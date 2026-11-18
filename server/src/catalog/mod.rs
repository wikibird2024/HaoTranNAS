//! The catalog: all metadata in `index.sqlite` (WAL mode). Devices, files,
//! versions, chunk lists, chunk status and open uploads. No reference counts
//! (decision D-020): a chunk is unused when no `version_chunks` or
//! `upload_chunks` row names it.
//!
//! All writes go through one writer thread ([`writer::CatalogWriter`]); reads
//! use their own read-only connections ([`reader::CatalogReader`]).

pub mod reader;
pub mod schema;
pub mod writer;

use haotrannas_core::chunker::ChunkHash;
use rusqlite::types::{FromSql, FromSqlError, FromSqlResult, ValueRef};

/// Why a catalog call failed.
#[derive(Debug, thiserror::Error)]
pub enum CatalogError {
    /// SQLite returned an error.
    #[error("catalog database error: {0}")]
    Database(#[from] rusqlite::Error),
    /// The writer thread is gone (server shutting down, or it panicked).
    #[error("catalog writer has stopped")]
    WriterStopped,
    /// The database was made by a newer server.
    #[error("catalog schema version {found} is newer than this server supports ({supported})")]
    SchemaTooNew {
        /// `PRAGMA user_version` in the file.
        found: i32,
        /// The newest version this server knows.
        supported: i32,
    },
    /// A number does not fit in a signed 64-bit SQLite integer (the wire
    /// format keeps every `u64` below 2^63, so this is a caller bug).
    #[error("number {0} does not fit in a SQLite integer")]
    NumberTooLarge(u64),
    /// The writer thread could not be started.
    #[error("could not start the catalog writer thread: {0}")]
    WriterStart(std::io::Error),
    /// Every random upload id tried was taken (practically impossible).
    #[error("no free upload id found")]
    NoFreeUploadId,
    /// `remove_device` on a device that still has committed backups.
    #[error("device still has backed-up files; removing it would orphan them")]
    DeviceHasBackups,
}

/// Status of a chunk row (`chunks.status`).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ChunkStatus {
    /// Stored and last check passed.
    Ok,
    /// Scrub found the file damaged; it is repaired by the next upload.
    Bad,
}

impl ChunkStatus {
    /// The text stored in `chunks.status`.
    pub fn as_sql_text(self) -> &'static str {
        match self {
            Self::Ok => "ok",
            Self::Bad => "bad",
        }
    }
}

impl FromSql for ChunkStatus {
    fn column_result(value: ValueRef<'_>) -> FromSqlResult<Self> {
        match value.as_str()? {
            "ok" => Ok(Self::Ok),
            "bad" => Ok(Self::Bad),
            _ => Err(FromSqlError::InvalidType),
        }
    }
}

/// A `u64` (id, size) as a SQLite integer.
pub(crate) fn sql_integer(number: u64) -> Result<i64, CatalogError> {
    i64::try_from(number).map_err(|_| CatalogError::NumberTooLarge(number))
}

/// A hash read from a 32-byte BLOB column.
pub(crate) fn chunk_hash_from_row(
    row: &rusqlite::Row<'_>,
    column_index: usize,
) -> rusqlite::Result<ChunkHash> {
    Ok(ChunkHash(row.get(column_index)?))
}

/// A non-negative SQLite integer (id, size) read as `u64`.
pub(crate) fn u64_from_row(row: &rusqlite::Row<'_>, column_index: usize) -> rusqlite::Result<u64> {
    let number: i64 = row.get(column_index)?;
    u64::try_from(number)
        .map_err(|_| rusqlite::Error::IntegralValueOutOfRange(column_index, number))
}
