//! Milestone M6 (server side) end to end: the scrub job finds bit rot and
//! missing chunk files, the next upload heals them, and the cleanup job
//! deletes expired uploads, unused chunks, orphan chunk files and old temp
//! files, but never a chunk an upload or a version still needs (D-020).
//!
//! The real server runs with the hidden test flags `--upload-expiry-ms` and
//! `--unused-chunk-grace-ms`; `haotrannas-server scrub-now` / `cleanup-now`
//! / `scrub-report` talk to it over the admin socket. Needs
//! `cargo build --workspace --bins`.

use std::ffi::OsStr;
use std::fs::{self, File};
use std::path::{Path, PathBuf};
use std::time::{Duration, SystemTime};

use haotrannas_core::chunker::{ChunkHash, chunk_reader};
use haotrannas_core::error_code::ErrorCode;
use haotrannas_core::limits::{CHUNK_SIZE_BYTES, PROTOCOL_VERSION};
use haotrannas_core::message::Message;
use haotrannas_e2e::{
    DevServer, RawClient, chunk_files, cli_upload, expect_success, restore_file,
    run_server_command, test_bytes,
};

const MIB: usize = CHUNK_SIZE_BYTES as usize;

/// A folder for test files, removed at the end of the test.
fn work_folder() -> tempfile::TempDir {
    tempfile::Builder::new()
        .prefix("htn-e2e-")
        .tempdir()
        .unwrap()
}

fn write_test_file(folder: &Path, name: &str, size_bytes: usize, seed: u64) -> PathBuf {
    let file_path = folder.join(name);
    fs::write(&file_path, test_bytes(size_bytes, seed)).unwrap();
    file_path
}

/// Uploads with the cli (dev-plain) and returns its summary line.
fn upload(server: &DevServer, file: &Path) -> String {
    let output = cli_upload(server.address(), file, &[]).unwrap();
    expect_success(&output)
        .unwrap_or_else(|error| panic!("{error:#}"))
        .trim_end()
        .to_owned()
}

/// `haotrannas-server <command> --data-dir D`; returns the stdout line.
fn job_command(server: &DevServer, command: &str) -> String {
    let output = run_server_command(&[
        OsStr::new(command),
        OsStr::new("--data-dir"),
        server.data_directory().as_os_str(),
    ])
    .unwrap();
    let stdout = expect_success(&output).unwrap_or_else(|error| panic!("{error:#}"));
    let lines: Vec<&str> = stdout.lines().collect();
    assert_eq!(lines.len(), 1, "one summary line: {stdout}");
    lines[0].to_owned()
}

/// The number after `name` in a `name value ...` summary line.
fn number_in(summary: &str, name: &str) -> u64 {
    let words: Vec<&str> = summary.split(' ').collect();
    let position = words
        .iter()
        .position(|word| *word == name)
        .unwrap_or_else(|| panic!("no {name} in {summary}"));
    words[position + 1].parse().unwrap()
}

/// (`bad_found`, `missing`, `repaired`) of a scrub summary.
fn scrub_counts(summary: &str) -> (u64, u64, u64) {
    (
        number_in(summary, "bad_found"),
        number_in(summary, "missing"),
        number_in(summary, "repaired"),
    )
}

/// `chunks.status` of one chunk, or `None` without a row.
fn chunk_status(data_directory: &Path, chunk_hash: &ChunkHash) -> Option<String> {
    let connection = rusqlite::Connection::open_with_flags(
        data_directory.join("index.sqlite"),
        rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY,
    )
    .unwrap();
    connection.busy_timeout(Duration::from_secs(5)).unwrap();
    connection
        .query_row(
            "SELECT status FROM chunks WHERE hash = ?1",
            [chunk_hash.0],
            |row| row.get(0),
        )
        .ok()
}

/// The chunk file of `hash` under the data folder.
fn chunk_path(data_directory: &Path, hash: &ChunkHash) -> PathBuf {
    let hex_name = hash.to_hex();
    data_directory
        .join("chunks")
        .join(&hex_name[0..2])
        .join(&hex_name[2..4])
        .join(&hex_name)
}

fn set_age(path: &Path, age: Duration) {
    File::options()
        .write(true)
        .open(path)
        .unwrap()
        .set_modified(SystemTime::now() - age)
        .unwrap();
}

/// A raw dev-plain client after `Hello`; it numbers its own requests.
struct Client {
    raw: RawClient,
    next_request_id: u32,
}

