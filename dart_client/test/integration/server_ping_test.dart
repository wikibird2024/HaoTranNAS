// Talks to a real haotrannas-server in dev mode (plain TCP, every
// connection is device 1). Start one, then:
//   NAS_SERVER_ADDR=127.0.0.1:47100 flutter test --tags server
// Without NAS_SERVER_ADDR the test is skipped.
@Tags(['server'])
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:haotrannas_client/client/nas_connection.dart';
import 'package:haotrannas_client/core/log/session_log.dart';
import 'package:haotrannas_client/core/transport/tcp_link.dart';

void main() {
  final serverAddress = Platform.environment['NAS_SERVER_ADDR'];

  test(
    'dev server: Hello → HelloOk(device 1), 3 pings, Close',
    () async {
      final separatorIndex = serverAddress!.lastIndexOf(':');
      final host = serverAddress.substring(0, separatorIndex);
      final port = int.parse(serverAddress.substring(separatorIndex + 1));

      final log = SessionLog();
      final link = await TcpLink.connect(host, port);
      final connection = await NasConnection.open(
        link,
        clientSoftware: 'haotrannas-mobile integration test',
        deviceName: 'integration test',
        log: log,
      );
      expect(connection.helloOk.deviceId, 1, reason: 'dev mode = device 1');
      expect(connection.helloOk.protocolVersion, 2);

      for (var attempt = 1; attempt <= 3; attempt++) {
        final roundTrip = await connection.ping();
        printOnFailure('ping $attempt: ${roundTrip.inMicroseconds} µs');
        expect(roundTrip, lessThan(const Duration(seconds: 5)));
      }
      await connection.close();
      expect(connection.closedBy!.kind, NasFailureKind.closedByClient);
    },
    skip: serverAddress == null
        ? 'NAS_SERVER_ADDR not set (host:port of haotrannas-server '
              '--dev-plain, e.g. 127.0.0.1:47100)'
        : false,
    timeout: const Timeout(Duration(seconds: 30)),
  );
}
