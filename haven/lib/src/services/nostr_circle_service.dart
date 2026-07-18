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
///
/// # Publish-before-apply (Dark Matter, Rule 13)
///
/// Every group-evolving operation (`createCircle`, `addMember`,
/// `removeMember`, `updateCircleRelays`, and the admin-handoff/self-demote
/// steps inside `leaveCircle`) follows the same contract: the FFI stages the
/// commit and returns an opaque `PendingStateRefFfi` token; this service
/// publishes the commit event to the circle's relays and, ONLY once at least
/// one relay returns an OK-ack, confirms the token via
/// `CircleManagerFfi.confirmPublished` so the engine applies the commit and
/// advances the epoch. A publish failure instead rolls the token back via
/// `CircleManagerFfi.publishFailed`. "Acked" means a relay accepted the
/// event — never merely "sent" — to avoid optimistic-merge forks.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:haven/src/rust/api.dart';
import 'package:haven/src/rust/api.dart' as frb_api;
import 'package:haven/src/services/circle_service.dart';
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
    Future<List<int>> Function()? identitySecretBytesProvider,
  }) : _relayService = relayService,
       _dataDirectoryProvider =
           dataDirectoryProvider ?? const PathProviderDataDirectory(),
       _keyringInitializer = keyringInitializer ?? initKeyringStore,
       _enableLeaverBackstop = enableLeaverBackstop,
       _identitySecretBytesProvider = identitySecretBytesProvider;

  /// Creates a [NostrCircleService] backed by a pre-built [CircleManagerFfi].
  ///
  /// Used by the background isolate (`background_location_task.dart`) to
  /// share the already-constructed manager rather than constructing a
  /// second one over the same SQLCipher path. Holding two managers in one
  /// isolate would split MLS state across two in-memory engine sessions and
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
       _identitySecretBytesProvider = null,
       _manager = injectedManager,
       _initialized = true;

  final RelayService _relayService;
  final DataDirectoryProvider _dataDirectoryProvider;
  final KeyringInitializer _keyringInitializer;

  /// Supplies the device identity's 32-byte Nostr secret for
  /// [CircleManagerFfi.newInstance], which (Dark Matter) hard-requires the
  /// identity at construction time (it binds the account identity, the NIP-59
  /// welcome signer, AND the account-identity-proof signer). Re-fetched on
  /// every `initialize()` call rather than held (Security Rule 9).
  ///
  /// `null` for the background-isolate / injected-manager constructor, which
  /// never calls [initialize] (the manager is already open).
  final Future<List<int>> Function()? _identitySecretBytesProvider;

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

  /// Completes once [closeAndInvalidate] latches [_wiped]. Reserved as the
  /// no-resurrection fence for any future settle-wait style operation; no
  /// current code path awaits it (the Dark Matter engine owns convergence
  /// internally, so there is no Dart-side settle window left to race).
  final Completer<void> _teardownSignal = Completer<void>();

  /// Hex-encoded `mlsGroupId`s observed entering the MLS `Unrecoverable`
  /// state this session (Rule 8 blocked-circle UI state). See
  /// [markCircleBlocked] / [isCircleBlocked].
  final Set<String> _blockedCircleIds = {};

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
      // manager. The Dark Matter session uses the keyring to store the
      // SQLCipher encryption key.
      try {
        await _keyringInitializer();
      } on Object catch (e) {
        debugPrint('Keyring initialization failed: ${e.runtimeType}');
        throw const CircleServiceException(
          'Failed to initialize secure storage',
        );
      }
      final secretBytesProvider = _identitySecretBytesProvider;
      if (secretBytesProvider == null) {
        throw const CircleServiceException(
          'No identity available to open the circle manager',
        );
      }
      final dataDir = await _dataDirectoryProvider.getDataDirectory();
      // Re-fetched fresh (never held) — Security Rule 9.
      final identitySecretBytes = await secretBytesProvider();
      final manager = await CircleManagerFfi.newInstance(
        dataDir: dataDir,
        identitySecretBytes: identitySecretBytes,
      );
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
  /// SQLCipher DB would split MLS state across two in-memory engine
  /// sessions and risk SQLite contention; consumers MUST go through this
  /// getter.
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
      // requires to be non-empty (validated by the engine's welcome wrap).
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

      // Publish-before-apply (Rule 13): publish the gift-wrapped Welcomes,
      // then confirm (or roll back) the engine's pending group-creation
      // state based on whether at least one Welcome reached a relay. With
      // zero invited members there is nothing to ack, so confirm
      // unconditionally (a circle with only the creator is still valid).
      final total = result.welcomeEvents.length;
      final welcomeResults = await Future.wait(
        result.welcomeEvents.map(
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
                debugPrint('[Circle] Create: welcome send failed');
                return false;
              }),
        ),
      );
      final sentCount = welcomeResults.where((ok) => ok).length;
      final anySent = total == 0 || sentCount > 0;

      try {
        if (anySent) {
          await manager.confirmPublished(pending: result.pending);
        } else {
          await manager.publishFailed(pending: result.pending);
        }
      } on Object catch (e) {
        debugPrint(
          '[Circle] Create ${anySent ? "confirm" : "rollback"} failed: '
          '${e.runtimeType}',
        );
        throw const CircleServiceException('Failed to create circle');
      }
      if (!anySent) {
        throw const CircleServiceException('Failed to create circle');
      }

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

      return CircleCreationResult(
        circle: circle,
        welcomesSent: sentCount,
        welcomesTotal: total,
      );
    } on CircleServiceException {
      rethrow;
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
      // `mlsGroupId` here is the pre-join stand-in id — actually the
      // gift-wrap event id the invitation was keyed by (see
      // `InvitationFfi`/`processGiftWrappedInvitation`); the FFI accepts by
      // that same id.
      final ffiCircle = await manager.acceptInvitation(
        giftWrapId: Uint8List.fromList(mlsGroupId),
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
        giftWrapId: Uint8List.fromList(mlsGroupId),
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
        // GAP (Dark Matter plan §5.2 #18): the engine's public API exposes
        // no admin-policy component codec yet, so `propose_admin_handoff`
        // currently fails closed with a documented Rust-side error — admin
        // handoff via leave is not yet functional upstream. The `catch`
        // block below surfaces that as the same generic leave failure.
        final promote = await manager.proposeAdminHandoff(
          mlsGroupId: groupId,
          successorHex: successor,
        );
        stage = 'publish admin handoff commit';
        if (!await _publishAndConfirm(
          manager: manager,
          commitEventJson: promote.commitEventJson,
          pending: promote.pending,
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
        // Same GAP as above — the self-demote step of the fallback path
        // (adminDemote, multiple admins) shares the same upstream limit.
        final demote = await manager.proposeSelfDemote(mlsGroupId: groupId);
        stage = 'publish self-demote commit';
        if (!await _publishAndConfirm(
          manager: manager,
          commitEventJson: demote.commitEventJson,
          pending: demote.pending,
          relays: relays,
          label: 'self-demote',
        )) {
          debugPrint('[Leave] aborted: self-demote publish failed');
          throw const CircleServiceException('Failed to leave circle');
        }
      }

      // `propose_leave` returns a SelfRemove *proposal* (RFC 9420 §12.1.2)
      // — a remaining member commits it later, so the leaver does not
      // finalize a pending commit here (there is no `PendingStateRef` for a
      // bare proposal). We bump the publish attempts to
      // [_leaveMaxPublishAttempts] because this publish is terminal:
      // success is immediately followed by a forward-secrecy purge of
      // the leaver's engine state, and failure must keep local state intact
      // so the user can retry.
      stage = 'proposeLeave';
      final leaveEventJson = await manager.proposeLeave(mlsGroupId: groupId);
      stage = 'publish leave proposal';
      if (!await _publishEvolutionEvent(
        leaveEventJson,
        relays,
        label: 'leave',
        maxAttempts: _leaveMaxPublishAttempts,
      )) {
        debugPrint('[Leave] aborted: leave proposal publish failed');
        throw const CircleServiceException('Failed to leave circle');
      }

      // REV-1 leaver backstop (driver 2): a race-losing SelfRemove can be
      // deferred while every remaining member converges. Rather than wipe
      // immediately and risk a stale roster ghost, we poll our own removal
      // and re-issue a fresh SelfRemove until removed (bounded), then wipe.
      // A durable marker lets a crashed-then-returned leaver finish the
      // leave on the next launch. Disabled for the background isolate /
      // launch-time wipe-only service (neither of which authors leaves): the
      // leave wipes immediately, exactly as before.
      if (_enableLeaverBackstop) {
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

  /// Runs the REV-1 leaver backstop for a departing member.
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
      final leaveEventJson = await manager.proposeLeave(mlsGroupId: groupId);
      await _publishEvolutionEvent(
        leaveEventJson,
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
      final relays = await _circleRelays(groupId);
      if (relays == null || relays.isEmpty) {
        debugPrint('Circle relays unavailable — aborting remove');
        throw const CircleServiceException('Failed to remove member');
      }

      // The engine stages the Remove commit and returns the `kind:445`
      // evolution event + a pending token for the admin to publish+confirm.
      final result = await manager.removeMembers(
        mlsGroupId: groupId,
        memberPubkeys: [memberPubkeyHex],
      );

      if (!await _publishAndConfirm(
        manager: manager,
        commitEventJson: result.commitEventJson,
        pending: result.pending,
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

      // Torn down (logout / leave) after we captured `manager` above: do NOT
      // stage on the wiped handle — an MLS write could re-create state the M10
      // sweep removed.
      if (_wiped) {
        throw const CircleServiceException('Failed to add member');
      }

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
        rethrow;
      }

      // Publish-before-apply (Rule 13): publish the commit; only after ≥1
      // relay OK confirms the pending state, so a member is added ONLY once
      // the commit is durably confirmed. Welcomes are published ONLY after
      // that confirm succeeds — a welcome for a losing/unconfirmed commit
      // references an epoch that never applied.
      final published = await _publishEvolutionEvent(
        staged.commitEventJson,
        relays,
        label: 'add member',
      );

      if (!published) {
        try {
          await manager.publishFailed(pending: staged.pending);
        } on Object catch (e) {
          debugPrint('add member: publishFailed failed: ${e.runtimeType}');
        }
        throw const CircleServiceException('Failed to add member');
      }

      try {
        await manager.confirmPublished(pending: staged.pending);
      } on Object catch (e) {
        debugPrint('add member: confirmPublished failed: ${e.runtimeType}');
        throw const CircleServiceException('Failed to add member');
      }

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

      // Stage the relay-rotation commit via the FFI.
      final result = await manager.updateCircleRelays(
        mlsGroupId: groupId,
        newRelays: newRelays,
      );

      // Publish to the union set, then finalize (or roll back) locally.
      final published = await _publishEvolutionEvent(
        result.commitEventJson,
        publishRelays,
        label: 'update circle relays',
      );

      try {
        if (published) {
          // finalizeRelayUpdate confirms the pending state AND re-syncs the
          // admin's own circle.relays to newRelays, so the admin converges to
          // the new set immediately without waiting for the receive path.
          //
          // If this throws AFTER the engine already applied the commit
          // (epoch advanced), the admin's local circle.relays may transiently
          // LAG the applied state — never get ahead of it. That lag
          // self-heals idempotently: the next commit the admin processes runs
          // the decrypt_location re-sync hook, and a restart re-derives the
          // row from the engine. So the throw below is safe to surface.
          await manager.finalizeRelayUpdate(
            pending: result.pending,
            mlsGroupId: groupId,
          );
        } else {
          await manager.publishFailed(pending: result.pending);
        }
      } on Object catch (e) {
        debugPrint(
          'update circle relays: pending-commit '
          '${published ? "finalizeRelayUpdate" : "rollback"} '
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

  /// Publishes a staged commit's event; confirms the pending state on
  /// success or rolls it back on failure so the engine never applies a
  /// commit that no relay acknowledged. Returns `true` iff the event
  /// reached at least one relay and the confirm succeeded.
  Future<bool> _publishAndConfirm({
    required CircleManagerFfi manager,
    required String commitEventJson,
    required PendingStateRefFfi pending,
    required List<String> relays,
    required String label,
  }) async {
    final published = await _publishEvolutionEvent(
      commitEventJson,
      relays,
      label: label,
    );
    try {
      if (published) {
        await manager.confirmPublished(pending: pending);
      } else {
        await manager.publishFailed(pending: pending);
      }
    } on Object catch (e) {
      debugPrint(
        '$label: pending-commit ${published ? "confirm" : "rollback"} '
        'failed: ${e.runtimeType}',
      );
      return false;
    }
    return published;
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
  }) async {
    final manager = await _ensureInitialized();

    try {
      final result = await manager.encryptLocation(
        mlsGroupId: Uint8List.fromList(mlsGroupId),
        senderPubkeyHex: senderPubkeyHex,
        latitude: latitude,
        longitude: longitude,
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

  /// Converts one FFI folded engine result to the service-level type,
  /// recording a session-scoped blocked-circle marker on `Unrecoverable`
  /// (Rule 8).
  LocationEventResult _convertLocationEventResult(LocationMessageResultFfi r) {
    if (r.kind == LocationMessageResultKindFfi.unrecoverable) {
      markCircleBlocked(r.mlsGroupId.toList());
    }
    final loc = r.location;
    return LocationEventResult(
      kind: _convertLocationEventKind(r.kind),
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
            ),
      mlsGroupId: r.mlsGroupId.toList(),
      epoch: r.epoch.toInt(),
    );
  }

  LocationEventKind _convertLocationEventKind(
    LocationMessageResultKindFfi kind,
  ) {
    return switch (kind) {
      LocationMessageResultKindFfi.location => LocationEventKind.location,
      LocationMessageResultKindFfi.joined => LocationEventKind.joined,
      LocationMessageResultKindFfi.groupUpdate =>
        LocationEventKind.groupUpdate,
      LocationMessageResultKindFfi.invalidated =>
        LocationEventKind.invalidated,
      LocationMessageResultKindFfi.unrecoverable =>
        LocationEventKind.unrecoverable,
    };
  }

  @override
  Future<List<LocationEventResult>> decryptLocation({
    required String eventJson,
  }) async {
    final manager = await _ensureInitialized();

    try {
      final results = await manager.decryptLocation(eventJson: eventJson);
      return results.map(_convertLocationEventResult).toList();
    } on Object catch (_) {
      debugPrint('[Circle] Location decryption failed');
      throw const CircleServiceException('Failed to decrypt location');
    }
  }

  @override
  Future<DecryptLocationOutcome> decryptLocationCollectingCommits({
    required String eventJson,
  }) async {
    final manager = await _ensureInitialized();

    try {
      final outcome = await manager.decryptLocationCollectingCommits(
        eventJson: eventJson,
      );
      return DecryptLocationOutcome(
        results: outcome.results.map(_convertLocationEventResult).toList(),
        autoCommits: outcome.autoCommits
            .map(
              (c) => PendingAutoCommit(
                commitEventJson: c.commitEventJson,
                pendingToken: PendingCommitToken(c.pending.token),
              ),
            )
            .toList(),
      );
    } on Object catch (_) {
      debugPrint('[Circle] Location decryption failed');
      throw const CircleServiceException('Failed to decrypt location');
    }
  }

  @override
  Future<void> confirmPendingCommit(PendingCommitToken pending) async {
    final manager = await _ensureInitialized();
    try {
      await manager.confirmPublished(
        pending: PendingStateRefFfi(token: pending.value),
      );
    } on Object catch (e) {
      debugPrint('[Circle] auto-commit confirm failed: ${e.runtimeType}');
      throw const CircleServiceException('Failed to confirm auto-commit');
    }
  }

  @override
  Future<void> failPendingCommit(PendingCommitToken pending) async {
    final manager = await _ensureInitialized();
    try {
      await manager.publishFailed(
        pending: PendingStateRefFfi(token: pending.value),
      );
    } on Object catch (e) {
      // Best-effort (interface contract): the caller already knows the
      // publish did not succeed; this is cleanup, never a fresh failure to
      // surface. Rule 13's non-negotiable half is the publish attempt +
      // its outcome, already resolved by the caller — a rollback that
      // itself fails self-heals on the next ingest of the same buffered
      // proposal (a fresh jittered auto-commit attempt is scheduled).
      debugPrint('[Circle] auto-commit rollback failed: ${e.runtimeType}');
    }
  }

  /// Hex-encodes an `mlsGroupId` for use as a blocked-circle set key.
  static String _hexGroupId(List<int> mlsGroupId) {
    return mlsGroupId.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  @override
  void markCircleBlocked(List<int> mlsGroupId) {
    _blockedCircleIds.add(_hexGroupId(mlsGroupId));
  }

  @override
  bool isCircleBlocked(List<int> mlsGroupId) {
    return _blockedCircleIds.contains(_hexGroupId(mlsGroupId));
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

  // NOTE: `KeyPackage` signing/publishing/recording no longer live on this
  // service — see the `CircleService` doc comment. Use
  // `RelayService.maintainKeyPackage` (`key_package_provider.dart`).

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
    // Reserved teardown fence for any future settle-wait style operation —
    // completing it here keeps the invariant "torn down ⇒ signalled" even
    // though no current code path awaits it.
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
  Future<void> setContactDisplayName({
    required String pubkey,
    String? displayName,
  }) async {
    final manager = await _ensureInitialized();
    try {
      manager.setLocalNickname(pubkeyHex: pubkey, nickname: displayName);
    } on Object catch (e) {
      debugPrint('Failed to set local nickname: ${e.runtimeType}');
      throw const CircleServiceException('Failed to set nickname');
    }
  }
}
