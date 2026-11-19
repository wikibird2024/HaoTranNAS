//! Browse (spec §9): `ListDevices` → `DeviceList`, `ListDir` → `DirEntries`.
//!
//! ```text
//!  ListDevices  every device, revoked ones included (D-031), by id;
//!               is_caller marks the asker
//!  ListDir      max_entries 1..=1000 (BAD_ARGUMENT) ─► device 0 = caller,
//!               unknown device (NOT_FOUND) ─► path "" = root, else path
//!               rules (BAD_PATH) ─► one page from the catalog; a non-root
//!               folder with no children → NOT_FOUND
//! ```
//!
//! Catalog reads block, so they run in `tokio::task::spawn_blocking`.
//! Errors are not fatal: the session sends `Error` and the connection stays.

use haotrannas_core::error_code::ErrorCode;
use haotrannas_core::limits::MAX_LIST_DIR_ENTRIES;
use haotrannas_core::message::{DeviceEntry, Message};
use haotrannas_core::path_rules::validate_path;

use crate::catalog::CatalogError;
use crate::catalog::reader::CatalogReader;
use crate::handlers::upload::UploadStorage;

/// A non-fatal browse or download error: the code and the text sent in
/// `Error`.
pub type ReadError = (ErrorCode, String);

/// Answers `ListDevices`.
///
/// "Every paired device" (spec §9) includes revoked ones (D-031): a lost
/// phone is revoked (D-025), and the new phone must still find it here to
/// restore its files with `ListDir`/`ReadFile`.
pub async fn handle_list_devices(
    storage: &UploadStorage,
    caller_device_id: u64,
) -> Result<Message, ReadError> {
    let devices = read_catalog(&storage.catalog_reader, "ListDevices", |reader| {
        reader.list_devices()
    })
    .await?;
    let devices = devices
        .into_iter()
        .map(|device| DeviceEntry {
            is_caller: device.device_id == caller_device_id,
            device_id: device.device_id,
            name: device.name,
            paired_at_ms: device.paired_at_ms,
        })
        .collect();
    Ok(Message::DeviceList { devices })
}

/// What `ListDir` asks for.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ListDirRequest {
    /// 0 = the caller.
    pub device_id: u64,
    /// "" = root.
    pub path: String,
    /// Only names after this one; "" = from the start.
    pub start_after: String,
    /// 1 ..= `MAX_LIST_DIR_ENTRIES`.
    pub max_entries: u32,
}

/// Answers `ListDir` with one page of `DirEntries`.
pub async fn handle_list_dir(
    storage: &UploadStorage,
    caller_device_id: u64,
    request: ListDirRequest,
) -> Result<Message, ReadError> {
    if !(1..=MAX_LIST_DIR_ENTRIES).contains(&request.max_entries) {
        return Err((
            ErrorCode::BadArgument,
            format!(
                "max_entries {} is outside 1..={MAX_LIST_DIR_ENTRIES}",
                request.max_entries
            ),
        ));
    }
    let device_id = resolve_device(storage, caller_device_id, request.device_id).await?;
    if !request.path.is_empty()
        && let Err(path_error) = validate_path(&request.path)
    {
        return Err((ErrorCode::BadPath, path_error.to_string()));
    }
    let max_entries = request.max_entries as usize;
    let path = request.path.clone();
    let page = read_catalog(&storage.catalog_reader, "ListDir", move |reader| {
        reader.list_directory(device_id, &path, &request.start_after, max_entries)
    })
    .await?;
    let Some(page) = page else {
        return Err((
            ErrorCode::NotFound,
            format!("no folder {:?} on device {device_id}", request.path),
        ));
    };
    Ok(Message::DirEntries {
        entries: page.entries,
        has_more: page.has_more,
    })
}

/// The device a browse or download request means: 0 = the caller; any other
/// id must be a device row (revoked ones included, D-025), else `NOT_FOUND`.
pub(crate) async fn resolve_device(
    storage: &UploadStorage,
    caller_device_id: u64,
    requested_device_id: u64,
) -> Result<u64, ReadError> {
    if requested_device_id == 0 || requested_device_id == caller_device_id {
        return Ok(caller_device_id);
    }
    let exists = read_catalog(&storage.catalog_reader, "device lookup", move |reader| {
        reader.device_exists(requested_device_id)
    })
    .await?;
    if exists {
        Ok(requested_device_id)
    } else {
        Err((
            ErrorCode::NotFound,
            format!("no device {requested_device_id}"),
        ))
    }
}

