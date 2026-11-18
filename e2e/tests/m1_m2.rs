//! Milestones M1 and M2 end to end: upload, offline restore, resume after a
//! dropped connection, dedupe, a lost `CommitOk`, a server killed with
//! SIGKILL mid-upload, bit-rot repair, and the upload error codes.
//!
//! The real server (`run --dev-plain`) and the real cli run as programs.
//! Needs `cargo build --workspace --bins` first.

use std::fs;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

use haotrannas_core::chunker::{ChunkHash, chunk_reader};
use haotrannas_core::error_code::ErrorCode;
use haotrannas_core::limits::{CHUNK_SIZE_BYTES, PROTOCOL_VERSION};
use haotrannas_core::message::Message;
use haotrannas_e2e::{
    DevServer, RawClient, check_every_chunk_file, chunk_files, cli_binary, cli_upload,
    expect_success, mark_chunk_bad, restore_file, test_bytes, version_count, wait_until,
};

const MIB: usize = CHUNK_SIZE_BYTES as usize;

/// A folder for test files (source files, restored copies), removed at the
/// end of the test.
fn work_folder() -> tempfile::TempDir {
    tempfile::Builder::new()
        .prefix("htn-e2e-")
        .tempdir()
        .unwrap()
}

/// Writes `size_bytes` pseudo-random bytes to `<folder>/<name>`.
fn write_test_file(folder: &Path, name: &str, size_bytes: usize, seed: u64) -> PathBuf {
    let file_path = folder.join(name);
    fs::write(&file_path, test_bytes(size_bytes, seed)).unwrap();
    file_path
}

/// Uploads with the cli and returns its one summary line.
fn upload(server: &DevServer, file: &Path, extra_args: &[&str]) -> String {
    let output = cli_upload(server.address(), file, extra_args).unwrap();
    let stdout = expect_success(&output).unwrap_or_else(|error| panic!("{error:#}"));
    let lines: Vec<&str> = stdout.lines().collect();
    assert_eq!(lines.len(), 1, "exactly one summary line: {stdout}");
    lines[0].to_owned()
}

/// Restores `remote_path` into `folder` and checks it is byte-equal to
/// `original`.
fn restore_and_compare(data_directory: &Path, remote_path: &str, original: &Path, folder: &Path) {
    let restored = folder.join(format!("restored-{}", remote_path.replace('/', "_")));
    let output = restore_file(data_directory, remote_path, &restored).unwrap();
    let stdout = expect_success(&output).unwrap_or_else(|error| panic!("{error:#}"));
    let original_bytes = fs::read(original).unwrap();
    let expected_hash = ChunkHash::of_bytes(&original_bytes).to_hex();
    assert_eq!(
        stdout.trim_end(),
        format!(
            "restored {remote_path} version {} ({} bytes, sha256 {expected_hash})",
            stdout.split(' ').nth(3).unwrap(),
            original_bytes.len()
        )
    );
    assert!(
        fs::read(&restored).unwrap() == original_bytes,
        "restored bytes differ"
    );
    fs::remove_file(restored).unwrap();
}

fn assert_error(message: &Message, expected_code: ErrorCode) {
    match message {
        Message::Error { code, .. } if *code == expected_code.code() => {}
        other => panic!("expected Error {}, got {other:?}", expected_code.name()),
    }
}

/// A raw client after `Hello`.
fn raw_client(server: &DevServer) -> RawClient {
    let mut client = RawClient::connect(server.address()).unwrap();
    let hello = Message::Hello {
        protocol_version: PROTOCOL_VERSION,
        client_software: "e2e/1".to_owned(),
        device_name: "e2e".to_owned(),
    };
    client.send(&hello, 1).unwrap();
    assert!(matches!(
        client.expect_frame().unwrap(),
        (1, Message::HelloOk { device_id: 1, .. })
    ));
    client
}

fn file_offer(path: &str, file_bytes: &[u8]) -> Message {
    let chunk_list = chunk_reader(file_bytes).unwrap();
    Message::FileOffer {
        path: path.to_owned(),
        size_bytes: chunk_list.size_bytes,
        modified_time_ms: 1_700_000_000_000,
        file_sha256: chunk_list.file_sha256,
        chunk_hashes: chunk_list.chunk_hashes,
    }
}

fn chunk_data(upload_id: u64, file_bytes: &[u8], chunk_index: u32) -> Message {
    let start = chunk_index as usize * MIB;
    let data = file_bytes[start..(start + MIB).min(file_bytes.len())].to_vec();
    Message::ChunkData {
        upload_id,
        chunk_index,
        chunk_sha256: ChunkHash::of_bytes(&data),
        data,
    }
}

