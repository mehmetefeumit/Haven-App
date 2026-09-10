// Copy accuracy for the iOS location-settings card, in EVERY supported locale.
//
// The English half of this tie — the base sentence against the Swift policy
// that decides what the user can see — lives in
// `test/lints/ios_indicator_copy_accuracy_test.dart`. This file exists because
// that guard would pass while twelve locales still promised a blue bar to a
// user who has none: the card was ONE sentence per locale, and splitting the
// English into two does not touch the other twelve values. A translator who
// skips this key leaves the OLD sentence in place, and the old sentence is
// exactly the false one.
//
// So each locale's forbidden list carries its OWN words from the OLD sentence
// (de "durchgehende"/"blaue Anzeige", ar "متواصلة"/"مؤشرًا أزرق", …). An
// untouched translation under a re-worded English key is then a red test, not a
// silent shipment.
//
// The vocabulary rules, per locale:
//
//   (a) the BASE names no indicator — not this locale's "blue", not its "blue
//       location bar" phrase, not its "indicator" or "arrow" term — because it
//       renders under BOTH indicator states, and not the old sentence's words;
//   (b) the ARROW sentence names this locale's arrow term AND its status-bar
//       term, and neither its "blue" word nor its bar stem; the BAR sentence
//       and the While-In-Use note name BOTH the bar stem and the colour;
//   (c) the While-In-Use NOTE names this locale's "Always" term and says the
//       app is closed — the localized pin on the receive-only limit that
//       INV-L-IOS-WAKES-RECEIVE-ONLY asserts.
//
// Two traps this guard was nearly built with, pulling in opposite directions.
//
// Forbidding the bare word for "bar" would break it: the arrow sentence HAS to
// say "status bar" (de "Statusleiste", ar "شريط الحالة"), so the pinned token
// can never be the noun on its own.
//
// Pinning the full inflected phrase instead breaks it the other way, and
// silently: the phrase then fails OPEN in BOTH directions at once. Reword the
// Russian bar sentence from the accusative "синюю полосу геопозиции" into the
// nominative "синяя полоса геопозиции" and it stops satisfying "the bar
// sentence names the bar" at the same moment it still satisfies "the arrow
// sentence names no bar" — a real regression that reddens nothing. So what is
// pinned is the shortest stem that survives this locale's inflection while
// staying clear of its status-bar term.
//
// The arrow sentence also names an iOS Settings screen, and the rule for that
// name is: quote it in the locale's own language ONLY where Apple ships iOS in
// that language AND the exact shipped string has been verified against Apple's
// own localized documentation; otherwise keep "Location Services" in English,
// which is what several of these ARB files already do with Android menu names.
// A localized name Apple does not ship points the user at nothing. Verified
// against support.apple.com/102647 and /102515 in each locale: de
// "Ortungsdienste", fr "Service de localisation" (singular), es "Localización"
// (identical in es-ES and es-419), pt "Serviços de Localização", ru "Службы
// геолокации", tr "Konum Servisleri", ja "位置情報サービス", ar "خدمات الموقع",
// hi "स्थान सेवा" (singular). Urdu is verified from a different pair, because
// those two articles stay in English on ur-IN: Apple's Urdu iPhone AND iPad
// User Guides, separately translated, both print the same menu name in the
// same path — "سیٹنگ > رازداری اور تحفظ > لوکیشن کی خدمات"
// (support.apple.com/ur-in/guide/iphone/iph3dd5f9be/ios and
// support.apple.com/ur-in/guide/ipad/ipadb7c27772/ipados), so ur quotes
// "لوکیشن کی خدمات". fa and ne keep English because Apple ships no Persian or
// Nepali iOS UI at all, while Urdu IS a shipped System Language
// (apple.com/ios/feature-availability, "System Language" list). The iPhone
// tech-specs "Language support" list is NOT the criterion: it omits Urdu
// alongside Bangla, Punjabi, Tamil and most other Indic system languages, so
// it is a stale subset of what iOS actually ships.
//
// The Settings-hub Location subtitle is scanned here too, under the OPPOSITE
// rule: the card names exactly one indicator, and those two lines must name
// none — nor a platform — because one hub line cannot qualify either, while
// still reusing the toggle's own word for background sharing.
//
// Deliberately NOT covered, so nobody over-trusts this: whether a translation
// is idiomatic, and whether it says the RIGHT thing rather than merely avoiding
// the wrong words. That is the reviewer-agent half of the l10n workflow.
@TestOn('vm')
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:haven/l10n/app_localizations.dart';

