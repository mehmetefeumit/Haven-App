/// Foreground location-publish scheduler: one jittered burst per interval.
///
/// ## Why one tick publishes every circle
///
/// One CSPRNG-jittered tick publishes a kind-445 to every eligible circle, so
/// the device wakes its radio ~30 times an hour however many circles the user
/// is in. It used to run one INDEPENDENT [JitteredScheduler] per circle, on the
/// theory that per-circle rhythms stop a relay from linking a device's circles
/// by co-timing. That theory never held where it mattered: the live-sync
/// engine's multiplexed `#h` subscription already tells any shared relay which
/// circles this one socket watches, and every circle's publish leaves over one
/// publish socket — while the cost, one radio wake per circle per interval, was
/// paid on every device in every circle count.
///
/// The cost of coalescing is real and is not hidden: circles held on DISJOINT
/// relay sets now emit the SAME inter-burst rhythm, so anyone holding two of
/// your circles' relay archives can tell they belong to the same phone.
///
/// ## What the stagger still buys, and why it is not the schedule
///
/// The defence that survives is [PublishStagger], and it is a different
/// defence: the engine binds the outer kind-445 `created_at` to the inner app
/// event's WHOLE-SECOND timestamp, so two circles encrypted inside one second
/// carry a byte-identical `created_at` INSIDE the signed event. That equality
/// travels to every relay in each circle's routing set and into any archive, so
/// it is transferable evidence rather than a weak hint. A burst therefore
/// publishes its circles in a CSPRNG permutation with a gap between consecutive
/// encrypts drawn from `[kPublishStaggerMinGap, PublishStagger.maxGapFor(n)]`,
/// which keeps every stamp in a different whole second — and keeps no circle
/// permanently at the front of the burst.
///
/// The ceiling is priced per burst, so the sampled range is 2-9 s only up to
/// four circles and narrows to 2-3.333 s at [kMaxCirclesPerAccount], the
/// largest burst a bounded roster can produce. Every stamp still lands in its
/// own whole second (the 2 s floor is what guarantees that), but how MANY
/// distinct deltas an archive reader sees falls from eight (`{2…9}`) to three
/// (`{2,3,4}` — the alphabet is the whole-second delta, so it runs one past the
/// millisecond ceiling) — see `PublishStagger`'s own header for what that does
/// and does not buy.
///
/// Per-circle freshness is unchanged (the tick samples the same `[72 s, 168 s]`
/// interval each circle used to sample for itself), and the burst opens ONE
/// publish window — identity, disclosure gate and GPS fix — that every circle
/// in it publishes from, so a burst costs one fix rather than one per circle.
/// That is not only battery: a per-circle fix puts an acquisition INSIDE the
/// stagger, and a slow first acquisition followed by a cache-warm second one
/// subtracts from the gap that separates the two `created_at` stamps.
///
/// ## What one burst does not promise
///
/// At most [kMaxCirclesPerBurst] circles publish per tick — the largest burst
/// whose spread still leaves the disclosed propagation margin inside the
/// kind-445 retention. A larger roster rotates: the tail of this burst leads
/// the next one. How LONG a deferred circle waits is a LADDER, not "two
/// sampled intervals": `_takeBurstSlice` is strict round-robin, so a circle is
/// served once every `ceil(N ÷ 11)` bursts — two intervals only up to 22
/// circles, three to 33, four or more from 34.
///
/// **No production roster reaches that rotation.** [kMaxCirclesPerAccount] (10)
/// refuses the eleventh circle at creation and at accept, one under the burst
/// cap, so `_takeBurstSlice` always takes the whole roster and the ladder above
/// is unreachable. It stays described — and the rotation stays correct —
/// because lifting the bound re-opens it exactly as written.
///
/// A circle's TURN comes back within one generation, and a turn is a
/// SELECTION, not a publish: the rotation advances when the tick FIRES, ahead
/// of the chain, the window and the sink. A slice therefore loses its turn
/// without publishing when the window refuses it (no identity, the disclosure
/// not accepted, a fix that timed out), when the app pauses under it, and when
/// the iOS coordinator drops a queued burst (a resume took the engine back,
/// consent was withdrawn, the window refused). The health model is told — a
/// refused window is attributed to every circle waiting on it — the queue is
/// not, so the circle waits its whole period over again: one more burst at
/// `N ≤ 11`, which puts its gap at up to 336 s against the 228 s kind-445
/// retention, and another `ceil(N ÷ 11)` past the cap.
///
/// The two paths that used to rewind the queue on every phone are closed here
/// rather than recorded as starvation. `_rotation` now survives
/// `stopScheduling`/`startScheduling`, so a backgrounding resumes the queue
/// instead of rewinding it, and it survives an emission that reports nothing
/// eligible — `circlesProvider` degrades ANY roster-read failure to `[]` and is
/// invalidated from sixteen call sites, so an empty emission is at least as
/// often a transient FFI/keyring error as a real departure. Rebuilding the
/// queue after one is not a re-phase either: `getVisibleCircles` orders by
/// `updated_at DESC`, so a rebuild rewinds to the SAME head and re-serves the
/// same first slice, starving the tail deterministically.
///
/// What DOES rewind the queue is `build` — a fresh container or the invalidate
/// in `IdentityNotifier.deleteIdentity` — and a process restart, which does not
/// persist it. Both re-serve the roster's leading slice, so a circle behind it
/// gets that session's publish from the deliberately UNCAPPED one-shot burst
/// (`locationPublisherProvider`) rather than from this ladder — as far as that
/// burst reaches. It fires on cold start, on motion, on accept/create and on a
/// resume more than 30 s after the last one, because `MapShell`'s resume
/// debounce sits ABOVE its invalidate. At a bounded roster the leading slice IS
/// the roster, so a rewind re-serves all of it and there is no tail to cover;
/// the two ways that cover used to be incomplete — a one-shot spread outlasting
/// `kLocationPublishOverlapGuard` from 21 circles, and a tick folding into a
/// running iOS burst (`BackgroundBurstCoordinator._joinable`) so one pass
/// carries two slices — both need `N ≥ 12` and are out of reach.
///
/// What all of that would cost at twelve circles and up is stated on
/// [kMaxCirclesPerBurst]; what keeps it hypothetical is
/// [kMaxCirclesPerAccount], enforced where the roster grows rather than here.
///
/// ## Relationship to `locationPublisherProvider`
///
/// This notifier owns only the RECURRING burst. The one-shot "publish to every
/// circle now" burst (`locationPublisherProvider`) handles cold-start,
/// app-resume, motion, and the accept/create UI; it is staggered the same way
/// and for the same reason. A one-shot that overlaps a recurring burst can
/// publish the same circle twice within a short window; that is benign — a
/// kind-25442 application message never advances the MLS epoch, and every
/// publish is serialized through the engine's session mutex. The FIFO chain
/// here plus that mutex uphold Rule 14 (single writer).
///
/// ## Lifecycle
///
/// Modeled on [MaintenanceSchedulerNotifier]: a monotonic generation fences
/// stale ticks across an `invalidate`+re-read (Riverpod reuses the instance),
/// timers are cancelled on [Ref.onDispose] and on the explicit invalidate in
/// `IdentityNotifier.deleteIdentity`. Unlike maintenance, publishing must PAUSE
/// while the app is backgrounded so the background isolate is the sole writer
/// (Rule 14): [stopScheduling]/[startScheduling] are driven by `MapShell`'s
/// lifecycle handlers.
library;

