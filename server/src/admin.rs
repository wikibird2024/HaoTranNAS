//! Admin socket `<data_dir>/admin.sock` (decision D-023): a local Unix
//! socket, mode 0600, for commands a background service cannot take on its
//! command line.
//!
//! Line protocol: one command per line, one reply line each.
//!
//! | Command | Reply |
//! |---|---|
//! | `status` | `ok <n> connections` |
//! | anything else | `error unknown command: <command>` |
//!
//! M0 skeleton: `pair` and `devices` come in wave 4.

use std::fs::{self, Permissions};
use std::io;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};

use tokio::io::{AsyncBufReadExt, AsyncReadExt, AsyncWriteExt, BufReader};
use tokio::net::{UnixListener, UnixStream};
use tokio::sync::watch;

use crate::listener::ConnectionLimit;

/// Socket file name inside the data folder.
pub const ADMIN_SOCKET_FILE_NAME: &str = "admin.sock";

/// Owner only: the socket hands out pairing codes later.
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
        let socket_path = data_directory.join(ADMIN_SOCKET_FILE_NAME);
        let io_error = |source| AdminSocketError::Io {
            path: socket_path.clone(),
            source,
        };
        let path_bytes = socket_path.as_os_str().len();
        if path_bytes >= MAX_SOCKET_PATH_BYTES {
            return Err(AdminSocketError::PathTooLong(socket_path, path_bytes));
        }
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
    pub async fn serve(
        self,
        connection_limit: ConnectionLimit,
        mut shutdown: watch::Receiver<bool>,
    ) {
        loop {
            let accepted = tokio::select! {
                biased;
                _ = shutdown.wait_for(|is_stopping| *is_stopping) => break,
                accepted = self.listener.accept() => accepted,
            };
            match accepted {
                Ok((stream, _)) => {
                    let connection_limit = connection_limit.clone();
                    tokio::spawn(async move {
                        if let Err(error) = serve_admin_connection(stream, &connection_limit).await
                        {
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

/// Answers command lines until the client hangs up.
async fn serve_admin_connection(
    stream: UnixStream,
    connection_limit: &ConnectionLimit,
) -> io::Result<()> {
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
        let reply = answer_command(line.trim(), connection_limit);
        write_half.write_all(reply.as_bytes()).await?;
        write_half.write_all(b"\n").await?;
    }
}

/// The reply line (without newline) for one command.
fn answer_command(command: &str, connection_limit: &ConnectionLimit) -> String {
    match command {
        "status" => format!("ok {} connections", connection_limit.open_connections()),
        other => format!("error unknown command: {other}"),
    }
}

#[cfg(test)]
mod tests {
    use std::os::unix::fs::FileTypeExt;

    use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};

    use super::*;

    #[test]
    fn commands_get_their_reply() {
        let limit = ConnectionLimit::new(4);
        assert_eq!(answer_command("status", &limit), "ok 0 connections");
        assert_eq!(
            answer_command("reboot", &limit),
            "error unknown command: reboot"
        );
    }

    #[tokio::test]
    async fn socket_answers_status_and_is_owner_only() {
        let data_directory = tempfile::tempdir().unwrap();
        let socket = AdminSocket::bind(data_directory.path()).unwrap();
        let socket_path = data_directory.path().join(ADMIN_SOCKET_FILE_NAME);
        let metadata = fs::metadata(&socket_path).unwrap();
        assert!(metadata.file_type().is_socket());
        assert_eq!(metadata.permissions().mode() & 0o777, 0o600);

        let (shutdown_sender, shutdown_receiver) = watch::channel(false);
        let server = tokio::spawn(socket.serve(ConnectionLimit::new(4), shutdown_receiver));

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

        // A second server on the same folder is refused while this one runs.
        assert!(matches!(
            AdminSocket::bind(data_directory.path()),
            Err(AdminSocketError::InUse(_))
        ));

        shutdown_sender.send(true).unwrap();
        server.await.unwrap();
        assert!(!socket_path.exists(), "socket file removed on stop");
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
