//! The single writer: one dedicated thread owns the only write connection.
//! Every write arrives over one channel and runs in order, so writes never
//! fight over locks and cleanup can never race an upload (D-020). `Commit`
//! is one transaction.
//!
//! [`CatalogWriter`] is the async handle (cheap to clone). Each operation is
//! also a plain function on `&mut Connection`, which the writer thread runs.

use std::collections::HashSet;
use std::path::Path;
use std::thread::JoinHandle;

use haotrannas_core::chunker::ChunkHash;
use haotrannas_core::limits::{CHUNK_SIZE_BYTES, HASH_BYTES};
use rusqlite::{Connection, OptionalExtension, Transaction, params};
use tokio::sync::{mpsc, oneshot};

use super::{CatalogError, chunk_hash_from_row, schema, sql_integer, u64_from_row};

/// How many commands may wait in the channel before senders wait.
const COMMAND_QUEUE_LENGTH: usize = 64;
/// How many times a new random upload id is tried before giving up.
const UPLOAD_ID_ATTEMPTS: usize = 8;

/// A job for the writer thread: runs on the write connection and sends its
/// own reply.
type WriteJob = Box<dyn FnOnce(&mut Connection) + Send>;

/// What the client offers in `FileOffer` (after the caller checked path rules
/// and chunk count).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FileOfferInput {
    /// Normalized relative path (section 10 rules already checked).
    pub path: String,
    /// File size.
    pub size_bytes: u64,
    /// File modified time, ms since the Unix epoch.
    pub modified_time_ms: i64,
    /// SHA-256 of the whole file.
    pub file_sha256: [u8; HASH_BYTES],
    /// SHA-256 of each chunk, in order.
    pub chunk_hashes: Vec<ChunkHash>,
}

/// The `NeedChunks` reply to a `FileOffer`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct OfferOutcome {
    /// New upload id, or 0 when the file is already backed up.
    pub upload_id: u64,
    /// The matching version when already backed up, else 0.
    pub existing_version_id: u64,
    /// Chunk indexes the client must send, ascending.
    pub missing_indexes: Vec<u32>,
}

/// An open upload, for the `ChunkData` checks.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct UploadInfo {
    /// Offered file size (gives each chunk's expected size).
    pub size_bytes: u64,
    /// Offered chunk hashes, in order.
    pub chunk_hashes: Vec<ChunkHash>,
}

/// Why `commit_upload` did not make a version. Nothing was written.
#[derive(Debug, thiserror::Error)]
pub enum CommitError {
    /// No such upload for this device → `UNKNOWN_UPLOAD`.
    #[error("unknown upload")]
    UnknownUpload,
    /// A chunk is not stored or is marked bad → `CHUNKS_MISSING`.
    #[error("chunks missing")]
    ChunksMissing,
    /// Database or writer failure → `INTERNAL`.
    #[error(transparent)]
    Catalog(#[from] CatalogError),
}

impl From<rusqlite::Error> for CommitError {
    fn from(error: rusqlite::Error) -> Self {
        Self::Catalog(CatalogError::Database(error))
    }
}

/// Async handle to the writer thread. Clone it freely.
#[derive(Debug, Clone)]
pub struct CatalogWriter {
    job_sender: mpsc::Sender<WriteJob>,
}

impl CatalogWriter {
    /// Opens (creating and migrating if needed) the database and starts the
    /// writer thread. The thread ends when every `CatalogWriter` is dropped.
    pub fn start(database_path: &Path) -> Result<(Self, JoinHandle<()>), CatalogError> {
        let connection = schema::open_writer_connection(database_path)?;
        Self::start_with_connection(connection)
    }

    /// Starts the writer thread on an already configured connection.
    pub fn start_with_connection(
        mut connection: Connection,
    ) -> Result<(Self, JoinHandle<()>), CatalogError> {
        let (job_sender, mut job_receiver) = mpsc::channel::<WriteJob>(COMMAND_QUEUE_LENGTH);
        let thread_handle = std::thread::Builder::new()
            .name("catalog-writer".to_owned())
            .spawn(move || {
                while let Some(job) = job_receiver.blocking_recv() {
                    job(&mut connection);
                }
            })
            .map_err(CatalogError::WriterStart)?;
        Ok((Self { job_sender }, thread_handle))
    }

    /// Runs `operation` on the writer thread and waits for its result.
    async fn run<T, F>(&self, operation: F) -> Result<T, CatalogError>
    where
        T: Send + 'static,
        F: FnOnce(&mut Connection) -> Result<T, CatalogError> + Send + 'static,
    {
        let (reply_sender, reply_receiver) = oneshot::channel();
        let job: WriteJob = Box::new(move |connection| {
            // The caller may have gone away; nothing to do then.
            let _ = reply_sender.send(operation(connection));
        });
        self.job_sender
            .send(job)
            .await
            .map_err(|_| CatalogError::WriterStopped)?;
        reply_receiver
            .await
            .map_err(|_| CatalogError::WriterStopped)?
    }

