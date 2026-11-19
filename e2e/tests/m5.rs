//! Milestone M5 end to end: browse and download over the wire (spec §9,
//! D-019) with the real TLS server and paired cli identities.
//!
//! The cli runs `upload`, `list` and `download`; a raw TLS client with the
//! cli's certificate checks the exact replies (`ListDevices`, `ListDir`
//! paging with 2 entries per page, `ReadChunk` refusals). Needs
//! `cargo build --workspace --bins`.

use std::ffi::OsStr;
use std::fs;
use std::path::{Path, PathBuf};
use std::process::Output;

use haotrannas_core::chunker::{ChunkHash, chunk_reader};
use haotrannas_core::error_code::ErrorCode;
use haotrannas_core::limits::{CHUNK_SIZE_BYTES, PROTOCOL_VERSION};
use haotrannas_core::message::{DirEntry, DirEntryKind, Message};
use haotrannas_core::tls::{ServerPin, TofuRecorder};
use haotrannas_e2e::{
    DevServer, RawClient, chunk_files, cli_pair, cli_paired, expect_success, load_client_identity,
    run_server_command, test_bytes,
};

/// A folder for identities and test files, removed at the end of the test.
fn work_folder() -> tempfile::TempDir {
    tempfile::Builder::new()
        .prefix("htn-e2e-")
        .tempdir()
        .unwrap()
}

/// Pairs the cli into `identity_directory` and returns the device id.
fn pair_cli(server: &DevServer, identity_directory: &Path) -> u64 {
    let pairing = server.pairing_code().unwrap();
    let output = cli_pair(server.address(), identity_directory, &pairing.code, &[]).unwrap();
    let stdout = expect_success(&output).unwrap_or_else(|error| panic!("{error:#}"));
    let suffix = format!(" with server {}", pairing.server_id);
    stdout
        .trim_end()
        .strip_prefix("paired as device ")
        .and_then(|rest| rest.strip_suffix(&suffix))
        .unwrap_or_else(|| panic!("unexpected pair output: {stdout}"))
        .parse()
        .unwrap()
}

/// Runs the cli with the saved pairing (TLS, the saved address).
fn cli(identity_directory: &Path, args: &[&OsStr]) -> Output {
    cli_paired(identity_directory, None, args).unwrap()
}

/// Runs the cli and returns stdout, failing the test on a non-zero exit.
fn cli_ok(identity_directory: &Path, args: &[&OsStr]) -> String {
    expect_success(&cli(identity_directory, args)).unwrap_or_else(|error| panic!("{error:#}"))
}

fn stderr_of(output: &Output) -> String {
    String::from_utf8_lossy(&output.stderr).into_owned()
}

/// `upload <file> --as <remote>`; returns the version id it printed.
fn upload(identity_directory: &Path, file: &Path, remote_path: &str) -> u64 {
    let stdout = cli_ok(
        identity_directory,
        &[
            OsStr::new("upload"),
            file.as_os_str(),
            OsStr::new("--as"),
            OsStr::new(remote_path),
        ],
    );
    stdout
        .trim_end()
        .rsplit(' ')
        .next()
        .and_then(|last_word| last_word.parse().ok())
        .unwrap_or_else(|| panic!("no version id in upload output: {stdout}"))
}

/// `download <remote> --output <file> [extra args]`.
fn download(
    identity_directory: &Path,
    remote_path: &str,
    output: &Path,
    extra_args: &[&str],
) -> Output {
    let mut args = vec![
        OsStr::new("download"),
        OsStr::new(remote_path),
        OsStr::new("--output"),
        output.as_os_str(),
    ];
    args.extend(extra_args.iter().map(OsStr::new));
    cli(identity_directory, &args)
}

/// `list [extra args] [path]` as lines.
fn list_lines(identity_directory: &Path, args: &[&str]) -> Vec<String> {
    let mut all_args = vec![OsStr::new("list")];
    all_args.extend(args.iter().map(OsStr::new));
    cli_ok(identity_directory, &all_args)
        .lines()
        .map(str::to_owned)
        .collect()
}

