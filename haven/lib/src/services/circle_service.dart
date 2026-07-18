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

/// Dark Matter cutover helpers (DM-4c).
extension CircleLegacyStatus on Circle {
  /// Whether this is an orphaned pre-cutover circle row: locally recorded as
  /// [MembershipStatus.accepted] but with an empty [members] list.
  ///
  /// A live, healthy accepted circle always includes at least the caller
  /// (self) in [members] (the underlying MLS roster always contains the
  /// local device once accepted), so this combination is otherwise
  /// unreachable. It arises specifically when the local `circles.db` row
  /// survives the once-only Dark Matter cutover (see
  /// `LegacyCutoverService`/`destroyLegacyMlsState`, which deletes only the
  /// old MLS session store) while the MLS group it refers to no longer
  /// exists — `getVisibleCircles`/`getCircles` swallow the resulting
  /// per-group member-lookup failure to an empty list rather than failing
  /// the whole call (see `haven-core`'s `CircleManager::get_circles`).
  ///
  /// A circle in this state must be re-created (and its members re-invited)
  /// — there is no way to resume the old MLS group.
  bool get isLegacyOrphaned =>
      membershipStatus == MembershipStatus.accepted && members.isEmpty;
}

/// Represents a member of a circle.
@immutable
class CircleMember {
  /// Creates a new [CircleMember].
  const CircleMember({
    required this.pubkey,
    required this.npub,
    required this.isAdmin,
    required this.status,
    this.displayName,
  });

  /// Member's Nostr public key (hex format).
  final String pubkey;

  /// Member's Nostr public key in bech32 (npub) form, for display and sharing.
  final String npub;

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
/// Publish-before-apply (Rule 13): `CircleService.createCircle` publishes the
/// gift-wrapped Welcome events and confirms (or rolls back) the engine's
/// pending group-creation state internally before returning, so this result
/// is presence-only — the raw welcome events never leave the service
/// (mirrors [AddMemberResult]).
@immutable
class CircleCreationResult {
  /// Creates a new [CircleCreationResult].
  const CircleCreationResult({
    required this.circle,
    required this.welcomesSent,
    required this.welcomesTotal,
  });

  /// The created circle.
  final Circle circle;

  /// Number of gift-wrapped Welcomes that reached at least one relay.
  final int welcomesSent;

  /// Total Welcomes produced (one per invited member).
  final int welcomesTotal;
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

  /// Whether this location has expired.
  bool get isExpired => DateTime.now().isAfter(expiresAt);
}

/// Discriminator for a single folded engine result from decrypting/ingesting
/// one `kind:445` event (Dark Matter taxonomy — mirrors
/// `LocationMessageResultKindFfi` 1:1).
///
/// Unlike the pre-migration outcome, stale / duplicate / out-of-order
/// handling is entirely engine-internal (a future-epoch event is durably
/// buffered and re-surfaced once the gap fills), so there is no
/// "unprocessable" / "previously failed" variant here, and — because the
/// engine now owns publish-before-apply for every commit — callers never
/// need to publish or finalize anything in reaction to a decrypt result.
enum LocationEventKind {
  /// A decrypted application (location) message.
  location,

  /// The local client joined a group via an accepted welcome.
  joined,

  /// A durable, MLS-authenticated change to group state (membership, admin,
  /// rename, retention) or an epoch advance the receiver should react to by
  /// refreshing the circle's roster.
  groupUpdate,

  /// A previously-surfaced result was withdrawn because branch selection
  /// superseded the commit that produced it — the caller must treat the
  /// earlier change as if it never happened.
  invalidated,

  /// The group entered the unrecoverable state; the UI MUST block
  /// send/mutate for it (Rule 8, blocked-circle UI state).
  unrecoverable,
}

/// One folded engine result from decrypting/ingesting a single `kind:445`
/// event. A single ingest can yield SEVERAL of these — the engine's internal
/// convergence may release buffered inbound after the outer event — so
/// [CircleService.decryptLocation] returns a `List`.
///
/// Cursor contract: the engine owns out-of-order buffering, so callers
/// advance their relay sync cursor on the OUTER event's `created_at` (which
/// the caller already holds), NOT per result. A buffered future-epoch event
/// is re-surfaced by the engine once the gap fills.
@immutable
class LocationEventResult {
  /// Creates a [LocationEventResult].
  const LocationEventResult({
    required this.kind,
    required this.mlsGroupId,
    required this.epoch,
    this.location,
  });

  /// Which of the five outcomes this result is.
  final LocationEventKind kind;

  /// The decrypted location — non-null only when [kind] is
  /// [LocationEventKind.location] AND the inner content parsed as a
  /// location message.
  final DecryptedLocation? location;

  /// The MLS group id (raw bytes) this result belongs to — the LOCAL circle
  /// handle (never published; Rule 4 keeps it off the wire).
  final List<int> mlsGroupId;

