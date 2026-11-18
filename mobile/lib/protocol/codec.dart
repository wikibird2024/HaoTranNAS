/// Turns frames into messages and messages into frames, using
/// `wire_reader.dart` and `wire_writer.dart`.
///
/// Pure: no I/O. Decoding never throws on bad bytes; it returns a
/// result that carries the error, so the connection can close cleanly.
///
/// Skeleton: no logic yet.
library;
