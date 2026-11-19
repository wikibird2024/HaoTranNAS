//! `discover`: find HaoTranNAS servers on the LAN with mDNS
//! (protocol/spec.md section 13) and print one line per server:
//!
//! ```text
//! haotrannas  192.168.1.20:47100  fp=ba7816bf8f01cfea  v=1  (paired)
//! ```
//!
//! `(paired)` marks the server whose `fp` matches the pin in
//! `<identity-dir>/server.json`. Only the IPv4 (A record) address is used:
//! the NAS firewall opens the port on IPv4 only. Finding nothing is not an
//! error.

use std::collections::{BTreeMap, BTreeSet};
use std::io;
use std::net::Ipv4Addr;
use std::path::Path;
use std::process::ExitCode;
use std::time::{Duration, Instant};

use mdns_sd::{IfKind, ResolvedService, ServiceDaemon, ServiceEvent, instance_name_unescaped};
use serde::Deserialize;

/// Service type and domain (spec section 13); the server announces the same.
pub const SERVICE_TYPE: &str = "_haotrannas._tcp.local.";

/// How long `discover` listens by default.
pub const DEFAULT_TIMEOUT_MS: u64 = 3_000;

/// The paired server's pin inside `--identity-dir`.
const PAIRED_SERVER_FILE: &str = "server.json";

/// Hex chars of the fingerprint sent in the `fp` TXT record.
const FINGERPRINT_PREFIX_CHARS: usize = 16;

/// How long the command waits for the mDNS thread to stop.
const STOP_TIMEOUT_MS: u64 = 1_000;

/// Exit code when mDNS could not start.
const FAILURE_EXIT_CODE: u8 = 1;

#[derive(Debug, clap::Args)]
pub struct DiscoverArgs {
    /// How long to listen for answers.
    #[arg(long, default_value_t = DEFAULT_TIMEOUT_MS)]
    pub timeout_ms: u64,
}

/// One server as seen on the LAN.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DiscoveredServer {
    /// Instance name (the server's `server_name`).
    pub name: String,
    /// IPv4 addresses from the A records.
    pub ipv4_addresses: BTreeSet<Ipv4Addr>,
    pub port: u16,
    /// `fp` TXT value, if present.
    pub fingerprint_prefix: Option<String>,
    /// `v` TXT value, if present.
    pub protocol_version: Option<String>,
}

impl DiscoveredServer {
    fn from_resolved(service: &ResolvedService) -> Self {
        Self {
            name: instance_name_unescaped(service.get_fullname()),
            ipv4_addresses: service.get_addresses_v4().into_iter().collect(),
            port: service.get_port(),
            fingerprint_prefix: service.get_property_val_str("fp").map(str::to_owned),
            protocol_version: service.get_property_val_str("v").map(str::to_owned),
        }
    }

    /// The address to connect to: a LAN address before loopback (a server on
    /// this same machine answers with both).
    pub fn best_ipv4_address(&self) -> Option<Ipv4Addr> {
        self.ipv4_addresses
            .iter()
            .find(|address| !address.is_loopback())
            .or_else(|| self.ipv4_addresses.first())
            .copied()
    }

    /// `<name>  <ipv4>:<port>  fp=<prefix>  v=<v>[  (paired)]`.
    pub fn line(&self, pinned_fingerprint_hex: Option<&str>) -> String {
        let address = self
            .best_ipv4_address()
            .map_or_else(|| "?".to_owned(), |address| address.to_string());
        let fingerprint_prefix = self.fingerprint_prefix.as_deref().unwrap_or("?");
        let protocol_version = self.protocol_version.as_deref().unwrap_or("?");
        let mut line = format!(
            "{}  {address}:{}  fp={fingerprint_prefix}  v={protocol_version}",
            self.name, self.port
        );
        let is_paired = match (&self.fingerprint_prefix, pinned_fingerprint_hex) {
            (Some(prefix), Some(pin)) => is_pin_match(prefix, pin),
            _ => false,
        };
        if is_paired {
            line.push_str("  (paired)");
        }
        line
    }
}

