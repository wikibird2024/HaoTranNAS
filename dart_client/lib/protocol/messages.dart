/// One Dart class per protocol message (spec §5) and the u16 message
/// type numbers.
///
/// Plain immutable data with value equality (byte lists compared by
/// content). `protocol/spec.md` in the repo root is the contract; field
/// names are the spec's names in lowerCamelCase.
///
/// The spec's `Error` message is [ErrorMessage] here, so it does not
/// hide `dart:core`'s `Error` in every file that imports this one.
library;

import 'dart:typed_data';

import 'package:collection/collection.dart';

import '../core/bytes/hex.dart';
import 'error_codes.dart';

/// The u16 `message_type` numbers, spec §5.
abstract final class MessageType {
  static const hello = 0x0001;
  static const helloOk = 0x0002;
  static const ping = 0x0003;
  static const pong = 0x0004;
  static const pairRequest = 0x0101;
  static const pairOk = 0x0102;
  static const fileOffer = 0x0201;
  static const needChunks = 0x0202;
  static const chunkData = 0x0203;
  static const chunkOk = 0x0204;
  static const commit = 0x0205;
  static const commitOk = 0x0206;
  static const listDevices = 0x0301;
  static const deviceList = 0x0302;
  static const listDir = 0x0303;
  static const dirEntries = 0x0304;
  static const readFile = 0x0401;
  static const fileManifest = 0x0402;
  static const readChunk = 0x0403;
  static const chunkContent = 0x0404;
  static const putThumbnail = 0x0501;
  static const thumbnailOk = 0x0502;
  static const readThumbnail = 0x0503;
  static const thumbnail = 0x0504;
  static const close = 0x00f0;
  static const error = 0x00ff;

  /// Every type in spec §5.
  static const all = [
    hello,
    helloOk,
    ping,
    pong,
    pairRequest,
    pairOk,
    fileOffer,
    needChunks,
    chunkData,
    chunkOk,
    commit,
    commitOk,
    listDevices,
    deviceList,
    listDir,
    dirEntries,
    readFile,
    fileManifest,
    readChunk,
    chunkContent,
    putThumbnail,
    thumbnailOk,
    readThumbnail,
    thumbnail,
    close,
    error,
  ];
}

const _deepEquality = DeepCollectionEquality();

/// Text for a field value in `toString()`: short byte lists as hex,
/// long ones and long lists by size only.
String _describe(Object? value) {
  if (value is Uint8List) {
    return value.length <= 32
        ? toHex(value, separator: '')
        : '<${value.length} bytes>';
  }
  if (value is String) return '"$value"';
  if (value is List) {
    return value.length <= 4
        ? '[${value.map(_describe).join(', ')}]'
        : '<${value.length} items>';
  }
  if (value is DirEntryKind) return value.name;
  return '$value';
}

/// A decoded or to-be-encoded protocol message.
sealed class Message {
  const Message();

  /// The u16 type number on the wire.
  int get messageType;

  /// The spec's message name, e.g. `HelloOk` (also after code
  /// obfuscation, unlike `runtimeType`).
  String get messageName;

  /// Field names and values in wire order: used for equality and
  /// `toString()`.
  Map<String, Object?> get _fields;

  /// What `toString()` prints; [PairOk] hides its key here.
  Map<String, Object?> get _printedFields => _fields;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is Message &&
          other.messageType == messageType &&
          _deepEquality.equals(
            _fields.values.toList(),
            other._fields.values.toList(),
          );

  @override
  int get hashCode =>
      Object.hash(messageType, _deepEquality.hash(_fields.values.toList()));

  @override
  String toString() {
    final fieldText = _printedFields.entries
        .map((field) => '${field.key}: ${_describe(field.value)}')
        .join(', ');
    return '$messageName($fieldText)';
  }
}

// ── Handshake ─────────────────────────────────────────────────────────

