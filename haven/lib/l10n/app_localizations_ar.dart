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
      'لا يملك Haven خادمًا مركزيًا. تنتقل رسائلك المشفّرة عبر شبكة لامركزية من المُرحِّلات التي يمكنك اختيارها بنفسك، فلا تقدر أي جهة منفردة على إيقافه.';

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
      'بلا خادم مركزي؛ يعمل عبر شبكة من المُرحِّلات تختارها بنفسك.';

  @override
  String get onboardingValueProp3Summary =>
      'بلا بريد أو هاتف أو تسجيل. مفتاحك السري لا يغادر هاتفك أبدًا.';

  @override
  String get onboardingCreateIdentityTitle => 'أنشئ هويتك';

  @override
  String get onboardingCreateIdentityBody =>
      'سيُنشئ Haven هوية خاصة تعيش على هذا الهاتف وحده. هي الطريقة التي تتعرّف بها دوائرك عليك.';

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
  String get relaySettingsInboxSubtitle => 'kind 10050، حيث تصلك الدعوات';

  @override
  String get relaySettingsKeyPackageTitle => 'مُرحِّلات KeyPackage الخاصة بي';

  @override
  String get relaySettingsKeyPackageSubtitle =>
      'kind 10002، حيث يكتشف المدعوون مفاتيح تشفيرك';

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
      'عند تفعيل المشاركة في الخلفية، تظل دوائرك ترى موقعك المباشر حتى عندما يكون Haven مغلقًا.';

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
      'لا يشارك Haven موقعك إلا مع الدوائر الصغيرة التي تختارها، ويُشفّره على هاتفك قبل أن يغادره. لا يوجد حساب لدى شركة ولا خادم يملكه Haven. تشرح الصفحات التالية كيف يعمل ذلك بلغة بسيطة، وتكون صريحة معك بشأن ما لا يحميه.';

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
      'ولا يشغّل Haven أي خوادم خاصة به. تمرّ تحديثات موقعك المشفّرة عبر خوادم مستقلة تُسمّى مُرحِّلات، يشغّلها أشخاص آخرون. لا يستطيع مطوّرو Haven رؤية موقعك، ولا يجمعون أي شيء عن طريقة استخدامك للتطبيق.';

  @override
  String get privacyWhatHavenIsMeansForYou =>
      'لا يوجد أحد تطلب منه بياناتك، لأنه لا أحد يحتفظ بها. والوجه الآخر لذلك أن لا أحد يستطيع استعادة حسابك أيضًا. راجع «مفتاحاك» لمعرفة ما يجب أن تنسخه احتياطيًا.';

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
      'يُحفَظ مفتاحك السري على هذا الهاتف وحده، في مخزن يحميه نظام التشغيل. ولا يُرسله Haven إلى أي مكان — لا إلى مُرحِّل، ولا إلينا.';

  @override
  String get privacyYourKeysPublicIsSafe =>
      'مفتاحك العام آمن لتوزيعه. يعمل كاسم مستخدم يمكنك نشره في أي مكان. ومشاركته لا تكشف مكانك.';

  @override
  String get privacyYourKeysMeansForYou =>
      'انسخ مفتاحك السري احتياطيًا إن أردت الاحتفاظ بهذه الهوية. يمكنك عرضه في الإعدادات ← الهوية ← متقدّم. وإن فقدت الهاتف دون نسخة احتياطية، فستضيع الهوية إلى الأبد، ولا يستطيع أحد إعادتها.';

  @override
  String get privacyYourKeysNeverShareSecret =>
      'من يحصل على مفتاحك السري يصبح هو أنت. يستطيع الانضمام إلى الدوائر بصفتك أو النشر باسمك. لا تلصقه أبدًا في تطبيق آخر، ولا في رسالة، ولا في موقع ويب.';

  @override
  String get privacyYourKeysDetailFormats =>
      'هذا الزوج مفتاح secp256k1، ويُعرَض بصيغتَي Nostr المعتادتين: المفتاح العام يبدأ بـ npub1 والمفتاح السري يبدأ بـ nsec1. يحدث التوقيع داخل التطبيق، وتُمحى بايتات المفتاح السري من الذاكرة بعد كل استخدام.';

  @override
  String get privacyYourKeysDetailSeparation =>
      'المفاتيح التي تُشفّر رسائل دوائرك منفصلة عن مفتاح الهوية هذا، ولا يحتفظ بها إلا التطبيق. هذا الفصل مقصود: فالمفتاح الذي يحمل اسمك ليس المفتاح الذي يفتح ما أرسلته.';

  @override
  String get privacyPublicProfileTitle => 'اسمك وصورتك عامّان';

  @override
  String get privacyPublicProfileSubtitle => 'مرئيان لأي شخص، لا لدوائرك فقط';

  @override
  String get privacyPublicProfileIsPublic =>
      'يُنشَر الاسم المعروض والصورة التي تضبطهما على شبكة Nostr الأوسع. يستطيع أي شخص البحث عنهما، لا الأشخاص الذين في دوائرك فقط.';

  @override
  String get privacyPublicProfileOnSave =>
      'يحدث هذا في اللحظة التي تحفظهما فيها. لا يوجد إعداد يُبقيهما خاصَّين، ولا طريقة لمشاركة اسم مع دوائرك وحدها.';

  @override
  String get privacyPublicProfilePseudonym =>
      'تبدأ التثبيتات الجديدة باسم مُختلق مثل «Quiet Wanderer»، لا يقول عنك شيئًا. يمكنك الاحتفاظ به، أو استبداله بما تشاء.';

  @override
  String get privacyPublicProfileMeansForYou =>
      'اختر اسمًا وصورة ترتاح لعرضهما علنًا. وإن كنت تفضّل ألّا يُتعرَّف عليك، فاحتفظ بالاسم المُختلق الذي أُعطي لك، وتجاوز الصورة.';

  @override
  String get privacyPublicProfileRemovalIsNotDeletion =>
      'إزالة صورتك لاحقًا لا تُلغي نشرها. يستبدل Haven ملفك الشخصي بملف فارغ، لكن ملف الصورة يبقى على الخادم الذي يستضيفه، وأي نسخة نُزِّلت منه بالفعل تبقى في أيدي من نزّلها. اعتبر كل ما تنشره دائمًا.';

  @override
  String get privacyPublicProfileDetailKindZero =>
      'الملف الشخصي هو حدث Nostr من نوع \"kind 0\" موقَّع بمفتاح هويتك. وتُرفع الصور إلى مستضيف Blossom — وهو blossom.primal.net إن لم تغيّره — فيرى الصورة ومفتاحك العام وعنوان IP الخاص بك.';

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
      'استخدام عدة مُرحِّلات يعني أنّه لا يستطيع أيٌّ منها عزلك. فإن توقّف أحدها، واصلت البقية العمل. وأنت تختار المُرحِّلات التي تستخدمها، ويمكنك تغييرها متى شئت.';

  @override
  String get privacyRelaysTwoLists =>
      'يحفظ Haven لك قائمتين. مُرحِّلات صندوق الوارد هي حيث تصلك الدعوات. ومُرحِّلات KeyPackage هي حيث يجلب الآخرون المفاتيح التي يحتاجونها لدعوتك. وتحمل كل دائرة أيضًا قائمتها الخاصة، وعبرها تنتقل تحديثات الدائرة المشفّرة.';

  @override
  String get privacyRelaysMeansForYou =>
      'ليس هنا ما قد تخطئ فيه فيضرّك: فالمُرحِّل لا يرى سوى بيانات مشفّرة. لكنك تحتاج إلى مُرحِّل واحد على الأقل يمكن الوصول إليه، وإلا لن يستطيع أحد دعوتك وستصمت دوائرك.';

  @override
  String get privacyRelaysDetailIndexers =>
      'بمعزل عن قوائمك الخاصة، يستعلم Haven من مجموعة صغيرة من مُرحِّلات الدليل العامة ليبحث عن ملفات الآخرين الشخصية ومفاتيحهم. ويتصل بها حتى إن لم تضبط لنفسك سوى مُرحِّلات خاصة. وهي ترى عنوان الشبكة الذي تتصل منه والحسابات التي سألت عنها.';

  @override
  String get privacyRelaysDetailKeyListIsPublic =>
      'قائمة مُرحِّلات KeyPackage تُنشَر هي نفسها على الشبكة، موقَّعة بمفتاح هويتك، ليتمكّن الآخرون من إيجادها. فإن أضفت مُرحِّلًا خاصًا إلى تلك القائمة، صار عنوانه عامًا ومرتبطًا بك. أما المُرحِّل المستخدَم داخل قائمة دائرة واحدة فقط، فلا يُعلَن عنه بهذه الطريقة.';

  @override
  String get privacyEncryptionTitle => 'كيف يعمل التشفير';

  @override
  String get privacyEncryptionSubtitle =>
      'مفاتيح لكل دائرة، وما يتغيّر عند انضمام الناس أو خروجهم';

  @override
  String get privacyEncryptionPerCircle =>
      'يُشفَّر موقعك على هاتفك قبل أن يغادره، بمعيار مفتوح اسمه MLS. وكل دائرة هي مجموعتها المشفّرة الخاصة بمفاتيحها الخاصة. ولا يستطيع أحد من خارج الدائرة قراءة ما يُرسَل داخلها — لا مُرحِّل، ولا Haven نفسه، ولا دائرة أخرى أنت فيها.';

  @override
  String get privacyEncryptionWhenSomeoneJoins =>
      'عندما ينضمّ شخص، تنتقل الدائرة إلى مفتاح جديد. يستطيع قراءة ما يُرسَل بعد وصوله، ولا شيء مما سبقه. ولا يُرسِل Haven إلى العضو الجديد أي مواقع سابقة أبدًا.';

  @override
  String get privacyEncryptionWhenSomeoneLeaves =>
      'عندما يخرج شخص أو يُزال، تنتقل الدائرة إلى مفتاح جديد آخر. وفي غضون دقائق قليلة على الأكثر، لا يعود قادرًا على قراءة أي شيء جديد.';

  @override
  String get privacyEncryptionKeysChangeOnMembership =>
      'تتغيّر المفاتيح عند تغيّر العضوية — لا وفق مؤقّت. وفي ما بين تلك التغييرات، يغطّي مفتاح واحد كل ما يُرسَل. لذا فمن تُزيله من دائرة مستقرّة منذ زمن طويل يبقى قادرًا على فتح أي رسائل حفظها وهو عضو، حتى رسائل من أسابيع مضت. لكنه لا يستطيع فتح أي شيء أُرسِل بعد خروجه.';

  @override
  String get privacyEncryptionMeansForYou =>
      'يحميك التشفير من كل من هم خارج دوائرك. ولا يستطيع حمايتك من شخص كان يومًا داخل إحداها. فإن أردت قطيعة تامة مع شخص، فإنشاء دائرة جديدة أكثر أمانًا من إزالته من دائرة قديمة.';

  @override
  String get privacyEncryptionDetailMls =>
      'إن معيار MLS (Messaging Layer Security) هو المعيار نفسه الصادر عن IETF والمستخدَم في تطبيقات مراسلة آمنة أخرى. ويصل Haven إلى شبكة Nostr من خلال بروتوكول Marmot الذي يحدّد كيف تنتقل مجموعات MLS عبر المُرحِّلات. ومفتاح هويتك العام في شبكة Nostr منفصل عن المفتاح الذي تُوقِّع به كل دائرة.';

  @override
  String get privacyEncryptionDetailEpochs =>
      'تُسمّى كل فترة يعمل فيها مفتاح واحد «حقبة». ولا يحتفظ جهازك إلا بما يكفي لفكّ تشفير الرسائل التي لا تزال في الطريق من الحقبات القليلة الأخيرة، ثم يتخلّص منه — ولهذا لا يستطيع Haven استعادة رسائلك الأقدم لك، ولا حتى من حيث المبدأ.';

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
      'ما دام Haven مفتوحًا وأنت في دائرة، يُرسَل موقعك من تلقاء نفسه كل دقيقتين تقريبًا. لا يوجد زرّ إيقاف مؤقّت. والإعداد الوحيد الذي تتحكّم به هو ما إذا كانت المشاركة تستمرّ بعد خروجك من التطبيق.';

  @override
  String get privacyWhatOthersSeeMembersLearnKey =>
      'الانضمام إلى دائرة يُظهر أيضًا مفتاحك العام لكل عضو فيها. وعبره يستطيعون البحث عن ملفك الشخصي العام، وعن كل ما نشرته يومًا تحت ذلك المفتاح.';

  @override
  String get privacyWhatOthersSeeCoMemberIp =>
      'تُجلَب صورة ملف العضو الشخصي من خادم يختاره هو. وتحميلها يكشف عنوان شبكتك — وبالتالي مكانك التقريبي في العالم — لمن يشغّل ذلك الخادم. يحدث هذا من تلقاء نفسه، دون أن تضغط على أي شيء.';

  @override
  String get privacyWhatOthersSeeRelaysHeading => 'مشغّلو المُرحِّلات';

  @override
  String get privacyWhatOthersSeeRelaysCannot =>
      'لا يستطيع مشغّلو المُرحِّلات قراءة موقعك، ولا رسائلك، ولا اسم دائرتك، ولا قائمة أعضائها. وتصلهم كل رسالة من عنوان إرسال جديد لمرة واحدة، فلا يستطيعون معرفة أي عضو أرسلها.';

  @override
  String get privacyWhatOthersSeeRelaysCan =>
      'لكنهم يرون عنوان الشبكة الذي تتصل منه، ومتى تكون متصلًا، وحجم حركة بياناتك وتكرارها. وتحمل كل دائرة وسمًا عشوائيًا، فيستطيع المُرحِّل جمع رسائل الدائرة الواحدة معًا وتقدير عدد من فيها — دون أن يعرف هوية أي منهم.';

  @override
  String get privacyWhatOthersSeeMeansForYou =>
      'اعتبر الدائرة أشخاصًا تعطيهم عنوان منزلك. في مواجهة المُرحِّلات ومن هم في الخارج يصمد التشفير، ويسدّ VPN ثغرة عنوان الشبكة. أما في مواجهة عضو يحفظ لقطة شاشة، فلا شيء يصمد.';

  @override
  String get privacyWhatOthersSeeDetailTag =>
      'يبقى وسم الدائرة كما هو مدى عمر تلك الدائرة، فيستطيع المُرحِّل ربط كل رسائلها معًا إلى أجل غير مسمّى. وهذه خاصية في البروتوكول الأساسي نفسه، وليست شيئًا يستطيع Haven تغييره.';

  @override
  String get commonLearnMore => 'اعرف المزيد';

  @override
  String get relaySettingsBackendCaption =>
      'لا يملك Haven خادمًا خاصًا به. تمرّ تحديثاتك المشفّرة عبر خوادم مستقلة تُسمّى مُرحِّلات، وهي لا ترى أبدًا موقعك ولا مَن في دوائرك.';

  @override
  String get privacyWhatOthersSeeScreenshots =>
      'لقطات الشاشة مسألة تعتمد على نظام التشغيل، والنظامان يختلفان. على Android يمنع Haven لقطات الشاشة وتسجيل الشاشة في كل شاشات التطبيق. أما على iPhone فلا يستطيع ذلك: يجعل Haven معاينة مبدّل التطبيقات ضبابية، لكن يستطيع أي عضو أن يأخذ لقطة لما يظهر على الشاشة.';

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
      'يُخفي التشفير ما تُرسله. لكنه لا يستطيع أن يخفي أنك أرسلت شيئًا. أما النمط المحيط بالرسالة — متى خرجت، وما حجمها، وبأي خوادم كنت متصلًا — فيُسمّى البيانات الوصفية، ويبقى مرئيًا حتى عندما لا يكون المحتوى كذلك.';

  @override
  String get privacyInferenceActivityPattern =>
      'ومن هذا النمط، يستطيع مُرحِّل تستخدمه أن يعرف تقريبًا متى تكون نشطًا وكم مرة. ويُرسل Haven أيضًا تحديثًا إضافيًا كلما تحرّكت أكثر من مئة متر تقريبًا. لذا قد يُلمِّح سجل طويل بما يكفي إلى ما إذا كنت متنقّلًا أم ثابتًا في مكانك — دون أن يكشف المكان أبدًا.';

  @override
  String get privacyInferencePresence =>
      'وما دام Haven يعمل، فهو يُبقي اتصالًا مفتوحًا بمُرحِّلاتك، فتستطيع هي أيضًا أن ترى أنك متصل، وأي الدوائر تُتابع. وهذا هو ثمن وصول التحديثات في ثوانٍ بدلًا من دقائق.';

  @override
  String get privacyInferenceIpHeading => 'عنوان شبكتك';

  @override
  String get privacyInferenceIpAddress =>
      'كل خادم يتحدّث إليه Haven يرى عنوان الشبكة الذي يتصل منه هاتفك: مُرحِّلاتك، ومزوّد الخرائط، ومن يستضيف صورة الملف الشخصي لأي عضو. ويرى مزوّد الإنترنت أي هذه الخوادم وصلت إليه ومتى. ولا يفعل Haven من تلقاء نفسه أي شيء لإخفاء أيٍّ من هذين الأمرين.';

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
      'إن كان ما يقلقك أن تضعك جهةٌ تُشغّل شبكةً أو خادمًا على خريطة، لا أن يفعل ذلك شخص، فشبكة VPN هي أنفع شيء واحد يمكنك إضافته. وإن كان ما يقلقك هو الأشخاص الذين في دوائرك، فهي لن تساعدك على الإطلاق.';

  @override
  String get privacyInferenceDetailJitter =>
      'يُغيّر Haven الفاصل الزمني بين التحديثات عن قصد، فلا يُظهر تسجيل قصير أي إيقاع منتظم. لكن عند حساب المتوسّط على مدى ساعات طويلة، يبقى تقدير الوتيرة الأساسية ممكنًا. ولا يُضاف حشو إلى أحجام الرسائل أيضًا، وتقع تحديثات الموقع في نطاق حجم ضيّق، وهذا ما يجعل التعرّف عليها بوصفها تحديثات موقع ممكنًا.';

  @override
  String get privacyInferenceDetailOutOfScope =>
      'بعض الأمور تقع بكل بساطة خارج ما يستطيع Haven معالجته. فمراقبٌ يستطيع أن يرصد مُرحِّلات كثيرة في الوقت نفسه، أو هاتفك أنت بعد أن يسيطر عليه شخص آخر، أمران يتجاوزان ما يمكن أن يُصلحه أي قرار تصميمي هنا.';

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
  String get createCircleNoAccountFound => 'لم يُعثَر على حساب Haven';

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
      'يستطيع كل فرد في هذه الدائرة رؤية موقع الآخرين واسمهم المعروض. اسمك المعروض هو الذي ضبطته في الإعدادات ← الهوية. تبقى هذه الدائرة منفصلة عن أي دوائر أخرى أنت فيها، فلا يستطيع أعضاؤها رؤية دوائرك الأخرى أو من فيها.';

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
      'يستطيع الأعضاء الجدد رؤية مواقع هذه الدائرة المشفّرة بمجرّد قبولهم الدعوة.';

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
  String get pendingMemberRemoveTooltip => 'إزالة العضو';

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
  String get circleDetailsRelaysHeading => 'مُرحِّلات هذه الدائرة';

  @override
  String get circleDetailsNoRelays => '(لا شيء مسجّل)';

  @override
  String get circleDetailsRelaysNote =>
      'اختيرت هذه المُرحِّلات عند إنشاء هذه الدائرة وليست قابلة للتعديل من المستخدم بعد. مستقلّة عن إعدادات المُرحِّلات الشخصية الخاصة بك.';

  @override
  String get circleDetailsAddMember => 'إضافة عضو';

  @override
  String get circleDetailsLeaveCircle => 'مغادرة الدائرة';

  @override
  String get leaveCircleDialogTitle => 'مغادرة الدائرة';

  @override
  String get leaveCircleDialogBody =>
      'هل أنت متأكد أنك تريد مغادرة هذه الدائرة؟ لن تتلقّى بعد الآن تحديثات الموقع من أعضائها. لا يمكن التراجع عن هذا الإجراء.';

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
      'جرى تحديث محرك التشفير في Haven، فلم يعد بالإمكان استخدام هذه الدائرة. أعد إنشاءها لمواصلة مشاركة الموقع مع الأشخاص أنفسهم — ستحتاج إلى دعوتهم مجددًا.';

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
      'هويتك وملفك الشخصي العام لم يتغيّرا — ولا يلزمك فعل أي شيء بشأنهما.';

  @override
  String get legacyCutoverExplainerCirclesNeedRecreation =>
      'لتحسين الأمان، يجب إعادة إنشاء دوائرك ودعوة أعضائها مجددًا قبل أن تتمكّن من مشاركة الموقع فيها من جديد.';

  @override
  String get legacyCutoverExplainerAcknowledge => 'فهمت';

  @override
  String get relaySettingsLegacyRetractionPending =>
      'لا يزال Haven ينظّف بعض البيانات المتبقّية من التحديث الأمني الأخير. سيكتمل ذلك تلقائيًا فور عودتك إلى الاتصال بالإنترنت.';

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
      'سيؤدي هذا إلى حذف هويتك نهائيًا. تأكّد من أنك نسخت مفتاحك السري احتياطيًا إن كنت تريد استعادتها.';

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
      'يعمل مفتاحك العام كاسم مستخدم آمن للمشاركة. يمسح الناس هذا الرمز، أو يلصقون مفتاحك العام، لدعوتك إلى دائرة. ومشاركته لا يمكن أن تكشف موقعك، الذي لا يظهر إلا لأعضاء الدوائر التي انضممت إليها. أما اسمك المعروض وصورتك فهما علنيان بالفعل، لذا لا تكشف مشاركة هذا الرمز عنهما أي شيء إضافي.';

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
      'يؤدي هذا إلى إزالة صورتك من ملفك الشخصي العام.';

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
      'تم تحديث الصورة — نُشرت في ملفك الشخصي العام على Nostr.';

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
  String memberMarkerHoursAgoSemantics(int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'قبل $countString ساعة',
      many: 'قبل $countString ساعة',
      few: 'قبل $countString ساعات',
      two: 'قبل ساعتين',
      one: 'قبل ساعة واحدة',
      zero: 'قبل أقل من ساعة',
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
      other: 'قبل $countString يوم',
      many: 'قبل $countString يومًا',
      few: 'قبل $countString أيام',
      two: 'قبل يومين',
      one: 'قبل يوم واحد',
      zero: 'قبل أقل من يوم',
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
