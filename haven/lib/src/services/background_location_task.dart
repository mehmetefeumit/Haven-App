/// Background location sharing task handler.
///
/// Runs in a separate Dart isolate (Android foreground service) and
/// publishes the user's encrypted location to all accepted circles. Uses the
/// same Rust FFI pipeline as the foreground publisher but with its own service
/// instances to avoid cross-isolate state sharing.
///
/// ## Cadence: one platform request, aimed
///
/// The isolate holds exactly ONE `LocationManager` registration and publishes
/// on its deliveries. Its interval is the time to the earliest per-circle
/// due-time minus [kBackgroundFixLeadTime], floored at
/// [kMinFixRequestInterval] — so the platform hibernates the GNSS engine
/// between fixes (`docs/POWER_EFFICIENCY_PLAN.md` §2.2) instead of navigating
/// continuously, and a publish costs about one acquisition rather than a
/// permanent receiver plus a 30 s HIGH_ACCURACY one-shot per wake.
///
/// Three inputs, one behaviour: a delivery, a foreground-handoff signal
/// ([kForegroundPausedSignal] / [kForegroundResumedSignal]) and the plugin's
/// [kBackgroundRepeatInterval] repeat all reach `_publishCycle` and nothing
/// else. That is what keeps every registration below the consent, ownership
/// and disclosure gates — `_ensureRegistration` is reachable from the cycle
/// alone.
/// The repeat is a WATCHDOG, not the cadence: it acts only when no delivery
/// can arrive (nothing registered, the registration went silent past
/// [kStreamPositionMaxAge], or it errored), which indoors on a GNSS-only
/// device is the only thing that publishes at all — the platform's own retry
/// alarms produce no app callback. That is why the plugin's permanent wake
/// lock is kept for now; [PublishWakeLock] is Haven's own, bounded hold over
/// fix→encrypt→publish→ack→fetch.
///
/// States, from three fields rather than an enum that could disagree with
/// them: **Idle** (`_fixSub == null`, the foreground owns publishing or the
/// request was dropped), **Armed** (`_registeredTarget` names what the live
/// request aims at) and **Cycling** (`_inFlightPublish != null`). A delivery
/// during a cycle sets `_deliveryPending` and is served by one follow-up
/// cycle; a watchdog tick during one is a no-op.
///
/// ## MLS safety
///
/// Only one isolate publishes at a time (single-owner model). The
/// foreground cancels its publish timer before starting this service,
/// and stops this service before restarting its own timer on resume.
/// The existing [kLocationPublishOverlapGuard] absorbs any transition
/// window.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:haven/src/constants/location.dart';
import 'package:haven/src/providers/location_publish_scheduler_provider.dart'
    show filterPublishEligibleCircles;
import 'package:haven/src/rust/api.dart';
import 'package:haven/src/rust/frb_generated.dart';
import 'package:haven/src/services/background_deferred_send.dart';
import 'package:haven/src/services/background_fix_request.dart';
import 'package:haven/src/services/background_identity_service.dart';
import 'package:haven/src/services/background_location_manager.dart';
import 'package:haven/src/services/circle_health_service.dart';
import 'package:haven/src/services/circle_service.dart' show Circle;
import 'package:haven/src/services/foreground_liveness_probe.dart';
import 'package:haven/src/services/fresh_secret.dart';
import 'package:haven/src/services/geolocator_location_service.dart';
import 'package:haven/src/services/location_service.dart' show Position;
import 'package:haven/src/services/location_sharing_service.dart';
import 'package:haven/src/services/mls_session_handover.dart'
    show kBackgroundTeardownDrainBudget;
import 'package:haven/src/services/nostr_circle_service.dart';
import 'package:haven/src/services/nostr_relay_service.dart';
import 'package:haven/src/services/pending_mls_wipe_service.dart';
import 'package:haven/src/services/per_circle_due_tracker.dart';
import 'package:haven/src/services/publish_stagger.dart';
import 'package:haven/src/services/publish_wake_lock.dart';
import 'package:haven/src/utils/log_alias.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Top-level callback required by [FlutterForegroundTask].
///
/// Must be annotated with `@pragma('vm:entry-point')` so the Dart
/// compiler does not tree-shake it. Registered in `main.dart`.
@pragma('vm:entry-point')
void backgroundCallback() {
  // A7: silence debugPrint in release builds. This isolate has its OWN
  // `FlutterEngine` and never runs `main()`, so `main.dart`'s silencer does not
  // reach it — `background_catchup_worker.dart`'s `callbackDispatcher` already
  // replicates it for exactly this reason. Without it, every `[BackgroundTask]`
  // line reaches release logcat, and those lines are not innocuous: the
  // publish summary carries the user's circle COUNT and a per-cycle timing
  // oracle, which together reconstruct a Haven activity timeline for anyone
  // with `adb logcat`, a bug-report capture, or an OEM/MDM log collector.
  //
  // Safe for CI: the E2E oracles grep these markers, but every lane drives a
  // debug APK — the same combination `e2e-background-catchup` relies on today.
  if (kReleaseMode) {
    debugPrint = (String? message, {int? wrapWidth}) {};
  }
  // This isolate never runs `main()`, so its `FlutterError.onError` /
  // `PlatformDispatcher.instance.onError` redaction is replicated here too —
  // Flutter's defaults print an exception's raw `toString()` + stack.
  FlutterError.onError = (details) => debugPrint(
    '[FlutterError] ${details.exception.runtimeType} in ${details.library}',
  );
  PlatformDispatcher.instance.onError = (error, stack) {
    debugPrint('[UncaughtAsync] ${error.runtimeType}');
    return true;
  };
  FlutterForegroundTask.setTaskHandler(BackgroundLocationTaskHandler());
}

/// Whether the background isolate may publish location this cycle, given the
/// two raw disclosure flags as `SharedPreferences` returns them.
///
/// Both must be explicitly `true`. Google Play's "disclosure before collection"
/// rule requires an affirmative in-app disclosure before location is collected,
/// and the background variant is the one carrying the "even when the app is
/// closed or not in use" sentence — precisely what this isolate does.
///
/// **A missing flag is a refusal, not a default.** `getBool` returns `null` for
/// a key that was never written (a fresh install, a wiped profile, a key
/// renamed by a future migration). Treating `null` as permission would let
/// exactly those cases publish location with no disclosure ever shown, so the
/// null-coalescing here is the security property, not a formality — which is
/// why it is a named, tested predicate rather than an inline `??` pair.
///
/// Extracted as a free function so the truth table is unit-testable without the
/// Rust bridge, `SharedPreferences`, or a device.
@visibleForTesting
bool backgroundPublishDisclosureAccepted({
  required bool? foregroundAccepted,
  required bool? backgroundAccepted,
}) => (foregroundAccepted ?? false) && (backgroundAccepted ?? false);

/// Handles periodic location publishing in the background.
///
/// Lifecycle:
/// 1. [onStart] — initializes Rust FFI, services, and identity
/// 2. [onRepeatEvent] — the ~72 s watchdog; acts only when no fix can arrive
/// 3. [onDestroy] — tears down relay connections
/// Why a session reclaim was or was not authorised.
///
/// Split out of [BackgroundLocationTaskHandler] so the gate logic is reachable
/// from a unit test. It used to live inline, where the only thing testing it was
/// a source-text scan — that could prove a gate's *token* appeared before the
/// destructive call, but not that its branch actually declined, and it could not
/// see the comparison operator in the rate limit at all.
enum SessionReclaimDecision {
  /// Every precondition holds; the caller may run the liveness probe and, if
  /// that reports the main isolate gone, reclaim.
  proceed,

  /// No data directory resolved — nothing to open.
  noDataDir,

  /// No identity loaded, so there is no session to open even if the guard were
  /// free.
  noIdentity,

  /// An MLS wipe is owed. Re-opening the database would recreate state that is
  /// supposed to be destroyed, so this outranks every other consideration.
  wipePending,

  /// The Rule-14 guard is not held, so the open failed for some other reason (a
  /// locked keyring, a full disk) that a reclaim cannot fix.
  guardNotHeld,

  /// A reclaim was attempted too recently.
  backoffActive,
}

/// Evaluates the gates that do not require I/O.
///
/// Pure by construction: every input is a value the caller has already
/// gathered, so the decision can be exercised exhaustively without a Rust
/// bridge, a foreground service, or a second isolate.
///
/// The liveness probe is deliberately NOT folded in — it is the one gate that
/// must run last and costs a cross-isolate round trip, so the caller applies it
/// only after this returns [SessionReclaimDecision.proceed].
@visibleForTesting
SessionReclaimDecision evaluateSessionReclaimGates({
  required bool hasDataDir,
  required bool hasIdentity,
  required bool wipePending,
  required bool guardHeld,
  required int? lastAttemptMs,
  required int nowMs,
  required Duration backoff,
}) {
  if (!hasDataDir) return SessionReclaimDecision.noDataDir;
  if (!hasIdentity) return SessionReclaimDecision.noIdentity;
  if (wipePending) return SessionReclaimDecision.wipePending;
  if (!guardHeld) return SessionReclaimDecision.guardNotHeld;
  if (lastAttemptMs != null) {
    final elapsed = nowMs - lastAttemptMs;
    // A NEGATIVE elapsed means the wall clock moved backwards (a manual change
    // or a large NTP correction). Treating that as "no time has passed" would
    // latch the limit until the clock caught up — potentially forever, which
    // would disable recovery entirely. A stamp in the future is not evidence of
    // a recent attempt, so let it through; the caller rewrites the stamp.
    if (elapsed >= 0 && elapsed < backoff.inMilliseconds) {
      return SessionReclaimDecision.backoffActive;
    }
  }
  return SessionReclaimDecision.proceed;
}

class BackgroundLocationTaskHandler extends TaskHandler {
  /// [stagger] is injected only by tests, where a CSPRNG gap would turn every
  /// multi-circle cycle into seconds of sleep; production takes the default,
  /// and `publish_decorrelation_wiring_test.dart` pins that `lib/` never
  /// builds the zero-gap sampler.
  BackgroundLocationTaskHandler({PublishStagger? stagger})
    : _stagger = stagger ?? PublishStagger();

  CircleManagerFfi? _circleManager;
  NostrIdentityManager? _identityManager;
  NostrRelayService? _relayService;
  GeolocatorLocationService? _locationService;
  LocationEventService? _locationEventService;
  NostrCircleService? _circleService;
  LocationSharingService? _locationSharingService;
  String? _pubkeyHex;

  /// Data directory resolved in [onStart], retained so a session reclaim can
  /// re-open the manager without re-resolving it.
  String? _dataDir;

  /// Liveness probe against the main isolate. Consulted before any reclaim.
  final ForegroundLivenessProbe _livenessProbe = ForegroundLivenessProbe();

  /// In-flight publish future, tracked so `onDestroy` can await it
  /// rather than nulling services mid-cycle.
  Future<void>? _inFlightPublish;

  /// The commit-critical slice of [_inFlightPublish], if one is running.
  ///
  /// [_inFlightPublish] is the WHOLE cycle, and `onDestroy` abandons that after
  /// [kBackgroundTeardownDrainBudget] so a stopping service is bounded. Most of
  /// the cycle can be abandoned freely — a location is an MLS application
  /// message, so a dropped one costs a sample. `fetchMemberLocations` cannot:
  /// it may publish a receiver-side auto-commit and then confirm it, and a
  /// teardown landing between those two steps leaves a commit neither confirmed
  /// nor rolled back while possibly already on a relay (Rule 13, and the
  /// `PendingPublish` wedge that follows from breaking it).
  ///
  /// So the commit-critical window gets its own future, which `onDestroy`
  /// drains UNBOUNDED. Null whenever no such window is open, which is the
  /// overwhelming majority of every cycle.
  Future<void>? _inFlightCommitCritical;

  /// Publish-due bookkeeping for the burst (battery: one wake per interval).
  /// Every eligible circle is registered on the SAME due-time when the
  /// background first owns publishing and re-armed on the burst's ONE jittered
  /// sample, so a cycle serves the whole roster instead of paying a radio wake
  /// per circle. Cleared whenever the foreground owns publishing, so the seed
  /// re-runs on every foreground→background handoff.
  final PerCircleDueTracker _dueTracker = PerCircleDueTracker();

