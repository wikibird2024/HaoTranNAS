//! The single writer task: every SQLite write arrives over one channel and
//! runs in order. `Commit` is one transaction.
