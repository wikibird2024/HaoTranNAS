// Test certificates made with the `openssl` command, shaped like the
// server's (D-018): a self-signed server certificate, a device CA, and a
// device certificate (EKU clientAuth) signed by it with its key as
// PKCS#8 DER, the way PairOk carries it.
import 'dart:io';
import 'dart:typed_data';

/// One certificate: DER bytes and the PEM openssl wrote.
typedef TestCertificate = ({Uint8List der, String pem});

class TlsTestCertificates {
  TlsTestCertificates._(this.directory);

  final Directory directory;
  late final TestCertificate server;
  late final String serverKeyPem;
  late final TestCertificate deviceCa;
  late final TestCertificate device;
  late final Uint8List deviceKeyPkcs8Der;

  /// A device certificate from another CA (not trusted by the server).
  late final TestCertificate strangerDevice;
  late final Uint8List strangerDeviceKeyPkcs8Der;

  /// Why openssl tests are skipped, or null when `openssl` runs.
  static String? get skipReason {
    try {
      final result = Process.runSync('openssl', ['version']);
      return result.exitCode == 0 ? null : 'openssl version failed';
    } on ProcessException {
      return 'openssl not installed';
    }
  }

  /// Makes every certificate in a new temp folder (TMPDIR).
  static Future<TlsTestCertificates> create() async {
    final certificates = TlsTestCertificates._(
      Directory.systemTemp.createTempSync('tls_test_certificates'),
    );
    await certificates._make();
    return certificates;
  }

  void delete() => directory.deleteSync(recursive: true);

  String _path(String name) => '${directory.path}/$name';

  Future<void> _openssl(List<String> arguments) async {
    final result = await Process.run('openssl', arguments);
    if (result.exitCode != 0) {
      throw StateError(
        'openssl ${arguments.join(' ')} failed:\n${result.stderr}',
      );
    }
  }

  static const _ecKey = [
    '-newkey',
    'ec',
    '-pkeyopt',
    'ec_paramgen_curve:prime256v1',
    '-nodes',
  ];

  Future<void> _selfSigned(String name, String commonName) => _openssl([
    'req', '-x509', ..._ecKey, //
    '-keyout', _path('$name.key.pem'),
    '-out', _path('$name.cert.pem'),
    '-days', '2', '-subj', '/CN=$commonName',
  ]);

  Future<void> _deviceSignedBy(String name, String caName) async {
    await _openssl([
      'req', ..._ecKey, //
      '-keyout', _path('$name.key.pem'),
      '-out', _path('$name.csr'),
      '-subj', '/CN=$name',
    ]);
    File(_path('client.ext')).writeAsStringSync(
      'extendedKeyUsage=clientAuth\nkeyUsage=digitalSignature\n',
    );
    await _openssl([
      'x509', '-req', '-in', _path('$name.csr'), //
      '-CA', _path('$caName.cert.pem'),
      '-CAkey', _path('$caName.key.pem'),
      '-CAcreateserial', '-days', '2',
      '-extfile', _path('client.ext'),
      '-out', _path('$name.cert.pem'),
    ]);
    await _openssl([
      'pkcs8', '-topk8', '-nocrypt', //
      '-in', _path('$name.key.pem'),
      '-outform', 'DER', '-out', _path('$name.key.pk8'),
    ]);
  }

  Future<TestCertificate> _read(String name) async {
    await _openssl([
      'x509', '-in', _path('$name.cert.pem'), //
      '-outform', 'DER', '-out', _path('$name.cert.der'),
    ]);
    return (
      der: File(_path('$name.cert.der')).readAsBytesSync(),
      pem: File(_path('$name.cert.pem')).readAsStringSync(),
    );
  }

  Future<void> _make() async {
    await _selfSigned('server', 'haotrannas-test-server');
    await _selfSigned('device-ca', 'haotrannas-test-device-ca');
    await _selfSigned('stranger-ca', 'stranger-ca');
    await _deviceSignedBy('device-7', 'device-ca');
    await _deviceSignedBy('stranger-device', 'stranger-ca');
    server = await _read('server');
    serverKeyPem = File(_path('server.key.pem')).readAsStringSync();
    deviceCa = await _read('device-ca');
    device = await _read('device-7');
    deviceKeyPkcs8Der = File(_path('device-7.key.pk8')).readAsBytesSync();
    strangerDevice = await _read('stranger-device');
    strangerDeviceKeyPkcs8Der = File(_path('stranger-device.key.pk8'))
        .readAsBytesSync();
  }
}
