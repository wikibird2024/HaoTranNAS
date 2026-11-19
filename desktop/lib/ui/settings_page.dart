/// Settings: this PC's pairing, where restores go by default, the debug
/// log, Unpair. Author: Hao Tran.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:haotrannas_client/core/log/session_log.dart';
import 'package:haotrannas_client/text/formatting.dart';

import '../app/desktop_providers.dart';
import 'widgets.dart';

class SettingsPage extends ConsumerWidget {
  const SettingsPage({super.key});

  Future<void> _unpair(BuildContext context, WidgetRef ref) async {
    final isSure = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Unpair this PC?'),
        content: const Text(
          'This PC forgets its key and stops backing up. Its backups stay '
          'on the NAS. To also lock the old key out, revoke this PC on the '
          'NAS page first.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Unpair'),
          ),
        ],
      ),
    );
    if (isSure == true) await ref.read(identityProvider.notifier).unpair();
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final identity = ref.watch(identityProvider).value;
    return PageFrame(
      title: 'Settings',
      children: [
        SectionCard(
          icon: Icons.link,
          title: 'Pairing',
          trailing: OutlinedButton(
            onPressed: () => _unpair(context, ref),
            child: const Text('Unpair'),
          ),
          child: Wrap(
            spacing: 32,
            runSpacing: 12,
            children: [
              Figure(label: 'Server id', value: identity?.serverShortId ?? '–'),
              Figure(
                label: 'This PC on the NAS',
                value: identity == null ? '–' : 'device ${identity.deviceId}',
              ),
              Figure(label: 'Name', value: ref.watch(deviceNameProvider)),
            ],
          ),
        ),
        SectionCard(
          icon: Icons.download_outlined,
          title: 'Restores',
          child: HintText(
            'You pick the folder each time. Nothing on this PC is ever '
            'replaced: a taken name becomes "name (2)". Suggested folder: '
            '${ref.watch(restoreFolderProvider).path}',
          ),
        ),
        const _DebugLogCard(),
      ],
    );
  }
}

class _DebugLogCard extends ConsumerWidget {
  const _DebugLogCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final log = ref.watch(sessionLogProvider);
    return SectionCard(
      icon: Icons.terminal,
      title: 'Debug log',
      child: ListenableBuilder(
        listenable: log,
        builder: (context, _) {
          final entries = log.entries.reversed.take(200).toList();
          if (entries.isEmpty) return const HintText('Nothing logged yet.');
          return ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 360),
            child: ListView.builder(
              shrinkWrap: true,
              itemCount: entries.length,
              itemBuilder: (context, index) {
                final entry = entries[index];
                final arrow = switch (entry.direction) {
                  Direction.sent => '→',
                  Direction.received => '←',
                  Direction.note => '·',
                };
                return Text(
                  '${formatClockTime(entry.time)} $arrow ${entry.description}',
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                );
              },
            ),
          );
        },
      ),
    );
  }
}
