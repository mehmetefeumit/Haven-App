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
      'निजी और सेंसरशिप-प्रतिरोधी स्थान साझाकरण।';

  @override
  String get onboardingWelcomeCta => 'शुरू करें';

  @override
  String get onboardingValueProp1Title => 'केवल आपके सर्कल आपको देख सकते हैं';

  @override
  String get onboardingValueProp2Title => 'इसे कोई बंद नहीं कर सकता';

  @override
  String get onboardingValueProp3Title => 'किसी खाते की ज़रूरत नहीं';

  @override
  String get onboardingValueProp1Summary =>
      'आपके डिवाइस पर एन्क्रिप्टेड, ताकि इसे केवल आपके चुने हुए सर्कल ही पढ़ सकें। इसे ले जाने वाले रिले भी नहीं पढ़ सकते।';

  @override
  String get onboardingValueProp2Summary =>
      'कोई केंद्रीय सर्वर नहीं। यह स्वतंत्र रिले पर चलता है। इन्हें कई लोग चलाते हैं, इसलिए कोई एक कंपनी इसे बंद नहीं कर सकती।';

  @override
  String get onboardingValueProp3Summary =>
      'न ईमेल, न फ़ोन, न साइन-अप। आपकी गुप्त कुंजी कभी आपके फ़ोन से बाहर नहीं जाती। Haven का चुना बेनामी नाम रखें, या अपना चुनें।';

  @override
  String get onboardingCreateIdentityTitle => 'अपनी पहचान बनाएँ';

  @override
  String get onboardingCreateIdentityCta => 'मेरी पहचान बनाएँ';

  @override
  String get onboardingCreateIdentityLoading => 'सब कुछ तैयार किया जा रहा है…';

  @override
  String get onboardingFinishingSetup => 'सेटअप पूरा हो रहा है…';

  @override
  String get onboardingFinishSetupError =>
      'आपके खाते का सेटअप पूरा नहीं हो सका। अपना कनेक्शन जाँचें और फिर कोशिश करें।';

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
  String get settingsRelaysTitle => 'रिले';

  @override
  String get settingsLocationTitle => 'स्थान';

  @override
  String get settingsLocationSubtitleOn => 'बैकग्राउंड साझाकरण चालू है';

  @override
  String get settingsLocationSubtitleOff => 'सिर्फ़ Haven के खुले रहने तक';

  @override
  String get settingsMapStyleTitle => 'मानचित्र शैली';

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
      'जहाँ निमंत्रण आप तक पहुँचते हैं (kind 10050)';

  @override
  String get relaySettingsKeyPackageTitle => 'मेरे KeyPackage रिले';

  @override
  String get relaySettingsKeyPackageSubtitle =>
      'जहाँ दूसरे लोग आपको आमंत्रित करने के लिए ज़रूरी कुंजियाँ पाते हैं (kind 10002)';

  @override
  String get relaySettingsProfileTitle => 'मेरे प्रोफ़ाइल रिले';

  @override
  String get relaySettingsProfileSubtitle =>
      'जहाँ आपकी सार्वजनिक प्रोफ़ाइल खोजी जाती है और प्रकाशित होती है। ये रिले आपके बाकी रिले से अलग रखे जाते हैं, और इन रिले की सूची कभी प्रकाशित नहीं होती (kind 0)';

  @override
  String get relaySettingsProfileUnderflowTitle =>
      'प्रोफ़ाइल खोज फ़िलहाल रुकी हुई है';

  @override
  String get relaySettingsProfileUnderflowMessage =>
      'प्रोफ़ाइल रिले बहुत कम बचे हैं, इसलिए सदस्यों के नाम और फ़ोटो अपडेट होने बंद हो जाएँगे।';

  @override
  String get relaySettingsProfileUnderflowRestoreButton =>
      'डिफ़ॉल्ट प्रोफ़ाइल रिले बहाल करें';

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
  String get relaySettingsStatusChecking => 'जाँच हो रही है';

  @override
  String get relaySettingsStatusUnreachable => 'पहुँच नहीं सका';

  @override
  String relaySettingsKindLine(String kind, String status) {
    return '$kind: $status';
  }

  @override
  String get relaySettingsKindKeyPackage => 'KeyPackage';

  @override
  String get relaySettingsKindRelayList => 'रिले सूची';

  @override
  String get relaySettingsKindInboxList => 'इनबॉक्स सूची';

  @override
  String get relaySettingsPresencePublished => 'प्रकाशित';

  @override
  String get relaySettingsPresenceMissing => 'मौजूद नहीं';

  @override
  String get relaySettingsPresenceOutdated => 'पुराना संस्करण';

  @override
  String get relaySettingsLookupTitle => 'खोज रिले';

  @override
  String get relaySettingsLookupSubtitle =>
      'सार्वजनिक रिले, जहाँ दूसरे लोग आपको खोजते हैं। Haven यहाँ आपकी रिले सूचियों की एक कॉपी रखता है ताकि लोग आपको आमंत्रित कर सकें।';

  @override
  String get relaySettingsRepublish => 'फिर से प्रकाशित करें';

  @override
  String get relaySettingsRepublishDone =>
      'जवाब देने वाले हर रिले पर अब वह सब है जो दूसरों को आपको आमंत्रित करने के लिए चाहिए';

  @override
  String get relaySettingsRepublishIncomplete =>
      'कुछ रिले पर अब भी वह नहीं है जो दूसरों को आपको आमंत्रित करने के लिए चाहिए';

  @override
  String get relaySettingsRepublishHeld =>
      'जब तक आप रिले सेटिंग्स वाली सूचना से आगे न बढ़ें, तब तक Haven आपकी रिले सेटिंग्स या निमंत्रण कुंजी प्रकाशित नहीं करेगा';

  @override
  String get relaySettingsStatusNotChecked => 'जाँचा नहीं गया';

  @override
  String get relaySettingsEmptyTitle => 'कोई रिले कॉन्फ़िगर नहीं है';

  @override
  String get relaySettingsEmptyMessage =>
      'आपको कम से कम एक रिले चाहिए ताकि दूसरे आप तक पहुँच सकें। Haven डिफ़ॉल्ट बहाल करने के लिए नीचे टैप करें।';

  @override
  String get relaySettingsProfileContaminationTooltip =>
      'इस पर Haven का दूसरा ट्रैफ़िक भी जाता है';

  @override
  String relaySettingsProfileContaminationSemantics(String url) {
    return 'चेतावनी: $url पर आपका दूसरा Haven ट्रैफ़िक भी जाता है, जिससे यह रिले आपकी प्रोफ़ाइल को उस ट्रैफ़िक से जोड़ सकता है';
  }

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
  String get locationSettingsBatteryOptNote =>
      'Haven के लिए बैटरी ऑप्टिमाइज़ेशन अभी भी चालू है। कुछ फ़ोन इसका इस्तेमाल करके बैकग्राउंड साझाकरण को बिना बताए रोक देते हैं। साझाकरण को भरोसेमंद बनाए रखने के लिए Haven को इस ऑप्टिमाइज़ेशन से बाहर रखें।';

  @override
  String get locationSettingsErrorSnack => 'कुछ गड़बड़ हो गई';

  @override
  String get locationSettingsIntro =>
      'जब भी ऐप खुला होता है, Haven आपका स्थान आपके सर्कलों के साथ साझा करता है। इसे चालू करें और Haven के बैकग्राउंड में रहते हुए भी आपके सर्कल इसे देखते रहेंगे। अगर सिस्टम ने Haven को बंद कर दिया, तो आपका अपना साझाकरण रुक जाता है: Haven फिर भी आपके सर्कलों के स्थान लाने के लिए जाग सकता है, पर आपका स्थान भेजने के लिए कभी नहीं। Android पर, Haven को हाल के ऐप्स में से स्वाइप करके हटा देने पर भी साझाकरण चलता रहता है, और फ़ोन रीस्टार्ट होने के बाद साझाकरण अपने आप फिर चलने लगता है। iPhone पर, आपके Haven खोलने तक साझाकरण रुका ही रहता है।';

  @override
  String get locationSettingsToggleTitle => 'बैकग्राउंड में साझा करें';

  @override
  String get locationSettingsToggleSubtitle =>
      'Haven के बैकग्राउंड में रहते हुए भी साझा करते रहें';

  @override
  String get locationSettingsIosLimitedNote =>
      'आपकी मौजूदा अनुमति के साथ भी साझाकरण बैकग्राउंड में चलता रहता है, और तब iOS अपनी नीली स्थान पट्टी स्क्रीन के शीर्ष पर दिखाता है। सेटिंग में Haven के लिए स्थान को \'हमेशा\' पर सेट करें, ताकि iOS के ऐप बंद कर देने के बाद Haven आपके सर्कलों के छूटे हुए स्थान भी पा सके। \'हमेशा\' पर, iOS उस पट्टी के बजाय स्टेटस बार में अपना स्थान तीर दिखा सकता है। आपका अपना साझाकरण तो तभी फिर शुरू होता है जब आप Haven दोबारा खोलते हैं।';

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
      'जब बैकग्राउंड साझाकरण चालू होता है, तो Haven आपके स्थान का एक सत्र जारी रखता है, ताकि आपके सर्कल आपको देखते रहें।';

  @override
  String get locationSettingsIosIndicatorArrow =>
      'जब तक Haven आपके स्थान का उपयोग करता है, तब तक iOS अपना स्थान तीर स्टेटस बार में दिखाता है, और उसके बाद कुछ समय तक वही तीर \"स्थान सेवा\" सेटिंग में Haven के आगे बना रहता है।';

  @override
  String get locationSettingsIosIndicatorBar =>
      'आपकी \'हमेशा\' वाली अनुमति के साथ, जब तक Haven आपके स्थान का उपयोग करता है, iOS अपनी नीली स्थान पट्टी स्क्रीन के शीर्ष पर दिखाता है।';

  @override
  String get locationDisclosureTitle => 'आपका स्थान साझा करना';

  @override
  String get locationDisclosureWhy =>
      'Haven आपका लाइव स्थान आपके चुने हुए सर्कलों के लोगों को दिखाता है, और उनका स्थान आपको मानचित्र पर दिखाता है। इसके लिए Haven को आपके डिवाइस का सटीक स्थान इस्तेमाल करने की अनुमति चाहिए।';

  @override
  String get locationDisclosureHow =>
      'आपका स्थान आपके डिवाइस पर ही एंड-टू-एंड एन्क्रिप्ट हो जाता है, इसलिए इसे केवल आपके चुने हुए सर्कलों के सदस्य पढ़ सकते हैं — खुद Haven नहीं। Haven का अपना कोई सर्वर नहीं है: आपके एन्क्रिप्टेड अपडेट दूसरे लोगों के चलाए हुए स्वतंत्र रिले से होकर गुज़रते हैं, जो आपका नेटवर्क पता तो देखते हैं पर यह कभी नहीं कि आप कहाँ हैं। मानचित्र बनाने के लिए आपके और आपके सर्कल के आस-पास के इलाके Stadia Maps से माँगे जाते हैं, इसलिए Stadia Maps को मोटे तौर पर पता चल जाता है कि वे इलाके कहाँ हैं, पर आपका नाम, आपकी कुंजी या आपके सर्कलों में कौन है, यह उसे कभी पता नहीं चलता। Stadia Maps का कहना है कि वह निजी जानकारी न बेचती है न उसका व्यापार करती है, आपके डिवाइस पर कोई कुकी नहीं रखती, और अपने सर्वर लॉग लगभग दो हफ़्ते तक रखती है — यह उसकी अपनी नीति है, जिसे Haven लागू नहीं करा सकता।';

  @override
  String get locationDisclosureSharing =>
      'जब तक Haven खुला है और आप किसी सर्कल में हैं, आपका स्थान हर कुछ मिनट में अपने आप भेज दिया जाता है। इसे रोककर रखने का कोई विकल्प नहीं है। किसी सर्कल के साथ साझा करना बंद करने के लिए वह सर्कल छोड़ दें।';

  @override
  String get locationDisclosureBackgroundAndroid =>
      'यह ऐप स्थान डेटा का उपयोग करता है ताकि आपके सर्कलों के साथ साझाकरण तब भी हो सके जब ऐप बंद हो या उपयोग में न हो।';

  @override
  String get locationDisclosureBackgroundIos =>
      'यह ऐप स्थान डेटा का उपयोग करता है ताकि Haven के बैकग्राउंड में रहते हुए और आपके उसे इस्तेमाल न करते हुए भी आपके सर्कलों के साथ साझाकरण हो सके। अगर iOS ने Haven को बंद कर दिया, तो आपका अपना साझाकरण तब तक रुका रहेगा जब तक आप उसे दोबारा नहीं खोलते: Haven फिर भी आपके सर्कलों के स्थान लाने के लिए जाग सकता है, पर आपका स्थान भेजने के लिए कभी नहीं।';

  @override
  String get locationDisclosureManage =>
      'आप बैकग्राउंड साझाकरण किसी भी समय सेटिंग → स्थान में जाकर बंद कर सकते हैं।';

  @override
  String get locationDisclosureAgree => 'सहमत हूँ';

  @override
  String get locationDisclosureNotNow => 'अभी नहीं';

  @override
  String get fgsNotificationSharing =>
      'Haven स्थान की जानकारी भेज और प्राप्त कर रहा है';

  @override
  String get fgsNotificationPaused =>
      'Haven रुका हुआ है — साझाकरण फिर से शुरू करने के लिए ऐप खोलें';

  @override
  String get fgsNotificationOpen => 'Haven खुला है';

  @override
  String get fgsChannelName => 'स्थान साझाकरण';

  @override
  String get fgsChannelDescription =>
      'इससे Haven बैकग्राउंड में आपका एन्क्रिप्टेड स्थान साझा करता रहता है।';

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
  String get aboutFooterLicense => 'MIT License के तहत लाइसेंस प्राप्त';

  @override
  String aboutFooterVersion(String version) {
    return 'संस्करण $version';
  }

  @override
  String get relaySettingsBackendCaption =>
      'Haven का अपना कोई सर्वर नहीं है। आपके एन्क्रिप्टेड अपडेट स्वतंत्र सर्वरों से होकर जाते हैं, जिन्हें रिले कहा जाता है और जो न आपका स्थान पढ़ सकते हैं न आपके संदेश।';

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
  String get createCircleNoIdInQr => 'QR कोड में कोई मान्य ID नहीं मिली';

  @override
  String get memberLookupNotFound =>
      'इस ID के लिए अभी तक कोई Haven खाता नहीं मिला। अगर उन्होंने अभी-अभी Haven सेट अप किया है, तो एक मिनट बाद फिर कोशिश करें।';

  @override
  String get memberLookupIncomplete =>
      'इस ID की जाँच पूरी नहीं हो सकी। अपना कनेक्शन जाँचें और फिर कोशिश करें।';

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
      'इस सर्कल का हर सदस्य एक-दूसरे का स्थान, और एक-दूसरे का सार्वजनिक नाम और फ़ोटो देख सकता है। आपका नाम और फ़ोटो Nostr नेटवर्क पर सार्वजनिक हैं, इस सर्कल तक सीमित नहीं। यह सर्कल आपके किसी भी अन्य सर्कल से अलग रहता है, इसलिए इसके सदस्य आपके अन्य सर्कल या उनमें कौन है, यह नहीं देख सकते।';

  @override
  String get nameCircleCreateCta => 'सर्कल बनाएँ';

  @override
  String get nameCircleStageCreatingGroup => 'सुरक्षित समूह बनाया जा रहा है...';

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
  String nameCircleCreatedSentSoFarSnack(String name, int sent, int total) {
    final intl.NumberFormat sentNumberFormat = intl.NumberFormat.decimalPattern(
      localeName,
    );
    final String sentString = sentNumberFormat.format(sent);
    final intl.NumberFormat totalNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String totalString = totalNumberFormat.format(total);

    String _temp0 = intl.Intl.pluralLogic(
      total,
      locale: localeName,
      other:
          'सर्कल \"$name\" बन गया। अब तक भेजे गए निमंत्रण: $totalString में से $sentString। ऐप खुला रहने के दौरान Haven बाकी निमंत्रण ज़्यादा से ज़्यादा एक दिन तक भेजता रहता है।',
      one:
          'सर्कल \"$name\" बन गया। अब तक भेजे गए निमंत्रण: $totalString में से $sentString। ऐप खुला रहने के दौरान Haven इसे ज़्यादा से ज़्यादा एक दिन तक भेजता रहता है।',
    );
    return '$_temp0';
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
  String nameCircleRosterFullError(int limit) {
    final intl.NumberFormat limitNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String limitString = limitNumberFormat.format(limit);

    return 'आपके पास एक समय में $limitString सर्कल ही हो सकते हैं। नया सर्कल बनाने के लिए पहले कोई एक सर्कल छोड़ें।';
  }

  @override
  String get circleCreateRefusedNoLocationRelay =>
      'Haven यह सर्कल नहीं बना सकता: सर्कलों के लिए वह जिन रिले का इस्तेमाल करता है, वे सभी आपकी अपनी रिले सूचियों में हैं या कभी रह चुके हैं, इसलिए इनमें से कोई भी इस सर्कल के लिए इस्तेमाल नहीं हो सकता।';

  @override
  String addMemberTitle(String circleName) {
    return '$circleName में जोड़ें';
  }

  @override
  String get addMemberInfo =>
      'स्वीकार करने के बाद वे उस समय से आगे सबका स्थान देखेंगे, उनके शामिल होने से पहले भेजा गया कुछ भी नहीं। उन्हें इस सर्कल में पहले से मौजूद सभी लोगों की सार्वजनिक कुंजियाँ भी दिखेंगी।';

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
  String addMemberSentSoFar(int sent, int total, String circleName) {
    final intl.NumberFormat sentNumberFormat = intl.NumberFormat.decimalPattern(
      localeName,
    );
    final String sentString = sentNumberFormat.format(sent);
    final intl.NumberFormat totalNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String totalString = totalNumberFormat.format(total);

    String _temp0 = intl.Intl.pluralLogic(
      total,
      locale: localeName,
      other:
          '$circleName सर्कल के लिए अब तक भेजे गए निमंत्रण: $totalString में से $sentString। ऐप खुला रहने के दौरान Haven बाकी निमंत्रण ज़्यादा से ज़्यादा एक दिन तक भेजता रहता है।',
      one:
          '$circleName सर्कल के लिए अब तक भेजे गए निमंत्रण: $totalString में से $sentString। ऐप खुला रहने के दौरान Haven इसे ज़्यादा से ज़्यादा एक दिन तक भेजता रहता है।',
    );
    return '$_temp0';
  }

  @override
  String addMemberReinviteNeeded(String circleName) {
    return '$circleName सर्कल का निमंत्रण Haven नहीं भेज सकता। उस व्यक्ति को हटाकर फिर से जोड़ें।';
  }

  @override
  String get memberCannotReceiveInvitations =>
      'Haven आपके चुने हुए सभी लोगों को आमंत्रित नहीं कर सकता, क्योंकि उनमें से कम से कम एक व्यक्ति का निमंत्रण कहाँ भेजना है, यह उसे पता नहीं चल सका। आपने जिन लोगों को चुना है, उनसे कहें कि वे जाँच लें कि उनका ऐप निमंत्रण प्राप्त कर सकता है या नहीं, उसके बाद फिर कोशिश करें।';

  @override
  String get missedInvitationsShowWho => 'लोग दिखाएँ';

  @override
  String missedInvitationsTitle(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'निमंत्रण नहीं भेजे जा सके',
      one: 'निमंत्रण नहीं भेजा जा सका',
    );
    return '$_temp0';
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
  String get circleMemberNoRecentLocation => 'कोई हालिया स्थान नहीं';

  @override
  String get circleMemberRemoveTooltip => 'सर्कल से हटाएँ';

  @override
  String circleMemberRemoveDialogTitle(String name) {
    return '$name को हटाएँ?';
  }

  @override
  String get circleMemberRemoveDialogBody =>
      'जैसे ही यह बदलाव बाकी सर्कल तक पहुँच जाता है, वह व्यक्ति इस सर्कल में कुछ भी नया नहीं पढ़ पाता; आम तौर पर यह कुछ मिनटों में हो जाता है, और जो उस समय ऑफ़लाइन था उसके लिए इसमें ज़्यादा समय लगता है। जो कुछ उस व्यक्ति को पहले मिल चुका है, वह उसके फ़ोन पर बना रहता है। इसे पूर्ववत करने के लिए आपको उसे दोबारा निमंत्रण भेजना होगा।';

  @override
  String get circleMemberRemoveConfirm => 'हटाएँ';

  @override
  String circleMemberRemoveInProgress(String name) {
    return '$name को हटाया जा रहा है…';
  }

  @override
  String circleMemberRemoveSuccess(String name) {
    return '$name को सर्कल से हटा दिया गया';
  }

  @override
  String circleMemberRemoveError(String name) {
    return '$name को हटाया नहीं जा सका। कुछ नहीं बदला — अपना कनेक्शन जाँचें और दोबारा कोशिश करें।';
  }

  @override
  String circleMemberRemoveAwaitingAnnouncement(String name) {
    return '$name को अभी भी हटाया जा रहा है: रिले की पुष्टि का इंतज़ार है। जब तक यह पूरा नहीं होता, इस सर्कल के साथ कुछ भी साझा नहीं किया जाता।';
  }

  @override
  String get circleMemberAdmin => 'एडमिन';

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
  String get pendingMemberRemoveTooltip => 'सूची से हटाएँ';

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
  String get pendingMemberNeedsUpdate =>
      'उन्हें Haven अपडेट करना या खोलना होगा';

  @override
  String get memberKeyPackageStale =>
      'Haven अभी उन्हें आमंत्रित नहीं कर सकता। उनसे Haven खोलने के लिए कहें, उसके बाद फिर कोशिश करें।';

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
  String get memberPickerSectionRoster => 'आपके सर्कलों के सदस्य';

  @override
  String get memberPickerTierRoster => 'आपके सर्कलों की सदस्य सूची में';

  @override
  String get memberPickerNoMatches => 'आपके सर्कलों में कोई मिलान नहीं';

  @override
  String get memberPickerLoading =>
      'आपके सर्कलों के लोगों की सूची लोड हो रही है';

  @override
  String get memberPickerDirectoryUnavailable =>
      'आपके सर्कलों के लोगों की सूची फ़िलहाल लोड नहीं हो सकी';

  @override
  String memberPickerMatchesAnnouncement(int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    return 'मिलान: $countString';
  }

  @override
  String get memberPickerReasonSelf => 'यह आपकी अपनी ID है';

  @override
  String get memberPickerReadPublicKey => 'सार्वजनिक कुंजी पढ़कर सुनाएँ';

  @override
  String get memberPickerSectionRecent => 'हाल ही में आपके सर्कलों में';

  @override
  String get memberPickerTierRecent => 'हाल ही में आपके सर्कलों में';

  @override
  String get memberPickerNicknameNote =>
      'आपका रखा हुआ उपनाम, उनका सार्वजनिक नाम नहीं';

  @override
  String memberPickerCollisionCircleLabel(String circleName) {
    return 'सर्कल: $circleName';
  }

  @override
  String get memberPickerStrangerLookupNote =>
      'Haven ने इस व्यक्ति की प्रकाशित प्रोफ़ाइल एक रिले से माँगी — ज़्यादा से ज़्यादा दो रिले से। जिस भी रिले से पूछा गया, उसे दिखता है कि इस डिवाइस ने अभी-अभी इस कुंजी के बारे में पूछा है। लेकिन इस अनुरोध पर कोई डिजिटल हस्ताक्षर नहीं होता, इसलिए यह आपकी Haven पहचान से नहीं जुड़ता। अगर प्रोफ़ाइल में फ़ोटो है, तो Haven वह फ़ोटो उस सर्वर से डाउनलोड करता है जिसे इस व्यक्ति ने चुना है, और उस सर्वर को इस डिवाइस का नेटवर्क पता दिखता है।';

  @override
  String get memberPickerStrangerLookingUp =>
      'प्रकाशित प्रोफ़ाइल खोजी जा रही है…';

  @override
  String get memberPickerStrangerNotFound => 'कोई प्रकाशित नाम नहीं मिला';

  @override
  String memberPickerStrangerFoundAnnouncement(String name) {
    return 'प्रकाशित नाम: $name';
  }

  @override
  String selectedMembersMore(int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    return '+$countString और';
  }

  @override
  String get invitationCardHeading => 'सर्कल निमंत्रण';

  @override
  String invitationCardSemantics(String inviter) {
    return 'एक सर्कल में शामिल होने का निमंत्रण, $inviter की ओर से';
  }

  @override
  String invitationCardInvitedBySemantics(String inviter) {
    return 'क्रिप्टोग्राफ़िक पहचानकर्ता $inviter द्वारा आमंत्रित';
  }

  @override
  String invitationCardInvitedBy(String inviter) {
    return '$inviter की ओर से';
  }

  @override
  String get invitationCardNicknameNote =>
      'आपका रखा हुआ उपनाम, उनका सार्वजनिक नाम नहीं';

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
  String invitationNeedsNewInviteError(String name) {
    return 'यह निमंत्रण अब इस्तेमाल नहीं किया जा सकता। $name से आपको फिर से आमंत्रित करने के लिए कहें। हो सकता है उन्हें पहले Haven अपडेट करना पड़े।';
  }

  @override
  String get rejoinDialogTitle => 'क्या इस सर्कल में फिर से शामिल होना है?';

  @override
  String rejoinDialogBody(String inviterName, String circleName) {
    return '$inviterName ने आपको “$circleName” सर्कल में आमंत्रित किया है, जो इस फ़ोन पर पहले से है। ऐसा तब हो सकता है जब आपको सर्कल से हटाकर फिर से आमंत्रित किया गया हो। फिर से शामिल होने पर इस फ़ोन पर मौजूद सर्कल की कॉपी बदल दी जाएगी। “अस्वीकार करें” चुनने पर यह निमंत्रण हमेशा के लिए खत्म हो जाता है; “रद्द करें” चुनने पर यह बाद के लिए बना रहता है।';
  }

  @override
  String rejoinDialogBodyUnnamed(String circleName) {
    return 'आपको “$circleName” सर्कल में आमंत्रित किया गया है, जो इस फ़ोन पर पहले से है। ऐसा तब हो सकता है जब आपको सर्कल से हटाकर फिर से आमंत्रित किया गया हो। फिर से शामिल होने पर इस फ़ोन पर मौजूद सर्कल की कॉपी बदल दी जाएगी। “अस्वीकार करें” चुनने पर यह निमंत्रण हमेशा के लिए खत्म हो जाता है; “रद्द करें” चुनने पर यह बाद के लिए बना रहता है।';
  }

  @override
  String get rejoinDialogConfirm => 'फिर से शामिल हों';

  @override
  String invitationRosterFullError(int limit) {
    final intl.NumberFormat limitNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String limitString = limitNumberFormat.format(limit);

    return 'आपके पास एक समय में $limitString सर्कल ही हो सकते हैं। कोई एक सर्कल छोड़ें और फिर यह निमंत्रण स्वीकार करें — यह तब तक यहीं रहेगा।';
  }

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
  String circleDetailsMembersWithEpoch(String members, int epoch) {
    final intl.NumberFormat epochNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String epochString = epochNumberFormat.format(epoch);

    return '$members · एपोक $epochString';
  }

  @override
  String circleDetailsMetaWithExpiry(String meta, String expiry) {
    return '$meta · समय-सीमा $expiry';
  }

  @override
  String circleDetailsExpiryMinutesShort(int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$countString मिनट',
      one: '$countString मिनट',
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
      other: '$countString सेकंड',
      one: '$countString सेकंड',
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
      other: 'करीब $countString मिनट',
      one: 'करीब $countString मिनट',
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
      other: '$countString सेकंड',
      one: '$countString सेकंड',
    );
    return '$_temp0';
  }

  @override
  String circleDetailsExpirySemantics(String meta, String expiry) {
    return '$meta। Haven रिले से कहता है कि आप इस सर्कल में जो स्थान अपडेट भेजते हैं, उन्हें $expiry बाद हटा दें।';
  }

  @override
  String get circleDetailsRelaysHeading => 'इस सर्कल के लिए रिले';

  @override
  String get circleDetailsNoRelays => '(कोई दर्ज नहीं)';

  @override
  String get circleDetailsRelaysNote =>
      'इस सर्कल के एन्क्रिप्टेड अपडेट इन्हीं रिले से होकर जाते हैं। इन्हें सर्कल बनाते समय तय किया गया था और अभी Haven में बदला नहीं जा सकता; आपकी रिले सूची में बदलाव का इन पर कोई असर नहीं पड़ता।';

  @override
  String get circleDetailsAddMember => 'सदस्य जोड़ें';

  @override
  String get circleDetailsLeaveCircle => 'सर्कल छोड़ें';

  @override
  String get circleDetailsLeavingInProgress => 'सर्कल छोड़ा जा रहा है…';

  @override
  String get leaveCircleDialogTitle => 'सर्कल छोड़ें';

  @override
  String get leaveCircleDialogBody =>
      'यह सर्कल छोड़ें? आप इसके सदस्यों को अपना स्थान भेजना बंद कर देंगे और उनका स्थान देखना भी बंद हो जाएगा। आपने आखिरी बार जो स्थान भेजा था वह एक दिन तक उनके फ़ोन पर बना रहता है। इसे पूर्ववत नहीं किया जा सकता: दोबारा शामिल होने के लिए आपको नया निमंत्रण चाहिए होगा।';

  @override
  String get leaveDisbandedCircleDialogBody =>
      'यह सर्कल समाप्त हो गया है, इसलिए इसके साथ अब कुछ भी साझा नहीं किया जाता। इसे छोड़ने से यह इस फ़ोन से हट जाता है।';

  @override
  String get leaveCircleDialogAdminNote =>
      'आप इस सर्कल के एडमिन हैं। आपके सर्कल छोड़ने से पहले, Haven किसी दूसरे सदस्य को एडमिन बनाने की कोशिश करता है, ताकि सर्कल काम करता रहे।';

  @override
  String get leaveCircleConfirm => 'छोड़ें';

  @override
  String get leaveCircleIdentityUnavailable => 'पहचान उपलब्ध नहीं';

  @override
  String get leaveCircleSuccess => 'सर्कल सफलतापूर्वक छोड़ा गया';

  @override
  String get leaveCircleError => 'सर्कल छोड़ने में विफल';

  @override
  String get legacyCircleRecreateCta => 'सर्कल फिर से बनाएँ';

  @override
  String get storageResetTitle => 'Haven अपडेट हो गया है';

  @override
  String get storageResetKept =>
      'आपकी पहचान नहीं बदली है, और आपने जो सार्वजनिक प्रोफ़ाइल पहले ही प्रकाशित की है, वह जैसी है वैसी ही रहेगी।';

  @override
  String get storageResetLost =>
      'Haven के नए एन्क्रिप्शन इंजन पर जाने के लिए इस अपडेट से पहले बनाए गए सर्कल हटा दिए गए। उन्हें फिर से बनाएँ और उनके सदस्यों को दोबारा आमंत्रित करें। इस अपडेट से पहले आपने लोगों को जो उपनाम दिए थे, और प्रोफ़ाइल का कोई भी बदलाव जो तब तक पूरी तरह सहेजा नहीं गया था, वे भी हटा दिए गए।';

  @override
  String get storageResetRelays =>
      'इस अपडेट ने आपकी रिले सेटिंग्स को Haven की डिफ़ॉल्ट सेटिंग्स पर रीसेट कर दिया। जब तक आप आगे नहीं बढ़ते या रिले सेटिंग्स से वापस नहीं आते, तब तक ये सेटिंग्स प्रकाशित नहीं होंगी, इसलिए आप पहले अपने रिले जोड़ सकते हैं।';

  @override
  String get storageResetContinue => 'आगे बढ़ें';

  @override
  String get storageResetOpenRelaySettings => 'रिले सेटिंग्स';

  @override
  String get storageResetAcknowledgeFailed =>
      'Haven आपका जवाब सहेज नहीं सका। जब तक यह सहेजा नहीं जाता, Haven आपकी रिले सेटिंग्स या निमंत्रण कुंजी प्रकाशित नहीं करेगा, इसलिए अभी कोई आपको आमंत्रित नहीं कर सकता। फिर से कोशिश करें, नहीं तो अगली बार खुलने पर Haven फिर पूछेगा।';

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
      'इससे इस फ़ोन से आपकी पहचान और सर्कल का सारा डेटा हट जाता है। इसके तहत पहले जो कुछ प्रकाशित हो चुका है, वह जहाँ है वहीं बना रहता है: आपका नाम और कुंजियाँ उन रिले पर जिनके पास वे हैं, और आपकी फ़ोटो उस छवि सर्वर पर जहाँ वह रखी हुई है। अगर आप बाद में इस पहचान को वापस पाना चाहते हैं तो सुनिश्चित करें कि आपने अपनी गुप्त कुंजी का बैकअप ले लिया है।';

  @override
  String get identityAdvancedDeleteConfirm => 'हटाएँ';

  @override
  String get identityAdvancedDeletedSnack => 'पहचान हटा दी गई';

  @override
  String get identityAdvancedDeleteError =>
      'पहचान हटाने में विफल। कृपया फिर कोशिश करें।';

  @override
  String get identityAdvancedDeletingProgress => 'आपकी पहचान हटाई जा रही है…';

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
  String get reachabilityChecking => 'निमंत्रण पाने की तैयारी हो रही है…';

  @override
  String get reachabilityReady => 'निमंत्रण पाने के लिए तैयार';

  @override
  String get reachabilityCantCheck =>
      'अभी जाँच नहीं हो पा रही कि दूसरे लोग आपको आमंत्रित कर सकते हैं या नहीं';

  @override
  String get reachabilityNotReady => 'दूसरे लोग अभी आपको आमंत्रित नहीं कर सकते';

  @override
  String get reachabilityNoRelays =>
      'कोई रिले जोड़ने के बाद ही दूसरे लोग आपको आमंत्रित कर पाएँगे';

  @override
  String get reachabilityOpenRelaySettings => 'रिले सेटिंग्स';

  @override
  String get reachabilityAwaitingReset =>
      'रिले सेटिंग्स वाली सूचना से आगे बढ़ने के बाद दूसरे लोग आपको आमंत्रित कर पाएँगे';

  @override
  String get qrCodeWhatIsThisTitle => 'यह क्या है?';

  @override
  String get qrCodeExplainerKeys =>
      'Haven, Nostr पर चलता है, जो एक खुला नेटवर्क है जिसके पीछे कोई कंपनी खाता या साइन-अप नहीं है। आपकी पहचान बस कुंजियों की एक जोड़ी है: एक गुप्त कुंजी जो केवल आपके पास होती है, और इसी से बनी यह सार्वजनिक कुंजी।';

  @override
  String get qrCodeExplainerUsername =>
      'आपकी सार्वजनिक कुंजी एक ऐसे उपयोगकर्ता नाम की तरह काम करती है जिसे साझा करना सुरक्षित है। लोग आपको किसी सर्कल में आमंत्रित करने के लिए यह कोड स्कैन करते हैं, या आपकी सार्वजनिक कुंजी पेस्ट करते हैं। इसे साझा करने से यह उजागर नहीं हो सकता कि आप कहाँ हैं। आपका प्रदर्शन नाम और फ़ोटो पहले से ही सार्वजनिक हैं, इसलिए इससे कुछ और नहीं जुड़ता।';

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
      'इससे आपकी फ़ोटो आपकी सार्वजनिक प्रोफ़ाइल से हट जाती है। छवि फ़ाइल उस सर्वर पर बनी रहती है जो उसे रखता है, और जो प्रतियाँ दूसरे पहले ही डाउनलोड कर चुके हैं वे उनके पास बनी रहती हैं।';

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
  String get avatarPickerPhotoUpdatedAnnouncement => 'फ़ोटो अपडेट की गई।';

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
  String get mapLocationNoPermissionTitle =>
      'Haven आपके स्थान का उपयोग नहीं कर सकता';

  @override
  String get mapLocationSharingStoppedServiceOff =>
      'इस डिवाइस पर स्थान बंद है, इसलिए Haven ने आपका स्थान आपके सर्कलों के साथ साझा करना बंद कर दिया है। फिर से शुरू करने के लिए स्थान चालू करें।';

  @override
  String get mapLocationSharingStoppedPermission =>
      'Haven के पास अब आपके स्थान का उपयोग करने की अनुमति नहीं है, इसलिए साझाकरण रुक गया है। फिर से शुरू करने के लिए स्थान की अनुमति दें।';

  @override
  String get mapLocationSharingStoppedPermissionSettings =>
      'सिस्टम सेटिंग में Haven के लिए स्थान की अनुमति बंद है, इसलिए साझाकरण रुक गया है। फिर से शुरू करने के लिए वहीं इसकी अनुमति दें।';

  @override
  String get mapLocationSharingStoppedBoth =>
      'Haven ने आपका स्थान साझा करना बंद कर दिया है। इस डिवाइस पर स्थान चालू करें और Haven को इसका उपयोग करने की अनुमति दें।';

  @override
  String get mapLocationSharingStoppedUnknown =>
      'Haven को आपका स्थान मिलना बंद हो गया है, इसलिए साझाकरण रुक गया है। जाँचें कि स्थान चालू है और Haven को इसके उपयोग की अनुमति है।';

  @override
  String get mapLocationAccessRestoredAnnouncement =>
      'Haven फिर से आपके स्थान का उपयोग कर सकता है। साझाकरण दोबारा शुरू हो गया है।';

  @override
  String get clockSkewTitle => 'इस फ़ोन की घड़ी गलत है';

  @override
  String get clockSkewBodyRejected =>
      'आपके सर्कलों को आपका स्थान नहीं मिल रहा है, क्योंकि रिले उस समय को स्वीकार नहीं करते जो यह फ़ोन उस पर दर्ज करता है। इसे ठीक करने के लिए सिस्टम सेटिंग में तारीख और समय अपने आप सेट करना चालू करें।';

  @override
  String get clockSkewBodyBehind =>
      'इस फ़ोन की घड़ी आपके सर्कलों के बाकी सदस्यों से पीछे चल रही है, इसलिए आपके स्थान भेजे तो जाते हैं, पर उनकी समय-सीमा जल्दी खत्म हो जाती है, और आपके सर्कल उनमें से कुछ या सभी को देखने से चूक सकते हैं। इसे ठीक करने के लिए सिस्टम सेटिंग में तारीख और समय अपने आप सेट करना चालू करें।';

  @override
  String get clockSkewResolvedAnnouncement =>
      'घड़ी की समस्या ठीक हो गई है। Haven फिर से आपका स्थान साझा कर रहा है।';

  @override
  String get clockSkewTitleDisagreement =>
      'आपके सर्कलों में से किसी में कोई घड़ी गलत है';

  @override
  String get clockSkewBodyDisagreement =>
      'इस फ़ोन की घड़ी और एक अन्य सदस्य की घड़ी में दो मिनट या उससे ज़्यादा का अंतर है। अगर गलत घड़ी इस फ़ोन की हुई, तो इसके भेजे स्थानों की समय-सीमा किसी के देखने से पहले ही खत्म हो सकती है। यह पक्का करने के लिए कि गलत घड़ी इस फ़ोन की नहीं है, सिस्टम सेटिंग में तारीख और समय अपने आप सेट करना चालू करें।';

  @override
  String get clockSkewDisagreementResolvedAnnouncement =>
      'घड़ी की चेतावनी हट गई है।';

  @override
  String get sharingHealthTitleStopped => 'स्थान साझाकरण रुक गया है';

  @override
  String get sharingHealthTitleNotSending => 'आपका स्थान साझा नहीं हो रहा है';

  @override
  String get sharingHealthTitleNotReceiving =>
      'आपको दूसरों के स्थान नहीं मिल रहे हैं';

  @override
  String sharingHealthNoUpdatesMinutes(int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'करीब $countString मिनट से कोई अपडेट नहीं',
      one: 'करीब 1 मिनट से कोई अपडेट नहीं',
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
      other: 'करीब $countString घंटे से कोई अपडेट नहीं',
      one: 'करीब 1 घंटे से कोई अपडेट नहीं',
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
      other: 'करीब $countString दिन से कोई अपडेट नहीं',
      one: 'करीब 1 दिन से कोई अपडेट नहीं',
    );
    return '$_temp0';
  }

  @override
  String get sharingHealthRepairAction => 'ठीक करें';

  @override
  String get sharingHealthRepairSent =>
      'ठीक करने का बदलाव भेज दिया गया। जब यह दूसरों के फ़ोन तक पहुँच जाएगा, तब उनके अपडेट भी आने लगेंगे।';

  @override
  String get sharingHealthRepairNothingToDo =>
      'अभी ठीक करने के लिए कुछ नहीं है। Haven कोशिश करता रहेगा।';

  @override
  String get sharingHealthRepairUnresolvedAnnouncement =>
      'स्थान साझाकरण अभी भी काम नहीं कर रहा है।';

  @override
  String get sharingHealthResumedAnnouncement =>
      'स्थान साझाकरण फिर से काम कर रहा है।';

  @override
  String get sharingHealthTitleQuarantined =>
      'Haven अभी यह सर्कल नहीं खोल पा रहा है';

  @override
  String get sharingHealthBodyQuarantined =>
      'इस फ़ोन पर यह सर्कल लोड करते समय कुछ गड़बड़ हो गई। सर्कल अब भी यहीं है।';

  @override
  String get sharingHealthTitleDisbanded => 'यह सर्कल समाप्त हो गया है';

  @override
  String get sharingHealthBodyDisbanded =>
      'एक एडमिन ने यह सर्कल समाप्त कर दिया है, इसलिए इसके साथ अब कुछ भी साझा नहीं किया जाता। इसे इस फ़ोन से हटाने के लिए सर्कल छोड़ें।';

  @override
  String get sharingHealthQuarantineRetryHint =>
      'इस सर्कल को फिर से लोड करने की कोशिश करता है';

  @override
  String get sharingHealthQuarantineRetryFailedAnnouncement =>
      'Haven अभी भी यह सर्कल नहीं खोल पा रहा है।';

  @override
  String get sharingHealthTitleUnrecoverable =>
      'इस फ़ोन पर इस सर्कल ने काम करना बंद कर दिया है';

  @override
  String get sharingHealthBodyUnrecoverable =>
      'Haven अब इस फ़ोन पर इस सर्कल में न तो अपडेट भेज सकता है और न ही प्राप्त कर सकता है। इसके किसी एडमिन से कहें कि वे आपको हटाकर फिर से जोड़ दें। अगर कोई भी ऐसा न कर सके, तो उन्हीं लोगों के साथ एक नया सर्कल बनाएँ।';

  @override
  String get sharingHealthTitleStalled =>
      'Haven इस सर्कल के अपडेट नहीं पढ़ पा रहा है';

  @override
  String get sharingHealthBodyStalled =>
      'लगता है कि इस फ़ोन से सर्कल का कोई बदलाव छूट गया है, और यह फ़ोन उसे रिले पर नहीं ढूँढ पाया। इसके किसी एडमिन से कहें कि वे आपको हटाकर फिर से जोड़ दें। अगर कोई भी ऐसा न कर सके, तो उन्हीं लोगों के साथ एक नया सर्कल बनाएँ।';

  @override
  String get sharingHealthTitlePaused => 'Haven ने यह सर्कल रोक दिया है';

  @override
  String get sharingHealthBodyCollision =>
      'Haven को इस फ़ोन पर इस सर्कल में एक समस्या मिली, और आपका स्थान निजी रखने के लिए उसने इसके साथ साझा करना बंद कर दिया। इसे ठीक करने का एकमात्र तरीका सर्कल छोड़ना है। इसमें फिर से शामिल होने के लिए आपको नया निमंत्रण चाहिए होगा।';

  @override
  String get sharingHealthBodyCannotCheck =>
      'Haven इस फ़ोन पर इस सर्कल की जाँच नहीं कर सका, इसलिए आपका स्थान निजी रखने के लिए उसने इसके साथ साझा करना रोक दिया है। Haven अपने आप फिर से जाँच करेगा।';

  @override
  String get sharingHealthTitleLeaving => 'यह सर्कल छोड़ा जा रहा है';

  @override
  String get sharingHealthBodyLeaving =>
      'जब तक Haven इसे छोड़ने का काम पूरा करता है, तब तक इस सर्कल के साथ कुछ भी साझा नहीं किया जाता। इसमें करीब एक दिन लग सकता है। यह पूरा होने पर सर्कल इस फ़ोन से हट जाता है।';

  @override
  String get sharingHealthBodyRemovalUnmade =>
      'आपने जो हटाने का अनुरोध किया था, वह पूरा नहीं हुआ, इसलिए Haven ने इस सर्कल के साथ आपका स्थान साझा करना रोक दिया है, ताकि आपने जिस किसी को हटाना चाहा था, उसे आपका स्थान न दिखे।';

  @override
  String get sharingHealthBodyRemovalUnmadeNoNotice =>
      'आपने जो हटाने का अनुरोध किया था, वह पूरा नहीं हुआ, इसलिए Haven ने इस सर्कल के साथ आपका स्थान साझा करना रोक दिया है, ताकि आपने जिस किसी को हटाना चाहा था, उसे आपका स्थान न दिखे। कौन अभी भी सर्कल में है, यह देखने के लिए सदस्य सूची खोलें।';

  @override
  String get sharingHealthBodyDepartureDue =>
      'किसी ने यह सर्कल छोड़ा है, पर उसकी प्रक्रिया अभी पूरी नहीं हुई है। जब तक यह पूरी नहीं होती, Haven इस सर्कल के साथ आपका स्थान साझा नहीं करता।';

  @override
  String get sharingHealthTitleBackgroundPaused =>
      'इस सर्कल के लिए बैकग्राउंड साझाकरण रुका हुआ है';

  @override
  String get sharingHealthBodyAwaitsForeground =>
      'जब Haven बैकग्राउंड में था, तब इस सर्कल के रिले बदल गए। Haven खुला होने पर रिले बदलने का काम पूरा करता है; तब तक इस सर्कल के साथ बैकग्राउंड में साझा नहीं किया जाता।';

  @override
  String get sharingHealthBodyAwaitingRelays =>
      'इस सर्कल का एक बदलाव किसी रिले की पुष्टि का इंतज़ार कर रहा है। तब तक Haven न तो इस सर्कल को आपका स्थान भेज रहा है और न ही इससे आए नए स्थान दिखा रहा है। जब तक ऐप खुला है, Haven कोशिश करता रहता है।';

  @override
  String get sharingHealthBodyAcknowledged =>
      'एक रिले ने इस सर्कल का एक बदलाव स्वीकार कर लिया है और Haven उसे पूरा कर रहा है। तब तक इस सर्कल के अपडेट रुके रहते हैं।';

  @override
  String get sharingHealthBodyStagedWithoutRecord =>
      'इस सर्कल का एक बदलाव सहेजा नहीं जा सका, इसलिए वह भेजा नहीं गया। Haven इसे सुलझा लेता है, ज़्यादा से ज़्यादा अपने अगली बार शुरू होने पर। तब तक इस सर्कल के अपडेट रुके रहते हैं।';

  @override
  String get sharingHealthBodyStoredInput =>
      'इस फ़ोन पर इस सर्कल के कुछ ऐसे अपडेट हैं जिन्हें यह अभी तक प्रोसेस नहीं कर पाया है। जब तक यह इन्हें प्रोसेस नहीं कर लेता, Haven इस सर्कल के साथ आपका स्थान साझा नहीं करता।';

  @override
  String get sharingHealthBodySessionHeld =>
      'Haven अभी भी अपना पिछला कनेक्शन बंद कर रहा है, इसलिए स्थान साझाकरण रुका हुआ है। वह पूरा होते ही साझाकरण फिर शुरू हो जाता है। अपना फ़ोन रीस्टार्ट करने पर यह रुकावट हमेशा हट जाती है।';

  @override
  String get sharingHealthRepairHintAnyMember =>
      'रिले से दोबारा जुड़ता है, आपका स्थान फिर से भेजने की कोशिश करता है, और इस सर्कल को नई एन्क्रिप्शन कुंजियाँ दे सकता है';

  @override
  String get sharingHealthAttentionAnnouncement =>
      'इस सर्कल में स्थान साझाकरण पर ध्यान देने की ज़रूरत है। वजह जानने के लिए सर्कल विवरण खोलें।';

  @override
  String changeNoticeArrivedAnnouncement(String circleName) {
    return '$circleName सर्कल में हाल के बदलावों से जुड़ी एक बात पर आपका ध्यान चाहिए। उसे पढ़ने के लिए उस सर्कल का विवरण खोलें।';
  }

  @override
  String get circleDetailsAttentionTooltip =>
      'सर्कल विवरण, ध्यान देने की ज़रूरत है';

  @override
  String circleRowAttentionSemantics(String circleName) {
    return '$circleName, ध्यान देने की ज़रूरत है';
  }

  @override
  String get changeNoticeHeading => 'इस सर्कल में बदलाव';

  @override
  String get changeNoteRemovalUndone =>
      'इस सर्कल का एक बदलाव पूरा नहीं हो सका। अगर उसमें किसी को हटाया जाना था, तो वे अब भी सर्कल में हैं, और इस सर्कल के साथ जो कुछ साझा होता है, वह उन्हें दिखता है।';

  @override
  String get changeNoteChangeUndone =>
      'इस सर्कल का एक बदलाव पूरा नहीं हो सका, इसलिए कुछ नहीं बदला। अगर वह बदलाव आपका था और आपको अब भी उसकी ज़रूरत है, तो उसे फिर से करें।';

  @override
  String get changeNoteMayBeOutOfStep =>
      'हो सकता है कि इस सर्कल का कोई बदलाव इस फ़ोन को पता चले बिना दूसरों तक पहुँच गया हो, इसलिए हो सकता है कि यह फ़ोन उनसे तालमेल में न हो।';

  @override
  String get changeNoteReinviteOwed =>
      'आपने जिस व्यक्ति को आमंत्रित किया था, उनका नाम इस सर्कल की सूची में है, पर उनका शामिल होना संभव नहीं है, क्योंकि Haven उनका निमंत्रण नहीं भेज सकता। उन्हें हटाकर फिर से जोड़ें।';

  @override
  String get changeNoteChangeUnrecorded =>
      'इस सर्कल का एक बदलाव सहेजा नहीं जा सका, इसलिए वह भेजा नहीं गया।';

  @override
  String get changeNoteQueuedChangeDropped =>
      'इस सर्कल में इंतज़ार कर रहा एक बदलाव रद्द कर दिया गया, क्योंकि अब उसे माँगे गए तरीके से नहीं किया जा सकता था। हो सकता है कि वह किसी और तरीके से पहले ही हो चुका हो।';

  @override
  String get changeNoteQueuedChangesHeld =>
      'इस सर्कल के कुछ बदलाव अभी भी होने बाकी हैं।';

  @override
  String get changeNoteQueuedRemovalDropped =>
      'इस सर्कल में आपने जो हटाने का अनुरोध किया था, वह पूरा नहीं हुआ। आपने जिस किसी को हटाना चाहा था, हो सकता है वह अब भी सर्कल में हो।';

  @override
  String get changeNoteChangeWithdrawn =>
      'किसी दूसरे सदस्य के बदलाव ने इस सर्कल में आपके एक बदलाव की जगह ले ली, इसलिए आपका बदलाव नहीं किया गया। अगर आपको अब भी उसकी ज़रूरत है, तो उसे फिर से करें।';

  @override
  String get changeNoteWelcomeOwed =>
      'इस सर्कल का एक निमंत्रण अभी तक भेजा नहीं जा सका है। आपके आमंत्रित करने के बाद ज़्यादा से ज़्यादा एक दिन तक, जब भी ऐप खुला होता है, Haven इसे भेजता रहता है। अगर तब तक भी वह व्यक्ति शामिल न हो, तो उन्हें हटाकर फिर से जोड़ें।';

  @override
  String get changeNoteUnreadLocation =>
      'इस सर्कल में भेजे गए कुछ हाल के अपडेट इस फ़ोन पर खोले नहीं जा सके।';

  @override
  String get changeNoticeStillInCircleLabel => 'अब भी सर्कल में:';

  @override
  String get changeNoticeRemoveAgain => 'फिर से हटाएँ';

  @override
  String get changeNoticeReviewMembers => 'सदस्य देखें';

  @override
  String get changeNoticeKeepMembers => 'उन्हें सर्कल में रहने दें';

  @override
  String get changeNoticeKeepConfirmTitle => 'उन्हें सर्कल में रहने दें?';

  @override
  String get changeNoticeKeepConfirmBody =>
      'इस हटाने के अनुरोध की वजह से इस सर्कल के साथ साझा करने पर लगी रोक Haven हटा देगा। आपने जिस किसी को हटाना चाहा था और जो अब भी सर्कल में है, उसकी सदस्यता बनी रहेगी, और जब भी Haven इस सर्कल के साथ आपका स्थान साझा करेगा, उसे आपका स्थान दिखेगा।';

  @override
  String get changeNoticeKeepConfirmAction => 'उन्हें रहने दें';

  @override
  String circleMemberLastSeenMinutes(int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'आखिरी स्थान $countString मिनट पहले मिला',
      one: 'आखिरी स्थान 1 मिनट पहले मिला',
    );
    return '$_temp0';
  }

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
  String get userLocationMarkerSemantics => 'आपके स्थान का मार्कर';

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
      other: '$countString मिनट पहले',
      one: '1 मिनट पहले',
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
  String get addRelaySheetTitleProfile => 'प्रोफ़ाइल रिले जोड़ें';

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
