//! `download`: get one backed-up file (spec §9, D-019).
//!
//! ```text
//!  output exists and no --force → stop (nothing sent)
//!  ReadFile(device, path, version) ─► FileManifest
//!  temp file next to the output (created new, removed on any failure)
//!  for each chunk hash, in order:
//!     ReadChunk ─► ChunkContent: same hash, right length, SHA-256(data) = hash
//!     ─► append, feed the whole-file hasher
//!  whole-file SHA-256 = file_sha256 and size right ─► fsync, set mtime
//!  ─► rename over the output (refused if it appeared meanwhile, unless --force)
//! ```

use std::fs::{self, File, OpenOptions};
use std::io::Write;
use std::path::{Path, PathBuf};
use std::time::{Duration, UNIX_EPOCH};

use anyhow::{Context, bail};
use haotrannas_core::chunker::{
    ChunkHash, expected_chunk_count, expected_chunk_size_bytes, hash_bytes,
};
use haotrannas_core::limits::HASH_BYTES;
use haotrannas_core::message::Message;
use haotrannas_core::path_rules::validate_path;
use sha2::{Digest, Sha256};

use crate::connection::{Transport, open_connection, unexpected_reply};

/// Device name the cli gives in `Hello`.
const CLI_DEVICE_NAME: &str = "haotrannas-cli";

/// What the person asked for.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DownloadRequest {
    /// Backup path on the server.
    pub remote_path: String,
    /// Local file to write.
    pub output_path: PathBuf,
    /// 0 = this device.
    pub device_id: u64,
    /// 0 = latest.
    pub version_id: u64,
    /// Replace an existing output file.
    pub is_force: bool,
}

/// What was downloaded.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DownloadOutcome {
    pub version_id: u64,
    pub size_bytes: u64,
    pub chunk_count: usize,
}

impl DownloadOutcome {
    /// The one line printed on success.
    pub fn summary_line(&self, request: &DownloadRequest) -> String {
        format!(
            "downloaded {} version {} ({} bytes, {} chunks) to {}",
            request.remote_path,
            self.version_id,
            self.size_bytes,
            self.chunk_count,
            request.output_path.display()
        )
    }
}

/// A temp file that is deleted when dropped, unless it was renamed into
/// place.
struct TempFile {
    path: PathBuf,
    is_kept: bool,
}

impl Drop for TempFile {
    fn drop(&mut self) {
        if !self.is_kept {
            let _ = fs::remove_file(&self.path);
        }
    }
}

/// Runs the download and returns what it got.
pub async fn run_download(
    server_address: &str,
    transport: &Transport,
    request: &DownloadRequest,
) -> anyhow::Result<DownloadOutcome> {
    if let Err(path_error) = validate_path(&request.remote_path) {
        bail!("bad remote path {:?}: {path_error}", request.remote_path);
    }
    refuse_overwrite(request)?;
    let mut connection = open_connection(server_address, transport, CLI_DEVICE_NAME).await?;
    let read_file = Message::ReadFile {
        device_id: request.device_id,
        path: request.remote_path.clone(),
        version_id: request.version_id,
    };
    let (version_id, size_bytes, modified_time_ms, file_sha256, chunk_hashes) =
        match connection.request(&read_file).await? {
            Message::FileManifest {
                version_id,
                size_bytes,
                modified_time_ms,
                file_sha256,
                chunk_hashes,
            } => (
                version_id,
                size_bytes,
                modified_time_ms,
                file_sha256,
                chunk_hashes,
            ),
            other => return Err(unexpected_reply(&other).into()),
        };
    if chunk_hashes.len() as u64 != expected_chunk_count(size_bytes) {
        bail!(
            "server manifest is inconsistent: {} chunk hashes for {size_bytes} bytes",
            chunk_hashes.len()
        );
    }

    let (mut temp_file, mut output) = create_temp_file(&request.output_path)?;
    let mut file_hasher = Sha256::new();
    for (chunk_index, expected_hash) in chunk_hashes.iter().enumerate() {
        let chunk_index = u32::try_from(chunk_index).context("too many chunks")?;
        let read_chunk = Message::ReadChunk {
            chunk_sha256: *expected_hash,
        };
        let data = match connection
            .request(&read_chunk)
            .await
            .with_context(|| format!("chunk {chunk_index} ({expected_hash})"))?
        {
            Message::ChunkContent { chunk_sha256, data } => {
                check_chunk(chunk_index, expected_hash, &chunk_sha256, &data, size_bytes)?;
                data
            }
            other => return Err(unexpected_reply(&other).into()),
        };
        output
            .write_all(&data)
            .with_context(|| format!("cannot write {}", temp_file.path.display()))?;
        file_hasher.update(&data);
    }
    connection.close().await;

    let whole_file_hash: [u8; HASH_BYTES] = file_hasher.finalize().into();
    if whole_file_hash != file_sha256 {
        bail!("downloaded file's SHA-256 does not match the manifest; nothing written");
    }
    output
        .sync_all()
        .context("cannot flush the downloaded file")?;
    if let Some(modified_time) = system_time_from_ms(modified_time_ms) {
        // Best effort: a file system without mtimes still gets the bytes.
        let _ = output.set_modified(modified_time);
    }
    drop(output);
    refuse_overwrite(request)?;
    fs::rename(&temp_file.path, &request.output_path).with_context(|| {
        format!(
            "cannot move the download into {}",
            request.output_path.display()
        )
    })?;
    temp_file.is_kept = true;
    Ok(DownloadOutcome {
        version_id,
        size_bytes,
        chunk_count: chunk_hashes.len(),
    })
}

