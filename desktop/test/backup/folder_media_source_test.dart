// FolderMediaSource on a temp tree: paths, counts, symlinks and special
// files skipped, unreadable folders skipped, folder choice rules.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:haotrannas_client/backup/media_source.dart';
import 'package:haotrannas_desktop/backup/folder_media_source.dart';

void main() {
  late Directory root;
  late String documents;
  late String pictures;
  final skipped = <String>[];

  FolderMediaSource sourceFor(Set<String> paths) =>
      FolderMediaSource(chosenFolderPaths: () => paths, onSkipped: skipped.add);

  setUp(() {
    skipped.clear();
    root = Directory.systemTemp.createTempSync('folder_source');
    documents = '${root.path}/Documents';
    pictures = '${root.path}/Pictures';
    File('$documents/a.txt')
      ..createSync(recursive: true)
      ..writeAsStringSync('hello');
    File('$documents/notes/deep/b.md')
      ..createSync(recursive: true)
      ..writeAsStringSync('b');
    File('$documents/Tiếng Việt.txt').writeAsStringSync('unicode');
    Link('$documents/link-to-a').createSync('$documents/a.txt');
    Link('$documents/link-to-folder').createSync('$documents/notes');
    File('$pictures/p.jpg')
      ..createSync(recursive: true)
      ..writeAsBytesSync([1, 2, 3]);
  });

  tearDown(() {
    // Make the locked folder deletable again.
    final locked = Directory('$documents/locked');
    if (locked.existsSync()) Process.runSync('chmod', ['700', locked.path]);
    root.deleteSync(recursive: true);
  });

  test(
    'items: remote path = folder name + path inside, links skipped',
    () async {
      final items = await sourceFor({documents}).listItems().toList();
      final byPath = {for (final item in items) item.relativePath: item};
      expect(byPath.keys.toSet(), {
        'Documents/a.txt',
        'Documents/notes/deep/b.md',
        'Documents/Tiếng Việt.txt',
      });
      final first = byPath['Documents/a.txt']!;
      expect(first.id, '$documents/a.txt');
      expect(first.sizeBytes, 5);
      expect(first.kind, MediaKind.file);
      expect(
        first.modifiedTimeMs,
        File('$documents/a.txt').lastModifiedSync().millisecondsSinceEpoch,
      );
    },
  );

  test('folders: name and file count; the chosen ids pick the walk', () async {
    final source = sourceFor({pictures, documents});
    final folders = await source.listFolders();
    expect(folders.map((folder) => (folder.name, folder.itemCount)), [
      ('Documents', 3),
      ('Pictures', 1),
    ]);
    final onlyPictures = await source.listItems(folderIds: {pictures}).toList();
    expect(onlyPictures.single.relativePath, 'Pictures/p.jpg');
  });

  test('original file is the file itself; a removed one is null', () async {
    final source = sourceFor({documents});
    final item = (await source.listItems().toList()).firstWhere(
      (item) => item.relativePath == 'Documents/a.txt',
    );
    expect((await source.originalFile(item))!.path, '$documents/a.txt');
    File('$documents/a.txt').deleteSync();
    expect(await source.originalFile(item), isNull);
  });

  test('missing folder and unreadable sub folder are skipped', () async {
    final locked = Directory('$documents/locked')..createSync();
    File('${locked.path}/secret.txt').writeAsStringSync('x');
    Process.runSync('chmod', ['000', locked.path]);
    final isRoot =
        Process.runSync('id', ['-u']).stdout.toString().trim() == '0';

    final items = await sourceFor({documents, '${root.path}/gone'})
        .listItems()
        .toList();

    expect(
      items.map((item) => item.relativePath),
      isNot(contains('Documents/locked/secret.txt')),
      skip: isRoot ? 'root reads everything' : null,
    );
    expect(items, hasLength(3));
    expect(skipped.join('\n'), contains('folder missing'));
  }, skip: Platform.isLinux ? null : 'POSIX permissions');

  group('folderNameClash', () {
    test('a new folder with its own name is fine', () {
      expect(
        folderNameClash('/home/hao/Pictures', ['/home/hao/Documents']),
        isNull,
      );
    });

    test('same folder, inside, around, same name are refused', () {
      const chosen = ['/home/hao/Documents'];
      expect(
        folderNameClash('/home/hao/Documents/', chosen),
        contains('already backed up'),
      );
      expect(
        folderNameClash('/home/hao/Documents/notes', chosen),
        contains('inside'),
      );
      expect(folderNameClash('/home/hao', chosen), contains('holds'));
      expect(
        folderNameClash('/mnt/usb/Documents', chosen),
        contains('also named'),
      );
    });

    test('folderNameOf', () {
      expect(folderNameOf('/home/hao/Documents/'), 'Documents');
      expect(folderNameOf('/'), '/');
    });
  });
}
