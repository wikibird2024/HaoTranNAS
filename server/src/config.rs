//! Server settings read from `config.toml` (on the NAS:
//! `/etc/haotrannas/config.toml`, passed with `--config`).
//!
//! Every field has a default, so a missing file works. Unknown keys, bad
//! TOML and bad network strings are errors that name the field. The example
//! with every field is `nas/config.example.toml`; a test keeps it in sync.

use std::fmt;
use std::io;
use std::net::{IpAddr, Ipv4Addr, SocketAddr};
use std::path::{Path, PathBuf};
use std::str::FromStr;

use serde::Deserialize;

/// Default TLS port (protocol/spec.md section 1).
pub const DEFAULT_PORT: u16 = 47100;

/// The `WireGuard` subnet from `nas/wireguard/wg0.conf.example`. Pairing is
/// LAN-only (protocol/spec.md section 7), so no `pairing_networks` entry may
/// overlap it: a phone on 4G behind the tunnel must never be able to pair.
pub const WIREGUARD_NETWORK: IpNetwork = IpNetwork {
    address: IpAddr::V4(Ipv4Addr::new(10, 66, 0, 0)),
    prefix_length: 24,
};

/// Everything the server reads from `config.toml`.
#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
#[serde(default, deny_unknown_fields)]
pub struct ServerConfig {
    /// Address and port the TLS listener binds to.
    pub listen_address: SocketAddr,
    /// Root of the store: `chunks/`, `tmp/`, `index.sqlite`, `tls/`.
    pub data_directory: PathBuf,
    /// mDNS instance name the apps show (protocol/spec.md section 13).
    pub server_name: String,
    /// Source networks allowed to pair (protocol/spec.md section 7). The real
    /// LAN only, never the `WireGuard` subnet.
    pub pairing_networks: Vec<IpNetwork>,
    /// Announce `_haotrannas._tcp.local` on the LAN.
    pub mdns_enabled: bool,
    /// Most client connections served at once; more are refused.
    pub max_connections: u32,
    /// Time between two full re-hashes of every stored chunk.
    pub scrub_interval_hours: u32,
    /// Time between two cleanup runs (old uploads, temp files, unused chunks).
    pub cleanup_interval_minutes: u32,
    /// An upload not committed within this time is deleted by cleanup.
    pub upload_expiry_hours: u32,
}

impl Default for ServerConfig {
    fn default() -> Self {
        Self {
            listen_address: SocketAddr::new(IpAddr::V4(Ipv4Addr::UNSPECIFIED), DEFAULT_PORT),
            data_directory: PathBuf::from("/srv/haotrannas"),
            server_name: "haotrannas".to_owned(),
            // The private IPv4 ranges a home LAN uses, minus 10.0.0.0/8: it
            // contains the WireGuard subnet 10.66.0.0/24. A 10.x LAN lists its
            // own subnet, e.g. "10.0.0.0/24".
            pairing_networks: vec![
                IpNetwork::from_str("192.168.0.0/16").expect("valid default network"),
                IpNetwork::from_str("172.16.0.0/12").expect("valid default network"),
            ],
            mdns_enabled: true,
            max_connections: 64,
            scrub_interval_hours: 168,
            cleanup_interval_minutes: 60,
            upload_expiry_hours: 24,
        }
    }
}

impl ServerConfig {
    /// Read and check the config file. A missing file gives the defaults.
    pub fn load(path: &Path) -> Result<Self, ConfigError> {
        match std::fs::read_to_string(path) {
            Ok(text) => Self::parse(&text, path),
            Err(error) if error.kind() == io::ErrorKind::NotFound => {
                let config = Self::default();
                config.validate()?;
                Ok(config)
            }
            Err(source) => Err(ConfigError::Read {
                path: path.to_owned(),
                source,
            }),
        }
    }

    /// Parse and check TOML text. `path` is only used in error messages.
    pub fn parse(text: &str, path: &Path) -> Result<Self, ConfigError> {
        let config: Self = toml::from_str(text).map_err(|source| ConfigError::Parse {
            path: path.to_owned(),
            source,
        })?;
        config.validate()?;
        Ok(config)
    }