/// A raw TLS client with the cli's certificate, after `Hello`; checks the
/// device id the server gives.
fn paired_raw_client(server: &DevServer, identity_directory: &Path, device_id: u64) -> RawClient {
    let identity = load_client_identity(identity_directory).unwrap();
    let mut client = RawClient::connect_tls(
        server.address(),
        ServerPin::RecordFirstSeen(TofuRecorder::new()),
        Some(identity),
    )
    .unwrap();
    let hello = Message::Hello {
        protocol_version: PROTOCOL_VERSION,
        client_software: "e2e/1".to_owned(),
        device_name: "raw".to_owned(),
    };
    client.send(&hello, 1).unwrap();
    match client.expect_frame().unwrap() {
        (1, Message::HelloOk { device_id: got, .. }) if got == device_id => {}
        other => panic!("expected HelloOk device {device_id}, got {other:?}"),
    }
    client
}

/// Sends one request and returns its reply (request ids count from 2).
fn ask(client: &mut RawClient, request_id: &mut u32, request: &Message) -> Message {
    *request_id += 1;
    client.send(request, *request_id).unwrap();
    let (reply_id, reply) = client.expect_frame().unwrap();
    assert_eq!(reply_id, *request_id, "reply to {request:?}");
    reply
}

fn assert_error(message: &Message, expected_code: ErrorCode) {
    match message {
        Message::Error { code, .. } if *code == expected_code.code() => {}
        other => panic!("expected Error {}, got {other:?}", expected_code.name()),
    }
}

fn list_dir(device_id: u64, path: &str, start_after: &str, max_entries: u32) -> Message {
    Message::ListDir {
        device_id,
        path: path.to_owned(),
        start_after: start_after.to_owned(),
        max_entries,
    }
}

fn folder_entry(name: &str) -> DirEntry {
    DirEntry {
        name: name.to_owned(),
        kind: DirEntryKind::Directory,
        size_bytes: 0,
        modified_time_ms: 0,
        version_id: 0,
    }
}

/// The test tree: (remote path, size, seed). Names chosen to hit the
/// tricky orders: "2024" folder next to "2024.txt", a 0-byte file, a file
/// of 3 MiB + 17 B (4 chunks), and Vietnamese names (multi-byte UTF-8).
const TREE: [(&str, usize, u64); 7] = [
    ("top.txt", 100, 1),
    ("docs/readme.txt", 2_000, 2),
    ("docs/notes/todo.md", 300, 3),
    (
        "photos/2024/b\u{e3}i bi\u{1ec3}n.jpg",
        3 * 1024 * 1024 + 17,
        4,
    ),
    ("photos/2024.txt", 50, 5),
    ("photos/empty.bin", 0, 6),
    ("photos/\u{1ea3}nh-\u{111}\u{1eb9}p.jpg", 4_000, 7),
];

/// Writes and uploads `TREE`; returns (remote path, local file, version id).
fn upload_tree(identity_directory: &Path, folder: &Path) -> Vec<(String, PathBuf, u64)> {
    TREE.iter()
        .enumerate()
        .map(|(index, (remote_path, size_bytes, seed))| {
            let local_file = folder.join(format!("source-{index}.bin"));
            fs::write(&local_file, test_bytes(*size_bytes, *seed)).unwrap();
            let version_id = upload(identity_directory, &local_file, remote_path);
            ((*remote_path).to_owned(), local_file, version_id)
        })
        .collect()
}

/// Files whose name starts with `.` in `folder` (download temp files).
fn hidden_files(folder: &Path) -> Vec<String> {
    fs::read_dir(folder)
        .unwrap()
        .map(|entry| entry.unwrap().file_name().to_string_lossy().into_owned())
        .filter(|name| name.starts_with('.'))
        .collect()
}

