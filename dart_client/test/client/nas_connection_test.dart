import 'dart:async';
import 'dart:typed_data';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haotrannas_client/client/nas_connection.dart';
import 'package:haotrannas_client/core/log/session_log.dart';
import 'package:haotrannas_client/protocol/error_codes.dart';
import 'package:haotrannas_client/protocol/limits.dart';
import 'package:haotrannas_client/protocol/messages.dart';
import 'package:haotrannas_client/testing/fake_server.dart';

Future<NasConnection> openConnection(FakeServer server, {SessionLog? log}) =>
    NasConnection.open(
      server.link,
      clientSoftware: 'haotrannas-mobile test',
      deviceName: 'test phone',
      log: log,
    );

Matcher failsWith(NasFailureKind kind) =>
    throwsA(isA<NasFailure>().having((failure) => failure.kind, 'kind', kind));

void main() {
  group('handshake', () {
    test(
      'Hello → HelloOk: helloOk exposed, state ready, frames logged',
      () async {
        final server = FakeServer();
        final log = SessionLog();
        final connection = await openConnection(server, log: log);

        final hello = server.sent.single;
        expect(hello.requestId, 1);
        expect(
          hello.message,
          const Hello(
            protocolVersion: 1,
            clientSoftware: 'haotrannas-mobile test',
            deviceName: 'test phone',
          ),
        );
        expect(connection.helloOk, testHelloOk);
        expect(connection.helloOk.deviceId, 1);
        expect(connection.isReady, isTrue);
        expect(connection.state.value, isA<NasReady>());

        final sentEntry = log.entries.firstWhere(
          (entry) => entry.direction == Direction.sent,
        );
        expect(sentEntry.description, startsWith('Hello('));
        expect(sentEntry.description, contains('id 1'));
        final receivedEntry = log.entries.firstWhere(
          (entry) => entry.direction == Direction.received,
        );
        expect(receivedEntry.description, startsWith('HelloOk('));
        await connection.close();
      },
    );

    test('Error VERSION_MISMATCH → versionMismatch, link closed', () async {
      final server = FakeServer()
        ..answer = (_) => ErrorMessage(
          code: ErrorCode.versionMismatch.number,
          message: 'server speaks 2',
        );
      await expectLater(
        openConnection(server),
        failsWith(NasFailureKind.versionMismatch),
      );
      expect(server.link.isClosed, isTrue);
    });

    test('HelloOk with another protocol version → versionMismatch', () async {
      final server = FakeServer()
        ..answer = (_) => const HelloOk(
          protocolVersion: 2,
          serverSoftware: 'future',
          serverName: 'nas',
          deviceId: 1,
          chunkSizeBytes: 1048576,
          maxFrameLengthBytes: 4194304,
        );
      await expectLater(
        openConnection(server),
        failsWith(NasFailureKind.versionMismatch),
      );
      expect(server.link.isClosed, isTrue);
    });

    test(
      'Error NOT_PAIRED during handshake → serverError, maybe not paired',
      () async {
        final server = FakeServer()
          ..answer = (_) => ErrorMessage(
            code: ErrorCode.notPaired.number,
            message: 'unknown certificate',
          );
        final failure = await openConnection(server).then<NasFailure?>(
          (_) => null,
          onError: (Object error) => error as NasFailure,
        );
        expect(failure!.kind, NasFailureKind.serverError);
        expect(failure.errorCode, ErrorCode.notPaired.number);
        expect(failure.isMaybeNotPaired, isTrue);
      },
    );

    test('link closed before HelloOk → closedBeforeHello', () async {
      final server = FakeServer();
      server.answer = (_) {
        // TLS 1.3: a rejected client cert shows up as end-of-stream.
        unawaited(server.link.close());
        return null;
      };
      final connection = NasConnection(
        server.link,
        clientSoftware: 'test',
        deviceName: 'test phone',
      );
      await expectLater(
        connection.start(),
        failsWith(NasFailureKind.closedBeforeHello),
      );
      expect(connection.closedBy!.isMaybeNotPaired, isTrue);
      expect(connection.state.value, isA<NasClosed>());
    });

    test('server Close before HelloOk → serverClosed', () async {
      final server = FakeServer()
        ..answer = (_) =>
            Close(reason: CloseReason.handshakeTimeout.number, message: '');
      await expectLater(
        openConnection(server),
        failsWith(NasFailureKind.serverClosed),
      );
    });

    test('no HelloOk within handshakeTimeout → handshakeTimeout', () {
      fakeAsync((async) {
        final server = FakeServer()..answer = (_) => null;
        Object? error;
        openConnection(server).catchError((Object caught) {
          error = caught;
          return Future<NasConnection>.error(caught);
        }).ignore();
        async.elapse(const Duration(milliseconds: 9999));
        expect(error, isNull);
        async.elapse(const Duration(milliseconds: 1));
        expect(
          error,
          isA<NasFailure>().having(
            (failure) => failure.kind,
            'kind',
            NasFailureKind.handshakeTimeout,
          ),
        );
        expect(server.link.isClosed, isTrue);
      });
    });

    test('state goes connecting → ready → closed', () async {
      final server = FakeServer();
      final connection = NasConnection(
        server.link,
        clientSoftware: 'test',
        deviceName: 'test phone',
      );
      final states = <NasConnectionState>[connection.state.value];
      connection.state.addListener(() => states.add(connection.state.value));
      await connection.start();
      await connection.close();
      expect(states, [
        isA<NasConnecting>(),
        isA<NasReady>(),
        isA<NasClosed>().having(
          (closed) => closed.cause.kind,
          'cause',
          NasFailureKind.closedByClient,
        ),
      ]);
    });
  });

  group('requests', () {
    test('reply completes the request; ids go 1 (Hello), 2, 3', () async {
      final server = FakeServer();
      final connection = await openConnection(server);
      expect(await connection.request(const ListDevices()), isA<DeviceList>());
      expect(await connection.ping(), isA<Duration>());
      expect([for (final frame in server.sent) frame.requestId], [1, 2, 3]);
      await connection.close();
    });

    test('Error reply → NasRequestError; the connection stays open', () async {
      final server = FakeServer()
        ..answer = (request) => request is ReadFile
            ? ErrorMessage(code: ErrorCode.notFound.number, message: 'no file')
            : FakeServer.defaultAnswer(request);
      final connection = await openConnection(server);

      await expectLater(
        connection.request(
          const ReadFile(deviceId: 0, path: 'a.jpg', versionId: 0),
        ),
        throwsA(
          isA<NasRequestError>()
              .having((error) => error.code, 'code', 40)
              .having((error) => error.codeName, 'codeName', 'NOT_FOUND')
              .having((error) => error.message, 'message', 'no file')
              .having((error) => error.isFatal, 'isFatal', isFalse),
        ),
      );
      expect(connection.isReady, isTrue);
      expect(await connection.request(const ListDevices()), isA<DeviceList>());
      await connection.close();
    });

    test(
      'fatal Error reply → NasRequestError, then the connection closes',
      () async {
        final server = FakeServer()
          ..answer = (request) => request is ListDevices
              ? ErrorMessage(code: ErrorCode.notPaired.number, message: 'pair')
              : FakeServer.defaultAnswer(request);
        final connection = await openConnection(server);
        await expectLater(
          connection.request(const ListDevices()),
          throwsA(
            isA<NasRequestError>().having(
              (error) => error.isFatal,
              'isFatal',
              isTrue,
            ),
          ),
        );
        expect(connection.closedBy!.kind, NasFailureKind.serverError);
        expect(server.link.isClosed, isTrue);
      },
    );

    test('reply split across 7 odd pieces is joined', () async {
      const devices = DeviceList(
        devices: [
          DeviceEntry(
            deviceId: 1,
            name: 'dev',
            pairedAtMs: 1700000000000,
            isCaller: true,
          ),
          DeviceEntry(
            deviceId: 2,
            name: 'laptop',
            pairedAtMs: 1700000001000,
            isCaller: false,
          ),
        ],
      );
      final server = FakeServer();
      final connection = await openConnection(server);
      server.answer = (_) => devices;
      server.replyPieceSizes = [1, 2, 3, 5, 1, 17]; // + the rest = 7 pieces
      expect(await connection.request(const ListDevices()), devices);
      await connection.close();
    });

    test('two queued requests go one at a time and finish in order', () async {
      final server = FakeServer();
      final connection = await openConnection(server);
      final heldRequests = <SentFrame>[];
      server.answer = (request) {
        heldRequests.add(server.sent.last);
        return null;
      };

      final first = connection.request(const ListDevices());
      final second = connection.request(const Ping());
      await pumpEventQueue();
      expect(heldRequests.length, 1, reason: 'second waits for the first');

      server.send(const DeviceList(devices: []), heldRequests[0].requestId);
      expect(await first, isA<DeviceList>());
      await pumpEventQueue();
      expect(heldRequests.length, 2);
      expect(heldRequests[1].message, const Ping());

      server.send(const Pong(), heldRequests[1].requestId);
      expect(await second, const Pong());
      expect([for (final frame in heldRequests) frame.requestId], [2, 3]);
      await connection.close();
    });

    test('no reply within requestTimeout → requestTimeout, link closed', () {
      fakeAsync((async) {
        final server = FakeServer();
        late NasConnection connection;
        openConnection(server).then((opened) => connection = opened);
        async.flushMicrotasks();
        server.answer = (_) => null;

        Object? error;
        connection
            .request(const ListDevices())
            .then<void>((_) {}, onError: (Object caught) => error = caught);
        async.elapse(const Duration(seconds: 29));
        expect(error, isNull);
        async.elapse(const Duration(seconds: 1));
        expect(
          error,
          isA<NasFailure>().having(
            (failure) => failure.kind,
            'kind',
            NasFailureKind.requestTimeout,
          ),
        );
        expect(server.link.isClosed, isTrue);
      });
    });

    test('a per-request timeout overrides requestTimeout (Commit, D-030)', () {
      fakeAsync((async) {
        final server = FakeServer();
        late NasConnection connection;
        openConnection(server).then((opened) => connection = opened);
        async.flushMicrotasks();
        server.answer = (_) => null;

        // A 3 GiB file: the server re-reads it before CommitOk.
        final commitTimeout = Duration(
          milliseconds: commitTimeoutMs(3 * 1073741824),
        );
        Object? error;
        connection
            .request(const Commit(uploadId: 7), timeout: commitTimeout)
            .then<void>((_) {}, onError: (Object caught) => error = caught);
        // Well past the normal 30 s request timeout: still waiting.
        async.elapse(const Duration(seconds: 120));
        expect(error, isNull);
        async.elapse(commitTimeout);
        expect(
          error,
          isA<NasFailure>().having(
            (failure) => failure.kind,
            'kind',
            NasFailureKind.requestTimeout,
          ),
        );
      });
    });

    test('request id wraps from 0xFFFFFFFF to 1, never 0', () async {
      final server = FakeServer();
      final connection = await openConnection(server);
      connection.nextRequestIdForTest = 0xFFFFFFFF;
      await connection.ping();
      await connection.ping();
      expect(
        [for (final frame in server.sent.skip(1)) frame.requestId],
        [0xFFFFFFFF, 1],
      );
      await connection.close();
    });

    test('a server-only message cannot be sent as a request', () async {
      final server = FakeServer();
      final connection = await openConnection(server);
      expect(() => connection.request(const Pong()), throwsArgumentError);
      expect(
        () => connection.request(const ErrorMessage(code: 1, message: '')),
        throwsArgumentError,
      );
      expect(connection.isReady, isTrue);
      await connection.close();
    });
  });

  group('keepalive', () {
    test('Ping after pingInterval without traffic; traffic pushes it back', () {
      fakeAsync((async) {
        final server = FakeServer();
        late NasConnection connection;
        openConnection(server).then((opened) => connection = opened);
        async.flushMicrotasks();
        int pingCount() => server.sentMessages.whereType<Ping>().length;

        async.elapse(const Duration(seconds: 19));
        expect(pingCount(), 0);
        async.elapse(const Duration(seconds: 1));
        expect(pingCount(), 1);

        // A request at 10 s is traffic: the next Ping is 20 s after it.
        async.elapse(const Duration(seconds: 10));
        connection.request(const ListDevices()).ignore();
        async.elapse(const Duration(seconds: 19));
        expect(pingCount(), 1);
        async.elapse(const Duration(seconds: 1));
        expect(pingCount(), 2);
        expect(connection.isReady, isTrue);
        connection.close();
        async.flushMicrotasks();
      });
    });
  });

  group('failures', () {
    test(
      'server Close IDLE_TIMEOUT fails the pending request with that reason',
      () async {
        final server = FakeServer();
        final connection = await openConnection(server);
        server.answer = (_) => null;
        final pending = connection.request(const ListDevices());
        server.send(
          Close(reason: CloseReason.idleTimeout.number, message: 'idle 60 s'),
          0,
        );
        final failure = await pending.then<NasFailure?>(
          (_) => null,
          onError: (Object error) => error as NasFailure,
        );
        expect(failure!.kind, NasFailureKind.serverClosed);
        expect(failure.closeReason, CloseReason.idleTimeout.number);
        expect(failure.message, contains('IDLE_TIMEOUT'));
        expect(failure.message, contains('idle 60 s'));
        expect(connection.state.value, isA<NasClosed>());
        expect(server.link.isClosed, isTrue);
        await expectLater(
          connection.request(const ListDevices()),
          failsWith(NasFailureKind.serverClosed),
        );
      },
    );

    test('garbage bytes (bad length field) → malformed, link closed', () async {
      final server = FakeServer();
      final connection = await openConnection(server);
      server.answer = (_) => null;
      final pending = connection.request(const ListDevices());
      server.link.deliver([0xFF, 0xFF, 0xFF, 0xFF, 1, 2, 3]);
      await expectLater(pending, failsWith(NasFailureKind.malformed));
      expect(server.link.isClosed, isTrue);
    });

    test('unknown message type → malformed, link closed', () async {
      final server = FakeServer();
      final connection = await openConnection(server);
      // length 6, type 0x7777, request id 2, empty payload.
      server.link.deliver([0, 0, 0, 6, 0x77, 0x77, 0, 0, 0, 2]);
      await pumpEventQueue();
      expect(connection.closedBy!.kind, NasFailureKind.malformed);
      expect(server.link.isClosed, isTrue);
    });

    test('reply with an unknown request id → unexpectedReply', () async {
      final server = FakeServer();
      final connection = await openConnection(server);
      server.answer = (_) => null;
      final pending = connection.request(const ListDevices());
      server.send(const DeviceList(devices: []), 99);
      await expectLater(pending, failsWith(NasFailureKind.unexpectedReply));
      expect(server.link.isClosed, isTrue);
    });

    test('reply of the wrong type → unexpectedReply', () async {
      final server = FakeServer();
      final connection = await openConnection(server);
      server.answer = (_) => const Pong();
      await expectLater(
        connection.request(const ListDevices()),
        failsWith(NasFailureKind.unexpectedReply),
      );
    });

    test('link ends after HelloOk → linkClosed', () async {
      final server = FakeServer();
      final connection = await openConnection(server);
      server.answer = (_) => null;
      final pending = connection.request(const ListDevices());
      await server.link.close();
      await expectLater(pending, failsWith(NasFailureKind.linkClosed));
    });
  });

  group('close', () {
    test(
      'close() sends Close NORMAL once and fails waiting requests',
      () async {
        final server = FakeServer();
        final connection = await openConnection(server);
        server.answer = (_) => null;
        final pendingFails = expectLater(
          connection.request(const ListDevices()),
          failsWith(NasFailureKind.closedByClient),
        );
        await pumpEventQueue();

        await Future.wait([connection.close(), connection.close()]);
        await connection.close();

        final closes = server.sent.where((frame) => frame.message is Close);
        expect(closes.length, 1);
        expect(closes.single.requestId, 0);
        expect(
          closes.single.message,
          Close(reason: CloseReason.normal.number, message: ''),
        );
        expect(server.link.isClosed, isTrue);
        await pendingFails;
        await expectLater(
          connection.request(const Ping()),
          failsWith(NasFailureKind.closedByClient),
        );
      },
    );

    test('close() after the server closed sends nothing', () async {
      final server = FakeServer();
      final connection = await openConnection(server);
      server.send(
        Close(reason: CloseReason.serverShutdown.number, message: ''),
        0,
      );
      await pumpEventQueue();
      final sentBefore = server.link.sentChunks.length;
      await connection.close();
      expect(server.link.sentChunks.length, sentBefore);
      expect(connection.closedBy!.kind, NasFailureKind.serverClosed);
    });
  });

  group('log', () {
    test(
      'PairOk is logged with the key redacted and no payload bytes',
      () async {
        final key = Uint8List.fromList(List.filled(40, 0xAB));
        final server = FakeServer()
          ..answer = (request) => switch (request) {
            Hello() => const HelloOk(
              protocolVersion: 1,
              serverSoftware: 'test',
              serverName: 'nas',
              deviceId: 0,
              chunkSizeBytes: 1048576,
              maxFrameLengthBytes: 4194304,
            ),
            PairRequest() => PairOk(
              deviceId: 7,
              deviceCertDer: Uint8List(50),
              deviceKeyPkcs8Der: key,
              serverCertSha256: Uint8List(32),
            ),
            _ => null,
          };
        final log = SessionLog();
        final connection = await openConnection(server, log: log);
        expect(connection.helloOk.deviceId, 0);
        final reply = await connection.request(
          const PairRequest(code: '482913'),
        );
        expect((reply as PairOk).deviceKeyPkcs8Der, key);

        final entry = log.entries.lastWhere(
          (entry) => entry.direction == Direction.received,
        );
        expect(entry.description, startsWith('PairOk('));
        expect(entry.description, contains('<key redacted>'));
        expect(entry.bytes.length, 10, reason: 'frame header only');
        await connection.close();
      },
    );

    test(
      'a big frame is logged with its size but only the first bytes',
      () async {
        final server = FakeServer();
        final log = SessionLog();
        final connection = await openConnection(server, log: log);
        server.answer = (_) =>
            ChunkOk(chunkIndex: 0, chunkSha256: Uint8List(32));
        await connection.request(
          ChunkData(
            uploadId: 1,
            chunkIndex: 0,
            chunkSha256: Uint8List(32),
            data: Uint8List(100000),
          ),
        );
        final entry = log.entries.lastWhere(
          (entry) => entry.direction == Direction.sent,
        );
        expect(entry.description, contains('100058 bytes'));
        expect(entry.bytes.length, maxLoggedFrameBytes);
        await connection.close();
      },
    );
  });
}
