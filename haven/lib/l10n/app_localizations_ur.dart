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
  String get onboardingValueProp2Title => 'اسے کوئی بند نہیں کر سکتا';

  @override
  String get onboardingValueProp3Title => 'کسی اکاؤنٹ کی ضرورت نہیں';

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
  String get settingsRelaysTitle => 'ریلے';

  @override
  String get settingsLocationTitle => 'مقام';

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
  String get locationSettingsBatteryOptNote =>
      'Haven کے لیے بیٹری بہتری اب بھی آن ہے۔ کچھ فونز اسی کے ذریعے پس منظر میں شیئرنگ کو بغیر بتائے روک دیتے ہیں۔ شیئرنگ کو بھروسے مند رکھنے کے لیے Haven کو اس سے مستثنیٰ کریں۔';

  @override
  String get locationSettingsErrorSnack => 'کچھ غلط ہو گیا';

  @override
  String get locationSettingsIntro =>
      'جب بھی ایپ کھلی ہو، Haven آپ کا مقام آپ کے حلقوں کے ساتھ شیئر کرتا ہے۔ اسے آن کریں تو Haven کے پس منظر میں ہوتے ہوئے بھی آپ کے حلقے اسے دیکھتے رہیں گے۔ اگر سسٹم Haven کو بند کر دے تو شیئرنگ رک جاتی ہے۔ پس منظر میں ایپ صرف آپ کے حلقوں کے مقامات لانے کے لیے جاگتی ہے، آپ کا اپنا مقام کبھی نہیں بھیجتی۔ Android پر شیئرنگ Haven کو ایپ سوئچر سے ہٹا دینے کے بعد بھی جاری رہتی ہے اور فون دوبارہ چالو ہونے پر خود ہی پھر شروع ہو جاتی ہے؛ iPhone پر یہ اُس وقت تک رکی رہتی ہے جب تک آپ Haven نہ کھولیں۔';

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
      'ارکان شامل کرنے کے لیے ID سے تلاش کریں یا ان کا QR کوڈ اسکین کریں۔';

  @override
  String get createCircleNoValidMembers =>
      'دعوت دینے کے لیے کوئی درست رکن نہیں';

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
  String nameCircleCreatedPartialSnack(String name, int sent, int total) {
    final intl.NumberFormat sentNumberFormat = intl.NumberFormat.decimalPattern(
      localeName,
    );
    final String sentString = sentNumberFormat.format(sent);
    final intl.NumberFormat totalNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String totalString = totalNumberFormat.format(total);

    return 'حلقہ \"$name\" بن گیا۔ دعوت نامے بھیج دیے گئے ($totalString میں سے $sentString)؛ باقی کی ترسیل زیر التوا ہے۔';
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
  String get memberPickerReasonSelf => 'یہ آپ کی اپنی ID ہے';

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
  String get memberPickerStrangerLookupNote =>
      'Haven نے ایک ریلے سے کہا کہ اس شخص کا عوامی نام تلاش کرے۔ وہ ریلے دیکھتا ہے کہ اس آلے نے ابھی ابھی اس کلید کے بارے میں پوچھا ہے۔ مگر اس درخواست پر دستخط نہیں ہوتے، اس لیے یہ آپ کی Haven شناخت سے نہیں جڑتی۔ ابھی تک کوئی تصویر ڈاؤن لوڈ نہیں ہوئی۔';

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
    return 'رمزی شناخت کنندہ $inviter کی جانب سے دعوت';
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
      'یہ ریلے مدعو ارکان کی شائع کردہ فہرستوں سے آئے ہیں، اُن ارکان کی فہرست نہ ہونے پر آپ کے اِن باکس ریلے یا Haven کے چنے ریلے استعمال ہوئے۔ انہیں ابھی بدلا نہیں جا سکتا، اور آپ کی ریلے فہرست میں بعد کی ترامیم انہیں نہیں بدلتیں۔';

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
      'Haven ابھی بھی ریلے سے کہہ رہا ہے کہ حالیہ سیکیورٹی اپ ڈیٹ کا کچھ پرانا ڈیٹا ہٹا دے۔';

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
      'اس سے آپ کی شناخت اور حلقوں کا سارا ڈیٹا اس فون سے حذف ہو جاتا ہے۔ اس کے تحت جو کچھ پہلے ہی شائع ہو چکا ہے وہ جہاں ہے وہیں رہتا ہے: آپ کا نام اور کلیدیں اُن ریلے پر جن کے پاس ہیں، اور آپ کی تصویر اُس تصویری میزبان پر جو اسے رکھے ہوئے ہے۔ اگر آپ اپنی شناخت بحال کرنا چاہتے ہیں تو یقینی بنائیں کہ آپ نے اپنی خفیہ کلید کا بیک اپ لے لیا ہے۔';

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
  String get profileSyncStatusSyncing => 'آپ کا عوامی پروفائل سنک ہو رہا ہے…';

  @override
  String get profileSyncStatusPartial =>
      'شائع ہو گیا — کچھ ریلے پر ابھی سنک ہو رہا ہے';

  @override
  String get profileSyncStatusSynced => 'عوامی پروفائل تازہ ترین ہے';

  @override
  String get profileSyncStatusFailed => 'ابھی سنک نہ ہو سکا۔';

  @override
  String get profileSyncStatusRetrySemantics =>
      'اپنا پروفائل دوبارہ شائع کرنے کی کوشش کریں';

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
      'تصویر اپ ڈیٹ ہو گئی۔ یہ آپ کے عوامی Nostr پروفائل پر شائع کی جائے گی۔';

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
  String get sharingHealthRepairUnavailableHint =>
      'ٹھیک کرنے کا بٹن اس حلقے کے لیے دستیاب نہیں';

  @override
  String get sharingHealthRepairHint =>
      'ریلے سے کنکشن بحال کرتا ہے، آپ کا مقام بھیجنے کی دوبارہ کوشش کرتا ہے، اور اگر آپ اس حلقے کے منتظم ہیں تو اسے نئی کلید دے سکتا ہے';

  @override
  String get sharingHealthRepairSent =>
      'حلقہ ٹھیک کرنے کی تبدیلی بھیج دی گئی ہے۔ دوسرے اُس وقت ہم آہنگ ہوں گے جب اُن کے فون یہ وصول کر لیں گے۔';

  @override
  String get sharingHealthRepairNotOwner =>
      'اس حلقے کو اس کے منتظم کے سوا کوئی ٹھیک نہیں کر سکتا۔ اُن سے کہیں کہ وہ آپ کو ہٹا کر دوبارہ شامل کر لیں۔';

  @override
  String get sharingHealthRepairNeedsNewCircle =>
      'اس حلقے کو اس فون پر ٹھیک نہیں کیا جا سکتا۔ اُنہی لوگوں کے ساتھ نیا حلقہ بنائیں۔';

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
