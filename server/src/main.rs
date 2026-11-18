//! `haotrannas-server`: the backup daemon that runs on the NAS.
//!
//! Layers (each talks only to the one below): listener → session → handlers
//! → chunk store + catalog. Background jobs: scrub and cleanup.
//!
//! M0: `init` makes a data folder; `run --dev-plain` serves Hello and Ping
//! over plain TCP on loopback. M1/M2: uploads (`FileOffer`, `ChunkData`, `Commit`)
//! and the offline `restore`. TLS (`run` without `--dev-plain`) is M3.

mod admin;
// Storage pieces used by `init`, dev mode and uploads now; the rest of their
// API is wired in by M3 (pairing, TLS), M5 (browse) and M6 (cleanup).
#[allow(dead_code, reason = "full API wired in by M3/M5/M6")]
mod catalog;
#[allow(dead_code, reason = "sweep_tmp is wired in by the cleanup job (M6)")]
mod chunk_store;
#[allow(dead_code, reason = "pairing_networks check wired in by M3")]
mod config;
mod data_folder;
mod handlers;
mod jobs;
mod listener;
mod mdns;
mod pairing;
mod restore;
mod session;
#[allow(dead_code, reason = "TLS config and device certs wired in by M3")]
mod tls_identity;

use std::io::Write;
use std::net::SocketAddr;
use std::path::{Path, PathBuf};
use std::process::ExitCode;
use std::sync::Arc;
use std::time::Duration;

use anyhow::{Context, bail};
use clap::{Args, Parser, Subcommand};
use haotrannas_core::limits::{HANDSHAKE_TIMEOUT_MS, IDLE_TIMEOUT_MS, MAX_NAME_BYTES};
use tokio::net::TcpListener;
use tokio::signal::unix::{SignalKind, signal};
use tokio::sync::watch;

use crate::admin::AdminSocket;
use crate::config::ServerConfig;
use crate::data_folder::{DEV_DEVICE_ID, DataFolder};
use crate::handlers::hello::ServerIdentity;
use crate::listener::{ConnectionLimit, is_dev_plain_address_allowed, serve_dev_plain};
use crate::restore::{RestoreRequest, restore_file};
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
    /// Copy one backed-up file out of the store (offline).
    Restore(RestoreArgs),
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

#[derive(Debug, Args)]
struct RestoreArgs {
    #[command(flatten)]
    config: ConfigArgs,
    /// Device whose backup to read (dev mode is device 1).
    #[arg(long, default_value_t = DEV_DEVICE_ID)]
    device_id: u64,
    /// Backup path of the file, as it was uploaded.
    #[arg(long)]
    path: String,
    /// Version to restore; the latest when left out.
    #[arg(long)]
    version_id: Option<u64>,
    /// File to write.
    #[arg(long)]
    output: PathBuf,
    /// Replace the output file if it exists.
    #[arg(long)]
    force: bool,
}

impl Command {
    /// The name typed on the command line.
    fn name(&self) -> &'static str {
        match self {
            Self::Init(_) => "init",
            Self::Run(_) => "run",
            Self::Pair => "pair",
            Self::Devices => "devices",
            Self::Restore(_) => "restore",
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
        Command::Restore(args) => run_restore(&args),
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

/// `restore`: copy one file version out of the store.
fn run_restore(args: &RestoreArgs) -> anyhow::Result<ExitCode> {
    let config = load_config(&args.config)?;
    let data_folder = DataFolder::new(config.data_directory);
    let request = RestoreRequest {
        device_id: args.device_id,
        path: args.path.clone(),
        version_id: args.version_id,
        output_path: args.output.clone(),
        is_overwrite_allowed: args.force,
    };
    let summary = restore_file(&data_folder, &request)?;
    println!("{}", summary.line());
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
    let (upload_storage, catalog_writer_thread) = data_folder.open_upload_storage()?;
    let settings = SessionSettings {
        server_identity: ServerIdentity::new(config.server_name.clone()),
        handshake_timeout_ms: args.handshake_timeout_ms.unwrap_or(HANDSHAKE_TIMEOUT_MS),
        idle_timeout_ms: IDLE_TIMEOUT_MS,
        upload_storage,
    };

    let runtime = tokio::runtime::Builder::new_multi_thread()
        .enable_all()
        .build()
        .context("cannot start the async runtime")?;
    let serve_outcome = runtime.block_on(serve_dev_plain_until_stopped(
        config.listen_address,
        data_folder.root_directory(),
        dev_device_id,
        settings,
        max_connections,
    ));
    // Drops every task (and with them every catalog writer handle); a
    // blocking chunk write still running gets the grace time to finish.
    runtime.shutdown_timeout(Duration::from_millis(SHUTDOWN_GRACE_MS));
    serve_outcome?;
    // The writer thread ends once its last handle is gone; a pending write
    // finishes first.
    if catalog_writer_thread.join().is_err() {
        bail!("the catalog writer thread panicked");
    }
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
