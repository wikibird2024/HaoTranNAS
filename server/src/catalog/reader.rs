//! Read-only queries: device lookup by certificate fingerprint, device list,
//! latest version of a file (its manifest), chunk status, and one page of a
//! folder listing (`ListDir`, spec §9).
//!
//! Every call opens a read-only connection (`SQLITE_OPEN_READ_ONLY`) and
//! blocks: async callers use `tokio::task::spawn_blocking`. In WAL mode
//! readers never wait for the writer.

use std::path::{Path, PathBuf};

use haotrannas_core::chunker::ChunkHash;
use haotrannas_core::limits::HASH_BYTES;
use haotrannas_core::message::{DirEntry, DirEntryKind};
use rusqlite::{Connection, OpenFlags, OptionalExtension, Transaction, params};

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
    /// When it was revoked (D-025); `None` while it may connect.
    pub revoked_at_ms: Option<i64>,
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

/// One page of a folder listing (`DirEntries`).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DirectoryPage {
    /// Children sorted by name, byte-wise.
    pub entries: Vec<DirEntry>,
    /// True if more children follow this page.
    pub has_more: bool,
}

/// One `chunks` row, as scrub walks them.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ChunkRecord {
    /// The chunk's SHA-256 (its name).
    pub hash: ChunkHash,
    /// Size recorded when it was stored.
    pub size_bytes: u64,
    /// Status in the catalog.
    pub status: ChunkStatus,
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

    /// The device that owns this client certificate fingerprint, if paired
    /// and not revoked (a revoked certificate is refused like an unknown
    /// one, D-025).
    pub fn device_by_cert(
        &self,
        cert_sha256: &[u8; HASH_BYTES],
    ) -> Result<Option<DeviceRecord>, CatalogError> {
        let connection = self.open_connection()?;
        Ok(connection
            .query_row(
                "SELECT id, name, paired_at_ms, revoked_at_ms FROM devices
                 WHERE cert_sha256 = ?1 AND revoked_at_ms IS NULL",
                [cert_sha256],
                device_from_row,
            )
            .optional()?)
    }

    /// True if any device row (revoked or not) has this fingerprint.
    pub fn has_device_with_cert(
        &self,
        cert_sha256: &[u8; HASH_BYTES],
    ) -> Result<bool, CatalogError> {
        let connection = self.open_connection()?;
        Ok(connection.query_row(
            "SELECT EXISTS (SELECT 1 FROM devices WHERE cert_sha256 = ?1)",
            [cert_sha256],
            |row| row.get(0),
        )?)
    }

    /// Every device, revoked ones included, by id.
    pub fn list_devices(&self) -> Result<Vec<DeviceRecord>, CatalogError> {
        let connection = self.open_connection()?;
        let mut select = connection
            .prepare("SELECT id, name, paired_at_ms, revoked_at_ms FROM devices ORDER BY id")?;
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

    /// Up to `max_count` chunk rows with a hash greater than `after_hash`
    /// (from the start when `None`), in hash order. Scrub walks the whole
    /// table with it, one small page at a time.
    pub fn chunk_page(
        &self,
        after_hash: Option<&ChunkHash>,
        max_count: usize,
    ) -> Result<Vec<ChunkRecord>, CatalogError> {
        let connection = self.open_connection()?;
        let mut select = connection.prepare(
            "SELECT hash, size_bytes, status FROM chunks WHERE hash > ?1 ORDER BY hash LIMIT ?2",
        )?;
        // Every hash is 32 bytes, so the empty BLOB sorts before all of them.
        let after_bytes: &[u8] = after_hash.map_or(&[], |hash| &hash.0);
        let max_sql_count = sql_integer(u64::try_from(max_count).unwrap_or(u64::MAX))?;
        let records = select
            .query_map(params![after_bytes, max_sql_count], |row| {
                Ok(ChunkRecord {
                    hash: chunk_hash_from_row(row, 0)?,
                    size_bytes: u64_from_row(row, 1)?,
                    status: row.get(2)?,
                })
            })?
            .collect::<Result<Vec<_>, _>>()?;
        Ok(records)
    }

    /// The hashes from `hashes` that have no `chunks` row (one connection
    /// for the whole list). Cleanup uses it to find orphan chunk files.
    pub fn hashes_not_in_catalog(
        &self,
        hashes: &[ChunkHash],
    ) -> Result<Vec<ChunkHash>, CatalogError> {
        let connection = self.open_connection()?;
        let mut has_row =
            connection.prepare("SELECT EXISTS (SELECT 1 FROM chunks WHERE hash = ?1)")?;
        let mut unknown_hashes = Vec::new();
        for hash in hashes {
            let is_known: bool = has_row.query_row([hash.0], |row| row.get(0))?;
            if !is_known {
                unknown_hashes.push(*hash);
            }
        }
        Ok(unknown_hashes)
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

    /// True if a device row with this id exists (revoked or not: a revoked
    /// device's backups stay restorable, D-025).
    pub fn device_exists(&self, device_id: u64) -> Result<bool, CatalogError> {
        let Ok(device_sql_id) = sql_integer(device_id) else {
            return Ok(false);
        };
        let connection = self.open_connection()?;
        Ok(connection.query_row(
            "SELECT EXISTS (SELECT 1 FROM devices WHERE id = ?1)",
            [device_sql_id],
            |row| row.get(0),
        )?)
    }

    /// True if the device has a committed version (any path) of a file
    /// with this SHA-256: the check before storing its thumbnail (spec §16).
    ///
    /// Cost: walks the device's files through `versions_by_file_id`, no
    /// index on `file_sha256` (no schema change, so an older server can
    /// still open the catalog). It runs once per uploaded file, far
    /// cheaper than the upload itself.
    pub fn device_has_file_sha256(
        &self,
        device_id: u64,
        file_sha256: &[u8; HASH_BYTES],
    ) -> Result<bool, CatalogError> {
        let Ok(device_sql_id) = sql_integer(device_id) else {
            return Ok(false);
        };
        let connection = self.open_connection()?;
        Ok(connection.query_row(
            "SELECT EXISTS (
                 SELECT 1 FROM files JOIN versions ON versions.file_id = files.id
                 WHERE files.device_id = ?1 AND versions.file_sha256 = ?2)",
            params![device_sql_id, file_sha256],
            |row| row.get(0),
        )?)
    }

    /// True if the chunk may be sent in `ChunkContent` (spec §9): stored
    /// with status ok and named by a committed version. A chunk that only an
    /// open upload names is not readable.
    pub fn is_chunk_readable(&self, hash: &ChunkHash) -> Result<bool, CatalogError> {
        let connection = self.open_connection()?;
        Ok(connection.query_row(
            "SELECT EXISTS (
                 SELECT 1 FROM chunks WHERE hash = ?1 AND status = 'ok'
                 AND EXISTS (SELECT 1 FROM version_chunks WHERE chunk_hash = ?1))",
            [hash.0],
            |row| row.get(0),
        )?)
    }

    /// One page of the direct children of `directory_path` ("" = root) in
    /// the device's committed files: names `> start_after` (byte-wise), at
    /// most `max_entries`. `None` when a non-root folder has no children at
    /// all (`NOT_FOUND`). The caller checks the path rules and the range of
    /// `max_entries`.
    ///
    /// Cost: a few index seeks per entry returned, never a scan of the
    /// whole folder, so a page stays fast with 100k files in one folder.
    /// [`FolderListing`] explains how.
    pub fn list_directory(
        &self,
        device_id: u64,
        directory_path: &str,
        start_after: &str,
        max_entries: usize,
    ) -> Result<Option<DirectoryPage>, CatalogError> {
        let Ok(device_sql_id) = sql_integer(device_id) else {
            return Ok(None);
        };
        let mut connection = self.open_connection()?;
        // One snapshot for the whole page.
        let transaction = connection.transaction()?;
        let listing = FolderListing::new(&transaction, device_sql_id, directory_path);
        if !directory_path.is_empty() && !listing.has_any_child()? {
            return Ok(None);
        }
        let mut entries = Vec::new();
        let mut last_name = start_after.to_owned();
        let mut has_more = false;
        while let Some(name) = listing.next_child_name(&last_name)? {
            if entries.len() >= max_entries {
                has_more = true;
                break;
            }
            if let Some(entry) = listing.entry_for(&name)? {
                entries.push(entry);
            }
            last_name = name;
        }
        Ok(Some(DirectoryPage { entries, has_more }))
    }
}

