import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:haotrannas_mobile/core/bytes/hex.dart';
import 'package:haotrannas_mobile/protocol/wire_reader.dart';
import 'package:haotrannas_mobile/protocol/wire_writer.dart';

WireReader readerOf(String hex) => WireReader(parseHex(hex));

/// A u16 length prefix, then [hex].
WireReader stringReaderOf(String hex) {
  final body = parseHex(hex);
  return WireReader(
    Uint8List.fromList([body.length >> 8, body.length & 0xff, ...body]),
  );
}

void main() {
  group('integers', () {
    test('big-endian u8 u16 u32', () {
      final reader = readerOf('ff 0102 01020304');
      expect(reader.readU8('a'), 0xff);
      expect(reader.readU16('b'), 0x0102);
      expect(reader.readU32('c'), 0x01020304);
      expect(reader.finish(), isNull);
    });

    test('u32 max is read as a positive number', () {
      expect(readerOf('ffffffff').readU32('x'), 0xffffffff);
    });

    test('u64 2^63 - 1 is the largest accepted', () {
      final reader = readerOf('7fffffffffffffff');
      expect(reader.readU64('x'), 0x7fffffffffffffff);
      expect(reader.finish(), isNull);
    });

    test('u64 with the top bit set is rejected', () {
      for (final hex in ['8000000000000000', 'ffffffffffffffff']) {
        final reader = readerOf(hex);
        expect(reader.readU64('version_id'), 0);
        expect(reader.failure?.reason, contains('top bit'));
      }
    });

    test('i64 min and -1', () {
      final reader = readerOf('8000000000000000 ffffffffffffffff');
      expect(reader.readI64('a'), -0x8000000000000000);
      expect(reader.readI64('b'), -1);
      expect(reader.finish(), isNull);
    });

    test('short buffer fails, does not throw', () {
      final reader = readerOf('0102');
      expect(reader.readU32('x'), 0);
      expect(reader.failure?.reason, contains('needs 4 bytes'));
    });
  });

  group('bool', () {
    test('0 and 1', () {
      final reader = readerOf('00 01');
      expect(reader.readBool('a'), isFalse);
      expect(reader.readBool('b'), isTrue);
      expect(reader.finish(), isNull);
    });

    test('2 is malformed', () {
      final reader = readerOf('02');
      reader.readBool('has_more');
      expect(reader.failure?.reason, contains('bool'));
    });
  });

  group('hash and bytes', () {
    test('hash needs exactly 32 bytes', () {
      expect(
        WireReader(Uint8List(31))..readHash('h'),
        isA<WireReader>().having(
          (reader) => reader.hasFailed,
          'hasFailed',
          isTrue,
        ),
      );
      final reader = WireReader(Uint8List(32));
      expect(reader.readHash('h'), hasLength(32));
      expect(reader.finish(), isNull);
    });

    test('bytes length past the end fails', () {
      final reader = readerOf('00000005 0102');
      expect(reader.readBytes('data'), isEmpty);
      expect(reader.hasFailed, isTrue);
    });

    test('empty bytes', () {
      final reader = readerOf('00000000');
      expect(reader.readBytes('data'), isEmpty);
      expect(reader.finish(), isNull);
    });

    test('result is a copy, not a view of the buffer', () {
      final buffer = parseHex('00000002 aabb');
      final bytes = WireReader(buffer).readBytes('data');
      buffer[4] = 0;
      expect(bytes, [0xaa, 0xbb]);
    });
  });

  group('strings', () {
    test('ASCII and Vietnamese', () {
      final text = 'Điện thoại của Hào';
      final encoded = utf8.encode(text);
      final reader = WireReader(
        Uint8List.fromList([0, encoded.length, ...encoded]),
      );
      expect(reader.readString('name', maxBytes: 64), text);
      expect(reader.finish(), isNull);
    });

    test('at the limit is fine, one byte over fails', () {
      expect(stringReaderOf('6e' * 64).readString('n', maxBytes: 64), 'n' * 64);
      final reader = stringReaderOf('6e' * 65);
      reader.readString('device_name', maxBytes: 64);
      expect(reader.failure?.reason, contains('longer than 64'));
    });

    test('length past the end fails', () {
      final reader = readerOf('00ff 616263');
      reader.readString('s', maxBytes: 1024);
      expect(reader.hasFailed, isTrue);
    });

    // Dart's decoder rejects all of these on its own; these tests keep it
    // that way if the SDK ever changes.
    final badUtf8 = {
      'byte 0xff': 'ff',
      'encoded surrogate U+D800': 'eda080',
      'encoded surrogate U+DFFF': 'edbfbf',
      "overlong '/' (2 bytes)": 'c0af',
      "overlong '/' (3 bytes)": 'e080af',
      'overlong NUL (2 bytes)': 'c080',
      'above U+10FFFF': 'f4908080',
      'lone continuation byte': '80',
      'truncated 3-byte form': 'e282',
      '5-byte form': 'f888808080',
    };
    badUtf8.forEach((name, hex) {
      test('rejects $name', () {
        final reader = stringReaderOf(hex);
        reader.readString('s', maxBytes: 1024);
        expect(reader.failure?.reason, contains('not valid UTF-8'));
      });
    });

    test('accepts U+10FFFF and U+FFFF edge code points', () {
      expect(
        stringReaderOf('f48fbfbf').readString('s', maxBytes: 8),
        '\u{10FFFF}',
      );
      expect(stringReaderOf('efbfbf').readString('s', maxBytes: 8), '￿');
    });

    test('keeps a leading byte order mark (Dart would drop it)', () {
      final reader = stringReaderOf('efbbbf efbbbf 61');
      final text = reader.readString('s', maxBytes: 64);
      expect(text, '﻿﻿a');
      expect(reader.finish(), isNull);
      final writer = WireWriter()..writeString(text, 's', maxBytes: 64);
      expect(writer.toBytes(), parseHex('0007 efbbbf efbbbf 61'));
    });

    test('a BOM alone is one character', () {
      expect(stringReaderOf('efbbbf').readString('s', maxBytes: 8), '﻿');
    });
  });

  group('list count', () {
    test('count that fits', () {
      final reader = readerOf('00000002 00000001 00000002');
      expect(reader.readListCount('l', minItemBytes: 4), 2);
    });

    test('count larger than the bytes left fails before allocating', () {
      final reader = readerOf('ffffffff 00000001');
      expect(reader.readListCount('missing_indexes', minItemBytes: 4), 0);
      expect(reader.failure?.reason, contains('items need at least'));
    });

    test('count × item size exactly equal to the bytes left is fine', () {
      final reader = WireReader(
        Uint8List.fromList([0, 0, 0, 2, ...List.filled(64, 0)]),
      );
      expect(reader.readListCount('hashes', minItemBytes: 32), 2);
    });
  });

  group('failure handling', () {
    test('first failure is kept, later reads return defaults', () {
      final reader = readerOf('02 01 0001');
      reader.readBool('first');
      expect(reader.readU8('second'), 0);
      expect(reader.readU16('third'), 0);
      expect(reader.offsetBytes, 0);
      expect(reader.failure?.reason, startsWith('first'));
    });

    test('finish reports trailing bytes', () {
      final reader = readerOf('01 02');
      reader.readU8('x');
      expect(reader.finish()?.reason, contains('1 bytes left'));
    });

    test('a failed field points at its start and moves nothing', () {
      final cases = <String, void Function(WireReader)>{
        '01 0041 6e': (reader) => reader.readString('s', maxBytes: 64),
        '01 0002 c0af': (reader) => reader.readString('s', maxBytes: 64),
        '01 00000005 00': (reader) => reader.readBytes('b'),
        '01 00000002 00': (reader) =>
            reader.readListCount('l', minItemBytes: 4),
        '01 8000000000000000': (reader) => reader.readU64('u'),
      };
      cases.forEach((hex, readField) {
        final reader = readerOf(hex);
        reader.readU8('first');
        readField(reader);
        expect(reader.failure?.offsetBytes, 1, reason: hex);
        expect(reader.offsetBytes, 1, reason: hex);
      });
    });
  });

  group('writer rejects values that do not fit (ArgumentError)', () {
    test('integers out of range', () {
      expect(() => WireWriter().writeU8(256, 'x'), throwsArgumentError);
      expect(() => WireWriter().writeU16(-1, 'x'), throwsArgumentError);
      expect(
        () => WireWriter().writeU32(0x100000000, 'x'),
        throwsArgumentError,
      );
      expect(() => WireWriter().writeU64(-1, 'x'), throwsArgumentError);
    });

    test('hash not 32 bytes', () {
      expect(
        () => WireWriter().writeHash(Uint8List(31), 'h'),
        throwsArgumentError,
      );
    });

    test('string over its limit or with a lone surrogate', () {
      expect(
        () => WireWriter().writeString('n' * 65, 's', maxBytes: 64),
        throwsArgumentError,
      );
      expect(
        () => WireWriter().writeString('a\uD800', 's', maxBytes: 64),
        throwsArgumentError,
      );
      expect(
        () => WireWriter().writeString('\uDC00', 's', maxBytes: 64),
        throwsArgumentError,
      );
    });

    test('a surrogate pair (emoji) is fine', () {
      final writer = WireWriter()..writeString('📷', 's', maxBytes: 64);
      expect(writer.toBytes(), parseHex('0004 f09f93b7'));
    });

    test('i64 and u64 extremes', () {
      final writer = WireWriter()
        ..writeI64(-0x8000000000000000, 'a')
        ..writeU64(0x7fffffffffffffff, 'b');
      expect(writer.toBytes(), parseHex('8000000000000000 7fffffffffffffff'));
    });
  });
}
