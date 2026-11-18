//! `haotrannas-server`: the backup daemon that runs on the NAS.
//!
//! Layers (each talks only to the one below): listener → session → handlers
//! → chunk store + catalog. Background jobs: scrub and cleanup.
//!
//! M0: `init` makes a data folder; `run --dev-plain` serves Hello and Ping
//! over plain TCP on loopback. TLS (`run` without `--dev-plain`) is M3.

mod admin;
// Storage pieces used by `init` and dev mode now; the rest of their API is
// wired in by M1 (upload) and M3 (pairing, TLS).
#[allow(dead_code, reason = "full API wired in by M1/M3")]
mod catalog;
#[allow(dead_code, reason = "full API wired in by M1")]
mod chunk_store;
#[allow(dead_code, reason = "pairing_networks check wired in by M3")]
mod config;
mod data_folder;
mod handlers;
mod jobs;
mod listener;
mod mdns;
mod pairing;
mod session;
#[allow(dead_code, reason = "TLS config and device certs wired in by M3")]
mod tls_identity;

use std::io::Write;
use std::net::SocketAddr;
use std::path::{Path, PathBuf};
use std::process::ExitCode;
use std::sync::Arc;

use anyhow::{Context, bail};
use clap::{Args, Parser, Subcommand};
use haotrannas_core::limits::{HANDSHAKE_TIMEOUT_MS, IDLE_TIMEOUT_MS, MAX_NAME_BYTES};
use tokio::net::TcpListener;
use tokio::signal::unix::{SignalKind, signal};
use tokio::sync::watch;

use crate::admin::AdminSocket;
use crate::config::ServerConfig;
use crate::data_folder::DataFolder;
use crate::handlers::hello::ServerIdentity;
use crate::listener::{ConnectionLimit, is_dev_plain_address_allowed, serve_dev_plain};
use crate::session::SessionSettings;

/// Exit code for a failure (bad config, folder not initialized, bind failed).
const FAILURE_EXIT_CODE: u8 = 1;
/// Exit code for a command or mode that exists but does nothing yet.
const NOT_IMPLEMENTED_EXIT_CODE: u8 = 2;
/// Time the sessions get to send `Close SERVER_SHUTDOWN` and end.
const SHUTDOWN_GRACE_MS: u64 = 2_000;

/// HaoTranNAS backup server.
#[derive(Debug, Parser)]
#[command(name = "haotrannas-server", version, author = "Hao Tran")]
struct Cli {
    #[command(subcommand)]
    command: Command,
}

#[derive(Debug, Subcommand)]
enum Command {
    /// Create the data folder, database and server TLS identity.
    Init(InitArgs),
    /// Start serving clients.
    Run(RunArgs),
    /// Print a one-time pairing code for a new device.
    Pair,
    /// List or remove paired devices.
    Devices,
    /// Copy backed-up files out of the store.
    Restore,
    /// Re-hash every stored chunk now and report bad ones.
    ScrubNow,
}

/// Where the settings come from: the config file, then flags on top.
#[derive(Debug, Args)]
struct ConfigArgs {
    /// Config file (TOML). A missing file gives the defaults; without this
    /// flag the built-in defaults are used.
    #[arg(long)]
    config: Option<PathBuf>,
    /// Data folder; overrides `data_directory` from the config.
    #[arg(long)]
    data_dir: Option<PathBuf>,
}

#[derive(Debug, Args)]
struct InitArgs {
    #[command(flatten)]
    config: ConfigArgs,
}

#[derive(Debug, Args)]
struct RunArgs {
    #[command(flatten)]
    config: ConfigArgs,
    /// Address and port to listen on; overrides `listen_address`. Port 0
    /// picks a free port (printed on stdout).
    #[arg(long)]
    listen: Option<SocketAddr>,
    /// Plain TCP without TLS, loopback only, every connection is device 1
    /// ("dev"). For tests up to M2; never on a network.
    #[arg(long)]
    dev_plain: bool,
    /// Test only, `--dev-plain` only: handshake timeout instead of 10 000 ms.
    #[arg(long, hide = true)]
    handshake_timeout_ms: Option<u64>,
}

impl Command {
    /// The name typed on the command line.
    fn name(&self) -> &'static str {
        match self {
            Self::Init(_) => "init",
            Self::Run(_) => "run",
            Self::Pair => "pair",
            Self::Devices => "devices",
            Self::Restore => "restore",
            Self::ScrubNow => "scrub-now",
        }
    }
}

fn main() -> ExitCode {
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| tracing_subscriber::EnvFilter::new("info")),
        )
        .with_writer(std::io::stderr)
        .init();

    let cli = Cli::parse();
    let outcome = match cli.command {
        Command::Init(args) => run_init(&args),
        Command::Run(args) => run_server(&args),
        other => {
            eprintln!("haotrannas-server {}: not implemented yet", other.name());
            Ok(ExitCode::from(NOT_IMPLEMENTED_EXIT_CODE))
        }
    };
    outcome.unwrap_or_else(|error| {
        eprintln!("haotrannas-server: {error:#}");
        ExitCode::from(FAILURE_EXIT_CODE)
    })
}

