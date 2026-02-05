/// App shell with bottom navigation for Haven.
///
/// Provides the main navigation structure with 4 tabs:
/// Map, Circles, Activity, and Settings.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:haven/src/pages/activity/activity_page.dart';
import 'package:haven/src/pages/circles/circles_page.dart';
import 'package:haven/src/pages/map/map_page.dart';
import 'package:haven/src/pages/settings/settings_page.dart';
import 'package:haven/src/providers/navigation_provider.dart';

/// Main app scaffold with bottom navigation.
///
/// Uses [IndexedStack] to preserve state across tab switches.
/// Navigation follows Material 3 guidelines with [NavigationBar].
class AppShell extends ConsumerWidget {
  /// Creates the app shell.
  const AppShell({super.key});

  /// Pages corresponding to each navigation destination.
  ///
  /// Order must match [_destinations] order.
  static const List<Widget> _pages = [
    MapPage(),
    CirclesPage(),
    ActivityPage(),
    SettingsPage(),
  ];

  /// Navigation destinations for the bottom bar.
  static const List<NavigationDestination> _destinations = [
    NavigationDestination(
      icon: Icon(Icons.map_outlined),
      selectedIcon: Icon(Icons.map),
      label: 'Map',
    ),
    NavigationDestination(
      icon: Icon(Icons.groups_outlined),
      selectedIcon: Icon(Icons.groups),
      label: 'Circles',
    ),
    NavigationDestination(
      icon: Icon(Icons.notifications_outlined),
      selectedIcon: Icon(Icons.notifications),
      label: 'Activity',
    ),
    NavigationDestination(
      icon: Icon(Icons.settings_outlined),
      selectedIcon: Icon(Icons.settings),
      label: 'Settings',
    ),
  ];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final currentIndex = ref.watch(navigationIndexProvider);

    return Scaffold(
      body: IndexedStack(index: currentIndex, children: _pages),
      bottomNavigationBar: NavigationBar(
        selectedIndex: currentIndex,
        onDestinationSelected: (index) {
          ref.read(navigationIndexProvider.notifier).state = index;
        },
        destinations: _destinations,
      ),
    );
  }
}
