/// Turns payloads into messages and messages into frames (spec §3–§5),
/// using `wire_reader.dart` and `wire_writer.dart`.
///
/// Pure: no I/O. [decodeMessage] never throws on bad bytes: it returns
/// [DecodeBad] with a reason, which the connection reports as
/// `MALFORMED_FRAME`. [encodeFrame] throws [ArgumentError] only for a
/// message that cannot be valid on the wire (a caller bug).
library;

import 'dart:typed_data';

import 'limits.dart';
import 'messages.dart';
import 'wire_reader.dart';
import 'wire_writer.dart';

/// What [decodeMessage] returns.
sealed class DecodeResult {
  const DecodeResult();
}

final class DecodeOk extends DecodeResult {
  const DecodeOk(this.message);

  final Message message;

  @override
  String toString() => 'DecodeOk($message)';
}

/// The payload is malformed (spec: `MALFORMED_FRAME`).
final class DecodeBad extends DecodeResult {
  const DecodeBad(this.reason);

  final String reason;

  @override
  String toString() => 'DecodeBad($reason)';
}

// Smallest wire size of one list item, for the count check (spec §3).
const _deviceEntryMinBytes = 8 + 2 + 8 + 1;
const _dirEntryMinBytes = 2 + 1 + 8 + 8 + 8;
const _u32Bytes = 4;

/// A whole frame for [message]: header (length, type, [requestId]) and
/// payload.
///
/// Throws [ArgumentError] if a field does not fit its wire type or limit,
/// [requestId] is not a u32, or the frame would be longer than
/// `maxFrameLengthBytes`.
Uint8List encodeFrame(Message message, int requestId) {
  final payload = encodePayload(message);
  final lengthBytes = minFrameLengthBytes + payload.length;
  if (lengthBytes > maxFrameLengthBytes) {
    throw ArgumentError.value(
      lengthBytes,
      'lengthBytes',
      '${message.messageName} frame is over $maxFrameLengthBytes bytes',
    );
  }
  final header = WireWriter()
    ..writeU32(lengthBytes, 'length_bytes')
    ..writeU16(message.messageType, 'message_type')
    ..writeU32(requestId, 'request_id');
  return (BytesBuilder(copy: false)
        ..add(header.toBytes())
        ..add(payload))
      .toBytes();
}

