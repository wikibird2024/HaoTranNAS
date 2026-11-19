//! `pair`: pair this client with a server using the code the server printed
//! (protocol spec §7).
//!
//! ```text
//!  TLS, no client cert, server fingerprint recorded (trust on first use)
//!  ─► Hello (expect device_id 0) ─► PairRequest(code) ─► PairOk
//!  ─► PairOk.server_cert_sha256 == recorded fingerprint?   else stop, save nothing
//!  ─► --expect-server-id given: == short id?              else stop, save nothing
//!  ─► save device.crt.pem, device.key.pem (0600), server.json
//! ```
//!
//! The server then sends `Close PAIRED_RECONNECT`; the next command
//! connects with the new certificate. The key is never printed or logged.

use std::path::PathBuf;

use anyhow::{Context, bail};
use haotrannas_core::fingerprint::CertFingerprint;
use haotrannas_core::message::Message;
use haotrannas_core::tls::ClientIdentity;

use crate::connection::{open_pairing_connection, unexpected_reply};
use crate::identity::{self, PairedIdentity};

/// What the person asked for.
#[derive(Debug, Clone)]
pub struct PairRequest {
    pub server_address: String,
    pub code: String,
    /// The short id the server printed with the code, to compare.
    pub expected_server_id: Option<String>,
    /// Name the server stores for this device.
    pub device_name: String,
    pub identity_directory: PathBuf,
}

/// A finished pairing.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PairOutcome {
    pub device_id: u64,
    pub server_short_id: String,
}

/// Pairs and saves the identity.
pub async fn run_pair(request: &PairRequest) -> anyhow::Result<PairOutcome> {
    if identity::is_paired(&request.identity_directory) {
        bail!(
            "{} already holds a pairing; use another --identity-dir or delete it first",
            request.identity_directory.display()
        );
    }
    let (mut connection, recorder) =
        open_pairing_connection(&request.server_address, &request.device_name).await?;
    if connection.server_hello.device_id != 0 {
        bail!(
            "the server already knows this connection as device {}; expected an unpaired connection",
            connection.server_hello.device_id
        );
    }
    let reply = connection
        .request(&Message::PairRequest {
            code: request.code.clone(),
        })
        .await?;
    // The server closes with PAIRED_RECONNECT right after PairOk.
    drop(connection);
    let Message::PairOk {
        device_id,
        device_cert_der,
        device_key_pkcs8_der,
        server_cert_sha256,
    } = reply
    else {
        return Err(unexpected_reply(&reply).into());
    };

    let seen_fingerprint = recorder
        .seen_fingerprint()
        .context("the TLS handshake recorded no server certificate")?;
    let named_fingerprint = CertFingerprint(server_cert_sha256);
    if named_fingerprint != seen_fingerprint {
        bail!(
            "PairOk names server {} but the TLS connection was to {}: someone may be in the \
             middle. Nothing saved",
            named_fingerprint.short_id(),
            seen_fingerprint.short_id()
        );
    }
    let server_short_id = seen_fingerprint.short_id();
    if let Some(expected_server_id) = &request.expected_server_id
        && !expected_server_id
            .trim()
            .eq_ignore_ascii_case(&server_short_id)
    {
        bail!(
            "the server's id is {server_short_id}, not {} as expected. Nothing saved",
            expected_server_id.trim()
        );
    }

    let paired_identity = PairedIdentity {
        server_fingerprint: seen_fingerprint,
        device_id,
        last_address: request.server_address.clone(),
        client_identity: ClientIdentity {
            cert_der: device_cert_der,
            key_pkcs8_der: device_key_pkcs8_der,
        },
    };
    identity::save(&request.identity_directory, &paired_identity)?;
    Ok(PairOutcome {
        device_id,
        server_short_id,
    })
}
