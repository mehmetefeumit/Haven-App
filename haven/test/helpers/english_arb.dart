/// Reads the English (template) ARB, for tests that tie a constant to the
/// user-facing string quoting it.
///
/// Only the template is checked — a translated numeral is a translation
/// concern, gated by `scripts/ci/arb_parity_check.dart`.
library;

import 'dart:convert';
import 'dart:io';

/// Returns the English (template) string for [key], throwing if it is absent
/// so a renamed key fails loudly instead of comparing against nothing.
String englishArb(String key) {
  final arb =
      jsonDecode(File('lib/l10n/app_en.arb').readAsStringSync())
          as Map<String, dynamic>;
  final value = arb[key];
  if (value is! String) {
    throw StateError('$key is missing from app_en.arb (or is not a string)');
  }
  return value;
}
