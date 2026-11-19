//! `upload`: back up one file (protocol spec section 8).
//!
//! ```text
//!  hash the file once (streaming) ─► FileOffer ─► NeedChunks
//!     existing version ≠ 0 → "already backed up"
//!     for each missing index: read that chunk again, re-hash (file changed? stop)
//!                             ─► ChunkData ─► ChunkOk
//!  Commit ─► CommitOk  ("uploaded ...")
//!     CHUNKS_MISSING → offer again (at most MAX_OFFER_ROUNDS offers)
//! ```
//!
//! Test switches: `--stop-after-chunks N` ends after N chunks without
//! `Commit` (a dropped connection); `--drop-after-commit` sends `Commit` and
//! disconnects without reading `CommitOk` (a lost reply).

use std::fs::File;
use std::io::{Read, Seek, SeekFrom};
use std::path::{Path, PathBuf};
use std::time::{Duration, UNIX_EPOCH};

use anyhow::{Context, bail};
use haotrannas_core::chunker::{ChunkHash, ChunkList, chunk_reader, expected_chunk_size_bytes};
use haotrannas_core::error_code::ErrorCode;
use haotrannas_core::limits::{CHUNK_SIZE_BYTES, commit_timeout_ms};
use haotrannas_core::message::Message;
use haotrannas_core::path_rules::validate_path;

use crate::connection::{ClientError, Connection, Transport, open_connection, unexpected_reply};

/// Device name the cli gives in `Hello`.
const CLI_DEVICE_NAME: &str = "haotrannas-cli";
/// Most `FileOffer`s for one file (the first plus re-offers after
/// `CHUNKS_MISSING`).
const MAX_OFFER_ROUNDS: u32 = 3;

/// What the person asked for.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct UploadRequest {
    /// Local file to back up.
    pub file_path: PathBuf,
    /// Backup path; the file name when `None`.
    pub remote_path: Option<String>,
    /// Stop after this many chunks without `Commit`.
    pub stop_after_chunks: Option<u32>,
    /// Send `Commit` and disconnect without reading the reply.
    pub is_drop_after_commit: bool,
}

/// How the upload ended (each prints one summary line).
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum UploadOutcome {
    /// The server already had this exact file.
    AlreadyBackedUp { version_id: u64 },
    /// Committed.
    Uploaded {
        sent_chunks: u32,
        total_chunks: usize,
        new_bytes: u64,
        version_id: u64,
    },
    /// `--stop-after-chunks`: stopped before `Commit`.
    Stopped { sent_chunks: u32 },
    /// `--drop-after-commit`: `Commit` sent, reply not read.
    CommitSentReplyDropped {
        sent_chunks: u32,
        total_chunks: usize,
        new_bytes: u64,
    },
}

impl UploadOutcome {
    /// The one summary line printed on stdout.
    pub fn summary_line(&self) -> String {
        match self {
            Self::AlreadyBackedUp { version_id } => {
                format!("already backed up: version {version_id}")
            }
            Self::Uploaded {
                sent_chunks,
                total_chunks,
                new_bytes,
                version_id,
            } => format!(
                "uploaded {sent_chunks} of {total_chunks} chunks ({new_bytes} bytes), version {version_id}"
            ),
            Self::Stopped { sent_chunks } => {
                format!("stopped after {sent_chunks} chunks (no commit)")
            }
            Self::CommitSentReplyDropped {
                sent_chunks,
                total_chunks,
                new_bytes,
            } => format!(
                "uploaded {sent_chunks} of {total_chunks} chunks ({new_bytes} bytes), commit sent, reply not read"
            ),
        }
    }
}

/// The local file: its hashes and an open handle to read chunks again.
struct LocalFile {
    file: File,
    chunk_list: ChunkList,
    modified_time_ms: i64,
}

impl LocalFile {
    /// Opens the file and hashes it in one streaming pass.
    fn open(file_path: &Path) -> anyhow::Result<Self> {
        let mut file = File::open(file_path)
            .with_context(|| format!("cannot open {}", file_path.display()))?;
        let metadata = file.metadata()?;
        if !metadata.is_file() {
            bail!("{} is not a regular file", file_path.display());
        }
        let modified_time_ms = metadata
            .modified()
            .map(system_time_to_unix_ms)
            .with_context(|| format!("cannot read the modified time of {}", file_path.display()))?;
        let chunk_list = chunk_reader(&mut file)
            .with_context(|| format!("cannot read {}", file_path.display()))?;
        Ok(Self {
            file,
            chunk_list,
            modified_time_ms,
        })
    }

