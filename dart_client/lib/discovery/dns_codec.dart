// Copied from Protocol Lab (lib/protocols/dns/dns_codec.dart), adapted:
// no Frame / Field / FieldReader (no Inside view here), a small private
// byte reader instead, a whole-message encoder for tests, and pointer
// loops are caught across jumps (the original counted per call).

/// DNS messages (RFC 1035) as mDNS uses them (RFC 6762): a 12-byte header,
/// questions, then answer / authority / additional records. Names are
/// length-prefixed labels, and a name may end in a 2-byte pointer to an
/// earlier name (compression).
///
/// Pure: bytes in, records out, no I/O. [decodeDns] never throws on bad
/// bytes: it returns null.
library;

import 'dart:convert';
import 'dart:typed_data';

const dnsTypeA = 1;
const dnsTypePtr = 12;
const dnsTypeTxt = 16;
const dnsTypeAaaa = 28;
const dnsTypeSrv = 33;

const dnsTypeNames = {
  dnsTypeA: 'A',
  dnsTypePtr: 'PTR',
  dnsTypeTxt: 'TXT',
  dnsTypeAaaa: 'AAAA',
  dnsTypeSrv: 'SRV',
  47: 'NSEC',
  255: 'ANY',
};

/// Class IN. mDNS uses its top bit as "QU" in questions and "cache flush"
/// in records.
const _classInternet = 1;
const _classTopBit = 0x8000;

/// Longest name on the wire (RFC 1035 §2.3.4) and how many compression
/// pointers one name may follow before we call it a loop.
const _maxNameBytes = 255;
const _maxPointerJumps = 64;

class DnsQuestion {
  const DnsQuestion(this.name, this.type, {this.wantsUnicast = false});
  final String name;
  final int type;

  /// mDNS "QU" bit (top bit of the class): please answer me directly.
  final bool wantsUnicast;
}

enum DnsSection { answer, authority, additional }

class DnsRecord {
  const DnsRecord({
    required this.name,
    required this.type,
    required this.ttlSeconds,
    this.section = DnsSection.answer,
    this.target,
    this.port,
    this.texts = const [],
    this.addressBytes,
    this.rawData,
  });

  final String name;
  final int type;

  /// 0 = goodbye: the record is leaving.
  final int ttlSeconds;
  final DnsSection section;

  /// PTR → instance name; SRV → host name.
  final String? target;

  /// SRV only.
  final int? port;

  /// TXT strings (`key=value`), empty strings dropped.
  final List<String> texts;

  /// A (4 bytes) / AAAA (16 bytes).
  final Uint8List? addressBytes;

  /// Data of a record type this codec does not read (kept for the encoder).
  final Uint8List? rawData;

  /// `192.168.1.42` or `fe80:0:0:0:...`; null when not an address record.
  String? get address {
    final bytes = addressBytes;
    if (bytes == null) return null;
    if (bytes.length == 4) return bytes.join('.');
    return [
      for (var index = 0; index + 1 < bytes.length; index += 2)
        (bytes[index] << 8 | bytes[index + 1]).toRadixString(16),
    ].join(':');
  }
}

class DnsMessage {
  const DnsMessage({
    this.id = 0,
    required this.isResponse,
    this.questions = const [],
    this.records = const [],
  });
  final int id;
  final bool isResponse;
  final List<DnsQuestion> questions;
  final List<DnsRecord> records;
}

/// An mDNS query (id 0, no flags), one question per name.
Uint8List encodeDnsQuery(List<DnsQuestion> questions, {int id = 0}) =>
    encodeDnsMessage(
      DnsMessage(id: id, isResponse: false, questions: questions),
    );

