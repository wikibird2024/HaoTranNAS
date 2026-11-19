import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:haotrannas_client/client/identity.dart';
import 'package:haotrannas_client/client/server_address.dart';
import 'package:haotrannas_client/core/bytes/hex.dart';
import 'package:haotrannas_client/core/transport/tls_link.dart';

/// SHA-256("abc"), FIPS 180-2 example.
final abcSha256 = parseHex(
  'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad',
);

DeviceIdentity sampleIdentity({
  KnownAddresses addresses = const KnownAddresses(),
}) => DeviceIdentity(
  deviceId: 7,
  certDer: List.generate(300, (index) => index & 0xff),
  keyPkcs8Der: List.generate(138, (index) => 0xA0 ^ index),
  serverCertSha256: abcSha256,
  lastAddresses: addresses,
);

void main() {
  group('short id and fingerprint prefix', () {
    test('spec §7 example bytes → 3F9A-C21B-77E0', () {
      final fingerprint = Uint8List(32)
        ..setAll(0, parseHex('3f9ac21b77e0'))
        ..[6] = 0xff;
      expect(shortId(fingerprint), '3F9A-C21B-77E0');
    });

    test('SHA-256("abc") → BA78-16BF-8F01', () {
      expect(sha256Of(utf8.encode('abc')), abcSha256);
      expect(shortId(abcSha256), 'BA78-16BF-8F01');
    });

    test('fewer than 6 bytes: ArgumentError', () {
      expect(() => shortId([1, 2, 3, 4, 5]), throwsArgumentError);
    });

    test('shortIdMatches ignores case, dashes and spaces', () {
      expect(shortIdMatches('BA78-16BF-8F01', abcSha256), isTrue);
      expect(shortIdMatches('ba78 16bf 8f01', abcSha256), isTrue);
      expect(shortIdMatches('ba7816bf8f01', abcSha256), isTrue);
      expect(shortIdMatches('BA78-16BF-8F02', abcSha256), isFalse);
      expect(shortIdMatches('BA78-16BF', abcSha256), isFalse);
    });

    test('mDNS fp= prefix: first 16 lowercase hex characters (spec §13)', () {
      expect(fingerprintPrefix(abcSha256), 'ba7816bf8f01cfea');
    });
  });

  group('DeviceIdentity', () {
    test('toString shows the key as <key redacted>, never its bytes', () {
      final identity = sampleIdentity();
      final text = identity.toString();
      expect(text, contains('<key redacted>'));
      expect(text, contains('device 7'));
      expect(text, contains('BA78-16BF-8F01'));
      expect(text, isNot(contains(toHex(identity.keyPkcs8Der.sublist(0, 4)))));
      expect(text, isNot(contains(base64.encode(identity.keyPkcs8Der))));
    });

    test('rejects device id 0, a short fingerprint, empty cert or key', () {
      expect(
        () => DeviceIdentity(
          deviceId: 0,
          certDer: [1],
          keyPkcs8Der: [1],
          serverCertSha256: abcSha256,
        ),
        throwsArgumentError,
      );
      expect(
        () => DeviceIdentity(
          deviceId: 1,
          certDer: [1],
          keyPkcs8Der: [1],
          serverCertSha256: [1, 2],
        ),
        throwsArgumentError,
      );
      expect(
        () => DeviceIdentity(
          deviceId: 1,
          certDer: [],
          keyPkcs8Der: [1],
          serverCertSha256: abcSha256,
        ),
        throwsArgumentError,
      );
    });

    test('is a ClientCertificate (cert + key for TlsLink)', () {
      final ClientCertificate certificate = sampleIdentity();
      expect(certificate.certDer, hasLength(300));
      expect(certificate.keyPkcs8Der, hasLength(138));
    });
  });

  group('ServerAddress.tryParse', () {
    test('valid', () {
      expect(
        ServerAddress.tryParse('192.168.1.5:47100'),
        const ServerAddress('192.168.1.5', 47100),
      );
      expect(
        ServerAddress.tryParse(' 10.66.0.1 '),
        const ServerAddress('10.66.0.1', defaultServerPort),
      );
      expect(
        ServerAddress.tryParse('[fd00::5]:9000'),
        const ServerAddress('fd00::5', 9000),
      );
      expect(ServerAddress.tryParse('fd00::5'), const ServerAddress('fd00::5'));
    });

    test('invalid', () {
      for (final text in [
        '',
        ':47100',
        '1.2.3.4:0',
        '1.2.3.4:70000',
        '1.2.3.4:x',
        '[fd00::5',
        'a b:1',
      ]) {
        expect(ServerAddress.tryParse(text), isNull, reason: text);
      }
    });

    test('toString round trip', () {
      for (final address in const [
        ServerAddress('192.168.1.5', 47100),
        ServerAddress('fd00::5', 9000),
      ]) {
        expect(ServerAddress.tryParse(address.toString()), address);
      }
    });
  });

  group('IdentityStore', () {
    late Directory appDirectory;
    late IdentityStore store;

    setUp(() {
      appDirectory = Directory.systemTemp.createTempSync('identity_store');
      store = IdentityStore(appDirectory);
    });

    tearDown(() => appDirectory.deleteSync(recursive: true));

    File file(String name) => File('${appDirectory.path}/identity/$name');

    test('nothing saved: load gives null', () async {
      expect(await store.load(), isNull);
    });

    test('round trip; file layout; no temp files left', () async {
      final identity = sampleIdentity(
        addresses: const KnownAddresses(
          lastLan: ServerAddress('192.168.1.5', 47100),
          wireGuard: ServerAddress('10.66.0.1', 47100),
        ),
      );
      await store.save(identity);

      expect(
        Directory('${appDirectory.path}/identity')
            .listSync()
            .map((entity) => entity.uri.pathSegments.last)
            .toSet(),
        {'device_cert.der', 'device_key.pk8', 'server.json'},
      );
      expect(file('device_cert.der').readAsBytesSync(), identity.certDer);
      expect(file('device_key.pk8').readAsBytesSync(), identity.keyPkcs8Der);

      final loaded = (await store.load())!;
      expect(loaded.deviceId, 7);
      expect(loaded.certDer, identity.certDer);
      expect(loaded.keyPkcs8Der, identity.keyPkcs8Der);
      expect(loaded.serverCertSha256, abcSha256);
      expect(loaded.lastAddresses, identity.lastAddresses);
    });

    test('server.json holds no key bytes', () async {
      final identity = sampleIdentity();
      await store.save(identity);
      final json = file('server.json').readAsStringSync();
      expect(json, isNot(contains(toHex(identity.keyPkcs8Der, separator: ''))));
      expect(json, isNot(contains(base64.encode(identity.keyPkcs8Der))));
      expect(jsonDecode(json), containsPair('deviceId', 7));
    });

    test('saveAddresses rewrites only the addresses', () async {
      await store.save(sampleIdentity());
      final moved = sampleIdentity(
        addresses: const KnownAddresses(lastLan: ServerAddress('192.168.1.9')),
      );
      await store.saveAddresses(moved);
      expect(
        (await store.load())!.lastAddresses.lastLan,
        const ServerAddress('192.168.1.9'),
      );
    });

    test('certificate from another pairing: IdentityDamaged', () async {
      await store.save(sampleIdentity());
      file('device_cert.der').writeAsBytesSync([9, 9, 9]);
      await expectLater(store.load(), throwsA(isA<IdentityDamaged>()));
    });

    test('key file missing: IdentityDamaged', () async {
      await store.save(sampleIdentity());
      file('device_key.pk8').deleteSync();
      await expectLater(store.load(), throwsA(isA<IdentityDamaged>()));
    });

    test('server.json not JSON or wrong layout: IdentityDamaged', () async {
      await store.save(sampleIdentity());
      file('server.json').writeAsStringSync('{not json');
      await expectLater(store.load(), throwsA(isA<IdentityDamaged>()));
      file('server.json').writeAsStringSync('{"version": 99}');
      await expectLater(store.load(), throwsA(isA<IdentityDamaged>()));
      file('server.json').writeAsStringSync('{"version": 1, "deviceId": "7"}');
      await expectLater(store.load(), throwsA(isA<IdentityDamaged>()));
    });

    test('delete forgets the pairing', () async {
      await store.save(sampleIdentity());
      await store.delete();
      expect(await store.load(), isNull);
      await store.delete();
    });
  });
}
