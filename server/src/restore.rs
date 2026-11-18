//! `haotrannas-server restore`: copies one backed-up file out of the store,
//! offline (no running server needed; it may run alongside one).
//!
//! ```text
//!  catalog (read-only) ─► version + chunk list
//!  for each chunk: read file ─► re-hash = its name ─► append to temp file
//!  whole file hash = file_sha256 ─► fsync ─► rename (or no-clobber link) ─► fsync folder
//! ```
//!
//! A damaged or missing chunk, or a whole-file hash mismatch, stops the
//! restore and deletes the temp file: a wrong file is never left at the
//! output path.

use std::fs::{self, File, OpenOptions};
use std::io::{self, Write};
use std::path::{Path, PathBuf};

use anyhow::{Context, bail};
use haotrannas_core::chunker::{expected_chunk_size_bytes, hash_bytes};
use haotrannas_core::limits::HASH_BYTES;
use sha2::{Digest, Sha256};

use crate::catalog::reader::{CatalogReader, VersionRecord};
use crate::chunk_store::{ChunkStore, StoreError};
use crate::data_folder::DataFolder;

/// What to restore and where.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RestoreRequest {
    /// Device whose backup to read.
    pub device_id: u64,
    /// Backup path of the file.
    pub path: String,
    /// The version; `None` = the latest.
    pub version_id: Option<u64>,
    /// Where to write the file.
    pub output_path: PathBuf,
    /// Replace an existing file at `output_path`.
    pub is_overwrite_allowed: bool,
}

/// What was restored.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RestoreSummary {
    pub path: String,
    pub version_id: u64,
    pub size_bytes: u64,
    pub file_sha256: [u8; HASH_BYTES],
}

impl RestoreSummary {
    /// `restored <path> version <id> (<size> bytes, sha256 <hex>)`.
    pub fn line(&self) -> String {
        format!(
            "restored {} version {} ({} bytes, sha256 {})",
            self.path,
            self.version_id,
            self.size_bytes,
            hex::encode(self.file_sha256)
        )
    }
}

/// Restores one file version to `request.output_path`.
pub fn restore_file(
    data_folder: &DataFolder,
    request: &RestoreRequest,
) -> anyhow::Result<RestoreSummary> {
    if !data_folder.is_initialized() {
        bail!(
            "{} is not a data folder (no index.sqlite)",
            data_folder.root_directory().display()
        );
    }
    let reader = CatalogReader::new(&data_folder.database_path());
    let version = match request.version_id {
        Some(version_id) => reader.version_of_file(request.device_id, &request.path, version_id),
        None => reader.latest_version(request.device_id, &request.path),
    }
    .context("cannot read the catalog")?;
    let Some(version) = version else {
        let which_version = request
            .version_id
            .map_or_else(|| "any version".to_owned(), |id| format!("version {id}"));
        bail!(
            "no backup of {:?} ({which_version}) for device {}",
            request.path,
            request.device_id
        );
    };
    if !request.is_overwrite_allowed && request.output_path.symlink_metadata().is_ok() {
        bail!(
            "{} already exists; refusing to overwrite it (use --force)",
            request.output_path.display()
        );
    }

    let chunk_store =
        ChunkStore::open(data_folder.root_directory()).context("cannot open the chunk store")?;
    let output_directory = match request.output_path.parent() {
        Some(parent) if !parent.as_os_str().is_empty() => parent.to_path_buf(),
        _ => PathBuf::from("."),
    };
    let output_file_name = request
        .output_path
        .file_name()
        .with_context(|| format!("{} has no file name", request.output_path.display()))?;
    let tmp_path = output_directory.join(format!(
        ".{}.restore-{:016x}.tmp",
        output_file_name.to_string_lossy(),
        rand::random::<u64>()
    ));
    let mut tmp_file_guard = TmpFileGuard {
        path: &tmp_path,
        is_armed: true,
    };
    let mut tmp_file = OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(&tmp_path)
        .with_context(|| format!("cannot create {}", tmp_path.display()))?;
    let file_sha256 = write_verified_chunks(&chunk_store, &version, &mut tmp_file, &tmp_path)?;
    tmp_file
        .sync_all()
        .with_context(|| format!("cannot fsync {}", tmp_path.display()))?;
    drop(tmp_file);

    place_output(
        &tmp_path,
        &request.output_path,
        request.is_overwrite_allowed,
    )?;
    tmp_file_guard.is_armed = false;
    File::open(&output_directory)
        .and_then(|directory| directory.sync_all())
        .with_context(|| format!("cannot fsync {}", output_directory.display()))?;

    Ok(RestoreSummary {
        path: request.path.clone(),
        version_id: version.version_id,
        size_bytes: version.size_bytes,
        file_sha256,
    })
}

