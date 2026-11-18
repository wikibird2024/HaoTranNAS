//! Certificate fingerprints: the SHA-256 of a DER certificate. The server
//! knows each device by its fingerprint; the client pins the server's.
//!
//! Text forms (protocol spec §7 and §13):
//! - full hex: 64 lowercase hex chars,
//! - short id: first 6 bytes, uppercase hex, groups of 4 joined by `-`
//!   (`3F9A-C21B-77E0`), shown to the user at pairing,
//! - mDNS prefix: first 16 lowercase hex chars, sent in the `fp` TXT record.

use sha2::{Digest, Sha256};

use crate::limits::HASH_BYTES;

/// Bytes of the fingerprint shown as the short id.
const SHORT_ID_BYTES: usize = 6;

/// Hex chars per group in the short id.
const SHORT_ID_GROUP_CHARS: usize = 4;

/// Hex chars of the fingerprint sent in the mDNS `fp` TXT record.
const MDNS_PREFIX_CHARS: usize = 16;

/// SHA-256 of a DER-encoded certificate.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct CertFingerprint(pub [u8; HASH_BYTES]);

impl CertFingerprint {
    /// Fingerprint of a DER-encoded certificate.
    pub fn of_der(cert_der: &[u8]) -> Self {
        Self(Sha256::digest(cert_der).into())
    }

    /// All 32 bytes as 64 lowercase hex chars.
    pub fn to_hex(&self) -> String {
        hex::encode(self.0)
    }

    /// The id people compare at pairing: `3F9A-C21B-77E0`.
    pub fn short_id(&self) -> String {
        let short_hex = hex::encode_upper(&self.0[..SHORT_ID_BYTES]);
        short_hex
            .as_bytes()
            .chunks(SHORT_ID_GROUP_CHARS)
            .map(|group| std::str::from_utf8(group).expect("hex is ASCII"))
            .collect::<Vec<_>>()
            .join("-")
    }

    /// The `fp` value in the mDNS TXT record: first 16 lowercase hex chars.
    pub fn mdns_prefix(&self) -> String {
        let mut full_hex = self.to_hex();
        full_hex.truncate(MDNS_PREFIX_CHARS);
        full_hex
    }
}

#[cfg(test)]
mod tests {
    use super::CertFingerprint;

    /// SHA-256("abc"), the FIPS 180-2 test vector.
    const ABC_SHA256_HEX: &str = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad";

    #[test]
    fn of_der_is_sha256() {
        assert_eq!(CertFingerprint::of_der(b"abc").to_hex(), ABC_SHA256_HEX);
    }

    #[test]
    fn short_id_is_first_six_bytes_upper_in_groups_of_four() {
        assert_eq!(CertFingerprint::of_der(b"abc").short_id(), "BA78-16BF-8F01");
    }

    #[test]
    fn mdns_prefix_is_first_sixteen_lower_hex_chars() {
        assert_eq!(
            CertFingerprint::of_der(b"abc").mdns_prefix(),
            "ba7816bf8f01cfea"
        );
    }

    #[test]
    fn short_id_matches_spec_example_shape() {
        let mut bytes = [0u8; 32];
        bytes[..6].copy_from_slice(&[0x3F, 0x9A, 0xC2, 0x1B, 0x77, 0xE0]);
        assert_eq!(CertFingerprint(bytes).short_id(), "3F9A-C21B-77E0");
    }
}
