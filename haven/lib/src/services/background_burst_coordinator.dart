/// iOS background burst receive: one bounded burst per publish tick (P4).
///
/// ## Why this exists
///
/// While backgrounded on iOS with sharing ON, the live-sync engine used to
/// hold a standing subscription and an open socket for the whole background
/// window — a continuous "this pubkey is online" signal to every circle relay,
/// and a 55 s pinger plus periodic re-anchors keeping the radio awake between
/// publishes. Both are paid for by a device that has nothing to render.
///
/// This coordinator replaces that with one bounded burst per publish tick:
///
/// 1. `openBackgroundBurstWithin()` — re-anchor every REQ at its persisted
///    cursor, or start a session into the burst where it finds none.
/// 2. `waitBacklogSettled()` — let the stored replay land, so a peer commit
///    received here is APPLIED before this burst encrypts (the location then
///    goes out at the current epoch). Where the Bluetooth mesh is wired its
///    drive is started here, behind the receive, and nothing waits for it.
/// 3. one GPS fix behind the access gate, then one publish per circle that is
///    due AND still eligible when the pass reaches it, CSPRNG-staggered so two
///    circles never share a whole-second `created_at`.
/// 4. any DUE `KeyPackage` / relay-list maintenance, folded onto the warm
///    publish pool — by direct call, never a provider invalidation, and never
///    the subscription-health tick (a paused engine holds no REQ, so the tick
///    would inspect nothing).
/// 5. `settleBeforePause()` → `pauseSubscriptions()` → drain any commit-
///    critical publish still on the shared publish pool → shut that pool.
///
/// A burst whose receive FAILED sends no relay anything; with the mesh on it
/// runs step 3 for the mesh alone, skips step 4 and closes (plan §7.7 R1).
///
/// Between bursts there is no standing REQ and no socket: presence is revealed
/// only at the instants the device publishes, which every circle relay already
/// learns from the kind-445 itself. A pause that drives no burst — nothing
/// eligible to publish, or a publish still inside the overlap guard — runs
/// step 5 on its own ([BackgroundBurstCoordinator.closeIdle]), so "between
/// bursts" covers the gap before the first one too.
///
/// ## Shape: an FFI-free core with injected collaborators
///
/// Every collaborator is an interface or a function — the engine, the
/// publisher, the maintenance fold, the publish-pool shutdown, the stagger,
/// the clock, and the consent read. Nothing here calls the FFI or touches
/// Riverpod, so the whole sequence is executable in a unit test with fakes,
/// which is the only way the properties below can be proved at all: they are
/// all about ORDER and about what happens on the failure paths.
///
/// There is deliberately **no `ref.watch`, and no `ref` at all** (pinned by
/// `test/lints/background_burst_coordinator_lint_test.dart`). A burst runs
/// while the app is paused, where frames are off — a widget rebuild cannot
/// run, so anything that depended on one would silently never happen. The
/// thin runner that builds this reads its collaborators once, with `ref.read`.
///
/// ## No `Timer` of its own
///
/// Ticks arrive from `LocationPublishSchedulerNotifier`, one per circle on its
/// own jittered cadence. A coordinator-owned timer would be a second wake
/// source in the one phase whose entire purpose is to remove wake sources, and
/// it would buy nothing: this whole design already depends on Dart timers
/// firing while the app is backgrounded, which they do for exactly as long as
/// the CoreLocation keep-alive holds the process EXECUTABLE. Once iOS suspends
/// the process nothing here runs — a timer of our own included — and the next
/// burst is whatever the schedulers fire when the process is let run again.
///
/// ## Wiring (owned by the lifecycle packet, P4-5)
///
/// The iOS + background-sharing-on pause branch of `MapShell` constructs one
/// coordinator and installs it as the scheduler's tick sink:
///
/// ```dart
/// final health = ref.read(sharingHealthProvider.notifier);
/// final coordinator = BackgroundBurstCoordinator(
///   engine: ref.read(subscriptionServiceProvider),
///   publisher: ref.read(locationPublishSchedulerProvider.notifier),
///   maintenance: ref.read(maintenanceSchedulerProvider.notifier),
///   stagger: ref.read(locationPublishStaggerProvider),
///   shutdownPublishPool: shutdownPublishPool,
///   pendingCommitCritical: () => publishPool?.inFlightDrives,
///   burstEnabled: () => ref.read(backgroundSharingProvider),
///   foregrounded: () => foregroundOwnsEngine,
///   onOpenOutcome: (failures) => failures == 0
///       ? health.recordRelaySubscriptionRestored()
///       : health.recordRelaySubscriptionLost(),
/// );
/// final scheduler = ref.read(locationPublishSchedulerProvider.notifier);
/// scheduler.setTickSink(coordinator);
/// ```
///
/// On resume it clears the sink (`setTickSink(null)`), which restores the
/// direct foreground publish, re-anchors the engine, and flips the
/// `foregrounded` read to true (see below).
///
/// ## Two invariants the caller must keep
///
/// **Every pause must be followed by a burst open or a foreground re-anchor.**
/// The engine's health model FREEZES its verdict while paused — a session that
/// pauses and never resumes stays at its last honest value and hides a fault
/// that develops afterwards. Every burst here ends in a pause and every burst
/// begins with an open, so the coordinator keeps its half; the resume half is
/// `MapShell`'s. The one deliberate exception is opting OUT of background
/// sharing mid-burst: the burst still pauses (leaving no socket, which is the
/// point of opting out) and no burst follows, because there is nothing left to
/// promise.
///
/// **`foregrounded` must become true the moment the foreground takes the tick
/// sink back, and false again when the sink is re-installed.** It is what stops
/// a burst that was in flight at resume from pausing an engine the foreground
/// now owns — `burstEnabled` cannot: it reads the background-sharing consent,
/// which is still true in the foreground. A pause landing there is invisible
/// and unrecoverable within the window: `ensureRunning` sees `isRunning`, the
/// health model's `refresh()` early-returns while paused, and the banner holds
/// at its last verdict while the device receives nothing. Unwired, the read
/// defaults to false and every burst tears down exactly as it did before this
/// signal existed.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import 'package:haven/src/constants/location.dart' show kOneShotLocationTimeout;
import 'package:haven/src/rust/api.dart'
    show BacklogOutcomeFfi, BurstOpenFfi, LiveLifecycleFfi;