    /// Adds a paired device; returns its id.
    pub async fn add_device(
        &self,
        name: String,
        cert_sha256: [u8; HASH_BYTES],
        paired_at_ms: i64,
    ) -> Result<u64, CatalogError> {
        self.run(move |connection| add_device(connection, &name, &cert_sha256, paired_at_ms))
            .await
    }

    /// Removes (unpairs) a device and its open uploads. Returns false when
    /// there was no such device. Refuses with `DeviceHasBackups` when the
    /// device has committed files.
    pub async fn remove_device(&self, device_id: u64) -> Result<bool, CatalogError> {
        self.run(move |connection| remove_device(connection, device_id))
            .await
    }

    /// Records a chunk that is now stored and verified on disk: inserts it,
    /// or marks it 'ok' again if it was 'bad' (repaired).
    pub async fn record_chunk(
        &self,
        hash: ChunkHash,
        size_bytes: u64,
        now_ms: i64,
    ) -> Result<(), CatalogError> {
        self.run(move |connection| record_chunk(connection, &hash, size_bytes, now_ms))
            .await
    }

    /// Marks a chunk 'bad' (scrub found it damaged). Returns false when the
    /// chunk is not in the catalog.
    pub async fn mark_chunk_bad(&self, hash: ChunkHash) -> Result<bool, CatalogError> {
        self.run(move |connection| mark_chunk_bad(connection, &hash))
            .await
    }

    /// `FileOffer` (spec §8): the existing version, or a new upload and the
    /// missing chunk indexes.
    pub async fn offer_file(
        &self,
        device_id: u64,
        offer: FileOfferInput,
        now_ms: i64,
    ) -> Result<OfferOutcome, CatalogError> {
        self.run(move |connection| offer_file(connection, device_id, &offer, now_ms))
            .await
    }

    /// The upload's size and chunk list, if it exists and belongs to the
    /// device.
    pub async fn upload_info(
        &self,
        device_id: u64,
        upload_id: u64,
    ) -> Result<Option<UploadInfo>, CatalogError> {
        self.run(move |connection| upload_info(connection, device_id, upload_id))
            .await
    }

    /// The upload's chunk hashes in order (for the whole-file hash check
    /// before commit), if it exists and belongs to the device.
    pub async fn upload_chunk_hashes(
        &self,
        device_id: u64,
        upload_id: u64,
    ) -> Result<Option<Vec<ChunkHash>>, CatalogError> {
        Ok(self
            .upload_info(device_id, upload_id)
            .await?
            .map(|info| info.chunk_hashes))
    }

    /// Drops an open upload (after `FILE_HASH_MISMATCH`). Returns false when
    /// there was no such upload for this device.
    pub async fn delete_upload(
        &self,
        device_id: u64,
        upload_id: u64,
    ) -> Result<bool, CatalogError> {
        self.run(move |connection| delete_upload(connection, device_id, upload_id))
            .await
    }

    /// `Commit` (spec §8) in one transaction; returns the new version id.
    pub async fn commit_upload(
        &self,
        device_id: u64,
        upload_id: u64,
        now_ms: i64,
    ) -> Result<u64, CommitError> {
        let (reply_sender, reply_receiver) = oneshot::channel();
        let job: WriteJob = Box::new(move |connection| {
            let _ = reply_sender.send(commit_upload(connection, device_id, upload_id, now_ms));
        });
        self.job_sender
            .send(job)
            .await
            .map_err(|_| CatalogError::WriterStopped)?;
        reply_receiver
            .await
            .map_err(|_| CatalogError::WriterStopped)?
    }

