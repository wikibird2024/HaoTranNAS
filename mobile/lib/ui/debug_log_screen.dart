/// Shows the `SessionLog`: every frame sent and received, with time,
/// description and the first bytes in hex, newest first. A PairOk frame
/// never shows more than its header (spec §7: the key is never shown),
/// even if a logger kept more. Author: Hao Tran.
library;

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:haotrannas_client/core/bytes/hex.dart';
import 'package:haotrannas_client/core/log/session_log.dart';
import 'package:haotrannas_client/protocol/limits.dart';
import 'package:haotrannas_client/protocol/messages.dart';
import 'package:haotrannas_client/text/formatting.dart';

import '../app/providers.dart';

/// Bytes of each frame shown in hex.
const int shownLogBytes = 32;

/// Text shown in place of a PairOk payload.
const String keyRedactedText = '<key redacted>';

/// The frame's message type from its header, or null if too short.
int? _frameMessageType(Uint8List bytes) =>
    bytes.length < frameHeaderBytes ? null : (bytes[4] << 8) | bytes[5];

/// Hex of the first [shownLogBytes] of [entry]; a PairOk frame shows only
/// its header and [keyRedactedText]. Empty for a note.
String logBytesPreview(LogEntry entry) {
  final bytes = entry.bytes;
  if (bytes.isEmpty) return '';
  if (_frameMessageType(bytes) == MessageType.pairOk ||
      entry.description.startsWith('PairOk')) {
    final headerBytes = bytes.length < frameHeaderBytes
        ? bytes.length
        : frameHeaderBytes;
    return '${toHex(Uint8List.sublistView(bytes, 0, headerBytes))} '
        '$keyRedactedText';
  }
  final shownBytes = bytes.length < shownLogBytes
      ? bytes.length
      : shownLogBytes;
  final more = bytes.length > shownBytes ? ' …' : '';
  return '${toHex(Uint8List.sublistView(bytes, 0, shownBytes))}$more';
}

class DebugLogScreen extends ConsumerWidget {
  const DebugLogScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final log = ref.watch(sessionLogProvider);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Debug log'),
        actions: [
          IconButton(
            tooltip: 'Clear',
            icon: const Icon(Icons.delete_sweep),
            onPressed: log.clear,
          ),
        ],
      ),
      body: ListenableBuilder(
        listenable: log,
        builder: (context, _) {
          if (log.length == 0) {
            return const Center(child: Text('Nothing sent or received yet.'));
          }
          return ListView.builder(
            itemCount: log.length,
            itemBuilder: (context, index) =>
                _LogTile(log.entryAt(log.length - 1 - index)),
          );
        },
      ),
    );
  }
}

class _LogTile extends StatelessWidget {
  const _LogTile(this.entry);

  final LogEntry entry;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final (arrow, color) = switch (entry.direction) {
      Direction.sent => ('→', colors.primary),
      Direction.received => ('←', colors.tertiary),
      Direction.note => ('•', colors.outline),
    };
    final preview = logBytesPreview(entry);
    return ListTile(
      dense: true,
      leading: Text(arrow, style: TextStyle(fontSize: 20, color: color)),
      title: Text(entry.description),
      subtitle: Text(
        '${formatClockTime(entry.time)}${preview.isEmpty ? '' : '\n$preview'}',
        style: const TextStyle(fontFamily: 'monospace'),
      ),
    );
  }
}
