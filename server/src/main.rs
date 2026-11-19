//! `haotrannas-server`: the backup daemon that runs on the NAS.
//!
//! Layers (each talks only to the one below): listener → session → handlers
//! → chunk store + catalog. Background jobs: scrub and cleanup.
//!
//! M0: `init` makes a data folder; `run --dev-plain` serves Hello and Ping
//! over plain TCP on loopback. M1/M2: uploads (`FileOffer`, `ChunkData`, `Commit`)
//! and the offline `restore`. M3: `run` in TLS mode (mutual TLS, pairing),
//! and `pair` / `devices` talking to the running server over the admin socket.

mod admin;
// Storage pieces used by `init`, dev mode and uploads now; the rest of their
// API is wired in by M5 (browse) and M6 (cleanup).
#[allow(dead_code, reason = "full API wired in by M5/M6")]
mod catalog;
#[allow(dead_code, reason = "sweep_tmp is wired in by the cleanup job (M6)")]
mod chunk_store;
#[allow(dead_code, reason = "scrub/cleanup intervals wired in by M6")]
mod config;
mod data_folder;
mod handlers;
mod jobs;
mod listener;
mod mdns;
mod pairing;
mod restore;
mod session;
mod tls_identity;

use std::io::Write;
use std::net::SocketAddr;
use std::path::{Path, PathBuf};
use std::process::ExitCode;
use std::sync::Arc;
use std::time::Duration;

use anyhow::{Context, bail};
use clap::{Args, Parser, Subcommand};
use haotrannas_core::limits::{
    HANDSHAKE_TIMEOUT_MS, IDLE_TIMEOUT_MS, MAX_NAME_BYTES, PAIRING_CODE_TTL_MS,
};
use tokio::net::TcpListener;
use tokio::signal::unix::{SignalKind, signal};
use tokio::sync::watch;
use tokio_rustls::TlsAcceptor;

use crate::admin::{AdminContext, AdminSocket, send_admin_command};
use crate::config::ServerConfig;
use crate::data_folder::{DEV_DEVICE_ID, DataFolder};
use crate::handlers::hello::ServerIdentity;
use crate::listener::{ConnectionLimit, ConnectionMode, is_dev_plain_address_allowed, serve};
use crate::pairing::PairingService;
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
    /// Print a one-time pairing code for a new device (asks the running server).
    Pair(PairArgs),
    /// List paired devices, or revoke one (asks the running server).
    Devices(DevicesArgs),
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
    /// Test only: handshake timeout (TLS handshake + Hello) instead of 10 000 ms.
    #[arg(long, hide = true)]
    handshake_timeout_ms: Option<u64>,
    /// Test only, TLS mode: pairing code lifetime instead of 120 000 ms.
    #[arg(long, hide = true, conflicts_with = "dev_plain")]
    pairing_code_ttl_ms: Option<u64>,
}

#[derive(Debug, Args)]
struct PairArgs {
    #[command(flatten)]
    config: ConfigArgs,
}

#[derive(Debug, Args)]
struct DevicesArgs {
    #[command(flatten)]
    config: ConfigArgs,
    /// Revoke this device: its certificate is refused from now on, its
    /// backups stay restorable.
    #[arg(long, value_name = "DEVICE_ID")]
    revoke: Option<u64>,
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
            Self::Pair(_) => "pair",
            Self::Devices(_) => "devices",
            Self::Restore(_) => "restore",
            Self::ScrubNow => "scrub-now",
        }
    }
}

/// Log filter when `RUST_LOG` is not set. rustls warns once per connection
/// when a client sends an IP literal as SNI (dart:io does); rustls ignores
/// the name and so does our pin check, so only its errors are shown.
const DEFAULT_LOG_FILTER: &str = "info,rustls=error";

