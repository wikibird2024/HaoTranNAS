//! The server's TLS identity (decision D-018): two keys in `<data_dir>/tls/`.
//!
//! ```text
//!  server.key + server.crt        self-signed leaf, sent alone in every
//!                                 handshake; clients pin SHA-256(server.crt DER)
//!  device-ca.key + device-ca.crt  CA that only signs device certs at pairing;
//!                                 the server trusts client certs it signed
//! ```
//!
//! `create` makes both on `init` and never overwrites; `load` reads them on
//! `run`. Losing this folder means every device must pair again.

use std::fs::{self, DirBuilder, OpenOptions};
use std::io::{self, Write};
use std::os::unix::fs::{DirBuilderExt, OpenOptionsExt};
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use haotrannas_core::fingerprint::CertFingerprint;
use haotrannas_core::tls::{SERVER_DNS_NAME, TlsSetupError, server_config};
use rcgen::{
    BasicConstraints, CertificateParams, DistinguishedName, DnType, ExtendedKeyUsagePurpose, IsCa,
    Issuer, KeyPair, KeyUsagePurpose,
};
use rustls::ServerConfig;
use rustls_pki_types::CertificateDer;
use rustls_pki_types::pem::PemObject;

pub const SERVER_KEY_FILE: &str = "server.key";
pub const SERVER_CERT_FILE: &str = "server.crt";
pub const DEVICE_CA_KEY_FILE: &str = "device-ca.key";
pub const DEVICE_CA_CERT_FILE: &str = "device-ca.crt";

/// Common name of the server leaf certificate.
const SERVER_COMMON_NAME: &str = "HaoTranNAS server";

/// Common name of the device CA. `load` rebuilds the issuer from this, so it
/// must never change: device certs name it as their issuer.
const DEVICE_CA_COMMON_NAME: &str = "HaoTranNAS device CA";

/// Certificates start one day in the past, so a device clock that is a bit
/// behind still accepts them.
const BACKDATE_SECONDS: u64 = 24 * 60 * 60;

/// Certificates are valid for 100 years (36 525 days); they are revoked by
/// removing the device row, not by expiry.
const VALIDITY_SECONDS: u64 = 36_525 * 24 * 60 * 60;

/// `tls/` holds private keys: owner only.
const TLS_DIRECTORY_MODE: u32 = 0o700;
const KEY_FILE_MODE: u32 = 0o600;
const CERT_FILE_MODE: u32 = 0o644;

