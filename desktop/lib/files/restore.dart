/// Restore to a PC folder the user picks: one file, or a whole backed-up
/// folder with everything below it. Each file is checked against its
/// SHA-256 by the download engine; nothing on the PC is ever replaced
/// (a taken name becomes `name (2).ext`).
///
/// ```
///  restoreFolder(Documents) ─► list every page, depth first
///     ├ file  ─► download ─► <target>/Documents/<path inside>   (hash checked)
///     └ folder ─► go inside
///  ─► RestoreSummary(files done, bytes, failures)
/// ```
///
/// Author: Hao Tran.
library;

import 'dart:io';

import 'package:haotrannas_client/client/download_engine.dart';
import 'package:haotrannas_client/protocol/messages.dart';

/// How a restore ended.
final class RestoreSummary {
  const RestoreSummary({
    required this.filesRestored,
    required this.bytesRestored,
    required this.failures,
    required this.isCancelled,
    this.listingProblem,
  });

  final int filesRestored;
  final int bytesRestored;

  /// Remote path → why it failed.
  final Map<String, String> failures;
  final bool isCancelled;

  /// The listing broke off (connection lost…): not every file was tried.
  final String? listingProblem;

  bool get isComplete =>
      failures.isEmpty && !isCancelled && listingProblem == null;
}

/// Progress: files done so far and the file being restored.
typedef RestoreProgress = void Function(int filesDone, String remotePath);

/// The last part of a remote path; `device` for the device's top level.
String remoteNameOf(String remotePath) =>
    remotePath.isEmpty ? 'device' : remotePath.split('/').last;

/// [folder] + `/` + [name]; just [name] at the top level (`''`).
String joinRemotePath(String folder, String name) =>
    folder.isEmpty ? name : '$folder/$name';

/// Restores one file into [targetFolder] under a free name.
Future<DownloadResult> restoreFile({
  required RemoteFiles files,
  required int deviceId,
  required String remotePath,
  required Directory targetFolder,
  void Function(DownloadProgress progress)? onProgress,
  DownloadCancel? cancel,
}) => files.download(
  deviceId: deviceId,
  remotePath: remotePath,
  outputPath: freeOutputPath(
    '${targetFolder.path}/${remoteNameOf(remotePath)}',
  ),
  onProgress: onProgress,
  cancel: cancel,
);

/// Restores [remoteFolder] of [deviceId] and everything below it into
/// `<targetFolder>/<folder name>/`. Never throws for a server or file
/// problem: see [RestoreSummary].
Future<RestoreSummary> restoreFolder({
  required RemoteFiles files,
  required int deviceId,
  required String remoteFolder,
  required Directory targetFolder,
  RestoreProgress? onProgress,
  DownloadCancel? cancel,
}) async {
  final outputRoot = freeOutputPath(
    '${targetFolder.path}/${remoteNameOf(remoteFolder)}',
  );
  var filesRestored = 0;
  var bytesRestored = 0;
  final failures = <String, String>{};
  final pending = [remoteFolder];
  while (pending.isNotEmpty) {
    final folder = pending.removeLast();
    var startAfter = '';
    while (true) {
      if (cancel?.isCancelled ?? false) {
        return RestoreSummary(
          filesRestored: filesRestored,
          bytesRestored: bytesRestored,
          failures: failures,
          isCancelled: true,
        );
      }
      final DirPage page;
      try {
        page = await files.listDirPage(
          deviceId: deviceId,
          path: folder,
          startAfter: startAfter,
        );
      } on BrowseFailed catch (error) {
        return RestoreSummary(
          filesRestored: filesRestored,
          bytesRestored: bytesRestored,
          failures: failures,
          isCancelled: false,
          listingProblem: '$folder: ${error.message}',
        );
      }
      for (final entry in page.entries) {
        final remotePath = joinRemotePath(folder, entry.name);
        if (entry.kind == DirEntryKind.directory) {
          pending.add(remotePath);
          continue;
        }
        onProgress?.call(filesRestored, remotePath);
        final inside = remoteFolder.isEmpty
            ? remotePath
            : remotePath.substring(remoteFolder.length + 1);
        final result = await files.download(
          deviceId: deviceId,
          remotePath: remotePath,
          versionId: entry.versionId,
          outputPath: '$outputRoot/$inside',
          cancel: cancel,
        );
        switch (result) {
          case DownloadDone(:final sizeBytes):
            filesRestored++;
            bytesRestored += sizeBytes;
          case DownloadCancelled():
            return RestoreSummary(
              filesRestored: filesRestored,
              bytesRestored: bytesRestored,
              failures: failures,
              isCancelled: true,
            );
          case DownloadFailed(:final message):
            failures[remotePath] = message;
        }
      }
      if (!page.hasMore) break;
      startAfter = page.nextStartAfter;
    }
  }
  return RestoreSummary(
    filesRestored: filesRestored,
    bytesRestored: bytesRestored,
    failures: failures,
    isCancelled: false,
  );
}
