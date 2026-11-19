// Fakes for the widget tests: identity, connection, backup source,
// remote files, pairing attempt, and a helper that pumps a screen inside
// a ProviderScope. Author: Hao Tran.
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:haotrannas_mobile/app/providers.dart';
import 'package:haotrannas_mobile/client/download_engine.dart';
import 'package:haotrannas_mobile/client/identity.dart';
import 'package:haotrannas_mobile/client/pairing.dart';
import 'package:haotrannas_mobile/client/server_address.dart';
import 'package:haotrannas_mobile/protocol/messages.dart';
import 'package:haotrannas_mobile/ui/backup_status_source.dart';
import 'package:haotrannas_mobile/ui/pairing_screen.dart';

/// Fingerprint whose short id is `3F9A-C21B-77E0`.
final testServerFingerprint = [
  0x3F, 0x9A, 0xC2, 0x1B, 0x77, 0xE0, //
  for (var index = 6; index < 32; index++) index,
];

const testShortId = '3F9A-C21B-77E0';

DeviceIdentity testIdentity() => DeviceIdentity(
  deviceId: 3,
  certDer: [1, 2, 3],
  keyPkcs8Der: [4, 5, 6],
  serverCertSha256: testServerFingerprint,
);

class FakeIdentityController extends IdentityController {
  FakeIdentityController(this.identity);

  final DeviceIdentity? identity;
  int unpairCalls = 0;

  @override
  Future<DeviceIdentity?> build() async => identity;

  @override
  Future<void> unpair() async {
    unpairCalls++;
    state = const AsyncData(null);
  }
}

class FakeServerConnection extends ServerConnectionController {
  FakeServerConnection(this.startState);

  final ServerLinkState startState;
  int connectCalls = 0;

  @override
  ServerLinkState build() => startState;

  @override
  Future<void> connect() async => connectCalls++;

  @override
  Future<void> disconnect() async {}
}

class FakeBackupSource extends ChangeNotifier implements BackupStatusSource {
  int runNowCalls = 0;
  int verifyAllCalls = 0;

  @override
  BackupActivity activity = BackupActivity.idle;

  @override
  BackupRunSummary? lastRun;

  @override
  VerifySummary? lastVerify;

  @override
  BackupSettings settings = const BackupSettings();

  @override
  Future<void> runNow() async => runNowCalls++;

  @override
  Future<void> verifyAll() async => verifyAllCalls++;

  @override
  Future<void> updateSettings(BackupSettings settings) async {
    this.settings = settings;
    notifyListeners();
  }
}

/// A NAS with folders in memory. [download] waits for [downloadGate]
/// when set, so a test can press Cancel.
class FakeRemoteFiles implements RemoteFiles {
  FakeRemoteFiles(this.folders);

  /// Folder path ("" = root) → its entries, sorted.
  final Map<String, List<DirEntry>> folders;

  final pageRequests = <({String path, String startAfter, int maxEntries})>[];
  final downloads = <String>[];
  Completer<void>? downloadGate;

  @override
  Future<List<DeviceEntry>> listDevices() async => const [
    DeviceEntry(
      deviceId: 3,
      name: 'Pixel',
      pairedAtMs: 1763400000000,
      isCaller: true,
    ),
  ];

  @override
  Future<DirPage> listDirPage({
    required int deviceId,
    required String path,
    String startAfter = '',
    int maxEntries = 1000,
  }) async {
    pageRequests.add((
      path: path,
      startAfter: startAfter,
      maxEntries: maxEntries,
    ));
    final entries = folders[path];
    if (entries == null) {
      throw const BrowseFailed(BrowseFailureKind.notFound, 'not found');
    }
    final after = [
      for (final entry in entries)
        if (startAfter.isEmpty || compareUtf8Bytes(entry.name, startAfter) > 0)
          entry,
    ];
    final page = after.take(maxEntries).toList();
    return DirPage(entries: page, hasMore: after.length > page.length);
  }

  @override
  Future<DownloadResult> download({
    required int deviceId,
    required String remotePath,
    int versionId = 0,
    required String outputPath,
    bool isOverwriteAllowed = false,
    void Function(DownloadProgress progress)? onProgress,
    DownloadCancel? cancel,
  }) async {
    downloads.add(remotePath);
    onProgress?.call(
      const DownloadProgress(
        chunksDone: 1,
        totalChunks: 2,
        bytesDone: 1024,
        sizeBytes: 2048,
      ),
    );
    final gate = downloadGate;
    if (gate != null) await gate.future;
    if (cancel?.isCancelled ?? false) {
      return const DownloadCancelled(chunksDone: 1);
    }
    return DownloadDone(
      outputPath: outputPath,
      versionId: versionId,
      sizeBytes: 2048,
      modifiedTimeMs: 0,
    );
  }
}

DirEntry fileEntry(String name, {int sizeBytes = 1536, int versionId = 9}) =>
    DirEntry(
      name: name,
      kind: DirEntryKind.file,
      sizeBytes: sizeBytes,
      modifiedTimeMs: 1763450000000,
      versionId: versionId,
    );

DirEntry folderEntry(String name) => DirEntry(
  name: name,
  kind: DirEntryKind.directory,
  sizeBytes: 0,
  modifiedTimeMs: 0,
  versionId: 0,
);

/// Plays a server for the pairing screen: each submitCode returns the
/// next of [results].
class FakePairingAttempt implements PairingAttempt {
  FakePairingAttempt(this.results);

  final List<PairingResult> results;
  final submittedCodes = <String>[];
  bool isClosed = false;

  @override
  bool isOpen = true;

  @override
  String get serverShortId => testShortId;

  @override
  Future<PairingResult> submitCode(String code) async {
    submittedCodes.add(code);
    return results.removeAt(0);
  }

  @override
  Future<void> close() async {
    isClosed = true;
    isOpen = false;
  }
}

/// Wraps [screen] in a ProviderScope with [overrides] and a MaterialApp.
/// [isAnimating]: the screen shows an endless animation.
Future<void> pumpScreen(
  WidgetTester tester,
  Widget screen, {
  List<Override> overrides = const [],
  bool isAnimating = false,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        restoreFolderProvider.overrideWithValue(
          Directory('${Directory.systemTemp.path}/htn-ui-test-restored'),
        ),
        ...overrides,
      ],
      child: MaterialApp(home: screen),
    ),
  );
  // A running progress bar never settles: pump a few frames instead.
  if (isAnimating) {
    await tester.pump();
    await tester.pump();
  } else {
    await tester.pumpAndSettle();
  }
}

/// The address the pairing tests type.
const typedAddress = ServerAddress('192.168.1.5');
