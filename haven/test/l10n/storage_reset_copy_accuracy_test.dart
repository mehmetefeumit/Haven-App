// Copy accuracy for what the storage-reset copy says is held back or removed,
// in EVERY supported locale.
//
// Three promises the code keeps, and nothing wider:
//
// * Until the user's answer to the notice is saved, Haven publishes neither
//   their relay lists (kinds 10050/10002, "relay settings") nor their
//   KeyPackage (kind 30443, "invitation key") — the gate in
//   `build_relay_list_publish`, `maintain_relay_list_category` and
//   `maintain_key_package`, proved by rust_builder
//   `no_relay_list_is_published_before_the_reset_is_acknowledged`. Their
//   profile, the invitations they send and their location still go out, so a
//   blanket "nothing is published" is false — in `storageResetRelays`, in
//   `storageResetAcknowledgeFailed`, anywhere.
// * This update reset the relay settings: they lived only in the deleted
//   pre-v2 `circles.db`. Told as the current state ("are back to defaults") it
//   is false on a re-shown notice after the user has added relays.
// * The reset removed the circles, the nicknames and the unsaved profile edits
//   made before the update: all lived only in the deleted pre-v2 `circles.db`
//   (the display name's local copy is dropped and re-taken from the published
//   profile, `storage_reset_own_name_test.dart`), and the v2 stores are never
//   touched. The notice can show again after the user has made new circles,
//   given new nicknames and edited their profile, so "any circles you had", a
//   bare "your nicknames" and an unscoped "profile change" are false on that
//   second showing.
//
// Per locale, on the strings as `AppLocalizations` renders them:
//
//   1. both relay sentences name the relay settings in the word this locale's
//      notice uses;
//   2. the failed-answer snackbar names the invitation key;
//   3. none of the three strings makes the blanket claim — matched with this
//      locale's own words for it, proved non-vacuous against a FROZEN copy of
//      the round-three `storageResetAcknowledgeFailed` that said it (never a
//      live ARB value, which a correct rewrite would empty);
//   4. the relay reset is told as an event of this update, the circles removal
//      is scoped to circles made before it, the nicknames to nicknames given
//      before it, and the profile change to one unsaved "by then" — each clause
//      proved discriminating against a FROZEN copy of the earlier sentence
//      that lacked it.
//
// Not covered: whether a translation is idiomatic. That is the reviewer half
// of the l10n workflow.
@TestOn('vm')
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:haven/l10n/app_localizations.dart';

class _Copy {
  const _Copy({
    required this.relay,
    required this.invitationKey,
    required this.blanket,
    required this.claimedNothing,
  });

  /// This locale's word for the relay settings, lower-cased.
  final String relay;

  /// This locale's "invitation key", lower-cased.
  final String invitationKey;

  /// This locale's blanket "nothing is published", as a pattern.
  final Pattern blanket;

  /// The round-three `storageResetAcknowledgeFailed`, frozen: the text that
  /// made the blanket claim, and so proves [blanket] matches it.
  final String claimedNothing;
}

