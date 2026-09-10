import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/intl.dart' as intl;

import 'app_localizations_ar.dart';
import 'app_localizations_de.dart';
import 'app_localizations_en.dart';
import 'app_localizations_es.dart';
import 'app_localizations_fa.dart';
import 'app_localizations_fr.dart';
import 'app_localizations_hi.dart';
import 'app_localizations_ja.dart';
import 'app_localizations_ne.dart';
import 'app_localizations_pt.dart';
import 'app_localizations_ru.dart';
import 'app_localizations_tr.dart';
import 'app_localizations_ur.dart';

// ignore_for_file: type=lint

/// Callers can lookup localized strings with an instance of AppLocalizations
/// returned by `AppLocalizations.of(context)`.
///
/// Applications need to include `AppLocalizations.delegate()` in their app's
/// `localizationDelegates` list, and the locales they support in the app's
/// `supportedLocales` list. For example:
///
/// ```dart
/// import 'l10n/app_localizations.dart';
///
/// return MaterialApp(
///   localizationsDelegates: AppLocalizations.localizationsDelegates,
///   supportedLocales: AppLocalizations.supportedLocales,
///   home: MyApplicationHome(),
/// );
/// ```
///
/// ## Update pubspec.yaml
///
/// Please make sure to update your pubspec.yaml to include the following
/// packages:
///
/// ```yaml
/// dependencies:
///   # Internationalization support.
///   flutter_localizations:
///     sdk: flutter
///   intl: any # Use the pinned version from flutter_localizations
///
///   # Rest of dependencies
/// ```
///
/// ## iOS Applications
///
/// iOS applications define key application metadata, including supported
/// locales, in an Info.plist file that is built into the application bundle.
/// To configure the locales supported by your app, you’ll need to edit this
/// file.
///
/// First, open your project’s ios/Runner.xcworkspace Xcode workspace file.
/// Then, in the Project Navigator, open the Info.plist file under the Runner
/// project’s Runner folder.
///
/// Next, select the Information Property List item, select Add Item from the
/// Editor menu, then select Localizations from the pop-up menu.
///
/// Select and expand the newly-created Localizations item then, for each
/// locale your application supports, add a new item and select the locale
/// you wish to add from the pop-up menu in the Value field. This list should
/// be consistent with the languages listed in the AppLocalizations.supportedLocales
/// property.
abstract class AppLocalizations {
  AppLocalizations(String locale)
    : localeName = intl.Intl.canonicalizedLocale(locale.toString());

  final String localeName;

  static AppLocalizations of(BuildContext context) {
    return Localizations.of<AppLocalizations>(context, AppLocalizations)!;
  }

  static const LocalizationsDelegate<AppLocalizations> delegate =
      _AppLocalizationsDelegate();

  /// A list of this localizations delegate along with the default localizations
  /// delegates.
  ///
  /// Returns a list of localizations delegates containing this delegate along with
  /// GlobalMaterialLocalizations.delegate, GlobalCupertinoLocalizations.delegate,
  /// and GlobalWidgetsLocalizations.delegate.
  ///
  /// Additional delegates can be added by appending to this list in
  /// MaterialApp. This list does not have to be used at all if a custom list
  /// of delegates is preferred or required.
  static const List<LocalizationsDelegate<dynamic>> localizationsDelegates =
      <LocalizationsDelegate<dynamic>>[
        delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
      ];

  /// A list of this localizations delegate's supported locales.
  static const List<Locale> supportedLocales = <Locale>[
    Locale('ar'),
    Locale('de'),
    Locale('en'),
    Locale('es'),
    Locale('fa'),
    Locale('fr'),
    Locale('hi'),
    Locale('ja'),
    Locale('ne'),
    Locale('pt'),
    Locale('ru'),
    Locale('tr'),
    Locale('ur'),
  ];

  /// Title of the Appearance settings page, which hosts the theme and language selectors. Previously labelled 'Theme'.
  ///
  /// In en, this message translates to:
  /// **'Appearance'**
  String get appearanceTitle;

  /// Section header above the light/dark/system theme options on the Appearance page.
  ///
  /// In en, this message translates to:
  /// **'Theme'**
  String get appearanceThemeHeader;

  /// Theme option: follow the device's light/dark setting.
  ///
  /// In en, this message translates to:
  /// **'System default'**
  String get appearanceThemeSystem;

  /// Subtitle under the 'System default' theme option.
  ///
  /// In en, this message translates to:
  /// **'Match your device settings'**
  String get appearanceThemeSystemSubtitle;

  /// Theme option: always use the light theme.
  ///
  /// In en, this message translates to:
  /// **'Light'**
  String get appearanceThemeLight;

  /// Subtitle under the 'Light' theme option.
  ///
  /// In en, this message translates to:
  /// **'Always use the light theme'**
  String get appearanceThemeLightSubtitle;

  /// Theme option: always use the dark theme.
  ///
  /// In en, this message translates to:
  /// **'Dark'**
  String get appearanceThemeDark;

  /// Subtitle under the 'Dark' theme option.
  ///
  /// In en, this message translates to:
  /// **'Always use the dark theme'**
  String get appearanceThemeDarkSubtitle;

  /// Label for the language selector row on the Appearance page, and the title of the language picker page it opens.
  ///
  /// In en, this message translates to:
  /// **'Language'**
  String get appearanceLanguageTitle;

  /// Language option that follows the device's system language. Selecting it removes any explicit in-app language override.
  ///
  /// In en, this message translates to:
  /// **'System default'**
  String get languageSystemDefault;

  /// Button that retries a failed operation (error states).
  ///
  /// In en, this message translates to:
  /// **'Try Again'**
  String get commonTryAgain;

  /// Tooltip on the button that closes an inline error card.
  ///
  /// In en, this message translates to:
  /// **'Dismiss'**
  String get commonDismiss;

  /// Tooltip on the floating button that opens the settings page.
  ///
  /// In en, this message translates to:
  /// **'Settings'**
  String get commonSettings;

  /// Tooltip on the invitations button when there are no pending invitations.
  ///
  /// In en, this message translates to:
  /// **'Invitations'**
  String get commonInvitations;

  /// Tooltip on the invitations button showing how many invitations are pending.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 pending invitation} other{{count} pending invitations}}'**
  String commonPendingInvitations(int count);

  /// Generic label/tooltip for a back navigation button.
  ///
  /// In en, this message translates to:
  /// **'Back'**
  String get commonBack;

  /// Generic primary call-to-action that advances to the next step.
  ///
  /// In en, this message translates to:
  /// **'Continue'**
  String get commonContinue;

  /// Generic secondary action that skips the current optional step.
  ///
  /// In en, this message translates to:
  /// **'Skip'**
  String get commonSkip;

  /// Generic action that retries a failed or incomplete operation (e.g. an inline pill action).
  ///
  /// In en, this message translates to:
  /// **'Retry'**
  String get commonRetry;

  /// Accessible step indicator announced on each onboarding screen transition, e.g. 'Step 2 of 5'.
  ///
  /// In en, this message translates to:
  /// **'Step {current} of {total}'**
  String onboardingStepOf(int current, int total);

  /// The app name 'Haven' as it appears in the onboarding welcome hero. A brand name, intentionally English (not translated).
  ///
  /// In en, this message translates to:
  /// **'Haven'**
  String get onboardingAppName;

  /// Welcome hero subtitle beneath the app name. The word in onboardingWelcomeHeadlineEmphasis is rendered in bold and must remain an exact substring of this sentence.
  ///
  /// In en, this message translates to:
  /// **'Share your location privately, only with those you want.'**
  String get onboardingWelcomeHeadline;

  /// The single word emphasised (bold) within onboardingWelcomeHeadline. Must be an exact substring of that headline.
  ///
  /// In en, this message translates to:
  /// **'only'**
  String get onboardingWelcomeHeadlineEmphasis;

  /// Primary call-to-action button on the onboarding welcome screen.
  ///
  /// In en, this message translates to:
  /// **'Get Started'**
  String get onboardingWelcomeCta;

  /// Title of the onboarding value-props screen.
  ///
  /// In en, this message translates to:
  /// **'What makes Haven different'**
  String get onboardingValuePropsTitle;

  /// Headline of the first onboarding value-prop card.
  ///
  /// In en, this message translates to:
  /// **'Only your circles can see you'**
  String get onboardingValueProp1Title;

  /// Headline of the second onboarding value-prop card.
  ///
  /// In en, this message translates to:
  /// **'No one can shut it down'**
  String get onboardingValueProp2Title;

  /// Headline of the third onboarding value-prop card.
  ///
  /// In en, this message translates to:
  /// **'No account needed'**
  String get onboardingValueProp3Title;

  /// Short one-line summary of the first value prop, shown under its title on the onboarding intro screen. Keep it to roughly one short sentence so the intro screen fits without scrolling.
  ///
  /// In en, this message translates to:
  /// **'Encrypted on your device, so only the circles you choose can read it.'**
  String get onboardingValueProp1Summary;

  /// Short one-line summary of the second value prop, shown under its title on the onboarding intro screen. Keep it to roughly one short sentence so the intro screen fits without scrolling.
  ///
  /// In en, this message translates to:
  /// **'No central server . It runs on a relay network you choose.'**
  String get onboardingValueProp2Summary;

  /// Short one-line summary of the third value prop, shown under its title on the onboarding intro screen. Keep it to roughly one short sentence so the intro screen fits without scrolling. An earlier version claimed 'nothing links it to you', which over-claimed (the user's network address is visible to every relay, and the same key carries a renameable public profile). Keep the claim narrowed to key custody.
  ///
  /// In en, this message translates to:
  /// **'No email, phone, or sign-up. Your secret key never leaves your phone.'**
  String get onboardingValueProp3Summary;

  /// Title of the onboarding create-identity screen.
  ///
  /// In en, this message translates to:
  /// **'Create your identity'**
  String get onboardingCreateIdentityTitle;

  /// Body explaining what happens when an identity is created on the onboarding create-identity screen.
  ///
  /// In en, this message translates to:
  /// **'Haven creates your keys on this phone. The secret one never leaves it.'**
  String get onboardingCreateIdentityBody;

  /// Critical warning the user must understand on the onboarding create-identity screen: identity loss is unrecoverable.
  ///
  /// In en, this message translates to:
  /// **'If you lose this phone or delete the app, your identity is gone. Haven has no way to recover it for you.'**
  String get onboardingCreateIdentityWarning;

  /// Primary call-to-action on the onboarding create-identity screen.
  ///
  /// In en, this message translates to:
  /// **'Create My Identity'**
  String get onboardingCreateIdentityCta;

  /// Loading label shown while the user's keypair is being generated.
  ///
  /// In en, this message translates to:
  /// **'Setting things up…'**
  String get onboardingCreateIdentityLoading;

  /// Secondary affordance text inviting the user to import an existing key instead of creating one.
  ///
  /// In en, this message translates to:
  /// **'Already have a key?'**
  String get onboardingCreateIdentityImportPrompt;

  /// Link text (emphasised) that navigates from create-identity to the import-key screen.
  ///
  /// In en, this message translates to:
  /// **'Import it instead'**
  String get onboardingCreateIdentityImportLink;

  /// Snackbar message shown when identity creation fails.
  ///
  /// In en, this message translates to:
  /// **'Something went wrong creating your identity. Please try again.'**
  String get onboardingCreateIdentityError;

  /// Title of the onboarding import-key screen.
  ///
  /// In en, this message translates to:
  /// **'Import your existing key'**
  String get onboardingImportTitle;

  /// Helper text on the onboarding import-key screen explaining the expected input.
  ///
  /// In en, this message translates to:
  /// **'Paste the secret key you backed up from another Haven-compatible app.'**
  String get onboardingImportBody;

  /// Text-field hint on the import-key screen showing the expected key format (bech32 nsec prefix). A technical format placeholder, intentionally English (not translated).
  ///
  /// In en, this message translates to:
  /// **'nsec1…'**
  String get onboardingImportHint;

  /// Primary call-to-action on the onboarding import-key screen.
  ///
  /// In en, this message translates to:
  /// **'Import'**
  String get onboardingImportCta;

  /// Loading label shown while an existing key is being imported.
  ///
  /// In en, this message translates to:
  /// **'Importing…'**
  String get onboardingImportLoading;

  /// Validation error shown when the import input does not look like a valid backup key.
  ///
  /// In en, this message translates to:
  /// **'That doesn’t look like a valid backup key. Please check and try again.'**
  String get onboardingImportInvalid;

  /// Generic error shown when importing an existing key fails.
  ///
  /// In en, this message translates to:
  /// **'We couldn’t import that key. Please check and try again.'**
  String get onboardingImportError;

  /// Text-field hint on the onboarding display-name screen showing an example name.
  ///
  /// In en, this message translates to:
  /// **'e.g. Alex'**
  String get onboardingDisplayNameHint;

  /// Snackbar message shown when saving the display name fails.
  ///
  /// In en, this message translates to:
  /// **'Couldn’t save that name. Please try again.'**
  String get onboardingDisplayNameError;

  /// Caption below the avatar circle on the onboarding create-identity screen, inviting the user to optionally add a profile photo. Shown only when no photo has been chosen yet.
  ///
  /// In en, this message translates to:
  /// **'Add a photo (optional)'**
  String get onboardingAddPhotoOptional;

  /// Generic button that dismisses a dialog or sheet without taking the action.
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get commonCancel;

  /// Generic action that opens an OS settings screen for Haven (e.g. to grant notifications, change location permission, or exclude Haven from battery optimization).
  ///
  /// In en, this message translates to:
  /// **'Open settings'**
  String get commonOpenSettings;

  /// Title of the main Settings hub page (AppBar).
  ///
  /// In en, this message translates to:
  /// **'Settings'**
  String get settingsTitle;

  /// Title of the Identity tile on the Settings hub, opening the identity/profile/keys page.
  ///
  /// In en, this message translates to:
  /// **'Identity'**
  String get settingsIdentityTitle;

  /// Title of the Relays tile on the Settings hub, opening the relay settings page.
  ///
  /// In en, this message translates to:
  /// **'Relays'**
  String get settingsRelaysTitle;

  /// Title of the Location tile on the Settings hub, opening the location settings page.
  ///
  /// In en, this message translates to:
  /// **'Location'**
  String get settingsLocationTitle;

  /// Subtitle of the Location tile on the Settings hub while the background-sharing setting is ON. Driven by backgroundSharingProvider and by nothing else: it reports the SETTING, never whether the service is currently alive, so it must not be reworded into a health or liveness claim. It is the one standing at-a-glance signal that background sharing is on, because a confirmed-Always iPhone shows no blue bar. Must not name a platform or an OS indicator (blue bar, arrow): one hub line cannot qualify either, and both differ per platform and per authorization tier. Keep this locale's term for background sharing identical to locationSettingsToggleTitle's.
  ///
  /// In en, this message translates to:
  /// **'Background sharing on'**
  String get settingsLocationSubtitleOn;

  /// Subtitle of the Location tile on the Settings hub while the background-sharing setting is OFF. True on BOTH platforms in that state: Haven shares only while it is open. Reports the SETTING, not service health. Must name the app, must not name a platform or an OS indicator, and must not promise that sharing resumes by itself.
  ///
  /// In en, this message translates to:
  /// **'Only while Haven is open'**
  String get settingsLocationSubtitleOff;

  /// Title of the Map style tile on the Settings hub, opening the map-style picker.
  ///
  /// In en, this message translates to:
  /// **'Map style'**
  String get settingsMapStyleTitle;

  /// Title of the About tile on the Settings hub, opening the About page.
  ///
  /// In en, this message translates to:
  /// **'About'**
  String get settingsAboutTitle;

  /// Title of the debug-only switch tile that toggles the on-screen log overlay (visible only in debug builds).
  ///
  /// In en, this message translates to:
  /// **'Debug Log Overlay'**
  String get settingsDebugOverlayTitle;

  /// Subtitle under the debug log overlay switch tile.
  ///
  /// In en, this message translates to:
  /// **'Show log output on screen'**
  String get settingsDebugOverlaySubtitle;

  /// Title of the relay settings page (AppBar).
  ///
  /// In en, this message translates to:
  /// **'Relays'**
  String get relaySettingsTitle;

  /// Tooltip on the refresh button that re-checks reachability of all configured relays.
  ///
  /// In en, this message translates to:
  /// **'Check relays'**
  String get relaySettingsCheckRelaysTooltip;

  /// Title of the empty state shown on the relay settings page when no identity exists yet.
  ///
  /// In en, this message translates to:
  /// **'No Identity'**
  String get relaySettingsNoIdentityTitle;

  /// Message of the empty state shown on the relay settings page when no identity exists yet.
  ///
  /// In en, this message translates to:
  /// **'Create an identity first to manage relays.'**
  String get relaySettingsNoIdentityMessage;

  /// Empty-state message shown when the user's identity could not be loaded on the relay settings page.
  ///
  /// In en, this message translates to:
  /// **'Failed to load identity.'**
  String get relaySettingsLoadIdentityError;

  /// Heading of the Inbox relays section on the relay settings page.
  ///
  /// In en, this message translates to:
  /// **'My Inbox Relays'**
  String get relaySettingsInboxTitle;

  /// Subtitle of the Inbox relays section. 'kind 10050' is a Nostr event-kind identifier, intentionally English (not translated).
  ///
  /// In en, this message translates to:
  /// **'Where invitations reach you (kind 10050)'**
  String get relaySettingsInboxSubtitle;

  /// Heading of the KeyPackage relays section on the relay settings page.
  ///
  /// In en, this message translates to:
  /// **'My KeyPackage Relays'**
  String get relaySettingsKeyPackageTitle;

  /// Subtitle of the KeyPackage relays section. 'kind 10002' is a Nostr event-kind identifier, intentionally English (not translated). This list no longer carries the public profile — kind-0 profile lookups/publish moved to the separate, local-only Profile relays section below (relaySettingsProfileSubtitle) so the two planes stay on disjoint relays. Do not reintroduce a 'your public profile is published' clause here.
  ///
  /// In en, this message translates to:
  /// **'Where others find the keys they need to invite you (kind 10002)'**
  String get relaySettingsKeyPackageSubtitle;

  /// Heading of the Profile relays section on the relay settings page. This is a local-only category (kind-0 profile lookups/publish), kept separate from the Inbox and KeyPackage categories.
  ///
  /// In en, this message translates to:
  /// **'My Profile Relays'**
  String get relaySettingsProfileTitle;

  /// Subtitle of the Profile relays section. 'kind 0' is a Nostr event-kind identifier, intentionally English (not translated). Explains that this list is local-only policy, unlike the other two sections' published lists.
  ///
  /// In en, this message translates to:
  /// **'Where your public profile is looked up and published. These relays are kept separate from your other relays, and the profile relay list itself is never published (kind 0)'**
  String get relaySettingsProfileSubtitle;

  /// Title of the warning banner shown at the top of the Profile relays section when the profile-plane relay pool has underflowed (too few relays remain to safely look up profiles — see ProfilePoolStatusFfi.isUnderflow). Only shown while true; the banner disappears on its own once enough relays are restored.
  ///
  /// In en, this message translates to:
  /// **'Profile lookups paused'**
  String get relaySettingsProfileUnderflowTitle;

  /// Body of the profile-pool-underflow warning banner, paired with relaySettingsProfileUnderflowTitle. States the practical consequence in plain language (stale roster names/photos) rather than the technical cause (contamination-ledger exclusion), matching this page's register elsewhere. The fix is offered by the banner's own button (relaySettingsProfileUnderflowRestoreButton), not restated here.
  ///
  /// In en, this message translates to:
  /// **'Too few Profile relays remain, so members\' names and photos will stop updating.'**
  String get relaySettingsProfileUnderflowMessage;

