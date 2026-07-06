/// Abstract interface for circle management services.
///
/// Provides a platform-agnostic API for managing circles (groups of trusted
/// contacts for location sharing). This abstraction allows for easy testing
/// with mock implementations.
///
/// Implementations:
/// - `NostrCircleService` (production, wraps the Rust core)
library;

import 'package:flutter/foundation.dart';
import 'package:haven/src/rust/api.dart' show AvatarMetaFfi;

/// Result of routing a kind-445 event through the avatar reassembler.
///
/// A non-avatar event (location, group update, unknown inner type) returns
/// `accepted = false, complete = false` — not an error. A `complete == true`
/// result means the Rust layer has stored the assembled avatar; callers should
/// invalidate the member-thumbnail provider for the sender.
@immutable
class AvatarIngestResult {
  /// Creates an [AvatarIngestResult].
  const AvatarIngestResult({
    required this.accepted,
    required this.complete,
    this.senderPubkeyHex,
  });

  /// Whether the event was recognised and accepted as an avatar event.
  final bool accepted;

  /// Whether a full avatar (or clear) has been stored after this event.
  final bool complete;

  /// MLS-authenticated sender pubkey hex when [accepted] is true.
  final String? senderPubkeyHex;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AvatarIngestResult &&
          runtimeType == other.runtimeType &&
          accepted == other.accepted &&
          complete == other.complete &&
          senderPubkeyHex == other.senderPubkeyHex;

  @override
  int get hashCode =>
      accepted.hashCode ^ complete.hashCode ^ senderPubkeyHex.hashCode;

  @override
  String toString() =>
      'AvatarIngestResult(accepted: $accepted, complete: $complete)';
}

/// Exception thrown when circle operations fail.
class CircleServiceException implements Exception {
  /// Creates a [CircleServiceException] with the given message.
  const CircleServiceException(this.message);

  /// The error message.
  final String message;

  @override
  String toString() => 'CircleServiceException: $message';
}

/// Membership status for a circle member.
enum MembershipStatus {
  /// Invitation sent but not yet accepted.
  pending,

  /// Member has accepted and is active.
  accepted,

  /// Member has declined the invitation.
  declined,
}

/// Circle type enumeration.
enum CircleType {
  /// Circle for sharing location with trusted contacts.
  locationSharing,

  /// Direct share circle for one-on-one sharing.
  directShare,
}

/// Represents a circle (group) for location sharing.
///
/// A circle is an MLS group with associated metadata for managing
/// trusted contacts who can see each other's locations.
@immutable
class Circle {
  /// Creates a new [Circle].
  const Circle({
    required this.mlsGroupId,
    required this.nostrGroupId,
    required this.displayName,
    required this.circleType,
    required this.relays,
    required this.membershipStatus,
    required this.members,
    required this.createdAt,
    required this.updatedAt,
  });

  /// Internal MLS group identifier (not shared publicly).
  final List<int> mlsGroupId;

  /// Public Nostr group identifier (shared in events).
  final List<int> nostrGroupId;

  /// User-facing name of the circle.
  final String displayName;

  /// Type of circle (location sharing or direct share).
  final CircleType circleType;

  /// Relay URLs for this circle.
  final List<String> relays;

  /// Current user's membership status in this circle.
  final MembershipStatus membershipStatus;

  /// Members of this circle.
  final List<CircleMember> members;

  /// When this circle was created.
  final DateTime createdAt;

  /// When this circle was last updated.
  final DateTime updatedAt;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is Circle &&
          runtimeType == other.runtimeType &&
          listEquals(mlsGroupId, other.mlsGroupId);

  @override
  int get hashCode => Object.hashAll(mlsGroupId);

  @override
  String toString() => 'Circle(members: ${members.length})';
}

/// Represents a member of a circle.
@immutable
class CircleMember {
  /// Creates a new [CircleMember].
  const CircleMember({
    required this.pubkey,
    required this.isAdmin,
    required this.status,
    this.displayName,
  });

  /// Member's Nostr public key (hex format).
  final String pubkey;

  /// Local display name for this member (from contacts).
  final String? displayName;

  /// Whether this member is an admin of the circle.
  final bool isAdmin;

  /// Member's invitation status.
  final MembershipStatus status;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is CircleMember &&
          runtimeType == other.runtimeType &&
          pubkey == other.pubkey;

