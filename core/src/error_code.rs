//! Error codes sent in `Error` (protocol spec section 11) and reasons sent in
//! `Close` (section 12).
//!
//! Messages carry the raw `u16`, so a number from a newer peer survives
//! decoding; [`ErrorCode::from_code`] and [`CloseReason::from_reason`] give
//! `None` for numbers this version does not know. An unknown number is never
//! a decode error; it is shown as `UNKNOWN(<number>)`.

/// Why a request failed (sent in `Error`). Never reuse or renumber a code.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
#[repr(u16)]
pub enum ErrorCode {
    /// Bad frame or payload (spec sections 2–5).
    MalformedFrame = 1,
    /// Hello with another protocol version.
    VersionMismatch = 2,
    /// Message not allowed in this state or direction.
    UnexpectedMessage = 3,
    /// Ready-only request while unpaired, or unknown client certificate.
    NotPaired = 4,
    /// No pairing window open.
    PairingNotOpen = 5,
    /// Wrong pairing code; fatal only on the 3rd failure in one connection.
    BadPairingCode = 6,
    /// Pairing window locked after too many failures.
    TooManyAttempts = 7,
    /// Pairing from outside `pairing_networks`.
    PairingNotAllowedFromNetwork = 8,
    /// Path rules broken.
    BadPath = 20,
    /// A value out of range (index, count, `max_entries`).
    BadArgument = 21,
    /// More than 65 536 chunks.
    TooLarge = 22,
    /// Chunk hash wrong.
    ChunkHashMismatch = 23,
    /// Chunk length wrong for its index.
    ChunkSizeWrong = 24,
    /// No such open upload for this device.
    UnknownUpload = 25,
    /// Commit before all chunks arrived.
    ChunksMissing = 26,
    /// Whole-file hash wrong at Commit.
    FileHashMismatch = 27,
    /// No space to store; nothing was written.
    DiskFull = 28,
    /// Device, path, version or chunk not found.
    NotFound = 40,
    /// Server bug or I/O error.
    Internal = 50,
    /// Server is stopping.
    ShuttingDown = 51,
}

impl ErrorCode {
    /// Every known code, in table order.
    pub const ALL: [Self; 20] = [
        Self::MalformedFrame,
        Self::VersionMismatch,
        Self::UnexpectedMessage,
        Self::NotPaired,
        Self::PairingNotOpen,
        Self::BadPairingCode,
        Self::TooManyAttempts,
        Self::PairingNotAllowedFromNetwork,
        Self::BadPath,
        Self::BadArgument,
        Self::TooLarge,
        Self::ChunkHashMismatch,
        Self::ChunkSizeWrong,
        Self::UnknownUpload,
        Self::ChunksMissing,
        Self::FileHashMismatch,
        Self::DiskFull,
        Self::NotFound,
        Self::Internal,
        Self::ShuttingDown,
    ];

    /// The number sent on the wire.
    pub const fn code(self) -> u16 {
        self as u16
    }

    /// The known code for `code`, or `None` for a number this version does
    /// not know (keep the raw number then).
    pub fn from_code(code: u16) -> Option<Self> {
        Self::ALL.into_iter().find(|known| known.code() == code)
    }

    /// True if the server closes the connection right after sending this
    /// error. `BadPairingCode` is false here: it becomes fatal only on the
    /// 3rd failure in one connection, which the session decides.
    pub const fn is_fatal(self) -> bool {
        matches!(
            self,
            Self::MalformedFrame
                | Self::VersionMismatch
                | Self::UnexpectedMessage
                | Self::NotPaired
                | Self::TooManyAttempts
                | Self::PairingNotAllowedFromNetwork
                | Self::ShuttingDown
        )
    }

    /// The spec name, for example `MALFORMED_FRAME`.
    pub const fn name(self) -> &'static str {
        match self {
            Self::MalformedFrame => "MALFORMED_FRAME",
            Self::VersionMismatch => "VERSION_MISMATCH",
            Self::UnexpectedMessage => "UNEXPECTED_MESSAGE",
            Self::NotPaired => "NOT_PAIRED",
            Self::PairingNotOpen => "PAIRING_NOT_OPEN",
            Self::BadPairingCode => "BAD_PAIRING_CODE",
            Self::TooManyAttempts => "TOO_MANY_ATTEMPTS",
            Self::PairingNotAllowedFromNetwork => "PAIRING_NOT_ALLOWED_FROM_NETWORK",
            Self::BadPath => "BAD_PATH",
            Self::BadArgument => "BAD_ARGUMENT",
            Self::TooLarge => "TOO_LARGE",
            Self::ChunkHashMismatch => "CHUNK_HASH_MISMATCH",
            Self::ChunkSizeWrong => "CHUNK_SIZE_WRONG",
            Self::UnknownUpload => "UNKNOWN_UPLOAD",
            Self::ChunksMissing => "CHUNKS_MISSING",
            Self::FileHashMismatch => "FILE_HASH_MISMATCH",
            Self::DiskFull => "DISK_FULL",
            Self::NotFound => "NOT_FOUND",
            Self::Internal => "INTERNAL",
            Self::ShuttingDown => "SHUTTING_DOWN",
        }
    }

    /// Name to show for a raw code: the spec name, or `UNKNOWN(<code>)`.
    pub fn label(code: u16) -> String {
        Self::from_code(code).map_or_else(
            || format!("UNKNOWN({code})"),
            |known| known.name().to_owned(),
        )
    }
}

