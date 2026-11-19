//! `haotrannas-cli`: command-line client that talks to the server without a
//! phone. Used by the e2e tests and for scripting.
//!
//! M0: `ping --dev-plain` over plain TCP. M1/M2: `upload --dev-plain`. M3:
//! `pair`, and `ping` / `upload` over mutual TLS with the saved identity.

mod connection;
mod identity;
mod pair;
mod ping;
mod upload;

use std::path::{Path, PathBuf};
use std::process::ExitCode;

use clap::{Args, Parser, Subcommand};

use crate::connection::Transport;

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

    /// Folder holding this client's TLS identity and the pinned server
    /// fingerprint. Default: `$XDG_CONFIG_HOME/haotrannas` or `~/.config/haotrannas`.
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
    Pair(PairArgs),
    /// Back up one file.
    Upload(UploadArgs),
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

#[derive(Debug, Args)]
struct PairArgs {
    /// The 6-digit code from `haotrannas-server pair`.
    #[arg(long)]
    code: String,
    /// The server id printed with the code (`XXXX-XXXX-XXXX`); pairing stops
    /// if the server shows another one.
    #[arg(long, value_name = "SERVER_ID")]
    expect_server_id: Option<String>,
    /// Name the server stores for this device.
    #[arg(long, default_value = "haotrannas-cli")]
    device_name: String,
}

#[derive(Debug, Args)]
struct UploadArgs {
    /// Local file to back up.
    file: PathBuf,
    /// Backup path on the server; the file name when left out.
    #[arg(long = "as", value_name = "REMOTE_PATH")]
    remote_path: Option<String>,
    /// Test: stop after N chunks without Commit (a dropped connection).
    #[arg(long, value_name = "N")]
    stop_after_chunks: Option<u32>,
    /// Test: send `Commit` and disconnect without reading `CommitOk` (a lost reply).
    #[arg(long, conflicts_with = "stop_after_chunks")]
    drop_after_commit: bool,
    /// Plain TCP without TLS, for a server started with `run --dev-plain`.
    #[arg(long)]
    dev_plain: bool,
}

impl Command {
    /// The name typed on the command line.
    fn name(&self) -> &'static str {
        match self {
            Self::Ping(_) => "ping",
            Self::Pair(_) => "pair",
            Self::Upload(_) => "upload",
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
        Command::Ping(ping_args) => run_ping_command(&cli, ping_args),
        Command::Upload(upload_args) => run_upload_command(&cli, upload_args),
        Command::Pair(pair_args) => run_pair_command(&cli, pair_args),
        other => {
            eprintln!("haotrannas-cli {}: not implemented yet", other.name());
            ExitCode::from(NOT_IMPLEMENTED_EXIT_CODE)
        }
    }
}

/// Where and how `ping` / `upload` connect: `--dev-plain` needs `--server`;
/// otherwise the saved pairing gives the pin, the certificate and (without
/// `--server`) the last address. `Err` is the exit code after printing why.
fn connection_target(
    cli: &Cli,
    command_name: &str,
    is_dev_plain: bool,
) -> Result<(String, Transport), ExitCode> {
    if is_dev_plain {
        let Some(server_address) = &cli.server else {
            eprintln!("haotrannas-cli {command_name}: give --server <host:port> with --dev-plain");
            return Err(ExitCode::from(NOT_IMPLEMENTED_EXIT_CODE));
        };
        return Ok((server_address.clone(), Transport::DevPlain));
    }
    let identity_directory = identity_directory(cli, command_name)?;
    let paired = match identity::load(&identity_directory) {
        Ok(Some(paired)) => paired,
        Ok(None) => {
            eprintln!(
                "haotrannas-cli {command_name}: not paired: run `haotrannas-cli pair` first \
                 (no pairing in {})",
                identity_directory.display()
            );
            return Err(ExitCode::from(FAILURE_EXIT_CODE));
        }
        Err(error) => {
            eprintln!("haotrannas-cli {command_name}: {error:#}");
            return Err(ExitCode::from(FAILURE_EXIT_CODE));
        }
    };
    let server_address = cli
        .server
        .clone()
        .unwrap_or_else(|| paired.last_address.clone());
    let transport = Transport::Paired {
        server_fingerprint: paired.server_fingerprint,
        client_identity: paired.client_identity,
    };
    Ok((server_address, transport))
}

