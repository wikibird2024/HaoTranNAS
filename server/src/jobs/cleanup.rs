//! Cleanup (every `cleanup_interval_minutes`, or `cleanup-now`):
//!
//! ```text
//!  1 expired uploads   catalog: uploads created before now - upload_expiry   (their upload_chunks go too)
//!  2 tmp/ files        older than 1 h (left by a crash mid-write)
//!  3 unused chunks     ONE writer job per round of 500 (D-020):
//!                        select rows with no version_chunks / upload_chunks row, created before now - 24 h
//!                        → delete the rows → commit → delete their files
//!  4 orphan files      at most once a day: chunk files older than 24 h with no catalog row
//! ```
//!
//! Why step 3 cannot race an upload: every catalog write runs in order on
//! the one writer thread, and the select, the row delete and the file delete
//! are one job. A `FileOffer` before it adds `upload_chunks` rows, so the
//! chunk is not selected; a `FileOffer` after it finds no row, lists the
//! chunk missing, and the client sends it again.
//!
//! Step 4 cleans up after a crash between "rows deleted" and "files
//! deleted", or between a chunk write and its catalog row. It keeps the 24 h
//! grace, so a chunk being written now (file renamed, row not yet recorded)
//! is never touched. Each delete re-checks for a row inside the writer.

use std::sync::Arc;
use std::time::{Duration, Instant};

use haotrannas_core::chunker::ChunkHash;

use super::{BackgroundJobs, JobError, cutoff_ms, unix_time_ms};
use crate::catalog::CatalogError;
use crate::chunk_store::ChunkStore;

/// Unused chunks deleted per writer job, so uploads wait only briefly.
const UNUSED_CHUNKS_PER_ROUND: usize = 500;
/// Orphan candidates checked per catalog read and per writer job.
const ORPHAN_HASHES_PER_BATCH: usize = 500;

/// What cleanup remembers between runs.
#[derive(Debug, Default)]
pub struct CleanupState {
    last_orphan_pass_at: Option<Instant>,
}

/// What one cleanup run did.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct CleanupReport {
    pub expired_uploads: u64,
    pub tmp_files: u64,
    /// Unused chunk rows deleted (their files with them).
    pub unused_chunks: u64,
    pub orphan_files: u64,
    /// False when the orphan pass was not due this run.
    pub is_orphan_pass_done: bool,
    pub duration_ms: u64,
}

impl CleanupReport {
    /// One line of `name value` pairs (admin replies, logs).
    pub fn summary_line(&self) -> String {
        format!(
            "expired_uploads {} tmp_files {} unused_chunks {} orphan_files {} orphan_pass {} \
             duration_ms {}",
            self.expired_uploads,
            self.tmp_files,
            self.unused_chunks,
            self.orphan_files,
            if self.is_orphan_pass_done {
                "yes"
            } else {
                "no"
            },
            self.duration_ms
        )
    }

    pub fn log(&self) {
        let has_work =
            self.expired_uploads + self.tmp_files + self.unused_chunks + self.orphan_files > 0;
        if has_work {
            tracing::info!("cleanup done: {}", self.summary_line());
        } else {
            tracing::debug!("cleanup done: {}", self.summary_line());
        }
    }
}