#[derive(Debug, thiserror::Error)]
pub enum TlsIdentityError {
    #[error("{0} already exists; refusing to overwrite the TLS identity")]
    AlreadyExists(PathBuf),
    #[error("{path}: {source}")]
    Io {
        path: PathBuf,
        #[source]
        source: io::Error,
    },
    #[error("{path}: not a PEM certificate: {source}")]
    BadCertificateFile {
        path: PathBuf,
        #[source]
        source: rustls_pki_types::pem::Error,
    },
    #[error("{path}: not a usable private key: {source}")]
    BadKeyFile {
        path: PathBuf,
        #[source]
        source: rcgen::Error,
    },
    #[error("certificate generation: {0}")]
    Certificate(#[from] rcgen::Error),
    #[error(transparent)]
    TlsSetup(#[from] TlsSetupError),
}

/// A device certificate made at pairing: exactly what `PairOk` carries.
#[derive(Clone)]
pub struct IssuedDeviceCert {
    pub cert_der: Vec<u8>,
    /// PKCS#8 DER. Sent once in `PairOk`, never stored or logged by the server.
    pub key_pkcs8_der: Vec<u8>,
    /// SHA-256 of `cert_der`, stored in `devices.cert_sha256`.
    pub fingerprint: CertFingerprint,
}

impl std::fmt::Debug for IssuedDeviceCert {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("IssuedDeviceCert")
            .field("fingerprint", &self.fingerprint.to_hex())
            .field("key_pkcs8_der", &"<key redacted>")
            .finish_non_exhaustive()
    }
}

/// The loaded server identity and device CA.
pub struct TlsIdentity {
    server_cert_der: Vec<u8>,
    server_key_pkcs8_der: Vec<u8>,
    device_ca_cert_der: Vec<u8>,
    device_ca_issuer: Issuer<'static, KeyPair>,
    server_fingerprint: CertFingerprint,
}

impl TlsIdentity {
    /// Make new server and device CA keys and certs and write them as PEM
    /// files into `tls_directory` (created with mode 0700 if missing; key
    /// files 0600). Fails if any of the four files already exists.
    pub fn create(tls_directory: &Path) -> Result<Self, TlsIdentityError> {
        let file_paths = [
            SERVER_KEY_FILE,
            SERVER_CERT_FILE,
            DEVICE_CA_KEY_FILE,
            DEVICE_CA_CERT_FILE,
        ]
        .map(|file_name| tls_directory.join(file_name));
        if let Some(existing_path) = file_paths.iter().find(|path| path.exists()) {
            return Err(TlsIdentityError::AlreadyExists(existing_path.clone()));
        }

        let server_key = KeyPair::generate()?;
        let mut server_params = CertificateParams::new(vec![SERVER_DNS_NAME.to_owned()])?;
        server_params.distinguished_name = common_name(SERVER_COMMON_NAME);
        server_params.key_usages = vec![KeyUsagePurpose::DigitalSignature];
        server_params.extended_key_usages = vec![ExtendedKeyUsagePurpose::ServerAuth];
        set_validity_from_now(&mut server_params);
        let server_cert = server_params.self_signed(&server_key)?;

        let device_ca_key = KeyPair::generate()?;
        let mut device_ca_params = device_ca_params();
        set_validity_from_now(&mut device_ca_params);
        let device_ca_cert = device_ca_params.self_signed(&device_ca_key)?;

        DirBuilder::new()
            .recursive(true)
            .mode(TLS_DIRECTORY_MODE)
            .create(tls_directory)
            .map_err(|source| TlsIdentityError::Io {
                path: tls_directory.to_path_buf(),
                source,
            })?;
        let [
            server_key_path,
            server_cert_path,
            device_ca_key_path,
            device_ca_cert_path,
        ] = file_paths;
        write_new_file(&server_key_path, &server_key.serialize_pem(), KEY_FILE_MODE)?;
        write_new_file(&server_cert_path, &server_cert.pem(), CERT_FILE_MODE)?;
        write_new_file(
            &device_ca_key_path,
            &device_ca_key.serialize_pem(),
            KEY_FILE_MODE,
        )?;
        write_new_file(&device_ca_cert_path, &device_ca_cert.pem(), CERT_FILE_MODE)?;

        Ok(Self::from_parts(
            server_cert.der().to_vec(),
            &server_key,
            device_ca_cert.der().to_vec(),
            device_ca_key,
        ))
    }

    /// Read the four PEM files from `tls_directory`. Also checks that the
    /// server key matches the server cert.
    pub fn load(tls_directory: &Path) -> Result<Self, TlsIdentityError> {
        let server_key = read_key(&tls_directory.join(SERVER_KEY_FILE))?;
        let server_cert_der = read_cert_der(&tls_directory.join(SERVER_CERT_FILE))?;
        let device_ca_key = read_key(&tls_directory.join(DEVICE_CA_KEY_FILE))?;
        let device_ca_cert_der = read_cert_der(&tls_directory.join(DEVICE_CA_CERT_FILE))?;
        let identity = Self::from_parts(
            server_cert_der,
            &server_key,
            device_ca_cert_der,
            device_ca_key,
        );
        identity.server_config()?;
        Ok(identity)
    }

    fn from_parts(
        server_cert_der: Vec<u8>,
        server_key: &KeyPair,
        device_ca_cert_der: Vec<u8>,
        device_ca_key: KeyPair,
    ) -> Self {
        Self {
            server_fingerprint: CertFingerprint::of_der(&server_cert_der),
            server_cert_der,
            server_key_pkcs8_der: server_key.serialize_der(),
            device_ca_cert_der,
            // The issuer needs only the CA's name, key usages and key; they
            // are rebuilt from constants, so no X.509 parser is needed.
            device_ca_issuer: Issuer::new(device_ca_params(), device_ca_key),
        }
    }