#[test]
fn tree_lists_exactly_as_the_spec_says_and_every_file_downloads_byte_equal() {
    let server = DevServer::start_tls().unwrap();
    let folder = work_folder();
    let identity_directory = folder.path().join("identity");
    let device_id = pair_cli(&server, &identity_directory);
    let uploaded = upload_tree(&identity_directory, folder.path());
    let version_of = |remote_path: &str| {
        uploaded
            .iter()
            .find(|(path, _, _)| path == remote_path)
            .unwrap()
            .2
    };

    // cli list: root and subfolders, sorted byte-wise, folders as `d name/`.
    let root = list_lines(&identity_directory, &[]);
    assert_eq!(root.len(), 3, "{root:?}");
    assert_eq!(root[..2], ["d docs/", "d photos/"]);
    let top_columns: Vec<&str> = root[2].split("  ").collect();
    assert_eq!(top_columns[0], "f top.txt");
    assert_eq!(top_columns[1], "100");
    assert!(top_columns[2].ends_with('Z'), "{root:?}");
    assert_eq!(top_columns[3], format!("v{}", version_of("top.txt")));
    let photos = list_lines(&identity_directory, &["photos"]);
    let photo_names: Vec<&str> = photos
        .iter()
        .map(|line| line.split("  ").next().unwrap())
        .collect();
    assert_eq!(
        photo_names,
        [
            "d 2024/",
            "f 2024.txt",
            "f empty.bin",
            "f \u{1ea3}nh-\u{111}\u{1eb9}p.jpg"
        ]
    );
    let docs = list_lines(&identity_directory, &["docs"]);
    assert_eq!(docs.len(), 2, "{docs:?}");
    assert_eq!(docs[0], "d notes/");
    assert!(docs[1].starts_with("f readme.txt  2000  "), "{docs:?}");
    assert_eq!(
        list_lines(&identity_directory, &["photos/2024"])[0]
            .split("  ")
            .take(2)
            .collect::<Vec<_>>(),
        ["f b\u{e3}i bi\u{1ec3}n.jpg", "3145745"]
    );

    check_raw_browse_replies(
        &server,
        &identity_directory,
        device_id,
        version_of("photos/2024.txt"),
    );

    // Download every file: byte-equal.
    check_tree_downloads(&identity_directory, folder.path(), &uploaded);
}

/// Raw client on the uploaded `TREE`: exact replies, paging with 2 entries
/// per page, and non-fatal errors.
fn check_raw_browse_replies(
    server: &DevServer,
    identity_directory: &Path,
    device_id: u64,
    version_of_2024_txt: u64,
) {
    let mut client = paired_raw_client(server, identity_directory, device_id);
    let mut request_id = 1;
    let devices = ask(&mut client, &mut request_id, &Message::ListDevices);
    let Message::DeviceList { devices } = devices else {
        panic!("expected DeviceList, got {devices:?}");
    };
    assert_eq!(devices.len(), 1);
    assert_eq!(
        (devices[0].device_id, devices[0].is_caller),
        (device_id, true)
    );

    let first_page = ask(&mut client, &mut request_id, &list_dir(0, "photos", "", 2));
    let Message::DirEntries { entries, has_more } = first_page else {
        panic!("expected DirEntries, got {first_page:?}");
    };
    assert!(has_more);
    assert_eq!(entries[0], folder_entry("2024"));
    assert_eq!(
        (
            entries[1].name.as_str(),
            entries[1].kind,
            entries[1].size_bytes,
            entries[1].version_id
        ),
        ("2024.txt", DirEntryKind::File, 50, version_of_2024_txt)
    );
    let second_page = ask(
        &mut client,
        &mut request_id,
        &list_dir(device_id, "photos", "2024.txt", 2),
    );
    let Message::DirEntries { entries, has_more } = second_page else {
        panic!("expected DirEntries, got {second_page:?}");
    };
    assert!(!has_more);
    let names: Vec<&str> = entries.iter().map(|entry| entry.name.as_str()).collect();
    assert_eq!(names, ["empty.bin", "\u{1ea3}nh-\u{111}\u{1eb9}p.jpg"]);
    assert_eq!(entries[0].size_bytes, 0);

    // Errors (not fatal: the connection stays).
    for (request, expected_code) in [
        (list_dir(0, "", "", 0), ErrorCode::BadArgument),
        (list_dir(0, "", "", 1001), ErrorCode::BadArgument),
        (list_dir(999, "", "", 10), ErrorCode::NotFound),
        (list_dir(0, "photos/", "", 10), ErrorCode::BadPath),
        (list_dir(0, "nothing", "", 10), ErrorCode::NotFound),
        (list_dir(0, "top.txt", "", 10), ErrorCode::NotFound),
    ] {
        let reply = ask(&mut client, &mut request_id, &request);
        assert_error(&reply, expected_code);
    }
    assert_eq!(
        ask(&mut client, &mut request_id, &Message::Ping),
        Message::Pong
    );
}

