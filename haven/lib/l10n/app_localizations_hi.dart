// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Hindi (`hi`).
class AppLocalizationsHi extends AppLocalizations {
  AppLocalizationsHi([String locale = 'hi']) : super(locale);

  @override
  String get appearanceTitle => 'दिखावट';

  @override
  String get appearanceThemeHeader => 'थीम';

  @override
  String get appearanceThemeSystem => 'सिस्टम डिफ़ॉल्ट';

  @override
  String get appearanceThemeSystemSubtitle => 'अपने डिवाइस की सेटिंग के अनुसार';

  @override
  String get appearanceThemeLight => 'हल्का';

  @override
  String get appearanceThemeLightSubtitle => 'हमेशा हल्की थीम इस्तेमाल करें';

  @override
  String get appearanceThemeDark => 'गहरा';

  @override
  String get appearanceThemeDarkSubtitle => 'हमेशा गहरी थीम इस्तेमाल करें';

  @override
  String get appearanceLanguageTitle => 'भाषा';

  @override
  String get languageSystemDefault => 'सिस्टम डिफ़ॉल्ट';

  @override
  String get commonTryAgain => 'फिर कोशिश करें';

  @override
  String get commonDismiss => 'बंद करें';

  @override
  String get commonSettings => 'सेटिंग';

  @override
  String get commonInvitations => 'निमंत्रण';

