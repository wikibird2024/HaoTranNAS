//! Server settings read from `config.toml` in the data folder: listen
//! address, data folder, job schedules. Defaults work without a file.

use std::net::SocketAddr;
use std::path::PathBuf;

/// Everything the server reads from `config.toml`.
#[derive(Debug, Clone)]
pub struct ServerConfig {
    /// Address and port the TLS listener binds to.
    pub listen_address: SocketAddr,
    /// Root of the store: `chunks/`, `tmp/`, `index.sqlite`, `tls/`.
    pub data_directory: PathBuf,
}
