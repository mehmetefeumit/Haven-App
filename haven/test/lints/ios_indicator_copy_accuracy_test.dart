// Ties the iOS settings copy to the native policy that decides what the user
// can actually SEE, in English, at the source (`app_en.arb` + the Swift).
//
// The card used to say, unconditionally, that "iOS shows a blue status-bar
// indicator". That was true only while Haven holds a
// `CLBackgroundActivitySession`, which is inseparable from the blue bar. Under
// a CONFIRMED "Always" the handler holds none — `HavenBackgroundSessionHandler`
// gates it on `!alwaysConfirmed`, and `HavenLocationStreamHandler` clears
// `showsBackgroundLocationIndicator` from the same predicate — so that user
// sees only the OS's status-bar arrow, and the old sentence promised them an
// indicator that is not there.
//
// So the card is now two sentences: a base that names NO indicator, then
// exactly one of two indicator sentences chosen by the handler's own state.
// This guard pins the vocabulary split that makes the choice meaningful:
//
//   * the BASE may not name an indicator at all — it renders under both
//     states, so any indicator word in it is false for one of them;
//   * the ARROW sentence may not name the blue bar, and must name the arrow
//     and the status bar it appears in;
//   * the BAR sentence and the While-In-Use note must name the blue location
//     bar, in that ONE noun — "indicator"/"pill" are not synonyms a reader can
//     match against what they see.
//
// It also pins the SELECTION, in both languages: Swift decides the activity
// session and the indicator flag from `alwaysConfirmed`, exports that field on
// its status channel, and Dart chooses the sentence from the same field —
// never from `backgroundActivitySessionHeld`, which is structurally false on
// the iOS 15/16 floor of the deployment target while those users are looking
// at the bar.
//
// Deliberately NOT forbidden: the bare word "bar". The arrow sentence has to
// say "status bar", and a guard that banned the word would force that sentence
// to describe the arrow without naming where it appears. The forbidden token
// is the noun PHRASE "blue location bar".
//
// The 13-locale half of this tie lives in
// `test/l10n/location_settings_copy_accuracy_test.dart`.
@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The tier-neutral first sentence. Renders under both indicator states.
const kBase = 'locationSettingsIosGuidance';

/// Selected when the handler reports `alwaysConfirmed` (a confirmed Always).
const kArrow = 'locationSettingsIosIndicatorArrow';

/// Selected on every other reading, in all of which the blue bar is up.
const kBar = 'locationSettingsIosIndicatorBar';

/// The When-In-Use note. The blue bar is mandatory OS behaviour there.
const kLimited = 'locationSettingsIosLimitedNote';

/// Every key this guard covers.
const kAllKeys = [kBase, kArrow, kBar, kLimited];

/// The noun phrase for the blue bar. NEVER the bare word "bar".
const kBlueBarPhrase = 'blue location bar';

/// Indicator vocabulary the BASE sentence may not use.
const kIndicatorWords = ['blue', kBlueBarPhrase, 'indicator', 'arrow'];

/// Battery promises. "low-power" was rejected: the session runs at GPS
/// accuracy whenever the user is moving or the screen is on, and the claim is
/// only verifiable on hardware this project does not have.
const kBatteryPromises = ['low-power', 'low power'];

/// Words for a state the card does not have. The session is never paused and
/// nothing in it is on a user-visible timer.
const kStateWords = ['pause', 'paused', 'timer'];

/// The forbidden terms [value] contains, out of [terms].
List<String> violations(String value, List<String> terms) {
  final haystack = value.toLowerCase();
  return [for (final t in terms) if (haystack.contains(t.toLowerCase())) t];
}

/// The message values of `app_en.arb`, keyed by message name.
Map<String, String> loadEnglishArb() {
  final file = File('lib/l10n/app_en.arb');
  expect(
    file.existsSync(),
    isTrue,
    reason: 'Expected to run from the haven package root '
        '(cwd=${Directory.current.path}).',
  );
  final decoded = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
  return {
    for (final e in decoded.entries)
      if (!e.key.startsWith('@') && e.value is String) e.key: e.value as String,
  };
}