  @override
  int get hashCode => pubkey.hashCode;

  @override
  String toString() =>
      'CircleMember(pubkey: ${pubkey.substring(0, 8)}..., status: $status)';
}

/// Result of creating a circle.
///
/// Contains the created circle and gift-wrapped welcome events
/// ready to publish to each invited member.
@immutable
class CircleCreationResult {
  /// Creates a new [CircleCreationResult].
  const CircleCreationResult({
    required this.circle,
    required this.welcomeEvents,
  });

  /// The created circle.
  final Circle circle;

  /// Gift-wrapped welcome events ready to publish.
  ///
  /// Each event is a kind 1059 gift-wrapped event containing an
  /// encrypted kind 444 Welcome, ready to publish to recipient relays.
  final List<GiftWrappedWelcome> welcomeEvents;
}

/// Result of adding members to an existing circle.
@immutable
class AddMemberResult {
  /// Creates a new [AddMemberResult].
  const AddMemberResult({
    required this.welcomesSent,
    required this.welcomesTotal,
  });

  /// Number of gift-wrapped Welcomes that reached at least one relay.
  final int welcomesSent;

  /// Total Welcomes produced (one per added member).
  final int welcomesTotal;
}

/// A gift-wrapped welcome event for a circle invitation.
///
/// Contains a kind 1059 gift-wrapped event that encapsulates an encrypted
/// kind 444 Welcome message. Ready to publish directly to relays.
@immutable
class GiftWrappedWelcome {
  /// Creates a new [GiftWrappedWelcome].
  const GiftWrappedWelcome({
    required this.recipientPubkey,
    required this.recipientRelays,
    required this.eventJson,
  });

  /// Recipient's Nostr public key (hex format).
  final String recipientPubkey;

  /// Relay URLs to publish this event to (recipient's inbox relays).
  final List<String> recipientRelays;

  /// Gift-wrapped event as JSON string (kind 1059).
  ///
  /// This is a signed, ready-to-publish event containing the encrypted
  /// Welcome message. The outer event uses an ephemeral keypair to hide
  /// the sender's identity per NIP-59.
  final String eventJson;
}

/// Represents a pending invitation to join a circle.
@immutable
class Invitation {
  /// Creates a new [Invitation].
  const Invitation({
    required this.mlsGroupId,
    required this.circleName,
    required this.inviterPubkey,
    required this.memberCount,
    required this.invitedAt,
  });

  /// MLS group identifier.
  final List<int> mlsGroupId;

  /// Name of the circle.
  final String circleName;

  /// Public key of the person who invited you.
  final String inviterPubkey;

  /// Number of members in the circle.
  final int memberCount;

  /// When the invitation was received.
  final DateTime invitedAt;

  @override
  String toString() => 'Invitation(memberCount: $memberCount)';
}

/// Encrypted location event ready for relay publishing.
@immutable
class EncryptedLocation {
  /// Creates an [EncryptedLocation].
  const EncryptedLocation({
    required this.eventJson,
    required this.nostrGroupId,
    required this.relays,
  });

  /// JSON-serialized signed Nostr event (kind 445).
  final String eventJson;

  /// Nostr group ID (32 bytes, for h-tag relay filtering).
  final List<int> nostrGroupId;

  /// Relay URLs to publish to.
  final List<String> relays;
}

/// Decrypted location from a peer.
@immutable
class DecryptedLocation {
  /// Creates a [DecryptedLocation].
  const DecryptedLocation({
    required this.senderPubkey,
    required this.latitude,
    required this.longitude,
    required this.geohash,
    required this.timestamp,
    required this.expiresAt,
    this.displayName,
  });

  /// Sender's Nostr public key (hex-encoded).
  final String senderPubkey;

  /// Latitude (exact GPS reading).
  final double latitude;

  /// Longitude (exact GPS reading).
  final double longitude;

  /// Geohash of the location.
  final String geohash;

  /// When the location was recorded.
  final DateTime timestamp;

  /// When this location expires.
  final DateTime expiresAt;

  /// Sender's self-chosen display name (if provided).
  final String? displayName;

  /// Whether this location has expired.
  bool get isExpired => DateTime.now().isAfter(expiresAt);
}

