/// The PC's [MediaSource]: the folders the user added on the Backup page,
/// walked file by file (D-039).
///
/// ```
///  chosen folder ids = absolute paths, e.g. /home/hao/Documents
///  listFolders ─► one MediaFolder per path (name = last part, count of files)
///  listItems ───► every regular file below, streamed while walking
///                 (symlinks and special files skipped, unreadable folders skipped)
///                 ─► MediaItem(id = absolute path, remote path = Documents/notes/a.txt)
///  originalFile ─► the file itself (nothing is copied)
/// ```
///
/// The remote path is `<folder name>/<path inside it>`, so two chosen
/// folders must not share a name ([folderNameClash]). A path that breaks
/// the path rules still comes out: its upload fails with the reason.
/// Author: Hao Tran.
library;

import 'dart:async';
import 'dart:io';

import 'package:haotrannas_client/backup/media_source.dart';

class FolderMediaSource implements MediaSource {
  /// [chosenFolderPaths]: the user's folders, read at each call (they
  /// live in the backup settings).
  FolderMediaSource({required this.chosenFolderPaths, this.onSkipped});

  final Set<String> Function() chosenFolderPaths;

  /// Told about each folder or file that could not be read.
  final void Function(String note)? onSkipped;

  /// A PC needs no permission dialog: the app reads what the user can.
  @override
  Future<MediaAccess> requestAccess() async =>
      const MediaAccess(MediaAccessLevel.all);

  @override
  Future<List<MediaFolder>> listFolders() async {
    final paths = chosenFolderPaths().toList()..sort();
    return [
      for (final path in paths)
        MediaFolder(
          id: path,
          name: folderNameOf(path),
          itemCount: await _countFiles(path),
        ),
    ];
  }

  @override
  Stream<MediaItem> listItems({Set<String>? folderIds}) async* {
    final paths = (folderIds ?? chosenFolderPaths()).toList()..sort();
    for (final root in paths) {
      final rootName = folderNameOf(root);
      await for (final entity in _walk(root)) {
        if (entity is! File) continue;
        final FileStat stat;
        try {
          stat = await entity.stat();
        } on FileSystemException catch (error) {
          onSkipped?.call('cannot read ${entity.path}: ${error.message}');
          continue;
        }
        if (stat.type != FileSystemEntityType.file) continue;
        yield MediaItem(
          id: entity.path,
          relativePath: '$rootName/${_insidePath(root, entity.path)}',
          sizeBytes: stat.size,
          modifiedTimeMs: stat.modified.millisecondsSinceEpoch,
          kind: MediaKind.file,
        );
      }
    }
  }

  @override
  Future<File?> originalFile(MediaItem item) async {
    final file = File(item.id);
    return await file.exists() ? file : null;
  }

  @override
  Future<void> releaseOriginalFile(MediaItem item) async {}

  /// Every entity below [root], not following links; a folder that
  /// cannot be read is skipped (and noted), the walk goes on.
  Stream<FileSystemEntity> _walk(String root) {
    final folder = Directory(root);
    if (!folder.existsSync()) {
      onSkipped?.call('folder missing: $root');
      return const Stream.empty();
    }
    return folder
        .list(recursive: true, followLinks: false)
        .handleError(
          (Object error) => onSkipped?.call('skipped: $error'),
          test: (error) => error is FileSystemException,
        );
  }

  Future<int> _countFiles(String root) =>
      _walk(root).where((entity) => entity is File).length;

  /// [path] relative to [root], with `/` separators.
  static String _insidePath(String root, String path) {
    final prefix = root.endsWith('/') ? root : '$root/';
    return path.startsWith(prefix) ? path.substring(prefix.length) : path;
  }
}

/// The last part of a folder path: `/home/hao/Documents/` → `Documents`.
String folderNameOf(String path) {
  final parts = path.split('/').where((part) => part.isNotEmpty);
  return parts.isEmpty ? '/' : parts.last;
}

/// Null when [newPath] can be added to [chosenPaths]; otherwise why not
/// (already chosen, inside or around a chosen folder, or the same name as
/// one, which would mix both on the server).
String? folderNameClash(String newPath, Iterable<String> chosenPaths) {
  String withSlash(String path) => path.endsWith('/') ? path : '$path/';
  final newName = folderNameOf(newPath);
  for (final chosen in chosenPaths) {
    if (withSlash(chosen) == withSlash(newPath)) {
      return 'This folder is already backed up.';
    }
    if (withSlash(newPath).startsWith(withSlash(chosen))) {
      return 'This folder is inside $chosen, which is already backed up.';
    }
    if (withSlash(chosen).startsWith(withSlash(newPath))) {
      return 'This folder holds $chosen, which is already backed up. '
          'Remove that one first.';
    }
    if (folderNameOf(chosen) == newName) {
      return 'Another backed-up folder is also named "$newName" ($chosen). '
          'Their files would mix on the NAS.';
    }
  }
  return null;
}
