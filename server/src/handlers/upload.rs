//! Upload: `FileOffer` → `NeedChunks`, `ChunkData` → `ChunkOk`,
//! `Commit` → `CommitOk`. Nothing is visible until `Commit`.
//!
//! Every check of protocol spec section 8 runs here, in the spec's order,
//! with the spec's error code. Upload errors are not fatal: the session
//! sends the `Error` and the connection stays open.
//!
//! ```text
//!  FileOffer  path rules ─► chunk count ≤ 65 536 ─► count = ceil(size / 1 MiB) ─► catalog offer
//!  ChunkData  upload is ours ─► index < count ─► hash = offered ─► size right ─► SHA-256(data) = hash
//!             ─► stored+ok: ChunkOk, no write · bad: replace · else: put ─► record chunk ─► ChunkOk
//!  Commit     upload is ours ─► every chunk stored+ok ─► re-hash chunks in order = file_sha256
//!             ─► one catalog transaction ─► CommitOk
//! ```
//!
//! Hashing and chunk files are blocking work: it runs in
//! `tokio::task::spawn_blocking`, never on the async threads.

use std::collections::HashSet;
use std::sync::Arc;
use std::time::{SystemTime, UNIX_EPOCH};

use haotrannas_core::chunker::{
    ChunkHash, expected_chunk_count, expected_chunk_size_bytes, hash_bytes,
};
use haotrannas_core::error_code::ErrorCode;
use haotrannas_core::limits::{HASH_BYTES, MAX_CHUNKS_PER_FILE};
use haotrannas_core::message::Message;
use haotrannas_core::path_rules::validate_path;
use sha2::{Digest, Sha256};

use crate::catalog::reader::CatalogReader;
use crate::catalog::writer::{CatalogWriter, CommitError, FileOfferInput};
use crate::catalog::{CatalogError, ChunkStatus};
use crate::chunk_store::{ChunkHealth, ChunkStore, PutOutcome, StoreError};

/// A non-fatal upload error: the code and the text sent in `Error`.
pub type UploadError = (ErrorCode, String);

/// What the upload handlers need: the chunk files and the catalog.
#[derive(Debug, Clone)]
pub struct UploadStorage {
    /// Chunk files on disk (shared with blocking tasks).
    pub chunk_store: Arc<ChunkStore>,
    /// The single catalog writer.
    pub catalog_writer: CatalogWriter,
    /// Read-only catalog queries.
    pub catalog_reader: CatalogReader,
}

/// The offered file, as decoded from `FileOffer`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FileOfferRequest {
    pub path: String,
    pub size_bytes: u64,
    pub modified_time_ms: i64,
    pub file_sha256: [u8; HASH_BYTES],
    pub chunk_hashes: Vec<ChunkHash>,
}

/// Answers `FileOffer` with `NeedChunks`.
pub async fn handle_file_offer(
    storage: &UploadStorage,
    device_id: u64,
    offer: FileOfferRequest,
) -> Result<Message, UploadError> {
    if let Err(path_error) = validate_path(&offer.path) {
        return Err((ErrorCode::BadPath, path_error.to_string()));
    }
    let offered_chunk_count = offer.chunk_hashes.len();
    let size_chunk_count = expected_chunk_count(offer.size_bytes);
    // Too many chunks, counted either way: the list sent or the size given.
    if offered_chunk_count > MAX_CHUNKS_PER_FILE as usize
        || size_chunk_count > u64::from(MAX_CHUNKS_PER_FILE)
    {
        return Err((
            ErrorCode::TooLarge,
            format!(
                "file has more than {MAX_CHUNKS_PER_FILE} chunks \
                 ({offered_chunk_count} offered, {size_chunk_count} for {} bytes)",
                offer.size_bytes
            ),
        ));
    }
    if offered_chunk_count as u64 != size_chunk_count {
        return Err((
            ErrorCode::BadArgument,
            format!(
                "{offered_chunk_count} chunk hashes offered, but {} bytes need {size_chunk_count}",
                offer.size_bytes
            ),
        ));
    }
    let input = FileOfferInput {
        path: offer.path,
        size_bytes: offer.size_bytes,
        modified_time_ms: offer.modified_time_ms,
        file_sha256: offer.file_sha256,
        chunk_hashes: offer.chunk_hashes,
    };
    let outcome = storage
        .catalog_writer
        .offer_file(device_id, input, unix_time_ms())
        .await
        .map_err(|error| internal_error("FileOffer", &error))?;
    Ok(Message::NeedChunks {
        upload_id: outcome.upload_id,
        existing_version_id: outcome.existing_version_id,
        missing_indexes: outcome.missing_indexes,
    })
}

