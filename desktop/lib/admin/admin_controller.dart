/// NAS admin state for the screens (D-041): where the admin socket is,
/// whether it answers, the devices, the last scrub and cleanup.
///
/// ```
///  AdminTarget ─► this PC: <data dir>/admin.sock ───────────┐
///              └► SSH: SshTunnel(host, <data dir>/admin.sock)┴► AdminLink ─► codec ─► AdminState
/// ```
///
/// Read-mostly on purpose: the only changes it can make are a pairing
/// code, revoking a device (its backups stay, D-025), a scrub and a
/// cleanup. No config editing, no delete (D-039). Author: Hao Tran.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'admin_codec.dart';
import 'admin_link.dart';
import 'ssh_tunnel.dart';

/// Where the server's admin socket is.
sealed class AdminTarget {
  const AdminTarget(this.dataDirectory);

  /// The server's data folder; `admin.sock` is inside it.
  final String dataDirectory;

  String get socketPath => '$dataDirectory/admin.sock';
  String get label;
}

final class AdminOnThisPc extends AdminTarget {
  const AdminOnThisPc(super.dataDirectory);

  @override
  String get label => 'This PC · $dataDirectory';
}

final class AdminOverSsh extends AdminTarget {
  const AdminOverSsh(this.host, super.dataDirectory);

  /// `user@nas` or a name from ~/.ssh/config.
  final String host;

  @override
  String get label => 'SSH $host · $dataDirectory';
}

/// The data folder the NAS install script uses (`nas/scripts/install.sh`).
const defaultNasDataDirectory = '/srv/haotrannas';

/// Name of the saved target in the app's value store.
const adminTargetValueName = 'admin_target';

String encodeAdminTarget(AdminTarget target) => jsonEncode(switch (target) {
  AdminOnThisPc(:final dataDirectory) => {
    'kind': 'this_pc',
    'data_dir': dataDirectory,
  },
  AdminOverSsh(:final host, :final dataDirectory) => {
    'kind': 'ssh',
    'host': host,
    'data_dir': dataDirectory,
  },
});

/// Null for missing or damaged text.
AdminTarget? decodeAdminTarget(String? text) {
  if (text == null) return null;
  try {
    final map = jsonDecode(text) as Map<String, Object?>;
    final dataDirectory = map['data_dir'] as String?;
    if (dataDirectory == null || dataDirectory.isEmpty) return null;
    return switch (map['kind']) {
      'this_pc' => AdminOnThisPc(dataDirectory),
      'ssh' when map['host'] is String => AdminOverSsh(
        map['host']! as String,
        dataDirectory,
      ),
      _ => null,
    };
  } on Object {
    return null;
  }
}

/// Whether the admin socket answered the last `status`.
sealed class AdminReach {
  const AdminReach();
}

final class AdminNotSetUp extends AdminReach {
  const AdminNotSetUp();
}

final class AdminChecking extends AdminReach {
  const AdminChecking();
}

final class AdminReachable extends AdminReach {
  const AdminReachable(this.openConnections);

  final int openConnections;
}

final class AdminUnreachable extends AdminReach {
  const AdminUnreachable(this.message);

  final String message;
}

final class AdminState {
  const AdminState({
    this.target,
    this.reach = const AdminNotSetUp(),
    this.devices,
    this.lastScrub,
    this.scrubNote,
    this.scrubChunksChecked,
    this.lastCleanup,
    this.isCleaning = false,
    this.actionProblem,
  });

  final AdminTarget? target;
  final AdminReach reach;
  final List<AdminDevice>? devices;
  final JobSummary? lastScrub;

  /// Why there is no scrub report (none yet, or the scrub failed).
  final String? scrubNote;

  /// Non-null while a scrub runs: chunks checked so far.
  final int? scrubChunksChecked;
  final JobSummary? lastCleanup;
  final bool isCleaning;

  /// The last failed action (revoke, cleanup…), for a message.
  final String? actionProblem;

  bool get isReachable => reach is AdminReachable;
  bool get isScrubbing => scrubChunksChecked != null;

