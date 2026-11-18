//! The catalog: all metadata in `index.sqlite` (WAL mode). Devices, files,
//! versions, chunk lists, chunk reference counts and open uploads.
//!
//! All writes go through one writer task; reads use their own connections.

pub mod reader;
pub mod schema;
pub mod writer;