/// Whole message, no name compression. Responses set QR and AA, as mDNS
/// answers do. Throws [ArgumentError] for input that cannot be encoded
/// (label over 63 bytes, TXT string over 255 bytes): that is a bug in the
/// caller, not bad bytes from the network.
Uint8List encodeDnsMessage(DnsMessage message) {
  int countOf(DnsSection section) =>
      message.records.where((record) => record.section == section).length;
  final out = BytesBuilder();
  out.add(
    (ByteData(12)
          ..setUint16(0, message.id)
          ..setUint16(2, message.isResponse ? 0x8400 : 0)
          ..setUint16(4, message.questions.length)
          ..setUint16(6, countOf(DnsSection.answer))
          ..setUint16(8, countOf(DnsSection.authority))
          ..setUint16(10, countOf(DnsSection.additional)))
        .buffer
        .asUint8List(),
  );
  for (final question in message.questions) {
    out.add(_encodeName(question.name));
    out.add(
      _uint16Pair(
        question.type,
        (question.wantsUnicast ? _classTopBit : 0) | _classInternet,
      ),
    );
  }
  for (final section in DnsSection.values) {
    for (final record in message.records) {
      if (record.section != section) continue;
      final data = _encodeRecordData(record);
      out.add(_encodeName(record.name));
      out.add(_uint16Pair(record.type, _classInternet));
      out.add(
        (ByteData(6)
              ..setUint32(0, record.ttlSeconds)
              ..setUint16(4, data.length))
            .buffer
            .asUint8List(),
      );
      out.add(data);
    }
  }
  return out.toBytes();
}

Uint8List _uint16Pair(int first, int second) =>
    (ByteData(4)
          ..setUint16(0, first)
          ..setUint16(2, second))
        .buffer
        .asUint8List();

Uint8List _encodeName(String name) {
  final out = BytesBuilder();
  for (final label in name.split('.').where((label) => label.isNotEmpty)) {
    final bytes = utf8.encode(label);
    if (bytes.length > 63) {
      throw ArgumentError.value(label, 'name', 'label longer than 63 bytes');
    }
    out
      ..addByte(bytes.length)
      ..add(bytes);
  }
  out.addByte(0);
  return out.toBytes();
}

Uint8List _encodeRecordData(DnsRecord record) {
  switch (record.type) {
    case dnsTypeA || dnsTypeAaaa:
      return record.addressBytes ?? Uint8List(0);
    case dnsTypePtr:
      return _encodeName(record.target ?? '');
    case dnsTypeSrv:
      return (BytesBuilder()
            ..add(_uint16Pair(0, 0)) // priority, weight
            ..add(
              (ByteData(
                2,
              )..setUint16(0, record.port ?? 0)).buffer.asUint8List(),
            )
            ..add(_encodeName(record.target ?? '')))
          .toBytes();
    case dnsTypeTxt:
      final out = BytesBuilder();
      for (final text in record.texts) {
        final bytes = utf8.encode(text);
        if (bytes.length > 255) {
          throw ArgumentError.value(text, 'texts', 'longer than 255 bytes');
        }
        out
          ..addByte(bytes.length)
          ..add(bytes);
      }
      // RFC 6763 §6.1: an empty TXT record is one zero byte.
      if (record.texts.isEmpty) out.addByte(0);
      return out.toBytes();
    default:
      return record.rawData ?? Uint8List(0);
  }
}

/// Decodes one DNS message. Returns null for anything malformed (cut off,
/// bad pointer, pointer loop, extra bytes after the records).
DnsMessage? decodeDns(Uint8List bytes) {
  try {
    return _decode(bytes);
  } on FormatException {
    return null;
  }
}

DnsMessage _decode(Uint8List bytes) {
  final reader = _ByteReader(bytes);
  final id = reader.uint16();
  final flags = reader.uint16();
  final questionCount = reader.uint16();
  final answerCount = reader.uint16();
  final authorityCount = reader.uint16();
  final additionalCount = reader.uint16();
  final questions = <DnsQuestion>[];
  for (var index = 0; index < questionCount; index++) {
    final name = _readName(bytes, reader.offset);
    reader.offset = name.end;
    final type = reader.uint16();
    final klass = reader.uint16();
    questions.add(
      DnsQuestion(name.name, type, wantsUnicast: klass & _classTopBit != 0),
    );
  }
  final sections = [
    for (var index = 0; index < answerCount; index++) DnsSection.answer,
    for (var index = 0; index < authorityCount; index++) DnsSection.authority,
    for (var index = 0; index < additionalCount; index++) DnsSection.additional,
  ];
  final records = [
    for (final section in sections) _readRecord(reader, bytes, section),
  ];
  if (!reader.isDone) {
    throw const FormatException('extra bytes after the records');
  }
  return DnsMessage(
    id: id,
    isResponse: flags & 0x8000 != 0,
    questions: questions,
    records: records,
  );
}

