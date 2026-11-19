/// Backup page: run now with live numbers, the PC folders to back up,
/// the hourly automatic backup, the last run and check.
///
/// ```
///  [Back up now] ─► BackupStatusSource.runNow ─► progress (bar, counts, speed, file)
///  [Add folder]  ─► system folder picker ─► folderNameClash? ─► settings.chosenFolderIds
///  [Remove]      ─► confirm ─► settings (backups on the NAS stay)
/// ```
///
/// Author: Hao Tran.
library;

import 'dart:async';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:haotrannas_client/backup/backup_status_source.dart';
import 'package:haotrannas_client/text/backup_text.dart';
import 'package:haotrannas_client/text/formatting.dart';

import '../app/desktop_providers.dart';
import '../backup/folder_media_source.dart';
import 'widgets.dart';

class BackupPage extends ConsumerWidget {
  const BackupPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) => const PageFrame(
    title: 'Backup',
    subtitle: 'Folders on this PC that are copied to the NAS.',
    children: [BackupNowCard(), FoldersCard(), AutomaticBackupCard()],
  );
}

/// Run now / Stop / Verify with live numbers and the last results. Also
/// on the Overview page.
class BackupNowCard extends ConsumerWidget {
  const BackupNowCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final source = ref.watch(backupStatusSourceProvider);
    return ListenableBuilder(
      listenable: source,
      builder: (context, _) {
        final activity = source.activity;
        final isBusy = activity != BackupActivity.idle;
        final progress = source.progress;
        final lastRun = source.lastRun;
        final lastVerify = source.lastVerify;
        final textTheme = Theme.of(context).textTheme;
        return SectionCard(
          icon: Icons.cloud_upload_outlined,
          title: 'This PC',
          trailing: isBusy
              ? OutlinedButton.icon(
                  onPressed: source.stop,
                  icon: const Icon(Icons.stop),
                  label: const Text('Stop'),
                )
              : Wrap(
                  spacing: 8,
                  children: [
                    OutlinedButton.icon(
                      onPressed: source.verifyAll,
                      icon: const Icon(Icons.fact_check_outlined),
                      label: const Text('Verify'),
                    ),
                    FilledButton.icon(
                      onPressed: source.runNow,
                      icon: const Icon(Icons.backup),
                      label: const Text('Back up now'),
                    ),
                  ],
                ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (isBusy) ...[
                Text(
                  activity == BackupActivity.verifying
                      ? 'Checking the backup…'
                      : 'Backing up…',
                  style: textTheme.titleSmall,
                ),
                const SizedBox(height: 8),
                ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(
                    value: progress?.fraction,
                    minHeight: 8,
                  ),
                ),
                const SizedBox(height: 8),
                for (final line in liveProgressLines(
                  activity,
                  progress,
                  DateTime.now(),
                  itemsWord: 'files',
                ))
                  Text(line, maxLines: 1, overflow: TextOverflow.ellipsis),
                const SizedBox(height: 16),
              ],
              _LastResult(
                label: 'Last backup',
                text: lastRun == null ? 'Never' : runSummaryText(lastRun),
                isProblem: lastRun?.problem != null,
              ),
              const SizedBox(height: 8),
              _LastResult(
                label: 'Last check',
                text: lastVerify == null
                    ? 'Never'
                    : verifySummaryText(lastVerify),
                isProblem:
                    lastVerify != null &&
                    (lastVerify.problem != null || lastVerify.filesWrong > 0),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _LastResult extends StatelessWidget {
  const _LastResult({
    required this.label,
    required this.text,
    required this.isProblem,
  });

  final String label;
  final String text;
  final bool isProblem;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 110,
          child: Text(
            label,
            style: Theme.of(context).textTheme.labelLarge
                ?.copyWith(color: colors.onSurfaceVariant),
          ),
        ),
        Expanded(
          child: Text(
            text,
            style: isProblem ? TextStyle(color: colors.error) : null,
          ),
        ),
      ],
    );
  }
}

/// The chosen PC folders with their file counts.
class FoldersCard extends ConsumerStatefulWidget {
  const FoldersCard({super.key});