  /// Button in the profile-pool-underflow warning banner; calls CircleManagerFfi.restoreDefaultProfileRelays() (non-destructive: adds back missing curated profile relays, keeps the user's own additions). Deliberately worded more specifically than relaySettingsRestoreDefaults (that label is used at two call sites on this same page: the section-level destructive wipe-and-reset-to-exactly-defaults action behind a confirmation dialog, and the non-destructive empty-category top-up action): reusing the identical short label here would give a screen-reader user, or anyone scanning the page while this banner is visible, differently-behaving controls with the same name. Keep this button's wording distinguishable from relaySettingsRestoreDefaults in every locale.
  ///
  /// In en, this message translates to:
  /// **'Restore default profile relays'**
  String get relaySettingsProfileUnderflowRestoreButton;

  /// Empty-state message shown when a relay category's list could not be loaded.
  ///
  /// In en, this message translates to:
  /// **'Failed to load relays.'**
  String get relaySettingsLoadRelaysError;

  /// Button that opens the sheet to add a new relay to a category.
  ///
  /// In en, this message translates to:
  /// **'Add relay'**
  String get relaySettingsAddRelay;

  /// Button/action that replaces the current relays with Haven's defaults.
  ///
  /// In en, this message translates to:
  /// **'Restore defaults'**
  String get relaySettingsRestoreDefaults;

  /// Snackbar shown when adding a relay fails for an unexpected reason.
  ///
  /// In en, this message translates to:
  /// **'Failed to add relay.'**
  String get relaySettingsAddRelayError;

  /// Snackbar shown when removing a relay fails for an unexpected reason.
  ///
  /// In en, this message translates to:
  /// **'Failed to remove relay.'**
  String get relaySettingsRemoveRelayError;

  /// Title of the confirmation dialog shown before restoring default relays.
  ///
  /// In en, this message translates to:
  /// **'Restore default relays?'**
  String get relaySettingsRestoreTitle;

  /// Body of the restore-defaults confirmation dialog, pluralised on the number of relays currently configured in the category.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{Your current 1 relay will be replaced with Haven\'s defaults. This cannot be undone.} other{Your current {count} relays will be replaced with Haven\'s defaults. This cannot be undone.}}'**
  String relaySettingsRestoreBody(int count);

  /// Confirm button in the restore-default-relays dialog.
  ///
  /// In en, this message translates to:
  /// **'Restore'**
  String get relaySettingsRestoreConfirm;

  /// Snackbar confirming that the default relays were restored.
  ///
  /// In en, this message translates to:
  /// **'Defaults restored.'**
  String get relaySettingsRestoreSuccess;

  /// Snackbar shown when restoring default relays fails.
  ///
  /// In en, this message translates to:
  /// **'Failed to restore defaults.'**
  String get relaySettingsRestoreError;

  /// Tooltip on the trash button that removes a specific relay row. {url} is the relay host (a technical address, intentionally English).
  ///
  /// In en, this message translates to:
  /// **'Remove {url}'**
  String relaySettingsRemoveTooltip(String url);

  /// Relay status label: the relay was reachable and returned the expected event.
  ///
  /// In en, this message translates to:
  /// **'Connected'**
  String get relaySettingsStatusConnected;

  /// Relay status label: a reachability check is in progress.
  ///
  /// In en, this message translates to:
  /// **'Checking'**
  String get relaySettingsStatusChecking;

  /// Relay status label: the relay could not be reached or returned an error.
  ///
  /// In en, this message translates to:
  /// **'Can\'t reach'**
  String get relaySettingsStatusUnreachable;

  /// Relay status label: the relay has not been checked yet.
  ///
  /// In en, this message translates to:
  /// **'Not checked'**
  String get relaySettingsStatusNotChecked;

  /// Accessibility label announcing a relay's connection status, where {status} is one of the status labels.
  ///
  /// In en, this message translates to:
  /// **'Relay status: {status}'**
  String relaySettingsStatusSemantics(String status);

  /// Title of the empty state shown when a relay category has no relays.
  ///
  /// In en, this message translates to:
  /// **'No relays configured'**
  String get relaySettingsEmptyTitle;

  /// Message of the empty state shown when a relay category has no relays.
  ///
  /// In en, this message translates to:
  /// **'You need at least one relay so others can reach you. Tap below to restore Haven defaults.'**
  String get relaySettingsEmptyMessage;

  /// Short tooltip on the warning icon shown next to a Profile-relay row whose URL is also one of the user's circle relays or inbox relays. Advisory only — never blocks adding or keeping the relay.
  ///
  /// In en, this message translates to:
  /// **'Also carries other Haven traffic'**
  String get relaySettingsProfileContaminationTooltip;

  /// Full screen-reader label for the Profile-relay contamination warning icon, naming the relay so the warning reads sensibly out of visual context. {url} is the relay host (a technical address, intentionally English).
  ///
  /// In en, this message translates to:
  /// **'Warning: {url} also carries your other Haven traffic, so this relay could link your profile to that traffic'**
  String relaySettingsProfileContaminationSemantics(String url);

  /// Title of the location settings page (AppBar).
  ///
  /// In en, this message translates to:
  /// **'Location'**
  String get locationSettingsTitle;

  /// Snackbar shown after the user turns off background location sharing.
  ///
  /// In en, this message translates to:
  /// **'Background sharing disabled'**
  String get locationSettingsDisabledSnack;

  /// Snackbar shown after the user turns on background location sharing.
  ///
  /// In en, this message translates to:
  /// **'Background sharing enabled'**
  String get locationSettingsEnabledSnack;

  /// Snackbar shown when background sharing cannot be enabled because the Android notification permission was denied.
  ///
  /// In en, this message translates to:
  /// **'Background sharing needs a notification so Android keeps it running. It\'s off for now. Enable notifications for Haven to turn it on.'**
  String get locationSettingsNotificationDeniedSnack;

  /// Snackbar shown when background sharing was enabled but Android battery optimization may still pause it.
  ///
  /// In en, this message translates to:
  /// **'On. Battery optimization may pause sharing on some phones. Exclude Haven from battery optimization to keep it reliable.'**
  String get locationSettingsBatteryOptSnack;

  /// Android-only advisory shown on the location settings page, under the background-sharing toggle, for as long as the user has background sharing ON but has NOT granted Haven the battery-optimization exemption (the one-off snackbar locationSettingsBatteryOptSnack said the same thing once, at the moment they declined; this line persists so the state is discoverable later). It renders beside an 'Open settings' button that opens the system battery-optimization screen. Accuracy limits, both directions: it MUST NOT say sharing IS stopped or broken — on most phones an ongoing foreground service keeps running fine, and claiming a fault the user cannot see would train them to ignore the line; and it MUST keep 'some phones', because the real risk is vendor battery managers (Samsung, Xiaomi and similar), not stock Android Doze, which a foreground service already survives. 'Battery optimization' is Android's own settings-screen wording — use the term your locale's Android system settings use, not a literal translation, so the user can find the screen.
  ///
  /// In en, this message translates to:
  /// **'Battery optimization is still on for Haven. Some phones use it to stop background sharing without warning. Exclude Haven to keep sharing reliable.'**
  String get locationSettingsBatteryOptNote;

  /// Generic snackbar shown when toggling background sharing fails unexpectedly.
  ///
  /// In en, this message translates to:
  /// **'Something went wrong'**
  String get locationSettingsErrorSnack;

  /// Framing paragraph at the top of the location settings page, and the one place the platform asymmetry is stated in full. MUST NOT promise that the user's OWN sharing resumes after the system closes the app: every background wake path (catchup_service.dart, ios_background_catchup.dart, HavenSLCHandler.swift) is receive-only and contains no publish call site, and Android has no movement trigger at all. An earlier version claimed 'updates resume when you move or when the system next wakes the app', which was false on both platforms. The wake claim is ONE sentence and must stay one: the stop, the fetch and the never-send are a single contrast, and an earlier version joined the last two with a comma splice ('...only fetch your circles' locations, they never send yours'), which reads as two separate facts rather than the asymmetry it is. 'may still wake up' is deliberate on both halves — the verb replaced the noun 'background wake-ups', which was engineer-speak in a paragraph non-technical readers meet first, and 'may' is load-bearing because neither platform guarantees a wake at all (iOS BGAppRefreshTask and the Android WorkManager sweep are both scheduled at the system's discretion). 'your own sharing stops' says whose sharing, which is the whole asymmetry. The two platform sentences are a SECOND, later correction and are platform-asymmetric on purpose: a version before them said flatly 'sharing stops until you open it again', which is false on Android in the dangerous direction. RebootReceiver is android:enabled="true" (AndroidManifest.xml) and ForegroundTaskOptions sets autoRunOnBoot:true (background_location_manager.dart), so a reboot resurrects the PUBLISHING foreground service with no user action; and no android:stopWithTask is set anywhere, so the service also survives the app being swiped out of recents. A user who reboots believing sharing stopped is still broadcasting, so never flatten these two platforms back into one sentence. The Android exception stops exactly there and must not be widened: RestartReceiver is android:enabled="false", so an OS or OEM kill of the service is never auto-restarted, and iOS has no publishing wake path at all. Those two facts are TWO sentences, each starting with its platform and each self-contained ('On iPhone, sharing stays stopped...', never 'on iPhone it...'), because this one string renders to users of both: a reader has to be able to skip the sentence that is not about their phone at a glance, and still parse the one that is. Do not rejoin them with a semicolon, and do not drop the platform name from the second.
  ///
  /// In en, this message translates to:
  /// **'Haven shares your location with your circles whenever the app is open. Turn this on and your circles keep seeing it while Haven is in the background. If the system closes Haven, your own sharing stops: Haven may still wake up to fetch your circles\' locations, but never to send yours. On Android, sharing survives swiping Haven away and starts again by itself after a reboot. On iPhone, sharing stays stopped until you open Haven.'**
  String get locationSettingsIntro;

  /// Title of the background-sharing toggle tile.
  ///
  /// In en, this message translates to:
  /// **'Share in background'**
  String get locationSettingsToggleTitle;

  /// Subtitle of the background-sharing toggle tile. MUST NOT say "when the app is closed": this toggle keeps sharing alive while Haven is BACKGROUNDED, and sharing stops when the system TERMINATES the app (every background wake path is receive-only). It renders directly beneath the toggle, immediately above locationSettingsIntro, so an over-claim here contradicts the paragraph that states the limit. That termination rule is not the whole truth, and this string is deliberately silent on the remainder rather than half-stating it: on Android the foreground service survives the app being swiped out of recents and is resurrected after a reboot (RebootReceiver + autoRunOnBoot), so sharing there resumes with no user action. locationSettingsIntro, directly below, is the one place that asymmetry is stated — keep it that way, because one tile line has no room to qualify it without misleading.
  ///
  /// In en, this message translates to:
  /// **'Keep sharing while Haven runs in the background'**
  String get locationSettingsToggleSubtitle;

  /// iOS-only note shown when background sharing is on but the location permission is only 'while in use'. Must stay honest in both directions: While-In-Use IS sufficient for continued background sharing while the app stays running (never claim 'Always' is required for that), and 'Always' still genuinely improves catch-up after iOS terminates the app (never present While-In-Use as loss-free), and 'Always' does NOT resume the user's own sharing — the SLC relaunch it enables is receive-only (HavenSLCHandler.swift), so never imply the user keeps being seen. The closing 'resumes when you reopen Haven' is true ONLY because this note is iOS-scoped — it renders behind `sharingEnabled && iosLimited`, and iosLimited is always false off iOS (location_settings_page.dart). The same sentence would be false on Android, where a reboot restarts the publishing foreground service by itself (see locationSettingsIntro), so never lift it into a cross-platform string. Sentence order is state → advice → what 'Always' changes → resume. The blue-bar clause belongs to the FIRST sentence: appended after 'resumes when you reopen Haven' any indicator clause reads as a claim about the reopened app, which is exactly why the THIRD sentence sits before that one and not after it. That third sentence is the honest consequence of the advice above it, and the note was misleading without it: a truthful sequence that told this reader the blue bar shows while Haven shares and then told them to choose 'Always', while following that advice can REMOVE the bar — under a CONFIRMED 'Always' the session handler holds no CLBackgroundActivitySession and clears showsBackgroundLocationIndicator, so only the status-bar arrow is left. It says 'may' because that is not universal: on the iOS 15/16 floor of the deployment target, under an iOS 17 'Always' (no diagnostics API, so never confirmed) and under a provisional 'Always', the bar stays — a version split no copy can resolve. Without the sentence the note recommends a change it does not disclose, and the user finds out only by re-reading a card that has silently started saying something else. 'the bar' there is an ANAPHOR for the 'blue location bar' named in the first sentence, never a second noun for it, and the arrow it names is the one locationSettingsIosIndicatorArrow names, so a single vocabulary carries this reader across the transition. The blue-bar clause is true here on iOS 15–26 whatever Haven does — the bar is mandatory OS behaviour under While-In-Use background use (QA1965), and Haven also holds a CLBackgroundActivitySession — and it uses the same ONE noun as locationSettingsIosIndicatorBar, 'blue location bar'. Under a confirmed 'Always' the card shows locationSettingsIosIndicatorArrow instead; never merge the two. Six widget tests locate this note by the English fragment 'with your current permission' (test/pages/settings/location_settings_page_test.dart), so an English rewording that moves, recases or drops that fragment has to update them in the same commit.
  ///
  /// In en, this message translates to:
  /// **'Sharing keeps working in the background with your current permission, and iOS shows its blue location bar at the top of the screen while it does. Choose \'Always\' for Haven in Settings so Haven can also catch up on your circles\' locations after iOS closes the app. Under \'Always\', iOS may show its location arrow in the status bar instead of the bar. Your own sharing resumes when you reopen Haven.'**
  String get locationSettingsIosLimitedNote;

  /// Android-only heading above the reliability guidance card.
  ///
  /// In en, this message translates to:
  /// **'OS settings for reliability'**
  String get locationSettingsAndroidHeader;

  /// Android-only reliability guidance about the persistent notification permission.
  ///
  /// In en, this message translates to:
  /// **'Haven needs a persistent notification so Android keeps the background service alive. If you denied the notification permission, open Settings and allow notifications for Haven.'**
  String get locationSettingsAndroidNotification;

  /// Android-only reliability guidance about excluding Haven from battery optimization. The arrow-separated path is a navigation breadcrumb.
  ///
  /// In en, this message translates to:
  /// **'For reliable background sharing, also exclude Haven from battery optimization. Go to Settings → Apps → Haven → Battery → Allow all the time.'**
  String get locationSettingsAndroidBattery;

  /// Android-only vendor-specific reliability guidance (Samsung/Xiaomi). 'Samsung', 'Xiaomi', and the menu paths are intentionally English brand/menu names.
  ///
  /// In en, this message translates to:
  /// **'On Samsung devices, remove Haven from \"Sleeping apps\" (Device care → Battery → Background usage limits). On Xiaomi, enable Autostart for Haven.'**
  String get locationSettingsAndroidVendors;

  /// FIRST of the two sentences of the iOS-only reliability card, which renders ONLY under IosAuthStatus.always — never under denied/notDetermined/restricted/unknown, whose users have no session to describe. The card composes, in this order: this base, then exactly ONE of locationSettingsIosIndicatorArrow / locationSettingsIosIndicatorBar, and nothing else, so a screen reader hears session → indicator as one paragraph. The indicator sentence is chosen by the session handler's own alwaysConfirmed — the predicate BOTH native branches decide from — and never by the authorization tier nor by backgroundActivitySessionHeld: a provisional 'Always' reports .authorizedAlways while the OS still treats the app as While-In-Use, and CLBackgroundActivitySession is iOS 17+, so on the iOS 15/16 floor of the deployment target nothing is ever held while the blue bar is up. Because this sentence renders under BOTH indicator states it MUST NOT name any indicator — no 'blue', no 'arrow', no 'indicator', and not the phrase 'blue location bar' (the bare word 'bar' is fine; the arrow sentence has to say 'status bar'). It must make no battery promise either — 'low-power' is banned, because the session runs at GPS accuracy whenever the user is moving or the screen is on — and must invent no pause or timer, neither of which Haven has. The accuracy tier is deliberately NOT user-visible copy: while stationary in the background the session drops to roughly 100 m accuracy and returns to GPS accuracy on movement.
  ///
  /// In en, this message translates to:
  /// **'While background sharing is on, Haven keeps a location session running so your circles keep seeing you.'**
  String get locationSettingsIosGuidance;

  /// SECOND sentence of the iOS reliability card, selected when the session handler reports alwaysConfirmed true — a CONFIRMED 'Always', which holds no CLBackgroundActivitySession. HavenBackgroundSessionHandler gates that session on !alwaysConfirmed and HavenLocationStreamHandler clears showsBackgroundLocationIndicator from the same predicate, so for this user the status-bar arrow and the Location Services listing are the only signals left, and the card must not promise a blue bar that is not there. Must name the arrow AND the status bar it appears in; must never say 'blue' or 'blue location bar'. The second half says what the Location Services listing TELLS this reader, not merely that Haven appears in it: iOS keeps the same arrow glyph beside an app that has recently used location (Apple documents a grey arrow for the last 24 hours), so the reader learns ONE symbol and can check afterwards, in the one place that survives the moment. 'for a while afterwards' is deliberately unquantified — Apple owns that window, not Haven — and no timestamp is promised, because the Location Services row carries a glyph and not a time (the timestamped view is the separate App Privacy Report, which is off by default). 'small' was dropped: it described nothing the reader can act on. 'its' is kept, matching locationSettingsIosIndicatorBar's 'its blue location bar' — the possessive is what marks both signals as the OS's own rather than something Haven draws. The Settings wording stays tier-neutral and uses only the OS's own localized 'Location Services' name: the deployment target is iOS 15, which has Settings → Privacy → Location Services, while iOS 16+ moved it under 'Privacy & Security' — a version split no localizer can resolve. Any breadcrumb uses '→', which screen readers speak, never '›', which they skip.
  ///
  /// In en, this message translates to:
  /// **'iOS shows its location arrow in the status bar while Haven uses your location, and keeps that same arrow next to Haven in Location Services for a while afterwards.'**
  String get locationSettingsIosIndicatorArrow;

  /// SECOND sentence of the iOS reliability card, selected when the session handler reports alwaysConfirmed false — every reading in which the blue bar is on screen: a provisional 'Always' (reported as .authorizedAlways while the OS still treats the app as While-In-Use), an iOS 17 'Always' (no diagnostics API, so never confirmed), the iOS 15/16 floor of the deployment target (where no CLBackgroundActivitySession can exist and showsBackgroundLocationIndicator, set from !alwaysConfirmed, is the only thing raising the bar), and every 'Always' should the confirmed-Always policy ever be withdrawn — which is why this key is also that rollback's version of the card. It NAMES the authorization instead of pointing at it: an earlier version said 'with this permission', and since the page never displays the authorization tier that phrase had no antecedent anywhere on the screen (locationSettingsIosLimitedNote's 'your current permission' works only because that note IS about the permission). Naming it is safe here and only here — this key renders exclusively under IosAuthStatus.always, so every reader of it holds 'Always', and 'Always' is the word iOS Settings shows them (a provisional 'Always' displays that way too). It states the tier and never urges granting it: that advice belongs to the While-In-Use note, and here it would ask a reader for a permission they already have. It must also not OPEN with the connector locationSettingsIosGuidance opens with — the two are read as one paragraph, and 'While ... . While ...' stutters; the reviewer wave already made this repair in es (Mientras → Cuando) and pt (Enquanto → Quando), and the other ten locales never had it. ONE noun everywhere for what the user sees, 'blue location bar', never 'indicator' or 'pill', so the words match the thing on screen. The bar is mandatory OS behaviour in this posture and cannot be turned off, so the sentence states it rather than offering it as a choice.
  ///
  /// In en, this message translates to:
  /// **'With your \'Always\' permission, iOS shows its blue location bar at the top of the screen while Haven uses your location.'**
  String get locationSettingsIosIndicatorBar;

