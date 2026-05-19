/// Theme-selection page.
///
/// Allows the user to pick between the system default, light, or dark
/// theme. The selection is persisted via [themeModeControllerProvider] and
/// takes effect immediately across the entire app.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:haven/src/providers/theme_mode_provider.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// User-visible metadata for a single [ThemeMode] choice.
@immutable
class _ThemeChoice {
  const _ThemeChoice({
    required this.mode,
    required this.title,
    required this.subtitle,
    required this.icon,
  });

  final ThemeMode mode;
  final String title;
  final String subtitle;
  final IconData icon;
}

const List<_ThemeChoice> _choices = [
  _ThemeChoice(
    mode: ThemeMode.system,
    title: 'System default',
    subtitle: 'Match your device settings',
    icon: LucideIcons.smartphone,
  ),
  _ThemeChoice(
    mode: ThemeMode.light,
    title: 'Light',
    subtitle: 'Always use the light theme',
    icon: LucideIcons.sun,
  ),
  _ThemeChoice(
    mode: ThemeMode.dark,
    title: 'Dark',
    subtitle: 'Always use the dark theme',
    icon: LucideIcons.moon,
  ),
];

/// Returns the user-facing label for [mode]. Used by the settings tile to
/// summarize the current selection without duplicating the strings here.
///
/// Implemented as an exhaustive [switch] so a future Flutter SDK that adds
/// a new [ThemeMode] value produces a compile error instead of silently
/// falling back to "System default".
String themeModeLabel(ThemeMode mode) {
  switch (mode) {
    case ThemeMode.system:
      return 'System default';
    case ThemeMode.light:
      return 'Light';
    case ThemeMode.dark:
      return 'Dark';
  }
}

/// Page presenting the three [ThemeMode] options as a radio group.
class ThemeSettingsPage extends ConsumerWidget {
  /// Creates the theme settings page.
  const ThemeSettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final selected = ref.watch(themeModeControllerProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Theme')),
      body: RadioGroup<ThemeMode>(
        groupValue: selected,
        onChanged: (mode) {
          if (mode == null) return;
          ref.read(themeModeControllerProvider.notifier).setMode(mode);
        },
        child: ListView(
          children: [
            for (final choice in _choices)
              RadioListTile<ThemeMode>(
                value: choice.mode,
                title: Text(choice.title),
                subtitle: Text(choice.subtitle),
                secondary: Icon(choice.icon),
              ),
          ],
        ),
      ),
    );
  }
}
