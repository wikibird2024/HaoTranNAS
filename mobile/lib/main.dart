import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:haotrannas_client/backup/backup_state_store.dart';
import 'package:haotrannas_client/client/identity.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart' show databaseFactory;

import 'app/app_start.dart';
import 'app/providers.dart';
import 'backup/background.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final identityStore = await IdentityStore.forApp();
  final documents = await getApplicationDocumentsDirectory();
  final backupStore = await SqfliteBackupStateStore.openForApp(databaseFactory);
  await initializeBackgroundBackup();
  runApp(
    ProviderScope(
      overrides: [
        identityStoreProvider.overrideWithValue(identityStore),
        clientSoftwareProvider.overrideWithValue(appClientSoftware),
        serverFinderProvider.overrideWithValue(findServersOnWifi),
        restoreFolderProvider.overrideWithValue(
          Directory('${documents.path}/restored'),
        ),
        backupStatusSourceProvider.overrideWith(
          (ref) => appBackupStatusSource(ref, backupStore),
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
