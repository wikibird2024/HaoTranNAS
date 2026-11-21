/// Protocol constants and limits, the same values as the Rust core.
///
/// A change here must match `protocol/` and `core/` (a breaking change
/// bumps [protocolVersion]). These limits are data-safety rules
/// (docs/conventions.md §4): never raise or remove one without asking Hao.
library;

/// Wire protocol version this app speaks and sends in `Hello` (2 = v1 +
/// thumbnails, spec §16); the server answers with the same number.
const int protocolVersion = 2;

/// Lowest version a server accepts; also the mDNS `v=` value (D-048).
const int minProtocolVersion = 1;

/// Frame header: lengthBytes u32 + type u16 + requestId u32.
const int frameHeaderBytes = 10;

/// Smallest lengthBytes value: type u16 + requestId u32, empty payload.
const int minFrameLengthBytes = 6;

/// Largest lengthBytes value (4 MiB); a bigger frame closes the connection.
const int maxFrameLengthBytes = 4194304;

/// Size of one file chunk (1 MiB); the last chunk of a file may be smaller.
const int chunkSizeBytes = 1048576;

/// Most chunks one file may have (64 GiB at 1 MiB per chunk).
const int maxChunksPerFile = 65536;

/// Size of a SHA-256 chunk hash.
const int hashBytes = 32;

/// Longest file path, in UTF-8 bytes.
const int maxPathBytes = 1024;

/// Most `/`-separated parts in one path.
const int maxPathComponents = 32;

/// Longest single name (device name, path part), in UTF-8 bytes.
const int maxNameBytes = 64;

/// Longest human-readable message (Error, Close reason), in UTF-8 bytes.
const int maxMessageBytes = 1024;

/// Most entries in one DirEntries reply.
const int maxListDirEntries = 1000;

/// Digits in the pairing code the server prints.
const int pairingCodeDigits = 6;

/// Time allowed from connect to a finished Hello.
const int handshakeTimeoutMs = 10000;

/// A connection with no frame for this long is closed.
const int idleTimeoutMs = 60000;

/// The client sends Ping this often, well inside [idleTimeoutMs].
const int pingIntervalMs = 20000;

/// How long a printed pairing code stays valid.
const int pairingCodeTtlMs = 120000;

/// Wrong pairing codes on one connection before it is closed.
const int maxPairFailuresPerConnection = 3;

/// Wrong pairing codes across all connections per rate-limit window.
const int maxPairFailuresPerWindow = 10;

/// Time allowed for the TCP connect to the server.
const int connectTimeoutMs = 3000;

/// Fixed part of the client's wait for `CommitOk` (spec §8, D-030).
const int commitTimeoutBaseMs = 30000;

/// Slowest re-hash speed a client allows for at `Commit`: the server
/// re-reads every chunk, and a busy spinning disk can be this slow.
const int commitMinHashBytesPerSecond = 20 * 1048576;

/// Largest thumbnail the server stores, in bytes (spec §16).
const int maxThumbnailBytes = 65536;

/// Longest side a thumbnail should have, in pixels (spec §16).
const int thumbnailMaxSidePx = 256;

/// How long a client waits for `CommitOk` for a file of [sizeBytes]: the
/// base plus the time to re-read the file at the slowest allowed speed.
/// A fixed timeout would make every big file fail on a slow disk.
int commitTimeoutMs(int sizeBytes) =>
    commitTimeoutBaseMs + sizeBytes * 1000 ~/ commitMinHashBytesPerSecond;