  /// CSPRNG gaps and burst order that keep two circles' kind-445 events out of
  /// the same wall-clock second (the engine stamps the outer `created_at` from
  /// the inner event's whole-second clock — see [PublishStagger]). This is the
  /// whole of the cross-circle timing defence now that the SCHEDULE is shared.
  ///
  /// The isolate builds its own rather than reading a provider: there is no
  /// Riverpod container here. Both planes share the same bounds via the
  /// constants in `publish_stagger.dart`.
  final PublishStagger _stagger;

  /// Completed the moment [onDestroy] begins, so a decorrelation wait inside
  /// [_publishCycle] aborts instead of holding teardown open.
  ///
  /// `onDestroy` awaits [_inFlightPublish] before tearing anything down, and
  /// Android gives a stopping foreground service a short window — a plain
  /// `Future.delayed` between circles would spend that window sleeping. This
  /// makes every such wait cancellable, so the cost of the stagger at teardown
  /// is one in-flight publish, not the whole remaining spread.
  final Completer<void> _shutdownSignal = Completer<void>();

  bool get _shuttingDown => _shutdownSignal.isCompleted;

  /// The isolate's single platform location registration, or `null` (Idle).
  ///
  /// Cancelled, never closed: cancelling releases the plugin registration
  /// while leaving the service's cached fix intact, so a handoff back does not
  /// throw away a coordinate that is still fresh. Closing would read as an
  /// access loss and drop it.
  ///
  /// Released by [_cancelRegistration] — from `onDestroy`, from every re-aim,
  /// and from EVERY exit of `_publishCycle` above the registration, because a
  /// cycle that cannot publish would otherwise keep the receiver duty-cycling
  /// until the next one reached the same gate (check (5b) of
  /// `check_android_location_power.sh`). None of those is recognised by the
  /// `cancel_subscriptions` lint, which only looks for a `dispose()`.
  // ignore: cancel_subscriptions
  StreamSubscription<Position>? _fixSub;

  /// What the live registration aims at: the instant the next fix is wanted
  /// (the earliest due-time minus [kBackgroundFixLeadTime]).
  DateTime? _registeredTarget;

  /// Fix time of the last delivery this isolate acted on.
  ///
  /// Every re-registration is answered on S+ with the fix just consumed
  /// (historical delivery, `LocationProviderManager:868-898`). Without this
  /// the replay would drive another cycle, which would re-register, which
  /// would replay: the dedupe is one half of the loop breaker,
  /// [registrationIsAligned] is the other.
  DateTime? _lastConsumedFixTs;

  /// When the last NEW fix arrived, so the watchdog can tell a silent
  /// registration from a delivering one. A replay is not a delivery.
  DateTime? _lastDeliveryAt;

  /// A fix arrived while a cycle was running, and no cycle has consumed it.
  ///
  /// Set only from [_onFixDelivered] and consumed only in
  /// [_runCycleWithIdleTracking], so it cannot leak: the cycle it interrupts
  /// serves it with one follow-up, and the watchdog is the backstop for a
  /// delivery that lands during THAT.
  bool _deliveryPending = false;

  /// When the live registration was armed.
  ///
  /// A registration that has not yet had time to deliver is not a dead one:
  /// its interval alone can be [kLocationPublishMaxInterval] minus the lead,
  /// so silence is measured from the later of this and [_lastDeliveryAt].
  DateTime? _registeredAt;

  /// The live registration is not known to be working — it reported an error,
  /// or it has produced nothing for longer than a fix may take. Either way it
  /// is re-issued rather than waited on; cleared by the registration that
  /// replaces it.
  ///
  /// Recovery for V-P2-2: the plugin binds its Android service asynchronously
  /// and `onListen` returns silently until it is bound, so a registration can
  /// be live, aligned and delivering nothing at all.
  bool _registrationSuspect = false;

  /// Completed by the first delivery while a cycle is waiting for one.
  Completer<void>? _firstDeliveryWaiter;

  /// The scoped `Haven:publish` hold. Stateless client over a method channel
  /// that exists only inside the foreground-service engine.
  final PublishWakeLock _wakeLock = const PublishWakeLock();

  /// Last time the background ran the all-circles peer-location fetch.
  /// Throttles the fetch to ~`kLocationUpdateInterval` so a cycle that
  /// publishes (or a deferred circle that makes one fire early) does not
  /// multiply background relay round-trips (battery parity, `_publishCycle`).
  DateTime? _lastBackgroundFetchAt;

  /// Number of completed publish cycles since the last prune. The bg
  /// isolate calls `pruneExpiredLastKnown` once every
  /// [_cyclesPerPrune] cycles to bound the SQLCipher last-known table
  /// during long backgrounded sessions. Foreground also prunes hourly
  /// (`map_shell.dart::_pruneTimer`); the two are idempotent because
  /// `prune_expired_last_known` is a single SQLite DELETE under a
  /// per-instance `Mutex<Connection>` (`haven-core/src/circle/storage.rs:1166`).
  int _cyclesSinceLastPrune = 0;

  /// Run prune approximately once per hour at the nominal 120 s cadence.
  /// Matches the foreground hourly cadence and avoids duplicate writes.
  static const int _cyclesPerPrune = 30;

  /// Hooks for tests: when non-null, [onStart] uses these instead of
  /// constructing fresh instances. Production callers pass `null`.
  ///
  /// The hooks must form a consistent set — sharing the same
  /// `CircleManagerFfi` between [_circleManager], [_circleService], and
  /// [_locationSharingService] is the test's responsibility.
  @visibleForTesting
  CircleManagerFfi? overrideCircleManager;

  /// Test-only override for the relay service.
  @visibleForTesting
  NostrRelayService? overrideRelayService;

  /// Test-only override for the geolocation service.
  @visibleForTesting
  GeolocatorLocationService? overrideLocationService;

  /// Test-only override for the location-sharing service. Applied by
  /// [_wireSharingServices] AFTER the circle service is built over the real
  /// manager seam, so a host test drives the publish cycle against a real
  /// circle roster while the receive plane is a stand-in.
  @visibleForTesting
  LocationSharingService? overrideLocationSharingService;

  /// Test-only override for the jitter sampler (`LocationEventService` is an
  /// FFI opaque handle whose constructor needs the bridge).
  @visibleForTesting
  LocationEventService? overrideLocationEventService;

  /// Test-only override for the Rule-14 liveness query (`isSessionLive`).
  ///
  /// Production leaves this `null` and calls the real FFI. Without this seam
  /// the whole `_ensureSession`/`_attemptSessionReclaim` orchestration could
  /// only be pinned by scanning the source text (see
  /// `session_reclaim_gate_test.dart`), which proves a gate's token appears in
  /// the right order but not that the gated code path actually runs and
  /// produces the right outcome against a scripted sequence of answers.
  @visibleForTesting
  Future<bool> Function({required String dataDir})? overrideIsSessionLive;

  /// Test-only override for [forceReleaseLiveSession]. See
  /// [overrideIsSessionLive] for why this seam exists.
  @visibleForTesting
  Future<ForceReleaseOutcomeFfi> Function()? overrideForceReleaseLiveSession;

  /// Test-only override for the liveness-probe confirmation timeout.
  ///
  /// Production uses the real [kLivenessProbeTimeout] (5 s, "generous relative
  /// to a publish cycle" — see `foreground_liveness_probe_test.dart`). A
  /// behavioural test of the full two-probe reclaim sequence would otherwise
  /// cost 2 × 5 s plus the gap below for every "genuinely dead foreground"
  /// case, so this is shortened in tests — never in production, where the
  /// default is the unmodified real constant.
  @visibleForTesting
  Duration livenessProbeTimeout = kLivenessProbeTimeout;

  /// Test-only override for the gap between the two confirmation probes
  /// (production default: [kLivenessProbeGap], 3 s). See
  /// [livenessProbeTimeout].
  @visibleForTesting
  Duration livenessProbeGap = kLivenessProbeGap;

  /// Test-only override for whether the cross-isolate liveness channel is
  /// ready (production default: [foregroundTaskChannelReady]).
  ///
  /// A "not ready" channel makes [ForegroundLivenessProbe.mainIsolateIsAlive]
  /// return `true` (alive) immediately, without ever waiting or accepting a
  /// simulated reply — the correct fail-closed production behaviour when no
  /// port is registered, but it would make every reclaim test trivially
  /// "alive" regardless of what the test scripts, since `flutter test` never
  /// has a real cross-isolate port. Forcing this `true` in a test lets the
  /// probe run its real ping/timeout/reply protocol instead.
  @visibleForTesting
  bool Function() livenessChannelReady = foregroundTaskChannelReady;

  /// Test-only override for the `hasIdentity` gate input to
  /// [evaluateSessionReclaimGates].
  ///
  /// Production leaves this `null` and reads the real
  /// `_identityManager?.hasIdentity()`. Lets a reclaim test pass the identity
  /// gate — and reach the guard/backoff/probe machinery behind it — without
  /// adopting an identity through [startWithoutBridgeForTest].
  @visibleForTesting
  bool? overrideHasIdentity;

  /// Cached nominal publish interval as [BigInt] to avoid per-tick allocation.
  static final BigInt _nominalSecsBigInt = BigInt.from(
    kLocationUpdateInterval.inSeconds,
  );

  /// Secure storage for reading identity and preferences.
  static const FlutterSecureStorage _secureStorage = FlutterSecureStorage(
    iOptions: IOSOptions(
      accessibility: KeychainAccessibility.first_unlock_this_device,
    ),
  );

  // ---------------------------------------------------------------------------
  // Storage keys (must match the providers in the foreground isolate).
  // ---------------------------------------------------------------------------
  static const String _identityStorageKey = 'haven.nostr.identity';

  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {
    debugPrint('[BackgroundTask] onStart (starter=$starter)');

    // Clear the idle flag — the background isolate is now active.
    await _setIdle(false);

    try {
      // 1. Initialize Rust FFI in this isolate.
      await RustLib.init();

      // 2. Initialize the platform keyring store (idempotent).
      await initKeyringStore();

      // 3. Resolve the data directory (same path as foreground isolate).
      final dataDir = await const PathProviderDataDirectory()
          .getDataDirectory();

      // 4. Create identity manager and load from secure storage. MUST run
      //    BEFORE the circle manager (opened in `_bringUpSession`): Dark
      //    Matter's
      //    `CircleManagerFfi.newInstance` hard-requires the identity secret
      //    bytes at construction time (it binds the account identity, the
      //    NIP-59 welcome signer, and the account-identity-proof signer).
      _identityManager = await NostrIdentityManager.newInstance();
      final storedBytes = await _secureStorage.read(key: _identityStorageKey);
      if (storedBytes != null) {
        final bytes = base64Decode(storedBytes);
        try {
          await _identityManager!.loadFromBytes(secretBytes: bytes);
          if (_identityManager!.hasIdentity()) {
            _pubkeyHex = _identityManager!.pubkeyHex();
          }
        } finally {
          // Zero the Dart-side copy of the secret bytes. The Rust FFI
          // boundary already zeroizes its input, but Dart has no
          // guaranteed zeroize — best-effort overwrite reduces the
          // window the secret sits in managed memory.
          bytes.fillRange(0, bytes.length, 0);
        }
      }

      // 5-7. Every step past the identity load has an `override*` seam, so
      //    they live in `_bringUpSession`, which a host test can drive end to
      //    end (see [startWithoutBridgeForTest]).
      await _bringUpSession(dataDir);

      // 8. Publish scheduling is seeded lazily in `_publishCycle` — every
      //    eligible circle is registered "due now" on the first cycle the
      //    background actually owns publishing, then re-armed on the burst's
      //    one jittered sample. No seed timestamp is needed (or read) here:
      //    seeding due-now bounds a circle's worst-case inter-publish gap
      //    across the foreground→background handoff to one background cycle,
      //    keeping the kind-445 TTL no-gap invariant intact.

      // log-scan-ok: presence-only ("loaded"/"none"), never the pubkey value
      debugPrint(
        '[BackgroundTask] Initialized '
        '(identity=${_pubkeyHex != null ? "loaded" : "none"}, '
        'locationSharing=${_locationSharingService != null})',
      );
    } on Object catch (e) {
      debugPrint('[BackgroundTask] onStart FAILED: ${e.runtimeType}');
    }
  }

