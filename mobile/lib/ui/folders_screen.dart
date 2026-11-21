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

  @override
  void initState() {
    super.initState();
    _load();
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
        _problem = folders.isEmpty
            ? 'No albums found. Allow access to photos and videos in the '
                  "phone's Settings, then come back."
            : null;
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
