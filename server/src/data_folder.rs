//! The data folder layout (docs/architecture.md section 9), `init`, the
//! dev device used by `run --dev-plain`, and the checks before a TLS `run`.
//!
//! ```text
//!  <data_dir>/            mode 0700
//!    tls/                 server identity + device CA (TlsIdentity)
//!    index.sqlite         catalog
//!    chunks/  tmp/        chunk store
//!    admin.sock           admin socket while the server runs
//! ```

use std::fs::{self, DirBuilder, Permissions};
use std::os::unix::fs::{DirBuilderExt, PermissionsExt};
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::{SystemTime, UNIX_EPOCH};

use anyhow::{Context, bail};
use haotrannas_core::limits::HASH_BYTES;

use crate::catalog::reader::CatalogReader;
use crate::catalog::writer::CatalogWriter;
use crate::catalog::{schema, writer};
use crate::chunk_store::ChunkStore;
use crate::handlers::upload::UploadStorage;
use crate::tls_identity::TlsIdentity;

/// Folder for the TLS identity.
const TLS_DIRECTORY_NAME: &str = "tls";
/// Catalog database file.
const DATABASE_FILE_NAME: &str = "index.sqlite";
/// The data folder is the server user's only.
const DATA_DIRECTORY_MODE: u32 = 0o700;

/// Device id of every `--dev-plain` connection (spec section 1).
pub const DEV_DEVICE_ID: u64 = 1;
/// Name of the dev device row.
pub const DEV_DEVICE_NAME: &str = "dev";
/// `cert_sha256` of the dev device row: all zero bytes. No real certificate
/// hashes to this (it would be a SHA-256 preimage), so a TLS client can never
/// be matched to the dev device.
pub const DEV_DEVICE_CERT_SHA256: [u8; HASH_BYTES] = [0; HASH_BYTES];

/// Paths inside one data folder.
#[derive(Debug, Clone)]
pub struct DataFolder {
    root_directory: PathBuf,
}

impl DataFolder {
    /// The layout under `root_directory` (nothing is touched yet).
    pub fn new(root_directory: PathBuf) -> Self {
        Self { root_directory }
    }

    pub fn root_directory(&self) -> &Path {
        &self.root_directory
    }

    pub fn tls_directory(&self) -> PathBuf {
        self.root_directory.join(TLS_DIRECTORY_NAME)
    }

    pub fn database_path(&self) -> PathBuf {
        self.root_directory.join(DATABASE_FILE_NAME)
    }

    /// True once `init` has run here.
    pub fn is_initialized(&self) -> bool {
        self.database_path().exists()
    }

    /// `init`: makes the folder (0700), the TLS identity, the catalog and the
    /// chunk folders. Refuses if `tls/` already exists, naming the server id
    /// it holds. Returns the new server's short id.
    pub fn initialize(&self) -> anyhow::Result<String> {
        let tls_directory = self.tls_directory();
        if tls_directory.exists() {
            let existing_id = TlsIdentity::load(&tls_directory).map_or_else(
                |error| format!("unreadable: {error}"),
                |identity| identity.server_fingerprint().short_id(),
            );
            bail!(
                "{} already exists (server id {existing_id}); refusing to overwrite. \
                 Every paired device would have to pair again",
                tls_directory.display()
            );
        }
        DirBuilder::new()
            .recursive(true)
            .mode(DATA_DIRECTORY_MODE)
            .create(&self.root_directory)
            .with_context(|| format!("cannot create {}", self.root_directory.display()))?;
        // An existing folder (for example from mktemp) gets the mode too.
        fs::set_permissions(
            &self.root_directory,
            Permissions::from_mode(DATA_DIRECTORY_MODE),
        )
        .with_context(|| format!("cannot set the mode of {}", self.root_directory.display()))?;
        let identity = TlsIdentity::create(&tls_directory)?;
        schema::open_writer_connection(&self.database_path()).with_context(|| {
            format!(
                "cannot create the catalog {}",
                self.database_path().display()
            )
        })?;
        ChunkStore::open(&self.root_directory)?;
        Ok(identity.server_fingerprint().short_id())
    }

    /// Opens the chunk store and starts the single catalog writer for
    /// serving uploads. The writer thread ends when every handle is dropped.
    pub fn open_upload_storage(
        &self,
    ) -> anyhow::Result<(UploadStorage, std::thread::JoinHandle<()>)> {
        let database_path = self.database_path();
        let (catalog_writer, writer_thread) = CatalogWriter::start(&database_path)
            .with_context(|| format!("cannot open the catalog {}", database_path.display()))?;
        let chunk_store = ChunkStore::open(&self.root_directory).with_context(|| {
            format!(
                "cannot open the chunk store in {}",
                self.root_directory.display()
            )
        })?;
        let storage = UploadStorage {
            chunk_store: Arc::new(chunk_store),
            catalog_writer,
            catalog_reader: CatalogReader::new(&database_path),
        };
        Ok((storage, writer_thread))
    }