  /// [onStart] steps 5-7: the manager, the relay/location/jitter services and
  /// the sharing services over them, in that order.
  ///
  /// The manager open comes first and its failure is caught INSIDE
  /// `_openCircleManager` on purpose. It is the one step that fails routinely
  /// for a recoverable reason (the Rule-14 guard held by a session whose
  /// isolate is gone), and letting it throw here would skip the services too —
  /// leaving the isolate with no relay service and no location-sharing service,
  /// so a later recovery that rebuilt only the manager could not publish.
  /// Tests inject a pre-built manager via [overrideCircleManager]; only one
  /// `CircleManagerFfi` may exist per isolate or MLS state diverges across two
  /// in-memory engine sessions. With no identity the manager stays null and
  /// every downstream call site no-ops.
  ///
  /// The circle service shares that one manager rather than opening a second
  /// MLS state cache over the same DB, and the identity adapter exposes only
  /// the pubkey hex — secret material stays inside the identity manager.
  Future<void> _bringUpSession(String dataDir) async {
    _dataDir = dataDir;
    await _openCircleManager();
    await _ensureAuxServices();
    _wireSharingServices();
  }

  /// The WATCHDOG. Covers the states in which no delivery can arrive, and
  /// nothing else.
  ///
  /// It never registers: it can only invoke [_publishCycle], which registers
  /// below the ownership and disclosure gates. Wiring a registration here
  /// would put one above both, on the one path that runs unconditionally.
  @override
  void onRepeatEvent(DateTime timestamp) {
    // A tick during a cycle is a no-op — two cycles in flight are two writers
    // on one MLS group. A delivery that lands meanwhile is not lost: it sets
    // `_deliveryPending`, which this reads on the next tick.
    if (_inFlightPublish != null) return;

    _trackCycle(_runWatchdog(timestamp));
  }

  /// Records [cycle] as THE in-flight one and releases the slot when it
  /// settles.
  ///
  /// The release cannot live in [_runCycleWithIdleTracking] alone, because
  /// [_runWatchdog] has exits that never reach it: the foreground-ownership
  /// yield and the healthy "nothing to do" return. A slot left pointing at a
  /// COMPLETED future latches the isolate — every later tick, every delivery
  /// and both handoff signals read it as "a cycle is running" and return, so
  /// the service publishes once per backgrounding and then goes silent.
  ///
  /// [identical] because [_runCycleWithIdleTracking] releases the slot from
  /// underneath this on the cycle path, and a later input may already have
  /// claimed it by the time [cycle] settles.
  void _trackCycle(Future<void> cycle) {
    _inFlightPublish = cycle;
    unawaited(
      cycle.whenComplete(() {
        if (identical(_inFlightPublish, cycle)) _inFlightPublish = null;
      }),
    );
  }

  /// Decides whether [timestamp]'s tick has anything to do.
  ///
  /// Deliberately NOT "run the cycle every tick": in the steady state the
  /// registration IS the cadence, and a tick that ran a cycle anyway would
  /// re-introduce the 72 s poll this phase removed — a roster read, a wake and
  /// (once the cached fix ages out) an acquisition, all for a schedule that
  /// already has a fix on the way.
  Future<void> _runWatchdog(DateTime timestamp) async {
    if (await _foregroundOwnsPublishing()) {
      // Not merely "skip this tick": while the UI isolate owns publishing it
      // also owns the platform registration, and two at once is the state the
      // ownership stamp exists to prevent.
      await _yieldToForeground();
      return;
    }

    // Silence past the age at which a fix stops being publishable is the
    // signal that the registration is not working — the platform's own retry
    // alarms produce no app callback, so nothing else would ever say so.
    final quietSince = _laterOf(_lastDeliveryAt, _registeredAt);
    if (_fixSub != null &&
        (quietSince == null ||
            timestamp.difference(quietSince) > kStreamPositionMaxAge)) {
      _registrationSuspect = true;
    }
    // An OVERDUE circle is the other thing only this tick can see. In the
    // healthy steady state there is never one — the fix is asked for
    // `kBackgroundFixLeadTime` early and the horizon selects the circle
    // before its due-time — so this does not re-introduce the poll. It fires
    // exactly when the delivery-driven path has already failed the circle: a
    // fix that came late, or a publish that did not land.
    if (_fixSub != null &&
        !_registrationSuspect &&
        !_deliveryPending &&
        !_anythingDueBy(timestamp)) {
      return;
    }

    debugPrint('[BackgroundTask] cycle trigger=watchdog');
    await _runCycleWithIdleTracking(timestamp);
  }

  Future<void> _runCycleWithIdleTracking(DateTime timestamp) async {
    // CRITICAL: MUST await before any publish work. The foreground isolate
    // reads kBackgroundIdleKey from disk via SharedPreferences, so the flip
    // to false must be persisted before _publishCycle starts. A race within
    // the async write window (a few ms) would let _waitForBackgroundIdle
    // return immediately on a foreground resume, causing both isolates to
    // call encryptLocation concurrently.
    await _setIdle(false);
    try {
      await _publishCycle(timestamp);

      // A fix that arrived mid-cycle is served here, inside the SAME
      // single-flight envelope, so it can neither race the cycle it
      // interrupted nor be dropped. Only when something is actually due: a
      // delivery that beat its circle's due-time has nothing to publish, and
      // re-running the whole cycle for it would cost a roster read per fix.
      final pending = _deliveryPending;
      _deliveryPending = false;
      final now = DateTime.now();
      if (pending && _dueWithinHorizon(now)) {
        debugPrint('[BackgroundTask] cycle trigger=pending-delivery');
        await _publishCycle(now);
      }
    } finally {
      _inFlightPublish = null;
      await _setIdle(true);
    }
  }

  /// Whether any tracked circle is due at or before [at].
  bool _anythingDueBy(DateTime at) =>
      _dueTracker.dueKeysUpTo(_dueTracker.trackedKeys, at).isNotEmpty;

  /// Whether any tracked circle is due inside [kBackgroundFixHorizon] of
  /// [now] — the same window [_publishCycle] selects with.
  bool _dueWithinHorizon(DateTime now) =>
      _anythingDueBy(now.add(kBackgroundFixHorizon));

