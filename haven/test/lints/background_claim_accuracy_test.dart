// Guard for what copy may say about sharing after Haven is closed.
//
// The unconditional "sharing survives the app being closed" claim has been
// shipped and removed FOUR times (three ARB strings in backlog P0-2, then the
// iOS Info.plist usage description and the Play prominent-disclosure dialog).
// Until 2026-11-26 every iOS wake path was receive-only and the copy said so.
// The owner then directed (OD-R1, owner-directed 2026-11-26) that a process iOS
// relaunches for a location event resumes the user's own sharing — but only
// under 'Always', only after movement (a significant change or leaving a 200 m
// region), only after the first unlock following a restart, only for a user who
// accepted the current background disclosure, and only when iOS chooses to
// relaunch. While Using is never relaunched. The wake handlers themselves
// (`HavenSLCHandler.swift`, `catchup_service.dart`,
// `ios_background_catchup.dart`) still have no publish call site; the relaunch
// publishes through MapShell's
// burst plane. So "a wake only fetches, never sends" is now FALSE for an
// 'Always' user, and an unconditional resume claim is false for everybody.
//
// On Android the foreground service is not stopped by a swipe (no
// `android:stopWithTask`) and publishes on its own timer, so the Play sentence
// "even when the app is closed" is true there and false on iOS. The guard is
// therefore not "never mention a closed app"; it is:
//
//   THE RULE (v2): in copy that reaches an iOS user, a sentence that names the
//   app being closed must state the outcome in the SAME sentence — that
//   sharing stops, or that it starts again only under the whole condition:
//   'Always', the movement, and that iOS decides (not guaranteed). And copy
//   that says sharing starts again after Haven is closed must also state the
//   While-Using limit: under 'While Using the App' it stays stopped until the
//   user opens Haven.
//
// Stated that way it cannot be dodged by changing the verb ("keeps updated" →
// "stays in sync" → "continues"), which a literal-substring guard would miss.
//
// The receive-only wording is checked separately and is now itself a finding:
// copy an iOS user reads may no longer say a wake only fetches or never sends.
//
// What it deliberately does NOT catch, so nobody over-trusts it: a claim that
// never names the closed state at all (e.g. "Haven keeps your circles updated
// around the clock"), and a self-contradicting sentence that both asserts
// continuation and states the stop or the condition. The widget assertions
// below cover the realistic regression instead by pinning the promise each
// platform makes.
//
// A second tie lives here too. Two surfaces state the iPhone resume claim —
// the consent dialog's iOS sentence and `locationSettingsIntroIos`, the iPhone
// half of the Location settings page's opening paragraph — and they word it
// differently on purpose,
// so what is compared is the CLAIM (its conditions), never the bytes.
@TestOn('vm')
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/l10n/app_localizations.dart';
import 'package:haven/src/test_keys.dart';
import 'package:haven/src/widgets/location/location_disclosure_dialog.dart';

/// One sentence that breaks a rule of this file.
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

/// Phrases stating the stop — that sharing stops, or does not start again,
/// until the user opens Haven.
final RegExp _statesTheStop = _anyOf([
  'stops',
  'stopped',
  'stop sharing',
  'until you open it again',
  'until you reopen',
  'until you open haven',
  'resumes when you reopen',
  'resumes when you open',
  'will not start (it |sharing )?again',
  'won.t start (it |sharing )?again',
]);

/// The whole condition under which iOS resumes sharing after Haven is closed.
/// A sentence that names the closed state without stating the stop must carry
/// EVERY one of these, or it promises more than iOS delivers.
final Map<String, RegExp> _resumeCondition = {
  "names 'Always'": RegExp(r'\balways\b'),
  'names the movement': RegExp(r'\b(moved|metres|meters)\b'),
  'says iOS decides': RegExp(r'\b(not guaranteed|ios decides|ios allows)\b'),
};

/// The While-Using limit: under that authorization sharing stays stopped
/// until the user opens Haven, because iOS never relaunches it.
final RegExp _whileUsingLimit = RegExp(
  r'\bwhile using\b[^.]*\b(stops|until you open|when you open)\b',
);

/// A claim that sharing starts again by itself after Haven is closed.
final RegExp _resumeVerb = RegExp(
  r'\b(starts?|start) (sharing )?again by itself\b',
);

/// The receive-only wording, true until 2026-11-26 and now false for an
/// 'Always' user: a relaunch may send.
final RegExp _receiveOnlyWording = _anyOf([
  'only (to )?fetch',
  'only receive',
  'receive.only',
  'never (to )?sends? yours',
  'does not send',
  'do not send',
]);

