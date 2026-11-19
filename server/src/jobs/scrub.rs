//! Scrub (weekly, or `scrub-now`): re-hashes every stored chunk and marks
//! damaged or missing ones bad in the catalog. A bad chunk is listed missing
//! by the next `FileOffer` that names it, so the phone re-sends it (spec §8,
//! D-027); a bad chunk that verifies again (ZFS repaired it, or an upload
//! replaced it) is marked ok.
//!
//! ```text
//!  chunk_page(after last hash, 256) ─► per chunk: verify (blocking) ─► mark bad / ok ─► pace
//!        ▲                                                                          │
//!        └──────────── next page (stop here on shutdown) ◄──── progress <n> ◄────────┘
//!  end ─► ScrubReport ─► <data>/scrub-report.json (atomic) + log
//! ```
//!
//! A scrub that reads a chunk just before an upload replaces it can mark
//! the new, good copy bad. That costs one re-send, never data: the next
//! offer lists it missing, and the next scrub marks it ok again.

use std::fs::{self, File};
use std::io::{self, Write};
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::{Duration, Instant};

use serde::{Deserialize, Serialize};
use tokio::sync::mpsc;

use super::{BackgroundJobs, JobError, unix_time_ms};
use crate::catalog::ChunkStatus;
use crate::catalog::reader::ChunkRecord;
use crate::chunk_store::ChunkHealth;

/// The last finished scrub's report, inside the data folder.
pub const SCRUB_REPORT_FILE_NAME: &str = "scrub-report.json";
/// Chunks read from the catalog at a time (one `progress` line each).
const CHUNKS_PER_PAGE: usize = 256;

/// What one finished scrub found.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct ScrubReport {
    /// Chunks in the catalog that were checked.
    pub chunks_checked: u64,
    /// Bytes read and re-hashed.
    pub bytes_checked: u64,
    /// Chunk files whose bytes do not match their hash (bit rot).
    pub bad_found: u64,
    /// Chunks that were marked bad and now verify ok.
    pub repaired: u64,
    /// Chunks in the catalog with no file.
    pub missing: u64,
    pub started_at_ms: i64,
    pub duration_ms: u64,
}

impl ScrubReport {
    /// One line of `name value` pairs (admin replies, logs).
    pub fn summary_line(&self) -> String {
        format!(
            "chunks_checked {} bytes_checked {} bad_found {} missing {} repaired {} \
             started_at_ms {} duration_ms {}",
            self.chunks_checked,
            self.bytes_checked,
            self.bad_found,
            self.missing,
            self.repaired,
            self.started_at_ms,
            self.duration_ms
        )
    }

    /// Logs the summary: a warning when something is damaged or missing.
    pub fn log(&self) {
        if self.bad_found > 0 || self.missing > 0 {
            tracing::warn!(
                "scrub found damaged or missing chunks: {}; see nas/RUNBOOK.md",
                self.summary_line()
            );
        } else {
            tracing::info!("scrub done: {}", self.summary_line());
        }
    }
}

impl BackgroundJobs {
    /// Runs one full scrub and saves its report. Sends the running chunk
    /// count to `progress` after each page. `Busy` if a scrub runs already,
    /// `Stopping` (and no report) if the server stops meanwhile.
    pub async fn scrub(
        &self,
        progress: Option<&mpsc::UnboundedSender<u64>>,
    ) -> Result<ScrubReport, JobError> {
        let _running = self
            .scrub_lock
            .try_lock()
            .map_err(|_| JobError::Busy("scrub"))?;
        let started_at = Instant::now();
        let mut report = ScrubReport {
            started_at_ms: unix_time_ms(),
            ..ScrubReport::default()
        };
        let mut stop_receiver = self.stop_sender.subscribe();
        let mut pacer = Pacer::new(self.settings.scrub_max_bytes_per_second, started_at);
        let mut after_hash = None;
        loop {
            if self.is_stopping() {
                return Err(JobError::Stopping);
            }
            let catalog_reader = self.catalog_reader.clone();
            let page = tokio::task::spawn_blocking(move || {
                catalog_reader.chunk_page(after_hash.as_ref(), CHUNKS_PER_PAGE)
            })
            .await??;
            let Some(last_record) = page.last() else {
                break;
            };
            after_hash = Some(last_record.hash);
            for record in &page {
                let chunk_started_at = Instant::now();
                self.scrub_one_chunk(record, &mut report).await?;
                let resume_at = pacer.resume_at(chunk_started_at, record.size_bytes);
                tokio::select! {
                    biased;
                    _ = stop_receiver.wait_for(|is_stopping| *is_stopping) => {
                        return Err(JobError::Stopping);
                    }
                    () = tokio::time::sleep_until(resume_at.into()) => {}
                }
            }
            if let Some(progress) = progress {
                // The admin client may have gone; the scrub goes on.
                let _ = progress.send(report.chunks_checked);
            }
        }
        report.duration_ms = u64::try_from(started_at.elapsed().as_millis()).unwrap_or(u64::MAX);
        let report_path = self.data_directory.join(SCRUB_REPORT_FILE_NAME);
        tokio::task::spawn_blocking(move || save_report(&report_path, &report))
            .await?
            .map_err(JobError::ReportSave)?;
        Ok(report)
    }

