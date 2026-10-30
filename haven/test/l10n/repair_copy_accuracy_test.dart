// Copy accuracy for the epoch-repair strings, in EVERY supported locale.
//
// The app ships thirteen locales, the translations are written by people who
// cannot read the Rust, and earlier rounds found the same false claim in all
// twelve non-English locales at once. So the guard is per-locale and phrased
// as forbidden (or required) vocabulary, because that is the half a reviewer
// cannot reliably re-derive months later:
//
//   1. NOTHING may claim forward secrecy or that earlier messages are now
//      protected. The repair IS a self-update with an `UpdatePath` (so "new
//      encryption keys" is true), but it promises nothing about what was sent
//      before. See `haven-core/src/circle/rotation.rs`.
//   2. The Repair hint may not name the circle's creator, nor any role: any
//      member can run the repair.
//   3. The success string may not say sharing is working again. The repair is
//      published here; every other member applies it when they next RECEIVE
//      it, which can be minutes away and longer if a phone is asleep.
//   4. The halted circle's body may not invite a retry: no retry helps it.
//   5. The Repair hint keeps its modal "may": several checks decline the key
//      step silently, so a flat promise would be wrong most of the time.
//
// Deliberately NOT covered, so nobody over-trusts this: whether a translation
// is idiomatic, and whether it says the RIGHT thing rather than merely avoiding
// the wrong words. That is the reviewer-agent half of the l10n workflow.
@TestOn('vm')
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:haven/l10n/app_localizations.dart';

/// The forbidden vocabulary for one locale.
class _Forbidden {
  const _Forbidden({
    required this.secrecy,
    required this.creator,
    required this.restored,
    required this.retry,
    required this.modal,
  });

  /// Words claiming forward secrecy. Forbidden in every string.
  final List<String> secrecy;

  /// Words naming the circle's creator. Forbidden in the Repair hint.
  final List<String> creator;

  /// Words claiming sharing is working again. Forbidden in the success string.
  final List<String> restored;

  /// Words inviting another attempt. Forbidden in the terminal string.
  final List<String> retry;

  /// Modal markers for "may". At least one must appear in the Repair hint.
  ///
  /// Stated positively: a forbidden list of flat phrasings only matches when
  /// the verb and its object are CONTIGUOUS, so requiring the hedge cannot be
  /// dodged by word order, and it goes stale loudly — as a failure.
  final List<String> modal;
}