/// Builds a word-boundary-anchored alternation over [phrases].
RegExp _anyOf(List<String> phrases) => RegExp('\\b(${phrases.join('|')})');

/// Sentence terminators. Each sentence is judged alone, so a caveat in a later
/// sentence cannot launder a claim made in an earlier one.
final RegExp _sentenceEnd = RegExp('[.!?]');

/// The iPhone resume claim, as predicates that must hold on EVERY surface
/// stating it.
///
/// The consent dialog and the Location settings page word this differently and
/// legitimately so — one is a Play disclosure shown before a permission prompt,
/// the other a settings paragraph that also covers Android — so the tie between
/// them is the CLAIM, never the bytes. Each predicate is written against a
/// fact: Haven can be closed; under 'Always' sharing then starts again by
/// itself; only after movement; never before the first unlock after a restart;
/// only when iOS decides; and under While Using it waits for an open. Drop any
/// one from either surface and the two stop promising the same thing.
final Map<String, RegExp> _resumeClaim = {
  'names Haven being closed': _notRunning,
  'says sharing starts again by itself': _resumeVerb,
  ..._resumeCondition,
  'names the first unlock after a restart': RegExp(r'\bunlocked?\b'),
  'says While Using waits for an open': RegExp(
    r'\bwhile using\b[^.]*\b(until you open|when you open)\b',
  ),
};

/// Which predicates of [_resumeClaim] [text] actually carries.
Map<String, bool> resumeClaimProfile(String text) {
  final normalized = normalizeCopy(text);
  return {
    for (final entry in _resumeClaim.entries)
      entry.key: entry.value.hasMatch(normalized),
  };
}

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

List<String> _sentences(String text) => [
  for (final raw in normalizeCopy(text).split(_sentenceEnd))
    if (raw.trim().isNotEmpty) raw.trim(),
];

/// Returns every sentence in [text] that names the app being closed without
/// stating the stop or the whole resume condition (THE RULE, first half).
List<BackgroundClaimViolation> findUnqualifiedClosedAppClaims(
  String text, {
  required String source,
}) {
  final violations = <BackgroundClaimViolation>[];
  for (final sentence in _sentences(text)) {
    final qualified =
        _statesTheStop.hasMatch(sentence) ||
        _resumeCondition.values.every((r) => r.hasMatch(sentence));
    if (_notRunning.hasMatch(sentence) && !qualified) {
      violations.add(
        BackgroundClaimViolation(source: source, sentence: sentence),
      );
    }
  }
  return violations;
}

/// Returns the resume claims in [text] when [text] nowhere states the
/// While-Using limit (THE RULE, second half). [text] is one surface: the
/// limit may sit in another sentence of it, never in another surface. A
/// sentence saying sharing will NOT start again is a stop, not a claim.
List<BackgroundClaimViolation> findResumeClaimsWithoutWhileUsingLimit(
  String text, {
  required String source,
}) {
  if (_whileUsingLimit.hasMatch(normalizeCopy(text))) return const [];
  return [
    for (final sentence in _sentences(text))
      if (_notRunning.hasMatch(sentence) &&
          _resumeVerb.hasMatch(sentence) &&
          !_statesTheStop.hasMatch(sentence))
        BackgroundClaimViolation(source: source, sentence: sentence),
  ];
}

/// Returns every sentence in [text] that still says a wake only fetches or
/// never sends — the receive-only claim the owner retired on 2026-11-26.
List<BackgroundClaimViolation> findReceiveOnlyWording(
  String text, {
  required String source,
}) => [
  for (final sentence in _sentences(text))
    if (_receiveOnlyWording.hasMatch(sentence))
      BackgroundClaimViolation(source: source, sentence: sentence),
];

/// Every rule of this file over one iOS surface.
List<BackgroundClaimViolation> findAllViolations(
  String text, {
  required String source,
}) => [
  ...findUnqualifiedClosedAppClaims(text, source: source),
  ...findResumeClaimsWithoutWhileUsingLimit(text, source: source),
  ...findReceiveOnlyWording(text, source: source),
];

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
      m.group(1)!: m
          .group(2)!
          .replaceAll('&apos;', "'")
          .replaceAll('&amp;', '&'),
  };
}

