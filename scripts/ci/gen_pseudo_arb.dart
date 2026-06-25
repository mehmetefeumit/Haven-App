#!/usr/bin/env dart
// gen_pseudo_arb.dart — generate a pseudo-localized ARB for layout/overflow and
// un-extracted-string testing. Pure Dart, no pub deps.
//
// Reads the English template and writes a pseudo locale (`en-XA`) where every
// translatable message is accented and ~40% longer. Switch a debug build to
// en-XA to catch, BEFORE real translations land:
//   * any still-hardcoded English string (it shows un-accented);
//   * any layout that overflows / clips once strings grow.
//
// ICU placeholders and plural/select structure are preserved verbatim (only
// text at brace-depth 0 is transformed), so gen-l10n still parses the output.
//
// Usage (from haven/):
//   dart ../scripts/ci/gen_pseudo_arb.dart lib/l10n/app_en.arb lib/l10n/app_en_XA.arb
//   flutter gen-l10n
//   # run the app, switch language to the "English" pseudo entry, eyeball screens
//   # then delete lib/l10n/app_en_XA.arb (it is gitignored) and regenerate.
//
// The output is gitignored so it never ships or pollutes the production locale
// list / CI parity gate.

import 'dart:convert';
import 'dart:io';

// Accent map for ASCII letters — keeps them recognizable but visibly "foreign".
const Map<String, String> _accents = {
  'a': 'á', 'b': 'ḅ', 'c': 'ć', 'd': 'ḋ', 'e': 'é', 'f': 'ḟ', 'g': 'ǵ',
  'h': 'ḧ', 'i': 'í', 'j': 'ĵ', 'k': 'ḱ', 'l': 'ĺ', 'm': 'ḿ', 'n': 'ń',
  'o': 'ó', 'p': 'ṕ', 'q': 'q̇', 'r': 'ŕ', 's': 'ś', 't': 'ť', 'u': 'ú',
  'v': 'ṽ', 'w': 'ẃ', 'x': 'ẋ', 'y': 'ý', 'z': 'ź',
  'A': 'Á', 'B': 'Ḅ', 'C': 'Ć', 'D': 'Ḋ', 'E': 'É', 'F': 'Ḟ', 'G': 'Ǵ',
  'H': 'Ḧ', 'I': 'Í', 'J': 'Ĵ', 'K': 'Ḱ', 'L': 'Ĺ', 'M': 'Ḿ', 'N': 'Ń',
  'O': 'Ó', 'P': 'Ṕ', 'Q': 'Q̇', 'R': 'Ŕ', 'S': 'Ś', 'T': 'Ť', 'U': 'Ú',
  'V': 'Ṽ', 'W': 'Ẃ', 'X': 'Ẋ', 'Y': 'Ý', 'Z': 'Ź',
};

void main(List<String> args) {
  if (args.length != 2) {
    stderr.writeln('Usage: dart gen_pseudo_arb.dart <template.arb> <out.arb>');
    exit(2);
  }
  final template = File(args[0]);
  if (!template.existsSync()) {
    stderr.writeln('ERROR: template not found: ${args[0]}');
    exit(2);
  }

  final src = jsonDecode(template.readAsStringSync()) as Map<String, dynamic>;
  final out = <String, dynamic>{};
  for (final entry in src.entries) {
    if (entry.key == '@@locale') {
      out['@@locale'] = 'en-XA';
    } else if (entry.key.startsWith('@')) {
      out[entry.key] = entry.value; // metadata copied verbatim
    } else if (entry.value is String) {
      out[entry.key] = _pseudo(entry.value as String);
    } else {
      out[entry.key] = entry.value;
    }
  }

  const encoder = JsonEncoder.withIndent('  ');
  File(args[1]).writeAsStringSync('${encoder.convert(out)}\n');
  stdout.writeln('Wrote pseudo locale en-XA -> ${args[1]}');
}

/// Accents brace-depth-0 letters and pads the result ~40% longer. Anything
/// inside `{ ... }` (placeholders, plural/select syntax) is passed through
/// untouched so the message stays valid ICU.
String _pseudo(String message) {
  final buf = StringBuffer('⟦');
  var depth = 0;
  var letters = 0;
  for (final rune in message.runes) {
    final ch = String.fromCharCode(rune);
    if (ch == '{') {
      depth++;
      buf.write(ch);
    } else if (ch == '}') {
      if (depth > 0) depth--;
      buf.write(ch);
    } else if (depth == 0) {
      final accented = _accents[ch];
      if (accented != null) {
        letters++;
        buf.write(accented);
      } else {
        buf.write(ch);
      }
    } else {
      buf.write(ch);
    }
  }
  // ~40% expansion to surface overflow, scaled to the visible letter count.
  final pad = (letters * 0.4).ceil();
  buf
    ..write(' ')
    ..write('·' * pad)
    ..write('⟧');
  return buf.toString();
}
