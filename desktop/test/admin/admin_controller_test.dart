// AdminController on a scripted channel: refresh, unreachable, pair,
// revoke, scrub progress, cleanup, problems shown.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haotrannas_desktop/admin/admin_codec.dart';
import 'package:haotrannas_desktop/admin/admin_controller.dart';
import 'package:haotrannas_desktop/admin/admin_link.dart';

/// Answers commands from a map; a missing command = link failure.
class ScriptedChannel implements AdminChannel {
  ScriptedChannel(this.replies);

  final Map<String, List<String>> replies;
  final sent = <String>[];
  List<int> progressToSend = const [];
  bool isClosed = false;

  @override
  Future<List<String>> send(
    String command, {
    void Function(int chunksChecked)? onProgress,
  }) async {
    sent.add(command);
    final reply = replies[command];
    if (reply == null) throw const AdminLinkFailed('No server answers.');
    progressToSend.forEach(onProgress ?? (_) {});
    return reply;
  }

  @override
  Future<void> close() async => isClosed = true;
}

const devicesReply = [
  '1 Android phone paired 1795069400492',
  '2 Linux PC paired 1795073404549',
  'ok 2 devices',
];

Map<String, List<String>> healthyServer() => {
  'status': ['ok 1 connections'],
  'devices': [...devicesReply],
  'scrub-report': ['error no scrub has finished yet (run scrub-now)'],
};

void main() {
  late ScriptedChannel channel;
  late ProviderContainer container;
  final saved = <AdminTarget>[];

  ProviderContainer makeContainer({AdminTarget? initial}) => ProviderContainer(
    overrides: [
      initialAdminTargetProvider.overrideWithValue(initial),
      saveAdminTargetProvider.overrideWithValue(
        (target) async => saved.add(target),
      ),
      adminChannelFactoryProvider.overrideWithValue((_) => channel),
    ],
  );

  setUp(() {
    saved.clear();
    channel = ScriptedChannel(healthyServer());
  });

  tearDown(() => container.dispose());

  test('not set up: nothing is sent', () {
    container = makeContainer();
    expect(container.read(adminProvider).reach, isA<AdminNotSetUp>());
    expect(channel.sent, isEmpty);
  });

  test('setTarget saves, then status, devices and scrub report', () async {
    container = makeContainer();
    await container
        .read(adminProvider.notifier)
        .setTarget(const AdminOnThisPc('/tmp/htn'));
    final state = container.read(adminProvider);
    expect(saved.single.dataDirectory, '/tmp/htn');
    expect(channel.sent, ['status', 'devices', 'scrub-report']);
    expect((state.reach as AdminReachable).openConnections, 1);
    expect(state.devices!.map((device) => device.name), [
      'Android phone',
      'Linux PC',
    ]);
    expect(state.lastScrub, isNull);
    expect(state.scrubNote, contains('no scrub has finished yet'));
  });

  test('a saved target is checked at start', () async {
    container = makeContainer(initial: const AdminOnThisPc('/tmp/htn'));
    expect(container.read(adminProvider).reach, isA<AdminChecking>());
    await pumpEventQueue();
    expect(container.read(adminProvider).isReachable, isTrue);
  });

  test('link failure: unreachable with the message', () async {
    channel = ScriptedChannel({});
    container = makeContainer();
    await container
        .read(adminProvider.notifier)
        .setTarget(const AdminOverSsh('hao@nas', '/srv/haotrannas'));
    final reach = container.read(adminProvider).reach;
    expect((reach as AdminUnreachable).message, 'No server answers.');
    final code = await container
        .read(adminProvider.notifier)
        .createPairingCode();
    expect(code, isA<AdminFailed<PairingCode>>());
  });

  test('pair, revoke (devices reloaded), revoke error shown', () async {
    container = makeContainer();
    final notifier = container.read(adminProvider.notifier);
    await notifier.setTarget(const AdminOnThisPc('/tmp/htn'));
    channel.replies['pair'] = [
      'code 123456 server-id AAAA-BBBB-CCCC valid 120 s',
    ];
    final code = await notifier.createPairingCode();
    expect((code as AdminOk<PairingCode>).value.code, '123456');

    channel.replies['revoke 2'] = ['ok revoked device 2'];
    channel.replies['devices'] = [
      devicesReply[0],
      '2 Linux PC paired 1795073404549 revoked 1795080000000',
      'ok 2 devices',
    ];
    channel.sent.clear();
    await notifier.revoke(2);
    expect(channel.sent, ['revoke 2', 'devices']);
    expect(container.read(adminProvider).devices![1].isRevoked, isTrue);

    channel.replies['revoke 9'] = ['error no device 9'];
    await notifier.revoke(9);
    expect(container.read(adminProvider).actionProblem, 'Revoke: no device 9');
  });

  test('scrub shows progress, then the report; cleanup summary', () async {
    container = makeContainer();
    final notifier = container.read(adminProvider.notifier);
    await notifier.setTarget(const AdminOnThisPc('/tmp/htn'));
    final seen = <int?>[];
    container.listen(
      adminProvider.select((state) => state.scrubChunksChecked),
      (_, next) => seen.add(next),
    );
    channel
      ..progressToSend = [256, 512]
      ..replies['scrub-now'] = [
        'ok scrub chunks_checked 600 bytes_checked 9 bad_found 0 missing 0 '
            'repaired 0 started_at_ms 1 duration_ms 2',
      ]
      ..replies['cleanup-now'] = [
        'ok cleanup expired_uploads 0 tmp_files 1 unused_chunks 2 '
            'orphan_files 0 orphan_pass no duration_ms 3',
      ];
    await notifier.scrubNow();
    expect(seen, [0, 256, 512, null]);
    expect(container.read(adminProvider).lastScrub!.chunksChecked, 600);

    await notifier.cleanupNow();
    final state = container.read(adminProvider);
    expect(state.isCleaning, isFalse);
    expect(state.lastCleanup!.unusedChunks, 2);
  });
}
