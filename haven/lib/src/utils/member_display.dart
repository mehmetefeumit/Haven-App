/// Helpers for resolving how a circle member should be displayed.
///
/// The member list mixes entries from two sources:
///
/// - Other members: their display name (if any) comes from the local Contact
///   table, populated when the current user has saved a nickname for them.
/// - The current user (self): their display name comes from device settings
///   (`IdentityService.getDisplayName`), not the Contact table — the user
///   does not usually have a Contact record for themselves.
///
/// These helpers join those two sources so callers can stay dumb. The helper
/// lives in `utils/` (not under `widgets/`) so non-widget consumers — for
/// example a future map overlay or notification renderer — can share the
/// same self-detection rule without pulling a dependency on the widget
/// layer.
library;

import 'package:haven/src/services/circle_service.dart';
import 'package:haven/src/services/profile_service.dart';

/// Returns the effective display name for [member], preferring the current
/// user's settings display name when [member] is the current user.
///
/// Resolution order:
///
/// 1. If [member] is the current user ([currentUserPubkey] equal to
///    [CircleMember.pubkey], compared case-insensitively), returns
///    [currentUserDisplayName] after trimming — but only when the trimmed
///    value is non-empty.
/// 2. Otherwise (or if the current user has no settings display name yet),
///    returns [CircleMember.displayName] (the Contact-table nickname).
///
/// A null return means the caller should fall back to a truncated pubkey.
///
/// Pubkey comparison is case-insensitive so that accidental hex-case drift
/// between identity sources (e.g. a stored contact using uppercase hex) does
/// not silently break self-detection. The Rust FFI today always emits
/// lowercase hex — the guard is defensive and cheap insurance.
String? resolveMemberDisplayName(
  CircleMember member, {
  required String? currentUserPubkey,
  required String? currentUserDisplayName,
}) {
  if (isSelfMember(member, currentUserPubkey: currentUserPubkey)) {
    final trimmed = currentUserDisplayName?.trim();
    if (trimmed != null && trimmed.isNotEmpty) {
      return trimmed;
    }
  }
  return member.displayName;
}

/// Returns `true` if [member] represents the current user.
///
/// Returns `false` when [currentUserPubkey] is null or empty — for example
/// while the identity is still loading or when no identity has been created.
/// Comparison is case-insensitive.
bool isSelfMember(CircleMember member, {required String? currentUserPubkey}) {
  if (currentUserPubkey == null || currentUserPubkey.isEmpty) return false;
  if (member.pubkey.isEmpty) return false;
  return member.pubkey.toLowerCase() == currentUserPubkey.toLowerCase();
}

/// Resolves the effective display name for a **non-self** circle member
/// under the public-profile migration (plan D6).
///
/// Precedence, most to least specific:
///
/// 1. [localOverride] — the user's own petname for this member (Contact
///    table `display_name`, set via the member detail sheet's "Set
///    Nickname"). Trimmed; ignored when empty/whitespace-only.
/// 2. [profile]?.displayName — the member's public kind-0 NIP-24
///    `display_name`, when non-empty.
/// 3. [profile]?.name — the member's public kind-0 NIP-01 `name`, when
///    non-empty.
/// 4. [npubFallback] — always returned as the last resort, so this
///    function (unlike [resolveMemberDisplayName]) never returns `null`.
///
/// The current user's own row does NOT use this resolver — it keeps its
/// dedicated [resolveMemberDisplayName] self-branch (reading the local
/// settings display name), so the member list and the Identity page always
/// agree on the self name (Flutter review F3). Passing a self member here
/// would silently skip that agreement, so callers must branch on
/// [isSelfMember] before choosing which resolver to call.
String resolveEffectiveMemberName({
  required String npubFallback,
  String? localOverride,
  Profile? profile,
}) {
  final nickname = localOverride?.trim();
  if (nickname != null && nickname.isNotEmpty) return nickname;

  final displayName = profile?.displayName?.trim();
  if (displayName != null && displayName.isNotEmpty) return displayName;

  final name = profile?.name?.trim();
  if (name != null && name.isNotEmpty) return name;

  return npubFallback;
}
