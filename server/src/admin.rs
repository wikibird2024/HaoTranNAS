//! Admin socket `<data_dir>/admin.sock` (decision D-023): a local Unix
//! socket, mode 0600, for commands a background service cannot take on its
//! command line. `haotrannas-server pair` and `devices` are its clients.
//!
//! Line protocol: one command per line. Every reply is one line, except
//! `devices` (one line per device, then `ok <n> devices`).
//!
//! | Command | Reply |
//! |---|---|
//! | `status` | `ok <n> connections` |
//! | `pair` | `code <6 digits> server-id <XXXX-XXXX-XXXX> valid <s> s` (TLS mode only) |
//! | `devices` | `<id> <name> paired <ms> [revoked <ms>]` per device, then `ok <n> devices` |
//! | `revoke <id>` | `ok revoked device <id>` |
//! | anything else, or a failure | `error <text>` |
//!
//! The pairing code goes to the admin only; it is never logged.

use std::fs::{self, Permissions};
use std::io::{self, BufRead, Write};
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::{SystemTime, UNIX_EPOCH};

use tokio::io::{AsyncBufReadExt, AsyncReadExt, AsyncWriteExt, BufReader};
use tokio::net::{UnixListener, UnixStream};
use tokio::sync::watch;

use crate::catalog::reader::{CatalogReader, DeviceRecord};
use crate::catalog::writer::{CatalogWriter, RevokeOutcome};
use crate::listener::ConnectionLimit;
use crate::pairing::PairingService;

/// Socket file name inside the data folder.
pub const ADMIN_SOCKET_FILE_NAME: &str = "admin.sock";

/// Owner only: the socket hands out pairing codes.
const ADMIN_SOCKET_MODE: u32 = 0o600;

/// Size of `sun_path` on Linux; the path and its NUL must fit.
const MAX_SOCKET_PATH_BYTES: usize = 108;

/// Longest command line read; a longer one ends the admin connection.
const MAX_COMMAND_LINE_BYTES: u64 = 1024;

/// Why the admin socket could not be opened.
#[derive(Debug, thiserror::Error)]
pub enum AdminSocketError {
    #[error(
        "{0} answers: another server is already running on this data folder (or remove the file if not)"
    )]
    InUse(PathBuf),
    #[error(
        "admin socket path {0} is {1} bytes; Unix socket paths must be shorter than \
         {MAX_SOCKET_PATH_BYTES} bytes, so use a shorter data folder path"
    )]
    PathTooLong(PathBuf, usize),
    /// The source error is shown by the caller's error chain (`{:#}`).
    #[error("admin socket {path}")]
    Io {
        path: PathBuf,
        #[source]
        source: io::Error,
    },
}

/// What the admin commands work on.
#[derive(Debug, Clone)]
pub struct AdminContext {
    pub connection_limit: ConnectionLimit,
    /// `None` in dev mode: `pair` is refused.
    pub pairing: Option<Arc<PairingService>>,
    pub catalog_reader: CatalogReader,
    pub catalog_writer: CatalogWriter,
}

/// The bound admin socket. Removes its file when dropped.
#[derive(Debug)]
pub struct AdminSocket {
    listener: UnixListener,
    socket_path: PathBuf,
}

impl AdminSocket {
    /// Binds `<data_directory>/admin.sock` with mode 0600. A stale file from
    /// a crashed server is removed; a socket that still answers means
    /// another server runs on this folder, which is refused.
    pub fn bind(data_directory: &Path) -> Result<Self, AdminSocketError> {
        let socket_path = admin_socket_path(data_directory)?;
        let io_error = |source| AdminSocketError::Io {
            path: socket_path.clone(),
            source,
        };
        if fs::symlink_metadata(&socket_path).is_ok() {
            if std::os::unix::net::UnixStream::connect(&socket_path).is_ok() {
                return Err(AdminSocketError::InUse(socket_path));
            }
            fs::remove_file(&socket_path).map_err(io_error)?;
        }
        let listener = UnixListener::bind(&socket_path).map_err(io_error)?;
        fs::set_permissions(&socket_path, Permissions::from_mode(ADMIN_SOCKET_MODE))
            .map_err(io_error)?;
        Ok(Self {
            listener,
            socket_path,
        })
    }

