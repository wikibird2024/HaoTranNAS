//! Helpers for the end-to-end tests: find the built server and cli programs,
//! start the server on a temporary data folder, stop it afterwards, and talk
//! raw frames to it.
//!
//! The tests run the real binaries, so build them first:
//! `cargo build --workspace --bins`.

use std::ffi::OsStr;
use std::fs::{self, File};
use std::io::{BufRead, BufReader, Read, Write};
use std::net::{SocketAddr, TcpStream};
use std::path::{Path, PathBuf};
use std::process::{Child, Command, ExitStatus, Output, Stdio};
use std::sync::mpsc;
use std::time::Duration;

use anyhow::{Context, bail};
use haotrannas_core::chunker::ChunkHash;
use haotrannas_core::codec::{decode_frame, encode_frame};
use haotrannas_core::frame::FrameDecoder;
use haotrannas_core::message::Message;
use tempfile::TempDir;

/// How long to wait for the server's `listening on` line.
pub const SERVER_START_TIMEOUT_MS: u64 = 10_000;
/// How long a raw client waits for one read before failing the test.
pub const READ_TIMEOUT_MS: u64 = 5_000;
/// Start of the one line the server prints on stdout once it listens.
pub const LISTENING_LINE_PREFIX: &str = "listening on ";

/// Root folder of the Cargo workspace (the parent of `e2e/`).
pub fn workspace_root() -> PathBuf {
    let e2e_directory = Path::new(env!("CARGO_MANIFEST_DIR"));
    e2e_directory
        .parent()
        .unwrap_or(e2e_directory)
        .to_path_buf()
}

/// Path of a debug binary of this workspace, for example `haotrannas-server`.
///
/// Uses `CARGO_TARGET_DIR` when set, else `<workspace>/target`. Does not
/// check that the file exists.
pub fn workspace_binary(binary_name: &str) -> PathBuf {
    let target_directory = std::env::var_os("CARGO_TARGET_DIR")
        .map_or_else(|| workspace_root().join("target"), PathBuf::from);
    target_directory
        .join("debug")
        .join(format!("{binary_name}{}", std::env::consts::EXE_SUFFIX))
}

/// The server binary, checked to exist (with a hint to build it).
pub fn server_binary() -> anyhow::Result<PathBuf> {
    existing_binary("haotrannas-server")
}

/// The cli binary, checked to exist (with a hint to build it).
pub fn cli_binary() -> anyhow::Result<PathBuf> {
    existing_binary("haotrannas-cli")
}

fn existing_binary(binary_name: &str) -> anyhow::Result<PathBuf> {
    let binary_path = workspace_binary(binary_name);
    if !binary_path.exists() {
        bail!(
            "{} is missing: run `cargo build --workspace --bins` first",
            binary_path.display()
        );
    }
    Ok(binary_path)
}

/// Runs `haotrannas-server init --data-dir <data_directory>`.
pub fn init_data_folder(data_directory: &Path) -> anyhow::Result<Output> {
    let output = Command::new(server_binary()?)
        .arg("init")
        .arg("--data-dir")
        .arg(data_directory)
        .output()
        .context("cannot run haotrannas-server init")?;
    Ok(output)
}

/// A real `haotrannas-server run --dev-plain` on a fresh temporary data
/// folder (or a given one). Killed (SIGKILL) when dropped, unless already
/// stopped.
pub struct DevServer {
    child: Child,
    address: SocketAddr,
    data_directory: PathBuf,
    log_path: PathBuf,
    /// Kept so the folder lives as long as the server (`None` when the
    /// caller owns the folder).
    _temporary_directory: Option<TempDir>,
}

impl DevServer {
    /// `init`, then `run --dev-plain --listen 127.0.0.1:0`; waits for the
    /// `listening on` line.
    pub fn start() -> anyhow::Result<Self> {
        Self::start_with_args(&[])
    }

    /// Like [`start`](Self::start) with extra `run` flags, for example
    /// `["--handshake-timeout-ms", "300"]`.
    pub fn start_with_args(extra_run_args: &[&str]) -> anyhow::Result<Self> {
        // Short path: the admin socket path must stay under 108 bytes.
        let temporary_directory = tempfile::Builder::new()
            .prefix("htn-e2e-")
            .tempdir()
            .context("cannot make a temporary folder")?;
        let data_directory = temporary_directory.path().join("data");
        Self::spawn(data_directory, extra_run_args, Some(temporary_directory))
    }

