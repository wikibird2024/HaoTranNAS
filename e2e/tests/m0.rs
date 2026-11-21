//! Milestone M0 end to end: the real server in `--dev-plain` mode, driven by
//! the real cli and by raw TCP clients that break the protocol on purpose.
//!
//! Needs `cargo build --workspace --bins` first.

use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixStream;

use haotrannas_core::error_code::{CloseReason, ErrorCode};
use haotrannas_core::limits::PROTOCOL_VERSION;
use haotrannas_core::message::Message;
use haotrannas_e2e::{DevServer, RawClient, init_data_folder, run_cli, server_binary};

fn hello(protocol_version: u16) -> Message {
    Message::Hello {
        protocol_version,
        client_software: "e2e/1".to_owned(),
        device_name: "e2e".to_owned(),
    }
}

fn file_offer() -> Message {
    Message::FileOffer {
        path: "photos/a.jpg".to_owned(),
        size_bytes: 0,
        modified_time_ms: 0,
        file_sha256: [0; 32],
        chunk_hashes: Vec::new(),
    }
}

/// Fails unless `message` is `Error` with `expected_code`.
fn assert_error(message: &Message, expected_code: ErrorCode) {
    match message {
        Message::Error { code, .. } if *code == expected_code.code() => {}
        other => panic!("expected Error {}, got {other:?}", expected_code.name()),
    }
}

/// Sends `Hello` and checks `HelloOk` for the dev device.
fn say_hello(client: &mut RawClient) {
    client.send(&hello(PROTOCOL_VERSION), 1).unwrap();
    let (request_id, reply) = client.expect_frame().unwrap();
    assert_eq!(request_id, 1);
    match reply {
        Message::HelloOk {
            protocol_version,
            server_software,
            device_id,
            chunk_size_bytes,
            max_frame_length_bytes,
            ..
        } => {
            assert_eq!(protocol_version, PROTOCOL_VERSION);
            assert!(server_software.starts_with("haotrannas-server/"));
            assert_eq!(device_id, 1, "dev mode is device 1");
            assert_eq!(chunk_size_bytes, 1_048_576);
            assert_eq!(max_frame_length_bytes, 4_194_304);
        }
        other => panic!("expected HelloOk, got {other:?}"),
    }
}

