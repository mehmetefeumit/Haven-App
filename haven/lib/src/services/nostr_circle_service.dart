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

/// Function type for keyring store initialization.
///
/// The default implementation calls the Rust FFI [initKeyringStore].
/// Tests can substitute a mock to avoid requiring native library access.
typedef KeyringInitializer = Future<void> Function();

/// Production implementation of [CircleService].
///
/// Uses the Rust core for MLS group operations and persistent storage.
class NostrCircleService implements CircleService {
  /// Creates a new [NostrCircleService].
  ///
  /// The service must be initialized with [initialize] before use.
  /// Optionally accepts a [DataDirectoryProvider] and a
  /// [KeyringInitializer] for testing.
  NostrCircleService({
    required RelayService relayService,
    DataDirectoryProvider? dataDirectoryProvider,
    KeyringInitializer? keyringInitializer,
  }) : _relayService = relayService,
       _dataDirectoryProvider =
           dataDirectoryProvider ?? const PathProviderDataDirectory(),
       _keyringInitializer = keyringInitializer ?? initKeyringStore;

  final RelayService _relayService;
  final DataDirectoryProvider _dataDirectoryProvider;
  final KeyringInitializer _keyringInitializer;
  CircleManagerFfi? _manager;
  bool _initialized = false;
  Completer<void>? _initCompleter;

  /// Initializes the circle manager with persistent storage.
  ///
  /// Must be called before any other methods.
  /// Uses the application documents directory for storage.
  /// Thread-safe: concurrent calls will wait for the first initialization.
  Future<void> initialize() {
    if (_initialized) return Future.value();

    // If initialization is in progress, all callers wait on the same future.
    if (_initCompleter != null) {
      return _initCompleter!.future;
    }

    // Start initialization. Both this caller and any concurrent callers
    // receive the outcome via _initCompleter.future, avoiding dual propagation.
    _initCompleter = Completer<void>();
    _runInitialization();
    return _initCompleter!.future;
  }

  /// Performs the actual initialization work and settles [_initCompleter].
  Future<void> _runInitialization() async {
    final completer = _initCompleter!;
    try {
      // Initialize the platform keyring store before creating the circle
      // manager. MDK uses the keyring to store the SQLCipher encryption key.
      try {
        await _keyringInitializer();
      } on Object catch (e) {
        debugPrint('Keyring initialization failed: $e');
        throw const CircleServiceException(
          'Failed to initialize secure storage',
        );
      }
      final dataDir = await _dataDirectoryProvider.getDataDirectory();
      _manager = await CircleManagerFfi.newInstance(dataDir: dataDir);
      _initialized = true;
      _initCompleter = null;
      completer.complete();
    } on CircleServiceException catch (e) {
      _initCompleter = null;
      completer.completeError(e);
    } on Object catch (e, stackTrace) {
      _initCompleter = null;
      completer.completeError(e, stackTrace);
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
    } on Object catch (e) {
      debugPrint('Failed to create circle: $e');
      throw const CircleServiceException('Failed to create circle');
    }
  }

  @override
  Future<List<Circle>> getVisibleCircles() async {
    final manager = await _ensureInitialized();

    try {
      final ffiCircles = await manager.getVisibleCircles();
      return ffiCircles.map(_convertCircleWithMembers).toList();
    } on Object catch (e) {
      debugPrint('Failed to get circles: $e');
      throw const CircleServiceException('Failed to get circles');
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
    } on Object catch (e) {
      debugPrint('Failed to get circle: $e');
      throw const CircleServiceException('Failed to get circle');
    }
  }

  @override
  Future<List<CircleMember>> getMembers(List<int> mlsGroupId) async {
    final manager = await _ensureInitialized();

    try {
      final groupId = Uint8List.fromList(mlsGroupId);
      final ffiMembers = await manager.getMembers(mlsGroupId: groupId);
      return ffiMembers.map(_convertMember).toList();
    } on Object catch (e) {
      debugPrint('Failed to get members: $e');
      throw const CircleServiceException('Failed to get members');
    }
  }

  @override
  Future<List<Invitation>> getPendingInvitations() async {
    final manager = await _ensureInitialized();

    try {
      final ffiInvitations = await manager.getPendingInvitations();
      return ffiInvitations.map(_convertInvitation).toList();
    } on Object catch (e) {
      debugPrint('Failed to get pending invitations: $e');
      throw const CircleServiceException('Failed to get pending invitations');
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
    } on Object catch (e) {
      debugPrint('Failed to accept invitation: $e');
      throw const CircleServiceException('Failed to accept invitation');
    }
  }