  /// Heading of the in-app location disclosure dialog (LocationDisclosureDialog), shown before the OS permission prompt — once during onboarding, and again when the user turns on 'Share in background' on the Location settings page. This dialog is Google Play's required Prominent Disclosure and the record of the user's consent, so its register is plain and factual, never promotional. The heading only names the subject: every checkable claim lives in the paragraphs below it (locationDisclosureWhy / How / Sharing / BackgroundAndroid / BackgroundIos / Manage). Keep it to a short noun phrase — it is an AlertDialog title read aloud first by a screen reader — and never make it a question or an instruction.
  ///
  /// In en, this message translates to:
  /// **'Sharing your location'**
  String get locationDisclosureTitle;

  /// FIRST paragraph of the location disclosure dialog: WHY Haven uses location and WHAT it uses — the device's PRECISE location, shown live on the map to the circles the user picked. Play requires the disclosure to name the data and the purpose before the runtime prompt appears, so keep both halves: what is shown to whom, and which permission that needs. 'precise' is the permission actually requested and must not be softened to 'your location'. Plain, present-tense description of what the app does; it makes no promise about the background, which locationDisclosureBackgroundAndroid / locationDisclosureBackgroundIos state separately and only in the background scope.
  ///
  /// In en, this message translates to:
  /// **'Haven shows your live location to the people in the circles you choose, and shows you theirs on the map. To do this, Haven needs permission to use your device’s precise location.'**
  String get locationDisclosureWhy;

  /// SECOND paragraph of the location disclosure dialog: HOW the data is protected, and every third party it reaches. An earlier version ended 'never Haven, and never any other entity.' That was false, and false inside the artefact that records consent: encrypted location transits third-party relays (three public operators by default) that also see the user's network address, and drawing the map sends tile coordinates derived from circle members' positions to an outside map provider. A Prominent Disclosure has to name third-party transmission, not deny it — do not reintroduce an absolute here. The Stadia Maps sentence REPORTS their policy; it does not vouch for it. Haven cannot observe what a third party does with a request, and nothing in this tree re-checks stadiamaps.com, so a flat 'Stadia Maps does not sell your data' would state as Haven's own fact something Haven has no standing to know. Keep the attributed shape ('Stadia Maps says … — its own policy, which Haven cannot enforce'): it stays true whatever Stadia later changes, while still disclosing the third-party sharing Play requires. Do not collapse it into an unattributed assertion, and translate the attribution as an attribution in this language. Provenance — read at the Stadia Maps privacy policy on 2026-07-29: they do not sell/rent/trade personal information, set no cookies for end users of apps built on their services, and keep server logs ~7-14 days. Their IP-anonymisation commitment covers their ANALYTICS system, NOT API request logs, so this must never be shortened to a 'no logging' or 'anonymous' claim, which would be false. Uses the precise term 'end-to-end encrypted' (consistent with the iOS usage strings), never the softer onboarding phrasing.
  ///
  /// In en, this message translates to:
  /// **'Your location is end-to-end encrypted on your device, so only the members of the circles you choose can read it, not Haven. Haven runs no servers of its own: your encrypted updates pass through independent relays run by other people, which see your network address but never where you are. Drawing the map asks Stadia Maps for the areas around you and your circle, so it learns roughly where that is, but never your name, your key, or who is in your circles. Stadia Maps says it does not sell or trade personal information, sets no cookies on your device, and keeps server logs for about two weeks — its own policy, which Haven cannot enforce.'**
  String get locationDisclosureHow;

  /// THIRD paragraph of the location disclosure dialog: WHEN sharing happens, and the only way to stop it. Always shown, unlike the background sentence and locationDisclosureManage, which render only when background sharing is being requested. Foreground sharing is unconditional and there is no pause control anywhere in Haven, so a dialog that offered only the background toggle as 'control' would advertise a switch while withholding the main behaviour. All three facts are load-bearing: that it is automatic, that nothing pauses it, and that leaving the circle is the remedy. 'every couple of minutes' is deliberately approximate — the publish cadence is jittered — so do not translate it into an exact interval.
  ///
  /// In en, this message translates to:
  /// **'While Haven is open and you are in a circle, your location is sent automatically every couple of minutes. There is no pause. To stop sharing with a circle, leave it.'**
  String get locationDisclosureSharing;

  /// Background-use sentence of the location disclosure dialog on ANDROID, rendered only when background sharing is being requested. Says 'uses' rather than the Play sample's 'collects': Haven transmits location only as end-to-end-encrypted messages and keeps no central copy, so 'collects' would misstate what actually happens. 'even when the app is closed or not in use' is the Play sample's own wording and is TRUE on Android: the foreground service is not stopped when the user swipes Haven out of recents (no android:stopWithTask, which defaults to false — AndroidManifest.xml), and that service publishes on its own timer (background_location_task.dart). Keep all three Play elements — the data (location), that the use is background, and the purpose. This sentence is FALSE on iOS, which is why locationDisclosureBackgroundIos exists and why the dialog picks between them by platform; never merge the two.
  ///
  /// In en, this message translates to:
  /// **'This app uses location data to enable sharing with your circles even when the app is closed or not in use.'**
  String get locationDisclosureBackgroundAndroid;

  /// Background-use sentence of the location disclosure dialog on iOS, where locationDisclosureBackgroundAndroid would be a lie. Chosen per platform because this dialog is the record of the user's consent and is shown on BOTH platforms, with no platform gate at either call site. Still carries all three Play elements (the data, that the use is background, and the purpose), and then states the limit iOS imposes: every native wake path is receive-only, so once iOS terminates Haven the user's OWN sharing stops until they reopen it. That second sentence must keep BOTH halves of the asymmetry — sharing stops, and a wake may still FETCH the circles' locations but never SEND the user's — because naming the not-running state without saying what stops is exactly the claim test/lints/background_claim_accuracy_test.dart forbids. It says the SAME thing as locationSettingsIntro, the settings paragraph the user meets later, and the two must not diverge on that claim; a test in that same lint file fails if they do. 'may still wake up' is deliberate and matches the intro: the verb replaced the noun 'background wake-ups', which was engineer-speak in a consent artefact non-technical readers must understand, and 'may' is load-bearing because iOS guarantees no wake at all (BGAppRefreshTask is scheduled at the system's discretion). Keep the stop, the fetch and the never-send as ONE contrasting sentence — an earlier version joined the last two with a comma splice, which reads as two separate facts rather than the asymmetry it is.
  ///
  /// In en, this message translates to:
  /// **'This app uses location data to enable sharing with your circles even when Haven is in the background and you are not using it. If iOS closes Haven, sharing stops until you open it again — Haven may still wake up to fetch your circles’ locations, but never to send yours.'**
  String get locationDisclosureBackgroundIos;

  /// Closing line of the location disclosure dialog, rendered only when background sharing is being requested (onboarding setup and the Settings toggle): the user stays in control and can withdraw this consent. It is a claim about a control that must really exist — the 'Share in background' toggle on the Location settings page — so the arrow-separated path is a navigation breadcrumb naming that screen and must match the labels this locale uses for it (see locationSettingsTitle). It is about BACKGROUND sharing only: foreground sharing has no off switch, which locationDisclosureSharing states, so never widen this to 'turn sharing off'.
  ///
  /// In en, this message translates to:
  /// **'You can turn background sharing off at any time in Settings → Location.'**
  String get locationDisclosureManage;

  /// Affirmative button of the location disclosure dialog: tapping it records the user's consent and is the only path to the OS permission prompt. Records consent and asserts nothing about behaviour. A short verb in this language's own convention for an affirmative dialog action, never a bare 'OK' (which does not read as agreement) and never a phrase that re-states the promise.
  ///
  /// In en, this message translates to:
  /// **'Agree'**
  String get locationDisclosureAgree;

  /// Dismissal button of the location disclosure dialog: it declines consent and asserts nothing about behaviour. 'Not now' rather than 'Cancel' or 'No': declining is not an error and the user can return to this dialog later, so the label must stay neutral and leave the door open. It is the safe default — a back gesture or any other dismissal is treated as this button, never as consent.
  ///
  /// In en, this message translates to:
  /// **'Not now'**
  String get locationDisclosureNotNow;

  /// Text of the Android ongoing foreground-service notification while background sharing is on and Haven is in the background. This is the ONE surface a user sees for as long as Haven runs behind other apps, so it must state exactly what Haven is doing and nothing more. Both halves are load-bearing and both are literally true on this path: Haven is sending this device's location to its circles AND receiving the circles' locations. Do not shorten it to 'sharing your location' (that hides the receiving half), and do not add a promise about what happens if the system closes Haven. It is a statement about the app's activity, not an instruction to the user. Paired with the notification title 'Haven', which stays the untranslated product name.
  ///
  /// In en, this message translates to:
  /// **'Haven is sending and receiving location information'**
  String get fgsNotificationSharing;

  /// Text of the same Android foreground-service notification when Haven could not hand its encrypted-messaging session to the service, so the service can neither send nor receive until the user reopens Haven. 'Haven is paused' describes the APP's STATE: it is NOT an imperative ('pause Haven'), NOT the user's own state, and NOT a claim that the user pressed a pause control — Haven has no pause button. The second clause is the remedy and must stay actionable: reopening the app is what repairs this. Keep the state before the remedy, and keep it to one line — Android collapses this notification to a single line, so a translation that buries the state gets truncated away. A user must be able to tell it apart at a glance from fgsNotificationSharing, which is this same notification when the handover DID work.
  ///
  /// In en, this message translates to:
  /// **'Haven is paused — open the app to resume sharing'**
  String get fgsNotificationPaused;

  /// Text of the Android foreground-service notification while Haven is in the FOREGROUND: the service is running, but the app itself is doing the sending and receiving, so this line deliberately claims no background activity. 'open' is the app's STATE — Haven is currently open, in use, on screen. Never the imperative 'open Haven', which would instruct a user who already has it open, and never the 'open' of 'open source'. Very short by design so it survives the collapsed single-line notification without truncation. Contrast with fgsNotificationSharing, shown on this same notification once the app is backgrounded.
  ///
  /// In en, this message translates to:
  /// **'Haven is open'**
  String get fgsNotificationOpen;

  /// Name of the Android notification CHANNEL the foreground-service notification belongs to. Shown in the system settings app (Settings > Apps > Haven > Notifications), in a list beside the app's other categories, and in the 'category' line the user long-presses the notification to reach — never inside Haven itself. So this is settings-page register, not notification register: a SHORT NOUN PHRASE naming a category of notifications, the way an OS settings list labels one. Not a sentence, not an instruction, no final period, and no verb — 'Location Sharing', never 'Haven is sharing your location' or 'Share location'. Keep it short: the system truncates it in a single-line list row. Follow the platform's own convention for this language on capitalization (English title-cases channel names; most languages do not).
  ///
  /// In en, this message translates to:
  /// **'Location Sharing'**
  String get fgsChannelName;

  /// Description of that same Android notification channel, shown as one line of secondary text under fgsChannelName in the system settings app. Answers 'what are the notifications in this category for?' — it describes what the ongoing notification's service DOES, so the user can decide whether to keep the category enabled. Exactly ONE sentence, ending with a period, in the same calm settings-page register as fgsChannelName. 'encrypted' is a factual claim Haven makes everywhere about location data and must survive translation; 'in the background' means while the app is not on screen, not 'secretly'. Do not turn it into an instruction, a warning, or a promise about battery.
  ///
  /// In en, this message translates to:
  /// **'Keeps Haven sharing your encrypted location in the background.'**
  String get fgsChannelDescription;

  /// Title of the map-style settings page (AppBar).
  ///
  /// In en, this message translates to:
  /// **'Map style'**
  String get mapStyleTitle;

  /// Title of the 'Minimal' map-style option (the theme-aware low-detail basemap).
  ///
  /// In en, this message translates to:
  /// **'Minimal'**
  String get mapStyleMinimalTitle;

  /// Subtitle of the 'Minimal' map-style option.
  ///
  /// In en, this message translates to:
  /// **'Calm, low-detail canvas that follows your light or dark theme'**
  String get mapStyleMinimalSubtitle;

  /// Title of the 'Detailed' map-style option (full-colour streets and places).
  ///
  /// In en, this message translates to:
  /// **'Detailed'**
  String get mapStyleDetailedTitle;

  /// Subtitle of the 'Detailed' map-style option.
  ///
  /// In en, this message translates to:
  /// **'Full-colour streets, labels, and places'**
  String get mapStyleDetailedSubtitle;

  /// Title of the 'Outdoors' map-style option (shaded terrain with trails).
  ///
  /// In en, this message translates to:
  /// **'Outdoors'**
  String get mapStyleOutdoorsTitle;

  /// Subtitle of the 'Outdoors' map-style option.
  ///
  /// In en, this message translates to:
  /// **'Shaded terrain with trails and parks'**
  String get mapStyleOutdoorsSubtitle;

  /// Section header above the live map-style previews.
  ///
  /// In en, this message translates to:
  /// **'Preview'**
  String get mapStylePreviewHeader;

  /// Label for the city preview scene on the map-style page.
  ///
  /// In en, this message translates to:
  /// **'City'**
  String get mapStylePreviewCity;

  /// Label for the nature preview scene on the map-style page.
  ///
  /// In en, this message translates to:
  /// **'Nature'**
  String get mapStylePreviewNature;

  /// Accessibility label for a live map preview image, naming the scene (City/Nature) and the style.
  ///
  /// In en, this message translates to:
  /// **'Map preview ({scene}): {style}'**
  String mapStylePreviewSemantics(String scene, String style);

  /// Accessibility label for the placeholder shown when no map API key is configured (debug/test builds).
  ///
  /// In en, this message translates to:
  /// **'Map preview unavailable in this build'**
  String get mapStylePreviewUnavailableSemantics;

  /// Caption inside the placeholder shown when no map API key is configured (debug/test builds).
  ///
  /// In en, this message translates to:
  /// **'Live preview appears in release builds'**
  String get mapStylePreviewUnavailableLabel;

  /// Title of the About page (AppBar).
  ///
  /// In en, this message translates to:
  /// **'About'**
  String get aboutTitle;

  /// The app name 'Haven' shown in the About page hero. A brand name, intentionally English (not translated).
  ///
  /// In en, this message translates to:
  /// **'Haven'**
  String get aboutHeroName;

  /// Tagline shown beneath the app name in the About page hero.
  ///
  /// In en, this message translates to:
  /// **'Private and censorship-resistant location sharing.'**
  String get aboutHeroTagline;

  /// List-tile label that opens the bundled open-source license page.
  ///
  /// In en, this message translates to:
  /// **'Open-source licenses'**
  String get aboutLicensesTitle;

  /// Legalese line shown on the bundled license page. 'Haven' and 'MIT License' are intentionally English (brand/license names).
  ///
  /// In en, this message translates to:
  /// **'© 2026 Haven · MIT License'**
  String get aboutLicensesLegalese;

  /// List-tile label linking to OpenStreetMap's 'fix the map' page.
  ///
  /// In en, this message translates to:
  /// **'Report a map issue'**
  String get aboutReportMapIssue;

  /// List-tile label linking to OpenStreetMap's support/donate page. 'OpenStreetMap' is intentionally English (project name).
  ///
  /// In en, this message translates to:
  /// **'Support OpenStreetMap'**
  String get aboutSupportOsm;

  /// Mandatory map-data attribution line. Provider names (Stadia Maps, OpenMapTiles, OpenStreetMap) and 'ODbL' are intentionally English (attribution is verbatim).
  ///
  /// In en, this message translates to:
  /// **'© Stadia Maps · © OpenMapTiles · © OpenStreetMap contributors\nMap data licensed under ODbL'**
  String get aboutMapAttribution;

  /// Snackbar shown when an external link could not be opened.
  ///
  /// In en, this message translates to:
  /// **'Could not open link'**
  String get aboutLinkOpenError;

  /// Footer line stating the app's license. 'MIT License' is intentionally English (license name).
  ///
  /// In en, this message translates to:
  /// **'Licensed under the MIT License'**
  String get aboutFooterLicense;

  /// Footer line showing the app version, e.g. 'Version 0.1.0'. {version} is a technical version string, intentionally English.
  ///
  /// In en, this message translates to:
  /// **'Version {version}'**
  String aboutFooterVersion(String version);

  /// Two-sentence caption below the relay lists on the Relay settings page, replacing a much longer explainer. Keeps just enough framing to make the 'Inbox' and 'KeyPackage' section headers meaningful. 'relay' is a Nostr term of art — keep this locale's established rendering.
  ///
  /// In en, this message translates to:
  /// **'Haven has no server of its own. Your encrypted updates pass through independent servers called relays, which cannot read your location or your messages.'**
  String get relaySettingsBackendCaption;

  /// Generic button that clears all selected items in a list.
  ///
  /// In en, this message translates to:
  /// **'Clear All'**
  String get commonClearAll;

  /// Member-count label shown under a circle, e.g. '1 member' or '3 members'.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 member} other{{count} members}}'**
  String commonMemberCount(int count);

  /// A bare standalone number rendered in the active locale's numbering system (e.g. a notification badge count). {count} is the integer value.
  ///
  /// In en, this message translates to:
  /// **'{count}'**
  String commonNumber(int count);

  /// Title of the Circles page (AppBar).
  ///
  /// In en, this message translates to:
  /// **'Circles'**
  String get circlesTitle;

  /// Tooltip on the button that reloads the list of circles.
  ///
  /// In en, this message translates to:
  /// **'Refresh circles'**
  String get circlesRefreshTooltip;

  /// Snackbar shown when the user taps Create Circle before an identity exists.
  ///
  /// In en, this message translates to:
  /// **'Circle creation requires identity setup first'**
  String get circlesRequiresIdentity;

  /// Label of the button/action that starts creating a new circle.
  ///
  /// In en, this message translates to:
  /// **'Create Circle'**
  String get circlesCreateCta;

  /// Section header above the user's list of circles on the Circles page.
  ///
  /// In en, this message translates to:
  /// **'Your Circles'**
  String get circlesYourCircles;

  /// Title of the empty state shown when the user has no circles.
  ///
  /// In en, this message translates to:
  /// **'No Circles Yet'**
  String get circlesEmptyTitle;

  /// Message of the empty state shown on the Circles page when the user has no circles.
  ///
  /// In en, this message translates to:
  /// **'Create a circle to start sharing your location with trusted friends and family.'**
  String get circlesEmptyMessage;

  /// Message of the empty state shown inside the circles bottom sheet when the user has no circles.
  ///
  /// In en, this message translates to:
  /// **'Create a circle to start sharing your location with trusted contacts.'**
  String get circlesSheetEmptyMessage;

  /// Message shown in the circles bottom sheet when the circle list fails to load.
  ///
  /// In en, this message translates to:
  /// **'Could not load circles'**
  String get circlesLoadError;

  /// Hint shown in the circles bottom sheet when circles exist but none is selected.
  ///
  /// In en, this message translates to:
  /// **'Select a circle to view members'**
  String get circlesSelectToView;

  /// Placeholder shown in the circles bottom sheet when the selected circle has no members.
  ///
  /// In en, this message translates to:
  /// **'No members in this circle'**
  String get circlesNoMembers;

  /// Title of the first circle-creation step where members are selected (AppBar).
  ///
  /// In en, this message translates to:
  /// **'Add Members'**
  String get createCircleTitle;

  /// Header above the chosen-members list showing how many are selected, e.g. 'Selected (3)'.
  ///
  /// In en, this message translates to:
  /// **'Selected ({count})'**
  String createCircleSelectedCount(int count);

