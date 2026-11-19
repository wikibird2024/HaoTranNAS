/// Browse and download (spec §9): ListDevices, paged ListDir, and one
/// file version: ReadFile → FileManifest → ReadChunk per hash, in order.
///
/// ```
///  download(deviceId, remotePath, versionId, outputPath)
///    path rules, output exists? (only replaced when asked)
///    ReadFile ─► FileManifest (chunk count = ceil(size / 1 MiB)?)
///    for each chunk hash, in order:
///      ReadChunk ─► ChunkContent: same hash? right size? SHA-256(data) ok?
///      write to <output>.part
///    flush + fsync ─► SHA-256(.part) == file_sha256? ─► rename to output
///  cancel or any failure ─► .part deleted, output untouched
/// ```
///
/// Never throws for a network, server or file problem: listing throws
/// only [BrowseFailed]; [DownloadEngine.download] returns a
/// [DownloadResult]. Author: Hao Tran.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:collection/collection.dart';
import 'package:crypto/crypto.dart';

import '../protocol/error_codes.dart';
import '../protocol/limits.dart';
import '../protocol/messages.dart';
import '../protocol/path_rules.dart';
import 'chunker.dart';
import 'nas_connection.dart';

/// Suffix of the temporary file a download writes before the rename.
const String partFileSuffix = '.part';

/// Bytes read at a time when hashing the finished `.part` file.
const int fileHashReadBytes = chunkSizeBytes;

// ── Browse ────────────────────────────────────────────────────────────

/// Why a listing failed.
enum BrowseFailureKind {
  /// NOT_FOUND: no such device, or a folder with nothing in it.
  notFound,

  /// The path breaks the path rules (checked here, or BAD_PATH).
  badPath,

  /// The server answered something the protocol does not allow (a page
  /// that does not move forward).
  badReply,

  /// Any other Error from the server; see [BrowseFailed.errorCode].
  serverRejected,

  /// The connection ended; see [BrowseFailed.connectionFailure].
  connectionLost,
}

/// A listing did not work. The only exception the listing methods throw.
class BrowseFailed implements Exception {
  const BrowseFailed(
    this.kind,
    this.message, {
    this.errorCode,
    this.connectionFailure,
  });

  final BrowseFailureKind kind;

  /// One line for a person.
  final String message;
  final int? errorCode;
  final NasFailure? connectionFailure;

  @override
  String toString() => 'BrowseFailed(${kind.name}): $message';
}

/// One ListDir page.
final class DirPage {
  const DirPage({required this.entries, required this.hasMore});

  final List<DirEntry> entries;

  /// More entries come after [entries]; ask again with [nextStartAfter].
  final bool hasMore;

  /// The `start_after` for the next page: the last name of this one.
  String get nextStartAfter => entries.isEmpty ? '' : entries.last.name;
}

/// What the browse screen needs from the server. [DownloadEngine] is the
/// real one; widget tests use a fake.
abstract interface class RemoteFiles {
  /// Every paired device (spec §9). Throws [BrowseFailed].
  Future<List<DeviceEntry>> listDevices();

  /// One page of [path] on [deviceId] (0 = this phone), names after
  /// [startAfter]. Throws [BrowseFailed].
  Future<DirPage> listDirPage({
    required int deviceId,
    required String path,
    String startAfter = '',
    int maxEntries = maxListDirEntries,
  });

  /// Downloads one file version to [outputPath]; see
  /// [DownloadEngine.download].
  Future<DownloadResult> download({
    required int deviceId,
    required String remotePath,
    int versionId = 0,
    required String outputPath,
    bool isOverwriteAllowed = false,
    void Function(DownloadProgress progress)? onProgress,
    DownloadCancel? cancel,
  });
}

// ── Download results ──────────────────────────────────────────────────

/// Set [cancel] from anywhere; the download stops before its next chunk
/// and deletes the `.part` file.
final class DownloadCancel {
  bool _isCancelled = false;

  bool get isCancelled => _isCancelled;

  void cancel() => _isCancelled = true;
}

