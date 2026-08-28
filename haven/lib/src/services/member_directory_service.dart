/// The local directory of people the user shares, or recently shared, a
/// circle with.
///
/// Answers requirements R2, R4 and R5 of `docs/MEMBER_PICKER_PLAN.md`: two
/// sections — current co-members, then people who shared a circle within the
/// 3-day retention window — that auto-populate the empty member field,
/// searchable by npub and by cached username. It adds no storage and no wire
/// traffic of its own: WHO is offered and WHICH TIER comes from the
/// persistent `member_directory` table (`rankedDirectoryMembers`, P3), and
/// names/pictures still come from the kind-0 profile cache.
///
/// Everything the directory DECIDES lives in the top-level functions below,
/// with no FFI in the path, so eligibility, tier bucketing, name resolution,
/// collision disambiguation, ordering and matching are all provable on the
/// host. The production implementation (`NostrMemberDirectoryService`) is a
/// call-and-map shell over them.
library;

import 'package:flutter/foundation.dart';
import 'package:haven/src/services/circle_service.dart';
import 'package:haven/src/services/profile_service.dart';
import 'package:haven/src/utils/member_display.dart';
import 'package:haven/src/utils/search_fold.dart';

/// One person the directory can offer, with everything a row needs to be
/// ordered, matched and identified — and nothing more.
///
/// Deliberately carries no picture BYTES. A roster's worth of 96px thumbnails
/// is tens of megabytes held for a list whose visible window is a handful of
/// rows; a row resolves its own bytes through `memberProfileProvider` when it
/// scrolls into view. [pictureHash] is enough to know a picture exists and to
/// key a decode cache.
@immutable
class MemberCandidate {
  /// Creates a [MemberCandidate].
  ///
  /// Prefer [buildMemberCandidate], which derives [nameKey]/[searchKeys] from
  /// the same fold the query is normalised with; a hand-built candidate can
  /// carry keys that disagree with its own names.
  const MemberCandidate({
    required this.pubkeyHex,
    required this.npub,
    required this.nameKey,
    required this.searchKeys,
    this.tier = DirectoryTier.current,
    this.displayName,
    this.petname,
    this.pictureHash,
    this.collisionCircleName,
  });

  /// The person's Nostr public key, hex.
  final String pubkeyHex;

  /// The same key in bech32 (npub) form — always rendered, as the
  /// anti-impersonation control (plan §7.1).
  final String npub;

  /// Which picker section this person is offered under (plan §7.2). Carries
  /// ROSTER PROVENANCE only — never a claim about whether they joined,
  /// accepted, or are active.
  final DirectoryTier tier;

  /// The name a row shows, or `null` when nothing resolved and the row is
  /// identified by [npub] alone.
  ///
  /// Resolved by [resolveEffectiveMemberName]: local petname, then the
  /// published `display_name`, then the published `name`.
  final String? displayName;

  /// The user's own local name for this person, when they set one.
  final String? petname;

  /// Content hash of the cached profile picture, or `null` when no picture
  /// is cached.
  final String? pictureHash;

  /// The circle name that disambiguates this row from another tier-0 row
  /// with the SAME [displayName], or `null` when no such collision exists —
  /// or when one does but none of this row's circles is unique to it among
  /// the rows it collides with (see [_distinguishingCircleName]).
  ///
  /// The single exception to "no circle is ever named at rest" (plan §7.2,
  /// D4): when two current co-members resolve to the same displayed name, a
  /// shared circle name is the only local way to tell them apart. Never set
  /// outside a genuine collision, and never for a tier-1 (recent) row — they
  /// are no longer co-members of anything, so there is no current circle
  /// that would BE the reason two names collide.
  final String? collisionCircleName;

  /// [displayName] folded — what the ordering compares on. Empty when no
  /// name resolved, and for the degenerate name the fold strips entirely.
  final String nameKey;