impl Client {
    fn connect(server: &DevServer) -> Self {
        let mut client = Self {
            raw: RawClient::connect(server.address()).unwrap(),
            next_request_id: 1,
        };
        let reply = client.ask(&Message::Hello {
            protocol_version: PROTOCOL_VERSION,
            client_software: "e2e/1".to_owned(),
            device_name: "e2e".to_owned(),
        });
        assert!(matches!(reply, Message::HelloOk { device_id: 1, .. }));
        client
    }

    fn ask(&mut self, message: &Message) -> Message {
        let request_id = self.next_request_id;
        self.next_request_id += 1;
        self.raw.send(message, request_id).unwrap();
        let (reply_id, reply) = self.raw.expect_frame().unwrap();
        assert_eq!(reply_id, request_id);
        reply
    }

    /// `FileOffer` → (upload id, missing indexes); `file_sha256` replaced
    /// when given.
    fn offer(
        &mut self,
        path: &str,
        file_bytes: &[u8],
        file_sha256: Option<[u8; 32]>,
    ) -> (u64, Vec<u32>) {
        let chunk_list = chunk_reader(file_bytes).unwrap();
        let reply = self.ask(&Message::FileOffer {
            path: path.to_owned(),
            size_bytes: chunk_list.size_bytes,
            modified_time_ms: 1_700_000_000_000,
            file_sha256: file_sha256.unwrap_or(chunk_list.file_sha256),
            chunk_hashes: chunk_list.chunk_hashes,
        });
        match reply {
            Message::NeedChunks {
                upload_id,
                existing_version_id: 0,
                missing_indexes,
            } => (upload_id, missing_indexes),
            other => panic!("expected NeedChunks for a new upload, got {other:?}"),
        }
    }

    fn send_chunk(&mut self, upload_id: u64, file_bytes: &[u8], chunk_index: u32) {
        let start = chunk_index as usize * MIB;
        let data = file_bytes[start..(start + MIB).min(file_bytes.len())].to_vec();
        let reply = self.ask(&Message::ChunkData {
            upload_id,
            chunk_index,
            chunk_sha256: ChunkHash::of_bytes(&data),
            data,
        });
        assert!(matches!(reply, Message::ChunkOk { .. }), "{reply:?}");
    }

    fn commit(&mut self, upload_id: u64) -> Message {
        self.ask(&Message::Commit { upload_id })
    }
}

fn assert_error(message: &Message, expected_code: ErrorCode) {
    match message {
        Message::Error { code, .. } if *code == expected_code.code() => {}
        other => panic!("expected Error {}, got {other:?}", expected_code.name()),
    }
}

#[test]
fn scrub_finds_a_flipped_byte_the_next_upload_heals_it_and_a_deleted_file_is_missing() {
    let mut server = DevServer::start().unwrap();
    let folder = work_folder();
    let data_directory = server.data_directory().to_owned();
    let file = write_test_file(folder.path(), "photo.jpg", 2 * MIB + 4000, 80);
    let file_bytes = fs::read(&file).unwrap();
    let chunk_hashes = chunk_reader(&file_bytes[..]).unwrap().chunk_hashes;
    upload(&server, &file);

    let clean = job_command(&server, "scrub-now");
    assert_eq!(number_in(&clean, "chunks_checked"), 3, "{clean}");
    assert_eq!(number_in(&clean, "bytes_checked"), file_bytes.len() as u64);
    assert_eq!(scrub_counts(&clean), (0, 0, 0), "{clean}");

    // Bit rot: one byte flipped in chunk 1.
    let damaged_path = chunk_path(&data_directory, &chunk_hashes[1]);
    let mut on_disk = fs::read(&damaged_path).unwrap();
    on_disk[777] ^= 0x10;
    fs::write(&damaged_path, &on_disk).unwrap();
    let found = job_command(&server, "scrub-now");
    assert_eq!(scrub_counts(&found), (1, 0, 0), "{found}");
    assert_eq!(
        chunk_status(&data_directory, &chunk_hashes[1]).as_deref(),
        Some("bad")
    );
    assert_eq!(job_command(&server, "scrub-report"), found);

    // The same file uploaded again sends exactly the bad chunk (heal) and
    // answers with the same version (D-029).
    assert_eq!(
        upload(&server, &file),
        format!("uploaded 1 of 3 chunks ({MIB} bytes), version 1")
    );
    let healed = job_command(&server, "scrub-now");
    assert_eq!(scrub_counts(&healed), (0, 0, 0), "{healed}");
    assert_eq!(
        chunk_status(&data_directory, &chunk_hashes[1]).as_deref(),
        Some("ok")
    );

    // A deleted chunk file is missing, and marked bad.
    fs::remove_file(chunk_path(&data_directory, &chunk_hashes[2])).unwrap();
    let missing = job_command(&server, "scrub-now");
    assert_eq!(scrub_counts(&missing), (0, 1, 0), "{missing}");
    assert_eq!(
        chunk_status(&data_directory, &chunk_hashes[2]).as_deref(),
        Some("bad")
    );

    // The JSON report says the same, and the server stops cleanly.
    let report: serde_json::Value =
        serde_json::from_slice(&fs::read(data_directory.join("scrub-report.json")).unwrap())
            .unwrap();
    assert_eq!(report["missing"], 1);
    assert_eq!(report["chunks_checked"], 3);
    assert!(server.stop_gracefully(5_000).unwrap().success());
}