/// Where a download is, sent after each chunk written.
final class DownloadProgress {
  const DownloadProgress({
    required this.chunksDone,
    required this.totalChunks,
    required this.bytesDone,
    required this.sizeBytes,
  });

  final int chunksDone;
  final int totalChunks;
  final int bytesDone;
  final int sizeBytes;

  /// 0.0 ..= 1.0; 1.0 for an empty file.
  double get fraction => sizeBytes == 0 ? 1.0 : bytesDone / sizeBytes;

  @override
  String toString() =>
      'DownloadProgress($chunksDone/$totalChunks chunks, $bytesDone bytes)';
}

enum DownloadFailureKind {
  /// The remote path breaks the path rules (checked here, or BAD_PATH).
  badPath,

  /// NOT_FOUND: no such device, path, version or chunk.
  notFound,

  /// A file is already at the output path and replacing it was not
  /// asked for. Nothing was downloaded.
  outputExists,

  /// A chunk's bytes do not match its hash in the manifest.
  chunkHashMismatch,

  /// A chunk has the wrong length for its place in the file.
  chunkSizeWrong,

  /// Every chunk was fine, but the whole file's SHA-256 is not the
  /// manifest's `file_sha256`.
  fileHashMismatch,

  /// The server answered something the protocol does not allow.
  badReply,

  /// Any other Error from the server; see [DownloadFailed.errorCode].
  serverRejected,

  /// The connection ended; see [DownloadFailed.connectionFailure].
  connectionLost,

  /// The phone could not write the file (no space, no permission).
  localWriteFailed,
}

/// How one download ended. [DownloadEngine.download] never throws for a
/// network, server or file problem.
sealed class DownloadResult {
  const DownloadResult();
}

/// The file is at [outputPath], checked against `file_sha256`.
final class DownloadDone extends DownloadResult {
  const DownloadDone({
    required this.outputPath,
    required this.versionId,
    required this.sizeBytes,
    required this.modifiedTimeMs,
  });

  final String outputPath;
  final int versionId;
  final int sizeBytes;
  final int modifiedTimeMs;

  @override
  String toString() =>
      'downloaded version $versionId ($sizeBytes bytes) to $outputPath';
}

/// [DownloadCancel.cancel] was called; the `.part` file is deleted.
final class DownloadCancelled extends DownloadResult {
  const DownloadCancelled({required this.chunksDone});

  final int chunksDone;

  @override
  String toString() => 'download cancelled after $chunksDone chunks';
}

/// Stopped on a problem; the `.part` file is deleted and the output path
/// is untouched.
final class DownloadFailed extends DownloadResult {
  const DownloadFailed(
    this.kind,
    this.message, {
    this.errorCode,
    this.connectionFailure,
  });

  final DownloadFailureKind kind;

  /// One line for a person.
  final String message;
  final int? errorCode;
  final NasFailure? connectionFailure;

  @override
  String toString() => 'download failed (${kind.name}): $message';
}

// ── Engine ────────────────────────────────────────────────────────────

/// Lists and downloads over one [NasConnection], one request at a time.
class DownloadEngine implements RemoteFiles {
  DownloadEngine(this.connection);

  final NasConnection connection;

  @override
  Future<List<DeviceEntry>> listDevices() async {
    final reply = await _browseRequest(const ListDevices()) as DeviceList;
    return reply.devices;
  }

  @override
  Future<DirPage> listDirPage({
    required int deviceId,
    required String path,
    String startAfter = '',
    int maxEntries = maxListDirEntries,
  }) async {
    if (maxEntries < 1 || maxEntries > maxListDirEntries) {
      throw ArgumentError.value(
        maxEntries,
        'maxEntries',
        'must be 1..$maxListDirEntries',
      );
    }
    final pathProblemText = path.isEmpty ? null : pathProblem(path);
    if (pathProblemText != null) {
      throw BrowseFailed(
        BrowseFailureKind.badPath,
        'path not allowed: $pathProblemText',
      );
    }
    final reply = await _browseRequest(
      ListDir(
        deviceId: deviceId,
        path: path,
        startAfter: startAfter,
        maxEntries: maxEntries,
      ),
    ) as DirEntries;
    final pageProblem = _pageProblem(reply, startAfter, maxEntries);
    if (pageProblem != null) {
      throw BrowseFailed(BrowseFailureKind.badReply, pageProblem);
    }
    return DirPage(entries: reply.entries, hasMore: reply.hasMore);
  }

