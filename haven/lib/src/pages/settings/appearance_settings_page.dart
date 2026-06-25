/// Appearance settings page (formerly "Theme").
///
/// Hosts two preferences that change how the app looks and reads:
///
/// * **Theme** — system / light / dark, persisted via
///   [themeModeControllerProvider]; takes effect immediately app-wide.
/// * **Language** — a row summarising the current choice that opens
///   [LanguageSettingsPage]; persisted via [localeControllerProvider].
///
/// Both apply live (the root [MaterialApp] watches both providers), with no
/// restart. This page is fully localized; it is the first surface to exercise
/// the gen-l10n pipeline.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:haven/l10n/app_localizations.dart';
import 'package:haven/src/l10n/language_helpers.dart';
import 'package:haven/src/pages/settings/language_settings_page.dart';
import 'package:haven/src/providers/locale_provider.dart';
import 'package:haven/src/providers/theme_mode_provider.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// Page presenting the theme options and the language selector.
class AppearanceSettingsPage extends ConsumerWidget {
  /// Creates the appearance settings page.
  const AppearanceSettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final selectedMode = ref.watch(themeModeControllerProvider);
    final locale = ref.watch(localeControllerProvider);
    final colorScheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(title: Text(l10n.appearanceTitle)),
      body: ListView(
        children: [
          _SectionHeader(label: l10n.appearanceThemeHeader),
          RadioGroup<ThemeMode>(
            groupValue: selectedMode,
            onChanged: (mode) {
              if (mode == null) return;
              ref.read(themeModeControllerProvider.notifier).setMode(mode);
            },
            child: Column(
              children: [
                RadioListTile<ThemeMode>(
                  value: ThemeMode.system,
                  secondary: const Icon(LucideIcons.smartphone),
                  title: Text(l10n.appearanceThemeSystem),
                  subtitle: Text(l10n.appearanceThemeSystemSubtitle),
                ),
                RadioListTile<ThemeMode>(
                  value: ThemeMode.light,
                  secondary: const Icon(LucideIcons.sun),
                  title: Text(l10n.appearanceThemeLight),
                  subtitle: Text(l10n.appearanceThemeLightSubtitle),
                ),
                RadioListTile<ThemeMode>(
                  value: ThemeMode.dark,
                  secondary: const Icon(LucideIcons.moon),
                  title: Text(l10n.appearanceThemeDark),
                  subtitle: Text(l10n.appearanceThemeDarkSubtitle),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          ListTile(
            leading: Icon(
              LucideIcons.languages,
              color: colorScheme.onSurfaceVariant,
            ),
            title: Text(l10n.appearanceLanguageTitle),
            subtitle: Text(languageLabel(l10n, locale)),
            trailing: const _DisclosureChevron(),
            onTap: () {
              Navigator.push(
                context,
                MaterialPageRoute<void>(
                  builder: (context) => const LanguageSettingsPage(),
                ),
              );
            },
          ),
        ],
      ),
    );
  }
}

/// A list-section header styled per Material 3, exposed as a semantic header so
/// screen readers can navigate by heading.
class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final colorScheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsetsDirectional.fromSTEB(16, 16, 16, 8),
      child: Semantics(
        header: true,
        child: Text(
          label,
          style: textTheme.labelLarge?.copyWith(color: colorScheme.primary),
        ),
      ),
    );
  }
}

/// Trailing disclosure chevron that mirrors under right-to-left text direction
/// (the Lucide chevron, unlike a Material directional icon, does not flip).
class _DisclosureChevron extends StatelessWidget {
  const _DisclosureChevron();

  @override
  Widget build(BuildContext context) {
    final pointsLeft = Directionality.of(context) == TextDirection.rtl;
    return Icon(
      pointsLeft ? LucideIcons.chevronLeft : LucideIcons.chevronRight,
    );
  }
}
