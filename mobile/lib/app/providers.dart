/// Riverpod providers that tie the client code to the screens.
///
/// ```
///  identityStoreProvider ─► identityProvider (paired or not)
///          │                       │
///          ▼                       ▼
///  addressBookProvider ─► serverConnectionProvider (offline/connecting/online)
///  serverFinderProvider ─┘         │
///                                  ▼
///                      remoteFilesProvider (DownloadEngine while online)
///  pairingOpenerProvider · backupStatusSourceProvider · sessionLogProvider
/// ```
///
/// [identityStoreProvider] and [restoreFolderProvider] need async
/// path_provider calls: `main()` overrides them. Author: Hao Tran.
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../backup/background.dart';
import '../backup/backup_controller.dart';
import '../backup/backup_runner.dart';
import '../backup/backup_state_store.dart';
import '../backup/media_source.dart';
import '../client/address_book.dart' as address_book;
import '../client/address_book.dart'
    show
        AddressBook,
        PairedConnectFailed,
        PairedConnectFailureKind,
        PairedConnected;
import '../client/download_engine.dart';
import '../client/identity.dart';
import '../client/nas_connection.dart';
import '../client/pairing.dart';
import '../client/server_address.dart';
import '../core/log/session_log.dart';
import '../core/transport/multicast_lock.dart';
import '../discovery/discovery.dart';
import '../ui/backup_status_source.dart';
import '../ui/pairing_screen.dart';

/// Sent in Hello (`client_software`).
const appClientSoftware = 'haotrannas-mobile 0.1.0';

/// Set in `main()`: `IdentityStore.forApp()`.
final identityStoreProvider = Provider<IdentityStore>(
  (ref) => throw UnimplementedError('override identityStoreProvider in main'),
);

/// Set in `main()`: `<app documents>/restored`.
final restoreFolderProvider = Provider<Directory>(
  (ref) => throw UnimplementedError('override restoreFolderProvider in main'),
);

/// Sent in Hello (`device_name`); the NAS lists the phone under it.
// shortcut: a fixed name; a "phone name" setting can come later.
final deviceNameProvider = Provider<String>(
  (ref) => Platform.isAndroid ? 'Android phone' : Platform.localHostname,
);

final sessionLogProvider = Provider<SessionLog>((ref) {
  final log = SessionLog();
  ref.onDispose(log.dispose);
  return log;
});

/// Adds a restored file to the phone's gallery. Null = files stay only
/// in the app's folder. ⚪ Android MediaStore insertion is phone-only
/// work, not written yet (see `AddToGallery`).
final addToGalleryProvider = Provider<AddToGallery?>((ref) => null);

/// The backup side. The lead overrides this with an adapter over the
/// real `BackupController` (see `BackupStatusSource`).
final backupStatusSourceProvider = Provider<BackupStatusSource>((ref) {
  final source = BackupNotConnected();
  ref.onDispose(source.dispose);
  return source;
});

/// The real backup side over [store]; `main()` overrides
/// [backupStatusSourceProvider] with it. Foreground runs may use mDNS;
/// the background job uses cached addresses only (D-012).
BackupStatusSource appBackupStatusSource(Ref ref, BackupStateStore store) {
  final log = ref.read(sessionLogProvider);
  final controller = BackupController(
    runner: BackupRunner(
      mediaSource: PhotoManagerMediaSource(),
      stateStore: store,
      connect: () async {
        final identity = await ref.read(identityProvider.future);
        if (identity == null) {
          throw const BackupConnectFailed('This phone is not paired.');
        }
        final found = await ref.read(serverFinderProvider)(
          pinnedFingerprintPrefix: fingerprintPrefix(identity.serverCertSha256),
        );
        return connectPairedOrThrow(
          ref.read(addressBookProvider),
          identity,
          discovered: [
            for (final server in found)
              address_book.DiscoveredServer(
                ServerAddress(server.ipv4Address.address, server.port),
                server.fingerprintPrefix,
              ),
          ],
        );
      },
    ),
    stateStore: store,
    scheduler: WorkmanagerBackupScheduler(
      clientSoftware: appClientSoftware,
      deviceName: ref.read(deviceNameProvider),
    ),
    manualLauncher: Platform.isAndroid
        ? WorkmanagerManualBackupLauncher(
            clientSoftware: appClientSoftware,
            deviceName: ref.read(deviceNameProvider),
          )
        : null,
    log: log.note,
  );
  final source = BackupControllerStatusSource(controller);
  unawaited(controller.start());
  ref.onDispose(() {
    unawaited(controller.stop());
    source.dispose();
    controller.dispose();
  });
  return source;
}

// ── Identity ──────────────────────────────────────────────────────────

/// This phone's pairing, or null when not paired.
final identityProvider =
    AsyncNotifierProvider<IdentityController, DeviceIdentity?>(
      IdentityController.new,
    );

class IdentityController extends AsyncNotifier<DeviceIdentity?> {
  @override
  Future<DeviceIdentity?> build() async {
    try {
      return await ref.watch(identityStoreProvider).load();
    } on IdentityDamaged catch (damaged) {
      // Unusable files count as "not paired": pairing again rewrites them.
      ref.read(sessionLogProvider).note('pairing files unusable: $damaged');
      return null;
    }
  }

  /// Keeps addresses the address book just learned (already saved).
  void updateIdentity(DeviceIdentity identity) => state = AsyncData(identity);