/// Appends every chunk of `version` to `tmp_file`, checking each chunk's
/// hash and size, then the whole file's size and hash. Returns the file's
/// SHA-256.
fn write_verified_chunks(
    chunk_store: &ChunkStore,
    version: &VersionRecord,
    tmp_file: &mut File,
    tmp_path: &Path,
) -> anyhow::Result<[u8; HASH_BYTES]> {
    let mut file_hasher = Sha256::new();
    let mut written_bytes: u64 = 0;
    for (chunk_index, chunk_hash) in version.chunk_hashes.iter().enumerate() {
        let chunk_bytes = match chunk_store.read(chunk_hash) {
            Ok(chunk_bytes) => chunk_bytes,
            Err(StoreError::NotFound) => {
                bail!("chunk {chunk_index} ({chunk_hash}) is missing from the store; not restored")
            }
            Err(error) => {
                return Err(error).with_context(|| format!("cannot read chunk {chunk_hash}"));
            }
        };
        if hash_bytes(&chunk_bytes) != chunk_hash.0 {
            bail!("chunk {chunk_index} ({chunk_hash}) is damaged on disk; not restored");
        }
        let expected_size_bytes = u32::try_from(chunk_index)
            .ok()
            .and_then(|index| expected_chunk_size_bytes(version.size_bytes, index));
        if expected_size_bytes.map(|size_bytes| size_bytes as usize) != Some(chunk_bytes.len()) {
            bail!("chunk {chunk_index} ({chunk_hash}) has the wrong size for this file");
        }
        tmp_file
            .write_all(&chunk_bytes)
            .with_context(|| format!("cannot write {}", tmp_path.display()))?;
        file_hasher.update(&chunk_bytes);
        written_bytes += chunk_bytes.len() as u64;
    }
    let file_sha256: [u8; HASH_BYTES] = file_hasher.finalize().into();
    if written_bytes != version.size_bytes || file_sha256 != version.file_sha256 {
        bail!(
            "restored bytes do not match the backup (size {written_bytes} of {}, sha256 {} instead of {}); not restored",
            version.size_bytes,
            hex::encode(file_sha256),
            hex::encode(version.file_sha256)
        );
    }
    Ok(file_sha256)
}

/// Moves the finished temp file to `output_path`: a rename when
/// overwriting is allowed, else a no-clobber hard link.
fn place_output(
    tmp_path: &Path,
    output_path: &Path,
    is_overwrite_allowed: bool,
) -> anyhow::Result<()> {
    if is_overwrite_allowed {
        return fs::rename(tmp_path, output_path)
            .with_context(|| format!("cannot rename into {}", output_path.display()));
    }
    // A hard link fails if the name exists, so a file that appeared after
    // the first check is still never overwritten.
    match fs::hard_link(tmp_path, output_path) {
        Ok(()) => {}
        Err(error) if error.kind() == io::ErrorKind::AlreadyExists => bail!(
            "{} already exists; refusing to overwrite it (use --force)",
            output_path.display()
        ),
        Err(error) => {
            return Err(error).with_context(|| format!("cannot create {}", output_path.display()));
        }
    }
    fs::remove_file(tmp_path).with_context(|| format!("cannot remove {}", tmp_path.display()))
}

/// Removes the temp file when dropped, unless disarmed.
struct TmpFileGuard<'path> {
    path: &'path Path,
    is_armed: bool,
}

impl Drop for TmpFileGuard<'_> {
    fn drop(&mut self) {
        if self.is_armed {
            let _ = fs::remove_file(self.path);
        }
    }
}

#[cfg(test)]
mod tests {
    use haotrannas_core::chunker::{ChunkHash, chunk_reader};
    use haotrannas_core::limits::CHUNK_SIZE_BYTES;

    use super::*;
    use crate::catalog::schema;
    use crate::catalog::writer::{self, FileOfferInput};

    struct BackedUpFile {
        _parent: tempfile::TempDir,
        data_folder: DataFolder,
        output_directory: PathBuf,
        file_bytes: Vec<u8>,
        version_id: u64,
    }

    /// A data folder holding one committed file `a/b.bin` of device 1.
    fn back_up_one_file(size_bytes: usize) -> BackedUpFile {
        let parent = tempfile::tempdir().unwrap();
        let data_folder = DataFolder::new(parent.path().join("data"));
        data_folder.initialize().unwrap();
        let output_directory = parent.path().join("out");
        fs::create_dir(&output_directory).unwrap();
        let file_bytes: Vec<u8> = (0..size_bytes)
            .map(|index| u8::try_from(index % 253).unwrap())
            .collect();
        let chunk_list = chunk_reader(file_bytes.as_slice()).unwrap();

        let mut connection = schema::open_writer_connection(&data_folder.database_path()).unwrap();
        let device_id = writer::add_device(&mut connection, "dev", &[0; 32], 0).unwrap();
        let store = ChunkStore::open(data_folder.root_directory()).unwrap();
        for (chunk_index, chunk_bytes) in file_bytes.chunks(CHUNK_SIZE_BYTES as usize).enumerate() {
            let hash = chunk_list.chunk_hashes[chunk_index];
            store.put(&hash, chunk_bytes).unwrap();
            writer::record_chunk(&mut connection, &hash, chunk_bytes.len() as u64, 0).unwrap();
        }
        let offer = FileOfferInput {
            path: "a/b.bin".to_owned(),
            size_bytes: chunk_list.size_bytes,
            modified_time_ms: 5,
            file_sha256: chunk_list.file_sha256,
            chunk_hashes: chunk_list.chunk_hashes,
        };
        let outcome = writer::offer_file(&mut connection, device_id, &offer, 0).unwrap();
        let version_id =
            writer::commit_upload(&mut connection, device_id, outcome.upload_id, 0).unwrap();
        BackedUpFile {
            _parent: parent,
            data_folder,
            output_directory,
            file_bytes,
            version_id,
        }
    }

