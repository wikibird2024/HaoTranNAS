/// Finds the server on the LAN with mDNS (spec §13): service
/// `_haotrannas._tcp.local`, TXT `v=1` and `fp=<16 lowercase hex>`, IPv4
/// (A record) address only. The address book (`client/address_book.dart`)
/// falls back to the last known address when nothing is found.
///
/// ```
///  PTR query ─► answers + additionals for [timeout]
///   PTR  _haotrannas._tcp.local → instance
///   SRV  instance → port, host        (asked again if missing)
///   TXT  instance → v=1, fp=…         (asked again if missing)
///   A    host → IPv4                  (asked again if missing; AAAA ignored)
///  ─► one DiscoveredServer per instance, v == 1, fp present, fp == pin
/// ```
///
/// Android drops multicast unless the app holds the Wi-Fi multicast lock
/// (D-012): the CALLER holds it around [discoverServers], foreground only,
/// e.g. `withMulticastLock(MulticastLock(), () => discoverServers(...))`.
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import '../core/transport/mdns_socket.dart';
import '../core/transport/multicast_lock.dart';
import 'dns_codec.dart';

/// The service name from spec §13.
const serviceName = '_haotrannas._tcp.local';

/// The only TXT `v` this app speaks.
const supportedProtocolVersion = 1;

/// Length of the TXT `fp` value: first 16 lowercase hex chars of the
/// server certificate's SHA-256 fingerprint.
const fingerprintPrefixLength = 16;

/// How long after the first PTR query it is sent again (Wi-Fi drops
/// multicast packets; one repeat is cheap).
const repeatQueryAfter = Duration(seconds: 1);

/// One server that answered. Connect to [ipv4Address]:[port] and check the
/// full pinned fingerprint on the TLS handshake: [fingerprintPrefix] only
/// says which server this probably is.
class DiscoveredServer {
  const DiscoveredServer({
    required this.instanceName,
    required this.ipv4Address,
    required this.port,
    required this.fingerprintPrefix,
    required this.protocolVersion,
  });

  /// e.g. `HaoTranNAS._haotrannas._tcp.local`.
  final String instanceName;
  final InternetAddress ipv4Address;
  final int port;

  /// 16 lowercase hex chars.
  final String fingerprintPrefix;
  final int protocolVersion;

  @override
  String toString() =>
      'DiscoveredServer($instanceName, ${ipv4Address.address}:$port, fp=$fingerprintPrefix, v=$protocolVersion)';
}

/// What [discoverServers] sends and listens on: [MdnsSocket] in the app,
/// a fake in tests.
abstract interface class MdnsTransport {
  Stream<Uint8List> get datagrams;
  void send(Uint8List bytes);
  void close();
}

/// [MdnsTransport] over the real multicast socket (224.0.0.251:5353).
class MdnsSocketTransport implements MdnsTransport {
  MdnsSocketTransport(this._socket);

  static Future<MdnsSocketTransport> open() async =>
      MdnsSocketTransport(await MdnsSocket.open());

  final MdnsSocket _socket;

  @override
  Stream<Uint8List> get datagrams =>
      _socket.datagrams.map((datagram) => datagram.bytes);

  @override
  void send(Uint8List bytes) => _socket.send(bytes);

  @override
  void close() => _socket.close();
}

/// Holds the Wi-Fi multicast lock while [action] runs, and always releases
/// it, also when [action] throws. If `hold()` throws (not Android, native
/// side missing) [action] does not run and the error goes to the caller,
/// who decides whether to discover without the lock.
Future<T> withMulticastLock<T>(
  MulticastLock lock,
  Future<T> Function() action,
) async {
  await lock.hold();
  try {
    return await action();
  } finally {
    await lock.release();
  }
}

/// `fp` value to compare with TXT `fp`: the first 16 chars, lowercase, of
/// a fingerprint (or of a prefix) in hex. Separators (`:`, `-`, spaces)
/// are dropped, so a full `3F:9A:...` fingerprint works too.
String fingerprintPrefixOf(String fingerprintHex) {
  final digits = fingerprintHex.toLowerCase().replaceAll(RegExp(r'[\s:-]'), '');
  return digits.length <= fingerprintPrefixLength
      ? digits
      : digits.substring(0, fingerprintPrefixLength);
}

/// Asks the LAN for HaoTranNAS servers for [timeout] and returns every
/// complete, valid one (sorted by instance name; empty when none).
///
/// [transport]: null opens a real [MdnsSocketTransport] and closes it at
/// the end; a given one is left open (the caller owns it).
/// [pinnedFingerprintPrefix]: when given, only servers whose TXT `fp`
/// equals [fingerprintPrefixOf] it are returned.
///
/// Never throws for bad packets (they are skipped). Opening the real
/// socket can throw [SocketException].
Future<List<DiscoveredServer>> discoverServers({
  Duration timeout = const Duration(seconds: 3),
  MdnsTransport? transport,
  String? pinnedFingerprintPrefix,
}) async {
  final ownsTransport = transport == null;
  final link = transport ?? await MdnsSocketTransport.open();
  final collector = _AnswerCollector();
  final askedQuestions = <String>{};

  void ask(List<DnsQuestion> questions) {
    final fresh = [
      for (final question in questions)
        if (askedQuestions.add(
          '${question.type} ${question.name.toLowerCase()}',
        ))
          question,
    ];
    if (fresh.isEmpty) return;
    try {
      link.send(encodeDnsQuery(fresh));
    } on SocketException {
      // Network gone mid-window: keep what was already heard.
    }
  }

  final subscription = link.datagrams.listen((bytes) {
    final message = decodeDns(bytes);
    // Our own queries loop back; only responses carry answers.
    if (message == null || !message.isResponse) return;
    collector.addAll(message.records);
    ask(collector.missingQuestions());
  }, onError: (Object error) {});

  final ptrQuestion = [const DnsQuestion(serviceName, dnsTypePtr)];
  void sendPtrQuery() {
    try {
      link.send(encodeDnsQuery(ptrQuestion));
    } on SocketException {
      // Same as above.
    }
  }

  sendPtrQuery();
  final repeatTimer = timeout > repeatQueryAfter
      ? Timer(repeatQueryAfter, sendPtrQuery)
      : null;
  try {
    await Future<void>.delayed(timeout);
  } finally {
    repeatTimer?.cancel();
    await subscription.cancel();
    if (ownsTransport) link.close();
  }

  final pin = pinnedFingerprintPrefix == null
      ? null
      : fingerprintPrefixOf(pinnedFingerprintPrefix);
  return [
    for (final server in collector.servers())
      if (pin == null || server.fingerprintPrefix == pin) server,
  ];
}

