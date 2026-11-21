/// Settings tab: when automatic backup may run (Wi-Fi only, charging
/// only, through `BackupStatusSource`; the on/off switch is on the Backup
/// tab), the paired NAS, unpair (deletes this phone's certificate and key
/// after a confirm dialog) and, under Advanced, the debug log.
/// Author: Hao Tran.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:haotrannas_client/backup/backup_status_source.dart';

import '../app/providers.dart';
import 'debug_log_screen.dart';

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  Future<void> _confirmUnpair(BuildContext context, WidgetRef ref) async {
    final isConfirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Unpair this phone?'),
        content: const Text(
          'The phone forgets the NAS and stops backing up. Backups on the '
          'NAS stay. To use this phone again you must pair it again.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Unpair'),
          ),
        ],
      ),
    );
    if (isConfirmed != true || !context.mounted) return;
    await ref.read(identityProvider.notifier).unpair();
    if (!context.mounted) return;
    Navigator.of(context).popUntil((route) => route.isFirst);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final source = ref.watch(backupStatusSourceProvider);
    final identity = ref.watch(identityProvider).value;
    final link = ref.watch(serverConnectionProvider);
    // The name comes from the NAS itself, so it is known only once online.
    final serverName = link is ServerOnline
        ? link.connection.helloOk.serverName
        : 'My NAS';
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListenableBuilder(
        listenable: source,
        builder: (context, _) {
          final settings = source.settings;
          void update(BackupSettings changed) => source.updateSettings(changed);
          final isIPhone = defaultTargetPlatform == TargetPlatform.iOS;
          return ListView(
            children: [
              const _SectionTitle('Automatic backup'),
              // iPhone (D-043): no background job, so Wi-Fi and charging
              // conditions have nothing to shape.
              if (isIPhone)
                const ListTile(
                  leading: Icon(Icons.info_outline),
                  title: Text('Runs while the app is open'),
                  subtitle: Text(
                    'iPhone does not let apps run long backups in the '
                    'background. Open the app on Wi-Fi to back up; leave '
                    'it open for a big first backup.',
                  ),
                ),
              if (!isIPhone) ...[
                SwitchListTile(
                  key: const Key('settings.wifiOnly'),
                  title: const Text('Only on Wi-Fi'),
                  subtitle: const Text('Never use mobile data'),
                  value: settings.isWifiOnly,
                  onChanged: (isOn) =>
                      update(settings.copyWith(isWifiOnly: isOn)),
                ),
                SwitchListTile(
                  key: const Key('settings.chargingOnly'),
                  title: const Text('Only while charging'),
                  subtitle: const Text('Wait until the phone is plugged in'),
                  value: settings.isChargingOnly,
                  onChanged: (isOn) =>
                      update(settings.copyWith(isChargingOnly: isOn)),
                ),
                const _BatteryTile(),
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 16),
                  child: Text(
                    '"Back up now" runs on any network, charging or not.',
                  ),
                ),
              ],
              const Divider(),
              const _SectionTitle('NAS'),
              if (identity != null)
                ListTile(
                  leading: const Icon(Icons.dns),
                  title: Text(serverName),
                  subtitle: Text(
                    'Server id ${identity.serverShortId} · this phone is '
                    'device ${identity.deviceId}',
                  ),
                ),
              ListTile(
                leading: Icon(
                  Icons.link_off,
                  color: Theme.of(context).colorScheme.error,
                ),
                title: const Text('Unpair this phone'),
                subtitle: const Text('Backups on the NAS stay'),
                onTap: () => _confirmUnpair(context, ref),
              ),
              const Divider(),
              const _SectionTitle('Advanced'),
              ListTile(
                leading: const Icon(Icons.receipt_long),
                title: const Text('Debug log'),
                subtitle: const Text('What the app sent and received'),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => const DebugLogScreen(),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
    child: Text(
      text,
      style: Theme.of(context).textTheme.titleSmall
          ?.copyWith(color: Theme.of(context).colorScheme.primary),
    ),
  );
}

/// Android only: is the battery saver allowed to stop automatic backup?
/// Checks again when the user comes back from the system dialog (D-047).
class _BatteryTile extends ConsumerStatefulWidget {
  const _BatteryTile();

  @override
  ConsumerState<_BatteryTile> createState() => _BatteryTileState();
}

class _BatteryTileState extends ConsumerState<_BatteryTile> {
  /// Null = not known yet.
  bool? _isExempt;
  late final AppLifecycleListener _lifecycle;

  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(onResume: _check);
    _check();
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    super.dispose();
  }

  Future<void> _check() async {
    final exemption = ref.read(batteryExemptionProvider);
    if (exemption == null) return;
    final isExempt = await exemption.isExempt();
    if (mounted) setState(() => _isExempt = isExempt);
  }

  @override
  Widget build(BuildContext context) {
    final exemption = ref.watch(batteryExemptionProvider);
    final isExempt = _isExempt;
    if (exemption == null || isExempt == null) return const SizedBox.shrink();
    if (isExempt) {
      return const ListTile(
        key: Key('settings.battery'),
        leading: Icon(Icons.battery_full),
        title: Text('Battery saver: allowed'),
        subtitle: Text('Automatic backup may run in the background'),
      );
    }
    return ListTile(
      key: const Key('settings.battery'),
      leading: Icon(
        Icons.battery_alert,
        color: Theme.of(context).colorScheme.error,
      ),
      title: const Text('Battery saver may stop backups'),
      subtitle: const Text('Tap to let automatic backup run'),
      trailing: const Text('Allow'),
      onTap: exemption.ask,
    );
  }
}
