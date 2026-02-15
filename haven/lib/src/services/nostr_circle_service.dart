/// Production implementation of [CircleService] using Rust core.
///
/// This implementation:
/// - Uses haven-core for MLS group operations (via flutter_rust_bridge)
/// - Stores circle metadata in encrypted SQLCipher database
/// - Requires data directory for persistent storage
///
/// # Architecture
///
/// ```text
/// Flutter App
///     │
///     └── NostrCircleService (this class)
///             │
///             └── CircleManagerFfi (Rust via FFI)
///                     │
///                     ├── MLS Manager (group operations)
///                     └── SQLCipher DB (circle metadata)
/// ```
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:haven/src/rust/api.dart';
import 'package:haven/src/services/circle_service.dart';
import 'package:haven/src/services/nostr_relay_service.dart';
import 'package:haven/src/services/relay_service.dart';

/// Production implementation of [CircleService].
///
/// Uses the Rust core for MLS group operations and persistent storage.
class NostrCircleService implements CircleService {
  /// Creates a new [NostrCircleService].
  ///
  /// The service must be initialized with [initialize] before use.
  /// Optionally accepts a [DataDirectoryProvider] for testing.
  NostrCircleService({
    required RelayService relayService,
    DataDirectoryProvider? dataDirectoryProvider,
  }) : _relayService = relayService,
       _dataDirectoryProvider =
           dataDirectoryProvider ?? const PathProviderDataDirectory();

  final RelayService _relayService;
  final DataDirectoryProvider _dataDirectoryProvider;
  CircleManagerFfi? _manager;
  bool _initialized = false;
  Completer<void>? _initCompleter;

  /// Initializes the circle manager with persistent storage.
  ///
  /// Must be called before any other methods.
  /// Uses the application documents directory for storage.
  /// Thread-safe: concurrent calls will wait for the first initialization.
  Future<void> initialize() async {
    if (_initialized) return;

    // If initialization is in progress, wait for it
    if (_initCompleter != null) {
      await _initCompleter!.future;
      return;
    }

    // Start initialization
    _initCompleter = Completer<void>();
    try {
      final dataDir = await _dataDirectoryProvider.getDataDirectory();
      _manager = await CircleManagerFfi.newInstance(dataDir: dataDir);
      _initialized = true;
      _initCompleter!.complete();
      _initCompleter = null;
    } on Object catch (e, stackTrace) {
      _initCompleter!.completeError(e, stackTrace);
      _initCompleter = null;
      rethrow;
    }
  }

  /// Ensures the manager is initialized.
  Future<CircleManagerFfi> _ensureInitialized() async {
    if (!_initialized || _manager == null) {
      await initialize();
    }
    return _manager!;
  }

  /// Converts a Rust timestamp to DateTime.
  DateTime _timestampToDateTime(num timestamp) {
    return DateTime.fromMillisecondsSinceEpoch(timestamp.toInt() * 1000);
  }

  /// Converts a membership status string to enum.
  MembershipStatus _parseMembershipStatus(String status) {
    return switch (status.toLowerCase()) {
      'pending' => MembershipStatus.pending,
      'accepted' => MembershipStatus.accepted,
      'declined' => MembershipStatus.declined,
      _ => MembershipStatus.pending,
    };
  }

  /// Converts a circle type string to enum.
  CircleType _parseCircleType(String circleType) {
    return switch (circleType.toLowerCase()) {
      'location_sharing' => CircleType.locationSharing,
      'direct_share' => CircleType.directShare,
      _ => CircleType.locationSharing,
    };
  }

  /// Converts a CircleType enum to string for FFI.
  String _circleTypeToString(CircleType circleType) {
    return switch (circleType) {
      CircleType.locationSharing => 'location_sharing',
      CircleType.directShare => 'direct_share',
    };
  }

  /// Converts FFI member to service member.
  CircleMember _convertMember(CircleMemberFfi ffiMember) {
    return CircleMember(
      pubkey: ffiMember.pubkey,
      displayName: ffiMember.displayName,
      avatarPath: ffiMember.avatarPath,
      isAdmin: ffiMember.isAdmin,
      // Members in a visible circle have accepted their invitation
      status: MembershipStatus.accepted,
    );
  }

  /// Converts FFI circle with members to service circle.
  Circle _convertCircleWithMembers(CircleWithMembersFfi ffiCircle) {
    return Circle(
      mlsGroupId: ffiCircle.circle.mlsGroupId.toList(),
      nostrGroupId: ffiCircle.circle.nostrGroupId.toList(),
      displayName: ffiCircle.circle.displayName,
      circleType: _parseCircleType(ffiCircle.circle.circleType),
      relays: ffiCircle.circle.relays,
      membershipStatus: _parseMembershipStatus(ffiCircle.membershipStatus),
      members: ffiCircle.members.map(_convertMember).toList(),
      createdAt: _timestampToDateTime(ffiCircle.circle.createdAt),
      updatedAt: _timestampToDateTime(ffiCircle.circle.updatedAt),
    );
  }