#[test]
fn cli_ping_prints_pong() {
    let server = DevServer::start().unwrap();
    let address = server.address().to_string();
    let output = run_cli(&["--server", &address, "ping", "--dev-plain", "--count", "3"]).unwrap();
    let stdout = String::from_utf8_lossy(&output.stdout);
    assert!(
        output.status.success(),
        "stdout: {stdout}\nstderr: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    let lines: Vec<&str> = stdout.lines().collect();
    assert_eq!(lines.len(), 4, "{stdout}");
    assert!(
        lines[0].starts_with("connected: haotrannas (haotrannas-server/"),
        "{stdout}"
    );
    assert!(lines[0].ends_with("), device 1"), "{stdout}");
    for pong_line in &lines[1..] {
        assert!(pong_line.starts_with("Pong in "), "{stdout}");
        assert!(pong_line.ends_with(" ms"), "{stdout}");
    }
}

#[test]
fn cli_without_dev_plain_and_without_pairing_says_pair_first() {
    let server = DevServer::start().unwrap();
    let address = server.address().to_string();
    let identity_folder = tempfile::Builder::new()
        .prefix("htn-e2e-")
        .tempdir()
        .unwrap();
    let identity_directory = identity_folder.path().join("id");
    let output = run_cli(&[
        "--server",
        &address,
        "--identity-dir",
        identity_directory.to_str().unwrap(),
        "ping",
    ])
    .unwrap();
    assert_eq!(output.status.code(), Some(1));
    assert!(
        String::from_utf8_lossy(&output.stderr)
            .contains("not paired: run `haotrannas-cli pair` first")
    );
}

#[test]
fn cli_reports_a_server_that_is_not_there() {
    // Port 1 on loopback: nothing listens there.
    let output = run_cli(&["--server", "127.0.0.1:1", "ping", "--dev-plain"]).unwrap();
    assert_eq!(output.status.code(), Some(1));
    assert!(String::from_utf8_lossy(&output.stderr).contains("cannot connect"));
}

#[test]
fn garbage_gets_malformed_frame_then_end() {
    let server = DevServer::start().unwrap();
    let mut client = RawClient::connect(server.address()).unwrap();
    // "GET " read as a length is far over 4 MiB.
    client.send_bytes(b"GET / HTTP/1.1\r\n\r\n").unwrap();
    let (request_id, reply) = client.expect_frame().unwrap();
    assert_eq!(request_id, 0, "no readable request: id 0");
    assert_error(&reply, ErrorCode::MalformedFrame);
    client.expect_end().unwrap();
}

#[test]
fn unknown_message_type_gets_malformed_frame_with_its_id() {
    let server = DevServer::start().unwrap();
    let mut client = RawClient::connect(server.address()).unwrap();
    client
        .send_bytes(&[0, 0, 0, 6, 0x77, 0x77, 0, 0, 0, 42])
        .unwrap();
    let (request_id, reply) = client.expect_frame().unwrap();
    assert_eq!(request_id, 42);
    assert_error(&reply, ErrorCode::MalformedFrame);
    client.expect_end().unwrap();
}

#[test]
fn hello_with_version_3_gets_version_mismatch() {
    let server = DevServer::start().unwrap();
    let mut client = RawClient::connect(server.address()).unwrap();
    client.send(&hello(3), 1).unwrap();
    let (request_id, reply) = client.expect_frame().unwrap();
    assert_eq!(request_id, 1);
    assert_error(&reply, ErrorCode::VersionMismatch);
    client.expect_end().unwrap();
}

#[test]
fn version_1_client_works_but_cannot_ask_for_thumbnails() {
    let server = DevServer::start().unwrap();
    let mut client = RawClient::connect(server.address()).unwrap();
    client.send(&hello(1), 1).unwrap();
    let (_, reply) = client.expect_frame().unwrap();
    assert!(
        matches!(
            reply,
            Message::HelloOk {
                protocol_version: 1,
                ..
            }
        ),
        "{reply:?}"
    );
    client.send(&Message::Ping, 2).unwrap();
    assert_eq!(client.expect_frame().unwrap(), (2, Message::Pong));
    let read_thumbnail = Message::ReadThumbnail {
        device_id: 0,
        path: "a.jpg".to_owned(),
        version_id: 0,
    };
    client.send(&read_thumbnail, 3).unwrap();
    let (_, reply) = client.expect_frame().unwrap();
    assert_error(&reply, ErrorCode::UnexpectedMessage);
    client.expect_end().unwrap();
}

#[test]
fn file_offer_before_hello_gets_unexpected_message() {
    let server = DevServer::start().unwrap();
    let mut client = RawClient::connect(server.address()).unwrap();
    client.send(&file_offer(), 1).unwrap();
    let (_, reply) = client.expect_frame().unwrap();
    assert_error(&reply, ErrorCode::UnexpectedMessage);
    client.expect_end().unwrap();
}

#[test]
fn ping_before_hello_gets_unexpected_message() {
    let server = DevServer::start().unwrap();
    let mut client = RawClient::connect(server.address()).unwrap();
    client.send(&Message::Ping, 1).unwrap();
    let (_, reply) = client.expect_frame().unwrap();
    assert_error(&reply, ErrorCode::UnexpectedMessage);
    client.expect_end().unwrap();
}

#[test]
fn request_error_is_not_fatal_and_the_connection_stays() {
    let server = DevServer::start().unwrap();
    let mut client = RawClient::connect(server.address()).unwrap();
    say_hello(&mut client);
    // Every request is built since M5; a non-fatal error keeps the connection.
    let read_file = Message::ReadFile {
        device_id: 0,
        path: "missing.txt".to_owned(),
        version_id: 0,
    };
    client.send(&read_file, 2).unwrap();
    let (request_id, reply) = client.expect_frame().unwrap();
    assert_eq!(request_id, 2);
    assert_error(&reply, ErrorCode::NotFound);
    client.send(&Message::Ping, 3).unwrap();
    assert_eq!(client.expect_frame().unwrap(), (3, Message::Pong));
}

#[test]
fn no_hello_in_time_gets_handshake_timeout() {
    let server = DevServer::start_with_args(&["--handshake-timeout-ms", "300"]).unwrap();
    let mut client = RawClient::connect(server.address()).unwrap();
    let (request_id, reply) = client.expect_frame().unwrap();
    assert_eq!(request_id, 0);
    match reply {
        Message::Close { reason, .. } => {
            assert_eq!(reason, CloseReason::HandshakeTimeout.reason());
        }
        other => panic!("expected Close HANDSHAKE_TIMEOUT, got {other:?}"),
    }
    client.expect_end().unwrap();
}

#[test]
fn two_clients_at_once_both_get_pong() {
    let server = DevServer::start().unwrap();
    let mut first = RawClient::connect(server.address()).unwrap();
    let mut second = RawClient::connect(server.address()).unwrap();
    say_hello(&mut first);
    say_hello(&mut second);
    for request_id in 2..5 {
        second.send(&Message::Ping, request_id).unwrap();
        first.send(&Message::Ping, request_id).unwrap();
        assert_eq!(first.expect_frame().unwrap(), (request_id, Message::Pong));
        assert_eq!(second.expect_frame().unwrap(), (request_id, Message::Pong));
    }
}

#[test]
fn admin_status_counts_open_connections() {
    let server = DevServer::start().unwrap();
    let mut client = RawClient::connect(server.address()).unwrap();
    say_hello(&mut client);

    let socket_path = server.data_directory().join("admin.sock");
    let mut admin = UnixStream::connect(&socket_path).unwrap();
    admin.write_all(b"status\n").unwrap();
    let mut reply = String::new();
    BufReader::new(&admin).read_line(&mut reply).unwrap();
    assert_eq!(reply, "ok 1 connections\n");
}

#[test]
fn sigterm_sends_server_shutdown_and_exits_cleanly() {
    let mut server = DevServer::start().unwrap();
    let mut client = RawClient::connect(server.address()).unwrap();
    say_hello(&mut client);
    let exit_status = server.stop_gracefully(5_000).unwrap();
    let (request_id, reply) = client.expect_frame().unwrap();
    assert_eq!(request_id, 0);
    match reply {
        Message::Close { reason, .. } => {
            assert_eq!(reason, CloseReason::ServerShutdown.reason());
        }
        other => panic!("expected Close SERVER_SHUTDOWN, got {other:?}"),
    }
    client.expect_end().unwrap();
    assert!(exit_status.success(), "log:\n{}", server.log());
    assert!(
        !server.data_directory().join("admin.sock").exists(),
        "admin socket removed on stop"
    );
}

#[test]
fn dev_plain_refuses_a_network_address() {
    let folder = tempfile::Builder::new()
        .prefix("htn-e2e-")
        .tempdir()
        .unwrap();
    let data_directory = folder.path().join("data");
    assert!(init_data_folder(&data_directory).unwrap().status.success());
    let output = std::process::Command::new(server_binary().unwrap())
        .args(["run", "--dev-plain", "--listen", "0.0.0.0:0", "--data-dir"])
        .arg(&data_directory)
        .output()
        .unwrap();
    assert_eq!(output.status.code(), Some(1));
    assert!(String::from_utf8_lossy(&output.stderr).contains("loopback only"));
}

#[test]
fn tls_run_needs_an_initialized_data_folder() {
    let folder = tempfile::Builder::new()
        .prefix("htn-e2e-")
        .tempdir()
        .unwrap();
    let output = std::process::Command::new(server_binary().unwrap())
        .args(["run", "--listen", "127.0.0.1:0", "--data-dir"])
        .arg(folder.path().join("missing"))
        .output()
        .unwrap();
    assert_eq!(output.status.code(), Some(1));
    assert!(String::from_utf8_lossy(&output.stderr).contains("is not initialized"));
}

#[test]
fn init_twice_is_refused_with_the_server_id() {
    let folder = tempfile::Builder::new()
        .prefix("htn-e2e-")
        .tempdir()
        .unwrap();
    let data_directory = folder.path().join("data");
    let first = init_data_folder(&data_directory).unwrap();
    assert!(first.status.success());
    let first_stdout = String::from_utf8_lossy(&first.stdout).into_owned();
    let short_id = first_stdout
        .trim_end()
        .rsplit(' ')
        .next()
        .unwrap()
        .to_owned();
    assert_eq!(short_id.len(), "3F9A-C21B-77E0".len(), "{first_stdout}");

    let second = init_data_folder(&data_directory).unwrap();
    assert_eq!(second.status.code(), Some(1));
    assert!(String::from_utf8_lossy(&second.stderr).contains(&short_id));
}