/// Result of decrypting a kind 445 MLS group event.
///
/// Distinguishes between location messages and MLS group state changes
/// (commits, proposals) so callers can refresh circle membership when
/// the group roster changes.
@immutable
class DecryptResult {
  /// Creates a [DecryptResult].
  const DecryptResult({
    this.location,
    this.groupUpdated = false,
    this.evolutionEventJson,
    this.evolutionMlsGroupId,
  });

  /// The decrypted location, if this was an application message.
  final DecryptedLocation? location;

  /// Whether this event was an MLS commit or proposal that changed
  /// the group state (e.g., a new member joined).
  final bool groupUpdated;

  /// Outbound `kind:445` commit event the caller must publish to the
  /// circle's relays and then finalize locally.
  ///
  /// Populated only when the Rust core auto-committed a peer's
  /// `SelfRemove` proposal (MLS leave): MDK stages a pending commit and
  /// the caller must publish it and call [CircleService.finalizePendingCommit]
  /// (or [CircleService.clearPendingCommit] on publish failure) so the
  /// local MLS epoch advances and the leaver stops appearing in the
  /// roster.
  ///
  /// `null` for location messages, plain commits, pending Add/Remove
  /// proposals awaiting admin approval, external join proposals, and
  /// unprocessable events.
  final String? evolutionEventJson;

  /// MLS group ID (raw bytes) the evolution event belongs to.
  ///
  /// Carried alongside [evolutionEventJson] so the caller can invoke
  /// [CircleService.finalizePendingCommit] / [CircleService.clearPendingCommit]
  /// after the publish attempt. `null` whenever [evolutionEventJson] is
  /// `null`.
  final List<int>? evolutionMlsGroupId;
}

/// Abstract interface for circle management services.
///
/// Manages circles (groups of trusted contacts for location sharing).
abstract class CircleService {
  /// Creates a new circle with the given members.
  ///
  /// The [identitySecretBytes] are the creator's identity secret bytes
  /// (32 bytes). The [memberKeyPackages] are the fetched KeyPackage data
  /// for each member. The [name] is the user-facing display name.
  ///
  /// Returns a [CircleCreationResult] containing the circle and gift-wrapped
  /// welcome events ready to publish.
  ///
  /// [creatorFallbackRelays] are the creator's own inbox relays (kind 10050),
  /// used as the third tier in the Welcome-delivery cascade
  /// (member 10050 → member 10002 → creator inbox → FAIL CLOSED). Pass an
  /// empty list if the creator has no inbox relays; delivery then fails
  /// closed (no public-default fallback) when tiers 1–2 are also empty.
  ///
  /// Throws [CircleServiceException] if creation fails.
  Future<CircleCreationResult> createCircle({
    required List<int> identitySecretBytes,
    required List<KeyPackageData> memberKeyPackages,
    required String name,
    required CircleType circleType,
    String? description,
    List<String>? relays,
    List<String> creatorFallbackRelays = const [],
  });

  /// Gets all visible circles (excludes declined invitations).
  ///
  /// Returns circles where the user is a member or has a pending invitation.
  /// Declined invitations are not included.
  ///
  /// Throws [CircleServiceException] if retrieval fails.
  Future<List<Circle>> getVisibleCircles();

  /// Gets a specific circle by its MLS group ID.
  ///
  /// Returns `null` if the circle is not found.
  ///
  /// Throws [CircleServiceException] if retrieval fails.
  Future<Circle?> getCircle(List<int> mlsGroupId);

  /// Gets the members of a circle.
  ///
  /// Returns the list of members with their status and contact info.
  ///
  /// Throws [CircleServiceException] if retrieval fails.
  Future<List<CircleMember>> getMembers(List<int> mlsGroupId);

  /// Gets all pending invitations.
  ///
  /// Returns invitations that have not been accepted or declined.
  ///
  /// Throws [CircleServiceException] if retrieval fails.
  Future<List<Invitation>> getPendingInvitations();

  /// Accepts an invitation to join a circle.
  ///
  /// Updates the membership status to [MembershipStatus.accepted].
  ///
  /// Returns the circle with updated membership.
  ///
  /// Throws [CircleServiceException] if acceptance fails.
  Future<Circle> acceptInvitation(List<int> mlsGroupId);

