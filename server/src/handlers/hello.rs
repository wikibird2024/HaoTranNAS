//! `Hello` → `HelloOk`: checks the protocol version (1 or 2; the
//! connection speaks the client's) and tells the client whether it is
//! paired on this connection (`device_id` 0 = not paired).
//! A client certificate the catalog does not know (never paired, or
//! revoked) gets `NOT_PAIRED` (fatal, spec §6).

use haotrannas_core::error_code::ErrorCode;
use haotrannas_core::limits::{
    CHUNK_SIZE_BYTES, MAX_FRAME_LENGTH_BYTES, MIN_PROTOCOL_VERSION, PROTOCOL_VERSION,
};
use haotrannas_core::message::Message;
use haotrannas_core::session::SessionState;

use crate::session::PeerIdentity;

/// What the server says about itself in `HelloOk`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ServerIdentity {
    /// `haotrannas-server/<version>`.
    pub server_software: String,
    /// The config's `server_name` (at most `MAX_NAME_BYTES`).
    pub server_name: String,
}

impl ServerIdentity {
    /// This build's software name and the given server name.
    pub fn new(server_name: String) -> Self {
        Self {
            server_software: format!("haotrannas-server/{}", env!("CARGO_PKG_VERSION")),
            server_name,
        }
    }
}

/// Answers `Hello`: the `HelloOk` reply and the next state, or the fatal
/// `VERSION_MISMATCH` / `NOT_PAIRED`. `peer_identity` is what the client
/// certificate said (in dev mode always device 1).
pub fn handle_hello(
    protocol_version: u16,
    server_identity: &ServerIdentity,
    peer_identity: PeerIdentity,
) -> Result<(Message, SessionState), (ErrorCode, String)> {
    if !(MIN_PROTOCOL_VERSION..=PROTOCOL_VERSION).contains(&protocol_version) {
        return Err((
            ErrorCode::VersionMismatch,
            format!(
                "client speaks protocol version {protocol_version}, this server speaks \
                 {MIN_PROTOCOL_VERSION} to {PROTOCOL_VERSION}"
            ),
        ));
    }
    let paired_device_id = match peer_identity {
        PeerIdentity::Device(device_id) => Some(device_id),
        PeerIdentity::NoCertificate => None,
        PeerIdentity::UnknownCertificate => {
            return Err((
                ErrorCode::NotPaired,
                "this device is not paired with this server (unknown or revoked certificate)"
                    .to_owned(),
            ));
        }
    };
    let reply = Message::HelloOk {
        // The connection speaks the client's version (spec §6).
        protocol_version,
        server_software: server_identity.server_software.clone(),
        server_name: server_identity.server_name.clone(),
        device_id: paired_device_id.unwrap_or(0),
        chunk_size_bytes: CHUNK_SIZE_BYTES,
        max_frame_length_bytes: MAX_FRAME_LENGTH_BYTES,
    };
    Ok((reply, SessionState::after_hello(paired_device_id.is_some())))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn paired_device_gets_its_id_and_ready() {
        let identity = ServerIdentity::new("attic".to_owned());
        let (reply, state) =
            handle_hello(PROTOCOL_VERSION, &identity, PeerIdentity::Device(1)).unwrap();
        assert_eq!(state, SessionState::Ready);
        assert_eq!(
            reply,
            Message::HelloOk {
                protocol_version: 2,
                server_software: format!("haotrannas-server/{}", env!("CARGO_PKG_VERSION")),
                server_name: "attic".to_owned(),
                device_id: 1,
                chunk_size_bytes: 1_048_576,
                max_frame_length_bytes: 4_194_304,
            }
        );
    }

    #[test]
    fn unpaired_client_gets_device_zero() {
        let identity = ServerIdentity::new("attic".to_owned());
        let (reply, state) =
            handle_hello(PROTOCOL_VERSION, &identity, PeerIdentity::NoCertificate).unwrap();
        assert_eq!(state, SessionState::Unpaired);
        assert!(matches!(reply, Message::HelloOk { device_id: 0, .. }));
    }

    #[test]
    fn unknown_certificate_is_not_paired() {
        let identity = ServerIdentity::new("attic".to_owned());
        let (code, _) = handle_hello(
            PROTOCOL_VERSION,
            &identity,
            PeerIdentity::UnknownCertificate,
        )
        .unwrap_err();
        assert_eq!(code, ErrorCode::NotPaired);
    }

    #[test]
    fn version_one_client_still_works_and_gets_version_one() {
        let identity = ServerIdentity::new("attic".to_owned());
        let (reply, state) = handle_hello(1, &identity, PeerIdentity::Device(1)).unwrap();
        assert_eq!(state, SessionState::Ready);
        assert!(matches!(
            reply,
            Message::HelloOk {
                protocol_version: 1,
                ..
            }
        ));
    }

    #[test]
    fn other_version_is_refused() {
        let identity = ServerIdentity::new("attic".to_owned());
        for version in [0, 3, u16::MAX] {
            let (code, message) =
                handle_hello(version, &identity, PeerIdentity::Device(1)).unwrap_err();
            assert_eq!(code, ErrorCode::VersionMismatch);
            assert!(message.contains(&version.to_string()), "{message}");
        }
    }
}
