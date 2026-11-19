// Cross-language check: a real mDNS answer captured from the Rust server's
// announcement code (protocol/fixtures/mdns_announcement.hex, see its
// README) must be understood by the Dart discovery code.
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:haotrannas_mobile/core/bytes/hex.dart';
import 'package:haotrannas_mobile/discovery/discovery.dart';
import 'package:haotrannas_mobile/discovery/dns_codec.dart';

import '../protocol/vector_files.dart';
import 'discovery_test.dart' show FakeMdnsTransport;

Uint8List loadRustAnnouncement() {
  final fixturesDirectory = Directory(
    '${findVectorsDirectory().parent.path}${Platform.pathSeparator}fixtures',
  );
  final hexText = File(
    '${fixturesDirectory.path}${Platform.pathSeparator}mdns_announcement.hex',
  ).readAsStringSync().replaceAll(RegExp(r'\s'), '');
  return parseHex(hexText);
}

void main() {
  test('the Rust server announcement decodes as a DNS message', () {
    final message = decodeDns(loadRustAnnouncement());
    expect(message, isNotNull);
  });

  test('Dart discovery finds the server in the Rust announcement', () async {
    final announcement = loadRustAnnouncement();
    final transport = FakeMdnsTransport();
    transport.onQuery = (query) {
      if (query.questions.isNotEmpty) {
        scheduleMicrotask(() => transport.deliver(announcement));
      }
    };

    final servers = await discoverServers(
      timeout: const Duration(milliseconds: 80),
      transport: transport,
    );

    expect(servers, hasLength(1));
    final server = servers.single;
    expect(server.instanceName, startsWith('haotrannas'));
    expect(server.ipv4Address, InternetAddress('127.0.0.1'));
    expect(server.port, 47100);
    // fp = first 16 hex chars of SHA-256("abc"), see the fixture README.
    expect(server.fingerprintPrefix, 'ba7816bf8f01cfea');
    expect(server.protocolVersion, 1);
  });

  test('a pin that does not match filters the Rust announcement out', () async {
    final announcement = loadRustAnnouncement();
    final transport = FakeMdnsTransport();
    transport.onQuery = (query) {
      scheduleMicrotask(() => transport.deliver(announcement));
    };

    final servers = await discoverServers(
      timeout: const Duration(milliseconds: 80),
      transport: transport,
      pinnedFingerprintPrefix: '0000000000000000',
    );

    expect(servers, isEmpty);
  });
}