    /// SHA-256 of the server cert: what clients pin.
    pub fn server_fingerprint(&self) -> CertFingerprint {
        self.server_fingerprint
    }

    /// New key and cert for a device (spec §7): ECDSA P-256, signed by the
    /// device CA, CN `device-<device_id>`, EKU clientAuth, valid from now
    /// minus one day for 100 years.
    pub fn issue_device_cert(&self, device_id: u64) -> Result<IssuedDeviceCert, TlsIdentityError> {
        let device_key = KeyPair::generate()?;
        let mut params = CertificateParams::default();
        params.distinguished_name = common_name(&format!("device-{device_id}"));
        params.is_ca = IsCa::NoCa;
        params.key_usages = vec![KeyUsagePurpose::DigitalSignature];
        params.extended_key_usages = vec![ExtendedKeyUsagePurpose::ClientAuth];
        set_validity_from_now(&mut params);
        let device_cert = params.signed_by(&device_key, &self.device_ca_issuer)?;
        let cert_der = device_cert.der().to_vec();
        Ok(IssuedDeviceCert {
            fingerprint: CertFingerprint::of_der(&cert_der),
            cert_der,
            key_pkcs8_der: device_key.serialize_der(),
        })
    }

    /// rustls server config: this leaf, device certs from this device CA.
    pub fn server_config(&self) -> Result<Arc<ServerConfig>, TlsSetupError> {
        server_config(
            &self.server_cert_der,
            &self.server_key_pkcs8_der,
            &self.device_ca_cert_der,
        )
    }
}

/// Device CA params without validity: used to sign the CA cert on `create`
/// and to rebuild the issuer on `load`.
fn device_ca_params() -> CertificateParams {
    let mut params = CertificateParams::default();
    params.distinguished_name = common_name(DEVICE_CA_COMMON_NAME);
    params.is_ca = IsCa::Ca(BasicConstraints::Unconstrained);
    params.key_usages = vec![KeyUsagePurpose::KeyCertSign, KeyUsagePurpose::CrlSign];
    params
}

fn common_name(name: &str) -> DistinguishedName {
    let mut distinguished_name = DistinguishedName::new();
    distinguished_name.push(DnType::CommonName, name);
    distinguished_name
}

/// Valid from now minus one day until now plus 100 years.
fn set_validity_from_now(params: &mut CertificateParams) {
    let now_since_epoch = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .expect("system clock is after 1970");
    // rcgen dates are `time::OffsetDateTime`; start from the epoch so this
    // crate needs no direct `time` dependency.
    let unix_epoch = rcgen::date_time_ymd(1970, 1, 1);
    let not_before = unix_epoch + now_since_epoch - Duration::from_secs(BACKDATE_SECONDS);
    params.not_before = not_before;
    params.not_after = not_before + Duration::from_secs(BACKDATE_SECONDS + VALIDITY_SECONDS);
}

/// Write `contents` to a file that must not exist yet, with `mode`, synced.
fn write_new_file(path: &Path, contents: &str, mode: u32) -> Result<(), TlsIdentityError> {
    let to_io_error = |source| TlsIdentityError::Io {
        path: path.to_path_buf(),
        source,
    };
    let mut file = OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(mode)
        .open(path)
        .map_err(|source| {
            if source.kind() == io::ErrorKind::AlreadyExists {
                TlsIdentityError::AlreadyExists(path.to_path_buf())
            } else {
                to_io_error(source)
            }
        })?;
    file.write_all(contents.as_bytes()).map_err(to_io_error)?;
    file.sync_all().map_err(to_io_error)
}

fn read_key(path: &Path) -> Result<KeyPair, TlsIdentityError> {
    let key_pem = fs::read_to_string(path).map_err(|source| TlsIdentityError::Io {
        path: path.to_path_buf(),
        source,
    })?;
    KeyPair::from_pem(&key_pem).map_err(|source| TlsIdentityError::BadKeyFile {
        path: path.to_path_buf(),
        source,
    })
}

fn read_cert_der(path: &Path) -> Result<Vec<u8>, TlsIdentityError> {
    CertificateDer::from_pem_file(path)
        .map(|cert_der| cert_der.to_vec())
        .map_err(|source| TlsIdentityError::BadCertificateFile {
            path: path.to_path_buf(),
            source,
        })
}

#[cfg(test)]
mod tests {
    use std::os::unix::fs::PermissionsExt;
    use std::sync::Arc;

