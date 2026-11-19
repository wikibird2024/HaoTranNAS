/// Finds a way to the paired server and opens a connection as this
/// device (architecture §6, spec §13):
///
/// ```
///  candidates, in order (same address only once):
///    1. mDNS results whose fp= matches the pinned fingerprint
///    2. the last LAN address that worked
///    3. the WireGuard address the user set
///  each: TlsLink(fixed pin, client cert) ─► Hello ─► HelloOk(device id)
///    unreachable / timeout / TLS failed / pin mismatch ─► next candidate
///    closed before HelloOk or NOT_PAIRED ─► stop: "maybe not paired"
///    ok ─► remember a LAN address that worked (IdentityStore)
/// ```
///
/// "Maybe not paired" stops at once: the pin matched, so this is our
/// server refusing the certificate (revoked, spec §6 TLS note), and every
/// other address would say the same. No endless retries.
library;

import '../core/log/session_log.dart';
import '../core/transport/tls_link.dart';
import '../protocol/limits.dart';
import 'identity.dart';
import 'nas_connection.dart';
import 'server_address.dart';

/// Where a candidate address came from.
enum AddressSource { mdns, lastLan, wireGuard }

/// One answer from mDNS discovery (spec §13): the IPv4 address and port
/// of a `_haotrannas._tcp` service and its TXT `fp=` value.
final class DiscoveredServer {
  const DiscoveredServer(this.address, this.fingerprintPrefix);

  final ServerAddress address;

  /// First 16 lowercase hex characters of the server fingerprint.
  final String fingerprintPrefix;

  @override
  String toString() => 'DiscoveredServer($address, fp=$fingerprintPrefix)';
}

final class AddressCandidate {
  const AddressCandidate(this.address, this.source);

  final ServerAddress address;
  final AddressSource source;

  @override
  bool operator ==(Object other) =>
      other is AddressCandidate &&
      other.address == address &&
      other.source == source;

  @override
  int get hashCode => Object.hash(address, source);

  @override
  String toString() => '$address (${source.name})';
}

/// The order to try addresses in. Pure, so it is easy to test.
List<AddressCandidate> orderedCandidates(
  DeviceIdentity identity, {
  List<DiscoveredServer> discovered = const [],
}) {
  final pinnedPrefix = fingerprintPrefix(identity.serverCertSha256);
  final candidates = <AddressCandidate>[
    for (final server in discovered)
      if (server.fingerprintPrefix.toLowerCase() == pinnedPrefix)
        AddressCandidate(server.address, AddressSource.mdns),
    if (identity.lastAddresses.lastLan case final lastLan?)
      AddressCandidate(lastLan, AddressSource.lastLan),
    if (identity.lastAddresses.wireGuard case final wireGuard?)
      AddressCandidate(wireGuard, AddressSource.wireGuard),
  ];
  final seen = <ServerAddress>{};
  return [
    for (final candidate in candidates)
      if (seen.add(candidate.address)) candidate,
  ];
}

/// One address that did not work, and why.
typedef FailedAttempt = ({AddressCandidate candidate, String problem});

sealed class PairedConnectResult {
  const PairedConnectResult();
}

/// Connected as [identity] (with any new LAN address recorded).
final class PairedConnected extends PairedConnectResult {
  const PairedConnected({
    required this.connection,
    required this.candidate,
    required this.identity,
    required this.failedAttempts,
  });

  final NasConnection connection;

  /// The address that worked.
  final AddressCandidate candidate;

  /// The identity to keep using: [AddressBook] already saved it.
  final DeviceIdentity identity;

  /// Addresses tried before [candidate].
  final List<FailedAttempt> failedAttempts;

  @override
  String toString() =>
      'PairedConnected($candidate, device ${identity.deviceId})';
}

enum PairedConnectFailureKind {
  /// No mDNS result, no last LAN address, no WireGuard address.
  noAddress,

  /// Every address failed: server off, phone offline, wrong network.
  noAddressWorked,

  /// Our server (pin matched) closed before HelloOk or said NOT_PAIRED:
  /// this phone was removed, or never finished pairing. Offer to pair.
  maybeNotPaired,

  /// The server speaks another protocol version: update the app or
  /// the server.
  versionMismatch,
}

final class PairedConnectFailed extends PairedConnectResult {
  const PairedConnectFailed(this.kind, this.message, this.failedAttempts);

  final PairedConnectFailureKind kind;