/// Everything heard so far, keyed by lowercase name (DNS names ignore
/// case). A record with TTL 0 (goodbye) removes what it names.
class _AnswerCollector {
  /// lowercase instance name → instance name as announced.
  final _instances = <String, String>{};
  final _services = <String, ({int port, String host})>{};
  final _texts = <String, List<String>>{};
  final _ipv4ByHost = <String, Uint8List>{};

  void addAll(List<DnsRecord> records) {
    for (final record in records) {
      final key = record.name.toLowerCase();
      final isGoodbye = record.ttlSeconds == 0;
      switch (record.type) {
        case dnsTypePtr when key == serviceName:
          final instance = record.target;
          if (instance == null || instance.isEmpty) break;
          if (isGoodbye) {
            _instances.remove(instance.toLowerCase());
          } else {
            _instances[instance.toLowerCase()] = instance;
          }
        case dnsTypeSrv:
          final host = record.target;
          final port = record.port;
          if (isGoodbye) {
            _services.remove(key);
          } else if (host != null &&
              host.isNotEmpty &&
              port != null &&
              port != 0) {
            _services[key] = (port: port, host: host.toLowerCase());
          }
        case dnsTypeTxt:
          if (isGoodbye) {
            _texts.remove(key);
          } else {
            _texts[key] = record.texts;
          }
        case dnsTypeA:
          final address = record.addressBytes;
          if (isGoodbye) {
            _ipv4ByHost.remove(key);
          } else if (address != null && address.length == 4) {
            _ipv4ByHost[key] = address;
          }
        default:
          // AAAA and anything else: spec §13 uses IPv4 only.
          break;
      }
    }
  }

  /// SRV / TXT / A questions for what the known instances still lack.
  List<DnsQuestion> missingQuestions() => [
    for (final entry in _instances.entries) ...[
      if (!_services.containsKey(entry.key))
        DnsQuestion(entry.value, dnsTypeSrv),
      if (!_texts.containsKey(entry.key)) DnsQuestion(entry.value, dnsTypeTxt),
      if (_services[entry.key] case final service?
          when !_ipv4ByHost.containsKey(service.host))
        DnsQuestion(service.host, dnsTypeA),
    ],
  ];

  List<DiscoveredServer> servers() {
    final found = <DiscoveredServer>[];
    for (final MapEntry(key: key, value: instanceName) in _instances.entries) {
      final service = _services[key];
      final texts = _texts[key];
      if (service == null || texts == null) continue;
      final address = _ipv4ByHost[service.host];
      if (address == null) continue;
      final values = parseTxtValues(texts);
      final version = values['v'];
      final fingerprintPrefix = values['fp']?.toLowerCase();
      if (version != '$supportedProtocolVersion') continue;
      if (fingerprintPrefix == null ||
          !_isFingerprintPrefix(fingerprintPrefix)) {
        continue;
      }
      found.add(
        DiscoveredServer(
          instanceName: instanceName,
          ipv4Address: InternetAddress.fromRawAddress(
            address,
            type: InternetAddressType.IPv4,
          ),
          port: service.port,
          fingerprintPrefix: fingerprintPrefix,
          protocolVersion: supportedProtocolVersion,
        ),
      );
    }
    found.sort(
      (first, second) => first.instanceName.compareTo(second.instanceName),
    );
    return found;
  }
}

final _fingerprintPrefixPattern = RegExp(
  '^[0-9a-f]{$fingerprintPrefixLength}\$',
);

bool _isFingerprintPrefix(String value) =>
    _fingerprintPrefixPattern.hasMatch(value);

/// TXT strings → key/value map, RFC 6763 §6.4: the key is everything
/// before the first `=`, compared without case (keys returned lowercase);
/// the first occurrence of a key wins; a string with no `=` is a key with
/// an empty value; an empty key is skipped.
Map<String, String> parseTxtValues(List<String> texts) {
  final values = <String, String>{};
  for (final text in texts) {
    final equalsAt = text.indexOf('=');
    final key = (equalsAt < 0 ? text : text.substring(0, equalsAt))
        .toLowerCase();
    if (key.isEmpty) continue;
    values.putIfAbsent(
      key,
      () => equalsAt < 0 ? '' : text.substring(equalsAt + 1),
    );
  }
  return values;
}