/// One locale's vocabulary for the four things this card can name.
class _Vocabulary {
  const _Vocabulary({
    required this.blue,
    required this.barPhrase,
    required this.arrow,
    required this.statusBar,
    required this.indicator,
    required this.always,
    required this.closesTheApp,
    required this.oldSentence,
    required this.backgroundTerm,
  });

  /// This locale's word for the colour. Forbidden in the base and the arrow.
  final List<String> blue;

  /// The blue location bar, as the shortest stem that survives this locale's
  /// inflection — never the full inflected phrase, and never the bare noun for
  /// "bar", which the arrow sentence needs for "status bar".
  ///
  /// Several locales carry two stems because the adjective can move. The list
  /// is an OR for the required direction and a NONE-OF for the forbidden one,
  /// so an extra stem only ever tightens the guard.
  final List<String> barPhrase;

  /// This locale's word for the OS status-bar arrow.
  final List<String> arrow;

  /// This locale's term for the status bar itself. Required in the arrow key.
  final List<String> statusBar;

  /// This locale's word for a UI indicator. Forbidden in the base.
  final List<String> indicator;

  /// This locale's rendering of the "Always" authorization.
  final List<String> always;

  /// This locale's phrase for iOS closing the app.
  final List<String> closesTheApp;

  /// The distinctive words of the OLD, now-false single-sentence card.
  ///
  /// Both halves of the claim it made: the session was called continuous, and
  /// the indicator was called blue. An untranslated key still contains them.
  final List<String> oldSentence;

  /// This locale's term for sharing in the BACKGROUND, as the toggle title
  /// already spells it. The hub subtitle has to reuse it: two surfaces naming
  /// one setting differently is how a user ends up believing there are two.
  final String backgroundTerm;
}

