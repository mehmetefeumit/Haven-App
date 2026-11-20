// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Urdu (`ur`).
class AppLocalizationsUr extends AppLocalizations {
  AppLocalizationsUr([String locale = 'ur']) : super(locale);

  @override
  String get appearanceTitle => 'ظاہری شکل';

  @override
  String get appearanceThemeHeader => 'تھیم';

  @override
  String get appearanceThemeSystem => 'سسٹم کا طے شدہ';

  @override
  String get appearanceThemeSystemSubtitle => 'اپنے آلے کی ترتیبات کے مطابق';

  @override
  String get appearanceThemeLight => 'روشن';

  @override
  String get appearanceThemeLightSubtitle => 'ہمیشہ روشن تھیم استعمال کریں';

  @override
  String get appearanceThemeDark => 'تاریک';

  @override
  String get appearanceThemeDarkSubtitle => 'ہمیشہ تاریک تھیم استعمال کریں';

  @override
  String get appearanceLanguageTitle => 'زبان';

  @override
  String get languageSystemDefault => 'سسٹم کا طے شدہ';

  @override
  String get commonTryAgain => 'دوبارہ کوشش کریں';

  @override
  String get commonDismiss => 'بند کریں';

  @override
  String get commonSettings => 'ترتیبات';

  @override
  String get commonInvitations => 'دعوت نامے';

