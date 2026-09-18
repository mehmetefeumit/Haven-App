/// Abstract interface for public Nostr profile services.
///
/// Provides a platform-agnostic API for reading and publishing kind-0
/// (NIP-01/NIP-24) public Nostr profile metadata — display name, about
/// text, and profile picture — resolved by Nostr public key. This
/// abstraction allows for easy testing with mock implementations.
///
/// See `docs/PUBLIC_PROFILE_MIGRATION_PLAN.md` (§6.1) for the full design.
/// This migrates Haven away from its previous "no public profiles" model
/// at the owner's explicit direction (CLAUDE.md Rule 10 exception).
/// Publishing is public-by-default and UNCONDITIONAL (owner-directed
/// 2026-07-16, matching the White Noise reference app): there is no consent
/// flag — saving a display name or photo always publishes. That a profile is
/// public is disclosed to the user (onboarding + the Identity settings page),
/// not gated by a toggle in this layer.
///
/// Implementations:
/// - `NostrProfileService` (production, wraps the Rust core) — added in a
///   later wave once the corresponding FFI surface exists.
library;

import 'package:flutter/foundation.dart';
import 'package:haven/src/constants/profile_refresh_tiers.dart';
import 'package:haven/src/utils/log_alias.dart';

/// Exception thrown when profile operations fail.
class ProfileServiceException implements Exception {
  /// Creates a [ProfileServiceException] with the given message.
  const ProfileServiceException(this.message);

  /// The error message.
  final String message;

  @override
  String toString() => 'ProfileServiceException: $message';
}

/// A public Nostr profile (kind-0 metadata), resolved by public key.
///
/// Mirrors a subset of NIP-01/NIP-24 `kind:0` fields plus a locally
/// cached profile picture. Deliberately has **no picture URL field**: per
/// decision D2 of the migration plan, picture URLs never cross the FFI
/// boundary — only already-downloaded, sha256-verified bytes do. This
/// keeps the `Image.network` ban meaningful (see
/// `test/security/image_network_ban_test.dart`) and never hands Flutter
/// an attacker-controlled URL to fetch.
@immutable
class Profile {
  /// Creates a [Profile].
  const Profile({
    required this.pubkeyHex,
    this.name,
    this.displayName,
    this.about,
    this.pictureBytes,
    this.pictureHash,
    this.knownAt,
  });

  /// The profile owner's Nostr public key (hex format).
  final String pubkeyHex;

  /// Raw NIP-01 `name` field, if set.
  final String? name;

  /// NIP-24 `display_name` field, if set.
  ///
  /// Preferred over [name] for display — see the four-tier precedence
  /// resolver (local nickname → `display_name` → `name` → npub + initials)
  /// added alongside `member_display.dart` in a later wave (D6).
  final String? displayName;

  /// NIP-01 `about` bio text, if set.
  final String? about;

  /// Decoded, re-encoded profile picture bytes, or `null` if none is
  /// cached.
  ///
  /// Already sanitized (EXIF/GPS/XMP stripped, re-encoded) and
  /// sha256-verified by the Rust core before ever reaching Dart. Never a
  /// URL — see the class doc.
  final Uint8List? pictureBytes;

  /// Content hash of [pictureBytes] (matches the Blossom `sha256` of the
  /// downloaded blob).
  ///
  /// Used to key decode caches and detect a picture change without
  /// re-decoding image bytes. `null` when [pictureBytes] is `null`.
  final String? pictureHash;

  /// When this profile snapshot was last resolved from a kind-0 fetch
  /// (the Rust cache row's `fetched_at`), or `null` if this pubkey has
  /// never been fetched (cache state `Unknown`).
  final DateTime? knownAt;