/// Downloads every uploaded file (byte-equal), then the error cases:
/// unknown path, existing output without `--force`.
fn check_tree_downloads(
    identity_directory: &Path,
    folder: &Path,
    uploaded: &[(String, PathBuf, u64)],
) {
    for (index, (remote_path, local_file, version_id)) in uploaded.iter().enumerate() {
        let output = folder.join(format!("downloaded-{index}.bin"));
        let stdout = expect_success(&download(identity_directory, remote_path, &output, &[]))
            .unwrap_or_else(|error| panic!("{error:#}"));
        assert!(
            stdout.starts_with(&format!("downloaded {remote_path} version {version_id} ")),
            "{stdout}"
        );
        assert_eq!(
            fs::read(&output).unwrap(),
            fs::read(local_file).unwrap(),
            "{remote_path}"
        );
    }

    // Unknown path → NOT_FOUND, nothing written.
    let missing_output = folder.join("missing.bin");
    let missing = download(identity_directory, "photos/nope.jpg", &missing_output, &[]);
    assert_eq!(missing.status.code(), Some(1));
    assert!(
        stderr_of(&missing).contains("NOT_FOUND"),
        "{}",
        stderr_of(&missing)
    );
    assert!(!missing_output.exists());

    // An existing output needs --force.
    let existing_output = folder.join("downloaded-0.bin");
    let refused = download(identity_directory, "docs/readme.txt", &existing_output, &[]);
    assert_eq!(refused.status.code(), Some(1));
    assert!(
        stderr_of(&refused).contains("--force"),
        "{}",
        stderr_of(&refused)
    );
    let forced = download(
        identity_directory,
        "docs/readme.txt",
        &existing_output,
        &["--force"],
    );
    expect_success(&forced).unwrap();
    assert_eq!(fs::read(&existing_output).unwrap(), test_bytes(2_000, 2));
    assert!(hidden_files(folder).is_empty());
}

#[test]
fn old_version_downloads_by_its_version_id() {
    let server = DevServer::start_tls().unwrap();
    let folder = work_folder();
    let identity_directory = folder.path().join("identity");
    pair_cli(&server, &identity_directory);
    let local_file = folder.path().join("notes.txt");
    let old_bytes = test_bytes(CHUNK_SIZE_BYTES as usize + 5, 11);
    fs::write(&local_file, &old_bytes).unwrap();
    let old_version_id = upload(&identity_directory, &local_file, "notes.txt");
    let new_bytes = test_bytes(700, 12);
    fs::write(&local_file, &new_bytes).unwrap();
    let new_version_id = upload(&identity_directory, &local_file, "notes.txt");
    assert!(new_version_id > old_version_id);

    let root = list_lines(&identity_directory, &[]);
    assert!(
        root[0].ends_with(&format!("  v{new_version_id}")),
        "{root:?}"
    );
    assert!(root[0].starts_with("f notes.txt  700  "), "{root:?}");

    let latest_output = folder.path().join("latest.txt");
    expect_success(&download(
        &identity_directory,
        "notes.txt",
        &latest_output,
        &[],
    ))
    .unwrap();
    assert_eq!(fs::read(&latest_output).unwrap(), new_bytes);
    let old_output = folder.path().join("old.txt");
    let old_version_text = old_version_id.to_string();
    expect_success(&download(
        &identity_directory,
        "notes.txt",
        &old_output,
        &["--version", &old_version_text],
    ))
    .unwrap();
    assert_eq!(fs::read(&old_output).unwrap(), old_bytes);

    let unknown_version = download(
        &identity_directory,
        "notes.txt",
        &folder.path().join("never.txt"),
        &["--version", "999999"],
    );
    assert_eq!(unknown_version.status.code(), Some(1));
    assert!(stderr_of(&unknown_version).contains("NOT_FOUND"));
}

