/// NAS page: the admin connection, paired devices, health jobs (D-041).
///
/// ```
///  Admin connection  this PC socket or SSH ─► ● reachable / problem   [Change] [↻]
///  Devices           table · Revoke (backups stay) · [Pair a new device] ─► code dialog
///  Health            last scrub · [Scrub now] (live count) · [Clean up now]
/// ```
///
/// No config editing and no delete here (D-039). Author: Hao Tran.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:haotrannas_client/text/formatting.dart';

import '../admin/admin_codec.dart';
import '../admin/admin_controller.dart';
import '../app/desktop_providers.dart';
import 'theme.dart';
import 'widgets.dart';

class AdminPage extends ConsumerWidget {
  const AdminPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final admin = ref.watch(adminProvider);
    final problem = admin.actionProblem;
    return PageFrame(
      title: 'NAS',
      subtitle:
          'Devices and health of the server. Nothing here deletes '
          'backups or changes the server\'s settings.',
      actions: [
        if (admin.target != null)
          IconButton(
            tooltip: 'Refresh',
            onPressed: () => ref.read(adminProvider.notifier).refresh(),
            icon: const Icon(Icons.refresh),
          ),
      ],
      children: [
        const _ConnectionCard(),
        if (problem != null) ProblemText(problem),
        if (admin.isReachable) ...[const _DevicesCard(), const _HealthCard()],
      ],
    );
  }
}

class _ConnectionCard extends ConsumerWidget {
  const _ConnectionCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final admin = ref.watch(adminProvider);
    final colors = Theme.of(context).colorScheme;
    final target = admin.target;
    return SectionCard(
      icon: Icons.lan_outlined,
      title: 'Admin connection',
      trailing: FilledButton.tonal(
        onPressed: () => showDialog<void>(
          context: context,
          builder: (context) => AdminTargetDialog(initial: target),
        ),
        child: Text(target == null ? 'Set up' : 'Change'),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (target == null)
            const HintText(
              'The app talks to the server\'s admin socket: directly when '
              'the server runs on this PC, or through SSH to the NAS '
              '(your SSH keys, no password is stored).',
            )
          else ...[
            Text(target.label),
            const SizedBox(height: 8),
            switch (admin.reach) {
              AdminReachable(:final openConnections) => StatusLine(
                color: okColor(colors),
                text: 'Reachable · $openConnections open connections',
              ),
              AdminChecking() => StatusLine(
                color: colors.tertiary,
                text: 'Checking…',
              ),
              AdminUnreachable(:final message) => StatusLine(
                color: colors.error,
                text: message,
              ),
              AdminNotSetUp() => const SizedBox.shrink(),
            },
          ],
        ],
      ),
    );
  }
}

/// Choose where the admin socket is.
class AdminTargetDialog extends ConsumerStatefulWidget {
  const AdminTargetDialog({super.key, this.initial});

  final AdminTarget? initial;

  @override
  ConsumerState<AdminTargetDialog> createState() => _AdminTargetDialogState();
}

class _AdminTargetDialogState extends ConsumerState<AdminTargetDialog> {
  late bool _isSsh = widget.initial is AdminOverSsh;
  late final _host = TextEditingController(
    text: switch (widget.initial) {
      AdminOverSsh(:final host) => host,
      _ => '',
    },
  );
  late final _dataDirectory = TextEditingController(
    text: widget.initial?.dataDirectory ?? defaultNasDataDirectory,
  );

  @override
  void dispose() {
    _host.dispose();
    _dataDirectory.dispose();
    super.dispose();
  }

