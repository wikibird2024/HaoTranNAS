//! Helpers for the end-to-end tests: find the built server and cli programs,
//! start the server on a temporary data folder, stop it afterwards, and talk
//! raw frames to it.
//!
//! The tests run the real binaries, so build them first:
//! `cargo build --workspace --bins`.

use std::fs::{self, File};
use std::io::{BufRead, BufReader, Read, Write};
use std::net::{SocketAddr, TcpStream};
use std::path::{Path, PathBuf};
use std::process::{Child, Command, ExitStatus, Output, Stdio};
use std::sync::mpsc;
use std::time::Duration;

use anyhow::{Context, bail};
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
/// folder. Killed (SIGKILL) when dropped, unless already stopped.
pub struct DevServer {
    child: Child,
    address: SocketAddr,
    data_directory: PathBuf,
    log_path: PathBuf,
    /// Kept so the folder lives as long as the server.
    _temporary_directory: TempDir,
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
        let init_output = init_data_folder(&data_directory)?;
        if !init_output.status.success() {
            bail!(
                "init failed: {}",
                String::from_utf8_lossy(&init_output.stderr)
            );
        }

        let log_path = temporary_directory.path().join("server.log");
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