/// Lists one folder by seeking in the `UNIQUE (device_id, path)` index of
/// `files` (SQLite's automatic index `sqlite_autoindex_files_1`, BINARY
/// collation = byte order of UTF-8); no new index is needed. Folders are not
/// stored: a folder exists while a committed file path lies below it.
///
/// ```text
///  prefix = "photos/"  (root: "")          subtree of child N = paths in
///  range  = ["photos/", "photos0")         [prefix+N+"/", prefix+N+"0")
///                                           ('0' is the byte after '/')
///  next name after A (A = start_after, then the last name sent):
///    1. first path in (prefix+A, prefix+A+"/")    names A + a byte below '/'
///    2. else first path >= prefix+A+"0"           jumps over A's subtree
///    -> N = the component of that path after the prefix; if N <= A
///       (folder "a" seen after A = "a.txt"), skip N's subtree, seek again
///    3. path order differs from name order for a folder D: "D-x" and
///       "D.txt" sort before "D/..." because '-' and '.' are below '/'.
///       So each shorter name M = N[..i] with N[i] below '/' and M > A is
///       tried as a folder (shortest first); the first that exists wins.
///  entry for N: folder if its subtree holds a file (a folder wins over a
///               file of the same name), else the file's latest version
/// ```
///
/// Each step is one `ORDER BY path LIMIT 1` seek, so a page of `k` entries
/// costs about `4 * k` seeks whatever the folder size. Every probe skips
/// file rows without a committed version.
struct FolderListing<'connection> {
    transaction: &'connection Transaction<'connection>,
    device_sql_id: i64,
    /// `directory_path + "/"`, or "" for the root.
    prefix: String,
    /// End of the folder's range (exclusive); `None` for the root.
    prefix_end: Option<String>,
}