#[test]
fn cleanup_deletes_what_nobody_needs_and_keeps_what_uploads_and_versions_use() {
    const EXPIRY_MS: u64 = 4_000;
    let server = DevServer::start_with_args(&[
        "--upload-expiry-ms",
        &EXPIRY_MS.to_string(),
        "--unused-chunk-grace-ms",
        "0",
    ])
    .unwrap();
    let folder = work_folder();
    let data_directory = server.data_directory().to_owned();

    // A committed version.
    let kept_file = write_test_file(folder.path(), "kept.jpg", MIB + 100, 81);
    upload(&server, &kept_file);
    let kept_hashes = chunk_reader(&fs::read(&kept_file).unwrap()[..])
        .unwrap()
        .chunk_hashes;

    // An upload that expires: one chunk sent, never committed.
    let mut client = Client::connect(&server);
    let expired_bytes = test_bytes(3000, 82);
    let expired_hash = ChunkHash::of_bytes(&expired_bytes);
    let (expired_upload_id, missing) = client.offer("expired.bin", &expired_bytes, None);
    assert_eq!(missing, vec![0]);
    client.send_chunk(expired_upload_id, &expired_bytes, 0);
    std::thread::sleep(Duration::from_millis(EXPIRY_MS + 500));

    // An open upload, fresh: chunk 0 sent, chunk 1 still to come.
    let open_bytes = test_bytes(MIB + 200, 83);
    let open_hashes = chunk_reader(&open_bytes[..]).unwrap().chunk_hashes;
    let (open_upload_id, missing) = client.offer("open.bin", &open_bytes, None);
    assert_eq!(missing, vec![0, 1]);
    client.send_chunk(open_upload_id, &open_bytes, 0);

    // Temp junk (old and new) and an orphan chunk file (no catalog row).
    let tmp_directory = data_directory.join("tmp");
    fs::write(tmp_directory.join("old-junk.tmp"), b"junk").unwrap();
    set_age(
        &tmp_directory.join("old-junk.tmp"),
        Duration::from_secs(7200),
    );
    fs::write(tmp_directory.join("new-junk.tmp"), b"junk").unwrap();
    let orphan_bytes = b"orphan chunk";
    let orphan_hash = ChunkHash::of_bytes(orphan_bytes);
    let orphan_path = chunk_path(&data_directory, &orphan_hash);
    fs::create_dir_all(orphan_path.parent().unwrap()).unwrap();
    fs::write(&orphan_path, orphan_bytes).unwrap();
    let chunk_files_before = chunk_files(&data_directory).unwrap().len();

    let summary = job_command(&server, "cleanup-now");
    assert_eq!(
        (
            number_in(&summary, "expired_uploads"),
            number_in(&summary, "tmp_files"),
            number_in(&summary, "unused_chunks"),
            number_in(&summary, "orphan_files"),
        ),
        (1, 1, 1, 1),
        "{summary}"
    );
    assert!(!chunk_path(&data_directory, &expired_hash).exists());
    assert_eq!(chunk_status(&data_directory, &expired_hash), None);
    assert!(!orphan_path.exists());
    assert_eq!(
        chunk_files(&data_directory).unwrap().len(),
        chunk_files_before - 2
    );
    assert!(!tmp_directory.join("old-junk.tmp").exists());
    assert!(tmp_directory.join("new-junk.tmp").exists());
    for kept_hash in kept_hashes.iter().chain(&open_hashes[..1]) {
        assert!(chunk_path(&data_directory, kept_hash).exists());
        assert_eq!(
            chunk_status(&data_directory, kept_hash).as_deref(),
            Some("ok")
        );
    }

    // The expired upload is gone; the open one still commits.
    assert_error(&client.commit(expired_upload_id), ErrorCode::UnknownUpload);
    client.send_chunk(open_upload_id, &open_bytes, 1);
    assert!(matches!(
        client.commit(open_upload_id),
        Message::CommitOk { .. }
    ));

    // ReadChunk of the deleted chunk: NOT_FOUND, and the connection stays.
    assert_error(
        &client.ask(&Message::ReadChunk {
            chunk_sha256: expired_hash,
        }),
        ErrorCode::NotFound,
    );
    // Race order 2: the next offer lists the deleted chunk missing; the
    // client sends it again and the commit succeeds.
    let (upload_id, missing) = client.offer("expired.bin", &expired_bytes, None);
    assert_eq!(missing, vec![0]);
    client.send_chunk(upload_id, &expired_bytes, 0);
    assert!(matches!(client.commit(upload_id), Message::CommitOk { .. }));

    // Every committed file restores byte for byte.
    for (remote_path, original) in [
        ("kept.jpg", fs::read(&kept_file).unwrap()),
        ("open.bin", open_bytes),
        ("expired.bin", expired_bytes),
    ] {
        let restored = folder.path().join(format!("restored-{remote_path}"));
        expect_success(&restore_file(&data_directory, remote_path, &restored).unwrap())
            .unwrap_or_else(|error| panic!("{error:#}"));
        assert!(
            fs::read(&restored).unwrap() == original,
            "{remote_path} differs"
        );
    }
}