  /// Converts FFI invitation to service invitation.
  Invitation _convertInvitation(InvitationFfi ffiInvitation) {
    return Invitation(
      mlsGroupId: ffiInvitation.mlsGroupId.toList(),
      circleName: ffiInvitation.circleName,
      inviterPubkey: ffiInvitation.inviterPubkey,
      memberCount: ffiInvitation.memberCount,
      invitedAt: _timestampToDateTime(ffiInvitation.invitedAt),
    );
  }

  @override
  Future<CircleCreationResult> createCircle({
    required List<int> identitySecretBytes,
    required List<KeyPackageData> memberKeyPackages,
    required String name,
    required CircleType circleType,
    String? description,
    List<String>? relays,
  }) async {
    final manager = await _ensureInitialized();

    try {
      // Validate identity secret bytes length
      if (identitySecretBytes.length != 32) {
        throw CircleServiceException(
          'Invalid identity secret bytes length: '
          'expected 32, got ${identitySecretBytes.length}',
        );
      }

      // Convert KeyPackageData to MemberKeyPackageFfi
      final members = memberKeyPackages
          .map(
            (kp) => MemberKeyPackageFfi(
              keyPackageJson: kp.eventJson,
              inboxRelays: kp.relays,
            ),
          )
          .toList();

      // Collect relay URLs from all members
      final memberRelays = memberKeyPackages
          .expand((kp) => kp.relays)
          .toSet()
          .toList();
      final circleRelays = relays ?? memberRelays;

      final result = await manager.createCircle(
        identitySecretBytes: Uint8List.fromList(identitySecretBytes),
        members: members,
        name: name,
        description: description,
        circleType: _circleTypeToString(circleType),
        relays: circleRelays,
      );

      // Convert FFI result to service types
      final circle = Circle(
        mlsGroupId: result.circle.mlsGroupId.toList(),
        nostrGroupId: result.circle.nostrGroupId.toList(),
        displayName: result.circle.displayName,
        circleType: _parseCircleType(result.circle.circleType),
        relays: result.circle.relays,
        membershipStatus: MembershipStatus.accepted, // Creator is accepted
        members: const [], // Members added after invitations are sent
        createdAt: _timestampToDateTime(result.circle.createdAt),
        updatedAt: _timestampToDateTime(result.circle.updatedAt),
      );

      // Convert gift-wrapped welcome events
      final welcomeEvents = result.welcomeEvents
          .map(
            (w) => GiftWrappedWelcome(
              recipientPubkey: w.recipientPubkey,
              recipientRelays: w.recipientRelays,
              eventJson: w.eventJson,
            ),
          )
          .toList();

      return CircleCreationResult(circle: circle, welcomeEvents: welcomeEvents);
    } on Exception catch (e) {
      throw CircleServiceException('Failed to create circle: $e');
    }
  }

  @override
  Future<List<Circle>> getVisibleCircles() async {
    final manager = await _ensureInitialized();

    try {
      final ffiCircles = await manager.getVisibleCircles();
      return ffiCircles.map(_convertCircleWithMembers).toList();
    } on Exception catch (e) {
      throw CircleServiceException('Failed to get circles: $e');
    }
  }

  @override
  Future<Circle?> getCircle(List<int> mlsGroupId) async {
    final manager = await _ensureInitialized();

    try {
      final groupId = Uint8List.fromList(mlsGroupId);
      final ffiCircle = await manager.getCircle(mlsGroupId: groupId);
      if (ffiCircle == null) {
        return null;
      }
      return _convertCircleWithMembers(ffiCircle);
    } on Exception catch (e) {
      throw CircleServiceException('Failed to get circle: $e');
    }
  }

  @override
  Future<List<CircleMember>> getMembers(List<int> mlsGroupId) async {
    final manager = await _ensureInitialized();

    try {
      final groupId = Uint8List.fromList(mlsGroupId);
      final ffiMembers = await manager.getMembers(mlsGroupId: groupId);
      return ffiMembers.map(_convertMember).toList();
    } on Exception catch (e) {
      throw CircleServiceException('Failed to get members: $e');
    }
  }

  @override
  Future<List<Invitation>> getPendingInvitations() async {
    final manager = await _ensureInitialized();

    try {
      final ffiInvitations = await manager.getPendingInvitations();
      return ffiInvitations.map(_convertInvitation).toList();
    } on Exception catch (e) {
      throw CircleServiceException('Failed to get pending invitations: $e');
    }
  }

  @override
  Future<Circle> acceptInvitation(List<int> mlsGroupId) async {
    final manager = await _ensureInitialized();

    try {
      final ffiCircle = await manager.acceptInvitation(
        mlsGroupId: Uint8List.fromList(mlsGroupId),
      );
      return _convertCircleWithMembers(ffiCircle);
    } on Exception catch (e) {
      throw CircleServiceException('Failed to accept invitation: $e');
    }
  }

  @override
  Future<void> declineInvitation(List<int> mlsGroupId) async {
    final manager = await _ensureInitialized();

    try {
      await manager.declineInvitation(
        mlsGroupId: Uint8List.fromList(mlsGroupId),
      );
    } on Exception catch (e) {
      throw CircleServiceException('Failed to decline invitation: $e');
    }
  }