  /// Reads the foreground-ownership stamp from a freshly reloaded snapshot.
  ///
  /// One judgement, two callers ([_runWatchdog] and [_publishCycle]) — a
  /// second, hand-rolled reading of the same stamp is how the two paths
  /// silently disagree about who owns publishing.
  Future<bool> _foregroundOwnsPublishing() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    return _foregroundActiveFrom(prefs);
  }

  /// Fix 2: when the key has never been written (cold-start Android
  /// auto-restart before `MapShell.initState` runs), assume the foreground is
  /// active so the background does not race it.
  /// `BackgroundLocationManager.isForegroundActive()` treats a null/missing
  /// key as `false`, which is the wrong default for that one window.
  Future<bool> _foregroundActiveFrom(SharedPreferences prefs) async {
    if (prefs.getInt(kForegroundActiveAtMsKey) == null) return true;
    return BackgroundLocationManager.isForegroundActive();
  }

  /// Everything this isolate must let go of the moment it stops owning
  /// publishing — because the UI isolate took it back, or because the user
  /// switched background sharing off: its platform registration and every
  /// per-circle schedule.
  ///
  /// Emptying the schedule is what makes every circle due-now on the NEXT
  /// handoff, bounding the gap across it to one background cycle instead of a
  /// full jittered interval.
  Future<void> _yieldToForeground() async {
    await _cancelRegistration();
    _dueTracker.pruneToKeys(<String>{});
  }

  /// One platform delivery.
  ///
  /// Synchronous and short on purpose: it is called from a stream callback, so
  /// anything awaited here would run outside the single-flight envelope.
  void _onFixDelivered(Position fix) {
    // The replay of the fix this isolate already used (S+ historical
    // delivery). It carries no new information, so it is not a delivery for
    // the watchdog's freshness either.
    if (_lastConsumedFixTs == fix.timestamp) return;
    _lastConsumedFixTs = fix.timestamp;
    _lastDeliveryAt = DateTime.now();

    // A cycle that is waiting for its first fix takes this one directly; it
    // must not also read as pending, or the cycle would follow itself up.
    final waiter = _firstDeliveryWaiter;
    if (waiter != null && !waiter.isCompleted) {
      waiter.complete();
      return;
    }

    if (_inFlightPublish != null) {
      _deliveryPending = true;
      return;
    }

    debugPrint('[BackgroundTask] cycle trigger=delivery');
    _trackCycle(_runCycleWithIdleTracking(DateTime.now()));
  }

  /// Aims the isolate's single platform location request at [earliestDue].
  ///
  /// THE only registration site, and it is reached only from [_publishCycle],
  /// below the background-sharing consent gate and the foreground-ownership
  /// and Play-disclosure ones — which is what makes "no platform request
  /// without consent" a property of the source rather than of review
  /// (`check_android_location_power.sh` check 5).
  ///
  /// A registration whose aim has not meaningfully moved is KEPT. Re-issuing
  /// it costs a cancel + listen and, on S+, a replay of the fix just
  /// consumed — which would drive another cycle, which would re-register.
  Future<void> _ensureRegistration({
    required DateTime earliestDue,
    required DateTime now,
    required DateTime plannedPublishStart,
  }) async {
    final target = earliestDue.subtract(kBackgroundFixLeadTime);
    final registered = _registeredTarget;
    if (_fixSub != null &&
        !_registrationSuspect &&
        registered != null &&
        registrationIsAligned(registered, target)) {
      return;
    }

    final interval = nextFixRequestInterval(
      earliestDue: earliestDue,
      now: now,
      plannedPublishStart: plannedPublishStart,
    );
    await _cancelRegistration();
    final service = _locationService;
    if (service == null) return;
    _fixSub = service
        .getLocationStream(
          profile: AndroidStreamProfile.backgroundService(interval: interval),
        )
        .listen(
          _onFixDelivered,
          onError: (Object e) {
            // Presence only (Rule 8): the type, never the message, which on
            // this boundary can carry provider and permission detail.
            debugPrint(
              '[BackgroundTask] fix stream error: ${e.runtimeType}',
            );
            _registrationSuspect = true;
          },
          onDone: () {
            // The stream ended (a closed provider). Back to Idle so the
            // watchdog re-arms rather than waiting on a dead registration.
            _fixSub = null;
            _registeredTarget = null;
          },
        );
    _registeredTarget = target;
    _registeredAt = DateTime.now();
    debugPrint(
      '[BackgroundTask] registration armed (${interval.inSeconds}s)',
    );
  }

  /// Releases the platform registration, if any. Idempotent.
  Future<void> _cancelRegistration() async {
    final sub = _fixSub;
    _fixSub = null;
    _registeredTarget = null;
    _registeredAt = null;
    _registrationSuspect = false;
    if (sub == null) return;
    await sub.cancel();
  }

  /// The later of two optional instants, or whichever one exists.
  static DateTime? _laterOf(DateTime? a, DateTime? b) {
    if (a == null) return b;
    if (b == null) return a;
    return a.isAfter(b) ? a : b;
  }

  /// Waits for the platform's first fix, bounded by [firstDeliveryWait].
  ///
  /// Only reached with a COLD cache — the first cycle after a handoff, or one
  /// whose cached fix aged out. On S+ the registration itself is answered with
  /// the provider's last location, so this normally returns in one event-loop
  /// hop and spares the cycle a 30 s HIGH_ACCURACY one-shot; where there is no
  /// historical delivery it lapses and the one-shot runs exactly as before.
  Future<void> _awaitFirstDelivery() async {
    if (_shuttingDown || _fixSub == null) return;
    final waiter = Completer<void>();
    _firstDeliveryWaiter = waiter;
    try {
      await Future.any<void>(<Future<void>>[
        waiter.future,
        Future<void>.delayed(firstDeliveryWait),
        _shutdownSignal.future,
      ]);
    } finally {
      _firstDeliveryWaiter = null;
    }
  }

  /// Writes the cross-isolate idle flag. Best-effort — failures here
  /// only widen the window the foreground waits on `_waitForBackgroundIdle`,
  /// they cannot break the MLS single-writer invariant (the 60 s
  /// overlap guard is the authoritative defense).
  Future<void> _setIdle(bool idle) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(kBackgroundIdleKey, idle);
    } on Object catch (_) {
      // Non-fatal.
    }
  }

  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {
    debugPrint('[BackgroundTask] onDestroy (isTimeout=$isTimeout)');

    // Release any decorrelation wait FIRST, before the await below. The cycle
    // paces its per-circle publishes seconds apart on purpose; without this
    // signal `onDestroy` would sit in `await _inFlightPublish` for the rest of
    // the burst's spread, inside Android's stop window. Signalling first turns
    // that into "finish the publish already in flight, then stop".
    if (!_shutdownSignal.isCompleted) _shutdownSignal.complete();

    // Release the platform registration BEFORE the drain, not after it: a
    // request still delivering into an isolate that is tearing down is a fix
    // nobody can publish and a GNSS engine nobody turns off. It also removes
    // the only way a new cycle could start underneath the teardown.
    await _cancelRegistration();

    // Hold the CPU across the drain. The plugin invokes the Kotlin lifecycle
    // listeners synchronously right after it invokes this method
    // asynchronously, i.e. before the drain below has started, so its own lock
    // can be gone by now — which is exactly why the scoped lock is released
    // from THIS method's `finally` and never from those listeners.
    await _wakeLock.acquire();
    try {
      await _drainAndTearDown();
    } finally {
      await _wakeLock.release();
    }

    // Signal to the foreground isolate that no publish cycle is in
    // flight. The foreground reads this flag on resume to know it is
    // safe to start its own publisher without violating the MLS
    // single-owner invariant.
    await _setIdle(true);
  }

  /// The teardown [onDestroy] runs under the scoped wake lock.
  Future<void> _drainAndTearDown() async {
    // Await any in-flight publish cycle so it can finish its
    // `encryptLocation` + `publishEvent` calls before we tear down
    // services. Without this, nulling `_relayService` mid-publish
    // would waste an MLS epoch advance (encrypt succeeds, publish
    // fails because the relay handle is gone).
    //
    // BOUNDED, because this wait is what the UI isolate's handover budget has
    // to cover: an unbounded drain here is a foreground that sits on a blank
    // map for as long as one relay's retry ladder feels like taking (~49 s).
    // Every step of the cycle checks `_shuttingDown`, so the only work that can
    // still be running is a single publish; this gives it one attempt's worth
    // ([kBackgroundTeardownDrainBudget]) and then proceeds regardless.
    //
    // Abandoning that publish is a sample, not a fork: a location is an MLS
    // APPLICATION message, so Rule 13's publish-before-apply contract is not in
    // play — there is no staged commit to confirm or roll back, and the sender
    // ratchet already advanced and persisted before the relay was ever
    // contacted.
    try {
      await _inFlightPublish?.timeout(teardownDrainBudget);
    } on Object catch (_) {
      // Publish errors are already handled inside `_publishCycle`; a
      // TimeoutException here means the drain budget was spent, which is the
      // designed outcome rather than a failure.
    }

    // RE-POST the timer. The hold taken above expires
    // [kPublishWakeLockTimeout] after IT, and this drain may just have spent
    // half of that budget; everything below (the unbounded Rule-13 wait, the
    // relay shutdown, the Rule-14 handback) would otherwise run on the tail of
    // it, with the plugin's permanent lock already gone —
    // `stopForegroundService()` releases that one synchronously before Dart's
    // `onDestroy` is even entered.
    await _wakeLock.acquire();

    // ...and then UNBOUNDED for the one slice of that cycle where the budget
    // above would be a correctness bug rather than a lost sample. A
    // `fetchMemberLocations` can publish a receiver-side auto-commit and then
    // confirm it; giving up between those two steps tears down the relay and
    // disposes the manager underneath a commit that is possibly already on a
    // relay, so it is neither confirmed nor rolled back — Rule 13 broken, and
    // the group left in `PendingPublish`. Read AFTER the bounded drain above,
    // which is what makes it observe whatever survived it. Null on the
    // overwhelming majority of teardowns, so this costs nothing to have.
    final commitCritical = _inFlightCommitCritical;
    if (commitCritical != null) {
      debugPrint('[BackgroundTask] onDestroy: draining commit-critical work');
      try {
        await commitCritical;
      } on Object catch (_) {
        // Handled per-circle inside the cycle; what matters here is that it
        // reached its own conclusion rather than being cut short.
      }
      // Unbounded by construction, so it can outlast the native
      // [kPublishWakeLockTimeout] ceiling on its own. The handback below is
      // the last thing that frees the Rule-14 slot for the foreground, so it
      // does not run on the tail of an expiring hold.
      await _wakeLock.acquire();
    }

    try {
      await _relayService?.shutdown();
    } on Object catch (_) {
      // Ignore shutdown errors.
    }

    // Null the high-level services first so any callbacks that fire
    // mid-teardown find the underlying handles still valid.
    _locationSharingService = null;
    _circleService = null;

    // Hand the MLS DB's Rule-14 single-session slot back BEFORE dropping the
    // reference. Rust statics — including the `LIVE_SESSIONS` registry backing
    // that rule — are shared by EVERY Dart isolate in the one loaded `.so`, and
    // the guard is released only when Rust drops the manager. Nulling alone
    // defers that to a GC in an isolate that is about to be torn down, so the
    // slot can stay registered after this task is gone and lock the FOREGROUND
    // out of its own database ("an MLS session is already open on this
    // database") until the process dies. `dispose()` is idempotent and this is
    // the last use of the handle — same discipline as the WorkManager worker's
    // teardown in `background_catchup_worker.dart`.
    try {
      _circleManager?.dispose();
    } on Object catch (_) {
      // Best-effort, like the relay shutdown above.
    }
    _circleManager = null;
    _identityManager = null;
    _relayService = null;
    _locationService = null;
    _locationEventService = null;
    _pubkeyHex = null;
  }

  @override
  void onReceiveData(Object data) {
    // `onReceiveData` is the ONE dispatch point for everything sent to this
    // task, so anything added later must branch here rather than assume it is
    // reached. The probe reports whether it consumed the payload.
    if (_livenessProbe.onData(data)) return;

    // The UI isolate's handoff signals. Both are prompts, never
    // authorisations: the paused one runs the ordinary cycle, which reloads
    // preferences and re-runs every gate before it registers or collects, so
    // a signal that arrives while the ownership stamp is still fresh does
    // nothing. The resumed one only ever REMOVES capability.
    if (data == kForegroundPausedSignal) {
      if (_inFlightPublish != null) return;
      debugPrint('[BackgroundTask] cycle trigger=paused-signal');
      _trackCycle(_runCycleWithIdleTracking(DateTime.now()));
      return;
    }
    if (data == kForegroundResumedSignal) {
      // Ahead of the UI isolate re-taking its own 1 Hz stream, and without
      // waiting for a delivery that may be a whole interval away.
      unawaited(_cancelRegistration());
      // And again when any in-flight cycle ends. That cycle passed its own
      // ownership gate before this signal existed and can still arm a request
      // below it (the retry cadence a failed publish sets), which would
      // outlive the cancel above and leave two live platform requests while
      // the UI isolate re-takes its own. This signal only ever REMOVES
      // capability, so doing it twice costs nothing.
      final cycle = _inFlightPublish;
      if (cycle != null) unawaited(cycle.whenComplete(_cancelRegistration));
      return;
    }

    debugPrint('[BackgroundTask] unrouted task data: ${data.runtimeType}');
  }

  @override
  void onNotificationPressed() {
    FlutterForegroundTask.launchApp();
  }

  // ---------------------------------------------------------------------------
  // Publish cycle
  // ---------------------------------------------------------------------------

  /// Opens the circle manager, leaving `_circleManager` null on failure.
  ///
  /// Never throws: see the call site in [onStart] for why a failure here must
  /// not abort the rest of initialisation.
  Future<void> _openCircleManager() async {
    if (overrideCircleManager != null) {
      _circleManager = overrideCircleManager;
      return;
    }
    final dataDir = _dataDir;
    if (dataDir == null || !(_identityManager?.hasIdentity() ?? false)) return;
    try {
      // Re-fetched fresh rather than reusing the onStart copy (already
      // zeroized), and scrubbed again on the way out — Security Rule 9.
      //
      // `withFreshSecret` owns the `finally` that wipes it. Fetching into a
      // bare local, as this did, leaves the raw 32-byte nsec in the isolate's
      // Dart heap for the GC to relocate rather than erase. That mattered more
      // after this method gained a second caller: the reclaim path can run
      // every backoff window, so each attempt used to mint another copy that
      // was never wiped.
      _circleManager = await withFreshSecret(
        _identityManager!.getSecretBytes,
        (secret) => CircleManagerFfi.newInstance(
          dataDir: dataDir,
          identitySecretBytes: secret,
        ),
      );
    } on Object catch (e) {
      // Generic in the UI sense (Rule 8): the type alone, never the message,
      // which can carry MLS group ids or relay URLs.
      debugPrint(
        '[BackgroundTask] circle manager open failed: ${e.runtimeType}',
      );
    }
  }

  /// Creates the relay / location / event services if they are absent.
  ///
  /// Separated from [onStart] so it can be re-run. `NostrRelayService.initialize`
  /// rethrows, and in `onStart` that exception is caught only by the outer
  /// handler — which aborts the remaining steps. Because the manager is opened
  /// BEFORE this, a throw here used to leave the isolate holding the Rule-14
  /// guard with no circle service and no sharing service, and nothing could
  /// repair it: the recovery path keys off `_circleManager == null`, which is
  /// false in that state. The isolate then held the guard hostage — unusable
  /// itself and blocking the main isolate from opening — until the OS restarted
  /// the service.
  Future<void> _ensureAuxServices() async {
    if (_relayService == null) {
      final relay = overrideRelayService ?? NostrRelayService();
      // Assign only after a successful initialize, so a failed attempt leaves
      // the field null and the next cycle retries rather than reusing a
      // half-initialised service.
      await relay.initialize();
      _relayService = relay;
    }
    _locationService ??= overrideLocationService ?? GeolocatorLocationService();
    _locationEventService ??=
        overrideLocationEventService ?? LocationEventService();
  }

  /// Repairs an isolate that holds a manager but never finished wiring.
  ///
  /// Non-destructive: it touches no other isolate's session, so unlike a
  /// reclaim it needs no liveness gate.
  Future<bool> _repairSharingServices() async {
    try {
      await _ensureAuxServices();
    } on Object catch (e) {
      debugPrint('[BackgroundTask] service repair failed: ${e.runtimeType}');
      return false;
    }
    _wireSharingServices();
    return _locationSharingService != null;
  }

  /// Builds the circle + location-sharing services over the current manager.
  ///
  /// No-op when the manager is absent, so it is safe to call both from
  /// [onStart] and after a recovery.
  void _wireSharingServices() {
    if (_identityManager == null ||
        _circleManager == null ||
        _relayService == null) {
      return;
    }
    _circleService = NostrCircleService.withInjectedManager(
      relayService: _relayService!,
      injectedManager: _circleManager!,
    );
    final overrideSharing = overrideLocationSharingService;
    if (overrideSharing != null) {
      _locationSharingService = overrideSharing;
      return;
    }
    _locationSharingService = LocationSharingService(
      circleService: _circleService!,
      relayService: _relayService!,
      identityService: BackgroundIdentityService(_identityManager!),
      // Delivery liveness for the RECEIVE plane while backgrounded. Without
      // it this isolate's peer receipts never reach `circle_health`, and the
      // foreground — whose cache is cleared on pause — comes back to a stale
      // persisted stamp and shows a "not receiving" banner over a background
      // session that was receiving perfectly.
      //
      // The factory reads the CURRENT `_circleManager` on every call rather
      // than capturing today's handle: the reclaim path closes and re-opens
      // the manager, and a captured handle would be a disposed one from the
      // first reclaim onwards. `NostrCircleHealthService` swallows the throw
      // below (health telemetry must never take down the receive path), so a
      // window with no manager costs one unrecorded stamp, not a failure.
      healthService: NostrCircleHealthService(
        circleManagerFactory: () async {
          final manager = _circleManager;
          if (manager == null) {
            throw StateError('no circle manager');
          }
          return manager;
        },
      ),
    );
  }

  /// Acquires a usable session, escalating only as far as the situation needs.
  ///
  /// # Why an open is tried before any reclaim
  ///
  /// The two are different problems and were conflated. A reclaim is for a
  /// guard held by an isolate that is GONE; it declines outright when the guard
  /// is free (`guardNotHeld`), because stopping or releasing anything would
  /// achieve nothing. But the normal path to this isolate owning a session is
  /// exactly that free case: the foreground hands the session over at pause, so
  /// by the time this runs there is usually nothing to reclaim — just something
  /// to open.
  ///
  /// Wiring the reclaim as the ONLY recovery therefore left the service
  /// declining to open a database that was sitting available, and background
  /// publishing stayed dead through the very handoff meant to enable it.
  ///
  /// The registry query comes first because it is cheap and side-effect-free.
  /// It is advisory — the guard can change state immediately after — but the
  /// acquire remains the authority and fails closed, so a lost race costs one
  /// cycle, never correctness.
  Future<bool> _ensureSession() async {
    // Opening a session for a service that is stopping buys nothing and costs
    // the teardown up to two 5 s liveness probes plus the gap between them.
    if (_shuttingDown) return false;
    final dataDir = _dataDir;
    if (dataDir == null) return false;

    final bool guardHeld;
    try {
      guardHeld = await _isSessionLive(dataDir: dataDir);
    } on Object catch (e) {
      // Cannot tell: do not open blind and do not escalate.
      debugPrint('[BackgroundTask] session query failed: ${e.runtimeType}');
      return false;
    }

    if (guardHeld) {
      // Someone else holds it. Only the reclaim path knows whether that is
      // recoverable, and it carries the gates that decide.
      return _attemptSessionReclaim();
    }

    // Free — the post-handoff steady state. Just take it. The repair helper
    // is the wiring step: it also rebuilds any service bring-up lost.
    await _openCircleManager();
    if (_circleManager == null) return false;
    if (!await _repairSharingServices()) return false;
    debugPrint('[BackgroundTask] session acquired');
    return true;
  }

  /// Tries to recover from "the MLS session is held by an isolate that is
  /// gone".
  ///
  /// Returns `true` only if a usable `_circleManager` exists afterwards.
  ///
  /// # Why this is gated so heavily
  ///
  /// `forceReleaseLiveSession` stops the process-global live-sync engine. If
  /// the main isolate is actually ALIVE, that engine is ITS engine: the stream
  /// ends, nothing restarts it (`NostrSubscriptionService` registers no
  /// `onDone`), and the guard is still held by the main isolate's own handle —
  /// so the reclaim
  /// destroys live receive and gains nothing. Every gate below exists to make
  /// sure that case is excluded before the destructive call, and every one of
  /// them fails CLOSED (declining to reclaim) when it cannot get an answer.
  Future<bool> _attemptSessionReclaim() async {
    final dataDir = _dataDir;

    final SharedPreferences prefs;
    try {
      prefs = await SharedPreferences.getInstance();
      await prefs.reload();
    } on Object catch (e) {
      debugPrint(
        '[BackgroundTask] reclaim: prefs unavailable (${e.runtimeType})',
      );
      return false;
    }

    // Is the guard actually held? Asked of the registry, never by classifying
    // an error string: Haven's FFI errors interpolate remote-authored text (a
    // circle admin controls the group's routing relays, and the relay gate
    // formats a rejected URL into its message), so a substring test would let a
    // remote party trigger this path at will.
    bool guardHeld = false;
    if (dataDir != null) {
      try {
        guardHeld = await _isSessionLive(dataDir: dataDir);
      } on Object catch (e) {
        debugPrint(
          '[BackgroundTask] reclaim: liveness query failed (${e.runtimeType})',
        );
        return false;
      }
    }

    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final decision = evaluateSessionReclaimGates(
      hasDataDir: dataDir != null,
      hasIdentity:
          overrideHasIdentity ?? (_identityManager?.hasIdentity() ?? false),
      wipePending: prefs.getBool(kPendingMlsWipeKey) ?? false,
      guardHeld: guardHeld,
      lastAttemptMs: prefs.getInt(kBackgroundSessionReclaimAtMsKey),
      nowMs: nowMs,
      backoff: kBackgroundSessionReclaimBackoff,
    );
    if (decision != SessionReclaimDecision.proceed) {
      debugPrint('[BackgroundTask] reclaim: declined (${decision.name})');
      return false;
    }

    // Consume the backoff HERE — before the probe, not after it.
    //
    // Recording it only on the reclaim path (as an earlier version did) meant a
    // "main isolate alive" verdict never advanced the limit. That is the normal
    // steady state whenever a user backgrounds the app with sharing on: the
    // main isolate keeps its handle, so the open keeps failing and this runs on
    // EVERY 72-second tick, firing a full cross-isolate probe each time. Each
    // probe is an independent chance for a GC pause or a jank frame to look
    // like death, so hundreds of rolls per afternoon turn a rare misread into a
    // likely one. Consuming the limit unconditionally bounds the attempts —
    // and it keeps the original crash-safety property, since a crash between
    // here and the release still leaves the limit spent.
    try {
      await prefs.setInt(kBackgroundSessionReclaimAtMsKey, nowMs);
    } on Object catch (e) {
      debugPrint(
        '[BackgroundTask] reclaim: backoff write failed (${e.runtimeType})',
      );
      return false;
    }

    // The decisive gate: only a DEAD main isolate may be reclaimed from. The
    // foreground-active heartbeat cannot answer this (the Android pause path
    // writes 0 while keeping the session), so ask the isolate itself.
    //
    // Confirmed with a SECOND probe. One silent window can be a garbage
    // collection or a slow frame in an isolate that is perfectly alive, and
    // acting on that destroys its live receive. Two consecutive silences,
    // separated by a fresh round trip, are far harder to produce by transient
    // jank. Both fail closed to "alive".
    _livenessProbe.resetRound();
    if (await _livenessProbe.mainIsolateIsAlive(
      timeout: livenessProbeTimeout,
      channelReady: livenessChannelReady,
    )) {
      debugPrint('[BackgroundTask] reclaim: declined, main isolate alive');
      return false;
    }
    // Space the confirmation. Issued back-to-back the two probes observe one
    // contiguous window, so a single sustained stall — the main isolate blocked
    // on a sync FFI call while this isolate holds the same SQLCipher locks —
    // satisfies both, which is precisely what a confirmation is supposed to
    // rule out. A gap makes them independent samples.
    await Future<void>.delayed(livenessProbeGap);
    if (await _livenessProbe.mainIsolateIsAlive(
      timeout: livenessProbeTimeout,
      channelReady: livenessChannelReady,
    )) {
      debugPrint('[BackgroundTask] reclaim: declined, main isolate answered '
          'on retry');
      return false;
    }
    // A reply for EITHER probe, including one that landed after its own wait
    // elapsed, is proof of life. Both probes timing out is not the same as
    // nothing ever answering.
    if (_livenessProbe.sawRecentReply) {
      debugPrint('[BackgroundTask] reclaim: declined, late reply observed');
      return false;
    }

    // Re-check the guard after the probes. The window between the first query
    // and here is seconds wide, and if the holder released in the meantime
    // there is nothing to reclaim — just open.
    if (dataDir != null) {
      try {
        if (!await _isSessionLive(dataDir: dataDir)) {
          debugPrint('[BackgroundTask] reclaim: guard freed while probing');
          await _openCircleManager();
          if (_circleManager == null) return false;
          _wireSharingServices();
          return _locationSharingService != null;
        }
      } on Object catch (e) {
        debugPrint(
          '[BackgroundTask] reclaim: re-check failed (${e.runtimeType})',
        );
        return false;
      }
    }

    final ForceReleaseOutcomeFfi outcome;
    try {
      outcome = await _forceReleaseLiveSession();
    } on Object catch (e) {
      debugPrint(
        '[BackgroundTask] reclaim: release failed (${e.runtimeType})',
      );
      return false;
    }
    debugPrint('[BackgroundTask] reclaim: release outcome=${outcome.name}');
    // `StopTimedOut` means a supervisor task is still running and may still
    // hold the manager — the open would fail anyway, and retrying it would only
    // add noise. `NoSession` means the holder was never the engine (a leaked
    // handle this cannot reach), so the open will likely fail too; attempt it
    // once regardless, since the registry said the guard was held and this is
    // the cheapest way to learn whether it has since been released.
    if (outcome == ForceReleaseOutcomeFfi.stopTimedOut) return false;

    await _openCircleManager();
    if (_circleManager == null) return false;
    _wireSharingServices();
    if (_locationSharingService == null) return false;
    debugPrint('[BackgroundTask] reclaim: session recovered');
    return true;
  }

  /// The Rule-14 liveness query this handler uses: [overrideIsSessionLive] in
  /// tests, the real FFI [isSessionLive] otherwise. See
  /// [overrideIsSessionLive] for why this indirection exists.
  Future<bool> _isSessionLive({required String dataDir}) {
    final override = overrideIsSessionLive;
    if (override != null) return override(dataDir: dataDir);
    return isSessionLive(dataDir: dataDir);
  }

  /// The session-reclaim call this handler uses:
  /// [overrideForceReleaseLiveSession] in tests, the real FFI
  /// [forceReleaseLiveSession] otherwise.
  Future<ForceReleaseOutcomeFfi> _forceReleaseLiveSession() {
    final override = overrideForceReleaseLiveSession;
    if (override != null) return override();
    return forceReleaseLiveSession();
  }

  /// Registers [publishStagedCommits] as [_inFlightCommitCritical] for the
  /// same reason a fetch is: abandoning it between `publishEvent` and
  /// `confirmPublished` leaves a commit that is neither confirmed nor rolled
  /// back while possibly already on a relay.
  ///
  /// The ladder itself lives in `background_deferred_send.dart` so that no
  /// file both resolves a staged commit and takes the one-shot location
  /// publish (Security Rule 13 — see that library's doc).
  Future<void> _resolveDeferredCommits(
    Circle circle,
    DeferredSendFfi deferred,
  ) async {
    if (deferred.commits.isEmpty) return;
    final work = publishStagedCommits(
      relayService: _relayService!,
      circleManager: _circleManager!,
      circle: circle,
      deferred: deferred,
    );
    _inFlightCommitCritical = work;
    try {
      await work;
    } finally {
      _inFlightCommitCritical = null;
    }
  }

  Future<void> _publishCycle(DateTime timestamp) async {
    // 0. A cycle that begins after the stop signal must take NO hold: from
    //    that signal on the release below belongs to `onDestroy`, which
    //    performs it exactly once, so a hold taken here would outlive the
    //    teardown with only the native ceiling to end it. Reachable for real
    //    — the pending-delivery follow-up in [_runCycleWithIdleTracking] runs
    //    after the drain has already abandoned the cycle it belongs to — and
    //    it would also re-arm a platform request underneath the teardown.
    if (_shuttingDown) {
      await _cancelRegistration();
      return;
    }

    // 1. Take the scoped CPU hold before the first gate, so no path through
    //    this method can reach a fix, an encrypt or a relay without it — and
    //    so the `finally` below is the single release site for all of them.
    //    Awaited: the channel call is asynchronous, and only awaiting makes
    //    "held before the fix leaves the device" an order rather than a race.
    await _wakeLock.acquire();
    try {
      // Per-circle jitter lives in `_dueTracker` (step 7 below), so there is
      // no cycle-wide jitter gate here: the registration's own interval is
      // what schedules the cycle, and the repeat event is only a watchdog.

      // 2. Abort if no identity is loaded. A MISSING MANAGER is no longer fatal
      //    here — it may be the recoverable "Rule-14 guard held by an isolate
      //    that is gone" case, which is retried below once the foreground gate
      //    has confirmed this isolate owns publishing.
      //
      //    Every `return` from here down releases the registration first, for
      //    the reason the empty-roster path below states: a request that keeps
      //    duty-cycling GNSS for an isolate that provably cannot publish is
      //    drain with no product, and it would persist indefinitely — the
      //    watchdog re-runs the cycle and arrives at the same return.
      if (_pubkeyHex == null) {
        await _cancelRegistration();
        return;
      }

      // 3. The preference snapshot every gate below reads, reloaded from disk
      //    once per cycle so a revocation written by the UI isolate takes
      //    effect on the very next one.
      final prefs = await SharedPreferences.getInstance();
      await prefs.reload();

      // 3a. CURRENT consent to background sharing.
      //
      //     The disclosure flags (step 6b) are the record that the dialogs
      //     were accepted; they are sticky and are never cleared on opt-out,
      //     so they cannot answer "does the user still want this". Only this
      //     key can — and the teardown that should have stopped this service
      //     is best-effort (`stop()` is unawaited on every path that flips the
      //     toggle off), so a service that outlives it reaches here holding a
      //     STANDING platform location request.
      //
      //     Standing down rather than returning bare is what releases that
      //     request and drops every schedule, so an opt-out costs one cycle
      //     instead of a whole registration interval of a GNSS receiver the
      //     user has already said stop to.
      if (!(prefs.getBool(kBackgroundSharingKey) ?? false)) {
        await _yieldToForeground();
        return;
      }

      // 3b. Defer to the foreground UI isolate while it is active.
      //     BackgroundLocationManager.isForegroundActive() uses a
      //     timestamp-based staleness check: if the foreground was killed
      //     without cleaning up (OOM, force-stop), the stale timestamp is
      //     automatically expired after 2 * kBackgroundRepeatInterval (144 s).
      //     The default when the key has never been written is `true` so that
      //     a cold Android service auto-restart (before MapShell.initState
      //     writes the flag) does not race with whatever the foreground does
      //     next — BackgroundLocationManager.isForegroundActive() treats a
      //     null/missing key as `false`, but the explicit ?? true guard below
      //     protects the window before the first markForegroundActive write.
      //     The service stays running so it can take over the moment the
      //     foreground pauses, without re-incurring an Android 12+
      //     background-start that would be rejected for
      //     `FOREGROUND_SERVICE_LOCATION`.
      final foregroundActive = await _foregroundActiveFrom(prefs);
      if (foregroundActive) {
        // The foreground owns publishing: release the platform registration
        // and keep NO per-circle schedule state, so that the moment the
        // foreground goes inactive every circle is seeded "due now" (bounding
        // the handoff gap to one background cycle).
        await _yieldToForeground();
        return;
      }

      // 3c. No manager? Try to recover the MLS session, but only from HERE —
      //     after the gate above has established the foreground is not
      //     publishing. Recovery stops the process-global live-sync engine, so
      //     running it from `onStart` (which executes regardless of foreground
      //     state) could tear down a session the visible UI is actively using.
      //     Placing it here inherits that decision from code that already owns
      //     it, rather than adding a second, parallel judgement of the same
      //     question. `_attemptSessionReclaim` adds the gates specific to the
      //     destructive step, including a direct liveness probe.
      if (_circleManager == null) {
        if (!await _ensureSession()) {
          await _cancelRegistration();
          return;
        }
      } else if (_locationSharingService == null) {
        // The manager opened but the wiring did not finish (see
        // `_ensureAuxServices`). No reclaim is warranted — this isolate already
        // owns the session — but without this the isolate would hold the
        // Rule-14 guard forever while publishing nothing.
        if (!await _repairSharingServices()) {
          await _cancelRegistration();
          return;
        }
      }

      // 6b. Play "disclosure before collection" — NEVER publish location from
      //     the background without both accepted disclosures.
      //
      //     The foreground publisher has always enforced the foreground flag
      //     (`location_publish_scheduler_provider.dart:214`); this path
      //     enforced NOTHING, so background publishing was strictly weaker than
      //     foreground publishing on the one consent gate Play requires. That
      //     asymmetry was invisible only because this isolate could not publish
      //     at all (CI_HARDENING_BACKLOG.md P0-1) — it would have become live
      //     the moment P0-1 was fixed, which is why the gate lands first.
      //
      //     BOTH flags are required, and the background one is the stricter,
      //     load-bearing half: it is the disclosure carrying the "even when the
      //     app is closed or not in use" sentence, which is exactly what this
      //     isolate does. Both paths that can enable background sharing already
      //     call `ensureDisclosed(includeBackground: true)` first
      //     (`location_settings_page.dart:64-68`,
      //     `create_identity_screen.dart:274-277`), so requiring them here is a
      //     no-op for every legitimately-enabled user and a fail-closed runtime
      //     enforcement of what is otherwise only a documented precondition on
      //     `BackgroundSharingNotifier.setEnabled`.
      //
      //     Reads the same `prefs` snapshot reloaded at step 3, so it sees a
      //     revocation written by the UI isolate on the very next cycle.
      final foregroundDisclosed = prefs.getBool(kLocationDisclosureAcceptedKey);
      final backgroundDisclosed = prefs.getBool(
        kLocationDisclosureBackgroundAcceptedKey,
      );
      if (!backgroundPublishDisclosureAccepted(
        foregroundAccepted: foregroundDisclosed,
        backgroundAccepted: backgroundDisclosed,
      )) {
        debugPrint(
          '[BackgroundTask] Publish BLOCKED — location disclosure not '
          'accepted (foreground=$foregroundDisclosed, '
          'background=$backgroundDisclosed).',
        );
        // Collection, not just publication: a live registration IS the
        // platform producing this device's coordinates for Haven, which is
        // the exact thing the undisclosed state may not have.
        await _cancelRegistration();
        return;
      }

      // 7. Get eligible circles. Uses the Dart-side `CircleService` so the same
      //    `Circle` value can be reused for the fetch step below — and applies
      //    the SAME eligibility filter as the foreground publisher
      //    (`filterPublishEligibleCircles`): accepted, not a pre-cutover
      //    orphan, not engine-blocked (Rule 8). (Previously it only filtered
      //    on `accepted`, so it kept retrying orphaned/blocked circles that can
      //    never succeed.)
      if (_circleService == null) {
        await _cancelRegistration();
        return;
      }
      final circles = await _circleService!.getVisibleCircles();
      final accepted = filterPublishEligibleCircles(circles, _circleService!);

      if (accepted.isEmpty) {
        // No circle can ever be published to, so a scheduled GNSS receiver
        // buys the user nothing but drain — release it rather than leave it
        // running for a roster that emptied while backgrounded.
        await _cancelRegistration();
        return;
      }

      // One burst, not one schedule per circle: register every eligible circle
      // on the SAME due-time the first time we see it while owning publishing,
      // so a handoff hands them all to one wake instead of scattering them
      // across a wake apiece. Prune first so a left/blocked circle's schedule
      // is dropped. Seeded together is not published together — the loop below
      // still holds each circle a CSPRNG gap behind the last, which is what
      // keeps their whole-second `created_at`s distinct.
      final eligibleKeys = <String>{
        for (final c in accepted) _bgCircleKey(c.nostrGroupId),
      };
      _dueTracker.pruneToKeys(eligibleKeys);
      for (final key in eligibleKeys) {
        _dueTracker.seedIfAbsent(key, timestamp);
      }

      // Select the circles whose own due-time falls inside this cycle's fix
      // horizon, most-overdue first. The horizon (rather than a bare
      // `isDue(key, timestamp)`) is what lets a fix taken
      // [kBackgroundFixLeadTime] AHEAD of a due-time serve the circle it was
      // taken for, and what lets a sibling due shortly after ride the same
      // acquisition instead of paying for another.
      final byKey = <String, Circle>{
        for (final c in accepted) _bgCircleKey(c.nostrGroupId): c,
      };
      // Shuffled in: a burst's circles are due in the same instant, so the
      // tie-break IS the publish order, and a stable one would put the same
      // circle's `created_at` permanently ahead of its sibling's.
      final dueKeys = _dueTracker.dueKeysUpTo(
        _stagger.shuffled(eligibleKeys.toList()),
        timestamp.add(kBackgroundFixHorizon),
      );

      // 7b. Plan the burst BEFORE anything is published, because the
      //     registration below is aimed at what this cycle is about to do.
      //
      //     Two pre-samples, both from the same CSPRNG draws the loop then
      //     uses — drawing them earlier changes no distribution, it only lets
      //     the aim be computed from the schedule that will actually happen:
      //
      //     * the inter-publish GAPS, one per due circle, so the predicted
      //       slots are the real ones (and so the deferral decision is taken
      //       once);
      //     * ONE jittered INTERVAL for the whole burst, so `earliestDue` is
      //       the due-time `nextBurstDue` will record rather than a guess.
      //       Shared, because a sample per circle would pull the roster apart
      //       into a wake apiece again within a few cycles.
      //
      //     The predicted slots are a PREDICTION and nothing else: the loop
      //     re-derives every slot from the actual previous publish start, for
      //     the reason `nextBackgroundPublishSlot` documents — a fixed
      //     schedule collapses the moment one publish overruns its slot, and
      //     compressed gaps are exactly the co-timed `created_at` this whole
      //     mechanism exists to prevent.
      final gaps = _stagger.sampleGaps(dueKeys.length);
      final burstIntervalSecs = _sampleJitteredInterval();
      final planStart = DateTime.now();
      final plannedKeys = <String>{};
      DateTime? plannedSlot;
      DateTime? firstPlannedSlot;
      for (var i = 0; i < dueKeys.length; i++) {
        final key = dueKeys[i];
        final slot = nextBackgroundPublishSlot(
          // Never before `planStart`: an overdue circle publishes when this
          // cycle can, and planning it at its past due-time aims the request
          // for it that much early — down to the platform floor.
          dueAt: _laterOf(_dueTracker.dueAt(key), planStart),
          lastPublishStartedAt: plannedSlot,
          gap: gaps[i],
          phaseStart: planStart,
          // Anchored at the burst's FIRST publish, not at the cycle start.
          // The fix is deliberately delivered [kBackgroundFixLeadTime] BEFORE
          // the due it was taken for, so a deadline measured from here hands
          // the burst only `30 − lead` seconds of its own budget and splits
          // rosters that fit — one wake per interval becoming two, on the
          // plane whose wake count is the whole point.
          deadline: (firstPlannedSlot ?? planStart).add(
            kPublishStaggerMaxSpread,
          ),
        );
        if (slot == null) break;
        plannedSlot = slot;
        firstPlannedSlot ??= slot;
        plannedKeys.add(key);
      }
      // ONE projected due for the whole burst, because that is what the loop
      // will record (`nextBurstDue`): a due per slot would aim the request at
      // a schedule the burst never adopts.
      final plannedDue = firstPlannedSlot == null
          ? null
          : nextBurstDue(
              firstPublishStartedAt: firstPlannedSlot,
              lastPublishStartedAt: plannedSlot!,
              interval: Duration(seconds: burstIntervalSecs),
              minInterval: kLocationPublishMinInterval,
            );

      // The earliest moment ANY circle will want a fix: the projected next
      // due of the ones about to publish, or the standing due-time of the
      // ones that are not (including any this burst's budget defers, which
      // stay overdue and want a fix as soon as the platform will schedule
      // one).
      var earliestDue = _dueTracker.earliestDue(
        eligibleKeys.where((k) => !plannedKeys.contains(k)),
      );
      if (plannedDue != null &&
          (earliestDue == null || plannedDue.isBefore(earliestDue))) {
        earliestDue = plannedDue;
      }

      // 7c. Aim the platform request. BEFORE any publish, and reached even
      //     when nothing is due — a cycle that only registered when it had
      //     something to publish would leave the 72 s watchdog driving
      //     sharing through the one-shot this phase retires, forever.
      if (earliestDue != null) {
        await _ensureRegistration(
          earliestDue: earliestDue,
          // The plan's own instant: a later read takes the planning time off
          // the interval, and at the shortest draw the platform — handed
          // whole milliseconds — then gets 61 999 ms against a 62 s floor.
          now: planStart,
          plannedPublishStart: firstPlannedSlot ?? planStart,
        );
      }

      // Nothing due this cycle → skip the GPS fix + publish entirely, so a
      // cycle with no scheduled circle takes neither a fix nor a wake. What
      // that saves is ESTIMATED, never measured (model E E-A1/E-A2,
      // `docs/POWER_EFFICIENCY_PLAN.md` §6.5a); what is checkable here is that
      // the cycle returns before either one is asked for.
      if (dueKeys.isEmpty) return;

      // 4. Acquire a GPS fix (only now that at least one circle is due).
      //    Normally free: the delivery that drove this cycle is already in the
      //    service's cache, and `getCurrentLocation` serves it while fresh.
      //    With a COLD cache — the first cycle after a handoff, or one the
      //    watchdog started after a silent registration — wait briefly for the
      //    platform's own answer first, then fall through to the one-shot.
      //    Raced against teardown: a one-shot fix is the single longest step in
      //    this cycle and nothing has been encrypted yet, so a stopping service
      //    must not spend its window inside it.
      //
      //    The two markers bracket the only calls that can reach the platform.
      //    Nothing else distinguishes a fix the one-shot answered from one
      //    `getLastKnownPosition()` produced after it ran out — which is the
      //    difference between background sharing surviving indoors and only
      //    looking as if it does, and is what `e2e-fgs-publish` step 8 times
      //    between them. Debug-only: `backgroundCallback` silences
      //    `debugPrint` in release.
      var coldCache = !_locationService!.hasFreshStreamFix();
      if (coldCache) {
        await _awaitFirstDelivery();
        coldCache = !_locationService!.hasFreshStreamFix();
      }
      if (coldCache) {
        debugPrint('[BackgroundTask] cold fix: asking the platform');
      }
      final position = await _unlessShuttingDown(
        _locationService!.getCurrentLocation(),
      );
      if (position == null) return;
      if (coldCache) debugPrint('[BackgroundTask] cold fix: in hand');

      // 8. Encrypt and publish to each DUE circle, one at a time and MORE THAN
      //    A SECOND APART.
      //
      //    Sequential alone is not enough. The engine stamps the outer
      //    kind-445 `created_at` from the inner app event's whole-second
      //    clock, so back-to-back publishes carry a byte-identical
      //    `created_at` — an equality inside the SIGNED event that links two
      //    circles to one device for anyone holding both, including from
      //    different relays or an archive. A burst's circles are due in the
      //    same instant BY DESIGN, so the tracker cannot space them at all —
      //    the pacing below is the entire separation.
      //
      //    Each circle therefore waits until the later of (a) its own due-time
      //    and (b) the pre-drawn CSPRNG gap after the previous publish
      //    STARTED — measured from the ACTUAL start, never from the predicted
      //    slot above, because a fixed schedule compresses the gaps back
      //    together as soon as one publish overruns. The spread is budgeted:
      //    once the next slot would fall past the deadline the loop stops and
      //    leaves the rest due for the next cycle.
      //
      //    Re-check foreground ownership immediately before each
      //    encryptLocation call: the user can resume during any of the
      //    preceding awaits (GPS fix, circle fetch, decorrelation wait). If the
      //    foreground reclaimed ownership, break out rather than advancing an
      //    MLS epoch concurrently.
      var publishCount = 0;
      var publishFailed = false;
      var yieldedToForeground = false;
      final publishPhaseStart = DateTime.now();
      DateTime? lastPublishStartedAt;
      DateTime? firstPublishStartedAt;
      final publishedKeys = <String>[];
      for (var i = 0; i < dueKeys.length; i++) {
        final key = dueKeys[i];
        // A stop that arrives mid-burst must cost the in-flight publish only,
        // not every circle still queued behind it. The existing check below
        // fires only after a decorrelation wait, and a due circle with no wait
        // skips it entirely.
        if (_shuttingDown) break;
        final circle = byKey[key];
        if (circle == null) continue;

        final notBefore = nextBackgroundPublishSlot(
          dueAt: _dueTracker.dueAt(key),
          lastPublishStartedAt: lastPublishStartedAt,
          gap: gaps[i],
          phaseStart: publishPhaseStart,
          // Anchored at the burst's first PUBLISH, for the reason the
          // planning pass above documents.
          deadline: (firstPublishStartedAt ?? publishPhaseStart).add(
            kPublishStaggerMaxSpread,
          ),
        );
        if (notBefore == null) {
          // NOT a failure: a deferred circle stays overdue. One the planning
          // pass deferred as well is already in the aim, at the platform
          // floor; one only this loop deferred — the burst overran the gaps
          // it was planned with — waits for the watchdog's next tick, which
          // finds it due.
          debugPrint(
            '[BackgroundTask] Stagger budget spent — deferring the remaining '
            'due circle(s) to the next cycle.',
          );
          break;
        }
        final wait = notBefore.difference(DateTime.now());
        if (wait > Duration.zero) {
          await _sleepUnlessShuttingDown(wait);
          if (_shuttingDown) break;
        }
        // Re-take the CPU hold after the decorrelation wait and before every
        // publish, so the guarantee is "never held more than
        // kPublishWakeLockTimeout past the LAST acquire" rather than past the
        // start of a burst that may span the whole stagger spread.
        await _wakeLock.acquire();

        // Fix 4: Re-check before each MLS epoch advance. BREAK, never
        // return: everything below the loop is the cycle's own teardown, and
        // the publish pool closed there is the Android presence claim that no
        // socket stays open between publishes.
        if (await BackgroundLocationManager.isForegroundActive()) {
          debugPrint(
            '[BackgroundTask] Foreground reclaimed ownership mid-loop — '
            'aborting remaining circles.',
          );
          // The same stand-down the top-of-cycle gate performs, for the same
          // reason: the UI isolate now holds its own registration, and this
          // one is aimed at a schedule this isolate no longer owns. Breaking
          // without it leaves two live platform requests for up to a whole
          // watchdog period.
          await _yieldToForeground();
          yieldedToForeground = true;
          break;
        }
        // Eligibility, re-read HERE and not only at the roster snapshot above.
        // The snapshot is taken before the GPS acquisition and the whole
        // stagger spread, so a circle the engine flagged Unrecoverable inside
        // either would still be sent to — the one thing `CircleService` says
        // must never happen (Rule 8). The engine's block flag is the only
        // eligibility input that can change under a background cycle: a
        // membership change arrives through the foreground, whose reclaim the
        // check above already stood down for.
        if (_circleService!.isCircleBlocked(circle.mlsGroupId)) {
          debugPrint(
            '[BackgroundTask] Circle blocked mid-burst — skipping its publish.',
          );
          continue;
        }
        final publishStartedAt = DateTime.now();
        lastPublishStartedAt = publishStartedAt;
        firstPublishStartedAt ??= publishStartedAt;

        try {
          final outcome = await _circleManager!.encryptLocation(
            mlsGroupId: circle.mlsGroupId,
            senderPubkeyHex: _pubkeyHex!,
            latitude: position.latitude,
            longitude: position.longitude,
            updateIntervalSecs: BigInt.from(
              kLocationPublishMaxInterval.inSeconds + kTtlNetworkBufferSeconds,
            ),
          );

          // The MLS engine QUEUED this update instead of encrypting it. Nothing
          // reached a relay, so nothing is stamped: `notePublishAcked` stays
          // untouched and the circle is NOT re-armed on a fresh cadence, so the
          // next cycle retries it promptly.
          //
          // This isolate has no Riverpod container, so it cannot call
          // `sharingHealthProvider.recordDeferredSend`. It persists nothing new
          // either — the deferral surfaces on the next FOREGROUND open through
          // Unit D's model, which reads the MISSING publish-ack timestamp for
          // this circle and derives the outage from its age. Adding a second
          // persisted signal here would duplicate evidence the model already
          // has, on an isolate whose clock is independent.
          final deferred = outcome.deferredSend;
          if (deferred != null) {
            debugPrint(
              '[BackgroundTask] send deferred by the MLS engine — '
              'gating=${magnitudeBucket(deferred.unresolvedInputs)}, '
              'repaired=${deferred.repaired}, '
              'stagedCommits=${magnitudeBucket(deferred.commits.length)}',
            );
            await _resolveDeferredCommits(circle, deferred);
            await publishDeferredProposals(
              relayService: _relayService!,
              circle: circle,
              deferred: deferred,
            );
            publishFailed = true;
            continue;
          }
          final encrypted = outcome.sent;
          if (encrypted == null) {
            // Neither arm set: the binding and this call site have drifted.
            // Fail closed for this circle rather than dereference nothing —
            // the same posture `NostrCircleService.encryptLocation` takes.
            debugPrint(
              '[BackgroundTask] encrypt returned an empty outcome — '
              'skipping this circle',
            );
            publishFailed = true;
            continue;
          }

          // The one-shot ladder: one connect and one 5 s per-relay ack
          // window, no retry. This tick's fix is superseded by the next one
          // within [kLocationPublishMaxInterval], so a second attempt buys a
          // stale sample at the price of a second radio wake. That price is
          // ESTIMATED and cannot be ranked against the cycle's other costs:
          // model E prices one background wake at `c` × 0.0208 %/h (E-A2) and
          // carries NO application-processor term at all (E-P3 is UNKNOWN), so
          // nothing in a background cycle can be called its dominant cost
          // (`docs/POWER_EFFICIENCY_PLAN.md` §6.5a). The deferral branch above
          // has already returned, so nothing carrying a `PendingStateRefFfi`
          // reaches this call (Security Rule 13).
          final publishResult = await _relayService!.publishLocationEvent(
            eventJson: encrypted.eventJson,
            relays: encrypted.relays,
          );

          // Delivery liveness for the foreground service's own publishes.
          // This isolate has no Riverpod container, so the persisted stamp is
          // the ONLY channel by which the sharing-health model can learn that
          // background publishing is (or has stopped) working. Recorded only
          // on an affirmative relay ACK — a result no relay accepted delivered
          // nothing, and stamping it would make a dead plane read as healthy.
          if (publishResult.acceptedBy.isNotEmpty) {
            await _circleManager!.notePublishAcked(
              nostrGroupId: circle.nostrGroupId,
              atMs: DateTime.now().millisecondsSinceEpoch,
            );
          }

          // Re-arm the whole burst so far onto ONE due (`nextBurstDue`), off
          // the interval pre-sampled above — the two inputs the registration
          // was aimed with, so the schedule the fix arrives for is the
          // schedule that was recorded. Re-applied after every publish rather
          // than once at the end, because a stop or a foreground reclaim can
          // cut the loop and the circles that DID go out must be left holding
          // what actually happened.
          publishedKeys.add(_bgCircleKey(circle.nostrGroupId));
          _dueTracker.markBurstPublished(
            publishedKeys,
            nextBurstDue(
              firstPublishStartedAt: firstPublishStartedAt,
              lastPublishStartedAt: publishStartedAt,
              interval: Duration(seconds: burstIntervalSecs),
              minInterval: kLocationPublishMinInterval,
            ),
          );
          publishCount++;
        } on Object catch (e) {
          debugPrint(
            '[BackgroundTask] Publish failed for circle: ${e.runtimeType}',
          );
          publishFailed = true;
        }
      }

      // A circle that did not publish is still due, but the registration is
      // aimed at the due-time it WOULD have had. Pull the retry back to the
      // watchdog's own period so a transient relay or engine failure costs one
      // recovery interval rather than a full jittered one.
      //
      // Never after a mid-loop hand-back, though: a failed publish followed by
      // a foreground reclaim would otherwise re-arm the very request the
      // stand-down just released.
      if (publishFailed && !yieldedToForeground) {
        final now = DateTime.now();
        await _ensureRegistration(
          earliestDue: now.add(kBackgroundRepeatInterval),
          now: now,
          plannedPublishStart: now,
        );
      }

      // 9. Fetch peer locations for each accepted circle. Piggybacks on
      //    the wake-up the publish step already paid for: the radio is
      //    awake, the relay WebSocket is open, and the GPS fix is
      //    cached. Without this, the SQLCipher last-known store grows
      //    stale during long backgrounded sessions and the foreground
      //    rehydrates to old data on resume.
      //
      //    Throttled to `kLocationUpdateInterval`: "a circle is due" can fire
      //    more often than the nominal cadence — a deferred circle stays
      //    overdue, and the watchdog re-runs the cycle — but fetching ALL
      //    circles on every such wake would multiply the background relay
      //    round-trips. Gating the fetch on its own ~nominal cadence keeps
      //    background fetch frequency (and battery) at parity with one fetch
      //    per publish interval regardless of how many circles the user is
      //    in.
      //
      //    Receiver-side auto-commit: `fetchMemberLocations` may
      //    publish + finalise an evolution event when MDK
      //    auto-commits a peer's `SelfRemove` proposal. The single-
      //    writer envelope (`_runCycleWithIdleTracking`) covers this
      //    full flow. If that publish gets no ack, the location
      //    service does NOT roll the commit back: Rust recorded the
      //    publish as owed before the commit crossed the FFI
      //    (`owe_removal_publish`) and refuses to discard a peer's
      //    eviction, so the commit stays staged
      //    and a FOREGROUND live-sync open publishes it. The next
      //    cycle does not re-surface it — a probe against the engine
      //    at the pinned MDK rev disproved that (this comment used to
      //    claim it); the durable obligation is the retry, and it is
      //    also what makes an isolate killed mid-publish visible
      //    instead of a circle that silently stopped sharing. We
      //    tolerate the failure here (catch + debugPrint per circle).
      var fetchCount = 0;
      final fetchDue = _lastBackgroundFetchAt == null ||
          timestamp.difference(_lastBackgroundFetchAt!) >=
              kLocationUpdateInterval;
      if (fetchDue && !_shuttingDown && _locationSharingService != null) {
        _lastBackgroundFetchAt = timestamp;
        // The burst above may have spent most of the hold on stagger waits and
        // relay ladders; the fetch is commit-critical work and must not run on
        // the tail of an expiring one.
        //
        // The stop check belongs on the GATE and not just inside the loop,
        // which stands down on the same flag: everything between the two is
        // awaited, so a cycle the drain abandoned would otherwise reach this
        // acquire, take a hold, and fall through to a `finally` that (rightly)
        // no longer releases it.
        await _wakeLock.acquire();
        for (final circle in accepted) {
          if (await BackgroundLocationManager.isForegroundActive()) {
            debugPrint(
              '[BackgroundTask] Foreground reclaimed ownership before fetch '
              '— aborting remaining fetches.',
            );
            await _yieldToForeground();
            break;
          }
          // LAST statement before the fetch, deliberately after the awaited
          // foreground check above: a stop that lands while this iteration is
          // suspended in that check must stop the NEXT fetch from starting, so
          // that the only commit-critical work `onDestroy` can find running is
          // one it can see in [_inFlightCommitCritical].
          if (_shuttingDown) break;
          // The invariant: a `fetchMemberLocations` that has STARTED is never
          // abandoned. It can publish and then confirm a receiver-side
          // auto-commit (a peer's SelfRemove), which is Rule 13 territory —
          // dropping it between `publishEvent` and `confirmPublished` leaves a
          // commit that is neither confirmed nor rolled back while possibly
          // already on a relay. Publishing it under this future is what lets
          // `onDestroy` wait for it WITHOUT a budget, unlike the location
          // publish, which it may abandon.
          try {
            final fetch = _locationSharingService!.fetchMemberLocations(
              circle: circle,
            );
            _inFlightCommitCritical = fetch;
            await fetch;
            fetchCount++;
          } on Object catch (e) {
            debugPrint(
              '[BackgroundTask] Fetch failed for circle: ${e.runtimeType}',
            );
          } finally {
            _inFlightCommitCritical = null;
          }
        }
      }

      // 9b. Close the publish pool. The relay work of this cycle is done, and
      //     nothing else will use the socket before the next fix arrives 62 s
      //     or more from now — so holding it open would keep a NAT binding
      //     alive and a relay able to watch this device's presence between
      //     publishes, which is precisely what the Android copy says does not
      //     happen. The service re-initialises itself lazily, so the next
      //     cycle reconnects without any wiring of its own.
      try {
        await _relayService?.shutdown();
      } on Object catch (e) {
        debugPrint(
          '[BackgroundTask] publish pool close failed: ${e.runtimeType}',
        );
      }

      // 10. Persist the publish timestamp for cross-isolate coordination.
      final now = DateTime.now();
      await BackgroundLocationManager.writeLastPublishTime(now);

      // 11. Periodic prune of expired last-known rows. Hourly cadence
      //     mirrors the foreground `_pruneTimer`; both are idempotent
      //     because `prune_expired_last_known` is a single SQLite
      //     DELETE under a per-instance Mutex<Connection>.
      _cyclesSinceLastPrune++;
      if (_cyclesSinceLastPrune >= _cyclesPerPrune &&
          _circleService != null &&
          !await BackgroundLocationManager.isForegroundActive()) {
        _cyclesSinceLastPrune = 0;
        try {
          final removed = await _circleService!.pruneExpiredLastKnown();
          debugPrint('[BackgroundTask] Pruned $removed expired row(s).');
        } on Object catch (e) {
          debugPrint('[BackgroundTask] Prune failed: ${e.runtimeType}');
        }
        try {
          await _circleService!.pruneProcessedGiftWraps();
        } on Object catch (e) {
          debugPrint(
            '[BackgroundTask] pruneProcessedGiftWraps failed: ${e.runtimeType}',
          );
        }
      }

      // The burst's shared next-publish time was re-armed inline
      // (markBurstPublished) as each due circle published — a cycle-wide
      // reschedule here would also re-arm the circles the budget deferred and
      // the ones whose publish failed, which must both stay overdue.
      debugPrint(
        '[BackgroundTask] Published to ${magnitudeBucket(publishCount)}/'
        '${magnitudeBucket(dueKeys.length)} due circle(s) '
        '(${magnitudeBucket(accepted.length)} eligible), fetched '
        '${magnitudeBucket(fetchCount)}/${magnitudeBucket(accepted.length)} '
        'circle(s).',
      );
    } on Object catch (e) {
      debugPrint('[BackgroundTask] Publish cycle FAILED: ${e.runtimeType}');
      // Per-circle schedules re-arm on the next successful publish; a failed
      // cycle leaves due circles due, so the next watchdog tick retries them.
    } finally {
      // Every exit — the gates, the early returns, a throw — releases. A lock
      // leaked on one of those paths holds the CPU awake until the native
      // timeout on every cycle, which is the opposite of what it is for.
      //
      // ...unless a stop arrived while this cycle was running, in which case
      // the lock is `onDestroy`'s from that moment and this cycle is only a
      // guest on it. The drain ABANDONS a publish past its budget and the
      // ladder keeps running for tens of seconds afterwards, so this
      // `finally` can land in the middle of the teardown — and because the
      // native lock is `setReferenceCounted(false)`, one release here drops
      // the hold `onDestroy` re-took for the unbounded Rule-13 wait, the
      // relay shutdown and the Rule-14 handback. `onDestroy`'s own `finally`
      // is then the single release site, with the native ceiling still the
      // backstop for a process that never reaches it.
      if (!_shuttingDown) await _wakeLock.release();
    }
  }

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

  /// Waits [d], or returns early the moment [onDestroy] starts.
  ///
  /// A decorrelation gap must never become a teardown stall. `onDestroy`
  /// completes [_shutdownSignal] before it awaits the in-flight cycle, so the
  /// worst this costs a stopping service is the publish already under way.
  ///
  /// The losing `Future.delayed` timer is left to expire on its own — it holds
  /// nothing but a timer slot in an isolate that is being torn down anyway,
  /// and cancelling it would need a `Timer` handle this call has no other use
  /// for.
  Future<void> _sleepUnlessShuttingDown(Duration d) async {
    if (d <= Duration.zero || _shuttingDown) return;
    await Future.any<void>(<Future<void>>[
      Future<void>.delayed(d),
      _shutdownSignal.future,
    ]);
  }

  /// Awaits [work], or gives up on it the moment [onDestroy] starts, in which
  /// case the result is `null`.
  ///
  /// For the steps whose own duration is set by something outside this isolate
  /// — a GPS fix, a relay round-trip — and which hold no MLS state while they
  /// run, so abandoning one loses a location sample and nothing else. `stop()`
  /// on the service side is what makes that trade worth taking: the sample was
  /// about to stop being published anyway.
  ///
  /// `Future.any` ignores whatever the loser does afterwards, including an
  /// error, so a late failure cannot surface as an unhandled async error.
  Future<T?> _unlessShuttingDown<T>(Future<T> work) {
    if (_shuttingDown) return Future<T?>.value();
    return Future.any<T?>(<Future<T?>>[
      work,
      _shutdownSignal.future.then((_) => null),
    ]);
  }

  /// Test seam for [_sleepUnlessShuttingDown].
  ///
  /// The cycle around it is reachable through [startWithoutBridgeForTest], but
  /// the cancellability of the wait is exactly the property that keeps a
  /// decorrelation gap from becoming a teardown stall — so it is provable on
  /// its own, without a roster or a fix.
  @visibleForTesting
  Future<void> staggerWaitForTest(Duration d) => _sleepUnlessShuttingDown(d);

  /// Test seam for [_unlessShuttingDown] — same reason as
  /// [staggerWaitForTest]: the steps it wraps (the GPS one-shot) are
  /// bridge/platform-bound, while the abandonment is the property.
  @visibleForTesting
  Future<T?> raceShutdownForTest<T>(Future<T> work) =>
      _unlessShuttingDown(work);

  /// Test seam for the in-flight cycle [onDestroy] drains.
  ///
  /// A bare future stands in for a cycle: "teardown does not wait past the
  /// publish already in flight" is exactly the bound the UI isolate's
  /// `handoverTimeout` is derived from, so it is proven on its own rather
  /// than assumed.
  @visibleForTesting
  set inFlightPublishForTest(Future<void> cycle) => _inFlightPublish = cycle;

  /// The cycle a preceding [onRepeatEvent] started, so a test can await the
  /// real entry point instead of pumping the event queue and hoping.
  @visibleForTesting
  Future<void>? get inFlightPublishForTest => _inFlightPublish;

  /// The per-circle schedule (keyed by hex `nostrGroupId`): what the cycle
  /// seeded, re-armed, or cleared.
  @visibleForTesting
  PerCircleDueTracker get dueTrackerForTest => _dueTracker;

  /// The isolate's own circle service, so a test can flag a circle
  /// Unrecoverable MID-burst — the state the pre-fix roster snapshot could not
  /// see and the pass must therefore re-read.
  @visibleForTesting
  NostrCircleService? get circleServiceForTest => _circleService;

  /// Test seam for [_inFlightCommitCritical]. Same reason as
  /// [inFlightPublishForTest], and the property is the opposite one: this
  /// window must be drained WITHOUT a budget.
  @visibleForTesting
  set inFlightCommitCriticalForTest(Future<void> window) =>
      _inFlightCommitCritical = window;

  /// Test-only override for [kBackgroundTeardownDrainBudget].
  ///
  /// Production uses the real constant; shortening it in a test keeps the
  /// bound-was-enforced case from costing 15 s of wall clock.
  @visibleForTesting
  Duration teardownDrainBudget = kBackgroundTeardownDrainBudget;

  /// Test-only override for [kFirstDeliveryWait] — same reason as
  /// [teardownDrainBudget]: what a test asserts is whether the cycle waits for
  /// the platform's own answer at all, and every cycle that gets none would
  /// otherwise sit out the real 2 s. The production default is the constant,
  /// and `background_location_task_delivery_cycle_test.dart` pins that.
  @visibleForTesting
  Duration firstDeliveryWait = kFirstDeliveryWait;

  /// Test seam for [_ensureSession].
  ///
  /// Reaches `_ensureSession` and `_attemptSessionReclaim` directly, without
  /// the foreground-ownership gate a real cycle puts in front of them. Setting
  /// [_dataDir] here is what lets the guard/backoff/probe machinery run
  /// against the `override*` seams above without a device.
  @visibleForTesting
  Future<bool> ensureSessionForTest({required String dataDir}) {
    _dataDir = dataDir;
    return _ensureSession();
  }

  /// [onStart] past its bridge-bound steps (FFI init, keyring, data directory,
  /// the identity load), which `flutter test` cannot run: adopts an identity
  /// the way step 4 does, then runs the same bring-up. Unlike [onStart] it does
  /// not swallow a failure, so a test sees exactly where bring-up stopped.
  @visibleForTesting
  Future<void> startWithoutBridgeForTest({
    required NostrIdentityManager identityManager,
    required String dataDir,
  }) {
    _identityManager = identityManager;
    if (identityManager.hasIdentity()) {
      _pubkeyHex = identityManager.pubkeyHex();
    }
    return _bringUpSession(dataDir);
  }

  /// Samples a jittered publish interval via the Rust CSPRNG.
  int _sampleJitteredInterval() {
    try {
      return _locationEventService!
          .jitteredPublishIntervalSecs(nominalSecs: _nominalSecsBigInt)
          .toInt();
    } on Object catch (_) {
      // Fallback to nominal on FFI error.
      return kLocationUpdateInterval.inSeconds;
    }
  }

  /// Hex-encodes a `nostrGroupId` for use as a per-circle due-tracker key.
  /// Matches the foreground `_circleKey` / `LocationSharingService._circleKey`
  /// convention (the public `#h` value — never the real MLS group id, Rule 4).
  static String _bgCircleKey(List<int> nostrGroupId) =>
      nostrGroupId.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}
