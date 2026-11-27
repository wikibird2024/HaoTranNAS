//! Thumbnails (protocol spec §16, D-048): one small JPEG per (device,
//! file SHA-256), made by the phone. Not backup data: losing one loses no
//! file. Still written like a chunk, so a crash never leaves half a picture.
//!
//! ```text
//!  <data_dir>/thumbnails/<device_id>/<file sha256 hex>.jpg
//!  put:  tmp/<random>.tmp ─► fsync ─► device folder ─► rename ─► fsync folder
//! ```
//!
//! Author: Hao Tran

use std::fs;
use std::io;
use std::path::{Path, PathBuf};

use haotrannas_core::limits::{HASH_BYTES, MAX_THUMBNAIL_BYTES};

use crate::chunk_store::{create_private_directory, sync_directory, write_and_sync_new_file};

/// Folder under the data folder.
const THUMBNAILS_DIRECTORY_NAME: &str = "thumbnails";
/// Shared with the chunk store, so its hourly sweep also removes our
/// leftover temp files.
const TMP_DIRECTORY_NAME: &str = "tmp";
/// Every JPEG starts with these bytes (SOI marker + the next marker's 0xFF).
pub const JPEG_START_BYTES: [u8; 3] = [0xFF, 0xD8, 0xFF];

/// Why `PutThumbnail` bytes are refused (spec §16: `BAD_ARGUMENT`).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ThumbnailRefusal {
    /// 0 bytes.
    Empty,
    /// Over [`MAX_THUMBNAIL_BYTES`].
    TooLarge,
    /// Does not start like a JPEG.
    NotJpeg,
}

/// Checks the bytes only; the server never decodes an image.
pub fn check_thumbnail_bytes(jpeg_data: &[u8]) -> Result<(), ThumbnailRefusal> {
    if jpeg_data.is_empty() {
        return Err(ThumbnailRefusal::Empty);
    }
    if jpeg_data.len() > MAX_THUMBNAIL_BYTES {
        return Err(ThumbnailRefusal::TooLarge);
    }
    if !jpeg_data.starts_with(&JPEG_START_BYTES) {
        return Err(ThumbnailRefusal::NotJpeg);
    }
    Ok(())
}

/// The thumbnail folder tree under the data folder.
#[derive(Debug)]
pub struct ThumbnailStore {
    /// The data folder (holds `thumbnails/` and `tmp/`).
    root_directory: PathBuf,
}

impl ThumbnailStore {
    /// Opens the store, creating `thumbnails/` and `tmp/` (mode 0700) when
    /// missing.
    pub fn open(root_directory: impl Into<PathBuf>) -> io::Result<Self> {
        let root_directory = root_directory.into();
        for name in [THUMBNAILS_DIRECTORY_NAME, TMP_DIRECTORY_NAME] {
            create_directory_if_missing(&root_directory, &root_directory.join(name))?;
        }
        Ok(Self { root_directory })
    }

    /// Where the thumbnail of (device, file) lives.
    pub fn path_for(&self, device_id: u64, file_sha256: &[u8; HASH_BYTES]) -> PathBuf {
        self.device_directory(device_id)
            .join(format!("{}.jpg", hex::encode(file_sha256)))
    }

    /// Stores `jpeg_data`, replacing an older thumbnail of the same file.
    /// The caller has checked the bytes ([`check_thumbnail_bytes`]).
    pub fn put(
        &self,
        device_id: u64,
        file_sha256: &[u8; HASH_BYTES],
        jpeg_data: &[u8],
    ) -> io::Result<()> {
        let device_directory = self.device_directory(device_id);
        create_directory_if_missing(
            &self.root_directory.join(THUMBNAILS_DIRECTORY_NAME),
            &device_directory,
        )?;
        let tmp_path = self.root_directory.join(TMP_DIRECTORY_NAME).join(format!(
            "thumbnail-{:032x}.tmp",
            rand::random::<u128>()
        ));
        let outcome = write_and_sync_new_file(&tmp_path, jpeg_data)
            .and_then(|()| fs::rename(&tmp_path, self.path_for(device_id, file_sha256)))
            .and_then(|()| sync_directory(&device_directory));
        if outcome.is_err() {
            // Best effort: the hourly temp sweep removes it otherwise.
            let _ = fs::remove_file(&tmp_path);
        }
        outcome
    }