import 'package:haven/src/services/circle_service.dart' show Circle;
import 'package:haven/src/services/publish_stagger.dart';
import 'package:haven/src/services/subscription_service.dart';

// ---------------------------------------------------------------------------
// Burst budget
// ---------------------------------------------------------------------------

/// Connect wait inside a burst open (`SUBSCRIBE_CONNECT_WAIT`, Rust).
const Duration kBurstConnectBudget = Duration(seconds: 5);

/// The engine's own cap on the backlog wait (`BURST_BACKLOG_WAIT_SECS`).
const Duration kBurstBacklogBudget = Duration(seconds: 5);

/// The burst's ONE publish window: the `timeLimit` every one-shot GPS fix runs
/// under ([kOneShotLocationTimeout]).
///
/// Paid once per burst however many circles are due, and normally near zero —
/// the fix is served from the location stream's cache. The identity and
/// preference reads in front of it are local.
const Duration kBurstWindowBudget = kOneShotLocationTimeout;

/// Worst case for ONE circle's publish: `CONNECTION_TIMEOUT` (5 s) +
/// `LOCATION_ACK_WINDOW` (5 s) of radio.
///
/// The WHOLE ladder, not one attempt of it — `LOCATION_PUBLISH_ATTEMPTS` is
/// exactly 1 (`haven-core/src/relay/manager.rs`), because the next tick
/// supersedes a location that missed. The 3-attempt ≈49 s ladder belongs to
/// the COMMIT path, and nothing on the publish pass takes it.
const Duration kBurstPublishBudget = Duration(seconds: 10);

/// Worst-case decorrelation stagger a burst of [circles] publishes can spend.
///
/// Deliberately NOT [PublishStagger.maxSpreadFor], which prices every gap at
/// the burst's FINAL size. A burst GROWS — a tick that lands mid-pass joins it
/// — so the k-th gap was sampled while only k circles were pending, at
/// `maxGapFor(k)`, and that ceiling only shrinks as the burst grows. Summing
/// the per-gap ceilings is the spread a joining burst can actually reach:
/// ≈60 s at 11 circles, where `maxSpreadFor` claims 30.
Duration burstStaggerSpread(int circles, PublishStagger stagger) {
  var spread = Duration.zero;
  for (var k = 2; k <= circles; k++) {
    spread += stagger.maxGapFor(k);
  }
  return spread;
}

/// Worst-case wall time of the burst's OWN links for [circles] circles: the
/// open, the backlog wait, the single publish window, and the publish pass
/// with its stagger. [BackgroundBurstCoordinator] measures exactly those links
/// against it and reports an overrun.
///
/// ## What it excludes, and why no bound on a whole burst exists
///
/// The maintenance fold and the teardown are outside both this sum and the
/// elapsed time measured against it, because neither is boundable:
///
/// * a due fold publishes through the COMMIT ladder (≈49 s per task) and a
///   generation's first `KeyPackage` tick waits up to 60 s for the login
///   publish to settle first;
/// * `pauseSubscriptions` ends in the engine's `wait_publishes_drained()`,
///   UNCAPPED by design — bounding it would let the process suspend with a
///   commit between SEND and OK (Security Rule 13).
///
/// So a burst can legitimately outlast the publish chain's watchdog
/// (`kPublishLinkTimeout`, 3 min), and nothing here may be read as a promise
/// that it cannot: the watchdog's own contract is to report and never cancel.
Duration burstBound(int circles, PublishStagger stagger) =>
    kBurstConnectBudget +
    kBurstBacklogBudget +
    kBurstWindowBudget +
    kBurstPublishBudget * circles +
    burstStaggerSpread(circles, stagger);

// ---------------------------------------------------------------------------
// Collaborators
// ---------------------------------------------------------------------------

/// One GPS fix plus the identity it is published under, shared by every circle
/// in a burst.
///
/// Taken once per burst rather than once per circle: the fix is served from
/// the location stream's cache anyway, and sharing it makes the burst's cost
/// independent of how many circles are due.
@immutable
class BurstFix {
  /// Creates a burst fix.
  const BurstFix({
    required this.senderPubkeyHex,
    required this.latitude,
    required this.longitude,
  });

  /// The publishing identity's public key, hex-encoded.
  final String senderPubkeyHex;

  /// Latitude of the fix, in degrees.
  final double latitude;

  /// Longitude of the fix, in degrees.
  final double longitude;
}

/// The publish half of a burst.
///
/// Implemented by `LocationPublishSchedulerNotifier`, which already owns the
/// access gate, the publish call and the sharing-health recording — a second
/// implementation of any of those would be a second thing to keep in sync.
abstract class BurstPublisher {
  /// The circle currently eligible to publish under [circleKey], or `null` if
  /// it stopped being eligible since the tick that queued it.
  ///
  /// Read once per publish pass, exactly as the foreground tick re-reads its
  /// own roster before firing. A circle can be left, removed, flagged
  /// Unrecoverable or superseded between the tick that made it due and the
  /// publish that would send it, and a blocked circle must never be sent to
  /// (`CircleService`: "The UI MUST block send/mutate for a blocked circle").
  /// It is also the only thing that drops a circle out of a burst's due set
  /// once it has stopped being publishable.
  Circle? eligibleCircle(String circleKey);

