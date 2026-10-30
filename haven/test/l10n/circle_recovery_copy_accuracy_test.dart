// Copy accuracy for the circle-recovery strings, in EVERY supported locale.
//
// Three claims a translation can break without a reviewer noticing months
// later, so each is held here as forbidden vocabulary per locale:
//
//   1. The collision and cannot-check bodies never claim two circles share an
//      identifier: a store that did not answer reads exactly like a
//      collision, so such a claim can be false (`commit_notes.rs`
//      RoutingCollision).
//   2. The Stalled and Unrecoverable bodies invite no retry: no retry helps
//      either, and neither offers a button.
//   3. The invitation strings never say "delivered" for a relay's acceptance:
//      a relay took it, which is "sent".
//
// The per-locale vocabulary is each locale reviewer's (decision 318); it does
// not prove a translation is right, only that it avoids these wrong words.
// That is the reviewer-agent half of the l10n workflow.
@TestOn('vm')
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:haven/l10n/app_localizations.dart';

class _Vocabulary {
  const _Vocabulary({
    required this.sameId,
    required this.retry,
    required this.delivered,
  });

  /// Words claiming two circles share an identifier, or naming a duplicate.
  final List<String> sameId;

  /// Words inviting another attempt.
  final List<String> retry;

  /// Words for "delivered".
  final List<String> delivered;
}

const _vocabulary = <String, _Vocabulary>{
  'en': _Vocabulary(
    sameId: ['same id', 'same identifier', 'duplicate', 'another circle'],
    retry: ['try again', 'retry'],
    delivered: ['delivered'],
  ),
  'de': _Vocabulary(
    sameId: [
      'kennung',
      'identifikator',
      'gleiche id',
      'gleichen id',
      'dieselbe id',
      'derselben id',
      'doppelt',
      'duplikat',
      'anderer kreis',
      'anderen kreis',
      'zwei kreise',
    ],
    retry: [
      'erneut versuchen',
      'noch einmal versuchen',
      'nochmal versuchen',
      'noch mal versuchen',
      'versuch es',
      'versuche es',
      'erneut probieren',
    ],
    delivered: ['zugestellt', 'zustell', 'geliefert', 'angekommen'],
  ),
  'es': _Vocabulary(
    sameId: [
      'mismo id',
      'misma id',
      'mismo identificador',
      'duplicad',
      'otro círculo',
    ],
    retry: [
      'inténtalo de nuevo',
      'inténtalo otra vez',
      'vuelve a intentar',
      'reinténtalo',
      'prueba de nuevo',
      'vuelve a probar',
    ],
    delivered: ['entreg'],
  ),
  'fr': _Vocabulary(
    sameId: [
      'même identifiant',
      'dupliqu',
      'doublon',
      'même id',
      'identifiant identique',
      'autre cercle',
    ],
    retry: [
      'réessayez',
      'réessayer',
      'nouvelle tentative',
      'essayez à nouveau',
      'essayez de nouveau',
      'recommencez',
    ],
    delivered: ['livré', 'remis', 'reçu', 'parvenu', 'distribué'],
  ),
  'pt': _Vocabulary(
    sameId: [
      'mesmo id',
      'mesmo identificador',
      'duplicad',
      'mesma identificação',
      'identificador igual',
      'id igual',
    ],
    retry: [
      'tente de novo',
      'tentar novamente',
      'tente novamente',
      'tentar de novo',
      'tente outra vez',
      'tentar outra vez',
    ],
    delivered: ['entreg', 'recebid'],
  ),
  'ru': _Vocabulary(
    sameId: ['тот же идентификатор', 'одинаковый идентификатор', 'дубликат'],
    retry: ['попробуйте ещё раз', 'повторите попытку', 'попробуйте снова'],
    delivered: ['доставлен'],
  ),
  'tr': _Vocabulary(
    sameId: [
      'aynı kimlik',
      'aynı tanımlayıcı',
      'aynı id',
      'yinelenen',
      'başka bir çevre',
    ],
    retry: ['tekrar deney', 'yeniden deney', 'bir daha deney'],
    delivered: ['teslim', 'iletildi', 'ulaştırıldı'],
  ),
  'ar': _Vocabulary(
    sameId: [
      'المعرّف نفسه',
      'المعرف نفسه',
      'نفس المعرّف',
      'نفس المعرف',
      'معرّف واحد',
      'معرف واحد',
      'مكرّر',
      'مكرر',
      'دائرة أخرى',
    ],
    retry: [
      'حاول مرة أخرى',
      'أعد المحاولة',
      'إعادة المحاولة',
      'المحاولة مرة أخرى',
      'المحاولة مجددًا',
      'المحاولة من جديد',
    ],
    delivered: [
      'تم تسليم',
      'تسليم',
      'سُلِّمت',
      'سُلّمت',
      'سلمت',
      'توصيل',
      'وصلت إلى',
    ],
  ),
  'fa': _Vocabulary(
    sameId: ['شناسه', 'تکراری', 'یکسان', 'مشترک'],
    retry: [
      'دوباره تلاش',
      'بار دیگر تلاش',
      'تلاش دوباره',
      'تلاش مجدد',
      'دوباره امتحان',
    ],
    delivered: ['تحویل', 'دریافت شد', 'به دستش رسید'],
  ),
  'ur': _Vocabulary(
    sameId: [
      'ایک ہی شناخت',
      'ڈپلیکیٹ',
      'ایک جیسی شناخت',
      'یکساں شناخت',
      'آئی ڈی',
      'دوسرے حلقے',
    ],
    retry: [
      'دوبارہ کوشش کریں',
      'پھر کوشش کریں',
      'پھر سے کوشش',
      'دوبارہ کوشش کیجیے',
    ],
    delivered: ['ڈیلیور', 'پہنچا دیا', 'پہنچ گیا', 'پہنچ گئ', 'موصول ہو'],
  ),
  'hi': _Vocabulary(
    sameId: [
      'वही पहचान',
      'एक ही पहचान',
      'समान पहचान',
      'वही आईडी',
      'एक ही आईडी',
      'डुप्लिकेट',
      'दूसरे सर्कल',
    ],
    retry: [
      'फिर कोशिश कर',
      'फिर से कोशिश',
      'दोबारा कोशिश',
      'फिर से प्रयास',
      'दोबारा प्रयास',
      'पुनः प्रयास',
    ],
    delivered: ['डिलीवर', 'वितरित', 'पहुँच', 'पहुंच'],
  ),
  'ne': _Vocabulary(
    sameId: [
      'उही पहिचान',
      'एउटै पहिचान',
      'उही id',
      'एउटै id',
      'डुप्लिकेट',
      'दोहोरो',
      'दोहोरिएको',
      'अर्को सर्कल',
    ],
    retry: ['फेरि प्रयास', 'पुनः प्रयास', 'फेरि कोसिस', 'पुनः कोसिस'],
    delivered: [
      'डेलिभर',
      'वितरित',
      'वितरण',
      'पुगेको',
      'पुग्यो',
      'प्राप्त भयो',
      'प्राप्त गरियो',
    ],
  ),
  'ja': _Vocabulary(
    sameId: ['同じid', '重複', '同じ識別子', '識別子が同じ', 'idが同じ', '別のサークル'],
    retry: ['もう一度お試し', '再試行', 'もう一度実行', '再度お試し', 'もう一度試して', 'やり直してください'],
    delivered: ['配信', '配達', '届きました', '届けました', '届いて'],
  ),
};

