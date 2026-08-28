/// Whether the person under the cursor can be added to the invitation being
/// built, and if not, which of three distinct reasons applies.
///
/// Two surfaces ask this and they hold different identifiers, so there are
/// two entry points over one enum and one precedence rule:
///
/// - a picker ROW carries a [MemberCandidate], which has the hex pubkey the
///   roster and the identity are keyed by;
/// - the search FIELD carries only what was typed, which is an npub.
///
/// Both answer BEFORE any relay is dialled. The check this replaces on
/// `add_member_page.dart` read a hex pubkey out of a fetched KeyPackage, so
/// with no network there was nothing to compare against and the add
/// proceeded (plan §9.5).
library;

import 'package:haven/l10n/app_localizations.dart';
import 'package:haven/src/services/member_directory_service.dart';

/// Why a person is, or is not, offered as a pick.
///
/// The three refusals are deliberately separate. "Already in this circle" is
/// literally true of the user themselves, and was the only thing the shipped
/// code could say about their own key — which is why a user who pasted their
/// own ID was told something true, unhelpful, and indistinguishable from the
/// ordinary case.
enum MemberPickState {
  /// Can be added.
  selectable,

  /// This is the user's own identity.
  self,

  /// Already on the target circle's member list.
  alreadyInCircle,

  /// Already staged on this screen, waiting to be invited.
  alreadyStaged,
}

/// Whether [candidate] can be picked, given what this screen already holds.
///
/// [stagedNpubs] is matched against [MemberCandidate.npub] and the other two
/// against [MemberCandidate.pubkeyHex], because that is the form each source
/// is authoritative in: the screens stage npubs, while the roster and the
/// identity are keyed by hex. Hex also side-steps `hex_to_npub`'s
/// fall-back-to-hex behaviour on a malformed key, which would silently turn
/// an npub comparison into no comparison at all.
///
/// **[circleMemberPubkeysHex] MUST already be lower-cased by the caller.**
/// This runs once per rendered ROW per keystroke (the picker re-filters
/// undebounced), so folding every member of the set here — the shape this
/// replaced — cost one `toLowerCase()` allocation per member per row: a
/// roster of 50 at 10 visible rows is ~500 throwaway strings per keystroke
/// for concurrency that bought nothing. Callers normalise ONCE, when the
/// circle's roster is known (e.g. at picker-open time), not per build; this
/// function then does one O(1) `Set.contains` with no allocation of its own.
///
/// A null [selfPubkeyHex] means the identity has not resolved yet, and yields
/// [MemberPickState.selectable] rather than refusing everyone: the picker
/// would otherwise be uniformly disabled during startup for a reason no user
/// could act on. Adding yourself is a mistake, not an escalation — the entry
/// path re-checks it, and the invitation itself is authored by the identity
/// this compares against.
MemberPickState resolveMemberPickState(
  MemberCandidate candidate, {
  required Set<String> stagedNpubs,
  required Set<String> circleMemberPubkeysHex,
  required String? selfPubkeyHex,
}) {
  final hex = candidate.pubkeyHex.toLowerCase();
  if (selfPubkeyHex != null && hex == selfPubkeyHex.toLowerCase()) {
    return MemberPickState.self;
  }
  if (circleMemberPubkeysHex.contains(hex)) {
    return MemberPickState.alreadyInCircle;
  }
  if (stagedNpubs.contains(candidate.npub)) {
    return MemberPickState.alreadyStaged;
  }
  return MemberPickState.selectable;
}

/// Whether the [npub] just entered into the search field can be staged.
///
/// Everything compared here is already on the device, so this holds offline
/// and answers before the KeyPackage lookup rather than after it.
MemberPickState resolveEntryPickState(
  String npub, {
  required Set<String> stagedNpubs,
  required Set<String> circleMemberNpubs,
  required String? selfNpub,
}) {
  if (selfNpub != null && npub == selfNpub) return MemberPickState.self;
  if (circleMemberNpubs.contains(npub)) return MemberPickState.alreadyInCircle;
  if (stagedNpubs.contains(npub)) return MemberPickState.alreadyStaged;
  return MemberPickState.selectable;
}

/// How a refusal is worded, wherever it is shown.
///
/// One mapping for all four surfaces that report it — the search field, a
/// picker row, the QR result, and the tests — so a reason cannot be phrased
/// one way under the field and another way on the row that means the same
/// thing. Returns `null` for [MemberPickState.selectable], which has nothing
/// to say.
String? memberPickRefusalMessage(AppLocalizations l10n, MemberPickState state) {
  return switch (state) {
    MemberPickState.selectable => null,
    MemberPickState.self => l10n.memberPickerReasonSelf,
    MemberPickState.alreadyInCircle => l10n.addMemberAlreadyInCircle,
    MemberPickState.alreadyStaged => l10n.memberSearchAlreadyAdded,
  };
}
