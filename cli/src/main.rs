//! `haotrannas-cli`: command-line client that talks to the server without a
//! phone. Used by the e2e tests and for scripting.
//!
//! M0: `ping --dev-plain` over plain TCP. TLS (and so every command without
//! `--dev-plain`) arrives in M3.

mod connection;
mod ping;

use std::path::PathBuf;
use std::process::ExitCode;

use clap::{Args, Parser, Subcommand};

/// Exit code when the server or connection failed.
const FAILURE_EXIT_CODE: u8 = 1;
/// Exit code for a command or mode that exists but does nothing yet.
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
    /// Connect, say Hello and send Ping, printing each round trip.
    Ping(PingArgs),
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

#[derive(Debug, Args)]
struct PingArgs {
    /// Number of pings to send.
    #[arg(long, default_value_t = 1, value_parser = clap::value_parser!(u32).range(1..))]
    count: u32,
    /// Plain TCP without TLS, for a server started with `run --dev-plain`.
    #[arg(long)]
    dev_plain: bool,
}

impl Command {
    /// The name typed on the command line.
    fn name(&self) -> &'static str {
        match self {
            Self::Ping(_) => "ping",
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
    match &cli.command {
        Command::Ping(ping_args) => run_ping_command(cli.server.as_deref(), ping_args),
        other => {
            eprintln!("haotrannas-cli {}: not implemented yet", other.name());
            ExitCode::from(NOT_IMPLEMENTED_EXIT_CODE)
        }
    }
}

/// `ping`: checks the flags, runs it, maps the outcome to an exit code.
fn run_ping_command(server_address: Option<&str>, ping_args: &PingArgs) -> ExitCode {
    if !ping_args.dev_plain {
        eprintln!("haotrannas-cli ping: TLS arrives in M3; use --dev-plain");
        return ExitCode::from(NOT_IMPLEMENTED_EXIT_CODE);
    }
    let Some(server_address) = server_address else {
        eprintln!("haotrannas-cli ping: give --server <host:port> (LAN discovery arrives in M3)");
        return ExitCode::from(NOT_IMPLEMENTED_EXIT_CODE);
    };
    let runtime = match tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
    {
        Ok(runtime) => runtime,
        Err(error) => {
            eprintln!("haotrannas-cli: cannot start the async runtime: {error}");
            return ExitCode::from(FAILURE_EXIT_CODE);
        }
    };
    match runtime.block_on(ping::run_ping(server_address, ping_args.count)) {
        Ok(()) => ExitCode::SUCCESS,
        Err(error) => {
            eprintln!("haotrannas-cli ping: {error}");
            ExitCode::from(FAILURE_EXIT_CODE)
        }
    }
}
