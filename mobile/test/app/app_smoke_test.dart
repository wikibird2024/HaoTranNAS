import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haotrannas_client/client/identity.dart';
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

  testWidgets('pairing unreadable: plain text, Try again reads it again', (
    tester,
  ) async {
    var buildCalls = 0;
    await tester.pumpWidget(
      ProviderScope(
        // No automatic retry, so the error screen stays.
        retry: (_, _) => null,
        overrides: [
          identityProvider.overrideWith(
            () => _FlakyIdentityController(() => ++buildCalls),
          ),
          serverFinderProvider.overrideWithValue(
            ({pinnedFingerprintPrefix}) async => const [],
          ),
        ],
        child: const HaoTranNasApp(),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      find.text('Could not read the pairing on this phone.'),
      findsOneWidget,
    );
    expect(find.text('Exception: disk busy'), findsOneWidget);

    await tester.tap(find.text('Try again'));
    await tester.pumpAndSettle();
    expect(buildCalls, 2);
    expect(find.text('Pair with your NAS'), findsOneWidget);
  });
}

/// Fails the first read, then reads "not paired".
class _FlakyIdentityController extends IdentityController {
  _FlakyIdentityController(this.countBuild);

  final int Function() countBuild;

  @override
  Future<DeviceIdentity?> build() async {
    if (countBuild() == 1) throw Exception('disk busy');
    return null;
  }
}
