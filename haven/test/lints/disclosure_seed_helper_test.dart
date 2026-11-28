// E2E targets record an accepted background disclosure only through
// `seedLocationDisclosuresAccepted`. A target that wrote the bool alone would
// read as an older acceptance: MapShell's first foreground would put the
// updated disclosure over whatever the target drives, and sharing that starts
// again without the user opening Haven would stay withheld, so a lane would
// measure the wrong thing while looking green.
@TestOn('vm')
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/constants/location.dart';
import 'package:haven/src/providers/location_disclosure_provider.dart';
import 'package:haven/src/services/android_background_location.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../integration_test/e2e/_lib/location_disclosure_seed.dart';

/// Code with `//` comments removed, so prose naming a key is not a write.
String _code(String source) => source
    .split('\n')
    .map((line) {
      final at = line.indexOf('//');
      return at < 0 ? line : line.substring(0, at);
    })
    .join('\n');

void main() {
  const helper = 'integration_test/e2e/_lib/location_disclosure_seed.dart';
  final writes = RegExp(
    r'set(Bool|Int)\(\s*(kLocationDisclosureBackgroundAcceptedKey|'
    'kLocationDisclosureBackgroundVersionKey|'
    r"kLocationDisclosureBackgroundPromptedVersionKey|'haven\.location\."
    "disclosure_background_(accepted|version|prompted_version)')",
  );

  List<File> dartFiles() =>
      Directory('integration_test')
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.endsWith('.dart'))
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));

  test('the helper exists and writes all three background keys', () {
    final source = _code(File(helper).readAsStringSync());
    expect(
      writes.allMatches(source).map((m) => m.group(2)).toSet(),
      {
        'kLocationDisclosureBackgroundAcceptedKey',
        'kLocationDisclosureBackgroundVersionKey',
        'kLocationDisclosureBackgroundPromptedVersionKey',
      },
      reason:
          'anti-vacuity: the scan below proves nothing without its one '
          'sanctioned writer',
    );
  });

  test('a seeded user owes MapShell no consent dialog on Android 11+ without '
      '"Allow all the time"', () async {
    // A lane that seeds sharing on and mounts MapShell without granting the
    // background permission would otherwise find a modal over the map and
    // tap its barrier instead of the screen it drives.
    SharedPreferences.setMockInitialValues({kBackgroundSharingKey: true});
    final prefs = await SharedPreferences.getInstance();
    await seedLocationDisclosuresAccepted(prefs);

    // The iOS lanes seed through the same helper, and iPhone's resume needs
    // a later version than Android's.
    for (final isIOS in [false, true]) {
      expect(
        foregroundConsentStepDue(
          sharingOn: true,
          backgroundAccepted:
              prefs.getBool(kLocationDisclosureBackgroundAcceptedKey) ?? false,
          acceptedVersion:
              prefs.getInt(kLocationDisclosureBackgroundVersionKey) ?? 1,
          promptedVersion:
              prefs.getInt(kLocationDisclosureBackgroundPromptedVersionKey) ??
              0,
          allTime: BackgroundLocationStatus.failClosed,
          allTimePrompted:
              prefs.getBool(kAndroidBackgroundLocationPromptedKey) ?? false,
          isIOS: isIOS,
        ),
        ForegroundConsentStep.none,
        reason: isIOS ? 'iPhone' : 'Android',
      );
    }

    await clearLocationDisclosures(prefs);
    expect(prefs.getBool(kAndroidBackgroundLocationPromptedKey), isNull);
    expect(prefs.getInt(kLocationDisclosureBackgroundVersionKey), isNull);
  });

  test('no other integration_test file writes a background-disclosure key', () {
    final files = dartFiles();
    expect(files.length, greaterThan(10), reason: 'anti-vacuity: the tree');
    final offenders = <String>[
      for (final file in files)
        if (file.path.replaceAll(r'\', '/') != helper &&
            writes.hasMatch(_code(file.readAsStringSync())))
          file.path,
    ];
    expect(
      offenders,
      isEmpty,
      reason:
          'seed through seedLocationDisclosuresAccepted(prefs) instead '
          '(pass `version:` to seed an older acceptance on purpose)',
    );
  });

  test('the scan sees a bare write', () {
    expect(
      writes.hasMatch(
        _code(
          'await prefs.setBool(\n  kLocationDisclosureBackgroundAcceptedKey, '
          'true);',
        ),
      ),
      isTrue,
    );
    expect(
      writes.hasMatch(
        "prefs.setBool('haven.location.disclosure_background_accepted', true)",
      ),
      isTrue,
    );
    expect(
      writes.hasMatch(
        _code('// prefs.setBool(kLocationDisclosureBackgroundAcceptedKey, x)'),
      ),
      isFalse,
    );
  });
}