  /// Opens the burst's shared publish window for [circles]: the identity and
  /// location-disclosure gate, then ONE GPS fix.
  ///
  /// Returns `null` when the window did not open, in which case the burst
  /// publishes nothing. [circles] is passed so the publisher can attribute a
  /// FAILED window to the circles that were waiting on it — without it, a
  /// dead GPS would reach the sharing-health model only as silence, minutes
  /// later. A pass that seals for the Bluetooth mesh alone passes none: its
  /// failed window is no failed relay publish.
  ///
  /// Never throws.
  Future<BurstFix?> openBurstPublishWindow(Iterable<Circle> circles);

  /// Publishes [circle] at [fix], recording the outcome. Never throws.
  ///
  /// [received] is the burst's word that its own relay receive was answered
  /// to the end before this send: only then may what fellow members sent by
  /// the Bluetooth mesh be passed on to the relays behind it. With
  /// [meshOnly] the fix is sealed for the mesh alone and no relay is asked.
  Future<void> publishInBurst(
    Circle circle,
    BurstFix fix, {
    required bool received,
    required bool meshOnly,
  });
}

/// The Bluetooth mesh as a burst uses it. A build without the mesh answers
/// off and drives nothing.
abstract class BurstMesh {
  /// Whether the mesh is on, read afresh. Never throws.
  Future<bool> isOn();

  /// Takes in what the mesh received. Calls no relay; never throws.
  Future<void> drive();
}

/// The maintenance a burst may fold onto its warm publish pool.
///
/// Deliberately only the two tasks that PUBLISH the user's own reachability
/// (`KeyPackage`, relay list). The subscription-health tick is absent by
/// construction: it probes the live subscription model, and a burst folds it
/// in at the one moment there is nothing to probe.
abstract class BurstMaintenance {
  /// Runs a `KeyPackage` maintenance tick if one is due at [now]. Never throws.
  Future<void> runKeyPackageIfDue(DateTime now);

  /// Runs a relay-list maintenance tick if one is due at [now]. Never throws.
  Future<void> runRelayListIfDue(DateTime now);

  /// Carries on every leave this device asked for, claiming no foreground.
  /// Never throws.
  Future<void> carryOnLeaves();
}

/// What became of a burst's relay receive.
enum _Receive {
  /// Answered to the end, with the burst still owning the wake.
  completed,

  /// Not answered to the end, by no choice of the user's.
  failed,

  /// The foreground took the burst back, or the consent was withdrawn.
  stopped,
}

/// How many further rounds of driver entries one teardown adopts after the
/// one it found in flight.
///
/// Three, because a drive can run to the core's own budget, so a teardown
/// that adopts four is already long, and the one producer a BACKGROUNDED
/// process still runs on its own — the motion trigger — is capped at one
/// publish per `kLocationPublishOverlapGuard` (60 s). The cap is what the
/// number rests on, not the trigger being the registry's only writer: the
/// polls and the maintenance ticks drive too, and they are foreground paths
/// whose timers the pause cancelled before any of this runs. A fifth round
/// therefore says the registry is answering with something other than the
/// work in flight — the runaway this cap stops, not a real backlog.
const int _maxAdoptedRounds = 3;

/// Starts a session directly into the burst asking for it.
typedef BurstStart = Future<void> Function();

/// The default `prepareStartIntoBurst`: no session may be started, so a burst
/// that finds none publishes nothing.
Future<BurstStart?> _startsNone(Duration budget) async => null;

/// The default `pendingCommitCritical` read: nothing is tracked, so the
/// teardown drains nothing and shuts the pool exactly as it did before the
/// drain existed.
Future<void>? _noCommitCriticalWork() => null;

/// The default `foregrounded` read: a coordinator nobody hands back is
/// backgrounded, so every burst runs its full teardown.
///
/// Both defaults fail SAFE in the same direction — an unwired caller gets the
/// behaviour it had — so wiring either one late is a missing improvement
/// rather than a new failure.
bool _stillBackgrounded() => false;

/// Where the per-circle publish scheduler sends a tick when something other
/// than a direct publish should handle it.
abstract class BurstSink {
  /// Handles one circle's due publish.
  ///
  /// [circleKey] is the scheduler's own key for [circle] — passed rather than
  /// re-derived so the sink and the scheduler can never disagree about circle
  /// identity.
  ///
  /// The returned future completes when the burst carrying this circle
  /// completes, so the scheduler's serialization chain still measures real
  /// work.
  Future<void> onTick({required String circleKey, required Circle circle});

  /// The burst in flight, or `null` when none is.
  ///
  /// A consent withdrawal that lands while a burst runs must let the burst
  /// reach its own settle-and-pause rather than pausing underneath it; with
  /// nothing in flight the caller pauses the engine directly.
  Future<void>? get runningBurst;
}

// ---------------------------------------------------------------------------
// Coordinator
// ---------------------------------------------------------------------------

/// Serializes background publish ticks into bounded open→publish→close bursts.
class BackgroundBurstCoordinator implements BurstSink {
  /// Creates a coordinator over its injected collaborators.
  BackgroundBurstCoordinator({
    required SubscriptionService engine,
    required BurstPublisher publisher,
    required BurstMaintenance maintenance,
    required PublishStagger stagger,
    required Future<void> Function() shutdownPublishPool,
    required bool Function() burstEnabled,
    required void Function(int consecutiveFailures) onOpenOutcome,
    Future<void>? Function() pendingCommitCritical = _noCommitCriticalWork,
    bool Function() foregrounded = _stillBackgrounded,
    Future<BurstStart?> Function(Duration budget) prepareStartIntoBurst =
        _startsNone,
    Future<bool> Function()? receiveWithoutSession,
    BurstMesh? mesh,
    DateTime Function() now = DateTime.now,
  }) : _engine = engine,
       _publisher = publisher,
       _maintenance = maintenance,
       _stagger = stagger,
       _shutdownPublishPool = shutdownPublishPool,
       _burstEnabled = burstEnabled,
       _onOpenOutcome = onOpenOutcome,
       _pendingCommitCritical = pendingCommitCritical,
       _foregrounded = foregrounded,
       _prepareStartIntoBurst = prepareStartIntoBurst,
       _receiveWithoutSession = receiveWithoutSession,
       _mesh = mesh,
       _now = now;

