// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Nepali (`ne`).
class AppLocalizationsNe extends AppLocalizations {
  AppLocalizationsNe([String locale = 'ne']) : super(locale);

  @override
  String get appearanceTitle => 'रूपरंग';

  @override
  String get appearanceThemeHeader => 'थिम';

  @override
  String get appearanceThemeSystem => 'सिस्टम पूर्वनिर्धारित';

  @override
  String get appearanceThemeSystemSubtitle => 'आफ्नो यन्त्रको सेटिङअनुसार';

  @override
  String get appearanceThemeLight => 'उज्यालो';

  @override
  String get appearanceThemeLightSubtitle =>
      'सधैँ उज्यालो थिम प्रयोग गर्नुहोस्';

  @override
  String get appearanceThemeDark => 'अँध्यारो';

  @override
  String get appearanceThemeDarkSubtitle =>
      'सधैँ अँध्यारो थिम प्रयोग गर्नुहोस्';

  @override
  String get appearanceLanguageTitle => 'भाषा';

  @override
  String get languageSystemDefault => 'सिस्टम पूर्वनिर्धारित';

  @override
  String get commonTryAgain => 'फेरि प्रयास गर्नुहोस्';

  @override
  String get commonDismiss => 'बन्द गर्नुहोस्';

  @override
  String get commonSettings => 'सेटिङ';

  @override
  String get commonInvitations => 'निमन्त्रणाहरू';