/// The payload bytes of [message], without the frame header.
/// Throws [ArgumentError] like [encodeFrame].
Uint8List encodePayload(Message message) {
  final writer = WireWriter();
  switch (message) {
    case Hello():
      writer
        ..writeU16(message.protocolVersion, 'protocol_version')
        ..writeString(
          message.clientSoftware,
          'client_software',
          maxBytes: maxNameBytes,
        )
        ..writeString(
          message.deviceName,
          'device_name',
          maxBytes: maxNameBytes,
        );
    case HelloOk():
      writer
        ..writeU16(message.protocolVersion, 'protocol_version')
        ..writeString(
          message.serverSoftware,
          'server_software',
          maxBytes: maxNameBytes,
        )
        ..writeString(message.serverName, 'server_name', maxBytes: maxNameBytes)
        ..writeU64(message.deviceId, 'device_id')
        ..writeU32(message.chunkSizeBytes, 'chunk_size_bytes')
        ..writeU32(message.maxFrameLengthBytes, 'max_frame_length_bytes');
    case Ping() || Pong() || ListDevices() || ThumbnailOk():
      break;
    case PairRequest():
      writer.writeString(message.code, 'code', maxBytes: maxNameBytes);
    case PairOk():
      writer
        ..writeU64(message.deviceId, 'device_id')
        ..writeBytes(message.deviceCertDer, 'device_cert_der')
        ..writeBytes(message.deviceKeyPkcs8Der, 'device_key_pkcs8_der')
        ..writeHash(message.serverCertSha256, 'server_cert_sha256');
    case FileOffer():
      writer
        ..writeString(message.path, 'path', maxBytes: maxPathBytes)
        ..writeU64(message.sizeBytes, 'size_bytes')
        ..writeI64(message.modifiedTimeMs, 'modified_time_ms')
        ..writeHash(message.fileSha256, 'file_sha256');
      _writeHashList(writer, message.chunkHashes, 'chunk_hashes');
    case NeedChunks():
      writer
        ..writeU64(message.uploadId, 'upload_id')
        ..writeU64(message.existingVersionId, 'existing_version_id')
        ..writeListCount(message.missingIndexes.length, 'missing_indexes');
      for (final index in message.missingIndexes) {
        writer.writeU32(index, 'missing_indexes item');
      }
    case ChunkData():
      writer
        ..writeU64(message.uploadId, 'upload_id')
        ..writeU32(message.chunkIndex, 'chunk_index')
        ..writeHash(message.chunkSha256, 'chunk_sha256')
        ..writeBytes(message.data, 'data');
    case ChunkOk():
      writer
        ..writeU32(message.chunkIndex, 'chunk_index')
        ..writeHash(message.chunkSha256, 'chunk_sha256');
    case Commit():
      writer.writeU64(message.uploadId, 'upload_id');
    case CommitOk():
      writer.writeU64(message.versionId, 'version_id');
    case DeviceList():
      writer.writeListCount(message.devices.length, 'devices');
      for (final device in message.devices) {
        writer
          ..writeU64(device.deviceId, 'device_id')
          ..writeString(device.name, 'name', maxBytes: maxNameBytes)
          ..writeI64(device.pairedAtMs, 'paired_at_ms')
          ..writeBool(device.isCaller);
      }
    case ListDir():
      writer
        ..writeU64(message.deviceId, 'device_id')
        ..writeString(message.path, 'path', maxBytes: maxPathBytes)
        ..writeString(message.startAfter, 'start_after', maxBytes: maxPathBytes)
        ..writeU32(message.maxEntries, 'max_entries');
    case DirEntries():
      writer.writeListCount(message.entries.length, 'entries');
      for (final entry in message.entries) {
        writer
          ..writeString(entry.name, 'name', maxBytes: maxPathBytes)
          ..writeU8(entry.kind.number, 'kind')
          ..writeU64(entry.sizeBytes, 'size_bytes')
          ..writeI64(entry.modifiedTimeMs, 'modified_time_ms')
          ..writeU64(entry.versionId, 'version_id');
      }
      writer.writeBool(message.hasMore);
    case ReadFile():
      writer
        ..writeU64(message.deviceId, 'device_id')
        ..writeString(message.path, 'path', maxBytes: maxPathBytes)
        ..writeU64(message.versionId, 'version_id');
    case FileManifest():
      writer
        ..writeU64(message.versionId, 'version_id')
        ..writeU64(message.sizeBytes, 'size_bytes')
        ..writeI64(message.modifiedTimeMs, 'modified_time_ms')
        ..writeHash(message.fileSha256, 'file_sha256');
      _writeHashList(writer, message.chunkHashes, 'chunk_hashes');
    case ReadChunk():
      writer.writeHash(message.chunkSha256, 'chunk_sha256');
    case ChunkContent():
      writer
        ..writeHash(message.chunkSha256, 'chunk_sha256')
        ..writeBytes(message.data, 'data');
    case PutThumbnail():
      writer
        ..writeHash(message.fileSha256, 'file_sha256')
        ..writeBytes(message.jpegData, 'jpeg_data');
    case ReadThumbnail():
      writer
        ..writeU64(message.deviceId, 'device_id')
        ..writeString(message.path, 'path', maxBytes: maxPathBytes)
        ..writeU64(message.versionId, 'version_id');
    case Thumbnail():
      writer.writeBytes(message.jpegData, 'jpeg_data');
    case Close():
      writer
        ..writeU16(message.reason, 'reason')
        ..writeString(message.message, 'message', maxBytes: maxMessageBytes);
    case ErrorMessage():
      writer
        ..writeU16(message.code, 'code')
        ..writeString(message.message, 'message', maxBytes: maxMessageBytes);
  }
  return writer.toBytes();
}

