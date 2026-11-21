/// Which phone albums to back up (D-037): one checkbox each, with the
/// number of files. Never chosen = Camera only. Each tick is saved at
/// once (no Save button: Back never loses a choice). Author: Hao Tran.
///
/// ```
///  open ─► loadFolders (asks for photo access) ─► list, Camera first
///  tick / untick ─► settings.chosenFolderIds (saved at once)
/// ```
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:haotrannas_client/backup/backup_status_source.dart';
import 'package:haotrannas_client/text/formatting.dart';

import '../app/providers.dart';
import 'problem_view.dart';

class FoldersScreen extends ConsumerStatefulWidget {
  const FoldersScreen({super.key});

  @override
  ConsumerState<FoldersScreen> createState() => _FoldersScreenState();
}

class _FoldersScreenState extends ConsumerState<FoldersScreen> {
  List<BackupFolderChoice>? _folders;
  final _chosenIds = <String>{};
  String? _problem;

  /// The raw reason under [_problem]; null = none.
  String? _problemDetail;

  /// Lists again when the user comes back from the phone's Settings.
  late final AppLifecycleListener _lifecycle;

  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(onResume: _load);
    _load();
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final folders = await ref.read(backupStatusSourceProvider).loadFolders();
      if (!mounted) return;
      setState(() {
        _folders = folders;
        _chosenIds
          ..clear()
          ..addAll([
            for (final folder in folders)
              if (folder.isChosen) folder.id,
          ]);
        _problem = null;
        _problemDetail = null;
      });
    } on Exception catch (error) {
      if (!mounted) return;
      setState(() {
        _problem = 'Could not list the albums on this phone.';
        _problemDetail = '$error';
      });
    }
  }

  /// Back to the spinner, then list again.
  void _retry() {
    setState(() {
      _folders = null;
      _problem = null;
      _problemDetail = null;
    });
    _load();
  }

  void _setChosen(String folderId, bool isChosen) {
    setState(
      () => isChosen ? _chosenIds.add(folderId) : _chosenIds.remove(folderId),
    );
    final source = ref.read(backupStatusSourceProvider);
    source.updateSettings(
      source.settings.copyWith(
        chosenFolderIds: {..._chosenIds},
        // Names too, so the Backup tab can show them (D-042).
        chosenFolderNames: [
          for (final folder in _folders ?? const <BackupFolderChoice>[])
            if (_chosenIds.contains(folder.id)) folder.name,
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final folders = _folders;
    final problem = _problem;
    return Scaffold(
      appBar: AppBar(title: const Text('Folders to back up')),
      body: switch ((folders, problem)) {
        (_, final String text) => ProblemView(
          text,
          detail: _problemDetail,
          onRetry: _retry,
        ),
        (null, _) => const Center(child: CircularProgressIndicator()),
        (final List<BackupFolderChoice> list, _) when list.isEmpty => _NoAlbums(
          openSettings: ref.read(openAppSettingsProvider),
          onRetry: _retry,
        ),
        (final List<BackupFolderChoice> list, _) => ListView(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Text(
                _chosenIds.isEmpty
                    ? 'Nothing is chosen, so nothing is backed up. Tick at '
                          'least Camera.'
                    : 'New photos land in Camera, so it is backed up first. '
                          'Tick more folders if you want them too. Changes '
                          'are saved at once.',
              ),
            ),
            for (final folder in list)
              CheckboxListTile(
                key: Key('folder.${folder.id}'),
                title: Text(folder.name),
                subtitle: Text('${formatCount(folder.itemCount)} files'),
                value: _chosenIds.contains(folder.id),
                onChanged: (isChosen) =>
                    _setChosen(folder.id, isChosen == true),
              ),
          ],
        ),
      },
    );
  }
}

/// No album to show: photo access is off, or the phone has no photos.
/// The list reloads by itself when the user comes back from Settings.
class _NoAlbums extends StatelessWidget {
  const _NoAlbums({required this.openSettings, required this.onRetry});

  /// Null = this phone has no settings page to open (tests).
  final Future<void> Function()? openSettings;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final openSettings = this.openSettings;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'No albums found. The app may not have access to your photos '
              'and videos: allow it in the phone\'s Settings, then come back.',
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            if (openSettings != null)
              FilledButton.icon(
                onPressed: openSettings,
                icon: const Icon(Icons.settings),
                label: const Text('Open phone settings'),
              ),
            const SizedBox(height: 8),
            OutlinedButton(onPressed: onRetry, child: const Text('Try again')),
          ],
        ),
      ),
    );
  }
}
