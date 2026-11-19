//! Milestone M3 end to end: TLS mode, pairing (spec §7), mutual TLS, pin
//! check, revoke (D-025), TLS refusing dev data (D-026), and the D-029
//! commit race.
//!
//! The real server and cli run as programs; the raw client speaks TLS with
//! the cli's settings for the cases the cli cannot produce (no certificate,
//! a certificate from another server). Needs `cargo build --workspace --bins`.

use std::ffi::OsStr;
use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::time::Duration;

use haotrannas_core::chunker::ChunkHash;
use haotrannas_core::error_code::ErrorCode;
use haotrannas_core::limits::{
    CHUNK_SIZE_BYTES, MAX_PAIR_FAILURES_PER_CONNECTION, MAX_PAIR_FAILURES_PER_WINDOW,
    PROTOCOL_VERSION,
};
use haotrannas_core::message::Message;
use haotrannas_core::tls::{ServerPin, TofuRecorder};
use haotrannas_e2e::{
    DevServer, RawClient, cli_pair, cli_paired, expect_success, load_client_identity,
    restore_file_of_device, server_binary, test_bytes, version_count,
};

/// A folder for identities and test files, removed at the end of the test.
fn work_folder() -> tempfile::TempDir {
    tempfile::Builder::new()
        .prefix("htn-e2e-")
        .tempdir()
        .unwrap()
}

fn hello() -> Message {
    Message::Hello {
        protocol_version: PROTOCOL_VERSION,
        client_software: "e2e/1".to_owned(),
        device_name: "raw".to_owned(),
    }
}

fn assert_error(message: &Message, expected_code: ErrorCode) {
    match message {
        Message::Error { code, .. } if *code == expected_code.code() => {}
        other => panic!("expected Error {}, got {other:?}", expected_code.name()),
    }
}

/// A raw TLS client without a certificate (any server accepted), after a
/// `Hello` that must say device 0.
fn unpaired_client(server: &DevServer) -> RawClient {
    let mut client = RawClient::connect_tls(
        server.address(),
        ServerPin::RecordFirstSeen(TofuRecorder::new()),
        None,
    )
    .unwrap();
    client.send(&hello(), 1).unwrap();
    match client.expect_frame().unwrap() {
        (1, Message::HelloOk { device_id: 0, .. }) => {}
        other => panic!("expected HelloOk device 0, got {other:?}"),
    }
    client
}

/// Pairs the cli into `identity_directory` and returns the device id.
fn pair_cli(server: &DevServer, identity_directory: &Path) -> u64 {
    let pairing = server.pairing_code().unwrap();
    let output = cli_pair(
        server.address(),
        identity_directory,
        &pairing.code,
        &["--expect-server-id", &pairing.server_id],
    )
    .unwrap();
    let stdout = expect_success(&output).unwrap_or_else(|error| panic!("{error:#}"));
    let line = stdout.trim_end();
    let suffix = format!(" with server {}", pairing.server_id);
    let device_id_text = line
        .strip_prefix("paired as device ")
        .and_then(|rest| rest.strip_suffix(&suffix))
        .unwrap_or_else(|| panic!("unexpected pair output: {stdout}"));
    device_id_text.parse().unwrap()
}

/// Runs the cli with the saved pairing (no `--server`: the saved address).
fn cli_with_identity(identity_directory: &Path, args: &[&str]) -> std::process::Output {
    let os_args: Vec<&OsStr> = args.iter().map(OsStr::new).collect();
    cli_paired(identity_directory, None, &os_args).unwrap()
}

fn stderr_of(output: &std::process::Output) -> String {
    String::from_utf8_lossy(&output.stderr).into_owned()
}

fn write_test_file(folder: &Path, name: &str, size_bytes: usize, seed: u64) -> PathBuf {
    let file_path = folder.join(name);
    fs::write(&file_path, test_bytes(size_bytes, seed)).unwrap();
    file_path
}

#[test]
fn unpaired_tls_client_can_ping_but_not_offer_a_file() {
    let server = DevServer::start_tls().unwrap();
    let mut client = unpaired_client(&server);
    client.send(&Message::Ping, 2).unwrap();
    assert_eq!(client.expect_frame().unwrap(), (2, Message::Pong));
    let offer = Message::FileOffer {
        path: "a.txt".to_owned(),
        size_bytes: 0,
        modified_time_ms: 0,
        file_sha256: [0; 32],
        chunk_hashes: Vec::new(),
    };
    client.send(&offer, 3).unwrap();
    let (request_id, reply) = client.expect_frame().unwrap();
    assert_eq!(request_id, 3);
    assert_error(&reply, ErrorCode::NotPaired);
    client.expect_end().unwrap();
}