import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:haven/src/constants/location.dart';
import 'package:haven/src/providers/circles_provider.dart';
import 'package:haven/src/providers/identity_provider.dart';
import 'package:haven/src/providers/service_providers.dart';
import 'package:haven/src/providers/sharing_health_provider.dart';
import 'package:haven/src/rust/api.dart';
import 'package:haven/src/services/background_burst_coordinator.dart';
import 'package:haven/src/services/circle_service.dart';
import 'package:haven/src/services/jittered_scheduler.dart';
import 'package:haven/src/services/location_sharing_service.dart';
import 'package:haven/src/services/publish_stagger.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Circles eligible for outbound location publishing: accepted, not a
/// pre-cutover orphan (no live MLS group to encrypt against), and not flagged
/// Unrecoverable by the engine (Rule 8 — no send/mutate for a blocked circle).
///
/// Single source of truth shared by the foreground per-circle scheduler and
/// (duplicated by value, since the background isolate has no Riverpod
/// container) the background publish cycle, so the two planes can never diverge
/// on eligibility.
List<Circle> filterPublishEligibleCircles(
  List<Circle> circles,
  CircleService circleService,
) {
  return circles
      .where((c) => c.membershipStatus == MembershipStatus.accepted)
      .where((c) => !c.isLegacyOrphaned)
      .where((c) => !circleService.isCircleBlocked(c.mlsGroupId))
      .toList();
}

