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
/// A change the user makes — an invite, a removal, a relay change, the epoch
/// repair, and a leave with a leaving admin's two steps — goes through the
/// fanout driver ([CircleChangeDriver]): Rust stages the commit under a
/// durable record, sends it until a relay acknowledges it, and only then
/// applies it. "Acked" means a relay accepted the event — never merely
/// "sent" — to avoid optimistic-merge forks.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:haven/src/rust/api.dart';
import 'package:haven/src/rust/api.dart' as frb_api;
import 'package:haven/src/services/circle_change_driver.dart';
import 'package:haven/src/services/circle_service.dart';
import 'package:haven/src/services/fresh_secret.dart';
import 'package:haven/src/services/mls_session_handover.dart'
    show HandoverOutcome, appIsForegrounded, appIsResumed;
import 'package:haven/src/services/nostr_relay_service.dart';
import 'package:haven/src/services/publish_stagger.dart'
    show kMaxCirclesPerAccount;
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
    Future<List<int>> Function()? identitySecretBytesProvider,
    Future<HandoverOutcome> Function(String dataDir)? sessionHandover,
    Future<bool> Function(String dataDir)? isSessionLive,
    Future<ForceReleaseOutcomeFfi> Function()? forceReleaseLiveSession,
    bool Function()? isForegrounded,
    CircleChangeDriver? changeDriver,
    Future<void> Function()? settleForeground,
  }) : _relayService = relayService,
       _changeDriver =
           changeDriver ??
           (relayService is CircleChangeDriver
               ? relayService as CircleChangeDriver
               : null),
       _appInFront = appIsResumed,
       _settleForeground = settleForeground,
       _sessionHandover = sessionHandover,
       _isSessionLive = isSessionLive,
       _forceReleaseLiveSession = forceReleaseLiveSession,
       _isForegrounded = isForegrounded ?? appIsForegrounded,
       _dataDirectoryProvider =
           dataDirectoryProvider ?? const PathProviderDataDirectory(),
       _keyringInitializer = keyringInitializer ?? initKeyringStore,
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
    CircleChangeDriver? changeDriver,
    @visibleForTesting bool Function()? appInFront,
    @visibleForTesting Future<void> Function()? settleForeground,
  }) : _relayService = relayService,
       _changeDriver =
           changeDriver ??
           (relayService is CircleChangeDriver
               ? relayService as CircleChangeDriver
               : null),
       // A background isolate is never the app in front of its user: every
       // change it could ask for is refused by the engine, whatever the
       // binding of the isolate reads.
       _appInFront = appInFront ?? _neverInFront,
       _settleForeground = settleForeground,
       _dataDirectoryProvider = const PathProviderDataDirectory(),
       _keyringInitializer = initKeyringStore,
       _identitySecretBytesProvider = null,
       // The background isolate is usually the HOLDER of the guard, so a
       // handover would be asking the service to stop itself. It also never
       // opens a manager here — one is injected.
       _sessionHandover = null,
       // Same reason, and one more: force-releasing the process-global
       // live-sync session is the BACKGROUND isolate's destructive lever, gated
       // on a liveness probe it owns (`background_location_task.dart`). Wiring
       // it here would give that isolate a second, ungated route to the same
       // call.
       _isSessionLive = null,
       _forceReleaseLiveSession = null,
       // Never consulted: the pause-time handoff is a UI-isolate concern and
       // this constructor's service never calls `initialize()` (the manager is
       // already open, and `releaseForHandoff` is never called on it).
       _isForegrounded = appIsForegrounded,
       _manager = injectedManager,
       _initialized = true;

  final RelayService _relayService;

  /// The fanout driver every user change goes through.
  final CircleChangeDriver? _changeDriver;

  /// The `foreground` word handed to the driver: the app is resumed.
  final bool Function() _appInFront;

  static bool _neverInFront() => false;

  /// Lets the app's own live session settle its foreground claim.
  final Future<void> Function()? _settleForeground;

  /// The `foreground` word for a change the user asked for. The core grants a
  /// foreground drive only to a live plane already claimed for it, so a change
  /// asked while the session is still starting or re-claiming is refused as
  /// `foregroundOnly`; waiting for the claim first leaves the core's rule as
  /// it is. The word is read again afterwards: the wait can outlast the app
  /// being in front.
  Future<bool> _foreground() async {
    if (!_appInFront()) return false;
    try {
      await _settleForeground?.call();
    } on Object catch (_) {
      // The change is still asked; the core refuses it if it must.
    }
    return _appInFront();
  }

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

  /// Asks the foreground service to give the Rule-14 guard back, reporting how
  /// that went. Null disables recovery — correct for the background isolate
  /// (which is usually the HOLDER, so stopping the service would be asking it
  /// to stop itself) and for tests that inject a manager directly.
  final Future<HandoverOutcome> Function(String dataDir)? _sessionHandover;

  /// Reads the process-local Rule-14 registry. Injected rather than called
  /// through the FFI directly so [_forceReleaseOrphanedSession] is decidable in
  /// a unit test — and NEVER replaced by classifying an error string, which
  /// would hand a circle admin (who controls the group's routing relays, and so
  /// the text Haven interpolates into relay errors) a lever on this decision.
  final Future<bool> Function(String dataDir)? _isSessionLive;

  /// Drops the process-global live-sync session's manager `Arc`s. Null for
  /// every service that is not the UI isolate's own — see
  /// [_forceReleaseOrphanedSession] for why only that one may call it.
  final Future<ForceReleaseOutcomeFfi> Function()? _forceReleaseLiveSession;

  /// Whether the app is currently foregrounded. Consulted only while
  /// [_handedOff] holds — see [releaseForHandoff] for why the handoff must
  /// expire on the way back up rather than latching until logout.
  final bool Function() _isForegrounded;

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

  /// Roster-growing operations admitted by [_refuseIfRosterFull] whose circle
  /// row the core has not written yet, so a concurrent read cannot see them.
  int _reservedRosterSlots = 0;

  /// Set by [releaseForHandoff], cleared by [endSessionHandoff] (or by the
  /// first foregrounded open — see [_handoffHolds]). While it holds, every
  /// [initialize] fails closed so nothing in THIS isolate re-takes the Rule-14
  /// guard it just handed to the foreground service.
  ///
  /// Unlike [_wiped] this is not one-way: the session is expected back on
  /// resume.
  bool _handedOff = false;

  /// Whether a handed-off session must stay handed off right now.
  ///
  /// The `_handedOff` flag alone is deliberately NOT enough. It is set on the
  /// way down and cleared on the way back up, and if the clear were ever
  /// missed — a resume path that returned early, a `MapShell` disposed while
  /// paused — the app would come back to a database it refuses to open, with
  /// no circles, no map and no publishing, for the rest of the process. Pairing
  /// it with "and we are still backgrounded" bounds that to the window it is
  /// meant for: the moment the app is foregrounded again the refusal lapses on
  /// its own, and the ordinary [_sessionHandover] recovery takes the session
  /// back from the service.
  bool get _handoffHolds => _handedOff && !_isForegrounded();

  /// Message for the refusal above. Deliberately says nothing about the
  /// database, the path, or any group (Rule 8) — a caller only needs to know
  /// this isolate is not the session's owner right now.
  static const String _handoffRefusalMessage =
      'MLS session handed off to the background service';

  /// Ends the pause-time handoff so the next [initialize] may re-open.
  ///
  /// Returns whether a handoff was actually in effect. Called on resume, when
  /// this isolate becomes the natural owner of the session again; the open it
  /// re-enables may still have to take the guard back from the service, which
  /// is what [_sessionHandover] is for.
  bool endSessionHandoff() {
    if (!_handedOff) return false;
    _handedOff = false;
    return true;
  }

  /// Releases the MLS session so another isolate can take it, WITHOUT the
  /// permanent latch [closeAndInvalidate] applies.
  ///
  /// Returns whether a manager was actually released.
  ///
  /// # Why this is separate from closeAndInvalidate
  ///
  /// That one is logout: it sets `_wiped`, which makes every future
  /// [initialize] fail closed forever, because the database is about to be
  /// deleted. A pause-time handoff is the opposite — the session is expected
  /// back on resume — so it must leave the service re-openable.
  ///
  /// # Why release at all
  ///
  /// Rule 14 allows exactly one live session per database per process. While
  /// this isolate holds it, the Android foreground service cannot open one, so
  /// it cannot publish. Handing the session over at pause is what lets the
  /// service work, and unlike the service's reclaim it needs no inference
  /// about who is alive: this isolate is deciding about itself.
  ///
  /// # Why releasing alone is not handing over
  ///
  /// Releasing frees the guard for an instant; it does not keep it free. This
  /// isolate is NOT dead at pause — it is paused, with work still resolving.
  /// A publish chain suspended mid-`await`, the live-sync re-subscriber
  /// reacting to a circle-set change, a maintenance tick that outlives every
  /// `MapShell` timer: each of those calls [initialize] and, on a free guard,
  /// simply re-opens the database. The service's next 72-second tick then finds
  /// the guard held by a main isolate that is provably alive, its reclaim
  /// correctly declines (a reclaim is for a dead owner), and background
  /// publishing stays dead through the very handoff meant to enable it — which
  /// is exactly what the `e2e-fgs-publish` lane observed.
  ///
  /// So this latches [_handedOff] as well as releasing, and the latch is what
  /// makes the handoff hold. It expires on the way back up ([_handoffHolds]).
  ///
  /// # In-flight initialisation
  ///
  /// An `initialize()` suspended on its awaited open adopts its handle AFTER
  /// this returns, and cannot be cancelled from here. The latch is therefore
  /// set BEFORE the early return below, so that adoption fails closed and
  /// disposes the handle rather than silently re-taking the guard (see
  /// `_runInitialization`). The return value still reports only whether THIS
  /// call released a live handle.
  bool releaseForHandoff() {
    // Latch first, unconditionally: whether there was a handle to give away and
    // whether this isolate may take one back are different questions, and the
    // answer to the second is "not until we are foregrounded again" in every
    // case below.
    _handedOff = true;
    if (_initCompleter != null) {
      debugPrint('[CircleService] handoff: init in flight, adopt will refuse');
      return false;
    }
    final manager = _manager;
    if (manager == null) return false;
    _manager = null;
    _initialized = false;
    // Dispose rather than dropping: the handle holds this database's Rule-14
    // guard in Rust, and nulling alone defers the release to a GC that may
    // never run — the service would keep failing to open for the whole
    // background session.
    manager.dispose();
    return true;
  }

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
    // The session belongs to the foreground service until we are foregrounded
    // again — see [releaseForHandoff]. Fail closed rather than re-opening: one
    // straggler open here is all it takes to strand background publishing for
    // the whole backgrounded session.
    if (_handedOff) {
      if (_handoffHolds) {
        return Future.error(
          // log-scan-ok: _handoffRefusalMessage is the fixed literal above.
          const CircleServiceException(_handoffRefusalMessage),
        );
      }
      // Foregrounded again — the handoff is over even if no resume path got
      // around to saying so.
      _handedOff = false;
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
      // Re-fetched fresh AND scrubbed on the way out — Security Rule 9. Dart
      // has no `zeroize`, so `withFreshSecret`'s `finally` is what keeps the
      // raw nsec from being left for a GC that relocates rather than erases.
      Future<CircleManagerFfi> open() => withFreshSecret(
        secretBytesProvider,
        (secret) => CircleManagerFfi.newInstance(
          dataDir: dataDir,
          identitySecretBytes: secret,
        ),
      );

      CircleManagerFfi manager;
      try {
        manager = await open();
      } on Object {
        // The open can fail because another isolate in this process holds the
        // Rule-14 guard — in practice the Android foreground service, which can
        // win the race on a cold auto-restart before any Activity exists.
        // Retrying alone never helps: every retry hits the same held guard, and
        // nothing makes the service let go, so the user is left with no
        // circles, no map, no publishing and no receiving until they toggle
        // background sharing off or the process dies.
        //
        // ONE recovery attempt, then give up and report the original failure.
        if (!await _recoverHeldSession(dataDir)) rethrow;
        manager = await open();
      }
      // M10 (H1 in-flight race): the service may have been wiped/latched while
      // this init was suspended at the awaited open above. If so, do NOT adopt
      // the just-(re)created handle — a caller receiving it would operate on a
      // DB that logout is about to delete, and the on-disk file + keyring key
      // that newInstance() created are deleted by the wipeAllMlsState() that
      // deleteIdentity() runs AFTER closeAndInvalidate() drains this future.
      // Fail closed so no live manager escapes over a doomed DB.
      //
      // The same applies to a handoff latched while this init was suspended
      // (`releaseForHandoff` cannot cancel an open already in flight): adopting
      // here would re-take the guard microseconds after giving it away, and the
      // foreground service — which by then may already have failed its own
      // open — would stay locked out for the rest of the backgrounded session.
      if (_wiped || _handoffHolds) {
        // Release the handle we just opened rather than orphaning it: it holds
        // this DB's Rule-14 `LiveSessionGuard`, so dropping it on GC alone
        // would keep the process-global single-session slot occupied and make
        // the NEXT legitimate open fail closed (see `closeAndInvalidate`).
        manager.dispose();
        _manager = null;
        _initialized = false;
        _initCompleter = null;
        completer.completeError(
          // log-scan-ok: both branches are fixed literals, never live data.
          CircleServiceException(
            _wiped ? 'circle service was wiped' : _handoffRefusalMessage,
          ),
        );
        return;
      }
      // Adopting IS taking ownership back, so the handoff is over — clear it
      // rather than leaving a stale flag that a later pause would revive
      // against a manager this instance is already holding.
      _handedOff = false;
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

  /// Tries to free the Rule-14 guard that just blocked an open, returning
  /// whether a single retry is worth attempting.
  ///
  /// Two holders are possible and they need opposite treatment. The foreground
  /// service is asked to let go, politely, by [_sessionHandover]. But the guard
  /// can also be held by THIS isolate's own live-sync engine after a stop that
  /// timed out: Rust reinstalls that wedged core into the process-global
  /// `SESSION` so a retry has a handle to it, and if the pause path had already
  /// disposed this isolate's `CircleManagerFfi`, nothing in Dart references the
  /// guard any more. The service's reclaim cannot break that tie either — it
  /// probes the main isolate, finds it alive, and correctly declines forever.
  /// So the only actor that can fix it is this one, and it must recognise the
  /// case from the handover's own verdict rather than guess.
  Future<bool> _recoverHeldSession(String dataDir) async {
    final handover = _sessionHandover;
    if (handover == null) return false;
    final outcome = await handover(dataDir);
    debugPrint('[CircleService] open blocked; handover=${outcome.name}');
    if (outcome == HandoverOutcome.released) return true;
    // ONE eligible verdict, deliberately. `timedOut` is the only one that says
    // both halves of what the lever below needs: the guard WAS held (the
    // handover checked before it stopped anything) and the foreground service
    // stopping did not free it. Every other verdict fails one half —
    // `backgrounded` is the pause-time handoff working as designed and must
    // never reach a call that ends background sharing; `stopFailed` leaves the
    // service's own state unknown; `notHeld` says the guard was free, so the
    // re-read below would answer `false` in every realizable case and the only
    // way past it is a race that would aim the release at a holder this
    // isolate has not established anything about.
    if (outcome != HandoverOutcome.timedOut) return false;
    return _forceReleaseOrphanedSession(dataDir);
  }

  /// Drops the process-global live-sync session so this isolate can re-open the
  /// MLS database.
  ///
  /// # Why this is safe HERE and gated everywhere else
  ///
  /// `SESSION` is the UI isolate's own engine. Reaching this line means that
  /// isolate is foregrounded (the handover returns `backgrounded` otherwise),
  /// holds no manager (it is inside its own failing open), and has watched the
  /// foreground service be stopped without the guard clearing. Stopping an
  /// engine it can no longer feed costs it nothing it still had, and
  /// `LiveSyncResubscriber` starts a fresh one once the open succeeds. The
  /// background isolate makes the same call only behind a liveness probe
  /// precisely because THERE the engine belongs to someone else, and killing
  /// it would destroy live receive for a foreground that was working.
  ///
  /// Reads the registry again rather than trusting the handover's earlier
  /// answer: that answer is a snapshot from before the service was stopped and
  /// polled, and a lever this destructive is not spent on a stale one.
  Future<bool> _forceReleaseOrphanedSession(String dataDir) async {
    final readRegistry = _isSessionLive;
    final forceRelease = _forceReleaseLiveSession;
    if (readRegistry == null || forceRelease == null) return false;

    final bool held;
    try {
      held = await readRegistry(dataDir);
    } on Object catch (e) {
      // Cannot tell is not "free" — never open blind (Rule 14).
      debugPrint('[CircleService] guard query failed: ${e.runtimeType}');
      return false;
    }
    if (!held) return false;

    final ForceReleaseOutcomeFfi outcome;
    try {
      outcome = await forceRelease();
      debugPrint('[CircleService] orphaned live session released: '
          '${outcome.name}');
    } on Object catch (e) {
      debugPrint('[CircleService] force release failed: ${e.runtimeType}');
      return false;
    }
    // `drained` and `stopTimedOut` both changed something — neither PROMISES a
    // free guard (other holders are untouched, and `acquire` stays the
    // authority), so the retry is what asks. `noSession` is different in kind:
    // the slot was already empty, so this call positively released nothing and
    // the guard is held by something else entirely. Retrying on that is an open
    // guaranteed to fail the same way.
    return outcome != ForceReleaseOutcomeFfi.noSession;
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
  ///
  /// A roster row establishes provenance and nothing else: this pubkey was
  /// placed in the group by an MLS-authenticated commit, with its identity
  /// proof verified. It says nothing about whether that person's device ever
  /// processed the invitation — no such signal exists to carry here.
  /// Processing a Welcome emits nothing on the wire, MLS has no join
  /// acknowledgement, and the group state stores no per-peer join flag or
  /// liveness.
  CircleMember _convertMember(CircleMemberFfi ffiMember) {
    return CircleMember(
      pubkey: ffiMember.pubkey,
      npub: ffiMember.npub,
      displayName: ffiMember.displayName,
      isAdmin: ffiMember.isAdmin,
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
      engineState: switch (ffiCircle.engineState) {
        CircleEngineStateFfi.live => CircleEngineState.live,
        CircleEngineStateFfi.quarantined => CircleEngineState.quarantined,
        CircleEngineStateFfi.disbanded => CircleEngineState.disbanded,
        CircleEngineStateFfi.unrecoverable => CircleEngineState.unrecoverable,
      },
    );
  }

  /// Converts FFI invitation to service invitation.
  Invitation _convertInvitation(InvitationFfi ffiInvitation) {
    return Invitation(
      mlsGroupId: ffiInvitation.mlsGroupId.toList(),
      circleName: ffiInvitation.circleName,
      inviterPubkey: ffiInvitation.inviterPubkey,
      inviterNpub: ffiInvitation.inviterNpub,
      invitedAt: _timestampToDateTime(ffiInvitation.invitedAt),
    );
  }

  /// Refuses a roster-growing operation once the account holds
  /// [kMaxCirclesPerAccount] circles.
  ///
  /// Enforced HERE and not in the pages because this file holds the only two
  /// calls that grow the roster (`createCircle`, `acceptInvitation` — the same
  /// two the Rust core writes a circle row from), so a page-level check would
  /// be one every other caller of this service bypasses.
  ///
  /// Only ACCEPTED memberships count; see [kMaxCirclesPerAccount]. Fails
  /// CLOSED: a roster read that throws propagates, so an unreadable roster
  /// refuses growth rather than guessing at its size.
  ///
  /// On admission this RESERVES the slot, and the caller must release it in a
  /// `finally` ([_releaseRosterSlot]). The row only exists once the core write
  /// returns, so without the reservation every accept in flight reads the same
  /// pre-growth roster: two Accept buttons tapped together (each invitation
  /// card owns its own spinner, so both stay enabled) would each see nine and
  /// each proceed, and enough simultaneous taps would carry the roster past
  /// `kMaxCirclesPerBurst` — the deferral the bound exists to make unreachable.
  Future<void> _refuseIfRosterFull() async {
    final held = (await getVisibleCircles())
        .where((c) => c.membershipStatus == MembershipStatus.accepted)
        .length;
    if (held + _reservedRosterSlots >= kMaxCirclesPerAccount) {
      throw const CircleRosterFullException();
    }
    _reservedRosterSlots++;
  }

  /// Releases a slot [_refuseIfRosterFull] reserved, on success and on failure
  /// alike: a failed create writes no row, and a successful one is already in
  /// the roster the next read returns.
  void _releaseRosterSlot() => _reservedRosterSlots--;

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
    // Outside the try because the `finally` below releases the reservation the
    // gate takes: a refusal raised INSIDE would give back a slot it never took,
    // the count would drift negative, and the bound would loosen by one circle
    // per refusal (`a refusal does not loosen the next check` pins that).
    // Not for flattening — the `on CircleServiceException { rethrow; }` clause
    // below already preserves the refusal, which is a subtype of it.
    await _refuseIfRosterFull();

    try {
      // Validate identity secret bytes length
      if (identitySecretBytes.length != 32) {
        // Never the actual length (Security Rule 6: no key-material
        // exposure, and a wrong secret length is itself a fact about it).
        throw const CircleServiceException(
          'Invalid identity secret bytes length',
        );
      }

      // Convert KeyPackageData to MemberKeyPackageFfi
      final members = memberKeyPackages
          .map(
            (kp) => MemberKeyPackageFfi(
              keyPackageJson: kp.eventJson,
              inboxRelays: kp.relays,
              nip65Relays: kp.nip65Relays,
              nip65WriteRelays: kp.nip65WriteRelays,
              authorNpub: kp.pubkey,
            ),
          )
          .toList();

      final outcome = await _driver('Failed to create circle').createCircle(
        circle: manager,
        identitySecretBytes: identitySecretBytes,
        members: members,
        name: name,
        description: description,
        circleType: _circleTypeToString(circleType),
        // Empty lets Rust pick from Haven's location pool: the invitees'
        // inbox relays see their pubkeys, so Rust avoids them, drawing one
        // only when fewer than three others remain.
        relays: relays ?? const [],
        foreground: await _foreground(),
      );
      final created = outcome.circle;
      if (created == null) {
        // By variant only (Rule 8): nothing was created.
        debugPrint('[Circle] Create refused: ${outcome.refusal}');
        if (outcome.refusal == RefusalFfi.missingWelcomeRelays) {
          throw const CircleInviteesUnreachableException();
        }
        if (outcome.refusal == RefusalFfi.noLocationRelay) {
          throw const CircleNoLocationRelayException();
        }
        throw const CircleServiceException('Failed to create circle');
      }

      // Founded is canonical on return (MDK v0.10.4 `FoundingGroupCreated`).
      // Each founding Welcome has its own delivery record: one no relay took
      // during the call is sent again from it by later foreground drives.
      final circle = Circle(
        mlsGroupId: created.mlsGroupId.toList(),
        nostrGroupId: created.nostrGroupId.toList(),
        displayName: created.displayName,
        circleType: _parseCircleType(created.circleType),
        relays: created.relays,
        membershipStatus: MembershipStatus.accepted, // Creator is accepted
        members: const [], // Members added after invitations are sent
        createdAt: _timestampToDateTime(created.createdAt),
        updatedAt: _timestampToDateTime(created.updatedAt),
      );

      return CircleCreationResult(
        circle: circle,
        welcomesSent: outcome.welcomesSent,
        welcomesTotal: outcome.welcomesTotal,
        unsentNpubs: unsentNpubs(outcome.unsentRecipients, memberKeyPackages),
      );
    } on CircleServiceException {
      rethrow;
    } on Object catch (_) {
      debugPrint('[Circle] Create failed');
      throw const CircleServiceException('Failed to create circle');
    } finally {
      _releaseRosterSlot();
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
    // Before the ingest, so a refused accept leaves the held Welcome untouched
    // and the invitation is still there once the user makes room. Outside the
    // try for `createCircle`'s reservation reason and for one only this method
    // has: its catch is `on Object`, which WOULD flatten the refusal into the
    // generic "Failed to accept invitation".
    await _refuseIfRosterFull();

    try {
      // `mlsGroupId` here is the pre-join stand-in id — actually the
      // gift-wrap event id the invitation was keyed by (see
      // `InvitationFfi`/`processGiftWrappedInvitation`); the FFI accepts by
      // that same id.
      final outcome = await manager.acceptInvitation(
        giftWrapId: Uint8List.fromList(mlsGroupId),
      );
      final joined = outcome.joined;
      if (joined != null) return _convertCircleWithMembers(joined);
      _throwAcceptFailure(outcome.failure);
      throw const CircleServiceException('Failed to accept invitation');
    } on CircleServiceException {
      rethrow;
    } on Object catch (e) {
      debugPrint('Failed to accept invitation: ${e.runtimeType}');
      throw const CircleServiceException('Failed to accept invitation');
    } finally {
      _releaseRosterSlot();
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
  Future<List<RejoinOffer>> rejoinOffersForInvitation(
    List<int> invitationId,
  ) async {
    final manager = await _ensureInitialized();
    try {
      final outcome = await manager.rejoinOffersForInvitation(
        giftWrapId: Uint8List.fromList(invitationId),
      );
      _throwAcceptFailure(outcome.failure);
      return [
        for (final offer in outcome.offers)
          RejoinOffer(
            mlsGroupId: offer.mlsGroupId.toList(),
            circleName: await _heldCircleName(manager, offer.mlsGroupId),
            localStateToken: offer.localStateToken.toList(),
          ),
      ];
    } on CircleServiceException {
      rethrow;
    } on Object catch (e) {
      debugPrint('[Rejoin] offers read failed: ${e.runtimeType}');
      throw const CircleServiceException('Failed to read the rejoin offers');
    }
  }

  /// The display name of the circle an offer would replace: one this device
  /// holds, by the offer's definition.
  Future<String> _heldCircleName(
    CircleManagerFfi manager,
    Uint8List mlsGroupId,
  ) async {
    final held = await manager.getCircle(mlsGroupId: mlsGroupId);
    if (held == null) {
      throw const CircleServiceException('Failed to read the rejoin offers');
    }
    return held.circle.displayName;
  }

  @override
  Future<Circle> confirmGroupRejoin(
    List<int> invitationId,
    RejoinOffer offer,
  ) async {
    final manager = await _ensureInitialized();
    try {
      final outcome = await manager.confirmGroupRejoin(
        giftWrapId: Uint8List.fromList(invitationId),
        localStateToken: Uint8List.fromList(offer.localStateToken),
      );
      final joined = outcome.joined;
      if (joined != null) return _convertCircleWithMembers(joined);
      _throwAcceptFailure(outcome.failure);
      throw const CircleServiceException('Failed to accept invitation');
    } on CircleServiceException {
      rethrow;
    } on Object catch (e) {
      debugPrint('[Rejoin] confirm failed: ${e.runtimeType}');
      throw const CircleServiceException('Failed to accept invitation');
    }
  }

  @override
  Future<void> declineGroupRejoin(List<int> invitationId) async {
    final manager = await _ensureInitialized();
    try {
      await manager.declineGroupRejoin(
        giftWrapId: Uint8List.fromList(invitationId),
      );
    } on Object catch (e) {
      debugPrint('[Rejoin] decline failed: ${e.runtimeType}');
      throw const CircleServiceException('Failed to decline invitation');
    }
  }

  /// Throws the exception an accept [failure] names; nothing for `null`.
  static void _throwAcceptFailure(AcceptFailureFfi? failure) {
    switch (failure) {
      case AcceptFailureFfi.needsNewInvite:
        throw const InvitationNeedsNewInviteException();
      case AcceptFailureFfi.rejoinConfirmationRequired:
        throw const InvitationRejoinConfirmationRequiredException();
      case null:
        return;
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
        identitySecretBytes: identitySecretBytes,
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
  Future<LeaveDelivery> leaveCircle({required List<int> mlsGroupId}) async {
    final manager = await _ensureInitialized();
    try {
      // Torn down (logout) after `manager` was captured: no intent is written
      // on the wiped handle.
      if (_wiped) throw const CircleServiceException('Failed to leave circle');
      final outcome = await _driver('Failed to leave circle').leave(
        circle: manager,
        mlsGroupId: mlsGroupId,
        foreground: await _foreground(),
      );
      final delivery = leaveDeliveryOf(outcome.status);
      debugPrint('[Leave] ${outcome.status.name}');
      return delivery;
    } on CircleServiceException {
      rethrow;
    } on Object catch (e) {
      debugPrint('[Leave] failed: ${e.runtimeType}');
      throw const CircleServiceException('Failed to leave circle');
    }
  }

  @override
  Future<void> leaveDisbandedCircle({required List<int> mlsGroupId}) async {
    final manager = await _ensureInitialized();
    try {
      await manager.completeLeave(mlsGroupId: Uint8List.fromList(mlsGroupId));
    } on Object catch (e) {
      debugPrint('[Leave] disbanded circle: ${e.runtimeType}');
      throw const CircleServiceException('Failed to leave circle');
    }
  }

  @override
  Future<ChangeDelivery> removeMember({
    required List<int> mlsGroupId,
    required String memberPubkeyHex,
  }) async {
    final manager = await _ensureInitialized();
    try {
      return _delivered(
        await _driver('Failed to remove member').removeMembers(
          circle: manager,
          mlsGroupId: mlsGroupId,
          memberPubkeys: [memberPubkeyHex],
          foreground: await _foreground(),
        ),
      );
    } on CircleServiceException {
      rethrow;
    } on Object catch (e) {
      debugPrint('Failed to remove member: ${e.runtimeType}');
      throw const CircleServiceException('Failed to remove member');
    }
  }

  @override
  Future<AddMemberResult> addMember({
    required List<int> mlsGroupId,
    required List<KeyPackageData> memberKeyPackages,
  }) async {
    final manager = await _ensureInitialized();
    final ffiMembers = memberKeyPackages
        .map(
          (kp) => MemberKeyPackageFfi(
            keyPackageJson: kp.eventJson,
            inboxRelays: kp.relays,
            nip65Relays: kp.nip65Relays,
            nip65WriteRelays: kp.nip65WriteRelays,
            authorNpub: kp.pubkey,
          ),
        )
        .toList();
    try {
      // Torn down (logout / leave) after we captured `manager` above: do NOT
      // stage on the wiped handle — an MLS write could re-create state the
      // M10 sweep removed.
      if (_wiped) throw const CircleServiceException('Failed to add member');
      final outcome = await _driver('Failed to add member').addMembers(
        circle: manager,
        mlsGroupId: mlsGroupId,
        members: ffiMembers,
        foreground: await _foreground(),
      );
      if (outcome.refusal == RefusalFfi.missingWelcomeRelays) {
        throw const CircleInviteesUnreachableException();
      }
      return AddMemberResult(
        delivery: _delivered(outcome),
        welcomesDelivered: outcome.welcomesDelivered,
        welcomesTotal: outcome.welcomesTotal,
        reinviteOwed: outcome.reinviteOwed,
      );
    } on CircleServiceException {
      rethrow;
    } on Object catch (e) {
      debugPrint('Failed to add member: ${e.runtimeType}');
      throw const CircleServiceException('Failed to add member');
    }
  }

  /// The npubs of [unsentHexes], the invitees whose founding Welcome is
  /// still owed, in the order given. A Welcome names its recipient in hex;
  /// the key package each invitee was invited with is authored by that same
  /// key and carries the npub it was verified under, so the npub is read off
  /// it.
  @visibleForTesting
  static List<String> unsentNpubs(
    List<String> unsentHexes,
    List<KeyPackageData> invited,
  ) {
    final npubByHex = <String, String>{};
    for (final kp in invited) {
      try {
        final event = jsonDecode(kp.eventJson) as Map<String, dynamic>;
        final author = event['pubkey'];
        if (author is String) npubByHex[author] = kp.pubkey;
      } on Object catch (_) {
        // A package that does not parse here was refused before any Welcome
        // was built for it.
      }
    }
    return [
      for (final hex in unsentHexes)
        if (npubByHex[hex] case final npub?) npub,
    ];
  }

  @override
  Future<ChangeDelivery> updateCircleRelays({
    required List<int> mlsGroupId,
    required List<String> newRelays,
  }) async {
    final manager = await _ensureInitialized();
    try {
      // The driver sends the rotation to the union of the circle's current
      // relays and the new ones, so a member listening only on a relay being
      // removed still receives it.
      return _delivered(
        await _driver('Failed to update circle relays').updateCircleRelays(
          circle: manager,
          mlsGroupId: mlsGroupId,
          relays: newRelays,
          foreground: await _foreground(),
        ),
      );
    } on CircleServiceException {
      rethrow;
    } on Object catch (e) {
      debugPrint('Failed to update circle relays: ${e.runtimeType}');
      throw const CircleServiceException('Failed to update circle relays');
    }
  }

  @override
  Future<EpochRepairResult> repairCircleEpoch(
    Circle circle, {
    required String selfPubkeyHex,
  }) async {
    final manager = await _ensureInitialized();

    // FETCH FIRST, and let it settle.
    //
    // The core's exact race gate reads DURABLE storage: a departure proposal
    // this device has ingested declines the repair cleanly, while one still
    // sitting on a relay does not. Draining once here converts a same-epoch
    // race into a `pendingProposal` decline for free. The engine's ordering
    // makes the race survivable either way — see `circle::rotation`: priority
    // decides the tie only at the `fork_recovery` seam, so the rotation usually
    // wins rather than always, and whichever branch wins, one of them
    // converges. The cost is at most one extra epoch, never a fork — this is
    // the cheap half of the belt.
    //
    // Best-effort: a fetch that fails leaves the repair on the engine's
    // guarantee, which is strictly better than refusing to repair at all.
    //
    // `runCatchup` sweeps every visible circle rather than just this one; that
    // is more work than strictly needed and exactly the drain we want, and it
    // is the seam that already exists rather than a second fetch path.
    try {
      await _relayService.runCatchup(
        circle: manager,
        ownPubkeyHex: selfPubkeyHex,
      );
    } on Object catch (e) {
      debugPrint('[EpochRepair] pre-fetch failed: ${e.runtimeType}');
    }

    final RepairOutcomeFfi outcome;
    try {
      outcome = await _driver('Failed to repair the circle').repairRotation(
        circle: manager,
        mlsGroupId: circle.mlsGroupId,
        foreground: await _foreground(),
      );
    } on Object catch (e) {
      // Rule 8: the type only. Engine text can carry group ids and
      // remote-authored content.
      debugPrint('[EpochRepair] failed: ${e.runtimeType}');
      throw const CircleServiceException('Failed to repair the circle');
    }

    // By the outcome's kind, then by the field it names; a missing field is
    // unreachable by the FFI contract and is not read as a repair made.
    switch (outcome.kind) {
      case RepairKindFfi.skipped:
        final skipped = outcome.skipped;
        if (skipped == null) break;
        debugPrint('[EpochRepair] declined: $skipped');
        return EpochRepairSkipped(skipped);
      case RepairKindFfi.deferred_:
        return const EpochRepairDeferred();
      case RepairKindFfi.rotated:
        final rotated = outcome.rotated;
        if (rotated == null) break;
        switch (_delivered(rotated)) {
          case ChangeDelivery.applied:
            return const EpochRepairApplied();
          case ChangeDelivery.awaitingRelays:
            return const EpochRepairAwaitingRelays();
          case ChangeDelivery.rejected:
            break;
        }
      case RepairKindFfi.refused:
        // A routing collision holds the circle as a send gate does.
        if (outcome.refusal == RefusalFfi.routingCollision) {
          return const EpochRepairDeferred();
        }
    }
    debugPrint('[EpochRepair] not made');
    throw const CircleServiceException('Failed to repair the circle');
  }

  /// The fanout driver, or [failure] when this service has none.
  CircleChangeDriver _driver(String failure) {
    final driver = _changeDriver;
    if (driver == null) throw CircleServiceException(failure);
    return driver;
  }

  /// Converts results a drive outside this service handed back. The
  /// locations themselves are already stored.
  List<LocationEventResult> absorbReplayed(
    List<LocationMessageResultFfi> replayed,
  ) => replayed.map(locationEventResultFromFfi).toList();

  /// What became of a change, by variant only (Rule 8). The locations its
  /// resolution replayed are already stored.
  ChangeDelivery _delivered(EvolutionOutcomeFfi outcome) {
    // A refusal of any kind is not made — a routing collision included: the
    // core stages nothing and owes nothing, and only leaving this circle
    // itself ends its hold, with the change never made, so it is no wait.
    return changeDeliveryOf(outcome.status);
  }

  @override
  Future<LocationSeal> sealLocation({
    required List<int> mlsGroupId,
    required double latitude,
    required double longitude,
    bool meshOnly = false,
  }) async {
    final manager = await _ensureInitialized();
    try {
      final driver = _driver('Failed to seal location');
      final outcome = meshOnly
          ? await driver.sealLocationForMesh(
              circle: manager,
              mlsGroupId: mlsGroupId,
              latitude: latitude,
              longitude: longitude,
            )
          : await driver.sealLocation(
              circle: manager,
              mlsGroupId: mlsGroupId,
              latitude: latitude,
              longitude: longitude,
              foreground: _appInFront(),
            );
      if (outcome.errored) {
        debugPrint('[Circle] seal drive ended on an error');
      }
      final replayed = absorbReplayed(outcome.replayed);
      final sealed = outcome.sealed;
      if (sealed != null) return LocationSealed(sealed, replayed: replayed);
      return LocationSendHeld(replayed: replayed);
    } on CircleServiceException {
      rethrow;
    } on Object catch (e) {
      debugPrint('[Circle] location seal failed: ${e.runtimeType}');
      throw const CircleServiceException('Failed to seal location');
    }
  }

  @override
  Future<LocationPublishFfi> publishSealedLocation(
    LocationSealed seal, {
    required bool received,
  }) async {
    final manager = await _ensureInitialized();
    try {
      return await _driver('Failed to publish location').publishLocation(
        circle: manager,
        sealed: seal.sealed,
        received: received,
      );
    } on CircleServiceException {
      rethrow;
    } on Object catch (e) {
      debugPrint('[Circle] location publish failed: ${e.runtimeType}');
      throw const CircleServiceException('Failed to publish location');
    }
  }

  @override
  Future<IngestResult> ingestEvent({required String eventJson}) async {
    final manager = await _ensureInitialized();
    try {
      final outcome = await _driver('Failed to decrypt location').ingest(
        circle: manager,
        eventJson: eventJson,
        foreground: _appInFront(),
      );
      if (outcome.errored) {
        debugPrint('[Circle] ingest drive ended on an error');
      }
      return IngestResult(
        results: outcome.replayed.map(locationEventResultFromFfi).toList(),
        held: switch (outcome.verdict) {
          ReceiveVerdictFfi.deferred_ => true,
          ReceiveVerdictFfi.applied ||
          ReceiveVerdictFfi.noEvidence ||
          ReceiveVerdictFfi.stranded => false,
        },
      );
    } on CircleServiceException {
      rethrow;
    } on Object catch (_) {
      debugPrint('[Circle] Location decryption failed');
      throw const CircleServiceException('Failed to decrypt location');
    }
  }

  // REMOVED: both of Dart's sync-cursor advances (group and inbox) — see
  // `CircleService`. Both cursors are written in Rust only, anchored on a local
  // clock reading taken when an observation window opened, never on an inbound
  // event's or gift wrap's timestamp.

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
        identitySecretBytes: identitySecretBytes,
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
              receivedAt: _timestampToDateTime(row.updatedAt),
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
    // Release the RustOpaque Arc DETERMINISTICALLY. Nulling the field alone
    // only makes the handle GC-eligible, and the Rust `Drop` that actually
    // closes the SQLite fds ALSO releases this DB's Rule-14 `LiveSessionGuard`
    // — so a GC-timed drop leaves the process-global single-session slot
    // occupied for an unbounded period. Anything reopening the same
    // `session.sqlite` before that GC lands (a logout→login inside one process,
    // or a second `HavenApp` pumped in the same test process) fails closed with
    // "an MLS session is already open on this database". `dispose()` decrements
    // the Arc exactly once and is idempotent, so the finalizer stays correct.
    //
    // In-flight Rust work is unaffected: `run_blocking` closures clone the
    // `Arc<CircleManager>` for their duration, so this can never free state a
    // running FFI call is using — it only drops OUR reference. The guard is
    // released once the last clone goes, which is why logout stops the
    // live-sync engine (it holds its own clone) BEFORE calling this.
    //
    // Forgotten whether or not the release returns: a handle left in the
    // field by a release that threw would be handed to the next caller,
    // disposed, in place of the latch's refusal.
    try {
      _manager?.dispose();
    } finally {
      _manager = null;
      _initialized = false;
      _initCompleter = null;
    }
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
  Future<void> acknowledgeStorageReset() async {
    try {
      final dataDir = await _dataDirectoryProvider.getDataDirectory();
      frb_api.acknowledgeStorageReset(dataDir: dataDir);
    } on Object catch (e) {
      debugPrint('[Circle] storage-reset acknowledge failed: ${e.runtimeType}');
      throw const CircleServiceException('Failed to acknowledge the reset');
    }
  }

  @override
  Future<KeyPackageAdmission> checkMemberKeyPackage({
    required String keyPackageJson,
    List<int>? mlsGroupId,
  }) async {
    final manager = await _ensureInitialized();
    try {
      final admission = await manager.checkMemberKeyPackage(
        keyPackageJson: keyPackageJson,
        mlsGroupId: mlsGroupId == null ? null : Uint8List.fromList(mlsGroupId),
      );
      return switch (admission) {
        KeyPackageAdmissionFfi.admissible => KeyPackageAdmission.admissible,
        KeyPackageAdmissionFfi.needsUpdate => KeyPackageAdmission.needsUpdate,
        KeyPackageAdmissionFfi.unusable => KeyPackageAdmission.unusable,
      };
    } on Object catch (e) {
      debugPrint('[Circle] key package check failed: ${e.runtimeType}');
      throw const CircleServiceException('Failed to check the key package');
    }
  }

  @override
  Future<bool> retryQuarantinedCircle(List<int> mlsGroupId) async {
    final manager = await _ensureInitialized();
    try {
      return await manager.retryQuarantinedCircle(
        mlsGroupId: Uint8List.fromList(mlsGroupId),
      );
    } on Object catch (e) {
      debugPrint('[Circle] quarantine retry failed: ${e.runtimeType}');
      throw const CircleServiceException('Failed to retry the circle');
    }
  }

  @override
  Future<CircleRecoveryCause?> circleRecovery(Circle circle) async {
    final manager = await _ensureInitialized();
    try {
      final cause = await _driver('Failed to read the circle').circleRecovery(
        circle: manager,
        mlsGroupId: circle.mlsGroupId,
        foreground: _appInFront(),
      );
      return cause == null ? null : circleRecoveryCauseOf(cause);
    } on Object catch (e) {
      debugPrint('[Recovery] read failed: ${e.runtimeType}');
      throw const CircleServiceException('Failed to read the circle');
    }
  }

  @override
  Future<List<String>> unmadeRemovalMembers(List<int> mlsGroupId) async {
    final manager = await _ensureInitialized();
    try {
      return manager.unmadeRemovalMembers(mlsGroupId: mlsGroupId);
    } on Object catch (e) {
      debugPrint('[Recovery] removal read failed: ${e.runtimeType}');
      throw const CircleServiceException('Failed to read the circle');
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

  DirectoryEntry _convertDirectoryEntry(DirectoryEntryFfi ffi) {
    return DirectoryEntry(
      pubkeyHex: ffi.pubkeyHex,
      npub: ffi.npub,
      tier: switch (ffi.tier) {
        DirectoryTierFfi.current => DirectoryTier.current,
        DirectoryTierFfi.recent => DirectoryTier.recent,
      },
    );
  }

  @override
  Future<List<DirectoryEntry>> rankedDirectoryMembers({DateTime? now}) async {
    final manager = await _ensureInitialized();
    final nowSecs = (now ?? DateTime.now()).millisecondsSinceEpoch ~/ 1000;
    try {
      final rows = await manager.rankedDirectoryMembers(nowUnixSecs: nowSecs);
      return rows.map(_convertDirectoryEntry).toList();
    } on Object catch (e) {
      debugPrint('Failed to read member directory: ${e.runtimeType}');
      throw const CircleServiceException('Failed to read member directory');
    }
  }

  @override
  Future<bool> reconcileMemberDirectory({DateTime? now}) async {
    final manager = await _ensureInitialized();
    final nowSecs = (now ?? DateTime.now()).millisecondsSinceEpoch ~/ 1000;
    try {
      return await manager.reconcileMemberDirectory(nowUnixSecs: nowSecs);
    } on Object catch (e) {
      debugPrint('Failed to reconcile member directory: ${e.runtimeType}');
      throw const CircleServiceException(
        'Failed to reconcile member directory',
      );
    }
  }

  @override
  Future<Map<String, String>> allContactDisplayNames() async {
    final manager = await _ensureInitialized();
    try {
      final contacts = await manager.getAllContacts();
      return {
        for (final contact in contacts)
          if (contact.displayName != null) contact.pubkey: contact.displayName!,
      };
    } on Object catch (e) {
      debugPrint('Failed to read local nicknames: ${e.runtimeType}');
      throw const CircleServiceException('Failed to read nicknames');
    }
  }

  // ==================== Contact Management ====================

  @override
  Future<String?> getContactDisplayName({required String pubkey}) async {
    final manager = await _ensureInitialized();
    try {
      final contact = await manager.getContact(pubkey: pubkey);
      return contact?.displayName;
    } on Object catch (e) {
      debugPrint('Failed to read local nickname: ${e.runtimeType}');
      throw const CircleServiceException('Failed to read nickname');
    }
  }

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

/// One FFI folded engine result as the service-level type.
///
/// Top-level for the reason [peerLocationFromFfi] is: a drive made outside
/// [NostrCircleService] — the Bluetooth mesh's — converts what it is handed
/// through this, never a second copy of it.
LocationEventResult locationEventResultFromFfi(LocationMessageResultFfi r) {
  return LocationEventResult(
    kind: switch (r.kind) {
      LocationMessageResultKindFfi.location => LocationEventKind.location,
      LocationMessageResultKindFfi.joined => LocationEventKind.joined,
      LocationMessageResultKindFfi.groupUpdate => LocationEventKind.groupUpdate,
      LocationMessageResultKindFfi.invalidated => LocationEventKind.invalidated,
      LocationMessageResultKindFfi.unrecoverable =>
        LocationEventKind.unrecoverable,
    },
    location: peerLocationFromFfi(r),
    mlsGroupId: r.mlsGroupId.toList(),
    epoch: r.epoch.toInt(),
  );
}

/// The peer location one FFI folded result carries, or `null` when it is not a
/// parsed location (a group-state result, or a decrypted-but-unparseable
/// inner).
///
/// Top-level so the Android foreground-service isolate — which routes an FFI
/// outcome without a [CircleService] in hand — converts a replayed fix through
/// exactly this arithmetic rather than a second copy of it.
DecryptedLocation? peerLocationFromFfi(LocationMessageResultFfi r) {
  final loc = r.location;
  if (loc == null) return null;
  return DecryptedLocation(
    senderPubkey: loc.senderPubkey,
    latitude: loc.latitude,
    longitude: loc.longitude,
    geohash: loc.geohash,
    timestamp: DateTime.fromMillisecondsSinceEpoch(loc.timestamp * 1000),
    expiresAt: DateTime.fromMillisecondsSinceEpoch(loc.expiresAt * 1000),
  );
}
