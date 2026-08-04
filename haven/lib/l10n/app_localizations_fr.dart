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
      'Partagez votre position en privé, uniquement avec les personnes de votre choix.';

  @override
  String get onboardingWelcomeHeadlineEmphasis => 'uniquement';

  @override
  String get onboardingWelcomeCta => 'Commencer';

  @override
  String get onboardingValuePropsTitle => 'Ce qui distingue Haven';

  @override
  String get onboardingValueProp1Title => 'Seuls vos cercles peuvent vous voir';

  @override
  String get onboardingValueProp1Body =>
      'Votre position est chiffrée sur votre appareil avant de le quitter, de sorte que seuls les cercles que vous choisissez peuvent la lire, jamais Haven ni qui que ce soit d\'autre. Comme Haven est open source, chacun peut le vérifier.';

  @override
  String get onboardingValueProp2Title => 'Personne ne peut le fermer';

  @override
  String get onboardingValueProp2Body =>
      'Haven n\'a pas de serveur central. Vos messages chiffrés transitent par des serveurs indépendants appelés relais, et vous choisissez lesquels utiliser. Aucune entreprise ni aucun gouvernement ne peut à lui seul éteindre le réseau.';

  @override
  String get onboardingValueProp3Title => 'Aucun compte requis';

  @override
  String get onboardingValueProp3Body =>
      'Pas d\'e-mail, pas de numéro de téléphone, pas d\'inscription. Haven crée une identité dont la clé secrète ne quitte jamais votre téléphone : il n\'existe donc aucun compte que quiconque pourrait remettre à un tiers.';

  @override
  String get onboardingValueProp1Summary =>
      'Chiffrée sur votre appareil : seuls les cercles que vous choisissez peuvent la lire.';

  @override
  String get onboardingValueProp2Summary =>
      'Pas de serveur central. Haven fonctionne sur un réseau de relais que vous choisissez.';

  @override
  String get onboardingValueProp3Summary =>
      'Ni e-mail, ni téléphone, ni inscription. Votre clé secrète ne quitte jamais votre téléphone.';

  @override
  String get onboardingCreateIdentityTitle => 'Créez votre identité';

  @override
  String get onboardingCreateIdentityBody =>
      'Haven crée vos clés sur ce téléphone. La clé secrète n\'en sort jamais.';

  @override
  String get onboardingCreateIdentityWarning =>
      'Si vous perdez ce téléphone ou supprimez l\'application, votre identité est perdue. Haven n\'a aucun moyen de la récupérer pour vous.';

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
  String get settingsIdentitySubtitle => 'Profil, clés et partage de photo';

  @override
  String get settingsRelaysTitle => 'Relais';

  @override
  String get settingsRelaysSubtitle => 'Là où les invitations vous parviennent';

  @override
  String get settingsLocationTitle => 'Position';

  @override
  String get settingsLocationSubtitle =>
      'Partage en arrière-plan et autorisations';

  @override
  String get settingsMapStyleTitle => 'Style de carte';

  @override
  String get settingsAppearanceSubtitle => 'Thème et langue';

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
  String get locationSettingsErrorSnack => 'Un problème est survenu';

  @override
  String get locationSettingsIntro =>
      'Haven partage votre position avec vos cercles dès que l\'application est ouverte. Activez cette option et vos cercles continueront de la voir pendant que Haven est en arrière-plan ; si le système ferme Haven, les mises à jour reprennent lorsque vous vous déplacez ou au prochain réveil de l\'application par le système.';

  @override
  String get locationSettingsToggleTitle => 'Partager en arrière-plan';

  @override
  String get locationSettingsToggleSubtitle =>
      'Continuer le partage lorsque l\'application est fermée';

  @override
  String get locationSettingsIosLimitedNote =>
      'Le partage continue de fonctionner en arrière-plan avec votre autorisation actuelle. Choisissez « Toujours » pour Haven dans Réglages afin que les mises à jour puissent aussi reprendre après qu\'iOS a fermé l\'application.';

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
      'Tant que le partage en arrière-plan est activé, Haven maintient une session de localisation continue et iOS affiche un indicateur bleu dans la barre d\'état. Accorder « Toujours » permet en plus à Haven de récupérer les mises à jour de vos cercles après qu\'iOS a fermé l\'application.';

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
  String get aboutVpnLinkLabel => 'mullvad.net';

  @override
  String get aboutFooterLicense => 'Distribué sous la licence MIT License';

  @override
  String aboutFooterVersion(String version) {
    return 'Version $version';
  }

  @override
  String get privacyTitle => 'Confidentialité';

  @override
  String get privacySubtitle =>
      'Comment Haven fonctionne et ce que les autres voient';

  @override
  String get privacyHubSummary =>
      'Haven ne partage votre position qu\'avec les petits groupes que vous choisissez, appelés cercles, et la chiffre sur votre téléphone avant qu\'elle ne quitte l\'appareil. Il n\'y a ni inscription ni serveur Haven. La seule chose publique, c\'est le nom d\'affichage et la photo que vous définissez. Les pages ci-dessous expliquent cela, et tout le reste, en langage clair.';

  @override
  String get privacyGroupBasicsHeading => 'L\'essentiel';

  @override
  String get privacyMeansForYouLabel => 'Ce que cela signifie pour vous';

  @override
  String get privacyMoreDetailLabel => 'Pour aller plus loin';

  @override
  String get privacyMoreDetailExpandHint => 'Afficher les détails techniques';

  @override
  String get privacyMoreDetailCollapseHint => 'Masquer les détails techniques';

  @override
  String get privacyMoreDetailExpandedAnnouncement =>
      'Détails techniques affichés';

  @override
  String get privacyMoreDetailCollapsedAnnouncement =>
      'Détails techniques masqués';

  @override
  String get privacyWhatHavenIsTitle =>
      'Ce qu\'est Haven, et pourquoi il n\'y a pas de compte';

  @override
  String get privacyWhatHavenIsSubtitle =>
      'Aucune inscription, aucun serveur d\'entreprise';

  @override
  String get privacyWhatHavenIsNoAccount =>
      'Haven partage votre position avec de petits groupes que vous choisissez, appelés cercles. Il n\'y a aucun compte derrière tout cela. Vous ne donnez jamais d\'adresse e-mail, de numéro de téléphone ni de mot de passe.';

  @override
  String get privacyWhatHavenIsNoServers =>
      'Haven n\'exploite pas non plus ses propres serveurs. Vos mises à jour de position chiffrées passent par des serveurs indépendants appelés relais, tenus par d\'autres personnes. Les développeurs de Haven ne peuvent pas voir votre position et n\'ont mis aucun traceur dans l\'application. La seule chose qu\'ils voient, c\'est le volume total d\'utilisation de la carte, car les tuiles de carte sont récupérées avec une unique clé partagée. Ils ne voient jamais qui les a récupérées.';

  @override
  String get privacyWhatHavenIsMeansForYou =>
      'On ne peut forcer personne à livrer vos données, puisque personne ne les détient. Le revers, c\'est que personne ne peut non plus restaurer votre identité à votre place. Voyez « Vos deux clés » pour savoir quoi sauvegarder.';

  @override
  String get privacyWhatHavenIsDetailNoTelemetry =>
      'L\'application ne contient aucun code de statistiques, de rapport de plantage ou de publicité. Comme Haven est open source, cela peut être vérifié plutôt que cru sur parole.';

  @override
  String get privacyWhatHavenIsDetailNoPush =>
      'Haven n\'a pas non plus de notifications push, et c\'est volontaire. Un service de notifications devrait être averti chaque fois qu\'une personne de vos cercles a quelque chose à vous transmettre, ce qui révélerait plus de vos habitudes que les relais.';

  @override
  String get privacyYourKeysTitle =>
      'Vos deux clés : une secrète, une à partager';

  @override
  String get privacyYourKeysSubtitle =>
      'Ce qui vous identifie, et ce qu\'il faut sauvegarder';

  @override
  String get privacyYourKeysWhatTheyAre =>
      'Au lieu d\'un nom d\'utilisateur et d\'un mot de passe, vous avez une paire de clés. La clé secrète prouve que vous êtes bien vous. La clé publique sert aux autres à vous trouver et à vous inviter.';

  @override
  String get privacyYourKeysSecretStaysHere =>
      'Votre clé secrète reste uniquement sur ce téléphone, dans un stockage protégé par le système d\'exploitation. Haven ne l\'envoie nulle part : ni à un serveur, ni à nous.';

  @override
  String get privacyYourKeysPublicIsSafe =>
      'Votre clé publique peut être communiquée sans risque. Elle fonctionne comme un nom d\'utilisateur que vous pouvez publier partout. La partager ne révèle jamais où vous êtes.';

  @override
  String get privacyYourKeysMeansForYou =>
      'Pour conserver cette identité, sauvegardez-la. Allez dans Réglages → Identité → Avancé, appuyez sur « Révéler la clé secrète », puis enregistrez-la en lieu sûr, par exemple dans un gestionnaire de mots de passe. Sans cette sauvegarde, perdre le téléphone, c\'est perdre l\'identité pour de bon.';

  @override
  String get privacyYourKeysNeverShareSecret =>
      'Quiconque obtient votre clé secrète devient vous. Cette personne pourrait rejoindre des cercles en votre nom ou publier sous votre identité. Ne la collez jamais dans une autre application, un message ou un site web.';

  @override
  String get privacyYourKeysDetailFormats =>
      'Les deux clés sont en secp256k1 et s\'affichent dans les formats Nostr habituels : npub1… pour la clé publique et nsec1… pour la clé secrète. La signature se fait dans l\'application, et la clé secrète est effacée des composants qui la manipulent directement dès qu\'elle a servi.';

  @override
  String get privacyYourKeysDetailSeparation =>
      'Les clés qui chiffrent les messages de vos cercles sont distinctes de cette clé d\'identité et sont détenues par l\'application seule. Cette séparation est délibérée : la clé qui vous nomme n\'est pas celle qui déverrouille ce que vous avez envoyé.';

  @override
  String get privacyPublicProfileTitle =>
      'Votre nom et votre photo sont publics';

  @override
  String get privacyPublicProfileSubtitle =>
      'Visibles par tous, pas seulement par vos cercles';

  @override
  String get privacyPublicProfileIsPublic =>
      'Le nom d\'affichage et la photo que vous définissez sont publiés sur Nostr, le réseau public ouvert sur lequel Haven fonctionne. N\'importe qui peut les consulter, pas seulement les personnes de vos cercles.';

  @override
  String get privacyPublicProfileOnSave =>
      'Votre nom et votre photo deviennent publics à l\'instant où vous les enregistrez. Aucun réglage ne les garde privés, et il n\'existe aucun moyen de partager un nom avec vos cercles seulement.';

  @override
  String get privacyPublicProfilePseudonym =>
      'Les nouvelles installations démarrent avec un nom inventé, par exemple « Quiet Wanderer », qui ne dit rien de vous. Vous pouvez le garder ou le remplacer par ce que vous voulez.';

  @override
  String get privacyPublicProfileMeansForYou =>
      'Choisissez un nom et une photo que vous acceptez de montrer publiquement. Si vous préférez ne pas être reconnaissable, gardez le nom inventé qui vous a été attribué et n\'ajoutez pas de photo.';

  @override
  String get privacyPublicProfileRemovalIsNotDeletion =>
      'Retirer votre photo plus tard ne supprime pas la copie qui se trouve sur le serveur. Haven remplace votre profil par un profil vide. Le fichier image reste là où il est hébergé, et toute copie déjà téléchargée reste dans la nature. Considérez comme définitif tout ce que vous publiez.';

  @override
  String get privacyPublicProfileDetailKindZero =>
      'Le profil est un événement Nostr « kind 0 » signé par votre clé d\'identité. Les photos sont envoyées à un hébergeur d\'images public, blossom.primal.net, qui voit l\'image, votre clé publique et votre adresse réseau. Haven ne vous permet pas encore de choisir un autre hébergeur.';

  @override
  String get privacyPublicProfileDetailExifStripped =>
      'Avant l\'envoi, Haven réencode l\'image et supprime les données cachées que les appareils photo y attachent, dont la position GPS où la photo a été prise. C\'est important ici : un cliché de vacances peut sinon transporter les coordonnées de votre domicile.';

  @override
  String get privacyGroupHowLocationTravelsHeading =>
      'Le trajet de votre position';

  @override
  String get privacyRelaysTitle =>
      'Les relais : les serveurs qui transmettent vos messages';

  @override
  String get privacyRelaysSubtitle => 'Chez qui transitent vos mises à jour';

  @override
  String get privacyRelaysWhatIsARelay =>
      'Haven n\'a pas de serveur à lui, vos mises à jour passent donc par ceux d\'autres personnes. On les appelle des relais : de petits serveurs indépendants que n\'importe qui peut héberger. Un relais conserve brièvement un message chiffré, puis le transmet lorsque votre cercle le demande.';

  @override
  String get privacyRelaysWhyMany =>
      'Haven utilise plusieurs relais, si bien qu\'aucun ne peut vous couper du réseau à lui seul. Si l\'un se déconnecte, les autres continuent de fonctionner. Vous choisissez les relais par lesquels les invitations vous parviennent ; ceux qu\'utilise un cercle sont fixés à sa création.';

  @override
  String get privacyRelaysYourLists =>
      'Haven tient trois listes pour vous. Vos relais de réception sont là où les invitations vous parviennent, et vos relais KeyPackage sont là où l\'on récupère les clés nécessaires pour vous inviter : Haven publie ces deux listes afin que les autres puissent les trouver. Vos relais de profil, eux, sont différents : c\'est là que votre nom et votre photo sont consultés et publiés, mais la liste elle-même reste sur votre appareil et n\'est jamais publiée. Un relais qui ne transporte que vos mises à jour de position ou vos invitations ne dispose donc d\'aucune liste publique lui indiquant quels relais vous utilisez pour votre profil. Chaque cercle porte aussi sa propre liste, et c\'est par elle que circulent ses mises à jour chiffrées.';

  @override
  String get privacyRelaysMeansForYou =>
      'Un relais ne voit jamais votre position, car elle est chiffrée avant de quitter votre téléphone. Il voit en revanche ce qui doit être public pour qu\'on puisse vous joindre : votre nom et votre photo, les clés dont les autres ont besoin pour vous inviter, et votre liste de relais elle-même. Haven vous fournit d\'emblée des relais qui fonctionnent, vous n\'avez donc rien à changer.';

  @override
  String get privacyRelaysDetailIndexers =>
      'Indépendamment de vos propres listes, Haven interroge un petit ensemble de relais d\'annuaire publics pour rechercher les profils et les clés d\'autres personnes. Il les contacte même si vous n\'avez configuré que des relais privés. Ils voient votre adresse réseau et quels comptes vous avez recherchés.';

  @override
  String get privacyRelaysDetailKeyListIsPublic =>
      'Votre liste de relais KeyPackage est signée par votre clé d\'identité et publiée sur les relais qui y figurent déjà. Si vous y ajoutez un relais privé, son adresse devient publique et associée à vous. Il n\'existe aucun moyen de garder privé un relais inscrit sur cette liste.';

  @override
  String get privacyEncryptionTitle => 'Comment fonctionne le chiffrement';

  @override
  String get privacyEncryptionSubtitle =>
      'Une clé par cercle, et ce qui change quand quelqu\'un arrive ou part';

  @override
  String get privacyEncryptionPerCircle =>
      'Votre position est chiffrée sur votre téléphone avant de le quitter, à l\'aide d\'une norme ouverte appelée MLS. Chaque cercle est son propre groupe chiffré, avec ses propres clés. Personne à l\'extérieur d\'un cercle ne peut lire ce qui y est envoyé : ni un relais, ni Haven, ni un autre cercle dont vous faites partie.';

  @override
  String get privacyEncryptionWhenSomeoneJoins =>
      'Quand une personne rejoint le cercle, celui-ci passe à une nouvelle clé. Elle peut lire ce qui est envoyé après son arrivée, et rien de ce qui précède. Haven n\'envoie jamais à un nouveau membre les positions passées.';

  @override
  String get privacyEncryptionWhenSomeoneLeaves =>
      'Quand une personne quitte un cercle, celui-ci passe encore à une nouvelle clé. Elle cesse de pouvoir lire quoi que ce soit de nouveau dès que le reste du cercle a suivi. Cela prend en général quelques minutes, et davantage pour les personnes qui étaient hors ligne à ce moment-là.';

  @override
  String get privacyEncryptionKeysChangeOnMembership =>
      'Quitter un cercle ne reprend pas ce que ses membres ont déjà enregistré. Haven ne change de clé que lorsqu\'une personne arrive ou part, jamais à intervalles réguliers. Une seule clé peut donc couvrir des semaines de messages, et tout ce qu\'un membre a enregistré pendant ce temps lui reste lisible. Cette personne ne peut toujours pas ouvrir ce qui a été envoyé après son départ.';

  @override
  String get privacyEncryptionMeansForYou =>
      'Le chiffrement vous protège de toute personne extérieure à vos cercles. Il ne peut pas vous protéger de quelqu\'un qui en a fait partie. Pour cesser de partager avec une personne en particulier, quittez le cercle qui vous relie à elle et créez-en un nouveau sans elle.';

  @override
  String get privacyEncryptionDetailMls =>
      'MLS (Messaging Layer Security) est la même norme IETF que celle utilisée par d\'autres messageries sécurisées. Haven rejoint le réseau Nostr par le protocole Marmot, qui définit comment les groupes MLS circulent sur les relais. La clé avec laquelle chaque cercle signe est distincte de votre clé d\'identité Nostr publique.';

  @override
  String get privacyEncryptionDetailEpochs =>
      'Chaque période de clé s\'appelle une époque, et un cercle n\'en change que lorsque sa composition change. Votre appareil conserve les clés de l\'époque en cours et de quelques époques récentes, de quoi ouvrir les messages encore en route, puis il jette le reste. Un cercle dont la composition n\'a pas bougé depuis des mois en est toujours à l\'époque de ses débuts.';

  @override
  String get privacyWhatOthersSeeTitle =>
      'Ce que voient les membres, et ce que voient les relais';

  @override
  String get privacyWhatOthersSeeSubtitle =>
      'Les personnes avec qui vous partagez, et les serveurs entre vous';

  @override
  String get privacyWhatOthersSeeMembersHeading =>
      'Les personnes de vos cercles';

  @override
  String get privacyWhatOthersSeeMembersExact =>
      'Tous les membres d\'un cercle voient votre position exacte sur la carte, pas une zone approximative. Aucun réglage ne permet de partager une position vague avec certains membres et une position précise avec d\'autres.';

  @override
  String get privacyWhatOthersSeeCannotPause =>
      'Tant que Haven est ouvert et que vous appartenez à un cercle, votre position part toute seule toutes les deux ou trois minutes. Il n\'y a pas de bouton pause : l\'interrupteur de la page Position détermine seulement si cela continue après la fermeture de l\'application. Pour cesser de partager avec un cercle, ouvrez-le et choisissez « Quitter le cercle ».';

  @override
  String get privacyWhatOthersSeeMembersLearnKey =>
      'Rejoindre un cercle montre aussi votre clé publique à chaque membre. Elle leur permet de consulter votre profil public, et tout ce que vous avez déjà publié sous cette clé.';

  @override
  String get privacyWhatOthersSeeCoMemberIp =>
      'Votre téléphone télécharge la photo de profil de chaque membre depuis un serveur que ce membre a choisi, sans que vous ayez à toucher quoi que ce soit. Ce serveur voit alors votre adresse réseau, ce qui vous situe grossièrement sur la carte. Un VPN masque cela ; rien d\'autre ne le fait.';

  @override
  String get privacyWhatOthersSeeRelaysHeading => 'Les opérateurs de relais';

  @override
  String get privacyWhatOthersSeeRelaysCannot =>
      'Les relais, ces serveurs indépendants par lesquels transitent vos mises à jour, ne peuvent lire ni votre position, ni vos messages, ni le nom de votre cercle, ni sa liste de membres. Vos mises à jour de position portent une adresse d\'envoi neuve et à usage unique au lieu de votre clé publique. Votre profil, vos invitations et vos listes de relais, eux, la portent bel et bien : un relais qui traite les deux peut donc souvent deviner que vous faites partie d\'un cercle, sans rien lire de ce qu\'il contient.';

  @override
  String get privacyWhatOthersSeeRelaysCan =>
      'Ils voient en revanche votre adresse réseau, les moments où vous êtes en ligne, ainsi que la taille et la fréquence de votre trafic. Chaque cercle porte une étiquette aléatoire. Grâce à elle, un relais peut regrouper les messages d\'un même cercle et estimer combien de personnes s\'y trouvent, sans savoir qui elles sont.';

  @override
  String get privacyWhatOthersSeeMeansForYou =>
      'Ne rejoignez un cercle qu\'avec des personnes à qui vous donneriez votre adresse personnelle. Face aux relais et aux tiers, le chiffrement tient, et un VPN masque l\'adresse depuis laquelle votre téléphone se connecte. Rien ne vous protège d\'un membre qui fait une capture d\'écran.';

  @override
  String get privacyWhatOthersSeeDetailTag =>
      'L\'étiquette d\'un cercle reste la même pendant toute la vie de ce cercle : un relais peut donc relier indéfiniment tous ses messages entre eux. C\'est une propriété du protocole sous-jacent, et non quelque chose que Haven peut changer.';

  @override
  String get commonLearnMore => 'En savoir plus';

  @override
  String get relaySettingsBackendCaption =>
      'Haven n\'a pas de serveur à lui. Vos mises à jour chiffrées passent par des serveurs indépendants appelés relais, qui ne peuvent lire ni votre position ni vos messages.';

  @override
  String get privacyWhatOthersSeeScreenshots =>
      'Cela dépend de votre téléphone. Sur Android, Haven bloque les captures d\'écran et l\'enregistrement de l\'écran dans toute l\'application. Sur iPhone, il ne le peut pas : Haven floute l\'aperçu du sélecteur d\'applications, mais un membre peut tout de même capturer ce qui est affiché à l\'écran.';

  @override
  String get privacyWhatOthersSeeDetailExpiry =>
      'Haven demande aux relais de supprimer les messages de position au bout d\'environ quatre minutes. Cette demande est indicative : un relais reste libre de les conserver plus longtemps. Les invitations, elles, ne portent aucune expiration et peuvent rester indéfiniment sur votre relais de réception.';

  @override
  String get privacyGroupTheLimitsHeading => 'Les limites';

  @override
  String get privacyInferenceTitle =>
      'Ce qu\'on peut encore déduire à votre sujet';

  @override
  String get privacyInferenceSubtitle =>
      'Les traces que le chiffrement ne peut pas masquer';

  @override
  String get privacyInferenceWhatIsMetadata =>
      'Le chiffrement masque ce que vous envoyez. Il ne peut pas masquer le fait que vous avez envoyé quelque chose. Cette trace résiduelle s\'appelle les métadonnées : le moment où un message est parti, sa taille, et les serveurs auxquels vous étiez connecté. Elles restent visibles même quand le contenu ne l\'est pas.';

  @override
  String get privacyInferenceActivityPattern =>
      'À partir de ces traces, un relais que vous utilisez peut deviner à peu près quand vous êtes actif et à quelle fréquence. Haven envoie en plus une mise à jour dès que vous vous déplacez d\'une centaine de mètres. Sur plusieurs heures, cela peut montrer à un relais si vous étiez en déplacement ou immobile. Cela ne montre jamais où.';

  @override
  String get privacyInferencePresence =>
      'Tant que Haven fonctionne, il garde une connexion ouverte vers vos relais. Ils peuvent voir que vous êtes en ligne, et quelles étiquettes de cercle vous suivez, jamais le nom d\'un cercle ni qui en fait partie. C\'est le prix des mises à jour qui arrivent en quelques secondes plutôt qu\'en quelques minutes.';

  @override
  String get privacyInferenceIpHeading => 'Votre adresse réseau';

  @override
  String get privacyInferenceIpAddress =>
      'Chaque serveur auquel Haven parle voit l\'adresse depuis laquelle votre téléphone se connecte, son adresse IP : vos relais, le fournisseur de cartes, et celui qui héberge la photo de profil d\'un membre. Votre fournisseur d\'accès à Internet voit lesquels de ces serveurs vous avez joints, et quand. À lui seul, Haven ne fait rien pour masquer ni l\'un ni l\'autre.';

  @override
  String get privacyInferenceMapTilesHeading => 'La carte elle-même';

  @override
  String get privacyInferenceMapTiles =>
      'Pour dessiner la carte, Haven demande au fournisseur de cartes les carrés d\'image affichés à l\'écran : celui-ci apprend donc à peu près quels endroits vous regardez. Haven télécharge aussi à l\'avance une petite zone autour de chaque membre que vous voyez, pour que la carte soit prête avant même que vous ne vous y déplaciez. Le fournisseur peut donc situer à peu près votre cercle, et pas seulement l\'endroit que vous regardez. Ces carrés restent dans un cache chiffré sur votre téléphone pendant sept jours au maximum, et sont effacés si vous supprimez votre identité.';

  @override
  String get privacyInferenceVpnHeading => 'Faut-il utiliser un VPN ?';

  @override
  String get privacyInferenceVpnHelps =>
      'Un VPN remplace votre adresse par la sienne : les relais et les autres serveurs ne voient plus d\'où vous vous connectez. Il masque aussi à votre fournisseur d\'accès à Internet quels serveurs vous joignez. Nous recommandons Mullvad.';

  @override
  String get privacyInferenceVpnLimits =>
      'Ce n\'est pas une solution miracle. Un VPN ne change rien à ce que voient les membres de votre cercle. Et il ne masque ni le rythme ni la taille de votre trafic au relais avec lequel vous échangez. Il transfère seulement votre confiance vers le fournisseur de VPN : il ne vous dispense pas de faire confiance à quelqu\'un.';

  @override
  String get privacyInferenceMeansForYou =>
      'Vous craignez que les relais, votre fournisseur d\'accès à Internet ou les serveurs de cartes vous situent sur une carte ? Un VPN est ce que vous pouvez ajouter de plus utile. Vous craignez les personnes de vos cercles ? Il n\'y changera rien du tout.';

  @override
  String get privacyInferenceDetailJitter =>
      'Haven fait varier exprès l\'intervalle entre les mises à jour : un enregistrement court n\'y montre aucune cadence régulière. Moyennée sur de longues heures, la fréquence réelle peut malgré tout être estimée. La taille des messages n\'est pas uniformisée non plus, et les mises à jour de position tiennent dans une plage de tailles étroite, ce qui les rend reconnaissables comme telles.';

  @override
  String get privacyInferenceDetailOutOfScope =>
      'Deux choses échappent à tout choix de conception ici : un observateur capable de surveiller de nombreux relais à la fois, et votre propre téléphone dès que quelqu\'un d\'autre en a le contrôle.';

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
  String get createCircleMemberAlreadyAdded => 'Membre déjà ajouté';

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
  String get nameCircleStageSendingInvites => 'Envoi des invitations...';

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
  String addMemberPartialDelivery(int sent, int total) {
    final intl.NumberFormat sentNumberFormat = intl.NumberFormat.decimalPattern(
      localeName,
    );
    final String sentString = sentNumberFormat.format(sent);
    final intl.NumberFormat totalNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String totalString = totalNumberFormat.format(total);

    return 'Invitations envoyées ($sentString sur $totalString). Livraison en attente pour les autres.';
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
  String get circleMemberInvitationPending => 'Invitation en attente';

  @override
  String get circleMemberNoRecentLocation => 'Aucune position récente';

  @override
  String get circleMemberRemoveTooltip => 'Retirer du cercle';

  @override
  String get circleMemberAdmin => 'Admin';

  @override
  String get circleMemberHintPending => 'invitation en attente';

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
  String get pendingMemberNeedsUpdate => 'Doit mettre à jour Haven';

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
  String selectedMembersMore(int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    return '+$countString de plus';
  }

  @override
  String get invitationStatusPending => 'Invitation en attente';

  @override
  String get invitationStatusActive => 'Actif';

  @override
  String get invitationStatusDeclined => 'Refusée';

  @override
  String invitationStatusSemantics(String label) {
    return 'Statut de l\'invitation : $label';
  }

  @override
  String invitationCardSemantics(String circleName, String inviter, int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    return 'Invitation à rejoindre $circleName, invité par $inviter, $countString membres';
  }

  @override
  String invitationCardInvitedBySemantics(String inviter) {
    return 'Invité par l\'identifiant cryptographique $inviter';
  }

  @override
  String invitationCardInvitedBy(String inviter) {
    return 'Invité par : $inviter';
  }

  @override
  String invitationCardMemberCount(int count) {
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
  String get circleDetailsRelaysHeading => 'Relais de ce cercle';

  @override
  String get circleDetailsNoRelays => '(aucun enregistré)';

  @override
  String get circleDetailsRelaysNote =>
      'Ces relais ont été copiés depuis vos relais de réception à la création de ce cercle et ne sont pas encore modifiables. Les modifications ultérieures de votre liste de relais personnelle ne les changent pas.';

  @override
  String get circleDetailsAddMember => 'Ajouter un membre';

  @override
  String get circleDetailsLeaveCircle => 'Quitter le cercle';

  @override
  String get leaveCircleDialogTitle => 'Quitter le cercle';

  @override
  String get leaveCircleDialogBody =>
      'Quitter ce cercle ? Vous cesserez d\'envoyer votre position à ses membres et de voir la leur. La dernière position que vous avez envoyée reste sur leurs téléphones pendant une journée au plus. C\'est irréversible : il vous faudrait une nouvelle invitation pour revenir.';

  @override
  String get leaveCircleConfirm => 'Quitter';

  @override
  String get leaveCircleIdentityUnavailable => 'Identité indisponible';

  @override
  String get leaveCircleSuccess => 'Cercle quitté avec succès';

  @override
  String get leaveCircleError => 'Échec de la sortie du cercle';

  @override
  String get circleBlockedBannerTitle =>
      'Ce cercle ne peut pas être mis à jour';

  @override
  String get circleBlockedBannerBody =>
      'Un problème est survenu avec le chiffrement de ce cercle, Haven ne peut donc plus y envoyer ni recevoir de mises à jour. Vous pouvez toujours voir ci-dessous les dernières informations connues, ou quitter le cercle.';

  @override
  String get legacyCircleBannerTitle => 'Ce cercle doit être recréé';

  @override
  String get legacyCircleBannerBody =>
      'Le moteur de chiffrement de Haven a été mis à jour, ce cercle ne peut donc plus être utilisé. Recréez-le pour continuer à partager votre position avec les mêmes personnes. Vous devrez les inviter à nouveau.';

  @override
  String get legacyCircleRecreateCta => 'Recréer le cercle';

  @override
  String get legacyCircleRemoveCta => 'Retirer';

  @override
  String get legacyCircleRemoveDialogTitle => 'Retirer ce cercle ?';

  @override
  String get legacyCircleRemoveDialogBody =>
      'Ce cercle ne peut plus être utilisé et sera retiré de votre liste. Cela n\'affecte pas un nouveau cercle que vous créeriez pour le remplacer.';

  @override
  String get legacyCircleRemoveConfirm => 'Retirer';

  @override
  String get legacyCutoverExplainerTitle => 'Haven a été mis à jour';

  @override
  String get legacyCutoverExplainerIdentityUnchanged =>
      'Votre identité et votre profil public sont inchangés. Vous n\'avez rien à faire de ce côté.';

  @override
  String get legacyCutoverExplainerCirclesNeedRecreation =>
      'Pour une meilleure sécurité, vos cercles doivent être recréés et leurs membres réinvités avant que vous puissiez à nouveau y partager votre position.';

  @override
  String get legacyCutoverExplainerAcknowledge => 'Compris';

  @override
  String get relaySettingsLegacyRetractionPending =>
      'Haven demande encore aux relais de supprimer certaines anciennes données issues de la récente mise à jour de sécurité.';

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
      'Cela supprime votre identité et toutes les données de vos cercles de ce téléphone. Tout ce qui a déjà été publié sous cette identité, y compris votre nom, votre photo et vos clés, reste sur les relais qui le détiennent. Assurez-vous d\'avoir sauvegardé votre clé secrète si vous souhaitez la récupérer.';

  @override
  String get identityAdvancedDeleteConfirm => 'Supprimer';

  @override
  String get identityAdvancedDeletedSnack => 'Identité supprimée';

  @override
  String get identityAdvancedDeleteError =>
      'Échec de la suppression de l\'identité. Veuillez réessayer.';

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
  String keyDisplayCopiedToClipboard(String label) {
    return '$label copié dans le presse-papiers';
  }

  @override
  String keyDisplaySemantics(String label, String state) {
    return '$label : $state';
  }

  @override
  String get keyDisplayStateRevealed => 'révélée';

  @override
  String get keyDisplayStateHidden => 'masquée';

  @override
  String get keyDisplayHideTooltip => 'Masquer';

  @override
  String get keyDisplayRevealTooltip => 'Révéler';

  @override
  String get keyDisplayCopyTooltip => 'Copier';

  @override
  String get keyDisplayCompactCopied => 'Clé copiée dans le presse-papiers';

  @override
  String get keyDisplayCompactTapToCopy => 'Appuyez pour copier';

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
      'Photo mise à jour. Publiée sur votre profil Nostr public.';

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
      'Ce téléphone retarde sur le reste de vos cercles : les positions qu\'il envoie expirent donc avant que quiconque puisse les voir. Activez la date et l\'heure automatiques dans les réglages du système pour y remédier.';

  @override
  String get clockSkewResolvedAnnouncement =>
      'Le problème d\'horloge est résolu. Haven partage à nouveau votre position.';

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
  String userLocationMarkerSemantics(String accuracy) {
    return 'Marqueur de votre position$accuracy';
  }

  @override
  String userLocationMarkerAccuracy(int meters) {
    final intl.NumberFormat metersNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String metersString = metersNumberFormat.format(meters);

    return '. Précision : $metersString mètres';
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