    /// Serves admin connections until `shutdown` turns true.
    pub async fn serve(self, context: AdminContext, mut shutdown: watch::Receiver<bool>) {
        loop {
            let accepted = tokio::select! {
                biased;
                _ = shutdown.wait_for(|is_stopping| *is_stopping) => break,
                accepted = self.listener.accept() => accepted,
            };
            match accepted {
                Ok((stream, _)) => {
                    let context = context.clone();
                    tokio::spawn(async move {
                        if let Err(error) = serve_admin_connection(stream, &context).await {
                            tracing::debug!(%error, "admin connection ended with an error");
                        }
                    });
                }
                Err(error) => tracing::warn!(%error, "admin accept failed"),
            }
        }
    }
}

impl Drop for AdminSocket {
    fn drop(&mut self) {
        let _ = fs::remove_file(&self.socket_path);
    }
}

/// `<data_directory>/admin.sock`, checked to fit in a Unix socket address.
fn admin_socket_path(data_directory: &Path) -> Result<PathBuf, AdminSocketError> {
    let socket_path = data_directory.join(ADMIN_SOCKET_FILE_NAME);
    let path_bytes = socket_path.as_os_str().len();
    if path_bytes >= MAX_SOCKET_PATH_BYTES {
        return Err(AdminSocketError::PathTooLong(socket_path, path_bytes));
    }
    Ok(socket_path)
}

/// Answers command lines until the client hangs up.
async fn serve_admin_connection(stream: UnixStream, context: &AdminContext) -> io::Result<()> {
    let (read_half, mut write_half) = stream.into_split();
    let mut reader = BufReader::new(read_half);
    let mut line = String::new();
    loop {
        line.clear();
        let read_bytes = (&mut reader)
            .take(MAX_COMMAND_LINE_BYTES)
            .read_line(&mut line)
            .await?;
        if read_bytes == 0 {
            return Ok(());
        }
        if !line.ends_with('\n')
            && u64::try_from(read_bytes).unwrap_or(u64::MAX) >= MAX_COMMAND_LINE_BYTES
        {
            write_half
                .write_all(b"error command line too long\n")
                .await?;
            return Ok(());
        }
        let reply = answer_command(line.trim(), context).await;
        write_half.write_all(reply.as_bytes()).await?;
        write_half.write_all(b"\n").await?;
    }
}

/// The reply (without the final newline) for one command.
async fn answer_command(command: &str, context: &AdminContext) -> String {
    let mut words = command.split_whitespace();
    match (words.next(), words.next(), words.next()) {
        (Some("status"), None, None) => format!(
            "ok {} connections",
            context.connection_limit.open_connections()
        ),
        (Some("pair"), None, None) => match &context.pairing {
            Some(pairing) => {
                let opened = pairing.open_window();
                format!(
                    "code {} server-id {} valid {} s",
                    opened.code,
                    opened.server_short_id,
                    opened.valid_ms.div_ceil(1000)
                )
            }
            None => "error pairing needs TLS mode (run without --dev-plain)".to_owned(),
        },
        (Some("devices"), None, None) => list_devices(&context.catalog_reader).await,
        (Some("revoke"), Some(device_id_text), None) => {
            revoke_device(&context.catalog_writer, device_id_text).await
        }
        _ => format!("error unknown command: {command}"),
    }
}

/// The `devices` reply.
async fn list_devices(catalog_reader: &CatalogReader) -> String {
    let catalog_reader = catalog_reader.clone();
    match tokio::task::spawn_blocking(move || catalog_reader.list_devices()).await {
        Ok(Ok(devices)) => {
            let mut lines: Vec<String> = devices.iter().map(device_line).collect();
            lines.push(format!("ok {} devices", devices.len()));
            lines.join("\n")
        }
        Ok(Err(error)) => format!("error cannot read the devices: {error}"),
        Err(join_error) => format!("error device listing failed: {join_error}"),
    }
}

