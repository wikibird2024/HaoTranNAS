/// Home screen when paired: which NAS, is it reachable, how did the last
/// backup go, "Back up now" and "Verify backup", and the way to Browse,
/// Settings and the Debug log. Connects on open. Author: Hao Tran.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app/providers.dart';
import 'backup_status_source.dart';
import 'browse_screen.dart';
import 'debug_log_screen.dart';
import 'formatting.dart';
import 'settings_screen.dart';

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

  void _open(Widget screen) =>
      Navigator.of(context)
          .push(MaterialPageRoute<void>(builder: (_) => screen));

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('HaoTranNAS')),
    body: ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const _ServerCard(),
        const SizedBox(height: 12),
        const _BackupCard(),
        const SizedBox(height: 12),
        Card(
          child: Column(
            children: [
              ListTile(
                leading: const Icon(Icons.folder_open),
                title: const Text('Browse backups'),
                onTap: () => _open(const BrowseScreen()),
              ),
              ListTile(
                leading: const Icon(Icons.settings),
                title: const Text('Settings'),
                onTap: () => _open(const SettingsScreen()),
              ),
              ListTile(
                leading: const Icon(Icons.receipt_long),
                title: const Text('Debug log'),
                onTap: () => _open(const DebugLogScreen()),
              ),
            ],
          ),
        ),
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

class _BackupCard extends ConsumerWidget {
  const _BackupCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final source = ref.watch(backupStatusSourceProvider);
    return ListenableBuilder(
      listenable: source,
      builder: (context, _) {
        final lastRun = source.lastRun;
        final lastVerify = source.lastVerify;
        final isBusy = source.activity != BackupActivity.idle;
        final textTheme = Theme.of(context).textTheme;
        return Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Backup', style: textTheme.titleLarge),
                const SizedBox(height: 8),
                Text(switch (source.activity) {
                  BackupActivity.idle =>
                    source.settings.isBackupOn
                        ? 'Automatic backup is on'
                        : 'Automatic backup is off',
                  BackupActivity.backingUp => 'Backing up…',
                  BackupActivity.verifying => 'Checking the backup…',
                }),
                if (isBusy) const LinearProgressIndicator(),
                const SizedBox(height: 8),
                Text('Last backup', style: textTheme.labelLarge),
                Text(lastRun == null ? 'Never' : _runSummaryText(lastRun)),
                if (lastVerify != null) ...[
                  const SizedBox(height: 8),
                  Text('Last check', style: textTheme.labelLarge),
                  Text(_verifySummaryText(lastVerify)),
                ],
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    FilledButton.icon(
                      onPressed: isBusy ? null : source.runNow,
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
