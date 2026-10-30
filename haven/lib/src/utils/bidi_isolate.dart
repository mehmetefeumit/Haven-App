/// Directional isolation for untrusted text interpolated beside app text.
library;

/// Wraps [text] in U+2068 FIRST STRONG ISOLATE / U+2069 POP DIRECTIONAL
/// ISOLATE.
///
/// Applied to a kind-0 display name — attacker-chosen, anyone can publish any
/// name — wherever it is interpolated into a RENDERED paragraph beside app
/// text. The bidirectional algorithm resolves run boundaries across a whole
/// paragraph, so an unisolated strong-RTL name (or one carrying an
/// unterminated U+202E override) reorders the words around it; the isolate
/// confines both effects to the name. Every locale happens to put this
/// placeholder last today, but a translation that moves it is an ARB edit
/// away, so the defence is structural rather than positional.
///
/// On a semantics LABEL the calculus is different, not exempt: TTS and
/// braille both read a label's codepoints in logical order, so an override
/// embedded in it cannot visually reorder anything for either — there is no
/// paragraph layout for it to escape. The invitation card's own "Invited by"
/// label is left un-isolated, and correctly so: the name is the LAST thing
/// in that joined string, so even where a label's raw text IS instead
/// rendered visibly — by an accessibility inspector, a semantics-tree dump,
/// or screenshot tooling, all of which do lay text out — there is nothing
/// after the name in this particular string left to reorder. Where a label
/// instead JOINS the untrusted text with OTHER label content that follows it
/// in the same string, isolate it there too: it is free (never spoken, never
/// a braille cell) and keeps that trailing content from being swallowed by
/// an unterminated override under those visual consumers.
/// `MemberCandidateTile._semanticsLabel` in member_picker.dart is exactly
/// that case — its identity is followed by the tier, the nickname note, the
/// collision note and any refusal reason in one joined string, so it stays
/// isolated there. An npub cannot carry a direction control — bech32 is ASCII
/// by construction — so it needs isolating only to keep its run whole beside
/// other right-to-left text; the missed-invitations list isolates each
/// shortened one so a row stays whole wherever its text is joined.
String bidiIsolate(String text) => '\u2068$text\u2069';
