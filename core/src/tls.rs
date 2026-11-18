//! TLS setup with rustls and the `ring` provider, TLS 1.3 only: server and
//! client configs for mutual TLS and the pinned-fingerprint server check.
//! Enabled by the `tls` feature.
//!
//! ```text
//!  client                                        server
//!  PinnedServerVerifier:                          WebPkiClientVerifier:
//!    SHA-256(leaf DER) == pin?                      device cert signed by
//!    (no name, no chain, no dates)                  the device CA? (optional:
//!    TLS 1.3 signature checked by ring              no cert = unpaired)
//! ```
//!
//! The client never checks the server's name (clients connect by IP, spec
//! §1); it still checks the server's handshake signature, so a copied
//! certificate without its key is refused.

use std::fmt;
use std::sync::{Arc, Mutex, PoisonError};

use rustls::client::danger::{HandshakeSignatureValid, ServerCertVerified, ServerCertVerifier};
use rustls::crypto::{CryptoProvider, WebPkiSupportedAlgorithms, ring};
use rustls::server::WebPkiClientVerifier;
use rustls::{
    CertificateError, ClientConfig, DigitallySignedStruct, PeerIncompatible, RootCertStore,
    ServerConfig, SignatureScheme,
};
use rustls_pki_types::{CertificateDer, PrivateKeyDer, PrivatePkcs8KeyDer, ServerName, UnixTime};

use crate::fingerprint::CertFingerprint;

/// The name the client puts in SNI and passes to rustls. Only the server
/// cert's SAN carries it; nothing checks it (the pin replaces the name check).
pub const SERVER_DNS_NAME: &str = "haotrannas.local";

/// Error while building a TLS config.
#[derive(Debug, thiserror::Error)]
pub enum TlsSetupError {
    #[error("TLS config: {0}")]
    Rustls(#[from] rustls::Error),
    #[error("client certificate verifier: {0}")]
    ClientVerifier(#[from] rustls::server::VerifierBuilderError),
}

/// [`SERVER_DNS_NAME`] as the type `TlsConnector::connect` takes.
pub fn server_name() -> ServerName<'static> {
    ServerName::try_from(SERVER_DNS_NAME).expect("SERVER_DNS_NAME is a valid DNS name")
}

/// The ring provider, the only one this project uses (no aws-lc).
fn ring_provider() -> Arc<CryptoProvider> {
    Arc::new(ring::default_provider())
}

/// Records the fingerprint of the server seen during a pairing connection
/// (trust on first use). Clones share the same slot.
#[derive(Debug, Clone, Default)]
pub struct TofuRecorder {
    seen_fingerprint: Arc<Mutex<Option<CertFingerprint>>>,
}

impl TofuRecorder {
    pub fn new() -> Self {
        Self::default()
    }

    /// The server fingerprint seen by the last handshake, if any.
    pub fn seen_fingerprint(&self) -> Option<CertFingerprint> {
        *self
            .seen_fingerprint
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
    }

    fn record(&self, fingerprint: CertFingerprint) {
        *self
            .seen_fingerprint
            .lock()
            .unwrap_or_else(PoisonError::into_inner) = Some(fingerprint);
    }
}

/// What the client trusts as the server.
#[derive(Debug, Clone)]
pub enum ServerPin {
    /// Normal connection: only the server cert with this fingerprint.
    Fingerprint(CertFingerprint),
    /// Pairing connection: any server cert; its fingerprint is recorded so
    /// the app can compare it with `PairOk.server_cert_sha256`.
    RecordFirstSeen(TofuRecorder),
}

/// rustls server check by pinned fingerprint (see the module docs).
pub struct PinnedServerVerifier {
    pin: ServerPin,
    supported_algorithms: WebPkiSupportedAlgorithms,
}

impl PinnedServerVerifier {
    pub fn new(pin: ServerPin) -> Self {
        Self {
            pin,
            supported_algorithms: ring::default_provider().signature_verification_algorithms,
        }
    }
}

impl fmt::Debug for PinnedServerVerifier {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("PinnedServerVerifier")
            .field("pin", &self.pin)
            .finish_non_exhaustive()
    }
}

