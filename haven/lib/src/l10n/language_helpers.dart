/// Shared display helpers for the language selector.
///
/// Endonyms (each language's own name) and RTL classification live here — not
/// on a page — so the picker, the Appearance summary row, and any future
/// language entry point all render the same label and text direction. Endonyms
/// are intentionally NOT translated: a language's own name does not change with
/// the UI language.
library;

import 'package:flutter/widgets.dart';
import 'package:haven/l10n/app_localizations.dart';

/// Language codes that render right-to-left.
const Set<String> kRtlLanguages = {'ar', 'fa', 'ur'};

/// Endonyms — each language's name written in that language, keyed by
/// `languageCode`. Kept in sync with [kRtlLanguages] and the shipped ARB files
/// so a newly-shipped locale always has a readable label.
const Map<String, String> kEndonyms = {
  'en': 'English',
  'es': 'Español',
  'fr': 'Français',
  'de': 'Deutsch',
  'ar': 'العربية',
  'tr': 'Türkçe',
  'ne': 'नेपाली',
  'pt': 'Português',
  'ru': 'Русский',
  'hi': 'हिन्दी',
  'ja': '日本語',
  'fa': 'فارسی',
  'ur': 'اردو',
};

/// The user-facing label for [locale] (`null` = system default).
///
/// Used by both the picker and the Appearance language row so the two never
/// disagree. Falls back to the raw language code for a locale with no endonym
/// mapping (should not happen for shipped locales).
String languageLabel(AppLocalizations l10n, Locale? locale) {
  if (locale == null) return l10n.languageSystemDefault;
  return kEndonyms[locale.languageCode] ?? locale.languageCode;
}

/// The [TextDirection] an entry's label should render in, independent of the
/// ambient direction, so an LTR endonym stays readable inside an RTL list (and
/// vice-versa). `null` for system default — it follows the ambient direction.
TextDirection? languageEntryDirection(Locale? locale) {
  if (locale == null) return null;
  return kRtlLanguages.contains(locale.languageCode)
      ? TextDirection.rtl
      : TextDirection.ltr;
}