  /// Every entry of [path], page after page (`start_after` = the last
  /// name seen) until `has_more` is false. Pages are asked for only as
  /// the stream is read. Throws [BrowseFailed] through the stream.
  Stream<DirEntry> listDir({
    required int deviceId,
    required String path,
    int pageSize = maxListDirEntries,
  }) async* {
    var startAfter = '';
    while (true) {
      final page = await listDirPage(
        deviceId: deviceId,
        path: path,
        startAfter: startAfter,
        maxEntries: pageSize,
      );
      yield* Stream.fromIterable(page.entries);
      if (!page.hasMore) return;
      startAfter = page.nextStartAfter;
    }
  }

  /// [listDir] collected into one list.
  Future<List<DirEntry>> listDirAll({
    required int deviceId,
    required String path,
    int pageSize = maxListDirEntries,
  }) => listDir(deviceId: deviceId, path: path, pageSize: pageSize).toList();

  /// Downloads [remotePath] of [deviceId] (0 = this phone), version
  /// [versionId] (0 = latest), to [outputPath]. Missing parent folders
  /// are made. An existing file at [outputPath] is replaced only when
  /// [isOverwriteAllowed]. [onProgress] is called after each chunk.
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
    final pathProblemText = pathProblem(remotePath);
    if (pathProblemText != null) {
      return DownloadFailed(
        DownloadFailureKind.badPath,
        'remote path not allowed: $pathProblemText',
      );
    }
    final outputProblem = _outputProblem(outputPath, isOverwriteAllowed);
    if (outputProblem != null) return outputProblem;

    final FileManifest manifest;
    try {
      manifest = await connection.request(
        ReadFile(deviceId: deviceId, path: remotePath, versionId: versionId),
      ) as FileManifest;
    } on NasRequestError catch (error) {
      return _failureFor(error, remotePath);
    } on NasFailure catch (failure) {
      return _connectionLost(failure);
    }
    final expectedChunks = expectedChunkCount(manifest.sizeBytes);
    if (manifest.chunkHashes.length != expectedChunks) {
      return DownloadFailed(
        DownloadFailureKind.badReply,
        'FileManifest lists ${manifest.chunkHashes.length} chunks for '
        '${manifest.sizeBytes} bytes; expected $expectedChunks',
      );
    }

