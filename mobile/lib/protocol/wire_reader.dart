/// Reads big-endian integers, hashes and length-prefixed UTF-8 strings
/// from a byte buffer, checking every length against `limits.dart`.
///
/// Pure: no I/O. Never throws on bad bytes: a short or malformed buffer
/// is reported as a decode error the caller can log and act on.
///
/// Skeleton: no logic yet.
library;
