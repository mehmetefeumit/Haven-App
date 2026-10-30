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
import 'package:haven/src/rust/api.dart'
    show
        LeaveStatusFfi,
        LocationPublishFfi,
        PublishStatusFfi,
        RecoveryCauseFfi,
        ReinviteResultFfi,
        SealedLocationFfi,
        SkipReasonFfi;
import 'package:haven/src/utils/log_alias.dart';

/// Exception thrown when circle operations fail.
class CircleServiceException implements Exception {
  /// Creates a [CircleServiceException] with the given message.
  const CircleServiceException(this.message);

  /// The error message.
  final String message;

  @override
  String toString() => 'CircleServiceException: $message';
}

/// Thrown when creating a circle or accepting an invitation would push the
/// account past `kMaxCirclesPerAccount` (`publish_stagger.dart`).
///
/// Its own type because it is a POLICY refusal and not a failure: the caller
/// must name the limit and the remedy (leave a circle) instead of the generic
/// "please try again" copy, and only a distinct type lets it do that without
/// reading an error string.
class CircleRosterFullException extends CircleServiceException {
  /// Creates a [CircleRosterFullException].
  const CircleRosterFullException() : super('Circle roster is full');
}

/// Thrown when a create or an invite is refused because an invitee lists no
/// inbox relay a Welcome could reach: nothing was made.
///
/// Its own type because the remedy is the invitee's (publish where they
/// receive invitations), not a retry of the same request as it stands.
class CircleInviteesUnreachableException extends CircleServiceException {
  /// Creates a [CircleInviteesUnreachableException].
  const CircleInviteesUnreachableException()
    : super('An invitee cannot receive invitations');
}

/// Thrown when an invitation can never be accepted on this device: its
/// Welcome was made for a KeyPackage this device no longer holds (the storage
/// reset, or a replaced package), is invalid, or was already processed.
///
/// Its own type because the remedy is the inviter's, not a retry: the caller
/// asks the user to get a new invitation. The core has already declined the
/// invitation, so it is gone from the pending list.
class InvitationNeedsNewInviteException extends CircleServiceException {
  /// Creates an [InvitationNeedsNewInviteException].
  const InvitationNeedsNewInviteException()
    : super('Invitation needs a new invite');
}

/// Thrown when accepting an invitation would replace a circle this device
/// still holds (a removal it never saw, or a split circle), which the engine
/// does only on the user's explicit confirmation
/// ([CircleService.rejoinOffersForInvitation]). The invitation stays pending.
class InvitationRejoinConfirmationRequiredException
    extends CircleServiceException {
  /// Creates an [InvitationRejoinConfirmationRequiredException].
  const InvitationRejoinConfirmationRequiredException()
    : super('Invitation would replace a held circle');
}

/// A replacement Welcome awaiting the user's consent: joining it discards
/// this device's copy of the circle [mlsGroupId].
@immutable
class RejoinOffer {
  /// Creates a [RejoinOffer].
  const RejoinOffer({
    required this.mlsGroupId,
    required this.circleName,
    required this.localStateToken,
  });

  /// The circle it would join again.
  final List<int> mlsGroupId;

  /// The local display name of that circle on this device.
  final String circleName;

  /// The token of the local copy the consent discards, handed back unchanged
  /// to [CircleService.confirmGroupRejoin]. Never logged.
  final List<int> localStateToken;
}

/// The local user's own invitation state for a circle.
///
/// Never a statement about a peer: processing an MLS Welcome emits nothing
/// on the wire and produces no artifact any other device can observe, so no
/// device can tell whether anyone else ever joined.
enum MembershipStatus {
  /// This device has been invited but has not accepted yet.
  pending,

  /// This device accepted and holds live MLS state for the circle.
  accepted,

  /// This device declined the invitation.
  declined,
}

/// Whether this device's encryption engine holds a circle live.
enum CircleEngineState {
  /// The circle's encrypted state loaded; it can send and receive.
  live,

  /// The circle's encrypted state failed to load on this device. It still
  /// exists and may load on a retry; it neither sends nor receives meanwhile.
  quarantined,

  /// An admin disbanded the circle: nothing is sent or received for it again,
  /// and it can only be left.
  disbanded,

  /// MDK halted the circle on this device: it neither sends nor receives
  /// until an admin removes this device and adds it back. Persisted, so it
  /// holds across a restart.
  unrecoverable,
}

/// What the user needs to know first about a circle that is not sharing, in
/// the core's worst-first order. Mirrors `RecoveryCauseFfi` so no FFI enum
/// leaks above the service layer.
enum CircleRecoveryCause {
  /// An admin disbanded the circle.
  disbanded,

  /// MDK halted the circle on this device.
  unrecoverable,

  /// The circle failed to load on this device.
  quarantined,

  /// The circle's routing id is another circle's on this device too.
  routingCollision,

