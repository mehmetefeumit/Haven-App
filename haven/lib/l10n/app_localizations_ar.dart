// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Arabic (`ar`).
class AppLocalizationsAr extends AppLocalizations {
  AppLocalizationsAr([String locale = 'ar']) : super(locale);

  @override
  String get appearanceTitle => 'المظهر';

  @override
  String get appearanceThemeHeader => 'السمة';

  @override
  String get appearanceThemeSystem => 'الافتراضي للنظام';

  @override
  String get appearanceThemeSystemSubtitle => 'مطابقة إعدادات جهازك';

  @override
  String get appearanceThemeLight => 'فاتح';

  @override
  String get appearanceThemeLightSubtitle => 'استخدام السمة الفاتحة دائمًا';

  @override
  String get appearanceThemeDark => 'داكن';

  @override
  String get appearanceThemeDarkSubtitle => 'استخدام السمة الداكنة دائمًا';

  @override
  String get appearanceLanguageTitle => 'اللغة';

  @override
  String get languageSystemDefault => 'الافتراضي للنظام';

  @override
  String get commonTryAgain => 'إعادة المحاولة';

  @override
  String get commonDismiss => 'تجاهل';

  @override
  String get commonSettings => 'الإعدادات';

  @override
  String get commonInvitations => 'الدعوات';