  void _save() {
    final dataDirectory = _dataDirectory.text.trim().replaceFirst(
      RegExp(r'/+$'),
      '',
    );
    if (dataDirectory.isEmpty || (_isSsh && _host.text.trim().isEmpty)) {
      return;
    }
    final target = _isSsh
        ? AdminOverSsh(_host.text.trim(), dataDirectory)
        : AdminOnThisPc(dataDirectory);
    unawaited(ref.read(adminProvider.notifier).setTarget(target));
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('NAS admin connection'),
    content: SizedBox(
      width: 460,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SegmentedButton<bool>(
            segments: const [
              ButtonSegment(
                value: false,
                icon: Icon(Icons.computer),
                label: Text('Server on this PC'),
              ),
              ButtonSegment(
                value: true,
                icon: Icon(Icons.vpn_key_outlined),
                label: Text('NAS over SSH'),
              ),
            ],
            selected: {_isSsh},
            onSelectionChanged: (choice) =>
                setState(() => _isSsh = choice.single),
          ),
          const SizedBox(height: 16),
          if (_isSsh) ...[
            TextField(
              controller: _host,
              decoration: const InputDecoration(
                labelText: 'SSH host',
                hintText: 'hao@nas.local or a name from ~/.ssh/config',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
          ],
          TextField(
            controller: _dataDirectory,
            decoration: const InputDecoration(
              labelText: 'Server data folder (holds admin.sock)',
              border: OutlineInputBorder(),
            ),
            onSubmitted: (_) => _save(),
          ),
          const SizedBox(height: 12),
          HintText(
            _isSsh
                ? 'Uses the system ssh with your keys or agent; it must '
                      'work without a password prompt.'
                : 'The server runs on this PC with this data folder.',
          ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(onPressed: _save, child: const Text('Connect')),
    ],
  );
}

class _DevicesCard extends ConsumerWidget {
  const _DevicesCard();

  Future<void> _revoke(
    BuildContext context,
    WidgetRef ref,
    AdminDevice device,
  ) async {
    final isSure = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Revoke ${device.name} (device ${device.id})?'),
        content: const Text(
          'It can no longer connect to the NAS. Its backups stay on the NAS '
          'and can still be restored. To use it again, pair it again.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
              foregroundColor: Theme.of(context).colorScheme.onError,
            ),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Revoke'),
          ),
        ],
      ),
    );
    if (isSure == true) {
      await ref.read(adminProvider.notifier).revoke(device.id);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final devices = ref.watch(adminProvider.select((state) => state.devices));
    final ownDeviceId = ref.watch(identityProvider).value?.deviceId;
    final colors = Theme.of(context).colorScheme;
    return SectionCard(
      icon: Icons.devices_other_outlined,
      title: 'Devices',
      trailing: FilledButton.icon(
        onPressed: () => showDialog<void>(
          context: context,
          builder: (context) => const PairingCodeDialog(),
        ),
        icon: const Icon(Icons.add_link),
        label: const Text('Pair a new device'),
      ),
      child: devices == null
          ? const LinearProgressIndicator()
          : SizedBox(
              width: double.infinity,
              child: DataTable(
                headingTextStyle: Theme.of(context).textTheme.labelLarge,
                columns: const [
                  DataColumn(label: Text('Id'), numeric: true),
                  DataColumn(label: Text('Name')),
                  DataColumn(label: Text('Paired')),
                  DataColumn(label: Text('Status')),
                  DataColumn(label: Text('')),
                ],
                rows: [
                  for (final device in devices)
                    DataRow(
                      key: ValueKey('device.${device.id}'),
                      cells: [
                        DataCell(Text('${device.id}')),
                        DataCell(
                          Text(
                            device.id == ownDeviceId
                                ? '${device.name} (this PC)'
                                : device.name,
                          ),
                        ),
                        DataCell(Text(formatDateTime(device.pairedAt))),
                        DataCell(
                          device.revokedAt == null
                              ? StatusLine(
                                  color: okColor(colors),
                                  text: 'Allowed',
                                )
                              : StatusLine(
                                  color: colors.outline,
                                  text:
                                      'Revoked ${formatDateTime(device.revokedAt!)}',
                                ),
                        ),
                        DataCell(
                          device.isRevoked
                              ? const SizedBox.shrink()
                              : TextButton(
                                  onPressed: () =>
                                      _revoke(context, ref, device),
                                  child: const Text('Revoke'),
                                ),
                        ),
                      ],
                    ),
                ],
              ),
            ),
    );
  }
}

/// Asks the server for a pairing code and shows it big, with the time
/// left. The code is never logged.
class PairingCodeDialog extends ConsumerStatefulWidget {
  const PairingCodeDialog({super.key});

  @override
  ConsumerState<PairingCodeDialog> createState() => _PairingCodeDialogState();
}