  final SubscriptionService _engine;
  final BurstPublisher _publisher;
  final BurstMaintenance _maintenance;
  final PublishStagger _stagger;
  final Future<void> Function() _shutdownPublishPool;
  final bool Function() _burstEnabled;

  /// The driver entries currently on the SHARED publish pool, or `null` when
  /// there are none — read by the teardown, and drained UNBOUNDED before the
  /// pool is shut.
  ///
  /// A burst awaits its own publishes, so its own work is drained by
  /// structure. The pool is not the burst's, though: while backgrounded on
  /// iOS the motion trigger, a leave's carry-on and a drive run over the same
  /// pool, unawaited by this coordinator, and `shutdownPublishPool` reaches
  /// `RelayManager::shutdown`, i.e. `client.disconnect()` with no drain of any
  /// kind (the engine's own `settleBeforePause` / `pauseSubscriptions` drain a
  /// DIFFERENT pool). The core forks nothing under a disconnect — a commit
  /// whose ack it never saw stays recorded and awaiting — but the drive is cut
  /// short and its sends wait for the next wake
  /// (`NostrRelayService.inFlightDrives`).
  ///
  /// The foreground service's teardown differs on two entries, a location's
  /// seal and its send: it reads its pool's `inFlightNonLocationDrives` after
  /// its bounded drain and awaits it with no bound, leaving those two inside
  /// that bound (`background_location_task.dart`).
  ///
  /// The contract for whoever supplies it: return the future while the work is
  /// genuinely in flight and `null` once it has completed — the shape
  /// `inFlightDrives` has, where a `finally` clears it.
  final Future<void>? Function() _pendingCommitCritical;

  /// Whether the FOREGROUND has taken the engine back, in which case this
  /// coordinator must not touch it: no burst opens, and a burst already in
  /// flight stops its teardown where it stands.
  ///
  /// Deliberately separate from [_burstEnabled], which reads the
  /// background-sharing consent and is still true in the foreground. Without
  /// this read a burst still running at resume settles, pauses and shuts the
  /// pool while the app is on screen, and nothing recovers it: `ensureRunning`
  /// reads `isRunning` (true across a pause), `_fullRestart` declines while
  /// paused, and the health model's `refresh()` early-returns while paused, so
  /// the banner holds at "healthy" while the device receives nothing until the
  /// next background→foreground cycle.
  final bool Function() _foregrounded;

  /// Reports the receive plane after EVERY burst open: how many opens in a row
  /// have now failed, `0` when this one succeeded. Never throws.
  ///
  /// A failed open leaves the burst holding no subscription at all — it still
  /// publishes (that rides the other pool) and ingests nothing. One is a
  /// transient. A RUN of them is the silent failure this phase can produce:
  /// the device publishes every 72-168 s while peers' commits pile up, and
  /// once more than the engine's retained past epochs have accumulated its
  /// kind-445s are undecryptable to every peer — relay acks still coming back
  /// on this side, a frozen marker on theirs. So the run is evidence, and it
  /// is reported to the sharing-health model the way a refused GPS window is,
  /// instead of dying in a `debugPrint`.
  final void Function(int consecutiveFailures) _onOpenOutcome;

  final DateTime Function() _now;

  /// Readies a start into the burst — the circles and inbox relays a
  /// foreground start takes, bounded by `budget` — or answers `null` where
  /// none may be started: no live session is wanted, or the shell is gone.
  final Future<BurstStart?> Function(Duration budget) _prepareStartIntoBurst;

  /// Set only in a configuration with no live plane at all (the live-sync-off
  /// build): the receive a burst runs in place of opening a session, which
  /// answers whether it completed. `null` where a live plane exists.
  final Future<bool> Function()? _receiveWithoutSession;

  /// The Bluetooth mesh, or `null` where none is wired: every burst then
  /// runs exactly as it did before the mesh existed.
  final BurstMesh? _mesh;

  /// Circle keys waiting to be published, in the order their ticks arrived.
  ///
  /// Keys only: the circle itself is re-read from the publisher's roster at
  /// fire time, so a burst structurally cannot publish to a circle the
  /// scheduler has since dropped.
  ///
  /// A running burst drains this; a tick arriving mid-publish adds to it and
  /// is picked up by the same burst (see [onTick]).
  final Set<String> _due = {};

  /// Circle keys already encrypted by the RUNNING burst. Empty between bursts.
  final Set<String> _encrypted = {};

  /// The single serialization chain. Exactly one burst runs at a time, so two
  /// bursts can never hold two sockets open — or two engine re-anchors race
  /// each other's REQ set.
  Future<void> _chain = Future<void>.value();

  /// Whether a burst is executing right now.
  ///
  /// Stays true THROUGH the teardown, not merely to the end of the publish
  /// pass: the opt-out edge reads [runningBurst] to decide whether to pause
  /// the engine itself, and clearing this any earlier would let it pause and
  /// shut the pool while the burst is still inside its own settle — a
  /// disconnect with a commit between SEND and OK (Security Rule 13).
  bool _bursting = false;

  /// Whether the running burst can still take on another circle: true from the
  /// burst's start until its publish pass ends.
  bool _joinable = false;

  /// Burst opens that have failed in a row, `0` after any open that succeeded.
  int _openFailures = 0;

  @override
  Future<void>? get runningBurst => _bursting ? _chain : null;

