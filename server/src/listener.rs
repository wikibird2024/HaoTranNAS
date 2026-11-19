//! The accept loop: accepts TCP connections and spawns one session task per
//! connection, at most `max_connections` at once (more are refused). Stops
//! accepting when shutdown starts; the sessions then send
//! `Close SERVER_SHUTDOWN` themselves.
//!
//! ```text
//!  accept ─► slot free? ─► task:
//!     dev-plain: plain TCP, the dev device ─────────────────────────────► session
//!     TLS:       handshake (within HANDSHAKE_TIMEOUT_MS of accept)
//!                ─► client cert? none → NoCertificate (may pair)
//!                                fingerprint in devices, not revoked → Device(id)
//!                                else → UnknownCertificate (Hello gets NOT_PAIRED)
//!                ─► session
//! ```
//!
//! The device CA check is rustls's (`WebPkiClientVerifier`): a cert from
//! another CA fails the handshake, which the client sees on its first read.

use std::net::SocketAddr;
use std::sync::Arc;
use std::time::Duration;

use haotrannas_core::fingerprint::CertFingerprint;
use tokio::net::{TcpListener, TcpStream};
use tokio::sync::{Semaphore, watch};
use tokio::task::JoinSet;
use tokio::time::Instant;
use tokio_rustls::TlsAcceptor;
use tokio_rustls::server::TlsStream;

use crate::catalog::reader::CatalogReader;
use crate::session::{Peer, PeerIdentity, SessionSettings, run_session};

/// Pause after a failed accept (for example too many open files), so the
/// loop does not spin.
const ACCEPT_RETRY_DELAY_MS: u64 = 100;

/// Counts open connections and caps them at `max_connections`.
#[derive(Debug, Clone)]
pub struct ConnectionLimit {
    free_slots: Arc<Semaphore>,
    max_connections: usize,
}

impl ConnectionLimit {
    /// Room for `max_connections` connections at once.
    pub fn new(max_connections: usize) -> Self {
        Self {
            free_slots: Arc::new(Semaphore::new(max_connections)),
            max_connections,
        }
    }

    /// Connections open right now.
    pub fn open_connections(&self) -> usize {
        self.max_connections - self.free_slots.available_permits()
    }
}

/// How connections are taken in.
pub enum ConnectionMode {
    /// Plain TCP (`--dev-plain`, loopback only): every connection is this
    /// device.
    DevPlain { dev_device_id: u64 },
    /// TLS 1.3; the client certificate (if any) is looked up in the catalog.
    Tls {
        acceptor: TlsAcceptor,
        catalog_reader: CatalogReader,
    },
}

/// Accepts connections until `shutdown` turns true, then waits up to
/// `shutdown_grace_ms` for the sessions to send their `Close` and end.
pub async fn serve(
    listener: TcpListener,
    connection_mode: Arc<ConnectionMode>,
    settings: Arc<SessionSettings>,
    connection_limit: ConnectionLimit,
    mut shutdown: watch::Receiver<bool>,
    shutdown_grace_ms: u64,
) {
    let mut sessions = JoinSet::new();
    loop {
        let accepted = tokio::select! {
            biased;
            _ = shutdown.wait_for(|is_stopping| *is_stopping) => break,
            accepted = listener.accept() => accepted,
        };
        // Reap finished session tasks so the set does not grow.
        while sessions.try_join_next().is_some() {}

        let (stream, peer_address) = match accepted {
            Ok(connection) => connection,
            Err(error) => {
                tracing::warn!(%error, "accept failed");
                tokio::time::sleep(Duration::from_millis(ACCEPT_RETRY_DELAY_MS)).await;
                continue;
            }
        };
        let Ok(slot) = Arc::clone(&connection_limit.free_slots).try_acquire_owned() else {
            tracing::warn!(
                %peer_address,
                max_connections = connection_limit.max_connections,
                "too many connections; refusing"
            );
            continue;
        };
        // Small request/reply frames: send each at once.
        if let Err(error) = stream.set_nodelay(true) {
            tracing::debug!(%error, "could not set TCP_NODELAY");
        }
        let accepted_at = Instant::now();
        let settings = Arc::clone(&settings);
        let connection_mode = Arc::clone(&connection_mode);
        let session_shutdown = shutdown.clone();
        sessions.spawn(async move {
            tracing::info!(%peer_address, "connection opened");
            match &*connection_mode {
                ConnectionMode::DevPlain { dev_device_id } => {
                    let peer = Peer {
                        identity: PeerIdentity::Device(*dev_device_id),
                        address: peer_address,
                        accepted_at,
                    };
                    let session_end = run_session(stream, peer, &settings, session_shutdown).await;
                    tracing::info!(%peer_address, ?session_end, "connection closed");
                }
                ConnectionMode::Tls {
                    acceptor,
                    catalog_reader,
                } => {
                    let handshake_deadline =
                        accepted_at + Duration::from_millis(settings.handshake_timeout_ms);
                    let Some(tls_stream) =
                        accept_tls(acceptor, stream, peer_address, handshake_deadline).await
                    else {
                        return;
                    };
                    let Some(identity) = identify_peer(&tls_stream, catalog_reader).await else {
                        return;
                    };
                    tracing::debug!(%peer_address, ?identity, "TLS client identified");
                    let peer = Peer {
                        identity,
                        address: peer_address,
                        accepted_at,
                    };
                    let session_end =
                        run_session(tls_stream, peer, &settings, session_shutdown).await;
                    tracing::info!(%peer_address, ?session_end, "connection closed");
                }
            }
            drop(slot);
        });
    }

    drop(listener);
    let open_sessions = sessions.len();
    if open_sessions > 0 {
        tracing::info!(open_sessions, "waiting for sessions to close");
    }
    let all_ended = async { while sessions.join_next().await.is_some() {} };
    if tokio::time::timeout(Duration::from_millis(shutdown_grace_ms), all_ended)
        .await
        .is_err()
    {
        tracing::warn!("sessions still open after the grace time; dropping them");
    }
}

