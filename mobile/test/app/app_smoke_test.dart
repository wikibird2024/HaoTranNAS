import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haotrannas_mobile/app/providers.dart';
import 'package:haotrannas_mobile/main.dart';

import '../ui/ui_fakes.dart';

void main() {
  testWidgets('app starts: not paired → the pairing screen', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          identityProvider.overrideWith(() => FakeIdentityController(null)),
          // The pairing screen searches the Wi-Fi on open.
          serverFinderProvider.overrideWithValue(
            ({pinnedFingerprintPrefix}) async => const [],
          ),
        ],
        child: const HaoTranNasApp(),
      ),
    );
    await tester.pumpAndSettle();

    final app = tester.widget<MaterialApp>(find.byType(MaterialApp));
    expect(app.title, 'HaoTranNAS');
    expect(find.text('Pair with your NAS'), findsOneWidget);
  });
}