  /// Queues [circleKey] and returns the burst that will publish it.
  ///
  /// [circle] is deliberately not kept: it is a snapshot taken at tick time,
  /// and a burst publishes seconds to a minute later. The pass re-reads the
  /// scheduler's roster instead — see [_pendingCircles].
  @override
  Future<void> onTick({required String circleKey, required Circle circle}) {
    _due.add(circleKey);
    if (_joinable && !_encrypted.contains(circleKey)) {
      // A burst is running and has not encrypted this circle yet: it joins
      // that burst rather than opening a second socket seconds later.
      return _chain;
    }
    // Either nothing is running, or this circle was ALREADY published by the
    // running burst — its next publish is genuinely due, so it is deferred to
    // a burst queued behind the current one rather than published twice in
    // the same one.
    return _chain = _chain.then((_) => _runBurst()).catchError((Object e) {
      // One failed burst must not poison the chain for every later tick.
      debugPrint('[BackgroundBurst] burst failed: ${e.runtimeType}');
    });
  }

  /// Runs a burst's teardown with no burst in front of it.
  ///
  /// The pause branch drives a burst only when a circle is eligible to publish
  /// AND the last publish is outside `kLocationPublishOverlapGuard`. Both
  /// exits used to leave the FOREGROUND's standing REQ, its socket and the
  /// crate's 55 s pinger up — until the first per-circle tick after a recent
  /// publish (mean ≈60 s, on the dominant interaction: open, glance,
  /// background), and for the WHOLE background window with nothing eligible,
  /// where no tick is ever coming. This is what makes every pause on that
  /// branch end in a teardown: the one the burst it drove runs, or this one.
  ///
  /// On the same chain and under the same [_bursting] flag as a burst, so it
  /// cannot interleave with one, a mid-pause opt-out waits for it through
  /// [runningBurst] instead of pausing underneath it, and a resume orders
  /// behind it. It reuses [_closeBurst] rather than open-coding the three
  /// links, which is what carries the per-link handback re-reads (a resume
  /// 300 ms later must stop this, not race it) and the unbounded drive
  /// drain.
  Future<void> closeIdle() {
    return _chain = _chain
        .then((_) async {
          _bursting = true;
          try {
            await _closeBurst();
          } finally {
            _bursting = false;
          }
        })
        .catchError((Object e) {
          // Same reason [onTick] has one, and a stronger one: this is launched
          // with `unawaited` from a lifecycle callback, so an escape is an
          // unhandled async error, and a REJECTED chain is inherited by every
          // later tick and every later close — none of which would run their
          // body again for the rest of the mount.
          debugPrint('[BackgroundBurst] idle close failed: ${e.runtimeType}');
        });
  }

  /// Runs one burst over whatever is currently due. Never throws.
  Future<void> _runBurst() async {
    if (_due.isEmpty) return; // drained by the burst this one queued behind
    if (_foregrounded()) {
      // Queued while backgrounded, reached after the resume took the sink
      // back. Opening now would replace the foreground's anchor with a burst
      // one — which carries no inbox REQ, so gift-wrapped invitations would
      // stop arriving until the next re-anchor. The ticks are not lost: the
      // foreground publishes them directly, and the resume publishes at once.
      _due.clear();
      debugPrint('[BackgroundBurst] queued burst dropped: the foreground owns '
          'the engine');
      return;
    }
    if (!_burstEnabled()) {
      // Consent was withdrawn between this burst being queued and running.
      // Nothing is opened, so there is nothing to pause.
      _due.clear();
      return;
    }
    // The drives of this burst end with its own links (decision: the burst
    // path has no OS deadline of its own while the keep-alive session is
    // armed; the settle and the pause's Rule-13 drain come after those links
    // and are bounded by neither).
    final budget = burstBound(_due.length, _stagger);
    final startedAt = _now();
    // Running from here, before any start: a resume landing while the burst
    // starts a session orders behind it ([runningBurst]) instead of racing
    // the start for the engine.
    _bursting = true;
    _joinable = true;
    try {
      try {
        // How this burst receives before it seals (receive-before-seal, both
        // configurations). Where no live plane exists at all, through the
        // catch-up, and only once it completed (decision 244); where a live
        // plane exists but finds no session — read from the typed lifecycle,
        // never from an error — by starting one into the burst (decision
        // 190). A burst that cannot receive sends no relay anything; one with
        // a live plane says so to the health model as a failed open, one
        // without says nothing (it holds no subscription to lose). With the
        // Bluetooth mesh on, one whose receive FAILED seals for the mesh
        // alone ([_sealedForMeshAlone]).
        var startedIntoBurst = false;
        // Whether THIS burst's relay receive was answered to the end, by its
        // typed outcome: what a publish may claim of it.
        var received = false;
        final receiveWithoutSession = _receiveWithoutSession;
        if (receiveWithoutSession != null) {
          final receive = await _receivedWithoutSession(receiveWithoutSession);
          if (receive != _Receive.completed) {
            if (!await _sealedForMeshAlone(receive)) {
              debugPrint('[BackgroundBurst] receive not completed: nothing '
                  'published');
            }
            return;
          }
          received = true;
        } else {
          switch (_engine.lifecycle()) {
            case LiveLifecycleFfi.noSession || LiveLifecycleFfi.stopped:
              final start = await _startedIntoBurst(budget);
              if (start != _Receive.completed) {
                await _endWithoutSession(start);
                return;
              }
              startedIntoBurst = true;
            case LiveLifecycleFfi.launched ||
                LiveLifecycleFfi.foreground ||
                LiveLifecycleFfi.burst ||
                LiveLifecycleFfi.paused:
              break;
          }
        }
        // A failed open is NOT swallowed by the engine wrapper, deliberately:
        // a burst open has no redundancy, and a caller that went on to wait
        // for a backlog nobody requested would spend the entire wait budget
        // learning nothing. So skip the wait — but keep publishing, which
        // rides the separate publish pool and is the promise the user can see.
        // The location may then be encrypted one epoch behind; peers decrypt
        // it from past-epoch keys and the next burst converges. What a failed
        // open must NOT be is invisible: the run of them goes to the health
        // model (see [_onOpenOutcome]).
        var opened = startedIntoBurst;
        if (receiveWithoutSession == null) {
          try {
            // A session that ended after the lifecycle read answers the open
            // with the typed no-session, and a start into the burst takes its
            // place as for a session found missing — within what the open
            // left of the one budget.
            if (!opened) {
              switch (await _engine.openBackgroundBurstWithin(budget)) {
                case BurstOpenFfi.opened:
                  break;
                case BurstOpenFfi.noSession:
                  final left = budget - _now().difference(startedAt);
                  final start = await _startedIntoBurst(
                    left.isNegative ? Duration.zero : left,
                  );
                  if (start != _Receive.completed) {
                    await _endWithoutSession(start);
                    return;
                  }
              }
            }
            opened = true;
            _openFailures = 0;
          } on Object catch (e) {
            _openFailures++;
            // Rule 8: the type and a count. The FFI message is remote text.
            debugPrint('[BackgroundBurst] open failed ($_openFailures in a '
                'row): ${e.runtimeType}');
          }
          _onOpenOutcome(_openFailures);
        }
        if (opened && _burstEnabled()) {
          switch (await _engine.waitBacklogSettled()) {
            case BacklogOutcomeFfi.settled:
              received = true;
            case BacklogOutcomeFfi.timedOut:
              // A report, not a failure: an endpoint stayed silent, so this
              // burst makes no promise about its epoch. Publish anyway —
              // exactly what the foreground does with a slow REQ, and the
              // alternative is a location gap for a relay problem.
              debugPrint('[BackgroundBurst] backlog wait timed out — '
                  'publishing at the epoch we have');
          }
        }
        _driveMesh();
        await _publishPass(received: received);
      } finally {
        // ONE assignment, covering the ordinary exit AND every throw from
        // the links above. Latched true, every later tick joins this
        // already-completed chain, queues nothing, and background sharing
        // stops for the rest of the window with no error anywhere.
        _joinable = false;
        _reportOverBudget(startedAt);
      }
      if (_burstEnabled()) await _foldMaintenance();
    } finally {
      // Nested, because the flag must be cleared even when the teardown throws
      // — its handback and drive reads are caller-supplied closures.
      // Latched true, `runningBurst` answers non-null for the life of the
      // coordinator, and every later resume takes the burst-in-flight bypass:
      // a pool reconnect and a 96 h `#p` gift-wrap replay per glance, which is
      // exactly the cost the re-anchor throttle exists to bound.
      try {
        await _closeBurst();
      } finally {
        _bursting = false;
      }
    }
  }