  /// One line for the user.
  final String message;
  final List<FailedAttempt> failedAttempts;

  @override
  String toString() => 'PairedConnectFailed(${kind.name}): $message';
}

class AddressBook {
  AddressBook({
    required this.clientSoftware,
    required this.deviceName,
    this.store,
    this.connect = TlsLink.connect,
    this.connectTimeout = const Duration(milliseconds: connectTimeoutMs),
    this.log,
  });

  final String clientSoftware;
  final String deviceName;

  /// Where a newly working LAN address is saved; null = not saved.
  final IdentityStore? store;

  /// [TlsLink.connect]; tests pass a fake.
  final TlsConnector connect;

  /// Per address: TCP connect + TLS handshake.
  final Duration connectTimeout;
  final SessionLog? log;

  /// Tries [orderedCandidates] one by one, each within [connectTimeout].
  /// Never throws for network or server problems.
  Future<PairedConnectResult> connectPaired(
    DeviceIdentity identity, {
    List<DiscoveredServer> discovered = const [],
  }) async {
    final candidates = orderedCandidates(identity, discovered: discovered);
    final failedAttempts = <FailedAttempt>[];
    if (candidates.isEmpty) {
      return PairedConnectFailed(
        PairedConnectFailureKind.noAddress,
        'No server address known: open the app on the home Wi-Fi, or set '
        'the WireGuard address.',
        failedAttempts,
      );
    }
    for (final candidate in candidates) {
      final address = candidate.address;
      log?.note('trying $candidate');
      final NasConnection connection;
      try {
        final link = await connect(
          address.host,
          address.port,
          pin: FixedServerPin(identity.serverCertSha256),
          clientCertificate: identity,
          timeout: connectTimeout,
        );
        connection = await NasConnection.open(
          link,
          clientSoftware: clientSoftware,
          deviceName: deviceName,
          log: log,
        );
      } on TlsConnectFailure catch (failure) {
        failedAttempts.add((candidate: candidate, problem: failure.message));
        continue;
      } on TlsPinMismatch catch (mismatch) {
        // Another server (or someone in the middle) at this address.
        failedAttempts.add((
          candidate: candidate,
          problem:
              'another server (id ${shortId(mismatch.seen)}, expected '
              '${identity.serverShortId})',
        ));
        continue;
      } on NasFailure catch (failure) {
        failedAttempts.add((candidate: candidate, problem: failure.message));
        if (failure.isMaybeNotPaired) {
          return PairedConnectFailed(
            PairedConnectFailureKind.maybeNotPaired,
            'The server ${identity.serverShortId} did not accept this '
            'phone: it may have been removed. Pair again.',
            failedAttempts,
          );
        }
        if (failure.kind == NasFailureKind.versionMismatch) {
          return PairedConnectFailed(
            PairedConnectFailureKind.versionMismatch,
            failure.message,
            failedAttempts,
          );
        }
        continue;
      }
      final serverDeviceId = connection.helloOk.deviceId;
      if (serverDeviceId != identity.deviceId) {
        await connection.close();
        failedAttempts.add((
          candidate: candidate,
          problem:
              'server knows this phone as device $serverDeviceId, '
              'not ${identity.deviceId}',
        ));
        return PairedConnectFailed(
          PairedConnectFailureKind.maybeNotPaired,
          'The server does not know this phone as device '
          '${identity.deviceId}. Pair again.',
          failedAttempts,
        );
      }
      return PairedConnected(
        connection: connection,
        candidate: candidate,
        identity: await _remember(identity, candidate),
        failedAttempts: failedAttempts,
      );
    }
    return PairedConnectFailed(
      PairedConnectFailureKind.noAddressWorked,
      'The server did not answer at any known address '
      '(${candidates.map((candidate) => candidate.address).join(', ')}).',
      failedAttempts,
    );
  }

  /// Saves a LAN address (from mDNS or the last one) that worked.
  Future<DeviceIdentity> _remember(
    DeviceIdentity identity,
    AddressCandidate candidate,
  ) async {
    if (candidate.source == AddressSource.wireGuard ||
        identity.lastAddresses.lastLan == candidate.address) {
      return identity;
    }
    final updated = identity.withAddresses(
      identity.lastAddresses.withLastLan(candidate.address),
    );
    try {
      await store?.saveAddresses(updated);
    } on Exception catch (error) {
      // Not fatal: next time mDNS finds the server again.
      log?.note('could not save the LAN address: $error');
    }
    return updated;
  }
}
