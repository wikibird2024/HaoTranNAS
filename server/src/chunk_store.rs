//! Chunk files on disk: `chunks/ab/cd/<sha256 hex>`, never changed once
//! written. A write goes to `tmp/`, is fsynced, re-hashed and only then
//! renamed into place (`docs/conventions.md` §4).

use std::path::PathBuf;

/// The chunk folder tree under the data folder.
#[derive(Debug)]
pub struct ChunkStore {
    /// Folder holding `chunks/` and `tmp/`.
    root_directory: PathBuf,
}
