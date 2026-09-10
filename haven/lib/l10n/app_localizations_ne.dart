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
  String get onboardingValueProp2Title => 'कसैले पनि यसलाई बन्द गर्न सक्दैन';

  @override
  String get onboardingValueProp3Title => 'खाता आवश्यक छैन';

  @override
  String get onboardingValueProp1Summary =>
      'तपाईंको यन्त्रमै इन्क्रिप्ट हुन्छ, त्यसैले तपाईंले छानेका सर्कलहरूले मात्र पढ्न सक्छन्।';

  @override
  String get onboardingValueProp2Summary =>
      'कुनै केन्द्रीय सर्भर छैन। यो तपाईंले छानेको रिले सञ्जालमा चल्छ।';

  @override
  String get onboardingValueProp3Summary =>
      'इमेल, फोन वा साइन-अप छैन। तपाईंको गोप्य कुञ्जी कहिल्यै फोनबाट बाहिर जाँदैन।';

  @override
  String get onboardingCreateIdentityTitle => 'आफ्नो परिचय बनाउनुहोस्';

  @override
  String get onboardingCreateIdentityBody =>
      'Haven ले तपाईंका कुञ्जी यही फोनमा बनाउँछ। गोप्य कुञ्जीले यो फोन कहिल्यै छोड्दैन।';

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
  String get settingsRelaysTitle => 'रिलेहरू';

  @override
  String get settingsLocationTitle => 'स्थान';

  @override
  String get settingsLocationSubtitleOn => 'पृष्ठभूमि साझेदारी सक्रिय छ';

  @override
  String get settingsLocationSubtitleOff => 'Haven खुला रहेको बेला मात्र';

  @override
  String get settingsMapStyleTitle => 'नक्सा शैली';

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
      'जहाँ निमन्त्रणा तपाईंकहाँ पुग्छन् (kind 10050)';

  @override
  String get relaySettingsKeyPackageTitle => 'मेरा KeyPackage रिलेहरू';

  @override
  String get relaySettingsKeyPackageSubtitle =>
      'जहाँ अरूले तपाईंलाई निमन्त्रणा गर्न चाहिने कुञ्जी फेला पार्छन् (kind 10002)';

  @override
  String get relaySettingsProfileTitle => 'मेरा प्रोफाइल रिलेहरू';

  @override
  String get relaySettingsProfileSubtitle =>
      'जहाँ तपाईंको सार्वजनिक प्रोफाइल खोजिन्छ र प्रकाशित हुन्छ। यी रिलेहरू तपाईंका अन्य रिलेबाट छुट्टै राखिन्छन्, र तपाईंका प्रोफाइल रिलेहरूको सूची कहिल्यै प्रकाशित हुँदैन (kind 0)';

  @override
  String get relaySettingsProfileUnderflowTitle => 'प्रोफाइल खोजी रोकिएको छ';

  @override
  String get relaySettingsProfileUnderflowMessage =>
      'प्रोफाइल रिलेहरू धेरै थोरै बाँकी छन्, त्यसैले सदस्यहरूका नाम र फोटो अपडेट हुन छाड्नेछन्।';

  @override
  String get relaySettingsProfileUnderflowRestoreButton =>
      'पूर्वनिर्धारित प्रोफाइल रिले फर्काउनुहोस्';

  @override
  String get relaySettingsLoadRelaysError => 'रिलेहरू लोड गर्न सकिएन।';

  @override
  String get relaySettingsAddRelay => 'रिले थप्नुहोस्';

  @override
  String get relaySettingsRestoreDefaults =>
      'पूर्वनिर्धारित रिलेहरू पुनर्स्थापना गर्नुहोस्';

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
  String get relaySettingsProfileContaminationTooltip =>
      'Haven को अन्य ट्राफिक पनि यसैबाट जान्छ';

  @override
  String relaySettingsProfileContaminationSemantics(String url) {
    return 'चेतावनी: $url बाट तपाईंको अन्य Haven ट्राफिक पनि जान्छ, जसले गर्दा यो रिलेले तपाईंको प्रोफाइललाई त्यो ट्राफिकसँग जोड्न सक्छ';
  }

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
  String get locationSettingsBatteryOptNote =>
      'Haven का लागि ब्याट्री अप्टिमाइजेसन अझै सक्रिय छ। केही फोनले कुनै चेतावनी नदिई पृष्ठभूमि साझेदारी रोक्न यसैको प्रयोग गर्छन्। साझेदारी भरपर्दो राख्न Haven लाई यसबाट छुट दिनुहोस्।';

  @override
  String get locationSettingsErrorSnack => 'केही गडबड भयो';

  @override
  String get locationSettingsIntro =>
      'एप खुला रहेको बेला Haven ले तपाईंको स्थान तपाईंका सर्कलसँग साझा गर्छ। यसलाई सक्रिय गर्नुभयो भने Haven पृष्ठभूमिमा हुँदा पनि तपाईंका सर्कलले यो देखिरहन्छन्। सिस्टमले Haven बन्द गर्‍यो भने तपाईंको आफ्नो साझेदारी रोकिन्छ: Haven ले तपाईंका सर्कलका स्थान ल्याउन त ब्यूँझन सक्छ, तर तपाईंको आफ्नो स्थान पठाउन कहिल्यै ब्यूँझँदैन। Android मा, Haven लाई स्वाइप गरेर हालैका एपको सूचीबाट हटाए पनि साझेदारी चलिरहन्छ, र फोन पुनः सुरु भएपछि साझेदारी आफैँ फेरि सुरु हुन्छ। iPhone मा भने तपाईंले Haven नखोलेसम्म साझेदारी रोकिएकै रहन्छ।';

  @override
  String get locationSettingsToggleTitle => 'पृष्ठभूमिमा साझा गर्नुहोस्';

  @override
  String get locationSettingsToggleSubtitle =>
      'Haven पृष्ठभूमिमा चलिरहँदा पनि साझा गरिरहनुहोस्';

  @override
  String get locationSettingsIosLimitedNote =>
      'तपाईंको हालको अनुमतिमै साझेदारी पृष्ठभूमिमा पनि चलिरहन्छ, र त्यस बेला iOS ले स्क्रिनको सबैभन्दा माथि आफ्नो निलो स्थान पट्टी देखाउँछ। सेटिङमा Haven का लागि स्थानलाई \'सधैँ\' मा सेट गर्नुहोस्। यसो गर्दा iOS ले एप बन्द गरेपछि पनि Haven ले तपाईंका सर्कलका छुटेका स्थान ल्याउन सक्छ। \'सधैँ\' मा भने iOS ले त्यो पट्टीको साटो स्थिति-पट्टीमा आफ्नो स्थान तीर देखाउन सक्छ। तपाईंको आफ्नो साझेदारी चाहिँ तपाईंले Haven फेरि खोलेपछि मात्र सुरु हुन्छ।';

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
      'पृष्ठभूमि साझेदारी सक्रिय हुँदा, Haven ले स्थानको सत्र चालु राख्छ, ताकि तपाईंका सर्कलले तपाईंलाई देखिरहन सकून्।';

  @override
  String get locationSettingsIosIndicatorArrow =>
      'Haven ले तपाईंको स्थान प्रयोग गरिरहेका बेला iOS ले स्थिति-पट्टीमा आफ्नो स्थान तीर देखाउँछ, र त्यसपछि केही समयसम्म त्यही तीर \"Location Services\" मा Haven कै छेउमा राखिरहन्छ।';

  @override
  String get locationSettingsIosIndicatorBar =>
      'तपाईंको \'सधैँ\' अनुमतिका साथ, Haven ले तपाईंको स्थान प्रयोग गरिरहेका बेला iOS ले स्क्रिनको सबैभन्दा माथि आफ्नो निलो स्थान पट्टी देखाउँछ।';

  @override
  String get locationDisclosureTitle => 'तपाईंको स्थानको साझेदारी';

  @override
  String get locationDisclosureWhy =>
      'Haven ले तपाईंको लाइभ स्थान तपाईंले छानेका सर्कलका मानिसहरूलाई देखाउँछ, र तिनको स्थान तपाईंलाई नक्सामा देखाउँछ। यसका लागि Haven लाई तपाईंको यन्त्रको सटीक स्थान प्रयोग गर्ने अनुमति चाहिन्छ।';

  @override
  String get locationDisclosureHow =>
      'तपाईंको स्थान तपाईंकै यन्त्रमा एन्ड-टु-एन्ड इन्क्रिप्ट हुन्छ, त्यसैले तपाईंले छानेका सर्कलका सदस्यहरूले मात्र यो पढ्न सक्छन् — Haven ले होइन। Haven को आफ्नै कुनै सर्भर छैन: तपाईंका इन्क्रिप्टेड अपडेट अरू मानिसहरूले चलाउने स्वतन्त्र रिलेहरू हुँदै जान्छन्, जसले तपाईंको नेटवर्क ठेगाना त देख्छन् तर तपाईं कहाँ हुनुहुन्छ भन्ने कहिल्यै देख्दैनन्। नक्सा कोर्न तपाईं र तपाईंको सर्कलको वरपरका क्षेत्र Stadia Maps सँग मागिन्छन्, त्यसैले ती क्षेत्र लगभग कहाँ छन् भन्ने Stadia Maps लाई थाहा हुन्छ, तर तपाईंको नाम, तपाईंको कुञ्जी वा तपाईंका सर्कलमा को-को छन् भन्ने कहिल्यै थाहा हुँदैन। Stadia Maps को भनाइअनुसार, उसले व्यक्तिगत जानकारी बेच्दैन वा साट्दैन, तपाईंको यन्त्रमा कुनै कुकी राख्दैन, र सर्भरका लग करिब दुई हप्ता राख्छ — यो उसको आफ्नै नीति हो, जसलाई Haven ले लागू गराउन सक्दैन।';

  @override
  String get locationDisclosureSharing =>
      'Haven खुला रहेसम्म र तपाईं कुनै सर्कलमा हुनुहुँदासम्म तपाईंको स्थान हरेक केही मिनेटमा आफैँ पठाइन्छ। यसलाई रोकेर राख्ने कुनै विकल्प छैन। कुनै सर्कलसँग साझेदारी रोक्न त्यो सर्कल छोड्नुहोस्।';

  @override
  String get locationDisclosureBackgroundAndroid =>
      'यो एपले स्थान डाटा प्रयोग गर्छ, ताकि एप बन्द हुँदा वा प्रयोगमा नहुँदा पनि तपाईंका सर्कलसँग साझेदारी हुन सकोस्।';

  @override
  String get locationDisclosureBackgroundIos =>
      'यो एपले स्थान डाटा प्रयोग गर्छ, ताकि Haven पृष्ठभूमिमा हुँदा र तपाईंले यसलाई प्रयोग नगरिरहेका बेला पनि तपाईंका सर्कलसँग साझेदारी हुन सकोस्। iOS ले Haven बन्द गर्‍यो भने तपाईंको आफ्नो साझेदारी तपाईंले फेरि नखोलेसम्म रोकिन्छ: Haven ले तपाईंका सर्कलका स्थान ल्याउन त ब्यूँझन सक्छ, तर तपाईंको आफ्नो स्थान पठाउन कहिल्यै ब्यूँझँदैन।';

  @override
  String get locationDisclosureManage =>
      'तपाईं पृष्ठभूमि साझेदारी जुनसुकै बेला सेटिङ → स्थानबाट बन्द गर्न सक्नुहुन्छ।';

  @override
  String get locationDisclosureAgree => 'सहमत छु';

  @override
  String get locationDisclosureNotNow => 'अहिले होइन';

  @override
  String get fgsNotificationSharing =>
      'Haven ले स्थान अपडेट पठाउँदै र प्राप्त गर्दै छ';

  @override
  String get fgsNotificationPaused =>
      'Haven अहिले रोकिएको छ — साझेदारी फेरि सुरु गर्न एप खोल्नुहोस्';

  @override
  String get fgsNotificationOpen => 'Haven अहिले खुला छ';

  @override
  String get fgsChannelName => 'स्थान साझेदारी';

  @override
  String get fgsChannelDescription =>
      'Haven लाई तपाईंको इन्क्रिप्टेड स्थान पृष्ठभूमिमा साझा गरिरहन दिन्छ।';

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
  String get aboutFooterLicense => 'MIT License अन्तर्गत इजाजतपत्र प्राप्त';

  @override
  String aboutFooterVersion(String version) {
    return 'संस्करण $version';
  }

  @override
  String get relaySettingsBackendCaption =>
      'Haven को आफ्नै कुनै सर्भर छैन। तपाईंका इन्क्रिप्टेड अपडेट रिले भनिने स्वतन्त्र सर्भरहरूमार्फत जान्छन्, जसले तपाईंको स्थान वा तपाईंका सन्देश पढ्न सक्दैनन्।';

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
  String get createCircleNoIdInQr => 'QR कोडमा कुनै वैध ID फेला परेन';

  @override
  String get createCircleNoAccountFound =>
      'यो ID का लागि कुनै Haven खाता फेला परेन';

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
      'यस सर्कलका सबैले एकआपसको स्थान, र एकआपसको सार्वजनिक नाम र फोटो देख्न सक्छन्। तपाईंको नाम र फोटो Nostr सञ्जालमा सार्वजनिक हुन्छन्, यस सर्कलभित्र मात्र सीमित हुँदैनन्। यो सर्कल तपाईं भएका अन्य सर्कलहरूबाट अलग रहन्छ, त्यसैले यसका सदस्यले तपाईंका अन्य सर्कल वा तिनमा को छन् भन्ने देख्न सक्दैनन्।';

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
  String nameCircleCreatedPartialSnack(String name, int sent, int total) {
    final intl.NumberFormat sentNumberFormat = intl.NumberFormat.decimalPattern(
      localeName,
    );
    final String sentString = sentNumberFormat.format(sent);
    final intl.NumberFormat totalNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String totalString = totalNumberFormat.format(total);

    return 'सर्कल \"$name\" बनाइयो। निमन्त्रणा पठाइयो ($totalString मध्ये $sentString); बाँकीको डेलिभरी विचाराधीन छ।';
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
  String nameCircleRosterFullError(int limit) {
    final intl.NumberFormat limitNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String limitString = limitNumberFormat.format(limit);

    return 'तपाईं एकै समयमा $limitString सर्कलमा मात्र रहन सक्नुहुन्छ। नयाँ सर्कलका लागि ठाउँ खाली गर्न कुनै एक सर्कल छोड्नुहोस्।';
  }

  @override
  String addMemberTitle(String circleName) {
    return '$circleName मा थप्नुहोस्';
  }

  @override
  String get addMemberInfo =>
      'तिनले स्वीकार गरेपछि त्यही बेलादेखि उताको सबैको स्थान देख्नेछन्, तिनी सामेल हुनुअघि पठाइएको कुनै पनि कुरा देख्दैनन्। यस सर्कलमा पहिले नै रहेका सबैका सार्वजनिक कुञ्जी पनि तिनले देख्नेछन्।';

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

    return 'निमन्त्रणा पठाइयो ($totalString मध्ये $sentString)। बाँकीको डेलिभरी विचाराधीन छ।';
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
  String get circleMemberNoRecentLocation => 'हालसालैको कुनै स्थान छैन';

  @override
  String get circleMemberRemoveTooltip => 'सर्कलबाट हटाउनुहोस्';

  @override
  String circleMemberRemoveDialogTitle(String name) {
    return '$name लाई हटाउने?';
  }

  @override
  String get circleMemberRemoveDialogBody =>
      'बाँकी सर्कल यो परिवर्तनसम्म आइपुगेपछि तिनले यो सर्कलको नयाँ कुनै पनि कुरा पढ्न सक्दैनन्; प्रायः यो केही मिनेटभित्रै हुन्छ, र त्यति बेला अफलाइन रहेको कसैका लागि यसमा बढी समय लाग्छ। तिनले पहिले नै पाइसकेको कुरा तिनकै फोनमा रहन्छ। यो पूर्ववत् गर्न तिनलाई फेरि निमन्त्रणा पठाउनुपर्छ।';

  @override
  String get circleMemberRemoveConfirm => 'हटाउनुहोस्';

  @override
  String circleMemberRemoveInProgress(String name) {
    return '$name लाई हटाइँदै छ…';
  }

  @override
  String circleMemberRemoveSuccess(String name) {
    return '$name लाई सर्कलबाट हटाइयो';
  }

  @override
  String circleMemberRemoveError(String name) {
    return '$name लाई हटाउन सकिएन। केही परिवर्तन भएन — आफ्नो जडान जाँचेर फेरि प्रयास गर्नुहोस्।';
  }

  @override
  String get circleMemberAdmin => 'एडमिन';

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
  String get pendingMemberRemoveTooltip => 'सूचीबाट हटाउनुहोस्';

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
  String get memberPickerSectionRoster => 'तपाईंका सर्कलका सदस्यहरू';

  @override
  String get memberPickerTierRoster => 'तपाईंका सर्कलका सदस्य';

  @override
  String get memberPickerNoMatches => 'तपाईंका सर्कलमा मिल्ने कोही फेला परेन';

  @override
  String get memberPickerLoading => 'तपाईंका सर्कलका मानिसहरू लोड गर्दै';

  @override
  String get memberPickerDirectoryUnavailable =>
      'तपाईंका सर्कलका मानिसहरूको सूची अहिलेलाई लोड गर्न सकिएन';

  @override
  String memberPickerMatchesAnnouncement(int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    return 'मिल्ने व्यक्ति: $countString';
  }

  @override
  String get memberPickerReasonSelf => 'यो तपाईंको आफ्नै ID हो';

  @override
  String get memberPickerReadPublicKey => 'सार्वजनिक कुञ्जी पढेर सुनाउनुहोस्';

  @override
  String get memberPickerSectionRecent => 'हालसालै तपाईंका सर्कलमा रहेकाहरू';

  @override
  String get memberPickerTierRecent => 'हालसालै तपाईंका सर्कलमा';

  @override
  String get memberPickerNicknameNote =>
      'तपाईंले राखेको उपनाम, तिनको सार्वजनिक नाम होइन';

  @override
  String memberPickerCollisionCircleLabel(String circleName) {
    return 'सर्कल: $circleName';
  }

  @override
  String get memberPickerStrangerLookupNote =>
      'Haven ले एउटा रिलेलाई यी व्यक्तिको प्रकाशित नाम सोध्यो। यो यन्त्रले भर्खरै यही कुञ्जीबारे सोधेको कुरा त्यो रिलेले देख्छ — तर यो अनुरोधले कुनै हस्ताक्षर बोक्दैन, त्यसैले यो तपाईंको Haven परिचयसँग जोडिँदैन। अहिलेसम्म कुनै फोटो डाउनलोड भएको छैन।';

  @override
  String selectedMembersMore(int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    return '+$countString थप';
  }

  @override
  String get invitationCardHeading => 'कुनै सर्कलको निमन्त्रणा';

  @override
  String invitationCardSemantics(String inviter) {
    return 'एउटा सर्कलमा सामेल हुने निमन्त्रणा, $inviter बाट आएको हो';
  }

  @override
  String invitationCardInvitedBySemantics(String inviter) {
    return 'क्रिप्टोग्राफिक पहिचानकर्ता $inviter बाट आएको निमन्त्रणा';
  }

  @override
  String invitationCardInvitedBy(String inviter) {
    return 'निमन्त्रणा गर्ने: $inviter';
  }

  @override
  String get invitationCardNicknameNote =>
      'तपाईंले राखेको उपनाम, तिनको सार्वजनिक नाम होइन';

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
  String invitationRosterFullError(int limit) {
    final intl.NumberFormat limitNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String limitString = limitNumberFormat.format(limit);

    return 'तपाईं एकै समयमा $limitString सर्कलमा मात्र रहन सक्नुहुन्छ। यो निमन्त्रणा बाँकी रहन्छ: कुनै एक सर्कल छोड्नुहोस्, त्यसपछि यसलाई स्वीकार गर्नुहोस्।';
  }

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
  String circleDetailsMembersWithEpoch(String members, int epoch) {
    final intl.NumberFormat epochNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String epochString = epochNumberFormat.format(epoch);

    return '$members · एपोक $epochString';
  }

  @override
  String circleDetailsMetaWithExpiry(String meta, String expiry) {
    return '$meta · समयसीमा $expiry';
  }

  @override
  String circleDetailsExpiryMinutesShort(int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$countString मिनेट',
      one: '$countString मिनेट',
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
      other: '$countString सेकेन्ड',
      one: '$countString सेकेन्ड',
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
      other: 'करिब $countString मिनेट',
      one: 'करिब $countString मिनेट',
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
      other: '$countString सेकेन्ड',
      one: '$countString सेकेन्ड',
    );
    return '$_temp0';
  }

  @override
  String circleDetailsExpirySemantics(String meta, String expiry) {
    return '$meta। Haven ले रिलेहरूलाई तपाईंले यो सर्कलमा पठाउने स्थान अपडेटहरू $expiry पछि हटाउन अनुरोध गर्छ।';
  }

  @override
  String get circleDetailsRelaysHeading => 'यस सर्कलका रिलेहरू';

  @override
  String get circleDetailsNoRelays => '(कुनै अभिलेख छैन)';

  @override
  String get circleDetailsRelaysNote =>
      'यी रिले निमन्त्रित सदस्यहरूका प्रकाशित सूचीबाट आएका हुन्; ती सदस्यहरूको सूची नभए तपाईंका इनबक्स रिले वा Haven ले रोजेका रिले प्रयोग भए। यिनलाई अहिलेसम्म बदल्न मिल्दैन, र तपाईंको रिले सूचीमा पछिका सम्पादनले यिनलाई बदल्दैन।';

  @override
  String get circleDetailsAddMember => 'सदस्य थप्नुहोस्';

  @override
  String get circleDetailsLeaveCircle => 'सर्कल छोड्नुहोस्';

  @override
  String get leaveCircleDialogTitle => 'सर्कल छोड्नुहोस्';

  @override
  String get leaveCircleDialogBody =>
      'यो सर्कल छोड्ने? तपाईंले यसका सदस्यलाई आफ्नो स्थान पठाउन बन्द गर्नुहुनेछ र तिनको स्थान पनि देख्न पाउनुहुनेछैन। तपाईंले पठाएको अन्तिम स्थान तिनका फोनमा एक दिनसम्म रहन्छ। यो पूर्ववत् गर्न सकिँदैन: फेरि सामेल हुन तपाईंलाई नयाँ निमन्त्रणा चाहिन्छ।';

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
      'Haven को इन्क्रिप्शन इन्जिन अपग्रेड गरिएको छ, त्यसैले यो सर्कल अब प्रयोग गर्न सकिँदैन। उही व्यक्तिहरूसँग स्थान साझेदारी जारी राख्न यसलाई फेरि बनाउनुहोस्। तपाईंले तिनीहरूलाई फेरि निमन्त्रणा दिनुपर्नेछ।';

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
      'तपाईंको परिचय र सार्वजनिक प्रोफाइल जस्ताको तस्तै छन्। तिनका लागि तपाईंले केही गर्नुपर्दैन।';

  @override
  String get legacyCutoverExplainerCirclesNeedRecreation =>
      'राम्रो सुरक्षाका लागि, तपाईंका सर्कलहरू फेरि बनाउनु र तिनका सदस्यहरूलाई फेरि निमन्त्रणा दिनुपर्नेछ; त्यसपछि मात्र तपाईंले तिनमा फेरि स्थान साझा गर्न सक्नुहुन्छ।';

  @override
  String get legacyCutoverExplainerAcknowledge => 'बुझेँ';

  @override
  String get relaySettingsLegacyRetractionPending =>
      'Haven ले भर्खरैको सुरक्षा अपडेटबाट बाँकी रहेका केही पुराना डाटा हटाइदिन रिलेहरूलाई अझै अनुरोध गरिरहेको छ।';

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
      'यसले यो फोनबाट तपाईंको परिचय र सर्कलका सबै डाटा मेटाउँछ। त्यसअन्तर्गत पहिले नै प्रकाशित भइसकेको कुरा जहाँ छ त्यहीँ रहिरहन्छ: तपाईंको नाम र कुञ्जीहरू ती बोक्ने रिलेहरूमा, र तपाईंको फोटो त्यसलाई राख्ने तस्बिर सर्भरमा। पछि यही परिचय पुनर्प्राप्त गर्न चाहनुहुन्छ भने गोप्य कुञ्जी ब्याकअप गरेको सुनिश्चित गर्नुहोस्।';

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
      'तपाईंको सार्वजनिक कुञ्जी साझा गर्न सुरक्षित प्रयोगकर्ता नाम जस्तै काम गर्छ। मानिसहरूले तपाईंलाई सर्कलमा निमन्त्रणा गर्न यो कोड स्क्यान गर्छन्, वा तपाईंको सार्वजनिक कुञ्जी टाँस्छन्। यो साझा गर्दा तपाईं कहाँ हुनुहुन्छ भन्ने खुल्न सक्दैन। तपाईंको प्रदर्शन नाम र फोटो पहिले नै सार्वजनिक छन्, त्यसैले यसले थप केही जोड्दैन।';

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
  String get profileSyncStatusSyncing =>
      'तपाईंको सार्वजनिक प्रोफाइलमा सिंक हुँदै छ…';

  @override
  String get profileSyncStatusPartial =>
      'प्रकाशित भयो — अझै केही रिलेमा सिंक हुँदै छ';

  @override
  String get profileSyncStatusSynced => 'सार्वजनिक प्रोफाइल अद्यावधिक छ';

  @override
  String get profileSyncStatusFailed => 'अझै सिंक हुन सकेन।';

  @override
  String get profileSyncStatusRetrySemantics =>
      'आफ्नो प्रोफाइल प्रकाशित गर्न पुनः प्रयास गर्नुहोस्';

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
      'यसले तपाईंको सार्वजनिक प्रोफाइलबाट तपाईंको फोटो हटाउँछ। तस्बिर फाइल त्यसलाई राख्ने सर्भरमा रहिरहन्छ, र अरूले पहिले नै डाउनलोड गरिसकेका प्रतिहरू तिनीहरूसँगै रहन्छन्।';

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
      'फोटो अपडेट गरियो। तपाईंको सार्वजनिक Nostr प्रोफाइलमा प्रकाशित हुनेछ।';

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
  String get mapLocationNoPermissionTitle =>
      'Haven ले तपाईंको स्थान प्रयोग गर्न सक्दैन';

  @override
  String get mapLocationSharingStoppedServiceOff =>
      'यो यन्त्रमा स्थान निष्क्रिय भएकाले Haven ले तपाईंको स्थान तपाईंका सर्कलसँग साझा गर्न छाडेको छ। फेरि सुरु गर्न स्थान सक्रिय गर्नुहोस्।';

  @override
  String get mapLocationSharingStoppedPermission =>
      'Haven लाई अब तपाईंको स्थान प्रयोग गर्ने अनुमति छैन, त्यसैले साझेदारी रोकिएको छ। फेरि सुरु गर्न Haven का लागि स्थानलाई अनुमति दिनुहोस्।';

  @override
  String get mapLocationSharingStoppedPermissionSettings =>
      'सिस्टम सेटिङमा Haven का लागि स्थानको पहुँच बन्द गरिएको छ, त्यसैले साझेदारी रोकिएको छ। फेरि सुरु गर्न त्यहीँ गएर अनुमति दिनुहोस्।';

  @override
  String get mapLocationSharingStoppedBoth =>
      'Haven ले तपाईंको स्थान साझा गर्न छाडेको छ। यो यन्त्रमा स्थान सक्रिय गर्नुहोस् र Haven लाई स्थान प्रयोग गर्ने अनुमति दिनुहोस्।';

  @override
  String get mapLocationSharingStoppedUnknown =>
      'Haven ले तपाईंको स्थान पाउन छाडेको छ, त्यसैले साझेदारी रोकिएको छ। स्थान सक्रिय छ र Haven लाई त्यो प्रयोग गर्ने अनुमति छ कि छैन जाँच्नुहोस्।';

  @override
  String get mapLocationAccessRestoredAnnouncement =>
      'Haven ले अब तपाईंको स्थान प्रयोग गर्न सक्छ। साझेदारी फेरि सुरु भएको छ।';

  @override
  String get clockSkewTitle => 'यो फोनको घडी मिलेको छैन';

  @override
  String get clockSkewBodyRejected =>
      'यो फोनले तपाईंको स्थानमा राख्ने समय रिलेहरूले अस्वीकार गर्छन्, त्यसैले तपाईंका सर्कलहरूले त्यो पाइरहेका छैनन्। यो मिलाउन सिस्टम सेटिङमा मिति र समय स्वतः सेट गर्ने सुविधा सक्रिय गर्नुहोस्।';

  @override
  String get clockSkewBodyBehind =>
      'यो फोनको समय तपाईंका सर्कलका अरू सदस्यहरूको भन्दा पछाडि छ। यसले तपाईंको स्थान पठाउँछ त, तर कसैले देख्नुअघि नै त्यसको समयसीमा सकिन्छ। यो मिलाउन सिस्टम सेटिङमा मिति र समय स्वतः सेट गर्ने सुविधा सक्रिय गर्नुहोस्।';

  @override
  String get clockSkewResolvedAnnouncement =>
      'घडीको समस्या हटेको छ। Haven ले फेरि तपाईंको स्थान साझा गर्दै छ।';

  @override
  String get clockSkewTitleDisagreement =>
      'तपाईंका कुनै एक सर्कलमा एउटा घडी मिलेको छैन';

  @override
  String get clockSkewBodyDisagreement =>
      'यो फोनको घडी र अर्को एक जना सदस्यको घडीबीच दुई मिनेट वा त्यसभन्दा बढी फरक छ। यदि नमिलेको घडी यो फोनकै हो भने, यसले पठाउने स्थानहरूको समयसीमा कसैले देख्नुअघि नै सकिन सक्छ। यो फोनको घडी चाहिँ मिलेको छ भन्ने सुनिश्चित गर्न सिस्टम सेटिङमा मिति र समय स्वतः सेट गर्ने सुविधा सक्रिय गर्नुहोस्।';

  @override
  String get clockSkewDisagreementResolvedAnnouncement =>
      'घडीको चेतावनी हटेको छ।';

  @override
  String get sharingHealthTitleStopped => 'स्थान साझेदारी रोकिएको छ';

  @override
  String get sharingHealthTitleNotSending => 'तपाईंको स्थान साझा भइरहेको छैन';

  @override
  String get sharingHealthTitleNotReceiving =>
      'अरू सदस्यका स्थान तपाईंसम्म आइरहेका छैनन्';

  @override
  String sharingHealthNoUpdatesMinutes(int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'करिब $countString मिनेटदेखि कुनै अपडेट छैन',
      one: 'करिब १ मिनेटदेखि कुनै अपडेट छैन',
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
      other: 'करिब $countString घण्टादेखि कुनै अपडेट छैन',
      one: 'करिब १ घण्टादेखि कुनै अपडेट छैन',
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
      other: 'करिब $countString दिनदेखि कुनै अपडेट छैन',
      one: 'करिब १ दिनदेखि कुनै अपडेट छैन',
    );
    return '$_temp0';
  }

  @override
  String get sharingHealthRepairAction => 'मिलाउनुहोस्';

  @override
  String get sharingHealthRepairUnavailableHint =>
      'यो सर्कलका लागि मिलाउने सुविधा उपलब्ध छैन';

  @override
  String get sharingHealthRepairHint =>
      'रिलेहरूसँग फेरि जोडिन्छ, तपाईंको स्थान पठाउन पुनः प्रयास गर्छ, र तपाईं यो सर्कलको एडमिन हुनुहुन्छ भने यसलाई नयाँ कुञ्जी दिन सक्छ';

  @override
  String get sharingHealthRepairSent =>
      'मिलाउने परिवर्तन पठाइयो। अरूका फोनले यो प्राप्त गरेपछि तिनीहरूको स्थान फेरि आउन थाल्नेछ।';

  @override
  String get sharingHealthRepairNotOwner =>
      'यो सर्कलको एडमिनले मात्र यसलाई मिलाउन सक्छन्। तपाईंलाई हटाएर फेरि थप्न तिनलाई भन्नुहोस्।';

  @override
  String get sharingHealthRepairNeedsNewCircle =>
      'यो सर्कल यस फोनमा मिलाउन सकिँदैन। उही व्यक्तिहरूसँग नयाँ सर्कल बनाउनुहोस्।';

  @override
  String get sharingHealthRepairNothingToDo =>
      'अहिले मिलाउनुपर्ने केही छैन। Haven ले प्रयास गरिरहनेछ।';

  @override
  String get sharingHealthRepairUnresolvedAnnouncement =>
      'स्थान साझेदारी अझै चलेको छैन।';

  @override
  String get sharingHealthResumedAnnouncement =>
      'स्थान साझेदारी फेरि चल्न थालेको छ।';

  @override
  String circleMemberLastSeenMinutes(int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'पछिल्लो स्थान $countString मिनेट अघि',
      one: 'पछिल्लो स्थान १ मिनेट अघि',
    );
    return '$_temp0';
  }

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
  String get addRelaySheetTitleProfile => 'प्रोफाइल रिले थप्नुहोस्';

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
