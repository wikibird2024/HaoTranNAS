//! The accept loop: binds the port, accepts TCP connections and spawns one
//! session task per connection, at most `max_connections` at once (more are
//! refused). Stops accepting when shutdown starts; the sessions then send
//! `Close SERVER_SHUTDOWN` themselves.
//!
//! M0 serves plain TCP only (`--dev-plain`, loopback, every connection is
//! the dev device). M3 wraps each stream in TLS here and looks up the device
//! from the client certificate.

use std::net::SocketAddr;
use std::sync::Arc;
use std::time::Duration;

use tokio::net::TcpListener;
use tokio::sync::{Semaphore, watch};
use tokio::task::JoinSet;

use crate::session::{SessionSettings, run_session};

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

/// Accepts plain TCP connections until `shutdown` turns true, then waits up
/// to `shutdown_grace_ms` for the sessions to send their `Close` and end.
/// Every connection is `dev_device_id`.
pub async fn serve_dev_plain(
    listener: TcpListener,
    dev_device_id: u64,
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
        let settings = Arc::clone(&settings);
        let session_shutdown = shutdown.clone();
        sessions.spawn(async move {
            tracing::info!(%peer_address, "connection opened");
            let session_end =
                run_session(stream, Some(dev_device_id), &settings, session_shutdown).await;
            tracing::info!(%peer_address, ?session_end, "connection closed");
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
