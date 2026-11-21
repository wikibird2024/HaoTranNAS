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
import 'package:flutter/widgets.dart' show AppLifecycleListener;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:haotrannas_client/app/client_providers.dart';
import 'package:haotrannas_client/backup/backup_controller.dart';
import 'package:haotrannas_client/backup/backup_runner.dart';
import 'package:haotrannas_client/backup/backup_state_store.dart';
import 'package:haotrannas_client/backup/backup_status_source.dart';
import 'package:haotrannas_client/discovery/discovery.dart';

import '../backup/background.dart';
import '../backup/gallery.dart';
import '../backup/photo_media_source.dart';
import '../core/discovery/bonjour_finder.dart';
import '../core/transport/multicast_lock.dart';

export 'package:haotrannas_client/app/client_providers.dart';

export '../backup/gallery.dart' show AddToGallery, addToPhoneGallery;

/// Sent in Hello (`client_software`); `main()` puts it in
/// [clientSoftwareProvider], the background job uses it directly.
const appClientSoftware = 'haotrannas-mobile 0.1.0';

/// Moves a restored photo or video into the phone's gallery. Null (tests,
/// not Android) = restored files stay only in the app's folder. `main()`
/// overrides it with [addToPhoneGallery] on Android.
final addToGalleryProvider = Provider<AddToGallery?>((ref) => null);

/// Opens this app's page in the phone's Settings (photo access). Null
/// (tests) = no button. `main()` overrides it with photo_manager's
/// `PhotoManager.openSetting`.
final openAppSettingsProvider = Provider<Future<void> Function()?>(
  (ref) => null,
);

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
  final started = controller.start();
  unawaited(started);
  // iPhone (D-043): no background job, so "automatic" = a run each time
  // the app opens or comes back to the front.
  final lifecycle = Platform.isIOS
      ? AppLifecycleListener(onResume: () => _runIfAutomatic(controller))
      : null;
  if (Platform.isIOS) {
    unawaited(started.then((_) => _runIfAutomatic(controller)));
  }
  ref.onDispose(() {
    lifecycle?.dispose();
    unawaited(controller.stop());
    source.dispose();
    controller.dispose();
  });
  return source;
}

/// Starts a run when automatic backup is on and nothing runs yet.
void _runIfAutomatic(BackupController controller) {
  if (!controller.settings.isBackupOn) return;
  if (controller.activity != BackupActivity.idle) return;
  unawaited(controller.runNow());
}

/// The phone's [ServerFinder]: asks the LAN for servers for 3 s while
/// holding the Wi-Fi multicast lock (foreground only, spec §13). iPhone:
/// the phone's Bonjour instead (D-043). Never throws: no network = empty
/// list.
Future<List<DiscoveredServer>> findServersOnWifi({
  String? pinnedFingerprintPrefix,
}) async {
  if (Platform.isIOS) {
    return findServersWithBonjour(
      pinnedFingerprintPrefix: pinnedFingerprintPrefix,
    );
  }
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
