//! Read-only queries: device lookup by certificate fingerprint, device list,
//! latest version of a file (its manifest), chunk status.
//!
//! Every call opens a read-only connection (`SQLITE_OPEN_READ_ONLY`) and
//! blocks: async callers use `tokio::task::spawn_blocking`. In WAL mode
//! readers never wait for the writer.

use std::path::{Path, PathBuf};

use haotrannas_core::chunker::ChunkHash;
use haotrannas_core::limits::HASH_BYTES;
use rusqlite::{Connection, OpenFlags, OptionalExtension, params};

use super::{CatalogError, ChunkStatus, chunk_hash_from_row, schema, sql_integer, u64_from_row};

/// A paired device.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DeviceRecord {
    /// `devices.id`.
    pub device_id: u64,
    /// Name the device gave at pairing.
    pub name: String,
    /// When it was paired, ms since the Unix epoch.
    pub paired_at_ms: i64,
}

/// One committed version of a file, with its chunk list (a `FileManifest`).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct VersionRecord {
    /// `versions.id`.
    pub version_id: u64,
    /// File size.
    pub size_bytes: u64,
    /// File modified time, ms since the Unix epoch.
    pub modified_time_ms: i64,
    /// SHA-256 of the whole file.
    pub file_sha256: [u8; HASH_BYTES],
    /// Chunk hashes in order.
    pub chunk_hashes: Vec<ChunkHash>,
}

/// Opens read-only connections to the catalog. Clone it freely.
#[derive(Debug, Clone)]
pub struct CatalogReader {
    database_path: PathBuf,
}

impl CatalogReader {
    /// A reader for the database the writer created at `database_path`.
    pub fn new(database_path: &Path) -> Self {
        Self {
            database_path: database_path.to_owned(),
        }
    }

    /// A new read-only connection.
    pub fn open_connection(&self) -> Result<Connection, CatalogError> {
        let connection = Connection::open_with_flags(
            &self.database_path,
            OpenFlags::SQLITE_OPEN_READ_ONLY
                | OpenFlags::SQLITE_OPEN_NO_MUTEX
                | OpenFlags::SQLITE_OPEN_URI,
        )?;
        connection.busy_timeout(schema::BUSY_TIMEOUT)?;
        Ok(connection)
    }

    /// The device that owns this client certificate fingerprint, if paired.
    pub fn device_by_cert(
        &self,
        cert_sha256: &[u8; HASH_BYTES],
    ) -> Result<Option<DeviceRecord>, CatalogError> {
        let connection = self.open_connection()?;
        Ok(connection
            .query_row(
                "SELECT id, name, paired_at_ms FROM devices WHERE cert_sha256 = ?1",
                [cert_sha256],
                device_from_row,
            )
            .optional()?)
    }

    /// Every paired device, by id.
    pub fn list_devices(&self) -> Result<Vec<DeviceRecord>, CatalogError> {
        let connection = self.open_connection()?;
        let mut select =
            connection.prepare("SELECT id, name, paired_at_ms FROM devices ORDER BY id")?;
        let devices = select
            .query_map([], device_from_row)?
            .collect::<Result<Vec<_>, _>>()?;
        Ok(devices)
    }

    /// The newest committed version of (device, path), with its chunk list.
    pub fn latest_version(
        &self,
        device_id: u64,
        path: &str,
    ) -> Result<Option<VersionRecord>, CatalogError> {
        let Ok(device_sql_id) = sql_integer(device_id) else {
            return Ok(None);
        };
        let mut connection = self.open_connection()?;
        // One snapshot for the version row and its chunk list.
        let transaction = connection.transaction()?;
        let version = transaction
            .query_row(
                "SELECT versions.id, versions.size_bytes, versions.modified_time_ms, versions.file_sha256
                 FROM versions JOIN files ON files.id = versions.file_id
                 WHERE files.device_id = ?1 AND files.path = ?2
                 ORDER BY versions.id DESC LIMIT 1",
                params![device_sql_id, path],
                |row| {
                    Ok(VersionRecord {
                        version_id: u64_from_row(row, 0)?,
                        size_bytes: u64_from_row(row, 1)?,
                        modified_time_ms: row.get(2)?,
                        file_sha256: row.get(3)?,
                        chunk_hashes: Vec::new(),
                    })
                },
            )
            .optional()?;
        let Some(mut version) = version else {
            return Ok(None);
        };
        let mut select = transaction.prepare(
            "SELECT chunk_hash FROM version_chunks WHERE version_id = ?1 ORDER BY position",
        )?;
        version.chunk_hashes = select
            .query_map([sql_integer(version.version_id)?], |row| {
                chunk_hash_from_row(row, 0)
            })?
            .collect::<Result<Vec<_>, _>>()?;
        Ok(Some(version))
    }

