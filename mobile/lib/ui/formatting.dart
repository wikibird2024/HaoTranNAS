/// Small text helpers shared by the screens (no intl package). Pure.
/// Author: Hao Tran.
library;

/// `0 B`, `950 B`, `1.5 KB`, `3.0 MB`, `1.2 GB` (1 KB = 1024 B).
String formatBytes(int sizeBytes) {
  const units = ['KB', 'MB', 'GB', 'TB'];
  if (sizeBytes < 1024) return '$sizeBytes B';
  var value = sizeBytes / 1024;
  var unitIndex = 0;
  while (value >= 1024 && unitIndex < units.length - 1) {
    value /= 1024;
    unitIndex++;
  }
  return '${value.toStringAsFixed(1)} ${units[unitIndex]}';
}

String _twoDigits(int value) => value.toString().padLeft(2, '0');

/// `2026-11-19 14:05` in local time.
String formatDateTime(DateTime time) {
  final local = time.toLocal();
  return '${local.year}-${_twoDigits(local.month)}-${_twoDigits(local.day)} '
      '${_twoDigits(local.hour)}:${_twoDigits(local.minute)}';
}

/// [formatDateTime] of a Unix time in milliseconds.
String formatTimeMs(int timeMs) =>
    formatDateTime(DateTime.fromMillisecondsSinceEpoch(timeMs));

/// `14:05:09.123` in local time, for the debug log.
String formatClockTime(DateTime time) {
  final local = time.toLocal();
  return '${_twoDigits(local.hour)}:${_twoDigits(local.minute)}:'
      '${_twoDigits(local.second)}.'
      '${local.millisecond.toString().padLeft(3, '0')}';
}
