// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Persian (`fa`).
class AppLocalizationsFa extends AppLocalizations {
  AppLocalizationsFa([String locale = 'fa']) : super(locale);

  @override
  String get appearanceTitle => 'ظاهر';

  @override
  String get appearanceThemeHeader => 'تم';

  @override
  String get appearanceThemeSystem => 'پیش‌فرض سیستم';

  @override
  String get appearanceThemeSystemSubtitle => 'هماهنگ با تنظیمات دستگاه شما';

  @override
  String get appearanceThemeLight => 'روشن';

  @override
  String get appearanceThemeLightSubtitle => 'همیشه از تم روشن استفاده کن';

  @override
  String get appearanceThemeDark => 'تیره';

  @override
  String get appearanceThemeDarkSubtitle => 'همیشه از تم تیره استفاده کن';

  @override
  String get appearanceLanguageTitle => 'زبان';

  @override
  String get languageSystemDefault => 'پیش‌فرض سیستم';

  @override
  String get commonTryAgain => 'تلاش دوباره';

  @override
  String get commonDismiss => 'بستن';

  @override
  String get commonSettings => 'تنظیمات';

  @override
  String get commonInvitations => 'دعوت‌ها';

  @override
  String commonPendingInvitations(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count دعوت در انتظار',
      one: '$count دعوت در انتظار',
    );
    return '$_temp0';
  }

  @override
  String get commonBack => 'بازگشت';

  @override
  String get commonContinue => 'ادامه';

  @override
  String get commonSkip => 'رد کردن';

  @override
  String get commonRetry => 'تلاش دوباره';

  @override
  String onboardingStepOf(int current, int total) {
    return 'مرحلهٔ $current از $total';
  }

  @override
  String get onboardingAppName => 'Haven';

  @override
  String get onboardingWelcomeHeadline =>
      'موقعیت مکانی‌ات را به‌صورت خصوصی، فقط با کسانی که می‌خواهی به اشتراک بگذار.';

  @override
  String get onboardingWelcomeHeadlineEmphasis => 'فقط';

  @override
  String get onboardingWelcomeCta => 'شروع کنید';

  @override
  String get onboardingValuePropsTitle => 'چه چیزی Haven را متفاوت می‌کند';

  @override
  String get onboardingValueProp1Title =>
      'فقط حلقه‌هایت می‌توانند تو را ببینند';

  @override
  String get onboardingValueProp1Body =>
      'موقعیت مکانی تو پیش از خروج از دستگاهت رمزگذاری می‌شود، پس فقط حلقه‌هایی که خودت انتخاب می‌کنی می‌توانند آن را بخوانند؛ نه Haven و نه هیچ‌کس دیگر. چون Haven متن‌باز است، هرکسی می‌تواند این را بررسی و تأیید کند.';

  @override
  String get onboardingValueProp2Title => 'هیچ‌کس نمی‌تواند آن را خاموش کند';

  @override
  String get onboardingValueProp2Body =>
      'Haven هیچ سرور مرکزی ندارد. پیام‌های رمزگذاری‌شدهٔ تو از میان شبکه‌ای غیرمتمرکز از رله‌ها عبور می‌کنند که خودت می‌توانی انتخابشان کنی، پس هیچ نهاد واحدی نمی‌تواند آن را تعطیل کند.';

  @override
  String get onboardingValueProp3Title => 'نیازی به حساب کاربری نیست';

  @override
  String get onboardingValueProp3Body =>
      'بدون ایمیل، بدون شمارهٔ تلفن، بدون ثبت‌نام. Haven یک هویت خصوصی می‌سازد که فقط روی گوشی تو زندگی می‌کند و هیچ چیزی آن را به هویت واقعی‌ات گره نمی‌زند.';

  @override
  String get onboardingCreateIdentityTitle => 'هویت خود را بسازید';

  @override
  String get onboardingCreateIdentityBody =>
      'Haven یک هویت خصوصی می‌سازد که فقط روی همین گوشی زندگی می‌کند. حلقه‌هایت با همین هویت تو را می‌شناسند.';

  @override
  String get onboardingCreateIdentityWarning =>
      'اگر این گوشی را گم کنی یا برنامه را پاک کنی، هویتت از بین می‌رود. Haven هیچ راهی برای بازیابی آن برایت ندارد.';

  @override
  String get onboardingCreateIdentityCta => 'هویتم را بساز';

  @override
  String get onboardingCreateIdentityLoading => 'در حال آماده‌سازی…';

  @override
  String get onboardingCreateIdentityImportPrompt => 'از قبل کلید داری؟';

  @override
  String get onboardingCreateIdentityImportLink => 'به‌جایش آن را وارد کن';

  @override
  String get onboardingCreateIdentityError =>
      'هنگام ساختن هویت مشکلی پیش آمد. لطفاً دوباره تلاش کنید.';

  @override
  String get onboardingImportTitle => 'کلید موجود خود را وارد کنید';

  @override
  String get onboardingImportBody =>
      'کلید خصوصی‌ای را که از یک برنامهٔ سازگار با Haven پشتیبان گرفته‌ای، اینجا جای‌گذاری کن.';

  @override
  String get onboardingImportHint => 'nsec1…';

  @override
  String get onboardingImportCta => 'وارد کردن';

  @override
  String get onboardingImportLoading => 'در حال وارد کردن…';

  @override
  String get onboardingImportInvalid =>
      'این به یک کلید پشتیبان معتبر شبیه نیست. لطفاً بررسی کنید و دوباره تلاش کنید.';

  @override
  String get onboardingImportError =>
      'نتوانستیم آن کلید را وارد کنیم. لطفاً بررسی کنید و دوباره تلاش کنید.';

  @override
  String get onboardingDisplayNameTitle => 'یک نام انتخاب کنید';

  @override
  String get onboardingDisplayNameBody =>
      'این نام فقط برای کسانی دیده می‌شود که دعوت حلقهٔ آن‌ها را می‌پذیری. دعوت‌ها با یک کلید عمومی فرستاده می‌شوند، پس نام تو تا زمانی که دعوت را نپذیری پنهان می‌ماند.';

  @override
  String get onboardingDisplayNameHint => 'مثلاً علی';

  @override
  String get onboardingDisplayNameError =>
      'نتوانستیم آن نام را ذخیره کنیم. لطفاً دوباره تلاش کنید.';

  @override
  String get onboardingReadyTitle => 'آماده‌ای';

  @override
  String get onboardingReadyBody =>
      'Haven بر پایهٔ حلقه‌ها سازمان‌دهی شده است؛ گروه‌های کوچک و خصوصی که در آن‌ها موقعیت مکانی‌ات را با افراد مورد اعتمادت به اشتراک می‌گذاری. نخستین حلقه‌ات را بساز، یا منتظر دعوتی از کسی که می‌شناسی بمان.';

  @override
  String get onboardingReadyCta => 'ورود به Haven';

  @override
  String get commonCancel => 'لغو';

  @override
  String get commonOpenSettings => 'باز کردن تنظیمات';

  @override
  String get settingsTitle => 'تنظیمات';

  @override
  String get settingsIdentityTitle => 'هویت';

  @override
  String get settingsIdentitySubtitle => 'نمایه، کلیدها و اشتراک عکس';

  @override
  String get settingsRelaysTitle => 'رله‌ها';

  @override
  String get settingsRelaysSubtitle => 'جایی که دعوت‌ها به تو می‌رسند';

  @override
  String get settingsLocationTitle => 'موقعیت مکانی';

  @override
  String get settingsLocationSubtitle => 'اشتراک‌گذاری در پس‌زمینه و مجوزها';

  @override
  String get settingsMapStyleTitle => 'سبک نقشه';

  @override
  String get settingsAppearanceSubtitle => 'تم و زبان';

  @override
  String get settingsAboutTitle => 'درباره';

  @override
  String get settingsDebugOverlayTitle => 'روپوش گزارش اشکال‌زدایی';

  @override
  String get settingsDebugOverlaySubtitle => 'نمایش خروجی گزارش روی صفحه';

  @override
  String get relaySettingsTitle => 'رله‌ها';

  @override
  String get relaySettingsCheckRelaysTooltip => 'بررسی رله‌ها';

  @override
  String get relaySettingsNoIdentityTitle => 'بدون هویت';

  @override
  String get relaySettingsNoIdentityMessage =>
      'برای مدیریت رله‌ها، ابتدا یک هویت بسازید.';

  @override
  String get relaySettingsLoadIdentityError => 'بارگذاری هویت ناموفق بود.';

  @override
  String get relaySettingsInboxTitle => 'رله‌های صندوق ورودی من';

  @override
  String get relaySettingsInboxSubtitle =>
      'kind 10050، جایی که دعوت‌ها به تو می‌رسند';

  @override
  String get relaySettingsKeyPackageTitle => 'رله‌های KeyPackage من';

  @override
  String get relaySettingsKeyPackageSubtitle =>
      'kind 10051، جایی که دعوت‌شدگان کلیدهای رمزگذاری تو را پیدا می‌کنند';

  @override
  String get relaySettingsLoadRelaysError => 'بارگذاری رله‌ها ناموفق بود.';

  @override
  String get relaySettingsAddRelay => 'افزودن رله';

  @override
  String get relaySettingsRestoreDefaults => 'بازگرداندن پیش‌فرض‌ها';

  @override
  String get relaySettingsAddRelayError => 'افزودن رله ناموفق بود.';

  @override
  String get relaySettingsRemoveRelayError => 'حذف رله ناموفق بود.';

  @override
  String get relaySettingsRestoreTitle => 'رله‌های پیش‌فرض بازگردانده شوند؟';

  @override
  String relaySettingsRestoreBody(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other:
          '$count رلهٔ کنونی تو با پیش‌فرض‌های Haven جایگزین می‌شوند. این کار قابل بازگشت نیست.',
      one:
          '$count رلهٔ کنونی تو با پیش‌فرض‌های Haven جایگزین می‌شود. این کار قابل بازگشت نیست.',
    );
    return '$_temp0';
  }

  @override
  String get relaySettingsRestoreConfirm => 'بازگرداندن';

  @override
  String get relaySettingsRestoreSuccess => 'پیش‌فرض‌ها بازگردانده شدند.';

  @override
  String get relaySettingsRestoreError => 'بازگرداندن پیش‌فرض‌ها ناموفق بود.';

  @override
  String relaySettingsRemoveTooltip(String url) {
    return 'حذف $url';
  }

  @override
  String get relaySettingsStatusConnected => 'متصل';

  @override
  String get relaySettingsStatusChecking => 'در حال بررسی';

  @override
  String get relaySettingsStatusUnreachable => 'در دسترس نیست';

  @override
  String get relaySettingsStatusNotChecked => 'بررسی نشده';

  @override
  String relaySettingsStatusSemantics(String status) {
    return 'وضعیت رله: $status';
  }

  @override
  String get relaySettingsEmptyTitle => 'هیچ رله‌ای تنظیم نشده';

  @override
  String get relaySettingsEmptyMessage =>
      'برای اینکه دیگران بتوانند به تو دسترسی داشته باشند، به دست‌کم یک رله نیاز داری. برای بازگرداندن پیش‌فرض‌های Haven، روی دکمهٔ پایین بزن.';

  @override
  String get relaySettingsExplainerSemantics =>
      'رله‌های Haven چگونه کار می‌کنند';

  @override
  String get relaySettingsExplainerHeading => 'این چگونه کار می‌کند';

  @override
  String get relaySettingsExplainerNostr =>
      'Haven هیچ سرور مرکزی ندارد. روی دو فناوری باز اجرا می‌شود. Nostr شبکه‌ای از سرورهای مستقل به نام رله است که هرکسی می‌تواند آن را راه‌اندازی کند؛ این سرورها پیام‌های تو را دریافت می‌کنند، کوتاه‌مدت نگه می‌دارند و هنگامی که مخاطبانت درخواست کنند آن‌ها را تحویل می‌دهند. هیچ رلهٔ واحدی ضروری نیست، پس اگر یکی از کار بیفتد بقیه به کار خود ادامه می‌دهند، و هر چیزی که یک رله ممکن است مجبور به تحویل آن شود، همواره فقط دادهٔ رمزگذاری‌شده است.';

  @override
  String get relaySettingsExplainerMarmot =>
      'پروتکل Marmot پیام‌های تو را پیش از خروج از دستگاهت روی همان دستگاه رمزگذاری می‌کند، با استفاده از استاندارد MLS (Messaging Layer Security). هر حلقه گروه رمزگذاری‌شدهٔ مستقل خودش با کلیدهای خودش است، پس حلقه‌های جداگانه را نمی‌توان به هم پیوند زد. این کلیدها همچنین به‌مرور پیوسته جلو می‌روند، ویژگی‌ای که محرمانگی پیش‌رو نامیده می‌شود، پس حتی اگر کلیدی بعدها افشا شود نمی‌تواند پیام‌های پیشین تو را باز کند.';

  @override
  String get relaySettingsExplainerMetadata =>
      'به همین دلیل، یک رله هرگز موقعیت مکانی تو، پیام‌هایت، اعضای حلقه‌هایت یا هویت تو روی آن پیام‌ها را نمی‌بیند. هر پیام از یک آدرس فرستندهٔ تازه و یک‌بارمصرف منتشر می‌شود، پس هیچ چیزی در پیام آن را به حساب تو گره نمی‌زند. با این حال، یک رله همچنان برخی فراداده‌ها را می‌بیند: یک برچسب تصادفی برای هر حلقه، زمان‌بندی و اندازهٔ ترافیک تو، و آدرس شبکه‌ای که از آن متصل می‌شوی.';

  @override
  String get relaySettingsExplainerInboxTerm => 'رله‌های صندوق ورودی';

  @override
  String get relaySettingsExplainerInboxBody =>
      ' صندوق پستی تو هستند: جایی که دعوت‌ها برای پیوستن به یک حلقه، که خودشان رمزگذاری‌شده‌اند، تحویل داده می‌شوند تا تو آن‌ها را برداری. برای اینکه کسی بتواند تو را دعوت کند، باید بتواند به یکی از این رله‌ها دسترسی پیدا کند.';

  @override
  String get relaySettingsExplainerKeyPackageTerm => 'رله‌های KeyPackage';

  @override
  String get relaySettingsExplainerKeyPackageBody =>
      ' جایی هستند که بستهٔ کوچکی از کلیدهای عمومی‌ات را منتشر می‌کنی، که به اشتراک گذاشتنش امن است. کسی که حساب تو را می‌شناسد آن را از این رله‌ها می‌گیرد تا تو را به یک حلقه اضافه کند.';

  @override
  String get relaySettingsExplainerOwnRelayTerm => 'استفاده از رلهٔ خودت.';

  @override
  String get relaySettingsExplainerOwnRelayBody =>
      ' هر حلقه فهرست رلهٔ خودش را نیز دارد که هنگام پیوستن با هر عضو به اشتراک گذاشته می‌شود؛ همان فهرست، نه صندوق ورودی تو، جایی است که به‌روزرسانی‌های رمزگذاری‌شدهٔ جاری حلقه از آن عبور می‌کنند. پس اگر ترجیح می‌دهی از رله‌های عمومی پرهیز کنی، می‌توانی رلهٔ خودت را راه‌اندازی کنی و یک حلقه را به آن متصل کنی: پس از پیوستن همه، ترافیک آن حلقه می‌تواند تنها از همان عبور کند.';

  @override
  String get relaySettingsExplainerReachabilityTerm =>
      'نکته‌اش دسترس‌پذیری است.';

  @override
  String get relaySettingsExplainerReachabilityBody =>
      ' هر عضو باید بتواند به آن رله متصل شود، و وقتی کسی را برای نخستین بار دعوت می‌کنی، هر دوی شما به رله‌ای نیاز دارید که هردو بتوانید به آن دسترسی پیدا کنید (برای نمونه، همان رلهٔ خصوصی که به‌عنوان رلهٔ صندوق ورودی و KeyPackage همه فهرست شده است). یک رلهٔ خصوصی همچنان همان ترافیک رمزگذاری‌شده و زمان‌بندی را مانند هر رلهٔ دیگری می‌بیند؛ تو فقط کنترل می‌کنی که چه کسی آن را اجرا کند.';

  @override
  String get relaySettingsExplainerFooter =>
      'می‌توانی هر زمان که خواستی به هر یک از این فهرست‌ها رله اضافه یا از آن حذف کنی. رله‌های بیشتر دسترسی به تو را آسان‌تر می‌کنند؛ رله‌های کمتر کنترل بیشتری بر مسیر ترافیک رمزگذاری‌شده‌ات به تو می‌دهند.';

  @override
  String get locationSettingsTitle => 'موقعیت مکانی';

  @override
  String get locationSettingsDisabledSnack =>
      'اشتراک‌گذاری در پس‌زمینه غیرفعال شد';

  @override
  String get locationSettingsEnabledSnack => 'اشتراک‌گذاری در پس‌زمینه فعال شد';

  @override
  String get locationSettingsNotificationDeniedSnack =>
      'اشتراک‌گذاری در پس‌زمینه به یک اعلان نیاز دارد تا اندروید آن را فعال نگه دارد. فعلاً خاموش است. برای فعال کردنش، اعلان‌های Haven را مجاز کن.';

  @override
  String get locationSettingsBatteryOptSnack =>
      'روشن است. بهینه‌سازی باتری ممکن است روی برخی گوشی‌ها اشتراک‌گذاری را متوقف کند. برای اینکه قابل‌اعتماد بماند، Haven را از بهینه‌سازی باتری مستثنا کن.';

  @override
  String get locationSettingsErrorSnack => 'مشکلی پیش آمد';

  @override
  String get locationSettingsIntro =>
      'وقتی اشتراک‌گذاری در پس‌زمینه روشن باشد، حلقه‌هایت موقعیت زندهٔ تو را حتی هنگامی که Haven بسته است همچنان می‌بینند.';

  @override
  String get locationSettingsToggleTitle => 'اشتراک‌گذاری در پس‌زمینه';

  @override
  String get locationSettingsToggleSubtitle =>
      'وقتی برنامه بسته است همچنان به اشتراک‌گذاری ادامه بده';

  @override
  String get locationSettingsIosLimitedNote =>
      'در پس‌زمینه محدود است. در تنظیمات، موقعیت مکانی Haven را روی «همیشه» بگذار';

  @override
  String get locationSettingsAndroidHeader =>
      'تنظیمات سیستم‌عامل برای قابلیت اطمینان';

  @override
  String get locationSettingsAndroidNotification =>
      'Haven به یک اعلان ماندگار نیاز دارد تا اندروید سرویس پس‌زمینه را فعال نگه دارد. اگر مجوز اعلان را رد کرده‌ای، تنظیمات را باز کن و اعلان‌های Haven را مجاز کن.';

  @override
  String get locationSettingsAndroidBattery =>
      'برای اشتراک‌گذاری پس‌زمینهٔ قابل‌اعتماد، Haven را از بهینه‌سازی باتری نیز مستثنا کن. به تنظیمات ← برنامه‌ها ← Haven ← باتری ← مجاز در همهٔ مواقع برو.';

  @override
  String get locationSettingsAndroidVendors =>
      'روی دستگاه‌های Samsung، ‏Haven را از «Sleeping apps» حذف کن (Device care ← Battery ← Background usage limits). روی Xiaomi، ‏Autostart را برای Haven فعال کن.';

  @override
  String get locationSettingsIosGuidance =>
      'برای اشتراک‌گذاری پیوستهٔ پس‌زمینه، در تنظیمات موقعیت مکانی Haven را روی «همیشه» بگذار. iOS هنگامی که یک برنامه در پس‌زمینه از موقعیت مکانی تو استفاده می‌کند، یک نشانگر آبی در نوار وضعیت نمایش می‌دهد.';

  @override
  String get mapStyleTitle => 'سبک نقشه';

  @override
  String get mapStyleMinimalTitle => 'ساده';

  @override
  String get mapStyleMinimalSubtitle =>
      'بومی آرام و کم‌جزئیات که از تم روشن یا تیرهٔ تو پیروی می‌کند';

  @override
  String get mapStyleDetailedTitle => 'پرجزئیات';

  @override
  String get mapStyleDetailedSubtitle =>
      'خیابان‌ها، برچسب‌ها و مکان‌ها به‌صورت تمام‌رنگی';

  @override
  String get mapStyleOutdoorsTitle => 'طبیعت‌گردی';

  @override
  String get mapStyleOutdoorsSubtitle =>
      'زمین سایه‌دار همراه با مسیرها و پارک‌ها';

  @override
  String get mapStylePreviewHeader => 'پیش‌نمایش';

  @override
  String get mapStylePreviewCity => 'شهر';

  @override
  String get mapStylePreviewNature => 'طبیعت';

  @override
  String mapStylePreviewSemantics(String scene, String style) {
    return 'پیش‌نمایش نقشه ($scene): $style';
  }

  @override
  String get mapStylePreviewUnavailableSemantics =>
      'پیش‌نمایش نقشه در این نسخه در دسترس نیست';

  @override
  String get mapStylePreviewUnavailableLabel =>
      'پیش‌نمایش زنده در نسخه‌های انتشار نمایش داده می‌شود';

  @override
  String get aboutTitle => 'درباره';

  @override
  String get aboutHeroName => 'Haven';

  @override
  String get aboutHeroTagline =>
      'اشتراک موقعیت مکانی خصوصی و مقاوم در برابر سانسور.';

  @override
  String get aboutLicensesTitle => 'مجوزهای متن‌باز';

  @override
  String get aboutLicensesLegalese => '© 2026 Haven · MIT License';

  @override
  String get aboutReportMapIssue => 'گزارش مشکل نقشه';

  @override
  String get aboutSupportOsm => 'حمایت از OpenStreetMap';

  @override
  String get aboutMapAttribution =>
      '© Stadia Maps · © OpenMapTiles · © OpenStreetMap contributors\nMap data licensed under ODbL';

  @override
  String get aboutLinkOpenError => 'نتوانستیم پیوند را باز کنیم';

  @override
  String get aboutWhoCanSeeTitle => 'چه کسی چه چیزی را می‌بیند';

  @override
  String get aboutWhoCanSeeIntro =>
      'موقعیت مکانی دقیق تو را فقط افرادی که خودت انتخاب می‌کنی می‌توانند بخوانند. در ادامه آمده است که هر یک از طرف‌های اصلی چه چیزی را می‌توانند ببینند و چه چیزی را نمی‌توانند.';

  @override
  String get aboutActorCirclesWho =>
      'اعضای حلقه‌ای که با آن‌ها به اشتراک می‌گذاری';

  @override
  String get aboutActorCirclesSees =>
      'موقعیت مکانی دقیق تو و نامی که انتخاب می‌کنی، اما فقط درون همان حلقه‌هایی که با آن‌ها به اشتراک می‌گذاری، نه حلقه‌های دیگرت.';

  @override
  String get aboutActorRelaysWho => 'گردانندگان رله';

  @override
  String get aboutActorRelaysSees =>
      'سرورهایی که پیام‌های تو را منتقل می‌کنند. آن‌ها آدرس IP تو، کلید عمومی‌ای که با آن منتشر می‌کنی (یک شناسهٔ تصادفی، نه نام تو)، اندازه و زمان‌بندی ترافیکت، و این را که هنگام جست‌وجوی کسی به دنبال چه حسابی بوده‌ای می‌بینند. آن‌ها هرگز نمی‌توانند موقعیت مکانی، پیام‌ها، نام حلقه‌ها یا اعضای حلقه‌هایت را بخوانند.';

  @override
  String get aboutActorMapWho => 'ارائه‌دهندهٔ نقشه (Stadia Maps)';

  @override
  String get aboutActorMapSees =>
      'فقط زمانی که نقشه باز است: آدرس IP تو و ناحیه‌ای که در حال دیدنش هستی، تا بتواند تصاویر درست نقشه را بفرستد. هرگز حلقه‌ها یا موقعیت به‌اشتراک‌گذاشته‌شده‌ات را نمی‌بیند. Stadia آدرس‌های IP را ناشناس می‌کند و داده‌های تو را نمی‌فروشد.';

  @override
  String get aboutActorDevelopersWho => 'توسعه‌دهندگان Haven';

  @override
  String get aboutActorDevelopersSees =>
      'هیچ چیز. Haven هیچ سروری اجرا نمی‌کند و هیچ آماری جمع‌آوری نمی‌کند. یک توسعه‌دهنده تنها می‌تواند چیزی را ببیند که یک گردانندهٔ رله می‌بیند، آن هم فقط اگر از رله‌ای استفاده کنی که اتفاقاً خودش آن را اجرا می‌کند.';

  @override
  String get aboutWhoCanSeeMetadataNote =>
      'با این حال، فعالیت تو نامرئی نیست. یک رله‌ای که از آن استفاده می‌کنی، یا هرکسی که شبکه‌ات را زیر نظر دارد، می‌تواند از روی زمان‌بندی اتصال و اندازهٔ پیام‌ها بفهمد که فعال هستی، تقریباً چه زمانی و هر چند وقت یک‌بار.';

  @override
  String get aboutScreenshotTitle => 'محافظت در برابر اسکرین‌شات';

  @override
  String get aboutScreenshotBody =>
      'روی Android، ‏Haven اسکرین‌شات و ضبط صفحه را در سراسر برنامه مسدود می‌کند تا از افشای ناخواستهٔ موقعیت مکانی جلوگیری شود. این یک محافظت در سطح سیستم (FLAG_SECURE) است که روی هر صفحه‌ای در برنامه، از جمله نقشه و فهرست اعضا، اعمال می‌شود.';

  @override
  String get aboutVpnTitle => 'با یک VPN حریم خصوصی بیشتری داشته باش';

  @override
  String get aboutVpnBody =>
      'رله‌ها و ارائه‌دهندهٔ نقشه آدرس IP تو را می‌بینند، و ارائه‌دهندهٔ اینترنتت می‌بیند به چه سرورهایی دسترسی پیدا می‌کنی. یک VPN قابل‌اعتماد آدرس IP تو را از آن‌ها پنهان می‌کند. ما Mullvad را پیشنهاد می‌کنیم. این کار آنچه را اعضای حلقه‌ات می‌بینند تغییر نمی‌دهد، و اعتماد را به ارائه‌دهندهٔ VPN منتقل می‌کند.';

  @override
  String get aboutVpnLinkLabel => 'mullvad.net';

  @override
  String get aboutFooterLicense => 'تحت مجوز MIT License';

  @override
  String aboutFooterVersion(String version) {
    return 'نسخهٔ $version';
  }

  @override
  String get commonClearAll => 'پاک کردن همه';

  @override
  String commonMemberCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count عضو',
      one: '$count عضو',
    );
    return '$_temp0';
  }

  @override
  String get circlesTitle => 'حلقه‌ها';

  @override
  String get circlesRefreshTooltip => 'تازه‌سازی حلقه‌ها';

  @override
  String get circlesRequiresIdentity =>
      'ساختن حلقه ابتدا به تنظیم هویت نیاز دارد';

  @override
  String get circlesCreateCta => 'ساختن حلقه';

  @override
  String get circlesYourCircles => 'حلقه‌های تو';

  @override
  String get circlesEmptyTitle => 'هنوز حلقه‌ای نیست';

  @override
  String get circlesEmptyMessage =>
      'یک حلقه بساز تا اشتراک موقعیت مکانی‌ات با دوستان و خانوادهٔ مورد اعتمادت را آغاز کنی.';

  @override
  String get circlesSheetEmptyMessage =>
      'یک حلقه بساز تا اشتراک موقعیت مکانی‌ات با مخاطبان مورد اعتمادت را آغاز کنی.';

  @override
  String get circlesLoadError => 'نتوانستیم حلقه‌ها را بارگذاری کنیم';

  @override
  String get circlesSelectToView => 'برای دیدن اعضا، یک حلقه انتخاب کن';

  @override
  String get circlesNoMembers => 'این حلقه عضوی ندارد';

  @override
  String get createCircleTitle => 'افزودن اعضا';

  @override
  String createCircleSelectedCount(int count) {
    return 'انتخاب‌شده ($count)';
  }

  @override
  String get createCircleEmptyTitle => 'افزودن اعضای حلقه';

  @override
  String get createCircleEmptyMessage =>
      'برای افزودن اعضا، با شناسه جست‌وجو کن یا کد QR آن‌ها را اسکن کن.';

  @override
  String get createCircleNoValidMembers => 'عضو معتبری برای دعوت وجود ندارد';

  @override
  String get createCircleMemberAlreadyAdded => 'این عضو از قبل افزوده شده است';

  @override
  String get createCircleNoIdInQr => 'شناسهٔ معتبری در کد QR یافت نشد';

  @override
  String get createCircleNoAccountFound => 'هیچ حساب Haven یافت نشد';

  @override
  String get createCircleCouldNotVerify => 'نتوانستیم عضو را تأیید کنیم';

  @override
  String get createCircleSomethingWentWrong => 'مشکلی پیش آمد';

  @override
  String get nameCircleTitle => 'نام حلقه‌ات را بگذار';

  @override
  String nameCircleMembersToInvite(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count عضو دعوت می‌شوند',
      one: '$count عضو دعوت می‌شود',
    );
    return '$_temp0';
  }

  @override
  String get nameCircleNameLabel => 'نام حلقه';

  @override
  String get nameCircleNameHint => 'مثلاً خانواده، دوستان نزدیک';

  @override
  String get nameCircleNameEmptyError => 'لطفاً یک نام برای حلقه وارد کنید';

  @override
  String get nameCircleNameTooLongError => 'نام باید ۵۰ نویسه یا کمتر باشد';

  @override
  String get nameCircleSharingInfo =>
      'همهٔ افراد این حلقه می‌توانند موقعیت مکانی و نام نمایشی یکدیگر را ببینند. نام نمایشی تو همان است که در تنظیمات ← هویت تعیین می‌کنی. این حلقه از هر حلقهٔ دیگری که در آن هستی جداست، پس اعضایش نمی‌توانند حلقه‌های دیگرت یا اعضای آن‌ها را ببینند.';

  @override
  String get nameCircleCreateCta => 'ساختن حلقه';

  @override
  String get nameCircleStageCreatingGroup => 'در حال ساختن گروه امن...';

  @override
  String get nameCircleStageSendingInvites => 'در حال فرستادن دعوت‌ها...';

  @override
  String get nameCircleStageComplete => 'انجام شد!';

  @override
  String nameCircleProgressSemantics(String stage) {
    return 'پیشرفت ساخت: $stage';
  }

  @override
  String nameCirclePercentComplete(int percent) {
    return '$percent درصد انجام شد';
  }

  @override
  String nameCircleCreatedSnack(String name, int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'حلقهٔ «$name» ساخته شد! $count دعوت فرستاده شد.',
      one: 'حلقهٔ «$name» ساخته شد! $count دعوت فرستاده شد.',
    );
    return '$_temp0';
  }

  @override
  String get nameCircleIdentityError =>
      'خطای هویت. لطفاً تنظیمات هویت خود را بررسی کنید.';

  @override
  String get nameCircleCreateError =>
      'ساختن حلقه ناموفق بود. لطفاً دوباره تلاش کنید.';

  @override
  String addMemberTitle(String circleName) {
    return 'افزودن به $circleName';
  }

  @override
  String get addMemberInfo =>
      'اعضای جدید پس از پذیرفتن دعوت می‌توانند موقعیت‌های رمزگذاری‌شدهٔ این حلقه را ببینند.';

  @override
  String get addMemberAlreadyInCircle => 'از قبل در این حلقه است';

  @override
  String addMemberSendInvitation(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'فرستادن دعوت‌ها',
      one: 'فرستادن دعوت',
    );
    return '$_temp0';
  }

  @override
  String addMemberSendingInvitation(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'در حال فرستادن دعوت‌ها...',
      one: 'در حال فرستادن دعوت...',
    );
    return '$_temp0';
  }

  @override
  String addMemberSentToCircle(int count, String circleName) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'دعوت‌ها به $circleName فرستاده شدند',
      one: 'دعوت به $circleName فرستاده شد',
    );
    return '$_temp0';
  }

  @override
  String addMemberPartialDelivery(int sent, int total) {
    return 'دعوت‌ها فرستاده شدند ($sent از $total). تحویل بقیه در انتظار است.';
  }

  @override
  String get addMemberError => 'افزودن عضو ناموفق بود. لطفاً دوباره تلاش کنید.';

  @override
  String get qrScannerTitle => 'اسکن کد QR';

  @override
  String get qrScannerToggleFlash => 'تغییر وضعیت فلش';

  @override
  String get qrScannerSwitchCamera => 'تعویض دوربین';

  @override
  String get qrScannerInstruction => 'کد QR را درون کادر قرار بده';

  @override
  String get qrScannerScanning => 'در حال اسکن...';

  @override
  String get circleMemberInvitationPending => 'دعوت در انتظار';

  @override
  String get circleMemberNoRecentLocation => 'موقعیت اخیری وجود ندارد';

  @override
  String get circleMemberRemoveTooltip => 'حذف از حلقه';

  @override
  String get circleMemberAdmin => 'مدیر';

  @override
  String get circleMemberHintPending => 'دعوت در انتظار';

  @override
  String get circleMemberHintNoLocation => 'موقعیتی در دسترس نیست';

  @override
  String get circleMemberHintMember => 'عضو';

  @override
  String get circleMemberHintTapToCenter =>
      'برای تمرکز نقشه روی موقعیتشان ضربه بزن';

  @override
  String get pendingMemberRetryTooltip => 'تلاش دوباره برای تأیید';

  @override
  String get pendingMemberRemoveTooltip => 'حذف عضو';

  @override
  String get pendingMemberValidating => 'در حال تأیید';

  @override
  String get pendingMemberValid => 'معتبر';

  @override
  String get pendingMemberWarning => 'هشدار';

  @override
  String get pendingMemberCheckingAvailability =>
      'در حال بررسی در دسترس بودن...';

  @override
  String get pendingMemberReadyToInvite => 'آمادهٔ دعوت';

  @override
  String get memberSearchHint => 'شناسهٔ عضو را وارد کن...';

  @override
  String get memberSearchPasteTooltip => 'جای‌گذاری از کلیپ‌بورد';

  @override
  String get memberSearchAddTooltip => 'افزودن عضو';

  @override
  String get memberSearchScanTooltip => 'اسکن کد QR';

  @override
  String get memberSearchHelper =>
      'از مخاطبانت کد QR یا شناسهٔ Haven آن‌ها را بخواه';

  @override
  String get memberSearchNoValidId => 'شناسهٔ معتبر Haven یافت نشد';

  @override
  String get memberSearchAlreadyAdded => 'این عضو از قبل افزوده شده است';

  @override
  String selectedMembersMore(int count) {
    return '‏+$count مورد دیگر';
  }

  @override
  String get invitationStatusPending => 'دعوت در انتظار';

  @override
  String get invitationStatusActive => 'فعال';

  @override
  String get invitationStatusDeclined => 'رد شده';

  @override
  String invitationStatusSemantics(String label) {
    return 'وضعیت دعوت: $label';
  }

  @override
  String invitationCardSemantics(String circleName, String inviter, int count) {
    return 'دعوت به پیوستن به $circleName، دعوت‌شده از سوی $inviter، $count عضو';
  }

  @override
  String invitationCardInvitedBySemantics(String inviter) {
    return 'دعوت‌شده از سوی شناسهٔ رمزنگاری $inviter';
  }

  @override
  String invitationCardInvitedBy(String inviter) {
    return 'دعوت‌شده از سوی: $inviter';
  }

  @override
  String invitationCardMemberCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count عضو',
      one: '$count عضو',
    );
    return '$_temp0';
  }

  @override
  String get invitationCardJustNow => 'همین حالا';

  @override
  String invitationCardDaysAgo(int count) {
    return '${count}d پیش';
  }

  @override
  String invitationCardHoursAgo(int count) {
    return '${count}h پیش';
  }

  @override
  String invitationCardMinutesAgo(int count) {
    return '${count}m پیش';
  }

  @override
  String get invitationCardDecline => 'رد کردن';

  @override
  String get invitationCardAccept => 'پذیرفتن';

  @override
  String get invitationAcceptedSnack => 'دعوت پذیرفته شد';

  @override
  String get invitationDeclinedSnack => 'دعوت رد شد';

  @override
  String get invitationAcceptError =>
      'پذیرفتن دعوت ناموفق بود. لطفاً دوباره تلاش کنید.';

  @override
  String get invitationDeclineError =>
      'رد کردن دعوت ناموفق بود. لطفاً دوباره تلاش کنید.';

  @override
  String get circleSelectorLabel => 'انتخابگر حلقه';

  @override
  String get circleSelectorPlaceholder => 'یک حلقه انتخاب کن';

  @override
  String get circleSelectorNewCircle => 'حلقهٔ جدید';

  @override
  String get circleSelectorLoadError => 'بارگذاری حلقه‌ها ناموفق بود';

  @override
  String get circleSelectorExpandedAnnouncement => 'فهرست حلقه‌ها باز شد';

  @override
  String get circleSelectorCollapsedAnnouncement => 'فهرست حلقه‌ها بسته شد';

  @override
  String get circleDetailsButtonTooltip => 'جزئیات حلقه';

  @override
  String get circleDetailsTitle => 'جزئیات حلقه';

  @override
  String get circleDetailsRelaysHeading => 'رله‌های این حلقه';

  @override
  String get circleDetailsNoRelays => '(چیزی ثبت نشده)';

  @override
  String get circleDetailsRelaysNote =>
      'این رله‌ها هنگام ساختن این حلقه انتخاب شده‌اند و هنوز قابل ویرایش به دست کاربر نیستند. مستقل از تنظیمات رلهٔ شخصی تو هستند.';

  @override
  String get circleDetailsAddMember => 'افزودن عضو';

  @override
  String get circleDetailsLeaveCircle => 'ترک حلقه';

  @override
  String get leaveCircleDialogTitle => 'ترک حلقه';

  @override
  String get leaveCircleDialogBody =>
      'آیا مطمئنی که می‌خواهی این حلقه را ترک کنی؟ دیگر به‌روزرسانی‌های موقعیت مکانی اعضایش را دریافت نخواهی کرد. این کار قابل بازگشت نیست.';

  @override
  String get leaveCircleConfirm => 'ترک';

  @override
  String get leaveCircleIdentityUnavailable => 'هویت در دسترس نیست';

  @override
  String get leaveCircleSuccess => 'با موفقیت از حلقه خارج شدی';

  @override
  String get leaveCircleError => 'ترک حلقه ناموفق بود';

  @override
  String get circlesPanelCollapsedAnnouncement => 'پنل حلقه‌ها بسته شد';

  @override
  String get circlesPanelExpandedAnnouncement => 'پنل حلقه‌ها باز شد';

  @override
  String get circlesPanelSlightlyOpenAnnouncement => 'پنل حلقه‌ها کمی باز است';

  @override
  String get circlesPanelHalfOpenAnnouncement => 'پنل حلقه‌ها نیمه‌باز است';

  @override
  String get circleMemberAnnouncementSelf => 'تو';

  @override
  String get circleMemberAnnouncementFallback => 'عضو';

  @override
  String get invitationsRefreshTooltip => 'تازه‌سازی دعوت‌ها';

  @override
  String get invitationsLoadError => 'نتوانستیم دعوت‌ها را بارگذاری کنیم';

  @override
  String get invitationsEmptyTitle => 'دعوتی وجود ندارد';

  @override
  String get invitationsEmptyMessage =>
      'وقتی کسی تو را به یک حلقه دعوت کند، اینجا نمایش داده می‌شود.';

  @override
  String get invitationPillChecking => 'در حال بررسی صندوق ورودی‌ات…';

  @override
  String get invitationPillCheckingAnnouncement =>
      'در حال بررسی صندوق ورودی‌ات';

  @override
  String invitationPillNewCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count دعوت جدید',
      one: '$count دعوت جدید',
    );
    return '$_temp0';
  }

  @override
  String get invitationPillUpToDate => 'همه پاسخ داده شد · چیز جدیدی نیست';

  @override
  String get invitationPillUpToDateAnnouncement =>
      'همهٔ صندوق‌های ورودی پاسخ دادند، چیز جدیدی نیست';

  @override
  String invitationPillPartial(int responded, int total) {
    return '‏$responded از $total صندوق ورودی پاسخ داد';
  }

  @override
  String get invitationPillOffline =>
      'نتوانستیم به صندوق ورودی‌ات دسترسی پیدا کنیم';

  @override
  String get invitationPillOfflineAnnouncement =>
      'نتوانستیم به صندوق ورودی‌ات دسترسی پیدا کنیم، دوباره تلاش کن';

  @override
  String get invitationPillNoInbox => 'هیچ صندوق ورودی‌ای تنظیم نشده';

  @override
  String get invitationPillSetUp => 'تنظیم';

  @override
  String get invitationPillDone => 'انجام شد';

  @override
  String get identityTitle => 'هویت';

  @override
  String get identityLoadError =>
      'هنگام بارگذاری هویت تو مشکلی پیش آمد. لطفاً دوباره تلاش کنید.';

  @override
  String get identityMissingTitle => 'بدون هویت';

  @override
  String get identityMissingMessage =>
      'هویت تو از بین رفته است. برای ادامهٔ استفاده از Haven یک هویت تازه بساز.';

  @override
  String get identitySetUpCta => 'تنظیم هویت';

  @override
  String get identityPublicKeyQrTitle => 'کد QR کلید عمومی';

  @override
  String get identityPublicKeyQrSubtitle =>
      'این‌گونه دیگران تو را به حلقه‌ها دعوت می‌کنند';

  @override
  String get identityAdvancedTitle => 'پیشرفته';

  @override
  String get identityAdvancedSubtitle => 'کلید عمومی، کلید خصوصی، حذف';

  @override
  String get identityVisibilityNote =>
      'فقط اعضای حلقه‌هایی که به آن‌ها پیوسته‌ای می‌توانند عکس و نام نمایشی تو را ببینند. دعوت‌ها با کلیدهای عمومی یا کدهای QR فرستاده می‌شوند.';

  @override
  String get identityAdvancedExportError =>
      'استخراج کلید خصوصی ناموفق بود. لطفاً دوباره تلاش کنید.';

  @override
  String get identityAdvancedDeleteTitle => 'هویت حذف شود؟';

  @override
  String get identityAdvancedDeleteBody =>
      'این کار هویت تو را برای همیشه حذف می‌کند. اگر می‌خواهی بتوانی آن را بازیابی کنی، مطمئن شو که از کلید خصوصی‌ات پشتیبان گرفته‌ای.';

  @override
  String get identityAdvancedDeleteConfirm => 'حذف';

  @override
  String get identityAdvancedDeletedSnack => 'هویت حذف شد';

  @override
  String get identityAdvancedDeleteError =>
      'حذف هویت ناموفق بود. لطفاً دوباره تلاش کنید.';

  @override
  String identityAdvancedCopiedToClipboard(String label) {
    return '$label در کلیپ‌بورد کپی شد';
  }

  @override
  String get identityAdvancedSecretCopiedWarning =>
      'کلید خصوصی کپی شد. هشدار: برنامه‌های دیگر ممکن است کلیپ‌بورد تو را بخوانند. آن را در جایی امن جای‌گذاری کن و کلیپ‌بوردت را پاک کن.';

  @override
  String get identityAdvancedMissingBody => 'هیچ هویتی تنظیم نشده است.';

  @override
  String get identityAdvancedPublicKeyLabel => 'کلید عمومی';

  @override
  String get identityAdvancedPublicKeyHexLabel => 'کلید عمومی (hex)';

  @override
  String get identityAdvancedCopyValue => 'کلید عمومی';

  @override
  String get identityAdvancedCopyPublicKeyTooltip => 'کپی کلید عمومی';

  @override
  String get identityAdvancedCopyHexTooltip => 'کپی hex';

  @override
  String get identityAdvancedSecretKeyTitle => 'کلید خصوصی';

  @override
  String get identityAdvancedSecretKeyWarning =>
      'کلید خصوصی تو دسترسی کامل به هویتت را می‌دهد. هرگز آن را با کسی به اشتراک نگذار.';

  @override
  String get identityAdvancedRevealSecretKey => 'نمایش کلید خصوصی';

  @override
  String get identityAdvancedHideSecretKey => 'پنهان کردن کلید خصوصی';

  @override
  String get identityAdvancedCopySecretKeyTooltip => 'کپی کلید خصوصی';

  @override
  String get identityAdvancedDeleteIdentityCta => 'حذف هویت';

  @override
  String get qrCodeLoadError =>
      'هنگام بارگذاری کلید عمومی تو مشکلی پیش آمد. لطفاً دوباره تلاش کنید.';

  @override
  String get qrCodeYourPublicKeyLabel => 'کلید عمومی تو';

  @override
  String get qrCodeWhatIsThisTitle => 'این چیست؟';

  @override
  String get qrCodeExplainerKeys =>
      'Haven روی Nostr اجرا می‌شود، یک شبکهٔ باز که هیچ حساب شرکتی یا ثبت‌نامی پشت آن نیست. هویت تو فقط یک جفت کلید است: یک کلید خصوصی که تنها در اختیار توست، و این کلید عمومی که از آن ساخته شده است.';

  @override
  String get qrCodeExplainerUsername =>
      'کلید عمومی تو مانند یک نام کاربری کار می‌کند که به اشتراک گذاشتنش امن است. مردم این کد را اسکن می‌کنند، یا کلید عمومی تو را جای‌گذاری می‌کنند، تا تو را به یک حلقه دعوت کنند. این کلید نمی‌تواند نام نمایشی، عکس یا موقعیت مکانی تو را آشکار کند، که فقط با اعضای حلقه‌هایی که به آن‌ها پیوسته‌ای به اشتراک گذاشته می‌شوند.';

  @override
  String get displayNameCardTitle => 'نام نمایشی';

  @override
  String get displayNameCardLoadError =>
      'نتوانستیم نام نمایشی تو را بارگذاری کنیم. بعداً دوباره تلاش کن.';

  @override
  String get displayNameCardHint => 'نام نمایشی‌ات را وارد کن';

  @override
  String get displayNameCardSavedLabel => 'نام نمایشی ذخیره شد';

  @override
  String get displayNameCardSaveLabel => 'ذخیرهٔ نام نمایشی';

  @override
  String get displayNameCardSavingLabel => 'در حال ذخیرهٔ نام نمایشی';

  @override
  String get displayNameCardRetryLabel => 'ذخیره ناموفق بود. تلاش دوباره';

  @override
  String get displayNameCardSavedAnnouncement => 'نام نمایشی ذخیره شد';

  @override
  String get displayNameCardSaveFailedAnnouncement =>
      'ذخیره ناموفق بود، دوباره تلاش کن';

  @override
  String keyDisplayCopiedToClipboard(String label) {
    return '$label در کلیپ‌بورد کپی شد';
  }

  @override
  String keyDisplaySemantics(String label, String state) {
    return '$label: $state';
  }

  @override
  String get keyDisplayStateRevealed => 'نمایش‌داده‌شده';

  @override
  String get keyDisplayStateHidden => 'پنهان';

  @override
  String get keyDisplayHideTooltip => 'پنهان کردن';

  @override
  String get keyDisplayRevealTooltip => 'نمایش';

  @override
  String get keyDisplayCopyTooltip => 'کپی';

  @override
  String get keyDisplayCompactCopied => 'کلید در کلیپ‌بورد کپی شد';

  @override
  String get keyDisplayCompactTapToCopy => 'برای کپی ضربه بزن';

  @override
  String get npubQrCopiedSnack => 'کلید عمومی در کلیپ‌بورد کپی شد';

  @override
  String get npubQrCopyButton => 'کپی کلید عمومی';

  @override
  String get npubQrScanLabel => 'برای افزودن من اسکن کن';

  @override
  String get npubQrSemanticsLabel => 'کد QR هویت عمومی تو';

  @override
  String get photoHeaderRemoveTitle => 'عکس نمایه حذف شود؟';

  @override
  String get photoHeaderRemoveBody =>
      'این کار عکس تو را برای همهٔ افراد حلقه‌هایت حذف می‌کند.';

  @override
  String get photoHeaderEditPhoto => 'ویرایش عکس';

  @override
  String get photoHeaderRemove => 'حذف';

  @override
  String get photoHeaderViewPhotoSemantics => 'دیدن عکس نمایه';

  @override
  String get photoHeaderAddPhotoSemantics => 'افزودن عکس نمایه';

  @override
  String get photoHeaderChangePhotoSemantics => 'تغییر عکس نمایه';

  @override
  String get avatarPickerPhotoUpdated =>
      'عکس به‌روزرسانی شد — با حلقه‌هایت به اشتراک گذاشته شد، با رمزگذاری سرتاسری.';

  @override
  String get avatarPickerPhotoRemoved => 'عکس حذف شد.';

  @override
  String get avatarPickerRemoveError =>
      'نتوانستیم عکس تو را حذف کنیم. لطفاً دوباره تلاش کنید.';

  @override
  String get avatarPickerUpdateError =>
      'نتوانستیم عکس تو را به‌روزرسانی کنیم. لطفاً دوباره تلاش کنید.';

  @override
  String get avatarPickerCropTitle => 'برش عکس';

  @override
  String get avatarPickerCropDone => 'انجام شد';

  @override
  String get avatarPickerCropCancel => 'لغو';

  @override
  String get avatarFullscreenClose => 'بستن';

  @override
  String get avatarFullscreenSemantics => 'عکس نمایه، تمام‌صفحه';

  @override
  String get avatarFullscreenLoadError => 'نتوانستیم عکس را بارگذاری کنیم';

  @override
  String get mapInitializing => 'در حال راه‌اندازی...';

  @override
  String get mapInitFailedTitle => 'راه‌اندازی ناموفق بود';

  @override
  String get mapInitFailedMessage =>
      'راه‌اندازی سرویس‌های موقعیت مکانی ناموفق بود.';

  @override
  String get mapInitFailedRetry =>
      'راه‌اندازی ناموفق بود. لطفاً دوباره تلاش کنید.';

  @override
  String get mapLocationOffMessage =>
      'موقعیت مکانی را روشن کن تا خودت و حلقه‌هایت را روی نقشه ببینی.';

  @override
  String get mapGettingLocation => 'در حال دریافت موقعیت مکانی...';

  @override
  String get mapLoadingMap => 'در حال بارگذاری نقشه...';

  @override
  String get mapLocationOffTitle => 'موقعیت مکانی خاموش است';

  @override
  String get mapLocationErrorTitle => 'خطای موقعیت مکانی';

  @override
  String get mapLocationUnavailable => 'موقعیت مکانی موقتاً در دسترس نیست';

  @override
  String get mapThisLocation => 'این موقعیت';

  @override
  String get mapMemberFallbackName => 'عضو';

  @override
  String mapOpenInAppleMapsTitle(String label) {
    return '‏$label در Apple Maps باز شود؟';
  }

  @override
  String get mapOpenInAppleMapsBody =>
      'فقط مختصات نقشه به Apple Maps فرستاده می‌شود، هرگز نام یا هویتی فرستاده نمی‌شود.';

  @override
  String get mapOpenInAppleMapsConfirm => 'باز کردن در Apple Maps';

  @override
  String get mapOpenMapsError => 'نتوانستیم Maps را باز کنیم';

  @override
  String get mapControlsZoomIn => 'بزرگ‌نمایی';

  @override
  String get mapControlsZoomOut => 'کوچک‌نمایی';

  @override
  String get mapControlsRecenter => 'بازگرداندن به مرکز';

  @override
  String get mapControlsRecenterFab => 'بازگرداندن به موقعیت من';

  @override
  String get mapAttributionCreditsButton => 'اعتبارها و مجوز نقشه';

  @override
  String userLocationMarkerSemantics(String accuracy) {
    return 'نشانگر موقعیت تو$accuracy';
  }

  @override
  String userLocationMarkerAccuracy(int meters) {
    return '. دقت: $meters متر';
  }

  @override
  String memberMarkerMinutesShort(int count) {
    return '${count}m';
  }

  @override
  String memberMarkerHoursShort(int count) {
    return '${count}h';
  }

  @override
  String memberMarkerDaysShort(int count) {
    return '${count}d';
  }

  @override
  String memberMarkerMinutesAgoSemantics(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count دقیقه پیش',
      one: '$count دقیقه پیش',
    );
    return '$_temp0';
  }

  @override
  String memberMarkerHoursAgoSemantics(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count ساعت پیش',
      one: '$count ساعت پیش',
    );
    return '$_temp0';
  }

  @override
  String memberMarkerDaysAgoSemantics(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count روز پیش',
      one: '$count روز پیش',
    );
    return '$_temp0';
  }

  @override
  String memberMarkerNamedSemantics(String name) {
    return 'نشانگر عضو $name';
  }

  @override
  String get memberMarkerGenericSemantics => 'نشانگر عضو';

  @override
  String memberMarkerLastSeenSemantics(String base, String age) {
    return '$base، آخرین بار دیده‌شده $age';
  }

  @override
  String get commonAdd => 'افزودن';

  @override
  String get addRelaySheetTitleInbox => 'افزودن رلهٔ صندوق ورودی';

  @override
  String get addRelaySheetTitleKeyPackage => 'افزودن رلهٔ KeyPackage';

  @override
  String get addRelaySheetHint => 'wss://relay.example.com';

  @override
  String get addRelaySheetPasteTooltip => 'جای‌گذاری از کلیپ‌بورد';

  @override
  String get addRelaySheetErrorEmpty => 'یک آدرس رله وارد کن.';

  @override
  String get addRelaySheetErrorInsecureScheme =>
      'از ‏wss://‏ استفاده کن تا ترافیک به این رله رمزگذاری شود.';

  @override
  String get addRelaySheetErrorHasCredentials =>
      'آدرس رله نباید حاوی اطلاعات ورود باشد.';

  @override
  String get addRelaySheetErrorInvalidFormat =>
      'یک آدرس رله مانند ‏wss://relay.example.com‏ وارد کن.';

  @override
  String get avatarSemanticsLabel => 'آواتار کاربر';

  @override
  String avatarSemanticsFor(String initials) {
    return 'برای $initials';
  }

  @override
  String get avatarSemanticsOnline => 'آنلاین';

  @override
  String get avatarSemanticsOffline => 'آفلاین';
}
