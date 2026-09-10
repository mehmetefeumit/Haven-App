// Copy accuracy for the two roster-bound refusals, in EVERY supported locale.
//
// The English wording is pinned by
// `test/pages/circles/name_circle_page_test.dart` and
// `test/widgets/circles/invitation_card_test.dart` — both of which pump the
// default `en` locale and say so in a comment pointing here. Until this file
// existed that pointer went nowhere: appending "please try again" to any of the
// twelve translations, the single failure every translator in this wave was
// briefed to avoid, would have failed nothing.
//
// It is the failure that matters most here, because the roster bound is
// TERMINAL. The service refuses before staging anything (see
// `test/services/nostr_circle_service_roster_bound_test.dart`), so the button
// the user would press again cannot succeed while they hold ten circles. A
// retry prompt is not merely unhelpful copy: it points at a dead control.
//
// So, per locale, on the string as `AppLocalizations` actually renders it:
//
//   1. the limit appears, in this locale's OWN digits. `intl` renders `ne` in
//      Devanagari and `fa` in Persian, and `ar`, `ur` and `hi` in ASCII —
//      their CLDR default numbering system is `latn`, and only `ar_EG` is
//      `arab`, so the script cannot be inferred from the language. Derived
//      here with the same `NumberFormat.decimalPattern` call gen-l10n emits,
//      never hand-written.
//   1b. the limit is INTERPOLATED, proved by rendering the same string at a
//      different limit. An ASCII-digit check alone is vacuous in eleven of the
//      thirteen locales — their digits ARE ASCII — so it cannot be the whole
//      of this check; the wrong-script form of the mistake is asserted on top,
//      where it exists.
//   2. the remedy appears, in the vocabulary this locale's own Leave control
//      uses. A refusal that names no way out is a dead end, and one that names
//      it with a different verb than the button sends the user hunting. Matched
//      by pattern, not substring: `es` and `pt` share only a three-letter stem
//      between the button and the remedy, and that stem also opens unrelated
//      verbs the app already ships ("Algo salió mal", "nunca sai do seu
//      celular").
//   3. the locale's retry vocabulary does NOT appear.
//
// Every forbidden term in (3) is proved non-vacuous against that locale's own
// retry surfaces — the transient siblings (`nameCircleCreateError` /
// `invitationAcceptError`) plus `commonTryAgain` and `commonRetry`, which is
// where the phrase legitimately lives. A per-locale forbidden term present in
// NO string of that locale asserts nothing while reporting that it does, and a
// term subsumed by another in the same list adds no coverage over it.
//
// Deliberately NOT covered, so nobody over-trusts this: whether a translation
// is idiomatic, and whether its limiter is heard as a ceiling rather than as
// permission. That judgement is the reviewer-agent half of the l10n workflow.
// Nor is the invitation string's "still waiting" reassurance covered: English
// and five other locales carry it only by implicature ("Leave a circle, then
// accept this invitation"), so no substring gate can tell a faithful
// translation from a dropped clause.
@TestOn('vm')
library;

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/l10n/app_localizations.dart';
import 'package:haven/src/services/publish_stagger.dart'
    show kMaxCirclesPerAccount;
import 'package:intl/intl.dart' as intl;

/// What one locale must and must not say at the roster bound.
class _RosterCopy {
  const _RosterCopy({required this.leavePattern, required this.retry});

  /// Case-insensitive pattern matching the vocabulary this locale's Leave
  /// control and its remedy clause share.
  ///
  /// A stem rather than the whole button label, because most of these
  /// languages inflect the verb between the two surfaces — "Kreis verlassen"
  /// against "Verlasse einen Kreis" — so containing the label itself would
  /// fail a perfectly correct translation. It is cross-checked against
  /// `circleDetailsLeaveCircle`, which keeps it from decaying into a
  /// free-floating word list: if the button stops using this vocabulary, or
  /// the refusal reaches for a different verb, the test says which.
  ///
  /// A PATTERN and not a bare substring because the two shortest stems are
  /// three letters that also open unrelated verbs: `es` shares only "sal"
  /// between "Salir del círculo" and "Sal de un círculo", and "sal" is also
  /// the head of "salió", "salida" and "sale" — so a refusal rewritten to the
  /// app's own "Algo salió mal" would read as naming the remedy under a
  /// `contains`. Nine of the thirteen are still just the literal stem.
  final String leavePattern;

  /// Phrases inviting another attempt, in this locale's own words.
  ///
  /// Taken from the locale's own retry surfaces, not from English, because a
  /// list that only knows the English words passes every translation
  /// unconditionally.
  final List<String> retry;
}