    /// `init` (only if `data_directory` is not a data folder yet), then
    /// `run --dev-plain` on it. The caller owns the folder, so a test can
    /// kill the server and start a new one on the same data. Keep the path
    /// short (admin socket < 108 bytes).
    pub fn start_on(data_directory: &Path) -> anyhow::Result<Self> {
        Self::spawn(data_directory.to_path_buf(), &[], None)
    }

    fn spawn(
        data_directory: PathBuf,
        extra_run_args: &[&str],
        temporary_directory: Option<TempDir>,
    ) -> anyhow::Result<Self> {
        if !data_directory.join("index.sqlite").exists() {
            let init_output = init_data_folder(&data_directory)?;
            if !init_output.status.success() {
                bail!(
                    "init failed: {}",
                    String::from_utf8_lossy(&init_output.stderr)
                );
            }
        }

        // Each start gets its own log next to the data folder (a restart on
        // the same folder keeps the old log).
        let mut log_number = 1;
        let log_path = loop {
            let candidate = data_directory.with_file_name(format!("server-{log_number}.log"));
            if !candidate.exists() {
                break candidate;
            }
            log_number += 1;
        };
        let log_file = File::create(&log_path).context("cannot make the server log")?;
        let mut child = Command::new(server_binary()?)
            .args([
                "run",
                "--dev-plain",
                "--listen",
                "127.0.0.1:0",
                "--data-dir",
            ])
            .arg(&data_directory)
            .args(extra_run_args)
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(log_file)
            .spawn()
            .context("cannot start haotrannas-server run")?;

        let stdout = child.stdout.take().context("server stdout is not piped")?;
        let address = match wait_for_listening_line(stdout) {
            Ok(address) => address,
            Err(error) => {
                let _ = child.kill();
                let _ = child.wait();
                let log = fs::read_to_string(&log_path).unwrap_or_default();
                bail!("{error:#}\nserver log:\n{log}");
            }
        };
        Ok(Self {
            child,
            address,
            data_directory,
            log_path,
            _temporary_directory: temporary_directory,
        })
    }

    /// The address the server listens on (`127.0.0.1:<port>`).
    pub fn address(&self) -> SocketAddr {
        self.address
    }

    /// The server's data folder.
    pub fn data_directory(&self) -> &Path {
        &self.data_directory
    }

    /// SIGKILL (a crash: no cleanup at all) and wait for the process.
    pub fn kill_hard(&mut self) -> anyhow::Result<()> {
        self.child.kill().context("cannot kill the server")?;
        self.child.wait().context("cannot wait for the server")?;
        Ok(())
    }

    /// The process id, for sending signals.
    pub fn process_id(&self) -> u32 {
        self.child.id()
    }

    /// What the server wrote to stderr so far.
    pub fn log(&self) -> String {
        fs::read_to_string(&self.log_path).unwrap_or_default()
    }

    /// Sends SIGTERM and waits up to `timeout_ms` for the process to exit.
    pub fn stop_gracefully(&mut self, timeout_ms: u64) -> anyhow::Result<ExitStatus> {
        let kill_status = Command::new("kill")
            .arg("-TERM")
            .arg(self.child.id().to_string())
            .status()
            .context("cannot run kill")?;
        if !kill_status.success() {
            bail!("kill -TERM failed");
        }
        let poll_interval = Duration::from_millis(20);
        let mut waited_ms = 0;
        while waited_ms < timeout_ms {
            if let Some(status) = self.child.try_wait()? {
                return Ok(status);
            }
            std::thread::sleep(poll_interval);
            waited_ms += 20;
        }
        bail!("server did not stop within {timeout_ms} ms after SIGTERM")
    }
}

impl Drop for DevServer {
    fn drop(&mut self) {
        if matches!(self.child.try_wait(), Ok(None)) {
            let _ = self.child.kill();
        }
        let _ = self.child.wait();
    }
}

/// Reads the server's stdout until the `listening on <address>` line.
fn wait_for_listening_line(stdout: impl Read + Send + 'static) -> anyhow::Result<SocketAddr> {
    let (line_sender, line_receiver) = mpsc::channel();
    std::thread::spawn(move || {
        let mut first_line = String::new();
        let outcome = BufReader::new(stdout)
            .read_line(&mut first_line)
            .map(|_| first_line);
        let _ = line_sender.send(outcome);
    });
    let first_line = line_receiver
        .recv_timeout(Duration::from_millis(SERVER_START_TIMEOUT_MS))
        .context("server printed no line in time")?
        .context("cannot read server stdout")?;
    parse_listening_line(&first_line)
}