impl<'connection> FolderListing<'connection> {
    fn new(
        transaction: &'connection Transaction<'connection>,
        device_sql_id: i64,
        directory_path: &str,
    ) -> Self {
        let (prefix, prefix_end) = if directory_path.is_empty() {
            (String::new(), None)
        } else {
            (
                format!("{directory_path}/"),
                Some(format!("{directory_path}0")),
            )
        };
        Self {
            transaction,
            device_sql_id,
            prefix,
            prefix_end,
        }
    }

    /// True if any committed file lies below the folder.
    fn has_any_child(&self) -> Result<bool, CatalogError> {
        Ok(self
            .first_path(&self.prefix, true, self.prefix_end.as_deref())?
            .is_some())
    }

    /// The smallest child name byte-wise greater than `after`.
    fn next_child_name(&self, after: &str) -> Result<Option<String>, CatalogError> {
        // A name never holds '/'. With one in `after`, only the part before
        // it can be a prefix of a name, and that name's subtree is skipped.
        let (after_stem, has_slash) = match after.find('/') {
            Some(slash_index) => (&after[..slash_index], true),
            None => (after, false),
        };
        let mut found_path = None;
        if !has_slash {
            let lower = format!("{}{after}", self.prefix);
            let upper = format!("{lower}/");
            found_path = self.first_path(&lower, false, Some(&upper))?;
        }
        let mut lower = format!("{}{after_stem}0", self.prefix);
        let name = loop {
            if found_path.is_none() {
                found_path = self.first_path(&lower, true, self.prefix_end.as_deref())?;
            }
            let Some(path) = found_path.take() else {
                return Ok(None);
            };
            let below_prefix = &path[self.prefix.len()..];
            let name = below_prefix.split('/').next().unwrap_or(below_prefix);
            if name > after {
                break name.to_owned();
            }
            // Mirror of step 3: a folder D that is a prefix of `after`
            // ("a" for "a.txt") sorts after it in path order. It was listed
            // already, so its subtree is skipped.
            lower = format!("{}{name}0", self.prefix);
        };
        // Step 3: a folder whose name is a shorter prefix of `name`.
        for (byte_index, byte) in name.bytes().enumerate().skip(1) {
            if byte >= b'/' {
                continue;
            }
            // Bytes below '/' are ASCII, so `byte_index` is a char boundary.
            let shorter_name = &name[..byte_index];
            if shorter_name > after && self.is_folder(shorter_name)? {
                return Ok(Some(shorter_name.to_owned()));
            }
        }
        Ok(Some(name))
    }

