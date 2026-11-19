/// First screen: not paired → [PairingPage]; paired → [HomeShell].
/// Author: Hao Tran.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app/desktop_providers.dart';
import 'home_shell.dart';
import 'pairing_page.dart';

class AppStart extends ConsumerWidget {
  const AppStart({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) =>
      switch (ref.watch(identityProvider)) {
        AsyncData(value: null) => const PairingPage(),
        AsyncData() => const HomeShell(),
        AsyncError(:final error) => Scaffold(
          body: Center(child: Text('Could not read the pairing: $error')),
        ),
        _ => const Scaffold(body: Center(child: CircularProgressIndicator())),
      };
}