  /// Every name Haven knows for this person, folded.
  ///
  /// Includes [nameKey] and, when a petname masks a published name, that
  /// published name too: R4 asks for people to be searchable by their CACHED
  /// USERNAME, so renaming someone locally must not make them unfindable
  /// under the name their other contacts know them by.
  final List<String> searchKeys;

  /// Whether a profile picture is cached for this person.
  bool get hasPicture => pictureHash != null;

  /// Returns a copy of this candidate with [collisionCircleName] replaced.
  ///
  /// The only field [buildDirectory]'s collision pass ever needs to set
  /// after a candidate is built — every other field is fixed once the
  /// directory row and the cache read are known.
  MemberCandidate copyWith({String? collisionCircleName}) {
    return MemberCandidate(
      pubkeyHex: pubkeyHex,
      npub: npub,
      tier: tier,
      displayName: displayName,
      petname: petname,
      pictureHash: pictureHash,
      nameKey: nameKey,
      searchKeys: searchKeys,
      collisionCircleName: collisionCircleName,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is MemberCandidate &&
          runtimeType == other.runtimeType &&
          pubkeyHex == other.pubkeyHex &&
          npub == other.npub &&
          tier == other.tier &&
          displayName == other.displayName &&
          petname == other.petname &&
          pictureHash == other.pictureHash &&
          collisionCircleName == other.collisionCircleName &&
          nameKey == other.nameKey &&
          listEquals(searchKeys, other.searchKeys);

  @override
  int get hashCode => Object.hash(
    pubkeyHex,
    npub,
    tier,
    displayName,
    petname,
    pictureHash,
    collisionCircleName,
    nameKey,
    Object.hashAll(searchKeys),
  );

  @override
  String toString() =>
      'MemberCandidate(${_shortKey(pubkeyHex)}, tier: $tier, named: '
      '${displayName != null})';
}

/// The leading 8 hex characters of [pubkeyHex] — or all of it when it is
/// shorter, because a `toString` that can raise turns one diagnostic into
/// two failures on the very path that reached for it.
String _shortKey(String pubkeyHex) =>
    pubkeyHex.length > 8 ? '${pubkeyHex.substring(0, 8)}...' : pubkeyHex;

/// The ordered, deduplicated directory one picker opening renders from.
@immutable
class MemberDirectory {
  /// Creates a [MemberDirectory] over an already-ordered [entries].
  const MemberDirectory(this.entries, {this.degraded = false});

  /// The directory with nobody in it — legitimately: no identity yet, or a
  /// genuine read that came back with zero rows. Never set [degraded].
  static const empty = MemberDirectory(<MemberCandidate>[]);

  /// A read FAILED — an unreadable store, a broken profile cache, or any
  /// other exception the outer catch in [MemberDirectoryService.loadDirectory]
  /// absorbed — as opposed to [empty], which means the read succeeded and
  /// genuinely found nobody. Distinguishing the two matters: a user with
  /// twenty co-members must never see the fresh-install "you have nobody
  /// yet" guidance because a query happened to throw. Carries [degraded]
  /// `true`; every other constant on this class carries it `false`.
  static const readFailed = MemberDirectory(
    <MemberCandidate>[],
    degraded: true,
  );

  /// One entry per person, in render order: every [DirectoryTier.current]
  /// entry (folded-name order), then every [DirectoryTier.recent] entry
  /// (see [buildDirectory]).
  final List<MemberCandidate> entries;

  /// Set on [readFailed]; `false` on every other instance, including [empty].
  final bool degraded;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is MemberDirectory &&
          runtimeType == other.runtimeType &&
          degraded == other.degraded &&
          listEquals(entries, other.entries);

  @override
  int get hashCode => Object.hash(degraded, Object.hashAll(entries));

  @override
  String toString() =>
      'MemberDirectory(${entries.length}${degraded ? ', degraded' : ''})';
}

/// Reads the local directory of people the user shares, or recently shared,
/// a circle with.
///
/// Implementations:
/// - `NostrMemberDirectoryService` (production, over the persistent
///   `member_directory` table and the local profile/contact caches).
///
/// An interface rather than the bare function type `one_member_abstracts`
/// suggests: this is the repo's DI seam, the thing a `ProviderScope` override
/// swaps for a recording mock, and the place the never-throws contract above
/// is stated once for every implementation.
// ignore: one_member_abstracts
abstract class MemberDirectoryService {
  /// Loads the current directory: current co-members of every joined circle,
  /// plus anyone who shared a circle within the retention window, except the
  /// local user.
  ///
  /// Takes no exclusion set. Someone already in the circle a caller is
  /// adding to is still someone the user shares a circle with, and plan
  /// §9.5 renders them as a DISABLED row with a reason — dropping them here
  /// would hide the person the user is searching for, and would empty the
  /// list entirely for a user whose only circle is the one being added to.
  ///
  /// [circles] is the caller's ALREADY-LOADED visible-circles list (e.g.
  /// `circlesProvider`'s cached value) — used ONLY to disambiguate a
  /// display-name collision between two current co-members (plan §7.2), never
  /// a source of WHO or WHICH TIER (that comes exclusively from the
  /// persistent directory table). Passed in rather than re-fetched: the
  /// caller already holds this list warm for the life of the process, so a
  /// second, uncached walk of the same rosters would cost an FFI call and a
  /// session-lock acquisition per circle for data already in memory.
  ///
  /// **Never throws.** Any failure resolves to [MemberDirectory.empty] or
  /// [MemberDirectory.readFailed] — never an exception. Without an identity, or
  /// when the read genuinely finds nobody, this is [MemberDirectory.empty]:
  /// the accelerator over a screen whose paste and QR paths still work simply
  /// has nothing to offer. A genuine read failure (an unreadable store, a
  /// broken profile cache) is [MemberDirectory.readFailed] instead, so a user
  /// with real co-members is told something went wrong rather than shown the
  /// fresh-install "you have nobody yet" guidance.
  Future<MemberDirectory> loadDirectory({required List<Circle> circles});
}

/// Builds one candidate from a directory row, whatever the profile cache
/// holds for it, and the user's local petname for it (if any).
///
/// Built from resolved CONTENT, never from the presence of a cache row: the
/// profile cache answers with a row for a pubkey it resolved nothing for, so
/// "an entry came back" is not "a profile resolved". A contentless row —
/// like an absent one — leaves the person identified by their npub, which is
/// the point of R2: nobody is silently hidden.
MemberCandidate buildMemberCandidate({
  required DirectoryEntry entry,
  Profile? profile,
  String? petname,
  SearchFold fold = searchFold,
}) {
  final trimmedPetname = _trimToNull(petname);

  // `resolveEffectiveMemberName` returns its fallback only when all three
  // real tiers are empty, and every tier is trimmed and required non-empty —
  // so with '' as the fallback, '' means exactly "nothing resolved" and can
  // never be a real name. Reusing the shipped resolver keeps the picker's
  // name precedence identical to the member list's.
  final resolved = resolveEffectiveMemberName(
    npubFallback: '',
    localOverride: trimmedPetname,
    profile: profile,
  );
  final displayName = resolved.isEmpty ? null : resolved;
  final nameKey = displayName == null ? '' : fold(displayName);

  final searchKeys = <String>[];
  for (final name in [
    trimmedPetname,
    _trimToNull(profile?.displayName),
    _trimToNull(profile?.name),
  ]) {
    if (name == null) continue;
    final key = fold(name);
    if (key.isEmpty || searchKeys.contains(key)) continue;
    searchKeys.add(key);
  }

  return MemberCandidate(
    pubkeyHex: entry.pubkeyHex,
    npub: entry.npub,
    tier: entry.tier,
    displayName: displayName,
    petname: trimmedPetname,
    pictureHash: profile?.pictureHash,
    nameKey: nameKey,
    searchKeys: List.unmodifiable(searchKeys),
  );
}

/// Builds the render-ordered directory from [entries] — WHO and WHICH TIER,
/// straight from the persistent `member_directory` table — the cached
/// [profiles] read for them and their local [petnames], keyed by pubkey.
///
/// [circleNamesByPubkey] is used for ONE thing only: breaking a
/// display-name collision between two tier-0 rows (plan §7.2). It is never a
/// source of WHO or WHICH TIER — a pubkey it mentions that is not already in
/// [entries] contributes nothing, and it never turns a tier-1 row into a
/// tier-0 one.
///
/// Two independently name-ordered blocks, current then recent — never one
/// list re-sorted across both — so a name that happens to sort early never
/// jumps a recent contact ahead of every current co-member.
MemberDirectory buildDirectory({
  required List<DirectoryEntry> entries,
  required Map<String, Profile> profiles,
  Map<String, String> petnames = const {},
  Map<String, List<String>> circleNamesByPubkey = const {},
  SearchFold fold = searchFold,
}) {
  final candidates = [
    for (final entry in entries)
      buildMemberCandidate(
        entry: entry,
        profile: profiles[entry.pubkeyHex],
        petname: petnames[entry.pubkeyHex],
        fold: fold,
      ),
  ];
  final marked = _markCollidingNames(
    candidates,
    circleNamesByPubkey: circleNamesByPubkey,
    fold: fold,
  );
  final current = [
    for (final c in marked)
      if (c.tier == DirectoryTier.current) c,
  ]..sort(_compareCandidates);
  final recent = [
    for (final c in marked)
      if (c.tier == DirectoryTier.recent) c,
  ]..sort(_compareCandidates);
  return MemberDirectory(List.unmodifiable([...current, ...recent]));
}

/// Every circle name each of [selfPubkeyHex]'s current co-members shares,
/// used ONLY as the disambiguator [buildDirectory] attaches to a
/// display-name collision (plan §7.2). Never rendered on its own, and never
/// consulted for a tier-1 row — someone no longer on any circle's member
/// list has no current circle for this to name.
///
/// `getVisibleCircles` also returns circles the user has only been INVITED
/// to; those are excluded, matching the union the directory table itself is
/// built from.
Map<String, List<String>> circleNamesForCollision({
  required List<Circle> circles,
  required String selfPubkeyHex,
}) {
  final result = <String, List<String>>{};
  for (final circle in circles) {
    if (circle.membershipStatus != MembershipStatus.accepted) continue;
    for (final member in circle.members) {
      if (isSelfMember(member, currentUserPubkey: selfPubkeyHex)) continue;
      result.putIfAbsent(member.pubkey.toLowerCase(), () => <String>[]).add(
        circle.displayName,
      );
    }
  }
  return result;
}

/// Marks every tier-0 candidate whose resolved [MemberCandidate.displayName]
/// is shared with another tier-0 candidate's, using [circleNamesByPubkey] as
/// the only local disambiguator (plan §7.2). Every colliding row is
/// considered, not just one of the pair — but a row is only ever marked with
/// a circle name that actually sets it apart from the OTHER rows it collides
/// with; see [_distinguishingCircleName].
///
/// Scoped to tier-0 ("co-members") deliberately: a tier-1 person is not a
/// co-member of anything any more, so there is no current circle that could
/// BE the reason their name collides with someone else's.
///
/// Compares the exact rendered [MemberCandidate.displayName], not the folded
/// search key — two names that fold alike (e.g. differing only by accent)
/// are not a rendered collision, and marking them would name a circle nobody
/// needed to disambiguate. This is the person's display name; the CIRCLE
/// names used to disambiguate a collision are a different string and ARE
/// compared folded — see [_distinguishingCircleName].
List<MemberCandidate> _markCollidingNames(
  List<MemberCandidate> candidates, {
  required Map<String, List<String>> circleNamesByPubkey,
  SearchFold fold = searchFold,
}) {
  final groupsByName = <String, List<MemberCandidate>>{};
  for (final candidate in candidates) {
    if (candidate.tier != DirectoryTier.current) continue;
    final name = candidate.displayName;
    if (name == null) continue;
    groupsByName.putIfAbsent(name, () => []).add(candidate);
  }

  // Keyed by pubkeyHex rather than filtered inline below, so a `null`
  // disambiguator (no distinguishing circle) is still distinguishable from
  // "not part of a collision at all" (candidate.copyWith left untouched).
  final chosen = <String, String?>{};
  for (final group in groupsByName.values) {
    if (group.length < 2) continue;
    for (final candidate in group) {
      final own = circleNamesByPubkey[candidate.pubkeyHex.toLowerCase()];
      // Folded: the Rust sanitizer deliberately KEEPS invisible-but-legible
      // characters (ZWNJ, ZWJ, LRM/RLM/ALM, VS-16, emoji tags) as real
      // orthography, so a spoofed circle name built from them can render
      // identically to a real one while comparing unequal as a raw string —
      // exactly defeating the disambiguator this exclusion set exists to
      // drive. `fold` collapses that padding (and case/accent) on both
      // sides, matching every other name comparison in this file.
      final othersFolded = <String>{
        for (final other in group)
          if (other.pubkeyHex != candidate.pubkeyHex)
            for (final name
                in circleNamesByPubkey[other.pubkeyHex.toLowerCase()] ??
                    const <String>[])
              fold(name),
      };
      chosen[candidate.pubkeyHex] = _distinguishingCircleName(
        own,
        excludingFolded: othersFolded,
        fold: fold,
      );
    }
  }

  return [
    for (final candidate in candidates)
      if (chosen.containsKey(candidate.pubkeyHex))
        candidate.copyWith(collisionCircleName: chosen[candidate.pubkeyHex])
      else
        candidate,
  ];
}

/// The disambiguator to show for one colliding row: the alphabetically
/// first of [own]'s circles that is NOT also a circle any of the OTHER rows
/// it collides with belongs to ([excludingFolded]), or `null` when every one
/// of [own]'s circles is shared with at least one of them.
///
/// Naming each row its own alphabetically-first circle independently can
/// hand two colliding rows the identical name when they happen to share
/// that first circle too — disambiguating nothing. Comparing against
/// [excludingFolded] instead guarantees the result, when non-null, is unique
/// to this row within its collision group, and — because [excludingFolded]
/// is built from every OTHER row's full circle list rather than from what
/// they individually end up showing — the choice does not depend on which
/// row is considered first.
///
/// [own]'s membership test folds each candidate with [fold] before checking
/// it against [excludingFolded] (already folded by the caller): two circle
/// names that render identically but differ only by an invisible character
/// the sanitizer keeps (ZWNJ, ZWJ, bidi marks, VS-16, emoji tags — see
/// `haven-core`'s `fold_for_search`) must be treated as the SAME circle
/// here, or a spoofed name survives sanitization only to defeat the very
/// disambiguator it was sanitized for. The RETURNED value, and the order
/// [own] is sorted in, both stay on the raw (unfolded) name — folding is
/// strictly a comparison detail; the row still renders, and alphabetizes,
/// the real sanitized text.
///
/// A raw name that is empty — `haven-core`'s `sanitize_display_name` returns
/// the empty string for a circle name built entirely from invisible
/// characters — is never a candidate: an empty label discloses nothing and
/// reads as a rendering bug, not a disambiguator.
///
/// When no circle is unique to this row (every one of its circles is also
/// shared by another colliding row), this returns `null` rather than a name
/// that would duplicate what a colliding row already shows: a circle note
/// that reads the same on two rows is not a disambiguator, and would read as
/// one. The npub — always rendered (plan §7.1) — remains the row's
/// unconditional differentiator either way.
String? _distinguishingCircleName(
  List<String>? own, {
  required Set<String> excludingFolded,
  SearchFold fold = searchFold,
}) {
  if (own == null || own.isEmpty) return null;
  final exclusive =
      own
          .where(
            (name) =>
                name.isNotEmpty && !excludingFolded.contains(fold(name)),
          )
          .toList()
        ..sort();
  return exclusive.isEmpty ? null : exclusive.first;
}

/// Every npub's shared human-readable part. Not a prefix anyone typed:
/// every key in the directory starts with it.
const _npubPrefix = 'npub1';

/// Returns the entries of [directory] matching [query], in directory order.
///
/// An empty (or whitespace-only) query returns the whole directory — R2's
/// auto-populate, which is what the picker shows the moment it opens.
/// Otherwise the folded query must be a substring of one of the candidate's
/// folded names, or — when it is recognisable as an npub — a PREFIX of the
/// candidate's npub.
///
/// Prefix, never substring, for the key: a substring rule would let a short
/// fragment nobody could have read off an identity enumerate the whole
/// directory. Both sides go through the same [fold], which is the only way
/// two independently normalised strings can be compared at all.
///
/// A key match additionally requires the query to carry `npub1` AND at least
/// one character past it. Every npub begins `npub1`, so a plain prefix rule
/// returns the ENTIRE directory for `n` — keystroke 1 of "Nadia" — which is
/// the enumeration the prefix rule exists to prevent. Requiring the prefix
/// costs nothing real: a key reaches this field by paste, and the truncated
/// form rendered anywhere in Haven starts at `npub1`.
///
/// Hex pubkeys are not matched at all. Hex is never rendered on this
/// surface, so a hex match surfaces people for a reason the user cannot see
/// — and one hex character selects roughly a sixteenth of the roster.
///
/// Synchronous and undebounced by design (plan §9.3): the fold is a
/// `#[frb(sync)]` call on the calling thread, so the filtered list is ready
/// in the same frame as the keystroke.
List<MemberCandidate> searchDirectory(
  MemberDirectory directory, {
  required String query,
  SearchFold fold = searchFold,
}) {
  final folded = fold(query.trim());
  if (folded.isEmpty) return directory.entries;
  return [
    for (final candidate in directory.entries)
      if (_matches(candidate, folded)) candidate,
  ];
}

bool _matches(MemberCandidate candidate, String foldedQuery) {
  for (final key in candidate.searchKeys) {
    if (key.contains(foldedQuery)) return true;
  }
  if (foldedQuery.length <= _npubPrefix.length ||
      !foldedQuery.startsWith(_npubPrefix)) {
    return false;
  }
  // The npub is bech32, so it is already the ASCII lower-case of itself and
  // the fold is a plain case fold over it. Folding it per candidate per
  // keystroke would be one FFI call per row instead of one per query.
  return candidate.npub.toLowerCase().startsWith(foldedQuery);
}

/// A TOTAL order over ONE tier's block: named entries by folded name,
/// unnamed entries last, and every remaining tie broken by pubkey hex.
///
/// Totality is not tidiness. Without the final tie-break the rendered
/// sequence would depend on which circle happened to be read first, and
/// every widget test over the list would be flaky.
int _compareCandidates(MemberCandidate a, MemberCandidate b) {
  final aNamed = a.displayName != null;
  final bNamed = b.displayName != null;
  if (aNamed != bNamed) return aNamed ? -1 : 1;
  final byName = a.nameKey.compareTo(b.nameKey);
  if (byName != 0) return byName;
  return a.pubkeyHex.compareTo(b.pubkeyHex);
}

String? _trimToNull(String? value) {
  final trimmed = value?.trim();
  return (trimmed == null || trimmed.isEmpty) ? null : trimmed;
}
