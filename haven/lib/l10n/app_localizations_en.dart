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
      'Haven has no central server. Your encrypted messages travel through a decentralized network of relays that you can choose yourself, so no single entity can shut it down.';

  @override
  String get onboardingValueProp3Title => 'No account needed';

  @override
  String get onboardingValueProp3Body =>
      'No email, no phone number, no sign-up. Haven creates a private identity that lives only on your phone, with nothing linking it to the real you.';

  @override
  String get onboardingValueProp1Summary =>
      'Encrypted on your device, so only the circles you choose can read it.';

  @override
  String get onboardingValueProp2Summary =>
      'No central server — it runs on a relay network you choose.';

  @override
  String get onboardingValueProp3Summary =>
      'No email, phone, or sign-up. Nothing links it to you.';

  @override
  String get onboardingCreateIdentityTitle => 'Create your identity';

  @override
  String get onboardingCreateIdentityBody =>
      'Haven will create a private identity that lives only on this phone. It’s how your circles recognise you.';

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
      'kind 10050, where invitations reach you';

  @override
  String get relaySettingsKeyPackageTitle => 'My KeyPackage Relays';

  @override
  String get relaySettingsKeyPackageSubtitle =>
      'kind 10051, where invitees discover your encryption keys';

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
  String get relaySettingsExplainerSemantics => 'How Haven relays work';

  @override
  String get relaySettingsExplainerHeading => 'How this works';

  @override
  String get relaySettingsExplainerNostr =>
      'Haven has no central server. It runs on two open technologies. Nostr is a network of independent servers called relays that anyone can run; they receive your messages, hold them briefly, and hand them on when your contacts ask. No single relay is essential, so if one goes offline the others keep working, and anything a relay could be forced to hand over is only ever encrypted data.';

  @override
  String get relaySettingsExplainerMarmot =>
      'The Marmot protocol encrypts your messages on your device before they leave it, using the MLS (Messaging Layer Security) standard. Each circle is its own encrypted group with its own keys, so separate circles cannot be linked together. Those keys also keep advancing over time, a property called forward secrecy, so even a key exposed later cannot unlock your earlier messages.';

  @override
  String get relaySettingsExplainerMetadata =>
      'Because of this, a relay never sees your location, your messages, who is in your circles, or your identity on those messages. Each message is published from a fresh, single-use sending address, so nothing in the message ties it to your account. A relay still sees some metadata, though: a random per-circle tag, the timing and size of your traffic, and the network address you connect from.';

  @override
  String get relaySettingsExplainerInboxTerm => 'Inbox relays';

  @override
  String get relaySettingsExplainerInboxBody =>
      ' are your mailbox: where invitations to join a circle, themselves encrypted, are delivered for you to collect. For someone to invite you, they must be able to reach one of these relays.';

  @override
  String get relaySettingsExplainerKeyPackageTerm => 'KeyPackage relays';

  @override
  String get relaySettingsExplainerKeyPackageBody =>
      ' are where you publish a small bundle of your public keys, which is safe to share. Someone who knows your account fetches it from these relays to add you to a circle.';

  @override
  String get relaySettingsExplainerOwnRelayTerm => 'Using your own relay.';

  @override
  String get relaySettingsExplainerOwnRelayBody =>
      ' Each circle also carries its own relay list, shared with every member when they join; that list, not your inbox, is where the circle’s ongoing encrypted updates travel. So if you would rather avoid public relays, you can run your own and point a circle at it: once everyone has joined, that circle’s traffic can flow through it alone.';

  @override
  String get relaySettingsExplainerReachabilityTerm =>
      'The catch is reachability.';

  @override
  String get relaySettingsExplainerReachabilityBody =>
      ' Every member must be able to connect to that relay, and when you first invite someone, the two of you need a relay you can both reach (for example, the same private relay listed as everyone’s inbox and KeyPackage relay). A private relay still sees the same encrypted traffic and timing as any other; you simply control who runs it.';

  @override
  String get relaySettingsExplainerFooter =>
      'You can add or remove relays in either list at any time. More relays make you easier to reach; fewer give you more control over where your encrypted traffic goes.';

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
      'When background sharing is on, your circles keep seeing your live location even when Haven is closed.';

  @override
  String get locationSettingsToggleTitle => 'Share in background';

  @override
  String get locationSettingsToggleSubtitle =>
      'Keep sharing when the app is closed';

  @override
  String get locationSettingsIosLimitedNote =>
      'Limited in background. Set Location to \'Always\' for Haven in Settings';

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
      'For continuous background sharing, set Location to \"Always\" for Haven in Settings. iOS shows a blue status-bar indicator while an app is using your location in the background.';

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
  String get aboutWhoCanSeeTitle => 'Who can see what';

  @override
  String get aboutWhoCanSeeIntro =>
      'Your exact location is readable only by the people you choose. Here is what the main parties can and cannot see.';

  @override
  String get aboutActorCirclesWho => 'Circle members you share with';

  @override
  String get aboutActorCirclesSees =>
      'Your exact location and the display name you pick, but only inside the circles you share with them, never your other circles.';

  @override
  String get aboutActorRelaysWho => 'Relay operators';

  @override
  String get aboutActorRelaysSees =>
      'The servers that pass your messages along. They see your IP address, the public key you publish under (a random ID, not your name), the size and timing of your traffic, and which account you searched for when you look someone up. They can never read your location, your messages, your circle names, or who is in your circles.';

  @override
  String get aboutActorMapWho => 'The map provider (Stadia Maps)';

  @override
  String get aboutActorMapSees =>
      'Only while the map is open: your IP address and the area you are viewing, so it can send the right map images. Never your circles or your shared location. Stadia anonymizes IP addresses and does not sell your data.';

  @override
  String get aboutActorDevelopersWho => 'Haven’s developers';

  @override
  String get aboutActorDevelopersSees =>
      'Nothing. Haven runs no servers and collects no analytics. A developer could only see what a relay operator sees, and only if you used a relay they happen to run.';

  @override
  String get aboutWhoCanSeeMetadataNote =>
      'Even so, your activity is not invisible. A relay you use, or anyone watching your network, can tell that you are active, roughly when, and how often, from connection timing and message sizes.';

  @override
  String get aboutScreenshotTitle => 'Screenshot protection';

  @override
  String get aboutScreenshotBody =>
      'On Android, Haven blocks screenshots and screen recording app-wide to prevent accidental location exposure. This is a system-level protection (FLAG_SECURE) that applies to every screen in the app, including the map and member lists.';

  @override
  String get aboutVpnTitle => 'Stay more private with a VPN';

  @override
  String get aboutVpnBody =>
      'Relays and the map provider see your IP address, and your internet provider sees which servers you reach. A trusted VPN hides your IP address from them. We recommend Mullvad. It does not change what your circle members see, and it shifts trust to the VPN provider.';

  @override
  String get aboutVpnLinkLabel => 'mullvad.net';

  @override
  String get aboutFooterLicense => 'Licensed under the MIT License';

  @override
  String aboutFooterVersion(String version) {
    return 'Version $version';
  }

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
  String get createCircleNoAccountFound => 'No Haven account found';

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
      'Everyone in this circle can see each other’s location and display name. Your display name is the one you set in Settings → Identity. This circle stays separate from any others you’re in, so its members can’t see your other circles or who’s in them.';

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
      'New members can see this circle\'s encrypted locations once they accept the invitation.';

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
  String get pendingMemberRemoveTooltip => 'Remove member';

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
  String get circleDetailsRelaysHeading => 'Relays for this circle';

  @override
  String get circleDetailsNoRelays => '(none recorded)';

  @override
  String get circleDetailsRelaysNote =>
      'These relays were chosen when this circle was created and are not user-editable yet. Independent from your personal relay settings.';

  @override
  String get circleDetailsAddMember => 'Add member';

  @override
  String get circleDetailsLeaveCircle => 'Leave Circle';

  @override
  String get leaveCircleDialogTitle => 'Leave Circle';

  @override
  String get leaveCircleDialogBody =>
      'Are you sure you want to leave this circle? You will no longer receive location updates from its members. This action cannot be undone.';

  @override
  String get leaveCircleConfirm => 'Leave';

  @override
  String get leaveCircleIdentityUnavailable => 'Identity unavailable';

  @override
  String get leaveCircleSuccess => 'Left circle successfully';

  @override
  String get leaveCircleError => 'Failed to leave circle';

  @override
  String get leaveCircleAdminLimitationNote =>
      'As this circle\'s admin, you can only leave once every other member has left. We know that\'s inconvenient — a future update will let admins hand off and leave directly.';

  @override
  String get circleBlockedBannerTitle => 'This circle can’t be updated';

  @override
  String get circleBlockedBannerBody =>
      'Something went wrong with this circle’s encryption, so Haven can no longer send or receive updates in it. You can still see what you last knew below, or leave the circle.';

  @override
  String get legacyCircleBannerTitle => 'This circle needs to be re-created';

  @override
  String get legacyCircleBannerBody =>
      'Haven’s encryption engine was upgraded, so this circle can no longer be used. Re-create it to keep sharing locations with the same people — you’ll need to invite them again.';

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
      'Your identity and public profile are unchanged — there is nothing you need to do for those.';

  @override
  String get legacyCutoverExplainerCirclesNeedRecreation =>
      'For improved security, your circles need to be re-created and their members re-invited before you can share locations in them again.';

  @override
  String get legacyCutoverExplainerAcknowledge => 'Got it';

  @override
  String get relaySettingsLegacyRetractionPending =>
      'Haven is still cleaning up some data from the recent security update. This will finish automatically once you’re back online.';

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
      'This will permanently delete your identity. Make sure you have backed up your secret key if you want to recover it.';

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
      'Your public key works like a username that is safe to share. People scan this code, or paste your public key, to invite you to a circle. Sharing it cannot reveal your location, which is only visible to members of circles you\'ve joined, nor your name and photo, which stay on this device unless you choose to publish a public profile.';

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
      'This removes your photo from your public profile.';

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
      'Photo updated — published to your public Nostr profile.';

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