#[test]
fn paired_cli_pings_uploads_and_restores_over_mutual_tls() {
    let server = DevServer::start_tls().unwrap();
    let folder = work_folder();
    let identity_directory = folder.path().join("identity");
    let device_id = pair_cli(&server, &identity_directory);

    let key_path = identity_directory.join("device.key.pem");
    let key_mode = fs::metadata(&key_path).unwrap().permissions().mode() & 0o777;
    assert_eq!(key_mode, 0o600);

    let ping = cli_with_identity(&identity_directory, &["ping", "--count", "2"]);
    let stdout = expect_success(&ping).unwrap();
    assert!(
        stdout
            .lines()
            .next()
            .unwrap()
            .ends_with(&format!("), device {device_id}")),
        "{stdout}"
    );
    assert_eq!(stdout.matches("Pong in ").count(), 2, "{stdout}");

    let file = write_test_file(
        folder.path(),
        "photo.bin",
        2 * CHUNK_SIZE_BYTES as usize + 5,
        31,
    );
    let upload = cli_with_identity(
        &identity_directory,
        &["upload", file.to_str().unwrap(), "--as", "camera/photo.bin"],
    );
    let stdout = expect_success(&upload).unwrap();
    assert!(stdout.starts_with("uploaded 3 of 3 chunks"), "{stdout}");

    let restored = folder.path().join("restored.bin");
    let restore = restore_file_of_device(
        server.data_directory(),
        device_id,
        "camera/photo.bin",
        &restored,
    )
    .unwrap();
    expect_success(&restore).unwrap();
    assert_eq!(fs::read(&restored).unwrap(), fs::read(&file).unwrap());

    // The device key never reaches the server log.
    let key_text = fs::read_to_string(&key_path).unwrap();
    let key_line = key_text.lines().nth(1).unwrap();
    assert!(
        !server.log().contains(key_line),
        "key found in the server log"
    );
}

#[test]
fn third_wrong_code_closes_the_connection() {
    let server = DevServer::start_tls().unwrap();
    let pairing = server.pairing_code().unwrap();
    let wrong_code = if pairing.code == "000000" {
        "000001"
    } else {
        "000000"
    };
    let mut client = unpaired_client(&server);
    for attempt in 1..=MAX_PAIR_FAILURES_PER_CONNECTION {
        let request_id = attempt + 1;
        client
            .send(
                &Message::PairRequest {
                    code: wrong_code.to_owned(),
                },
                request_id,
            )
            .unwrap();
        let (reply_id, reply) = client.expect_frame().unwrap();
        assert_eq!(reply_id, request_id);
        assert_error(&reply, ErrorCode::BadPairingCode);
    }
    client.expect_end().unwrap();

    // Three failures do not lock the window: the right code still pairs.
    let folder = work_folder();
    let output = cli_pair(
        server.address(),
        &folder.path().join("id"),
        &pairing.code,
        &[],
    )
    .unwrap();
    expect_success(&output).unwrap();
}

#[test]
fn ten_wrong_codes_across_connections_lock_the_window() {
    let server = DevServer::start_tls().unwrap();
    let pairing = server.pairing_code().unwrap();
    let wrong_code = if pairing.code == "000000" {
        "000001"
    } else {
        "000000"
    };
    let mut failures = 0;
    while failures < MAX_PAIR_FAILURES_PER_WINDOW {
        let mut client = unpaired_client(&server);
        let mut request_id = 2;
        loop {
            client
                .send(
                    &Message::PairRequest {
                        code: wrong_code.to_owned(),
                    },
                    request_id,
                )
                .unwrap();
            assert_error(&client.expect_frame().unwrap().1, ErrorCode::BadPairingCode);
            failures += 1;
            request_id += 1;
            if failures == MAX_PAIR_FAILURES_PER_WINDOW {
                break;
            }
            if request_id - 2 == MAX_PAIR_FAILURES_PER_CONNECTION {
                client.expect_end().unwrap();
                break;
            }
        }
    }

    // Locked: even the right code gets TOO_MANY_ATTEMPTS, fatal.
    let mut client = unpaired_client(&server);
    client
        .send(
            &Message::PairRequest {
                code: pairing.code.clone(),
            },
            2,
        )
        .unwrap();
    assert_error(
        &client.expect_frame().unwrap().1,
        ErrorCode::TooManyAttempts,
    );
    client.expect_end().unwrap();

    // A new window from the admin works again.
    let fresh = server.pairing_code().unwrap();
    let folder = work_folder();
    let output = cli_pair(
        server.address(),
        &folder.path().join("id"),
        &fresh.code,
        &[],
    )
    .unwrap();
    expect_success(&output).unwrap();
}