    use haotrannas_core::fingerprint::CertFingerprint;
    use haotrannas_core::tls::{
        ClientIdentity, ServerPin, TofuRecorder, client_config, server_name,
    };
    use rustls::{ClientConfig, ProtocolVersion, ServerConfig};
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    use tokio_rustls::{TlsAcceptor, TlsConnector};

    use super::{
        DEVICE_CA_CERT_FILE, DEVICE_CA_KEY_FILE, IssuedDeviceCert, SERVER_CERT_FILE,
        SERVER_KEY_FILE, TlsIdentity, TlsIdentityError,
    };

    /// In-memory pipe size for the handshake tests.
    const PIPE_BYTES: usize = 64 * 1024;
    const PING: &[u8; 4] = b"ping";
    const PONG: &[u8; 4] = b"pong";

    /// What the server side saw in a successful handshake.
    #[derive(Debug)]
    struct ServerView {
        peer_fingerprint: Option<CertFingerprint>,
        protocol_version: Option<ProtocolVersion>,
    }

    /// Run one connection over an in-memory pipe. The client writes "ping"
    /// and reads; the server, after a good handshake, reads "ping" and
    /// answers "pong". Returns the server's view (or its handshake error
    /// text) and the client's result (handshake error, or the reply).
    async fn connect(
        server_config: Arc<ServerConfig>,
        client_config: Arc<ClientConfig>,
    ) -> (Result<ServerView, String>, Result<Vec<u8>, String>) {
        let (client_pipe, server_pipe) = tokio::io::duplex(PIPE_BYTES);
        let server_task = tokio::spawn(async move {
            let mut stream = TlsAcceptor::from(server_config)
                .accept(server_pipe)
                .await
                .map_err(|error| error.to_string())?;
            let connection = stream.get_ref().1;
            let view = ServerView {
                peer_fingerprint: connection
                    .peer_certificates()
                    .and_then(|certs| certs.first())
                    .map(|cert_der| CertFingerprint::of_der(cert_der)),
                protocol_version: connection.protocol_version(),
            };
            let mut request = [0u8; 4];
            stream
                .read_exact(&mut request)
                .await
                .map_err(|error| error.to_string())?;
            assert_eq!(&request, PING);
            stream
                .write_all(PONG)
                .await
                .map_err(|error| error.to_string())?;
            stream.flush().await.map_err(|error| error.to_string())?;
            Ok(view)
        });

        let client_result = async {
            let mut stream = TlsConnector::from(client_config)
                .connect(server_name(), client_pipe)
                .await
                .map_err(|error| format!("connect: {error}"))?;
            stream
                .write_all(PING)
                .await
                .map_err(|error| format!("write: {error}"))?;
            stream
                .flush()
                .await
                .map_err(|error| format!("write: {error}"))?;
            let mut reply = vec![0u8; PONG.len()];
            stream
                .read_exact(&mut reply)
                .await
                .map_err(|error| format!("read: {error}"))?;
            Ok(reply)
        }
        .await;
        (server_task.await.unwrap(), client_result)
    }

    fn device_identity(issued: &IssuedDeviceCert) -> ClientIdentity {
        ClientIdentity {
            cert_der: issued.cert_der.clone(),
            key_pkcs8_der: issued.key_pkcs8_der.clone(),
        }
    }

