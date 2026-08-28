/// What Haven's text fields are allowed to hand to the operating system.
///
/// `TextField.autofillHints` defaults to `const <String>[]`, which is **not**
/// `null`. `EditableText` builds an `AutofillConfiguration` whenever the list
/// is non-null, and that configuration carries the field's
/// `currentEditingValue` to the platform autofill service; only an explicit
/// `null` yields `AutofillConfiguration.disabled`, and `obscureText` gates
/// none of it. `TextFormField` defaults to `null` instead, so it is already
/// opted out and passing this constant there is flagged redundant; the two
/// widgets disagree, so read the default before trusting it. What holds the
/// guarantee at every field is a test asserting `autofillHints` is `null`,
/// which survives a `TextFormField` being rewritten as a `TextField`.
///
/// Nothing Haven asks a user to type is data an autofill service could
/// meaningfully supply: a relay URL, a circle name, a petname kept only on
/// this device, or a display name that is a deliberately generated pseudonym
/// rather than a legal name. The feature is worthless here; the channel out
/// of the app is real.
library;

/// Opts a text field out of platform autofill entirely.
///
/// Pass as `autofillHints`. See the library doc for why `null` — rather than
/// the framework's default empty list — is what actually disables autofill.
const List<String>? kNoAutofill = null;