    /// Deletes uploads created before `created_before_ms`; returns how many.
    pub async fn delete_expired_uploads(
        &self,
        created_before_ms: i64,
    ) -> Result<u64, CatalogError> {
        self.run(move |connection| delete_expired_uploads(connection, created_before_ms))
            .await
    }
}

/// See [`CatalogWriter::add_device`].
pub fn add_device(
    connection: &mut Connection,
    name: &str,
    cert_sha256: &[u8; HASH_BYTES],
    paired_at_ms: i64,
) -> Result<u64, CatalogError> {
    connection.execute(
        "INSERT INTO devices (name, cert_sha256, paired_at_ms) VALUES (?1, ?2, ?3)",
        params![name, cert_sha256, paired_at_ms],
    )?;
    Ok(row_id_to_u64(connection.last_insert_rowid()))
}

/// See [`CatalogWriter::remove_device`].
pub fn remove_device(connection: &mut Connection, device_id: u64) -> Result<bool, CatalogError> {
    let Ok(device_sql_id) = sql_integer(device_id) else {
        return Ok(false);
    };
    let transaction = connection.transaction()?;
    let has_files: bool = transaction.query_row(
        "SELECT EXISTS (SELECT 1 FROM files WHERE device_id = ?1)",
        [device_sql_id],
        |row| row.get(0),
    )?;
    if has_files {
        return Err(CatalogError::DeviceHasBackups);
    }
    transaction.execute("DELETE FROM uploads WHERE device_id = ?1", [device_sql_id])?;
    let removed_count =
        transaction.execute("DELETE FROM devices WHERE id = ?1", [device_sql_id])?;
    transaction.commit()?;
    Ok(removed_count > 0)
}

/// See [`CatalogWriter::record_chunk`].
pub fn record_chunk(
    connection: &mut Connection,
    hash: &ChunkHash,
    size_bytes: u64,
    now_ms: i64,
) -> Result<(), CatalogError> {
    connection.execute(
        "INSERT INTO chunks (hash, size_bytes, status, created_at_ms) VALUES (?1, ?2, 'ok', ?3)
         ON CONFLICT (hash) DO UPDATE SET status = 'ok'",
        params![hash.0, sql_integer(size_bytes)?, now_ms],
    )?;
    Ok(())
}

/// See [`CatalogWriter::mark_chunk_bad`].
pub fn mark_chunk_bad(connection: &mut Connection, hash: &ChunkHash) -> Result<bool, CatalogError> {
    let changed_count =
        connection.execute("UPDATE chunks SET status = 'bad' WHERE hash = ?1", [hash.0])?;
    Ok(changed_count > 0)
}

/// See [`CatalogWriter::offer_file`].
pub fn offer_file(
    connection: &mut Connection,
    device_id: u64,
    offer: &FileOfferInput,
    now_ms: i64,
) -> Result<OfferOutcome, CatalogError> {
    debug_assert_eq!(
        u64::try_from(offer.chunk_hashes.len()).ok(),
        Some(offer.size_bytes.div_ceil(u64::from(CHUNK_SIZE_BYTES))),
        "the caller checks the chunk count"
    );
    let device_sql_id = sql_integer(device_id)?;
    let size_sql_bytes = sql_integer(offer.size_bytes)?;
    let transaction = connection.transaction()?;

    // Shortcut: the latest version is the same file and all its chunks are
    // healthy → already backed up.
    let latest_version: Option<(i64, i64, i64, [u8; HASH_BYTES])> = transaction
        .query_row(
            "SELECT versions.id, versions.size_bytes, versions.modified_time_ms, versions.file_sha256
             FROM versions JOIN files ON files.id = versions.file_id
             WHERE files.device_id = ?1 AND files.path = ?2
             ORDER BY versions.id DESC LIMIT 1",
            params![device_sql_id, offer.path],
            |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?, row.get(3)?)),
        )
        .optional()?;
    if let Some((version_id, size_bytes, modified_time_ms, file_sha256)) = latest_version {
        let is_same_file = size_bytes == size_sql_bytes
            && modified_time_ms == offer.modified_time_ms
            && file_sha256 == offer.file_sha256;
        if is_same_file && !version_has_unhealthy_chunk(&transaction, version_id)? {
            return Ok(OfferOutcome {
                upload_id: 0,
                existing_version_id: row_id_to_u64(version_id),
                missing_indexes: Vec::new(),
            });
        }
    }

    let upload_sql_id = insert_upload(&transaction, device_sql_id, offer, size_sql_bytes, now_ms)?;
    let missing_indexes = insert_upload_chunks(&transaction, upload_sql_id, &offer.chunk_hashes)?;
    transaction.commit()?;
    Ok(OfferOutcome {
        upload_id: row_id_to_u64(upload_sql_id),
        existing_version_id: 0,
        missing_indexes,
    })
}

/// Saves the offered chunk list and returns, for each distinct hash not
/// stored with status 'ok', the first index that has it (ascending).
fn insert_upload_chunks(
    transaction: &Transaction<'_>,
    upload_sql_id: i64,
    chunk_hashes: &[ChunkHash],
) -> Result<Vec<u32>, CatalogError> {
    let mut insert_chunk = transaction.prepare_cached(
        "INSERT INTO upload_chunks (upload_id, position, chunk_hash) VALUES (?1, ?2, ?3)",
    )?;
    let mut is_chunk_ok = transaction
        .prepare_cached("SELECT EXISTS (SELECT 1 FROM chunks WHERE hash = ?1 AND status = 'ok')")?;
    let mut seen_hashes: HashSet<ChunkHash> = HashSet::new();
    let mut missing_indexes = Vec::new();
    for (position, hash) in chunk_hashes.iter().enumerate() {
        let position = u32::try_from(position).expect("the caller checks the chunk count");
        insert_chunk.execute(params![upload_sql_id, position, hash.0])?;
        if seen_hashes.insert(*hash) {
            let is_stored_ok: bool = is_chunk_ok.query_row([hash.0], |row| row.get(0))?;
            if !is_stored_ok {
                missing_indexes.push(position);
            }
        }
    }
    Ok(missing_indexes)
}

/// True when a chunk of the version is marked bad, or (should never happen)
/// has no `chunks` row at all.
fn version_has_unhealthy_chunk(
    transaction: &Transaction<'_>,
    version_sql_id: i64,
) -> Result<bool, CatalogError> {
    Ok(transaction.query_row(
        "SELECT EXISTS (
             SELECT 1 FROM version_chunks
             LEFT JOIN chunks ON chunks.hash = version_chunks.chunk_hash
             WHERE version_chunks.version_id = ?1
               AND (chunks.status IS NULL OR chunks.status <> 'ok'))",
        [version_sql_id],
        |row| row.get(0),
    )?)
}