/// The config file (or defaults) with the flags applied.
fn load_config(config_args: &ConfigArgs) -> anyhow::Result<ServerConfig> {
    let mut config = match &config_args.config {
        Some(path) => ServerConfig::load(path)?,
        None => ServerConfig::default(),
    };
    if let Some(data_directory) = &config_args.data_dir {
        config.data_directory.clone_from(data_directory);
    }
    Ok(config)
}

/// `init`: make the data folder.
fn run_init(args: &InitArgs) -> anyhow::Result<ExitCode> {
    let config = load_config(&args.config)?;
    let data_folder = DataFolder::new(config.data_directory);
    let short_id = data_folder.initialize()?;
    println!(
        "initialized {}; server id {short_id}",
        data_folder.root_directory().display()
    );
    Ok(ExitCode::SUCCESS)
}

/// `run`: serve until SIGINT / SIGTERM.
fn run_server(args: &RunArgs) -> anyhow::Result<ExitCode> {
    if !args.dev_plain {
        if args.handshake_timeout_ms.is_some() {
            bail!("--handshake-timeout-ms is a test flag for --dev-plain only");
        }
        eprintln!("haotrannas-server run: TLS mode arrives in M3; use --dev-plain");
        return Ok(ExitCode::from(NOT_IMPLEMENTED_EXIT_CODE));
    }
    let mut config = load_config(&args.config)?;
    if let Some(listen_address) = args.listen {
        config.listen_address = listen_address;
    }
    if !is_dev_plain_address_allowed(&config.listen_address) {
        bail!(
            "--dev-plain is plain TCP without encryption, so it listens on loopback only \
             (protocol/spec.md section 1), not {}. Use --listen 127.0.0.1:<port>",
            config.listen_address
        );
    }
    if config.server_name.len() > MAX_NAME_BYTES {
        bail!("config: server_name is longer than {MAX_NAME_BYTES} bytes");
    }
    let max_connections =
        usize::try_from(config.max_connections).context("max_connections is too large")?;

    let data_folder = DataFolder::new(config.data_directory.clone());
    if !data_folder.is_initialized() {
        bail!(
            "{} is not initialized; run `haotrannas-server init --data-dir {}` first",
            data_folder.root_directory().display(),
            data_folder.root_directory().display()
        );
    }
    let dev_device_id = data_folder.ensure_dev_device()?;
    let settings = SessionSettings {
        server_identity: ServerIdentity::new(config.server_name.clone()),
        handshake_timeout_ms: args.handshake_timeout_ms.unwrap_or(HANDSHAKE_TIMEOUT_MS),
        idle_timeout_ms: IDLE_TIMEOUT_MS,
    };

    let runtime = tokio::runtime::Builder::new_multi_thread()
        .enable_all()
        .build()
        .context("cannot start the async runtime")?;
    runtime.block_on(serve_dev_plain_until_stopped(
        config.listen_address,
        data_folder.root_directory(),
        dev_device_id,
        settings,
        max_connections,
    ))?;
    Ok(ExitCode::SUCCESS)
}

/// Binds, prints `listening on <ip>:<port>`, serves, and stops cleanly on
/// SIGINT / SIGTERM.
async fn serve_dev_plain_until_stopped(
    listen_address: SocketAddr,
    data_directory: &Path,
    dev_device_id: u64,
    settings: SessionSettings,
    max_connections: usize,
) -> anyhow::Result<()> {
    // Signal handlers first, so a stop right after start is still clean.
    let mut interrupt = signal(SignalKind::interrupt()).context("cannot watch SIGINT")?;
    let mut terminate = signal(SignalKind::terminate()).context("cannot watch SIGTERM")?;

    let listener = TcpListener::bind(listen_address)
        .await
        .with_context(|| format!("cannot listen on {listen_address}"))?;
    let bound_address = listener.local_addr()?;
    let admin_socket = AdminSocket::bind(data_directory)?;

    tracing::warn!(
        "dev-plain mode: plain TCP without encryption; every connection is device {dev_device_id} (dev)"
    );
    // The one stdout line tests and scripts wait for.
    let mut stdout = std::io::stdout().lock();
    writeln!(stdout, "listening on {bound_address}")?;
    stdout.flush()?;
    drop(stdout);

    let (shutdown_sender, shutdown_receiver) = watch::channel(false);
    let connection_limit = ConnectionLimit::new(max_connections);
    let admin_task =
        tokio::spawn(admin_socket.serve(connection_limit.clone(), shutdown_receiver.clone()));
    let listener_task = tokio::spawn(serve_dev_plain(
        listener,
        dev_device_id,
        Arc::new(settings),
        connection_limit,
        shutdown_receiver,
        SHUTDOWN_GRACE_MS,
    ));

    tokio::select! {
        _ = interrupt.recv() => tracing::info!("SIGINT: stopping"),
        _ = terminate.recv() => tracing::info!("SIGTERM: stopping"),
    }
    shutdown_sender.send_replace(true);
    listener_task.await.context("listener task failed")?;
    admin_task.await.context("admin task failed")?;
    tracing::info!("stopped");
    Ok(())
}
