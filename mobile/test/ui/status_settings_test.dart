// Status and Settings screens with a fake BackupStatusSource, identity
// and connection; App start choosing Pairing or Status. Author: Hao Tran.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haotrannas_mobile/app/app_start.dart';
import 'package:haotrannas_mobile/app/providers.dart';
import 'package:haotrannas_mobile/ui/backup_status_source.dart';
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
  }) => pumpScreen(
    tester,
    screen,
    isAnimating: isAnimating,
    overrides: [
      backupStatusSourceProvider.overrideWithValue(source),
      identityProvider.overrideWith(() => identity),
      serverConnectionProvider.overrideWith(() => connection),
    ],
  );

  group('status', () {
    testWidgets('shows server id, state, last run; connects on open', (
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

      expect(find.text('Server id $testShortId'), findsOneWidget);
      expect(
        find.text('Not connected: No server address known'),
        findsOneWidget,
      );
      expect(
        find.text(
          '2026-11-19 08:30: 12 uploaded (3.0 MB), 300 already there, '
          '1 failed',
        ),
        findsOneWidget,
      );
      expect(connection.connectCalls, 1);
    });

    testWidgets('"Back up now" and "Verify backup" call the source', (
      tester,
    ) async {
      await pumpWithFakes(tester, const StatusScreen());
      await tester.tap(find.text('Back up now'));
      await tester.tap(find.text('Verify backup'));
      expect(source.runNowCalls, 1);
      expect(source.verifyAllCalls, 1);
    });

    testWidgets('buttons are off while a run is going', (tester) async {
      source.activity = BackupActivity.backingUp;
      await pumpWithFakes(tester, const StatusScreen(), isAnimating: true);
      expect(find.text('Backing up…'), findsOneWidget);
      await tester.tap(find.text('Back up now'));
      expect(source.runNowCalls, 0);
    });

    testWidgets('a refused phone is told to pair again', (tester) async {
      connection = FakeServerConnection(
        const ServerOffline(problem: 'refused', isMaybeNotPaired: true),
      );
      await pumpWithFakes(tester, const StatusScreen());
      expect(find.textContaining('pair again'), findsOneWidget);
    });
  });

  group('settings', () {
    testWidgets('switches change the source settings', (tester) async {
      await pumpWithFakes(tester, const SettingsScreen());
      expect(source.settings.isWifiOnly, isTrue);

      await tester.tap(find.byKey(const Key('settings.wifiOnly')));
      await tester.pumpAndSettle();
      expect(source.settings.isWifiOnly, isFalse);

      await tester.tap(find.byKey(const Key('settings.chargingOnly')));
      await tester.pumpAndSettle();
      expect(source.settings.isChargingOnly, isTrue);

      await tester.tap(find.byKey(const Key('settings.backupOn')));
      await tester.pumpAndSettle();
      expect(source.settings.isBackupOn, isFalse);
      // Each switch changed only its own value.
      expect(source.settings.isWifiOnly, isFalse);
      expect(source.settings.isChargingOnly, isTrue);
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

    testWidgets('identity → Status; unpair from Settings → Pairing', (
      tester,
    ) async {
      await pumpWithFakes(tester, const AppStart());
      expect(find.text('Back up now'), findsOneWidget);

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
