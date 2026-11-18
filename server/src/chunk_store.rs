//! Chunk files on disk: `chunks/ab/cd/<sha256 hex>`, never changed once
//! written. A write goes to `tmp/`, is fsynced, re-hashed and only then
//! renamed into place (`docs/conventions.md` §4).
//!
//! Every call is blocking file I/O: async callers use
//! `tokio::task::spawn_blocking`. `ChunkStore` is `Sync`, so one store can be
//! shared by many threads.

use std::fs::{self, File, OpenOptions};
use std::io::{self, Write};
use std::path::{Path, PathBuf};
use std::time::Duration;

use haotrannas_core::chunker::ChunkHash;
use sha2::{Digest, Sha256};

/// Folder under the root that holds the chunk files.
const CHUNKS_DIRECTORY_NAME: &str = "chunks";
/// Folder under the root that holds chunks being written.
const TMP_DIRECTORY_NAME: &str = "tmp";
/// File name ending of a chunk being written.
const TMP_FILE_EXTENSION: &str = "tmp";
/// `ENOSPC` on Linux, in case the standard library maps it to another kind.
const NO_SPACE_ERROR_NUMBER: i32 = 28;
/// Folder permissions: only the server user.
#[cfg(unix)]
const PRIVATE_DIRECTORY_MODE: u32 = 0o700;
/// Chunk file permissions: only the server user.
#[cfg(unix)]
const PRIVATE_FILE_MODE: u32 = 0o600;

/// What `put` did.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PutOutcome {
    /// The chunk was written now.
    Stored,
    /// A file with this name was already there; nothing was written.
    AlreadyStored,
}

/// What `verify` found on disk.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ChunkHealth {
    /// The file is there and its bytes hash to its name.
    Ok,
    /// The file is there but its bytes do not hash to its name (bit rot).
    Bad,
    /// No file with this name.
    Missing,
}

/// Why a chunk store call failed.
#[derive(Debug, thiserror::Error)]
pub enum StoreError {
    /// The data does not hash to the given name. Nothing was written.
    #[error("chunk data does not match its SHA-256 name")]
    HashMismatch,
    /// The bytes read back after the write did not hash to the name.
    #[error("chunk read back from disk does not match its SHA-256 name")]
    WriteVerifyFailed,
    /// The disk (or quota) is full.
    #[error("disk full")]
    DiskFull,
    /// No chunk file with this name.
    #[error("chunk not found")]
    NotFound,
    /// Any other file system error.
    #[error("chunk store I/O error: {0}")]
    Io(io::Error),
}

impl From<io::Error> for StoreError {
    fn from(error: io::Error) -> Self {
        let is_disk_full = matches!(
            error.kind(),
            io::ErrorKind::StorageFull | io::ErrorKind::QuotaExceeded
        ) || error.raw_os_error() == Some(NO_SPACE_ERROR_NUMBER);
        if is_disk_full {
            Self::DiskFull
        } else {
            Self::Io(error)
        }
    }
}

/// The chunk folder tree under the data folder.
#[derive(Debug)]
pub struct ChunkStore {
    /// Folder holding `chunks/` and `tmp/`.
    root_directory: PathBuf,
    /// Test fail-point: stop right after the temp file is written, as if the
    /// server crashed before the rename.
    #[cfg(test)]
    crash_before_rename: std::sync::atomic::AtomicBool,
}

impl ChunkStore {
    /// Opens the store under `root_directory`, creating `chunks/` and `tmp/`
    /// (mode 0700 on unix) when missing.
    pub fn open(root_directory: impl Into<PathBuf>) -> Result<Self, StoreError> {
        let root_directory = root_directory.into();
        fs::create_dir_all(&root_directory)?;
        for name in [CHUNKS_DIRECTORY_NAME, TMP_DIRECTORY_NAME] {
            let directory = root_directory.join(name);
            match create_private_directory(&directory) {
                Ok(()) => sync_directory(&root_directory)?,
                Err(error) if error.kind() == io::ErrorKind::AlreadyExists => {}
                Err(error) => return Err(error.into()),
            }
            set_private_directory_mode(&directory)?;
        }
        Ok(Self {
            root_directory,
            #[cfg(test)]
            crash_before_rename: std::sync::atomic::AtomicBool::new(false),
        })
    }

    /// Where the chunk named `hash` lives: `chunks/<hex 0..2>/<hex 2..4>/<hex>`.
    pub fn path_for(&self, hash: &ChunkHash) -> PathBuf {
        let hex_name = hex::encode(hash.0);
        self.root_directory
            .join(CHUNKS_DIRECTORY_NAME)
            .join(&hex_name[0..2])
            .join(&hex_name[2..4])
            .join(&hex_name)
    }

