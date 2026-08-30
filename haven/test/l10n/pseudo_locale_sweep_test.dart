/// Pseudo-locale sweep — LOCAL ONLY, requires `lib/l10n/app_en_XA.arb`.
///
/// Mechanises the manual check documented in `lib/l10n/README.md`, which asks
/// you to run the app in the accented pseudo locale and eyeball screens. Both
/// things that pass looks for are automatable, so they are asserted here
/// instead of trusted to a human at 200% text scale:
///
///   1. **Clipping / overflow.** Pseudo strings are accented and ~40% longer
///      than English, which is at the upper end of real expansion (de/ru/fa run
///      20–35%). Combined with a 200% text scale on a 320dp surface this is a
///      harsher case than any shipped locale.
///   2. **Un-extracted strings.** Every localized string comes back wrapped in
///      `⟦…⟧`. Any visible `Text` whose content is plain ASCII prose and is NOT
///      wrapped is a hardcoded literal that never reached the ARB.
///
/// This file is skipped automatically when the pseudo ARB is absent, so it is
/// inert in CI and for anyone who has not generated it. To run:
///
/// ```sh
/// dart ../scripts/ci/gen_pseudo_arb.dart lib/l10n/app_en.arb lib/l10n/app_en_XA.arb
/// # NOTE: the generator writes `@@locale: en-XA` but gen-l10n requires it to
/// # match the filename (`en_XA`), or the locale is silently skipped.
/// flutter gen-l10n && flutter test test/l10n/pseudo_locale_sweep_test.dart
/// rm lib/l10n/app_en_XA.arb && flutter gen-l10n
/// ```
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/l10n/app_localizations.dart';
import 'package:haven/src/pages/settings/about_page.dart';

import '../helpers/localized_app_harness.dart';

const _pseudo = Locale('en', 'XA');

/// Text that is legitimately not localized: brand names, versions, symbols.
bool _allowedUnwrapped(String s) {
  final t = s.trim();
  if (t.isEmpty) return true;
  // No lowercase ASCII letters → not prose (icons, symbols, digits, bullets).
  if (!RegExp(r'[a-z]{3,}').hasMatch(t)) return true;
  const allow = {'Haven', 'Version 0.1.0'};
  return allow.contains(t);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final hasPseudo = File('lib/l10n/app_en_XA.arb').existsSync() &&
      AppLocalizations.supportedLocales.any(
        (l) => l.languageCode == 'en' && l.countryCode == 'XA',
      );

  group('pseudo-locale sweep', skip: hasPseudo ? false : 'app_en_XA.arb absent', () {
    /// A narrow surface at double text scale — worse than any real device.
    void useHarshSurface(WidgetTester tester) {
      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = const Size(320, 1600);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
    }

    testWidgets('AboutPage does not overflow at 200% scale', (tester) async {
      useHarshSurface(tester);
      await pumpLocalized(
        tester,
        const AboutPage(),
        locale: _pseudo,
        textScaler: const TextScaler.linear(2),
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('AboutPage has no un-extracted strings', (tester) async {
      useHarshSurface(tester);
      await pumpLocalized(tester, const AboutPage(), locale: _pseudo);

      final leaks = <String>[];
      for (final w in tester.widgetList<Text>(find.byType(Text))) {
        final data = w.data;
        if (data == null) continue;
        if (data.contains('⟦')) continue;
        if (_allowedUnwrapped(data)) continue;
        leaks.add(data);
      }
      expect(
        leaks,
        isEmpty,
        reason: 'AboutPage renders hardcoded strings that never reached the ARB',
      );
    });
  });
}
