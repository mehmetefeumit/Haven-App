/// Language-selection page.
///
/// Lets the user pick the in-app language, or "System default" to follow the
/// device language. The selection is persisted via [localeControllerProvider]
/// and takes effect immediately across the whole app (the root [MaterialApp]
/// watches the provider), with no restart.
///
/// Languages are listed in their own **endonym** (the language's name in that
/// language, e.g. `Español`, `العربية`) — the platform-standard pattern, so a
/// user who reads only that language can still find it. Endonyms are therefore
/// intentionally NOT translated. The selectable set is derived from
/// [AppLocalizations.supportedLocales], so a language can never appear here
/// without a shipped ARB file.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:haven/l10n/app_localizations.dart';
import 'package:haven/src/l10n/language_helpers.dart';
import 'package:haven/src/providers/locale_provider.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// Page presenting the available languages as a single-selection list.
class LanguageSettingsPage extends ConsumerWidget {
  /// Creates the language settings page.
  const LanguageSettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final selected = ref.watch(localeControllerProvider);

    // System default first, then every shipped locale. Tying the list to
    // supportedLocales keeps the picker and the shipped ARB files in sync.
    final options = <Locale?>[null, ...AppLocalizations.supportedLocales];

    return Scaffold(
      appBar: AppBar(title: Text(l10n.appearanceLanguageTitle)),
      body: ListView(
        children: [
          for (final option in options)
            _LanguageTile(
              label: languageLabel(l10n, option),
              textDirection: languageEntryDirection(option),
              selected: option == selected,
              onTap: () => _select(context, ref, l10n, option),
            ),
        ],
      ),
    );
  }

  Future<void> _select(
    BuildContext context,
    WidgetRef ref,
    AppLocalizations l10n,
    Locale? locale,
  ) async {
    await ref.read(localeControllerProvider.notifier).setLocale(locale);
    if (!context.mounted) return;
    // Announce the new language for screen-reader users, in the direction of
    // the language they just chose (system default follows the ambient one).
    // Fire-and-forget: the announcement must not block returning to the page.
    unawaited(
      SemanticsService.sendAnnouncement(
        View.of(context),
        languageLabel(l10n, locale),
        languageEntryDirection(locale) ?? Directionality.of(context),
      ),
    );
    // Return to the Appearance page, whose language-row summary now updates.
    Navigator.of(context).pop();
  }
}

/// A single selectable language row: title + a trailing check when selected.
///
/// Selection is conveyed both visually (the check icon) and to screen readers
/// (`Semantics(selected: ...)`), never by colour or icon alone.
class _LanguageTile extends StatelessWidget {
  const _LanguageTile({
    required this.label,
    required this.selected,
    required this.onTap,
    this.textDirection,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;
  final TextDirection? textDirection;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Semantics(
      selected: selected,
      child: ListTile(
        title: Text(label, textDirection: textDirection),
        trailing: selected
            ? Icon(LucideIcons.check, color: colorScheme.primary)
            : null,
        onTap: onTap,
      ),
    );
  }
}
