/// Tests that user-facing numbers render in each locale's CLDR numbering
/// system and grouping, so users see the digits/grouping they expect rather
/// than always-Western, raw-interpolated numbers.
///
/// The per-locale outcome is delivered by intl/CLDR (no custom digit
/// substitution): Persian and Nepali use native digits; Hindi keeps Western
/// digits but Indian (lakh) grouping; Arabic, Urdu and English use Western
/// digits — all "what locals have an easier time with" per the CLDR defaults.
library;

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/l10n/app_localizations.dart';

Future<AppLocalizations> _load(String code) =>
    AppLocalizations.delegate.load(Locale(code));

void main() {
  test('commonNumber uses each locale CLDR numbering system', () async {
    // Western-digit locales (CLDR "latn" default).
    expect((await _load('en')).commonNumber(3), '3');
    expect((await _load('ar')).commonNumber(3), '3');
    expect((await _load('ur')).commonNumber(3), '3');
    expect((await _load('hi')).commonNumber(3), '3');
    // Native-digit locales.
    expect((await _load('fa')).commonNumber(3), '۳'); // Persian
    expect((await _load('ne')).commonNumber(3), '३'); // Devanagari
  });

  test('numbers get locale-appropriate grouping (not raw interpolation)',
      () async {
    // English: thousands grouping.
    expect((await _load('en')).commonNumber(1234567), '1,234,567');
    // Hindi: Indian (lakh/crore) grouping even with Western digits.
    expect((await _load('hi')).commonNumber(1234567), '12,34,567');
  });

  test('plural counts localize the digit in the displayed branch', () async {
    // count = 3 is the "other" category for both; both embed {count}.
    expect((await _load('fa')).commonMemberCount(3), contains('۳'));
    expect((await _load('ne')).commonMemberCount(3), contains('३'));
  });
}