/// Race order 1: a chunk is unused (its upload was dropped), then a new
/// `FileOffer` names it before cleanup runs. The offer does not list it
/// missing, so cleanup must keep it, and the commit needs no chunk.
#[test]
fn unused_chunk_offered_again_before_cleanup_is_kept() {
    let server = DevServer::start_with_args(&["--unused-chunk-grace-ms", "0"]).unwrap();
    let folder = work_folder();
    let data_directory = server.data_directory().to_owned();
    let mut client = Client::connect(&server);
    let file_bytes = test_bytes(5000, 84);
    let chunk_hash = ChunkHash::of_bytes(&file_bytes);

    // A wrong whole-file hash: Commit drops the upload, the chunk stays
    // stored with no upload or version naming it.
    let (upload_id, _) = client.offer("again.bin", &file_bytes, Some([0xAB; 32]));
    client.send_chunk(upload_id, &file_bytes, 0);
    assert_error(&client.commit(upload_id), ErrorCode::FileHashMismatch);
    assert_eq!(
        chunk_status(&data_directory, &chunk_hash).as_deref(),
        Some("ok")
    );

    let (upload_id, missing) = client.offer("again.bin", &file_bytes, None);
    assert!(missing.is_empty(), "stored and ok: nothing to send");
    let summary = job_command(&server, "cleanup-now");
    assert_eq!(number_in(&summary, "unused_chunks"), 0, "{summary}");
    assert!(chunk_path(&data_directory, &chunk_hash).exists());
    assert!(matches!(client.commit(upload_id), Message::CommitOk { .. }));

    let restored = folder.path().join("restored-again.bin");
    expect_success(&restore_file(&data_directory, "again.bin", &restored).unwrap())
        .unwrap_or_else(|error| panic!("{error:#}"));
    assert!(
        fs::read(&restored).unwrap() == file_bytes,
        "restored bytes differ"
    );
}

/// The jobs run in TLS mode too, and the admin commands say when they
/// cannot run.
#[test]
fn jobs_answer_in_tls_mode_and_errors_are_clear() {
    let mut server = DevServer::start_tls().unwrap();
    let report_before = run_server_command(&[
        OsStr::new("scrub-report"),
        OsStr::new("--data-dir"),
        server.data_directory().as_os_str(),
    ])
    .unwrap();
    assert_eq!(report_before.status.code(), Some(1));
    assert!(
        String::from_utf8_lossy(&report_before.stderr).contains("no scrub has finished yet"),
        "{report_before:?}"
    );
    let summary = job_command(&server, "scrub-now");
    assert_eq!(number_in(&summary, "chunks_checked"), 0, "{summary}");
    assert_eq!(job_command(&server, "scrub-report"), summary);
    let summary = job_command(&server, "cleanup-now");
    assert!(
        summary.starts_with("cleanup expired_uploads 0 "),
        "{summary}"
    );
    let data_directory = server.data_directory().to_owned();
    assert!(server.stop_gracefully(5_000).unwrap().success());

    // No server: the command says so.
    let output = run_server_command(&[
        OsStr::new("scrub-now"),
        OsStr::new("--data-dir"),
        data_directory.as_os_str(),
    ])
    .unwrap();
    assert_eq!(output.status.code(), Some(1));
    assert!(String::from_utf8_lossy(&output.stderr).contains("no running server"));
}