#[test]
fn pairing_code_is_single_use() {
    let server = DevServer::start_tls().unwrap();
    let pairing = server.pairing_code().unwrap();
    assert_eq!(pairing.valid_seconds, 120);
    let folder = work_folder();
    let first = cli_pair(
        server.address(),
        &folder.path().join("a"),
        &pairing.code,
        &[],
    )
    .unwrap();
    expect_success(&first).unwrap();
    let second = cli_pair(
        server.address(),
        &folder.path().join("b"),
        &pairing.code,
        &[],
    )
    .unwrap();
    assert_eq!(second.status.code(), Some(1));
    assert!(
        stderr_of(&second).contains("PAIRING_NOT_OPEN"),
        "{}",
        stderr_of(&second)
    );
    assert!(!folder.path().join("b").join("server.json").exists());
}

#[test]
fn expired_code_is_not_open() {
    let server = DevServer::start_tls_with_args(&["--pairing-code-ttl-ms", "300"]).unwrap();
    let pairing = server.pairing_code().unwrap();
    assert_eq!(pairing.valid_seconds, 1);
    std::thread::sleep(Duration::from_millis(600));
    let folder = work_folder();
    let output = cli_pair(
        server.address(),
        &folder.path().join("id"),
        &pairing.code,
        &[],
    )
    .unwrap();
    assert_eq!(output.status.code(), Some(1));
    assert!(
        stderr_of(&output).contains("PAIRING_NOT_OPEN"),
        "{}",
        stderr_of(&output)
    );
}

#[test]
fn wrong_expected_server_id_saves_nothing() {
    let server = DevServer::start_tls().unwrap();
    let pairing = server.pairing_code().unwrap();
    let folder = work_folder();
    let identity_directory = folder.path().join("id");
    let output = cli_pair(
        server.address(),
        &identity_directory,
        &pairing.code,
        &["--expect-server-id", "0000-0000-0000"],
    )
    .unwrap();
    assert_eq!(output.status.code(), Some(1));
    assert!(
        stderr_of(&output).contains("Nothing saved"),
        "{}",
        stderr_of(&output)
    );
    assert!(!identity_directory.join("server.json").exists());
}

#[test]
fn certificate_from_another_server_is_refused_and_the_pin_is_checked() {
    let server = DevServer::start_tls().unwrap();
    let other_server = DevServer::start_tls().unwrap();
    let folder = work_folder();
    let other_identity_directory = folder.path().join("other");
    pair_cli(&other_server, &other_identity_directory);
    let server_id = server.pairing_code().unwrap().server_id;
    let other_server_id = other_server.pairing_code().unwrap().server_id;

    // A device cert signed by another server's device CA: the TLS 1.3
    // handshake "succeeds" for the client, the refusal shows on the first
    // read (an alert or the end), never a HelloOk.
    let foreign_identity = load_client_identity(&other_identity_directory).unwrap();
    let mut client = RawClient::connect_tls(
        server.address(),
        ServerPin::RecordFirstSeen(TofuRecorder::new()),
        Some(foreign_identity),
    )
    .unwrap();
    let hello_sent = client.send(&hello(), 1);
    if hello_sent.is_ok() {
        match client.receive() {
            Err(_) | Ok(None) => {}
            Ok(Some(frame)) => panic!("expected the connection to fail, got {frame:?}"),
        }
    }

    // The cli pinned the other server: talking to this one is refused.
    let output = cli_paired(
        &other_identity_directory,
        Some(server.address()),
        &[OsStr::new("ping")],
    )
    .unwrap();
    assert_eq!(output.status.code(), Some(1));
    let expected_text =
        format!("server identity changed (expected {other_server_id}, got {server_id})");
    assert!(
        stderr_of(&output).contains(&expected_text),
        "{}",
        stderr_of(&output)
    );
}

