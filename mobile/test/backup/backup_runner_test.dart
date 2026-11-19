// BackupRunner against FakeUploadServer (spec §8 rules in memory), a
// temp-file photo library and the memory store.
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:haotrannas_mobile/backup/backup_runner.dart';
import 'package:haotrannas_mobile/backup/backup_state_store.dart';
import 'package:haotrannas_mobile/backup/media_source.dart';
import 'package:haotrannas_mobile/client/upload_engine.dart';
import 'package:haotrannas_mobile/core/bytes/hex.dart';
import 'package:haotrannas_mobile/protocol/error_codes.dart';
import 'package:haotrannas_mobile/protocol/limits.dart';
import 'package:haotrannas_mobile/protocol/messages.dart';
import 'package:crypto/crypto.dart';

import 'backup_fakes.dart';

const baseTimeMs = 1763450000000;

/// [chunkCount] full chunks of [fillByte] (different bytes = different
/// chunks), plus [tailBytes] bytes.
Uint8List content(int fillByte, {int chunkCount = 0, int tailBytes = 3}) {
  final sizeBytes = chunkCount * chunkSizeBytes + tailBytes;
  return Uint8List(sizeBytes)..fillRange(0, sizeBytes, fillByte);
}

void main() {
  late Directory folder;
  late FakeMediaSource media;
  late MemoryBackupStateStore store;
  late FakeNas nas;
  late FakeClock clock;
  late BackupRunner runner;

  setUp(() async {
    folder = Directory.systemTemp.createTempSync('backup_runner');
    media = FakeMediaSource(folder);
    store = MemoryBackupStateStore();
    nas = await FakeNas.start();
    clock = FakeClock();
    runner = BackupRunner(
      mediaSource: media,
      stateStore: store,
      connect: nas.connect,
      clock: clock.call,
    );
  });

  tearDown(() async {
    await nas.close();
    folder.deleteSync(recursive: true);
  });

  /// Three photos; "c" is the newest.
  void addThreePhotos() {
    media.put('a', content(1), modifiedTimeMs: baseTimeMs);
    media.put('b', content(2), modifiedTimeMs: baseTimeMs + 1000);
    media.put('c', content(3), modifiedTimeMs: baseTimeMs + 2000);
  }

  group('runOnce', () {
    test('first run uploads all, newest first, and records versions', () async {
      addThreePhotos();

      final report = await runner.runOnce();

      expect(report.stopReason, BackupStopReason.finished);
      expect(report.problem, isNull);
      expect(report.itemsScanned, 3);
      expect(report.itemsPicked, 3);
      expect(report.filesUploaded, 3);
      expect(report.bytesUploaded, 9);
      expect(report.itemsLeft, 0);
      expect(nas.offeredPaths(), [
        'DCIM/Camera/c.jpg',
        'DCIM/Camera/b.jpg',
        'DCIM/Camera/a.jpg',
      ]);
      final records = await store.loadAll();
      for (final id in ['a', 'b', 'c']) {
        final record = records[id]!;
        expect(
          record.versionId,
          nas.server.latestVersions[record.remotePath]!.versionId,
        );
        expect(record.sizeBytes, 3);
        expect(record.backedUpAtMs, clock.now.millisecondsSinceEpoch);
        expect(record.lastError, isNull);
      }
      expect(nas.connection.closeCalls, 1, reason: 'connection closed');
      expect(media.releasedIds, unorderedEquals(['a', 'b', 'c']));
    });

    test('second run uploads nothing and does not even connect', () async {
      addThreePhotos();
      await runner.runOnce();
      final offersBefore = nas.offeredPaths().length;

      final report = await runner.runOnce();

      expect(report.stopReason, BackupStopReason.finished);
      expect(report.itemsScanned, 3);
      expect(report.itemsPicked, 0);
      expect(report.filesUploaded, 0);
      expect(nas.offeredPaths().length, offersBefore);
      expect(nas.connectCalls, 1);
    });

    test(
      'a changed file (size or mtime) uploads again as a new version',
      () async {
        addThreePhotos();
        await runner.runOnce();
        final oldVersion = (await store.loadAll())['b']!.versionId;

        media.put(
          'b',
          content(9, tailBytes: 5),
          modifiedTimeMs: baseTimeMs + 5000,
        );
        final report = await runner.runOnce();

        expect(report.itemsPicked, 1);
        expect(report.filesUploaded, 1);
        final record = (await store.loadAll())['b']!;
        expect(record.versionId, isNot(oldVersion));
        expect(record.sizeBytes, 5);
        expect(
          nas.server.latestVersions['DCIM/Camera/b.jpg']!.content,
          content(9, tailBytes: 5),
        );
      },
    );

    test(
      'same content at a new path (moved album): offered, no bytes sent',
      () async {
        media.put('a', content(1), remotePath: 'DCIM/Camera/a.jpg');
        await runner.runOnce();

        media.put('a', content(1), remotePath: 'Pictures/Trip/a.jpg');
        final report = await runner.runOnce();

        expect(report.filesUploaded, 1);
        expect(report.bytesUploaded, 0, reason: 'server had the chunk');
        expect((await store.loadAll())['a']!.remotePath, 'Pictures/Trip/a.jpg');
      },
    );

    test('lost local record: the server says "already backed up"', () async {
      addThreePhotos();
      await runner.runOnce();
      store.records.clear();

      final report = await runner.runOnce();

      expect(report.filesUploaded, 0);
      expect(report.filesAlreadyBackedUp, 3);
      expect((await store.loadAll()).values.every((r) => r.isBackedUp), isTrue);
    });

    test(
      'budget used between files: stop, the next run does the rest',
      () async {
        addThreePhotos();
        // Each commit takes 4 minutes of "time".
        nas.server.onRequest = (request) {
          if (request is Commit) clock.advance(const Duration(minutes: 4));
        };

        final first = await runner.runOnce(budget: const Duration(minutes: 6));

        expect(first.stopReason, BackupStopReason.budgetUsed);
        expect(first.problem, contains('next run'));
        expect(first.filesUploaded, 2);
        expect(first.itemsLeft, 1);
        expect(nas.committedPaths(), hasLength(2));

        final second = await runner.runOnce(budget: const Duration(minutes: 6));

        expect(second.stopReason, BackupStopReason.finished);
        expect(second.itemsPicked, 1);
        expect(second.filesUploaded, 1);
        expect(nas.committedPaths(), hasLength(3));
      },
    );

    test('budget used inside a big file: stops between chunks, the next '
        'run sends only the missing chunks', () async {
      // Four distinct chunks.
      final bytes = BytesBuilder()
        ..add(content(1, chunkCount: 1, tailBytes: 0))
        ..add(content(2, chunkCount: 1, tailBytes: 0))
        ..add(content(3, chunkCount: 1, tailBytes: 0))
        ..add(content(4, tailBytes: 10));
      media.put('video', bytes.toBytes(), kind: MediaKind.video);
      nas.server.onRequest = (request) {
        if (request is ChunkData) clock.advance(const Duration(minutes: 4));
      };

      final first = await runner.runOnce(budget: const Duration(minutes: 7));

      expect(first.stopReason, BackupStopReason.budgetUsed);
      expect(first.filesUploaded, 0);
      expect(first.itemsLeft, 1);
      final sentFirst = nas.server.sentOfType<ChunkData>().length;
      expect(sentFirst, 2, reason: 'stopped after the 2nd chunk (8 min)');
      expect(nas.server.sentOfType<Commit>(), isEmpty);
      expect(
        (await store.loadAll())['video'],
        isNull,
        reason: 'not an error: nothing recorded',
      );

      nas.server.onRequest = null;
      final second = await runner.runOnce();

      expect(second.filesUploaded, 1);
      final indexesSecond = [
        for (final chunk in nas.server.sentOfType<ChunkData>().skip(sentFirst))
          chunk.chunkIndex,
      ];
      expect(indexesSecond, [2, 3], reason: 'resume: only the missing chunks');
      expect(
        nas.server.latestVersions['DCIM/Camera/video.jpg']!.content,
        bytes.toBytes(),
      );
    });

    test('cancel stops the run before the next file', () async {
      addThreePhotos();
      final cancel = UploadCancel();
      nas.server.onRequest = (request) {
        if (request is Commit) cancel.cancel();
      };

      final report = await runner.runOnce(cancel: cancel);

      expect(report.stopReason, BackupStopReason.cancelled);
      expect(report.filesUploaded, 1);
      expect(report.itemsLeft, 2);
    });

    test('a per-item error is recorded and the run goes on', () async {
      addThreePhotos();
      media.put('broken', content(7), modifiedTimeMs: baseTimeMs + 1500);
      media.fileFor('broken').deleteSync(); // e.g. only in a cloud

      final report = await runner.runOnce();

      expect(report.stopReason, BackupStopReason.finished);
      expect(report.filesUploaded, 3);
      expect(report.filesFailed, 1);
      expect(report.failures.single.remotePath, 'DCIM/Camera/broken.jpg');
      final broken = (await store.loadAll())['broken']!;
      expect(broken.isBackedUp, isFalse);
      expect(broken.lastError, contains('not on the phone'));

      // Next run tries it again (and fails again, still recorded).
      final again = await runner.runOnce();
      expect(again.itemsPicked, 1);
      expect(again.filesFailed, 1);
    });

    test(
      'a server error on one file (DISK_FULL) does not stop the run',
      () async {
        addThreePhotos();
        nas.server.replyOverride = (request) =>
            request is FileOffer && request.path == 'DCIM/Camera/b.jpg'
            ? ErrorMessage(
                code: ErrorCode.diskFull.number,
                message: 'disk full',
              )
            : null;

        final report = await runner.runOnce();

        expect(report.filesUploaded, 2);
        expect(report.filesFailed, 1);
        expect(report.failures.single.remotePath, 'DCIM/Camera/b.jpg');
      },
    );

    test('a failed re-upload keeps the old version on record', () async {
      addThreePhotos();
      await runner.runOnce();
      final before = (await store.loadAll())['a']!;
      media.put('a', content(8), modifiedTimeMs: baseTimeMs + 9000);
      media.fileFor('a').deleteSync();

      await runner.runOnce();

      final after = (await store.loadAll())['a']!;
      expect(after.versionId, before.versionId);
      expect(after.modifiedTimeMs, before.modifiedTimeMs);
      expect(after.lastError, isNotNull);
      expect(
        BackupRunner.needsUpload(media.itemsById['a']!, after),
        isTrue,
        reason: 'still picked next time',
      );
    });

    test('connection loss stops the run and is reported', () async {
      addThreePhotos();
      var offers = 0;
      nas.server.replyOverride = (request) {
        if (request is FileOffer && ++offers == 2) {
          return Close(
            reason: CloseReason.serverShutdown.number,
            message: 'server shutting down',
          );
        }
        return null;
      };

      final report = await runner.runOnce();

      expect(report.stopReason, BackupStopReason.connectionLost);
      expect(report.problem, contains('Connection lost'));
      expect(report.filesUploaded, 1);
      expect(report.filesFailed, 0, reason: 'not the files\' fault');
      expect(report.itemsLeft, 2);
      expect((await store.loadAll()).length, 1);
    });

    test('server not reachable: nothing uploaded, problem reported', () async {
      addThreePhotos();
      nas.connectFailure = const BackupConnectFailed('No address worked');

      final report = await runner.runOnce();

      expect(report.stopReason, BackupStopReason.connectFailed);
      expect(report.problem, contains('No address worked'));
      expect(report.itemsPicked, 3);
      expect(report.itemsLeft, 3);
    });

    test('no photo access: stops before scanning', () async {
      addThreePhotos();
      media.access = const MediaAccess(MediaAccessLevel.none);

      final report = await runner.runOnce();

      expect(report.stopReason, BackupStopReason.noMediaAccess);
      expect(report.problem, isNotNull);
      expect(nas.connectCalls, 0);
    });

    test('limited access (Android 14 selected photos) still runs', () async {
      addThreePhotos();
      media.access = const MediaAccess(MediaAccessLevel.selectedOnly);

      final report = await runner.runOnce();

      expect(report.mediaAccess!.level, MediaAccessLevel.selectedOnly);
      expect(report.filesUploaded, 3);
    });

    test('progress reports each file and its chunks', () async {
      media.put('a', content(1, chunkCount: 1));
      final progress = <BackupProgress>[];

      await runner.runOnce(onProgress: progress.add);

      expect(progress.first.itemsTotal, 1);
      expect(progress.first.currentPath, 'DCIM/Camera/a.jpg');
      expect(progress.where((step) => step.upload != null), hasLength(2));
    });
  });

  group('verifyAll', () {
    test('re-offers every backed-up file; all fine → nothing sent', () async {
      addThreePhotos();
      await runner.runOnce();
      final offersBefore = nas.offeredPaths().length;
      final chunksBefore = nas.server.sentOfType<ChunkData>().length;
      clock.advance(const Duration(days: 1));

      final report = await runner.verifyAll();

      expect(report.stopReason, BackupStopReason.finished);
      expect(report.filesChecked, 3);
      expect(report.filesRepaired, 0);
      expect(nas.offeredPaths().length - offersBefore, 3);
      expect(nas.server.sentOfType<ChunkData>().length, chunksBefore);
      for (final record in (await store.loadAll()).values) {
        expect(record.lastVerifiedAtMs, clock.now.millisecondsSinceEpoch);
      }
    });

    test('heals a chunk the server lost (scrub marked it bad)', () async {
      final bytes =
          (BytesBuilder()
                ..add(content(1, chunkCount: 1, tailBytes: 0))
                ..add(content(2, chunkCount: 1, tailBytes: 0))
                ..add(content(3, tailBytes: 100)))
              .toBytes();
      media.put('a', bytes);
      media.put('b', content(4));
      await runner.runOnce();
      final versionBefore = (await store.loadAll())['a']!.versionId;

      // Scrub found chunk 1 of "a" bad. The fake has no "bad" flag: the
      // chunk is dropped and the version forgotten, so the offer gets a
      // new upload that asks for that chunk only, as spec §8 says.
      final chunkOneHash = toHex(
        sha256.convert(content(2, chunkCount: 1, tailBytes: 0)).bytes,
        separator: '',
      );
      nas.server.storedChunks.remove(chunkOneHash);
      nas.server.latestVersions.remove('DCIM/Camera/a.jpg');
      final chunksBefore = nas.server.sentOfType<ChunkData>().length;

      final report = await runner.verifyAll();

      expect(report.filesChecked, 2);
      expect(report.filesRepaired, 1);
      final resent = nas.server.sentOfType<ChunkData>().skip(chunksBefore);
      expect([for (final chunk in resent) chunk.chunkIndex], [1]);
      expect(nas.server.storedChunks.containsKey(chunkOneHash), isTrue);
      expect(nas.server.latestVersions['DCIM/Camera/a.jpg']!.content, bytes);
      final record = (await store.loadAll())['a']!;
      expect(record.versionId, isNot(versionBefore));
    });

    test(
      'Commit CHUNKS_MISSING during verify: re-offer sends the chunk',
      () async {
        media.put('a', content(1, chunkCount: 1));
        await runner.runOnce();
        nas.server.latestVersions.clear(); // server must re-check "a"
        nas.server.badChunkIndex = 0;
        nas.server.badChunkCommitsLeft = 1;

        final report = await runner.verifyAll();

        expect(report.filesRepaired, 1);
        expect(report.filesFailed, 0);
      },
    );

    test('skips deleted and changed files, counts them', () async {
      addThreePhotos();
      await runner.runOnce();
      media.remove('a');
      media.put('b', content(9), modifiedTimeMs: baseTimeMs + 99000);

      final report = await runner.verifyAll();

      expect(report.filesChecked, 1);
      expect(report.filesNotOnPhone, 1);
      expect(report.filesChangedOnPhone, 1);
    });

    test(
      'oldest-verified first, so a stopped verify goes on next time',
      () async {
        addThreePhotos();
        await runner.runOnce();
        final records = await store.loadAll();
        await store.put(records['a']!.copyWith(lastVerifiedAtMs: 3));
        await store.put(records['b']!.copyWith(lastVerifiedAtMs: 1));
        await store.put(records['c']!.copyWith(lastVerifiedAtMs: 2));
        final offersBefore = nas.offeredPaths().length;

        await runner.verifyAll();

        expect(nas.offeredPaths().skip(offersBefore), [
          'DCIM/Camera/b.jpg',
          'DCIM/Camera/c.jpg',
          'DCIM/Camera/a.jpg',
        ]);
      },
    );

    test('budget stops a verify', () async {
      addThreePhotos();
      await runner.runOnce();
      nas.server.onRequest = (request) {
        if (request is FileOffer) clock.advance(const Duration(minutes: 5));
      };

      final report = await runner.verifyAll(budget: const Duration(minutes: 9));

      expect(report.stopReason, BackupStopReason.budgetUsed);
      expect(report.filesChecked, 2);
    });
  });
}