/// Answers `ChunkData` with `ChunkOk`.
pub async fn handle_chunk_data(
    storage: &UploadStorage,
    device_id: u64,
    upload_id: u64,
    chunk_index: u32,
    chunk_sha256: ChunkHash,
    data: Vec<u8>,
) -> Result<Message, UploadError> {
    let upload = storage
        .catalog_writer
        .upload_info(device_id, upload_id)
        .await
        .map_err(|error| internal_error("ChunkData", &error))?
        .ok_or_else(|| unknown_upload(upload_id))?;
    let chunk_count = upload.chunk_hashes.len();
    let Some(offered_hash) = upload.chunk_hashes.get(chunk_index as usize) else {
        return Err((
            ErrorCode::BadArgument,
            format!(
                "chunk index {chunk_index} is out of range (the file has {chunk_count} chunks)"
            ),
        ));
    };
    if *offered_hash != chunk_sha256 {
        return Err((
            ErrorCode::ChunkHashMismatch,
            format!("chunk {chunk_index}: hash {chunk_sha256} is not the offered {offered_hash}"),
        ));
    }
    let expected_size_bytes = expected_chunk_size_bytes(upload.size_bytes, chunk_index)
        .ok_or_else(|| {
            (
                ErrorCode::Internal,
                format!("no chunk size for index {chunk_index}"),
            )
        })?;
    if data.len() != expected_size_bytes as usize {
        return Err((
            ErrorCode::ChunkSizeWrong,
            format!(
                "chunk {chunk_index} is {} bytes, expected {expected_size_bytes}",
                data.len()
            ),
        ));
    }

    let chunk_store = Arc::clone(&storage.chunk_store);
    let catalog_reader = storage.catalog_reader.clone();
    let stored = tokio::task::spawn_blocking(move || {
        store_chunk(&chunk_store, &catalog_reader, &chunk_sha256, &data)
    })
    .await
    .map_err(|join_error| {
        tracing::error!(%join_error, "chunk store task failed");
        (ErrorCode::Internal, "chunk store task failed".to_owned())
    })??;

    if stored == StoreStep::Written {
        storage
            .catalog_writer
            .record_chunk(chunk_sha256, u64::from(expected_size_bytes), unix_time_ms())
            .await
            .map_err(|error| internal_error("ChunkData", &error))?;
    }
    Ok(Message::ChunkOk {
        chunk_index,
        chunk_sha256,
    })
}

/// What `store_chunk` did.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum StoreStep {
    /// Already stored and marked ok: nothing written, nothing to record.
    AlreadyOk,
    /// Stored (or found intact) now: the catalog must record it as ok.
    Written,
}

/// Blocking part of `ChunkData`: the data hash check, then the write.
fn store_chunk(
    chunk_store: &ChunkStore,
    catalog_reader: &CatalogReader,
    chunk_sha256: &ChunkHash,
    data: &[u8],
) -> Result<StoreStep, UploadError> {
    if hash_bytes(data) != chunk_sha256.0 {
        return Err((
            ErrorCode::ChunkHashMismatch,
            format!("data does not hash to {chunk_sha256}"),
        ));
    }
    let status = catalog_reader
        .chunk_status(chunk_sha256)
        .map_err(|error| internal_error("ChunkData", &error))?;
    let write_outcome = match status {
        Some(ChunkStatus::Ok) => return Ok(StoreStep::AlreadyOk),
        // Marked bad by scrub: overwrite atomically.
        Some(ChunkStatus::Bad) => chunk_store.replace(chunk_sha256, data),
        // Not in the catalog. A file may still be there (a crash between the
        // rename and the catalog write): keep it only if it is intact.
        None => match chunk_store.put(chunk_sha256, data) {
            Ok(PutOutcome::AlreadyStored) => match chunk_store.verify(chunk_sha256) {
                Ok(ChunkHealth::Ok) => Ok(()),
                Ok(_) => chunk_store.replace(chunk_sha256, data),
                Err(error) => Err(error),
            },
            Ok(PutOutcome::Stored) => Ok(()),
            Err(error) => Err(error),
        },
    };
    match write_outcome {
        Ok(()) => Ok(StoreStep::Written),
        Err(StoreError::DiskFull) => Err((
            ErrorCode::DiskFull,
            "no space left to store the chunk".to_owned(),
        )),
        Err(StoreError::HashMismatch) => Err((
            ErrorCode::ChunkHashMismatch,
            format!("data does not hash to {chunk_sha256}"),
        )),
        Err(error) => {
            tracing::error!(%error, chunk = %chunk_sha256, "cannot store chunk");
            Err((
                ErrorCode::Internal,
                format!("cannot store the chunk: {error}"),
            ))
        }
    }
}