  /// Runs [receive], and answers what became of it: completed while the
  /// burst still owns the wake, stopped by the foreground or a withdrawn
  /// consent, or failed. Never throws.
  Future<_Receive> _receivedWithoutSession(
    Future<bool> Function() receive,
  ) async {
    var completed = false;
    try {
      completed = await receive();
    } on Object catch (e) {
      debugPrint('[BackgroundBurst] receive failed: ${e.runtimeType}');
    }
    if (_foregrounded() || !_burstEnabled()) return _Receive.stopped;
    return completed ? _Receive.completed : _Receive.failed;
  }

  /// Starts a session into this burst where none runs (decision 190). Not
  /// started is one of two things: the start failed, which is a failed open
  /// told to the health model, or the burst was stopped — the foreground or
  /// the consent took it back meanwhile, or the foreground took the engine
  /// back while the start ran (its re-anchor, ordered behind this burst,
  /// takes the session).
  Future<_Receive> _startedIntoBurst(Duration budget) async {
    if (!await _startIntoBurst(budget)) {
      if (_foregrounded() || !_burstEnabled()) return _Receive.stopped;
      _openFailures++;
      _onOpenOutcome(_openFailures);
      return _Receive.failed;
    }
    return _foregrounded() ? _Receive.stopped : _Receive.completed;
  }

  /// Ends a burst no session could be started for.
  Future<void> _endWithoutSession(_Receive start) async {
    if (!await _sealedForMeshAlone(start) && start == _Receive.failed) {
      debugPrint('[BackgroundBurst] no session: nothing published');
    }
  }

  /// Ends a burst whose relay receive did not complete, and answers whether
  /// it sealed for the Bluetooth mesh alone (plan §7.7 R1): only one whose
  /// receive FAILED, with the mesh on and the burst still owning the wake —
  /// so a phone no relay answers still shares by radio. No relay is asked
  /// anything, and the maintenance fold is skipped as for any burst that
  /// could not receive. Every other such burst publishes nothing: one the
  /// foreground or a withdrawn consent stopped, and any with the mesh off.
  ///
  /// The cost is the plan's: the fix is sealed at the last epoch this phone
  /// knows, so a member removed by a commit it could not fetch can read it
  /// within radio range until the next receive completes.
  Future<bool> _sealedForMeshAlone(_Receive receive) async {
    final mesh = _mesh;
    if (receive == _Receive.failed &&
        mesh != null &&
        await mesh.isOn() &&
        !_foregrounded() &&
        _burstEnabled()) {
      _driveMesh();
      await _publishPass(received: false, meshOnly: true);
      return true;
    }
    _due.clear();
    return false;
  }

  /// Starts the mesh's own drive and waits for none of it: it rides the
  /// burst behind the relay receive — what it takes in may be passed on only
  /// behind a receive that completed — and the burst's relay links neither
  /// wait on it nor fail with it.
  void _driveMesh() => unawaited(_mesh?.drive().catchError((Object _) {}));

