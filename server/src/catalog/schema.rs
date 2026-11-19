//! Table definitions and migrations: `devices` (with `revoked_at_ms` from
//! version 2), `files`, `versions`,
//! `version_chunks`, `chunks`, `uploads`, `upload_chunks`.
//!
//! The schema version lives in `PRAGMA user_version`. Migration `n` (counting
//! from 1) moves the file from version `n - 1` to `n`, in one transaction.

use std::path::Path;
use std::time::Duration;

use rusqlite::Connection;

use super::CatalogError;

/// How long a connection waits for a lock before failing with `SQLITE_BUSY`.
pub const BUSY_TIMEOUT: Duration = Duration::from_secs(5);

/// Migrations in order; index 0 makes version 1.
const MIGRATIONS: &[&str] = &[
    // Version 1: the first schema. `AUTOINCREMENT` on ids the outside world
    // sees, so a removed row's id is never handed out again.
    "
    CREATE TABLE devices (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT NOT NULL,
        cert_sha256 BLOB UNIQUE NOT NULL,
        paired_at_ms INTEGER NOT NULL
    );

    CREATE TABLE files (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        device_id INTEGER NOT NULL REFERENCES devices(id),
        path TEXT NOT NULL,
        UNIQUE (device_id, path)
    );

    CREATE TABLE versions (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        file_id INTEGER NOT NULL REFERENCES files(id),
        size_bytes INTEGER NOT NULL,
        modified_time_ms INTEGER NOT NULL,
        file_sha256 BLOB NOT NULL,
        committed_at_ms INTEGER NOT NULL
    );
    CREATE INDEX versions_by_file_id ON versions(file_id);

    CREATE TABLE version_chunks (
        version_id INTEGER NOT NULL REFERENCES versions(id),
        position INTEGER NOT NULL,
        chunk_hash BLOB NOT NULL,
        PRIMARY KEY (version_id, position)
    ) WITHOUT ROWID;
    CREATE INDEX version_chunks_by_chunk_hash ON version_chunks(chunk_hash);

    CREATE TABLE chunks (
        hash BLOB PRIMARY KEY,
        size_bytes INTEGER NOT NULL,
        status TEXT NOT NULL CHECK (status IN ('ok', 'bad')),
        created_at_ms INTEGER NOT NULL
    ) WITHOUT ROWID;

    CREATE TABLE uploads (
        id INTEGER PRIMARY KEY,
        device_id INTEGER NOT NULL REFERENCES devices(id),
        path TEXT NOT NULL,
        size_bytes INTEGER NOT NULL,
        modified_time_ms INTEGER NOT NULL,
        file_sha256 BLOB NOT NULL,
        created_at_ms INTEGER NOT NULL
    );
    CREATE INDEX uploads_by_created_at_ms ON uploads(created_at_ms);

    CREATE TABLE upload_chunks (
        upload_id INTEGER NOT NULL REFERENCES uploads(id) ON DELETE CASCADE,
        position INTEGER NOT NULL,
        chunk_hash BLOB NOT NULL,
        PRIMARY KEY (upload_id, position)
    ) WITHOUT ROWID;
    CREATE INDEX upload_chunks_by_chunk_hash ON upload_chunks(chunk_hash);
    ",
    // Version 2 (D-025): a revoked device keeps its row and its backups; its
    // certificate is refused like an unknown one.
    "
    ALTER TABLE devices ADD COLUMN revoked_at_ms INTEGER NULL;
    ",
];

/// The schema version this server writes.
pub fn latest_schema_version() -> i32 {
    i32::try_from(MIGRATIONS.len()).expect("migration count fits in i32")
}

/// Opens (or creates) the database for the single writer: sets the
/// connection options and runs pending migrations.
pub fn open_writer_connection(database_path: &Path) -> Result<Connection, CatalogError> {
    let mut connection = Connection::open(database_path)?;
    configure_writer_connection(&connection)?;
    migrate(&mut connection)?;
    Ok(connection)
}