  /// This device asked to leave the circle.
  leaving,

  /// This device cannot read its peers: history walks the relays answered in
  /// full brought back nothing that moves it.
  stalled,

  /// A removal the user asked for was dropped unmade and a member it named is
  /// still in the circle.
  removalUnmade,

  /// The removal of a member who left is due and not made yet.
  departureDue,

  /// A change of the circle's relays waits for the app's foreground.
  awaitsForeground,

  /// A change of the circle awaits a relay's acknowledgement.
  awaitingRelays,

  /// A change a relay acknowledged awaits its confirm.
  acknowledged,

  /// A commit is staged in the circle with no record.
  stagedWithoutRecord,

  /// Stored input still holds the circle's sends.
  storedInput,
}

/// The [CircleRecoveryCause] of a recovery read, by variant only (Rule 8).
///
/// Exhaustive with no `_`: a cause added upstream fails to compile here.
CircleRecoveryCause circleRecoveryCauseOf(RecoveryCauseFfi cause) =>
    switch (cause) {
      RecoveryCauseFfi.disbanded => CircleRecoveryCause.disbanded,
      RecoveryCauseFfi.unrecoverable => CircleRecoveryCause.unrecoverable,
      RecoveryCauseFfi.quarantined => CircleRecoveryCause.quarantined,
      RecoveryCauseFfi.routingCollision => CircleRecoveryCause.routingCollision,
      RecoveryCauseFfi.leaving => CircleRecoveryCause.leaving,
      RecoveryCauseFfi.stalled => CircleRecoveryCause.stalled,
      RecoveryCauseFfi.removalUnmade => CircleRecoveryCause.removalUnmade,
      RecoveryCauseFfi.departureDue => CircleRecoveryCause.departureDue,
      RecoveryCauseFfi.awaitsForeground => CircleRecoveryCause.awaitsForeground,
      RecoveryCauseFfi.awaitingRelays => CircleRecoveryCause.awaitingRelays,
      RecoveryCauseFfi.acknowledged => CircleRecoveryCause.acknowledged,
      RecoveryCauseFfi.stagedWithoutRecord =>
        CircleRecoveryCause.stagedWithoutRecord,
      RecoveryCauseFfi.storedInput => CircleRecoveryCause.storedInput,
    };

/// Whether a fetched KeyPackage can be invited, by MDK's own admission check.
enum KeyPackageAdmission {
  /// It can be invited.
  admissible,

  /// It comes from an older Haven; the person must update first.
  needsUpdate,

  /// It cannot be used (for example incomplete or malformed); a fresh one is
  /// published when the person next opens Haven.
  unusable,
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
    this.engineState = CircleEngineState.live,
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

  /// Whether this device's engine holds the circle live.
  final CircleEngineState engineState;

  /// Whether the circle's encrypted state failed to load on this device.
  bool get isQuarantined => engineState == CircleEngineState.quarantined;

  /// Whether an admin disbanded the circle.
  bool get isDisbanded => engineState == CircleEngineState.disbanded;

  /// Whether MDK halted the circle on this device.
  bool get isUnrecoverable => engineState == CircleEngineState.unrecoverable;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is Circle &&
          runtimeType == other.runtimeType &&
          listEquals(mlsGroupId, other.mlsGroupId);

  @override
  int get hashCode => Object.hashAll(mlsGroupId);

  @override
  String toString() => 'Circle(members: ${magnitudeBucket(members.length)})';
}