  /// Title of the empty state on the add-members step before any member is chosen.
  ///
  /// In en, this message translates to:
  /// **'Add circle members'**
  String get createCircleEmptyTitle;

  /// Message of the empty state on the add-members step explaining how to add members.
  ///
  /// In en, this message translates to:
  /// **'Search by ID or scan their QR code to add members.'**
  String get createCircleEmptyMessage;

  /// Error shown when the user tries to continue with no valid members selected.
  ///
  /// In en, this message translates to:
  /// **'No valid members to invite'**
  String get createCircleNoValidMembers;

  /// Snackbar shown when a scanned QR code contains no recognizable member ID.
  ///
  /// In en, this message translates to:
  /// **'No valid ID found in QR code'**
  String get createCircleNoIdInQr;

  /// Member validation error: no KeyPackage was found for the entered ID, so the person has no Haven account. 'Haven' is intentionally English (brand name).
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t find a Haven account for this ID'**
  String get createCircleNoAccountFound;

  /// Member validation error shown on a relay/network failure; the validation can be retried.
  ///
  /// In en, this message translates to:
  /// **'Could not verify member'**
  String get createCircleCouldNotVerify;

  /// Generic member validation error shown on an unexpected failure.
  ///
  /// In en, this message translates to:
  /// **'Something went wrong'**
  String get createCircleSomethingWentWrong;

  /// Title of the second circle-creation step where the circle is named (AppBar).
  ///
  /// In en, this message translates to:
  /// **'Name Your Circle'**
  String get nameCircleTitle;

  /// Summary of how many members will be invited to the new circle.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 member will be invited} other{{count} members will be invited}}'**
  String nameCircleMembersToInvite(int count);

  /// Label of the circle-name text field.
  ///
  /// In en, this message translates to:
  /// **'Circle Name'**
  String get nameCircleNameLabel;

  /// Hint inside the circle-name text field showing example names.
  ///
  /// In en, this message translates to:
  /// **'e.g., Family, Close Friends'**
  String get nameCircleNameHint;

  /// Validation error shown when the circle-name field is left empty.
  ///
  /// In en, this message translates to:
  /// **'Please enter a circle name'**
  String get nameCircleNameEmptyError;

  /// Validation error shown when the circle name exceeds 50 characters.
  ///
  /// In en, this message translates to:
  /// **'Name must be 50 characters or less'**
  String get nameCircleNameTooLongError;

  /// Plain-language note explaining what sharing in this circle means. 'Settings → Identity' is a navigation breadcrumb.
  ///
  /// In en, this message translates to:
  /// **'Everyone in this circle can see each other\'s location, and each other\'s public name and photo. Your name and photo are public on the Nostr network, not private to this circle. This circle stays separate from any others you\'re in, so its members can\'t see your other circles or who\'s in them.'**
  String get nameCircleSharingInfo;

  /// Primary button that creates the circle on the naming step.
  ///
  /// In en, this message translates to:
  /// **'Create Circle'**
  String get nameCircleCreateCta;

  /// Progress label shown while the encrypted MLS group is being created.
  ///
  /// In en, this message translates to:
  /// **'Creating secure group...'**
  String get nameCircleStageCreatingGroup;

  /// Progress label shown while circle invitations are being sent.
  ///
  /// In en, this message translates to:
  /// **'Sending invitations...'**
  String get nameCircleStageSendingInvites;

  /// Progress label shown when circle creation has completed.
  ///
  /// In en, this message translates to:
  /// **'Done!'**
  String get nameCircleStageComplete;

  /// Accessibility live-region label announcing the current circle-creation stage. {stage} is one of the stage labels.
  ///
  /// In en, this message translates to:
  /// **'Creation progress: {stage}'**
  String nameCircleProgressSemantics(String stage);

  /// Accessibility value announcing creation progress as a percentage, e.g. '66 percent complete'.
  ///
  /// In en, this message translates to:
  /// **'{percent} percent complete'**
  String nameCirclePercentComplete(int percent);

  /// Snackbar after creating a circle when only SOME invitations reached a relay. Replaces reusing addMemberPartialDelivery here: that string was written for the add-member page, where the circle already exists and the user knows it, so on the create flow it reported delivery while silently dropping the primary outcome — that the circle was created at all. Both facts must survive translation, and the circle name must stay present, because the user is popped two screens back immediately after seeing this. Keep the counts honest: {sent} is the number of invitations a relay actually acked, not the number of people invited.
  ///
  /// In en, this message translates to:
  /// **'Circle \"{name}\" created. Invitations sent ({sent} of {total}); delivery pending for the rest.'**
  String nameCircleCreatedPartialSnack(String name, int sent, int total);

  /// Success snackbar after creating a circle, naming it and how many invitations were sent. {name} is the user-entered circle name.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{Circle \"{name}\" created! 1 invitation sent.} other{Circle \"{name}\" created! {count} invitations sent.}}'**
  String nameCircleCreatedSnack(String name, int count);

  /// Error shown on the naming step when the user's identity could not be used to create the circle.
  ///
  /// In en, this message translates to:
  /// **'Identity error. Please check your identity setup.'**
  String get nameCircleIdentityError;

  /// Error shown on the naming step when circle creation fails.
  ///
  /// In en, this message translates to:
  /// **'Failed to create circle. Please try again.'**
  String get nameCircleCreateError;

  /// Error shown on the naming step when the user already belongs to the maximum number of circles ({limit}, kMaxCirclesPerAccount) so the circle was NOT created. Must state the limit AND the remedy — leaving a circle — because retrying can never succeed; do not translate this as a transient failure or add 'try again'. Mark the ceiling EXPLICITLY in your language ('up to', 'at most', 'only', a restrictive construction, a bounding particle — whatever your language uses): a bare positive ('you can be in 10 circles') reads as capability or permission rather than as a limit in most of the languages this app ships, and under a possessive framing it is also ambiguous between 'exactly 10' and 'up to 10'. Eleven of the twelve locales independently had to add a limiter to the previous, unmarked English wording, which is why the English marks it now too. {limit} is the maximum, currently 10.
  ///
  /// In en, this message translates to:
  /// **'You can be in up to {limit} circles at a time. Leave a circle to make room for a new one.'**
  String nameCircleRosterFullError(int limit);

  /// Title of the add-member page (AppBar), naming the circle members are being added to. {circleName} is the user-chosen circle name.
  ///
  /// In en, this message translates to:
  /// **'Add to {circleName}'**
  String addMemberTitle(String circleName);

  /// Plain-language note on the add-member page explaining what a new member can see once they accept.
  ///
  /// In en, this message translates to:
  /// **'Once they accept, they will see everyone\'s location from that point on, never anything sent before they joined. They will also see the public keys of everyone already in this circle.'**
  String get addMemberInfo;

  /// Member validation error shown when the entered ID is already a member of this circle.
  ///
  /// In en, this message translates to:
  /// **'Already in this circle'**
  String get addMemberAlreadyInCircle;

  /// Label of the send button on the add-member page, pluralised by the number of selected members.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{Send invitation} other{Send invitations}}'**
  String addMemberSendInvitation(int count);

  /// In-progress label of the send button on the add-member page, pluralised by the number of selected members.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{Sending invitation...} other{Sending invitations...}}'**
  String addMemberSendingInvitation(int count);

  /// Success snackbar after fully sending invitations on the add-member page. {circleName} is the circle name.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{Invitation sent to {circleName}} other{Invitations sent to {circleName}}}'**
  String addMemberSentToCircle(int count, String circleName);

  /// Snackbar after partially sending invitations on the add-member page, reporting how many were delivered.
  ///
  /// In en, this message translates to:
  /// **'Invitations sent ({sent} of {total}). Delivery pending for the rest.'**
  String addMemberPartialDelivery(int sent, int total);

  /// Error snackbar shown when adding a member fails.
  ///
  /// In en, this message translates to:
  /// **'Failed to add member. Please try again.'**
  String get addMemberError;

  /// Title of the QR-code scanner page (AppBar).
  ///
  /// In en, this message translates to:
  /// **'Scan QR Code'**
  String get qrScannerTitle;

  /// Tooltip on the torch/flashlight toggle button in the QR scanner.
  ///
  /// In en, this message translates to:
  /// **'Toggle flash'**
  String get qrScannerToggleFlash;

  /// Tooltip on the front/back camera switch button in the QR scanner.
  ///
  /// In en, this message translates to:
  /// **'Switch camera'**
  String get qrScannerSwitchCamera;

  /// Instruction text overlaid on the QR scanner camera view.
  ///
  /// In en, this message translates to:
  /// **'Position the QR code within the frame'**
  String get qrScannerInstruction;

  /// Status text shown below the QR scanner instruction while scanning.
  ///
  /// In en, this message translates to:
  /// **'Scanning...'**
  String get qrScannerScanning;

  /// Subtitle shown for an accepted member with no cached location.
  ///
  /// In en, this message translates to:
  /// **'No recent location'**
  String get circleMemberNoRecentLocation;

  /// Tooltip on the admin button that removes a member from the circle. LIVE since 2026-08-15: rendered by CircleMemberTile for an admin viewer on another member's row in a circle that is not blocked, and wired from circles_bottom_sheet.dart to CircleService.removeMember through confirmAndRemoveMember. Do NOT confuse this with the sibling pendingMemberRemoveTooltip, which removes an npub from the local pre-invite picker rather than a member from a circle. The button is also rendered DISABLED (same tooltip) on every other row while one removal is in flight.
  ///
  /// In en, this message translates to:
  /// **'Remove from circle'**
  String get circleMemberRemoveTooltip;

  /// Title of the confirmation dialog for the admin removing a member. Names the member so the admin can check they tapped the row they meant.
  ///
  /// In en, this message translates to:
  /// **'Remove {name}?'**
  String circleMemberRemoveDialogTitle(String name);

  /// Body of the remove-member confirmation dialog. States what removal does and does not do: the group re-keys so the removed member cannot read later location updates (INV-E-REMOVAL-ADVANCES-EPOCH), the convergence caveat is the same one leaving carries, already-received locations are beyond our reach, and there is no undo short of a fresh invitation. Do NOT add a claim that the removed person is notified, or that anything already delivered is deleted — neither is true.
  ///
  /// In en, this message translates to:
  /// **'They stop being able to read anything new from this circle once the rest of it has caught up, usually within a few minutes, longer for anyone who was offline at the time. Whatever they already received stays on their phone. To undo this you would have to invite them again.'**
  String get circleMemberRemoveDialogBody;

  /// Destructive confirm button in the remove-member dialog.
  ///
  /// In en, this message translates to:
  /// **'Remove'**
  String get circleMemberRemoveConfirm;

  /// Label of the progress indicator that replaces the remove button on the row being removed, and the screen-reader announcement made once when the removal starts.
  ///
  /// In en, this message translates to:
  /// **'Removing {name}…'**
  String circleMemberRemoveInProgress(String name);

  /// SnackBar and screen-reader announcement after a removal that was published and acknowledged by at least one relay. Past tense is accurate: the service only returns once the commit is confirmed (Security Rule 13).
  ///
  /// In en, this message translates to:
  /// **'Removed {name} from the circle'**
  String circleMemberRemoveSuccess(String name);

  /// SnackBar and screen-reader announcement after a failed removal. 'Nothing changed' is exact rather than reassuring: the service rolls its staged commit back when the publish is not acknowledged, so the member is still in the circle and the epoch did not move.
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t remove {name}. Nothing changed — check your connection and try again.'**
  String circleMemberRemoveError(String name);

  /// Chip label marking a circle member as an administrator.
  ///
  /// In en, this message translates to:
  /// **'Admin'**
  String get circleMemberAdmin;

  /// Accessibility hint appended to a member's name when no location is available.
  ///
  /// In en, this message translates to:
  /// **'no location available'**
  String get circleMemberHintNoLocation;

  /// Accessibility hint appended to a member's name when the row is a non-actionable member.
  ///
  /// In en, this message translates to:
  /// **'member'**
  String get circleMemberHintMember;

  /// Accessibility hint appended to a member's name when tapping the row centers the map on them.
  ///
  /// In en, this message translates to:
  /// **'tap to center map on their location'**
  String get circleMemberHintTapToCenter;

  /// Tooltip on the button that retries validating a pending member after a network failure.
  ///
  /// In en, this message translates to:
  /// **'Retry validation'**
  String get pendingMemberRetryTooltip;

  /// Tooltip on the button that drops someone from the staged list of people you are about to invite, BEFORE any invitation is sent. Deliberately not "Remove member": Haven ships no way to remove an existing member from a circle. This label must not be readable as circle-member removal.
  ///
  /// In en, this message translates to:
  /// **'Remove from list'**
  String get pendingMemberRemoveTooltip;

  /// Accessibility label for the spinner shown while a pending member is being validated.
  ///
  /// In en, this message translates to:
  /// **'Validating'**
  String get pendingMemberValidating;

  /// Accessibility label for the icon shown when a pending member passed validation.
  ///
  /// In en, this message translates to:
  /// **'Valid'**
  String get pendingMemberValid;

  /// Accessibility label for the icon shown when a pending member failed validation.
  ///
  /// In en, this message translates to:
  /// **'Warning'**
  String get pendingMemberWarning;

  /// Subtitle shown while a pending member's KeyPackage is being fetched.
  ///
  /// In en, this message translates to:
  /// **'Checking availability...'**
  String get pendingMemberCheckingAvailability;

  /// Subtitle shown when a pending member passed validation and can be invited.
  ///
  /// In en, this message translates to:
  /// **'Ready to invite'**
  String get pendingMemberReadyToInvite;

  /// Subtitle/accessibility label shown when a pending member's discovered KeyPackage is the deprecated pre-migration kind — the person is running an old Haven build and must update it before they can be invited (Dark Matter migration).
  ///
  /// In en, this message translates to:
  /// **'Needs to update Haven'**
  String get pendingMemberNeedsUpdate;

  /// Hint inside the member-search text field where a member ID is entered.
  ///
  /// In en, this message translates to:
  /// **'Enter member ID...'**
  String get memberSearchHint;

  /// Tooltip on the button that pastes a member ID from the clipboard.
  ///
  /// In en, this message translates to:
  /// **'Paste from clipboard'**
  String get memberSearchPasteTooltip;

  /// Tooltip on the button that adds the entered member ID.
  ///
  /// In en, this message translates to:
  /// **'Add member'**
  String get memberSearchAddTooltip;

  /// Tooltip on the button that opens the QR scanner to add a member.
  ///
  /// In en, this message translates to:
  /// **'Scan QR Code'**
  String get memberSearchScanTooltip;

  /// Helper text under the member-search field. 'Haven' is intentionally English (brand name).
  ///
  /// In en, this message translates to:
  /// **'Ask contacts for their Haven QR code or ID'**
  String get memberSearchHelper;

  /// Inline error shown when the entered text is not a recognizable Haven ID. 'Haven' is intentionally English (brand name).
  ///
  /// In en, this message translates to:
  /// **'No valid Haven ID found'**
  String get memberSearchNoValidId;

  /// Inline error shown when the entered member ID is already in the selected list.
  ///
  /// In en, this message translates to:
  /// **'Member already added'**
  String get memberSearchAlreadyAdded;

  /// Heading above the list of people offered as picks when inviting someone to a circle. It states ONLY that each pubkey is on the member list of a circle stored on this device. Haven cannot observe whether any of them ever accepted an invitation — processing an MLS Welcome puts nothing on the wire — so this heading must never say or imply joined, accepted, confirmed, verified, active, connected, or sharing with you.
  ///
  /// In en, this message translates to:
  /// **'Members of your circles'**
  String get memberPickerSectionRoster;

  /// Spoken by screen readers as part of every picker row's label, because a reader swiping row by row never hears the heading above them. Same claim, and the same restrictions, as memberPickerSectionRoster, phrased for one person.
  ///
  /// In en, this message translates to:
  /// **'Member of your circles'**
  String get memberPickerTierRoster;

  /// Shown, and announced once, when what was typed matches nobody in the user's circles. The person can still be invited by pasting their full ID, so this must not read as a dead end.
  ///
  /// In en, this message translates to:
  /// **'No matches in your circles'**
  String get memberPickerNoMatches;

  /// Screen-reader label for the progress indicator shown while the on-device list of co-members is read. No relay is contacted; do not imply a download.
  ///
  /// In en, this message translates to:
  /// **'Loading people from your circles'**
  String get memberPickerLoading;

  /// Shown in place of the picker's list when the on-device directory of co-members could not be read at all (a storage or lookup fault) — distinct from memberPickerNoMatches, which means the read SUCCEEDED and simply matched nobody, and distinct from the silent empty state on a fresh install, which means the read succeeded and truthfully found no co-members yet. This string must never be read as either of those: it says the answer is unknown, not that it is empty or negative. The person can still be invited by pasting or scanning their full ID, so this must not read as a dead end, and must not display any raw error text (Security Rule 8 — never surface exception detail to the UI).
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t load who\'s in your circles right now'**
  String get memberPickerDirectoryUnavailable;

  /// Announced to screen readers once a search has settled, giving how many people match what was typed. Deliberately a label-and-number construction rather than a sentence, so that no language needs a plural form for it.
  ///
  /// In en, this message translates to:
  /// **'Matches: {count}'**
  String memberPickerMatchesAnnouncement(int count);

  /// Why someone cannot be added: the entered ID, or the row, is the user's own identity. Shown under the search field when the user enters their own ID, and as the reason on a disabled picker row. Must stay distinct from 'Already in this circle' — being unable to invite yourself is a different fact from already being a member.
  ///
  /// In en, this message translates to:
  /// **'This is your own ID'**
  String get memberPickerReasonSelf;

  /// Screen-reader custom action on a picker row that SPEAKS the person's public key aloud — it does not display or open it. The word 'aloud' is load-bearing: without it, four of the first five translators rendered 'read' in the read-with-your-eyes sense, which many languages distinguish with a different verb entirely (German vorlesen vs lesen). Translate the speaking sense. This label is also a fixed string and must never contain the key itself: Flutter interns custom-action labels in a process-wide map with no prune path, so a per-person label would hold identifier text for the life of the process.
  ///
  /// In en, this message translates to:
  /// **'Read public key aloud'**
  String get memberPickerReadPublicKey;

  /// Heading above the SECOND section of the invite picker (below memberPickerSectionRoster): people who shared a circle with the user within the last few days but are no longer on any current circle's member list (P3, plan §7.2). States ONLY roster provenance, exactly like memberPickerSectionRoster — Haven cannot observe whether any of them ever accepted an invitation or is still reachable, so this heading must never say or imply joined, accepted, confirmed, verified, active, connected, or sharing with you.
  ///
  /// In en, this message translates to:
  /// **'Recently in your circles'**
  String get memberPickerSectionRecent;

  /// Spoken by screen readers as part of every tier-1 (recent) picker row's label, because a reader swiping row by row never hears the heading above them. Same claim, and the same restrictions, as memberPickerSectionRecent, phrased so it also reads naturally appended to one person's name.
  ///
  /// In en, this message translates to:
  /// **'Recently in your circles'**
  String get memberPickerTierRecent;

  /// Tooltip shown on long-press on the small mark beside a picker row's name when the name shown is the local nickname the user saved for that person, rather than their public Nostr name. On THIS surface the mark carries no semantics label of its own — its enclosing Semantics node drops every descendant, so a screen reader hears this string only as ONE CLAUSE inside the row's own joined label, spoken together with the person's name and tier, never as its own announcement the way a standalone icon label would be. Translate it so it reads naturally appended after a name in a list of short clauses, not as a self-contained sentence. States where the name came from and nothing more — it is NOT a verification, trust, safety or identity-confirmation claim, and must not be translated as one. Same string and purpose as invitationCardNicknameNote on the invitation card, where the mark DOES carry its own semantics label as a separate node — the wording is shared between the two screens, but only invitationCardNicknameNote is spoken that way.
  ///
  /// In en, this message translates to:
  /// **'Your nickname for them, not their public name'**
  String get memberPickerNicknameNote;