/// Per-locale forbidden lists.
///
/// Written against each locale's own vocabulary rather than transliterated
/// English, because a guard that only knows the English words would pass every
/// translation unconditionally — which is exactly how the creator/admin error
/// survived twelve locales.
const _forbidden = <String, _Forbidden>{
  'en': _Forbidden(
    secrecy: ['forward secrecy', 'perfect forward', 'earlier messages'],
    creator: ['created', 'creator', 'who made', 'set it up', 'set up'],
    restored: [
      'working again',
      'is fixed',
      'restored',
      'back to normal',
      'now working',
    ],
    retry: ['try again', 'retry'],
    modal: ['may '],
  ),
  'de': _Forbidden(
    secrecy: ['vorwärtssicherheit', 'forward secrecy'],
    creator: ['erstellt hat', 'ersteller', 'angelegt hat', 'erstellt hast'],
    restored: ['funktioniert wieder', 'wiederhergestellt', 'behoben'],
    retry: [
      'erneut versuchen',
      'noch einmal versuchen',
      'nochmal versuchen',
      'noch mal versuchen',
      'versuch es',
      'versuche es',
      'erneut probieren',
    ],
    modal: ['möglicherweise', 'unter umständen', 'eventuell', 'kann '],
  ),
  'es': _Forbidden(
    secrecy: ['secreto hacia adelante', 'confidencialidad persistente'],
    creator: ['quien creó', 'creaste', 'creador', 'creó este'],
    restored: [
      'vuelve a funcionar',
      'restaurad',
      'ya funciona',
      'solucionado',
      'arreglado',
    ],
    retry: [
      'inténtalo de nuevo',
      'inténtalo otra vez',
      'vuelve a intentar',
      'reinténtalo',
      'prueba de nuevo',
      'vuelve a probar',
    ],
    modal: ['puede', 'podría'],
  ),
  'fr': _Forbidden(
    secrecy: ['confidentialité persistante', 'secret de transmission'],
    creator: ['a créé', 'avez créé', 'as créé', 'créateur', 'créatrice'],
    restored: ['fonctionne à nouveau', 'rétabli', 'refonctionne'],
    retry: ['réessayez', 'réessayer', 'nouvelle tentative'],
    modal: ['peut', 'pourrait'],
  ),
  'pt': _Forbidden(
    secrecy: ['sigilo antecipado', 'sigilo persistente'],
    creator: ['quem criou', 'você criou', 'criador', 'criou este'],
    restored: ['voltou a funcionar', 'restaurad', 'já funciona'],
    retry: [
      'tente de novo',
      'tentar novamente',
      'tente novamente',
      'tentar de novo',
      'tente outra vez',
      'tentar outra vez',
    ],
    modal: ['pode', 'poderá'],
  ),
  'ru': _Forbidden(
    secrecy: ['прямая секретность'],
    creator: ['кто его создал', 'вы создали', 'создател'],
    restored: ['снова работает', 'восстановлен', 'уже работает'],
    retry: ['попробуйте ещё раз', 'повторите попытку', 'попробуйте снова'],
    modal: ['может', 'сможет'],
  ),
  'tr': _Forbidden(
    secrecy: ['ileri gizlilik'],
    creator: ['oluşturan kişi', 'oluşturduysanız', 'oluşturan kullanıcı'],
    restored: ['yeniden çalışıyor', 'düzeldi', 'geri geldi'],
    retry: ['tekrar deney', 'yeniden deney', 'bir daha deney'],
    modal: ['ebilir', 'abilir'],
  ),
  'ar': _Forbidden(
    secrecy: ['السرية التامة للأمام'],
    creator: ['أنشأها', 'من أنشأ', 'منشئ'],
    restored: ['يعمل من جديد', 'استُعيد', 'عادت المشاركة'],
    retry: [
      'حاول مرة أخرى',
      'أعد المحاولة',
      'إعادة المحاولة',
      'المحاولة مرة أخرى',
      'المحاولة مجددًا',
      'المحاولة من جديد',
    ],
    modal: ['قد '],
  ),
  'fa': _Forbidden(
    secrecy: ['رازداری پیشرو'],
    creator: ['ساخته', 'سازنده'],
    restored: ['دوباره کار می‌کند', 'بازیابی شد'],
    retry: [
      'دوباره تلاش',
      'بار دیگر تلاش',
      'تلاش دوباره',
      'تلاش مجدد',
      'دوباره امتحان',
    ],
    modal: ['ممکن است', 'شاید', 'می‌تواند'],
  ),
  'ur': _Forbidden(
    secrecy: ['فارورڈ سیکریسی'],
    creator: ['بنایا ہے', 'بنانے وال'],
    restored: ['دوبارہ کام کر', 'بحال ہو'],
    retry: [
      'دوبارہ کوشش کریں',
      'پھر کوشش کریں',
      'پھر سے کوشش',
      'دوبارہ کوشش کیجیے',
    ],
    modal: ['سکتا', 'سکتے', 'سکتی'],
  ),
  'hi': _Forbidden(
    secrecy: ['फ़ॉरवर्ड सीक्रेसी'],
    creator: ['बनाया है', 'बनाने वाल', 'निर्माता'],
    restored: ['फिर से काम कर', 'ठीक हो गया', 'बहाल'],
    retry: [
      'फिर कोशिश कर',
      'फिर से कोशिश',
      'दोबारा कोशिश',
      'फिर से प्रयास',
      'दोबारा प्रयास',
      'पुनः प्रयास',
    ],
    modal: ['सकता', 'सकते', 'सकती'],
  ),
  'ne': _Forbidden(
    secrecy: ['फरवार्ड सिक्रेसी'],
    creator: ['बनाउने व्यक्ति', 'बनाउनुभएको', 'निर्माता'],
    restored: ['फेरि चल्न', 'ठीक भयो', 'पुनःस्थापित'],
    retry: ['फेरि प्रयास', 'पुनः प्रयास', 'फेरि कोसिस', 'पुनः कोसिस'],
    modal: ['सक्छ', 'सक्नु', 'सक्ने'],
  ),
  'ja': _Forbidden(
    secrecy: ['前方秘匿'],
    creator: ['作成した人', 'あなたが作成', '作った人', '作成者'],
    restored: ['復旧しました', '直りました', '再開しました', '元に戻りました'],
    retry: ['もう一度お試し', '再試行', 'もう一度実行', '再度お試し', 'もう一度試して', 'やり直してください'],
    modal: ['ことがあります', 'ことも', '場合があります'],
  ),
};

