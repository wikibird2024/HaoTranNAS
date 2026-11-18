//! Which backup paths are valid (protocol spec section 10): UTF-8,
//! 1 ..= `MAX_PATH_BYTES` long, `/`-separated, at most `MAX_PATH_COMPONENTS`
//! components of 1 ..= 255 bytes each, no leading or trailing `/`, no `.` or
//! `..` component, no NUL and no backslash (see [`crate::limits`]).
//!
//! Both sides use these rules: the client before sending, the server before
//! trusting a path. Paths are not normalized: they are stored exactly as sent.

use crate::limits::{MAX_PATH_BYTES, MAX_PATH_COMPONENTS};

/// Longest path component, in UTF-8 bytes (a path rule, not a shared limit).
const MAX_COMPONENT_BYTES: usize = 255;

/// Why a path breaks the rules (the server answers `BAD_PATH`).
#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum PathError {
    /// The path is "".
    #[error("path is empty")]
    Empty,
    /// More than `MAX_PATH_BYTES`.
    #[error("path is {length_bytes} bytes, max {MAX_PATH_BYTES}")]
    TooLong {
        /// The path's length.
        length_bytes: usize,
    },
    /// Contains a NUL character.
    #[error("path contains NUL")]
    HasNul,
    /// Contains a backslash.
    #[error("path contains a backslash")]
    HasBackslash,
    /// Starts with `/`.
    #[error("path starts with /")]
    LeadingSlash,
    /// Ends with `/`.
    #[error("path ends with /")]
    TrailingSlash,
    /// More than `MAX_PATH_COMPONENTS` components.
    #[error("path has {component_count} components, max {MAX_PATH_COMPONENTS}")]
    TooManyComponents {
        /// Number of `/`-separated components.
        component_count: usize,
    },
    /// Two slashes in a row (`a//b`).
    #[error("path has an empty component")]
    EmptyComponent,
    /// A component over 255 bytes.
    #[error("path component is {length_bytes} bytes, max {MAX_COMPONENT_BYTES}")]
    ComponentTooLong {
        /// The component's length.
        length_bytes: usize,
    },
    /// A component equal to `.` or `..`.
    #[error("path has a . or .. component")]
    DotComponent,
}

/// Checks `path` against every path rule.
pub fn validate_path(path: &str) -> Result<(), PathError> {
    if path.is_empty() {
        return Err(PathError::Empty);
    }
    if path.len() > MAX_PATH_BYTES {
        return Err(PathError::TooLong {
            length_bytes: path.len(),
        });
    }
    if path.contains('\0') {
        return Err(PathError::HasNul);
    }
    if path.contains('\\') {
        return Err(PathError::HasBackslash);
    }
    if path.starts_with('/') {
        return Err(PathError::LeadingSlash);
    }
    if path.ends_with('/') {
        return Err(PathError::TrailingSlash);
    }
    let component_count = path.split('/').count();
    if component_count > MAX_PATH_COMPONENTS {
        return Err(PathError::TooManyComponents { component_count });
    }
    for component in path.split('/') {
        if component.is_empty() {
            return Err(PathError::EmptyComponent);
        }
        if component.len() > MAX_COMPONENT_BYTES {
            return Err(PathError::ComponentTooLong {
                length_bytes: component.len(),
            });
        }
        if component == "." || component == ".." {
            return Err(PathError::DotComponent);
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::{PathError, validate_path};

    #[test]
    fn each_rule_gives_its_error() {
        assert_eq!(validate_path("DCIM/a.jpg"), Ok(()));
        assert_eq!(validate_path(""), Err(PathError::Empty));
        assert_eq!(validate_path("/a"), Err(PathError::LeadingSlash));
        assert_eq!(validate_path("a/"), Err(PathError::TrailingSlash));
        assert_eq!(validate_path("a//b"), Err(PathError::EmptyComponent));
        assert_eq!(validate_path("a/../b"), Err(PathError::DotComponent));
        assert_eq!(validate_path("a\\b"), Err(PathError::HasBackslash));
        assert_eq!(validate_path("a\0b"), Err(PathError::HasNul));
        assert_eq!(
            validate_path(&"x".repeat(256)),
            Err(PathError::ComponentTooLong { length_bytes: 256 })
        );
        assert_eq!(
            validate_path(&["p"; 33].join("/")),
            Err(PathError::TooManyComponents {
                component_count: 33
            })
        );
    }
}