/// The uncommented line of [source] that decides whether the activity session
/// (and with it the blue bar) is held, or null if it is gone.
///
/// The whole guard is conditional on this line: it is the reason an arrow
/// sentence exists at all, and if the tier branch is removed the copy has to be
/// re-derived rather than silently kept.
String? activitySessionPolicyLine(String source) {
  for (final raw in source.split('\n')) {
    final line = raw.trim();
    if (line.startsWith('//')) continue;
    if (line.contains('wantsActivitySession') && line.contains('=') &&
        line.contains('!alwaysConfirmed')) {
      return line;
    }
  }
  return null;
}

/// The uncommented line of [source] that asks the OS for the location
/// indicator, or null if it no longer follows `alwaysConfirmed`.
///
/// The other half of the native decision, and the half that reaches the users
/// the activity session cannot: `CLBackgroundActivitySession` is iOS 17+ and
/// Haven deploys to iOS 15.5, so on iOS 15/16 this flag is the ONLY thing
/// putting the bar on screen.
String? indicatorFlagPolicyLine(String source) {
  for (final raw in source.split('\n')) {
    final line = raw.trim();
    if (line.startsWith('//')) continue;
    if (line.contains('showsBackgroundLocationIndicator') &&
        line.contains('=') &&
        line.contains('!') &&
        line.contains('alwaysConfirmed')) {
      return line;
    }
  }
  return null;
}

/// The body of the Swift function whose declaration line contains
/// [signature], or null when that function is gone.
///
/// Sliced from the declaration to the first line that is exactly the closing
/// brace at the declaration's own indentation — the shape every method in
/// `HavenBackgroundSessionHandler` has. Comment lines are dropped, so a
/// commented-out assignment cannot stand in for a real one.
String? swiftFunctionBody(String source, String signature) {
  final lines = source.split('\n');
  final start = lines.indexWhere((l) => l.contains(signature));
  if (start == -1) return null;
  final indent = ' ' * (lines[start].length - lines[start].trimLeft().length);
  final body = StringBuffer();
  for (final raw in lines.skip(start + 1)) {
    if (raw == '$indent}') return body.toString();
    if (!raw.trim().startsWith('//')) body.writeln(raw);
  }
  return null;
}

/// Whether [source] still puts `alwaysConfirmed` on the wire.
///
/// The predicate is OWNED by `HavenBackgroundSessionHandler` and CONSUMED in
/// two other places — the stream handler's indicator flag and, over this
/// channel, the Dart sentence selector. Dropping the key from the status map
/// leaves no compile error anywhere: Dart's parse simply falls back to false
/// forever, and every confirmed-Always user is promised a bar again.
bool statusExportsAlwaysConfirmed(String source) {
  for (final raw in source.split('\n')) {
    final line = raw.trim();
    if (line.startsWith('//')) continue;
    if (line.startsWith('"alwaysConfirmed":')) return true;
  }
  return false;
}

/// Whether [source] still puts `armed` on the wire.
///
/// The qualifier that makes `alwaysConfirmed` readable at all. Dropping the
/// key leaves no compile error: Dart's parse falls back to false, every
/// reading becomes "not armed", and the card silently stops rendering for
/// everyone — the copy would be gone rather than wrong, which is the failure
/// nobody reports.
bool statusExportsArmed(String source) {
  for (final raw in source.split('\n')) {
    final line = raw.trim();
    if (line.startsWith('//')) continue;
    if (line.startsWith('"armed":')) return true;
  }
  return false;
}

/// The code (comments stripped) of `iosIndicatorSentenceProvider` in [source].
///
/// Comments are dropped because the provider's own doc comment NAMES the field
/// it deliberately does not select on; a scan that read the prose would report
/// the very violation the prose exists to prevent.
String indicatorProviderBody(String source) {
  final lines = source.split('\n');
  final start = lines.indexWhere(
    (l) => l.startsWith('final iosIndicatorSentenceProvider'),
  );
  expect(start, isNot(-1), reason: 'iosIndicatorSentenceProvider is gone');
  final body = StringBuffer();
  for (final raw in lines.skip(start)) {
    final line = raw.trim();
    if (!line.startsWith('//')) body.writeln(line);
    if (line == '});') break;
  }
  return body.toString();
}

