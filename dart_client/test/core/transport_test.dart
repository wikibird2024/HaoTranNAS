import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haotrannas_client/core/transport/link.dart';
import 'package:haotrannas_client/core/transport/tcp_link.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('FakeLink records sends, delivers bytes, refuses after close', () async {
    final link = FakeLink();
    final replies = <Uint8List>[];
    link.onSend = (bytes) => link.deliver([bytes.length]);
    final subscription = link.incoming.listen(replies.add);

    await link.send(Uint8List.fromList([1, 2]));
    await pumpEventQueue();
    expect(link.sentChunks.single, [1, 2]);
    expect(replies.single, [2]);

    await link.close();
    expect(() => link.send(Uint8List(1)), throwsStateError);
    await subscription.cancel();
  });

  test('TcpLink sends and receives over loopback', () async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    // Echo server: sends back whatever arrives.
    server.listen((client) => client.listen(client.add));

    final link = await TcpLink.connect('127.0.0.1', server.port);
    expect(link.description, 'tcp 127.0.0.1:${server.port}');
    final received = <int>[];
    final gotAll = Completer<void>();
    link.incoming.listen((bytes) {
      received.addAll(bytes);
      if (received.length >= 4 && !gotAll.isCompleted) gotAll.complete();
    });

    await link.send(Uint8List.fromList([1, 2]));
    await link.send(Uint8List.fromList([3, 4]));
    await gotAll.future.timeout(const Duration(seconds: 5));
    expect(received, [1, 2, 3, 4]);

    await link.close();
    await server.close();
  });
}
