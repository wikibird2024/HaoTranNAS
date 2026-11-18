//! `haotrannas_core`: the protocol pieces both ends of a connection share.
//!
//! Owns framing, message encoding, limits, path rules, chunking, hashing,
//! the session state machine and TLS setup. Knows nothing about SQLite, disk
//! layout or any UI (see `docs/conventions.md` §1).
//!
//! Cargo features:
//! - `tokio`: async frame read/write over tokio streams ([`io`]).
//! - `tls`: TLS 1.3 configs and self-signed identities with rustls + ring ([`tls`]).

pub mod chunker;
pub mod codec;
pub mod error_code;
pub mod fingerprint;
pub mod frame;
pub mod limits;
pub mod message;
pub mod path_rules;
pub mod session;
pub mod wire;

#[cfg(feature = "tokio")]
pub mod io;

#[cfg(feature = "tls")]
pub mod tls;
