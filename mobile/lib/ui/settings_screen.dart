/// Settings tab: backup on/off, Wi-Fi only, charging only (through
/// `BackupStatusSource`), the paired NAS, the debug log, and unpair
/// (deletes this phone's certificate and key after a confirm dialog).
/// Author: Hao Tran.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app/providers.dart';
import 'backup_status_source.dart';
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
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListenableBuilder(
        listenable: source,
        builder: (context, _) {
          final settings = source.settings;
          void update(BackupSettings changed) => source.updateSettings(changed);
          return ListView(
            children: [
              SwitchListTile(
                key: const Key('settings.backupOn'),
                title: const Text('Automatic backup'),
                subtitle: const Text('Back up new photos and files by itself'),
                value: settings.isBackupOn,
                onChanged: (isOn) =>
                    update(settings.copyWith(isBackupOn: isOn)),
              ),
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
                value: settings.isChargingOnly,
                onChanged: (isOn) =>
                    update(settings.copyWith(isChargingOnly: isOn)),
              ),
              const Divider(),
              if (identity != null)
                ListTile(
                  leading: const Icon(Icons.dns),
                  title: const Text('Paired NAS'),
                  subtitle: Text(
                    'Server id ${identity.serverShortId} · this phone is '
                    'device ${identity.deviceId}',
                  ),
                ),
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
              ListTile(
                leading: Icon(
                  Icons.link_off,
                  color: Theme.of(context).colorScheme.error,
                ),
                title: const Text('Unpair this phone'),
                onTap: () => _confirmUnpair(context, ref),
              ),
            ],
          );
        },
      ),
    );
  }
}