/// Per-locale vocabulary, written against each locale's own words rather than
/// transliterated English — a guard that only knew the English words would pass
/// every translation unconditionally.
const _vocabulary = <String, _Vocabulary>{
  'en': _Vocabulary(
    blue: ['blue'],
    barPhrase: ['location bar'],
    arrow: ['arrow'],
    statusBar: ['status bar'],
    indicator: ['indicator'],
    always: ['always'],
    closesTheApp: ['closes the app'],
    oldSentence: ['continuous location session', 'blue status-bar indicator'],
    backgroundTerm: 'background',
  ),
  'de': _Vocabulary(
    blue: ['blau'],
    // The adjective is the half that declines (blaue/blauen/blauer).
    barPhrase: ['standortleiste'],
    arrow: ['pfeil'],
    statusBar: ['statusleiste'],
    indicator: ['anzeige'],
    always: ['immer'],
    closesTheApp: ['die app beendet'],
    oldSentence: ['durchgehende', 'blaue anzeige'],
    backgroundTerm: 'Hintergrund',
  ),
  'es': _Vocabulary(
    blue: ['azul'],
    // Two stems: the adjective can sit either side of the complement
    // ("barra azul de ubicación" / "barra de ubicación azul").
    barPhrase: ['barra azul', 'barra de ubicación'],
    arrow: ['flecha'],
    statusBar: ['barra de estado'],
    indicator: ['indicador'],
    always: ['siempre'],
    closesTheApp: ['cierre la app'],
    oldSentence: ['ubicación continua', 'indicador azul'],
    backgroundTerm: 'segundo plano',
  ),
  'fr': _Vocabulary(
    blue: ['bleu'],
    barPhrase: ['barre bleue', 'barre de localisation'],
    arrow: ['flèche'],
    statusBar: ["barre d'état"],
    indicator: ['indicateur'],
    always: ['toujours'],
    closesTheApp: ["fermé l'application"],
    oldSentence: ['localisation continue', 'indicateur bleu'],
    backgroundTerm: 'arrière-plan',
  ),
  'pt': _Vocabulary(
    blue: ['azul'],
    barPhrase: ['barra azul', 'barra de localização'],
    arrow: ['seta'],
    statusBar: ['barra de status'],
    indicator: ['indicador'],
    always: ['sempre'],
    closesTheApp: ['fechar o app'],
    oldSentence: ['localização contínua', 'indicador azul'],
    backgroundTerm: 'segundo plano',
  ),
  'ru': _Vocabulary(
    blue: ['син'],
    // Every word of "синюю полосу геопозиции" declines, so the only
    // case-invariant fragment is the noun stem. It is clear of the
    // status-bar term, which is "строка состояния" and carries no полос-.
    barPhrase: ['полос'],
    arrow: ['стрелк'],
    statusBar: ['строке состояния'],
    indicator: ['индикатор'],
    always: ['всегда'],
    closesTheApp: ['закроет приложение'],
    oldSentence: ['непрерывн', 'синий индикатор'],
    backgroundTerm: 'фон',
  ),
  'tr': _Vocabulary(
    blue: ['mavi'],
    // Cut before the k/ğ alternation so every form lands (çubuk, çubuğu,
    // çubuğunu, çubukları). The naive stem "çubu" is the collision this
    // locale is famous for — "durum çubuğunda" contains it — but the
    // qualified "konum çubu" does not.
    barPhrase: ['konum çubu'],
    // "konum ok" and not the bare "ok": Turkish spells the arrow with a
    // suffix ("okunu", "ok simgesi") and the two letters alone appear inside
    // a dozen unrelated words.
    arrow: ['konum ok'],
    statusBar: ['durum çubuğu'],
    indicator: ['gösterge'],
    always: ['her zaman'],
    closesTheApp: ['uygulamayı kapattıktan sonra'],
    oldSentence: ['kesintisiz', 'mavi bir gösterge'],
    backgroundTerm: 'arka plan',
  ),
  'ar': _Vocabulary(
    blue: ['زرق'],
    barPhrase: ['شريط الموقع'],
    arrow: ['سهم'],
    statusBar: ['شريط الحالة'],
    indicator: ['مؤشر'],
    always: ['دائم'],
    closesTheApp: ['يُغلق iOS التطبيق'],
    oldSentence: ['متواصلة', 'مؤشرًا أزرق'],
    backgroundTerm: 'الخلفية',
  ),
  'fa': _Vocabulary(
    blue: ['آبی'],
    barPhrase: ['نوار آبی', 'نوار موقعیت'],
    arrow: ['پیکان'],
    statusBar: ['نوار وضعیت'],
    indicator: ['نشانگر'],
    always: ['همیشه'],
    closesTheApp: ['برنامه را بست'],
    oldSentence: ['پیوسته', 'نشانگر آبی'],
    backgroundTerm: 'پس‌زمینه',
  ),
  'hi': _Vocabulary(
    blue: ['नील'],
    barPhrase: ['स्थान पट्टी'],
    arrow: ['तीर'],
    statusBar: ['स्टेटस बार'],
    indicator: ['संकेतक'],
    always: ['हमेशा'],
    closesTheApp: ['ऐप बंद कर देने के बाद'],
    oldSentence: ['लगातार', 'नीला संकेतक'],
    backgroundTerm: 'बैकग्राउंड',
  ),
  'ja': _Vocabulary(
    blue: ['青'],
    // The bare "バー" would collide with "ステータスバー".
    barPhrase: ['位置情報バー'],
    arrow: ['矢印'],
    statusBar: ['ステータスバー'],
    // 表示 alone is the everyday verb "to show", so the forbidden token is the
    // old sentence's noun use of it.
    indicator: ['表示が出'],
    always: ['常に'],
    closesTheApp: ['アプリを終了した後'],
    oldSentence: ['継続', '青い表示'],
    backgroundTerm: 'バックグラウンド',
  ),
  'ne': _Vocabulary(
    blue: ['निलो'],
    barPhrase: ['स्थान पट्टी'],
    arrow: ['तीर'],
    statusBar: ['स्थिति-पट्टी'],
    indicator: ['सूचक'],
    always: ['सधैँ'],
    closesTheApp: ['एप बन्द गरेपछि'],
    oldSentence: ['निरन्तर', 'निलो स्थिति-पट्टी'],
    backgroundTerm: 'पृष्ठभूमि',
  ),
  'ur': _Vocabulary(
    blue: ['نیل'],
    barPhrase: ['مقام پٹی'],
    arrow: ['تیر'],
    statusBar: ['اسٹیٹس بار'],
    indicator: ['اشارہ'],
    // English, because app_ur.arb spells this authorization "Always" in the
    // string the list is asserted against. Unlike the Location Services menu
    // name, Apple's Urdu guides never print a quoted Urdu label for the
    // option — ہمیشہ appears there only as ordinary prose — so there is no
    // shipped Urdu string to quote.
    always: ['always'],
    closesTheApp: ['ایپ بند کر دینے کے بعد'],
    oldSentence: ['مسلسل', 'نیلا اشارہ'],
    backgroundTerm: 'پس منظر',
  ),
};