/// Inserts an `uploads` row with a random id in 1 ..< 2^63, retrying on the
/// (very unlikely) id collision.
fn insert_upload(
    transaction: &Transaction<'_>,
    device_sql_id: i64,
    offer: &FileOfferInput,
    size_sql_bytes: i64,
    now_ms: i64,
) -> Result<i64, CatalogError> {
    let mut insert = transaction.prepare_cached(
        "INSERT INTO uploads (id, device_id, path, size_bytes, modified_time_ms, file_sha256, created_at_ms)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)
         ON CONFLICT (id) DO NOTHING",
    )?;
    for _ in 0..UPLOAD_ID_ATTEMPTS {
        let upload_sql_id: i64 = rand::random_range(1..=i64::MAX);
        let inserted_count = insert.execute(params![
            upload_sql_id,
            device_sql_id,
            offer.path,
            size_sql_bytes,
            offer.modified_time_ms,
            offer.file_sha256,
            now_ms
        ])?;
        if inserted_count == 1 {
            return Ok(upload_sql_id);
        }
    }
    Err(CatalogError::NoFreeUploadId)
}

/// See [`CatalogWriter::upload_info`].
pub fn upload_info(
    connection: &mut Connection,
    device_id: u64,
    upload_id: u64,
) -> Result<Option<UploadInfo>, CatalogError> {
    let (Ok(device_sql_id), Ok(upload_sql_id)) = (sql_integer(device_id), sql_integer(upload_id))
    else {
        return Ok(None);
    };
    let size_bytes: Option<u64> = connection
        .query_row(
            "SELECT size_bytes FROM uploads WHERE id = ?1 AND device_id = ?2",
            [upload_sql_id, device_sql_id],
            |row| u64_from_row(row, 0),
        )
        .optional()?;
    let Some(size_bytes) = size_bytes else {
        return Ok(None);
    };
    let mut select = connection.prepare_cached(
        "SELECT chunk_hash FROM upload_chunks WHERE upload_id = ?1 ORDER BY position",
    )?;
    let chunk_hashes = select
        .query_map([upload_sql_id], |row| chunk_hash_from_row(row, 0))?
        .collect::<Result<Vec<_>, _>>()?;
    Ok(Some(UploadInfo {
        size_bytes,
        chunk_hashes,
    }))
}

/// See [`CatalogWriter::delete_upload`].
pub fn delete_upload(
    connection: &mut Connection,
    device_id: u64,
    upload_id: u64,
) -> Result<bool, CatalogError> {
    let (Ok(device_sql_id), Ok(upload_sql_id)) = (sql_integer(device_id), sql_integer(upload_id))
    else {
        return Ok(false);
    };
    let deleted_count = connection.execute(
        "DELETE FROM uploads WHERE id = ?1 AND device_id = ?2",
        [upload_sql_id, device_sql_id],
    )?;
    Ok(deleted_count > 0)
}

/// See [`CatalogWriter::commit_upload`]. One transaction: if anything fails,
/// nothing is written and the upload stays.
pub fn commit_upload(
    connection: &mut Connection,
    device_id: u64,
    upload_id: u64,
    now_ms: i64,
) -> Result<u64, CommitError> {
    let (Ok(device_sql_id), Ok(upload_sql_id)) = (sql_integer(device_id), sql_integer(upload_id))
    else {
        return Err(CommitError::UnknownUpload);
    };
    let transaction = connection.transaction()?;

    let upload: Option<(String, i64, i64, [u8; HASH_BYTES])> = transaction
        .query_row(
            "SELECT path, size_bytes, modified_time_ms, file_sha256
             FROM uploads WHERE id = ?1 AND device_id = ?2",
            [upload_sql_id, device_sql_id],
            |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?, row.get(3)?)),
        )
        .optional()?;
    let Some((path, size_bytes, modified_time_ms, file_sha256)) = upload else {
        return Err(CommitError::UnknownUpload);
    };

    let has_missing_chunk: bool = transaction.query_row(
        "SELECT EXISTS (
             SELECT 1 FROM upload_chunks
             LEFT JOIN chunks ON chunks.hash = upload_chunks.chunk_hash
             WHERE upload_chunks.upload_id = ?1
               AND (chunks.status IS NULL OR chunks.status <> 'ok'))",
        [upload_sql_id],
        |row| row.get(0),
    )?;
    if has_missing_chunk {
        return Err(CommitError::ChunksMissing);
    }

    transaction.execute(
        "INSERT INTO files (device_id, path) VALUES (?1, ?2)
         ON CONFLICT (device_id, path) DO NOTHING",
        params![device_sql_id, path],
    )?;
    let file_sql_id: i64 = transaction.query_row(
        "SELECT id FROM files WHERE device_id = ?1 AND path = ?2",
        params![device_sql_id, path],
        |row| row.get(0),
    )?;
    transaction.execute(
        "INSERT INTO versions (file_id, size_bytes, modified_time_ms, file_sha256, committed_at_ms)
         VALUES (?1, ?2, ?3, ?4, ?5)",
        params![
            file_sql_id,
            size_bytes,
            modified_time_ms,
            file_sha256,
            now_ms
        ],
    )?;
    let version_sql_id = transaction.last_insert_rowid();
    transaction.execute(
        "INSERT INTO version_chunks (version_id, position, chunk_hash)
         SELECT ?1, position, chunk_hash FROM upload_chunks WHERE upload_id = ?2",
        [version_sql_id, upload_sql_id],
    )?;
    transaction.execute("DELETE FROM uploads WHERE id = ?1", [upload_sql_id])?;
    transaction.commit()?;
    Ok(row_id_to_u64(version_sql_id))
}