/// Per-locale roster-bound vocabulary.
///
/// Every `retry` term below is attested in that locale's own transient
/// siblings — a stem where the locale has one, so the realistic mutation
/// (lifting the sibling's clause across, in any of its inflections) is caught
/// without pinning one exact sentence. Terms that are merely PLAUSIBLE in the
/// language were deliberately removed: the anti-vacuity test rejected them,
/// and it was right to.
const _copy = <String, _RosterCopy>{
  'en': _RosterCopy(leavePattern: 'leave', retry: ['try again', 'retry']),
  'de': _RosterCopy(
    leavePattern: 'verlass',
    retry: ['erneut', 'versuch', 'wiederhol'],
  ),
  // "sal" is as long as the shared substring gets — the button is the
  // infinitive ("Salir"), the remedy the imperative ("Sal de un círculo") — so
  // the two continuations are spelled out instead. "salió"/"salida"/"sale" are
  // exactly what that excludes.
  'es': _RosterCopy(
    leavePattern: r'\bsal(ir|\s)',
    retry: ['inténtalo', 'de nuevo', 'reintent'],
  ),
  'fr': _RosterCopy(leavePattern: 'quitt', retry: ['réessay']),
  // "Sair do círculo" against "Saia de um círculo"; the bare "sai " of
  // "nunca sai do seu celular" is not the verb this refusal needs.
  'pt': _RosterCopy(
    leavePattern: r'\bsai[ra]\b',
    retry: ['tente', 'de novo'],
  ),
  // "повтор", not "повторите": the same stem carries `commonRetry`
  // ("Повторить") and the sibling's "повторите попытку".
  'ru': _RosterCopy(leavePattern: 'покин', retry: ['повтор', 'попытк']),
  'tr': _RosterCopy(leavePattern: 'ayrıl', retry: ['tekrar', 'dene']),
  'ar': _RosterCopy(leavePattern: 'مغادرة', retry: ['إعادة المحاولة']),
  'fa': _RosterCopy(leavePattern: 'ترک', retry: ['دوباره', 'تلاش']),
  'ur': _RosterCopy(leavePattern: 'چھوڑ', retry: ['دوبارہ', 'کوشش']),
  // The bare adverb ("फिर") is NOT forbidden: the invitation refusal uses it
  // for sequence — "leave a circle and THEN accept" — so only the retry verb
  // itself can be banned here.
  'hi': _RosterCopy(leavePattern: 'छोड़', retry: ['कोशिश']),
  'ne': _RosterCopy(leavePattern: 'छोड्', retry: ['प्रयास', 'फेरि']),
  'ja': _RosterCopy(
    leavePattern: '退出',
    retry: ['もう一度', 'お試し', '再試行'],
  ),
};

/// [_RosterCopy.leavePattern] for [code], compiled.
RegExp _leave(String code) =>
    RegExp(_copy[code]!.leavePattern, caseSensitive: false);

/// The two strings this guard covers, for one locale.
List<(String, String)> _rosterStrings(
  AppLocalizations l, [
  int limit = kMaxCirclesPerAccount,
]) => [
  ('nameCircleRosterFullError', l.nameCircleRosterFullError(limit)),
  ('invitationRosterFullError', l.invitationRosterFullError(limit)),
];

/// The transient siblings, where a retry prompt is CORRECT.
///
/// Both failures really are worth another tap, so these are the strings that
/// prove the forbidden vocabulary is this locale's real retry phrasing.
List<(String, String)> _transientSiblings(AppLocalizations l) => [
  ('nameCircleCreateError', l.nameCircleCreateError),
  ('invitationAcceptError', l.invitationAcceptError),
];

/// Every string that legitimately invites another attempt, for one locale.
///
/// The two transient siblings PLUS the app's own canonical retry controls. A
/// pool narrower than the app's real retry vocabulary is what let `commonRetry`
/// — "Retry", "Reintentar", "再試行", "Повторить", "Wiederholen" — stay
/// un-forbidden in five locales while this gate reported it had proved
/// otherwise: those labels are attested nowhere in the two siblings, so a term
/// covering them could not be added without failing the anti-vacuity test.
List<(String, String)> _retryAttestations(AppLocalizations l) => [
  ..._transientSiblings(l),
  ('commonTryAgain', l.commonTryAgain),
  ('commonRetry', l.commonRetry),
];

/// The forbidden [terms] that [value] contains.
List<String> violations(String value, List<String> terms) {
  final haystack = value.toLowerCase();
  return [for (final t in terms) if (haystack.contains(t.toLowerCase())) t];
}

