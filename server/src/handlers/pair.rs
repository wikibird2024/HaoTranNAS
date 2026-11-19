//! `PairRequest` → `PairOk` (protocol spec §7), checked in the spec's order:
//!
//! ```text
//!  source IP in pairing_networks or loopback? ── no ──► PAIRING_NOT_ALLOWED_FROM_NETWORK (fatal)
//!  window open?                               ── no ──► PAIRING_NOT_OPEN (not fatal)
//!  window locked (10 failures)?               ── yes ─► TOO_MANY_ATTEMPTS (fatal)
//!  code right?                                ── no ──► BAD_PAIRING_CODE (fatal on the 3rd in
//!                                                       this connection)
//!  add device + issue its cert (one catalog transaction) ──► PairOk
//! ```
//!
//! The session then sends `Close PAIRED_RECONNECT` and ends. The device key
//! in `PairOk` is never logged.

use std::net::IpAddr;
use std::sync::Arc;
use std::time::{SystemTime, UNIX_EPOCH};

use haotrannas_core::error_code::ErrorCode;
use haotrannas_core::limits::MAX_PAIR_FAILURES_PER_CONNECTION;
use haotrannas_core::message::Message;

use crate::catalog::CatalogError;
use crate::catalog::writer::CatalogWriter;
use crate::pairing::{CodeCheck, PairingService};

/// Name stored for a device that sent an empty `device_name` in `Hello`.
const UNNAMED_DEVICE_NAME: &str = "unnamed";

/// What the session does with a `PairRequest`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum PairStep {
    /// Send this `PairOk`, then `Close PAIRED_RECONNECT`.
    Paired(Message),
    /// Send `Error`; the connection stays.
    Refused(ErrorCode, String),
    /// Send `Error` and close the connection.
    Fatal(ErrorCode, String),
}

/// The connection's view of a `PairRequest`.
#[derive(Debug)]
pub struct PairAttempt<'a> {
    /// The client's source address.
    pub peer_ip: IpAddr,
    /// `device_name` from the connection's `Hello`.
    pub device_name: &'a str,
    /// The offered code.
    pub code: &'a str,
}

/// Answers one `PairRequest`. `failures_in_connection` counts wrong codes on
/// this connection (the session keeps it).
pub async fn handle_pair_request(
    pairing: &PairingService,
    catalog_writer: &CatalogWriter,
    attempt: &PairAttempt<'_>,
    failures_in_connection: &mut u32,
) -> PairStep {
    if !pairing.is_allowed_from(attempt.peer_ip) {
        tracing::warn!(peer_ip = %attempt.peer_ip, "pairing refused: not from a pairing network");
        return PairStep::Fatal(
            ErrorCode::PairingNotAllowedFromNetwork,
            format!(
                "pairing is allowed from the LAN only, not from {}",
                attempt.peer_ip
            ),
        );
    }
    match pairing.check_code(attempt.code) {
        CodeCheck::Accepted => {}
        CodeCheck::NotOpen => {
            return PairStep::Refused(
                ErrorCode::PairingNotOpen,
                "no pairing code is open: run `haotrannas-server pair` on the server".to_owned(),
            );
        }
        CodeCheck::Locked => {
            return PairStep::Fatal(
                ErrorCode::TooManyAttempts,
                "too many wrong codes: pairing is locked until a new code is made".to_owned(),
            );
        }
        CodeCheck::Wrong => {
            *failures_in_connection += 1;
            tracing::warn!(
                peer_ip = %attempt.peer_ip,
                failures_in_connection = *failures_in_connection,
                "wrong pairing code"
            );
            let text = "wrong pairing code".to_owned();
            return if *failures_in_connection >= MAX_PAIR_FAILURES_PER_CONNECTION {
                PairStep::Fatal(ErrorCode::BadPairingCode, text)
            } else {
                PairStep::Refused(ErrorCode::BadPairingCode, text)
            };
        }
    }

    let device_name = if attempt.device_name.is_empty() {
        UNNAMED_DEVICE_NAME.to_owned()
    } else {
        attempt.device_name.to_owned()
    };
    let tls_identity = Arc::clone(pairing.tls_identity());
    let added = catalog_writer
        .add_paired_device(device_name.clone(), unix_time_ms(), move |device_id| {
            let issued = tls_identity
                .issue_device_cert(device_id)
                .map_err(|error| CatalogError::CertificateIssue(error.to_string()))?;
            let fingerprint = issued.fingerprint.0;
            Ok((issued, fingerprint))
        })
        .await;
    match added {
        Ok((device_id, issued)) => {
            tracing::info!(
                device_id,
                device_name = %device_name,
                peer_ip = %attempt.peer_ip,
                cert = %issued.fingerprint.short_id(),
                "device paired"
            );
            PairStep::Paired(Message::PairOk {
                device_id,
                device_cert_der: issued.cert_der,
                device_key_pkcs8_der: issued.key_pkcs8_der,
                server_cert_sha256: pairing.tls_identity().server_fingerprint().0,
            })
        }
        Err(error) => {
            tracing::error!(%error, "pairing failed after the code was accepted");
            PairStep::Refused(
                ErrorCode::Internal,
                "pairing failed on the server; make a new code and try again".to_owned(),
            )
        }
    }
}