  /// Shown on an invite-picker row, and included in its screen-reader label, ONLY when another row in the FIRST section (memberPickerSectionRoster, tier-0) resolves to the exact same displayed name as this one. It can never appear in the recent section: a tier-1 person is no longer a co-member of anything, so no current circle could be the reason their name collides. {circleName} is chosen to be UNIQUE to this row among every row it collides with — the alphabetically first of THIS row's own circles that is NOT also a circle any OTHER colliding row's person shares with the user, so the two colliding rows normally name DIFFERENT circles. When no such circle exists (every one of this row's circles is also shared by a rival), this note is omitted for that row entirely rather than repeating a name a colliding row already shows. It is emphatically NOT a circle the two colliding people share with each other (such a circle could not tell them apart); never translate it as a shared, common or mutual circle. Translate as a label-and-value construction, exactly like memberPickerMatchesAnnouncement: the circle noun in its plain citation form, a colon, then the name. NEVER render it as a prepositional or locative phrase — on real circle names 'In {circleName}' collides with ordinary locative idiom ('In Family', 'In Brooklyn', and the per-locale equivalents of the very names nameCircleNameHint itself suggests), which in a location-sharing app announces a place the person is not. The label-value shape also avoids case government and possessive re-readings, and it needs no quotation marks, which screen readers do not speak at default verbosity. This is the ONE exception to the rule that Haven never names a circle on this screen (plan §7.2); do not reuse this copy, or invent similar copy, anywhere else the picker shows a person. {circleName} is a name the user (or someone in the circle) chose locally.
  ///
  /// In en, this message translates to:
  /// **'Circle: {circleName}'**
  String memberPickerCollisionCircleLabel(String circleName);

  /// Shown on the ONE row that appears when the user types or pastes a complete, valid npub for someone not already in the local directory (plan §10 D2), and spoken as the screen-reader label on that row's loading spinner while the lookup is in flight. Appears whether or not anything resolves. Discloses exactly four things and no more: (1) Haven asked ONE public relay (never more — see docs/MEMBER_PICKER_PLAN.md, the design deliberately adds no fan-out of its own — it never pads with decoys, and it issues one request per attempt through the existing per-author relay assignment, whose own ladder is bounded by PROFILE_MAX_RELAY_RANK); (2) that relay can see THIS DEVICE asked about THAT KEY at THAT MOMENT — do not soften this into 'may be able to see' or omit it, it is a real, unavoidable disclosure; (3) the request is NOT tied to the user's Haven identity, because it carries no cryptographic signature and therefore cannot answer a relay's NIP-42 AUTH challenge — translate 'signature' in the cryptographic sense, not a handwritten or email signature; (4) no photo is downloaded at this stage (only the published name, if any, is looked up). Do NOT use a word meaning 'anonymous' or 'anonymously' anywhere in this string — it overclaims: the network address and timing of the request are still visible to the relay, which is exactly what point (2) discloses. Do not add or imply a duration, a retry count, or which relay was asked.
  ///
  /// In en, this message translates to:
  /// **'Haven asked a relay to look up this person\'s published name. That relay can see this device asked about this key just now — but the request carries no signature, so it isn\'t tied to your Haven identity. No photo is downloaded yet.'**
  String get memberPickerStrangerLookupNote;

  /// Indicator shown after the visible member chips for the remaining members, e.g. '+2 more'.
  ///
  /// In en, this message translates to:
  /// **'+{count} more'**
  String selectedMembersMore(int count);

  /// Heading of a pending circle invitation card, and the largest text on it. Deliberately NOT the circle's name: pre-join the name is still inside the encrypted Welcome, so the card can only say what the item IS. Must not name, number or otherwise imply a specific circle.
  ///
  /// In en, this message translates to:
  /// **'Circle invitation'**
  String get invitationCardHeading;

  /// Accessibility label summarizing an invitation card. {inviter} is the inviter's local nickname if the user saved one, else their resolved public name, else their shortened npub. 'a circle' is indefinite on purpose — see invitationCardHeading; do not reintroduce a circle name or a member count, neither of which Haven knows before the invitation is accepted. 'sent by', NOT 'invited by': the participle in 'invited by' agrees with the READER, whose gender Haven never asks for — five translators independently hit this and each replaced it with a send-verb attached to the invitation. Keep {inviter} LAST: it usually resolves to a ~21-character npub, and a screen-reader listener needs the gist before the key.
  ///
  /// In en, this message translates to:
  /// **'Invitation to join a circle, sent by {inviter}'**
  String invitationCardSemantics(String inviter);

  /// Accessibility label for the inviter row of an invitation card. {inviter} is the inviter's shortened npub.
  ///
  /// In en, this message translates to:
  /// **'Invited by cryptographic identifier {inviter}'**
  String invitationCardInvitedBySemantics(String inviter);

  /// Visible inviter line on an invitation card. {inviter} is the nickname the user saved for the inviter when there is one, else the inviter's resolved public name, else their shortened npub; the npub is then shown on its own line beneath.
  ///
  /// In en, this message translates to:
  /// **'Invited by: {inviter}'**
  String invitationCardInvitedBy(String inviter);

  /// Tooltip and screen-reader label on the small mark beside the inviter line when the name shown is the nickname the user saved on this device rather than the inviter's public Nostr name. States where the name came from and nothing more: it is NOT a verification, trust, safety or identity-confirmation claim, and must not be translated as one.
  ///
  /// In en, this message translates to:
  /// **'Your nickname for them, not their public name'**
  String get invitationCardNicknameNote;

  /// Relative time shown on an invitation card when it arrived moments ago.
  ///
  /// In en, this message translates to:
  /// **'Just now'**
  String get invitationCardJustNow;

  /// Relative time shown on an invitation card, in days. The 'd' abbreviation is compact and intentionally English.
  ///
  /// In en, this message translates to:
  /// **'{count}d ago'**
  String invitationCardDaysAgo(int count);

  /// Relative time shown on an invitation card, in hours. The 'h' abbreviation is compact and intentionally English.
  ///
  /// In en, this message translates to:
  /// **'{count}h ago'**
  String invitationCardHoursAgo(int count);

  /// Relative time shown on an invitation card, in minutes. The 'm' abbreviation is compact and intentionally English.
  ///
  /// In en, this message translates to:
  /// **'{count}m ago'**
  String invitationCardMinutesAgo(int count);

  /// Button that declines a circle invitation.
  ///
  /// In en, this message translates to:
  /// **'Decline'**
  String get invitationCardDecline;

  /// Button that accepts a circle invitation.
  ///
  /// In en, this message translates to:
  /// **'Accept'**
  String get invitationCardAccept;

  /// Snackbar confirming a circle invitation was accepted.
  ///
  /// In en, this message translates to:
  /// **'Invitation accepted'**
  String get invitationAcceptedSnack;

  /// Snackbar confirming a circle invitation was declined.
  ///
  /// In en, this message translates to:
  /// **'Invitation declined'**
  String get invitationDeclinedSnack;

  /// Error snackbar shown when accepting an invitation fails.
  ///
  /// In en, this message translates to:
  /// **'Failed to accept invitation. Please try again.'**
  String get invitationAcceptError;

  /// Error snackbar shown when the user already belongs to the maximum number of circles ({limit}, kMaxCirclesPerAccount) so the invitation was NOT accepted. Must state the limit AND the remedy — leaving a circle — and must keep the reassurance that the invitation is still waiting; do not translate this as a transient failure or add 'try again'. Mark the ceiling EXPLICITLY in your language ('up to', 'at most', 'only', a restrictive construction, a bounding particle — whatever your language uses): a bare positive ('you can be in 10 circles') reads as capability or permission rather than as a limit in most of the languages this app ships, and under a possessive framing it is also ambiguous between 'exactly 10' and 'up to 10'. Eleven of the twelve locales independently had to add a limiter to the previous, unmarked English wording, which is why the English marks it now too. {limit} is the maximum, currently 10.
  ///
  /// In en, this message translates to:
  /// **'You can be in up to {limit} circles at a time. Leave a circle, then accept this invitation.'**
  String invitationRosterFullError(int limit);

  /// Error snackbar shown when declining an invitation fails.
  ///
  /// In en, this message translates to:
  /// **'Failed to decline invitation. Please try again.'**
  String get invitationDeclineError;

  /// Accessibility label for the expandable circle-selector control.
  ///
  /// In en, this message translates to:
  /// **'Circle selector'**
  String get circleSelectorLabel;

  /// Placeholder shown in the circle selector when no circle is selected.
  ///
  /// In en, this message translates to:
  /// **'Select a circle'**
  String get circleSelectorPlaceholder;

  /// Action at the bottom of the circle-selector dropdown that starts creating a new circle.
  ///
  /// In en, this message translates to:
  /// **'New Circle'**
  String get circleSelectorNewCircle;

  /// Error shown in the circle selector when the circle list fails to load.
  ///
  /// In en, this message translates to:
  /// **'Failed to load circles'**
  String get circleSelectorLoadError;

  /// Accessibility announcement when the circle-selector dropdown opens.
  ///
  /// In en, this message translates to:
  /// **'Circle list expanded'**
  String get circleSelectorExpandedAnnouncement;

  /// Accessibility announcement when the circle-selector dropdown closes.
  ///
  /// In en, this message translates to:
  /// **'Circle list collapsed'**
  String get circleSelectorCollapsedAnnouncement;

  /// Tooltip on the info button that opens the circle-details sheet.
  ///
  /// In en, this message translates to:
  /// **'Circle details'**
  String get circleDetailsButtonTooltip;

  /// Title of the circle-details bottom sheet.
  ///
  /// In en, this message translates to:
  /// **'Circle details'**
  String get circleDetailsTitle;

  /// Subtitle of the circle-details sheet, combining the member count with the circle's current encryption epoch, e.g. '3 members · epoch 14'. Deliberately understated: most users never need it, but members comparing two devices use it to tell whether their circles are in sync. 'epoch' is the cryptographic protocol term for the period between two key changes — use the established technical term in your language rather than a literal word for 'era', and keep it lowercase if your language allows. The separator can be changed to whatever punctuation reads naturally.
  ///
  /// In en, this message translates to:
  /// **'{members} · epoch {epoch}'**
  String circleDetailsMembersWithEpoch(String members, int epoch);

  /// Appends the relay-expiry window to the circle-details subtitle, e.g. '3 members · epoch 14 · expiry 4 min'. {meta} is the already-composed member count (with the epoch, when there is one) and must be inserted untouched; {expiry} is the compact duration (circleDetailsExpiryMinutesShort / circleDetailsExpirySecondsShort). Space is the whole point of this segment: for almost every circle it reads '4 min' forever, so it must stay a couple of words on the dimmest line, never a row or a label of its own. 'expiry' is the relay-expiry window of the location message. Do NOT translate it as a promise that messages are deleted, and do NOT make it read as though the CIRCLE expires; what expires is the location message. Reorder freely (a language that wants the duration first can write '{expiry} ... {meta}') and change the separator to whatever punctuation reads naturally, but keep it short enough to sit on one dim line.
  ///
  /// In en, this message translates to:
  /// **'{meta} · expiry {expiry}'**
  String circleDetailsMetaWithExpiry(String meta, String expiry);

  /// Compact minutes duration for the circle-details expiry segment, e.g. '4 min'. Glanceable abbreviation, not prose: it shares one dim line with the member count and the epoch, so keep it to a number plus a short unit and never spell 'minutes' out here (circleDetailsExpiryMinutesLong is the spoken form). The plural branches exist because some languages inflect even the abbreviation; if yours does not, both branches are legitimately identical.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{{count} min} other{{count} min}}'**
  String circleDetailsExpiryMinutesShort(int count);

  /// Compact seconds duration for the circle-details expiry segment, e.g. '30 sec'. Only ever shown for a circle created by another Marmot client that declared a window under a minute — the case where relays drop this phone's location almost immediately — so it must read as alarmingly short next to the usual '4 min', not be rounded away. Same length constraint as circleDetailsExpiryMinutesShort.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{{count} sec} other{{count} sec}}'**
  String circleDetailsExpirySecondsShort(int count);

  /// Spelled-out minutes duration read by screen readers inside circleDetailsExpirySemantics, e.g. 'about 4 minutes'. Never displayed. 'about' is required and must survive translation: the number is rounded to the nearest minute (Haven's own window is 228 seconds, which is what makes the usual reading 'about 4 minutes'). Spell the unit out in full — an abbreviation is what this key exists to avoid. These are consumed at exactly ONE call site, inside circleDetailsExpirySemantics, so a language whose carrier sentence governs the duration may fold the preposition or case into this string rather than leave it stranded (ru does: it carries 'через' and the accusative, and its semantics string has no preposition). Do not 'restore' the English shape there.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{about {count} minute} other{about {count} minutes}}'**
  String circleDetailsExpiryMinutesLong(int count);

  /// Spelled-out seconds duration read by screen readers inside circleDetailsExpirySemantics, e.g. '30 seconds'. Never displayed. Deliberately has no 'about' — unlike the minutes form this number is exact, and hedging an exact figure would be less accurate, not more. Spell the unit out in full. These are consumed at exactly ONE call site, inside circleDetailsExpirySemantics, so a language whose carrier sentence governs the duration may fold the preposition or case into this string rather than leave it stranded (ru does: it carries 'через' and the accusative, and its semantics string has no preposition). Do not 'restore' the English shape there.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{{count} second} other{{count} seconds}}'**
  String circleDetailsExpirySecondsLong(int count);

  /// The whole circle-details subtitle as a screen reader hears it, replacing the terse visible line. {meta} is the visible member count (with the epoch, when there is one), read as-is; {expiry} is the spelled-out duration (circleDetailsExpiryMinutesLong / circleDetailsExpirySecondsLong). Two things are load-bearing and must survive translation. First, 'asks relays to drop' — the expiry is an advisory NIP-40 hint a relay may ignore, so never phrase it as a guarantee that anything is deleted. Second, 'the location updates you send' — this window governs THIS phone's own messages; Haven cannot state what another member's client stamps, so never generalise it to 'this circle's messages' or 'everyone's location'. Third, the duration must unambiguously modify the DROPPING, not the sending. English fences it in preverbal position with commas because a trailing 'after about 4 minutes' otherwise attaches to 'you send' by Late Closure, and a listener gets one pass to recover from that. Do NOT clone the comma fence: independent per-language review found the same ambiguity real in es/fr/pt/ru/ar and structurally impossible in de/tr/hi/ur/ja/ne, where a prenominal relative clause or a comma-closed one already forecloses it — there, mirroring English word order REINTRODUCES the defect. Make the attachment unambiguous by whatever device the language actually uses. Keep it one spoken sentence after {meta}.
  ///
  /// In en, this message translates to:
  /// **'{meta}. Haven asks relays to drop, after {expiry}, the location updates you send to this circle.'**
  String circleDetailsExpirySemantics(String meta, String expiry);

  /// Heading above the list of relays in the circle-details sheet.
  ///
  /// In en, this message translates to:
  /// **'Relays for this circle'**
  String get circleDetailsRelaysHeading;

  /// Placeholder shown in the circle-details sheet when the circle has no recorded relays.
  ///
  /// In en, this message translates to:
  /// **'(none recorded)'**
  String get circleDetailsNoRelays;

  /// Explanatory note under the relay list in the circle-details sheet. Factually load-bearing and previously wrong: a circle's relay set is the union of the INVITEES' published inbox relays (nostr_circle_service.dart builds it from the fetched key packages), not a copy of the creator's own list. Both fallbacks must stay in the copy — the creator's stored inbox relays first, then Haven's built-in defaults — because in the empty-inbox case the circle's location traffic travels over relays the user never chose, and naming only the first fallback implies they always did. Do not restore the old 'copied from your inbox relays' framing — it told the user their own relay choices govern where that traffic goes, which is false in the normal case. LENGTH IS A CORRECTNESS CONSTRAINT HERE, not a style preference: this renders in the circle-details bottom sheet, which is content-sized, and once the body scrolls the sheet's drag-to-dismiss gesture scrolls instead of dismissing. A longer draft of this string broke both `circle_details_layout_test.dart` cases at normal text scale. Keep every fact and keep it tight; note that the locale sweep in that file only asserts no overflow at 1.5x, and scrolling raises no overflow, so a too-long TRANSLATION will not be caught by any test.
  ///
  /// In en, this message translates to:
  /// **'These relays came from the lists the invited members published — or, if they had none, from your inbox relays or ones Haven chose. They cannot be changed yet, and later edits to your relay list do not affect them.'**
  String get circleDetailsRelaysNote;

  /// Button in the circle-details sheet that opens the add-member page.
  ///
  /// In en, this message translates to:
  /// **'Add member'**
  String get circleDetailsAddMember;

  /// Button in the circle-details sheet that starts leaving the circle.
  ///
  /// In en, this message translates to:
  /// **'Leave Circle'**
  String get circleDetailsLeaveCircle;

  /// Title of the confirmation dialog shown before leaving a circle.
  ///
  /// In en, this message translates to:
  /// **'Leave Circle'**
  String get leaveCircleDialogTitle;

  /// Body of the confirmation dialog shown before leaving a circle.
  ///
  /// In en, this message translates to:
  /// **'Leave this circle? You will stop sending your location to its members and stop seeing theirs. The last position you sent stays on their phones for up to a day. You cannot undo this: you would need a new invitation to rejoin.'**
  String get leaveCircleDialogBody;

  /// Confirm button in the leave-circle dialog.
  ///
  /// In en, this message translates to:
  /// **'Leave'**
  String get leaveCircleConfirm;

  /// Internal error message used when the user's identity is unavailable while leaving a circle.
  ///
  /// In en, this message translates to:
  /// **'Identity unavailable'**
  String get leaveCircleIdentityUnavailable;

  /// Snackbar confirming the user left the circle.
  ///
  /// In en, this message translates to:
  /// **'Left circle successfully'**
  String get leaveCircleSuccess;

  /// Error snackbar shown when leaving a circle fails.
  ///
  /// In en, this message translates to:
  /// **'Failed to leave circle'**
  String get leaveCircleError;

  /// Title of the banner shown above a circle's member list when the encryption engine has flagged the circle as unrecoverable (Dark Matter migration, Security Rule 8). Never shows a raw internal error.
  ///
  /// In en, this message translates to:
  /// **'This circle can’t be updated'**
  String get circleBlockedBannerTitle;

  /// Body text of the blocked-circle banner. Kept generic and non-technical, per the app's no-raw-errors-in-UI rule.
  ///
  /// In en, this message translates to:
  /// **'Something went wrong with this circle’s encryption, so Haven can no longer send or receive updates in it. You can still see what you last knew below, or leave the circle.'**
  String get circleBlockedBannerBody;

  /// Title of the banner shown in place of the member list for a circle left over from before the app's encryption engine was upgraded (Dark Matter migration).
  ///
  /// In en, this message translates to:
  /// **'This circle needs to be re-created'**
  String get legacyCircleBannerTitle;

  /// Body text of the legacy-circle banner, explaining why the circle must be re-created.
  ///
  /// In en, this message translates to:
  /// **'Haven’s encryption engine was upgraded, so this circle can no longer be used. Re-create it to keep sharing locations with the same people. You’ll need to invite them again.'**
  String get legacyCircleBannerBody;

  /// Button that starts creating a new circle, pre-filled with the old circle's name. Shown on the legacy-circle banner and on the blocked-circle banner — both are circles that can only be recovered by re-creating them.
  ///
  /// In en, this message translates to:
  /// **'Re-create Circle'**
  String get legacyCircleRecreateCta;

