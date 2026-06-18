/// User-facing copy for the first-run onboarding flow.
///
/// Centralising strings here keeps the screens terse and makes later
/// extraction to ARB (via the `intl` dependency) mechanical. No variables
/// or pluralisation live here — any parameterised copy should be added as
/// a `String Function(...)` on [OnboardingStrings] rather than composed at
/// the call site, so translators see the full sentence.
///
/// # Tone rules
///
/// - Plain, confident, second person ("you"); active voice.
/// - Concrete security terms that make the guarantee verifiable ARE allowed
///   and encouraged: "encrypted" / "on-device encryption", "open source",
///   "decentralized", "relays", "public key".
/// - Still avoid deep protocol jargon that doesn't help a user reason about
///   their own privacy: "MLS", "Nostr", "nsec", "key package", "signature",
///   "bech32", "gift wrap", "epoch".
library;

/// All user-facing strings for the onboarding flow.
abstract final class OnboardingStrings {
  // ---------------------------------------------------------------------------
  // Shared
  // ---------------------------------------------------------------------------

  /// Accessible name for the step-indicator ("Step 2 of 5").
  ///
  /// Announced on each screen transition via
  /// `SemanticsService.sendAnnouncement`.
  static String stepOf(int current, int total) => 'Step $current of $total';

  /// Label for the back button present on every screen except the first.
  static const String back = 'Back';

  // ---------------------------------------------------------------------------
  // Welcome screen
  // ---------------------------------------------------------------------------

  /// App name as it appears in the hero.
  static const String appName = 'Haven';

  /// Hero subtitle beneath the app name.
  ///
  /// [welcomeHeadlineEmphasis] is rendered in bold at the call site and must
  /// stay an exact substring of this sentence.
  static const String welcomeHeadline =
      'Share your location privately, only with those you want.';

  /// The single word emphasised (bold) within [welcomeHeadline].
  static const String welcomeHeadlineEmphasis = 'only';

  /// Primary CTA on the welcome screen.
  static const String welcomeCta = 'Get Started';

  // ---------------------------------------------------------------------------
  // Value props screen
  // ---------------------------------------------------------------------------

  /// Screen title.
  static const String valuePropsTitle = 'What makes Haven different';

  /// Card 1 headline.
  static const String valueProp1Title = 'Only your circles can see you';

  /// Card 1 body.
  static const String valueProp1Body =
      'Your location is encrypted on your device before it leaves, so only '
      'the circles you choose can read it, never Haven or anyone else. Because '
      'Haven is open source, anyone can verify that.';

  /// Card 2 headline.
  static const String valueProp2Title = 'No one can shut it down';

  /// Card 2 body.
  static const String valueProp2Body =
      'Haven has no central server. Your encrypted messages travel through a '
      'decentralized network of relays that you can choose yourself, so no '
      'company or government can shut it down.';

  /// Card 3 headline.
  static const String valueProp3Title = 'No account needed';

  /// Card 3 body.
  static const String valueProp3Body =
      'No email, no phone number, no sign-up. Haven creates a private identity '
      'that lives only on your phone, with nothing linking it to the real you.';

  /// Primary CTA for value-props screen.
  static const String valuePropsCta = 'Continue';

  // ---------------------------------------------------------------------------
  // Age-gate screen
  // ---------------------------------------------------------------------------

  /// Screen title.
  static const String ageGateTitle = 'How old are you?';

  /// Body explaining the minimum age in plain language.
  static const String ageGateBody =
      'Haven is built for people aged 13 and up. '
      'Please confirm you meet the minimum age to continue.';

  /// Primary CTA confirming the user meets the minimum age.
  static const String ageGateConfirmCta = 'I’m 13 or older';

  /// Secondary CTA for users below the minimum age.
  static const String ageGateUnderCta = 'I’m under 13';

  /// Title of the polite "not available yet" dialog for under-13 users.
  static const String ageGateUnderTitle = 'Haven isn’t available yet';

  /// Body of the under-13 dialog.
  static const String ageGateUnderBody =
      'You need to be at least 13 to use Haven. '
      'Thanks for stopping by. Come back when you’re old enough!';

  /// Dismiss button for the under-13 dialog.
  static const String ageGateUnderDismiss = 'OK';

  // ---------------------------------------------------------------------------
  // Create identity screen
  // ---------------------------------------------------------------------------

  /// Screen title.
  static const String createIdentityTitle = 'Create your identity';

  /// Body explaining what happens and the stakes.
  static const String createIdentityBody =
      'Haven will create a private identity that lives only on this phone. '
      'It\u2019s how your circles recognise you.';

  /// The critical warning the user must understand.
  static const String createIdentityWarning =
      'If you lose this phone or delete the app, your identity is gone. '
      'Haven has no way to recover it for you.';

  /// Primary CTA.
  static const String createIdentityCta = 'Create My Identity';

  /// Loading label while the keypair is being generated.
  static const String createIdentityLoading = 'Setting things up\u2026';

  /// Secondary affordance text inviting import.
  static const String createIdentityImportPrompt = 'Already have a key?';

  /// Link text that navigates to the import screen.
  static const String createIdentityImportLink = 'Import it instead';

  /// Snackbar message on creation failure.
  static const String createIdentityError =
      'Something went wrong creating your identity. Please try again.';

  // ---------------------------------------------------------------------------
  // Import nsec screen
  // ---------------------------------------------------------------------------

  /// Screen title.
  static const String importTitle = 'Import your existing key';

  /// Helper text explaining the expected format without jargon.
  static const String importBody =
      'Paste the secret key you backed up from another Haven-compatible app.';

  /// Text-field hint.
  static const String importHint = 'nsec1\u2026';

  /// Primary CTA.
  static const String importCta = 'Import';

  /// Loading label during import.
  static const String importLoading = 'Importing\u2026';

  /// Validation error when the input doesn't look like an nsec.
  static const String importInvalid =
      'That doesn\u2019t look like a valid backup key. '
      'Please check and try again.';

  /// Generic error on import failure.
  static const String importError =
      'We couldn\u2019t import that key. Please check and try again.';

  // ---------------------------------------------------------------------------
  // Display-name screen
  // ---------------------------------------------------------------------------

  /// Screen title.
  static const String displayNameTitle = 'Pick a name';

  /// Explains where the name is visible.
  static const String displayNameBody =
      'This name is only visible to people whose circle invitations you '
      'accept. Invitations are sent using a public key, so your name stays '
      'hidden until you accept.';

  /// Text-field hint.
  static const String displayNameHint = 'e.g. Alex';

  /// Primary CTA.
  static const String displayNameCta = 'Continue';

  /// Skip button label.
  static const String displayNameSkip = 'Skip';

  /// Snackbar on save failure.
  static const String displayNameError =
      'Couldn\u2019t save that name. Please try again.';

  // ---------------------------------------------------------------------------
  // Ready screen
  // ---------------------------------------------------------------------------

  /// Screen title.
  static const String readyTitle = 'You\u2019re ready';

  /// Body explaining the first-use mental model.
  static const String readyBody =
      'Haven is organised into circles, which are small private groups where '
      'you share your location with people you trust. '
      'Create your first circle, or wait for an invitation from '
      'someone you know.';

  /// Primary CTA.
  static const String readyCta = 'Enter Haven';
}