    /// Stores `data` under `hash` unless a file with that name is already
    /// there. The data is checked against the hash first; on a mismatch
    /// nothing is written.
    pub fn put(&self, hash: &ChunkHash, data: &[u8]) -> Result<PutOutcome, StoreError> {
        check_hash(hash, data)?;
        if self.has(hash)? {
            return Ok(PutOutcome::AlreadyStored);
        }
        self.write_atomically(hash, data)?;
        Ok(PutOutcome::Stored)
    }

    /// Stores `data` under `hash`, atomically replacing a file that is
    /// already there (used to repair a chunk marked bad).
    pub fn replace(&self, hash: &ChunkHash, data: &[u8]) -> Result<(), StoreError> {
        check_hash(hash, data)?;
        self.write_atomically(hash, data)
    }

    /// Reads the chunk's bytes. Does not re-hash them (`verify` does).
    pub fn read(&self, hash: &ChunkHash) -> Result<Vec<u8>, StoreError> {
        match fs::read(self.path_for(hash)) {
            Ok(data) => Ok(data),
            Err(error) if error.kind() == io::ErrorKind::NotFound => Err(StoreError::NotFound),
            Err(error) => Err(error.into()),
        }
    }

    /// Re-hashes the chunk file and says whether it is intact.
    pub fn verify(&self, hash: &ChunkHash) -> Result<ChunkHealth, StoreError> {
        match self.read(hash) {
            Ok(data) if sha256(&data) == hash.0 => Ok(ChunkHealth::Ok),
            Ok(_) => Ok(ChunkHealth::Bad),
            Err(StoreError::NotFound) => Ok(ChunkHealth::Missing),
            Err(error) => Err(error),
        }
    }

    /// Whether a file with this chunk's name exists (its bytes are not checked).
    pub fn has(&self, hash: &ChunkHash) -> Result<bool, StoreError> {
        Ok(self.path_for(hash).try_exists()?)
    }

    /// Deletes temp files last changed at least `older_than` ago (left by a
    /// crash). Returns how many were removed.
    pub fn sweep_tmp(&self, older_than: Duration) -> Result<usize, StoreError> {
        let mut removed_count = 0;
        for entry in fs::read_dir(self.tmp_directory())? {
            let entry = entry?;
            let metadata = entry.metadata()?;
            if !metadata.is_file() {
                continue;
            }
            // A modified time in the future counts as age zero.
            let age = metadata.modified()?.elapsed().unwrap_or(Duration::ZERO);
            if age < older_than {
                continue;
            }
            match fs::remove_file(entry.path()) {
                Ok(()) => removed_count += 1,
                // Another sweep or the writer removed it first.
                Err(error) if error.kind() == io::ErrorKind::NotFound => {}
                Err(error) => return Err(error.into()),
            }
        }
        Ok(removed_count)
    }

    /// `tmp/` under the root.
    fn tmp_directory(&self) -> PathBuf {
        self.root_directory.join(TMP_DIRECTORY_NAME)
    }

    /// Temp write → fsync → read back and re-hash → fan-out folders →
    /// rename into place → fsync the folder. The temp file is removed on any
    /// error. The rename overwrites an existing file with the same name.
    fn write_atomically(&self, hash: &ChunkHash, data: &[u8]) -> Result<(), StoreError> {
        let tmp_path = self.tmp_directory().join(format!(
            "{:032x}.{TMP_FILE_EXTENSION}",
            rand::random::<u128>()
        ));
        let mut tmp_file_guard = TmpFileGuard {
            path: &tmp_path,
            is_armed: true,
        };

        write_and_sync_new_file(&tmp_path, data)?;
        let read_back = fs::read(&tmp_path)?;
        if sha256(&read_back) != hash.0 {
            return Err(StoreError::WriteVerifyFailed);
        }

        #[cfg(test)]
        if self
            .crash_before_rename
            .load(std::sync::atomic::Ordering::SeqCst)
        {
            // Simulated crash: the temp file stays behind.
            tmp_file_guard.is_armed = false;
            return Err(StoreError::Io(io::Error::other(
                "test fail-point: crash before rename",
            )));
        }

        let final_path = self.path_for(hash);
        let parent_directory = final_path
            .parent()
            .expect("a chunk path always has a parent folder");
        Self::create_fan_out_directories(parent_directory)?;
        fs::rename(&tmp_path, &final_path)?;
        tmp_file_guard.is_armed = false;
        sync_directory(parent_directory)?;
        Ok(())
    }

