// Guard for the "sharing survives the app being closed" claim, which has now
// been shipped and removed FOUR times (three ARB strings in backlog P0-2, then
// the iOS Info.plist usage description and the Play prominent-disclosure
// dialog). It is false on iOS: every native background wake path is
// receive-only — `HavenSLCHandler.swift` calls its own sweep "receive-only",
// and neither `catchup_service.dart` nor `ios_background_catchup.dart` has a
// publish call site — so once iOS ends the app, nothing the user shares
// resumes until they reopen Haven.
//
// It is TRUE on Android, and deliberately so: the foreground service is not
// stopped when the user swipes Haven out of recents (no `android:stopWithTask`
// in AndroidManifest.xml, which defaults to false), and that service publishes
// on its own timer. So the guard is not "never mention a closed app" — it is:
//
//   THE RULE: in copy that reaches an iOS user, a sentence may mention the app
//   not running only if the SAME sentence says what stops. Mentioning the
//   not-running state and leaving the consequence unstated is the claim.
//
// Stated that way it cannot be dodged by changing the verb ("keeps updated" →
// "stays in sync" → "continues"), which a literal-substring guard would miss.
//
// What it deliberately does NOT catch, so nobody over-trusts it: a claim that
// never names the not-running state at all (e.g. "Haven keeps your circles
// updated around the clock"), and a self-contradicting sentence that both
// asserts continuation and states the limit. The widget assertions below cover
// the realistic regression instead by pinning the promise each platform makes.
@TestOn('vm')
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/test_keys.dart';
import 'package:haven/src/widgets/location/location_disclosure_dialog.dart';

/// One sentence that names the app not running without stating what stops.
class BackgroundClaimViolation {
  BackgroundClaimViolation({required this.source, required this.sentence});

  /// Where the sentence came from (a plist key, or a rendered widget).
  final String source;

  /// The offending sentence, normalized.
  final String sentence;

  @override
  String toString() => '$source: "$sentence"';
}

/// Phrases naming a state in which the app is NOT running.
///
/// "not in use" / "not using it" are deliberately absent: they describe a
/// BACKGROUNDED app, which genuinely does keep sharing on both platforms.
final RegExp _notRunning = _anyOf([
  'app is closed',
  'app is not open',
  'app isn.t open',
  'haven is closed',
  'closes haven',
  'closes the app',
  'closes it',
  'close the app',
  'closed the app',
  'closing the app',
  'after you close',
  'when you close',
  'once you close',
  'terminat',
  'force.?quit',
  'quit the app',
  'swiped? (it |haven |the app )?away',
  'swipe.kill',
  'kills? the app',
  'killed the app',
  'not running',
  'isn.t running',
  'wakes the app',
  'next wakes',
  'system wake',
  'wake.up',
]);

/// Phrases stating the limit — what stops, and that it takes reopening.
final RegExp _statesTheLimit = _anyOf([
  'stops',
  'stopped',
  'stop sharing',
  'until you open it again',
  'until you reopen',
  'until you open haven',
  'resumes when you reopen',
  'resumes when you open',
  'only fetch',
  'only to fetch',
  'only receive',
  'receive.only',
  'never sends? yours',
  'does not send',
  'do not send',
]);

/// Builds a word-boundary-anchored alternation over [phrases].
RegExp _anyOf(List<String> phrases) => RegExp('\\b(${phrases.join('|')})');

/// Sentence terminators. Each sentence is judged alone, so a caveat in a later
/// sentence cannot launder a claim made in an earlier one.
final RegExp _sentenceEnd = RegExp('[.!?]');

/// Lowercases, folds typographic punctuation, and collapses whitespace so the
/// markers match regardless of the quote/dash style the copy happens to use.
String normalizeCopy(String text) => text
    .toLowerCase()
    .replaceAll('’', "'")
    .replaceAll('‘', "'")
    .replaceAll('—', ' ')
    .replaceAll('–', ' ')
    .replaceAll(RegExp(r'\s+'), ' ')
    .trim();

/// Returns every sentence in [text] that names the app not running without
/// stating what stops.
List<BackgroundClaimViolation> findUnqualifiedClosedAppClaims(
  String text, {
  required String source,
}) {
  final violations = <BackgroundClaimViolation>[];
  for (final raw in normalizeCopy(text).split(_sentenceEnd)) {
    final sentence = raw.trim();
    if (sentence.isEmpty) continue;
    if (_notRunning.hasMatch(sentence) && !_statesTheLimit.hasMatch(sentence)) {
      violations.add(
        BackgroundClaimViolation(source: source, sentence: sentence),
      );
    }
  }
  return violations;
}

