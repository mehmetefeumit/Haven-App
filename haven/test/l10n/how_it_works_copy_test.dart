// Copy rules for the How It Works page, in EVERY supported locale.
//
// The page's claims are held true by the invariants each paragraph is
// registered under in docs/privacy/privacy_invariants.json. What this file
// holds are the owner's two rules for the copy itself:
//
//   1. no dash used as punctuation (em, en and their kin) in any locale's
//      rendering of the page;
//   2. the English reads in three to five minutes, at the 238 words a minute
//      an adult reads non-fiction silently (Brysbaert 2019, a meta-analysis
//      of 190 studies), so the page cannot quietly grow into a manual.
//
// Not covered: whether a translation is accurate or idiomatic. That is the
// reviewer half of the l10n workflow.
@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The dashes the rule bans: figure, en, em and horizontal bar (the one
/// Japanese prints as a long dash), and the two- and three-em dashes.
final _dash = RegExp(r'[\u2012\u2013\u2014\u2015\u2E3A\u2E3B]');

Map<String, String> _pageStrings(String locale) {
  final arb =
      jsonDecode(File('lib/l10n/app_$locale.arb').readAsStringSync())
          as Map<String, dynamic>;
  return {
    for (final e in arb.entries)
      if (e.key.startsWith('howItWorks') || e.key == 'settingsHowItWorksTitle')
        e.key: e.value as String,
  };
}

void main() {
  final locales =
      Directory('lib/l10n')
          .listSync()
          .whereType<File>()
          .map((f) => RegExp(r'app_(\w+)\.arb$').firstMatch(f.path)?.group(1))
          .whereType<String>()
          .toList()
        ..sort();

  test('every shipped locale is checked', () {
    expect(locales, contains('en'));
    expect(locales.length, greaterThanOrEqualTo(13));
  });

  for (final locale in locales) {
    test('$locale: the page carries no dash', () {
      final strings = _pageStrings(locale);
      expect(strings.length, greaterThanOrEqualTo(28));
      for (final MapEntry(:key, :value) in strings.entries) {
        expect(value, isNot(contains(_dash)), reason: '$key has a dash');
      }
    });
  }

  test('the English page reads in three to five minutes', () {
    const wordsPerMinute = 238;
    final words = _pageStrings('en').entries
        .where((e) => e.key != 'settingsHowItWorksTitle')
        .map((e) => e.value.split(RegExp(r'\s+')).length)
        .reduce((a, b) => a + b);
    expect(words, inInclusiveRange(3 * wordsPerMinute, 5 * wordsPerMinute));
  });
}