/// Runs a blocking catalog read on the blocking pool; a failure becomes
/// `INTERNAL` (and is logged).
pub(crate) async fn read_catalog<Answer, Query>(
    reader: &CatalogReader,
    request_name: &'static str,
    query: Query,
) -> Result<Answer, ReadError>
where
    Answer: Send + 'static,
    Query: FnOnce(&CatalogReader) -> Result<Answer, CatalogError> + Send + 'static,
{
    let reader = reader.clone();
    tokio::task::spawn_blocking(move || query(&reader))
        .await
        .map_err(|join_error| {
            tracing::error!(%join_error, request = request_name, "catalog read task failed");
            (ErrorCode::Internal, "catalog read task failed".to_owned())
        })?
        .map_err(|error| {
            tracing::error!(%error, request = request_name, "catalog error");
            (ErrorCode::Internal, format!("catalog error: {error}"))
        })
}

/// Test helpers shared with the download tests.
#[cfg(test)]
pub(crate) mod test_support {
    use haotrannas_core::chunker::{ChunkList, chunk_reader};
    use haotrannas_core::limits::CHUNK_SIZE_BYTES;

    use crate::handlers::upload::{
        FileOfferRequest, UploadStorage, handle_chunk_data, handle_commit, handle_file_offer,
    };

    /// Uploads `bytes` as `path` through the real upload handlers and
    /// returns the committed version id and the chunk list.
    pub async fn commit_test_file(
        storage: &UploadStorage,
        device_id: u64,
        path: &str,
        bytes: &[u8],
    ) -> (u64, ChunkList) {
        let chunk_list = chunk_reader(bytes).unwrap();
        let offer = FileOfferRequest {
            path: path.to_owned(),
            size_bytes: chunk_list.size_bytes,
            modified_time_ms: 1_700_000_000_000,
            file_sha256: chunk_list.file_sha256,
            chunk_hashes: chunk_list.chunk_hashes.clone(),
        };
        let reply = handle_file_offer(storage, device_id, offer).await.unwrap();
        let haotrannas_core::message::Message::NeedChunks {
            upload_id,
            missing_indexes,
            ..
        } = reply
        else {
            panic!("expected NeedChunks, got {reply:?}");
        };
        for chunk_index in missing_indexes {
            let start = chunk_index as usize * CHUNK_SIZE_BYTES as usize;
            let end = (start + CHUNK_SIZE_BYTES as usize).min(bytes.len());
            handle_chunk_data(
                storage,
                device_id,
                upload_id,
                chunk_index,
                chunk_list.chunk_hashes[chunk_index as usize],
                bytes[start..end].to_vec(),
            )
            .await
            .unwrap();
        }
        let reply = handle_commit(storage, device_id, upload_id).await.unwrap();
        let haotrannas_core::message::Message::CommitOk { version_id } = reply else {
            panic!("expected CommitOk, got {reply:?}");
        };
        (version_id, chunk_list)
    }
}

#[cfg(test)]
mod tests {
    use haotrannas_core::message::DirEntryKind;

    use super::test_support::commit_test_file;
    use super::*;
    use crate::data_folder::DEV_DEVICE_ID;
    use crate::handlers::upload::test_support::open_test_storage;

    fn list_dir(path: &str, start_after: &str, max_entries: u32) -> ListDirRequest {
        ListDirRequest {
            device_id: 0,
            path: path.to_owned(),
            start_after: start_after.to_owned(),
            max_entries,
        }
    }

    fn error_code(result: Result<Message, ReadError>) -> ErrorCode {
        result.expect_err("expected an error").0
    }

