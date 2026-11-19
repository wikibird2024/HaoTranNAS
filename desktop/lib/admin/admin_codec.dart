/// The server's admin socket line protocol (`server/src/admin.rs`, D-023,
/// D-041): command lines out, reply lines in. Pure: no I/O, never throws.
///
/// ```
///  status        ─► ok <n> connections
///  pair          ─► code <6 digits> server-id <XXXX-XXXX-XXXX> valid <s> s
///  devices       ─► <id> <name> paired <ms> [revoked <ms>] … then ok <n> devices
///  revoke <id>   ─► ok revoked device <id>
///  scrub-now     ─► progress <n> … then ok scrub <name value …>
///  scrub-report  ─► ok scrub <name value …>
///  cleanup-now   ─► ok cleanup <name value …>
///  any failure   ─► error <text>
/// ```
///
/// Author: Hao Tran.
library;

/// A parsed reply: the value, or what went wrong.
sealed class AdminResult<T> {
  const AdminResult();
}

final class AdminOk<T> extends AdminResult<T> {
  const AdminOk(this.value);

  final T value;
}

final class AdminFailed<T> extends AdminResult<T> {
  const AdminFailed(this.message);

  /// The server's `error` text, or why the reply made no sense.
  final String message;

  @override
  String toString() => 'AdminFailed($message)';
}

/// The command lines (without the newline).
abstract final class AdminCommand {
  static const status = 'status';
  static const pair = 'pair';
  static const devices = 'devices';
  static const scrubNow = 'scrub-now';
  static const scrubReport = 'scrub-report';
  static const cleanupNow = 'cleanup-now';

  static String revoke(int deviceId) => 'revoke $deviceId';
}

/// A one-time pairing code the server just opened.
final class PairingCode {
  const PairingCode({
    required this.code,
    required this.serverShortId,
    required this.validSeconds,
  });

  final String code;

  /// `DEB1-CAE1-944A`: the device compares it with what it sees.
  final String serverShortId;
  final int validSeconds;
}

/// One paired device.
final class AdminDevice {
  const AdminDevice({
    required this.id,
    required this.name,
    required this.pairedAt,
    this.revokedAt,
  });

  final int id;
  final String name;
  final DateTime pairedAt;

  /// Null = still allowed in.
  final DateTime? revokedAt;

  bool get isRevoked => revokedAt != null;
}

/// A scrub or cleanup summary: `name value` pairs, in order.
final class JobSummary {
  const JobSummary(this.values);

  final Map<String, String> values;

  int number(String name) => int.tryParse(values[name] ?? '') ?? 0;
}

/// Scrub summary names (`ScrubReport::summary_line`).
extension ScrubNumbers on JobSummary {
  int get chunksChecked => number('chunks_checked');
  int get bytesChecked => number('bytes_checked');
  int get badFound => number('bad_found');
  int get missing => number('missing');
  int get repaired => number('repaired');
  DateTime get startedAt =>
      DateTime.fromMillisecondsSinceEpoch(number('started_at_ms'));
  Duration get duration => Duration(milliseconds: number('duration_ms'));

  /// Nothing bad or missing.
  bool get isClean => badFound == 0 && missing == 0;
}

/// Cleanup summary names (`CleanupReport::summary_line`).
extension CleanupNumbers on JobSummary {
  int get expiredUploads => number('expired_uploads');
  int get tmpFiles => number('tmp_files');
  int get unusedChunks => number('unused_chunks');
  int get orphanFiles => number('orphan_files');
}

/// The reply lines of one command, `progress` lines already taken out.
/// Empty, or an `error` line → [AdminFailed].
AdminResult<List<String>> _checked(List<String> lines) {
  if (lines.isEmpty) {
    return const AdminFailed(
      'The server closed the admin connection without '
      'a reply.',
    );
  }
  final last = lines.last;
  if (last.startsWith('error ')) return AdminFailed(last.substring(6));
  return AdminOk(lines);
}

AdminFailed<T> _unexpected<T>(List<String> lines) =>
    AdminFailed('Unexpected reply: ${lines.join(' | ')}');