/// [limit] as gen-l10n renders it for [locale].
///
/// The same call the generated `nameCircleRosterFullError` makes, so the
/// expectation tracks `intl`'s CLDR data rather than a digit table copied into
/// this file and left to rot.
String limitFor(Locale locale, [int limit = kMaxCirclesPerAccount]) =>
    intl.NumberFormat.decimalPattern(
      intl.Intl.canonicalizedLocale(locale.toString()),
    ).format(limit);

void main() {
  test('every supported locale has roster-bound vocabulary', () {
    // A locale added without an entry would be scanned against nothing and
    // pass silently — worse than not scanning it, because the gate would then
    // report coverage it does not have.
    expect(
      AppLocalizations.supportedLocales.map((l) => l.languageCode).toSet(),
      _copy.keys.toSet(),
    );
    // Presence is not usefulness. An empty pattern matches every string and an
    // empty term list forbids nothing, so either one buys a locale seven green
    // tests of which the two that matter assert nothing at all.
    for (final MapEntry(key: code, value: copy) in _copy.entries) {
      expect(
        copy.leavePattern,
        isNotEmpty,
        reason: '$code: an empty pattern matches every string, so the remedy '
            'check would pass on a refusal that names no way out',
      );
      expect(
        copy.retry,
        isNotEmpty,
        reason: '$code: an empty list forbids nothing',
      );
      for (final term in copy.retry) {
        expect(
          copy.retry.where(
            (other) =>
                other != term &&
                other.toLowerCase().contains(term.toLowerCase()),
          ),
          isEmpty,
          reason: '$code: "$term" is a substring of another forbidden term, so '
              "the attestation that proves it is this locale's own is the one "
              'that already proved the longer one — it adds no coverage',
        );
      }
    }
  });

  for (final locale in AppLocalizations.supportedLocales) {
    final code = locale.languageCode;
    group('$code roster-bound copy', () {
      late AppLocalizations l;
      late _RosterCopy copy;

      setUp(() async {
        l = await AppLocalizations.delegate.load(locale);
        copy = _copy[code]!;
      });

      test("states the limit in this locale's digits", () {
        final limit = limitFor(locale);
        for (final (key, value) in _rosterStrings(l)) {
          expect(
            value,
            contains(limit),
            reason:
                '$code/$key: the user cannot act on a limit they are not '
                'told — "$value"',
          );
        }
      });

      test('renders the limit from the placeholder, never a frozen digit', () {
        // A translator who types the number into the sentence freezes
        // kMaxCirclesPerAccount at today's value: the copy keeps saying ten
        // after the constant moves, and every other test here still passes
        // because they all render at the bound. Rendering at a DIFFERENT limit
        // is what proves the placeholder is still doing the work — and unlike
        // an ASCII-digit check it is non-vacuous in all thirteen locales, not
        // just the two whose digits are not ASCII.
        const other = 7;
        final otherRendered = limitFor(locale, other);
        final atBound = limitFor(locale);
        for (final (key, value) in _rosterStrings(l, other)) {
          expect(
            value,
            contains(otherRendered),
            reason:
                '$code/$key must render the limit it is given; '
                '"$otherRendered" is missing — "$value"',
          );
          expect(
            value,
            isNot(contains(atBound)),
            reason:
                '$code/$key rendered at $other still contains "$atBound", so '
                'the bound is typed into the sentence rather than interpolated '
                '— "$value"',
          );
          // The wrong-script form of the same mistake, which only exists where
          // the locale's digits are not ASCII.
          if (otherRendered != '$other') {
            expect(
              value,
              isNot(contains('$other')),
              reason:
                  '$code/$key renders digits as "$otherRendered"; an ASCII '
                  '"$other" here is hand-localized — "$value"',
            );
          }
        }
      });

      test("names the remedy with this locale's own Leave vocabulary", () {
        // Half of what makes the refusal actionable. Asserted against the
        // locale's own control rather than a transliteration, so the refusal
        // and the button the user must then find are proved to agree.
        final leave = _leave(code);
        expect(
          l.circleDetailsLeaveCircle,
          matches(leave),
          reason:
              '$code: "${copy.leavePattern}" is no longer the Leave control\'s '
              'vocabulary ("${l.circleDetailsLeaveCircle}"), so this guard is '
              'checking the refusal against a word the app no longer uses',
        );
        for (final (key, value) in _rosterStrings(l)) {
          expect(
            value,
            matches(leave),
            reason:
                '$code/$key: without the remedy the refusal is a dead end, '
                'and it must name it the way the Leave control does '
                '("${l.circleDetailsLeaveCircle}") — "$value"',
          );
        }
      });

      test('does not invite a retry it can never honour', () {
        for (final (key, value) in _rosterStrings(l)) {
          expect(
            violations(value, copy.retry),
            isEmpty,
            reason:
                '$code/$key: the roster bound is terminal — the control the '
                'user would press again cannot succeed while they hold '
                '$kMaxCirclesPerAccount circles — "$value"',
          );
        }
      });

      test("the forbidden retry vocabulary is this locale's own", () {
        // Anti-vacuity, per locale. A term that appears in no string of this
        // language forbids nothing, and would keep passing after the real
        // phrasing drifted away from it.
        final attested = _retryAttestations(l);
        for (final term in copy.retry) {
          expect(
            attested.where((s) => violations(s.$2, [term]).isNotEmpty),
            isNotEmpty,
            reason:
                '$code: "$term" appears in none of this locale\'s retry '
                'surfaces (${attested.map((s) => '"${s.$2}"').join(', ')}), so '
                'forbidding it in the roster copy proves nothing',
          );
        }
      });

      test('the transient siblings still DO invite a retry', () {
        // The contrast this whole file rests on: these two failures are worth
        // another tap, the roster bound is not. If a sibling stopped saying so
        // the copy would be wrong in the other direction, and the anti-vacuity
        // test above would go quiet about the reason.
        for (final (key, value) in _transientSiblings(l)) {
          expect(
            violations(value, copy.retry),
            isNotEmpty,
            reason:
                '$code/$key is a transient failure and must offer another '
                'attempt — "$value"',
          );
        }
      });

      test('is non-empty and free of the untranslated placeholder', () {
        for (final (key, value) in _rosterStrings(l)) {
          expect(value.trim(), isNotEmpty, reason: '$code/$key');
          // A literal `{limit}` cannot reach here — gen-l10n interpolates the
          // declared placeholder and `l10n-check.yml` fails an undeclared one —
          // so only the translator's own leftovers are worth sweeping for.
          expect(
            value,
            isNot(matches(RegExp('todo|fixme|xxx', caseSensitive: false))),
            reason: '$code/$key',
          );
        }
      });
    });
  }

  test('the scanner actually catches a violation', () {
    // Without this, an empty term list or a broken `contains` would let every
    // locale pass and the gate would prove nothing.
    expect(
      violations(
        'You can be in up to 10 circles. Please try again.',
        _copy['en']!.retry,
      ),
      contains('try again'),
    );
    expect(
      violations('Leave a circle to make room.', _copy['en']!.retry),
      isEmpty,
    );
    // Case folding is load-bearing: German's retry adverb is sentence-initial
    // in some phrasings and mid-sentence in others.
    expect(
      violations('Bitte Erneut versuchen.', _copy['de']!.retry),
      containsAll(['erneut', 'versuch']),
    );
  });

  test('the Leave matcher rejects an unrelated verb sharing the stem', () {
    // Why `leavePattern` is a pattern. Every string below already ships in the
    // app: "Algo salió mal" is `createCircleSomethingWentWrong`, "la salida
    // del registro" is in `settingsDebugOverlaySubtitle`, and "nunca sai do
    // seu celular" is `onboardingValueProp3Summary`. Under a `contains('sal')`
    // a refusal rewritten to any of them read as naming the remedy.
    final es = _leave('es');
    expect(es.hasMatch('Salir del círculo'), isTrue);
    expect(
      es.hasMatch('Sal de un círculo para poder crear uno nuevo.'),
      isTrue,
    );
    expect(es.hasMatch('Algo salió mal'), isFalse);
    expect(es.hasMatch('la salida del registro'), isFalse);
    expect(es.hasMatch('nunca sale de tu teléfono'), isFalse);
    final pt = _leave('pt');
    expect(pt.hasMatch('Sair do círculo'), isTrue);
    expect(pt.hasMatch('Saia de um círculo e depois aceite este convite.'),
        isTrue);
    expect(pt.hasMatch('nunca sai do seu celular'), isFalse);
  });

  test('the digit expectation comes from CLDR, not from this file', () {
    // Pins the two facts the header claims, so a wrong-script assumption
    // ("Devanagari because the language is written in it") fails here rather
    // than being written into a translation.
    expect(limitFor(const Locale('ne')), '१०');
    expect(limitFor(const Locale('fa')), '۱۰');
    expect(limitFor(const Locale('hi')), '10');
    expect(limitFor(const Locale('ar')), '10');
    expect(limitFor(const Locale('ur')), '10');
  });
}
