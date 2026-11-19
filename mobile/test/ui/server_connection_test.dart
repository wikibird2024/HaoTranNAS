// ServerConnectionController (lib/app/providers.dart) over the fake TLS
// connector: connect → online, the server hanging up → offline with a
// reason, disconnect, not paired. Author: Hao Tran.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haotrannas_mobile/app/providers.dart';
import 'package:haotrannas_mobile/client/address_book.dart';
import 'package:haotrannas_mobile/client/identity.dart';
import 'package:haotrannas_mobile/client/server_address.dart';

import '../client/fake_tls_server.dart' as fake_tls;
import 'ui_fakes.dart';

void main() {
  late fake_tls.FakeTlsServer fakeTls;
  late List<String?> pinnedPrefixes;

  ProviderContainer containerFor(DeviceIdentity? identity) {
    fakeTls = fake_tls.FakeTlsServer();
    pinnedPrefixes = [];
    final container = ProviderContainer(
      overrides: [
        identityProvider.overrideWith(() => FakeIdentityController(identity)),
        serverFinderProvider.overrideWithValue(({
          pinnedFingerprintPrefix,
        }) async {
          pinnedPrefixes.add(pinnedFingerprintPrefix);
          return const [];
        }),
        addressBookProvider.overrideWithValue(
          AddressBook(
            clientSoftware: 'test',
            deviceName: 'test phone',
            connect: fakeTls.connect,
          ),
        ),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  DeviceIdentity pairedIdentity() => DeviceIdentity(
    deviceId: 1,
    certDer: [1],
    keyPkcs8Der: [2],
    serverCertSha256: fake_tls.testServerFingerprint,
    lastAddresses: const KnownAddresses(lastLan: ServerAddress('192.168.1.5')),
  );

  test('connect → online with a DownloadEngine; hang-up → offline', () async {
    final container = containerFor(pairedIdentity());
    final controller = container.read(serverConnectionProvider.notifier);

    await controller.connect();
    expect(container.read(serverConnectionProvider), isA<ServerOnline>());
    expect(container.read(remoteFilesProvider), isNotNull);
    expect(pinnedPrefixes, [fingerprintPrefix(fake_tls.testServerFingerprint)]);

    await fakeTls.lastServer.link.close();
    await Future<void>.delayed(Duration.zero);
    final state = container.read(serverConnectionProvider);
    expect(state, isA<ServerOffline>());
    expect((state as ServerOffline).problem, isNotNull);
    expect(container.read(remoteFilesProvider), isNull);
  });

  test('disconnect → offline with no problem', () async {
    final container = containerFor(pairedIdentity());
    final controller = container.read(serverConnectionProvider.notifier);
    await controller.connect();
    await controller.disconnect();
    final state = container.read(serverConnectionProvider);
    expect(state, isA<ServerOffline>());
    expect((state as ServerOffline).problem, isNull);
    expect(fakeTls.lastServer.link.isClosed, isTrue);
  });

  test('not paired → offline, nothing tried', () async {
    final container = containerFor(null);
    await container.read(serverConnectionProvider.notifier).connect();
    final state = container.read(serverConnectionProvider);
    expect((state as ServerOffline).problem, 'This phone is not paired.');
    expect(fakeTls.calls, isEmpty);
  });

  test('no address known → offline with the address book message', () async {
    final container = containerFor(
      DeviceIdentity(
        deviceId: 1,
        certDer: [1],
        keyPkcs8Der: [2],
        serverCertSha256: fake_tls.testServerFingerprint,
      ),
    );
    await container.read(serverConnectionProvider.notifier).connect();
    final state = container.read(serverConnectionProvider);
    expect((state as ServerOffline).problem, contains('No server address'));
  });
}