  /// Returns a copy of this profile with the given fields overridden.
  ///
  /// Following this class's existing value-class convention (see
  /// `MemberLocation.copyWith` in `location_sharing_service.dart`), a
  /// `null` argument means "keep the current value" — pass an empty
  /// string to clear a text field. This cannot null out [pictureBytes] /
  /// [pictureHash]; construct a new [Profile] directly for that case
  /// (e.g. an avatar-removal result).
  Profile copyWith({
    String? name,
    String? displayName,
    String? about,
    Uint8List? pictureBytes,
    String? pictureHash,
    DateTime? knownAt,
  }) {
    return Profile(
      pubkeyHex: pubkeyHex,
      name: name ?? this.name,
      displayName: displayName ?? this.displayName,
      about: about ?? this.about,
      pictureBytes: pictureBytes ?? this.pictureBytes,
      pictureHash: pictureHash ?? this.pictureHash,
      knownAt: knownAt ?? this.knownAt,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is Profile &&
          runtimeType == other.runtimeType &&
          pubkeyHex == other.pubkeyHex &&
          name == other.name &&
          displayName == other.displayName &&
          about == other.about &&
          pictureHash == other.pictureHash &&
          knownAt == other.knownAt &&
          listEquals(pictureBytes, other.pictureBytes);

  @override
  int get hashCode =>
      Object.hash(pubkeyHex, name, displayName, about, pictureHash, knownAt);

  @override
  String toString() =>
      'Profile(${logAliasHandle(LogAliasClass.peer, pubkeyHex)}, '
      'hasPicture: ${pictureBytes != null})';
}

/// What one own-profile sync pass did (mirrors the Rust
/// `ProfileSyncOutcome`/FFI `ProfileSyncOutcomeFfi`).
///
/// No catch-all variant, deliberately: a new outcome must force every
/// `switch` over this enum to decide what it means rather than silently
/// folding into "something went wrong".
enum ProfileSyncOutcome {
  /// Everything saved is already fully acknowledged; no network was touched.
  nothingPending,

  /// A kind-0 was published and at least one relay acknowledged it.
  published,

  /// The staged picture could not be uploaded; nothing was published.
  uploadFailed,

  /// The kind-0 was built but no relay accepted it.
  publishFailed,

  /// Too few uncontaminated profile relays remain to publish at all.
  poolUnderflow,
}

/// The result of one own-profile sync pass ([ProfileService.syncOwnProfile]).
///
/// Mirrors the FFI `ProfileSyncResultFfi` — kept as a distinct Dart type so no
/// FFI class ever leaks above the service layer.
@immutable
class ProfileSyncResult {
  /// Creates a [ProfileSyncResult].
  const ProfileSyncResult({
    required this.outcome,
    required this.relaysAcked,
    required this.relaysAttempted,
    required this.stillPending,
  });

  /// What the pass did.
  final ProfileSyncOutcome outcome;

  /// How many relays acknowledged the published event.
  final int relaysAcked;

  /// How many relays the publish was attempted against.
  final int relaysAttempted;

  /// Whether a save is STILL unpublished after this pass — the honest answer
  /// even for [ProfileSyncOutcome.published], because a partial
  /// acknowledgement (or an edit saved mid-flight) leaves work behind.
  final bool stillPending;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ProfileSyncResult &&
          runtimeType == other.runtimeType &&
          outcome == other.outcome &&
          relaysAcked == other.relaysAcked &&
          relaysAttempted == other.relaysAttempted &&
          stillPending == other.stillPending;

  @override
  int get hashCode =>
      Object.hash(outcome, relaysAcked, relaysAttempted, stillPending);
}

/// What the UI may honestly say about the own profile right now
/// ([ProfileService.pendingSyncState]; mirrors the FFI
/// `ProfilePendingStateFfi`).
///
/// Three independent facts rather than one enum: how they render is a UI
/// concern, and collapsing them here would decide it in the service layer.
@immutable
class ProfilePendingState {
  /// Creates a [ProfilePendingState].
  const ProfilePendingState({
    required this.pending,
    required this.partial,
    required this.retryDue,
  });

  /// A save has not been fully acknowledged yet.
  final bool pending;

  /// Pending, but already accepted by at least one relay for this version.
  final bool partial;

  /// The persisted retry ladder permits another attempt now.
  final bool retryDue;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ProfilePendingState &&
          runtimeType == other.runtimeType &&
          pending == other.pending &&
          partial == other.partial &&
          retryDue == other.retryDue;

  @override
  int get hashCode => Object.hash(pending, partial, retryDue);
}

/// Abstract interface for public Nostr profile services.
///
/// Manages the user's own public profile (kind-0 name/about/photo) and
/// resolves other circle members' public profiles by pubkey.
///
/// **Local-first, honest-status publishing**: [updateOwnProfile] and
/// [setOwnAvatar] merge the edit onto the LOCAL cache and queue it — they no
/// longer touch a relay or Blossom, and return in milliseconds. Publishing is
/// still unconditional — there is no consent flag (public-by-default,
/// owner-directed 2026-07-16) — but it now happens on [syncOwnProfile], which
/// callers should trigger right after a local save (see
/// `utils/profile_sync_trigger.dart`) and which the UI can also honestly
/// report the progress of via [pendingSyncState]. Every method's allow-status:
/// - Reads ([getOwnProfile], [getMemberProfile], [getCachedMemberProfiles],
///   [refreshMemberProfiles]) are always allowed — another client's
///   already-published data is public regardless of anything Haven does.
/// - Local writes ([updateOwnProfile], [setOwnAvatar]) always save and queue.
/// - [syncOwnProfile] always attempts to publish whatever is queued.
/// - Retraction ([removeOwnAvatar]) is always allowed, but is a no-op
///   unless something was actually published; it must never create a
///   public footprint for a pubkey that never published.
abstract class ProfileService {
  /// Returns the user's own profile, or `null` if never fetched/published.
  ///
  /// Resolves from the local cache first. Per decision D7, this should
  /// never throw purely because the network is unavailable when a cached
  /// value exists — pass [forceRefresh] to force a network re-fetch; a
  /// background refresh augments the cache and callers should
  /// invalidate/re-read afterward rather than await a slow network
  /// round-trip inline.
  ///
  /// Always allowed (a read).
  ///
  /// Throws [ProfileServiceException] on a genuine failure.
  Future<Profile?> getOwnProfile({bool forceRefresh = false});

  /// Merges [displayName] and [about] onto the LOCAL cache and queues them
  /// for publication — this no longer touches a relay.
  ///
  /// Mutates only [displayName] and [about] — leaving every other field
  /// (including any `custom` NIP-24 field set by another client, e.g.
  /// `lud16`) untouched — and ACCUMULATES with any edit already queued from
  /// an earlier, still-unsynced call. Pass `about: null` to leave the
  /// existing about text unchanged, or `about: ''` to clear it.
  ///
  /// Returns in milliseconds: no relay is dialed and no signing key is
  /// needed, because nothing is published here. [syncOwnProfile] is what
  /// makes the network agree. There is no consent gate (see class doc) — the
  /// edit is queued unconditionally.
  ///
  /// Throws [ProfileServiceException] on a genuine local (database) failure.
  /// Unlike before this migration, this can no longer throw because a relay
  /// rejected the event — that outcome now lives in [syncOwnProfile]'s
  /// result.
  Future<Profile> updateOwnProfile({
    required String displayName,
    String? about,
  });

  /// Sanitizes [raw] and saves it LOCALLY as the user's own profile picture,
  /// queued for upload — this no longer touches Blossom or a relay.
  ///
  /// EXIF/GPS/XMP metadata is stripped and the image re-encoded before it is
  /// cached; the raw input bytes never outlive this call. The returned
  /// [Profile.pictureBytes] are the re-encoded, locally cached bytes. Returns
  /// in milliseconds — [syncOwnProfile] is what uploads the staged bytes and
  /// publishes the resulting URL.
  ///
  /// There is no consent gate (see class doc) — the picture is queued
  /// unconditionally.
  ///
  /// Throws [ProfileServiceException] if sanitization fails or the local
  /// database write fails. Unlike before this migration, this can no longer
  /// throw because the Blossom upload or the kind-0 republish failed — those
  /// outcomes now live in [syncOwnProfile]'s result.
  Future<Profile> setOwnAvatar(Uint8List raw);

  /// Publishes whatever the local own-profile outbox is holding.
  ///
  /// Idempotent and safe to call from any resume/foreground trigger: with
  /// nothing queued it resolves to [ProfileSyncOutcome.nothingPending]
  /// without touching the network. A network/relay failure is an OUTCOME
  /// in the returned [ProfileSyncResult], not a thrown exception — the save
  /// stays queued with its retry backoff advanced, and only a genuine local
  /// fault (malformed secret, database error) throws.
  ///
  /// Prefer triggering this via `utils/profile_sync_trigger.dart` rather
  /// than calling it directly from widget code, so overlapping calls
  /// coalesce through one shared controller instead of each opening its own
  /// relay connections for the same publish.
  ///
  /// Throws [ProfileServiceException] on a genuine local failure.
  Future<ProfileSyncResult> syncOwnProfile();

  /// Whether the own profile has unpublished work, how far it got, and
  /// whether the persisted backoff permits another sync attempt now.
  ///
  /// A pure local read — never touches the network. Callers use this before
  /// [syncOwnProfile] to decide whether a network attempt is warranted at
  /// all (e.g. a resume trigger that should not dial a relay just to
  /// discover it had nothing to say).
  ///
  /// **Fails closed**: on any read failure this returns
  /// `ProfilePendingState(pending: true, partial: false, retryDue: false)`
  /// — deliberately. An unreadable local state must never be reported as
  /// "up to date" (which could hide a save that never actually published),
  /// but it also must not force an automatic network retry loop on a
  /// persistent local fault — `retryDue: false` leaves that to an explicit,
  /// user-initiated retry. This method itself never throws.
  Future<ProfilePendingState> pendingSyncState();

  /// Removes the user's own published profile picture.
  ///
  /// Always allowed — a no-op (returns the current profile unchanged)
  /// unless a picture was actually published; must never mint a first
  /// public kind-0 event for a pubkey that never published.
  ///
  /// Throws [ProfileServiceException] on a genuine failure.
  Future<Profile> removeOwnAvatar();

  /// Returns a single circle member's profile, resolved by [pubkeyHex],
  /// or `null` if never fetched.
  ///
  /// Resolves from the local cache; pass [forceRefresh] to force a
  /// network re-fetch for just this pubkey. To refresh many members at
  /// once (e.g. on circle open), prefer [refreshMemberProfiles], which
  /// batches into a single relay request instead of one per member.
  ///
  /// Always allowed (a read) — another pubkey's already-published data is
  /// public regardless of anything Haven's own UI does.
  ///
  /// Throws [ProfileServiceException] on a genuine failure.
  Future<Profile?> getMemberProfile(
    String pubkeyHex, {
    bool forceRefresh = false,
  });

  /// Reads the ALREADY-CACHED profiles for [pubkeyHexes] in ONE batch, and
  /// without resolving picture bytes.
  ///
  /// The read a name-only surface wants: [getMemberProfile] loads each
  /// person's 96px thumbnail whenever one is cached, so a caller that keeps
  /// only [Profile.pictureHash] pays a decrypt, an FFI copy and the peak
  /// memory for a thumbnail per person and then drops it. The returned
  /// [Profile]s therefore always have a `null` [Profile.pictureBytes], and
  /// [Profile.pictureHash] is how a row that does want the bytes asks for
  /// them later.
  ///
  /// Never touches the network — unlike [refreshMemberProfiles], a pubkey
  /// with no cache entry stays absent rather than being fetched.
  ///
  /// **Never throws.** A pubkey whose row resolved nothing (a negative-cache
  /// entry: looked up, nothing found) is simply absent from the result, and a
  /// failure to open the store or read the batch at all yields an empty map:
  /// one unresolvable person must cost that person their name, never the
  /// whole picker.
  Future<Map<String, Profile>> getCachedMemberProfiles(
    List<String> pubkeyHexes,
  );

  /// Batch-refreshes profiles for [pubkeyHexes] in a single relay fetch.
  ///
  /// Callers should pass the **union** of all known member pubkeys across
  /// every circle — never a clean per-circle roster partition, which
  /// would hand the relay exact co-membership clusters (migration plan
  /// §1.7).
  ///
  /// [maxAge] is the caller's staleness tolerance: a pubkey whose cached
  /// entry is younger than this is served from cache and never refetched.
  /// Pass [profileForceMaxAge] (`Duration.zero`) to re-fetch everything.
  /// Pick a tier from `constants/profile_refresh_tiers.dart` rather than an
  /// ad-hoc value, so refresh cadence stays reviewable in one place.
  ///
  /// Returns a map of pubkeyHex to the resolved [Profile] for every
  /// pubkey with a cache entry after the refresh; a pubkey that was never
  /// found on any relay is recorded `Unknown` on the Rust side and is
  /// simply absent from the result — not an error.
  ///
  /// Always allowed (a read).
  ///
  /// Throws [ProfileServiceException] on a genuine failure. Implementations
  /// called from a best-effort background refresh should generally prefer
  /// to swallow partial per-pubkey failures and return whatever resolved.
  Future<Map<String, Profile>> refreshMemberProfiles(
    List<String> pubkeyHexes, {
    Duration maxAge = profileInteractiveMaxAge,
  });

  /// Resolves ONE typed stranger's published profile by [npub] — the member
  /// picker's typed-stranger resolve (plan §10 D2).
  ///
  /// [npub] MUST already be a complete, validated npub the caller has decided
  /// is worth a single-key network lookup — this method itself does no
  /// eligibility gating (that lives in the picker: a complete-match check, a
  /// local-directory check, and a self/staged/in-circle check, all run
  /// BEFORE this is ever called). It is a SINGLETON lookup, never a batch:
  /// unlike [refreshMemberProfiles], which exists precisely to avoid a
  /// per-circle roster partition, this asks about exactly the one key a user
  /// just typed or pasted, and nothing else about their circles.
  ///
  /// Never downloads a picture: like [getMemberProfile], only bytes already
  /// cached (if any) are read. A stranger's picture URL is an HTTP GET to a
  /// host THEY chose, from the user's IP — that must never fire merely
  /// because their npub was typed.
  ///
  /// Returns `null` when nothing resolved (including an npub that is
  /// syntactically well-formed but fails to decode) so the caller falls back
  /// to rendering the bare npub — never an error for that case.
  ///
  /// Always allowed (a read) — another pubkey's already-published data is
  /// public regardless of anything Haven's own UI does.
  ///
  /// Throws [ProfileServiceException] on a genuine failure.
  Future<Profile?> resolveTypedStrangerProfile(String npub);
}