#[test]
fn revoked_device_is_refused_but_its_backups_restore() {
    let server = DevServer::start_tls().unwrap();
    let folder = work_folder();
    let identity_directory = folder.path().join("identity");
    let device_id = pair_cli(&server, &identity_directory);
    let file = write_test_file(folder.path(), "notes.txt", 1000, 5);
    let upload = cli_with_identity(
        &identity_directory,
        &["upload", file.to_str().unwrap(), "--as", "notes.txt"],
    );
    expect_success(&upload).unwrap();

    let data_directory = server.data_directory().as_os_str();
    let devices = haotrannas_e2e::run_server_command(&[
        OsStr::new("devices"),
        OsStr::new("--data-dir"),
        data_directory,
    ])
    .unwrap();
    let listing = expect_success(&devices).unwrap();
    assert!(
        listing.starts_with(&format!("{device_id} haotrannas-cli paired ")),
        "{listing}"
    );
    assert!(!listing.contains("revoked"), "{listing}");

    let device_id_text = device_id.to_string();
    let revoke = haotrannas_e2e::run_server_command(&[
        OsStr::new("devices"),
        OsStr::new("--data-dir"),
        data_directory,
        OsStr::new("--revoke"),
        OsStr::new(&device_id_text),
    ])
    .unwrap();
    expect_success(&revoke).unwrap();

    let ping = cli_with_identity(&identity_directory, &["ping"]);
    assert_eq!(ping.status.code(), Some(1));
    assert!(
        stderr_of(&ping).contains("this device is not paired (or was revoked)"),
        "{}",
        stderr_of(&ping)
    );
    let devices = haotrannas_e2e::run_server_command(&[
        OsStr::new("devices"),
        OsStr::new("--data-dir"),
        data_directory,
    ])
    .unwrap();
    assert!(expect_success(&devices).unwrap().contains(" revoked "));

    let restored = folder.path().join("restored.txt");
    let restore =
        restore_file_of_device(server.data_directory(), device_id, "notes.txt", &restored).unwrap();
    expect_success(&restore).unwrap();
    assert_eq!(fs::read(&restored).unwrap(), fs::read(&file).unwrap());
}

#[test]
fn tls_run_refuses_a_data_folder_with_the_dev_device() {
    let mut dev_server = DevServer::start().unwrap();
    dev_server.stop_gracefully(5_000).unwrap();
    let output = std::process::Command::new(server_binary().unwrap())
        .args(["run", "--listen", "127.0.0.1:0", "--data-dir"])
        .arg(dev_server.data_directory())
        .output()
        .unwrap();
    assert_eq!(output.status.code(), Some(1));
    assert!(
        stderr_of(&output).contains("--dev-plain"),
        "{}",
        stderr_of(&output)
    );
}

#[test]
fn admin_pair_needs_tls_mode() {
    let server = DevServer::start().unwrap();
    let error = server.pairing_code().unwrap_err().to_string();
    assert!(error.contains("pairing needs TLS mode"), "{error}");
}

/// D-029: two identical uploads offered before either commits end as one
/// version; both commits get its id.
#[test]
fn identical_uploads_racing_commit_to_one_version() {
    let server = DevServer::start().unwrap();
    let file_bytes = test_bytes(CHUNK_SIZE_BYTES as usize + 9, 77);
    let chunk_hashes: Vec<ChunkHash> = file_bytes
        .chunks(CHUNK_SIZE_BYTES as usize)
        .map(ChunkHash::of_bytes)
        .collect();
    let offer = Message::FileOffer {
        path: "race.bin".to_owned(),
        size_bytes: file_bytes.len() as u64,
        modified_time_ms: 1_700_000_000_000,
        file_sha256: ChunkHash::of_bytes(&file_bytes).0,
        chunk_hashes: chunk_hashes.clone(),
    };
    let mut uploads = Vec::new();
    for _ in 0..2 {
        let mut client = RawClient::connect(server.address()).unwrap();
        client.send(&hello(), 1).unwrap();
        client.expect_frame().unwrap();
        client.send(&offer, 2).unwrap();
        let Message::NeedChunks { upload_id, .. } = client.expect_frame().unwrap().1 else {
            panic!("expected NeedChunks");
        };
        assert_ne!(upload_id, 0);
        uploads.push((client, upload_id));
    }
    // The first client sends every chunk; the second needs none then.
    for (chunk_index, chunk) in file_bytes.chunks(CHUNK_SIZE_BYTES as usize).enumerate() {
        let (client, upload_id) = &mut uploads[0];
        let chunk_index = u32::try_from(chunk_index).unwrap();
        let chunk_data = Message::ChunkData {
            upload_id: *upload_id,
            chunk_index,
            chunk_sha256: chunk_hashes[chunk_index as usize],
            data: chunk.to_vec(),
        };
        client.send(&chunk_data, 10 + chunk_index).unwrap();
        assert!(matches!(
            client.expect_frame().unwrap().1,
            Message::ChunkOk { .. }
        ));
    }
    let mut version_ids = Vec::new();
    for (client, upload_id) in &mut uploads {
        client
            .send(
                &Message::Commit {
                    upload_id: *upload_id,
                },
                20,
            )
            .unwrap();
        let Message::CommitOk { version_id } = client.expect_frame().unwrap().1 else {
            panic!("expected CommitOk");
        };
        version_ids.push(version_id);
    }
    assert_eq!(version_ids[0], version_ids[1]);
    assert_eq!(
        version_count(server.data_directory(), "race.bin").unwrap(),
        1
    );
}
