#!/usr/bin/env dart
// arb_parity_check.dart — cross-locale ARB consistency gate for Haven.
//
// Pure Dart, no pub dependencies (uses only dart:io / dart:convert), so it runs
// without `flutter pub get`. Validates, against the English template
// (app_en.arb), that every translated ARB file:
//
//   1. has exactly the template's message keys (no missing, no extra);
//   2. uses exactly the template's placeholder set for each key;
//   3. has no empty message values;
//   4. supplies the CLDR plural categories required for its language on every
//      plural message (e.g. Arabic needs zero/one/two/few/many/other);
//   5. is not a verbatim copy of the English value (a likely-untranslated
//      string) — unless the key's @description says "intentionally English".
//
// Usage: dart scripts/ci/arb_parity_check.dart <arb-dir>
// Exit:  0 = all good, 1 = a violation, 2 = misconfiguration.

import 'dart:convert';
import 'dart:io';

/// CLDR cardinal plural categories required per language (current CLDR). A
/// category is satisfied either by its keyword branch (e.g. `few{...}`) or, for
/// the categories that have an exact-number equivalent, by an explicit branch
/// (`one`↔`=1`, `zero`↔`=0`, `two`↔`=2`). `few`/`many` have no explicit form.
const Map<String, Set<String>> _requiredPluralCategories = {
  'en': {'one', 'other'},
  'de': {'one', 'other'},
  'es': {'one', 'many', 'other'},
  'fr': {'one', 'many', 'other'},
  'ar': {'zero', 'one', 'two', 'few', 'many', 'other'},
};

const String _templateFile = 'app_en.arb';

void main(List<String> args) {
  if (args.length != 1) {
    stderr.writeln('Usage: dart arb_parity_check.dart <arb-dir>');
    exit(2);
  }
  final dir = Directory(args.single);
  if (!dir.existsSync()) {
    stderr.writeln('ERROR: directory not found: ${args.single}');
    exit(2);
  }

  final arbFiles = dir
      .listSync()
      .whereType<File>()
      .where((f) => f.path.endsWith('.arb'))
      .toList()
    ..sort((a, b) => a.path.compareTo(b.path));
  if (arbFiles.isEmpty) {
    stderr.writeln('ERROR: no .arb files in ${args.single}');
    exit(2);
  }

  final byName = <String, Map<String, dynamic>>{};
  for (final file in arbFiles) {
    final name = file.uri.pathSegments.last;
    try {
      byName[name] = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
    } on FormatException catch (e) {
      stderr.writeln('ERROR: $name is not valid JSON: ${e.message}');
      exit(1);
    }
  }
  if (!byName.containsKey(_templateFile)) {
    stderr.writeln('ERROR: template $_templateFile not found in ${args.single}');
    exit(2);
  }

  final template = byName[_templateFile]!;
  final templateKeys = _messageKeys(template);
  final templatePlaceholders = {
    for (final k in templateKeys) k: _placeholders(template[k] as String),
  };

  final errors = <String>[];

  byName.forEach((name, arb) {
    final keys = _messageKeys(arb);

    // (1) key parity.
    final missing = templateKeys.difference(keys);
    final extra = keys.difference(templateKeys);
    for (final k in missing) {
      errors.add('$name: missing key "$k"');
    }
    for (final k in extra) {
      errors.add('$name: unexpected key "$k" (not in $_templateFile)');
    }

    final locale = (arb['@@locale'] as String?) ?? _localeOf(name);

    for (final k in keys.intersection(templateKeys)) {
      final value = arb[k];
      if (value is! String) {
        errors.add('$name: key "$k" is not a string');
        continue;
      }

      // (3) no empty values.
      if (value.trim().isEmpty) {
        errors.add('$name: key "$k" has an empty value');
        continue;
      }

      // (2) placeholder parity.
      final ph = _placeholders(value);
      final expected = templatePlaceholders[k] ?? const <String>{};
      if (ph.length != expected.length || !ph.containsAll(expected)) {
        errors.add(
          '$name: key "$k" placeholders ${_sorted(ph)} '
          '!= template ${_sorted(expected)}',
        );
      }

      // (4) CLDR plural-category completeness.
      if (_isPlural(value)) {
        final required = _requiredPluralCategories[locale];
        if (required != null) {
          final provided = _pluralBranches(value);
          for (final cat in required) {
            if (!_satisfies(cat, provided)) {
              errors.add(
                '$name: plural key "$k" is missing the "$cat" category '
                'required for locale "$locale"',
              );
            }
          }
        }
      }

      // (5) untranslated-copy heuristic (non-template files only).
      if (name != _templateFile) {
        final templateValue = template[k];
        if (templateValue is String &&
            value == templateValue &&
            !_intentionallyEnglish(arb['@$k'])) {
          errors.add(
            '$name: key "$k" is identical to English — likely untranslated. '
            'If intentional, add "intentionally English" to its @description.',
          );
        }
      }
    }
  });

  if (errors.isNotEmpty) {
    errors.sort();
    for (final e in errors) {
      stderr.writeln('  - $e');
    }
    stderr.writeln('\nARB parity check FAILED (${errors.length} issue(s)).');
    exit(1);
  }
  stdout.writeln('ARB parity check PASSED for ${byName.length} file(s).');
}

Set<String> _messageKeys(Map<String, dynamic> arb) => arb.keys
    .where((k) => !k.startsWith('@'))
    .toSet();

/// Placeholder identifiers referenced in an ICU [message] (e.g. `{name}`,
/// `{count, plural, ...}` → `count`).
Set<String> _placeholders(String message) {
  final out = <String>{};
  for (final m in RegExp(r'\{\s*([a-zA-Z_]\w*)').allMatches(message)) {
    out.add(m.group(1)!);
  }
  return out;
}

bool _isPlural(String message) => RegExp(r',\s*plural\s*,').hasMatch(message);

/// The plural branch labels present in [message] (keyword categories like
/// `few` and explicit ones like `=1`).
Set<String> _pluralBranches(String message) {
  final out = <String>{};
  for (final m
      in RegExp(r'(=\d+|zero|one|two|few|many|other)\s*\{').allMatches(message)) {
    out.add(m.group(1)!);
  }
  return out;
}

/// Whether a required CLDR category is satisfied by the [provided] branches,
/// treating the exact-number forms as covering their keyword equivalents.
bool _satisfies(String category, Set<String> provided) {
  if (provided.contains(category)) return true;
  switch (category) {
    case 'zero':
      return provided.contains('=0');
    case 'one':
      return provided.contains('=1');
    case 'two':
      return provided.contains('=2');
    default:
      return false;
  }
}

bool _intentionallyEnglish(Object? meta) {
  if (meta is! Map) return false;
  final desc = meta['description'];
  return desc is String && desc.contains('intentionally English');
}

/// Best-effort locale from a filename like `app_ar.arb` → `ar`.
String _localeOf(String fileName) {
  final m = RegExp(r'app_([a-zA-Z]+)\.arb$').firstMatch(fileName);
  return m?.group(1) ?? '';
}

List<String> _sorted(Set<String> s) => s.toList()..sort();