    final download = _Download(
      connection: connection,
      manifest: manifest,
      outputPath: outputPath,
      isOverwriteAllowed: isOverwriteAllowed,
      onProgress: onProgress,
      cancel: cancel,
    );
    final DownloadResult result;
    try {
      result = await download.run();
    } on NasRequestError catch (error) {
      await download.deletePart();
      return _failureFor(error, remotePath);
    } on NasFailure catch (failure) {
      await download.deletePart();
      return _connectionLost(failure);
    } on FileSystemException catch (error) {
      await download.deletePart();
      return DownloadFailed(
        DownloadFailureKind.localWriteFailed,
        'cannot write ${error.path ?? outputPath}: ${error.message}',
      );
    }
    if (result is! DownloadDone) await download.deletePart();
    return result;
  }

  /// Sends a listing request; server errors become [BrowseFailed].
  Future<Message> _browseRequest(Message request) async {
    try {
      return await connection.request(request);
    } on NasRequestError catch (error) {
      throw BrowseFailed(
        switch (error.knownCode) {
          ErrorCode.notFound => BrowseFailureKind.notFound,
          ErrorCode.badPath => BrowseFailureKind.badPath,
          _ => BrowseFailureKind.serverRejected,
        },
        'server error ${error.codeName}: ${error.message}',
        errorCode: error.code,
      );
    } on NasFailure catch (failure) {
      throw BrowseFailed(
        BrowseFailureKind.connectionLost,
        failure.message,
        connectionFailure: failure,
      );
    }
  }

  /// A page must stay inside [maxEntries] and move forward, or auto
  /// paging could loop for ever.
  static String? _pageProblem(
    DirEntries reply,
    String startAfter,
    int maxEntries,
  ) {
    if (reply.entries.length > maxEntries) {
      return 'DirEntries has ${reply.entries.length} entries, asked for '
          'at most $maxEntries';
    }
    if (reply.hasMore && reply.entries.isEmpty) {
      return 'DirEntries is empty but says more entries follow';
    }
    var previousName = startAfter;
    for (final (index, entry) in reply.entries.indexed) {
      final isFirstFromStart = index == 0 && startAfter.isEmpty;
      if (!isFirstFromStart &&
          compareUtf8Bytes(entry.name, previousName) <= 0) {
        return 'DirEntries not sorted after "$previousName": "${entry.name}"';
      }
      previousName = entry.name;
    }
    return null;
  }

  static DownloadFailed? _outputProblem(
    String outputPath,
    bool isOverwriteAllowed,
  ) {
    switch (FileSystemEntity.typeSync(outputPath, followLinks: false)) {
      case FileSystemEntityType.notFound:
        return null;
      case FileSystemEntityType.file when isOverwriteAllowed:
        return null;
      case FileSystemEntityType.file:
        return DownloadFailed(
          DownloadFailureKind.outputExists,
          '$outputPath already exists',
        );
      default:
        return DownloadFailed(
          DownloadFailureKind.outputExists,
          '$outputPath is a folder or link, not a file',
        );
    }
  }

  static DownloadFailed _failureFor(NasRequestError error, String path) {
    final kind = switch (error.knownCode) {
      ErrorCode.notFound => DownloadFailureKind.notFound,
      ErrorCode.badPath => DownloadFailureKind.badPath,
      _ => DownloadFailureKind.serverRejected,
    };
    return DownloadFailed(
      kind,
      kind == DownloadFailureKind.notFound
          ? '$path is not on the server (or a piece of it is missing)'
          : 'server error ${error.codeName}: ${error.message}',
      errorCode: error.code,
    );
  }

  static DownloadFailed _connectionLost(NasFailure failure) => DownloadFailed(
    DownloadFailureKind.connectionLost,
    failure.message,
    connectionFailure: failure,
  );
}

/// The state of one download call.
final class _Download {
  _Download({
    required this.connection,
    required this.manifest,
    required this.outputPath,
    required this.isOverwriteAllowed,
    required this.onProgress,
    required this.cancel,
  });

  final NasConnection connection;
  final FileManifest manifest;
  final String outputPath;
  final bool isOverwriteAllowed;
  final void Function(DownloadProgress progress)? onProgress;
  final DownloadCancel? cancel;

  late final File partFile = File('$outputPath$partFileSuffix');
  RandomAccessFile? _openFile;
  int chunksDone = 0;
  int bytesDone = 0;

  bool get isCancelled => cancel?.isCancelled ?? false;

