/// The phone's photos and videos through package:photo_manager: the
/// [MediaSource] the app and the background job use (see
/// `package:haotrannas_client/backup/media_source.dart` for the flow).
/// Author: Hao Tran.
library;

import 'dart:io';

import 'package:haotrannas_client/backup/media_source.dart';
import 'package:photo_manager/photo_manager.dart';

/// Folder on the NAS for an iPhone photo: `iPhone/<yyyy>-<mm>` of the
/// day it was taken, in UTC so a trip abroad never moves a path. iOS has
/// no folders, and its `IMG_0001` names roll over after 9999, so one flat
/// folder would mix two photos with the same name. Pure.
String iPhoneMediaFolder(int createdSeconds) {
  final created = DateTime.fromMillisecondsSinceEpoch(
    createdSeconds * 1000,
    isUtc: true,
  );
  final month = created.month.toString().padLeft(2, '0');
  return 'iPhone/${created.year}-$month';
}

/// The real phone library through package:photo_manager.
class PhotoManagerMediaSource implements MediaSource {
  /// [isBackground]: no permission dialog (no Activity); reads with what
  /// the user granted in the app.
  PhotoManagerMediaSource({this.isBackground = false, this.pageSize = 200});

  final bool isBackground;

  /// Assets per query.
  final int pageSize;

  /// Images and videos; `mediaLocation: true` also asks for
  /// ACCESS_MEDIA_LOCATION so the original file keeps its GPS EXIF.
  static const _permissionOption = PermissionRequestOption(
    androidPermission: AndroidPermission(
      type: RequestType.common,
      mediaLocation: true,
    ),
  );

  @override
  Future<MediaAccess> requestAccess() async {
    if (isBackground) {
      // Checking needs an Activity; the plugin docs say to skip the check
      // from a background job.
      await PhotoManager.setIgnorePermissionCheck(true);
      return const MediaAccess(MediaAccessLevel.notAsked);
    }
    final state = await PhotoManager.requestPermissionExtend(
      requestOption: _permissionOption,
    );
    return MediaAccess(switch (state) {
      PermissionState.authorized => MediaAccessLevel.all,
      PermissionState.limited => MediaAccessLevel.selectedOnly,
      _ => MediaAccessLevel.none,
    });
  }

  /// Newest first. A photo taken during the scan shifts the pages by
  /// one, so an item can come twice; the `seenIds` check drops it.
  static final _newestFirst = FilterOptionGroup(
    orders: const [OrderOption(type: OrderOptionType.createDate, asc: false)],
  );

  Future<List<AssetPathEntity>> _albums() => PhotoManager.getAssetPathList(
    hasAll: false,
    type: RequestType.common,
    filterOption: _newestFirst,
  );

  @override
  Future<List<MediaFolder>> listFolders() async => [
    for (final album in await _albums())
      MediaFolder(
        id: album.id,
        name: album.name,
        itemCount: await album.assetCountAsync,
      ),
  ];

  @override
  Stream<MediaItem> listItems({Set<String>? folderIds}) async* {
    final albums = {for (final album in await _albums()) album.id: album};
    final folders = inBackupOrder([
      for (final album in albums.values)
        if (folderIds == null || folderIds.contains(album.id))
          MediaFolder(id: album.id, name: album.name, itemCount: 0),
    ]);
    final seenIds = <String>{};
    for (final folder in folders) {
      final album = albums[folder.id]!;
      for (var page = 0; ; page++) {
        final assets = await album.getAssetListPaged(
          page: page,
          size: pageSize,
        );
        for (final asset in assets) {
          if (!seenIds.add(asset.id)) continue;
          final item = await _itemFor(asset);
          if (item != null) yield item;
        }
        if (assets.length < pageSize) break;
      }
    }
  }

  Future<MediaItem?> _itemFor(AssetEntity asset) async {
    final kind = switch (asset.type) {
      AssetType.image => MediaKind.image,
      AssetType.video => MediaKind.video,
      _ => null,
    };
    if (kind == null) return null;
    var title = asset.title;
    if (title == null || title.isEmpty) title = await asset.titleAsync;
    final modifiedSeconds =
        asset.modifiedDateSecond ?? asset.createDateSecond ?? 0;
    return MediaItem(
      id: asset.id,
      relativePath: mediaRemotePath(
        // Android: DCIM/Camera/…; iPhone has none (D-043).
        folder:
            asset.relativePath ??
            (Platform.isIOS
                ? iPhoneMediaFolder(asset.createDateSecond ?? modifiedSeconds)
                : null),
        fileName: title,
        mediaId: asset.id,
      ),
      sizeBytes: await asset.fileSize,
      modifiedTimeMs: modifiedSeconds * 1000,
      kind: kind,
    );
  }

  @override
  Future<File?> originalFile(MediaItem item) async {
    final asset = await AssetEntity.fromId(item.id);
    // originFile = MediaStore.setRequireOriginal: GPS kept, but only when
    // ACCESS_MEDIA_LOCATION was granted (else the plugin falls back to
    // the redacted file).
    return asset?.originFile;
  }

  @override
  Future<void> releaseOriginalFile(MediaItem item) =>
      // Deletes only the plugin's own cache copies (Android 10).
      PhotoManager.clearFileCache();
}
