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

  /// Headline of the first onboarding value-prop card (also reused on the About page).
  ///
  /// In en, this message translates to:
  /// **'Only your circles can see you'**
  String get onboardingValueProp1Title;

  /// Body of the first onboarding value-prop card (also reused on the About page).
  ///
  /// In en, this message translates to:
  /// **'Your location is encrypted on your device before it leaves, so only the circles you choose can read it, never Haven or anyone else. Because Haven is open source, anyone can verify that.'**
  String get onboardingValueProp1Body;

  /// Headline of the second onboarding value-prop card (also reused on the About page).
  ///
  /// In en, this message translates to:
  /// **'No one can shut it down'**
  String get onboardingValueProp2Title;

  /// Body of the second onboarding value-prop card (also reused on the About page).
  ///
  /// In en, this message translates to:
  /// **'Haven has no central server. Your encrypted messages travel through independent servers called relays, and you choose which ones to use. No single company or government can switch the network off.'**
  String get onboardingValueProp2Body;

  /// Headline of the third onboarding value-prop card (also reused on the About page).
  ///
  /// In en, this message translates to:
  /// **'No account needed'**
  String get onboardingValueProp3Title;

  /// Body of the third onboarding value-prop card (also reused on the About page).
  ///
  /// In en, this message translates to:
  /// **'No email, no phone number, no sign-up. Haven creates an identity whose secret key never leaves your phone, so there is no account for anyone to hand over.'**
  String get onboardingValueProp3Body;

  /// Short one-line summary of the first value prop, shown under its title on the onboarding intro screen. The longer onboardingValueProp1Body is shown on the About page instead. Keep it to roughly one short sentence so the intro screen fits without scrolling.
  ///
  /// In en, this message translates to:
  /// **'Encrypted on your device, so only the circles you choose can read it.'**
  String get onboardingValueProp1Summary;

  /// Short one-line summary of the second value prop, shown under its title on the onboarding intro screen. Keep it to roughly one short sentence so the intro screen fits without scrolling.
  ///
  /// In en, this message translates to:
  /// **'No central server . It runs on a relay network you choose.'**
  String get onboardingValueProp2Summary;

  /// Short one-line summary of the third value prop, shown under its title on the onboarding intro screen. Keep it to roughly one short sentence so the intro screen fits without scrolling. Must stay consistent with onboardingValueProp3Body, which it summarises: an earlier version claimed 'nothing links it to you', which over-claimed (the user's network address is visible to every relay, and the same key carries a renameable public profile). Keep the claim narrowed to key custody.
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

  /// Generic action that opens the OS app settings (e.g. to grant notifications or change location permission).
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

  /// Subtitle under the Identity tile on the Settings hub.
  ///
  /// In en, this message translates to:
  /// **'Profile, keys, and photo sharing'**
  String get settingsIdentitySubtitle;

  /// Title of the Relays tile on the Settings hub, opening the relay settings page.
  ///
  /// In en, this message translates to:
  /// **'Relays'**
  String get settingsRelaysTitle;

  /// Subtitle under the Relays tile on the Settings hub.
  ///
  /// In en, this message translates to:
  /// **'Where invitations reach you'**
  String get settingsRelaysSubtitle;

  /// Title of the Location tile on the Settings hub, opening the location settings page.
  ///
  /// In en, this message translates to:
  /// **'Location'**
  String get settingsLocationTitle;

  /// Subtitle under the Location tile on the Settings hub.
  ///
  /// In en, this message translates to:
  /// **'Background sharing and permissions'**
  String get settingsLocationSubtitle;

  /// Title of the Map style tile on the Settings hub, opening the map-style picker.
  ///
  /// In en, this message translates to:
  /// **'Map style'**
  String get settingsMapStyleTitle;

  /// Subtitle under the Appearance tile on the Settings hub. The Appearance tile title reuses appearanceTitle.
  ///
  /// In en, this message translates to:
  /// **'Theme and language'**
  String get settingsAppearanceSubtitle;

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

  /// Generic snackbar shown when toggling background sharing fails unexpectedly.
  ///
  /// In en, this message translates to:
  /// **'Something went wrong'**
  String get locationSettingsErrorSnack;

  /// Framing paragraph at the top of the location settings page. MUST NOT promise that the user's OWN sharing resumes after the system closes the app: every background wake path (catchup_service.dart, ios_background_catchup.dart, HavenSLCHandler.swift) is receive-only and contains no publish call site, and Android has no movement trigger at all. An earlier version claimed 'updates resume when you move or when the system next wakes the app', which was false on both platforms. The final sentence is a SECOND, later correction and is platform-asymmetric on purpose, the same way privacyWhatOthersSeeScreenshots is: a version after that one said flatly 'sharing stops until you open it again', which is false on Android in the dangerous direction. RebootReceiver is android:enabled="true" (AndroidManifest.xml) and ForegroundTaskOptions sets autoRunOnBoot:true (background_location_manager.dart), so a reboot resurrects the PUBLISHING foreground service with no user action; and no android:stopWithTask is set anywhere, so the service also survives the app being swiped out of recents. A user who reboots believing sharing stopped is still broadcasting, so never flatten these two platforms back into one sentence. The Android exception stops exactly there and must not be widened: RestartReceiver is android:enabled="false", so an OS or OEM kill of the service is never auto-restarted, and iOS has no publishing wake path at all.
  ///
  /// In en, this message translates to:
  /// **'Haven shares your location with your circles whenever the app is open. Turn this on and your circles keep seeing it while Haven is in the background. If the system closes Haven, sharing stops — background wake-ups only fetch your circles\' locations, they never send yours. On Android, sharing survives swiping Haven away and starts again by itself after a reboot; on iPhone it stays stopped until you open Haven.'**
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

  /// iOS-only note shown when background sharing is on but the location permission is only 'while in use'. Must stay honest in both directions: While-In-Use IS sufficient for continued background sharing while the app stays running (never claim 'Always' is required for that), and 'Always' still genuinely improves catch-up after iOS terminates the app (never present While-In-Use as loss-free), and 'Always' does NOT resume the user's own sharing — the SLC relaunch it enables is receive-only (HavenSLCHandler.swift), so never imply the user keeps being seen. The closing 'resumes when you reopen Haven' is true ONLY because this note is iOS-scoped — it renders behind `sharingEnabled && iosLimited`, and iosLimited is always false off iOS (location_settings_page.dart). The same sentence would be false on Android, where a reboot restarts the publishing foreground service by itself (see locationSettingsIntro), so never lift it into a cross-platform string.
  ///
  /// In en, this message translates to:
  /// **'Sharing keeps working in the background with your current permission. Choose \'Always\' for Haven in Settings so Haven can also catch up on your circles\' locations after iOS closes the app. Your own sharing resumes when you reopen Haven.'**
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

  /// iOS-only reliability guidance card. Explains that background sharing works via a continuous location session (with the visible blue indicator), and frames the 'Always' permission as an optional enhancement for catch-up after app termination — never as a requirement for background sharing.
  ///
  /// In en, this message translates to:
  /// **'While background sharing is on, Haven keeps a continuous location session and iOS shows a blue status-bar indicator. Granting \"Always\" additionally lets Haven catch up on your circles after iOS closes the app.'**
  String get locationSettingsIosGuidance;

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

  /// Link label for the Mullvad VPN website. A domain name, intentionally English (not translated).
  ///
  /// In en, this message translates to:
  /// **'mullvad.net'**
  String get aboutVpnLinkLabel;

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

  /// Title of the Privacy section: both the Settings row (directly above About) and the Privacy hub page's app bar.
  ///
  /// In en, this message translates to:
  /// **'Privacy'**
  String get privacyTitle;

  /// Subtitle of the Privacy row in the Settings menu. Sets the expectation that this section explains the technology as well as the privacy consequences.
  ///
  /// In en, this message translates to:
  /// **'How Haven works and what others can see'**
  String get privacySubtitle;

  /// Always-visible summary paragraph at the top of the Privacy hub — the thirty-second answer for a reader who taps nothing else. Audience: non-technical, no Nostr knowledge assumed. Must promise honesty about limits, not only reassurance. Keep sentences under 25 words. The third sentence is factually load-bearing: the profile (kind 0) is NOT the only public thing — the kind-10002/10050 relay lists and the kind-30443 KeyPackage are published under the same identity key, and relay-list publishing is on by default (haven-core/src/circle/storage_relay_prefs.rs). An earlier version claimed the name and photo were 'the one thing that is public', which the app's own privacyRelaysMeansForYou and privacyRelaysDetailKeyListIsPublic contradicted. Match the enumeration already used in privacyRelaysMeansForYou in this locale.
  ///
  /// In en, this message translates to:
  /// **'Haven shares your location only with the small groups you choose, called circles, and encrypts it on your phone before it leaves. There is no sign-up and no Haven server. The display name and photo you set are public, along with the keys and relay lists that others need in order to invite you. The pages below explain that, and everything else, in plain language.'**
  String get privacyHubSummary;

  /// Header for the first group of Privacy topics on the hub (what Haven is, your keys, your public profile).
  ///
  /// In en, this message translates to:
  /// **'The basics'**
  String get privacyGroupBasicsHeading;

  /// Fixed label introducing the practical takeaway at the end of every Privacy topic page. Appears on every topic, so it must read naturally as a recurring heading.
  ///
  /// In en, this message translates to:
  /// **'What this means for you'**
  String get privacyMeansForYouLabel;

  /// Header of the collapsed region holding technical depth at the end of a Privacy topic page. Should invite a curious reader without implying the main text was incomplete.
  ///
  /// In en, this message translates to:
  /// **'In more detail'**
  String get privacyMoreDetailLabel;

  /// Screen-reader action hint on the collapsed 'In more detail' header, describing what activating it does.
  ///
  /// In en, this message translates to:
  /// **'Show the technical detail'**
  String get privacyMoreDetailExpandHint;

  /// Screen-reader action hint on the expanded 'In more detail' header, describing what activating it does.
  ///
  /// In en, this message translates to:
  /// **'Hide the technical detail'**
  String get privacyMoreDetailCollapseHint;

  /// Screen-reader announcement fired when the 'In more detail' region is expanded. Announces the resulting state, not the action.
  ///
  /// In en, this message translates to:
  /// **'Technical detail shown'**
  String get privacyMoreDetailExpandedAnnouncement;

  /// Screen-reader announcement fired when the 'In more detail' region is collapsed. Announces the resulting state, not the action.
  ///
  /// In en, this message translates to:
  /// **'Technical detail hidden'**
  String get privacyMoreDetailCollapsedAnnouncement;

  /// Title of the Privacy topic covering Haven's shape: no account, no Haven servers, no analytics. Front-loaded with the distinguishing words so screen-reader users scanning headings hear what differs first.
  ///
  /// In en, this message translates to:
  /// **'What Haven is, and why there\'s no account'**
  String get privacyWhatHavenIsTitle;

  /// One-line preview shown under the topic title on the Privacy hub.
  ///
  /// In en, this message translates to:
  /// **'No sign-up, no company server'**
  String get privacyWhatHavenIsSubtitle;

  /// Body paragraph, Privacy → What Haven is. Audience: non-technical. 'circle' is Haven's own term for a sharing group — keep it consistent with how circles are named elsewhere in the app. Sentences under 20 words.
  ///
  /// In en, this message translates to:
  /// **'Haven shares your location with small groups you choose, called circles. There is no account behind it. You never give an email address, a phone number, or a password.'**
  String get privacyWhatHavenIsNoAccount;

  /// Body paragraph, Privacy → What Haven is. Introduces 'relay' with a plain-language handhold BEFORE the term ('independent servers called relays'), which is the pattern used throughout this section. 'relay' is a Nostr term of art — keep it recognizable; do not translate it to a generic word for 'server'.
  ///
  /// In en, this message translates to:
  /// **'Haven also runs no servers of its own. Your encrypted location updates pass through independent servers called relays, run by other people. Haven\'s developers cannot see your location and put no tracking in the app. The one thing they can see is how much the map is used in total, because map tiles are fetched with a single shared key, never who fetched them.'**
  String get privacyWhatHavenIsNoServers;

  /// The practical takeaway for Privacy → What Haven is. Deliberately pairs the benefit with its cost. Factually load-bearing: an earlier version said 'nobody is holding it', which is false — relays retain the kind-0 profile, the kind-10002/10050 relay lists and the kind-30443 KeyPackage indefinitely, no deletion path exists for the KeyPackage, and the photo sits on a Blossom image host with no DELETE (haven-core/src/profile/). Scope the 'cannot hand over' claim to LOCATION, which is genuinely unreadable to a relay, and keep the published-is-permanent clause — the app states the same thing in privacyPublicProfileRemovalIsNotDeletion. The quoted phrase is the leading phrase of the privacyYourKeysTitle topic title — translate it identically to the way that title opens in this locale so the cross-reference is recognisable.
  ///
  /// In en, this message translates to:
  /// **'No relay operator can be made to hand over your location, because the servers that carry it cannot read it. The cost is that nobody can restore your identity for you, and whatever you have already published stays published. See “Your two keys” for what to back up.'**
  String get privacyWhatHavenIsMeansForYou;

  /// Technical-detail paragraph (collapsed by default), Privacy → What Haven is. Register may be more technical than the main body.
  ///
  /// In en, this message translates to:
  /// **'The app contains no analytics, crash reporting, or advertising code. Because Haven is open source, that can be checked rather than taken on trust.'**
  String get privacyWhatHavenIsDetailNoTelemetry;

  /// Technical-detail paragraph (collapsed by default), Privacy → What Haven is. Explains a deliberate omission, so the reasoning matters more than the feature.
  ///
  /// In en, this message translates to:
  /// **'Haven also has no push notifications, on purpose. A notification service would have to be told whenever anyone in your circles had something to deliver, which would reveal more about your habits than the relays do.'**
  String get privacyWhatHavenIsDetailNoPush;

  /// Title of the Privacy topic covering the secret/public key pair. Also quoted inside privacyWhatHavenIsMeansForYou — keep both translations identical.
  ///
  /// In en, this message translates to:
  /// **'Your two keys: one secret, one to share'**
  String get privacyYourKeysTitle;

  /// One-line preview shown under the topic title on the Privacy hub.
  ///
  /// In en, this message translates to:
  /// **'What identifies you, and what to back up'**
  String get privacyYourKeysSubtitle;

  /// Body paragraph, Privacy → Your two keys. Audience: non-technical; the username/password comparison is the handhold and should be kept.
  ///
  /// In en, this message translates to:
  /// **'Instead of a username and password, you have a pair of keys. The secret key proves you are you. The public key is what others use to find and invite you.'**
  String get privacyYourKeysWhatTheyAre;

  /// Body paragraph, Privacy → Your two keys.
  ///
  /// In en, this message translates to:
  /// **'Your secret key is kept only on this phone, in storage the operating system protects. Haven never sends it anywhere: not to any server, not to us.'**
  String get privacyYourKeysSecretStaysHere;

  /// Body paragraph, Privacy → Your two keys.
  ///
  /// In en, this message translates to:
  /// **'Your public key is safe to hand out. It works like a username you can post anywhere. Sharing it cannot reveal where you are.'**
  String get privacyYourKeysPublicIsSafe;

  /// The practical takeaway for Privacy → Your two keys — the one genuinely actionable instruction in this group. 'Settings → Identity → Advanced' is a navigation path: translate the screen names to match those screens' own titles in this locale, and keep the arrows.
  ///
  /// In en, this message translates to:
  /// **'To keep this identity, back it up. Go to Settings → Identity → Advanced, tap Reveal Secret Key, and save it somewhere safe such as a password manager. Without that backup, losing the phone loses the identity for good.'**
  String get privacyYourKeysMeansForYou;

  /// Warning callout, Privacy → Your two keys. This is a limitation the reader can act on, so it is styled as a warning rather than a neutral note. Keep the imperative force in translation.
  ///
  /// In en, this message translates to:
  /// **'Anyone who gets your secret key becomes you. They could join circles as you or publish under your name. Never paste it into another app, a message, or a website.'**
  String get privacyYourKeysNeverShareSecret;

  /// Technical-detail paragraph (collapsed by default), Privacy → Your two keys. 'secp256k1', 'Nostr', 'npub1…' and 'nsec1…' are intentionally English (algorithm name, protocol name, and literal key prefixes users will see verbatim).
  ///
  /// In en, this message translates to:
  /// **'Both keys are secp256k1, shown in the standard Nostr formats: npub1… for the public key and nsec1… for the secret one. Signing happens inside the app, and the secret is cleared from the parts that handle it directly as soon as it is used.'**
  String get privacyYourKeysDetailFormats;

  /// Technical-detail paragraph (collapsed by default), Privacy → Your two keys. Describes MLS/Nostr key separation without naming the protocols. Do NOT strengthen this into a claim that a leaked identity key is harmless.
  ///
  /// In en, this message translates to:
  /// **'The keys that encrypt your circles\' messages are separate from this identity key, and are held only by the app. That separation is deliberate: the key that names you is not the key that unlocks what you sent.'**
  String get privacyYourKeysDetailSeparation;

  /// Title of the Privacy topic covering the public profile. States the conclusion in the title rather than hedging, because a reader who reads nothing else should still learn this.
  ///
  /// In en, this message translates to:
  /// **'Your name and photo are public'**
  String get privacyPublicProfileTitle;

  /// One-line preview shown under the topic title on the Privacy hub.
  ///
  /// In en, this message translates to:
  /// **'Visible to anyone, not just your circles'**
  String get privacyPublicProfileSubtitle;

  /// Body paragraph, Privacy → Your name and photo are public. 'Nostr' is intentionally English (protocol name), though the surrounding sentence is translatable.
  ///
  /// In en, this message translates to:
  /// **'The display name and photo you set are published to Nostr, the open public network Haven runs on. Anyone can look them up, not only the people in your circles.'**
  String get privacyPublicProfileIsPublic;

  /// Body paragraph, Privacy → Your name and photo are public. States that publishing is unconditional — there is deliberately no consent toggle. Do not soften this into 'may be published'.
  ///
  /// In en, this message translates to:
  /// **'Your name and photo go public the moment you save them. There is no setting that keeps them private, and no way to share a name with your circles only.'**
  String get privacyPublicProfileOnSave;

  /// Body paragraph, Privacy → Your name and photo are public. The quoted example “Quiet Wanderer” is intentionally English and MUST be kept verbatim in every locale: the generator's word lists (lib/src/utils/anonymous_name_words.dart) are English ASCII only, so this is literally the kind of name a user of any locale will see pre-filled. Translating it would describe a name the app never generates.
  ///
  /// In en, this message translates to:
  /// **'New installs start with a made-up name such as “Quiet Wanderer”, which says nothing about you. You can keep it, or replace it with whatever you like.'**
  String get privacyPublicProfilePseudonym;

  /// The practical takeaway for Privacy → Your name and photo are public.
  ///
  /// In en, this message translates to:
  /// **'Pick a name and photo you are happy to show in public. If you would rather not be recognised, keep the made-up name you were given and skip the photo.'**
  String get privacyPublicProfileMeansForYou;

  /// Warning callout, Privacy → Your name and photo are public. Factually load-bearing: Haven issues no delete request for the hosted image, so the copy must not imply deletion. Keep 'does not unpublish' unambiguous.
  ///
  /// In en, this message translates to:
  /// **'Removing your photo later does not delete the copy on the server. Haven replaces your profile with an empty one. The image file stays where it is hosted, and any copy already downloaded stays out there. Treat anything you publish as permanent.'**
  String get privacyPublicProfileRemovalIsNotDeletion;

  /// Technical-detail paragraph (collapsed by default), Privacy → Your name and photo are public. 'Nostr', 'kind 0', 'Blossom' and 'blossom.primal.net' are intentionally English (protocol name, event-kind identifier, protocol name, hostname).
  ///
  /// In en, this message translates to:
  /// **'The profile is a Nostr “kind 0” event signed by your identity key. Photos are uploaded to a public image host, blossom.primal.net, which sees the image, your public key, and your network address. Haven does not yet let you choose a different host.'**
  String get privacyPublicProfileDetailKindZero;

  /// Technical-detail paragraph (collapsed by default), Privacy → Your name and photo are public. Describes EXIF/GPS stripping without naming EXIF. 'GPS' is intentionally English (widely-understood initialism).
  ///
  /// In en, this message translates to:
  /// **'Before uploading, Haven re-encodes the picture and drops the hidden data cameras attach, including the GPS position where the photo was taken. That matters here: a holiday snapshot can otherwise carry the coordinates of your home.'**
  String get privacyPublicProfileDetailExifStripped;

  /// Header for the second group of Privacy topics on the hub (relays, how the encryption works, what members and relay operators see).
  ///
  /// In en, this message translates to:
  /// **'How your location travels'**
  String get privacyGroupHowLocationTravelsHeading;

  /// Title of the Privacy topic explaining what a relay is. Front-loaded with the distinguishing word so screen-reader users scanning headings hear it first. 'Relays' is a Nostr term of art — keep it recognizable; do not translate it to a generic word for 'server' unless this locale's file already does so consistently.
  ///
  /// In en, this message translates to:
  /// **'Relays: the servers that pass messages along'**
  String get privacyRelaysTitle;

  /// One-line preview shown under the topic title on the Privacy hub.
  ///
  /// In en, this message translates to:
  /// **'Whose computers your updates pass through'**
  String get privacyRelaysSubtitle;

  /// Body paragraph, Privacy → Relays. Introduces 'relay' with the plain-language handhold BEFORE the term, which is the pattern used throughout this section. Audience: non-technical, no Nostr knowledge.
  ///
  /// In en, this message translates to:
  /// **'Haven has no server of its own, so your updates travel through other people\'s. These are called relays: small, independent servers that anyone can run. A relay holds an encrypted message briefly, then hands it on when your circle asks for it.'**
  String get privacyRelaysWhatIsARelay;

  /// Body paragraph, Privacy → Relays, on why Haven uses more than one relay.
  ///
  /// In en, this message translates to:
  /// **'Haven uses several relays, so no single one can cut you off. If one goes offline, the rest keep working. You choose the relays where invitations reach you; the relays a circle uses are fixed when it is created.'**
  String get privacyRelaysWhyMany;

  /// Body paragraph, Privacy → Relays, explaining the three user-editable relay lists (inbox, KeyPackage, and the local-only profile list) plus the per-circle list. 'KeyPackage' is intentionally English and is deliberately NOT simplified to plain language here: the reader has to find this list on the Relay settings page, which is labelled with that exact term (relaySettingsKeyPackageTitle), so findability outranks register. The sentence itself carries the plain-language gloss. Keep 'inbox relays' matching relaySettingsInboxTitle, and 'profile relays' matching relaySettingsProfileTitle, in this locale. IMPORTANT — do not overstate the guarantee: do not imply that no relay can ever learn a device uses it for the profile plane (a relay that actually serves the profile pool obviously sees that traffic directly, and profile-relay assignment can collide across contacts). What is true, and all this sentence claims, is that Haven never publishes a list naming the profile relays, so a relay outside that pool (e.g. one that only sees your location or invitation traffic) has no public pointer to it. See haven-core/SECURITY.md, 'Profile-plane relay separation — accepted deviations', point P3, for the precise wording to match.
  ///
  /// In en, this message translates to:
  /// **'Haven keeps three lists for you. Your inbox relays are where invitations reach you, and your KeyPackage relays are where people fetch the keys they need in order to invite you — Haven publishes both of these lists so others can find them. Your profile relays are different: that is where your name and photo are looked up and published, but the list itself stays on your device and is never published. A relay that only carries your location traffic or invitations therefore has no public list telling it which relays you use for your profile. Each circle also carries its own list, and that is where the circle\'s encrypted updates travel.'**
  String get privacyRelaysYourLists;

  /// The practical takeaway for Privacy → Relays. Reassuring rather than actionable, deliberately — there is no setting the reader must change. The split in the middle is factually load-bearing: since the profile-plane relay separation (haven-core/SECURITY.md) no single relay sees all three things. The profile pool carries the name and photo; the user's own inbox/KeyPackage relays carry the keys and the published lists, and the two sets are disjoint by construction. An earlier version attributed all three to one relay, which is now false. Do not merge the sentences back together.
  ///
  /// In en, this message translates to:
  /// **'A relay never sees your location, because it is encrypted before it leaves your phone. It does see what has to be public for people to reach you: the keys others need to invite you, and the lists saying which relays to use. Your name and photo are public too, but they go to a separate set of relays. Haven starts you with working relays, so there is nothing you must change.'**
  String get privacyRelaysMeansForYou;

  /// Technical-detail paragraph (collapsed by default), Privacy → Relays. Discloses the unconditional lookups on servers the user never chose, which are not surfaced anywhere else in the app. Do NOT soften 'even if every relay you chose for yourself is private' — that is the point of the paragraph. The two-pool split is factually load-bearing and post-dates an earlier version that described a single 'set of public directory relays': profiles (kind 0) go to the eight-relay profile pool (haven-core/src/profile/relay_pool.rs) and keys go to the six discovery relays (haven-core/src/relay/discovery.rs), and the two sets are disjoint by construction — that disjointness is the whole point of the profile-plane relay separation (haven-core/SECURITY.md). Keep the counts accurate; if a pool changes size, this string changes with it. 'that you do not choose' was challenged as false for the eight, on the grounds that they seed a user-editable RelayType::Profile list (haven-core/src/circle/storage_relay_prefs.rs) with a full add/remove/restore-defaults section in Settings → Relays (relay_settings_page.dart). It was VERIFIED AND KEPT, because removal does not take effect: usable_profile_relays() unions profile_relay_pool_default() back in on every resolution (haven-core/src/circle/storage_contamination.rs), and every fetch and publish path resolves through it, so the only thing that ever drops one of the eight is the contamination ledger. Removing one in Settings shortens the displayed list while Haven keeps contacting it — so 'you can edit the eight' would be a NEW false claim in the dangerous direction. Do not make that edit. The third sentence is what reconciles this paragraph with privacyRelaysYourLists, which correctly calls the profile list user-editable: additions are real, removals of the curated eight are not.
  ///
  /// In en, this message translates to:
  /// **'Separately from your own lists, Haven uses two groups of public servers that you do not choose: eight for looking up other people\'s names and photos, and six for looking up the keys needed to invite them. The two groups never overlap. You can add your own servers to the profile group, but you cannot take these eight out of it. Haven contacts both groups even if every relay you chose for yourself is private, and each of them sees your network address.'**
  String get privacyRelaysDetailIndexers;

  /// Technical-detail paragraph (collapsed by default), Privacy → Relays. Discloses three properties of profile lookups that were previously stated nowhere in the app: one author per request (never a batched roster, which is CI-enforced), a salted per-install assignment that is deliberately NEVER rotated, and that publishing fans out to the whole pool. The never-changing pairing is the honest cost of not rotating the salt (haven-core/SECURITY.md, 'Profile-plane relay separation — accepted deviations', point P5) and must not be presented as a pure benefit — keep the cost sentence alongside the spreading claim. Do NOT strengthen the spreading claim into 'no single server sees everyone you look up': that is a statistical property of a per-install hash, not an invariant, and P1 records that collisions follow the birthday bound (~79% for a five-member roster over eight relays), so for a small circle one server genuinely can be assigned everyone. The final clause of the second sentence exists to say so. The publish fan-out is point P2, and it targets the ENTIRE usable pool, so keep it phrased as every profile relay in use. Two claims here are corrections and must not drift back. (1) An earlier version said Haven 'always asks the same server about the same person' and that the pairing 'never changes'. Both were false: PROFILE_MAX_RELAY_RANK is 2 (haven-core/src/profile/assignment.rs) and assigned_relay_for_attempt walks a retry ladder fed by a persisted miss counter (haven-core/src/circle/storage_profile.rs), so an author whose kind-0 misses — the normal case for a brand-new contact — is asked of a SECOND relay; and because the ranking is rendezvous-hashed over the resolved pool, assignments shift for roughly 1/N of authors whenever the pool changes (resolve_profile_pool subtracts contaminated relays, haven-core/src/profile/relay_pool.rs). State the bound as at most TWO of the eight — that cap is the actual privacy parameter, and understating it as one makes the paragraph read as a stronger guarantee than the code gives. (2) An earlier version said a saved profile 'goes to all eight' unconditionally; the publish uses usable_profile_relays() (haven/rust_builder/src/api.rs, haven-core/src/circle/storage_contamination.rs), which is the curated pool minus the contamination ledger plus the user's own additions. 'the eight' must agree with the count in privacyRelaysDetailIndexers.
  ///
  /// In en, this message translates to:
  /// **'For names and photos, Haven asks about one person at a time. Each person is assigned a server on your device; if that server has nothing for them, Haven tries one more. Looking someone up therefore discloses them to at most two of the eight, never to the whole set. Haven never reshuffles those assignments on its own, though they do shift if the set of servers changes. That spreads your lookups rather than sending them all to one server. Each assigned server still builds a lasting record that your phone keeps asking about someone, and with only a few people, several of them can land on the same server. When you save your own name or photo, it goes to every profile relay you are using — the eight, minus any Haven has excluded, plus any you added — so each of those learns your public key.'**
  String get privacyRelaysDetailProfileLookups;

  /// Technical-detail paragraph (collapsed by default), Privacy → Relays. Warns that following the app's own 'use your own private relay' advice publishes that relay's address. Factually load-bearing — do not weaken to 'may become public'.
  ///
  /// In en, this message translates to:
  /// **'Your KeyPackage-relay list is signed by your identity key and published to the relays already on it. If you add a private relay there, its address becomes public and tied to you. There is no way to keep a relay on that list private.'**
  String get privacyRelaysDetailKeyListIsPublic;

  /// Title of the Privacy topic explaining MLS/Marmot encryption in plain language.
  ///
  /// In en, this message translates to:
  /// **'How the encryption works'**
  String get privacyEncryptionTitle;

  /// One-line preview shown under the topic title on the Privacy hub.
  ///
  /// In en, this message translates to:
  /// **'One key per circle, and what changes when people join or leave'**
  String get privacyEncryptionSubtitle;

  /// Body paragraph, Privacy → How the encryption works. 'MLS' is intentionally English (standard name). Do NOT rewrite this to imply two independent layers of encryption protect message contents — there is one strong layer.
  ///
  /// In en, this message translates to:
  /// **'Your location is encrypted on your phone before it leaves, using an open standard called MLS. Each circle is its own encrypted group with its own keys. Nobody outside a circle can read what is sent inside it: not a relay, not Haven, not another circle you belong to.'**
  String get privacyEncryptionPerCircle;

  /// Body paragraph, Privacy → How the encryption works. This claim is firm and verified: a joiner gets only current-epoch keys and no history is transferred.
  ///
  /// In en, this message translates to:
  /// **'When someone joins, the circle moves to a new key. They can read what is sent after they arrive, and nothing from before it. Haven never sends a new member any past locations.'**
  String get privacyEncryptionWhenSomeoneJoins;

  /// Body paragraph, Privacy → How the encryption works. 'Within a few minutes at most' is deliberate and must not become 'immediately' — the real cutoff waits for the next published update. The important caveat about saved messages follows in privacyEncryptionKeysChangeOnMembership.
  ///
  /// In en, this message translates to:
  /// **'When someone leaves a circle, it moves to another new key. They stop being able to read anything new once the rest of the circle has caught up, usually within a few minutes, longer for anyone who was offline at the time.'**
  String get privacyEncryptionWhenSomeoneLeaves;

  /// Warning callout, Privacy → How the encryption works. THE most factually load-bearing string in the Privacy section. Haven disables periodic key rotation (an owner-accepted deviation documented in haven-core/SECURITY.md), so keys rotate ONLY on membership change and one key covers a whole epoch. Never translate this in a way that implies keys rotate regularly, and never use this locale's term for 'forward secrecy' here.
  ///
  /// In en, this message translates to:
  /// **'Leaving a circle does not take back what its members already saved. Haven changes keys only when someone joins or leaves, never on a timer. So one key can cover weeks of messages, and anything a member saved in that time stays readable to them. They still cannot open anything sent after they left.'**
  String get privacyEncryptionKeysChangeOnMembership;

  /// The practical takeaway for Privacy → How the encryption works, and the actionable consequence of the epoch caveat above.
  ///
  /// In en, this message translates to:
  /// **'Encryption protects you from everyone outside your circles. It cannot protect you from someone who was once inside one. To stop sharing with a particular person, leave the circle you share with them and start a new one without them.'**
  String get privacyEncryptionMeansForYou;

  /// Technical-detail paragraph (collapsed by default), Privacy → How the encryption works. 'MLS (Messaging Layer Security)', 'IETF', 'Nostr' and 'Marmot' are intentionally English (standard, body and protocol names).
  ///
  /// In en, this message translates to:
  /// **'MLS (Messaging Layer Security) is the same IETF standard used by other secure messengers. Haven reaches the Nostr network through the Marmot protocol, which defines how MLS groups travel over relays. The key each circle signs with is separate from your public Nostr identity key.'**
  String get privacyEncryptionDetailMls;

  /// Technical-detail paragraph (collapsed by default), Privacy → How the encryption works. 'epoch' is a term of art; introduce it as the paragraph does rather than replacing it.
  ///
  /// In en, this message translates to:
  /// **'Each key period is called an epoch, and a circle moves to a new one only when its membership changes. Your device keeps the keys for the current epoch and a few recent ones, enough to open messages still arriving, and drops the rest. A circle whose membership has not changed in months is still on the epoch it started on.'**
  String get privacyEncryptionDetailEpochs;

  /// Title of the Privacy topic contrasting what circle members can observe with what relay operators can observe. The two are deliberately on one page so the contrast is unmissable.
  ///
  /// In en, this message translates to:
  /// **'What members see, and what relays see'**
  String get privacyWhatOthersSeeTitle;

  /// One-line preview shown under the topic title on the Privacy hub.
  ///
  /// In en, this message translates to:
  /// **'The people you share with, and the servers in between'**
  String get privacyWhatOthersSeeSubtitle;

  /// Section heading within the Privacy topic, introducing what circle members can observe. Rendered as a navigable screen-reader heading.
  ///
  /// In en, this message translates to:
  /// **'The people in your circles'**
  String get privacyWhatOthersSeeMembersHeading;

  /// Body paragraph, Privacy → What members see. Factually load-bearing: Haven shares full-precision GPS and the obfuscation tiers were removed, so do not imply any approximate mode exists.
  ///
  /// In en, this message translates to:
  /// **'Everyone in a circle sees your exact position on the map, not a rough area. There is no setting that shares a vaguer location with some members and a precise one with others.'**
  String get privacyWhatOthersSeeMembersExact;

  /// Body paragraph, Privacy → What members see. Factually load-bearing and easy to get wrong: only BACKGROUND sharing is toggleable (locationSettingsToggleTitle); foreground sharing is unconditional. Do not imply a pause or ghost mode exists. The second and third sentences carry the same correction as locationSettingsIntro and must stay consistent with it in this locale: an earlier version said the switch governs sharing 'after you close the app', which overstated it — no background wake path publishes, so once the system closes Haven, sharing stops. The per-platform sentence is a SECOND, later correction: the version that carried the first one ended 'sharing stops until you open it again', which is false on Android and false in the dangerous direction, because RebootReceiver (android:enabled="true") plus autoRunOnBoot:true resurrect the publishing foreground service after a reboot with no user action, and nothing sets android:stopWithTask, so it also survives being swiped out of recents. That matters most in THIS paragraph, whose whole subject is how a user stops being seen — someone who swipes Haven away or reboots to stop sharing has not stopped sharing, and the closing Leave Circle sentence is the only advice here that actually works. Keep both platforms named; never flatten them. Match the phrasing this locale already uses in locationSettingsIntro.
  ///
  /// In en, this message translates to:
  /// **'While Haven is open and you are in a circle, your position goes out every couple of minutes on its own. There is no pause button: the switch on the Location page only controls whether that continues while Haven is in the background. If the system closes Haven, sharing stops. On Android, sharing survives swiping Haven away and starts again by itself after a reboot; on iPhone it stays stopped until you open Haven. To stop sharing with a circle, open it and choose Leave Circle.'**
  String get privacyWhatOthersSeeCannotPause;

  /// Body paragraph, Privacy → What members see.
  ///
  /// In en, this message translates to:
  /// **'Joining a circle also shows every member your public key. Through it they can look up your public profile, and anything else you have ever published under that key.'**
  String get privacyWhatOthersSeeMembersLearnKey;

  /// Warning callout, Privacy → What members see. Discloses co-member IP harvesting via an attacker-controlled kind-0 picture URL, which Haven's own source names as a risk and which is disclosed nowhere else in the app. Keep 'without you tapping anything' — the automatic nature is the point.
  ///
  /// In en, this message translates to:
  /// **'Your phone downloads each member\'s profile photo from a server that member chose, without you tapping anything. That server then sees your network address, which places you roughly on the map. A VPN hides this; nothing else does.'**
  String get privacyWhatOthersSeeCoMemberIp;

  /// Section heading within the Privacy topic, introducing what relay operators can observe. Rendered as a navigable screen-reader heading.
  ///
  /// In en, this message translates to:
  /// **'The relay operators'**
  String get privacyWhatOthersSeeRelaysHeading;

  /// Body paragraph, Privacy → What relays see. All four 'cannot' items are verified. The single-use sender address is real (a new key per message) — but note the following paragraph deliberately walks back what it does NOT hide, so do not merge the two.
  ///
  /// In en, this message translates to:
  /// **'Relays, the independent servers your updates pass through, cannot read your location, your messages, your circle\'s name, or its member list. Your location updates carry a fresh, single-use sender address instead of your public key. Your profile, invitations and relay lists do carry it, so a relay handling both can often tell you are in a circle, without reading anything inside.'**
  String get privacyWhatOthersSeeRelaysCannot;

  /// Body paragraph, Privacy → What relays see. The honest counterweight to the previous paragraph. Do not soften: activity timing, message sizes and the per-circle tag are all genuinely observable.
  ///
  /// In en, this message translates to:
  /// **'They do see your network address, when you are online, and how large and how frequent your traffic is. Each circle carries a random tag. A relay can group one circle\'s messages by that tag and estimate how many people are in it, without learning who any of them are.'**
  String get privacyWhatOthersSeeRelaysCan;

  /// The practical takeaway for Privacy → What members see and what relays see. The blunt final sentence is deliberate — it is the one thing on this page a reader must not miss.
  ///
  /// In en, this message translates to:
  /// **'Only join a circle with people you would give your home address to. Encryption holds against relays and outsiders, and a VPN hides the address your phone connects from. Nothing protects you from a member who takes a screenshot.'**
  String get privacyWhatOthersSeeMeansForYou;

  /// Technical-detail paragraph (collapsed by default), Privacy → What members see and what relays see. Describes the stable per-circle routing tag without naming the 'h' tag or the group ID. The second sentence is a correction and must not drift back: an earlier version said the stability was 'a property of the underlying protocol, not something Haven can change', which is false. The Marmot nostr-routing-v1 app component explicitly permits rotation ('an update MAY also change nostr_group_id'), and the pinned MDK v0.9.4 implements it end to end. Haven simply does not rotate — a product choice, not a protocol limit — so the copy must attribute it to Haven. Keep the final clause: rotation is forward-only and does not retract prior correlation.
  ///
  /// In en, this message translates to:
  /// **'A circle\'s tag stays the same for the life of that circle, so a relay can link all of its messages together indefinitely. The protocol does allow a circle to move to a new tag, but Haven does not do that today — and moving would not undo what a relay has already linked.'**
  String get privacyWhatOthersSeeDetailTag;

  /// Shared label for a link that opens the matching Privacy topic for a fuller explanation. Used on the Relay settings, Public key QR and Location settings pages. Keep it short — it sits under a paragraph as a TextButton.
  ///
  /// In en, this message translates to:
  /// **'Learn more'**
  String get commonLearnMore;

  /// Two-sentence caption below the relay lists on the Relay settings page, replacing a much longer explainer that moved to the Privacy section. Keeps just enough framing to make the 'Inbox' and 'KeyPackage' section headers meaningful. 'relay' is a Nostr term of art — match this locale's rendering in privacyRelaysWhatIsARelay.
  ///
  /// In en, this message translates to:
  /// **'Haven has no server of its own. Your encrypted updates pass through independent servers called relays, which cannot read your location or your messages.'**
  String get relaySettingsBackendCaption;

  /// Warning callout, Privacy → What members see. Factually load-bearing and asymmetric: Android sets FLAG_SECURE on every Activity in the process, registered once in HavenApplication.kt (which is what makes 'everywhere in the app' true — it covers the photo-crop screen and any future plugin Activity, not just MainActivity), whereas iOS has no equivalent and only the app-switcher snapshot is blurred (AppDelegate.swift). Do NOT flatten this into a single claim covering both platforms, and never imply iOS blocks in-app screenshots.
  ///
  /// In en, this message translates to:
  /// **'This depends on your phone. On Android, Haven blocks screenshots and screen recording everywhere in the app. On iPhone it cannot: Haven blurs the app-switcher preview, but a member can still capture what is on screen.'**
  String get privacyWhatOthersSeeScreenshots;

  /// Technical-detail paragraph (collapsed by default), Privacy → What members see and what relays see. 'At most' is load-bearing and must survive translation: the window Haven requests is the SMALLER of its own LOCATION_MESSAGE_RETENTION_SECS and whatever the circle's 0x8005 component declares, so a circle created by another Marmot client can be shorter — and the circle-details sheet now displays that shorter window (circleDetailsMetaWithExpiry), which is what made the un-qualified sentence contradict the app. The reason it can be shorter is another app's declaration, never a setting the user can change. Keep 'about four minutes' contiguous: relay_expiry_copy_states_the_retention_window (haven-core/tests/privacy_copy_ties.rs) matches the substring 'drop location messages after about four minutes' against the constant. 'Advisory' is essential — the expiry is a NIP-40 hint a relay may ignore, so never phrase this as a guarantee that messages are deleted. The third sentence discloses a public discriminator that was previously stated nowhere: Haven stamps the expiration on application messages only, while commits and proposals carry the routing tag alone, so its presence or absence separates group-control traffic from location traffic to any observer. Its opening scope clause ('Among the messages your phone sends') is load-bearing and must survive translation as a real restriction, never generalised to every message in the circle: Haven stamps its OWN application messages unconditionally, but it cannot stamp another member's, and in a circle created by a client that declared no retention policy another member's unstamped message may itself be a location update — the unscoped sentence pointed a relay at the wrong conclusion about a real position report. 'membership or settings change' is the whole un-stamped class, which is every group-control message: joins and removals, but also an admin handoff or a change to the circle's relays — do not narrow it back to membership. Phrase the sentence so the thing that is absent is unmistakably the EXPIRY REQUEST — an earlier version ended 'by its absence', where the nearest antecedent was 'a location update', and that misreading turns the sentence into a different and false claim.
  ///
  /// In en, this message translates to:
  /// **'Haven asks relays to drop location messages after about four minutes at most — sooner, in a circle created by another app that asked for less. That request is advisory: a relay is free to keep them for longer. Among the messages your phone sends, only location updates carry that expiry request, so a message without one is visibly a membership or settings change rather than a location update. Invitations carry no expiry at all, and may sit on your inbox relay indefinitely.'**
  String get privacyWhatOthersSeeDetailExpiry;

  /// Technical-detail paragraph (collapsed by default), Privacy → What members see and what relays see. Discloses the on-device retention of other members' coordinates, which the app previously stated only in passing in leaveCircleDialogBody. 'a day' is the fixed 24-hour purge window (LOCATION_RETENTION_SECS, haven-core/src/location/types.rs); it is not configurable and does not follow any hint in the payload, so do not translate it as an approximation or a setting. The second sentence keeps the automatic purge from being read as a guarantee about what a member kept deliberately.
  ///
  /// In en, this message translates to:
  /// **'Each member\'s phone stops showing the last position it received from you after a day, and deletes it the next time they open Haven. That is separate from anything a member chose to save or screenshot themselves, which Haven has no say over.'**
  String get privacyWhatOthersSeeDetailOnDevice;

  /// Technical-detail paragraph (collapsed by default), Privacy → What members see and what relays see. Discloses socket-level correlation, previously undisclosed: a single connection carries both the inbox filter naming the user's OWN public key and every subscribed circle's routing-tag filter (haven-core/src/relay/live_sync/session.rs). The public key here is the reader's own — it is the gift-wrap recipient tag — NOT other members' keys, so do not translate this as though Haven were sending its contacts' keys to a relay. The final sentence matters: the overlap is the default configuration, not a rare misconfiguration, because the inbox and per-circle relay sets both seed from the same defaults.
  ///
  /// In en, this message translates to:
  /// **'Haven opens one connection to each relay and uses it for everything on that relay. Where a relay carries both your invitations and a circle\'s messages, that single connection asks for invitations addressed to your public key and for that circle\'s messages by its tag at the same time, which is what lets the relay tie the two together. On a new install the same relays are used for both.'**
  String get privacyWhatOthersSeeDetailOneConnection;

  /// Header for the third group of Privacy topics on the hub — the honest disclosures about what Haven does not protect. Grouping them under one candid heading is deliberate: it reads as candour, where scattering the same caveats through the reassuring topics would read as hedging.
  ///
  /// In en, this message translates to:
  /// **'The limits'**
  String get privacyGroupTheLimitsHeading;

  /// Title of the Privacy topic on metadata, traffic patterns, IP address and VPNs. Front-loaded with the distinguishing words. Deliberately says 'still' — it follows the topics that explain what IS protected.
  ///
  /// In en, this message translates to:
  /// **'What can still be worked out about you'**
  String get privacyInferenceTitle;

  /// One-line preview shown under the topic title on the Privacy hub.
  ///
  /// In en, this message translates to:
  /// **'The traces encryption cannot cover'**
  String get privacyInferenceSubtitle;

  /// Body paragraph, Privacy → What can still be worked out. Defines 'metadata' at first use, which is the single most misunderstood word in this section — keep the definition, and use this locale's established word for the concept if the app already has one.
  ///
  /// In en, this message translates to:
  /// **'Encryption hides what you send. It cannot hide that you sent something. That leftover trail is called metadata: when a message went out, how big it was, and which servers you were connected to. It stays visible even when the contents do not.'**
  String get privacyInferenceWhatIsMetadata;

  /// Body paragraph, Privacy → What can still be worked out. Discloses that motion-triggered publishes make moving-vs-stationary inferable, which is a real activity-level leak and is disclosed nowhere else in the app. Keep the closing 'That pattern never shows where you are' — it bounds the claim, and it names its subject explicitly because the preceding sentences use 'it' for Haven, so a bare pronoun here collides with that referent when the paragraph is read aloud. The scoping in the second sentence is factually load-bearing and must not be flattened back into an unconditional claim: the motion trigger lives only in the Flutter UI isolate (haven/lib/src/pages/map_shell.dart, gated on kMotionTriggerDistanceMeters and rate-limited by kLocationPublishOverlapGuard), so it exists in the foreground on both platforms and on iOS while background sharing keeps the process alive, but NOT in the Android background service, which is a plain timer with no awareness of movement at all. 'at most once a minute' states the rate limit and bounds the leak — keep it.
  ///
  /// In en, this message translates to:
  /// **'From that pattern, a relay you use can tell roughly when you are active and how often. While Haven is on screen — and on iPhone, while background sharing keeps it running — it also sends an extra update, at most once a minute, whenever you move about a hundred metres. Over hours, that can show a relay whether you were on the move or staying put. That pattern never shows where you are.'**
  String get privacyInferenceActivityPattern;

  /// Body paragraph, Privacy → What can still be worked out. Discloses the continuous online-presence signal created by the live connection, and names the benefit it buys so the disclosure is not merely alarming.
  ///
  /// In en, this message translates to:
  /// **'While Haven is running it keeps an open connection to your relays. They can see that you are online, and which circle tags you are following, never a circle\'s name or who is in it. That is the price of updates arriving in seconds rather than minutes.'**
  String get privacyInferencePresence;

  /// Section heading within the Privacy topic, introducing IP-address exposure. Rendered as a navigable screen-reader heading. Prefer this locale's plain-language phrase over the initialism 'IP' if one reads naturally.
  ///
  /// In en, this message translates to:
  /// **'Your network address'**
  String get privacyInferenceIpHeading;

  /// Body paragraph, Privacy → What can still be worked out. Names all three classes of server that observe the user's address, including the photo host — an earlier version of this disclosure named only relays and the map provider, which was incomplete.
  ///
  /// In en, this message translates to:
  /// **'Every server Haven talks to sees the address your phone connects from, its IP address: your relays, the map provider, and whoever hosts a member\'s profile photo. Your internet provider sees which of those servers you reached, and when. Haven does nothing to hide either of those on its own.'**
  String get privacyInferenceIpAddress;

  /// Heading in Privacy > What can be inferred, introducing what the map provider learns.
  ///
  /// In en, this message translates to:
  /// **'The map itself'**
  String get privacyInferenceMapTilesHeading;

  /// Privacy > What can be inferred: discloses that map tiles are fetched from the map provider around BOTH the user's and other members' positions, that tiles are prefetched ahead of viewing, and the on-device cache retention. Must not overstate: the provider sees tile coordinates, not identities, and Haven never sends it a member list. The final clause must name IDENTITY DELETION, not logout — Haven has no login/logout; the tile wipe runs inside NostrIdentityService.deleteIdentity().
  ///
  /// In en, this message translates to:
  /// **'Drawing the map asks the map provider for the squares of imagery on screen, so it learns roughly which places you look at. Haven also fetches a small area around each member you can see before you scroll there, so the map is ready — which means the provider can learn roughly where your circle is, not only where you are looking. Those squares are kept in an encrypted cache on your phone for up to seven days, and are cleared if you delete your identity.'**
  String get privacyInferenceMapTiles;

  /// Section heading within the Privacy topic, introducing the VPN recommendation. Rendered as a navigable screen-reader heading. 'VPN' is intentionally English (widely-understood initialism).
  ///
  /// In en, this message translates to:
  /// **'Whether to use a VPN'**
  String get privacyInferenceVpnHeading;

  /// Body paragraph, Privacy → What can still be worked out. 'VPN' and 'Mullvad' are intentionally English (initialism and brand name).
  ///
  /// In en, this message translates to:
  /// **'A VPN replaces your address with its own, so relays and the other servers no longer see where you connect from. It also hides which servers you reach from your internet provider. We recommend Mullvad.'**
  String get privacyInferenceVpnHelps;

  /// Body paragraph, Privacy → What can still be worked out. All three limits are real and must survive translation: members are unaffected, traffic analysis by the relay is unaffected, and trust is shifted rather than eliminated.
  ///
  /// In en, this message translates to:
  /// **'It is not a cure-all. A VPN changes nothing about what your circle members see, and it does not hide the timing or size of your traffic from a relay you are talking to. It also moves your trust to the VPN company rather than removing the need to trust anyone.'**
  String get privacyInferenceVpnLimits;

  /// The practical takeaway for Privacy → What can still be worked out. Deliberately splits the advice by threat model rather than giving one blanket recommendation.
  ///
  /// In en, this message translates to:
  /// **'Worried about relays, your internet provider, or the map servers placing you on a map? A VPN is the single most useful thing you can add. Worried about the people in your circles? It will not help at all.'**
  String get privacyInferenceMeansForYou;

  /// Technical-detail paragraph (collapsed by default), Privacy → What can still be worked out. Honest about the limits of the jitter defence: it defeats short-window fingerprinting but not long-run averaging. Do not present the jitter as defeating traffic analysis outright.
  ///
  /// In en, this message translates to:
  /// **'Haven varies the gap between updates on purpose, so a short recording shows no clean rhythm. Averaged over many hours the underlying rate can still be estimated. Message sizes are not padded either, and location updates fall in a narrow size range, which makes them recognisable as location updates.'**
  String get privacyInferenceDetailJitter;

  /// Technical-detail paragraph (collapsed by default), Privacy → What can still be worked out. States the threat model's boundary plainly rather than leaving the reader to assume total coverage.
  ///
  /// In en, this message translates to:
  /// **'Two things are beyond any design choice here: an observer who can watch many relays at once, and your own phone once someone else controls it.'**
  String get privacyInferenceDetailOutOfScope;

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

  /// Snackbar shown when a scanned member is already in the selected list.
  ///
  /// In en, this message translates to:
  /// **'Member already added'**
  String get createCircleMemberAlreadyAdded;

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

  /// Subtitle/badge shown for a member whose circle invitation has not yet been accepted.
  ///
  /// In en, this message translates to:
  /// **'Invitation Pending'**
  String get circleMemberInvitationPending;

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

  /// Accessibility hint appended to a member's name when their invitation is pending.
  ///
  /// In en, this message translates to:
  /// **'invitation pending'**
  String get circleMemberHintPending;

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

  /// Tooltip on the button that drops someone from the staged list of people you are about to invite, BEFORE any invitation is sent. Deliberately not "Remove member": Haven ships no way to remove an existing member from a circle, and the Privacy section tells users the remedy is to leave the circle instead. This label must not be readable as circle-member removal.
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

  /// Indicator shown after the visible member chips for the remaining members, e.g. '+2 more'.
  ///
  /// In en, this message translates to:
  /// **'+{count} more'**
  String selectedMembersMore(int count);

  /// Status badge label for a member with a pending circle invitation.
  ///
  /// In en, this message translates to:
  /// **'Invitation Pending'**
  String get invitationStatusPending;

  /// Status badge label for an active (accepted) member.
  ///
  /// In en, this message translates to:
  /// **'Active'**
  String get invitationStatusActive;

  /// Status badge label for a member who declined the invitation.
  ///
  /// In en, this message translates to:
  /// **'Declined'**
  String get invitationStatusDeclined;

  /// Accessibility label announcing a member's invitation status. {label} is one of the status labels.
  ///
  /// In en, this message translates to:
  /// **'Invitation status: {label}'**
  String invitationStatusSemantics(String label);

  /// Accessibility label summarizing an invitation card. {circleName} is the circle name, {inviter} is a truncated public key, {count} is the member count (always shown with the plural noun 'members', matching the original copy).
  ///
  /// In en, this message translates to:
  /// **'Invitation to join {circleName}, invited by {inviter}, {count} members'**
  String invitationCardSemantics(String circleName, String inviter, int count);

  /// Accessibility label for the inviter row of an invitation card. {inviter} is a truncated public key.
  ///
  /// In en, this message translates to:
  /// **'Invited by cryptographic identifier {inviter}'**
  String invitationCardInvitedBySemantics(String inviter);

  /// Visible inviter line on an invitation card. {inviter} is a truncated public key.
  ///
  /// In en, this message translates to:
  /// **'Invited by: {inviter}'**
  String invitationCardInvitedBy(String inviter);

  /// Member-count line on an invitation card.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 member} other{{count} members}}'**
  String invitationCardMemberCount(int count);

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

  /// Appends the relay-expiry window to the circle-details subtitle, e.g. '3 members · epoch 14 · expiry 4 min'. {meta} is the already-composed member count (with the epoch, when there is one) and must be inserted untouched; {expiry} is the compact duration (circleDetailsExpiryMinutesShort / circleDetailsExpirySecondsShort). Space is the whole point of this segment: for almost every circle it reads '4 min' forever, so it must stay a couple of words on the dimmest line, never a row or a label of its own. 'expiry' is the same term privacyWhatOthersSeeDetailExpiry uses ('that expiry request') — reuse whatever word that paragraph uses in your language. Do NOT translate it as a promise that messages are deleted, and do NOT make it read as though the CIRCLE expires; what expires is the location message. Reorder freely (a language that wants the duration first can write '{expiry} ... {meta}') and change the separator to whatever punctuation reads naturally, but keep it short enough to sit on one dim line.
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

  /// Spelled-out minutes duration read by screen readers inside circleDetailsExpirySemantics, e.g. 'about 4 minutes'. Never displayed. 'about' is required and must survive translation: the number is rounded to the nearest minute (Haven's own window is 228 seconds, which is what makes the usual reading 'about 4 minutes', matching privacyWhatOthersSeeDetailExpiry). Spell the unit out in full — an abbreviation is what this key exists to avoid. These are consumed at exactly ONE call site, inside circleDetailsExpirySemantics, so a language whose carrier sentence governs the duration may fold the preposition or case into this string rather than leave it stranded (ru does: it carries 'через' and the accusative, and its semantics string has no preposition). Do not 'restore' the English shape there.
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

  /// Button on the legacy-circle banner that starts creating a new circle, pre-filled with the old circle's name.
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

  /// Snackbar confirming a labelled key (e.g. 'Public Key') was copied to the clipboard from the KeyDisplay widget.
  ///
  /// In en, this message translates to:
  /// **'{label} copied to clipboard'**
  String keyDisplayCopiedToClipboard(String label);

  /// Accessibility label for the KeyDisplay container, naming the key and whether it is revealed or hidden.
  ///
  /// In en, this message translates to:
  /// **'{label}: {state}'**
  String keyDisplaySemantics(String label, String state);

  /// Accessibility state word used in the KeyDisplay semantics label when the key is fully shown.
  ///
  /// In en, this message translates to:
  /// **'revealed'**
  String get keyDisplayStateRevealed;

  /// Accessibility state word used in the KeyDisplay semantics label when the key is truncated.
  ///
  /// In en, this message translates to:
  /// **'hidden'**
  String get keyDisplayStateHidden;

  /// Tooltip on the KeyDisplay button that re-truncates a revealed key.
  ///
  /// In en, this message translates to:
  /// **'Hide'**
  String get keyDisplayHideTooltip;

  /// Tooltip on the KeyDisplay button that reveals the full key.
  ///
  /// In en, this message translates to:
  /// **'Reveal'**
  String get keyDisplayRevealTooltip;

  /// Tooltip on the KeyDisplay button that copies the key to the clipboard.
  ///
  /// In en, this message translates to:
  /// **'Copy'**
  String get keyDisplayCopyTooltip;

  /// Snackbar confirming a key was copied from the CompactKeyDisplay widget.
  ///
  /// In en, this message translates to:
  /// **'Key copied to clipboard'**
  String get keyDisplayCompactCopied;

  /// Tooltip on the CompactKeyDisplay row inviting the user to tap and copy the key.
  ///
  /// In en, this message translates to:
  /// **'Tap to copy'**
  String get keyDisplayCompactTapToCopy;

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

  /// Snackbar confirming the new profile photo was saved and shared. The em dash separates the two clauses. Updated for the public-profile migration: the photo is now published publicly (Blossom-hosted), not end-to-end encrypted within circles (docs/PUBLIC_PROFILE_MIGRATION_PLAN.md §6.5).
  ///
  /// In en, this message translates to:
  /// **'Photo updated. Published to your public Nostr profile.'**
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

  /// Banner body when several independent circle members consistently report times ahead of this device (a clock running slow). Crucially this fault is INVISIBLE: the send succeeds and the data is then discarded, so the wording must convey 'sent but wasted', and MUST NEVER imply the send failed — that is the distinction from clockSkewBodyRejected, and the two bodies must not be merged. 'Expire' refers to a short time-to-live carried on each location update. Same remedy sentence as clockSkewBodyRejected; keep it identical in your locale so the fix reads the same in both faults.
  ///
  /// In en, this message translates to:
  /// **'This phone is running behind the rest of your circles, so the locations it sends expire before anyone can see them. Turn on automatic date and time in system settings to fix it.'**
  String get clockSkewBodyBehind;

  /// Screen-reader announcement spoken once when the clock warning clears. A live region announces its appearance but never its removal, so this is the only signal a screen-reader user gets that sharing recovered. 'Haven' is the app name and is never translated.
  ///
  /// In en, this message translates to:
  /// **'The clock problem is gone. Haven is sharing your location again.'**
  String get clockSkewResolvedAnnouncement;

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
