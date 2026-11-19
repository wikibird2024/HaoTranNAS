import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:haotrannas_client/client/address_book.dart';
import 'package:haotrannas_client/client/identity.dart';
import 'package:haotrannas_client/client/server_address.dart';
import 'package:haotrannas_client/core/transport/tls_link.dart';
import 'package:haotrannas_client/protocol/error_codes.dart';
import 'package:haotrannas_client/protocol/messages.dart';
import 'package:haotrannas_client/testing/fake_server.dart';
import 'package:haotrannas_client/testing/fake_tls_server.dart';

const mdnsAddress = ServerAddress('192.168.1.20');
const lanAddress = ServerAddress('192.168.1.5');
const wireGuardAddress = ServerAddress('10.66.0.1');

/// testHelloOk says device 1.
DeviceIdentity identityWith({
  ServerAddress? lastLan = lanAddress,
  ServerAddress? wireGuard = wireGuardAddress,
}) => DeviceIdentity(
  deviceId: 1,
  certDer: [1, 2, 3],
  keyPkcs8Der: [4, 5, 6],
  serverCertSha256: testServerFingerprint,
  lastAddresses: KnownAddresses(lastLan: lastLan, wireGuard: wireGuard),
);

final ourPrefix = fingerprintPrefix(testServerFingerprint);

const unreachable = TlsConnectFailure(
  TlsConnectFailureKind.unreachable,
  'refused',
);