/// Every string this guard covers, for one locale.
List<(String, String)> _cardStrings(AppLocalizations l) => [
  ('locationSettingsIosGuidance', l.locationSettingsIosGuidance),
  ('locationSettingsIosIndicatorArrow', l.locationSettingsIosIndicatorArrow),
  ('locationSettingsIosIndicatorBar', l.locationSettingsIosIndicatorBar),
  ('locationSettingsIosLimitedNote', l.locationSettingsIosLimitedNote),
];

/// The Settings-hub Location subtitle, in both states, for one locale.
///
/// Scanned apart from [_cardStrings]: the card's rules are about naming ONE
/// indicator correctly, and these two lines must name NO indicator at all.
List<(String, String)> _subtitleStrings(AppLocalizations l) => [
  ('settingsLocationSubtitleOn', l.settingsLocationSubtitleOn),
  ('settingsLocationSubtitleOff', l.settingsLocationSubtitleOff),
];

/// Platform names, which every locale keeps in Latin script.
///
/// Forbidden in the hub subtitle: it reports the SETTING, which is the same on
/// both platforms, and the behaviours that differ are stated on the page
/// behind it where there is room to qualify them.
const _platformWords = ['ios', 'iphone', 'android'];

/// The forbidden terms [value] contains, given the [terms] that apply to it.
List<String> violations(String value, List<String> terms) {
  final haystack = value.toLowerCase();
  return [for (final t in terms) if (haystack.contains(t.toLowerCase())) t];
}

