// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for German (`de`).
class AppLocalizationsDe extends AppLocalizations {
  AppLocalizationsDe([String locale = 'de']) : super(locale);

  @override
  String get appearanceTitle => 'Darstellung';

  @override
  String get appearanceThemeHeader => 'Design';

  @override
  String get appearanceThemeSystem => 'Systemstandard';

  @override
  String get appearanceThemeSystemSubtitle =>
      'An deine Geräteeinstellungen anpassen';

  @override
  String get appearanceThemeLight => 'Hell';

  @override
  String get appearanceThemeLightSubtitle => 'Immer das helle Design verwenden';

  @override
  String get appearanceThemeDark => 'Dunkel';

  @override
  String get appearanceThemeDarkSubtitle => 'Immer das dunkle Design verwenden';

  @override
  String get appearanceLanguageTitle => 'Sprache';

  @override
  String get languageSystemDefault => 'Systemstandard';

  @override
  String get commonTryAgain => 'Erneut versuchen';

  @override
  String get commonDismiss => 'Schließen';

  @override
  String get commonSettings => 'Einstellungen';

  @override
  String get commonInvitations => 'Einladungen';

  @override
  String commonPendingInvitations(int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$countString ausstehende Einladungen',
      one: '1 ausstehende Einladung',
    );
    return '$_temp0';
  }

  @override
  String get commonBack => 'Zurück';

  @override
  String get commonContinue => 'Weiter';

  @override
  String get commonSkip => 'Überspringen';

  @override
  String get commonRetry => 'Wiederholen';

  @override
  String onboardingStepOf(int current, int total) {
    final intl.NumberFormat currentNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String currentString = currentNumberFormat.format(current);
    final intl.NumberFormat totalNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String totalString = totalNumberFormat.format(total);

    return 'Schritt $currentString von $totalString';
  }

  @override
  String get onboardingAppName => 'Haven';

  @override
  String get onboardingWelcomeHeadline =>
      'Privates und zensurresistentes Teilen des Standorts.';

  @override
  String get onboardingWelcomeCta => 'Loslegen';

  @override
  String get onboardingValueProp1Title => 'Nur deine Kreise können dich sehen';

  @override
  String get onboardingValueProp2Title => 'Niemand kann es abschalten';

  @override
  String get onboardingValueProp3Title => 'Kein Konto erforderlich';

  @override
  String get onboardingValueProp1Summary =>
      'Auf deinem Gerät verschlüsselt, damit nur die Kreise, die du auswählst, ihn lesen können. Auch die Relays, die ihn weiterleiten, können das nicht.';

  @override
  String get onboardingValueProp2Summary =>
      'Kein zentraler Server. Es läuft über unabhängige Relays. Viele Menschen betreiben sie, deshalb kann kein einzelnes Unternehmen es abschalten.';

  @override
  String get onboardingValueProp3Summary =>
      'Ohne E-Mail, Telefon oder Anmeldung. Dein geheimer Schlüssel verlässt dein Telefon nie. Behalte den anonymen Namen, den Haven auswählt, oder wähle einen eigenen.';

  @override
  String get onboardingCreateIdentityTitle => 'Erstelle deine Identität';

  @override
  String get onboardingCreateIdentityCta => 'Meine Identität erstellen';

  @override
  String get onboardingCreateIdentityLoading => 'Wird eingerichtet …';

  @override
  String get onboardingCreateIdentityImportPrompt =>
      'Du hast bereits einen Schlüssel?';

  @override
  String get onboardingCreateIdentityImportLink => 'Stattdessen importieren';

  @override
  String get onboardingCreateIdentityError =>
      'Beim Erstellen deiner Identität ist etwas schiefgelaufen. Bitte versuche es erneut.';

  @override
  String get onboardingImportTitle => 'Importiere deinen vorhandenen Schlüssel';

  @override
  String get onboardingImportBody =>
      'Füge den geheimen Schlüssel ein, den du aus einer anderen Haven-kompatiblen App gesichert hast.';

  @override
  String get onboardingImportHint => 'nsec1…';

  @override
  String get onboardingImportCta => 'Importieren';

  @override
  String get onboardingImportLoading => 'Wird importiert …';

  @override
  String get onboardingImportInvalid =>
      'Das sieht nicht nach einem gültigen Sicherungsschlüssel aus. Bitte prüfe ihn und versuche es erneut.';

  @override
  String get onboardingImportError =>
      'Wir konnten diesen Schlüssel nicht importieren. Bitte prüfe ihn und versuche es erneut.';

  @override
  String get onboardingDisplayNameHint => 'z. B. Alex';

  @override
  String get onboardingDisplayNameError =>
      'Dieser Name konnte nicht gespeichert werden. Bitte versuche es erneut.';

  @override
  String get onboardingAddPhotoOptional => 'Foto hinzufügen (optional)';

  @override
  String get commonCancel => 'Abbrechen';

  @override
  String get commonOpenSettings => 'Einstellungen öffnen';

  @override
  String get settingsTitle => 'Einstellungen';

  @override
  String get settingsIdentityTitle => 'Identität';

  @override
  String get settingsRelaysTitle => 'Relays';

  @override
  String get settingsLocationTitle => 'Standort';

  @override
  String get settingsLocationSubtitleOn => 'Teilen im Hintergrund ist an';

  @override
  String get settingsLocationSubtitleOff => 'Nur solange Haven geöffnet ist';

  @override
  String get settingsMapStyleTitle => 'Kartenstil';

  @override
  String get settingsAboutTitle => 'Über';

  @override
  String get settingsHowItWorksTitle => 'So funktioniert Haven';

  @override
  String get settingsDebugOverlayTitle => 'Debug-Log-Overlay';

  @override
  String get settingsDebugOverlaySubtitle =>
      'Log-Ausgabe auf dem Bildschirm anzeigen';

  @override
  String get relaySettingsTitle => 'Relays';

  @override
  String get relaySettingsCheckRelaysTooltip => 'Relays prüfen';

  @override
  String get relaySettingsNoIdentityTitle => 'Keine Identität';

  @override
  String get relaySettingsNoIdentityMessage =>
      'Erstelle zuerst eine Identität, um Relays zu verwalten.';

  @override
  String get relaySettingsLoadIdentityError =>
      'Identität konnte nicht geladen werden.';

  @override
  String get relaySettingsInboxTitle => 'Meine Posteingangs-Relays';

  @override
  String get relaySettingsInboxSubtitle =>
      'Wo Einladungen dich erreichen (kind 10050)';

  @override
  String get relaySettingsKeyPackageTitle => 'Meine KeyPackage-Relays';

  @override
  String get relaySettingsKeyPackageSubtitle =>
      'Wo andere die Schlüssel finden, die sie brauchen, um dich einzuladen (kind 10002)';

  @override
  String get relaySettingsProfileTitle => 'Meine Profil-Relays';

  @override
  String get relaySettingsProfileSubtitle =>
      'Wo dein öffentliches Profil nachgeschlagen und veröffentlicht wird. Diese Relays bleiben von deinen übrigen Relays getrennt, und die Liste der Profil-Relays wird nie veröffentlicht (kind 0)';

  @override
  String get relaySettingsProfileUnderflowTitle => 'Profilabfragen pausiert';

  @override
  String get relaySettingsProfileUnderflowMessage =>
      'Es sind zu wenige Profil-Relays übrig, deshalb werden Namen und Fotos der Mitglieder nicht mehr aktualisiert.';

  @override
  String get relaySettingsProfileUnderflowRestoreButton =>
      'Standard-Profil-Relays wiederherstellen';

  @override
  String get relaySettingsLoadRelaysError =>
      'Relays konnten nicht geladen werden.';

  @override
  String get relaySettingsAddRelay => 'Relay hinzufügen';

  @override
  String get relaySettingsRestoreDefaults => 'Standardwerte wiederherstellen';

  @override
  String get relaySettingsAddRelayError =>
      'Relay konnte nicht hinzugefügt werden.';

  @override
  String get relaySettingsRemoveRelayError =>
      'Relay konnte nicht entfernt werden.';

  @override
  String get relaySettingsRestoreTitle => 'Standard-Relays wiederherstellen?';

  @override
  String relaySettingsRestoreBody(int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other:
          'Deine aktuellen $countString Relays werden durch Havens Standardwerte ersetzt. Dies kann nicht rückgängig gemacht werden.',
      one:
          'Dein aktuelles Relay wird durch Havens Standardwerte ersetzt. Dies kann nicht rückgängig gemacht werden.',
    );
    return '$_temp0';
  }

  @override
  String get relaySettingsRestoreConfirm => 'Wiederherstellen';

  @override
  String get relaySettingsRestoreSuccess => 'Standardwerte wiederhergestellt.';

  @override
  String get relaySettingsRestoreError =>
      'Standardwerte konnten nicht wiederhergestellt werden.';

  @override
  String relaySettingsRemoveTooltip(String url) {
    return '$url entfernen';
  }

  @override
  String get relaySettingsStatusConnected => 'Verbunden';

  @override
  String get relaySettingsStatusChecking => 'Wird geprüft';

  @override
  String get relaySettingsStatusUnreachable => 'Nicht erreichbar';

  @override
  String get relaySettingsStatusNotChecked => 'Nicht geprüft';

  @override
  String relaySettingsStatusSemantics(String status) {
    return 'Relay-Status: $status';
  }

  @override
  String get relaySettingsEmptyTitle => 'Keine Relays konfiguriert';

  @override
  String get relaySettingsEmptyMessage =>
      'Du brauchst mindestens ein Relay, damit andere dich erreichen können. Tippe unten, um die Haven-Standardwerte wiederherzustellen.';

  @override
  String get relaySettingsProfileContaminationTooltip =>
      'Hier läuft auch anderer Haven-Datenverkehr';

  @override
  String relaySettingsProfileContaminationSemantics(String url) {
    return 'Warnung: Über $url läuft auch dein übriger Haven-Datenverkehr, sodass dieses Relay dein Profil mit diesem Datenverkehr verknüpfen könnte';
  }

  @override
  String get locationSettingsTitle => 'Standort';

  @override
  String get locationSettingsDisabledSnack =>
      'Teilen im Hintergrund deaktiviert';

  @override
  String get locationSettingsEnabledSnack => 'Teilen im Hintergrund aktiviert';

  @override
  String get locationSettingsNotificationDeniedSnack =>
      'Das Teilen im Hintergrund benötigt eine Benachrichtigung, damit Android es weiterlaufen lässt. Es ist vorerst aus. Aktiviere Benachrichtigungen für Haven, um es einzuschalten.';

  @override
  String get locationSettingsBatteryOptSnack =>
      'Aktiviert. Die Akkuoptimierung kann das Teilen auf manchen Telefonen pausieren. Schließe Haven von der Akkuoptimierung aus, damit es zuverlässig bleibt.';

  @override
  String get locationSettingsBatteryOptNote =>
      'Die Akkuoptimierung ist für Haven weiterhin aktiviert. Manche Telefone stoppen damit ohne Vorwarnung das Teilen im Hintergrund. Schließe Haven davon aus, damit das Teilen zuverlässig bleibt.';

  @override
  String get locationSettingsErrorSnack => 'Etwas ist schiefgelaufen';

  @override
  String get locationSettingsIntro =>
      'Haven teilt deinen Standort mit deinen Kreisen, solange die App geöffnet ist. Schalte das hier ein, und deine Kreise sehen ihn weiter, während Haven im Hintergrund läuft. Beendet das System Haven, wird dein eigener Standort nicht mehr geteilt: Haven kann zwar noch aufwachen, um die Standorte deiner Kreise abzurufen, aber nie, um deinen zu senden. Unter Android läuft das Teilen weiter, wenn du Haven aus dem App-Umschalter wischst, und startet nach einem Neustart des Geräts von allein wieder. Auf dem iPhone bleibt das Teilen gestoppt, bis du Haven öffnest.';

  @override
  String get locationSettingsToggleTitle => 'Im Hintergrund teilen';

  @override
  String get locationSettingsToggleSubtitle =>
      'Weiter teilen, solange Haven im Hintergrund läuft';

  @override
  String get locationSettingsIosLimitedNote =>
      'Das Teilen läuft mit deiner aktuellen Berechtigung auch im Hintergrund weiter, und iOS zeigt dabei oben am Bildschirm seine blaue Standortleiste. Setze in den Einstellungen für Haven den Standortzugriff auf „Immer“, damit Haven auch dann noch die verpassten Standorte deiner Kreise nachholen kann, wenn iOS die App beendet hat. Unter „Immer“ zeigt iOS statt der blauen Standortleiste möglicherweise seinen Standortpfeil in der Statusleiste. Dein eigener Standort wird erst wieder geteilt, wenn du Haven erneut öffnest.';

  @override
  String get locationSettingsAndroidHeader =>
      'Systemeinstellungen für Zuverlässigkeit';

  @override
  String get locationSettingsAndroidNotification =>
      'Haven benötigt eine dauerhafte Benachrichtigung, damit Android den Hintergrunddienst am Leben hält. Falls du die Benachrichtigungsberechtigung verweigert hast, öffne die Einstellungen und erlaube Benachrichtigungen für Haven.';

  @override
  String get locationSettingsAndroidBattery =>
      'Für zuverlässiges Teilen im Hintergrund schließe Haven außerdem von der Akkuoptimierung aus. Gehe zu Einstellungen → Apps → Haven → Akku → Immer zulassen.';

  @override
  String get locationSettingsAndroidVendors =>
      'Entferne auf Samsung-Geräten Haven aus den „Ruhenden Apps“ (Gerätewartung → Akku → Nutzungsbeschränkungen im Hintergrund). Aktiviere auf Xiaomi den Autostart für Haven.';

  @override
  String get locationSettingsIosGuidance =>
      'Solange das Teilen im Hintergrund aktiviert ist, hält Haven eine Standortsitzung aufrecht, damit deine Kreise dich weiterhin sehen.';

  @override
  String get locationSettingsIosIndicatorArrow =>
      'iOS zeigt seinen Standortpfeil in der Statusleiste, solange Haven deinen Standort verwendet, und lässt denselben Pfeil danach noch eine Weile neben Haven unter „Ortungsdienste“ stehen.';

  @override
  String get locationSettingsIosIndicatorBar =>
      'Mit deiner Berechtigung „Immer“ zeigt iOS oben am Bildschirm seine blaue Standortleiste, solange Haven deinen Standort verwendet.';

  @override
  String get locationDisclosureTitle => 'Deinen Standort teilen';

  @override
  String get locationDisclosureWhy =>
      'Haven zeigt deinen Live-Standort den Personen in den Kreisen, die du auswählst, und zeigt dir ihren Standort auf der Karte. Dafür benötigt Haven die Berechtigung, den genauen Standort deines Geräts zu verwenden.';

  @override
  String get locationDisclosureHow =>
      'Dein Standort wird auf deinem Gerät Ende-zu-Ende-verschlüsselt, sodass nur die Mitglieder der Kreise, die du auswählst, ihn lesen können – Haven nicht. Haven hat keine eigenen Server: Deine verschlüsselten Aktualisierungen laufen über unabhängige Relays, die andere Leute betreiben. Diese Relays sehen deine Netzwerkadresse, aber nie, wo du bist. Um die Karte zu zeichnen, fragt Haven bei Stadia Maps die Gebiete rund um dich und deinen Kreis ab. Stadia Maps erfährt dadurch ungefähr, wo das ist, aber nie deinen Namen, deinen Schlüssel oder wer in deinen Kreisen ist. Stadia Maps gibt an, personenbezogene Daten weder zu verkaufen noch zu tauschen, keine Cookies auf deinem Gerät zu setzen und Server-Protokolle etwa zwei Wochen lang aufzubewahren – die eigene Richtlinie des Anbieters, auf die Haven keinen Einfluss hat.';

  @override
  String get locationDisclosureSharing =>
      'Solange Haven geöffnet ist und du in einem Kreis bist, wird dein Standort automatisch alle paar Minuten gesendet. Pausieren ist nicht möglich. Um das Teilen mit einem Kreis zu beenden, verlasse ihn.';

  @override
  String get locationDisclosureBackgroundAndroid =>
      'Diese App nutzt Standortdaten, um das Teilen mit deinen Kreisen zu ermöglichen, auch wenn die App geschlossen ist oder nicht verwendet wird.';

  @override
  String get locationDisclosureBackgroundIos =>
      'Diese App nutzt Standortdaten, um das Teilen mit deinen Kreisen zu ermöglichen, auch wenn Haven im Hintergrund läuft und du die App gerade nicht benutzt. Beendet iOS Haven, wird dein Standort nicht mehr geteilt, bis du Haven wieder öffnest – Haven kann zwar noch aufwachen, um die Standorte deiner Kreise abzurufen, aber nie, um deinen zu senden.';

  @override
  String get locationDisclosureManage =>
      'Du kannst das Teilen im Hintergrund jederzeit unter Einstellungen → Standort ausschalten.';

  @override
  String get locationDisclosureAgree => 'Zustimmen';

  @override
  String get locationDisclosureNotNow => 'Jetzt nicht';

  @override
  String get fgsNotificationSharing =>
      'Haven sendet und empfängt Standortdaten';

  @override
  String get fgsNotificationPaused =>
      'Haven ist angehalten – öffne die App, um das Teilen fortzusetzen';

  @override
  String get fgsNotificationOpen => 'Haven ist geöffnet';

  @override
  String get fgsChannelName => 'Standortfreigabe';

  @override
  String get fgsChannelDescription =>
      'Haven teilt deinen verschlüsselten Standort weiterhin, während die App im Hintergrund läuft.';

  @override
  String get mapStyleTitle => 'Kartenstil';

  @override
  String get mapStyleMinimalTitle => 'Minimal';

  @override
  String get mapStyleMinimalSubtitle =>
      'Ruhige, detailarme Fläche, die deinem hellen oder dunklen Design folgt';

  @override
  String get mapStyleDetailedTitle => 'Detailliert';

  @override
  String get mapStyleDetailedSubtitle =>
      'Straßen, Beschriftungen und Orte in voller Farbe';

  @override
  String get mapStyleOutdoorsTitle => 'Outdoor';

  @override
  String get mapStyleOutdoorsSubtitle =>
      'Schattiertes Gelände mit Wegen und Parks';

  @override
  String get mapStylePreviewHeader => 'Vorschau';

  @override
  String get mapStylePreviewCity => 'Stadt';

  @override
  String get mapStylePreviewNature => 'Natur';

  @override
  String mapStylePreviewSemantics(String scene, String style) {
    return 'Kartenvorschau ($scene): $style';
  }

  @override
  String get mapStylePreviewUnavailableSemantics =>
      'Kartenvorschau in diesem Build nicht verfügbar';

  @override
  String get mapStylePreviewUnavailableLabel =>
      'Die Live-Vorschau erscheint in Release-Builds';

  @override
  String get aboutTitle => 'Über';

  @override
  String get aboutHeroName => 'Haven';

  @override
  String get aboutHeroTagline =>
      'Privates und zensurresistentes Teilen des Standorts.';

  @override
  String get aboutLicensesTitle => 'Open-Source-Lizenzen';

  @override
  String get aboutLicensesLegalese => '© 2026 Haven · MIT License';

  @override
  String get aboutReportMapIssue => 'Kartenproblem melden';

  @override
  String get aboutSupportOsm => 'OpenStreetMap unterstützen';

  @override
  String get aboutMapAttribution =>
      '© Stadia Maps · © OpenMapTiles · © OpenStreetMap contributors\nKartendaten lizenziert unter ODbL';

  @override
  String get aboutLinkOpenError => 'Link konnte nicht geöffnet werden';

  @override
  String get aboutFooterLicense => 'Lizenziert unter der MIT License';

  @override
  String aboutFooterVersion(String version) {
    return 'Version $version';
  }

  @override
  String get howItWorksTitle => 'So funktioniert Haven';

  @override
  String get howItWorksIntro =>
      'Mit Haven teilst du deinen Live-Standort mit kleinen Gruppen von Menschen, den sogenannten Kreisen. Dein Standort wird schon auf deinem Telefon verschlossen, bevor er es verlässt. So können ihn weder die Dienste lesen, die ihn übermitteln, noch die Menschen, die Haven entwickeln.';

  @override
  String get howItWorksIdentityHeading => 'Deine Identität';

  @override
  String get howItWorksIdentityKeys =>
      'Wenn du Haven zum ersten Mal öffnest, erstellt dein Telefon deine Identität. Sie besteht aus zwei zusammengehörigen Schlüsseln, also langen Codes. Dein öffentlicher Schlüssel funktioniert wie ein Benutzername. Du kannst ihn gefahrlos teilen, und andere scannen ihn oder fügen ihn ein, um dich zu einem Kreis einzuladen. Dein geheimer Schlüssel beweist, dass du wirklich du bist. Er bleibt in einem geschützten Bereich deines Telefons, und Haven sendet ihn nie über das Internet.';

  @override
  String get howItWorksIdentityBackup =>
      'Es gibt keine Registrierung, keine E-Mail-Adresse und keine Telefonnummer. Deshalb kann kein Unternehmen deine Identität für dich zurücksetzen, und Haven bewahrt keine weitere Kopie deines geheimen Schlüssels auf. Du kannst ihn in den Einstellungen unter „Identität“ ansehen und eine Kopie an einem sicheren, privaten Ort aufbewahren. Deine Kreise lassen sich nicht auf ein anderes Telefon übertragen. Auf einem neuen Telefon bräuchtest du daher neue Einladungen, um ihnen wieder beizutreten.';

  @override
  String get howItWorksIdentityProfile =>
      'Dein Anzeigename und dein Foto sind öffentlich. Wenn du sie speicherst, veröffentlicht Haven sie als dein Profil im Nostr-Netzwerk. Das Foto liegt dabei auf einem separaten Fotoserver. Jeder kann beides abrufen. Haven gibt dir zu Beginn einen zufällig erfundenen Namen, damit du nicht deinen echten verwenden musst.';

  @override
  String get howItWorksNostrHeading => 'Das Nostr-Netzwerk';

  @override
  String get howItWorksNostrRelays =>
      'Haven basiert auf Nostr, einem offenen Netzwerk, über das Nachrichten im Internet weitergegeben werden. Es gehört niemandem, und niemand kontrolliert es. Nachrichten laufen über Relays. Das sind Server (Computer, die dauerhaft online sind), die von vielen unabhängigen Menschen und Organisationen betrieben werden. Jeder kann ein Relay betreiben, und Haven betreibt selbst keines.';

  @override
  String get howItWorksNostrChecks =>
      'Haven prüft jede Nachricht, die ankommt. So kann ein Relay keine Nachricht heimlich verändern und auch keine im Namen einer anderen Person fälschen. Ein Relay kann Nachrichten aber weiterhin verzögern oder löschen, und jedes Relay entscheidet selbst, was es annimmt und wie lange es etwas aufbewahrt. Weil das Netzwerk keinen zentralen Server hat, betreibt es kein einzelnes Unternehmen, und keines kann dich von deiner Identität aussperren.';

  @override
  String get howItWorksNostrYourRelays =>
      'Deine Identität nutzt eigene Relays. Sie speichern dein Profil und nehmen deine Einladungen entgegen. Du findest sie in den Einstellungen auf der Seite „Relays“ und kannst dort weitere hinzufügen. Jeder Kreis sendet seine Aktualisierungen über seine eigenen Relays. Diese siehst du in den Details des jeweiligen Kreises.';

  @override
  String get howItWorksEncryptionHeading =>
      'Verschlüsselung mit MLS und Marmot';

  @override
  String get howItWorksEncryptionStandards =>
      'Dieses Verschließen nennt man Verschlüsselung. Dabei werden Informationen so unlesbar gemacht, dass nur jemand mit dem richtigen Schlüssel sie wieder lesbar machen (entschlüsseln) kann. Haven nutzt MLS (Messaging Layer Security), einen offenen Standard für verschlüsselte Gruppennachrichten. Veröffentlicht hat ihn die IETF, ein Gremium von Fachleuten, das Internetstandards entwickelt. Marmot ist ein Protokoll, also ein gemeinsames Regelwerk, mit dem MLS-Nachrichten über Nostr übertragen werden. Auch andere Apps nutzen Marmot.';

  @override
  String get howItWorksEncryptionCircleKeys =>
      'Jeder Kreis hat eigene geheime Schlüssel. Sie sind von deinen Identitätsschlüsseln getrennt, und nur die Telefone seiner Mitglieder besitzen sie. Dein Telefon verschlüsselt deinen Standort damit, bevor er es verlässt, und nur Telefone in diesem Kreis können ihn entschlüsseln. Weil jeder Kreis andere Schlüssel hat, sehen die Mitglieder eines Kreises weder deine anderen Kreise noch, wer darin ist.';

  @override
  String get howItWorksInvitationsHeading => 'Einladungen und Mitglieder';

  @override
  String get howItWorksInvitations =>
      'Haven veröffentlicht für dich einen öffentlichen Einladungsschlüssel auf deinen Relays. So können andere dich einladen, auch während dein Telefon offline ist. Kreise werden von Admins verwaltet. Sie entscheiden, wer eingeladen und wer entfernt wird. Eine Einladung steckt in mehreren Schichten Verschlüsselung. Ein Relay kann sehen, an wen sie gerichtet ist, aber die Einladung selbst verrät nicht, wer sie gesendet hat oder für welchen Kreis sie ist. Eine eingeladene Person teilt ihren Standort erst mit dem Kreis, wenn sie die Einladung annimmt.';

  @override
  String get howItWorksMembership =>
      'Wenn jemand eingeladen oder entfernt wird, wechselt der Kreis zu neuen Schlüsseln. Wenn jemand den Kreis verlässt, bittet das Telefon dieser Person die anderen, diesen Wechsel vorzunehmen. Tut das niemand, bleibt die Person im Kreis, bis ein Admin sie entfernt. Ein neues Mitglied kann lesen, was der Kreis ab dem Moment seiner Einladung teilt, aber nichts von davor. Nach einem Wechsel kann jemand, der den Kreis verlassen hat oder entfernt wurde, nichts Neues mehr lesen. Die Person kann aber möglicherweise noch erkennen, wann der Kreis aktiv ist. Was bereits auf ihrem Telefon angekommen ist, bleibt dort. Mitglieder sehen gegenseitig ihre Standorte, Anzeigenamen, Fotos und öffentlichen Schlüssel.';

  @override
  String get howItWorksSharingHeading => 'Deinen Standort teilen';

  @override
  String get howItWorksSharingWhen =>
      'Solange Haven geöffnet ist, teilt die App deinen Standort regelmäßig mit jedem deiner Kreise. Du kannst außerdem in den Einstellungen auf der Seite „Standort“ das Teilen im Hintergrund einschalten. Dann geht das Teilen weiter, während du andere Apps nutzt. Wie gut das funktioniert, hängt von deinem Telefon und seinen Einstellungen ab.';

  @override
  String get howItWorksSharingUpdate =>
      'Jede Aktualisierung wird auf deinem Telefon verschlüsselt und an die Relays des Kreises gesendet, und zwar unter einem ganz neuen Schlüssel, der nur einmal verwendet und dann weggeworfen wird. Die Aktualisierung allein nennt deshalb nicht, wer sie gesendet hat. Jede Aktualisierung bittet die Relays außerdem, sie nach ein paar Minuten zu löschen. Das wird von den Relays erwartet, aber nichts zwingt sie dazu, und die Aktualisierung bleibt in jedem Fall verschlüsselt. Die Telefone deiner Kreismitglieder holen sie ab, entschlüsseln sie und zeigen dich auf ihrer Karte.';

  @override
  String get howItWorksMapHeading => 'Die Karte';

  @override
  String get howItWorksMap =>
      'Die Kartenbilder stammen von einem Online-Kartendienst. Haven fragt dort die Gebiete ab, die du dir ansiehst, und die Gebiete rund um deine Kreismitglieder. Dadurch kann der Dienst ungefähr erkennen, um welche Orte es sich handelt. Er erfährt aber weder deinen Namen noch deine Schlüssel noch, wer in deinen Kreisen ist.';

  @override
  String get howItWorksOnDeviceHeading => 'Auf deinem Telefon';

  @override
  String get howItWorksOnDevice =>
      'Haven speichert deine Kreise in einer verschlüsselten Datenbank auf deinem Telefon und legt den Schlüssel zu dieser Datenbank im geschützten Speicher des Telefons ab. Haven betreibt keine eigenen Server und enthält keinen Code, der verfolgt, wie du die App nutzt, oder dir Werbung zeigt. Der Quellcode, also die Anweisungen, aus denen die App besteht, ist öffentlich. So kann jeder nachprüfen, wie sie funktioniert.';

  @override
  String get howItWorksLimitsHeading => 'Was Haven nicht verbergen kann';

  @override
  String get howItWorksLimitsAddress =>
      'Relays, der Kartendienst und Fotoserver können die Netzwerkadresse deines Telefons sehen, also seine IP-Adresse. Das ist eine Nummer, die deine Internetverbindung kennzeichnet. Sie kann Hinweise auf deine ungefähre Gegend geben. Außerdem können Relays mit ihrer Hilfe deine Aktualisierungen, deine Kreise und deinen öffentlichen Schlüssel miteinander in Verbindung bringen, besonders wenn sie untereinander teilen, was sie sehen. Ein VPN, also ein Dienst, der deinen Internetverkehr über seine eigenen Computer leitet, kann deine Adresse verbergen, indem er stattdessen seine eigene zeigt.';

  @override
  String get howItWorksLimitsPatterns =>
      'Relays können sehen, wann Aktualisierungen gesendet werden, wie groß sie ungefähr sind und welche Aktualisierungen zum selben Kreis gehören. Am Zeitpunkt der Aktualisierungen lässt sich außerdem erkennen, welche Kreise zum selben Telefon gehören und in wie vielen Kreisen du ungefähr bist. Wer den Internetverkehr beobachtet, etwa ein Internetanbieter, kann möglicherweise erkennen, dass du Haven nutzt und welche Telefone wahrscheinlich im selben Kreis sind. Haven ist nicht dafür gemacht, deine Aktivität vor jemandem zu verbergen, der viele Relays gleichzeitig beobachten kann.';

  @override
  String get howItWorksLimitsPeople =>
      'Die Personen in deinen Kreisen sehen, wo du bist, und zwar so genau, wie dein Telefon es meldet. Teile deinen Standort deshalb nur mit Menschen, denen du vertraust. Wenn du deinen Namen oder dein Foto später entfernst, werden Kopien, die andere bereits haben, nicht gelöscht, und ein entferntes Foto bleibt auf dem Server, der es gespeichert hat. Außerdem kann Haven deine Daten nicht vor jemandem schützen, der die Kontrolle über dein Telefon hat.';

  @override
  String get relaySettingsBackendCaption =>
      'Haven hat keinen eigenen Server. Deine verschlüsselten Aktualisierungen laufen über unabhängige Server, Relays genannt, die deinen Standort und deine Nachrichten nicht lesen können.';

  @override
  String get commonClearAll => 'Alle löschen';

  @override
  String commonMemberCount(int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$countString Mitglieder',
      one: '1 Mitglied',
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
  String get circlesTitle => 'Kreise';

  @override
  String get circlesRefreshTooltip => 'Kreise aktualisieren';

  @override
  String get circlesRequiresIdentity =>
      'Zum Erstellen eines Kreises muss zuerst eine Identität eingerichtet werden';

  @override
  String get circlesCreateCta => 'Kreis erstellen';

  @override
  String get circlesYourCircles => 'Deine Kreise';

  @override
  String get circlesEmptyTitle => 'Noch keine Kreise';

  @override
  String get circlesEmptyMessage =>
      'Erstelle einen Kreis, um deinen Standort mit vertrauten Freunden und Familie zu teilen.';

  @override
  String get circlesSheetEmptyMessage =>
      'Erstelle einen Kreis, um deinen Standort mit vertrauten Kontakten zu teilen.';

  @override
  String get circlesLoadError => 'Kreise konnten nicht geladen werden';

  @override
  String get circlesSelectToView =>
      'Wähle einen Kreis aus, um die Mitglieder anzuzeigen';

  @override
  String get circlesNoMembers => 'Keine Mitglieder in diesem Kreis';

  @override
  String get createCircleTitle => 'Mitglieder hinzufügen';

  @override
  String createCircleSelectedCount(int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    return 'Ausgewählt ($countString)';
  }

  @override
  String get createCircleEmptyTitle => 'Kreismitglieder hinzufügen';

  @override
  String get createCircleEmptyMessage =>
      'Suche per ID oder scanne den QR-Code, um Mitglieder hinzuzufügen.';

  @override
  String get createCircleNoValidMembers =>
      'Keine gültigen Mitglieder zum Einladen';

  @override
  String get createCircleNoIdInQr => 'Keine gültige ID im QR-Code gefunden';

  @override
  String get createCircleNoAccountFound =>
      'Für diese ID wurde kein Haven-Konto gefunden';

  @override
  String get createCircleCouldNotVerify =>
      'Mitglied konnte nicht überprüft werden';

  @override
  String get createCircleSomethingWentWrong => 'Etwas ist schiefgelaufen';

  @override
  String get nameCircleTitle => 'Benenne deinen Kreis';

  @override
  String nameCircleMembersToInvite(int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$countString Mitglieder werden eingeladen',
      one: '1 Mitglied wird eingeladen',
    );
    return '$_temp0';
  }

  @override
  String get nameCircleNameLabel => 'Kreisname';

  @override
  String get nameCircleNameHint => 'z. B. Familie, enge Freunde';

  @override
  String get nameCircleNameEmptyError => 'Bitte gib einen Kreisnamen ein';

  @override
  String get nameCircleNameTooLongError =>
      'Der Name darf höchstens 50 Zeichen lang sein';

  @override
  String get nameCircleSharingInfo =>
      'Alle in diesem Kreis können den Standort sowie den öffentlichen Namen und das Foto der anderen sehen. Dein Name und dein Foto sind im Nostr-Netzwerk öffentlich und nicht auf diesen Kreis beschränkt. Dieser Kreis bleibt von allen anderen, in denen du bist, getrennt, sodass seine Mitglieder deine anderen Kreise oder deren Mitglieder nicht sehen können.';

  @override
  String get nameCircleCreateCta => 'Kreis erstellen';

  @override
  String get nameCircleStageCreatingGroup => 'Sichere Gruppe wird erstellt …';

  @override
  String get nameCircleStageComplete => 'Fertig!';

  @override
  String nameCircleProgressSemantics(String stage) {
    return 'Erstellungsfortschritt: $stage';
  }

  @override
  String nameCirclePercentComplete(int percent) {
    final intl.NumberFormat percentNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String percentString = percentNumberFormat.format(percent);

    return '$percentString Prozent abgeschlossen';
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
          'Kreis „$name“ erstellt. Bisher $sentString von $totalString Einladungen gesendet. Haven versucht weiterhin, die übrigen zu senden, solange die App geöffnet ist, bis zu einem Tag lang.',
      one:
          'Kreis „$name“ erstellt. Bisher $sentString von 1 Einladung gesendet. Haven versucht weiterhin, sie zu senden, solange die App geöffnet ist, bis zu einem Tag lang.',
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
      other: 'Kreis „$name“ erstellt! $countString Einladungen gesendet.',
      one: 'Kreis „$name“ erstellt! 1 Einladung gesendet.',
    );
    return '$_temp0';
  }

  @override
  String get nameCircleIdentityError =>
      'Identitätsfehler. Bitte überprüfe deine Identitätseinrichtung.';

  @override
  String get nameCircleCreateError =>
      'Kreis konnte nicht erstellt werden. Bitte versuche es erneut.';

  @override
  String nameCircleRosterFullError(int limit) {
    final intl.NumberFormat limitNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String limitString = limitNumberFormat.format(limit);

    return 'Du kannst gleichzeitig in höchstens $limitString Kreisen sein. Verlasse einen Kreis, um Platz für einen neuen zu schaffen.';
  }

  @override
  String get circleCreateRefusedNoLocationRelay =>
      'Haven kann diesen Kreis nicht erstellen: Alle Relays, die Haven für Kreise nutzt, stehen auf deinen eigenen Relay-Listen oder standen früher dort, deshalb kann keines davon den Kreis übertragen.';

  @override
  String addMemberTitle(String circleName) {
    return 'Zu $circleName hinzufügen';
  }

  @override
  String get addMemberInfo =>
      'Sobald die Person annimmt, sieht sie ab diesem Zeitpunkt die Standorte aller, nie aber etwas, das vor ihrem Beitritt gesendet wurde. Sie sieht außerdem die öffentlichen Schlüssel aller, die bereits in diesem Kreis sind.';

  @override
  String get addMemberAlreadyInCircle => 'Bereits in diesem Kreis';

  @override
  String addMemberSendInvitation(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Einladungen senden',
      one: 'Einladung senden',
    );
    return '$_temp0';
  }

  @override
  String addMemberSendingInvitation(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Einladungen werden gesendet …',
      one: 'Einladung wird gesendet …',
    );
    return '$_temp0';
  }

  @override
  String addMemberSentToCircle(int count, String circleName) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Einladungen an $circleName gesendet',
      one: 'Einladung an $circleName gesendet',
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
          'Bisher $sentString von $totalString Einladungen für $circleName gesendet. Haven versucht weiterhin, die übrigen zu senden, solange die App geöffnet ist, bis zu einem Tag lang.',
      one:
          'Bisher $sentString von 1 Einladung für $circleName gesendet. Haven versucht weiterhin, sie zu senden, solange die App geöffnet ist, bis zu einem Tag lang.',
    );
    return '$_temp0';
  }

  @override
  String addMemberReinviteNeeded(String circleName) {
    return 'Haven kann die Einladung für $circleName nicht senden. Entferne die Person und füge sie erneut hinzu.';
  }

  @override
  String get memberCannotReceiveInvitations =>
      'Haven kann nicht alle Personen einladen, die du ausgewählt hast, weil es nicht herausfinden konnte, wohin mindestens eine ihrer Einladungen gesendet werden soll. Bitte die ausgewählten Personen darum zu prüfen, ob ihre App Einladungen empfangen kann, und versuche es dann erneut.';

  @override
  String get missedInvitationsShowWho => 'Personen anzeigen';

  @override
  String missedInvitationsTitle(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Einladungen nicht gesendet',
      one: 'Einladung nicht gesendet',
    );
    return '$_temp0';
  }

  @override
  String get addMemberError =>
      'Mitglied konnte nicht hinzugefügt werden. Bitte versuche es erneut.';

  @override
  String get qrScannerTitle => 'QR-Code scannen';

  @override
  String get qrScannerToggleFlash => 'Blitz umschalten';

  @override
  String get qrScannerSwitchCamera => 'Kamera wechseln';

  @override
  String get qrScannerInstruction =>
      'Positioniere den QR-Code innerhalb des Rahmens';

  @override
  String get qrScannerScanning => 'Wird gescannt …';

  @override
  String get circleMemberNoRecentLocation => 'Kein aktueller Standort';

  @override
  String get circleMemberRemoveTooltip => 'Aus Kreis entfernen';

  @override
  String circleMemberRemoveDialogTitle(String name) {
    return '$name entfernen?';
  }

  @override
  String get circleMemberRemoveDialogBody =>
      'Sobald der Rest des Kreises nachgezogen ist, kann diese Person nichts Neues mehr aus diesem Kreis lesen. Das dauert meist wenige Minuten und länger, wenn jemand zu diesem Zeitpunkt offline war. Was sie schon bekommen hat, bleibt auf ihrem Handy. Rückgängig machen lässt sich das nur mit einer neuen Einladung.';

  @override
  String get circleMemberRemoveConfirm => 'Entfernen';

  @override
  String circleMemberRemoveInProgress(String name) {
    return '$name wird entfernt …';
  }

  @override
  String circleMemberRemoveSuccess(String name) {
    return '$name aus dem Kreis entfernt';
  }

  @override
  String circleMemberRemoveError(String name) {
    return '$name konnte nicht entfernt werden. Es hat sich nichts geändert – prüfe deine Verbindung und versuche es erneut.';
  }

  @override
  String circleMemberRemoveAwaitingAnnouncement(String name) {
    return 'Die Entfernung von $name läuft noch: Haven wartet auf die Relays. Bis sie abgeschlossen ist, wird mit diesem Kreis nichts geteilt.';
  }

  @override
  String get circleMemberAdmin => 'Admin';

  @override
  String get circleMemberHintNoLocation => 'kein Standort verfügbar';

  @override
  String get circleMemberHintMember => 'Mitglied';

  @override
  String get circleMemberHintTapToCenter =>
      'tippen, um die Karte auf ihren Standort zu zentrieren';

  @override
  String get pendingMemberRetryTooltip => 'Überprüfung wiederholen';

  @override
  String get pendingMemberRemoveTooltip => 'Aus Liste entfernen';

  @override
  String get pendingMemberValidating => 'Wird überprüft';

  @override
  String get pendingMemberValid => 'Gültig';

  @override
  String get pendingMemberWarning => 'Warnung';

  @override
  String get pendingMemberCheckingAvailability =>
      'Verfügbarkeit wird geprüft …';

  @override
  String get pendingMemberReadyToInvite => 'Bereit zum Einladen';

  @override
  String get pendingMemberNeedsUpdate => 'Muss Haven aktualisieren oder öffnen';

  @override
  String get memberKeyPackageStale =>
      'Haven kann diese Person gerade nicht einladen. Bitte sie, Haven zu öffnen, und versuche es dann erneut.';

  @override
  String get memberSearchHint => 'Mitglieds-ID eingeben …';

  @override
  String get memberSearchPasteTooltip => 'Aus Zwischenablage einfügen';

  @override
  String get memberSearchAddTooltip => 'Mitglied hinzufügen';

  @override
  String get memberSearchScanTooltip => 'QR-Code scannen';

  @override
  String get memberSearchHelper =>
      'Bitte deine Kontakte um ihren Haven-QR-Code oder ihre ID';

  @override
  String get memberSearchNoValidId => 'Keine gültige Haven-ID gefunden';

  @override
  String get memberSearchAlreadyAdded => 'Mitglied bereits hinzugefügt';

  @override
  String get memberPickerSectionRoster => 'Mitglieder deiner Kreise';

  @override
  String get memberPickerTierRoster => 'Mitglied deiner Kreise';

  @override
  String get memberPickerNoMatches => 'Keine Treffer in deinen Kreisen';

  @override
  String get memberPickerLoading =>
      'Die Mitgliederliste deiner Kreise wird geladen';

  @override
  String get memberPickerDirectoryUnavailable =>
      'Die Mitgliederliste deiner Kreise konnte gerade nicht geladen werden';

  @override
  String memberPickerMatchesAnnouncement(int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    return 'Treffer: $countString';
  }

  @override
  String get memberPickerReasonSelf => 'Das ist deine eigene ID';

  @override
  String get memberPickerReadPublicKey => 'Öffentlichen Schlüssel vorlesen';

  @override
  String get memberPickerSectionRecent => 'Kürzlich in deinen Kreisen';

  @override
  String get memberPickerTierRecent => 'Kürzlich in deinen Kreisen';

  @override
  String get memberPickerNicknameNote =>
      'Dein Spitzname für diese Person, nicht ihr öffentlicher Name';

  @override
  String memberPickerCollisionCircleLabel(String circleName) {
    return 'Kreis: $circleName';
  }

  @override
  String get memberPickerStrangerLookupNote =>
      'Haven hat ein Relay nach dem veröffentlichten Namen dieser Person gefragt. Das Relay sieht, dass dieses Gerät gerade eben nach dem Namen zu diesem Schlüssel gefragt hat – die Anfrage trägt aber keine Signatur und ist damit nicht mit deiner Haven-Identität verknüpft. Es wird noch kein Foto heruntergeladen.';

  @override
  String selectedMembersMore(int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    return '+$countString weitere';
  }

  @override
  String get invitationCardHeading => 'Kreiseinladung';

  @override
  String invitationCardSemantics(String inviter) {
    return 'Einladung, einem Kreis beizutreten, gesendet von $inviter';
  }

  @override
  String invitationCardInvitedBySemantics(String inviter) {
    return 'Eingeladen von kryptografischer Kennung $inviter';
  }

  @override
  String invitationCardInvitedBy(String inviter) {
    return 'Eingeladen von: $inviter';
  }

  @override
  String get invitationCardNicknameNote =>
      'Dein Spitzname für diese Person, nicht ihr öffentlicher Name';

  @override
  String get invitationCardJustNow => 'Gerade eben';

  @override
  String invitationCardDaysAgo(int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    return 'vor ${countString}d';
  }

  @override
  String invitationCardHoursAgo(int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    return 'vor ${countString}h';
  }

  @override
  String invitationCardMinutesAgo(int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    return 'vor ${countString}m';
  }

  @override
  String get invitationCardDecline => 'Ablehnen';

  @override
  String get invitationCardAccept => 'Annehmen';

  @override
  String get invitationAcceptedSnack => 'Einladung angenommen';

  @override
  String get invitationDeclinedSnack => 'Einladung abgelehnt';

  @override
  String get invitationAcceptError =>
      'Einladung konnte nicht angenommen werden. Bitte versuche es erneut.';

  @override
  String invitationNeedsNewInviteError(String name) {
    return 'Diese Einladung kann nicht mehr verwendet werden. Bitte $name, dich erneut einzuladen. Eventuell muss die Person zuerst Haven aktualisieren.';
  }

  @override
  String get rejoinDialogTitle => 'Diesem Kreis erneut beitreten?';

  @override
  String rejoinDialogBody(String inviterName, String circleName) {
    return 'Du wurdest von $inviterName in „$circleName“ eingeladen, und dieser Kreis ist schon auf diesem Telefon. Das kann passieren, wenn du aus dem Kreis entfernt und wieder eingeladen wurdest. Wenn du erneut beitrittst, wird die Kopie des Kreises auf diesem Telefon ersetzt. Mit „Ablehnen“ endet diese Einladung endgültig; mit „Abbrechen“ bleibt sie für später erhalten.';
  }

  @override
  String rejoinDialogBodyUnnamed(String circleName) {
    return 'Du wurdest in „$circleName“ eingeladen, und dieser Kreis ist schon auf diesem Telefon. Das kann passieren, wenn du aus dem Kreis entfernt und wieder eingeladen wurdest. Wenn du erneut beitrittst, wird die Kopie des Kreises auf diesem Telefon ersetzt. Mit „Ablehnen“ endet diese Einladung endgültig; mit „Abbrechen“ bleibt sie für später erhalten.';
  }

  @override
  String get rejoinDialogConfirm => 'Erneut beitreten';

  @override
  String invitationRosterFullError(int limit) {
    final intl.NumberFormat limitNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String limitString = limitNumberFormat.format(limit);

    return 'Du kannst gleichzeitig in höchstens $limitString Kreisen sein. Verlasse einen Kreis, dann kannst du diese Einladung annehmen.';
  }

  @override
  String get invitationDeclineError =>
      'Einladung konnte nicht abgelehnt werden. Bitte versuche es erneut.';

  @override
  String get circleSelectorLabel => 'Kreisauswahl';

  @override
  String get circleSelectorPlaceholder => 'Wähle einen Kreis';

  @override
  String get circleSelectorNewCircle => 'Neuer Kreis';

  @override
  String get circleSelectorLoadError => 'Kreise konnten nicht geladen werden';

  @override
  String get circleSelectorExpandedAnnouncement => 'Kreisliste ausgeklappt';

  @override
  String get circleSelectorCollapsedAnnouncement => 'Kreisliste eingeklappt';

  @override
  String get circleDetailsButtonTooltip => 'Kreisdetails';

  @override
  String get circleDetailsTitle => 'Kreisdetails';

  @override
  String circleDetailsMembersWithEpoch(String members, int epoch) {
    final intl.NumberFormat epochNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String epochString = epochNumberFormat.format(epoch);

    return '$members · Epoche $epochString';
  }

  @override
  String circleDetailsMetaWithExpiry(String meta, String expiry) {
    return '$meta · Verfall nach $expiry';
  }

  @override
  String circleDetailsExpiryMinutesShort(int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$countString Min.',
      one: '$countString Min.',
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
      other: '$countString Sek.',
      one: '$countString Sek.',
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
      other: 'etwa $countString Minuten',
      one: 'etwa $countString Minute',
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
      other: '$countString Sekunden',
      one: '$countString Sekunde',
    );
    return '$_temp0';
  }

  @override
  String circleDetailsExpirySemantics(String meta, String expiry) {
    return '$meta. Haven bittet die Relays, die Standortnachrichten, die du an diesen Kreis sendest, nach $expiry zu verwerfen.';
  }

  @override
  String get circleDetailsRelaysHeading => 'Relays für diesen Kreis';

  @override
  String get circleDetailsNoRelays => '(keine erfasst)';

  @override
  String get circleDetailsRelaysNote =>
      'Über diese Relays laufen die verschlüsselten Aktualisierungen dieses Kreises. Sie wurden beim Erstellen festgelegt und lassen sich in Haven noch nicht ändern; Änderungen an deiner Relay-Liste wirken sich nicht auf sie aus.';

  @override
  String get circleDetailsAddMember => 'Mitglied hinzufügen';

  @override
  String get circleDetailsLeaveCircle => 'Kreis verlassen';

  @override
  String get circleDetailsLeavingInProgress => 'Kreis wird verlassen …';

  @override
  String get leaveCircleDialogTitle => 'Kreis verlassen';

  @override
  String get leaveCircleDialogBody =>
      'Diesen Kreis verlassen? Du sendest seinen Mitgliedern dann keinen Standort mehr und siehst ihren auch nicht mehr. Der zuletzt gesendete Standort bleibt bis zu einem Tag lang auf ihren Handys. Das lässt sich nicht rückgängig machen: Für eine Rückkehr bräuchtest du eine neue Einladung.';

  @override
  String get leaveDisbandedCircleDialogBody =>
      'Dieser Kreis wurde beendet, daher wird mit ihm nichts mehr geteilt. Beim Verlassen wird er von diesem Telefon entfernt.';

  @override
  String get leaveCircleDialogAdminNote =>
      'Du bist Admin dieses Kreises. Bevor du ihn verlässt, versucht Haven, ein anderes Mitglied zum Admin zu machen, damit der Kreis weiter funktioniert.';

  @override
  String get leaveCircleConfirm => 'Verlassen';

  @override
  String get leaveCircleIdentityUnavailable => 'Identität nicht verfügbar';

  @override
  String get leaveCircleSuccess => 'Kreis erfolgreich verlassen';

  @override
  String get leaveCircleError => 'Kreis konnte nicht verlassen werden';

  @override
  String get legacyCircleRecreateCta => 'Kreis neu erstellen';

  @override
  String get storageResetTitle => 'Haven wurde aktualisiert';

  @override
  String get storageResetKept =>
      'Deine Identität ist unverändert, und das öffentliche Profil, das du bereits veröffentlicht hast, bleibt, wie es ist.';

  @override
  String get storageResetLost =>
      'Für den Wechsel zu Havens neuer Verschlüsselungs-Engine wurden die Kreise entfernt, die vor diesem Update erstellt wurden. Erstelle sie neu und lade ihre Mitglieder erneut ein. Auch die Spitznamen, die du anderen vor diesem Update gegeben hast, und Profiländerungen, deren Speichern bis dahin noch nicht abgeschlossen war, wurden entfernt.';

  @override
  String get storageResetRelays =>
      'Dieses Update hat deine Relay-Einstellungen auf Havens Standardwerte zurückgesetzt. Sie werden erst veröffentlicht, wenn du fortfährst oder aus den Relay-Einstellungen zurückkehrst – du kannst also zuerst deine eigenen Relays hinzufügen.';

  @override
  String get storageResetContinue => 'Fortfahren';

  @override
  String get storageResetOpenRelaySettings => 'Relay-Einstellungen';

  @override
  String get storageResetAcknowledgeFailed =>
      'Haven konnte deine Antwort nicht speichern. Solange sie nicht gespeichert ist, veröffentlicht Haven weder deine Relay-Einstellungen noch deinen Einladungsschlüssel, daher kann dich noch niemand einladen. Versuche es erneut – sonst fragt Haven beim nächsten Öffnen noch einmal.';

  @override
  String get circlesPanelCollapsedAnnouncement => 'Kreis-Panel eingeklappt';

  @override
  String get circlesPanelExpandedAnnouncement => 'Kreis-Panel ausgeklappt';

  @override
  String get circlesPanelSlightlyOpenAnnouncement =>
      'Kreis-Panel leicht geöffnet';

  @override
  String get circlesPanelHalfOpenAnnouncement => 'Kreis-Panel halb geöffnet';

  @override
  String get circleMemberAnnouncementSelf => 'du';

  @override
  String get circleMemberAnnouncementFallback => 'Mitglied';

  @override
  String get invitationsRefreshTooltip => 'Einladungen aktualisieren';

  @override
  String get invitationsLoadError => 'Einladungen konnten nicht geladen werden';

  @override
  String get invitationsEmptyTitle => 'Keine Einladungen';

  @override
  String get invitationsEmptyMessage =>
      'Wenn dich jemand zu einem Kreis einlädt, erscheint die Einladung hier.';

  @override
  String get refreshRingSemanticNoInbox =>
      'Kein Posteingang konfiguriert, öffnet die Relay-Einstellungen';

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
      other: '$checkedString von $totalString Relays geprüft',
      one: '$checkedString von 1 Relay geprüft',
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
      other: 'Alle $totalString Relays haben geantwortet',
      one: 'Das Relay hat geantwortet',
    );
    return '$_temp0';
  }

  @override
  String get refreshRingSemanticAllError => 'Keine Relays haben geantwortet';

  @override
  String refreshRingSemanticPartial(int ok, int total) {
    final intl.NumberFormat okNumberFormat = intl.NumberFormat.decimalPattern(
      localeName,
    );
    final String okString = okNumberFormat.format(ok);
    final intl.NumberFormat totalNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String totalString = totalNumberFormat.format(total);

    return '$okString von $totalString Relays haben geantwortet';
  }

  @override
  String get refreshRingAnnouncementChecking => 'Relays werden geprüft';

  @override
  String get refreshRingAnnouncementAllOk => 'Alle Relays haben geantwortet';

  @override
  String refreshRingAnnouncementPartial(int ok, int total) {
    final intl.NumberFormat okNumberFormat = intl.NumberFormat.decimalPattern(
      localeName,
    );
    final String okString = okNumberFormat.format(ok);
    final intl.NumberFormat totalNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String totalString = totalNumberFormat.format(total);

    return '$okString von $totalString Relays haben geantwortet';
  }

  @override
  String get refreshRingAnnouncementAllError => 'Keine Relays erreichbar';

  @override
  String get refreshRingAnnouncementNoInbox => 'Kein Posteingang konfiguriert';

  @override
  String refreshRingSemanticAllFound(int total) {
    final intl.NumberFormat totalNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String totalString = totalNumberFormat.format(total);

    String _temp0 = intl.Intl.pluralLogic(
      total,
      locale: localeName,
      other: 'Alle $totalString Relays haben deine Daten',
      one: 'Das Relay hat deine Daten',
    );
    return '$_temp0';
  }

  @override
  String get refreshRingSemanticNoneFound => 'Keine Relays haben deine Daten';

  @override
  String refreshRingSemanticPartialFound(int ok, int total) {
    final intl.NumberFormat okNumberFormat = intl.NumberFormat.decimalPattern(
      localeName,
    );
    final String okString = okNumberFormat.format(ok);
    final intl.NumberFormat totalNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String totalString = totalNumberFormat.format(total);

    return '$okString von $totalString Relays haben deine Daten';
  }

  @override
  String get refreshRingAnnouncementAllFound => 'Alle Relays haben deine Daten';

  @override
  String refreshRingAnnouncementPartialFound(int ok, int total) {
    final intl.NumberFormat okNumberFormat = intl.NumberFormat.decimalPattern(
      localeName,
    );
    final String okString = okNumberFormat.format(ok);
    final intl.NumberFormat totalNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String totalString = totalNumberFormat.format(total);

    return '$okString von $totalString Relays haben deine Daten';
  }

  @override
  String get refreshRingAnnouncementNoneFound =>
      'Keine Relays haben deine Daten';

  @override
  String get identityTitle => 'Identität';

  @override
  String get identityLoadError =>
      'Beim Laden deiner Identität ist etwas schiefgelaufen. Bitte versuche es erneut.';

  @override
  String get identityMissingTitle => 'Keine Identität';

  @override
  String get identityMissingMessage =>
      'Deine Identität ist verloren. Richte eine neue ein, um Haven weiter zu nutzen.';

  @override
  String get identitySetUpCta => 'Identität einrichten';

  @override
  String get identityPublicKeyQrTitle => 'QR-Code des öffentlichen Schlüssels';

  @override
  String get identityPublicKeyQrSubtitle =>
      'So laden andere dich zu Kreisen ein';

  @override
  String get identityAdvancedTitle => 'Erweitert';

  @override
  String get identityAdvancedSubtitle =>
      'Öffentlicher Schlüssel, geheimer Schlüssel, Löschen';

  @override
  String get profileIsPublicNoticeTitle => 'Profil ist öffentlich';

  @override
  String get profileIsPublicNoticeBody =>
      'Dein Anzeigename und dein Foto sind für jeden im Nostr-Netzwerk sichtbar, nicht nur für Mitglieder deiner Kreise. Mach nur das öffentlich, womit du dich wohlfühlst.';

  @override
  String get identityRefreshProfileTooltip =>
      'Öffentliches Profil aktualisieren';

  @override
  String get identityAdvancedExportError =>
      'Der geheime Schlüssel konnte nicht exportiert werden. Bitte versuche es erneut.';

  @override
  String get identityAdvancedDeleteTitle => 'Identität löschen?';

  @override
  String get identityAdvancedDeleteBody =>
      'Dadurch werden deine Identität und alle Kreisdaten von diesem Handy gelöscht. Alles, was bereits unter dieser Identität veröffentlicht wurde, bleibt dort, wo es ist: dein Name und deine Schlüssel auf den Relays, die sie haben, dein Foto auf dem Bild-Host, der es speichert. Stelle sicher, dass du deinen geheimen Schlüssel gesichert hast, falls du die Identität später wiederherstellen möchtest.';

  @override
  String get identityAdvancedDeleteConfirm => 'Löschen';

  @override
  String get identityAdvancedDeletedSnack => 'Identität gelöscht';

  @override
  String get identityAdvancedDeleteError =>
      'Identität konnte nicht gelöscht werden. Bitte versuche es erneut.';

  @override
  String get identityAdvancedDeletingProgress =>
      'Deine Identität wird gelöscht …';

  @override
  String identityAdvancedCopiedToClipboard(String label) {
    return '$label in die Zwischenablage kopiert';
  }

  @override
  String get identityAdvancedSecretCopiedWarning =>
      'Geheimer Schlüssel kopiert. Warnung: Andere Apps können deine Zwischenablage lesen. Füge ihn an einem sicheren Ort ein und leere deine Zwischenablage.';

  @override
  String get identityAdvancedMissingBody =>
      'Es ist keine Identität eingerichtet.';

  @override
  String get identityAdvancedPublicKeyLabel => 'Öffentlicher Schlüssel';

  @override
  String get identityAdvancedPublicKeyHexLabel =>
      'Öffentlicher Schlüssel (hex)';

  @override
  String get identityAdvancedCopyValue => 'Öffentlicher Schlüssel';

  @override
  String get identityAdvancedCopyPublicKeyTooltip =>
      'Öffentlichen Schlüssel kopieren';

  @override
  String get identityAdvancedCopyHexTooltip => 'Hex kopieren';

  @override
  String get identityAdvancedSecretKeyTitle => 'Geheimer Schlüssel';

  @override
  String get identityAdvancedSecretKeyWarning =>
      'Dein geheimer Schlüssel gewährt vollen Zugriff auf deine Identität. Teile ihn niemals mit jemandem.';

  @override
  String get identityAdvancedRevealSecretKey => 'Geheimen Schlüssel anzeigen';

  @override
  String get identityAdvancedHideSecretKey => 'Geheimen Schlüssel verbergen';

  @override
  String get identityAdvancedCopySecretKeyTooltip =>
      'Geheimen Schlüssel kopieren';

  @override
  String get identityAdvancedDeleteIdentityCta => 'Identität löschen';

  @override
  String get qrCodeLoadError =>
      'Beim Laden deines öffentlichen Schlüssels ist etwas schiefgelaufen. Bitte versuche es erneut.';

  @override
  String get qrCodeYourPublicKeyLabel => 'Dein öffentlicher Schlüssel';

  @override
  String get qrCodeWhatIsThisTitle => 'Was ist das?';

  @override
  String get qrCodeExplainerKeys =>
      'Haven basiert auf Nostr, einem offenen Netzwerk ohne Unternehmenskonto oder Registrierung dahinter. Deine Identität ist einfach ein Schlüsselpaar: ein geheimer Schlüssel, den nur du besitzt, und dieser daraus erzeugte öffentliche Schlüssel.';

  @override
  String get qrCodeExplainerUsername =>
      'Dein öffentlicher Schlüssel funktioniert wie ein Benutzername, den du gefahrlos teilen kannst. Andere scannen diesen Code oder fügen deinen öffentlichen Schlüssel ein, um dich zu einem Kreis einzuladen. Durch das Teilen wird nicht preisgegeben, wo du bist. Dein Anzeigename und dein Foto sind ohnehin schon öffentlich, hier kommt also nichts hinzu.';

  @override
  String get displayNameCardTitle => 'Anzeigename';

  @override
  String get displayNameCardLoadError =>
      'Dein Anzeigename konnte nicht geladen werden. Versuche es später erneut.';

  @override
  String get displayNameCardHint => 'Gib deinen Anzeigenamen ein';

  @override
  String get displayNameCardSavedLabel => 'Anzeigename gespeichert';

  @override
  String get displayNameCardSaveLabel => 'Anzeigenamen speichern';

  @override
  String get displayNameCardSavingLabel => 'Anzeigename wird gespeichert';

  @override
  String get displayNameCardRetryLabel =>
      'Speichern fehlgeschlagen. Wiederholen';

  @override
  String get displayNameCardSavedAnnouncement => 'Anzeigename gespeichert';

  @override
  String get displayNameCardSaveFailedAnnouncement =>
      'Speichern fehlgeschlagen, versuche es erneut';

  @override
  String get npubQrCopiedSnack =>
      'Öffentlicher Schlüssel in die Zwischenablage kopiert';

  @override
  String get npubQrCopyButton => 'Öffentlichen Schlüssel kopieren';

  @override
  String get circleMemberPublicKeyCopied =>
      'Öffentlicher Schlüssel in die Zwischenablage kopiert';

  @override
  String get circleMemberCopyPublicKeyHint => 'Öffentlichen Schlüssel kopieren';

  @override
  String get circleMemberSetNicknameMenuItem => 'Spitznamen festlegen';

  @override
  String get circleMemberCopyPublicKeyMenuItem =>
      'Öffentlichen Schlüssel kopieren';

  @override
  String get memberProfileRefreshErrorGeneric =>
      'Profile konnten nicht aktualisiert werden. Bitte versuche es erneut.';

  @override
  String get memberDetailSheetTitle => 'Mitgliedsdetails';

  @override
  String get memberNicknameSheetHint => 'Spitznamen eingeben';

  @override
  String get memberNicknameSheetLabel => 'Spitzname';

  @override
  String get memberNicknameSheetSave => 'Spitznamen speichern';

  @override
  String get memberNicknameSheetClear => 'Spitznamen entfernen';

  @override
  String get memberNicknameSheetSavedAnnouncement => 'Spitzname gespeichert';

  @override
  String get memberNicknameSheetClearedAnnouncement => 'Spitzname entfernt';

  @override
  String get npubQrScanLabel => 'Scannen, um mich hinzuzufügen';

  @override
  String get npubQrSemanticsLabel => 'QR-Code für deine öffentliche Identität';

  @override
  String get photoHeaderRemoveTitle => 'Profilfoto entfernen?';

  @override
  String get photoHeaderRemoveBody =>
      'Dadurch wird dein Foto aus deinem öffentlichen Profil entfernt. Die Bilddatei bleibt auf dem Server, der sie hostet, und bereits heruntergeladene Kopien bleiben bei denen, die sie haben.';

  @override
  String get photoHeaderEditPhoto => 'Foto bearbeiten';

  @override
  String get photoHeaderRemove => 'Entfernen';

  @override
  String get photoHeaderViewPhotoSemantics => 'Profilfoto ansehen';

  @override
  String get photoHeaderAddPhotoSemantics => 'Profilfoto hinzufügen';

  @override
  String get photoHeaderChangePhotoSemantics => 'Profilfoto ändern';

  @override
  String get avatarPickerPhotoUpdatedAnnouncement => 'Foto aktualisiert.';

  @override
  String get avatarPickerPhotoRemoved => 'Foto entfernt.';

  @override
  String get avatarPickerRemoveError =>
      'Dein Foto konnte nicht entfernt werden. Bitte versuche es erneut.';

  @override
  String get avatarPickerUpdateError =>
      'Dein Foto konnte nicht aktualisiert werden. Bitte versuche es erneut.';

  @override
  String get avatarPickerCropTitle => 'Foto zuschneiden';

  @override
  String get avatarPickerCropDone => 'Fertig';

  @override
  String get avatarPickerCropCancel => 'Abbrechen';

  @override
  String get avatarFullscreenClose => 'Schließen';

  @override
  String get avatarFullscreenSemantics => 'Profilfoto, Vollbild';

  @override
  String get avatarFullscreenLoadError => 'Foto konnte nicht geladen werden';

  @override
  String get mapInitializing => 'Wird initialisiert …';

  @override
  String get mapInitFailedTitle => 'Initialisierung fehlgeschlagen';

  @override
  String get mapInitFailedMessage =>
      'Standortdienste konnten nicht initialisiert werden.';

  @override
  String get mapInitFailedRetry =>
      'Initialisierung fehlgeschlagen. Bitte versuche es erneut.';

  @override
  String get mapLocationOffMessage =>
      'Schalte den Standort ein, um dich und deine Kreise auf der Karte zu sehen.';

  @override
  String get mapGettingLocation => 'Standort wird ermittelt …';

  @override
  String get mapLoadingMap => 'Karte wird geladen …';

  @override
  String get mapLocationOffTitle => 'Standort ist aus';

  @override
  String get mapLocationErrorTitle => 'Standortfehler';

  @override
  String get mapLocationUnavailable => 'Standort vorübergehend nicht verfügbar';

  @override
  String get mapLocationNoPermissionTitle =>
      'Haven darf deinen Standort nicht nutzen';

  @override
  String get mapLocationSharingStoppedServiceOff =>
      'Der Standort ist auf diesem Gerät ausgeschaltet, deshalb teilt Haven deinen Standort nicht mehr mit deinen Kreisen. Schalte den Standort wieder ein, damit das Teilen weitergeht.';

  @override
  String get mapLocationSharingStoppedPermission =>
      'Haven hat keine Berechtigung mehr für deinen Standort und teilt ihn deshalb nicht mehr. Erlaube den Standortzugriff, damit das Teilen weitergeht.';

  @override
  String get mapLocationSharingStoppedPermissionSettings =>
      'Der Standortzugriff für Haven ist in den Systemeinstellungen deaktiviert, deshalb wird dein Standort nicht mehr geteilt. Erlaube den Zugriff dort wieder, damit das Teilen weitergeht.';

  @override
  String get mapLocationSharingStoppedBoth =>
      'Haven teilt deinen Standort nicht mehr. Schalte den Standort auf diesem Gerät ein und erlaube Haven den Zugriff darauf.';

  @override
  String get mapLocationSharingStoppedUnknown =>
      'Haven erhält deinen Standort nicht mehr, deshalb wurde das Teilen gestoppt. Prüfe, ob der Standort eingeschaltet ist und ob Haven darauf zugreifen darf.';

  @override
  String get mapLocationAccessRestoredAnnouncement =>
      'Haven hat wieder Zugriff auf deinen Standort. Das Teilen läuft wieder.';

  @override
  String get clockSkewTitle => 'Die Uhr dieses Geräts geht falsch';

  @override
  String get clockSkewBodyRejected =>
      'Deine Kreise erhalten deinen Standort nicht, weil die Relays den Zeitstempel ablehnen, den dieses Gerät darauf setzt. Aktiviere in den Systemeinstellungen die automatische Einstellung von Datum und Uhrzeit, um das zu beheben.';

  @override
  String get clockSkewBodyBehind =>
      'Dieses Gerät geht gegenüber dem Rest deiner Kreise nach, deshalb werden deine Standorte zwar gesendet, laufen aber zu früh ab, sodass deine Kreise einige oder alle davon verpassen können. Aktiviere in den Systemeinstellungen die automatische Einstellung von Datum und Uhrzeit, um das zu beheben.';

  @override
  String get clockSkewResolvedAnnouncement =>
      'Das Problem mit der Uhr ist behoben. Haven teilt deinen Standort wieder.';

  @override
  String get clockSkewTitleDisagreement =>
      'Eine Uhr in einem deiner Kreise geht falsch';

  @override
  String get clockSkewBodyDisagreement =>
      'Die Uhr dieses Geräts und die eines anderen Mitglieds weichen um zwei Minuten oder mehr voneinander ab. Wenn die Uhr dieses Geräts die falsche ist, können die Standorte, die es sendet, ablaufen, bevor sie jemand sieht. Aktiviere in den Systemeinstellungen die automatische Einstellung von Datum und Uhrzeit, um auszuschließen, dass es an diesem Gerät liegt.';

  @override
  String get clockSkewDisagreementResolvedAnnouncement =>
      'Die Warnung zur Uhr ist verschwunden.';

  @override
  String get sharingHealthTitleStopped =>
      'Das Teilen von Standorten ist gestoppt';

  @override
  String get sharingHealthTitleNotSending => 'Dein Standort wird nicht geteilt';

  @override
  String get sharingHealthTitleNotReceiving => 'Du empfängst keine Standorte';

  @override
  String sharingHealthNoUpdatesMinutes(int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Keine Aktualisierungen seit etwa $countString Minuten',
      one: 'Keine Aktualisierungen seit etwa 1 Minute',
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
      other: 'Keine Aktualisierungen seit etwa $countString Stunden',
      one: 'Keine Aktualisierungen seit etwa 1 Stunde',
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
      other: 'Keine Aktualisierungen seit etwa $countString Tagen',
      one: 'Keine Aktualisierungen seit etwa 1 Tag',
    );
    return '$_temp0';
  }

  @override
  String get sharingHealthRepairAction => 'Reparieren';

  @override
  String get sharingHealthRepairSent =>
      'Reparatur gesendet. Die anderen ziehen nach, sobald ihre Handys die Reparatur empfangen haben.';

  @override
  String get sharingHealthRepairNothingToDo =>
      'Gerade gibt es nichts zu reparieren. Haven versucht es weiter.';

  @override
  String get sharingHealthRepairUnresolvedAnnouncement =>
      'Das Teilen von Standorten funktioniert weiterhin nicht.';

  @override
  String get sharingHealthResumedAnnouncement =>
      'Das Teilen von Standorten funktioniert wieder.';

  @override
  String get sharingHealthTitleQuarantined =>
      'Haven kann diesen Kreis gerade nicht öffnen';

  @override
  String get sharingHealthBodyQuarantined =>
      'Beim Laden dieses Kreises auf diesem Telefon ist etwas schiefgelaufen. Der Kreis ist noch da.';

  @override
  String get sharingHealthTitleDisbanded => 'Dieser Kreis wurde beendet';

  @override
  String get sharingHealthBodyDisbanded =>
      'Ein Admin hat diesen Kreis beendet, daher wird mit ihm nichts mehr geteilt. Verlasse ihn, um ihn von diesem Telefon zu entfernen.';

  @override
  String get sharingHealthQuarantineRetryHint =>
      'Versucht erneut, diesen Kreis zu laden';

  @override
  String get sharingHealthQuarantineRetryFailedAnnouncement =>
      'Haven kann diesen Kreis weiterhin nicht öffnen.';

  @override
  String get sharingHealthTitleUnrecoverable =>
      'Dieser Kreis funktioniert auf diesem Telefon nicht mehr';

  @override
  String get sharingHealthBodyUnrecoverable =>
      'Haven kann in diesem Kreis auf diesem Telefon keine Aktualisierungen mehr senden oder empfangen. Bitte einen der Admins dieses Kreises darum, dich zu entfernen und wieder hinzuzufügen. Wenn das niemand kann, erstelle einen neuen Kreis mit denselben Personen.';

  @override
  String get sharingHealthTitleStalled =>
      'Haven kann die Aktualisierungen dieses Kreises nicht lesen';

  @override
  String get sharingHealthBodyStalled =>
      'Dieses Telefon scheint eine Änderung am Kreis verpasst zu haben und konnte sie auf den Relays nicht finden. Bitte einen der Admins dieses Kreises darum, dich zu entfernen und wieder hinzuzufügen. Wenn das niemand kann, erstelle einen neuen Kreis mit denselben Personen.';

  @override
  String get sharingHealthTitlePaused => 'Haven hat diesen Kreis pausiert';

  @override
  String get sharingHealthBodyCollision =>
      'Haven hat auf diesem Telefon ein Problem mit diesem Kreis festgestellt und das Teilen mit ihm gestoppt, damit dein Standort privat bleibt. Beheben lässt sich das nur, indem du den Kreis verlässt. Um ihm wieder beizutreten, brauchst du eine neue Einladung.';

  @override
  String get sharingHealthBodyCannotCheck =>
      'Haven konnte diesen Kreis auf diesem Telefon nicht überprüfen und hat das Teilen mit ihm deshalb pausiert, damit dein Standort privat bleibt. Haven prüft ihn von allein erneut.';

  @override
  String get sharingHealthTitleLeaving => 'Du verlässt diesen Kreis';

  @override
  String get sharingHealthBodyLeaving =>
      'Solange Haven das Verlassen abschließt, wird mit diesem Kreis nichts geteilt. Das kann etwa einen Tag dauern. Sobald es abgeschlossen ist, verschwindet der Kreis von diesem Telefon.';

  @override
  String get sharingHealthBodyRemovalUnmade =>
      'Eine von dir angeforderte Entfernung wurde nicht durchgeführt. Deshalb hat Haven das Teilen deines Standorts mit diesem Kreis pausiert, damit ihn niemand sieht, den du entfernen wolltest.';

  @override
  String get sharingHealthBodyRemovalUnmadeNoNotice =>
      'Eine von dir angeforderte Entfernung wurde nicht durchgeführt. Deshalb hat Haven das Teilen deines Standorts mit diesem Kreis pausiert, damit ihn niemand sieht, den du entfernen wolltest. Öffne die Mitgliederliste, um zu sehen, wer noch im Kreis ist.';

  @override
  String get sharingHealthBodyDepartureDue =>
      'Jemand hat diesen Kreis verlassen, aber der Austritt ist noch nicht abgeschlossen. Bis dahin teilt Haven deinen Standort nicht mit diesem Kreis.';

  @override
  String get sharingHealthTitleBackgroundPaused =>
      'Das Teilen im Hintergrund ist für diesen Kreis pausiert';

  @override
  String get sharingHealthBodyAwaitsForeground =>
      'Die Relays dieses Kreises haben sich geändert, während Haven im Hintergrund lief. Haven schließt den Wechsel ab, während die App geöffnet ist; bis dahin wird mit diesem Kreis im Hintergrund nichts geteilt.';

  @override
  String get sharingHealthBodyAwaitingRelays =>
      'Eine Änderung an diesem Kreis wartet darauf, dass ein Relay sie bestätigt. Bis dahin sendet Haven deinen Standort nicht an diesen Kreis und zeigt keine neuen Standorte aus ihm an. Haven versucht es weiter, solange die App geöffnet ist.';

  @override
  String get sharingHealthBodyAcknowledged =>
      'Ein Relay hat eine Änderung an diesem Kreis angenommen, und Haven schließt sie gerade ab. Bis dahin warten die Aktualisierungen dieses Kreises.';

  @override
  String get sharingHealthBodyStagedWithoutRecord =>
      'Eine Änderung an diesem Kreis konnte nicht gespeichert werden und wurde deshalb nicht gesendet. Haven bringt das spätestens beim nächsten Start in Ordnung; bis dahin warten die Aktualisierungen dieses Kreises.';

  @override
  String get sharingHealthBodyStoredInput =>
      'Dieses Telefon hat Aktualisierungen für diesen Kreis, die es noch nicht verarbeiten konnte. Solange das nicht geschehen ist, teilt Haven deinen Standort nicht mit diesem Kreis.';

  @override
  String get sharingHealthBodySessionHeld =>
      'Haven schließt noch seine vorherige Verbindung, deshalb ist das Teilen von Standorten pausiert. Es geht weiter, sobald das abgeschlossen ist. Ein Neustart deines Telefons behebt das immer.';

  @override
  String get sharingHealthRepairHintAnyMember =>
      'Stellt die Verbindung zu den Relays wieder her, versucht erneut, deinen Standort zu senden, und gibt diesem Kreis möglicherweise neue Verschlüsselungsschlüssel';

  @override
  String get sharingHealthAttentionAnnouncement =>
      'Das Teilen von Standorten in diesem Kreis erfordert deine Aufmerksamkeit. Öffne die Kreisdetails, um zu sehen, warum.';

  @override
  String changeNoticeArrivedAnnouncement(String circleName) {
    return 'Zu den jüngsten Änderungen im Kreis $circleName gibt es einen Hinweis, der deine Aufmerksamkeit erfordert. Öffne die Kreisdetails dieses Kreises, um ihn zu lesen.';
  }

  @override
  String get circleDetailsAttentionTooltip =>
      'Kreisdetails, erfordert Aufmerksamkeit';

  @override
  String circleRowAttentionSemantics(String circleName) {
    return '$circleName, erfordert Aufmerksamkeit';
  }

  @override
  String get changeNoticeHeading => 'Änderungen an diesem Kreis';

  @override
  String get changeNoteRemovalUndone =>
      'Eine Änderung an diesem Kreis wurde nicht wirksam. Falls damit jemand entfernt werden sollte, ist jede betroffene Person noch im Kreis und kann sehen, was mit dem Kreis geteilt wird.';

  @override
  String get changeNoteChangeUndone =>
      'Eine Änderung an diesem Kreis wurde nicht wirksam, es hat sich also nichts geändert. Falls sie von dir stammt, nimm sie bei Bedarf erneut vor.';

  @override
  String get changeNoteMayBeOutOfStep =>
      'Eine Änderung an diesem Kreis hat die anderen möglicherweise erreicht, ohne dass dieses Telefon davon erfahren hat. Dieses Telefon ist daher vielleicht nicht mehr auf demselben Stand wie sie.';

  @override
  String get changeNoteReinviteOwed =>
      'Eine Person, die du eingeladen hast, ist in diesem Kreis aufgeführt, kann aber nicht beitreten, weil Haven ihre Einladung nicht senden kann. Entferne sie und füge sie erneut hinzu.';

  @override
  String get changeNoteChangeUnrecorded =>
      'Eine Änderung an diesem Kreis konnte nicht gespeichert werden und wurde deshalb nicht gesendet.';

  @override
  String get changeNoteQueuedChangeDropped =>
      'Eine ausstehende Änderung in diesem Kreis wurde verworfen, weil sie nicht mehr wie gewünscht durchgeführt werden konnte. Möglicherweise wurde sie bereits auf anderem Weg durchgeführt.';

  @override
  String get changeNoteQueuedChangesHeld =>
      'Einige Änderungen an diesem Kreis warten noch darauf, durchgeführt zu werden.';

  @override
  String get changeNoteQueuedRemovalDropped =>
      'Eine von dir angeforderte Entfernung in diesem Kreis wurde nicht durchgeführt. Wer entfernt werden sollte, ist möglicherweise noch im Kreis.';

  @override
  String get changeNoteChangeWithdrawn =>
      'Die Änderung eines anderen Mitglieds an diesem Kreis hat eine deiner Änderungen ersetzt, deshalb wurde deine nicht durchgeführt. Nimm sie bei Bedarf erneut vor.';

  @override
  String get changeNoteWelcomeOwed =>
      'Eine Einladung in diesen Kreis wurde noch nicht gesendet. Haven versucht weiterhin, sie zu senden, solange die App geöffnet ist, bis zu einem Tag lang nach deiner Einladung. Ist die Person bis dahin nicht beigetreten, entferne sie und füge sie erneut hinzu.';

  @override
  String get changeNoteUnreadLocation =>
      'Einige kürzlich an diesen Kreis gesendete Aktualisierungen konnten auf diesem Telefon nicht geöffnet werden.';

  @override
  String get changeNoticeStillInCircleLabel => 'Noch im Kreis:';

  @override
  String get changeNoticeRemoveAgain => 'Erneut entfernen';

  @override
  String get changeNoticeReviewMembers => 'Mitglieder prüfen';

  @override
  String get changeNoticeKeepMembers => 'Im Kreis behalten';

  @override
  String get changeNoticeKeepConfirmTitle => 'Im Kreis behalten?';

  @override
  String get changeNoticeKeepConfirmBody =>
      'Haven pausiert das Teilen mit diesem Kreis dann nicht mehr wegen dieser Entfernung. Wer entfernt werden sollte und noch im Kreis ist, bleibt darin und kann deinen Standort sehen, wann immer Haven ihn mit diesem Kreis teilt.';

  @override
  String get changeNoticeKeepConfirmAction => 'Behalten';

  @override
  String circleMemberLastSeenMinutes(int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Zuletzt gesehen vor $countString Minuten',
      one: 'Zuletzt gesehen vor 1 Minute',
    );
    return '$_temp0';
  }

  @override
  String get mapThisLocation => 'diesen Standort';

  @override
  String get mapMemberFallbackName => 'Mitglied';

  @override
  String mapOpenInAppleMapsTitle(String label) {
    return '$label in Apple Maps öffnen?';
  }

  @override
  String get mapOpenInAppleMapsBody =>
      'Nur die Kartenkoordinate wird an Apple Maps gesendet, niemals ein Name oder eine Identität.';

  @override
  String get mapOpenInAppleMapsConfirm => 'In Apple Maps öffnen';

  @override
  String get mapOpenMapsError => 'Maps konnte nicht geöffnet werden';

  @override
  String get mapControlsZoomIn => 'Vergrößern';

  @override
  String get mapControlsZoomOut => 'Verkleinern';

  @override
  String get mapControlsRecenter => 'Neu zentrieren';

  @override
  String get mapControlsRecenterFab => 'Auf meinen Standort zentrieren';

  @override
  String get mapAttributionCreditsButton => 'Karten-Credits und Lizenz';

  @override
  String get userLocationMarkerSemantics => 'Markierung deines Standorts';

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
      other: 'vor $countString Minuten',
      one: 'vor 1 Minute',
    );
    return '$_temp0';
  }

  @override
  String memberMarkerNamedSemantics(String name) {
    return 'Mitgliedsmarkierung von $name';
  }

  @override
  String get memberMarkerGenericSemantics => 'Mitgliedsmarkierung';

  @override
  String memberMarkerLastSeenSemantics(String base, String age) {
    return '$base, zuletzt gesehen $age';
  }

  @override
  String memberMarkerOffScreenSemantics(String name, String direction) {
    return '$name ist außerhalb des Bildschirms im $direction. Zum Anzeigen tippen';
  }

  @override
  String memberMarkerOffScreenGenericSemantics(String direction) {
    return 'Ein Mitglied ist außerhalb des Bildschirms im $direction. Zum Anzeigen tippen';
  }

  @override
  String get compassNorth => 'Norden';

  @override
  String get compassNorthEast => 'Nordosten';

  @override
  String get compassEast => 'Osten';

  @override
  String get compassSouthEast => 'Südosten';

  @override
  String get compassSouth => 'Süden';

  @override
  String get compassSouthWest => 'Südwesten';

  @override
  String get compassWest => 'Westen';

  @override
  String get compassNorthWest => 'Nordwesten';

  @override
  String get commonAdd => 'Hinzufügen';

  @override
  String get addRelaySheetTitleInbox => 'Posteingangs-Relay hinzufügen';

  @override
  String get addRelaySheetTitleKeyPackage => 'KeyPackage-Relay hinzufügen';

  @override
  String get addRelaySheetTitleProfile => 'Profil-Relay hinzufügen';

  @override
  String get addRelaySheetHint => 'wss://relay.example.com';

  @override
  String get addRelaySheetPasteTooltip => 'Aus Zwischenablage einfügen';

  @override
  String get addRelaySheetErrorEmpty => 'Gib eine Relay-Adresse ein.';

  @override
  String get addRelaySheetErrorInsecureScheme =>
      'Verwende wss://, damit der Datenverkehr zu diesem Relay verschlüsselt ist.';

  @override
  String get addRelaySheetErrorHasCredentials =>
      'Die Relay-URL darf keine Anmeldedaten enthalten.';

  @override
  String get addRelaySheetErrorInvalidFormat =>
      'Gib eine Relay-Adresse wie wss://relay.example.com ein.';

  @override
  String get avatarSemanticsLabel => 'Benutzer-Avatar';

  @override
  String avatarSemanticsFor(String initials) {
    return 'für $initials';
  }

  @override
  String get avatarSemanticsOnline => 'Online';

  @override
  String get avatarSemanticsOffline => 'Offline';
}
