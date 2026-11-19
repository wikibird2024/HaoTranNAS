//! Download (spec §9, D-019): `ReadFile` → `FileManifest`, then the client
//! sends `ReadChunk` → `ChunkContent` for each hash in order. Pull-based:
//! one reply per request, so the client controls resume.
//!
//! ```text
//!  ReadFile   device 0 = caller, unknown device → NOT_FOUND ─► path rules (BAD_PATH)
//!             ─► version 0 = latest, else that version of that file; none → NOT_FOUND
//!  ReadChunk  stored + ok + used by a committed version? no → NOT_FOUND
//!             ─► read the file, re-hash (blocking pool)
//!                 intact  → ChunkContent
//!                 damaged → mark bad in the catalog → NOT_FOUND (bad bytes never leave)
//! ```

use haotrannas_core::chunker::{ChunkHash, hash_bytes};
use haotrannas_core::error_code::ErrorCode;
use haotrannas_core::message::Message;
use haotrannas_core::path_rules::validate_path;

use crate::chunk_store::{ChunkStore, StoreError};
use crate::handlers::browse::{ReadError, read_catalog, resolve_device};
use crate::handlers::upload::UploadStorage;

/// What `ReadFile` asks for.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ReadFileRequest {
    /// 0 = the caller.
    pub device_id: u64,
    /// Backup path.
    pub path: String,
    /// 0 = latest.
    pub version_id: u64,
}

/// Answers `ReadFile` with the version's `FileManifest`.
pub async fn handle_read_file(
    storage: &UploadStorage,
    caller_device_id: u64,
    request: ReadFileRequest,
) -> Result<Message, ReadError> {
    let device_id = resolve_device(storage, caller_device_id, request.device_id).await?;
    if let Err(path_error) = validate_path(&request.path) {
        return Err((ErrorCode::BadPath, path_error.to_string()));
    }
    let path = request.path.clone();
    let version_id = request.version_id;
    let version = read_catalog(&storage.catalog_reader, "ReadFile", move |reader| {
        if version_id == 0 {
            reader.latest_version(device_id, &path)
        } else {
            reader.version_of_file(device_id, &path, version_id)
        }
    })
    .await?;
    let Some(version) = version else {
        let wanted = if request.version_id == 0 {
            "any version".to_owned()
        } else {
            format!("version {}", request.version_id)
        };
        return Err((
            ErrorCode::NotFound,
            format!("no {wanted} of {:?} on device {device_id}", request.path),
        ));
    };
    Ok(Message::FileManifest {
        version_id: version.version_id,
        size_bytes: version.size_bytes,
        modified_time_ms: version.modified_time_ms,
        file_sha256: version.file_sha256,
        chunk_hashes: version.chunk_hashes,
    })
}

/// How reading one chunk file went.
enum ChunkRead {
    /// The bytes hash to the chunk's name.
    Intact(Vec<u8>),
    /// The file is gone or its bytes are wrong.
    Damaged(&'static str),
}

/// Answers `ReadChunk` with `ChunkContent`, re-checking the hash first.
pub async fn handle_read_chunk(
    storage: &UploadStorage,
    chunk_sha256: ChunkHash,
) -> Result<Message, ReadError> {
    let is_readable = read_catalog(&storage.catalog_reader, "ReadChunk", move |reader| {
        reader.is_chunk_readable(&chunk_sha256)
    })
    .await?;
    if !is_readable {
        return Err(chunk_not_found(&chunk_sha256));
    }
    let chunk_store = storage.chunk_store.clone();
    let chunk_read = tokio::task::spawn_blocking(move || read_checked(&chunk_store, &chunk_sha256))
        .await
        .map_err(|join_error| {
            tracing::error!(%join_error, "chunk read task failed");
            (ErrorCode::Internal, "chunk read task failed".to_owned())
        })?
        .map_err(|error| {
            tracing::error!(%error, chunk = %chunk_sha256, "cannot read chunk");
            (ErrorCode::Internal, format!("cannot read a chunk: {error}"))
        })?;
    match chunk_read {
        ChunkRead::Intact(data) => Ok(Message::ChunkContent { chunk_sha256, data }),
        ChunkRead::Damaged(what) => {
            tracing::warn!(chunk = %chunk_sha256, what, "damaged chunk found on download; marking it bad");
            if let Err(error) = storage.catalog_writer.mark_chunk_bad(chunk_sha256).await {
                tracing::error!(%error, chunk = %chunk_sha256, "cannot mark chunk bad");
            }
            Err((
                ErrorCode::NotFound,
                format!(
                    "chunk {chunk_sha256} is damaged on the server ({what}); \
                     the next upload of a file holding it repairs it"
                ),
            ))
        }
    }
}

/// Reads the chunk file and re-hashes it (blocking).
fn read_checked(
    chunk_store: &ChunkStore,
    chunk_sha256: &ChunkHash,
) -> Result<ChunkRead, StoreError> {
    match chunk_store.read(chunk_sha256) {
        Ok(data) if hash_bytes(&data) == chunk_sha256.0 => Ok(ChunkRead::Intact(data)),
        Ok(_) => Ok(ChunkRead::Damaged("bytes do not match the hash")),
        Err(StoreError::NotFound) => Ok(ChunkRead::Damaged("file missing")),
        Err(error) => Err(error),
    }
}

fn chunk_not_found(chunk_sha256: &ChunkHash) -> ReadError {
    (
        ErrorCode::NotFound,
        format!("chunk {chunk_sha256} is not stored, is damaged, or is in no backed-up file"),
    )
}

#[cfg(test)]
mod tests {
    use haotrannas_core::limits::CHUNK_SIZE_BYTES;