    /// Re-hashes one chunk and brings its catalog status in line.
    async fn scrub_one_chunk(
        &self,
        record: &ChunkRecord,
        report: &mut ScrubReport,
    ) -> Result<(), JobError> {
        let chunk_store = Arc::clone(&self.chunk_store);
        let hash = record.hash;
        let health = tokio::task::spawn_blocking(move || chunk_store.verify(&hash))
            .await?
            .unwrap_or_else(|error| {
                // ZFS answers EIO for a block it cannot repair: that is bit rot.
                tracing::warn!(%error, chunk = %hash, "cannot read chunk; counting it as damaged");
                ChunkHealth::Bad
            });
        report.chunks_checked += 1;
        match health {
            ChunkHealth::Ok => {
                report.bytes_checked += record.size_bytes;
                if record.status == ChunkStatus::Bad
                    && self.catalog_writer.mark_chunk_ok(hash).await?
                {
                    tracing::info!(chunk = %hash, "chunk marked bad verifies ok again; marked ok");
                    report.repaired += 1;
                }
            }
            // `mark_chunk_bad` is false when cleanup deleted the row since
            // the page was read: nothing is lost then, so nothing is counted.
            ChunkHealth::Bad => {
                report.bytes_checked += record.size_bytes;
                if self.catalog_writer.mark_chunk_bad(hash).await? {
                    tracing::warn!(chunk = %hash, "chunk damaged on disk; marked bad");
                    report.bad_found += 1;
                }
            }
            ChunkHealth::Missing => {
                if self.catalog_writer.mark_chunk_bad(hash).await? {
                    tracing::warn!(chunk = %hash, "chunk file missing; marked bad");
                    report.missing += 1;
                }
            }
        }
        Ok(())
    }
}

/// Keeps the scrub at or below a byte rate: after a chunk of `size_bytes`,
/// the next one starts no earlier than `size_bytes / rate` after this one
/// started. Time lost to a slow read is not made up later in a burst.
#[derive(Debug)]
struct Pacer {
    /// 0 = no limit.
    max_bytes_per_second: u64,
    next_start_at: Instant,
}

impl Pacer {
    fn new(max_bytes_per_second: u64, now: Instant) -> Self {
        Self {
            max_bytes_per_second,
            next_start_at: now,
        }
    }

    /// When the next chunk may start.
    fn resume_at(&mut self, chunk_started_at: Instant, size_bytes: u64) -> Instant {
        if self.max_bytes_per_second == 0 {
            return chunk_started_at;
        }
        // Rounding to whole nanoseconds: precise enough for pacing.
        #[allow(clippy::cast_precision_loss, reason = "pacing needs no exact ns")]
        let cost = Duration::from_secs_f64(size_bytes as f64 / self.max_bytes_per_second as f64);
        self.next_start_at = self.next_start_at.max(chunk_started_at) + cost;
        self.next_start_at
    }
}

/// Writes the report as JSON: temp file, fsync, rename, fsync the folder.
fn save_report(report_path: &Path, report: &ScrubReport) -> io::Result<()> {
    let tmp_path = report_path.with_extension("json.tmp");
    let json = serde_json::to_vec_pretty(report).map_err(io::Error::other)?;
    let mut file = File::create(&tmp_path)?;
    file.write_all(&json)?;
    file.write_all(b"\n")?;
    file.sync_all()?;
    fs::rename(&tmp_path, report_path)?;
    if let Some(folder) = report_path.parent() {
        File::open(folder)?.sync_all()?;
    }
    Ok(())
}

/// The last saved report, or `None` before the first scrub finished.
pub fn load_report(data_directory: &Path) -> io::Result<Option<ScrubReport>> {
    let report_path: PathBuf = data_directory.join(SCRUB_REPORT_FILE_NAME);
    match fs::read(&report_path) {
        Ok(json) => serde_json::from_slice(&json)
            .map(Some)
            .map_err(io::Error::other),
        Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(None),
        Err(error) => Err(error),
    }
}