final _copy = <String, _Copy>{
  'en': _Copy(
    relay: 'relay settings',
    invitationKey: 'invitation key',
    blanket: RegExp(r'\b(nothing|anything)\b'),
    claimedNothing:
        'Haven couldn’t save your answer. Until then, nothing is published. '
        'Try again, or Haven will ask again the next time it opens.',
  ),
  'ar': const _Copy(
    relay: 'المُرحِّلات',
    invitationKey: 'مفتاح الدعوة',
    blanket: 'لن يُنشر أي شيء',
    claimedNothing:
        'تعذّر على Haven حفظ إجابتك. وإلى أن تُحفظ، لن يُنشر أي شيء. أعد '
        'المحاولة، وإلا فسيسألك Haven من جديد عند فتحه في المرة القادمة.',
  ),
  'de': const _Copy(
    relay: 'relay',
    invitationKey: 'einladungsschlüssel',
    blanket: 'nichts veröffentlicht',
    claimedNothing:
        'Haven konnte deine Antwort nicht speichern. Solange sie nicht '
        'gespeichert ist, wird nichts veröffentlicht. Versuche es erneut – '
        'sonst fragt Haven beim nächsten Öffnen noch einmal.',
  ),
  'es': const _Copy(
    relay: 'relés',
    invitationKey: 'clave de invitación',
    blanket: 'no se publica nada',
    claimedNothing:
        'Haven no pudo guardar tu respuesta. Hasta que se guarde, no se '
        'publica nada. Vuelve a intentarlo o Haven te lo volverá a preguntar '
        'la próxima vez que se abra.',
  ),
  'fa': const _Copy(
    relay: 'رله',
    invitationKey: 'کلید دعوت',
    blanket: 'چیزی منتشر نمی‌شود',
    claimedNothing:
        'Haven نتوانست پاسخت را ذخیره کند. تا وقتی ذخیره نشود، چیزی منتشر '
        'نمی‌شود. دوباره تلاش کن، وگرنه Haven دفعهٔ بعد که باز شود دوباره '
        'می‌پرسد.',
  ),
  'fr': const _Copy(
    relay: 'relais',
    invitationKey: "clé d'invitation",
    blanket: "rien n'est publié",
    claimedNothing:
        "Haven n'a pas pu enregistrer votre réponse. Tant qu'elle n'est pas "
        "enregistrée, rien n'est publié. Réessayez, sinon Haven vous la "
        'redemandera à sa prochaine ouverture.',
  ),
  'hi': const _Copy(
    relay: 'रिले',
    invitationKey: 'निमंत्रण कुंजी',
    blanket: 'कुछ भी प्रकाशित नहीं',
    claimedNothing:
        'Haven आपका जवाब सहेज नहीं सका। जब तक यह सहेजा नहीं जाता, कुछ भी '
        'प्रकाशित नहीं होगा। फिर से कोशिश करें, नहीं तो अगली बार खुलने पर '
        'Haven फिर पूछेगा।',
  ),
  // Japanese puts no space between sentences, so the fixture is joined bare.
  'ja': _Copy(
    relay: 'リレー',
    invitationKey: '招待用の鍵',
    blanket: '何も公開',
    claimedNothing: [
      'Haven は回答を保存できませんでした。',
      '保存されるまで、何も公開されません。',
      'もう一度お試しください。',
      'そのままにすると、次に Haven を開いたときにもう一度確認されます。',
    ].join(),
  ),
  'ne': const _Copy(
    relay: 'रिले',
    invitationKey: 'निमन्त्रणा कुञ्जी',
    blanket: 'केही पनि प्रकाशित',
    claimedNothing:
        'Haven ले तपाईंको जवाफ सुरक्षित गर्न सकेन। यो सुरक्षित नभएसम्म केही '
        'पनि प्रकाशित हुँदैन। फेरि प्रयास गर्नुहोस्, नत्र अर्को पटक Haven '
        'खुल्दा फेरि सोधिनेछ।',
  ),
  'pt': const _Copy(
    relay: 'relays',
    invitationKey: 'chave de convite',
    blanket: 'nada é publicado',
    claimedNothing:
        'O Haven não conseguiu salvar sua resposta. Até que ela seja salva, '
        'nada é publicado. Tente de novo ou o Haven vai perguntar novamente '
        'na próxima vez que for aberto.',
  ),
  'ru': const _Copy(
    relay: 'реле',
    invitationKey: 'ключ приглашения',
    blanket: 'ничего не',
    claimedNothing:
        'Haven не удалось сохранить ваш ответ. Пока он не сохранён, ничего не '
        'публикуется. Повторите попытку — иначе Haven спросит снова при '
        'следующем запуске.',
  ),
  'tr': const _Copy(
    relay: 'aktarıcı',
    invitationKey: 'davet anahtar',
    blanket: 'hiçbir şey yayımlanmaz',
    claimedNothing:
        'Haven yanıtınızı kaydedemedi. Yanıtınız kaydedilene kadar hiçbir şey '
        'yayımlanmaz. Tekrar deneyin; yoksa Haven bir dahaki açılışta yeniden '
        'soracak.',
  ),
  'ur': const _Copy(
    relay: 'ریلے',
    invitationKey: 'دعوتی کلید',
    blanket: 'کچھ بھی شائع نہیں',
    claimedNothing:
        'Haven آپ کا جواب محفوظ نہیں کر سکا۔ جب تک یہ محفوظ نہ ہو، کچھ بھی '
        'شائع نہیں ہوگا۔ دوبارہ کوشش کریں، ورنہ اگلی بار کھلنے پر Haven پھر '
        'پوچھے گا۔',
  ),
};

