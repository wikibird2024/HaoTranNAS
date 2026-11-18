//! `haotrannas-cli`: command-line client that talks to the server without a
//! phone. Used by the e2e tests and for scripting.

use std::path::PathBuf;
use std::process::ExitCode;

use clap::{Parser, Subcommand};

/// Exit code for a command that exists but does nothing yet.
const NOT_IMPLEMENTED_EXIT_CODE: u8 = 2;

/// HaoTranNAS command-line client.
#[derive(Debug, Parser)]
#[command(name = "haotrannas-cli", version, author = "Hao Tran")]
struct Cli {
    /// Server address as `host:port`. Without it, the cli looks on the LAN (mDNS).
    #[arg(long, global = true)]
    server: Option<String>,

    /// Folder holding this client's TLS identity and the pinned server fingerprint.
    #[arg(long, global = true)]
    identity_dir: Option<PathBuf>,

    #[command(subcommand)]
    command: Command,
}

#[derive(Debug, Subcommand)]
enum Command {
    /// Connect, say Hello and send one Ping.
    Ping,
    /// Pair this client with the server using the code it printed.
    Pair,
    /// Back up one file.
    Upload,
    /// Back up every file in a folder.
    UploadDir,
    /// List one folder of backed-up files.
    List,
    /// Download one backed-up file.
    Download,
    /// Find servers on the LAN via mDNS.
    Discover,
}

impl Command {
    /// The name typed on the command line.
    fn name(&self) -> &'static str {
        match self {
            Self::Ping => "ping",
            Self::Pair => "pair",
            Self::Upload => "upload",
            Self::UploadDir => "upload-dir",
            Self::List => "list",
            Self::Download => "download",
            Self::Discover => "discover",
        }
    }
}

fn main() -> ExitCode {
    tracing_subscriber::fmt()
        .with_env_filter(tracing_subscriber::EnvFilter::from_default_env())
        .with_writer(std::io::stderr)
        .init();

    let cli = Cli::parse();
    tracing::debug!(server = ?cli.server, identity_dir = ?cli.identity_dir, "parsed global flags");
    eprintln!("haotrannas-cli {}: not implemented yet", cli.command.name());
    ExitCode::from(NOT_IMPLEMENTED_EXIT_CODE)
}