  /// Forgets the pairing: closes the connection and deletes the
  /// certificate and key. Backups on the NAS stay.
  Future<void> unpair() async {
    await ref.read(serverConnectionProvider.notifier).disconnect();
    await ref.read(identityStoreProvider).delete();
    state = const AsyncData(null);
  }
}

// ── Finding and connecting ────────────────────────────────────────────

/// mDNS discovery; [pinnedFingerprintPrefix] keeps only our server.
typedef ServerFinder = Future<List<DiscoveredServer>> Function({
  String? pinnedFingerprintPrefix,
});

final serverFinderProvider = Provider<ServerFinder>((ref) => findServersOnWifi);

/// Asks the LAN for servers for 3 s while holding the Wi-Fi multicast
/// lock (foreground only, spec §13). Without the lock (not Android) it
/// tries anyway. Never throws: no network = empty list.
Future<List<DiscoveredServer>> findServersOnWifi({
  String? pinnedFingerprintPrefix,
}) async {
  Future<List<DiscoveredServer>> discover() =>
      discoverServers(pinnedFingerprintPrefix: pinnedFingerprintPrefix);
  try {
    try {
      return await withMulticastLock(MulticastLock(), discover);
    } on MissingPluginException {
      return await discover();
    } on PlatformException {
      return await discover();
    }
  } on SocketException {
    return const [];
  }
}

final addressBookProvider = Provider<AddressBook>(
  (ref) => AddressBook(
    clientSoftware: appClientSoftware,
    deviceName: ref.watch(deviceNameProvider),
    store: ref.watch(identityStoreProvider),
    log: ref.watch(sessionLogProvider),
  ),
);

/// The connection to the paired server, as the screens see it.
sealed class ServerLinkState {
  const ServerLinkState();
}

final class ServerOffline extends ServerLinkState {
  const ServerOffline({this.problem, this.isMaybeNotPaired = false});

  /// Why, for the user; null = not tried yet or closed by the app.
  final String? problem;

  /// The server refused this phone: it was removed on the NAS.
  final bool isMaybeNotPaired;
}

final class ServerConnecting extends ServerLinkState {
  const ServerConnecting();
}

final class ServerOnline extends ServerLinkState {
  const ServerOnline(this.connection);

  final NasConnection connection;
}

final serverConnectionProvider =
    NotifierProvider<ServerConnectionController, ServerLinkState>(
      ServerConnectionController.new,
    );

class ServerConnectionController extends Notifier<ServerLinkState> {
  NasConnection? _connection;

  @override
  ServerLinkState build() {
    ref.onDispose(() => _connection?.close());
    return const ServerOffline();
  }

  /// mDNS (pinned to our server), then the address book's order. Does
  /// nothing while connecting or online.
  Future<void> connect() async {
    if (state is! ServerOffline) return;
    state = const ServerConnecting();
    final identity = await ref.read(identityProvider.future);
    if (!ref.mounted) return;
    if (identity == null) {
      state = const ServerOffline(problem: 'This phone is not paired.');
      return;
    }
    final found = await ref.read(serverFinderProvider)(
      pinnedFingerprintPrefix: fingerprintPrefix(identity.serverCertSha256),
    );
    if (!ref.mounted) return;
    final result = await ref
        .read(addressBookProvider)
        .connectPaired(
          identity,
          discovered: [
            for (final server in found)
              address_book.DiscoveredServer(
                ServerAddress(server.ipv4Address.address, server.port),
                server.fingerprintPrefix,
              ),
          ],
        );
    if (!ref.mounted) {
      if (result is PairedConnected) await result.connection.close();
      return;
    }
    switch (result) {
      case PairedConnected(:final connection, identity: final updated):
        _connection = connection;
        connection.state.addListener(_onConnectionState);
        ref.read(identityProvider.notifier).updateIdentity(updated);
        state = ServerOnline(connection);
        _onConnectionState();
      case PairedConnectFailed(:final kind, :final message):
        state = ServerOffline(
          problem: message,
          isMaybeNotPaired: kind == PairedConnectFailureKind.maybeNotPaired,
        );
    }
  }

  /// Closes the connection; the state becomes [ServerOffline].
  Future<void> disconnect() async {
    final connection = _connection;
    _connection = null;
    connection?.state.removeListener(_onConnectionState);
    if (ref.mounted) state = const ServerOffline();
    await connection?.close();
  }

  void _onConnectionState() {
    final connection = _connection;
    if (connection == null || !ref.mounted) return;
    final connectionState = connection.state.value;
    if (connectionState is! NasClosed) return;
    connection.state.removeListener(_onConnectionState);
    _connection = null;
    final cause = connectionState.cause;
    state = cause.kind == NasFailureKind.closedByClient
        ? const ServerOffline()
        : ServerOffline(
            problem: cause.message,
            isMaybeNotPaired: cause.isMaybeNotPaired,
          );
  }
}

/// Browse and download over the connection; null while not online.
final remoteFilesProvider = Provider<RemoteFiles?>((ref) {
  final link = ref.watch(serverConnectionProvider);
  return link is ServerOnline ? DownloadEngine(link.connection) : null;
});

// ── Pairing ───────────────────────────────────────────────────────────

final pairingOpenerProvider = Provider<PairingOpener>((ref) {
  final deviceName = ref.watch(deviceNameProvider);
  final log = ref.watch(sessionLogProvider);
  return (address) async => SessionPairingAttempt(
    await PairingSession.open(
      host: address.host,
      port: address.port,
      deviceName: deviceName,
      clientSoftware: appClientSoftware,
      log: log,
    ),
  );
});
