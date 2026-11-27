/// The Android string resources Haven shows with no Flutter engine running —
/// the resume notice a boot or update posts (`ResumeNotice.kt`) and the
/// sharing text it repaints into the service notification (`BootResume.kt`).
///
/// The ARB is the source of truth, but nothing can read it at boot, before any
/// Dart has run: the resources must already be in the APK. So each one is a
/// hand-kept copy, and this test is what keeps it one. A
/// `values[-<lang>]/strings.xml` entry named `a_b_c` equals the ARB value of
/// `aBC` in that locale's file, for every locale that has the resource file;
/// every translated file carries exactly the entries the default one does;
/// and none of these strings takes a placeholder (native code fills none).
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

const _resDir = 'android/app/src/main/res';
const _l10nDir = 'lib/l10n';

/// `values` → `en`; `values-de` → `de`.
String _localeOf(Directory dir) {
  final name = dir.uri.pathSegments.where((s) => s.isNotEmpty).last;
  return name == 'values' ? 'en' : name.substring('values-'.length);
}

/// Name → text, unescaped as Android's resource compiler reads it.
Map<String, String> _strings(File file) {
  final xml = file.readAsStringSync();
  final entries = <String, String>{};
  for (final m in RegExp(
    '<string name="([a-z0-9_]+)">(.*?)</string>',
    dotAll: true,
  ).allMatches(xml)) {
    entries[m.group(1)!] = _unescape(m.group(2)!);
  }
  return entries;
}

String _unescape(String raw) => raw
    .replaceAll('&lt;', '<')
    .replaceAll('&gt;', '>')
    .replaceAll('&quot;', '"')
    .replaceAll('&apos;', "'")
    .replaceAll('&amp;', '&')
    .replaceAllMapped(
      RegExp(r'\\(.)'),
      (m) => switch (m.group(1)!) {
        'n' => '\n',
        't' => '\t',
        final c => c,
      },
    );

String _arbKey(String resourceName) {
  final parts = resourceName.split('_');
  return parts.first +
      parts.skip(1).map((p) => p[0].toUpperCase() + p.substring(1)).join();
}

Map<String, dynamic> _arb(String locale) {
  final file = File('$_l10nDir/app_$locale.arb');
  expect(
    file.existsSync(),
    isTrue,
    reason: 'res/values-$locale has no ARB counterpart ($file)',
  );
  return jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
}

void main() {
  final resourceFiles = Directory(_resDir)
      .listSync()
      .whereType<Directory>()
      .where((d) => d.uri.pathSegments.any((s) => s.startsWith('values')))
      .map((d) => File('${d.path}/strings.xml'))
      .where((f) => f.existsSync())
      .toList();

  test('the default resource file exists and holds the notice text', () {
    final defaults = File('$_resDir/values/strings.xml');
    expect(defaults.existsSync(), isTrue);
    expect(
      _strings(defaults).keys,
      containsAll(<String>[
        'fgs_notification_sharing',
        'android_resume_notice_title',
        'android_resume_notice_body',
        'android_resume_notice_channel_name',
      ]),
      reason: 'BootResume.kt and ResumeNotice.kt read these by name',
    );
  });

  for (final file in resourceFiles) {
    final locale = _localeOf(file.parent);
    test('values for "$locale" equal the ARB, entry for entry', () {
      final arb = _arb(locale);
      final strings = _strings(file);
      expect(strings, isNotEmpty, reason: '$file parsed to nothing');
      for (final MapEntry(key: name, value: text) in strings.entries) {
        final key = _arbKey(name);
        expect(
          arb[key],
          isA<String>(),
          reason: '$name has no "$key" in app_$locale.arb',
        );
        expect(
          text,
          arb[key],
          reason: '$file "$name" drifted from app_$locale.arb "$key"',
        );
        expect(
          text,
          isNot(contains('{')),
          reason: '"$key" must take no placeholder: native code fills none',
        );
      }
    });

    if (locale != 'en') {
      test('values-$locale carries exactly the default entries', () {
        expect(
          _strings(file).keys.toSet(),
          _strings(File('$_resDir/values/strings.xml')).keys.toSet(),
          reason:
              'a missing entry falls back to English on that phone; an '
              'extra one is text no default backs',
        );
      });
    }
  }
}