/// Sends a `FileOffer` and returns (upload id, missing indexes).
fn offer_new_upload(client: &mut RawClient, request_id: u32, offer: &Message) -> (u64, Vec<u32>) {
    client.send(offer, request_id).unwrap();
    match client.expect_frame().unwrap() {
        (
            id,
            Message::NeedChunks {
                upload_id,
                existing_version_id: 0,
                missing_indexes,
            },
        ) if id == request_id => (upload_id, missing_indexes),
        other => panic!("expected NeedChunks for a new upload, got {other:?}"),
    }
}

#[test]
fn upload_then_restore_is_byte_equal() {
    let server = DevServer::start().unwrap();
    let folder = work_folder();
    for (size_bytes, seed) in [(0, 1), (1, 2), (MIB, 3), (3 * MIB + 17, 4)] {
        let name = format!("file-{size_bytes}.bin");
        let file = write_test_file(folder.path(), &name, size_bytes, seed);
        let total_chunks = size_bytes.div_ceil(MIB);
        let remote_path = format!("sizes/{name}");
        let summary = upload(&server, &file, &["--as", &remote_path]);
        assert!(
            summary.starts_with(&format!(
                "uploaded {total_chunks} of {total_chunks} chunks ({size_bytes} bytes), version "
            )),
            "{summary}"
        );
        restore_and_compare(server.data_directory(), &remote_path, &file, folder.path());
    }
    // The default backup path is the file name.
    let file = write_test_file(folder.path(), "plain.txt", 10, 5);
    upload(&server, &file, &[]);
    restore_and_compare(server.data_directory(), "plain.txt", &file, folder.path());
}

#[test]
fn stopped_upload_resumes_with_only_the_missing_chunks() {
    let server = DevServer::start().unwrap();
    let folder = work_folder();
    let file = write_test_file(folder.path(), "five.bin", 4 * MIB + 100, 10);

    assert_eq!(
        upload(&server, &file, &["--stop-after-chunks", "2"]),
        "stopped after 2 chunks (no commit)"
    );
    assert_eq!(
        version_count(server.data_directory(), "five.bin").unwrap(),
        0
    );
    assert_eq!(
        upload(&server, &file, &[]),
        format!(
            "uploaded 3 of 5 chunks ({} bytes), version 1",
            2 * MIB + 100
        )
    );
    // No duplicate chunks: exactly one file per distinct chunk.
    assert_eq!(check_every_chunk_file(server.data_directory()).unwrap(), 5);
    restore_and_compare(server.data_directory(), "five.bin", &file, folder.path());
}

#[test]
fn same_content_under_another_path_sends_no_chunks() {
    let server = DevServer::start().unwrap();
    let folder = work_folder();
    let file = write_test_file(folder.path(), "photo.jpg", 2 * MIB + 5, 20);
    upload(&server, &file, &["--as", "camera/photo.jpg"]);
    let chunk_count_before = chunk_files(server.data_directory()).unwrap().len();
    assert_eq!(chunk_count_before, 3);

    let summary = upload(&server, &file, &["--as", "copies/photo-copy.jpg"]);
    assert_eq!(summary, "uploaded 0 of 3 chunks (0 bytes), version 2");
    assert_eq!(
        chunk_files(server.data_directory()).unwrap().len(),
        chunk_count_before
    );
    restore_and_compare(
        server.data_directory(),
        "copies/photo-copy.jpg",
        &file,
        folder.path(),
    );
}

#[test]
fn lost_commit_ok_is_answered_with_the_existing_version() {
    let server = DevServer::start().unwrap();
    let folder = work_folder();
    let file = write_test_file(folder.path(), "doc.pdf", MIB + 1, 30);

    let summary = upload(&server, &file, &["--drop-after-commit"]);
    assert_eq!(
        summary,
        format!(
            "uploaded 2 of 2 chunks ({} bytes), commit sent, reply not read",
            MIB + 1
        )
    );
    // The server finishes the Commit it received after the client left.
    wait_until(5_000, || {
        Ok(version_count(server.data_directory(), "doc.pdf")? == 1)
    })
    .unwrap();

    assert_eq!(upload(&server, &file, &[]), "already backed up: version 1");
    assert_eq!(
        version_count(server.data_directory(), "doc.pdf").unwrap(),
        1
    );
    restore_and_compare(server.data_directory(), "doc.pdf", &file, folder.path());
}