/// Per locale: this locale's word for the nicknames, the scoped clause the
/// nicknames sentence must carry (lower-cased), and the round-five sentence
/// without the scope, frozen.
const _nicknames = <String, (String, String, String)>{
  'en': (
    'nicknames',
    'nicknames you gave people before this update',
    'Nicknames you gave people and any profile change that had not finished '
        'saving were also removed.',
  ),
  'ar': (
    'الأسماء المستعارة',
    'الأسماء المستعارة التي أعطيتها للأشخاص قبل هذا التحديث',
    'وأُزيلت أيضًا الأسماء المستعارة التي أعطيتها للأشخاص وأي تغيير في الملف '
        'الشخصي لم يكتمل حفظه.',
  ),
  'de': (
    'spitznamen',
    'spitznamen, die du anderen vor diesem update gegeben hast',
    'Auch die Spitznamen, die du anderen gegeben hast, und Profiländerungen, '
        'deren Speichern noch nicht abgeschlossen war, wurden entfernt.',
  ),
  'es': (
    'apodos',
    'apodos que pusiste a otras personas antes de esta actualización',
    'También se eliminaron los apodos que pusiste a otras personas y cualquier '
        'cambio de perfil que no se hubiera terminado de guardar.',
  ),
  'fa': (
    'نام‌های مستعار',
    'نام‌های مستعاری که پیش از این به‌روزرسانی',
    'نام‌های مستعاری که برای افراد گذاشته بودی و هر تغییری در نمایه که '
        'ذخیره‌اش تمام نشده بود هم حذف شدند.',
  ),
  'fr': (
    'surnoms',
    "surnoms que vous aviez donnés à d'autres personnes "
        'avant cette mise à jour',
    "Les surnoms que vous aviez donnés à d'autres personnes et toute "
        "modification de profil dont l'enregistrement n'était pas terminé ont "
        'également été supprimés.',
  ),
  'hi': (
    'उपनाम',
    'इस अपडेट से पहले आपने लोगों को जो उपनाम',
    'आपने लोगों को जो उपनाम दिए थे, और प्रोफ़ाइल का कोई भी बदलाव जो पूरी तरह '
        'सहेजा नहीं गया था, वे भी हटा दिए गए।',
  ),
  'ja': (
    'ニックネーム',
    'このアップデートより前に相手に付けたニックネーム',
    // Japanese puts no space between clauses, so the fixture is joined bare.
    '相手に付けたニックネームと、'
        '保存が完了していなかったプロフィールの変更も削除されました。',
  ),
  'ne': (
    'उपनामहरू',
    'यो अपडेटअघि तपाईंले मानिसहरूलाई दिएका उपनामहरू',
    'तपाईंले मानिसहरूलाई दिएका उपनामहरू र सुरक्षित गर्ने काम पूरा नभएका '
        'प्रोफाइल परिवर्तनहरू पनि हटाइए।',
  ),
  'pt': (
    'apelidos',
    'apelidos que você deu às pessoas antes desta atualização',
    'Os apelidos que você deu às pessoas e qualquer alteração de perfil que '
        'ainda não tinha sido salva por completo também foram removidos.',
  ),
  'ru': (
    'псевдонимы',
    'псевдонимы, которые вы дали людям до этого обновления',
    'Также удалены псевдонимы, которые вы дали людям, и изменения профиля, '
        'сохранение которых не завершилось.',
  ),
  'tr': (
    'takma adlar',
    'bu güncellemeden önce kişilere verdiğiniz takma adlar',
    'Kişilere verdiğiniz takma adlar ve kaydedilmesi tamamlanmamış profil '
        'değişiklikleri de kaldırıldı.',
  ),
  'ur': (
    'عرفی نام',
    'اس اپ ڈیٹ سے پہلے آپ نے لوگوں کو جو عرفی نام',
    'آپ نے لوگوں کو جو عرفی نام دیے تھے، اور پروفائل کی کوئی بھی ایسی تبدیلی '
        'جو مکمل طور پر محفوظ نہیں ہوئی تھی، وہ بھی ہٹا دیے گئے۔',
  ),
};