    use super::*;
    use crate::catalog::ChunkStatus;
    use crate::data_folder::DEV_DEVICE_ID;
    use crate::handlers::browse::test_support::commit_test_file;
    use crate::handlers::upload::test_support::open_test_storage;
    use crate::handlers::upload::{FileOfferRequest, handle_chunk_data, handle_file_offer};

    fn read_file(path: &str, version_id: u64) -> ReadFileRequest {
        ReadFileRequest {
            device_id: 0,
            path: path.to_owned(),
            version_id,
        }
    }

    fn error_code(result: Result<Message, ReadError>) -> ErrorCode {
        result.expect_err("expected an error").0
    }

    /// `byte[i] = i mod 251`, like the chunking vectors.
    fn file_bytes(size_bytes: usize) -> Vec<u8> {
        (0..size_bytes)
            .map(|index| u8::try_from(index % 251).unwrap())
            .collect()
    }

    #[tokio::test]
    async fn read_file_gives_latest_or_asked_version_and_chunks_rebuild_the_file() {
        let (_folder, storage) = open_test_storage();
        let first_bytes = file_bytes(CHUNK_SIZE_BYTES as usize + 17);
        let (first_version, _) =
            commit_test_file(&storage, DEV_DEVICE_ID, "docs/a.bin", &first_bytes).await;
        let second_bytes = b"changed".to_vec();
        let (second_version, second_list) =
            commit_test_file(&storage, DEV_DEVICE_ID, "docs/a.bin", &second_bytes).await;

        let latest = handle_read_file(&storage, DEV_DEVICE_ID, read_file("docs/a.bin", 0))
            .await
            .unwrap();
        assert_eq!(
            latest,
            Message::FileManifest {
                version_id: second_version,
                size_bytes: 7,
                modified_time_ms: 1_700_000_000_000,
                file_sha256: second_list.file_sha256,
                chunk_hashes: second_list.chunk_hashes,
            }
        );

        let old = handle_read_file(
            &storage,
            DEV_DEVICE_ID,
            read_file("docs/a.bin", first_version),
        )
        .await
        .unwrap();
        let Message::FileManifest {
            version_id,
            chunk_hashes,
            ..
        } = old
        else {
            panic!("expected FileManifest, got {old:?}");
        };
        assert_eq!(version_id, first_version);
        assert_eq!(chunk_hashes.len(), 2);
        let mut rebuilt = Vec::new();
        for hash in chunk_hashes {
            let reply = handle_read_chunk(&storage, hash).await.unwrap();
            let Message::ChunkContent { chunk_sha256, data } = reply else {
                panic!("expected ChunkContent, got {reply:?}");
            };
            assert_eq!(chunk_sha256, hash);
            rebuilt.extend(data);
        }
        assert_eq!(rebuilt, first_bytes);
    }