final class Hello extends Message {
  const Hello({
    required this.protocolVersion,
    required this.clientSoftware,
    required this.deviceName,
  });

  final int protocolVersion;
  final String clientSoftware;
  final String deviceName;

  @override
  int get messageType => MessageType.hello;
  @override
  String get messageName => 'Hello';
  @override
  Map<String, Object?> get _fields => {
    'protocolVersion': protocolVersion,
    'clientSoftware': clientSoftware,
    'deviceName': deviceName,
  };
}

final class HelloOk extends Message {
  const HelloOk({
    required this.protocolVersion,
    required this.serverSoftware,
    required this.serverName,
    required this.deviceId,
    required this.chunkSizeBytes,
    required this.maxFrameLengthBytes,
  });

  final int protocolVersion;
  final String serverSoftware;
  final String serverName;

  /// 0 = not paired on this connection.
  final int deviceId;
  final int chunkSizeBytes;
  final int maxFrameLengthBytes;

  @override
  int get messageType => MessageType.helloOk;
  @override
  String get messageName => 'HelloOk';
  @override
  Map<String, Object?> get _fields => {
    'protocolVersion': protocolVersion,
    'serverSoftware': serverSoftware,
    'serverName': serverName,
    'deviceId': deviceId,
    'chunkSizeBytes': chunkSizeBytes,
    'maxFrameLengthBytes': maxFrameLengthBytes,
  };
}

final class Ping extends Message {
  const Ping();

  @override
  int get messageType => MessageType.ping;
  @override
  String get messageName => 'Ping';
  @override
  Map<String, Object?> get _fields => const {};
}

final class Pong extends Message {
  const Pong();

  @override
  int get messageType => MessageType.pong;
  @override
  String get messageName => 'Pong';
  @override
  Map<String, Object?> get _fields => const {};
}

// ── Pairing ───────────────────────────────────────────────────────────

final class PairRequest extends Message {
  const PairRequest({required this.code});

  final String code;

  @override
  int get messageType => MessageType.pairRequest;
  @override
  String get messageName => 'PairRequest';
  @override
  Map<String, Object?> get _fields => {'code': code};
}

/// Carries the device's private key: `toString()` never prints it
/// (spec §7, Logging).
final class PairOk extends Message {
  const PairOk({
    required this.deviceId,
    required this.deviceCertDer,
    required this.deviceKeyPkcs8Der,
    required this.serverCertSha256,
  });

  final int deviceId;
  final Uint8List deviceCertDer;

  /// Secret. Never log it.
  final Uint8List deviceKeyPkcs8Der;
  final Uint8List serverCertSha256;

  @override
  int get messageType => MessageType.pairOk;
  @override
  String get messageName => 'PairOk';
  @override
  Map<String, Object?> get _fields => {
    'deviceId': deviceId,
    'deviceCertDer': deviceCertDer,
    'deviceKeyPkcs8Der': deviceKeyPkcs8Der,
    'serverCertSha256': serverCertSha256,
  };
  @override
  Map<String, Object?> get _printedFields => {
    'deviceId': deviceId,
    'deviceCertDer': '<${deviceCertDer.length} bytes>',
    'deviceKeyPkcs8Der': const _Redacted(),
    'serverCertSha256': serverCertSha256,
  };
}

final class _Redacted {
  const _Redacted();

  @override
  String toString() => '<key redacted>';
}

// ── Upload ────────────────────────────────────────────────────────────

final class FileOffer extends Message {
  const FileOffer({
    required this.path,
    required this.sizeBytes,
    required this.modifiedTimeMs,
    required this.fileSha256,
    required this.chunkHashes,
  });

  final String path;
  final int sizeBytes;
  final int modifiedTimeMs;
  final Uint8List fileSha256;
  final List<Uint8List> chunkHashes;

