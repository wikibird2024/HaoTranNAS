// Status and Settings screens with a fake BackupStatusSource, identity
// and connection; App start choosing Pairing or Status. Author: Hao Tran.
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:haotrannas_client/backup/backup_status_source.dart';
import 'package:haotrannas_client/client/nas_connection.dart';
import 'package:haotrannas_client/protocol/messages.dart';
import 'package:haotrannas_mobile/app/app_start.dart';
import 'package:haotrannas_mobile/app/providers.dart';
import 'package:haotrannas_mobile/ui/folders_screen.dart';
import 'package:haotrannas_mobile/ui/home_screen.dart';
import 'package:haotrannas_mobile/ui/settings_screen.dart';
import 'package:haotrannas_mobile/ui/status_screen.dart';

import 'ui_fakes.dart';

void main() {
  late FakeBackupSource source;
  late FakeIdentityController identity;
  late FakeServerConnection connection;

  setUp(() {
    source = FakeBackupSource();
    identity = FakeIdentityController(testIdentity());
    connection = FakeServerConnection(
      const ServerOffline(problem: 'No server address known'),
    );
  });

  Future<void> pumpWithFakes(
    WidgetTester tester,
    Widget screen, {
    bool isAnimating = false,
    List<Override> extraOverrides = const [],
  }) => pumpScreen(
    tester,
    screen,
    isAnimating: isAnimating,
    overrides: [
      backupStatusSourceProvider.overrideWithValue(source),
      identityProvider.overrideWith(() => identity),
      serverConnectionProvider.overrideWith(() => connection),
      serverFinderProvider.overrideWithValue(
        ({pinnedFingerprintPrefix}) async => const [],
      ),
      ...extraOverrides,
    ],
  );

  group('status', () {
    testWidgets('headline, state + reason, last run; connects on open', (
      tester,
    ) async {
      source.lastRun = BackupRunSummary(
        finishedAt: DateTime(2026, 11, 19, 8, 30),
        filesUploaded: 12,
        filesAlreadyBackedUp: 300,
        filesFailed: 1,
        bytesUploaded: 3 * 1024 * 1024,
      );
      await pumpWithFakes(tester, const StatusScreen());

      expect(find.text('Last backup did not finish'), findsOneWidget);
      expect(find.text('Not connected'), findsOneWidget);
      expect(find.text('No server address known'), findsOneWidget);
      expect(
        find.text(
          '2026-11-19 08:30: 12 uploaded (3.0 MB), 300 already there, '
          '1 failed',
        ),
        findsOneWidget,
      );
      expect(connection.connectCalls, 1);
    });

    testWidgets('a clean last run says "Backed up"; never run says so', (
      tester,
    ) async {
      await pumpWithFakes(tester, const StatusScreen());
      expect(find.text('Not backed up yet'), findsOneWidget);
      expect(find.text('Tap "Back up now" to start.'), findsOneWidget);

      source.lastRun = BackupRunSummary(
        finishedAt: DateTime(2026, 11, 19, 8, 30),
        filesUploaded: 2,
        filesAlreadyBackedUp: 10,
        filesFailed: 0,
        bytesUploaded: 2048,
      );
      source.notifyListeners();
      await tester.pumpAndSettle();
      expect(find.text('Backed up'), findsOneWidget);
    });

    testWidgets('folders card names the chosen albums', (tester) async {
      await source.updateSettings(
        const BackupSettings(
          chosenFolderIds: {'cam', 'wa'},
          chosenFolderNames: ['Camera', 'WhatsApp Images'],
        ),
      );
      await pumpWithFakes(tester, const StatusScreen());
      expect(find.text('Camera, WhatsApp Images'), findsOneWidget);
    });

    testWidgets('a run that stopped early says how many are left', (
      tester,
    ) async {
      source.lastRun = BackupRunSummary(
        finishedAt: DateTime(2026, 11, 19, 8, 30),
        filesUploaded: 5,
        filesAlreadyBackedUp: 0,
        filesFailed: 0,
        bytesUploaded: 0,
        filesLeft: 37,
        problem: 'Time is up for this run; the next run goes on.',
      );
      await pumpWithFakes(tester, const StatusScreen());
      expect(find.text('37 files still to back up'), findsOneWidget);
    });

    testWidgets('automatic backup switch sits on the Backup tab', (
      tester,
    ) async {
      await pumpWithFakes(tester, const StatusScreen());
      expect(find.text('Runs by itself · only on Wi-Fi'), findsOneWidget);
      await tester.tap(find.byKey(const Key('backup.autoOn')));
      await tester.pumpAndSettle();
      expect(source.settings.isBackupOn, isFalse);
      expect(find.text('Off: only "Back up now" backs up'), findsOneWidget);
    });

    testWidgets('"Back up now" and "Check backup" call the source', (
      tester,
    ) async {
      await pumpWithFakes(tester, const StatusScreen());
      await tester.tap(find.text('Back up now'));
      await tester.tap(find.text('Check backup'));
      expect(source.runNowCalls, 1);
      expect(source.verifyAllCalls, 1);
    });

    testWidgets('while a run goes on: live numbers, Stop, no Verify', (
      tester,
    ) async {
      source.activity = BackupActivity.backingUp;
      source.progress = BackupLiveProgress(
        startedAt: DateTime.now().subtract(const Duration(seconds: 10)),
        itemsChecked: 1240,
        itemsTotal: 8300,
        filesUploaded: 35,
        bytesUploaded: 420 * 1024 * 1024,
        currentPath: 'DCIM/Camera/IMG_1.jpg',
      );
      await pumpWithFakes(tester, const StatusScreen(), isAnimating: true);

      expect(find.text('Backing up…'), findsOneWidget);
      expect(find.text('1 240 of ~8 300 files done'), findsOneWidget);
      expect(find.textContaining('35 uploaded · 420.0 MB · '), findsOneWidget);
      expect(find.text('Now: DCIM/Camera/IMG_1.jpg'), findsOneWidget);
      expect(find.text('Back up now'), findsNothing);
      await tester.tap(find.text('Check backup'));
      expect(source.verifyAllCalls, 0);
      await tester.tap(find.text('Stop'));
      expect(source.stopCalls, 1);
    });

    testWidgets('before the first number: "Getting ready…"', (tester) async {
      source.activity = BackupActivity.backingUp;
      await pumpWithFakes(tester, const StatusScreen(), isAnimating: true);
      expect(find.text('Getting ready…'), findsOneWidget);
    });

    testWidgets('a refused phone is told to pair again', (tester) async {
      connection = FakeServerConnection(
        const ServerOffline(problem: 'refused', isMaybeNotPaired: true),
      );
      await pumpWithFakes(tester, const StatusScreen());
      expect(find.textContaining('pair again'), findsOneWidget);
    });
  });

  group('folders', () {
    testWidgets('a tick is saved at once (no Save button)', (tester) async {
      source.folders = const [
        BackupFolderChoice(
          id: 'cam',
          name: 'Camera',
          itemCount: 6200,
          isChosen: true,
        ),
        BackupFolderChoice(
          id: 'shots',
          name: 'Screenshots',
          itemCount: 1800,
          isChosen: false,
        ),
      ];
      await pumpWithFakes(tester, const FoldersScreen());
      await tester.pumpAndSettle();
      expect(find.text('6 200 files'), findsOneWidget);
      expect(find.text('Save'), findsNothing);

      await tester.tap(find.byKey(const Key('folder.shots')));
      await tester.pump();
      expect(source.settings.chosenFolderIds, {'cam', 'shots'});
      expect(source.settings.chosenFolderNames, ['Camera', 'Screenshots']);

      await tester.tap(find.byKey(const Key('folder.cam')));
      await tester.tap(find.byKey(const Key('folder.shots')));
      await tester.pump();
      expect(source.settings.chosenFolderIds, isEmpty);
      expect(find.textContaining('nothing is backed up'), findsOneWidget);
    });

    testWidgets('no albums: open settings, list again on coming back', (
      tester,
    ) async {
      var openSettingsCalls = 0;
      await pumpWithFakes(
        tester,
        const FoldersScreen(),
        extraOverrides: [
          openAppSettingsProvider.overrideWithValue(
            () async => openSettingsCalls++,
          ),
        ],
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('No albums found'), findsOneWidget);

      await tester.tap(find.text('Open phone settings'));
      expect(openSettingsCalls, 1);

      // The user allows access in Settings and comes back to the app.
      source.folders = const [
        BackupFolderChoice(
          id: 'cam',
          name: 'Camera',
          itemCount: 5,
          isChosen: true,
        ),
      ];
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(find.text('Camera'), findsOneWidget);
    });

    testWidgets('no albums, no settings page: only Try again', (tester) async {
      await pumpWithFakes(tester, const FoldersScreen());
      await tester.pumpAndSettle();
      expect(find.text('Open phone settings'), findsNothing);
      expect(find.text('Try again'), findsOneWidget);
    });
  });

  testWidgets('automatic backup on: asks the battery saver once', (
    tester,
  ) async {
    final battery = FakeBatteryExemption(isExemptNow: false);
    await pumpWithFakes(
      tester,
      const StatusScreen(),
      extraOverrides: [batteryExemptionProvider.overrideWithValue(battery)],
    );
    await tester.pumpAndSettle();

    // On → off: no question.
    await tester.tap(find.byKey(const Key('backup.autoOn')));
    await tester.pumpAndSettle();
    expect(source.settings.isBackupOn, isFalse);
    expect(battery.askCalls, 0);

    // Off → on: asks.
    await tester.tap(find.byKey(const Key('backup.autoOn')));
    await tester.pumpAndSettle();
    expect(source.settings.isBackupOn, isTrue);
    expect(battery.askCalls, 1);

    // Already exempt: no question.
    battery.isExemptNow = true;
    await tester.tap(find.byKey(const Key('backup.autoOn')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('backup.autoOn')));
    await tester.pumpAndSettle();
    expect(battery.askCalls, 1);
  });

  testWidgets('home: coming back to the app connects again', (tester) async {
    await pumpWithFakes(tester, const HomeScreen());
    await tester.pumpAndSettle();
    // The Backup tab connects on open.
    expect(connection.connectCalls, 1);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(connection.connectCalls, 2);
  });

  group('settings', () {
    testWidgets('battery tile: Allow asks, then shows allowed', (tester) async {
      final battery = FakeBatteryExemption(isExemptNow: false);
      await pumpWithFakes(
        tester,
        const SettingsScreen(),
        extraOverrides: [batteryExemptionProvider.overrideWithValue(battery)],
      );
      await tester.pumpAndSettle();
      expect(find.text('Battery saver may stop backups'), findsOneWidget);

      await tester.tap(find.byKey(const Key('settings.battery')));
      expect(battery.askCalls, 1);

      // The user allows it in the system dialog and comes back.
      battery.isExemptNow = true;
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(find.text('Battery saver: allowed'), findsOneWidget);
    });

    testWidgets('no battery exemption (iPhone, tests): no tile', (
      tester,
    ) async {
      await pumpWithFakes(tester, const SettingsScreen());
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('settings.battery')), findsNothing);
    });

    testWidgets('the NAS name shows once online', (tester) async {
      await pumpWithFakes(tester, const SettingsScreen());
      expect(find.text('My NAS'), findsOneWidget);

      connection.state = ServerOnline(_NamedConnection('nas-attic'));
      await tester.pumpAndSettle();
      expect(find.text('nas-attic'), findsOneWidget);
      expect(find.text('My NAS'), findsNothing);
    });

    testWidgets('switches change the source settings', (tester) async {
      await pumpWithFakes(tester, const SettingsScreen());
      expect(source.settings.isWifiOnly, isTrue);

      await tester.tap(find.byKey(const Key('settings.wifiOnly')));
      await tester.pumpAndSettle();
      expect(source.settings.isWifiOnly, isFalse);

      await tester.tap(find.byKey(const Key('settings.chargingOnly')));
      await tester.pumpAndSettle();
      expect(source.settings.isChargingOnly, isTrue);

      // Each switch changed only its own value.
      expect(source.settings.isWifiOnly, isFalse);
      expect(source.settings.isBackupOn, isTrue);
      expect(
        find.text('Server id $testShortId · this phone is device 3'),
        findsOneWidget,
      );
    });

    testWidgets('iPhone: no Wi-Fi/charging switches, says when it runs', (
      tester,
    ) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      try {
        await pumpWithFakes(tester, const SettingsScreen());
        expect(find.text('Runs while the app is open'), findsOneWidget);
        expect(find.byKey(const Key('settings.wifiOnly')), findsNothing);

        await pumpWithFakes(tester, const StatusScreen());
        expect(find.text('Each time you open the app'), findsOneWidget);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });

    testWidgets('unpair asks first; Cancel keeps the pairing', (tester) async {
      await pumpWithFakes(tester, const SettingsScreen());
      await tester.tap(find.text('Unpair this phone'));
      await tester.pumpAndSettle();
      expect(find.text('Unpair this phone?'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(identity.unpairCalls, 0);

      await tester.tap(find.text('Unpair this phone'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Unpair'));
      await tester.pumpAndSettle();
      expect(identity.unpairCalls, 1);
    });
  });

  group('app start', () {
    testWidgets('no identity → Pairing', (tester) async {
      identity = FakeIdentityController(null);
      await pumpWithFakes(tester, const AppStart());
      expect(find.text('Pair with your NAS'), findsOneWidget);
    });

    testWidgets('identity → Home tabs; unpair from Settings → Pairing', (
      tester,
    ) async {
      await pumpWithFakes(tester, const AppStart());
      expect(find.text('Back up now'), findsOneWidget);
      expect(find.byType(NavigationDestination), findsNWidgets(3));

      await tester.tap(find.text('Files'));
      await tester.pumpAndSettle();
      expect(find.text('Files on the NAS'), findsOneWidget);
      expect(find.text('Back up now'), findsNothing, reason: 'other tab');

      await tester.tap(find.text('Settings'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Unpair this phone'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Unpair'));
      await tester.pumpAndSettle();
      expect(find.text('Pair with your NAS'), findsOneWidget);
    });
  });
}

/// Online with a name and nothing else: Settings reads only [helloOk].
class _NamedConnection implements NasConnection {
  _NamedConnection(String serverName)
    : helloOk = HelloOk(
        protocolVersion: 1,
        serverSoftware: 'test',
        serverName: serverName,
        deviceId: 3,
        chunkSizeBytes: 1 << 20,
        maxFrameLengthBytes: 1 << 22,
      );

  @override
  final HelloOk helloOk;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