    /// The stored thumbnail, or `None` when there is none.
    pub fn read(
        &self,
        device_id: u64,
        file_sha256: &[u8; HASH_BYTES],
    ) -> io::Result<Option<Vec<u8>>> {
        match fs::read(self.path_for(device_id, file_sha256)) {
            Ok(jpeg_data) => Ok(Some(jpeg_data)),
            Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(None),
            Err(error) => Err(error),
        }
    }

    fn device_directory(&self, device_id: u64) -> PathBuf {
        self.root_directory
            .join(THUMBNAILS_DIRECTORY_NAME)
            .join(device_id.to_string())
    }
}

/// Creates `directory` (mode 0700) and fsyncs `parent` so the new entry
/// survives a power cut. An existing folder is fine.
fn create_directory_if_missing(parent: &Path, directory: &Path) -> io::Result<()> {
    match create_private_directory(directory) {
        Ok(()) => sync_directory(parent),
        Err(error) if error.kind() == io::ErrorKind::AlreadyExists => Ok(()),
        Err(error) => Err(error),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const FILE_SHA256: [u8; HASH_BYTES] = [0xAB; HASH_BYTES];

    fn tiny_jpeg() -> Vec<u8> {
        [&JPEG_START_BYTES[..], b"\xE0thumb\xFF\xD9"].concat()
    }

    #[test]
    fn put_then_read_gives_the_same_bytes() {
        let folder = tempfile::tempdir().unwrap();
        let store = ThumbnailStore::open(folder.path()).unwrap();
        assert_eq!(store.read(7, &FILE_SHA256).unwrap(), None);
        store.put(7, &FILE_SHA256, &tiny_jpeg()).unwrap();
        assert_eq!(store.read(7, &FILE_SHA256).unwrap(), Some(tiny_jpeg()));
        // Another device's thumbnail of the same file is separate.
        assert_eq!(store.read(8, &FILE_SHA256).unwrap(), None);
        assert!(
            store
                .path_for(7, &FILE_SHA256)
                .ends_with(format!("thumbnails/7/{}.jpg", "ab".repeat(32)))
        );
    }

    #[test]
    fn a_newer_thumbnail_replaces_the_older_and_no_temp_file_is_left() {
        let folder = tempfile::tempdir().unwrap();
        let store = ThumbnailStore::open(folder.path()).unwrap();
        store.put(7, &FILE_SHA256, &tiny_jpeg()).unwrap();
        let newer = [&JPEG_START_BYTES[..], b"\xE1newer"].concat();
        store.put(7, &FILE_SHA256, &newer).unwrap();
        assert_eq!(store.read(7, &FILE_SHA256).unwrap(), Some(newer));
        let tmp_entries = fs::read_dir(folder.path().join("tmp")).unwrap().count();
        assert_eq!(tmp_entries, 0);
    }

    #[test]
    fn only_small_jpeg_bytes_pass_the_check() {
        assert_eq!(check_thumbnail_bytes(&tiny_jpeg()), Ok(()));
        assert_eq!(check_thumbnail_bytes(&[]), Err(ThumbnailRefusal::Empty));
        assert_eq!(
            check_thumbnail_bytes(b"\x89PNG\r\n"),
            Err(ThumbnailRefusal::NotJpeg)
        );
        let mut largest = vec![0; MAX_THUMBNAIL_BYTES];
        largest[..3].copy_from_slice(&JPEG_START_BYTES);
        assert_eq!(check_thumbnail_bytes(&largest), Ok(()));
        largest.push(0);
        assert_eq!(
            check_thumbnail_bytes(&largest),
            Err(ThumbnailRefusal::TooLarge)
        );
    }
}