/// Now, in ms since the Unix epoch.
fn unix_time_ms() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0, |since_epoch| {
            i64::try_from(since_epoch.as_millis()).unwrap_or(i64::MAX)
        })
}

#[cfg(test)]
mod tests {
    use haotrannas_core::fingerprint::CertFingerprint;
    use haotrannas_core::limits::PAIRING_CODE_TTL_MS;

    use super::*;
    use crate::catalog::reader::CatalogReader;
    use crate::config::ServerConfig;
    use crate::tls_identity::TlsIdentity;

    struct TestPairing {
        _folder: tempfile::TempDir,
        service: PairingService,
        writer: CatalogWriter,
        reader: CatalogReader,
    }

    fn test_pairing() -> TestPairing {
        let folder = tempfile::tempdir().unwrap();
        let identity = Arc::new(TlsIdentity::create(&folder.path().join("tls")).unwrap());
        let database_path = folder.path().join("index.sqlite");
        let (writer, _thread) = CatalogWriter::start(&database_path).unwrap();
        TestPairing {
            service: PairingService::new(identity, ServerConfig::default(), PAIRING_CODE_TTL_MS),
            writer,
            reader: CatalogReader::new(&database_path),
            _folder: folder,
        }
    }

    fn attempt<'a>(peer_ip: &str, code: &'a str) -> PairAttempt<'a> {
        PairAttempt {
            peer_ip: peer_ip.parse().unwrap(),
            device_name: "Pixel 8",
            code,
        }
    }

    #[tokio::test]
    async fn right_code_pairs_and_stores_the_cert_fingerprint() {
        let pairing = test_pairing();
        let code = pairing.service.open_window().code;
        let mut failures = 0;
        let step = handle_pair_request(
            &pairing.service,
            &pairing.writer,
            &attempt("192.168.1.20", &code),
            &mut failures,
        )
        .await;
        let PairStep::Paired(Message::PairOk {
            device_id,
            device_cert_der,
            device_key_pkcs8_der,
            server_cert_sha256,
        }) = step
        else {
            panic!("expected PairOk, got {step:?}");
        };
        assert!(!device_key_pkcs8_der.is_empty());
        assert_eq!(
            server_cert_sha256,
            pairing.service.tls_identity().server_fingerprint().0
        );
        let device = pairing
            .reader
            .device_by_cert(&CertFingerprint::of_der(&device_cert_der).0)
            .unwrap()
            .unwrap();
        assert_eq!(
            (device.device_id, device.name.as_str()),
            (device_id, "Pixel 8")
        );

        // Single use.
        let again = handle_pair_request(
            &pairing.service,
            &pairing.writer,
            &attempt("192.168.1.20", &code),
            &mut failures,
        )
        .await;
        assert!(matches!(
            again,
            PairStep::Refused(ErrorCode::PairingNotOpen, _)
        ));
    }

    #[tokio::test]
    async fn third_wrong_code_in_a_connection_is_fatal() {
        let pairing = test_pairing();
        pairing.service.open_window();
        let mut failures = 0;
        for expected_fatal in [false, false, true] {
            let step = handle_pair_request(
                &pairing.service,
                &pairing.writer,
                &attempt("127.0.0.1", "not-it"),
                &mut failures,
            )
            .await;
            match step {
                PairStep::Fatal(ErrorCode::BadPairingCode, _) => assert!(expected_fatal),
                PairStep::Refused(ErrorCode::BadPairingCode, _) => assert!(!expected_fatal),
                other => panic!("unexpected {other:?}"),
            }
        }
    }

    #[tokio::test]
    async fn outside_network_is_refused_before_the_code_is_looked_at() {
        let pairing = test_pairing();
        let code = pairing.service.open_window().code;
        let mut failures = 0;
        let step = handle_pair_request(
            &pairing.service,
            &pairing.writer,
            &attempt("10.66.0.2", &code),
            &mut failures,
        )
        .await;
        assert!(matches!(
            step,
            PairStep::Fatal(ErrorCode::PairingNotAllowedFromNetwork, _)
        ));
        // The code was not used up.
        let step = handle_pair_request(
            &pairing.service,
            &pairing.writer,
            &attempt("192.168.0.9", &code),
            &mut failures,
        )
        .await;
        assert!(matches!(step, PairStep::Paired(_)));
    }

    #[tokio::test]
    async fn no_window_is_not_fatal() {
        let pairing = test_pairing();
        let mut failures = 0;
        let step = handle_pair_request(
            &pairing.service,
            &pairing.writer,
            &attempt("127.0.0.1", "123456"),
            &mut failures,
        )
        .await;
        assert!(matches!(
            step,
            PairStep::Refused(ErrorCode::PairingNotOpen, _)
        ));
        assert_eq!(failures, 0);
    }
}