/// WAL, foreign keys, `synchronous=FULL` (backup data: durability over
/// speed) and a busy timeout.
pub fn configure_writer_connection(connection: &Connection) -> Result<(), CatalogError> {
    connection.busy_timeout(BUSY_TIMEOUT)?;
    let journal_mode: String =
        connection.pragma_update_and_check(None, "journal_mode", "WAL", |row| row.get(0))?;
    // An in-memory database answers "memory"; a file must really be in WAL.
    debug_assert!(
        journal_mode.eq_ignore_ascii_case("wal") || journal_mode.eq_ignore_ascii_case("memory"),
        "journal_mode is {journal_mode}"
    );
    connection.pragma_update(None, "foreign_keys", true)?;
    connection.pragma_update(None, "synchronous", "FULL")?;
    Ok(())
}

/// Runs every migration newer than the file's `user_version`.
pub fn migrate(connection: &mut Connection) -> Result<(), CatalogError> {
    let found_version: i32 =
        connection.pragma_query_value(None, "user_version", |row| row.get(0))?;
    let supported_version = latest_schema_version();
    if found_version > supported_version {
        return Err(CatalogError::SchemaTooNew {
            found: found_version,
            supported: supported_version,
        });
    }
    let first_pending = usize::try_from(found_version).unwrap_or(0);
    for (index, migration_sql) in MIGRATIONS.iter().enumerate().skip(first_pending) {
        let transaction = connection.transaction()?;
        transaction.execute_batch(migration_sql)?;
        let new_version = i32::try_from(index + 1).expect("migration count fits in i32");
        transaction.pragma_update(None, "user_version", new_version)?;
        transaction.commit()?;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn new_file_gets_latest_schema_and_wal() {
        let folder = tempfile::tempdir().unwrap();
        let database_path = folder.path().join("index.sqlite");
        let connection = open_writer_connection(&database_path).unwrap();
        let version: i32 = connection
            .pragma_query_value(None, "user_version", |row| row.get(0))
            .unwrap();
        assert_eq!(version, latest_schema_version());
        let journal_mode: String = connection
            .pragma_query_value(None, "journal_mode", |row| row.get(0))
            .unwrap();
        assert_eq!(journal_mode, "wal");
        let foreign_keys: bool = connection
            .pragma_query_value(None, "foreign_keys", |row| row.get(0))
            .unwrap();
        assert!(foreign_keys);
        // 2 = FULL.
        let synchronous: i32 = connection
            .pragma_query_value(None, "synchronous", |row| row.get(0))
            .unwrap();
        assert_eq!(synchronous, 2);
        drop(connection);

        // Reopening runs no migration again.
        open_writer_connection(&database_path).unwrap();
    }

    #[test]
    fn newer_schema_is_refused() {
        let folder = tempfile::tempdir().unwrap();
        let database_path = folder.path().join("index.sqlite");
        let connection = open_writer_connection(&database_path).unwrap();
        connection
            .pragma_update(None, "user_version", latest_schema_version() + 1)
            .unwrap();
        drop(connection);
        assert!(matches!(
            open_writer_connection(&database_path),
            Err(CatalogError::SchemaTooNew { .. })
        ));
    }

    #[test]
    fn version_one_file_migrates_and_keeps_its_devices() {
        let folder = tempfile::tempdir().unwrap();
        let database_path = folder.path().join("index.sqlite");
        {
            let mut connection = Connection::open(&database_path).unwrap();
            let transaction = connection.transaction().unwrap();
            transaction.execute_batch(MIGRATIONS[0]).unwrap();
            transaction.pragma_update(None, "user_version", 1).unwrap();
            transaction.commit().unwrap();
            connection
                .execute(
                    "INSERT INTO devices (name, cert_sha256, paired_at_ms) VALUES ('phone', ?1, 5)",
                    [vec![7_u8; 32]],
                )
                .unwrap();
        }
        let connection = open_writer_connection(&database_path).unwrap();
        let (name, revoked_at_ms): (String, Option<i64>) = connection
            .query_row("SELECT name, revoked_at_ms FROM devices", [], |row| {
                Ok((row.get(0)?, row.get(1)?))
            })
            .unwrap();
        assert_eq!((name.as_str(), revoked_at_ms), ("phone", None));
    }

    #[test]
    fn bad_chunk_status_is_refused() {
        let folder = tempfile::tempdir().unwrap();
        let connection = open_writer_connection(&folder.path().join("index.sqlite")).unwrap();
        let result = connection.execute(
            "INSERT INTO chunks (hash, size_bytes, status, created_at_ms) VALUES (?1, 1, 'lost', 0)",
            [vec![0_u8; 32]],
        );
        assert!(result.is_err());
    }
}
