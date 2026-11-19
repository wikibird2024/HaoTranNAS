/// Overview: the NAS and this PC's backup at a glance.
///
/// ```
///  ┌ NAS ─────────────────────┐  ┌ This PC ───────────────────┐
///  │ name, server id, ● state │  │ Back up now · live numbers │
///  │ connections · devices ·  │  │ last backup · last check   │
///  │ last scrub (admin)       │  └────────────────────────────┘
///  └──────────────────────────┘
/// ```
///
/// Author: Hao Tran.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:haotrannas_client/text/formatting.dart';

import '../admin/admin_codec.dart';
import '../admin/admin_controller.dart';
import '../app/desktop_providers.dart';
import 'backup_page.dart';
import 'home_shell.dart';
import 'theme.dart';
import 'widgets.dart';

class OverviewPage extends StatelessWidget {
  const OverviewPage({super.key});

  @override
  Widget build(BuildContext context) => PageFrame(
    title: 'Overview',
    subtitle: 'Your NAS and this PC\'s backup.',
    children: [
      LayoutBuilder(
        builder: (context, constraints) {
          const nasCard = NasCard();
          const backupCard = BackupNowCard();
          if (constraints.maxWidth < 760) {
            return const Column(
              children: [nasCard, SizedBox(height: 16), backupCard],
            );
          }
          return const IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(flex: 2, child: nasCard),
                SizedBox(width: 16),
                Expanded(flex: 3, child: backupCard),
              ],
            ),
          );
        },
      ),
    ],
  );
}

class NasCard extends ConsumerWidget {
  const NasCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = Theme.of(context).colorScheme;
    final identity = ref.watch(identityProvider).value;
    final link = ref.watch(serverConnectionProvider);
    final admin = ref.watch(adminProvider);
    final (color, text) = switch (link) {
      ServerOnline() => (okColor(colors), 'Connected'),
      ServerConnecting() => (colors.tertiary, 'Connecting…'),
      ServerOffline(:final problem) => (
        colors.error,
        problem == null ? 'Not connected' : 'Not connected: $problem',
      ),
    };
    final serverName = link is ServerOnline
        ? link.connection.helloOk.serverName
        : 'My NAS';
    final reach = admin.reach;
    final scrub = admin.lastScrub;
    return SectionCard(
      icon: Icons.dns_outlined,
      title: serverName,
      trailing: link is ServerOffline
          ? TextButton(
              onPressed: () =>
                  ref.read(serverConnectionProvider.notifier).connect(),
              child: const Text('Connect'),
            )
          : null,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          StatusLine(color: color, text: text),
          if (identity != null) ...[
            const SizedBox(height: 4),
            HintText('Server id ${identity.serverShortId}'),
          ],
          if (link is ServerOffline && link.isMaybeNotPaired) ...[
            const SizedBox(height: 8),
            const ProblemText(
              'The NAS refused this PC. It may have been revoked on the '
              'NAS: unpair in Settings and pair again.',
            ),
          ],
          const SizedBox(height: 16),
          const Divider(),
          const SizedBox(height: 16),
          switch (reach) {
            AdminReachable(:final openConnections) => Wrap(
              spacing: 32,
              runSpacing: 12,
              children: [
                Figure(label: 'Connections', value: '$openConnections'),
                Figure(
                  label: 'Devices',
                  value:
                      '${admin.devices?.where((d) => !d.isRevoked).length ?? '–'}',
                ),
                Figure(
                  label: 'Last scrub',
                  value: scrub == null
                      ? 'never'
                      : scrub.isClean
                      ? 'clean · ${formatDateTime(scrub.startedAt)}'
                      : '${scrub.badFound + scrub.missing} bad · ${formatDateTime(scrub.startedAt)}',
                ),
              ],
            ),
            AdminNotSetUp() => Row(
              children: [
                const Expanded(
                  child: HintText(
                    'Connect the NAS admin to see devices and health.',
                  ),
                ),
                TextButton(
                  onPressed: () =>
                      ref.read(currentPageProvider.notifier).show(AppPage.nas),
                  child: const Text('Set up'),
                ),
              ],
            ),
            AdminChecking() => const HintText('Checking the NAS…'),
            AdminUnreachable(:final message) => ProblemText('Admin: $message'),
          },
        ],
      ),
    );
  }
}
