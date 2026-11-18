//! `haotrannas-server`: the backup daemon that runs on the NAS.
//!
//! Layers (each talks only to the one below): listener → session → handlers
//! → chunk store + catalog. Background jobs: scrub and cleanup.

// Scaffold: the stub modules below are not wired into `main` yet. Remove this
// once the `run` command uses them.
#![allow(dead_code, reason = "scaffold stubs, wired in by later tasks")]

mod admin;
mod catalog;
mod chunk_store;
mod config;
mod handlers;
mod jobs;
mod listener;
mod mdns;
mod pairing;
mod session;
mod tls_identity;

use std::process::ExitCode;

use clap::{Parser, Subcommand};

/// Exit code for a command that exists but does nothing yet.
const NOT_IMPLEMENTED_EXIT_CODE: u8 = 2;

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
    Init,
    /// Start serving clients.
    Run,
    /// Print a one-time pairing code for a new device.
    Pair,
    /// List or remove paired devices.
    Devices,
    /// Copy backed-up files out of the store.
    Restore,
    /// Re-hash every stored chunk now and report bad ones.
    ScrubNow,
}

impl Command {
    /// The name typed on the command line.
    fn name(&self) -> &'static str {
        match self {
            Self::Init => "init",
            Self::Run => "run",
            Self::Pair => "pair",
            Self::Devices => "devices",
            Self::Restore => "restore",
            Self::ScrubNow => "scrub-now",
        }
    }
}

fn main() -> ExitCode {
    tracing_subscriber::fmt()
        .with_env_filter(tracing_subscriber::EnvFilter::from_default_env())
        .with_writer(std::io::stderr)
        .init();

    let cli = Cli::parse();
    eprintln!(
        "haotrannas-server {}: not implemented yet",
        cli.command.name()
    );
    ExitCode::from(NOT_IMPLEMENTED_EXIT_CODE)
}
