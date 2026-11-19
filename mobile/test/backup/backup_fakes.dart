// Fakes for the backup tests: a phone library made of temp files, and a
// connection that stays open across runs so one FakeUploadServer keeps
// its chunks and versions between them (like the real server).
import 'dart:async';
import 'dart:io';

import 'package:haotrannas_mobile/backup/media_source.dart';
import 'package:haotrannas_mobile/client/nas_connection.dart';
import 'package:haotrannas_mobile/protocol/messages.dart';

import '../client/fake_upload_server.dart';

/// A photo library in a temp folder.
class FakeMediaSource implements MediaSource {
  FakeMediaSource(this.folder);

  final Directory folder;
  MediaAccess access = const MediaAccess(MediaAccessLevel.all);
  final itemsById = <String, MediaItem>{};
  final releasedIds = <String>[];

  /// When set, [requestAccess] waits for it (holds a run at its start).
  Completer<void>? accessGate;

  @override
  Future<MediaAccess> requestAccess() async {
    await accessGate?.future;
    return access;
  }

  File fileFor(String id) => File('${folder.path}/$id.bin');

  /// Adds (or replaces) a photo with [bytes] as its content.
  MediaItem put(
    String id,
    List<int> bytes, {
    String? remotePath,
    int modifiedTimeMs = 1763450000000,
    MediaKind kind = MediaKind.image,
  }) {
    fileFor(id).writeAsBytesSync(bytes);
    final item = MediaItem(
      id: id,
      relativePath: remotePath ?? 'DCIM/Camera/$id.jpg',
      sizeBytes: bytes.length,
      modifiedTimeMs: modifiedTimeMs,
      kind: kind,
    );
    itemsById[id] = item;
    return item;
  }

  /// Deletes the photo from the phone.
  void remove(String id) {
    itemsById.remove(id);
    fileFor(id).deleteSync();
  }

  @override
  Stream<MediaItem> listItems({DateTime? changedSince}) => Stream.fromIterable([
    for (final item in itemsById.values)
      if (changedSince == null ||
          item.modifiedTimeMs >= changedSince.millisecondsSinceEpoch)
        item,
  ]);

  @override
  Future<File?> originalFile(MediaItem item) async {
    final file = fileFor(item.id);
    return file.existsSync() ? file : null;
  }

  @override
  Future<void> releaseOriginalFile(MediaItem item) async =>
      releasedIds.add(item.id);
}

/// Forwards requests to one long-lived connection; `close()` is only
/// counted, so the next run talks to the same fake server.
class SharedConnection implements NasConnection {
  SharedConnection(this.inner);

  final NasConnection inner;
  int closeCalls = 0;

  @override
  Future<Message> request(Message message, {Duration? timeout}) =>
      inner.request(message, timeout: timeout);

  @override
  Future<void> close() async => closeCalls++;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// A fake NAS: one [FakeUploadServer] and a connector for the runner.
class FakeNas {
  FakeNas._(this.server, this.connection);

  static Future<FakeNas> start() async {
    final server = FakeUploadServer();
    final inner = await NasConnection.open(
      server.server.link,
      clientSoftware: 'haotrannas-mobile test',
      deviceName: 'test phone',
    );
    return FakeNas._(server, SharedConnection(inner));
  }

  final FakeUploadServer server;
  final SharedConnection connection;
  int connectCalls = 0;

  /// Set to make the next connects fail.
  Exception? connectFailure;

  Future<NasConnection> connect() async {
    connectCalls++;
    final failure = connectFailure;
    if (failure != null) throw failure;
    return connection;
  }

  Future<void> close() => connection.inner.close();

  /// Paths the phone offered, in order.
  List<String> offeredPaths() => [
    for (final offer in server.sentOfType<FileOffer>()) offer.path,
  ];

  List<String> committedPaths() => [
    for (final version in server.latestVersions.values) version.offer.path,
  ];
}

/// A settable clock.
class FakeClock {
  FakeClock([DateTime? start]) : now = start ?? DateTime.utc(2026, 11, 19, 10);

  DateTime now;

  DateTime call() => now;

  void advance(Duration duration) => now = now.add(duration);
}
