/// The paired app: three tabs at the bottom, like most Android backup
/// apps (Immich, Google Photos). Author: Hao Tran.
///
/// ```
///  ┌──────────────────────────────┐
///  │  Backup | Files | Settings   │  tab body (each has its own app bar)
///  ├──────────────────────────────┤
///  │ ☁ Backup  📁 Files  ⚙ Settings│  NavigationBar
///  └──────────────────────────────┘
/// ```
///
/// The tabs stay alive while hidden (IndexedStack), so a folder open in
/// Files is still open after a look at Backup.
///
/// Coming back to the app (unlock, app switch) connects again when the
/// link is down; `connect()` does nothing when online or connecting.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app/providers.dart';
import 'browse_screen.dart';
import 'settings_screen.dart';
import 'status_screen.dart';

class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
  int _tabIndex = 0;
  late final AppLifecycleListener _lifecycle;

  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(
      onResume: () => ref.read(serverConnectionProvider.notifier).connect(),
    );
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: IndexedStack(
      index: _tabIndex,
      children: const [StatusScreen(), BrowseScreen(), SettingsScreen()],
    ),
    bottomNavigationBar: NavigationBar(
      selectedIndex: _tabIndex,
      onDestinationSelected: (index) => setState(() => _tabIndex = index),
      destinations: const [
        NavigationDestination(icon: Icon(Icons.backup), label: 'Backup'),
        NavigationDestination(icon: Icon(Icons.folder_open), label: 'Files'),
        NavigationDestination(icon: Icon(Icons.settings), label: 'Settings'),
      ],
    ),
  );
}