/// Why a connection is being closed (sent in `Close`).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
#[repr(u16)]
pub enum CloseReason {
    /// Normal end of the conversation.
    Normal = 0,
    /// No `Hello` within the handshake timeout.
    HandshakeTimeout = 1,
    /// No frame within the idle timeout.
    IdleTimeout = 2,
    /// The peer broke the protocol.
    ProtocolError = 3,
    /// The server is stopping.
    ServerShutdown = 4,
    /// Pairing done; reconnect with the new client certificate.
    PairedReconnect = 5,
}

impl CloseReason {
    /// Every known reason, in table order.
    pub const ALL: [Self; 6] = [
        Self::Normal,
        Self::HandshakeTimeout,
        Self::IdleTimeout,
        Self::ProtocolError,
        Self::ServerShutdown,
        Self::PairedReconnect,
    ];

    /// The number sent on the wire.
    pub const fn reason(self) -> u16 {
        self as u16
    }

    /// The known reason for `reason`, or `None` for a number this version
    /// does not know (keep the raw number then).
    pub fn from_reason(reason: u16) -> Option<Self> {
        Self::ALL.into_iter().find(|known| known.reason() == reason)
    }

    /// The spec name, for example `IDLE_TIMEOUT`.
    pub const fn name(self) -> &'static str {
        match self {
            Self::Normal => "NORMAL",
            Self::HandshakeTimeout => "HANDSHAKE_TIMEOUT",
            Self::IdleTimeout => "IDLE_TIMEOUT",
            Self::ProtocolError => "PROTOCOL_ERROR",
            Self::ServerShutdown => "SERVER_SHUTDOWN",
            Self::PairedReconnect => "PAIRED_RECONNECT",
        }
    }

    /// Name to show for a raw reason: the spec name, or `UNKNOWN(<reason>)`.
    pub fn label(reason: u16) -> String {
        Self::from_reason(reason).map_or_else(
            || format!("UNKNOWN({reason})"),
            |known| known.name().to_owned(),
        )
    }
}

#[cfg(test)]
mod tests {
    use super::{CloseReason, ErrorCode};

    #[test]
    fn error_codes_have_spec_numbers() {
        let expected: [(u16, &str, bool); 20] = [
            (1, "MALFORMED_FRAME", true),
            (2, "VERSION_MISMATCH", true),
            (3, "UNEXPECTED_MESSAGE", true),
            (4, "NOT_PAIRED", true),
            (5, "PAIRING_NOT_OPEN", false),
            (6, "BAD_PAIRING_CODE", false),
            (7, "TOO_MANY_ATTEMPTS", true),
            (8, "PAIRING_NOT_ALLOWED_FROM_NETWORK", true),
            (20, "BAD_PATH", false),
            (21, "BAD_ARGUMENT", false),
            (22, "TOO_LARGE", false),
            (23, "CHUNK_HASH_MISMATCH", false),
            (24, "CHUNK_SIZE_WRONG", false),
            (25, "UNKNOWN_UPLOAD", false),
            (26, "CHUNKS_MISSING", false),
            (27, "FILE_HASH_MISMATCH", false),
            (28, "DISK_FULL", false),
            (40, "NOT_FOUND", false),
            (50, "INTERNAL", false),
            (51, "SHUTTING_DOWN", true),
        ];
        for (known, (code, name, is_fatal)) in ErrorCode::ALL.into_iter().zip(expected) {
            assert_eq!(known.code(), code);
            assert_eq!(known.name(), name);
            assert_eq!(known.is_fatal(), is_fatal, "{name}");
            assert_eq!(ErrorCode::from_code(code), Some(known));
        }
    }

    #[test]
    fn unknown_error_code_is_kept_raw() {
        assert_eq!(ErrorCode::from_code(0), None);
        assert_eq!(ErrorCode::from_code(999), None);
        assert_eq!(ErrorCode::label(999), "UNKNOWN(999)");
        assert_eq!(ErrorCode::label(25), "UNKNOWN_UPLOAD");
    }

    #[test]
    fn close_reasons_have_spec_numbers() {
        for (number, known) in (0_u16..).zip(CloseReason::ALL) {
            assert_eq!(known.reason(), number);
            assert_eq!(CloseReason::from_reason(number), Some(known));
        }
        assert_eq!(CloseReason::from_reason(6), None);
        assert_eq!(CloseReason::label(5), "PAIRED_RECONNECT");
        assert_eq!(CloseReason::label(77), "UNKNOWN(77)");
    }
}
