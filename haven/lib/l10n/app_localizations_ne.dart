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
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$countString बाँकी निमन्त्रणा',
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
    final intl.NumberFormat currentNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String currentString = currentNumberFormat.format(current);
    final intl.NumberFormat totalNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String totalString = totalNumberFormat.format(total);

    return 'चरण $currentString / $totalString';
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
      'इमेल छैन, फोन नम्बर छैन, साइन-अप छैन। Haven ले यस्तो परिचय बनाउँछ जसको गोप्य कुञ्जी कहिल्यै तपाईंको फोनबाट बाहिर जाँदैन, त्यसैले कसैले सुम्पन सक्ने कुनै खाता नै हुँदैन।';

  @override
  String get onboardingValueProp1Summary =>
      'तपाईंको यन्त्रमै इन्क्रिप्ट हुन्छ, त्यसैले तपाईंले छानेका सर्कलहरूले मात्र पढ्न सक्छन्।';

  @override
  String get onboardingValueProp2Summary =>
      'कुनै केन्द्रीय सर्भर छैन — यो तपाईंले छानेको रिले नेटवर्कमा चल्छ।';

  @override
  String get onboardingValueProp3Summary =>
      'इमेल, फोन वा साइन-अप छैन। तपाईंको गोप्य कुञ्जी कहिल्यै फोनबाट बाहिर जाँदैन।';

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
  String get onboardingDisplayNameHint => 'जस्तै, Alex';

  @override
  String get onboardingDisplayNameError =>
      'त्यो नाम सुरक्षित गर्न सकिएन। कृपया फेरि प्रयास गर्नुहोस्।';

  @override
  String get onboardingAddPhotoOptional => 'फोटो थप्नुहोस् (वैकल्पिक)';

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
      'kind 10002, जहाँ निमन्त्रित व्यक्तिले तपाईंका इन्क्रिप्शन कुञ्जी फेला पार्छन्';

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
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other:
          'तपाईंका हालका $countString रिले Haven को पूर्वनिर्धारितले प्रतिस्थापन हुनेछन्। यो पूर्ववत् गर्न सकिँदैन।',
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
      'तपाईंको हालको अनुमतिमै साझेदारी पृष्ठभूमिमा पनि चलिरहन्छ। iOS ले एप बन्द गरेपछि पनि अपडेटहरू फेरि सुरु हुन सकून् भनेर सेटिङमा Haven का लागि स्थानलाई \'सधैँ\' मा सेट गर्नुहोस्।';

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
      'पृष्ठभूमि साझेदारी सक्रिय हुँदा, Haven ले तपाईंको स्थान निरन्तर प्रयोग गरिरहन्छ र iOS ले निलो स्थिति-पट्टी सूचक देखाउँछ। \"सधैँ\" अनुमति दिनुभयो भने, iOS ले एप बन्द गरेपछि पनि Haven ले तपाईंका सर्कलका छुटेका अपडेटहरू ल्याउन सक्छ।';

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
  String get aboutVpnLinkLabel => 'mullvad.net';

  @override
  String get aboutFooterLicense => 'MIT License अन्तर्गत इजाजतपत्र प्राप्त';

  @override
  String aboutFooterVersion(String version) {
    return 'संस्करण $version';
  }

  @override
  String get privacyTitle => 'गोपनीयता';

  @override
  String get privacySubtitle => 'Haven कसरी काम गर्छ र अरूले के देख्न सक्छन्';

  @override
  String get privacyHubSummary =>
      'Haven ले तपाईंको स्थान तपाईंले रोजेका सानो समूहसँग मात्र साझा गर्छ, र फोन छोड्नुअघि नै त्यहीँ इन्क्रिप्ट गर्छ। यसको पछाडि कुनै कम्पनीको खाता छैन, र कुनै Haven सर्भर छैन। तलका पृष्ठहरूले यो कसरी हुन्छ भन्ने सरल भाषामा बताउँछन्, र यसले केबाट बचाउँदैन भन्नेमा पनि इमानदार छन्।';

  @override
  String get privacyGroupBasicsHeading => 'आधारभूत कुरा';

  @override
  String get privacyMeansForYouLabel => 'तपाईंका लागि यसको अर्थ';

  @override
  String get privacyMoreDetailLabel => 'अझ विस्तारमा';

  @override
  String get privacyMoreDetailExpandHint => 'प्राविधिक विवरण देखाउनुहोस्';

  @override
  String get privacyMoreDetailCollapseHint => 'प्राविधिक विवरण लुकाउनुहोस्';

  @override
  String get privacyMoreDetailExpandedAnnouncement => 'प्राविधिक विवरण देखाइयो';

  @override
  String get privacyMoreDetailCollapsedAnnouncement =>
      'प्राविधिक विवरण लुकाइयो';

  @override
  String get privacyWhatHavenIsTitle => 'Haven के हो, र किन कुनै खाता हुँदैन';

  @override
  String get privacyWhatHavenIsSubtitle => 'साइन-अप छैन, कम्पनीको सर्भर छैन';

  @override
  String get privacyWhatHavenIsNoAccount =>
      'Haven ले तपाईंको स्थान तपाईंले रोजेका सानो समूहसँग साझा गर्छ, जसलाई सर्कल भनिन्छ। यसको पछाडि कुनै खाता हुँदैन। तपाईंले कहिल्यै इमेल ठेगाना, फोन नम्बर वा पासवर्ड दिनुपर्दैन।';

  @override
  String get privacyWhatHavenIsNoServers =>
      'Haven आफैँले पनि कुनै सर्भर चलाउँदैन। तपाईंका इन्क्रिप्टेड स्थान अपडेटहरू अरू मानिसले चलाउने, रिले भनिने स्वतन्त्र सर्भरहरूमार्फत जान्छन्। Haven का विकासकर्ताले तपाईंको स्थान देख्न सक्दैनन्, र तपाईंले एप कसरी प्रयोग गर्नुहुन्छ भन्नेबारे तिनले केही पनि संकलन गर्दैनन्।';

  @override
  String get privacyWhatHavenIsMeansForYou =>
      'तपाईंको डाटा माग्ने कोही छैन, किनभने कसैले पनि यो राखेको छैन। यसको अर्को पक्ष हो, तपाईंको खाता पुनर्स्थापना गर्न सक्ने पनि कोही छैन। के ब्याकअप गर्ने भन्ने जान्न \"तपाईंका दुई कुञ्जी\" हेर्नुहोस्।';

  @override
  String get privacyWhatHavenIsDetailNoTelemetry =>
      'एपमा कुनै एनालिटिक्स, क्र्यास रिपोर्टिङ वा विज्ञापन कोड छैन। Haven खुला स्रोत भएकाले यो कुरा भरोसामा छोड्नुको साटो जाँच्न सकिन्छ।';

  @override
  String get privacyWhatHavenIsDetailNoPush =>
      'Haven मा पुस नोटिफिकेसन पनि जानाजान राखिएको छैन। नोटिफिकेसन सेवालाई, तपाईंका सर्कलमा कसैसँग तपाईंका लागि पठाउनुपर्ने कुरा भएको हरेक पटक बताउनुपर्ने हुन्थ्यो, र त्यसले रिलेले भन्दा तपाईंका बानीबारे धेरै खुलाउँथ्यो।';

  @override
  String get privacyYourKeysTitle =>
      'तपाईंका दुई कुञ्जी: एउटा गोप्य, एउटा साझा गर्ने';

  @override
  String get privacyYourKeysSubtitle =>
      'तपाईंलाई चिनाउने कुरा, र ब्याकअप गर्नुपर्ने कुरा';

  @override
  String get privacyYourKeysWhatTheyAre =>
      'प्रयोगकर्ता नाम र पासवर्डको सट्टा तपाईंसँग कुञ्जीको एक जोडी हुन्छ। गोप्य कुञ्जीले तपाईं तपाईं नै हुनुहुन्छ भन्ने प्रमाणित गर्छ। सार्वजनिक कुञ्जी भनेको अरूले तपाईंलाई खोज्न र निमन्त्रणा गर्न प्रयोग गर्ने कुरा हो।';

  @override
  String get privacyYourKeysSecretStaysHere =>
      'तपाईंको गोप्य कुञ्जी यही फोनमा मात्र, अपरेटिङ सिस्टमले सुरक्षित राख्ने भण्डारणमा रहन्छ। Haven ले यसलाई कहीँ पठाउँदैन — न कुनै रिलेमा, न हामीलाई।';

  @override
  String get privacyYourKeysPublicIsSafe =>
      'तपाईंको सार्वजनिक कुञ्जी अरूलाई दिन सुरक्षित छ। यो तपाईंले कतै पनि राख्न सक्ने प्रयोगकर्ता नाम जस्तै काम गर्छ। यो साझा गर्दा तपाईं कहाँ हुनुहुन्छ भन्ने खुल्दैन।';

  @override
  String get privacyYourKeysMeansForYou =>
      'यो परिचय राखिरहन चाहनुहुन्छ भने आफ्नो गोप्य कुञ्जीको ब्याकअप लिनुहोस्। तपाईं यसलाई सेटिङ → परिचय → उन्नत मा हेर्न सक्नुहुन्छ। ब्याकअपबिना फोन हराए, त्यो परिचय सदाका लागि जान्छ, र कसैले पनि त्यसलाई फर्काउन सक्दैन।';

  @override
  String get privacyYourKeysNeverShareSecret =>
      'तपाईंको गोप्य कुञ्जी पाउने कोही पनि तपाईं बन्छ। तिनले तपाईंको नाममा सर्कलमा सामेल हुन वा तपाईंको नाममा प्रकाशित गर्न सक्छन्। यसलाई कहिल्यै अर्को एप, सन्देश वा वेबसाइटमा नटाँस्नुहोस्।';

  @override
  String get privacyYourKeysDetailFormats =>
      'यो जोडी एउटा secp256k1 कुञ्जी हो, जुन मानक Nostr ढाँचामा देखाइन्छ: सार्वजनिक कुञ्जीका लागि npub1… र गोप्य कुञ्जीका लागि nsec1…। हस्ताक्षर एपभित्रै हुन्छ, र गोप्य बाइटहरू हरेक प्रयोगपछि मेमोरीबाट मेटाइन्छन्।';

  @override
  String get privacyYourKeysDetailSeparation =>
      'तपाईंका सर्कलका सन्देश इन्क्रिप्ट गर्ने कुञ्जीहरू यो परिचय कुञ्जीबाट छुट्टै हुन्छन्, र एपले मात्र राख्छ। यो छुट्याउने काम जानाजान गरिएको हो: जुन कुञ्जीले तपाईंको नाम बताउँछ, त्यो कुञ्जीले तपाईंले पठाएको कुरा खोल्दैन।';

  @override
  String get privacyPublicProfileTitle =>
      'तपाईंको नाम र फोटो सार्वजनिक हुन्छन्';

  @override
  String get privacyPublicProfileSubtitle =>
      'जो कसैलाई पनि देखिन्छ, तपाईंका सर्कललाई मात्र होइन';

  @override
  String get privacyPublicProfileIsPublic =>
      'तपाईंले सेट गर्ने प्रदर्शन नाम र फोटो व्यापक Nostr सञ्जालमा प्रकाशित हुन्छन्। तपाईंका सर्कलका मानिसले मात्र होइन, जो कसैले पनि खोज्न सक्छ।';

  @override
  String get privacyPublicProfileOnSave =>
      'तपाईंले सुरक्षित गर्ने बित्तिकै यो हुन्छ। यिनलाई गोप्य राख्ने कुनै सेटिङ छैन, र नाम आफ्ना सर्कलसँग मात्र साझा गर्ने कुनै उपाय पनि छैन।';

  @override
  String get privacyPublicProfilePseudonym =>
      'नयाँ इन्स्टल गर्दा \"Quiet Wanderer\" जस्तो बनाइएको नामबाट सुरु हुन्छ, जसले तपाईंबारे केही बताउँदैन। तपाईं यही राख्न सक्नुहुन्छ, वा मन लागेको कुनै पनि नामले फेर्न सक्नुहुन्छ।';

  @override
  String get privacyPublicProfileMeansForYou =>
      'सार्वजनिक रूपमा देखाउन तपाईं सहज हुने नाम र फोटो छान्नुहोस्। चिनिन चाहनुहुन्न भने, तपाईंलाई दिइएको बनाइएको नाम त्यसै राख्नुहोस् र फोटो नराख्नुहोस्।';

  @override
  String get privacyPublicProfileRemovalIsNotDeletion =>
      'पछि आफ्नो फोटो हटाउँदा त्यो अप्रकाशित हुँदैन। Haven ले तपाईंको प्रोफाइललाई खाली प्रोफाइलले बदल्छ, तर तस्बिर फाइल त्यसलाई राख्ने सर्भरमा रहिरहन्छ, र पहिले नै डाउनलोड भइसकेका प्रतिहरू कतै न कतै रहिरहन्छन्। तपाईंले प्रकाशित गर्ने कुनै पनि कुरालाई स्थायी मान्नुहोस्।';

  @override
  String get privacyPublicProfileDetailKindZero =>
      'प्रोफाइल भनेको तपाईंको परिचय कुञ्जीले हस्ताक्षर गरिएको Nostr \"kind 0\" इभेन्ट हो। फोटोहरू कुनै Blossom होस्टमा अपलोड हुन्छन् — तपाईंले नबदलेसम्म blossom.primal.net मा — र त्यो होस्टले तस्बिर, तपाईंको सार्वजनिक कुञ्जी र तपाईंको IP ठेगाना देख्छ।';

  @override
  String get privacyPublicProfileDetailExifStripped =>
      'अपलोड गर्नुअघि Haven ले तस्बिरलाई पुनः एन्कोड गर्छ र क्यामेराले जोड्ने लुकेको डाटा हटाउँछ, जसमा फोटो खिचिएको GPS स्थिति पनि पर्छ। यसको महत्त्व यहीँ छ: नत्र बिदाको एउटा तस्बिरले तपाईंको घरको निर्देशांक बोकेर हिँड्न सक्छ।';

  @override
  String get privacyGroupHowLocationTravelsHeading =>
      'तपाईंको स्थान कुन बाटो जान्छ';

  @override
  String get privacyRelaysTitle => 'रिले: सन्देश अगाडि पुर्‍याउने सर्भरहरू';

  @override
  String get privacyRelaysSubtitle =>
      'तपाईंका अपडेट कसका कम्प्युटरमार्फत जान्छन्';

  @override
  String get privacyRelaysWhatIsARelay =>
      'Haven को आफ्नै कुनै सर्भर छैन, त्यसैले तपाईंका अपडेट अरू मानिसका सर्भरमार्फत जान्छन्। यिनलाई रिले भनिन्छ: जो कसैले चलाउन सक्ने साना, स्वतन्त्र सर्भरहरू। रिलेले इन्क्रिप्टेड सन्देश छोटो समय राख्छ, र तपाईंको सर्कलले माग्दा अगाडि हस्तान्तरण गर्छ।';

  @override
  String get privacyRelaysWhyMany =>
      'धेरै रिले प्रयोग गर्नुको अर्थ हो, कुनै एउटैले तपाईंलाई काट्न सक्दैन। एउटा अफलाइन भए पनि बाँकीले काम गरिरहन्छन्। कुन रिले प्रयोग गर्ने भन्ने तपाईं आफै छान्नुहुन्छ, र जुनसुकै बेला बदल्न सक्नुहुन्छ।';

  @override
  String get privacyRelaysTwoLists =>
      'Haven ले तपाईंका लागि दुई सूची राख्छ। तपाईंका इनबक्स रिलेहरू भनेका निमन्त्रणा तपाईंकहाँ पुग्ने ठाउँ हुन्। तपाईंका KeyPackage रिलेहरू भनेका तपाईंलाई निमन्त्रणा गर्न चाहिने कुञ्जी अरूले लिने ठाउँ हुन्। प्रत्येक सर्कलले पनि आफ्नै सूची बोक्छ, र सर्कलका इन्क्रिप्टेड अपडेटहरू त्यहीँबाट जान्छन्।';

  @override
  String get privacyRelaysMeansForYou =>
      'यहाँ बिगारेर जोखिममा पर्ने कुनै कुरा छैन: रिलेले सधैँ इन्क्रिप्टेड डाटा मात्र देख्छ। तर तपाईंलाई पुग्न सकिने कम्तीमा एउटा रिले चाहिन्छ, नत्र तपाईंलाई कसैले निमन्त्रणा गर्न सक्दैन र तपाईंका सर्कलबाट कुनै अपडेट आउँदैन।';

  @override
  String get privacyRelaysDetailIndexers =>
      'तपाईंका आफ्नै सूचीहरूभन्दा अलग, Haven ले अरू मानिसका प्रोफाइल र कुञ्जी खोज्न केही सार्वजनिक डाइरेक्टरी रिलेमा सोध्छ। तपाईंले आफ्ना लागि निजी रिले मात्र सेट गरेको भए पनि यसले तिनीहरूसँग सम्पर्क गर्छ। तिनले तपाईंको सञ्जाल ठेगाना, र तपाईंले कुन खाताबारे सोध्नुभयो भन्ने देख्छन्।';

  @override
  String get privacyRelaysDetailKeyListIsPublic =>
      'तपाईंको KeyPackage रिले सूची आफै पनि, अरूले भेट्न सकोस् भनेर तपाईंको परिचय कुञ्जीले हस्ताक्षर गरी सञ्जालमा प्रकाशित हुन्छ। त्यो सूचीमा तपाईंले कुनै निजी रिले थप्नुभयो भने, त्यसको ठेगाना सार्वजनिक हुन्छ र तपाईंसँग जोडिन्छ। कुनै एक सर्कलको आफ्नै सूचीभित्र मात्र प्रयोग हुने रिले त्यसरी सार्वजनिक रूपमा घोषित हुँदैन।';

  @override
  String get privacyEncryptionTitle => 'इन्क्रिप्शन कसरी काम गर्छ';

  @override
  String get privacyEncryptionSubtitle =>
      'प्रत्येक सर्कलका आफ्नै कुञ्जी, र मानिस आउँदा-जाँदा के बदलिन्छ';

  @override
  String get privacyEncryptionPerCircle =>
      'तपाईंको स्थान फोन छोड्नुअघि नै त्यहीँ इन्क्रिप्ट हुन्छ; यसका लागि MLS नामको एउटा खुला मानक प्रयोग हुन्छ। प्रत्येक सर्कल आफ्नै कुञ्जीसहितको आफ्नै इन्क्रिप्टेड समूह हो। सर्कलबाहिरका कसैले पनि त्यसभित्र पठाइएको कुरा पढ्न सक्दैन — न कुनै रिलेले, न Haven ले, न तपाईं सामेल भएको अर्को सर्कलले।';

  @override
  String get privacyEncryptionWhenSomeoneJoins =>
      'कोही सामेल हुँदा, सर्कल नयाँ कुञ्जीमा सर्छ। तिनले आफू आएपछि पठाइएको पढ्न सक्छन्, त्यसअघिको केही पनि पढ्न सक्दैनन्। Haven ले नयाँ सदस्यलाई विगतका स्थान कहिल्यै पठाउँदैन।';

  @override
  String get privacyEncryptionWhenSomeoneLeaves =>
      'कोही छाड्दा वा हटाइँदा, सर्कल फेरि अर्को नयाँ कुञ्जीमा सर्छ। बढीमा केही मिनेटभित्र तिनले नयाँ कुरा पढ्न सक्दैनन्।';

  @override
  String get privacyEncryptionKeysChangeOnMembership =>
      'कुञ्जी सदस्यता बदलिँदा बदलिन्छ, कुनै निश्चित अन्तरालमा होइन। दुई परिवर्तनको बीचमा पठाइएको सबै कुरा एउटै कुञ्जीले ओगट्छ। त्यसैले लामो समयदेखि कुनै परिवर्तन नभएको सर्कलबाट तपाईंले कसैलाई हटाउँदा पनि, त्यो व्यक्तिले सदस्य रहँदा सङ्ग्रह गरेका सन्देश अझै खोल्न सक्छ — हप्तौँ अघिका सन्देश पनि। तर त्यो व्यक्तिले छाडेपछि पठाइएको कुनै पनि कुरा खोल्न सक्दैन।';

  @override
  String get privacyEncryptionMeansForYou =>
      'इन्क्रिप्शनले तपाईंलाई तपाईंका सर्कलबाहिरका सबैबाट जोगाउँछ। कुनै बेला सर्कलभित्र भएको व्यक्तिबाट यो जोगाउन सक्दैन। कसैसँग पूरै नाता तोड्न चाहनुहुन्छ भने, पुरानो सर्कलबाट तिनलाई हटाउनुभन्दा नयाँ सर्कल सुरु गर्नु बढी सुरक्षित हुन्छ।';

  @override
  String get privacyEncryptionDetailMls =>
      'MLS (Messaging Layer Security) भनेको अन्य सुरक्षित मेसेन्जरले प्रयोग गर्ने त्यही IETF मानक हो। Haven ले Nostr सञ्जालसम्म Marmot प्रोटोकलमार्फत पुग्छ, र त्यही प्रोटोकलले MLS समूहहरू रिलेमा कसरी चल्छन् भन्ने निर्धारण गर्छ। प्रत्येक सर्कलले हस्ताक्षर गर्न प्रयोग गर्ने कुञ्जी तपाईंको सार्वजनिक Nostr परिचय कुञ्जीबाट छुट्टै हुन्छ।';

  @override
  String get privacyEncryptionDetailEpochs =>
      'कुञ्जीको प्रत्येक अवधिलाई एपोक भनिन्छ। तपाईंको फोनले पछिल्ला केही एपोकबाट बाटोमै रहेका सन्देश खोल्न पुग्ने सामग्री मात्र राख्छ, त्यसपछि त्यसलाई हटाउँछ — यसैले Haven ले तपाईंका पुराना सन्देश सिद्धान्ततः पनि फर्काउन सक्दैन।';

  @override
  String get privacyWhatOthersSeeTitle =>
      'सदस्यले के देख्छन्, र रिलेले के देख्छ';

  @override
  String get privacyWhatOthersSeeSubtitle =>
      'तपाईंले साझा गर्ने मानिस, र बीचमा रहने सर्भरहरू';

  @override
  String get privacyWhatOthersSeeMembersHeading => 'तपाईंका सर्कलका मानिस';

  @override
  String get privacyWhatOthersSeeMembersExact =>
      'सर्कलका सबैले नक्सामा तपाईंको ठ्याक्कै स्थान देख्छन्, अनुमानित क्षेत्र होइन। कुनै सदस्यसँग अस्पष्ट स्थान र अरूसँग ठ्याक्कै स्थान साझा गर्ने कुनै सेटिङ छैन।';

  @override
  String get privacyWhatOthersSeeCannotPause =>
      'Haven खुला छ र तपाईं कुनै सर्कलमा हुनुहुन्छ भने, तपाईंको स्थान हरेक दुई-तीन मिनेटमा आफै जान्छ। रोक्ने कुनै बटन छैन। एउटै मात्र स्विच छ: एप छाडेपछि साझा गर्ने काम जारी रहने वा नरहने।';

  @override
  String get privacyWhatOthersSeeMembersLearnKey =>
      'सर्कलमा सामेल हुँदा प्रत्येक सदस्यले तपाईंको सार्वजनिक कुञ्जी पनि देख्छ। त्यसमार्फत तिनले तपाईंको सार्वजनिक प्रोफाइल, र तपाईंले त्यो कुञ्जीअन्तर्गत कहिल्यै प्रकाशित गरेको अरू सबै कुरा खोज्न सक्छन्।';

  @override
  String get privacyWhatOthersSeeCoMemberIp =>
      'सदस्यको प्रोफाइल फोटो तिनले रोजेको सर्भरबाट ल्याइन्छ। त्यो लोड हुँदा तपाईंको सञ्जाल ठेगाना — र त्यसबाट तपाईं संसारमा लगभग कहाँ हुनुहुन्छ भन्ने — त्यो सर्भर चलाउने व्यक्तिसामु खुल्छ। यो तपाईंले कुनै पनि ट्याप नगर्दै, आफै हुन्छ।';

  @override
  String get privacyWhatOthersSeeRelaysHeading => 'रिले चलाउनेहरू';

  @override
  String get privacyWhatOthersSeeRelaysCannot =>
      'रिले चलाउनेहरूले तपाईंको स्थान, तपाईंका सन्देश, तपाईंको सर्कलको नाम वा त्यसका सदस्यको सूची पढ्न सक्दैनन्। प्रत्येक सन्देश तिनकहाँ नयाँ, एकपटक मात्र प्रयोग हुने पठाउने ठेगानाबाट पुग्छ, त्यसैले कुन सदस्यले पठायो भन्ने तिनले भन्न सक्दैनन्।';

  @override
  String get privacyWhatOthersSeeRelaysCan =>
      'तिनले तपाईंको सञ्जाल ठेगाना, तपाईं कति बेला अनलाइन हुनुहुन्छ, र तपाईंको ट्राफिक कति ठूलो र कति बारम्बार छ भन्ने देख्छन्। प्रत्येक सर्कलले एउटा अनियमित ट्याग बोक्छ, त्यसैले रिलेले एउटै सर्कलका सन्देश सँगै राख्न र त्यसमा कति मानिस छन् भन्ने अनुमान गर्न सक्छ — तिनमध्ये कोही पनि को हो भन्ने नजानिकनै।';

  @override
  String get privacyWhatOthersSeeMeansForYou =>
      'सर्कललाई तपाईंले आफ्नो घरको ठेगाना दिनुहुने मानिसको समूह मानी व्यवहार गर्नुहोस्। रिले र सर्कलबाहिरका मानिससामु इन्क्रिप्शन टिक्छ, र VPN ले सञ्जाल ठेगानाको यो प्वाल टाल्छ। स्क्रिनसट सुरक्षित गर्ने सदस्यसामु भने कुनै कुरा टिक्दैन।';

  @override
  String get privacyWhatOthersSeeDetailTag =>
      'सर्कलको ट्याग त्यो सर्कल रहेसम्म एउटै रहन्छ, त्यसैले रिलेले त्यसका सबै सन्देश अनिश्चित कालसम्म आपसमा जोड्न सक्छ। यो त्यो प्रोटोकलको गुण हो जसमा यो सबै बनेको छ, Haven ले बदल्न सक्ने कुरा होइन।';

  @override
  String get commonLearnMore => 'थप जान्नुहोस्';

  @override
  String get relaySettingsBackendCaption =>
      'Haven को आफ्नै कुनै सर्भर छैन। तपाईंका इन्क्रिप्टेड अपडेट रिले भनिने स्वतन्त्र सर्भरहरूबाट जान्छन्। तिनले तपाईंको स्थान वा तपाईंका सर्कलमा को-को छन् भन्ने कहिल्यै देख्दैनन्।';

  @override
  String get privacyWhatOthersSeeScreenshots =>
      'स्क्रिनसटको कुरा अपरेटिङ सिस्टममा भर पर्छ, र दुवै सिस्टम यसमा फरक छन्। Android मा Haven ले सम्पूर्ण एपमा स्क्रिनसट र स्क्रिन रेकर्डिङ रोक्छ। iPhone मा भने त्यसो गर्न सक्दैन: Haven ले एप स्विचरको पूर्वावलोकन धमिलो बनाउँछ, तर कुनै सदस्यले स्क्रिनमा देखिएको कुरा अझै पनि खिच्न सक्छ।';

  @override
  String get privacyWhatOthersSeeDetailExpiry =>
      'Haven ले रिलेहरूलाई स्थान सन्देश करिब चार मिनेटपछि हटाउन अनुरोध गर्छ। त्यो केवल अनुरोध हो: रिलेले तिनलाई थप लामो समय राख्न स्वतन्त्र छ। निमन्त्रणामा कुनै समयसीमा नै हुँदैन, र तिनी तपाईंको इनबक्स रिलेमा अनिश्चित कालसम्म बसिरहन सक्छन्।';

  @override
  String get privacyGroupTheLimitsHeading => 'सीमाहरू';

  @override
  String get privacyInferenceTitle => 'तपाईंबारे अझै के पत्ता लगाउन सकिन्छ';

  @override
  String get privacyInferenceSubtitle => 'इन्क्रिप्शनले छोप्न नसक्ने चिन्हहरू';

  @override
  String get privacyInferenceWhatIsMetadata =>
      'इन्क्रिप्शनले तपाईंले के पठाउनुहुन्छ भन्ने लुकाउँछ। तपाईंले केही पठाउनुभयो भन्ने कुरा भने यसले लुकाउन सक्दैन। सन्देशको वरिपरि बन्ने ढर्रा — त्यो कति बेला गयो, कति ठूलो थियो, तपाईं कुन सर्भरमा जोडिनुभएको थियो — त्यसलाई मेटाडाटा भनिन्छ, र सामग्री नदेखिँदा पनि यो देखिइरहन्छ।';

  @override
  String get privacyInferenceActivityPattern =>
      'त्यही ढर्राबाट, तपाईंले प्रयोग गर्ने रिलेले तपाईं कति बेला र कति पटक सक्रिय हुनुहुन्छ भन्ने लगभग थाहा पाउन सक्छ। तपाईं करिब सय मिटरभन्दा बढी सर्नुभएपछि Haven ले एउटा थप अपडेट पनि पठाउँछ, त्यसैले पर्याप्त लामो अभिलेखले तपाईं यात्रामा हुनुहुन्थ्यो कि एकै ठाउँमा बस्नुभएको थियो भन्ने संकेत दिन सक्छ — तर कहाँ हुनुहुन्थ्यो भन्ने कहिल्यै देखाउँदैन।';

  @override
  String get privacyInferencePresence =>
      'Haven चलिरहेको बेला यसले तपाईंका रिलेसँग जडान खुलै राख्छ, त्यसैले तिनले तपाईं अनलाइन हुनुहुन्छ र तपाईं कुन सर्कल हेरिरहनुभएको छ भन्ने पनि देख्छन्। अपडेट मिनेटमा नभई सेकेन्डमा आउनुको मूल्य यही हो।';

  @override
  String get privacyInferenceIpHeading => 'तपाईंको सञ्जाल ठेगाना';

  @override
  String get privacyInferenceIpAddress =>
      'Haven ले सम्पर्क गर्ने प्रत्येक सर्भरले तपाईंको फोन जोडिने ठेगाना देख्छ: तपाईंका रिले, नक्सा प्रदायक, र कुनै सदस्यको प्रोफाइल फोटो राख्ने जो कोही। तपाईंको इन्टरनेट प्रदायकले तपाईं तिनमध्ये कुन सर्भरमा कति बेला पुग्नुभयो भन्ने देख्छ। Haven आफैँले यी दुईमध्ये कुनै पनि लुकाउँदैन।';

  @override
  String get privacyInferenceVpnHeading => 'VPN प्रयोग गर्ने कि नगर्ने';

  @override
  String get privacyInferenceVpnHelps =>
      'VPN ले तपाईंको ठेगानाको सट्टा आफ्नै ठेगाना राख्छ, त्यसैले रिले र अन्य सर्भरले तपाईं कहाँबाट जोडिनुहुन्छ भन्ने देख्न पाउँदैनन्। तपाईं कुन सर्भरमा पुग्नुहुन्छ भन्ने कुरा यसले तपाईंको इन्टरनेट प्रदायकबाट पनि लुकाउँछ। हामी Mullvad सिफारिस गर्छौं।';

  @override
  String get privacyInferenceVpnLimits =>
      'यो सबै रोगको एउटै औषधि होइन। VPN ले तपाईंका सर्कल सदस्यले देख्ने कुरा कत्ति पनि बदल्दैन, र तपाईंले कुरा गरिरहेको रिलेबाट तपाईंको ट्राफिकको समय र आकार लुकाउँदैन। यसले कसैलाई पनि विश्वास गर्नुपर्ने आवश्यकता हटाउँदैन, बरु तपाईंको विश्वास VPN प्रदायकतर्फ सार्छ।';

  @override
  String get privacyInferenceMeansForYou =>
      'तपाईंको चिन्ता कुनै व्यक्तिले नभई सञ्जाल चलाउने कसैले तपाईंलाई नक्सामा राख्ने हो भने, VPN थप्न सकिने सबैभन्दा उपयोगी कुरा हो। तपाईंको चिन्ता आफ्ना सर्कलका मानिसको हो भने, यसले कत्ति पनि मद्दत गर्दैन।';

  @override
  String get privacyInferenceDetailJitter =>
      'Haven ले अपडेटबीचको अन्तराल जानाजान फेरबदल गर्छ, त्यसैले छोटो अभिलेखमा कुनै सफा लय देखिँदैन। तर धेरै घण्टाको औसत निकाल्दा अपडेटको मूल दर अझै अनुमान गर्न सकिन्छ। सन्देशको आकार पनि एकनासको बनाइँदैन, र स्थान अपडेट आकारको साँघुरो दायराभित्र पर्छन्, जसले तिनलाई स्थान अपडेट भनी चिन्न सकिने बनाउँछ।';

  @override
  String get privacyInferenceDetailOutOfScope =>
      'कतिपय कुरा Haven ले सम्बोधन गर्न सक्ने दायराभित्रै पर्दैनन्। एकैचोटि धेरै रिले हेर्न सक्ने कुनै निगरानीकर्ता, वा अरू कसैको नियन्त्रणमा पुगेको तपाईंको आफ्नै फोन — यहाँको कुनै पनि डिजाइन छनोटले यी कुरा समाधान गर्न सक्दैन।';

  @override
  String get commonClearAll => 'सबै हटाउनुहोस्';

  @override
  String commonMemberCount(int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$countString सदस्य',
      one: '१ सदस्य',
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
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    return 'चयन गरिएको ($countString)';
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
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$countString सदस्यलाई निमन्त्रणा गरिनेछ',
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
    final intl.NumberFormat percentNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String percentString = percentNumberFormat.format(percent);

    return '$percentString प्रतिशत पूरा';
  }

  @override
  String nameCircleCreatedSnack(String name, int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'सर्कल \"$name\" बनाइयो! $countString निमन्त्रणा पठाइयो।',
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
    final intl.NumberFormat sentNumberFormat = intl.NumberFormat.decimalPattern(
      localeName,
    );
    final String sentString = sentNumberFormat.format(sent);
    final intl.NumberFormat totalNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String totalString = totalNumberFormat.format(total);

    return 'निमन्त्रणा पठाइयो ($sentString मध्ये $totalString)। बाँकीको डेलिभरी विचाराधीन छ।';
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
  String get pendingMemberNeedsUpdate => 'Haven अपडेट गर्नुपर्छ';

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
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    return '+$countString थप';
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
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    return '$circleName मा सामेल हुने निमन्त्रणा, $inviter ले निमन्त्रणा गरेको, $countString सदस्य';
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
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$countString सदस्य',
      one: '१ सदस्य',
    );
    return '$_temp0';
  }

  @override
  String get invitationCardJustNow => 'भर्खरै';

  @override
  String invitationCardDaysAgo(int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    return '${countString}d अघि';
  }

  @override
  String invitationCardHoursAgo(int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    return '${countString}h अघि';
  }

  @override
  String invitationCardMinutesAgo(int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    return '${countString}m अघि';
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
  String get circleBlockedBannerTitle => 'यो सर्कल अपडेट गर्न सकिँदैन';

  @override
  String get circleBlockedBannerBody =>
      'यो सर्कलको इन्क्रिप्शनमा केही गडबड भयो, त्यसैले Haven ले अब यसमा अपडेट पठाउन वा प्राप्त गर्न सक्दैन। तपाईंले अन्तिम पटक थाहा पाएको कुरा तल अझै हेर्न सक्नुहुन्छ, वा सर्कल छोड्न सक्नुहुन्छ।';

  @override
  String get legacyCircleBannerTitle => 'यो सर्कल फेरि बनाउनुपर्छ';

  @override
  String get legacyCircleBannerBody =>
      'Haven को इन्क्रिप्शन इन्जिन अपग्रेड गरिएको छ, त्यसैले यो सर्कल अब प्रयोग गर्न सकिँदैन। उही व्यक्तिहरूसँग स्थान साझेदारी जारी राख्न यसलाई फेरि बनाउनुहोस् — तपाईंले तिनीहरूलाई फेरि निमन्त्रणा दिनुपर्नेछ।';

  @override
  String get legacyCircleRecreateCta => 'सर्कल फेरि बनाउनुहोस्';

  @override
  String get legacyCircleRemoveCta => 'हटाउनुहोस्';

  @override
  String get legacyCircleRemoveDialogTitle => 'सर्कल हटाउने?';

  @override
  String get legacyCircleRemoveDialogBody =>
      'यो सर्कल अब प्रयोग गर्न सकिँदैन र तपाईंको सूचीबाट हटाइनेछ। यसको सट्टा तपाईंले बनाउने कुनै पनि नयाँ सर्कललाई यसले असर गर्दैन।';

  @override
  String get legacyCircleRemoveConfirm => 'हटाउनुहोस्';

  @override
  String get legacyCutoverExplainerTitle => 'Haven अपडेट भएको छ';

  @override
  String get legacyCutoverExplainerIdentityUnchanged =>
      'तपाईंको परिचय र सार्वजनिक प्रोफाइल जस्ताको तस्तै छन् — तिनका लागि तपाईंले केही गर्नुपर्दैन।';

  @override
  String get legacyCutoverExplainerCirclesNeedRecreation =>
      'राम्रो सुरक्षाका लागि, तपाईंका सर्कलहरू फेरि बनाउनु र तिनका सदस्यहरूलाई फेरि निमन्त्रणा दिनुपर्नेछ; त्यसपछि मात्र तपाईंले तिनमा फेरि स्थान साझा गर्न सक्नुहुन्छ।';

  @override
  String get legacyCutoverExplainerAcknowledge => 'बुझेँ';

  @override
  String get relaySettingsLegacyRetractionPending =>
      'Haven ले भर्खरैको सुरक्षा अपडेटबाट केही डाटा अझै सफा गर्दै छ। तपाईं फेरि अनलाइन हुनासाथ यो स्वतः पूरा हुनेछ।';

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
  String get refreshRingSemanticNoInbox =>
      'कुनै इनबक्स कन्फिगर गरिएको छैन, रिले सेटिङहरू खोल्छ';

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
      other: '$totalString मध्ये $checkedString रिले जाँचिए',
      one: '1 मध्ये $checkedString रिले जाँचियो',
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
      other: 'सबै $totalString रिलेले जवाफ दिए',
      one: 'रिलेले जवाफ दियो',
    );
    return '$_temp0';
  }

  @override
  String get refreshRingSemanticAllError => 'कुनै रिलेले जवाफ दिएन';

  @override
  String refreshRingSemanticPartial(int ok, int total) {
    final intl.NumberFormat okNumberFormat = intl.NumberFormat.decimalPattern(
      localeName,
    );
    final String okString = okNumberFormat.format(ok);
    final intl.NumberFormat totalNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String totalString = totalNumberFormat.format(total);

    return '$totalString मध्ये $okString रिलेले जवाफ दिए';
  }

  @override
  String get refreshRingAnnouncementChecking => 'रिलेहरू जाँच्दै';

  @override
  String get refreshRingAnnouncementAllOk => 'सबै रिलेले जवाफ दिए';

  @override
  String refreshRingAnnouncementPartial(int ok, int total) {
    final intl.NumberFormat okNumberFormat = intl.NumberFormat.decimalPattern(
      localeName,
    );
    final String okString = okNumberFormat.format(ok);
    final intl.NumberFormat totalNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String totalString = totalNumberFormat.format(total);

    return '$totalString मध्ये $okString रिलेले जवाफ दिए';
  }

  @override
  String get refreshRingAnnouncementAllError => 'कुनै पनि रिलेमा पुग्न सकिएन';

  @override
  String get refreshRingAnnouncementNoInbox => 'कुनै इनबक्स कन्फिगर गरिएको छैन';

  @override
  String refreshRingSemanticAllFound(int total) {
    final intl.NumberFormat totalNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String totalString = totalNumberFormat.format(total);

    String _temp0 = intl.Intl.pluralLogic(
      total,
      locale: localeName,
      other: 'सबै $totalString रिलेमा तपाईंको डेटा छ',
      one: 'रिलेमा तपाईंको डेटा छ',
    );
    return '$_temp0';
  }

  @override
  String get refreshRingSemanticNoneFound => 'कुनै रिलेमा तपाईंको डेटा छैन';

  @override
  String refreshRingSemanticPartialFound(int ok, int total) {
    final intl.NumberFormat okNumberFormat = intl.NumberFormat.decimalPattern(
      localeName,
    );
    final String okString = okNumberFormat.format(ok);
    final intl.NumberFormat totalNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String totalString = totalNumberFormat.format(total);

    return '$totalString मध्ये $okString रिलेमा तपाईंको डेटा छ';
  }

  @override
  String get refreshRingAnnouncementAllFound => 'सबै रिलेमा तपाईंको डेटा छ';

  @override
  String refreshRingAnnouncementPartialFound(int ok, int total) {
    final intl.NumberFormat okNumberFormat = intl.NumberFormat.decimalPattern(
      localeName,
    );
    final String okString = okNumberFormat.format(ok);
    final intl.NumberFormat totalNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String totalString = totalNumberFormat.format(total);

    return '$totalString मध्ये $okString रिलेमा तपाईंको डेटा छ';
  }

  @override
  String get refreshRingAnnouncementNoneFound => 'कुनै रिलेमा तपाईंको डेटा छैन';

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
  String get profileIsPublicNoticeTitle => 'प्रोफाइल सार्वजनिक छ';

  @override
  String get profileIsPublicNoticeBody =>
      'तपाईंको प्रदर्शन नाम र फोटो Nostr सञ्जालमा जो कसैलाई पनि देखिन्छन्, तपाईंका सर्कलका सदस्यलाई मात्र होइन। सार्वजनिक बनाउन तपाईं सहज हुनुहुने कुरा मात्र साझा गर्नुहोस्।';

  @override
  String get identityRefreshProfileTooltip =>
      'सार्वजनिक प्रोफाइल ताजा गर्नुहोस्';

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
      'तपाईंको सार्वजनिक कुञ्जी साझा गर्न सुरक्षित प्रयोगकर्ता नाम जस्तै काम गर्छ। मानिसहरूले तपाईंलाई सर्कलमा निमन्त्रणा गर्न यो कोड स्क्यान गर्छन्, वा तपाईंको सार्वजनिक कुञ्जी टाँस्छन्। यो साझा गर्दा तपाईंको स्थान उजागर हुन सक्दैन, जुन तपाईं सामेल भएका सर्कलका सदस्यलाई मात्र देखिन्छ। तपाईंको प्रदर्शन नाम र फोटो पहिले नै सार्वजनिक छन्, त्यसैले यो साझा गर्दा तिनका बारेमा थप केही उजागर हुँदैन।';

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
  String get circleMemberPublicKeyCopied =>
      'सार्वजनिक कुञ्जी क्लिपबोर्डमा प्रतिलिपि गरियो';

  @override
  String get circleMemberCopyPublicKeyHint =>
      'सार्वजनिक कुञ्जी प्रतिलिपि गर्नुहोस्';

  @override
  String get circleMemberSetNicknameMenuItem => 'उपनाम सेट गर्नुहोस्';

  @override
  String get circleMemberCopyPublicKeyMenuItem =>
      'सार्वजनिक कुञ्जी प्रतिलिपि गर्नुहोस्';

  @override
  String get memberProfileRefreshErrorGeneric =>
      'प्रोफाइलहरू ताजा गर्न सकिएन। कृपया फेरि प्रयास गर्नुहोस्।';

  @override
  String get memberDetailSheetTitle => 'सदस्य विवरण';

  @override
  String get memberNicknameSheetHint => 'उपनाम लेख्नुहोस्';

  @override
  String get memberNicknameSheetLabel => 'उपनाम';

  @override
  String get memberNicknameSheetSave => 'उपनाम सुरक्षित गर्नुहोस्';

  @override
  String get memberNicknameSheetClear => 'उपनाम हटाउनुहोस्';

  @override
  String get memberNicknameSheetSavedAnnouncement => 'उपनाम सुरक्षित गरियो';

  @override
  String get memberNicknameSheetClearedAnnouncement => 'उपनाम हटाइयो';

  @override
  String get npubQrScanLabel => 'मलाई थप्न स्क्यान गर्नुहोस्';

  @override
  String get npubQrSemanticsLabel => 'तपाईंको सार्वजनिक परिचयको QR कोड';

  @override
  String get photoHeaderRemoveTitle => 'प्रोफाइल फोटो हटाउने?';

  @override
  String get photoHeaderRemoveBody =>
      'यसले तपाईंको सार्वजनिक प्रोफाइलबाट तपाईंको फोटो हटाउँछ।';

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
      'फोटो अपडेट गरियो — तपाईंको सार्वजनिक Nostr प्रोफाइलमा प्रकाशित गरियो।';

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
    final intl.NumberFormat metersNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String metersString = metersNumberFormat.format(meters);

    return '. शुद्धता: $metersString मिटर';
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
      other: '$countString मिनेट अघि',
      one: '१ मिनेट अघि',
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
      other: '$countString घन्टा अघि',
      one: '१ घन्टा अघि',
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
      other: '$countString दिन अघि',
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
  String memberMarkerOffScreenSemantics(String name, String direction) {
    return '$name स्क्रिनबाहिर $directionतिर छन्, हेर्न ट्याप गर्नुहोस्';
  }

  @override
  String memberMarkerOffScreenGenericSemantics(String direction) {
    return 'एक सदस्य स्क्रिनबाहिर $directionतिर छन्, हेर्न ट्याप गर्नुहोस्';
  }

  @override
  String get compassNorth => 'उत्तर';

  @override
  String get compassNorthEast => 'उत्तर-पूर्व';

  @override
  String get compassEast => 'पूर्व';

  @override
  String get compassSouthEast => 'दक्षिण-पूर्व';

  @override
  String get compassSouth => 'दक्षिण';

  @override
  String get compassSouthWest => 'दक्षिण-पश्चिम';

  @override
  String get compassWest => 'पश्चिम';

  @override
  String get compassNorthWest => 'उत्तर-पश्चिम';

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