    /// True if a committed file lies below child `name`.
    fn is_folder(&self, name: &str) -> Result<bool, CatalogError> {
        let lower = format!("{}{name}/", self.prefix);
        let upper = format!("{}{name}0", self.prefix);
        Ok(self.first_path(&lower, true, Some(&upper))?.is_some())
    }

    /// The `DirEntry` for child `name`: a folder, else the file's latest
    /// version. `None` if neither exists (cannot happen inside one snapshot).
    fn entry_for(&self, name: &str) -> Result<Option<DirEntry>, CatalogError> {
        if self.is_folder(name)? {
            return Ok(Some(DirEntry {
                name: name.to_owned(),
                kind: DirEntryKind::Directory,
                size_bytes: 0,
                modified_time_ms: 0,
                version_id: 0,
            }));
        }
        let mut select = self.transaction.prepare_cached(
            "SELECT versions.id, versions.size_bytes, versions.modified_time_ms
             FROM files JOIN versions ON versions.file_id = files.id
             WHERE files.device_id = ?1 AND files.path = ?2
             ORDER BY versions.id DESC LIMIT 1",
        )?;
        let file_path = format!("{}{name}", self.prefix);
        Ok(select
            .query_row(params![self.device_sql_id, file_path], |row| {
                Ok(DirEntry {
                    name: name.to_owned(),
                    kind: DirEntryKind::File,
                    size_bytes: u64_from_row(row, 1)?,
                    modified_time_ms: row.get(2)?,
                    version_id: u64_from_row(row, 0)?,
                })
            })
            .optional()?)
    }

    /// The first committed file path `> lower` (`>= lower` when
    /// `is_lower_inclusive`) and `< upper` (`None`: no upper bound).
    fn first_path(
        &self,
        lower: &str,
        is_lower_inclusive: bool,
        upper: Option<&str>,
    ) -> Result<Option<String>, CatalogError> {
        let lower_operator = if is_lower_inclusive { ">=" } else { ">" };
        let upper_condition = if upper.is_some() { "AND path < ?3" } else { "" };
        let sql = format!(
            "SELECT path FROM files
             WHERE device_id = ?1 AND path {lower_operator} ?2 {upper_condition}
               AND EXISTS (SELECT 1 FROM versions WHERE versions.file_id = files.id)
             ORDER BY path LIMIT 1"
        );
        let mut select = self.transaction.prepare_cached(&sql)?;
        let found = match upper {
            Some(upper) => select
                .query_row(params![self.device_sql_id, lower, upper], |row| row.get(0))
                .optional()?,
            None => select
                .query_row(params![self.device_sql_id, lower], |row| row.get(0))
                .optional()?,
        };
        Ok(found)
    }
}