void main() {
  test('every supported locale has a vocabulary entry', () {
    // A locale added without one would be scanned against nothing and pass
    // silently, which is worse than not scanning it: the gate would report
    // coverage it does not have.
    expect(
      AppLocalizations.supportedLocales.map((l) => l.languageCode).toSet(),
      _vocabulary.keys.toSet(),
    );
  });

  test('every vocabulary entry carries the OLD sentence words', () {
    // The clause that catches the realistic regression — an untouched
    // translation under a re-worded English key. An empty list here would make
    // clause (a) blind to exactly that.
    for (final entry in _vocabulary.entries) {
      expect(
        entry.value.oldSentence,
        isNotEmpty,
        reason: '${entry.key} could not detect an untranslated card',
      );
    }
  });

  for (final locale in AppLocalizations.supportedLocales) {
    final code = locale.languageCode;
    group('$code iOS settings copy', () {
      late AppLocalizations l;
      late _Vocabulary vocabulary;

      setUp(() async {
        l = await AppLocalizations.delegate.load(locale);
        vocabulary = _vocabulary[code]!;
      });

      test('the base sentence names no indicator, and is not the old one', () {
        final base = l.locationSettingsIosGuidance;
        expect(
          violations(base, [
            ...vocabulary.blue,
            ...vocabulary.barPhrase,
            ...vocabulary.indicator,
            ...vocabulary.arrow,
            ...vocabulary.oldSentence,
          ]),
          isEmpty,
          reason: '$code: this sentence renders under BOTH indicator states, '
              'so naming one is false for the other — "$base"',
        );
      });

      test('the arrow sentence names the arrow and the status bar, never the '
          'blue bar', () {
        final arrow = l.locationSettingsIosIndicatorArrow;
        expect(
          violations(arrow, vocabulary.arrow),
          isNotEmpty,
          reason: '$code: the sentence exists to name the one signal this user '
              'still has — "$arrow"',
        );
        expect(
          violations(arrow, vocabulary.statusBar),
          isNotEmpty,
          reason: '$code: the arrow is only findable if the copy says where it '
              'is — "$arrow"',
        );
        expect(
          violations(arrow, [...vocabulary.blue, ...vocabulary.barPhrase]),
          isEmpty,
          reason: '$code: this sentence is selected exactly when no activity '
              'session is held, i.e. when there is no blue bar — "$arrow"',
        );
      });

      test('the bar sentence and the While-In-Use note name the blue location '
          'bar', () {
        for (final key in const [
          'locationSettingsIosIndicatorBar',
          'locationSettingsIosLimitedNote',
        ]) {
          final value = _cardStrings(l).firstWhere((e) => e.$1 == key).$2;
          expect(
            violations(value, vocabulary.barPhrase),
            isNotEmpty,
            reason: '$code/$key must name what the user sees, in the same ONE '
                'noun phrase everywhere — "$value"',
          );
          // The pinned stem deliberately drops the adjective so that it
          // survives inflection, which leaves "blue" unasserted — and a bar
          // the copy never calls blue is not the bar the user is looking for.
          expect(
            violations(value, vocabulary.blue),
            isNotEmpty,
            reason: '$code/$key must say the bar is BLUE: that colour is the '
                'whole of how the user recognises it — "$value"',
          );
        }
      });

      test('the While-In-Use note keeps the termination claim', () {
        // The localized pin on `INV-L-IOS-WAKES-RECEIVE-ONLY`: this note is
        // the one string in every locale that tells the cohort the advice is
        // for what "Always" buys them, and that it is bounded by iOS closing
        // the app. Nothing else asserts that claim in the twelve translations.
        const key = 'locationSettingsIosLimitedNote';
        final value = _cardStrings(l).firstWhere((e) => e.$1 == key).$2;
        expect(
          violations(value, vocabulary.always),
          isNotEmpty,
          reason: '$code/$key must name the "Always" authorization it is '
              'about — "$value"',
        );
        expect(
          violations(value, vocabulary.closesTheApp),
          isNotEmpty,
          reason: '$code/$key must keep saying that this is what happens '
              'AFTER iOS closes Haven — "$value"',
        );
      });

      test('no sentence uses a separator screen readers skip', () {
        // VoiceOver and TalkBack speak "→" and pass over "›", so a path
        // written with "›" is silently unnavigable.
        for (final (key, value) in _cardStrings(l)) {
          expect(value, isNot(contains('›')), reason: '$code/$key: "$value"');
        }
      });

      test('is non-empty and free of the untranslated placeholder', () {
        for (final (key, value) in _cardStrings(l)) {
          expect(value.trim(), isNotEmpty, reason: '$code/$key');
          expect(value, isNot(contains('TODO')), reason: '$code/$key');
        }
      });
    });

    group('$code Settings-hub Location subtitle', () {
      late AppLocalizations l;
      late _Vocabulary vocabulary;

      setUp(() async {
        l = await AppLocalizations.delegate.load(locale);
        vocabulary = _vocabulary[code]!;
      });

      test('the ON line uses the same background term as the toggle', () {
        // The tie, in both directions: the term has to be the toggle's own, so
        // the hub and the page cannot end up naming one setting two ways.
        final term = [vocabulary.backgroundTerm];
        expect(
          violations(l.locationSettingsToggleTitle, term),
          isNotEmpty,
          reason: '$code: the vocabulary entry no longer matches the toggle it '
              'was taken from — "${l.locationSettingsToggleTitle}"',
        );
        expect(
          violations(l.settingsLocationSubtitleOn, term),
          isNotEmpty,
          reason: '$code: the hub line must name the same thing the toggle '
              'does — "${l.settingsLocationSubtitleOn}"',
        );
      });

      test('the OFF line names the app whose lifetime it scopes', () {
        // "Only while <app> is open" is meaningless without the app: the whole
        // content of the line is WHOSE being open the sharing depends on.
        expect(
          l.settingsLocationSubtitleOff,
          contains('Haven'),
          reason: '$code: "${l.settingsLocationSubtitleOff}"',
        );
      });

      test('neither line names a platform or an OS indicator', () {
        // A hub line has no room to qualify either, and both differ by
        // platform AND by authorization tier — the exact half-truth the iOS
        // card above had to be split into three sentences to avoid.
        for (final (key, value) in _subtitleStrings(l)) {
          expect(
            violations(value, [
              ..._platformWords,
              ...vocabulary.blue,
              ...vocabulary.barPhrase,
              ...vocabulary.arrow,
              ...vocabulary.indicator,
            ]),
            isEmpty,
            reason: '$code/$key: "$value"',
          );
        }
      });

      test('the two states do not read the same', () {
        // A subtitle that says one thing in both states reports nothing, and
        // this row exists only to report.
        expect(
          l.settingsLocationSubtitleOn.trim(),
          isNot(l.settingsLocationSubtitleOff.trim()),
          reason: code,
        );
      });

      test('is non-empty and free of the untranslated placeholder', () {
        for (final (key, value) in _subtitleStrings(l)) {
          expect(value.trim(), isNotEmpty, reason: '$code/$key');
          expect(value, isNot(contains('TODO')), reason: '$code/$key');
          expect(value, isNot(contains('›')), reason: '$code/$key');
        }
      });
    });
  }

  group('scanner self-tests', () {
    test('the status-bar term is clean while the bar phrase is flagged', () {
      // Both directions of the trap this guard was nearly built with.
      expect(
        violations(
          'iOS zeigt seinen Pfeil in der Statusleiste.',
          _vocabulary['de']!.barPhrase,
        ),
        isEmpty,
      );
      expect(
        violations(
          'iOS zeigt seine blaue Standortleiste.',
          _vocabulary['de']!.barPhrase,
        ),
        contains('standortleiste'),
      );
    });

    test('a re-inflected bar phrase is still caught in both directions', () {
      // The regression the full-phrase pin could not see. Both Russian cases
      // of the SAME sentence must flag, or the guard fails open twice over:
      // silently in the bar sentence, which stops naming the bar, and
      // silently in the arrow sentence, which could then name it freely.
      for (final wording in const [
        'iOS показывает вверху экрана синюю полосу геопозиции.',
        'Вверху экрана появляется синяя полоса геопозиции.',
      ]) {
        expect(
          violations(wording, _vocabulary['ru']!.barPhrase),
          isNotEmpty,
          reason: wording,
        );
      }
      // …while the Russian status bar, which the arrow sentence must name,
      // stays clean.
      expect(
        violations(
          'iOS показывает стрелку в строке состояния.',
          _vocabulary['ru']!.barPhrase,
        ),
        isEmpty,
      );
    });

    test('a suffixed bar phrase is caught without a status-bar collision', () {
      // Turkish is the locale where the obvious stem is the wrong one: the
      // bare "çubu" sits inside "durum çubuğunda" too.
      for (final wording in const [
        'iOS mavi konum çubuğunu gösterir.',
        'Ekranda mavi bir konum çubuğu belirir.',
      ]) {
        expect(
          violations(wording, _vocabulary['tr']!.barPhrase),
          isNotEmpty,
          reason: wording,
        );
      }
      expect(
        violations(
          'iOS durum çubuğunda küçük bir konum ok simgesi gösterir.',
          _vocabulary['tr']!.barPhrase,
        ),
        isEmpty,
      );
    });

    test('an untouched translation of the old card is caught', () {
      // The exact German and Arabic values that shipped before the split.
      expect(
        violations(
          'Solange das Teilen im Hintergrund aktiviert ist, hält Haven eine '
          'durchgehende Standortsitzung aufrecht, und iOS zeigt in der '
          'Statusleiste eine blaue Anzeige.',
          _vocabulary['de']!.oldSentence,
        ),
        unorderedEquals(<String>['durchgehende', 'blaue anzeige']),
      );
      expect(
        violations(
          'ما دامت المشاركة في الخلفية مفعّلة، يحتفظ Haven بجلسة موقع متواصلة '
          'ويُظهر iOS مؤشرًا أزرق في شريط الحالة.',
          _vocabulary['ar']!.oldSentence,
        ),
        unorderedEquals(<String>['متواصلة', 'مؤشرًا أزرق']),
      );
    });
  });
}
