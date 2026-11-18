//! Helpers for the end-to-end tests: find the built server and cli programs,
//! start them in a temporary data folder, and stop them afterwards.
//!
//! The tests run the real binaries, so build them first:
//! `cargo build --workspace --bins`.

use std::path::{Path, PathBuf};

/// Root folder of the Cargo workspace (the parent of `e2e/`).
pub fn workspace_root() -> PathBuf {
    let e2e_directory = Path::new(env!("CARGO_MANIFEST_DIR"));
    e2e_directory
        .parent()
        .unwrap_or(e2e_directory)
        .to_path_buf()
}

/// Path of a debug binary of this workspace, for example `haotrannas-server`.
///
/// Uses `CARGO_TARGET_DIR` when set, else `<workspace>/target`. Does not
/// check that the file exists.
pub fn workspace_binary(binary_name: &str) -> PathBuf {
    let target_directory = std::env::var_os("CARGO_TARGET_DIR")
        .map_or_else(|| workspace_root().join("target"), PathBuf::from);
    target_directory
        .join("debug")
        .join(format!("{binary_name}{}", std::env::consts::EXE_SUFFIX))
}