  @override
  int get messageType => MessageType.fileOffer;
  @override
  String get messageName => 'FileOffer';
  @override
  Map<String, Object?> get _fields => {
    'path': path,
    'sizeBytes': sizeBytes,
    'modifiedTimeMs': modifiedTimeMs,
    'fileSha256': fileSha256,
    'chunkHashes': chunkHashes,
  };
}

final class NeedChunks extends Message {
  const NeedChunks({
    required this.uploadId,
    required this.existingVersionId,
    required this.missingIndexes,
  });

  final int uploadId;

  /// Not 0 = this file is already backed up as that version.
  final int existingVersionId;
  final List<int> missingIndexes;

  @override
  int get messageType => MessageType.needChunks;
  @override
  String get messageName => 'NeedChunks';
  @override
  Map<String, Object?> get _fields => {
    'uploadId': uploadId,
    'existingVersionId': existingVersionId,
    'missingIndexes': missingIndexes,
  };
}

final class ChunkData extends Message {
  const ChunkData({
    required this.uploadId,
    required this.chunkIndex,
    required this.chunkSha256,
    required this.data,
  });

  final int uploadId;
  final int chunkIndex;
  final Uint8List chunkSha256;
  final Uint8List data;

  @override
  int get messageType => MessageType.chunkData;
  @override
  String get messageName => 'ChunkData';
  @override
  Map<String, Object?> get _fields => {
    'uploadId': uploadId,
    'chunkIndex': chunkIndex,
    'chunkSha256': chunkSha256,
    'data': data,
  };
}

final class ChunkOk extends Message {
  const ChunkOk({required this.chunkIndex, required this.chunkSha256});

  final int chunkIndex;
  final Uint8List chunkSha256;

  @override
  int get messageType => MessageType.chunkOk;
  @override
  String get messageName => 'ChunkOk';
  @override
  Map<String, Object?> get _fields => {
    'chunkIndex': chunkIndex,
    'chunkSha256': chunkSha256,
  };
}

final class Commit extends Message {
  const Commit({required this.uploadId});

  final int uploadId;

  @override
  int get messageType => MessageType.commit;
  @override
  String get messageName => 'Commit';
  @override
  Map<String, Object?> get _fields => {'uploadId': uploadId};
}

final class CommitOk extends Message {
  const CommitOk({required this.versionId});

  final int versionId;

  @override
  int get messageType => MessageType.commitOk;
  @override
  String get messageName => 'CommitOk';
  @override
  Map<String, Object?> get _fields => {'versionId': versionId};
}

// ── Browse ────────────────────────────────────────────────────────────

final class ListDevices extends Message {
  const ListDevices();

  @override
  int get messageType => MessageType.listDevices;
  @override
  String get messageName => 'ListDevices';
  @override
  Map<String, Object?> get _fields => const {};
}

/// One paired device in [DeviceList].
final class DeviceEntry {
  const DeviceEntry({
    required this.deviceId,
    required this.name,
    required this.pairedAtMs,
    required this.isCaller,
  });

  final int deviceId;
  final String name;
  final int pairedAtMs;

  /// This entry is the device that asked.
  final bool isCaller;

  @override
  bool operator ==(Object other) =>
      other is DeviceEntry &&
      other.deviceId == deviceId &&
      other.name == name &&
      other.pairedAtMs == pairedAtMs &&
      other.isCaller == isCaller;

  @override
  int get hashCode => Object.hash(deviceId, name, pairedAtMs, isCaller);

  @override
  String toString() =>
      'DeviceEntry(deviceId: $deviceId, name: "$name", '
      'pairedAtMs: $pairedAtMs, isCaller: $isCaller)';
}

final class DeviceList extends Message {
  const DeviceList({required this.devices});

  final List<DeviceEntry> devices;

  @override
  int get messageType => MessageType.deviceList;
  @override
  String get messageName => 'DeviceList';
  @override
  Map<String, Object?> get _fields => {'devices': devices};
}

