// iPhone NAS finder (D-043): a resolved Bonjour service → server, with
// the same checks as the raw mDNS finder; no plugin = empty list.
// Author: Hao Tran.
import 'package:flutter_test/flutter_test.dart';
import 'package:haotrannas_client/discovery/discovery.dart';
import 'package:haotrannas_mobile/core/discovery/bonjour_finder.dart';

void main() {
  const goodTxt = {'v': '1', 'fp': '3f9ac21b77e00607'};

  test('a resolved service with v=1, fp and IPv4 is a server', () {
    final server = serverFromBonjour(
      name: 'HaoTranNAS',
      hostAddresses: ['fe80::1', '192.168.1.9'],
      port: 47100,
      attributes: goodTxt,
    )!;
    expect(server.instanceName, 'HaoTranNAS._haotrannas._tcp.local');
    expect(server.ipv4Address.address, '192.168.1.9');
    expect(server.port, 47100);
    expect(server.fingerprintPrefix, '3f9ac21b77e00607');
  });

  test('fp in capitals is accepted; pin compares the prefix', () {
    final upper = {'v': '1', 'fp': '3F9AC21B77E00607'};
    DiscoveredServer? check(String? pin) => serverFromBonjour(
      name: 'nas',
      hostAddresses: ['192.168.1.9'],
      port: 47100,
      attributes: upper,
      pinnedFingerprintPrefix: pin,
    );
    expect(check(null), isNotNull);
    expect(check('3F:9A:C2:1B:77:E0:06:07:AA:BB'), isNotNull);
    expect(check('0000000000000000'), isNull, reason: 'another NAS');
  });

  test('not ours: wrong version, bad fp, no IPv4, bad port', () {
    DiscoveredServer? check({
      Map<String, String> attributes = goodTxt,
      List<String> addresses = const ['192.168.1.9'],
      int port = 47100,
    }) => serverFromBonjour(
      name: 'nas',
      hostAddresses: addresses,
      port: port,
      attributes: attributes,
    );
    expect(check(attributes: {'v': '3', 'fp': '3f9ac21b77e00607'}), isNull);
    expect(check(attributes: {'v': '1', 'fp': 'xyz'}), isNull);
    expect(check(attributes: {'v': '1'}), isNull);
    expect(check(addresses: ['fe80::1']), isNull);
    expect(check(addresses: []), isNull);
    expect(check(port: 0), isNull);
  });

  test('no Bonjour plugin (host test): empty list, no throw', () async {
    TestWidgetsFlutterBinding.ensureInitialized();
    expect(await findServersWithBonjour(listenFor: Duration.zero), isEmpty);
  });
}