  AdminState copyWith({
    AdminTarget? target,
    AdminReach? reach,
    List<AdminDevice>? devices,
    JobSummary? lastScrub,
    String? Function()? scrubNote,
    int? Function()? scrubChunksChecked,
    JobSummary? lastCleanup,
    bool? isCleaning,
    String? Function()? actionProblem,
  }) => AdminState(
    target: target ?? this.target,
    reach: reach ?? this.reach,
    devices: devices ?? this.devices,
    lastScrub: lastScrub ?? this.lastScrub,
    scrubNote: scrubNote == null ? this.scrubNote : scrubNote(),
    scrubChunksChecked: scrubChunksChecked == null
        ? this.scrubChunksChecked
        : scrubChunksChecked(),
    lastCleanup: lastCleanup ?? this.lastCleanup,
    isCleaning: isCleaning ?? this.isCleaning,
    actionProblem: actionProblem == null ? this.actionProblem : actionProblem(),
  );
}

/// Sends one command line; the real one goes through [AdminLink] (and an
/// [SshTunnel]), tests answer from a script.
abstract interface class AdminChannel {
  Future<List<String>> send(
    String command, {
    void Function(int chunksChecked)? onProgress,
  });

  Future<void> close();
}

/// [AdminChannel] for a target: opens the SSH tunnel on first use and
/// again after a failure.
class TargetAdminChannel implements AdminChannel {
  TargetAdminChannel(this.target, {this.openTunnel = SshTunnel.open});

  final AdminTarget target;
  final Future<SshTunnel> Function({
    required String host,
    required String remoteSocketPath,
  })
  openTunnel;

  SshTunnel? _tunnel;

  @override
  Future<List<String>> send(
    String command, {
    void Function(int chunksChecked)? onProgress,
  }) async {
    final socketPath = switch (target) {
      AdminOnThisPc(:final socketPath) => socketPath,
      AdminOverSsh(:final host, :final socketPath) =>
        (_tunnel ??= await openTunnel(
          host: host,
          remoteSocketPath: socketPath,
        )).localSocketPath,
    };
    try {
      return await AdminLink(socketPath).send(command, onProgress: onProgress);
    } on AdminLinkFailed {
      await close();
      rethrow;
    }
  }

  @override
  Future<void> close() async {
    final tunnel = _tunnel;
    _tunnel = null;
    await tunnel?.close();
  }
}

/// The saved target, read in `main()`; null = never set up.
final initialAdminTargetProvider = Provider<AdminTarget?>((ref) => null);

/// Saves a target (the app's value store); `main()` overrides it.
final saveAdminTargetProvider = Provider<Future<void> Function(AdminTarget)>(
  (ref) => (_) async {},
);

/// Makes the channel for a target; tests override it.
final adminChannelFactoryProvider =
    Provider<AdminChannel Function(AdminTarget)>(
      (ref) => TargetAdminChannel.new,
    );

final adminProvider = NotifierProvider<AdminController, AdminState>(
  AdminController.new,
);

class AdminController extends Notifier<AdminState> {
  AdminChannel? _channel;

  @override
  AdminState build() {
    ref.onDispose(() => unawaited(_channel?.close()));
    final target = ref.read(initialAdminTargetProvider);
    if (target == null) return const AdminState();
    _channel = ref.read(adminChannelFactoryProvider)(target);
    Future.microtask(refresh);
    return AdminState(target: target, reach: const AdminChecking());
  }

  /// Saves [target] and checks it at once.
  Future<void> setTarget(AdminTarget target) async {
    await _channel?.close();
    _channel = ref.read(adminChannelFactoryProvider)(target);
    state = AdminState(target: target, reach: const AdminChecking());
    await ref.read(saveAdminTargetProvider)(target);
    await refresh();
  }

  /// Sends [command]; a broken link marks the NAS unreachable.
  Future<List<String>?> _send(
    String command, {
    void Function(int chunksChecked)? onProgress,
  }) async {
    final channel = _channel;
    if (channel == null) return null;
    try {
      return await channel.send(command, onProgress: onProgress);
    } on AdminLinkFailed catch (error) {
      if (ref.mounted) {
        state = state.copyWith(reach: AdminUnreachable('$error'));
      }
      return null;
    }
  }