/// `<id> <name> paired <ms> [revoked <ms>]`. The name comes from the device,
/// so control characters (a newline would fake a reply line) become `?`.
fn device_line(device: &DeviceRecord) -> String {
    let safe_name: String = device
        .name
        .chars()
        .map(|character| {
            if character.is_control() {
                '?'
            } else {
                character
            }
        })
        .collect();
    let revoked_text = device
        .revoked_at_ms
        .map_or_else(String::new, |revoked_at_ms| {
            format!(" revoked {revoked_at_ms}")
        });
    format!(
        "{} {safe_name} paired {}{revoked_text}",
        device.device_id, device.paired_at_ms
    )
}

/// The `revoke <id>` reply.
async fn revoke_device(catalog_writer: &CatalogWriter, device_id_text: &str) -> String {
    let Ok(device_id) = device_id_text.parse::<u64>() else {
        return format!("error bad device id: {device_id_text}");
    };
    match catalog_writer
        .revoke_device(device_id, unix_time_ms())
        .await
    {
        Ok(RevokeOutcome::Revoked) => {
            tracing::info!(device_id, "device revoked; its backups stay");
            format!("ok revoked device {device_id}")
        }
        Ok(RevokeOutcome::AlreadyRevoked { revoked_at_ms }) => {
            format!("error device {device_id} was already revoked at {revoked_at_ms}")
        }
        Ok(RevokeOutcome::NoSuchDevice) => format!("error no device {device_id}"),
        Err(error) => format!("error cannot revoke: {error}"),
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

/// Client side (`haotrannas-server pair` / `devices`): sends one command to
/// the running server on `data_directory` and returns the reply lines.
pub fn send_admin_command(data_directory: &Path, command: &str) -> anyhow::Result<Vec<String>> {
    use anyhow::Context;

    let socket_path = admin_socket_path(data_directory)?;
    let mut stream = std::os::unix::net::UnixStream::connect(&socket_path).with_context(|| {
        format!(
            "no running server answers on {} (start `haotrannas-server run --data-dir {}` first)",
            socket_path.display(),
            data_directory.display()
        )
    })?;
    writeln!(stream, "{command}").context("cannot send the admin command")?;
    // End of input: the server answers, sees the end and closes.
    stream
        .shutdown(std::net::Shutdown::Write)
        .context("cannot send the admin command")?;
    let lines = io::BufReader::new(stream)
        .lines()
        .collect::<Result<Vec<_>, _>>()
        .context("cannot read the admin reply")?;
    if let Some(error_text) = lines.last().and_then(|line| line.strip_prefix("error ")) {
        anyhow::bail!("server says: {error_text}");
    }
    if lines.is_empty() {
        anyhow::bail!("the server closed the admin connection without a reply");
    }
    Ok(lines)
}

#[cfg(test)]
mod tests {
    use std::os::unix::fs::FileTypeExt;

    use haotrannas_core::limits::PAIRING_CODE_TTL_MS;
    use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};

    use super::*;
    use crate::config::ServerConfig;
    use crate::tls_identity::TlsIdentity;

    struct TestAdmin {
        _folder: tempfile::TempDir,
        context: AdminContext,
    }

    fn test_admin(has_pairing: bool) -> TestAdmin {
        let folder = tempfile::tempdir().unwrap();
        let database_path = folder.path().join("index.sqlite");
        let (catalog_writer, _thread) = CatalogWriter::start(&database_path).unwrap();
        let pairing = has_pairing.then(|| {
            let identity = Arc::new(TlsIdentity::create(&folder.path().join("tls")).unwrap());
            Arc::new(PairingService::new(
                identity,
                ServerConfig::default(),
                PAIRING_CODE_TTL_MS,
            ))
        });
        TestAdmin {
            context: AdminContext {
                connection_limit: ConnectionLimit::new(4),
                pairing,
                catalog_reader: CatalogReader::new(&database_path),
                catalog_writer,
            },
            _folder: folder,
        }
    }

    #[tokio::test]
    async fn commands_get_their_reply() {
        let admin = test_admin(false);
        let context = &admin.context;
        assert_eq!(answer_command("status", context).await, "ok 0 connections");
        assert_eq!(
            answer_command("reboot", context).await,
            "error unknown command: reboot"
        );
        assert!(
            answer_command("pair", context)
                .await
                .starts_with("error pairing needs TLS")
        );
        assert_eq!(answer_command("devices", context).await, "ok 0 devices");
        assert_eq!(
            answer_command("revoke x", context).await,
            "error bad device id: x"
        );
        assert_eq!(
            answer_command("revoke 9", context).await,
            "error no device 9"
        );
    }

    #[tokio::test]
    async fn pair_devices_and_revoke() {
        let admin = test_admin(true);
        let context = &admin.context;
        let reply = answer_command("pair", context).await;
        let words: Vec<&str> = reply.split(' ').collect();
        assert_eq!(words.len(), 7, "{reply}");
        assert_eq!(
            (words[0], words[2], words[4], words[6]),
            ("code", "server-id", "valid", "s")
        );
        assert_eq!(words[1].len(), 6);
        assert_eq!(words[3].len(), "3F9A-C21B-77E0".len());
        assert_eq!(words[5], "120");

        let device_id = context
            .catalog_writer
            .add_device("Pixel\n8".to_owned(), [3; 32], 77)
            .await
            .unwrap();
        assert_eq!(
            answer_command("devices", context).await,
            format!("{device_id} Pixel?8 paired 77\nok 1 devices")
        );
        assert_eq!(
            answer_command(&format!("revoke {device_id}"), context).await,
            format!("ok revoked device {device_id}")
        );
        let listing = answer_command("devices", context).await;
        assert!(
            listing.starts_with(&format!("{device_id} Pixel?8 paired 77 revoked ")),
            "{listing}"
        );
        assert!(
            answer_command(&format!("revoke {device_id}"), context)
                .await
                .contains("already revoked")
        );
    }

    #[tokio::test]
    async fn socket_answers_status_and_is_owner_only() {
        let admin = test_admin(false);
        let data_directory = tempfile::tempdir().unwrap();
        let socket = AdminSocket::bind(data_directory.path()).unwrap();
        let socket_path = data_directory.path().join(ADMIN_SOCKET_FILE_NAME);
        let metadata = fs::metadata(&socket_path).unwrap();
        assert!(metadata.file_type().is_socket());
        assert_eq!(metadata.permissions().mode() & 0o777, 0o600);

        let (shutdown_sender, shutdown_receiver) = watch::channel(false);
        let server = tokio::spawn(socket.serve(admin.context.clone(), shutdown_receiver));

        let stream = UnixStream::connect(&socket_path).await.unwrap();
        let (read_half, mut write_half) = stream.into_split();
        let mut lines = BufReader::new(read_half).lines();
        write_half.write_all(b"status\nnope\n").await.unwrap();
        assert_eq!(
            lines.next_line().await.unwrap().unwrap(),
            "ok 0 connections"
        );
        assert_eq!(
            lines.next_line().await.unwrap().unwrap(),
            "error unknown command: nope"
        );

        // The blocking client used by `haotrannas-server devices`.
        let client_directory = data_directory.path().to_owned();
        let reply =
            tokio::task::spawn_blocking(move || send_admin_command(&client_directory, "devices"))
                .await
                .unwrap()
                .unwrap();
        assert_eq!(reply, vec!["ok 0 devices".to_owned()]);

        // A second server on the same folder is refused while this one runs.
        assert!(matches!(
            AdminSocket::bind(data_directory.path()),
            Err(AdminSocketError::InUse(_))
        ));

        shutdown_sender.send(true).unwrap();
        server.await.unwrap();
        assert!(!socket_path.exists(), "socket file removed on stop");
        // No server: the client says so.
        let message = send_admin_command(data_directory.path(), "status")
            .unwrap_err()
            .to_string();
        assert!(message.contains("no running server"), "{message}");
    }

    #[tokio::test]
    async fn stale_socket_file_is_replaced() {
        let data_directory = tempfile::tempdir().unwrap();
        let socket_path = data_directory.path().join(ADMIN_SOCKET_FILE_NAME);
        // A socket file nobody listens on, as a crashed server leaves it.
        drop(std::os::unix::net::UnixListener::bind(&socket_path).unwrap());
        assert!(socket_path.exists());
        let socket = AdminSocket::bind(data_directory.path()).unwrap();
        assert!(socket_path.exists());
        drop(socket);
        assert!(!socket_path.exists());
    }
}