  @override
  Future<Invitation> processGiftWrappedInvitation({
    required List<int> identitySecretBytes,
    required String giftWrapEventJson,
    String circleName = 'New Circle',
  }) async {
    final manager = await _ensureInitialized();

    try {
      final ffiInvitation = await manager.processGiftWrappedInvitation(
        identitySecretBytes: Uint8List.fromList(identitySecretBytes),
        giftWrapEventJson: giftWrapEventJson,
        circleName: circleName,
      );
      return _convertInvitation(ffiInvitation);
    } on Exception catch (e) {
      throw CircleServiceException(
        'Failed to process gift-wrapped invitation: $e',
      );
    }
  }

  @override
  Future<void> finalizePendingCommit(List<int> mlsGroupId) async {
    final manager = await _ensureInitialized();

    try {
      await manager.finalizePendingCommit(
        mlsGroupId: Uint8List.fromList(mlsGroupId),
      );
    } on Exception catch (e) {
      throw CircleServiceException('Failed to finalize pending commit: $e');
    }
  }

  @override
  Future<void> leaveCircle(List<int> mlsGroupId) async {
    final manager = await _ensureInitialized();

    try {
      final groupId = Uint8List.fromList(mlsGroupId);

      // Fetch circle relays BEFORE leaving (leave deletes local storage).
      // If relays unavailable, skip publishing (do NOT fall back to default
      // relays — that would leak group metadata to unrelated relays).
      List<String>? relays;
      try {
        final circle = await manager.getCircle(mlsGroupId: groupId);
        relays = circle?.circle.relays;
      } on Object {
        // Circle lookup failed — proceed with leave but skip publishing.
      }

      // Leave circle (produces MLS Remove Proposal, deletes local state).
      final result = await manager.leaveCircle(mlsGroupId: groupId);

      // Best-effort publish to circle relays only.
      if (relays != null && relays.isNotEmpty) {
        try {
          final publishResult = await _relayService.publishEvent(
            eventJson: result.evolutionEventJson,
            relays: relays,
          );
          debugPrint(
            'Evolution event published: '
            '${publishResult.acceptedBy.length} accepted, '
            '${publishResult.failed.length} failed',
          );
        } on Object catch (e) {
          debugPrint('Failed to publish evolution event (non-fatal): $e');
        }
      } else {
        debugPrint(
          'Circle relays unavailable, skipping evolution event publish',
        );
      }
    } on Object catch (e) {
      debugPrint('Failed to leave circle: $e');
      throw const CircleServiceException('Failed to leave circle');
    }
  }

  @override
  Future<EncryptedLocation> encryptLocation({
    required List<int> mlsGroupId,
    required String senderPubkeyHex,
    required double latitude,
    required double longitude,
  }) async {
    final manager = await _ensureInitialized();

    try {
      final result = await manager.encryptLocation(
        mlsGroupId: Uint8List.fromList(mlsGroupId),
        senderPubkeyHex: senderPubkeyHex,
        latitude: latitude,
        longitude: longitude,
      );

      return EncryptedLocation(
        eventJson: result.eventJson,
        nostrGroupId: result.nostrGroupId.toList(),
        relays: result.relays,
      );
    } on Exception catch (e) {
      throw CircleServiceException('Failed to encrypt location: $e');
    }
  }

  @override
  Future<DecryptedLocation?> decryptLocation({
    required String eventJson,
  }) async {
    final manager = await _ensureInitialized();

    try {
      final result = await manager.decryptLocation(eventJson: eventJson);
      if (result == null) return null;

      return DecryptedLocation(
        senderPubkey: result.senderPubkey,
        latitude: result.latitude,
        longitude: result.longitude,
        geohash: result.geohash,
        timestamp: DateTime.fromMillisecondsSinceEpoch(result.timestamp * 1000),
        expiresAt: DateTime.fromMillisecondsSinceEpoch(result.expiresAt * 1000),
        precision: result.precision,
      );
    } on Exception catch (e) {
      throw CircleServiceException('Failed to decrypt location: $e');
    }
  }

  @override
  Future<SignedKeyPackageEvent> signKeyPackageEvent({
    required List<int> identitySecretBytes,
    required List<String> relays,
  }) async {
    final manager = await _ensureInitialized();

    try {
      final result = await manager.signKeyPackageEvent(
        identitySecretBytes: Uint8List.fromList(identitySecretBytes),
        relays: relays,
      );
      return SignedKeyPackageEvent(
        eventJson: result.eventJson,
        relays: result.relays,
      );
    } on Object {
      throw const CircleServiceException('Failed to sign key package event');
    }
  }

  @override
  Future<String> signRelayListEvent({
    required List<int> identitySecretBytes,
    required List<String> relays,
  }) async {
    final manager = await _ensureInitialized();
    try {
      return manager.signRelayListEvent(
        identitySecretBytes: Uint8List.fromList(identitySecretBytes),
        relays: relays,
      );
    } on Object {
      throw const CircleServiceException('Failed to sign relay list event');
    }
  }
}
