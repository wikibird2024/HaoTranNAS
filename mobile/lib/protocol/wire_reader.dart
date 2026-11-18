/// Reads the protocol's primitive types (spec §2) from a byte buffer:
/// big-endian integers, bool, hash, length-prefixed bytes and strict
/// UTF-8 strings, and list counts.
///
/// Pure: no I/O. Never throws on bad bytes. The first problem is kept as
/// a [WireFailure] value in [WireReader.failure]; after that every read
/// returns a harmless default (0, false, empty) and moves nothing, so a
/// decoder can read field after field and check [WireReader.finish] once
/// at the end.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'limits.dart';

/// Why a buffer could not be read, and where.
final class WireFailure {
  const WireFailure(this.reason, this.offsetBytes);

  /// Short text for logs and the `Error` message, e.g.
  /// `device_name: string of 65 bytes is longer than 64`.
  final String reason;

  /// Byte offset in the buffer where the bad field starts.
  final int offsetBytes;

  @override
  String toString() => '$reason (at byte $offsetBytes)';
}

/// UTF-8 byte order mark. Dart's decoder silently drops it at the start
/// of the input, which would change the text, so it is handled by hand.
const _byteOrderMark = [0xef, 0xbb, 0xbf];

/// Reads one buffer front to back. See the library comment for how
/// failures work.
final class WireReader {
  WireReader(this._bytes) : _view = ByteData.sublistView(_bytes);

  final Uint8List _bytes;
  final ByteData _view;
  int _offsetBytes = 0;
  WireFailure? _failure;

  /// Bytes read so far.
  int get offsetBytes => _offsetBytes;

  /// Bytes not read yet.
  int get remainingBytes => _bytes.length - _offsetBytes;

  /// The first problem found, or null while all reads succeeded.
  WireFailure? get failure => _failure;

  bool get hasFailed => _failure != null;

  /// Records a problem found by the caller (for example a value out of
  /// its allowed set) at [atOffsetBytes], or at the current offset. Only
  /// the first failure is kept.
  void fail(String reason, {int? atOffsetBytes}) {
    _failure ??= WireFailure(reason, atOffsetBytes ?? _offsetBytes);
  }

  /// Fails a field that starts at [startBytes] after its length prefix
  /// was read: moves back to the field start, so a failed read moves
  /// nothing and the failure points at the field.
  void _failField(int startBytes, String reason) {
    if (_failure != null) return;
    _offsetBytes = startBytes;
    fail(reason);
  }

  /// The final check after the last field: returns the first failure, or
  /// a trailing-bytes failure if the buffer was not consumed exactly, or
  /// null when everything was read cleanly.
  WireFailure? finish() {
    if (_failure == null && remainingBytes != 0) {
      fail('$remainingBytes bytes left after the last field');
    }
    return _failure;
  }

  /// True when [sizeBytes] more bytes can be read; records a failure
  /// otherwise (or if an earlier read already failed).
  bool _take(int sizeBytes, String field) {
    if (_failure != null) return false;
    if (sizeBytes > remainingBytes) {
      fail(_pastEnd(field, sizeBytes));
      return false;
    }
    return true;
  }

  String _pastEnd(String field, int sizeBytes) =>
      '$field: needs $sizeBytes bytes, only $remainingBytes left';

  int readU8(String field) {
    if (!_take(1, field)) return 0;
    final value = _view.getUint8(_offsetBytes);
    _offsetBytes += 1;
    return value;
  }

  int readU16(String field) {
    if (!_take(2, field)) return 0;
    final value = _view.getUint16(_offsetBytes);
    _offsetBytes += 2;
    return value;
  }

  int readU32(String field) {
    if (!_take(4, field)) return 0;
    final value = _view.getUint32(_offsetBytes);
    _offsetBytes += 4;
    return value;
  }

  /// A u64 that must be below 2^63 (spec §2). Read as a signed 64-bit
  /// number: a set top bit shows up as a negative value and is rejected.
  int readU64(String field) {
    if (!_take(8, field)) return 0;
    final value = _view.getInt64(_offsetBytes);
    if (value < 0) {
      fail('$field: u64 has the top bit set (must be < 2^63)');
      return 0;
    }
    _offsetBytes += 8;
    return value;
  }

