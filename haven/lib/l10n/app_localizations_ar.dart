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
  String get onboardingValueProp2Title => 'لا يستطيع أحد إيقافه';

  @override
  String get onboardingValueProp3Title => 'لا حاجة إلى حساب';

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
  String get settingsRelaysTitle => 'المُرحِّلات';

  @override
  String get settingsLocationTitle => 'الموقع';

  @override
  String get settingsLocationSubtitleOn => 'المشاركة في الخلفية مفعّلة';

  @override
  String get settingsLocationSubtitleOff => 'فقط ما دام Haven مفتوحًا';

  @override
  String get settingsMapStyleTitle => 'نمط الخريطة';

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
  String get locationSettingsBatteryOptNote =>
      'لا يزال تحسين البطارية مُفعّلًا لتطبيق Haven. وبعض الهواتف تستخدمه لإيقاف المشاركة في الخلفية دون سابق إنذار. استثنِ Haven منه للحفاظ على موثوقية المشاركة.';

  @override
  String get locationSettingsErrorSnack => 'حدث خطأ ما';

  @override
  String get locationSettingsIntro =>
      'يشارك Haven موقعك مع دوائرك كلما كان التطبيق مفتوحًا. وإن فعّلت هذا الخيار، ظلّت دوائرك ترى موقعك بينما يعمل Haven في الخلفية. وإذا أغلق النظام Haven، توقّفت مشاركتك أنت: قد يستيقظ Haven لجلب مواقع دوائرك، لكنه لا يستيقظ أبدًا لإرسال موقعك. وعلى Android، تستمر المشاركة حتى بعد إزاحة Haven من مبدّل التطبيقات، وتعود من تلقاء نفسها بعد إعادة تشغيل الجهاز. أما على iPhone فتبقى المشاركة متوقفة إلى أن تفتح Haven.';

  @override
  String get locationSettingsToggleTitle => 'المشاركة في الخلفية';

  @override
  String get locationSettingsToggleSubtitle =>
      'استمرار المشاركة ما دام Haven يعمل في الخلفية';

  @override
  String get locationSettingsIosLimitedNote =>
      'تظل المشاركة تعمل في الخلفية بإذنك الحالي، ويعرض iOS خلال ذلك شريط الموقع الأزرق في أعلى الشاشة. اختر «دائمًا» لتطبيق Haven في الإعدادات ليتمكّن أيضًا من تدارك ما فاته من مواقع دوائرك بعد أن يُغلق iOS التطبيق. ومع «دائمًا»، قد يعرض iOS سهم الموقع في شريط الحالة بدلًا من ذلك الشريط. أما مشاركة موقعك أنت فتُستأنف عندما تفتح Haven من جديد.';

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
      'ما دامت المشاركة في الخلفية مفعّلة، يحتفظ Haven بجلسة موقع كي تظل دوائرك تراك.';

  @override
  String get locationSettingsIosIndicatorArrow =>
      'يعرض iOS سهم الموقع الخاص به في شريط الحالة أثناء استخدام Haven لموقعك، ويُبقي السهم نفسه بجوار Haven في «خدمات الموقع» مدةً بعد ذلك.';

  @override
  String get locationSettingsIosIndicatorBar =>
      'بإذن «دائمًا» الذي منحته، يعرض iOS شريط الموقع الأزرق الخاص به في أعلى الشاشة أثناء استخدام Haven لموقعك.';

  @override
  String get locationDisclosureTitle => 'مشاركة موقعك';

  @override
  String get locationDisclosureWhy =>
      'يعرض Haven موقعك المباشر لأفراد الدوائر التي تختارها، ويعرض لك مواقعهم على الخريطة. ولهذا يحتاج Haven إلى إذن لاستخدام الموقع الدقيق لجهازك.';

  @override
  String get locationDisclosureHow =>
      'موقعك مشفَّر تشفيرًا تامًّا بين الطرفين على جهازك، فلا يستطيع قراءته سوى أعضاء الدوائر التي تختارها، لا Haven. ولا يشغّل Haven خوادم خاصة به: تمر تحديثاتك المشفَّرة عبر مُرحِّلات مستقلة يديرها أشخاص آخرون، وهي ترى عنوانك على الشبكة لكنها لا ترى أبدًا أين أنت. ولرسم الخريطة يطلب Haven من Stadia Maps المناطق المحيطة بك وبدائرتك، فتعرف Stadia Maps تقريبًا أين تقع تلك المناطق، لكنها لا تعرف اسمك ولا مفتاحك ولا مَن في دوائرك. وتقول Stadia Maps إنها لا تبيع المعلومات الشخصية ولا تتاجر بها، ولا تضع أي ملفات تعريف ارتباط على جهازك، وتحتفظ بسجلات خوادمها نحو أسبوعين — وهذه سياستها هي، ولا يستطيع Haven فرضها.';

  @override
  String get locationDisclosureSharing =>
      'ما دام Haven مفتوحًا وأنت في دائرة، يُرسَل موقعك تلقائيًا كل بضع دقائق. ولا يوجد إيقاف مؤقت. وللتوقف عن المشاركة مع دائرة، غادرها.';

  @override
  String get locationDisclosureBackgroundAndroid =>
      'يستخدم هذا التطبيق بيانات الموقع لتمكين المشاركة مع دوائرك حتى عندما يكون التطبيق مغلقًا أو غير قيد الاستخدام.';

  @override
  String get locationDisclosureBackgroundIos =>
      'يستخدم هذا التطبيق بيانات الموقع لتمكين المشاركة مع دوائرك حتى عندما يعمل Haven في الخلفية ولا تستخدمه أنت. وإذا أغلق iOS تطبيق Haven، توقّفت مشاركتك إلى أن تفتحه من جديد: قد يستيقظ Haven لجلب مواقع دوائرك، لكنه لا يستيقظ أبدًا لإرسال موقعك.';

  @override
  String get locationDisclosureManage =>
      'يمكنك إيقاف المشاركة في الخلفية في أي وقت من الإعدادات ← الموقع.';

  @override
  String get locationDisclosureAgree => 'أوافق';

  @override
  String get locationDisclosureNotNow => 'ليس الآن';

  @override
  String get fgsNotificationSharing => 'يُرسل Haven معلومات الموقع ويستقبلها';

  @override
  String get fgsNotificationPaused =>
      'تطبيق Haven متوقّف مؤقتًا — افتحه لاستئناف المشاركة';

  @override
  String get fgsNotificationOpen => 'تطبيق Haven مفتوح';

  @override
  String get fgsChannelName => 'مشاركة الموقع';

  @override
  String get fgsChannelDescription =>
      'يتيح هذا الإشعار لتطبيق Haven أن يواصل مشاركة موقعك المشفّر في الخلفية.';

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
  String get aboutFooterLicense => 'مُرخَّص بموجب MIT License';

  @override
  String aboutFooterVersion(String version) {
    return 'الإصدار $version';
  }

  @override
  String get relaySettingsBackendCaption =>
      'لا يملك Haven خادمًا خاصًا به. تمرّ تحديثاتك المشفّرة عبر خوادم مستقلة تُسمّى مُرحِّلات، وهي لا تستطيع قراءة موقعك ولا رسائلك.';

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
  String get circlesEmptyTitle => 'لا توجد دوائر بعدُ';

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
  String nameCircleCreatedPartialSnack(String name, int sent, int total) {
    final intl.NumberFormat sentNumberFormat = intl.NumberFormat.decimalPattern(
      localeName,
    );
    final String sentString = sentNumberFormat.format(sent);
    final intl.NumberFormat totalNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String totalString = totalNumberFormat.format(total);

    return 'تم إنشاء الدائرة \"$name\". أُرسلت الدعوات ($sentString من $totalString)؛ التسليم معلّق للبقية.';
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
  String nameCircleRosterFullError(int limit) {
    final intl.NumberFormat limitNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String limitString = limitNumberFormat.format(limit);

    return 'الحدّ الأقصى لعدد دوائرك في وقت واحد هو $limitString. ويجب مغادرة إحدى دوائرك لإفساح المجال لدائرة جديدة.';
  }

  @override
  String addMemberTitle(String circleName) {
    return 'إضافة إلى $circleName';
  }

  @override
  String get addMemberInfo =>
      'بمجرّد قبولهم، سيرون مواقع الجميع من تلك اللحظة فصاعدًا، ولن يروا أبدًا أي شيء أُرسِل قبل انضمامهم. وسيرون أيضًا المفاتيح العامة لكل من هم في هذه الدائرة بالفعل.';

  @override
  String get addMemberAlreadyInCircle => 'العضو موجود في هذه الدائرة بالفعل';

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
  String get circleMemberNoRecentLocation => 'لا موقع حديث';

  @override
  String get circleMemberRemoveTooltip => 'إزالة من الدائرة';

  @override
  String circleMemberRemoveDialogTitle(String name) {
    return 'إزالة $name؟';
  }

  @override
  String get circleMemberRemoveDialogBody =>
      'لا يعود هذا الشخص قادرًا على قراءة أي شيء جديد في هذه الدائرة بمجرّد أن يلحق بقية أعضاء الدائرة بهذا التغيير، وهو ما يحدث عادةً في غضون دقائق قليلة، ويطول أكثر مع من كان غير متصل بالإنترنت حينها. ويبقى ما وصله من قبل على هاتفه. وللتراجع عن هذا، ستحتاج إلى دعوته من جديد.';

  @override
  String get circleMemberRemoveConfirm => 'إزالة';

  @override
  String circleMemberRemoveInProgress(String name) {
    return 'جارٍ إزالة $name…';
  }

  @override
  String circleMemberRemoveSuccess(String name) {
    return 'تمت إزالة $name من الدائرة';
  }

  @override
  String circleMemberRemoveError(String name) {
    return 'تعذّرت إزالة $name. لم يتغيّر شيء — تحقّق من اتصالك وحاول مرة أخرى.';
  }

  @override
  String get circleMemberAdmin => 'مشرف';

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
  String get memberPickerSectionRoster => 'أعضاء دوائرك';

  @override
  String get memberPickerTierRoster => 'مِن أعضاء دوائرك';

  @override
  String get memberPickerNoMatches => 'لا نتائج مطابقة في دوائرك';

  @override
  String get memberPickerLoading => 'جارٍ تجهيز قائمة الأشخاص في دوائرك';

  @override
  String get memberPickerDirectoryUnavailable =>
      'تعذّر الآن تحميل قائمة الأشخاص في دوائرك';

  @override
  String memberPickerMatchesAnnouncement(int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    return 'النتائج المطابقة: $countString';
  }

  @override
  String get memberPickerReasonSelf => 'هذا معرّفك أنت';

  @override
  String get memberPickerReadPublicKey => 'نطق المفتاح العام';

  @override
  String get memberPickerSectionRecent => 'أشخاص كانوا في دوائرك مؤخّرًا';

  @override
  String get memberPickerTierRecent => 'مِن الذين كانوا في دوائرك مؤخّرًا';

  @override
  String get memberPickerNicknameNote =>
      'اسمك المستعار لهذا الشخص، لا اسمه العلني';

  @override
  String memberPickerCollisionCircleLabel(String circleName) {
    return 'الدائرة: $circleName';
  }

  @override
  String get memberPickerStrangerLookupNote =>
      'طلب Haven من مُرحِّل أن يبحث عن الاسم العلني لهذا الشخص. ويرى ذلك المُرحِّل أن هذا الجهاز سأل للتو عن هذا المفتاح. لكن هذا الطلب لا يحمل أي توقيع، فهو غير مرتبط بهويتك في Haven. ولم تُنزَّل أي صورة حتى الآن.';

  @override
  String selectedMembersMore(int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    return '+$countString آخرون';
  }

  @override
  String get invitationCardHeading => 'دعوة إلى دائرة';

  @override
  String invitationCardSemantics(String inviter) {
    return 'دعوة للانضمام إلى دائرة، أرسلها $inviter';
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
  String get invitationCardNicknameNote =>
      'اسمك المستعار لهذا الشخص، لا اسمه العلني';

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
  String invitationRosterFullError(int limit) {
    final intl.NumberFormat limitNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String limitString = limitNumberFormat.format(limit);

    return 'الحدّ الأقصى لعدد دوائرك في وقت واحد هو $limitString. وتبقى هذه الدعوة في انتظارك، فيمكنك قبولها بعد مغادرة إحدى دوائرك.';
  }

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
  String circleDetailsMetaWithExpiry(String meta, String expiry) {
    return '$meta · انتهاء $expiry';
  }

  @override
  String circleDetailsExpiryMinutesShort(int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$countString دقيقة',
      many: '$countString دقيقة',
      few: '$countString دقائق',
      two: 'دقيقتين',
      one: 'دقيقة واحدة',
      zero: '$countString دقيقة',
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
      other: '$countString ثانية',
      many: '$countString ثانية',
      few: '$countString ثوانٍ',
      two: 'ثانيتين',
      one: 'ثانية واحدة',
      zero: '$countString ثانية',
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
      other: 'نحو $countString دقيقة',
      many: 'نحو $countString دقيقة',
      few: 'نحو $countString دقائق',
      two: 'نحو دقيقتين',
      one: 'نحو دقيقة واحدة',
      zero: 'نحو $countString دقيقة',
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
      other: '$countString ثانية',
      many: '$countString ثانية',
      few: '$countString ثوانٍ',
      two: 'ثانيتين',
      one: 'ثانية واحدة',
      zero: '$countString ثانية',
    );
    return '$_temp0';
  }

  @override
  String circleDetailsExpirySemantics(String meta, String expiry) {
    return '$meta. يطلب Haven من المُرحِّلات أن تُسقِط بعد $expiry تحديثات الموقع التي ترسلها أنت إلى هذه الدائرة.';
  }

  @override
  String get circleDetailsRelaysHeading => 'مُرحِّلات هذه الدائرة';

  @override
  String get circleDetailsNoRelays => '(لا شيء مسجّل)';

  @override
  String get circleDetailsRelaysNote =>
      'جاءت هذه المُرحِّلات من قوائم نشرها الأعضاء المدعوّون، وإن لم ينشروا قوائم فمن مُرحِّلات صندوق الوارد لديك أو مُرحِّلات اختارها Haven. ولا يمكن تغييرها بعد، والتعديلات اللاحقة على قائمة مُرحِّلاتك لا تؤثّر فيها.';

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
      'يحذف هذا هويتك وكل بيانات دوائرك من هذا الهاتف. أما ما نُشِر تحتها بالفعل فيبقى مكانه: اسمك ومفاتيحك على المُرحِّلات التي لديها نسخة منها، وصورتك على مستضيف الصور الذي يخزّنها. وتأكّد من أنك نسخت مفتاحك السري احتياطيًا إن أردت استعادة هويتك.';

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
  String get profileSyncStatusSyncing => 'جارٍ مزامنة ملفك الشخصي العام…';

  @override
  String get profileSyncStatusPartial =>
      'منشور — لا تزال المزامنة جارية مع بعض المُرحِّلات';

  @override
  String get profileSyncStatusSynced => 'ملفك الشخصي العام مُحدَّث';

  @override
  String get profileSyncStatusFailed => 'تعذّرت المزامنة حتى الآن.';

  @override
  String get profileSyncStatusRetrySemantics => 'إعادة محاولة نشر ملفك الشخصي';

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
      'تم تحديث الصورة. ستُنشَر في ملفك الشخصي العام على Nostr.';

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
  String get clockSkewTitleDisagreement => 'ساعة في إحدى دوائرك غير مضبوطة';

  @override
  String get clockSkewBodyDisagreement =>
      'تختلف ساعة هذا الهاتف عن ساعة عضو آخر بدقيقتين أو أكثر. وإن كان الخلل في ساعة هذا الهاتف، فقد تنتهي صلاحية تحديثات موقعك قبل أن يراها أحد. فعّل ضبط التاريخ والوقت تلقائيًا في إعدادات النظام لتستبعد أن يكون الخلل في هذا الهاتف.';

  @override
  String get clockSkewDisagreementResolvedAnnouncement => 'انتهى تحذير الساعة.';

  @override
  String get sharingHealthTitleStopped => 'توقّفت مشاركة الموقع';

  @override
  String get sharingHealthTitleNotSending => 'لا تتم مشاركة موقعك';

  @override
  String get sharingHealthTitleNotReceiving => 'لا تصلك مواقع الأعضاء';

  @override
  String sharingHealthNoUpdatesMinutes(int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'لا تحديثات منذ نحو $countString دقيقة',
      many: 'لا تحديثات منذ نحو $countString دقيقة',
      few: 'لا تحديثات منذ نحو $countString دقائق',
      two: 'لا تحديثات منذ نحو دقيقتين',
      one: 'لا تحديثات منذ نحو دقيقة واحدة',
      zero: 'لا تحديثات منذ أقل من دقيقة',
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
      other: 'لا تحديثات منذ نحو $countString ساعة',
      many: 'لا تحديثات منذ نحو $countString ساعة',
      few: 'لا تحديثات منذ نحو $countString ساعات',
      two: 'لا تحديثات منذ نحو ساعتين',
      one: 'لا تحديثات منذ نحو ساعة واحدة',
      zero: 'لا تحديثات منذ أقل من ساعة',
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
      other: 'لا تحديثات منذ نحو $countString يوم',
      many: 'لا تحديثات منذ نحو $countString يومًا',
      few: 'لا تحديثات منذ نحو $countString أيام',
      two: 'لا تحديثات منذ نحو يومين',
      one: 'لا تحديثات منذ نحو يوم واحد',
      zero: 'لا تحديثات منذ أقل من يوم',
    );
    return '$_temp0';
  }

  @override
  String get sharingHealthRepairAction => 'إصلاح';

  @override
  String get sharingHealthRepairUnavailableHint =>
      'الإصلاح غير متاح لهذه الدائرة';

  @override
  String get sharingHealthRepairHint =>
      'يعيد الاتصال بالمُرحِّلات، ويعيد محاولة إرسال موقعك، وقد يمنح الدائرة مفتاحًا جديدًا إن كنت مشرفها';

  @override
  String get sharingHealthRepairSent =>
      'تم إرسال الإصلاح. وسيلحق الآخرون بهذا التغيير بمجرّد أن تستقبله هواتفهم.';

  @override
  String get sharingHealthRepairNotOwner =>
      'لا يستطيع إصلاح هذه الدائرة إلا مشرفها. اطلب من المشرف إزالتك ثم إضافتك من جديد.';

  @override
  String get sharingHealthRepairNeedsNewCircle =>
      'لا يمكن إصلاح هذه الدائرة على هذا الهاتف. أنشئ دائرةً جديدةً مع الأشخاص أنفسهم.';

  @override
  String get sharingHealthRepairNothingToDo =>
      'لا شيء يحتاج إلى إصلاح الآن. وسيواصل Haven المحاولة.';

  @override
  String get sharingHealthRepairUnresolvedAnnouncement =>
      'ما زالت مشاركة الموقع لا تعمل.';

  @override
  String get sharingHealthResumedAnnouncement => 'تعمل مشاركة الموقع من جديد.';

  @override
  String circleMemberLastSeenMinutes(int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'آخر ظهور قبل $countString دقيقة',
      many: 'آخر ظهور قبل $countString دقيقة',
      few: 'آخر ظهور قبل $countString دقائق',
      two: 'آخر ظهور قبل دقيقتين',
      one: 'آخر ظهور قبل دقيقة واحدة',
      zero: 'آخر ظهور قبل أقل من دقيقة',
    );
    return '$_temp0';
  }

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