/// Answers `Commit` with `CommitOk`.
pub async fn handle_commit(
    storage: &UploadStorage,
    device_id: u64,
    upload_id: u64,
) -> Result<Message, UploadError> {
    let chunk_hashes = storage
        .catalog_writer
        .upload_chunk_hashes(device_id, upload_id)
        .await
        .map_err(|error| internal_error("Commit", &error))?
        .ok_or_else(|| unknown_upload(upload_id))?;
    let file_sha256 = storage
        .catalog_reader
        .upload_file_sha256(device_id, upload_id)
        .map_err(|error| internal_error("Commit", &error))?
        .ok_or_else(|| unknown_upload(upload_id))?;

    let chunk_store = Arc::clone(&storage.chunk_store);
    let catalog_reader = storage.catalog_reader.clone();
    let check = tokio::task::spawn_blocking(move || {
        check_chunks_for_commit(&chunk_store, &catalog_reader, &chunk_hashes, &file_sha256)
    })
    .await
    .map_err(|join_error| {
        tracing::error!(%join_error, "commit check task failed");
        (ErrorCode::Internal, "commit check task failed".to_owned())
    })??;

    match check {
        CommitCheck::Ready => {}
        CommitCheck::DamagedChunks(damaged_hashes) => {
            for hash in &damaged_hashes {
                tracing::warn!(chunk = %hash, "chunk damaged on disk; marking it bad");
                storage
                    .catalog_writer
                    .mark_chunk_bad(*hash)
                    .await
                    .map_err(|error| internal_error("Commit", &error))?;
            }
            return Err(chunks_missing(damaged_hashes.len()));
        }
        CommitCheck::Missing(missing_count) => return Err(chunks_missing(missing_count)),
        CommitCheck::FileHashMismatch => {
            storage
                .catalog_writer
                .delete_upload(device_id, upload_id)
                .await
                .map_err(|error| internal_error("Commit", &error))?;
            return Err((
                ErrorCode::FileHashMismatch,
                "the chunks do not hash to the offered file_sha256; upload dropped".to_owned(),
            ));
        }
    }

    match storage
        .catalog_writer
        .commit_upload(device_id, upload_id, unix_time_ms())
        .await
    {
        Ok(version_id) => Ok(Message::CommitOk { version_id }),
        Err(CommitError::UnknownUpload) => Err(unknown_upload(upload_id)),
        Err(CommitError::ChunksMissing) => Err(chunks_missing(1)),
        Err(CommitError::Catalog(error)) => Err(internal_error("Commit", &error)),
    }
}

/// What the blocking commit check found.
#[derive(Debug, Clone, PartialEq, Eq)]
enum CommitCheck {
    /// Every chunk stored, intact, and the whole file hashes right.
    Ready,
    /// This many distinct chunks are not stored or marked bad.
    Missing(usize),
    /// These chunks are marked ok but their files are damaged or gone.
    DamagedChunks(Vec<ChunkHash>),
    /// The chunks in order do not hash to the offered `file_sha256`.
    FileHashMismatch,
}