#[test]
fn server_killed_mid_upload_loses_nothing_and_the_upload_resumes() {
    let folder = work_folder();
    let data_directory = folder.path().join("data");
    let mut server = DevServer::start_on(&data_directory).unwrap();
    let file = write_test_file(folder.path(), "video.mp4", 5 * MIB + 333, 40);
    let file_bytes = fs::read(&file).unwrap();

    // Two chunks stored, the third half sent, then SIGKILL.
    let mut client = raw_client(&server);
    let offer = file_offer("video.mp4", &file_bytes);
    let (upload_id, missing_indexes) = offer_new_upload(&mut client, 2, &offer);
    assert_eq!(missing_indexes, vec![0, 1, 2, 3, 4, 5]);
    for (request_id, chunk_index) in [(3, 0), (4, 1)] {
        client
            .send(&chunk_data(upload_id, &file_bytes, chunk_index), request_id)
            .unwrap();
        assert!(matches!(
            client.expect_frame().unwrap(),
            (id, Message::ChunkOk { chunk_index: index, .. }) if id == request_id && index == chunk_index
        ));
    }
    let third_chunk =
        haotrannas_core::codec::encode_frame(&chunk_data(upload_id, &file_bytes, 2), 5).unwrap();
    client
        .send_bytes(&third_chunk[..third_chunk.len() / 2])
        .unwrap();
    server.kill_hard().unwrap();
    drop(client);

    // No corrupt chunk is ever in place: every chunk file hashes to its name.
    assert_eq!(check_every_chunk_file(&data_directory).unwrap(), 2);

    // Restart on the same data; the cli sends only what is missing.
    let server = DevServer::start_on(&data_directory).unwrap();
    let summary = upload(&server, &file, &[]);
    assert_eq!(
        summary,
        format!(
            "uploaded 4 of 6 chunks ({} bytes), version 1",
            3 * MIB + 333
        )
    );
    assert_eq!(check_every_chunk_file(&data_directory).unwrap(), 6);
    restore_and_compare(&data_directory, "video.mp4", &file, folder.path());
}

#[test]
fn server_killed_during_a_cli_upload_then_upload_again_completes() {
    let folder = work_folder();
    let data_directory = folder.path().join("data");
    let mut server = DevServer::start_on(&data_directory).unwrap();
    let file = write_test_file(folder.path(), "big.bin", 12 * MIB + 9, 50);

    let mut cli = Command::new(cli_binary().unwrap())
        .arg("--server")
        .arg(server.address().to_string())
        .arg("upload")
        .arg(&file)
        .arg("--dev-plain")
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .unwrap();
    // Kill as soon as a couple of chunks are on disk.
    wait_until(20_000, || Ok(chunk_files(&data_directory)?.len() >= 2)).unwrap();
    server.kill_hard().unwrap();
    let cli_status = cli.wait().unwrap();
    check_every_chunk_file(&data_directory).unwrap();

    // Killed after 2 of 13 chunks: the first upload never committed.
    assert!(!cli_status.success(), "the cli should have lost its server");
    assert_eq!(version_count(&data_directory, "big.bin").unwrap(), 0);

    let server = DevServer::start_on(&data_directory).unwrap();
    let summary = upload(&server, &file, &[]);
    assert!(summary.starts_with("uploaded "), "{summary}");
    assert!(summary.contains(" of 13 chunks "), "{summary}");
    assert!(!summary.starts_with("uploaded 13 of"), "resumed: {summary}");
    assert_eq!(check_every_chunk_file(&data_directory).unwrap(), 13);
    restore_and_compare(&data_directory, "big.bin", &file, folder.path());
}

#[test]
fn corrupted_chunk_is_healed_by_the_next_upload() {
    let server = DevServer::start().unwrap();
    let folder = work_folder();
    let file = write_test_file(folder.path(), "old.jpg", MIB + 4000, 60);
    let file_bytes = fs::read(&file).unwrap();
    upload(&server, &file, &[]);

    // Bit rot in chunk 0, found by scrub (simulated: flip a byte, mark bad).
    let first_hash = ChunkHash::of_bytes(&file_bytes[..MIB]);
    let chunk_path = chunk_files(server.data_directory())
        .unwrap()
        .into_iter()
        .find(|path| path.file_name().unwrap().to_str() == Some(&first_hash.to_hex()))
        .unwrap();
    let mut on_disk = fs::read(&chunk_path).unwrap();
    on_disk[12345] ^= 0x04;
    fs::write(&chunk_path, &on_disk).unwrap();
    mark_chunk_bad(server.data_directory(), &first_hash).unwrap();
    assert!(check_every_chunk_file(server.data_directory()).is_err());

    // Restore refuses the damaged file and leaves nothing behind.
    let restored = folder.path().join("restored-old.jpg");
    let output = restore_file(server.data_directory(), "old.jpg", &restored).unwrap();
    assert_eq!(output.status.code(), Some(1));
    assert!(String::from_utf8_lossy(&output.stderr).contains("damaged"));
    assert!(!restored.exists());

    // Same file offered again: the bad chunk is listed missing and replaced.
    assert_eq!(
        upload(&server, &file, &[]),
        format!("uploaded 1 of 2 chunks ({MIB} bytes), version 2")
    );
    assert_eq!(check_every_chunk_file(server.data_directory()).unwrap(), 2);
    restore_and_compare(server.data_directory(), "old.jpg", &file, folder.path());
}