/// Per locale: the scoped clause `storageResetRelays` must tell the reset
/// with (lower-cased), and its round-five first sentence, frozen, which stated
/// the current state instead.
const _relayReset = <String, (String, String)>{
  'en': (
    'this update reset your relay settings',
    'Your relay settings are back to Haven’s defaults.',
  ),
  'ar': (
    'أعاد هذا التحديث إعدادات المُرحِّلات',
    'أُعيدت إعدادات المُرحِّلات إلى الإعدادات الافتراضية في Haven.',
  ),
  'de': (
    'dieses update hat deine relay-einstellungen',
    'Deine Relay-Einstellungen sind auf Havens Standardwerte zurückgesetzt.',
  ),
  'es': (
    'esta actualización restableció tus ajustes de relés',
    'Tus ajustes de relés volvieron a los valores predeterminados de Haven.',
  ),
  'fa': (
    'این به‌روزرسانی تنظیمات رله‌هایت',
    'تنظیمات رله‌هایت به پیش‌فرض‌های Haven برگشته است.',
  ),
  'fr': (
    'cette mise à jour a réinitialisé vos paramètres de relais',
    'Vos paramètres de relais ont été réinitialisés aux valeurs par '
        'défaut de Haven.',
  ),
  'hi': (
    'इस अपडेट ने आपकी रिले सेटिंग्स',
    'आपकी रिले सेटिंग्स Haven की डिफ़ॉल्ट सेटिंग्स पर लौट आई हैं।',
  ),
  'ja': (
    'このアップデートで、リレーの設定は',
    'リレーの設定は Haven のデフォルトに戻りました。',
  ),
  'ne': (
    'यो अपडेटले तपाईंका रिले सेटिङहरू',
    'तपाईंका रिले सेटिङहरू Haven का पूर्वनिर्धारित सेटिङहरूमा फर्किएका छन्।',
  ),
  'pt': (
    'esta atualização redefiniu suas configurações de relays',
    'Suas configurações de relays voltaram aos padrões do Haven.',
  ),
  'ru': (
    'это обновление сбросило настройки реле',
    'Настройки реле сброшены к значениям Haven по умолчанию.',
  ),
  'tr': (
    'bu güncelleme aktarıcı ayarlarınızı',
    "Aktarıcı ayarlarınız Haven'ın varsayılanlarına döndü.",
  ),
  'ur': (
    'اس اپ ڈیٹ نے آپ کی ریلے کی ترتیبات',
    'آپ کی ریلے کی ترتیبات Haven کی طے شدہ ترتیبات پر واپس آ گئی ہیں۔',
  ),
};

/// Per locale: the scoped clause `storageResetLost` must remove circles with
/// (lower-cased), and its round-four first sentence, frozen, which said "any
/// circles you had".
const _circlesScope = <String, (String, String)>{
  'en': (
    'circles made before this update',
    'To move to Haven’s new encryption engine, any circles you had '
        'were removed.',
  ),
  'ar': (
    'أُزيلت الدوائر التي أُنشئت قبل هذا التحديث',
    'للانتقال إلى محرّك التشفير الجديد في Haven، أُزيلت أي دوائر كانت لديك.',
  ),
  'de': (
    'kreise entfernt, die vor diesem update erstellt wurden',
    'Für den Wechsel zu Havens neuer Verschlüsselungs-Engine wurden '
        'alle Kreise entfernt, die du hattest.',
  ),
  'es': (
    'círculos creados antes de esta actualización',
    'Para pasar al nuevo motor de cifrado de Haven, se eliminaron '
        'los círculos que tuvieras.',
  ),
  'fa': (
    'حلقه‌هایی که پیش از این به‌روزرسانی ساخته شده بودند',
    'برای انتقال به موتور رمزگذاری جدید Haven، هر حلقه‌ای که داشتی حذف شد.',
  ),
  'fr': (
    'cercles créés avant cette mise à jour',
    'Pour le passage au nouveau moteur de chiffrement de Haven, les '
        'cercles que vous aviez ont été supprimés.',
  ),
  'hi': (
    'इस अपडेट से पहले बनाए गए सर्कल',
    'Haven के नए एन्क्रिप्शन इंजन पर जाने के लिए आपके जो भी सर्कल '
        'थे, वे हटा दिए गए।',
  ),
  'ja': (
    'このアップデートより前に作成されたサークル',
    'Haven の新しい暗号化エンジンに移行するため、お持ちだったサークルはすべて削除されました。',
  ),
  'ne': (
    'यो अपडेटअघि बनाइएका सर्कलहरू',
    'Haven को नयाँ इन्क्रिप्शन इन्जिनमा सर्न तपाईंसँग भएका सबै सर्कलहरू हटाइए।',
  ),
  'pt': (
    'círculos criados antes desta atualização',
    'Para passar ao novo mecanismo de criptografia do Haven, os '
        'círculos que você tinha foram removidos.',
  ),
  'ru': (
    'круги, созданные до этого обновления',
    'Для перехода на новый механизм шифрования Haven все ваши '
        'круги, если они были, удалены.',
  ),
  'tr': (
    'bu güncellemeden önce oluşturulan çevreler',
    "Haven'ın yeni şifreleme motoruna geçmek için varsa tüm "
        'çevreleriniz kaldırıldı.',
  ),
  'ur': (
    'اس اپ ڈیٹ سے پہلے بنائے گئے حلقے',
    'Haven کے نئے خفیہ کاری کے نظام پر منتقل ہونے کے لیے آپ کے تمام '
        'حلقے، اگر کوئی تھے، ہٹا دیے گئے۔',
  ),
};