void main() {
  group('orderedCandidates', () {
    test('mDNS match → last LAN → WireGuard; other servers dropped', () {
      final candidates = orderedCandidates(
        identityWith(),
        discovered: [
          const DiscoveredServer(
            ServerAddress('192.168.1.30'),
            '0123456789abcdef',
          ),
          DiscoveredServer(mdnsAddress, ourPrefix.toUpperCase()),
        ],
      );
      expect(candidates, const [
        AddressCandidate(mdnsAddress, AddressSource.mdns),
        AddressCandidate(lanAddress, AddressSource.lastLan),
        AddressCandidate(wireGuardAddress, AddressSource.wireGuard),
      ]);
    });

    test('an address found twice is tried once (first source wins)', () {
      final candidates = orderedCandidates(
        identityWith(),
        discovered: [DiscoveredServer(lanAddress, ourPrefix)],
      );
      expect(candidates, const [
        AddressCandidate(lanAddress, AddressSource.mdns),
        AddressCandidate(wireGuardAddress, AddressSource.wireGuard),
      ]);
    });

    test('nothing known: empty', () {
      expect(
        orderedCandidates(identityWith(lastLan: null, wireGuard: null)),
        isEmpty,
      );
    });
  });

  group('connectPaired', () {
    late FakeTlsServer fake;
    late Directory appDirectory;
    late IdentityStore store;
    late AddressBook book;

    setUp(() {
      fake = FakeTlsServer();
      appDirectory = Directory.systemTemp.createTempSync('address_book');
      store = IdentityStore(appDirectory);
      book = AddressBook(
        clientSoftware: 'haotrannas-mobile test',
        deviceName: 'test phone',
        store: store,
        connect: fake.connect,
      );
    });

    tearDown(() => appDirectory.deleteSync(recursive: true));

    test('first address works: fixed pin + client certificate', () async {
      final identity = identityWith();
      final result = await book.connectPaired(identity);
      expect(result, isA<PairedConnected>());
      final connected = result as PairedConnected;
      expect(connected.candidate.source, AddressSource.lastLan);
      expect(connected.failedAttempts, isEmpty);
      expect(connected.connection.helloOk.deviceId, 1);

      final call = fake.calls.single;
      expect(call.host, lanAddress.host);
      expect(call.port, lanAddress.port);
      expect(call.clientCertificate, same(identity));
      expect(call.pin, isA<FixedServerPin>());
      expect(call.pin.expectedFingerprint, testServerFingerprint);
      await connected.connection.close();
    });

    test(
      'unreachable LAN → WireGuard; WireGuard is not stored as LAN',
      () async {
        fake.failureFor = (host) =>
            host == lanAddress.host ? unreachable : null;
        final identity = identityWith();
        final result = await book.connectPaired(identity) as PairedConnected;
        expect(result.candidate.source, AddressSource.wireGuard);
        expect(result.failedAttempts.single.candidate.address, lanAddress);
        expect(result.identity.lastAddresses, identity.lastAddresses);
        expect(await store.load(), isNull, reason: 'nothing new to save');
        await result.connection.close();
      },
    );

    test('mDNS address that works is saved as the last LAN address', () async {
      final identity = identityWith();
      await store.save(identity);
      final result = await book.connectPaired(
        identity,
        discovered: [DiscoveredServer(mdnsAddress, ourPrefix)],
      ) as PairedConnected;
      expect(result.candidate.source, AddressSource.mdns);
      expect(result.identity.lastAddresses.lastLan, mdnsAddress);
      expect(result.identity.lastAddresses.wireGuard, wireGuardAddress);
      expect((await store.load())!.lastAddresses.lastLan, mdnsAddress);
      await result.connection.close();
    });

    test('another server at an address (pin mismatch) → next', () async {
      fake.fingerprintFor = (host) =>
          host == lanAddress.host ? sha256Of([9, 9, 9]) : testServerFingerprint;
      final result =
          await book.connectPaired(identityWith()) as PairedConnected;
      expect(result.candidate.address, wireGuardAddress);
      expect(result.failedAttempts.single.problem, contains('another server'));
      await result.connection.close();
    });

    test(
      'closed before HelloOk: maybeNotPaired, no other address tried',
      () async {
        fake.answer = (server, host, request) {
          hangUpLater(server);
          return null;
        };
        final result = await book.connectPaired(identityWith());
        expect(
          result,
          isA<PairedConnectFailed>().having(
            (failed) => failed.kind,
            'kind',
            PairedConnectFailureKind.maybeNotPaired,
          ),
        );
        expect(fake.calls, hasLength(1));
      },
    );

    test('Error NOT_PAIRED to Hello: maybeNotPaired', () async {
      fake.answer = (server, host, request) => ErrorMessage(
        code: ErrorCode.notPaired.number,
        message: 'unknown certificate',
      );
      final result = await book.connectPaired(identityWith());
      expect(
        (result as PairedConnectFailed).kind,
        PairedConnectFailureKind.maybeNotPaired,
      );
      expect(fake.calls, hasLength(1));
    });

    test('HelloOk with another device id: maybeNotPaired', () async {
      fake.answer = (server, host, request) => request is Hello
          ? const HelloOk(
              protocolVersion: 1,
              serverSoftware: 'x',
              serverName: 'nas',
              deviceId: 2,
              chunkSizeBytes: 1048576,
              maxFrameLengthBytes: 4194304,
            )
          : FakeServer.defaultAnswer(request);
      final result = await book.connectPaired(identityWith());
      expect(
        (result as PairedConnectFailed).kind,
        PairedConnectFailureKind.maybeNotPaired,
      );
      expect(fake.lastServer.link.isClosed, isTrue);
    });

    test('every address fails: noAddressWorked, each attempt listed', () async {
      fake.failureFor = (host) => unreachable;
      final result = await book.connectPaired(
        identityWith(),
        discovered: [DiscoveredServer(mdnsAddress, ourPrefix)],
      );
      final failed = result as PairedConnectFailed;
      expect(failed.kind, PairedConnectFailureKind.noAddressWorked);
      expect(
        failed.failedAttempts.map((attempt) => attempt.candidate.address),
        [mdnsAddress, lanAddress, wireGuardAddress],
      );
    });

    test('no address known: noAddress, nothing tried', () async {
      final result = await book.connectPaired(
        identityWith(lastLan: null, wireGuard: null),
      );
      expect(
        (result as PairedConnectFailed).kind,
        PairedConnectFailureKind.noAddress,
      );
      expect(fake.calls, isEmpty);
    });
  });
}