#[test]
fn wrong_file_hash_gets_file_hash_mismatch_and_the_upload_is_dropped() {
    let server = DevServer::start().unwrap();
    let mut client = raw_client(&server);
    let file_bytes = test_bytes(5000, 70);
    let mut offer = file_offer("lie.bin", &file_bytes);
    if let Message::FileOffer { file_sha256, .. } = &mut offer {
        *file_sha256 = [0xAB; 32];
    }
    let (upload_id, missing_indexes) = offer_new_upload(&mut client, 2, &offer);
    assert_eq!(missing_indexes, vec![0]);
    client
        .send(&chunk_data(upload_id, &file_bytes, 0), 3)
        .unwrap();
    assert!(matches!(
        client.expect_frame().unwrap(),
        (3, Message::ChunkOk { .. })
    ));
    client.send(&Message::Commit { upload_id }, 4).unwrap();
    let (request_id, reply) = client.expect_frame().unwrap();
    assert_eq!(request_id, 4);
    assert_error(&reply, ErrorCode::FileHashMismatch);
    // Dropped: a second Commit does not know it; the connection stays.
    client.send(&Message::Commit { upload_id }, 5).unwrap();
    assert_error(&client.expect_frame().unwrap().1, ErrorCode::UnknownUpload);
    client.send(&Message::Ping, 6).unwrap();
    assert_eq!(client.expect_frame().unwrap(), (6, Message::Pong));
    assert_eq!(
        version_count(server.data_directory(), "lie.bin").unwrap(),
        0
    );
}

#[test]
fn upload_errors_have_their_codes_and_the_connection_stays() {
    let server = DevServer::start().unwrap();
    let mut client = raw_client(&server);
    let file_bytes = test_bytes(MIB + 10, 80);

    // FileOffer checks.
    client
        .send(&file_offer("../escape.bin", &file_bytes), 2)
        .unwrap();
    let (request_id, reply) = client.expect_frame().unwrap();
    assert_eq!(request_id, 2);
    assert_error(&reply, ErrorCode::BadPath);
    let mut wrong_count = file_offer("a.bin", &file_bytes);
    if let Message::FileOffer { size_bytes, .. } = &mut wrong_count {
        *size_bytes = 10;
    }
    client.send(&wrong_count, 3).unwrap();
    assert_error(&client.expect_frame().unwrap().1, ErrorCode::BadArgument);
    let mut too_many = file_offer("huge.bin", &file_bytes);
    if let Message::FileOffer {
        size_bytes,
        chunk_hashes,
        ..
    } = &mut too_many
    {
        *size_bytes = 65_537 * u64::from(CHUNK_SIZE_BYTES);
        *chunk_hashes = vec![ChunkHash([1; 32]); 65_537];
    }
    client.send(&too_many, 4).unwrap();
    assert_error(&client.expect_frame().unwrap().1, ErrorCode::TooLarge);

    // ChunkData checks.
    let (upload_id, _) = offer_new_upload(&mut client, 5, &file_offer("a.bin", &file_bytes));
    client
        .send(&chunk_data(upload_id + 1, &file_bytes, 1), 6)
        .unwrap();
    assert_error(&client.expect_frame().unwrap().1, ErrorCode::UnknownUpload);
    let Message::ChunkData {
        chunk_sha256, data, ..
    } = chunk_data(upload_id, &file_bytes, 1)
    else {
        unreachable!()
    };
    let out_of_range = Message::ChunkData {
        upload_id,
        chunk_index: 2,
        chunk_sha256,
        data: data.clone(),
    };
    client.send(&out_of_range, 7).unwrap();
    assert_error(&client.expect_frame().unwrap().1, ErrorCode::BadArgument);
    let wrong_index = Message::ChunkData {
        upload_id,
        chunk_index: 0,
        chunk_sha256,
        data: data.clone(),
    };
    client.send(&wrong_index, 8).unwrap();
    assert_error(
        &client.expect_frame().unwrap().1,
        ErrorCode::ChunkHashMismatch,
    );
    let mut short_data = data.clone();
    short_data.pop();
    let wrong_size = Message::ChunkData {
        upload_id,
        chunk_index: 1,
        chunk_sha256,
        data: short_data,
    };
    client.send(&wrong_size, 9).unwrap();
    assert_error(&client.expect_frame().unwrap().1, ErrorCode::ChunkSizeWrong);
    let mut flipped_data = data;
    flipped_data[0] ^= 1;
    let wrong_bytes = Message::ChunkData {
        upload_id,
        chunk_index: 1,
        chunk_sha256,
        data: flipped_data,
    };
    client.send(&wrong_bytes, 10).unwrap();
    assert_error(
        &client.expect_frame().unwrap().1,
        ErrorCode::ChunkHashMismatch,
    );
    // Commit before the chunks arrived.
    client.send(&Message::Commit { upload_id }, 11).unwrap();
    assert_error(&client.expect_frame().unwrap().1, ErrorCode::ChunksMissing);

    client.send(&Message::Ping, 12).unwrap();
    assert_eq!(client.expect_frame().unwrap(), (12, Message::Pong));
    assert!(chunk_files(server.data_directory()).unwrap().is_empty());
}

