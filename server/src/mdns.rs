//! LAN discovery (protocol/spec.md section 13, decision D-012): announces
//! `_haotrannas._tcp.local.` with mdns-sd while the TLS server runs. LAN
//! only, never outside home (the NAS firewall opens UDP 5353 to the LAN).
//!
//! ```text
//!  PTR  _haotrannas._tcp.local.            -> <server_name>._haotrannas._tcp.local.
//!  SRV  <server_name>._haotrannas._tcp...  -> haotrannas-<fp>.local. : <bound port>
//!  TXT  <server_name>._haotrannas._tcp...  -> "v=1" "fp=<first 16 hex of fingerprint>"
//!  A    haotrannas-<fp>.local.             -> the IPv4 address of each LAN interface
//! ```
//!
//! IPv4 only: the firewall opens the server port on IPv4 only, so an AAAA
//! record would send clients to an address that drops them. mDNS is a
//! convenience: a failure is logged and the server keeps running (clients
//! fall back to the last known address).

use std::net::{IpAddr, Ipv4Addr};
use std::time::Duration;

use haotrannas_core::fingerprint::CertFingerprint;
use haotrannas_core::limits::PROTOCOL_VERSION;
use mdns_sd::{IfKind, ServiceDaemon, ServiceInfo};

use crate::config::ServerConfig;

/// Service type and domain (spec section 13), with the trailing dot mdns-sd wants.
pub const SERVICE_TYPE: &str = "_haotrannas._tcp.local.";

/// TXT key for the protocol version.
pub const VERSION_TXT_KEY: &str = "v";

/// TXT key for the fingerprint prefix ([`CertFingerprint::mdns_prefix`]).
pub const FINGERPRINT_TXT_KEY: &str = "fp";

/// How long stopping waits for the goodbye packets and the daemon thread.
const STOP_TIMEOUT_MS: u64 = 1_000;

#[derive(Debug, thiserror::Error)]
pub enum MdnsError {
    #[error("mDNS: {0}")]
    Daemon(#[from] mdns_sd::Error),
    #[error(
        "mDNS announces IPv4 addresses only (protocol/spec.md section 13), \
         but the server listens on {0}"
    )]
    NotIpv4(IpAddr),
}

/// Which IPv4 addresses the A records carry.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum AnnouncedAddresses {
    /// The server listens on every address: each IPv4 interface announces
    /// its own address, kept up to date when addresses change.
    EveryIpv4Interface,
    /// The server listens on one IPv4 address: only that one.
    Only(Ipv4Addr),
}

/// The A records follow the listen address: never announce an address the
/// server does not accept connections on.
fn announced_addresses(listen_ip: IpAddr) -> Result<AnnouncedAddresses, MdnsError> {
    match listen_ip {
        IpAddr::V4(ipv4) if ipv4.is_unspecified() => Ok(AnnouncedAddresses::EveryIpv4Interface),
        IpAddr::V4(ipv4) => Ok(AnnouncedAddresses::Only(ipv4)),
        // `[::]` on Linux is dual-stack: it accepts IPv4 too.
        IpAddr::V6(ipv6) if ipv6.is_unspecified() => Ok(AnnouncedAddresses::EveryIpv4Interface),
        IpAddr::V6(ipv6) => ipv6
            .to_ipv4_mapped()
            .map(AnnouncedAddresses::Only)
            .ok_or(MdnsError::NotIpv4(listen_ip)),
    }
}