/// The address in a `listening on <ip>:<port>` line.
pub fn parse_listening_line(line: &str) -> anyhow::Result<SocketAddr> {
    let address_text = line
        .trim_end()
        .strip_prefix(LISTENING_LINE_PREFIX)
        .with_context(|| format!("server did not print `listening on`, got {line:?}"))?;
    address_text
        .parse()
        .with_context(|| format!("bad address in {line:?}"))
}

/// Runs the cli with `args` and returns its output.
pub fn run_cli(args: &[&str]) -> anyhow::Result<Output> {
    Command::new(cli_binary()?)
        .args(args)
        .output()
        .context("cannot run haotrannas-cli")
}

/// A hand-driven TCP client: sends any bytes or frames, reads frames back.
pub struct RawClient {
    stream: TcpStream,
    decoder: FrameDecoder,
}

impl RawClient {
    /// Connects with a read timeout of `READ_TIMEOUT_MS`.
    pub fn connect(address: SocketAddr) -> anyhow::Result<Self> {
        let stream = TcpStream::connect(address).context("cannot connect")?;
        stream.set_read_timeout(Some(Duration::from_millis(READ_TIMEOUT_MS)))?;
        stream.set_nodelay(true)?;
        Ok(Self {
            stream,
            decoder: FrameDecoder::new(),
        })
    }

    /// Writes raw bytes.
    pub fn send_bytes(&mut self, bytes: &[u8]) -> anyhow::Result<()> {
        self.stream.write_all(bytes)?;
        Ok(())
    }

    /// Encodes and writes one frame.
    pub fn send(&mut self, message: &Message, request_id: u32) -> anyhow::Result<()> {
        let frame_bytes = encode_frame(message, request_id)?;
        self.send_bytes(&frame_bytes)
    }

    /// The next frame as (request id, message); `None` once the server
    /// ended the connection. Fails on a read timeout.
    pub fn receive(&mut self) -> anyhow::Result<Option<(u32, Message)>> {
        let mut read_piece = [0_u8; 4096];
        loop {
            if let Some(next) = self.decoder.next_frame() {
                let frame = next?;
                let message = decode_frame(&frame)?;
                return Ok(Some((frame.header.request_id, message)));
            }
            let received_bytes = self
                .stream
                .read(&mut read_piece)
                .context("read failed (timeout?)")?;
            if received_bytes == 0 {
                if self.decoder.buffered_len_bytes() > 0 {
                    bail!("connection ended in the middle of a frame");
                }
                return Ok(None);
            }
            self.decoder.push(&read_piece[..received_bytes]);
        }
    }

    /// The next frame, failing if the connection ended instead.
    pub fn expect_frame(&mut self) -> anyhow::Result<(u32, Message)> {
        self.receive()?
            .context("connection ended, a frame was expected")
    }

    /// Fails unless the server ends the connection next.
    pub fn expect_end(&mut self) -> anyhow::Result<()> {
        match self.receive()? {
            None => Ok(()),
            Some((_, message)) => bail!("expected end of connection, got {message:?}"),
        }
    }
}

/// Runs the server binary with `args` (for example `restore ...`).
pub fn run_server_command(args: &[&OsStr]) -> anyhow::Result<Output> {
    Command::new(server_binary()?)
        .args(args)
        .output()
        .context("cannot run haotrannas-server")
}

/// `haotrannas-server restore --data-dir D --path P --output F` (device 1,
/// latest version).
pub fn restore_file(data_directory: &Path, path: &str, output: &Path) -> anyhow::Result<Output> {
    run_server_command(&[
        OsStr::new("restore"),
        OsStr::new("--data-dir"),
        data_directory.as_os_str(),
        OsStr::new("--path"),
        OsStr::new(path),
        OsStr::new("--output"),
        output.as_os_str(),
    ])
}

/// `haotrannas-cli --server A upload <file> --dev-plain [extra args]`.
pub fn cli_upload(address: SocketAddr, file: &Path, extra_args: &[&str]) -> anyhow::Result<Output> {
    Command::new(cli_binary()?)
        .arg("--server")
        .arg(address.to_string())
        .arg("upload")
        .arg(file)
        .arg("--dev-plain")
        .args(extra_args)
        .output()
        .context("cannot run haotrannas-cli upload")
}