impl BackgroundJobs {
    /// Runs the cleanup steps in order. The orphan pass runs when
    /// `is_orphan_pass_forced` or when it is due. `Busy` if a cleanup runs
    /// already.
    pub async fn cleanup(&self, is_orphan_pass_forced: bool) -> Result<CleanupReport, JobError> {
        let mut state = self
            .cleanup_state
            .try_lock()
            .map_err(|_| JobError::Busy("cleanup"))?;
        let started_at = Instant::now();
        let now_ms = unix_time_ms();

        let expired_uploads = self
            .catalog_writer
            .delete_expired_uploads(cutoff_ms(now_ms, self.settings.upload_expiry_ms))
            .await?;

        let chunk_store = Arc::clone(&self.chunk_store);
        let tmp_file_max_age = Duration::from_millis(self.settings.tmp_file_max_age_ms);
        let swept_count =
            tokio::task::spawn_blocking(move || chunk_store.sweep_tmp(tmp_file_max_age)).await??;
        let mut report = CleanupReport {
            expired_uploads,
            tmp_files: u64::try_from(swept_count).unwrap_or(u64::MAX),
            ..CleanupReport::default()
        };

        let created_before_ms = cutoff_ms(now_ms, self.settings.unused_chunk_grace_ms);
        loop {
            if self.is_stopping() {
                return Err(JobError::Stopping);
            }
            let deleted = self
                .catalog_writer
                .delete_unused_chunks(
                    created_before_ms,
                    UNUSED_CHUNKS_PER_ROUND,
                    file_remover(Arc::clone(&self.chunk_store)),
                )
                .await?;
            report.unused_chunks += deleted.row_count;
            if deleted.file_count < deleted.row_count {
                tracing::warn!(
                    rows = deleted.row_count,
                    files = deleted.file_count,
                    "some unused chunks had no file to delete"
                );
            }
            if deleted.row_count < UNUSED_CHUNKS_PER_ROUND as u64 {
                break;
            }
        }

        let orphan_pass_interval = Duration::from_millis(self.settings.orphan_pass_interval_ms);
        let is_orphan_pass_due = state
            .last_orphan_pass_at
            .is_none_or(|last_pass_at| last_pass_at.elapsed() >= orphan_pass_interval);
        if is_orphan_pass_forced || is_orphan_pass_due {
            report.orphan_files = self.delete_orphan_files().await?;
            report.is_orphan_pass_done = true;
            state.last_orphan_pass_at = Some(Instant::now());
        }

        report.duration_ms = u64::try_from(started_at.elapsed().as_millis()).unwrap_or(u64::MAX);
        Ok(report)
    }

    /// Step 4: walks the chunk files (blocking), keeps those older than the
    /// grace with no catalog row, then deletes them in writer jobs that
    /// check the row again.
    async fn delete_orphan_files(&self) -> Result<u64, JobError> {
        let chunk_store = Arc::clone(&self.chunk_store);
        let catalog_reader = self.catalog_reader.clone();
        let grace = Duration::from_millis(self.settings.unused_chunk_grace_ms);
        let orphan_hashes = tokio::task::spawn_blocking(move || {
            let mut orphan_hashes: Vec<ChunkHash> = Vec::new();
            let mut batch = Vec::with_capacity(ORPHAN_HASHES_PER_BATCH);
            let mut first_error: Option<CatalogError> = None;
            let mut check_batch = |batch: &mut Vec<ChunkHash>| {
                if first_error.is_none() {
                    match catalog_reader.hashes_not_in_catalog(batch) {
                        Ok(unknown_hashes) => orphan_hashes.extend(unknown_hashes),
                        Err(error) => first_error = Some(error),
                    }
                }
                batch.clear();
            };
            chunk_store.for_each_chunk_file_older_than(grace, &mut |hash| {
                batch.push(hash);
                if batch.len() == ORPHAN_HASHES_PER_BATCH {
                    check_batch(&mut batch);
                }
            })?;
            check_batch(&mut batch);
            if let Some(error) = first_error {
                return Err(JobError::Catalog(error));
            }
            Ok(orphan_hashes)
        })
        .await??;

        let mut removed_count = 0;
        for batch in orphan_hashes.chunks(ORPHAN_HASHES_PER_BATCH) {
            if self.is_stopping() {
                return Err(JobError::Stopping);
            }
            removed_count += self
                .catalog_writer
                .delete_orphan_chunk_files(
                    batch.to_vec(),
                    file_remover(Arc::clone(&self.chunk_store)),
                )
                .await?;
        }
        if removed_count > 0 {
            tracing::info!(removed_count, "deleted orphan chunk files (no catalog row)");
        }
        Ok(removed_count)
    }
}