  @override
  String commonPendingInvitations(int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$countString دعوة معلّقة',
      many: '$countString دعوة معلّقة',
      few: '$countString دعوات معلّقة',
      two: 'دعوتان معلّقتان',
      one: 'دعوة معلّقة واحدة',
      zero: 'لا دعوات معلّقة',
    );
    return '$_temp0';
  }

  @override
  String get commonBack => 'رجوع';

  @override
  String get commonContinue => 'متابعة';

  @override
  String get commonSkip => 'تخطٍّ';

  @override
  String get commonRetry => 'إعادة المحاولة';

  @override
  String onboardingStepOf(int current, int total) {
    final intl.NumberFormat currentNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String currentString = currentNumberFormat.format(current);
    final intl.NumberFormat totalNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String totalString = totalNumberFormat.format(total);

    return 'الخطوة $currentString من $totalString';
  }

  @override
  String get onboardingAppName => 'Haven';

  @override
  String get onboardingWelcomeHeadline =>
      'شارِك موقعك بخصوصية، فقط مع من تريد.';

  @override
  String get onboardingWelcomeHeadlineEmphasis => 'فقط';

  @override
  String get onboardingWelcomeCta => 'ابدأ الآن';

  @override
  String get onboardingValuePropsTitle => 'ما الذي يميّز Haven';

  @override
  String get onboardingValueProp1Title => 'دوائرك وحدها تستطيع رؤيتك';

  @override
  String get onboardingValueProp1Body =>
      'يُشفَّر موقعك على جهازك قبل أن يغادره، بحيث لا يقدر على قراءته سوى الدوائر التي تختارها، ولا تقدر على ذلك Haven ولا أي جهة أخرى. ولأن Haven مفتوح المصدر، يمكن لأي شخص التحقق من ذلك.';

  @override
  String get onboardingValueProp2Title => 'لا يستطيع أحد إيقافه';

  @override
  String get onboardingValueProp2Body =>
      'لا يملك Haven خادمًا مركزيًا. تنتقل رسائلك المشفّرة عبر خوادم مستقلة تُسمّى مُرحِّلات، وأنت تختار أيها تستخدم. ولا تستطيع أي شركة أو حكومة بمفردها إيقاف الشبكة.';

  @override
  String get onboardingValueProp3Title => 'لا حاجة إلى حساب';

  @override
  String get onboardingValueProp3Body =>
      'لا بريد إلكتروني، ولا رقم هاتف، ولا تسجيل. يُنشئ Haven هوية مفتاحها السري لا يغادر هاتفك أبدًا، فلا يوجد حساب يستطيع أحد تسليمه.';

  @override
  String get onboardingValueProp1Summary =>
      'مُشفَّر على جهازك، فلا يستطيع قراءته سوى الدوائر التي تختارها.';

  @override
  String get onboardingValueProp2Summary =>
      'بلا خادم مركزي. يعمل على شبكة مُرحِّلات تختارها بنفسك.';

  @override
  String get onboardingValueProp3Summary =>
      'بلا بريد أو هاتف أو تسجيل. مفتاحك السري لا يغادر هاتفك أبدًا.';

  @override
  String get onboardingCreateIdentityTitle => 'أنشئ هويتك';

  @override
  String get onboardingCreateIdentityBody =>
      'يُنشئ Haven مفاتيحك على هذا الهاتف. ولا يغادره المفتاح السري أبدًا.';

  @override
  String get onboardingCreateIdentityWarning =>
      'إن فقدت هذا الهاتف أو حذفت التطبيق، فستضيع هويتك. وليس لدى Haven أي وسيلة لاستعادتها لك.';

  @override
  String get onboardingCreateIdentityCta => 'أنشئ هويتي';

  @override
  String get onboardingCreateIdentityLoading => 'جارٍ التجهيز…';

  @override
  String get onboardingCreateIdentityImportPrompt => 'لديك مفتاح بالفعل؟';

  @override
  String get onboardingCreateIdentityImportLink => 'استورده بدلًا من ذلك';

  @override
  String get onboardingCreateIdentityError =>
      'حدث خطأ ما أثناء إنشاء هويتك. يُرجى إعادة المحاولة.';

  @override
  String get onboardingImportTitle => 'استورد مفتاحك الحالي';

  @override
  String get onboardingImportBody =>
      'الصق المفتاح السري الذي نسخته احتياطيًا من تطبيق آخر متوافق مع Haven.';

  @override
  String get onboardingImportHint => 'nsec1…';

  @override
  String get onboardingImportCta => 'استيراد';

  @override
  String get onboardingImportLoading => 'جارٍ الاستيراد…';

  @override
  String get onboardingImportInvalid =>
      'لا يبدو هذا مفتاح نسخ احتياطي صالحًا. يُرجى التحقق وإعادة المحاولة.';

  @override
  String get onboardingImportError =>
      'تعذّر استيراد هذا المفتاح. يُرجى التحقق وإعادة المحاولة.';

  @override
  String get onboardingDisplayNameHint => 'مثال: أليكس';

  @override
  String get onboardingDisplayNameError =>
      'تعذّر حفظ هذا الاسم. يُرجى إعادة المحاولة.';

  @override
  String get onboardingAddPhotoOptional => 'إضافة صورة (اختياري)';

  @override
  String get commonCancel => 'إلغاء';

  @override
  String get commonOpenSettings => 'فتح الإعدادات';

  @override
  String get settingsTitle => 'الإعدادات';

  @override
  String get settingsIdentityTitle => 'الهوية';

  @override
  String get settingsIdentitySubtitle => 'الملف الشخصي والمفاتيح ومشاركة الصور';

  @override
  String get settingsRelaysTitle => 'المُرحِّلات';

  @override
  String get settingsRelaysSubtitle => 'حيث تصلك الدعوات';

  @override
  String get settingsLocationTitle => 'الموقع';

  @override
  String get settingsLocationSubtitle => 'المشاركة في الخلفية والأذونات';

  @override
  String get settingsMapStyleTitle => 'نمط الخريطة';

  @override
  String get settingsAppearanceSubtitle => 'السمة واللغة';

  @override
  String get settingsAboutTitle => 'حول';

  @override
  String get settingsDebugOverlayTitle => 'تراكب سجلّ التصحيح';

  @override
  String get settingsDebugOverlaySubtitle => 'إظهار مخرجات السجلّ على الشاشة';

  @override
  String get relaySettingsTitle => 'المُرحِّلات';

  @override
  String get relaySettingsCheckRelaysTooltip => 'فحص المُرحِّلات';

  @override
  String get relaySettingsNoIdentityTitle => 'لا توجد هوية';

  @override
  String get relaySettingsNoIdentityMessage =>
      'أنشئ هوية أولًا لإدارة المُرحِّلات.';

  @override
  String get relaySettingsLoadIdentityError => 'تعذّر تحميل الهوية.';

  @override
  String get relaySettingsInboxTitle => 'مُرحِّلات صندوق الوارد';

  @override
  String get relaySettingsInboxSubtitle => 'حيث تصلك الدعوات (kind 10050)';

  @override
  String get relaySettingsKeyPackageTitle => 'مُرحِّلات KeyPackage الخاصة بي';

  @override
  String get relaySettingsKeyPackageSubtitle =>
      'حيث يجد الآخرون المفاتيح التي يحتاجونها لدعوتك (kind 10002)';

  @override
  String get relaySettingsProfileTitle => 'مُرحِّلات ملفي الشخصي';

  @override
  String get relaySettingsProfileSubtitle =>
      'حيث يُبحَث عن ملفك الشخصي العام ويُنشَر. تبقى هذه المُرحِّلات منفصلة عن بقية مُرحِّلاتك، ولا تُنشَر قائمة هذه المُرحِّلات أبدًا (kind 0)';

  @override
  String get relaySettingsProfileUnderflowTitle =>
      'البحث عن الملفات الشخصية متوقّف مؤقتًا';

  @override
  String get relaySettingsProfileUnderflowMessage =>
      'لم يتبقَّ عدد كافٍ من مُرحِّلات الملف الشخصي، لذا ستتوقّف أسماء الأعضاء وصورهم عن التحديث.';

  @override
  String get relaySettingsProfileUnderflowRestoreButton =>
      'استعادة مُرحِّلات الملف الشخصي الافتراضية';

  @override
  String get relaySettingsLoadRelaysError => 'تعذّر تحميل المُرحِّلات.';

  @override
  String get relaySettingsAddRelay => 'إضافة مُرحِّل';

  @override
  String get relaySettingsRestoreDefaults => 'استعادة الإعدادات الافتراضية';

  @override
  String get relaySettingsAddRelayError => 'تعذّرت إضافة المُرحِّل.';

  @override
  String get relaySettingsRemoveRelayError => 'تعذّرت إزالة المُرحِّل.';

  @override
  String get relaySettingsRestoreTitle => 'استعادة المُرحِّلات الافتراضية؟';

  @override
  String relaySettingsRestoreBody(int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other:
          'ستُستبدَل المُرحِّلات الحالية ($countString) بإعدادات Haven الافتراضية. لا يمكن التراجع عن ذلك.',
      many:
          'سيُستبدَل المُرحِّل الحالي ($countString) بإعدادات Haven الافتراضية. لا يمكن التراجع عن ذلك.',
      few:
          'ستُستبدَل المُرحِّلات الحالية ($countString) بإعدادات Haven الافتراضية. لا يمكن التراجع عن ذلك.',
      two:
          'سيُستبدَل المُرحِّلان الحاليان بإعدادات Haven الافتراضية. لا يمكن التراجع عن ذلك.',
      one:
          'سيُستبدَل المُرحِّل الحالي بإعدادات Haven الافتراضية. لا يمكن التراجع عن ذلك.',
      zero:
          'سيُستبدَل المُرحِّل الحالي بإعدادات Haven الافتراضية. لا يمكن التراجع عن ذلك.',
    );
    return '$_temp0';
  }

  @override
  String get relaySettingsRestoreConfirm => 'استعادة';

  @override
  String get relaySettingsRestoreSuccess => 'تمت استعادة الإعدادات الافتراضية.';

  @override
  String get relaySettingsRestoreError =>
      'تعذّرت استعادة الإعدادات الافتراضية.';

  @override
  String relaySettingsRemoveTooltip(String url) {
    return 'إزالة $url';
  }

  @override
  String get relaySettingsStatusConnected => 'متصل';

  @override
  String get relaySettingsStatusChecking => 'جارٍ الفحص';

  @override
  String get relaySettingsStatusUnreachable => 'تعذّر الوصول';

  @override
  String get relaySettingsStatusNotChecked => 'لم يُفحَص';

  @override
  String relaySettingsStatusSemantics(String status) {
    return 'حالة المُرحِّل: $status';
  }

  @override
  String get relaySettingsEmptyTitle => 'لا توجد مُرحِّلات مُهيّأة';

  @override
  String get relaySettingsEmptyMessage =>
      'تحتاج إلى مُرحِّل واحد على الأقل ليتمكّن الآخرون من الوصول إليك. اضغط أدناه لاستعادة إعدادات Haven الافتراضية.';

  @override
  String get relaySettingsProfileContaminationTooltip =>
      'يحمل أيضًا حركة بيانات Haven الأخرى';

  @override
  String relaySettingsProfileContaminationSemantics(String url) {
    return 'تحذير: $url يحمل أيضًا حركة بيانات Haven الأخرى الخاصة بك، لذا قد يتمكّن هذا المُرحِّل من ربط ملفك الشخصي بتلك الحركة';
  }

  @override
  String get locationSettingsTitle => 'الموقع';

  @override
  String get locationSettingsDisabledSnack => 'تم تعطيل المشاركة في الخلفية';

  @override
  String get locationSettingsEnabledSnack => 'تم تفعيل المشاركة في الخلفية';

  @override
  String get locationSettingsNotificationDeniedSnack =>
      'تحتاج المشاركة في الخلفية إلى إشعار حتى يُبقيها Android قيد التشغيل. هي معطّلة الآن. فعّل الإشعارات لتطبيق Haven لتشغيلها.';

  @override
  String get locationSettingsBatteryOptSnack =>
      'مُفعّلة. قد يوقف تحسين البطارية المشاركة مؤقتًا على بعض الهواتف. استثنِ Haven من تحسين البطارية للحفاظ على موثوقيتها.';

  @override
  String get locationSettingsErrorSnack => 'حدث خطأ ما';

  @override
  String get locationSettingsIntro =>
      'يشارك Haven موقعك مع دوائرك كلما كان التطبيق مفتوحًا. وإن فعّلت هذا الخيار، ظلّت دوائرك ترى موقعك بينما يعمل Haven في الخلفية؛ وإن أغلق النظام Haven، استؤنفت التحديثات عند تحرّكك أو عندما يوقظ النظام التطبيق في المرة التالية.';

  @override
  String get locationSettingsToggleTitle => 'المشاركة في الخلفية';

  @override
  String get locationSettingsToggleSubtitle =>
      'استمرار المشاركة عند إغلاق التطبيق';

  @override
  String get locationSettingsIosLimitedNote =>
      'تظل المشاركة تعمل في الخلفية بإذنك الحالي. اختر «دائمًا» لتطبيق Haven في الإعدادات حتى تُستأنف التحديثات أيضًا بعد أن يُغلق iOS التطبيق.';

  @override
  String get locationSettingsAndroidHeader => 'إعدادات النظام للموثوقية';

  @override
  String get locationSettingsAndroidNotification =>
      'يحتاج Haven إلى إشعار دائم حتى يُبقي Android خدمة الخلفية نشطة. إن رفضت إذن الإشعارات، فافتح الإعدادات واسمح بالإشعارات لتطبيق Haven.';

  @override
  String get locationSettingsAndroidBattery =>
      'للمشاركة الموثوقة في الخلفية، استثنِ Haven أيضًا من تحسين البطارية. انتقل إلى الإعدادات ← التطبيقات ← Haven ← البطارية ← السماح طوال الوقت.';

  @override
  String get locationSettingsAndroidVendors =>
      'على أجهزة Samsung، أزِل Haven من \"التطبيقات النائمة\" (Device care ← Battery ← Background usage limits). على Xiaomi، فعّل Autostart لتطبيق Haven.';

  @override
  String get locationSettingsIosGuidance =>
      'ما دامت المشاركة في الخلفية مفعّلة، يحتفظ Haven بجلسة موقع متواصلة ويُظهر iOS مؤشرًا أزرق في شريط الحالة. ومنح إذن «دائمًا» يتيح لتطبيق Haven إضافةً إلى ذلك تدارك ما فاته من تحديثات دوائرك بعد أن يُغلق iOS التطبيق.';

  @override
  String get mapStyleTitle => 'نمط الخريطة';

  @override
  String get mapStyleMinimalTitle => 'بسيط';

  @override
  String get mapStyleMinimalSubtitle =>
      'لوحة هادئة قليلة التفاصيل تتبع سمتك الفاتحة أو الداكنة';

  @override
  String get mapStyleDetailedTitle => 'مفصّل';

  @override
  String get mapStyleDetailedSubtitle => 'شوارع وعلامات وأماكن بألوان كاملة';

  @override
  String get mapStyleOutdoorsTitle => 'في الهواء الطلق';

  @override
  String get mapStyleOutdoorsSubtitle => 'تضاريس مظلّلة مع مسارات وحدائق';

  @override
  String get mapStylePreviewHeader => 'معاينة';

  @override
  String get mapStylePreviewCity => 'مدينة';

  @override
  String get mapStylePreviewNature => 'طبيعة';

  @override
  String mapStylePreviewSemantics(String scene, String style) {
    return 'معاينة الخريطة ($scene): $style';
  }

  @override
  String get mapStylePreviewUnavailableSemantics =>
      'معاينة الخريطة غير متاحة في هذا الإصدار';

  @override
  String get mapStylePreviewUnavailableLabel =>
      'تظهر المعاينة المباشرة في إصدارات النشر';

  @override
  String get aboutTitle => 'حول';

  @override
  String get aboutHeroName => 'Haven';

  @override
  String get aboutHeroTagline => 'مشاركة موقع خاصة ومقاوِمة للرقابة.';

  @override
  String get aboutLicensesTitle => 'تراخيص المصدر المفتوح';

  @override
  String get aboutLicensesLegalese => '© 2026 Haven · MIT License';

  @override
  String get aboutReportMapIssue => 'الإبلاغ عن مشكلة في الخريطة';

  @override
  String get aboutSupportOsm => 'دعم OpenStreetMap';

  @override
  String get aboutMapAttribution =>
      '© Stadia Maps · © OpenMapTiles · © OpenStreetMap contributors\nMap data licensed under ODbL';

  @override
  String get aboutLinkOpenError => 'تعذّر فتح الرابط';

  @override
  String get aboutVpnLinkLabel => 'mullvad.net';

  @override
  String get aboutFooterLicense => 'مُرخَّص بموجب MIT License';

  @override
  String aboutFooterVersion(String version) {
    return 'الإصدار $version';
  }

  @override
  String get privacyTitle => 'الخصوصية';

  @override
  String get privacySubtitle => 'كيف يعمل Haven وما يستطيع الآخرون رؤيته';

  @override
  String get privacyHubSummary =>
      'لا يشارك Haven موقعك إلا مع المجموعات الصغيرة التي تختارها، وتُسمّى دوائر، ويُشفّره على هاتفك قبل أن يغادره. لا يوجد تسجيل ولا خادم يملكه Haven. الشيء الوحيد العلني هو الاسم المعروض والصورة اللذان تضبطهما. وتشرح الصفحات التالية ذلك، وكل ما عداه، بلغة بسيطة.';

  @override
  String get privacyGroupBasicsHeading => 'الأساسيات';

  @override
  String get privacyMeansForYouLabel => 'ما يعنيه هذا لك';

  @override
  String get privacyMoreDetailLabel => 'بمزيد من التفصيل';

  @override
  String get privacyMoreDetailExpandHint => 'إظهار التفاصيل التقنية';

  @override
  String get privacyMoreDetailCollapseHint => 'إخفاء التفاصيل التقنية';

  @override
  String get privacyMoreDetailExpandedAnnouncement => 'التفاصيل التقنية ظاهرة';

  @override
  String get privacyMoreDetailCollapsedAnnouncement => 'التفاصيل التقنية مخفية';

  @override
  String get privacyWhatHavenIsTitle => 'ما هو Haven، ولماذا لا يوجد حساب';

  @override
  String get privacyWhatHavenIsSubtitle => 'لا تسجيل، ولا خادم لشركة';

  @override
  String get privacyWhatHavenIsNoAccount =>
      'يشارك Haven موقعك مع مجموعات صغيرة تختارها بنفسك، تُسمّى دوائر. لا يوجد حساب خلف ذلك. لن تعطي بريدًا إلكترونيًا، ولا رقم هاتف، ولا كلمة مرور.';

  @override
  String get privacyWhatHavenIsNoServers =>
      'ولا يشغّل Haven أي خوادم خاصة به. تمرّ تحديثات موقعك المشفّرة عبر خوادم مستقلة تُسمّى مُرحِّلات، يشغّلها أشخاص آخرون. ولا يستطيع مطوّرو Haven رؤية موقعك، ولم يضعوا أي تتبّع في التطبيق. والشيء الوحيد الذي يرونه هو إجمالي مقدار استخدام الخريطة، لأن أجزاء الخريطة تُجلَب بمفتاح وصول واحد مشترك، لا يكشف مَن جلبها.';

  @override
  String get privacyWhatHavenIsMeansForYou =>
      'لا أحد يمكن إجباره على تسليم بياناتك، لأنه لا أحد يحتفظ بها. والثمن أن لا أحد يستطيع استعادة هويتك لك أيضًا. راجع «مفتاحاك» لمعرفة ما يجب أن تنسخه احتياطيًا.';

  @override
  String get privacyWhatHavenIsDetailNoTelemetry =>
      'لا يحتوي التطبيق على أي كود للتحليلات أو الإبلاغ عن الأعطال أو الإعلانات. ولأن Haven مفتوح المصدر، يمكن التحقق من ذلك بدلًا من الاكتفاء بالثقة.';

  @override
  String get privacyWhatHavenIsDetailNoPush =>
      'كذلك لا توجد في Haven إشعارات فورية، وذلك عن قصد. فخدمة الإشعارات سيلزم إبلاغها كلما كان لدى أحد في دوائرك ما يوصله إليك، وهذا سيكشف عن عاداتك أكثر مما تكشفه المُرحِّلات.';

  @override
  String get privacyYourKeysTitle => 'مفتاحاك: أحدهما سري والآخر للمشاركة';

  @override
  String get privacyYourKeysSubtitle => 'ما يعرّفك، وما يجب أن تنسخه احتياطيًا';

  @override
  String get privacyYourKeysWhatTheyAre =>
      'بدلًا من اسم مستخدم وكلمة مرور، لديك زوج من المفاتيح. المفتاح السري يُثبت أنك أنت. والمفتاح العام هو ما يستخدمه الآخرون ليجدوك ويدعوك.';

  @override
  String get privacyYourKeysSecretStaysHere =>
      'يُحفَظ مفتاحك السري على هذا الهاتف وحده، في مخزن يحميه نظام التشغيل. ولا يُرسله Haven إلى أي مكان: لا إلى أي خادم، ولا إلينا.';

  @override
  String get privacyYourKeysPublicIsSafe =>
      'مفتاحك العام آمن لتوزيعه. يعمل كاسم مستخدم يمكنك نشره في أي مكان. ومشاركته لا تكشف مكانك.';

  @override
  String get privacyYourKeysMeansForYou =>
      'لتحتفظ بهذه الهوية، انسخها احتياطيًا. اذهب إلى الإعدادات ← الهوية ← متقدّم، واضغط «إظهار المفتاح السري»، واحفظه في مكان آمن مثل مدير كلمات المرور. وبدون تلك النسخة الاحتياطية، يعني فقدان الهاتف فقدان الهوية إلى الأبد.';

  @override
  String get privacyYourKeysNeverShareSecret =>
      'من يحصل على مفتاحك السري يصبح هو أنت. يستطيع الانضمام إلى الدوائر بصفتك أو النشر باسمك. لا تلصقه أبدًا في تطبيق آخر، ولا في رسالة، ولا في موقع ويب.';

  @override
  String get privacyYourKeysDetailFormats =>
      'المفتاحان كلاهما من نوع secp256k1، ويُعرَضان بصيغتَي Nostr المعتادتين: المفتاح العام يبدأ بـ npub1 والمفتاح السري يبدأ بـ nsec1. يحدث التوقيع داخل التطبيق، ويُمحى المفتاح السري من الأجزاء التي تتعامل معه مباشرة بمجرّد استخدامه.';

  @override
  String get privacyYourKeysDetailSeparation =>
      'المفاتيح التي تُشفّر رسائل دوائرك منفصلة عن مفتاح الهوية هذا، ولا يحتفظ بها إلا التطبيق. هذا الفصل مقصود: فالمفتاح الذي يحمل اسمك ليس المفتاح الذي يفتح ما أرسلته.';

  @override
  String get privacyPublicProfileTitle => 'اسمك وصورتك عامّان';

  @override
  String get privacyPublicProfileSubtitle => 'مرئيان لأي شخص، لا لدوائرك فقط';

  @override
  String get privacyPublicProfileIsPublic =>
      'يُنشَر الاسم المعروض والصورة اللذان تضبطهما على Nostr، وهي الشبكة العامة المفتوحة التي يعمل عليها Haven. ويستطيع أي شخص البحث عنهما، لا الأشخاص الذين في دوائرك فقط.';

  @override
  String get privacyPublicProfileOnSave =>
      'يصير اسمك وصورتك علنيَّين في اللحظة التي تحفظهما فيها. لا يوجد إعداد يُبقيهما خاصَّين، ولا طريقة لمشاركة اسم مع دوائرك وحدها.';

  @override
  String get privacyPublicProfilePseudonym =>
      'تبدأ التثبيتات الجديدة باسم مُختلق مثل «Quiet Wanderer»، لا يقول عنك شيئًا. يمكنك الاحتفاظ به، أو استبداله بما تشاء.';

  @override
  String get privacyPublicProfileMeansForYou =>
      'اختر اسمًا وصورة ترتاح لعرضهما علنًا. وإن كنت تفضّل ألّا يُتعرَّف عليك، فاحتفظ بالاسم المُختلق الذي أُعطي لك، وتجاوز الصورة.';

  @override
  String get privacyPublicProfileRemovalIsNotDeletion =>
      'إزالة صورتك لاحقًا لا تحذف النسخة الموجودة على الخادم. يستبدل Haven ملفك الشخصي بملف فارغ. ويبقى ملف الصورة حيث هو مُستضاف، وتبقى أي نسخة نُزِّلت منه بالفعل في أيدي من نزّلها. اعتبر كل ما تنشره دائمًا.';

  @override
  String get privacyPublicProfileDetailKindZero =>
      'الملف الشخصي هو حدث Nostr من نوع «kind 0» موقَّع بمفتاح هويتك. وتُرفع الصور إلى مستضيف صور عام هو blossom.primal.net، فيرى الصورة ومفتاحك العام وعنوان شبكتك. ولا يتيح لك Haven بعدُ اختيار مستضيف آخر.';

  @override
  String get privacyPublicProfileDetailExifStripped =>
      'قبل الرفع، يعيد Haven ترميز الصورة ويُسقط البيانات المخفية التي ترفقها الكاميرات، ومنها موقع GPS الذي التُقطت فيه الصورة. وهذا مهم هنا: فصورة من رحلة قد تحمل، بغير ذلك، إحداثيات منزلك.';

  @override
  String get privacyGroupHowLocationTravelsHeading => 'كيف ينتقل موقعك';

  @override
  String get privacyRelaysTitle => 'المُرحِّلات: الخوادم التي تمرّر الرسائل';

  @override
  String get privacyRelaysSubtitle => 'عبر حواسيب مَن تمرّ تحديثاتك';

  @override
  String get privacyRelaysWhatIsARelay =>
      'لا يملك Haven خادمًا خاصًا به، فتمرّ تحديثاتك عبر خوادم يملكها آخرون. تُسمّى هذه الخوادم مُرحِّلات: خوادم صغيرة مستقلة يمكن لأي شخص تشغيلها. يحتفظ المُرحِّل بالرسالة المشفّرة لفترة وجيزة، ثم يمرّرها عندما تطلبها دائرتك.';

  @override
  String get privacyRelaysWhyMany =>
      'يستخدم Haven عدة مُرحِّلات، فلا يستطيع أيٌّ منها وحده أن يعزلك. وإن توقّف أحدها، واصلت البقية العمل. وأنت تختار المُرحِّلات التي تصلك عليها الدعوات، أما مُرحِّلات الدائرة فتُحدَّد عند إنشائها.';

  @override
  String get privacyRelaysYourLists =>
      'يحفظ Haven لك ثلاث قوائم. مُرحِّلات صندوق الوارد هي حيث تصلك الدعوات، ومُرحِّلات KeyPackage هي حيث يجلب الآخرون المفاتيح التي يحتاجونها لدعوتك — وينشر Haven هاتين القائمتين ليتمكّن الآخرون من العثور عليهما. أما مُرحِّلات ملفك الشخصي فمختلفة: هي حيث يُبحَث عن اسمك وصورتك ويُنشَران، لكن القائمة نفسها تبقى على جهازك ولا تُنشَر أبدًا. لذلك فإن المُرحِّل الذي لا يحمل سوى بيانات موقعك أو دعواتك لا تدلّه أي قائمة علنية على المُرحِّلات التي تستخدمها لملفك الشخصي. وتحمل كل دائرة أيضًا قائمتها الخاصة، وعبرها تنتقل تحديثات الدائرة المشفّرة.';

  @override
  String get privacyRelaysMeansForYou =>
      'لا يرى المُرحِّل موقعك أبدًا، لأنه يُشفَّر قبل أن يغادر هاتفك. لكنه يرى ما يجب أن يكون علنيًا ليصل إليك الناس: اسمك وصورتك، والمفاتيح التي يحتاجها الآخرون لدعوتك، وقائمة مُرحِّلاتك نفسها. ويبدأ Haven معك بمُرحِّلات تعمل، فليس عليك تغيير أي شيء.';

  @override
  String get privacyRelaysDetailIndexers =>
      'بمعزل عن قوائمك الخاصة، يستعلم Haven من مجموعة صغيرة من مُرحِّلات الدليل العامة ليبحث عن ملفات الآخرين الشخصية ومفاتيحهم. ويتصل بها حتى إن لم تضبط لنفسك سوى مُرحِّلات خاصة. وهي ترى عنوان الشبكة الذي تتصل منه والحسابات التي سألت عنها.';

  @override
  String get privacyRelaysDetailKeyListIsPublic =>
      'قائمة مُرحِّلات KeyPackage الخاصة بك موقَّعة بمفتاح هويتك، وتُنشَر على المُرحِّلات الموجودة فيها أصلًا. فإن أضفت إليها مُرحِّلًا خاصًا، صار عنوانه علنيًا ومرتبطًا بك. ولا توجد أي طريقة لإبقاء مُرحِّل في تلك القائمة خاصًا.';

  @override
  String get privacyEncryptionTitle => 'كيف يعمل التشفير';

  @override
  String get privacyEncryptionSubtitle =>
      'مفتاح واحد لكل دائرة، وما يتغيّر عند انضمام الناس أو مغادرتهم';

  @override
  String get privacyEncryptionPerCircle =>
      'يُشفَّر موقعك على هاتفك قبل أن يغادره، بمعيار مفتوح اسمه MLS. وكل دائرة هي مجموعتها المشفّرة الخاصة بمفاتيحها الخاصة. ولا يستطيع أحد من خارج الدائرة قراءة ما يُرسَل داخلها: لا مُرحِّل، ولا Haven نفسه، ولا دائرة أخرى أنت فيها.';

  @override
  String get privacyEncryptionWhenSomeoneJoins =>
      'عندما ينضمّ شخص، تنتقل الدائرة إلى مفتاح جديد. يستطيع قراءة ما يُرسَل بعد وصوله، ولا شيء مما سبقه. ولا يُرسِل Haven إلى العضو الجديد أي مواقع سابقة أبدًا.';

  @override
  String get privacyEncryptionWhenSomeoneLeaves =>
      'عندما يغادر شخص دائرة، تنتقل الدائرة إلى مفتاح جديد آخر. ولا يعود قادرًا على قراءة أي شيء جديد بمجرّد أن يلحق بقية أعضاء الدائرة بذلك التغيير، وهو ما يحدث عادةً في غضون دقائق قليلة، ويطول أكثر مع من كان غير متصل بالإنترنت حينها.';

  @override
  String get privacyEncryptionKeysChangeOnMembership =>
      'مغادرتك دائرة لا تسترجع ما حفظه أعضاؤها بالفعل. ولا يغيّر Haven المفاتيح إلا عند انضمام شخص أو مغادرته، ولا يفعل ذلك وفق مؤقّت أبدًا. لذا قد يغطّي مفتاح واحد رسائل أسابيع، ويبقى كل ما حفظه عضو في تلك المدة قابلًا للقراءة عنده. ومع ذلك لا يستطيع فتح أي شيء أُرسِل بعد مغادرته.';

  @override
  String get privacyEncryptionMeansForYou =>
      'يحميك التشفير من كل من هم خارج دوائرك. ولا يستطيع حمايتك من شخص كان يومًا داخل إحداها. فإن أردت التوقّف عن المشاركة مع شخص بعينه، غادِر الدائرة التي تشاركه فيها وابدأ دائرة جديدة من دونه.';

  @override
  String get privacyEncryptionDetailMls =>
      'إن معيار MLS (Messaging Layer Security) هو المعيار نفسه الصادر عن IETF والمستخدَم في تطبيقات مراسلة آمنة أخرى. ويصل Haven إلى شبكة Nostr من خلال بروتوكول Marmot الذي يحدّد كيف تنتقل مجموعات MLS عبر المُرحِّلات. ومفتاح هويتك العام في شبكة Nostr منفصل عن المفتاح الذي تُوقِّع به كل دائرة.';

  @override
  String get privacyEncryptionDetailEpochs =>
      'تُسمّى كل فترة يعمل فيها مفتاح واحد «حقبة»، ولا تنتقل الدائرة إلى حقبة جديدة إلا عند تغيّر عضويتها. ويحتفظ جهازك بمفاتيح الحقبة الحالية وبضع حقبات قريبة، بما يكفي لفتح الرسائل التي لا تزال في الطريق، ويتخلّص من الباقي. والدائرة التي لم تتغيّر عضويتها منذ أشهر لا تزال في الحقبة التي بدأت بها.';

  @override
  String get privacyWhatOthersSeeTitle =>
      'ما يراه الأعضاء، وما تراه المُرحِّلات';

  @override
  String get privacyWhatOthersSeeSubtitle =>
      'الأشخاص الذين تشارك معهم، والخوادم التي بينكم';

  @override
  String get privacyWhatOthersSeeMembersHeading => 'الأشخاص الذين في دوائرك';

  @override
  String get privacyWhatOthersSeeMembersExact =>
      'يرى كل فرد في الدائرة موقعك بدقّة على الخريطة، لا منطقة تقريبية. ولا يوجد إعداد يشارك موقعًا غامضًا مع بعض الأعضاء وموقعًا دقيقًا مع آخرين.';

  @override
  String get privacyWhatOthersSeeCannotPause =>
      'ما دام Haven مفتوحًا وأنت في دائرة، يُرسَل موقعك من تلقاء نفسه كل دقيقتين تقريبًا. ولا يوجد زرّ إيقاف مؤقّت: فالخيار الموجود في صفحة «الموقع» لا يتحكّم إلا في استمرار ذلك بعد إغلاقك التطبيق. وإن أردت التوقّف عن المشاركة مع دائرة، فافتحها واختر «مغادرة الدائرة».';

  @override
  String get privacyWhatOthersSeeMembersLearnKey =>
      'الانضمام إلى دائرة يُظهر أيضًا مفتاحك العام لكل عضو فيها. وعبره يستطيعون البحث عن ملفك الشخصي العام، وعن كل ما نشرته يومًا تحت ذلك المفتاح.';

  @override
  String get privacyWhatOthersSeeCoMemberIp =>
      'ينزّل هاتفك صورة الملف الشخصي لكل عضو من خادم اختاره ذلك العضو، دون أن تضغط على أي شيء. فيرى ذلك الخادم عنوان شبكتك، وهو ما يضعك تقريبًا على الخريطة. تُخفي شبكة VPN هذا الأمر، ولا يُخفيه شيء آخر.';

  @override
  String get privacyWhatOthersSeeRelaysHeading => 'مشغّلو المُرحِّلات';

  @override
  String get privacyWhatOthersSeeRelaysCannot =>
      'المُرحِّلات، وهي الخوادم المستقلة التي تمرّ بها تحديثاتك، لا تستطيع قراءة موقعك، ولا رسائلك، ولا اسم دائرتك، ولا قائمة أعضائها. تحمل تحديثات موقعك عنوان إرسال جديدًا يُستخدَم مرة واحدة فقط، بدلًا من مفتاحك العام. أما ملفك الشخصي ودعواتك وقوائم مُرحِّلاتك فتحمل مفتاحك العام، لذا يستطيع المُرحِّل الذي يمرّ به الاثنان أن يستنتج غالبًا أنك في دائرة، دون أن يقرأ شيئًا مما بداخلها.';

  @override
  String get privacyWhatOthersSeeRelaysCan =>
      'لكنها ترى عنوان شبكتك، ومتى تكون متصلًا، وحجم حركة بياناتك ومدى تكرارها. وتحمل كل دائرة وسمًا عشوائيًا. ويستطيع المُرحِّل أن يجمع رسائل الدائرة الواحدة بذلك الوسم ويقدّر عدد من فيها، دون أن يعرف هوية أي منهم.';

  @override
  String get privacyWhatOthersSeeMeansForYou =>
      'لا تنضمّ إلى دائرة إلا مع أشخاص تعطيهم عنوان منزلك. في مواجهة المُرحِّلات ومن هم في الخارج يصمد التشفير، وتُخفي شبكة VPN العنوان الذي يتصل منه هاتفك. أما العضو الذي يلتقط لقطة شاشة، فلا شيء يحميك منه.';

  @override
  String get privacyWhatOthersSeeDetailTag =>
      'يبقى وسم الدائرة كما هو مدى عمر تلك الدائرة، فيستطيع المُرحِّل ربط كل رسائلها معًا إلى أجل غير مسمّى. وهذه خاصية في البروتوكول الأساسي نفسه، وليست شيئًا يستطيع Haven تغييره.';

  @override
  String get commonLearnMore => 'اعرف المزيد';

  @override
  String get relaySettingsBackendCaption =>
      'لا يملك Haven خادمًا خاصًا به. تمرّ تحديثاتك المشفّرة عبر خوادم مستقلة تُسمّى مُرحِّلات، وهي لا تستطيع قراءة موقعك ولا رسائلك.';

  @override
  String get privacyWhatOthersSeeScreenshots =>
      'يعتمد هذا على هاتفك. على Android يمنع Haven لقطات الشاشة وتسجيل الشاشة في كل أنحاء التطبيق. أما على iPhone فلا يستطيع ذلك: يجعل Haven معاينة مبدّل التطبيقات ضبابية، لكن يظل بإمكان أي عضو أن يلتقط ما يظهر على الشاشة.';

  @override
  String get privacyWhatOthersSeeDetailExpiry =>
      'يطلب Haven من المُرحِّلات إسقاط رسائل الموقع بعد نحو أربع دقائق. وهذا الطلب استرشادي: فللمُرحِّل أن يحتفظ بها مدة أطول. أما الدعوات فلا تحمل أي مدة انتهاء، وقد تبقى على مُرحِّل صندوق وارِدك إلى أجل غير مسمّى.';

  @override
  String get privacyGroupTheLimitsHeading => 'حدود الحماية';

  @override
  String get privacyInferenceTitle => 'ما لا يزال يمكن استنتاجه عنك';

  @override
  String get privacyInferenceSubtitle => 'الآثار التي لا يحجبها التشفير';

  @override
  String get privacyInferenceWhatIsMetadata =>
      'يُخفي التشفير ما تُرسله. لكنه لا يستطيع أن يخفي أنك أرسلت شيئًا. ويُسمّى الأثر المتبقّي البيانات الوصفية: متى خرجت الرسالة، وما حجمها، وبأي خوادم كنت متصلًا. ويبقى هذا الأثر مرئيًا حتى عندما لا يكون المحتوى كذلك.';

  @override
  String get privacyInferenceActivityPattern =>
      'ومن هذا النمط، يستطيع مُرحِّل تستخدمه أن يعرف تقريبًا متى تكون نشطًا وكم مرة. ويُرسل Haven أيضًا تحديثًا إضافيًا كلما تحرّكت نحو مئة متر. وعلى مدى ساعات، قد يكشف ذلك للمُرحِّل ما إذا كنت متنقّلًا أم ثابتًا في مكانك. لكنه لا يكشف المكان أبدًا.';

  @override
  String get privacyInferencePresence =>
      'ما دام Haven يعمل، فهو يُبقي اتصالًا مفتوحًا بمُرحِّلاتك. وتستطيع هي أن ترى أنك متصل، وأي وسوم دوائر تتابع، لا اسم دائرة ولا من فيها أبدًا. وهذا هو ثمن وصول التحديثات في ثوانٍ بدلًا من دقائق.';

  @override
  String get privacyInferenceIpHeading => 'عنوان شبكتك';

  @override
  String get privacyInferenceIpAddress =>
      'كل خادم يتحدّث إليه Haven يرى العنوان الذي يتصل منه هاتفك، أي عنوان IP الخاص به: مُرحِّلاتك، ومزوّد الخرائط، ومن يستضيف صورة الملف الشخصي لأي عضو. ويرى مزوّد الإنترنت أيَّ هذه الخوادم وصلت إليه، ومتى. ولا يفعل Haven من تلقاء نفسه أي شيء لإخفاء أيٍّ من هذين الأمرين.';

  @override
  String get privacyInferenceMapTilesHeading => 'الخريطة نفسها';

  @override
  String get privacyInferenceMapTiles =>
      'لرسم الخريطة يطلب Haven من مزوّد الخرائط مربّعات الصور الظاهرة على الشاشة، فيعرف المزوّد تقريبًا أي الأماكن تنظر إليها. ويجلب Haven أيضًا مساحة صغيرة حول كل عضو تراه قبل أن تنتقل إليها، حتى تكون الخريطة جاهزة؛ وهذا يعني أن المزوّد قد يعرف تقريبًا أين يكون أفراد دائرتك، وليس المكان الذي تنظر إليه فحسب. وتبقى هذه المربّعات في ذاكرة مؤقّتة مشفّرة على هاتفك مدة تصل إلى سبعة أيام، وتُمسَح إن حذفت هويتك.';

  @override
  String get privacyInferenceVpnHeading => 'هل تحتاج إلى شبكة VPN؟';

  @override
  String get privacyInferenceVpnHelps =>
      'تستبدل شبكة VPN عنوان شبكتك بعنوانها، فلا ترى المُرحِّلات ولا الخوادم الأخرى من أين تتصل. وتخفي أيضًا عن مزوّد الإنترنت أي الخوادم تصل إليها. نوصي بـ Mullvad.';

  @override
  String get privacyInferenceVpnLimits =>
      'لكنها ليست دواءً لكل داء. لا تُغيّر شبكة VPN شيئًا مما يراه أعضاء دائرتك، ولا تُخفي توقيت حركة بياناتك ولا حجمها عن مُرحِّل تتحدّث إليه. وهي تنقل ثقتك إلى شركة VPN بدلًا من أن تُغنيك عن الحاجة إلى الثقة بأحد.';

  @override
  String get privacyInferenceMeansForYou =>
      'هل يقلقك أن تضعك المُرحِّلات أو مزوّد الإنترنت أو خوادم الخرائط على خريطة؟ إذًا فشبكة VPN هي أنفع شيء واحد يمكنك إضافته. وهل يقلقك الأشخاص الذين في دوائرك؟ فهي لن تساعدك على الإطلاق.';

  @override
  String get privacyInferenceDetailJitter =>
      'يُغيّر Haven الفاصل الزمني بين التحديثات عن قصد، فلا يُظهر تسجيل قصير أي إيقاع منتظم. لكن عند حساب المتوسّط على مدى ساعات طويلة، يبقى تقدير الوتيرة الأساسية ممكنًا. ولا يُضاف حشو إلى أحجام الرسائل أيضًا، وتقع تحديثات الموقع في نطاق حجم ضيّق، وهذا ما يجعل التعرّف عليها بوصفها تحديثات موقع ممكنًا.';

  @override
  String get privacyInferenceDetailOutOfScope =>
      'أمران يتجاوزان أي قرار تصميمي هنا: مراقبٌ يستطيع رصد مُرحِّلات كثيرة في وقت واحد، وهاتفك أنت بعد أن يسيطر عليه شخص آخر.';

  @override
  String get commonClearAll => 'مسح الكل';

  @override
  String commonMemberCount(int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$countString عضو',
      many: '$countString عضوًا',
      few: '$countString أعضاء',
      two: 'عضوان',
      one: 'عضو واحد',
      zero: 'لا أعضاء',
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
  String get circlesTitle => 'الدوائر';

  @override
  String get circlesRefreshTooltip => 'تحديث الدوائر';

  @override
  String get circlesRequiresIdentity =>
      'يتطلّب إنشاء الدائرة إعداد الهوية أولًا';

  @override
  String get circlesCreateCta => 'إنشاء دائرة';

  @override
  String get circlesYourCircles => 'دوائرك';

  @override
  String get circlesEmptyTitle => 'لا توجد دوائر بعد';

  @override
  String get circlesEmptyMessage =>
      'أنشئ دائرة لتبدأ مشاركة موقعك مع الأصدقاء والعائلة الموثوقين.';

  @override
  String get circlesSheetEmptyMessage =>
      'أنشئ دائرة لتبدأ مشاركة موقعك مع جهات اتصال موثوقة.';

  @override
  String get circlesLoadError => 'تعذّر تحميل الدوائر';

  @override
  String get circlesSelectToView => 'اختر دائرة لعرض الأعضاء';

  @override
  String get circlesNoMembers => 'لا أعضاء في هذه الدائرة';

  @override
  String get createCircleTitle => 'إضافة أعضاء';

  @override
  String createCircleSelectedCount(int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    return 'المُحدَّد ($countString)';
  }

  @override
  String get createCircleEmptyTitle => 'أضف أعضاء الدائرة';

  @override
  String get createCircleEmptyMessage =>
      'ابحث بالمعرّف أو امسح رمز QR الخاص بهم لإضافة الأعضاء.';

  @override
  String get createCircleNoValidMembers => 'لا أعضاء صالحون للدعوة';

  @override
  String get createCircleMemberAlreadyAdded => 'العضو مُضاف بالفعل';

  @override
  String get createCircleNoIdInQr => 'لم يُعثَر على معرّف صالح في رمز QR';

  @override
  String get createCircleNoAccountFound =>
      'لم يُعثَر على حساب Haven لهذا المعرّف';

  @override
  String get createCircleCouldNotVerify => 'تعذّر التحقق من العضو';

  @override
  String get createCircleSomethingWentWrong => 'حدث خطأ ما';

  @override
  String get nameCircleTitle => 'سمِّ دائرتك';

  @override
  String nameCircleMembersToInvite(int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'ستُرسَل دعوة إلى $countString عضو',
      many: 'ستُرسَل دعوة إلى $countString عضوًا',
      few: 'ستُرسَل دعوة إلى $countString أعضاء',
      two: 'ستُرسَل دعوة إلى عضوين',
      one: 'ستُرسَل دعوة إلى عضو واحد',
      zero: 'لن يُدعى أحد',
    );
    return '$_temp0';
  }

  @override
  String get nameCircleNameLabel => 'اسم الدائرة';

  @override
  String get nameCircleNameHint => 'مثل: العائلة، الأصدقاء المقرّبون';

  @override
  String get nameCircleNameEmptyError => 'يُرجى إدخال اسم للدائرة';

  @override
  String get nameCircleNameTooLongError => 'يجب ألّا يتجاوز الاسم 50 حرفًا';

  @override
  String get nameCircleSharingInfo =>
      'يستطيع كل فرد في هذه الدائرة رؤية موقع الآخرين واسمهم العلني وصورتهم. اسمك وصورتك علنيّان على شبكة Nostr، وليسا خاصَّين بهذه الدائرة. وتبقى هذه الدائرة منفصلة عن أي دوائر أخرى أنت فيها، فلا يستطيع أعضاؤها رؤية دوائرك الأخرى أو من فيها.';

  @override
  String get nameCircleCreateCta => 'إنشاء دائرة';

  @override
  String get nameCircleStageCreatingGroup => 'جارٍ إنشاء مجموعة آمنة...';

  @override
  String get nameCircleStageSendingInvites => 'جارٍ إرسال الدعوات...';

  @override
  String get nameCircleStageComplete => 'تم!';

  @override
  String nameCircleProgressSemantics(String stage) {
    return 'تقدّم الإنشاء: $stage';
  }

  @override
  String nameCirclePercentComplete(int percent) {
    final intl.NumberFormat percentNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String percentString = percentNumberFormat.format(percent);

    return 'اكتمل $percentString بالمئة';
  }

  @override
  String nameCircleCreatedSnack(String name, int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'تم إنشاء الدائرة \"$name\"! أُرسلت $countString دعوة.',
      many: 'تم إنشاء الدائرة \"$name\"! أُرسلت $countString دعوة.',
      few: 'تم إنشاء الدائرة \"$name\"! أُرسلت $countString دعوات.',
      two: 'تم إنشاء الدائرة \"$name\"! أُرسلت دعوتان.',
      one: 'تم إنشاء الدائرة \"$name\"! أُرسلت دعوة واحدة.',
      zero: 'تم إنشاء الدائرة \"$name\"! لم تُرسَل دعوات.',
    );
    return '$_temp0';
  }

  @override
  String get nameCircleIdentityError =>
      'خطأ في الهوية. يُرجى التحقق من إعداد هويتك.';

  @override
  String get nameCircleCreateError =>
      'تعذّر إنشاء الدائرة. يُرجى إعادة المحاولة.';

  @override
  String addMemberTitle(String circleName) {
    return 'إضافة إلى $circleName';
  }

  @override
  String get addMemberInfo =>
      'بمجرّد قبولهم، سيرون مواقع الجميع من تلك اللحظة فصاعدًا، ولن يروا أبدًا أي شيء أُرسِل قبل انضمامهم. وسيرون أيضًا المفاتيح العامة لكل من هم في هذه الدائرة بالفعل.';

  @override
  String get addMemberAlreadyInCircle => 'موجود في هذه الدائرة بالفعل';

  @override
  String addMemberSendInvitation(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'إرسال الدعوات',
      many: 'إرسال الدعوات',
      few: 'إرسال الدعوات',
      two: 'إرسال دعوتين',
      one: 'إرسال دعوة',
      zero: 'إرسال دعوة',
    );
    return '$_temp0';
  }

  @override
  String addMemberSendingInvitation(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'جارٍ إرسال الدعوات...',
      many: 'جارٍ إرسال الدعوات...',
      few: 'جارٍ إرسال الدعوات...',
      two: 'جارٍ إرسال الدعوتين...',
      one: 'جارٍ إرسال الدعوة...',
      zero: 'جارٍ إرسال الدعوة...',
    );
    return '$_temp0';
  }

  @override
  String addMemberSentToCircle(int count, String circleName) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'أُرسلت الدعوات إلى $circleName',
      many: 'أُرسلت الدعوات إلى $circleName',
      few: 'أُرسلت الدعوات إلى $circleName',
      two: 'أُرسلت الدعوتان إلى $circleName',
      one: 'أُرسلت الدعوة إلى $circleName',
      zero: 'أُرسلت الدعوة إلى $circleName',
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

    return 'أُرسلت الدعوات ($sentString من $totalString). التسليم معلّق للبقية.';
  }

  @override
  String get addMemberError => 'تعذّرت إضافة العضو. يُرجى إعادة المحاولة.';

  @override
  String get qrScannerTitle => 'مسح رمز QR';

  @override
  String get qrScannerToggleFlash => 'تبديل الفلاش';

  @override
  String get qrScannerSwitchCamera => 'تبديل الكاميرا';

  @override
  String get qrScannerInstruction => 'ضع رمز QR داخل الإطار';

  @override
  String get qrScannerScanning => 'جارٍ المسح...';

  @override
  String get circleMemberInvitationPending => 'الدعوة معلّقة';

  @override
  String get circleMemberNoRecentLocation => 'لا موقع حديث';

  @override
  String get circleMemberRemoveTooltip => 'إزالة من الدائرة';

  @override
  String get circleMemberAdmin => 'مشرف';

  @override
  String get circleMemberHintPending => 'الدعوة معلّقة';

  @override
  String get circleMemberHintNoLocation => 'لا موقع متاح';

  @override
  String get circleMemberHintMember => 'عضو';

  @override
  String get circleMemberHintTapToCenter => 'اضغط لتوسيط الخريطة على موقعه';

  @override
  String get pendingMemberRetryTooltip => 'إعادة محاولة التحقق';

  @override
  String get pendingMemberRemoveTooltip => 'إزالة من القائمة';

  @override
  String get pendingMemberValidating => 'جارٍ التحقق';

  @override
  String get pendingMemberValid => 'صالح';

  @override
  String get pendingMemberWarning => 'تحذير';

  @override
  String get pendingMemberCheckingAvailability => 'جارٍ التحقق من التوفّر...';

  @override
  String get pendingMemberReadyToInvite => 'جاهز للدعوة';

  @override
  String get pendingMemberNeedsUpdate => 'بحاجة إلى تحديث Haven';

  @override
  String get memberSearchHint => 'أدخل معرّف العضو...';

  @override
  String get memberSearchPasteTooltip => 'لصق من الحافظة';

  @override
  String get memberSearchAddTooltip => 'إضافة عضو';

  @override
  String get memberSearchScanTooltip => 'مسح رمز QR';

  @override
  String get memberSearchHelper =>
      'اطلب من جهات اتصالك رمز Haven QR أو المعرّف الخاص بهم';

  @override
  String get memberSearchNoValidId => 'لم يُعثَر على معرّف Haven صالح';

  @override
  String get memberSearchAlreadyAdded => 'العضو مُضاف بالفعل';

  @override
  String selectedMembersMore(int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    return '+$countString آخرون';
  }

  @override
  String get invitationStatusPending => 'الدعوة معلّقة';

  @override
  String get invitationStatusActive => 'نشط';

  @override
  String get invitationStatusDeclined => 'مرفوضة';

  @override
  String invitationStatusSemantics(String label) {
    return 'حالة الدعوة: $label';
  }

  @override
  String invitationCardSemantics(String circleName, String inviter, int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    return 'دعوة للانضمام إلى $circleName، بدعوة من $inviter، $countString أعضاء';
  }

  @override
  String invitationCardInvitedBySemantics(String inviter) {
    return 'بدعوة من المعرّف التشفيري $inviter';
  }

  @override
  String invitationCardInvitedBy(String inviter) {
    return 'بدعوة من: $inviter';
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
      many: '$countString عضوًا',
      few: '$countString أعضاء',
      two: 'عضوان',
      one: 'عضو واحد',
      zero: 'لا أعضاء',
    );
    return '$_temp0';
  }

  @override
  String get invitationCardJustNow => 'الآن للتو';

  @override
  String invitationCardDaysAgo(int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    return 'قبل ${countString}d';
  }

  @override
  String invitationCardHoursAgo(int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    return 'قبل ${countString}h';
  }

  @override
  String invitationCardMinutesAgo(int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    return 'قبل ${countString}m';
  }

  @override
  String get invitationCardDecline => 'رفض';

  @override
  String get invitationCardAccept => 'قبول';

  @override
  String get invitationAcceptedSnack => 'قُبلت الدعوة';

  @override
  String get invitationDeclinedSnack => 'رُفضت الدعوة';

  @override
  String get invitationAcceptError =>
      'تعذّر قبول الدعوة. يُرجى إعادة المحاولة.';

  @override
  String get invitationDeclineError =>
      'تعذّر رفض الدعوة. يُرجى إعادة المحاولة.';

  @override
  String get circleSelectorLabel => 'مُحدِّد الدائرة';

  @override
  String get circleSelectorPlaceholder => 'اختر دائرة';

  @override
  String get circleSelectorNewCircle => 'دائرة جديدة';

  @override
  String get circleSelectorLoadError => 'تعذّر تحميل الدوائر';

  @override
  String get circleSelectorExpandedAnnouncement => 'قائمة الدوائر مفتوحة';

  @override
  String get circleSelectorCollapsedAnnouncement => 'قائمة الدوائر مطوية';

  @override
  String get circleDetailsButtonTooltip => 'تفاصيل الدائرة';

  @override
  String get circleDetailsTitle => 'تفاصيل الدائرة';

  @override
  String circleDetailsMembersWithEpoch(String members, int epoch) {
    final intl.NumberFormat epochNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String epochString = epochNumberFormat.format(epoch);

    return '$members · الحقبة $epochString';
  }

  @override
  String get circleDetailsRelaysHeading => 'مُرحِّلات هذه الدائرة';

  @override
  String get circleDetailsNoRelays => '(لا شيء مسجّل)';

  @override
  String get circleDetailsRelaysNote =>
      'نُسِخت هذه المُرحِّلات من مُرحِّلات صندوق الوارد لديك عند إنشاء هذه الدائرة، ولا يمكن تغييرها بعد. والتعديلات اللاحقة على قائمة مُرحِّلاتك الشخصية لا تغيّرها.';

  @override
  String get circleDetailsAddMember => 'إضافة عضو';

  @override
  String get circleDetailsLeaveCircle => 'مغادرة الدائرة';

  @override
  String get leaveCircleDialogTitle => 'مغادرة الدائرة';

  @override
  String get leaveCircleDialogBody =>
      'هل تريد مغادرة هذه الدائرة؟ ستتوقّف عن إرسال موقعك إلى أعضائها وعن رؤية مواقعهم. ويبقى آخر موقع أرسلته على هواتفهم مدة تصل إلى يوم. ولا يمكنك التراجع عن هذا: ستحتاج إلى دعوة جديدة للانضمام من جديد.';

  @override
  String get leaveCircleConfirm => 'مغادرة';

  @override
  String get leaveCircleIdentityUnavailable => 'الهوية غير متاحة';

  @override
  String get leaveCircleSuccess => 'تمت مغادرة الدائرة بنجاح';

  @override
  String get leaveCircleError => 'تعذّرت مغادرة الدائرة';

  @override
  String get circleBlockedBannerTitle => 'لا يمكن تحديث هذه الدائرة';

  @override
  String get circleBlockedBannerBody =>
      'حدث خلل في تشفير هذه الدائرة، فلم يعد Haven قادرًا على إرسال التحديثات فيها أو استقبالها. يمكنك مع ذلك الاطلاع على آخر ما عرفته أدناه، أو مغادرة الدائرة.';

  @override
  String get legacyCircleBannerTitle => 'يجب إعادة إنشاء هذه الدائرة';

  @override
  String get legacyCircleBannerBody =>
      'جرى تحديث محرك التشفير في Haven، فلم يعد بالإمكان استخدام هذه الدائرة. أعد إنشاءها لمواصلة مشاركة الموقع مع الأشخاص أنفسهم. ستحتاج إلى دعوتهم مجددًا.';

  @override
  String get legacyCircleRecreateCta => 'إعادة إنشاء الدائرة';

  @override
  String get legacyCircleRemoveCta => 'إزالة';

  @override
  String get legacyCircleRemoveDialogTitle => 'إزالة الدائرة؟';

  @override
  String get legacyCircleRemoveDialogBody =>
      'لم يعد بالإمكان استخدام هذه الدائرة وستُزال من قائمتك. لا يؤثر هذا في أي دائرة جديدة تُنشئها لتحل محلها.';

  @override
  String get legacyCircleRemoveConfirm => 'إزالة';

  @override
  String get legacyCutoverExplainerTitle => 'تم تحديث Haven';

  @override
  String get legacyCutoverExplainerIdentityUnchanged =>
      'هويتك وملفك الشخصي العام لم يتغيّرا. ولا يلزمك فعل أي شيء بشأنهما.';

  @override
  String get legacyCutoverExplainerCirclesNeedRecreation =>
      'لتحسين الأمان، يجب إعادة إنشاء دوائرك ودعوة أعضائها مجددًا قبل أن تتمكّن من مشاركة الموقع فيها من جديد.';

  @override
  String get legacyCutoverExplainerAcknowledge => 'فهمت';

  @override
  String get relaySettingsLegacyRetractionPending =>
      'لا يزال Haven يطلب من المُرحِّلات إسقاط بعض البيانات القديمة من التحديث الأمني الأخير.';

  @override
  String get circlesPanelCollapsedAnnouncement => 'لوحة الدوائر مطوية';

  @override
  String get circlesPanelExpandedAnnouncement => 'لوحة الدوائر مفتوحة';

  @override
  String get circlesPanelSlightlyOpenAnnouncement =>
      'لوحة الدوائر مفتوحة قليلًا';

  @override
  String get circlesPanelHalfOpenAnnouncement => 'لوحة الدوائر مفتوحة نصفيًا';

  @override
  String get circleMemberAnnouncementSelf => 'أنت';

  @override
  String get circleMemberAnnouncementFallback => 'عضو';

  @override
  String get invitationsRefreshTooltip => 'تحديث الدعوات';

  @override
  String get invitationsLoadError => 'تعذّر تحميل الدعوات';

  @override
  String get invitationsEmptyTitle => 'لا توجد دعوات';

  @override
  String get invitationsEmptyMessage =>
      'عندما يدعوك أحدهم إلى دائرة، ستظهر هنا.';

  @override
  String get refreshRingSemanticNoInbox =>
      'لا يوجد صندوق وارد مُهيَّأ، يفتح إعدادات المُرحِّلات';

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
      other: 'تم فحص $checkedString من أصل $totalString مُرحِّل',
      many: 'تم فحص $checkedString من أصل $totalString مُرحِّلًا',
      few: 'تم فحص $checkedString من أصل $totalString مُرحِّلات',
      two: 'تم فحص $checkedString من أصل مُرحِّلَين',
      one: 'تم فحص $checkedString من أصل مُرحِّل واحد',
      zero: 'تم فحص $checkedString من أصل $totalString مُرحِّل',
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
      other: 'استجابت $totalString مُرحِّل',
      many: 'استجاب $totalString مُرحِّلًا',
      few: 'استجابت $totalString مُرحِّلات',
      two: 'استجاب المُرحِّلان',
      one: 'استجاب المُرحِّل',
      zero: 'استجابت جميع المُرحِّلات',
    );
    return '$_temp0';
  }

  @override
  String get refreshRingSemanticAllError => 'لم يستجب أي مُرحِّل';

  @override
  String refreshRingSemanticPartial(int ok, int total) {
    final intl.NumberFormat okNumberFormat = intl.NumberFormat.decimalPattern(
      localeName,
    );
    final String okString = okNumberFormat.format(ok);
    final intl.NumberFormat totalNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String totalString = totalNumberFormat.format(total);

    return 'استجاب $okString من أصل $totalString مُرحِّل';
  }

  @override
  String get refreshRingAnnouncementChecking => 'جارٍ فحص المُرحِّلات';

  @override
  String get refreshRingAnnouncementAllOk => 'استجابت جميع المُرحِّلات';

  @override
  String refreshRingAnnouncementPartial(int ok, int total) {
    final intl.NumberFormat okNumberFormat = intl.NumberFormat.decimalPattern(
      localeName,
    );
    final String okString = okNumberFormat.format(ok);
    final intl.NumberFormat totalNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String totalString = totalNumberFormat.format(total);

    return 'استجاب $okString من أصل $totalString مُرحِّل';
  }

  @override
  String get refreshRingAnnouncementAllError => 'تعذّر الوصول إلى أي مُرحِّل';

  @override
  String get refreshRingAnnouncementNoInbox => 'لا يوجد صندوق وارد مُهيَّأ';

  @override
  String refreshRingSemanticAllFound(int total) {
    final intl.NumberFormat totalNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String totalString = totalNumberFormat.format(total);

    String _temp0 = intl.Intl.pluralLogic(
      total,
      locale: localeName,
      other: '$totalString مُرحِّل يحتوي على بياناتك',
      many: '$totalString مُرحِّلًا يحتوي على بياناتك',
      few: '$totalString مُرحِّلات تحتوي على بياناتك',
      two: 'المُرحِّلان يحتويان على بياناتك',
      one: 'المُرحِّل يحتوي على بياناتك',
      zero: 'جميع المُرحِّلات تحتوي على بياناتك',
    );
    return '$_temp0';
  }

  @override
  String get refreshRingSemanticNoneFound =>
      'لا يوجد مُرحِّل يحتوي على بياناتك';

  @override
  String refreshRingSemanticPartialFound(int ok, int total) {
    final intl.NumberFormat okNumberFormat = intl.NumberFormat.decimalPattern(
      localeName,
    );
    final String okString = okNumberFormat.format(ok);
    final intl.NumberFormat totalNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String totalString = totalNumberFormat.format(total);

    return '$okString من أصل $totalString مُرحِّل يحتوي على بياناتك';
  }

  @override
  String get refreshRingAnnouncementAllFound =>
      'جميع المُرحِّلات تحتوي على بياناتك';

  @override
  String refreshRingAnnouncementPartialFound(int ok, int total) {
    final intl.NumberFormat okNumberFormat = intl.NumberFormat.decimalPattern(
      localeName,
    );
    final String okString = okNumberFormat.format(ok);
    final intl.NumberFormat totalNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String totalString = totalNumberFormat.format(total);

    return '$okString من أصل $totalString مُرحِّل يحتوي على بياناتك';
  }

  @override
  String get refreshRingAnnouncementNoneFound =>
      'لا يوجد مُرحِّل يحتوي على بياناتك';

  @override
  String get identityTitle => 'الهوية';

  @override
  String get identityLoadError =>
      'حدث خطأ ما أثناء تحميل هويتك. يُرجى إعادة المحاولة.';

  @override
  String get identityMissingTitle => 'لا توجد هوية';

  @override
  String get identityMissingMessage =>
      'ضاعت هويتك. أعدّ هوية جديدة لمواصلة استخدام Haven.';

  @override
  String get identitySetUpCta => 'إعداد الهوية';

  @override
  String get identityPublicKeyQrTitle => 'رمز QR للمفتاح العام';

  @override
  String get identityPublicKeyQrSubtitle => 'كيف يدعوك الآخرون إلى الدوائر';

  @override
  String get identityAdvancedTitle => 'متقدّم';

  @override
  String get identityAdvancedSubtitle => 'المفتاح العام، المفتاح السري، الحذف';

  @override
  String get profileIsPublicNoticeTitle => 'ملفك الشخصي عام';

  @override
  String get profileIsPublicNoticeBody =>
      'اسمك المعروض وصورتك مرئيان لأي شخص على شبكة Nostr، لا لأعضاء دوائرك فقط. شارِك فقط ما ترتاح لجعله عامًا.';

  @override
  String get identityRefreshProfileTooltip => 'تحديث الملف الشخصي العام';

  @override
  String get identityAdvancedExportError =>
      'تعذّر تصدير المفتاح السري. يُرجى إعادة المحاولة.';

  @override
  String get identityAdvancedDeleteTitle => 'حذف الهوية؟';

  @override
  String get identityAdvancedDeleteBody =>
      'يحذف هذا هويتك وكل بيانات دوائرك من هذا الهاتف. أما ما نُشِر تحتها بالفعل، بما في ذلك اسمك وصورتك ومفاتيحك، فيبقى على المُرحِّلات التي لديها نسخة منه. وتأكّد من أنك نسخت مفتاحك السري احتياطيًا إن أردت استعادتها.';

  @override
  String get identityAdvancedDeleteConfirm => 'حذف';

  @override
  String get identityAdvancedDeletedSnack => 'تم حذف الهوية';

  @override
  String get identityAdvancedDeleteError =>
      'تعذّر حذف الهوية. يُرجى إعادة المحاولة.';

  @override
  String identityAdvancedCopiedToClipboard(String label) {
    return 'تم نسخ $label إلى الحافظة';
  }

  @override
  String get identityAdvancedSecretCopiedWarning =>
      'تم نسخ المفتاح السري. تحذير: قد تقرأ تطبيقات أخرى حافظتك. الصقه في مكان آمن وامسح حافظتك.';

  @override
  String get identityAdvancedMissingBody => 'لم تُعدّ أي هوية.';

  @override
  String get identityAdvancedPublicKeyLabel => 'المفتاح العام';

  @override
  String get identityAdvancedPublicKeyHexLabel => 'المفتاح العام (hex)';

  @override
  String get identityAdvancedCopyValue => 'المفتاح العام';

  @override
  String get identityAdvancedCopyPublicKeyTooltip => 'نسخ المفتاح العام';

  @override
  String get identityAdvancedCopyHexTooltip => 'نسخ hex';

  @override
  String get identityAdvancedSecretKeyTitle => 'المفتاح السري';

  @override
  String get identityAdvancedSecretKeyWarning =>
      'يمنح مفتاحك السري وصولًا كاملًا إلى هويتك. لا تشاركه مع أي أحد أبدًا.';

  @override
  String get identityAdvancedRevealSecretKey => 'إظهار المفتاح السري';

  @override
  String get identityAdvancedHideSecretKey => 'إخفاء المفتاح السري';

  @override
  String get identityAdvancedCopySecretKeyTooltip => 'نسخ المفتاح السري';

  @override
  String get identityAdvancedDeleteIdentityCta => 'حذف الهوية';

  @override
  String get qrCodeLoadError =>
      'حدث خطأ ما أثناء تحميل مفتاحك العام. يُرجى إعادة المحاولة.';

  @override
  String get qrCodeYourPublicKeyLabel => 'مفتاحك العام';

  @override
  String get qrCodeWhatIsThisTitle => 'ما هذا؟';

  @override
  String get qrCodeExplainerKeys =>
      'يعمل Haven على Nostr، وهي شبكة مفتوحة لا يقف خلفها حساب شركة ولا تسجيل. هويتك مجرّد زوج من المفاتيح: مفتاح سري تحتفظ به أنت وحدك، وهذا المفتاح العام المُشتقّ منه.';

  @override
  String get qrCodeExplainerUsername =>
      'يعمل مفتاحك العام كاسم مستخدم آمن للمشاركة. يمسح الناس هذا الرمز، أو يلصقون مفتاحك العام، لدعوتك إلى دائرة. ومشاركته لا يمكن أن تكشف مكانك. أما اسمك المعروض وصورتك فهما علنيّان بالفعل، لذا لا يضيف هذا شيئًا.';

  @override
  String get displayNameCardTitle => 'الاسم المعروض';

  @override
  String get displayNameCardLoadError =>
      'تعذّر تحميل اسمك المعروض. حاول لاحقًا.';

  @override
  String get displayNameCardHint => 'أدخل اسمك المعروض';

  @override
  String get displayNameCardSavedLabel => 'تم حفظ الاسم المعروض';

  @override
  String get displayNameCardSaveLabel => 'حفظ الاسم المعروض';

  @override
  String get displayNameCardSavingLabel => 'جارٍ حفظ الاسم المعروض';

  @override
  String get displayNameCardRetryLabel => 'فشل الحفظ. أعد المحاولة';

  @override
  String get displayNameCardSavedAnnouncement => 'تم حفظ الاسم المعروض';

  @override
  String get displayNameCardSaveFailedAnnouncement => 'فشل الحفظ، أعد المحاولة';

  @override
  String keyDisplayCopiedToClipboard(String label) {
    return 'تم نسخ $label إلى الحافظة';
  }

  @override
  String keyDisplaySemantics(String label, String state) {
    return '$label: $state';
  }

  @override
  String get keyDisplayStateRevealed => 'ظاهر';

  @override
  String get keyDisplayStateHidden => 'مخفي';

  @override
  String get keyDisplayHideTooltip => 'إخفاء';

  @override
  String get keyDisplayRevealTooltip => 'إظهار';

  @override
  String get keyDisplayCopyTooltip => 'نسخ';

  @override
  String get keyDisplayCompactCopied => 'تم نسخ المفتاح إلى الحافظة';

  @override
  String get keyDisplayCompactTapToCopy => 'اضغط للنسخ';

  @override
  String get npubQrCopiedSnack => 'تم نسخ المفتاح العام إلى الحافظة';

  @override
  String get npubQrCopyButton => 'نسخ المفتاح العام';

  @override
  String get circleMemberPublicKeyCopied => 'تم نسخ المفتاح العام إلى الحافظة';

  @override
  String get circleMemberCopyPublicKeyHint => 'نسخ المفتاح العام';

  @override
  String get circleMemberSetNicknameMenuItem => 'تعيين اسم مستعار';

  @override
  String get circleMemberCopyPublicKeyMenuItem => 'نسخ المفتاح العام';

  @override
  String get memberProfileRefreshErrorGeneric =>
      'تعذّر تحديث الملفات الشخصية. يُرجى إعادة المحاولة.';

  @override
  String get memberDetailSheetTitle => 'تفاصيل العضو';

  @override
  String get memberNicknameSheetHint => 'أدخل اسمًا مستعارًا';

  @override
  String get memberNicknameSheetLabel => 'اسم مستعار';

  @override
  String get memberNicknameSheetSave => 'حفظ الاسم المستعار';

  @override
  String get memberNicknameSheetClear => 'مسح الاسم المستعار';

  @override
  String get memberNicknameSheetSavedAnnouncement => 'تم حفظ الاسم المستعار';

  @override
  String get memberNicknameSheetClearedAnnouncement => 'تم مسح الاسم المستعار';

  @override
  String get npubQrScanLabel => 'امسح لإضافتي';

  @override
  String get npubQrSemanticsLabel => 'رمز QR لهويتك العامة';

  @override
  String get photoHeaderRemoveTitle => 'إزالة صورة الملف الشخصي؟';

  @override
  String get photoHeaderRemoveBody =>
      'يؤدي هذا إلى إزالة صورتك من ملفك الشخصي العام. ويبقى ملف الصورة على الخادم الذي يستضيفه، وتبقى النسخ التي نزّلها آخرون بالفعل عندهم.';

  @override
  String get photoHeaderEditPhoto => 'تعديل الصورة';

  @override
  String get photoHeaderRemove => 'إزالة';

  @override
  String get photoHeaderViewPhotoSemantics => 'عرض صورة الملف الشخصي';

  @override
  String get photoHeaderAddPhotoSemantics => 'إضافة صورة ملف شخصي';

  @override
  String get photoHeaderChangePhotoSemantics => 'تغيير صورة الملف الشخصي';

  @override
  String get avatarPickerPhotoUpdated =>
      'تم تحديث الصورة. نُشرت في ملفك الشخصي العام على Nostr.';

  @override
  String get avatarPickerPhotoRemoved => 'تمت إزالة الصورة.';

  @override
  String get avatarPickerRemoveError =>
      'تعذّرت إزالة صورتك. يُرجى إعادة المحاولة.';

  @override
  String get avatarPickerUpdateError =>
      'تعذّر تحديث صورتك. يُرجى إعادة المحاولة.';

  @override
  String get avatarPickerCropTitle => 'اقتصاص الصورة';

  @override
  String get avatarPickerCropDone => 'تم';

  @override
  String get avatarPickerCropCancel => 'إلغاء';

  @override
  String get avatarFullscreenClose => 'إغلاق';

  @override
  String get avatarFullscreenSemantics => 'صورة الملف الشخصي، ملء الشاشة';

  @override
  String get avatarFullscreenLoadError => 'تعذّر تحميل الصورة';

  @override
  String get mapInitializing => 'جارٍ التهيئة...';

  @override
  String get mapInitFailedTitle => 'فشلت التهيئة';

  @override
  String get mapInitFailedMessage => 'تعذّرت تهيئة خدمات الموقع.';

  @override
  String get mapInitFailedRetry => 'فشلت التهيئة. يُرجى إعادة المحاولة.';

  @override
  String get mapLocationOffMessage =>
      'فعّل الموقع لترى نفسك ودوائرك على الخريطة.';

  @override
  String get mapGettingLocation => 'جارٍ تحديد الموقع...';

  @override
  String get mapLoadingMap => 'جارٍ تحميل الخريطة...';

  @override
  String get mapLocationOffTitle => 'الموقع مُعطّل';

  @override
  String get mapLocationErrorTitle => 'خطأ في الموقع';

  @override
  String get mapLocationUnavailable => 'الموقع غير متاح مؤقتًا';

  @override
  String get mapLocationNoPermissionTitle => 'لا يستطيع Haven استخدام موقعك';

  @override
  String get mapLocationSharingStoppedServiceOff =>
      'الموقع مُعطّل على هذا الجهاز، لذا توقّف Haven عن مشاركة موقعك مع دوائرك. فعّل الموقع لتُستأنف المشاركة.';

  @override
  String get mapLocationSharingStoppedPermission =>
      'لم يعد لدى Haven إذن باستخدام موقعك، فتوقّفت مشاركته. اسمح بالوصول إلى الموقع لتُستأنف المشاركة.';

  @override
  String get mapLocationSharingStoppedPermissionSettings =>
      'وصول تطبيق Haven إلى موقعك مُعطّل في إعدادات النظام، لذا توقّفت المشاركة. اسمح به من هناك لتُستأنف المشاركة.';

  @override
  String get mapLocationSharingStoppedBoth =>
      'توقّف Haven عن مشاركة موقعك. فعّل الموقع على هذا الجهاز، واسمح لتطبيق Haven باستخدامه.';

  @override
  String get mapLocationSharingStoppedUnknown =>
      'لم يعد Haven يتلقّى موقعك، لذا توقّفت المشاركة. تحقّق من أنّ الموقع مُفعّل وأنّ تطبيق Haven مسموح له باستخدامه.';

  @override
  String get mapLocationAccessRestoredAnnouncement =>
      'عاد الوصول إلى الموقع. يشارك Haven موقعك من جديد.';

  @override
  String get clockSkewTitle => 'ساعة هذا الهاتف غير مضبوطة';

  @override
  String get clockSkewBodyRejected =>
      'لا يصل موقعك إلى دوائرك، لأنّ المُرحِّلات ترفض وقت الإرسال الذي يسجّله هذا الهاتف. فعّل ضبط التاريخ والوقت تلقائيًا في إعدادات النظام لحلّ المشكلة.';

  @override
  String get clockSkewBodyBehind =>
      'هذا الهاتف متأخّر في التوقيت عن بقية أعضاء دوائرك، فهو يرسل تحديثات موقعك، لكن تنتهي صلاحيتها قبل أن يراها أحد. فعّل ضبط التاريخ والوقت تلقائيًا في إعدادات النظام لحلّ المشكلة.';

  @override
  String get clockSkewResolvedAnnouncement =>
      'انتهت مشكلة الساعة. يشارك Haven موقعك من جديد.';

  @override
  String get mapThisLocation => 'هذا الموقع';

  @override
  String get mapMemberFallbackName => 'عضو';

  @override
  String mapOpenInAppleMapsTitle(String label) {
    return 'فتح $label في Apple Maps؟';
  }

  @override
  String get mapOpenInAppleMapsBody =>
      'تُرسَل إحداثيات الخريطة فقط إلى Apple Maps، ولا يُرسَل أبدًا اسم أو هوية.';

  @override
  String get mapOpenInAppleMapsConfirm => 'فتح في Apple Maps';

  @override
  String get mapOpenMapsError => 'تعذّر فتح Maps';

  @override
  String get mapControlsZoomIn => 'تكبير';

  @override
  String get mapControlsZoomOut => 'تصغير';

  @override
  String get mapControlsRecenter => 'إعادة التوسيط';

  @override
  String get mapControlsRecenterFab => 'إعادة التوسيط على موقعي';

  @override
  String get mapAttributionCreditsButton => 'حقوق الخريطة والترخيص';

  @override
  String userLocationMarkerSemantics(String accuracy) {
    return 'علامة موقعك$accuracy';
  }

  @override
  String userLocationMarkerAccuracy(int meters) {
    final intl.NumberFormat metersNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String metersString = metersNumberFormat.format(meters);

    return '. الدقة: $metersString مترًا';
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
      other: 'قبل $countString دقيقة',
      many: 'قبل $countString دقيقة',
      few: 'قبل $countString دقائق',
      two: 'قبل دقيقتين',
      one: 'قبل دقيقة واحدة',
      zero: 'قبل أقل من دقيقة',
    );
    return '$_temp0';
  }

  @override
  String memberMarkerNamedSemantics(String name) {
    return 'علامة العضو $name';
  }

  @override
  String get memberMarkerGenericSemantics => 'علامة عضو';

  @override
  String memberMarkerLastSeenSemantics(String base, String age) {
    return '$base، آخر ظهور $age';
  }

  @override
  String memberMarkerOffScreenSemantics(String name, String direction) {
    return '$name خارج الشاشة نحو جهة $direction، اضغط للعرض';
  }

  @override
  String memberMarkerOffScreenGenericSemantics(String direction) {
    return 'أحد الأعضاء خارج الشاشة نحو جهة $direction، اضغط للعرض';
  }

  @override
  String get compassNorth => 'الشمال';

  @override
  String get compassNorthEast => 'الشمال الشرقي';

  @override
  String get compassEast => 'الشرق';

  @override
  String get compassSouthEast => 'الجنوب الشرقي';

  @override
  String get compassSouth => 'الجنوب';

  @override
  String get compassSouthWest => 'الجنوب الغربي';

  @override
  String get compassWest => 'الغرب';

  @override
  String get compassNorthWest => 'الشمال الغربي';

  @override
  String get commonAdd => 'إضافة';

  @override
  String get addRelaySheetTitleInbox => 'إضافة مُرحِّل صندوق وارد';

  @override
  String get addRelaySheetTitleKeyPackage => 'إضافة مُرحِّل KeyPackage';

  @override
  String get addRelaySheetTitleProfile => 'إضافة مُرحِّل ملف شخصي';

  @override
  String get addRelaySheetHint => 'wss://relay.example.com';

  @override
  String get addRelaySheetPasteTooltip => 'لصق من الحافظة';

  @override
  String get addRelaySheetErrorEmpty => 'أدخل عنوان مُرحِّل.';

  @override
  String get addRelaySheetErrorInsecureScheme =>
      'استخدم wss:// ليكون مرور البيانات إلى هذا المُرحِّل مشفّرًا.';

  @override
  String get addRelaySheetErrorHasCredentials =>
      'يجب ألّا يحتوي عنوان المُرحِّل على بيانات اعتماد.';

  @override
  String get addRelaySheetErrorInvalidFormat =>
      'أدخل عنوان مُرحِّل مثل wss://relay.example.com.';

  @override
  String get avatarSemanticsLabel => 'صورة المستخدم';

  @override
  String avatarSemanticsFor(String initials) {
    return 'لـ $initials';
  }

  @override
  String get avatarSemanticsOnline => 'متصل';

  @override
  String get avatarSemanticsOffline => 'غير متصل';
}