  int readI64(String field) {
    if (!_take(8, field)) return 0;
    final value = _view.getInt64(_offsetBytes);
    _offsetBytes += 8;
    return value;
  }

  /// 0 = false, 1 = true, anything else is malformed.
  bool readBool(String field) {
    if (!_take(1, field)) return false;
    final value = _bytes[_offsetBytes];
    if (value > 1) {
      fail('$field: bool must be 0 or 1, got $value');
      return false;
    }
    _offsetBytes += 1;
    return value == 1;
  }

  /// A raw 32-byte SHA-256 digest (a copy, not a view of the buffer).
  Uint8List readHash(String field) {
    if (!_take(hashBytes, field)) return Uint8List(0);
    return _copyAndSkip(hashBytes);
  }

  /// u32 length, then that many raw bytes (a copy).
  Uint8List readBytes(String field) {
    final startBytes = _offsetBytes;
    final lengthBytes = readU32('$field length');
    if (_failure != null) return Uint8List(0);
    if (lengthBytes > remainingBytes) {
      _failField(startBytes, _pastEnd(field, lengthBytes));
      return Uint8List(0);
    }
    return _copyAndSkip(lengthBytes);
  }

  /// u16 length, then strict UTF-8 of at most [maxBytes] bytes (spec §2,
  /// §4): no overlong forms, no surrogates, nothing above U+10FFFF.
  String readString(String field, {required int maxBytes}) {
    final startBytes = _offsetBytes;
    final lengthBytes = readU16('$field length');
    if (_failure != null) return '';
    if (lengthBytes > remainingBytes) {
      _failField(startBytes, _pastEnd(field, lengthBytes));
      return '';
    }
    if (lengthBytes > maxBytes) {
      _failField(
        startBytes,
        '$field: string of $lengthBytes bytes is longer than $maxBytes',
      );
      return '';
    }
    final text = decodeStrictUtf8(
      Uint8List.sublistView(_bytes, _offsetBytes, _offsetBytes + lengthBytes),
    );
    if (text == null) {
      _failField(startBytes, '$field: not valid UTF-8');
      return '';
    }
    _offsetBytes += lengthBytes;
    return text;
  }

  /// A list's u32 item count, checked against the bytes left before the
  /// caller allocates anything: `count × minItemBytes ≤ remaining`.
  /// Returns 0 on failure, so a loop over the count does nothing.
  int readListCount(String field, {required int minItemBytes}) {
    final startBytes = _offsetBytes;
    final count = readU32('$field count');
    if (_failure != null) return 0;
    if (count * minItemBytes > remainingBytes) {
      _failField(
        startBytes,
        '$field: $count items need at least ${count * minItemBytes} bytes, '
        'only $remainingBytes left',
      );
      return 0;
    }
    return count;
  }

  Uint8List _copyAndSkip(int sizeBytes) {
    final copy = Uint8List.fromList(
      Uint8List.sublistView(_bytes, _offsetBytes, _offsetBytes + sizeBytes),
    );
    _offsetBytes += sizeBytes;
    return copy;
  }
}

/// Strict UTF-8 to text, or null if the bytes are not valid UTF-8.
///
/// Dart's decoder (`allowMalformed: false`) already rejects overlong
/// forms, encoded surrogates and code points above U+10FFFF (checked by
/// the vectors `hello_utf8_surrogate` / `hello_utf8_overlong` and the
/// reader tests). The one thing it does differently is drop a leading
/// byte order mark, so leading BOMs are counted here and put back.
String? decodeStrictUtf8(Uint8List bytes) {
  var startBytes = 0;
  while (startBytes + 3 <= bytes.length &&
      bytes[startBytes] == _byteOrderMark[0] &&
      bytes[startBytes + 1] == _byteOrderMark[1] &&
      bytes[startBytes + 2] == _byteOrderMark[2]) {
    startBytes += 3;
  }
  try {
    final rest = utf8.decode(
      Uint8List.sublistView(bytes, startBytes),
      allowMalformed: false,
    );
    return '﻿' * (startBytes ~/ 3) + rest;
  } on FormatException {
    return null;
  }
}