/// See [`CatalogWriter::delete_expired_uploads`].
pub fn delete_expired_uploads(
    connection: &mut Connection,
    created_before_ms: i64,
) -> Result<u64, CatalogError> {
    let deleted_count = connection.execute(
        "DELETE FROM uploads WHERE created_at_ms < ?1",
        [created_before_ms],
    )?;
    Ok(u64::try_from(deleted_count).expect("row count fits in u64"))
}

/// A SQLite row id (always positive here) as a wire id.
fn row_id_to_u64(row_id: i64) -> u64 {
    u64::try_from(row_id).expect("row ids are positive")
}

#[cfg(test)]
mod tests {
    use sha2::{Digest, Sha256};

    use super::super::reader::CatalogReader;
    use super::*;

    const NOW_MS: i64 = 1_700_000_000_000;

    struct TestCatalog {
        _folder: tempfile::TempDir,
        writer: CatalogWriter,
        reader: CatalogReader,
    }

    fn open_test_catalog() -> TestCatalog {
        let folder = tempfile::tempdir().unwrap();
        let database_path = folder.path().join("index.sqlite");
        let (writer, _thread) = CatalogWriter::start(&database_path).unwrap();
        let reader = CatalogReader::new(&database_path);
        TestCatalog {
            _folder: folder,
            writer,
            reader,
        }
    }

    fn hash_of(data: &[u8]) -> ChunkHash {
        ChunkHash(Sha256::digest(data).into())
    }

    /// An offer whose sizes match the chunk count (the bytes are not real).
    fn offer_for(
        path: &str,
        chunk_hashes: Vec<ChunkHash>,
        modified_time_ms: i64,
    ) -> FileOfferInput {
        let chunk_count = u64::try_from(chunk_hashes.len()).unwrap();
        let mut whole_file_hasher = Sha256::new();
        for hash in &chunk_hashes {
            whole_file_hasher.update(hash.0);
        }
        FileOfferInput {
            path: path.to_owned(),
            size_bytes: chunk_count * u64::from(CHUNK_SIZE_BYTES),
            modified_time_ms,
            file_sha256: whole_file_hasher.finalize().into(),
            chunk_hashes,
        }
    }

    async fn add_test_device(catalog: &TestCatalog, name: &str) -> u64 {
        catalog
            .writer
            .add_device(name.to_owned(), Sha256::digest(name).into(), NOW_MS)
            .await
            .unwrap()
    }

    /// Records every chunk of the offer as stored.
    async fn store_all_chunks(catalog: &TestCatalog, offer: &FileOfferInput) {
        for hash in &offer.chunk_hashes {
            catalog
                .writer
                .record_chunk(*hash, u64::from(CHUNK_SIZE_BYTES), NOW_MS)
                .await
                .unwrap();
        }
    }

    /// Offer, store everything, commit; returns the version id.
    async fn back_up(catalog: &TestCatalog, device_id: u64, offer: &FileOfferInput) -> u64 {
        let outcome = catalog
            .writer
            .offer_file(device_id, offer.clone(), NOW_MS)
            .await
            .unwrap();
        assert_ne!(outcome.upload_id, 0);
        store_all_chunks(catalog, offer).await;
        catalog
            .writer
            .commit_upload(device_id, outcome.upload_id, NOW_MS)
            .await
            .unwrap()
    }

    fn count_rows(catalog: &TestCatalog, table: &str) -> i64 {
        let connection = catalog.reader.open_connection().unwrap();
        connection
            .query_row(&format!("SELECT COUNT(*) FROM {table}"), [], |row| {
                row.get(0)
            })
            .unwrap()
    }

