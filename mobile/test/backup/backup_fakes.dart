// Fakes for the backup tests: a phone library made of temp files, and a
// connection that stays open across runs so one FakeUploadServer keeps
// its chunks and versions between them (like the real server).
import 'dart:async';
import 'dart:io';

import 'package:haotrannas_mobile/backup/media_source.dart';
import 'package:haotrannas_mobile/client/nas_connection.dart';
import 'package:haotrannas_mobile/protocol/messages.dart';

import '../client/fake_upload_server.dart';

/// Album id of the fake's Camera album (where [FakeMediaSource.put]
/// puts photos unless told otherwise).
const fakeCameraFolderId = 'camera';

/// A photo library in a temp folder, in albums.
class FakeMediaSource implements MediaSource {
  FakeMediaSource(this.folder);

  final Directory folder;
  MediaAccess access = const MediaAccess(MediaAccessLevel.all);
  final itemsById = <String, MediaItem>{};
  final releasedIds = <String>[];

  /// Album id → album name; Camera is always there.
  final folderNames = <String, String>{fakeCameraFolderId: 'Camera'};

  /// Media id → album ids it is in (a photo can be in two).
  final folderIdsOf = <String, Set<String>>{};

  /// Folder ids asked for by the last [listItems].
  Set<String>? lastListedFolderIds;

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
    Set<String> folderIds = const {fakeCameraFolderId},
  }) {
    fileFor(id).writeAsBytesSync(bytes);
    folderIdsOf[id] = folderIds;
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
    folderIdsOf.remove(id);
    fileFor(id).deleteSync();
  }

  List<MediaFolder> get _folders => [
    for (final MapEntry(key: id, value: name) in folderNames.entries)
      MediaFolder(
        id: id,
        name: name,
        itemCount: folderIdsOf.values.where((ids) => ids.contains(id)).length,
      ),
  ];

  @override
  Future<List<MediaFolder>> listFolders() async => _folders;

  /// Like the real source: Camera first, each folder newest first, each
  /// item once.
  @override
  Stream<MediaItem> listItems({Set<String>? folderIds}) {
    lastListedFolderIds = folderIds;
    final seenIds = <String>{};
    final items = <MediaItem>[];
    for (final folder in inBackupOrder(_folders)) {
      if (folderIds != null && !folderIds.contains(folder.id)) continue;
      final inFolder =
          [
            for (final item in itemsById.values)
              if (folderIdsOf[item.id]!.contains(folder.id)) item,
          ]..sort((first, second) {
            final byTime = second.modifiedTimeMs.compareTo(
              first.modifiedTimeMs,
            );
            return byTime != 0 ? byTime : first.id.compareTo(second.id);
          });
      items.addAll(inFolder.where((item) => seenIds.add(item.id)));
    }
    return Stream.fromIterable(items);
  }

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