  @override
  String commonPendingInvitations(int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$countString زیر التوا دعوت نامے',
      one: '1 زیر التوا دعوت نامہ',
    );
    return '$_temp0';
  }

  @override
  String get commonBack => 'واپس';

  @override
  String get commonContinue => 'جاری رکھیں';

  @override
  String get commonSkip => 'چھوڑ دیں';

  @override
  String get commonRetry => 'دوبارہ کوشش کریں';

  @override
  String onboardingStepOf(int current, int total) {
    final intl.NumberFormat currentNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String currentString = currentNumberFormat.format(current);
    final intl.NumberFormat totalNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String totalString = totalNumberFormat.format(total);

    return 'مرحلہ $currentString از $totalString';
  }

  @override
  String get onboardingAppName => 'Haven';

  @override
  String get onboardingWelcomeHeadline =>
      'نجی اور سنسرشپ سے محفوظ مقام شیئرنگ۔';

  @override
  String get onboardingWelcomeCta => 'شروع کریں';

  @override
  String get onboardingValueProp1Title =>
      'آپ کو صرف آپ کے حلقے ہی دیکھ سکتے ہیں';

  @override
  String get onboardingValueProp2Title => 'اسے کوئی بند نہیں کر سکتا';

  @override
  String get onboardingValueProp3Title => 'کسی اکاؤنٹ کی ضرورت نہیں';

  @override
  String get onboardingValueProp1Summary =>
      'آپ کے آلے پر خفیہ کردہ، تاکہ صرف آپ کے منتخب کردہ حلقے ہی اسے پڑھ سکیں۔ اسے آگے پہنچانے والے ریلے بھی اسے نہیں پڑھ سکتے۔';

  @override
  String get onboardingValueProp2Summary =>
      'کوئی مرکزی سرور نہیں۔ یہ آزاد ریلے پر چلتا ہے۔ بہت سے لوگ انہیں چلاتے ہیں، اس لیے کوئی ایک کمپنی اسے بند نہیں کر سکتی۔';

  @override
  String get onboardingValueProp3Summary =>
      'نہ ای میل، نہ فون، نہ سائن اپ۔ آپ کی خفیہ کلید کبھی آپ کے فون سے باہر نہیں جاتی۔ Haven کا چنا ہوا گمنام نام رکھیں، یا اپنا خود چنیں۔';

  @override
  String get onboardingCreateIdentityTitle => 'اپنی شناخت بنائیں';

  @override
  String get onboardingCreateIdentityCta => 'میری شناخت بنائیں';

  @override
  String get onboardingCreateIdentityLoading => 'تیاری ہو رہی ہے…';

  @override
  String get onboardingFinishingSetup => 'سیٹ اپ مکمل ہو رہا ہے…';

  @override
  String get onboardingFinishSetupError =>
      'آپ کے اکاؤنٹ کا سیٹ اپ مکمل نہ ہو سکا۔ اپنا کنکشن جانچیں اور دوبارہ کوشش کریں۔';

  @override
  String get onboardingCreateIdentityImportPrompt => 'پہلے سے کلید موجود ہے؟';

  @override
  String get onboardingCreateIdentityImportLink => 'اس کے بجائے اسے درآمد کریں';

  @override
  String get onboardingCreateIdentityError =>
      'آپ کی شناخت بناتے ہوئے کچھ غلط ہو گیا۔ براہِ کرم دوبارہ کوشش کریں۔';

  @override
  String get onboardingImportTitle => 'اپنی موجودہ کلید درآمد کریں';

  @override
  String get onboardingImportBody =>
      'وہ خفیہ کلید چسپاں کریں جس کا بیک اپ آپ نے Haven کے ساتھ مطابقت رکھنے والی کسی دوسری ایپ سے لیا تھا۔';

  @override
  String get onboardingImportHint => 'nsec1…';

  @override
  String get onboardingImportCta => 'درآمد کریں';

  @override
  String get onboardingImportLoading => 'درآمد ہو رہی ہے…';

  @override
  String get onboardingImportInvalid =>
      'یہ کوئی درست خفیہ کلید معلوم نہیں ہوتی۔ براہِ کرم جانچ کر دوبارہ کوشش کریں۔';

  @override
  String get onboardingImportError =>
      'ہم وہ کلید درآمد نہ کر سکے۔ براہِ کرم جانچ کر دوبارہ کوشش کریں۔';

  @override
  String get onboardingDisplayNameHint => 'مثلاً علی';

  @override
  String get onboardingDisplayNameError =>
      'وہ نام محفوظ نہ ہو سکا۔ براہِ کرم دوبارہ کوشش کریں۔';

  @override
  String get onboardingPhotoNotSaved =>
      'آپ کی تصویر محفوظ نہیں ہو سکی۔ اسے بعد میں ترتیبات میں، شناخت کے تحت، شامل کیا جا سکتا ہے۔';

  @override
  String get onboardingAddPhotoOptional => 'تصویر شامل کریں (اختیاری)';

  @override
  String get commonCancel => 'منسوخ کریں';

  @override
  String get commonOpenSettings => 'ترتیبات کھولیں';

  @override
  String get settingsTitle => 'ترتیبات';

  @override
  String get settingsIdentityTitle => 'شناخت';

  @override
  String get settingsRelaysTitle => 'ریلے';

  @override
  String get settingsLocationTitle => 'مقام';

  @override
  String get settingsLocationSubtitleOn => 'پس منظر میں شیئرنگ فعال ہے';

  @override
  String get settingsLocationSubtitleOff => 'صرف جب تک Haven کھلا ہے';

  @override
  String get settingsMapStyleTitle => 'نقشے کا انداز';

  @override
  String get settingsAboutTitle => 'تعارف';

  @override
  String get settingsDebugOverlayTitle => 'ڈیبگ لاگ اوورلے';

  @override
  String get settingsDebugOverlaySubtitle => 'اسکرین پر لاگ آؤٹ پٹ دکھائیں';

  @override
  String get relaySettingsTitle => 'ریلے';

  @override
  String get relaySettingsNoIdentityTitle => 'کوئی شناخت نہیں';

  @override
  String get relaySettingsNoIdentityMessage =>
      'ریلے کا انتظام کرنے کے لیے پہلے ایک شناخت بنائیں۔';

  @override
  String get relaySettingsLoadIdentityError => 'شناخت لوڈ نہ ہو سکی۔';

  @override
  String get relaySettingsInboxTitle => 'میرے اِن باکس ریلے';

  @override
  String get relaySettingsKeyPackageTitle => 'میرے KeyPackage ریلے';

  @override
  String get relaySettingsProfileTitle => 'میرے پروفائل ریلے';

  @override
  String get relaySettingsProfileUnderflowTitle =>
      'پروفائل کی تلاش رُکی ہوئی ہے';

  @override
  String get relaySettingsProfileUnderflowMessage =>
      'پروفائل ریلے بہت کم رہ گئے ہیں، اس لیے ارکان کے نام اور تصاویر اب اپ ڈیٹ نہیں ہوں گے۔';

  @override
  String get relaySettingsProfileUnderflowRestoreButton =>
      'طے شدہ پروفائل ریلے بحال کریں';

  @override
  String get relaySettingsLoadRelaysError => 'ریلے لوڈ نہ ہو سکے۔';

  @override
  String get relaySettingsAddRelay => 'ریلے شامل کریں';

  @override
  String get relaySettingsRestoreDefaults => 'طے شدہ بحال کریں';

  @override
  String get relaySettingsAddRelayError => 'ریلے شامل نہ ہو سکا۔';

  @override
  String get relaySettingsRemoveRelayError => 'ریلے ہٹایا نہ جا سکا۔';

  @override
  String get relaySettingsRestoreTitle => 'طے شدہ ریلے بحال کریں؟';

  @override
  String relaySettingsRestoreBody(int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other:
          'آپ کے موجودہ $countString ریلے Haven کے طے شدہ ریلے سے بدل دیے جائیں گے۔ اسے واپس نہیں کیا جا سکتا۔',
      one:
          'آپ کا موجودہ 1 ریلے Haven کے طے شدہ ریلے سے بدل دیا جائے گا۔ اسے واپس نہیں کیا جا سکتا۔',
    );
    return '$_temp0';
  }

  @override
  String get relaySettingsRestoreConfirm => 'بحال کریں';

  @override
  String get relaySettingsRestoreSuccess => 'طے شدہ ریلے بحال کر دیے گئے۔';

  @override
  String get relaySettingsRestoreError => 'طے شدہ بحال نہ ہو سکے۔';

  @override
  String relaySettingsRemoveTooltip(String url) {
    return '$url ہٹائیں';
  }

  @override
  String get relaySettingsStatusChecking => 'جانچ ہو رہی ہے';

  @override
  String relaySettingsKindLine(String kind, String status) {
    return '$kind: $status';
  }

  @override
  String get relaySettingsKindKeyPackage => 'KeyPackage';

  @override
  String get relaySettingsKindRelayList => 'ریلے کی فہرست';

  @override
  String get relaySettingsKindInboxList => 'اِن باکس کی فہرست';

  @override
  String get relaySettingsPresencePublished => 'شائع شدہ';

  @override
  String get relaySettingsPresenceMissing => 'موجود نہیں';

  @override
  String get relaySettingsPresenceOutdated => 'پرانا ورژن';

  @override
  String get relaySettingsLookupTitle => 'تلاش کے ریلے';

  @override
  String get relaySettingsPublishingHeld =>
      'جب تک آپ ریلے کی ترتیبات والے نوٹس سے آگے نہ بڑھیں، Haven آپ کی ریلے کی ترتیبات یا دعوتی کلید شائع نہیں کرے گا';

  @override
  String get relaySettingsStatusNotChecked => 'جانچ نہیں ہوئی';

  @override
  String get relaySettingsPresencePublishing => 'اشاعت جاری ہے…';

  @override
  String get relaySettingsPresenceRefused => 'ریلے نے انکار کر دیا';

  @override
  String get relaySettingsPresenceUnconfirmed => 'ریلے نے تصدیق نہیں کی';

  @override
  String get relaySettingsPresenceNoAnswer => 'جانچ نہ ہو سکی';

  @override
  String get relaySettingsPresenceHeld => 'موقوف';

  @override
  String relaySettingsInfoTooltip(String section) {
    return '$section کے بارے میں';
  }

  @override
  String get relaySettingsInboxInfoWhat =>
      'جب کوئی آپ کو کسی حلقے میں مدعو کرے تو دعوت نامہ ان ریلے پر پہنچایا جاتا ہے۔ ریلے آزاد سرورز ہیں جو پیغامات آگے پہنچاتے ہیں۔ Haven نئے دعوت ناموں کے لیے انہیں جانچتا ہے۔';

  @override
  String get relaySettingsInboxInfoKeeps =>
      'Haven آپ کی اِن باکس کی فہرست یہاں رکھتا ہے۔ یہ ایک مختصر عوامی نوٹ ہے جو بتاتا ہے کہ کون سے ریلے آپ کا اِن باکس ہیں، تاکہ لوگوں کو معلوم ہو کہ دعوت نامے کہاں بھیجیں۔ اس کی ایک نقل اس صفحے پر نیچے دیے گئے تلاش کے ریلے کو بھی جاتی ہے۔ دعوت نامے اس طرح سربمہر کیے جاتے ہیں کہ صرف آپ ہی انہیں کھول سکیں۔';

  @override
  String get relaySettingsInboxInfoMissing =>
      'Haven استعمال کرنے والے لوگ آپ کی اِن باکس کی فہرست تلاش کے ریلے پر ڈھونڈتے ہیں، اور دوسری ایپس شاید اسے آپ کے اپنے ریلے پر ڈھونڈیں، اس لیے Haven دونوں جگہ اس کی نقل رکھتا ہے۔ ہر قطار بتاتی ہے کہ آیا اس ریلے کے پاس موجودہ ورژن ہے۔';

  @override
  String get relaySettingsInboxInfoActions =>
      'یہاں اپنے بھروسے کے ریلے شامل کیے جا سکتے ہیں، اور جن کی اب ضرورت نہ ہو انہیں ہٹایا جا سکتا ہے۔ Haven اس فہرست کا آخری ریلے ہٹانے نہیں دے گا۔ اس فہرست کا ہر ریلے عوامی ہے: کوئی بھی اسے آپ کی اِن باکس کی فہرست میں دیکھ سکتا ہے۔ جب آپ کوئی ریلے ہٹائیں تو Haven اس سے آپ کی پرانی فہرست حذف کرنے کی درخواست کرتا ہے۔';

  @override
  String get relaySettingsInboxInfoTechnical =>
      'تکنیکی تفصیل میں دلچسپی ہو تو: آپ کی اِن باکس کی فہرست kind 10050 کا ایک Nostr ایونٹ ہے، اور دعوت نامے kind 1059 کے گفٹ ریپ شدہ ایونٹس کی صورت میں آتے ہیں۔';

  @override
  String get relaySettingsKeyPackageInfoWhat =>
      'آپ کو کسی حلقے میں شامل کرنے کے لیے مدعو کرنے والے شخص کو آپ کی دعوتی کلید درکار ہوتی ہے، جسے KeyPackage کہتے ہیں۔ Haven اسے ان ریلے پر رکھتا ہے تاکہ آپ کا فون بند ہونے پر بھی لوگ آپ کو مدعو کر سکیں۔';

  @override
  String get relaySettingsKeyPackageInfoKeeps =>
      'Haven یہاں دو چیزیں رکھتا ہے: آپ کا KeyPackage، اور آپ کی ریلے کی فہرست، یعنی ایک مختصر عوامی نوٹ جو بتاتا ہے کہ آپ کا KeyPackage کن ریلے پر ہے۔ ریلے کی فہرست کی ایک نقل تلاش کے ریلے کو بھی جاتی ہے۔ آپ کا KeyPackage صرف اسی فہرست کے ریلے کو جاتا ہے۔ استعمال ہو جانے کے بعد Haven اسے نئے KeyPackage سے بدل دیتا ہے، اور وقتاً فوقتاً اس کی تجدید بھی کرتا ہے۔';

  @override
  String get relaySettingsKeyPackageInfoMissing =>
      'ہر قطار بتاتی ہے کہ آیا اس ریلے کے پاس آپ کا موجودہ KeyPackage اور ریلے کی فہرست ہے۔ اگر کسی ریلے پر آپ کا KeyPackage موجود نہ ہو، یا اس پر کوئی پرانا KeyPackage ہو جسے Haven بدل چکا ہے، تو جو لوگ اسے وہاں ڈھونڈیں وہ شاید آپ کو مدعو نہ کر سکیں۔';

  @override
  String get relaySettingsKeyPackageInfoActions =>
      'یہاں ریلے شامل کیے یا ہٹائے جا سکتے ہیں۔ Haven اس فہرست کا آخری ریلے ہٹانے نہیں دے گا۔ اس فہرست کا ہر ریلے عوامی ہے: کوئی بھی اسے آپ کی ریلے کی فہرست میں دیکھ سکتا ہے۔ جب آپ کوئی ریلے ہٹائیں تو Haven اس سے آپ کی پرانی ریلے کی فہرست حذف کرنے کی درخواست کرتا ہے۔';

  @override
  String get relaySettingsKeyPackageInfoTechnical =>
      'تکنیکی تفصیل میں دلچسپی ہو تو: KeyPackage، kind 30443 کا ایک Marmot ایونٹ ہے، اور ریلے کی فہرست kind 10002 کا ایک NIP-65 ایونٹ ہے۔';

  @override
  String get relaySettingsProfileInfoWhat =>
      'جب آپ کوئی نام یا تصویر محفوظ کریں تو Haven آپ کا عوامی پروفائل ان ریلے کو بھیجتا ہے۔ Haven دوسرے ارکان کے نام اور تصاویر بھی یہیں تلاش کرتا ہے۔';

  @override
  String get relaySettingsProfileInfoKeeps =>
      'کوئی بھی ان ریلے پر آپ کا پروفائل تلاش کر سکتا ہے۔ آپ کی تصویر خود ایک الگ تصویری سرور پر محفوظ ہوتی ہے، اور آپ کے پروفائل میں اس کا ویب پتہ ہوتا ہے۔';

  @override
  String get relaySettingsProfileInfoPrivacy =>
      'Haven آپ کا پروفائل صرف انہی ریلے کو بھیجتا ہے، اور انہیں اُن ریلے سے الگ رکھتا ہے جو آپ کے دعوت نامے لے جاتے ہیں۔ چونکہ آپ کا پروفائل عوامی ہے، اس لیے دوسری ایپس اسے کہیں اور بھی نقل کر سکتی ہیں۔ Haven یہ فہرست آپ کے فون پر رکھتا ہے اور اسے کبھی شائع نہیں کرتا۔ یہاں جو ریلے آپ کا دوسرا Haven ٹریفک بھی لے جاتا ہو، اس پر تنبیہ کا نشان لگا ہوتا ہے۔';

  @override
  String get relaySettingsProfileInfoActions =>
      'یہاں ریلے شامل کیے جا سکتے ہیں۔ Haven میں پہلے سے شامل پروفائل ریلے ہٹائے نہیں جا سکتے، کیونکہ Haven انہیں ہمیشہ واپس شامل کر دیتا ہے۔ یہ حصہ کسی ریلے کے لیے کوئی نشان نہیں دکھاتا؛ آپ کا محفوظ کیا ہوا پروفائل آپ کے شناخت کے صفحے پر نظر آتا ہے۔';

  @override
  String get relaySettingsProfileInfoTechnical =>
      'تکنیکی تفصیل میں دلچسپی ہو تو: آپ کا پروفائل kind 0 کا ایک Nostr ایونٹ ہے، اور تصویر ایک Blossom سرور پر محفوظ ہوتی ہے۔';

  @override
  String get relaySettingsLookupInfoWhat =>
      'تلاش کے ریلے معروف عوامی ریلے ہیں جہاں ایپس کسی شخص کے ریلے ڈھونڈتی ہیں جب انہیں صرف اس شخص کا اکاؤنٹ معلوم ہو۔ انہیں Haven نے چنا ہے، اور یہ Haven استعمال کرنے والے ہر فرد کے لیے ایک جیسے ہیں۔ Haven ان کی مدد سے ان لوگوں کو بھی ڈھونڈتا ہے جنہیں آپ مدعو کریں۔';

  @override
  String get relaySettingsLookupInfoKeeps =>
      'تاکہ جو شخص صرف آپ کا اکاؤنٹ جانتا ہو وہ بھی آپ کو مدعو کر سکے، Haven آپ کی اِن باکس کی فہرست اور ریلے کی فہرست بغیر کسی تبدیلی کے یہاں نقل کرتا ہے۔ اگر ان فہرستوں میں کسی نجی ریلے کا نام ہو تو وہ نام یہاں بھی نظر آتا ہے۔ اس کردار میں Haven یہاں صرف یہی دو فہرستیں نقل کرتا ہے۔ تلاش کے کچھ ریلے Haven کے طے شدہ اِن باکس اور KeyPackage ریلے بھی ہیں؛ جب تک وہ آپ کی فہرستوں میں ہوں، ان پر وہ سب کچھ بھی ہوتا ہے جو ان حصوں میں بیان کیا گیا ہے۔';

  @override
  String get relaySettingsLookupInfoMissing =>
      'ہر قطار بتاتی ہے کہ آیا اس ریلے کے پاس دونوں فہرستوں کا موجودہ ورژن ہے۔ اگر تلاش کے کسی ریلے پر یہ فہرستیں موجود نہ ہوں یا ان کے پرانے ورژن ہوں، تو وہاں تلاش کرنے والے لوگ شاید آپ کو نہ ڈھونڈ سکیں۔ ایک ریلے ایک سے زیادہ حصوں میں نظر آ سکتا ہے؛ ہر حصہ صرف وہی دکھاتا ہے جو اس کردار کے لیے ضروری ہے۔';

  @override
  String get relaySettingsLookupInfoActions =>
      'یہ فہرست Haven میں پہلے سے شامل ہے، اس لیے اسے یہاں بدلا نہیں جا سکتا۔ اوپر والی اِن باکس اور KeyPackage فہرستیں آپ کے اختیار میں ہیں۔';

  @override
  String get relaySettingsLookupInfoTechnical =>
      'تکنیکی تفصیل میں دلچسپی ہو تو: Haven آپ کے kind 10050 اور kind 10002 ایونٹس ان ریلے پر نقل کرتا ہے؛ kind 30443 صرف آپ کے KeyPackage ریلے کو جاتا ہے۔';

  @override
  String get relaySettingsLegendTitle => 'نشانات کا مطلب';

  @override
  String get relaySettingsLegendCurrent =>
      'شائع شدہ: اس ریلے کے پاس موجودہ ورژن ہے۔';

  @override
  String get relaySettingsLegendPublishing =>
      'اشاعت جاری ہے: Haven نے اسے بھیج دیا ہے اور ریلے کی تصدیق کا انتظار کر رہا ہے۔';

  @override
  String get relaySettingsLegendChecking =>
      'جانچ ہو رہی ہے، یا ابھی جانچ نہیں ہوئی: Haven ریلے سے پوچھ رہا ہے کہ اس کے پاس کیا ہے، یا ابھی تک اس نے پوچھا نہیں۔';

  @override
  String get relaySettingsLegendNotOnRelay =>
      'ابھی اس ریلے پر نہیں: یا تو یہ موجود نہیں، یا پرانا ورژن ہے، یا ریلے نے انکار کر دیا، یا ریلے نے تصدیق نہیں کی۔ کون سی بات ہے، یہ جاننے کے لیے نشان پر تھپتھپائیں۔ Haven اپنی اگلی جانچ پر دوبارہ کوشش کرتا ہے: جب تک Haven کھلا ہو، تقریباً ہر 10 منٹ بعد آپ کے KeyPackage کے لیے اور ہر 30 منٹ بعد آپ کی فہرستوں کے لیے، اور ہر بار جب Haven شروع ہو۔ اگر آپ کا کوئی ریلے بار بار یہی دکھائے تو اسے کسی دوسرے ریلے سے بدلا جا سکتا ہے۔';

  @override
  String get relaySettingsLegendNoAnswer =>
      'جانچ نہ ہو سکی: ریلے نے جواب نہیں دیا، شاید اس لیے کہ آپ آف لائن ہیں یا ریلے بند ہے۔ Haven اپنی اگلی جانچ پر دوبارہ پوچھتا ہے۔';

  @override
  String get relaySettingsLegendHeld =>
      'موقوف: Haven فی الحال اسے شائع نہیں کر رہا۔ اس صفحے پر ایک نوٹ اس کی وجہ بتاتا ہے۔';

  @override
  String get relaySettingsHeldNoRelays =>
      'اوپر جس فہرست میں بھی کوئی ریلے نہیں، Haven کے پاس اسے شائع کرنے کی کوئی جگہ نہیں۔ اسے دوبارہ شائع کرنے کے لیے ہر خالی فہرست میں طے شدہ بحال کریں۔';

  @override
  String get relaySettingsHeldNotYetPublished =>
      'Haven نے ابھی تک آپ کی ریلے فہرستوں میں سے ایک شائع نہیں کی۔ یہ کام وہ اپنی اگلی جانچ پر کرتا ہے۔';

  @override
  String relaySettingsCheckSettled(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other:
          'ریلے کی جانچ مکمل ہو گئی۔ $count ریلے کے تازہ ترین ہونے کی تصدیق نہیں ہوئی۔',
      one:
          'ریلے کی جانچ مکمل ہو گئی۔ 1 ریلے کے تازہ ترین ہونے کی تصدیق نہیں ہوئی۔',
      zero: 'ریلے کی جانچ مکمل ہو گئی۔ سب کچھ تازہ ترین ہے۔',
    );
    return '$_temp0';
  }

  @override
  String relaySettingsAddedRelayUpToDate(String relay) {
    return '$relay تازہ ترین ہے۔';
  }

  @override
  String relaySettingsAddedRelayNotUpToDate(String relay) {
    return '$relay کے تازہ ترین ہونے کی تصدیق نہیں ہوئی۔ اس کی قطار میں وجہ درج ہے۔';
  }

  @override
  String get relaySettingsEmptyTitle => 'کوئی ریلے مرتب نہیں';

  @override
  String get relaySettingsEmptyMessage =>
      'آپ کو کم از کم ایک ریلے درکار ہے تاکہ دوسرے آپ تک پہنچ سکیں۔ Haven کے طے شدہ ریلے بحال کرنے کے لیے نیچے تھپتھپائیں۔';

  @override
  String get relaySettingsProfileContaminationTooltip =>
      'Haven کا دوسرا ٹریفک بھی لے جاتا ہے';

  @override
  String relaySettingsProfileContaminationSemantics(String url) {
    return 'تنبیہ: $url آپ کا دوسرا Haven ٹریفک بھی لے جاتا ہے، اس لیے یہ ریلے آپ کے پروفائل کو اُس ٹریفک سے جوڑ سکتا ہے';
  }

  @override
  String get relaySettingsInboxRefused =>
      'اس ریلے نے Haven کو آپ کے دعوت نامے پڑھنے کی اجازت نہیں دی۔ اسے ہٹا دیں، یا کوئی اور ریلے شامل کریں۔';

  @override
  String get relaySettingsInboxRefusedTooltip =>
      'Haven کو دعوت نامے پڑھنے کی اجازت نہیں دی';

  @override
  String relaySettingsInboxRefusedSemantics(String url) {
    return 'تنبیہ: $url نے Haven کو آپ کے دعوت نامے پڑھنے کی اجازت نہیں دی';
  }

  @override
  String get relaySettingsInboxAllRefusedTitle =>
      'آپ کے کسی بھی اِن باکس ریلے نے Haven کو دعوت نامے پڑھنے کی اجازت نہیں دی';

  @override
  String get relaySettingsInboxAllRefusedMessage =>
      'آپ کو بھیجے گئے دعوت نامے تب تک آپ تک نہیں پہنچیں گے جب تک آپ کا کوئی اِن باکس ریلے Haven کو انہیں پڑھنے کی اجازت نہ دے۔ طے شدہ ریلے بحال کریں، یا کوئی اور ریلے شامل کریں۔';

  @override
  String get locationSettingsTitle => 'مقام';

  @override
  String get locationSettingsDisabledSnack => 'پس منظر میں شیئرنگ غیر فعال';

  @override
  String get locationSettingsEnabledSnack => 'پس منظر میں شیئرنگ فعال';

  @override
  String get locationSettingsNotificationDeniedSnack =>
      'پس منظر میں شیئرنگ کے لیے ایک اطلاع درکار ہے تاکہ Android اسے چلتا رکھے۔ فی الحال یہ بند ہے۔ اسے آن کرنے کے لیے Haven کے لیے اطلاعات فعال کریں۔';

  @override
  String get locationSettingsBatteryOptSnack =>
      'آن۔ بیٹری بہتری کچھ فونز پر شیئرنگ روک سکتی ہے۔ اسے بھروسے مند رکھنے کے لیے Haven کو بیٹری بہتری سے مستثنیٰ کریں۔';

  @override
  String get locationSettingsBatteryOptNote =>
      'Haven کے لیے بیٹری بہتری اب بھی آن ہے۔ کچھ فونز اسی کے ذریعے پس منظر میں شیئرنگ کو بغیر بتائے روک دیتے ہیں۔ شیئرنگ کو بھروسے مند رکھنے کے لیے Haven کو اس سے مستثنیٰ کریں۔';

  @override
  String get locationSettingsErrorSnack => 'کچھ غلط ہو گیا';

  @override
  String get locationSettingsIntro =>
      'جب بھی ایپ کھلی ہو، Haven آپ کا مقام آپ کے حلقوں کے ساتھ شیئر کرتا ہے۔ اسے آن کریں تو Haven کے پس منظر میں ہوتے ہوئے بھی آپ کے حلقے اسے دیکھتے رہیں گے۔ اگر سسٹم نے Haven کو بند کر دیا تو آپ کی اپنی شیئرنگ رک جاتی ہے: Haven پھر بھی آپ کے حلقوں کے مقامات لانے کے لیے جاگ سکتا ہے، مگر آپ کا اپنا مقام بھیجنے کے لیے کبھی نہیں۔ Android پر شیئرنگ Haven کو ایپ سوئچر سے ہٹا دینے کے بعد بھی جاری رہتی ہے اور فون دوبارہ چالو ہونے پر خود ہی پھر شروع ہو جاتی ہے۔ iPhone پر شیئرنگ اُس وقت تک رکی رہتی ہے جب تک آپ Haven نہ کھولیں۔';

  @override
  String get locationSettingsToggleTitle => 'پس منظر میں شیئر کریں';

  @override
  String get locationSettingsToggleSubtitle =>
      'Haven کے پس منظر میں چلتے ہوئے بھی شیئر کرتے رہیں';

  @override
  String get locationSettingsIosLimitedNote =>
      'آپ کی موجودہ اجازت کے ساتھ شیئرنگ پس منظر میں کام کرتی رہتی ہے، اور اس دوران iOS آپ کی اسکرین کے اوپری حصے میں اپنی نیلی مقام پٹی دکھاتا ہے۔ ترتیبات میں Haven کے لیے \'Always\' منتخب کریں تاکہ iOS کے ایپ بند کر دینے کے بعد Haven آپ کے حلقوں کے مقامات کی تازہ صورت حال بھی حاصل کر سکے۔ \'Always\' کے تحت iOS خود اُس پٹی کے بجائے اسٹیٹس بار میں مقام کا تیر دکھا سکتا ہے۔ آپ کی اپنی شیئرنگ تو Haven دوبارہ کھولنے پر ہی بحال ہوتی ہے۔';

  @override
  String get locationSettingsAndroidHeader => 'بھروسے کے لیے OS ترتیبات';

  @override
  String get locationSettingsAndroidNotification =>
      'Haven کو ایک مستقل اطلاع درکار ہے تاکہ Android پس منظر کی سروس کو زندہ رکھے۔ اگر آپ نے اطلاع کی اجازت سے انکار کیا تھا تو ترتیبات کھولیں اور Haven کے لیے اطلاعات کی اجازت دیں۔';

  @override
  String get locationSettingsAndroidBattery =>
      'بھروسے مند پس منظر شیئرنگ کے لیے Haven کو بیٹری بہتری سے بھی مستثنیٰ کریں۔ Settings → Apps → Haven → Battery → Allow all the time پر جائیں۔';

  @override
  String get locationSettingsAndroidVendors =>
      'Samsung آلات پر، Haven کو \"Sleeping apps\" سے ہٹائیں (Device care → Battery → Background usage limits)۔ Xiaomi پر، Haven کے لیے Autostart فعال کریں۔';

  @override
  String get locationSettingsIosGuidance =>
      'جب پس منظر میں شیئرنگ آن ہو تو Haven مقام کا سیشن جاری رکھتا ہے تاکہ آپ کے حلقے آپ کو دیکھتے رہیں۔';

  @override
  String get locationSettingsIosIndicatorArrow =>
      'جب تک Haven آپ کا مقام استعمال کرتا ہے، iOS خود اسٹیٹس بار میں مقام کا تیر دکھاتا ہے، اور اس کے بعد کچھ دیر تک وہی تیر \'لوکیشن کی خدمات\' میں Haven کے ساتھ نظر آتا رہتا ہے۔';

  @override
  String get locationSettingsIosIndicatorBar =>
      'آپ کی \'Always\' اجازت کے ساتھ، جب تک Haven آپ کا مقام استعمال کرتا ہے، iOS اپنی نیلی مقام پٹی اسکرین کے اوپری حصے میں دکھاتا ہے۔';

  @override
  String get locationDisclosureTitle => 'آپ کے مقام کی شیئرنگ';

  @override
  String get locationDisclosureWhy =>
      'Haven آپ کا لمحہ بہ لمحہ مقام اُن حلقوں کے لوگوں کو دکھاتا ہے جو آپ منتخب کرتے ہیں، اور اُن کا مقام آپ کو نقشے پر دکھاتا ہے۔ اس کے لیے Haven کو آپ کے آلے کا درست مقام استعمال کرنے کی اجازت درکار ہے۔';

  @override
  String get locationDisclosureHow =>
      'آپ کا مقام آپ کے آلے پر ہی اینڈ ٹو اینڈ خفیہ کر دیا جاتا ہے، اس لیے اسے صرف اُن حلقوں کے ارکان پڑھ سکتے ہیں جو آپ منتخب کرتے ہیں، خود Haven نہیں۔ Haven کا اپنا کوئی سرور نہیں: آپ کا خفیہ کردہ مقام ہر بار اُن آزاد ریلے سے گزرتا ہے جنہیں دوسرے لوگ چلاتے ہیں، اور یہ ریلے آپ کا نیٹ ورک پتہ تو دیکھتے ہیں مگر یہ کبھی نہیں دیکھتے کہ آپ کہاں ہیں۔ نقشہ بنانے کے لیے آپ کے اور آپ کے حلقے کے گرد کے علاقے Stadia Maps سے منگوائے جاتے ہیں، اس لیے Stadia Maps کو موٹے طور پر پتہ چل جاتا ہے کہ وہ علاقے کہاں ہیں، مگر آپ کا نام، آپ کی کلید یا آپ کے حلقوں میں کون ہے — یہ اسے کبھی معلوم نہیں ہوتا۔ Stadia Maps کا کہنا ہے کہ وہ ذاتی معلومات نہ بیچتی ہے نہ ان کا تبادلہ کرتی ہے، آپ کے آلے پر کوئی کوکی نہیں رکھتی، اور اپنے سرور کے لاگ تقریباً دو ہفتے محفوظ رکھتی ہے — یہ اُن کی اپنی پالیسی ہے، جسے Haven نافذ نہیں کر سکتا۔';

  @override
  String get locationDisclosureSharing =>
      'جب تک Haven کھلا ہے اور آپ کسی حلقے میں ہیں، آپ کا مقام ہر چند منٹ بعد خود بخود بھیج دیا جاتا ہے۔ اسے وقفے پر رکھنے کا کوئی طریقہ نہیں۔ کسی حلقے کے ساتھ شیئرنگ روکنے کے لیے وہ حلقہ چھوڑ دیں۔';

  @override
  String get locationDisclosureBackgroundAndroid =>
      'یہ ایپ مقام کا ڈیٹا استعمال کرتی ہے تاکہ آپ کے حلقوں کے ساتھ شیئرنگ ممکن ہو سکے، خواہ ایپ بند ہو یا زیرِ استعمال نہ ہو۔';

  @override
  String get locationDisclosureBackgroundIos =>
      'یہ ایپ مقام کا ڈیٹا استعمال کرتی ہے تاکہ Haven کے پس منظر میں ہوتے ہوئے اور آپ کے اسے استعمال نہ کرتے ہوئے بھی آپ کے حلقوں کے ساتھ شیئرنگ ممکن ہو سکے۔ اگر iOS نے Haven کو بند کر دیا تو آپ کی اپنی شیئرنگ اُس وقت تک رکی رہے گی جب تک آپ اسے دوبارہ نہ کھولیں: Haven پھر بھی آپ کے حلقوں کے مقامات لانے کے لیے جاگ سکتا ہے، مگر آپ کا اپنا مقام بھیجنے کے لیے کبھی نہیں۔';

  @override
  String get locationDisclosureManage =>
      'آپ پس منظر میں شیئرنگ کسی بھی وقت ترتیبات ← مقام سے بند کر سکتے ہیں۔';

  @override
  String get locationDisclosureAgree => 'متفق ہوں';

  @override
  String get locationDisclosureNotNow => 'ابھی نہیں';

  @override
  String get fgsNotificationSharing =>
      'Haven مقام کی معلومات بھیج اور وصول کر رہا ہے';

  @override
  String get fgsNotificationPaused =>
      'Haven رکا ہوا ہے — شیئرنگ بحال کرنے کے لیے ایپ کھولیں';

  @override
  String get fgsNotificationOpen => 'Haven استعمال میں ہے';

  @override
  String get fgsChannelName => 'مقام کی شیئرنگ';

  @override
  String get fgsChannelDescription =>
      'Haven کو پس منظر میں آپ کا خفیہ کردہ مقام شیئر کرتے رہنے دیتا ہے۔';

  @override
  String get mapStyleTitle => 'نقشے کا انداز';

  @override
  String get mapStyleMinimalTitle => 'سادہ';

  @override
  String get mapStyleMinimalSubtitle =>
      'پُرسکون، کم تفصیلی پس منظر جو آپ کے روشن یا تاریک تھیم کے مطابق چلتا ہے';

  @override
  String get mapStyleDetailedTitle => 'تفصیلی';

  @override
  String get mapStyleDetailedSubtitle => 'پوری رنگین سڑکیں، لیبل اور مقامات';

  @override
  String get mapStyleOutdoorsTitle => 'کھلی فضا';

  @override
  String get mapStyleOutdoorsSubtitle => 'راستوں اور پارکوں سمیت سایہ دار خطہ';

  @override
  String get mapStylePreviewHeader => 'پیش منظر';

  @override
  String get mapStylePreviewCity => 'شہر';

  @override
  String get mapStylePreviewNature => 'فطرت';

  @override
  String mapStylePreviewSemantics(String scene, String style) {
    return 'نقشے کا پیش منظر ($scene): $style';
  }

  @override
  String get aboutTitle => 'تعارف';

  @override
  String get aboutHeroName => 'Haven';

  @override
  String get aboutHeroTagline => 'نجی اور سنسرشپ سے محفوظ مقام شیئرنگ۔';

  @override
  String get aboutLicensesTitle => 'اوپن سورس لائسنس';

  @override
  String get aboutLicensesLegalese => '© 2026 Haven · MIT License';

  @override
  String get aboutReportMapIssue => 'نقشے کا کوئی مسئلہ رپورٹ کریں';

  @override
  String get aboutSupportOsm => 'OpenStreetMap کی معاونت کریں';

  @override
  String get aboutMapAttribution =>
      '© Stadia Maps · © OpenMapTiles · © OpenStreetMap contributors\nMap data licensed under ODbL';

  @override
  String get aboutLinkOpenError => 'لنک نہ کھل سکا';

  @override
  String get aboutFooterLicense => 'MIT License کے تحت لائسنس یافتہ';

  @override
  String aboutFooterVersion(String version) {
    return 'ورژن $version';
  }

  @override
  String get relaySettingsBackendCaption =>
      'Haven کا اپنا کوئی سرور نہیں۔ آپ کی خفیہ کردہ اپ ڈیٹس آزاد سرورز سے گزرتی ہیں جنہیں ریلے کہا جاتا ہے، اور یہ نہ آپ کا مقام پڑھ سکتے ہیں نہ آپ کے پیغامات۔';

  @override
  String get commonClearAll => 'سب صاف کریں';

  @override
  String commonMemberCount(int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$countString ارکان',
      one: '1 رکن',
    );
    return '$_temp0';
  }

  @override
  String commonNumber(int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    return '$countString';
  }

  @override
  String get circlesTitle => 'حلقے';

  @override
  String get circlesRefreshTooltip => 'حلقے تازہ کریں';

  @override
  String get circlesRequiresIdentity =>
      'حلقہ بنانے کے لیے پہلے شناخت مرتب کرنا ضروری ہے';

  @override
  String get circlesCreateCta => 'حلقہ بنائیں';

  @override
  String get circlesYourCircles => 'آپ کے حلقے';

  @override
  String get circlesEmptyTitle => 'ابھی کوئی حلقہ نہیں';

  @override
  String get circlesEmptyMessage =>
      'اپنے قابلِ اعتماد دوستوں اور خاندان کے ساتھ مقام شیئر کرنا شروع کرنے کے لیے ایک حلقہ بنائیں۔';

  @override
  String get circlesSheetEmptyMessage =>
      'اپنے قابلِ اعتماد رابطوں کے ساتھ مقام شیئر کرنا شروع کرنے کے لیے ایک حلقہ بنائیں۔';

  @override
  String get circlesLoadError => 'حلقے لوڈ نہ ہو سکے';

  @override
  String get circlesSelectToView => 'ارکان دیکھنے کے لیے کوئی حلقہ منتخب کریں';

  @override
  String get circlesNoMembers => 'اس حلقے میں کوئی رکن نہیں';

  @override
  String get createCircleTitle => 'ارکان شامل کریں';

  @override
  String createCircleSelectedCount(int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    return 'منتخب شدہ ($countString)';
  }

  @override
  String get createCircleEmptyTitle => 'حلقے کے ارکان شامل کریں';

  @override
  String get createCircleEmptyMessage =>
      'ارکان شامل کرنے کے لیے عوامی کلید سے تلاش کریں یا ان کا QR کوڈ اسکین کریں۔';

  @override
  String get createCircleNoValidMembers =>
      'دعوت دینے کے لیے کوئی درست رکن نہیں';

  @override
  String get createCircleNoIdInQr => 'QR کوڈ میں کوئی درست عوامی کلید نہیں ملی';

  @override
  String get memberLookupNotFound =>
      'اس عوامی کلید کا ابھی تک کوئی Haven اکاؤنٹ نہیں ملا۔ اگر انہوں نے ابھی ابھی Haven سیٹ اپ کیا ہے، تو ایک منٹ بعد دوبارہ کوشش کریں۔';

  @override
  String get memberLookupIncomplete =>
      'اس عوامی کلید کی جانچ مکمل نہ ہو سکی۔ اپنا کنکشن جانچیں اور دوبارہ کوشش کریں۔';

  @override
  String get createCircleSomethingWentWrong => 'کچھ غلط ہو گیا';

  @override
  String get nameCircleTitle => 'اپنے حلقے کا نام رکھیں';

  @override
  String nameCircleMembersToInvite(int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$countString ارکان کو دعوت دی جائیں گی',
      one: '1 رکن کو دعوت دی جائے گی',
    );
    return '$_temp0';
  }

  @override
  String get nameCircleNameLabel => 'حلقے کا نام';

  @override
  String get nameCircleNameHint => 'مثلاً خاندان، قریبی دوست';

  @override
  String get nameCircleNameEmptyError => 'براہِ کرم حلقے کا نام درج کریں';

  @override
  String get nameCircleNameTooLongError => 'نام 50 حروف یا اس سے کم ہونا چاہیے';

  @override
  String get nameCircleSharingInfo =>
      'اس حلقے میں شامل ہر شخص ایک دوسرے کا مقام، اور ایک دوسرے کا عوامی نام اور تصویر دیکھ سکتا ہے۔ آپ کا نام اور تصویر Nostr نیٹ ورک پر عوامی ہیں، اس حلقے تک محدود نہیں۔ یہ حلقہ آپ کے کسی بھی دوسرے حلقے سے الگ رہتا ہے، چنانچہ اس کے ارکان آپ کے دوسرے حلقے یا یہ نہیں دیکھ سکتے کہ ان میں کون ہے۔';

  @override
  String get nameCircleCreateCta => 'حلقہ بنائیں';

  @override
  String get nameCircleStageCreatingGroup => 'محفوظ گروہ بنایا جا رہا ہے...';

  @override
  String get nameCircleStageComplete => 'ہو گیا!';

  @override
  String nameCircleProgressSemantics(String stage) {
    return 'تخلیق کی پیش رفت: $stage';
  }

  @override
  String nameCirclePercentComplete(int percent) {
    final intl.NumberFormat percentNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String percentString = percentNumberFormat.format(percent);

    return '$percentString فیصد مکمل';
  }

  @override
  String nameCircleCreatedSentSoFarSnack(String name, int sent, int total) {
    final intl.NumberFormat sentNumberFormat = intl.NumberFormat.decimalPattern(
      localeName,
    );
    final String sentString = sentNumberFormat.format(sent);
    final intl.NumberFormat totalNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String totalString = totalNumberFormat.format(total);

    String _temp0 = intl.Intl.pluralLogic(
      total,
      locale: localeName,
      other:
          'حلقہ \"$name\" بن گیا۔ اب تک بھیجے گئے دعوت نامے: $totalString میں سے $sentString۔ جب تک ایپ کھلی ہو، Haven زیادہ سے زیادہ ایک دن تک باقی دعوت نامے بھیجتا رہتا ہے۔',
      one:
          'حلقہ \"$name\" بن گیا۔ اب تک بھیجا گیا دعوت نامہ: $totalString میں سے $sentString۔ جب تک ایپ کھلی ہو، Haven زیادہ سے زیادہ ایک دن تک اسے بھیجتا رہتا ہے۔',
    );
    return '$_temp0';
  }

  @override
  String nameCircleCreatedSnack(String name, int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'حلقہ \"$name\" بن گیا! $countString دعوت نامے بھیجے گئے۔',
      one: 'حلقہ \"$name\" بن گیا! 1 دعوت نامہ بھیجا گیا۔',
    );
    return '$_temp0';
  }

  @override
  String get nameCircleIdentityError =>
      'شناخت میں خرابی۔ براہِ کرم اپنی شناخت کی ترتیب جانچیں۔';

  @override
  String get nameCircleCreateError =>
      'حلقہ بنانے میں ناکامی۔ براہِ کرم دوبارہ کوشش کریں۔';

  @override
  String nameCircleRosterFullError(int limit) {
    final intl.NumberFormat limitNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String limitString = limitNumberFormat.format(limit);

    return 'آپ کے پاس بیک وقت زیادہ سے زیادہ $limitString حلقے ہو سکتے ہیں۔ نئے حلقے کی جگہ بنانے کے لیے کوئی حلقہ چھوڑ دیں۔';
  }

  @override
  String get circleCreateRefusedNoLocationRelay =>
      'Haven یہ حلقہ نہیں بنا سکتا۔ جو ریلے Haven حلقوں کے لیے استعمال کرتا ہے، وہ سب آپ کی اپنی ریلے فہرستوں میں شامل ہیں یا کبھی شامل رہے ہیں، اس لیے ان میں سے کوئی بھی اس حلقے کا ٹریفک نہیں لے جا سکتا۔';

  @override
  String addMemberTitle(String circleName) {
    return '$circleName میں شامل کریں';
  }

  @override
  String get addMemberInfo =>
      'دعوت قبول کرتے ہی وہ اُس وقت سے آگے سب کا مقام دیکھیں گے، اپنے شامل ہونے سے پہلے بھیجی گئی کوئی چیز کبھی نہیں۔ وہ اُن سب کی عوامی کلیدیں بھی دیکھیں گے جو پہلے سے اس حلقے میں ہیں۔';

  @override
  String get addMemberAlreadyInCircle => 'پہلے ہی اس حلقے میں ہے';

  @override
  String addMemberSendInvitation(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'دعوت نامے بھیجیں',
      one: 'دعوت نامہ بھیجیں',
    );
    return '$_temp0';
  }

  @override
  String addMemberSendingInvitation(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'دعوت نامے بھیجے جا رہے ہیں...',
      one: 'دعوت نامہ بھیجا جا رہا ہے...',
    );
    return '$_temp0';
  }

  @override
  String addMemberSentToCircle(int count, String circleName) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$circleName کو دعوت نامے بھیج دیے گئے',
      one: '$circleName کو دعوت نامہ بھیج دیا گیا',
    );
    return '$_temp0';
  }

  @override
  String addMemberSentSoFar(int sent, int total, String circleName) {
    final intl.NumberFormat sentNumberFormat = intl.NumberFormat.decimalPattern(
      localeName,
    );
    final String sentString = sentNumberFormat.format(sent);
    final intl.NumberFormat totalNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String totalString = totalNumberFormat.format(total);

    String _temp0 = intl.Intl.pluralLogic(
      total,
      locale: localeName,
      other:
          '$circleName کے لیے اب تک بھیجے گئے دعوت نامے: $totalString میں سے $sentString۔ جب تک ایپ کھلی ہو، Haven زیادہ سے زیادہ ایک دن تک باقی دعوت نامے بھیجتا رہتا ہے۔',
      one:
          '$circleName کے لیے اب تک بھیجا گیا دعوت نامہ: $totalString میں سے $sentString۔ جب تک ایپ کھلی ہو، Haven زیادہ سے زیادہ ایک دن تک اسے بھیجتا رہتا ہے۔',
    );
    return '$_temp0';
  }

  @override
  String addMemberReinviteNeeded(String circleName) {
    return 'Haven $circleName کا دعوت نامہ نہیں بھیج سکتا۔ اُس شخص کو ہٹا کر دوبارہ شامل کریں۔';
  }

  @override
  String get memberCannotReceiveInvitations =>
      'Haven آپ کے چنے ہوئے سب لوگوں کو مدعو نہیں کر سکتا، کیونکہ اسے یہ معلوم نہ ہو سکا کہ ان میں سے کم از کم ایک کا دعوت نامہ کہاں بھیجا جائے۔ جن لوگوں کو آپ نے چنا ہے، ان سے کہیں کہ دیکھ لیں کہ ان کی ایپ دعوت نامے وصول کر سکتی ہے، پھر دوبارہ کوشش کریں۔';

  @override
  String get missedInvitationsShowWho => 'افراد دکھائیں';

  @override
  String missedInvitationsTitle(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'دعوت نامے نہیں بھیجے جا سکے',
      one: 'دعوت نامہ نہیں بھیجا جا سکا',
    );
    return '$_temp0';
  }

  @override
  String get addMemberError =>
      'رکن شامل کرنے میں ناکامی۔ براہِ کرم دوبارہ کوشش کریں۔';

  @override
  String get qrScannerTitle => 'QR کوڈ اسکین کریں';

  @override
  String get qrScannerToggleFlash => 'فلیش آن/آف کریں';

  @override
  String get qrScannerSwitchCamera => 'کیمرہ تبدیل کریں';

  @override
  String get qrScannerInstruction => 'QR کوڈ کو فریم کے اندر رکھیں';

  @override
  String get qrScannerScanning => 'اسکین ہو رہا ہے...';

  @override
  String get circleMemberNoRecentLocation => 'کوئی حالیہ مقام نہیں';

  @override
  String get circleMemberRemoveTooltip => 'حلقے سے ہٹائیں';

  @override
  String circleMemberRemoveDialogTitle(String name) {
    return '$name کو ہٹائیں؟';
  }

  @override
  String get circleMemberRemoveDialogBody =>
      'جیسے ہی حلقے کے باقی ارکان اس تبدیلی کے ساتھ ہم آہنگ ہو جاتے ہیں، ہٹائے گئے رکن کے لیے اس حلقے کی کوئی نئی چیز پڑھنا ممکن نہیں رہتا؛ عام طور پر اس میں چند منٹ لگتے ہیں، اور جو اُس وقت آف لائن تھا اس کے لیے کچھ زیادہ۔ جو کچھ انہیں پہلے مل چکا ہے وہ ان کے فون پر رہتا ہے۔ اسے واپس کرنے کے لیے آپ کو انہیں دوبارہ دعوت دینی ہوگی۔';

  @override
  String get circleMemberRemoveConfirm => 'ہٹائیں';

  @override
  String circleMemberRemoveInProgress(String name) {
    return '$name کو ہٹایا جا رہا ہے…';
  }

  @override
  String circleMemberRemoveSuccess(String name) {
    return '$name کو حلقے سے ہٹا دیا گیا';
  }

  @override
  String circleMemberRemoveError(String name) {
    return '$name کو ہٹایا نہ جا سکا۔ کچھ تبدیل نہیں ہوا — اپنا کنکشن جانچیں اور دوبارہ کوشش کریں۔';
  }

  @override
  String circleMemberRemoveAwaitingAnnouncement(String name) {
    return '$name کو ہٹانے کا عمل ابھی جاری ہے، ریلے کا انتظار ہے۔ جب تک یہ مکمل نہ ہو، اس حلقے کے ساتھ کچھ بھی شیئر نہیں ہوتا۔';
  }

  @override
  String get circleMemberAdmin => 'منتظم';

  @override
  String get circleMemberHintNoLocation => 'کوئی مقام دستیاب نہیں';

  @override
  String get circleMemberHintMember => 'رکن';

  @override
  String get circleMemberHintTapToCenter =>
      'ان کے مقام پر نقشہ مرکوز کرنے کے لیے تھپتھپائیں';

  @override
  String get pendingMemberRetryTooltip => 'توثیق دوبارہ کریں';

  @override
  String get pendingMemberRemoveTooltip => 'فہرست سے ہٹائیں';

  @override
  String get pendingMemberValidating => 'توثیق ہو رہی ہے';

  @override
  String get pendingMemberValid => 'درست';

  @override
  String get pendingMemberWarning => 'انتباہ';

  @override
  String get pendingMemberCheckingAvailability => 'دستیابی جانچی جا رہی ہے...';

  @override
  String get pendingMemberReadyToInvite => 'دعوت دینے کے لیے تیار';

  @override
  String get pendingMemberNeedsUpdate =>
      'انہیں Haven اپ ڈیٹ کرنے یا کھولنے کی ضرورت ہے';

  @override
  String get memberKeyPackageStale =>
      'Haven ابھی انہیں مدعو نہیں کر سکتا۔ ان سے کہیں کہ Haven کھولیں، پھر دوبارہ کوشش کریں۔';

  @override
  String get memberSearchHint => 'عوامی کلید درج کریں...';

  @override
  String get memberSearchPasteTooltip => 'کلپ بورڈ سے چسپاں کریں';

  @override
  String get memberSearchAddTooltip => 'رکن شامل کریں';

  @override
  String get memberSearchScanTooltip => 'QR کوڈ اسکین کریں';

  @override
  String get memberSearchHelper =>
      'رابطوں سے ان کی عوامی کلید یا QR کوڈ مانگیں';

  @override
  String get memberSearchNoValidId => 'کوئی درست عوامی کلید نہیں ملی';

  @override
  String get memberSearchAlreadyAdded => 'رکن پہلے ہی شامل ہے';

  @override
  String get memberPickerSectionRoster => 'آپ کے حلقوں کے ارکان';

  @override
  String get memberPickerTierRoster => 'آپ کے حلقوں کا رکن';

  @override
  String get memberPickerNoMatches => 'آپ کے حلقوں میں کوئی مماثل نتیجہ نہیں';

  @override
  String get memberPickerLoading =>
      'آپ کے حلقوں کے لوگوں کی فہرست لوڈ ہو رہی ہے';

  @override
  String get memberPickerDirectoryUnavailable =>
      'فی الحال آپ کے حلقوں کے لوگوں کی فہرست لوڈ نہ ہو سکی';

  @override
  String memberPickerMatchesAnnouncement(int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    return 'مماثل نتائج: $countString';
  }

  @override
  String get memberPickerReasonSelf => 'یہ آپ کی اپنی عوامی کلید ہے';

  @override
  String get memberPickerReadPublicKey => 'عوامی کلید پڑھ کر سنائیں';

  @override
  String get memberPickerSectionRecent => 'حال ہی میں آپ کے حلقوں میں';

  @override
  String get memberPickerTierRecent => 'حال ہی میں آپ کے حلقوں میں';

  @override
  String get memberPickerNicknameNote =>
      'آپ کا مقرر کردہ عرفی نام، ان کا عوامی نام نہیں';

  @override
  String memberPickerCollisionCircleLabel(String circleName) {
    return 'حلقہ: $circleName';
  }

  @override
  String get memberPickerStrangerLookingUp =>
      'شائع شدہ پروفائل تلاش کیا جا رہا ہے…';

  @override
  String get memberPickerStrangerNotFound => 'کوئی شائع شدہ نام نہیں ملا';

  @override
  String memberPickerStrangerFoundAnnouncement(String name) {
    return 'شائع شدہ نام: $name';
  }

  @override
  String selectedMembersMore(int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    return '+$countString مزید';
  }

  @override
  String get invitationCardHeading => 'کسی حلقے کا دعوت نامہ';

  @override
  String invitationCardSemantics(String inviter) {
    return 'کسی حلقے میں شامل ہونے کی دعوت، جو $inviter نے دی ہے';
  }

  @override
  String invitationCardInvitedBySemantics(String inviter) {
    return 'عوامی کلید $inviter کی جانب سے دعوت';
  }

  @override
  String invitationCardInvitedBy(String inviter) {
    return '$inviter کی جانب سے';
  }

  @override
  String get invitationCardNicknameNote =>
      'آپ کا مقرر کردہ عرفی نام، ان کا عوامی نام نہیں';

  @override
  String get invitationCardJustNow => 'ابھی ابھی';

  @override
  String invitationCardDaysAgo(int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    return '${countString}d پہلے';
  }

  @override
  String invitationCardHoursAgo(int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    return '${countString}h پہلے';
  }

  @override
  String invitationCardMinutesAgo(int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    return '${countString}m پہلے';
  }

  @override
  String get invitationCardDecline => 'مسترد کریں';

  @override
  String get invitationCardAccept => 'قبول کریں';

  @override
  String get invitationAcceptedSnack => 'دعوت قبول کر لی گئی';

  @override
  String get invitationDeclinedSnack => 'دعوت مسترد کر دی گئی';

  @override
  String get invitationAcceptError =>
      'دعوت قبول کرنے میں ناکامی۔ براہِ کرم دوبارہ کوشش کریں۔';

  @override
  String invitationNeedsNewInviteError(String name) {
    return 'یہ دعوت اب استعمال نہیں کی جا سکتی۔ $name سے کہیں کہ آپ کو دوبارہ مدعو کریں۔ ہو سکتا ہے انہیں پہلے Haven اپ ڈیٹ کرنا پڑے۔';
  }

  @override
  String get rejoinDialogTitle => 'کیا اس حلقے میں دوبارہ شامل ہونا ہے؟';

  @override
  String rejoinDialogBody(String inviterName, String circleName) {
    return '$inviterName نے آپ کو «$circleName» میں مدعو کیا ہے، جو اس فون پر پہلے سے موجود ہے۔ ایسا تب ہو سکتا ہے جب آپ کو حلقے سے ہٹا کر دوبارہ مدعو کیا گیا ہو۔ دوبارہ شامل ہونے سے اس فون پر حلقے کی کاپی بدل دی جائے گی۔ «مسترد کریں» اس دعوت کو ہمیشہ کے لیے ختم کر دیتا ہے؛ «منسوخ کریں» اسے بعد کے لیے رکھ لیتا ہے۔';
  }

  @override
  String rejoinDialogBodyUnnamed(String circleName) {
    return 'آپ کو «$circleName» میں مدعو کیا گیا ہے، جو اس فون پر پہلے سے موجود ہے۔ ایسا تب ہو سکتا ہے جب آپ کو حلقے سے ہٹا کر دوبارہ مدعو کیا گیا ہو۔ دوبارہ شامل ہونے سے اس فون پر حلقے کی کاپی بدل دی جائے گی۔ «مسترد کریں» اس دعوت کو ہمیشہ کے لیے ختم کر دیتا ہے؛ «منسوخ کریں» اسے بعد کے لیے رکھ لیتا ہے۔';
  }

  @override
  String get rejoinDialogConfirm => 'دوبارہ شامل ہوں';

  @override
  String invitationRosterFullError(int limit) {
    final intl.NumberFormat limitNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String limitString = limitNumberFormat.format(limit);

    return 'آپ کے پاس بیک وقت زیادہ سے زیادہ $limitString حلقے ہو سکتے ہیں۔ پہلے کوئی حلقہ چھوڑ دیں، پھر یہ دعوت قبول کریں۔';
  }

  @override
  String get invitationDeclineError =>
      'دعوت مسترد کرنے میں ناکامی۔ براہِ کرم دوبارہ کوشش کریں۔';

  @override
  String get circleSelectorLabel => 'حلقہ منتخب کنندہ';

  @override
  String get circleSelectorPlaceholder => 'کوئی حلقہ منتخب کریں';

  @override
  String get circleSelectorNewCircle => 'نیا حلقہ';

  @override
  String get circleSelectorLoadError => 'حلقے لوڈ نہ ہو سکے';

  @override
  String get circleSelectorExpandedAnnouncement => 'حلقوں کی فہرست پھیلائی گئی';

  @override
  String get circleSelectorCollapsedAnnouncement => 'حلقوں کی فہرست سمیٹی گئی';

  @override
  String get circleDetailsButtonTooltip => 'حلقے کی تفصیلات';

  @override
  String get circleDetailsTitle => 'حلقے کی تفصیلات';

  @override
  String circleDetailsMembersWithEpoch(String members, int epoch) {
    final intl.NumberFormat epochNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String epochString = epochNumberFormat.format(epoch);

    return '$members · دور $epochString';
  }

  @override
  String circleDetailsMetaWithExpiry(String meta, String expiry) {
    return '$meta · انقضا $expiry';
  }

  @override
  String circleDetailsExpiryMinutesShort(int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$countString منٹ',
      one: '$countString منٹ',
    );
    return '$_temp0';
  }

  @override
  String circleDetailsExpirySecondsShort(int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$countString سیکنڈ',
      one: '$countString سیکنڈ',
    );
    return '$_temp0';
  }

  @override
  String circleDetailsExpiryMinutesLong(int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'تقریباً $countString منٹ',
      one: 'تقریباً $countString منٹ',
    );
    return '$_temp0';
  }

  @override
  String circleDetailsExpirySecondsLong(int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$countString سیکنڈ',
      one: '$countString سیکنڈ',
    );
    return '$_temp0';
  }

  @override
  String circleDetailsExpirySemantics(String meta, String expiry) {
    return '$meta۔ Haven ریلے سے کہتا ہے کہ آپ اس حلقے میں جو مقام کی اپ ڈیٹس بھیجتے ہیں، انہیں $expiry بعد ہٹا دے۔';
  }

  @override
  String get circleDetailsRelaysHeading => 'اس حلقے کے ریلے';

  @override
  String get circleDetailsNoRelays => '(کوئی درج نہیں)';

  @override
  String get circleDetailsRelaysNote =>
      'اس حلقے کی خفیہ کردہ اپ ڈیٹس انہی ریلے سے گزرتی ہیں۔ انہیں حلقہ بنتے وقت طے کیا گیا تھا اور ابھی Haven میں بدلا نہیں جا سکتا۔ آپ کی ریلے فہرست میں ترامیم ان پر اثر نہیں ڈالتیں۔';

  @override
  String get circleDetailsAddMember => 'رکن شامل کریں';

  @override
  String get circleDetailsLeaveCircle => 'حلقہ چھوڑیں';

  @override
  String get circleDetailsLeavingInProgress => 'حلقہ چھوڑا جا رہا ہے…';

  @override
  String get leaveCircleDialogTitle => 'حلقہ چھوڑیں';

  @override
  String get leaveCircleDialogBody =>
      'یہ حلقہ چھوڑ دیں؟ آپ اس کے ارکان کو اپنا مقام بھیجنا اور ان کا مقام دیکھنا بند کر دیں گے۔ آپ نے آخری بار جو مقام بھیجا وہ ایک دن تک ان کے فونوں پر رہتا ہے۔ اسے واپس نہیں کیا جا سکتا: دوبارہ شامل ہونے کے لیے آپ کو نئی دعوت درکار ہوگی۔';

  @override
  String get leaveDisbandedCircleDialogBody =>
      'یہ حلقہ ختم ہو چکا ہے، اس لیے اب اس کے ساتھ کچھ بھی شیئر نہیں ہوتا۔ اسے چھوڑنے سے یہ اس فون سے ہٹ جاتا ہے۔';

  @override
  String get leaveCircleDialogAdminNote =>
      'آپ اس حلقے کے منتظم ہیں۔ آپ کے حلقہ چھوڑنے سے پہلے، Haven کوشش کرتا ہے کہ کسی دوسرے رکن کو منتظم بنا دے تاکہ حلقہ کام کرتا رہے۔';

  @override
  String get leaveCircleConfirm => 'چھوڑیں';

  @override
  String get leaveCircleIdentityUnavailable => 'شناخت دستیاب نہیں';

  @override
  String get leaveCircleSuccess => 'حلقہ کامیابی سے چھوڑ دیا گیا';

  @override
  String get leaveCircleError => 'حلقہ چھوڑنے میں ناکامی';

  @override
  String get legacyCircleRecreateCta => 'حلقہ دوبارہ بنائیں';

  @override
  String get storageResetTitle => 'Haven اپ ڈیٹ ہو چکا ہے';

  @override
  String get storageResetKept =>
      'آپ کی شناخت میں کوئی تبدیلی نہیں آئی، اور جو عوامی پروفائل آپ پہلے شائع کر چکے ہیں وہ جوں کا توں رہے گا۔';

  @override
  String get storageResetLost =>
      'Haven کے خفیہ کاری کے نئے نظام پر منتقل ہونے کے لیے، اس اپ ڈیٹ سے پہلے بنائے گئے حلقے ہٹا دیے گئے۔ انہیں دوبارہ بنائیں اور ان کے ارکان کو پھر سے مدعو کریں۔ اس اپ ڈیٹ سے پہلے آپ نے لوگوں کو جو عرفی نام دیے تھے، اور پروفائل کی کوئی بھی ایسی تبدیلی جو اس وقت تک مکمل طور پر محفوظ نہیں ہوئی تھی، وہ بھی ہٹا دیے گئے۔';

  @override
  String get storageResetRelays =>
      'اس اپ ڈیٹ نے آپ کی ریلے کی ترتیبات Haven کی طے شدہ ترتیبات پر واپس کر دیں۔ جب تک آپ جاری نہ رکھیں یا ریلے کی ترتیبات سے واپس نہ آئیں، یہ ترتیبات شائع نہیں ہوں گی، اس لیے آپ پہلے اپنے ریلے شامل کر سکتے ہیں۔';

  @override
  String get storageResetContinue => 'جاری رکھیں';

  @override
  String get storageResetOpenRelaySettings => 'ریلے کی ترتیبات';

  @override
  String get storageResetAcknowledgeFailed =>
      'Haven آپ کا جواب محفوظ نہیں کر سکا۔ جب تک یہ محفوظ نہ ہو، Haven آپ کی ریلے کی ترتیبات یا دعوتی کلید شائع نہیں کرے گا، اس لیے ابھی کوئی آپ کو مدعو نہیں کر سکتا۔ دوبارہ کوشش کریں، ورنہ اگلی بار کھلنے پر Haven پھر پوچھے گا۔';

  @override
  String get circlesPanelCollapsedAnnouncement => 'حلقوں کا پینل سمیٹا گیا';

  @override
  String get circlesPanelExpandedAnnouncement => 'حلقوں کا پینل پھیلایا گیا';

  @override
  String get circlesPanelSlightlyOpenAnnouncement =>
      'حلقوں کا پینل ذرا سا کھلا';

  @override
  String get circlesPanelHalfOpenAnnouncement => 'حلقوں کا پینل آدھا کھلا';

  @override
  String get circleMemberAnnouncementSelf => 'آپ';

  @override
  String get circleMemberAnnouncementFallback => 'رکن';

  @override
  String get invitationsRefreshTooltip => 'دعوت نامے تازہ کریں';

  @override
  String get invitationsLoadError => 'دعوت نامے لوڈ نہ ہو سکے';

  @override
  String invitationsNoticeRefused(int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other:
          '$countString اِن باکس ریلے نے Haven کو آپ کے دعوت نامے پڑھنے کی اجازت نہیں دی، اس لیے جو دعوت نامہ صرف وہاں بھیجا گیا ہو وہ آپ تک نہیں پہنچے گا۔ ریلے کی ترتیبات میں جا کر انہیں ہٹا دیں یا کوئی اور ریلے شامل کریں۔',
      one:
          '1 اِن باکس ریلے نے Haven کو آپ کے دعوت نامے پڑھنے کی اجازت نہیں دی، اس لیے جو دعوت نامہ صرف وہاں بھیجا گیا ہو وہ آپ تک نہیں پہنچے گا۔ ریلے کی ترتیبات میں جا کر اسے ہٹا دیں یا کوئی اور ریلے شامل کریں۔',
    );
    return '$_temp0';
  }

  @override
  String invitationsNoticeNotSaved(int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$countString دعوت نامے موصول ہوئے مگر اس آلے پر محفوظ نہ ہو سکے۔',
      one: 'ایک دعوت نامہ موصول ہوا مگر اس آلے پر محفوظ نہ ہو سکا۔',
    );
    return '$_temp0';
  }

  @override
  String get invitationsNoticeOffline =>
      'Haven آپ کے اِن باکس ریلے تک نہیں پہنچ سکا، اس لیے نئے دعوت نامے ابھی ظاہر نہیں ہو سکتے۔';

  @override
  String get invitationsNoticeIncomplete =>
      'Haven آپ کے تمام اِن باکس ریلے کی جانچ مکمل نہیں کر سکا، اس لیے ہو سکتا ہے کچھ دعوت نامے ابھی ظاہر نہ ہوں۔';

  @override
  String get invitationsNoticeOpenRelaySettings => 'ریلے کی ترتیبات';

  @override
  String get invitationsEmptyTitle => 'کوئی دعوت نامہ نہیں';

  @override
  String get invitationsEmptyMessage =>
      'جب کوئی آپ کو کسی حلقے میں مدعو کرے گا تو وہ یہاں ظاہر ہو گا۔';

  @override
  String get refreshRingSemanticNoInbox =>
      'کوئی اِن باکس کنفیگر نہیں ہے، ریلے کی ترتیبات کھولتا ہے';

  @override
  String refreshRingSemanticChecking(int checked, int total) {
    final intl.NumberFormat checkedNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String checkedString = checkedNumberFormat.format(checked);
    final intl.NumberFormat totalNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String totalString = totalNumberFormat.format(total);

    String _temp0 = intl.Intl.pluralLogic(
      total,
      locale: localeName,
      other: '$totalString میں سے $checkedString ریلے جانچے گئے',
      one: '$totalString میں سے $checkedString ریلے جانچا گیا',
    );
    return '$_temp0';
  }

  @override
  String refreshRingSemanticInboxAll(int total) {
    final intl.NumberFormat totalNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String totalString = totalNumberFormat.format(total);

    String _temp0 = intl.Intl.pluralLogic(
      total,
      locale: localeName,
      other: 'دعوت نامے تمام $totalString ریلے پر جانچ لیے گئے',
      one: 'دعوت نامے ریلے پر جانچ لیے گئے',
    );
    return '$_temp0';
  }

  @override
  String get refreshRingSemanticInboxNone =>
      'کسی بھی ریلے پر دعوت نامے جانچے نہ جا سکے';

  @override
  String refreshRingSemanticInboxPartial(int ok, int total) {
    final intl.NumberFormat okNumberFormat = intl.NumberFormat.decimalPattern(
      localeName,
    );
    final String okString = okNumberFormat.format(ok);
    final intl.NumberFormat totalNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String totalString = totalNumberFormat.format(total);

    return 'دعوت نامے $totalString میں سے $okString ریلے پر جانچ لیے گئے';
  }

  @override
  String get refreshRingAnnouncementChecking => 'ریلے جانچے جا رہے ہیں';

  @override
  String get refreshRingAnnouncementInboxAll =>
      'دعوت نامے ہر ریلے پر جانچ لیے گئے';

  @override
  String refreshRingAnnouncementInboxPartial(int ok, int total) {
    final intl.NumberFormat okNumberFormat = intl.NumberFormat.decimalPattern(
      localeName,
    );
    final String okString = okNumberFormat.format(ok);
    final intl.NumberFormat totalNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String totalString = totalNumberFormat.format(total);

    return 'دعوت نامے $totalString میں سے $okString ریلے پر جانچ لیے گئے';
  }

  @override
  String get refreshRingAnnouncementInboxNone =>
      'کسی بھی ریلے پر دعوت نامے جانچے نہ جا سکے';

  @override
  String get refreshRingAnnouncementNoInbox => 'کوئی اِن باکس کنفیگر نہیں ہے';

  @override
  String get identityTitle => 'شناخت';

  @override
  String get identityLoadError =>
      'آپ کی شناخت لوڈ کرتے ہوئے کچھ غلط ہو گیا۔ براہِ کرم دوبارہ کوشش کریں۔';

  @override
  String get identityMissingTitle => 'کوئی شناخت نہیں';

  @override
  String get identityMissingMessage =>
      'آپ کی شناخت ختم ہو گئی ہے۔ Haven استعمال کرتے رہنے کے لیے ایک نئی مرتب کریں۔';

  @override
  String get identitySetUpCta => 'شناخت مرتب کریں';

  @override
  String get identityPublicKeyQrTitle => 'عوامی کلید QR';

  @override
  String get identityPublicKeyQrSubtitle =>
      'دوسرے آپ کو حلقوں میں کیسے مدعو کرتے ہیں';

  @override
  String get identityAdvancedTitle => 'اعلیٰ';

  @override
  String get identityAdvancedSubtitle => 'عوامی کلید، خفیہ کلید، حذف';

  @override
  String get profileIsPublicNoticeTitle => 'پروفائل عوامی ہے';

  @override
  String get profileIsPublicNoticeBody =>
      'آپ کا ظاہری نام اور تصویر Nostr نیٹ ورک پر کسی کو بھی نظر آتے ہیں، صرف آپ کے حلقوں کے ارکان کو نہیں۔ صرف وہی شیئر کریں جسے عوامی کرنے میں آپ راحت محسوس کریں۔';

  @override
  String get identityRefreshProfileTooltip => 'عوامی پروفائل تازہ کریں';

  @override
  String get identityAdvancedExportError =>
      'خفیہ کلید برآمد کرنے میں ناکامی۔ براہِ کرم دوبارہ کوشش کریں۔';

  @override
  String get identityAdvancedDeleteTitle => 'شناخت حذف کریں؟';

  @override
  String get identityAdvancedDeleteBody =>
      'اس سے آپ کی شناخت اور حلقوں کا سارا ڈیٹا اس فون سے حذف ہو جاتا ہے۔ اس کے تحت جو کچھ پہلے ہی شائع ہو چکا ہے وہ جہاں ہے وہیں رہتا ہے: آپ کا نام اور کلیدیں اُن ریلے پر جن کے پاس ہیں، اور آپ کی تصویر ہر اُس تصویری میزبان پر جس پر اسے اپ لوڈ کیا گیا تھا۔ اگر آپ اپنی شناخت بحال کرنا چاہتے ہیں تو یقینی بنائیں کہ آپ نے اپنی خفیہ کلید کا بیک اپ لے لیا ہے۔';

  @override
  String get identityAdvancedDeleteConfirm => 'حذف کریں';

  @override
  String get identityAdvancedDeletedSnack => 'شناخت حذف کر دی گئی';

  @override
  String get identityAdvancedDeleteError =>
      'شناخت حذف کرنے میں ناکامی۔ براہِ کرم دوبارہ کوشش کریں۔';

  @override
  String get identityAdvancedDeletingProgress =>
      'آپ کی شناخت حذف کی جا رہی ہے…';

  @override
  String identityAdvancedCopiedToClipboard(String label) {
    return '$label کلپ بورڈ پر کاپی ہو گئی';
  }

  @override
  String get identityAdvancedSecretCopiedWarning =>
      'خفیہ کلید کاپی ہو گئی۔ انتباہ: دوسری ایپس آپ کا کلپ بورڈ پڑھ سکتی ہیں۔ اسے کسی محفوظ جگہ چسپاں کریں اور اپنا کلپ بورڈ صاف کر دیں۔';

  @override
  String get identityAdvancedMissingBody => 'کوئی شناخت مرتب نہیں ہے۔';

  @override
  String get identityAdvancedPublicKeyLabel => 'عوامی کلید';

  @override
  String get identityAdvancedPublicKeyHexLabel => 'عوامی کلید (hex)';

  @override
  String get identityAdvancedCopyValue => 'عوامی کلید';

  @override
  String get identityAdvancedCopyPublicKeyTooltip => 'عوامی کلید کاپی کریں';

  @override
  String get identityAdvancedCopyHexTooltip => 'hex کاپی کریں';

  @override
  String get identityAdvancedSecretKeyTitle => 'خفیہ کلید';

  @override
  String get identityAdvancedSecretKeyWarning =>
      'آپ کی خفیہ کلید آپ کی شناخت تک مکمل رسائی دیتی ہے۔ اسے کبھی کسی کے ساتھ شیئر نہ کریں۔';

  @override
  String get identityAdvancedRevealSecretKey => 'خفیہ کلید ظاہر کریں';

  @override
  String get identityAdvancedHideSecretKey => 'خفیہ کلید چھپائیں';

  @override
  String get identityAdvancedCopySecretKeyTooltip => 'خفیہ کلید کاپی کریں';

  @override
  String get identityAdvancedDeleteIdentityCta => 'شناخت حذف کریں';

  @override
  String get qrCodeLoadError =>
      'آپ کی عوامی کلید لوڈ کرتے ہوئے کچھ غلط ہو گیا۔ براہِ کرم دوبارہ کوشش کریں۔';

  @override
  String get qrCodeYourPublicKeyLabel => 'آپ کی عوامی کلید';

  @override
  String get qrCodeWhatIsThisTitle => 'یہ کیا ہے؟';

  @override
  String get qrCodeExplainerKeys =>
      'Haven، Nostr پر چلتا ہے، ایک کھلا نیٹ ورک جس کے پیچھے نہ کوئی کمپنی اکاؤنٹ ہے نہ سائن اپ۔ آپ کی شناخت محض کلیدوں کا ایک جوڑا ہے: ایک خفیہ کلید جو صرف آپ کے پاس ہے، اور اسی سے بنی یہ عوامی کلید۔';

  @override
  String get qrCodeExplainerUsername =>
      'آپ کی عوامی کلید ایک ایسے صارف نام کی طرح کام کرتی ہے جسے شیئر کرنا محفوظ ہے۔ لوگ آپ کو کسی حلقے میں مدعو کرنے کے لیے یہ کوڈ اسکین کرتے ہیں، یا آپ کی عوامی کلید چسپاں کرتے ہیں۔ اسے شیئر کرنے سے یہ ظاہر نہیں ہو سکتا کہ آپ کہاں ہیں۔ آپ کا ظاہری نام اور تصویر پہلے ہی عوامی ہیں، اس لیے اس سے کچھ اضافہ نہیں ہوتا۔';

  @override
  String get displayNameCardTitle => 'ظاہری نام';

  @override
  String get displayNameCardLoadError =>
      'آپ کا ظاہری نام لوڈ نہ ہو سکا۔ بعد میں دوبارہ کوشش کریں۔';

  @override
  String get displayNameCardHint => 'اپنا ظاہری نام درج کریں';

  @override
  String get displayNameCardSavedLabel => 'ظاہری نام محفوظ ہو گیا';

  @override
  String get displayNameCardSaveLabel => 'ظاہری نام محفوظ کریں';

  @override
  String get displayNameCardSavingLabel => 'ظاہری نام محفوظ ہو رہا ہے';

  @override
  String get displayNameCardRetryLabel => 'محفوظ کرنا ناکام۔ دوبارہ کوشش کریں';

  @override
  String get displayNameCardSavedAnnouncement => 'ظاہری نام محفوظ ہو گیا';

  @override
  String get displayNameCardSaveFailedAnnouncement =>
      'محفوظ کرنا ناکام، دوبارہ کوشش کریں';

  @override
  String get npubQrCopiedSnack => 'عوامی کلید کلپ بورڈ پر کاپی ہو گئی';

  @override
  String get npubQrCopyButton => 'عوامی کلید کاپی کریں';

  @override
  String get circleMemberPublicKeyCopied =>
      'عوامی کلید کلپ بورڈ پر کاپی ہو گئی';

  @override
  String get circleMemberCopyPublicKeyHint => 'عوامی کلید کاپی کریں';

  @override
  String get circleMemberSetNicknameMenuItem => 'عرفی نام مقرر کریں';

  @override
  String get circleMemberCopyPublicKeyMenuItem => 'عوامی کلید کاپی کریں';

  @override
  String get memberProfileRefreshErrorGeneric =>
      'پروفائلز تازہ نہ ہو سکے۔ براہِ کرم دوبارہ کوشش کریں۔';

  @override
  String get memberDetailSheetTitle => 'رکن کی تفصیلات';

  @override
  String get memberNicknameSheetHint => 'کوئی عرفی نام درج کریں';

  @override
  String get memberNicknameSheetLabel => 'عرفی نام';

  @override
  String get memberNicknameSheetSave => 'عرفی نام محفوظ کریں';

  @override
  String get memberNicknameSheetClear => 'عرفی نام صاف کریں';

  @override
  String get memberNicknameSheetSavedAnnouncement => 'عرفی نام محفوظ ہو گیا';

  @override
  String get memberNicknameSheetClearedAnnouncement => 'عرفی نام صاف ہو گیا';

  @override
  String get npubQrScanLabel => 'مجھے شامل کرنے کے لیے اسکین کریں';

  @override
  String get npubQrSemanticsLabel => 'آپ کی عوامی کلید کا QR کوڈ';

  @override
  String get photoHeaderRemoveTitle => 'پروفائل تصویر ہٹائیں؟';

  @override
  String get photoHeaderRemoveBody =>
      'اس سے آپ کی تصویر آپ کے عوامی پروفائل سے ہٹ جاتی ہے۔ تصویر کی فائل ہر اُس سرور پر موجود رہتی ہے جس پر اسے اپ لوڈ کیا گیا تھا، اور جو نقلیں دوسرے پہلے ہی ڈاؤن لوڈ کر چکے ہیں وہ اُن کے پاس رہتی ہیں۔';

  @override
  String get photoHeaderEditPhoto => 'تصویر میں ترمیم کریں';

  @override
  String get photoHeaderRemove => 'ہٹائیں';

  @override
  String get photoHeaderViewPhotoSemantics => 'پروفائل تصویر دیکھیں';

  @override
  String get photoHeaderAddPhotoSemantics => 'پروفائل تصویر شامل کریں';

  @override
  String get photoHeaderChangePhotoSemantics => 'پروفائل تصویر تبدیل کریں';

  @override
  String get avatarPickerPhotoUpdatedAnnouncement => 'تصویر اپ ڈیٹ ہو گئی۔';

  @override
  String get avatarPickerPhotoRemoved => 'تصویر ہٹا دی گئی۔';

  @override
  String get avatarPickerRemoveError =>
      'آپ کی تصویر ہٹائی نہ جا سکی۔ براہِ کرم دوبارہ کوشش کریں۔';

  @override
  String get avatarPickerUpdateError =>
      'آپ کی تصویر اپ ڈیٹ نہ ہو سکی۔ براہِ کرم دوبارہ کوشش کریں۔';

  @override
  String get avatarPickerCropTitle => 'تصویر کاٹیں';

  @override
  String get avatarPickerCropDone => 'ہو گیا';

  @override
  String get avatarPickerCropCancel => 'منسوخ کریں';

  @override
  String get avatarFullscreenClose => 'بند کریں';

  @override
  String get avatarFullscreenSemantics => 'پروفائل تصویر، پوری اسکرین';

  @override
  String get avatarFullscreenLoadError => 'تصویر لوڈ نہ ہو سکی';

  @override
  String get mapInitializing => 'ابتدائی تیاری ہو رہی ہے...';

  @override
  String get mapInitFailedTitle => 'ابتدائی تیاری ناکام';

  @override
  String get mapInitFailedMessage =>
      'مقام کی سروسز کی ابتدائی تیاری میں ناکامی۔';

  @override
  String get mapInitFailedRetry =>
      'ابتدائی تیاری ناکام۔ براہِ کرم دوبارہ کوشش کریں۔';

  @override
  String get mapLocationOffMessage =>
      'خود کو اور اپنے حلقوں کو نقشے پر دیکھنے کے لیے مقام آن کریں۔';

  @override
  String get mapGettingLocation => 'مقام حاصل کیا جا رہا ہے...';

  @override
  String get mapLoadingMap => 'نقشہ لوڈ ہو رہا ہے...';

  @override
  String get mapLocationOffTitle => 'مقام بند ہے';

  @override
  String get mapLocationErrorTitle => 'مقام میں خرابی';

  @override
  String get mapLocationUnavailable => 'مقام عارضی طور پر دستیاب نہیں';

  @override
  String get mapLocationNoPermissionTitle =>
      'Haven آپ کا مقام استعمال نہیں کر سکتا';

  @override
  String get mapLocationSharingStoppedServiceOff =>
      'اس آلے پر مقام بند ہے، اس لیے Haven نے آپ کا مقام آپ کے حلقوں کے ساتھ شیئر کرنا روک دیا ہے۔ دوبارہ شروع کرنے کے لیے مقام آن کریں۔';

  @override
  String get mapLocationSharingStoppedPermission =>
      'Haven کے پاس اب آپ کا مقام استعمال کرنے کی اجازت نہیں رہی، اس لیے شیئرنگ رک گئی ہے۔ دوبارہ شروع کرنے کے لیے مقام تک رسائی کی اجازت دیں۔';

  @override
  String get mapLocationSharingStoppedPermissionSettings =>
      'Haven کے لیے مقام تک رسائی سسٹم کی ترتیبات میں بند ہے، اس لیے شیئرنگ رک گئی ہے۔ دوبارہ شروع کرنے کے لیے وہیں جا کر اجازت دیں۔';

  @override
  String get mapLocationSharingStoppedBoth =>
      'Haven نے آپ کا مقام شیئر کرنا روک دیا ہے۔ اس آلے پر مقام آن کریں اور Haven کو اسے استعمال کرنے کی اجازت دیں۔';

  @override
  String get mapLocationSharingStoppedUnknown =>
      'Haven کو آپ کا مقام ملنا بند ہو گیا ہے، اس لیے شیئرنگ رک گئی ہے۔ دیکھ لیں کہ مقام آن ہے اور Haven کو اسے استعمال کرنے کی اجازت حاصل ہے۔';

  @override
  String get mapLocationAccessRestoredAnnouncement =>
      'مقام تک رسائی بحال ہو گئی ہے۔ Haven پھر سے آپ کا مقام شیئر کر رہا ہے۔';

  @override
  String get clockSkewTitle => 'اس فون کی گھڑی غلط ہے';

  @override
  String get clockSkewBodyRejected =>
      'آپ کے حلقوں کو آپ کا مقام نہیں مل رہا، کیونکہ یہ فون اس پر جو وقت درج کرتا ہے، ریلے اسے مسترد کر دیتے ہیں۔ یہ مسئلہ حل کرنے کے لیے سسٹم کی ترتیبات میں خودکار تاریخ اور وقت آن کریں۔';

  @override
  String get clockSkewBodyBehind =>
      'اس فون کی گھڑی آپ کے باقی حلقہ ارکان سے پیچھے چل رہی ہے، اس لیے یہ فون مقامات تو بھیج دیتا ہے، مگر ان کی میعاد جلد ختم ہو جاتی ہے، اور ہو سکتا ہے آپ کے حلقے ان میں سے کچھ یا سبھی نہ دیکھ پائیں۔ یہ مسئلہ حل کرنے کے لیے سسٹم کی ترتیبات میں خودکار تاریخ اور وقت آن کریں۔';

  @override
  String get clockSkewResolvedAnnouncement =>
      'گھڑی کا مسئلہ ختم ہو گیا۔ Haven پھر سے آپ کا مقام شیئر کر رہا ہے۔';

  @override
  String get clockSkewTitleDisagreement =>
      'آپ کے کسی حلقے میں کوئی گھڑی غلط ہے';

  @override
  String get clockSkewBodyDisagreement =>
      'اس فون کی گھڑی اور کسی دوسرے رکن کی گھڑی میں دو منٹ یا اس سے زیادہ کا فرق ہے۔ اگر خرابی اسی فون کی گھڑی میں ہے، تو یہ فون جو مقام بھیجتا ہے، کسی کے دیکھنے سے پہلے اس کی میعاد ختم ہو سکتی ہے۔ سسٹم کی ترتیبات میں خودکار تاریخ اور وقت آن کریں تاکہ یہ اطمینان ہو جائے کہ غلط گھڑی اس فون کی نہیں ہے۔';

  @override
  String get clockSkewDisagreementResolvedAnnouncement =>
      'گھڑی کا انتباہ ختم ہو گیا۔';

  @override
  String get sharingHealthTitleStopped => 'مقام کی شیئرنگ رک گئی ہے';

  @override
  String get sharingHealthTitleNotSending => 'آپ کا مقام شیئر نہیں ہو رہا';

  @override
  String get sharingHealthTitleNotReceiving =>
      'آپ کو دوسروں کے مقامات نہیں مل رہے';

  @override
  String sharingHealthNoUpdatesMinutes(int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'تقریباً $countString منٹ سے کوئی اپ ڈیٹ نہیں',
      one: 'تقریباً 1 منٹ سے کوئی اپ ڈیٹ نہیں',
    );
    return '$_temp0';
  }

  @override
  String sharingHealthNoUpdatesHours(int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'تقریباً $countString گھنٹے سے کوئی اپ ڈیٹ نہیں',
      one: 'تقریباً 1 گھنٹے سے کوئی اپ ڈیٹ نہیں',
    );
    return '$_temp0';
  }

  @override
  String sharingHealthNoUpdatesDays(int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'تقریباً $countString دن سے کوئی اپ ڈیٹ نہیں',
      one: 'تقریباً 1 دن سے کوئی اپ ڈیٹ نہیں',
    );
    return '$_temp0';
  }

  @override
  String get sharingHealthRepairAction => 'ٹھیک کریں';

  @override
  String get sharingHealthRepairSent =>
      'حلقہ ٹھیک کرنے کی تبدیلی بھیج دی گئی ہے۔ دوسرے اُس وقت ہم آہنگ ہوں گے جب اُن کے فون یہ وصول کر لیں گے۔';

  @override
  String get sharingHealthRepairNothingToDo =>
      'ابھی ٹھیک کرنے کو کچھ نہیں ہے۔ Haven خود کوشش کرتا رہے گا۔';

  @override
  String get sharingHealthRepairUnresolvedAnnouncement =>
      'مقام کی شیئرنگ اب بھی کام نہیں کر رہی۔';

  @override
  String get sharingHealthResumedAnnouncement =>
      'مقام کی شیئرنگ پھر سے کام کر رہی ہے۔';

  @override
  String get sharingHealthTitleQuarantined =>
      'Haven ابھی یہ حلقہ نہیں کھول سکتا';

  @override
  String get sharingHealthBodyQuarantined =>
      'اس فون پر یہ حلقہ لوڈ کرتے وقت کچھ غلط ہو گیا۔ حلقہ اب بھی یہیں ہے۔';

  @override
  String get sharingHealthTitleDisbanded => 'یہ حلقہ ختم ہو چکا ہے';

  @override
  String get sharingHealthBodyDisbanded =>
      'ایک منتظم نے یہ حلقہ ختم کر دیا ہے، اس لیے اب اس کے ساتھ کچھ بھی شیئر نہیں ہوتا۔ اسے اس فون سے ہٹانے کے لیے یہ حلقہ چھوڑیں۔';

  @override
  String get sharingHealthQuarantineRetryHint =>
      'اس حلقے کو دوبارہ لوڈ کرنے کی کوشش کرتا ہے';

  @override
  String get sharingHealthQuarantineRetryFailedAnnouncement =>
      'Haven اب بھی یہ حلقہ نہیں کھول سکتا۔';

  @override
  String get sharingHealthTitleUnrecoverable =>
      'یہ حلقہ اس فون پر کام کرنا بند کر چکا ہے';

  @override
  String get sharingHealthBodyUnrecoverable =>
      'Haven اب اس فون پر اس حلقے میں نہ اپ ڈیٹس بھیج سکتا ہے نہ وصول کر سکتا ہے۔ اس کے منتظمین میں سے کسی ایک سے کہیں کہ آپ کو ہٹا کر دوبارہ شامل کر لے۔ اگر کوئی ایسا نہ کر سکے تو اُنہی لوگوں کے ساتھ نیا حلقہ بنائیں۔';

  @override
  String get sharingHealthTitleStalled =>
      'Haven اس حلقے کی اپ ڈیٹس پڑھ نہیں پا رہا';

  @override
  String get sharingHealthBodyStalled =>
      'لگتا ہے اس فون سے حلقے کی کوئی تبدیلی چھوٹ گئی ہے، اور ریلے پر تلاش کرنے سے بھی وہ نہیں ملی۔ اس کے منتظمین میں سے کسی ایک سے کہیں کہ آپ کو ہٹا کر دوبارہ شامل کر لے۔ اگر کوئی ایسا نہ کر سکے تو اُنہی لوگوں کے ساتھ نیا حلقہ بنائیں۔';

  @override
  String get sharingHealthTitlePaused => 'Haven نے یہ حلقہ روک رکھا ہے';

  @override
  String get sharingHealthBodyCollision =>
      'Haven کو اس فون پر اس حلقے میں ایک مسئلہ ملا، اس لیے آپ کا مقام نجی رکھنے کے لیے اس نے اس حلقے کے ساتھ شیئرنگ روک دی ہے۔ اسے ٹھیک کرنے کا واحد طریقہ حلقہ چھوڑنا ہے۔ اس میں دوبارہ شامل ہونے کے لیے آپ کو نئی دعوت درکار ہوگی۔';

  @override
  String get sharingHealthBodyCannotCheck =>
      'Haven اس فون پر اس حلقے کی جانچ نہیں کر سکا، اس لیے آپ کا مقام نجی رکھنے کے لیے اس نے اس حلقے کے ساتھ شیئرنگ روک رکھی ہے۔ Haven خود ہی دوبارہ جانچ کرتا ہے۔';

  @override
  String get sharingHealthTitleLeaving => 'یہ حلقہ چھوڑا جا رہا ہے';

  @override
  String get sharingHealthBodyLeaving =>
      'جب تک Haven اس حلقے کو چھوڑنے کا عمل مکمل کر رہا ہے، اس کے ساتھ کچھ بھی شیئر نہیں کیا جاتا۔ اس میں تقریباً ایک دن لگ سکتا ہے۔ عمل مکمل ہونے پر یہ حلقہ اس فون سے غائب ہو جاتا ہے۔';

  @override
  String get sharingHealthBodyRemovalUnmade =>
      'ہٹانے کی جو درخواست آپ نے کی تھی اس پر عمل نہیں ہوا، اس لیے Haven نے اس حلقے کو آپ کا مقام بھیجنا روک رکھا ہے، تاکہ یہ کسی بھی ایسے شخص تک نہ پہنچے جسے آپ نے ہٹانے کی کوشش کی تھی۔';

  @override
  String get sharingHealthBodyRemovalUnmadeNoNotice =>
      'ہٹانے کی جو درخواست آپ نے کی تھی اس پر عمل نہیں ہوا، اس لیے Haven نے اس حلقے کو آپ کا مقام بھیجنا روک رکھا ہے، تاکہ یہ کسی بھی ایسے شخص تک نہ پہنچے جسے آپ نے ہٹانے کی کوشش کی تھی۔ یہ دیکھنے کے لیے کہ حلقے میں اب بھی کون ہے، ارکان کی فہرست کھولیں۔';

  @override
  String get sharingHealthBodyDepartureDue =>
      'کسی نے یہ حلقہ چھوڑ دیا ہے، مگر اُن کے جانے کا عمل ابھی مکمل نہیں ہوا۔ جب تک یہ مکمل نہ ہو، Haven اس حلقے کے ساتھ آپ کا مقام شیئر نہیں کرتا۔';

  @override
  String get sharingHealthTitleBackgroundPaused =>
      'اس حلقے کے لیے پس منظر میں شیئرنگ رکی ہوئی ہے';

  @override
  String get sharingHealthBodyAwaitsForeground =>
      'Haven کے پس منظر میں ہوتے ہوئے اس حلقے کے ریلے بدل گئے۔ Haven نئے ریلے پر منتقلی اُس وقت مکمل کرتا ہے جب وہ کھلا ہو؛ تب تک پس منظر میں اس حلقے کے ساتھ شیئرنگ نہیں ہوتی۔';

  @override
  String get sharingHealthBodyAwaitingRelays =>
      'اس حلقے میں ایک تبدیلی کسی ریلے کی تصدیق کا انتظار کر رہی ہے۔ تب تک Haven نہ اس حلقے کو آپ کا مقام بھیج رہا ہے اور نہ اس کی طرف سے آنے والے نئے مقامات دکھا رہا ہے۔ جب تک ایپ کھلی ہو، Haven کوشش کرتا رہتا ہے۔';

  @override
  String get sharingHealthBodyAcknowledged =>
      'ایک ریلے نے اس حلقے میں ایک تبدیلی قبول کر لی ہے اور Haven اسے مکمل کر رہا ہے۔ تب تک اس حلقے کی اپ ڈیٹس رکی رہتی ہیں۔';

  @override
  String get sharingHealthBodyStagedWithoutRecord =>
      'اس حلقے میں ایک تبدیلی محفوظ نہ ہو سکی، اس لیے وہ بھیجی نہیں گئی۔ Haven یہ معاملہ سلجھا لیتا ہے، زیادہ سے زیادہ اگلی بار شروع ہونے تک؛ تب تک اس حلقے کی اپ ڈیٹس رکی رہتی ہیں۔';

  @override
  String get sharingHealthBodyStoredInput =>
      'اس فون کے پاس اس حلقے کی کچھ ایسی اپ ڈیٹس ہیں جنہیں یہ ابھی تک پروسیس نہیں کر سکا۔ جب تک یہ ایسا نہ کر لے، Haven اس حلقے کے ساتھ آپ کا مقام شیئر نہیں کرتا۔';

  @override
  String get sharingHealthBodySessionHeld =>
      'Haven ابھی اپنا پچھلا کنکشن بند کر رہا ہے، اس لیے مقام کی شیئرنگ رکی ہوئی ہے۔ یہ عمل مکمل ہوتے ہی شیئرنگ پھر سے شروع ہو جاتی ہے۔ اپنا فون دوبارہ چالو کرنے سے یہ رکاوٹ ہمیشہ دور ہو جاتی ہے۔';

  @override
  String get sharingHealthRepairHintAnyMember =>
      'ریلے سے کنکشن بحال کرتا ہے، آپ کا مقام بھیجنے کی دوبارہ کوشش کرتا ہے، اور اس حلقے کو خفیہ کاری کی نئی کلیدیں دے سکتا ہے';

  @override
  String get sharingHealthAttentionAnnouncement =>
      'اس حلقے میں مقام کی شیئرنگ پر توجہ درکار ہے۔ وجہ جاننے کے لیے حلقے کی تفصیلات کھولیں۔';

  @override
  String changeNoticeArrivedAnnouncement(String circleName) {
    return '$circleName میں حالیہ تبدیلیوں کے بارے میں ایک بات پر آپ کی توجہ درکار ہے۔ اسے پڑھنے کے لیے اُس حلقے کی تفصیلات کھولیں۔';
  }

  @override
  String get circleDetailsAttentionTooltip => 'حلقے کی تفصیلات، توجہ درکار ہے';

  @override
  String circleRowAttentionSemantics(String circleName) {
    return '$circleName، توجہ درکار ہے';
  }

  @override
  String get changeNoticeHeading => 'اس حلقے میں تبدیلیاں';

  @override
  String get changeNoteRemovalUndone =>
      'اس حلقے میں ایک تبدیلی نافذ نہیں ہو سکی۔ اگر اس تبدیلی میں کسی کو ہٹایا گیا تھا تو وہ اب بھی حلقے میں ہیں، اور اس حلقے کے ساتھ جو کچھ شیئر ہوتا ہے وہ انہیں نظر آتا ہے۔';

  @override
  String get changeNoteChangeUndone =>
      'اس حلقے میں ایک تبدیلی نافذ نہیں ہو سکی، اس لیے کچھ نہیں بدلا۔ اگر یہ تبدیلی آپ کی تھی اور اب بھی درکار ہے تو اسے دوبارہ کریں۔';

  @override
  String get changeNoteMayBeOutOfStep =>
      'ہو سکتا ہے اس حلقے میں کوئی تبدیلی اس فون کے علم میں آئے بغیر دوسروں تک پہنچ گئی ہو، اس لیے ممکن ہے کہ یہ فون اُن سے ہم آہنگ نہ ہو۔';

  @override
  String get changeNoteReinviteOwed =>
      'آپ کے مدعو کردہ کسی شخص کا نام اس حلقے میں درج ہے، مگر اُن کے لیے شامل ہونا ممکن نہیں، کیونکہ Haven اُن کا دعوت نامہ نہیں بھیج سکتا۔ انہیں ہٹا کر دوبارہ شامل کریں۔';

  @override
  String get changeNoteChangeUnrecorded =>
      'اس حلقے میں ایک تبدیلی محفوظ نہ ہو سکی، اس لیے وہ بھیجی نہیں گئی۔';

  @override
  String get changeNoteQueuedChangeDropped =>
      'اس حلقے میں ایک زیرِ التوا تبدیلی منسوخ کر دی گئی، کیونکہ اسے اب اُس طرح نہیں کیا جا سکتا تھا جیسے کہا گیا تھا۔ ہو سکتا ہے یہ تبدیلی کسی اور طریقے سے پہلے ہی ہو چکی ہو۔';

  @override
  String get changeNoteQueuedChangesHeld =>
      'اس حلقے میں کچھ تبدیلیاں ابھی زیرِ التوا ہیں۔';

  @override
  String get changeNoteQueuedRemovalDropped =>
      'اس حلقے سے ہٹانے کی جو درخواست آپ نے کی تھی اس پر عمل نہیں ہوا۔ ہو سکتا ہے کہ جس کسی کو بھی آپ نے ہٹانے کی کوشش کی تھی، وہ اب بھی حلقے میں ہو۔';

  @override
  String get changeNoteChangeWithdrawn =>
      'کسی دوسرے رکن کی تبدیلی نے اس حلقے میں آپ کی ایک تبدیلی کی جگہ لے لی، اس لیے آپ کی تبدیلی عمل میں نہیں آئی۔ اگر اب بھی درکار ہو تو اسے دوبارہ کریں۔';

  @override
  String get changeNoteWelcomeOwed =>
      'اس حلقے کا ایک دعوت نامہ ابھی تک بھیجا نہیں جا سکا۔ جب تک ایپ کھلی ہو، Haven آپ کے مدعو کرنے کے بعد زیادہ سے زیادہ ایک دن تک اسے بھیجتا رہتا ہے۔ اگر تب تک وہ شامل نہ ہوں تو انہیں ہٹا کر دوبارہ شامل کریں۔';

  @override
  String get changeNoteUnreadLocation =>
      'اس حلقے کو بھیجی گئی کچھ حالیہ اپ ڈیٹس اس فون پر کھولی نہیں جا سکیں۔';

  @override
  String get changeNoticeStillInCircleLabel => 'اب بھی حلقے میں:';

  @override
  String get changeNoticeRemoveAgain => 'دوبارہ ہٹائیں';

  @override
  String get changeNoticeReviewMembers => 'ارکان کا جائزہ لیں';

  @override
  String get changeNoticeKeepMembers => 'انہیں حلقے میں رہنے دیں';

  @override
  String get changeNoticeKeepConfirmTitle =>
      'کیا انہیں حلقے میں رہنے دیا جائے؟';

  @override
  String get changeNoticeKeepConfirmBody =>
      'Haven اب ہٹانے کی اس کارروائی کی وجہ سے اس حلقے کے ساتھ شیئرنگ نہیں روکے گا۔ جس کسی کو بھی آپ نے ہٹانے کی کوشش کی تھی، اگر وہ اب بھی حلقے میں ہے تو اس کی رکنیت برقرار رہے گی، اور جب بھی Haven اس حلقے کے ساتھ آپ کا مقام شیئر کرے گا، وہ مقام اسے نظر آئے گا۔';

  @override
  String get changeNoticeKeepConfirmAction => 'انہیں رہنے دیں';

  @override
  String circleMemberLastSeenMinutes(int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'آخری مقام $countString منٹ پہلے',
      one: 'آخری مقام 1 منٹ پہلے',
    );
    return '$_temp0';
  }

  @override
  String get mapThisLocation => 'یہ مقام';

  @override
  String get mapMemberFallbackName => 'رکن';

  @override
  String mapOpenInAppleMapsTitle(String label) {
    return '$label کو Apple Maps میں کھولیں؟';
  }

  @override
  String get mapOpenInAppleMapsBody =>
      'Apple Maps کو صرف نقشے کا نقطۂ احداثی بھیجا جاتا ہے، کبھی کوئی نام یا شناخت نہیں۔';

  @override
  String get mapOpenInAppleMapsConfirm => 'Apple Maps میں کھولیں';

  @override
  String get mapOpenMapsError => 'Maps نہ کھل سکا';

  @override
  String get mapControlsZoomIn => 'زوم اِن';

  @override
  String get mapControlsZoomOut => 'زوم آؤٹ';

  @override
  String get mapControlsRecenter => 'دوبارہ مرکوز کریں';

  @override
  String get mapControlsRecenterFab => 'میرے مقام پر دوبارہ مرکوز کریں';

  @override
  String get mapAttributionCreditsButton => 'نقشے کے کریڈٹس اور لائسنس';

  @override
  String get userLocationMarkerSemantics => 'آپ کے مقام کا نشان';

  @override
  String memberMarkerMinutesShort(int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    return '${countString}m';
  }

  @override
  String memberMarkerMinutesAgoSemantics(int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$countString منٹ پہلے',
      one: '1 منٹ پہلے',
    );
    return '$_temp0';
  }

  @override
  String memberMarkerNamedSemantics(String name) {
    return '$name کے رکن کا نشان';
  }

  @override
  String get memberMarkerGenericSemantics => 'رکن کا نشان';

  @override
  String memberMarkerLastSeenSemantics(String base, String age) {
    return '$base، آخری بار $age دیکھے گئے';
  }

  @override
  String memberMarkerOffScreenSemantics(String name, String direction) {
    return '$name $direction کی جانب اسکرین سے باہر ہیں، دیکھنے کے لیے تھپتھپائیں';
  }

  @override
  String memberMarkerOffScreenGenericSemantics(String direction) {
    return 'ایک رکن $direction کی جانب اسکرین سے باہر ہے، دیکھنے کے لیے تھپتھپائیں';
  }

  @override
  String get compassNorth => 'شمال';

  @override
  String get compassNorthEast => 'شمال مشرق';

  @override
  String get compassEast => 'مشرق';

  @override
  String get compassSouthEast => 'جنوب مشرق';

  @override
  String get compassSouth => 'جنوب';

  @override
  String get compassSouthWest => 'جنوب مغرب';

  @override
  String get compassWest => 'مغرب';

  @override
  String get compassNorthWest => 'شمال مغرب';

  @override
  String get commonAdd => 'شامل کریں';

  @override
  String get addRelaySheetTitleInbox => 'اِن باکس ریلے شامل کریں';

  @override
  String get addRelaySheetTitleKeyPackage => 'KeyPackage ریلے شامل کریں';

  @override
  String get addRelaySheetTitleProfile => 'پروفائل ریلے شامل کریں';

  @override
  String get addRelaySheetHint => 'wss://relay.example.com';

  @override
  String get addRelaySheetPasteTooltip => 'کلپ بورڈ سے چسپاں کریں';

  @override
  String get addRelaySheetErrorEmpty => 'ریلے کا پتہ درج کریں۔';

  @override
  String get addRelaySheetErrorInsecureScheme =>
      'wss:// استعمال کریں تاکہ اس ریلے کا ٹریفک خفیہ رہے۔';

  @override
  String get addRelaySheetErrorHasCredentials =>
      'ریلے URL میں سند درج نہیں ہونی چاہیے۔';

  @override
  String get addRelaySheetErrorInvalidFormat =>
      'wss://relay.example.com کی طرح ریلے کا پتہ درج کریں۔';

  @override
  String get avatarSemanticsLabel => 'صارف اواتار';

  @override
  String avatarSemanticsFor(String initials) {
    return '$initials کے لیے';
  }

  @override
  String get avatarSemanticsOnline => 'آن لائن';

  @override
  String get avatarSemanticsOffline => 'آف لائن';
}