  /// The MLS epoch the message was authenticated at — meaningful only for
  /// [LocationEventKind.location] (0 otherwise).
  final int epoch;
}

/// An opaque publish-before-apply token for a [PendingAutoCommit].
///
/// Dart-native mirror of `PendingStateRefFfi` — pass it, unmodified, to
/// [CircleService.confirmPendingCommit] or [CircleService.failPendingCommit].
/// Meaningless across a process restart; never persisted, never published.
@immutable
class PendingCommitToken {
  /// Creates a [PendingCommitToken] wrapping the opaque engine token.
  const PendingCommitToken(this.value);

  /// The opaque engine token.
  final BigInt value;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is PendingCommitToken && value == other.value;

  @override
  int get hashCode => value.hashCode;
}

/// A group-evolving commit the engine auto-staged while ingesting a received
/// `kind:445` (a peer `SelfRemove` eviction it decided to auto-commit) that
/// the caller MUST publish then confirm/fail. Dart-native mirror of
/// `CommitToPublishFfi`.
///
/// Publish-before-apply (Rule 13 / security F13): publish
/// [commitEventJson] to the circle's relays, then
/// [CircleService.confirmPendingCommit] on a ≥1-relay ACK, or
/// [CircleService.failPendingCommit] on failure/timeout. NEVER confirm
/// before an ACK, and NEVER drop an entry silently — that re-forks the
/// group the leaver departed.
@immutable
class PendingAutoCommit {
  /// Creates a [PendingAutoCommit].
  const PendingAutoCommit({
    required this.commitEventJson,
    required this.pendingToken,
  });

  /// JSON-serialized kind 445 commit event to publish to the circle's relays.
  final String commitEventJson;

  /// The pending commit to confirm/fail after publishing.
  final PendingCommitToken pendingToken;
}

/// The folded outcome of ingesting one received `kind:445` via
/// [CircleService.decryptLocationCollectingCommits] — the folded
/// location-facing results AND any receive-side auto-commit the caller MUST
/// publish then confirm/fail (Rule 13). Dart-native mirror of
/// `DecryptLocationOutcomeFfi`.
@immutable
class DecryptLocationOutcome {
  /// Creates a [DecryptLocationOutcome].
  const DecryptLocationOutcome({
    required this.results,
    required this.autoCommits,
  });

  /// The folded location-facing results (locations, joins, updates, …).
  final List<LocationEventResult> results;

  /// Receive-side auto-commits the caller MUST publish then confirm/fail.
  final List<PendingAutoCommit> autoCommits;
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
  /// Publishes the gift-wrapped Welcome events and confirms (or rolls back)
  /// the engine's pending group-creation state internally (publish-before-
  /// apply, Rule 13) before returning a [CircleCreationResult] with the
  /// created circle and Welcome delivery counts.
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

  /// Whether [ownPubkeyHex] is still in the MLS roster of the circle with
  /// [mlsGroupId] — the REV-1 leaver-backstop liveness predicate.
  ///
  /// After publishing a `SelfRemove`, the leave flow polls this with the
  /// leaver's OWN pubkey: while it returns `true` the leaver re-issues a fresh
  /// `propose_leave` on each poll; once it returns `false` the eviction has
  /// landed and the local wipe (`complete_leave`) may proceed. Fails SAFE to
  /// `false` when the group is gone or the caller has been evicted, so a
  /// removed leaver stops re-issuing.
  ///
  /// Throws [CircleServiceException] on a genuine infrastructure failure (a
  /// caller in the backstop loop treats a throw conservatively — as "cannot
  /// confirm removal" — never as a removal).
  Future<bool> stillAMember({
    required List<int> mlsGroupId,
    required String ownPubkeyHex,
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
  });

  /// Decrypts / ingests a received kind 445 event through the MLS engine.
  ///
  /// Returns the folded engine results (Dark Matter five-variant taxonomy —
  /// see [LocationEventKind]). A single ingest can yield SEVERAL results (the
  /// engine may release buffered inbound after the outer event), so this
  /// returns a `List` — empty when nothing new resulted (e.g. a duplicate).
  ///
  /// Callers should refresh the circle's member list on
  /// [LocationEventKind.joined], [LocationEventKind.groupUpdate], or
  /// [LocationEventKind.invalidated], and treat
  /// [LocationEventKind.unrecoverable] as a blocked-circle signal (Rule 8 —
  /// see [markCircleBlocked]). The engine owns publish-before-apply for every
  /// commit internally, so callers never need to publish or finalize
  /// anything in reaction to a decrypt result.
  ///
  /// Throws [CircleServiceException] if the event JSON is invalid or the
  /// engine ingest fails hard.
  Future<List<LocationEventResult>> decryptLocation({
    required String eventJson,
  });