#[test]
fn new_phone_lists_and_downloads_the_old_phones_files_even_after_revoke() {
    let server = DevServer::start_tls().unwrap();
    let folder = work_folder();
    let old_phone = folder.path().join("old-phone");
    let new_phone = folder.path().join("new-phone");
    let old_device_id = pair_cli(&server, &old_phone);
    let photo = folder.path().join("photo.jpg");
    let photo_bytes = test_bytes(2 * CHUNK_SIZE_BYTES as usize + 3, 21);
    fs::write(&photo, &photo_bytes).unwrap();
    upload(&old_phone, &photo, "camera/photo.jpg");
    let new_device_id = pair_cli(&server, &new_phone);
    assert_ne!(old_device_id, new_device_id);

    // The new phone sees both devices and its own empty root.
    let mut client = paired_raw_client(&server, &new_phone, new_device_id);
    let mut request_id = 1;
    let reply = ask(&mut client, &mut request_id, &Message::ListDevices);
    let Message::DeviceList { devices } = reply else {
        panic!("expected DeviceList, got {reply:?}");
    };
    let summary: Vec<(u64, bool)> = devices
        .iter()
        .map(|device| (device.device_id, device.is_caller))
        .collect();
    assert_eq!(summary, [(old_device_id, false), (new_device_id, true)]);
    assert!(list_lines(&new_phone, &[]).is_empty());

    let old_device_text = old_device_id.to_string();
    let restore_to_new_phone = |output_name: &str| {
        let output = folder.path().join(output_name);
        let result = download(
            &new_phone,
            "camera/photo.jpg",
            &output,
            &["--device", &old_device_text],
        );
        expect_success(&result).unwrap_or_else(|error| panic!("{error:#}"));
        assert_eq!(fs::read(&output).unwrap(), photo_bytes);
    };
    assert_eq!(
        list_lines(&new_phone, &["--device", &old_device_text]),
        ["d camera/"]
    );
    assert!(
        list_lines(&new_phone, &["--device", &old_device_text, "camera"])[0]
            .starts_with("f photo.jpg  ")
    );
    restore_to_new_phone("restored.jpg");

    // The old phone is lost: revoked (D-025), still listed by ListDevices
    // (D-031) so the new phone can find it, its files still restorable.
    let revoke = run_server_command(&[
        OsStr::new("devices"),
        OsStr::new("--data-dir"),
        server.data_directory().as_os_str(),
        OsStr::new("--revoke"),
        OsStr::new(&old_device_text),
    ])
    .unwrap();
    expect_success(&revoke).unwrap();
    let reply = ask(&mut client, &mut request_id, &Message::ListDevices);
    let Message::DeviceList { devices } = reply else {
        panic!("expected DeviceList, got {reply:?}");
    };
    let listed_ids: Vec<u64> = devices.iter().map(|device| device.device_id).collect();
    assert!(listed_ids.contains(&new_device_id), "{listed_ids:?}");
    assert!(listed_ids.contains(&old_device_id), "{listed_ids:?}");
    restore_to_new_phone("restored-after-revoke.jpg");
}

