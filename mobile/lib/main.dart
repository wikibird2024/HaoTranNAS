import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import 'app/app_start.dart';
import 'app/providers.dart';
import 'client/identity.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final identityStore = await IdentityStore.forApp();
  final documents = await getApplicationDocumentsDirectory();
  runApp(
    ProviderScope(
      overrides: [
        identityStoreProvider.overrideWithValue(identityStore),
        restoreFolderProvider.overrideWithValue(
          Directory('${documents.path}/restored'),
        ),
      ],
      child: const HaoTranNasApp(),
    ),
  );
}

/// Material 3, plain Navigator; the first screen is [AppStart].
class HaoTranNasApp extends StatelessWidget {
  const HaoTranNasApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'HaoTranNAS',
    theme: ThemeData(colorSchemeSeed: Colors.teal),
    darkTheme: ThemeData(
      colorSchemeSeed: Colors.teal,
      brightness: Brightness.dark,
    ),
    home: const AppStart(),
  );
}