  @override
  ConsumerState<FoldersCard> createState() => _FoldersCardState();
}

class _FoldersCardState extends ConsumerState<FoldersCard> {
  List<BackupFolderChoice>? _folders;
  bool _isCounting = false;
  late final BackupStatusSource _source;

  /// The choice the shown counts belong to; the saved settings load
  /// after the page is first built, so a change means count again.
  Set<String>? _countedPaths;

  @override
  void initState() {
    super.initState();
    _source = ref.read(backupStatusSourceProvider)..addListener(_onChange);
    unawaited(_count());
  }

  @override
  void dispose() {
    _source.removeListener(_onChange);
    super.dispose();
  }

  void _onChange() {
    final counted = _countedPaths;
    if (counted == null || !setEquals(counted, _chosenPaths)) {
      unawaited(_count());
    }
  }

  Future<void> _count() async {
    _countedPaths = {..._chosenPaths};
    setState(() => _isCounting = true);
    final folders = await _source.loadFolders();
    if (!mounted) return;
    setState(() {
      _folders = folders;
      _isCounting = false;
    });
  }

  Set<String> get _chosenPaths =>
      ref.read(backupStatusSourceProvider).settings.chosenFolderIds ?? {};

  Future<void> _add() async {
    final path = await getDirectoryPath(confirmButtonText: 'Back up');
    if (path == null || !mounted) return;
    final clash = folderNameClash(path, _chosenPaths);
    if (clash != null) {
      showNote(context, clash);
      return;
    }
    await _save({..._chosenPaths, path});
  }

  Future<void> _remove(String path) async {
    final isSure = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Stop backing up ${folderNameOf(path)}?'),
        content: const Text(
          'Files already on the NAS stay there and can still be restored. '
          'New changes in this folder are no longer backed up.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Stop backing up'),
          ),
        ],
      ),
    );
    if (isSure != true) return;
    await _save({..._chosenPaths}..remove(path));
  }

  Future<void> _save(Set<String> paths) async {
    final source = ref.read(backupStatusSourceProvider);
    await source.updateSettings(
      source.settings.copyWith(chosenFolderIds: paths),
    );
  }

  @override
  Widget build(BuildContext context) {
    final folders = _folders;
    return SectionCard(
      icon: Icons.folder_copy_outlined,
      title: 'Folders to back up',
      trailing: FilledButton.tonalIcon(
        onPressed: _add,
        icon: const Icon(Icons.create_new_folder_outlined),
        label: const Text('Add folder'),
      ),
      child: switch (folders) {
        null => const LinearProgressIndicator(),
        [] => const HintText(
          'No folders yet. Add one, for example Documents or Pictures. '
          'Each folder lands on the NAS under its own name.',
        ),
        _ => Column(
          children: [
            for (final folder in folders)
              ListTile(
                key: Key('folder.${folder.id}'),
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.folder),
                title: Text(folder.name),
                subtitle: Text(folder.id),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      _isCounting
                          ? 'counting…'
                          : '${formatCount(folder.itemCount)} files',
                    ),
                    const SizedBox(width: 8),
                    IconButton(
                      tooltip: 'Stop backing up this folder',
                      onPressed: () => _remove(folder.id),
                      icon: const Icon(Icons.remove_circle_outline),
                    ),
                  ],
                ),
              ),
          ],
        ),
      },
    );
  }
}

class AutomaticBackupCard extends ConsumerWidget {
  const AutomaticBackupCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final source = ref.watch(backupStatusSourceProvider);
    return ListenableBuilder(
      listenable: source,
      builder: (context, _) => SectionCard(
        icon: Icons.schedule,
        title: 'Automatic backup',
        child: SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Back up every hour while the app is open'),
          subtitle: const Text(
            'Only new and changed files are sent. Closing the app pauses it.',
          ),
          value: source.settings.isBackupOn,
          onChanged: (isOn) =>
              source.updateSettings(source.settings.copyWith(isBackupOn: isOn)),
        ),
      ),
    );
  }
}
