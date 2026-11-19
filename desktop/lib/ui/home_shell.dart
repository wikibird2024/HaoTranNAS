/// The paired app: a navigation rail on the left, one page on the right.
///
/// ```
///  ┌──────────────┬──────────────────────────────┐
///  │ HaoTranNAS   │                              │
///  │ ● Connected  │   Overview / Backup / Files  │
///  │ ▣ Overview   │   / NAS / Settings           │
///  │ ⟳ Backup     │                              │
///  │ ▤ Files      │                              │
///  │ ⚙ NAS        │                              │
///  │ ☰ Settings   │                              │
///  └──────────────┴──────────────────────────────┘
/// ```
///
/// Connects to the NAS when it opens. Author: Hao Tran.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../admin/admin_controller.dart';
import '../app/desktop_providers.dart';
import 'admin_page.dart';
import 'backup_page.dart';
import 'files_page.dart';
import 'overview_page.dart';
import 'settings_page.dart';
import 'theme.dart';

/// The pages, in rail order.
enum AppPage {
  overview('Overview', Icons.space_dashboard_outlined, Icons.space_dashboard),
  backup('Backup', Icons.cloud_upload_outlined, Icons.cloud_upload),
  files('Files', Icons.folder_outlined, Icons.folder),
  nas('NAS', Icons.dns_outlined, Icons.dns),
  settings('Settings', Icons.settings_outlined, Icons.settings);

  const AppPage(this.label, this.icon, this.selectedIcon);

  final String label;
  final IconData icon;
  final IconData selectedIcon;
}

/// The page shown now; any page can switch it (e.g. "See all" links).
final currentPageProvider = NotifierProvider<CurrentPage, AppPage>(
  CurrentPage.new,
);

class CurrentPage extends Notifier<AppPage> {
  @override
  AppPage build() => AppPage.overview;

  void show(AppPage page) => state = page;
}

class HomeShell extends ConsumerStatefulWidget {
  const HomeShell({super.key});

  @override
  ConsumerState<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends ConsumerState<HomeShell> {
  @override
  void initState() {
    super.initState();
    Future.microtask(() {
      ref.read(serverConnectionProvider.notifier).connect();
      // Pairing just added this PC: the device list must show it.
      if (ref.read(adminProvider).target != null) {
        ref.read(adminProvider.notifier).refresh();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final page = ref.watch(currentPageProvider);
    final isWide = MediaQuery.sizeOf(context).width >= 1100;
    return Scaffold(
      body: Row(
        children: [
          NavigationRail(
            extended: isWide,
            labelType: isWide
                ? NavigationRailLabelType.none
                : NavigationRailLabelType.all,
            minExtendedWidth: 220,
            selectedIndex: page.index,
            onDestinationSelected: (index) => ref
                .read(currentPageProvider.notifier)
                .show(AppPage.values[index]),
            leading: _RailHeader(isWide: isWide),
            destinations: [
              for (final destination in AppPage.values)
                NavigationRailDestination(
                  icon: Icon(destination.icon),
                  selectedIcon: Icon(destination.selectedIcon),
                  label: Text(destination.label),
                ),
            ],
          ),
          const VerticalDivider(width: 1),
          Expanded(
            child: IndexedStack(
              index: page.index,
              children: const [
                OverviewPage(),
                BackupPage(),
                FilesPage(),
                AdminPage(),
                SettingsPage(),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// App name and the connection light at the top of the rail.
class _RailHeader extends ConsumerWidget {
  const _RailHeader({required this.isWide});

  final bool isWide;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = Theme.of(context).colorScheme;
    final link = ref.watch(serverConnectionProvider);
    final (color, text) = switch (link) {
      ServerOnline() => (okColor(colors), 'Connected'),
      ServerConnecting() => (colors.tertiary, 'Connecting…'),
      ServerOffline() => (colors.error, 'Offline'),
    };
    final logo = Icon(Icons.storage_rounded, color: colors.primary, size: 28);
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 20, 8, 24),
      child: isWide
          ? SizedBox(
              width: 190,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      logo,
                      const SizedBox(width: 10),
                      Flexible(
                        child: Text(
                          'HaoTranNAS',
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.titleLarge,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Icon(Icons.circle, size: 10, color: color),
                      const SizedBox(width: 8),
                      Flexible(
                        child: Text(
                          text,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            )
          : Tooltip(
              message: text,
              child: Badge(backgroundColor: color, child: logo),
            ),
    );
  }
}
