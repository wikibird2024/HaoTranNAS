/// Which phone albums to back up (D-037): one checkbox each, with the
/// number of photos. Never chosen = Camera only. Save keeps the choice
/// in the backup settings. Author: Hao Tran.
///
/// ```
///  open ─► loadFolders (asks for photo access) ─► list, Camera first
///  tick / untick ─► Save ─► settings.chosenFolderIds ─► back
/// ```
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app/providers.dart';
import 'backup_status_source.dart';
import 'formatting.dart';

class FoldersScreen extends ConsumerStatefulWidget {
  const FoldersScreen({super.key});

  @override
  ConsumerState<FoldersScreen> createState() => _FoldersScreenState();
}

class _FoldersScreenState extends ConsumerState<FoldersScreen> {
  List<BackupFolderChoice>? _folders;
  final _chosenIds = <String>{};
  String? _problem;

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
      if (mounted) setState(() => _problem = 'Could not list albums: $error');
    }
  }

  Future<void> _save() async {
    final source = ref.read(backupStatusSourceProvider);
    await source.updateSettings(
      source.settings.copyWith(chosenFolderIds: {..._chosenIds}),
    );
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final folders = _folders;
    final problem = _problem;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Folders to back up'),
        actions: [
          TextButton(
            onPressed: folders == null || folders.isEmpty ? null : _save,
            child: const Text('Save'),
          ),
        ],
      ),
      body: switch ((folders, problem)) {
        (_, final String text) => Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text(text, textAlign: TextAlign.center),
          ),
        ),
        (null, _) => const Center(child: CircularProgressIndicator()),
        (final List<BackupFolderChoice> list, _) => ListView(
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Text(
                'New photos land in Camera, so it is backed up first. '
                'Pick more folders if you want them too.',
              ),
            ),
            for (final folder in list)
              CheckboxListTile(
                key: Key('folder.${folder.id}'),
                title: Text(folder.name),
                subtitle: Text('${formatCount(folder.itemCount)} items'),
                value: _chosenIds.contains(folder.id),
                onChanged: (isChosen) => setState(
                  () => isChosen == true
                      ? _chosenIds.add(folder.id)
                      : _chosenIds.remove(folder.id),
                ),
              ),
          ],
        ),
      },
    );
  }
}