fn main() -> ExitCode {
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| tracing_subscriber::EnvFilter::new(DEFAULT_LOG_FILTER)),
        )
        .with_writer(std::io::stderr)
        .init();

    let cli = Cli::parse();
    let outcome = match cli.command {
        Command::Init(args) => run_init(&args),
        Command::Run(args) => run_server(&args),
        Command::Restore(args) => run_restore(&args),
        Command::Pair(args) => run_pair(&args),
        Command::Devices(args) => run_devices(&args),
        other @ Command::ScrubNow => {
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

/// `pair`: asks the running server for a pairing code.
fn run_pair(args: &PairArgs) -> anyhow::Result<ExitCode> {
    let config = load_config(&args.config)?;
    let lines = send_admin_command(&config.data_directory, "pair")?;
    let reply = lines.first().map_or("", String::as_str);
    let words: Vec<&str> = reply.split(' ').collect();
    let [
        "code",
        code,
        "server-id",
        server_id,
        "valid",
        valid_seconds,
        "s",
    ] = words.as_slice()
    else {
        bail!("unexpected reply from the server: {reply}");
    };
    println!("code {code} · server id {server_id} · valid {valid_seconds} s");
    Ok(ExitCode::SUCCESS)
}

/// `devices`: lists the devices of the running server, or revokes one.
fn run_devices(args: &DevicesArgs) -> anyhow::Result<ExitCode> {
    let config = load_config(&args.config)?;
    if let Some(device_id) = args.revoke {
        send_admin_command(&config.data_directory, &format!("revoke {device_id}"))?;
        println!("revoked device {device_id}; its backups stay restorable");
        return Ok(ExitCode::SUCCESS);
    }
    let lines = send_admin_command(&config.data_directory, "devices")?;
    // The last line is `ok <n> devices`.
    let device_lines = &lines[..lines.len() - 1];
    if device_lines.is_empty() {
        println!("no paired devices");
    }
    for line in device_lines {
        println!("{line}");
    }
    Ok(ExitCode::SUCCESS)
}

/// `run`: serve until SIGINT / SIGTERM.
fn run_server(args: &RunArgs) -> anyhow::Result<ExitCode> {
    let mut config = load_config(&args.config)?;
    if let Some(listen_address) = args.listen {
        config.listen_address = listen_address;
    }
    if args.dev_plain && !is_dev_plain_address_allowed(&config.listen_address) {
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
    // Both checks run before the catalog writer starts.
    let tls_identity = if args.dev_plain {
        None
    } else {
        Some(Arc::new(data_folder.prepare_tls_run()?))
    };
    let dev_device_id = if args.dev_plain {
        Some(data_folder.ensure_dev_device()?)
    } else {
        None
    };
    let (upload_storage, catalog_writer_thread) = data_folder.open_upload_storage()?;

    let (connection_mode, pairing) = match (&tls_identity, dev_device_id) {
        (Some(tls_identity), _) => {
            let server_config = tls_identity
                .server_config()
                .context("cannot build the TLS server config")?;
            let pairing = Arc::new(PairingService::new(
                Arc::clone(tls_identity),
                config.clone(),
                args.pairing_code_ttl_ms.unwrap_or(PAIRING_CODE_TTL_MS),
            ));
            let mode = ConnectionMode::Tls {
                acceptor: TlsAcceptor::from(server_config),
                catalog_reader: upload_storage.catalog_reader.clone(),
            };
            (mode, Some(pairing))
        }
        (None, Some(dev_device_id)) => (ConnectionMode::DevPlain { dev_device_id }, None),
        (None, None) => unreachable!("dev-plain mode always has the dev device"),
    };
    let connection_limit = ConnectionLimit::new(max_connections);
    let admin_context = AdminContext {
        connection_limit: connection_limit.clone(),
        pairing: pairing.clone(),
        catalog_reader: upload_storage.catalog_reader.clone(),
        catalog_writer: upload_storage.catalog_writer.clone(),
    };
    let settings = SessionSettings {
        server_identity: ServerIdentity::new(config.server_name.clone()),
        handshake_timeout_ms: args.handshake_timeout_ms.unwrap_or(HANDSHAKE_TIMEOUT_MS),
        idle_timeout_ms: IDLE_TIMEOUT_MS,
        upload_storage,
        pairing,
    };
    match (&tls_identity, dev_device_id) {
        (Some(tls_identity), _) => tracing::info!(
            server_id = %tls_identity.server_fingerprint().short_id(),
            "TLS mode: mutual TLS; pairing from {:?} and loopback",
            config
                .pairing_networks
                .iter()
                .map(ToString::to_string)
                .collect::<Vec<_>>()
        ),
        (None, dev_device_id) => tracing::warn!(
            "dev-plain mode: plain TCP without encryption; every connection is device {} (dev)",
            dev_device_id.unwrap_or(DEV_DEVICE_ID)
        ),
    }

    let runtime = tokio::runtime::Builder::new_multi_thread()
        .enable_all()
        .build()
        .context("cannot start the async runtime")?;
    let serve_outcome = runtime.block_on(serve_until_stopped(
        config.listen_address,
        data_folder.root_directory(),
        connection_mode,
        settings,
        admin_context,
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
async fn serve_until_stopped(
    listen_address: SocketAddr,
    data_directory: &Path,
    connection_mode: ConnectionMode,
    settings: SessionSettings,
    admin_context: AdminContext,
) -> anyhow::Result<()> {
    // Signal handlers first, so a stop right after start is still clean.
    let mut interrupt = signal(SignalKind::interrupt()).context("cannot watch SIGINT")?;
    let mut terminate = signal(SignalKind::terminate()).context("cannot watch SIGTERM")?;

    let listener = TcpListener::bind(listen_address)
        .await
        .with_context(|| format!("cannot listen on {listen_address}"))?;
    let bound_address = listener.local_addr()?;
    let admin_socket = AdminSocket::bind(data_directory)?;

    // The one stdout line tests and scripts wait for.
    let mut stdout = std::io::stdout().lock();
    writeln!(stdout, "listening on {bound_address}")?;
    stdout.flush()?;
    drop(stdout);

    let (shutdown_sender, shutdown_receiver) = watch::channel(false);
    let connection_limit = admin_context.connection_limit.clone();
    let admin_task = tokio::spawn(admin_socket.serve(admin_context, shutdown_receiver.clone()));
    let listener_task = tokio::spawn(serve(
        listener,
        Arc::new(connection_mode),
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