  @override
  Future<void> declineInvitation(List<int> mlsGroupId) async {
    final manager = await _ensureInitialized();

    try {
      await manager.declineInvitation(
        mlsGroupId: Uint8List.fromList(mlsGroupId),
      );
    } on Object catch (e) {
      debugPrint('Failed to decline invitation: $e');
      throw const CircleServiceException('Failed to decline invitation');
    }
  }

  @override
  Future<Invitation> processGiftWrappedInvitation({
    required List<int> identitySecretBytes,
    required String giftWrapEventJson,
  }) async {
    final manager = await _ensureInitialized();

    try {
      final ffiInvitation = await manager.processGiftWrappedInvitation(
        identitySecretBytes: Uint8List.fromList(identitySecretBytes),
        giftWrapEventJson: giftWrapEventJson,
      );
      return _convertInvitation(ffiInvitation);
    } on Object catch (e) {
      debugPrint('Failed to process gift-wrapped invitation: $e');
      throw const CircleServiceException(
        'Failed to process gift-wrapped invitation',
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
    } on Object catch (e) {
      debugPrint('Failed to finalize pending commit: $e');
      throw const CircleServiceException('Failed to finalize pending commit');
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
      // Orphaned circles (MLS group not found in MDK) are cleaned up by the
      // Rust layer. The error still propagates here, but local storage is
      // already deleted — treat it as a successful leave with no evolution
      // event to publish.
      if (e.toString().contains('Orphaned circle removed')) {
        debugPrint('Orphaned circle cleaned up from local storage');
        return;
      }
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
    required int retentionSecs,
    String? displayName,
  }) async {
    final manager = await _ensureInitialized();

    try {
      final result = await manager.encryptLocation(
        mlsGroupId: Uint8List.fromList(mlsGroupId),
        senderPubkeyHex: senderPubkeyHex,
        latitude: latitude,
        longitude: longitude,
        displayName: displayName,
        retentionSecs: BigInt.from(retentionSecs),
      );

      return EncryptedLocation(
        eventJson: result.eventJson,
        nostrGroupId: result.nostrGroupId.toList(),
        relays: result.relays,
      );
    } on Object catch (e) {
      debugPrint('Failed to encrypt location: $e');
      throw const CircleServiceException('Failed to encrypt location');
    }
  }

  @override
  Future<DecryptResult?> decryptLocation({required String eventJson}) async {
    final manager = await _ensureInitialized();

    try {
      final result = await manager.decryptLocation(eventJson: eventJson);
      if (result == null) return null;

      final loc = result.location;
      return DecryptResult(
        location: loc == null
            ? null
            : DecryptedLocation(
                senderPubkey: loc.senderPubkey,
                latitude: loc.latitude,
                longitude: loc.longitude,
                geohash: loc.geohash,
                timestamp: DateTime.fromMillisecondsSinceEpoch(
                  loc.timestamp * 1000,
                ),
                expiresAt: DateTime.fromMillisecondsSinceEpoch(
                  loc.expiresAt * 1000,
                ),
                precision: loc.precision,
                displayName: loc.displayName,
                retentionSecs: loc.retentionSecs.toInt(),
              ),
        groupUpdated: result.groupUpdated,
      );
    } on Object catch (e) {
      debugPrint('Failed to decrypt location: $e');
      throw const CircleServiceException('Failed to decrypt location');
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

  // ==================== Last-Known Location Cache ====================

  /// Cached value of the receiver-side retention ceiling (sync FFI getter).
  int? _maxRetentionSecsCache;

  /// Cached value of the default sender retention preference (sync FFI getter).
  int? _defaultRetentionSecsCache;

  /// Hard fallback for the receiver-side retention ceiling.
  ///
  /// Used only before the FFI manager has been initialised (so the getter
  /// is non-async and can be read at any time). Mirrors
  /// `LOCATION_RECEIVER_MAX_RETENTION_SECS` in haven-core (30 days).
  static const int _fallbackMaxRetentionSecs = 30 * 24 * 60 * 60;

  /// Hard fallback for the default sender retention preference (24 hours).
  static const int _fallbackDefaultRetentionSecs = 24 * 60 * 60;

  /// Eagerly populates the receiver-max / default-retention caches once
  /// the FFI manager is available.
  void _primeRetentionCachesIfNeeded(CircleManagerFfi manager) {
    _maxRetentionSecsCache ??= manager
        .locationReceiverMaxRetentionSecs()
        .toInt();
    _defaultRetentionSecsCache ??= manager.defaultSenderRetentionSecs().toInt();
  }

  @override
  int get locationReceiverMaxRetentionSecs =>
      _maxRetentionSecsCache ?? _fallbackMaxRetentionSecs;

  @override
  int get defaultSenderRetentionSecs =>
      _defaultRetentionSecsCache ?? _fallbackDefaultRetentionSecs;

  @override
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
  }) async {
    final manager = await _ensureInitialized();
    _primeRetentionCachesIfNeeded(manager);
    try {
      await manager.upsertLastKnownLocation(
        location: LastKnownLocationFfi(
          nostrGroupId: Uint8List.fromList(nostrGroupId),
          senderPubkey: senderPubkey,
          latitude: latitude,
          longitude: longitude,
          geohash: geohash,
          precision: precision,
          displayName: displayName,
          timestamp: timestamp.millisecondsSinceEpoch ~/ 1000,
          expiresAt: expiresAt.millisecondsSinceEpoch ~/ 1000,
          retentionSecs: BigInt.from(retentionSecs),
          purgeAfter: purgeAfter.millisecondsSinceEpoch ~/ 1000,
          updatedAt: updatedAt.millisecondsSinceEpoch ~/ 1000,
        ),
      );
    } on Object catch (e) {
      debugPrint('Failed to upsert last-known location: $e');
      throw const CircleServiceException(
        'Failed to upsert last-known location',
      );
    }
  }

  @override
  Future<List<DecryptedLocation>> snapshotLastKnownForCircle({
    required List<int> nostrGroupId,
    DateTime? now,
  }) async {
    final manager = await _ensureInitialized();
    _primeRetentionCachesIfNeeded(manager);
    final nowSecs = (now ?? DateTime.now()).millisecondsSinceEpoch ~/ 1000;
    try {
      final rows = await manager.snapshotLastKnownForCircle(
        nostrGroupId: Uint8List.fromList(nostrGroupId),
        nowUnixSecs: nowSecs,
      );
      return rows
          .map(
            (row) => DecryptedLocation(
              senderPubkey: row.senderPubkey,
              latitude: row.latitude,
              longitude: row.longitude,
              geohash: row.geohash,
              timestamp: _timestampToDateTime(row.timestamp),
              expiresAt: _timestampToDateTime(row.expiresAt),
              precision: row.precision,
              displayName: row.displayName,
              retentionSecs: row.retentionSecs.toInt(),
            ),
          )
          .toList();
    } on Object catch (e) {
      debugPrint('Failed to snapshot last-known locations: $e');
      throw const CircleServiceException('Failed to load last-known locations');
    }
  }

  @override
  Future<void> removeLastKnownMember({
    required List<int> nostrGroupId,
    required String senderPubkey,
  }) async {
    final manager = await _ensureInitialized();
    try {
      await manager.removeLastKnownMember(
        nostrGroupId: Uint8List.fromList(nostrGroupId),
        senderPubkey: senderPubkey,
      );
    } on Object catch (e) {
      debugPrint('Failed to remove last-known member: $e');
      throw const CircleServiceException(
        'Failed to remove last-known location',
      );
    }
  }

  @override
  Future<int> removeLastKnownForSender({required String senderPubkey}) async {
    final manager = await _ensureInitialized();
    try {
      final removed = await manager.removeLastKnownForSender(
        senderPubkey: senderPubkey,
      );
      return removed;
    } on Object catch (e) {
      debugPrint('Failed to remove last-known for sender: $e');
      throw const CircleServiceException(
        'Failed to clear last-known locations for sender',
      );
    }
  }

  @override
  Future<void> removeLastKnownCircle({required List<int> nostrGroupId}) async {
    final manager = await _ensureInitialized();
    try {
      await manager.removeLastKnownCircle(
        nostrGroupId: Uint8List.fromList(nostrGroupId),
      );
    } on Object catch (e) {
      debugPrint('Failed to remove last-known circle: $e');
      throw const CircleServiceException(
        'Failed to remove last-known locations for circle',
      );
    }
  }

  @override
  Future<void> wipeAllLastKnownLocations() async {
    final manager = await _ensureInitialized();
    try {
      await manager.wipeAllLastKnownLocations();
    } on Object catch (e) {
      debugPrint('Failed to wipe last-known locations: $e');
      throw const CircleServiceException('Failed to wipe last-known locations');
    }
  }

  @override
  Future<int> pruneExpiredLastKnown({DateTime? now}) async {
    final manager = await _ensureInitialized();
    final nowSecs = (now ?? DateTime.now()).millisecondsSinceEpoch ~/ 1000;
    try {
      final removed = await manager.pruneExpiredLastKnown(nowUnixSecs: nowSecs);
      return removed;
    } on Object catch (e) {
      debugPrint('Failed to prune last-known locations: $e');
      throw const CircleServiceException(
        'Failed to prune last-known locations',
      );
    }
  }
}
