//! Background jobs beside the listener: scrub (find bit rot) and cleanup
//! (expired uploads, temp files, unused chunks).
//!
//! ```text
//!  run ─► bind listener ─► BackgroundJobs::start ─┬─► scrub loop    every scrub_interval_hours
//!                                                 └─► cleanup loop  every cleanup_interval_minutes
//!  admin socket: scrub-now / cleanup-now ─► the same scrub() / cleanup()
//!  SIGTERM ─► stop(): the loops end; a running scrub stops between chunk pages
//! ```
//!
//! Each loop waits one full interval before its first run (a restart does
//! not start a week-long scrub). One scrub and one cleanup at a time: a
//! second request gets [`JobError::Busy`].

pub mod cleanup;
pub mod scrub;

use std::future::Future;
use std::path::PathBuf;
use std::sync::Arc;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use tokio::sync::{Mutex, watch};
use tokio::task::JoinHandle;

use crate::catalog::CatalogError;
use crate::catalog::reader::CatalogReader;
use crate::catalog::writer::CatalogWriter;
use crate::chunk_store::{ChunkStore, StoreError};
use crate::config::ServerConfig;

const MS_PER_MINUTE: u64 = 60_000;
const MS_PER_HOUR: u64 = 60 * MS_PER_MINUTE;

/// Unused chunks and orphan files are deleted only after this age (D-020).
pub const UNUSED_CHUNK_GRACE_MS: u64 = 24 * MS_PER_HOUR;
/// Files in `tmp/` older than this are left by a crash and deleted.
pub const TMP_FILE_MAX_AGE_MS: u64 = MS_PER_HOUR;
/// The orphan file pass walks every chunk file, so it runs at most once a
/// day (`cleanup-now` always runs it).
pub const ORPHAN_PASS_INTERVAL_MS: u64 = 24 * MS_PER_HOUR;
/// Scrub reads at most this fast, so uploads keep most of the disk. At
/// 64 MiB/s a 1 TB store takes about 4.5 h.
pub const SCRUB_MAX_BYTES_PER_SECOND: u64 = 64 * 1024 * 1024;

/// Timing and limits of the jobs (from the config; tests shorten some).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct JobSettings {
    pub scrub_interval_ms: u64,
    pub cleanup_interval_ms: u64,
    /// An upload not committed within this time is deleted.
    pub upload_expiry_ms: u64,
    /// Grace before an unused chunk (or orphan file) is deleted.
    pub unused_chunk_grace_ms: u64,
    pub tmp_file_max_age_ms: u64,
    pub orphan_pass_interval_ms: u64,
    /// 0 = no limit (tests only).
    pub scrub_max_bytes_per_second: u64,
}

impl JobSettings {
    /// The settings from `config.toml` and the constants above.
    pub fn from_config(config: &ServerConfig) -> Self {
        Self {
            scrub_interval_ms: u64::from(config.scrub_interval_hours) * MS_PER_HOUR,
            cleanup_interval_ms: u64::from(config.cleanup_interval_minutes) * MS_PER_MINUTE,
            upload_expiry_ms: u64::from(config.upload_expiry_hours) * MS_PER_HOUR,
            unused_chunk_grace_ms: UNUSED_CHUNK_GRACE_MS,
            tmp_file_max_age_ms: TMP_FILE_MAX_AGE_MS,
            orphan_pass_interval_ms: ORPHAN_PASS_INTERVAL_MS,
            scrub_max_bytes_per_second: SCRUB_MAX_BYTES_PER_SECOND,
        }
    }
}