    #[tokio::test]
    async fn list_devices_marks_the_caller_and_keeps_revoked_devices() {
        let (_folder, storage) = open_test_storage();
        let tablet_id = storage
            .catalog_writer
            .add_device("tablet".to_owned(), [7; 32], 5)
            .await
            .unwrap();
        let lost_id = storage
            .catalog_writer
            .add_device("lost".to_owned(), [8; 32], 6)
            .await
            .unwrap();
        storage
            .catalog_writer
            .revoke_device(lost_id, 9)
            .await
            .unwrap();

        let reply = handle_list_devices(&storage, tablet_id).await.unwrap();
        let Message::DeviceList { devices } = reply else {
            panic!("expected DeviceList, got {reply:?}");
        };
        let summary: Vec<(u64, &str, bool)> = devices
            .iter()
            .map(|device| (device.device_id, device.name.as_str(), device.is_caller))
            .collect();
        assert_eq!(
            summary,
            vec![
                (DEV_DEVICE_ID, crate::data_folder::DEV_DEVICE_NAME, false),
                (tablet_id, "tablet", true),
                (lost_id, "lost", false),
            ]
        );
        assert_eq!(devices[1].paired_at_ms, 5);
    }

    #[tokio::test]
    async fn list_dir_checks_arguments_in_spec_order() {
        let (_folder, storage) = open_test_storage();
        commit_test_file(&storage, DEV_DEVICE_ID, "photos/a.jpg", b"abc").await;

        for bad_count in [0, MAX_LIST_DIR_ENTRIES + 1] {
            let result =
                handle_list_dir(&storage, DEV_DEVICE_ID, list_dir("", "", bad_count)).await;
            assert_eq!(error_code(result), ErrorCode::BadArgument);
        }
        let unknown_device = ListDirRequest {
            device_id: 999,
            ..list_dir("bad//path", "", 10)
        };
        assert_eq!(
            error_code(handle_list_dir(&storage, DEV_DEVICE_ID, unknown_device).await),
            ErrorCode::NotFound
        );
        for bad_path in ["/photos", "photos/", "a//b", "..", "a\\b"] {
            let result = handle_list_dir(&storage, DEV_DEVICE_ID, list_dir(bad_path, "", 10)).await;
            assert_eq!(error_code(result), ErrorCode::BadPath, "{bad_path:?}");
        }
        assert_eq!(
            error_code(handle_list_dir(&storage, DEV_DEVICE_ID, list_dir("nothing", "", 10)).await),
            ErrorCode::NotFound
        );

        let root = handle_list_dir(&storage, DEV_DEVICE_ID, list_dir("", "", 1))
            .await
            .unwrap();
        let Message::DirEntries { entries, has_more } = root else {
            panic!("expected DirEntries, got {root:?}");
        };
        assert!(!has_more);
        assert_eq!(entries.len(), 1);
        assert_eq!(
            (entries[0].name.as_str(), entries[0].kind),
            ("photos", DirEntryKind::Directory)
        );
        let photos = handle_list_dir(&storage, DEV_DEVICE_ID, list_dir("photos", "", 1000))
            .await
            .unwrap();
        let Message::DirEntries { entries, .. } = photos else {
            panic!("expected DirEntries, got {photos:?}");
        };
        assert_eq!(
            (
                entries[0].name.as_str(),
                entries[0].kind,
                entries[0].size_bytes
            ),
            ("a.jpg", DirEntryKind::File, 3)
        );
    }

    #[tokio::test]
    async fn list_dir_reads_another_device_and_a_revoked_one() {
        let (_folder, storage) = open_test_storage();
        commit_test_file(&storage, DEV_DEVICE_ID, "old.txt", b"old phone").await;
        let new_phone_id = storage
            .catalog_writer
            .add_device("new".to_owned(), [9; 32], 0)
            .await
            .unwrap();
        storage
            .catalog_writer
            .revoke_device(DEV_DEVICE_ID, 1)
            .await
            .unwrap();
        let request = ListDirRequest {
            device_id: DEV_DEVICE_ID,
            ..list_dir("", "", 10)
        };
        let reply = handle_list_dir(&storage, new_phone_id, request)
            .await
            .unwrap();
        let Message::DirEntries { entries, .. } = reply else {
            panic!("expected DirEntries, got {reply:?}");
        };
        assert_eq!(entries[0].name, "old.txt");
        // The caller's own (empty) root.
        let own = handle_list_dir(&storage, new_phone_id, list_dir("", "", 10))
            .await
            .unwrap();
        assert_eq!(
            own,
            Message::DirEntries {
                entries: Vec::new(),
                has_more: false
            }
        );
    }
}
