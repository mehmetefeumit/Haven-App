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
      'Dein Standort wird auf deinem Gerät verschlüsselt, bevor er es verlässt, sodass nur die Kreise, die du auswählst, ihn lesen können – niemals Haven oder jemand anderes. Da Haven quelloffen ist, kann das jeder überprüfen.';

  @override
  String get onboardingValueProp2Title => 'Niemand kann es abschalten';

  @override
  String get onboardingValueProp2Body =>
      'Haven hat keinen zentralen Server. Deine verschlüsselten Nachrichten laufen über ein dezentrales Netzwerk aus Relays, die du selbst wählen kannst, sodass keine einzelne Stelle es abschalten kann.';

  @override
  String get onboardingValueProp3Title => 'Kein Konto erforderlich';

  @override
  String get onboardingValueProp3Body =>
      'Keine E-Mail-Adresse, keine Telefonnummer, keine Registrierung. Haven erstellt eine private Identität, die nur auf deinem Telefon lebt und durch nichts mit deiner realen Person verknüpft ist.';

  @override
  String get onboardingValueProp1Summary =>
      'Auf deinem Gerät verschlüsselt – lesbar nur für die Kreise, die du auswählst.';

  @override
  String get onboardingValueProp2Summary =>
      'Kein zentraler Server – läuft über ein Relay-Netzwerk deiner Wahl.';

  @override
  String get onboardingValueProp3Summary =>
      'Keine E-Mail, keine Telefonnummer, keine Anmeldung. Nichts verweist auf dich.';

  @override
  String get onboardingCreateIdentityTitle => 'Erstelle deine Identität';

  @override
  String get onboardingCreateIdentityBody =>
      'Haven erstellt eine private Identität, die nur auf diesem Telefon lebt. Daran erkennen dich deine Kreise.';

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
      'kind 10050, wo Einladungen dich erreichen';

  @override
  String get relaySettingsKeyPackageTitle => 'Meine KeyPackage-Relays';

  @override
  String get relaySettingsKeyPackageSubtitle =>
      'kind 10051, wo Eingeladene deine Verschlüsselungsschlüssel finden';

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
  String get relaySettingsExplainerSemantics =>
      'So funktionieren Havens Relays';

  @override
  String get relaySettingsExplainerHeading => 'So funktioniert es';

  @override
  String get relaySettingsExplainerNostr =>
      'Haven hat keinen zentralen Server. Es basiert auf zwei offenen Technologien. Nostr ist ein Netzwerk aus unabhängigen Servern, sogenannten Relays, die jeder betreiben kann; sie empfangen deine Nachrichten, halten sie kurz vor und geben sie weiter, wenn deine Kontakte sie anfordern. Kein einzelnes Relay ist unverzichtbar, sodass die anderen weiterarbeiten, wenn eines offline geht, und alles, was ein Relay herausgeben könnte, sind ausschließlich verschlüsselte Daten.';

  @override
  String get relaySettingsExplainerMarmot =>
      'Das Marmot-Protokoll verschlüsselt deine Nachrichten auf deinem Gerät, bevor sie es verlassen, mithilfe des MLS-Standards (Messaging Layer Security). Jeder Kreis ist seine eigene verschlüsselte Gruppe mit eigenen Schlüsseln, sodass sich verschiedene Kreise nicht miteinander verknüpfen lassen. Diese Schlüssel entwickeln sich außerdem ständig weiter – eine Eigenschaft namens Forward Secrecy –, sodass selbst ein später offengelegter Schlüssel deine früheren Nachrichten nicht entschlüsseln kann.';

  @override
  String get relaySettingsExplainerMetadata =>
      'Dadurch sieht ein Relay niemals deinen Standort, deine Nachrichten, wer in deinen Kreisen ist oder deine Identität auf diesen Nachrichten. Jede Nachricht wird von einer frischen, einmalig genutzten Absenderadresse veröffentlicht, sodass nichts in der Nachricht sie mit deinem Konto verbindet. Ein Relay sieht jedoch weiterhin einige Metadaten: ein zufälliges Kennzeichen pro Kreis, den Zeitpunkt und die Größe deines Datenverkehrs sowie die Netzwerkadresse, von der aus du dich verbindest.';

  @override
  String get relaySettingsExplainerInboxTerm => 'Posteingangs-Relays';

  @override
  String get relaySettingsExplainerInboxBody =>
      ' sind dein Briefkasten: Hier werden Einladungen, einem Kreis beizutreten – selbst verschlüsselt – für dich zur Abholung zugestellt. Damit jemand dich einladen kann, muss er eines dieser Relays erreichen können.';

  @override
  String get relaySettingsExplainerKeyPackageTerm => 'KeyPackage-Relays';

  @override
  String get relaySettingsExplainerKeyPackageBody =>
      ' sind die Relays, auf denen du ein kleines Bündel deiner öffentlichen Schlüssel veröffentlichst, das gefahrlos geteilt werden kann. Wer dein Konto kennt, holt es von diesen Relays ab, um dich zu einem Kreis hinzuzufügen.';

  @override
  String get relaySettingsExplainerOwnRelayTerm =>
      'Ein eigenes Relay verwenden.';

  @override
  String get relaySettingsExplainerOwnRelayBody =>
      ' Jeder Kreis führt außerdem seine eigene Relay-Liste, die beim Beitritt mit jedem Mitglied geteilt wird; über diese Liste – nicht über deinen Posteingang – laufen die fortlaufenden verschlüsselten Aktualisierungen des Kreises. Wenn du also lieber öffentliche Relays vermeiden möchtest, kannst du ein eigenes betreiben und einen Kreis darauf verweisen: Sobald alle beigetreten sind, kann der Datenverkehr dieses Kreises allein darüber fließen.';

  @override
  String get relaySettingsExplainerReachabilityTerm =>
      'Der Haken ist die Erreichbarkeit.';

  @override
  String get relaySettingsExplainerReachabilityBody =>
      ' Jedes Mitglied muss eine Verbindung zu diesem Relay herstellen können, und wenn du jemanden zum ersten Mal einlädst, braucht ihr beide ein Relay, das ihr beide erreichen könnt (zum Beispiel dasselbe private Relay, das bei allen als Posteingangs- und KeyPackage-Relay eingetragen ist). Ein privates Relay sieht weiterhin denselben verschlüsselten Datenverkehr und dieselben Zeitpunkte wie jedes andere; du bestimmst lediglich, wer es betreibt.';

  @override
  String get relaySettingsExplainerFooter =>
      'Du kannst jederzeit Relays in einer der beiden Listen hinzufügen oder entfernen. Mehr Relays machen dich leichter erreichbar; weniger geben dir mehr Kontrolle darüber, wohin dein verschlüsselter Datenverkehr geht.';

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
      'Wenn das Teilen im Hintergrund aktiviert ist, sehen deine Kreise deinen Live-Standort weiterhin, selbst wenn Haven geschlossen ist.';

  @override
  String get locationSettingsToggleTitle => 'Im Hintergrund teilen';

  @override
  String get locationSettingsToggleSubtitle =>
      'Weiter teilen, wenn die App geschlossen ist';

  @override
  String get locationSettingsIosLimitedNote =>
      'Das Teilen läuft mit deiner aktuellen Berechtigung auch im Hintergrund weiter. Setze in den Einstellungen für Haven den Standortzugriff auf „Immer“, damit Aktualisierungen auch dann wieder anlaufen können, wenn iOS die App beendet.';

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
  String get aboutWhoCanSeeTitle => 'Wer was sehen kann';

  @override
  String get aboutWhoCanSeeIntro =>
      'Deinen genauen Standort können nur die Personen lesen, die du auswählst. Hier siehst du, was die wichtigsten Beteiligten sehen können und was nicht.';

  @override
  String get aboutActorCirclesWho => 'Kreismitglieder, mit denen du teilst';

  @override
  String get aboutActorCirclesSees =>
      'Deinen genauen Standort und den Anzeigenamen, den du wählst, aber nur innerhalb der Kreise, in denen du mit ihnen teilst, niemals deine anderen Kreise.';

  @override
  String get aboutActorRelaysWho => 'Relay-Betreiber';

  @override
  String get aboutActorRelaysSees =>
      'Die Server, die deine Nachrichten weiterleiten. Sie sehen deine IP-Adresse, den öffentlichen Schlüssel, unter dem du veröffentlichst (eine zufällige Kennung, nicht deinen Namen), die Größe und den Zeitpunkt deines Datenverkehrs sowie das Konto, nach dem du gesucht hast, wenn du jemanden nachschlägst. Sie können niemals deinen Standort, deine Nachrichten, deine Kreisnamen oder die Mitglieder deiner Kreise lesen.';

  @override
  String get aboutActorMapWho => 'Der Kartenanbieter (Stadia Maps)';

  @override
  String get aboutActorMapSees =>
      'Nur während die Karte geöffnet ist: deine IP-Adresse und den Bereich, den du betrachtest, damit er die passenden Kartenbilder senden kann. Niemals deine Kreise oder deinen geteilten Standort. Stadia anonymisiert IP-Adressen und verkauft deine Daten nicht.';

  @override
  String get aboutActorDevelopersWho => 'Havens Entwickler';

  @override
  String get aboutActorDevelopersSees =>
      'Nichts. Haven betreibt keine Server und sammelt keine Analysedaten. Ein Entwickler könnte nur das sehen, was ein Relay-Betreiber sieht, und auch nur, wenn du ein Relay verwendest, das er zufällig betreibt.';

  @override
  String get aboutWhoCanSeeMetadataNote =>
      'Dennoch ist deine Aktivität nicht unsichtbar. Ein Relay, das du nutzt, oder jemand, der deinen Netzwerkverkehr beobachtet, kann anhand von Verbindungszeitpunkten und Nachrichtengrößen erkennen, dass du aktiv bist, ungefähr wann und wie oft.';

  @override
  String get aboutScreenshotTitle => 'Screenshot-Schutz';

  @override
  String get aboutScreenshotBody =>
      'Unter Android blockiert Haven appweit Screenshots und Bildschirmaufnahmen, um eine versehentliche Offenlegung des Standorts zu verhindern. Dies ist ein Schutz auf Systemebene (FLAG_SECURE), der für jeden Bildschirm der App gilt, einschließlich Karte und Mitgliederlisten.';

  @override
  String get aboutVpnTitle => 'Mit einem VPN noch privater bleiben';

  @override
  String get aboutVpnBody =>
      'Relays und der Kartenanbieter sehen deine IP-Adresse, und dein Internetanbieter sieht, welche Server du erreichst. Ein vertrauenswürdiges VPN verbirgt deine IP-Adresse vor ihnen. Wir empfehlen Mullvad. Es ändert nicht, was deine Kreismitglieder sehen, und es verlagert das Vertrauen auf den VPN-Anbieter.';

  @override
  String get aboutVpnLinkLabel => 'mullvad.net';

  @override
  String get aboutFooterLicense => 'Lizenziert unter der MIT License';

  @override
  String aboutFooterVersion(String version) {
    return 'Version $version';
  }

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
  String get createCircleNoAccountFound => 'Kein Haven-Konto gefunden';

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
      'Alle in diesem Kreis können den Standort und Anzeigenamen der anderen sehen. Dein Anzeigename ist der, den du unter Einstellungen → Identität festlegst. Dieser Kreis bleibt von allen anderen, in denen du bist, getrennt, sodass seine Mitglieder deine anderen Kreise oder deren Mitglieder nicht sehen können.';

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
      'Neue Mitglieder können die verschlüsselten Standorte dieses Kreises sehen, sobald sie die Einladung annehmen.';

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
  String get pendingMemberRemoveTooltip => 'Mitglied entfernen';

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
  String get circleDetailsRelaysHeading => 'Relays für diesen Kreis';

  @override
  String get circleDetailsNoRelays => '(keine erfasst)';

  @override
  String get circleDetailsRelaysNote =>
      'Diese Relays wurden bei der Erstellung dieses Kreises ausgewählt und sind noch nicht bearbeitbar. Sie sind unabhängig von deinen persönlichen Relay-Einstellungen.';

  @override
  String get circleDetailsAddMember => 'Mitglied hinzufügen';

  @override
  String get circleDetailsLeaveCircle => 'Kreis verlassen';

  @override
  String get leaveCircleDialogTitle => 'Kreis verlassen';

  @override
  String get leaveCircleDialogBody =>
      'Möchtest du diesen Kreis wirklich verlassen? Du erhältst dann keine Standortaktualisierungen seiner Mitglieder mehr. Diese Aktion kann nicht rückgängig gemacht werden.';

  @override
  String get leaveCircleConfirm => 'Verlassen';

  @override
  String get leaveCircleIdentityUnavailable => 'Identität nicht verfügbar';

  @override
  String get leaveCircleSuccess => 'Kreis erfolgreich verlassen';

  @override
  String get leaveCircleError => 'Kreis konnte nicht verlassen werden';

  @override
  String get leaveCircleAdminLimitationNote =>
      'Als Admin dieses Kreises kannst du ihn erst verlassen, wenn alle anderen Mitglieder ihn verlassen haben. Wir wissen, dass das unpraktisch ist – ein zukünftiges Update wird es Admins ermöglichen, die Rolle zu übergeben und den Kreis direkt zu verlassen.';

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
      'Havens Verschlüsselungs-Engine wurde aktualisiert, daher kann dieser Kreis nicht mehr verwendet werden. Erstelle ihn neu, um den Standort weiterhin mit denselben Personen zu teilen – du musst sie erneut einladen.';

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
      'Deine Identität und dein öffentliches Profil sind unverändert – dafür musst du nichts tun.';

  @override
  String get legacyCutoverExplainerCirclesNeedRecreation =>
      'Für mehr Sicherheit müssen deine Kreise neu erstellt und ihre Mitglieder erneut eingeladen werden, bevor du wieder Standorte darin teilen kannst.';

  @override
  String get legacyCutoverExplainerAcknowledge => 'Verstanden';

  @override
  String get relaySettingsLegacyRetractionPending =>
      'Haven räumt noch einige Daten vom letzten Sicherheitsupdate auf. Das wird automatisch abgeschlossen, sobald du wieder online bist.';

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
      'Dadurch wird deine Identität dauerhaft gelöscht. Stelle sicher, dass du deinen geheimen Schlüssel gesichert hast, falls du sie wiederherstellen möchtest.';

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
      'Dein öffentlicher Schlüssel funktioniert wie ein Benutzername, der gefahrlos geteilt werden kann. Andere scannen diesen Code oder fügen deinen öffentlichen Schlüssel ein, um dich zu einem Kreis einzuladen. Durch das Teilen wird weder dein Standort preisgegeben, der nur für Mitglieder der Kreise sichtbar ist, denen du beigetreten bist, noch dein Name und dein Foto, die auf diesem Gerät bleiben, sofern du dich nicht dafür entscheidest, ein öffentliches Profil zu veröffentlichen.';

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
      'Dadurch wird dein Foto aus deinem öffentlichen Profil entfernt.';

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
      'Foto aktualisiert – in deinem öffentlichen Nostr-Profil veröffentlicht.';

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
      other: 'vor $countString Minuten',
      one: 'vor 1 Minute',
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
      other: 'vor $countString Stunden',
      one: 'vor 1 Stunde',
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
      other: 'vor $countString Tagen',
      one: 'vor 1 Tag',
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