/// Reads a name at [offset]: labels, possibly ending in a compression
/// pointer. Returns the name and where it ends in the message (just after
/// the first pointer, or after the zero byte).
({String name, int end}) _readName(Uint8List bytes, int offset) {
  final labels = <String>[];
  var position = offset;
  int? end;
  var jumps = 0;
  var nameBytes = 0;
  while (true) {
    if (position >= bytes.length) {
      throw const FormatException('name runs past the end');
    }
    final length = bytes[position];
    if (length & 0xc0 == 0xc0) {
      if (position + 1 >= bytes.length) {
        throw const FormatException('pointer cut off');
      }
      end ??= position + 2;
      if (++jumps > _maxPointerJumps) {
        throw const FormatException('pointer loop');
      }
      position = (length & 0x3f) << 8 | bytes[position + 1];
      continue;
    }
    if (length & 0xc0 != 0) throw const FormatException('reserved label type');
    if (length == 0) {
      end ??= position + 1;
      break;
    }
    if (position + 1 + length > bytes.length) {
      throw const FormatException('label runs past the end');
    }
    nameBytes += 1 + length;
    if (nameBytes > _maxNameBytes) throw const FormatException('name too long');
    labels.add(
      utf8.decode(
        Uint8List.sublistView(bytes, position + 1, position + 1 + length),
        allowMalformed: true,
      ),
    );
    position += 1 + length;
  }
  return (name: labels.join('.'), end: end);
}

DnsRecord _readRecord(_ByteReader reader, Uint8List bytes, DnsSection section) {
  final name = _readName(bytes, reader.offset);
  reader.offset = name.end;
  final type = reader.uint16();
  reader.uint16(); // class (+ cache flush bit): not needed
  final ttlSeconds = reader.uint32();
  final length = reader.uint16();
  final dataStart = reader.offset;
  final data = reader.take(length);
  String? target;
  int? port;
  Uint8List? addressBytes;
  Uint8List? rawData;
  final texts = <String>[];
  switch (type) {
    case dnsTypeA when length == 4:
    case dnsTypeAaaa when length == 16:
      addressBytes = Uint8List.fromList(data);
    case dnsTypePtr:
      final pointed = _readName(bytes, dataStart);
      if (pointed.end > dataStart + length) {
        throw const FormatException('PTR name runs past its data');
      }
      target = pointed.name;
    case dnsTypeSrv when length >= 7:
      port = ByteData.sublistView(data).getUint16(4);
      final host = _readName(bytes, dataStart + 6);
      if (host.end > dataStart + length) {
        throw const FormatException('SRV name runs past its data');
      }
      target = host.name;
    case dnsTypeTxt:
      var position = 0;
      while (position < data.length) {
        final textLength = data[position];
        if (position + 1 + textLength > data.length) break;
        final text = utf8.decode(
          Uint8List.sublistView(data, position + 1, position + 1 + textLength),
          allowMalformed: true,
        );
        if (text.isNotEmpty) texts.add(text);
        position += 1 + textLength;
      }
    default:
      rawData = Uint8List.fromList(data);
  }
  return DnsRecord(
    name: name.name,
    type: type,
    ttlSeconds: ttlSeconds,
    section: section,
    target: target,
    port: port,
    texts: List.unmodifiable(texts),
    addressBytes: addressBytes,
    rawData: rawData,
  );
}

/// Big-endian reads with bounds checks; past the end → [FormatException]
/// (caught in [decodeDns]).
class _ByteReader {
  _ByteReader(this.bytes);

  final Uint8List bytes;
  int offset = 0;

  bool get isDone => offset >= bytes.length;

  Uint8List take(int count) {
    if (offset + count > bytes.length) throw const FormatException('cut off');
    final slice = Uint8List.sublistView(bytes, offset, offset + count);
    offset += count;
    return slice;
  }

  int uint16() => ByteData.sublistView(take(2)).getUint16(0);

  int uint32() => ByteData.sublistView(take(4)).getUint32(0);
}
