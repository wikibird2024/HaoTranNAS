/// First screen: not paired → Pairing; paired → Home (3 tabs). After pairing
/// the identity is saved at once; the switch to Home waits for the
/// user's "Done". Author: Hao Tran.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../ui/pairing_screen.dart';
import '../ui/home_screen.dart';
import 'providers.dart';

class AppStart extends ConsumerWidget {
  const AppStart({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final identity = ref.watch(identityProvider);
    return switch (identity) {
      AsyncData(value: null) => PairingScreen(
        savePairing: (paired) => ref.read(identityStoreProvider).save(paired),
        onDone: () => ref.invalidate(identityProvider),
      ),
      AsyncData() => const HomeScreen(),
      AsyncError(:final error) => Scaffold(
        body: Center(child: Text('Could not read the pairing: $error')),
      ),
      _ => const Scaffold(body: Center(child: CircularProgressIndicator())),
    };
  }
}
