// Copy accuracy for the epoch-repair strings, in EVERY supported locale.
//
// The English versions of these six strings are pinned by
// `test/widgets/map/sharing_health_epoch_repair_test.dart`, which is where the
// claims were reasoned about. That is not enough: the app ships thirteen
// locales, the translations are written by people who cannot read the Rust,
// and three of the four claims below were ALREADY wrong in all twelve
// non-English locales at once — every one of them said the other members catch
// up "the next time their phones send a location", which is not how the repair
// propagates, and every one of them named the circle's CREATOR rather than its
// admin, which is wrong after an admin handoff.
//
// So the guard is per-locale and phrased as forbidden vocabulary, because that
// is the half a reviewer cannot reliably re-derive months later:
//
//   1. NOTHING may call this key rotation or claim forward secrecy. The commit
//      carries no `UpdatePath`: it resets sender ratchets and provides no
//      post-compromise security. See `haven-core/src/circle/rotation.rs`.
//   2. The "who can repair this" strings may not name the circle's CREATOR.
//      Only the current sole ADMIN can author the commit, and after a handoff
//      that is a different person.
//   3. The success string may not say sharing is working again. The repair is
//      published here; every other member applies it when they next RECEIVE
//      it, which can be minutes away and longer if a phone is asleep.
//   4. The two terminal strings may not invite a retry — the Repair button is
//      disabled while they are on screen, so a retry prompt points at a
//      control the user cannot press.
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
    required this.rotation,
    required this.creator,
    required this.restored,
    required this.retry,
    required this.modal,
    required this.controlNouns,
  });

  /// Words for key rotation or forward secrecy. Forbidden in every string.
  final List<String> rotation;

  /// Words naming the circle's creator. Forbidden where the ADMIN is meant.
  final List<String> creator;

  /// Words claiming sharing is working again. Forbidden in the success string.
  final List<String> restored;

  /// Words inviting another attempt. Forbidden in the terminal strings.
  final List<String> retry;

  /// Words for the CONTROL itself — button, option — in this locale.
  ///
  /// The disabled-state hint must name the control or carry the button's own
  /// label. A bare nominalisation of the action ("La réparation est
  /// indisponible", "Исправление недоступно") is heard as *repairing this
  /// circle is impossible*, which is false in one of the two cases the string
  /// covers: when the user is simply not the admin, the circle CAN be
  /// repaired, and the banner line beside it says so.
  final List<String> controlNouns;

  /// Modal markers for "may". At least one must appear in the Repair hint.
  ///
  /// Stated positively after the negative version failed to catch a real
  /// mutation: a forbidden list of flat phrasings ("gives it a new key") only
  /// matches when the verb and its object are CONTIGUOUS, and half the locales
  /// put the role condition between them, so deleting the modal left no
  /// forbidden substring behind. Requiring the hedge cannot be dodged by word
  /// order, and it goes stale loudly — as a failure — rather than silently.
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
    rotation: ['rotat', 'forward secrecy', 'perfect forward'],
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
    controlNouns: ['button', 'option'],
  ),
  'de': _Forbidden(
    rotation: ['rotier', 'rotation', 'vorwärtssicherheit', 'forward secrecy'],
    creator: ['erstellt hat', 'ersteller', 'angelegt hat', 'erstellt hast'],
    restored: ['funktioniert wieder', 'wiederhergestellt', 'behoben'],
    retry: ['erneut versuchen', 'noch einmal versuchen', 'versuch es erneut'],
    modal: ['möglicherweise', 'unter umständen', 'eventuell', 'kann '],
    controlNouns: ['schaltfläche', 'option', 'reparieren'],
  ),
  'es': _Forbidden(
    rotation: [
      'rotación',
      'rotar',
      'secreto hacia adelante',
      'confidencialidad persistente',
    ],
    creator: ['quien creó', 'creaste', 'creador', 'creó este'],
    restored: [
      'vuelve a funcionar',
      'restaurad',
      'ya funciona',
      'solucionado',
      'arreglado',
    ],
    retry: ['inténtalo de nuevo', 'vuelve a intentar', 'reinténtalo'],
    modal: ['puede', 'podría'],
    controlNouns: ['opción', 'botón'],
  ),
  'fr': _Forbidden(
    rotation: [
      'rotation',
      'faire tourner',
      'confidentialité persistante',
      'secret de transmission',
    ],
    creator: ['a créé', 'avez créé', 'as créé', 'créateur', 'créatrice'],
    restored: ['fonctionne à nouveau', 'rétabli', 'refonctionne'],
    retry: ['réessayez', 'réessayer', 'nouvelle tentative'],
    modal: ['peut', 'pourrait'],
    // `action` is this file's own word for what a control does
    // (`relaySettingsResetConfirm`: "Cette action est irréversible"), and
    // the button's role is already spoken by the merged semantics node
    // immediately before this hint, so echoing the label would stutter it.
    controlNouns: ['option', 'bouton', 'action'],
  ),
  'pt': _Forbidden(
    rotation: [
      'rotação',
      'rotacion',
      'sigilo antecipado',
      'sigilo persistente',
    ],
    creator: ['quem criou', 'você criou', 'criador', 'criou este'],
    restored: ['voltou a funcionar', 'restaurad', 'já funciona'],
    retry: ['tente de novo', 'tentar novamente', 'tente novamente'],
    modal: ['pode', 'poderá'],
    controlNouns: ['opção', 'botão'],
  ),
  'ru': _Forbidden(
    rotation: ['ротаци', 'прямая секретность'],
    creator: ['кто его создал', 'вы создали', 'создател'],
    restored: ['снова работает', 'восстановлен', 'уже работает'],
    retry: ['попробуйте ещё раз', 'повторите попытку', 'попробуйте снова'],
    modal: ['может', 'сможет'],
    controlNouns: ['кнопк', 'опци'],
  ),
  'tr': _Forbidden(
    rotation: ['rotasyon', 'ileri gizlilik'],
    creator: ['oluşturan kişi', 'oluşturduysanız', 'oluşturan kullanıcı'],
    restored: ['yeniden çalışıyor', 'düzeldi', 'geri geldi'],
    retry: ['tekrar deneyin', 'yeniden deneyin'],
    modal: ['ebilir', 'abilir'],
    controlNouns: ['düğme', 'seçenek', 'onarım'],
  ),
  'ar': _Forbidden(
    rotation: ['تدوير المفاتيح', 'السرية التامة للأمام'],
    creator: ['أنشأها', 'من أنشأ', 'منشئ'],
    restored: ['يعمل من جديد', 'استُعيد', 'عادت المشاركة'],
    retry: ['حاول مرة أخرى', 'أعد المحاولة'],
    modal: ['قد '],
    controlNouns: ['زر', 'خيار'],
  ),
  'fa': _Forbidden(
    rotation: ['چرخش کلید', 'رازداری پیشرو'],
    creator: ['ساخته', 'سازنده'],
    restored: ['دوباره کار می‌کند', 'بازیابی شد'],
    retry: ['دوباره تلاش کن', 'بار دیگر تلاش'],
    modal: ['ممکن است', 'شاید', 'می‌تواند'],
    controlNouns: ['دکمه', 'گزینه'],
  ),
  'ur': _Forbidden(
    rotation: ['روٹیشن', 'فارورڈ سیکریسی'],
    creator: ['بنایا ہے', 'بنانے وال'],
    restored: ['دوبارہ کام کر', 'بحال ہو'],
    retry: ['دوبارہ کوشش کریں', 'پھر کوشش کریں'],
    modal: ['سکتا', 'سکتے', 'سکتی'],
    controlNouns: ['بٹن', 'آپشن'],
  ),
  'hi': _Forbidden(
    rotation: ['रोटेशन', 'फ़ॉरवर्ड सीक्रेसी'],
    creator: ['बनाया है', 'बनाने वाल', 'निर्माता'],
    restored: ['फिर से काम कर', 'ठीक हो गया', 'बहाल'],
    retry: ['फिर कोशिश कर', 'दोबारा कोशिश'],
    modal: ['सकता', 'सकते', 'सकती'],
    controlNouns: ['विकल्प', 'बटन'],
  ),
  'ne': _Forbidden(
    rotation: ['रोटेसन', 'रोटेशन'],
    creator: ['बनाउने व्यक्ति', 'बनाउनुभएको', 'निर्माता'],
    restored: ['फेरि चल्न', 'ठीक भयो', 'पुनःस्थापित'],
    retry: ['फेरि प्रयास गर्नुहोस्', 'पुनः प्रयास गर्नुहोस्'],
    modal: ['सक्छ', 'सक्नु', 'सक्ने'],
    controlNouns: ['सुविधा', 'विकल्प', 'बटन'],
  ),
  'ja': _Forbidden(
    rotation: ['ローテーション', '前方秘匿'],
    creator: ['作成した人', 'あなたが作成', '作った人', '作成者'],
    restored: ['復旧しました', '直りました', '再開しました', '元に戻りました'],
    retry: ['もう一度お試し', '再試行', 'もう一度実行'],
    modal: ['ことがあります', 'ことも', '場合があります'],
    controlNouns: ['ボタン'],
  ),
};