    #[test]
    fn create_then_load_gives_same_identity() {
        let tls_directory = tempfile::tempdir().unwrap();
        let created = TlsIdentity::create(tls_directory.path()).unwrap();
        let loaded = TlsIdentity::load(tls_directory.path()).unwrap();
        assert_eq!(created.server_fingerprint(), loaded.server_fingerprint());
        assert_eq!(
            CertFingerprint::of_der(&created.device_ca_cert_der),
            CertFingerprint::of_der(&loaded.device_ca_cert_der)
        );
        assert_eq!(created.server_key_pkcs8_der, loaded.server_key_pkcs8_der);
    }

    #[test]
    fn create_refuses_to_overwrite() {
        let tls_directory = tempfile::tempdir().unwrap();
        let created = TlsIdentity::create(tls_directory.path()).unwrap();
        let second_try = TlsIdentity::create(tls_directory.path());
        assert!(matches!(
            second_try,
            Err(TlsIdentityError::AlreadyExists(_))
        ));
        // The first identity is still the one on disk.
        let loaded = TlsIdentity::load(tls_directory.path()).unwrap();
        assert_eq!(created.server_fingerprint(), loaded.server_fingerprint());
    }

    #[test]
    fn create_refuses_when_only_one_file_exists() {
        let tls_directory = tempfile::tempdir().unwrap();
        std::fs::write(tls_directory.path().join(DEVICE_CA_CERT_FILE), "old").unwrap();
        let result = TlsIdentity::create(tls_directory.path());
        assert!(matches!(result, Err(TlsIdentityError::AlreadyExists(_))));
        assert!(!tls_directory.path().join(SERVER_KEY_FILE).exists());
    }

    #[test]
    fn key_files_are_owner_only() {
        let parent_directory = tempfile::tempdir().unwrap();
        let tls_directory = parent_directory.path().join("tls");
        TlsIdentity::create(&tls_directory).unwrap();
        let mode_of =
            |path: &std::path::Path| std::fs::metadata(path).unwrap().permissions().mode() & 0o777;
        assert_eq!(mode_of(&tls_directory.join(SERVER_KEY_FILE)), 0o600);
        assert_eq!(mode_of(&tls_directory.join(DEVICE_CA_KEY_FILE)), 0o600);
        assert_eq!(mode_of(&tls_directory.join(SERVER_CERT_FILE)), 0o644);
        assert_eq!(mode_of(&tls_directory), 0o700);
    }

    #[test]
    fn load_fails_on_missing_directory() {
        let parent_directory = tempfile::tempdir().unwrap();
        let result = TlsIdentity::load(&parent_directory.path().join("missing"));
        assert!(matches!(result, Err(TlsIdentityError::Io { .. })));
    }

    #[test]
    fn issued_device_cert_debug_hides_key() {
        let tls_directory = tempfile::tempdir().unwrap();
        let identity = TlsIdentity::create(tls_directory.path()).unwrap();
        let issued = identity.issue_device_cert(7).unwrap();
        assert_eq!(
            issued.fingerprint,
            CertFingerprint::of_der(&issued.cert_der)
        );
        assert!(format!("{issued:?}").contains("<key redacted>"));
    }

    #[tokio::test]
    async fn paired_device_handshake_over_tls13() {
        let tls_directory = tempfile::tempdir().unwrap();
        let identity = TlsIdentity::create(tls_directory.path()).unwrap();
        let issued = identity.issue_device_cert(1).unwrap();
        let client = client_config(
            ServerPin::Fingerprint(identity.server_fingerprint()),
            Some(device_identity(&issued)),
        )
        .unwrap();

        let (server_view, client_result) = connect(identity.server_config().unwrap(), client).await;

        let server_view = server_view.unwrap();
        assert_eq!(server_view.peer_fingerprint, Some(issued.fingerprint));
        assert_eq!(server_view.protocol_version, Some(ProtocolVersion::TLSv1_3));
        assert_eq!(client_result.unwrap(), PONG);
    }

    #[tokio::test]
    async fn device_cert_still_works_after_reload() {
        let tls_directory = tempfile::tempdir().unwrap();
        let issued = TlsIdentity::create(tls_directory.path())
            .unwrap()
            .issue_device_cert(2)
            .unwrap();
        let reloaded = TlsIdentity::load(tls_directory.path()).unwrap();
        let client = client_config(
            ServerPin::Fingerprint(reloaded.server_fingerprint()),
            Some(device_identity(&issued)),
        )
        .unwrap();

        let (server_view, client_result) = connect(reloaded.server_config().unwrap(), client).await;

        assert_eq!(
            server_view.unwrap().peer_fingerprint,
            Some(issued.fingerprint)
        );
        assert_eq!(client_result.unwrap(), PONG);
    }

