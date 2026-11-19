// DNS codec tests. The first group is adapted from Protocol Lab
// (test/protocols/inside_depth_test.dart, group 'DNS / mDNS'): same
// hand-built packet, checks on records instead of the Inside view.
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:haotrannas_mobile/discovery/dns_codec.dart';

Uint8List _bytes(List<int> values) => Uint8List.fromList(values);

List<int> _ascii(String text) => text.codeUnits;

void main() {
  // A hand-built mDNS answer: PTR, then SRV and A as additional records,
  // with compression pointers back into earlier names.
  // dart format off
  final response = _bytes([
    0x00, 0x00, 0x84, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x02,
    // offset 12: _http._tcp.local PTR IN ttl 4500
    0x05, ..._ascii('_http'), 0x04, ..._ascii('_tcp'), 0x05, ..._ascii('local'), 0x00,
    0x00, 0x0c, 0x00, 0x01, 0x00, 0x00, 0x11, 0x94, 0x00, 0x0a,
    // offset 40: Kitchen + pointer to offset 12
    0x07, ..._ascii('Kitchen'), 0xc0, 0x0c,
    // offset 50: SRV for Kitchen (pointer 40), cache flush, ttl 120
    0xc0, 0x28, 0x00, 0x21, 0x80, 0x01, 0x00, 0x00, 0x00, 0x78, 0x00, 0x0e,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x50,
    // offset 68: esp32 + pointer to "local" at offset 23
    0x05, ..._ascii('esp32'), 0xc0, 0x17,
    // offset 76: A for esp32.local (pointer 68)
    0xc0, 0x44, 0x00, 0x01, 0x80, 0x01, 0x00, 0x00, 0x00, 0x78, 0x00, 0x04, 192, 168, 1, 42,
  ]);
  // dart format on

  group('from Protocol Lab', () {
    test('reads PTR → SRV → A through compression pointers', () {
      final message = decodeDns(response)!;
      expect(message.isResponse, isTrue);
      final records = message.records;
      expect(records.map((record) => record.section), [
        DnsSection.answer,
        DnsSection.additional,
        DnsSection.additional,
      ]);
      expect(
        (records[0].type, records[0].ttlSeconds, records[0].target),
        (dnsTypePtr, 4500, 'Kitchen._http._tcp.local'),
      );
      expect(
        (records[1].name, records[1].target, records[1].port),
        ('Kitchen._http._tcp.local', 'esp32.local', 80),
      );
      expect(
        (records[2].name, records[2].address),
        ('esp32.local', '192.168.1.42'),
      );
    });

    test('query round trip, QU bit in the class', () {
      final bytes = encodeDnsQuery([
        const DnsQuestion('_http._tcp.local', dnsTypePtr, wantsUnicast: true),
      ]);
      final message = decodeDns(bytes)!;
      expect(message.isResponse, isFalse);
      expect(
        (message.questions.single.name, message.questions.single.wantsUnicast),
        ('_http._tcp.local', true),
      );
    });

    test('a cut-off message is null, not a throw', () {
      expect(decodeDns(Uint8List.sublistView(response, 0, 30)), isNull);
    });
  });

  group('encode / decode', () {
    test('PTR query for the service, QU off, id 0: exact bytes', () {
      final bytes = encodeDnsQuery([
        const DnsQuestion('_haotrannas._tcp.local', dnsTypePtr),
      ]);
      // dart format off
      expect(bytes, [
        0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0,
        11, ..._ascii('_haotrannas'), 4, ..._ascii('_tcp'), 5, ..._ascii('local'), 0,
        0, 12, 0, 1,
      ]);
      // dart format on
    });

    test('response round trip: every record type, sections kept', () {
      final original = DnsMessage(
        id: 7,
        isResponse: true,
        records: [
          const DnsRecord(
            name: '_s._tcp.local',
            type: dnsTypePtr,
            ttlSeconds: 4500,
            target: 'Box._s._tcp.local',
          ),
          const DnsRecord(
            name: 'Box._s._tcp.local',
            type: dnsTypeSrv,
            ttlSeconds: 120,
            section: DnsSection.additional,
            target: 'box.local',
            port: 7443,
          ),
          const DnsRecord(
            name: 'Box._s._tcp.local',
            type: dnsTypeTxt,
            ttlSeconds: 4500,
            section: DnsSection.additional,
            texts: ['v=1', 'fp=0123456789abcdef'],
          ),
          DnsRecord(
            name: 'box.local',
            type: dnsTypeA,
            ttlSeconds: 120,
            section: DnsSection.additional,
            addressBytes: _bytes([10, 0, 0, 5]),
          ),
          DnsRecord(
            name: 'box.local',
            type: dnsTypeAaaa,
            ttlSeconds: 120,
            section: DnsSection.additional,
            addressBytes: _bytes([0xfe, 0x80, ...List.filled(13, 0), 1]),
          ),
          DnsRecord(
            name: 'box.local',
            type: 47,
            ttlSeconds: 120,
            section: DnsSection.authority,
            rawData: _bytes([1, 2, 3]),
          ),
        ],
      );
      final decoded = decodeDns(encodeDnsMessage(original))!;
      expect((decoded.id, decoded.isResponse), (7, true));
      // The encoder writes sections in order: answer, authority, additional.
      expect(decoded.records.map((record) => record.type), [
        dnsTypePtr,
        47,
        dnsTypeSrv,
        dnsTypeTxt,
        dnsTypeA,
        dnsTypeAaaa,
      ]);
      final byType = {
        for (final record in decoded.records) record.type: record,
      };
      expect(byType[dnsTypePtr]!.target, 'Box._s._tcp.local');
      final service = byType[dnsTypeSrv]!;
      expect(
        (service.target, service.port, service.section),
        ('box.local', 7443, DnsSection.additional),
      );
      expect(byType[dnsTypeTxt]!.texts, ['v=1', 'fp=0123456789abcdef']);
      expect(byType[dnsTypeA]!.address, '10.0.0.5');
      expect(byType[dnsTypeAaaa]!.address, 'fe80:0:0:0:0:0:0:1');
      expect(byType[47]!.rawData, [1, 2, 3]);
      expect(byType[47]!.section, DnsSection.authority);
    });

    test('empty TXT is one zero byte and decodes to no texts', () {
      final bytes = encodeDnsMessage(
        const DnsMessage(
          isResponse: true,
          records: [
            DnsRecord(name: 'x.local', type: dnsTypeTxt, ttlSeconds: 1),
          ],
        ),
      );
      expect(bytes.sublist(bytes.length - 3), [
        0,
        1,
        0,
      ]); // data length 1, then 0
      expect(decodeDns(bytes)!.records.single.texts, isEmpty);
    });

    test('TXT string cut off inside its data keeps the strings before it', () {
      final bytes = encodeDnsMessage(
        const DnsMessage(
          isResponse: true,
          records: [
            DnsRecord(
              name: 'x.local',
              type: dnsTypeTxt,
              ttlSeconds: 1,
              texts: ['v=1', 'ab'],
            ),
          ],
        ),
      );
      bytes[bytes.length - 3] = 9; // "ab" claims 9 bytes, only 2 left
      expect(decodeDns(bytes)!.records.single.texts, ['v=1']);
    });

    test('encoder refuses a label over 63 bytes', () {
      expect(
        () => encodeDnsQuery([DnsQuestion('${'a' * 64}.local', dnsTypeA)]),
        throwsArgumentError,
      );
    });
  });

  group('bad bytes → null, never a throw', () {
    test('every truncation of a good response', () {
      for (var length = 0; length < response.length; length++) {
        expect(
          decodeDns(Uint8List.sublistView(response, 0, length)),
          isNull,
          reason: 'length $length',
        );
      }
    });

    test('extra bytes after the records', () {
      expect(decodeDns(_bytes([...response, 0])), isNull);
    });

    test('pointer to itself (loop)', () {
      final bytes = _bytes([
        0,
        0,
        0x84,
        0,
        0,
        1,
        0,
        0,
        0,
        0,
        0,
        0,
        0xc0,
        12,
        0,
        1,
        0,
        1,
      ]);
      expect(decodeDns(bytes), isNull);
    });

    test('two pointers pointing at each other', () {
      final bytes = _bytes([
        0,
        0,
        0x84,
        0,
        0,
        1,
        0,
        0,
        0,
        0,
        0,
        0,
        0xc0,
        14,
        0xc0,
        12,
        0,
        1,
        0,
        1,
      ]);
      expect(decodeDns(bytes), isNull);
    });

    test('pointer past the end, reserved label type', () {
      expect(
        decodeDns(
          _bytes([
            0,
            0,
            0x84,
            0,
            0,
            1,
            0,
            0,
            0,
            0,
            0,
            0,
            0xc0,
            200,
            0,
            1,
            0,
            1,
          ]),
        ),
        isNull,
      );
      expect(
        decodeDns(
          _bytes([0, 0, 0x84, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0x40, 0, 0, 1, 0, 1]),
        ),
        isNull,
      );
    });

    test('SRV whose host name runs past its data length', () {
      final bytes = encodeDnsMessage(
        const DnsMessage(
          isResponse: true,
          records: [
            DnsRecord(
              name: 'x.local',
              type: dnsTypeSrv,
              ttlSeconds: 1,
              target: 'host.local',
              port: 1,
            ),
          ],
        ),
      );
      // Header 12 + name "x.local" 9 + type, class, ttl 8 → data length.
      const dataLengthAt = 12 + 9 + 8;
      bytes[dataLengthAt + 1] -= 1; // the name now ends outside the data
      expect(decodeDns(bytes), isNull);
    });

    test('5000 random buffers and bit flips of a good one', () {
      final random = Random(42);
      for (var round = 0; round < 5000; round++) {
        final noise = _bytes(
          List.generate(random.nextInt(80), (_) => random.nextInt(256)),
        );
        decodeDns(noise); // must not throw
        final flipped = Uint8List.fromList(response);
        flipped[random.nextInt(flipped.length)] ^= 1 << random.nextInt(8);
        decodeDns(flipped);
      }
    });
  });
}