impl ServerCertVerifier for PinnedServerVerifier {
    fn verify_server_cert(
        &self,
        end_entity: &CertificateDer<'_>,
        intermediates: &[CertificateDer<'_>],
        _server_name: &ServerName<'_>,
        _ocsp_response: &[u8],
        _now: UnixTime,
    ) -> Result<ServerCertVerified, rustls::Error> {
        // The server sends its leaf only; anything else is not our server.
        if !intermediates.is_empty() {
            return Err(rustls::Error::InvalidCertificate(
                CertificateError::ApplicationVerificationFailure,
            ));
        }
        let seen_fingerprint = CertFingerprint::of_der(end_entity);
        match &self.pin {
            ServerPin::Fingerprint(pinned_fingerprint)
                if *pinned_fingerprint == seen_fingerprint =>
            {
                Ok(ServerCertVerified::assertion())
            }
            ServerPin::Fingerprint(_) => Err(rustls::Error::InvalidCertificate(
                CertificateError::ApplicationVerificationFailure,
            )),
            ServerPin::RecordFirstSeen(recorder) => {
                recorder.record(seen_fingerprint);
                Ok(ServerCertVerified::assertion())
            }
        }
    }

    fn verify_tls12_signature(
        &self,
        _message: &[u8],
        _cert: &CertificateDer<'_>,
        _signature: &DigitallySignedStruct,
    ) -> Result<HandshakeSignatureValid, rustls::Error> {
        Err(PeerIncompatible::Tls12NotOfferedOrEnabled.into())
    }

    fn verify_tls13_signature(
        &self,
        message: &[u8],
        cert: &CertificateDer<'_>,
        signature: &DigitallySignedStruct,
    ) -> Result<HandshakeSignatureValid, rustls::Error> {
        rustls::crypto::verify_tls13_signature(message, cert, signature, &self.supported_algorithms)
    }

    fn supported_verify_schemes(&self) -> Vec<SignatureScheme> {
        self.supported_algorithms.supported_schemes()
    }
}

/// This device's certificate and key from `PairOk`.
#[derive(Clone, PartialEq, Eq)]
pub struct ClientIdentity {
    pub cert_der: Vec<u8>,
    /// PKCS#8 DER. Never logged.
    pub key_pkcs8_der: Vec<u8>,
}

impl fmt::Debug for ClientIdentity {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("ClientIdentity")
            .field("cert_der", &self.cert_der.len())
            .field("key_pkcs8_der", &"<key redacted>")
            .finish()
    }
}

/// Client config: TLS 1.3, ring, server checked by `pin`, and this device's
/// cert when paired (`None` for the pairing connection).
pub fn client_config(
    pin: ServerPin,
    client_identity: Option<ClientIdentity>,
) -> Result<Arc<ClientConfig>, TlsSetupError> {
    let builder = ClientConfig::builder_with_provider(ring_provider())
        .with_protocol_versions(&[&rustls::version::TLS13])?
        .dangerous()
        .with_custom_certificate_verifier(Arc::new(PinnedServerVerifier::new(pin)));
    let config = match client_identity {
        Some(identity) => builder.with_client_auth_cert(
            vec![CertificateDer::from(identity.cert_der)],
            PrivateKeyDer::Pkcs8(PrivatePkcs8KeyDer::from(identity.key_pkcs8_der)),
        )?,
        None => builder.with_no_client_auth(),
    };
    Ok(Arc::new(config))
}