    #[tokio::test]
    async fn device_cert_issued_after_reload_works() {
        let tls_directory = tempfile::tempdir().unwrap();
        TlsIdentity::create(tls_directory.path()).unwrap();
        let reloaded = TlsIdentity::load(tls_directory.path()).unwrap();
        let issued = reloaded.issue_device_cert(3).unwrap();
        let client = client_config(
            ServerPin::Fingerprint(reloaded.server_fingerprint()),
            Some(device_identity(&issued)),
        )
        .unwrap();

        let (server_view, client_result) = connect(reloaded.server_config().unwrap(), client).await;

        assert_eq!(
            server_view.unwrap().peer_fingerprint,
            Some(issued.fingerprint)
        );
        assert_eq!(client_result.unwrap(), PONG);
    }

    #[tokio::test]
    async fn unpaired_client_without_cert_is_accepted() {
        let tls_directory = tempfile::tempdir().unwrap();
        let identity = TlsIdentity::create(tls_directory.path()).unwrap();
        let client =
            client_config(ServerPin::Fingerprint(identity.server_fingerprint()), None).unwrap();

        let (server_view, client_result) = connect(identity.server_config().unwrap(), client).await;

        assert_eq!(server_view.unwrap().peer_fingerprint, None);
        assert_eq!(client_result.unwrap(), PONG);
    }

    /// TLS 1.3: the client's handshake ends before the server has checked
    /// the client cert, so `connect` succeeds on the client. The server's
    /// rejection (a TLS alert) only shows on the client's first read. This
    /// is why spec §6 says a client that loses the connection before
    /// `HelloOk` must treat it as "maybe not paired".
    #[tokio::test]
    async fn device_cert_from_other_ca_is_refused() {
        let tls_directory = tempfile::tempdir().unwrap();
        let identity = TlsIdentity::create(tls_directory.path()).unwrap();
        let other_directory = tempfile::tempdir().unwrap();
        let other_identity = TlsIdentity::create(other_directory.path()).unwrap();
        let foreign_cert = other_identity.issue_device_cert(1).unwrap();
        let client = client_config(
            ServerPin::Fingerprint(identity.server_fingerprint()),
            Some(device_identity(&foreign_cert)),
        )
        .unwrap();

        let (server_view, client_result) = connect(identity.server_config().unwrap(), client).await;

        assert!(server_view.is_err(), "server must refuse: {server_view:?}");
        let client_error = client_result.unwrap_err();
        assert!(
            client_error.starts_with("read:"),
            "client sees the refusal on its first read, not on connect: {client_error}"
        );
    }

    #[tokio::test]
    async fn wrong_pin_is_refused_and_tofu_records_real_fingerprint() {
        let tls_directory = tempfile::tempdir().unwrap();
        let identity = TlsIdentity::create(tls_directory.path()).unwrap();
        let wrong_pin = CertFingerprint::of_der(b"some other server");
        let pinned_client = client_config(ServerPin::Fingerprint(wrong_pin), None).unwrap();

        let (server_view, client_result) =
            connect(identity.server_config().unwrap(), pinned_client).await;

        assert!(server_view.is_err());
        let client_error = client_result.unwrap_err();
        assert!(client_error.starts_with("connect:"), "{client_error}");

        let recorder = TofuRecorder::new();
        let pairing_client =
            client_config(ServerPin::RecordFirstSeen(recorder.clone()), None).unwrap();
        let (server_view, client_result) =
            connect(identity.server_config().unwrap(), pairing_client).await;

        assert!(server_view.is_ok());
        assert_eq!(client_result.unwrap(), PONG);
        assert_eq!(
            recorder.seen_fingerprint(),
            Some(identity.server_fingerprint())
        );
    }
}