/// Every string this guard covers, for one locale.
List<(String, String)> _repairStrings(AppLocalizations l) => [
  ('sharingHealthRepairAction', l.sharingHealthRepairAction),
  ('sharingHealthRepairSent', l.sharingHealthRepairSent),
  ('sharingHealthBodyUnrecoverable', l.sharingHealthBodyUnrecoverable),
  ('sharingHealthRepairNothingToDo', l.sharingHealthRepairNothingToDo),
  ('sharingHealthRepairHintAnyMember', l.sharingHealthRepairHintAnyMember),
  (
    'sharingHealthRepairUnresolvedAnnouncement',
    l.sharingHealthRepairUnresolvedAnnouncement,
  ),
];

/// The strings whose state no retry changes.
const _terminalCopy = ['sharingHealthBodyUnrecoverable'];

/// The forbidden terms [value] contains, given the [terms] that apply to it.
List<String> violations(String value, List<String> terms) {
  final haystack = value.toLowerCase();
  return [for (final t in terms) if (haystack.contains(t.toLowerCase())) t];
}

void main() {
  test('every supported locale has a forbidden list', () {
    // A locale added without one would be scanned against nothing and pass
    // silently, which is worse than not scanning it: the gate would report
    // coverage it does not have.
    expect(
      AppLocalizations.supportedLocales.map((l) => l.languageCode).toSet(),
      _forbidden.keys.toSet(),
    );
  });

  for (final locale in AppLocalizations.supportedLocales) {
    final code = locale.languageCode;
    group('$code repair copy', () {
      late AppLocalizations l;
      late _Forbidden forbidden;

      setUp(() async {
        l = await AppLocalizations.delegate.load(locale);
        forbidden = _forbidden[code]!;
      });

      test('never claims forward secrecy', () {
        for (final (key, value) in _repairStrings(l)) {
          expect(
            violations(value, forbidden.secrecy),
            isEmpty,
            reason:
                '$code/$key: the repair promises nothing about what was sent '
                'before — "$value"',
          );
        }
      });

      test('the Repair hint names no creator and no role', () {
        final hint = l.sharingHealthRepairHintAnyMember;
        expect(
          violations(hint, forbidden.creator),
          isEmpty,
          reason: '$code: any member can repair — "$hint"',
        );
        expect(
          hint.toLowerCase(),
          isNot(contains(l.circleMemberAdmin.toLowerCase())),
          reason:
              '$code: the hint must not scope the repair to the Admin role '
              '("${l.circleMemberAdmin}") — "$hint"',
        );
      });

      test('does not claim sharing is working again', () {
        expect(
          violations(l.sharingHealthRepairSent, forbidden.restored),
          isEmpty,
          reason:
              '$code: the others only apply the repair when they next RECEIVE '
              'it — "${l.sharingHealthRepairSent}"',
        );
      });

      test('does not invite a retry it cannot honour', () {
        for (final key in _terminalCopy) {
          final value = _repairStrings(l).firstWhere((e) => e.$1 == key).$2;
          expect(
            violations(value, forbidden.retry),
            isEmpty,
            reason: '$code/$key: no retry changes this — "$value"',
          );
        }
      });

      test('keeps the Repair hint MODAL', () {
        expect(
          violations(l.sharingHealthRepairHintAnyMember, forbidden.modal),
          isNotEmpty,
          reason:
              '$code: the Repair hint states the new keys as a fact — '
              '"${l.sharingHealthRepairHintAnyMember}"',
        );
      });

      test('is non-empty and free of the untranslated placeholder', () {
        for (final (key, value) in _repairStrings(l)) {
          expect(value.trim(), isNotEmpty, reason: '$code/$key');
          expect(value, isNot(contains('TODO')), reason: '$code/$key');
        }
      });
    });
  }

  test('the scanner actually catches a violation', () {
    // Anti-vacuity: without this, an empty term list or a broken `contains`
    // would let every locale pass and the gate would prove nothing.
    expect(
      violations(
        'This restores forward secrecy for earlier messages.',
        _forbidden['en']!.secrecy,
      ),
      unorderedEquals(['forward secrecy', 'earlier messages']),
    );
    expect(
      violations('Ask whoever created it.', _forbidden['en']!.creator),
      contains('created'),
    );
    expect(
      violations(
        'Reconnects to the relays and gives it a new key.',
        _forbidden['en']!.modal,
      ),
      isEmpty,
      reason: 'a flat indicative carries no modal marker',
    );
    expect(
      violations('It may give it a new key.', _forbidden['en']!.modal),
      contains('may '),
    );
  });
}
