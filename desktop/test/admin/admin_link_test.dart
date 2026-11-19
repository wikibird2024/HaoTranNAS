// AdminLink over a real Unix socket served by the test, and the target
// encoding. The real server is covered by test/integration/.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:haotrannas_desktop/admin/admin_controller.dart';
import 'package:haotrannas_desktop/admin/admin_link.dart';

/// A one-shot admin server: reads one command line, answers [reply].
Future<(ServerSocket, Future<String>)> serveOnce(
  String socketPath,
  List<String> Function(String command) reply,
) async {
  final server = await ServerSocket.bind(
    InternetAddress(socketPath, type: InternetAddressType.unix),
    0,
  );
  final command = Completer<String>();
  server.listen((client) async {
    final line = await client
        .cast<List<int>>()
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .first;
    command.complete(line);
    for (final answer in reply(line)) {
      client.write('$answer\n');
    }
    await client.flush();
    await client.close();
  });
  return (server, command.future);
}

void main() {
  late Directory folder;
  late String socketPath;

  setUp(() {
    folder = Directory.systemTemp.createTempSync('admin_link');
    socketPath = '${folder.path}/admin.sock';
  });

  tearDown(() => folder.deleteSync(recursive: true));

  test('sends the line, returns the reply, progress goes aside', () async {
    final (server, command) = await serveOnce(
      socketPath,
      (_) => ['progress 256', 'progress 512', 'ok scrub chunks_checked 600'],
    );
    final progress = <int>[];
    final lines = await AdminLink(socketPath)
        .send('scrub-now', onProgress: progress.add);
    expect(await command, 'scrub-now');
    expect(lines, ['ok scrub chunks_checked 600']);
    expect(progress, [256, 512]);
    await server.close();
  });

  test('no server: AdminLinkFailed names the socket', () async {
    await expectLater(
      AdminLink(socketPath).send('status'),
      throwsA(
        isA<AdminLinkFailed>().having(
          (failed) => failed.message,
          'message',
          contains(socketPath),
        ),
      ),
    );
  });

  test('a silent server times out', () async {
    final server = await ServerSocket.bind(
      InternetAddress(socketPath, type: InternetAddressType.unix),
      0,
    );
    final clients = <Socket>[];
    server.listen(clients.add);
    await expectLater(
      AdminLink(
        socketPath,
        replyTimeout: const Duration(milliseconds: 200),
      ).send('status'),
      throwsA(isA<AdminLinkFailed>()),
    );
    for (final client in clients) {
      client.destroy();
    }
    await server.close();
  });

  test('admin target round trip; damaged text is null', () {
    for (final target in [
      const AdminOnThisPc('/tmp/htn'),
      const AdminOverSsh('hao@nas', '/srv/haotrannas'),
    ]) {
      final back = decodeAdminTarget(encodeAdminTarget(target))!;
      expect(back.runtimeType, target.runtimeType);
      expect(back.label, target.label);
      expect(back.socketPath, '${target.dataDirectory}/admin.sock');
    }
    expect(decodeAdminTarget(null), isNull);
    expect(decodeAdminTarget('{'), isNull);
    expect(decodeAdminTarget('{"kind":"ssh","data_dir":"/x"}'), isNull);
    expect(decodeAdminTarget('{"kind":"this_pc","data_dir":""}'), isNull);
  });
}