  /// Starts a session into this burst, if one may be started and the burst
  /// still owns the wake. Never throws.
  Future<bool> _startIntoBurst(Duration budget) async {
    try {
      final start = await _prepareStartIntoBurst(budget);
      if (start == null || _foregrounded() || !_burstEnabled()) return false;
      await start();
      return true;
    } on Object catch (e) {
      // Rule 8: the type alone. The FFI message is remote text.
      debugPrint('[BackgroundBurst] start into burst failed: ${e.runtimeType}');
      return false;
    }
  }

  /// Reports a burst whose OWN links ran past [burstBound].
  ///
  /// Measured over exactly the links that bound covers — up to and including
  /// the publish pass, and never through the fold or the teardown, whose
  /// commit ladder and uncapped Rule-13 drain would make the report cry wolf
  /// on the two things a burst is supposed to do slowly.
  void _reportOverBudget(DateTime startedAt) {
    final elapsed = _now().difference(startedAt);
    final bound = burstBound(_encrypted.length, _stagger);
    if (elapsed > bound) {
      // The FACT only. `debugPrint` is not compiled out in release, and one
      // burst now encrypts the whole eligible roster, so the count is the
      // roster size — as is the bound, which is monotone in it. Either number
      // would put "how many circles this user is in" in the device log every
      // time a burst runs long.
      debugPrint(
        '[BackgroundBurst] burst over budget: ${elapsed.inSeconds}s',
      );
    }
  }

  /// Publishes every due circle once, sharing one GPS fix, with the CSPRNG
  /// stagger between consecutive publishes.
  ///
  /// Re-reads the due set after each pass so a tick that arrived mid-publish
  /// joins this burst. Terminates because every published circle enters
  /// [_encrypted] and is filtered out of the next pass.
  Future<void> _publishPass({
    required bool received,
    bool meshOnly = false,
  }) async {
    BurstFix? fix;
    while (_burstEnabled()) {
      final pending = _pendingCircles();
      if (pending.isEmpty) return;
      // The window opens on the first pass only: one fix per burst, and a
      // window that refused once will refuse the joiners too.
      fix ??= await _publisher.openBurstPublishWindow(
        meshOnly ? const [] : pending.map((e) => e.circle),
      );
      if (fix == null) {
        // The window refuses for a reason that belongs to the DEVICE, never to
        // a circle: no identity yet, the disclosure not accepted, location
        // permission revoked, or a one-shot fix that timed out. Every circle
        // still queued would be refused the same way a second later, so
        // leaving them due is what turned ONE refusal into one whole burst per
        // due circle — a cold connect, a REQ set replaying 96 h of `#p` gift
        // wraps and a pool cycle each, publishing nothing, on the branch this
        // phase exists to keep quiet.
        //
        // Dropping them loses at most one cadence and hides nothing: the
        // refusal was attributed to every waiting circle by
        // `openBurstPublishWindow` before it returned, so the sharing-health
        // model already has it, and each circle's own next tick re-queues it
        // (a transient refusal recovers there; a durable one has nothing to
        // publish anyway). Same disposition as a withdrawn consent in
        // [_runBurst], for the same reason: nothing queued can go out.
        _due.clear();
        return;
      }
      final total = _encrypted.length + pending.length;
      for (final entry in _stagger.shuffled(pending)) {
        if (_encrypted.isNotEmpty) {
          // No gap before the burst's FIRST publish — freshness is not spent
          // on a separation nobody can observe.
          await Future<void>.delayed(
            _stagger.sampleGap(totalPublishes: total),
          );
        }
        // Consent is re-read immediately before the encrypt, not once per
        // pass: the previous publish and the stagger gap are each seconds
        // long, and a withdrawal inside either must stop the publish that
        // follows it rather than the one after that.
        if (!_burstEnabled()) return;
        // A seal for the mesh alone is made at an epoch no receive vouched
        // for: none is made once the foreground, which receives first, has
        // the engine back.
        if (meshOnly && _foregrounded()) return;
        // ELIGIBILITY, re-read at the same point and for the same reason. The
        // pass reads [_pendingCircles] once per round, so without this a
        // circle the engine flags Unrecoverable mid-pass is still sent to for
        // the rest of the round — the one thing `CircleService` says must
        // never happen (Rule 8). The foreground tick makes exactly this
        // re-read, after exactly this wait.
        final circle = _publisher.eligibleCircle(entry.key);
        if (circle == null) {
          _due.remove(entry.key);
          continue;
        }
        // Marked BEFORE the publish: a tick for this circle arriving while it
        // is being encrypted must queue a later burst, not slip into this
        // pass's next round and publish twice.
        _encrypted.add(entry.key);
        _due.remove(entry.key);
        await _publisher.publishInBurst(
          circle,
          fix,
          received: received,
          meshOnly: meshOnly,
        );
      }
    }
  }

  /// The due circles this pass may publish, re-read from the scheduler's
  /// roster and dropped from [_due] when they are no longer eligible.
  ///
  /// Entering [_due] is a decision taken at tick time; publishing happens up
  /// to a minute later, and the burst had no other way out for a circle that
  /// was blocked, orphaned or left in between — it would keep sending to it,
  /// and keep it queued for every later burst.
  List<({String key, Circle circle})> _pendingCircles() {
    final pending = <({String key, Circle circle})>[];
    for (final key in _due.toList()) {
      if (_encrypted.contains(key)) continue;
      final circle = _publisher.eligibleCircle(key);
      if (circle == null) {
        _due.remove(key);
        continue;
      }
      pending.add((key: key, circle: circle));
    }
    return pending;
  }

