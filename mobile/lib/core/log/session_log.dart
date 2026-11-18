// Copied from Protocol Lab (lib/core/log/session_log.dart), simplified:
// an entry holds a description and the raw bytes, not a decoded Frame
// with fields, and there is no pause.
import 'dart:collection';

import 'package:flutter/foundation.dart';

enum Direction {
  /// Phone → server.
  sent,

  /// Server → phone.
  received,

  /// Something the app noticed: connected, timeout, error.
  note,
}

class LogEntry {
  LogEntry({
    required this.time,
    required this.direction,
    required this.description,
    required this.bytes,
  });

  final DateTime time;
  final Direction direction;

  /// One line for a person, for example `ChunkData 1048576 bytes`.
  final String description;

  /// The bytes on the wire; empty for a [Direction.note].
  final Uint8List bytes;
}

/// Everything the app sent and received, newest last. Capped so a long
/// backup (thousands of chunks) cannot fill the phone's memory; the oldest
/// entries go first.
class SessionLog extends ChangeNotifier {
  SessionLog({this.capacity = 5000, DateTime Function()? clock})
    : _clock = clock ?? DateTime.now;

  final int capacity;
  final DateTime Function() _clock;
  final _entries = ListQueue<LogEntry>();

  List<LogEntry> get entries => List.unmodifiable(_entries);
  int get length => _entries.length;

  /// O(1); use this in list builders instead of copying [entries].
  LogEntry entryAt(int index) => _entries.elementAt(index);

  void sent(String description, Uint8List bytes) =>
      add(Direction.sent, description, bytes);

  void received(String description, Uint8List bytes) =>
      add(Direction.received, description, bytes);

  void note(String text) => add(Direction.note, text, Uint8List(0));

  void add(Direction direction, String description, Uint8List bytes) {
    _entries.addLast(
      LogEntry(
        time: _clock(),
        direction: direction,
        description: description,
        bytes: bytes,
      ),
    );
    while (_entries.length > capacity) {
      _entries.removeFirst();
    }
    notifyListeners();
  }

  void clear() {
    _entries.clear();
    notifyListeners();
  }
}