    /// Creates `chunks/ab` and `chunks/ab/cd` when missing and fsyncs the
    /// folder that got a new entry.
    fn create_fan_out_directories(leaf_directory: &Path) -> Result<(), StoreError> {
        let middle_directory = leaf_directory
            .parent()
            .expect("a fan-out folder always has a parent folder");
        for directory in [middle_directory, leaf_directory] {
            if directory.try_exists()? {
                continue;
            }
            match create_private_directory(directory) {
                // Also fsync when another thread created it a moment ago: its
                // fsync may not have happened yet.
                Ok(()) => {}
                Err(error) if error.kind() == io::ErrorKind::AlreadyExists => {}
                Err(error) => return Err(error.into()),
            }
            sync_directory(
                directory
                    .parent()
                    .expect("a fan-out folder always has a parent folder"),
            )?;
        }
        Ok(())
    }
}

/// Removes the temp file when dropped, unless disarmed (after the rename).
struct TmpFileGuard<'path> {
    path: &'path Path,
    is_armed: bool,
}

impl Drop for TmpFileGuard<'_> {
    fn drop(&mut self) {
        if self.is_armed {
            // Best effort: a leftover is removed later by `sweep_tmp`.
            let _ = fs::remove_file(self.path);
        }
    }
}

/// SHA-256 of `data`.
fn sha256(data: &[u8]) -> [u8; 32] {
    Sha256::digest(data).into()
}

/// `HashMismatch` unless `data` hashes to `hash`.
fn check_hash(hash: &ChunkHash, data: &[u8]) -> Result<(), StoreError> {
    if sha256(data) == hash.0 {
        Ok(())
    } else {
        Err(StoreError::HashMismatch)
    }
}

/// Creates a new file (fails if it exists), writes `data` and fsyncs it.
fn write_and_sync_new_file(path: &Path, data: &[u8]) -> io::Result<()> {
    let mut options = OpenOptions::new();
    options.write(true).create_new(true);
    #[cfg(unix)]
    std::os::unix::fs::OpenOptionsExt::mode(&mut options, PRIVATE_FILE_MODE);
    let mut file = options.open(path)?;
    file.write_all(data)?;
    file.sync_all()
}

/// Creates one folder (not its parents), mode 0700 on unix.
fn create_private_directory(path: &Path) -> io::Result<()> {
    let mut builder = fs::DirBuilder::new();
    #[cfg(unix)]
    std::os::unix::fs::DirBuilderExt::mode(&mut builder, PRIVATE_DIRECTORY_MODE);
    builder.create(path)
}

/// Sets mode 0700 on an existing folder (unix only).
fn set_private_directory_mode(path: &Path) -> io::Result<()> {
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        fs::set_permissions(path, fs::Permissions::from_mode(PRIVATE_DIRECTORY_MODE))?;
    }
    #[cfg(not(unix))]
    let _ = path;
    Ok(())
}