  /// Decrypts / ingests a received kind 445 event, identically to
  /// [decryptLocation], but ALSO surfaces any receive-side auto-commit the
  /// engine staged (a peer `SelfRemove` eviction) instead of rolling it back.
  ///
  /// Rule 13 / security F13: for EACH
  /// [DecryptLocationOutcome.autoCommits] entry, publish its
  /// `commitEventJson` to the circle's relays, then
  /// [confirmPendingCommit] on a ≥1-relay ACK (or [failPendingCommit] on
  /// failure/timeout) — exactly like the [PendingAutoCommit] contract
  /// describes. NEVER confirm before an ACK, and NEVER drop an entry
  /// silently.
  ///
  /// The foreground poll receive path (which owns no Rust-side relay handle)
  /// SHOULD call this in place of [decryptLocation]; the live-sync and
  /// background-catch-up planes already publish receive-side auto-commits
  /// in-Rust.
  ///
  /// Throws [CircleServiceException] if the event JSON is invalid or the
  /// engine ingest fails hard.
  Future<DecryptLocationOutcome> decryptLocationCollectingCommits({
    required String eventJson,
  });

  /// Confirms a [PendingAutoCommit] after ≥1 relay acknowledged its publish
  /// (Rule 13). See [decryptLocationCollectingCommits].
  ///
  /// Throws [CircleServiceException] if the confirm fails.
  Future<void> confirmPendingCommit(PendingCommitToken pending);

  /// Rolls back a [PendingAutoCommit] after a publish failure/timeout
  /// (Rule 13). See [decryptLocationCollectingCommits].
  ///
  /// Best-effort: implementations should swallow rollback failures rather
  /// than throw, since the caller has already determined the publish did
  /// not succeed.
  Future<void> failPendingCommit(PendingCommitToken pending);

  /// Records that [mlsGroupId] entered the MLS `Unrecoverable` state (Rule 8).
  ///
  /// Session-scoped (in-memory): the FFI surface does not persist this flag
  /// on the circle row, so it is derived locally from
  /// [LocationEventKind.unrecoverable] results and does not survive an app
  /// restart — a restart re-derives it from the next ingest of an event for
  /// that group, if any arrives. See [isCircleBlocked].
  void markCircleBlocked(List<int> mlsGroupId);

  /// Whether [mlsGroupId] was observed entering the MLS `Unrecoverable`
  /// state this session (see [markCircleBlocked]).
  ///
  /// The UI MUST block send/mutate for a blocked circle (Rule 8).
  bool isCircleBlocked(List<int> mlsGroupId);

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

  // NOTE: `KeyPackage` signing/publishing no longer lives on `CircleService`.
  // The Dark Matter `maintain_key_package` FFI method (via
  // `RelayService.maintainKeyPackage`) is now the ONE publish path
  // (onboarding/login/heal): it owns the decide/reuse-or-mint/publish/record
  // sequence internally. See `key_package_provider.dart`.

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

  // NOTE: `wipeAllStagedCommits` was removed. The Dark Matter engine owns
  // pending-commit state internally (`EpochState::PendingPublish` +
  // `PendingStateRef`) — there is no Haven-owned staged-commit marker to wipe.

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

  /// Sets or clears a member's local petname (contact `display_name`).
  ///
  /// Always overwrites any existing value — it is the always-set petname
  /// editor backing the member detail sheet's "Set Nickname" / "Clear
  /// Nickname" actions (plan D6). Pass `displayName: null` (or an empty
  /// string) to clear the override, reverting display to the
  /// profile-resolved name. Purely local; never leaves the device.
  ///
  /// Throws [CircleServiceException] on a genuine storage failure.
  Future<void> setContactDisplayName({
    required String pubkey,
    String? displayName,
  });

  /// Rotates the relay list for [mlsGroupId] via a MIP-01
  /// `GroupContextExtensions` commit (admin-only).
  ///
  /// Stages the commit, publishes the resulting `kind:445` evolution event to
  /// the **union** of the circle's current relays and [newRelays] — so a
  /// member that only listens on a relay being removed still receives the
  /// commit before it stops polling that relay. On publish success, confirms
  /// the engine's pending state (which also re-syncs the admin's own
  /// `circle.relays` to [newRelays]). On publish failure, rolls the pending
  /// state back and rethrows.
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

  /// KeyPackage event as JSON string (kind 30443, or legacy kind 443 from a
  /// not-yet-updated peer — see the F11 "needs to update" detection in
  /// `add_member_page.dart` / `create_circle_page.dart`).
  final String eventJson;

  /// Inbox relay URLs for Welcome delivery (kind 10050).
  final List<String> relays;

  /// Fallback NIP-65 relay URLs (kind 10002), used when inbox relays
  /// are unavailable for Welcome delivery.
  final List<String> nip65Relays;
}