    #[tokio::test]
    async fn new_file_lists_each_distinct_missing_hash_once_at_first_index() {
        let catalog = open_test_catalog();
        let device_id = add_test_device(&catalog, "phone").await;
        let (first, second, third) = (hash_of(b"a"), hash_of(b"b"), hash_of(b"c"));
        let offer = offer_for(
            "photos/a.jpg",
            vec![first, second, first, third, second],
            NOW_MS,
        );
        let outcome = catalog
            .writer
            .offer_file(device_id, offer.clone(), NOW_MS)
            .await
            .unwrap();
        assert!(outcome.upload_id >= 1 && outcome.upload_id < 1 << 63);
        assert_eq!(outcome.existing_version_id, 0);
        assert_eq!(outcome.missing_indexes, vec![0, 1, 3]);

        let info = catalog
            .writer
            .upload_info(device_id, outcome.upload_id)
            .await
            .unwrap()
            .unwrap();
        assert_eq!(info.size_bytes, offer.size_bytes);
        assert_eq!(info.chunk_hashes, offer.chunk_hashes);

        // Stored chunks are not asked for again.
        catalog.writer.record_chunk(first, 1, NOW_MS).await.unwrap();
        let outcome = catalog
            .writer
            .offer_file(device_id, offer, NOW_MS)
            .await
            .unwrap();
        assert_eq!(outcome.missing_indexes, vec![1, 3]);
    }

    #[tokio::test]
    async fn empty_file_has_no_missing_chunks() {
        let catalog = open_test_catalog();
        let device_id = add_test_device(&catalog, "phone").await;
        let offer = offer_for("empty.txt", Vec::new(), NOW_MS);
        let version_id = back_up(&catalog, device_id, &offer).await;
        let again = catalog
            .writer
            .offer_file(device_id, offer, NOW_MS)
            .await
            .unwrap();
        assert_eq!(again.existing_version_id, version_id);
    }

    #[tokio::test]
    async fn second_device_with_same_content_uploads_nothing() {
        let catalog = open_test_catalog();
        let phone_id = add_test_device(&catalog, "phone").await;
        let laptop_id = add_test_device(&catalog, "laptop").await;
        let offer = offer_for("doc.pdf", vec![hash_of(b"x"), hash_of(b"y")], NOW_MS);
        back_up(&catalog, phone_id, &offer).await;

        let outcome = catalog
            .writer
            .offer_file(laptop_id, offer, NOW_MS)
            .await
            .unwrap();
        assert_ne!(outcome.upload_id, 0);
        assert_eq!(outcome.existing_version_id, 0);
        assert!(outcome.missing_indexes.is_empty());
        let version_id = catalog
            .writer
            .commit_upload(laptop_id, outcome.upload_id, NOW_MS)
            .await
            .unwrap();
        assert!(version_id > 0);
    }

    #[tokio::test]
    async fn same_offer_after_commit_returns_existing_version() {
        let catalog = open_test_catalog();
        let device_id = add_test_device(&catalog, "phone").await;
        let offer = offer_for("a.txt", vec![hash_of(b"1")], NOW_MS);
        // Commit, then the client "loses CommitOk" and offers again.
        let version_id = back_up(&catalog, device_id, &offer).await;
        let outcome = catalog
            .writer
            .offer_file(device_id, offer, NOW_MS)
            .await
            .unwrap();
        assert_eq!(
            outcome,
            OfferOutcome {
                upload_id: 0,
                existing_version_id: version_id,
                missing_indexes: Vec::new(),
            }
        );
        assert_eq!(count_rows(&catalog, "uploads"), 0);
        assert_eq!(count_rows(&catalog, "versions"), 1);
    }

    #[tokio::test]
    async fn changed_modified_time_starts_a_new_upload() {
        let catalog = open_test_catalog();
        let device_id = add_test_device(&catalog, "phone").await;
        let offer = offer_for("a.txt", vec![hash_of(b"1")], NOW_MS);
        back_up(&catalog, device_id, &offer).await;

        let touched = FileOfferInput {
            modified_time_ms: NOW_MS + 1,
            ..offer
        };
        let outcome = catalog
            .writer
            .offer_file(device_id, touched, NOW_MS)
            .await
            .unwrap();
        assert_ne!(outcome.upload_id, 0);
        assert_eq!(outcome.existing_version_id, 0);
        assert!(outcome.missing_indexes.is_empty());
    }

    #[tokio::test]
    async fn bad_chunk_in_latest_version_skips_shortcut() {
        let catalog = open_test_catalog();
        let device_id = add_test_device(&catalog, "phone").await;
        let (good, damaged) = (hash_of(b"good"), hash_of(b"damaged"));
        let offer = offer_for("a.bin", vec![good, damaged], NOW_MS);
        back_up(&catalog, device_id, &offer).await;
        assert!(catalog.writer.mark_chunk_bad(damaged).await.unwrap());

        let outcome = catalog
            .writer
            .offer_file(device_id, offer, NOW_MS)
            .await
            .unwrap();
        assert_ne!(outcome.upload_id, 0);
        assert_eq!(outcome.existing_version_id, 0);
        assert_eq!(outcome.missing_indexes, vec![1]);
    }

