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
/// - Never use: "MLS", "Nostr", "relay", "nsec", "key package", "pubkey",
///   "encryption", "signature", "bech32", "protocol".
/// - Prefer concrete verbs ("scrambled", "hop", "hold") and active voice.
/// - Address the user as "you".
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

  /// Primary hero tagline.
  static const String welcomeHeadline =
      'Share where you are.\nOnly with who you pick.';

  /// Subordinate line beneath the hero.
  static const String welcomeSub = 'No account. No email. No phone number.';

  /// Primary CTA on the welcome screen.
  static const String welcomeCta = 'Get Started';

  // ---------------------------------------------------------------------------
  // Value props screen
  // ---------------------------------------------------------------------------

  /// Screen title.
  static const String valuePropsTitle = 'What makes Haven different';

  /// Card 1 headline.
  static const String valueProp1Title = 'Your location, your rules';

  /// Card 1 body.
  static const String valueProp1Body =
      'Share where you are only with the small groups of people you pick. '
      'Nobody else, ever.';

  /// Card 2 headline.
  static const String valueProp2Title = 'Locked with a key only you hold';

  /// Card 2 body.
  static const String valueProp2Body =
      'Your location is scrambled on your phone before it leaves. '
      'Only people you trust can unscramble it.';

  /// Card 3 headline.
  static const String valueProp3Title = 'Nothing tying you to the internet';

  /// Card 3 body.
  static const String valueProp3Body =
      'No central Haven server stores your data. Messages pass through '
      'independent relays that can\u2019t read them.';

  /// Card 4 headline.
  static const String valueProp4Title = 'Your name stays on your device';

  /// Card 4 body.
  static const String valueProp4Body =
      'The name you pick is visible only to you and your circles. '
      'It\u2019s never uploaded or searchable anywhere online.';

  /// Primary CTA for value-props screen.
  static const String valuePropsCta = 'Continue';

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
      'This is how people in your circles will see you. '
      'Only they see it \u2014 '
      'it never leaves your phone except inside encrypted messages.';

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
      'Haven is organised into circles \u2014 small private groups where '
      'you share your location with people you trust. '
      'Create your first circle, or wait for an invitation from '
      'someone you know.';

  /// Primary CTA.
  static const String readyCta = 'Enter Haven';
}