/// Blocking part of `Commit`: every distinct chunk stored and ok, then one
/// streaming pass over the chunks in order (one chunk in memory at a time)
/// that re-hashes each chunk and the whole file.
fn check_chunks_for_commit(
    chunk_store: &ChunkStore,
    catalog_reader: &CatalogReader,
    chunk_hashes: &[ChunkHash],
    file_sha256: &[u8; HASH_BYTES],
) -> Result<CommitCheck, UploadError> {
    let distinct_hashes: HashSet<ChunkHash> = chunk_hashes.iter().copied().collect();
    let mut missing_count = 0;
    for hash in &distinct_hashes {
        let status = catalog_reader
            .chunk_status(hash)
            .map_err(|error| internal_error("Commit", &error))?;
        if status != Some(ChunkStatus::Ok) {
            missing_count += 1;
        }
    }
    if missing_count > 0 {
        return Ok(CommitCheck::Missing(missing_count));
    }

    let mut file_hasher = Sha256::new();
    let mut damaged_hashes = Vec::new();
    for hash in chunk_hashes {
        match chunk_store.read(hash) {
            Ok(chunk_bytes) => {
                if hash_bytes(&chunk_bytes) != hash.0 {
                    if !damaged_hashes.contains(hash) {
                        damaged_hashes.push(*hash);
                    }
                    continue;
                }
                file_hasher.update(&chunk_bytes);
            }
            Err(StoreError::NotFound) => {
                if !damaged_hashes.contains(hash) {
                    damaged_hashes.push(*hash);
                }
            }
            Err(error) => {
                tracing::error!(%error, chunk = %hash, "cannot read chunk for commit");
                return Err((ErrorCode::Internal, format!("cannot read a chunk: {error}")));
            }
        }
    }
    if !damaged_hashes.is_empty() {
        return Ok(CommitCheck::DamagedChunks(damaged_hashes));
    }
    let whole_file_hash: [u8; HASH_BYTES] = file_hasher.finalize().into();
    if whole_file_hash == *file_sha256 {
        Ok(CommitCheck::Ready)
    } else {
        Ok(CommitCheck::FileHashMismatch)
    }
}

fn unknown_upload(upload_id: u64) -> UploadError {
    (
        ErrorCode::UnknownUpload,
        format!("no open upload {upload_id} for this device"),
    )
}

fn chunks_missing(missing_count: usize) -> UploadError {
    (
        ErrorCode::ChunksMissing,
        format!("{missing_count} chunk(s) not stored or damaged; offer the file again"),
    )
}

/// Logs a catalog failure and turns it into `INTERNAL`.
fn internal_error(request_name: &str, error: &CatalogError) -> UploadError {
    tracing::error!(%error, request = request_name, "catalog error");
    (ErrorCode::Internal, format!("catalog error: {error}"))
}

/// Now, in ms since the Unix epoch.
fn unix_time_ms() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0, |since_epoch| {
            i64::try_from(since_epoch.as_millis()).unwrap_or(i64::MAX)
        })
}

/// Test helpers shared with the session tests.
#[cfg(test)]
pub mod test_support {
    use super::*;
    use crate::catalog::writer;
    use crate::data_folder::{DEV_DEVICE_CERT_SHA256, DEV_DEVICE_ID, DEV_DEVICE_NAME};

    /// Storage on a fresh temp folder with the dev device (id 1) added.
    pub fn open_test_storage() -> (tempfile::TempDir, UploadStorage) {
        let folder = tempfile::tempdir().unwrap();
        let database_path = folder.path().join("index.sqlite");
        let mut connection =
            crate::catalog::schema::open_writer_connection(&database_path).unwrap();
        let device_id =
            writer::add_device(&mut connection, DEV_DEVICE_NAME, &DEV_DEVICE_CERT_SHA256, 0)
                .unwrap();
        assert_eq!(device_id, DEV_DEVICE_ID);
        let (catalog_writer, _thread) = CatalogWriter::start_with_connection(connection).unwrap();
        let storage = UploadStorage {
            chunk_store: Arc::new(ChunkStore::open(folder.path()).unwrap()),
            catalog_writer,
            catalog_reader: CatalogReader::new(&database_path),
        };
        (folder, storage)
    }
}

#[cfg(test)]
mod tests {
    use haotrannas_core::chunker::chunk_reader;
    use haotrannas_core::limits::CHUNK_SIZE_BYTES;

    use super::test_support::open_test_storage;
    use super::*;
    use crate::data_folder::DEV_DEVICE_ID;

    /// `byte[i] = i mod 251`, like the chunking vectors.
    fn file_bytes(size_bytes: usize) -> Vec<u8> {
        (0..size_bytes)
            .map(|index| u8::try_from(index % 251).unwrap())
            .collect()
    }

