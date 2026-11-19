// Loads protocol/vectors/*.json and turns vector fields into messages.
// Shared by the protocol tests; not a test file itself.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:haotrannas_client/core/bytes/hex.dart';
import 'package:haotrannas_client/protocol/messages.dart';

/// `protocol/vectors/`, found by walking up from the current directory
/// (`flutter test` runs in `mobile/`, an IDE may run elsewhere).
Directory findVectorsDirectory() {
  var directory = Directory.current.absolute;
  while (true) {
    final candidate = Directory(
      '${directory.path}${Platform.pathSeparator}protocol'
      '${Platform.pathSeparator}vectors',
    );
    if (candidate.existsSync()) return candidate;
    final parent = directory.parent;
    if (parent.path == directory.path) {
      throw StateError('protocol/vectors not found above ${Directory.current}');
    }
    directory = parent;
  }
}

Map<String, dynamic> loadVectorFile(String fileName) {
  final file = File(
    '${findVectorsDirectory().path}${Platform.pathSeparator}$fileName',
  );
  return jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
}

/// The vector's `frame_hex` segments joined into bytes.
Uint8List frameBytesOf(Map<String, dynamic> vector) =>
    parseHex((vector['frame_hex'] as List).join());

/// Builds the message a valid vector describes, from its JSON fields
/// (spec §15: u64/i64 are decimal strings, bytes/hash are hex).
Message messageFromVector(Map<String, dynamic> vector) {
  final fields = vector['fields'] as Map<String, dynamic>;
  int number(String name) => fields[name] as int;
  int bigNumber(String name) => int.parse(fields[name] as String);
  String text(String name) => fields[name] as String;
  Uint8List bytes(String name) => parseHex(fields[name] as String);
  List<Uint8List> hashList(String name) => [
    for (final hash in fields[name] as List) parseHex(hash as String),
  ];

  switch (vector['message'] as String) {
    case 'Hello':
      return Hello(
        protocolVersion: number('protocol_version'),
        clientSoftware: text('client_software'),
        deviceName: text('device_name'),
      );
    case 'HelloOk':
      return HelloOk(
        protocolVersion: number('protocol_version'),
        serverSoftware: text('server_software'),
        serverName: text('server_name'),
        deviceId: bigNumber('device_id'),
        chunkSizeBytes: number('chunk_size_bytes'),
        maxFrameLengthBytes: number('max_frame_length_bytes'),
      );
    case 'Ping':
      return const Ping();
    case 'Pong':
      return const Pong();
    case 'PairRequest':
      return PairRequest(code: text('code'));
    case 'PairOk':
      return PairOk(
        deviceId: bigNumber('device_id'),
        deviceCertDer: bytes('device_cert_der'),
        deviceKeyPkcs8Der: bytes('device_key_pkcs8_der'),
        serverCertSha256: bytes('server_cert_sha256'),
      );
    case 'FileOffer':
      return FileOffer(
        path: text('path'),
        sizeBytes: bigNumber('size_bytes'),
        modifiedTimeMs: bigNumber('modified_time_ms'),
        fileSha256: bytes('file_sha256'),
        chunkHashes: hashList('chunk_hashes'),
      );
    case 'NeedChunks':
      return NeedChunks(
        uploadId: bigNumber('upload_id'),
        existingVersionId: bigNumber('existing_version_id'),
        missingIndexes: [
          for (final index in fields['missing_indexes'] as List) index as int,
        ],
      );
    case 'ChunkData':
      return ChunkData(
        uploadId: bigNumber('upload_id'),
        chunkIndex: number('chunk_index'),
        chunkSha256: bytes('chunk_sha256'),
        data: bytes('data'),
      );
    case 'ChunkOk':
      return ChunkOk(
        chunkIndex: number('chunk_index'),
        chunkSha256: bytes('chunk_sha256'),
      );
    case 'Commit':
      return Commit(uploadId: bigNumber('upload_id'));
    case 'CommitOk':
      return CommitOk(versionId: bigNumber('version_id'));
    case 'ListDevices':
      return const ListDevices();
    case 'DeviceList':
      return DeviceList(
        devices: [
          for (final item in fields['devices'] as List)
            DeviceEntry(
              deviceId: int.parse(item['device_id'] as String),
              name: item['name'] as String,
              pairedAtMs: int.parse(item['paired_at_ms'] as String),
              isCaller: item['is_caller'] as bool,
            ),
        ],
      );
    case 'ListDir':
      return ListDir(
        deviceId: bigNumber('device_id'),
        path: text('path'),
        startAfter: text('start_after'),
        maxEntries: number('max_entries'),
      );
    case 'DirEntries':
      return DirEntries(
        entries: [
          for (final item in fields['entries'] as List)
            DirEntry(
              name: item['name'] as String,
              kind: DirEntryKind.fromNumber(item['kind'] as int)!,
              sizeBytes: int.parse(item['size_bytes'] as String),
              modifiedTimeMs: int.parse(item['modified_time_ms'] as String),
              versionId: int.parse(item['version_id'] as String),
            ),
        ],
        hasMore: fields['has_more'] as bool,
      );
    case 'ReadFile':
      return ReadFile(
        deviceId: bigNumber('device_id'),
        path: text('path'),
        versionId: bigNumber('version_id'),
      );
    case 'FileManifest':
      return FileManifest(
        versionId: bigNumber('version_id'),
        sizeBytes: bigNumber('size_bytes'),
        modifiedTimeMs: bigNumber('modified_time_ms'),
        fileSha256: bytes('file_sha256'),
        chunkHashes: hashList('chunk_hashes'),
      );
    case 'ReadChunk':
      return ReadChunk(chunkSha256: bytes('chunk_sha256'));
    case 'ChunkContent':
      return ChunkContent(
        chunkSha256: bytes('chunk_sha256'),
        data: bytes('data'),
      );
    case 'Close':
      return Close(reason: number('reason'), message: text('message'));
    case 'Error':
      return ErrorMessage(code: number('code'), message: text('message'));
    default:
      throw ArgumentError('unknown message ${vector['message']}');
  }
}