final class ListDir extends Message {
  const ListDir({
    required this.deviceId,
    required this.path,
    required this.startAfter,
    required this.maxEntries,
  });

  /// 0 = the asking device.
  final int deviceId;

  /// "" = root.
  final String path;

  /// "" = from the start.
  final String startAfter;
  final int maxEntries;

  @override
  int get messageType => MessageType.listDir;
  @override
  String get messageName => 'ListDir';
  @override
  Map<String, Object?> get _fields => {
    'deviceId': deviceId,
    'path': path,
    'startAfter': startAfter,
    'maxEntries': maxEntries,
  };
}

/// `DirEntry.kind` on the wire; other values are malformed.
enum DirEntryKind {
  directory(1),
  file(2);

  const DirEntryKind(this.number);

  /// The u8 sent on the wire.
  final int number;

  /// The kind for [number], or null if it is not 1 or 2.
  static DirEntryKind? fromNumber(int number) => switch (number) {
    1 => directory,
    2 => file,
    _ => null,
  };
}

/// One child in [DirEntries]. A directory has size, time and version 0.
final class DirEntry {
  const DirEntry({
    required this.name,
    required this.kind,
    required this.sizeBytes,
    required this.modifiedTimeMs,
    required this.versionId,
  });

  final String name;
  final DirEntryKind kind;
  final int sizeBytes;
  final int modifiedTimeMs;
  final int versionId;

  @override
  bool operator ==(Object other) =>
      other is DirEntry &&
      other.name == name &&
      other.kind == kind &&
      other.sizeBytes == sizeBytes &&
      other.modifiedTimeMs == modifiedTimeMs &&
      other.versionId == versionId;

  @override
  int get hashCode =>
      Object.hash(name, kind, sizeBytes, modifiedTimeMs, versionId);

  @override
  String toString() =>
      'DirEntry(name: "$name", kind: ${kind.name}, sizeBytes: $sizeBytes, '
      'modifiedTimeMs: $modifiedTimeMs, versionId: $versionId)';
}

final class DirEntries extends Message {
  const DirEntries({required this.entries, required this.hasMore});

  final List<DirEntry> entries;
  final bool hasMore;

  @override
  int get messageType => MessageType.dirEntries;
  @override
  String get messageName => 'DirEntries';
  @override
  Map<String, Object?> get _fields => {'entries': entries, 'hasMore': hasMore};
}

// ── Download ──────────────────────────────────────────────────────────

final class ReadFile extends Message {
  const ReadFile({
    required this.deviceId,
    required this.path,
    required this.versionId,
  });

  /// 0 = the asking device.
  final int deviceId;
  final String path;

  /// 0 = latest.
  final int versionId;

  @override
  int get messageType => MessageType.readFile;
  @override
  String get messageName => 'ReadFile';
  @override
  Map<String, Object?> get _fields => {
    'deviceId': deviceId,
    'path': path,
    'versionId': versionId,
  };
}

final class FileManifest extends Message {
  const FileManifest({
    required this.versionId,
    required this.sizeBytes,
    required this.modifiedTimeMs,
    required this.fileSha256,
    required this.chunkHashes,
  });

  final int versionId;
  final int sizeBytes;
  final int modifiedTimeMs;
  final Uint8List fileSha256;
  final List<Uint8List> chunkHashes;

  @override
  int get messageType => MessageType.fileManifest;
  @override
  String get messageName => 'FileManifest';
  @override
  Map<String, Object?> get _fields => {
    'versionId': versionId,
    'sizeBytes': sizeBytes,
    'modifiedTimeMs': modifiedTimeMs,
    'fileSha256': fileSha256,
    'chunkHashes': chunkHashes,
  };
}

final class ReadChunk extends Message {
  const ReadChunk({required this.chunkSha256});

  final Uint8List chunkSha256;

  @override
  int get messageType => MessageType.readChunk;
  @override
  String get messageName => 'ReadChunk';
  @override
  Map<String, Object?> get _fields => {'chunkSha256': chunkSha256};
}

