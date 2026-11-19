// mediaRemotePath: every result passes the spec §10 path rules, and the
// same input always gives the same path.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:haotrannas_client/backup/media_source.dart';
import 'package:haotrannas_client/protocol/limits.dart';
import 'package:haotrannas_client/protocol/path_rules.dart';

String remotePath(String? folder, String? fileName, {String mediaId = '42'}) {
  final path = mediaRemotePath(
    folder: folder,
    fileName: fileName,
    mediaId: mediaId,
  );
  expect(pathProblem(path), isNull, reason: 'path rules: "$path"');
  return path;
}

void main() {
  test('Android relative_path + name', () {
    expect(
      remotePath('DCIM/Camera/', 'IMG_0001.jpg'),
      'DCIM/Camera/IMG_0001.jpg',
    );
    expect(
      remotePath('Pictures/WhatsApp Images', 'IMG-2026.jpg'),
      'Pictures/WhatsApp Images/IMG-2026.jpg',
    );
  });

  test('Android 9 absolute parent path loses the storage root', () {
    expect(
      remotePath('/storage/emulated/0/DCIM/Camera', 'a.jpg'),
      'DCIM/Camera/a.jpg',
    );
    expect(remotePath('/storage/1234-ABCD/DCIM', 'a.jpg'), 'DCIM/a.jpg');
    expect(remotePath('/sdcard/Download/', 'a.jpg'), 'Download/a.jpg');
  });

  test('no folder → fallback folder; no name → unnamed_<id>', () {
    expect(remotePath(null, 'a.jpg'), '$fallbackMediaFolder/a.jpg');
    expect(remotePath('', 'a.jpg'), '$fallbackMediaFolder/a.jpg');
    expect(remotePath('//', 'a.jpg'), '$fallbackMediaFolder/a.jpg');
    expect(remotePath('DCIM', '', mediaId: 'L0/001'), 'DCIM/unnamed_L0_001');
  });

  test(r'backslash, control characters, NUL and broken Unicode become _', () {
    expect(remotePath(r'DCIM\Cam', 'a\\b.jpg'), 'DCIM_Cam/a_b.jpg');
    expect(remotePath('DCIM', 'a\u0000b\u001f\u007f.jpg'), 'DCIM/a_b__.jpg');
    expect(remotePath('DCIM', 'a\ud800b.jpg'), 'DCIM/a_b.jpg');
    expect(remotePath('DCIM', 'a/b.jpg'), 'DCIM/a_b.jpg');
  });

  test('dot parts and empty parts', () {
    expect(remotePath('DCIM/./x/../', '..'), 'DCIM/_/x/__/__');
    expect(remotePath('DCIM//Camera', '.'), 'DCIM/Camera/_');
  });

  test('long name is cut to 255 bytes and keeps its extension', () {
    final path = remotePath('DCIM', '${'é' * 200}.jpeg');
    final name = path.split('/').last;
    expect(utf8.encode(name).length, lessThanOrEqualTo(maxPathComponentBytes));
    expect(name, endsWith('.jpeg'));
    expect(name, startsWith('é'));
  });

  test('long folder part is cut, too many parts are merged', () {
    final longFolder = remotePath('${'x' * 300}/y', 'a.jpg');
    expect(longFolder.split('/').first.length, maxPathComponentBytes);

    final deep = List.generate(40, (index) => 'd$index').join('/');
    final path = remotePath(deep, 'a.jpg');
    final parts = path.split('/');
    expect(parts.length, maxPathComponents);
    expect(parts.last, 'a.jpg');
    expect(
      parts[maxPathComponents - 2],
      'd30_d31_d32_d33_d34_d35_d36_d37_d38_d39',
    );
  });

  test('path over 1024 bytes falls back to Photos/<name>', () {
    final folder = List.generate(8, (index) => 'f' * 200).join('/');
    expect(remotePath(folder, 'a.jpg'), '$fallbackMediaFolder/a.jpg');
  });

  test('deterministic: same input, same output', () {
    final first = remotePath('DCIM\\x', 'a\u0001.jpg');
    final second = remotePath('DCIM\\x', 'a\u0001.jpg');
    expect(first, second);
  });

  test('MediaAccess: only "none" blocks reading', () {
    for (final level in MediaAccessLevel.values) {
      expect(
        MediaAccess(level).canRead,
        level != MediaAccessLevel.none,
        reason: level.name,
      );
      expect(MediaAccess(level).description, isNotEmpty);
    }
  });
}