/// The TXT records: `v=<protocol version>`, `fp=<fingerprint prefix>`.
pub fn txt_records(server_fingerprint: &CertFingerprint) -> [(&'static str, String); 2] {
    [
        (VERSION_TXT_KEY, PROTOCOL_VERSION.to_string()),
        (FINGERPRINT_TXT_KEY, server_fingerprint.mdns_prefix()),
    ]
}

/// Host name of the A records: `haotrannas-<fp prefix>.local.`. Its own name,
/// so it never clashes with the `<hostname>.local.` that avahi announces.
pub fn host_name(server_fingerprint: &CertFingerprint) -> String {
    format!("haotrannas-{}.local.", server_fingerprint.mdns_prefix())
}

/// Everything announced for one server, ready for `ServiceDaemon::register`.
pub fn service_info(
    server_name: &str,
    listen_ip: IpAddr,
    port: u16,
    server_fingerprint: &CertFingerprint,
) -> Result<ServiceInfo, MdnsError> {
    let txt = txt_records(server_fingerprint);
    let host_name = host_name(server_fingerprint);
    let service_info = match announced_addresses(listen_ip)? {
        AnnouncedAddresses::EveryIpv4Interface => {
            let mut service_info =
                ServiceInfo::new(SERVICE_TYPE, server_name, &host_name, (), port, &txt[..])?
                    .enable_addr_auto();
            service_info.set_interfaces(vec![IfKind::IPv4]);
            service_info
        }
        AnnouncedAddresses::Only(ipv4) => ServiceInfo::new(
            SERVICE_TYPE,
            server_name,
            &host_name,
            IpAddr::V4(ipv4),
            port,
            &txt[..],
        )?,
    };
    Ok(service_info)
}

/// A running announcement. Dropping it sends the goodbye packets and stops
/// the mDNS thread.
pub struct Announcement {
    daemon: ServiceDaemon,
    /// Escaped full name, e.g. `haotrannas._haotrannas._tcp.local.`.
    fullname: String,
}

impl Announcement {
    /// Announce `config.server_name` on the bound TLS `port`, with the
    /// listen address from `config` deciding which IPv4 addresses go out.
    pub fn start(
        config: &ServerConfig,
        port: u16,
        server_fingerprint: &CertFingerprint,
    ) -> Result<Self, MdnsError> {
        let service_info = service_info(
            &config.server_name,
            config.listen_address.ip(),
            port,
            server_fingerprint,
        )?;
        let fullname = service_info.get_fullname().to_owned();
        let daemon = ServiceDaemon::new()?;
        if let Err(error) = daemon
            .disable_interface(IfKind::IPv6)
            .and_then(|()| daemon.register(service_info))
        {
            stop_daemon(&daemon);
            return Err(error.into());
        }
        tracing::info!(
            "mDNS: announcing {fullname} on port {port}, fp={}",
            server_fingerprint.mdns_prefix()
        );
        Ok(Self { daemon, fullname })
    }

    /// Escaped full name of the announced service (used by the live test).
    #[cfg(test)]
    pub fn fullname(&self) -> &str {
        &self.fullname
    }
}

impl Drop for Announcement {
    fn drop(&mut self) {
        let stop_timeout = Duration::from_millis(STOP_TIMEOUT_MS);
        match self.daemon.unregister(&self.fullname) {
            Ok(status_receiver) => {
                if let Err(error) = status_receiver.recv_timeout(stop_timeout) {
                    tracing::warn!("mDNS: no answer to unregister: {error}");
                }
            }
            Err(error) => tracing::warn!("mDNS: unregister failed: {error}"),
        }
        stop_daemon(&self.daemon);
        tracing::info!("mDNS: stopped announcing {}", self.fullname);
    }
}

/// Stop the mDNS thread; problems are logged only.
fn stop_daemon(daemon: &ServiceDaemon) {
    match daemon.shutdown() {
        Ok(status_receiver) => {
            if let Err(error) = status_receiver.recv_timeout(Duration::from_millis(STOP_TIMEOUT_MS))
            {
                tracing::warn!("mDNS: daemon did not confirm shutdown: {error}");
            }
        }
        Err(error) => tracing::warn!("mDNS: shutdown failed: {error}"),
    }
}

/// What `run` calls once the TLS listener is bound. `None` when
/// `mdns_enabled` is off or the announcement failed (logged, not fatal).
pub fn start_if_enabled(
    config: &ServerConfig,
    port: u16,
    server_fingerprint: &CertFingerprint,
) -> Option<Announcement> {
    if !config.mdns_enabled {
        tracing::info!("mDNS: off (mdns_enabled = false)");
        return None;
    }
    match Announcement::start(config, port, server_fingerprint) {
        Ok(announcement) => Some(announcement),
        Err(error) => {
            tracing::warn!("{error}; clients must use the address directly");
            None
        }
    }
}

#[cfg(test)]
mod tests {
    use std::net::{IpAddr, Ipv4Addr, Ipv6Addr};

    use haotrannas_core::fingerprint::CertFingerprint;

    use super::{
        AnnouncedAddresses, MdnsError, SERVICE_TYPE, announced_addresses, host_name, service_info,
        txt_records,
    };

    /// SHA-256("abc"): its mDNS prefix is `ba7816bf8f01cfea`.
    fn abc_fingerprint() -> CertFingerprint {
        CertFingerprint::of_der(b"abc")
    }

    #[test]
    fn txt_records_are_version_and_fingerprint_prefix() {
        let txt = txt_records(&abc_fingerprint());
        assert_eq!(
            txt,
            [("v", "1".to_owned()), ("fp", "ba7816bf8f01cfea".to_owned())]
        );
    }

    #[test]
    fn host_name_is_its_own_local_name() {
        assert_eq!(
            host_name(&abc_fingerprint()),
            "haotrannas-ba7816bf8f01cfea.local."
        );
    }

    #[test]
    fn announced_addresses_follow_the_listen_address() {
        let cases = [
            (
                IpAddr::V4(Ipv4Addr::UNSPECIFIED),
                AnnouncedAddresses::EveryIpv4Interface,
            ),
            (
                IpAddr::V6(Ipv6Addr::UNSPECIFIED),
                AnnouncedAddresses::EveryIpv4Interface,
            ),
            (
                IpAddr::V4(Ipv4Addr::new(192, 168, 1, 20)),
                AnnouncedAddresses::Only(Ipv4Addr::new(192, 168, 1, 20)),
            ),
            (
                IpAddr::V6(Ipv4Addr::new(192, 168, 1, 20).to_ipv6_mapped()),
                AnnouncedAddresses::Only(Ipv4Addr::new(192, 168, 1, 20)),
            ),
        ];
        for (listen_ip, expected) in cases {
            assert_eq!(
                announced_addresses(listen_ip).unwrap(),
                expected,
                "{listen_ip}"
            );
        }
    }

    #[test]
    fn an_ipv6_only_listen_address_is_refused() {
        let listen_ip = IpAddr::V6(Ipv6Addr::LOCALHOST);
        assert!(matches!(
            service_info("haotrannas", listen_ip, 47_100, &abc_fingerprint()),
            Err(MdnsError::NotIpv4(ip)) if ip == listen_ip
        ));
    }

    #[test]
    fn service_info_on_every_interface_tracks_ipv4_addresses() {
        let info = service_info(
            "haotrannas",
            IpAddr::V4(Ipv4Addr::UNSPECIFIED),
            47_100,
            &abc_fingerprint(),
        )
        .unwrap();
        assert_eq!(info.get_type(), SERVICE_TYPE);
        assert_eq!(info.get_fullname(), "haotrannas._haotrannas._tcp.local.");
        assert_eq!(info.get_hostname(), "haotrannas-ba7816bf8f01cfea.local.");
        assert_eq!(info.get_port(), 47_100);
        assert_eq!(info.get_property_val_str("v"), Some("1"));
        assert_eq!(info.get_property_val_str("fp"), Some("ba7816bf8f01cfea"));
        assert!(info.is_addr_auto());
        assert!(info.get_addresses_v4().is_empty());
    }

    #[test]
    fn service_info_on_one_address_announces_only_it() {
        let listen_ip = Ipv4Addr::new(192, 168, 1, 20);
        let info = service_info(
            "Hao's NAS",
            IpAddr::V4(listen_ip),
            50_000,
            &abc_fingerprint(),
        )
        .unwrap();
        assert!(!info.is_addr_auto());
        assert_eq!(
            info.get_addresses_v4().into_iter().collect::<Vec<_>>(),
            [&listen_ip]
        );
        assert_eq!(info.get_port(), 50_000);
        assert_eq!(info.get_fullname(), "Hao's NAS._haotrannas._tcp.local.");
    }
}

/// Real multicast on this machine. Ignored by default: CI runners often
/// have no multicast. Run: `cargo test -p haotrannas-server mdns -- --ignored`.
#[cfg(test)]
mod lan_tests {
    use std::net::{IpAddr, Ipv4Addr, SocketAddr, UdpSocket};
    use std::path::PathBuf;
    use std::time::{Duration, Instant};

    use haotrannas_core::fingerprint::CertFingerprint;
    use mdns_sd::{IfKind, ServiceDaemon, ServiceEvent};

    use super::{Announcement, SERVICE_TYPE, service_info};
    use crate::config::ServerConfig;

    const BROWSE_TIMEOUT_MS: u64 = 10_000;

    /// Set to `1` to (re)write `protocol/fixtures/mdns_announcement.hex`.
    const WRITE_FIXTURE_VARIABLE: &str = "HAOTRANNAS_WRITE_MDNS_FIXTURE";

    #[test]
    #[ignore = "needs multicast on a real network interface"]
    fn mdns_announcement_is_found_by_a_browser() {
        let config = ServerConfig {
            server_name: format!("haotrannas-test-{}", std::process::id()),
            ..ServerConfig::default()
        };
        let port = 47_199;
        let fingerprint = CertFingerprint::of_der(config.server_name.as_bytes());
        let announcement = Announcement::start(&config, port, &fingerprint).unwrap();

        let browser = ServiceDaemon::new().unwrap();
        browser.disable_interface(IfKind::IPv6).unwrap();
        let events = browser.browse(SERVICE_TYPE).unwrap();
        let deadline = Instant::now() + Duration::from_millis(BROWSE_TIMEOUT_MS);
        let resolved = loop {
            match events.recv_deadline(deadline) {
                Ok(ServiceEvent::ServiceResolved(service))
                    if service.get_fullname() == announcement.fullname() =>
                {
                    break service;
                }
                Ok(_) => {}
                Err(error) => panic!("not found within {BROWSE_TIMEOUT_MS} ms: {error}"),
            }
        };
        browser.shutdown().unwrap();

        assert_eq!(resolved.get_port(), port);
        assert_eq!(
            resolved.get_property_val_str("fp"),
            Some(fingerprint.mdns_prefix().as_str())
        );
        assert_eq!(resolved.get_property_val_str("v"), Some("1"));
        assert!(!resolved.get_addresses_v4().is_empty());
    }

    /// Records one real answer to a PTR query for the Dart decoder tests.
    ///
    /// The query is sent from an ephemeral port to 127.0.0.1:5353, so the
    /// responder treats it as a legacy unicast query (RFC 6762 §6.7) and
    /// answers to that port: no root needed, no clash with avahi. Avahi may
    /// get the datagram instead (both bind 5353), so it retries from new ports.
    #[test]
    #[ignore = "needs the mDNS port 5353 on this machine"]
    fn mdns_capture_ptr_answer_fixture() {
        let fingerprint = CertFingerprint::of_der(b"abc");
        let info = service_info(
            "haotrannas",
            IpAddr::V4(Ipv4Addr::LOCALHOST),
            47_100,
            &fingerprint,
        )
        .unwrap();
        let daemon = ServiceDaemon::new().unwrap();
        daemon.disable_interface(IfKind::IPv6).unwrap();
        daemon.register(info).unwrap();

        let query = ptr_query(SERVICE_TYPE);
        let fingerprint_txt = format!("fp={}", fingerprint.mdns_prefix());
        let responder = SocketAddr::from((Ipv4Addr::LOCALHOST, mdns_sd::MDNS_PORT));
        let deadline = Instant::now() + Duration::from_millis(BROWSE_TIMEOUT_MS);
        let answer = loop {
            assert!(Instant::now() < deadline, "no answer to the PTR query");
            let socket = UdpSocket::bind((Ipv4Addr::LOCALHOST, 0)).unwrap();
            socket
                .set_read_timeout(Some(Duration::from_millis(500)))
                .unwrap();
            socket.send_to(&query, responder).unwrap();
            let mut buffer = [0u8; 9_000];
            if let Ok((length, _)) = socket.recv_from(&mut buffer) {
                let packet = &buffer[..length];
                // Only our answer: another haotrannas on the LAN has another fp.
                if contains(packet, fingerprint_txt.as_bytes()) {
                    break packet.to_vec();
                }
            }
        };
        daemon.shutdown().unwrap();

        assert!(contains(&answer, b"\x0b_haotrannas\x04_tcp\x05local"));
        assert!(contains(&answer, &47_100u16.to_be_bytes()));
        assert!(contains(&answer, &[127, 0, 0, 1]));

        if std::env::var(WRITE_FIXTURE_VARIABLE).as_deref() == Ok("1") {
            let fixture_path = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
                .join("../protocol/fixtures/mdns_announcement.hex");
            let hex_lines: Vec<String> = answer.chunks(32).map(hex::encode).collect();
            std::fs::write(&fixture_path, hex_lines.join("\n") + "\n").unwrap();
            println!("wrote {} ({} bytes)", fixture_path.display(), answer.len());
        }
    }

    /// A one-question DNS query: `<name> PTR IN`, id 0x4854 ("HT").
    fn ptr_query(name: &str) -> Vec<u8> {
        const QUERY_ID: u16 = 0x4854;
        const TYPE_PTR: u16 = 12;
        const CLASS_IN: u16 = 1;
        let mut packet = Vec::new();
        packet.extend_from_slice(&QUERY_ID.to_be_bytes());
        // flags 0 (standard query), 1 question, 0 answers / authority / additional
        packet.extend_from_slice(&[0, 0, 0, 1, 0, 0, 0, 0, 0, 0]);
        for label in name.trim_end_matches('.').split('.') {
            packet.push(u8::try_from(label.len()).unwrap());
            packet.extend_from_slice(label.as_bytes());
        }
        packet.push(0);
        packet.extend_from_slice(&TYPE_PTR.to_be_bytes());
        packet.extend_from_slice(&CLASS_IN.to_be_bytes());
        packet
    }

    fn contains(haystack: &[u8], needle: &[u8]) -> bool {
        haystack
            .windows(needle.len())
            .any(|window| window == needle)
    }
}
