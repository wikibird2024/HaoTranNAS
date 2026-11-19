// The app on fakes: pairing page when not paired; the rail with five
// pages when paired; Backup page folders; NAS page devices and the
// pairing code dialog.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haotrannas_client/backup/backup_status_source.dart';
import 'package:haotrannas_client/client/identity.dart';
import 'package:haotrannas_desktop/admin/admin_controller.dart';
import 'package:haotrannas_desktop/app/desktop_providers.dart';
import 'package:haotrannas_desktop/main.dart';
import 'package:haotrannas_desktop/ui/home_shell.dart';

import '../admin/admin_controller_test.dart'
    show ScriptedChannel, healthyServer;

class FakeBackupSource extends ChangeNotifier implements BackupStatusSource {
  FakeBackupSource(this.folders);

  final List<BackupFolderChoice> folders;
  int runs = 0;

  @override
  BackupActivity activity = BackupActivity.idle;

  @override
  BackupLiveProgress? progress;

  @override
  BackupRunSummary? lastRun;

  @override
  VerifySummary? get lastVerify => null;

  @override
  BackupSettings settings = const BackupSettings();

  @override
  Future<List<BackupFolderChoice>> loadFolders() async => [
    for (final folder in folders)
      if (settings.chosenFolderIds?.contains(folder.id) ?? false) folder,
  ];

  @override
  Future<void> runNow() async {
    runs++;
    activity = BackupActivity.backingUp;
    progress = BackupLiveProgress(
      startedAt: DateTime.now(),
      itemsChecked: 3,
      itemsTotal: 10,
      filesUploaded: 2,
      bytesUploaded: 2048,
      currentPath: 'Documents/a.txt',
    );
    notifyListeners();
  }

  @override
  Future<void> stop() async {
    activity = BackupActivity.idle;
    progress = null;
    notifyListeners();
  }

  @override
  Future<void> updateSettings(BackupSettings settings) async {
    this.settings = settings;
    notifyListeners();
  }

  @override
  Future<void> verifyAll() async {}
}

/// The pairing without file I/O (real I/O never ends inside a widget
/// test's fake time).
class FakeIdentityController extends IdentityController {
  FakeIdentityController(this.identity);

  final DeviceIdentity? identity;

  @override
  Future<DeviceIdentity?> build() async => identity;
}

/// No network in widget tests: connect() only counts.
class FakeServerConnection extends ServerConnectionController {
  int connectCalls = 0;

  @override
  ServerLinkState build() => const ServerOffline();

  @override
  Future<void> connect() async => connectCalls++;

  @override
  Future<void> disconnect() async {}
}

DeviceIdentity testIdentity() => DeviceIdentity(
  deviceId: 3,
  certDer: [1, 2, 3],
  keyPkcs8Der: [4, 5, 6],
  serverCertSha256: List.filled(32, 7),
);

