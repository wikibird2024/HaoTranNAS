//! Which backup paths are valid: UTF-8, `/`-separated, no empty, `.` or `..`
//! components, at most `MAX_PATH_BYTES` long, `MAX_PATH_COMPONENTS` deep and
//! `MAX_NAME_BYTES` per component (see [`crate::limits`]).
//!
//! Both sides use these rules: the client before sending, the server before
//! trusting a path.
//!
//! Stub: filled in when the protocol spec is fixed.