/// `id, name, paired_at_ms, revoked_at_ms` → `DeviceRecord`.
fn device_from_row(row: &rusqlite::Row<'_>) -> rusqlite::Result<DeviceRecord> {
    Ok(DeviceRecord {
        device_id: u64_from_row(row, 0)?,
        name: row.get(1)?,
        paired_at_ms: row.get(2)?,
        revoked_at_ms: row.get(3)?,
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

    /// Adds a committed version of (device, path) straight in SQL (fast,
    /// for listing tests). `size_bytes` doubles as the modified time.
    fn insert_committed_file(
        connection: &Connection,
        device_id: u64,
        path: &str,
        size_bytes: i64,
    ) -> u64 {
        let device_sql_id = sql_integer(device_id).unwrap();
        connection
            .execute(
                "INSERT INTO files (device_id, path) VALUES (?1, ?2)
                 ON CONFLICT (device_id, path) DO NOTHING",
                params![device_sql_id, path],
            )
            .unwrap();
        let file_id: i64 = connection
            .query_row(
                "SELECT id FROM files WHERE device_id = ?1 AND path = ?2",
                params![device_sql_id, path],
                |row| row.get(0),
            )
            .unwrap();
        connection
            .execute(
                "INSERT INTO versions (file_id, size_bytes, modified_time_ms, file_sha256, committed_at_ms)
                 VALUES (?1, ?2, ?2, ?3, 0)",
                params![file_id, size_bytes, [0_u8; HASH_BYTES]],
            )
            .unwrap();
        u64::try_from(connection.last_insert_rowid()).unwrap()
    }

    fn names_and_kinds(page: &DirectoryPage) -> Vec<(String, DirEntryKind)> {
        page.entries
            .iter()
            .map(|entry| (entry.name.clone(), entry.kind))
            .collect()
    }

    /// Every page of a folder, `page_size` entries at a time.
    fn list_all(
        reader: &CatalogReader,
        device_id: u64,
        path: &str,
        page_size: usize,
    ) -> Vec<DirEntry> {
        let mut all_entries = Vec::new();
        let mut start_after = String::new();
        loop {
            let page = reader
                .list_directory(device_id, path, &start_after, page_size)
                .unwrap()
                .unwrap();
            assert!(page.entries.len() <= page_size);
            all_entries.extend(page.entries.iter().cloned());
            if !page.has_more {
                return all_entries;
            }
            assert_eq!(page.entries.len(), page_size);
            start_after = page.entries.last().unwrap().name.clone();
        }
    }

    /// The catalog both spec tests list.
    struct SpecCatalog {
        _folder: tempfile::TempDir,
        reader: CatalogReader,
        device_id: u64,
        other_device_id: u64,
        empty_device_id: u64,
        latest_version_id: u64,
    }

    fn spec_catalog() -> SpecCatalog {
        use super::super::writer;

        let folder = tempfile::tempdir().unwrap();
        let database_path = folder.path().join("index.sqlite");
        let mut connection = schema::open_writer_connection(&database_path).unwrap();
        let device_id = writer::add_device(&mut connection, "phone", &[1; HASH_BYTES], 0).unwrap();
        let other_device_id =
            writer::add_device(&mut connection, "tablet", &[2; HASH_BYTES], 0).unwrap();
        let empty_device_id =
            writer::add_device(&mut connection, "new", &[3; HASH_BYTES], 0).unwrap();
        for path in [
            "a/x.txt",
            "a-b",
            "a.d/y",
            "b",
            "b/c",
            "z/deep/er/f",
            "\u{e9}.txt",
        ] {
            insert_committed_file(&connection, device_id, path, 1);
        }
        insert_committed_file(&connection, device_id, "a.txt", 5);
        let latest_version_id = insert_committed_file(&connection, device_id, "a.txt", 9);
        insert_committed_file(&connection, other_device_id, "other.txt", 1);
        // File rows without a committed version are invisible.
        connection
            .execute(
                "INSERT INTO files (device_id, path) VALUES (?1, 'ghost/f'), (?1, 'ghost2')",
                [sql_integer(device_id).unwrap()],
            )
            .unwrap();
        SpecCatalog {
            reader: CatalogReader::new(&database_path),
            _folder: folder,
            device_id,
            other_device_id,
            empty_device_id,
            latest_version_id,
        }
    }

    #[test]
    fn list_directory_root_order_kinds_and_paging_follow_spec_section_9() {
        use DirEntryKind::{Directory, File};

        let catalog = spec_catalog();
        let (reader, device_id) = (&catalog.reader, catalog.device_id);
        let root = reader
            .list_directory(device_id, "", "", 1000)
            .unwrap()
            .unwrap();
        let expected_root = vec![
            ("a".to_owned(), Directory),
            ("a-b".to_owned(), File),
            ("a.d".to_owned(), Directory),
            ("a.txt".to_owned(), File),
            // Both a file and a folder: the folder is shown.
            ("b".to_owned(), Directory),
            ("z".to_owned(), Directory),
            ("\u{e9}.txt".to_owned(), File),
        ];
        assert_eq!(names_and_kinds(&root), expected_root);
        assert!(!root.has_more);
        let a_txt = &root.entries[3];
        assert_eq!(
            (a_txt.size_bytes, a_txt.modified_time_ms, a_txt.version_id),
            (9, 9, catalog.latest_version_id)
        );
        let folder_a = &root.entries[0];
        assert_eq!(
            (
                folder_a.size_bytes,
                folder_a.modified_time_ms,
                folder_a.version_id
            ),
            (0, 0, 0)
        );

        // Paging gives the same list, for every page size.
        for page_size in 1..=8 {
            let paged = list_all(reader, device_id, "", page_size);
            assert_eq!(paged, root.entries, "page size {page_size}");
        }
        let first_two = reader
            .list_directory(device_id, "", "", 2)
            .unwrap()
            .unwrap();
        assert_eq!(names_and_kinds(&first_two), expected_root[..2].to_vec());
        assert!(first_two.has_more);
        let last_one = reader
            .list_directory(device_id, "", "z", 2)
            .unwrap()
            .unwrap();
        assert_eq!(names_and_kinds(&last_one), expected_root[6..].to_vec());
        assert!(!last_one.has_more);
        // `start_after` need not be a name that exists, and may hold '/'.
        let after_a_slash = reader
            .list_directory(device_id, "", "a/zzz", 1000)
            .unwrap()
            .unwrap();
        assert_eq!(names_and_kinds(&after_a_slash), expected_root[4..].to_vec());
        let after_aa = reader
            .list_directory(device_id, "", "a.c", 1000)
            .unwrap()
            .unwrap();
        assert_eq!(names_and_kinds(&after_aa), expected_root[2..].to_vec());
    }

    #[test]
    fn list_directory_subfolders_not_found_and_devices_follow_spec_section_9() {
        use DirEntryKind::{Directory, File};

        let catalog = spec_catalog();
        let (reader, device_id) = (&catalog.reader, catalog.device_id);
        let (other_device_id, empty_device_id) = (catalog.other_device_id, catalog.empty_device_id);
        let folder_a = reader
            .list_directory(device_id, "a", "", 10)
            .unwrap()
            .unwrap();
        assert_eq!(names_and_kinds(&folder_a), vec![("x.txt".to_owned(), File)]);
        let folder_z = reader
            .list_directory(device_id, "z", "", 10)
            .unwrap()
            .unwrap();
        assert_eq!(
            names_and_kinds(&folder_z),
            vec![("deep".to_owned(), Directory)]
        );
        let deep = reader
            .list_directory(device_id, "z/deep/er", "", 10)
            .unwrap()
            .unwrap();
        assert_eq!(names_and_kinds(&deep), vec![("f".to_owned(), File)]);
        let folder_b = reader
            .list_directory(device_id, "b", "", 10)
            .unwrap()
            .unwrap();
        assert_eq!(names_and_kinds(&folder_b), vec![("c".to_owned(), File)]);
        // An existing folder past its last name: empty, not NOT_FOUND.
        let past_end = reader
            .list_directory(device_id, "a", "zzz", 10)
            .unwrap()
            .unwrap();
        assert!(past_end.entries.is_empty() && !past_end.has_more);

        // Non-root path with no children → None (NOT_FOUND).
        for path in ["a.txt", "nothing", "ghost", "a/x.txt", "z/deep/e"] {
            assert_eq!(
                reader.list_directory(device_id, path, "", 10).unwrap(),
                None,
                "{path}"
            );
        }
        // Empty root → empty list.
        let empty = reader
            .list_directory(empty_device_id, "", "", 10)
            .unwrap()
            .unwrap();
        assert!(empty.entries.is_empty() && !empty.has_more);
        // Other device: only its own files.
        let other = reader
            .list_directory(other_device_id, "", "", 10)
            .unwrap()
            .unwrap();
        assert_eq!(
            names_and_kinds(&other),
            vec![("other.txt".to_owned(), File)]
        );

        assert!(reader.device_exists(device_id).unwrap());
        assert!(!reader.device_exists(99).unwrap());
    }

    /// The seek walk against a brute-force model on random trees whose names
    /// mix bytes below '/' ('-', '.', ' ') with letters and a 2-byte UTF-8
    /// letter: every folder, every page size, and `start_after` taken from
    /// names, non-names and slashed text.
    #[test]
    fn list_directory_matches_a_brute_force_model() {
        use std::collections::{BTreeMap, BTreeSet};

        use super::super::writer;

        const NAME_PIECES: [&str; 6] = ["a", "b", "-", ".", " ", "\u{e9}"];
        let mut random_state: u64 = 0x2545_F491_4F6C_DD1D;
        let mut next_random = |limit: usize| {
            random_state ^= random_state << 13;
            random_state ^= random_state >> 7;
            random_state ^= random_state << 17;
            usize::try_from(random_state % limit as u64).unwrap()
        };

        for round in 0..6 {
            let folder = tempfile::tempdir().unwrap();
            let database_path = folder.path().join("index.sqlite");
            let mut connection = schema::open_writer_connection(&database_path).unwrap();
            let device_id =
                writer::add_device(&mut connection, "phone", &[1; HASH_BYTES], 0).unwrap();
            let mut paths = BTreeSet::new();
            for _ in 0..60 {
                let component_count = 1 + next_random(3);
                let components: Vec<String> = (0..component_count)
                    .map(|_| {
                        let piece_count = 1 + next_random(3);
                        (0..piece_count)
                            .map(|_| NAME_PIECES[next_random(NAME_PIECES.len())])
                            .collect()
                    })
                    .collect();
                let path = components.join("/");
                if haotrannas_core::path_rules::validate_path(&path).is_ok() {
                    paths.insert(path);
                }
            }
            for path in &paths {
                insert_committed_file(&connection, device_id, path, 1);
            }
            let reader = CatalogReader::new(&database_path);

            // Model: folder → child name → is it a folder.
            let mut model: BTreeMap<String, BTreeMap<String, bool>> = BTreeMap::new();
            model.entry(String::new()).or_default();
            for path in &paths {
                let components: Vec<&str> = path.split('/').collect();
                for depth in 0..components.len() {
                    let parent = components[..depth].join("/");
                    let is_folder = depth + 1 < components.len();
                    let children = model.entry(parent).or_default();
                    let shown_as_folder = children.entry(components[depth].to_owned()).or_default();
                    *shown_as_folder |= is_folder;
                }
            }
            for (parent, children) in &model {
                let expected: Vec<(String, DirEntryKind)> = children
                    .iter()
                    .map(|(name, is_folder)| {
                        let kind = if *is_folder {
                            DirEntryKind::Directory
                        } else {
                            DirEntryKind::File
                        };
                        (name.clone(), kind)
                    })
                    .collect();
                for page_size in [1, 2, 3, 1000] {
                    let listed = list_all(&reader, device_id, parent, page_size);
                    let listed: Vec<(String, DirEntryKind)> = listed
                        .into_iter()
                        .map(|entry| (entry.name, entry.kind))
                        .collect();
                    assert_eq!(listed, expected, "round {round}, folder {parent:?}");
                }
                let mut start_values: Vec<String> = children.keys().cloned().collect();
                start_values.extend(["a.", "a/", "a-/b", "b", "\u{e9}", "zz"].map(str::to_owned));
                for start_after in start_values {
                    let page = reader
                        .list_directory(device_id, parent, &start_after, 1000)
                        .unwrap()
                        .unwrap();
                    let expected_after: Vec<(String, DirEntryKind)> = expected
                        .iter()
                        .filter(|(name, _)| name.as_str() > start_after.as_str())
                        .cloned()
                        .collect();
                    assert_eq!(
                        names_and_kinds(&page),
                        expected_after,
                        "round {round}, folder {parent:?}, after {start_after:?}"
                    );
                }
            }
        }
    }

    /// 20 000 files in one folder: each 1000-entry page takes a handful of
    /// index seeks per entry, not a scan of the folder. Debug build budget:
    /// 1 s per page.
    #[test]
    fn list_directory_stays_fast_with_20k_files_in_one_folder() {
        use super::super::writer;

        const FILE_COUNT: usize = 20_000;
        const PAGE_TIME_BUDGET_MS: u128 = 1_000;

        let folder = tempfile::tempdir().unwrap();
        let database_path = folder.path().join("index.sqlite");
        let mut connection = schema::open_writer_connection(&database_path).unwrap();
        let device_id = writer::add_device(&mut connection, "phone", &[1; HASH_BYTES], 0).unwrap();
        let transaction = connection.transaction().unwrap();
        for index in 0..FILE_COUNT {
            let path = format!("big/IMG_{index:05}.jpg");
            insert_committed_file(&transaction, device_id, &path, 1);
        }
        insert_committed_file(&transaction, device_id, "small.txt", 1);
        transaction.commit().unwrap();
        let reader = CatalogReader::new(&database_path);

        let max_entries = haotrannas_core::limits::MAX_LIST_DIR_ENTRIES as usize;
        for start_after in ["", "IMG_09999.jpg", "IMG_19500.jpg"] {
            let started_at = std::time::Instant::now();
            let page = reader
                .list_directory(device_id, "big", start_after, max_entries)
                .unwrap()
                .unwrap();
            let elapsed_ms = started_at.elapsed().as_millis();
            eprintln!("page after {start_after:?}: {elapsed_ms} ms");
            assert!(
                elapsed_ms < PAGE_TIME_BUDGET_MS,
                "page after {start_after:?} took {elapsed_ms} ms"
            );
            assert!(!page.entries.is_empty());
            assert!(
                page.entries
                    .iter()
                    .all(|entry| entry.name.as_str() > start_after)
            );
        }
        // The root skips the 20k-file subtree in one seek.
        let started_at = std::time::Instant::now();
        let root = reader
            .list_directory(device_id, "", "", max_entries)
            .unwrap()
            .unwrap();
        assert!(started_at.elapsed().as_millis() < PAGE_TIME_BUDGET_MS);
        assert_eq!(
            names_and_kinds(&root),
            vec![
                ("big".to_owned(), DirEntryKind::Directory),
                ("small.txt".to_owned(), DirEntryKind::File)
            ]
        );
        // Every file comes back exactly once, in order.
        let all_entries = list_all(&reader, device_id, "big", max_entries);
        assert_eq!(all_entries.len(), FILE_COUNT);
        assert!(
            all_entries
                .windows(2)
                .all(|pair| pair[0].name < pair[1].name)
        );
    }
}