    fn offer_for(path: &str, bytes: &[u8]) -> FileOfferRequest {
        let chunk_list = chunk_reader(bytes).unwrap();
        FileOfferRequest {
            path: path.to_owned(),
            size_bytes: chunk_list.size_bytes,
            modified_time_ms: 1_700_000_000_000,
            file_sha256: chunk_list.file_sha256,
            chunk_hashes: chunk_list.chunk_hashes,
        }
    }

    fn chunk_of(bytes: &[u8], chunk_index: usize) -> Vec<u8> {
        let chunk_size = CHUNK_SIZE_BYTES as usize;
        let start = chunk_index * chunk_size;
        bytes[start..(start + chunk_size).min(bytes.len())].to_vec()
    }

    fn expect_code(result: Result<Message, UploadError>, expected: ErrorCode) {
        match result {
            Err((code, _)) => assert_eq!(code, expected),
            Ok(reply) => panic!("expected {}, got {reply:?}", expected.name()),
        }
    }

    /// (upload id, missing indexes) of a new upload.
    async fn offer(storage: &UploadStorage, request: FileOfferRequest) -> (u64, Vec<u32>) {
        match handle_file_offer(storage, DEV_DEVICE_ID, request)
            .await
            .unwrap()
        {
            Message::NeedChunks {
                upload_id,
                existing_version_id: 0,
                missing_indexes,
            } => (upload_id, missing_indexes),
            other => panic!("expected a new upload, got {other:?}"),
        }
    }

    async fn send_chunk(
        storage: &UploadStorage,
        upload_id: u64,
        bytes: &[u8],
        chunk_index: u32,
    ) -> Result<Message, UploadError> {
        let chunk = chunk_of(bytes, chunk_index as usize);
        handle_chunk_data(
            storage,
            DEV_DEVICE_ID,
            upload_id,
            chunk_index,
            ChunkHash::of_bytes(&chunk),
            chunk,
        )
        .await
    }

    #[tokio::test]
    async fn file_offer_checks_in_spec_order() {
        let (_folder, storage) = open_test_storage();
        let bytes = file_bytes(10);
        let mut request = offer_for("../escape", &bytes);
        // A bad path wins over a wrong chunk count.
        request.chunk_hashes.clear();
        expect_code(
            handle_file_offer(&storage, DEV_DEVICE_ID, request).await,
            ErrorCode::BadPath,
        );

        let mut too_many = offer_for("big.bin", &bytes);
        too_many.chunk_hashes = vec![ChunkHash([1; 32]); MAX_CHUNKS_PER_FILE as usize + 1];
        expect_code(
            handle_file_offer(&storage, DEV_DEVICE_ID, too_many).await,
            ErrorCode::TooLarge,
        );
        let mut too_big_size = offer_for("big.bin", &bytes);
        too_big_size.size_bytes = u64::from(MAX_CHUNKS_PER_FILE) * u64::from(CHUNK_SIZE_BYTES) + 1;
        expect_code(
            handle_file_offer(&storage, DEV_DEVICE_ID, too_big_size).await,
            ErrorCode::TooLarge,
        );

        let mut wrong_count = offer_for("a.bin", &bytes);
        wrong_count.size_bytes = u64::from(CHUNK_SIZE_BYTES) + 1;
        expect_code(
            handle_file_offer(&storage, DEV_DEVICE_ID, wrong_count).await,
            ErrorCode::BadArgument,
        );
    }

    #[tokio::test]
    async fn full_upload_then_same_offer_is_already_backed_up() {
        let (_folder, storage) = open_test_storage();
        let bytes = file_bytes(2 * CHUNK_SIZE_BYTES as usize + 5);
        let (upload_id, missing_indexes) = offer(&storage, offer_for("dir/a.bin", &bytes)).await;
        assert_eq!(missing_indexes, vec![0, 1, 2]);
        for chunk_index in missing_indexes {
            let reply = send_chunk(&storage, upload_id, &bytes, chunk_index)
                .await
                .unwrap();
            assert!(
                matches!(reply, Message::ChunkOk { chunk_index: index, .. } if index == chunk_index)
            );
        }
        // Sending a chunk again is safe.
        send_chunk(&storage, upload_id, &bytes, 1).await.unwrap();
        let Message::CommitOk { version_id } = handle_commit(&storage, DEV_DEVICE_ID, upload_id)
            .await
            .unwrap()
        else {
            panic!("expected CommitOk");
        };
        assert!(version_id > 0);
        // The upload is gone after Commit.
        expect_code(
            handle_commit(&storage, DEV_DEVICE_ID, upload_id).await,
            ErrorCode::UnknownUpload,
        );

        let reply = handle_file_offer(&storage, DEV_DEVICE_ID, offer_for("dir/a.bin", &bytes))
            .await
            .unwrap();
        assert_eq!(
            reply,
            Message::NeedChunks {
                upload_id: 0,
                existing_version_id: version_id,
                missing_indexes: Vec::new(),
            }
        );
    }