/// Injectable jitter sampler: given a nominal interval in seconds, returns a
/// CSPRNG-jittered interval in seconds. Production wraps the Rust
/// `compute_jittered_publish_interval_secs` (OsRng) via
/// `LocationEventService.jitteredPublishIntervalSecs`; tests override with a
/// deterministic sequence.
final locationPublishJitterSamplerProvider =
    Provider<int Function(int nominalSecs)>((ref) {
  final service = LocationEventService();
  return (nominalSecs) {
    try {
      return service
          .jitteredPublishIntervalSecs(nominalSecs: BigInt.from(nominalSecs))
          .toInt();
    } on Object catch (_) {
      // Fall back to the nominal interval on any FFI error — location sharing
      // must stay live rather than silently halting.
      return nominalSecs;
    }
  };
});

/// Hex-encodes a `nostrGroupId` for use as a per-circle scheduler key.
///
/// Delegates to [sharingCircleKey] rather than re-implementing it: the same key
/// now also indexes the sharing-health model, and two copies of one encoder in
/// one file is exactly how the scheduler's keys and the health model's keys
/// would drift apart.
String _circleKey(List<int> nostrGroupId) => sharingCircleKey(nostrGroupId);

/// Ceiling on a single chained tick before the chain moves on without it.
///
/// A FIFO chain has one structural failure mode: a link that never completes
/// is not an error a `catchError` can absorb, it is a permanent stall. Every
/// later tick — for EVERY circle — queues behind it, and only
/// [LocationPublishSchedulerNotifier.build] resets the chain, so a single hung
/// await ends location sharing for the rest of the process, silently. One
/// route in was a backgrounded iOS permission prompt that iOS defers and
/// geolocator never resolves; that specific route is closed at the source in
/// `GeolocatorLocationService`, but the fragility is the chain's, not that
/// call site's, so it is bounded here too.
///
/// 3 minutes is chosen to be unreachable by a slow-but-honest publish and
/// still bounded: the composed internal ceilings are the 30 s one-shot GPS
/// `timeLimit` plus the Rust relay publisher's ~49 s worst case (3 attempts ×
/// (`CONNECTION_TIMEOUT` + `DEFAULT_TIMEOUT`) + 2 backoffs,
/// `haven-core/src/relay/manager.rs`), i.e. ≈79 s — so this leaves better than
/// 2× headroom, while still recovering within about one publish cadence.
///
/// It is NOT a ceiling a background burst is held to. A burst's own links fit
/// inside it for small circle counts ([burstBound]), but the maintenance fold
/// it carries and the uncapped Rule-13 drain its pause ends in are both
/// unbounded on purpose, so a perfectly healthy burst can outlast this. That
/// costs a log line and nothing else — see `_dispatchTick`.
///
/// Letting the abandoned link run on does not weaken Rule 14. The
/// single-writer guarantee is the engine's `tokio::sync::Mutex<
/// AccountDeviceSession>`, which every `encrypt_location` funnels through
/// (documented at `rust_builder/src/api.rs`'s `encryptLocation`); this chain
/// is the belt on top of those suspenders, and a stall long enough to trip
/// this cap is overwhelmingly in the GPS/permission stage, before the engine
/// is touched at all.
const Duration kPublishLinkTimeout = Duration(minutes: 3);

