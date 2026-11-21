/// Finds HaoTranNAS servers with the phone's own Bonjour (package:bonsoir)
/// instead of our raw multicast socket. iPhone only (D-043): iOS lets an
/// app send multicast only with Apple's multicast entitlement, which a
/// free Apple ID cannot get; Bonjour browsing needs only
/// `NSBonjourServices` in Info.plist. Author: Hao Tran.
///
/// ```
///  browse _haotrannas._tcp (3 s) ─► found ─► resolve ─► resolved:
///    host addresses + port + TXT v/fp ─► serverFromBonjour ─► DiscoveredServer
/// ```
///
/// Same checks as `discoverServers` in dart_client: TXT `v` must be the
/// protocol version we speak, `fp` 16 hex chars, an IPv4 address.
library;

import 'dart:async';
import 'dart:io';

import 'package:bonsoir/bonsoir.dart';
import 'package:flutter/services.dart';
import 'package:haotrannas_client/discovery/discovery.dart';

/// The Bonjour service type (no `.local`), as in `NSBonjourServices`.
const bonjourServiceType = '_haotrannas._tcp';

final _fingerprintPrefixPattern = RegExp(r'^[0-9a-f]{16}$');

/// One resolved Bonjour service → a server we can talk to, or null when
/// it is not one (wrong version, bad `fp`, no IPv4 address, or another
/// NAS than [pinnedFingerprintPrefix]). Pure.
DiscoveredServer? serverFromBonjour({
  required String name,
  required List<String> hostAddresses,
  required int port,
  required Map<String, String> attributes,
  String? pinnedFingerprintPrefix,
}) {
  final version = usableAnnouncedVersion(attributes['v']);
  if (version == null) return null;
  final fingerprintPrefix = attributes['fp']?.toLowerCase();
  if (fingerprintPrefix == null ||
      !_fingerprintPrefixPattern.hasMatch(fingerprintPrefix)) {
    return null;
  }
  if (pinnedFingerprintPrefix != null &&
      fingerprintPrefix != fingerprintPrefixOf(pinnedFingerprintPrefix)) {
    return null;
  }
  final ipv4Address = hostAddresses
      .map(InternetAddress.tryParse)
      .whereType<InternetAddress>()
      .where((address) => address.type == InternetAddressType.IPv4)
      .firstOrNull;
  if (ipv4Address == null || port <= 0 || port > 65535) return null;
  return DiscoveredServer(
    instanceName: '$name.$serviceName',
    ipv4Address: ipv4Address,
    port: port,
    fingerprintPrefix: fingerprintPrefix,
    protocolVersion: version,
  );
}

/// Browses for [listenFor] and returns every valid server, sorted by
/// name. Never throws: no Bonjour (plugin missing, Local Network access
/// denied) = an empty list, and the user can still type the address.
Future<List<DiscoveredServer>> findServersWithBonjour({
  String? pinnedFingerprintPrefix,
  Duration listenFor = const Duration(seconds: 3),
}) async {
  final foundByName = <String, DiscoveredServer>{};
  BonsoirDiscovery? discovery;
  StreamSubscription<BonsoirDiscoveryEvent>? subscription;

  void keep(BonsoirService service) {
    final server = serverFromBonjour(
      name: service.name,
      hostAddresses: service.hostAddresses,
      port: service.port,
      attributes: service.attributes,
      pinnedFingerprintPrefix: pinnedFingerprintPrefix,
    );
    if (server != null) foundByName[service.name] = server;
  }

  try {
    final browser = BonsoirDiscovery(
      type: bonjourServiceType,
      printLogs: false,
    );
    discovery = browser;
    await browser.initialize();
    subscription = browser.eventStream?.listen((event) {
      switch (event) {
        case BonsoirDiscoveryServiceFoundEvent(:final service):
          unawaited(
            Future.sync(() => browser.serviceResolver.resolveService(service))
                .catchError((Object _) {}),
          );
        case BonsoirDiscoveryServiceResolvedEvent(:final service):
          keep(service);
        case BonsoirDiscoveryServiceUpdatedEvent(:final service):
          keep(service);
        case BonsoirDiscoveryServiceLostEvent(:final service):
          foundByName.remove(service.name);
        default:
          break;
      }
    });
    await browser.start();
    await Future<void>.delayed(listenFor);
  } on PlatformException {
    // Bonjour refused (e.g. Local Network access off): nothing found.
  } on MissingPluginException {
    // Not on a phone (tests): nothing found.
  } finally {
    await subscription?.cancel();
    try {
      await discovery?.stop();
    } on Object {
      // Already stopped or never started.
    }
  }
  return foundByName.values.toList()..sort(
    (first, second) => first.instanceName.compareTo(second.instanceName),
  );
}