/// Why a job did not finish.
#[derive(Debug, thiserror::Error)]
pub enum JobError {
    /// The same job is running now (scheduled, or another admin request).
    #[error("a {0} is already running")]
    Busy(&'static str),
    /// The server is shutting down; the job stopped early.
    #[error("the server is stopping")]
    Stopping,
    #[error(transparent)]
    Catalog(#[from] CatalogError),
    #[error(transparent)]
    Store(#[from] StoreError),
    #[error("cannot save the scrub report: {0}")]
    ReportSave(std::io::Error),
    /// A blocking task panicked or was cancelled.
    #[error("background task failed: {0}")]
    Task(#[from] tokio::task::JoinError),
}

/// What the jobs work on, and their run state. Shared by the loops and
/// the admin socket.
#[derive(Debug)]
pub struct BackgroundJobs {
    chunk_store: Arc<ChunkStore>,
    catalog_writer: CatalogWriter,
    catalog_reader: CatalogReader,
    /// Holds `scrub-report.json`.
    data_directory: PathBuf,
    settings: JobSettings,
    /// Held while a scrub runs.
    scrub_lock: Mutex<()>,
    /// Held while a cleanup runs; remembers the last orphan pass.
    cleanup_state: Mutex<cleanup::CleanupState>,
    stop_sender: watch::Sender<bool>,
}

impl BackgroundJobs {
    pub fn new(
        chunk_store: Arc<ChunkStore>,
        catalog_writer: CatalogWriter,
        catalog_reader: CatalogReader,
        data_directory: PathBuf,
        settings: JobSettings,
    ) -> Self {
        Self {
            chunk_store,
            catalog_writer,
            catalog_reader,
            data_directory,
            settings,
            scrub_lock: Mutex::new(()),
            cleanup_state: Mutex::new(cleanup::CleanupState::default()),
            stop_sender: watch::Sender::new(false),
        }
    }

    /// Starts the scrub and cleanup loops. They end after [`stop`](Self::stop).
    pub fn start(self: &Arc<Self>) -> Vec<JoinHandle<()>> {
        let scrub_jobs = Arc::clone(self);
        let scrub_task = tokio::spawn(async move {
            let interval = Duration::from_millis(scrub_jobs.settings.scrub_interval_ms);
            let stop_receiver = scrub_jobs.stop_sender.subscribe();
            repeat_every(interval, stop_receiver, || scrub_jobs.run_scheduled_scrub()).await;
        });
        let cleanup_jobs = Arc::clone(self);
        let cleanup_task = tokio::spawn(async move {
            let interval = Duration::from_millis(cleanup_jobs.settings.cleanup_interval_ms);
            let stop_receiver = cleanup_jobs.stop_sender.subscribe();
            repeat_every(interval, stop_receiver, || {
                cleanup_jobs.run_scheduled_cleanup()
            })
            .await;
        });
        vec![scrub_task, cleanup_task]
    }

    /// Asks the loops and a running scrub or cleanup to stop.
    pub fn stop(&self) {
        self.stop_sender.send_replace(true);
    }

    /// The data folder (it holds `scrub-report.json`).
    pub fn data_directory(&self) -> &std::path::Path {
        &self.data_directory
    }

    fn is_stopping(&self) -> bool {
        *self.stop_sender.borrow()
    }

    async fn run_scheduled_scrub(&self) {
        match self.scrub(None).await {
            Ok(report) => report.log(),
            Err(JobError::Busy(_)) => tracing::info!("scheduled scrub skipped: one is running"),
            Err(JobError::Stopping) => {}
            Err(error) => tracing::error!(%error, "scheduled scrub failed"),
        }
    }

    async fn run_scheduled_cleanup(&self) {
        match self.cleanup(false).await {
            Ok(report) => report.log(),
            Err(JobError::Busy(_)) => tracing::info!("scheduled cleanup skipped: one is running"),
            Err(JobError::Stopping) => {}
            Err(error) => tracing::error!(%error, "scheduled cleanup failed"),
        }
    }
}

/// Runs `job` every `interval` (first run after one interval) until `stop`
/// turns true. A run that takes long delays the next one, never overlaps.
async fn repeat_every<Job, JobFuture>(
    interval: Duration,
    mut stop_receiver: watch::Receiver<bool>,
    mut job: Job,
) where
    Job: FnMut() -> JobFuture,
    JobFuture: Future<Output = ()>,
{
    loop {
        tokio::select! {
            biased;
            _ = stop_receiver.wait_for(|is_stopping| *is_stopping) => return,
            () = tokio::time::sleep(interval) => {}
        }
        job().await;
    }
}

/// Now, in ms since the Unix epoch.
fn unix_time_ms() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0, |since_epoch| {
            i64::try_from(since_epoch.as_millis()).unwrap_or(i64::MAX)
        })
}

/// `now_ms - age_ms`, as a catalog time cutoff.
fn cutoff_ms(now_ms: i64, age_ms: u64) -> i64 {
    now_ms.saturating_sub(i64::try_from(age_ms).unwrap_or(i64::MAX))
}

/// Test helpers shared by the scrub and cleanup tests.
#[cfg(test)]
pub mod test_support {
    use super::*;

    /// Jobs on a fresh temp folder, with no rate limit.
    pub struct TestJobs {
        pub folder: tempfile::TempDir,
        pub jobs: Arc<BackgroundJobs>,
    }

    pub fn open_test_jobs(settings: JobSettings) -> TestJobs {
        let folder = tempfile::tempdir().unwrap();
        let database_path = folder.path().join("index.sqlite");
        let (catalog_writer, _thread) = CatalogWriter::start(&database_path).unwrap();
        let jobs = BackgroundJobs::new(
            Arc::new(ChunkStore::open(folder.path()).unwrap()),
            catalog_writer,
            CatalogReader::new(&database_path),
            folder.path().to_owned(),
            settings,
        );
        TestJobs {
            folder,
            jobs: Arc::new(jobs),
        }
    }

    /// Default settings without the scrub rate limit.
    pub fn fast_settings() -> JobSettings {
        JobSettings {
            scrub_max_bytes_per_second: 0,
            ..JobSettings::from_config(&ServerConfig::default())
        }
    }
}

#[cfg(test)]
mod tests {
    use std::sync::atomic::{AtomicU32, Ordering};

    use super::*;

    #[tokio::test(start_paused = true)]
    async fn loop_runs_after_each_interval_and_stops() {
        let (stop_sender, stop_receiver) = watch::channel(false);
        let run_count = Arc::new(AtomicU32::new(0));
        let counter = Arc::clone(&run_count);
        let task = tokio::spawn(repeat_every(
            Duration::from_secs(60),
            stop_receiver,
            move || {
                counter.fetch_add(1, Ordering::SeqCst);
                async {}
            },
        ));
        tokio::time::sleep(Duration::from_secs(59)).await;
        assert_eq!(run_count.load(Ordering::SeqCst), 0, "not at start");
        tokio::time::sleep(Duration::from_secs(2)).await;
        assert_eq!(run_count.load(Ordering::SeqCst), 1);
        tokio::time::sleep(Duration::from_secs(60)).await;
        assert_eq!(run_count.load(Ordering::SeqCst), 2);
        stop_sender.send_replace(true);
        task.await.unwrap();
    }

    #[test]
    fn settings_come_from_the_config() {
        let settings = JobSettings::from_config(&ServerConfig::default());
        assert_eq!(settings.scrub_interval_ms, 168 * MS_PER_HOUR);
        assert_eq!(settings.cleanup_interval_ms, 60 * MS_PER_MINUTE);
        assert_eq!(settings.upload_expiry_ms, 24 * MS_PER_HOUR);
        assert_eq!(cutoff_ms(10_000, 3_000), 7_000);
        assert_eq!(cutoff_ms(0, u64::MAX), -i64::MAX);
    }
}