  /// Throws [NasRequestError] / [NasFailure] / [FileSystemException];
  /// the caller deletes the `.part` file and makes a [DownloadFailed].
  Future<DownloadResult> run() async {
    if (isCancelled) return DownloadCancelled(chunksDone: chunksDone);
    await partFile.parent.create(recursive: true);
    final openFile = _openFile = await partFile.open(mode: FileMode.write);
    try {
      final totalChunks = manifest.chunkHashes.length;
      for (var chunkIndex = 0; chunkIndex < totalChunks; chunkIndex++) {
        if (isCancelled) return DownloadCancelled(chunksDone: chunksDone);
        final failure = await _fetchChunk(openFile, chunkIndex);
        if (failure != null) return failure;
      }
      if (isCancelled) return DownloadCancelled(chunksDone: chunksDone);
      // flush() is fsync: the bytes are on disk before the rename.
      await openFile.flush();
    } finally {
      _openFile = null;
      await openFile.close();
    }

    final writtenSizeBytes = await partFile.length();
    if (writtenSizeBytes != manifest.sizeBytes) {
      return DownloadFailed(
        DownloadFailureKind.localWriteFailed,
        'wrote $writtenSizeBytes bytes, expected ${manifest.sizeBytes}',
      );
    }
    // Re-read from the file, so the check covers what is really stored.
    final fileSha256 = await _hashFile(partFile.path);
    if (!_sameBytes(fileSha256, manifest.fileSha256)) {
      return const DownloadFailed(
        DownloadFailureKind.fileHashMismatch,
        'the downloaded file\'s SHA-256 is not the one the server listed',
      );
    }
    try {
      await partFile.setLastModified(
        DateTime.fromMillisecondsSinceEpoch(manifest.modifiedTimeMs),
      );
    } on FileSystemException {
      // The time is a nice extra; the bytes are what matter.
    }
    // A file may have appeared at the output while we downloaded.
    final outputProblem = DownloadEngine._outputProblem(
      outputPath,
      isOverwriteAllowed,
    );
    if (outputProblem != null) return outputProblem;
    await partFile.rename(outputPath);
    // shortcut: the folder entry is not fsynced (dart:io cannot open a
    // directory); a power cut right now may lose the rename, not the data.
    return DownloadDone(
      outputPath: outputPath,
      versionId: manifest.versionId,
      sizeBytes: manifest.sizeBytes,
      modifiedTimeMs: manifest.modifiedTimeMs,
    );
  }

  /// Asks for one chunk, checks it and appends it; null when written.
  Future<DownloadFailed?> _fetchChunk(
    RandomAccessFile openFile,
    int chunkIndex,
  ) async {
    final expectedHash = manifest.chunkHashes[chunkIndex];
    final reply = await connection.request(
      ReadChunk(chunkSha256: expectedHash),
    ) as ChunkContent;
    if (!_sameBytes(reply.chunkSha256, expectedHash)) {
      return DownloadFailed(
        DownloadFailureKind.badReply,
        'ChunkContent for chunk $chunkIndex names another hash',
      );
    }
    final expectedSizeBytes = expectedChunkSizeBytes(
      manifest.sizeBytes,
      chunkIndex,
    );
    if (reply.data.length != expectedSizeBytes) {
      return DownloadFailed(
        DownloadFailureKind.chunkSizeWrong,
        'chunk $chunkIndex is ${reply.data.length} bytes, expected '
        '$expectedSizeBytes',
      );
    }
    if (!_sameBytes(await _hashBytes(reply.data), expectedHash)) {
      return DownloadFailed(
        DownloadFailureKind.chunkHashMismatch,
        'chunk $chunkIndex does not match its SHA-256',
      );
    }
    await openFile.writeFrom(reply.data);
    chunksDone++;
    bytesDone += reply.data.length;
    onProgress?.call(
      DownloadProgress(
        chunksDone: chunksDone,
        totalChunks: manifest.chunkHashes.length,
        bytesDone: bytesDone,
        sizeBytes: manifest.sizeBytes,
      ),
    );
    return null;
  }

  /// Removes the `.part` file; never throws.
  Future<void> deletePart() async {
    try {
      await _openFile?.close();
    } on FileSystemException {
      // Already closed.
    }
    _openFile = null;
    try {
      if (await partFile.exists()) await partFile.delete();
    } on FileSystemException {
      // Nothing more to do; the next download of this file truncates it.
    }
  }
}

/// SHA-256 of [data] in another isolate, so the UI isolate never hashes
/// 1 MiB.
Future<Uint8List> _hashBytes(Uint8List data) =>
    Isolate.run(() => Uint8List.fromList(sha256.convert(data).bytes));

/// SHA-256 of the file at [path], read [fileHashReadBytes] at a time in
/// another isolate.
Future<Uint8List> _hashFile(String path) => Isolate.run(() {
  final digestSink = _DigestSink();
  final hashInput = sha256.startChunkedConversion(digestSink);
  final file = File(path).openSync();
  try {
    final buffer = Uint8List(fileHashReadBytes);
    while (true) {
      final readBytes = file.readIntoSync(buffer);
      if (readBytes == 0) break;
      hashInput.add(Uint8List.sublistView(buffer, 0, readBytes));
    }
  } finally {
    file.closeSync();
  }
  hashInput.close();
  return Uint8List.fromList(digestSink.digest!.bytes);
});

