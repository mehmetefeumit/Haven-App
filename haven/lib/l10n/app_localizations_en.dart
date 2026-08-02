// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for English (`en`).
class AppLocalizationsEn extends AppLocalizations {
  AppLocalizationsEn([String locale = 'en']) : super(locale);

  @override
  String get appearanceTitle => 'Appearance';

  @override
  String get appearanceThemeHeader => 'Theme';

  @override
  String get appearanceThemeSystem => 'System default';

  @override
  String get appearanceThemeSystemSubtitle => 'Match your device settings';

  @override
  String get appearanceThemeLight => 'Light';

  @override
  String get appearanceThemeLightSubtitle => 'Always use the light theme';

  @override
  String get appearanceThemeDark => 'Dark';

  @override
  String get appearanceThemeDarkSubtitle => 'Always use the dark theme';

  @override
  String get appearanceLanguageTitle => 'Language';

  @override
  String get languageSystemDefault => 'System default';

  @override
  String get commonTryAgain => 'Try Again';

  @override
  String get commonDismiss => 'Dismiss';

  @override
  String get commonSettings => 'Settings';

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
      other: '$countString pending invitations',
      one: '1 pending invitation',
    );
    return '$_temp0';
  }

  @override
  String get commonBack => 'Back';

  @override
  String get commonContinue => 'Continue';

  @override
  String get commonSkip => 'Skip';

  @override
  String get commonRetry => 'Retry';

  @override
  String onboardingStepOf(int current, int total) {
    final intl.NumberFormat currentNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String currentString = currentNumberFormat.format(current);
    final intl.NumberFormat totalNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String totalString = totalNumberFormat.format(total);

    return 'Step $currentString of $totalString';
  }

  @override
  String get onboardingAppName => 'Haven';

  @override
  String get onboardingWelcomeHeadline =>
      'Share your location privately, only with those you want.';

  @override
  String get onboardingWelcomeHeadlineEmphasis => 'only';

  @override
  String get onboardingWelcomeCta => 'Get Started';

  @override
  String get onboardingValuePropsTitle => 'What makes Haven different';

  @override
  String get onboardingValueProp1Title => 'Only your circles can see you';

  @override
  String get onboardingValueProp1Body =>
      'Your location is encrypted on your device before it leaves, so only the circles you choose can read it, never Haven or anyone else. Because Haven is open source, anyone can verify that.';

  @override
  String get onboardingValueProp2Title => 'No one can shut it down';

  @override
  String get onboardingValueProp2Body =>
      'Haven has no central server. Your encrypted messages travel through independent servers called relays, and you choose which ones to use. No single company or government can switch the network off.';

  @override
  String get onboardingValueProp3Title => 'No account needed';

  @override
  String get onboardingValueProp3Body =>
      'No email, no phone number, no sign-up. Haven creates an identity whose secret key never leaves your phone, so there is no account for anyone to hand over.';

  @override
  String get onboardingValueProp1Summary =>
      'Encrypted on your device, so only the circles you choose can read it.';

  @override
  String get onboardingValueProp2Summary =>
      'No central server . It runs on a relay network you choose.';

  @override
  String get onboardingValueProp3Summary =>
      'No email, phone, or sign-up. Your secret key never leaves your phone.';

  @override
  String get onboardingCreateIdentityTitle => 'Create your identity';

  @override
  String get onboardingCreateIdentityBody =>
      'Haven creates your keys on this phone. The secret one never leaves it.';

  @override
  String get onboardingCreateIdentityWarning =>
      'If you lose this phone or delete the app, your identity is gone. Haven has no way to recover it for you.';

  @override
  String get onboardingCreateIdentityCta => 'Create My Identity';

  @override
  String get onboardingCreateIdentityLoading => 'Setting things up…';

  @override
  String get onboardingCreateIdentityImportPrompt => 'Already have a key?';

  @override
  String get onboardingCreateIdentityImportLink => 'Import it instead';

  @override
  String get onboardingCreateIdentityError =>
      'Something went wrong creating your identity. Please try again.';

  @override
  String get onboardingImportTitle => 'Import your existing key';

  @override
  String get onboardingImportBody =>
      'Paste the secret key you backed up from another Haven-compatible app.';

  @override
  String get onboardingImportHint => 'nsec1…';

  @override
  String get onboardingImportCta => 'Import';

  @override
  String get onboardingImportLoading => 'Importing…';

  @override
  String get onboardingImportInvalid =>
      'That doesn’t look like a valid backup key. Please check and try again.';

  @override
  String get onboardingImportError =>
      'We couldn’t import that key. Please check and try again.';

  @override
  String get onboardingDisplayNameHint => 'e.g. Alex';

  @override
  String get onboardingDisplayNameError =>
      'Couldn’t save that name. Please try again.';

  @override
  String get onboardingAddPhotoOptional => 'Add a photo (optional)';

  @override
  String get commonCancel => 'Cancel';

  @override
  String get commonOpenSettings => 'Open settings';

  @override
  String get settingsTitle => 'Settings';

  @override
  String get settingsIdentityTitle => 'Identity';

  @override
  String get settingsIdentitySubtitle => 'Profile, keys, and photo sharing';

  @override
  String get settingsRelaysTitle => 'Relays';

  @override
  String get settingsRelaysSubtitle => 'Where invitations reach you';

  @override
  String get settingsLocationTitle => 'Location';

  @override
  String get settingsLocationSubtitle => 'Background sharing and permissions';

  @override
  String get settingsMapStyleTitle => 'Map style';

  @override
  String get settingsAppearanceSubtitle => 'Theme and language';

  @override
  String get settingsAboutTitle => 'About';

  @override
  String get settingsDebugOverlayTitle => 'Debug Log Overlay';

  @override
  String get settingsDebugOverlaySubtitle => 'Show log output on screen';

  @override
  String get relaySettingsTitle => 'Relays';

  @override
  String get relaySettingsCheckRelaysTooltip => 'Check relays';

  @override
  String get relaySettingsNoIdentityTitle => 'No Identity';

  @override
  String get relaySettingsNoIdentityMessage =>
      'Create an identity first to manage relays.';

  @override
  String get relaySettingsLoadIdentityError => 'Failed to load identity.';

  @override
  String get relaySettingsInboxTitle => 'My Inbox Relays';

  @override
  String get relaySettingsInboxSubtitle =>
      'Where invitations reach you (kind 10050)';

  @override
  String get relaySettingsKeyPackageTitle => 'My KeyPackage Relays';

  @override
  String get relaySettingsKeyPackageSubtitle =>
      'Where others find the keys they need to invite you (kind 10002)';

  @override
  String get relaySettingsProfileTitle => 'My Profile Relays';

  @override
  String get relaySettingsProfileSubtitle =>
      'Where your public profile is looked up and published. These relays are kept separate from your other relays, and the profile relay list itself is never published (kind 0)';

  @override
  String get relaySettingsProfileUnderflowTitle => 'Profile lookups paused';

  @override
  String get relaySettingsProfileUnderflowMessage =>
      'Too few Profile relays remain, so members\' names and photos will stop updating.';

  @override
  String get relaySettingsProfileUnderflowRestoreButton =>
      'Restore default profile relays';

  @override
  String get relaySettingsLoadRelaysError => 'Failed to load relays.';

  @override
  String get relaySettingsAddRelay => 'Add relay';

  @override
  String get relaySettingsRestoreDefaults => 'Restore defaults';

  @override
  String get relaySettingsAddRelayError => 'Failed to add relay.';

  @override
  String get relaySettingsRemoveRelayError => 'Failed to remove relay.';

  @override
  String get relaySettingsRestoreTitle => 'Restore default relays?';

  @override
  String relaySettingsRestoreBody(int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other:
          'Your current $countString relays will be replaced with Haven\'s defaults. This cannot be undone.',
      one:
          'Your current 1 relay will be replaced with Haven\'s defaults. This cannot be undone.',
    );
    return '$_temp0';
  }

  @override
  String get relaySettingsRestoreConfirm => 'Restore';

  @override
  String get relaySettingsRestoreSuccess => 'Defaults restored.';

  @override
  String get relaySettingsRestoreError => 'Failed to restore defaults.';

  @override
  String relaySettingsRemoveTooltip(String url) {
    return 'Remove $url';
  }

  @override
  String get relaySettingsStatusConnected => 'Connected';

  @override
  String get relaySettingsStatusChecking => 'Checking';

  @override
  String get relaySettingsStatusUnreachable => 'Can\'t reach';

  @override
  String get relaySettingsStatusNotChecked => 'Not checked';

  @override
  String relaySettingsStatusSemantics(String status) {
    return 'Relay status: $status';
  }

  @override
  String get relaySettingsEmptyTitle => 'No relays configured';

  @override
  String get relaySettingsEmptyMessage =>
      'You need at least one relay so others can reach you. Tap below to restore Haven defaults.';

  @override
  String get relaySettingsProfileContaminationTooltip =>
      'Also carries other Haven traffic';

  @override
  String relaySettingsProfileContaminationSemantics(String url) {
    return 'Warning: $url also carries your other Haven traffic, so this relay could link your profile to that traffic';
  }

  @override
  String get locationSettingsTitle => 'Location';

  @override
  String get locationSettingsDisabledSnack => 'Background sharing disabled';

  @override
  String get locationSettingsEnabledSnack => 'Background sharing enabled';

  @override
  String get locationSettingsNotificationDeniedSnack =>
      'Background sharing needs a notification so Android keeps it running. It\'s off for now. Enable notifications for Haven to turn it on.';

  @override
  String get locationSettingsBatteryOptSnack =>
      'On. Battery optimization may pause sharing on some phones. Exclude Haven from battery optimization to keep it reliable.';

  @override
  String get locationSettingsErrorSnack => 'Something went wrong';

  @override
  String get locationSettingsIntro =>
      'Haven shares your location with your circles whenever the app is open. Turn this on and your circles keep seeing it while Haven is in the background; if the system closes Haven, updates resume when you move or when the system next wakes the app.';

  @override
  String get locationSettingsToggleTitle => 'Share in background';

  @override
  String get locationSettingsToggleSubtitle =>
      'Keep sharing when the app is closed';

  @override
  String get locationSettingsIosLimitedNote =>
      'Sharing keeps working in the background with your current permission. Choose \'Always\' for Haven in Settings so updates can also resume after iOS closes the app.';

  @override
  String get locationSettingsAndroidHeader => 'OS settings for reliability';

  @override
  String get locationSettingsAndroidNotification =>
      'Haven needs a persistent notification so Android keeps the background service alive. If you denied the notification permission, open Settings and allow notifications for Haven.';

  @override
  String get locationSettingsAndroidBattery =>
      'For reliable background sharing, also exclude Haven from battery optimization. Go to Settings → Apps → Haven → Battery → Allow all the time.';

  @override
  String get locationSettingsAndroidVendors =>
      'On Samsung devices, remove Haven from \"Sleeping apps\" (Device care → Battery → Background usage limits). On Xiaomi, enable Autostart for Haven.';

  @override
  String get locationSettingsIosGuidance =>
      'While background sharing is on, Haven keeps a continuous location session and iOS shows a blue status-bar indicator. Granting \"Always\" additionally lets Haven catch up on your circles after iOS closes the app.';

  @override
  String get mapStyleTitle => 'Map style';

  @override
  String get mapStyleMinimalTitle => 'Minimal';

  @override
  String get mapStyleMinimalSubtitle =>
      'Calm, low-detail canvas that follows your light or dark theme';

  @override
  String get mapStyleDetailedTitle => 'Detailed';

  @override
  String get mapStyleDetailedSubtitle =>
      'Full-colour streets, labels, and places';

  @override
  String get mapStyleOutdoorsTitle => 'Outdoors';

  @override
  String get mapStyleOutdoorsSubtitle => 'Shaded terrain with trails and parks';

  @override
  String get mapStylePreviewHeader => 'Preview';

  @override
  String get mapStylePreviewCity => 'City';

  @override
  String get mapStylePreviewNature => 'Nature';

  @override
  String mapStylePreviewSemantics(String scene, String style) {
    return 'Map preview ($scene): $style';
  }

  @override
  String get mapStylePreviewUnavailableSemantics =>
      'Map preview unavailable in this build';

  @override
  String get mapStylePreviewUnavailableLabel =>
      'Live preview appears in release builds';

  @override
  String get aboutTitle => 'About';

  @override
  String get aboutHeroName => 'Haven';

  @override
  String get aboutHeroTagline =>
      'Private and censorship-resistant location sharing.';

  @override
  String get aboutLicensesTitle => 'Open-source licenses';

  @override
  String get aboutLicensesLegalese => '© 2026 Haven · MIT License';

  @override
  String get aboutReportMapIssue => 'Report a map issue';

  @override
  String get aboutSupportOsm => 'Support OpenStreetMap';

  @override
  String get aboutMapAttribution =>
      '© Stadia Maps · © OpenMapTiles · © OpenStreetMap contributors\nMap data licensed under ODbL';

  @override
  String get aboutLinkOpenError => 'Could not open link';

  @override
  String get aboutVpnLinkLabel => 'mullvad.net';

  @override
  String get aboutFooterLicense => 'Licensed under the MIT License';

  @override
  String aboutFooterVersion(String version) {
    return 'Version $version';
  }

  @override
  String get privacyTitle => 'Privacy';

  @override
  String get privacySubtitle => 'How Haven works and what others can see';

  @override
  String get privacyHubSummary =>
      'Haven shares your location only with the small groups you choose, called circles, and encrypts it on your phone before it leaves. There is no sign-up and no Haven server. The one thing that is public is the display name and photo you set. The pages below explain that, and everything else, in plain language.';

  @override
  String get privacyGroupBasicsHeading => 'The basics';

  @override
  String get privacyMeansForYouLabel => 'What this means for you';

  @override
  String get privacyMoreDetailLabel => 'In more detail';

  @override
  String get privacyMoreDetailExpandHint => 'Show the technical detail';

  @override
  String get privacyMoreDetailCollapseHint => 'Hide the technical detail';

  @override
  String get privacyMoreDetailExpandedAnnouncement => 'Technical detail shown';

  @override
  String get privacyMoreDetailCollapsedAnnouncement =>
      'Technical detail hidden';

  @override
  String get privacyWhatHavenIsTitle =>
      'What Haven is, and why there\'s no account';

  @override
  String get privacyWhatHavenIsSubtitle => 'No sign-up, no company server';

  @override
  String get privacyWhatHavenIsNoAccount =>
      'Haven shares your location with small groups you choose, called circles. There is no account behind it. You never give an email address, a phone number, or a password.';

  @override
  String get privacyWhatHavenIsNoServers =>
      'Haven also runs no servers of its own. Your encrypted location updates pass through independent servers called relays, run by other people. Haven\'s developers cannot see your location and put no tracking in the app. The one thing they can see is how much the map is used in total, because map tiles are fetched with a single shared key, never who fetched them.';

  @override
  String get privacyWhatHavenIsMeansForYou =>
      'Nobody can be made to hand over your data, because nobody is holding it. The cost is that nobody can restore your identity for you either. See “Your two keys” for what to back up.';

  @override
  String get privacyWhatHavenIsDetailNoTelemetry =>
      'The app contains no analytics, crash reporting, or advertising code. Because Haven is open source, that can be checked rather than taken on trust.';

  @override
  String get privacyWhatHavenIsDetailNoPush =>
      'Haven also has no push notifications, on purpose. A notification service would have to be told whenever anyone in your circles had something to deliver, which would reveal more about your habits than the relays do.';

  @override
  String get privacyYourKeysTitle => 'Your two keys: one secret, one to share';

  @override
  String get privacyYourKeysSubtitle =>
      'What identifies you, and what to back up';

  @override
  String get privacyYourKeysWhatTheyAre =>
      'Instead of a username and password, you have a pair of keys. The secret key proves you are you. The public key is what others use to find and invite you.';

  @override
  String get privacyYourKeysSecretStaysHere =>
      'Your secret key is kept only on this phone, in storage the operating system protects. Haven never sends it anywhere: not to any server, not to us.';

  @override
  String get privacyYourKeysPublicIsSafe =>
      'Your public key is safe to hand out. It works like a username you can post anywhere. Sharing it cannot reveal where you are.';

  @override
  String get privacyYourKeysMeansForYou =>
      'To keep this identity, back it up. Go to Settings → Identity → Advanced, tap Reveal Secret Key, and save it somewhere safe such as a password manager. Without that backup, losing the phone loses the identity for good.';

  @override
  String get privacyYourKeysNeverShareSecret =>
      'Anyone who gets your secret key becomes you. They could join circles as you or publish under your name. Never paste it into another app, a message, or a website.';

  @override
  String get privacyYourKeysDetailFormats =>
      'Both keys are secp256k1, shown in the standard Nostr formats: npub1… for the public key and nsec1… for the secret one. Signing happens inside the app, and the secret is cleared from the parts that handle it directly as soon as it is used.';

  @override
  String get privacyYourKeysDetailSeparation =>
      'The keys that encrypt your circles\' messages are separate from this identity key, and are held only by the app. That separation is deliberate: the key that names you is not the key that unlocks what you sent.';

  @override
  String get privacyPublicProfileTitle => 'Your name and photo are public';

  @override
  String get privacyPublicProfileSubtitle =>
      'Visible to anyone, not just your circles';

  @override
  String get privacyPublicProfileIsPublic =>
      'The display name and photo you set are published to Nostr, the open public network Haven runs on. Anyone can look them up, not only the people in your circles.';

  @override
  String get privacyPublicProfileOnSave =>
      'Your name and photo go public the moment you save them. There is no setting that keeps them private, and no way to share a name with your circles only.';

  @override
  String get privacyPublicProfilePseudonym =>
      'New installs start with a made-up name such as “Quiet Wanderer”, which says nothing about you. You can keep it, or replace it with whatever you like.';

  @override
  String get privacyPublicProfileMeansForYou =>
      'Pick a name and photo you are happy to show in public. If you would rather not be recognised, keep the made-up name you were given and skip the photo.';

  @override
  String get privacyPublicProfileRemovalIsNotDeletion =>
      'Removing your photo later does not delete the copy on the server. Haven replaces your profile with an empty one. The image file stays where it is hosted, and any copy already downloaded stays out there. Treat anything you publish as permanent.';

  @override
  String get privacyPublicProfileDetailKindZero =>
      'The profile is a Nostr “kind 0” event signed by your identity key. Photos are uploaded to a public image host, blossom.primal.net, which sees the image, your public key, and your network address. Haven does not yet let you choose a different host.';

  @override
  String get privacyPublicProfileDetailExifStripped =>
      'Before uploading, Haven re-encodes the picture and drops the hidden data cameras attach, including the GPS position where the photo was taken. That matters here: a holiday snapshot can otherwise carry the coordinates of your home.';

  @override
  String get privacyGroupHowLocationTravelsHeading =>
      'How your location travels';

  @override
  String get privacyRelaysTitle =>
      'Relays: the servers that pass messages along';

  @override
  String get privacyRelaysSubtitle =>
      'Whose computers your updates pass through';

  @override
  String get privacyRelaysWhatIsARelay =>
      'Haven has no server of its own, so your updates travel through other people\'s. These are called relays: small, independent servers that anyone can run. A relay holds an encrypted message briefly, then hands it on when your circle asks for it.';

  @override
  String get privacyRelaysWhyMany =>
      'Haven uses several relays, so no single one can cut you off. If one goes offline, the rest keep working. You choose the relays where invitations reach you; the relays a circle uses are fixed when it is created.';

  @override
  String get privacyRelaysYourLists =>
      'Haven keeps three lists for you. Your inbox relays are where invitations reach you, and your KeyPackage relays are where people fetch the keys they need in order to invite you — Haven publishes both of these lists so others can find them. Your profile relays are different: that is where your name and photo are looked up and published, but the list itself stays on your device and is never published. A relay that only carries your location traffic or invitations therefore has no public list telling it which relays you use for your profile. Each circle also carries its own list, and that is where the circle\'s encrypted updates travel.';

  @override
  String get privacyRelaysMeansForYou =>
      'A relay never sees your location, because it is encrypted before it leaves your phone. It does see what has to be public for people to reach you: your name and photo, the keys others need to invite you, and your relay list itself. Haven starts you with working relays, so there is nothing you must change.';

  @override
  String get privacyRelaysDetailIndexers =>
      'Separately from your own lists, Haven queries a small set of public directory relays to look up other people\'s profiles and keys. It contacts these even if you have configured only private relays of your own. They see your network address and which accounts you asked about.';

  @override
  String get privacyRelaysDetailKeyListIsPublic =>
      'Your KeyPackage-relay list is signed by your identity key and published to the relays already on it. If you add a private relay there, its address becomes public and tied to you. There is no way to keep a relay on that list private.';

  @override
  String get privacyEncryptionTitle => 'How the encryption works';

  @override
  String get privacyEncryptionSubtitle =>
      'One key per circle, and what changes when people join or leave';

  @override
  String get privacyEncryptionPerCircle =>
      'Your location is encrypted on your phone before it leaves, using an open standard called MLS. Each circle is its own encrypted group with its own keys. Nobody outside a circle can read what is sent inside it: not a relay, not Haven, not another circle you belong to.';

  @override
  String get privacyEncryptionWhenSomeoneJoins =>
      'When someone joins, the circle moves to a new key. They can read what is sent after they arrive, and nothing from before it. Haven never sends a new member any past locations.';

  @override
  String get privacyEncryptionWhenSomeoneLeaves =>
      'When someone leaves a circle, it moves to another new key. They stop being able to read anything new once the rest of the circle has caught up, usually within a few minutes, longer for anyone who was offline at the time.';

  @override
  String get privacyEncryptionKeysChangeOnMembership =>
      'Leaving a circle does not take back what its members already saved. Haven changes keys only when someone joins or leaves, never on a timer. So one key can cover weeks of messages, and anything a member saved in that time stays readable to them. They still cannot open anything sent after they left.';

  @override
  String get privacyEncryptionMeansForYou =>
      'Encryption protects you from everyone outside your circles. It cannot protect you from someone who was once inside one. To stop sharing with a particular person, leave the circle you share with them and start a new one without them.';

  @override
  String get privacyEncryptionDetailMls =>
      'MLS (Messaging Layer Security) is the same IETF standard used by other secure messengers. Haven reaches the Nostr network through the Marmot protocol, which defines how MLS groups travel over relays. The key each circle signs with is separate from your public Nostr identity key.';

  @override
  String get privacyEncryptionDetailEpochs =>
      'Each key period is called an epoch, and a circle moves to a new one only when its membership changes. Your device keeps the keys for the current epoch and a few recent ones, enough to open messages still arriving, and drops the rest. A circle whose membership has not changed in months is still on the epoch it started on.';

  @override
  String get privacyWhatOthersSeeTitle =>
      'What members see, and what relays see';

  @override
  String get privacyWhatOthersSeeSubtitle =>
      'The people you share with, and the servers in between';

  @override
  String get privacyWhatOthersSeeMembersHeading => 'The people in your circles';

  @override
  String get privacyWhatOthersSeeMembersExact =>
      'Everyone in a circle sees your exact position on the map, not a rough area. There is no setting that shares a vaguer location with some members and a precise one with others.';

  @override
  String get privacyWhatOthersSeeCannotPause =>
      'While Haven is open and you are in a circle, your position goes out every couple of minutes on its own. There is no pause button: the switch on the Location page only controls whether that continues after you close the app. To stop sharing with a circle, open it and choose Leave Circle.';

  @override
  String get privacyWhatOthersSeeMembersLearnKey =>
      'Joining a circle also shows every member your public key. Through it they can look up your public profile, and anything else you have ever published under that key.';

  @override
  String get privacyWhatOthersSeeCoMemberIp =>
      'Your phone downloads each member\'s profile photo from a server that member chose, without you tapping anything. That server then sees your network address, which places you roughly on the map. A VPN hides this; nothing else does.';

  @override
  String get privacyWhatOthersSeeRelaysHeading => 'The relay operators';

  @override
  String get privacyWhatOthersSeeRelaysCannot =>
      'Relays, the independent servers your updates pass through, cannot read your location, your messages, your circle\'s name, or its member list. Your location updates carry a fresh, single-use sender address instead of your public key. Your profile, invitations and relay lists do carry it, so a relay handling both can often tell you are in a circle, without reading anything inside.';

  @override
  String get privacyWhatOthersSeeRelaysCan =>
      'They do see your network address, when you are online, and how large and how frequent your traffic is. Each circle carries a random tag. A relay can group one circle\'s messages by that tag and estimate how many people are in it, without learning who any of them are.';

  @override
  String get privacyWhatOthersSeeMeansForYou =>
      'Only join a circle with people you would give your home address to. Encryption holds against relays and outsiders, and a VPN hides the address your phone connects from. Nothing protects you from a member who takes a screenshot.';

  @override
  String get privacyWhatOthersSeeDetailTag =>
      'A circle\'s tag stays the same for the life of that circle, so a relay can link all of its messages together indefinitely. That is a property of the underlying protocol, not something Haven can change.';

  @override
  String get commonLearnMore => 'Learn more';

  @override
  String get relaySettingsBackendCaption =>
      'Haven has no server of its own. Your encrypted updates pass through independent servers called relays, which cannot read your location or your messages.';

  @override
  String get privacyWhatOthersSeeScreenshots =>
      'This depends on your phone. On Android, Haven blocks screenshots and screen recording everywhere in the app. On iPhone it cannot: Haven blurs the app-switcher preview, but a member can still capture what is on screen.';

  @override
  String get privacyWhatOthersSeeDetailExpiry =>
      'Haven asks relays to drop location messages after about four minutes. That request is advisory: a relay is free to keep them for longer. Invitations carry no expiry at all, and may sit on your inbox relay indefinitely.';

  @override
  String get privacyGroupTheLimitsHeading => 'The limits';

  @override
  String get privacyInferenceTitle => 'What can still be worked out about you';

  @override
  String get privacyInferenceSubtitle => 'The traces encryption cannot cover';

  @override
  String get privacyInferenceWhatIsMetadata =>
      'Encryption hides what you send. It cannot hide that you sent something. That leftover trail is called metadata: when a message went out, how big it was, and which servers you were connected to. It stays visible even when the contents do not.';

  @override
  String get privacyInferenceActivityPattern =>
      'From that pattern, a relay you use can tell roughly when you are active and how often. Haven also sends an extra update whenever you move about a hundred metres. Over hours, that can show a relay whether you were on the move or staying put. It never shows where.';

  @override
  String get privacyInferencePresence =>
      'While Haven is running it keeps an open connection to your relays. They can see that you are online, and which circle tags you are following, never a circle\'s name or who is in it. That is the price of updates arriving in seconds rather than minutes.';

  @override
  String get privacyInferenceIpHeading => 'Your network address';

  @override
  String get privacyInferenceIpAddress =>
      'Every server Haven talks to sees the address your phone connects from, its IP address: your relays, the map provider, and whoever hosts a member\'s profile photo. Your internet provider sees which of those servers you reached, and when. Haven does nothing to hide either of those on its own.';

  @override
  String get privacyInferenceVpnHeading => 'Whether to use a VPN';

  @override
  String get privacyInferenceVpnHelps =>
      'A VPN replaces your address with its own, so relays and the other servers no longer see where you connect from. It also hides which servers you reach from your internet provider. We recommend Mullvad.';

  @override
  String get privacyInferenceVpnLimits =>
      'It is not a cure-all. A VPN changes nothing about what your circle members see, and it does not hide the timing or size of your traffic from a relay you are talking to. It also moves your trust to the VPN company rather than removing the need to trust anyone.';

  @override
  String get privacyInferenceMeansForYou =>
      'Worried about relays, your internet provider, or the map servers placing you on a map? A VPN is the single most useful thing you can add. Worried about the people in your circles? It will not help at all.';

  @override
  String get privacyInferenceDetailJitter =>
      'Haven varies the gap between updates on purpose, so a short recording shows no clean rhythm. Averaged over many hours the underlying rate can still be estimated. Message sizes are not padded either, and location updates fall in a narrow size range, which makes them recognisable as location updates.';

  @override
  String get privacyInferenceDetailOutOfScope =>
      'Two things are beyond any design choice here: an observer who can watch many relays at once, and your own phone once someone else controls it.';

  @override
  String get commonClearAll => 'Clear All';

  @override
  String commonMemberCount(int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$countString members',
      one: '1 member',
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
  String get circlesTitle => 'Circles';

  @override
  String get circlesRefreshTooltip => 'Refresh circles';

  @override
  String get circlesRequiresIdentity =>
      'Circle creation requires identity setup first';

  @override
  String get circlesCreateCta => 'Create Circle';

  @override
  String get circlesYourCircles => 'Your Circles';

  @override
  String get circlesEmptyTitle => 'No Circles Yet';

  @override
  String get circlesEmptyMessage =>
      'Create a circle to start sharing your location with trusted friends and family.';

  @override
  String get circlesSheetEmptyMessage =>
      'Create a circle to start sharing your location with trusted contacts.';

  @override
  String get circlesLoadError => 'Could not load circles';

  @override
  String get circlesSelectToView => 'Select a circle to view members';

  @override
  String get circlesNoMembers => 'No members in this circle';

  @override
  String get createCircleTitle => 'Add Members';

  @override
  String createCircleSelectedCount(int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    return 'Selected ($countString)';
  }

  @override
  String get createCircleEmptyTitle => 'Add circle members';

  @override
  String get createCircleEmptyMessage =>
      'Search by ID or scan their QR code to add members.';

  @override
  String get createCircleNoValidMembers => 'No valid members to invite';

  @override
  String get createCircleMemberAlreadyAdded => 'Member already added';

  @override
  String get createCircleNoIdInQr => 'No valid ID found in QR code';

  @override
  String get createCircleNoAccountFound =>
      'Couldn\'t find a Haven account for this ID';

  @override
  String get createCircleCouldNotVerify => 'Could not verify member';

  @override
  String get createCircleSomethingWentWrong => 'Something went wrong';

  @override
  String get nameCircleTitle => 'Name Your Circle';

  @override
  String nameCircleMembersToInvite(int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$countString members will be invited',
      one: '1 member will be invited',
    );
    return '$_temp0';
  }

  @override
  String get nameCircleNameLabel => 'Circle Name';

  @override
  String get nameCircleNameHint => 'e.g., Family, Close Friends';

  @override
  String get nameCircleNameEmptyError => 'Please enter a circle name';

  @override
  String get nameCircleNameTooLongError => 'Name must be 50 characters or less';

  @override
  String get nameCircleSharingInfo =>
      'Everyone in this circle can see each other\'s location, and each other\'s public name and photo. Your name and photo are public on the Nostr network, not private to this circle. This circle stays separate from any others you\'re in, so its members can\'t see your other circles or who\'s in them.';

  @override
  String get nameCircleCreateCta => 'Create Circle';

  @override
  String get nameCircleStageCreatingGroup => 'Creating secure group...';

  @override
  String get nameCircleStageSendingInvites => 'Sending invitations...';

  @override
  String get nameCircleStageComplete => 'Done!';

  @override
  String nameCircleProgressSemantics(String stage) {
    return 'Creation progress: $stage';
  }

  @override
  String nameCirclePercentComplete(int percent) {
    final intl.NumberFormat percentNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String percentString = percentNumberFormat.format(percent);

    return '$percentString percent complete';
  }

  @override
  String nameCircleCreatedSnack(String name, int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Circle \"$name\" created! $countString invitations sent.',
      one: 'Circle \"$name\" created! 1 invitation sent.',
    );
    return '$_temp0';
  }

  @override
  String get nameCircleIdentityError =>
      'Identity error. Please check your identity setup.';

  @override
  String get nameCircleCreateError =>
      'Failed to create circle. Please try again.';

  @override
  String addMemberTitle(String circleName) {
    return 'Add to $circleName';
  }

  @override
  String get addMemberInfo =>
      'Once they accept, they will see everyone\'s location from that point on, never anything sent before they joined. They will also see the public keys of everyone already in this circle.';

  @override
  String get addMemberAlreadyInCircle => 'Already in this circle';

  @override
  String addMemberSendInvitation(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Send invitations',
      one: 'Send invitation',
    );
    return '$_temp0';
  }

  @override
  String addMemberSendingInvitation(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Sending invitations...',
      one: 'Sending invitation...',
    );
    return '$_temp0';
  }

  @override
  String addMemberSentToCircle(int count, String circleName) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Invitations sent to $circleName',
      one: 'Invitation sent to $circleName',
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

    return 'Invitations sent ($sentString of $totalString). Delivery pending for the rest.';
  }

  @override
  String get addMemberError => 'Failed to add member. Please try again.';

  @override
  String get qrScannerTitle => 'Scan QR Code';

  @override
  String get qrScannerToggleFlash => 'Toggle flash';

  @override
  String get qrScannerSwitchCamera => 'Switch camera';

  @override
  String get qrScannerInstruction => 'Position the QR code within the frame';

  @override
  String get qrScannerScanning => 'Scanning...';

  @override
  String get circleMemberInvitationPending => 'Invitation Pending';

  @override
  String get circleMemberNoRecentLocation => 'No recent location';

  @override
  String get circleMemberRemoveTooltip => 'Remove from circle';

  @override
  String get circleMemberAdmin => 'Admin';

  @override
  String get circleMemberHintPending => 'invitation pending';

  @override
  String get circleMemberHintNoLocation => 'no location available';

  @override
  String get circleMemberHintMember => 'member';

  @override
  String get circleMemberHintTapToCenter =>
      'tap to center map on their location';

  @override
  String get pendingMemberRetryTooltip => 'Retry validation';

  @override
  String get pendingMemberRemoveTooltip => 'Remove from list';

  @override
  String get pendingMemberValidating => 'Validating';

  @override
  String get pendingMemberValid => 'Valid';

  @override
  String get pendingMemberWarning => 'Warning';

  @override
  String get pendingMemberCheckingAvailability => 'Checking availability...';

  @override
  String get pendingMemberReadyToInvite => 'Ready to invite';

  @override
  String get pendingMemberNeedsUpdate => 'Needs to update Haven';

  @override
  String get memberSearchHint => 'Enter member ID...';

  @override
  String get memberSearchPasteTooltip => 'Paste from clipboard';

  @override
  String get memberSearchAddTooltip => 'Add member';

  @override
  String get memberSearchScanTooltip => 'Scan QR Code';

  @override
  String get memberSearchHelper => 'Ask contacts for their Haven QR code or ID';

  @override
  String get memberSearchNoValidId => 'No valid Haven ID found';

  @override
  String get memberSearchAlreadyAdded => 'Member already added';

  @override
  String selectedMembersMore(int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    return '+$countString more';
  }

  @override
  String get invitationStatusPending => 'Invitation Pending';

  @override
  String get invitationStatusActive => 'Active';

  @override
  String get invitationStatusDeclined => 'Declined';

  @override
  String invitationStatusSemantics(String label) {
    return 'Invitation status: $label';
  }

  @override
  String invitationCardSemantics(String circleName, String inviter, int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    return 'Invitation to join $circleName, invited by $inviter, $countString members';
  }

  @override
  String invitationCardInvitedBySemantics(String inviter) {
    return 'Invited by cryptographic identifier $inviter';
  }

  @override
  String invitationCardInvitedBy(String inviter) {
    return 'Invited by: $inviter';
  }

  @override
  String invitationCardMemberCount(int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$countString members',
      one: '1 member',
    );
    return '$_temp0';
  }

  @override
  String get invitationCardJustNow => 'Just now';

  @override
  String invitationCardDaysAgo(int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    return '${countString}d ago';
  }

  @override
  String invitationCardHoursAgo(int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    return '${countString}h ago';
  }

  @override
  String invitationCardMinutesAgo(int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    return '${countString}m ago';
  }

  @override
  String get invitationCardDecline => 'Decline';

  @override
  String get invitationCardAccept => 'Accept';

  @override
  String get invitationAcceptedSnack => 'Invitation accepted';

  @override
  String get invitationDeclinedSnack => 'Invitation declined';

  @override
  String get invitationAcceptError =>
      'Failed to accept invitation. Please try again.';

  @override
  String get invitationDeclineError =>
      'Failed to decline invitation. Please try again.';

  @override
  String get circleSelectorLabel => 'Circle selector';

  @override
  String get circleSelectorPlaceholder => 'Select a circle';

  @override
  String get circleSelectorNewCircle => 'New Circle';

  @override
  String get circleSelectorLoadError => 'Failed to load circles';

  @override
  String get circleSelectorExpandedAnnouncement => 'Circle list expanded';

  @override
  String get circleSelectorCollapsedAnnouncement => 'Circle list collapsed';

  @override
  String get circleDetailsButtonTooltip => 'Circle details';

  @override
  String get circleDetailsTitle => 'Circle details';

  @override
  String circleDetailsMembersWithEpoch(String members, int epoch) {
    final intl.NumberFormat epochNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String epochString = epochNumberFormat.format(epoch);

    return '$members · epoch $epochString';
  }

  @override
  String get circleDetailsRelaysHeading => 'Relays for this circle';

  @override
  String get circleDetailsNoRelays => '(none recorded)';

  @override
  String get circleDetailsRelaysNote =>
      'These relays were copied from your inbox relays when this circle was created, and cannot be changed yet. Later edits to your personal relay list do not change them.';

  @override
  String get circleDetailsAddMember => 'Add member';

  @override
  String get circleDetailsLeaveCircle => 'Leave Circle';

  @override
  String get leaveCircleDialogTitle => 'Leave Circle';

  @override
  String get leaveCircleDialogBody =>
      'Leave this circle? You will stop sending your location to its members and stop seeing theirs. The last position you sent stays on their phones for up to a day. You cannot undo this: you would need a new invitation to rejoin.';

  @override
  String get leaveCircleConfirm => 'Leave';

  @override
  String get leaveCircleIdentityUnavailable => 'Identity unavailable';

  @override
  String get leaveCircleSuccess => 'Left circle successfully';

  @override
  String get leaveCircleError => 'Failed to leave circle';

  @override
  String get circleBlockedBannerTitle => 'This circle can’t be updated';

  @override
  String get circleBlockedBannerBody =>
      'Something went wrong with this circle’s encryption, so Haven can no longer send or receive updates in it. You can still see what you last knew below, or leave the circle.';

  @override
  String get legacyCircleBannerTitle => 'This circle needs to be re-created';

  @override
  String get legacyCircleBannerBody =>
      'Haven’s encryption engine was upgraded, so this circle can no longer be used. Re-create it to keep sharing locations with the same people. You’ll need to invite them again.';

  @override
  String get legacyCircleRecreateCta => 'Re-create Circle';

  @override
  String get legacyCircleRemoveCta => 'Remove';

  @override
  String get legacyCircleRemoveDialogTitle => 'Remove circle?';

  @override
  String get legacyCircleRemoveDialogBody =>
      'This circle can no longer be used and will be removed from your list. This does not affect any new circle you create to replace it.';

  @override
  String get legacyCircleRemoveConfirm => 'Remove';

  @override
  String get legacyCutoverExplainerTitle => 'Haven has been updated';

  @override
  String get legacyCutoverExplainerIdentityUnchanged =>
      'Your identity and public profile are unchanged. There is nothing you need to do for those.';

  @override
  String get legacyCutoverExplainerCirclesNeedRecreation =>
      'For improved security, your circles need to be re-created and their members re-invited before you can share locations in them again.';

  @override
  String get legacyCutoverExplainerAcknowledge => 'Got it';

  @override
  String get relaySettingsLegacyRetractionPending =>
      'Haven is still asking relays to drop some old data from the recent security update.';

  @override
  String get circlesPanelCollapsedAnnouncement => 'Circles panel collapsed';

  @override
  String get circlesPanelExpandedAnnouncement => 'Circles panel expanded';

  @override
  String get circlesPanelSlightlyOpenAnnouncement =>
      'Circles panel slightly open';

  @override
  String get circlesPanelHalfOpenAnnouncement => 'Circles panel half open';

  @override
  String get circleMemberAnnouncementSelf => 'you';

  @override
  String get circleMemberAnnouncementFallback => 'member';

  @override
  String get invitationsRefreshTooltip => 'Refresh invitations';

  @override
  String get invitationsLoadError => 'Could not load invitations';

  @override
  String get invitationsEmptyTitle => 'No Invitations';

  @override
  String get invitationsEmptyMessage =>
      'When someone invites you to a circle, it will appear here.';

  @override
  String get refreshRingSemanticNoInbox =>
      'No inbox configured, opens relay settings';

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
      other: '$checkedString of $totalString relays checked',
      one: '$checkedString of 1 relay checked',
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
      other: 'All $totalString relays responded',
      one: 'The relay responded',
    );
    return '$_temp0';
  }

  @override
  String get refreshRingSemanticAllError => 'No relays responded';

  @override
  String refreshRingSemanticPartial(int ok, int total) {
    final intl.NumberFormat okNumberFormat = intl.NumberFormat.decimalPattern(
      localeName,
    );
    final String okString = okNumberFormat.format(ok);
    final intl.NumberFormat totalNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String totalString = totalNumberFormat.format(total);

    return '$okString of $totalString relays responded';
  }

  @override
  String get refreshRingAnnouncementChecking => 'Checking relays';

  @override
  String get refreshRingAnnouncementAllOk => 'All relays responded';

  @override
  String refreshRingAnnouncementPartial(int ok, int total) {
    final intl.NumberFormat okNumberFormat = intl.NumberFormat.decimalPattern(
      localeName,
    );
    final String okString = okNumberFormat.format(ok);
    final intl.NumberFormat totalNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String totalString = totalNumberFormat.format(total);

    return '$okString of $totalString relays responded';
  }

  @override
  String get refreshRingAnnouncementAllError => 'No relays could be reached';

  @override
  String get refreshRingAnnouncementNoInbox => 'No inbox configured';

  @override
  String refreshRingSemanticAllFound(int total) {
    final intl.NumberFormat totalNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String totalString = totalNumberFormat.format(total);

    String _temp0 = intl.Intl.pluralLogic(
      total,
      locale: localeName,
      other: 'All $totalString relays have your data',
      one: 'The relay has your data',
    );
    return '$_temp0';
  }

  @override
  String get refreshRingSemanticNoneFound => 'No relays have your data';

  @override
  String refreshRingSemanticPartialFound(int ok, int total) {
    final intl.NumberFormat okNumberFormat = intl.NumberFormat.decimalPattern(
      localeName,
    );
    final String okString = okNumberFormat.format(ok);
    final intl.NumberFormat totalNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String totalString = totalNumberFormat.format(total);

    return '$okString of $totalString relays have your data';
  }

  @override
  String get refreshRingAnnouncementAllFound => 'All relays have your data';

  @override
  String refreshRingAnnouncementPartialFound(int ok, int total) {
    final intl.NumberFormat okNumberFormat = intl.NumberFormat.decimalPattern(
      localeName,
    );
    final String okString = okNumberFormat.format(ok);
    final intl.NumberFormat totalNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String totalString = totalNumberFormat.format(total);

    return '$okString of $totalString relays have your data';
  }

  @override
  String get refreshRingAnnouncementNoneFound => 'No relays have your data';

  @override
  String get identityTitle => 'Identity';

  @override
  String get identityLoadError =>
      'Something went wrong loading your identity. Please try again.';

  @override
  String get identityMissingTitle => 'No Identity';

  @override
  String get identityMissingMessage =>
      'Your identity is gone. Set up a new one to keep using Haven.';

  @override
  String get identitySetUpCta => 'Set Up Identity';

  @override
  String get identityPublicKeyQrTitle => 'Public Key QR';

  @override
  String get identityPublicKeyQrSubtitle => 'How others invite you to circles';

  @override
  String get identityAdvancedTitle => 'Advanced';

  @override
  String get identityAdvancedSubtitle => 'Public key, secret key, delete';

  @override
  String get profileIsPublicNoticeTitle => 'Profile is public';

  @override
  String get profileIsPublicNoticeBody =>
      'Your display name and photo are visible to anyone on the Nostr network, not just members of your circles. Share only what you\'re comfortable making public.';

  @override
  String get identityRefreshProfileTooltip => 'Refresh public profile';

  @override
  String get identityAdvancedExportError =>
      'Failed to export secret key. Please try again.';

  @override
  String get identityAdvancedDeleteTitle => 'Delete Identity?';

  @override
  String get identityAdvancedDeleteBody =>
      'This deletes your identity and all circle data from this phone. Anything already published under it, including your name, photo and keys, stays on the relays that have it. Make sure you have backed up your secret key if you want to recover it.';

  @override
  String get identityAdvancedDeleteConfirm => 'Delete';

  @override
  String get identityAdvancedDeletedSnack => 'Identity deleted';

  @override
  String get identityAdvancedDeleteError =>
      'Failed to delete identity. Please try again.';

  @override
  String identityAdvancedCopiedToClipboard(String label) {
    return '$label copied to clipboard';
  }

  @override
  String get identityAdvancedSecretCopiedWarning =>
      'Secret key copied. Warning: other apps may read your clipboard. Paste it somewhere safe and clear your clipboard.';

  @override
  String get identityAdvancedMissingBody => 'No identity is set up.';

  @override
  String get identityAdvancedPublicKeyLabel => 'Public Key';

  @override
  String get identityAdvancedPublicKeyHexLabel => 'Public Key (hex)';

  @override
  String get identityAdvancedCopyValue => 'Public key';

  @override
  String get identityAdvancedCopyPublicKeyTooltip => 'Copy public key';

  @override
  String get identityAdvancedCopyHexTooltip => 'Copy hex';

  @override
  String get identityAdvancedSecretKeyTitle => 'Secret Key';

  @override
  String get identityAdvancedSecretKeyWarning =>
      'Your secret key gives full access to your identity. Never share it with anyone.';

  @override
  String get identityAdvancedRevealSecretKey => 'Reveal Secret Key';

  @override
  String get identityAdvancedHideSecretKey => 'Hide Secret Key';

  @override
  String get identityAdvancedCopySecretKeyTooltip => 'Copy secret key';

  @override
  String get identityAdvancedDeleteIdentityCta => 'Delete Identity';

  @override
  String get qrCodeLoadError =>
      'Something went wrong loading your public key. Please try again.';

  @override
  String get qrCodeYourPublicKeyLabel => 'Your public key';

  @override
  String get qrCodeWhatIsThisTitle => 'What is this?';

  @override
  String get qrCodeExplainerKeys =>
      'Haven runs on Nostr, an open network with no company account or sign-up behind it. Your identity is just a pair of keys: a secret key only you hold, and this public key made from it.';

  @override
  String get qrCodeExplainerUsername =>
      'Your public key works like a username that is safe to share. People scan this code, or paste your public key, to invite you to a circle. Sharing it cannot reveal where you are. Your display name and photo are already public, so this adds nothing.';

  @override
  String get displayNameCardTitle => 'Display Name';

  @override
  String get displayNameCardLoadError =>
      'Could not load your display name. Try again later.';

  @override
  String get displayNameCardHint => 'Enter your display name';

  @override
  String get displayNameCardSavedLabel => 'Display name saved';

  @override
  String get displayNameCardSaveLabel => 'Save display name';

  @override
  String get displayNameCardSavingLabel => 'Saving display name';

  @override
  String get displayNameCardRetryLabel => 'Save failed. Retry';

  @override
  String get displayNameCardSavedAnnouncement => 'Display name saved';

  @override
  String get displayNameCardSaveFailedAnnouncement => 'Save failed, try again';

  @override
  String keyDisplayCopiedToClipboard(String label) {
    return '$label copied to clipboard';
  }

  @override
  String keyDisplaySemantics(String label, String state) {
    return '$label: $state';
  }

  @override
  String get keyDisplayStateRevealed => 'revealed';

  @override
  String get keyDisplayStateHidden => 'hidden';

  @override
  String get keyDisplayHideTooltip => 'Hide';

  @override
  String get keyDisplayRevealTooltip => 'Reveal';

  @override
  String get keyDisplayCopyTooltip => 'Copy';

  @override
  String get keyDisplayCompactCopied => 'Key copied to clipboard';

  @override
  String get keyDisplayCompactTapToCopy => 'Tap to copy';

  @override
  String get npubQrCopiedSnack => 'Public key copied to clipboard';

  @override
  String get npubQrCopyButton => 'Copy public key';

  @override
  String get circleMemberPublicKeyCopied => 'Public key copied to clipboard';

  @override
  String get circleMemberCopyPublicKeyHint => 'Copy public key';

  @override
  String get circleMemberSetNicknameMenuItem => 'Set Nickname';

  @override
  String get circleMemberCopyPublicKeyMenuItem => 'Copy Public Key';

  @override
  String get memberProfileRefreshErrorGeneric =>
      'Could not refresh profiles. Please try again.';

  @override
  String get memberDetailSheetTitle => 'Member Details';

  @override
  String get memberNicknameSheetHint => 'Enter a nickname';

  @override
  String get memberNicknameSheetLabel => 'Nickname';

  @override
  String get memberNicknameSheetSave => 'Save Nickname';

  @override
  String get memberNicknameSheetClear => 'Clear Nickname';

  @override
  String get memberNicknameSheetSavedAnnouncement => 'Nickname saved';

  @override
  String get memberNicknameSheetClearedAnnouncement => 'Nickname cleared';

  @override
  String get npubQrScanLabel => 'Scan to add me';

  @override
  String get npubQrSemanticsLabel => 'QR code for your public identity';

  @override
  String get photoHeaderRemoveTitle => 'Remove profile photo?';

  @override
  String get photoHeaderRemoveBody =>
      'This takes your photo off your public profile. The image file stays on the server that hosts it, and copies others already downloaded stay with them.';

  @override
  String get photoHeaderEditPhoto => 'Edit Photo';

  @override
  String get photoHeaderRemove => 'Remove';

  @override
  String get photoHeaderViewPhotoSemantics => 'View profile photo';

  @override
  String get photoHeaderAddPhotoSemantics => 'Add profile photo';

  @override
  String get photoHeaderChangePhotoSemantics => 'Change profile photo';

  @override
  String get avatarPickerPhotoUpdated =>
      'Photo updated. Published to your public Nostr profile.';

  @override
  String get avatarPickerPhotoRemoved => 'Photo removed.';

  @override
  String get avatarPickerRemoveError =>
      'Could not remove your photo. Please try again.';

  @override
  String get avatarPickerUpdateError =>
      'Could not update your photo. Please try again.';

  @override
  String get avatarPickerCropTitle => 'Crop photo';

  @override
  String get avatarPickerCropDone => 'Done';

  @override
  String get avatarPickerCropCancel => 'Cancel';

  @override
  String get avatarFullscreenClose => 'Close';

  @override
  String get avatarFullscreenSemantics => 'Profile photo, full screen';

  @override
  String get avatarFullscreenLoadError => 'Couldn\'t load photo';

  @override
  String get mapInitializing => 'Initializing...';

  @override
  String get mapInitFailedTitle => 'Initialization Failed';

  @override
  String get mapInitFailedMessage => 'Failed to initialize location services.';

  @override
  String get mapInitFailedRetry => 'Initialization failed. Please try again.';

  @override
  String get mapLocationOffMessage =>
      'Turn on location to see yourself and your circles on the map.';

  @override
  String get mapGettingLocation => 'Getting location...';

  @override
  String get mapLoadingMap => 'Loading map...';

  @override
  String get mapLocationOffTitle => 'Location is off';

  @override
  String get mapLocationErrorTitle => 'Location Error';

  @override
  String get mapLocationUnavailable => 'Location temporarily unavailable';

  @override
  String get mapThisLocation => 'this location';

  @override
  String get mapMemberFallbackName => 'member';

  @override
  String mapOpenInAppleMapsTitle(String label) {
    return 'Open $label in Apple Maps?';
  }

  @override
  String get mapOpenInAppleMapsBody =>
      'Only the map coordinate is sent to Apple Maps, never a name or identity.';

  @override
  String get mapOpenInAppleMapsConfirm => 'Open in Apple Maps';

  @override
  String get mapOpenMapsError => 'Could not open Maps';

  @override
  String get mapControlsZoomIn => 'Zoom in';

  @override
  String get mapControlsZoomOut => 'Zoom out';

  @override
  String get mapControlsRecenter => 'Recenter';

  @override
  String get mapControlsRecenterFab => 'Recenter on my location';

  @override
  String get mapAttributionCreditsButton => 'Map credits and licence';

  @override
  String userLocationMarkerSemantics(String accuracy) {
    return 'Your location marker$accuracy';
  }

  @override
  String userLocationMarkerAccuracy(int meters) {
    final intl.NumberFormat metersNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String metersString = metersNumberFormat.format(meters);

    return '. Accuracy: $metersString meters';
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
      other: '$countString minutes ago',
      one: '1 minute ago',
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
      other: '$countString hours ago',
      one: '1 hour ago',
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
      other: '$countString days ago',
      one: '1 day ago',
    );
    return '$_temp0';
  }

  @override
  String memberMarkerNamedSemantics(String name) {
    return '$name member marker';
  }

  @override
  String get memberMarkerGenericSemantics => 'Member marker';

  @override
  String memberMarkerLastSeenSemantics(String base, String age) {
    return '$base, last seen $age';
  }

  @override
  String memberMarkerOffScreenSemantics(String name, String direction) {
    return '$name is off-screen to the $direction, tap to view';
  }

  @override
  String memberMarkerOffScreenGenericSemantics(String direction) {
    return 'A member is off-screen to the $direction, tap to view';
  }

  @override
  String get compassNorth => 'north';

  @override
  String get compassNorthEast => 'north-east';

  @override
  String get compassEast => 'east';

  @override
  String get compassSouthEast => 'south-east';

  @override
  String get compassSouth => 'south';

  @override
  String get compassSouthWest => 'south-west';

  @override
  String get compassWest => 'west';

  @override
  String get compassNorthWest => 'north-west';

  @override
  String get commonAdd => 'Add';

  @override
  String get addRelaySheetTitleInbox => 'Add Inbox relay';

  @override
  String get addRelaySheetTitleKeyPackage => 'Add KeyPackage relay';

  @override
  String get addRelaySheetTitleProfile => 'Add Profile relay';

  @override
  String get addRelaySheetHint => 'wss://relay.example.com';

  @override
  String get addRelaySheetPasteTooltip => 'Paste from clipboard';

  @override
  String get addRelaySheetErrorEmpty => 'Enter a relay address.';

  @override
  String get addRelaySheetErrorInsecureScheme =>
      'Use wss:// so traffic to this relay is encrypted.';

  @override
  String get addRelaySheetErrorHasCredentials =>
      'Relay URL must not contain credentials.';

  @override
  String get addRelaySheetErrorInvalidFormat =>
      'Enter a relay address like wss://relay.example.com.';

  @override
  String get avatarSemanticsLabel => 'User avatar';

  @override
  String avatarSemanticsFor(String initials) {
    return 'for $initials';
  }

  @override
  String get avatarSemanticsOnline => 'online';

  @override
  String get avatarSemanticsOffline => 'offline';
}
