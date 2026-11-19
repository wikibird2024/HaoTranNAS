/// Backup tab (first tab of [HomeScreen]): which NAS and is it
/// reachable, the backup with live numbers and Stop, the chosen folders,
/// the last backup and check. Connects on open. Author: Hao Tran.
///
/// ```
///  ● Connected · server id
///  Backup: state · n of ~N photos checked · uploaded · MB/s · now <file>
///          [Back up now | Stop]  [Verify backup]
///  Folders: Camera, … (2 of 12) ›  ─► FoldersScreen
///  Last backup · Last check
/// ```
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app/providers.dart';
import 'backup_status_source.dart';
import 'folders_screen.dart';
import 'formatting.dart';

class StatusScreen extends ConsumerStatefulWidget {
  const StatusScreen({super.key});

  @override
  ConsumerState<StatusScreen> createState() => _StatusScreenState();
}

class _StatusScreenState extends ConsumerState<StatusScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) ref.read(serverConnectionProvider.notifier).connect();
    });
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('HaoTranNAS')),
    body: ListView(
      padding: const EdgeInsets.all(16),
      children: const [
        _ServerCard(),
        SizedBox(height: 12),
        _BackupCard(),
        SizedBox(height: 12),
        _FoldersCard(),
        SizedBox(height: 12),
        _HistoryCard(),
      ],
    ),
  );
}

class _ServerCard extends ConsumerWidget {
  const _ServerCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final identity = ref.watch(identityProvider).value;
    final link = ref.watch(serverConnectionProvider);
    final colors = Theme.of(context).colorScheme;
    final serverName = link is ServerOnline
        ? link.connection.helloOk.serverName
        : 'My NAS';
    final (stateText, stateColor) = switch (link) {
      ServerOnline() => ('Connected', Colors.green),
      ServerConnecting() => ('Connecting…', colors.tertiary),
      ServerOffline(:final problem) => (
        problem == null ? 'Not connected' : 'Not connected: $problem',
        colors.error,
      ),
    };
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(serverName, style: Theme.of(context).textTheme.titleLarge),
            if (identity != null) Text('Server id ${identity.serverShortId}'),
            const SizedBox(height: 8),
            Row(
              children: [
                Icon(Icons.circle, size: 12, color: stateColor),
                const SizedBox(width: 8),
                Expanded(child: Text(stateText)),
              ],
            ),
            if (link is ServerOffline && link.isMaybeNotPaired)
              const Padding(
                padding: EdgeInsets.only(top: 8),
                child: Text(
                  'The NAS refused this phone. It may have been removed on '
                  'the NAS: unpair in Settings and pair again.',
                ),
              ),
            if (link is ServerOffline)
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  onPressed: () =>
                      ref.read(serverConnectionProvider.notifier).connect(),
                  child: const Text('Connect'),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

String _runSummaryText(BackupRunSummary run) {
  final parts = [
    '${run.filesUploaded} uploaded (${formatBytes(run.bytesUploaded)})',
    '${run.filesAlreadyBackedUp} already there',
    if (run.filesFailed > 0) '${run.filesFailed} failed',
  ];
  final problem = run.problem;
  return '${formatDateTime(run.finishedAt)}: ${parts.join(', ')}'
      '${problem == null ? '' : '\n$problem'}';
}

String _verifySummaryText(VerifySummary verify) {
  final result = verify.filesWrong == 0
      ? 'all ${verify.filesChecked} files OK'
      : '${verify.filesWrong} of ${verify.filesChecked} files wrong or missing';
  final problem = verify.problem;
  return '${formatDateTime(verify.finishedAt)}: $result'
      '${problem == null ? '' : '\n$problem'}';
}

/// The lines under the progress bar while a run goes on.
List<String> liveProgressLines(
  BackupActivity activity,
  BackupLiveProgress? progress,
  DateTime now,
) {
  if (progress == null) return const ['Getting ready…'];
  final checkedText = activity == BackupActivity.verifying
      ? '${formatCount(progress.itemsChecked)} of '
            '${formatCount(progress.itemsTotal)} files checked'
      : '${formatCount(progress.itemsChecked)} of '
            '~${formatCount(progress.itemsTotal)} photos checked';
  final speed = progress.bytesPerSecond(now);
  return [
    checkedText,
    '${formatCount(progress.filesUploaded)} uploaded · '
        '${formatBytes(progress.bytesUploaded)}'
        '${speed > 0 ? ' · ${formatBytes(speed.round())}/s' : ''}',
    if (progress.currentPath.isNotEmpty) 'Now: ${progress.currentPath}',
  ];
}

class _BackupCard extends ConsumerWidget {
  const _BackupCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final source = ref.watch(backupStatusSourceProvider);
    return ListenableBuilder(
      listenable: source,
      builder: (context, _) {
        final activity = source.activity;
        final isBusy = activity != BackupActivity.idle;
        final progress = source.progress;
        final textTheme = Theme.of(context).textTheme;
        return Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Backup', style: textTheme.titleLarge),
                const SizedBox(height: 8),
                Text(switch (activity) {
                  BackupActivity.idle =>
                    source.settings.isBackupOn
                        ? 'Automatic backup is on'
                        : 'Automatic backup is off',
                  BackupActivity.backingUp => 'Backing up…',
                  BackupActivity.verifying => 'Checking the backup…',
                }, style: textTheme.titleMedium),
                if (isBusy) ...[
                  const SizedBox(height: 8),
                  LinearProgressIndicator(value: progress?.fraction),
                  const SizedBox(height: 8),
                  for (final line in liveProgressLines(
                    activity,
                    progress,
                    DateTime.now(),
                  ))
                    Text(line, maxLines: 1, overflow: TextOverflow.ellipsis),
                ],
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    if (isBusy)
                      FilledButton.tonalIcon(
                        onPressed: source.stop,
                        icon: const Icon(Icons.stop),
                        label: const Text('Stop'),
                      )
                    else
                      FilledButton.icon(
                        onPressed: source.runNow,
                        icon: const Icon(Icons.backup),
                        label: const Text('Back up now'),
                      ),
                    OutlinedButton.icon(
                      onPressed: isBusy ? null : source.verifyAll,
                      icon: const Icon(Icons.fact_check),
                      label: const Text('Verify backup'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _FoldersCard extends ConsumerWidget {
  const _FoldersCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final source = ref.watch(backupStatusSourceProvider);
    return ListenableBuilder(
      listenable: source,
      builder: (context, _) {
        final chosen = source.settings.chosenFolderIds;
        return Card(
          child: ListTile(
            leading: const Icon(Icons.photo_library),
            title: const Text('Folders to back up'),
            subtitle: Text(
              chosen == null
                  ? 'Camera (not chosen yet): tap to choose'
                  : '${chosen.length} chosen',
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => const FoldersScreen()),
            ),
          ),
        );
      },
    );
  }
}

class _HistoryCard extends ConsumerWidget {
  const _HistoryCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final source = ref.watch(backupStatusSourceProvider);
    return ListenableBuilder(
      listenable: source,
      builder: (context, _) {
        final lastRun = source.lastRun;
        final lastVerify = source.lastVerify;
        final textTheme = Theme.of(context).textTheme;
        return Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Last backup', style: textTheme.labelLarge),
                Text(lastRun == null ? 'Never' : _runSummaryText(lastRun)),
                const SizedBox(height: 8),
                Text('Last check', style: textTheme.labelLarge),
                Text(
                  lastVerify == null ? 'Never' : _verifySummaryText(lastVerify),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
