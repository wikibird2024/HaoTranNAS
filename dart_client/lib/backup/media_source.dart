/// The backup's view of a library of files: photos on the phone, folders
/// on the PC. Each app has its own source (phone: PhotoManagerMediaSource
/// in `mobile/`; PC: FolderMediaSource in `desktop/`); tests use a fake.
///
/// ```
///  requestAccess ─► all / selectedOnly (Android 14 "selected photos") / none
///  listFolders ───► albums (Camera, Screenshots, WhatsApp Images…) + counts
///  listItems ─────► the chosen folders, Camera first, each newest first,
///                   in pages of 200; a photo in two albums comes once
///                   ─► MediaItem(id, remote path, size, mtime)
///  originalFile ──► the original bytes (setRequireOriginal: EXIF GPS kept
///                   when ACCESS_MEDIA_LOCATION is granted)
/// ```
///
/// The remote path is `relative_path` + file name, e.g.
/// `DCIM/Camera/IMG_0001.jpg`, cleaned by [mediaRemotePath] so it always
/// passes the spec §10 path rules. Author: Hao Tran.
library;

import 'dart:convert';
import 'dart:io';

import '../protocol/limits.dart';
import '../protocol/path_rules.dart';

enum MediaKind { image, video }

/// One photo or video on the phone.
final class MediaItem {
  const MediaItem({
    required this.id,
    required this.relativePath,
    required this.sizeBytes,
    required this.modifiedTimeMs,
    required this.kind,
  });

  /// Stable id from the phone's media database (Android `_id`).
  final String id;

  /// The remote path to back it up as; passes the path rules.
  final String relativePath;
  final int sizeBytes;
  final int modifiedTimeMs;
  final MediaKind kind;

  @override
  String toString() => 'MediaItem($id, $relativePath, $sizeBytes bytes)';
}

/// What the user let the app read.
enum MediaAccessLevel {
  /// Every photo and video.
  all,

  /// Android 14+ "Allow limited access": only the photos the user picked.
  selectedOnly,

  /// Nothing: backup cannot run.
  none,

  /// Not asked (background job: it cannot show a dialog); uses whatever
  /// the user granted in the app.
  notAsked,
}

final class MediaAccess {
  const MediaAccess(this.level);

  final MediaAccessLevel level;

  bool get canRead => level != MediaAccessLevel.none;

  /// One line for the user.
  String get description => switch (level) {
    MediaAccessLevel.all => 'All photos and videos',
    MediaAccessLevel.selectedOnly =>
      'Only the photos you selected: new photos are not backed up until '
          'you allow all photos',
    MediaAccessLevel.none => 'No access to photos: allow it in Settings',
    MediaAccessLevel.notAsked => 'Using the access given in the app',
  };
}

/// One album (Android bucket) of photos and videos.
final class MediaFolder {
  const MediaFolder({
    required this.id,
    required this.name,
    required this.itemCount,
  });

  final String id;

  /// What the gallery shows, e.g. `Camera`, `Screenshots`.
  final String name;
  final int itemCount;

  @override
  String toString() => 'MediaFolder($id, $name, $itemCount)';
}

/// The folder backed up when the user never chose (D-037).
const defaultFolderName = 'Camera';

/// Ids of the folders named [defaultFolderName] (any case).
Set<String> defaultFolderIds(List<MediaFolder> folders) => {
  for (final folder in folders)
    if (folder.name.toLowerCase() == defaultFolderName.toLowerCase()) folder.id,
};

/// [folders] in backup order: Camera first (new photos land there), then
/// by name.
List<MediaFolder> inBackupOrder(Iterable<MediaFolder> folders) {
  bool isCamera(MediaFolder folder) =>
      folder.name.toLowerCase() == defaultFolderName.toLowerCase();
  return folders.toList()..sort((first, second) {
    if (isCamera(first) != isCamera(second)) return isCamera(first) ? -1 : 1;
    return first.name.toLowerCase().compareTo(second.name.toLowerCase());
  });
}

abstract interface class MediaSource {
  /// Asks for photo and video access (shows the system dialog once).
  Future<MediaAccess> requestAccess();

  /// Every album with photos or videos, with its count.
  Future<List<MediaFolder>> listFolders();

  /// The photos and videos of [folderIds] (every folder when null):
  /// Camera first, each folder newest first, each item once.
  Stream<MediaItem> listItems({Set<String>? folderIds});