  /// Button on the legacy-circle banner that removes the stale local circle entry.
  ///
  /// In en, this message translates to:
  /// **'Remove'**
  String get legacyCircleRemoveCta;

  /// Title of the confirmation dialog shown before removing a legacy (pre-upgrade) circle.
  ///
  /// In en, this message translates to:
  /// **'Remove circle?'**
  String get legacyCircleRemoveDialogTitle;

  /// Body of the confirmation dialog shown before removing a legacy (pre-upgrade) circle.
  ///
  /// In en, this message translates to:
  /// **'This circle can no longer be used and will be removed from your list. This does not affect any new circle you create to replace it.'**
  String get legacyCircleRemoveDialogBody;

  /// Confirm button in the remove-legacy-circle dialog.
  ///
  /// In en, this message translates to:
  /// **'Remove'**
  String get legacyCircleRemoveConfirm;

  /// Title of the one-time dialog shown after Haven's encryption engine upgrade (Dark Matter migration) destroys the old, no-longer-usable circle data.
  ///
  /// In en, this message translates to:
  /// **'Haven has been updated'**
  String get legacyCutoverExplainerTitle;

  /// First paragraph of the one-time cutover explainer: reassures the user their Nostr identity/profile survived the upgrade.
  ///
  /// In en, this message translates to:
  /// **'Your identity and public profile are unchanged. There is nothing you need to do for those.'**
  String get legacyCutoverExplainerIdentityUnchanged;

  /// Second paragraph of the one-time cutover explainer: explains that existing circles must be re-created.
  ///
  /// In en, this message translates to:
  /// **'For improved security, your circles need to be re-created and their members re-invited before you can share locations in them again.'**
  String get legacyCutoverExplainerCirclesNeedRecreation;

  /// Acknowledgement button that dismisses the one-time cutover explainer dialog.
  ///
  /// In en, this message translates to:
  /// **'Got it'**
  String get legacyCutoverExplainerAcknowledge;

  /// Subtle, non-blocking note on the Relay Settings page shown only while the one-time post-upgrade cleanup of old encryption-key advertisements has not yet completed (most commonly because no relay was reachable yet).
  ///
  /// In en, this message translates to:
  /// **'Haven is still asking relays to drop some old data from the recent security update.'**
  String get relaySettingsLegacyRetractionPending;

  /// Accessibility announcement when the circles bottom sheet snaps to its collapsed position.
  ///
  /// In en, this message translates to:
  /// **'Circles panel collapsed'**
  String get circlesPanelCollapsedAnnouncement;

  /// Accessibility announcement when the circles bottom sheet snaps to its fully expanded position.
  ///
  /// In en, this message translates to:
  /// **'Circles panel expanded'**
  String get circlesPanelExpandedAnnouncement;

  /// Accessibility announcement when the circles bottom sheet snaps to its low 'peek' position.
  ///
  /// In en, this message translates to:
  /// **'Circles panel slightly open'**
  String get circlesPanelSlightlyOpenAnnouncement;

  /// Accessibility announcement when the circles bottom sheet snaps to its half-open position.
  ///
  /// In en, this message translates to:
  /// **'Circles panel half open'**
  String get circlesPanelHalfOpenAnnouncement;

  /// Fallback name spoken in the map-recenter accessibility announcement when the tapped member is the current user and has no display name.
  ///
  /// In en, this message translates to:
  /// **'you'**
  String get circleMemberAnnouncementSelf;

  /// Fallback name spoken in the map-recenter accessibility announcement when a tapped member has no display name.
  ///
  /// In en, this message translates to:
  /// **'member'**
  String get circleMemberAnnouncementFallback;

  /// Tooltip on the app-bar button that re-checks the inbox relays for new invitations.
  ///
  /// In en, this message translates to:
  /// **'Refresh invitations'**
  String get invitationsRefreshTooltip;

  /// Message shown on the Invitations page when the pending-invitations list fails to load.
  ///
  /// In en, this message translates to:
  /// **'Could not load invitations'**
  String get invitationsLoadError;

  /// Title of the empty state on the Invitations page when there are no pending invitations.
  ///
  /// In en, this message translates to:
  /// **'No Invitations'**
  String get invitationsEmptyTitle;

  /// Message of the empty state on the Invitations page when there are no pending invitations.
  ///
  /// In en, this message translates to:
  /// **'When someone invites you to a circle, it will appear here.'**
  String get invitationsEmptyMessage;

  /// Accessibility label on the app-bar refresh ring when no inbox relay is configured. Tapping opens the relay settings page, so the label states that destination.
  ///
  /// In en, this message translates to:
  /// **'No inbox configured, opens relay settings'**
  String get refreshRingSemanticNoInbox;

  /// Accessibility label on the refresh ring while relays are being checked, e.g. '2 of 3 relays checked'. Read on focus; not announced live.
  ///
  /// In en, this message translates to:
  /// **'{total, plural, =1{{checked} of 1 relay checked} other{{checked} of {total} relays checked}}'**
  String refreshRingSemanticChecking(int checked, int total);

  /// Accessibility label on the refresh ring when every relay responded successfully.
  ///
  /// In en, this message translates to:
  /// **'{total, plural, =1{The relay responded} other{All {total} relays responded}}'**
  String refreshRingSemanticAllOk(int total);

  /// Accessibility label on the refresh ring when no relay could be reached. The count is omitted because zero responded makes a number redundant.
  ///
  /// In en, this message translates to:
  /// **'No relays responded'**
  String get refreshRingSemanticAllError;

  /// Accessibility label on the refresh ring when only some relays responded, e.g. '2 of 3 relays responded'. A partial result always has at least two relays, so no singular form is needed.
  ///
  /// In en, this message translates to:
  /// **'{ok} of {total} relays responded'**
  String refreshRingSemanticPartial(int ok, int total);

  /// Screen-reader announcement when a relay refresh starts (sent via SemanticsService, not a live region).
  ///
  /// In en, this message translates to:
  /// **'Checking relays'**
  String get refreshRingAnnouncementChecking;

  /// Screen-reader announcement when every relay responded successfully at the end of a refresh.
  ///
  /// In en, this message translates to:
  /// **'All relays responded'**
  String get refreshRingAnnouncementAllOk;

  /// Screen-reader announcement when only some relays responded at the end of a refresh, e.g. '2 of 3 relays responded'. A partial result always has at least two relays, so no singular form is needed.
  ///
  /// In en, this message translates to:
  /// **'{ok} of {total} relays responded'**
  String refreshRingAnnouncementPartial(int ok, int total);

  /// Screen-reader announcement when no relay could be reached at the end of a refresh.
  ///
  /// In en, this message translates to:
  /// **'No relays could be reached'**
  String get refreshRingAnnouncementAllError;

  /// Screen-reader announcement when the user taps the refresh ring with no inbox relay configured, which routes to relay settings.
  ///
  /// In en, this message translates to:
  /// **'No inbox configured'**
  String get refreshRingAnnouncementNoInbox;

  /// Accessibility label on the Relay Settings refresh ring when every relay holds the user's published data (KeyPackage / relay lists). The 'hasData' vocabulary, distinct from the Invitations 'responded' wording, because on this page a relay can answer yet still be missing the data.
  ///
  /// In en, this message translates to:
  /// **'{total, plural, =1{The relay has your data} other{All {total} relays have your data}}'**
  String refreshRingSemanticAllFound(int total);

  /// Accessibility label on the Relay Settings refresh ring when no relay holds the user's data (missing everywhere, or unreachable).
  ///
  /// In en, this message translates to:
  /// **'No relays have your data'**
  String get refreshRingSemanticNoneFound;

  /// Accessibility label on the Relay Settings refresh ring when only some relays hold the user's data, e.g. '2 of 3 relays have your data'. A partial result always has at least two relays, so no singular form is needed.
  ///
  /// In en, this message translates to:
  /// **'{ok} of {total} relays have your data'**
  String refreshRingSemanticPartialFound(int ok, int total);

  /// Screen-reader announcement when every relay holds the user's data at the end of a Relay Settings check.
  ///
  /// In en, this message translates to:
  /// **'All relays have your data'**
  String get refreshRingAnnouncementAllFound;

  /// Screen-reader announcement when only some relays hold the user's data at the end of a Relay Settings check, e.g. '2 of 3 relays have your data'. A partial result always has at least two relays, so no singular form is needed.
  ///
  /// In en, this message translates to:
  /// **'{ok} of {total} relays have your data'**
  String refreshRingAnnouncementPartialFound(int ok, int total);

  /// Screen-reader announcement when no relay holds the user's data at the end of a Relay Settings check.
  ///
  /// In en, this message translates to:
  /// **'No relays have your data'**
  String get refreshRingAnnouncementNoneFound;

  /// Title of the Identity management page (AppBar).
  ///
  /// In en, this message translates to:
  /// **'Identity'**
  String get identityTitle;

  /// Error card shown on the Identity page when the identity provider fails to load.
  ///
  /// In en, this message translates to:
  /// **'Something went wrong loading your identity. Please try again.'**
  String get identityLoadError;

  /// Title of the recovery card shown on the Identity page when no identity exists.
  ///
  /// In en, this message translates to:
  /// **'No Identity'**
  String get identityMissingTitle;

  /// Body of the recovery card shown on the Identity page when no identity exists. 'Haven' is intentionally English (brand name).
  ///
  /// In en, this message translates to:
  /// **'Your identity is gone. Set up a new one to keep using Haven.'**
  String get identityMissingMessage;

  /// Button on the Identity recovery card that restarts onboarding to create a new identity.
  ///
  /// In en, this message translates to:
  /// **'Set Up Identity'**
  String get identitySetUpCta;

  /// Title of the Public Key QR subpage tile on the Identity page (and the QR page AppBar).
  ///
  /// In en, this message translates to:
  /// **'Public Key QR'**
  String get identityPublicKeyQrTitle;

  /// Subtitle of the Public Key QR subpage tile on the Identity page.
  ///
  /// In en, this message translates to:
  /// **'How others invite you to circles'**
  String get identityPublicKeyQrSubtitle;

  /// Title of the Advanced subpage tile on the Identity page (and the Advanced page AppBar).
  ///
  /// In en, this message translates to:
  /// **'Advanced'**
  String get identityAdvancedTitle;

  /// Subtitle of the Advanced subpage tile on the Identity page.
  ///
  /// In en, this message translates to:
  /// **'Public key, secret key, delete'**
  String get identityAdvancedSubtitle;

  /// Title of the combined, always-visible informational notice disclosing that the user's public profile (display name + photo) is public on the Nostr network. Shown in exactly two places (same widget, PublicProfileNotice): onboarding's display-name screen and the Identity settings page. Publishing is unconditional (public-by-default) — there is no opt-in toggle, so this is a neutral disclosure, not a consent prompt.
  ///
  /// In en, this message translates to:
  /// **'Profile is public'**
  String get profileIsPublicNoticeTitle;

  /// Body of the combined public-profile disclosure notice (see profileIsPublicNoticeTitle). Must not imply an opt-in/toggle exists — publishing a saved name/photo is unconditional.
  ///
  /// In en, this message translates to:
  /// **'Your display name and photo are visible to anyone on the Nostr network, not just members of your circles. Share only what you\'re comfortable making public.'**
  String get profileIsPublicNoticeBody;

  /// Tooltip on the Identity-page AppBar refresh action that forces a network re-fetch of the user's own public profile.
  ///
  /// In en, this message translates to:
  /// **'Refresh public profile'**
  String get identityRefreshProfileTooltip;

  /// Snackbar shown on the Advanced identity page when exporting the secret key fails. 'secret key' is the nsec; do not soften this wording.
  ///
  /// In en, this message translates to:
  /// **'Failed to export secret key. Please try again.'**
  String get identityAdvancedExportError;

  /// Title of the confirmation dialog before permanently deleting the identity.
  ///
  /// In en, this message translates to:
  /// **'Delete Identity?'**
  String get identityAdvancedDeleteTitle;

  /// Body of the delete-identity confirmation dialog. 'secret key' is the nsec; preserve this exact warning wording. The middle sentence was corrected: the profile photo is not on a relay at all — it is a blob on a Blossom image host (haven-core/src/profile/blossom.rs) for which no delete request exists, so naming relays as the only destination mis-stated where the photo survives. Keep the two destinations distinct in translation.
  ///
  /// In en, this message translates to:
  /// **'This deletes your identity and all circle data from this phone. Anything already published under it stays where it is: your name and keys on the relays that have them, your photo on the image host that stores it. Make sure you have backed up your secret key if you want to recover this identity later.'**
  String get identityAdvancedDeleteBody;

  /// Confirm button in the delete-identity dialog.
  ///
  /// In en, this message translates to:
  /// **'Delete'**
  String get identityAdvancedDeleteConfirm;

  /// Snackbar confirming the identity was deleted.
  ///
  /// In en, this message translates to:
  /// **'Identity deleted'**
  String get identityAdvancedDeletedSnack;

  /// Snackbar shown when deleting the identity fails.
  ///
  /// In en, this message translates to:
  /// **'Failed to delete identity. Please try again.'**
  String get identityAdvancedDeleteError;

  /// Snackbar confirming an arbitrary labelled value (e.g. 'Public key') was copied to the clipboard.
  ///
  /// In en, this message translates to:
  /// **'{label} copied to clipboard'**
  String identityAdvancedCopiedToClipboard(String label);

  /// Security warning snackbar shown after copying the secret key (nsec) to the clipboard. Preserve this exact wording; do not soften it.
  ///
  /// In en, this message translates to:
  /// **'Secret key copied. Warning: other apps may read your clipboard. Paste it somewhere safe and clear your clipboard.'**
  String get identityAdvancedSecretCopiedWarning;

  /// Body shown on the Advanced identity page (and QR page) when no identity exists.
  ///
  /// In en, this message translates to:
  /// **'No identity is set up.'**
  String get identityAdvancedMissingBody;

  /// Field label above the npub public-key value on the Advanced identity page.
  ///
  /// In en, this message translates to:
  /// **'Public Key'**
  String get identityAdvancedPublicKeyLabel;

  /// Field label above the hex public-key value on the Advanced identity page. 'hex' is intentionally English (technical term).
  ///
  /// In en, this message translates to:
  /// **'Public Key (hex)'**
  String get identityAdvancedPublicKeyHexLabel;

  /// Label interpolated into the copy-confirmation snackbar when the public key (npub or hex) is copied.
  ///
  /// In en, this message translates to:
  /// **'Public key'**
  String get identityAdvancedCopyValue;

  /// Tooltip on the button that copies the npub public key on the Advanced identity page.
  ///
  /// In en, this message translates to:
  /// **'Copy public key'**
  String get identityAdvancedCopyPublicKeyTooltip;

  /// Tooltip on the button that copies the hex public key on the Advanced identity page. 'hex' is intentionally English (technical term).
  ///
  /// In en, this message translates to:
  /// **'Copy hex'**
  String get identityAdvancedCopyHexTooltip;

  /// Section title of the secret-key (nsec) card on the Advanced identity page. Preserve this exact wording.
  ///
  /// In en, this message translates to:
  /// **'Secret Key'**
  String get identityAdvancedSecretKeyTitle;

  /// Warning text in the secret-key (nsec) card. Preserve this exact wording; do not soften it.
  ///
  /// In en, this message translates to:
  /// **'Your secret key gives full access to your identity. Never share it with anyone.'**
  String get identityAdvancedSecretKeyWarning;

  /// Button that reveals (exports) the secret key (nsec) on the Advanced identity page. Preserve this exact wording.
  ///
  /// In en, this message translates to:
  /// **'Reveal Secret Key'**
  String get identityAdvancedRevealSecretKey;

  /// Button that hides the revealed secret key (nsec) on the Advanced identity page. Preserve this exact wording.
  ///
  /// In en, this message translates to:
  /// **'Hide Secret Key'**
  String get identityAdvancedHideSecretKey;

  /// Tooltip on the button that copies the revealed secret key (nsec). Preserve this exact wording.
  ///
  /// In en, this message translates to:
  /// **'Copy secret key'**
  String get identityAdvancedCopySecretKeyTooltip;

  /// Destructive button at the bottom of the Advanced identity page that starts identity deletion.
  ///
  /// In en, this message translates to:
  /// **'Delete Identity'**
  String get identityAdvancedDeleteIdentityCta;

  /// Message shown on the Public Key QR page when the identity provider fails to load.
  ///
  /// In en, this message translates to:
  /// **'Something went wrong loading your public key. Please try again.'**
  String get qrCodeLoadError;

  /// Field label above the selectable npub on the Public Key QR page.
  ///
  /// In en, this message translates to:
  /// **'Your public key'**
  String get qrCodeYourPublicKeyLabel;

  /// Heading of the plain-language explainer on the Public Key QR page.
  ///
  /// In en, this message translates to:
  /// **'What is this?'**
  String get qrCodeWhatIsThisTitle;

  /// First explainer paragraph on the Public Key QR page. 'Haven' and 'Nostr' are intentionally English (brand/protocol names).
  ///
  /// In en, this message translates to:
  /// **'Haven runs on Nostr, an open network with no company account or sign-up behind it. Your identity is just a pair of keys: a secret key only you hold, and this public key made from it.'**
  String get qrCodeExplainerKeys;

  /// Second explainer paragraph on the Public Key QR page.
  ///
  /// In en, this message translates to:
  /// **'Your public key works like a username that is safe to share. People scan this code, or paste your public key, to invite you to a circle. Sharing it cannot reveal where you are. Your display name and photo are already public, so this adds nothing.'**
  String get qrCodeExplainerUsername;

  /// Section title of the display-name card on the Identity page. Reused as the display-name TextField's InputDecoration.labelText so the field's purpose is still announced by screen readers once text has been entered and the hint is no longer visible.
  ///
  /// In en, this message translates to:
  /// **'Display Name'**
  String get displayNameCardTitle;

  /// Error text shown in the display-name card when the display name fails to load.
  ///
  /// In en, this message translates to:
  /// **'Could not load your display name. Try again later.'**
  String get displayNameCardLoadError;

  /// Hint inside the display-name text field.
  ///
  /// In en, this message translates to:
  /// **'Enter your display name'**
  String get displayNameCardHint;

  /// Accessible label/tooltip on the circular save button when the display name matches the saved value.
  ///
  /// In en, this message translates to:
  /// **'Display name saved'**
  String get displayNameCardSavedLabel;

  /// Accessible label/tooltip on the circular save button when there are unsaved edits.
  ///
  /// In en, this message translates to:
  /// **'Save display name'**
  String get displayNameCardSaveLabel;

  /// Accessible label/tooltip on the circular save button while a save is in flight; also announced to screen readers when saving begins.
  ///
  /// In en, this message translates to:
  /// **'Saving display name'**
  String get displayNameCardSavingLabel;

  /// Accessible label/tooltip on the circular save button after a save failed.
  ///
  /// In en, this message translates to:
  /// **'Save failed. Retry'**
  String get displayNameCardRetryLabel;

  /// Screen-reader announcement when the display name is saved successfully.
  ///
  /// In en, this message translates to:
  /// **'Display name saved'**
  String get displayNameCardSavedAnnouncement;

  /// Assertive screen-reader announcement when saving the display name fails.
  ///
  /// In en, this message translates to:
  /// **'Save failed, try again'**
  String get displayNameCardSaveFailedAnnouncement;

  /// Own-profile sync status line: a publish of the local name/photo edit is currently in flight to the relay pool.
  ///
  /// In en, this message translates to:
  /// **'Syncing to your public profile…'**
  String get profileSyncStatusSyncing;

  /// Own-profile sync status line: at least one relay acknowledged the publish, but not the whole pool yet (or a newer edit is queued); a persisted backoff will retry automatically.
  ///
  /// In en, this message translates to:
  /// **'Published — still syncing to some relays'**
  String get profileSyncStatusPartial;