/// Fails if the output exists and `--force` was not given.
fn refuse_overwrite(request: &DownloadRequest) -> anyhow::Result<()> {
    if !request.is_force && request.output_path.symlink_metadata().is_ok() {
        bail!(
            "{} already exists; add --force to replace it",
            request.output_path.display()
        );
    }
    Ok(())
}

/// Creates `.<name>.download-<pid>` next to `output_path` (same folder, so
/// the final rename is atomic).
fn create_temp_file(output_path: &Path) -> anyhow::Result<(TempFile, File)> {
    let file_name = output_path
        .file_name()
        .with_context(|| format!("{} is not a file path", output_path.display()))?;
    let temp_name = format!(
        ".{}.download-{}",
        file_name.to_string_lossy(),
        std::process::id()
    );
    let temp_path = output_path.with_file_name(temp_name);
    let file = OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(&temp_path)
        .with_context(|| format!("cannot create {}", temp_path.display()))?;
    Ok((
        TempFile {
            path: temp_path,
            is_kept: false,
        },
        file,
    ))
}

/// Checks one `ChunkContent` against the manifest.
fn check_chunk(
    chunk_index: u32,
    expected_hash: &ChunkHash,
    reply_hash: &ChunkHash,
    data: &[u8],
    file_size_bytes: u64,
) -> anyhow::Result<()> {
    if reply_hash != expected_hash {
        bail!("chunk {chunk_index}: server sent chunk {reply_hash}, asked for {expected_hash}");
    }
    let expected_size_bytes = expected_chunk_size_bytes(file_size_bytes, chunk_index)
        .context("chunk index past the end of the file")?;
    if data.len() != expected_size_bytes as usize {
        bail!(
            "chunk {chunk_index}: {} bytes, expected {expected_size_bytes}",
            data.len()
        );
    }
    if hash_bytes(data) != expected_hash.0 {
        bail!("chunk {chunk_index}: bytes do not match hash {expected_hash}");
    }
    Ok(())
}

/// ms since the Unix epoch as a `SystemTime` (`None` if out of range).
fn system_time_from_ms(unix_time_ms: i64) -> Option<std::time::SystemTime> {
    let since_epoch = Duration::from_millis(unix_time_ms.unsigned_abs());
    if unix_time_ms >= 0 {
        UNIX_EPOCH.checked_add(since_epoch)
    } else {
        UNIX_EPOCH.checked_sub(since_epoch)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn chunk_checks() {
        let data = b"hello".to_vec();
        let hash = ChunkHash::of_bytes(&data);
        assert!(check_chunk(0, &hash, &hash, &data, 5).is_ok());
        let other_hash = ChunkHash([1; 32]);
        assert!(check_chunk(0, &hash, &other_hash, &data, 5).is_err());
        assert!(check_chunk(0, &hash, &hash, &data, 6).is_err());
        assert!(check_chunk(0, &hash, &hash, b"jello", 5).is_err());
        assert!(check_chunk(1, &hash, &hash, &data, 5).is_err());
    }

    #[test]
    fn temp_file_is_removed_unless_kept() {
        let folder = tempfile::tempdir().unwrap();
        let output_path = folder.path().join("out.bin");
        let (temp_file, _file) = create_temp_file(&output_path).unwrap();
        let temp_path = temp_file.path.clone();
        assert!(temp_path.exists());
        drop(temp_file);
        assert!(!temp_path.exists());
    }

    #[test]
    fn existing_output_needs_force() {
        let folder = tempfile::tempdir().unwrap();
        let output_path = folder.path().join("out.bin");
        fs::write(&output_path, b"keep me").unwrap();
        let mut request = DownloadRequest {
            remote_path: "a".to_owned(),
            output_path,
            device_id: 0,
            version_id: 0,
            is_force: false,
        };
        assert!(refuse_overwrite(&request).is_err());
        request.is_force = true;
        assert!(refuse_overwrite(&request).is_ok());
    }
}
