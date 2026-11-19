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
library;

import 'package:flutter/material.dart';

import 'browse_screen.dart';
import 'settings_screen.dart';
import 'status_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  int _tabIndex = 0;

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