  @override
  String commonPendingInvitations(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count बाँकी निमन्त्रणा',
      one: '१ बाँकी निमन्त्रणा',
    );
    return '$_temp0';
  }

  @override
  String get commonBack => 'पछाडि';

  @override
  String get commonContinue => 'जारी राख्नुहोस्';

  @override
  String get commonSkip => 'छोड्नुहोस्';

  @override
  String get commonRetry => 'पुनः प्रयास गर्नुहोस्';

  @override
  String onboardingStepOf(int current, int total) {
    return 'चरण $current / $total';
  }

  @override
  String get onboardingAppName => 'Haven';

  @override
  String get onboardingWelcomeHeadline =>
      'तपाईंले चाहेका मानिसहरूसँग मात्र, गोप्य रूपमा आफ्नो स्थान साझा गर्नुहोस्।';

  @override
  String get onboardingWelcomeHeadlineEmphasis => 'मात्र';

  @override
  String get onboardingWelcomeCta => 'सुरु गर्नुहोस्';

  @override
  String get onboardingValuePropsTitle => 'Haven लाई के कुराले फरक बनाउँछ';

  @override
  String get onboardingValueProp1Title =>
      'तपाईंका सर्कलले मात्र तपाईंलाई देख्न सक्छन्';

  @override
  String get onboardingValueProp1Body =>
      'तपाईंको स्थान यन्त्र छोड्नुअघि नै तपाईंको यन्त्रमा इन्क्रिप्ट हुन्छ, त्यसैले तपाईंले रोजेका सर्कलले मात्र यसलाई पढ्न सक्छन्, कहिल्यै Haven वा अरू कसैले होइन। Haven खुला स्रोत भएकाले जो कसैले पनि यो कुरा प्रमाणित गर्न सक्छ।';

  @override
  String get onboardingValueProp2Title => 'कसैले पनि यसलाई बन्द गर्न सक्दैन';

  @override
  String get onboardingValueProp2Body =>
      'Haven को कुनै केन्द्रीय सर्भर छैन। तपाईंका इन्क्रिप्टेड सन्देशहरू तपाईं आफैँले रोज्न सक्ने रिलेहरूको विकेन्द्रित सञ्जालमार्फत यात्रा गर्छन्, त्यसैले कुनै एक्लो संस्थाले यसलाई बन्द गर्न सक्दैन।';

  @override
  String get onboardingValueProp3Title => 'खाता आवश्यक छैन';

  @override
  String get onboardingValueProp3Body =>
      'इमेल छैन, फोन नम्बर छैन, साइन-अप छैन। Haven ले तपाईंको फोनमा मात्र रहने एउटा निजी परिचय बनाउँछ, जसलाई वास्तविक तपाईंसँग जोड्ने कुनै कुरा हुँदैन।';

  @override
  String get onboardingCreateIdentityTitle => 'आफ्नो परिचय बनाउनुहोस्';

  @override
  String get onboardingCreateIdentityBody =>
      'Haven ले यही फोनमा मात्र रहने एउटा निजी परिचय बनाउनेछ। तपाईंका सर्कलले तपाईंलाई यसैबाट चिन्छन्।';

  @override
  String get onboardingCreateIdentityWarning =>
      'यदि तपाईंले यो फोन हराउनुभयो वा एप मेटाउनुभयो भने, तपाईंको परिचय हराउँछ। Haven सँग यसलाई तपाईंका लागि पुनर्प्राप्त गर्ने कुनै उपाय छैन।';

  @override
  String get onboardingCreateIdentityCta => 'मेरो परिचय बनाउनुहोस्';

  @override
  String get onboardingCreateIdentityLoading => 'तयारी गर्दै…';

  @override
  String get onboardingCreateIdentityImportPrompt => 'पहिल्यै कुञ्जी छ?';

  @override
  String get onboardingCreateIdentityImportLink =>
      'बरु त्यसैलाई आयात गर्नुहोस्';

  @override
  String get onboardingCreateIdentityError =>
      'तपाईंको परिचय बनाउँदा केही गडबड भयो। कृपया फेरि प्रयास गर्नुहोस्।';

  @override
  String get onboardingImportTitle => 'आफ्नो विद्यमान कुञ्जी आयात गर्नुहोस्';

  @override
  String get onboardingImportBody =>
      'अर्को Haven-अनुकूल एपबाट ब्याकअप गरेको गोप्य कुञ्जी टाँस्नुहोस्।';

  @override
  String get onboardingImportHint => 'nsec1…';

  @override
  String get onboardingImportCta => 'आयात गर्नुहोस्';

  @override
  String get onboardingImportLoading => 'आयात गर्दै…';

  @override
  String get onboardingImportInvalid =>
      'यो वैध ब्याकअप कुञ्जी जस्तो देखिँदैन। कृपया जाँचेर फेरि प्रयास गर्नुहोस्।';

  @override
  String get onboardingImportError =>
      'हामी त्यो कुञ्जी आयात गर्न सकेनौं। कृपया जाँचेर फेरि प्रयास गर्नुहोस्।';

  @override
  String get onboardingDisplayNameTitle => 'नाम छान्नुहोस्';

  @override
  String get onboardingDisplayNameBody =>
      'यो नाम तपाईंले स्वीकार गर्नुभएका सर्कल निमन्त्रणा पठाउने मानिसलाई मात्र देखिन्छ। निमन्त्रणाहरू सार्वजनिक कुञ्जी प्रयोग गरेर पठाइन्छन्, त्यसैले तपाईंले स्वीकार नगरेसम्म तपाईंको नाम लुकेकै रहन्छ।';

  @override
  String get onboardingDisplayNameHint => 'जस्तै, Alex';

  @override
  String get onboardingDisplayNameError =>
      'त्यो नाम सुरक्षित गर्न सकिएन। कृपया फेरि प्रयास गर्नुहोस्।';

  @override
  String get onboardingReadyTitle => 'तपाईं तयार हुनुहुन्छ';

  @override
  String get onboardingReadyBody =>
      'Haven सर्कलमा व्यवस्थित छ, जुन साना निजी समूह हुन् जहाँ तपाईंले विश्वास गर्ने मानिससँग आफ्नो स्थान साझा गर्नुहुन्छ। आफ्नो पहिलो सर्कल बनाउनुहोस्, वा आफ्ना चिनेको कसैको निमन्त्रणा पर्खनुहोस्।';

  @override
  String get onboardingReadyCta => 'Haven मा प्रवेश गर्नुहोस्';

  @override
  String get commonCancel => 'रद्द गर्नुहोस्';

  @override
  String get commonOpenSettings => 'सेटिङ खोल्नुहोस्';

  @override
  String get settingsTitle => 'सेटिङ';

  @override
  String get settingsIdentityTitle => 'परिचय';

  @override
  String get settingsIdentitySubtitle => 'प्रोफाइल, कुञ्जी, र फोटो साझेदारी';

  @override
  String get settingsRelaysTitle => 'रिलेहरू';

  @override
  String get settingsRelaysSubtitle => 'निमन्त्रणा तपाईंकहाँ पुग्ने ठाउँ';

  @override
  String get settingsLocationTitle => 'स्थान';

  @override
  String get settingsLocationSubtitle => 'पृष्ठभूमि साझेदारी र अनुमति';

  @override
  String get settingsMapStyleTitle => 'नक्सा शैली';

  @override
  String get settingsAppearanceSubtitle => 'थिम र भाषा';

  @override
  String get settingsAboutTitle => 'बारेमा';

  @override
  String get settingsDebugOverlayTitle => 'डिबग लग ओभरले';

  @override
  String get settingsDebugOverlaySubtitle => 'स्क्रिनमा लग आउटपुट देखाउनुहोस्';

  @override
  String get relaySettingsTitle => 'रिलेहरू';

  @override
  String get relaySettingsCheckRelaysTooltip => 'रिलेहरू जाँच्नुहोस्';

  @override
  String get relaySettingsNoIdentityTitle => 'परिचय छैन';

  @override
  String get relaySettingsNoIdentityMessage =>
      'रिलेहरू व्यवस्थापन गर्न पहिले एउटा परिचय बनाउनुहोस्।';

  @override
  String get relaySettingsLoadIdentityError => 'परिचय लोड गर्न सकिएन।';

  @override
  String get relaySettingsInboxTitle => 'मेरा इनबक्स रिलेहरू';

  @override
  String get relaySettingsInboxSubtitle =>
      'kind 10050, जहाँ निमन्त्रणा तपाईंकहाँ पुग्छन्';

  @override
  String get relaySettingsKeyPackageTitle => 'मेरा KeyPackage रिलेहरू';

  @override
  String get relaySettingsKeyPackageSubtitle =>
      'kind 10051, जहाँ निमन्त्रित व्यक्तिले तपाईंका इन्क्रिप्शन कुञ्जी फेला पार्छन्';

  @override
  String get relaySettingsLoadRelaysError => 'रिलेहरू लोड गर्न सकिएन।';

  @override
  String get relaySettingsAddRelay => 'रिले थप्नुहोस्';

  @override
  String get relaySettingsRestoreDefaults =>
      'पूर्वनिर्धारित पुनर्स्थापना गर्नुहोस्';

  @override
  String get relaySettingsAddRelayError => 'रिले थप्न सकिएन।';

  @override
  String get relaySettingsRemoveRelayError => 'रिले हटाउन सकिएन।';

  @override
  String get relaySettingsRestoreTitle =>
      'पूर्वनिर्धारित रिलेहरू पुनर्स्थापना गर्ने?';

  @override
  String relaySettingsRestoreBody(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other:
          'तपाईंका हालका $count रिले Haven को पूर्वनिर्धारितले प्रतिस्थापन हुनेछन्। यो पूर्ववत् गर्न सकिँदैन।',
      one:
          'तपाईंको हालको १ रिले Haven को पूर्वनिर्धारितले प्रतिस्थापन हुनेछ। यो पूर्ववत् गर्न सकिँदैन।',
    );
    return '$_temp0';
  }

  @override
  String get relaySettingsRestoreConfirm => 'पुनर्स्थापना';

  @override
  String get relaySettingsRestoreSuccess => 'पूर्वनिर्धारित पुनर्स्थापना भयो।';

  @override
  String get relaySettingsRestoreError =>
      'पूर्वनिर्धारित पुनर्स्थापना गर्न सकिएन।';

  @override
  String relaySettingsRemoveTooltip(String url) {
    return '$url हटाउनुहोस्';
  }

  @override
  String get relaySettingsStatusConnected => 'जोडिएको';

  @override
  String get relaySettingsStatusChecking => 'जाँच्दै';

  @override
  String get relaySettingsStatusUnreachable => 'पुग्न सकिएन';

  @override
  String get relaySettingsStatusNotChecked => 'जाँचिएको छैन';

  @override
  String relaySettingsStatusSemantics(String status) {
    return 'रिले स्थिति: $status';
  }

  @override
  String get relaySettingsEmptyTitle => 'कुनै रिले कन्फिगर गरिएको छैन';

  @override
  String get relaySettingsEmptyMessage =>
      'अरूले तपाईंकहाँ पुग्न सकून् भनेर तपाईंलाई कम्तीमा एउटा रिले चाहिन्छ। Haven को पूर्वनिर्धारित पुनर्स्थापना गर्न तल ट्याप गर्नुहोस्।';

  @override
  String get relaySettingsExplainerSemantics => 'Haven का रिले कसरी काम गर्छन्';

  @override
  String get relaySettingsExplainerHeading => 'यो कसरी काम गर्छ';

  @override
  String get relaySettingsExplainerNostr =>
      'Haven को कुनै केन्द्रीय सर्भर छैन। यो दुई खुला प्रविधिमा चल्छ। Nostr भनेको जो कसैले चलाउन सक्ने रिले भनिने स्वतन्त्र सर्भरहरूको सञ्जाल हो; तिनले तपाईंका सन्देश प्राप्त गर्छन्, छोटो समय राख्छन्, र तपाईंका सम्पर्कले माग्दा हस्तान्तरण गर्छन्। कुनै एक रिले अपरिहार्य छैन, त्यसैले एउटा अफलाइन भए पनि अरूले काम गरिरहन्छन्, र रिलेलाई हस्तान्तरण गर्न बाध्य पारिए पनि त्यो सधैँ इन्क्रिप्टेड डाटा मात्र हुन्छ।';

  @override
  String get relaySettingsExplainerMarmot =>
      'Marmot प्रोटोकलले तपाईंका सन्देश यन्त्र छोड्नुअघि नै MLS (Messaging Layer Security) मानक प्रयोग गरेर तपाईंको यन्त्रमा इन्क्रिप्ट गर्छ। प्रत्येक सर्कल आफ्नै कुञ्जीसहितको आफ्नै इन्क्रिप्टेड समूह हो, त्यसैले छुट्टाछुट्टै सर्कलहरूलाई एकआपसमा जोड्न सकिँदैन। ती कुञ्जीहरू समयसँगै निरन्तर अघि बढिरहन्छन्, जसलाई फरवार्ड सेक्रेसी भनिन्छ, त्यसैले पछि उजागर भएको कुञ्जीले पनि तपाईंका अघिल्ला सन्देश खोल्न सक्दैन।';

  @override
  String get relaySettingsExplainerMetadata =>
      'यसकारण, कुनै रिलेले तपाईंको स्थान, तपाईंका सन्देश, तपाईंका सर्कलमा को छन्, वा ती सन्देशमा तपाईंको परिचय कहिल्यै देख्दैन। प्रत्येक सन्देश नयाँ, एकपटक मात्र प्रयोग हुने पठाउने ठेगानाबाट प्रकाशित हुन्छ, त्यसैले सन्देशमा भएको कुनै कुराले यसलाई तपाईंको खातासँग जोड्दैन। तर रिलेले अझै केही मेटाडाटा भने देख्छ: प्रति-सर्कल अनियमित ट्याग, तपाईंको ट्राफिकको समय र आकार, र तपाईंले जोडिने सञ्जाल ठेगाना।';

  @override
  String get relaySettingsExplainerInboxTerm => 'इनबक्स रिलेहरू';

  @override
  String get relaySettingsExplainerInboxBody =>
      ' तपाईंको पत्रपेटी हुन्: जहाँ सर्कलमा सामेल हुने निमन्त्रणाहरू, आफैँमा इन्क्रिप्टेड, तपाईंलाई संकलन गर्न पुर्‍याइन्छन्। कसैले तपाईंलाई निमन्त्रणा गर्न तिनमध्ये कुनै एउटा रिलेमा पुग्न सक्नुपर्छ।';

  @override
  String get relaySettingsExplainerKeyPackageTerm => 'KeyPackage रिलेहरू';

  @override
  String get relaySettingsExplainerKeyPackageBody =>
      ' ती हुन् जहाँ तपाईंले आफ्ना सार्वजनिक कुञ्जीको सानो बन्डल प्रकाशित गर्नुहुन्छ, जुन साझा गर्न सुरक्षित छ। तपाईंको खाता थाहा पाएको कसैले तपाईंलाई सर्कलमा थप्न ती रिलेहरूबाट यो ल्याउँछ।';

  @override
  String get relaySettingsExplainerOwnRelayTerm => 'आफ्नै रिले प्रयोग गर्दै।';

  @override
  String get relaySettingsExplainerOwnRelayBody =>
      ' प्रत्येक सर्कलले आफ्नै रिले सूची पनि बोक्छ, जुन प्रत्येक सदस्य सामेल हुँदा साझा गरिन्छ; तपाईंको इनबक्स होइन, त्यही सूची सर्कलका निरन्तर इन्क्रिप्टेड अपडेट यात्रा गर्ने ठाउँ हो। त्यसैले तपाईं सार्वजनिक रिलेहरूबाट टाढै रहन चाहनुहुन्छ भने, आफ्नै रिले चलाएर सर्कललाई त्यसैतिर इंगित गर्न सक्नुहुन्छ: सबैजना सामेल भएपछि, त्यो सर्कलको ट्राफिक त्यसैमार्फत मात्र बग्न सक्छ।';

  @override
  String get relaySettingsExplainerReachabilityTerm => 'अड्चन भनेको पहुँच हो।';

  @override
  String get relaySettingsExplainerReachabilityBody =>
      ' प्रत्येक सदस्य त्यो रिलेमा जोडिन सक्नुपर्छ, र तपाईंले पहिलोपटक कसैलाई निमन्त्रणा गर्दा, तपाईं दुवैले पुग्न सक्ने एउटा रिले चाहिन्छ (उदाहरणका लागि, सबैको इनबक्स र KeyPackage रिलेका रूपमा सूचीबद्ध त्यही निजी रिले)। निजी रिलेले पनि अरू कुनैले झैँ उही इन्क्रिप्टेड ट्राफिक र समय देख्छ; तपाईंले बस त्यो कसले चलाउँछ भन्ने नियन्त्रण गर्नुहुन्छ।';

  @override
  String get relaySettingsExplainerFooter =>
      'तपाईं कुनै पनि सूचीमा कुनै पनि बेला रिले थप्न वा हटाउन सक्नुहुन्छ। बढी रिलेले तपाईंलाई सजिलै पुग्न योग्य बनाउँछन्; कम रिलेले तपाईंको इन्क्रिप्टेड ट्राफिक कहाँ जान्छ भन्नेमा बढी नियन्त्रण दिन्छन्।';

  @override
  String get locationSettingsTitle => 'स्थान';

  @override
  String get locationSettingsDisabledSnack =>
      'पृष्ठभूमि साझेदारी निष्क्रिय गरियो';

  @override
  String get locationSettingsEnabledSnack => 'पृष्ठभूमि साझेदारी सक्रिय गरियो';

  @override
  String get locationSettingsNotificationDeniedSnack =>
      'पृष्ठभूमि साझेदारीलाई Android ले चालु राखोस् भनेर सूचना चाहिन्छ। अहिलेलाई यो निष्क्रिय छ। यसलाई सक्रिय गर्न Haven का लागि सूचनाहरूलाई अनुमति दिनुहोस्।';

  @override
  String get locationSettingsBatteryOptSnack =>
      'सक्रिय। केही फोनमा ब्याट्री अप्टिमाइजेसनले साझेदारी रोक्न सक्छ। भरपर्दो राख्न Haven लाई ब्याट्री अप्टिमाइजेसनबाट छुट दिनुहोस्।';

  @override
  String get locationSettingsErrorSnack => 'केही गडबड भयो';

  @override
  String get locationSettingsIntro =>
      'पृष्ठभूमि साझेदारी सक्रिय हुँदा, Haven बन्द भए पनि तपाईंका सर्कलले तपाईंको लाइभ स्थान देखिरहन्छन्।';

  @override
  String get locationSettingsToggleTitle => 'पृष्ठभूमिमा साझा गर्नुहोस्';

  @override
  String get locationSettingsToggleSubtitle =>
      'एप बन्द हुँदा पनि साझा गरिरहनुहोस्';

  @override
  String get locationSettingsIosLimitedNote =>
      'पृष्ठभूमिमा सीमित। सेटिङमा Haven का लागि स्थानलाई \'सधैँ\' मा सेट गर्नुहोस्';

  @override
  String get locationSettingsAndroidHeader => 'भरपर्दोपनका लागि OS सेटिङ';

  @override
  String get locationSettingsAndroidNotification =>
      'Android ले पृष्ठभूमि सेवालाई जीवित राखोस् भनेर Haven लाई स्थायी सूचना चाहिन्छ। यदि तपाईंले सूचना अनुमति अस्वीकार गर्नुभएको छ भने, सेटिङ खोलेर Haven का लागि सूचनाहरूलाई अनुमति दिनुहोस्।';

  @override
  String get locationSettingsAndroidBattery =>
      'भरपर्दो पृष्ठभूमि साझेदारीका लागि, Haven लाई ब्याट्री अप्टिमाइजेसनबाट पनि छुट दिनुहोस्। Settings → Apps → Haven → Battery → Allow all the time मा जानुहोस्।';

  @override
  String get locationSettingsAndroidVendors =>
      'Samsung यन्त्रमा, Haven लाई \"Sleeping apps\" बाट हटाउनुहोस् (Device care → Battery → Background usage limits)। Xiaomi मा, Haven का लागि Autostart सक्षम गर्नुहोस्।';

  @override
  String get locationSettingsIosGuidance =>
      'निरन्तर पृष्ठभूमि साझेदारीका लागि, सेटिङमा Haven का लागि स्थानलाई \"सधैँ\" मा सेट गर्नुहोस्। कुनै एपले पृष्ठभूमिमा तपाईंको स्थान प्रयोग गर्दा iOS ले निलो स्थिति-पट्टी सूचक देखाउँछ।';

  @override
  String get mapStyleTitle => 'नक्सा शैली';

  @override
  String get mapStyleMinimalTitle => 'न्यूनतम';

  @override
  String get mapStyleMinimalSubtitle =>
      'तपाईंको उज्यालो वा अँध्यारो थिमलाई पछ्याउने शान्त, कम-विवरणको क्यानभास';

  @override
  String get mapStyleDetailedTitle => 'विस्तृत';

  @override
  String get mapStyleDetailedSubtitle => 'पूर्ण-रङका सडक, लेबल, र स्थानहरू';

  @override
  String get mapStyleOutdoorsTitle => 'बाहिरी';

  @override
  String get mapStyleOutdoorsSubtitle => 'बाटा र पार्कसहितको छायाँकित भूभाग';

  @override
  String get mapStylePreviewHeader => 'पूर्वावलोकन';

  @override
  String get mapStylePreviewCity => 'सहर';

  @override
  String get mapStylePreviewNature => 'प्रकृति';

  @override
  String mapStylePreviewSemantics(String scene, String style) {
    return 'नक्सा पूर्वावलोकन ($scene): $style';
  }

  @override
  String get mapStylePreviewUnavailableSemantics =>
      'यो बिल्डमा नक्सा पूर्वावलोकन उपलब्ध छैन';

  @override
  String get mapStylePreviewUnavailableLabel =>
      'लाइभ पूर्वावलोकन रिलिज बिल्डहरूमा देखिन्छ';

  @override
  String get aboutTitle => 'बारेमा';

  @override
  String get aboutHeroName => 'Haven';

  @override
  String get aboutHeroTagline => 'गोप्य र सेन्सरशिप-प्रतिरोधी स्थान साझेदारी।';

  @override
  String get aboutLicensesTitle => 'खुला-स्रोत इजाजतपत्र';

  @override
  String get aboutLicensesLegalese => '© 2026 Haven · MIT License';

  @override
  String get aboutReportMapIssue => 'नक्सा समस्या रिपोर्ट गर्नुहोस्';

  @override
  String get aboutSupportOsm => 'OpenStreetMap लाई सहयोग गर्नुहोस्';

  @override
  String get aboutMapAttribution =>
      '© Stadia Maps · © OpenMapTiles · © OpenStreetMap contributors\nनक्सा डाटा ODbL अन्तर्गत इजाजतपत्र प्राप्त';

  @override
  String get aboutLinkOpenError => 'लिङ्क खोल्न सकिएन';

  @override
  String get aboutWhoCanSeeTitle => 'कसले के देख्न सक्छ';

  @override
  String get aboutWhoCanSeeIntro =>
      'तपाईंको ठ्याक्कै स्थान तपाईंले रोजेका मानिसले मात्र पढ्न सक्छन्। मुख्य पक्षहरूले के देख्न सक्छन् र के सक्दैनन्, यहाँ दिइएको छ।';

  @override
  String get aboutActorCirclesWho => 'तपाईंले साझा गर्ने सर्कल सदस्यहरू';

  @override
  String get aboutActorCirclesSees =>
      'तपाईंको ठ्याक्कै स्थान र तपाईंले रोजेको प्रदर्शन नाम, तर तपाईंले तिनीहरूसँग साझा गरेका सर्कलभित्र मात्र, कहिल्यै तपाईंका अन्य सर्कलमा होइन।';

  @override
  String get aboutActorRelaysWho => 'रिले सञ्चालकहरू';

  @override
  String get aboutActorRelaysSees =>
      'तपाईंका सन्देश पुर्‍याउने सर्भरहरू। तिनले तपाईंको IP ठेगाना, तपाईंले जुन सार्वजनिक कुञ्जीअन्तर्गत प्रकाशित गर्नुहुन्छ (अनियमित ID, तपाईंको नाम होइन), तपाईंको ट्राफिकको आकार र समय, र तपाईंले कसैलाई खोज्दा कुन खाता खोज्नुभयो भन्ने देख्छन्। तिनले तपाईंको स्थान, तपाईंका सन्देश, तपाईंका सर्कलका नाम, वा तपाईंका सर्कलमा को छन् भन्ने कहिल्यै पढ्न सक्दैनन्।';

  @override
  String get aboutActorMapWho => 'नक्सा प्रदायक (Stadia Maps)';

  @override
  String get aboutActorMapSees =>
      'नक्सा खुला हुँदा मात्र: तपाईंको IP ठेगाना र तपाईंले हेरिरहेको क्षेत्र, ताकि यसले सही नक्सा तस्बिर पठाउन सकोस्। कहिल्यै तपाईंका सर्कल वा तपाईंले साझा गरेको स्थान होइन। Stadia ले IP ठेगानालाई बेनामी बनाउँछ र तपाईंको डाटा बेच्दैन।';

  @override
  String get aboutActorDevelopersWho => 'Haven का विकासकर्ताहरू';

  @override
  String get aboutActorDevelopersSees =>
      'केही पनि होइन। Haven ले कुनै सर्भर चलाउँदैन र कुनै एनालिटिक्स संकलन गर्दैन। विकासकर्ताले रिले सञ्चालकले देख्ने कुरा मात्र देख्न सक्छन्, र त्यो पनि तपाईंले उनीहरूले चलाएको रिले प्रयोग गर्नुभयो भने मात्र।';

  @override
  String get aboutWhoCanSeeMetadataNote =>
      'त्यसो भए पनि, तपाईंको क्रियाकलाप अदृश्य हुँदैन। तपाईंले प्रयोग गर्ने रिले, वा तपाईंको सञ्जाल हेरिरहेको कसैले, जडानको समय र सन्देशको आकारबाट तपाईं सक्रिय हुनुहुन्छ, लगभग कहिले, र कति पटक भन्ने थाहा पाउन सक्छ।';

  @override
  String get aboutScreenshotTitle => 'स्क्रिनसट सुरक्षा';

  @override
  String get aboutScreenshotBody =>
      'Android मा, आकस्मिक स्थान उजागर रोक्न Haven ले एपभरि नै स्क्रिनसट र स्क्रिन रेकर्डिङ रोक्छ। यो सिस्टम-स्तरको सुरक्षा (FLAG_SECURE) हो जुन नक्सा र सदस्य सूचीसहित एपको प्रत्येक स्क्रिनमा लागू हुन्छ।';

  @override
  String get aboutVpnTitle => 'VPN सँग अझ बढी गोप्य रहनुहोस्';

  @override
  String get aboutVpnBody =>
      'रिले र नक्सा प्रदायकले तपाईंको IP ठेगाना देख्छन्, र तपाईंको इन्टरनेट प्रदायकले तपाईं कुन सर्भरमा पुग्नुहुन्छ देख्छ। विश्वासिलो VPN ले तिनीहरूबाट तपाईंको IP ठेगाना लुकाउँछ। हामी Mullvad सिफारिस गर्छौं। यसले तपाईंका सर्कल सदस्यले देख्ने कुरा बदल्दैन, र यसले विश्वास VPN प्रदायकतर्फ सार्छ।';

  @override
  String get aboutVpnLinkLabel => 'mullvad.net';

  @override
  String get aboutFooterLicense => 'MIT License अन्तर्गत इजाजतपत्र प्राप्त';

  @override
  String aboutFooterVersion(String version) {
    return 'संस्करण $version';
  }

  @override
  String get commonClearAll => 'सबै हटाउनुहोस्';

  @override
  String commonMemberCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count सदस्य',
      one: '१ सदस्य',
    );
    return '$_temp0';
  }

  @override
  String get circlesTitle => 'सर्कलहरू';

  @override
  String get circlesRefreshTooltip => 'सर्कलहरू ताजा गर्नुहोस्';

  @override
  String get circlesRequiresIdentity =>
      'सर्कल बनाउन पहिले परिचय सेटअप आवश्यक छ';

  @override
  String get circlesCreateCta => 'सर्कल बनाउनुहोस्';

  @override
  String get circlesYourCircles => 'तपाईंका सर्कलहरू';

  @override
  String get circlesEmptyTitle => 'अहिलेसम्म कुनै सर्कल छैन';

  @override
  String get circlesEmptyMessage =>
      'विश्वासिला साथी र परिवारसँग आफ्नो स्थान साझा गर्न सुरु गर्न एउटा सर्कल बनाउनुहोस्।';

  @override
  String get circlesSheetEmptyMessage =>
      'विश्वासिला सम्पर्कसँग आफ्नो स्थान साझा गर्न सुरु गर्न एउटा सर्कल बनाउनुहोस्।';

  @override
  String get circlesLoadError => 'सर्कलहरू लोड गर्न सकिएन';

  @override
  String get circlesSelectToView => 'सदस्य हेर्न एउटा सर्कल चयन गर्नुहोस्';

  @override
  String get circlesNoMembers => 'यो सर्कलमा कुनै सदस्य छैन';

  @override
  String get createCircleTitle => 'सदस्य थप्नुहोस्';

  @override
  String createCircleSelectedCount(int count) {
    return 'चयन गरिएको ($count)';
  }

  @override
  String get createCircleEmptyTitle => 'सर्कल सदस्य थप्नुहोस्';

  @override
  String get createCircleEmptyMessage =>
      'सदस्य थप्न ID द्वारा खोज्नुहोस् वा तिनको QR कोड स्क्यान गर्नुहोस्।';

  @override
  String get createCircleNoValidMembers => 'निमन्त्रणा गर्न कुनै वैध सदस्य छैन';

  @override
  String get createCircleMemberAlreadyAdded => 'सदस्य पहिल्यै थपिएको छ';

  @override
  String get createCircleNoIdInQr => 'QR कोडमा कुनै वैध ID फेला परेन';

  @override
  String get createCircleNoAccountFound => 'कुनै Haven खाता फेला परेन';

  @override
  String get createCircleCouldNotVerify => 'सदस्य प्रमाणित गर्न सकिएन';

  @override
  String get createCircleSomethingWentWrong => 'केही गडबड भयो';

  @override
  String get nameCircleTitle => 'आफ्नो सर्कललाई नाम दिनुहोस्';

  @override
  String nameCircleMembersToInvite(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count सदस्यलाई निमन्त्रणा गरिनेछ',
      one: '१ सदस्यलाई निमन्त्रणा गरिनेछ',
    );
    return '$_temp0';
  }

  @override
  String get nameCircleNameLabel => 'सर्कलको नाम';

  @override
  String get nameCircleNameHint => 'जस्तै, परिवार, घनिष्ठ साथीहरू';

  @override
  String get nameCircleNameEmptyError => 'कृपया सर्कलको नाम लेख्नुहोस्';

  @override
  String get nameCircleNameTooLongError =>
      'नाम ५० वा त्योभन्दा कम अक्षरको हुनुपर्छ';

  @override
  String get nameCircleSharingInfo =>
      'यस सर्कलका सबैले एकआपसको स्थान र प्रदर्शन नाम देख्न सक्छन्। तपाईंको प्रदर्शन नाम भनेको तपाईंले Settings → परिचय मा सेट गरेको हो। यो सर्कल तपाईं भएका अन्य सर्कलहरूबाट अलग रहन्छ, त्यसैले यसका सदस्यले तपाईंका अन्य सर्कल वा तिनमा को छन् भन्ने देख्न सक्दैनन्।';

  @override
  String get nameCircleCreateCta => 'सर्कल बनाउनुहोस्';

  @override
  String get nameCircleStageCreatingGroup => 'सुरक्षित समूह बनाउँदै...';

  @override
  String get nameCircleStageSendingInvites => 'निमन्त्रणा पठाउँदै...';

  @override
  String get nameCircleStageComplete => 'भयो!';

  @override
  String nameCircleProgressSemantics(String stage) {
    return 'बनाउने प्रगति: $stage';
  }

  @override
  String nameCirclePercentComplete(int percent) {
    return '$percent प्रतिशत पूरा';
  }

  @override
  String nameCircleCreatedSnack(String name, int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'सर्कल \"$name\" बनाइयो! $count निमन्त्रणा पठाइयो।',
      one: 'सर्कल \"$name\" बनाइयो! १ निमन्त्रणा पठाइयो।',
    );
    return '$_temp0';
  }

  @override
  String get nameCircleIdentityError =>
      'परिचय त्रुटि। कृपया आफ्नो परिचय सेटअप जाँच्नुहोस्।';

  @override
  String get nameCircleCreateError =>
      'सर्कल बनाउन सकिएन। कृपया फेरि प्रयास गर्नुहोस्।';

  @override
  String addMemberTitle(String circleName) {
    return '$circleName मा थप्नुहोस्';
  }

  @override
  String get addMemberInfo =>
      'नयाँ सदस्यले निमन्त्रणा स्वीकार गरेपछि यस सर्कलका इन्क्रिप्टेड स्थानहरू देख्न सक्छन्।';

  @override
  String get addMemberAlreadyInCircle => 'पहिल्यै यो सर्कलमा छन्';

  @override
  String addMemberSendInvitation(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'निमन्त्रणाहरू पठाउनुहोस्',
      one: 'निमन्त्रणा पठाउनुहोस्',
    );
    return '$_temp0';
  }

  @override
  String addMemberSendingInvitation(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'निमन्त्रणाहरू पठाउँदै...',
      one: 'निमन्त्रणा पठाउँदै...',
    );
    return '$_temp0';
  }

  @override
  String addMemberSentToCircle(int count, String circleName) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$circleName मा निमन्त्रणाहरू पठाइयो',
      one: '$circleName मा निमन्त्रणा पठाइयो',
    );
    return '$_temp0';
  }

  @override
  String addMemberPartialDelivery(int sent, int total) {
    return 'निमन्त्रणा पठाइयो ($sent मध्ये $total)। बाँकीको डेलिभरी विचाराधीन छ।';
  }

  @override
  String get addMemberError => 'सदस्य थप्न सकिएन। कृपया फेरि प्रयास गर्नुहोस्।';

  @override
  String get qrScannerTitle => 'QR कोड स्क्यान गर्नुहोस्';

  @override
  String get qrScannerToggleFlash => 'फ्ल्यास टगल गर्नुहोस्';

  @override
  String get qrScannerSwitchCamera => 'क्यामेरा बदल्नुहोस्';

  @override
  String get qrScannerInstruction => 'QR कोडलाई फ्रेमभित्र राख्नुहोस्';

  @override
  String get qrScannerScanning => 'स्क्यान गर्दै...';

  @override
  String get circleMemberInvitationPending => 'निमन्त्रणा बाँकी';

  @override
  String get circleMemberNoRecentLocation => 'हालसालैको कुनै स्थान छैन';

  @override
  String get circleMemberRemoveTooltip => 'सर्कलबाट हटाउनुहोस्';

  @override
  String get circleMemberAdmin => 'एडमिन';

  @override
  String get circleMemberHintPending => 'निमन्त्रणा बाँकी';

  @override
  String get circleMemberHintNoLocation => 'कुनै स्थान उपलब्ध छैन';

  @override
  String get circleMemberHintMember => 'सदस्य';

  @override
  String get circleMemberHintTapToCenter =>
      'तिनको स्थानमा नक्सा केन्द्रित गर्न ट्याप गर्नुहोस्';

  @override
  String get pendingMemberRetryTooltip => 'प्रमाणीकरण पुनः प्रयास गर्नुहोस्';

  @override
  String get pendingMemberRemoveTooltip => 'सदस्य हटाउनुहोस्';

  @override
  String get pendingMemberValidating => 'प्रमाणित गर्दै';

  @override
  String get pendingMemberValid => 'वैध';

  @override
  String get pendingMemberWarning => 'चेतावनी';

  @override
  String get pendingMemberCheckingAvailability => 'उपलब्धता जाँच्दै...';

  @override
  String get pendingMemberReadyToInvite => 'निमन्त्रणा गर्न तयार';

  @override
  String get memberSearchHint => 'सदस्य ID लेख्नुहोस्...';

  @override
  String get memberSearchPasteTooltip => 'क्लिपबोर्डबाट टाँस्नुहोस्';

  @override
  String get memberSearchAddTooltip => 'सदस्य थप्नुहोस्';

  @override
  String get memberSearchScanTooltip => 'QR कोड स्क्यान गर्नुहोस्';

  @override
  String get memberSearchHelper =>
      'सम्पर्कहरूसँग तिनको Haven QR कोड वा ID माग्नुहोस्';

  @override
  String get memberSearchNoValidId => 'कुनै वैध Haven ID फेला परेन';

  @override
  String get memberSearchAlreadyAdded => 'सदस्य पहिल्यै थपिएको छ';

  @override
  String selectedMembersMore(int count) {
    return '+$count थप';
  }

  @override
  String get invitationStatusPending => 'निमन्त्रणा बाँकी';

  @override
  String get invitationStatusActive => 'सक्रिय';

  @override
  String get invitationStatusDeclined => 'अस्वीकृत';

  @override
  String invitationStatusSemantics(String label) {
    return 'निमन्त्रणा स्थिति: $label';
  }

  @override
  String invitationCardSemantics(String circleName, String inviter, int count) {
    return '$circleName मा सामेल हुने निमन्त्रणा, $inviter ले निमन्त्रणा गरेको, $count सदस्य';
  }

  @override
  String invitationCardInvitedBySemantics(String inviter) {
    return 'क्रिप्टोग्राफिक पहिचानकर्ता $inviter ले निमन्त्रणा गरेको';
  }

  @override
  String invitationCardInvitedBy(String inviter) {
    return 'निमन्त्रणा गर्ने: $inviter';
  }

  @override
  String invitationCardMemberCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count सदस्य',
      one: '१ सदस्य',
    );
    return '$_temp0';
  }

  @override
  String get invitationCardJustNow => 'भर्खरै';

  @override
  String invitationCardDaysAgo(int count) {
    return '${count}d अघि';
  }

  @override
  String invitationCardHoursAgo(int count) {
    return '${count}h अघि';
  }

  @override
  String invitationCardMinutesAgo(int count) {
    return '${count}m अघि';
  }

  @override
  String get invitationCardDecline => 'अस्वीकार गर्नुहोस्';

  @override
  String get invitationCardAccept => 'स्वीकार गर्नुहोस्';

  @override
  String get invitationAcceptedSnack => 'निमन्त्रणा स्वीकार गरियो';

  @override
  String get invitationDeclinedSnack => 'निमन्त्रणा अस्वीकार गरियो';

  @override
  String get invitationAcceptError =>
      'निमन्त्रणा स्वीकार गर्न सकिएन। कृपया फेरि प्रयास गर्नुहोस्।';

  @override
  String get invitationDeclineError =>
      'निमन्त्रणा अस्वीकार गर्न सकिएन। कृपया फेरि प्रयास गर्नुहोस्।';

  @override
  String get circleSelectorLabel => 'सर्कल चयनकर्ता';

  @override
  String get circleSelectorPlaceholder => 'एउटा सर्कल चयन गर्नुहोस्';

  @override
  String get circleSelectorNewCircle => 'नयाँ सर्कल';

  @override
  String get circleSelectorLoadError => 'सर्कलहरू लोड गर्न सकिएन';

  @override
  String get circleSelectorExpandedAnnouncement => 'सर्कल सूची विस्तार गरियो';

  @override
  String get circleSelectorCollapsedAnnouncement =>
      'सर्कल सूची संक्षिप्त गरियो';

  @override
  String get circleDetailsButtonTooltip => 'सर्कल विवरण';

  @override
  String get circleDetailsTitle => 'सर्कल विवरण';

  @override
  String get circleDetailsRelaysHeading => 'यस सर्कलका रिलेहरू';

  @override
  String get circleDetailsNoRelays => '(कुनै अभिलेख छैन)';

  @override
  String get circleDetailsRelaysNote =>
      'यी रिलेहरू यो सर्कल बनाउँदा रोजिएका थिए र अहिले प्रयोगकर्ताले सम्पादन गर्न मिल्दैन। तपाईंका व्यक्तिगत रिले सेटिङबाट स्वतन्त्र।';

  @override
  String get circleDetailsAddMember => 'सदस्य थप्नुहोस्';

  @override
  String get circleDetailsLeaveCircle => 'सर्कल छोड्नुहोस्';

  @override
  String get leaveCircleDialogTitle => 'सर्कल छोड्नुहोस्';

  @override
  String get leaveCircleDialogBody =>
      'के तपाईं यो सर्कल छोड्न निश्चित हुनुहुन्छ? तपाईंले यसका सदस्यहरूबाट स्थान अपडेटहरू अब प्राप्त गर्नुहुने छैन। यो कार्य पूर्ववत् गर्न सकिँदैन।';

  @override
  String get leaveCircleConfirm => 'छोड्नुहोस्';

  @override
  String get leaveCircleIdentityUnavailable => 'परिचय उपलब्ध छैन';

  @override
  String get leaveCircleSuccess => 'सर्कल सफलतापूर्वक छोडियो';

  @override
  String get leaveCircleError => 'सर्कल छोड्न सकिएन';

  @override
  String get circlesPanelCollapsedAnnouncement =>
      'सर्कल प्यानल संक्षिप्त गरियो';

  @override
  String get circlesPanelExpandedAnnouncement => 'सर्कल प्यानल विस्तार गरियो';

  @override
  String get circlesPanelSlightlyOpenAnnouncement => 'सर्कल प्यानल अलिकति खुला';

  @override
  String get circlesPanelHalfOpenAnnouncement => 'सर्कल प्यानल आधा खुला';

  @override
  String get circleMemberAnnouncementSelf => 'तपाईं';

  @override
  String get circleMemberAnnouncementFallback => 'सदस्य';

  @override
  String get invitationsRefreshTooltip => 'निमन्त्रणाहरू ताजा गर्नुहोस्';

  @override
  String get invitationsLoadError => 'निमन्त्रणाहरू लोड गर्न सकिएन';

  @override
  String get invitationsEmptyTitle => 'कुनै निमन्त्रणा छैन';

  @override
  String get invitationsEmptyMessage =>
      'कसैले तपाईंलाई सर्कलमा निमन्त्रणा गर्दा, यो यहाँ देखिनेछ।';

  @override
  String get invitationPillChecking => 'तपाईंको इनबक्स जाँच्दै…';

  @override
  String get invitationPillCheckingAnnouncement => 'तपाईंको इनबक्स जाँच्दै';

  @override
  String invitationPillNewCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count नयाँ निमन्त्रणा',
      one: '१ नयाँ निमन्त्रणा',
    );
    return '$_temp0';
  }

  @override
  String get invitationPillUpToDate => 'सबैले जवाफ दिए · केही नयाँ छैन';

  @override
  String get invitationPillUpToDateAnnouncement =>
      'सबै इनबक्सले जवाफ दिए, केही नयाँ छैन';

  @override
  String invitationPillPartial(int responded, int total) {
    return '$total मध्ये $responded इनबक्सले जवाफ दिए';
  }

  @override
  String get invitationPillOffline => 'तपाईंको इनबक्समा पुग्न सकिएन';

  @override
  String get invitationPillOfflineAnnouncement =>
      'तपाईंको इनबक्समा पुग्न सकिएन, फेरि प्रयास गर्नुहोस्';

  @override
  String get invitationPillNoInbox => 'कुनै इनबक्स सेटअप गरिएको छैन';

  @override
  String get invitationPillSetUp => 'सेटअप गर्नुहोस्';

  @override
  String get invitationPillDone => 'भयो';

  @override
  String get identityTitle => 'परिचय';

  @override
  String get identityLoadError =>
      'तपाईंको परिचय लोड गर्दा केही गडबड भयो। कृपया फेरि प्रयास गर्नुहोस्।';

  @override
  String get identityMissingTitle => 'परिचय छैन';

  @override
  String get identityMissingMessage =>
      'तपाईंको परिचय हरायो। Haven प्रयोग गरिरहन नयाँ परिचय सेटअप गर्नुहोस्।';

  @override
  String get identitySetUpCta => 'परिचय सेटअप गर्नुहोस्';

  @override
  String get identityPublicKeyQrTitle => 'सार्वजनिक कुञ्जी QR';

  @override
  String get identityPublicKeyQrSubtitle =>
      'अरूले तपाईंलाई सर्कलमा कसरी निमन्त्रणा गर्छन्';

  @override
  String get identityAdvancedTitle => 'उन्नत';

  @override
  String get identityAdvancedSubtitle =>
      'सार्वजनिक कुञ्जी, गोप्य कुञ्जी, मेटाउने';

  @override
  String get identityVisibilityNote =>
      'तपाईं सामेल भएका सर्कलका सदस्यले मात्र तपाईंको फोटो र प्रदर्शन नाम देख्न सक्छन्। निमन्त्रणाहरू सार्वजनिक कुञ्जी वा QR कोड प्रयोग गरेर पठाइन्छन्।';

  @override
  String get identityAdvancedExportError =>
      'गोप्य कुञ्जी निर्यात गर्न सकिएन। कृपया फेरि प्रयास गर्नुहोस्।';

  @override
  String get identityAdvancedDeleteTitle => 'परिचय मेटाउने?';

  @override
  String get identityAdvancedDeleteBody =>
      'यसले तपाईंको परिचय स्थायी रूपमा मेटाउनेछ। यदि तपाईं यसलाई पुनर्प्राप्त गर्न चाहनुहुन्छ भने आफ्नो गोप्य कुञ्जी ब्याकअप गरेको सुनिश्चित गर्नुहोस्।';

  @override
  String get identityAdvancedDeleteConfirm => 'मेटाउनुहोस्';

  @override
  String get identityAdvancedDeletedSnack => 'परिचय मेटाइयो';

  @override
  String get identityAdvancedDeleteError =>
      'परिचय मेटाउन सकिएन। कृपया फेरि प्रयास गर्नुहोस्।';

  @override
  String identityAdvancedCopiedToClipboard(String label) {
    return '$label क्लिपबोर्डमा प्रतिलिपि गरियो';
  }

  @override
  String get identityAdvancedSecretCopiedWarning =>
      'गोप्य कुञ्जी प्रतिलिपि गरियो। चेतावनी: अन्य एपले तपाईंको क्लिपबोर्ड पढ्न सक्छन्। यसलाई कतै सुरक्षित ठाउँमा टाँस्नुहोस् र आफ्नो क्लिपबोर्ड खाली गर्नुहोस्।';

  @override
  String get identityAdvancedMissingBody => 'कुनै परिचय सेटअप गरिएको छैन।';

  @override
  String get identityAdvancedPublicKeyLabel => 'सार्वजनिक कुञ्जी';

  @override
  String get identityAdvancedPublicKeyHexLabel => 'सार्वजनिक कुञ्जी (hex)';

  @override
  String get identityAdvancedCopyValue => 'सार्वजनिक कुञ्जी';

  @override
  String get identityAdvancedCopyPublicKeyTooltip =>
      'सार्वजनिक कुञ्जी प्रतिलिपि गर्नुहोस्';

  @override
  String get identityAdvancedCopyHexTooltip => 'hex प्रतिलिपि गर्नुहोस्';

  @override
  String get identityAdvancedSecretKeyTitle => 'गोप्य कुञ्जी';

  @override
  String get identityAdvancedSecretKeyWarning =>
      'तपाईंको गोप्य कुञ्जीले तपाईंको परिचयमा पूर्ण पहुँच दिन्छ। यसलाई कहिल्यै कसैसँग साझा नगर्नुहोस्।';

  @override
  String get identityAdvancedRevealSecretKey => 'गोप्य कुञ्जी देखाउनुहोस्';

  @override
  String get identityAdvancedHideSecretKey => 'गोप्य कुञ्जी लुकाउनुहोस्';

  @override
  String get identityAdvancedCopySecretKeyTooltip =>
      'गोप्य कुञ्जी प्रतिलिपि गर्नुहोस्';

  @override
  String get identityAdvancedDeleteIdentityCta => 'परिचय मेटाउनुहोस्';

  @override
  String get qrCodeLoadError =>
      'तपाईंको सार्वजनिक कुञ्जी लोड गर्दा केही गडबड भयो। कृपया फेरि प्रयास गर्नुहोस्।';

  @override
  String get qrCodeYourPublicKeyLabel => 'तपाईंको सार्वजनिक कुञ्जी';

  @override
  String get qrCodeWhatIsThisTitle => 'यो के हो?';

  @override
  String get qrCodeExplainerKeys =>
      'Haven Nostr मा चल्छ, जुन कुनै कम्पनी खाता वा साइन-अप नभएको खुला सञ्जाल हो। तपाईंको परिचय भनेको कुञ्जीहरूको एक जोडा मात्र हो: तपाईंले मात्र राख्ने गोप्य कुञ्जी, र त्यसैबाट बनेको यो सार्वजनिक कुञ्जी।';

  @override
  String get qrCodeExplainerUsername =>
      'तपाईंको सार्वजनिक कुञ्जी साझा गर्न सुरक्षित प्रयोगकर्ता नाम जस्तै काम गर्छ। मानिसहरूले तपाईंलाई सर्कलमा निमन्त्रणा गर्न यो कोड स्क्यान गर्छन्, वा तपाईंको सार्वजनिक कुञ्जी टाँस्छन्। यसले तपाईंको प्रदर्शन नाम, फोटो, वा स्थान उजागर गर्न सक्दैन, जुन तपाईं सामेल भएका सर्कलका सदस्यसँग मात्र साझा गरिन्छ।';

  @override
  String get displayNameCardTitle => 'प्रदर्शन नाम';

  @override
  String get displayNameCardLoadError =>
      'तपाईंको प्रदर्शन नाम लोड गर्न सकिएन। पछि फेरि प्रयास गर्नुहोस्।';

  @override
  String get displayNameCardHint => 'आफ्नो प्रदर्शन नाम लेख्नुहोस्';

  @override
  String get displayNameCardSavedLabel => 'प्रदर्शन नाम सुरक्षित गरियो';

  @override
  String get displayNameCardSaveLabel => 'प्रदर्शन नाम सुरक्षित गर्नुहोस्';

  @override
  String get displayNameCardSavingLabel => 'प्रदर्शन नाम सुरक्षित गर्दै';

  @override
  String get displayNameCardRetryLabel =>
      'सुरक्षित गर्न सकिएन। पुनः प्रयास गर्नुहोस्';

  @override
  String get displayNameCardSavedAnnouncement => 'प्रदर्शन नाम सुरक्षित गरियो';

  @override
  String get displayNameCardSaveFailedAnnouncement =>
      'सुरक्षित गर्न सकिएन, फेरि प्रयास गर्नुहोस्';

  @override
  String keyDisplayCopiedToClipboard(String label) {
    return '$label क्लिपबोर्डमा प्रतिलिपि गरियो';
  }

  @override
  String keyDisplaySemantics(String label, String state) {
    return '$label: $state';
  }

  @override
  String get keyDisplayStateRevealed => 'देखाइएको';

  @override
  String get keyDisplayStateHidden => 'लुकाइएको';

  @override
  String get keyDisplayHideTooltip => 'लुकाउनुहोस्';

  @override
  String get keyDisplayRevealTooltip => 'देखाउनुहोस्';

  @override
  String get keyDisplayCopyTooltip => 'प्रतिलिपि गर्नुहोस्';

  @override
  String get keyDisplayCompactCopied => 'कुञ्जी क्लिपबोर्डमा प्रतिलिपि गरियो';

  @override
  String get keyDisplayCompactTapToCopy => 'प्रतिलिपि गर्न ट्याप गर्नुहोस्';

  @override
  String get npubQrCopiedSnack =>
      'सार्वजनिक कुञ्जी क्लिपबोर्डमा प्रतिलिपि गरियो';

  @override
  String get npubQrCopyButton => 'सार्वजनिक कुञ्जी प्रतिलिपि गर्नुहोस्';

  @override
  String get npubQrScanLabel => 'मलाई थप्न स्क्यान गर्नुहोस्';

  @override
  String get npubQrSemanticsLabel => 'तपाईंको सार्वजनिक परिचयको QR कोड';

  @override
  String get photoHeaderRemoveTitle => 'प्रोफाइल फोटो हटाउने?';

  @override
  String get photoHeaderRemoveBody =>
      'यसले तपाईंका सर्कलका सबैका लागि तपाईंको फोटो हटाउँछ।';

  @override
  String get photoHeaderEditPhoto => 'फोटो सम्पादन गर्नुहोस्';

  @override
  String get photoHeaderRemove => 'हटाउनुहोस्';

  @override
  String get photoHeaderViewPhotoSemantics => 'प्रोफाइल फोटो हेर्नुहोस्';

  @override
  String get photoHeaderAddPhotoSemantics => 'प्रोफाइल फोटो थप्नुहोस्';

  @override
  String get photoHeaderChangePhotoSemantics => 'प्रोफाइल फोटो बदल्नुहोस्';

  @override
  String get avatarPickerPhotoUpdated =>
      'फोटो अपडेट गरियो — तपाईंका सर्कलसँग साझा गरियो, एन्ड-टु-एन्ड इन्क्रिप्टेड।';

  @override
  String get avatarPickerPhotoRemoved => 'फोटो हटाइयो।';

  @override
  String get avatarPickerRemoveError =>
      'तपाईंको फोटो हटाउन सकिएन। कृपया फेरि प्रयास गर्नुहोस्।';

  @override
  String get avatarPickerUpdateError =>
      'तपाईंको फोटो अपडेट गर्न सकिएन। कृपया फेरि प्रयास गर्नुहोस्।';

  @override
  String get avatarPickerCropTitle => 'फोटो क्रप गर्नुहोस्';

  @override
  String get avatarPickerCropDone => 'भयो';

  @override
  String get avatarPickerCropCancel => 'रद्द गर्नुहोस्';

  @override
  String get avatarFullscreenClose => 'बन्द गर्नुहोस्';

  @override
  String get avatarFullscreenSemantics => 'प्रोफाइल फोटो, पूर्ण स्क्रिन';

  @override
  String get avatarFullscreenLoadError => 'फोटो लोड गर्न सकिएन';

  @override
  String get mapInitializing => 'सुरु गर्दै...';

  @override
  String get mapInitFailedTitle => 'सुरुआत असफल भयो';

  @override
  String get mapInitFailedMessage => 'स्थान सेवाहरू सुरु गर्न सकिएन।';

  @override
  String get mapInitFailedRetry =>
      'सुरुआत असफल भयो। कृपया फेरि प्रयास गर्नुहोस्।';

  @override
  String get mapLocationOffMessage =>
      'नक्सामा आफूलाई र आफ्ना सर्कलहरूलाई देख्न स्थान सक्रिय गर्नुहोस्।';

  @override
  String get mapGettingLocation => 'स्थान प्राप्त गर्दै...';

  @override
  String get mapLoadingMap => 'नक्सा लोड गर्दै...';

  @override
  String get mapLocationOffTitle => 'स्थान निष्क्रिय छ';

  @override
  String get mapLocationErrorTitle => 'स्थान त्रुटि';

  @override
  String get mapLocationUnavailable => 'स्थान अस्थायी रूपमा उपलब्ध छैन';

  @override
  String get mapThisLocation => 'यो स्थान';

  @override
  String get mapMemberFallbackName => 'सदस्य';

  @override
  String mapOpenInAppleMapsTitle(String label) {
    return '$label लाई Apple Maps मा खोल्ने?';
  }

  @override
  String get mapOpenInAppleMapsBody =>
      'नक्साको निर्देशांक मात्र Apple Maps मा पठाइन्छ, कहिल्यै नाम वा परिचय होइन।';

  @override
  String get mapOpenInAppleMapsConfirm => 'Apple Maps मा खोल्नुहोस्';

  @override
  String get mapOpenMapsError => 'Maps खोल्न सकिएन';

  @override
  String get mapControlsZoomIn => 'जुम इन गर्नुहोस्';

  @override
  String get mapControlsZoomOut => 'जुम आउट गर्नुहोस्';

  @override
  String get mapControlsRecenter => 'पुनः केन्द्रित गर्नुहोस्';

  @override
  String get mapControlsRecenterFab => 'मेरो स्थानमा पुनः केन्द्रित गर्नुहोस्';

  @override
  String get mapAttributionCreditsButton => 'नक्सा क्रेडिट र इजाजतपत्र';

  @override
  String userLocationMarkerSemantics(String accuracy) {
    return 'तपाईंको स्थान मार्कर$accuracy';
  }

  @override
  String userLocationMarkerAccuracy(int meters) {
    return '. शुद्धता: $meters मिटर';
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
      other: '$count मिनेट अघि',
      one: '१ मिनेट अघि',
    );
    return '$_temp0';
  }

  @override
  String memberMarkerHoursAgoSemantics(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count घन्टा अघि',
      one: '१ घन्टा अघि',
    );
    return '$_temp0';
  }

  @override
  String memberMarkerDaysAgoSemantics(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count दिन अघि',
      one: '१ दिन अघि',
    );
    return '$_temp0';
  }

  @override
  String memberMarkerNamedSemantics(String name) {
    return '$name सदस्य मार्कर';
  }

  @override
  String get memberMarkerGenericSemantics => 'सदस्य मार्कर';

  @override
  String memberMarkerLastSeenSemantics(String base, String age) {
    return '$base, अन्तिम पटक देखिएको $age';
  }

  @override
  String get commonAdd => 'थप्नुहोस्';

  @override
  String get addRelaySheetTitleInbox => 'इनबक्स रिले थप्नुहोस्';

  @override
  String get addRelaySheetTitleKeyPackage => 'KeyPackage रिले थप्नुहोस्';

  @override
  String get addRelaySheetHint => 'wss://relay.example.com';

  @override
  String get addRelaySheetPasteTooltip => 'क्लिपबोर्डबाट टाँस्नुहोस्';

  @override
  String get addRelaySheetErrorEmpty => 'रिले ठेगाना लेख्नुहोस्।';

  @override
  String get addRelaySheetErrorInsecureScheme =>
      'यस रिलेमा जाने ट्राफिक इन्क्रिप्ट होस् भनेर wss:// प्रयोग गर्नुहोस्।';

  @override
  String get addRelaySheetErrorHasCredentials =>
      'रिले URL मा प्रमाणहरू हुनु हुँदैन।';

  @override
  String get addRelaySheetErrorInvalidFormat =>
      'wss://relay.example.com जस्तो रिले ठेगाना लेख्नुहोस्।';

  @override
  String get avatarSemanticsLabel => 'प्रयोगकर्ता अवतार';

  @override
  String avatarSemanticsFor(String initials) {
    return '$initials का लागि';
  }

  @override
  String get avatarSemanticsOnline => 'अनलाइन';

  @override
  String get avatarSemanticsOffline => 'अफलाइन';
}