/// `--identity-dir`, or the default config folder.
fn identity_directory(cli: &Cli, command_name: &str) -> Result<PathBuf, ExitCode> {
    cli.identity_dir
        .clone()
        .or_else(identity::default_identity_directory)
        .ok_or_else(|| {
            eprintln!(
                "haotrannas-cli {command_name}: cannot find a config folder ($XDG_CONFIG_HOME, \
                 $HOME); give --identity-dir <dir>"
            );
            ExitCode::from(FAILURE_EXIT_CODE)
        })
}

/// `ping`: checks the flags, runs it, maps the outcome to an exit code.
fn run_ping_command(cli: &Cli, ping_args: &PingArgs) -> ExitCode {
    let (server_address, transport) = match connection_target(cli, "ping", ping_args.dev_plain) {
        Ok(target) => target,
        Err(exit_code) => return exit_code,
    };
    let Some(runtime) = start_runtime() else {
        return ExitCode::from(FAILURE_EXIT_CODE);
    };
    match runtime.block_on(ping::run_ping(&server_address, &transport, ping_args.count)) {
        Ok(()) => ExitCode::SUCCESS,
        Err(error) => {
            eprintln!("haotrannas-cli ping: {error}");
            ExitCode::from(FAILURE_EXIT_CODE)
        }
    }
}

/// `upload`: checks the flags, runs it, prints one summary line.
fn run_upload_command(cli: &Cli, upload_args: &UploadArgs) -> ExitCode {
    let (server_address, transport) = match connection_target(cli, "upload", upload_args.dev_plain)
    {
        Ok(target) => target,
        Err(exit_code) => return exit_code,
    };
    let Some(runtime) = start_runtime() else {
        return ExitCode::from(FAILURE_EXIT_CODE);
    };
    let request = upload::UploadRequest {
        file_path: upload_args.file.clone(),
        remote_path: upload_args.remote_path.clone(),
        stop_after_chunks: upload_args.stop_after_chunks,
        is_drop_after_commit: upload_args.drop_after_commit,
    };
    match runtime.block_on(upload::run_upload(&server_address, &transport, &request)) {
        Ok(outcome) => {
            println!("{}", outcome.summary_line());
            ExitCode::SUCCESS
        }
        Err(error) => {
            eprintln!("haotrannas-cli upload: {error:#}");
            ExitCode::from(FAILURE_EXIT_CODE)
        }
    }
}

/// `pair`: pairs and saves the identity; prints one line.
fn run_pair_command(cli: &Cli, pair_args: &PairArgs) -> ExitCode {
    let Some(server_address) = &cli.server else {
        eprintln!("haotrannas-cli pair: give --server <host:port>");
        return ExitCode::from(NOT_IMPLEMENTED_EXIT_CODE);
    };
    let identity_directory = match identity_directory(cli, "pair") {
        Ok(identity_directory) => identity_directory,
        Err(exit_code) => return exit_code,
    };
    let Some(runtime) = start_runtime() else {
        return ExitCode::from(FAILURE_EXIT_CODE);
    };
    let request = pair::PairRequest {
        server_address: server_address.clone(),
        code: pair_args.code.clone(),
        expected_server_id: pair_args.expect_server_id.clone(),
        device_name: pair_args.device_name.clone(),
        identity_directory: identity_directory.clone(),
    };
    match runtime.block_on(pair::run_pair(&request)) {
        Ok(outcome) => {
            println!(
                "paired as device {} with server {}",
                outcome.device_id, outcome.server_short_id
            );
            print_identity_note(&identity_directory);
            ExitCode::SUCCESS
        }
        Err(error) => {
            eprintln!("haotrannas-cli pair: {error:#}");
            ExitCode::from(FAILURE_EXIT_CODE)
        }
    }
}

/// Where the identity went (stderr, so stdout stays one line).
fn print_identity_note(identity_directory: &Path) {
    eprintln!("identity saved in {}", identity_directory.display());
}

/// A single-thread async runtime, or `None` after printing why not.
fn start_runtime() -> Option<tokio::runtime::Runtime> {
    match tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
    {
        Ok(runtime) => Some(runtime),
        Err(error) => {
            eprintln!("haotrannas-cli: cannot start the async runtime: {error}");
            None
        }
    }
}