/// Extracts every `NS*UsageDescription` value from an Info.plist body.
///
/// Tolerates XML comments between the key and its string (the location key
/// carries one), so a comment can never hide or shift a value.
Map<String, String> parseUsageDescriptions(String plist) {
  final pattern = RegExp(
    r'<key>(NS\w*UsageDescription)</key>\s*(?:<!--.*?-->\s*)*<string>(.*?)</string>',
    dotAll: true,
  );
  return {
    for (final m in pattern.allMatches(plist))
      m.group(1)!: m.group(2)!.replaceAll('&apos;', "'").replaceAll(
        '&amp;',
        '&',
      ),
  };
}

/// Every string the disclosure dialog actually renders on [isIOS].
///
/// Dismisses the dialog before returning: pumping a fresh host does NOT pop a
/// route that is already on the navigator, so a second call in the same test
/// would otherwise collect the first dialog's text and compare a platform
/// against itself.
Future<List<String>> renderedDisclosureText(
  WidgetTester tester, {
  required bool isIOS,
  required bool includeBackground,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => ElevatedButton(
            onPressed: () => LocationDisclosureDialog.show(
              context,
              includeBackground: includeBackground,
              isIOS: isIOS,
            ),
            child: const Text('Show dialog'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('Show dialog'));
  await tester.pumpAndSettle();
  final rendered = tester
      .widgetList<Text>(find.byType(Text))
      .map((t) => t.data ?? '')
      .where((s) => s.isNotEmpty)
      .toList();
  await tester.tap(find.byKey(WidgetKeys.locationDisclosureNotNow));
  await tester.pumpAndSettle();
  return rendered;
}

void main() {
  group('detector self-tests', () {
    test('flags the string the iOS permission prompt used to ship', () {
      const shipped =
          'Haven uses background location to keep your trusted circles '
          'updated even when the app is closed. Your location is always '
          'end-to-end encrypted.';
      expect(
        findUnqualifiedClosedAppClaims(shipped, source: 'x'),
        hasLength(1),
      );
    });

    test('flags the ARB claim removed by backlog P0-2', () {
      const removed =
          'If the system closes Haven, updates resume when you move or when '
          'the system next wakes the app.';
      expect(
        findUnqualifiedClosedAppClaims(removed, source: 'x'),
        hasLength(1),
      );
    });

    test('flags the Play sentence — the claim itself, merely true on '
        'Android', () {
      // The whole point of the platform split: this exact sentence must never
      // be what an iOS user reads.
      expect(
        findUnqualifiedClosedAppClaims(
          LocationDisclosureStrings.backgroundAndroid,
          source: 'x',
        ),
        hasLength(1),
      );
    });

    test('flags a reworded claim that shares no wording with the original', () {
      // A literal-substring guard is defeated here; this one is not.
      const reworded =
          'Your circles stay in sync around the clock, including after iOS '
          'terminates Haven.';
      expect(
        findUnqualifiedClosedAppClaims(reworded, source: 'x'),
        hasLength(1),
      );
    });

    test('permits naming the closed state when the limit is stated', () {
      const honest =
          'If iOS closes Haven, sharing stops until you open it again.';
      expect(findUnqualifiedClosedAppClaims(honest, source: 'x'), isEmpty);
    });

    test('permits "not in use" — a backgrounded app really does keep '
        'sharing', () {
      const backgrounded =
          'Haven keeps sharing with your circles while it is in the '
          'background and not in use.';
      expect(
        findUnqualifiedClosedAppClaims(backgrounded, source: 'x'),
        isEmpty,
      );
    });

    test('judges each sentence alone — a later caveat does not launder an '
        'earlier claim', () {
      const laundered =
          'Haven keeps your circles updated even when the app is closed. '
          'Sharing stops until you open it again.';
      final v = findUnqualifiedClosedAppClaims(laundered, source: 'x');
      expect(v, hasLength(1));
      expect(v.single.sentence, contains('app is closed'));
    });
  });

  group('iOS Info.plist usage descriptions', () {
    late Map<String, String> descriptions;

    setUpAll(() {
      final plist = File('ios/Runner/Info.plist');
      expect(
        plist.existsSync(),
        isTrue,
        reason: 'Expected to run from the haven package root '
            '(cwd=${Directory.current.path}).',
      );
      descriptions = parseUsageDescriptions(plist.readAsStringSync());
    });

    test('the parser actually found the usage descriptions (anti-vacuity)', () {
      // Without this, a broken regex would make every scan below pass by
      // finding nothing at all.
      expect(
        descriptions.keys,
        containsAll(<String>[
          'NSLocationWhenInUseUsageDescription',
          'NSLocationAlwaysAndWhenInUseUsageDescription',
          'NSCameraUsageDescription',
          'NSPhotoLibraryUsageDescription',
        ]),
        reason: 'Info.plist usage-description parse looks broken: '
            'found ${descriptions.keys.toList()}',
      );
    });

    test('no usage description claims sharing survives iOS closing the app',
        () {
      final offenders = <BackgroundClaimViolation>[];
      descriptions.forEach((key, value) {
        offenders.addAll(findUnqualifiedClosedAppClaims(value, source: key));
      });
      expect(
        offenders,
        isEmpty,
        reason:
            'An iOS usage description breaks THE RULE at the top of this file, '
            'and the user reads this string at the moment they grant the '
            'permission, so an over-claim here buys consent that was not '
            'informed.\nOffenders:\n  ${offenders.join('\n  ')}',
      );
    });

    test('the Always description still justifies Always specifically', () {
      // Apple requires a purpose string for the authorization being requested.
      // Fixing the false claim must not flatten it into something generic.
      final always =
          descriptions['NSLocationAlwaysAndWhenInUseUsageDescription']!;
      expect(always, contains('circles'));
      expect(
        normalizeCopy(always),
        contains('background'),
        reason: 'the Always string must still say what background access is '
            'for, not just what it is not',
      );
      expect(
        _statesTheLimit.hasMatch(normalizeCopy(always)),
        isTrue,
        reason: 'the Always string must state what happens after iOS closes '
            'Haven, since that is what the user is consenting to',
      );
    });
  });

  group('prominent-disclosure dialog', () {
    testWidgets('nothing an iOS user reads claims sharing survives iOS '
        'closing the app', (tester) async {
      final rendered = await renderedDisclosureText(
        tester,
        isIOS: true,
        includeBackground: true,
      );

      // Anti-vacuity: the dialog must actually have rendered its copy.
      expect(rendered, contains(LocationDisclosureStrings.title));
      expect(rendered, contains(LocationDisclosureStrings.backgroundIos));

      final offenders = <BackgroundClaimViolation>[];
      for (final text in rendered) {
        offenders.addAll(
          findUnqualifiedClosedAppClaims(text, source: 'iOS dialog'),
        );
      }
      expect(
        offenders,
        isEmpty,
        reason:
            'The Play prominent-disclosure dialog is shown on BOTH platforms '
            '(neither create_identity_screen.dart nor '
            'location_settings_page.dart gates it on Platform) and is the '
            "record of the user's consent, so THE RULE at the top of this file "
            'applies to it on iOS.\nOffenders:\n  ${offenders.join('\n  ')}',
      );
    });

    testWidgets('the iOS copy states the limit affirmatively', (tester) async {
      // Absence of a false claim is not the same as disclosing the truth.
      final rendered = await renderedDisclosureText(
        tester,
        isIOS: true,
        includeBackground: true,
      );
      final joined = normalizeCopy(rendered.join(' '));
      expect(
        _statesTheLimit.hasMatch(joined),
        isTrue,
        reason: 'iOS copy must say that sharing stops until the user reopens '
            'Haven, not merely omit the claim that it does not',
      );
    });

    testWidgets('Android keeps all three Play disclosure elements',
        (tester) async {
      // Android's behaviour is genuinely stronger; correcting iOS must not
      // weaken the Play artefact, which has to name the data, say it is
      // collected in the background, and say what it is for.
      final rendered = await renderedDisclosureText(
        tester,
        isIOS: false,
        includeBackground: true,
      );
      final joined = normalizeCopy(rendered.join(' '));

      expect(joined, contains('location data'), reason: 'names the data');
      expect(
        joined,
        contains('even when the app is closed or not in use'),
        reason: "states background collection, in Play's own wording",
      );
      expect(
        joined,
        contains('sharing with your circles'),
        reason: 'states the purpose',
      );
    });

    testWidgets('the background sentence differs by platform', (tester) async {
      // The iOS pass above must come from different copy, not from a detector
      // that flags nothing.
      final ios = await renderedDisclosureText(
        tester,
        isIOS: true,
        includeBackground: true,
      );
      final android = await renderedDisclosureText(
        tester,
        isIOS: false,
        includeBackground: true,
      );
      expect(
        ios,
        isNot(contains(LocationDisclosureStrings.backgroundAndroid)),
      );
      expect(android, contains(LocationDisclosureStrings.backgroundAndroid));
      expect(android, isNot(contains(LocationDisclosureStrings.backgroundIos)));
    });

    testWidgets('third-party policy is attributed, never asserted as '
        'Haven\u2019s own fact', (tester) async {
      // Haven cannot observe what Stadia Maps does with a request and nothing
      // re-checks their policy, so the disclosure reports it rather than
      // vouching for it — true whatever Stadia later changes.
      final rendered = await renderedDisclosureText(
        tester,
        isIOS: true,
        includeBackground: true,
      );
      final joined = rendered.join(' ');

      expect(
        joined,
        contains('Stadia Maps says'),
        reason: 'the third-party policy claims must stay attributed',
      );
      expect(
        joined,
        contains('Haven cannot enforce'),
        reason: 'the disclosure must not imply Haven can hold Stadia to it',
      );
      // Play still requires the third-party sharing itself to be disclosed.
      expect(joined, contains('does not sell or trade personal information'));
      expect(joined, contains('server logs'));
      expect(
        joined,
        isNot(contains('Stadia Maps does not sell')),
        reason: "unattributed assertion of another company's policy",
      );
    });
  });
}