    #[tokio::test]
    async fn read_file_errors() {
        let (_folder, storage) = open_test_storage();
        let (version_id, _) = commit_test_file(&storage, DEV_DEVICE_ID, "a.txt", b"abc").await;
        let (other_version_id, _) = commit_test_file(&storage, DEV_DEVICE_ID, "b.txt", b"b").await;

        let cases = [
            (read_file("missing.txt", 0), ErrorCode::NotFound),
            (read_file("a.txt", version_id + 100), ErrorCode::NotFound),
            // A version of another file.
            (read_file("a.txt", other_version_id), ErrorCode::NotFound),
            (read_file("", 0), ErrorCode::BadPath),
            (read_file("../a.txt", 0), ErrorCode::BadPath),
            (
                ReadFileRequest {
                    device_id: 77,
                    ..read_file("a.txt", 0)
                },
                ErrorCode::NotFound,
            ),
        ];
        for (request, expected_code) in cases {
            let result = handle_read_file(&storage, DEV_DEVICE_ID, request.clone()).await;
            assert_eq!(error_code(result), expected_code, "{request:?}");
        }
        // The empty file has no chunks.
        let (_, empty_list) = commit_test_file(&storage, DEV_DEVICE_ID, "empty", b"").await;
        let reply = handle_read_file(&storage, DEV_DEVICE_ID, read_file("empty", 0))
            .await
            .unwrap();
        assert!(matches!(
            reply,
            Message::FileManifest { size_bytes: 0, ref chunk_hashes, .. } if chunk_hashes.is_empty()
        ));
        assert!(empty_list.chunk_hashes.is_empty());
    }

    #[tokio::test]
    async fn damaged_chunk_is_marked_bad_and_never_sent() {
        let (_folder, storage) = open_test_storage();
        let (_, chunk_list) = commit_test_file(&storage, DEV_DEVICE_ID, "a.txt", b"hello").await;
        let hash = chunk_list.chunk_hashes[0];
        std::fs::write(storage.chunk_store.path_for(&hash), b"jello").unwrap();

        let result = handle_read_chunk(&storage, hash).await;
        assert_eq!(error_code(result), ErrorCode::NotFound);
        assert_eq!(
            storage.catalog_reader.chunk_status(&hash).unwrap(),
            Some(ChunkStatus::Bad)
        );
        // Bad now: refused before the disk is read.
        std::fs::write(storage.chunk_store.path_for(&hash), b"hello").unwrap();
        assert_eq!(
            error_code(handle_read_chunk(&storage, hash).await),
            ErrorCode::NotFound
        );
    }

    #[tokio::test]
    async fn missing_chunk_file_is_marked_bad() {
        let (_folder, storage) = open_test_storage();
        let (_, chunk_list) = commit_test_file(&storage, DEV_DEVICE_ID, "a.txt", b"hello").await;
        let hash = chunk_list.chunk_hashes[0];
        std::fs::remove_file(storage.chunk_store.path_for(&hash)).unwrap();
        assert_eq!(
            error_code(handle_read_chunk(&storage, hash).await),
            ErrorCode::NotFound
        );
        assert_eq!(
            storage.catalog_reader.chunk_status(&hash).unwrap(),
            Some(ChunkStatus::Bad)
        );
    }

    #[tokio::test]
    async fn chunk_of_an_uncommitted_upload_or_unknown_is_not_found() {
        let (_folder, storage) = open_test_storage();
        let bytes = b"not committed yet".to_vec();
        let hash = ChunkHash::of_bytes(&bytes);
        let offer = FileOfferRequest {
            path: "pending.txt".to_owned(),
            size_bytes: bytes.len() as u64,
            modified_time_ms: 0,
            file_sha256: hash_bytes(&bytes),
            chunk_hashes: vec![hash],
        };
        let Message::NeedChunks { upload_id, .. } =
            handle_file_offer(&storage, DEV_DEVICE_ID, offer)
                .await
                .unwrap()
        else {
            panic!("expected NeedChunks");
        };
        handle_chunk_data(&storage, DEV_DEVICE_ID, upload_id, 0, hash, bytes)
            .await
            .unwrap();
        assert_eq!(
            storage.catalog_reader.chunk_status(&hash).unwrap(),
            Some(ChunkStatus::Ok)
        );
        assert_eq!(
            error_code(handle_read_chunk(&storage, hash).await),
            ErrorCode::NotFound
        );
        assert_eq!(
            error_code(handle_read_chunk(&storage, ChunkHash([3; 32])).await),
            ErrorCode::NotFound
        );
    }
}