    /// Rules TOML types cannot express.
    pub fn validate(&self) -> Result<(), ConfigError> {
        if self.server_name.trim().is_empty() {
            return Err(ConfigError::EmptyField {
                field: "server_name",
            });
        }
        if self.pairing_networks.is_empty() {
            return Err(ConfigError::EmptyField {
                field: "pairing_networks",
            });
        }
        if let Some(network) = self
            .pairing_networks
            .iter()
            .find(|network| network.overlaps(&WIREGUARD_NETWORK))
        {
            return Err(ConfigError::WireGuardCanPair { network: *network });
        }
        let counts = [
            ("max_connections", self.max_connections),
            ("scrub_interval_hours", self.scrub_interval_hours),
            ("cleanup_interval_minutes", self.cleanup_interval_minutes),
            ("upload_expiry_hours", self.upload_expiry_hours),
        ];
        if let Some((field, _)) = counts.iter().find(|(_, count)| *count == 0) {
            return Err(ConfigError::ZeroValue { field });
        }
        Ok(())
    }

    /// True if a client at `address` may pair.
    pub fn is_pairing_allowed_from(&self, address: IpAddr) -> bool {
        self.pairing_networks
            .iter()
            .any(|network| network.contains(address))
    }
}

/// Why the config could not be used. Each message names the file or field.
#[derive(Debug, thiserror::Error)]
pub enum ConfigError {
    #[error("cannot read config file {path}: {source}")]
    Read { path: PathBuf, source: io::Error },
    /// Bad TOML, unknown key, wrong type or bad network string. The `toml`
    /// message shows the line and names the key.
    #[error("config file {path}: {source}")]
    Parse {
        path: PathBuf,
        source: toml::de::Error,
    },
    #[error("config: {field} must not be empty")]
    EmptyField { field: &'static str },
    #[error("config: {field} must be greater than 0")]
    ZeroValue { field: &'static str },
    #[error(
        "config: pairing_networks entry {network} overlaps the WireGuard subnet \
         {WIREGUARD_NETWORK}. Pairing is LAN-only (protocol/spec.md section 7): \
         list the real LAN only, e.g. \"192.168.1.0/24\""
    )]
    WireGuardCanPair { network: IpNetwork },
}

/// An IP network in CIDR form, e.g. `192.168.1.0/24` or `fd00::/8`.
///
/// Host bits after the prefix are ignored, so `192.168.1.7/24` means
/// `192.168.1.0/24`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize)]
#[serde(try_from = "String")]
pub struct IpNetwork {
    pub address: IpAddr,
    pub prefix_length: u8,
}

impl IpNetwork {
    /// True if `address` is inside this network. An IPv4-mapped IPv6 address
    /// (`::ffff:192.168.1.7`, what a dual-stack socket reports) counts as
    /// its IPv4 address.
    pub fn contains(&self, address: IpAddr) -> bool {
        match (self.address, address.to_canonical()) {
            (IpAddr::V4(network), IpAddr::V4(candidate)) => {
                let mask = u32::MAX
                    .checked_shl(32 - u32::from(self.prefix_length))
                    .unwrap_or(0);
                u32::from(network) & mask == u32::from(candidate) & mask
            }
            (IpAddr::V6(network), IpAddr::V6(candidate)) => {
                let mask = u128::MAX
                    .checked_shl(128 - u32::from(self.prefix_length))
                    .unwrap_or(0);
                u128::from(network) & mask == u128::from(candidate) & mask
            }
            _ => false,
        }
    }

    /// True if the two networks share any address. CIDR blocks are either
    /// nested or apart, so it is enough to test each one's base address.
    pub fn overlaps(&self, other: &IpNetwork) -> bool {
        self.contains(other.address) || other.contains(self.address)
    }
}

impl FromStr for IpNetwork {
    type Err = String;

    fn from_str(text: &str) -> Result<Self, Self::Err> {
        let bad = || format!("bad network \"{text}\": expected CIDR form like \"192.168.1.0/24\"");
        let (address_text, prefix_text) = text.split_once('/').ok_or_else(bad)?;
        let address = IpAddr::from_str(address_text).map_err(|_| bad())?;
        let prefix_length = u8::from_str(prefix_text).map_err(|_| bad())?;
        let max_prefix_length = if address.is_ipv4() { 32 } else { 128 };
        if prefix_length > max_prefix_length {
            return Err(format!(
                "bad network \"{text}\": prefix length {prefix_length} is over {max_prefix_length}"
            ));
        }
        Ok(Self {
            address,
            prefix_length,
        })
    }
}

