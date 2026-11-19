/// Riverpod state shared by the phone and PC apps: pairing, identity,
/// the connection to the paired server, browse/download, the backup side.
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
/// Each app overrides [clientSoftwareProvider], [deviceNameProvider],
/// [identityStoreProvider], [restoreFolderProvider] and, for the real
/// backup, [backupStatusSourceProvider] in its `main()`. No widgets here
/// (D-040). Author: Hao Tran.
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../backup/backup_runner.dart';
import '../backup/backup_status_source.dart';
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
import '../discovery/discovery.dart';

/// Sent in Hello (`client_software`), e.g. `haotrannas-mobile 0.1.0`.
final clientSoftwareProvider = Provider<String>(
  (ref) => 'haotrannas-client 0.1.0',
);

/// Sent in Hello (`device_name`); the NAS lists the device under it.
// shortcut: a fixed name; a "device name" setting can come later.
final deviceNameProvider = Provider<String>(
  (ref) => Platform.isAndroid
      ? 'Android phone'
      : Platform.isIOS
      ? 'iPhone'
      : Platform.localHostname,
);

/// Set in `main()`: `IdentityStore.forApp()`.
final identityStoreProvider = Provider<IdentityStore>(
  (ref) => throw UnimplementedError('override identityStoreProvider in main'),
);

/// Set in `main()`: where restored files go.
final restoreFolderProvider = Provider<Directory>(
  (ref) => throw UnimplementedError('override restoreFolderProvider in main'),
);

final sessionLogProvider = Provider<SessionLog>((ref) {
  final log = SessionLog();
  ref.onDispose(log.dispose);
  return log;
});

/// The backup side; `main()` overrides it with an adapter over the real
/// `BackupController` (see `BackupStatusSource`).
final backupStatusSourceProvider = Provider<BackupStatusSource>((ref) {
  final source = BackupNotConnected();
  ref.onDispose(source.dispose);
  return source;
});

/// Connects to the paired server for a backup run: mDNS pinned to our
/// server, then the address book's order. Throws [BackupConnectFailed].
Future<NasConnection> connectForBackup(Ref ref) async {
  final identity = await ref.read(identityProvider.future);
  if (identity == null) {
    throw const BackupConnectFailed('This device is not paired.');
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
}

/// [AddressBook.connectPaired] as a connection or a [BackupConnectFailed].
Future<NasConnection> connectPairedOrThrow(
  AddressBook addressBook,
  DeviceIdentity identity, {
  List<address_book.DiscoveredServer> discovered = const [],
}) async {
  final result = await addressBook.connectPaired(
    identity,
    discovered: discovered,
  );
  return switch (result) {
    PairedConnected(:final connection) => connection,
    PairedConnectFailed(:final kind, :final message) =>
      throw BackupConnectFailed(
        message,
        isMaybeNotPaired: kind == PairedConnectFailureKind.maybeNotPaired,
      ),
  };
}

// ── Identity ──────────────────────────────────────────────────────────

/// This device's pairing, or null when not paired.
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

/// Plain mDNS; the phone overrides it to hold the Wi-Fi multicast lock.
final serverFinderProvider = Provider<ServerFinder>((ref) => findServersOnLan);

/// Asks the LAN for servers for 3 s. Never throws: no network = empty list.
Future<List<DiscoveredServer>> findServersOnLan({
  String? pinnedFingerprintPrefix,
}) async {
  try {
    return await discoverServers(
      pinnedFingerprintPrefix: pinnedFingerprintPrefix,
    );
  } on SocketException {
    return const [];
  }
}

final addressBookProvider = Provider<AddressBook>(
  (ref) => AddressBook(
    clientSoftware: ref.watch(clientSoftwareProvider),
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

  /// The server refused this device: it was removed on the NAS.
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
      state = const ServerOffline(problem: 'This device is not paired.');
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
      clientSoftware: ref.watch(clientSoftwareProvider),
      log: log,
    ),
  );
});

/// One open, unpaired connection that takes codes. [PairingSession]
/// through [SessionPairingAttempt]; tests use a fake.
abstract interface class PairingAttempt {
  /// `3F9A-C21B-77E0`: the user compares it with the NAS.
  String get serverShortId;

  /// The connection still takes another code.
  bool get isOpen;

  /// See `PairingSession.submitCode`; never throws.
  Future<PairingResult> submitCode(String code);

  Future<void> close();
}

/// Opens a [PairingAttempt]; throws `PairingFailed` when no server
/// answers or TLS fails.
typedef PairingOpener = Future<PairingAttempt> Function(ServerAddress address);

final class SessionPairingAttempt implements PairingAttempt {
  SessionPairingAttempt(this.session);

  final PairingSession session;

  @override
  String get serverShortId => session.serverShortId;

  @override
  bool get isOpen => session.isOpen;

  @override
  Future<PairingResult> submitCode(String code) => session.submitCode(code);

  @override
  Future<void> close() => session.close();
}

/// A short title for each failure the user can act on.
String pairingFailureTitle(PairingFailureKind kind) => switch (kind) {
  PairingFailureKind.badCode => 'Wrong code',
  PairingFailureKind.badCodeFormat => 'Check the code',
  PairingFailureKind.notAllowedFromNetwork => 'Not allowed from this network',
  PairingFailureKind.serverMismatch ||
  PairingFailureKind.shortIdMismatch => 'Possible man-in-the-middle',
  PairingFailureKind.pairingNotOpen => 'The NAS is not waiting for a phone',
  PairingFailureKind.tooManyAttempts => 'Too many wrong codes',
  PairingFailureKind.unreachable => 'NAS not found',
  _ => 'Pairing failed',
};