  /// The original file for [item], or null when it is gone or not on
  /// the phone (for example only in a cloud).
  Future<File?> originalFile(MediaItem item);

  /// Frees any copy [originalFile] made (Android 10 copies into the
  /// cache). Never deletes the user's photo.
  Future<void> releaseOriginalFile(MediaItem item);
}

/// The folder used when the phone gives none (not Android).
const fallbackMediaFolder = 'Photos';

/// Longest file-name extension kept when a name is shortened.
const int _maxKeptExtensionBytes = 16;

/// Folders Android ≤ 9 puts in front of `relative_path` (it is the parent
/// of the absolute DATA path there).
final _storageRootPattern = RegExp(
  r'^/*(storage/emulated/\d+|storage/[^/]+|sdcard)(/|$)',
);

/// Builds the remote path for a media file from its [folder] (Android
/// `relative_path`, e.g. `DCIM/Camera/`) and [fileName]. Deterministic:
/// the same input always gives the same path, so a renamed-by-cleaning
/// file is not uploaded twice.
///
/// Cleaning: `\`, control characters and broken Unicode become `_`; empty
/// parts are dropped; parts made only of dots get `_` for each dot; each
/// part is cut to 255 UTF-8 bytes (a file name keeps its extension);
/// more than 32 parts are merged; a path still over 1024 bytes goes into
/// [fallbackMediaFolder]. An empty name becomes `unnamed_<mediaId>`.
String mediaRemotePath({
  required String? folder,
  required String? fileName,
  required String mediaId,
}) {
  final folderText = (folder ?? '').replaceFirst(_storageRootPattern, '');
  var folderParts = [
    for (final part in folderText.split('/'))
      if (part.isNotEmpty) _cutToBytes(_cleanPart(part)),
  ];
  if (folderParts.isEmpty) folderParts = [fallbackMediaFolder];
  final maxFolderParts = maxPathComponents - 1;
  if (folderParts.length > maxFolderParts) {
    folderParts = [
      ...folderParts.take(maxFolderParts - 1),
      _cutToBytes(folderParts.skip(maxFolderParts - 1).join('_')),
    ];
  }

  var name = _cleanPart((fileName ?? '').replaceAll('/', '_'));
  if (name.isEmpty) {
    name = _cleanPart('unnamed_${mediaId.replaceAll('/', '_')}');
  }
  name = _cutKeepingExtension(name);

  final path = [...folderParts, name].join('/');
  if (pathProblem(path) == null) return path;
  return '$fallbackMediaFolder/$name';
}

String _cleanPart(String part) {
  final cleaned = StringBuffer();
  for (final rune in part.runes) {
    final isControl = rune < 0x20 || rune == 0x7f;
    final isBrokenUnicode = rune >= 0xd800 && rune <= 0xdfff;
    cleaned.write(
      isControl || isBrokenUnicode || rune == 0x5c /* \ */
          ? '_'
          : String.fromCharCode(rune),
    );
  }
  final text = cleaned.toString();
  if (text.isNotEmpty && text.replaceAll('.', '').isEmpty) {
    return '_' * text.length;
  }
  return text;
}

/// Cuts [text] to at most [maxBytes] UTF-8 bytes, never inside a character.
String _cutToBytes(String text, [int maxBytes = maxPathComponentBytes]) {
  if (utf8.encode(text).length <= maxBytes) return text;
  final kept = StringBuffer();
  var keptBytes = 0;
  for (final rune in text.runes) {
    final character = String.fromCharCode(rune);
    final characterBytes = utf8.encode(character).length;
    if (keptBytes + characterBytes > maxBytes) break;
    kept.write(character);
    keptBytes += characterBytes;
  }
  return kept.toString();
}

String _cutKeepingExtension(String name) {
  if (utf8.encode(name).length <= maxPathComponentBytes) return name;
  final dotIndex = name.lastIndexOf('.');
  final extension = dotIndex > 0 ? name.substring(dotIndex) : '';
  if (extension.isEmpty ||
      utf8.encode(extension).length > _maxKeptExtensionBytes) {
    return _cutToBytes(name);
  }
  final stemBytes = maxPathComponentBytes - utf8.encode(extension).length;
  return _cutToBytes(name.substring(0, dotIndex), stemBytes) + extension;
}