impl TryFrom<String> for IpNetwork {
    type Error = String;

    fn try_from(text: String) -> Result<Self, Self::Error> {
        Self::from_str(&text)
    }
}

impl fmt::Display for IpNetwork {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(formatter, "{}/{}", self.address, self.prefix_length)
    }
}

#[cfg(test)]
mod tests {
    use std::net::Ipv6Addr;

    use super::*;

    fn network(text: &str) -> IpNetwork {
        IpNetwork::from_str(text).unwrap()
    }

    fn address(text: &str) -> IpAddr {
        IpAddr::from_str(text).unwrap()
    }

    fn parse(text: &str) -> Result<ServerConfig, ConfigError> {
        ServerConfig::parse(text, Path::new("test.toml"))
    }

    #[test]
    fn defaults_match_the_documented_values() {
        let config = ServerConfig::default();
        assert_eq!(config.listen_address, "0.0.0.0:47100".parse().unwrap());
        assert_eq!(config.data_directory, PathBuf::from("/srv/haotrannas"));
        assert_eq!(config.server_name, "haotrannas");
        assert_eq!(
            config.pairing_networks,
            vec![network("192.168.0.0/16"), network("172.16.0.0/12")]
        );
        assert!(config.mdns_enabled);
        assert_eq!(config.max_connections, 64);
        assert_eq!(config.scrub_interval_hours, 168);
        assert_eq!(config.cleanup_interval_minutes, 60);
        assert_eq!(config.upload_expiry_hours, 24);
        config.validate().unwrap();
    }

    #[test]
    fn empty_text_gives_defaults() {
        assert_eq!(parse("").unwrap(), ServerConfig::default());
    }

    #[test]
    fn missing_file_gives_defaults() {
        let directory = tempfile::tempdir().unwrap();
        let config = ServerConfig::load(&directory.path().join("absent.toml")).unwrap();
        assert_eq!(config, ServerConfig::default());
    }

