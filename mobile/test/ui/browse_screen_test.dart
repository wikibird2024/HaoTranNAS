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
    expect(find.text('9'), findsOneWidget);

    await tester.tap(find.text('Restore to phone'));
    await tester.pumpAndSettle();
    expect(files.downloads, ['DCIM/IMG_1.jpg']);
    expect(
      find.textContaining('Saved to ').evaluate().single.widget,
      isA<Text>().having(
        (text) => text.data,
        'data',
        endsWith('/device-3/DCIM/IMG_1.jpg'),
      ),
    );
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