class _PairingCodeDialogState extends ConsumerState<PairingCodeDialog> {
  AdminResult<PairingCode>? _result;
  DateTime? _validUntil;
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    unawaited(_ask());
  }

  Future<void> _ask() async {
    setState(() => _result = null);
    final result = await ref.read(adminProvider.notifier).createPairingCode();
    if (!mounted) return;
    _ticker?.cancel();
    setState(() {
      _result = result;
      if (result case AdminOk(value: final code)) {
        _validUntil = DateTime.now().add(Duration(seconds: code.validSeconds));
        _ticker = Timer.periodic(
          const Duration(seconds: 1),
          (_) => setState(() {}),
        );
      }
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final result = _result;
    final validUntil = _validUntil;
    final secondsLeft = validUntil == null
        ? 0
        : validUntil.difference(DateTime.now()).inSeconds.clamp(0, 9999);
    return AlertDialog(
      title: const Text('Pair a new device'),
      content: SizedBox(
        width: 420,
        child: switch (result) {
          null => const LinearProgressIndicator(),
          AdminFailed(:final message) => ProblemText(message),
          AdminOk(value: final code) => Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const HintText(
                'On the phone or PC: open pairing, check that it shows this '
                'server id, then type the code.',
              ),
              const SizedBox(height: 20),
              SelectableText(
                '${code.code.substring(0, 3)} ${code.code.substring(3)}',
                key: const Key('pairing.code'),
                style: textTheme.displayMedium?.copyWith(
                  fontFeatures: const [FontFeature.tabularFigures()],
                  letterSpacing: 4,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'Server id ${code.serverShortId}',
                style: textTheme.titleMedium,
              ),
              const SizedBox(height: 16),
              Text(
                secondsLeft > 0
                    ? 'Valid for $secondsLeft s'
                    : 'Expired: ask for a new code',
              ),
            ],
          ),
        },
      ),
      actions: [
        if (result case AdminOk(value: final code))
          TextButton(
            onPressed: () => Clipboard.setData(ClipboardData(text: code.code)),
            child: const Text('Copy code'),
          ),
        if (result != null && secondsLeft == 0)
          TextButton(onPressed: _ask, child: const Text('New code')),
        FilledButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Done'),
        ),
      ],
    );
  }
}

class _HealthCard extends ConsumerWidget {
  const _HealthCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final admin = ref.watch(adminProvider);
    final notifier = ref.read(adminProvider.notifier);
    final colors = Theme.of(context).colorScheme;
    final scrub = admin.lastScrub;
    final cleanup = admin.lastCleanup;
    final scrubNote = admin.scrubNote;
    final checking = admin.scrubChunksChecked;
    return SectionCard(
      icon: Icons.health_and_safety_outlined,
      title: 'Health',
      trailing: Wrap(
        spacing: 8,
        children: [
          OutlinedButton.icon(
            onPressed: admin.isCleaning ? null : notifier.cleanupNow,
            icon: const Icon(Icons.cleaning_services_outlined),
            label: Text(admin.isCleaning ? 'Cleaning…' : 'Clean up now'),
          ),
          FilledButton.tonalIcon(
            onPressed: admin.isScrubbing ? null : notifier.scrubNow,
            icon: const Icon(Icons.verified_outlined),
            label: const Text('Scrub now'),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (checking != null) ...[
            const LinearProgressIndicator(),
            const SizedBox(height: 8),
            Text(
              'Scrubbing: ${formatCount(checking)} chunks checked. '
              'This reads every chunk and can take hours on a big store.',
            ),
            const SizedBox(height: 16),
          ],
          Text('Last scrub', style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 8),
          if (scrub == null)
            HintText(scrubNote ?? 'No scrub has finished yet.')
          else ...[
            StatusLine(
              color: scrub.isClean ? okColor(colors) : colors.error,
              text: scrub.isClean
                  ? 'Clean: every chunk matches its hash'
                  : '${scrub.badFound} bad and ${scrub.missing} missing chunks '
                        '(${scrub.repaired} repaired): see nas/RUNBOOK.md',
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 32,
              runSpacing: 12,
              children: [
                Figure(label: 'When', value: formatDateTime(scrub.startedAt)),
                Figure(
                  label: 'Chunks',
                  value: formatCount(scrub.chunksChecked),
                ),
                Figure(label: 'Data', value: formatBytes(scrub.bytesChecked)),
                Figure(
                  label: 'Took',
                  value:
                      '${(scrub.duration.inMilliseconds / 1000).toStringAsFixed(1)} s',
                ),
              ],
            ),
          ],
          if (cleanup != null) ...[
            const SizedBox(height: 20),
            Text('Last cleanup', style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 8),
            Text(
              '${cleanup.expiredUploads} expired uploads, '
              '${cleanup.tmpFiles} temp files, '
              '${cleanup.unusedChunks} unused chunks, '
              '${cleanup.orphanFiles} orphan files removed.',
            ),
          ],
        ],
      ),
    );
  }
}
