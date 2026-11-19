// restoreFolder / restoreFile on an in-memory RemoteFiles: structure kept,
// paging followed, names never replaced, failures and cancel reported.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:haotrannas_client/client/download_engine.dart';
import 'package:haotrannas_client/protocol/messages.dart';
import 'package:haotrannas_desktop/files/restore.dart';

/// Files of one device by remote path; pages of [pageSize] entries.
class MemoryRemoteFiles implements RemoteFiles {
  MemoryRemoteFiles(this.files, {this.pageSize = 2});

  final Map<String, String> files;
  final int pageSize;
  final failPaths = <String>{};
  final downloaded = <String>[];
  void Function()? afterDownload;

  @override
  Future<List<DeviceEntry>> listDevices() async => const [];

  @override
  Future<DirPage> listDirPage({
    required int deviceId,
    required String path,
    String startAfter = '',
    int maxEntries = 0,
  }) async {
    final prefix = path.isEmpty ? '' : '$path/';
    final names = <String, bool>{};
    for (final filePath in files.keys) {
      if (!filePath.startsWith(prefix)) continue;
      final rest = filePath.substring(prefix.length).split('/');
      names[rest.first] = rest.length > 1 || (names[rest.first] ?? false);
    }
    final sorted = names.keys.toList()..sort();
    final after = sorted
        .where((name) => name.compareTo(startAfter) > 0)
        .toList();
    final page = after.take(pageSize).toList();
    return DirPage(
      entries: [
        for (final name in page)
          DirEntry(
            name: name,
            kind: names[name]! ? DirEntryKind.directory : DirEntryKind.file,
            sizeBytes: names[name]! ? 0 : files['$prefix$name']!.length,
            modifiedTimeMs: 0,
            versionId: names[name]! ? 0 : 1,
          ),
      ],
      hasMore: after.length > page.length,
    );
  }

  @override
  Future<DownloadResult> download({
    required int deviceId,
    required String remotePath,
    int versionId = 0,
    required String outputPath,
    bool isOverwriteAllowed = false,
    void Function(DownloadProgress progress)? onProgress,
    DownloadCancel? cancel,
  }) async {
    if (cancel?.isCancelled ?? false) {
      return const DownloadCancelled(chunksDone: 0);
    }
    if (failPaths.contains(remotePath)) {
      return const DownloadFailed(
        DownloadFailureKind.fileHashMismatch,
        'file hash does not match',
      );
    }
    final content = files[remotePath]!;
    File(outputPath)
      ..createSync(recursive: true)
      ..writeAsStringSync(content);
    downloaded.add(remotePath);
    afterDownload?.call();
    return DownloadDone(
      outputPath: outputPath,
      versionId: versionId,
      sizeBytes: content.length,
      modifiedTimeMs: 0,
    );
  }
}

void main() {
  late Directory target;
  late MemoryRemoteFiles remote;

  setUp(() {
    target = Directory.systemTemp.createTempSync('restore_target');
    remote = MemoryRemoteFiles({
      'Documents/a.txt': 'a',
      'Documents/b.txt': 'bb',
      'Documents/c.txt': 'ccc',
      'Documents/notes/deep/d.md': 'dddd',
      'Pictures/p.jpg': 'p',
    });
  });

  tearDown(() => target.deleteSync(recursive: true));

  Map<String, String> filesUnder(Directory folder) => {
    for (final file in folder.listSync(recursive: true).whereType<File>())
      file.path.substring(folder.path.length + 1): file.readAsStringSync(),
  };

  test('a folder comes back with its structure, across pages', () async {
    final summary = await restoreFolder(
      files: remote,
      deviceId: 1,
      remoteFolder: 'Documents',
      targetFolder: target,
    );
    expect(summary.isComplete, isTrue);
    expect(summary.filesRestored, 4);
    expect(summary.bytesRestored, 10);
    expect(filesUnder(target), {
      'Documents/a.txt': 'a',
      'Documents/b.txt': 'bb',
      'Documents/c.txt': 'ccc',
      'Documents/notes/deep/d.md': 'dddd',
    });
  });

  test('an existing folder is never replaced: "Documents (2)"', () async {
    File('${target.path}/Documents/a.txt')
      ..createSync(recursive: true)
      ..writeAsStringSync('mine');
    await restoreFolder(
      files: remote,
      deviceId: 1,
      remoteFolder: 'Documents',
      targetFolder: target,
    );
    expect(File('${target.path}/Documents/a.txt').readAsStringSync(), 'mine');
    expect(File('${target.path}/Documents (2)/a.txt').readAsStringSync(), 'a');
  });

  test('a failed file is listed, the rest still comes', () async {
    remote.failPaths.add('Documents/b.txt');
    final summary = await restoreFolder(
      files: remote,
      deviceId: 1,
      remoteFolder: 'Documents',
      targetFolder: target,
    );
    expect(summary.isComplete, isFalse);
    expect(summary.failures.keys, ['Documents/b.txt']);
    expect(summary.filesRestored, 3);
  });

  test('cancel stops before the next file', () async {
    final cancel = DownloadCancel();
    remote.afterDownload = cancel.cancel;
    final summary = await restoreFolder(
      files: remote,
      deviceId: 1,
      remoteFolder: 'Documents',
      targetFolder: target,
      cancel: cancel,
    );
    expect(summary.isCancelled, isTrue);
    expect(remote.downloaded, hasLength(1));
  });

  test('one file goes to the folder under a free name', () async {
    File('${target.path}/p.jpg').writeAsStringSync('old');
    final result = await restoreFile(
      files: remote,
      deviceId: 1,
      remotePath: 'Pictures/p.jpg',
      targetFolder: target,
    );
    expect((result as DownloadDone).outputPath, '${target.path}/p (2).jpg');
    expect(File('${target.path}/p.jpg').readAsStringSync(), 'old');
  });

  test('path helpers', () {
    expect(joinRemotePath('', 'a'), 'a');
    expect(joinRemotePath('x/y', 'a'), 'x/y/a');
    expect(remoteNameOf('x/y'), 'y');
    expect(remoteNameOf(''), 'device');
  });
}