#[test]
fn corrupt_chunk_fails_the_download_with_not_found_and_is_marked_bad() {
    let server = DevServer::start_tls().unwrap();
    let folder = work_folder();
    let identity_directory = folder.path().join("identity");
    pair_cli(&server, &identity_directory);
    let local_file = folder.path().join("video.bin");
    let file_bytes = test_bytes(3 * CHUNK_SIZE_BYTES as usize + 17, 31);
    fs::write(&local_file, &file_bytes).unwrap();
    upload(&identity_directory, &local_file, "video.bin");

    // Flip one byte in the second chunk's file.
    let chunk_list = chunk_reader(file_bytes.as_slice()).unwrap();
    let damaged_hash = chunk_list.chunk_hashes[1];
    let damaged_file = chunk_files(server.data_directory())
        .unwrap()
        .into_iter()
        .find(|path| path.file_name().unwrap().to_string_lossy() == damaged_hash.to_hex())
        .unwrap();
    let mut chunk_bytes = fs::read(&damaged_file).unwrap();
    chunk_bytes[100] ^= 0xFF;
    fs::write(&damaged_file, &chunk_bytes).unwrap();

    let output = folder.path().join("video-out.bin");
    let failed = download(&identity_directory, "video.bin", &output, &[]);
    assert_eq!(failed.status.code(), Some(1));
    let stderr = stderr_of(&failed);
    assert!(
        stderr.contains("NOT_FOUND") && stderr.contains("chunk 1"),
        "{stderr}"
    );
    assert!(!output.exists());
    assert!(
        hidden_files(folder.path()).is_empty(),
        "temp file left behind"
    );
    assert_eq!(chunk_status(server.data_directory(), &damaged_hash), "bad");
    assert_eq!(
        chunk_status(server.data_directory(), &chunk_list.chunk_hashes[0]),
        "ok"
    );

    // The next upload of the file repairs the chunk; download works again.
    upload(&identity_directory, &local_file, "video.bin");
    assert_eq!(chunk_status(server.data_directory(), &damaged_hash), "ok");
    expect_success(&download(&identity_directory, "video.bin", &output, &[])).unwrap();
    assert_eq!(fs::read(&output).unwrap(), file_bytes);
}

#[test]
fn chunk_only_in_an_uncommitted_upload_is_not_found() {
    let server = DevServer::start_tls().unwrap();
    let folder = work_folder();
    let identity_directory = folder.path().join("identity");
    let device_id = pair_cli(&server, &identity_directory);
    let local_file = folder.path().join("half.bin");
    let file_bytes = test_bytes(2 * CHUNK_SIZE_BYTES as usize, 41);
    fs::write(&local_file, &file_bytes).unwrap();
    let stopped = cli_ok(
        &identity_directory,
        &[
            OsStr::new("upload"),
            local_file.as_os_str(),
            OsStr::new("--stop-after-chunks"),
            OsStr::new("1"),
        ],
    );
    assert!(stopped.starts_with("stopped after 1 chunks"), "{stopped}");
    let chunk_list = chunk_reader(file_bytes.as_slice()).unwrap();
    let stored_hash = chunk_list.chunk_hashes[0];
    assert_eq!(chunk_status(server.data_directory(), &stored_hash), "ok");

    let mut client = paired_raw_client(&server, &identity_directory, device_id);
    let mut request_id = 1;
    for hash in [stored_hash, ChunkHash([9; 32])] {
        let reply = ask(
            &mut client,
            &mut request_id,
            &Message::ReadChunk { chunk_sha256: hash },
        );
        assert_error(&reply, ErrorCode::NotFound);
    }
    // And no file shows up in the listing.
    let reply = ask(&mut client, &mut request_id, &list_dir(0, "", "", 10));
    assert_eq!(
        reply,
        Message::DirEntries {
            entries: Vec::new(),
            has_more: false
        }
    );
}

/// `chunks.status` of one chunk, read from the catalog.
fn chunk_status(data_directory: &Path, chunk_hash: &ChunkHash) -> String {
    let connection = rusqlite::Connection::open_with_flags(
        data_directory.join("index.sqlite"),
        rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY,
    )
    .unwrap();
    connection
        .busy_timeout(std::time::Duration::from_secs(5))
        .unwrap();
    connection
        .query_row(
            "SELECT status FROM chunks WHERE hash = ?1",
            [chunk_hash.0],
            |row| row.get(0),
        )
        .unwrap()
}
