// A FakeServer (fake_server.dart) that holds backed-up files and answers
// the browse and download requests of spec §9: ListDevices, ListDir
// (implied folders, byte-wise order, start_after, has_more), ReadFile and
// ReadChunk. Tests can corrupt a chunk or the file hash and watch every
// request. Author: Hao Tran.
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:haotrannas_mobile/client/download_engine.dart';
import 'package:haotrannas_mobile/core/bytes/hex.dart';
import 'package:haotrannas_mobile/protocol/error_codes.dart';
import 'package:haotrannas_mobile/protocol/limits.dart';
import 'package:haotrannas_mobile/protocol/messages.dart';

import 'fake_server.dart';

/// The device id of the phone in the fake (testHelloOk.deviceId).
const fakeCallerDeviceId = 1;

/// A second paired device, with no files.
const fakeOtherDeviceId = 2;

Uint8List sha256Of(List<int> bytes) =>
    Uint8List.fromList(sha256.convert(bytes).bytes);

/// One committed file version on the fake server.
final class StoredFile {
  StoredFile(this.content, {this.versionId = 7, this.modifiedTimeMs = 0})
    : chunkHashes = [
        for (var offset = 0; offset < content.length; offset += chunkSizeBytes)
          sha256Of(
            Uint8List.sublistView(
              content,
              offset,
              offset + chunkSizeBytes > content.length
                  ? content.length
                  : offset + chunkSizeBytes,
            ),
          ),
      ];

  final Uint8List content;
  final int versionId;
  final int modifiedTimeMs;
  final List<Uint8List> chunkHashes;
}

class FakeDownloadServer {
  FakeDownloadServer() {
    server.answer = _answer;
  }

  final server = FakeServer();

  /// Backed-up files of [fakeCallerDeviceId], by path.
  final files = <String, StoredFile>{};

  /// When set, ChunkContent for this chunk index has one byte flipped
  /// (same hash field, wrong bytes).
  int? corruptChunkIndex;

  /// When set, ChunkContent for this chunk index is one byte short.
  int? shortChunkIndex;

  /// When true, FileManifest lists a wrong `file_sha256`.
  bool isFileHashWrong = false;

  /// Called on each ReadChunk before the answer, with the chunk's index.
  void Function(int chunkIndex)? onReadChunk;

  /// Every ListDir the phone sent.
  final listDirRequests = <ListDir>[];

  StoredFile addFile(String path, Uint8List content, {int versionId = 7}) =>
      files[path] = StoredFile(
        content,
        versionId: versionId,
        modifiedTimeMs: 1763450000000,
      );

  Message? _answer(Message request) => switch (request) {
    ListDevices() => const DeviceList(
      devices: [
        DeviceEntry(
          deviceId: fakeCallerDeviceId,
          name: 'test phone',
          pairedAtMs: 1763400000000,
          isCaller: true,
        ),
        DeviceEntry(
          deviceId: fakeOtherDeviceId,
          name: 'laptop',
          pairedAtMs: 1763400000001,
          isCaller: false,
        ),
      ],
    ),
    ListDir() => _listDir(request),
    ReadFile() => _readFile(request),
    ReadChunk() => _readChunk(request),
    _ => FakeServer.defaultAnswer(request),
  };

  static ErrorMessage notFound(String text) =>
      ErrorMessage(code: ErrorCode.notFound.number, message: text);

  bool _isKnownDevice(int deviceId) =>
      deviceId == 0 ||
      deviceId == fakeCallerDeviceId ||
      deviceId == fakeOtherDeviceId;

  Message _listDir(ListDir request) {
    listDirRequests.add(request);
    if (!_isKnownDevice(request.deviceId)) return notFound('no such device');
    final ownFiles = request.deviceId == fakeOtherDeviceId
        ? const <String, StoredFile>{}
        : files;
    final prefix = request.path.isEmpty ? '' : '${request.path}/';
    final children = <String, DirEntry>{};
    for (final MapEntry(key: path, value: file) in ownFiles.entries) {
      if (!path.startsWith(prefix)) continue;
      final rest = path.substring(prefix.length);
      final slashIndex = rest.indexOf('/');
      if (slashIndex >= 0) {
        final name = rest.substring(0, slashIndex);
        children[name] = DirEntry(
          name: name,
          kind: DirEntryKind.directory,
          sizeBytes: 0,
          modifiedTimeMs: 0,
          versionId: 0,
        );
      } else if (children[rest]?.kind != DirEntryKind.directory) {
        children[rest] = DirEntry(
          name: rest,
          kind: DirEntryKind.file,
          sizeBytes: file.content.length,
          modifiedTimeMs: file.modifiedTimeMs,
          versionId: file.versionId,
        );
      }
    }
    if (request.path.isNotEmpty && children.isEmpty) {
      return notFound('no such folder');
    }
    final sortedNames = children.keys.toList()..sort(compareUtf8Bytes);
    final namesAfter = [
      for (final name in sortedNames)
        if (request.startAfter.isEmpty ||
            compareUtf8Bytes(name, request.startAfter) > 0)
          name,
    ];
    final pageNames = namesAfter.take(request.maxEntries).toList();
    return DirEntries(
      entries: [for (final name in pageNames) children[name]!],
      hasMore: namesAfter.length > pageNames.length,
    );
  }

  Message _readFile(ReadFile request) {
    final file = files[request.path];
    if (!_isKnownDevice(request.deviceId) ||
        file == null ||
        (request.versionId != 0 && request.versionId != file.versionId)) {
      return notFound('no such file or version');
    }
    final fileSha256 = sha256Of(file.content);
    if (isFileHashWrong) fileSha256[0] ^= 0xFF;
    return FileManifest(
      versionId: file.versionId,
      sizeBytes: file.content.length,
      modifiedTimeMs: file.modifiedTimeMs,
      fileSha256: fileSha256,
      chunkHashes: file.chunkHashes,
    );
  }

  Message _readChunk(ReadChunk request) {
    final wantedHex = toHex(request.chunkSha256, separator: '');
    for (final file in files.values) {
      for (final (chunkIndex, hash) in file.chunkHashes.indexed) {
        if (toHex(hash, separator: '') != wantedHex) continue;
        onReadChunk?.call(chunkIndex);
        final start = chunkIndex * chunkSizeBytes;
        final end = start + chunkSizeBytes > file.content.length
            ? file.content.length
            : start + chunkSizeBytes;
        var data = Uint8List.fromList(file.content.sublist(start, end));
        if (chunkIndex == corruptChunkIndex) data[0] ^= 0xFF;
        if (chunkIndex == shortChunkIndex) {
          data = Uint8List.sublistView(data, 0, data.length - 1);
        }
        return ChunkContent(chunkSha256: request.chunkSha256, data: data);
      }
    }
    return notFound('no such chunk');
  }
}
