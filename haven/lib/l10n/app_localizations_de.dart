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
  String get onboardingValueProp1Body =>
      'Dein Standort wird auf deinem Gerät verschlüsselt, bevor er das Gerät verlässt, sodass nur die Kreise, die du auswählst, ihn lesen können – niemals Haven oder jemand anderes. Da Haven quelloffen ist, kann das jeder überprüfen.';

  @override
  String get onboardingValueProp2Title => 'Niemand kann es abschalten';

  @override
  String get onboardingValueProp2Body =>
      'Haven hat keinen zentralen Server. Deine verschlüsselten Nachrichten laufen über unabhängige Server, Relays genannt, und du wählst selbst, welche du nutzt. Kein einzelnes Unternehmen und keine Regierung kann das Netzwerk abschalten.';

  @override
  String get onboardingValueProp3Title => 'Kein Konto erforderlich';

  @override
  String get onboardingValueProp3Body =>
      'Keine E-Mail-Adresse, keine Telefonnummer, keine Registrierung. Haven erstellt eine Identität, deren geheimer Schlüssel dein Telefon nie verlässt – es gibt also kein Konto, das irgendwer herausgeben könnte.';

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
  String get settingsIdentitySubtitle => 'Profil, Schlüssel und Foto-Sharing';

  @override
  String get settingsRelaysTitle => 'Relays';

  @override
  String get settingsRelaysSubtitle => 'Wo Einladungen dich erreichen';

  @override
  String get settingsLocationTitle => 'Standort';

  @override
  String get settingsLocationSubtitle =>
      'Teilen im Hintergrund und Berechtigungen';

  @override
  String get settingsMapStyleTitle => 'Kartenstil';

  @override
  String get settingsAppearanceSubtitle => 'Design und Sprache';

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
  String get locationSettingsErrorSnack => 'Etwas ist schiefgelaufen';

  @override
  String get locationSettingsIntro =>
      'Haven teilt deinen Standort mit deinen Kreisen, solange die App geöffnet ist. Schaltest du das hier ein, sehen deine Kreise ihn auch weiter, während Haven im Hintergrund läuft. Beendet das System Haven, wird dein Standort nicht mehr geteilt – im Hintergrund wird Haven nur aufgeweckt, um die Standorte deiner Kreise abzurufen; dein eigener Standort wird dabei nie gesendet. Unter Android wird dein Standort aber auch dann weiter geteilt, wenn du Haven aus dem App-Umschalter wischst, und nach einem Neustart des Geräts beginnt das Teilen deines Standorts von allein wieder; auf dem iPhone bleibt das Teilen gestoppt, bis du Haven öffnest.';

  @override
  String get locationSettingsToggleTitle => 'Im Hintergrund teilen';

  @override
  String get locationSettingsToggleSubtitle =>
      'Weiter teilen, solange Haven im Hintergrund läuft';

  @override
  String get locationSettingsIosLimitedNote =>
      'Das Teilen läuft mit deiner aktuellen Berechtigung auch im Hintergrund weiter. Setze in den Einstellungen für Haven den Standortzugriff auf „Immer“, damit Haven auch dann noch die verpassten Standorte deiner Kreise nachholen kann, wenn iOS die App beendet hat. Dein eigener Standort wird erst wieder geteilt, wenn du Haven erneut öffnest.';

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
      'Solange das Teilen im Hintergrund aktiviert ist, hält Haven eine durchgehende Standortsitzung aufrecht, und iOS zeigt in der Statusleiste eine blaue Anzeige. Mit der Berechtigung „Immer“ kann Haven außerdem Verpasstes aus deinen Kreisen nachholen, nachdem iOS die App beendet hat.';

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
  String get aboutVpnLinkLabel => 'mullvad.net';

  @override
  String get aboutFooterLicense => 'Lizenziert unter der MIT License';

  @override
  String aboutFooterVersion(String version) {
    return 'Version $version';
  }

  @override
  String get privacyTitle => 'Privatsphäre';

  @override
  String get privacySubtitle =>
      'Wie Haven funktioniert und was andere sehen können';

  @override
  String get privacyHubSummary =>
      'Haven teilt deinen Standort nur mit kleinen Gruppen deiner Wahl, den sogenannten Kreisen, und verschlüsselt ihn auf deinem Handy, bevor er es verlässt. Es gibt keine Anmeldung und keinen Haven-Server. Öffentlich sind der Anzeigename und das Foto, die du festlegst, und dazu die Schlüssel und Relay-Listen, die andere brauchen, um dich einzuladen. Die folgenden Seiten erklären das und alles Weitere in einfachen Worten.';

  @override
  String get privacyGroupBasicsHeading => 'Die Grundlagen';

  @override
  String get privacyMeansForYouLabel => 'Was das für dich bedeutet';

  @override
  String get privacyMoreDetailLabel => 'Genauer betrachtet';

  @override
  String get privacyMoreDetailExpandHint => 'Technische Details einblenden';

  @override
  String get privacyMoreDetailCollapseHint => 'Technische Details ausblenden';

  @override
  String get privacyMoreDetailExpandedAnnouncement =>
      'Technische Details eingeblendet';

  @override
  String get privacyMoreDetailCollapsedAnnouncement =>
      'Technische Details ausgeblendet';

  @override
  String get privacyWhatHavenIsTitle =>
      'Was Haven ist – und warum es kein Konto gibt';

  @override
  String get privacyWhatHavenIsSubtitle => 'Keine Anmeldung, kein Firmenserver';

  @override
  String get privacyWhatHavenIsNoAccount =>
      'Haven teilt deinen Standort mit kleinen Gruppen, die du selbst auswählst – Kreise genannt. Dahinter steht kein Konto. Du gibst niemals eine E-Mail-Adresse, eine Telefonnummer oder ein Passwort an.';

  @override
  String get privacyWhatHavenIsNoServers =>
      'Haven betreibt auch keine eigenen Server. Deine verschlüsselten Standortmeldungen laufen über unabhängige Server, Relays genannt, die andere Menschen betreiben. Havens Entwickler können deinen Standort nicht sehen und haben keinerlei Tracking in die App eingebaut. Sie sehen nur eines: wie stark die Karte insgesamt genutzt wird, denn die Kartenkacheln werden mit einem einzigen gemeinsamen Schlüssel abgerufen. Wer sie abgerufen hat, bleibt ihnen verborgen.';

  @override
  String get privacyWhatHavenIsMeansForYou =>
      'Kein Relay-Betreiber kann gezwungen werden, deinen Standort herauszugeben, denn die Server, über die dein Standort läuft, können ihn nicht lesen. Der Preis dafür ist, dass niemand deine Identität für dich wiederherstellen kann und dass alles, was du bereits veröffentlicht hast, veröffentlicht bleibt. Unter „Deine zwei Schlüssel“ steht, was du sichern solltest.';

  @override
  String get privacyWhatHavenIsDetailNoTelemetry =>
      'Die App enthält keinen Code für Analysen, Absturzberichte oder Werbung. Da Haven quelloffen ist, lässt sich das überprüfen und muss nicht auf Vertrauen beruhen.';

  @override
  String get privacyWhatHavenIsDetailNoPush =>
      'Haven hat außerdem absichtlich keine Push-Benachrichtigungen. Ein Benachrichtigungsdienst müsste jedes Mal erfahren, wenn jemand aus deinen Kreisen etwas zuzustellen hat – und würde damit mehr über deine Gewohnheiten verraten als die Relays.';

  @override
  String get privacyYourKeysTitle =>
      'Deine zwei Schlüssel: einer geheim, einer zum Teilen';

  @override
  String get privacyYourKeysSubtitle =>
      'Was dich ausweist und was du sichern solltest';

  @override
  String get privacyYourKeysWhatTheyAre =>
      'Anstelle von Benutzername und Passwort hast du ein Schlüsselpaar. Der geheime Schlüssel beweist, dass du es wirklich bist. Den öffentlichen Schlüssel nutzen andere, um dich zu finden und einzuladen.';

  @override
  String get privacyYourKeysSecretStaysHere =>
      'Dein geheimer Schlüssel bleibt nur auf diesem Handy, in einem Speicher, den das Betriebssystem schützt. Haven sendet ihn nirgendwohin: nicht an einen Server, nicht an uns.';

  @override
  String get privacyYourKeysPublicIsSafe =>
      'Deinen öffentlichen Schlüssel kannst du gefahrlos weitergeben. Er funktioniert wie ein Benutzername, den du überall veröffentlichen darfst. Wenn du ihn teilst, verrät das nicht, wo du bist.';

  @override
  String get privacyYourKeysMeansForYou =>
      'Willst du diese Identität behalten, sichere sie. Gehe zu Einstellungen → Identität → Erweitert, tippe auf „Geheimen Schlüssel anzeigen“ und speichere ihn an einem sicheren Ort, zum Beispiel in einem Passwortmanager. Ohne diese Sicherung ist die Identität endgültig verloren, wenn du das Handy verlierst.';

  @override
  String get privacyYourKeysNeverShareSecret =>
      'Wer deinen geheimen Schlüssel bekommt, wird zu dir: Diese Person könnte in deinem Namen Kreisen beitreten oder unter deinem Namen veröffentlichen. Füge ihn niemals in eine andere App, eine Nachricht oder eine Website ein.';

  @override
  String get privacyYourKeysDetailFormats =>
      'Beide Schlüssel sind secp256k1 und werden in den üblichen Nostr-Formaten angezeigt: npub1… für den öffentlichen und nsec1… für den geheimen Schlüssel. Signiert wird innerhalb der App, und der geheime Schlüssel wird in den Teilen, die ihn direkt verarbeiten, gleich nach der Nutzung gelöscht.';

  @override
  String get privacyYourKeysDetailSeparation =>
      'Die Schlüssel, mit denen die Nachrichten deiner Kreise verschlüsselt werden, sind von diesem Identitätsschlüssel getrennt und liegen nur bei der App. Diese Trennung ist Absicht: Der Schlüssel, der dich benennt, ist nicht der Schlüssel, mit dem sich öffnen lässt, was du gesendet hast.';

  @override
  String get privacyPublicProfileTitle =>
      'Dein Name und dein Foto sind öffentlich';

  @override
  String get privacyPublicProfileSubtitle =>
      'Für alle sichtbar, nicht nur für deine Kreise';

  @override
  String get privacyPublicProfileIsPublic =>
      'Der Anzeigename und das Foto, die du festlegst, werden auf Nostr veröffentlicht, dem offenen öffentlichen Netzwerk, auf dem Haven läuft. Jeder kann sie nachschlagen, nicht nur die Menschen in deinen Kreisen.';

  @override
  String get privacyPublicProfileOnSave =>
      'Dein Name und dein Foto werden in dem Moment öffentlich, in dem du sie speicherst. Es gibt keine Einstellung, die sie privat hält, und keine Möglichkeit, einen Namen nur mit deinen Kreisen zu teilen.';

  @override
  String get privacyPublicProfilePseudonym =>
      'Neue Installationen starten mit einem erfundenen Namen wie „Quiet Wanderer“, der nichts über dich verrät. Du kannst ihn behalten oder durch einen beliebigen anderen ersetzen.';

  @override
  String get privacyPublicProfileMeansForYou =>
      'Wähle einen Namen und ein Foto, die du gerne öffentlich zeigst. Wenn du nicht erkannt werden möchtest, behalte den erfundenen Namen, den du bekommen hast, und lass das Foto weg.';

  @override
  String get privacyPublicProfileRemovalIsNotDeletion =>
      'Dein Foto später zu entfernen, löscht nicht die Kopie auf dem Server. Haven ersetzt dein Profil durch ein leeres. Die Bilddatei bleibt dort liegen, wo sie gehostet wird, und jede bereits heruntergeladene Kopie bleibt im Umlauf. Betrachte alles, was du veröffentlichst, als dauerhaft.';

  @override
  String get privacyPublicProfileDetailKindZero =>
      'Das Profil ist ein Nostr-Ereignis vom Typ „kind 0“, das mit deinem Identitätsschlüssel signiert wird. Fotos werden zu einem öffentlichen Bild-Host hochgeladen, blossom.primal.net, der das Bild, deinen öffentlichen Schlüssel und deine Netzwerkadresse sieht. Einen anderen Host kannst du in Haven bisher nicht wählen.';

  @override
  String get privacyPublicProfileDetailExifStripped =>
      'Vor dem Hochladen kodiert Haven das Bild neu und entfernt die verborgenen Daten, die Kameras anhängen – darunter die GPS-Position, an der das Foto entstanden ist. Das ist hier wichtig: Ein Urlaubsschnappschuss kann sonst die Koordinaten deines Zuhauses mitführen.';

  @override
  String get privacyGroupHowLocationTravelsHeading =>
      'Der Weg deines Standorts';

  @override
  String get privacyRelaysTitle =>
      'Relays: die Server, die Nachrichten weitergeben';

  @override
  String get privacyRelaysSubtitle =>
      'Über wessen Computer deine Aktualisierungen laufen';

  @override
  String get privacyRelaysWhatIsARelay =>
      'Haven hat keinen eigenen Server, also laufen deine Aktualisierungen über die Server anderer Leute. Man nennt sie Relays: kleine, unabhängige Server, die jeder betreiben kann. Ein Relay hält eine verschlüsselte Nachricht kurz vor und gibt sie weiter, wenn dein Kreis sie anfordert.';

  @override
  String get privacyRelaysWhyMany =>
      'Haven nutzt mehrere Relays, damit dich keines allein vom Netz trennen kann. Geht eines offline, arbeiten die übrigen weiter. Du wählst selbst die Relays, über die dich Einladungen erreichen; die Relays eines Kreises stehen fest, sobald er erstellt ist.';

  @override
  String get privacyRelaysYourLists =>
      'Haven führt drei Listen für dich. Über deine Posteingangs-Relays erreichen dich Einladungen, und von deinen KeyPackage-Relays holen andere die Schlüssel, die sie brauchen, um dich einzuladen – beide Listen veröffentlicht Haven, damit andere sie finden. Deine Profil-Relays sind anders: Dort werden dein Name und dein Foto nachgeschlagen und veröffentlicht, die Liste selbst bleibt aber auf deinem Gerät und wird nie veröffentlicht. Ein Relay, über das nur deine Standortmeldungen oder Einladungen laufen, hat daher keine öffentliche Liste, die ihm verrät, welche Relays du für dein Profil nutzt. Jeder Kreis führt außerdem seine eigene Liste, und über sie laufen die verschlüsselten Aktualisierungen des Kreises.';

  @override
  String get privacyRelaysMeansForYou =>
      'Ein Relay sieht deinen Standort nie, denn er wird verschlüsselt, bevor er dein Handy verlässt. Es sieht aber, was öffentlich sein muss, damit andere dich erreichen können: die Schlüssel, die andere zum Einladen brauchen, und die Listen, die angeben, welche Relays genutzt werden sollen. Dein Name und dein Foto sind ebenfalls öffentlich, gehen aber an eine getrennte Gruppe von Relays. Haven bringt von Anfang an funktionierende Relays mit, du musst also nichts ändern.';

  @override
  String get privacyRelaysDetailIndexers =>
      'Unabhängig von deinen eigenen Listen nutzt Haven zwei Gruppen öffentlicher Server, die du nicht auswählst: acht, um die Namen und Fotos anderer Leute nachzuschlagen, und sechs, um die Schlüssel nachzuschlagen, die man zum Einladen braucht. Die beiden Gruppen überschneiden sich nie. Du kannst der Profil-Gruppe eigene Server hinzufügen, diese acht aber nicht daraus entfernen. Haven kontaktiert beide Gruppen auch dann, wenn alle Relays, die du für dich selbst gewählt hast, privat sind, und jeder dieser Server sieht deine Netzwerkadresse.';

  @override
  String get privacyRelaysDetailProfileLookups =>
      'Bei Namen und Fotos fragt Haven immer nur nach einer Person auf einmal. Jeder Person wird auf deinem Gerät ein Server zugeordnet; hat dieser Server nichts zu dieser Person, fragt Haven noch einen zweiten. Schlägst du jemanden nach, erfahren davon also höchstens zwei der acht Server, nie die ganze Gruppe. Haven mischt diese Zuordnungen nie von sich aus neu; sie verschieben sich aber, wenn sich die Gruppe der Server ändert. So verteilen sich deine Anfragen, statt alle bei einem einzigen Server zu landen. Jeder zugeordnete Server sammelt trotzdem mit der Zeit eine dauerhafte Spur davon, dass dein Handy immer wieder nach derselben Person fragt, und wenn es nur wenige Personen sind, können mehrere von ihnen demselben Server zugeordnet sein. Wenn du deinen eigenen Namen oder dein Foto speicherst, geht das an alle Profil-Relays, die du gerade nutzt – das sind die acht Server, minus die von Haven ausgeschlossenen und plus die von dir selbst hinzugefügten –, und jedes dieser Relays erfährt dadurch deinen öffentlichen Schlüssel.';

  @override
  String get privacyRelaysDetailKeyListIsPublic =>
      'Deine Liste der KeyPackage-Relays wird mit deinem Identitätsschlüssel signiert und auf den Relays veröffentlicht, die bereits darin stehen. Fügst du dort ein privates Relay hinzu, wird seine Adresse öffentlich und mit dir verknüpft. Es gibt keine Möglichkeit, ein Relay auf dieser Liste privat zu halten.';

  @override
  String get privacyEncryptionTitle => 'Wie die Verschlüsselung funktioniert';

  @override
  String get privacyEncryptionSubtitle =>
      'Ein Schlüssel pro Kreis, und was sich bei Beitritt oder Austritt ändert';

  @override
  String get privacyEncryptionPerCircle =>
      'Dein Standort wird auf deinem Handy verschlüsselt, bevor er es verlässt, und zwar mit einem offenen Standard namens MLS. Jeder Kreis ist seine eigene verschlüsselte Gruppe mit eigenen Schlüsseln. Niemand außerhalb eines Kreises kann lesen, was darin gesendet wird: kein Relay, nicht Haven und kein anderer Kreis, dem du angehörst.';

  @override
  String get privacyEncryptionWhenSomeoneJoins =>
      'Tritt jemand bei, wechselt der Kreis auf einen neuen Schlüssel. Diese Person kann lesen, was nach ihrer Ankunft gesendet wird, und nichts von davor. Haven sendet einem neuen Mitglied niemals frühere Standorte.';

  @override
  String get privacyEncryptionWhenSomeoneLeaves =>
      'Verlässt jemand einen Kreis, wechselt dieser auf einen weiteren neuen Schlüssel. Sobald der Rest des Kreises nachgezogen ist, kann diese Person nichts Neues mehr lesen. Das dauert meist wenige Minuten und länger, wenn jemand zu diesem Zeitpunkt offline war.';

  @override
  String get privacyEncryptionKeysChangeOnMembership =>
      'Einen Kreis zu verlassen, nimmt nicht zurück, was seine Mitglieder bereits gespeichert haben. Haven wechselt die Schlüssel nur, wenn jemand beitritt oder geht, nie nach einem Zeitplan. Ein einziger Schlüssel kann daher Wochen von Nachrichten abdecken, und alles, was ein Mitglied in dieser Zeit gespeichert hat, bleibt für diese Person lesbar. Was nach ihrem Austritt gesendet wird, kann sie trotzdem nicht öffnen.';

  @override
  String get privacyEncryptionMeansForYou =>
      'Die Verschlüsselung schützt dich vor allen außerhalb deiner Kreise. Sie schützt dich nicht vor jemandem, der einmal drin war. Willst du mit einer bestimmten Person nicht mehr teilen, verlasse den Kreis, über den du mit ihr teilst, und erstelle einen neuen ohne sie.';

  @override
  String get privacyEncryptionDetailMls =>
      'MLS (Messaging Layer Security) ist derselbe IETF-Standard, den auch andere sichere Messenger verwenden. Haven erreicht das Nostr-Netzwerk über das Marmot-Protokoll, das festlegt, wie MLS-Gruppen über Relays übertragen werden. Der Schlüssel, mit dem jeder Kreis signiert, ist von deinem öffentlichen Nostr-Identitätsschlüssel getrennt.';

  @override
  String get privacyEncryptionDetailEpochs =>
      'Jeder Schlüsselzeitraum heißt Epoche, und ein Kreis wechselt nur dann in eine neue, wenn sich seine Mitglieder ändern. Dein Gerät behält die Schlüssel der aktuellen und einiger weniger vorheriger Epochen, gerade genug für Nachrichten, die noch eintreffen, und verwirft den Rest. Ein Kreis, dessen Mitglieder sich seit Monaten nicht geändert haben, ist noch in der Epoche, mit der er begonnen hat.';

  @override
  String get privacyWhatOthersSeeTitle =>
      'Was Mitglieder sehen und was Relays sehen';

  @override
  String get privacyWhatOthersSeeSubtitle =>
      'Die Menschen, mit denen du teilst, und die Server dazwischen';

  @override
  String get privacyWhatOthersSeeMembersHeading =>
      'Die Menschen in deinen Kreisen';

  @override
  String get privacyWhatOthersSeeMembersExact =>
      'Alle in einem Kreis sehen deinen genauen Standort auf der Karte, keinen ungefähren Bereich. Es gibt keine Einstellung, die manchen Mitgliedern einen ungenauen Standort zeigt und anderen einen präzisen.';

  @override
  String get privacyWhatOthersSeeCannotPause =>
      'Solange Haven geöffnet ist und du zu einem Kreis gehörst, wird dein Standort alle paar Minuten von allein gesendet. Einen Pausenknopf gibt es nicht: Der Schalter auf der Seite „Standort“ legt nur fest, ob das weitergeht, während Haven im Hintergrund läuft. Beendet das System Haven, wird dein Standort nicht mehr geteilt. Unter Android wird dein Standort aber auch dann weiter geteilt, wenn du Haven aus dem App-Umschalter wischst, und nach einem Neustart des Geräts beginnt das Teilen deines Standorts von allein wieder; auf dem iPhone bleibt das Teilen gestoppt, bis du Haven öffnest. Willst du deinen Standort mit einem Kreis nicht mehr teilen, öffne diesen Kreis und wähle „Kreis verlassen“.';

  @override
  String get privacyWhatOthersSeeMembersLearnKey =>
      'Wenn du einem Kreis beitrittst, sehen alle Mitglieder auch deinen öffentlichen Schlüssel. Darüber können sie dein öffentliches Profil nachschlagen – und alles andere, was du je unter diesem Schlüssel veröffentlicht hast.';

  @override
  String get privacyWhatOthersSeeCoMemberIp =>
      'Dein Handy lädt das Profilfoto jedes Mitglieds von einem Server, den dieses Mitglied gewählt hat, ohne dass du irgendwo tippst. Dieser Server sieht dabei deine Netzwerkadresse und verortet dich damit ungefähr auf der Karte. Ein VPN verbirgt das; sonst nichts.';

  @override
  String get privacyWhatOthersSeeRelaysHeading => 'Die Relay-Betreiber';

  @override
  String get privacyWhatOthersSeeRelaysCannot =>
      'Relays, die unabhängigen Server, über die deine Aktualisierungen laufen, können weder deinen Standort noch deine Nachrichten, den Namen deines Kreises oder dessen Mitgliederliste lesen. Deine Standortmeldungen tragen statt deines öffentlichen Schlüssels eine frische, nur einmal genutzte Absenderadresse. Dein Profil, Einladungen und Relay-Listen tragen ihn dagegen sehr wohl. Ein Relay, das beides abwickelt, kann daher oft erkennen, dass du zu einem Kreis gehörst, ohne etwas von den Inhalten zu lesen.';

  @override
  String get privacyWhatOthersSeeRelaysCan =>
      'Sie sehen aber deine Netzwerkadresse, wann du online bist und wie groß und wie häufig dein Datenverkehr ist. Jeder Kreis trägt ein zufälliges Kennzeichen. Über dieses Kennzeichen kann ein Relay die Nachrichten eines Kreises gruppieren und abschätzen, wie viele Menschen darin sind, ohne zu erfahren, wer sie sind.';

  @override
  String get privacyWhatOthersSeeMeansForYou =>
      'Tritt einem Kreis nur mit Menschen bei, denen du deine Wohnadresse geben würdest. Gegen Relays und Außenstehende hält die Verschlüsselung, und ein VPN verbirgt die Adresse, von der aus sich dein Handy verbindet. Vor einem Mitglied, das einen Screenshot macht, schützt dich nichts.';

  @override
  String get privacyWhatOthersSeeDetailTag =>
      'Das Kennzeichen eines Kreises bleibt über die gesamte Lebensdauer des Kreises gleich, sodass ein Relay alle seine Nachrichten dauerhaft miteinander verknüpfen kann. Das Protokoll erlaubt einem Kreis durchaus, auf ein neues Kennzeichen zu wechseln, aber Haven tut das bisher nicht – und ein Wechsel würde auch nicht rückgängig machen, was ein Relay bereits verknüpft hat.';

  @override
  String get commonLearnMore => 'Mehr erfahren';

  @override
  String get relaySettingsBackendCaption =>
      'Haven hat keinen eigenen Server. Deine verschlüsselten Aktualisierungen laufen über unabhängige Server, Relays genannt, die deinen Standort und deine Nachrichten nicht lesen können.';

  @override
  String get privacyWhatOthersSeeScreenshots =>
      'Das hängt von deinem Handy ab. Unter Android blockiert Haven Screenshots und Bildschirmaufnahmen in der gesamten App. Auf dem iPhone kann Haven das nicht: Es macht die Vorschau im App-Umschalter unscharf, aber ein Mitglied kann trotzdem aufnehmen, was auf dem Bildschirm zu sehen ist.';

  @override
  String get privacyWhatOthersSeeDetailExpiry =>
      'Haven bittet die Relays, Standortnachrichten nach etwa vier Minuten zu verwerfen. Diese Bitte ist nur ein Hinweis: Ein Relay darf die Nachrichten auch länger behalten. Nur Standortnachrichten tragen dieses Verfallsdatum; fehlt es, kann ein Relay daran eine Mitgliederänderung von einer Standortnachricht unterscheiden. Einladungen haben überhaupt kein Verfallsdatum und können unbegrenzt auf deinem Posteingangs-Relay liegen bleiben.';

  @override
  String get privacyWhatOthersSeeDetailOnDevice =>
      'Das Handy jedes Mitglieds zeigt den letzten Standort, den es von dir empfangen hat, nach einem Tag nicht mehr an und löscht ihn, sobald das Mitglied Haven das nächste Mal öffnet. Davon unberührt bleibt, was ein Mitglied selbst gespeichert oder als Screenshot festgehalten hat – darauf hat Haven keinen Einfluss.';

  @override
  String get privacyWhatOthersSeeDetailOneConnection =>
      'Haven öffnet zu jedem Relay eine einzige Verbindung und wickelt darüber alles ab, was auf diesem Relay passiert. Trägt ein Relay sowohl deine Einladungen als auch die Nachrichten eines Kreises, fragt diese eine Verbindung gleichzeitig nach Einladungen, die an deinen eigenen öffentlichen Schlüssel gerichtet sind, und nach den Nachrichten dieses Kreises anhand seines Kennzeichens – und genau das erlaubt dem Relay, beides miteinander zu verknüpfen. Bei einer neuen Installation werden für beides dieselben Relays verwendet.';

  @override
  String get privacyGroupTheLimitsHeading => 'Die Grenzen';

  @override
  String get privacyInferenceTitle =>
      'Was sich trotzdem über dich herausfinden lässt';

  @override
  String get privacyInferenceSubtitle =>
      'Die Spuren, die die Verschlüsselung nicht verdeckt';

  @override
  String get privacyInferenceWhatIsMetadata =>
      'Die Verschlüsselung verbirgt, was du sendest. Sie kann nicht verbergen, dass du überhaupt etwas gesendet hast. Diese zurückbleibende Spur nennt man Metadaten: wann eine Nachricht hinausging, wie groß sie war und mit welchen Servern du verbunden warst. Sie bleibt sichtbar, auch wenn der Inhalt es nicht ist.';

  @override
  String get privacyInferenceActivityPattern =>
      'Aus diesem Muster kann ein Relay, das du nutzt, ungefähr ablesen, wann du aktiv bist und wie oft. Solange Haven auf dem Bildschirm ist – und auf dem iPhone auch, solange das Teilen im Hintergrund die App am Laufen hält –, sendet Haven außerdem jedes Mal, wenn du dich etwa hundert Meter bewegst, eine zusätzliche Standortmeldung, höchstens jedoch einmal pro Minute. Über Stunden hinweg kann das einem Relay zeigen, ob du unterwegs warst oder an einem Ort geblieben bist. Wo du bist, zeigt dieses Muster nie.';

  @override
  String get privacyInferencePresence =>
      'Solange Haven läuft, hält es eine offene Verbindung zu deinen Relays. Sie sehen dadurch, dass du online bist, und welchen Kreis-Kennzeichen du folgst, nie aber den Namen eines Kreises oder wer darin ist. Das ist der Preis dafür, dass Aktualisierungen in Sekunden statt in Minuten ankommen.';

  @override
  String get privacyInferenceIpHeading => 'Deine Netzwerkadresse';

  @override
  String get privacyInferenceIpAddress =>
      'Jeder Server, mit dem Haven spricht, sieht die Adresse, von der aus sich dein Handy verbindet, also seine IP-Adresse: deine Relays, der Kartenanbieter und wer auch immer das Profilfoto eines Mitglieds hostet. Dein Internetanbieter sieht, welche dieser Server du erreicht hast und wann. Haven verbirgt von sich aus weder das eine noch das andere.';

  @override
  String get privacyInferenceMapTilesHeading => 'Die Karte selbst';

  @override
  String get privacyInferenceMapTiles =>
      'Um die Karte zu zeichnen, fordert Haven beim Kartenanbieter die Bildkacheln an, die gerade auf dem Bildschirm zu sehen sind; er erfährt dadurch ungefähr, welche Orte du dir ansiehst. Haven lädt außerdem vorab einen kleinen Bereich rund um jedes Mitglied, das du sehen kannst, damit die Karte schon bereit ist, wenn du dorthin scrollst – der Anbieter kann daraus also ungefähr ablesen, wo sich dein Kreis gerade aufhält, und nicht nur, wohin du schaust. Diese Kacheln bleiben bis zu sieben Tage in einem verschlüsselten Zwischenspeicher auf deinem Handy und werden entfernt, falls du deine Identität löschst.';

  @override
  String get privacyInferenceVpnHeading => 'Ob ein VPN sinnvoll ist';

  @override
  String get privacyInferenceVpnHelps =>
      'Ein VPN ersetzt deine Adresse durch seine eigene, sodass Relays und die anderen Server nicht mehr sehen, von wo aus du dich verbindest. Außerdem verbirgt es vor deinem Internetanbieter, welche Server du erreichst. Wir empfehlen Mullvad.';

  @override
  String get privacyInferenceVpnLimits =>
      'Ein Allheilmittel ist es nicht. An dem, was deine Kreismitglieder sehen, ändert ein VPN nichts. Und vor dem Relay, mit dem du gerade sprichst, verbirgt es weder den Zeitpunkt noch die Größe deines Datenverkehrs. Es verlagert dein Vertrauen außerdem nur auf den VPN-Anbieter – vertrauen musst du weiterhin jemandem.';

  @override
  String get privacyInferenceMeansForYou =>
      'Sorgst du dich davor, dass Relays, dein Internetanbieter oder die Kartenserver dich auf einer Karte verorten? Dann ist ein VPN das Wirksamste, was du hinzufügen kannst. Sorgst du dich vor den Menschen in deinen Kreisen? Dann hilft es überhaupt nicht.';

  @override
  String get privacyInferenceDetailJitter =>
      'Haven variiert den Abstand zwischen den Aktualisierungen absichtlich, sodass eine kurze Aufzeichnung keinen klaren Rhythmus zeigt. Über viele Stunden gemittelt lässt sich die zugrunde liegende Häufigkeit dennoch abschätzen. Die Nachrichten werden auch nicht auf eine einheitliche Größe aufgefüllt, und Standortaktualisierungen liegen in einem engen Größenbereich – das macht sie als Standortaktualisierungen erkennbar.';

  @override
  String get privacyInferenceDetailOutOfScope =>
      'Zwei Dinge liegen jenseits jeder Gestaltungsentscheidung hier: ein Beobachter, der viele Relays gleichzeitig überwachen kann, und dein eigenes Handy, sobald jemand anders es kontrolliert.';

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
  String get createCircleMemberAlreadyAdded => 'Mitglied bereits hinzugefügt';

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
  String get circleMemberInvitationPending => 'Einladung ausstehend';

  @override
  String get circleMemberNoRecentLocation => 'Kein aktueller Standort';

  @override
  String get circleMemberRemoveTooltip => 'Aus Kreis entfernen';

  @override
  String get circleMemberAdmin => 'Admin';

  @override
  String get circleMemberHintPending => 'Einladung ausstehend';

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
  String selectedMembersMore(int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    return '+$countString weitere';
  }

  @override
  String get invitationStatusPending => 'Einladung ausstehend';

  @override
  String get invitationStatusActive => 'Aktiv';

  @override
  String get invitationStatusDeclined => 'Abgelehnt';

  @override
  String invitationStatusSemantics(String label) {
    return 'Einladungsstatus: $label';
  }

  @override
  String invitationCardSemantics(String circleName, String inviter, int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    return 'Einladung zum Beitritt zu $circleName, eingeladen von $inviter, $countString Mitglieder';
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
  String invitationCardMemberCount(int count) {
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
  String keyDisplayCopiedToClipboard(String label) {
    return '$label in die Zwischenablage kopiert';
  }

  @override
  String keyDisplaySemantics(String label, String state) {
    return '$label: $state';
  }

  @override
  String get keyDisplayStateRevealed => 'angezeigt';

  @override
  String get keyDisplayStateHidden => 'verborgen';

  @override
  String get keyDisplayHideTooltip => 'Verbergen';

  @override
  String get keyDisplayRevealTooltip => 'Anzeigen';

  @override
  String get keyDisplayCopyTooltip => 'Kopieren';

  @override
  String get keyDisplayCompactCopied =>
      'Schlüssel in die Zwischenablage kopiert';

  @override
  String get keyDisplayCompactTapToCopy => 'Zum Kopieren tippen';

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
      'Foto aktualisiert. In deinem öffentlichen Nostr-Profil veröffentlicht.';

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