/// Server config: TLS 1.3, ring, sends only its leaf, and accepts a client
/// cert signed by the device CA or no client cert at all (unpaired). Which
/// device it is (or whether it was removed) is the session's job.
pub fn server_config(
    server_cert_der: &[u8],
    server_key_pkcs8_der: &[u8],
    device_ca_cert_der: &[u8],
) -> Result<Arc<ServerConfig>, TlsSetupError> {
    let provider = ring_provider();
    let mut device_ca_roots = RootCertStore::empty();
    device_ca_roots.add(CertificateDer::from(device_ca_cert_der.to_vec()))?;
    let client_verifier =
        WebPkiClientVerifier::builder_with_provider(Arc::new(device_ca_roots), provider.clone())
            .allow_unauthenticated()
            .build()?;
    let config = ServerConfig::builder_with_provider(provider)
        .with_protocol_versions(&[&rustls::version::TLS13])?
        .with_client_cert_verifier(client_verifier)
        .with_single_cert(
            vec![CertificateDer::from(server_cert_der.to_vec())],
            PrivateKeyDer::Pkcs8(PrivatePkcs8KeyDer::from(server_key_pkcs8_der.to_vec())),
        )?;
    Ok(Arc::new(config))
}

#[cfg(test)]
mod tests {
    use super::{
        CertFingerprint, ClientIdentity, PinnedServerVerifier, ServerPin, TofuRecorder,
        client_config, server_name,
    };
    use rustls::client::danger::ServerCertVerifier;
    use rustls_pki_types::{CertificateDer, UnixTime};

    fn self_signed_cert_der() -> CertificateDer<'static> {
        let key = rcgen::KeyPair::generate().unwrap();
        let params = rcgen::CertificateParams::new(vec!["haotrannas.local".to_owned()]).unwrap();
        params.self_signed(&key).unwrap().der().clone()
    }

    fn verify(
        verifier: &PinnedServerVerifier,
        end_entity: &CertificateDer<'_>,
        intermediates: &[CertificateDer<'_>],
    ) -> Result<(), rustls::Error> {
        verifier
            .verify_server_cert(
                end_entity,
                intermediates,
                &server_name(),
                &[],
                UnixTime::now(),
            )
            .map(|_| ())
    }

    #[test]
    fn pinned_accepts_matching_fingerprint() {
        let cert_der = self_signed_cert_der();
        let verifier =
            PinnedServerVerifier::new(ServerPin::Fingerprint(CertFingerprint::of_der(&cert_der)));
        assert!(verify(&verifier, &cert_der, &[]).is_ok());
    }

    #[test]
    fn pinned_refuses_other_fingerprint() {
        let cert_der = self_signed_cert_der();
        let other_der = self_signed_cert_der();
        let verifier =
            PinnedServerVerifier::new(ServerPin::Fingerprint(CertFingerprint::of_der(&other_der)));
        assert!(verify(&verifier, &cert_der, &[]).is_err());
    }

    #[test]
    fn pinned_refuses_intermediates() {
        let cert_der = self_signed_cert_der();
        let verifier =
            PinnedServerVerifier::new(ServerPin::Fingerprint(CertFingerprint::of_der(&cert_der)));
        let intermediate_der = self_signed_cert_der();
        assert!(verify(&verifier, &cert_der, &[intermediate_der]).is_err());
    }

    #[test]
    fn tofu_records_seen_fingerprint() {
        let cert_der = self_signed_cert_der();
        let recorder = TofuRecorder::new();
        let verifier = PinnedServerVerifier::new(ServerPin::RecordFirstSeen(recorder.clone()));
        assert_eq!(recorder.seen_fingerprint(), None);
        assert!(verify(&verifier, &cert_der, &[]).is_ok());
        assert_eq!(
            recorder.seen_fingerprint(),
            Some(CertFingerprint::of_der(&cert_der))
        );
    }

    #[test]
    fn client_identity_debug_hides_key() {
        let identity = ClientIdentity {
            cert_der: vec![1, 2, 3],
            key_pkcs8_der: vec![0x42; 8],
        };
        let debug_text = format!("{identity:?}");
        assert!(debug_text.contains("<key redacted>"));
        assert!(!debug_text.contains("66"));
    }

    #[test]
    fn client_config_builds_without_identity() {
        let recorder = TofuRecorder::new();
        assert!(client_config(ServerPin::RecordFirstSeen(recorder), None).is_ok());
    }
}