/// True when the announced `fp` is the first 16 hex chars of the pinned
/// SHA-256 (case-insensitive). Only a hint: the TLS handshake checks the
/// full pin.
pub fn is_pin_match(fingerprint_prefix: &str, pinned_fingerprint_hex: &str) -> bool {
    fingerprint_prefix.len() == FINGERPRINT_PREFIX_CHARS
        && pinned_fingerprint_hex
            .get(..FINGERPRINT_PREFIX_CHARS)
            .is_some_and(|pin_prefix| pin_prefix.eq_ignore_ascii_case(fingerprint_prefix))
}

/// The fields of `server.json` that `discover` reads; the pairing code owns
/// the file and its other fields.
#[derive(Debug, Deserialize)]
struct PairedServer {
    /// SHA-256 of the server certificate, 64 hex chars.
    server_cert_sha256: String,
}

/// The pinned server fingerprint (hex), `None` when not paired yet.
pub fn read_pinned_fingerprint(identity_directory: &Path) -> anyhow::Result<Option<String>> {
    let path = identity_directory.join(PAIRED_SERVER_FILE);
    let text = match std::fs::read_to_string(&path) {
        Ok(text) => text,
        Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(None),
        Err(error) => return Err(anyhow::anyhow!("{}: {error}", path.display())),
    };
    let paired_server: PairedServer = serde_json::from_str(&text)
        .map_err(|error| anyhow::anyhow!("{}: {error}", path.display()))?;
    Ok(Some(paired_server.server_cert_sha256))
}

/// Listen for `timeout_ms` and return every server found, sorted by name.
pub fn browse(timeout_ms: u64) -> Result<Vec<DiscoveredServer>, mdns_sd::Error> {
    let daemon = ServiceDaemon::new()?;
    let outcome = browse_with(&daemon, timeout_ms);
    if let Ok(status_receiver) = daemon.shutdown() {
        // Waits for the thread so no mDNS work outlives the command.
        let _ = status_receiver.recv_timeout(Duration::from_millis(STOP_TIMEOUT_MS));
    }
    outcome
}

fn browse_with(
    daemon: &ServiceDaemon,
    timeout_ms: u64,
) -> Result<Vec<DiscoveredServer>, mdns_sd::Error> {
    // IPv4 only (spec section 13).
    daemon.disable_interface(IfKind::IPv6)?;
    let events = daemon.browse(SERVICE_TYPE)?;
    let deadline = Instant::now() + Duration::from_millis(timeout_ms);
    let mut servers_by_fullname: BTreeMap<String, DiscoveredServer> = BTreeMap::new();
    // Ends at the deadline (or if the daemon goes away).
    while let Ok(event) = events.recv_deadline(deadline) {
        match event {
            ServiceEvent::ServiceResolved(service) => {
                let found = DiscoveredServer::from_resolved(&service);
                servers_by_fullname
                    .entry(service.get_fullname().to_owned())
                    .and_modify(|known| {
                        // Each interface answers with its own address.
                        known.ipv4_addresses.extend(&found.ipv4_addresses);
                        known.port = found.port;
                        known
                            .fingerprint_prefix
                            .clone_from(&found.fingerprint_prefix);
                        known.protocol_version.clone_from(&found.protocol_version);
                    })
                    .or_insert(found);
            }
            ServiceEvent::ServiceRemoved(_, fullname) => {
                servers_by_fullname.remove(&fullname);
            }
            _ => {}
        }
    }
    let mut servers: Vec<DiscoveredServer> = servers_by_fullname
        .into_values()
        .filter(|server| !server.ipv4_addresses.is_empty())
        .collect();
    servers.sort_by(|left, right| left.name.cmp(&right.name));
    Ok(servers)
}

/// `discover`: browse, print, exit 0 even when nothing is found.
pub fn run_discover_command(
    identity_directory: Option<&Path>,
    discover_args: &DiscoverArgs,
) -> ExitCode {
    let pinned_fingerprint_hex = match identity_directory.map(read_pinned_fingerprint) {
        Some(Ok(pin)) => pin,
        Some(Err(error)) => {
            eprintln!("haotrannas-cli discover: cannot read the pin, ignoring it: {error:#}");
            None
        }
        None => None,
    };
    let servers = match browse(discover_args.timeout_ms) {
        Ok(servers) => servers,
        Err(error) => {
            eprintln!("haotrannas-cli discover: mDNS: {error}");
            return ExitCode::from(FAILURE_EXIT_CODE);
        }
    };
    if servers.is_empty() {
        println!("no servers found");
    }
    for server in &servers {
        println!("{}", server.line(pinned_fingerprint_hex.as_deref()));
    }
    ExitCode::SUCCESS
}