    #[tokio::test]
    async fn chunk_data_checks_in_spec_order() {
        let (_folder, storage) = open_test_storage();
        let bytes = file_bytes(CHUNK_SIZE_BYTES as usize + 7);
        let (upload_id, _) = offer(&storage, offer_for("a.bin", &bytes)).await;
        let last_chunk = chunk_of(&bytes, 1);
        let last_hash = ChunkHash::of_bytes(&last_chunk);

        // Unknown upload, and another device's view of this upload.
        expect_code(
            handle_chunk_data(
                &storage,
                DEV_DEVICE_ID,
                upload_id + 1,
                1,
                last_hash,
                last_chunk.clone(),
            )
            .await,
            ErrorCode::UnknownUpload,
        );
        expect_code(
            handle_chunk_data(&storage, 2, upload_id, 1, last_hash, last_chunk.clone()).await,
            ErrorCode::UnknownUpload,
        );
        // Index out of range.
        expect_code(
            handle_chunk_data(
                &storage,
                DEV_DEVICE_ID,
                upload_id,
                2,
                last_hash,
                last_chunk.clone(),
            )
            .await,
            ErrorCode::BadArgument,
        );
        // Hash not the offered one for this index (checked before the size).
        expect_code(
            handle_chunk_data(
                &storage,
                DEV_DEVICE_ID,
                upload_id,
                0,
                last_hash,
                last_chunk.clone(),
            )
            .await,
            ErrorCode::ChunkHashMismatch,
        );
        // Wrong size for the index.
        let mut long_chunk = last_chunk.clone();
        long_chunk.push(0);
        expect_code(
            handle_chunk_data(&storage, DEV_DEVICE_ID, upload_id, 1, last_hash, long_chunk).await,
            ErrorCode::ChunkSizeWrong,
        );
        // Right size, wrong bytes.
        let mut flipped_chunk = last_chunk.clone();
        flipped_chunk[0] ^= 0xFF;
        expect_code(
            handle_chunk_data(
                &storage,
                DEV_DEVICE_ID,
                upload_id,
                1,
                last_hash,
                flipped_chunk,
            )
            .await,
            ErrorCode::ChunkHashMismatch,
        );
        assert!(
            !storage.chunk_store.has(&last_hash).unwrap(),
            "nothing written"
        );

        // Commit too early.
        expect_code(
            handle_commit(&storage, DEV_DEVICE_ID, upload_id).await,
            ErrorCode::ChunksMissing,
        );
        send_chunk(&storage, upload_id, &bytes, 0).await.unwrap();
        send_chunk(&storage, upload_id, &bytes, 1).await.unwrap();
        // Another device cannot commit it.
        expect_code(
            handle_commit(&storage, 2, upload_id).await,
            ErrorCode::UnknownUpload,
        );
        handle_commit(&storage, DEV_DEVICE_ID, upload_id)
            .await
            .unwrap();
    }

    #[tokio::test]
    async fn wrong_file_hash_drops_the_upload() {
        let (_folder, storage) = open_test_storage();
        let bytes = file_bytes(100);
        let mut request = offer_for("a.bin", &bytes);
        request.file_sha256 = [9; 32];
        let (upload_id, _) = offer(&storage, request).await;
        send_chunk(&storage, upload_id, &bytes, 0).await.unwrap();
        expect_code(
            handle_commit(&storage, DEV_DEVICE_ID, upload_id).await,
            ErrorCode::FileHashMismatch,
        );
        expect_code(
            handle_commit(&storage, DEV_DEVICE_ID, upload_id).await,
            ErrorCode::UnknownUpload,
        );
    }

