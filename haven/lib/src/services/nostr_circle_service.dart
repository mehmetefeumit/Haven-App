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
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:haven/src/providers/live_sync_provider.dart';
import 'package:haven/src/rust/api.dart';
import 'package:haven/src/rust/api.dart' as frb_api;
import 'package:haven/src/services/circle_service.dart';
import 'package:haven/src/services/converge_finalize.dart';
import 'package:haven/src/services/fresh_secret.dart';
import 'package:haven/src/services/leaver_backstop.dart';
import 'package:haven/src/services/nostr_relay_service.dart';
import 'package:haven/src/services/pending_leave_service.dart';
import 'package:haven/src/services/relay_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

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
    bool enableLeaverBackstop = false,
  }) : _relayService = relayService,
       _dataDirectoryProvider =
           dataDirectoryProvider ?? const PathProviderDataDirectory(),
       _keyringInitializer = keyringInitializer ?? initKeyringStore,
       _enableLeaverBackstop = enableLeaverBackstop;

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
       _enableLeaverBackstop = false,
       _manager = injectedManager,
       _initialized = true;

  final RelayService _relayService;
  final DataDirectoryProvider _dataDirectoryProvider;
  final KeyringInitializer _keyringInitializer;

  /// Whether this instance runs the REV-1 leaver backstop (driver 2) after a
  /// `propose_leave`.
  ///
  /// `true` for the foreground service (`circleServiceProvider`), which authors
  /// leaves; `false` for the background isolate (`withInjectedManager`, which
  /// never does) and the launch-time wipe-only service — there the leave wipes
  /// immediately, exactly as under flag-off. This is a plain enable flag, not a
  /// secret provider: the backstop touches no secret material (`propose_leave`
  /// publishes under an ephemeral key — Rule 9, nothing to materialise). A
  /// concurrent-logout abort is enforced by the `_wiped` latch inside
  /// [_runLeaverBackstop], not by this flag.
  final bool _enableLeaverBackstop;

  /// Delay between leaver-backstop membership polls. Sized around the M6 settle
  /// window so a peer's removal commit has time to land and be processed by the
  /// live-sync engine before the next poll. Bounds the total re-issue tail to
  /// `budget × delay` (≈24 s) before the wipe proceeds regardless.
  static const Duration _leaverPollDelay = Duration(seconds: 8);
  CircleManagerFfi? _manager;
  bool _initialized = false;
  Completer<void>? _initCompleter;

  /// M10: one-way latch set on logout wipe. Once wiped, this instance MUST
  /// NEVER re-open circles.db — otherwise an in-flight maintenance/engine tick
  /// that calls `getCircleManagerFfi()` after the file was deleted would
  /// SQLite-create a fresh (decryptable) DB + keyring key, defeating the wipe.
  /// The provider is invalidated after logout, so a fresh login gets a fresh
  /// (un-wiped) instance.
  bool _wiped = false;

  /// Completes once [closeAndInvalidate] latches [_wiped]. A live-sync converge
  /// finalize loop races its settle wait against this so a logout / leave that
  /// lands mid-window unblocks the wait immediately instead of stalling for the
  /// full [settleWindowSecs], then bails without converging (M11 L1 —
  /// no-resurrection, paired with the `isTornDown` short-circuit). Completed at
  /// most once; a converge started after teardown sees it already done.
  final Completer<void> _teardownSignal = Completer<void>();

  /// Initializes the circle manager with persistent storage.
  ///
  /// Must be called before any other methods.
  /// Uses the application documents directory for storage.
  /// Thread-safe: concurrent calls will wait for the first initialization.
  Future<void> initialize() {
    // M10: refuse to (re-)open after a logout wipe — see [_wiped].
    if (_wiped) {
      return Future.error(
        const CircleServiceException('circle service was wiped'),
      );
    }
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
      final manager = await CircleManagerFfi.newInstance(dataDir: dataDir);
      // M10 (H1 in-flight race): the service may have been wiped/latched while
      // this init was suspended at the awaited open above. If so, do NOT adopt
      // the just-(re)created handle — a caller receiving it would operate on a
      // DB that logout is about to delete, and the on-disk file + keyring key
      // that newInstance() created are deleted by the wipeAllMlsState() that
      // deleteIdentity() runs AFTER closeAndInvalidate() drains this future.
      // Fail closed so no live manager escapes over a doomed DB.
      if (_wiped) {
        _manager = null;
        _initialized = false;
        _initCompleter = null;
        completer.completeError(
          const CircleServiceException('circle service was wiped'),
        );
        return;
      }
      _manager = manager;
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

  /// Returns the underlying [CircleManagerFfi] handle, initializing
  /// first if needed.
  ///
  /// Exposed so adjacent services that need access to the same
  /// authoritative FFI manager (e.g. [`NostrRelayPreferencesService`])
  /// can share one handle. Holding two managers against the same
  /// SQLCipher DB would split MLS state across two in-memory MDK caches
  /// and risk SQLite contention; consumers MUST go through this getter.
  Future<CircleManagerFfi> getCircleManagerFfi() => _ensureInitialized();

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
      npub: ffiMember.npub,
      displayName: ffiMember.displayName,
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
      //
      // When neither the caller nor any member supplies a URL, we pass an
      // empty list to Rust intentionally — Rust's `create_circle` then
      // substitutes the user's Inbox relays (kind 10050) and falls back
      // to DEFAULT_RELAYS if those are also empty. This keeps the
      // substitution policy in one place (Rust) rather than duplicated
      // here, and ensures the user's customized inbox relays are picked
      // up automatically on circle creation.
      final memberRelays = memberKeyPackages
          .expand((kp) => kp.relays)
          .toSet()
          .toList();
      final circleRelays = relays?.isNotEmpty ?? false
          ? relays!
          : memberRelays; // empty → Rust substitutes user Inbox → defaults

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
      // FFI message is pre-redacted (hex ≥16 chars → [REDACTED]); safe
      // for developer logs.
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
      debugPrint('[SelfUpdate] starting');
      final groupId = Uint8List.fromList(mlsGroupId);

      // Live-sync engine ON: converge against concurrent same-epoch commits
      // instead of eagerly merging. (`stageSelfUpdateConverging` returns null
      // when the engine is off — a flag race — in which case we fall through to
      // the legacy eager path below.)
      //
      // NOTE: this branch is dead under the shipped flags — it also requires
      // the periodic driver (`enablePeriodicSelfUpdate`, currently false) to
      // call `selfUpdate` at all. Flipping only `liveSyncEnabled` does not
      // re-enable rotation.
      if (liveSyncEnabled) {
        final ctx = await _convergeContext(groupId);
        if (ctx == null) {
          debugPrint('[SelfUpdate] skipped: circle relays unavailable');
          return;
        }
        final staged = await stageSelfUpdateConverging(
          mlsGroupId: mlsGroupId,
          nostrGroupId: ctx.nostrGroupId,
        );
        if (staged != null) {
          // Self-update intent is None → never re-stages, no Welcomes. The
          // outcome is ignored on purpose: a rolled-back rotation (notApplied)
          // is benign — the hourly self-update scheduler re-queries it and
          // retries, so there is nothing to surface to the user here.
          await _runConvergingFinalize(
            mlsGroupId: mlsGroupId,
            nostrGroupId: ctx.nostrGroupId,
            relays: ctx.relays,
            intent: const ConvergeIntentFfi(
              kind: ConvergeIntentKind.none,
              pubkeys: [],
            ),
            label: 'self-update',
            commitJson: staged.commitJson,
            stagedEpoch: staged.stagedEpoch,
          );
          return;
        }
      }

      // Fetch circle relays for publishing.
      List<String>? relays;
      try {
        final circle = await manager.getCircle(mlsGroupId: groupId);
        relays = circle?.circle.relays;
      } on Object catch (e) {
        debugPrint('[SelfUpdate] relay lookup failed: ${e.runtimeType}');
      }

      if (relays == null || relays.isEmpty) {
        debugPrint('[SelfUpdate] skipped: circle relays unavailable');
        return;
      }

      debugPrint('[SelfUpdate] staging pending commit via FFI');
      final result = await manager.selfUpdate(mlsGroupId: groupId);

      debugPrint(
        '[SelfUpdate] publishing commit event to ${relays.length} relay(s)',
      );
      final published = await _publishEvolutionEvent(
        result.evolutionEventJson,
        relays,
        label: 'self-update',
      );

      if (published) {
        await finalizePendingCommit(mlsGroupId);
        debugPrint('[SelfUpdate] finalized locally');
      } else {
        debugPrint('[SelfUpdate] publish failed, rolling back');
        try {
          await clearPendingCommit(mlsGroupId);
        } on Object catch (e) {
          // If this also fails, the residual pending commit will block
          // future commit-staging operations on this group until the
          // downstream pre-clear paths run (e.g. propose_leave).
          debugPrint(
            '[SelfUpdate] clearPendingCommit failed after publish failure: '
            '${e.runtimeType}',
          );
        }
      }
    } on Object catch (e) {
      // Self-update is best-effort (MIP-02 requires completion within 24h).
      // Log and return — the hourly selfUpdateProvider retries missed rotations.
      debugPrint('[SelfUpdate] failed: ${e.runtimeType}');
    }
  }

  @override
  Future<void> leaveCircle({
    required List<int> mlsGroupId,
    required String selfPubkeyHex,
  }) async {
    final manager = await _ensureInitialized();
    final groupId = Uint8List.fromList(mlsGroupId);

    // Stage tracker: updated before each fallible step so a failure log can
    // pinpoint where in the multi-step flow we tripped. FFI error strings
    // are pre-redacted by `redact_hex_sequences` on the Rust side, so it is
    // safe to surface them through `debugPrint` (developer-only output).
    var stage = 'planLeave';
    debugPrint('[Leave] starting');
    try {
      final plan = await manager.planLeave(
        mlsGroupId: groupId,
        selfPubkeyHex: selfPubkeyHex,
      );
      debugPrint('[Leave] plan kind: ${plan.kind.name}');

      switch (plan.kind) {
        case LeavePlanKindFfi.orphanLocalOnly:
          stage = 'completeLeave (orphan)';
          await manager.completeLeave(mlsGroupId: groupId);
          debugPrint('[Leave] completed (orphan)');
          return;
        case LeavePlanKindFfi.abandon:
          stage = 'abandonCircleLocalOnly';
          await manager.abandonCircleLocalOnly(mlsGroupId: groupId);
          debugPrint('[Leave] completed (abandon)');
          return;
        case LeavePlanKindFfi.nonAdmin:
        case LeavePlanKindFfi.adminHandoff:
        case LeavePlanKindFfi.adminDemote:
          break;
      }

      // Handoff / demotion / leave publish each target the circle's relays.
      // Skip publishing when relays are unavailable — do NOT fall back to
      // defaults (would leak group metadata to unrelated relays).
      stage = 'lookup circle relays';
      final relays = await _circleRelays(groupId);
      if (relays == null || relays.isEmpty) {
        debugPrint('[Leave] aborted: circle relays unavailable');
        throw const CircleServiceException('Failed to leave circle');
      }
      debugPrint('[Leave] using ${relays.length} relay(s)');

      if (plan.kind == LeavePlanKindFfi.adminHandoff) {
        final successor = plan.successorHex;
        if (successor == null) {
          debugPrint('[Leave] aborted: handoff plan missing successor');
          throw const CircleServiceException('Failed to leave circle');
        }
        stage = 'proposeAdminHandoff';
        final promote = await manager.proposeAdminHandoff(
          mlsGroupId: groupId,
          successorHex: successor,
        );
        stage = 'publish admin handoff commit';
        if (!await _commitAndPublish(
          mlsGroupId: mlsGroupId,
          eventJson: promote.evolutionEventJson,
          relays: relays,
          label: 'admin handoff',
        )) {
          debugPrint('[Leave] aborted: admin handoff publish failed');
          throw const CircleServiceException('Failed to leave circle');
        }
      }

      if (plan.kind == LeavePlanKindFfi.adminHandoff ||
          plan.kind == LeavePlanKindFfi.adminDemote) {
        stage = 'proposeSelfDemote';
        final demote = await _stageOrClear(
          () => manager.proposeSelfDemote(mlsGroupId: groupId),
          mlsGroupId: mlsGroupId,
          label: 'self-demote',
        );
        stage = 'publish self-demote commit';
        if (!await _commitAndPublish(
          mlsGroupId: mlsGroupId,
          eventJson: demote.evolutionEventJson,
          relays: relays,
          label: 'self-demote',
        )) {
          debugPrint('[Leave] aborted: self-demote publish failed');
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
      stage = 'proposeLeave';
      final leave = await manager.proposeLeave(mlsGroupId: groupId);
      stage = 'publish leave proposal';
      if (!await _publishEvolutionEvent(
        leave.evolutionEventJson,
        relays,
        label: 'leave',
        maxAttempts: _leaveMaxPublishAttempts,
      )) {
        debugPrint('[Leave] aborted: leave proposal publish failed');
        throw const CircleServiceException('Failed to leave circle');
      }

      // REV-1 leaver backstop (driver 2): under live-sync a race-losing
      // SelfRemove can be deferred in EVERY remaining member's settle window
      // at once. Rather than wipe immediately and risk a stale roster ghost,
      // we poll our own removal and re-issue a fresh SelfRemove until removed
      // (bounded), then wipe. A durable marker lets a crashed-then-returned
      // leaver finish the leave on the next launch. Inert under flag-off, or
      // when the backstop is disabled (the background isolate / launch-time
      // wipe-only service, neither of which authors leaves): the leave wipes
      // immediately, exactly as before.
      if (liveSyncEnabled && _enableLeaverBackstop) {
        stage = 'leaver backstop';
        await _runLeaverBackstop(
          manager: manager,
          groupId: groupId,
          selfPubkeyHex: selfPubkeyHex,
          relays: relays,
        );
        debugPrint('[Leave] completed (backstop)');
        return;
      }

      stage = 'completeLeave';
      await manager.completeLeave(mlsGroupId: groupId);
      debugPrint('[Leave] completed');
    } on CircleServiceException {
      // Already logged at the failure site with stage context.
      rethrow;
    } on Object catch (e) {
      // `e` is either an FFI String (redacted by `redact_hex_sequences` on
      // the Rust side) or a Dart-thrown Exception whose message is
      // app-controlled — both safe for developer logs.
      debugPrint('[Leave] failed at $stage: ${e.runtimeType}');
      throw const CircleServiceException('Failed to leave circle');
    }
  }

  @override
  Future<bool> stillAMember({
    required List<int> mlsGroupId,
    required String ownPubkeyHex,
  }) async {
    final manager = await _ensureInitialized();
    try {
      return await manager.stillAMember(
        mlsGroupId: Uint8List.fromList(mlsGroupId),
        pubkeyHex: ownPubkeyHex,
      );
    } on Object catch (e) {
      // FFI error strings are hex-redacted on the Rust side; log only the type.
      debugPrint('Failed to check membership: ${e.runtimeType}');
      throw const CircleServiceException('Failed to check membership');
    }
  }

  /// Runs the REV-1 leaver backstop for a departing member (live-sync only).
  ///
  /// Sets a durable "leave in progress" marker, then polls our own removal via
  /// `still_a_member`, re-issuing a fresh SelfRemove on each still-a-member
  /// poll (bounded), and wipes the leaver's MLS state the moment the removal
  /// lands (or the budget is exhausted). Clears the durable marker once the
  /// wipe completes; a crash mid-backstop leaves the marker set so the launch
  /// resume ([PendingLeaveService.resumePendingLeaves]) finishes the leave.
  ///
  /// The loop uses no identity secret (`propose_leave` publishes under an
  /// ephemeral key — Rule 9, nothing to materialise). A concurrent logout that
  /// latches [_wiped] aborts the loop before any manager write via the
  /// `abortIfWiped` gate below, so the durable marker persists for resume
  /// rather than the wipe running against a half-torn-down identity.
  Future<void> _runLeaverBackstop({
    required CircleManagerFfi manager,
    required Uint8List groupId,
    required String selfPubkeyHex,
    required List<String> relays,
  }) async {
    // Resolve the circle's PUBLIC nostr_group_id for the durable marker.
    List<int>? nostrGroupId;
    try {
      final circle = await manager.getCircle(mlsGroupId: groupId);
      nostrGroupId = circle?.circle.nostrGroupId.toList();
    } on Object catch (e) {
      debugPrint(
        '[Leave] backstop: nostr_group_id lookup failed: ${e.runtimeType}',
      );
    }

    // Durable "leave in progress" marker (best-effort — must NEVER block the
    // leave). Set BEFORE the first re-issue so a crash resumes on next launch.
    PendingLeaveService? marker;
    if (nostrGroupId != null) {
      try {
        final prefs = await SharedPreferences.getInstance();
        marker = PendingLeaveService(prefs: prefs);
        await marker.markLeaving(nostrGroupId);
      } on Object catch (e) {
        debugPrint(
          '[Leave] backstop: durable marker set failed: ${e.runtimeType}',
        );
        marker = null;
      }
    }

    // Non-secret concurrent-logout gate. Replaces the old secret-fetch presence
    // check (Rule 9 — no secret is materialised) with the service's own wipe
    // latch, which is set EARLIER in logout (`closeAndInvalidate`, before the
    // identity secret is even removed) and lives on this same instance, so it
    // cannot be raced by the manager handle this loop still holds. Throwing
    // stops the loop before any manager write and propagates out so the durable
    // marker persists (resume retries) — never a re-issue or complete_leave
    // against a wiped identity.
    void abortIfWiped() {
      if (_wiped) {
        throw const CircleServiceException('circle service wiped mid-leave');
      }
    }

    await runLeaverBackstop(
      stillAMember: () async {
        abortIfWiped();
        try {
          return await manager.stillAMember(
            mlsGroupId: groupId,
            pubkeyHex: selfPubkeyHex,
          );
        } on Object catch (e) {
          // Conservative: on an infra error assume we are still a member and
          // keep trying within budget — never PRESUME removal (which would wipe
          // prematurely).
          debugPrint(
            '[Leave] backstop: membership poll failed, assuming still a '
            'member: ${e.runtimeType}',
          );
          return true;
        }
      },
      // `propose_leave` publishes under an ephemeral key and consumes no
      // identity secret, so the re-issue takes none (Rule 9 — nothing to
      // materialise); `abortIfWiped` is the non-secret concurrent-logout gate.
      reissue: () {
        abortIfWiped();
        return _reissueLeaveProposal(manager, groupId, relays);
      },
      completeLeave: () {
        abortIfWiped();
        return manager.completeLeave(mlsGroupId: groupId);
      },
      waitBetween: (_) => Future<void>.delayed(_leaverPollDelay),
      // maxReissues defaults to kDefaultLeaverReissueBudget (leaver_backstop).
    );

    // The backstop ran complete_leave — the leaver's MLS state is wiped. Clear
    // the durable marker (best-effort; a stale marker self-heals on next launch
    // when the circle is no longer present).
    if (marker != null && nostrGroupId != null) {
      await marker.clearLeaving(nostrGroupId);
    }
  }

  /// Re-issues a fresh SelfRemove (`propose_leave` + publish) for the backstop.
  ///
  /// Best-effort: a failed re-issue is retried on the next poll (within the
  /// budget), so it NEVER throws — a transient publish failure must not abort
  /// the backstop or block the eventual wipe.
  Future<void> _reissueLeaveProposal(
    CircleManagerFfi manager,
    Uint8List groupId,
    List<String> relays,
  ) async {
    try {
      final leave = await manager.proposeLeave(mlsGroupId: groupId);
      await _publishEvolutionEvent(
        leave.evolutionEventJson,
        relays,
        label: 'leave re-issue',
        maxAttempts: _leaveMaxPublishAttempts,
      );
    } on Object catch (e) {
      debugPrint('[Leave] SelfRemove re-issue failed: ${e.runtimeType}');
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
      // Live-sync engine ON: converge against concurrent same-epoch admin
      // commits (two admins removing different members at epoch N would fork
      // under the eager path). Falls through to legacy when the engine is off.
      if (liveSyncEnabled) {
        final ctx = await _convergeContext(groupId);
        if (ctx == null) {
          debugPrint('Circle relays unavailable — aborting remove');
          throw const CircleServiceException('Failed to remove member');
        }
        final staged = await stageRemoveMembersConverging(
          mlsGroupId: mlsGroupId,
          nostrGroupId: ctx.nostrGroupId,
          memberPubkeys: [memberPubkeyHex],
        );
        if (staged != null) {
          final outcome = await _runConvergingFinalize(
            mlsGroupId: mlsGroupId,
            nostrGroupId: ctx.nostrGroupId,
            relays: ctx.relays,
            intent: ConvergeIntentFfi(
              kind: ConvergeIntentKind.remove,
              pubkeys: [memberPubkeyHex],
            ),
            label: 'remove member',
            commitJson: staged.commitJson,
            stagedEpoch: staged.stagedEpoch,
            reStage: (attempt) async {
              final next = await stageRemoveMembersConverging(
                mlsGroupId: mlsGroupId,
                nostrGroupId: ctx.nostrGroupId,
                memberPubkeys: [memberPubkeyHex],
              );
              return next == null
                  ? null
                  : (
                      commitJson: next.commitJson,
                      stagedEpoch: next.stagedEpoch,
                    );
            },
          );
          // The removal was not applied (bounded re-stage exhausted or the
          // engine stopped mid-flow). No scheduler retries membership ops, so
          // surface a retryable error instead of a silent success.
          if (outcome == ConvergeFinalizeOutcome.notApplied) {
            throw const CircleServiceException('Failed to remove member');
          }
          return;
        }
      }

      final relays = await _circleRelays(groupId);
      if (relays == null || relays.isEmpty) {
        debugPrint('Circle relays unavailable — aborting remove');
        throw const CircleServiceException('Failed to remove member');
      }

      // MDK's `remove_members` stages a pending commit and returns the
      // `kind:445` evolution event for the admin to publish.
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

  @override
  Future<AddMemberResult> addMember({
    required Future<List<int>> Function() secretProvider,
    required List<int> mlsGroupId,
    required List<KeyPackageData> memberKeyPackages,
    List<String> creatorFallbackRelays = const [],
  }) async {
    final manager = await _ensureInitialized();
    final groupId = Uint8List.fromList(mlsGroupId);

    try {
      final relays = await _circleRelays(groupId);
      if (relays == null || relays.isEmpty) {
        debugPrint('[AddMember] circle relays unavailable — aborting');
        throw const CircleServiceException('Failed to add member');
      }

      // Convert KeyPackageData to MemberKeyPackageFfi (mirrors createCircle).
      final ffiMembers = memberKeyPackages
          .map(
            (kp) => MemberKeyPackageFfi(
              keyPackageJson: kp.eventJson,
              inboxRelays: kp.relays,
              nip65Relays: kp.nip65Relays,
            ),
          )
          .toList();

      // Live-sync engine ON: converge the Add against concurrent same-epoch
      // admin commits. Welcomes are published only after a `Merged` converge
      // (a losing Add references an epoch that never committed). Falls through
      // to legacy when the engine is off.
      if (liveSyncEnabled) {
        final ctx = await _convergeContext(groupId);
        if (ctx == null) {
          debugPrint('[AddMember] circle relays unavailable — aborting');
          throw const CircleServiceException('Failed to add member');
        }
        final memberPubkeys = memberKeyPackages.map((kp) => kp.pubkey).toList();
        final staged = await withFreshSecret(
          secretProvider,
          (secret) => stageAddMembersConverging(
            identitySecretBytes: secret,
            mlsGroupId: mlsGroupId,
            nostrGroupId: ctx.nostrGroupId,
            members: ffiMembers,
            creatorFallbackRelays: creatorFallbackRelays,
          ),
        );
        if (staged != null) {
          var welcomes = staged.welcomeEvents;
          var welcomesSent = 0;
          final outcome = await _runConvergingFinalize(
            mlsGroupId: mlsGroupId,
            nostrGroupId: ctx.nostrGroupId,
            relays: ctx.relays,
            intent: ConvergeIntentFfi(
              kind: ConvergeIntentKind.add,
              pubkeys: memberPubkeys,
            ),
            label: 'add member',
            commitJson: staged.commitJson,
            stagedEpoch: staged.stagedEpoch,
            onMerged: () async {
              welcomesSent = await _publishConvergedWelcomes(
                welcomes,
                'add member',
              );
            },
            reStage: (attempt) async {
              // Re-fetch the secret FRESH for every re-stage (M11 L1, Rule 9):
              // it lives only for this FFI round-trip, scrubbed before the next
              // settle wait — never held across the ~24s of re-staging.
              final next = await withFreshSecret(
                secretProvider,
                (secret) => stageAddMembersConverging(
                  identitySecretBytes: secret,
                  mlsGroupId: mlsGroupId,
                  nostrGroupId: ctx.nostrGroupId,
                  members: ffiMembers,
                  creatorFallbackRelays: creatorFallbackRelays,
                ),
              );
              if (next == null) return null;
              welcomes = next.welcomeEvents;
              return (
                commitJson: next.commitJson,
                stagedEpoch: next.stagedEpoch,
              );
            },
          );
          // The Add was not applied (bounded re-stage exhausted or the engine
          // stopped mid-flow): no member was added and no Welcome was sent.
          // Surface a retryable error rather than a false-success result.
          if (outcome == ConvergeFinalizeOutcome.notApplied) {
            throw const CircleServiceException('Failed to add member');
          }
          // `merged` sent our Welcomes (welcomesSent); `adoptedSatisfied` means
          // a sibling admin's winning commit already added the member and sent
          // their own Welcome, so we sent none — welcomesTotal reflects the
          // Welcomes we had prepared.
          return AddMemberResult(
            welcomesSent: welcomesSent,
            welcomesTotal: welcomes.length,
          );
        }
      }

      // Torn down (logout / leave) after we captured `manager` above: do NOT
      // stage on the wiped handle — an MLS write could re-create state the M10
      // sweep removed. (The live-sync branch above is already guarded by the
      // converge loop's isTornDown; this legacy fall-through needs its own.)
      if (_wiped) {
        throw const CircleServiceException('Failed to add member');
      }

      // Stage the MLS Add commit inside an inline try/clear because the
      // result type is AddMembersResultFfi, not UpdateGroupResultFfi, so
      // the typed _stageOrClear helper does not apply here.
      final AddMembersResultFfi staged;
      try {
        staged = await withFreshSecret(secretProvider, (secret) {
          // Re-check inside the closure — `_wiped` can flip during the
          // `secretProvider()` await above the FFI (TOCTOU-tight).
          if (_wiped) {
            throw const CircleServiceException('Failed to add member');
          }
          return manager.addMembersToCircle(
            identitySecretBytes: secret,
            mlsGroupId: groupId,
            members: ffiMembers,
            creatorFallbackRelays: creatorFallbackRelays,
          );
        });
      } on Object catch (e) {
        debugPrint('add member: FFI staging failed: ${e.runtimeType}');
        try {
          await clearPendingCommit(mlsGroupId);
        } on Object catch (_) {
          // No pending commit to clear — expected when staging fails early.
        }
        rethrow;
      }

      // Publish the kind:445 Add commit; finalize on success, clear on failure.
      if (!await _commitAndPublish(
        mlsGroupId: mlsGroupId,
        eventJson: staged.evolutionEventJson,
        relays: relays,
        label: 'add member',
      )) {
        throw const CircleServiceException('Failed to add member');
      }

      // Only after a successful finalize: publish gift-wrapped Welcome(s).
      final total = staged.welcomeEvents.length;
      final results = await Future.wait(
        staged.welcomeEvents.map(
          (w) => _relayService
              .publishWelcome(
                welcomeEvent: GiftWrappedWelcome(
                  recipientPubkey: w.recipientPubkey,
                  recipientRelays: w.recipientRelays,
                  eventJson: w.eventJson,
                ),
              )
              .then((_) => true)
              .onError((_, _) {
                debugPrint('[AddMember] welcome send failed');
                return false;
              }),
        ),
      );

      return AddMemberResult(
        welcomesSent: results.where((ok) => ok).length,
        welcomesTotal: total,
      );
    } on CircleServiceException {
      rethrow;
    } on Object catch (e) {
      debugPrint('Failed to add member: ${e.runtimeType}');
      throw const CircleServiceException('Failed to add member');
    }
  }

  @override
  Future<void> updateCircleRelays({
    required List<int> mlsGroupId,
    required List<String> newRelays,
  }) async {
    final manager = await _ensureInitialized();
    final groupId = Uint8List.fromList(mlsGroupId);

    try {
      // Read the circle's CURRENT relay list BEFORE staging. The commit event
      // must be published to the UNION of (current relays ∪ newRelays) so
      // members that only listen on a relay being removed still receive the
      // relay-rotation commit. Reading before staging avoids a TOCTOU window
      // where finalize would have already mutated circle.relays.
      final currentRelays = await _circleRelays(groupId);
      if (currentRelays == null || currentRelays.isEmpty) {
        debugPrint('[UpdateRelays] circle relays unavailable — aborting');
        throw const CircleServiceException('Failed to update circle relays');
      }

      // Compute the publish union: deduplicated, order-stable.
      final publishRelays = {...currentRelays, ...newRelays}.toList();

      // Stage the GroupContextExtensions commit via the FFI. _stageOrClear
      // handles a staging failure by best-effort clearing any dangling pending
      // commit and rethrowing — keeps the MLS group from getting wedged.
      final result = await _stageOrClear(
        () => manager.updateCircleRelays(
          mlsGroupId: groupId,
          newRelays: newRelays,
        ),
        mlsGroupId: mlsGroupId,
        label: 'update circle relays',
      );

      // Publish to the union set, then finalize (or clear) locally.
      // Using a bespoke publish+finalize rather than the shared
      // _commitAndPublish so we can call finalizeRelayUpdate (which also
      // re-syncs admin's circle.relays) instead of finalizePendingCommit.
      final published = await _publishEvolutionEvent(
        result.evolutionEventJson,
        publishRelays,
        label: 'update circle relays',
      );

      try {
        if (published) {
          // finalizeRelayUpdate merges the commit AND re-syncs the admin's
          // own circle.relays to newRelays, so the admin converges to the
          // new set immediately without waiting for the receive path.
          //
          // If this throws AFTER the MLS merge already committed (epoch
          // advanced in Rust), the admin's local circle.relays may transiently
          // LAG the merged MLS state — never get ahead of it. That lag
          // self-heals idempotently: the next commit the admin processes runs
          // the decrypt_location re-sync hook, and a restart re-derives the
          // row from MDK. So the throw below is safe to surface.
          await manager.finalizeRelayUpdate(mlsGroupId: groupId);
        } else {
          await manager.clearPendingCommit(mlsGroupId: groupId);
        }
      } on Object catch (e) {
        debugPrint(
          'update circle relays: pending-commit '
          '${published ? "finalizeRelayUpdate" : "clear"} '
          'failed: ${e.runtimeType}',
        );
        throw const CircleServiceException('Failed to update circle relays');
      }

      if (!published) {
        throw const CircleServiceException('Failed to update circle relays');
      }
    } on CircleServiceException {
      rethrow;
    } on Object catch (e) {
      debugPrint('Failed to update circle relays: ${e.runtimeType}');
      throw const CircleServiceException('Failed to update circle relays');
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

  // ============== M6-4: converging finalize (path A, live-sync) ==============
  //
  // When the live-sync engine is running, a foreground membership/self-update
  // commit converges against concurrent same-epoch sibling commits instead of
  // eagerly merging its own (which forks). The Rust converging FFI (`stage_*`
  // opens a settle window + stages under the per-circle gate; `convergeAfter
  // Window` takes the buffered competitors + runs MIP-03 convergence) does the
  // gating; this orchestrates the publish-during-window + the result.

  /// The publish context for a converging finalize: the circle's relays + its
  /// pseudonymous `nostr_group_id` (the gate/settle key). `null` if unavailable.
  Future<({List<String> relays, List<int> nostrGroupId})?> _convergeContext(
    Uint8List groupId,
  ) async {
    try {
      final circle = await (await _ensureInitialized()).getCircle(
        mlsGroupId: groupId,
      );
      final relays = circle?.circle.relays;
      if (circle == null || relays == null || relays.isEmpty) return null;
      return (relays: relays, nostrGroupId: circle.circle.nostrGroupId);
    } on Object catch (e) {
      debugPrint('converge context lookup failed: ${e.runtimeType}');
      return null;
    }
  }

  /// Aborts an open settle window + clears any dangling staged commit. Called
  /// on a publish/converge error or an engine-stopped-mid-flow (so the circle
  /// is never wedged in regime 2 / left holding an unmerged commit).
  Future<void> _abortConvergeAndClear(
    List<int> mlsGroupId,
    List<int> nostrGroupId,
  ) async {
    // Torn down: the M10 logout/leave sweep already deleted the group and its
    // pending commit and closed circles.db. Any FFI here would re-open the DB
    // (defeating the wipe) or throw — there is nothing left to abort.
    if (_wiped) return;
    try {
      final aborted = await abortConvergingWindow(
        mlsGroupId: mlsGroupId,
        nostrGroupId: nostrGroupId,
      );
      if (!aborted) {
        // Engine off → its window is already gone, but a CS1 pending commit
        // may dangle in MDK; clear it directly (the legacy rollback).
        await clearPendingCommit(mlsGroupId);
      }
    } on Object catch (e) {
      debugPrint('converge cleanup failed: ${e.runtimeType}');
    }
  }

  /// Publishes the gift-wrapped Welcomes after a `Merged` Add convergence
  /// (never for a losing Add — it references an epoch that never committed).
  Future<int> _publishConvergedWelcomes(
    List<GiftWrappedWelcomeFfi> welcomes,
    String label,
  ) async {
    var sent = 0;
    for (final w in welcomes) {
      try {
        await _relayService.publishWelcome(
          welcomeEvent: GiftWrappedWelcome(
            recipientPubkey: w.recipientPubkey,
            recipientRelays: w.recipientRelays,
            eventJson: w.eventJson,
          ),
        );
        sent++;
      } on Object catch (e) {
        debugPrint('$label: welcome send failed: ${e.runtimeType}');
      }
    }
    return sent;
  }

  /// Runs the settle-window finalize after CS1 staged a commit + opened the
  /// window: publish the commit DURING the window (so a sibling admin can
  /// collect it), wait [settleWindowSecs], then converge under the gate. On
  /// `AdoptedWinner` with a still-pending intent / `RolledBack`, re-stages
  /// (bounded ≤2) via [reStage]. On `Merged`, runs [onMerged] (e.g. publish
  /// Welcomes). On ANY publish/converge error — or the engine stopping mid-flow
  /// — aborts the window + clears the commit (never leaves a dangling commit).
  ///
  /// Throws [CircleServiceException] on a hard publish/converge failure so the
  /// caller surfaces a generic error, matching the legacy path. Returns the
  /// terminal [ConvergeFinalizeOutcome] so a membership caller can distinguish
  /// an applied change ([ConvergeFinalizeOutcome.merged] /
  /// [ConvergeFinalizeOutcome.adoptedSatisfied]) from one that was NOT applied
  /// ([ConvergeFinalizeOutcome.notApplied] — bounded re-stage exhausted, or the
  /// engine stopped mid-flow) and surface a retryable error.
  Future<ConvergeFinalizeOutcome> _runConvergingFinalize({
    required List<int> mlsGroupId,
    required List<int> nostrGroupId,
    required List<String> relays,
    required ConvergeIntentFfi intent,
    required String label,
    required String commitJson,
    required BigInt stagedEpoch,
    Future<void> Function()? onMerged,
    Future<({String commitJson, BigInt stagedEpoch})?> Function(int attempt)?
    reStage,
  }) {
    // The loop logic lives in the testable `runConvergeFinalize` free function;
    // here we inject the real FFI/relay ops.
    return runConvergeFinalize(
      label: label,
      commitJson: commitJson,
      stagedEpoch: stagedEpoch,
      publish: (c) => _publishEvolutionEvent(c, relays, label: label),
      // Race the settle wait against teardown so a logout / leave that lands
      // mid-window unblocks immediately; `isTornDown` then bails before the
      // converge FFI so no MLS write resurrects the wiped group (M11 L1).
      waitWindow: () => Future.any<void>([
        Future<void>.delayed(Duration(seconds: settleWindowSecs().toInt())),
        _teardownSignal.future,
      ]),
      converge: (c, e) => convergeAfterWindow(
        mlsGroupId: mlsGroupId,
        nostrGroupId: nostrGroupId,
        ourCommitJson: c,
        stagedEpoch: e,
        intent: intent,
      ),
      abort: () => _abortConvergeAndClear(mlsGroupId, nostrGroupId),
      onHardError: () => throw CircleServiceException('Failed to $label'),
      onMerged: onMerged,
      reStage: reStage,
      isTornDown: () => _wiped,
    );
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
    required int updateIntervalSecs,
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
                displayName: loc.displayName,
              ),
        groupUpdated: result.groupUpdated,
        evolutionEventJson: result.evolutionEventJson,
        evolutionMlsGroupId: result.evolutionMlsGroupId?.toList(),
      );
    } on Object catch (_) {
      debugPrint('[Circle] Location decryption failed');
      throw const CircleServiceException('Failed to decrypt location');
    }
  }

  @override
  Future<void> advanceGroupCursorToEventSecs(int eventCreatedAtSecs) async {
    final manager = await _ensureInitialized();
    try {
      await manager.cursorAdvanceGroupToEvent(
        eventCreatedAtSecs: eventCreatedAtSecs,
      );
    } on Object catch (_) {
      // Surface as the class's own exception type (callers treat cursor
      // advance as best-effort; this protects any future
      // `on CircleServiceException` caller).
      throw const CircleServiceException('Failed to advance group sync cursor');
    }
  }

  @override
  Future<void> advanceInboxCursorToWrapSecs(int wrapCreatedAtSecs) async {
    final manager = await _ensureInitialized();
    try {
      await manager.cursorAdvanceInboxToWrap(
        wrapCreatedAtSecs: wrapCreatedAtSecs,
      );
    } on Object catch (_) {
      throw const CircleServiceException('Failed to advance inbox sync cursor');
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
        legacyEventJson: result.legacyEventJson,
        relays: result.relays,
        canonicalHashRef: result.canonicalHashRef,
        dTag: result.dTag,
        canonicalEventId: result.canonicalEventId,
        legacyEventId: result.legacyEventId,
      );
    } on Object {
      throw const CircleServiceException('Failed to sign key package event');
    }
  }

  @override
  Future<void> recordPublishedKeyPackages({
    required List<int> canonicalHashRef,
    required String dTag,
    required String canonicalEventId,
    required String legacyEventId,
  }) async {
    final manager = await _ensureInitialized();
    try {
      await manager.recordPublishedKeyPackages(
        canonicalHashRef: canonicalHashRef,
        dTag: dTag,
        canonicalEventId: canonicalEventId,
        legacyEventId: legacyEventId,
      );
    } on Object {
      throw const CircleServiceException(
        'Failed to record published key package',
      );
    }
  }

  // signRelayListEvent removed — see CircleService doc comment. The
  // FFI sign_relay_list_event method has also been deleted from
  // rust_builder/src/api.rs; the toggle-aware flow lives on
  // RelayPreferencesService.buildRelayListPublish.

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

  @override
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
  }) async {
    final manager = await _ensureInitialized();
    try {
      await manager.upsertLastKnownLocation(
        location: LastKnownLocationFfi(
          nostrGroupId: Uint8List.fromList(nostrGroupId),
          senderPubkey: senderPubkey,
          latitude: latitude,
          longitude: longitude,
          geohash: geohash,
          displayName: displayName,
          timestamp: timestamp.millisecondsSinceEpoch ~/ 1000,
          expiresAt: expiresAt.millisecondsSinceEpoch ~/ 1000,
          purgeAfter: purgeAfter.millisecondsSinceEpoch ~/ 1000,
          updatedAt: updatedAt.millisecondsSinceEpoch ~/ 1000,
        ),
      );
    } on Object catch (e) {
      // The FFI maps the underlying error to `String` via
      // `.map_err(|e| redact_hex_sequences(&e.to_string()))`; surface it so
      // we can distinguish validation failures (e.g. bad nostr_group_id
      // length, malformed pubkey hex) from rusqlite errors (schema /
      // constraint / SQLCipher key issues). Hex sequences inside any
      // rusqlite message are redacted on the Rust side; validation strings
      // only carry field names and lengths — never the values.
      debugPrint('[Upsert] failed (type=${e.runtimeType})');
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
              displayName: row.displayName,
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
  Future<void> wipeAllStagedCommits() async {
    final manager = await _ensureInitialized();
    try {
      await manager.wipeAllStagedCommits();
    } on Object catch (e) {
      debugPrint('Failed to wipe staged commits: ${e.runtimeType}');
      throw const CircleServiceException('Failed to wipe staged commits');
    }
  }

  @override
  Future<void> resetAllSyncCursors() async {
    final manager = await _ensureInitialized();
    try {
      await manager.resetAllSyncCursors();
    } on Object catch (e) {
      debugPrint('Failed to reset sync cursors: ${e.runtimeType}');
      throw const CircleServiceException('Failed to reset sync cursors');
    }
  }

  @override
  Future<void> closeAndInvalidate() async {
    // M10: latch FIRST so any concurrent in-flight caller that reaches
    // `initialize()` after this point is refused a re-open (H1 race fix).
    // Setting this before reading `_initCompleter` below is atomic (no await
    // between), so the in-flight init — whenever it resumes — is guaranteed to
    // see `_wiped` at its post-open re-check and fail closed.
    _wiped = true;
    // Unblock any live-sync converge loop parked in its settle wait so it bails
    // (no-resurrection) instead of stalling the wipe for a full window.
    if (!_teardownSignal.isCompleted) _teardownSignal.complete();
    // M10 (H1 in-flight race): an initialization already suspended at its
    // awaited DB open when we latched will still run to completion and
    // (re)create the circles.db file + keyring key on disk. Drain it here —
    // BEFORE returning — so the wipeAllMlsState() that deleteIdentity() runs
    // next deletes whatever that racing open created, instead of the open
    // landing AFTER the wipe and resurrecting a decryptable DB. The drained
    // init rejects via the `_wiped` re-check in _runInitialization(); swallow.
    final inFlight = _initCompleter?.future;
    if (inFlight != null) {
      try {
        await inFlight;
      } on Object catch (_) {
        // Expected: the in-flight init rejects once `_wiped` is set.
      }
    }
    // Drop the RustOpaque Arc so GC closes the SQLite fd before file deletion.
    _manager = null;
    _initialized = false;
    _initCompleter = null;
  }

  @override
  Future<void> wipeAllMlsState() async {
    // Defensively null the handle in case the caller did not call
    // closeAndInvalidate() first.
    _manager = null;
    _initialized = false;
    _initCompleter = null;
    // Ensure the keyring backend is installed so the FFI wipe can actually
    // REMOVE the SQLCipher keys, not just delete the DB files. At the M10.1
    // launch-retry / pre-create reconcile entry points no circle manager has
    // been initialized yet, so without this the keyring store is absent and
    // key removal silently no-ops, leaving a stale key behind. Idempotent when
    // already installed. Best-effort: if it fails, still proceed with file
    // deletion (the primary objective — no decryptable DB at rest).
    try {
      await _keyringInitializer();
    } on Object catch (e) {
      debugPrint(
        '[SECURITY][NostrCircleService] keyring init before wipe failed '
        '(file deletion still proceeds): ${e.runtimeType}',
      );
    }
    try {
      final dataDir = await _dataDirectoryProvider.getDataDirectory();
      await frb_api.wipeAllMlsState(dataDir: dataDir);
    } on Object catch (e) {
      debugPrint(
        '[SECURITY][NostrCircleService] MLS state wipe failed: '
        '${e.runtimeType}',
      );
      throw const CircleServiceException('Failed to wipe MLS state');
    }
  }

  @override
  Future<void> pruneProcessedGiftWraps({DateTime? now}) async {
    final manager = await _ensureInitialized();
    final nowSecs = (now ?? DateTime.now()).millisecondsSinceEpoch ~/ 1000;
    try {
      await manager.pruneProcessedGiftWraps(nowUnixSecs: nowSecs);
    } on Object catch (e) {
      debugPrint('Failed to prune processed gift wraps: ${e.runtimeType}');
      throw const CircleServiceException(
        'Failed to prune processed gift wraps',
      );
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

  // ==================== Avatar Management ====================

  @override
  Future<AvatarMetaFfi> setMyAvatar(String ownPubkey, Uint8List raw) async {
    final manager = await _ensureInitialized();
    try {
      return await manager.setMyAvatar(ownPubkey: ownPubkey, raw: raw.toList());
    } on Object catch (e) {
      // Log only the runtime type — never the error body, which could
      // contain hex sequences (redacted in Rust) or image bytes.
      debugPrint('[Avatar] setMyAvatar failed: ${e.runtimeType}');
      throw const CircleServiceException('Failed to set avatar');
    }
  }

  @override
  Future<void> clearMyAvatar(String ownPubkey) async {
    final manager = await _ensureInitialized();
    try {
      await manager.clearMyAvatar(ownPubkey: ownPubkey);
    } on Object catch (e) {
      debugPrint('[Avatar] clearMyAvatar failed: ${e.runtimeType}');
      throw const CircleServiceException('Failed to remove avatar');
    }
  }

  @override
  Future<Uint8List?> getMyAvatarThumbnail(String ownPubkey) async {
    final manager = await _ensureInitialized();
    try {
      final bytes = await manager.getMyAvatarThumbnail(ownPubkey: ownPubkey);
      if (bytes == null) return null;
      // Return a copy so the caller holds an independent buffer.
      return Uint8List.fromList(bytes);
    } on Object catch (e) {
      debugPrint('[Avatar] getMyAvatarThumbnail failed: ${e.runtimeType}');
      throw const CircleServiceException('Failed to load avatar');
    }
  }

  @override
  Future<Uint8List?> getMyAvatar(String ownPubkey) async {
    final manager = await _ensureInitialized();
    try {
      final bytes = await manager.getMyAvatar(ownPubkey: ownPubkey);
      if (bytes == null) return null;
      return Uint8List.fromList(bytes);
    } on Object catch (e) {
      debugPrint('[Avatar] getMyAvatar failed: ${e.runtimeType}');
      throw const CircleServiceException('Failed to load avatar');
    }
  }

  // ==================== M2 Avatar Network ====================

  /// Serializes a [SignedEventFfi] to a standard Nostr JSON string.
  ///
  /// Produces `{"id":...,"pubkey":...,"created_at":...,"kind":...,"tags":...,"content":...,"sig":...}`
  /// which is the canonical NIP-01 event format accepted by relays and by
  /// `RelayService.publishEvent`. The field order matches the NIP-01
  /// serialization canon, though relays accept any order.
  static String _signedEventToJson(SignedEventFfi e) {
    return jsonEncode({
      'id': e.id,
      'pubkey': e.pubkey,
      'created_at': e.createdAt,
      'kind': e.kind,
      'tags': e.tags,
      'content': e.content,
      'sig': e.sig,
    });
  }

  @override
  Future<List<String>> buildAvatarShareEvents({
    required List<int> mlsGroupId,
    required String senderPubkeyHex,
    required int updateIntervalSecs,
  }) async {
    final manager = await _ensureInitialized();
    try {
      final events = await manager.buildAvatarShareEvents(
        mlsGroupId: Uint8List.fromList(mlsGroupId),
        senderPubkeyHex: senderPubkeyHex,
        updateIntervalSecs: BigInt.from(updateIntervalSecs),
      );
      return events.map(_signedEventToJson).toList();
    } on Object catch (e) {
      debugPrint('[Avatar] buildAvatarShareEvents failed: ${e.runtimeType}');
      throw const CircleServiceException('Failed to build avatar share events');
    }
  }

  @override
  Future<String> buildAvatarClearEvent({
    required List<int> mlsGroupId,
    required String senderPubkeyHex,
    required int updateIntervalSecs,
  }) async {
    final manager = await _ensureInitialized();
    try {
      final event = await manager.buildAvatarClearEvent(
        mlsGroupId: Uint8List.fromList(mlsGroupId),
        senderPubkeyHex: senderPubkeyHex,
        updateIntervalSecs: BigInt.from(updateIntervalSecs),
      );
      return _signedEventToJson(event);
    } on Object catch (e) {
      debugPrint('[Avatar] buildAvatarClearEvent failed: ${e.runtimeType}');
      throw const CircleServiceException('Failed to build avatar clear event');
    }
  }

  @override
  Future<AvatarIngestResult> ingestIncomingAvatarMessage({
    required String eventJson,
  }) async {
    final manager = await _ensureInitialized();
    try {
      final result = await manager.ingestIncomingAvatarMessage(
        eventJson: eventJson,
      );
      return AvatarIngestResult(
        accepted: result.accepted,
        complete: result.complete,
        senderPubkeyHex: result.senderPubkeyHex,
      );
    } on Object catch (e) {
      debugPrint(
        '[Avatar] ingestIncomingAvatarMessage failed: ${e.runtimeType}',
      );
      throw const CircleServiceException('Failed to ingest avatar message');
    }
  }

  @override
  Future<Uint8List?> getMemberAvatarThumbnail({
    required List<int> mlsGroupId,
    required String pubkey,
  }) async {
    final manager = await _ensureInitialized();
    try {
      final bytes = await manager.getAvatarThumbnail(
        mlsGroupId: Uint8List.fromList(mlsGroupId),
        pubkey: pubkey,
      );
      if (bytes == null) return null;
      return Uint8List.fromList(bytes);
    } on Object catch (e) {
      debugPrint('[Avatar] getMemberAvatarThumbnail failed: ${e.runtimeType}');
      throw const CircleServiceException('Failed to load member avatar');
    }
  }

  @override
  Future<Uint8List?> getMemberAvatar({
    required List<int> mlsGroupId,
    required String pubkey,
  }) async {
    final manager = await _ensureInitialized();
    try {
      final bytes = await manager.getMemberAvatar(
        mlsGroupId: Uint8List.fromList(mlsGroupId),
        pubkey: pubkey,
      );
      if (bytes == null) return null;
      return Uint8List.fromList(bytes);
    } on Object catch (e) {
      debugPrint('[Avatar] getMemberAvatar failed: ${e.runtimeType}');
      throw const CircleServiceException('Failed to load member full avatar');
    }
  }
}
