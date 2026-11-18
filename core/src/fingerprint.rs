//! Certificate fingerprints: the SHA-256 of a DER certificate. The server
//! knows each device by its fingerprint; the client pins the server's.

use crate::limits::HASH_BYTES;

/// SHA-256 of a DER-encoded certificate.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct CertFingerprint(pub [u8; HASH_BYTES]);
