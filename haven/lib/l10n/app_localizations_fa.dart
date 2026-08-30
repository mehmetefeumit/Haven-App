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
  String get appearanceThemeSystemSubtitle => 'هماهنگ با تنظیمات دستگاهت';

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
  String get onboardingWelcomeCta => 'شروع کن';

  @override
  String get onboardingValuePropsTitle => 'چه چیزی Haven را متفاوت می‌کند';

  @override
  String get onboardingValueProp1Title =>
      'فقط حلقه‌هایت می‌توانند تو را ببینند';

  @override
  String get onboardingValueProp2Title => 'هیچ‌کس نمی‌تواند آن را خاموش کند';

  @override
  String get onboardingValueProp3Title => 'نیازی به حساب کاربری نیست';

  @override
  String get onboardingValueProp1Summary =>
      'روی دستگاهت رمزگذاری می‌شود؛ فقط حلقه‌هایی که انتخاب می‌کنی می‌توانند آن را ببینند.';

  @override
  String get onboardingValueProp2Summary =>
      'بدون سرور مرکزی. روی شبکه‌ای از رله‌ها که خودت انتخاب می‌کنی اجرا می‌شود.';

  @override
  String get onboardingValueProp3Summary =>
      'بدون ایمیل، تلفن یا ثبت‌نام. کلید خصوصی‌ات هرگز از گوشی‌ات بیرون نمی‌رود.';

  @override
  String get onboardingCreateIdentityTitle => 'هویتت را بساز';

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
      'هنگام ساختن هویت مشکلی پیش آمد. لطفاً دوباره تلاش کن.';

  @override
  String get onboardingImportTitle => 'کلید موجودت را وارد کن';

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
      'این به یک کلید پشتیبان معتبر شبیه نیست. لطفاً بررسی کن و دوباره تلاش کن.';

  @override
  String get onboardingImportError =>
      'نتوانستیم آن کلید را وارد کنیم. لطفاً بررسی کن و دوباره تلاش کن.';

  @override
  String get onboardingDisplayNameHint => 'مثلاً علی';

  @override
  String get onboardingDisplayNameError =>
      'نتوانستیم آن نام را ذخیره کنیم. لطفاً دوباره تلاش کن.';

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
  String get settingsRelaysTitle => 'رله‌ها';

  @override
  String get settingsLocationTitle => 'موقعیت مکانی';

  @override
  String get settingsMapStyleTitle => 'سبک نقشه';

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
      'برای مدیریت رله‌ها، ابتدا یک هویت بساز.';

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
  String get locationSettingsBatteryOptNote =>
      'بهینه‌سازی باتری برای Haven هنوز روشن است. برخی گوشی‌ها با همین قابلیت، اشتراک‌گذاری در پس‌زمینه را بدون هشدار متوقف می‌کنند. Haven را از آن مستثنا کن تا اشتراک‌گذاری قابل‌اعتماد بماند.';

  @override
  String get locationSettingsErrorSnack => 'مشکلی پیش آمد';

  @override
  String get locationSettingsIntro =>
      'Haven هر وقت برنامه باز باشد موقعیت مکانی‌ات را با حلقه‌هایت به اشتراک می‌گذارد. این را روشن کن تا حلقه‌هایت وقتی Haven در پس‌زمینه است هم آن را ببینند. اگر سیستم Haven را ببندد، اشتراک‌گذاری متوقف می‌شود؛ برنامه در پس‌زمینه فقط برای گرفتن موقعیت حلقه‌هایت بیدار می‌شود، نه برای فرستادن موقعیت خودت. روی Android، اشتراک‌گذاری حتی بعد از کنار زدن Haven از فهرست برنامه‌های باز ادامه پیدا می‌کند و پس از راه‌اندازی دوبارهٔ دستگاه خودبه‌خود از سر گرفته می‌شود؛ روی iPhone تا وقتی Haven را باز نکنی متوقف می‌ماند.';

  @override
  String get locationSettingsToggleTitle => 'اشتراک‌گذاری در پس‌زمینه';

  @override
  String get locationSettingsToggleSubtitle =>
      'تا وقتی Haven در پس‌زمینه است، به اشتراک‌گذاری ادامه بده';

  @override
  String get locationSettingsIosLimitedNote =>
      'اشتراک‌گذاری با همین مجوز فعلی همچنان در پس‌زمینه کار می‌کند. در تنظیمات، موقعیت مکانی Haven را روی «همیشه» بگذار تا Haven بتواند پس از آنکه iOS برنامه را بست هم خودش را با موقعیت حلقه‌هایت به‌روز کند. وقتی دوباره Haven را باز کنی، اشتراک‌گذاری موقعیت خودت از سر گرفته می‌شود.';

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
  String get fgsNotificationSharing =>
      'Haven در حال ارسال و دریافت موقعیت مکانی است';

  @override
  String get fgsNotificationPaused =>
      'Haven موقتاً متوقف است — برنامه را باز کن تا اشتراک‌گذاری از سر گرفته شود';

  @override
  String get fgsNotificationOpen => 'Haven باز است';

  @override
  String get fgsChannelName => 'اشتراک‌گذاری موقعیت مکانی';

  @override
  String get fgsChannelDescription =>
      'این اعلان، Haven را فعال نگه می‌دارد تا موقعیت مکانی رمزگذاری‌شده‌ات را در پس‌زمینه به اشتراک بگذارد.';

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
  String get aboutFooterLicense => 'تحت مجوز MIT License';

  @override
  String aboutFooterVersion(String version) {
    return 'نسخهٔ $version';
  }

  @override
  String get relaySettingsBackendCaption =>
      'Haven سرور خودش را ندارد. به‌روزرسانی‌های رمزگذاری‌شده‌ات از میان سرورهای مستقلی می‌گذرند که رله نامیده می‌شوند و نمی‌توانند موقعیت مکانی یا پیام‌هایت را بخوانند.';

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
  String get nameCircleNameEmptyError => 'لطفاً یک نام برای حلقه وارد کن';

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
  String nameCircleCreatedPartialSnack(String name, int sent, int total) {
    final intl.NumberFormat sentNumberFormat = intl.NumberFormat.decimalPattern(
      localeName,
    );
    final String sentString = sentNumberFormat.format(sent);
    final intl.NumberFormat totalNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String totalString = totalNumberFormat.format(total);

    return 'حلقهٔ «$name» ساخته شد. دعوت‌ها فرستاده شدند ($sentString از $totalString)؛ تحویل بقیه در انتظار است.';
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
      'خطای هویت. لطفاً تنظیمات هویتت را بررسی کن.';

  @override
  String get nameCircleCreateError =>
      'ساختن حلقه ناموفق بود. لطفاً دوباره تلاش کن.';

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
  String get addMemberError => 'افزودن عضو ناموفق بود. لطفاً دوباره تلاش کن.';

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
  String get circleMemberNoRecentLocation => 'موقعیت اخیری وجود ندارد';

  @override
  String get circleMemberRemoveTooltip => 'حذف از حلقه';

  @override
  String circleMemberRemoveDialogTitle(String name) {
    return '$name حذف شود؟';
  }

  @override
  String get circleMemberRemoveDialogBody =>
      'به‌محض اینکه بقیهٔ اعضای حلقه خود را با این تغییر هماهنگ کنند، او دیگر نمی‌تواند چیز تازه‌ای از این حلقه بخواند؛ این کار معمولاً چند دقیقه طول می‌کشد و برای کسی که آن موقع آفلاین بوده بیشتر. آنچه پیش‌تر گرفته روی گوشی‌اش می‌ماند. تنها راه برگرداندنش این است که دوباره دعوتش کنی.';

  @override
  String get circleMemberRemoveConfirm => 'حذف';

  @override
  String circleMemberRemoveInProgress(String name) {
    return 'در حال حذف $name…';
  }

  @override
  String circleMemberRemoveSuccess(String name) {
    return '$name از حلقه حذف شد';
  }

  @override
  String circleMemberRemoveError(String name) {
    return 'نتوانستیم $name را حذف کنیم. چیزی تغییر نکرد؛ اتصالت را بررسی کن و دوباره تلاش کن.';
  }

  @override
  String get circleMemberAdmin => 'مدیر';

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
  String get memberPickerSectionRoster => 'اعضای حلقه‌هایت';

  @override
  String get memberPickerTierRoster => 'عضوِ حلقه‌هایت';

  @override
  String get memberPickerNoMatches => 'در حلقه‌هایت نتیجه‌ای یافت نشد';

  @override
  String get memberPickerLoading => 'در حال خواندن فهرست افرادِ حلقه‌هایت';

  @override
  String get memberPickerDirectoryUnavailable =>
      'فعلاً نتوانستیم فهرست افرادِ حلقه‌هایت را بارگذاری کنیم';

  @override
  String memberPickerMatchesAnnouncement(int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    return 'نتایج: $countString';
  }

  @override
  String get memberPickerReasonSelf => 'این شناسهٔ خودت است';

  @override
  String get memberPickerReadPublicKey => 'خواندن کلید عمومی با صدای بلند';

  @override
  String get memberPickerSectionRecent => 'به‌تازگی در حلقه‌هایت';

  @override
  String get memberPickerTierRecent => 'به‌تازگی در حلقه‌هایت';

  @override
  String get memberPickerNicknameNote =>
      'نام مستعاری که خودت برایش گذاشته‌ای، نه نام عمومی‌اش';

  @override
  String memberPickerCollisionCircleLabel(String circleName) {
    return 'حلقه: $circleName';
  }

  @override
  String get memberPickerStrangerLookupNote =>
      'Haven از یک رله خواست که نام عمومی این شخص را جست‌وجو کند. آن رله می‌بیند که این دستگاه همین حالا دربارهٔ این کلید پرسیده است. اما این درخواست هیچ امضایی ندارد، پس به هویتت در Haven گره نمی‌خورد. هنوز هیچ عکسی دانلود نشده است.';

  @override
  String selectedMembersMore(int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    return '‏+$countString مورد دیگر';
  }

  @override
  String get invitationCardHeading => 'دعوت به حلقه';

  @override
  String invitationCardSemantics(String inviter) {
    return 'دعوتی برای پیوستن به یک حلقه، از سوی $inviter';
  }

  @override
  String invitationCardInvitedBySemantics(String inviter) {
    return 'دعوت‌کننده: شناسهٔ رمزنگاری $inviter';
  }

  @override
  String invitationCardInvitedBy(String inviter) {
    return 'دعوت‌کننده: $inviter';
  }

  @override
  String get invitationCardNicknameNote =>
      'نام مستعاری که خودت برایش گذاشته‌ای، نه نام عمومی‌اش';

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
      'پذیرفتن دعوت ناموفق بود. لطفاً دوباره تلاش کن.';

  @override
  String get invitationDeclineError =>
      'رد کردن دعوت ناموفق بود. لطفاً دوباره تلاش کن.';

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
      other: '$countString دقیقه',
      one: '$countString دقیقه',
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
      other: '$countString ثانیه',
      one: '$countString ثانیه',
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
      other: 'حدود $countString دقیقه',
      one: 'حدود $countString دقیقه',
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
      other: '$countString ثانیه',
      one: '$countString ثانیه',
    );
    return '$_temp0';
  }

  @override
  String circleDetailsExpirySemantics(String meta, String expiry) {
    return '$meta. Haven از رله‌ها می‌خواهد به‌روزرسانی‌های موقعیت مکانی‌ای را که به این حلقه می‌فرستی، پس از $expiry دور بیندازند.';
  }

  @override
  String get circleDetailsRelaysHeading => 'رله‌های این حلقه';

  @override
  String get circleDetailsNoRelays => '(چیزی ثبت نشده)';

  @override
  String get circleDetailsRelaysNote =>
      'این رله‌ها از فهرست‌های منتشرشدهٔ اعضای دعوت‌شده آمده‌اند، و اگر آن اعضا فهرستی نداشتند، از رله‌های صندوق ورودی خودت یا رله‌های انتخابی Haven. هنوز نمی‌شود عوضشان کرد، و ویرایش‌های بعدیِ فهرست رله‌ات روی آن‌ها اثری ندارد.';

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
      'Haven هنوز از رله‌ها می‌خواهد برخی داده‌های قدیمی به‌جامانده از به‌روزرسانی امنیتی اخیر را دور بیندازند.';

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
      other: 'همهٔ $totalString رله پاسخ دادند',
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
  String get refreshRingAnnouncementAllOk => 'همهٔ رله‌ها پاسخ دادند';

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
      other: 'همهٔ $totalString رله داده‌هایت را دارند',
      one: 'رله داده‌هایت را دارد',
    );
    return '$_temp0';
  }

  @override
  String get refreshRingSemanticNoneFound => 'هیچ رله‌ای داده‌هایت را ندارد';

  @override
  String refreshRingSemanticPartialFound(int ok, int total) {
    final intl.NumberFormat okNumberFormat = intl.NumberFormat.decimalPattern(
      localeName,
    );
    final String okString = okNumberFormat.format(ok);
    final intl.NumberFormat totalNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String totalString = totalNumberFormat.format(total);

    return '$okString از $totalString رله داده‌هایت را دارند';
  }

  @override
  String get refreshRingAnnouncementAllFound =>
      'همهٔ رله‌ها داده‌هایت را دارند';

  @override
  String refreshRingAnnouncementPartialFound(int ok, int total) {
    final intl.NumberFormat okNumberFormat = intl.NumberFormat.decimalPattern(
      localeName,
    );
    final String okString = okNumberFormat.format(ok);
    final intl.NumberFormat totalNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String totalString = totalNumberFormat.format(total);

    return '$okString از $totalString رله داده‌هایت را دارند';
  }

  @override
  String get refreshRingAnnouncementNoneFound =>
      'هیچ رله‌ای داده‌هایت را ندارد';

  @override
  String get identityTitle => 'هویت';

  @override
  String get identityLoadError =>
      'هنگام بارگذاری هویت تو مشکلی پیش آمد. لطفاً دوباره تلاش کن.';

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
      'استخراج کلید خصوصی ناموفق بود. لطفاً دوباره تلاش کن.';

  @override
  String get identityAdvancedDeleteTitle => 'هویت حذف شود؟';

  @override
  String get identityAdvancedDeleteBody =>
      'این کار هویت تو و همهٔ داده‌های حلقه‌ها را از این گوشی حذف می‌کند. هر چه پیش‌تر با آن منتشر شده، همان‌جا که هست می‌ماند: نام و کلیدهایت روی رله‌هایی که آن‌ها را دارند، و عکست روی میزبان تصویری که نگهش می‌دارد. اگر می‌خواهی بتوانی هویتت را بازیابی کنی، مطمئن شو که از کلید خصوصی‌ات پشتیبان گرفته‌ای.';

  @override
  String get identityAdvancedDeleteConfirm => 'حذف';

  @override
  String get identityAdvancedDeletedSnack => 'هویت حذف شد';

  @override
  String get identityAdvancedDeleteError =>
      'حذف هویت ناموفق بود. لطفاً دوباره تلاش کن.';

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
      'هنگام بارگذاری کلید عمومی تو مشکلی پیش آمد. لطفاً دوباره تلاش کن.';

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
  String get profileSyncStatusSyncing =>
      'در حال همگام‌سازی با نمایهٔ عمومی‌ات…';

  @override
  String get profileSyncStatusPartial =>
      'منتشر شد — هنوز با برخی رله‌ها همگام‌سازی می‌شود';

  @override
  String get profileSyncStatusSynced => 'نمایهٔ عمومی‌ات به‌روز است';

  @override
  String get profileSyncStatusFailed => 'هنوز نتوانستیم همگام‌سازی کنیم.';

  @override
  String get profileSyncStatusRetrySemantics =>
      'تلاش دوباره برای انتشار نمایه‌ات';

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
      'نتوانستیم نمایه‌ها را تازه‌سازی کنیم. لطفاً دوباره تلاش کن.';

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
      'عکس به‌روزرسانی شد. در نمایهٔ عمومی‌ات روی Nostr منتشر خواهد شد.';

  @override
  String get avatarPickerPhotoRemoved => 'عکس حذف شد.';

  @override
  String get avatarPickerRemoveError =>
      'نتوانستیم عکس تو را حذف کنیم. لطفاً دوباره تلاش کن.';

  @override
  String get avatarPickerUpdateError =>
      'نتوانستیم عکس تو را به‌روزرسانی کنیم. لطفاً دوباره تلاش کن.';

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
      'راه‌اندازی ناموفق بود. لطفاً دوباره تلاش کن.';

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
  String get mapLocationNoPermissionTitle =>
      'Haven به موقعیت مکانی‌ات دسترسی ندارد';

  @override
  String get mapLocationSharingStoppedServiceOff =>
      'موقعیت مکانی روی این دستگاه خاموش است، پس Haven اشتراک‌گذاری آن با حلقه‌هایت را متوقف کرده است. برای شروع دوباره، موقعیت مکانی را روشن کن.';

  @override
  String get mapLocationSharingStoppedPermission =>
      'Haven دیگر مجوز استفاده از موقعیت مکانی‌ات را ندارد، پس اشتراک‌گذاری متوقف شده است. برای شروع دوباره، دسترسی به موقعیت مکانی را مجاز کن.';

  @override
  String get mapLocationSharingStoppedPermissionSettings =>
      'در تنظیمات سیستم، دسترسی Haven به موقعیت مکانی مجاز نیست، پس اشتراک‌گذاری متوقف شده است. برای شروع دوباره، همان‌جا آن را مجاز کن.';

  @override
  String get mapLocationSharingStoppedBoth =>
      'Haven اشتراک‌گذاری موقعیت مکانی‌ات را متوقف کرده است. موقعیت مکانی را روی این دستگاه روشن کن و دسترسی Haven به آن را مجاز کن.';

  @override
  String get mapLocationSharingStoppedUnknown =>
      'Haven دیگر موقعیت مکانی‌ات را دریافت نمی‌کند، پس اشتراک‌گذاری متوقف شده است. بررسی کن که موقعیت مکانی روشن باشد و Haven اجازهٔ استفاده از آن را داشته باشد.';

  @override
  String get mapLocationAccessRestoredAnnouncement =>
      'دسترسی به موقعیت مکانی برقرار شد. Haven دوباره موقعیت مکانی‌ات را به اشتراک می‌گذارد.';

  @override
  String get clockSkewTitle => 'ساعت این گوشی درست نیست';

  @override
  String get clockSkewBodyRejected =>
      'حلقه‌هایت موقعیت مکانی‌ات را دریافت نمی‌کنند، چون رله‌ها زمانی را که این گوشی ثبت می‌کند نمی‌پذیرند. برای رفع این مشکل، در تنظیمات سیستم تنظیم خودکار تاریخ و ساعت را روشن کن.';

  @override
  String get clockSkewBodyBehind =>
      'ساعت این گوشی از بقیهٔ حلقه‌هایت عقب است، پس موقعیت مکانی‌ات فرستاده می‌شود، اما پیش از آنکه کسی بتواند آن را ببیند منقضی می‌شود. برای رفع این مشکل، در تنظیمات سیستم تنظیم خودکار تاریخ و ساعت را روشن کن.';

  @override
  String get clockSkewResolvedAnnouncement =>
      'مشکل ساعت برطرف شد. Haven دوباره موقعیت مکانی‌ات را به اشتراک می‌گذارد.';

  @override
  String get clockSkewTitleDisagreement =>
      'ساعتی در یکی از حلقه‌هایت درست نیست';

  @override
  String get clockSkewBodyDisagreement =>
      'ساعت این گوشی و ساعت یکی دیگر از اعضا دو دقیقه یا بیشتر با هم اختلاف دارند. اگر ساعت این گوشی درست نباشد، ممکن است موقعیت مکانی‌ات پیش از آنکه کسی آن را ببیند منقضی شود. برای اینکه مطمئن شوی مشکل از این گوشی نیست، در تنظیمات سیستم تنظیم خودکار تاریخ و ساعت را روشن کن.';

  @override
  String get clockSkewDisagreementResolvedAnnouncement =>
      'هشدار ساعت برطرف شد.';

  @override
  String get sharingHealthTitleStopped =>
      'اشتراک‌گذاری موقعیت مکانی متوقف شده است';

  @override
  String get sharingHealthTitleNotSending =>
      'موقعیت مکانی‌ات به اشتراک گذاشته نمی‌شود';

  @override
  String get sharingHealthTitleNotReceiving =>
      'موقعیت مکانی دیگران را دریافت نمی‌کنی';

  @override
  String sharingHealthNoUpdatesMinutes(int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'حدود $countString دقیقه بدون به‌روزرسانی',
      one: 'حدود $countString دقیقه بدون به‌روزرسانی',
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
      other: 'حدود $countString ساعت بدون به‌روزرسانی',
      one: 'حدود $countString ساعت بدون به‌روزرسانی',
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
      other: 'حدود $countString روز بدون به‌روزرسانی',
      one: 'حدود $countString روز بدون به‌روزرسانی',
    );
    return '$_temp0';
  }

  @override
  String get sharingHealthRepairAction => 'رفع مشکل';

  @override
  String get sharingHealthRepairUnavailableHint =>
      'رفع مشکل برای این حلقه در دسترس نیست';

  @override
  String get sharingHealthRepairHint =>
      'دوباره به رله‌ها وصل می‌شود و موقعیت مکانی‌ات را دوباره می‌فرستد، و اگر مدیر این حلقه باشی، ممکن است کلید تازه‌ای به آن بدهد';

  @override
  String get sharingHealthRepairSent =>
      'پیامِ رفع مشکل فرستاده شد. دیگران وقتی گوشی‌هایشان آن را دریافت کنند، هماهنگ می‌شوند.';

  @override
  String get sharingHealthRepairNotOwner =>
      'فقط مدیر این حلقه می‌تواند مشکلش را رفع کند. از او بخواه تو را حذف کند و دوباره اضافه کند.';

  @override
  String get sharingHealthRepairNeedsNewCircle =>
      'مشکل این حلقه روی این گوشی رفع نمی‌شود. یک حلقهٔ تازه با همان افراد بساز.';

  @override
  String get sharingHealthRepairNothingToDo =>
      'فعلاً چیزی برای رفع کردن نیست. Haven به تلاش ادامه می‌دهد.';

  @override
  String get sharingHealthRepairUnresolvedAnnouncement =>
      'اشتراک‌گذاری موقعیت مکانی هنوز کار نمی‌کند.';

  @override
  String get sharingHealthResumedAnnouncement =>
      'اشتراک‌گذاری موقعیت مکانی دوباره کار می‌کند.';

  @override
  String circleMemberLastSeenMinutes(int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'آخرین بار $countString دقیقه پیش دیده شد',
      one: 'آخرین بار $countString دقیقه پیش دیده شد',
    );
    return '$_temp0';
  }

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
