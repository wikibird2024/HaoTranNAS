//! This client's pairing, kept in the identity folder (`--identity-dir`,
//! default `$XDG_CONFIG_HOME/haotrannas` or `~/.config/haotrannas`):
//!
//! ```text
//!  <identity_dir>/        mode 0700
//!    device.crt.pem       this device's certificate (from PairOk)
//!    device.key.pem       its private key, PKCS#8, mode 0600 (never printed)
//!    server.json          {"server_cert_sha256": <64 hex>, "device_id": n,
//!                          "last_address": "host:port"}  (written last)
//! ```
//!
//! Each file is written to a temporary name, synced, then renamed, so a
//! crash never leaves half a key. `server.json` is written last: it is the
//! "paired" mark.

use std::fs::{self, DirBuilder, OpenOptions};
use std::io::Write;
use std::os::unix::fs::{DirBuilderExt, OpenOptionsExt};
use std::path::{Path, PathBuf};

use anyhow::{Context, bail};
use haotrannas_core::fingerprint::CertFingerprint;
use haotrannas_core::limits::HASH_BYTES;
use haotrannas_core::tls::ClientIdentity;
use rustls_pki_types::pem::PemObject;
use rustls_pki_types::{CertificateDer, PrivatePkcs8KeyDer};
use serde::{Deserialize, Serialize};

pub const DEVICE_CERT_FILE: &str = "device.crt.pem";
pub const DEVICE_KEY_FILE: &str = "device.key.pem";
pub const SERVER_RECORD_FILE: &str = "server.json";

/// Folder name under the config folder.
const IDENTITY_FOLDER_NAME: &str = "haotrannas";
const IDENTITY_DIRECTORY_MODE: u32 = 0o700;
const KEY_FILE_MODE: u32 = 0o600;
const PUBLIC_FILE_MODE: u32 = 0o644;
/// Base64 characters per PEM line (RFC 7468).
const PEM_LINE_CHARS: usize = 64;

/// `server.json`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ServerRecord {
    /// SHA-256 of the server certificate, 64 lowercase hex chars: the pin.
    pub server_cert_sha256: String,
    /// This device's id on that server.
    pub device_id: u64,
    /// Where the server was reached last (`host:port`).
    pub last_address: String,
}

/// A loaded pairing: everything needed to connect as this device.
#[derive(Debug, Clone)]
pub struct PairedIdentity {
    pub server_fingerprint: CertFingerprint,
    pub device_id: u64,
    pub last_address: String,
    pub client_identity: ClientIdentity,
}

/// `$XDG_CONFIG_HOME/haotrannas`, else `$HOME/.config/haotrannas`.
pub fn default_identity_directory() -> Option<PathBuf> {
    let config_home = std::env::var_os("XDG_CONFIG_HOME")
        .map(PathBuf::from)
        .filter(|path| path.is_absolute())
        .or_else(|| {
            std::env::var_os("HOME")
                .map(PathBuf::from)
                .filter(|path| path.is_absolute())
                .map(|home| home.join(".config"))
        })?;
    Some(config_home.join(IDENTITY_FOLDER_NAME))
}

/// True once a pairing was saved in `identity_directory`.
pub fn is_paired(identity_directory: &Path) -> bool {
    identity_directory.join(SERVER_RECORD_FILE).exists()
}

/// The saved pairing, or `None` when this folder holds none.
pub fn load(identity_directory: &Path) -> anyhow::Result<Option<PairedIdentity>> {
    let record_path = identity_directory.join(SERVER_RECORD_FILE);
    if !record_path.exists() {
        return Ok(None);
    }
    let record_text = fs::read_to_string(&record_path)
        .with_context(|| format!("cannot read {}", record_path.display()))?;
    let record: ServerRecord = serde_json::from_str(&record_text)
        .with_context(|| format!("{} is not a valid server record", record_path.display()))?;
    let fingerprint_bytes: [u8; HASH_BYTES] = hex::decode(&record.server_cert_sha256)
        .ok()
        .and_then(|bytes| bytes.try_into().ok())
        .with_context(|| {
            format!(
                "{}: server_cert_sha256 is not 64 hex chars",
                record_path.display()
            )
        })?;
    let cert_path = identity_directory.join(DEVICE_CERT_FILE);
    let cert_der = CertificateDer::from_pem_file(&cert_path)
        .with_context(|| format!("cannot read the certificate {}", cert_path.display()))?;
    let key_path = identity_directory.join(DEVICE_KEY_FILE);
    let key_der = PrivatePkcs8KeyDer::from_pem_file(&key_path)
        .with_context(|| format!("cannot read the key {}", key_path.display()))?;
    Ok(Some(PairedIdentity {
        server_fingerprint: CertFingerprint(fingerprint_bytes),
        device_id: record.device_id,
        last_address: record.last_address,
        client_identity: ClientIdentity {
            cert_der: cert_der.to_vec(),
            key_pkcs8_der: key_der.secret_pkcs8_der().to_vec(),
        },
    }))
}