    #[tokio::test]
    async fn commit_with_missing_chunk_writes_nothing() {
        let catalog = open_test_catalog();
        let device_id = add_test_device(&catalog, "phone").await;
        let (stored, never_sent) = (hash_of(b"s"), hash_of(b"n"));
        let offer = offer_for("a.bin", vec![stored, never_sent], NOW_MS);
        let outcome = catalog
            .writer
            .offer_file(device_id, offer, NOW_MS)
            .await
            .unwrap();
        catalog
            .writer
            .record_chunk(stored, 1, NOW_MS)
            .await
            .unwrap();
        let result = catalog
            .writer
            .commit_upload(device_id, outcome.upload_id, NOW_MS)
            .await;
        assert!(matches!(result, Err(CommitError::ChunksMissing)));
        assert_eq!(count_rows(&catalog, "files"), 0);
        assert_eq!(count_rows(&catalog, "versions"), 0);
        assert_eq!(count_rows(&catalog, "uploads"), 1);
    }

    #[tokio::test]
    async fn commit_after_chunk_marked_bad_reports_missing() {
        let catalog = open_test_catalog();
        let device_id = add_test_device(&catalog, "phone").await;
        let hash = hash_of(b"rot");
        let offer = offer_for("a.bin", vec![hash], NOW_MS);
        let outcome = catalog
            .writer
            .offer_file(device_id, offer, NOW_MS)
            .await
            .unwrap();
        catalog.writer.record_chunk(hash, 1, NOW_MS).await.unwrap();
        catalog.writer.mark_chunk_bad(hash).await.unwrap();
        let result = catalog
            .writer
            .commit_upload(device_id, outcome.upload_id, NOW_MS)
            .await;
        assert!(matches!(result, Err(CommitError::ChunksMissing)));
    }

    #[tokio::test]
    async fn commit_of_another_devices_upload_is_unknown() {
        let catalog = open_test_catalog();
        let owner_id = add_test_device(&catalog, "phone").await;
        let stranger_id = add_test_device(&catalog, "laptop").await;
        let offer = offer_for("a.bin", vec![hash_of(b"1")], NOW_MS);
        let outcome = catalog
            .writer
            .offer_file(owner_id, offer.clone(), NOW_MS)
            .await
            .unwrap();
        store_all_chunks(&catalog, &offer).await;

        let result = catalog
            .writer
            .commit_upload(stranger_id, outcome.upload_id, NOW_MS)
            .await;
        assert!(matches!(result, Err(CommitError::UnknownUpload)));
        assert!(
            catalog
                .writer
                .upload_info(stranger_id, outcome.upload_id)
                .await
                .unwrap()
                .is_none()
        );
        let result = catalog.writer.commit_upload(owner_id, 12345, NOW_MS).await;
        assert!(matches!(result, Err(CommitError::UnknownUpload)));
        let result = catalog
            .writer
            .commit_upload(owner_id, u64::MAX, NOW_MS)
            .await;
        assert!(matches!(result, Err(CommitError::UnknownUpload)));
        // The owner still can.
        catalog
            .writer
            .commit_upload(owner_id, outcome.upload_id, NOW_MS)
            .await
            .unwrap();
    }

    #[test]
    fn commit_is_atomic() {
        let folder = tempfile::tempdir().unwrap();
        let mut connection =
            schema::open_writer_connection(&folder.path().join("index.sqlite")).unwrap();
        let device_id = add_device(&mut connection, "phone", &[1; HASH_BYTES], NOW_MS).unwrap();
        let offer = offer_for("a.bin", vec![hash_of(b"1"), hash_of(b"2")], NOW_MS);
        let outcome = offer_file(&mut connection, device_id, &offer, NOW_MS).unwrap();
        for hash in &offer.chunk_hashes {
            record_chunk(&mut connection, hash, 1, NOW_MS).unwrap();
        }
        // Fail the last insert step inside the commit transaction.
        connection
            .execute_batch(
                "CREATE TEMP TRIGGER fail_version_chunks BEFORE INSERT ON version_chunks
                 BEGIN SELECT RAISE(ABORT, 'test failure'); END;",
            )
            .unwrap();
        let result = commit_upload(&mut connection, device_id, outcome.upload_id, NOW_MS);
        assert!(matches!(
            result,
            Err(CommitError::Catalog(CatalogError::Database(_)))
        ));
        for (table, expected_count) in [
            ("files", 0),
            ("versions", 0),
            ("version_chunks", 0),
            ("uploads", 1),
            ("upload_chunks", 2),
        ] {
            let count: i64 = connection
                .query_row(&format!("SELECT COUNT(*) FROM {table}"), [], |row| {
                    row.get(0)
                })
                .unwrap();
            assert_eq!(count, expected_count, "{table}");
        }

        // Without the failure the same upload commits.
        connection
            .execute_batch("DROP TRIGGER fail_version_chunks")
            .unwrap();
        commit_upload(&mut connection, device_id, outcome.upload_id, NOW_MS).unwrap();
    }

    #[tokio::test]
    async fn record_chunk_heals_a_bad_chunk() {
        let catalog = open_test_catalog();
        let hash = hash_of(b"heal me");
        assert!(!catalog.writer.mark_chunk_bad(hash).await.unwrap());
        catalog.writer.record_chunk(hash, 7, NOW_MS).await.unwrap();
        assert!(catalog.writer.mark_chunk_bad(hash).await.unwrap());
        assert_eq!(
            catalog.reader.chunk_status(&hash).unwrap(),
            Some(super::super::ChunkStatus::Bad)
        );
        catalog.writer.record_chunk(hash, 7, NOW_MS).await.unwrap();
        assert_eq!(
            catalog.reader.chunk_status(&hash).unwrap(),
            Some(super::super::ChunkStatus::Ok)
        );
    }

