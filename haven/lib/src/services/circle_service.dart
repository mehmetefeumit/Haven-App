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
  String toString() => 'Circle(displayName: $displayName)';
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
  String toString() => 'CircleMember(pubkey: $pubkey, status: $status)';
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
      'Invitation(circleName: $circleName, memberCount: $memberCount)';
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

  /// Whether this location has expired.
  bool get isExpired => DateTime.now().isAfter(expiresAt);
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
  /// the invitation as pending. The circle name defaults to [circleName].
  ///
  /// Returns the [Invitation] for display in the UI.
  ///
  /// Throws [CircleServiceException] if processing fails or the event
  /// has already been processed.
  Future<Invitation> processGiftWrappedInvitation({
    required List<int> identitySecretBytes,
    required String giftWrapEventJson,
    String circleName = 'New Circle',
  });

  /// Finalizes a pending MLS commit for a circle.
  ///
  /// Must be called after all welcome events have been published to relays.
  /// This merges the pending commit into the MLS group state, completing
  /// the group creation or member addition.
  ///
  /// Throws [CircleServiceException] if finalization fails.
  Future<void> finalizePendingCommit(List<int> mlsGroupId);

  /// Encrypts a location for a circle.
  ///
  /// Creates an MLS-encrypted kind 445 event containing the location data,
  /// ready for publishing to the circle's relays.
  ///
  /// Throws [CircleServiceException] if encryption fails.
  Future<EncryptedLocation> encryptLocation({
    required List<int> mlsGroupId,
    required String senderPubkeyHex,
    required double latitude,
    required double longitude,
  });

  /// Decrypts a received location event.
  ///
  /// Processes a kind 445 event through MLS decryption and extracts
  /// location data. Returns `null` for non-location messages (group
  /// updates, unprocessable messages).
  ///
  /// Throws [CircleServiceException] if decryption fails.
  Future<DecryptedLocation?> decryptLocation({required String eventJson});
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
  });

  /// User's Nostr public key (hex format).
  final String pubkey;

  /// Kind 443 KeyPackage event as JSON string.
  final String eventJson;

  /// Relay URLs where this KeyPackage was found.
  final List<String> relays;
}
