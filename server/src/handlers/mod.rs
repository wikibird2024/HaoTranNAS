//! Request handlers: one module per message group. Each takes a decoded
//! request and the session's device, uses the chunk store and catalog, and
//! returns the reply message.
//!
//! M0 has only `hello`; the others are filled in from M1 on.

pub mod browse;
pub mod download;
pub mod hello;
pub mod pair;
pub mod upload;