final class ChunkContent extends Message {
  const ChunkContent({required this.chunkSha256, required this.data});

  final Uint8List chunkSha256;
  final Uint8List data;

  @override
  int get messageType => MessageType.chunkContent;
  @override
  String get messageName => 'ChunkContent';
  @override
  Map<String, Object?> get _fields => {
    'chunkSha256': chunkSha256,
    'data': data,
  };
}

// ── Thumbnails (version 2, spec §16) ───────────────────────────────────

/// A small JPEG for a file this device has backed up.
final class PutThumbnail extends Message {
  const PutThumbnail({required this.fileSha256, required this.jpegData});

  /// The backed-up file's SHA-256.
  final Uint8List fileSha256;

  /// At most `maxThumbnailBytes` (spec §16).
  final Uint8List jpegData;

  @override
  int get messageType => MessageType.putThumbnail;
  @override
  String get messageName => 'PutThumbnail';
  @override
  Map<String, Object?> get _fields => {
    'fileSha256': fileSha256,
    'jpegData': jpegData,
  };
}

final class ThumbnailOk extends Message {
  const ThumbnailOk();

  @override
  int get messageType => MessageType.thumbnailOk;
  @override
  String get messageName => 'ThumbnailOk';
  @override
  Map<String, Object?> get _fields => const {};
}

final class ReadThumbnail extends Message {
  const ReadThumbnail({
    required this.deviceId,
    required this.path,
    required this.versionId,
  });

  /// 0 = the asking device.
  final int deviceId;
  final String path;

  /// 0 = latest.
  final int versionId;

  @override
  int get messageType => MessageType.readThumbnail;
  @override
  String get messageName => 'ReadThumbnail';
  @override
  Map<String, Object?> get _fields => {
    'deviceId': deviceId,
    'path': path,
    'versionId': versionId,
  };
}

final class Thumbnail extends Message {
  const Thumbnail({required this.jpegData});

  final Uint8List jpegData;

  @override
  int get messageType => MessageType.thumbnail;
  @override
  String get messageName => 'Thumbnail';
  @override
  Map<String, Object?> get _fields => {'jpegData': jpegData};
}

// ── Connection ────────────────────────────────────────────────────────

final class Close extends Message {
  const Close({required this.reason, required this.message});

  /// Raw number: an unknown reason is kept, not an error.
  final int reason;
  final String message;

  /// The known reason, or null for a number this app does not know.
  CloseReason? get knownReason => CloseReason.fromNumber(reason);

  /// `IDLE_TIMEOUT`, or `UNKNOWN(<n>)`.
  String get reasonName => closeReasonName(reason);

  @override
  int get messageType => MessageType.close;
  @override
  String get messageName => 'Close';
  @override
  Map<String, Object?> get _fields => {'reason': reason, 'message': message};
  @override
  Map<String, Object?> get _printedFields => {
    'reason': _Named(reasonName),
    'message': message,
  };
}

/// The spec's `Error` message (type 0x00FF).
final class ErrorMessage extends Message {
  const ErrorMessage({required this.code, required this.message});

  /// Raw number: an unknown code is kept, not an error.
  final int code;
  final String message;

  /// The known code, or null for a number this app does not know.
  ErrorCode? get knownCode => ErrorCode.fromNumber(code);

  /// `NOT_FOUND`, or `UNKNOWN(<n>)`.
  String get codeName => errorCodeName(code);

  @override
  int get messageType => MessageType.error;
  @override
  String get messageName => 'Error';
  @override
  Map<String, Object?> get _fields => {'code': code, 'message': message};
  @override
  Map<String, Object?> get _printedFields => {
    'code': _Named(codeName),
    'message': message,
  };
}

/// Prints a name without quotes in `toString()`.
final class _Named {
  const _Named(this.name);

  final String name;

  @override
  String toString() => name;
}