  /// Declines an invitation to join a circle.
  ///
  /// Updates the membership status to [MembershipStatus.declined].
  /// The circle will no longer appear in [getVisibleCircles].
  ///
  /// Throws [CircleServiceException] if declining fails.
  Future<void> declineInvitation(List<int> mlsGroupId);

  /// Leaves a circle.
  ///
  /// Removes the user from the circle. This action cannot be undone.
  ///
  /// [selfPubkeyHex] is the caller's Nostr identity pubkey — required so
  /// the Rust layer can classify the leave (non-admin, admin handoff, or
  /// sole-member abandon) before executing the matching MLS sequence.
  ///
  /// Throws [CircleServiceException] if leaving fails.
  Future<void> leaveCircle({
    required List<int> mlsGroupId,
    required String selfPubkeyHex,
  });

  /// Removes [memberPubkeyHex] from the circle identified by [mlsGroupId].
  ///
  /// Intended for admin-initiated removal — e.g. evicting a member who
  /// has gone quiet, or cleaning up a stale invite. Admins leaving
  /// themselves go through the MIP-03 `LeavePlan` path (self-demote
  /// then SelfRemove); this method is for removing **other** members.
  ///
  /// Stages the MLS `RemoveMember` commit, publishes the `kind:445`
  /// evolution event to the circle's relays, and finalizes (or clears,
  /// on publish failure) the pending commit locally.
  ///
  /// Throws [CircleServiceException] if the caller is not an admin, the
  /// member is not in the circle, staging the commit fails, or the
  /// evolution event could not be published to any relay.
  Future<void> removeMember({
    required List<int> mlsGroupId,
    required String memberPubkeyHex,
  });

  /// Adds new members to an already-created circle (admin only).
  ///
  /// Stages the MLS add commit, publishes the kind:445 evolution event to
  /// the circle's relays, finalizes (or clears, on publish failure) the
  /// pending commit, then publishes the gift-wrapped Welcome(s) to each new
  /// member's relays. Welcomes are published ONLY after a successful
  /// finalize, so a rolled-back add never leaves a dangling invitation.
  ///
  /// [creatorFallbackRelays] are the adder's own inbox relays (kind 10050),
  /// the third tier of the Welcome-delivery cascade.
  ///
  /// [secretProvider] yields the caller's 32-byte identity secret; it is
  /// invoked FRESH for each staging attempt (and scrubbed straight after) so
  /// the plaintext is never held across a settle-window wait (Rule 9). Under
  /// live-sync convergence an add re-stages up to three times, so passing raw
  /// bytes would keep the secret resident for ~24s.
  ///
  /// Throws [CircleServiceException] if not admin, relays unavailable,
  /// staging/publish/finalize fails, or delivery fails closed.
  Future<AddMemberResult> addMember({
    required Future<List<int>> Function() secretProvider,
    required List<int> mlsGroupId,
    required List<KeyPackageData> memberKeyPackages,
    List<String> creatorFallbackRelays = const [],
  });

  /// Processes a gift-wrapped invitation event.
  ///
  /// Unwraps the NIP-59 gift wrap, extracts the MLS Welcome, and stores
  /// the invitation as pending. Circle name and relays are extracted
  /// from the Welcome's embedded group data.
  ///
  /// Returns:
  /// - [Invitation] for a newly-processed gift wrap (caller should surface
  ///   it in the UI and refresh the pending-invitations list).
  /// - `null` when the gift wrap has already been processed on a prior
  ///   poll cycle. This is the expected outcome when NIP-59's 2-day
  ///   lookback causes the poller to re-fetch the same wrapper events.
  ///   Callers should treat `null` as a silent no-op (no count, no log).
  ///
  /// Throws [CircleServiceException] for real failures (malformed event,
  /// MDK error, storage failure).
  Future<Invitation?> processGiftWrappedInvitation({
    required List<int> identitySecretBytes,
    required String giftWrapEventJson,
  });

  /// Returns MLS group IDs where the user's key material needs rotation.
  ///
  /// A group is included if the post-join self-update was never completed
  /// (`Required`) or the last rotation is older than [thresholdSecs]
  /// (`CompletedAt` past threshold). Callers should iterate the result
  /// and call [selfUpdate] for each group.
  ///
  /// Throws [CircleServiceException] on failure.
  Future<List<List<int>>> groupsNeedingSelfUpdate(int thresholdSecs);