#[cfg(test)]
mod tests {
    use haotrannas_core::chunker::ChunkHash;
    use sha2::{Digest, Sha256};

    use super::super::test_support::{fast_settings, open_test_jobs};
    use super::*;

    fn hash_of(data: &[u8]) -> ChunkHash {
        ChunkHash(Sha256::digest(data).into())
    }

    /// Stores and records chunks with these contents; returns their hashes.
    async fn store_chunks(jobs: &BackgroundJobs, contents: &[&[u8]]) -> Vec<ChunkHash> {
        let mut hashes = Vec::new();
        for data in contents {
            let hash = hash_of(data);
            jobs.chunk_store.put(&hash, data).unwrap();
            jobs.catalog_writer
                .record_chunk(hash, data.len() as u64, 1)
                .await
                .unwrap();
            hashes.push(hash);
        }
        hashes
    }

    #[tokio::test]
    async fn scrub_finds_bad_and_missing_then_sees_the_repair() {
        let test = open_test_jobs(fast_settings());
        let jobs = &test.jobs;
        let hashes = store_chunks(jobs, &[b"first", b"second", b"third"]).await;
        let first_path = jobs.chunk_store.path_for(&hashes[0]);
        fs::write(&first_path, b"firsT").unwrap();
        fs::remove_file(jobs.chunk_store.path_for(&hashes[1])).unwrap();

        let (progress_sender, mut progress_receiver) = mpsc::unbounded_channel();
        let report = jobs.scrub(Some(&progress_sender)).await.unwrap();
        assert_eq!(
            (report.chunks_checked, report.bytes_checked),
            (3, 10),
            "{report:?}"
        );
        assert_eq!(
            (report.bad_found, report.missing, report.repaired),
            (1, 1, 0)
        );
        assert_eq!(progress_receiver.recv().await, Some(3));
        for hash in &hashes[..2] {
            assert_eq!(
                jobs.catalog_reader.chunk_status(hash).unwrap(),
                Some(ChunkStatus::Bad)
            );
        }
        assert_eq!(load_report(test.folder.path()).unwrap(), Some(report));

        // ZFS (or an upload) puts the first chunk right again.
        fs::write(&first_path, b"first").unwrap();
        let report = jobs.scrub(None).await.unwrap();
        assert_eq!(
            (report.bad_found, report.missing, report.repaired),
            (0, 1, 1)
        );
        assert_eq!(
            jobs.catalog_reader.chunk_status(&hashes[0]).unwrap(),
            Some(ChunkStatus::Ok)
        );
        assert_eq!(load_report(test.folder.path()).unwrap(), Some(report));
    }

    #[tokio::test]
    async fn no_report_before_the_first_scrub_and_one_scrub_at_a_time() {
        let test = open_test_jobs(fast_settings());
        assert_eq!(load_report(test.folder.path()).unwrap(), None);
        let _running = test.jobs.scrub_lock.lock().await;
        assert!(matches!(
            test.jobs.scrub(None).await,
            Err(JobError::Busy("scrub"))
        ));
    }

    #[tokio::test]
    async fn stopped_scrub_saves_no_report() {
        let test = open_test_jobs(fast_settings());
        store_chunks(&test.jobs, &[b"one"]).await;
        test.jobs.stop();
        assert!(matches!(
            test.jobs.scrub(None).await,
            Err(JobError::Stopping)
        ));
        assert_eq!(load_report(test.folder.path()).unwrap(), None);
    }

    #[test]
    fn pacer_keeps_the_rate_without_catch_up_bursts() {
        let start = Instant::now();
        let mut pacer = Pacer::new(1_000_000, start);
        // A fast read of 1 MB: wait until 1 s after it started.
        assert_eq!(
            pacer.resume_at(start, 1_000_000),
            start + Duration::from_secs(1)
        );
        // A slow read that started late: its own start counts, no burst.
        let late_start = start + Duration::from_secs(5);
        assert_eq!(
            pacer.resume_at(late_start, 500_000),
            late_start + Duration::from_millis(500)
        );
        let mut unlimited = Pacer::new(0, start);
        assert_eq!(unlimited.resume_at(late_start, 1_000_000), late_start);
    }

    #[test]
    fn summary_line_names_every_number() {
        let report = ScrubReport {
            chunks_checked: 1,
            bytes_checked: 2,
            bad_found: 3,
            repaired: 4,
            missing: 5,
            started_at_ms: 6,
            duration_ms: 7,
        };
        assert_eq!(
            report.summary_line(),
            "chunks_checked 1 bytes_checked 2 bad_found 3 missing 5 repaired 4 \
             started_at_ms 6 duration_ms 7"
        );
    }
}