void _writeHashList(WireWriter writer, List<Uint8List> hashes, String field) {
  writer.writeListCount(hashes.length, field);
  for (final hash in hashes) {
    writer.writeHash(hash, '$field item');
  }
}

/// Decodes one frame's payload as [messageType]. Never throws: an unknown
/// or zero type, a short or long payload, a bad value or a string over
/// its limit gives [DecodeBad].
DecodeResult decodeMessage(int messageType, Uint8List payload) {
  final reader = WireReader(payload);
  final message = _decodeFields(messageType, reader);
  if (message == null) {
    return DecodeBad(
      'unknown message type 0x${messageType.toRadixString(16).padLeft(4, '0')}',
    );
  }
  final failure = reader.finish();
  if (failure != null) return DecodeBad('${message.messageName}: $failure');
  return DecodeOk(message);
}

/// Reads every field of [messageType]; null for an unknown type. The
/// result is only meaningful if the reader did not fail.
Message? _decodeFields(int messageType, WireReader reader) {
  switch (messageType) {
    case MessageType.hello:
      return Hello(
        protocolVersion: reader.readU16('protocol_version'),
        clientSoftware: reader.readString(
          'client_software',
          maxBytes: maxNameBytes,
        ),
        deviceName: reader.readString('device_name', maxBytes: maxNameBytes),
      );
    case MessageType.helloOk:
      return HelloOk(
        protocolVersion: reader.readU16('protocol_version'),
        serverSoftware: reader.readString(
          'server_software',
          maxBytes: maxNameBytes,
        ),
        serverName: reader.readString('server_name', maxBytes: maxNameBytes),
        deviceId: reader.readU64('device_id'),
        chunkSizeBytes: reader.readU32('chunk_size_bytes'),
        maxFrameLengthBytes: reader.readU32('max_frame_length_bytes'),
      );
    case MessageType.ping:
      return const Ping();
    case MessageType.pong:
      return const Pong();
    case MessageType.pairRequest:
      return PairRequest(
        code: reader.readString('code', maxBytes: maxNameBytes),
      );
    case MessageType.pairOk:
      return PairOk(
        deviceId: reader.readU64('device_id'),
        deviceCertDer: reader.readBytes('device_cert_der'),
        deviceKeyPkcs8Der: reader.readBytes('device_key_pkcs8_der'),
        serverCertSha256: reader.readHash('server_cert_sha256'),
      );
    case MessageType.fileOffer:
      return FileOffer(
        path: reader.readString('path', maxBytes: maxPathBytes),
        sizeBytes: reader.readU64('size_bytes'),
        modifiedTimeMs: reader.readI64('modified_time_ms'),
        fileSha256: reader.readHash('file_sha256'),
        chunkHashes: _readHashList(reader, 'chunk_hashes'),
      );
    case MessageType.needChunks:
      final uploadId = reader.readU64('upload_id');
      final existingVersionId = reader.readU64('existing_version_id');
      final count = reader.readListCount(
        'missing_indexes',
        minItemBytes: _u32Bytes,
      );
      return NeedChunks(
        uploadId: uploadId,
        existingVersionId: existingVersionId,
        missingIndexes: [
          for (var i = 0; i < count; i++)
            reader.readU32('missing_indexes item'),
        ],
      );
    case MessageType.chunkData:
      return ChunkData(
        uploadId: reader.readU64('upload_id'),
        chunkIndex: reader.readU32('chunk_index'),
        chunkSha256: reader.readHash('chunk_sha256'),
        data: reader.readBytes('data'),
      );
    case MessageType.chunkOk:
      return ChunkOk(
        chunkIndex: reader.readU32('chunk_index'),
        chunkSha256: reader.readHash('chunk_sha256'),
      );
    case MessageType.commit:
      return Commit(uploadId: reader.readU64('upload_id'));
    case MessageType.commitOk:
      return CommitOk(versionId: reader.readU64('version_id'));
    case MessageType.listDevices:
      return const ListDevices();
    case MessageType.deviceList:
      final count = reader.readListCount(
        'devices',
        minItemBytes: _deviceEntryMinBytes,
      );
      return DeviceList(
        devices: [
          for (var i = 0; i < count; i++)
            DeviceEntry(
              deviceId: reader.readU64('device_id'),
              name: reader.readString('name', maxBytes: maxNameBytes),
              pairedAtMs: reader.readI64('paired_at_ms'),
              isCaller: reader.readBool('is_caller'),
            ),
        ],
      );
    case MessageType.listDir:
      return ListDir(
        deviceId: reader.readU64('device_id'),
        path: reader.readString('path', maxBytes: maxPathBytes),
        startAfter: reader.readString('start_after', maxBytes: maxPathBytes),
        maxEntries: reader.readU32('max_entries'),
      );
    case MessageType.dirEntries:
      final count = reader.readListCount(
        'entries',
        minItemBytes: _dirEntryMinBytes,
      );
      final entries = [for (var i = 0; i < count; i++) _readDirEntry(reader)];
      return DirEntries(entries: entries, hasMore: reader.readBool('has_more'));
    case MessageType.readFile:
      return ReadFile(
        deviceId: reader.readU64('device_id'),
        path: reader.readString('path', maxBytes: maxPathBytes),
        versionId: reader.readU64('version_id'),
      );
    case MessageType.fileManifest:
      return FileManifest(
        versionId: reader.readU64('version_id'),
        sizeBytes: reader.readU64('size_bytes'),
        modifiedTimeMs: reader.readI64('modified_time_ms'),
        fileSha256: reader.readHash('file_sha256'),
        chunkHashes: _readHashList(reader, 'chunk_hashes'),
      );
    case MessageType.readChunk:
      return ReadChunk(chunkSha256: reader.readHash('chunk_sha256'));
    case MessageType.chunkContent:
      return ChunkContent(
        chunkSha256: reader.readHash('chunk_sha256'),
        data: reader.readBytes('data'),
      );
    case MessageType.putThumbnail:
      return PutThumbnail(
        fileSha256: reader.readHash('file_sha256'),
        jpegData: reader.readBytes('jpeg_data'),
      );
    case MessageType.thumbnailOk:
      return const ThumbnailOk();
    case MessageType.readThumbnail:
      return ReadThumbnail(
        deviceId: reader.readU64('device_id'),
        path: reader.readString('path', maxBytes: maxPathBytes),
        versionId: reader.readU64('version_id'),
      );
    case MessageType.thumbnail:
      return Thumbnail(jpegData: reader.readBytes('jpeg_data'));
    case MessageType.close:
      return Close(
        reason: reader.readU16('reason'),
        message: reader.readString('message', maxBytes: maxMessageBytes),
      );
    case MessageType.error:
      return ErrorMessage(
        code: reader.readU16('code'),
        message: reader.readString('message', maxBytes: maxMessageBytes),
      );
    default:
      return null;
  }
}

List<Uint8List> _readHashList(WireReader reader, String field) {
  final count = reader.readListCount(field, minItemBytes: hashBytes);
  return [for (var i = 0; i < count; i++) reader.readHash('$field item')];
}

DirEntry _readDirEntry(WireReader reader) {
  final name = reader.readString('name', maxBytes: maxPathBytes);
  final kindOffsetBytes = reader.offsetBytes;
  final kindNumber = reader.readU8('kind');
  final kind = DirEntryKind.fromNumber(kindNumber);
  if (kind == null) {
    reader.fail(
      'kind must be 1 or 2, got $kindNumber',
      atOffsetBytes: kindOffsetBytes,
    );
  }
  return DirEntry(
    name: name,
    // Placeholder after a failure; the whole message is rejected then.
    kind: kind ?? DirEntryKind.file,
    sizeBytes: reader.readU64('size_bytes'),
    modifiedTimeMs: reader.readI64('modified_time_ms'),
    versionId: reader.readU64('version_id'),
  );
}
