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
      'Teile deinen Standort privat, nur mit Menschen, denen du vertraust.';

  @override
  String get onboardingWelcomeHeadlineEmphasis => 'nur';

  @override
  String get onboardingWelcomeCta => 'Loslegen';

  @override
  String get onboardingValuePropsTitle => 'Was Haven besonders macht';

  @override
  String get onboardingValueProp1Title => 'Nur deine Kreise können dich sehen';

  @override
  String get onboardingValueProp2Title => 'Niemand kann es abschalten';

  @override
  String get onboardingValueProp3Title => 'Kein Konto erforderlich';

  @override
  String get onboardingValueProp1Summary =>
      'Auf deinem Gerät verschlüsselt – lesbar nur für die Kreise, die du auswählst.';

  @override
  String get onboardingValueProp2Summary =>
      'Kein zentraler Server. Es läuft über ein Relay-Netzwerk deiner Wahl.';

  @override
  String get onboardingValueProp3Summary =>
      'Ohne E-Mail, Telefon oder Anmeldung. Dein geheimer Schlüssel verlässt dein Telefon nie.';

  @override
  String get onboardingCreateIdentityTitle => 'Erstelle deine Identität';

  @override
  String get onboardingCreateIdentityBody =>
      'Haven erstellt deine Schlüssel auf diesem Handy. Der geheime verlässt es nie.';

  @override
  String get onboardingCreateIdentityWarning =>
      'Wenn du dieses Telefon verlierst oder die App löschst, ist deine Identität verloren. Haven kann sie für dich nicht wiederherstellen.';

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
  String get nameCircleStageSendingInvites => 'Einladungen werden gesendet …';

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
  String nameCircleCreatedPartialSnack(String name, int sent, int total) {
    final intl.NumberFormat sentNumberFormat = intl.NumberFormat.decimalPattern(
      localeName,
    );
    final String sentString = sentNumberFormat.format(sent);
    final intl.NumberFormat totalNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String totalString = totalNumberFormat.format(total);

    return 'Kreis „$name“ erstellt. Einladungen gesendet ($sentString von $totalString); die Zustellung der übrigen steht noch aus.';
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
  String addMemberPartialDelivery(int sent, int total) {
    final intl.NumberFormat sentNumberFormat = intl.NumberFormat.decimalPattern(
      localeName,
    );
    final String sentString = sentNumberFormat.format(sent);
    final intl.NumberFormat totalNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String totalString = totalNumberFormat.format(total);

    return 'Einladungen gesendet ($sentString von $totalString). Die Zustellung der übrigen steht noch aus.';
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
  String get pendingMemberNeedsUpdate => 'Muss Haven aktualisieren';

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
      'Diese Relays stammen aus den veröffentlichten Listen der eingeladenen Mitglieder – bei fehlender Liste aus deinen Posteingangs-Relays oder Haven-Relays. Noch nicht änderbar; spätere Änderungen deiner Relay-Liste wirken sich nicht auf sie aus.';

  @override
  String get circleDetailsAddMember => 'Mitglied hinzufügen';

  @override
  String get circleDetailsLeaveCircle => 'Kreis verlassen';

  @override
  String get leaveCircleDialogTitle => 'Kreis verlassen';

  @override
  String get leaveCircleDialogBody =>
      'Diesen Kreis verlassen? Du sendest seinen Mitgliedern dann keinen Standort mehr und siehst ihren auch nicht mehr. Der zuletzt gesendete Standort bleibt bis zu einem Tag lang auf ihren Handys. Das lässt sich nicht rückgängig machen: Für eine Rückkehr bräuchtest du eine neue Einladung.';

  @override
  String get leaveCircleConfirm => 'Verlassen';

  @override
  String get leaveCircleIdentityUnavailable => 'Identität nicht verfügbar';

  @override
  String get leaveCircleSuccess => 'Kreis erfolgreich verlassen';

  @override
  String get leaveCircleError => 'Kreis konnte nicht verlassen werden';

  @override
  String get circleBlockedBannerTitle =>
      'Dieser Kreis kann nicht aktualisiert werden';

  @override
  String get circleBlockedBannerBody =>
      'Bei der Verschlüsselung dieses Kreises ist etwas schiefgelaufen, daher kann Haven darin keine Aktualisierungen mehr senden oder empfangen. Du kannst unten weiterhin den zuletzt bekannten Stand sehen oder den Kreis verlassen.';

  @override
  String get legacyCircleBannerTitle => 'Dieser Kreis muss neu erstellt werden';

  @override
  String get legacyCircleBannerBody =>
      'Havens Verschlüsselungs-Engine wurde aktualisiert, daher kann dieser Kreis nicht mehr verwendet werden. Erstelle ihn neu, um den Standort weiterhin mit denselben Personen zu teilen. Du musst sie erneut einladen.';

  @override
  String get legacyCircleRecreateCta => 'Kreis neu erstellen';

  @override
  String get legacyCircleRemoveCta => 'Entfernen';

  @override
  String get legacyCircleRemoveDialogTitle => 'Kreis entfernen?';

  @override
  String get legacyCircleRemoveDialogBody =>
      'Dieser Kreis kann nicht mehr verwendet werden und wird aus deiner Liste entfernt. Das wirkt sich nicht auf einen neuen Kreis aus, den du als Ersatz erstellst.';

  @override
  String get legacyCircleRemoveConfirm => 'Entfernen';

  @override
  String get legacyCutoverExplainerTitle => 'Haven wurde aktualisiert';

  @override
  String get legacyCutoverExplainerIdentityUnchanged =>
      'Deine Identität und dein öffentliches Profil sind unverändert. Dafür musst du nichts tun.';

  @override
  String get legacyCutoverExplainerCirclesNeedRecreation =>
      'Für mehr Sicherheit müssen deine Kreise neu erstellt und ihre Mitglieder erneut eingeladen werden, bevor du wieder Standorte darin teilen kannst.';

  @override
  String get legacyCutoverExplainerAcknowledge => 'Verstanden';

  @override
  String get relaySettingsLegacyRetractionPending =>
      'Haven bittet die Relays noch, einige alte Daten aus dem jüngsten Sicherheitsupdate zu verwerfen.';

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
  String get profileSyncStatusSyncing =>
      'Wird mit deinem öffentlichen Profil synchronisiert …';

  @override
  String get profileSyncStatusPartial =>
      'Veröffentlicht – wird noch mit einigen Relays synchronisiert';

  @override
  String get profileSyncStatusSynced => 'Öffentliches Profil ist aktuell';

  @override
  String get profileSyncStatusFailed =>
      'Konnte noch nicht synchronisiert werden.';

  @override
  String get profileSyncStatusRetrySemantics =>
      'Veröffentlichung deines Profils wiederholen';

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
  String get avatarPickerPhotoUpdated =>
      'Foto aktualisiert. Es wird in deinem öffentlichen Nostr-Profil veröffentlicht.';

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
      'Dieses Gerät geht gegenüber dem Rest deiner Kreise nach, deshalb werden deine Standorte zwar gesendet, laufen aber ab, bevor sie jemand sehen kann. Aktiviere in den Systemeinstellungen die automatische Einstellung von Datum und Uhrzeit, um das zu beheben.';

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
  String get sharingHealthRepairUnavailableHint =>
      'Reparieren ist für diesen Kreis nicht verfügbar';

  @override
  String get sharingHealthRepairHint =>
      'Stellt die Verbindung zu den Relays wieder her, sendet deinen Standort erneut und gibt diesem Kreis, wenn du sein Admin bist, möglicherweise einen neuen Schlüssel';

  @override
  String get sharingHealthRepairSent =>
      'Reparatur gesendet. Die anderen ziehen nach, sobald ihre Handys die Reparatur empfangen haben.';

  @override
  String get sharingHealthRepairNotOwner =>
      'Nur der Admin dieses Kreises kann ihn reparieren. Wende dich an diese Person, damit sie dich entfernt und wieder hinzufügt.';

  @override
  String get sharingHealthRepairNeedsNewCircle =>
      'Dieser Kreis lässt sich auf diesem Handy nicht reparieren. Erstelle einen neuen Kreis mit denselben Personen.';

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
  String userLocationMarkerSemantics(String accuracy) {
    return 'Markierung deines Standorts$accuracy';
  }

  @override
  String userLocationMarkerAccuracy(int meters) {
    final intl.NumberFormat metersNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String metersString = metersNumberFormat.format(meters);

    return '. Genauigkeit: $metersString Meter';
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