  @override
  String commonPendingInvitations(int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$countString लंबित निमंत्रण',
      one: '1 लंबित निमंत्रण',
    );
    return '$_temp0';
  }

  @override
  String get commonBack => 'वापस';

  @override
  String get commonContinue => 'जारी रखें';

  @override
  String get commonSkip => 'छोड़ें';

  @override
  String get commonRetry => 'फिर कोशिश करें';

  @override
  String onboardingStepOf(int current, int total) {
    final intl.NumberFormat currentNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String currentString = currentNumberFormat.format(current);
    final intl.NumberFormat totalNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String totalString = totalNumberFormat.format(total);

    return 'चरण $currentString/$totalString';
  }

  @override
  String get onboardingAppName => 'Haven';

  @override
  String get onboardingWelcomeHeadline =>
      'अपना स्थान निजी तौर पर साझा करें, केवल उन्हीं के साथ जिन्हें आप चाहते हैं।';

  @override
  String get onboardingWelcomeHeadlineEmphasis => 'केवल';

  @override
  String get onboardingWelcomeCta => 'शुरू करें';

  @override
  String get onboardingValuePropsTitle => 'Haven को क्या अलग बनाता है';

  @override
  String get onboardingValueProp1Title => 'केवल आपके सर्कल आपको देख सकते हैं';

  @override
  String get onboardingValueProp1Body =>
      'आपका स्थान आपके डिवाइस को छोड़ने से पहले ही उस पर एन्क्रिप्ट हो जाता है, इसलिए इसे केवल वही सर्कल पढ़ सकते हैं जिन्हें आप चुनते हैं, न Haven और न ही कोई और। चूँकि Haven ओपन सोर्स है, कोई भी इसकी पुष्टि कर सकता है।';

  @override
  String get onboardingValueProp2Title => 'इसे कोई बंद नहीं कर सकता';

  @override
  String get onboardingValueProp2Body =>
      'Haven का कोई केंद्रीय सर्वर नहीं है। आपके एन्क्रिप्टेड संदेश रिले के एक विकेंद्रीकृत नेटवर्क से होकर जाते हैं, जिन्हें आप खुद चुन सकते हैं, इसलिए कोई भी अकेली संस्था इसे बंद नहीं कर सकती।';

  @override
  String get onboardingValueProp3Title => 'किसी खाते की ज़रूरत नहीं';

  @override
  String get onboardingValueProp3Body =>
      'न ईमेल, न फ़ोन नंबर, न साइन-अप। Haven ऐसी पहचान बनाता है जिसकी गुप्त कुंजी कभी आपके फ़ोन से बाहर नहीं जाती, इसलिए ऐसा कोई खाता ही नहीं होता जिसे कोई किसी को सौंप सके।';

  @override
  String get onboardingValueProp1Summary =>
      'आपके डिवाइस पर एन्क्रिप्टेड, ताकि इसे केवल आपके चुने हुए सर्कल ही पढ़ सकें।';

  @override
  String get onboardingValueProp2Summary =>
      'कोई केंद्रीय सर्वर नहीं — यह आपके चुने हुए रिले नेटवर्क पर चलता है।';

  @override
  String get onboardingValueProp3Summary =>
      'न ईमेल, न फ़ोन, न साइन-अप। आपकी गुप्त कुंजी कभी आपके फ़ोन से बाहर नहीं जाती।';

  @override
  String get onboardingCreateIdentityTitle => 'अपनी पहचान बनाएँ';

  @override
  String get onboardingCreateIdentityBody =>
      'Haven एक निजी पहचान बनाएगा जो केवल इसी फ़ोन पर रहेगी। इसी से आपके सर्कल आपको पहचानते हैं।';

  @override
  String get onboardingCreateIdentityWarning =>
      'अगर यह फ़ोन खो गया या आपने ऐप हटा दिया, तो आपकी पहचान चली जाएगी। Haven के पास इसे वापस पाने का कोई तरीका नहीं है।';

  @override
  String get onboardingCreateIdentityCta => 'मेरी पहचान बनाएँ';

  @override
  String get onboardingCreateIdentityLoading => 'सब कुछ तैयार किया जा रहा है…';

  @override
  String get onboardingCreateIdentityImportPrompt => 'पहले से कोई कुंजी है?';

  @override
  String get onboardingCreateIdentityImportLink => 'उसे इंपोर्ट करें';

  @override
  String get onboardingCreateIdentityError =>
      'आपकी पहचान बनाने में कुछ गड़बड़ हो गई। कृपया फिर कोशिश करें।';

  @override
  String get onboardingImportTitle => 'अपनी मौजूदा कुंजी इंपोर्ट करें';

  @override
  String get onboardingImportBody =>
      'किसी अन्य Haven-संगत ऐप से बैकअप की हुई गुप्त कुंजी यहाँ पेस्ट करें।';

  @override
  String get onboardingImportHint => 'nsec1…';

  @override
  String get onboardingImportCta => 'इंपोर्ट करें';

  @override
  String get onboardingImportLoading => 'इंपोर्ट हो रहा है…';

  @override
  String get onboardingImportInvalid =>
      'यह एक मान्य बैकअप कुंजी नहीं लगती। कृपया जाँचें और फिर कोशिश करें।';

  @override
  String get onboardingImportError =>
      'हम वह कुंजी इंपोर्ट नहीं कर सके। कृपया जाँचें और फिर कोशिश करें।';

  @override
  String get onboardingDisplayNameHint => 'जैसे, आर्यन';

  @override
  String get onboardingDisplayNameError =>
      'वह नाम सहेजा नहीं जा सका। कृपया फिर कोशिश करें।';

  @override
  String get onboardingAddPhotoOptional => 'फ़ोटो जोड़ें (वैकल्पिक)';

  @override
  String get commonCancel => 'रद्द करें';

  @override
  String get commonOpenSettings => 'सेटिंग खोलें';

  @override
  String get settingsTitle => 'सेटिंग';

  @override
  String get settingsIdentityTitle => 'पहचान';

  @override
  String get settingsIdentitySubtitle => 'प्रोफ़ाइल, कुंजियाँ और फ़ोटो साझाकरण';

  @override
  String get settingsRelaysTitle => 'रिले';

  @override
  String get settingsRelaysSubtitle => 'जहाँ निमंत्रण आप तक पहुँचते हैं';

  @override
  String get settingsLocationTitle => 'स्थान';

  @override
  String get settingsLocationSubtitle => 'बैकग्राउंड साझाकरण और अनुमतियाँ';

  @override
  String get settingsMapStyleTitle => 'मानचित्र शैली';

  @override
  String get settingsAppearanceSubtitle => 'थीम और भाषा';

  @override
  String get settingsAboutTitle => 'परिचय';

  @override
  String get settingsDebugOverlayTitle => 'डीबग लॉग ओवरले';

  @override
  String get settingsDebugOverlaySubtitle => 'स्क्रीन पर लॉग आउटपुट दिखाएँ';

  @override
  String get relaySettingsTitle => 'रिले';

  @override
  String get relaySettingsCheckRelaysTooltip => 'रिले जाँचें';

  @override
  String get relaySettingsNoIdentityTitle => 'कोई पहचान नहीं';

  @override
  String get relaySettingsNoIdentityMessage =>
      'रिले प्रबंधित करने के लिए पहले एक पहचान बनाएँ।';

  @override
  String get relaySettingsLoadIdentityError => 'पहचान लोड नहीं हो सकी।';

  @override
  String get relaySettingsInboxTitle => 'मेरे इनबॉक्स रिले';

  @override
  String get relaySettingsInboxSubtitle =>
      'kind 10050, जहाँ निमंत्रण आप तक पहुँचते हैं';

  @override
  String get relaySettingsKeyPackageTitle => 'मेरे KeyPackage रिले';

  @override
  String get relaySettingsKeyPackageSubtitle =>
      'kind 10002, जहाँ आमंत्रित लोग आपकी एन्क्रिप्शन कुंजियाँ खोजते हैं';

  @override
  String get relaySettingsLoadRelaysError => 'रिले लोड नहीं हो सके।';

  @override
  String get relaySettingsAddRelay => 'रिले जोड़ें';

  @override
  String get relaySettingsRestoreDefaults => 'डिफ़ॉल्ट बहाल करें';

  @override
  String get relaySettingsAddRelayError => 'रिले जोड़ा नहीं जा सका।';

  @override
  String get relaySettingsRemoveRelayError => 'रिले हटाया नहीं जा सका।';

  @override
  String get relaySettingsRestoreTitle => 'डिफ़ॉल्ट रिले बहाल करें?';

  @override
  String relaySettingsRestoreBody(int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other:
          'आपके मौजूदा $countString रिले Haven के डिफ़ॉल्ट से बदल दिए जाएँगे। इसे पूर्ववत नहीं किया जा सकता।',
      one:
          'आपका मौजूदा 1 रिले Haven के डिफ़ॉल्ट से बदल दिया जाएगा। इसे पूर्ववत नहीं किया जा सकता।',
    );
    return '$_temp0';
  }

  @override
  String get relaySettingsRestoreConfirm => 'बहाल करें';

  @override
  String get relaySettingsRestoreSuccess => 'डिफ़ॉल्ट बहाल कर दिए गए।';

  @override
  String get relaySettingsRestoreError => 'डिफ़ॉल्ट बहाल नहीं किए जा सके।';

  @override
  String relaySettingsRemoveTooltip(String url) {
    return '$url हटाएँ';
  }

  @override
  String get relaySettingsStatusConnected => 'कनेक्टेड';

  @override
  String get relaySettingsStatusChecking => 'जाँच हो रही है';

  @override
  String get relaySettingsStatusUnreachable => 'पहुँच नहीं सका';

  @override
  String get relaySettingsStatusNotChecked => 'जाँचा नहीं गया';

  @override
  String relaySettingsStatusSemantics(String status) {
    return 'रिले स्थिति: $status';
  }

  @override
  String get relaySettingsEmptyTitle => 'कोई रिले कॉन्फ़िगर नहीं है';

  @override
  String get relaySettingsEmptyMessage =>
      'आपको कम से कम एक रिले चाहिए ताकि दूसरे आप तक पहुँच सकें। Haven डिफ़ॉल्ट बहाल करने के लिए नीचे टैप करें।';

  @override
  String get locationSettingsTitle => 'स्थान';

  @override
  String get locationSettingsDisabledSnack => 'बैकग्राउंड साझाकरण बंद किया गया';

  @override
  String get locationSettingsEnabledSnack => 'बैकग्राउंड साझाकरण चालू किया गया';

  @override
  String get locationSettingsNotificationDeniedSnack =>
      'बैकग्राउंड साझाकरण को एक नोटिफ़िकेशन चाहिए ताकि Android इसे चलता रखे। फ़िलहाल यह बंद है। इसे चालू करने के लिए Haven के लिए नोटिफ़िकेशन की अनुमति दें।';

  @override
  String get locationSettingsBatteryOptSnack =>
      'चालू। बैटरी ऑप्टिमाइज़ेशन कुछ फ़ोन पर साझाकरण रोक सकता है। इसे भरोसेमंद बनाए रखने के लिए Haven को बैटरी ऑप्टिमाइज़ेशन से बाहर रखें।';

  @override
  String get locationSettingsErrorSnack => 'कुछ गड़बड़ हो गई';

  @override
  String get locationSettingsIntro =>
      'जब बैकग्राउंड साझाकरण चालू होता है, तो Haven बंद होने पर भी आपके सर्कल आपका लाइव स्थान देखते रहते हैं।';

  @override
  String get locationSettingsToggleTitle => 'बैकग्राउंड में साझा करें';

  @override
  String get locationSettingsToggleSubtitle =>
      'ऐप बंद होने पर भी साझा करते रहें';

  @override
  String get locationSettingsIosLimitedNote =>
      'आपकी मौजूदा अनुमति के साथ भी साझाकरण बैकग्राउंड में चलता रहता है। सेटिंग में Haven के लिए स्थान को \'हमेशा\' पर सेट करें, ताकि iOS के ऐप बंद कर देने के बाद भी अपडेट फिर से शुरू हो सकें।';

  @override
  String get locationSettingsAndroidHeader =>
      'भरोसेमंद कामकाज के लिए OS सेटिंग';

  @override
  String get locationSettingsAndroidNotification =>
      'Haven को एक स्थायी नोटिफ़िकेशन चाहिए ताकि Android बैकग्राउंड सेवा को चलता रखे। अगर आपने नोटिफ़िकेशन की अनुमति अस्वीकार कर दी है, तो सेटिंग खोलें और Haven के लिए नोटिफ़िकेशन की अनुमति दें।';

  @override
  String get locationSettingsAndroidBattery =>
      'भरोसेमंद बैकग्राउंड साझाकरण के लिए, Haven को बैटरी ऑप्टिमाइज़ेशन से भी बाहर रखें। सेटिंग → ऐप्स → Haven → बैटरी → हर समय अनुमति दें पर जाएँ।';

  @override
  String get locationSettingsAndroidVendors =>
      'Samsung डिवाइस पर, Haven को \"Sleeping apps\" से हटाएँ (Device care → Battery → Background usage limits)। Xiaomi पर, Haven के लिए Autostart चालू करें।';

  @override
  String get locationSettingsIosGuidance =>
      'जब बैकग्राउंड साझाकरण चालू होता है, तो Haven लगातार आपके स्थान का उपयोग करता रहता है और iOS स्टेटस बार में एक नीला संकेतक दिखाता है। साथ ही, \"हमेशा\" की अनुमति देने पर iOS के ऐप बंद कर देने के बाद भी Haven आपके सर्कलों के छूटे हुए अपडेट पा सकता है।';

  @override
  String get mapStyleTitle => 'मानचित्र शैली';

  @override
  String get mapStyleMinimalTitle => 'सादा';

  @override
  String get mapStyleMinimalSubtitle =>
      'शांत, कम विवरण वाला कैनवास जो आपकी हल्की या गहरी थीम के अनुसार चलता है';

  @override
  String get mapStyleDetailedTitle => 'विस्तृत';

  @override
  String get mapStyleDetailedSubtitle => 'पूरे रंग की सड़कें, लेबल और स्थान';

  @override
  String get mapStyleOutdoorsTitle => 'बाहरी क्षेत्र';

  @override
  String get mapStyleOutdoorsSubtitle =>
      'पगडंडियों और पार्कों के साथ छायांकित भूभाग';

  @override
  String get mapStylePreviewHeader => 'पूर्वावलोकन';

  @override
  String get mapStylePreviewCity => 'शहर';

  @override
  String get mapStylePreviewNature => 'प्रकृति';

  @override
  String mapStylePreviewSemantics(String scene, String style) {
    return 'मानचित्र पूर्वावलोकन ($scene): $style';
  }

  @override
  String get mapStylePreviewUnavailableSemantics =>
      'इस बिल्ड में मानचित्र पूर्वावलोकन उपलब्ध नहीं है';

  @override
  String get mapStylePreviewUnavailableLabel =>
      'लाइव पूर्वावलोकन रिलीज़ बिल्ड में दिखता है';

  @override
  String get aboutTitle => 'परिचय';

  @override
  String get aboutHeroName => 'Haven';

  @override
  String get aboutHeroTagline => 'निजी और सेंसरशिप-प्रतिरोधी स्थान साझाकरण।';

  @override
  String get aboutLicensesTitle => 'ओपन-सोर्स लाइसेंस';

  @override
  String get aboutLicensesLegalese => '© 2026 Haven · MIT License';

  @override
  String get aboutReportMapIssue => 'मानचित्र की समस्या रिपोर्ट करें';

  @override
  String get aboutSupportOsm => 'OpenStreetMap का समर्थन करें';

  @override
  String get aboutMapAttribution =>
      '© Stadia Maps · © OpenMapTiles · © OpenStreetMap contributors\nMap data licensed under ODbL';

  @override
  String get aboutLinkOpenError => 'लिंक नहीं खुल सका';

  @override
  String get aboutVpnLinkLabel => 'mullvad.net';

  @override
  String get aboutFooterLicense => 'MIT License के तहत लाइसेंस प्राप्त';

  @override
  String aboutFooterVersion(String version) {
    return 'संस्करण $version';
  }

  @override
  String get privacyTitle => 'गोपनीयता';

  @override
  String get privacySubtitle =>
      'Haven कैसे काम करता है और दूसरे क्या देख सकते हैं';

  @override
  String get privacyHubSummary =>
      'Haven आपका स्थान केवल उन छोटे समूहों के साथ साझा करता है जिन्हें आप चुनते हैं, और आपके फ़ोन को छोड़ने से पहले ही उसे उसी पर एन्क्रिप्ट कर देता है। इसके पीछे कोई कंपनी खाता नहीं है और कोई Haven सर्वर नहीं है। नीचे दिए गए पन्ने सरल भाषा में बताते हैं कि यह कैसे होता है, और यह भी ईमानदारी से बताते हैं कि यह किससे नहीं बचाता।';

  @override
  String get privacyGroupBasicsHeading => 'बुनियादी बातें';

  @override
  String get privacyMeansForYouLabel => 'आपके लिए इसका मतलब';

  @override
  String get privacyMoreDetailLabel => 'और विस्तार से';

  @override
  String get privacyMoreDetailExpandHint => 'तकनीकी विवरण दिखाएँ';

  @override
  String get privacyMoreDetailCollapseHint => 'तकनीकी विवरण छिपाएँ';

  @override
  String get privacyMoreDetailExpandedAnnouncement =>
      'तकनीकी विवरण दिखाया गया है';

  @override
  String get privacyMoreDetailCollapsedAnnouncement => 'तकनीकी विवरण छिपा है';

  @override
  String get privacyWhatHavenIsTitle =>
      'Haven क्या है, और इसमें कोई खाता क्यों नहीं होता';

  @override
  String get privacyWhatHavenIsSubtitle =>
      'कोई साइन-अप नहीं, कोई कंपनी सर्वर नहीं';

  @override
  String get privacyWhatHavenIsNoAccount =>
      'Haven आपका स्थान उन छोटे समूहों के साथ साझा करता है जिन्हें आप चुनते हैं और जिन्हें सर्कल कहा जाता है। इसके पीछे कोई खाता नहीं होता। आप कभी कोई ईमेल पता, फ़ोन नंबर या पासवर्ड नहीं देते।';

  @override
  String get privacyWhatHavenIsNoServers =>
      'Haven अपना कोई सर्वर भी नहीं चलाता। आपके एन्क्रिप्टेड स्थान अपडेट स्वतंत्र सर्वरों से होकर जाते हैं, जिन्हें रिले कहा जाता है और जिन्हें दूसरे लोग चलाते हैं। Haven के डेवलपर आपका स्थान नहीं देख सकते, और आप ऐप कैसे इस्तेमाल करते हैं इसके बारे में वे कुछ भी इकट्ठा नहीं करते।';

  @override
  String get privacyWhatHavenIsMeansForYou =>
      'आपका डेटा माँगने के लिए कोई नहीं है, क्योंकि किसी के पास वह नहीं है। इसका दूसरा पहलू यह है कि आपका खाता बहाल भी कोई नहीं कर सकता। क्या बैकअप करना है, यह जानने के लिए \"आपकी दो कुंजियाँ\" देखें।';

  @override
  String get privacyWhatHavenIsDetailNoTelemetry =>
      'ऐप में कोई एनालिटिक्स, क्रैश रिपोर्टिंग या विज्ञापन कोड नहीं है। चूँकि Haven ओपन सोर्स है, इसे भरोसे पर छोड़ने के बजाय जाँचा जा सकता है।';

  @override
  String get privacyWhatHavenIsDetailNoPush =>
      'Haven में पुश नोटिफ़िकेशन भी जान-बूझकर नहीं रखे गए हैं। किसी नोटिफ़िकेशन सेवा को हर बार यह बताना पड़ता कि आपके सर्कलों में किसी के पास आपके लिए कुछ पहुँचाने को है, और इससे रिले की तुलना में आपकी आदतों के बारे में ज़्यादा पता चल जाता।';

  @override
  String get privacyYourKeysTitle =>
      'आपकी दो कुंजियाँ: एक गुप्त, एक साझा करने के लिए';

  @override
  String get privacyYourKeysSubtitle =>
      'आपकी पहचान क्या बनाता है, और क्या बैकअप करना है';

  @override
  String get privacyYourKeysWhatTheyAre =>
      'उपयोगकर्ता नाम और पासवर्ड की जगह आपके पास कुंजियों की एक जोड़ी होती है। गुप्त कुंजी यह साबित करती है कि आप ही आप हैं। सार्वजनिक कुंजी वह है जिससे दूसरे आपको खोजते और आमंत्रित करते हैं।';

  @override
  String get privacyYourKeysSecretStaysHere =>
      'आपकी गुप्त कुंजी केवल इसी फ़ोन पर रहती है, ऐसे भंडारण में जिसे ऑपरेटिंग सिस्टम सुरक्षित रखता है। Haven इसे कहीं नहीं भेजता — न किसी रिले को, न हमें।';

  @override
  String get privacyYourKeysPublicIsSafe =>
      'आपकी सार्वजनिक कुंजी किसी को देना सुरक्षित है। यह ऐसे उपयोगकर्ता नाम की तरह काम करती है जिसे आप कहीं भी पोस्ट कर सकते हैं। इसे साझा करने से यह उजागर नहीं होता कि आप कहाँ हैं।';

  @override
  String get privacyYourKeysMeansForYou =>
      'अगर आप यह पहचान बनाए रखना चाहते हैं, तो अपनी गुप्त कुंजी का बैकअप लें। आप इसे सेटिंग → पहचान → उन्नत में देख सकते हैं। अगर बैकअप के बिना फ़ोन खो जाए, तो वह पहचान हमेशा के लिए चली जाती है, और कोई उसे वापस नहीं ला सकता।';

  @override
  String get privacyYourKeysNeverShareSecret =>
      'जिसे भी आपकी गुप्त कुंजी मिल जाए, वह आप बन जाता है। वह आपके नाम से सर्कलों में शामिल हो सकता है या आपके नाम से कुछ प्रकाशित कर सकता है। इसे कभी किसी दूसरे ऐप, संदेश या वेबसाइट में पेस्ट न करें।';

  @override
  String get privacyYourKeysDetailFormats =>
      'यह जोड़ी एक secp256k1 कुंजी है, जो मानक Nostr स्वरूपों में दिखाई जाती है: सार्वजनिक कुंजी के लिए npub1… और गुप्त कुंजी के लिए nsec1…। हस्ताक्षर ऐप के भीतर ही होते हैं, और गुप्त बाइट हर उपयोग के बाद मेमोरी से मिटा दिए जाते हैं।';

  @override
  String get privacyYourKeysDetailSeparation =>
      'आपके सर्कलों के संदेशों को एन्क्रिप्ट करने वाली कुंजियाँ इस पहचान कुंजी से अलग होती हैं और केवल ऐप के पास रहती हैं। यह अलगाव जान-बूझकर है: जो कुंजी आपका नाम बताती है, वह वह कुंजी नहीं है जो आपके भेजे हुए को खोलती है।';

  @override
  String get privacyPublicProfileTitle => 'आपका नाम और फ़ोटो सार्वजनिक हैं';

  @override
  String get privacyPublicProfileSubtitle =>
      'किसी को भी दिखते हैं, केवल आपके सर्कलों को ही नहीं';

  @override
  String get privacyPublicProfileIsPublic =>
      'आपका सेट किया हुआ प्रदर्शन नाम और फ़ोटो व्यापक Nostr नेटवर्क पर प्रकाशित होते हैं। इन्हें कोई भी खोज सकता है, केवल आपके सर्कलों के लोग ही नहीं।';

  @override
  String get privacyPublicProfileOnSave =>
      'यह उसी पल हो जाता है जब आप उन्हें सहेजते हैं। ऐसी कोई सेटिंग नहीं है जो इन्हें निजी रखे, और नाम को केवल अपने सर्कलों के साथ साझा करने का कोई तरीका भी नहीं है।';

  @override
  String get privacyPublicProfilePseudonym =>
      'नए इंस्टॉल पर शुरुआत एक बनाए हुए नाम से होती है, जैसे \"Quiet Wanderer\", जो आपके बारे में कुछ नहीं बताता। आप इसे रख सकते हैं, या इसकी जगह जो चाहें वह रख सकते हैं।';

  @override
  String get privacyPublicProfileMeansForYou =>
      'ऐसा नाम और फ़ोटो चुनें जिन्हें सार्वजनिक रूप से दिखाने में आप सहज हों। अगर आप पहचाने नहीं जाना चाहते, तो आपको दिया गया बनाया हुआ नाम ही रखें और फ़ोटो न लगाएँ।';

  @override
  String get privacyPublicProfileRemovalIsNotDeletion =>
      'बाद में अपनी फ़ोटो हटाने से वह अप्रकाशित नहीं हो जाती। Haven आपकी प्रोफ़ाइल को एक खाली प्रोफ़ाइल से बदल देता है, पर छवि फ़ाइल उस सर्वर पर बनी रहती है जो उसे रखता है, और जो प्रतियाँ पहले डाउनलोड हो चुकी हैं वे कहीं न कहीं मौजूद रहती हैं। आप जो कुछ प्रकाशित करते हैं, उसे स्थायी मानें।';

  @override
  String get privacyPublicProfileDetailKindZero =>
      'प्रोफ़ाइल एक Nostr \"kind 0\" इवेंट है जिस पर आपकी पहचान कुंजी से हस्ताक्षर होते हैं। फ़ोटो किसी Blossom होस्ट पर अपलोड होती हैं — जब तक आप उसे बदलें नहीं, blossom.primal.net पर — और वह होस्ट छवि, आपकी सार्वजनिक कुंजी और आपका IP पता देखता है।';

  @override
  String get privacyPublicProfileDetailExifStripped =>
      'अपलोड करने से पहले Haven तस्वीर को दोबारा एनकोड करता है और कैमरे जो छिपा हुआ डेटा जोड़ते हैं उसे हटा देता है, जिसमें वह GPS स्थिति भी शामिल है जहाँ फ़ोटो ली गई थी। यहाँ इसका महत्व है: वरना छुट्टियों की एक तस्वीर आपके घर के निर्देशांक साथ ले जा सकती है।';

  @override
  String get privacyGroupHowLocationTravelsHeading =>
      'आपका स्थान किस रास्ते जाता है';

  @override
  String get privacyRelaysTitle => 'रिले: वे सर्वर जो संदेश आगे पहुँचाते हैं';

  @override
  String get privacyRelaysSubtitle =>
      'आपके अपडेट किसके कंप्यूटरों से होकर जाते हैं';

  @override
  String get privacyRelaysWhatIsARelay =>
      'Haven का अपना कोई सर्वर नहीं है, इसलिए आपके अपडेट दूसरे लोगों के सर्वरों से होकर जाते हैं। इन्हें रिले कहा जाता है: छोटे, स्वतंत्र सर्वर जिन्हें कोई भी चला सकता है। एक रिले किसी एन्क्रिप्टेड संदेश को थोड़ी देर रखता है, और जब आपका सर्कल माँगता है तो उसे आगे पहुँचा देता है।';

  @override
  String get privacyRelaysWhyMany =>
      'कई रिले होने का मतलब है कि उनमें से कोई अकेला आपको काट नहीं सकता। अगर एक ऑफ़लाइन हो जाए, तो बाकी चलते रहते हैं। आप तय करते हैं कि कौन-से रिले इस्तेमाल हों, और उन्हें जब चाहें बदल सकते हैं।';

  @override
  String get privacyRelaysTwoLists =>
      'Haven आपके लिए दो सूचियाँ रखता है। आपके इनबॉक्स रिले वे हैं जहाँ निमंत्रण आप तक पहुँचते हैं। आपके KeyPackage रिले वे हैं जहाँ से लोग आपको आमंत्रित करने के लिए ज़रूरी कुंजियाँ लेते हैं। हर सर्कल की भी अपनी एक सूची होती है, और उसी से उस सर्कल के एन्क्रिप्टेड अपडेट गुज़रते हैं।';

  @override
  String get privacyRelaysMeansForYou =>
      'यहाँ ऐसा कुछ नहीं है जिसे गलत करने से जोखिम हो: एक रिले को हमेशा केवल एन्क्रिप्टेड डेटा ही दिखता है। पर आपके पास कम से कम एक ऐसा रिले होना चाहिए जहाँ तक पहुँचा जा सके, वरना कोई आपको आमंत्रित नहीं कर पाएगा और आपके सर्कलों से कोई अपडेट नहीं आएगा।';

  @override
  String get privacyRelaysDetailIndexers =>
      'आपकी अपनी सूचियों से अलग, Haven दूसरे लोगों की प्रोफ़ाइल और कुंजियाँ खोजने के लिए कुछ सार्वजनिक डायरेक्टरी रिले से पूछता है। आपने अपने लिए केवल निजी रिले सेट किए हों, तब भी यह उनसे संपर्क करता है। उन्हें आपका नेटवर्क पता दिखता है, और यह भी कि आपने किन खातों के बारे में पूछा।';

  @override
  String get privacyRelaysDetailKeyListIsPublic =>
      'आपकी KeyPackage रिले सूची खुद भी आपकी पहचान कुंजी से हस्ताक्षरित होकर नेटवर्क पर प्रकाशित होती है, ताकि दूसरे इसे पा सकें। अगर आप उस सूची में कोई निजी रिले जोड़ते हैं, तो उसका पता सार्वजनिक हो जाता है और आपसे जुड़ जाता है। जो रिले केवल किसी एक सर्कल की अपनी सूची में इस्तेमाल होता है, उसका इस तरह प्रचार नहीं होता।';

  @override
  String get privacyEncryptionTitle => 'एन्क्रिप्शन कैसे काम करता है';

  @override
  String get privacyEncryptionSubtitle =>
      'हर सर्कल की अपनी कुंजियाँ, और लोगों के आने-जाने पर क्या बदलता है';

  @override
  String get privacyEncryptionPerCircle =>
      'आपके फ़ोन से निकलने से पहले ही आपका स्थान उसी पर एन्क्रिप्ट हो जाता है; इसके लिए MLS नाम का एक खुला मानक इस्तेमाल होता है। हर सर्कल अपनी खुद की कुंजियों वाला एक अलग एन्क्रिप्टेड समूह है। सर्कल के बाहर कोई यह नहीं पढ़ सकता कि उसके भीतर क्या भेजा गया — न कोई रिले, न Haven, न कोई दूसरा सर्कल जिसमें आप हैं।';

  @override
  String get privacyEncryptionWhenSomeoneJoins =>
      'जब कोई शामिल होता है, तो सर्कल एक नई कुंजी पर चला जाता है। वह अपने आने के बाद भेजी गई बातें पढ़ सकता है, और उससे पहले की कोई नहीं। Haven किसी नए सदस्य को पिछले स्थान कभी नहीं भेजता।';

  @override
  String get privacyEncryptionWhenSomeoneLeaves =>
      'जब कोई छोड़ता है या हटाया जाता है, तो सर्कल एक और नई कुंजी पर चला जाता है। ज़्यादा से ज़्यादा कुछ मिनटों में वह कुछ भी नया पढ़ नहीं पाता।';

  @override
  String get privacyEncryptionKeysChangeOnMembership =>
      'कुंजियाँ तब बदलती हैं जब सदस्यता बदलती है, न कि किसी तय अंतराल पर। दो बदलावों के बीच जो कुछ भेजा जाता है, वह सब एक ही कुंजी के दायरे में आता है। इसलिए जिस सर्कल में लंबे समय से कोई बदलाव नहीं हुआ, उसमें से किसी को हटाने पर भी वह व्यक्ति सदस्य रहते हुए उसने जो भी संदेश सहेजे थे, वे सब खोल सकता है — हफ़्तों पुराने संदेश भी। उसके जाने के बाद भेजा गया कुछ भी वह नहीं खोल सकता।';

  @override
  String get privacyEncryptionMeansForYou =>
      'एन्क्रिप्शन आपको आपके सर्कलों के बाहर के हर व्यक्ति से बचाता है। जो कभी किसी सर्कल के भीतर रहा हो, उससे यह नहीं बचा सकता। अगर आप किसी से पूरी तरह नाता तोड़ना चाहते हैं, तो उसे पुराने सर्कल से हटाने के बजाय एक नया सर्कल शुरू करना ज़्यादा सुरक्षित है।';

  @override
  String get privacyEncryptionDetailMls =>
      'MLS (Messaging Layer Security) वही IETF मानक है जो दूसरे सुरक्षित मैसेंजर इस्तेमाल करते हैं। Haven जिस Marmot प्रोटोकॉल से Nostr नेटवर्क तक पहुँचता है, वही तय करता है कि MLS समूह रिले पर होकर कैसे चलते हैं। हर सर्कल जिस कुंजी से हस्ताक्षर करता है, वह आपकी सार्वजनिक Nostr पहचान कुंजी से अलग होती है।';

  @override
  String get privacyEncryptionDetailEpochs =>
      'कुंजी की हर अवधि को एपोक कहा जाता है। आपका फ़ोन पिछली कुछ एपोक से रास्ते में आ रहे संदेशों को खोलने भर की सामग्री रखता है, और उसके बाद उसे मिटा देता है — इसीलिए Haven आपके पुराने संदेश आपके लिए वापस नहीं ला सकता, सिद्धांत रूप में भी नहीं।';

  @override
  String get privacyWhatOthersSeeTitle =>
      'सदस्य क्या देखते हैं, और रिले क्या देखते हैं';

  @override
  String get privacyWhatOthersSeeSubtitle =>
      'वे लोग जिनके साथ आप साझा करते हैं, और बीच के सर्वर';

  @override
  String get privacyWhatOthersSeeMembersHeading => 'आपके सर्कलों के लोग';

  @override
  String get privacyWhatOthersSeeMembersExact =>
      'सर्कल में हर कोई मानचित्र पर आपका सटीक स्थान देखता है, न कि कोई अनुमानित इलाका। ऐसी कोई सेटिंग नहीं है जो कुछ सदस्यों के साथ धुँधला स्थान और दूसरों के साथ सटीक स्थान साझा करे।';

  @override
  String get privacyWhatOthersSeeCannotPause =>
      'जब तक Haven खुला है और आप किसी सर्कल में हैं, आपका स्थान हर दो-तीन मिनट में अपने आप चला जाता है। रोकने का कोई बटन नहीं है। बस एक ही स्विच है: ऐप से बाहर निकलने के बाद साझा करना चलता रहे या नहीं।';

  @override
  String get privacyWhatOthersSeeMembersLearnKey =>
      'किसी सर्कल में शामिल होने पर हर सदस्य को आपकी सार्वजनिक कुंजी भी दिख जाती है। उसके ज़रिये वे आपकी सार्वजनिक प्रोफ़ाइल देख सकते हैं, और वह सब भी जो आपने कभी उस कुंजी से प्रकाशित किया है।';

  @override
  String get privacyWhatOthersSeeCoMemberIp =>
      'किसी सदस्य की प्रोफ़ाइल फ़ोटो उसी के चुने हुए सर्वर से आती है। उसे लोड करने पर आपका नेटवर्क पता — और इससे मोटे तौर पर यह भी कि आप दुनिया में कहाँ हैं — उस सर्वर को चलाने वाले तक पहुँच जाता है। यह अपने आप होता है, आपके कुछ भी टैप किए बिना।';

  @override
  String get privacyWhatOthersSeeRelaysHeading => 'रिले चलाने वाले';

  @override
  String get privacyWhatOthersSeeRelaysCannot =>
      'रिले चलाने वाले आपका स्थान, आपके संदेश, आपके सर्कल का नाम या उसके सदस्यों की सूची नहीं पढ़ सकते। हर संदेश उनके पास एक नए, एक-बार इस्तेमाल होने वाले भेजने वाले पते से पहुँचता है, इसलिए वे यह नहीं बता सकते कि उसे किस सदस्य ने भेजा।';

  @override
  String get privacyWhatOthersSeeRelaysCan =>
      'उन्हें आपका नेटवर्क पता दिखता है, यह भी कि आप कब ऑनलाइन हैं, और आपका ट्रैफ़िक कितना बड़ा और कितनी बार होता है। हर सर्कल के साथ एक यादृच्छिक टैग चलता है, इसलिए एक रिले उस सर्कल के सारे संदेश एक साथ रख सकता है और अंदाज़ा लगा सकता है कि उसमें कितने लोग हैं — यह जाने बिना कि वे कौन हैं।';

  @override
  String get privacyWhatOthersSeeMeansForYou =>
      'सर्कल में उन्हीं लोगों को रखें जिन्हें आप अपने घर का पता भी दे देते हों। रिले और सर्कल के बाहर के लोगों के सामने एन्क्रिप्शन टिकता है, और एक VPN नेटवर्क पते की इस कमी को ढक देता है। जो सदस्य स्क्रीनशॉट सहेज ले, उसके सामने कुछ नहीं टिकता।';

  @override
  String get privacyWhatOthersSeeDetailTag =>
      'किसी सर्कल का टैग उसके पूरे जीवन भर वही रहता है, इसलिए एक रिले उसके सारे संदेशों को अनिश्चित काल तक आपस में जोड़ सकता है। यह उस प्रोटोकॉल का गुण है जिस पर यह सब बना है, ऐसी चीज़ नहीं जिसे Haven बदल सके।';

  @override
  String get commonLearnMore => 'और जानें';

  @override
  String get relaySettingsBackendCaption =>
      'Haven का अपना कोई सर्वर नहीं है। आपके एन्क्रिप्टेड अपडेट स्वतंत्र सर्वरों से होकर जाते हैं, जिन्हें रिले कहा जाता है। ये न आपका स्थान देखते हैं और न यह कि आपके सर्कलों में कौन है।';

  @override
  String get privacyWhatOthersSeeScreenshots =>
      'स्क्रीनशॉट का मामला ऑपरेटिंग सिस्टम पर निर्भर करता है, और दोनों सिस्टम इसमें अलग हैं। Android पर Haven पूरे ऐप में स्क्रीनशॉट और स्क्रीन रिकॉर्डिंग रोक देता है। iPhone पर वह ऐसा नहीं कर सकता: Haven ऐप स्विचर के पूर्वावलोकन को धुँधला कर देता है, पर कोई सदस्य फिर भी स्क्रीन पर दिख रही चीज़ को कैप्चर कर सकता है।';

  @override
  String get privacyWhatOthersSeeDetailExpiry =>
      'Haven रिले से कहता है कि स्थान संदेशों को करीब चार मिनट बाद हटा दें। यह कहना केवल एक अनुरोध है: कोई रिले उन्हें और देर तक रख सकता है। निमंत्रणों पर कोई समय-सीमा ही नहीं होती, और वे आपके इनबॉक्स रिले पर अनिश्चित काल तक पड़े रह सकते हैं।';

  @override
  String get privacyGroupTheLimitsHeading => 'सीमाएँ';

  @override
  String get privacyInferenceTitle =>
      'आपके बारे में फिर भी क्या पता चल सकता है';

  @override
  String get privacyInferenceSubtitle =>
      'वे निशान जिन्हें एन्क्रिप्शन नहीं ढक सकता';

  @override
  String get privacyInferenceWhatIsMetadata =>
      'एन्क्रिप्शन यह छिपाता है कि आप क्या भेजते हैं। यह इस बात को नहीं छिपा सकता कि आपने कुछ भेजा है। संदेश के आस-पास बनने वाला पैटर्न — वह कब गया, कितना बड़ा था, आप किन सर्वरों से जुड़े हुए थे — मेटाडेटा कहलाता है, और सामग्री न दिखने पर भी यह दिखता रहता है।';

  @override
  String get privacyInferenceActivityPattern =>
      'उसी पैटर्न से, आप जिस रिले का इस्तेमाल करते हैं, वह मोटे तौर पर जान सकता है कि आप कब सक्रिय रहते हैं और कितनी बार। Haven एक अतिरिक्त अपडेट तब भी भेजता है जब आप करीब सौ मीटर से ज़्यादा दूर चले जाते हैं, इसलिए काफ़ी लंबे रिकॉर्ड से इसका संकेत मिल सकता है कि आप चल रहे थे या एक ही जगह टिके थे — पर कहाँ थे, यह कभी नहीं दिखता।';

  @override
  String get privacyInferencePresence =>
      'जब तक Haven चल रहा है, वह आपके रिले से एक खुला कनेक्शन बनाए रखता है, इसलिए उन्हें यह भी दिखता है कि आप ऑनलाइन हैं और आप किन सर्कलों पर नज़र रख रहे हैं। अपडेट मिनटों की जगह सेकंडों में पहुँचें, इसकी यही कीमत है।';

  @override
  String get privacyInferenceIpHeading => 'आपका नेटवर्क पता';

  @override
  String get privacyInferenceIpAddress =>
      'Haven जिस भी सर्वर से बात करता है, उसे वह पता दिखता है जहाँ से आपका फ़ोन जुड़ता है: आपके रिले, मानचित्र प्रदाता, और वह जो किसी सदस्य की प्रोफ़ाइल फ़ोटो रखता है। आपका इंटरनेट प्रदाता देखता है कि आप इनमें से किन सर्वरों तक पहुँचे, और कब। Haven खुद इन दोनों में से किसी को भी नहीं छिपाता।';

  @override
  String get privacyInferenceVpnHeading => 'VPN इस्तेमाल करें या नहीं';

  @override
  String get privacyInferenceVpnHelps =>
      'VPN आपके पते की जगह अपना पता रख देता है, इसलिए रिले और बाकी सर्वरों को यह नहीं दिखता कि आप कहाँ से जुड़ रहे हैं। यह आपके इंटरनेट प्रदाता से यह भी छिपाता है कि आप किन सर्वरों तक पहुँचते हैं। हम Mullvad की सलाह देते हैं।';

  @override
  String get privacyInferenceVpnLimits =>
      'यह हर मर्ज़ की दवा नहीं है। VPN से यह ज़रा भी नहीं बदलता कि आपके सर्कल सदस्य क्या देखते हैं, और जिस रिले से आप बात कर रहे हैं, उससे यह आपके ट्रैफ़िक का समय और आकार नहीं छिपाता। यह किसी पर भरोसा करने की ज़रूरत खत्म नहीं करता, बल्कि आपका भरोसा VPN प्रदाता पर स्थानांतरित कर देता है।';

  @override
  String get privacyInferenceMeansForYou =>
      'अगर आपको यह चिंता है कि कोई व्यक्ति नहीं, बल्कि नेटवर्क चलाने वाला कोई आपको मानचित्र पर रख देगा, तो VPN वह एक चीज़ है जो सबसे ज़्यादा काम आएगी। और अगर आपको अपने सर्कलों के लोगों की चिंता है, तो इससे ज़रा भी मदद नहीं मिलेगी।';

  @override
  String get privacyInferenceDetailJitter =>
      'Haven जान-बूझकर अपडेट के बीच का अंतराल बदलता रहता है, इसलिए थोड़ी देर के रिकॉर्ड में कोई साफ़ लय नहीं दिखती। फिर भी कई घंटों का औसत निकालकर अपडेट की असली दर का अंदाज़ा लगाया जा सकता है। संदेशों का आकार बराबर करने के लिए उनमें कुछ भरा भी नहीं जाता, और स्थान अपडेट आकार के एक सँकरे दायरे में आते हैं, जिससे उन्हें स्थान अपडेट के रूप में पहचाना जा सकता है।';

  @override
  String get privacyInferenceDetailOutOfScope =>
      'कुछ चीज़ें ऐसी हैं जिनके बारे में Haven कुछ नहीं कर सकता। एक साथ कई रिले पर नज़र रख सकने वाला कोई पक्ष, या आपका अपना फ़ोन जब वह किसी और के काबू में आ जाए — ये ऐसी बातें हैं जिन्हें यहाँ किसी भी डिज़ाइन से ठीक नहीं किया जा सकता।';

  @override
  String get commonClearAll => 'सभी साफ़ करें';

  @override
  String commonMemberCount(int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$countString सदस्य',
      one: '1 सदस्य',
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
  String get circlesTitle => 'सर्कल';

  @override
  String get circlesRefreshTooltip => 'सर्कल रीफ़्रेश करें';

  @override
  String get circlesRequiresIdentity =>
      'सर्कल बनाने के लिए पहले पहचान सेटअप करनी होगी';

  @override
  String get circlesCreateCta => 'सर्कल बनाएँ';

  @override
  String get circlesYourCircles => 'आपके सर्कल';

  @override
  String get circlesEmptyTitle => 'अभी कोई सर्कल नहीं';

  @override
  String get circlesEmptyMessage =>
      'भरोसेमंद दोस्तों और परिवार के साथ अपना स्थान साझा करना शुरू करने के लिए एक सर्कल बनाएँ।';

  @override
  String get circlesSheetEmptyMessage =>
      'भरोसेमंद संपर्कों के साथ अपना स्थान साझा करना शुरू करने के लिए एक सर्कल बनाएँ।';

  @override
  String get circlesLoadError => 'सर्कल लोड नहीं हो सके';

  @override
  String get circlesSelectToView => 'सदस्य देखने के लिए कोई सर्कल चुनें';

  @override
  String get circlesNoMembers => 'इस सर्कल में कोई सदस्य नहीं है';

  @override
  String get createCircleTitle => 'सदस्य जोड़ें';

  @override
  String createCircleSelectedCount(int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    return 'चयनित ($countString)';
  }

  @override
  String get createCircleEmptyTitle => 'सर्कल सदस्य जोड़ें';

  @override
  String get createCircleEmptyMessage =>
      'सदस्य जोड़ने के लिए ID से खोजें या उनका QR कोड स्कैन करें।';

  @override
  String get createCircleNoValidMembers =>
      'आमंत्रित करने के लिए कोई मान्य सदस्य नहीं';

  @override
  String get createCircleMemberAlreadyAdded => 'सदस्य पहले से जोड़ा गया है';

  @override
  String get createCircleNoIdInQr => 'QR कोड में कोई मान्य ID नहीं मिली';

  @override
  String get createCircleNoAccountFound => 'कोई Haven खाता नहीं मिला';

  @override
  String get createCircleCouldNotVerify => 'सदस्य की पुष्टि नहीं हो सकी';

  @override
  String get createCircleSomethingWentWrong => 'कुछ गड़बड़ हो गई';

  @override
  String get nameCircleTitle => 'अपने सर्कल को नाम दें';

  @override
  String nameCircleMembersToInvite(int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$countString सदस्यों को आमंत्रित किया जाएगा',
      one: '1 सदस्य को आमंत्रित किया जाएगा',
    );
    return '$_temp0';
  }

  @override
  String get nameCircleNameLabel => 'सर्कल का नाम';

  @override
  String get nameCircleNameHint => 'जैसे, परिवार, करीबी दोस्त';

  @override
  String get nameCircleNameEmptyError => 'कृपया सर्कल का नाम दर्ज करें';

  @override
  String get nameCircleNameTooLongError =>
      'नाम 50 अक्षरों या उससे कम का होना चाहिए';

  @override
  String get nameCircleSharingInfo =>
      'इस सर्कल का हर सदस्य एक-दूसरे का स्थान और प्रदर्शन नाम देख सकता है। आपका प्रदर्शन नाम वही है जो आपने सेटिंग → पहचान में सेट किया है। यह सर्कल आपके किसी भी अन्य सर्कल से अलग रहता है, इसलिए इसके सदस्य आपके अन्य सर्कल या उनमें कौन है, यह नहीं देख सकते।';

  @override
  String get nameCircleCreateCta => 'सर्कल बनाएँ';

  @override
  String get nameCircleStageCreatingGroup => 'सुरक्षित समूह बनाया जा रहा है...';

  @override
  String get nameCircleStageSendingInvites => 'निमंत्रण भेजे जा रहे हैं...';

  @override
  String get nameCircleStageComplete => 'हो गया!';

  @override
  String nameCircleProgressSemantics(String stage) {
    return 'बनाने की प्रगति: $stage';
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
      other: 'सर्कल \"$name\" बन गया! $countString निमंत्रण भेजे गए।',
      one: 'सर्कल \"$name\" बन गया! 1 निमंत्रण भेजा गया।',
    );
    return '$_temp0';
  }

  @override
  String get nameCircleIdentityError =>
      'पहचान संबंधी त्रुटि। कृपया अपना पहचान सेटअप जाँचें।';

  @override
  String get nameCircleCreateError =>
      'सर्कल बनाने में विफल। कृपया फिर कोशिश करें।';

  @override
  String addMemberTitle(String circleName) {
    return '$circleName में जोड़ें';
  }

  @override
  String get addMemberInfo =>
      'नए सदस्य निमंत्रण स्वीकार करने के बाद इस सर्कल के एन्क्रिप्टेड स्थान देख सकते हैं।';

  @override
  String get addMemberAlreadyInCircle => 'पहले से इस सर्कल में है';

  @override
  String addMemberSendInvitation(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'निमंत्रण भेजें',
      one: 'निमंत्रण भेजें',
    );
    return '$_temp0';
  }

  @override
  String addMemberSendingInvitation(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'निमंत्रण भेजे जा रहे हैं...',
      one: 'निमंत्रण भेजा जा रहा है...',
    );
    return '$_temp0';
  }

  @override
  String addMemberSentToCircle(int count, String circleName) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$circleName को निमंत्रण भेजे गए',
      one: '$circleName को निमंत्रण भेजा गया',
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

    return 'निमंत्रण भेजे गए ($totalString में से $sentString)। बाकी की डिलीवरी लंबित है।';
  }

  @override
  String get addMemberError => 'सदस्य जोड़ने में विफल। कृपया फिर कोशिश करें।';

  @override
  String get qrScannerTitle => 'QR कोड स्कैन करें';

  @override
  String get qrScannerToggleFlash => 'फ़्लैश चालू/बंद करें';

  @override
  String get qrScannerSwitchCamera => 'कैमरा बदलें';

  @override
  String get qrScannerInstruction => 'QR कोड को फ़्रेम के भीतर रखें';

  @override
  String get qrScannerScanning => 'स्कैन हो रहा है...';

  @override
  String get circleMemberInvitationPending => 'निमंत्रण लंबित';

  @override
  String get circleMemberNoRecentLocation => 'कोई हालिया स्थान नहीं';

  @override
  String get circleMemberRemoveTooltip => 'सर्कल से हटाएँ';

  @override
  String get circleMemberAdmin => 'एडमिन';

  @override
  String get circleMemberHintPending => 'निमंत्रण लंबित';

  @override
  String get circleMemberHintNoLocation => 'कोई स्थान उपलब्ध नहीं';

  @override
  String get circleMemberHintMember => 'सदस्य';

  @override
  String get circleMemberHintTapToCenter =>
      'उनके स्थान पर मानचित्र केंद्रित करने के लिए टैप करें';

  @override
  String get pendingMemberRetryTooltip => 'पुष्टि फिर से करें';

  @override
  String get pendingMemberRemoveTooltip => 'सदस्य हटाएँ';

  @override
  String get pendingMemberValidating => 'पुष्टि हो रही है';

  @override
  String get pendingMemberValid => 'मान्य';

  @override
  String get pendingMemberWarning => 'चेतावनी';

  @override
  String get pendingMemberCheckingAvailability => 'उपलब्धता जाँची जा रही है...';

  @override
  String get pendingMemberReadyToInvite => 'आमंत्रित करने के लिए तैयार';

  @override
  String get pendingMemberNeedsUpdate => 'Haven अपडेट करना होगा';

  @override
  String get memberSearchHint => 'सदस्य ID दर्ज करें...';

  @override
  String get memberSearchPasteTooltip => 'क्लिपबोर्ड से पेस्ट करें';

  @override
  String get memberSearchAddTooltip => 'सदस्य जोड़ें';

  @override
  String get memberSearchScanTooltip => 'QR कोड स्कैन करें';

  @override
  String get memberSearchHelper => 'संपर्कों से उनका Haven QR कोड या ID माँगें';

  @override
  String get memberSearchNoValidId => 'कोई मान्य Haven ID नहीं मिली';

  @override
  String get memberSearchAlreadyAdded => 'सदस्य पहले से जोड़ा गया है';

  @override
  String selectedMembersMore(int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    return '+$countString और';
  }

  @override
  String get invitationStatusPending => 'निमंत्रण लंबित';

  @override
  String get invitationStatusActive => 'सक्रिय';

  @override
  String get invitationStatusDeclined => 'अस्वीकृत';

  @override
  String invitationStatusSemantics(String label) {
    return 'निमंत्रण स्थिति: $label';
  }

  @override
  String invitationCardSemantics(String circleName, String inviter, int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    return '$circleName में शामिल होने का निमंत्रण, $inviter द्वारा आमंत्रित, $countString सदस्य';
  }

  @override
  String invitationCardInvitedBySemantics(String inviter) {
    return 'क्रिप्टोग्राफ़िक पहचानकर्ता $inviter द्वारा आमंत्रित';
  }

  @override
  String invitationCardInvitedBy(String inviter) {
    return 'आमंत्रित करने वाला: $inviter';
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
      one: '1 सदस्य',
    );
    return '$_temp0';
  }

  @override
  String get invitationCardJustNow => 'अभी-अभी';

  @override
  String invitationCardDaysAgo(int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    return '${countString}d पहले';
  }

  @override
  String invitationCardHoursAgo(int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    return '${countString}h पहले';
  }

  @override
  String invitationCardMinutesAgo(int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    return '${countString}m पहले';
  }

  @override
  String get invitationCardDecline => 'अस्वीकार करें';

  @override
  String get invitationCardAccept => 'स्वीकार करें';

  @override
  String get invitationAcceptedSnack => 'निमंत्रण स्वीकार किया गया';

  @override
  String get invitationDeclinedSnack => 'निमंत्रण अस्वीकार किया गया';

  @override
  String get invitationAcceptError =>
      'निमंत्रण स्वीकार करने में विफल। कृपया फिर कोशिश करें।';

  @override
  String get invitationDeclineError =>
      'निमंत्रण अस्वीकार करने में विफल। कृपया फिर कोशिश करें।';

  @override
  String get circleSelectorLabel => 'सर्कल चयनकर्ता';

  @override
  String get circleSelectorPlaceholder => 'कोई सर्कल चुनें';

  @override
  String get circleSelectorNewCircle => 'नया सर्कल';

  @override
  String get circleSelectorLoadError => 'सर्कल लोड नहीं हो सके';

  @override
  String get circleSelectorExpandedAnnouncement => 'सर्कल सूची विस्तृत हुई';

  @override
  String get circleSelectorCollapsedAnnouncement => 'सर्कल सूची संक्षिप्त हुई';

  @override
  String get circleDetailsButtonTooltip => 'सर्कल विवरण';

  @override
  String get circleDetailsTitle => 'सर्कल विवरण';

  @override
  String get circleDetailsRelaysHeading => 'इस सर्कल के लिए रिले';

  @override
  String get circleDetailsNoRelays => '(कोई दर्ज नहीं)';

  @override
  String get circleDetailsRelaysNote =>
      'ये रिले इस सर्कल के बनने के समय चुने गए थे और अभी उपयोगकर्ता द्वारा संपादित नहीं किए जा सकते। ये आपकी निजी रिले सेटिंग से अलग हैं।';

  @override
  String get circleDetailsAddMember => 'सदस्य जोड़ें';

  @override
  String get circleDetailsLeaveCircle => 'सर्कल छोड़ें';

  @override
  String get leaveCircleDialogTitle => 'सर्कल छोड़ें';

  @override
  String get leaveCircleDialogBody =>
      'क्या आप वाकई यह सर्कल छोड़ना चाहते हैं? आपको अब इसके सदस्यों से स्थान अपडेट नहीं मिलेंगे। इस क्रिया को पूर्ववत नहीं किया जा सकता।';

  @override
  String get leaveCircleConfirm => 'छोड़ें';

  @override
  String get leaveCircleIdentityUnavailable => 'पहचान उपलब्ध नहीं';

  @override
  String get leaveCircleSuccess => 'सर्कल सफलतापूर्वक छोड़ा गया';

  @override
  String get leaveCircleError => 'सर्कल छोड़ने में विफल';

  @override
  String get circleBlockedBannerTitle => 'यह सर्कल अपडेट नहीं किया जा सकता';

  @override
  String get circleBlockedBannerBody =>
      'इस सर्कल की एन्क्रिप्शन में कुछ गड़बड़ हो गई, इसलिए Haven अब इसमें न तो अपडेट भेज सकता है और न ही प्राप्त कर सकता है। आपको आख़िरी बार जो पता था, वह आप अभी भी नीचे देख सकते हैं, या यह सर्कल छोड़ सकते हैं।';

  @override
  String get legacyCircleBannerTitle => 'इस सर्कल को फिर से बनाना ज़रूरी है';

  @override
  String get legacyCircleBannerBody =>
      'Haven का एन्क्रिप्शन इंजन अपग्रेड हो गया है, इसलिए यह सर्कल अब इस्तेमाल नहीं किया जा सकता। उन्हीं लोगों के साथ स्थान साझा करना जारी रखने के लिए इसे फिर से बनाएँ — आपको उन्हें दोबारा आमंत्रित करना होगा।';

  @override
  String get legacyCircleRecreateCta => 'सर्कल फिर से बनाएँ';

  @override
  String get legacyCircleRemoveCta => 'हटाएँ';

  @override
  String get legacyCircleRemoveDialogTitle => 'सर्कल हटाएँ?';

  @override
  String get legacyCircleRemoveDialogBody =>
      'यह सर्कल अब इस्तेमाल नहीं किया जा सकता और आपकी सूची से हटा दिया जाएगा। इसकी जगह आप जो भी नया सर्कल बनाएँगे, उस पर इसका कोई असर नहीं पड़ेगा।';

  @override
  String get legacyCircleRemoveConfirm => 'हटाएँ';

  @override
  String get legacyCutoverExplainerTitle => 'Haven अपडेट हो गया है';

  @override
  String get legacyCutoverExplainerIdentityUnchanged =>
      'आपकी पहचान और सार्वजनिक प्रोफ़ाइल पहले जैसी ही हैं — इनके लिए आपको कुछ नहीं करना है।';

  @override
  String get legacyCutoverExplainerCirclesNeedRecreation =>
      'बेहतर सुरक्षा के लिए, आपके सर्कल फिर से बनाने होंगे और उनके सदस्यों को दोबारा आमंत्रित करना होगा, तभी आप उनमें फिर से स्थान साझा कर पाएँगे।';

  @override
  String get legacyCutoverExplainerAcknowledge => 'ठीक है';

  @override
  String get relaySettingsLegacyRetractionPending =>
      'Haven अभी भी हाल के सुरक्षा अपडेट से कुछ डेटा साफ़ कर रहा है। आपके फिर से ऑनलाइन आते ही यह अपने आप पूरा हो जाएगा।';

  @override
  String get circlesPanelCollapsedAnnouncement => 'सर्कल पैनल संक्षिप्त हुआ';

  @override
  String get circlesPanelExpandedAnnouncement => 'सर्कल पैनल विस्तृत हुआ';

  @override
  String get circlesPanelSlightlyOpenAnnouncement => 'सर्कल पैनल थोड़ा खुला';

  @override
  String get circlesPanelHalfOpenAnnouncement => 'सर्कल पैनल आधा खुला';

  @override
  String get circleMemberAnnouncementSelf => 'आप';

  @override
  String get circleMemberAnnouncementFallback => 'सदस्य';

  @override
  String get invitationsRefreshTooltip => 'निमंत्रण रीफ़्रेश करें';

  @override
  String get invitationsLoadError => 'निमंत्रण लोड नहीं हो सके';

  @override
  String get invitationsEmptyTitle => 'कोई निमंत्रण नहीं';

  @override
  String get invitationsEmptyMessage =>
      'जब कोई आपको किसी सर्कल में आमंत्रित करेगा, तो वह यहाँ दिखेगा।';

  @override
  String get refreshRingSemanticNoInbox =>
      'कोई इनबॉक्स कॉन्फ़िगर नहीं है, रिले सेटिंग्स खोलता है';

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
      other: '$totalString में से $checkedString रिले जाँचे गए',
      one: '$totalString में से $checkedString रिले जाँचा गया',
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
      other: 'सभी $totalString रिले ने जवाब दिया',
      one: 'रिले ने जवाब दिया',
    );
    return '$_temp0';
  }

  @override
  String get refreshRingSemanticAllError => 'किसी भी रिले ने जवाब नहीं दिया';

  @override
  String refreshRingSemanticPartial(int ok, int total) {
    final intl.NumberFormat okNumberFormat = intl.NumberFormat.decimalPattern(
      localeName,
    );
    final String okString = okNumberFormat.format(ok);
    final intl.NumberFormat totalNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String totalString = totalNumberFormat.format(total);

    return '$totalString में से $okString रिले ने जवाब दिया';
  }

  @override
  String get refreshRingAnnouncementChecking => 'रिले जाँचे जा रहे हैं';

  @override
  String get refreshRingAnnouncementAllOk => 'सभी रिले ने जवाब दिया';

  @override
  String refreshRingAnnouncementPartial(int ok, int total) {
    final intl.NumberFormat okNumberFormat = intl.NumberFormat.decimalPattern(
      localeName,
    );
    final String okString = okNumberFormat.format(ok);
    final intl.NumberFormat totalNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String totalString = totalNumberFormat.format(total);

    return '$totalString में से $okString रिले ने जवाब दिया';
  }

  @override
  String get refreshRingAnnouncementAllError =>
      'किसी भी रिले तक नहीं पहुँचा जा सका';

  @override
  String get refreshRingAnnouncementNoInbox => 'कोई इनबॉक्स कॉन्फ़िगर नहीं है';

  @override
  String refreshRingSemanticAllFound(int total) {
    final intl.NumberFormat totalNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String totalString = totalNumberFormat.format(total);

    String _temp0 = intl.Intl.pluralLogic(
      total,
      locale: localeName,
      other: 'सभी $totalString रिले में आपका डेटा है',
      one: 'रिले में आपका डेटा है',
    );
    return '$_temp0';
  }

  @override
  String get refreshRingSemanticNoneFound =>
      'किसी भी रिले में आपका डेटा नहीं है';

  @override
  String refreshRingSemanticPartialFound(int ok, int total) {
    final intl.NumberFormat okNumberFormat = intl.NumberFormat.decimalPattern(
      localeName,
    );
    final String okString = okNumberFormat.format(ok);
    final intl.NumberFormat totalNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String totalString = totalNumberFormat.format(total);

    return '$totalString में से $okString रिले में आपका डेटा है';
  }

  @override
  String get refreshRingAnnouncementAllFound => 'सभी रिले में आपका डेटा है';

  @override
  String refreshRingAnnouncementPartialFound(int ok, int total) {
    final intl.NumberFormat okNumberFormat = intl.NumberFormat.decimalPattern(
      localeName,
    );
    final String okString = okNumberFormat.format(ok);
    final intl.NumberFormat totalNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String totalString = totalNumberFormat.format(total);

    return '$totalString में से $okString रिले में आपका डेटा है';
  }

  @override
  String get refreshRingAnnouncementNoneFound =>
      'किसी भी रिले में आपका डेटा नहीं है';

  @override
  String get identityTitle => 'पहचान';

  @override
  String get identityLoadError =>
      'आपकी पहचान लोड करने में कुछ गड़बड़ हो गई। कृपया फिर कोशिश करें।';

  @override
  String get identityMissingTitle => 'कोई पहचान नहीं';

  @override
  String get identityMissingMessage =>
      'आपकी पहचान चली गई है। Haven इस्तेमाल करते रहने के लिए एक नई पहचान सेटअप करें।';

  @override
  String get identitySetUpCta => 'पहचान सेटअप करें';

  @override
  String get identityPublicKeyQrTitle => 'सार्वजनिक कुंजी QR';

  @override
  String get identityPublicKeyQrSubtitle =>
      'दूसरे आपको सर्कल में कैसे आमंत्रित करते हैं';

  @override
  String get identityAdvancedTitle => 'उन्नत';

  @override
  String get identityAdvancedSubtitle => 'सार्वजनिक कुंजी, गुप्त कुंजी, हटाएँ';

  @override
  String get profileIsPublicNoticeTitle => 'प्रोफ़ाइल सार्वजनिक है';

  @override
  String get profileIsPublicNoticeBody =>
      'आपका प्रदर्शन नाम और फ़ोटो Nostr नेटवर्क पर किसी को भी दिखते हैं, केवल आपके सर्कलों के सदस्यों को ही नहीं। वही साझा करें जिसे सार्वजनिक करने में आप सहज हों।';

  @override
  String get identityRefreshProfileTooltip =>
      'सार्वजनिक प्रोफ़ाइल रीफ़्रेश करें';

  @override
  String get identityAdvancedExportError =>
      'गुप्त कुंजी निर्यात करने में विफल। कृपया फिर कोशिश करें।';

  @override
  String get identityAdvancedDeleteTitle => 'पहचान हटाएँ?';

  @override
  String get identityAdvancedDeleteBody =>
      'इससे आपकी पहचान स्थायी रूप से हट जाएगी। अगर आप इसे वापस पाना चाहते हैं तो सुनिश्चित करें कि आपने अपनी गुप्त कुंजी का बैकअप ले लिया है।';

  @override
  String get identityAdvancedDeleteConfirm => 'हटाएँ';

  @override
  String get identityAdvancedDeletedSnack => 'पहचान हटा दी गई';

  @override
  String get identityAdvancedDeleteError =>
      'पहचान हटाने में विफल। कृपया फिर कोशिश करें।';

  @override
  String identityAdvancedCopiedToClipboard(String label) {
    return '$label क्लिपबोर्ड पर कॉपी किया गया';
  }

  @override
  String get identityAdvancedSecretCopiedWarning =>
      'गुप्त कुंजी कॉपी की गई। चेतावनी: दूसरे ऐप आपका क्लिपबोर्ड पढ़ सकते हैं। इसे किसी सुरक्षित जगह पेस्ट करें और अपना क्लिपबोर्ड साफ़ करें।';

  @override
  String get identityAdvancedMissingBody => 'कोई पहचान सेटअप नहीं है।';

  @override
  String get identityAdvancedPublicKeyLabel => 'सार्वजनिक कुंजी';

  @override
  String get identityAdvancedPublicKeyHexLabel => 'सार्वजनिक कुंजी (hex)';

  @override
  String get identityAdvancedCopyValue => 'सार्वजनिक कुंजी';

  @override
  String get identityAdvancedCopyPublicKeyTooltip =>
      'सार्वजनिक कुंजी कॉपी करें';

  @override
  String get identityAdvancedCopyHexTooltip => 'hex कॉपी करें';

  @override
  String get identityAdvancedSecretKeyTitle => 'गुप्त कुंजी';

  @override
  String get identityAdvancedSecretKeyWarning =>
      'आपकी गुप्त कुंजी आपकी पहचान तक पूरी पहुँच देती है। इसे किसी के साथ कभी साझा न करें।';

  @override
  String get identityAdvancedRevealSecretKey => 'गुप्त कुंजी दिखाएँ';

  @override
  String get identityAdvancedHideSecretKey => 'गुप्त कुंजी छिपाएँ';

  @override
  String get identityAdvancedCopySecretKeyTooltip => 'गुप्त कुंजी कॉपी करें';

  @override
  String get identityAdvancedDeleteIdentityCta => 'पहचान हटाएँ';

  @override
  String get qrCodeLoadError =>
      'आपकी सार्वजनिक कुंजी लोड करने में कुछ गड़बड़ हो गई। कृपया फिर कोशिश करें।';

  @override
  String get qrCodeYourPublicKeyLabel => 'आपकी सार्वजनिक कुंजी';

  @override
  String get qrCodeWhatIsThisTitle => 'यह क्या है?';

  @override
  String get qrCodeExplainerKeys =>
      'Haven, Nostr पर चलता है, जो एक खुला नेटवर्क है जिसके पीछे कोई कंपनी खाता या साइन-अप नहीं है। आपकी पहचान बस कुंजियों की एक जोड़ी है: एक गुप्त कुंजी जो केवल आपके पास होती है, और इसी से बनी यह सार्वजनिक कुंजी।';

  @override
  String get qrCodeExplainerUsername =>
      'आपकी सार्वजनिक कुंजी एक ऐसे उपयोगकर्ता नाम की तरह काम करती है जिसे साझा करना सुरक्षित है। लोग आपको किसी सर्कल में आमंत्रित करने के लिए यह कोड स्कैन करते हैं, या आपकी सार्वजनिक कुंजी पेस्ट करते हैं। इसे साझा करने से आपका स्थान उजागर नहीं हो सकता, जो केवल उन सर्कलों के सदस्यों को दिखता है जिनमें आप शामिल हुए हैं। आपका प्रदर्शन नाम और फ़ोटो पहले से ही सार्वजनिक हैं, इसलिए इसे साझा करने से उनके बारे में और कुछ उजागर नहीं होता।';

  @override
  String get displayNameCardTitle => 'प्रदर्शन नाम';

  @override
  String get displayNameCardLoadError =>
      'आपका प्रदर्शन नाम लोड नहीं हो सका। बाद में फिर कोशिश करें।';

  @override
  String get displayNameCardHint => 'अपना प्रदर्शन नाम दर्ज करें';

  @override
  String get displayNameCardSavedLabel => 'प्रदर्शन नाम सहेजा गया';

  @override
  String get displayNameCardSaveLabel => 'प्रदर्शन नाम सहेजें';

  @override
  String get displayNameCardSavingLabel => 'प्रदर्शन नाम सहेजा जा रहा है';

  @override
  String get displayNameCardRetryLabel => 'सहेजना विफल। फिर कोशिश करें';

  @override
  String get displayNameCardSavedAnnouncement => 'प्रदर्शन नाम सहेजा गया';

  @override
  String get displayNameCardSaveFailedAnnouncement =>
      'सहेजना विफल, फिर कोशिश करें';

  @override
  String keyDisplayCopiedToClipboard(String label) {
    return '$label क्लिपबोर्ड पर कॉपी किया गया';
  }

  @override
  String keyDisplaySemantics(String label, String state) {
    return '$label: $state';
  }

  @override
  String get keyDisplayStateRevealed => 'दिखाई गई';

  @override
  String get keyDisplayStateHidden => 'छिपी हुई';

  @override
  String get keyDisplayHideTooltip => 'छिपाएँ';

  @override
  String get keyDisplayRevealTooltip => 'दिखाएँ';

  @override
  String get keyDisplayCopyTooltip => 'कॉपी करें';

  @override
  String get keyDisplayCompactCopied => 'कुंजी क्लिपबोर्ड पर कॉपी की गई';

  @override
  String get keyDisplayCompactTapToCopy => 'कॉपी करने के लिए टैप करें';

  @override
  String get npubQrCopiedSnack => 'सार्वजनिक कुंजी क्लिपबोर्ड पर कॉपी की गई';

  @override
  String get npubQrCopyButton => 'सार्वजनिक कुंजी कॉपी करें';

  @override
  String get circleMemberPublicKeyCopied =>
      'सार्वजनिक कुंजी क्लिपबोर्ड पर कॉपी की गई';

  @override
  String get circleMemberCopyPublicKeyHint => 'सार्वजनिक कुंजी कॉपी करें';

  @override
  String get circleMemberSetNicknameMenuItem => 'उपनाम सेट करें';

  @override
  String get circleMemberCopyPublicKeyMenuItem => 'सार्वजनिक कुंजी कॉपी करें';

  @override
  String get memberProfileRefreshErrorGeneric =>
      'प्रोफ़ाइलें रीफ़्रेश नहीं हो सकीं। कृपया फिर कोशिश करें।';

  @override
  String get memberDetailSheetTitle => 'सदस्य विवरण';

  @override
  String get memberNicknameSheetHint => 'एक उपनाम दर्ज करें';

  @override
  String get memberNicknameSheetLabel => 'उपनाम';

  @override
  String get memberNicknameSheetSave => 'उपनाम सहेजें';

  @override
  String get memberNicknameSheetClear => 'उपनाम हटाएँ';

  @override
  String get memberNicknameSheetSavedAnnouncement => 'उपनाम सहेजा गया';

  @override
  String get memberNicknameSheetClearedAnnouncement => 'उपनाम हटाया गया';

  @override
  String get npubQrScanLabel => 'मुझे जोड़ने के लिए स्कैन करें';

  @override
  String get npubQrSemanticsLabel => 'आपकी सार्वजनिक पहचान का QR कोड';

  @override
  String get photoHeaderRemoveTitle => 'प्रोफ़ाइल फ़ोटो हटाएँ?';

  @override
  String get photoHeaderRemoveBody =>
      'इससे आपकी फ़ोटो आपकी सार्वजनिक प्रोफ़ाइल से हट जाती है।';

  @override
  String get photoHeaderEditPhoto => 'फ़ोटो संपादित करें';

  @override
  String get photoHeaderRemove => 'हटाएँ';

  @override
  String get photoHeaderViewPhotoSemantics => 'प्रोफ़ाइल फ़ोटो देखें';

  @override
  String get photoHeaderAddPhotoSemantics => 'प्रोफ़ाइल फ़ोटो जोड़ें';

  @override
  String get photoHeaderChangePhotoSemantics => 'प्रोफ़ाइल फ़ोटो बदलें';

  @override
  String get avatarPickerPhotoUpdated =>
      'फ़ोटो अपडेट हुई — आपकी सार्वजनिक Nostr प्रोफ़ाइल पर प्रकाशित।';

  @override
  String get avatarPickerPhotoRemoved => 'फ़ोटो हटाई गई।';

  @override
  String get avatarPickerRemoveError =>
      'आपकी फ़ोटो हटाई नहीं जा सकी। कृपया फिर कोशिश करें।';

  @override
  String get avatarPickerUpdateError =>
      'आपकी फ़ोटो अपडेट नहीं हो सकी। कृपया फिर कोशिश करें।';

  @override
  String get avatarPickerCropTitle => 'फ़ोटो क्रॉप करें';

  @override
  String get avatarPickerCropDone => 'हो गया';

  @override
  String get avatarPickerCropCancel => 'रद्द करें';

  @override
  String get avatarFullscreenClose => 'बंद करें';

  @override
  String get avatarFullscreenSemantics => 'प्रोफ़ाइल फ़ोटो, पूरी स्क्रीन';

  @override
  String get avatarFullscreenLoadError => 'फ़ोटो लोड नहीं हो सकी';

  @override
  String get mapInitializing => 'आरंभ हो रहा है...';

  @override
  String get mapInitFailedTitle => 'आरंभ विफल';

  @override
  String get mapInitFailedMessage => 'स्थान सेवाएँ आरंभ करने में विफल।';

  @override
  String get mapInitFailedRetry => 'आरंभ विफल। कृपया फिर कोशिश करें।';

  @override
  String get mapLocationOffMessage =>
      'मानचित्र पर खुद को और अपने सर्कलों को देखने के लिए स्थान चालू करें।';

  @override
  String get mapGettingLocation => 'स्थान लिया जा रहा है...';

  @override
  String get mapLoadingMap => 'मानचित्र लोड हो रहा है...';

  @override
  String get mapLocationOffTitle => 'स्थान बंद है';

  @override
  String get mapLocationErrorTitle => 'स्थान त्रुटि';

  @override
  String get mapLocationUnavailable => 'स्थान अस्थायी रूप से अनुपलब्ध';

  @override
  String get mapThisLocation => 'यह स्थान';

  @override
  String get mapMemberFallbackName => 'सदस्य';

  @override
  String mapOpenInAppleMapsTitle(String label) {
    return '$label को Apple Maps में खोलें?';
  }

  @override
  String get mapOpenInAppleMapsBody =>
      'Apple Maps को केवल मानचित्र निर्देशांक भेजा जाता है, कभी कोई नाम या पहचान नहीं।';

  @override
  String get mapOpenInAppleMapsConfirm => 'Apple Maps में खोलें';

  @override
  String get mapOpenMapsError => 'Maps नहीं खुल सका';

  @override
  String get mapControlsZoomIn => 'ज़ूम इन करें';

  @override
  String get mapControlsZoomOut => 'ज़ूम आउट करें';

  @override
  String get mapControlsRecenter => 'फिर केंद्रित करें';

  @override
  String get mapControlsRecenterFab => 'मेरे स्थान पर फिर केंद्रित करें';

  @override
  String get mapAttributionCreditsButton => 'मानचित्र क्रेडिट और लाइसेंस';

  @override
  String userLocationMarkerSemantics(String accuracy) {
    return 'आपके स्थान का मार्कर$accuracy';
  }

  @override
  String userLocationMarkerAccuracy(int meters) {
    final intl.NumberFormat metersNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String metersString = metersNumberFormat.format(meters);

    return '. सटीकता: $metersString मीटर';
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
      other: '$countString मिनट पहले',
      one: '1 मिनट पहले',
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
      other: '$countString घंटे पहले',
      one: '1 घंटा पहले',
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
      other: '$countString दिन पहले',
      one: '1 दिन पहले',
    );
    return '$_temp0';
  }

  @override
  String memberMarkerNamedSemantics(String name) {
    return '$name का सदस्य मार्कर';
  }

  @override
  String get memberMarkerGenericSemantics => 'सदस्य मार्कर';

  @override
  String memberMarkerLastSeenSemantics(String base, String age) {
    return '$base, पिछली बार देखा गया $age';
  }

  @override
  String memberMarkerOffScreenSemantics(String name, String direction) {
    return '$name $direction की ओर स्क्रीन के बाहर है, देखने के लिए टैप करें';
  }

  @override
  String memberMarkerOffScreenGenericSemantics(String direction) {
    return 'एक सदस्य $direction की ओर स्क्रीन के बाहर है, देखने के लिए टैप करें';
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
  String get commonAdd => 'जोड़ें';

  @override
  String get addRelaySheetTitleInbox => 'इनबॉक्स रिले जोड़ें';

  @override
  String get addRelaySheetTitleKeyPackage => 'KeyPackage रिले जोड़ें';

  @override
  String get addRelaySheetHint => 'wss://relay.example.com';

  @override
  String get addRelaySheetPasteTooltip => 'क्लिपबोर्ड से पेस्ट करें';

  @override
  String get addRelaySheetErrorEmpty => 'एक रिले पता दर्ज करें।';

  @override
  String get addRelaySheetErrorInsecureScheme =>
      'wss:// इस्तेमाल करें ताकि इस रिले तक का ट्रैफ़िक एन्क्रिप्टेड रहे।';

  @override
  String get addRelaySheetErrorHasCredentials =>
      'रिले URL में क्रेडेंशियल नहीं होने चाहिए।';

  @override
  String get addRelaySheetErrorInvalidFormat =>
      'wss://relay.example.com जैसा रिले पता दर्ज करें।';

  @override
  String get avatarSemanticsLabel => 'उपयोगकर्ता अवतार';

  @override
  String avatarSemanticsFor(String initials) {
    return '$initials के लिए';
  }

  @override
  String get avatarSemanticsOnline => 'ऑनलाइन';

  @override
  String get avatarSemanticsOffline => 'ऑफ़लाइन';
}