/// Every string this guard covers, for one locale.
List<(String, String)> _repairStrings(AppLocalizations l) => [
  ('sharingHealthRepairAction', l.sharingHealthRepairAction),
  ('sharingHealthRepairSent', l.sharingHealthRepairSent),
  ('sharingHealthRepairNotOwner', l.sharingHealthRepairNotOwner),
  ('sharingHealthRepairNeedsNewCircle', l.sharingHealthRepairNeedsNewCircle),
  ('sharingHealthRepairNothingToDo', l.sharingHealthRepairNothingToDo),
  ('sharingHealthRepairHint', l.sharingHealthRepairHint),
  ('sharingHealthRepairUnavailableHint', l.sharingHealthRepairUnavailableHint),
  (
    'sharingHealthRepairUnresolvedAnnouncement',
    l.sharingHealthRepairUnresolvedAnnouncement,
  ),
];

/// The keys that must name the ADMIN role rather than the circle's creator.
const _mustNotNameCreator = [
  'sharingHealthRepairNotOwner',
  'sharingHealthRepairHint',
];

/// The keys whose claim is scoped to the circle's ADMIN.
///
/// `sharingHealthRepairHint` needs it because the key clause is conditional on
/// the role; `sharingHealthRepairNotOwner` needs it because naming who CAN
/// repair is the whole message.
const _mustNameTheRole = [
  'sharingHealthRepairHint',
  'sharingHealthRepairNotOwner',
];

