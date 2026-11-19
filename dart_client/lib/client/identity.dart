/// The phone's device identity (spec §7, D-018, D-022): the TLS client
/// certificate and key the server issued at pairing, the pinned server
/// certificate fingerprint, and the addresses that worked.
///
/// ```
///  <app support dir>/identity/
///    device_cert.der   X.509 DER from PairOk
///    device_key.pk8    PKCS#8 DER from PairOk (secret, never logged)
///    server.json       device id, fingerprints, addresses (written last)
/// ```
///
/// App-private files, not secure storage (D-022): dart:io TLS needs the
/// raw key bytes, and the background backup job must read them without a
/// plugin. Every file is written to `<name>.tmp`, flushed, then renamed,
/// so a crash leaves the old file or the new one, never half of one.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

import '../core/bytes/hex.dart';
import '../core/transport/tls_link.dart';
import '../protocol/limits.dart';
import 'server_address.dart';

/// Bytes of a fingerprint shown as the short id (spec §7).
const int shortIdBytes = 6;

/// Hex characters of the fingerprint in the mDNS TXT `fp=` (spec §13).
const int fingerprintPrefixCharacters = 16;

/// `3F9A-C21B-77E0`: the first 6 bytes of [fingerprint], uppercase hex,
/// groups of 4 joined by `-` (spec §7). The user compares it with what
/// `haotrannas-server pair` printed.
String shortId(List<int> fingerprint) {
  if (fingerprint.length < shortIdBytes) {
    throw ArgumentError.value(
      fingerprint.length,
      'fingerprint',
      'needs at least $shortIdBytes bytes',
    );
  }
  final hexText = toHex(
    fingerprint.sublist(0, shortIdBytes),
    separator: '',
  ).toUpperCase();
  return [
    for (var offset = 0; offset < hexText.length; offset += 4)
      hexText.substring(offset, offset + 4),
  ].join('-');
}

/// Yes when [typed] (any case, with or without dashes or spaces) is the
/// short id of [fingerprint].
bool shortIdMatches(String typed, List<int> fingerprint) =>
    typed.toUpperCase().replaceAll(RegExp(r'[^0-9A-F]'), '') ==
    shortId(fingerprint).replaceAll('-', '');

/// First 16 lowercase hex characters of [fingerprint]: the `fp=` value
/// the server puts in its mDNS TXT record (spec §13).
String fingerprintPrefix(List<int> fingerprint) =>
    toHex(fingerprint, separator: '').substring(0, fingerprintPrefixCharacters);

/// What the phone needs to connect as a paired device.
final class DeviceIdentity implements ClientCertificate {
  DeviceIdentity({
    required this.deviceId,
    required List<int> certDer,
    required List<int> keyPkcs8Der,
    required List<int> serverCertSha256,
    this.lastAddresses = const KnownAddresses(),
  }) : certDer = Uint8List.fromList(certDer),
       keyPkcs8Der = Uint8List.fromList(keyPkcs8Der),
       serverCertSha256 = Uint8List.fromList(serverCertSha256) {
    if (deviceId <= 0) {
      throw ArgumentError.value(deviceId, 'deviceId', 'must be 1 or more');
    }
    if (this.serverCertSha256.length != hashBytes) {
      throw ArgumentError.value(
        this.serverCertSha256.length,
        'serverCertSha256',
        'must be $hashBytes bytes',
      );
    }
    if (this.certDer.isEmpty || this.keyPkcs8Der.isEmpty) {
      throw ArgumentError('certificate and key must not be empty');
    }
  }

  /// The id the server gave this phone; HelloOk repeats it.
  final int deviceId;

  @override
  final Uint8List certDer;

  /// Secret. Never logged: [toString] prints `<key redacted>`.
  @override
  final Uint8List keyPkcs8Der;

  /// The pinned server certificate fingerprint.
  final Uint8List serverCertSha256;

  final KnownAddresses lastAddresses;

  /// SHA-256 of [certDer]: how the server knows this phone.
  Uint8List get certSha256 => sha256Of(certDer);

  /// The server's short id, e.g. `3F9A-C21B-77E0`.
  String get serverShortId => shortId(serverCertSha256);

  DeviceIdentity withAddresses(KnownAddresses addresses) => DeviceIdentity(
    deviceId: deviceId,
    certDer: certDer,
    keyPkcs8Der: keyPkcs8Der,
    serverCertSha256: serverCertSha256,
    lastAddresses: addresses,
  );