  /// Performs a self-update on the user's leaf node in a group (MIP-02/03).
  ///
  /// Rotates the user's MLS key material to restore forward secrecy after
  /// joining a group (MIP-02) or for periodic post-compromise security
  /// (MIP-03). Publishes the evolution event to the circle's relays with
  /// retry and rollback on failure.
  ///
  /// This is a best-effort operation — failure is logged but does not throw.
  Future<void> selfUpdate(List<int> mlsGroupId);

  /// Finalizes a pending MLS commit for a circle.
  ///
  /// Must be called after all welcome events have been published to relays.
  /// This merges the pending commit into the MLS group state, completing
  /// the group creation or member addition.
  ///
  /// Throws [CircleServiceException] if finalization fails.
  Future<void> finalizePendingCommit(List<int> mlsGroupId);

  /// Clears a pending MLS commit, rolling back failed publish attempts.
  ///
  /// Call this when a relay publish fails after an operation that creates
  /// a pending commit (circle creation, member addition, etc.). This
  /// prevents the group from being permanently blocked by a dangling
  /// pending commit.
  ///
  /// Throws [CircleServiceException] if clearing fails.
  Future<void> clearPendingCommit(List<int> mlsGroupId);

  /// Publishes an MLS evolution event (kind 445 commit) to [relays].
  ///
  /// Used to surface an evolution event produced during [decryptLocation]
  /// — specifically when MDK auto-commits a peer's `SelfRemove` proposal
  /// and hands the caller a pending commit. The returned `bool` indicates
  /// whether at least one relay accepted the event on any attempt, so
  /// the caller can decide between finalizing (on success) and clearing
  /// (on failure) the local pending commit.
  ///
  /// [label] is used for diagnostic logging only; it is never included
  /// in the published event and not surfaced to the UI.
  Future<bool> publishEvolutionEvent({
    required String eventJson,
    required List<String> relays,
    required String label,
  });

  /// Encrypts a location for a circle.
  ///
  /// Creates an MLS-encrypted kind 445 event containing the location data,
  /// ready for publishing to the circle's relays.
  ///
  /// [updateIntervalSecs] is the publish-cadence hint used to compute the
  /// jittered NIP-40 `expiration` tag on the outer kind:445 wrapper. Must be
  /// in `[60, 3600]`; the Rust FFI validates the range. The absolute
  /// expiration is sampled uniformly from `[interval, 2 * interval]`.
  ///
  /// Throws [CircleServiceException] if encryption fails.
  Future<EncryptedLocation> encryptLocation({
    required List<int> mlsGroupId,
    required String senderPubkeyHex,
    required double latitude,
    required double longitude,
    required int updateIntervalSecs,
    String? displayName,
  });

  /// Decrypts a received kind 445 event through MLS.
  ///
  /// Returns a [DecryptResult] indicating whether this was a location
  /// message or a group state change (commit/proposal). Returns `null`
  /// for unprocessable or previously-failed events.
  ///
  /// When [DecryptResult.groupUpdated] is `true`, callers should refresh
  /// the circle's member list to pick up roster changes.
  ///
  /// Throws [CircleServiceException] if decryption fails.
  Future<DecryptResult?> decryptLocation({required String eventJson});

  /// Advances the persisted `group_445` sync cursor to a fully-processed
  /// kind:445 event's `created_at` (Unix **seconds**).
  ///
  /// Monotonic — never moves the cursor backward. Call this only after an
  /// event was fully processed (decrypted, and any receiver-side commit
  /// re-published), with the high-water-mark `created_at` of such events in a
  /// fetch batch, so a later cold start / resubscribe re-anchors here instead
  /// of replaying full history or skipping an unprocessed commit. Best-effort:
  /// callers should swallow failures (a lagging cursor self-heals on the next
  /// advance or the cold-start refetch).
  Future<void> advanceGroupCursorToEventSecs(int eventCreatedAtSecs);

  /// Advances the persisted `inbox_1059` sync cursor to a handled gift-wrap's
  /// outer `created_at` (Unix **seconds**).
  ///
  /// As [advanceGroupCursorToEventSecs], for the kind:1059 gift-wrap inbox.
  /// The 7-day inbox lookback applied at REQ time absorbs NIP-59 wrapper
  /// backdating, so advancing on the outer wrapper timestamp is safe.
  Future<void> advanceInboxCursorToWrapSecs(int wrapCreatedAtSecs);

