// discoverServers over a fake MdnsTransport. Fixture packets are built
// with the codec's own encoder (protocol/fixtures/mdns_announcement.hex
// did not exist when this was written).
import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haotrannas_mobile/core/transport/multicast_lock.dart';
import 'package:haotrannas_mobile/discovery/discovery.dart';
import 'package:haotrannas_mobile/discovery/dns_codec.dart';

/// Records what discovery sends and lets the test answer.
class FakeMdnsTransport implements MdnsTransport {
  final _datagrams = StreamController<Uint8List>.broadcast();
  final sentQueries = <DnsMessage>[];
  bool isClosed = false;

  /// Called (as a microtask) for each query sent; may [deliver] answers.
  void Function(DnsMessage query)? onQuery;

  @override
  Stream<Uint8List> get datagrams => _datagrams.stream;

  @override
  void send(Uint8List bytes) {
    final query = decodeDns(bytes)!;
    sentQueries.add(query);
    // Like the real socket: our own multicast query comes back to us.
    scheduleMicrotask(() {
      deliver(bytes);
      onQuery?.call(query);
    });
  }

  void deliver(Uint8List bytes) => _datagrams.add(bytes);

  @override
  void close() => isClosed = true;

  List<String> get askedQuestions => [
    for (final query in sentQueries)
      for (final question in query.questions)
        '${dnsTypeNames[question.type]} ${question.name}',
  ];
}

const shortTimeout = Duration(milliseconds: 60);
const fingerprint = '3f9ac21b77e01234';
const otherFingerprint = 'aaaabbbbccccdddd';

String instanceOf(String label) => '$label.$serviceName';

DnsRecord ptrRecord(String instance, {int ttlSeconds = 4500}) => DnsRecord(
  name: serviceName,
  type: dnsTypePtr,
  ttlSeconds: ttlSeconds,
  target: instance,
);

DnsRecord srvRecord(
  String instance,
  String host,
  int port, {
  DnsSection section = DnsSection.additional,
}) => DnsRecord(
  name: instance,
  type: dnsTypeSrv,
  ttlSeconds: 120,
  section: section,
  target: host,
  port: port,
);

DnsRecord txtRecord(
  String instance,
  List<String> texts, {
  DnsSection section = DnsSection.additional,
}) => DnsRecord(
  name: instance,
  type: dnsTypeTxt,
  ttlSeconds: 4500,
  section: section,
  texts: texts,
);

DnsRecord aRecord(
  String host,
  List<int> address, {
  DnsSection section = DnsSection.additional,
}) => DnsRecord(
  name: host,
  type: dnsTypeA,
  ttlSeconds: 120,
  section: section,
  addressBytes: Uint8List.fromList(address),
);

DnsRecord aaaaRecord(String host) => DnsRecord(
  name: host,
  type: dnsTypeAaaa,
  ttlSeconds: 120,
  section: DnsSection.additional,
  addressBytes: Uint8List.fromList([0xfe, 0x80, ...List.filled(13, 0), 7]),
);

Uint8List responsePacket(List<DnsRecord> records) =>
    encodeDnsMessage(DnsMessage(isResponse: true, records: records));

/// What the server sends for a PTR query: everything in one packet.
Uint8List announcement({
  String label = 'HaoTranNAS',
  String host = 'haotrannas.local',
  int port = 7443,
  List<int> address = const [192, 168, 1, 10],
  List<String>? texts,
}) {
  final instance = instanceOf(label);
  return responsePacket([
    ptrRecord(instance),
    srvRecord(instance, host, port),
    txtRecord(instance, texts ?? ['v=1', 'fp=$fingerprint']),
    aRecord(host, address),
    aaaaRecord(host),
  ]);
}

/// Answers every PTR query with [packets].
FakeMdnsTransport answeringWith(List<Uint8List> packets) {
  final transport = FakeMdnsTransport();
  transport.onQuery = (query) {
    if (query.questions.any((question) => question.type == dnsTypePtr)) {
      packets.forEach(transport.deliver);
    }
  };
  return transport;
}