    fn request(backup: &BackedUpFile, output_name: &str) -> RestoreRequest {
        RestoreRequest {
            device_id: 1,
            path: "a/b.bin".to_owned(),
            version_id: None,
            output_path: backup.output_directory.join(output_name),
            is_overwrite_allowed: false,
        }
    }

    fn output_folder_entries(backup: &BackedUpFile) -> Vec<String> {
        let mut names: Vec<String> = fs::read_dir(&backup.output_directory)
            .unwrap()
            .map(|entry| entry.unwrap().file_name().to_string_lossy().into_owned())
            .collect();
        names.sort();
        names
    }

    #[test]
    fn restores_byte_equal_files_of_edge_sizes() {
        for size_bytes in [
            0,
            1,
            CHUNK_SIZE_BYTES as usize,
            2 * CHUNK_SIZE_BYTES as usize + 9,
        ] {
            let backup = back_up_one_file(size_bytes);
            let summary = restore_file(&backup.data_folder, &request(&backup, "copy")).unwrap();
            assert_eq!(summary.version_id, backup.version_id);
            assert_eq!(summary.size_bytes, size_bytes as u64);
            assert_eq!(
                fs::read(backup.output_directory.join("copy")).unwrap(),
                backup.file_bytes
            );
            assert_eq!(output_folder_entries(&backup), vec!["copy"]);
            assert!(summary.line().starts_with(&format!(
                "restored a/b.bin version {} ({size_bytes} bytes, sha256 ",
                backup.version_id
            )));
        }
    }

    #[test]
    fn refuses_to_overwrite_without_force() {
        let backup = back_up_one_file(10);
        let output_path = backup.output_directory.join("copy");
        fs::write(&output_path, b"keep me").unwrap();
        let message = restore_file(&backup.data_folder, &request(&backup, "copy"))
            .unwrap_err()
            .to_string();
        assert!(message.contains("--force"), "{message}");
        assert_eq!(fs::read(&output_path).unwrap(), b"keep me");

        let forced = RestoreRequest {
            is_overwrite_allowed: true,
            ..request(&backup, "copy")
        };
        restore_file(&backup.data_folder, &forced).unwrap();
        assert_eq!(fs::read(&output_path).unwrap(), backup.file_bytes);
        assert_eq!(output_folder_entries(&backup), vec!["copy"]);
    }

    #[test]
    fn damaged_chunk_is_refused_and_no_file_is_left() {
        let backup = back_up_one_file(CHUNK_SIZE_BYTES as usize + 1);
        let store = ChunkStore::open(backup.data_folder.root_directory()).unwrap();
        let first_hash = ChunkHash::of_bytes(&backup.file_bytes[..CHUNK_SIZE_BYTES as usize]);
        let chunk_path = store.path_for(&first_hash);
        let mut on_disk = fs::read(&chunk_path).unwrap();
        on_disk[0] ^= 0x80;
        fs::write(&chunk_path, &on_disk).unwrap();

        let message = restore_file(&backup.data_folder, &request(&backup, "copy"))
            .unwrap_err()
            .to_string();
        assert!(message.contains("damaged"), "{message}");
        assert!(
            output_folder_entries(&backup).is_empty(),
            "temp file removed"
        );
    }

    #[test]
    fn unknown_path_or_version_is_not_found() {
        let backup = back_up_one_file(10);
        let other_path = RestoreRequest {
            path: "nope".to_owned(),
            ..request(&backup, "copy")
        };
        assert!(
            restore_file(&backup.data_folder, &other_path)
                .unwrap_err()
                .to_string()
                .contains("no backup")
        );
        let other_version = RestoreRequest {
            version_id: Some(backup.version_id + 1),
            ..request(&backup, "copy")
        };
        assert!(restore_file(&backup.data_folder, &other_version).is_err());
        let same_version = RestoreRequest {
            version_id: Some(backup.version_id),
            ..request(&backup, "copy")
        };
        restore_file(&backup.data_folder, &same_version).unwrap();
    }
}