void main() {
  late Map<String, String> arb;

  setUpAll(() {
    arb = loadEnglishArb();
  });

  group('the native policy this copy is tied to', () {
    test('the handler still releases the activity session on a CONFIRMED '
        'Always', () {
      final swift = File('ios/Runner/HavenBackgroundSessionHandler.swift');
      expect(swift.existsSync(), isTrue);
      expect(
        activitySessionPolicyLine(swift.readAsStringSync()),
        isNotNull,
        reason: 'The arrow sentence exists because a confirmed Always holds no '
            'CLBackgroundActivitySession. If that branch is gone, every user '
            'sees the blue bar again and the card must say so — re-derive the '
            'copy, do not delete this assertion.',
      );
    });

    test('the OS indicator is still asked for from the same predicate', () {
      final swift = File('ios/Runner/HavenLocationStreamHandler.swift');
      expect(swift.existsSync(), isTrue);
      expect(
        indicatorFlagPolicyLine(swift.readAsStringSync()),
        isNotNull,
        reason: 'showsBackgroundLocationIndicator is what shows the bar on '
            'every iOS below 17, where no activity session can exist. If it '
            'stops following !alwaysConfirmed, the sentence the page picks is '
            'no longer the one the OS obeys.',
      );
    });

    test('the predicate the copy is selected on still reaches Dart', () {
      final swift = File('ios/Runner/HavenBackgroundSessionHandler.swift');
      expect(
        statusExportsAlwaysConfirmed(swift.readAsStringSync()),
        isTrue,
        reason: 'the sentence selector reads this key over the status channel; '
            'without it the parse falls back to false and the page promises a '
            'blue bar to every confirmed-Always user, silently.',
      );
    });

    test('the handler still records whether it is armed at all', () {
      // `alwaysConfirmed` is a MEASUREMENT that only a held `.always` session's
      // diagnostics can make, and `disarm()` clears it unconditionally — so
      // while sharing is off its `false` says "nothing is running", not "not
      // Always". Without this second predicate the two are one value, and the
      // page reads a teardown residue as a verdict and promises the blue bar
      // to a reader who may get the arrow the moment they turn sharing on.
      final swift = File('ios/Runner/HavenBackgroundSessionHandler.swift');
      final source = swift.readAsStringSync();

      final arm = swiftFunctionBody(source, 'func arm()');
      expect(arm, isNotNull, reason: 'arm() is gone');
      expect(
        arm,
        contains('armed = true'),
        reason: 'arm() no longer records that its gates passed, so a running '
            'session is indistinguishable from a torn-down one and the '
            'settings card can never render',
      );

      final disarm = swiftFunctionBody(source, 'func disarm()');
      expect(disarm, isNotNull, reason: 'disarm() is gone');
      expect(
        disarm,
        contains('armed = false'),
        reason: 'disarm() no longer clears the arming, so the cleared '
            'alwaysConfirmed beside it reads as a measured "not Always" — '
            'exactly the conflation this predicate exists to end',
      );

      expect(
        statusExportsArmed(source),
        isTrue,
        reason: 'the sentence selector reads this key over the status '
            'channel; without it the parse falls back to false and the card '
            'disappears for every user, silently',
      );
    });

    test('Dart declines to name an indicator while the handler is not '
        'armed', () {
      final body = indicatorProviderBody(
        File('lib/src/providers/service_providers.dart').readAsStringSync(),
      );
      expect(
        body,
        contains('armed'),
        reason: 'without this gate the provider answers from a predicate the '
            'last disarm() wrote — "$body"',
      );
      expect(
        body,
        contains('return null'),
        reason: 'the honest answer for an unmeasured tier is no sentence at '
            'all; the page already renders no card for a null — "$body"',
      );
    });

    test('Dart selects the sentence on alwaysConfirmed, never on the held '
        'session', () {
      // The two sources are pinned against each other so a change to either
      // one fails: Swift decides both the activity session and the indicator
      // flag from `alwaysConfirmed`, so anything else in Dart is a second,
      // divergent policy. `backgroundActivitySessionHeld` was that second
      // policy — false for the whole iOS 15/16 cohort, who see the bar.
      final body = indicatorProviderBody(
        File('lib/src/providers/service_providers.dart').readAsStringSync(),
      );
      expect(
        body,
        contains('alwaysConfirmed'),
        reason: 'the sentence must be selected on the value both native '
            'branches decide from — "$body"',
      );
      expect(
        body,
        isNot(contains('backgroundActivitySessionHeld')),
        reason: 'CLBackgroundActivitySession is iOS 17+ and Haven deploys to '
            'iOS 15.5, so this field is false for users who are looking at '
            'the blue bar — "$body"',
      );
    });
  });

  group('app_en.arb', () {
    test('every key this guard covers exists and is non-empty '
        '(anti-vacuity)', () {
      // Without this a renamed key would make every scan below pass by
      // scanning nothing.
      for (final key in kAllKeys) {
        expect(arb[key]?.trim(), isNotNull, reason: key);
        expect(arb[key]!.trim(), isNotEmpty, reason: key);
      }
    });

    test('the base sentence names no indicator', () {
      expect(
        violations(arb[kBase]!, kIndicatorWords),
        isEmpty,
        reason: 'The base renders under BOTH indicator states, so naming one '
            'is false for the other — "${arb[kBase]}"',
      );
    });

    test('the arrow sentence names the arrow and the status bar, never the '
        'blue bar', () {
      final arrow = arb[kArrow]!.toLowerCase();
      expect(arrow, contains('arrow'), reason: arb[kArrow]);
      expect(
        arrow,
        contains('status bar'),
        reason: 'the arrow is only findable if the copy says where it is — '
            '"${arb[kArrow]}"',
      );
      expect(
        violations(arrow, const ['blue', kBlueBarPhrase]),
        isEmpty,
        reason: 'this sentence is selected exactly when no activity session is '
            'held, i.e. when there is no blue bar — "${arb[kArrow]}"',
      );
    });

    test('the bar sentence and the While-In-Use note name the blue location '
        'bar', () {
      for (final key in const [kBar, kLimited]) {
        expect(
          arb[key]!.toLowerCase(),
          contains(kBlueBarPhrase),
          reason: '$key must name what the user sees in ONE noun — '
              '"${arb[key]}"',
        );
      }
    });

    test('no key makes a battery promise', () {
      for (final key in kAllKeys) {
        expect(
          violations(arb[key]!, kBatteryPromises),
          isEmpty,
          reason: '$key: the session runs at GPS accuracy while moving or '
              'foregrounded, and no device measurement backs the claim — '
              '"${arb[key]}"',
        );
      }
    });

    test('no key invents a pause or a timer', () {
      for (final key in kAllKeys) {
        expect(
          violations(arb[key]!, kStateWords),
          isEmpty,
          reason: '$key: Haven has no pause control and shows no countdown — '
              '"${arb[key]}"',
        );
      }
    });

    test('breadcrumbs use the arrow a screen reader speaks', () {
      // VoiceOver and TalkBack read "→" and skip "›", so a path written with
      // "›" is silently unnavigable. `locationSettingsAndroidBattery` set the
      // convention.
      for (final key in kAllKeys) {
        expect(
          arb[key],
          isNot(contains('›')),
          reason: '$key uses "›", which screen readers do not speak; use '
              '"→" — "${arb[key]}"',
        );
      }
    });
  });

  group('scanner self-tests', () {
    test('"status bar" is clean while "blue location bar" is flagged', () {
      // The trap this guard was nearly built with: forbidding the bare word
      // "bar" would have failed the arrow sentence, which HAS to say where the
      // arrow appears.
      expect(
        violations('iOS shows its arrow in the status bar.', const [
          kBlueBarPhrase,
        ]),
        isEmpty,
      );
      expect(
        violations('iOS shows its blue location bar.', const [kBlueBarPhrase]),
        contains(kBlueBarPhrase),
      );
      expect(
        kIndicatorWords,
        isNot(contains('bar')),
        reason: 'the forbidden token is the noun phrase, never the bare word',
      );
    });

    test('the old, now-false base sentence would be caught', () {
      expect(
        violations(
          'While background sharing is on, Haven keeps a continuous location '
          'session and iOS shows a blue status-bar indicator.',
          kIndicatorWords,
        ),
        containsAll(<String>['blue', 'indicator']),
      );
    });

    test('the policy reader ignores a commented-out branch', () {
      expect(
        activitySessionPolicyLine(
          '// let wantsActivitySession = status == .authorizedWhenInUse || '
          '!alwaysConfirmed',
        ),
        isNull,
      );
      expect(
        activitySessionPolicyLine(
          '      let wantsActivitySession = status == .authorizedWhenInUse || '
          '!alwaysConfirmed',
        ),
        isNotNull,
      );
    });

    test('the indicator-flag reader needs the negation, not just the name', () {
      expect(
        indicatorFlagPolicyLine(
          '    manager.showsBackgroundLocationIndicator = '
          '!(sessionHandler?.alwaysConfirmed ?? false)',
        ),
        isNotNull,
      );
      expect(
        indicatorFlagPolicyLine(
          '    manager.showsBackgroundLocationIndicator = false',
        ),
        isNull,
        reason: 'a flag pinned to a constant no longer tracks the tier, and '
            'the copy would have to be re-derived',
      );
    });

    test('the function slicer stops at the function it was asked for', () {
      const source = '''
final class Handler {
  func arm() {
    armed = true
  }

  func disarm() {
    // armed = true
    armed = false
  }
}
''';
      expect(swiftFunctionBody(source, 'func arm()'), contains('armed = true'));
      expect(
        swiftFunctionBody(source, 'func arm()'),
        isNot(contains('armed = false')),
        reason: 'the slice must end at its own closing brace, or every check '
            'reads the whole file and passes on the wrong function',
      );
      expect(
        swiftFunctionBody(source, 'func disarm()'),
        isNot(contains('armed = true')),
        reason: 'a commented-out assignment is not an assignment',
      );
      expect(swiftFunctionBody(source, 'func nothing()'), isNull);
    });

    test('the armed-export reader wants the key, not the field', () {
      expect(statusExportsArmed('      "armed": armed,'), isTrue);
      expect(statusExportsArmed('  // "armed": armed,'), isFalse);
      expect(
        statusExportsArmed('  private(set) var armed = false'),
        isFalse,
        reason: 'the field existing is not the field being exported',
      );
    });

    test('the status-export reader wants the key, not a mention of it', () {
      const exported = '      "alwaysConfirmed": alwaysConfirmed,';
      expect(statusExportsAlwaysConfirmed(exported), isTrue);
      expect(statusExportsAlwaysConfirmed('  // $exported'), isFalse);
      expect(
        statusExportsAlwaysConfirmed(
          '  private(set) var alwaysConfirmed = false',
        ),
        isFalse,
        reason: 'the field existing is not the field being exported',
      );
    });

    test('the provider reader sees the code, not the doc comment', () {
      // The realistic false pass and the realistic false failure, in one
      // pair: the provider's doc comment names the rejected field, and a
      // scanner that read it would fail on the prose that prevents the bug.
      const declaration = '''
final iosIndicatorSentenceProvider = FutureProvider<IosIndicatorSentence>((
  ref,
) async {
  final status = await ref.read(iosBackgroundSessionServiceProvider).status();
  return status.alwaysConfirmed
      ? IosIndicatorSentence.arrow
      : IosIndicatorSentence.bar;
});
final somethingElse = 1;
''';
      const prose = '/// NOT backgroundActivitySessionHeld: it is iOS 17+.\n';

      final body = indicatorProviderBody(prose + declaration);
      expect(body, contains('alwaysConfirmed'));
      expect(body, isNot(contains('backgroundActivitySessionHeld')));
      expect(
        body,
        isNot(contains('somethingElse')),
        reason: 'the reader must stop at the provider it was asked for',
      );

      expect(
        indicatorProviderBody(declaration.replaceAll(
          'status.alwaysConfirmed',
          'status.backgroundActivitySessionHeld',
        )),
        contains('backgroundActivitySessionHeld'),
        reason: 'stripping comments must not also strip the code',
      );
    });
  });
}
