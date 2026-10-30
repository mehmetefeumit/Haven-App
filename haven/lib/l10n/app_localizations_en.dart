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
  String get onboardingValueProp2Title => 'No one can shut it down';

  @override
  String get onboardingValueProp3Title => 'No account needed';

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
  String get settingsRelaysTitle => 'Relays';

  @override
  String get settingsLocationTitle => 'Location';

  @override
  String get settingsLocationSubtitleOn => 'Background sharing on';

  @override
  String get settingsLocationSubtitleOff => 'Only while Haven is open';

  @override
  String get settingsMapStyleTitle => 'Map style';

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
  String get locationSettingsBatteryOptNote =>
      'Battery optimization is still on for Haven. Some phones use it to stop background sharing without warning. Exclude Haven to keep sharing reliable.';

  @override
  String get locationSettingsErrorSnack => 'Something went wrong';

  @override
  String get locationSettingsIntro =>
      'Haven shares your location with your circles whenever the app is open. Turn this on and your circles keep seeing it while Haven is in the background. If the system closes Haven, your own sharing stops: Haven may still wake up to fetch your circles\' locations, but never to send yours. On Android, sharing survives swiping Haven away and starts again by itself after a reboot. On iPhone, sharing stays stopped until you open Haven.';

  @override
  String get locationSettingsToggleTitle => 'Share in background';

  @override
  String get locationSettingsToggleSubtitle =>
      'Keep sharing while Haven runs in the background';

  @override
  String get locationSettingsIosLimitedNote =>
      'Sharing keeps working in the background with your current permission, and iOS shows its blue location bar at the top of the screen while it does. Choose \'Always\' for Haven in Settings so Haven can also catch up on your circles\' locations after iOS closes the app. Under \'Always\', iOS may show its location arrow in the status bar instead of the bar. Your own sharing resumes when you reopen Haven.';

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
      'While background sharing is on, Haven keeps a location session running so your circles keep seeing you.';

  @override
  String get locationSettingsIosIndicatorArrow =>
      'iOS shows its location arrow in the status bar while Haven uses your location, and keeps that same arrow next to Haven in Location Services for a while afterwards.';

  @override
  String get locationSettingsIosIndicatorBar =>
      'With your \'Always\' permission, iOS shows its blue location bar at the top of the screen while Haven uses your location.';

  @override
  String get locationDisclosureTitle => 'Sharing your location';

  @override
  String get locationDisclosureWhy =>
      'Haven shows your live location to the people in the circles you choose, and shows you theirs on the map. To do this, Haven needs permission to use your device’s precise location.';

  @override
  String get locationDisclosureHow =>
      'Your location is end-to-end encrypted on your device, so only the members of the circles you choose can read it, not Haven. Haven runs no servers of its own: your encrypted updates pass through independent relays run by other people, which see your network address but never where you are. Drawing the map asks Stadia Maps for the areas around you and your circle, so it learns roughly where that is, but never your name, your key, or who is in your circles. Stadia Maps says it does not sell or trade personal information, sets no cookies on your device, and keeps server logs for about two weeks — its own policy, which Haven cannot enforce.';

  @override
  String get locationDisclosureSharing =>
      'While Haven is open and you are in a circle, your location is sent automatically every couple of minutes. There is no pause. To stop sharing with a circle, leave it.';

  @override
  String get locationDisclosureBackgroundAndroid =>
      'This app uses location data to enable sharing with your circles even when the app is closed or not in use.';

  @override
  String get locationDisclosureBackgroundIos =>
      'This app uses location data to enable sharing with your circles even when Haven is in the background and you are not using it. If iOS closes Haven, sharing stops until you open it again — Haven may still wake up to fetch your circles’ locations, but never to send yours.';

  @override
  String get locationDisclosureManage =>
      'You can turn background sharing off at any time in Settings → Location.';

  @override
  String get locationDisclosureAgree => 'Agree';

  @override
  String get locationDisclosureNotNow => 'Not now';

  @override
  String get fgsNotificationSharing =>
      'Haven is sending and receiving location information';

  @override
  String get fgsNotificationPaused =>
      'Haven is paused — open the app to resume sharing';

  @override
  String get fgsNotificationOpen => 'Haven is open';

  @override
  String get fgsChannelName => 'Location Sharing';

  @override
  String get fgsChannelDescription =>
      'Keeps Haven sharing your encrypted location in the background.';

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
  String get aboutFooterLicense => 'Licensed under the MIT License';

  @override
  String aboutFooterVersion(String version) {
    return 'Version $version';
  }

  @override
  String get relaySettingsBackendCaption =>
      'Haven has no server of its own. Your encrypted updates pass through independent servers called relays, which cannot read your location or your messages.';

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
          'Circle \"$name\" created. $sentString of $totalString invitations sent so far. Haven keeps sending the rest while the app is open, for up to a day.',
      one:
          'Circle \"$name\" created. $sentString of 1 invitation sent so far. Haven keeps sending it while the app is open, for up to a day.',
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
  String nameCircleRosterFullError(int limit) {
    final intl.NumberFormat limitNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String limitString = limitNumberFormat.format(limit);

    return 'You can be in up to $limitString circles at a time. Leave a circle to make room for a new one.';
  }

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
          '$sentString of $totalString invitations to $circleName sent so far. Haven keeps sending the rest while the app is open, for up to a day.',
      one:
          '$sentString of 1 invitation to $circleName sent so far. Haven keeps sending it while the app is open, for up to a day.',
    );
    return '$_temp0';
  }

  @override
  String addMemberReinviteNeeded(String circleName) {
    return 'Haven can’t send the invitation to $circleName. Remove that person and add them again.';
  }

  @override
  String get memberCannotReceiveInvitations =>
      'Haven can’t invite everyone you chose, because it couldn’t find where to send at least one of their invitations. Ask the people you chose to check that their app can receive invitations, then try again.';

  @override
  String get missedInvitationsShowWho => 'Show who';

  @override
  String missedInvitationsTitle(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Invitations not sent',
      one: 'Invitation not sent',
    );
    return '$_temp0';
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
  String get circleMemberNoRecentLocation => 'No recent location';

  @override
  String get circleMemberRemoveTooltip => 'Remove from circle';

  @override
  String circleMemberRemoveDialogTitle(String name) {
    return 'Remove $name?';
  }

  @override
  String get circleMemberRemoveDialogBody =>
      'They stop being able to read anything new from this circle once the rest of it has caught up, usually within a few minutes, longer for anyone who was offline at the time. Whatever they already received stays on their phone. To undo this you would have to invite them again.';

  @override
  String get circleMemberRemoveConfirm => 'Remove';

  @override
  String circleMemberRemoveInProgress(String name) {
    return 'Removing $name…';
  }

  @override
  String circleMemberRemoveSuccess(String name) {
    return 'Removed $name from the circle';
  }

  @override
  String circleMemberRemoveError(String name) {
    return 'Couldn\'t remove $name. Nothing changed — check your connection and try again.';
  }

  @override
  String circleMemberRemoveAwaitingAnnouncement(String name) {
    return 'Still removing $name: waiting for the relays. Until it’s done, nothing is shared with this circle.';
  }

  @override
  String get circleMemberAdmin => 'Admin';

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
  String get pendingMemberNeedsUpdate => 'Needs to update or open Haven';

  @override
  String get memberKeyPackageStale =>
      'Haven can’t invite them right now. Ask them to open Haven, then try again.';

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
  String get memberPickerSectionRoster => 'Members of your circles';

  @override
  String get memberPickerTierRoster => 'Member of your circles';

  @override
  String get memberPickerNoMatches => 'No matches in your circles';

  @override
  String get memberPickerLoading => 'Loading people from your circles';

  @override
  String get memberPickerDirectoryUnavailable =>
      'Couldn\'t load who\'s in your circles right now';

  @override
  String memberPickerMatchesAnnouncement(int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    return 'Matches: $countString';
  }

  @override
  String get memberPickerReasonSelf => 'This is your own ID';

  @override
  String get memberPickerReadPublicKey => 'Read public key aloud';

  @override
  String get memberPickerSectionRecent => 'Recently in your circles';

  @override
  String get memberPickerTierRecent => 'Recently in your circles';

  @override
  String get memberPickerNicknameNote =>
      'Your nickname for them, not their public name';

  @override
  String memberPickerCollisionCircleLabel(String circleName) {
    return 'Circle: $circleName';
  }

  @override
  String get memberPickerStrangerLookupNote =>
      'Haven asked a relay to look up this person\'s published name. That relay can see this device asked about this key just now — but the request carries no signature, so it isn\'t tied to your Haven identity. No photo is downloaded yet.';

  @override
  String selectedMembersMore(int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    return '+$countString more';
  }

  @override
  String get invitationCardHeading => 'Circle invitation';

  @override
  String invitationCardSemantics(String inviter) {
    return 'Invitation to join a circle, sent by $inviter';
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
  String get invitationCardNicknameNote =>
      'Your nickname for them, not their public name';

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
  String invitationNeedsNewInviteError(String name) {
    return 'This invitation can no longer be used. Ask $name to invite you again. They may need to update Haven first.';
  }

  @override
  String get rejoinDialogTitle => 'Join this circle again?';

  @override
  String rejoinDialogBody(String inviterName, String circleName) {
    return '$inviterName invited you to “$circleName”, which is already on this phone. This can happen if you were removed from it and invited back. Joining again replaces this phone’s copy of the circle. Decline ends this invitation for good; Cancel keeps it for later.';
  }

  @override
  String rejoinDialogBodyUnnamed(String circleName) {
    return 'You were invited to “$circleName”, which is already on this phone. This can happen if you were removed from it and invited back. Joining again replaces this phone’s copy of the circle. Decline ends this invitation for good; Cancel keeps it for later.';
  }

  @override
  String get rejoinDialogConfirm => 'Join again';

  @override
  String invitationRosterFullError(int limit) {
    final intl.NumberFormat limitNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String limitString = limitNumberFormat.format(limit);

    return 'You can be in up to $limitString circles at a time. Leave a circle, then accept this invitation.';
  }

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
  String circleDetailsMetaWithExpiry(String meta, String expiry) {
    return '$meta · expiry $expiry';
  }

  @override
  String circleDetailsExpiryMinutesShort(int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$countString min',
      one: '$countString min',
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
      other: '$countString sec',
      one: '$countString sec',
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
      other: 'about $countString minutes',
      one: 'about $countString minute',
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
      other: '$countString seconds',
      one: '$countString second',
    );
    return '$_temp0';
  }

  @override
  String circleDetailsExpirySemantics(String meta, String expiry) {
    return '$meta. Haven asks relays to drop, after $expiry, the location updates you send to this circle.';
  }

  @override
  String get circleDetailsRelaysHeading => 'Relays for this circle';

  @override
  String get circleDetailsNoRelays => '(none recorded)';

  @override
  String get circleDetailsRelaysNote =>
      'These relays came from the lists the invited members published — or, if they had none, from your inbox relays or ones Haven chose. They cannot be changed yet, and later edits to your relay list do not affect them.';

  @override
  String get circleDetailsAddMember => 'Add member';

  @override
  String get circleDetailsLeaveCircle => 'Leave Circle';

  @override
  String get circleDetailsLeavingInProgress => 'Leaving circle…';

  @override
  String get leaveCircleDialogTitle => 'Leave Circle';

  @override
  String get leaveCircleDialogBody =>
      'Leave this circle? You will stop sending your location to its members and stop seeing theirs. The last position you sent stays on their phones for up to a day. You cannot undo this: you would need a new invitation to rejoin.';

  @override
  String get leaveDisbandedCircleDialogBody =>
      'This circle has ended, so nothing is shared with it any more. Leaving removes it from this phone.';

  @override
  String get leaveCircleDialogAdminNote =>
      'You’re an admin of this circle. Before you leave, Haven tries to make another member an admin so the circle can keep working.';

  @override
  String get leaveCircleConfirm => 'Leave';

  @override
  String get leaveCircleIdentityUnavailable => 'Identity unavailable';

  @override
  String get leaveCircleSuccess => 'Left circle successfully';

  @override
  String get leaveCircleError => 'Failed to leave circle';

  @override
  String get legacyCircleRecreateCta => 'Re-create Circle';

  @override
  String get storageResetTitle => 'Haven has been updated';

  @override
  String get storageResetKept =>
      'Your identity is unchanged, and the public profile you already published stays as it is.';

  @override
  String get storageResetLost =>
      'To move to Haven’s new encryption engine, circles made before this update were removed. Re-create them and invite their members again. Nicknames you gave people before this update, and any profile change that had not finished saving by then, were also removed.';

  @override
  String get storageResetRelays =>
      'This update reset your relay settings to Haven’s defaults. These settings won’t be published until you continue or come back from Relay settings, so you can add your own relays first.';

  @override
  String get storageResetContinue => 'Continue';

  @override
  String get storageResetOpenRelaySettings => 'Relay settings';

  @override
  String get storageResetAcknowledgeFailed =>
      'Haven couldn’t save your answer. Until it’s saved, Haven won’t publish your relay settings or invitation key, so no one can invite you yet. Try again, or Haven will ask again the next time it opens.';

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
      'This deletes your identity and all circle data from this phone. Anything already published under it stays where it is: your name and keys on the relays that have them, your photo on the image host that stores it. Make sure you have backed up your secret key if you want to recover this identity later.';

  @override
  String get identityAdvancedDeleteConfirm => 'Delete';

  @override
  String get identityAdvancedDeletedSnack => 'Identity deleted';

  @override
  String get identityAdvancedDeleteError =>
      'Failed to delete identity. Please try again.';

  @override
  String get identityAdvancedDeletingProgress => 'Deleting your identity…';

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
  String get profileSyncStatusSyncing => 'Syncing to your public profile…';

  @override
  String get profileSyncStatusPartial =>
      'Published — still syncing to some relays';

  @override
  String get profileSyncStatusSynced => 'Public profile up to date';

  @override
  String get profileSyncStatusFailed => 'Couldn\'t sync yet.';

  @override
  String get profileSyncStatusRetrySemantics => 'Retry publishing your profile';

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
      'Photo updated. It will be published to your public Nostr profile.';

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
  String get mapLocationNoPermissionTitle => 'Haven can\'t use your location';

  @override
  String get mapLocationSharingStoppedServiceOff =>
      'Location is off on this device, so Haven has stopped sharing your location with your circles. Turn location on to start again.';

  @override
  String get mapLocationSharingStoppedPermission =>
      'Haven no longer has permission to use your location, so sharing has stopped. Allow location access to start again.';

  @override
  String get mapLocationSharingStoppedPermissionSettings =>
      'Location access for Haven is turned off in system settings, so sharing has stopped. Allow it there to start again.';

  @override
  String get mapLocationSharingStoppedBoth =>
      'Haven has stopped sharing your location. Turn location on for this device and allow Haven to use it.';

  @override
  String get mapLocationSharingStoppedUnknown =>
      'Haven has stopped receiving your location, so sharing has stopped. Check that location is on and that Haven is allowed to use it.';

  @override
  String get mapLocationAccessRestoredAnnouncement =>
      'Haven can use your location again. Sharing has resumed.';

  @override
  String get clockSkewTitle => 'This phone\'s clock is wrong';

  @override
  String get clockSkewBodyRejected =>
      'Your circles are not receiving your location, because the relays reject the time this phone stamps on it. Turn on automatic date and time in system settings to fix it.';

  @override
  String get clockSkewBodyBehind =>
      'This phone is running behind the rest of your circles, so the locations it sends expire early, and your circles can miss some or all of them. Turn on automatic date and time in system settings to fix it.';

  @override
  String get clockSkewResolvedAnnouncement =>
      'The clock problem is gone. Haven is sharing your location again.';

  @override
  String get clockSkewTitleDisagreement =>
      'A clock in one of your circles is wrong';

  @override
  String get clockSkewBodyDisagreement =>
      'This phone\'s clock and another member\'s disagree by two minutes or more. If this phone\'s is the wrong one, the locations it sends can expire before anyone sees them. Turn on automatic date and time in system settings to make sure this phone is not the one that is wrong.';

  @override
  String get clockSkewDisagreementResolvedAnnouncement =>
      'The clock warning is gone.';

  @override
  String get sharingHealthTitleStopped => 'Location sharing has stopped';

  @override
  String get sharingHealthTitleNotSending =>
      'Your location is not being shared';

  @override
  String get sharingHealthTitleNotReceiving =>
      'You are not receiving locations';

  @override
  String sharingHealthNoUpdatesMinutes(int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'No updates for about $countString minutes',
      one: 'No updates for about 1 minute',
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
      other: 'No updates for about $countString hours',
      one: 'No updates for about 1 hour',
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
      other: 'No updates for about $countString days',
      one: 'No updates for about 1 day',
    );
    return '$_temp0';
  }

  @override
  String get sharingHealthRepairAction => 'Repair';

  @override
  String get sharingHealthRepairSent =>
      'Repair sent. The others will catch up once their phones have picked it up.';

  @override
  String get sharingHealthRepairNothingToDo =>
      'Nothing to repair right now. Haven will keep trying.';

  @override
  String get sharingHealthRepairUnresolvedAnnouncement =>
      'Location sharing is still not working.';

  @override
  String get sharingHealthResumedAnnouncement =>
      'Location sharing is working again.';

  @override
  String get sharingHealthTitleQuarantined =>
      'Haven can’t open this circle right now';

  @override
  String get sharingHealthBodyQuarantined =>
      'Something went wrong loading this circle on this phone. The circle is still here.';

  @override
  String get sharingHealthTitleDisbanded => 'This circle has ended';

  @override
  String get sharingHealthBodyDisbanded =>
      'An admin ended this circle, so nothing is shared with it any more. Leave it to remove it from this phone.';

  @override
  String get sharingHealthQuarantineRetryHint =>
      'Tries to load this circle again';

  @override
  String get sharingHealthQuarantineRetryFailedAnnouncement =>
      'Haven still can’t open this circle.';

  @override
  String get sharingHealthTitleUnrecoverable =>
      'This circle stopped working on this phone';

  @override
  String get sharingHealthBodyUnrecoverable =>
      'Haven can no longer send or receive updates in this circle on this phone. Ask one of its admins to remove you and add you back. If no one can, make a new circle with the same people.';

  @override
  String get sharingHealthTitleStalled =>
      'Haven can’t read this circle’s updates';

  @override
  String get sharingHealthBodyStalled =>
      'This phone seems to have missed a change to the circle and couldn’t find it on the relays. Ask one of its admins to remove you and add you back. If no one can, make a new circle with the same people.';

  @override
  String get sharingHealthTitlePaused => 'Haven paused this circle';

  @override
  String get sharingHealthBodyCollision =>
      'Haven found a problem with this circle on this phone and stopped sharing with it to keep your location private. Leaving the circle is the only way to fix this. To join it again, you’ll need a new invitation.';

  @override
  String get sharingHealthBodyCannotCheck =>
      'Haven couldn’t check this circle on this phone, so it paused sharing with it to keep your location private. It checks again on its own.';

  @override
  String get sharingHealthTitleLeaving => 'You’re leaving this circle';

  @override
  String get sharingHealthBodyLeaving =>
      'Nothing is shared with this circle while Haven finishes leaving it. This can take about a day. The circle disappears from this phone when it’s done.';

  @override
  String get sharingHealthBodyRemovalUnmade =>
      'A removal you asked for wasn’t made, so Haven has paused sharing your location with this circle to keep it from anyone you tried to remove.';

  @override
  String get sharingHealthBodyRemovalUnmadeNoNotice =>
      'A removal you asked for wasn’t made, so Haven has paused sharing your location with this circle to keep it from anyone you tried to remove. Open the member list to see who is still in the circle.';

  @override
  String get sharingHealthBodyDepartureDue =>
      'Someone left this circle and their departure hasn’t been completed. Until it is, Haven doesn’t share your location with this circle.';

  @override
  String get sharingHealthTitleBackgroundPaused =>
      'Background sharing is paused for this circle';

  @override
  String get sharingHealthBodyAwaitsForeground =>
      'Its relays changed while Haven was in the background. Haven finishes switching while it’s open; until then this circle isn’t shared in the background.';

  @override
  String get sharingHealthBodyAwaitingRelays =>
      'A change to this circle is waiting for a relay to confirm it. Until then, Haven isn’t sending your location to this circle or showing new locations from it. It keeps trying while the app is open.';

  @override
  String get sharingHealthBodyAcknowledged =>
      'A relay accepted a change to this circle and Haven is finishing it. Until then, this circle’s updates wait.';

  @override
  String get sharingHealthBodyStagedWithoutRecord =>
      'A change to this circle couldn’t be saved, so it wasn’t sent. Haven sorts it out, at the latest the next time it starts; until then this circle’s updates wait.';

  @override
  String get sharingHealthBodyStoredInput =>
      'This phone has updates for this circle that it hasn’t been able to process. Until it has, Haven doesn’t share your location with this circle.';

  @override
  String get sharingHealthBodySessionHeld =>
      'Haven is still closing its last connection, so location sharing is paused. It resumes once that finishes. Restarting your phone always clears it.';

  @override
  String get sharingHealthRepairHintAnyMember =>
      'Reconnects to the relays, retries sending your location, and may give this circle new encryption keys';

  @override
  String get sharingHealthAttentionAnnouncement =>
      'Location sharing needs attention in this circle. Open Circle details to see why.';

  @override
  String changeNoticeArrivedAnnouncement(String circleName) {
    return 'Something about recent changes to $circleName needs your attention. Open that circle’s details to read it.';
  }

  @override
  String get circleDetailsAttentionTooltip => 'Circle details, needs attention';

  @override
  String circleRowAttentionSemantics(String circleName) {
    return '$circleName, needs attention';
  }

  @override
  String get changeNoticeHeading => 'Changes to this circle';

  @override
  String get changeNoteRemovalUndone =>
      'A change to this circle didn’t go through. If it removed someone, they’re still in the circle and can see what’s shared with it.';

  @override
  String get changeNoteChangeUndone =>
      'A change to this circle didn’t go through, so nothing changed. If it was yours, make it again if you still want it.';

  @override
  String get changeNoteMayBeOutOfStep =>
      'A change to this circle may have reached the others without this phone knowing, so this phone may be out of step with them.';

  @override
  String get changeNoteReinviteOwed =>
      'Someone you invited is listed in this circle but can’t join, because Haven can’t send their invitation. Remove them and add them again.';

  @override
  String get changeNoteChangeUnrecorded =>
      'A change to this circle couldn’t be saved, so it wasn’t sent.';

  @override
  String get changeNoteQueuedChangeDropped =>
      'A change waiting to be made in this circle was cancelled because it could no longer be made as asked. It may already have been made another way.';

  @override
  String get changeNoteQueuedChangesHeld =>
      'Some changes to this circle are still waiting to be made.';

  @override
  String get changeNoteQueuedRemovalDropped =>
      'A removal you asked for in this circle wasn’t made. Anyone you tried to remove may still be in the circle.';

  @override
  String get changeNoteChangeWithdrawn =>
      'Another member’s change to this circle replaced one of yours, so yours wasn’t made. Make it again if you still want it.';

  @override
  String get changeNoteWelcomeOwed =>
      'An invitation to this circle hasn’t gone through. Haven keeps sending it while the app is open, for up to a day after you invited them. If the person hasn’t joined by then, remove them and add them again.';

  @override
  String get changeNoteUnreadLocation =>
      'Some recent updates sent to this circle couldn’t be opened on this phone.';

  @override
  String get changeNoticeStillInCircleLabel => 'Still in the circle:';

  @override
  String get changeNoticeRemoveAgain => 'Remove again';

  @override
  String get changeNoticeReviewMembers => 'Review members';

  @override
  String get changeNoticeKeepMembers => 'Keep them in the circle';

  @override
  String get changeNoticeKeepConfirmTitle => 'Keep them in the circle?';

  @override
  String get changeNoticeKeepConfirmBody =>
      'Haven will no longer pause sharing with this circle because of this removal. Anyone you tried to remove who is still in the circle stays in it and can see your location whenever Haven shares it with this circle.';

  @override
  String get changeNoticeKeepConfirmAction => 'Keep them';

  @override
  String circleMemberLastSeenMinutes(int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Last seen $countString minutes ago',
      one: 'Last seen 1 minute ago',
    );
    return '$_temp0';
  }

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