    #[test]
    fn load_reads_a_file() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("config.toml");
        std::fs::write(&path, "max_connections = 8\n").unwrap();
        assert_eq!(ServerConfig::load(&path).unwrap().max_connections, 8);
    }

    #[test]
    fn full_config_parses() {
        let config = parse(
            r#"
            listen_address = "192.168.1.10:47200"
            data_directory = "/tank/backup"
            server_name = "attic"
            pairing_networks = ["192.168.1.0/24", "fd00:1::/64"]
            mdns_enabled = false
            max_connections = 8
            scrub_interval_hours = 24
            cleanup_interval_minutes = 15
            upload_expiry_hours = 48
            "#,
        )
        .unwrap();
        let expected = ServerConfig {
            listen_address: "192.168.1.10:47200".parse().unwrap(),
            data_directory: PathBuf::from("/tank/backup"),
            server_name: "attic".to_owned(),
            pairing_networks: vec![network("192.168.1.0/24"), network("fd00:1::/64")],
            mdns_enabled: false,
            max_connections: 8,
            scrub_interval_hours: 24,
            cleanup_interval_minutes: 15,
            upload_expiry_hours: 48,
        };
        assert_eq!(config, expected);
    }

    /// The example file sets every field to its default, so the comments in
    /// it ("default: ...") and the code cannot drift apart.
    #[test]
    fn example_file_equals_defaults() {
        let path = Path::new(env!("CARGO_MANIFEST_DIR")).join("../nas/config.example.toml");
        let text = std::fs::read_to_string(&path).unwrap();
        assert_eq!(parse(&text).unwrap(), ServerConfig::default());
        // Every field is written out in the example, not left to the default.
        for field in [
            "listen_address",
            "data_directory",
            "server_name",
            "pairing_networks",
            "mdns_enabled",
            "max_connections",
            "scrub_interval_hours",
            "cleanup_interval_minutes",
            "upload_expiry_hours",
        ] {
            assert!(
                text.lines()
                    .any(|line| line.starts_with(&format!("{field} = "))),
                "{field} missing from the example"
            );
        }
    }

    #[test]
    fn unknown_key_is_rejected_by_name() {
        let message = parse("max_conections = 8\n").unwrap_err().to_string();
        assert!(message.contains("max_conections"), "{message}");
    }

    #[test]
    fn wrong_type_names_the_field() {
        let message = parse("max_connections = \"many\"\n")
            .unwrap_err()
            .to_string();
        assert!(message.contains("max_connections"), "{message}");
    }

    #[test]
    fn bad_toml_is_rejected() {
        assert!(matches!(
            parse("listen_address = \n"),
            Err(ConfigError::Parse { .. })
        ));
    }

    #[test]
    fn bad_cidr_is_rejected_by_name() {
        for bad in [
            "192.168.1.0",
            "192.168.1.0/33",
            "fd00::/129",
            "192.168.1/24",
            "lan/24",
            "192.168.1.0/-1",
        ] {
            let message = parse(&format!("pairing_networks = [\"{bad}\"]\n"))
                .unwrap_err()
                .to_string();
            assert!(message.contains("pairing_networks"), "{message}");
            assert!(message.contains(bad), "{message}");
        }
    }

    #[test]
    fn empty_pairing_networks_is_rejected() {
        let error = parse("pairing_networks = []\n").unwrap_err();
        assert!(matches!(
            error,
            ConfigError::EmptyField {
                field: "pairing_networks"
            }
        ));
    }

    #[test]
    fn zero_interval_is_rejected() {
        let error = parse("cleanup_interval_minutes = 0\n").unwrap_err();
        assert!(error.to_string().contains("cleanup_interval_minutes"));
    }

    #[test]
    fn wireguard_subnet_is_rejected() {
        for wide in [
            "10.0.0.0/8",
            "10.66.0.0/24",
            "10.66.0.1/32",
            "10.66.0.128/25",
            "0.0.0.0/0",
        ] {
            let message = parse(&format!(
                "pairing_networks = [\"192.168.1.0/24\", \"{wide}\"]\n"
            ))
            .unwrap_err()
            .to_string();
            assert!(message.contains("WireGuard"), "{message}");
            assert!(message.contains("section 7"), "{message}");
        }
        // Right next to it is fine.
        parse("pairing_networks = [\"10.65.0.0/16\", \"10.67.0.0/16\"]\n").unwrap();
    }

    #[test]
    fn contains_ipv4_edges() {
        let lan = network("192.168.1.0/24");
        assert!(lan.contains(address("192.168.1.0")));
        assert!(lan.contains(address("192.168.1.255")));
        assert!(!lan.contains(address("192.168.2.0")));
        assert!(!lan.contains(address("192.168.0.255")));

        let everything = network("0.0.0.0/0");
        assert!(everything.contains(address("0.0.0.0")));
        assert!(everything.contains(address("255.255.255.255")));

        let single = network("10.66.0.1/32");
        assert!(single.contains(address("10.66.0.1")));
        assert!(!single.contains(address("10.66.0.2")));

        // Host bits are ignored.
        assert!(network("192.168.1.7/24").contains(address("192.168.1.200")));
        // An IPv4 network never matches an IPv6 address and back.
        assert!(!everything.contains(address("::1")));
    }

    #[test]
    fn contains_ipv6_edges() {
        let local = network("fd00:1::/64");
        assert!(local.contains(address("fd00:1::1")));
        assert!(local.contains(address("fd00:1::ffff:ffff:ffff:ffff")));
        assert!(!local.contains(address("fd00:2::1")));

        let everything = network("::/0");
        assert!(everything.contains(IpAddr::V6(Ipv6Addr::UNSPECIFIED)));
        assert!(everything.contains(address("ffff:ffff:ffff:ffff:ffff:ffff:ffff:ffff")));
        assert!(!everything.contains(address("192.168.1.1")));

        let single = network("fe80::1/128");
        assert!(single.contains(address("fe80::1")));
        assert!(!single.contains(address("fe80::2")));
    }

    #[test]
    fn ipv4_mapped_address_counts_as_ipv4() {
        let config = ServerConfig::default();
        assert!(config.is_pairing_allowed_from(address("::ffff:192.168.1.7")));
        assert!(!config.is_pairing_allowed_from(address("::ffff:10.66.0.2")));
        assert!(!config.is_pairing_allowed_from(address("10.66.0.2")));
    }

    #[test]
    fn network_displays_in_cidr_form() {
        assert_eq!(network("fd00::/8").to_string(), "fd00::/8");
        assert_eq!(WIREGUARD_NETWORK.to_string(), "10.66.0.0/24");
    }
}