void main() {
  late Directory folder;
  late IdentityStore identityStore;
  late FakeBackupSource backup;
  late ScriptedChannel channel;

  setUp(() {
    folder = Directory.systemTemp.createTempSync('desktop_ui');
    identityStore = IdentityStore(folder);
    backup = FakeBackupSource(const [
      BackupFolderChoice(
        id: '/home/hao/Documents',
        name: 'Documents',
        itemCount: 1234,
        isChosen: true,
      ),
    ]);
    channel = ScriptedChannel(healthyServer());
  });

  tearDown(() => folder.deleteSync(recursive: true));

  Future<void> startApp(
    WidgetTester tester, {
    DeviceIdentity? identity,
    AdminTarget? admin,
  }) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          identityStoreProvider.overrideWithValue(identityStore),
          restoreFolderProvider.overrideWithValue(folder),
          serverFinderProvider.overrideWithValue(
            ({pinnedFingerprintPrefix}) async => const [],
          ),
          backupStatusSourceProvider.overrideWith((ref) => backup),
          serverConnectionProvider.overrideWith(FakeServerConnection.new),
          identityProvider.overrideWith(() => FakeIdentityController(identity)),
          initialAdminTargetProvider.overrideWithValue(admin),
          adminChannelFactoryProvider.overrideWithValue((_) => channel),
        ],
        child: const HaoTranNasDesktop(),
      ),
    );
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('not paired: the pairing page', (tester) async {
    await startApp(tester);
    expect(find.text('Pair this PC with your NAS'), findsOneWidget);
    expect(find.text('Find the NAS'), findsOneWidget);
    expect(find.textContaining('No NAS found'), findsOneWidget);
  });

  testWidgets('paired: rail with five pages, Overview first', (tester) async {
    await startApp(tester, identity: testIdentity());
    for (final page in AppPage.values) {
      expect(find.text(page.label), findsWidgets);
    }
    expect(
      find.text('Server id ${testIdentity().serverShortId}'),
      findsOneWidget,
    );
    expect(find.text('Set up'), findsOneWidget, reason: 'admin not set up');

    await tester.tap(find.text('Back up now').first);
    await tester.pump();
    expect(backup.runs, 1);
    expect(find.text('3 of ~10 files done'), findsOneWidget);
    expect(find.text('Now: Documents/a.txt'), findsOneWidget);
    await tester.tap(find.text('Stop'));
    await tester.pump();
    expect(find.text('Back up now'), findsOneWidget);
  });

  testWidgets('Backup page lists the folders with counts', (tester) async {
    backup.settings = const BackupSettings(
      chosenFolderIds: {'/home/hao/Documents'},
    );
    await startApp(tester, identity: testIdentity());
    await tester.tap(find.text('Backup').first);
    await tester.pumpAndSettle();
    expect(find.text('Documents'), findsOneWidget);
    expect(find.text('/home/hao/Documents'), findsOneWidget);
    expect(find.text('1 234 files'), findsOneWidget);
    expect(find.text('Add folder'), findsOneWidget);

    await tester.tap(find.byType(Switch));
    await tester.pump();
    expect(backup.settings.isBackupOn, isFalse);
  });

  testWidgets('settings loaded after start still show the folders', (
    tester,
  ) async {
    await startApp(tester, identity: testIdentity());
    await tester.tap(find.text('Backup').first);
    await tester.pumpAndSettle();
    expect(find.textContaining('No folders yet'), findsOneWidget);

    // What BackupController.start() does once the saved settings are read.
    await backup.updateSettings(
      const BackupSettings(chosenFolderIds: {'/home/hao/Documents'}),
    );
    await tester.pumpAndSettle();
    expect(find.text('/home/hao/Documents'), findsOneWidget);
    expect(find.text('1 234 files'), findsOneWidget);
  });

  testWidgets('NAS page: devices table and the pairing code', (tester) async {
    channel.replies['pair'] = [
      'code 042317 server-id AAAA-BBBB-CCCC valid 120 s',
    ];
    await startApp(
      tester,
      identity: testIdentity(),
      admin: const AdminOnThisPc('/tmp/htn'),
    );
    await tester.tap(find.text('NAS').first);
    await tester.pumpAndSettle();
    expect(find.text('Reachable · 1 open connections'), findsOneWidget);
    expect(find.text('Android phone'), findsOneWidget);
    expect(find.text('Linux PC'), findsOneWidget);
    expect(find.text('Revoke'), findsNWidgets(2));
    expect(
      find.text('No scrub has finished yet (run scrub-now)'),
      findsNothing,
    );

    await tester.tap(find.text('Pair a new device'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(
      tester.widget<SelectableText>(find.byKey(const Key('pairing.code'))).data,
      '042 317',
    );
    expect(find.text('Server id AAAA-BBBB-CCCC'), findsOneWidget);
    expect(
      find.textContaining(RegExp(r'^Valid for 1[12][0-9] s$')),
      findsOneWidget,
    );
    await tester.tap(find.text('Done'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('Server id AAAA-BBBB-CCCC'), findsNothing);
  });
}