    /// Version `version_id` of (device, path), with its chunk list; `None`
    /// when that version does not exist or belongs to another file.
    pub fn version_of_file(
        &self,
        device_id: u64,
        path: &str,
        version_id: u64,
    ) -> Result<Option<VersionRecord>, CatalogError> {
        let (Ok(device_sql_id), Ok(version_sql_id)) =
            (sql_integer(device_id), sql_integer(version_id))
        else {
            return Ok(None);
        };
        let mut connection = self.open_connection()?;
        let transaction = connection.transaction()?;
        let version = transaction
            .query_row(
                "SELECT versions.id, versions.size_bytes, versions.modified_time_ms, versions.file_sha256
                 FROM versions JOIN files ON files.id = versions.file_id
                 WHERE files.device_id = ?1 AND files.path = ?2 AND versions.id = ?3",
                params![device_sql_id, path, version_sql_id],
                |row| {
                    Ok(VersionRecord {
                        version_id: u64_from_row(row, 0)?,
                        size_bytes: u64_from_row(row, 1)?,
                        modified_time_ms: row.get(2)?,
                        file_sha256: row.get(3)?,
                        chunk_hashes: Vec::new(),
                    })
                },
            )
            .optional()?;
        let Some(mut version) = version else {
            return Ok(None);
        };
        let mut select = transaction.prepare(
            "SELECT chunk_hash FROM version_chunks WHERE version_id = ?1 ORDER BY position",
        )?;
        version.chunk_hashes = select
            .query_map([version_sql_id], |row| chunk_hash_from_row(row, 0))?
            .collect::<Result<Vec<_>, _>>()?;
        Ok(Some(version))
    }

    /// The offered `file_sha256` of an open upload, if it exists and belongs
    /// to the device.
    pub fn upload_file_sha256(
        &self,
        device_id: u64,
        upload_id: u64,
    ) -> Result<Option<[u8; HASH_BYTES]>, CatalogError> {
        let (Ok(device_sql_id), Ok(upload_sql_id)) =
            (sql_integer(device_id), sql_integer(upload_id))
        else {
            return Ok(None);
        };
        let connection = self.open_connection()?;
        Ok(connection
            .query_row(
                "SELECT file_sha256 FROM uploads WHERE id = ?1 AND device_id = ?2",
                [upload_sql_id, device_sql_id],
                |row| row.get(0),
            )
            .optional()?)
    }

    /// The chunk's status, or `None` when it is not in the catalog.
    pub fn chunk_status(&self, hash: &ChunkHash) -> Result<Option<ChunkStatus>, CatalogError> {
        let connection = self.open_connection()?;
        Ok(connection
            .query_row(
                "SELECT status FROM chunks WHERE hash = ?1",
                [hash.0],
                |row| row.get(0),
            )
            .optional()?)
    }
}

/// `id, name, paired_at_ms` → `DeviceRecord`.
fn device_from_row(row: &rusqlite::Row<'_>) -> rusqlite::Result<DeviceRecord> {
    Ok(DeviceRecord {
        device_id: u64_from_row(row, 0)?,
        name: row.get(1)?,
        paired_at_ms: row.get(2)?,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reader_cannot_write() {
        let folder = tempfile::tempdir().unwrap();
        let database_path = folder.path().join("index.sqlite");
        let _writer_connection = schema::open_writer_connection(&database_path).unwrap();
        let reader = CatalogReader::new(&database_path);
        let connection = reader.open_connection().unwrap();
        let result = connection.execute(
            "INSERT INTO devices (name, cert_sha256, paired_at_ms) VALUES ('x', x'00', 0)",
            [],
        );
        assert!(result.is_err());
        assert!(reader.list_devices().unwrap().is_empty());
        assert_eq!(reader.chunk_status(&ChunkHash([0; 32])).unwrap(), None);
    }

    #[test]
    fn version_of_file_and_upload_file_hash() {
        use super::super::writer::{self, FileOfferInput};

        let folder = tempfile::tempdir().unwrap();
        let database_path = folder.path().join("index.sqlite");
        let mut connection = schema::open_writer_connection(&database_path).unwrap();
        let device_id = writer::add_device(&mut connection, "phone", &[1; HASH_BYTES], 0).unwrap();
        let chunk_hash = ChunkHash([5; 32]);
        let offer = FileOfferInput {
            path: "a.bin".to_owned(),
            size_bytes: 10,
            modified_time_ms: 7,
            file_sha256: [3; HASH_BYTES],
            chunk_hashes: vec![chunk_hash],
        };
        let reader = CatalogReader::new(&database_path);

        let first = writer::offer_file(&mut connection, device_id, &offer, 0).unwrap();
        assert_eq!(
            reader
                .upload_file_sha256(device_id, first.upload_id)
                .unwrap(),
            Some([3; HASH_BYTES])
        );
        assert_eq!(
            reader
                .upload_file_sha256(device_id + 1, first.upload_id)
                .unwrap(),
            None
        );
        writer::record_chunk(&mut connection, &chunk_hash, 10, 0).unwrap();
        let first_version =
            writer::commit_upload(&mut connection, device_id, first.upload_id, 0).unwrap();
        assert_eq!(
            reader
                .upload_file_sha256(device_id, first.upload_id)
                .unwrap(),
            None
        );

        let changed_offer = FileOfferInput {
            modified_time_ms: 8,
            ..offer
        };
        let second = writer::offer_file(&mut connection, device_id, &changed_offer, 0).unwrap();
        let second_version =
            writer::commit_upload(&mut connection, device_id, second.upload_id, 0).unwrap();

        let old = reader
            .version_of_file(device_id, "a.bin", first_version)
            .unwrap()
            .unwrap();
        assert_eq!(old.modified_time_ms, 7);
        assert_eq!(old.chunk_hashes, vec![chunk_hash]);
        let latest = reader.latest_version(device_id, "a.bin").unwrap().unwrap();
        assert_eq!(latest.version_id, second_version);
        assert_eq!(
            reader
                .version_of_file(device_id, "other.bin", first_version)
                .unwrap(),
            None
        );
        assert_eq!(
            reader
                .version_of_file(device_id + 1, "a.bin", first_version)
                .unwrap(),
            None
        );
    }
}
