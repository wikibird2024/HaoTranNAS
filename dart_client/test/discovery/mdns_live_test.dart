// Live mDNS on this PC's real network: never in CI (CI runs
// `flutter test --exclude-tags server,mdns`). Run it by hand:
//
//   flutter test --tags mdns test/discovery/mdns_live_test.dart
//   NAS_EXPECT_MDNS_FP=3f9ac21b77e01234 flutter test --tags mdns ...
//
// Without NAS_EXPECT_MDNS_FP it only prints what answered and passes
// (also when nothing answers, or when port 5353 cannot be opened).
@Tags(['mdns'])
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:haotrannas_client/discovery/discovery.dart';

void main() {
  test('discoverServers on the real LAN for 3 s', () async {
    final expectedFingerprintPrefix =
        Platform.environment['NAS_EXPECT_MDNS_FP'];
    final MdnsTransport transport;
    try {
      transport = await MdnsSocketTransport.open();
    } on SocketException catch (error) {
      if (expectedFingerprintPrefix != null) rethrow;
      markTestSkipped('cannot open the mDNS socket: $error');
      return;
    }
    try {
      final servers = await discoverServers(transport: transport);
      // ignore: avoid_print
      print(
        servers.isEmpty
            ? 'mDNS: no HaoTranNAS server answered'
            : 'mDNS found:\n  ${servers.join('\n  ')}',
      );
      if (expectedFingerprintPrefix != null) {
        expect(
          servers.map((server) => server.fingerprintPrefix),
          contains(fingerprintPrefixOf(expectedFingerprintPrefix)),
        );
      }
    } finally {
      transport.close();
    }
  }, timeout: const Timeout(Duration(seconds: 20)));
}