  /// Own-profile sync status line: every relay in the pool has acknowledged the current name/photo.
  ///
  /// In en, this message translates to:
  /// **'Public profile up to date'**
  String get profileSyncStatusSynced;

  /// Own-profile sync status line: the last publish attempt could not reach any relay; shown beside a Retry action (commonRetry).
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t sync yet.'**
  String get profileSyncStatusFailed;

  /// Accessibility label for the Retry button on the own-profile sync status line, more descriptive than its short visible "Retry" caption (commonRetry).
  ///
  /// In en, this message translates to:
  /// **'Retry publishing your profile'**
  String get profileSyncStatusRetrySemantics;

  /// Snackbar confirming the npub public key was copied to the clipboard from the QR widget.
  ///
  /// In en, this message translates to:
  /// **'Public key copied to clipboard'**
  String get npubQrCopiedSnack;

  /// Button beneath the QR code that copies the npub public key to the clipboard.
  ///
  /// In en, this message translates to:
  /// **'Copy public key'**
  String get npubQrCopyButton;

  /// Snackbar confirming a circle member's public key (npub) was copied to the clipboard after long-pressing their row in the member list.
  ///
  /// In en, this message translates to:
  /// **'Public key copied to clipboard'**
  String get circleMemberPublicKeyCopied;

  /// Accessibility hint spoken by screen readers for the long-press action on a circle member row, which copies that member's public key (npub) to the clipboard.
  ///
  /// In en, this message translates to:
  /// **'Copy public key'**
  String get circleMemberCopyPublicKeyHint;

  /// Action in the member detail bottom sheet that reveals the local-nickname editor for that member (docs/PUBLIC_PROFILE_MIGRATION_PLAN.md §6.3 D6).
  ///
  /// In en, this message translates to:
  /// **'Set Nickname'**
  String get circleMemberSetNicknameMenuItem;

  /// Action in the member detail bottom sheet that copies that member's public key (npub) to the clipboard.
  ///
  /// In en, this message translates to:
  /// **'Copy Public Key'**
  String get circleMemberCopyPublicKeyMenuItem;

  /// Generic error shown when a batched member-profile refresh fails. Never surfaces the raw underlying error (Security Rule 8).
  ///
  /// In en, this message translates to:
  /// **'Could not refresh profiles. Please try again.'**
  String get memberProfileRefreshErrorGeneric;

  /// AppBar/header title of the member detail bottom sheet opened from a circle member row.
  ///
  /// In en, this message translates to:
  /// **'Member Details'**
  String get memberDetailSheetTitle;

  /// Hint text inside the nickname text field in the member detail sheet.
  ///
  /// In en, this message translates to:
  /// **'Enter a nickname'**
  String get memberNicknameSheetHint;

  /// Persistent label (InputDecoration.labelText) of the nickname text field in the member detail sheet, so the field's purpose is still announced by screen readers once text has been entered and the hint is no longer visible.
  ///
  /// In en, this message translates to:
  /// **'Nickname'**
  String get memberNicknameSheetLabel;

  /// Button in the member detail sheet that saves the entered local nickname for a member.
  ///
  /// In en, this message translates to:
  /// **'Save Nickname'**
  String get memberNicknameSheetSave;

  /// Button in the member detail sheet that clears the local nickname override for a member, reverting to the profile-derived name.
  ///
  /// In en, this message translates to:
  /// **'Clear Nickname'**
  String get memberNicknameSheetClear;

  /// Screen-reader announcement when a member's local nickname is saved successfully.
  ///
  /// In en, this message translates to:
  /// **'Nickname saved'**
  String get memberNicknameSheetSavedAnnouncement;

  /// Screen-reader announcement when a member's local nickname override is cleared.
  ///
  /// In en, this message translates to:
  /// **'Nickname cleared'**
  String get memberNicknameSheetClearedAnnouncement;

  /// Label shown beneath the QR code inviting others to scan it to add the user.
  ///
  /// In en, this message translates to:
  /// **'Scan to add me'**
  String get npubQrScanLabel;

  /// Accessibility label for the npub QR code group.
  ///
  /// In en, this message translates to:
  /// **'QR code for your public identity'**
  String get npubQrSemanticsLabel;

  /// Title of the confirmation dialog before removing the profile photo.
  ///
  /// In en, this message translates to:
  /// **'Remove profile photo?'**
  String get photoHeaderRemoveTitle;

  /// Body of the remove-profile-photo confirmation dialog. Updated for the public-profile migration: the photo is now a public Nostr/Blossom profile picture, not something shared privately within circles (docs/PUBLIC_PROFILE_MIGRATION_PLAN.md §6.5).
  ///
  /// In en, this message translates to:
  /// **'This takes your photo off your public profile. The image file stays on the server that hosts it, and copies others already downloaded stay with them.'**
  String get photoHeaderRemoveBody;

  /// Action that opens the photo picker to change the profile photo.
  ///
  /// In en, this message translates to:
  /// **'Edit Photo'**
  String get photoHeaderEditPhoto;

  /// Action (and dialog confirm button) that removes the profile photo.
  ///
  /// In en, this message translates to:
  /// **'Remove'**
  String get photoHeaderRemove;

  /// Accessibility label for the avatar when a photo is set and tapping it opens the full-screen viewer.
  ///
  /// In en, this message translates to:
  /// **'View profile photo'**
  String get photoHeaderViewPhotoSemantics;

  /// Accessibility label for the avatar when no photo is set and tapping it opens the picker.
  ///
  /// In en, this message translates to:
  /// **'Add profile photo'**
  String get photoHeaderAddPhotoSemantics;

  /// Accessibility label for the camera badge that opens the photo picker.
  ///
  /// In en, this message translates to:
  /// **'Change profile photo'**
  String get photoHeaderChangePhotoSemantics;

  /// Snackbar confirming the new profile photo was saved locally. FUTURE TENSE deliberately (profile-latency migration): the photo is saved instantly but the publish to the public Nostr profile (Blossom-hosted) now happens in the background, so past-tense "Published to" would be a claim this snackbar cannot back up. The Identity page's sync status line reports when it actually lands.
  ///
  /// In en, this message translates to:
  /// **'Photo updated. It will be published to your public Nostr profile.'**
  String get avatarPickerPhotoUpdated;

  /// Snackbar confirming the profile photo was removed.
  ///
  /// In en, this message translates to:
  /// **'Photo removed.'**
  String get avatarPickerPhotoRemoved;

  /// Snackbar shown when removing the profile photo fails.
  ///
  /// In en, this message translates to:
  /// **'Could not remove your photo. Please try again.'**
  String get avatarPickerRemoveError;

  /// Generic snackbar shown when picking or setting a new profile photo fails.
  ///
  /// In en, this message translates to:
  /// **'Could not update your photo. Please try again.'**
  String get avatarPickerUpdateError;

  /// Toolbar title of the native square crop/rotate editor for the profile photo.
  ///
  /// In en, this message translates to:
  /// **'Crop photo'**
  String get avatarPickerCropTitle;

  /// iOS done button title in the native crop editor.
  ///
  /// In en, this message translates to:
  /// **'Done'**
  String get avatarPickerCropDone;

  /// iOS cancel button title in the native crop editor.
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get avatarPickerCropCancel;

  /// Tooltip on the close button of the full-screen avatar viewer.
  ///
  /// In en, this message translates to:
  /// **'Close'**
  String get avatarFullscreenClose;

  /// Accessibility label for the full-screen avatar image.
  ///
  /// In en, this message translates to:
  /// **'Profile photo, full screen'**
  String get avatarFullscreenSemantics;

  /// Fallback text shown in the full-screen avatar viewer when the image fails to decode.
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t load photo'**
  String get avatarFullscreenLoadError;

  /// Loading label shown on the map page while the Rust core is being initialized.
  ///
  /// In en, this message translates to:
  /// **'Initializing...'**
  String get mapInitializing;

  /// Title of the error display shown when the map page fails to initialize.
  ///
  /// In en, this message translates to:
  /// **'Initialization Failed'**
  String get mapInitFailedTitle;

  /// Default error message shown on the map page when initialization fails and no specific reason is available.
  ///
  /// In en, this message translates to:
  /// **'Failed to initialize location services.'**
  String get mapInitFailedMessage;

  /// Error message stored when initializing the map page's core fails, prompting the user to retry.
  ///
  /// In en, this message translates to:
  /// **'Initialization failed. Please try again.'**
  String get mapInitFailedRetry;

  /// Empty-state message shown on the map when the user declined the location prominent disclosure.
  ///
  /// In en, this message translates to:
  /// **'Turn on location to see yourself and your circles on the map.'**
  String get mapLocationOffMessage;

  /// Loading-scrim label shown while a GPS fix is being acquired after the user accepted the location disclosure.
  ///
  /// In en, this message translates to:
  /// **'Getting location...'**
  String get mapGettingLocation;

  /// Loading-scrim label shown on the map before the initial location attempt resolves.
  ///
  /// In en, this message translates to:
  /// **'Loading map...'**
  String get mapLoadingMap;

  /// Title of the calm empty state shown when the user declined the location disclosure (an 'off' choice, not an error).
  ///
  /// In en, this message translates to:
  /// **'Location is off'**
  String get mapLocationOffTitle;

  /// Title of the error empty state shown when a GPS or location-service failure occurs.
  ///
  /// In en, this message translates to:
  /// **'Location Error'**
  String get mapLocationErrorTitle;

  /// Error message shown when the current location could not be fetched and can be retried.
  ///
  /// In en, this message translates to:
  /// **'Location temporarily unavailable'**
  String get mapLocationUnavailable;

  /// Title of the map's location-access banner when the blocker is Haven's own location PERMISSION rather than the device location toggle. Must read as distinct from mapLocationOffTitle ('Location is off'), because the two have different remedies and the pair is the only thing telling the user which settings screen to open. Keep it short — it sits above a two-line body in a banner that must not dominate the map. Avoid blaming the user; state the capability that is missing.
  ///
  /// In en, this message translates to:
  /// **'Haven can\'t use your location'**
  String get mapLocationNoPermissionTitle;

  /// Body of the map's location-access banner when the DEVICE-WIDE location provider was switched off mid-session (Android LocationManager.isLocationEnabled false / iOS Location Services off). Distinct from mapLocationOffMessage, which is the calm first-run empty state for a user who declined the disclosure and has never shared: this one reports a change that already happened — sharing was working and has stopped. Two facts must survive translation: (a) the blocker is the DEVICE's location setting, not a Haven permission, and (b) the user's circles are no longer receiving their location. The remedy verb should match whatever the platform's own location toggle is called in this locale. Paired with title mapLocationOffTitle and the action label commonOpenSettings.
  ///
  /// In en, this message translates to:
  /// **'Location is off on this device, so Haven has stopped sharing your location with your circles. Turn location on to start again.'**
  String get mapLocationSharingStoppedServiceOff;

  /// Body of the map's location-access banner when Haven's location permission is not granted but can still be requested (geolocator LocationPermission.denied / unableToDetermine). Paired with title mapLocationNoPermissionTitle and the action label commonOpenSettings. Contrast with mapLocationSharingStoppedPermissionSettings, which covers the permanently-denied case where the app can no longer prompt. Do not say 'location is off' here — the device location service IS on in this state, and saying otherwise sends the user to the wrong screen.
  ///
  /// In en, this message translates to:
  /// **'Haven no longer has permission to use your location, so sharing has stopped. Allow location access to start again.'**
  String get mapLocationSharingStoppedPermission;

  /// Body of the map's location-access banner when Haven's location permission is permanently denied (Android 'Don't ask again' / iOS 'Never'), so the app can no longer show a permission prompt and the ONLY remedy is the system settings screen. Paired with title mapLocationNoPermissionTitle and the action label commonOpenSettings. Must not promise an in-app prompt. 'system settings' should match the OS's own naming in this locale.
  ///
  /// In en, this message translates to:
  /// **'Location access for Haven is turned off in system settings, so sharing has stopped. Allow it there to start again.'**
  String get mapLocationSharingStoppedPermissionSettings;

  /// Body of the map's location-access banner when BOTH blockers are present: the device location provider is off AND Haven's permission is not granted. Deliberately names both remedies rather than picking one, because fixing only one leaves the user still blocked and with no explanation. Paired with title mapLocationOffTitle and the action label commonOpenSettings. Keep both clauses — do not collapse them into a single generic 'check your settings'.
  ///
  /// In en, this message translates to:
  /// **'Haven has stopped sharing your location. Turn location on for this device and allow Haven to use it.'**
  String get mapLocationSharingStoppedBoth;

  /// Body of the map's location-access banner when location updates stopped and the platform checks that would name the cause themselves failed, so Haven genuinely does not know why. Honest by construction: it must state the observable fact and offer both things to check, and must NEVER assert a specific cause. Paired with the existing title mapLocationErrorTitle and the action label commonTryAgain.
  ///
  /// In en, this message translates to:
  /// **'Haven has stopped receiving your location, so sharing has stopped. Check that location is on and that Haven is allowed to use it.'**
  String get mapLocationSharingStoppedUnknown;

  /// Screen-reader-only announcement (SemanticsService.sendAnnouncement) fired once when location access returns and the map's location-access banner disappears. Nothing is drawn for this string — a live region announces its own APPEARANCE but not its removal, so without this a TalkBack/VoiceOver user is told that sharing stopped and never told that it resumed. Keep it a short complete sentence pair; it is spoken, never read. Do not include an action — there is nothing left to do. MUST BE CAUSE-NEUTRAL: it fires on recovery from ANY blocked state, so it must not name which blocker cleared. Saying 'location is back on' is WRONG in the permission-only cases, where the device location toggle was never off — that is the same wrong-cause imprecision the other six strings in this group exist to prevent, and here it is spoken aloud to someone who cannot see the screen to check.
  ///
  /// In en, this message translates to:
  /// **'Haven can use your location again. Sharing has resumed.'**
  String get mapLocationAccessRestoredAnnouncement;

  /// Title of the banner shown when the device clock is preventing or silently breaking location sharing. Short headline (fits one or two lines beside an icon). Names the phone as the thing that is wrong, because that is the only thing the user can act on. Address the DEVICE, not the user — the fault is the phone's, and blaming the user reads badly in a security app.
  ///
  /// In en, this message translates to:
  /// **'This phone\'s clock is wrong'**
  String get clockSkewTitle;

  /// Banner body when no relay accepted this device's location and at least one refused it on timestamp grounds (typically a clock running fast). Sharing is failing outright right now. 'Relays' are the Nostr servers Haven publishes to; keep the term if your locale's Haven UI already uses it, otherwise 'servers' is acceptable. The second sentence is the remedy and must stay actionable: on iOS this is Settings > General > Date & Time > Set Automatically, on Android Settings > System > Date & time > Set time automatically — use whatever wording your locale's OS actually shows. MUST NOT imply the send partially worked. No placeholders and no numbers: the measured magnitude is deliberately never rendered.
  ///
  /// In en, this message translates to:
  /// **'Your circles are not receiving your location, because the relays reject the time this phone stamps on it. Turn on automatic date and time in system settings to fix it.'**
  String get clockSkewBodyRejected;

  /// Banner body when TWO OR MORE independent circle members consistently report times ahead of this device (a clock running slow). The one-member case is a DIFFERENT string (clockSkewBodyDisagreement) because a single peer cannot tell us whose clock is wrong; this one may accuse this phone precisely because several members agree. Crucially this fault is INVISIBLE: the send succeeds and the data is then discarded, so the wording must convey 'sent but wasted', and MUST NEVER imply the send failed — that is the distinction from clockSkewBodyRejected, and the two bodies must not be merged. 'Expire' refers to a short time-to-live carried on each location update. Same remedy sentence as clockSkewBodyRejected; keep it identical in your locale so the fix reads the same in both faults.
  ///
  /// In en, this message translates to:
  /// **'This phone is running behind the rest of your circles, so the locations it sends expire before anyone can see them. Turn on automatic date and time in system settings to fix it.'**
  String get clockSkewBodyBehind;

  /// Screen-reader announcement spoken once when the clock warning clears. A live region announces its appearance but never its removal, so this is the only signal a screen-reader user gets that sharing recovered. 'Haven' is the app name and is never translated.
  ///
  /// In en, this message translates to:
  /// **'The clock problem is gone. Haven is sharing your location again.'**
  String get clockSkewResolvedAnnouncement;

  /// Title of the clock banner in the ONE-OTHER-MEMBER case, where Haven has heard from exactly one other member and therefore CANNOT tell whose clock is wrong — this phone's or theirs. It MUST NOT accuse this phone: that is what the other title (clockSkewTitle) is for, and it is used only when two or more members independently agree. Say 'one of your circles', NEVER 'this circle': the verdict is app-global (it is fed by every circle at once), so the banner can be on screen while the map is showing a different circle than the one the disagreement came from. Short headline (fits one or two lines beside an icon). 'Circle' is Haven's word for a sharing group and is already translated elsewhere in this file — reuse that term, in the plural.
  ///
  /// In en, this message translates to:
  /// **'A clock in one of your circles is wrong'**
  String get clockSkewTitleDisagreement;

  /// Banner body paired with clockSkewTitleDisagreement: exactly one other member has been heard from, so the disagreement is certain but the CULPRIT is not. Three hard accuracy limits, all of which a careless translation breaks. (1) NEVER say this phone's clock is wrong, only that the two disagree. (2) NEVER say anything IS being lost: the protocol tolerates roughly four and a half minutes of disagreement, so between two minutes (when this fires) and that point nothing is lost yet — hence 'can expire', a possibility, never 'expire'. Compare clockSkewBodyBehind, which DOES assert real loss and is used only when several members agree. (3) The remedy is deliberately hedged: fixing this phone's clock only rules THIS phone out; it cannot fix the other member's. 'Two minutes' is the real alert threshold (120 seconds) — keep the number. 'Expire' refers to a short time-to-live carried on each location update. Use the same words for the automatic-date-and-time setting as clockSkewBodyRejected does in your locale (on iOS Settings > General > Date & Time > Set Automatically, on Android Settings > System > Date & time > Set time automatically).
  ///
  /// In en, this message translates to:
  /// **'This phone\'s clock and another member\'s disagree by two minutes or more. If this phone\'s is the wrong one, the locations it sends can expire before anyone sees them. Turn on automatic date and time in system settings to make sure this phone is not the one that is wrong.'**
  String get clockSkewBodyDisagreement;

  /// Screen-reader announcement spoken once when the ONE-OTHER-MEMBER clock banner clears. Separate from clockSkewResolvedAnnouncement because that one says Haven 'is sharing your location again', which would be an over-claim here: in this case sharing may never have stopped at all (see clockSkewBodyDisagreement). It must ALSO not claim the clocks now agree: the banner can clear because a second member was heard and re-attributed the outlier, while the disagreeing sample is still live. So it states only that the WARNING is gone — the one thing that is certainly true — and says nothing about circles or clocks agreeing. Spoken, never read; keep it one short sentence and offer no action — there is nothing left to do.
  ///
  /// In en, this message translates to:
  /// **'The clock warning is gone.'**
  String get clockSkewDisagreementResolvedAnnouncement;

  /// Headline of the map banner shown when BOTH directions of location sharing have stopped (the relay connection dropped): this device is neither sending nor receiving. Do not merge with the two directional headlines below — saying 'has stopped' when only one direction is broken would be inaccurate.
  ///
  /// In en, this message translates to:
  /// **'Location sharing has stopped'**
  String get sharingHealthTitleStopped;

  /// Headline of the map banner shown when this device's location updates are no longer reaching any relay. Receiving may still be working, so this must NOT claim that all of sharing stopped.
  ///
  /// In en, this message translates to:
  /// **'Your location is not being shared'**
  String get sharingHealthTitleNotSending;

