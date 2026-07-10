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
      'Haven کا کوئی مرکزی سرور نہیں ہے۔ آپ کے خفیہ پیغامات ریلے کے ایک غیر مرکزی نیٹ ورک سے گزرتے ہیں جنہیں آپ خود منتخب کر سکتے ہیں، چنانچہ کوئی واحد ادارہ اسے بند نہیں کر سکتا۔';

  @override
  String get onboardingValueProp3Title => 'کسی اکاؤنٹ کی ضرورت نہیں';

  @override
  String get onboardingValueProp3Body =>
      'نہ ای میل، نہ فون نمبر، نہ سائن اپ۔ Haven ایک نجی شناخت بناتا ہے جو صرف آپ کے فون پر رہتی ہے، اور کوئی چیز اسے حقیقی آپ سے نہیں جوڑتی۔';

  @override
  String get onboardingCreateIdentityTitle => 'اپنی شناخت بنائیں';

  @override
  String get onboardingCreateIdentityBody =>
      'Haven ایک نجی شناخت بنائے گا جو صرف اسی فون پر رہے گی۔ آپ کے حلقے اسی سے آپ کو پہچانتے ہیں۔';

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
  String get onboardingDisplayNameTitle => 'کوئی نام منتخب کریں';

  @override
  String get onboardingDisplayNameBody =>
      'یہ نام صرف انہی لوگوں کو نظر آتا ہے جن کے حلقے کے دعوت نامے آپ قبول کرتے ہیں۔ دعوت نامے ایک عوامی کلید کے ذریعے بھیجے جاتے ہیں، چنانچہ جب تک آپ قبول نہ کریں آپ کا نام پوشیدہ رہتا ہے۔';

  @override
  String get onboardingDisplayNameHint => 'مثلاً علی';

  @override
  String get onboardingDisplayNameError =>
      'وہ نام محفوظ نہ ہو سکا۔ براہِ کرم دوبارہ کوشش کریں۔';

  @override
  String get onboardingReadyTitle => 'آپ تیار ہیں';

  @override
  String get onboardingReadyBody =>
      'Haven حلقوں میں منظم ہے، یعنی چھوٹے نجی گروہ جہاں آپ اپنا مقام اپنے قابلِ اعتماد لوگوں کے ساتھ شیئر کرتے ہیں۔ اپنا پہلا حلقہ بنائیں، یا کسی جاننے والے کی دعوت کا انتظار کریں۔';

  @override
  String get onboardingReadyCta => 'Haven میں داخل ہوں';

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
      'kind 10050، جہاں دعوت نامے آپ تک پہنچتے ہیں';

  @override
  String get relaySettingsKeyPackageTitle => 'میرے KeyPackage ریلے';

  @override
  String get relaySettingsKeyPackageSubtitle =>
      'kind 10051، جہاں مدعو کرنے والے آپ کی خفیہ کلیدیں تلاش کرتے ہیں';

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
  String get relaySettingsExplainerSemantics =>
      'Haven کے ریلے کیسے کام کرتے ہیں';

  @override
  String get relaySettingsExplainerHeading => 'یہ کیسے کام کرتا ہے';

  @override
  String get relaySettingsExplainerNostr =>
      'Haven کا کوئی مرکزی سرور نہیں ہے۔ یہ دو کھلی ٹیکنالوجیز پر چلتا ہے۔ Nostr آزاد سرورز کا ایک نیٹ ورک ہے جنہیں ریلے کہتے ہیں اور جنہیں کوئی بھی چلا سکتا ہے؛ یہ آپ کے پیغامات وصول کرتے ہیں، تھوڑی دیر کے لیے رکھتے ہیں، اور جب آپ کے رابطے درخواست کریں تو آگے پہنچا دیتے ہیں۔ کوئی واحد ریلے ناگزیر نہیں، چنانچہ اگر ایک آف لائن ہو جائے تو باقی کام کرتے رہتے ہیں، اور کسی ریلے کو جو بھی چیز دینے پر مجبور کیا جا سکتا ہے وہ صرف خفیہ کردہ ڈیٹا ہی ہوتا ہے۔';

  @override
  String get relaySettingsExplainerMarmot =>
      'Marmot پروٹوکول آپ کے پیغامات کو آپ کے آلے سے نکلنے سے پہلے ہی اسی پر خفیہ کر دیتا ہے، جس کے لیے MLS (Messaging Layer Security) معیار استعمال ہوتا ہے۔ ہر حلقہ اپنی الگ کلیدوں کے ساتھ اپنا ایک خفیہ گروہ ہے، چنانچہ مختلف حلقوں کو آپس میں نہیں جوڑا جا سکتا۔ یہ کلیدیں وقت کے ساتھ آگے بھی بڑھتی رہتی ہیں، جسے فارورڈ سیکریسی کہا جاتا ہے، چنانچہ بعد میں ظاہر ہونے والی کلید بھی آپ کے پہلے کے پیغامات نہیں کھول سکتی۔';

  @override
  String get relaySettingsExplainerMetadata =>
      'اسی وجہ سے، کوئی ریلے کبھی آپ کا مقام، آپ کے پیغامات، آپ کے حلقوں میں کون ہے، یا ان پیغامات پر آپ کی شناخت نہیں دیکھتا۔ ہر پیغام ایک تازہ، یک بار استعمال ہونے والے بھیجنے والے پتے سے شائع ہوتا ہے، چنانچہ پیغام میں کوئی چیز اسے آپ کے اکاؤنٹ سے نہیں جوڑتی۔ پھر بھی ریلے کچھ میٹا ڈیٹا دیکھتا ہے: ہر حلقے کے لیے ایک بے ترتیب ٹیگ، آپ کے ٹریفک کا وقت اور حجم، اور وہ نیٹ ورک پتہ جہاں سے آپ منسلک ہوتے ہیں۔';

  @override
  String get relaySettingsExplainerInboxTerm => 'اِن باکس ریلے';

  @override
  String get relaySettingsExplainerInboxBody =>
      ' آپ کا ڈاک خانہ ہیں: جہاں حلقے میں شامل ہونے کے دعوت نامے، جو خود بھی خفیہ ہوتے ہیں، آپ کے لیے پہنچائے جاتے ہیں تاکہ آپ انہیں وصول کریں۔ کسی کے لیے آپ کو دعوت دینے کے لیے ضروری ہے کہ وہ ان میں سے کسی ریلے تک پہنچ سکے۔';

  @override
  String get relaySettingsExplainerKeyPackageTerm => 'KeyPackage ریلے';

  @override
  String get relaySettingsExplainerKeyPackageBody =>
      ' وہ جگہ ہیں جہاں آپ اپنی عوامی کلیدوں کا ایک چھوٹا سا بنڈل شائع کرتے ہیں، جسے شیئر کرنا محفوظ ہے۔ جو شخص آپ کا اکاؤنٹ جانتا ہے وہ آپ کو کسی حلقے میں شامل کرنے کے لیے ان ریلے سے اسے حاصل کرتا ہے۔';

  @override
  String get relaySettingsExplainerOwnRelayTerm => 'اپنا ریلے استعمال کرنا۔';

  @override
  String get relaySettingsExplainerOwnRelayBody =>
      ' ہر حلقہ اپنی ایک ریلے فہرست بھی رکھتا ہے، جو ہر رکن کے شامل ہونے پر اس کے ساتھ شیئر کی جاتی ہے؛ یہی فہرست، آپ کا اِن باکس نہیں، وہ جگہ ہے جہاں حلقے کے جاری خفیہ اپ ڈیٹس سفر کرتے ہیں۔ چنانچہ اگر آپ عوامی ریلے سے بچنا چاہتے ہیں تو آپ اپنا ریلے چلا کر کسی حلقے کو اسی کی طرف رہنمائی دے سکتے ہیں: ایک بار جب سب شامل ہو جائیں، تو اس حلقے کا ٹریفک صرف اسی سے گزر سکتا ہے۔';

  @override
  String get relaySettingsExplainerReachabilityTerm => 'اصل مشکل رسائی ہے۔';

  @override
  String get relaySettingsExplainerReachabilityBody =>
      ' ہر رکن کو اس ریلے سے منسلک ہونے کے قابل ہونا چاہیے، اور جب آپ پہلی بار کسی کو دعوت دیتے ہیں تو آپ دونوں کو ایک ایسا ریلے درکار ہوتا ہے جس تک آپ دونوں پہنچ سکیں (مثلاً وہی نجی ریلے جو سب کے اِن باکس اور KeyPackage ریلے کے طور پر درج ہو)۔ ایک نجی ریلے بھی وہی خفیہ ٹریفک اور وقت دیکھتا ہے جو کوئی بھی دوسرا؛ آپ صرف یہ طے کرتے ہیں کہ اسے کون چلائے۔';

  @override
  String get relaySettingsExplainerFooter =>
      'آپ کسی بھی فہرست میں جب چاہیں ریلے شامل یا ہٹا سکتے ہیں۔ زیادہ ریلے آپ تک پہنچنا آسان بناتے ہیں؛ کم ریلے آپ کو اس پر زیادہ اختیار دیتے ہیں کہ آپ کا خفیہ ٹریفک کہاں جائے۔';

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
      'جب پس منظر میں شیئرنگ آن ہو تو آپ کے حلقے Haven کے بند ہونے پر بھی آپ کا لائیو مقام دیکھتے رہتے ہیں۔';

  @override
  String get locationSettingsToggleTitle => 'پس منظر میں شیئر کریں';

  @override
  String get locationSettingsToggleSubtitle =>
      'ایپ بند ہونے پر بھی شیئر کرتے رہیں';

  @override
  String get locationSettingsIosLimitedNote =>
      'پس منظر میں محدود۔ ترتیبات میں Haven کے لیے مقام کو \'Always\' پر مقرر کریں';

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
      'مسلسل پس منظر شیئرنگ کے لیے ترتیبات میں Haven کے لیے مقام کو \"Always\" پر مقرر کریں۔ جب کوئی ایپ پس منظر میں آپ کا مقام استعمال کر رہی ہو تو iOS اسٹیٹس بار میں ایک نیلا اشارہ دکھاتا ہے۔';

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
  String get aboutWhoCanSeeTitle => 'کون کیا دیکھ سکتا ہے';

  @override
  String get aboutWhoCanSeeIntro =>
      'آپ کا درست مقام صرف انہی لوگوں کو نظر آتا ہے جنہیں آپ منتخب کرتے ہیں۔ یہاں بتایا گیا ہے کہ بنیادی فریق کیا دیکھ سکتے ہیں اور کیا نہیں۔';

  @override
  String get aboutActorCirclesWho =>
      'وہ حلقہ ارکان جن کے ساتھ آپ شیئر کرتے ہیں';

  @override
  String get aboutActorCirclesSees =>
      'آپ کا درست مقام اور آپ کا منتخب کردہ ظاہری نام، مگر صرف انہی حلقوں کے اندر جن میں آپ ان کے ساتھ شیئر کرتے ہیں، کبھی آپ کے دوسرے حلقے نہیں۔';

  @override
  String get aboutActorRelaysWho => 'ریلے چلانے والے';

  @override
  String get aboutActorRelaysSees =>
      'وہ سرور جو آپ کے پیغامات آگے پہنچاتے ہیں۔ وہ آپ کا IP پتہ، وہ عوامی کلید جس کے تحت آپ شائع کرتے ہیں (ایک بے ترتیب شناخت، آپ کا نام نہیں)، آپ کے ٹریفک کا حجم اور وقت، اور یہ دیکھتے ہیں کہ جب آپ کسی کو تلاش کرتے ہیں تو کس اکاؤنٹ کی تلاش کرتے ہیں۔ وہ کبھی آپ کا مقام، آپ کے پیغامات، آپ کے حلقوں کے نام، یا یہ نہیں پڑھ سکتے کہ آپ کے حلقوں میں کون ہے۔';

  @override
  String get aboutActorMapWho => 'نقشے کا فراہم کنندہ (Stadia Maps)';

  @override
  String get aboutActorMapSees =>
      'صرف جب نقشہ کھلا ہو: آپ کا IP پتہ اور وہ علاقہ جسے آپ دیکھ رہے ہیں، تاکہ وہ درست نقشے کی تصاویر بھیج سکے۔ کبھی آپ کے حلقے یا آپ کا شیئر کردہ مقام نہیں۔ Stadia، IP پتوں کو گمنام بنا دیتا ہے اور آپ کا ڈیٹا فروخت نہیں کرتا۔';

  @override
  String get aboutActorDevelopersWho => 'Haven کے ڈویلپرز';

  @override
  String get aboutActorDevelopersSees =>
      'کچھ نہیں۔ Haven کوئی سرور نہیں چلاتا اور نہ کوئی تجزیات اکٹھا کرتا ہے۔ کوئی ڈویلپر صرف وہی دیکھ سکتا ہے جو ایک ریلے چلانے والا دیکھتا ہے، اور وہ بھی صرف اس صورت میں جب آپ نے ان کا چلایا ہوا کوئی ریلے استعمال کیا ہو۔';

  @override
  String get aboutWhoCanSeeMetadataNote =>
      'پھر بھی، آپ کی سرگرمی غیر مرئی نہیں ہے۔ جو ریلے آپ استعمال کرتے ہیں، یا کوئی بھی جو آپ کا نیٹ ورک دیکھ رہا ہو، کنکشن کے وقت اور پیغامات کے حجم سے یہ بتا سکتا ہے کہ آپ سرگرم ہیں، تقریباً کب، اور کتنی بار۔';

  @override
  String get aboutScreenshotTitle => 'اسکرین شاٹ تحفظ';

  @override
  String get aboutScreenshotBody =>
      'Android پر، Haven حادثاتی طور پر مقام کے انکشاف کو روکنے کے لیے پوری ایپ میں اسکرین شاٹس اور اسکرین ریکارڈنگ کو روک دیتا ہے۔ یہ ایک سسٹم سطح کا تحفظ (FLAG_SECURE) ہے جو ایپ کی ہر اسکرین پر لاگو ہوتا ہے، بشمول نقشہ اور ارکان کی فہرستیں۔';

  @override
  String get aboutVpnTitle => 'VPN کے ساتھ زیادہ نجی رہیں';

  @override
  String get aboutVpnBody =>
      'ریلے اور نقشے کا فراہم کنندہ آپ کا IP پتہ دیکھتے ہیں، اور آپ کا انٹرنیٹ فراہم کنندہ یہ دیکھتا ہے کہ آپ کن سرورز تک پہنچتے ہیں۔ ایک قابلِ اعتماد VPN آپ کا IP پتہ ان سے چھپا دیتا ہے۔ ہم Mullvad کی سفارش کرتے ہیں۔ یہ اس بات کو نہیں بدلتا جو آپ کے حلقہ ارکان دیکھتے ہیں، اور یہ بھروسے کو VPN فراہم کنندہ کی طرف منتقل کر دیتا ہے۔';

  @override
  String get aboutVpnLinkLabel => 'mullvad.net';

  @override
  String get aboutFooterLicense => 'MIT License کے تحت لائسنس یافتہ';

  @override
  String aboutFooterVersion(String version) {
    return 'ورژن $version';
  }

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
  String get createCircleNoAccountFound => 'کوئی Haven اکاؤنٹ نہیں ملا';

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
      'اس حلقے میں شامل ہر شخص ایک دوسرے کا مقام اور ظاہری نام دیکھ سکتا ہے۔ آپ کا ظاہری نام وہی ہے جو آپ نے Settings → Identity میں مقرر کیا ہے۔ یہ حلقہ آپ کے کسی بھی دوسرے حلقے سے الگ رہتا ہے، چنانچہ اس کے ارکان آپ کے دوسرے حلقے یا یہ نہیں دیکھ سکتے کہ ان میں کون ہے۔';

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
      'نئے ارکان دعوت قبول کرنے کے بعد اس حلقے کے خفیہ مقامات دیکھ سکتے ہیں۔';

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
  String get pendingMemberRemoveTooltip => 'رکن ہٹائیں';

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
  String get circleDetailsRelaysHeading => 'اس حلقے کے ریلے';

  @override
  String get circleDetailsNoRelays => '(کوئی درج نہیں)';

  @override
  String get circleDetailsRelaysNote =>
      'یہ ریلے اس حلقے کے بننے کے وقت منتخب کیے گئے تھے اور ابھی صارف کے قابلِ ترمیم نہیں ہیں۔ یہ آپ کی ذاتی ریلے ترتیبات سے آزاد ہیں۔';

  @override
  String get circleDetailsAddMember => 'رکن شامل کریں';

  @override
  String get circleDetailsLeaveCircle => 'حلقہ چھوڑیں';

  @override
  String get leaveCircleDialogTitle => 'حلقہ چھوڑیں';

  @override
  String get leaveCircleDialogBody =>
      'کیا آپ واقعی یہ حلقہ چھوڑنا چاہتے ہیں؟ اس کے بعد آپ کو اس کے ارکان سے مقام کی اپ ڈیٹس موصول نہیں ہوں گی۔ اس عمل کو واپس نہیں کیا جا سکتا۔';

  @override
  String get leaveCircleConfirm => 'چھوڑیں';

  @override
  String get leaveCircleIdentityUnavailable => 'شناخت دستیاب نہیں';

  @override
  String get leaveCircleSuccess => 'حلقہ کامیابی سے چھوڑ دیا گیا';

  @override
  String get leaveCircleError => 'حلقہ چھوڑنے میں ناکامی';

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
  String get identityVisibilityNote =>
      'آپ کی تصویر اور ظاہری نام صرف انہی حلقوں کے ارکان دیکھ سکتے ہیں جن میں آپ شامل ہوئے ہیں۔ دعوت نامے عوامی کلیدوں یا QR کوڈز کے ذریعے بھیجے جاتے ہیں۔';

  @override
  String get identityAdvancedExportError =>
      'خفیہ کلید برآمد کرنے میں ناکامی۔ براہِ کرم دوبارہ کوشش کریں۔';

  @override
  String get identityAdvancedDeleteTitle => 'شناخت حذف کریں؟';

  @override
  String get identityAdvancedDeleteBody =>
      'اس سے آپ کی شناخت مستقل طور پر حذف ہو جائے گی۔ یقینی بنائیں کہ اگر آپ اسے بحال کرنا چاہتے ہیں تو آپ نے اپنی خفیہ کلید کا بیک اپ لے لیا ہے۔';

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
      'آپ کی عوامی کلید ایک ایسے صارف نام کی طرح کام کرتی ہے جسے شیئر کرنا محفوظ ہے۔ لوگ آپ کو کسی حلقے میں مدعو کرنے کے لیے یہ کوڈ اسکین کرتے ہیں، یا آپ کی عوامی کلید چسپاں کرتے ہیں۔ یہ آپ کا ظاہری نام، تصویر، یا مقام ظاہر نہیں کر سکتی، جو صرف انہی حلقوں کے ارکان کے ساتھ شیئر ہوتے ہیں جن میں آپ شامل ہوئے ہیں۔';

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
  String get npubQrScanLabel => 'مجھے شامل کرنے کے لیے اسکین کریں';

  @override
  String get npubQrSemanticsLabel => 'آپ کی عوامی شناخت کا QR کوڈ';

  @override
  String get photoHeaderRemoveTitle => 'پروفائل تصویر ہٹائیں؟';

  @override
  String get photoHeaderRemoveBody =>
      'اس سے آپ کے حلقوں کے ہر فرد کے لیے آپ کی تصویر ہٹ جائے گی۔';

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
      'تصویر اپ ڈیٹ ہو گئی — آپ کے حلقوں کے ساتھ شیئر کر دی گئی، سرے تا سرے خفیہ۔';

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
  String memberMarkerHoursShort(int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    return '${countString}h';
  }

  @override
  String memberMarkerDaysShort(int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    return '${countString}d';
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
  String memberMarkerHoursAgoSemantics(int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$countString گھنٹے پہلے',
      one: '1 گھنٹہ پہلے',
    );
    return '$_temp0';
  }

  @override
  String memberMarkerDaysAgoSemantics(int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$countString دن پہلے',
      one: '1 دن پہلے',
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