List<String> _hits(String value, List<String> terms) {
  final haystack = value.toLowerCase();
  return [for (final t in terms) if (haystack.contains(t.toLowerCase())) t];
}

void main() {
  test('every supported locale has a vocabulary', () {
    expect(
      AppLocalizations.supportedLocales.map((l) => l.languageCode).toSet(),
      _vocabulary.keys.toSet(),
    );
  });

  for (final locale in AppLocalizations.supportedLocales) {
    final code = locale.languageCode;
    group('$code recovery copy', () {
      late AppLocalizations l;
      late _Vocabulary v;

      setUp(() async {
        l = await AppLocalizations.delegate.load(locale);
        v = _vocabulary[code]!;
      });

      test('never claims two circles share an identifier', () {
        for (final (key, value) in [
          ('sharingHealthBodyCollision', l.sharingHealthBodyCollision),
          ('sharingHealthBodyCannotCheck', l.sharingHealthBodyCannotCheck),
        ]) {
          expect(_hits(value, v.sameId), isEmpty, reason: '$code/$key: $value');
        }
      });

      test('a stall and a halt invite no retry', () {
        for (final (key, value) in [
          ('sharingHealthBodyStalled', l.sharingHealthBodyStalled),
          ('sharingHealthBodyUnrecoverable', l.sharingHealthBodyUnrecoverable),
        ]) {
          expect(_hits(value, v.retry), isEmpty, reason: '$code/$key: $value');
        }
      });

      test('a relay acceptance is "sent", never "delivered"', () {
        for (final (key, value) in [
          (
            'nameCircleCreatedSentSoFarSnack',
            l.nameCircleCreatedSentSoFarSnack('C', 1, 3),
          ),
          ('addMemberSentSoFar', l.addMemberSentSoFar(1, 3, 'C')),
          // Every plural branch: `=1`/`one`, `two`, `few`, `many` and
          // `other` are each text of their own in some locale.
          for (final total in const [1, 2, 5, 21]) ...[
            (
              'nameCircleCreatedSentSoFarSnack $total',
              l.nameCircleCreatedSentSoFarSnack('C', 0, total),
            ),
            (
              'addMemberSentSoFar $total',
              l.addMemberSentSoFar(0, total, 'C'),
            ),
          ],
          ('changeNoteWelcomeOwed', l.changeNoteWelcomeOwed),
          ('memberCannotReceiveInvitations', l.memberCannotReceiveInvitations),
        ]) {
          expect(
            _hits(value, v.delivered),
            isEmpty,
            reason: '$code/$key: $value',
          );
        }
      });
    });
  }

  test('the scanner catches a violation', () {
    final en = _vocabulary['en']!;
    expect(
      _hits('Two circles share the same ID on this phone.', en.sameId),
      contains('same id'),
    );
    expect(_hits('Please try again later.', en.retry), contains('try again'));
    expect(_hits('1 of 3 delivered', en.delivered), contains('delivered'));
  });
}