  @override
  String toString() =>
      'DeviceIdentity(device $deviceId, server $serverShortId, '
      'cert ${certDer.length} bytes, key <key redacted>, $lastAddresses)';
}

/// The identity files are there but cannot be used (missing, cut short,
/// or from two different pairings). The phone must pair again.
class IdentityDamaged implements Exception {
  const IdentityDamaged(this.message);

  final String message;

  @override
  String toString() => 'IdentityDamaged: $message';
}

/// Saves and loads the [DeviceIdentity] in an app-private folder.
class IdentityStore {
  /// Files go in `<appDirectory>/identity/`.
  IdentityStore(Directory appDirectory)
    : directory = Directory('${appDirectory.path}/identity');

  /// The store in the app's support folder (`getApplicationSupportDirectory`).
  static Future<IdentityStore> forApp() async =>
      IdentityStore(await getApplicationSupportDirectory());

  static const certFileName = 'device_cert.der';
  static const keyFileName = 'device_key.pk8';
  static const serverFileName = 'server.json';

  /// Layout version of `server.json`.
  static const serverFileVersion = 1;

  final Directory directory;

  File _file(String name) => File('${directory.path}/$name');

  /// The saved identity, or null when this phone is not paired. Throws
  /// [IdentityDamaged] when the files are there but unusable.
  Future<DeviceIdentity?> load() async {
    final serverFile = _file(serverFileName);
    if (!await serverFile.exists()) return null;
    try {
      final json = jsonDecode(await serverFile.readAsString());
      if (json is! Map<String, Object?> ||
          json['version'] != serverFileVersion) {
        throw const IdentityDamaged('$serverFileName: unknown layout');
      }
      final certDer = await _file(certFileName).readAsBytes();
      final keyPkcs8Der = await _file(keyFileName).readAsBytes();
      final expectedCertSha256 = parseHex(json['deviceCertSha256'] as String);
      if (!bytesEqual(sha256Of(certDer), expectedCertSha256)) {
        throw const IdentityDamaged(
          '$certFileName does not match $serverFileName',
        );
      }
      return DeviceIdentity(
        deviceId: json['deviceId'] as int,
        certDer: certDer,
        keyPkcs8Der: keyPkcs8Der,
        serverCertSha256: parseHex(json['serverCertSha256'] as String),
        lastAddresses: KnownAddresses(
          lastLan: _parseAddress(json['lastLanAddress']),
          wireGuard: _parseAddress(json['wireGuardAddress']),
        ),
      );
    } on IdentityDamaged {
      rethrow;
    } on FileSystemException catch (error) {
      throw IdentityDamaged('${error.path}: ${error.message}');
    } on Object catch (error) {
      // FormatException, TypeError (wrong JSON type), ArgumentError.
      throw IdentityDamaged('$serverFileName: $error');
    }
  }

  /// Saves all three files: certificate, key, then `server.json` last, so
  /// [load] never sees a new `server.json` with missing key files.
  Future<void> save(DeviceIdentity identity) async {
    await directory.create(recursive: true);
    await _writeReplacing(certFileName, identity.certDer);
    await _writeReplacing(keyFileName, identity.keyPkcs8Der);
    await saveAddresses(identity);
  }

  /// Rewrites only `server.json` (after an address change).
  Future<void> saveAddresses(DeviceIdentity identity) async {
    await directory.create(recursive: true);
    final addresses = identity.lastAddresses;
    final json = {
      'version': serverFileVersion,
      'deviceId': identity.deviceId,
      'deviceCertSha256': toHex(identity.certSha256, separator: ''),
      'serverCertSha256': toHex(identity.serverCertSha256, separator: ''),
      'lastLanAddress': addresses.lastLan?.toString(),
      'wireGuardAddress': addresses.wireGuard?.toString(),
    };
    await _writeReplacing(
      serverFileName,
      utf8.encode(const JsonEncoder.withIndent('  ').convert(json)),
    );
  }

  /// Forgets the pairing: deletes every identity file.
  Future<void> delete() async {
    if (await directory.exists()) await directory.delete(recursive: true);
  }

  Future<void> _writeReplacing(String name, List<int> bytes) async {
    final temporary = _file('$name.tmp');
    await temporary.writeAsBytes(bytes, flush: true);
    await temporary.rename(_file(name).path);
  }

  static ServerAddress? _parseAddress(Object? text) {
    if (text == null) return null;
    return ServerAddress.tryParse(text as String) ??
        (throw IdentityDamaged('bad address "$text"'));
  }
}
