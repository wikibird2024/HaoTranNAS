/// The phone's providers: the shared ones (`client_providers.dart` in
/// dart_client, re-exported here) plus the phone-only parts: the Wi-Fi
/// multicast lock around mDNS, the photo backup with workmanager jobs,
/// adding restored photos to the gallery.
///
/// `main()` overrides [identityStoreProvider], [restoreFolderProvider],
/// [clientSoftwareProvider], [serverFinderProvider] and
/// [backupStatusSourceProvider]. Author: Hao Tran.
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:haotrannas_client/app/client_providers.dart';
import 'package:haotrannas_client/backup/backup_controller.dart';
import 'package:haotrannas_client/backup/backup_runner.dart';
import 'package:haotrannas_client/backup/backup_state_store.dart';
import 'package:haotrannas_client/backup/backup_status_source.dart';
import 'package:haotrannas_client/client/download_engine.dart';
import 'package:haotrannas_client/discovery/discovery.dart';

import '../backup/background.dart';
import '../backup/photo_media_source.dart';
import '../core/transport/multicast_lock.dart';

export 'package:haotrannas_client/app/client_providers.dart';

/// Sent in Hello (`client_software`); `main()` puts it in
/// [clientSoftwareProvider], the background job uses it directly.
const appClientSoftware = 'haotrannas-mobile 0.1.0';

/// Adds a restored file to the phone's gallery. Null = files stay only
/// in the app's folder. ⚪ Android MediaStore insertion is phone-only
/// work, not written yet (see `AddToGallery`).
final addToGalleryProvider = Provider<AddToGallery?>((ref) => null);

/// The real backup side over [store]; `main()` overrides
/// [backupStatusSourceProvider] with it. Foreground runs may use mDNS;
/// the background job uses cached addresses only (D-012).
BackupStatusSource appBackupStatusSource(Ref ref, BackupStateStore store) {
  final log = ref.read(sessionLogProvider);
  final controller = BackupController(
    runner: BackupRunner(
      mediaSource: PhotoManagerMediaSource(),
      stateStore: store,
      connect: () => connectForBackup(ref),
    ),
    stateStore: store,
    scheduler: WorkmanagerBackupScheduler(
      clientSoftware: appClientSoftware,
      deviceName: ref.read(deviceNameProvider),
    ),
    manualLauncher: Platform.isAndroid
        ? WorkmanagerManualBackupLauncher(
            clientSoftware: appClientSoftware,
            deviceName: ref.read(deviceNameProvider),
          )
        : null,
    log: log.note,
  );
  final source = BackupControllerStatusSource(controller);
  unawaited(controller.start());
  ref.onDispose(() {
    unawaited(controller.stop());
    source.dispose();
    controller.dispose();
  });
  return source;
}

/// The phone's [ServerFinder]: asks the LAN for servers for 3 s while
/// holding the Wi-Fi multicast lock (foreground only, spec §13). Without
/// the lock (not Android) it tries anyway. Never throws: no network =
/// empty list.
Future<List<DiscoveredServer>> findServersOnWifi({
  String? pinnedFingerprintPrefix,
}) async {
  Future<List<DiscoveredServer>> discover() =>
      discoverServers(pinnedFingerprintPrefix: pinnedFingerprintPrefix);
  try {
    try {
      return await withMulticastLock(MulticastLock(), discover);
    } on MissingPluginException {
      return await discover();
    } on PlatformException {
      return await discover();
    }
  } on SocketException {
    return const [];
  }
}
