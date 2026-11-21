// Browse screens on a fake RemoteFiles: paging as the list reaches its
// end, devices → folders → file details → restore with progress and
// cancel, not connected. Author: Hao Tran.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haotrannas_mobile/app/providers.dart';
import 'package:haotrannas_mobile/ui/browse_screen.dart';

import 'ui_fakes.dart';

void main() {
  testWidgets('folder pages: 5 entries in pages of 2 = 3 ListDir', (
    tester,
  ) async {
    final files = FakeRemoteFiles({
      '': [
        for (final name in ['a', 'b', 'c', 'd', 'e']) fileEntry(name),
      ],
    });
    await pumpScreen(
      tester,
      FolderScreen(
        files: files,
        deviceId: 3,
        deviceName: 'Pixel',
        path: '',
        pageEntries: 2,
      ),
    );
    for (final name in ['a', 'b', 'c', 'd', 'e']) {
      expect(find.text(name), findsOneWidget);
    }
    expect(
      [for (final request in files.pageRequests) request.startAfter],
      ['', 'b', 'd'],
    );
    expect(files.pageRequests.first.maxEntries, 2);
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });

  testWidgets('long folder loads the next page only when scrolled', (
    tester,
  ) async {
    final files = FakeRemoteFiles({
      '': [
        for (var index = 0; index < 60; index++) fileEntry('f${index + 100}'),
      ],
    });
    await pumpScreen(
      tester,
      FolderScreen(
        files: files,
        deviceId: 3,
        deviceName: 'Pixel',
        path: '',
        pageEntries: 20,
      ),
    );
    expect(files.pageRequests, hasLength(1));
    await tester.dragUntilVisible(
      find.text('f159'),
      find.byType(ListView),
      const Offset(0, -500),
    );
    await tester.pumpAndSettle();
    expect(files.pageRequests, hasLength(3));
  });

  testWidgets('devices → folder → file → restore', (tester) async {
    final files = FakeRemoteFiles({
      '': [folderEntry('DCIM')],
      'DCIM': [fileEntry('IMG_1.jpg', sizeBytes: 1536, versionId: 9)],
    });
    await pumpScreen(
      tester,
      const BrowseScreen(),
      overrides: [remoteFilesProvider.overrideWithValue(files)],
    );
    expect(find.text('Pixel (this phone)'), findsOneWidget);

    await tester.tap(find.text('Pixel (this phone)'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('DCIM'));
    await tester.pumpAndSettle();
    expect(files.pageRequests.last.path, 'DCIM');
    expect(find.textContaining('1.5 KB'), findsOneWidget);

    await tester.tap(find.text('IMG_1.jpg'));
    await tester.pumpAndSettle();
    expect(find.text('DCIM/IMG_1.jpg'), findsOneWidget);
    expect(find.text('Pixel › DCIM'), findsNothing, reason: 'file page');

    await tester.tap(find.text('Restore to phone'));
    await tester.pumpAndSettle();
    expect(files.downloads, ['DCIM/IMG_1.jpg']);
    expect(
      find.text(
        'Saved inside this app. Only photos and videos go to the gallery.',
      ),
      findsOneWidget,
      reason: 'no gallery in tests',
    );
  });

  testWidgets('a restored photo goes on to the gallery', (tester) async {
    final files = FakeRemoteFiles({});
    final galleryCalls = <(String, String)>[];
    await pumpScreen(
      tester,
      FileDetailsScreen(
        files: files,
        deviceId: 3,
        remotePath: 'DCIM/IMG_1.jpg',
        entry: fileEntry('IMG_1.jpg'),
      ),
      overrides: [
        addToGalleryProvider.overrideWithValue((
          localPath,
          fileName,
          takenAt,
        ) async {
          galleryCalls.add((localPath, fileName));
          return 'Pictures/HaoTranNAS';
        }),
      ],
    );
    await tester.tap(find.text('Restore to phone'));
    await tester.pumpAndSettle();
    expect(galleryCalls.single.$1, endsWith('/device-3/DCIM/IMG_1.jpg'));
    expect(galleryCalls.single.$2, 'IMG_1.jpg');
    expect(
      find.text('Saved to the gallery, album "HaoTranNAS".'),
      findsOneWidget,
    );
  });

  testWidgets('a gallery refusal keeps the file and says so', (tester) async {
    await pumpScreen(
      tester,
      FileDetailsScreen(
        files: FakeRemoteFiles({}),
        deviceId: 3,
        remotePath: 'clip.mp4',
        entry: fileEntry('clip.mp4'),
      ),
      overrides: [
        addToGalleryProvider.overrideWithValue(
          (localPath, fileName, takenAt) async => throw StateError('no room'),
        ),
      ],
    );
    await tester.tap(find.text('Restore to phone'));
    await tester.pumpAndSettle();
    expect(find.textContaining('kept inside this app'), findsOneWidget);
  });

  testWidgets('folder title shows where you are', (tester) async {
    await pumpScreen(
      tester,
      FolderScreen(
        files: FakeRemoteFiles({'DCIM/Camera': []}),
        deviceId: 3,
        deviceName: 'Pixel',
        path: 'DCIM/Camera',
      ),
    );
    expect(find.text('Camera'), findsOneWidget);
    expect(find.text('Pixel › DCIM › Camera'), findsOneWidget);
  });

  testWidgets('restore shows progress and Cancel stops it', (tester) async {
    final files = FakeRemoteFiles({})..downloadGate = Completer<void>();
    await pumpScreen(
      tester,
      FileDetailsScreen(
        files: files,
        deviceId: 3,
        remotePath: 'a.bin',
        entry: fileEntry('a.bin', sizeBytes: 2048),
      ),
    );
    await tester.tap(find.text('Restore to phone'));
    await tester.pump();
    expect(find.text('1.0 KB of 2.0 KB'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    files.downloadGate!.complete();
    await tester.pumpAndSettle();
    expect(find.text('Cancelled. Nothing was saved.'), findsOneWidget);
    expect(find.text('Restore to phone'), findsOneWidget);
  });

  testWidgets('Back during a restore asks first', (tester) async {
    final files = FakeRemoteFiles({})..downloadGate = Completer<void>();
    await pumpScreen(
      tester,
      Builder(
        builder: (context) => TextButton(
          onPressed: () => Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => FileDetailsScreen(
                files: files,
                deviceId: 3,
                remotePath: 'a.bin',
                entry: fileEntry('a.bin', sizeBytes: 2048),
              ),
            ),
          ),
          child: const Text('open file'),
        ),
      ),
    );
    await tester.tap(find.text('open file'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Restore to phone'));
    await tester.pump();

    // Keep restoring: the dialog closes, the restore goes on.
    await tester.pageBack();
    await tester.pump();
    expect(find.text('Stop the restore?'), findsOneWidget);
    await tester.tap(find.text('Keep restoring'));
    await tester.pump();
    expect(find.text('1.0 KB of 2.0 KB'), findsOneWidget);

    // Stop and leave: back on the first screen.
    await tester.pageBack();
    await tester.pump();
    await tester.tap(find.text('Stop and leave'));
    files.downloadGate!.complete();
    await tester.pumpAndSettle();
    expect(find.text('open file'), findsOneWidget);
    expect(find.text('Restore to phone'), findsNothing);
  });

  testWidgets('not connected: Connect asks the connection', (tester) async {
    final connection = FakeServerConnection(const ServerOffline());
    await pumpScreen(
      tester,
      const BrowseScreen(),
      overrides: [
        remoteFilesProvider.overrideWithValue(null),
        serverConnectionProvider.overrideWith(() => connection),
      ],
    );
    expect(find.text('Not connected to the NAS.'), findsOneWidget);
    await tester.tap(find.text('Connect'));
    expect(connection.connectCalls, 1);
  });

  testWidgets('missing folder shows a message and Try again', (tester) async {
    await pumpScreen(
      tester,
      FolderScreen(
        files: FakeRemoteFiles({}),
        deviceId: 3,
        deviceName: 'Pixel',
        path: 'gone',
      ),
    );
    expect(
      find.text('This folder is not on the NAS (any more).'),
      findsOneWidget,
    );
    expect(find.text('Try again'), findsOneWidget);
  });
}
