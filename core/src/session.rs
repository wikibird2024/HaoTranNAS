//! The connection state machine (protocol spec section 6):
//!
//! ```text
//!              Hello ok, cert known
//!  AwaitingHello ─────────────────────► Ready ◄──┐ requests
//!       │  Hello ok, no cert                     └─────────┘
//!       ▼
//!    Unpaired ──PairRequest ok──► PairOk + Close(PAIRED_RECONNECT) ──► Closed
//! ```
//!
//! Pure logic, no I/O and no clock: it says whether a message from the
//! client is allowed in a state, or which fatal error the server sends.
//! Timeouts and the pairing failure limit are counted by the server's
//! session task (see [`crate::limits`]).

use crate::error_code::ErrorCode;
use crate::message::MessageType;

/// Where a connection is in its life (server side).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SessionState {
    /// TCP (and TLS) are up; only `Hello` is allowed.
    AwaitingHello,
    /// `Hello` accepted without a known client certificate: only pairing,
    /// `Ping` and `Close`.
    Unpaired,
    /// `Hello` accepted from a paired device: every request is allowed.
    Ready,
    /// The connection is over; nothing more is handled.
    Closed,
}

impl SessionState {
    /// Every state, in spec order.
    pub const ALL: [Self; 4] = [
        Self::AwaitingHello,
        Self::Unpaired,
        Self::Ready,
        Self::Closed,
    ];

    /// The state after a successful `Hello`: `Ready` for a paired device,
    /// `Unpaired` otherwise.
    pub const fn after_hello(is_paired: bool) -> Self {
        if is_paired {
            Self::Ready
        } else {
            Self::Unpaired
        }
    }

    /// Checks a message the client sent in this state. `Ok` = handle it;
    /// `Err(code)` = send `Error code` and close the connection (every code
    /// returned here is fatal).
    ///
    /// Rules (spec section 6): a server-to-client type is always
    /// `UNEXPECTED_MESSAGE`; before `Hello` only `Hello` is allowed; while
    /// unpaired a Ready-only request is `NOT_PAIRED`; `Hello` and
    /// `PairRequest` are allowed once only, in their state.
    pub fn check_incoming(self, message_type: MessageType) -> Result<(), ErrorCode> {
        if !is_sent_by_client(message_type) {
            return Err(ErrorCode::UnexpectedMessage);
        }
        let is_allowed = match self {
            Self::AwaitingHello => message_type == MessageType::Hello,
            Self::Unpaired => {
                if is_ready_only(message_type) {
                    return Err(ErrorCode::NotPaired);
                }
                matches!(
                    message_type,
                    MessageType::PairRequest | MessageType::Ping | MessageType::Close
                )
            }
            Self::Ready => !matches!(message_type, MessageType::Hello | MessageType::PairRequest),
            Self::Closed => false,
        };
        if is_allowed {
            Ok(())
        } else {
            Err(ErrorCode::UnexpectedMessage)
        }
    }
}

/// True for the types a client may send (spec section 5, direction C→S or
/// both): every request, plus `Close`.
pub const fn is_sent_by_client(message_type: MessageType) -> bool {
    message_type.is_request() || matches!(message_type, MessageType::Close)
}

/// True for the requests only a paired device may send (the `Ready` row of
/// the spec section 6 table, minus `Ping` and `Close`).
pub const fn is_ready_only(message_type: MessageType) -> bool {
    matches!(
        message_type,
        MessageType::FileOffer
            | MessageType::ChunkData
            | MessageType::Commit
            | MessageType::ListDevices
            | MessageType::ListDir
            | MessageType::ReadFile
            | MessageType::ReadChunk
    )
}

#[cfg(test)]
mod tests {
    use super::SessionState;
    use crate::error_code::ErrorCode;
    use crate::message::MessageType;

    /// Expected outcome of one (state, message type) pair.
    #[derive(Debug, Clone, Copy, PartialEq, Eq)]
    enum Expected {
        /// Handled.
        Allowed,
        /// `UNEXPECTED_MESSAGE`, fatal.
        Unexpected,
        /// `NOT_PAIRED`, fatal.
        NotPaired,
    }

    use Expected::{Allowed, NotPaired, Unexpected};