#[test]
fn two_clients_upload_different_files_at_once() {
    let server = DevServer::start().unwrap();
    let folder = work_folder();
    let first = write_test_file(folder.path(), "first.bin", 3 * MIB + 1, 90);
    let second = write_test_file(folder.path(), "second.bin", 2 * MIB + 2, 91);
    let start_upload = |file: &Path| {
        Command::new(cli_binary().unwrap())
            .arg("--server")
            .arg(server.address().to_string())
            .arg("upload")
            .arg(file)
            .arg("--dev-plain")
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .unwrap()
    };
    let first_upload = start_upload(&first);
    let second_upload = start_upload(&second);
    let first_summary = expect_success(&first_upload.wait_with_output().unwrap()).unwrap();
    let second_summary = expect_success(&second_upload.wait_with_output().unwrap()).unwrap();
    assert!(
        first_summary.starts_with("uploaded 4 of 4 chunks"),
        "{first_summary}"
    );
    assert!(
        second_summary.starts_with("uploaded 3 of 3 chunks"),
        "{second_summary}"
    );
    restore_and_compare(server.data_directory(), "first.bin", &first, folder.path());
    restore_and_compare(
        server.data_directory(),
        "second.bin",
        &second,
        folder.path(),
    );
}

#[test]
fn restore_refuses_to_overwrite_without_force() {
    let server = DevServer::start().unwrap();
    let folder = work_folder();
    let file = write_test_file(folder.path(), "keep.txt", 100, 95);
    upload(&server, &file, &[]);
    let existing = write_test_file(folder.path(), "existing.txt", 7, 96);
    let output = restore_file(server.data_directory(), "keep.txt", &existing).unwrap();
    assert_eq!(output.status.code(), Some(1));
    assert!(String::from_utf8_lossy(&output.stderr).contains("--force"));
    assert_eq!(fs::read(&existing).unwrap(), test_bytes(7, 96));

    let output = haotrannas_e2e::run_server_command(&[
        "restore".as_ref(),
        "--data-dir".as_ref(),
        server.data_directory().as_os_str(),
        "--path".as_ref(),
        "keep.txt".as_ref(),
        "--output".as_ref(),
        existing.as_os_str(),
        "--force".as_ref(),
    ])
    .unwrap();
    expect_success(&output).unwrap();
    assert_eq!(fs::read(&existing).unwrap(), fs::read(&file).unwrap());

    let missing = restore_file(
        server.data_directory(),
        "not/there.txt",
        &folder.path().join("x"),
    )
    .unwrap();
    assert_eq!(missing.status.code(), Some(1));
}

#[test]
fn cli_upload_needs_dev_plain_and_a_readable_file() {
    let server = DevServer::start().unwrap();
    let folder = work_folder();
    let file = write_test_file(folder.path(), "a.txt", 3, 97);
    let output = haotrannas_e2e::run_cli(&[
        "--server",
        &server.address().to_string(),
        "upload",
        file.to_str().unwrap(),
    ])
    .unwrap();
    assert_eq!(output.status.code(), Some(2));
    let output = cli_upload(server.address(), &folder.path().join("missing.txt"), &[]).unwrap();
    assert_eq!(output.status.code(), Some(1));
    assert!(output.stdout.is_empty());
}
