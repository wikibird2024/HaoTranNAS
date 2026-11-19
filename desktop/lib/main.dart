/// HaoTranNAS PC app (M7, D-039): backs up PC folders, browses and
/// restores, and manages the NAS over its admin socket. Author: Hao Tran.
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:haotrannas_client/backup/backup_state_store.dart';
import 'package:haotrannas_client/client/identity.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'admin/admin_controller.dart';
import 'app/desktop_providers.dart';
import 'ui/app_start.dart';
import 'ui/theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  final identityStore = await IdentityStore.forApp();
  final backupStore = await SqfliteBackupStateStore.openForApp(
    databaseFactoryFfi,
  );
  final adminTarget = decodeAdminTarget(
    await backupStore.readValue(adminTargetValueName),
  );
  final home = Platform.environment['HOME'] ?? '.';
  final downloads = await getDownloadsDirectory() ?? Directory(home);
  runApp(
    ProviderScope(
      overrides: [
        identityStoreProvider.overrideWithValue(identityStore),
        clientSoftwareProvider.overrideWithValue(appClientSoftware),
        restoreFolderProvider.overrideWithValue(
          Directory('${downloads.path}/HaoTranNAS restored'),
        ),
        backupStatusSourceProvider.overrideWith(
          (ref) => desktopBackupStatusSource(ref, backupStore),
        ),
        initialAdminTargetProvider.overrideWithValue(adminTarget),
        saveAdminTargetProvider.overrideWithValue(
          (target) => backupStore.writeValue(
            adminTargetValueName,
            encodeAdminTarget(target),
          ),
        ),
      ],
      child: const HaoTranNasDesktop(),
    ),
  );
}

class HaoTranNasDesktop extends StatelessWidget {
  const HaoTranNasDesktop({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'HaoTranNAS',
    debugShowCheckedModeBanner: false,
    theme: appTheme(Brightness.light),
    darkTheme: appTheme(Brightness.dark),
    home: const AppStart(),
  );
}
