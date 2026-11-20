// Static guard: an integration scenario that mounts the real `HavenApp` and
// asserts on its own `syncOwnProfile()` outcomes must own every sync pass.
//
// MapShell's cold-start timer and each resume start the app's own pass
// (`OwnProfileSyncController.retryIfPending`) whenever a save is pending, and
// the core's sync lock makes the second of two concurrent passes report
// `nothingPending` by design. A scenario that leaves the controller live
// therefore asserts on whichever pass won a race: `e2e_profile_sharing.dart`
// failed exactly so on iOS (CI run 44770359116, step 7). Overriding
// `ownProfileSyncProvider` in the scenario's ProviderScope closes it.
//
// Comment lines are stripped so a prose mention cannot satisfy the guard; the
// detector is unit-tested below so it cannot rot into a vacuous pass.
@TestOn('vm')
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _codeOnly(String source) => source
    .split('\n')
    .where((line) => !line.trimLeft().startsWith('//'))
    .join('\n');

/// Whether [source] mounts `HavenApp`, calls `syncOwnProfile()` itself, and
/// does not override `ownProfileSyncProvider`.
bool racesTheAppsProfileSync(String source) {
  final code = _codeOnly(source);
  final mountsApp = RegExp(r'\bHavenApp\s*\(').hasMatch(code);
  final syncsItself = RegExp(r'\.syncOwnProfile\s*\(').hasMatch(code);
  final ownsPasses = RegExp(
    r'\bownProfileSyncProvider\s*\.\s*overrideWith\b',
  ).hasMatch(code);
  return mountsApp && syncsItself && !ownsPasses;
}

void main() {
  group('profile-sync owner detector', () {
    test('flags a scenario that mounts the app and syncs itself', () {
      const source = '''
await tester.pumpWidget(const ProviderScope(child: HavenApp()));
final r = await profileService.syncOwnProfile();
''';
      expect(racesTheAppsProfileSync(source), isTrue);
    });

    test('accepts one that overrides the controller', () {
      const source = '''
await tester.pumpWidget(ProviderScope(
  overrides: [ownProfileSyncProvider.overrideWith(_Inert.new)],
  child: const HavenApp(),
));
final r = await profileService.syncOwnProfile();
''';
      expect(racesTheAppsProfileSync(source), isFalse);
    });

    test('a commented-out override does not count', () {
      const source = '''
await tester.pumpWidget(const ProviderScope(child: HavenApp()));
// ownProfileSyncProvider.overrideWith(_Inert.new),
final r = await profileService.syncOwnProfile();
''';
      expect(racesTheAppsProfileSync(source), isTrue);
    });

    test('ignores a scenario that never calls syncOwnProfile itself', () {
      const source = '''
await tester.pumpWidget(const ProviderScope(child: HavenApp()));
''';
      expect(racesTheAppsProfileSync(source), isFalse);
    });
  });

  test('every integration scenario that syncs its own profile owns the '
      'passes', () {
    final dir = Directory('integration_test');
    expect(dir.existsSync(), isTrue, reason: 'run from the haven/ package');
    final scenarios = dir
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.dart'))
        .toList();
    final syncing = scenarios
        .where(
          (f) => _codeOnly(f.readAsStringSync()).contains('.syncOwnProfile('),
        )
        .map((f) => f.path)
        .toList();
    expect(
      syncing,
      contains(endsWith('e2e_profile_sharing.dart')),
      reason: 'the scan must reach the scenario it was written for',
    );
    final offenders = scenarios
        .where((f) => racesTheAppsProfileSync(f.readAsStringSync()))
        .map((f) => f.path)
        .toList();
    expect(
      offenders,
      isEmpty,
      reason:
          'these mount HavenApp and assert on syncOwnProfile() while the '
          "app's own OwnProfileSyncController can start a pass beside it; "
          'override ownProfileSyncProvider in their ProviderScope',
    );
  });
}
