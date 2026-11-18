/// Writes the protocol's primitive types (spec §2) into a growing byte
/// buffer; the mirror of `wire_reader.dart`.
///
/// Pure: no I/O. Byte formats are hand-written, no code generator.
///
/// A value that does not fit its wire type (a negative or too large
/// integer, a hash that is not 32 bytes, a string over its limit or with
/// a lone surrogate) is a bug in the caller, not bad input from the
/// network, so it throws [ArgumentError].
library;

import 'dart:convert';
import 'dart:typed_data';

import 'limits.dart';

final class WireWriter {
  /// Copies each added list, so the reused [_scratch] is safe to add.
  final BytesBuilder _builder = BytesBuilder();
  final ByteData _scratch = ByteData(8);

  /// Bytes written so far.
  int get lengthBytes => _builder.length;

  /// The bytes written so far.
  Uint8List toBytes() => _builder.toBytes();

  void writeU8(int value, String field) {
    _checkRange(value, 0xff, field);
    _builder.addByte(value);
  }

  void writeU16(int value, String field) {
    _checkRange(value, 0xffff, field);
    _scratch.setUint16(0, value);
    _builder.add(Uint8List.sublistView(_scratch, 0, 2));
  }

  void writeU32(int value, String field) {
    _checkRange(value, 0xffffffff, field);
    _scratch.setUint32(0, value);
    _builder.add(Uint8List.sublistView(_scratch, 0, 4));
  }

  /// A u64 below 2^63. Every non-negative Dart int is below 2^63, so only
  /// negative values are rejected.
  void writeU64(int value, String field) {
    if (value < 0) {
      throw ArgumentError.value(value, field, 'u64 must be 0 ..< 2^63');
    }
    _writeInt64(value);
  }

  void writeI64(int value, String field) => _writeInt64(value);

  void writeBool(bool value) => _builder.addByte(value ? 1 : 0);

  void writeHash(Uint8List hash, String field) {
    if (hash.length != hashBytes) {
      throw ArgumentError.value(
        hash.length,
        field,
        'hash must be $hashBytes bytes',
      );
    }
    _builder.add(hash);
  }

  /// u32 length, then the raw bytes.
  void writeBytes(Uint8List bytes, String field) {
    writeU32(bytes.length, '$field length');
    _builder.add(bytes);
  }

  /// u16 length, then UTF-8 of at most [maxBytes] bytes.
  void writeString(String text, String field, {required int maxBytes}) {
    if (hasLoneSurrogate(text)) {
      throw ArgumentError.value(text, field, 'lone surrogate, not valid UTF-8');
    }
    final encoded = utf8.encode(text);
    if (encoded.length > maxBytes) {
      throw ArgumentError.value(
        encoded.length,
        field,
        'string longer than $maxBytes bytes',
      );
    }
    writeU16(encoded.length, '$field length');
    _builder.add(encoded);
  }

  /// A list's u32 item count; the caller writes the items after it.
  void writeListCount(int count, String field) =>
      writeU32(count, '$field count');

  void _writeInt64(int value) {
    _scratch.setInt64(0, value);
    _builder.add(Uint8List.sublistView(_scratch, 0, 8));
  }

  static void _checkRange(int value, int max, String field) {
    if (value < 0 || value > max) {
      throw ArgumentError.value(value, field, 'must be 0 ..= $max');
    }
  }
}

/// True if [text] has a UTF-16 surrogate without its partner. Such a
/// string has no UTF-8 form (`utf8.encode` would silently replace it).
bool hasLoneSurrogate(String text) {
  for (var i = 0; i < text.length; i++) {
    final unit = text.codeUnitAt(i);
    if (unit >= 0xd800 && unit <= 0xdbff) {
      final hasLowPartner =
          i + 1 < text.length && (text.codeUnitAt(i + 1) & 0xfc00) == 0xdc00;
      if (!hasLowPartner) return true;
      i++;
    } else if (unit >= 0xdc00 && unit <= 0xdfff) {
      return true;
    }
  }
  return false;
}