    #[tokio::test]
    async fn empty_file_commits_without_chunks() {
        let (_folder, storage) = open_test_storage();
        let (upload_id, missing_indexes) = offer(&storage, offer_for("empty", &[])).await;
        assert!(missing_indexes.is_empty());
        assert!(matches!(
            handle_commit(&storage, DEV_DEVICE_ID, upload_id)
                .await
                .unwrap(),
            Message::CommitOk { .. }
        ));
    }

    #[tokio::test]
    async fn bad_chunk_is_listed_again_and_replaced() {
        let (_folder, storage) = open_test_storage();
        let bytes = file_bytes(CHUNK_SIZE_BYTES as usize + 3);
        let (upload_id, _) = offer(&storage, offer_for("a.bin", &bytes)).await;
        send_chunk(&storage, upload_id, &bytes, 0).await.unwrap();
        send_chunk(&storage, upload_id, &bytes, 1).await.unwrap();
        handle_commit(&storage, DEV_DEVICE_ID, upload_id)
            .await
            .unwrap();

        // Bit rot in chunk 0, found by scrub.
        let first_hash = ChunkHash::of_bytes(&chunk_of(&bytes, 0));
        let chunk_path = storage.chunk_store.path_for(&first_hash);
        let mut on_disk = std::fs::read(&chunk_path).unwrap();
        on_disk[10] ^= 0x01;
        std::fs::write(&chunk_path, &on_disk).unwrap();
        storage
            .catalog_writer
            .mark_chunk_bad(first_hash)
            .await
            .unwrap();

        let (upload_id, missing_indexes) = offer(&storage, offer_for("a.bin", &bytes)).await;
        assert_eq!(missing_indexes, vec![0]);
        send_chunk(&storage, upload_id, &bytes, 0).await.unwrap();
        handle_commit(&storage, DEV_DEVICE_ID, upload_id)
            .await
            .unwrap();
        assert_eq!(
            storage.chunk_store.verify(&first_hash).unwrap(),
            ChunkHealth::Ok
        );
        assert_eq!(
            storage.catalog_reader.chunk_status(&first_hash).unwrap(),
            Some(ChunkStatus::Ok)
        );
    }

    #[tokio::test]
    async fn damaged_chunk_found_at_commit_is_marked_bad() {
        let (_folder, storage) = open_test_storage();
        let bytes = file_bytes(50);
        let (upload_id, _) = offer(&storage, offer_for("a.bin", &bytes)).await;
        send_chunk(&storage, upload_id, &bytes, 0).await.unwrap();
        let hash = ChunkHash::of_bytes(&bytes);
        std::fs::write(storage.chunk_store.path_for(&hash), b"rotten").unwrap();
        expect_code(
            handle_commit(&storage, DEV_DEVICE_ID, upload_id).await,
            ErrorCode::ChunksMissing,
        );
        assert_eq!(
            storage.catalog_reader.chunk_status(&hash).unwrap(),
            Some(ChunkStatus::Bad)
        );
        // Re-offer lists it, the upload heals it, commit works.
        let (upload_id, missing_indexes) = offer(&storage, offer_for("a.bin", &bytes)).await;
        assert_eq!(missing_indexes, vec![0]);
        send_chunk(&storage, upload_id, &bytes, 0).await.unwrap();
        handle_commit(&storage, DEV_DEVICE_ID, upload_id)
            .await
            .unwrap();
    }

    #[tokio::test]
    async fn file_left_by_a_crash_is_checked_before_it_is_trusted() {
        let (_folder, storage) = open_test_storage();
        let bytes = file_bytes(64);
        let hash = ChunkHash::of_bytes(&bytes);
        // A file with the chunk's name but wrong bytes, not in the catalog.
        let chunk_path = storage.chunk_store.path_for(&hash);
        std::fs::create_dir_all(chunk_path.parent().unwrap()).unwrap();
        std::fs::write(&chunk_path, b"junk").unwrap();
        let (upload_id, _) = offer(&storage, offer_for("a.bin", &bytes)).await;
        send_chunk(&storage, upload_id, &bytes, 0).await.unwrap();
        assert_eq!(std::fs::read(&chunk_path).unwrap(), bytes);
        handle_commit(&storage, DEV_DEVICE_ID, upload_id)
            .await
            .unwrap();
    }
}