    /// Spec section 6 written out by hand, one row per message type.
    /// Columns: `AwaitingHello`, `Unpaired`, `Ready`, `Closed`.
    const SPEC_TABLE: [(MessageType, [Expected; 4]); 22] = [
        (
            MessageType::Hello,
            [Allowed, Unexpected, Unexpected, Unexpected],
        ),
        (
            MessageType::HelloOk,
            [Unexpected, Unexpected, Unexpected, Unexpected],
        ),
        (
            MessageType::Ping,
            [Unexpected, Allowed, Allowed, Unexpected],
        ),
        (
            MessageType::Pong,
            [Unexpected, Unexpected, Unexpected, Unexpected],
        ),
        (
            MessageType::PairRequest,
            [Unexpected, Allowed, Unexpected, Unexpected],
        ),
        (
            MessageType::PairOk,
            [Unexpected, Unexpected, Unexpected, Unexpected],
        ),
        (
            MessageType::FileOffer,
            [Unexpected, NotPaired, Allowed, Unexpected],
        ),
        (
            MessageType::NeedChunks,
            [Unexpected, Unexpected, Unexpected, Unexpected],
        ),
        (
            MessageType::ChunkData,
            [Unexpected, NotPaired, Allowed, Unexpected],
        ),
        (
            MessageType::ChunkOk,
            [Unexpected, Unexpected, Unexpected, Unexpected],
        ),
        (
            MessageType::Commit,
            [Unexpected, NotPaired, Allowed, Unexpected],
        ),
        (
            MessageType::CommitOk,
            [Unexpected, Unexpected, Unexpected, Unexpected],
        ),
        (
            MessageType::ListDevices,
            [Unexpected, NotPaired, Allowed, Unexpected],
        ),
        (
            MessageType::DeviceList,
            [Unexpected, Unexpected, Unexpected, Unexpected],
        ),
        (
            MessageType::ListDir,
            [Unexpected, NotPaired, Allowed, Unexpected],
        ),
        (
            MessageType::DirEntries,
            [Unexpected, Unexpected, Unexpected, Unexpected],
        ),
        (
            MessageType::ReadFile,
            [Unexpected, NotPaired, Allowed, Unexpected],
        ),
        (
            MessageType::FileManifest,
            [Unexpected, Unexpected, Unexpected, Unexpected],
        ),
        (
            MessageType::ReadChunk,
            [Unexpected, NotPaired, Allowed, Unexpected],
        ),
        (
            MessageType::ChunkContent,
            [Unexpected, Unexpected, Unexpected, Unexpected],
        ),
        (
            MessageType::Close,
            [Unexpected, Allowed, Allowed, Unexpected],
        ),
        (
            MessageType::Error,
            [Unexpected, Unexpected, Unexpected, Unexpected],
        ),
    ];

    #[test]
    fn table_covers_every_message_type_once() {
        for message_type in MessageType::ALL {
            let row_count = SPEC_TABLE
                .iter()
                .filter(|(row_type, _)| *row_type == message_type)
                .count();
            assert_eq!(row_count, 1, "{}", message_type.name());
        }
    }

    #[test]
    fn every_state_and_message_type_pair_follows_the_spec() {
        for (message_type, expected_per_state) in SPEC_TABLE {
            for (state, expected) in SessionState::ALL.into_iter().zip(expected_per_state) {
                let outcome = state.check_incoming(message_type);
                let expected_outcome = match expected {
                    Allowed => Ok(()),
                    Unexpected => Err(ErrorCode::UnexpectedMessage),
                    NotPaired => Err(ErrorCode::NotPaired),
                };
                assert_eq!(
                    outcome,
                    expected_outcome,
                    "{state:?} + {}",
                    message_type.name()
                );
            }
        }
    }

    #[test]
    fn every_refusal_is_fatal() {
        for state in SessionState::ALL {
            for message_type in MessageType::ALL {
                if let Err(code) = state.check_incoming(message_type) {
                    assert!(code.is_fatal(), "{state:?} + {}", message_type.name());
                }
            }
        }
    }

    #[test]
    fn hello_leads_to_ready_or_unpaired() {
        assert_eq!(SessionState::after_hello(true), SessionState::Ready);
        assert_eq!(SessionState::after_hello(false), SessionState::Unpaired);
    }
}