/// The keys shown while the Repair button is DISABLED.
///
/// `sharingHealthRepairNotOwner` belongs here for the same reason the other two
/// do: the outcome that shows it is terminal, so the button beside it is dead
/// and a retry prompt would point at a control the user cannot press.
const _terminalCopy = [
  'sharingHealthRepairNotOwner',
  'sharingHealthRepairNeedsNewCircle',
  'sharingHealthRepairUnavailableHint',
];

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

      test('never calls it key rotation or claims forward secrecy', () {
        for (final (key, value) in _repairStrings(l)) {
          expect(
            violations(value, forbidden.rotation),
            isEmpty,
            reason:
                '$code/$key: the commit carries no UpdatePath and gives no '
                'post-compromise security — "$value"',
          );
        }
      });

      test('names the admin role, never the creator', () {
        for (final key in _mustNotNameCreator) {
          final value = _repairStrings(
            l,
          ).firstWhere((e) => e.$1 == key).$2;
          expect(
            violations(value, forbidden.creator),
            isEmpty,
            reason:
                '$code/$key: after an admin handoff the creator is no longer '
                'the admin — "$value"',
          );
        }
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
            reason:
                '$code/$key: the Repair button is disabled while this shows — '
                '"$value"',
          );
        }
      });

      test('names the admin ROLE in both strings that depend on it', () {
        // The other half of the hint's two hedges, and the one that had no
        // cover outside English: dropping "if you are this circle's admin"
        // leaves a hint promising every user a re-key only the sole admin can
        // get, and a spot check of one locale cannot see it.
        //
        // Asserted against this locale's OWN badge term rather than a
        // transliteration, so the banner and the member list are proved to
        // name the role the same way.
        for (final key in _mustNameTheRole) {
          final value = _repairStrings(l).firstWhere((e) => e.$1 == key).$2;
          expect(
            value.toLowerCase(),
            contains(l.circleMemberAdmin.toLowerCase()),
            reason:
                "$code/$key must name the role with this locale's Admin "
                'badge term ("${l.circleMemberAdmin}") — "$value"',
          );
        }
      });

      test('the disabled hint names the CONTROL, not the act', () {
        // Spoken while the Repair button is dead, and one of the two outcomes
        // that kill it is "you are not this circle's admin" — where the circle
        // is perfectly repairable by someone else. A hint that nominalises the
        // action instead of naming the control therefore contradicts, aloud,
        // the banner line sitting right beside it.
        final hint = l.sharingHealthRepairUnavailableHint.toLowerCase();
        expect(
          hint.contains(l.sharingHealthRepairAction.toLowerCase()) ||
              violations(hint, forbidden.controlNouns).isNotEmpty,
          isTrue,
          reason:
              '$code: the disabled-state hint must carry the button label '
              '("${l.sharingHealthRepairAction}") or name the control — '
              '"${l.sharingHealthRepairUnavailableHint}"',
        );
      });

      test('keeps the Repair hint MODAL', () {
        // The second of the hint's two hedges. Even for the sole admin, five
        // further gates decline silently, so a flat indicative would promise a
        // re-key that most presses do not get.
        expect(
          violations(l.sharingHealthRepairHint, forbidden.modal),
          isNotEmpty,
          reason:
              '$code: the Repair hint states the re-key as a fact — '
              '"${l.sharingHealthRepairHint}"',
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
        'This rotates the key and restores forward secrecy.',
        _forbidden['en']!.rotation,
      ),
      unorderedEquals(['rotat', 'forward secrecy']),
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