/// Owns the foreground session's single [JitteredScheduler] and the roster its
/// burst publishes.
class LocationPublishSchedulerNotifier extends Notifier<void>
    implements BurstPublisher {
  /// The one armed wake of this plane, or `null` while paused or with nothing
  /// eligible to publish. One, not one per circle: that is the whole of P5's
  /// battery claim, and a second one would double this plane's wake count.
  JitteredScheduler? _scheduler;

  final Map<String, Circle> _circles = {};

  /// The order circles are entitled to a burst slot in, least-recently-served
  /// first. A burst takes the head and moves it to the back, so a roster
  /// larger than [kMaxCirclesPerBurst] rotates rather than letting the CSPRNG
  /// burst order strand the same circle tick after tick. Deterministic on
  /// purpose: fairness is the one part of the selection that must NOT be a
  /// draw.
  ///
  /// Outlives a pause and an empty roster emission, and is reset only by
  /// [build] — anything shorter-lived rewinds it to the same head and re-serves
  /// the same first slice (see the library header). Every key here is a key of
  /// [_circles] whenever [_circles] is non-empty (`a departed circle loses its
  /// place in the queue`); an empty roster is the one state where the queue
  /// outlives its circles, and it holds no armed tick.
  final List<String> _rotation = [];

  /// Serializes every publish onto one FIFO chain so two circles can never run
  /// `encryptLocation` concurrently (Rule 14 — belt-and-suspenders on top of
  /// the engine's own session mutex).
  Future<void> _publishChain = Future<void>.value();

  Duration _publishLinkTimeout = kPublishLinkTimeout;

  /// Where a due tick goes instead of publishing directly.
  ///
  /// `null` — the foreground default — publishes the circle here and now.
  /// While backgrounded on iOS the lifecycle wiring installs a
  /// [BackgroundBurstCoordinator], and each tick becomes one bounded
  /// open→ingest→publish→fold→close burst instead.
  BurstSink? _tickSink;

  /// When the chain last STARTED a publish, so [_pacedPublish] can hold the
  /// next one until more than a second has passed. `null` until the first
  /// publish of this generation.
  DateTime? _lastChainPublishAt;

  bool _disposed = false;

  /// Whether recurring publishing is active. Set false while the app is
  /// backgrounded so the background isolate is the sole writer.
  bool _active = true;

  /// Monotonic lifecycle counter (see [MaintenanceSchedulerNotifier]). A stale
  /// tick from a superseded generation must never publish or re-arm.
  int _generation = 0;

  @override
  void build() {
    _cancelScheduling();
    // The ONE place the service queue is discarded: a rebuild is a fresh
    // container or a deleted identity, whose circles' service history is not
    // this generation's. A pause is not — see [_rotation].
    _rotation.clear();
    _disposed = false;
    _active = true;
    _publishChain = Future<void>.value();
    _lastChainPublishAt = null;
    final generation = ++_generation;

    ref
      ..onDispose(() {
        _disposed = true;
        _cancelScheduling();
      })
      // React to circle-set changes: fireImmediately seeds from the current
      // roster; every later emission replaces it, leaving the armed cadence
      // alone so a roster change never re-phases the burst.
      ..listen<AsyncValue<List<Circle>>>(circlesProvider, (_, next) {
        next.whenData((circles) => _syncCircles(circles, generation));
      }, fireImmediately: true);
  }

  bool _isCurrent(int generation) => !_disposed && generation == _generation;

  void _cancelScheduling() {
    _scheduler?.cancel();
    _scheduler = null;
    _circles.clear();
  }

  void _syncCircles(List<Circle> circles, int generation) {
    if (!_isCurrent(generation)) return;
    if (!_active) {
      // Paused (backgrounded): keep no live foreground timers.
      _cancelScheduling();
      return;
    }
    final circleService = ref.read(circleServiceProvider);
    final eligible = filterPublishEligibleCircles(circles, circleService);
    // Replaced wholesale: this roster is the burst's target set AND the answer
    // [eligibleCircle] gives a burst re-reading eligibility at fire time, so a
    // circle that dropped out (left / blocked / orphaned / removed) has to
    // leave it in the same step it stops qualifying.
    _circles
      ..clear()
      ..addAll({for (final c in eligible) _circleKey(c.nostrGroupId): c});

    if (_circles.isEmpty) {
      // Nothing to publish: hold no timer at all rather than wake to find that
      // out. A circle arriving later re-arms through this same listener.
      //
      // [_rotation] is deliberately left standing. An emission of nothing
      // eligible is as often a transient roster-read failure as a real
      // departure (`circlesProvider` degrades every failure to `[]`), and
      // reconciling against it would empty the queue and let the next healthy
      // emission rebuild it from the roster's own order — the same head, the
      // same first slice, the tail starved. Stale keys cannot be published:
      // there is no armed timer here, and the next non-empty emission prunes
      // them below.
      //
      // What it still costs, because the queue is the only part this repairs:
      // the disarm is unconditional, so the next healthy emission builds a NEW
      // [JitteredScheduler] and samples a fresh 72-168 s — a transient read
      // failure spends up to one whole interval of freshness. Backgrounded on
      // iOS it can spend the rest of the window: every `circlesProvider`
      // invalidation reachable there rides an inbound peer event (live-sync's
      // `onGroupUpdated` / `onInvitationReceived`), so the re-arm waits for a
      // peer to publish something.
      _scheduler?.cancel();
      _scheduler = null;
      return;
    }
    // Survivors keep their place in the queue — a roster change must not
    // re-phase WHOSE turn it is any more than it re-phases the cadence — and
    // a new circle joins at the back.
    final known = _rotation.toSet();
    _rotation
      ..retainWhere(_circles.containsKey)
      ..addAll(_circles.keys.where((key) => !known.contains(key)));

    // An unrelated roster change must never re-phase the burst — restarting the
    // scheduler here would let a chatty circle list pull the cadence in.
    _scheduler ??= JitteredScheduler(
      nominal: kLocationUpdateInterval,
      sampleIntervalSecs: ref.read(locationPublishJitterSamplerProvider),
      onTick: () => _onCircleTick(generation),
    )..start();
  }

  /// The circles this tick may publish: the head of [_rotation] capped at
  /// [kMaxCirclesPerBurst], moved to the back so whatever this burst defers
  /// leads the next one.
  List<String> _takeBurstSlice() {
    final take = min(_rotation.length, kMaxCirclesPerBurst);
    final slice = _rotation.sublist(0, take);
    _rotation
      ..removeRange(0, take)
      ..addAll(slice);
    return slice;
  }

  void _onCircleTick(int generation) {
    if (!_isCurrent(generation) || !_active) return;
    // A LOOKUP, not `_circles[key]!`. The queue outlives an emptied roster on
    // purpose (see [_rotation]), so the two key sets are equal only while the
    // roster is non-empty — and a `!` would make any divergence permanent
    // rather than one thin burst: `JitteredScheduler._fire` swallows what
    // `onTick` throws and re-arms, so every later tick would throw too, with
    // nothing published, no failed publish recorded, and the sharing banner
    // healthy until its silence threshold.
    final burst = <_BurstTarget>[
      for (final key in _takeBurstSlice())
        if (_circles[key] case final circle?) (key: key, circle: circle),
    ];
    // The BURST is what may not be empty, never the roster: [_publishBurst]
    // opens ONE window — an identity read, a preference read and a fix with a
    // 30 s budget — ahead of its first publish, and none of that may be spent
    // on zero circles. An empty rotation reaches here having advanced nothing,
    // so returning costs no circle its turn.
    if (burst.isEmpty) return;
    // Enqueue onto the single serialization chain. catchError keeps one failed
    // publish from poisoning the chain for later bursts, and the timeout keeps
    // one HUNG publish from poisoning it forever (see [kPublishLinkTimeout] —
    // an unfinished future raises no error, so catchError alone cannot see it).
    //
    // The timeout is constructed INSIDE the `then`, so its clock starts when
    // the link begins rather than when it is enqueued; starting it at enqueue
    // time would make queued links expire for the sin of waiting their turn.
    _publishChain = _publishChain
        .then((_) => _dispatchBurst(burst, generation))
        .catchError((Object _) {});
  }

  /// Runs one due tick over the whole eligible roster: the engine's background
  /// burst when a sink is installed, the paced direct publish otherwise.
  ///
  /// The bound on the burst branch is a WATCHDOG, not a cancellation.
  /// `Future.timeout` does not cancel the future it wraps, so a burst that
  /// runs long keeps running and still reaches its own settle, pause and
  /// socket close. All the timeout does is let this chain move on and report
  /// the overrun — the only safe shape here, because cutting a burst short
  /// would leave the engine live with standing REQs for the rest of the
  /// background window, or a commit between SEND and OK (Security Rule 13).
  ///
  /// A HEALTHY burst CAN trip it, and that is not a fault. Two of a burst's
  /// links are unbounded on purpose — a due maintenance fold (the commit
  /// ladder, plus up to a minute for a generation's first `KeyPackage` tick)
  /// and the pause's Rule-13 publish drain — so [burstBound] bounds the
  /// burst's own links only and no honest bound on a whole burst exists. A
  /// report costs a log line and nothing else: moving on cannot start a second
  /// burst, because the coordinator serializes them on its own chain and the
  /// tick that follows a reported burst joins or queues behind it.
  Future<void> _dispatchBurst(List<_BurstTarget> burst, int generation) {
    final sink = _tickSink;
    if (sink == null) return _publishBurst(burst, generation);
    // Every circle is handed over BEFORE the first await, so they all reach the
    // coordinator's due set while it is still empty and one burst carries them
    // — the joins it is built for. The ticks that queue a burst of their own
    // find the set already drained and return without opening a socket.
    final handovers = <Future<void>>[
      for (final target in burst)
        sink.onTick(circleKey: target.key, circle: target.circle),
    ];
    return Future.wait(handovers).then<void>((_) {}).timeout(
      _publishLinkTimeout,
      onTimeout: () => debugPrint(
        '[LocationPublishScheduler] background burst exceeded '
        '${_publishLinkTimeout.inSeconds}s — reported, not cancelled: the '
        'burst still owns its own settle, pause and socket close',
      ),
    );
  }

  /// Publishes [burst] in a CSPRNG permutation, holding each circle a sampled
  /// gap behind the previous one, all from ONE publish window.
  ///
  /// Sequential and paced rather than concurrent: the gaps ARE the defence (see
  /// [PublishStagger]), and a `Future.wait` here would put every circle inside
  /// one whole-second `created_at` by construction. The gaps are drawn up front
  /// so every one of them is priced for the burst's real size, which is what
  /// keeps the spread inside its budget.
  ///
  /// The window is opened once, ahead of the pacing, so nothing variable sits
  /// between the wait and the encrypt. Opening one PER CIRCLE puts an identity
  /// read, a preference read and a GPS acquisition inside every gap, and the
  /// separation the archive reader sees is then
  /// `max(gap, window_i + publish_i) + window_i+1 − window_i` — a slow first
  /// acquisition followed by a cache-warm second one subtracts the gap out of
  /// the answer entirely.
  Future<void> _publishBurst(List<_BurstTarget> burst, int generation) async {
    final stagger = ref.read(locationPublishStaggerProvider);
    final order = stagger.shuffled(burst);
    final gaps = stagger.sampleGaps(order.length);
    if (_lastChainPublishAt != null && gaps.isNotEmpty) {
      // [PublishStagger.sampleGaps] leaves index 0 unwaited because nothing
      // inside THIS burst precedes it — but `_lastChainPublishAt` is
      // chain-global, and a tick that queued behind a slow burst starts one
      // microtask after that burst's last publish. Without a gap here those
      // two circles share a whole-second `created_at`, which is the leak
      // itself and not a hint of it.
      gaps[0] = stagger.sampleGap(totalPublishes: order.length);
    }
    final fix = await _openWindowAttributed(
      [for (final target in order) target.circle],
      generation,
    );
    if (fix == null) return;
    for (var i = 0; i < order.length; i++) {
      if (!_isCurrent(generation) || !_active) return;
      await _pacedPublish(order[i].key, generation, gaps[i], fix);
    }
  }

  /// Holds the link until [gap] has passed since the chain's previous publish,
  /// then runs it under the per-link timeout.
  ///
  /// The wait is measured from the previous publish's ACTUAL start, not from a
  /// pre-computed slot: a schedule of fixed slots collapses the moment one
  /// publish overruns, because the next circle's slot has already passed and it
  /// fires arbitrarily close behind. The running measurement cannot be
  /// compressed that way, so the >1 s separation survives a slow relay, a slow
  /// encrypt or a stalled fix.
  ///
  /// The wait sits OUTSIDE [_publishLinkTimeout] deliberately: the timeout
  /// bounds a hung publish, and folding a deliberate wait into it would make
  /// the decorrelation gap look like a hang and abandon the link. The timeout
  /// stays PER CIRCLE for the same reason it exists at all — inside a burst it
  /// is what stops one wedged circle from taking its siblings' publishes with
  /// it.
  Future<void> _pacedPublish(
    String circleKey,
    int generation,
    Duration gap,
    BurstFix fix,
  ) async {
    final last = _lastChainPublishAt;
    if (last != null) {
      final elapsed = DateTime.now().difference(last);
      if (elapsed < gap) {
        await Future<void>.delayed(gap - elapsed);
        if (!_isCurrent(generation) || !_active) return;
      }
    }
    // Re-read AFTER the wait, never before it: the wait is seconds long, and a
    // circle left, removed or flagged Unrecoverable inside it must not be sent
    // to (Rule 8). Re-reading ahead of the wait would leave a window as wide
    // as the gap in which exactly that happens. The burst sink re-reads at the
    // same point, through [eligibleCircle].
    final circle = _circles[circleKey];
    if (circle == null) return;
    _lastChainPublishAt = DateTime.now();
    await _publishCircle(circle, generation, fix: fix).timeout(
      _publishLinkTimeout,
      onTimeout: () => debugPrint(
        '[LocationPublishScheduler] per-circle publish exceeded '
        '${_publishLinkTimeout.inSeconds}s — abandoning the link so the '
        'chain keeps moving',
      ),
    );
  }

  /// Opens the publish window: the identity + disclosure gate (mirroring
  /// `locationPublisherProvider`'s — keep the two in sync) and ONE GPS fix.
  ///
  /// Returns null when a gate refused or the lifecycle moved on. THROWS what
  /// the identity read, the preference read or the GPS fetch throws; the
  /// single caller, [_openWindowAttributed], turns that into a health verdict
  /// for every circle waiting on the window.
  Future<BurstFix?> _openPublishWindow(int generation) async {
    final identity = await ref.read(identityProvider.future);
    if (identity == null) return null;

    // Play "disclosure before collection": never publish before the user has
    // accepted the in-app foreground-location disclosure.
    final prefs = await SharedPreferences.getInstance();
    if (!(prefs.getBool(kLocationDisclosureAcceptedKey) ?? false)) return null;
    if (!_isCurrent(generation) || !_active) return null;

    final locationService = ref.read(locationServiceProvider);
    final position = await locationService.getCurrentLocation();
    if (!_isCurrent(generation) || !_active) return null;
    return BurstFix(
      senderPubkeyHex: identity.pubkeyHex,
      latitude: position.latitude,
      longitude: position.longitude,
    );
  }

  /// Publishes the current location to a single [circle] from the [fix] its
  /// burst took for the whole due set. Never throws (the chain swallows errors
  /// too).
  ///
  /// It never opens a window of its own: every plane takes ONE fix per burst,
  /// and a per-circle window here is what would put a variable acquisition
  /// inside the decorrelation gap (see [_publishBurst]).
  Future<void> _publishCircle(
    Circle circle,
    int generation, {
    required BurstFix fix,
  }) async {
    if (!_isCurrent(generation) || !_active) return;
    try {
      final service = ref.read(locationSharingServiceProvider);
      final outcome = await service.publishLocation(
        mlsGroupId: circle.mlsGroupId,
        nostrGroupId: circle.nostrGroupId,
        senderPubkeyHex: fix.senderPubkeyHex,
        latitude: fix.latitude,
        longitude: fix.longitude,
      );
      switch (outcome) {
        // A `PublishResult` no relay accepted delivered nothing, and used to be
        // indistinguishable here from a success — the outcome was dropped
        // entirely. Record it so the sharing-health model can see the plane die.
        case LocationPublishSent(:final result):
          _recordPublishOutcome(circle, acked: result.acceptedBy.isNotEmpty);
        // A deferral is NOT a publish failure: nothing was rejected, the MLS
        // engine simply could not encrypt. It gets its own health verdict so
        // the banner can name the real cause, and deliberately does NOT reach
        // `recordPublishOutcome` — a deferred send has no relay verdict to
        // report, and `notePublishAcked` stays untouched (nothing was acked).
        case LocationPublishDeferred(:final unresolvedInputs, :final repaired):
          debugPrint(
            '[LocationPublishScheduler] send deferred by the MLS engine — '
            'gating=$unresolvedInputs, repaired=$repaired',
          );
          _recordDeferredSend(circle);
      }
    } on Object catch (e) {
      debugPrint('[LocationPublishScheduler] per-circle publish failed: '
          '${e.runtimeType}');
      _recordPublishOutcome(circle, acked: false);
    }
  }

  /// Feeds one publish verdict to the sharing-health model.
  ///
  /// Never throws: this is diagnostics, and a failure to record must not be
  /// able to take down the publish chain it is observing.
  void _recordPublishOutcome(Circle circle, {required bool acked}) {
    try {
      ref
          .read(sharingHealthProvider.notifier)
          .recordPublishOutcome(_circleKey(circle.nostrGroupId), acked: acked);
    } on Object catch (e) {
      debugPrint('[LocationPublishScheduler] health record failed: '
          '${e.runtimeType}');
    }
  }

  /// Feeds a deferred send to the sharing-health model.
  ///
  /// Never throws, for the same reason [_recordPublishOutcome] does not: this
  /// is diagnostics, and a failure to record must not take down the publish
  /// chain it is observing.
  void _recordDeferredSend(Circle circle) {
    try {
      ref
          .read(sharingHealthProvider.notifier)
          .recordDeferredSend(_circleKey(circle.nostrGroupId));
    } on Object catch (e) {
      debugPrint('[LocationPublishScheduler] deferred record failed: '
          '${e.runtimeType}');
    }
  }

  /// Resumes recurring publishing (app foregrounded). Re-arms a fresh burst
  /// cadence from the current roster, and RESUMES the service queue rather
  /// than rewinding it ([_rotation]). Idempotent.
  void startScheduling() {
    if (_disposed) return;
    _active = true;
    ref.read(circlesProvider).whenData(
          (circles) => _syncCircles(circles, _generation),
        );
  }

  /// Pauses recurring publishing (app backgrounded) so the background isolate
  /// is the sole writer (Rule 14). Cancels the armed tick; a later
  /// [startScheduling] re-arms a fresh CADENCE phase but the same service
  /// queue, because a device that backgrounds often would otherwise re-serve
  /// the roster's head every time and never reach its tail. Idempotent.
  void stopScheduling() {
    _active = false;
    _cancelScheduling();
  }

  /// Routes due ticks to [sink] instead of publishing them directly.
  ///
  /// `null` restores the direct publish. Installed while backgrounded on iOS
  /// (a [BackgroundBurstCoordinator]) and cleared on resume, so the burst
  /// machinery is inert in the foreground, where the engine holds its
  /// subscriptions anyway.
  // A method, not a setter: it is a lifecycle instruction from `MapShell`'s
  // pause/resume handlers, and a bare assignment would read as configuration.
  // ignore: use_setters_to_change_properties
  void setTickSink(BurstSink? sink) {
    _tickSink = sink;
  }

  // --- BurstPublisher ------------------------------------------------------

  // The roster this scheduler already maintains IS the answer: [_syncCircles]
  // only ever admits [filterPublishEligibleCircles] output and drops a circle
  // the moment it stops qualifying, so a burst asking here at fire time gets
  // exactly the check the foreground tick makes at fire time.
  @override
  Circle? eligibleCircle(String circleKey) => _circles[circleKey];

  @override
  Future<BurstFix?> openBurstPublishWindow(Iterable<Circle> circles) =>
      _openWindowAttributed(circles, _generation);

  /// [_openPublishWindow], bounded, with its failure attributed to every
  /// circle waiting on it. Never throws.
  ///
  /// Nothing got a fix, so every circle waiting on this window failed to
  /// publish. Attributing it here is what keeps a dead GPS from reading as
  /// healthy until the sharing-health model's silence threshold expires.
  ///
  /// The bound is [kPublishLinkTimeout] and it is load-bearing precisely
  /// BECAUSE the window is shared: one window now stands in front of a whole
  /// burst, so a link that never completes — the backgrounded iOS permission
  /// prompt the OS defers and geolocator never resolves — would stall not one
  /// circle but the chain, for the rest of the process. A timeout raises
  /// where an unfinished future raises nothing, which is what lets the catch
  /// below see it and record it as the failed publish it is.
  Future<BurstFix?> _openWindowAttributed(
    Iterable<Circle> circles,
    int generation,
  ) async {
    if (!_isCurrent(generation) || !_active) return null;
    try {
      return await _openPublishWindow(generation).timeout(_publishLinkTimeout);
    } on Object catch (e) {
      debugPrint('[LocationPublishScheduler] burst publish window failed: '
          '${e.runtimeType}');
      for (final circle in circles) {
        _recordPublishOutcome(circle, acked: false);
      }
      return null;
    }
  }

  @override
  Future<void> publishInBurst(Circle circle, BurstFix fix) =>
      _publishCircle(circle, _generation, fix: fix);

  // --- Test seams (mirror MaintenanceSchedulerNotifier) --------------------

  @visibleForTesting
  Set<String> get eligibleKeysForTest => _circles.keys.toSet();

  /// How many timers this plane has armed — the wake count P5 is about.
  ///
  /// One for any non-empty roster, none while paused or with nothing eligible.
  /// A per-circle scheduler would make this the circle count.
  @visibleForTesting
  int get armedWakesForTest => _scheduler == null ? 0 : 1;

  /// The armed timer ITSELF, so a test can prove a roster change reused it.
  /// [armedWakesForTest] counts a field: replacing the scheduler on every
  /// `circlesProvider` emission leaves the count at one while the abandoned
  /// timer keeps firing, which is the wake count growing with roster churn.
  @visibleForTesting
  JitteredScheduler? get armedSchedulerForTest => _scheduler;

  /// The order the next bursts will serve circles in — the fairness half of
  /// [kMaxCirclesPerBurst], which a burst-order assertion cannot see because
  /// that order is a CSPRNG permutation of the slice this decides.
  @visibleForTesting
  List<String> get rotationForTest => List<String>.unmodifiable(_rotation);

  @visibleForTesting
  bool get isActiveForTest => _active;

  /// Shortens [kPublishLinkTimeout] so the wedge-recovery property is
  /// provable in milliseconds instead of minutes. Production never writes it.
  @visibleForTesting
  // A getter would be dead weight: nothing reads this back, and the
  // production value is the const above.
  // ignore: avoid_setters_without_getters
  set publishLinkTimeoutForTest(Duration value) => _publishLinkTimeout = value;

  /// Enqueues one burst tick immediately (as a real timer would) and returns
  /// the serialization chain snapshot INCLUDING it — `await` the result to let
  /// the burst settle, or enqueue several before awaiting to exercise the FIFO
  /// serialization.
  @visibleForTesting
  Future<void> triggerTickForTest() {
    _onCircleTick(_generation);
    return _publishChain;
  }
}

/// One circle of a burst, with the scheduler's own key for it.
///
/// The key travels with the circle so the burst sink and the roster can never
/// disagree about circle identity.
typedef _BurstTarget = ({String key, Circle circle});

/// Provider owning the foreground publish tick.
///
/// Anchor once in `MapShell` (`ref.read(locationPublishSchedulerProvider
/// .notifier)`); cancelled on dispose and on the explicit invalidate in
/// `IdentityNotifier.deleteIdentity`.
final locationPublishSchedulerProvider =
    NotifierProvider<LocationPublishSchedulerNotifier, void>(
      LocationPublishSchedulerNotifier.new,
    );
