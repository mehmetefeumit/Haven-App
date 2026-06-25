/// Shared widget-test harness for localized screens.
///
/// With `nullable-getter: false` in `l10n.yaml`, any widget that calls
/// `AppLocalizations.of(context)` throws unless it is pumped under a
/// [MaterialApp] that registers the localization delegates. Use [pumpLocalized]
/// for every test that builds a localized page so the delegate is present and
/// the locale is deterministic.
///
/// The invariant for the i18n migration: when a screen's strings move to ARB,
/// its test harness moves to [pumpLocalized] in the same change — a missed one
/// fails loudly rather than silently rendering the wrong (or no) string.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/l10n/app_localizations.dart';

/// Default test locale. English keeps existing text assertions valid while the
/// extraction sweep is in progress (the English ARB values equal the strings
/// that were previously hardcoded).
const Locale kDefaultTestLocale = Locale('en');

/// Pumps [home] under a [ProviderScope] → [MaterialApp] wired with the full
/// localization delegates and the given [locale].
///
/// Pass provider [overrides] through unchanged. By default the tree settles;
/// set [settle] to `false` for screens with indefinite animations.
Future<void> pumpLocalized(
  WidgetTester tester,
  Widget home, {
  Locale locale = kDefaultTestLocale,
  List<Override> overrides = const [],
  bool settle = true,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: overrides,
      child: MaterialApp(
        locale: locale,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: home,
      ),
    ),
  );
  if (settle) {
    await tester.pumpAndSettle();
  }
}

/// Resolves [AppLocalizations] from the built tree, for asserting against the
/// generated getter instead of a raw English literal.
AppLocalizations l10nOf(WidgetTester tester, Type widgetType) {
  return AppLocalizations.of(tester.element(find.byType(widgetType)));
}
