/// Backup tab (first tab of [HomeScreen]): is everything backed up, is
/// the NAS reachable, the backup with live numbers and Stop, the
/// automatic backup switch, the chosen folders, the last check. Connects
/// on open. Author: Hao Tran.
///
/// ```
///  ✓ Backed up            ← backupHeadline: green / orange / busy
///    <last run> | live numbers + bar
///    [Automatic backup  ⏻]  runs by itself · only on Wi-Fi
///    [Back up now | Stop]  [Check backup]
///  My NAS ● Connected (short reason when not)
///  Folders to back up: Camera (default) ›  ─► FoldersScreen
///  Last check
/// ```
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:haotrannas_client/backup/backup_status_source.dart';
import 'package:haotrannas_client/text/backup_text.dart';

import '../app/providers.dart';
import 'folders_screen.dart';

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
        _BackupCard(),
        SizedBox(height: 12),
        _ServerCard(),
        SizedBox(height: 12),
        _FoldersCard(),
        SizedBox(height: 12),
        _LastCheckCard(),
      ],
    ),
  );
}

class _ServerCard extends ConsumerWidget {
  const _ServerCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final link = ref.watch(serverConnectionProvider);
    final colors = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final serverName = link is ServerOnline
        ? link.connection.helloOk.serverName
        : 'My NAS';
    final (stateText, stateColor) = switch (link) {
      ServerOnline() => ('Connected', Colors.green),
      ServerConnecting() => ('Connecting…', colors.tertiary),
      ServerOffline() => ('Not connected', colors.error),
    };
    final problem = link is ServerOffline ? link.problem : null;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.dns),
                const SizedBox(width: 12),
                Expanded(child: Text(serverName, style: textTheme.titleMedium)),
                Icon(Icons.circle, size: 12, color: stateColor),
                const SizedBox(width: 8),
                Text(stateText),
              ],
            ),
            if (problem != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(problem, style: textTheme.bodySmall),
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

/// "Runs by itself · only on Wi-Fi · only while charging" for the switch.
/// iPhone: iOS allows no long background work, so automatic backup runs
/// each time the app opens (D-043).
String _autoBackupText(BackupSettings settings) => !settings.isBackupOn
    ? 'Off: only "Back up now" backs up'
    : defaultTargetPlatform == TargetPlatform.iOS
    ? 'Each time you open the app'
    : [
        'Runs by itself',
        if (settings.isWifiOnly) 'only on Wi-Fi',
        if (settings.isChargingOnly) 'only while charging',
      ].join(' · ');

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
        final lastRun = source.lastRun;
        final settings = source.settings;
        final headline = backupHeadline(activity, lastRun);
        final colors = Theme.of(context).colorScheme;
        final textTheme = Theme.of(context).textTheme;
        final (headlineIcon, headlineColor) = switch (headline.health) {
          BackupHealth.good => (Icons.check_circle, Colors.green),
          BackupHealth.warning => (Icons.warning_amber, Colors.orange),
          BackupHealth.busy => (Icons.sync, colors.primary),
        };
        return Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(headlineIcon, color: headlineColor, size: 32),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(headline.text, style: textTheme.titleLarge),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                if (isBusy) ...[
                  LinearProgressIndicator(value: progress?.fraction),
                  const SizedBox(height: 8),
                  for (final line in liveProgressLines(
                    activity,
                    progress,
                    DateTime.now(),
                  ))
                    Text(line, maxLines: 1, overflow: TextOverflow.ellipsis),
                ] else
                  Text(
                    lastRun == null
                        ? 'Tap "Back up now" to start.'
                        : runSummaryText(lastRun),
                  ),
                SwitchListTile(
                  key: const Key('backup.autoOn'),
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Automatic backup'),
                  subtitle: Text(_autoBackupText(settings)),
                  value: settings.isBackupOn,
                  onChanged: (isOn) => source.updateSettings(
                    settings.copyWith(isBackupOn: isOn),
                  ),
                ),
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
                      label: const Text('Check backup'),
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
        final names = source.settings.chosenFolderNames;
        return Card(
          child: ListTile(
            leading: const Icon(Icons.photo_library),
            title: const Text('Folders to back up'),
            subtitle: Text(
              switch (chosen?.length) {
                null => 'Camera (default): tap to choose more',
                0 => 'None chosen: nothing is backed up',
                // Names saved with the choice; a count for older settings.
                _ when names != null && names.isNotEmpty => names.join(', '),
                1 => '1 folder',
                final count => '$count folders',
              },
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
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

/// The last "Check backup" result.
class _LastCheckCard extends ConsumerWidget {
  const _LastCheckCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final source = ref.watch(backupStatusSourceProvider);
    return ListenableBuilder(
      listenable: source,
      builder: (context, _) {
        final lastVerify = source.lastVerify;
        return Card(
          child: ListTile(
            leading: const Icon(Icons.fact_check),
            title: const Text('Last check'),
            subtitle: Text(
              lastVerify == null
                  ? 'Never. "Check backup" makes sure every file on the NAS '
                        'is whole.'
                  : verifySummaryText(lastVerify),
            ),
          ),
        );
      },
    );
  }
}