    /// Reads chunk `chunk_index` again and checks it still hashes to what
    /// was offered.
    fn read_checked_chunk(&mut self, chunk_index: u32) -> anyhow::Result<(ChunkHash, Vec<u8>)> {
        let offered_hash = *self
            .chunk_list
            .chunk_hashes
            .get(chunk_index as usize)
            .with_context(|| {
                format!("server asked for chunk {chunk_index}, which does not exist")
            })?;
        let size_bytes = expected_chunk_size_bytes(self.chunk_list.size_bytes, chunk_index)
            .context("chunk index out of range")?;
        let mut chunk_bytes = vec![0_u8; size_bytes as usize];
        self.file
            .seek(SeekFrom::Start(
                u64::from(chunk_index) * u64::from(CHUNK_SIZE_BYTES),
            ))
            .context("cannot seek in the file")?;
        let is_read_whole = match self.file.read_exact(&mut chunk_bytes) {
            Ok(()) => true,
            Err(error) if error.kind() == std::io::ErrorKind::UnexpectedEof => false,
            Err(error) => return Err(error).context("cannot read the file"),
        };
        if !is_read_whole || ChunkHash::of_bytes(&chunk_bytes) != offered_hash {
            bail!("file changed during upload (chunk {chunk_index}); run the upload again");
        }
        Ok((offered_hash, chunk_bytes))
    }
}

/// Runs the upload and returns how it ended.
pub async fn run_upload(
    server_address: &str,
    transport: &Transport,
    request: &UploadRequest,
) -> anyhow::Result<UploadOutcome> {
    let remote_path = remote_path_for(request)?;
    let mut local_file = LocalFile::open(&request.file_path)?;
    let total_chunks = local_file.chunk_list.chunk_hashes.len();

    let mut connection = open_connection(server_address, transport, CLI_DEVICE_NAME).await?;
    let offer = Message::FileOffer {
        path: remote_path,
        size_bytes: local_file.chunk_list.size_bytes,
        modified_time_ms: local_file.modified_time_ms,
        file_sha256: local_file.chunk_list.file_sha256,
        chunk_hashes: local_file.chunk_list.chunk_hashes.clone(),
    };

    let mut sent_chunks: u32 = 0;
    let mut new_bytes: u64 = 0;
    for offer_round in 1..=MAX_OFFER_ROUNDS {
        let (upload_id, existing_version_id, missing_indexes) =
            match connection.request(&offer).await? {
                Message::NeedChunks {
                    upload_id,
                    existing_version_id,
                    missing_indexes,
                } => (upload_id, existing_version_id, missing_indexes),
                other => return Err(unexpected_reply(&other).into()),
            };
        if existing_version_id != 0 {
            connection.close().await;
            return Ok(UploadOutcome::AlreadyBackedUp {
                version_id: existing_version_id,
            });
        }

        for chunk_index in missing_indexes {
            if request.stop_after_chunks == Some(sent_chunks) {
                break;
            }
            new_bytes +=
                send_chunk(&mut connection, &mut local_file, upload_id, chunk_index).await?;
            sent_chunks += 1;
        }
        if request.stop_after_chunks.is_some() {
            // Simulates a dropped connection: no Commit, no Close.
            drop(connection);
            return Ok(UploadOutcome::Stopped { sent_chunks });
        }

        let commit = Message::Commit { upload_id };
        if request.is_drop_after_commit {
            connection.send_without_reply(&commit).await?;
            drop(connection);
            return Ok(UploadOutcome::CommitSentReplyDropped {
                sent_chunks,
                total_chunks,
                new_bytes,
            });
        }
        let commit_timeout =
            Duration::from_millis(commit_timeout_ms(local_file.chunk_list.size_bytes));
        match connection
            .request_with_timeout(&commit, commit_timeout)
            .await
        {
            Ok(Message::CommitOk { version_id }) => {
                connection.close().await;
                return Ok(UploadOutcome::Uploaded {
                    sent_chunks,
                    total_chunks,
                    new_bytes,
                    version_id,
                });
            }
            Ok(other) => return Err(unexpected_reply(&other).into()),
            Err(ClientError::ServerError { code, message })
                if code == ErrorCode::ChunksMissing.code() =>
            {
                tracing::info!(offer_round, %message, "chunks missing at commit; offering again");
            }
            Err(error) => return Err(error.into()),
        }
    }
    bail!("the server still reported missing chunks after {MAX_OFFER_ROUNDS} offers")
}

/// The backup path: `--as`, else the file name. Checked against the path
/// rules here too (both sides check them).
fn remote_path_for(request: &UploadRequest) -> anyhow::Result<String> {
    let remote_path = match &request.remote_path {
        Some(remote_path) => remote_path.clone(),
        None => request
            .file_path
            .file_name()
            .and_then(|name| name.to_str())
            .with_context(|| {
                format!(
                    "{} has no UTF-8 file name; give --as <remote-path>",
                    request.file_path.display()
                )
            })?
            .to_owned(),
    };
    validate_path(&remote_path).with_context(|| format!("bad remote path {remote_path:?}"))?;
    Ok(remote_path)
}