/// Every string the disclosure dialog actually renders on [isIOS], in
/// re-confirm mode when [reconfirm].
///
/// Dismisses the dialog before returning: pumping a fresh host does NOT pop a
/// route that is already on the navigator, so a second call in the same test
/// would otherwise collect the first dialog's text and compare a platform
/// against itself.
Future<List<String>> renderedDisclosureText(
  WidgetTester tester, {
  required bool isIOS,
  required bool includeBackground,
  bool reconfirm = false,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      // The consent copy is ARB-backed, so without the delegates the dialog
      // throws instead of rendering and every scan below would see nothing.
      locale: const Locale('en'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: Builder(
          builder: (context) => ElevatedButton(
            onPressed: () => LocationDisclosureDialog.show(
              context,
              includeBackground: includeBackground,
              reconfirm: reconfirm,
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

/// The iOS consent sentence as it shipped before 2026-11-26 — now false for an
/// 'Always' user, so it must be caught if a revert or an untranslated locale
/// brings it back.
const _oldIosConsentSentence =
    'This app uses location data to enable sharing with your circles even when '
    'Haven is in the background and you are not using it. If iOS closes Haven, '
    'sharing stops until you open it again — Haven may still wake up to fetch '
    'your circles’ locations, but never to send yours.';

/// The Always usage description as it shipped before 2026-11-26.
const _oldAlwaysDescription =
    'Haven shares your location with your trusted circles while it runs in the '
    "background. After iOS closes Haven, it wakes only to fetch your circles' "
    'locations; your own sharing resumes when you reopen Haven. Your location '
    'is always end-to-end encrypted.';

void main() {
  // The consent copy lives in the ARB now (`locationDisclosure*`), so the
  // English values are read the way the app reads them — through the generated
  // localizations — rather than from constants a refactor could quietly detach
  // from what actually renders.
  late AppLocalizations en;

  setUpAll(() async {
    en = await AppLocalizations.delegate.load(const Locale('en'));
  });

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
          en.locationDisclosureBackgroundAndroid,
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

    test('flags an unconditional resume claim', () {
      const unconditional =
          'If Haven is closed, sharing starts again by itself.';
      expect(
        findUnqualifiedClosedAppClaims(unconditional, source: 'x'),
        hasLength(1),
      );
    });

    test('flags a resume claim that drops any ONE condition', () {
      // Each variant states two of the three conditions: partial is not
      // enough, because each one is something iOS really requires.
      const variants = {
        "names 'Always'":
            'If Haven is closed, sharing starts again by itself once you have '
            'moved a few hundred metres; iOS decides when.',
        'names the movement':
            "With 'Always', if Haven is closed, sharing starts again by "
            'itself; iOS decides when, so it is not guaranteed.',
        'says iOS decides':
            "With 'Always', if Haven is closed, sharing starts again by "
            'itself once you have moved a few hundred metres.',
      };
      expect(variants.keys.toSet(), _resumeCondition.keys.toSet());
      variants.forEach((dropped, sentence) {
        expect(
          findUnqualifiedClosedAppClaims(sentence, source: 'x'),
          hasLength(1),
          reason: 'a resume claim that no longer $dropped must be caught',
        );
      });
    });

    test('permits a resume claim that states the whole condition', () {
      const conditional =
          "With 'Always', if Haven is closed, sharing starts again by itself "
          'once you have moved a few hundred metres; iOS decides when, so it '
          'is not guaranteed.';
      expect(findUnqualifiedClosedAppClaims(conditional, source: 'x'), isEmpty);
    });

    test('permits naming the closed state when the stop is stated', () {
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

    test('flags a conditional resume claim that omits the While-Using limit, '
        'and passes it once the limit is stated', () {
      const resume =
          'With Always, if Haven is closed it starts sharing again by itself '
          'once you have moved a few hundred metres, when iOS allows it.';
      expect(
        findResumeClaimsWithoutWhileUsingLimit(resume, source: 'x'),
        hasLength(1),
      );
      expect(
        findResumeClaimsWithoutWhileUsingLimit(
          '$resume With While Using the App, sharing stops when Haven is '
          'closed until you open it again.',
          source: 'x',
        ),
        isEmpty,
      );
    });

    test('the old receive-only sentences are now caught', () {
      // An untranslated or reverted string must go red: since 2026-11-26 a
      // relaunch under 'Always' may send, so "only fetch, never send" is false.
      for (final old in [_oldIosConsentSentence, _oldAlwaysDescription]) {
        expect(
          findReceiveOnlyWording(old, source: 'x'),
          isNotEmpty,
          reason: 'still reads as current copy: "$old"',
        );
      }
    });
  });

  group('iOS Info.plist usage descriptions', () {
    late Map<String, String> descriptions;

    setUpAll(() {
      final plist = File('ios/Runner/Info.plist');
      expect(
        plist.existsSync(),
        isTrue,
        reason:
            'Expected to run from the haven package root '
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
        reason:
            'Info.plist usage-description parse looks broken: '
            'found ${descriptions.keys.toList()}',
      );
    });

    test('no usage description claims sharing resumes after Haven is closed '
        'without stating its condition', () {
      final offenders = <BackgroundClaimViolation>[];
      descriptions.forEach((key, value) {
        offenders.addAll(findAllViolations(value, source: key));
      });
      expect(
        offenders,
        isEmpty,
        reason:
            'An iOS usage description breaks a rule at the top of this file, '
            'and the user reads this string at the moment they grant the '
            'permission, so an over-claim here buys consent that was not '
            'informed.\nOffenders:\n  ${offenders.join('\n  ')}',
      );
    });

    test('the Always description justifies Always and states the resume '
        'condition', () {
      // Apple requires a purpose string for the authorization being requested,
      // and Always is exactly what buys the relaunch that resumes sharing.
      final always = normalizeCopy(
        descriptions['NSLocationAlwaysAndWhenInUseUsageDescription']!,
      );
      expect(always, contains('circles'));
      expect(
        always,
        contains('background'),
        reason:
            'the Always string must still say what background access is '
            'for, not just what it is not',
      );
      expect(
        _resumeVerb.hasMatch(always),
        isTrue,
        reason:
            'the Always string must say what Always now buys: sharing '
            'that starts again by itself after Haven is closed',
      );
      for (final condition in _resumeCondition.entries) {
        expect(
          condition.value.hasMatch(always),
          isTrue,
          reason: 'the Always string ${condition.key} no longer',
        );
      }
      expect(
        _whileUsingLimit.hasMatch(always),
        isTrue,
        reason:
            'the prompt also offers While Using, so it must say that '
            'choice does not resume after Haven is closed',
      );
    });
  });

  group('prominent-disclosure dialog', () {
    /// Renders the iOS dialog and returns every sentence breaking a rule.
    Future<List<BackgroundClaimViolation>> iosDialogViolations(
      WidgetTester tester, {
      required bool reconfirm,
    }) async {
      final rendered = await renderedDisclosureText(
        tester,
        isIOS: true,
        includeBackground: true,
        reconfirm: reconfirm,
      );

      // Anti-vacuity: the dialog must actually have rendered its copy.
      expect(rendered, contains(en.locationDisclosureTitle));
      expect(rendered, contains(en.locationDisclosureBackgroundIos));
      expect(
        rendered.contains(en.locationDisclosureUpdateLead),
        reconfirm,
        reason: 'the update lead renders in re-confirm mode only',
      );

      return [
        for (final text in rendered)
          ...findAllViolations(text, source: 'iOS dialog'),
      ];
    }

    // The Play prominent-disclosure dialog is shown on BOTH platforms and is
    // the record of the user's consent, so the rules at the top of this file
    // apply to it on iOS, in both of its modes.
    testWidgets('nothing an iOS user reads claims sharing resumes after Haven '
        'is closed without stating its condition', (tester) async {
      final offenders = await iosDialogViolations(tester, reconfirm: false);
      expect(offenders, isEmpty, reason: offenders.join('\n'));
    });

    testWidgets('nothing an iOS user reads in the re-shown dialog claims '
        'sharing resumes after Haven is closed without stating its '
        'condition', (tester) async {
      final offenders = await iosDialogViolations(tester, reconfirm: true);
      expect(offenders, isEmpty, reason: offenders.join('\n'));
    });

    testWidgets('the iOS copy states the condition and the While-Using limit '
        'affirmatively', (tester) async {
      // Absence of a false claim is not the same as disclosing the truth.
      final rendered = await renderedDisclosureText(
        tester,
        isIOS: true,
        includeBackground: true,
      );
      final joined = normalizeCopy(rendered.join(' '));
      for (final condition in _resumeCondition.entries) {
        expect(
          condition.value.hasMatch(joined),
          isTrue,
          reason: 'the iOS consent copy ${condition.key} no longer',
        );
      }
      expect(
        _whileUsingLimit.hasMatch(joined),
        isTrue,
        reason:
            'iOS copy must say that under While Using sharing stops '
            'until the user opens Haven',
      );
    });

    testWidgets('Android keeps all three Play disclosure elements', (
      tester,
    ) async {
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
      expect(ios, isNot(contains(en.locationDisclosureBackgroundAndroid)));
      expect(android, contains(en.locationDisclosureBackgroundAndroid));
      expect(android, isNot(contains(en.locationDisclosureBackgroundIos)));
    });

    test('the re-confirm lead never says Not now turns sharing off', () {
      // 'Not now' keeps background sharing exactly as it was; only the
      // start-again-by-itself is withheld. Saying otherwise would push the
      // user to agree out of a fear the app created.
      final turnsOff = RegExp(
        r'\b(turns? (background sharing |sharing |it )?off|stops|switch(es)? '
        r'off|is turned off|ends)\b',
      );
      expect(
        turnsOff.hasMatch(
          normalizeCopy("If you choose 'Not now', background sharing stops."),
        ),
        isTrue,
        reason: 'self-test: the matcher must see the claim it forbids',
      );
      final lead = normalizeCopy(en.locationDisclosureUpdateLead);
      expect(lead, contains('not now'), reason: 'anti-vacuity: names Not now');
      expect(turnsOff.hasMatch(lead), isFalse, reason: lead);
    });

    testWidgets('third-party policy is attributed, never asserted as '
        'Haven’s own fact', (tester) async {
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

  group('iOS settings copy', () {
    test('the iPhone intro names Haven being closed (anti-vacuity)', () {
      // A key that never names the closed state would pass every rule here
      // by saying nothing.
      expect(
        _sentences(en.locationSettingsIntroIos).where(_notRunning.hasMatch),
        isNotEmpty,
      );
    });

    test("the intro's iPhone sentences and the While-Using note break no "
        'rule', () {
      // The note renders only on iOS under While Using; an iPhone renders the
      // common intro followed by the iPhone sentences.
      final offenders = <BackgroundClaimViolation>[
        ...findAllViolations(
          '${en.locationSettingsIntro} ${en.locationSettingsIntroIos}',
          source: 'locationSettingsIntro + locationSettingsIntroIos',
        ),
        ...findUnqualifiedClosedAppClaims(
          en.locationSettingsIosLimitedNote,
          source: 'locationSettingsIosLimitedNote',
        ),
        ...findReceiveOnlyWording(
          en.locationSettingsIosLimitedNote,
          source: 'locationSettingsIosLimitedNote',
        ),
      ];
      expect(offenders, isEmpty, reason: offenders.join('\n'));
    });

    test('the While-Using note states the stop for its own reader', () {
      // Its reader is the While-Using cohort, so the limit is stated as their
      // own state rather than by naming the authorization.
      final note = _sentences(en.locationSettingsIosLimitedNote);
      expect(
        note.any((s) => _notRunning.hasMatch(s) && _statesTheStop.hasMatch(s)),
        isTrue,
        reason: en.locationSettingsIosLimitedNote,
      );
    });
  });

  // Both surfaces that state the iPhone resume claim, tied to each other.
  //
  // `locationDisclosureBackgroundIos` is the sentence the user consents to
  // before the permission prompt; `locationSettingsIntroIos` is what they
  // meet later above the toggle. The user who reads both must not be told two
  // different things about what happens after Haven is closed.
  group('the consent dialog and the settings intro state one claim', () {
    test('the resume-claim detector notices a half-stated claim', () {
      // Without this, the equality below would pass on two surfaces that had
      // BOTH lost the same condition.
      const halfStated =
          "With 'Always', if Haven is closed, sharing starts again by itself.";
      final profile = resumeClaimProfile(halfStated);
      expect(profile['says sharing starts again by itself'], isTrue);
      expect(profile['names the movement'], isFalse);
      expect(profile['says iOS decides'], isFalse);
      expect(profile['says While Using waits for an open'], isFalse);
    });

    test('the old receive-only consent sentence fails the resume claim', () {
      final profile = resumeClaimProfile(_oldIosConsentSentence);
      expect(
        profile.values,
        contains(isFalse),
        reason: 'a reverted consent sentence must not satisfy the tie',
      );
      expect(profile['says sharing starts again by itself'], isFalse);
    });

    test('the consent dialog and the settings intro each carry the whole '
        'resume claim', () {
      for (final surface in <String, String>{
        'locationDisclosureBackgroundIos': en.locationDisclosureBackgroundIos,
        'locationSettingsIntroIos': en.locationSettingsIntroIos,
      }.entries) {
        final profile = resumeClaimProfile(surface.value);
        expect(
          profile.values,
          everyElement(isTrue),
          reason:
              '${surface.key} no longer states the iPhone resume claim in '
              'full: $profile. Every condition is one iOS really imposes; '
              'dropping one promises a resumption the user may not get.',
        );
      }
    });

    test('the consent dialog and the settings intro state the SAME resume '
        'claim', () {
      final consent = resumeClaimProfile(en.locationDisclosureBackgroundIos);
      final settings = resumeClaimProfile(en.locationSettingsIntroIos);
      expect(
        consent,
        equals(settings),
        reason:
            'The consent artefact and the settings paragraph disagree about '
            'what happens after Haven is closed. Whichever one is now weaker, '
            'the user has been shown both.',
      );
    });
  });
}