AdminResult<int> parseStatus(List<String> lines) => switch (_checked(lines)) {
  AdminFailed(:final message) => AdminFailed(message),
  AdminOk(value: [final line]) => switch (line.split(' ')) {
    ['ok', final count, 'connections'] when int.tryParse(count) != null =>
      AdminOk(int.parse(count)),
    _ => _unexpected(lines),
  },
  AdminOk() => _unexpected(lines),
};

AdminResult<PairingCode> parsePair(List<String> lines) =>
    switch (_checked(lines)) {
      AdminFailed(:final message) => AdminFailed(message),
      AdminOk(value: [final line]) => switch (line.split(' ')) {
        [
          'code',
          final code,
          'server-id',
          final serverId,
          'valid',
          final seconds,
          's',
        ]
            when RegExp(r'^\d{6}$').hasMatch(code) &&
                int.tryParse(seconds) != null =>
          AdminOk(
            PairingCode(
              code: code,
              serverShortId: serverId,
              validSeconds: int.parse(seconds),
            ),
          ),
        _ => _unexpected(lines),
      },
      AdminOk() => _unexpected(lines),
    };

final _okDevicesPattern = RegExp(r'^ok (\d+) devices$');

/// `<id> <name> paired <ms> [revoked <ms>]`: read from both ends, so a
/// name with spaces (or even the word "paired") still works.
final _devicePattern = RegExp(
  r'^(\d+) (.*) paired (-?\d+)(?: revoked (-?\d+))?$',
);

AdminResult<List<AdminDevice>> parseDevices(List<String> lines) {
  switch (_checked(lines)) {
    case AdminFailed(:final message):
      return AdminFailed(message);
    case AdminOk(value: final checked):
      final total = _okDevicesPattern.firstMatch(checked.last);
      if (total == null) return _unexpected(lines);
      final devices = <AdminDevice>[];
      for (final line in checked.take(checked.length - 1)) {
        final match = _devicePattern.firstMatch(line);
        if (match == null) return _unexpected(lines);
        final revokedMs = match.group(4);
        devices.add(
          AdminDevice(
            id: int.parse(match.group(1)!),
            name: match.group(2)!,
            pairedAt: DateTime.fromMillisecondsSinceEpoch(
              int.parse(match.group(3)!),
            ),
            revokedAt: revokedMs == null
                ? null
                : DateTime.fromMillisecondsSinceEpoch(int.parse(revokedMs)),
          ),
        );
      }
      if (devices.length != int.parse(total.group(1)!)) {
        return _unexpected(lines);
      }
      return AdminOk(devices);
  }
}

AdminResult<int> parseRevoke(List<String> lines) => switch (_checked(lines)) {
  AdminFailed(:final message) => AdminFailed(message),
  AdminOk(value: [final line]) => switch (line.split(' ')) {
    ['ok', 'revoked', 'device', final id] when int.tryParse(id) != null =>
      AdminOk(int.parse(id)),
    _ => _unexpected(lines),
  },
  AdminOk() => _unexpected(lines),
};

/// `ok scrub …` (scrub-now, scrub-report) or `ok cleanup …`.
AdminResult<JobSummary> parseJobSummary(List<String> lines, String job) =>
    switch (_checked(lines)) {
      AdminFailed(:final message) => AdminFailed(message),
      AdminOk(value: [final line]) when line.startsWith('ok $job ') =>
        switch (_pairs(line.substring('ok $job '.length))) {
          final Map<String, String> values => AdminOk(JobSummary(values)),
          null => _unexpected(lines),
        },
      AdminOk() => _unexpected(lines),
    };

/// `a 1 b 2` → {a: 1, b: 2}; null for an odd count.
Map<String, String>? _pairs(String text) {
  final words = text.split(' ').where((word) => word.isNotEmpty).toList();
  if (words.isEmpty || words.length.isOdd) return null;
  return {
    for (var index = 0; index < words.length; index += 2)
      words[index]: words[index + 1],
  };
}

/// The chunk count of a `progress <n>` line; null for any other line.
int? parseProgress(String line) =>
    line.startsWith('progress ') ? int.tryParse(line.substring(9)) : null;