/// Saves a new pairing. Refuses a folder that already holds one (pairing
/// again would throw away the old key).
pub fn save(identity_directory: &Path, identity: &PairedIdentity) -> anyhow::Result<()> {
    if is_paired(identity_directory) {
        bail!(
            "{} already holds a pairing; use another --identity-dir or delete it first",
            identity_directory.display()
        );
    }
    DirBuilder::new()
        .recursive(true)
        .mode(IDENTITY_DIRECTORY_MODE)
        .create(identity_directory)
        .with_context(|| format!("cannot create {}", identity_directory.display()))?;
    write_file_atomically(
        &identity_directory.join(DEVICE_KEY_FILE),
        pem_text("PRIVATE KEY", &identity.client_identity.key_pkcs8_der).as_bytes(),
        KEY_FILE_MODE,
    )?;
    write_file_atomically(
        &identity_directory.join(DEVICE_CERT_FILE),
        pem_text("CERTIFICATE", &identity.client_identity.cert_der).as_bytes(),
        PUBLIC_FILE_MODE,
    )?;
    let record = ServerRecord {
        server_cert_sha256: identity.server_fingerprint.to_hex(),
        device_id: identity.device_id,
        last_address: identity.last_address.clone(),
    };
    let mut record_text = serde_json::to_string_pretty(&record)?;
    record_text.push('\n');
    write_file_atomically(
        &identity_directory.join(SERVER_RECORD_FILE),
        record_text.as_bytes(),
        PUBLIC_FILE_MODE,
    )
}

/// Writes `<path>.tmp` with `mode`, syncs it, renames it to `path`.
fn write_file_atomically(path: &Path, contents: &[u8], mode: u32) -> anyhow::Result<()> {
    let mut temporary_name = path.as_os_str().to_owned();
    temporary_name.push(".tmp");
    let temporary_path = PathBuf::from(temporary_name);
    let _ = fs::remove_file(&temporary_path);
    let mut file = OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(mode)
        .open(&temporary_path)
        .with_context(|| format!("cannot create {}", temporary_path.display()))?;
    file.write_all(contents)
        .and_then(|()| file.sync_all())
        .with_context(|| format!("cannot write {}", temporary_path.display()))?;
    fs::rename(&temporary_path, path)
        .with_context(|| format!("cannot rename to {}", path.display()))
}

/// DER bytes as a PEM block with `label`.
fn pem_text(label: &str, der: &[u8]) -> String {
    let base64_text = base64_encode(der);
    let mut text = format!("-----BEGIN {label}-----\n");
    for line in base64_text.as_bytes().chunks(PEM_LINE_CHARS) {
        text.push_str(std::str::from_utf8(line).expect("base64 is ASCII"));
        text.push('\n');
    }
    text.push_str("-----END ");
    text.push_str(label);
    text.push_str("-----\n");
    text
}

/// Standard base64 with padding (RFC 4648 §4).
fn base64_encode(bytes: &[u8]) -> String {
    const ALPHABET: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut text = String::with_capacity(bytes.len().div_ceil(3) * 4);
    for group in bytes.chunks(3) {
        let first = group[0];
        let second = group.get(1).copied().unwrap_or(0);
        let third = group.get(2).copied().unwrap_or(0);
        let joined = (u32::from(first) << 16) | (u32::from(second) << 8) | u32::from(third);
        for position in 0..4 {
            if position <= group.len() {
                let index = (joined >> (18 - 6 * position)) & 0x3F;
                text.push(char::from(ALPHABET[index as usize]));
            } else {
                text.push('=');
            }
        }
    }
    text
}

#[cfg(test)]
mod tests {
    use std::os::unix::fs::PermissionsExt;

    use super::*;

    #[test]
    fn base64_matches_rfc_4648_vectors() {
        let vectors = [
            ("", ""),
            ("f", "Zg=="),
            ("fo", "Zm8="),
            ("foo", "Zm9v"),
            ("foob", "Zm9vYg=="),
            ("fooba", "Zm9vYmE="),
            ("foobar", "Zm9vYmFy"),
        ];
        for (plain, encoded) in vectors {
            assert_eq!(base64_encode(plain.as_bytes()), encoded, "{plain:?}");
        }
    }

    fn sample_identity() -> PairedIdentity {
        let key = rcgen::KeyPair::generate().unwrap();
        let params = rcgen::CertificateParams::new(vec!["device-7".to_owned()]).unwrap();
        let cert = params.self_signed(&key).unwrap();
        PairedIdentity {
            server_fingerprint: CertFingerprint::of_der(b"server"),
            device_id: 7,
            last_address: "127.0.0.1:47100".to_owned(),
            client_identity: ClientIdentity {
                cert_der: cert.der().to_vec(),
                key_pkcs8_der: key.serialize_der(),
            },
        }
    }

    #[test]
    fn save_then_load_gives_the_same_identity() {
        let folder = tempfile::tempdir().unwrap();
        let identity_directory = folder.path().join("identity");
        assert!(load(&identity_directory).unwrap().is_none());
        let identity = sample_identity();
        save(&identity_directory, &identity).unwrap();

        let loaded = load(&identity_directory).unwrap().unwrap();
        assert_eq!(loaded.server_fingerprint, identity.server_fingerprint);
        assert_eq!(loaded.device_id, 7);
        assert_eq!(loaded.last_address, identity.last_address);
        assert_eq!(loaded.client_identity, identity.client_identity);

        let mode_of = |name: &str| {
            fs::metadata(identity_directory.join(name))
                .unwrap()
                .permissions()
                .mode()
                & 0o777
        };
        assert_eq!(mode_of(DEVICE_KEY_FILE), 0o600);
        assert_eq!(
            fs::metadata(&identity_directory)
                .unwrap()
                .permissions()
                .mode()
                & 0o777,
            0o700
        );
        // The PEM key is what other TLS tools read too.
        assert!(
            fs::read_to_string(identity_directory.join(DEVICE_KEY_FILE))
                .unwrap()
                .starts_with("-----BEGIN PRIVATE KEY-----\n")
        );
        // A second pairing into the same folder is refused.
        assert!(save(&identity_directory, &identity).is_err());
    }
}
