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
  /// **'Haven has no central server. Your encrypted messages travel through a decentralized network of relays that you can choose yourself, so no single entity can shut it down.'**
  String get onboardingValueProp2Body;

  /// Headline of the third onboarding value-prop card (also reused on the About page).
  ///
  /// In en, this message translates to:
  /// **'No account needed'**
  String get onboardingValueProp3Title;

  /// Body of the third onboarding value-prop card (also reused on the About page).
  ///
  /// In en, this message translates to:
  /// **'No email, no phone number, no sign-up. Haven creates a private identity that lives only on your phone, with nothing linking it to the real you.'**
  String get onboardingValueProp3Body;

  /// Short one-line summary of the first value prop, shown under its title on the onboarding intro screen. The longer onboardingValueProp1Body is shown on the About page instead. Keep it to roughly one short sentence so the intro screen fits without scrolling.
  ///
  /// In en, this message translates to:
  /// **'Encrypted on your device, so only the circles you choose can read it.'**
  String get onboardingValueProp1Summary;

  /// Short one-line summary of the second value prop, shown under its title on the onboarding intro screen. Keep it to roughly one short sentence so the intro screen fits without scrolling.
  ///
  /// In en, this message translates to:
  /// **'No central server — it runs on a relay network you choose.'**
  String get onboardingValueProp2Summary;

  /// Short one-line summary of the third value prop, shown under its title on the onboarding intro screen. Keep it to roughly one short sentence so the intro screen fits without scrolling.
  ///
  /// In en, this message translates to:
  /// **'No email, phone, or sign-up. Nothing links it to you.'**
  String get onboardingValueProp3Summary;

  /// Title of the onboarding create-identity screen.
  ///
  /// In en, this message translates to:
  /// **'Create your identity'**
  String get onboardingCreateIdentityTitle;

  /// Body explaining what happens when an identity is created on the onboarding create-identity screen.
  ///
  /// In en, this message translates to:
  /// **'Haven will create a private identity that lives only on this phone. It’s how your circles recognise you.'**
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
  /// **'kind 10050, where invitations reach you'**
  String get relaySettingsInboxSubtitle;

  /// Heading of the KeyPackage relays section on the relay settings page.
  ///
  /// In en, this message translates to:
  /// **'My KeyPackage Relays'**
  String get relaySettingsKeyPackageTitle;

  /// Subtitle of the KeyPackage relays section. 'kind 10051' is a Nostr event-kind identifier, intentionally English (not translated).
  ///
  /// In en, this message translates to:
  /// **'kind 10051, where invitees discover your encryption keys'**
  String get relaySettingsKeyPackageSubtitle;

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

  /// Accessibility container label for the footer note explaining how Haven's relay backend works.
  ///
  /// In en, this message translates to:
  /// **'How Haven relays work'**
  String get relaySettingsExplainerSemantics;

  /// Heading of the footer note explaining how Haven's relay backend works.
  ///
  /// In en, this message translates to:
  /// **'How this works'**
  String get relaySettingsExplainerHeading;

  /// First paragraph of the relay backend explainer note. 'Nostr' is a protocol name, intentionally English (not translated).
  ///
  /// In en, this message translates to:
  /// **'Haven has no central server. It runs on two open technologies. Nostr is a network of independent servers called relays that anyone can run; they receive your messages, hold them briefly, and hand them on when your contacts ask. No single relay is essential, so if one goes offline the others keep working, and anything a relay could be forced to hand over is only ever encrypted data.'**
  String get relaySettingsExplainerNostr;

  /// Second paragraph of the relay backend explainer note. 'Marmot' and 'MLS (Messaging Layer Security)' are protocol/standard names, intentionally English.
  ///
  /// In en, this message translates to:
  /// **'The Marmot protocol encrypts your messages on your device before they leave it, using the MLS (Messaging Layer Security) standard. Each circle is its own encrypted group with its own keys, so separate circles cannot be linked together. Those keys also keep advancing over time, a property called forward secrecy, so even a key exposed later cannot unlock your earlier messages.'**
  String get relaySettingsExplainerMarmot;

  /// Third paragraph of the relay backend explainer note, on what metadata a relay can still observe.
  ///
  /// In en, this message translates to:
  /// **'Because of this, a relay never sees your location, your messages, who is in your circles, or your identity on those messages. Each message is published from a fresh, single-use sending address, so nothing in the message ties it to your account. A relay still sees some metadata, though: a random per-circle tag, the timing and size of your traffic, and the network address you connect from.'**
  String get relaySettingsExplainerMetadata;

  /// Bold lead-in term for the Inbox-relays explainer sentence.
  ///
  /// In en, this message translates to:
  /// **'Inbox relays'**
  String get relaySettingsExplainerInboxTerm;

  /// Explainer sentence following the bold 'Inbox relays' term. Begins with a leading space so it joins the bold term inline.
  ///
  /// In en, this message translates to:
  /// **' are your mailbox: where invitations to join a circle, themselves encrypted, are delivered for you to collect. For someone to invite you, they must be able to reach one of these relays.'**
  String get relaySettingsExplainerInboxBody;

  /// Bold lead-in term for the KeyPackage-relays explainer sentence.
  ///
  /// In en, this message translates to:
  /// **'KeyPackage relays'**
  String get relaySettingsExplainerKeyPackageTerm;

  /// Explainer sentence following the bold 'KeyPackage relays' term. Begins with a leading space so it joins the bold term inline.
  ///
  /// In en, this message translates to:
  /// **' are where you publish a small bundle of your public keys, which is safe to share. Someone who knows your account fetches it from these relays to add you to a circle.'**
  String get relaySettingsExplainerKeyPackageBody;

  /// Bold lead-in term for the run-your-own-relay explainer sentence.
  ///
  /// In en, this message translates to:
  /// **'Using your own relay.'**
  String get relaySettingsExplainerOwnRelayTerm;

  /// Explainer sentence following the bold 'Using your own relay.' term. Begins with a leading space so it joins the bold term inline.
  ///
  /// In en, this message translates to:
  /// **' Each circle also carries its own relay list, shared with every member when they join; that list, not your inbox, is where the circle’s ongoing encrypted updates travel. So if you would rather avoid public relays, you can run your own and point a circle at it: once everyone has joined, that circle’s traffic can flow through it alone.'**
  String get relaySettingsExplainerOwnRelayBody;

  /// Bold lead-in term for the reachability-tradeoff explainer sentence.
  ///
  /// In en, this message translates to:
  /// **'The catch is reachability.'**
  String get relaySettingsExplainerReachabilityTerm;

  /// Explainer sentence following the bold 'The catch is reachability.' term. Begins with a leading space so it joins the bold term inline.
  ///
  /// In en, this message translates to:
  /// **' Every member must be able to connect to that relay, and when you first invite someone, the two of you need a relay you can both reach (for example, the same private relay listed as everyone’s inbox and KeyPackage relay). A private relay still sees the same encrypted traffic and timing as any other; you simply control who runs it.'**
  String get relaySettingsExplainerReachabilityBody;

  /// Closing paragraph of the relay backend explainer note.
  ///
  /// In en, this message translates to:
  /// **'You can add or remove relays in either list at any time. More relays make you easier to reach; fewer give you more control over where your encrypted traffic goes.'**
  String get relaySettingsExplainerFooter;

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

  /// Framing paragraph at the top of the location settings page.
  ///
  /// In en, this message translates to:
  /// **'When background sharing is on, your circles keep seeing your live location even when Haven is closed.'**
  String get locationSettingsIntro;

  /// Title of the background-sharing toggle tile.
  ///
  /// In en, this message translates to:
  /// **'Share in background'**
  String get locationSettingsToggleTitle;

  /// Subtitle of the background-sharing toggle tile.
  ///
  /// In en, this message translates to:
  /// **'Keep sharing when the app is closed'**
  String get locationSettingsToggleSubtitle;

  /// iOS-only note shown when background sharing is on but the location permission is only 'while in use'.
  ///
  /// In en, this message translates to:
  /// **'Limited in background. Set Location to \'Always\' for Haven in Settings'**
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

  /// iOS-only reliability guidance about setting Location permission to 'Always'.
  ///
  /// In en, this message translates to:
  /// **'For continuous background sharing, set Location to \"Always\" for Haven in Settings. iOS shows a blue status-bar indicator while an app is using your location in the background.'**
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

  /// Heading of the 'who can see what' disclosure section on the About page.
  ///
  /// In en, this message translates to:
  /// **'Who can see what'**
  String get aboutWhoCanSeeTitle;

  /// Intro paragraph of the 'who can see what' disclosure section.
  ///
  /// In en, this message translates to:
  /// **'Your exact location is readable only by the people you choose. Here is what the main parties can and cannot see.'**
  String get aboutWhoCanSeeIntro;

  /// Bold actor name: circle members you share your location with.
  ///
  /// In en, this message translates to:
  /// **'Circle members you share with'**
  String get aboutActorCirclesWho;

  /// What circle members can observe, in the 'who can see what' list.
  ///
  /// In en, this message translates to:
  /// **'Your exact location and the display name you pick, but only inside the circles you share with them, never your other circles.'**
  String get aboutActorCirclesSees;

  /// Bold actor name: the operators of the relay servers.
  ///
  /// In en, this message translates to:
  /// **'Relay operators'**
  String get aboutActorRelaysWho;

  /// What relay operators can observe, in the 'who can see what' list.
  ///
  /// In en, this message translates to:
  /// **'The servers that pass your messages along. They see your IP address, the public key you publish under (a random ID, not your name), the size and timing of your traffic, and which account you searched for when you look someone up. They can never read your location, your messages, your circle names, or who is in your circles.'**
  String get aboutActorRelaysSees;

  /// Bold actor name: the map tile provider. 'Stadia Maps' is intentionally English (brand name).
  ///
  /// In en, this message translates to:
  /// **'The map provider (Stadia Maps)'**
  String get aboutActorMapWho;

  /// What the map provider can observe, in the 'who can see what' list. 'Stadia' is intentionally English (brand name).
  ///
  /// In en, this message translates to:
  /// **'Only while the map is open: your IP address and the area you are viewing, so it can send the right map images. Never your circles or your shared location. Stadia anonymizes IP addresses and does not sell your data.'**
  String get aboutActorMapSees;

  /// Bold actor name: Haven's developers.
  ///
  /// In en, this message translates to:
  /// **'Haven’s developers'**
  String get aboutActorDevelopersWho;

  /// What Haven's developers can observe, in the 'who can see what' list.
  ///
  /// In en, this message translates to:
  /// **'Nothing. Haven runs no servers and collects no analytics. A developer could only see what a relay operator sees, and only if you used a relay they happen to run.'**
  String get aboutActorDevelopersSees;

  /// Closing metadata caveat after the 'who can see what' actor list.
  ///
  /// In en, this message translates to:
  /// **'Even so, your activity is not invisible. A relay you use, or anyone watching your network, can tell that you are active, roughly when, and how often, from connection timing and message sizes.'**
  String get aboutWhoCanSeeMetadataNote;

  /// Heading of the screenshot-protection paragraph on the About page.
  ///
  /// In en, this message translates to:
  /// **'Screenshot protection'**
  String get aboutScreenshotTitle;

  /// Body of the screenshot-protection paragraph. 'Android' and 'FLAG_SECURE' are intentionally English (platform/API names).
  ///
  /// In en, this message translates to:
  /// **'On Android, Haven blocks screenshots and screen recording app-wide to prevent accidental location exposure. This is a system-level protection (FLAG_SECURE) that applies to every screen in the app, including the map and member lists.'**
  String get aboutScreenshotBody;

  /// Heading of the VPN-recommendation paragraph on the About page.
  ///
  /// In en, this message translates to:
  /// **'Stay more private with a VPN'**
  String get aboutVpnTitle;

  /// Body of the VPN-recommendation paragraph. 'Mullvad' is intentionally English (brand name).
  ///
  /// In en, this message translates to:
  /// **'Relays and the map provider see your IP address, and your internet provider sees which servers you reach. A trusted VPN hides your IP address from them. We recommend Mullvad. It does not change what your circle members see, and it shifts trust to the VPN provider.'**
  String get aboutVpnBody;

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
  /// **'No Haven account found'**
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
  /// **'Everyone in this circle can see each other’s location and display name. Your display name is the one you set in Settings → Identity. This circle stays separate from any others you’re in, so its members can’t see your other circles or who’s in them.'**
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
  /// **'New members can see this circle\'s encrypted locations once they accept the invitation.'**
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

  /// Tooltip on the admin button that removes a member from the circle.
  ///
  /// In en, this message translates to:
  /// **'Remove from circle'**
  String get circleMemberRemoveTooltip;

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

  /// Tooltip on the button that removes a pending member from the selection.
  ///
  /// In en, this message translates to:
  /// **'Remove member'**
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

  /// Explanatory note under the relay list in the circle-details sheet.
  ///
  /// In en, this message translates to:
  /// **'These relays were chosen when this circle was created and are not user-editable yet. Independent from your personal relay settings.'**
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
  /// **'Are you sure you want to leave this circle? You will no longer receive location updates from its members. This action cannot be undone.'**
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

  /// Informational note shown only to a circle's admin, directly below the Leave Circle button in the circle-details sheet. Explains that MDK's current public API exposes no admin-policy component codec (mdk#755), so Haven cannot yet support admin hand-off or self-demotion: an admin can only leave once every other member already has (the sole-remaining-member 'abandon' path still works). Temporary, upstream-blocked limitation; never shown to non-admin members.
  ///
  /// In en, this message translates to:
  /// **'As this circle\'s admin, you can only leave once every other member has left. We know that\'s inconvenient — a future update will let admins hand off and leave directly.'**
  String get leaveCircleAdminLimitationNote;

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
  /// **'Haven’s encryption engine was upgraded, so this circle can no longer be used. Re-create it to keep sharing locations with the same people — you’ll need to invite them again.'**
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
  /// **'Your identity and public profile are unchanged — there is nothing you need to do for those.'**
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
  /// **'Haven is still cleaning up some data from the recent security update. This will finish automatically once you’re back online.'**
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

  /// Body of the delete-identity confirmation dialog. 'secret key' is the nsec; preserve this exact warning wording.
  ///
  /// In en, this message translates to:
  /// **'This will permanently delete your identity. Make sure you have backed up your secret key if you want to recover it.'**
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
  /// **'Your public key works like a username that is safe to share. People scan this code, or paste your public key, to invite you to a circle. Sharing it cannot reveal your location, which is only visible to members of circles you\'ve joined, nor your name and photo, which stay on this device unless you choose to publish a public profile.'**
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
  /// **'This removes your photo from your public profile.'**
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
  /// **'Photo updated — published to your public Nostr profile.'**
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

  /// Compact age pill on a member marker for hours, e.g. '3h'. The 'h' suffix is intentionally English (a compact time abbreviation).
  ///
  /// In en, this message translates to:
  /// **'{count}h'**
  String memberMarkerHoursShort(int count);

  /// Compact age pill on a member marker for days, e.g. '2d'. The 'd' suffix is intentionally English (a compact time abbreviation).
  ///
  /// In en, this message translates to:
  /// **'{count}d'**
  String memberMarkerDaysShort(int count);

  /// Expanded last-seen age, in minutes, read by screen readers for a member marker.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 minute ago} other{{count} minutes ago}}'**
  String memberMarkerMinutesAgoSemantics(int count);

  /// Expanded last-seen age, in hours, read by screen readers for a member marker.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 hour ago} other{{count} hours ago}}'**
  String memberMarkerHoursAgoSemantics(int count);

  /// Expanded last-seen age, in days, read by screen readers for a member marker.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 day ago} other{{count} days ago}}'**
  String memberMarkerDaysAgoSemantics(int count);

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