/// Deletes one chunk file on the writer thread; true when a file was
/// deleted. A failure is logged and leaves an orphan for the next pass.
fn file_remover(chunk_store: Arc<ChunkStore>) -> impl FnMut(&ChunkHash) -> bool + Send + 'static {
    move |hash| match chunk_store.remove(hash) {
        Ok(was_removed) => was_removed,
        Err(error) => {
            tracing::warn!(%error, chunk = %hash, "cannot delete chunk file; left as an orphan");
            false
        }
    }
}

#[cfg(test)]
mod tests {
    use std::fs::{self, File};
    use std::time::SystemTime;

    use haotrannas_core::limits::CHUNK_SIZE_BYTES;
    use sha2::{Digest, Sha256};

    use super::super::JobSettings;
    use super::super::test_support::{TestJobs, fast_settings, open_test_jobs};
    use super::*;
    use crate::catalog::ChunkStatus;
    use crate::catalog::writer::FileOfferInput;

    fn hash_of(data: &[u8]) -> ChunkHash {
        ChunkHash(Sha256::digest(data).into())
    }

    /// No grace and no expiry, so everything unused goes at once.
    fn no_grace_settings() -> JobSettings {
        JobSettings {
            upload_expiry_ms: 0,
            unused_chunk_grace_ms: 0,
            ..fast_settings()
        }
    }

    /// Stores and records one chunk, `created_at_ms` as given.
    async fn store_chunk(test: &TestJobs, data: &[u8], created_at_ms: i64) -> ChunkHash {
        let hash = hash_of(data);
        test.jobs.chunk_store.put(&hash, data).unwrap();
        test.jobs
            .catalog_writer
            .record_chunk(hash, data.len() as u64, created_at_ms)
            .await
            .unwrap();
        hash
    }

    fn set_age(path: &std::path::Path, age: Duration) {
        File::options()
            .write(true)
            .open(path)
            .unwrap()
            .set_modified(SystemTime::now() - age)
            .unwrap();
    }

    async fn add_device(test: &TestJobs) -> u64 {
        test.jobs
            .catalog_writer
            .add_device("phone".to_owned(), [1; 32], 0)
            .await
            .unwrap()
    }

    fn one_chunk_offer(path: &str, hash: ChunkHash) -> FileOfferInput {
        FileOfferInput {
            path: path.to_owned(),
            size_bytes: u64::from(CHUNK_SIZE_BYTES),
            modified_time_ms: 1,
            file_sha256: [7; 32],
            chunk_hashes: vec![hash],
        }
    }

    #[tokio::test]
    async fn cleanup_deletes_expired_uploads_old_tmp_unused_chunks_and_orphans() {
        let test = open_test_jobs(JobSettings {
            unused_chunk_grace_ms: 3_600_000,
            ..no_grace_settings()
        });
        let jobs = &test.jobs;
        let device_id = add_device(&test).await;
        let now_ms = unix_time_ms();
        let day_ago_ms = now_ms - 86_400_000;

        // An upload that names an old chunk, created a day ago (expired).
        let expired_chunk = store_chunk(&test, b"in expired upload", day_ago_ms).await;
        jobs.catalog_writer
            .offer_file(
                device_id,
                one_chunk_offer("old.bin", expired_chunk),
                day_ago_ms,
            )
            .await
            .unwrap();
        // Unused: old (deleted) and young (kept by the grace).
        let old_unused = store_chunk(&test, b"old unused", day_ago_ms).await;
        let young_unused = store_chunk(&test, b"young unused", now_ms).await;
        // An old orphan file and a young one.
        let (old_orphan, young_orphan) = (hash_of(b"old orphan"), hash_of(b"young orphan"));
        jobs.chunk_store.put(&old_orphan, b"old orphan").unwrap();
        jobs.chunk_store
            .put(&young_orphan, b"young orphan")
            .unwrap();
        set_age(
            &jobs.chunk_store.path_for(&old_orphan),
            Duration::from_secs(7200),
        );
        // Temp junk: old and new.
        let tmp_directory = test.folder.path().join("tmp");
        fs::write(tmp_directory.join("old.tmp"), b"junk").unwrap();
        set_age(&tmp_directory.join("old.tmp"), Duration::from_secs(7200));
        fs::write(tmp_directory.join("new.tmp"), b"junk").unwrap();

        let report = jobs.cleanup(false).await.unwrap();
        assert_eq!(
            (
                report.expired_uploads,
                report.tmp_files,
                report.unused_chunks,
                report.orphan_files,
                report.is_orphan_pass_done
            ),
            (1, 1, 2, 1, true),
            "{report:?}"
        );
        for gone in [expired_chunk, old_unused, old_orphan] {
            assert!(!jobs.chunk_store.has(&gone).unwrap());
        }
        assert_eq!(jobs.catalog_reader.chunk_status(&old_unused).unwrap(), None);
        for kept in [young_unused, young_orphan] {
            assert!(jobs.chunk_store.has(&kept).unwrap());
        }
        assert!(tmp_directory.join("new.tmp").exists());
        assert!(!tmp_directory.join("old.tmp").exists());

        // The orphan pass is not due again for a day; cleanup-now forces it.
        let report = jobs.cleanup(false).await.unwrap();
        assert!(!report.is_orphan_pass_done);
        assert!(jobs.cleanup(true).await.unwrap().is_orphan_pass_done);
    }