/// The TLS handshake, bounded by the handshake deadline. `None` (logged)
/// when it fails: wrong protocol, a client cert from another CA, or too slow.
async fn accept_tls(
    acceptor: &TlsAcceptor,
    stream: TcpStream,
    peer_address: SocketAddr,
    handshake_deadline: Instant,
) -> Option<TlsStream<TcpStream>> {
    match tokio::time::timeout_at(handshake_deadline, acceptor.accept(stream)).await {
        Ok(Ok(tls_stream)) => Some(tls_stream),
        Ok(Err(error)) => {
            tracing::info!(%peer_address, %error, "TLS handshake failed");
            None
        }
        Err(_) => {
            tracing::info!(%peer_address, "TLS handshake timed out");
            None
        }
    }
}

/// Who the TLS client is, from its certificate. `None` (logged) when the
/// catalog cannot be read: the connection is dropped without a reply, so a
/// paired client sees "maybe not paired" and retries later, instead of a
/// wrong `NOT_PAIRED`.
async fn identify_peer(
    tls_stream: &TlsStream<TcpStream>,
    catalog_reader: &CatalogReader,
) -> Option<PeerIdentity> {
    let Some(cert_der) = tls_stream
        .get_ref()
        .1
        .peer_certificates()
        .and_then(|certs| certs.first())
    else {
        return Some(PeerIdentity::NoCertificate);
    };
    let fingerprint = CertFingerprint::of_der(cert_der);
    let catalog_reader = catalog_reader.clone();
    let lookup =
        tokio::task::spawn_blocking(move || catalog_reader.device_by_cert(&fingerprint.0)).await;
    match lookup {
        Ok(Ok(Some(device))) => Some(PeerIdentity::Device(device.device_id)),
        Ok(Ok(None)) => {
            tracing::info!(cert = %fingerprint.short_id(), "client certificate not paired (unknown or revoked)");
            Some(PeerIdentity::UnknownCertificate)
        }
        Ok(Err(error)) => {
            tracing::error!(%error, "cannot look up the client certificate");
            None
        }
        Err(join_error) => {
            tracing::error!(%join_error, "certificate lookup task failed");
            None
        }
    }
}

/// True if `address` may be used with `--dev-plain` (spec section 1:
/// loopback only, never on a network).
pub fn is_dev_plain_address_allowed(address: &SocketAddr) -> bool {
    address.ip().is_loopback()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn dev_plain_allows_loopback_only() {
        for allowed in ["127.0.0.1:0", "127.0.0.2:47100", "[::1]:0"] {
            assert!(
                is_dev_plain_address_allowed(&allowed.parse().unwrap()),
                "{allowed}"
            );
        }
        for refused in [
            "0.0.0.0:0",
            "[::]:0",
            "192.168.1.10:47100",
            "10.66.0.1:0",
            "[::ffff:127.0.0.1]:0",
        ] {
            assert!(
                !is_dev_plain_address_allowed(&refused.parse().unwrap()),
                "{refused}"
            );
        }
    }

    #[test]
    fn connection_limit_counts_open_slots() {
        let limit = ConnectionLimit::new(2);
        assert_eq!(limit.open_connections(), 0);
        let first = Arc::clone(&limit.free_slots).try_acquire_owned().unwrap();
        let second = Arc::clone(&limit.free_slots).try_acquire_owned().unwrap();
        assert_eq!(limit.open_connections(), 2);
        assert!(Arc::clone(&limit.free_slots).try_acquire_owned().is_err());
        drop(first);
        assert_eq!(limit.open_connections(), 1);
        drop(second);
    }
}
