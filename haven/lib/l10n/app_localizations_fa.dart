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
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$countString دعوت در انتظار',
      one: '$countString دعوت در انتظار',
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
    final intl.NumberFormat currentNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String currentString = currentNumberFormat.format(current);
    final intl.NumberFormat totalNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String totalString = totalNumberFormat.format(total);

    return 'مرحلهٔ $currentString از $totalString';
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
      'Haven هیچ سرور مرکزی ندارد. پیام‌های رمزگذاری‌شده‌ات از میان سرورهای مستقلی می‌گذرند که رله نامیده می‌شوند، و خودت انتخاب می‌کنی از کدام‌ها استفاده کنی. هیچ شرکت یا دولتی به‌تنهایی نمی‌تواند این شبکه را خاموش کند.';

  @override
  String get onboardingValueProp3Title => 'نیازی به حساب کاربری نیست';

  @override
  String get onboardingValueProp3Body =>
      'بدون ایمیل، بدون شمارهٔ تلفن، بدون ثبت‌نام. Haven هویتی می‌سازد که کلید خصوصی‌اش هرگز از گوشی‌ات بیرون نمی‌رود، پس هیچ حسابی هم وجود ندارد که کسی بتواند آن را تحویل دهد.';

  @override
  String get onboardingValueProp1Summary =>
      'روی دستگاه شما رمزنگاری می‌شود؛ فقط حلقه‌هایی که انتخاب می‌کنید می‌توانند آن را ببینند.';

  @override
  String get onboardingValueProp2Summary =>
      'بدون سرور مرکزی. روی شبکه‌ای از رله‌ها که خودت انتخاب می‌کنی اجرا می‌شود.';

  @override
  String get onboardingValueProp3Summary =>
      'بدون ایمیل، تلفن یا ثبت‌نام. کلید خصوصی‌ات هرگز از گوشی‌ات بیرون نمی‌رود.';

  @override
  String get onboardingCreateIdentityTitle => 'هویت خود را بسازید';

  @override
  String get onboardingCreateIdentityBody =>
      'Haven کلیدهایت را روی همین گوشی می‌سازد. کلید خصوصی هرگز از آن بیرون نمی‌رود.';

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
  String get onboardingDisplayNameHint => 'مثلاً علی';

  @override
  String get onboardingDisplayNameError =>
      'نتوانستیم آن نام را ذخیره کنیم. لطفاً دوباره تلاش کنید.';

  @override
  String get onboardingAddPhotoOptional => 'افزودن عکس (اختیاری)';

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
      'جایی که دعوت‌ها به تو می‌رسند (kind 10050)';

  @override
  String get relaySettingsKeyPackageTitle => 'رله‌های KeyPackage من';

  @override
  String get relaySettingsKeyPackageSubtitle =>
      'جایی که دیگران کلیدهای لازم برای دعوت کردنت را پیدا می‌کنند (kind 10002)';

  @override
  String get relaySettingsProfileTitle => 'رله‌های نمایهٔ من';

  @override
  String get relaySettingsProfileSubtitle =>
      'جایی که نمایهٔ عمومی‌ات جست‌وجو و منتشر می‌شود. این رله‌ها جدا از رله‌های دیگرت نگه داشته می‌شوند و فهرست رله‌های نمایه‌ات هرگز منتشر نمی‌شود (kind 0)';

  @override
  String get relaySettingsProfileUnderflowTitle =>
      'جست‌وجوی نمایه‌ها موقتاً متوقف شد';

  @override
  String get relaySettingsProfileUnderflowMessage =>
      'تعداد رله‌های نمایه بسیار کم شده است، بنابراین نام و عکس اعضا دیگر به‌روز نمی‌شوند.';

  @override
  String get relaySettingsProfileUnderflowRestoreButton =>
      'بازگرداندن رله‌های پیش‌فرض نمایه';

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
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other:
          '$countString رلهٔ کنونی تو با پیش‌فرض‌های Haven جایگزین می‌شوند. این کار قابل بازگشت نیست.',
      one:
          '$countString رلهٔ کنونی تو با پیش‌فرض‌های Haven جایگزین می‌شود. این کار قابل بازگشت نیست.',
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
  String get relaySettingsProfileContaminationTooltip =>
      'بقیهٔ ترافیک تو در Haven را هم حمل می‌کند';

  @override
  String relaySettingsProfileContaminationSemantics(String url) {
    return 'هشدار: $url بقیهٔ ترافیک تو در Haven را هم حمل می‌کند؛ پس این رله می‌تواند نمایه‌ات را به همان ترافیک گره بزند';
  }

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
      'Haven هر وقت برنامه باز باشد موقعیت مکانی‌ات را با حلقه‌هایت به اشتراک می‌گذارد. این را روشن کن تا حلقه‌هایت وقتی Haven در پس‌زمینه است هم آن را ببینند؛ اگر سیستم Haven را ببندد، به‌روزرسانی‌ها با جابه‌جا شدنت یا با بیدار شدن بعدیِ برنامه به دست سیستم از سر گرفته می‌شوند.';

  @override
  String get locationSettingsToggleTitle => 'اشتراک‌گذاری در پس‌زمینه';

  @override
  String get locationSettingsToggleSubtitle =>
      'وقتی برنامه بسته است همچنان به اشتراک‌گذاری ادامه بده';

  @override
  String get locationSettingsIosLimitedNote =>
      'اشتراک‌گذاری با همین مجوز فعلی همچنان در پس‌زمینه کار می‌کند. در تنظیمات، موقعیت مکانی Haven را روی «همیشه» بگذار تا پس از آنکه iOS برنامه را بست هم به‌روزرسانی‌ها از سر گرفته شوند.';

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
      'تا وقتی اشتراک‌گذاری در پس‌زمینه روشن است، Haven یک نشست پیوستهٔ موقعیت مکانی را فعال نگه می‌دارد و iOS یک نشانگر آبی در نوار وضعیت نمایش می‌دهد. اگر مجوز «همیشه» را هم بدهی، Haven می‌تواند پس از آنکه iOS برنامه را بست، خودش را با حلقه‌هایت به‌روز کند.';

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
  String get aboutVpnLinkLabel => 'mullvad.net';

  @override
  String get aboutFooterLicense => 'تحت مجوز MIT License';

  @override
  String aboutFooterVersion(String version) {
    return 'نسخهٔ $version';
  }

  @override
  String get privacyTitle => 'حریم خصوصی';

  @override
  String get privacySubtitle =>
      'Haven چگونه کار می‌کند و دیگران چه چیزی را می‌بینند';

  @override
  String get privacyHubSummary =>
      'Haven موقعیت مکانی‌ات را فقط با همان گروه‌های کوچکی که خودت انتخاب می‌کنی به اشتراک می‌گذارد؛ به آن‌ها حلقه می‌گوییم. پیش از خروج از گوشی هم رمزگذاری‌اش می‌کند. نه ثبت‌نامی هست و نه سروری از آنِ Haven. تنها چیزی که عمومی است، نام نمایشی و عکسی است که تعیین می‌کنی. صفحه‌های زیر این را، و هر چیز دیگر را، با زبان ساده توضیح می‌دهند.';

  @override
  String get privacyGroupBasicsHeading => 'مبانی';

  @override
  String get privacyMeansForYouLabel => 'این برای تو چه معنایی دارد';

  @override
  String get privacyMoreDetailLabel => 'با جزئیات بیشتر';

  @override
  String get privacyMoreDetailExpandHint => 'نمایش جزئیات فنی';

  @override
  String get privacyMoreDetailCollapseHint => 'پنهان کردن جزئیات فنی';

  @override
  String get privacyMoreDetailExpandedAnnouncement =>
      'جزئیات فنی نمایش داده شد';

  @override
  String get privacyMoreDetailCollapsedAnnouncement => 'جزئیات فنی پنهان شد';

  @override
  String get privacyWhatHavenIsTitle => 'Haven چیست و چرا حساب کاربری ندارد';

  @override
  String get privacyWhatHavenIsSubtitle => 'بدون ثبت‌نام، بدون سرور شرکتی';

  @override
  String get privacyWhatHavenIsNoAccount =>
      'Haven موقعیت مکانی‌ات را با گروه‌های کوچکی که خودت انتخاب می‌کنی به اشتراک می‌گذارد؛ به آن‌ها حلقه می‌گوییم. هیچ حساب کاربری پشت این کار نیست. هرگز ایمیل، شمارهٔ تلفن یا گذرواژه نمی‌دهی.';

  @override
  String get privacyWhatHavenIsNoServers =>
      'Haven هیچ سروری از خودش هم اجرا نمی‌کند. به‌روزرسانی‌های رمزگذاری‌شدهٔ موقعیت مکانی‌ات از میان سرورهای مستقلی می‌گذرند که رله نامیده می‌شوند و دیگران آن‌ها را اجرا می‌کنند. توسعه‌دهندگان Haven نمی‌توانند موقعیت مکانی‌ات را ببینند و هیچ ردیابی‌ای در برنامه نگذاشته‌اند. تنها چیزی که می‌بینند مجموع میزان استفاده از نقشه است، چون تکه‌های نقشه با یک کلید دسترسی مشترک گرفته می‌شوند و هرگز معلوم نمی‌شود چه کسی آن‌ها را گرفته است.';

  @override
  String get privacyWhatHavenIsMeansForYou =>
      'هیچ‌کس را نمی‌شود وادار کرد داده‌هایت را تحویل بدهد، چون هیچ‌کس آن‌ها را نگه نمی‌دارد. بهایش این است که هیچ‌کس هم نمی‌تواند هویتت را برایت بازیابی کند. برای اینکه بدانی از چه چیزی باید پشتیبان بگیری، «دو کلید تو» را ببین.';

  @override
  String get privacyWhatHavenIsDetailNoTelemetry =>
      'برنامه هیچ کدی برای آمارگیری، گزارش خرابی یا تبلیغات ندارد. چون Haven متن‌باز است، می‌شود این را بررسی کرد و لازم نیست فقط به آن اعتماد کنی.';

  @override
  String get privacyWhatHavenIsDetailNoPush =>
      'Haven به‌عمد اعلان فوری هم ندارد. یک سرویس اعلان باید هر بار که کسی در حلقه‌هایت چیزی برای رساندن داشت باخبر می‌شد، و این بیش از رله‌ها از عادت‌های تو پرده برمی‌داشت.';

  @override
  String get privacyYourKeysTitle => 'دو کلید تو: یکی خصوصی، یکی برای اشتراک';

  @override
  String get privacyYourKeysSubtitle =>
      'چه چیزی تو را شناسایی می‌کند و از چه چیزی پشتیبان بگیری';

  @override
  String get privacyYourKeysWhatTheyAre =>
      'به‌جای نام کاربری و گذرواژه، یک جفت کلید داری. کلید خصوصی ثابت می‌کند که تو خودتی. کلید عمومی همان چیزی است که دیگران با آن تو را پیدا و دعوت می‌کنند.';

  @override
  String get privacyYourKeysSecretStaysHere =>
      'کلید خصوصی‌ات فقط روی همین گوشی نگه داشته می‌شود، در فضای ذخیره‌سازی‌ای که سیستم‌عامل از آن محافظت می‌کند. Haven هرگز آن را جایی نمی‌فرستد: نه به هیچ سروری، نه به ما.';

  @override
  String get privacyYourKeysPublicIsSafe =>
      'دادن کلید عمومی‌ات به دیگران بی‌خطر است. مثل نام کاربری کار می‌کند که هر جا بخواهی می‌توانی منتشرش کنی. به اشتراک گذاشتنش نمی‌تواند لو بدهد کجایی.';

  @override
  String get privacyYourKeysMeansForYou =>
      'برای نگه داشتن این هویت، از آن پشتیبان بگیر. به تنظیمات ← هویت ← پیشرفته برو، «نمایش کلید خصوصی» را بزن، و آن را جایی امن مثل یک مدیر گذرواژه ذخیره کن. بدون آن پشتیبان، از دست دادن گوشی یعنی از دست دادن همیشگی این هویت.';

  @override
  String get privacyYourKeysNeverShareSecret =>
      'هر کسی کلید خصوصی‌ات را به دست بیاورد، تبدیل به تو می‌شود. می‌تواند به‌جای تو به حلقه‌ها بپیوندد یا به نام تو مطلب منتشر کند. هرگز آن را در برنامهٔ دیگری، در یک پیام یا در یک وب‌سایت جای‌گذاری نکن.';

  @override
  String get privacyYourKeysDetailFormats =>
      'هر دو کلید secp256k1 هستند و در قالب‌های استاندارد Nostr نشان داده می‌شوند: کلید عمومی با npub1 آغاز می‌شود و کلید خصوصی با nsec1. امضا داخل برنامه انجام می‌شود، و کلید خصوصی به‌محض استفاده از بخش‌هایی که مستقیم با آن سر و کار دارند پاک می‌شود.';

  @override
  String get privacyYourKeysDetailSeparation =>
      'کلیدهایی که پیام‌های حلقه‌هایت را رمزگذاری می‌کنند از این کلید هویت جدا هستند و فقط خود برنامه آن‌ها را نگه می‌دارد. این جدایی عمدی است: کلیدی که نام تو را حمل می‌کند همان کلیدی نیست که آنچه فرستاده‌ای را باز می‌کند.';

  @override
  String get privacyPublicProfileTitle => 'نام و عکس تو عمومی‌اند';

  @override
  String get privacyPublicProfileSubtitle =>
      'برای هر کسی دیده می‌شوند، نه فقط حلقه‌هایت';

  @override
  String get privacyPublicProfileIsPublic =>
      'نام نمایشی و عکسی که تعیین می‌کنی روی Nostr منتشر می‌شوند، همان شبکهٔ عمومی و بازی که Haven روی آن کار می‌کند. هر کسی می‌تواند آن‌ها را جست‌وجو کند، نه فقط افرادِ حلقه‌هایت.';

  @override
  String get privacyPublicProfileOnSave =>
      'نام و عکست همان لحظه‌ای که ذخیره‌شان می‌کنی عمومی می‌شوند. هیچ تنظیمی نیست که آن‌ها را خصوصی نگه دارد، و هیچ راهی نیست که نامی را فقط با حلقه‌هایت به اشتراک بگذاری.';

  @override
  String get privacyPublicProfilePseudonym =>
      'نصب‌های تازه با یک نام ساختگی مثل «Quiet Wanderer» شروع می‌شوند که هیچ چیزی دربارهٔ تو نمی‌گوید. می‌توانی نگهش داری یا با هر چه دوست داری عوضش کنی.';

  @override
  String get privacyPublicProfileMeansForYou =>
      'نام و عکسی را انتخاب کن که از نشان دادنشان در فضای عمومی خوشحال باشی. اگر ترجیح می‌دهی شناخته نشوی، همان نام ساختگی را که به تو داده شده نگه دار و از عکس بگذر.';

  @override
  String get privacyPublicProfileRemovalIsNotDeletion =>
      'برداشتن عکست در آینده، نسخهٔ روی سرور را حذف نمی‌کند. Haven نمایه‌ات را با یک نمایهٔ خالی جایگزین می‌کند. فایل تصویر همان‌جا که میزبانی می‌شود می‌ماند، و هر نسخه‌ای که پیش‌تر دانلود شده دست دیگران می‌ماند. هر چه را منتشر می‌کنی دائمی در نظر بگیر.';

  @override
  String get privacyPublicProfileDetailKindZero =>
      'نمایه یک رویداد «kind 0» در Nostr است که با کلید هویتت امضا می‌شود. عکس‌ها روی یک میزبان عمومی تصویر بارگذاری می‌شوند، یعنی blossom.primal.net، که تصویر، کلید عمومی و آدرس شبکه‌ات را می‌بیند. Haven هنوز اجازه نمی‌دهد میزبان دیگری انتخاب کنی.';

  @override
  String get privacyPublicProfileDetailExifStripped =>
      'Haven پیش از بارگذاری، تصویر را دوباره کدگذاری می‌کند و داده‌های پنهانی را که دوربین‌ها به آن می‌چسبانند حذف می‌کند، از جمله موقعیت GPS جایی که عکس گرفته شده است. این موضوع اینجا مهم است: وگرنه یک عکس تعطیلات می‌تواند مختصات خانه‌ات را با خود حمل کند.';

  @override
  String get privacyGroupHowLocationTravelsHeading =>
      'موقعیت مکانی‌ات چگونه سفر می‌کند';

  @override
  String get privacyRelaysTitle => 'رله‌ها: سرورهایی که پیام‌ها را می‌رسانند';

  @override
  String get privacyRelaysSubtitle =>
      'به‌روزرسانی‌هایت از رایانهٔ چه کسانی می‌گذرد';

  @override
  String get privacyRelaysWhatIsARelay =>
      'Haven سرور خودش را ندارد، پس به‌روزرسانی‌هایت از سرورهای دیگران می‌گذرند. به این‌ها رله می‌گویند: سرورهای کوچک و مستقلی که هرکسی می‌تواند راه‌اندازی کند. یک رله پیام رمزگذاری‌شده را کوتاه‌مدت نگه می‌دارد و بعد، وقتی حلقه‌ات آن را بخواهد، تحویلش می‌دهد.';

  @override
  String get privacyRelaysWhyMany =>
      'Haven از چند رله استفاده می‌کند، پس هیچ‌کدام به‌تنهایی نمی‌تواند تو را قطع کند. اگر یکی از کار بیفتد، بقیه به کار خود ادامه می‌دهند. تو رله‌هایی را انتخاب می‌کنی که دعوت‌ها از آن‌ها به تو می‌رسند؛ رله‌هایی که یک حلقه به کار می‌برد، هنگام ساخته شدن آن حلقه تعیین می‌شوند.';

  @override
  String get privacyRelaysYourLists =>
      'Haven سه فهرست برایت نگه می‌دارد. رله‌های صندوق ورودی‌ات جایی‌اند که دعوت‌ها به تو می‌رسند، و رله‌های KeyPackage جایی‌اند که دیگران کلیدهای لازم برای دعوت کردن تو را از آن‌ها می‌گیرند — Haven هر دوی این فهرست‌ها را منتشر می‌کند تا دیگران بتوانند آن‌ها را پیدا کنند. رله‌های نمایه‌ات فرق دارند: نام و عکست از آن‌ها خوانده و روی آن‌ها منتشر می‌شود، اما خودِ فهرست روی دستگاهت می‌ماند و هرگز منتشر نمی‌شود. بنابراین رله‌ای که فقط ترافیک موقعیت مکانی یا دعوت‌های تو را حمل می‌کند، هیچ فهرست عمومی ندارد که به آن بگوید برای نمایه‌ات از کدام رله‌ها استفاده می‌کنی. هر حلقه هم فهرست خودش را دارد، و به‌روزرسانی‌های رمزگذاری‌شدهٔ آن حلقه از همان فهرست می‌گذرند.';

  @override
  String get privacyRelaysMeansForYou =>
      'یک رله هرگز موقعیت مکانی‌ات را نمی‌بیند، چون پیش از خروج از گوشی رمزگذاری شده است. اما آنچه را باید عمومی باشد تا دیگران به تو برسند می‌بیند: نام و عکست، کلیدهایی که دیگران برای دعوت کردنت لازم دارند، و خودِ فهرست رله‌هایت. Haven کار را با رله‌هایی که کار می‌کنند برایت شروع می‌کند، پس چیزی نیست که مجبور باشی عوضش کنی.';

  @override
  String get privacyRelaysDetailIndexers =>
      'Haven جدا از فهرست‌های خودت، از مجموعهٔ کوچکی از رله‌های راهنمای عمومی هم پرس‌وجو می‌کند تا نمایه و کلید دیگران را پیدا کند. حتی اگر فقط رله‌های خصوصی خودت را تنظیم کرده باشی، باز هم با آن‌ها تماس می‌گیرد. آن‌ها آدرس شبکه‌ات را می‌بینند و اینکه سراغ کدام حساب‌ها را گرفته‌ای.';

  @override
  String get privacyRelaysDetailKeyListIsPublic =>
      'فهرست رله‌های KeyPackage تو با کلید هویتت امضا می‌شود و روی همان رله‌هایی که از پیش در آن هستند منتشر می‌شود. اگر رله‌ای خصوصی به آن اضافه کنی، آدرسش عمومی می‌شود و به تو گره می‌خورد. هیچ راهی نیست که رله‌ای در آن فهرست خصوصی بماند.';

  @override
  String get privacyEncryptionTitle => 'رمزگذاری چگونه کار می‌کند';

  @override
  String get privacyEncryptionSubtitle =>
      'یک کلید برای هر حلقه، و آنچه با پیوستن یا رفتن افراد تغییر می‌کند';

  @override
  String get privacyEncryptionPerCircle =>
      'موقعیت مکانی‌ات پیش از خروج از گوشی، با یک استاندارد باز به نام MLS رمزگذاری می‌شود. هر حلقه گروه رمزگذاری‌شدهٔ خودش با کلیدهای خودش است. هیچ‌کس از بیرونِ یک حلقه نمی‌تواند آنچه را درون آن فرستاده می‌شود بخواند: نه یک رله، نه خودِ Haven و نه حلقهٔ دیگری که در آن هستی.';

  @override
  String get privacyEncryptionWhenSomeoneJoins =>
      'وقتی کسی می‌پیوندد، حلقه به یک کلید تازه می‌رود. او می‌تواند آنچه پس از رسیدنش فرستاده می‌شود را بخواند، و هیچ چیزی از پیش از آن را. Haven هرگز هیچ موقعیت مکانی گذشته‌ای را برای عضو تازه نمی‌فرستد.';

  @override
  String get privacyEncryptionWhenSomeoneLeaves =>
      'وقتی کسی حلقه‌ای را ترک می‌کند، آن حلقه به کلید تازهٔ دیگری می‌رود. به‌محض اینکه بقیهٔ اعضای حلقه خود را با این تغییر هماهنگ کنند، او دیگر نمی‌تواند چیز تازه‌ای بخواند؛ این کار معمولاً چند دقیقه طول می‌کشد و برای کسی که آن موقع آفلاین بوده بیشتر.';

  @override
  String get privacyEncryptionKeysChangeOnMembership =>
      'ترک کردن یک حلقه، آنچه را اعضایش پیش‌تر ذخیره کرده‌اند پس نمی‌گیرد. Haven کلیدها را فقط وقتی عوض می‌کند که کسی بپیوندد یا برود، هرگز بر پایهٔ زمان‌بندی. پس یک کلید می‌تواند هفته‌ها پیام را پوشش بدهد، و هر چه عضوی در آن مدت ذخیره کرده برایش خواندنی می‌ماند. با این حال او نمی‌تواند چیزی را که پس از رفتنش فرستاده شده باز کند.';

  @override
  String get privacyEncryptionMeansForYou =>
      'رمزگذاری تو را از همهٔ کسانی که بیرون حلقه‌هایت هستند محافظت می‌کند. اما نمی‌تواند تو را از کسی که روزی درون یکی از آن‌ها بوده محافظت کند. اگر می‌خواهی اشتراک‌گذاری با شخص معینی را متوقف کنی، حلقه‌ای را که با او در آن شریکی ترک کن و حلقهٔ تازه‌ای بدون او بساز.';

  @override
  String get privacyEncryptionDetailMls =>
      'استاندارد MLS (Messaging Layer Security) همان استانداردی است که IETF تدوین کرده و پیام‌رسان‌های امن دیگر هم از آن استفاده می‌کنند. Haven از راه پروتکل Marmot به شبکهٔ Nostr می‌رسد؛ همین پروتکل تعیین می‌کند که گروه‌های MLS چگونه روی رله‌ها جابه‌جا می‌شوند. کلیدی که هر حلقه با آن امضا می‌کند از کلید هویت عمومی‌ات در Nostr جداست.';

  @override
  String get privacyEncryptionDetailEpochs =>
      'به هر بازه‌ای که یک کلید در آن کار می‌کند «دوره» می‌گویند، و یک حلقه تنها وقتی به دورهٔ تازه می‌رود که اعضایش عوض شوند. دستگاهت کلیدهای دورهٔ کنونی و چند دورهٔ اخیر را نگه می‌دارد، همان‌قدر که برای باز کردن پیام‌های هنوز در راه بس باشد، و بقیه را دور می‌ریزد. حلقه‌ای که ماه‌هاست اعضایش عوض نشده‌اند، هنوز در همان دوره‌ای است که با آن آغاز شده.';

  @override
  String get privacyWhatOthersSeeTitle =>
      'اعضا چه می‌بینند و رله‌ها چه می‌بینند';

  @override
  String get privacyWhatOthersSeeSubtitle =>
      'کسانی که با آن‌ها به اشتراک می‌گذاری، و سرورهای میان راه';

  @override
  String get privacyWhatOthersSeeMembersHeading => 'افرادِ حلقه‌هایت';

  @override
  String get privacyWhatOthersSeeMembersExact =>
      'هر کسی در یک حلقه، موقعیت دقیق تو را روی نقشه می‌بیند، نه یک محدودهٔ تقریبی. هیچ تنظیمی نیست که موقعیتی مبهم‌تر را با بعضی اعضا و موقعیتی دقیق را با بعضی دیگر به اشتراک بگذارد.';

  @override
  String get privacyWhatOthersSeeCannotPause =>
      'تا وقتی Haven باز است و در حلقه‌ای عضوی، موقعیتت هر دو سه دقیقه خودبه‌خود بیرون می‌رود. دکمهٔ توقف موقت وجود ندارد: گزینهٔ صفحهٔ «موقعیت مکانی» فقط تعیین می‌کند که آیا این کار پس از بستن برنامه ادامه پیدا کند یا نه. برای آنکه اشتراک‌گذاری با یک حلقه را متوقف کنی، آن را باز کن و «ترک حلقه» را انتخاب کن.';

  @override
  String get privacyWhatOthersSeeMembersLearnKey =>
      'پیوستن به یک حلقه، کلید عمومی‌ات را هم به همهٔ اعضا نشان می‌دهد. با آن می‌توانند نمایهٔ عمومی‌ات و هر چیز دیگری را که تا حالا با آن کلید منتشر کرده‌ای پیدا کنند.';

  @override
  String get privacyWhatOthersSeeCoMemberIp =>
      'گوشی‌ات عکس نمایهٔ هر عضو را از سروری می‌گیرد که خود آن عضو انتخاب کرده، بی‌آنکه تو روی چیزی بزنی. آن سرور آن‌گاه آدرس شبکه‌ات را می‌بیند، و همین تقریباً جای تو را روی نقشه مشخص می‌کند. یک VPN این را پنهان می‌کند؛ هیچ چیز دیگری نه.';

  @override
  String get privacyWhatOthersSeeRelaysHeading => 'گردانندگان رله';

  @override
  String get privacyWhatOthersSeeRelaysCannot =>
      'رله‌ها، یعنی همان سرورهای مستقلی که به‌روزرسانی‌هایت از آن‌ها می‌گذرند، نمی‌توانند موقعیت مکانی‌ات، پیام‌هایت، نام حلقه‌ات یا فهرست اعضایش را بخوانند. به‌روزرسانی‌های موقعیت مکانی‌ات به‌جای کلید عمومی‌ات، یک آدرس فرستندهٔ تازه و یک‌بارمصرف با خود دارند. اما نمایه، دعوت‌ها و فهرست‌های رلهٔ تو کلید عمومی‌ات را با خود دارند، پس رله‌ای که هر دوی این‌ها از آن بگذرند اغلب می‌تواند بفهمد که تو در یک حلقه‌ای، بی‌آنکه چیزی از درون آن بخواند.';

  @override
  String get privacyWhatOthersSeeRelaysCan =>
      'آن‌ها آدرس شبکه‌ات، زمان‌هایی که آنلاینی، و اندازه و تکرار ترافیکت را می‌بینند. هر حلقه یک برچسب تصادفی با خود دارد. یک رله می‌تواند پیام‌های یک حلقه را بر پایهٔ همان برچسب کنار هم بگذارد و حدس بزند چند نفر در آن هستند، بی‌آنکه بداند آن‌ها چه کسانی‌اند.';

  @override
  String get privacyWhatOthersSeeMeansForYou =>
      'فقط با کسانی به یک حلقه بپیوند که حاضری نشانی خانه‌ات را به آن‌ها بدهی. رمزگذاری در برابر رله‌ها و بیرونی‌ها پایدار است، و یک VPN آدرسی را که گوشی‌ات از آن وصل می‌شود پنهان می‌کند. هیچ چیزی تو را از عضوی که از صفحه‌نمایش عکس می‌گیرد محافظت نمی‌کند.';

  @override
  String get privacyWhatOthersSeeDetailTag =>
      'برچسب یک حلقه تا پایان عمر آن حلقه همان می‌ماند، پس یک رله می‌تواند همهٔ پیام‌هایش را تا هر وقت که بخواهد به هم پیوند بزند. این ویژگیِ خودِ پروتکل زیرین است، نه چیزی که Haven بتواند عوضش کند.';

  @override
  String get commonLearnMore => 'اطلاعات بیشتر';

  @override
  String get relaySettingsBackendCaption =>
      'Haven سرور خودش را ندارد. به‌روزرسانی‌های رمزگذاری‌شده‌ات از میان سرورهای مستقلی می‌گذرند که رله نامیده می‌شوند و نمی‌توانند موقعیت مکانی یا پیام‌هایت را بخوانند.';

  @override
  String get privacyWhatOthersSeeScreenshots =>
      'این به گوشی‌ات بستگی دارد. Haven روی Android عکس گرفتن از صفحه‌نمایش و ضبط صفحه‌نمایش را در سراسر برنامه مسدود می‌کند. روی iPhone نمی‌تواند: پیش‌نمایش برنامه را در فهرست برنامه‌های باز محو می‌کند، اما یک عضو همچنان می‌تواند از آنچه روی صفحه‌نمایش است عکس بگیرد.';

  @override
  String get privacyWhatOthersSeeDetailExpiry =>
      'Haven از رله‌ها می‌خواهد پیام‌های موقعیت مکانی را پس از حدود چهار دقیقه بیندازند. این درخواست فقط یک توصیه است: رله آزاد است آن‌ها را بیشتر نگه دارد. دعوت‌ها هیچ زمان انقضایی ندارند و می‌توانند تا هر وقت روی رلهٔ صندوق ورودی‌ات بمانند.';

  @override
  String get privacyGroupTheLimitsHeading => 'محدودیت‌ها';

  @override
  String get privacyInferenceTitle => 'چیزهایی که هنوز می‌شود دربارهٔ تو فهمید';

  @override
  String get privacyInferenceSubtitle => 'ردهایی که رمزگذاری نمی‌پوشاند';

  @override
  String get privacyInferenceWhatIsMetadata =>
      'رمزگذاری پنهان می‌کند که چه می‌فرستی. اما نمی‌تواند پنهان کند که چیزی فرستاده‌ای. به آن ردِ باقی‌مانده فراداده می‌گویند: اینکه پیام کِی بیرون رفته، چه اندازه بوده، و به کدام سرورها وصل بوده‌ای. این رد حتی وقتی محتوا پیدا نیست، پیدا می‌ماند.';

  @override
  String get privacyInferenceActivityPattern =>
      'از همان الگو، رله‌ای که از آن استفاده می‌کنی می‌تواند تقریباً بفهمد کِی فعالی و هر چند وقت یک‌بار. Haven هر بار که حدود صد متر جابه‌جا می‌شوی یک به‌روزرسانی اضافی هم می‌فرستد. در طول چند ساعت، همین می‌تواند به یک رله نشان بدهد که در حال حرکت بوده‌ای یا یک جا مانده‌ای. اما هرگز نشان نمی‌دهد کجا.';

  @override
  String get privacyInferencePresence =>
      'تا وقتی Haven در حال اجراست، یک اتصال باز به رله‌هایت نگه می‌دارد. آن‌ها می‌بینند که آنلاینی و کدام برچسب‌های حلقه را دنبال می‌کنی، اما هرگز نام یک حلقه یا اینکه چه کسانی در آن هستند را نمی‌بینند. این بهای آن است که به‌روزرسانی‌ها در چند ثانیه برسند، نه چند دقیقه.';

  @override
  String get privacyInferenceIpHeading => 'آدرس شبکه‌ات';

  @override
  String get privacyInferenceIpAddress =>
      'هر سروری که Haven با آن حرف می‌زند، آدرسی را می‌بیند که گوشی‌ات از آن وصل می‌شود، یعنی آدرس IP آن: رله‌هایت، ارائه‌دهندهٔ نقشه، و هر کسی که عکس نمایهٔ یک عضو را میزبانی می‌کند. ارائه‌دهندهٔ اینترنتت می‌بیند به کدام‌یک از این سرورها رسیده‌ای و کِی. Haven خودش هیچ کاری برای پنهان کردن هیچ‌یک از این دو نمی‌کند.';

  @override
  String get privacyInferenceMapTilesHeading => 'خودِ نقشه';

  @override
  String get privacyInferenceMapTiles =>
      'برای کشیدن نقشه، Haven مربع‌های تصویری را که روی صفحه است از ارائه‌دهندهٔ نقشه می‌گیرد، پس او تقریباً می‌فهمد به چه جاهایی نگاه می‌کنی. Haven محدودهٔ کوچکی را هم دور تا دور هر عضوی که می‌بینی، پیش از آنکه به سراغش بروی، از پیش می‌گیرد تا نقشه آماده باشد؛ یعنی ارائه‌دهنده می‌تواند تقریباً بفهمد افرادِ حلقه‌ات کجا هستند، نه فقط اینکه تو کجا را نگاه می‌کنی. این مربع‌ها تا هفت روز در یک حافظهٔ نهانِ رمزگذاری‌شده روی گوشی‌ات می‌مانند و اگر هویتت را حذف کنی پاک می‌شوند.';

  @override
  String get privacyInferenceVpnHeading => 'آیا به VPN نیاز داری؟';

  @override
  String get privacyInferenceVpnHelps =>
      'یک VPN آدرس شبکه‌ات را با آدرس خودش عوض می‌کند، پس رله‌ها و دیگر سرورها نمی‌بینند از کجا وصل می‌شوی. همچنین از ارائه‌دهندهٔ اینترنتت پنهان می‌کند به چه سرورهایی می‌رسی. ما Mullvad را پیشنهاد می‌کنیم.';

  @override
  String get privacyInferenceVpnLimits =>
      'اما نوشدارو نیست. یک VPN چیزی از آنچه اعضای حلقه‌ات می‌بینند تغییر نمی‌دهد، و زمان‌بندی و اندازهٔ ترافیکت را از رله‌ای که با آن حرف می‌زنی پنهان نمی‌کند. اعتماد تو را هم به شرکت VPN منتقل می‌کند، نه اینکه نیاز به اعتماد کردن را از میان بردارد.';

  @override
  String get privacyInferenceMeansForYou =>
      'نگران رله‌ها، ارائه‌دهندهٔ اینترنتت یا سرورهای نقشه‌ای هستی که تو را روی نقشه می‌گذارند؟ یک VPN مفیدترین چیز واحدی است که می‌توانی اضافه کنی. نگران افرادِ حلقه‌هایت هستی؟ هیچ کمکی نمی‌کند.';

  @override
  String get privacyInferenceDetailJitter =>
      'Haven فاصلهٔ میان به‌روزرسانی‌ها را به‌عمد تغییر می‌دهد، پس یک ضبط کوتاه هیچ ریتم منظمی نشان نمی‌دهد. اما با میانگین‌گیری در طول ساعت‌های متوالی، همچنان می‌شود نرخ اصلی به‌روزرسانی‌ها را تخمین زد. اندازهٔ پیام‌ها هم با دادهٔ اضافی یکسان نمی‌شود، و به‌روزرسانی‌های موقعیت مکانی در بازهٔ باریکی از اندازه قرار می‌گیرند؛ همین باعث می‌شود بتوان آن‌ها را به‌عنوان به‌روزرسانی موقعیت شناخت.';

  @override
  String get privacyInferenceDetailOutOfScope =>
      'دو چیز فراتر از هر انتخاب طراحی در اینجا هستند: ناظری که بتواند چندین رله را هم‌زمان زیر نظر بگیرد، و گوشی خودت وقتی کس دیگری کنترلش را در دست گرفته باشد.';

  @override
  String get commonClearAll => 'پاک کردن همه';

  @override
  String commonMemberCount(int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$countString عضو',
      one: '$countString عضو',
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
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    return 'انتخاب‌شده ($countString)';
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
  String get createCircleNoAccountFound =>
      'برای این شناسه هیچ حساب Haven پیدا نشد';

  @override
  String get createCircleCouldNotVerify => 'نتوانستیم عضو را تأیید کنیم';

  @override
  String get createCircleSomethingWentWrong => 'مشکلی پیش آمد';

  @override
  String get nameCircleTitle => 'نام حلقه‌ات را بگذار';

  @override
  String nameCircleMembersToInvite(int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$countString عضو دعوت می‌شوند',
      one: '$countString عضو دعوت می‌شود',
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
      'همهٔ افراد این حلقه می‌توانند موقعیت مکانی و نام و عکس عمومی یکدیگر را ببینند. نام و عکس تو روی شبکهٔ Nostr عمومی‌اند، نه خصوصیِ این حلقه. این حلقه از هر حلقهٔ دیگری که در آن هستی جداست، پس اعضایش نمی‌توانند حلقه‌های دیگرت یا اعضای آن‌ها را ببینند.';

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
    final intl.NumberFormat percentNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String percentString = percentNumberFormat.format(percent);

    return '$percentString درصد انجام شد';
  }

  @override
  String nameCircleCreatedSnack(String name, int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'حلقهٔ «$name» ساخته شد! $countString دعوت فرستاده شد.',
      one: 'حلقهٔ «$name» ساخته شد! $countString دعوت فرستاده شد.',
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
      'به‌محض اینکه بپذیرد، موقعیت مکانی همه را از آن لحظه به بعد می‌بیند، و هرگز چیزی را که پیش از پیوستنش فرستاده شده نمی‌بیند. کلید عمومی همهٔ کسانی را هم که از پیش در این حلقه‌اند می‌بیند.';

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
    final intl.NumberFormat sentNumberFormat = intl.NumberFormat.decimalPattern(
      localeName,
    );
    final String sentString = sentNumberFormat.format(sent);
    final intl.NumberFormat totalNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String totalString = totalNumberFormat.format(total);

    return 'دعوت‌ها فرستاده شدند ($sentString از $totalString). تحویل بقیه در انتظار است.';
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
  String get pendingMemberRemoveTooltip => 'حذف از فهرست';

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
  String get pendingMemberNeedsUpdate => 'نیاز به به‌روزرسانی Haven دارد';

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
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    return '‏+$countString مورد دیگر';
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
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    return 'دعوت به پیوستن به $circleName، دعوت‌شده از سوی $inviter، $countString عضو';
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
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$countString عضو',
      one: '$countString عضو',
    );
    return '$_temp0';
  }

  @override
  String get invitationCardJustNow => 'همین حالا';

  @override
  String invitationCardDaysAgo(int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    return '${countString}d پیش';
  }

  @override
  String invitationCardHoursAgo(int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    return '${countString}h پیش';
  }

  @override
  String invitationCardMinutesAgo(int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    return '${countString}m پیش';
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
  String circleDetailsMembersWithEpoch(String members, int epoch) {
    final intl.NumberFormat epochNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String epochString = epochNumberFormat.format(epoch);

    return '$members · دوره $epochString';
  }

  @override
  String get circleDetailsRelaysHeading => 'رله‌های این حلقه';

  @override
  String get circleDetailsNoRelays => '(چیزی ثبت نشده)';

  @override
  String get circleDetailsRelaysNote =>
      'این رله‌ها هنگام ساخته شدن این حلقه از رله‌های صندوق ورودی‌ات رونوشت شده‌اند و هنوز نمی‌شود عوضشان کرد. ویرایش‌های بعدیِ فهرست رلهٔ شخصی‌ات آن‌ها را تغییر نمی‌دهد.';

  @override
  String get circleDetailsAddMember => 'افزودن عضو';

  @override
  String get circleDetailsLeaveCircle => 'ترک حلقه';

  @override
  String get leaveCircleDialogTitle => 'ترک حلقه';

  @override
  String get leaveCircleDialogBody =>
      'این حلقه ترک شود؟ دیگر موقعیت مکانی‌ات را برای اعضایش نمی‌فرستی و موقعیت آن‌ها را هم نمی‌بینی. آخرین موقعیتی که فرستاده‌ای تا یک روز روی گوشی‌هایشان می‌ماند. این کار قابل بازگشت نیست: برای پیوستن دوباره به دعوت تازه‌ای نیاز داری.';

  @override
  String get leaveCircleConfirm => 'ترک';

  @override
  String get leaveCircleIdentityUnavailable => 'هویت در دسترس نیست';

  @override
  String get leaveCircleSuccess => 'با موفقیت از حلقه خارج شدی';

  @override
  String get leaveCircleError => 'ترک حلقه ناموفق بود';

  @override
  String get circleBlockedBannerTitle => 'این حلقه قابل به‌روزرسانی نیست';

  @override
  String get circleBlockedBannerBody =>
      'مشکلی در رمزگذاری این حلقه پیش آمده، بنابراین Haven دیگر نمی‌تواند در آن به‌روزرسانی ارسال یا دریافت کند. هنوز می‌توانی آخرین چیزی را که می‌دانستی در پایین ببینی، یا حلقه را ترک کنی.';

  @override
  String get legacyCircleBannerTitle => 'این حلقه باید دوباره ساخته شود';

  @override
  String get legacyCircleBannerBody =>
      'موتور رمزگذاری Haven ارتقا یافته، بنابراین این حلقه دیگر قابل استفاده نیست. آن را دوباره بساز تا بتوانی موقعیت مکانی را همچنان با همان افراد به اشتراک بگذاری. باید دوباره دعوتشان کنی.';

  @override
  String get legacyCircleRecreateCta => 'بازسازی حلقه';

  @override
  String get legacyCircleRemoveCta => 'حذف';

  @override
  String get legacyCircleRemoveDialogTitle => 'حلقه حذف شود؟';

  @override
  String get legacyCircleRemoveDialogBody =>
      'این حلقه دیگر قابل استفاده نیست و از فهرستت حذف خواهد شد. این کار روی هیچ حلقهٔ جدیدی که برای جایگزینی آن می‌سازی اثر نمی‌گذارد.';

  @override
  String get legacyCircleRemoveConfirm => 'حذف';

  @override
  String get legacyCutoverExplainerTitle => 'Haven به‌روزرسانی شده است';

  @override
  String get legacyCutoverExplainerIdentityUnchanged =>
      'هویت و نمایهٔ عمومی‌ات بدون تغییر مانده‌اند. نیازی نیست برای آن‌ها کاری بکنی.';

  @override
  String get legacyCutoverExplainerCirclesNeedRecreation =>
      'برای امنیت بیشتر، باید حلقه‌هایت را از نو بسازی و اعضایشان را دوباره دعوت کنی تا بتوانی باز هم موقعیت مکانی‌ات را در آن‌ها به اشتراک بگذاری.';

  @override
  String get legacyCutoverExplainerAcknowledge => 'متوجه شدم';

  @override
  String get relaySettingsLegacyRetractionPending =>
      'Haven هنوز از رله‌ها می‌خواهد برخی داده‌های قدیمی به‌جامانده از به‌روزرسانی امنیتی اخیر را بیندازند.';

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
  String get refreshRingSemanticNoInbox =>
      'صندوق ورودی پیکربندی نشده است، تنظیمات رله را باز می‌کند';

  @override
  String refreshRingSemanticChecking(int checked, int total) {
    final intl.NumberFormat checkedNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String checkedString = checkedNumberFormat.format(checked);
    final intl.NumberFormat totalNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String totalString = totalNumberFormat.format(total);

    return '$checkedString از $totalString رله بررسی شد';
  }

  @override
  String refreshRingSemanticAllOk(int total) {
    final intl.NumberFormat totalNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String totalString = totalNumberFormat.format(total);

    String _temp0 = intl.Intl.pluralLogic(
      total,
      locale: localeName,
      other: 'همه‌ی $totalString رله پاسخ دادند',
      one: 'رله پاسخ داد',
    );
    return '$_temp0';
  }

  @override
  String get refreshRingSemanticAllError => 'هیچ رله‌ای پاسخ نداد';

  @override
  String refreshRingSemanticPartial(int ok, int total) {
    final intl.NumberFormat okNumberFormat = intl.NumberFormat.decimalPattern(
      localeName,
    );
    final String okString = okNumberFormat.format(ok);
    final intl.NumberFormat totalNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String totalString = totalNumberFormat.format(total);

    return '$okString از $totalString رله پاسخ دادند';
  }

  @override
  String get refreshRingAnnouncementChecking => 'در حال بررسی رله‌ها';

  @override
  String get refreshRingAnnouncementAllOk => 'همه‌ی رله‌ها پاسخ دادند';

  @override
  String refreshRingAnnouncementPartial(int ok, int total) {
    final intl.NumberFormat okNumberFormat = intl.NumberFormat.decimalPattern(
      localeName,
    );
    final String okString = okNumberFormat.format(ok);
    final intl.NumberFormat totalNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String totalString = totalNumberFormat.format(total);

    return '$okString از $totalString رله پاسخ دادند';
  }

  @override
  String get refreshRingAnnouncementAllError =>
      'به هیچ رله‌ای نمی‌توان دسترسی یافت';

  @override
  String get refreshRingAnnouncementNoInbox => 'صندوق ورودی پیکربندی نشده است';

  @override
  String refreshRingSemanticAllFound(int total) {
    final intl.NumberFormat totalNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String totalString = totalNumberFormat.format(total);

    String _temp0 = intl.Intl.pluralLogic(
      total,
      locale: localeName,
      other: 'همه‌ی $totalString رله داده‌های شما را دارند',
      one: 'رله داده‌های شما را دارد',
    );
    return '$_temp0';
  }

  @override
  String get refreshRingSemanticNoneFound => 'هیچ رله‌ای داده‌های شما را ندارد';

  @override
  String refreshRingSemanticPartialFound(int ok, int total) {
    final intl.NumberFormat okNumberFormat = intl.NumberFormat.decimalPattern(
      localeName,
    );
    final String okString = okNumberFormat.format(ok);
    final intl.NumberFormat totalNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String totalString = totalNumberFormat.format(total);

    return '$okString از $totalString رله داده‌های شما را دارند';
  }

  @override
  String get refreshRingAnnouncementAllFound =>
      'همه‌ی رله‌ها داده‌های شما را دارند';

  @override
  String refreshRingAnnouncementPartialFound(int ok, int total) {
    final intl.NumberFormat okNumberFormat = intl.NumberFormat.decimalPattern(
      localeName,
    );
    final String okString = okNumberFormat.format(ok);
    final intl.NumberFormat totalNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String totalString = totalNumberFormat.format(total);

    return '$okString از $totalString رله داده‌های شما را دارند';
  }

  @override
  String get refreshRingAnnouncementNoneFound =>
      'هیچ رله‌ای داده‌های شما را ندارد';

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
  String get profileIsPublicNoticeTitle => 'نمایه‌ات عمومی است';

  @override
  String get profileIsPublicNoticeBody =>
      'نام نمایشی و عکس تو برای هر کسی روی شبکهٔ Nostr دیده می‌شوند، نه فقط اعضای حلقه‌هایت. فقط چیزهایی را به اشتراک بگذار که با عمومی‌شدنشان راحت هستی.';

  @override
  String get identityRefreshProfileTooltip => 'تازه‌سازی نمایهٔ عمومی';

  @override
  String get identityAdvancedExportError =>
      'استخراج کلید خصوصی ناموفق بود. لطفاً دوباره تلاش کنید.';

  @override
  String get identityAdvancedDeleteTitle => 'هویت حذف شود؟';

  @override
  String get identityAdvancedDeleteBody =>
      'این کار هویت تو و همهٔ داده‌های حلقه‌ها را از این گوشی حذف می‌کند. هر چه پیش‌تر با آن منتشر شده، از جمله نام، عکس و کلیدهایت، روی رله‌هایی که آن را دارند می‌ماند. اگر می‌خواهی بتوانی بازیابی‌اش کنی، مطمئن شو که از کلید خصوصی‌ات پشتیبان گرفته‌ای.';

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
      'کلید عمومی تو مثل یک نام کاربری کار می‌کند که به اشتراک گذاشتنش امن است. مردم این کد را اسکن می‌کنند، یا کلید عمومی‌ات را جای‌گذاری می‌کنند، تا تو را به یک حلقه دعوت کنند. به اشتراک گذاشتنش نمی‌تواند لو بدهد کجایی. نام نمایشی و عکست از پیش عمومی‌اند، پس این چیزی به آن نمی‌افزاید.';

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
  String get circleMemberPublicKeyCopied => 'کلید عمومی در کلیپ‌بورد کپی شد';

  @override
  String get circleMemberCopyPublicKeyHint => 'کپی کلید عمومی';

  @override
  String get circleMemberSetNicknameMenuItem => 'تعیین نام مستعار';

  @override
  String get circleMemberCopyPublicKeyMenuItem => 'کپی کلید عمومی';

  @override
  String get memberProfileRefreshErrorGeneric =>
      'نتوانستیم نمایه‌ها را تازه‌سازی کنیم. لطفاً دوباره تلاش کنید.';

  @override
  String get memberDetailSheetTitle => 'جزئیات عضو';

  @override
  String get memberNicknameSheetHint => 'یک نام مستعار وارد کن';

  @override
  String get memberNicknameSheetLabel => 'نام مستعار';

  @override
  String get memberNicknameSheetSave => 'ذخیرهٔ نام مستعار';

  @override
  String get memberNicknameSheetClear => 'پاک کردن نام مستعار';

  @override
  String get memberNicknameSheetSavedAnnouncement => 'نام مستعار ذخیره شد';

  @override
  String get memberNicknameSheetClearedAnnouncement => 'نام مستعار پاک شد';

  @override
  String get npubQrScanLabel => 'برای افزودن من اسکن کن';

  @override
  String get npubQrSemanticsLabel => 'کد QR هویت عمومی تو';

  @override
  String get photoHeaderRemoveTitle => 'عکس نمایه حذف شود؟';

  @override
  String get photoHeaderRemoveBody =>
      'این کار عکس تو را از نمایهٔ عمومی‌ات برمی‌دارد. فایل تصویر روی سروری که میزبانش است می‌ماند، و نسخه‌هایی که دیگران پیش‌تر دانلود کرده‌اند نزد خودشان می‌ماند.';

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
      'عکس به‌روزرسانی شد. در نمایهٔ عمومی‌ات در Nostr منتشر شد.';

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
    final intl.NumberFormat metersNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String metersString = metersNumberFormat.format(meters);

    return '. دقت: $metersString متر';
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
      other: '$countString دقیقه پیش',
      one: '$countString دقیقه پیش',
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
  String memberMarkerOffScreenSemantics(String name, String direction) {
    return '$name در سمت $direction خارج از صفحه است؛ برای دیدن ضربه بزن';
  }

  @override
  String memberMarkerOffScreenGenericSemantics(String direction) {
    return 'یک عضو در سمت $direction خارج از صفحه است؛ برای دیدن ضربه بزن';
  }

  @override
  String get compassNorth => 'شمال';

  @override
  String get compassNorthEast => 'شمال شرقی';

  @override
  String get compassEast => 'شرق';

  @override
  String get compassSouthEast => 'جنوب شرقی';

  @override
  String get compassSouth => 'جنوب';

  @override
  String get compassSouthWest => 'جنوب غربی';

  @override
  String get compassWest => 'غرب';

  @override
  String get compassNorthWest => 'شمال غربی';

  @override
  String get commonAdd => 'افزودن';

  @override
  String get addRelaySheetTitleInbox => 'افزودن رلهٔ صندوق ورودی';

  @override
  String get addRelaySheetTitleKeyPackage => 'افزودن رلهٔ KeyPackage';

  @override
  String get addRelaySheetTitleProfile => 'افزودن رلهٔ نمایه';

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