  /// Creates and signs a key package event (kind 443) for relay publishing.
  ///
  /// Generates MLS key material, builds the Nostr event, and signs it
  /// with the identity key. Returns the signed event ready for publishing.
  ///
  /// Throws [CircleServiceException] if signing fails.
  Future<SignedKeyPackageEvent> signKeyPackageEvent({
    required List<int> identitySecretBytes,
    required List<String> relays,
  });

  /// Records a just-published `KeyPackage` pair (M8-6) so the maintenance
  /// live-material gate recognizes it as live (and thus NoOp).
  ///
  /// Call AFTER a relay accepts the canonical 30443 (publish-first), passing
  /// the fields from the [SignedKeyPackageEvent]. Best-effort at the call site;
  /// throws [CircleServiceException] on a storage error.
  Future<void> recordPublishedKeyPackages({
    required List<int> canonicalHashRef,
    required String dTag,
    required String canonicalEventId,
    required String legacyEventId,
  });

  // NOTE: `signRelayListEvent` was removed. The privacy-toggle-aware
  // flow lives on `RelayPreferencesService.buildRelayListPublish`,
  // which atomically gates on the user's publish toggle and resolves
  // targets. Exposing a parallel sign-only method left a way to publish
  // kind 10050/10051 without consulting the toggle. New code MUST use
  // the relay-preferences flow instead.

  /// Signs a NIP-09 event deletion event (kind 5).
  ///
  /// Creates a deletion event referencing the given event IDs, signed
  /// with the identity key. Used to delete consumed KeyPackage events
  /// from relays after rotation.
  ///
  /// Throws [CircleServiceException] if signing fails.
  Future<String> signDeletionEvent({
    required List<int> identitySecretBytes,
    required List<String> eventIds,
  });

  // ==================== Last-Known Location Cache ====================

  /// Persists a last-known location for a circle member.
  ///
  /// The Rust layer derives `purgeAfter = timestamp + LOCATION_RETENTION_SECS`
  /// (1 day) authoritatively; any value passed here is advisory only.
  ///
  /// Throws [CircleServiceException] on failure.
  Future<void> upsertLastKnownLocation({
    required List<int> nostrGroupId,
    required String senderPubkey,
    required double latitude,
    required double longitude,
    required String geohash,
    required DateTime timestamp,
    required DateTime expiresAt,
    required DateTime purgeAfter,
    required DateTime updatedAt,
    String? displayName,
  });

  /// Returns all non-purged last-known locations for a circle.
  ///
  /// Rows whose `purge_after` is in the past relative to [now] are filtered.
  ///
  /// Throws [CircleServiceException] on failure.
  Future<List<DecryptedLocation>> snapshotLastKnownForCircle({
    required List<int> nostrGroupId,
    DateTime? now,
  });

  /// Removes the last-known location for a single sender in a circle.
  ///
  /// Called when the member leaves the circle.
  Future<void> removeLastKnownMember({
    required List<int> nostrGroupId,
    required String senderPubkey,
  });

  /// Removes every last-known location row for a circle.
  Future<void> removeLastKnownCircle({required List<int> nostrGroupId});

  /// Wipes every last-known location row across all circles.
  ///
  /// Wired into the identity-deletion path.
  Future<void> wipeAllLastKnownLocations();

  /// Wipes every M7 staged-commit marker.
  ///
  /// Wired into the identity-deletion path so a returning (or different)
  /// identity never inherits a stale marker that would wrongly skip a
  /// background receive.
  Future<void> wipeAllStagedCommits();

  /// Resets every sync cursor (bulk).
  ///
  /// Wired into the identity-deletion path so a returning identity re-seeds
  /// cleanly instead of resuming at a stale floor.
  Future<void> resetAllSyncCursors();

  /// Drops the open database handle so a subsequent file wipe is race-free.
  ///
  /// Nulls `_manager`, `_initialized`, and `_initCompleter` so GC can drop
  /// the `RustOpaque` Arc, closing the underlying SQLite connection. Must be
  /// called BEFORE [wipeAllMlsState] to ensure POSIX unlink-under-open is
  /// safe (kernel reclaims the inode once the last fd closes).
  Future<void> closeAndInvalidate();

