/// Abstract interface for circle management services.
///
/// Provides a platform-agnostic API for managing circles (groups of trusted
/// contacts for location sharing). This abstraction allows for easy testing
/// with mock implementations.
///
/// Implementations:
/// - [NostrCircleService] - Production implementation using Rust core
library;

import 'package:flutter/foundation.dart';

/// Fallback retention for decoded `DecryptedLocation` payloads that arrive
/// without an explicit `retention_secs` field (older Haven builds).
///
/// Mirrors `DEFAULT_SENDER_RETENTION_SECS` in `haven-core`. Kept in sync
/// manually; if the Rust default changes, update this constant too.
const int kFallbackSenderRetentionSecs = 24 * 60 * 60;

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
    this.avatarPath,
  });

  /// Member's Nostr public key (hex format).
  final String pubkey;

  /// Local display name for this member (from contacts).
  final String? displayName;

  /// Local avatar path for this member (from contacts).
  final String? avatarPath;

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
  String toString() =>
      'Invitation(memberCount: $memberCount)';
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
    required this.precision,
    this.displayName,
    this.retentionSecs = kFallbackSenderRetentionSecs,
  });

  /// Sender's Nostr public key (hex-encoded).
  final String senderPubkey;

  /// Latitude (obfuscated to sender's precision).
  final double latitude;

  /// Longitude (obfuscated to sender's precision).
  final double longitude;

  /// Geohash of the location.
  final String geohash;

  /// When the location was recorded.
  final DateTime timestamp;

  /// When this location expires.
  final DateTime expiresAt;

  /// Precision level ("Private", "Standard", or "Enhanced").
  final String precision;

  /// Sender's self-chosen display name (if provided).
  final String? displayName;

  /// Sender-controlled retention preference, in seconds.
  ///
  /// Already clamped at the FFI boundary to the receiver-side ceiling.
  /// `0` is the sender's "do not store" sentinel.
  final int retentionSecs;

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
  const DecryptResult({this.location, this.groupUpdated = false});

  /// The decrypted location, if this was an application message.
  final DecryptedLocation? location;

  /// Whether this event was an MLS commit or proposal that changed
  /// the group state (e.g., a new member joined).
  final bool groupUpdated;
}

/// Abstract interface for circle management services.
///
/// Manages circles (groups of trusted contacts for location sharing).
/// All operations involving relays are routed through Tor.
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
  /// Throws [CircleServiceException] if creation fails.
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
  /// Throws [CircleServiceException] if leaving fails.
  Future<void> leaveCircle(List<int> mlsGroupId);

  /// Processes a gift-wrapped invitation event.
  ///
  /// Unwraps the NIP-59 gift wrap, extracts the MLS Welcome, and stores
  /// the invitation as pending. Circle name and relays are extracted
  /// from the Welcome's embedded group data.
  ///
  /// Returns the [Invitation] for display in the UI.
  ///
  /// Throws [CircleServiceException] if processing fails or the event
  /// has already been processed.
  Future<Invitation> processGiftWrappedInvitation({
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

  /// Encrypts a location for a circle.
  ///
  /// Creates an MLS-encrypted kind 445 event containing the location data,
  /// ready for publishing to the circle's relays.
  ///
  /// [retentionSecs] is the sender-controlled retention preference embedded
  /// in the encrypted message. The Rust layer clamps it to the receiver
  /// ceiling (`LOCATION_RECEIVER_MAX_RETENTION_SECS`). A value of `0` is
  /// the "do not store" sentinel — receivers will drop any cached row for
  /// this sender.
  ///
  /// [precisionLabel] is the Rust `LocationPrecision` label string
  /// (`"Enhanced"`, `"Standard"`, or `"Private"`).  When `null`, the
  /// Rust core defaults to `Enhanced` (~1.1 m).
  ///
  /// Throws [CircleServiceException] if encryption fails.
  Future<EncryptedLocation> encryptLocation({
    required List<int> mlsGroupId,
    required String senderPubkeyHex,
    required double latitude,
    required double longitude,
    required int retentionSecs,
    String? displayName,
    String? precisionLabel,
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

  /// Signs a relay list event (kind 10051) for key package discovery.
  ///
  /// Builds and signs a replaceable event listing the relays where the
  /// user's key packages are published. Returns the signed event JSON.
  ///
  /// Throws [CircleServiceException] if signing fails.
  Future<String> signRelayListEvent({
    required List<int> identitySecretBytes,
    required List<String> relays,
  });

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
  /// The Rust layer clamps `retentionSecs` to the receiver-side ceiling.
  /// `purgeAfter` should be `timestamp + effective_retention`.
  ///
  /// Throws [CircleServiceException] on failure.
  Future<void> upsertLastKnownLocation({
    required List<int> nostrGroupId,
    required String senderPubkey,
    required double latitude,
    required double longitude,
    required String geohash,
    required String precision,
    required DateTime timestamp,
    required DateTime expiresAt,
    required int retentionSecs,
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
  /// Called when a sender publishes `retentionSecs == 0` or when the
  /// member leaves the circle.
  Future<void> removeLastKnownMember({
    required List<int> nostrGroupId,
    required String senderPubkey,
  });

  /// Removes every last-known location row for a circle.
  Future<void> removeLastKnownCircle({required List<int> nostrGroupId});

  /// Removes every last-known location row for a sender across all circles.
  ///
  /// Used by the "Clear my location from others" flow so the caller does
  /// not have to iterate circles (including hidden ones) on the Dart side.
  /// Returns the number of rows removed.
  Future<int> removeLastKnownForSender({required String senderPubkey});

  /// Wipes every last-known location row across all circles.
  ///
  /// Wired into the identity-deletion path.
  Future<void> wipeAllLastKnownLocations();

  /// Deletes every row whose `purge_after < now`.
  ///
  /// Returns the number of rows removed.
  Future<int> pruneExpiredLastKnown({DateTime? now});

  /// Receiver-side ceiling for sender-controlled retention (seconds).
  int get locationReceiverMaxRetentionSecs;

  /// Default sender-side retention preference (seconds).
  int get defaultSenderRetentionSecs;

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
}

/// A signed key package event ready for relay publishing.
///
/// Contains the signed kind 443 Nostr event and the relay URLs where
/// it should be published.
@immutable
class SignedKeyPackageEvent {
  /// Creates a [SignedKeyPackageEvent].
  const SignedKeyPackageEvent({required this.eventJson, required this.relays});

  /// The signed kind 443 event as JSON string.
  final String eventJson;

  /// Relay URLs where this event should be published.
  final List<String> relays;
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

  /// Inbox relay URLs where this KeyPackage was found (kind 10051).
  final List<String> relays;

  /// Fallback NIP-65 relay URLs (kind 10002), used when inbox relays
  /// are unavailable for Welcome delivery.
  final List<String> nip65Relays;
}