/// Fsyncs a folder so a new or renamed entry in it survives a power cut.
fn sync_directory(path: &Path) -> io::Result<()> {
    #[cfg(unix)]
    {
        File::open(path)?.sync_all()
    }
    // Windows cannot open a folder as a file; NTFS journals renames.
    #[cfg(not(unix))]
    {
        let _ = path;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use std::sync::Arc;
    use std::sync::atomic::Ordering;

    use super::*;

    fn hash_of(data: &[u8]) -> ChunkHash {
        ChunkHash(sha256(data))
    }

    fn count_files(directory: &Path) -> usize {
        let mut count = 0;
        for entry in fs::read_dir(directory).unwrap() {
            let entry = entry.unwrap();
            if entry.file_type().unwrap().is_dir() {
                count += count_files(&entry.path());
            } else {
                count += 1;
            }
        }
        count
    }

    fn open_test_store() -> (tempfile::TempDir, ChunkStore) {
        let root = tempfile::tempdir().unwrap();
        let store = ChunkStore::open(root.path()).unwrap();
        (root, store)
    }

    #[test]
    fn open_creates_private_folders() {
        let (root, _store) = open_test_store();
        for name in [CHUNKS_DIRECTORY_NAME, TMP_DIRECTORY_NAME] {
            let metadata = fs::metadata(root.path().join(name)).unwrap();
            assert!(metadata.is_dir());
            #[cfg(unix)]
            {
                use std::os::unix::fs::PermissionsExt;
                assert_eq!(metadata.permissions().mode() & 0o777, 0o700);
            }
        }
        // Opening again is fine.
        ChunkStore::open(root.path()).unwrap();
    }

    #[test]
    fn path_uses_two_level_fan_out() {
        let (root, store) = open_test_store();
        let hash = ChunkHash([0xab; 32]);
        let hex_name = "ab".repeat(32);
        assert_eq!(
            store.path_for(&hash),
            root.path()
                .join("chunks")
                .join("ab")
                .join("ab")
                .join(hex_name)
        );
    }

    #[test]
    fn hash_mismatch_writes_nothing() {
        let (root, store) = open_test_store();
        let wrong_hash = hash_of(b"other data");
        assert!(matches!(
            store.put(&wrong_hash, b"data"),
            Err(StoreError::HashMismatch)
        ));
        assert!(matches!(
            store.replace(&wrong_hash, b"data"),
            Err(StoreError::HashMismatch)
        ));
        assert_eq!(count_files(&root.path().join("chunks")), 0);
        assert_eq!(count_files(&root.path().join("tmp")), 0);
    }

    #[test]
    fn put_then_read_and_put_again() {
        let (root, store) = open_test_store();
        let data = b"chunk bytes".to_vec();
        let hash = hash_of(&data);
        assert!(!store.has(&hash).unwrap());
        assert_eq!(store.put(&hash, &data).unwrap(), PutOutcome::Stored);
        assert_eq!(store.put(&hash, &data).unwrap(), PutOutcome::AlreadyStored);
        assert!(store.has(&hash).unwrap());
        assert_eq!(store.read(&hash).unwrap(), data);
        assert_eq!(store.verify(&hash).unwrap(), ChunkHealth::Ok);
        assert_eq!(count_files(&root.path().join("chunks")), 1);
        assert_eq!(count_files(&root.path().join("tmp")), 0);
    }

    #[test]
    fn missing_chunk() {
        let (_root, store) = open_test_store();
        let hash = hash_of(b"never stored");
        assert_eq!(store.verify(&hash).unwrap(), ChunkHealth::Missing);
        assert!(matches!(store.read(&hash), Err(StoreError::NotFound)));
    }

    #[test]
    fn replace_repairs_a_corrupted_chunk() {
        let (_root, store) = open_test_store();
        let data = vec![7_u8; 4096];
        let hash = hash_of(&data);
        store.put(&hash, &data).unwrap();

        let mut on_disk = fs::read(store.path_for(&hash)).unwrap();
        on_disk[100] ^= 0x01;
        fs::write(store.path_for(&hash), &on_disk).unwrap();
        assert_eq!(store.verify(&hash).unwrap(), ChunkHealth::Bad);
        // `put` does not look inside an existing file.
        assert_eq!(store.put(&hash, &data).unwrap(), PutOutcome::AlreadyStored);

        store.replace(&hash, &data).unwrap();
        assert_eq!(store.verify(&hash).unwrap(), ChunkHealth::Ok);
        assert_eq!(store.read(&hash).unwrap(), data);
    }

    #[test]
    fn crash_before_rename_leaves_only_a_tmp_file() {
        let (root, store) = open_test_store();
        let data = b"half written".to_vec();
        let hash = hash_of(&data);
        store.crash_before_rename.store(true, Ordering::SeqCst);
        assert!(store.put(&hash, &data).is_err());
        assert!(!store.has(&hash).unwrap());
        assert_eq!(count_files(&root.path().join("chunks")), 0);
        assert_eq!(count_files(&root.path().join("tmp")), 1);

        // A young temp file is kept, an old enough one is removed.
        assert_eq!(store.sweep_tmp(Duration::from_secs(3600)).unwrap(), 0);
        assert_eq!(store.sweep_tmp(Duration::ZERO).unwrap(), 1);
        assert_eq!(count_files(&root.path().join("tmp")), 0);

        // The store still works after the "restart".
        store.crash_before_rename.store(false, Ordering::SeqCst);
        assert_eq!(store.put(&hash, &data).unwrap(), PutOutcome::Stored);
    }

    #[test]
    fn two_threads_putting_the_same_chunk() {
        let (root, store) = open_test_store();
        let store = Arc::new(store);
        let data: Arc<Vec<u8>> = Arc::new(
            (0..100_000_u32)
                .map(|value| value.to_le_bytes()[0])
                .collect(),
        );
        let hash = hash_of(&data);
        let barrier = Arc::new(std::sync::Barrier::new(2));
        let handles: Vec<_> = (0..2)
            .map(|_| {
                let store = Arc::clone(&store);
                let data = Arc::clone(&data);
                let barrier = Arc::clone(&barrier);
                std::thread::spawn(move || {
                    barrier.wait();
                    store.put(&hash, &data).unwrap()
                })
            })
            .collect();
        for handle in handles {
            handle.join().unwrap();
        }
        assert_eq!(store.verify(&hash).unwrap(), ChunkHealth::Ok);
        assert_eq!(count_files(&root.path().join("chunks")), 1);
        assert_eq!(count_files(&root.path().join("tmp")), 0);
    }

    #[test]
    fn disk_full_errors_map_to_disk_full() {
        let error = StoreError::from(io::Error::from(io::ErrorKind::StorageFull));
        assert!(matches!(error, StoreError::DiskFull));
        let error = StoreError::from(io::Error::from_raw_os_error(NO_SPACE_ERROR_NUMBER));
        assert!(matches!(error, StoreError::DiskFull));
        let error = StoreError::from(io::Error::from(io::ErrorKind::PermissionDenied));
        assert!(matches!(error, StoreError::Io(_)));
    }
}