    /// Before a TLS `run`: migrates the catalog, refuses a folder that holds
    /// the dev device (D-026: dev data must never be served on a network),
    /// and loads the TLS identity made by `init`.
    pub fn prepare_tls_run(&self) -> anyhow::Result<TlsIdentity> {
        let database_path = self.database_path();
        schema::open_writer_connection(&database_path)
            .with_context(|| format!("cannot open the catalog {}", database_path.display()))?;
        if CatalogReader::new(&database_path).has_device_with_cert(&DEV_DEVICE_CERT_SHA256)? {
            bail!(
                "{} was used with --dev-plain (it has the dev device). TLS mode refuses it: \
                 dev uploads must never be served on a network. Use a fresh data folder \
                 (`haotrannas-server init --data-dir <new folder>`)",
                self.root_directory.display()
            );
        }
        let tls_directory = self.tls_directory();
        TlsIdentity::load(&tls_directory).with_context(|| {
            format!(
                "cannot load the TLS identity in {} (made by `haotrannas-server init`)",
                tls_directory.display()
            )
        })
    }

    /// Makes sure device row 1 is the dev device, adding it to an empty
    /// catalog. Refuses a catalog that holds real paired devices: dev mode
    /// must never act as a real phone.
    pub fn ensure_dev_device(&self) -> anyhow::Result<u64> {
        let database_path = self.database_path();
        let mut connection = schema::open_writer_connection(&database_path)?;
        let reader = CatalogReader::new(&database_path);
        if let Some(device) = reader.device_by_cert(&DEV_DEVICE_CERT_SHA256)? {
            if device.device_id == DEV_DEVICE_ID {
                return Ok(DEV_DEVICE_ID);
            }
            bail!(
                "the dev device has id {} instead of {DEV_DEVICE_ID}; use a fresh data folder for --dev-plain",
                device.device_id
            );
        }
        if !reader.list_devices()?.is_empty() {
            bail!(
                "{} has paired devices; --dev-plain needs a data folder of its own",
                self.root_directory.display()
            );
        }
        let device_id = writer::add_device(
            &mut connection,
            DEV_DEVICE_NAME,
            &DEV_DEVICE_CERT_SHA256,
            unix_time_ms(),
        )?;
        if device_id != DEV_DEVICE_ID {
            bail!(
                "the dev device got id {device_id} instead of {DEV_DEVICE_ID} (devices were removed \
                 here before); use a fresh data folder for --dev-plain"
            );
        }
        Ok(device_id)
    }
}

/// Now, in ms since the Unix epoch.
fn unix_time_ms() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0, |since_epoch| {
            i64::try_from(since_epoch.as_millis()).unwrap_or(i64::MAX)
        })
}

#[cfg(test)]
mod tests {
    use std::os::unix::fs::PermissionsExt;

    use super::*;

    #[test]
    fn initialize_makes_the_layout_and_refuses_a_second_time() {
        let parent = tempfile::tempdir().unwrap();
        let folder = DataFolder::new(parent.path().join("data"));
        let short_id = folder.initialize().unwrap();
        assert_eq!(short_id.len(), "3F9A-C21B-77E0".len());
        for name in ["tls/server.crt", "index.sqlite", "chunks", "tmp"] {
            assert!(folder.root_directory().join(name).exists(), "{name}");
        }
        let mode = fs::metadata(folder.root_directory())
            .unwrap()
            .permissions()
            .mode();
        assert_eq!(mode & 0o777, 0o700);
        assert!(folder.is_initialized());

        let message = folder.initialize().unwrap_err().to_string();
        assert!(message.contains(&short_id), "{message}");
    }

    #[test]
    fn dev_device_is_added_once_as_device_one() {
        let parent = tempfile::tempdir().unwrap();
        let folder = DataFolder::new(parent.path().join("data"));
        folder.initialize().unwrap();
        assert_eq!(folder.ensure_dev_device().unwrap(), DEV_DEVICE_ID);
        assert_eq!(folder.ensure_dev_device().unwrap(), DEV_DEVICE_ID);
        let devices = CatalogReader::new(&folder.database_path())
            .list_devices()
            .unwrap();
        assert_eq!(devices.len(), 1);
        assert_eq!(devices[0].name, DEV_DEVICE_NAME);
    }

    #[test]
    fn tls_run_refuses_a_folder_with_the_dev_device() {
        let parent = tempfile::tempdir().unwrap();
        let folder = DataFolder::new(parent.path().join("data"));
        let short_id = folder.initialize().unwrap();
        let identity = folder.prepare_tls_run().unwrap();
        assert_eq!(identity.server_fingerprint().short_id(), short_id);
        folder.ensure_dev_device().unwrap();
        let message = folder.prepare_tls_run().err().unwrap().to_string();
        assert!(message.contains("--dev-plain"), "{message}");
    }

    #[test]
    fn dev_mode_refuses_a_folder_with_real_devices() {
        let parent = tempfile::tempdir().unwrap();
        let folder = DataFolder::new(parent.path().join("data"));
        folder.initialize().unwrap();
        let mut connection = schema::open_writer_connection(&folder.database_path()).unwrap();
        writer::add_device(&mut connection, "phone", &[7; HASH_BYTES], 1).unwrap();
        let message = folder.ensure_dev_device().unwrap_err().to_string();
        assert!(message.contains("paired devices"), "{message}");
    }
}