  /// Headline of the map banner shown when other members' locations have stopped arriving. This device may still be sending its own, so this must NOT claim that all of sharing stopped.
  ///
  /// In en, this message translates to:
  /// **'You are not receiving locations'**
  String get sharingHealthTitleNotReceiving;

  /// Body of the sharing-health map banner, under one hour. IMPORTANT: this ONE body is rendered under ALL THREE headlines (sharingHealthTitleStopped, sharingHealthTitleNotSending, sharingHealthTitleNotReceiving), so it must carry NO subject and NO verb agreeing with one — a translation that supplies a subject such as 'sharing' reads as a mismatch under the 'you are not receiving' headline, where the thing that stopped is the receiving. Keep it a bare noun phrase. 'About' is deliberate: the age is measured from the last delivery Haven can actually prove — a relay-acknowledged publish or a decrypted peer location — never from the moment a fault was noticed, because a fault noticed just now on a circle that has been silent for half an hour must not be dated 'a moment ago'. An 'update' here is one location message in either direction.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{No updates for about 1 minute} other{No updates for about {count} minutes}}'**
  String sharingHealthNoUpdatesMinutes(int count);

  /// Body of the sharing-health map banner when the gap is hours (under one day). Same subject-less rule as sharingHealthNoUpdatesMinutes — read that description first.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{No updates for about 1 hour} other{No updates for about {count} hours}}'**
  String sharingHealthNoUpdatesHours(int count);

  /// Body of the sharing-health map banner when the gap is a day or more. Same subject-less rule as sharingHealthNoUpdatesMinutes — read that description first.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{No updates for about 1 day} other{No updates for about {count} days}}'**
  String sharingHealthNoUpdatesDays(int count);

  /// Label of the single remedy button on the sharing-health map banner. Keep it short — it sits on one line inside the banner, next to a spinner while it runs. Prefer an imperative verb where the locale forms button labels that way; languages that label buttons with a verbal noun (Japanese 修復, Arabic إصلاح) should use their own convention rather than forcing an imperative. The word must be the same one that appears in sharingHealthRepairSent.
  ///
  /// In en, this message translates to:
  /// **'Repair'**
  String get sharingHealthRepairAction;

  /// Accessibility hint spoken for the Repair button while it is DISABLED, Map → sharing-health banner. WCAG 2.1 SC 4.1.2: a disabled control must still say why it cannot be used. Shown for BOTH outcomes that never clear by waiting — this device is not the circle's admin, and the circle's encryption state is unrecoverable here — so it must be true of both. Do NOT say the circle cannot be repaired on this phone: in the first case it CAN be, just not by this user, which the banner line beside it says outright. Say only that the control is unavailable for this circle; the banner carries the reason. Must not invite a retry. It is sometimes the ONLY spoken statement of why the button is dead: the button is its own focusable node, so a user arriving by focus traversal hears this and not the banner line above it.
  ///
  /// In en, this message translates to:
  /// **'Repair is unavailable for this circle'**
  String get sharingHealthRepairUnavailableHint;

  /// Accessibility hint spoken for the Repair button, describing what it actually does. It re-reads the circle list, re-anchors the relay subscriptions, re-runs the location publish, and MAY commit a new circle key. Two hedges are load-bearing and must both survive translation. (1) The key clause is conditional on ROLE: only this circle's sole admin can do it — use this locale's 'Admin' badge wording (circleMemberAdmin), not 'the person who created it', because after an admin handoff those differ. (2) 'may' is not politeness: five further gates (epoch too recent, circle too busy, a departure pending, already repaired today, engine state unsettled) decline silently even for the admin, so a flat promise would be wrong most of the time. Do not say 'rotates keys' or imply anything periodic. The commit carries no MLS UpdatePath: it resets the sender ratchets and gives NO post-compromise security, so 'new key' must stay that plain — never 'fresh', 'secure again', 'locks out', or any wording implying past or future traffic becomes unreadable to anyone.
  ///
  /// In en, this message translates to:
  /// **'Reconnects to the relays, retries sending your location, and, if you are this circle\'s admin, may give it a new key'**
  String get sharingHealthRepairHint;

  /// Shown in the sharing-health banner AND spoken by the screen reader (it is folded into the banner's live-region label), Map. MUST NOT promise instant recovery: the repair changes this device's key material immediately, but every other member only applies it when they next RECEIVE it — which is a receive event on their side, not merely their next send — so their locations start arriving again some minutes later, longer if a phone is asleep. Do not translate as 'fixed' or 'sharing restored' — the honest claim is that the repair was sent and the others will follow once they have picked it up. 'Repair' must match sharingHealthRepairAction. The commit carries no MLS UpdatePath: it resets the sender ratchets and gives NO post-compromise security, so never strengthen this into 'secure again', 'locked out', or any wording implying past or future traffic becomes unreadable to anyone.
  ///
  /// In en, this message translates to:
  /// **'Repair sent. The others will catch up once their phones have picked it up.'**
  String get sharingHealthRepairSent;

  /// Shown in the sharing-health banner AND spoken (folded into the live-region label), Map. Displayed when the user taps Repair on a circle where this device is not the SOLE admin — which is normally the circle's creator, but NOT always: after an admin handoff the creator is no longer the admin, and mid-handoff there are briefly two. So the copy must name the ROLE, not the creator: use whatever this locale uses for the 'Admin' badge (see circleMemberAdmin). Repairing needs that admin, and there is no message the app can send on the user's behalf, so the remedy is a real-world one: ask them to remove and re-add you. Say WHO can do it and WHAT to ask for; do not imply the app will do it, and do not suggest leaving and rejoining on your own (that is not the same thing and does not work).
  ///
  /// In en, this message translates to:
  /// **'Only this circle\'s admin can repair it. Ask them to remove you and add you back.'**
  String get sharingHealthRepairNotOwner;

  /// Shown in the sharing-health banner AND spoken (folded into the live-region label), Map. Displayed when the circle's encryption state is unrecoverable on this device. This never clears by waiting, so the copy must NOT invite a retry — it is the one repair outcome with no second attempt, and the Repair button is disabled while it is on screen. Keep it concrete and non-technical: the remedy is a new circle with the same members. Do not mention epochs, MLS, or state machines.
  ///
  /// In en, this message translates to:
  /// **'This circle cannot be repaired on this phone. Make a new circle with the same people.'**
  String get sharingHealthRepairNeedsNewCircle;

  /// Shown in the sharing-health banner AND spoken (folded into the live-region label), Map. Displayed when the repair ran but the key-change step declined for a reason that will clear on its own — the epoch changed too recently, the circle is busy, a departure is pending, it was already repaired today, or the engine state is unsettled. It exists so a tap is never SILENT. Must not sound like a failure and must not invite an immediate retry; the second sentence carries that. Keep it short: it is read aloud after the fault line.
  ///
  /// In en, this message translates to:
  /// **'Nothing to repair right now. Haven will keep trying.'**
  String get sharingHealthRepairNothingToDo;

  /// Screen-reader announcement spoken once when the user has tapped Repair on the sharing-health banner and the banner is STILL showing afterwards. Without it, a screen-reader user gets no signal at all that the remedy did not work — the banner is a live region, which announces its appearance but never its persistence. Must not blame the user or promise a retry will help; it only reports the outcome.
  ///
  /// In en, this message translates to:
  /// **'Location sharing is still not working.'**
  String get sharingHealthRepairUnresolvedAnnouncement;

  /// Screen-reader announcement spoken once when the sharing-health banner clears. A live region announces its appearance but never its removal, so this is the only signal a screen-reader user gets that sharing recovered.
  ///
  /// In en, this message translates to:
  /// **'Location sharing is working again.'**
  String get sharingHealthResumedAnnouncement;

  /// Secondary line on a circle member's row in the members list, giving the age of their last known location. Shown only once the location is older than the threshold the map marker's age pill uses, so the list and the map never disagree. Deliberately expressed in minutes at every age (e.g. '90 minutes ago' rather than '1 hour ago') to match that pill exactly.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{Last seen 1 minute ago} other{Last seen {count} minutes ago}}'**
  String circleMemberLastSeenMinutes(int count);

  /// Generic fallback name for a member marker (used in the 'Open in Apple Maps' prompt) when the member has no display name.
  ///
  /// In en, this message translates to:
  /// **'this location'**
  String get mapThisLocation;

  /// Generic fallback name spoken to assistive technology when recentering the map on a member who has no display name.
  ///
  /// In en, this message translates to:
  /// **'member'**
  String get mapMemberFallbackName;

  /// Title of the iOS confirmation sheet asking whether to open a member's location in Apple Maps. {label} is the member's display name or a generic fallback. 'Apple Maps' is intentionally English (brand name).
  ///
  /// In en, this message translates to:
  /// **'Open {label} in Apple Maps?'**
  String mapOpenInAppleMapsTitle(String label);

  /// Subtitle of the iOS Apple Maps confirmation sheet, clarifying that only the coordinate is shared. 'Apple Maps' is intentionally English (brand name).
  ///
  /// In en, this message translates to:
  /// **'Only the map coordinate is sent to Apple Maps, never a name or identity.'**
  String get mapOpenInAppleMapsBody;

  /// Confirm action on the iOS Apple Maps sheet that opens the coordinate in Apple Maps. 'Apple Maps' is intentionally English (brand name).
  ///
  /// In en, this message translates to:
  /// **'Open in Apple Maps'**
  String get mapOpenInAppleMapsConfirm;

  /// Snackbar shown when opening the coordinate in Apple Maps fails. 'Maps' refers to Apple Maps, intentionally English (brand name).
  ///
  /// In en, this message translates to:
  /// **'Could not open Maps'**
  String get mapOpenMapsError;

  /// Tooltip on the map zoom-in button.
  ///
  /// In en, this message translates to:
  /// **'Zoom in'**
  String get mapControlsZoomIn;

  /// Tooltip on the map zoom-out button.
  ///
  /// In en, this message translates to:
  /// **'Zoom out'**
  String get mapControlsZoomOut;

  /// Tooltip on the map recenter button in the vertical map controls.
  ///
  /// In en, this message translates to:
  /// **'Recenter'**
  String get mapControlsRecenter;

  /// Tooltip on the floating recenter button (the FAB variant of the recenter control).
  ///
  /// In en, this message translates to:
  /// **'Recenter on my location'**
  String get mapControlsRecenterFab;

  /// Accessibility label for the button that expands the map's attribution credits and licence.
  ///
  /// In en, this message translates to:
  /// **'Map credits and licence'**
  String get mapAttributionCreditsButton;

  /// Accessibility label for the user's own location marker on the map. {accuracy} is an optional accuracy clause (userLocationMarkerAccuracy) appended when an accuracy circle is shown, or empty otherwise.
  ///
  /// In en, this message translates to:
  /// **'Your location marker{accuracy}'**
  String userLocationMarkerSemantics(String accuracy);

  /// Optional accuracy clause appended to the user-location-marker accessibility label, e.g. '. Accuracy: 40 meters'. {meters} is an integer count of meters.
  ///
  /// In en, this message translates to:
  /// **'. Accuracy: {meters} meters'**
  String userLocationMarkerAccuracy(int meters);

  /// Compact age pill on a member marker for minutes, e.g. '5m'. The 'm' suffix is intentionally English (a compact time abbreviation).
  ///
  /// In en, this message translates to:
  /// **'{count}m'**
  String memberMarkerMinutesShort(int count);

  /// Expanded last-seen age, in minutes, read by screen readers for a member marker.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 minute ago} other{{count} minutes ago}}'**
  String memberMarkerMinutesAgoSemantics(int count);

  /// Accessibility label for an on-screen member marker that has a display name. {name} is the member's display name.
  ///
  /// In en, this message translates to:
  /// **'{name} member marker'**
  String memberMarkerNamedSemantics(String name);

  /// Accessibility label for an on-screen member marker with no display name (never the initials, which can be a pubkey fragment).
  ///
  /// In en, this message translates to:
  /// **'Member marker'**
  String get memberMarkerGenericSemantics;

  /// Accessibility label for an on-screen member marker including its last-seen age. {base} is the named or generic marker label; {age} is the expanded relative age (e.g. '5 minutes ago').
  ///
  /// In en, this message translates to:
  /// **'{base}, last seen {age}'**
  String memberMarkerLastSeenSemantics(String base, String age);

  /// Accessibility label for an off-screen member marker. Spoken by screen readers; tapping recenters the map on the member. {name} is the member's display name; {direction} is one of the localized compass* strings. The compass bearing is real geography and reads the same in every language and layout direction.
  ///
  /// In en, this message translates to:
  /// **'{name} is off-screen to the {direction}, tap to view'**
  String memberMarkerOffScreenSemantics(String name, String direction);

  /// Accessibility label for an off-screen member marker when no display name is known. {direction} is one of the localized compass* strings.
  ///
  /// In en, this message translates to:
  /// **'A member is off-screen to the {direction}, tap to view'**
  String memberMarkerOffScreenGenericSemantics(String direction);

  /// Compass direction 'north', inserted as {direction} in the off-screen member accessibility labels. A real-world bearing; translate to the natural cardinal-direction word.
  ///
  /// In en, this message translates to:
  /// **'north'**
  String get compassNorth;

  /// Compass direction 'north-east', inserted as {direction} in the off-screen member accessibility labels. A real-world bearing; translate to the natural intercardinal-direction word.
  ///
  /// In en, this message translates to:
  /// **'north-east'**
  String get compassNorthEast;

  /// Compass direction 'east', inserted as {direction} in the off-screen member accessibility labels. A real-world bearing; translate to the natural cardinal-direction word.
  ///
  /// In en, this message translates to:
  /// **'east'**
  String get compassEast;

  /// Compass direction 'south-east', inserted as {direction} in the off-screen member accessibility labels. A real-world bearing; translate to the natural intercardinal-direction word.
  ///
  /// In en, this message translates to:
  /// **'south-east'**
  String get compassSouthEast;

  /// Compass direction 'south', inserted as {direction} in the off-screen member accessibility labels. A real-world bearing; translate to the natural cardinal-direction word.
  ///
  /// In en, this message translates to:
  /// **'south'**
  String get compassSouth;

  /// Compass direction 'south-west', inserted as {direction} in the off-screen member accessibility labels. A real-world bearing; translate to the natural intercardinal-direction word.
  ///
  /// In en, this message translates to:
  /// **'south-west'**
  String get compassSouthWest;

  /// Compass direction 'west', inserted as {direction} in the off-screen member accessibility labels. A real-world bearing; translate to the natural cardinal-direction word.
  ///
  /// In en, this message translates to:
  /// **'west'**
  String get compassWest;

  /// Compass direction 'north-west', inserted as {direction} in the off-screen member accessibility labels. A real-world bearing; translate to the natural intercardinal-direction word.
  ///
  /// In en, this message translates to:
  /// **'north-west'**
  String get compassNorthWest;

  /// Generic 'Add' confirmation button label, used to commit a newly entered item (e.g. a relay address).
  ///
  /// In en, this message translates to:
  /// **'Add'**
  String get commonAdd;

  /// Title of the bottom sheet for adding a new Inbox relay address.
  ///
  /// In en, this message translates to:
  /// **'Add Inbox relay'**
  String get addRelaySheetTitleInbox;

  /// Title of the bottom sheet for adding a new KeyPackage relay address. 'KeyPackage' is a Marmot/MLS protocol term, intentionally English (not translated).
  ///
  /// In en, this message translates to:
  /// **'Add KeyPackage relay'**
  String get addRelaySheetTitleKeyPackage;

  /// Title of the bottom sheet for adding a new Profile relay address (the local-only kind-0 lookup/publish category).
  ///
  /// In en, this message translates to:
  /// **'Add Profile relay'**
  String get addRelaySheetTitleProfile;

  /// Text-field hint in the add-relay sheet showing the expected relay URL format. A technical URL example, intentionally English (not translated).
  ///
  /// In en, this message translates to:
  /// **'wss://relay.example.com'**
  String get addRelaySheetHint;

  /// Tooltip on the button that pastes a relay URL from the system clipboard into the add-relay field.
  ///
  /// In en, this message translates to:
  /// **'Paste from clipboard'**
  String get addRelaySheetPasteTooltip;

  /// Validation message shown in the add-relay field when the input is empty, whitespace-only, or only a bare scheme prefix.
  ///
  /// In en, this message translates to:
  /// **'Enter a relay address.'**
  String get addRelaySheetErrorEmpty;

  /// Validation message shown when the user enters an insecure ws:// relay URL. 'wss://' is a technical URL scheme, intentionally English (not translated).
  ///
  /// In en, this message translates to:
  /// **'Use wss:// so traffic to this relay is encrypted.'**
  String get addRelaySheetErrorInsecureScheme;

  /// Validation message shown when the entered relay URL embeds credentials (a user:pass@host form).
  ///
  /// In en, this message translates to:
  /// **'Relay URL must not contain credentials.'**
  String get addRelaySheetErrorHasCredentials;

  /// Validation message shown when the entered relay URL cannot be parsed or does not look like a relay address. 'wss://relay.example.com' is a technical URL example, intentionally English (not translated).
  ///
  /// In en, this message translates to:
  /// **'Enter a relay address like wss://relay.example.com.'**
  String get addRelaySheetErrorInvalidFormat;

  /// Screen-reader label for a user's avatar — the leading fragment of a composed avatar semantics label.
  ///
  /// In en, this message translates to:
  /// **'User avatar'**
  String get avatarSemanticsLabel;

  /// Screen-reader fragment naming whose avatar it is, by their initials; appended after the avatar label.
  ///
  /// In en, this message translates to:
  /// **'for {initials}'**
  String avatarSemanticsFor(String initials);

  /// Screen-reader fragment: the user is currently online (avatar online indicator).
  ///
  /// In en, this message translates to:
  /// **'online'**
  String get avatarSemanticsOnline;

  /// Screen-reader fragment: the user is currently offline (avatar online indicator).
  ///
  /// In en, this message translates to:
  /// **'offline'**
  String get avatarSemanticsOffline;
}

class _AppLocalizationsDelegate
    extends LocalizationsDelegate<AppLocalizations> {
  const _AppLocalizationsDelegate();

  @override
  Future<AppLocalizations> load(Locale locale) {
    return SynchronousFuture<AppLocalizations>(lookupAppLocalizations(locale));
  }

  @override
  bool isSupported(Locale locale) => <String>[
    'ar',
    'de',
    'en',
    'es',
    'fa',
    'fr',
    'hi',
    'ja',
    'ne',
    'pt',
    'ru',
    'tr',
    'ur',
  ].contains(locale.languageCode);

  @override
  bool shouldReload(_AppLocalizationsDelegate old) => false;
}

AppLocalizations lookupAppLocalizations(Locale locale) {
  // Lookup logic when only language code is specified.
  switch (locale.languageCode) {
    case 'ar':
      return AppLocalizationsAr();
    case 'de':
      return AppLocalizationsDe();
    case 'en':
      return AppLocalizationsEn();
    case 'es':
      return AppLocalizationsEs();
    case 'fa':
      return AppLocalizationsFa();
    case 'fr':
      return AppLocalizationsFr();
    case 'hi':
      return AppLocalizationsHi();
    case 'ja':
      return AppLocalizationsJa();
    case 'ne':
      return AppLocalizationsNe();
    case 'pt':
      return AppLocalizationsPt();
    case 'ru':
      return AppLocalizationsRu();
    case 'tr':
      return AppLocalizationsTr();
    case 'ur':
      return AppLocalizationsUr();
  }

  throw FlutterError(
    'AppLocalizations.delegate failed to load unsupported locale "$locale". This is likely '
    'an issue with the localizations generation tool. Please file an issue '
    'on GitHub with a reproducible sample app and the gen-l10n configuration '
    'that was used.',
  );
}