final class _DigestSink implements Sink<Digest> {
  Digest? digest;

  @override
  void add(Digest data) => digest = data;

  @override
  void close() {}
}

/// Byte-wise comparison of the UTF-8 forms (spec §9 sorts names this
/// way; `String.compareTo` compares UTF-16 units, which differs above
/// U+FFFF).
int compareUtf8Bytes(String first, String second) {
  final firstBytes = utf8.encode(first);
  final secondBytes = utf8.encode(second);
  final sharedLength = firstBytes.length < secondBytes.length
      ? firstBytes.length
      : secondBytes.length;
  for (var index = 0; index < sharedLength; index++) {
    final difference = firstBytes[index] - secondBytes[index];
    if (difference != 0) return difference;
  }
  return firstBytes.length - secondBytes.length;
}

bool _sameBytes(Uint8List first, Uint8List second) =>
    const ListEquality<int>().equals(first, second);

// ── Restore to the phone ──────────────────────────────────────────────

/// Adds a restored file to the phone's gallery. Phone-only work (Android
/// MediaStore): not written yet. ⚪ Wire it to photo_manager's
/// `PhotoManager.editor.saveImageWithPath` / `saveVideo` on a real phone.
typedef AddToGallery = Future<void> Function(
  String localPath,
  String remotePath,
);

/// Where restored files go: `<documents>/restored/<device id>/<remote path>`.
/// [remotePath] passed the path rules, so it has no `..` or leading `/`.
String restorePathFor(
  Directory restoreFolder,
  int deviceId,
  String remotePath,
) => '${restoreFolder.path}/device-$deviceId/$remotePath';

/// [wantedPath], or `name (2).ext`, `name (3).ext`, … when a file is
/// already there: a restore never replaces a file.
String freeOutputPath(String wantedPath) {
  if (FileSystemEntity.typeSync(wantedPath, followLinks: false) ==
      FileSystemEntityType.notFound) {
    return wantedPath;
  }
  final slashIndex = wantedPath.lastIndexOf('/');
  final folder = wantedPath.substring(0, slashIndex + 1);
  final fileName = wantedPath.substring(slashIndex + 1);
  final dotIndex = fileName.lastIndexOf('.');
  final hasExtension = dotIndex > 0;
  final baseName = hasExtension ? fileName.substring(0, dotIndex) : fileName;
  final extension = hasExtension ? fileName.substring(dotIndex) : '';
  for (var copyNumber = 2; ; copyNumber++) {
    final candidate = '$folder$baseName ($copyNumber)$extension';
    if (FileSystemEntity.typeSync(candidate, followLinks: false) ==
        FileSystemEntityType.notFound) {
      return candidate;
    }
  }
}

/// Restores one backed-up file into [restoreFolder] (the app's documents
/// folder in the app) under a free name, then hands it to
/// [addToGallery] when given. Never replaces an existing file.
Future<DownloadResult> restoreToPhone({
  required RemoteFiles files,
  required Directory restoreFolder,
  required int deviceId,
  required String remotePath,
  int versionId = 0,
  void Function(DownloadProgress progress)? onProgress,
  DownloadCancel? cancel,
  AddToGallery? addToGallery,
}) async {
  final pathProblemText = pathProblem(remotePath);
  if (pathProblemText != null) {
    return DownloadFailed(
      DownloadFailureKind.badPath,
      'remote path not allowed: $pathProblemText',
    );
  }
  final outputPath = freeOutputPath(
    restorePathFor(restoreFolder, deviceId, remotePath),
  );
  final result = await files.download(
    deviceId: deviceId,
    remotePath: remotePath,
    versionId: versionId,
    outputPath: outputPath,
    onProgress: onProgress,
    cancel: cancel,
  );
  if (result is DownloadDone && addToGallery != null) {
    await addToGallery(result.outputPath, remotePath);
  }
  return result;
}
