// Pairing screen with a fake PairingAttempt: happy path, wrong code with
// tries left, MITM, id mismatch, not allowed from this network, search.
// Author: Hao Tran.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haotrannas_mobile/app/providers.dart';
import 'package:haotrannas_mobile/client/identity.dart';
import 'package:haotrannas_mobile/client/pairing.dart';
import 'package:haotrannas_mobile/client/server_address.dart';
import 'package:haotrannas_mobile/discovery/discovery.dart';
import 'package:haotrannas_mobile/ui/pairing_screen.dart';

import 'ui_fakes.dart';

void main() {
  late FakePairingAttempt attempt;
  late List<ServerAddress> openedAddresses;
  late List<DeviceIdentity> saved;
  late int doneCalls;

  Future<void> pumpPairing(
    WidgetTester tester,
    List<PairingResult> results, {
    List<DiscoveredServer> found = const [],
  }) async {
    attempt = FakePairingAttempt(results);
    openedAddresses = [];
    saved = [];
    doneCalls = 0;
    await pumpScreen(
      tester,
      PairingScreen(
        savePairing: (identity) async => saved.add(identity),
        onDone: () => doneCalls++,
      ),
      overrides: [
        pairingOpenerProvider.overrideWithValue((address) async {
          openedAddresses.add(address);
          return attempt;
        }),
        serverFinderProvider.overrideWithValue(
          ({pinnedFingerprintPrefix}) async => found,
        ),
      ],
    );
  }

  Future<void> connectTyped(WidgetTester tester) async {
    await tester.enterText(
      find.byKey(const Key('pairing.address')),
      '192.168.1.5',
    );
    await tester.tap(find.text('Connect'));
    await tester.pumpAndSettle();
  }

  Future<void> confirmIdAndType(WidgetTester tester, String code) async {
    await tester.tap(find.text('Yes, same id'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('pairing.code')), code);
    await tester.tap(find.widgetWithText(FilledButton, 'Pair'));
    await tester.pumpAndSettle();
  }

  testWidgets('happy path: short id shown big, code, paired, Done', (
    tester,
  ) async {
    await pumpPairing(tester, [
      PairingSucceeded(identity: testIdentity(), serverShortId: testShortId),
    ]);
    await connectTyped(tester);

    expect(openedAddresses, [typedAddress]);
    expect(find.text(testShortId), findsOneWidget);
    expect(find.text('Does the NAS show the same id?'), findsOneWidget);

    await confirmIdAndType(tester, '482913');
    expect(attempt.submittedCodes, ['482913']);
    expect(find.text('Paired'), findsOneWidget);
    expect(saved, hasLength(1));
    expect(saved.single.lastAddresses.lastLan, typedAddress);
    expect(doneCalls, 0);

    await tester.tap(find.text('Done'));
    expect(doneCalls, 1);
  });

  testWidgets('wrong code: message with tries left, then the right code', (
    tester,
  ) async {
    await pumpPairing(tester, [
      const PairingFailed(
        PairingFailureKind.badCode,
        'Wrong code. 2 more tries on this connection.',
        attemptsLeft: 2,
      ),
      PairingSucceeded(identity: testIdentity(), serverShortId: testShortId),
    ]);
    await connectTyped(tester);
    await confirmIdAndType(tester, '000000');

    expect(find.text('Wrong code'), findsOneWidget);
    expect(find.textContaining('2 more tries'), findsOneWidget);
    expect(find.byKey(const Key('pairing.code')), findsOneWidget);
    expect(attempt.isClosed, isFalse);

    await tester.enterText(find.byKey(const Key('pairing.code')), '482913');
    await tester.tap(find.widgetWithText(FilledButton, 'Pair'));
    await tester.pumpAndSettle();
    expect(find.text('Paired'), findsOneWidget);
  });

  testWidgets('MITM: warning, connection closed, back to the start', (
    tester,
  ) async {
    await pumpPairing(tester, [
      const PairingFailed(
        PairingFailureKind.serverMismatch,
        'Someone may be in the middle; nothing was saved.',
      ),
    ]);
    await connectTyped(tester);
    await confirmIdAndType(tester, '482913');

    expect(find.text('Possible man-in-the-middle'), findsOneWidget);
    expect(find.textContaining('nothing was saved'), findsOneWidget);
    expect(attempt.isClosed, isTrue);
    expect(saved, isEmpty);
    expect(find.byKey(const Key('pairing.address')), findsOneWidget);
  });

  testWidgets('ids differ: "No, stop" closes without sending a code', (
    tester,
  ) async {
    await pumpPairing(tester, []);
    await connectTyped(tester);
    await tester.tap(find.text('No, stop'));
    await tester.pumpAndSettle();

    expect(find.text('Pairing stopped'), findsOneWidget);
    expect(attempt.isClosed, isTrue);
    expect(attempt.submittedCodes, isEmpty);
  });

  testWidgets('not allowed from this network', (tester) async {
    await pumpPairing(tester, [
      const PairingFailed(
        PairingFailureKind.notAllowedFromNetwork,
        'Join the home Wi-Fi and try again.',
      ),
    ]);
    await connectTyped(tester);
    await confirmIdAndType(tester, '482913');

    expect(find.text('Not allowed from this network'), findsOneWidget);
    expect(find.textContaining('home Wi-Fi'), findsOneWidget);
  });

  testWidgets('bad address text is caught before connecting', (tester) async {
    await pumpPairing(tester, []);
    await tester.enterText(
      find.byKey(const Key('pairing.address')),
      'not an ip:x',
    );
    await tester.tap(find.text('Connect'));
    await tester.pumpAndSettle();
    expect(find.text('Check the address'), findsOneWidget);
    expect(openedAddresses, isEmpty);
  });

  testWidgets('search on Wi-Fi lists a NAS; tapping it connects', (
    tester,
  ) async {
    await pumpPairing(
      tester,
      [],
      found: [
        DiscoveredServer(
          instanceName: 'HaoTranNAS._haotrannas._tcp.local',
          ipv4Address: InternetAddress('192.168.1.9'),
          port: 47100,
          fingerprintPrefix: '3f9ac21b77e00607',
          protocolVersion: 1,
        ),
      ],
    );
    await tester.tap(find.text('Search on Wi-Fi'));
    await tester.pumpAndSettle();
    expect(find.text('HaoTranNAS'), findsOneWidget);
    await tester.tap(find.text('192.168.1.9:47100'));
    await tester.pumpAndSettle();
    expect(openedAddresses, [const ServerAddress('192.168.1.9')]);
    expect(find.text(testShortId), findsOneWidget);
  });
}