    #[tokio::test]
    async fn chunks_of_versions_and_open_uploads_are_never_deleted() {
        let test = open_test_jobs(JobSettings {
            upload_expiry_ms: 3_600_000,
            ..no_grace_settings()
        });
        let jobs = &test.jobs;
        let device_id = add_device(&test).await;
        let now_ms = unix_time_ms();
        let committed_chunk = store_chunk(&test, b"committed", 0).await;
        let mut committed_offer = one_chunk_offer("kept.bin", committed_chunk);
        committed_offer.file_sha256 = Sha256::digest(b"committed").into();
        committed_offer.size_bytes = 9;
        let outcome = jobs
            .catalog_writer
            .offer_file(device_id, committed_offer, now_ms)
            .await
            .unwrap();
        jobs.catalog_writer
            .commit_upload(device_id, outcome.upload_id, now_ms)
            .await
            .unwrap();
        let open_chunk = store_chunk(&test, b"open upload", 0).await;
        jobs.catalog_writer
            .offer_file(device_id, one_chunk_offer("open.bin", open_chunk), now_ms)
            .await
            .unwrap();
        for hash in [committed_chunk, open_chunk] {
            set_age(&jobs.chunk_store.path_for(&hash), Duration::from_secs(7200));
        }

        let report = jobs.cleanup(true).await.unwrap();
        assert_eq!((report.unused_chunks, report.orphan_files), (0, 0));
        for kept in [committed_chunk, open_chunk] {
            assert!(jobs.chunk_store.has(&kept).unwrap());
            assert_eq!(
                jobs.catalog_reader.chunk_status(&kept).unwrap(),
                Some(ChunkStatus::Ok)
            );
        }
    }

    #[tokio::test]
    async fn many_unused_chunks_go_in_several_rounds() {
        let test = open_test_jobs(no_grace_settings());
        let chunk_count = UNUSED_CHUNKS_PER_ROUND + 3;
        for number in 0..chunk_count {
            store_chunk(&test, &number.to_le_bytes(), 0).await;
        }
        let report = test.jobs.cleanup(false).await.unwrap();
        assert_eq!(report.unused_chunks, chunk_count as u64);
        assert_eq!(report.orphan_files, 0);
        assert!(
            crate::catalog::reader::CatalogReader::chunk_page(&test.jobs.catalog_reader, None, 1)
                .unwrap()
                .is_empty()
        );
    }

    #[tokio::test]
    async fn one_cleanup_at_a_time() {
        let test = open_test_jobs(fast_settings());
        let _running = test.jobs.cleanup_state.lock().await;
        assert!(matches!(
            test.jobs.cleanup(true).await,
            Err(JobError::Busy("cleanup"))
        ));
    }
}
