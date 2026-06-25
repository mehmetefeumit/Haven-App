/// App-language (locale) state provider.
///
/// Persists the user's language choice to [SharedPreferences] and exposes it as
/// a [StateNotifierProvider] so the root [MaterialApp] reacts immediately — no
/// restart. A `null` state means "follow the device locale" (system default).
///
/// # Why this mirrors the theme-mode provider
///
/// It is the audited precedent for an app-wide, persisted, flicker-free
/// preference:
///
/// * Each mutation awaits the [SharedPreferences] write **before** updating the
///   in-memory state, so a process kill between storage and memory cannot leave
///   the two out of sync.
/// * The provider is overridden at the root in `main.dart` with the value
///   pre-loaded by [loadInitialLocale] before `runApp`, so the first frame
///   renders in the correct language with no flash of the wrong one.
///
/// # Privacy
///
/// The persisted value is a BCP-47 language subtag (e.g. `es`, `ar`) with no
/// identity, location, or cryptographic material. It is read **only** by the
/// root `MaterialApp` to set `locale`; it must never flow into a relay/circle/
/// location service or a Nostr event builder. `scripts/ci/check_locale_privacy.sh`
/// enforces this as a standing regression guard.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:haven/l10n/app_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// [SharedPreferences] key under which the selected language subtag is stored.
const String kLocaleKey = 'haven.locale.tag';

/// Loads the persisted [Locale] from [SharedPreferences].
///
/// Intended to be awaited in `main.dart` before `runApp` so the root
/// [MaterialApp] renders the user's chosen language on the very first frame.
///
/// Returns `null` (follow the device locale) when nothing is stored, or — like
/// the theme provider's defensive `_decode` — when the stored value is not a
/// currently-supported locale. This guards against a corrupted preferences file
/// or a value written by a future build that shipped a language this build no
/// longer supports; with `nullable-getter: false`, resolving to an unsupported
/// locale would otherwise risk a hard throw.
///
/// Only the language subtag is persisted and compared, which is sufficient for
/// Haven's supported languages. A future script-variant language (e.g.
/// `zh-Hant`) would require switching to [Locale.fromSubtags] here.
Future<Locale?> loadInitialLocale() async {
  final prefs = await SharedPreferences.getInstance();
  final tag = prefs.getString(kLocaleKey);
  if (tag == null || tag.isEmpty) return null;
  final code = tag.split('-').first;
  for (final supported in AppLocalizations.supportedLocales) {
    if (supported.languageCode == code) return Locale(code);
  }
  return null;
}

/// [StateNotifier] holding the user's selected [Locale] (`null` = system).
///
/// Mutations persist to [SharedPreferences] before updating in-memory state.
// TODO(i18n): migrate to Notifier/NotifierProvider alongside
// themeModeControllerProvider (StateNotifier is soft-deprecated in Riverpod).
class LocaleController extends StateNotifier<Locale?> {
  /// Creates a controller seeded with [initial] (`null` = follow device).
  ///
  /// In production the root [ProviderScope] overrides the provider with the
  /// value pre-loaded by [loadInitialLocale]. Tests may pass any value.
  LocaleController(super.initial);

  /// Persists [locale] (or clears the override when `null`) and updates state.
  ///
  /// No-op if [locale] equals the current state — avoids a redundant disk write
  /// when a user re-taps the already-selected language. Persists the language
  /// subtag only. Writes to disk **before** mutating state so a process kill
  /// between the two cannot desync them (mirrors the theme provider).
  Future<void> setLocale(Locale? locale) async {
    if (state == locale) return;
    final prefs = await SharedPreferences.getInstance();
    if (locale == null) {
      await prefs.remove(kLocaleKey);
    } else {
      await prefs.setString(kLocaleKey, locale.languageCode);
    }
    if (!mounted) return;
    state = locale;
  }
}

/// Provides the [LocaleController] and the current [Locale] (`null` = system).
///
/// The default factory yields `null` (follow device); the production root
/// overrides this with a value pre-loaded from [SharedPreferences] before
/// `runApp` to guarantee no first-frame language flicker.
final localeControllerProvider =
    StateNotifierProvider<LocaleController, Locale?>(
      (ref) => LocaleController(null),
    );