/// Stdout of a finished program, failing (with stdout and stderr) unless
/// it exited 0.
pub fn expect_success(output: &Output) -> anyhow::Result<String> {
    let stdout = String::from_utf8_lossy(&output.stdout).into_owned();
    if !output.status.success() {
        bail!(
            "exit {:?}\nstdout: {stdout}\nstderr: {}",
            output.status.code(),
            String::from_utf8_lossy(&output.stderr)
        );
    }
    Ok(stdout)
}

/// Pseudo-random bytes from `seed` (xorshift: same seed, same bytes).
pub fn test_bytes(size_bytes: usize, seed: u64) -> Vec<u8> {
    let mut state = seed.wrapping_mul(0x9E37_79B9_7F4A_7C15) | 1;
    let mut bytes = Vec::with_capacity(size_bytes + 8);
    while bytes.len() < size_bytes {
        state ^= state << 13;
        state ^= state >> 7;
        state ^= state << 17;
        bytes.extend_from_slice(&state.to_le_bytes());
    }
    bytes.truncate(size_bytes);
    bytes
}

/// Every file under `<data_directory>/chunks/`, sorted.
pub fn chunk_files(data_directory: &Path) -> anyhow::Result<Vec<PathBuf>> {
    fn walk(directory: &Path, found: &mut Vec<PathBuf>) -> anyhow::Result<()> {
        for entry in fs::read_dir(directory)? {
            let entry = entry?;
            if entry.file_type()?.is_dir() {
                walk(&entry.path(), found)?;
            } else {
                found.push(entry.path());
            }
        }
        Ok(())
    }
    let mut found = Vec::new();
    walk(&data_directory.join("chunks"), &mut found)?;
    found.sort();
    Ok(found)
}

/// Fails unless every chunk file's bytes hash to its own name. Returns how
/// many chunk files there are.
pub fn check_every_chunk_file(data_directory: &Path) -> anyhow::Result<usize> {
    let files = chunk_files(data_directory)?;
    for file in &files {
        let name = file
            .file_name()
            .and_then(|name| name.to_str())
            .context("chunk file name is not UTF-8")?;
        let actual_hash = ChunkHash::of_bytes(&fs::read(file)?).to_hex();
        if actual_hash != name {
            bail!("{} hashes to {actual_hash}", file.display());
        }
    }
    Ok(files.len())
}

/// Number of committed versions of (device 1, `path`), read from the catalog.
pub fn version_count(data_directory: &Path, path: &str) -> anyhow::Result<i64> {
    let connection = rusqlite::Connection::open_with_flags(
        data_directory.join("index.sqlite"),
        rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY,
    )?;
    connection.busy_timeout(Duration::from_secs(5))?;
    Ok(connection.query_row(
        "SELECT COUNT(*) FROM versions JOIN files ON files.id = versions.file_id
         WHERE files.device_id = 1 AND files.path = ?1",
        [path],
        |row| row.get(0),
    )?)
}

/// Marks a chunk bad in the catalog, as scrub does when it finds bit rot
/// (M6). Safe while the server runs (SQLite locking, WAL).
pub fn mark_chunk_bad(data_directory: &Path, chunk_hash: &ChunkHash) -> anyhow::Result<()> {
    let connection = rusqlite::Connection::open(data_directory.join("index.sqlite"))?;
    connection.busy_timeout(Duration::from_secs(5))?;
    let changed_count = connection.execute(
        "UPDATE chunks SET status = 'bad' WHERE hash = ?1",
        [chunk_hash.0],
    )?;
    if changed_count != 1 {
        bail!("chunk {chunk_hash} is not in the catalog");
    }
    Ok(())
}

/// Polls `condition` every 20 ms until it is true; fails after `timeout_ms`.
pub fn wait_until(
    timeout_ms: u64,
    mut condition: impl FnMut() -> anyhow::Result<bool>,
) -> anyhow::Result<()> {
    let started_at = std::time::Instant::now();
    while started_at.elapsed() < Duration::from_millis(timeout_ms) {
        if condition()? {
            return Ok(());
        }
        std::thread::sleep(Duration::from_millis(20));
    }
    bail!("condition not met within {timeout_ms} ms")
}
