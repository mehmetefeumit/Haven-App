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
      'اپنا مقام نجی طور پر صرف انہی لوگوں کے ساتھ شیئر کریں جنہیں آپ چاہتے ہیں۔';

  @override
  String get onboardingWelcomeHeadlineEmphasis => 'صرف';

  @override
  String get onboardingWelcomeCta => 'شروع کریں';

  @override
  String get onboardingValuePropsTitle => 'Haven کو مختلف کیا بناتا ہے';

  @override
  String get onboardingValueProp1Title =>
      'آپ کو صرف آپ کے حلقے ہی دیکھ سکتے ہیں';

  @override
  String get onboardingValueProp1Body =>
      'آپ کا مقام آپ کے آلے سے نکلنے سے پہلے ہی اسی پر خفیہ ہو جاتا ہے، چنانچہ اسے صرف وہی حلقے پڑھ سکتے ہیں جنہیں آپ منتخب کرتے ہیں، کبھی Haven یا کوئی اور نہیں۔ چونکہ Haven اوپن سورس ہے، اس لیے کوئی بھی اس کی تصدیق کر سکتا ہے۔';

  @override
  String get onboardingValueProp2Title => 'اسے کوئی بند نہیں کر سکتا';

  @override
  String get onboardingValueProp2Body =>
      'Haven کا کوئی مرکزی سرور نہیں ہے۔ آپ کے خفیہ کردہ پیغامات آزاد سرورز سے گزرتے ہیں جنہیں ریلے کہا جاتا ہے، اور آپ خود چنتے ہیں کہ کون سے استعمال کرنے ہیں۔ کوئی ایک کمپنی یا حکومت اس نیٹ ورک کو بند نہیں کر سکتی۔';

  @override
  String get onboardingValueProp3Title => 'کسی اکاؤنٹ کی ضرورت نہیں';

  @override
  String get onboardingValueProp3Body =>
      'نہ ای میل، نہ فون نمبر، نہ سائن اپ۔ Haven ایسی شناخت بناتا ہے جس کی خفیہ کلید کبھی آپ کے فون سے باہر نہیں جاتی، اس لیے کوئی ایسا اکاؤنٹ ہی نہیں ہوتا جسے کوئی کسی کے حوالے کر سکے۔';

  @override
  String get onboardingValueProp1Summary =>
      'آپ کے آلے پر خفیہ کردہ، تاکہ صرف آپ کے منتخب کردہ حلقے ہی اسے پڑھ سکیں۔';

  @override
  String get onboardingValueProp2Summary =>
      'کوئی مرکزی سرور نہیں۔ یہ آپ کے منتخب کردہ ریلے نیٹ ورک پر چلتا ہے۔';

  @override
  String get onboardingValueProp3Summary =>
      'نہ ای میل، نہ فون، نہ سائن اپ۔ آپ کی خفیہ کلید کبھی آپ کے فون سے باہر نہیں جاتی۔';

  @override
  String get onboardingCreateIdentityTitle => 'اپنی شناخت بنائیں';

  @override
  String get onboardingCreateIdentityBody =>
      'Haven آپ کی کلیدیں اسی فون پر بناتا ہے۔ خفیہ کلید کبھی اس سے باہر نہیں جاتی۔';

  @override
  String get onboardingCreateIdentityWarning =>
      'اگر آپ یہ فون کھو دیں یا ایپ حذف کر دیں تو آپ کی شناخت ختم ہو جائے گی۔ Haven کے پاس اسے آپ کے لیے بحال کرنے کا کوئی طریقہ نہیں۔';

  @override
  String get onboardingCreateIdentityCta => 'میری شناخت بنائیں';

  @override
  String get onboardingCreateIdentityLoading => 'تیاری ہو رہی ہے…';

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
      'یہ کوئی درست بیک اپ کلید معلوم نہیں ہوتی۔ براہِ کرم جانچ کر دوبارہ کوشش کریں۔';

  @override
  String get onboardingImportError =>
      'ہم وہ کلید درآمد نہ کر سکے۔ براہِ کرم جانچ کر دوبارہ کوشش کریں۔';

  @override
  String get onboardingDisplayNameHint => 'مثلاً علی';

  @override
  String get onboardingDisplayNameError =>
      'وہ نام محفوظ نہ ہو سکا۔ براہِ کرم دوبارہ کوشش کریں۔';

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
  String get settingsIdentitySubtitle => 'پروفائل، کلیدیں اور تصویر شیئرنگ';

  @override
  String get settingsRelaysTitle => 'ریلے';

  @override
  String get settingsRelaysSubtitle => 'جہاں دعوت نامے آپ تک پہنچتے ہیں';

  @override
  String get settingsLocationTitle => 'مقام';

  @override
  String get settingsLocationSubtitle => 'پس منظر میں شیئرنگ اور اجازتیں';

  @override
  String get settingsMapStyleTitle => 'نقشے کا انداز';

  @override
  String get settingsAppearanceSubtitle => 'تھیم اور زبان';

  @override
  String get settingsAboutTitle => 'تعارف';

  @override
  String get settingsDebugOverlayTitle => 'ڈیبگ لاگ اوورلے';

  @override
  String get settingsDebugOverlaySubtitle => 'اسکرین پر لاگ آؤٹ پٹ دکھائیں';

  @override
  String get relaySettingsTitle => 'ریلے';

  @override
  String get relaySettingsCheckRelaysTooltip => 'ریلے جانچیں';

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
  String get relaySettingsInboxSubtitle =>
      'جہاں دعوت نامے آپ تک پہنچتے ہیں (kind 10050)';

  @override
  String get relaySettingsKeyPackageTitle => 'میرے KeyPackage ریلے';

  @override
  String get relaySettingsKeyPackageSubtitle =>
      'جہاں دوسرے وہ کلیدیں پاتے ہیں جو آپ کو مدعو کرنے کے لیے درکار ہوتی ہیں (kind 10002)';

  @override
  String get relaySettingsProfileTitle => 'میرے پروفائل ریلے';

  @override
  String get relaySettingsProfileSubtitle =>
      'جہاں آپ کا عوامی پروفائل تلاش اور شائع کیا جاتا ہے۔ یہ ریلے آپ کے باقی ریلے سے الگ رکھے جاتے ہیں، اور پروفائل ریلے کی فہرست کبھی شائع نہیں کی جاتی (kind 0)';

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
  String get relaySettingsStatusConnected => 'منسلک';

  @override
  String get relaySettingsStatusChecking => 'جانچ ہو رہی ہے';

  @override
  String get relaySettingsStatusUnreachable => 'رسائی ممکن نہیں';

  @override
  String get relaySettingsStatusNotChecked => 'جانچ نہیں ہوئی';

  @override
  String relaySettingsStatusSemantics(String status) {
    return 'ریلے کی حالت: $status';
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
  String get locationSettingsErrorSnack => 'کچھ غلط ہو گیا';

  @override
  String get locationSettingsIntro =>
      'جب بھی ایپ کھلی ہو، Haven آپ کا مقام آپ کے حلقوں کے ساتھ شیئر کرتا ہے۔ اسے آن کریں تو Haven کے پس منظر میں ہوتے ہوئے بھی آپ کے حلقے اسے دیکھتے رہیں گے۔ اگر سسٹم Haven کو بند کر دے تو شیئرنگ اُس وقت تک رکی رہتی ہے جب تک آپ ایپ دوبارہ نہ کھولیں۔ پس منظر میں ایپ صرف آپ کے حلقوں کے مقامات لانے کے لیے جاگتی ہے، آپ کا اپنا مقام کبھی نہیں بھیجتی۔';

  @override
  String get locationSettingsToggleTitle => 'پس منظر میں شیئر کریں';

  @override
  String get locationSettingsToggleSubtitle =>
      'Haven کے پس منظر میں چلتے ہوئے بھی شیئر کرتے رہیں';

  @override
  String get locationSettingsIosLimitedNote =>
      'آپ کی موجودہ اجازت کے ساتھ شیئرنگ پس منظر میں کام کرتی رہتی ہے۔ ترتیبات میں Haven کے لیے \'Always\' منتخب کریں تاکہ iOS کے ایپ بند کر دینے کے بعد Haven آپ کے حلقوں کے مقامات کی تازہ صورت حال بھی حاصل کر سکے۔ آپ کی اپنی شیئرنگ تو Haven دوبارہ کھولنے پر ہی بحال ہوتی ہے۔';

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
      'جب پس منظر میں شیئرنگ آن ہو تو Haven مقام کا ایک مسلسل سیشن جاری رکھتا ہے اور iOS اسٹیٹس بار میں ایک نیلا اشارہ دکھاتا ہے۔ \"Always\" کی اجازت دینے سے یہ اضافی سہولت ملتی ہے کہ iOS کے ایپ بند کر دینے کے بعد Haven آپ کے حلقوں کی تازہ صورت حال حاصل کر سکے۔';

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
  String get mapStylePreviewUnavailableSemantics =>
      'اس بلڈ میں نقشے کا پیش منظر دستیاب نہیں';

  @override
  String get mapStylePreviewUnavailableLabel =>
      'لائیو پیش منظر ریلیز بلڈز میں ظاہر ہوتا ہے';

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
  String get aboutVpnLinkLabel => 'mullvad.net';

  @override
  String get aboutFooterLicense => 'MIT License کے تحت لائسنس یافتہ';

  @override
  String aboutFooterVersion(String version) {
    return 'ورژن $version';
  }

  @override
  String get privacyTitle => 'رازداری';

  @override
  String get privacySubtitle =>
      'Haven کیسے کام کرتا ہے اور دوسرے کیا دیکھ سکتے ہیں';

  @override
  String get privacyHubSummary =>
      'Haven آپ کا مقام صرف انہی چھوٹے گروپوں کے ساتھ شیئر کرتا ہے جنہیں آپ منتخب کرتے ہیں اور جنہیں حلقے کہا جاتا ہے، اور فون سے نکلنے سے پہلے ہی اسے خفیہ کر دیتا ہے۔ نہ کوئی سائن اپ ہے اور نہ Haven کا کوئی سرور۔ عوامی صرف ایک چیز ہے: آپ کا مقرر کردہ ظاہری نام اور تصویر۔ نیچے دیے گئے صفحات یہ سب، اور باقی ہر بات، سادہ زبان میں بتاتے ہیں۔';

  @override
  String get privacyGroupBasicsHeading => 'بنیادی باتیں';

  @override
  String get privacyMeansForYouLabel => 'آپ کے لیے اس کا مطلب';

  @override
  String get privacyMoreDetailLabel => 'مزید تفصیل میں';

  @override
  String get privacyMoreDetailExpandHint => 'تکنیکی تفصیل دکھائیں';

  @override
  String get privacyMoreDetailCollapseHint => 'تکنیکی تفصیل چھپائیں';

  @override
  String get privacyMoreDetailExpandedAnnouncement => 'تکنیکی تفصیل ظاہر ہے';

  @override
  String get privacyMoreDetailCollapsedAnnouncement =>
      'تکنیکی تفصیل چھپی ہوئی ہے';

  @override
  String get privacyWhatHavenIsTitle => 'Haven کیا ہے، اور اکاؤنٹ کیوں نہیں';

  @override
  String get privacyWhatHavenIsSubtitle => 'نہ سائن اپ، نہ کمپنی کا سرور';

  @override
  String get privacyWhatHavenIsNoAccount =>
      'Haven آپ کا مقام انہی چھوٹے گروپوں کے ساتھ شیئر کرتا ہے جنہیں آپ منتخب کرتے ہیں؛ انہیں حلقے کہا جاتا ہے۔ اس کے پیچھے کوئی اکاؤنٹ نہیں ہوتا۔ آپ کبھی کوئی ای میل، فون نمبر یا پاس ورڈ نہیں دیتے۔';

  @override
  String get privacyWhatHavenIsNoServers =>
      'Haven اپنا کوئی سرور بھی نہیں چلاتا۔ آپ کے مقام کی خفیہ کردہ اپ ڈیٹس آزاد سرورز سے گزرتی ہیں جنہیں ریلے کہا جاتا ہے اور جنہیں دوسرے لوگ چلاتے ہیں۔ Haven کے ڈویلپرز آپ کا مقام نہیں دیکھ سکتے، اور انہوں نے ایپ میں کوئی ٹریکنگ نہیں رکھی۔ وہ صرف ایک چیز دیکھ سکتے ہیں: نقشے کا مجموعی استعمال کتنا ہے، کیونکہ نقشے کے ٹکڑے ایک ہی مشترکہ رسائی کلید سے لیے جاتے ہیں، اور یہ کبھی ظاہر نہیں ہوتا کہ انہیں کس نے لیا۔';

  @override
  String get privacyWhatHavenIsMeansForYou =>
      'کسی سے آپ کا ڈیٹا زبردستی نہیں لیا جا سکتا، کیونکہ کوئی اسے رکھے ہوئے نہیں ہے۔ اس کی قیمت یہ ہے کہ کوئی آپ کی شناخت آپ کے لیے بحال بھی نہیں کر سکتا۔ کس چیز کا بیک اپ لینا ہے، یہ جاننے کے لیے \"آپ کی دو کلیدیں\" دیکھیں۔';

  @override
  String get privacyWhatHavenIsDetailNoTelemetry =>
      'ایپ میں تجزیات، کریش رپورٹنگ یا اشتہارات کا کوئی کوڈ نہیں ہے۔ چونکہ Haven اوپن سورس ہے، اس لیے اسے صرف بھروسے پر لینے کے بجائے جانچا جا سکتا ہے۔';

  @override
  String get privacyWhatHavenIsDetailNoPush =>
      'Haven میں جان بوجھ کر پش اطلاعات بھی نہیں ہیں۔ کسی اطلاعاتی سروس کو ہر بار بتانا پڑتا کہ آپ کے حلقوں میں کسی کے پاس پہنچانے کے لیے کچھ ہے، اور یہ ریلے سے بھی زیادہ آپ کی عادتوں کو ظاہر کر دیتا۔';

  @override
  String get privacyYourKeysTitle =>
      'آپ کی دو کلیدیں: ایک خفیہ، ایک شیئر کرنے کے لیے';

  @override
  String get privacyYourKeysSubtitle =>
      'آپ کی شناخت کیا ہے، اور بیک اپ کس چیز کا لینا ہے';

  @override
  String get privacyYourKeysWhatTheyAre =>
      'صارف نام اور پاس ورڈ کی جگہ آپ کے پاس کلیدوں کا ایک جوڑا ہوتا ہے۔ خفیہ کلید ثابت کرتی ہے کہ آپ ہی آپ ہیں۔ عوامی کلید وہ ہے جس سے دوسرے آپ کو ڈھونڈتے اور مدعو کرتے ہیں۔';

  @override
  String get privacyYourKeysSecretStaysHere =>
      'آپ کی خفیہ کلید صرف اسی فون پر رکھی جاتی ہے، اُس ذخیرے میں جس کی حفاظت آپریٹنگ سسٹم کرتا ہے۔ Haven اسے کبھی کہیں نہیں بھیجتا: نہ کسی سرور کو، نہ ہمیں۔';

  @override
  String get privacyYourKeysPublicIsSafe =>
      'آپ کی عوامی کلید دوسروں کو دینا محفوظ ہے۔ یہ ایک ایسے صارف نام کی طرح کام کرتی ہے جسے آپ کہیں بھی شائع کر سکتے ہیں۔ اسے شیئر کرنے سے یہ ظاہر نہیں ہو سکتا کہ آپ کہاں ہیں۔';

  @override
  String get privacyYourKeysMeansForYou =>
      'یہ شناخت برقرار رکھنے کے لیے اس کا بیک اپ لیں۔ ترتیبات ← شناخت ← اعلیٰ میں جائیں، \"خفیہ کلید ظاہر کریں\" پر ٹیپ کریں، اور اسے کسی محفوظ جگہ، مثلاً پاس ورڈ مینیجر میں، محفوظ کر لیں۔ اس بیک اپ کے بغیر، فون کھونے کا مطلب شناخت ہمیشہ کے لیے کھو دینا ہے۔';

  @override
  String get privacyYourKeysNeverShareSecret =>
      'جس کسی کو آپ کی خفیہ کلید مل جائے، وہ آپ بن جاتا ہے۔ وہ آپ بن کر حلقوں میں شامل ہو سکتا ہے یا آپ کے نام سے شائع کر سکتا ہے۔ اسے کبھی کسی دوسری ایپ، کسی پیغام یا کسی ویب سائٹ میں چسپاں نہ کریں۔';

  @override
  String get privacyYourKeysDetailFormats =>
      'دونوں کلیدیں secp256k1 ہیں، جو معیاری Nostr صورتوں میں دکھائی جاتی ہیں: عوامی کلید npub1 سے شروع ہوتی ہے اور خفیہ کلید nsec1 سے۔ دستخط ایپ کے اندر ہوتے ہیں، اور خفیہ کلید استعمال ہوتے ہی اُن حصوں سے صاف کر دی جاتی ہے جو براہِ راست اسے سنبھالتے ہیں۔';

  @override
  String get privacyYourKeysDetailSeparation =>
      'جو کلیدیں آپ کے حلقوں کے پیغامات خفیہ کرتی ہیں وہ اس شناختی کلید سے الگ ہیں، اور انہیں صرف ایپ رکھتی ہے۔ یہ علیحدگی جان بوجھ کر ہے: جو کلید آپ کا نام بتاتی ہے وہ کلید نہیں جو آپ کے بھیجے ہوئے کو کھولتی ہے۔';

  @override
  String get privacyPublicProfileTitle => 'آپ کا نام اور تصویر عوامی ہیں';

  @override
  String get privacyPublicProfileSubtitle =>
      'کسی کو بھی نظر آتے ہیں، صرف آپ کے حلقوں کو نہیں';

  @override
  String get privacyPublicProfileIsPublic =>
      'آپ کا مقرر کردہ ظاہری نام اور تصویر Nostr پر شائع ہوتے ہیں، یعنی اُس کھلے عوامی نیٹ ورک پر جس پر Haven چلتا ہے۔ انہیں کوئی بھی تلاش کر سکتا ہے، صرف آپ کے حلقوں کے لوگ نہیں۔';

  @override
  String get privacyPublicProfileOnSave =>
      'آپ کا نام اور تصویر اُسی لمحے عوامی ہو جاتے ہیں جب آپ انہیں محفوظ کرتے ہیں۔ کوئی ایسی ترتیب موجود نہیں جو انہیں نجی رکھے، اور نہ کوئی ایسا طریقہ ہے کہ نام صرف اپنے حلقوں کے ساتھ شیئر کیا جائے۔';

  @override
  String get privacyPublicProfilePseudonym =>
      'نئی تنصیبات ایک فرضی نام سے شروع ہوتی ہیں، جیسے \"Quiet Wanderer\"، جو آپ کے بارے میں کچھ نہیں بتاتا۔ آپ اسے رکھ سکتے ہیں، یا جو چاہیں اس سے بدل سکتے ہیں۔';

  @override
  String get privacyPublicProfileMeansForYou =>
      'ایسا نام اور تصویر منتخب کریں جنہیں عوامی طور پر دکھانے میں آپ خوش ہوں۔ اگر آپ پہچانے جانا نہیں چاہتے تو جو فرضی نام آپ کو ملا ہے وہی رکھیں اور تصویر چھوڑ دیں۔';

  @override
  String get privacyPublicProfileRemovalIsNotDeletion =>
      'بعد میں اپنی تصویر ہٹانے سے سرور پر موجود نقل حذف نہیں ہوتی۔ Haven آپ کے پروفائل کی جگہ ایک خالی پروفائل رکھ دیتا ہے۔ تصویر کی فائل جہاں میزبانی پا رہی ہے وہیں رہتی ہے، اور جو نقل پہلے ہی ڈاؤن لوڈ ہو چکی ہو وہ باہر ہی رہتی ہے۔ جو کچھ آپ شائع کریں اسے مستقل سمجھیں۔';

  @override
  String get privacyPublicProfileDetailKindZero =>
      'پروفائل Nostr کا ایک \"kind 0\" ایونٹ ہے جس پر آپ کی شناختی کلید سے دستخط ہوتے ہیں۔ تصاویر ایک عوامی تصویری میزبان، یعنی blossom.primal.net، پر اپ لوڈ ہوتی ہیں، جو تصویر، آپ کی عوامی کلید اور آپ کا نیٹ ورک پتہ دیکھتا ہے۔ Haven ابھی تک آپ کو کوئی دوسرا میزبان چننے نہیں دیتا۔';

  @override
  String get privacyPublicProfileDetailExifStripped =>
      'اپ لوڈ سے پہلے Haven تصویر کو دوبارہ انکوڈ کرتا ہے اور وہ پوشیدہ ڈیٹا ہٹا دیتا ہے جو کیمرے ساتھ لگا دیتے ہیں، بشمول وہ GPS مقام جہاں تصویر لی گئی تھی۔ یہ بات یہاں اہم ہے: ورنہ چھٹیوں کی ایک تصویر آپ کے گھر کے کوآرڈینیٹس ساتھ لے جا سکتی ہے۔';

  @override
  String get privacyGroupHowLocationTravelsHeading =>
      'آپ کا مقام کیسے سفر کرتا ہے';

  @override
  String get privacyRelaysTitle => 'ریلے: وہ سرور جو پیغامات آگے پہنچاتے ہیں';

  @override
  String get privacyRelaysSubtitle =>
      'آپ کی اپ ڈیٹس کن لوگوں کے کمپیوٹروں سے گزرتی ہیں';

  @override
  String get privacyRelaysWhatIsARelay =>
      'Haven کا اپنا کوئی سرور نہیں، اس لیے آپ کی اپ ڈیٹس دوسرے لوگوں کے سرورز سے گزرتی ہیں۔ انہیں ریلے کہا جاتا ہے: چھوٹے، آزاد سرور جنہیں کوئی بھی چلا سکتا ہے۔ ریلے کسی خفیہ کردہ پیغام کو تھوڑی دیر رکھتا ہے، پھر جب آپ کا حلقہ مانگے تو آگے پہنچا دیتا ہے۔';

  @override
  String get privacyRelaysWhyMany =>
      'Haven کئی ریلے استعمال کرتا ہے، چنانچہ کوئی ایک بھی آپ کو کاٹ نہیں سکتا۔ ایک آف لائن ہو جائے تو باقی کام کرتے رہتے ہیں۔ آپ وہ ریلے چنتے ہیں جہاں دعوت نامے آپ تک پہنچتے ہیں؛ کوئی حلقہ جو ریلے استعمال کرتا ہے، وہ اس حلقے کے بننے کے وقت طے ہو جاتے ہیں۔';

  @override
  String get privacyRelaysYourLists =>
      'Haven آپ کے لیے تین فہرستیں رکھتا ہے۔ اِن باکس ریلے وہ ہیں جہاں دعوت نامے آپ تک پہنچتے ہیں، اور KeyPackage ریلے وہ ہیں جہاں سے لوگ وہ کلیدیں لیتے ہیں جو آپ کو مدعو کرنے کے لیے درکار ہوتی ہیں — Haven یہ دونوں فہرستیں شائع کرتا ہے تاکہ دوسرے انہیں ڈھونڈ سکیں۔ آپ کے پروفائل ریلے اِن سے مختلف ہیں: وہیں آپ کا نام اور تصویر تلاش اور شائع کیے جاتے ہیں، لیکن فہرست خود آپ کے آلے پر ہی رہتی ہے اور کبھی شائع نہیں کی جاتی۔ چنانچہ جو ریلے صرف آپ کے مقام کا ٹریفک یا دعوت نامے لے جاتا ہے، اس کے پاس کوئی عوامی فہرست نہیں جو اسے بتائے کہ آپ اپنے پروفائل کے لیے کون سے ریلے استعمال کرتے ہیں۔ ہر حلقہ اپنی الگ فہرست بھی رکھتا ہے، اور حلقے کی خفیہ کردہ اپ ڈیٹس اسی فہرست سے سفر کرتی ہیں۔';

  @override
  String get privacyRelaysMeansForYou =>
      'ریلے آپ کا مقام کبھی نہیں دیکھتا، کیونکہ وہ فون سے نکلنے سے پہلے ہی خفیہ ہو چکا ہوتا ہے۔ البتہ وہ سب کچھ دیکھتا ہے جس کا عوامی ہونا ضروری ہے تاکہ لوگ آپ تک پہنچ سکیں: آپ کا نام اور تصویر، وہ کلیدیں جو دوسروں کو آپ کو مدعو کرنے کے لیے درکار ہوتی ہیں، اور خود آپ کی ریلے فہرست۔ Haven آپ کو کام کرتے ہوئے ریلے کے ساتھ شروع کراتا ہے، اس لیے آپ کو کچھ بدلنے کی ضرورت نہیں۔';

  @override
  String get privacyRelaysDetailIndexers =>
      'آپ کی اپنی فہرستوں سے الگ، Haven دوسروں کے پروفائل اور کلیدیں ڈھونڈنے کے لیے چند عوامی ڈائریکٹری ریلے سے استفسار کرتا ہے۔ چاہے آپ نے صرف اپنے نجی ریلے ہی مقرر کیے ہوں، پھر بھی یہ ان سے رابطہ کرتا ہے۔ وہ آپ کا نیٹ ورک پتہ اور یہ دیکھتے ہیں کہ آپ نے کن اکاؤنٹس کے بارے میں پوچھا۔';

  @override
  String get privacyRelaysDetailKeyListIsPublic =>
      'آپ کی KeyPackage ریلے فہرست پر آپ کی شناختی کلید سے دستخط ہوتے ہیں، اور وہ انہی ریلے پر شائع کی جاتی ہے جو پہلے سے اس میں شامل ہیں۔ اگر آپ اس میں کوئی نجی ریلے شامل کریں تو اس کا پتہ عوامی ہو جاتا ہے اور آپ سے جڑ جاتا ہے۔ اس فہرست میں کسی ریلے کو نجی رکھنے کا کوئی طریقہ نہیں۔';

  @override
  String get privacyEncryptionTitle => 'خفیہ کاری کیسے کام کرتی ہے';

  @override
  String get privacyEncryptionSubtitle =>
      'ہر حلقے کے لیے ایک کلید، اور لوگوں کے شامل ہونے یا نکلنے پر کیا بدلتا ہے';

  @override
  String get privacyEncryptionPerCircle =>
      'آپ کا مقام فون سے نکلنے سے پہلے ہی، MLS نامی ایک کھلے معیار سے خفیہ کر دیا جاتا ہے۔ ہر حلقہ اپنی الگ کلیدوں کے ساتھ اپنا ایک خفیہ گروہ ہے۔ حلقے سے باہر کوئی بھی یہ نہیں پڑھ سکتا کہ اس کے اندر کیا بھیجا جاتا ہے: نہ کوئی ریلے، نہ خود Haven اور نہ آپ کا کوئی دوسرا حلقہ۔';

  @override
  String get privacyEncryptionWhenSomeoneJoins =>
      'جب کوئی شامل ہوتا ہے تو حلقہ ایک نئی کلید پر منتقل ہو جاتا ہے۔ وہ اپنے آنے کے بعد بھیجی گئی باتیں پڑھ سکتا ہے، اس سے پہلے کی کوئی نہیں۔ Haven کسی نئے رکن کو گزرے ہوئے مقامات ہرگز نہیں بھیجتا۔';

  @override
  String get privacyEncryptionWhenSomeoneLeaves =>
      'جب کوئی حلقہ چھوڑتا ہے تو وہ حلقہ ایک اور نئی کلید پر منتقل ہو جاتا ہے۔ جیسے ہی حلقے کے باقی ارکان اس تبدیلی کے ساتھ ہم آہنگ ہو جاتے ہیں، وہ کوئی نئی چیز نہیں پڑھ سکتا؛ عام طور پر اس میں چند منٹ لگتے ہیں، اور جو اُس وقت آف لائن تھا اس کے لیے کچھ زیادہ۔';

  @override
  String get privacyEncryptionKeysChangeOnMembership =>
      'کوئی حلقہ چھوڑ دینے سے وہ سب واپس نہیں آتا جو اس کے ارکان پہلے ہی محفوظ کر چکے ہیں۔ Haven کلیدیں صرف اُس وقت بدلتا ہے جب کوئی شامل ہو یا نکل جائے، کسی مقررہ وقفے پر کبھی نہیں۔ چنانچہ ایک ہی کلید ہفتوں کے پیغامات پر محیط ہو سکتی ہے، اور اُس عرصے میں کسی رکن نے جو کچھ محفوظ کیا ہو وہ اس کے لیے پڑھنے کے قابل رہتا ہے۔ پھر بھی وہ ایسی کوئی چیز نہیں کھول سکتا جو اس کے نکلنے کے بعد بھیجی گئی ہو۔';

  @override
  String get privacyEncryptionMeansForYou =>
      'خفیہ کاری آپ کو ہر اُس شخص سے بچاتی ہے جو آپ کے حلقوں سے باہر ہے۔ یہ آپ کو اُس شخص سے نہیں بچا سکتی جو کبھی کسی حلقے کے اندر رہا ہو۔ کسی خاص شخص کے ساتھ شیئر کرنا بند کرنے کے لیے، جس حلقے میں آپ اس کے ساتھ شیئر کرتے ہیں اسے چھوڑ دیں اور اس کے بغیر ایک نیا حلقہ شروع کریں۔';

  @override
  String get privacyEncryptionDetailMls =>
      'MLS (Messaging Layer Security) وہی IETF معیار ہے جو دوسرے محفوظ پیغام رساں بھی استعمال کرتے ہیں۔ Nostr نیٹ ورک تک Haven کی رسائی Marmot پروٹوکول کے ذریعے ہوتی ہے، اور یہی پروٹوکول طے کرتا ہے کہ MLS گروہ ریلے کے اوپر سے کیسے گزرتے ہیں۔ جس کلید سے ہر حلقہ دستخط کرتا ہے، وہ آپ کی عوامی Nostr شناختی کلید سے الگ ہے۔';

  @override
  String get privacyEncryptionDetailEpochs =>
      'جس مدت تک ایک کلید کارآمد رہتی ہے، اسے ایک \"دور\" کہا جاتا ہے، اور حلقہ نئے دور میں صرف اُس وقت جاتا ہے جب اس کے ارکان بدلیں۔ آپ کا آلہ موجودہ دور اور چند حالیہ دوروں کی کلیدیں رکھتا ہے، اتنی جتنی راستے میں موجود پیغامات کھولنے کے لیے کافی ہوں، اور باقی پھینک دیتا ہے۔ جس حلقے کے ارکان مہینوں سے نہیں بدلے، وہ آج بھی اُسی دور پر ہے جس سے اس کا آغاز ہوا تھا۔';

  @override
  String get privacyWhatOthersSeeTitle =>
      'ارکان کیا دیکھتے ہیں، اور ریلے کیا دیکھتے ہیں';

  @override
  String get privacyWhatOthersSeeSubtitle =>
      'وہ لوگ جن کے ساتھ آپ شیئر کرتے ہیں، اور درمیان کے سرور';

  @override
  String get privacyWhatOthersSeeMembersHeading => 'آپ کے حلقوں کے لوگ';

  @override
  String get privacyWhatOthersSeeMembersExact =>
      'حلقے میں شامل ہر شخص نقشے پر آپ کا بالکل درست مقام دیکھتا ہے، کوئی سرسری علاقہ نہیں۔ کوئی ایسی ترتیب موجود نہیں جو کچھ ارکان کے ساتھ مبہم مقام اور کچھ کے ساتھ درست مقام شیئر کرے۔';

  @override
  String get privacyWhatOthersSeeCannotPause =>
      'جب تک Haven کھلا ہے اور آپ کسی حلقے میں ہیں، آپ کا مقام ہر دو تین منٹ بعد خود ہی چلا جاتا ہے۔ عارضی طور پر روکنے کا کوئی بٹن نہیں ہے: \"مقام\" کے صفحے پر موجود سوئچ صرف یہ طے کرتا ہے کہ ایپ بند کرنے کے بعد یہ سلسلہ جاری رہے یا نہیں۔ کسی حلقے کے ساتھ شیئر کرنا بند کرنے کے لیے، اسے کھولیں اور \"حلقہ چھوڑیں\" منتخب کریں۔';

  @override
  String get privacyWhatOthersSeeMembersLearnKey =>
      'کسی حلقے میں شامل ہونے سے ہر رکن کو آپ کی عوامی کلید بھی دکھ جاتی ہے۔ اس کے ذریعے وہ آپ کا عوامی پروفائل، اور جو کچھ بھی آپ نے کبھی اس کلید کے تحت شائع کیا ہو، تلاش کر سکتے ہیں۔';

  @override
  String get privacyWhatOthersSeeCoMemberIp =>
      'آپ کا فون ہر رکن کی پروفائل تصویر اُس سرور سے ڈاؤن لوڈ کرتا ہے جو اُس رکن نے چنا ہو، اور اس کے لیے آپ کو کچھ ٹیپ نہیں کرنا پڑتا۔ پھر وہ سرور آپ کا نیٹ ورک پتہ دیکھ لیتا ہے، جو آپ کو نقشے پر تقریباً رکھ دیتا ہے۔ VPN اسے چھپا دیتا ہے؛ اس کے سوا کوئی چیز نہیں چھپاتی۔';

  @override
  String get privacyWhatOthersSeeRelaysHeading => 'ریلے چلانے والے';

  @override
  String get privacyWhatOthersSeeRelaysCannot =>
      'ریلے، یعنی وہ آزاد سرور جن سے آپ کی اپ ڈیٹس گزرتی ہیں، آپ کا مقام، آپ کے پیغامات، آپ کے حلقے کا نام یا اس کے ارکان کی فہرست نہیں پڑھ سکتے۔ آپ کے مقام کی اپ ڈیٹس آپ کی عوامی کلید کے بجائے ایک تازہ اور صرف ایک بار استعمال ہونے والا بھیجنے والے کا پتہ ساتھ لے جاتی ہیں۔ مگر آپ کا پروفائل، دعوت نامے اور ریلے فہرستیں وہی عوامی کلید ساتھ لے جاتی ہیں، چنانچہ جس ریلے سے یہ دونوں گزریں وہ اکثر جان لیتا ہے کہ آپ کسی حلقے میں ہیں، بغیر اس کے اندر کا کچھ پڑھے۔';

  @override
  String get privacyWhatOthersSeeRelaysCan =>
      'وہ آپ کا نیٹ ورک پتہ، آپ کے آن لائن ہونے کے اوقات، اور آپ کے ٹریفک کا حجم اور تعدد ضرور دیکھتے ہیں۔ ہر حلقے کے ساتھ ایک بے ترتیب ٹیگ ہوتا ہے۔ ریلے اسی ٹیگ کی بنیاد پر ایک ہی حلقے کے پیغامات ایک جگہ جوڑ سکتا ہے اور اندازہ لگا سکتا ہے کہ اس میں کتنے لوگ ہیں، بغیر یہ جانے کہ وہ کون ہیں۔';

  @override
  String get privacyWhatOthersSeeMeansForYou =>
      'کسی حلقے میں صرف اُنہی لوگوں کے ساتھ شامل ہوں جنہیں آپ اپنے گھر کا پتہ دے دیں۔ ریلے اور باہر والوں کے سامنے خفیہ کاری قائم رہتی ہے، اور VPN وہ نیٹ ورک پتہ چھپا دیتا ہے جہاں سے آپ کا فون جڑتا ہے۔ اُس رکن سے کوئی چیز آپ کو نہیں بچاتی جو اسکرین شاٹ لے لے۔';

  @override
  String get privacyWhatOthersSeeDetailTag =>
      'کسی حلقے کا ٹیگ اُس حلقے کی پوری عمر ایک ہی رہتا ہے، چنانچہ ریلے اس کے سارے پیغامات غیر معینہ مدت تک آپس میں جوڑ سکتا ہے۔ یہ بنیادی پروٹوکول کی ایک خصوصیت ہے، ایسی چیز نہیں جسے Haven بدل سکے۔';

  @override
  String get commonLearnMore => 'مزید جانیں';

  @override
  String get relaySettingsBackendCaption =>
      'Haven کا اپنا کوئی سرور نہیں۔ آپ کی خفیہ کردہ اپ ڈیٹس آزاد سرورز سے گزرتی ہیں جنہیں ریلے کہا جاتا ہے، اور یہ نہ آپ کا مقام پڑھ سکتے ہیں نہ آپ کے پیغامات۔';

  @override
  String get privacyWhatOthersSeeScreenshots =>
      'یہ آپ کے فون پر منحصر ہے۔ Android پر Haven پوری ایپ میں اسکرین شاٹ اور اسکرین ریکارڈنگ روک دیتا ہے۔ iPhone پر ایسا نہیں ہو سکتا: Haven ایپ سوئچر کا پیش منظر دھندلا کر دیتا ہے، مگر کوئی رکن پھر بھی اسکرین پر نظر آنے والی چیز کی تصویر لے سکتا ہے۔';

  @override
  String get privacyWhatOthersSeeDetailExpiry =>
      'Haven ریلے سے کہتا ہے کہ مقام کے پیغامات تقریباً چار منٹ بعد گرا دیں۔ یہ درخواست صرف ایک مشورہ ہے: ریلے انہیں زیادہ دیر رکھنے میں آزاد ہے۔ دعوت ناموں پر کوئی مدتِ انقضا ہی نہیں ہوتی، اور وہ آپ کے اِن باکس ریلے پر غیر معینہ مدت تک پڑے رہ سکتے ہیں۔';

  @override
  String get privacyGroupTheLimitsHeading => 'حفاظت کی حدود';

  @override
  String get privacyInferenceTitle =>
      'آپ کے بارے میں پھر بھی کیا معلوم ہو سکتا ہے';

  @override
  String get privacyInferenceSubtitle =>
      'وہ نشانات جو خفیہ کاری نہیں چھپا سکتی';

  @override
  String get privacyInferenceWhatIsMetadata =>
      'خفیہ کاری یہ چھپا دیتی ہے کہ آپ کیا بھیجتے ہیں۔ مگر یہ نہیں چھپا سکتی کہ آپ نے کچھ بھیجا ہے۔ اس بچے ہوئے نشان کو میٹا ڈیٹا کہا جاتا ہے: پیغام کب گیا، کتنا بڑا تھا، اور آپ کن سرورز سے جڑے ہوئے تھے۔ مواد نظر نہ آنے کے باوجود یہ نشان نظر آتا رہتا ہے۔';

  @override
  String get privacyInferenceActivityPattern =>
      'اُسی نمونے سے، جو ریلے آپ استعمال کرتے ہیں وہ تقریباً بتا سکتا ہے کہ آپ کب سرگرم ہوتے ہیں اور کتنی بار۔ جب بھی آپ تقریباً سو میٹر حرکت کریں، Haven ایک اضافی اپ ڈیٹ بھی بھیجتا ہے۔ کئی گھنٹوں میں یہ کسی ریلے پر ظاہر کر سکتا ہے کہ آپ سفر میں تھے یا ایک ہی جگہ ٹھہرے ہوئے۔ یہ کبھی ظاہر نہیں کرتا کہ کہاں۔';

  @override
  String get privacyInferencePresence =>
      'جب تک Haven چل رہا ہے، وہ آپ کے ریلے سے ایک کھلا کنکشن قائم رکھتا ہے۔ وہ دیکھ سکتے ہیں کہ آپ آن لائن ہیں اور آپ کن حلقوں کے ٹیگ دیکھ رہے ہیں، مگر کسی حلقے کا نام یا اس میں کون ہے، یہ کبھی نہیں۔ اپ ڈیٹس منٹوں کے بجائے سیکنڈوں میں پہنچنے کی قیمت یہی ہے۔';

  @override
  String get privacyInferenceIpHeading => 'آپ کا نیٹ ورک پتہ';

  @override
  String get privacyInferenceIpAddress =>
      'ہر وہ سرور جس سے Haven بات کرتا ہے، وہ پتہ دیکھتا ہے جہاں سے آپ کا فون جڑتا ہے، یعنی اس کا IP پتہ: آپ کے ریلے، نقشے کا فراہم کنندہ، اور جو بھی کسی رکن کی پروفائل تصویر کی میزبانی کرتا ہو۔ آپ کا انٹرنیٹ فراہم کنندہ یہ دیکھتا ہے کہ آپ ان میں سے کن سرورز تک پہنچے، اور کب۔ Haven خود سے ان دونوں میں سے کسی کو چھپانے کے لیے کچھ نہیں کرتا۔';

  @override
  String get privacyInferenceMapTilesHeading => 'خود نقشہ';

  @override
  String get privacyInferenceMapTiles =>
      'نقشہ بنانے کے لیے Haven اسکرین پر نظر آنے والی تصویر کے چوکور ٹکڑے نقشے کے فراہم کنندہ سے مانگتا ہے، چنانچہ اسے تقریباً معلوم ہو جاتا ہے کہ آپ کن جگہوں کو دیکھتے ہیں۔ آپ جن ارکان کو دیکھ سکتے ہیں، Haven اُن میں سے ہر ایک کے آس پاس کا ایک چھوٹا سا علاقہ بھی آپ کے وہاں پہنچنے سے پہلے ہی منگوا لیتا ہے تاکہ نقشہ تیار ہو۔ اس کا مطلب یہ ہے کہ فراہم کنندہ صرف یہ نہیں جان سکتا کہ آپ کہاں دیکھ رہے ہیں، بلکہ یہ بھی کہ آپ کے حلقے کے لوگ تقریباً کہاں ہیں۔ یہ ٹکڑے آپ کے فون پر ایک خفیہ کردہ عارضی ذخیرے میں زیادہ سے زیادہ سات دن تک رہتے ہیں، اور اگر آپ اپنی شناخت حذف کریں تو یہ بھی مٹا دیے جاتے ہیں۔';

  @override
  String get privacyInferenceVpnHeading => 'کیا آپ کو VPN کی ضرورت ہے؟';

  @override
  String get privacyInferenceVpnHelps =>
      'VPN آپ کے نیٹ ورک پتے کی جگہ اپنا پتہ استعمال کرتا ہے، چنانچہ ریلے اور دوسرے سرورز یہ نہیں دیکھ پاتے کہ آپ کہاں سے جڑتے ہیں۔ یہ آپ کے انٹرنیٹ فراہم کنندہ سے یہ بھی چھپا دیتا ہے کہ آپ کن سرورز تک پہنچتے ہیں۔ ہم Mullvad کی سفارش کرتے ہیں۔';

  @override
  String get privacyInferenceVpnLimits =>
      'یہ ہر مسئلے کا حل نہیں ہے۔ VPN اس میں کوئی تبدیلی نہیں لاتا جو آپ کے حلقہ ارکان دیکھتے ہیں، اور یہ آپ کے ٹریفک کا وقت اور حجم اُس ریلے سے نہیں چھپاتا جس سے آپ بات کر رہے ہوتے ہیں۔ یہ آپ کے بھروسے کو VPN کمپنی کی طرف منتقل بھی کر دیتا ہے، یہ نہیں کہ کسی پر بھروسہ کرنے کی ضرورت ہی ختم ہو جائے۔';

  @override
  String get privacyInferenceMeansForYou =>
      'کیا آپ کو ریلے، اپنے انٹرنیٹ فراہم کنندہ، یا نقشے کے سرورز سے یہ فکر ہے کہ وہ آپ کو نقشے پر رکھ دیں گے؟ تو VPN سب سے کارآمد چیز ہے جو آپ شامل کر سکتے ہیں۔ کیا آپ کو اپنے حلقوں کے لوگوں کی فکر ہے؟ تو یہ ذرا بھی مدد نہیں کرے گا۔';

  @override
  String get privacyInferenceDetailJitter =>
      'Haven جان بوجھ کر اپ ڈیٹس کے درمیان وقفہ بدلتا رہتا ہے، چنانچہ کسی مختصر ریکارڈنگ میں کوئی صاف تال نظر نہیں آتی۔ مگر کئی گھنٹوں کا اوسط نکالا جائے تو اپ ڈیٹس کی بنیادی رفتار کا اندازہ پھر بھی لگایا جا سکتا ہے۔ پیغامات کے حجم کو اضافی ڈیٹا سے یکساں بھی نہیں کیا جاتا۔ مقام کی اپ ڈیٹس کا حجم ایک تنگ حد کے اندر رہتا ہے، جس سے انہیں مقام کی اپ ڈیٹس کے طور پر پہچانا جا سکتا ہے۔';

  @override
  String get privacyInferenceDetailOutOfScope =>
      'دو چیزیں یہاں کے کسی بھی ڈیزائن فیصلے سے باہر ہیں: ایک ایسا مشاہدہ کرنے والا جو بیک وقت کئی ریلے دیکھ سکے، اور آپ کا اپنا فون جب اس پر کسی اور کا قبضہ ہو جائے۔';

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
      'ارکان شامل کرنے کے لیے ID سے تلاش کریں یا ان کا QR کوڈ اسکین کریں۔';

  @override
  String get createCircleNoValidMembers =>
      'دعوت دینے کے لیے کوئی درست رکن نہیں';

  @override
  String get createCircleMemberAlreadyAdded => 'رکن پہلے ہی شامل ہے';

  @override
  String get createCircleNoIdInQr => 'QR کوڈ میں کوئی درست ID نہیں ملی';

  @override
  String get createCircleNoAccountFound =>
      'اس ID کے لیے کوئی Haven اکاؤنٹ نہیں ملا';

  @override
  String get createCircleCouldNotVerify => 'رکن کی توثیق نہ ہو سکی';

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
  String get nameCircleStageSendingInvites => 'دعوت نامے بھیجے جا رہے ہیں...';

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
  String addMemberPartialDelivery(int sent, int total) {
    final intl.NumberFormat sentNumberFormat = intl.NumberFormat.decimalPattern(
      localeName,
    );
    final String sentString = sentNumberFormat.format(sent);
    final intl.NumberFormat totalNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String totalString = totalNumberFormat.format(total);

    return 'دعوت نامے بھیج دیے گئے ($totalString میں سے $sentString)۔ باقی کی ترسیل زیر التوا ہے۔';
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
  String get circleMemberInvitationPending => 'دعوت زیر التوا';

  @override
  String get circleMemberNoRecentLocation => 'کوئی حالیہ مقام نہیں';

  @override
  String get circleMemberRemoveTooltip => 'حلقے سے ہٹائیں';

  @override
  String get circleMemberAdmin => 'منتظم';

  @override
  String get circleMemberHintPending => 'دعوت زیر التوا';

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
  String get pendingMemberNeedsUpdate => 'Haven کو اپ ڈیٹ کرنے کی ضرورت ہے';

  @override
  String get memberSearchHint => 'رکن کی ID درج کریں...';

  @override
  String get memberSearchPasteTooltip => 'کلپ بورڈ سے چسپاں کریں';

  @override
  String get memberSearchAddTooltip => 'رکن شامل کریں';

  @override
  String get memberSearchScanTooltip => 'QR کوڈ اسکین کریں';

  @override
  String get memberSearchHelper => 'رابطوں سے ان کا Haven QR کوڈ یا ID مانگیں';

  @override
  String get memberSearchNoValidId => 'کوئی درست Haven ID نہیں ملی';

  @override
  String get memberSearchAlreadyAdded => 'رکن پہلے ہی شامل ہے';

  @override
  String selectedMembersMore(int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    return '+$countString مزید';
  }

  @override
  String get invitationStatusPending => 'دعوت زیر التوا';

  @override
  String get invitationStatusActive => 'فعال';

  @override
  String get invitationStatusDeclined => 'مسترد';

  @override
  String invitationStatusSemantics(String label) {
    return 'دعوت کی حالت: $label';
  }

  @override
  String invitationCardSemantics(String circleName, String inviter, int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    return '$circleName میں شامل ہونے کی دعوت، $inviter کی جانب سے، $countString ارکان';
  }

  @override
  String invitationCardInvitedBySemantics(String inviter) {
    return 'رمزی شناخت کنندہ $inviter کی جانب سے دعوت';
  }

  @override
  String invitationCardInvitedBy(String inviter) {
    return 'دعوت دینے والا: $inviter';
  }

  @override
  String invitationCardMemberCount(int count) {
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
  String get invitationCardJustNow => 'ابھی ابھی';

  @override
  String invitationCardDaysAgo(int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    return '${countString}d ago';
  }

  @override
  String invitationCardHoursAgo(int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    return '${countString}h ago';
  }

  @override
  String invitationCardMinutesAgo(int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    return '${countString}m ago';
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
  String get circleDetailsRelaysHeading => 'اس حلقے کے ریلے';

  @override
  String get circleDetailsNoRelays => '(کوئی درج نہیں)';

  @override
  String get circleDetailsRelaysNote =>
      'یہ ریلے اس حلقے کے بننے کے وقت آپ کے اِن باکس ریلے سے نقل کیے گئے تھے، اور ابھی انہیں بدلا نہیں جا سکتا۔ آپ کی ذاتی ریلے فہرست میں بعد کی ترامیم انہیں تبدیل نہیں کرتیں۔';

  @override
  String get circleDetailsAddMember => 'رکن شامل کریں';

  @override
  String get circleDetailsLeaveCircle => 'حلقہ چھوڑیں';

  @override
  String get leaveCircleDialogTitle => 'حلقہ چھوڑیں';

  @override
  String get leaveCircleDialogBody =>
      'یہ حلقہ چھوڑ دیں؟ آپ اس کے ارکان کو اپنا مقام بھیجنا اور ان کا مقام دیکھنا بند کر دیں گے۔ آپ نے آخری بار جو مقام بھیجا وہ ایک دن تک ان کے فونوں پر رہتا ہے۔ اسے واپس نہیں کیا جا سکتا: دوبارہ شامل ہونے کے لیے آپ کو نئی دعوت درکار ہوگی۔';

  @override
  String get leaveCircleConfirm => 'چھوڑیں';

  @override
  String get leaveCircleIdentityUnavailable => 'شناخت دستیاب نہیں';

  @override
  String get leaveCircleSuccess => 'حلقہ کامیابی سے چھوڑ دیا گیا';

  @override
  String get leaveCircleError => 'حلقہ چھوڑنے میں ناکامی';

  @override
  String get circleBlockedBannerTitle => 'یہ حلقہ اپ ڈیٹ نہیں کیا جا سکتا';

  @override
  String get circleBlockedBannerBody =>
      'اس حلقے کی خفیہ کاری میں کچھ گڑبڑ ہو گئی، اس لیے Haven اب اس میں نہ تو اپ ڈیٹس بھیج سکتا ہے اور نہ وصول کر سکتا ہے۔ آپ پھر بھی نیچے اپنی آخری معلوم صورتحال دیکھ سکتے ہیں، یا حلقہ چھوڑ سکتے ہیں۔';

  @override
  String get legacyCircleBannerTitle => 'اس حلقے کو دوبارہ بنانا ضروری ہے';

  @override
  String get legacyCircleBannerBody =>
      'Haven کے خفیہ کاری کے نظام کو اپ گریڈ کر دیا گیا ہے، اس لیے یہ حلقہ اب استعمال نہیں کیا جا سکتا۔ انہی لوگوں کے ساتھ مقام شیئر کرتے رہنے کے لیے اسے دوبارہ بنائیں۔ آپ کو انہیں دوبارہ دعوت دینی ہوگی۔';

  @override
  String get legacyCircleRecreateCta => 'حلقہ دوبارہ بنائیں';

  @override
  String get legacyCircleRemoveCta => 'ہٹائیں';

  @override
  String get legacyCircleRemoveDialogTitle => 'حلقہ ہٹائیں؟';

  @override
  String get legacyCircleRemoveDialogBody =>
      'یہ حلقہ اب استعمال نہیں کیا جا سکتا اور آپ کی فہرست سے ہٹا دیا جائے گا۔ اس کی جگہ آپ جو بھی نیا حلقہ بنائیں گے، اس پر اس کا کوئی اثر نہیں پڑے گا۔';

  @override
  String get legacyCircleRemoveConfirm => 'ہٹائیں';

  @override
  String get legacyCutoverExplainerTitle => 'Haven اپ ڈیٹ ہو چکا ہے';

  @override
  String get legacyCutoverExplainerIdentityUnchanged =>
      'آپ کی شناخت اور عوامی پروفائل میں کوئی تبدیلی نہیں آئی۔ ان کے لیے آپ کو کچھ کرنے کی ضرورت نہیں۔';

  @override
  String get legacyCutoverExplainerCirclesNeedRecreation =>
      'بہتر سیکیورٹی کے لیے، آپ کے حلقوں کو دوبارہ بنانا اور ان کے ارکان کو دوبارہ دعوت دینا ضروری ہے، اس کے بعد ہی آپ ان میں دوبارہ مقام شیئر کر سکیں گے۔';

  @override
  String get legacyCutoverExplainerAcknowledge => 'ٹھیک ہے';

  @override
  String get relaySettingsLegacyRetractionPending =>
      'Haven ابھی بھی ریلے سے کہہ رہا ہے کہ حالیہ سیکیورٹی اپ ڈیٹ کا کچھ پرانا ڈیٹا گرا دیں۔';

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
  String refreshRingSemanticAllOk(int total) {
    final intl.NumberFormat totalNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String totalString = totalNumberFormat.format(total);

    String _temp0 = intl.Intl.pluralLogic(
      total,
      locale: localeName,
      other: 'تمام $totalString ریلے نے جواب دیا',
      one: 'ریلے نے جواب دیا',
    );
    return '$_temp0';
  }

  @override
  String get refreshRingSemanticAllError => 'کسی ریلے نے جواب نہیں دیا';

  @override
  String refreshRingSemanticPartial(int ok, int total) {
    final intl.NumberFormat okNumberFormat = intl.NumberFormat.decimalPattern(
      localeName,
    );
    final String okString = okNumberFormat.format(ok);
    final intl.NumberFormat totalNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String totalString = totalNumberFormat.format(total);

    return '$totalString میں سے $okString ریلے نے جواب دیا';
  }

  @override
  String get refreshRingAnnouncementChecking => 'ریلے جانچے جا رہے ہیں';

  @override
  String get refreshRingAnnouncementAllOk => 'تمام ریلے نے جواب دیا';

  @override
  String refreshRingAnnouncementPartial(int ok, int total) {
    final intl.NumberFormat okNumberFormat = intl.NumberFormat.decimalPattern(
      localeName,
    );
    final String okString = okNumberFormat.format(ok);
    final intl.NumberFormat totalNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String totalString = totalNumberFormat.format(total);

    return '$totalString میں سے $okString ریلے نے جواب دیا';
  }

  @override
  String get refreshRingAnnouncementAllError =>
      'کسی بھی ریلے تک رسائی نہ ہو سکی';

  @override
  String get refreshRingAnnouncementNoInbox => 'کوئی اِن باکس کنفیگر نہیں ہے';

  @override
  String refreshRingSemanticAllFound(int total) {
    final intl.NumberFormat totalNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String totalString = totalNumberFormat.format(total);

    String _temp0 = intl.Intl.pluralLogic(
      total,
      locale: localeName,
      other: 'تمام $totalString ریلے میں آپ کا ڈیٹا ہے',
      one: 'ریلے میں آپ کا ڈیٹا ہے',
    );
    return '$_temp0';
  }

  @override
  String get refreshRingSemanticNoneFound => 'کسی ریلے میں آپ کا ڈیٹا نہیں ہے';

  @override
  String refreshRingSemanticPartialFound(int ok, int total) {
    final intl.NumberFormat okNumberFormat = intl.NumberFormat.decimalPattern(
      localeName,
    );
    final String okString = okNumberFormat.format(ok);
    final intl.NumberFormat totalNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String totalString = totalNumberFormat.format(total);

    return '$totalString میں سے $okString ریلے میں آپ کا ڈیٹا ہے';
  }

  @override
  String get refreshRingAnnouncementAllFound => 'تمام ریلے میں آپ کا ڈیٹا ہے';

  @override
  String refreshRingAnnouncementPartialFound(int ok, int total) {
    final intl.NumberFormat okNumberFormat = intl.NumberFormat.decimalPattern(
      localeName,
    );
    final String okString = okNumberFormat.format(ok);
    final intl.NumberFormat totalNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String totalString = totalNumberFormat.format(total);

    return '$totalString میں سے $okString ریلے میں آپ کا ڈیٹا ہے';
  }

  @override
  String get refreshRingAnnouncementNoneFound =>
      'کسی ریلے میں آپ کا ڈیٹا نہیں ہے';

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
      'اس سے آپ کی شناخت اور حلقوں کا سارا ڈیٹا اس فون سے حذف ہو جاتا ہے۔ اس کے تحت جو کچھ پہلے ہی شائع ہو چکا ہے، بشمول آپ کا نام، تصویر اور کلیدیں، وہ اُن ریلے پر موجود رہتا ہے جن کے پاس ہے۔ اگر آپ اسے بحال کرنا چاہتے ہیں تو یقینی بنائیں کہ آپ نے اپنی خفیہ کلید کا بیک اپ لے لیا ہے۔';

  @override
  String get identityAdvancedDeleteConfirm => 'حذف کریں';

  @override
  String get identityAdvancedDeletedSnack => 'شناخت حذف کر دی گئی';

  @override
  String get identityAdvancedDeleteError =>
      'شناخت حذف کرنے میں ناکامی۔ براہِ کرم دوبارہ کوشش کریں۔';

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
  String keyDisplayCopiedToClipboard(String label) {
    return '$label کلپ بورڈ پر کاپی ہو گئی';
  }

  @override
  String keyDisplaySemantics(String label, String state) {
    return '$label: $state';
  }

  @override
  String get keyDisplayStateRevealed => 'ظاہر';

  @override
  String get keyDisplayStateHidden => 'پوشیدہ';

  @override
  String get keyDisplayHideTooltip => 'چھپائیں';

  @override
  String get keyDisplayRevealTooltip => 'ظاہر کریں';

  @override
  String get keyDisplayCopyTooltip => 'کاپی کریں';

  @override
  String get keyDisplayCompactCopied => 'کلید کلپ بورڈ پر کاپی ہو گئی';

  @override
  String get keyDisplayCompactTapToCopy => 'کاپی کرنے کے لیے تھپتھپائیں';

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
  String get npubQrSemanticsLabel => 'آپ کی عوامی شناخت کا QR کوڈ';

  @override
  String get photoHeaderRemoveTitle => 'پروفائل تصویر ہٹائیں؟';

  @override
  String get photoHeaderRemoveBody =>
      'اس سے آپ کی تصویر آپ کے عوامی پروفائل سے ہٹ جاتی ہے۔ تصویر کی فائل اُس سرور پر موجود رہتی ہے جو اسے میزبانی دیتا ہے، اور جو نقلیں دوسرے پہلے ہی ڈاؤن لوڈ کر چکے ہیں وہ اُن کے پاس رہتی ہیں۔';

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
  String get avatarPickerPhotoUpdated =>
      'تصویر اپ ڈیٹ ہو گئی۔ آپ کے عوامی Nostr پروفائل پر شائع کر دی گئی۔';

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
      'اس فون کی گھڑی آپ کے باقی حلقہ ارکان سے پیچھے چل رہی ہے، اس لیے یہ فون مقام تو بھیج دیتا ہے، مگر کسی کے دیکھنے سے پہلے ہی اس کی میعاد ختم ہو جاتی ہے۔ یہ مسئلہ حل کرنے کے لیے سسٹم کی ترتیبات میں خودکار تاریخ اور وقت آن کریں۔';

  @override
  String get clockSkewResolvedAnnouncement =>
      'گھڑی کا مسئلہ ختم ہو گیا۔ Haven پھر سے آپ کا مقام شیئر کر رہا ہے۔';

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
  String userLocationMarkerSemantics(String accuracy) {
    return 'آپ کے مقام کا نشان$accuracy';
  }

  @override
  String userLocationMarkerAccuracy(int meters) {
    final intl.NumberFormat metersNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String metersString = metersNumberFormat.format(meters);

    return '۔ درستگی: $metersString میٹر';
  }

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