Future<List<DiscoveredServer>> discoverWithTexts(List<String> texts) =>
    discoverServers(
      timeout: shortTimeout,
      transport: answeringWith([announcement(texts: texts)]),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'one announcement (PTR + SRV + TXT + A + AAAA) → one server, IPv4 only',
    () async {
      final transport = answeringWith([announcement()]);
      final servers = await discoverServers(
        timeout: shortTimeout,
        transport: transport,
      );

      final server = servers.single;
      expect(server.instanceName, 'HaoTranNAS._haotrannas._tcp.local');
      expect(server.ipv4Address, InternetAddress('192.168.1.10'));
      expect(server.ipv4Address.type, InternetAddressType.IPv4);
      expect(
        (server.port, server.fingerprintPrefix, server.protocolVersion),
        (7443, fingerprint, 1),
      );

      final firstQuery = transport.sentQueries.first;
      expect((firstQuery.id, firstQuery.isResponse), (0, false));
      expect(firstQuery.questions.single.name, serviceName);
      expect(firstQuery.questions.single.type, dnsTypePtr);
      expect(firstQuery.questions.single.wantsUnicast, isFalse);
      // Nothing was missing, so no follow-up questions.
      expect(transport.askedQuestions, ['PTR $serviceName']);
      // An injected transport belongs to the caller.
      expect(transport.isClosed, isFalse);
    },
  );

  test('answers split across 3 packets are merged', () async {
    final instance = instanceOf('HaoTranNAS');
    final servers = await discoverServers(
      timeout: shortTimeout,
      transport: answeringWith([
        responsePacket([ptrRecord(instance)]),
        responsePacket([
          srvRecord(instance, 'nas.local', 7443, section: DnsSection.answer),
          txtRecord(instance, [
            'v=1',
            'fp=$fingerprint',
          ], section: DnsSection.answer),
        ]),
        responsePacket([
          aRecord('NAS.local', [10, 0, 0, 2], section: DnsSection.answer),
        ]),
      ]),
    );
    expect(servers.single.ipv4Address.address, '10.0.0.2');
    expect(servers.single.port, 7443);
  });

  test('PTR alone → asks SRV and TXT, then A, and finds the server', () async {
    final instance = instanceOf('HaoTranNAS');
    final transport = FakeMdnsTransport();
    transport.onQuery = (query) {
      for (final question in query.questions) {
        final answer = switch (question.type) {
          dnsTypePtr => ptrRecord(instance),
          dnsTypeSrv => srvRecord(
            instance,
            'nas.local',
            7443,
            section: DnsSection.answer,
          ),
          dnsTypeTxt => txtRecord(instance, [
            'v=1',
            'fp=$fingerprint',
          ], section: DnsSection.answer),
          dnsTypeA => aRecord('nas.local', [
            192,
            168,
            0,
            9,
          ], section: DnsSection.answer),
          _ => null,
        };
        if (answer != null) transport.deliver(responsePacket([answer]));
      }
    };

    final servers = await discoverServers(
      timeout: shortTimeout,
      transport: transport,
    );

    expect(servers.single.ipv4Address.address, '192.168.0.9');
    expect(transport.askedQuestions, [
      'PTR $serviceName',
      'SRV $instance',
      'TXT $instance',
      'A nas.local',
    ]);
  });

  group('TXT', () {
    test('missing fp → dropped', () async {
      expect(await discoverWithTexts(['v=1']), isEmpty);
    });

    test('v=2 → dropped, missing v → dropped', () async {
      expect(await discoverWithTexts(['v=2', 'fp=$fingerprint']), isEmpty);
      expect(await discoverWithTexts(['fp=$fingerprint']), isEmpty);
    });

    test('fp= empty, fp too short or not hex → dropped', () async {
      expect(await discoverWithTexts(['v=1', 'fp=']), isEmpty);
      expect(await discoverWithTexts(['v=1', 'fp=3f9a']), isEmpty);
      expect(await discoverWithTexts(['v=1', 'fp=3f9ac21b77e0123z']), isEmpty);
    });

    test('duplicate keys: the first one wins (RFC 6763 §6.4)', () async {
      final servers = await discoverWithTexts([
        'v=1',
        'fp=$fingerprint',
        'v=2',
        'fp=$otherFingerprint',
      ]);
      expect(servers.single.fingerprintPrefix, fingerprint);
      expect(
        await discoverWithTexts(['v=2', 'v=1', 'fp=$fingerprint']),
        isEmpty,
      );
    });

    test(
      'keys ignore case, fp is read lowercase, extra keys ignored',
      () async {
        final servers = await discoverWithTexts([
          'V=1',
          'FP=${fingerprint.toUpperCase()}',
          'name=box',
          'flag',
        ]);
        expect(servers.single.fingerprintPrefix, fingerprint);
      },
    );

    test('binary garbage in TXT → dropped, no throw', () async {
      final packet = announcement(texts: ['v=1', 'fp=XXXXXXXXXXXXXXXX']);
      // Overwrite the 16 X's with bytes that are not UTF-8.
      final start = String.fromCharCodes(packet).indexOf('X' * 16);
      for (var index = 0; index < 16; index++) {
        packet[start + index] = 0x80 + index;
      }
      final servers = await discoverServers(
        timeout: shortTimeout,
        transport: answeringWith([packet]),
      );
      expect(servers, isEmpty);
    });

    test('parseTxtValues', () {
      expect(parseTxtValues(['v=1', 'FP=ab=cd', 'flag', '=nokey', 'v=2']), {
        'v': '1',
        'fp': 'ab=cd',
        'flag': '',
      });
    });
  });

  group('pinned fingerprint', () {
    final twoServers = [
      announcement(
        label: 'Home',
        host: 'home.local',
        address: [192, 168, 1, 10],
      ),
      announcement(
        label: 'Office',
        host: 'office.local',
        address: [192, 168, 1, 20],
        texts: ['v=1', 'fp=$otherFingerprint'],
      ),
    ];

    test('keeps only the matching server', () async {
      final servers = await discoverServers(
        timeout: shortTimeout,
        transport: answeringWith(twoServers),
        pinnedFingerprintPrefix: otherFingerprint,
      );
      expect(servers.single.instanceName, instanceOf('Office'));
    });

    test('a full fingerprint, uppercase with colons, also matches', () async {
      final fullFingerprint = [
        for (var index = 0; index < 64; index += 2)
          ('${fingerprint}00112233445566778899aabbccddeeff00112233445566778899aabb')
              .substring(index, index + 2),
      ].join(':').toUpperCase();
      final servers = await discoverServers(
        timeout: shortTimeout,
        transport: answeringWith(twoServers),
        pinnedFingerprintPrefix: fullFingerprint,
      );
      expect(servers.single.instanceName, instanceOf('Home'));
    });

    test('no match → empty', () async {
      final servers = await discoverServers(
        timeout: shortTimeout,
        transport: answeringWith(twoServers),
        pinnedFingerprintPrefix: '0000000000000000',
      );
      expect(servers, isEmpty);
    });

    test('no pin → both servers, sorted by name, each once', () async {
      // Each one announces twice: still one result per instance.
      final servers = await discoverServers(
        timeout: shortTimeout,
        transport: answeringWith([...twoServers, ...twoServers]),
      );
      expect(servers.map((server) => server.instanceName), [
        instanceOf('Home'),
        instanceOf('Office'),
      ]);
      expect(servers.map((server) => server.ipv4Address.address), [
        '192.168.1.10',
        '192.168.1.20',
      ]);
    });
  });

  test('AAAA only (no A) → dropped', () async {
    final instance = instanceOf('HaoTranNAS');
    final servers = await discoverServers(
      timeout: shortTimeout,
      transport: answeringWith([
        responsePacket([
          ptrRecord(instance),
          srvRecord(instance, 'nas.local', 7443),
          txtRecord(instance, ['v=1', 'fp=$fingerprint']),
          aaaaRecord('nas.local'),
        ]),
      ]),
    );
    expect(servers, isEmpty);
  });

  test('malformed packets are skipped, the good one still counts', () async {
    final good = announcement();
    final servers = await discoverServers(
      timeout: shortTimeout,
      transport: answeringWith([
        Uint8List(0),
        Uint8List.fromList([0xff, 0xff, 0xff]),
        Uint8List.sublistView(good, 0, good.length - 3),
        Uint8List.fromList([
          0,
          0,
          0x84,
          0,
          0,
          1,
          0,
          0,
          0,
          0,
          0,
          0,
          0xc0,
          12,
          0,
          1,
          0,
          1,
        ]),
        good,
      ]),
    );
    expect(servers.single.port, 7443);
  });

  test('records for another service are ignored', () async {
    const otherService = '_http._tcp.local';
    final servers = await discoverServers(
      timeout: shortTimeout,
      transport: answeringWith([
        responsePacket([
          const DnsRecord(
            name: otherService,
            type: dnsTypePtr,
            ttlSeconds: 120,
            target: 'Web.$otherService',
          ),
          srvRecord('Web.$otherService', 'web.local', 80),
          txtRecord('Web.$otherService', ['v=1', 'fp=$fingerprint']),
          aRecord('web.local', [192, 168, 1, 30]),
        ]),
      ]),
    );
    expect(servers, isEmpty);
  });

  test('goodbye (PTR with TTL 0) removes the server', () async {
    final servers = await discoverServers(
      timeout: shortTimeout,
      transport: answeringWith([
        announcement(),
        responsePacket([ptrRecord(instanceOf('HaoTranNAS'), ttlSeconds: 0)]),
      ]),
    );
    expect(servers, isEmpty);
  });

  test('timeout returns what was found by then; nothing → empty', () async {
    final complete = announcement(label: 'Home', host: 'home.local');
    final incomplete = responsePacket([ptrRecord(instanceOf('Half'))]);
    final stopwatch = Stopwatch()..start();
    final servers = await discoverServers(
      timeout: const Duration(milliseconds: 150),
      transport: answeringWith([complete, incomplete]),
    );
    expect(
      stopwatch.elapsed,
      greaterThanOrEqualTo(const Duration(milliseconds: 150)),
    );
    expect(servers.single.instanceName, instanceOf('Home'));

    final silent = FakeMdnsTransport();
    expect(
      await discoverServers(timeout: shortTimeout, transport: silent),
      isEmpty,
    );
    expect(silent.askedQuestions, ['PTR $serviceName']);
  });

  test('the PTR query is sent again after 1 s', () async {
    final silent = FakeMdnsTransport();
    await discoverServers(
      timeout: const Duration(milliseconds: 1100),
      transport: silent,
    );
    expect(silent.askedQuestions, ['PTR $serviceName', 'PTR $serviceName']);
  });

  group('withMulticastLock', () {
    final calls = <Object?>[];
    setUp(() {
      calls.clear();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel(MulticastLock.channelName),
            (call) async {
              calls.add(call.arguments);
              return null;
            },
          );
    });

    test('holds, runs, releases, returns the result', () async {
      final result = await withMulticastLock(MulticastLock(), () async {
        calls.add('action');
        return 5;
      });
      expect(result, 5);
      expect(calls, [
        {'hold': true},
        'action',
        {'hold': false},
      ]);
    });

    test('releases when the action throws', () async {
      await expectLater(
        withMulticastLock<void>(
          MulticastLock(),
          () async => throw StateError('boom'),
        ),
        throwsStateError,
      );
      expect(calls, [
        {'hold': true},
        {'hold': false},
      ]);
    });

    test(
      'hold fails → action does not run, error goes to the caller',
      () async {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(
              const MethodChannel(MulticastLock.channelName),
              (call) async => throw PlatformException(code: 'no_wifi'),
            );
        var didRun = false;
        await expectLater(
          withMulticastLock(MulticastLock(), () async => didRun = true),
          throwsA(isA<PlatformException>()),
        );
        expect(didRun, isFalse);
      },
    );
  });
}