  /// Wipes ALL local MLS state on logout.
  ///
  /// Deletes both encrypted database files (`circles.db` and `haven_mdk.db`,
  /// plus WAL/SHM/journal sidecars) and then removes both keyring keys.
  /// Permanent and irreversible — call only on identity deletion.
  ///
  /// The caller MUST have already called [closeAndInvalidate] to drop the
  /// SQLite handle before this; otherwise file deletion races an open fd.
  Future<void> wipeAllMlsState();

  /// Prunes the dedup cache of processed gift-wrap events.
  ///
  /// Removes rows older than the retention window and caps the table at the
  /// max-row limit. Best-effort maintenance — a failure should not block the
  /// caller. [now] defaults to [DateTime.now] when null.
  Future<void> pruneProcessedGiftWraps({DateTime? now});

  /// Deletes every row whose `purge_after < now`.
  ///
  /// Returns the number of rows removed.
  Future<int> pruneExpiredLastKnown({DateTime? now});

  /// Saves a display name for a contact, only if no name is already set.
  ///
  /// Used to persist sender-reported display names from received location
  /// messages so that the member list shows names instead of raw pubkeys.
  /// Does nothing if the contact already has a display name (preserves
  /// any user-set override).
  Future<void> setContactDisplayNameIfAbsent({
    required String pubkey,
    required String displayName,
  });

  // ==================== Avatar Management ====================

  /// Processes and stores the user's own avatar from raw image bytes.
  ///
  /// EXIF/GPS stripping, downscaling, re-encoding, content hashing, and
  /// SQLCipher-encrypted storage all happen in Rust. Returns metadata
  /// only — never the image bytes.
  ///
  /// Throws [CircleServiceException] on failure.
  Future<AvatarMetaFfi> setMyAvatar(String ownPubkey, Uint8List raw);

  /// Clears (removes) the user's own avatar.
  ///
  /// Throws [CircleServiceException] on failure.
  Future<void> clearMyAvatar(String ownPubkey);

  /// Returns the user's own avatar thumbnail bytes (hot path), or `null`.
  ///
  /// Throws [CircleServiceException] on failure.
  Future<Uint8List?> getMyAvatarThumbnail(String ownPubkey);

  /// Returns the user's own full-resolution avatar bytes, or `null`.
  ///
  /// Throws [CircleServiceException] on failure.
  Future<Uint8List?> getMyAvatar(String ownPubkey);

  // ==================== M2 Avatar Network (broadcast / receive) ====================

  /// Builds the wire-ready kind-445 events that share the user's own avatar
  /// into [mlsGroupId] (M2 on-change publish).
  ///
  /// Returns an empty list if the user has no avatar set. [updateIntervalSecs]
  /// feeds the jittered NIP-40 `expiration` so avatar events are
  /// indistinguishable from location on the wire (DEC-4).
  ///
  /// Throws [CircleServiceException] on failure.
  Future<List<String>> buildAvatarShareEvents({
    required List<int> mlsGroupId,
    required String senderPubkeyHex,
    required int updateIntervalSecs,
  });

  /// Builds a tombstone kind-445 event that clears the user's avatar
  /// in [mlsGroupId].
  ///
  /// The tombstone version is derived inside Rust from the stored own-avatar
  /// version + 1 — no version argument is needed from Dart. This must be
  /// called BEFORE [clearMyAvatar] so Rust can read the current version.
  ///
  /// Returns the event JSON string ready for publishing.
  ///
  /// Throws [CircleServiceException] on failure.
  Future<String> buildAvatarClearEvent({
    required List<int> mlsGroupId,
    required String senderPubkeyHex,
    required int updateIntervalSecs,
  });

  /// Routes a fetched kind-445 event through the avatar reassembler.
  ///
  /// Non-avatar inner types (location, group updates, unknown) return
  /// `accepted = false, complete = false` — callers must NOT treat these
  /// as errors; just continue to the regular `decryptLocation` path.
  ///
  /// On `complete == true`, the Rust layer has stored the assembled
  /// thumbnail and full-res bytes; callers should invalidate the member
  /// thumbnail provider for `(mlsGroupId, senderPubkeyHex)`.
  ///
  /// Throws [CircleServiceException] on a genuine ingest failure.
  Future<AvatarIngestResult> ingestIncomingAvatarMessage({
    required String eventJson,
  });