  /// Folds the maintenance tasks that are DUE onto the burst's warm publish
  /// pool, by direct call.
  ///
  /// A provider invalidation would be the wrong mechanism here for the same
  /// reason `ref.watch` is: it schedules work for a rebuild that a paused app
  /// never performs.
  ///
  /// Each link is guarded separately, for the reason [_closeBurst]'s are: the
  /// two tasks are independent publishes of the user's own reachability, and a
  /// `KeyPackage` relay that throws must not cost the relay list its fold —
  /// which no one would see, because the next fold is 30 minutes away.
  Future<void> _foldMaintenance() async {
    final now = _now();
    try {
      await _maintenance.runKeyPackageIfDue(now);
    } on Object catch (e) {
      debugPrint('[BackgroundBurst] KeyPackage fold failed: ${e.runtimeType}');
    }
    try {
      await _maintenance.runRelayListIfDue(now);
    } on Object catch (e) {
      debugPrint('[BackgroundBurst] relay-list fold failed: ${e.runtimeType}');
    }
    try {
      await _maintenance.carryOnLeaves();
    } on Object catch (e) {
      debugPrint('[BackgroundBurst] leave carry-on failed: ${e.runtimeType}');
    }
  }

  /// Settles, pauses, drains and shuts the publish pool — the links that must
  /// run on EVERY exit from a burst, including a throw and a cooperative
  /// cancellation.
  ///
  /// Each link is guarded separately: a throw from one must not skip the next,
  /// or the burst would end with the sockets it opened still open for the
  /// whole gap to the next tick. None of them may be given a `.timeout(` —
  /// a Dart timeout does not cancel the Rust future, it only lets this
  /// coordinator return while a commit is still between SEND and OK (Security
  /// Rule 13). Pinned by `test/lints/commit_critical_no_timeout_test.dart`.
  ///
  /// The teardown stops wherever the foreground takes the engine back
  /// ([_foregrounded]), re-read before each link rather than once at the top:
  /// the settle can wait for as long as the engine's uncapped publish drain
  /// takes, and a resume inside it must not be followed by the pause it was
  /// waiting for. The publish PASS is deliberately not gated the same way — a
  /// burst that stopped mid-pass would silently skip circles whose locations
  /// are due, where stopping the teardown only leaves the foreground owning
  /// what it already owns.
  ///
  /// The handback read itself is the one thing here that is deliberately NOT
  /// guarded: a caller whose signal cannot be read has no safe answer — one
  /// disposition pauses an engine the foreground owns, the other leaves the
  /// sockets up — so it propagates to the chain guards in [onTick] and
  /// [closeIdle], which are what keep it from latching [_bursting] or
  /// poisoning the chain.
  Future<void> _closeBurst() async {
    try {
      if (_handedBack('settle')) return;
      try {
        await _engine.settleBeforePause();
      } on Object catch (e) {
        debugPrint('[BackgroundBurst] settle failed: ${e.runtimeType}');
      }
      if (_handedBack('pause')) return;
      try {
        await _engine.pauseSubscriptions();
      } on Object catch (e) {
        debugPrint('[BackgroundBurst] pause failed: ${e.runtimeType}');
      }
      if (_handedBack('drive drain')) return;
      await _drainCommitCritical();
      // Read again: the drain can run as long as a drive does.
      if (_handedBack('pool shutdown')) return;
      try {
        await _shutdownPublishPool();
      } on Object catch (e) {
        debugPrint('[BackgroundBurst] pool shutdown failed: ${e.runtimeType}');
      }
    } finally {
      _encrypted.clear();
    }
  }

  /// Whether the foreground has taken the engine back, so the teardown stops
  /// before [link].
  bool _handedBack(String link) {
    if (!_foregrounded()) return false;
    debugPrint('[BackgroundBurst] teardown stopped before the $link: the '
        'foreground owns the engine now');
    return true;
  }

  /// Awaits the driver entries the shared pool is carrying, if any, before
  /// that pool is disconnected.
  ///
  /// UNBOUNDED, and it must stay that way: bounding it is the same defect as
  /// not having it, because a `.timeout(` cancels nothing — it just returns
  /// here and lets the shutdown cut the socket under a drive that is between
  /// a send and its ack. Normally a no-op: [_pendingCommitCritical] is null on
  /// the overwhelming majority of teardowns.
  ///
  /// Re-read after each drain, because the motion trigger keeps running while
  /// backgrounded and can START a drive inside one — the shutdown that
  /// follows would cut that one instead. Rounds after the first are capped
  /// ([_maxAdoptedRounds]), and each awaits only the drives in flight when it
  /// reads, so a drive that joins during the last adopted round is not
  /// awaited and may be cut; the motion trigger's 60 s spacing
  /// (`kLocationPublishOverlapGuard`) keeps its drives from landing in round
  /// after round. Without the cap a registry that manufactures a future on
  /// every read (an `() async =>` closure where the contract asks for a
  /// field) spins here forever: no burst ever completes again, both pools
  /// stay open, and background sharing ends for the process with nothing in
  /// the log but this line repeating.
  Future<void> _drainCommitCritical() async {
    for (var round = 0; round <= _maxAdoptedRounds; round++) {
      final Future<void>? commitCritical;
      try {
        commitCritical = _pendingCommitCritical();
      } on Object catch (e) {
        // The one link of the teardown whose read is a caller-supplied closure
        // rather than an engine call — one that reads a provider throws once
        // its container is disposed. Unguarded it escaped the whole teardown,
        // so the pool this method exists to protect was left OPEN. A read
        // that cannot answer has no drive to offer, so the shutdown that
        // follows is the right disposition.
        debugPrint('[BackgroundBurst] drive read failed: ${e.runtimeType}');
        return;
      }
      if (commitCritical == null) return;
      debugPrint('[BackgroundBurst] draining driver entries before the pool '
          'shutdown');
      try {
        await commitCritical;
      } on Object catch (e) {
        // Reaching its own conclusion is the point; the drive that owns it
        // logs the cause. Rule 8: the type only.
        debugPrint('[BackgroundBurst] drive drain failed: ${e.runtimeType}');
      }
    }
  }
}
