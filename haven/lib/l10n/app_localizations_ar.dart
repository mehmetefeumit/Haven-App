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
      'لا بريد إلكتروني، ولا رقم هاتف، ولا تسجيل. يُنشئ Haven هوية خاصة تعيش على هاتفك وحده، دون أي شيء يربطها بشخصك الحقيقي.';

  @override
  String get onboardingValueProp1Summary =>
      'مُشفَّر على جهازك، فلا يستطيع قراءته سوى الدوائر التي تختارها.';

  @override
  String get onboardingValueProp2Summary =>
      'بلا خادم مركزي؛ يعمل عبر شبكة من المُرحِّلات تختارها بنفسك.';

  @override
  String get onboardingValueProp3Summary =>
      'بلا بريد أو هاتف أو تسجيل، ولا شيء يربطه بك.';

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
      'kind 10051، حيث يكتشف المدعوون مفاتيح تشفيرك';

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
  String get relaySettingsExplainerSemantics => 'كيف تعمل مُرحِّلات Haven';

  @override
  String get relaySettingsExplainerHeading => 'كيف يعمل هذا';

  @override
  String get relaySettingsExplainerNostr =>
      'لا يملك Haven خادمًا مركزيًا. يعمل على تقنيتين مفتوحتين. Nostr شبكة من الخوادم المستقلة تُسمّى المُرحِّلات يمكن لأي شخص تشغيلها؛ تستقبل رسائلك وتحتفظ بها لفترة وجيزة ثم تمرّرها عندما يطلبها جهات اتصالك. لا غنى عن أي مُرحِّل بعينه، فإن توقّف أحدها واصلت البقية العمل، وكل ما قد يُجبَر مُرحِّل على تسليمه ليس سوى بيانات مشفّرة.';

  @override
  String get relaySettingsExplainerMarmot =>
      'يُشفِّر بروتوكول Marmot رسائلك على جهازك قبل أن تغادره، مستخدمًا معيار MLS (Messaging Layer Security). كل دائرة هي مجموعتها المشفّرة الخاصة بمفاتيحها الخاصة، فلا يمكن ربط الدوائر المنفصلة ببعضها. وتظل تلك المفاتيح تتقدّم مع الوقت، وهي خاصية تُسمّى السرّية الأمامية، فحتى المفتاح الذي يُكشَف لاحقًا لا يستطيع فتح رسائلك السابقة.';

  @override
  String get relaySettingsExplainerMetadata =>
      'لذلك، لا يرى المُرحِّل أبدًا موقعك، ولا رسائلك، ولا من في دوائرك، ولا هويتك على تلك الرسائل. تُنشَر كل رسالة من عنوان إرسال جديد لمرة واحدة، فلا شيء في الرسالة يربطها بحسابك. ومع ذلك، لا يزال المُرحِّل يرى بعض البيانات الوصفية: وسمًا عشوائيًا لكل دائرة، وتوقيت حركة بياناتك وحجمها، وعنوان الشبكة الذي تتصل منه.';

  @override
  String get relaySettingsExplainerInboxTerm => 'مُرحِّلات صندوق الوارد';

  @override
  String get relaySettingsExplainerInboxBody =>
      ' هي صندوق بريدك: حيث تُسلَّم إليك الدعوات للانضمام إلى دائرة، وهي بدورها مشفّرة، لتستلمها. لكي يدعوك أحدهم، يجب أن يكون قادرًا على الوصول إلى أحد هذه المُرحِّلات.';

  @override
  String get relaySettingsExplainerKeyPackageTerm => 'مُرحِّلات KeyPackage';

  @override
  String get relaySettingsExplainerKeyPackageBody =>
      ' هي حيث تنشر حزمة صغيرة من مفاتيحك العامة، وهي آمنة للمشاركة. يجلبها من يعرف حسابك من هذه المُرحِّلات ليضيفك إلى دائرة.';

  @override
  String get relaySettingsExplainerOwnRelayTerm => 'استخدام مُرحِّلك الخاص.';

  @override
  String get relaySettingsExplainerOwnRelayBody =>
      ' تحمل كل دائرة أيضًا قائمة المُرحِّلات الخاصة بها، تُشارَك مع كل عضو عند انضمامه؛ تلك القائمة، لا صندوق وارِدك، هي حيث تنتقل التحديثات المشفّرة المستمرّة للدائرة. لذا إن كنت تفضّل تجنّب المُرحِّلات العامة، يمكنك تشغيل مُرحِّلك الخاص وتوجيه دائرة إليه: فبعد أن ينضمّ الجميع، يمكن أن تتدفّق حركة تلك الدائرة عبره وحده.';

  @override
  String get relaySettingsExplainerReachabilityTerm =>
      'العقبة هي إمكانية الوصول.';

  @override
  String get relaySettingsExplainerReachabilityBody =>
      ' يجب أن يتمكّن كل عضو من الاتصال بذلك المُرحِّل، وعندما تدعو أحدهم أول مرة، تحتاجان كلاكما إلى مُرحِّل يمكنكما الوصول إليه (على سبيل المثال، المُرحِّل الخاص نفسه المُدرَج بوصفه مُرحِّل صندوق الوارد وKeyPackage للجميع). ولا يزال المُرحِّل الخاص يرى حركة البيانات المشفّرة وتوقيتها نفسها التي يراها أي مُرحِّل آخر؛ غير أنك تتحكّم بمن يشغّله.';

  @override
  String get relaySettingsExplainerFooter =>
      'يمكنك إضافة المُرحِّلات أو إزالتها من أي قائمة في أي وقت. المُرحِّلات الأكثر تجعل الوصول إليك أسهل؛ والأقل تمنحك تحكّمًا أكبر بوجهة حركة بياناتك المشفّرة.';

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
      'محدودة في الخلفية. اضبط الموقع على «دائمًا» لتطبيق Haven في الإعدادات';

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
      'للمشاركة المتواصلة في الخلفية، اضبط الموقع على \"دائمًا\" لتطبيق Haven في الإعدادات. يُظهر iOS مؤشرًا أزرق في شريط الحالة أثناء استخدام تطبيق لموقعك في الخلفية.';

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
  String get aboutWhoCanSeeTitle => 'من يرى ماذا';

  @override
  String get aboutWhoCanSeeIntro =>
      'موقعك الدقيق قابل للقراءة فقط من قِبل الأشخاص الذين تختارهم. إليك ما تستطيع الأطراف الرئيسية رؤيته وما لا تستطيع.';

  @override
  String get aboutActorCirclesWho => 'أعضاء الدائرة الذين تشارك معهم';

  @override
  String get aboutActorCirclesSees =>
      'موقعك الدقيق والاسم المعروض الذي تختاره، لكن فقط داخل الدوائر التي تشاركهم فيها، ولا يرون أبدًا دوائرك الأخرى.';

  @override
  String get aboutActorRelaysWho => 'مشغّلو المُرحِّلات';

  @override
  String get aboutActorRelaysSees =>
      'الخوادم التي تمرّر رسائلك. ترى عنوان IP الخاص بك، والمفتاح العام الذي تنشر تحته (معرّف عشوائي، لا اسمك)، وحجم حركة بياناتك وتوقيتها، وأي حساب بحثت عنه عند البحث عن شخص. ولا يمكنها أبدًا قراءة موقعك، أو رسائلك، أو أسماء دوائرك، أو من في دوائرك.';

  @override
  String get aboutActorMapWho => 'مزوّد الخرائط (Stadia Maps)';

  @override
  String get aboutActorMapSees =>
      'فقط أثناء فتح الخريطة: عنوان IP الخاص بك والمنطقة التي تعرضها، ليتمكّن من إرسال صور الخريطة الصحيحة. ولا يرى أبدًا دوائرك أو موقعك المشترك. تُخفي Stadia هوية عناوين IP ولا تبيع بياناتك.';

  @override
  String get aboutActorDevelopersWho => 'مطوّرو Haven';

  @override
  String get aboutActorDevelopersSees =>
      'لا شيء. لا يشغّل Haven أي خوادم ولا يجمع أي تحليلات. لا يستطيع المطوّر رؤية سوى ما يراه مشغّل المُرحِّل، وذلك فقط إن استخدمت مُرحِّلًا يصادف أنه يشغّله.';

  @override
  String get aboutWhoCanSeeMetadataNote =>
      'ومع ذلك، نشاطك ليس خفيًا تمامًا. يستطيع مُرحِّل تستخدمه، أو أي شخص يراقب شبكتك، أن يعرف أنك نشط، ومتى تقريبًا، وكم مرة، من توقيت الاتصال وأحجام الرسائل.';

  @override
  String get aboutScreenshotTitle => 'حماية لقطات الشاشة';

  @override
  String get aboutScreenshotBody =>
      'على Android، يحظر Haven لقطات الشاشة وتسجيل الشاشة على مستوى التطبيق كله لمنع كشف الموقع عن طريق الخطأ. هذه حماية على مستوى النظام (FLAG_SECURE) تنطبق على كل شاشة في التطبيق، بما في ذلك الخريطة وقوائم الأعضاء.';

  @override
  String get aboutVpnTitle => 'كن أكثر خصوصية مع شبكة VPN';

  @override
  String get aboutVpnBody =>
      'ترى المُرحِّلات ومزوّد الخرائط عنوان IP الخاص بك، ويرى مزوّد الإنترنت أي خوادم تصل إليها. تُخفي شبكة VPN موثوقة عنوان IP الخاص بك عنهم. نوصي بـ Mullvad. لا يُغيّر ذلك ما يراه أعضاء دائرتك، وينقل الثقة إلى مزوّد VPN.';

  @override
  String get aboutVpnLinkLabel => 'mullvad.net';

  @override
  String get aboutFooterLicense => 'مُرخَّص بموجب MIT License';

  @override
  String aboutFooterVersion(String version) {
    return 'الإصدار $version';
  }

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
  String get leaveCircleAdminLimitationNote =>
      'بصفتك مشرف هذه الدائرة، لا يمكنك مغادرتها إلا بعد أن يغادرها جميع الأعضاء الآخرين. نعلم أن هذا أمر غير مريح — سيتيح تحديث مستقبلي للمشرفين نقل الإشراف والمغادرة مباشرة.';

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
      'يعمل مفتاحك العام كاسم مستخدم آمن للمشاركة. يمسح الناس هذا الرمز، أو يلصقون مفتاحك العام، لدعوتك إلى دائرة. ومشاركته لا يمكن أن تكشف موقعك، الذي لا يظهر إلا لأعضاء الدوائر التي انضممت إليها، ولا اسمك وصورتك، اللذين يبقيان على هذا الجهاز ما لم تختر نشر ملف شخصي عام.';

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