  /// Returns the thumbnail bytes for a circle member's avatar, or `null`.
  ///
  /// Hot path — returns the small thumbnail tier only. Pass the circle's
  /// MLS group ID (raw bytes) and the member's pubkey hex.
  ///
  /// Throws [CircleServiceException] on failure.
  Future<Uint8List?> getMemberAvatarThumbnail({
    required List<int> mlsGroupId,
    required String pubkey,
  });

  /// Returns the full-resolution avatar bytes for a circle member, or `null`.
  ///
  /// For use on an explicit profile-detail view only (not the hot path).
  ///
  /// Throws [CircleServiceException] on failure.
  Future<Uint8List?> getMemberAvatar({
    required List<int> mlsGroupId,
    required String pubkey,
  });

  /// Rotates the relay list for [mlsGroupId] via a MIP-01
  /// `GroupContextExtensions` commit (admin-only).
  ///
  /// Stages the commit, publishes the resulting `kind:445` evolution event to
  /// the **union** of the circle's current relays and [newRelays] — so a
  /// member that only listens on a relay being removed still receives the
  /// commit before it stops polling that relay. On publish success, calls
  /// `finalizeRelayUpdate` (which merges the commit and re-syncs the admin's
  /// own `circle.relays` to [newRelays]). On publish failure, calls
  /// `clearPendingCommit` and rethrows.
  ///
  /// [newRelays] must be non-empty, `wss://` (or a debug loopback URL in
  /// test builds), credential-free, and at most 20 entries. Admin
  /// authorization is enforced by MDK against live MLS state — non-admins
  /// will receive a [CircleServiceException].
  ///
  /// Throws [CircleServiceException] on any failure.
  Future<void> updateCircleRelays({
    required List<int> mlsGroupId,
    required List<String> newRelays,
  });
}

/// A signed key package event pair ready for relay publishing.
///
/// During the MIP-00 transition window, publishers sign both the canonical
/// kind 30443 (addressable) event and the legacy kind 443 twin from the same
/// MLS material so that clients which still query kind 443 can discover this
/// user. The two events share `content` and `hash_ref`; only the tag set
/// differs (the legacy twin omits the `d` tag).
@immutable
class SignedKeyPackageEvent {
  /// Creates a [SignedKeyPackageEvent].
  const SignedKeyPackageEvent({
    required this.eventJson,
    required this.legacyEventJson,
    required this.relays,
    this.canonicalHashRef = const [],
    this.dTag = '',
    this.canonicalEventId = '',
    this.legacyEventId = '',
  });

  /// The canonical kind 30443 signed event as JSON string.
  final String eventJson;

  /// The legacy kind 443 signed event as JSON string.
  ///
  /// Publishing is best-effort: callers should not fail the rotation when
  /// this twin is rejected, but should keep publishing it to remain
  /// discoverable by clients that haven't migrated yet.
  final String legacyEventJson;

  /// Relay URLs where both events should be published.
  final List<String> relays;

  /// The MLS `KeyPackageRef` bytes (M8-6), for recording the published
  /// `KeyPackage` after a relay accepts it — so maintenance recognizes it as
  /// live. See [CircleService.recordPublishedKeyPackages].
  final List<int> canonicalHashRef;

  /// The stable NIP-33 `d` the canonical event was published into.
  final String dTag;

  /// Lowercase-hex event id of the canonical (30443) event.
  final String canonicalEventId;

  /// Lowercase-hex event id of the legacy (443) twin.
  final String legacyEventId;
}

/// KeyPackage data for a user.
///
/// Contains the information needed to invite a user to a circle.
@immutable
class KeyPackageData {
  /// Creates a new [KeyPackageData].
  const KeyPackageData({
    required this.pubkey,
    required this.eventJson,
    required this.relays,
    this.nip65Relays = const [],
  });

  /// User's Nostr public key (hex format).
  final String pubkey;

  /// Kind 443 KeyPackage event as JSON string.
  final String eventJson;

  /// Inbox relay URLs for Welcome delivery (kind 10050).
  final List<String> relays;

  /// Fallback NIP-65 relay URLs (kind 10002), used when inbox relays
  /// are unavailable for Welcome delivery.
  final List<String> nip65Relays;
}