  /// status, devices and the last scrub report.
  Future<void> refresh() async {
    if (_channel == null) return;
    state = state.copyWith(reach: const AdminChecking());
    final statusLines = await _send(AdminCommand.status);
    if (statusLines == null || !ref.mounted) return;
    switch (parseStatus(statusLines)) {
      case AdminFailed(:final message):
        state = state.copyWith(reach: AdminUnreachable(message));
        return;
      case AdminOk(value: final connections):
        state = state.copyWith(reach: AdminReachable(connections));
    }
    await _loadDevices();
    final scrubLines = await _send(AdminCommand.scrubReport);
    if (scrubLines == null || !ref.mounted) return;
    state = switch (parseJobSummary(scrubLines, 'scrub')) {
      AdminOk(value: final summary) => state.copyWith(
        lastScrub: summary,
        scrubNote: () => null,
      ),
      AdminFailed(:final message) => state.copyWith(scrubNote: () => message),
    };
  }

  Future<void> _loadDevices() async {
    final lines = await _send(AdminCommand.devices);
    if (lines == null || !ref.mounted) return;
    state = switch (parseDevices(lines)) {
      AdminOk(value: final devices) => state.copyWith(devices: devices),
      AdminFailed(:final message) => state.copyWith(
        actionProblem: () => 'Device list: $message',
      ),
    };
  }

  /// Opens a pairing window on the server; the code is shown, never logged.
  Future<AdminResult<PairingCode>> createPairingCode() async {
    final lines = await _send(AdminCommand.pair);
    if (lines == null) {
      return AdminFailed(_reachMessage());
    }
    return parsePair(lines);
  }

  /// Locks a device out; its backups stay restorable (D-025).
  Future<void> revoke(int deviceId) async {
    final lines = await _send(AdminCommand.revoke(deviceId));
    if (lines == null || !ref.mounted) return;
    if (parseRevoke(lines) case AdminFailed(:final message)) {
      state = state.copyWith(actionProblem: () => 'Revoke: $message');
      return;
    }
    state = state.copyWith(actionProblem: () => null);
    await _loadDevices();
  }

  /// Re-hashes every stored chunk; can take hours on a big store.
  Future<void> scrubNow() async {
    if (state.isScrubbing) return;
    state = state.copyWith(scrubChunksChecked: () => 0);
    final lines = await _send(
      AdminCommand.scrubNow,
      onProgress: (checked) {
        if (ref.mounted) {
          state = state.copyWith(scrubChunksChecked: () => checked);
        }
      },
    );
    if (!ref.mounted) return;
    state = state.copyWith(scrubChunksChecked: () => null);
    if (lines == null) return;
    state = switch (parseJobSummary(lines, 'scrub')) {
      AdminOk(value: final summary) => state.copyWith(
        lastScrub: summary,
        scrubNote: () => null,
      ),
      AdminFailed(:final message) => state.copyWith(
        actionProblem: () => 'Scrub: $message',
      ),
    };
  }

  /// Removes expired uploads, temp files and unused chunks now.
  Future<void> cleanupNow() async {
    if (state.isCleaning) return;
    state = state.copyWith(isCleaning: true);
    final lines = await _send(AdminCommand.cleanupNow);
    if (!ref.mounted) return;
    state = state.copyWith(isCleaning: false);
    if (lines == null) return;
    state = switch (parseJobSummary(lines, 'cleanup')) {
      AdminOk(value: final summary) => state.copyWith(lastCleanup: summary),
      AdminFailed(:final message) => state.copyWith(
        actionProblem: () => 'Cleanup: $message',
      ),
    };
  }

  String _reachMessage() => switch (state.reach) {
    AdminUnreachable(:final message) => message,
    AdminNotSetUp() => 'Set up the NAS admin connection first.',
    _ => 'The NAS admin connection is not ready.',
  };
}