/// Per locale: the "by then" clause scoping the unsaved profile change
/// (lower-cased). Its frozen anti-vacuity copy is the round-five nicknames
/// sentence in [_nicknames], which lacked it.
const _profileScope = <String, String>{
  'en': 'not finished saving by then',
  'ar': 'حتى ذلك الحين',
  'de': 'bis dahin',
  'es': 'para entonces',
  'fa': 'تا آن زمان',
  'fr': 'à ce moment-là',
  'hi': 'तब तक',
  'ja': 'その時点で',
  'ne': 'त्यतिबेलासम्म',
  'pt': 'até então',
  'ru': 'к тому моменту',
  'tr': 'o zamana kadar',
  'ur': 'اس وقت تک',
};

void main() {
  test('every supported locale has vocabulary', () {
    final codes =
        AppLocalizations.supportedLocales.map((l) => l.languageCode).toSet();
    expect(codes, _copy.keys.toSet());
    expect(codes, _nicknames.keys.toSet());
    expect(codes, _relayReset.keys.toSet());
    expect(codes, _circlesScope.keys.toSet());
    expect(codes, _profileScope.keys.toSet());
  });

  for (final locale in AppLocalizations.supportedLocales) {
    final code = locale.languageCode;
    test("$code: the blanket phrase is one this locale's old copy said", () {
      final copy = _copy[code]!;
      expect(
        copy.blanket.allMatches(copy.claimedNothing.toLowerCase()),
        isNotEmpty,
        reason: '$code: anti-vacuity, against a frozen fixture',
      );
    });

    test('$code: the reset and circles scopes are ones old copy lacked', () {
      final scopes = [_relayReset[code]!, _circlesScope[code]!];
      for (final (clause, frozen) in scopes) {
        expect(
          frozen.toLowerCase(),
          isNot(contains(clause)),
          reason: '$code: anti-vacuity — the old sentence fails the check',
        );
      }
    });

    test('$code: the nicknames scope is one the old sentence lacked', () {
      final (word, scoped, unscoped) = _nicknames[code]!;
      final frozen = unscoped.toLowerCase();
      expect(
        frozen,
        isNot(contains(_profileScope[code])),
        reason: '$code: anti-vacuity — the unscoped profile clause fails',
      );
      expect(frozen, contains(word), reason: '$code: the same nicknames');
      expect(
        frozen,
        isNot(contains(scoped)),
        reason: '$code: anti-vacuity — the unscoped sentence fails the check',
      );
    });

    test('$code: says exactly what is held back and removed', () async {
      final l = await AppLocalizations.delegate.load(locale);
      final copy = _copy[code]!;
      final failed = l.storageResetAcknowledgeFailed.toLowerCase();
      final relays = l.storageResetRelays.toLowerCase();
      final lost = l.storageResetLost.toLowerCase();

      for (final (name, text) in [('notice', relays), ('snackbar', failed)]) {
        expect(text, contains(copy.relay), reason: '$code $name: relay word');
      }
      expect(
        failed,
        contains(copy.invitationKey),
        reason: '$code: the invitation key is the other thing held back',
      );
      for (final (name, text) in [
        ('storageResetRelays', relays),
        ('storageResetAcknowledgeFailed', failed),
        ('storageResetLost', lost),
      ]) {
        expect(
          copy.blanket.allMatches(text),
          isEmpty,
          reason: '$code $name: the profile, invitations and locations still '
              'go out',
        );
      }
      expect(
        relays,
        contains(_relayReset[code]!.$1),
        reason: '$code: the reset is an event of this update — relays the '
            'user added since are not "back to defaults"',
      );
      expect(
        lost,
        contains(_circlesScope[code]!.$1),
        reason: '$code: circles made after the update were never removed',
      );
      expect(
        lost,
        contains(_nicknames[code]!.$2),
        reason: '$code: nicknames given after the update were never removed',
      );
      expect(
        lost,
        contains(_profileScope[code]),
        reason: '$code: profile edits made after the update were never '
            'removed',
      );
    });
  }
}
