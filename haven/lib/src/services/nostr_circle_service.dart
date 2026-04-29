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
import 'package:haven/src/constants/relays.dart';
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

  /// Creates a [NostrCircleService] backed by a pre-built [CircleManagerFfi].
  ///
  /// Used by the background isolate (`background_location_task.dart`) to
  /// share the already-constructed manager rather than constructing a
  /// second one over the same SQLCipher path. Holding two managers in one
  /// isolate would split MLS state across two in-memory MDK caches and
  /// risk SQLite contention; the foreground hands its existing manager to
  /// this constructor so all MLS work in the bg isolate goes through one
  /// authoritative handle.
  ///
  /// `relayService` and `injectedManager` MUST originate from the same
  /// isolate. The keyring initializer is bypassed because the caller has
  /// already opened the encrypted database via the same manager.
  NostrCircleService.withInjectedManager({
    required RelayService relayService,
    required CircleManagerFfi injectedManager,
  }) : _relayService = relayService,
       _dataDirectoryProvider = const PathProviderDataDirectory(),
       _keyringInitializer = initKeyringStore,
       _manager = injectedManager,
       _initialized = true;

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
        debugPrint('Keyring initialization failed: ${e.runtimeType}');
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
    List<String> creatorFallbackRelays = const [],
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
              nip65Relays: kp.nip65Relays,
            ),
          )
          .toList();

      // Collect relay URLs from all members. The circle's `relays` field
      // populates the kind 444 Welcome rumor's `relays` tag, which MIP-02
      // requires to be non-empty (validated by MDK's `validate_welcome_event`).
      // If neither the caller nor any member supplies a URL, fall back to
      // `defaultRelays` so the rumor is always structurally valid.
      final memberRelays = memberKeyPackages
          .expand((kp) => kp.relays)
          .toSet()
          .toList();
      final circleRelays = relays?.isNotEmpty ?? false
          ? relays!
          : (memberRelays.isNotEmpty ? memberRelays : defaultRelays);

      final result = await manager.createCircle(
        identitySecretBytes: Uint8List.fromList(identitySecretBytes),
        members: members,
        name: name,
        description: description,
        circleType: _circleTypeToString(circleType),
        relays: circleRelays,
        creatorFallbackRelays: creatorFallbackRelays,
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
    } on Object catch (_) {
      debugPrint('[Circle] Create failed');
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
      debugPrint('Failed to get circles: ${e.runtimeType}');
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
      debugPrint('Failed to get circle: ${e.runtimeType}');
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
      debugPrint('Failed to get members: ${e.runtimeType}');
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
      debugPrint('Failed to get pending invitations: ${e.runtimeType}');
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
      debugPrint('Failed to accept invitation: ${e.runtimeType}');
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
      debugPrint('Failed to decline invitation: ${e.runtimeType}');
      throw const CircleServiceException('Failed to decline invitation');
    }
  }

  @override
  Future<Invitation?> processGiftWrappedInvitation({
    required List<int> identitySecretBytes,
    required String giftWrapEventJson,
  }) async {
    final manager = await _ensureInitialized();

    try {
      final ffiInvitation = await manager.processGiftWrappedInvitation(
        identitySecretBytes: Uint8List.fromList(identitySecretBytes),
        giftWrapEventJson: giftWrapEventJson,
      );
      // `null` signals the Rust side detected a duplicate gift wrap (the
      // wrapper event ID is already in `processed_gift_wraps`). Propagate
      // as `null` so the poller can silently skip it.
      if (ffiInvitation == null) {
        return null;
      }
      return _convertInvitation(ffiInvitation);
    } on Object catch (e) {
      // Log only the runtime type — CircleError variants (NotFound,
      // ContactNotFound, etc.) can embed pubkeys or group IDs in their
      // Display output; logging `$e` would expose that even in debug builds.
      debugPrint('[Circle] Invitation processing failed: ${e.runtimeType}');
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
      debugPrint('Failed to finalize pending commit: ${e.runtimeType}');
      throw const CircleServiceException('Failed to finalize pending commit');
    }
  }

  @override
  Future<void> clearPendingCommit(List<int> mlsGroupId) async {
    final manager = await _ensureInitialized();

    try {
      await manager.clearPendingCommit(
        mlsGroupId: Uint8List.fromList(mlsGroupId),
      );
    } on Object catch (e) {
      debugPrint('Failed to clear pending commit: ${e.runtimeType}');
      throw const CircleServiceException('Failed to clear pending commit');
    }
  }

  @override
  Future<List<List<int>>> groupsNeedingSelfUpdate(int thresholdSecs) async {
    final manager = await _ensureInitialized();

    try {
      return await manager.groupsNeedingSelfUpdate(
        thresholdSecs: BigInt.from(thresholdSecs),
      );
    } on Object catch (e) {
      debugPrint(
        'Failed to query groups needing self-update: ${e.runtimeType}',
      );
      throw const CircleServiceException(
        'Failed to query groups needing self-update',
      );
    }
  }

  @override
  Future<void> selfUpdate(List<int> mlsGroupId) async {
    final manager = await _ensureInitialized();

    try {
      final groupId = Uint8List.fromList(mlsGroupId);

      // Fetch circle relays for publishing.
      List<String>? relays;
      try {
        final circle = await manager.getCircle(mlsGroupId: groupId);
        relays = circle?.circle.relays;
      } on Object catch (e) {
        debugPrint('Self-update relay lookup failed: ${e.runtimeType}');
      }

      if (relays == null || relays.isEmpty) {
        debugPrint('Self-update skipped: circle relays unavailable');
        return;
      }

      final result = await manager.selfUpdate(mlsGroupId: groupId);

      final published = await _publishEvolutionEvent(
        result.evolutionEventJson,
        relays,
        label: 'self-update',
      );

      if (published) {
        await finalizePendingCommit(mlsGroupId);
      } else {
        debugPrint('Self-update publish failed, rolling back');
        try {
          await clearPendingCommit(mlsGroupId);
        } on Object catch (e) {
          debugPrint(
            'Failed to clear pending commit after self-update failure: ${e.runtimeType}',
          );
        }
      }
    } on Object catch (e) {
      // Self-update is best-effort (MIP-02 requires completion within 24h).
      // Log and return — the hourly selfUpdateProvider retries missed rotations.
      debugPrint('Self-update failed: ${e.runtimeType}');
    }
  }

  @override
  Future<void> leaveCircle({
    required List<int> mlsGroupId,
    required String selfPubkeyHex,
  }) async {
    final manager = await _ensureInitialized();
    final groupId = Uint8List.fromList(mlsGroupId);

    try {
      final plan = await manager.planLeave(
        mlsGroupId: groupId,
        selfPubkeyHex: selfPubkeyHex,
      );

      switch (plan.kind) {
        case LeavePlanKindFfi.orphanLocalOnly:
          await manager.completeLeave(mlsGroupId: groupId);
          return;
        case LeavePlanKindFfi.abandon:
          await manager.abandonCircleLocalOnly(mlsGroupId: groupId);
          return;
        case LeavePlanKindFfi.nonAdmin:
        case LeavePlanKindFfi.adminHandoff:
        case LeavePlanKindFfi.adminDemote:
          break;
      }

      // Handoff / demotion / leave publish each target the circle's relays.
      // Skip publishing when relays are unavailable — do NOT fall back to
      // defaults (would leak group metadata to unrelated relays).
      final relays = await _circleRelays(groupId);
      if (relays == null || relays.isEmpty) {
        debugPrint('Circle relays unavailable — aborting leave');
        throw const CircleServiceException('Failed to leave circle');
      }

      if (plan.kind == LeavePlanKindFfi.adminHandoff) {
        final successor = plan.successorHex;
        if (successor == null) {
          throw const CircleServiceException('Failed to leave circle');
        }
        final promote = await manager.proposeAdminHandoff(
          mlsGroupId: groupId,
          successorHex: successor,
        );
        if (!await _commitAndPublish(
          mlsGroupId: mlsGroupId,
          eventJson: promote.evolutionEventJson,
          relays: relays,
          label: 'admin handoff',
        )) {
          throw const CircleServiceException('Failed to leave circle');
        }
      }

      if (plan.kind == LeavePlanKindFfi.adminHandoff ||
          plan.kind == LeavePlanKindFfi.adminDemote) {
        final demote = await _stageOrClear(
          () => manager.proposeSelfDemote(mlsGroupId: groupId),
          mlsGroupId: mlsGroupId,
          label: 'self-demote',
        );
        if (!await _commitAndPublish(
          mlsGroupId: mlsGroupId,
          eventJson: demote.evolutionEventJson,
          relays: relays,
          label: 'self-demote',
        )) {
          throw const CircleServiceException('Failed to leave circle');
        }
      }

      // `propose_leave` returns a SelfRemove *proposal* (RFC 9420 §12.1.2)
      // — a remaining member commits it later, so the leaver does not
      // finalize a pending commit here. We bump the publish attempts to
      // [_leaveMaxPublishAttempts] because this publish is terminal:
      // success is immediately followed by a forward-secrecy purge of
      // the leaver's MDK state, and failure must keep local state intact
      // so the user can retry.
      final leave = await manager.proposeLeave(mlsGroupId: groupId);
      if (!await _publishEvolutionEvent(
        leave.evolutionEventJson,
        relays,
        label: 'leave',
        maxAttempts: _leaveMaxPublishAttempts,
      )) {
        throw const CircleServiceException('Failed to leave circle');
      }

      await manager.completeLeave(mlsGroupId: groupId);
    } on CircleServiceException {
      rethrow;
    } on Object catch (e) {
      debugPrint('Failed to leave circle: ${e.runtimeType}');
      throw const CircleServiceException('Failed to leave circle');
    }
  }

  @override
  Future<void> removeMember({
    required List<int> mlsGroupId,
    required String memberPubkeyHex,
  }) async {
    final manager = await _ensureInitialized();
    final groupId = Uint8List.fromList(mlsGroupId);

    try {
      final relays = await _circleRelays(groupId);
      if (relays == null || relays.isEmpty) {
        debugPrint('Circle relays unavailable — aborting remove');
        throw const CircleServiceException('Failed to remove member');
      }

      // MDK's `remove_members` stages a pending commit and returns the
      // `kind:445` evolution event. The admin-published RemoveMember
      // commit bypasses MDK's SelfRemove admin-gate (only SelfRemove
      // proposals are dropped), which is exactly how we evict a
      // ghost-admin leaver. See `docs/ADMIN_LEAVE_GHOST_BUG.md`.
      final result = await _stageOrClear(
        () => manager.removeMembers(
          mlsGroupId: groupId,
          memberPubkeys: [memberPubkeyHex],
        ),
        mlsGroupId: mlsGroupId,
        label: 'remove member',
      );

      if (!await _commitAndPublish(
        mlsGroupId: mlsGroupId,
        eventJson: result.evolutionEventJson,
        relays: relays,
        label: 'remove member',
      )) {
        throw const CircleServiceException('Failed to remove member');
      }
    } on CircleServiceException {
      rethrow;
    } on Object catch (e) {
      debugPrint('Failed to remove member: ${e.runtimeType}');
      throw const CircleServiceException('Failed to remove member');
    }
  }

  /// Runs an FFI call that stages a pending commit. If it throws, clears
  /// any lingering pending commit (best-effort) and rethrows — keeps the
  /// MLS group from getting stuck on a half-staged commit.
  Future<UpdateGroupResultFfi> _stageOrClear(
    Future<UpdateGroupResultFfi> Function() stage, {
    required List<int> mlsGroupId,
    required String label,
  }) async {
    try {
      return await stage();
    } on Object catch (e) {
      debugPrint('$label: FFI staging failed: ${e.runtimeType}');
      try {
        await clearPendingCommit(mlsGroupId);
      } on Object catch (_) {
        // No pending commit to clear — expected when staging fails early.
      }
      rethrow;
    }
  }

  /// Fetches the circle's relay list, returning `null` if unavailable.
  Future<List<String>?> _circleRelays(Uint8List groupId) async {
    try {
      final manager = await _ensureInitialized();
      final circle = await manager.getCircle(mlsGroupId: groupId);
      return circle?.circle.relays;
    } on Object catch (e) {
      debugPrint('Circle relay lookup failed: ${e.runtimeType}');
      return null;
    }
  }

  /// Publishes a pending commit's evolution event; finalizes on success or
  /// clears on failure so the MLS group is never left with a dangling commit.
  /// Returns `true` iff the event reached at least one relay and was merged.
  Future<bool> _commitAndPublish({
    required List<int> mlsGroupId,
    required String eventJson,
    required List<String> relays,
    required String label,
  }) async {
    final published = await _publishEvolutionEvent(
      eventJson,
      relays,
      label: label,
    );
    try {
      if (published) {
        await finalizePendingCommit(mlsGroupId);
      } else {
        await clearPendingCommit(mlsGroupId);
      }
    } on Object catch (e) {
      debugPrint(
        '$label: pending-commit ${published ? "finalize" : "clear"} '
        'failed: ${e.runtimeType}',
      );
      return false;
    }
    return published;
  }

  /// Default max publish attempts for evolution events.
  static const int _defaultMaxPublishAttempts = 3;

  /// Max publish attempts for the SelfRemove leave proposal.
  ///
  /// Bumped above the default so the one-shot publish — which is terminal
  /// and immediately followed by a forward-secrecy purge — gets the best
  /// chance of reaching a relay within the user's attention window.
  /// Backoff is exponential (2^attempt seconds), giving 2+4+8+16 = 30s of
  /// retry over 5 attempts.
  static const int _leaveMaxPublishAttempts = 5;

  /// Publishes an evolution event to relays with retry and exponential backoff.
  ///
  /// Attempts up to [maxAttempts] times (backoff: 2s, 4s, 8s, …) before
  /// giving up. Returns `true` if at least one relay accepted the event
  /// on any attempt.
  Future<bool> _publishEvolutionEvent(
    String eventJson,
    List<String> relays, {
    required String label,
    int maxAttempts = _defaultMaxPublishAttempts,
  }) async {
    for (var attempt = 0; attempt < maxAttempts; attempt++) {
      if (attempt > 0) {
        final delaySecs = 1 << attempt; // 2s, 4s, 8s, ...
        debugPrint(
          '$label event: retrying in ${delaySecs}s '
          '(attempt ${attempt + 1}/$maxAttempts)',
        );
        await Future<void>.delayed(Duration(seconds: delaySecs));
      }

      try {
        final publishResult = await _relayService.publishEvent(
          eventJson: eventJson,
          relays: relays,
        );
        if (publishResult.acceptedBy.isNotEmpty) {
          debugPrint(
            '$label event published: '
            '${publishResult.acceptedBy.length} accepted, '
            '${publishResult.failed.length} failed',
          );
          return true;
        }
        debugPrint(
          '$label event rejected by all relays '
          '(attempt ${attempt + 1}/$maxAttempts)',
        );
      } on Object catch (e) {
        debugPrint(
          '$label event: attempt ${attempt + 1} failed: ${e.runtimeType}',
        );
      }
    }

    debugPrint('$label event: all $maxAttempts attempts failed');
    return false;
  }

  @override
  Future<EncryptedLocation> encryptLocation({
    required List<int> mlsGroupId,
    required String senderPubkeyHex,
    required double latitude,
    required double longitude,
    required int retentionSecs,
    required int updateIntervalSecs,
    String? displayName,
    String? precisionLabel,
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
        precisionLabel: precisionLabel,
        updateIntervalSecs: BigInt.from(updateIntervalSecs),
      );

      return EncryptedLocation(
        eventJson: result.eventJson,
        nostrGroupId: result.nostrGroupId.toList(),
        relays: result.relays,
      );
    } on Object catch (_) {
      debugPrint('[Circle] Location encryption failed');
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
        evolutionEventJson: result.evolutionEventJson,
        evolutionMlsGroupId: result.evolutionMlsGroupId?.toList(),
        ignoredReason: result.ignoredReason,
        ignoredMlsGroupId: result.ignoredMlsGroupId?.toList(),
      );
    } on Object catch (_) {
      debugPrint('[Circle] Location decryption failed');
      throw const CircleServiceException('Failed to decrypt location');
    }
  }

  @override
  Future<bool> publishEvolutionEvent({
    required String eventJson,
    required List<String> relays,
    required String label,
  }) async {
    return _publishEvolutionEvent(eventJson, relays, label: label);
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

  @override
  Future<String> signDeletionEvent({
    required List<int> identitySecretBytes,
    required List<String> eventIds,
  }) async {
    final manager = await _ensureInitialized();

    try {
      return manager.signDeletionEvent(
        identitySecretBytes: Uint8List.fromList(identitySecretBytes),
        eventIds: eventIds,
      );
    } on Object catch (e) {
      debugPrint('Failed to sign deletion event: ${e.runtimeType}');
      throw const CircleServiceException('Failed to sign deletion event');
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
      debugPrint('Failed to upsert last-known location: ${e.runtimeType}');
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
      debugPrint('Failed to snapshot last-known locations: ${e.runtimeType}');
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
      debugPrint('Failed to remove last-known member: ${e.runtimeType}');
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
      debugPrint('Failed to remove last-known for sender: ${e.runtimeType}');
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
      debugPrint('Failed to remove last-known circle: ${e.runtimeType}');
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
      debugPrint('Failed to wipe last-known locations: ${e.runtimeType}');
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
      debugPrint('Failed to prune last-known locations: ${e.runtimeType}');
      throw const CircleServiceException(
        'Failed to prune last-known locations',
      );
    }
  }

  // ==================== Contact Management ====================

  @override
  Future<void> setContactDisplayNameIfAbsent({
    required String pubkey,
    required String displayName,
  }) async {
    final manager = await _ensureInitialized();

    try {
      // Fetch existing contact — skip if a name is already set.
      final existing = await manager.getContact(pubkey: pubkey);
      if (existing?.displayName != null) return;

      await manager.setContact(pubkey: pubkey, displayName: displayName);
    } on Object catch (e) {
      // Best-effort: a failure here should not break location processing.
      debugPrint('Failed to save contact display name: ${e.runtimeType}');
    }
  }
}
