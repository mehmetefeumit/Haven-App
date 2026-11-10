// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for French (`fr`).
class AppLocalizationsFr extends AppLocalizations {
  AppLocalizationsFr([String locale = 'fr']) : super(locale);

  @override
  String get appearanceTitle => 'Apparence';

  @override
  String get appearanceThemeHeader => 'Thème';

  @override
  String get appearanceThemeSystem => 'Par défaut du système';

  @override
  String get appearanceThemeSystemSubtitle =>
      'Suivre les réglages de votre appareil';

  @override
  String get appearanceThemeLight => 'Clair';

  @override
  String get appearanceThemeLightSubtitle => 'Toujours utiliser le thème clair';

  @override
  String get appearanceThemeDark => 'Sombre';

  @override
  String get appearanceThemeDarkSubtitle => 'Toujours utiliser le thème sombre';

  @override
  String get appearanceLanguageTitle => 'Langue';

  @override
  String get languageSystemDefault => 'Par défaut du système';

  @override
  String get commonTryAgain => 'Réessayer';

  @override
  String get commonDismiss => 'Ignorer';

  @override
  String get commonSettings => 'Réglages';

  @override
  String get commonInvitations => 'Invitations';

  @override
  String commonPendingInvitations(int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$countString invitations en attente',
      many: '$countString invitations en attente',
      one: '$countString invitation en attente',
    );
    return '$_temp0';
  }

  @override
  String get commonBack => 'Retour';

  @override
  String get commonContinue => 'Continuer';

  @override
  String get commonSkip => 'Ignorer';

  @override
  String get commonRetry => 'Réessayer';

  @override
  String onboardingStepOf(int current, int total) {
    final intl.NumberFormat currentNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String currentString = currentNumberFormat.format(current);
    final intl.NumberFormat totalNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String totalString = totalNumberFormat.format(total);

    return 'Étape $currentString sur $totalString';
  }

  @override
  String get onboardingAppName => 'Haven';

  @override
  String get onboardingWelcomeHeadline =>
      'Partage de position privé et résistant à la censure.';

  @override
  String get onboardingWelcomeCta => 'Commencer';

  @override
  String get onboardingValueProp1Title => 'Seuls vos cercles peuvent vous voir';

  @override
  String get onboardingValueProp2Title => 'Personne ne peut le fermer';

  @override
  String get onboardingValueProp3Title => 'Aucun compte requis';

  @override
  String get onboardingValueProp1Summary =>
      'Chiffrée sur votre appareil : seuls les cercles que vous choisissez peuvent la lire. Même les relais qui la transmettent en sont incapables.';

  @override
  String get onboardingValueProp2Summary =>
      'Pas de serveur central. Haven s\'appuie sur des relais indépendants, gérés par de nombreuses personnes : aucune entreprise ne peut tout éteindre.';

  @override
  String get onboardingValueProp3Summary =>
      'Ni e-mail, ni téléphone, ni inscription. Votre clé secrète ne quitte jamais votre téléphone. Gardez le nom anonyme choisi par Haven, ou choisissez le vôtre.';

  @override
  String get onboardingCreateIdentityTitle => 'Créez votre identité';

  @override
  String get onboardingCreateIdentityCta => 'Créer mon identité';

  @override
  String get onboardingCreateIdentityLoading => 'Préparation en cours…';

  @override
  String get onboardingCreateIdentityImportPrompt => 'Vous avez déjà une clé ?';

  @override
  String get onboardingCreateIdentityImportLink => 'L\'importer à la place';

  @override
  String get onboardingCreateIdentityError =>
      'Un problème est survenu lors de la création de votre identité. Veuillez réessayer.';

  @override
  String get onboardingImportTitle => 'Importez votre clé existante';

  @override
  String get onboardingImportBody =>
      'Collez la clé secrète que vous avez sauvegardée depuis une autre application compatible avec Haven.';

  @override
  String get onboardingImportHint => 'nsec1…';

  @override
  String get onboardingImportCta => 'Importer';

  @override
  String get onboardingImportLoading => 'Importation…';

  @override
  String get onboardingImportInvalid =>
      'Cela ne ressemble pas à une clé de sauvegarde valide. Veuillez vérifier et réessayer.';

  @override
  String get onboardingImportError =>
      'Nous n\'avons pas pu importer cette clé. Veuillez vérifier et réessayer.';

  @override
  String get onboardingDisplayNameHint => 'ex. Alex';

  @override
  String get onboardingDisplayNameError =>
      'Impossible d\'enregistrer ce nom. Veuillez réessayer.';

  @override
  String get onboardingAddPhotoOptional => 'Ajouter une photo (facultatif)';

  @override
  String get commonCancel => 'Annuler';

  @override
  String get commonOpenSettings => 'Ouvrir les réglages';

  @override
  String get settingsTitle => 'Réglages';

  @override
  String get settingsIdentityTitle => 'Identité';

  @override
  String get settingsRelaysTitle => 'Relais';

  @override
  String get settingsLocationTitle => 'Position';

  @override
  String get settingsLocationSubtitleOn => 'Partage en arrière-plan activé';

  @override
  String get settingsLocationSubtitleOff => 'Uniquement quand Haven est ouvert';

  @override
  String get settingsMapStyleTitle => 'Style de carte';

  @override
  String get settingsAboutTitle => 'À propos';

  @override
  String get settingsDebugOverlayTitle =>
      'Superposition du journal de débogage';

  @override
  String get settingsDebugOverlaySubtitle => 'Afficher le journal à l\'écran';

  @override
  String get relaySettingsTitle => 'Relais';

  @override
  String get relaySettingsCheckRelaysTooltip => 'Vérifier les relais';

  @override
  String get relaySettingsNoIdentityTitle => 'Aucune identité';

  @override
  String get relaySettingsNoIdentityMessage =>
      'Créez d\'abord une identité pour gérer les relais.';

  @override
  String get relaySettingsLoadIdentityError =>
      'Échec du chargement de l\'identité.';

  @override
  String get relaySettingsInboxTitle => 'Mes relais de réception';

  @override
  String get relaySettingsInboxSubtitle =>
      'Là où les invitations vous parviennent (kind 10050)';

  @override
  String get relaySettingsKeyPackageTitle => 'Mes relais KeyPackage';

  @override
  String get relaySettingsKeyPackageSubtitle =>
      'Là où les autres trouvent les clés dont ils ont besoin pour vous inviter (kind 10002)';

  @override
  String get relaySettingsProfileTitle => 'Mes relais de profil';

  @override
  String get relaySettingsProfileSubtitle =>
      'Là où votre profil public est consulté et publié. Ces relais restent séparés de vos autres relais, et la liste de vos relais de profil n\'est jamais publiée (kind 0)';

  @override
  String get relaySettingsProfileUnderflowTitle =>
      'Consultation des profils suspendue';

  @override
  String get relaySettingsProfileUnderflowMessage =>
      'Il reste trop peu de relais de profil : les noms et les photos des membres ne seront plus mis à jour.';

  @override
  String get relaySettingsProfileUnderflowRestoreButton =>
      'Rétablir les relais de profil par défaut';

  @override
  String get relaySettingsLoadRelaysError => 'Échec du chargement des relais.';

  @override
  String get relaySettingsAddRelay => 'Ajouter un relais';

  @override
  String get relaySettingsRestoreDefaults => 'Rétablir les valeurs par défaut';

  @override
  String get relaySettingsAddRelayError => 'Échec de l\'ajout du relais.';

  @override
  String get relaySettingsRemoveRelayError =>
      'Échec de la suppression du relais.';

  @override
  String get relaySettingsRestoreTitle => 'Rétablir les relais par défaut ?';

  @override
  String relaySettingsRestoreBody(int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other:
          'Vos $countString relais actuels seront remplacés par les valeurs par défaut de Haven. Cette action est irréversible.',
      many:
          'Vos $countString relais actuels seront remplacés par les valeurs par défaut de Haven. Cette action est irréversible.',
      one:
          'Votre $countString relais actuel sera remplacé par les valeurs par défaut de Haven. Cette action est irréversible.',
    );
    return '$_temp0';
  }

  @override
  String get relaySettingsRestoreConfirm => 'Rétablir';

  @override
  String get relaySettingsRestoreSuccess => 'Valeurs par défaut rétablies.';

  @override
  String get relaySettingsRestoreError =>
      'Échec du rétablissement des valeurs par défaut.';

  @override
  String relaySettingsRemoveTooltip(String url) {
    return 'Supprimer $url';
  }

  @override
  String get relaySettingsStatusConnected => 'Connecté';

  @override
  String get relaySettingsStatusChecking => 'Vérification';

  @override
  String get relaySettingsStatusUnreachable => 'Injoignable';

  @override
  String get relaySettingsStatusNotChecked => 'Non vérifié';

  @override
  String relaySettingsStatusSemantics(String status) {
    return 'État du relais : $status';
  }

  @override
  String get relaySettingsEmptyTitle => 'Aucun relais configuré';

  @override
  String get relaySettingsEmptyMessage =>
      'Vous avez besoin d\'au moins un relais pour que les autres puissent vous joindre. Appuyez ci-dessous pour rétablir les valeurs par défaut de Haven.';

  @override
  String get relaySettingsProfileContaminationTooltip =>
      'Transporte aussi votre autre trafic Haven';

  @override
  String relaySettingsProfileContaminationSemantics(String url) {
    return 'Avertissement : $url transporte aussi votre autre trafic Haven ; ce relais pourrait donc associer votre profil à ce trafic';
  }

  @override
  String get locationSettingsTitle => 'Position';

  @override
  String get locationSettingsDisabledSnack =>
      'Partage en arrière-plan désactivé';

  @override
  String get locationSettingsEnabledSnack => 'Partage en arrière-plan activé';

  @override
  String get locationSettingsNotificationDeniedSnack =>
      'Le partage en arrière-plan nécessite une notification pour qu\'Android le maintienne actif. Il est désactivé pour le moment. Autorisez les notifications pour Haven afin de l\'activer.';

  @override
  String get locationSettingsBatteryOptSnack =>
      'Activé. L\'optimisation de la batterie peut interrompre le partage sur certains téléphones. Excluez Haven de l\'optimisation de la batterie pour le garder fiable.';

  @override
  String get locationSettingsBatteryOptNote =>
      'L\'optimisation de la batterie est encore active pour Haven. Certains téléphones s\'en servent pour interrompre le partage en arrière-plan sans prévenir. Excluez Haven pour que le partage reste fiable.';

  @override
  String get locationSettingsErrorSnack => 'Un problème est survenu';

  @override
  String get locationSettingsIntro =>
      'Haven partage votre position avec vos cercles tant que l\'application est ouverte. Activez cette option et vos cercles continueront de la voir pendant que Haven est en arrière-plan. Si le système ferme Haven, votre position n\'est plus partagée : Haven peut encore se réveiller pour récupérer les positions de vos cercles, mais jamais pour envoyer la vôtre. Sur Android, le partage se poursuit même si vous balayez Haven hors du sélecteur d\'applications, et il repart tout seul après un redémarrage du téléphone. Sur iPhone, le partage reste arrêté jusqu\'à ce que vous ouvriez Haven.';

  @override
  String get locationSettingsToggleTitle => 'Partager en arrière-plan';

  @override
  String get locationSettingsToggleSubtitle =>
      'Continuer le partage tant que Haven fonctionne en arrière-plan';

  @override
  String get locationSettingsIosLimitedNote =>
      'Le partage continue de fonctionner en arrière-plan avec votre autorisation actuelle, et iOS affiche alors sa barre bleue de localisation en haut de l\'écran. Choisissez « Toujours » pour Haven dans Réglages afin que Haven puisse aussi récupérer les positions de vos cercles après qu\'iOS a fermé l\'application. Avec « Toujours », iOS peut afficher sa flèche de localisation dans la barre d\'état à la place de cette barre bleue. Votre propre partage, lui, ne reprend que lorsque vous rouvrez Haven.';

  @override
  String get locationSettingsAndroidHeader =>
      'Réglages de l\'OS pour la fiabilité';

  @override
  String get locationSettingsAndroidNotification =>
      'Haven a besoin d\'une notification persistante pour qu\'Android maintienne le service d\'arrière-plan actif. Si vous avez refusé l\'autorisation de notification, ouvrez les Réglages et autorisez les notifications pour Haven.';

  @override
  String get locationSettingsAndroidBattery =>
      'Pour un partage en arrière-plan fiable, excluez aussi Haven de l\'optimisation de la batterie. Allez dans Réglages → Applications → Haven → Batterie → Autoriser en permanence.';

  @override
  String get locationSettingsAndroidVendors =>
      'Sur les appareils Samsung, retirez Haven des « Applications en veille » (Maintenance de l\'appareil → Batterie → Limites d\'utilisation en arrière-plan). Sur Xiaomi, activez le Démarrage automatique pour Haven.';

  @override
  String get locationSettingsIosGuidance =>
      'Tant que le partage en arrière-plan est activé, Haven maintient une session de localisation pour que vos cercles ne vous perdent pas de vue.';

  @override
  String get locationSettingsIosIndicatorArrow =>
      'iOS affiche sa flèche de localisation dans la barre d\'état pendant que Haven utilise votre position, et conserve ensuite cette même flèche à côté de Haven dans les réglages « Service de localisation » pendant un certain temps.';

  @override
  String get locationSettingsIosIndicatorBar =>
      'Avec votre autorisation « Toujours », iOS affiche sa barre bleue de localisation en haut de l\'écran pendant que Haven utilise votre position.';

  @override
  String get locationDisclosureTitle => 'Partage de votre position';

  @override
  String get locationDisclosureWhy =>
      'Haven montre votre position en temps réel aux personnes des cercles que vous choisissez, et vous montre la leur sur la carte. Pour cela, Haven a besoin de l\'autorisation d\'utiliser la position précise de votre appareil.';

  @override
  String get locationDisclosureHow =>
      'Votre position est chiffrée de bout en bout sur votre appareil, si bien que seuls les membres des cercles que vous choisissez peuvent la lire, et pas Haven. Haven n\'a pas de serveur à lui : vos mises à jour chiffrées passent par des relais indépendants gérés par d\'autres personnes. Ces relais voient votre adresse réseau, mais jamais où vous êtes. Pour dessiner la carte, Haven demande à Stadia Maps les zones autour de vous et de votre cercle. Stadia Maps apprend donc à peu près où cela se situe, mais jamais votre nom, votre clé, ni qui fait partie de vos cercles. Stadia Maps déclare ne pas vendre ni échanger de données personnelles, ne déposer aucun cookie sur votre appareil et conserver ses journaux de serveur environ deux semaines — sa propre politique, que Haven ne peut pas faire appliquer.';

  @override
  String get locationDisclosureSharing =>
      'Tant que Haven est ouvert et que vous faites partie d\'un cercle, votre position est envoyée automatiquement à quelques minutes d\'intervalle. Aucune pause n\'est possible. Pour cesser de partager avec un cercle, quittez-le.';

  @override
  String get locationDisclosureBackgroundAndroid =>
      'Cette application utilise les données de localisation pour permettre le partage avec vos cercles, même lorsque l\'application est fermée ou n\'est pas utilisée.';

  @override
  String get locationDisclosureBackgroundIos =>
      'Cette application utilise les données de localisation pour permettre le partage avec vos cercles, même lorsque Haven est en arrière-plan et que vous ne l\'utilisez pas. Si iOS ferme Haven, le partage s\'arrête jusqu\'à ce que vous rouvriez l\'application — Haven peut encore se réveiller pour récupérer les positions de vos cercles, mais jamais pour envoyer la vôtre.';

  @override
  String get locationDisclosureManage =>
      'Vous pouvez désactiver le partage en arrière-plan à tout moment dans Réglages → Position.';

  @override
  String get locationDisclosureAgree => 'Accepter';

  @override
  String get locationDisclosureNotNow => 'Pas maintenant';

  @override
  String get fgsNotificationSharing =>
      'Haven envoie et reçoit des mises à jour de position';

  @override
  String get fgsNotificationPaused =>
      'Haven est en pause — ouvrez l\'application pour reprendre le partage';

  @override
  String get fgsNotificationOpen => 'Haven est ouvert à l\'écran';

  @override
  String get fgsChannelName => 'Partage de position';

  @override
  String get fgsChannelDescription =>
      'Maintient le partage de votre position chiffrée en arrière-plan.';

  @override
  String get mapStyleTitle => 'Style de carte';

  @override
  String get mapStyleMinimalTitle => 'Minimal';

  @override
  String get mapStyleMinimalSubtitle =>
      'Une toile sobre et épurée qui suit votre thème clair ou sombre';

  @override
  String get mapStyleDetailedTitle => 'Détaillé';

  @override
  String get mapStyleDetailedSubtitle =>
      'Rues, étiquettes et lieux en couleurs';

  @override
  String get mapStyleOutdoorsTitle => 'Plein air';

  @override
  String get mapStyleOutdoorsSubtitle => 'Relief ombré avec sentiers et parcs';

  @override
  String get mapStylePreviewHeader => 'Aperçu';

  @override
  String get mapStylePreviewCity => 'Ville';

  @override
  String get mapStylePreviewNature => 'Nature';

  @override
  String mapStylePreviewSemantics(String scene, String style) {
    return 'Aperçu de la carte ($scene) : $style';
  }

  @override
  String get mapStylePreviewUnavailableSemantics =>
      'Aperçu de la carte indisponible dans cette version';

  @override
  String get mapStylePreviewUnavailableLabel =>
      'L\'aperçu en direct apparaît dans les versions de production';

  @override
  String get aboutTitle => 'À propos';

  @override
  String get aboutHeroName => 'Haven';

  @override
  String get aboutHeroTagline =>
      'Partage de position privé et résistant à la censure.';

  @override
  String get aboutLicensesTitle => 'Licences open source';

  @override
  String get aboutLicensesLegalese => '© 2026 Haven · MIT License';

  @override
  String get aboutReportMapIssue => 'Signaler un problème de carte';

  @override
  String get aboutSupportOsm => 'Soutenir OpenStreetMap';

  @override
  String get aboutMapAttribution =>
      '© Stadia Maps · © OpenMapTiles · © OpenStreetMap contributors\nDonnées cartographiques sous licence ODbL';

  @override
  String get aboutLinkOpenError => 'Impossible d\'ouvrir le lien';

  @override
  String get aboutFooterLicense => 'Distribué sous la licence MIT License';

  @override
  String aboutFooterVersion(String version) {
    return 'Version $version';
  }

  @override
  String get relaySettingsBackendCaption =>
      'Haven n\'a pas de serveur à lui. Vos mises à jour chiffrées passent par des serveurs indépendants appelés relais, qui ne peuvent lire ni votre position ni vos messages.';

  @override
  String get commonClearAll => 'Tout effacer';

  @override
  String commonMemberCount(int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$countString membres',
      many: '$countString membres',
      one: '$countString membre',
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
  String get circlesTitle => 'Cercles';

  @override
  String get circlesRefreshTooltip => 'Actualiser les cercles';

  @override
  String get circlesRequiresIdentity =>
      'La création d\'un cercle nécessite d\'abord la configuration d\'une identité';

  @override
  String get circlesCreateCta => 'Créer un cercle';

  @override
  String get circlesYourCircles => 'Vos cercles';

  @override
  String get circlesEmptyTitle => 'Aucun cercle pour l\'instant';

  @override
  String get circlesEmptyMessage =>
      'Créez un cercle pour commencer à partager votre position avec des amis et de la famille de confiance.';

  @override
  String get circlesSheetEmptyMessage =>
      'Créez un cercle pour commencer à partager votre position avec des contacts de confiance.';

  @override
  String get circlesLoadError => 'Impossible de charger les cercles';

  @override
  String get circlesSelectToView =>
      'Sélectionnez un cercle pour voir ses membres';

  @override
  String get circlesNoMembers => 'Aucun membre dans ce cercle';

  @override
  String get createCircleTitle => 'Ajouter des membres';

  @override
  String createCircleSelectedCount(int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    return 'Sélectionnés ($countString)';
  }

  @override
  String get createCircleEmptyTitle => 'Ajouter des membres au cercle';

  @override
  String get createCircleEmptyMessage =>
      'Recherchez par identifiant ou scannez leur code QR pour ajouter des membres.';

  @override
  String get createCircleNoValidMembers => 'Aucun membre valide à inviter';

  @override
  String get createCircleNoIdInQr =>
      'Aucun identifiant valide trouvé dans le code QR';

  @override
  String get createCircleNoAccountFound =>
      'Aucun compte Haven trouvé pour cet identifiant';

  @override
  String get createCircleCouldNotVerify => 'Impossible de vérifier le membre';

  @override
  String get createCircleSomethingWentWrong => 'Un problème est survenu';

  @override
  String get nameCircleTitle => 'Nommez votre cercle';

  @override
  String nameCircleMembersToInvite(int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$countString membres seront invités',
      many: '$countString membres seront invités',
      one: '$countString membre sera invité',
    );
    return '$_temp0';
  }

  @override
  String get nameCircleNameLabel => 'Nom du cercle';

  @override
  String get nameCircleNameHint => 'ex. : Famille, Amis proches';

  @override
  String get nameCircleNameEmptyError => 'Veuillez saisir un nom de cercle';

  @override
  String get nameCircleNameTooLongError =>
      'Le nom doit comporter au maximum 50 caractères';

  @override
  String get nameCircleSharingInfo =>
      'Tous les membres de ce cercle voient la position, le nom public et la photo des uns et des autres. Votre nom et votre photo sont publics sur le réseau Nostr, ils ne sont pas réservés à ce cercle. Ce cercle reste distinct de tous les autres dont vous faites partie : ses membres ne peuvent donc pas voir vos autres cercles ni qui s\'y trouve.';

  @override
  String get nameCircleCreateCta => 'Créer le cercle';

  @override
  String get nameCircleStageCreatingGroup => 'Création du groupe sécurisé...';

  @override
  String get nameCircleStageComplete => 'Terminé !';

  @override
  String nameCircleProgressSemantics(String stage) {
    return 'Progression de la création : $stage';
  }

  @override
  String nameCirclePercentComplete(int percent) {
    final intl.NumberFormat percentNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String percentString = percentNumberFormat.format(percent);

    return '$percentString pour cent terminé';
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
          'Cercle « $name » créé. Invitations envoyées jusqu\'à présent : $sentString sur $totalString. Haven continue d\'envoyer les autres tant que l\'application est ouverte, pendant une journée au plus.',
      many:
          'Cercle « $name » créé. Invitations envoyées jusqu\'à présent : $sentString sur $totalString. Haven continue d\'envoyer les autres tant que l\'application est ouverte, pendant une journée au plus.',
      one:
          'Cercle « $name » créé. Invitation envoyée jusqu\'à présent : $sentString sur $totalString. Haven continue de l\'envoyer tant que l\'application est ouverte, pendant une journée au plus.',
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
      other: 'Cercle « $name » créé ! $countString invitations envoyées.',
      many: 'Cercle « $name » créé ! $countString invitations envoyées.',
      one: 'Cercle « $name » créé ! $countString invitation envoyée.',
    );
    return '$_temp0';
  }

  @override
  String get nameCircleIdentityError =>
      'Erreur d\'identité. Veuillez vérifier la configuration de votre identité.';

  @override
  String get nameCircleCreateError =>
      'Échec de la création du cercle. Veuillez réessayer.';

  @override
  String nameCircleRosterFullError(int limit) {
    final intl.NumberFormat limitNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String limitString = limitNumberFormat.format(limit);

    return 'Vous ne pouvez faire partie que de $limitString cercles à la fois. Quittez un cercle pour en créer un nouveau.';
  }

  @override
  String get circleCreateRefusedNoLocationRelay =>
      'Haven ne peut pas créer ce cercle : tous les relais qu\'il utilise pour les cercles figurent, ou ont figuré, dans vos propres listes de relais, si bien qu\'aucun ne peut accueillir ce cercle.';

  @override
  String addMemberTitle(String circleName) {
    return 'Ajouter à $circleName';
  }

  @override
  String get addMemberInfo =>
      'Une fois l\'invitation acceptée, la personne verra la position de chacun à partir de ce moment-là, jamais rien de ce qui a été envoyé avant son arrivée. Elle verra aussi les clés publiques de toutes les personnes déjà présentes dans ce cercle.';

  @override
  String get addMemberAlreadyInCircle => 'Déjà dans ce cercle';

  @override
  String addMemberSendInvitation(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Envoyer les invitations',
      many: 'Envoyer les invitations',
      one: 'Envoyer l\'invitation',
    );
    return '$_temp0';
  }

  @override
  String addMemberSendingInvitation(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Envoi des invitations...',
      many: 'Envoi des invitations...',
      one: 'Envoi de l\'invitation...',
    );
    return '$_temp0';
  }

  @override
  String addMemberSentToCircle(int count, String circleName) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Invitations envoyées à $circleName',
      many: 'Invitations envoyées à $circleName',
      one: 'Invitation envoyée à $circleName',
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
          'Invitations à rejoindre $circleName envoyées jusqu\'à présent : $sentString sur $totalString. Haven continue d\'envoyer les autres tant que l\'application est ouverte, pendant une journée au plus.',
      many:
          'Invitations à rejoindre $circleName envoyées jusqu\'à présent : $sentString sur $totalString. Haven continue d\'envoyer les autres tant que l\'application est ouverte, pendant une journée au plus.',
      one:
          'Invitation à rejoindre $circleName envoyée jusqu\'à présent : $sentString sur $totalString. Haven continue de l\'envoyer tant que l\'application est ouverte, pendant une journée au plus.',
    );
    return '$_temp0';
  }

  @override
  String addMemberReinviteNeeded(String circleName) {
    return 'Haven ne peut pas envoyer l\'invitation à rejoindre $circleName. Retirez cette personne du cercle puis ajoutez-la à nouveau.';
  }

  @override
  String get memberCannotReceiveInvitations =>
      'Haven ne peut pas inviter toutes les personnes que vous avez choisies, car il n\'a pas trouvé où envoyer au moins une de leurs invitations. Demandez aux personnes choisies de vérifier que leur application peut recevoir des invitations, puis réessayez.';

  @override
  String get missedInvitationsShowWho => 'Voir les personnes';

  @override
  String missedInvitationsTitle(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Invitations non envoyées',
      many: 'Invitations non envoyées',
      one: 'Invitation non envoyée',
    );
    return '$_temp0';
  }

  @override
  String get addMemberError =>
      'Échec de l\'ajout du membre. Veuillez réessayer.';

  @override
  String get qrScannerTitle => 'Scanner un code QR';

  @override
  String get qrScannerToggleFlash => 'Activer/désactiver le flash';

  @override
  String get qrScannerSwitchCamera => 'Changer de caméra';

  @override
  String get qrScannerInstruction => 'Placez le code QR dans le cadre';

  @override
  String get qrScannerScanning => 'Analyse...';

  @override
  String get circleMemberNoRecentLocation => 'Aucune position récente';

  @override
  String get circleMemberRemoveTooltip => 'Retirer du cercle';

  @override
  String circleMemberRemoveDialogTitle(String name) {
    return 'Retirer $name ?';
  }

  @override
  String get circleMemberRemoveDialogBody =>
      'Cette personne cesse de pouvoir lire quoi que ce soit de nouveau dans ce cercle dès que le reste du cercle a suivi. Cela prend en général quelques minutes, et davantage pour les personnes qui étaient hors ligne à ce moment-là. Ce qu\'elle a déjà reçu reste sur son téléphone. Pour annuler ce retrait, il vous faudrait l\'inviter à nouveau.';

  @override
  String get circleMemberRemoveConfirm => 'Retirer';

  @override
  String circleMemberRemoveInProgress(String name) {
    return 'Retrait en cours : $name…';
  }

  @override
  String circleMemberRemoveSuccess(String name) {
    return '$name ne fait plus partie du cercle';
  }

  @override
  String circleMemberRemoveError(String name) {
    return 'Impossible de retirer $name. Rien n\'a changé : vérifiez votre connexion et réessayez.';
  }

  @override
  String circleMemberRemoveAwaitingAnnouncement(String name) {
    return 'Retrait toujours en cours : $name. Haven attend les relais. Tant que ce n\'est pas terminé, rien n\'est partagé avec ce cercle.';
  }

  @override
  String get circleMemberAdmin => 'Admin';

  @override
  String get circleMemberHintNoLocation => 'aucune position disponible';

  @override
  String get circleMemberHintMember => 'membre';

  @override
  String get circleMemberHintTapToCenter =>
      'appuyez pour centrer la carte sur sa position';

  @override
  String get pendingMemberRetryTooltip => 'Réessayer la validation';

  @override
  String get pendingMemberRemoveTooltip => 'Retirer de la liste';

  @override
  String get pendingMemberValidating => 'Validation en cours';

  @override
  String get pendingMemberValid => 'Valide';

  @override
  String get pendingMemberWarning => 'Avertissement';

  @override
  String get pendingMemberCheckingAvailability =>
      'Vérification de la disponibilité...';

  @override
  String get pendingMemberReadyToInvite => 'Prêt à inviter';

  @override
  String get pendingMemberNeedsUpdate => 'Doit mettre à jour ou ouvrir Haven';

  @override
  String get memberKeyPackageStale =>
      'Haven ne peut pas inviter cette personne pour le moment. Demandez-lui d\'ouvrir Haven, puis réessayez.';

  @override
  String get memberSearchHint => 'Saisissez l\'identifiant du membre...';

  @override
  String get memberSearchPasteTooltip => 'Coller depuis le presse-papiers';

  @override
  String get memberSearchAddTooltip => 'Ajouter un membre';

  @override
  String get memberSearchScanTooltip => 'Scanner un code QR';

  @override
  String get memberSearchHelper =>
      'Demandez à vos contacts leur code QR ou identifiant Haven';

  @override
  String get memberSearchNoValidId => 'Aucun identifiant Haven valide trouvé';

  @override
  String get memberSearchAlreadyAdded => 'Membre déjà ajouté';

  @override
  String get memberPickerSectionRoster => 'Membres de vos cercles';

  @override
  String get memberPickerTierRoster => 'Membre de vos cercles';

  @override
  String get memberPickerNoMatches => 'Aucun résultat dans vos cercles';

  @override
  String get memberPickerLoading => 'Chargement des membres de vos cercles';

  @override
  String get memberPickerDirectoryUnavailable =>
      'Pour le moment, impossible de charger la liste des membres de vos cercles';

  @override
  String memberPickerMatchesAnnouncement(int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    return 'Résultats : $countString';
  }

  @override
  String get memberPickerReasonSelf => 'C\'est votre propre identifiant';

  @override
  String get memberPickerReadPublicKey => 'Lire la clé publique à voix haute';

  @override
  String get memberPickerSectionRecent => 'Récemment dans vos cercles';

  @override
  String get memberPickerTierRecent => 'Récemment dans vos cercles';

  @override
  String get memberPickerNicknameNote =>
      'Votre surnom pour cette personne, pas son nom public';

  @override
  String memberPickerCollisionCircleLabel(String circleName) {
    return 'Cercle : $circleName';
  }

  @override
  String get memberPickerStrangerLookupNote =>
      'Haven a demandé à un relais le nom publié de cette personne. Ce relais peut voir que cet appareil vient de se renseigner sur cette clé, mais la demande ne porte aucune signature : elle n\'est donc pas associée à votre identité Haven. Aucune photo n\'a encore été téléchargée.';

  @override
  String selectedMembersMore(int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    return '+$countString de plus';
  }

  @override
  String get invitationCardHeading => 'Invitation à rejoindre un cercle';

  @override
  String invitationCardSemantics(String inviter) {
    return 'Invitation à rejoindre un cercle, envoyée par $inviter';
  }

  @override
  String invitationCardInvitedBySemantics(String inviter) {
    return 'Invitation envoyée par l\'identifiant cryptographique $inviter';
  }

  @override
  String invitationCardInvitedBy(String inviter) {
    return 'Envoyée par : $inviter';
  }

  @override
  String get invitationCardNicknameNote =>
      'Votre surnom pour cette personne, pas son nom public';

  @override
  String get invitationCardJustNow => 'À l\'instant';

  @override
  String invitationCardDaysAgo(int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    return 'il y a $countString j';
  }

  @override
  String invitationCardHoursAgo(int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    return 'il y a $countString h';
  }

  @override
  String invitationCardMinutesAgo(int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    return 'il y a $countString min';
  }

  @override
  String get invitationCardDecline => 'Refuser';

  @override
  String get invitationCardAccept => 'Accepter';

  @override
  String get invitationAcceptedSnack => 'Invitation acceptée';

  @override
  String get invitationDeclinedSnack => 'Invitation refusée';

  @override
  String get invitationAcceptError =>
      'Échec de l\'acceptation de l\'invitation. Veuillez réessayer.';

  @override
  String invitationNeedsNewInviteError(String name) {
    return 'Cette invitation ne peut plus être utilisée. Demandez à $name de vous inviter à nouveau. Cette personne devra peut-être d\'abord mettre à jour Haven.';
  }

  @override
  String get rejoinDialogTitle => 'Rejoindre à nouveau ce cercle ?';

  @override
  String rejoinDialogBody(String inviterName, String circleName) {
    return '$inviterName vous invite à rejoindre « $circleName », qui est déjà sur ce téléphone. Cela peut arriver après un retrait du cercle suivi d\'une nouvelle invitation. Le rejoindre à nouveau remplace la copie du cercle sur ce téléphone. « Refuser » met définitivement fin à cette invitation ; « Annuler » la conserve pour plus tard.';
  }

  @override
  String rejoinDialogBodyUnnamed(String circleName) {
    return 'Vous avez reçu une invitation à rejoindre « $circleName », qui est déjà sur ce téléphone. Cela peut arriver après un retrait du cercle suivi d\'une nouvelle invitation. Le rejoindre à nouveau remplace la copie du cercle sur ce téléphone. « Refuser » met définitivement fin à cette invitation ; « Annuler » la conserve pour plus tard.';
  }

  @override
  String get rejoinDialogConfirm => 'Rejoindre à nouveau';

  @override
  String invitationRosterFullError(int limit) {
    final intl.NumberFormat limitNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String limitString = limitNumberFormat.format(limit);

    return 'Vous ne pouvez faire partie que de $limitString cercles à la fois. Cette invitation reste en attente. Quittez un cercle, puis acceptez-la.';
  }

  @override
  String get invitationDeclineError =>
      'Échec du refus de l\'invitation. Veuillez réessayer.';

  @override
  String get circleSelectorLabel => 'Sélecteur de cercle';

  @override
  String get circleSelectorPlaceholder => 'Sélectionnez un cercle';

  @override
  String get circleSelectorNewCircle => 'Nouveau cercle';

  @override
  String get circleSelectorLoadError => 'Échec du chargement des cercles';

  @override
  String get circleSelectorExpandedAnnouncement =>
      'Liste des cercles développée';

  @override
  String get circleSelectorCollapsedAnnouncement => 'Liste des cercles réduite';

  @override
  String get circleDetailsButtonTooltip => 'Détails du cercle';

  @override
  String get circleDetailsTitle => 'Détails du cercle';

  @override
  String circleDetailsMembersWithEpoch(String members, int epoch) {
    final intl.NumberFormat epochNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String epochString = epochNumberFormat.format(epoch);

    return '$members · époque $epochString';
  }

  @override
  String circleDetailsMetaWithExpiry(String meta, String expiry) {
    return '$meta · expiration $expiry';
  }

  @override
  String circleDetailsExpiryMinutesShort(int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$countString min',
      many: '$countString min',
      one: '$countString min',
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
      other: '$countString s',
      many: '$countString s',
      one: '$countString s',
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
      other: 'environ $countString minutes',
      many: 'environ $countString minutes',
      one: 'environ $countString minute',
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
      other: '$countString secondes',
      many: '$countString secondes',
      one: '$countString seconde',
    );
    return '$_temp0';
  }

  @override
  String circleDetailsExpirySemantics(String meta, String expiry) {
    return '$meta. Haven demande aux relais de supprimer, après $expiry, les messages de position que vous envoyez à ce cercle.';
  }

  @override
  String get circleDetailsRelaysHeading => 'Relais de ce cercle';

  @override
  String get circleDetailsNoRelays => '(aucun enregistré)';

  @override
  String get circleDetailsRelaysNote =>
      'Les mises à jour chiffrées de ce cercle passent par ces relais. Ils ont été fixés à la création du cercle et ne sont pas encore modifiables dans Haven ; les modifications de votre liste de relais n\'ont aucun effet sur eux.';

  @override
  String get circleDetailsAddMember => 'Ajouter un membre';

  @override
  String get circleDetailsLeaveCircle => 'Quitter le cercle';

  @override
  String get circleDetailsLeavingInProgress => 'Sortie du cercle en cours…';

  @override
  String get leaveCircleDialogTitle => 'Quitter le cercle';

  @override
  String get leaveCircleDialogBody =>
      'Quitter ce cercle ? Vous cesserez d\'envoyer votre position à ses membres et de voir la leur. La dernière position que vous avez envoyée reste sur leurs téléphones pendant une journée au plus. C\'est irréversible : il vous faudrait une nouvelle invitation pour revenir.';

  @override
  String get leaveDisbandedCircleDialogBody =>
      'Ce cercle a pris fin : plus rien n\'y est partagé. Le quitter le supprime de ce téléphone.';

  @override
  String get leaveCircleDialogAdminNote =>
      'Vous êtes Admin de ce cercle. Avant votre départ, Haven tente de nommer Admin un autre membre, pour que le cercle puisse continuer de fonctionner.';

  @override
  String get leaveCircleConfirm => 'Quitter';

  @override
  String get leaveCircleIdentityUnavailable => 'Identité indisponible';

  @override
  String get leaveCircleSuccess => 'Cercle quitté avec succès';

  @override
  String get leaveCircleError => 'Échec de la sortie du cercle';

  @override
  String get legacyCircleRecreateCta => 'Recréer le cercle';

  @override
  String get storageResetTitle => 'Haven a été mis à jour';

  @override
  String get storageResetKept =>
      'Votre identité n\'a pas changé, et le profil public que vous avez déjà publié reste tel quel.';

  @override
  String get storageResetLost =>
      'Pour le passage au nouveau moteur de chiffrement de Haven, les cercles créés avant cette mise à jour ont été supprimés. Recréez-les et invitez à nouveau leurs membres. Les surnoms que vous aviez donnés à d\'autres personnes avant cette mise à jour ont également été supprimés, ainsi que toute modification de profil dont l\'enregistrement n\'était pas encore terminé à ce moment-là.';

  @override
  String get storageResetRelays =>
      'Cette mise à jour a réinitialisé vos paramètres de relais aux valeurs par défaut de Haven. Ils ne seront pas publiés avant que vous continuiez ou reveniez des Paramètres de relais : vous pouvez donc d\'abord ajouter vos propres relais.';

  @override
  String get storageResetContinue => 'Continuer';

  @override
  String get storageResetOpenRelaySettings => 'Paramètres de relais';

  @override
  String get storageResetAcknowledgeFailed =>
      'Haven n\'a pas pu enregistrer votre réponse. Tant qu\'elle n\'est pas enregistrée, Haven ne publiera ni vos paramètres de relais ni votre clé d\'invitation : personne ne peut donc encore vous inviter. Réessayez, sinon Haven vous la redemandera à sa prochaine ouverture.';

  @override
  String get circlesPanelCollapsedAnnouncement => 'Panneau des cercles réduit';

  @override
  String get circlesPanelExpandedAnnouncement =>
      'Panneau des cercles développé';

  @override
  String get circlesPanelSlightlyOpenAnnouncement =>
      'Panneau des cercles légèrement ouvert';

  @override
  String get circlesPanelHalfOpenAnnouncement =>
      'Panneau des cercles à moitié ouvert';

  @override
  String get circleMemberAnnouncementSelf => 'vous';

  @override
  String get circleMemberAnnouncementFallback => 'membre';

  @override
  String get invitationsRefreshTooltip => 'Actualiser les invitations';

  @override
  String get invitationsLoadError => 'Impossible de charger les invitations';

  @override
  String get invitationsEmptyTitle => 'Aucune invitation';

  @override
  String get invitationsEmptyMessage =>
      'Lorsque quelqu\'un vous invite à un cercle, cela apparaît ici.';

  @override
  String get refreshRingSemanticNoInbox =>
      'Aucune boîte de réception configurée, ouvre les paramètres de relais';

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
      other: '$checkedString relais sur $totalString vérifiés',
      many: '$checkedString relais sur $totalString vérifiés',
      one: '$checkedString relais sur 1 vérifié',
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
      other: 'Les $totalString relais ont répondu',
      many: 'Les $totalString relais ont répondu',
      one: 'Le relais a répondu',
    );
    return '$_temp0';
  }

  @override
  String get refreshRingSemanticAllError => 'Aucun relais n\'a répondu';

  @override
  String refreshRingSemanticPartial(int ok, int total) {
    final intl.NumberFormat okNumberFormat = intl.NumberFormat.decimalPattern(
      localeName,
    );
    final String okString = okNumberFormat.format(ok);
    final intl.NumberFormat totalNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String totalString = totalNumberFormat.format(total);

    return '$okString relais sur $totalString ont répondu';
  }

  @override
  String get refreshRingAnnouncementChecking => 'Vérification des relais';

  @override
  String get refreshRingAnnouncementAllOk => 'Tous les relais ont répondu';

  @override
  String refreshRingAnnouncementPartial(int ok, int total) {
    final intl.NumberFormat okNumberFormat = intl.NumberFormat.decimalPattern(
      localeName,
    );
    final String okString = okNumberFormat.format(ok);
    final intl.NumberFormat totalNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String totalString = totalNumberFormat.format(total);

    return '$okString relais sur $totalString ont répondu';
  }

  @override
  String get refreshRingAnnouncementAllError =>
      'Aucun relais n\'a pu être contacté';

  @override
  String get refreshRingAnnouncementNoInbox =>
      'Aucune boîte de réception configurée';

  @override
  String refreshRingSemanticAllFound(int total) {
    final intl.NumberFormat totalNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String totalString = totalNumberFormat.format(total);

    String _temp0 = intl.Intl.pluralLogic(
      total,
      locale: localeName,
      other: 'Les $totalString relais ont vos données',
      many: 'Les $totalString relais ont vos données',
      one: 'Le relais a vos données',
    );
    return '$_temp0';
  }

  @override
  String get refreshRingSemanticNoneFound => 'Aucun relais n\'a vos données';

  @override
  String refreshRingSemanticPartialFound(int ok, int total) {
    final intl.NumberFormat okNumberFormat = intl.NumberFormat.decimalPattern(
      localeName,
    );
    final String okString = okNumberFormat.format(ok);
    final intl.NumberFormat totalNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String totalString = totalNumberFormat.format(total);

    return '$okString relais sur $totalString ont vos données';
  }

  @override
  String get refreshRingAnnouncementAllFound =>
      'Tous les relais ont vos données';

  @override
  String refreshRingAnnouncementPartialFound(int ok, int total) {
    final intl.NumberFormat okNumberFormat = intl.NumberFormat.decimalPattern(
      localeName,
    );
    final String okString = okNumberFormat.format(ok);
    final intl.NumberFormat totalNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String totalString = totalNumberFormat.format(total);

    return '$okString relais sur $totalString ont vos données';
  }

  @override
  String get refreshRingAnnouncementNoneFound =>
      'Aucun relais n\'a vos données';

  @override
  String get identityTitle => 'Identité';

  @override
  String get identityLoadError =>
      'Un problème est survenu lors du chargement de votre identité. Veuillez réessayer.';

  @override
  String get identityMissingTitle => 'Aucune identité';

  @override
  String get identityMissingMessage =>
      'Votre identité a disparu. Configurez-en une nouvelle pour continuer à utiliser Haven.';

  @override
  String get identitySetUpCta => 'Configurer l\'identité';

  @override
  String get identityPublicKeyQrTitle => 'QR de la clé publique';

  @override
  String get identityPublicKeyQrSubtitle =>
      'Comment les autres vous invitent à des cercles';

  @override
  String get identityAdvancedTitle => 'Avancé';

  @override
  String get identityAdvancedSubtitle =>
      'Clé publique, clé secrète, suppression';

  @override
  String get profileIsPublicNoticeTitle => 'Votre profil est public';

  @override
  String get profileIsPublicNoticeBody =>
      'Votre nom d\'affichage et votre photo sont visibles par tous sur le réseau Nostr, pas seulement par les membres de vos cercles. Ne partagez que ce que vous êtes à l\'aise de rendre public.';

  @override
  String get identityRefreshProfileTooltip => 'Actualiser le profil public';

  @override
  String get identityAdvancedExportError =>
      'Échec de l\'exportation de la clé secrète. Veuillez réessayer.';

  @override
  String get identityAdvancedDeleteTitle => 'Supprimer l\'identité ?';

  @override
  String get identityAdvancedDeleteBody =>
      'Cela supprime votre identité et toutes les données de vos cercles de ce téléphone. Tout ce qui a déjà été publié sous cette identité reste là où cela se trouve : votre nom et vos clés sur les relais qui les détiennent, votre photo sur l\'hébergeur d\'images qui la stocke. Assurez-vous d\'avoir sauvegardé votre clé secrète si vous souhaitez pouvoir récupérer cette identité.';

  @override
  String get identityAdvancedDeleteConfirm => 'Supprimer';

  @override
  String get identityAdvancedDeletedSnack => 'Identité supprimée';

  @override
  String get identityAdvancedDeleteError =>
      'Échec de la suppression de l\'identité. Veuillez réessayer.';

  @override
  String get identityAdvancedDeletingProgress =>
      'Suppression de votre identité…';

  @override
  String identityAdvancedCopiedToClipboard(String label) {
    return '$label copié dans le presse-papiers';
  }

  @override
  String get identityAdvancedSecretCopiedWarning =>
      'Clé secrète copiée. Attention : d\'autres applications peuvent lire votre presse-papiers. Collez-la dans un endroit sûr et effacez votre presse-papiers.';

  @override
  String get identityAdvancedMissingBody =>
      'Aucune identité n\'est configurée.';

  @override
  String get identityAdvancedPublicKeyLabel => 'Clé publique';

  @override
  String get identityAdvancedPublicKeyHexLabel => 'Clé publique (hex)';

  @override
  String get identityAdvancedCopyValue => 'Clé publique';

  @override
  String get identityAdvancedCopyPublicKeyTooltip => 'Copier la clé publique';

  @override
  String get identityAdvancedCopyHexTooltip => 'Copier le hex';

  @override
  String get identityAdvancedSecretKeyTitle => 'Clé secrète';

  @override
  String get identityAdvancedSecretKeyWarning =>
      'Votre clé secrète donne un accès complet à votre identité. Ne la partagez jamais avec qui que ce soit.';

  @override
  String get identityAdvancedRevealSecretKey => 'Révéler la clé secrète';

  @override
  String get identityAdvancedHideSecretKey => 'Masquer la clé secrète';

  @override
  String get identityAdvancedCopySecretKeyTooltip => 'Copier la clé secrète';

  @override
  String get identityAdvancedDeleteIdentityCta => 'Supprimer l\'identité';

  @override
  String get qrCodeLoadError =>
      'Un problème est survenu lors du chargement de votre clé publique. Veuillez réessayer.';

  @override
  String get qrCodeYourPublicKeyLabel => 'Votre clé publique';

  @override
  String get qrCodeWhatIsThisTitle => 'Qu\'est-ce que c\'est ?';

  @override
  String get qrCodeExplainerKeys =>
      'Haven repose sur Nostr, un réseau ouvert sans compte d\'entreprise ni inscription. Votre identité n\'est qu\'une paire de clés : une clé secrète que vous seul détenez, et cette clé publique qui en est dérivée.';

  @override
  String get qrCodeExplainerUsername =>
      'Votre clé publique fonctionne comme un nom d\'utilisateur qu\'il est sûr de partager. Les gens scannent ce code, ou collent votre clé publique, pour vous inviter à un cercle. La partager ne peut pas révéler où vous êtes. Votre nom d\'affichage et votre photo sont déjà publics : cela n\'ajoute donc rien.';

  @override
  String get displayNameCardTitle => 'Nom d\'affichage';

  @override
  String get displayNameCardLoadError =>
      'Impossible de charger votre nom d\'affichage. Réessayez plus tard.';

  @override
  String get displayNameCardHint => 'Saisissez votre nom d\'affichage';

  @override
  String get displayNameCardSavedLabel => 'Nom d\'affichage enregistré';

  @override
  String get displayNameCardSaveLabel => 'Enregistrer le nom d\'affichage';

  @override
  String get displayNameCardSavingLabel => 'Enregistrement du nom d\'affichage';

  @override
  String get displayNameCardRetryLabel =>
      'Échec de l\'enregistrement. Réessayer';

  @override
  String get displayNameCardSavedAnnouncement => 'Nom d\'affichage enregistré';

  @override
  String get displayNameCardSaveFailedAnnouncement =>
      'Échec de l\'enregistrement, réessayez';

  @override
  String get profileSyncStatusSyncing =>
      'Synchronisation de votre profil public…';

  @override
  String get profileSyncStatusPartial =>
      'Publié — synchronisation en cours avec certains relais';

  @override
  String get profileSyncStatusSynced => 'Profil public à jour';

  @override
  String get profileSyncStatusFailed =>
      'Synchronisation impossible pour le moment.';

  @override
  String get profileSyncStatusRetrySemantics =>
      'Réessayer de publier votre profil';

  @override
  String get npubQrCopiedSnack => 'Clé publique copiée dans le presse-papiers';

  @override
  String get npubQrCopyButton => 'Copier la clé publique';

  @override
  String get circleMemberPublicKeyCopied =>
      'Clé publique copiée dans le presse-papiers';

  @override
  String get circleMemberCopyPublicKeyHint => 'Copier la clé publique';

  @override
  String get circleMemberSetNicknameMenuItem => 'Définir un surnom';

  @override
  String get circleMemberCopyPublicKeyMenuItem => 'Copier la clé publique';

  @override
  String get memberProfileRefreshErrorGeneric =>
      'Impossible d\'actualiser les profils. Veuillez réessayer.';

  @override
  String get memberDetailSheetTitle => 'Détails du membre';

  @override
  String get memberNicknameSheetHint => 'Saisissez un surnom';

  @override
  String get memberNicknameSheetLabel => 'Surnom';

  @override
  String get memberNicknameSheetSave => 'Enregistrer le surnom';

  @override
  String get memberNicknameSheetClear => 'Effacer le surnom';

  @override
  String get memberNicknameSheetSavedAnnouncement => 'Surnom enregistré';

  @override
  String get memberNicknameSheetClearedAnnouncement => 'Surnom effacé';

  @override
  String get npubQrScanLabel => 'Scannez pour m\'ajouter';

  @override
  String get npubQrSemanticsLabel => 'Code QR de votre identité publique';

  @override
  String get photoHeaderRemoveTitle => 'Supprimer la photo de profil ?';

  @override
  String get photoHeaderRemoveBody =>
      'Cela retire votre photo de votre profil public. Le fichier image reste sur le serveur qui l\'héberge, et les copies que d\'autres ont déjà téléchargées restent chez elles.';

  @override
  String get photoHeaderEditPhoto => 'Modifier la photo';

  @override
  String get photoHeaderRemove => 'Supprimer';

  @override
  String get photoHeaderViewPhotoSemantics => 'Voir la photo de profil';

  @override
  String get photoHeaderAddPhotoSemantics => 'Ajouter une photo de profil';

  @override
  String get photoHeaderChangePhotoSemantics => 'Changer la photo de profil';

  @override
  String get avatarPickerPhotoUpdated =>
      'Photo mise à jour. Elle sera publiée sur votre profil Nostr public.';

  @override
  String get avatarPickerPhotoRemoved => 'Photo supprimée.';

  @override
  String get avatarPickerRemoveError =>
      'Impossible de supprimer votre photo. Veuillez réessayer.';

  @override
  String get avatarPickerUpdateError =>
      'Impossible de mettre à jour votre photo. Veuillez réessayer.';

  @override
  String get avatarPickerCropTitle => 'Recadrer la photo';

  @override
  String get avatarPickerCropDone => 'Terminé';

  @override
  String get avatarPickerCropCancel => 'Annuler';

  @override
  String get avatarFullscreenClose => 'Fermer';

  @override
  String get avatarFullscreenSemantics => 'Photo de profil, plein écran';

  @override
  String get avatarFullscreenLoadError => 'Impossible de charger la photo';

  @override
  String get mapInitializing => 'Initialisation...';

  @override
  String get mapInitFailedTitle => 'Échec de l\'initialisation';

  @override
  String get mapInitFailedMessage =>
      'Échec de l\'initialisation des services de localisation.';

  @override
  String get mapInitFailedRetry =>
      'Échec de l\'initialisation. Veuillez réessayer.';

  @override
  String get mapLocationOffMessage =>
      'Activez la localisation pour vous voir, vous et vos cercles, sur la carte.';

  @override
  String get mapGettingLocation => 'Obtention de la position...';

  @override
  String get mapLoadingMap => 'Chargement de la carte...';

  @override
  String get mapLocationOffTitle => 'La localisation est désactivée';

  @override
  String get mapLocationErrorTitle => 'Erreur de localisation';

  @override
  String get mapLocationUnavailable => 'Position temporairement indisponible';

  @override
  String get mapLocationNoPermissionTitle =>
      'Haven n\'a pas accès à votre position';

  @override
  String get mapLocationSharingStoppedServiceOff =>
      'La localisation est désactivée sur cet appareil : Haven a donc cessé de partager votre position avec vos cercles. Réactivez la localisation pour reprendre le partage.';

  @override
  String get mapLocationSharingStoppedPermission =>
      'Haven n\'a plus l\'autorisation d\'utiliser votre position : le partage s\'est donc arrêté. Accordez de nouveau cette autorisation pour reprendre le partage.';

  @override
  String get mapLocationSharingStoppedPermissionSettings =>
      'L\'accès à votre position est désactivé pour Haven : le partage s\'est donc arrêté. Réactivez cet accès dans les réglages du système pour reprendre le partage.';

  @override
  String get mapLocationSharingStoppedBoth =>
      'Haven a cessé de partager votre position. Réactivez la localisation sur cet appareil, puis autorisez Haven à l\'utiliser.';

  @override
  String get mapLocationSharingStoppedUnknown =>
      'Haven ne reçoit plus votre position : le partage s\'est donc arrêté. Vérifiez que la localisation est activée et que Haven est autorisé à l\'utiliser.';

  @override
  String get mapLocationAccessRestoredAnnouncement =>
      'L\'accès à la localisation est rétabli. Haven partage à nouveau votre position.';

  @override
  String get clockSkewTitle => 'L\'horloge de ce téléphone est déréglée';

  @override
  String get clockSkewBodyRejected =>
      'Vos cercles ne reçoivent pas votre position : les relais refusent l\'heure que ce téléphone y inscrit. Activez la date et l\'heure automatiques dans les réglages du système pour y remédier.';

  @override
  String get clockSkewBodyBehind =>
      'Ce téléphone retarde sur le reste de vos cercles : les positions qu\'il envoie expirent donc trop tôt, et vos cercles peuvent en manquer une partie, voire la totalité. Activez la date et l\'heure automatiques dans les réglages du système pour y remédier.';

  @override
  String get clockSkewResolvedAnnouncement =>
      'Le problème d\'horloge est résolu. Haven partage à nouveau votre position.';

  @override
  String get clockSkewTitleDisagreement =>
      'Une horloge est déréglée dans l\'un de vos cercles';

  @override
  String get clockSkewBodyDisagreement =>
      'L\'horloge de ce téléphone et celle d\'un autre membre diffèrent d\'au moins deux minutes. Si c\'est celle de ce téléphone qui est déréglée, les positions qu\'il envoie risquent d\'expirer avant que quiconque puisse les voir. Activez la date et l\'heure automatiques dans les réglages du système pour vous assurer que ce n\'est pas celle de ce téléphone qui est en cause.';

  @override
  String get clockSkewDisagreementResolvedAnnouncement =>
      'L\'avertissement d\'horloge a disparu.';

  @override
  String get sharingHealthTitleStopped =>
      'Le partage de position s\'est arrêté';

  @override
  String get sharingHealthTitleNotSending =>
      'Votre position n\'est plus partagée';

  @override
  String get sharingHealthTitleNotReceiving =>
      'Vous ne recevez plus de positions';

  @override
  String sharingHealthNoUpdatesMinutes(int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Aucune mise à jour depuis environ $countString minutes',
      many: 'Aucune mise à jour depuis environ $countString minutes',
      one: 'Aucune mise à jour depuis environ $countString minute',
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
      other: 'Aucune mise à jour depuis environ $countString heures',
      many: 'Aucune mise à jour depuis environ $countString heures',
      one: 'Aucune mise à jour depuis environ $countString heure',
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
      other: 'Aucune mise à jour depuis environ $countString jours',
      many: 'Aucune mise à jour depuis environ $countString jours',
      one: 'Aucune mise à jour depuis environ $countString jour',
    );
    return '$_temp0';
  }

  @override
  String get sharingHealthRepairAction => 'Réparer';

  @override
  String get sharingHealthRepairSent =>
      'Réparation envoyée. Les autres suivront dès que leur téléphone l\'aura reçue.';

  @override
  String get sharingHealthRepairNothingToDo =>
      'Rien à réparer pour le moment. Haven continuera d\'essayer.';

  @override
  String get sharingHealthRepairUnresolvedAnnouncement =>
      'Le partage de position ne fonctionne toujours pas.';

  @override
  String get sharingHealthResumedAnnouncement =>
      'Le partage de position fonctionne à nouveau.';

  @override
  String get sharingHealthTitleQuarantined =>
      'Haven ne peut pas ouvrir ce cercle pour le moment';

  @override
  String get sharingHealthBodyQuarantined =>
      'Un problème est survenu lors du chargement de ce cercle sur ce téléphone. Le cercle est toujours là.';

  @override
  String get sharingHealthTitleDisbanded => 'Ce cercle a pris fin';

  @override
  String get sharingHealthBodyDisbanded =>
      'Un Admin a mis fin à ce cercle : plus rien n\'y est partagé. Quittez-le pour le supprimer de ce téléphone.';

  @override
  String get sharingHealthQuarantineRetryHint =>
      'Tente de charger à nouveau ce cercle';

  @override
  String get sharingHealthQuarantineRetryFailedAnnouncement =>
      'Haven ne peut toujours pas ouvrir ce cercle.';

  @override
  String get sharingHealthTitleUnrecoverable =>
      'Ce cercle a cessé de fonctionner sur ce téléphone';

  @override
  String get sharingHealthBodyUnrecoverable =>
      'Haven ne peut plus envoyer ni recevoir de mises à jour dans ce cercle sur ce téléphone. Demandez à l\'un de ses Admins de vous retirer, puis de vous ajouter à nouveau. Si personne ne le peut, créez un nouveau cercle avec les mêmes personnes.';

  @override
  String get sharingHealthTitleStalled =>
      'Haven ne peut pas lire les mises à jour de ce cercle';

  @override
  String get sharingHealthBodyStalled =>
      'Ce téléphone semble avoir manqué une modification du cercle et n\'a pas pu la trouver sur les relais. Demandez à l\'un de ses Admins de vous retirer, puis de vous ajouter à nouveau. Si personne ne le peut, créez un nouveau cercle avec les mêmes personnes.';

  @override
  String get sharingHealthTitlePaused => 'Haven a mis ce cercle en pause';

  @override
  String get sharingHealthBodyCollision =>
      'Haven a détecté un problème avec ce cercle sur ce téléphone et a cessé de partager avec lui pour que votre position reste privée. Quitter le cercle est le seul moyen d\'y remédier. Pour le rejoindre à nouveau, il vous faudra une nouvelle invitation.';

  @override
  String get sharingHealthBodyCannotCheck =>
      'Haven n\'a pas pu vérifier ce cercle sur ce téléphone et a donc suspendu le partage avec lui pour que votre position reste privée. Haven refera cette vérification de lui-même.';

  @override
  String get sharingHealthTitleLeaving => 'Vous quittez ce cercle';

  @override
  String get sharingHealthBodyLeaving =>
      'Rien n\'est partagé avec ce cercle pendant que Haven finit de le quitter. Cela peut prendre environ une journée. Une fois le départ terminé, le cercle disparaît de ce téléphone.';

  @override
  String get sharingHealthBodyRemovalUnmade =>
      'Un retrait que vous avez demandé n\'a pas été effectué. Haven a donc suspendu le partage de votre position avec ce cercle, afin qu\'aucune personne que vous avez tenté de retirer ne puisse la voir.';

  @override
  String get sharingHealthBodyRemovalUnmadeNoNotice =>
      'Un retrait que vous avez demandé n\'a pas été effectué. Haven a donc suspendu le partage de votre position avec ce cercle, afin qu\'aucune personne que vous avez tenté de retirer ne puisse la voir. Ouvrez la liste des membres pour voir qui fait encore partie du cercle.';

  @override
  String get sharingHealthBodyDepartureDue =>
      'Quelqu\'un a quitté ce cercle et son départ n\'a pas été finalisé. Tant que ce n\'est pas fait, Haven ne partage pas votre position avec ce cercle.';

  @override
  String get sharingHealthTitleBackgroundPaused =>
      'Le partage en arrière-plan est en pause pour ce cercle';

  @override
  String get sharingHealthBodyAwaitsForeground =>
      'Les relais de ce cercle ont changé pendant que Haven était en arrière-plan. Haven termine ce changement lorsque l\'application est ouverte ; d\'ici là, rien n\'est partagé avec ce cercle en arrière-plan.';

  @override
  String get sharingHealthBodyAwaitingRelays =>
      'Une modification de ce cercle attend la confirmation d\'un relais. En attendant, Haven n\'envoie pas votre position à ce cercle et n\'affiche pas les nouvelles positions qui en proviennent. Haven continue d\'essayer tant que l\'application est ouverte.';

  @override
  String get sharingHealthBodyAcknowledged =>
      'Un relais a accepté une modification de ce cercle et Haven est en train de la finaliser. D\'ici là, les mises à jour de ce cercle restent en attente.';

  @override
  String get sharingHealthBodyStagedWithoutRecord =>
      'Une modification de ce cercle n\'a pas pu être enregistrée : elle n\'a donc pas été envoyée. Haven règle la situation, au plus tard à son prochain démarrage ; d\'ici là, les mises à jour de ce cercle restent en attente.';

  @override
  String get sharingHealthBodyStoredInput =>
      'Ce téléphone a des mises à jour pour ce cercle qu\'il n\'a pas pu traiter jusqu\'à présent. Tant que ce n\'est pas fait, Haven ne partage pas votre position avec ce cercle.';

  @override
  String get sharingHealthBodySessionHeld =>
      'Haven est encore en train de fermer sa dernière connexion : le partage de position est donc en pause. Le partage reprend dès que c\'est terminé. Redémarrer votre téléphone résout toujours ce blocage.';

  @override
  String get sharingHealthRepairHintAnyMember =>
      'Se reconnecte aux relais, réessaie d\'envoyer votre position et peut donner à ce cercle de nouvelles clés de chiffrement';

  @override
  String get sharingHealthAttentionAnnouncement =>
      'Le partage de position demande votre attention dans ce cercle. Ouvrez « Détails du cercle » pour savoir pourquoi.';

  @override
  String changeNoticeArrivedAnnouncement(String circleName) {
    return 'Une information concernant des modifications récentes du cercle $circleName demande votre attention. Ouvrez les détails de ce cercle pour la lire.';
  }

  @override
  String get circleDetailsAttentionTooltip =>
      'Détails du cercle, attention requise';

  @override
  String circleRowAttentionSemantics(String circleName) {
    return '$circleName, attention requise';
  }

  @override
  String get changeNoticeHeading => 'Modifications de ce cercle';

  @override
  String get changeNoteRemovalUndone =>
      'Une modification de ce cercle n\'a pas abouti. Si elle retirait quelqu\'un, toute personne concernée fait toujours partie du cercle et peut voir ce qui y est partagé.';

  @override
  String get changeNoteChangeUndone =>
      'Une modification de ce cercle n\'a pas abouti : rien n\'a donc changé. Si elle venait de vous, refaites-la si vous le souhaitez toujours.';

  @override
  String get changeNoteMayBeOutOfStep =>
      'Une modification de ce cercle est peut-être parvenue aux autres membres sans que ce téléphone le sache : il n\'est donc peut-être plus en phase avec le reste du cercle.';

  @override
  String get changeNoteReinviteOwed =>
      'Une personne que vous avez invitée apparaît parmi les membres de ce cercle mais ne peut pas le rejoindre, car Haven ne peut pas envoyer son invitation. Retirez-la du cercle puis ajoutez-la à nouveau.';

  @override
  String get changeNoteChangeUnrecorded =>
      'Une modification de ce cercle n\'a pas pu être enregistrée : elle n\'a donc pas été envoyée.';

  @override
  String get changeNoteQueuedChangeDropped =>
      'Une modification en attente dans ce cercle a été annulée, car elle ne pouvait plus être effectuée comme demandé. Elle a peut-être déjà été effectuée autrement.';

  @override
  String get changeNoteQueuedChangesHeld =>
      'Certaines modifications de ce cercle attendent toujours d\'être effectuées.';

  @override
  String get changeNoteQueuedRemovalDropped =>
      'Un retrait que vous avez demandé dans ce cercle n\'a pas été effectué. Toute personne que vous avez tenté de retirer peut encore faire partie du cercle.';

  @override
  String get changeNoteChangeWithdrawn =>
      'Une modification de ce cercle faite par un autre membre a remplacé l\'une des vôtres : la vôtre n\'a donc pas été effectuée. Refaites-la si vous le souhaitez toujours.';

  @override
  String get changeNoteWelcomeOwed =>
      'Une invitation à ce cercle n\'a pas abouti. Haven continue de l\'envoyer tant que l\'application est ouverte, pendant une journée au plus après votre invitation. Si la personne n\'a pas rejoint le cercle d\'ici là, retirez-la puis ajoutez-la à nouveau.';

  @override
  String get changeNoteUnreadLocation =>
      'Certaines mises à jour récentes envoyées à ce cercle n\'ont pas pu être ouvertes sur ce téléphone.';

  @override
  String get changeNoticeStillInCircleLabel => 'Toujours dans le cercle :';

  @override
  String get changeNoticeRemoveAgain => 'Retirer à nouveau';

  @override
  String get changeNoticeReviewMembers => 'Vérifier les membres';

  @override
  String get changeNoticeKeepMembers => 'Garder dans le cercle';

  @override
  String get changeNoticeKeepConfirmTitle => 'Garder dans le cercle ?';

  @override
  String get changeNoticeKeepConfirmBody =>
      'Haven ne suspendra plus le partage avec ce cercle à cause de ce retrait. Toute personne que vous avez tenté de retirer et qui fait encore partie du cercle y reste, et peut voir votre position chaque fois que Haven la partage avec ce cercle.';

  @override
  String get changeNoticeKeepConfirmAction => 'Garder';

  @override
  String circleMemberLastSeenMinutes(int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Dernière position il y a $countString minutes',
      many: 'Dernière position il y a $countString minutes',
      one: 'Dernière position il y a $countString minute',
    );
    return '$_temp0';
  }

  @override
  String get mapThisLocation => 'cet emplacement';

  @override
  String get mapMemberFallbackName => 'membre';

  @override
  String mapOpenInAppleMapsTitle(String label) {
    return 'Ouvrir $label dans Apple Maps ?';
  }

  @override
  String get mapOpenInAppleMapsBody =>
      'Seule la coordonnée cartographique est envoyée à Apple Maps, jamais un nom ni une identité.';

  @override
  String get mapOpenInAppleMapsConfirm => 'Ouvrir dans Apple Maps';

  @override
  String get mapOpenMapsError => 'Impossible d\'ouvrir Maps';

  @override
  String get mapControlsZoomIn => 'Zoomer';

  @override
  String get mapControlsZoomOut => 'Dézoomer';

  @override
  String get mapControlsRecenter => 'Recentrer';

  @override
  String get mapControlsRecenterFab => 'Recentrer sur ma position';

  @override
  String get mapAttributionCreditsButton => 'Crédits et licence de la carte';

  @override
  String get userLocationMarkerSemantics => 'Marqueur de votre position';

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
      other: 'il y a $countString minutes',
      many: 'il y a $countString minutes',
      one: 'il y a $countString minute',
    );
    return '$_temp0';
  }

  @override
  String memberMarkerNamedSemantics(String name) {
    return 'Marqueur du membre $name';
  }

  @override
  String get memberMarkerGenericSemantics => 'Marqueur de membre';

  @override
  String memberMarkerLastSeenSemantics(String base, String age) {
    return '$base, vu pour la dernière fois $age';
  }

  @override
  String memberMarkerOffScreenSemantics(String name, String direction) {
    return '$name est hors de l\'écran, direction $direction ; appuyez pour afficher';
  }

  @override
  String memberMarkerOffScreenGenericSemantics(String direction) {
    return 'Un membre est hors de l\'écran, direction $direction ; appuyez pour afficher';
  }

  @override
  String get compassNorth => 'nord';

  @override
  String get compassNorthEast => 'nord-est';

  @override
  String get compassEast => 'est';

  @override
  String get compassSouthEast => 'sud-est';

  @override
  String get compassSouth => 'sud';

  @override
  String get compassSouthWest => 'sud-ouest';

  @override
  String get compassWest => 'ouest';

  @override
  String get compassNorthWest => 'nord-ouest';

  @override
  String get commonAdd => 'Ajouter';

  @override
  String get addRelaySheetTitleInbox => 'Ajouter un relais de réception';

  @override
  String get addRelaySheetTitleKeyPackage => 'Ajouter un relais KeyPackage';

  @override
  String get addRelaySheetTitleProfile => 'Ajouter un relais de profil';

  @override
  String get addRelaySheetHint => 'wss://relay.example.com';

  @override
  String get addRelaySheetPasteTooltip => 'Coller depuis le presse-papiers';

  @override
  String get addRelaySheetErrorEmpty => 'Saisissez une adresse de relais.';

  @override
  String get addRelaySheetErrorInsecureScheme =>
      'Utilisez wss:// afin que le trafic vers ce relais soit chiffré.';

  @override
  String get addRelaySheetErrorHasCredentials =>
      'L\'URL du relais ne doit pas contenir d\'identifiants.';

  @override
  String get addRelaySheetErrorInvalidFormat =>
      'Saisissez une adresse de relais comme wss://relay.example.com.';

  @override
  String get avatarSemanticsLabel => 'Avatar de l\'utilisateur';

  @override
  String avatarSemanticsFor(String initials) {
    return 'de $initials';
  }

  @override
  String get avatarSemanticsOnline => 'en ligne';

  @override
  String get avatarSemanticsOffline => 'hors ligne';
}