/// Represents a member of a circle.
@immutable
class CircleMember {
  /// Creates a new [CircleMember].
  const CircleMember({
    required this.pubkey,
    required this.npub,
    required this.isAdmin,
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
      'CircleMember(${logAliasHandle(LogAliasClass.peer, pubkey)})';
}

/// Which section of the member picker a directory row belongs to (plan
/// §6.1/§7.2, P3). Mirrors the FFI `DirectoryTierFfi` as a Dart-level type so
/// no FFI enum leaks above the service layer.
///
/// A tier is a claim about ROSTER PROVENANCE and nothing more: this pubkey
/// is (or recently was) on the member list of a circle on this device,
/// placed there by an MLS-authenticated commit. It says nothing about
/// whether that person accepted, joined, or is active — none of which Haven
/// can observe — so UI copy built on it must not either.
enum DirectoryTier {
  /// On the member list of a circle on this device, as of the last
  /// reconcile.
  current,

  /// Not on any current member list; retained for at most the directory
  /// retention window (3 days) after the last day they were.
  recent,
}

/// One row of the local member directory (plan §6.1/§7.2, P3).
///
/// A pure local read of `circles.db` — no relay traffic, no network. The
/// directory is the only source of WHO the picker offers and WHICH TIER;
/// names and pictures still come from the kind-0 profile cache, and local
/// petnames from the contacts table.
@immutable
class DirectoryEntry {
  /// Creates a [DirectoryEntry].
  const DirectoryEntry({
    required this.pubkeyHex,
    required this.npub,
    required this.tier,
  });

  /// Lowercase-hex Nostr identity key.
  final String pubkeyHex;

  /// The same key in NIP-19 bech32 (`npub1…`) — the form every
  /// anti-impersonation surface renders.
  final String npub;

  /// Which picker section this row belongs to.
  final DirectoryTier tier;

  // The day bucket a co-member's row is ranked/retired by stays in Rust —
  // ordering is the ranked read's `ORDER BY`, and nothing on this side reads
  // or renders by it, so it is deliberately never exported over the FFI
  // (`DirectoryEntryFfi`'s doc, `rust_builder/src/api.rs`): exporting it would
  // hand this layer a departure-cohort timestamp with no reader to justify
  // it.

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DirectoryEntry &&
          runtimeType == other.runtimeType &&
          pubkeyHex == other.pubkeyHex &&
          npub == other.npub &&
          tier == other.tier;

  @override
  int get hashCode => Object.hash(pubkeyHex, npub, tier);

  @override
  String toString() =>
      'DirectoryEntry(${logAliasHandle(LogAliasClass.peer, pubkeyHex)}, '
      'tier: $tier)';
}

/// Result of creating a circle.
///
/// `CircleService.createCircle` creates the circle through the fanout driver,
/// which records each founding Welcome and sends it from that record, so this
/// result carries counts only — no Welcome event reaches Dart (mirrors
/// [AddMemberResult]).
@immutable
class CircleCreationResult {
  /// Creates a new [CircleCreationResult].
  const CircleCreationResult({
    required this.circle,
    required this.welcomesSent,
    required this.welcomesTotal,
    this.unsentNpubs = const [],
  });

  /// The created circle.
  final Circle circle;

  /// Number of founding Welcomes an inbox relay acknowledged during the
  /// call.
  final int welcomesSent;

  /// Total Welcomes produced (one per invited member).
  final int welcomesTotal;

  /// The invitees (`npub1…`) whose founding Welcome no relay acknowledged
  /// during the call. Each is still owed: later foreground drives send it
  /// again from its record, for a day.
  final List<String> unsentNpubs;
}

/// Result of adding members to an existing circle.
@immutable
class AddMemberResult {
  /// Creates a new [AddMemberResult].
  const AddMemberResult({
    required this.delivery,
    required this.welcomesDelivered,
    required this.welcomesTotal,
    this.reinviteOwed = false,
  });

  /// What became of the invite's commit.
  final ChangeDelivery delivery;

  /// How many Welcomes an inbox relay acknowledged so far. The rest are sent
  /// again by the driver, each from a record of its own, until a relay takes
  /// it or it expires.
  final int welcomesDelivered;

  /// Total Welcomes the invite carries (one per invitee).
  final int welcomesTotal;

  /// The invite was applied with no Welcome left to deliver: the invitees must
  /// be removed and added again.
  final bool reinviteOwed;
}

/// What became of a circle change asked of the fanout driver.
enum ChangeDelivery {
  /// A relay acknowledged the commit and the engine applied it — or the
  /// circle already was as asked, and nothing needed to be sent.
  applied,

  /// Not made yet, and not refused: staged and sent again until a relay
  /// acknowledges it, or queued behind what the circle is still resolving
  /// (made later, or retired at the next open with a notice). Never an error:
  /// it shows through the circle's deferred-send cause.
  awaitingRelays,

  /// Not made: refused before the engine was asked, refused by every relay,
  /// set aside by the engine, or staged and never sent.
  rejected,
}

/// What became of one re-invite MDK owed. None of these is made: the one on
/// its way says so in its name.
enum ReinviteDelivery {
  /// Staged with a fresh package: awaiting its relays.
  awaitingRelays,

  /// Still owed, and looked for again at its next lookup: queued, not due,
  /// its circle not settled, no admissible package, no inbox relay a Welcome
  /// could reach, or not made this time.
  stillOwed,

  /// Given up: the user invites again. The circle's change notice carries
  /// the re-invite owed until the user does.
  needsReinvite,

  /// Ended by MDK: no member any more, the invitees already in, or a conflict.
  ended,
}

/// The [ReinviteDelivery] of a re-invite result, by variant only (Rule 8).
///
/// Exhaustive with no `_`: a result added upstream fails to compile here.
ReinviteDelivery reinviteDeliveryOf(ReinviteResultFfi result) =>
    switch (result) {
      ReinviteResultFfi.reissuedAwaitingRelays =>
        ReinviteDelivery.awaitingRelays,
      ReinviteResultFfi.queued ||
      ReinviteResultFfi.notDue ||
      ReinviteResultFfi.unsettled ||
      ReinviteResultFfi.keyPackageMissing ||
      ReinviteResultFfi.noInbox ||
      ReinviteResultFfi.unmade => ReinviteDelivery.stillOwed,
      ReinviteResultFfi.gaveUp => ReinviteDelivery.needsReinvite,
      ReinviteResultFfi.ended => ReinviteDelivery.ended,
    };

/// Where a leave the user asked for stands.
enum LeaveDelivery {
  /// Left on this device: the circle is gone from it.
  left,

  /// Asked for and carried on at every wake until it ends: nothing is shared
  /// with the circle meanwhile. Never an error: it shows through the circle's
  /// deferred-send cause.
  leaving,

  /// Not asked for: refused for good, the leave's intent ended.
  notMade,
}

/// The [LeaveDelivery] of a leave status, by variant only (Security Rule 8).
///
/// Exhaustive with no `_`: a status added upstream fails to compile here.
LeaveDelivery leaveDeliveryOf(LeaveStatusFfi status) => switch (status) {
  // The circle is not on this device: nothing of it is left to leave.
  LeaveStatusFfi.completed ||
  LeaveStatusFfi.circleNotFound => LeaveDelivery.left,
  // The intent stands, and the next wake carries it on: a proposal no peer
  // has committed yet, a circle not stable yet or a failure no variant names
  // (`pending`, no wait named), an admin step only the app in front makes, or
  // input the engine holds first.
  LeaveStatusFfi.proposed ||
  LeaveStatusFfi.pending ||
  LeaveStatusFfi.foregroundOnly ||
  LeaveStatusFfi.engineHeld => LeaveDelivery.leaving,
  // The driver keeps the intent and steps down first itself now, so it no
  // longer answers `adminMustStepDown`; the bridge still maps the error to it,
  // so it stays mapped.
  LeaveStatusFfi.adminMustStepDown ||
  LeaveStatusFfi.notLeaving => LeaveDelivery.notMade,
};

/// The [ChangeDelivery] of a driver status, by variant only (Security Rule 8).
///
/// Exhaustive with no `_` on purpose: a status added upstream fails to compile
/// here rather than land in an arm that shows it as made.
ChangeDelivery changeDeliveryOf(PublishStatusFfi status) => switch (status) {
  PublishStatusFfi.confirmed => ChangeDelivery.applied,
  PublishStatusFfi.unresolved ||
  PublishStatusFfi.queued => ChangeDelivery.awaitingRelays,
  PublishStatusFfi.rolledBack ||
  PublishStatusFfi.stale ||
  PublishStatusFfi.unrecorded ||
  PublishStatusFfi.refused => ChangeDelivery.rejected,
};

/// What [CircleService.ingestEvent] did with one received event.
@immutable
class IngestResult {
  /// Creates an [IngestResult].
  const IngestResult({required this.results, required this.held});

  /// What the event and the drives it made handed back, each routed by its
  /// own group id.
  final List<LocationEventResult> results;

  /// Not taken in yet: the engine holds it, and it is fetched again.
  final bool held;
}

/// Represents a pending invitation to join a circle.
@immutable
class Invitation {
  /// Creates a new [Invitation].
  const Invitation({
    required this.mlsGroupId,
    required this.circleName,
    required this.inviterPubkey,
    required this.inviterNpub,
    required this.invitedAt,
  });

  /// MLS group identifier.
  final List<int> mlsGroupId;

  /// Name of the circle.
  final String circleName;

  /// Public key of the person who invited you.
  final String inviterPubkey;

  /// The inviter's public key in NIP-19 bech32 form (`npub1...`).
  ///
  /// Carried alongside [inviterPubkey] rather than replacing it: the hex is
  /// the profile-cache key and the identity comparison, the npub is the only
  /// form a user can check against what the inviter actually handed them —
  /// which is exactly what deciding whether to join a stranger's
  /// live-location circle requires.
  final String inviterNpub;

  /// When the invitation was received.
  final DateTime invitedAt;
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
    this.receivedAt,
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

  /// When THIS device wrote the row this location was read back from — the
  /// `last_known_locations.updated_at` the store ranks it by.
  ///
  /// Set only by [CircleService.snapshotLastKnownForCircle]; `null` for a
  /// freshly decrypted message, whose receipt instant is the decrypt itself.
  /// Carried across so a rehydrated row keeps the rank the store gave it: a
  /// cache that re-stamped it with "now" would rank a future-dated row ABOVE
  /// the store's own rank, and the two layers would then accept different
  /// fixes.
  final DateTime? receivedAt;

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

  /// MDK halted the group: its circle reads
  /// [CircleEngineState.unrecoverable] from then on, which blocks send and
  /// mutate for it (Rule 8).
  unrecoverable,
}

/// One folded engine result from decrypting/ingesting a single `kind:445`
/// event. A single ingest can yield SEVERAL of these — the engine's internal
/// convergence may release buffered inbound after the outer event — so
/// [IngestResult.results] is a `List`.
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

/// What a seal made of a fix ([CircleService.sealLocation]).
///
/// Sealed so the compiler, not a reviewer, holds every call site to handling
/// a send the core held: that is a state, never a failure.
@immutable
sealed class LocationSeal {
  /// Const base constructor.
  const LocationSeal({required this.replayed});

  /// What the seal's drives handed back, each routed by its own group id.
  /// Every location in it is already stored.
  final List<LocationEventResult> replayed;
}

/// Sealed and recorded; [CircleService.publishSealedLocation] sends it.
@immutable
final class LocationSealed extends LocationSeal {
  /// Creates a [LocationSealed].
  const LocationSealed(this.sealed, {required super.replayed});

  /// The sealed event, which only the core sends.
  final SealedLocationFfi sealed;
}

/// Nothing was sealed: something holds the circle's sends — a change
/// awaiting its relays, a departure owed, a leave — or the core asked nothing
/// of the engine. Every caller treats either as a deferral; the next tick
/// seals again.
@immutable
final class LocationSendHeld extends LocationSeal {
  /// Creates a [LocationSendHeld].
  const LocationSendHeld({required super.replayed});
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
  /// Through the fanout driver: a delivery record is written for each
  /// founding Welcome before this returns, and each is sent from it to its
  /// invitee's inbox relays (kind 10050) alone until one acknowledges it; a
  /// member with none fails the creation closed, before anything is made.
  /// Returns a [CircleCreationResult] with the created circle and how many
  /// Welcomes were acknowledged during the call.
  ///
  /// Throws [CircleRosterFullException] when the account already holds
  /// `kMaxCirclesPerAccount` circles — checked before anything is staged, so a
  /// refusal leaves no MLS group and nothing on the wire. Throws
  /// [CircleServiceException] if creation fails.
  Future<CircleCreationResult> createCircle({
    required List<int> identitySecretBytes,
    required List<KeyPackageData> memberKeyPackages,
    required String name,
    required CircleType circleType,
    String? description,
    List<String>? relays,
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
  /// Throws [CircleRosterFullException] when the account already holds
  /// `kMaxCirclesPerAccount` circles — checked before the held Welcome is
  /// ingested, so the invitation stays pending and acceptable once the user
  /// leaves a circle. Throws [InvitationNeedsNewInviteException] when the
  /// invitation can never be accepted on this device (it is declined), and
  /// [CircleServiceException] if acceptance otherwise fails.
  Future<Circle> acceptInvitation(List<int> mlsGroupId);

  /// Declines an invitation to join a circle.
  ///
  /// Updates the membership status to [MembershipStatus.declined].
  /// The circle will no longer appear in [getVisibleCircles].
  ///
  /// Throws [CircleServiceException] if declining fails.
  Future<void> declineInvitation(List<int> mlsGroupId);

  /// The replacement offers of the invitation [invitationId] that
  /// [acceptInvitation] answered with an
  /// [InvitationRejoinConfirmationRequiredException]. Empty when none is held
  /// any more.
  ///
  /// Throws [InvitationNeedsNewInviteException] when the core declined them
  /// (an author who is not the inviter shown, or a circle this device is
  /// leaving), and [CircleServiceException] if the read fails.
  Future<List<RejoinOffer>> rejoinOffersForInvitation(List<int> invitationId);

  /// The user's consent to [offer]: the circle is joined again, and this
  /// device's copy of it is discarded.
  ///
  /// Throws [InvitationRejoinConfirmationRequiredException] when the local
  /// copy moved since [offer] was read — nothing changed; read the offers
  /// again — [InvitationNeedsNewInviteException] when the offer is gone, and
  /// [CircleServiceException] if the join otherwise fails.
  Future<Circle> confirmGroupRejoin(List<int> invitationId, RejoinOffer offer);

  /// Declines every replacement offer of the invitation [invitationId], and
  /// the invitation with them. Nothing is sent.
  ///
  /// Throws [CircleServiceException] if declining fails.
  Future<void> declineGroupRejoin(List<int> invitationId);

  /// Leaves a circle through the fanout driver: the intent is written first,
  /// and from then nothing is shared with the circle on any plane. A leaving
  /// admin hands the circle on and steps down first; the leave's proposal
  /// follows, and the leave ends on this device once a peer commits it or its
  /// bound passes — carried on at every wake ([LeaveDelivery.leaving]) by the
  /// leaver backstop, never by a loop here.
  ///
  /// Throws [CircleServiceException] when the driver answers an error that
  /// is no typed status.
  Future<LeaveDelivery> leaveCircle({required List<int> mlsGroupId});

  /// Leaves a circle an admin disbanded ([Circle.isDisbanded]): nothing is
  /// sent, since no member receives anything for it again, and this device's
  /// copy is deleted with the disband's record kept.
  ///
  /// Throws [CircleServiceException] if the deletion fails.
  Future<void> leaveDisbandedCircle({required List<int> mlsGroupId});

  /// Removes [memberPubkeyHex] from the circle identified by [mlsGroupId].
  ///
  /// Intended for admin-initiated removal — e.g. evicting a member who
  /// has gone quiet, or cleaning up a stale invite. Admins leaving
  /// themselves go through the MIP-03 `LeavePlan` path (self-demote
  /// then SelfRemove); this method is for removing **other** members.
  ///
  /// Through the fanout driver: the commit is staged under a durable record
  /// and sent until a relay acknowledges it. Returns what became of it;
  /// [ChangeDelivery.awaitingRelays] is not a failure.
  ///
  /// Throws [CircleServiceException] only when the driver could not be asked.
  Future<ChangeDelivery> removeMember({
    required List<int> mlsGroupId,
    required String memberPubkeyHex,
  });

  /// Adds new members to an already-created circle (admin only).
  ///
  /// Through the fanout driver: the invite is staged under a record of its
  /// own and driven, and each Welcome goes from a record of its own to its
  /// invitee's inbox relays once a relay takes the commit. Welcomes are sent
  /// ONLY after a relay took the commit, so a rolled-back add never leaves a
  /// dangling invitation.
  ///
  /// Throws [CircleServiceException] only when the driver could not be asked.
  Future<AddMemberResult> addMember({
    required List<int> mlsGroupId,
    required List<KeyPackageData> memberKeyPackages,
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

  /// Seals a fix for the circle and records it, after the circle's records
  /// are driven: from a leave's intent on — or while a change awaits its
  /// relays, or a departure is owed — nothing is sealed ([LocationSendHeld]).
  ///
  /// Throws [CircleServiceException] when the driver answers an error that
  /// is no typed outcome.
  Future<LocationSeal> sealLocation({
    required List<int> mlsGroupId,
    required double latitude,
    required double longitude,
  });

  /// Sends [seal] once, to the relays its record names, and ends its record
  /// whatever was answered.
  ///
  /// Throws [CircleServiceException] when the driver could not be asked.
  Future<LocationPublishFfi> publishSealedLocation(LocationSealed seal);

  /// Ingests a received kind-445 through the fanout driver: the engine takes
  /// it in, records and drives whatever it stages on the way (a receive-side
  /// auto-commit included), and every location it hands back is already
  /// stored. A [IngestResult.held] event is fetched again: whoever polled it
  /// does not move past it (Security Rule 12).
  ///
  /// Throws [CircleServiceException] if the event JSON is invalid or the
  /// engine ingest fails hard.
  Future<IngestResult> ingestEvent({required String eventJson});

  // REMOVED: BOTH of Dart's sync-cursor advances — the group one that took an
  // inbound kind:445's `created_at`, and the inbox one that took a kind:1059
  // gift wrap's (deleted 2026-08; neither name is spelled out here on purpose,
  // so the CI guard can ban the tokens outright rather than parse comments).
  //
  // Both raised a persisted REQ floor from a remotely-chosen `created_at` that
  // nothing on the receive path authenticates, which is a lever for pushing a
  // victim's floor past legitimate events — permanently, and across restarts.
  //
  // The gift-wrap one was the cheaper of the two to exploit: a kind:1059 is
  // routed by a `#p` tag carrying the recipient's PUBLIC key (published in
  // their kind:0 profile, their relay lists and every KeyPackage), is authored
  // by a throwaway ephemeral key by construction, and is peeled with NIP-59
  // alone — no MLS state, nothing binding the wrapper timestamp to its payload.
  // So anyone who knows a user's npub could mint a wrap that peels cleanly at
  // any `created_at`. Dated in the FUTURE it parked the cursor above the wall
  // clock, and since the derived floor is capped at `now`, every later inbox
  // REQ floor was pinned at `now` — where NIP-59's mandatory backdating (up to
  // 48h) makes even a wrap published this second invisible. Invitations simply
  // stopped arriving.
  //
  // Dart now has NO sync-cursor write path of any kind. Both cursors are
  // advanced in haven-core, from a LOCAL clock reading taken when an
  // observation window opened — the catch-up fetch's open time, and each REQ's
  // own open time redeemed on that REQ's EOSE (`haven_core::relay::cursor`,
  // "the governing asymmetry"). Do not reintroduce one: a "high-water mark of
  // processed events" is exactly the shape that was removed, in both planes.
  // Kept deleted by `scripts/ci/check_no_event_timestamp_cursor_advance.sh`.

  // NOTE: `KeyPackage` signing/publishing no longer lives on `CircleService`.
  // The Dark Matter `maintain_key_package` FFI method (via
  // `RelayService.maintainKeyPackage`) is now the ONE publish path
  // (onboarding/login/heal): it owns the decide/reuse-or-mint/publish/record
  // sequence internally. See `key_package_provider.dart`.

  // NOTE: `signRelayListEvent` was removed. The privacy-toggle-aware
  // flow lives on `RelayPreferencesService.buildRelayListPublish`,
  // which atomically gates on the user's publish toggle and resolves
  // targets. Exposing a parallel sign-only method left a way to publish
  // kind 10050/10002 without consulting the toggle. New code MUST use
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
  /// Deletes both encrypted database files (`circles-v2.db` and
  /// `session-v2.sqlite`, plus WAL/SHM/journal sidecars), then removes both
  /// keyring keys and this identity's part of the storage reset (any notice
  /// still owed, and the record that its preferences were cleared). Permanent
  /// and irreversible — call only on identity deletion.
  ///
  /// The caller MUST have already called [closeAndInvalidate] to drop the
  /// SQLite handle before this; otherwise file deletion races an open fd.
  Future<void> wipeAllMlsState();

  /// Dismisses the one-time storage-reset notice: deletes the marker the
  /// reset left, which lifts the core's hold on relay-list publishing.
  ///
  /// Throws [CircleServiceException] if the marker cannot be removed; the
  /// notice is then owed again next launch.
  Future<void> acknowledgeStorageReset();

  /// Whether the fetched KeyPackage event [keyPackageJson] can be invited into
  /// the circle [mlsGroupId], or into a new circle when it is `null`.
  ///
  /// Throws [CircleServiceException] if the check itself fails.
  Future<KeyPackageAdmission> checkMemberKeyPackage({
    required String keyPackageJson,
    List<int>? mlsGroupId,
  });

  /// Retries loading a circle whose encrypted state failed to load
  /// ([CircleEngineState.quarantined]). Returns whether it is live now.
  ///
  /// Throws [CircleServiceException] if the retry itself fails.
  Future<bool> retryQuarantinedCircle(List<int> mlsGroupId);

  /// What the user needs to know first about [circle], worst first; `null`
  /// when nothing holds it. One standing read: nothing is sent.
  ///
  /// Throws [CircleServiceException] when the read fails.
  Future<CircleRecoveryCause?> circleRecovery(Circle circle);

  /// The members (hex) a removal the user asked for named, dropped unmade,
  /// that are still in the circle [mlsGroupId]: the people "Remove again" is
  /// offered for. Never logged.
  ///
  /// Throws [CircleServiceException] when the circle store cannot be read: an
  /// empty answer would hide a member the user tried to remove.
  Future<List<String>> unmadeRemovalMembers(List<int> mlsGroupId);

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

  /// The local member directory in picker order: current co-members first,
  /// then people who shared a circle within the retention window, each block
  /// newest-shared first before this layer re-sorts by name (plan §6.1/§7.2,
  /// P3).
  ///
  /// A pure local read — no relay traffic, no network. Deletes every row past
  /// the retention window before selecting, so opening the picker is enough
  /// to keep the three days honest on a device that has seen no membership
  /// change since the row was written. [now] defaults to [DateTime.now] when
  /// null.
  ///
  /// Throws [CircleServiceException] on a genuine storage failure.
  Future<List<DirectoryEntry>> rankedDirectoryMembers({DateTime? now});

  /// Refreshes the member directory from the union of current co-members
  /// across every visible circle, then sweeps expired rows.
  ///
  /// Returns `false` when the refresh DEFERRED because a circle's membership
  /// commit is still in flight — nothing was written and nothing was purged,
  /// and the caller should simply read the directory as it stands. Every
  /// membership change already refreshes the directory from inside Rust
  /// (plan §5.5); this exists so a caller can bring a directory that has not
  /// seen one of those changes since this feature shipped up to date. [now]
  /// defaults to [DateTime.now] when null.
  ///
  /// Throws [CircleServiceException] on a genuine storage/roster-read
  /// failure. The directory is left untouched on any error.
  Future<bool> reconcileMemberDirectory({DateTime? now});

  /// Every locally-saved contact petname, keyed by pubkey (hex).
  ///
  /// The directory's only source of a petname for a tier-[DirectoryTier.recent]
  /// person: unlike a current co-member, they have no [CircleMember] row to
  /// carry [CircleMember.displayName] from. Purely local; never touches a
  /// relay.
  ///
  /// Throws [CircleServiceException] on a genuine storage failure.
  Future<Map<String, String>> allContactDisplayNames();

  /// Returns the local petname saved for [pubkey], or `null` when none is.
  ///
  /// The read half of [setContactDisplayName], for the surfaces that show a
  /// person Haven has no [CircleMember] row for — a pending invitation's
  /// inviter is a stranger until Accept, but may still be someone the user
  /// nicknamed in another circle. Purely local; never touches a relay.
  ///
  /// Throws [CircleServiceException] on a genuine storage failure.
  Future<String?> getContactDisplayName({required String pubkey});

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
  /// `GroupContextExtensions` commit (admin-only), through the fanout driver:
  /// the commit is staged under a durable record and sent until a relay
  /// acknowledges it. Returns what became of it;
  /// [ChangeDelivery.awaitingRelays] is not a failure.
  ///
  /// [newRelays] must be non-empty, `wss://` (or a debug loopback URL in
  /// test builds), credential-free, and at most 16 entries (the engine's
  /// routing bound). Admin
  /// authorization is enforced by MDK against live MLS state.
  ///
  /// Throws [CircleServiceException] only when the driver could not be asked.
  Future<ChangeDelivery> updateCircleRelays({
    required List<int> mlsGroupId,
    required List<String> newRelays,
  });

  /// Repairs a circle whose message delivery has stopped, by a self-update of
  /// this device's own leaf: a commit with an `UpdatePath`, which any member
  /// may make. Applying it moves the circle to a new epoch with new keys, so
  /// a peer whose messages this device could no longer decrypt becomes
  /// readable again once they have applied it.
  ///
  /// Fetches once for the circle BEFORE asking the core, so a departure
  /// proposal sitting on a relay becomes a clean [EpochRepairSkipped] decline
  /// instead of a same-epoch race. [selfPubkeyHex] is what that fetch is
  /// scoped by (`RelayService.runCatchup`); this service holds no identity of
  /// its own to read it from.
  ///
  /// Foreground only (Rule 14): never call this from a background isolate.
  /// Enforced by `scripts/ci/check_epoch_repair_isolation.sh`.
  ///
  /// Returns a typed [EpochRepairResult]; a declined repair is a normal answer,
  /// not a failure. Throws [CircleServiceException] only on a real failure, and
  /// never with raw engine text (Security Rule 8).
  Future<EpochRepairResult> repairCircleEpoch(
    Circle circle, {
    required String selfPubkeyHex,
  });
}

/// What [CircleService.repairCircleEpoch] did.
///
/// Sealed so the compiler owns exhaustiveness at every call site — the three
/// outcomes route to different user-facing copy, and collapsing them would put
/// a user in a retry loop that cannot succeed.
sealed class EpochRepairResult {
  /// Creates an [EpochRepairResult].
  const EpochRepairResult();
}

/// The repair committed: the self-update is published and applied locally.
///
/// Peers apply it on their own next epoch pass, so delivery does not recover
/// the instant this returns — copy must not promise that it does.
final class EpochRepairApplied extends EpochRepairResult {
  /// Creates an [EpochRepairApplied].
  const EpochRepairApplied();
}

/// A gate declined the repair; nothing was staged and nothing changed.
final class EpochRepairSkipped extends EpochRepairResult {
  /// Creates an [EpochRepairSkipped] carrying the gate that declined.
  const EpochRepairSkipped(this.reason);

  /// Which gate declined. [SkipReasonFfi.epochUnrecoverable] is terminal for
  /// this device; every other reason is retryable.
  final SkipReasonFfi reason;

  /// Whether waiting could change this answer.
  ///
  /// `false` for the reason that never clears on its own, so the UI can
  /// offer a different remedy instead of a retry — and, in the banner, disable
  /// the control rather than invite a loop that cannot succeed.
  ///
  /// An exhaustive `switch` with NO `_` on purpose. A `!=` chain fails OPEN: a
  /// new terminal reason added upstream would silently classify as retryable
  /// and be offered as a retry. This way it fails to COMPILE instead.
  bool get isRetryable => switch (reason) {
    SkipReasonFfi.epochUnrecoverable => false,
    SkipReasonFfi.epochNotStable ||
    SkipReasonFfi.recentEpochChange ||
    SkipReasonFfi.recentInboundTraffic ||
    SkipReasonFfi.pendingProposal ||
    SkipReasonFfi.rotatedRecently => true,
  };
}

/// The repair commit is staged and recorded, sent again until a relay
/// acknowledges it: not applied yet, and not a failure.
final class EpochRepairAwaitingRelays extends EpochRepairResult {
  /// Creates an [EpochRepairAwaitingRelays].
  const EpochRepairAwaitingRelays();
}

/// The circle is send-gated, so nothing was staged.
///
/// What still holds the circle's sends is the driver's to resolve — for a
/// routing collision, only leaving this circle itself does; leaving the other
/// colliding circle does not release it.
final class EpochRepairDeferred extends EpochRepairResult {
  /// Creates an [EpochRepairDeferred].
  const EpochRepairDeferred();
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

  /// The account the KeyPackage was verified to belong to (`npub1…`): its
  /// signer and MLS credential, as `fetchKeyPackage` returns it. Passed back
  /// on create/add, where Rust refuses a package it does not name.
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
