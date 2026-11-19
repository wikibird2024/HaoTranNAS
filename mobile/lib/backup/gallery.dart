/// Puts a restored photo or video into the phone's gallery (Android
/// MediaStore, through photo_manager), in the album [galleryFolder].
/// Other files stay in the app's own folder. Author: Hao Tran.
///
/// ```
///  restoreToPhone ─► <documents>/restored/… ─► photo or video? ─► MediaStore copy
///                                                  │ no                └─► delete the app's copy
///                                                  ▼
///                                         stays inside the app
/// ```
library;

import 'dart:io';

import 'package:photo_manager/photo_manager.dart';

/// Where restored photos and videos show up (gallery album "HaoTranNAS").
const galleryFolder = 'Pictures/HaoTranNAS';

enum GalleryKind { image, video }

const _imageExtensions = {
  'jpg', 'jpeg', 'png', 'gif', 'webp', 'heic', 'heif', 'dng', 'bmp', //
};
const _videoExtensions = {'mp4', 'mov', '3gp', 'mkv', 'webm', 'm4v'};

/// Image or video by the file name's extension; null = not for the
/// gallery.
GalleryKind? galleryKindOf(String fileName) {
  final dotIndex = fileName.lastIndexOf('.');
  if (dotIndex < 0) return null;
  final extension = fileName.substring(dotIndex + 1).toLowerCase();
  if (_imageExtensions.contains(extension)) return GalleryKind.image;
  if (_videoExtensions.contains(extension)) return GalleryKind.video;
  return null;
}

/// Copies [localPath] into the gallery as [fileName], dated [takenAt]
/// so it sorts where the original was. Returns the gallery folder.
/// Throws when the phone refuses; the app's copy is then kept.
typedef AddToGallery = Future<String> Function(
  String localPath,
  String fileName,
  DateTime takenAt,
);

/// The real [AddToGallery] (Android only). On success the app's own copy
/// is deleted: the gallery holds the file now.
Future<String> addToPhoneGallery(
  String localPath,
  String fileName,
  DateTime takenAt,
) async {
  switch (galleryKindOf(fileName)) {
    case GalleryKind.image:
      await PhotoManager.editor.saveImageWithPath(
        localPath,
        title: fileName,
        relativePath: galleryFolder,
        creationDate: takenAt,
      );
    case GalleryKind.video:
      await PhotoManager.editor.saveVideo(
        File(localPath),
        title: fileName,
        relativePath: galleryFolder,
        creationDate: takenAt,
      );
    case null:
      throw ArgumentError.value(fileName, 'fileName', 'not a photo or video');
  }
  try {
    await File(localPath).delete();
  } on FileSystemException {
    // The gallery has it; a leftover copy in the app only costs space.
  }
  return galleryFolder;
}