    #[tokio::test]
    async fn expired_uploads_are_deleted_with_their_chunk_lists() {
        let catalog = open_test_catalog();
        let device_id = add_test_device(&catalog, "phone").await;
        let offer = offer_for("a.bin", vec![hash_of(b"1"), hash_of(b"2")], NOW_MS);
        catalog
            .writer
            .offer_file(device_id, offer.clone(), NOW_MS - 1000)
            .await
            .unwrap();
        let young = catalog
            .writer
            .offer_file(device_id, offer, NOW_MS)
            .await
            .unwrap();
        let deleted_count = catalog
            .writer
            .delete_expired_uploads(NOW_MS - 500)
            .await
            .unwrap();
        assert_eq!(deleted_count, 1);
        assert_eq!(count_rows(&catalog, "uploads"), 1);
        assert_eq!(count_rows(&catalog, "upload_chunks"), 2);
        assert!(
            catalog
                .writer
                .upload_info(device_id, young.upload_id)
                .await
                .unwrap()
                .is_some()
        );
    }

    #[tokio::test]
    async fn delete_upload_drops_only_own_upload() {
        let catalog = open_test_catalog();
        let owner_id = add_test_device(&catalog, "phone").await;
        let stranger_id = add_test_device(&catalog, "laptop").await;
        let offer = offer_for("a.bin", vec![hash_of(b"1")], NOW_MS);
        let outcome = catalog
            .writer
            .offer_file(owner_id, offer, NOW_MS)
            .await
            .unwrap();
        assert!(
            !catalog
                .writer
                .delete_upload(stranger_id, outcome.upload_id)
                .await
                .unwrap()
        );
        assert!(
            catalog
                .writer
                .delete_upload(owner_id, outcome.upload_id)
                .await
                .unwrap()
        );
        assert_eq!(count_rows(&catalog, "upload_chunks"), 0);
    }

    #[tokio::test]
    async fn devices_add_find_and_remove() {
        let catalog = open_test_catalog();
        let phone_id = add_test_device(&catalog, "phone").await;
        let laptop_id = add_test_device(&catalog, "laptop").await;
        // The same certificate cannot pair twice.
        assert!(
            catalog
                .writer
                .add_device("again".to_owned(), Sha256::digest("phone").into(), NOW_MS)
                .await
                .is_err()
        );

        let found = catalog
            .reader
            .device_by_cert(&Sha256::digest("phone").into())
            .unwrap()
            .unwrap();
        assert_eq!((found.device_id, found.name.as_str()), (phone_id, "phone"));
        assert_eq!(catalog.reader.list_devices().unwrap().len(), 2);

        // A device with backups is not removed.
        back_up(
            &catalog,
            phone_id,
            &offer_for("a", vec![hash_of(b"1")], NOW_MS),
        )
        .await;
        assert!(matches!(
            catalog.writer.remove_device(phone_id).await,
            Err(CatalogError::DeviceHasBackups)
        ));
        // A device with only an open upload is.
        catalog
            .writer
            .offer_file(
                laptop_id,
                offer_for("b", vec![hash_of(b"2")], NOW_MS),
                NOW_MS,
            )
            .await
            .unwrap();
        assert!(catalog.writer.remove_device(laptop_id).await.unwrap());
        assert!(!catalog.writer.remove_device(laptop_id).await.unwrap());
        assert!(
            catalog
                .reader
                .device_by_cert(&Sha256::digest("laptop").into())
                .unwrap()
                .is_none()
        );
        assert_eq!(count_rows(&catalog, "uploads"), 0);
    }

    #[tokio::test]
    async fn latest_version_has_the_manifest() {
        let catalog = open_test_catalog();
        let device_id = add_test_device(&catalog, "phone").await;
        let first = offer_for("a.bin", vec![hash_of(b"1")], NOW_MS);
        back_up(&catalog, device_id, &first).await;
        let second = offer_for("a.bin", vec![hash_of(b"2"), hash_of(b"3")], NOW_MS + 5);
        let second_version_id = back_up(&catalog, device_id, &second).await;

        let latest = catalog
            .reader
            .latest_version(device_id, "a.bin")
            .unwrap()
            .unwrap();
        assert_eq!(latest.version_id, second_version_id);
        assert_eq!(latest.size_bytes, second.size_bytes);
        assert_eq!(latest.modified_time_ms, second.modified_time_ms);
        assert_eq!(latest.file_sha256, second.file_sha256);
        assert_eq!(latest.chunk_hashes, second.chunk_hashes);
        assert!(
            catalog
                .reader
                .latest_version(device_id, "b.bin")
                .unwrap()
                .is_none()
        );
        assert_eq!(count_rows(&catalog, "files"), 1);
    }
}
