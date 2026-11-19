//! Request handlers: one module per message group. Each takes a decoded
//! request and the session's device, uses the chunk store and catalog, and
//! returns the reply message.
//!
//! `hello` (M0), `upload` (M1/M2), `pair` (M3); browse and download come in M5.

pub mod browse;
pub mod download;
pub mod hello;
pub mod pair;
pub mod upload;