/// Reads one chunk again (checking it did not change), sends it and waits
/// for its `ChunkOk`. Returns the bytes sent.
async fn send_chunk<Stream>(
    connection: &mut Connection<Stream>,
    local_file: &mut LocalFile,
    upload_id: u64,
    chunk_index: u32,
) -> anyhow::Result<u64>
where
    Stream: tokio::io::AsyncRead + tokio::io::AsyncWrite + Unpin,
{
    let (chunk_sha256, data) = local_file.read_checked_chunk(chunk_index)?;
    let data_bytes = data.len() as u64;
    let chunk_data = Message::ChunkData {
        upload_id,
        chunk_index,
        chunk_sha256,
        data,
    };
    match connection.request(&chunk_data).await? {
        Message::ChunkOk {
            chunk_index: confirmed_index,
            chunk_sha256: confirmed_hash,
        } if confirmed_index == chunk_index && confirmed_hash == chunk_sha256 => Ok(data_bytes),
        other => Err(unexpected_reply(&other).into()),
    }
}

/// A file time as ms since the Unix epoch (negative before 1970).
fn system_time_to_unix_ms(time: std::time::SystemTime) -> i64 {
    match time.duration_since(UNIX_EPOCH) {
        Ok(since_epoch) => i64::try_from(since_epoch.as_millis()).unwrap_or(i64::MAX),
        Err(before_epoch) => {
            i64::try_from(before_epoch.duration().as_millis()).map_or(i64::MIN, |ms| -ms)
        }
    }
}

#[cfg(test)]
mod tests {
    use std::io::Write;
    use std::time::{Duration, SystemTime};

    use super::*;

    #[test]
    fn summary_lines() {
        assert_eq!(
            UploadOutcome::AlreadyBackedUp { version_id: 7 }.summary_line(),
            "already backed up: version 7"
        );
        assert_eq!(
            UploadOutcome::Uploaded {
                sent_chunks: 3,
                total_chunks: 5,
                new_bytes: 100,
                version_id: 9
            }
            .summary_line(),
            "uploaded 3 of 5 chunks (100 bytes), version 9"
        );
        assert_eq!(
            UploadOutcome::Stopped { sent_chunks: 2 }.summary_line(),
            "stopped after 2 chunks (no commit)"
        );
    }

    #[test]
    fn times_before_1970_are_negative() {
        assert_eq!(system_time_to_unix_ms(UNIX_EPOCH), 0);
        assert_eq!(
            system_time_to_unix_ms(UNIX_EPOCH + Duration::from_millis(1500)),
            1500
        );
        assert_eq!(
            system_time_to_unix_ms(UNIX_EPOCH - Duration::from_millis(20)),
            -20
        );
        assert!(system_time_to_unix_ms(SystemTime::now()) > 1_700_000_000_000);
    }

    #[test]
    fn chunks_are_read_again_and_a_change_is_caught() {
        let folder = tempfile::tempdir().unwrap();
        let file_path = folder.path().join("data.bin");
        let file_bytes: Vec<u8> = (0..(CHUNK_SIZE_BYTES as usize + 10))
            .map(|index| u8::try_from(index % 241).unwrap())
            .collect();
        std::fs::write(&file_path, &file_bytes).unwrap();

        let mut local_file = LocalFile::open(&file_path).unwrap();
        assert_eq!(local_file.chunk_list.chunk_hashes.len(), 2);
        let (hash, chunk_bytes) = local_file.read_checked_chunk(1).unwrap();
        assert_eq!(chunk_bytes, &file_bytes[CHUNK_SIZE_BYTES as usize..]);
        assert_eq!(hash, local_file.chunk_list.chunk_hashes[1]);
        assert!(local_file.read_checked_chunk(2).is_err());

        // Change one byte of chunk 0 after the hashing pass.
        let mut writer = std::fs::OpenOptions::new()
            .write(true)
            .open(&file_path)
            .unwrap();
        writer.write_all(&[0xFF]).unwrap();
        let message = local_file.read_checked_chunk(0).unwrap_err().to_string();
        assert!(message.contains("file changed during upload"), "{message}");
        // Chunk 1 is unchanged and still fine.
        local_file.read_checked_chunk(1).unwrap();

        // A file that got shorter is a change too.
        std::fs::write(&file_path, &file_bytes[..100]).unwrap();
        let message = local_file.read_checked_chunk(1).unwrap_err().to_string();
        assert!(message.contains("file changed during upload"), "{message}");
    }
}