#[cfg(test)]
mod tests {
    use std::collections::BTreeSet;
    use std::net::Ipv4Addr;

    use super::{DiscoveredServer, is_pin_match, read_pinned_fingerprint};

    /// SHA-256("abc").
    const ABC_SHA256_HEX: &str = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad";

    fn server(addresses: &[Ipv4Addr]) -> DiscoveredServer {
        DiscoveredServer {
            name: "haotrannas".to_owned(),
            ipv4_addresses: addresses.iter().copied().collect::<BTreeSet<_>>(),
            port: 47_100,
            fingerprint_prefix: Some("ba7816bf8f01cfea".to_owned()),
            protocol_version: Some("1".to_owned()),
        }
    }

    #[test]
    fn line_shows_name_address_fingerprint_and_version() {
        let found = server(&[Ipv4Addr::new(192, 168, 1, 20)]);
        assert_eq!(
            found.line(None),
            "haotrannas  192.168.1.20:47100  fp=ba7816bf8f01cfea  v=1"
        );
    }

    #[test]
    fn line_marks_the_pinned_server_as_paired() {
        let found = server(&[Ipv4Addr::new(192, 168, 1, 20)]);
        assert_eq!(
            found.line(Some(ABC_SHA256_HEX)),
            "haotrannas  192.168.1.20:47100  fp=ba7816bf8f01cfea  v=1  (paired)"
        );
        let other_pin = "00".repeat(32);
        assert!(!found.line(Some(&other_pin)).ends_with("(paired)"));
    }

    #[test]
    fn line_shows_missing_txt_values_as_question_marks() {
        let mut found = server(&[Ipv4Addr::new(192, 168, 1, 20)]);
        found.fingerprint_prefix = None;
        found.protocol_version = None;
        assert_eq!(
            found.line(Some(ABC_SHA256_HEX)),
            "haotrannas  192.168.1.20:47100  fp=?  v=?"
        );
    }

    #[test]
    fn lan_address_wins_over_loopback() {
        let found = server(&[Ipv4Addr::LOCALHOST, Ipv4Addr::new(192, 168, 1, 20)]);
        assert_eq!(
            found.best_ipv4_address(),
            Some(Ipv4Addr::new(192, 168, 1, 20))
        );
        let local_only = server(&[Ipv4Addr::LOCALHOST]);
        assert_eq!(local_only.best_ipv4_address(), Some(Ipv4Addr::LOCALHOST));
    }

    #[test]
    fn pin_match_needs_the_full_sixteen_char_prefix() {
        assert!(is_pin_match("ba7816bf8f01cfea", ABC_SHA256_HEX));
        assert!(is_pin_match(
            "ba7816bf8f01cfea",
            &ABC_SHA256_HEX.to_ascii_uppercase()
        ));
        assert!(!is_pin_match("ba7816bf", ABC_SHA256_HEX));
        assert!(!is_pin_match("ba7816bf8f01cfeb", ABC_SHA256_HEX));
        assert!(!is_pin_match("ba7816bf8f01cfea", "ba78"));
    }

    #[test]
    fn pin_is_read_from_server_json_and_missing_file_is_not_paired() {
        let identity_directory = tempfile::tempdir().unwrap();
        assert_eq!(
            read_pinned_fingerprint(identity_directory.path()).unwrap(),
            None
        );
        std::fs::write(
            identity_directory.path().join("server.json"),
            format!(
                r#"{{"server_cert_sha256":"{ABC_SHA256_HEX}","device_id":3,"last_address":"192.168.1.20:47100"}}"#
            ),
        )
        .unwrap();
        assert_eq!(
            read_pinned_fingerprint(identity_directory.path()).unwrap(),
            Some(ABC_SHA256_HEX.to_owned())
        );
    }

    #[test]
    fn bad_server_json_is_an_error() {
        let identity_directory = tempfile::tempdir().unwrap();
        std::fs::write(identity_directory.path().join("server.json"), "{").unwrap();
        assert!(read_pinned_fingerprint(identity_directory.path()).is_err());
    }
}
