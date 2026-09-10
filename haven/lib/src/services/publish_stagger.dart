/// CSPRNG inter-publish stagger — cross-circle `created_at` decorrelation.
///
/// ## The leak this closes
///
/// The MDK engine binds the OUTER kind-445 `created_at` to the INNER
/// application event's `created_at`
/// (`cgka-engine/src/message_processor/send.rs` builds
/// `GroupMessageMetadata::application(app_event.created_at, …)`;
/// `transport-nostr-peeler/src/peeler.rs` then calls
/// `builder.custom_created_at(…)` with it). Upstream documents the
/// consequence on `GroupMessageMetadata::outer_created_at`: binding the two
/// "makes broadcasts of identical content to multiple groups share a
/// timestamp — an accepted trade-off for cross-client ordering".
///
/// Haven's inner rumor is stamped by `nostr::EventBuilder::build`, i.e.
/// `Timestamp::now()`, which is a **u64 of whole seconds**. So two circles
/// whose `encryptLocation` calls land in the same wall-clock second emit two
/// kind-445 events carrying a byte-identical `created_at` (and, since the
/// NIP-40 `expiration` tag is `created_at + LOCATION_MESSAGE_RETENTION_SECS`,
/// an identical expiration too). That equality is inside the SIGNED event: it
/// survives to every relay in each circle's routing set and into any archive,
/// so anyone holding kind-445s from two circles — from different relays, or a
/// scraper that never saw the socket — can link those otherwise-unlinkable
/// pseudonymous circles to one device. Repeated exact matches are decisive
/// within a couple of bursts.
///
/// The only local lever is WHEN the encrypt happens, so this samples a delay
/// between consecutive publishes.
///
/// ## What the stagger still buys, stated exactly
///
/// The publish SCHEDULE is no longer a defence. One jittered tick publishes
/// every eligible circle, so circles held on disjoint relay sets emit the same
/// inter-burst rhythm and anyone holding two of your circles' archives can tell
/// they belong to the same phone — the accepted cost of not paying one radio
/// wake per circle per interval, and a cost the per-circle schedules it
/// replaced never actually avoided (a shared relay reads the circle set off
/// the multiplexed `#h` subscription, and every publish leaves over one
/// publish socket).
///
/// So the gaps are NOT "the archive-adversary defence" — after coalescing the
/// archive reader gets the link anyway, from the shared inter-burst interval
/// sequence. What the gaps still buy is ROSTER-SCOPED, because
/// [PublishStagger.maxGapFor] prices every gap at the burst's own size. The
/// observer sees no sockets and no milliseconds, only `floor(created_at)` per
/// event, so its alphabet is the whole-second delta: `{2…9}` (eight values) up
/// to four circles, thinning monotonically — `{2…6}` at six, `{2…5}` at eight
/// — to exactly `{2,3,4}` at [kMaxCirclesPerAccount], the largest burst a
/// bounded roster can produce. (`maxGapFor` keeps answering one circle further,
/// where the alphabet is `{2,3}`; no observer reaches that while the roster
/// bound holds.) Coalescing is what thinned it: before it every gap was priced
/// at the default `totalPublishes = 2`, so the alphabet was always eight.
///
/// At small rosters the downgrade in KIND is real. A byte-identical
/// `created_at` is a zero-cost equality join — a scraper indexes every kind-445
/// in the network by timestamp and reads the pairs straight off, with no
/// hypothesis about who anyone is — whereas eight admissible offsets force a
/// windowed correlation: the reader must first hypothesise that two specific
/// circles share a device, then test that against a matching sequence of
/// offsets. At the roster BOUND it barely is: a three-element alphabet is three
/// shifted equality joins over that same whole-network index, still
/// un-targeted mass linkage. What survives there is a constant factor, not a
/// change in kind.
///
/// The delta must therefore both exceed one second and VARY — one that prints
/// the same number every burst is as good a link as no gap at all — which is
/// why the bounds below are load-bearing rather than tunable, and why the
/// per-gap floor is the last thing a growing burst may spend.
///
/// ## Why the bounds are what they are
///
/// * **[kPublishStaggerMinGap] = 2 s.** `created_at` is whole seconds, so
///   millisecond jitter changes nothing: the gap has to exceed one second.
///   `floor(t + 2 s) > floor(t)` always holds, with a full second of margin
///   for scheduler slop between "we stopped waiting" and "Rust read the
///   clock".
/// * **[kPublishStaggerMaxGap] = 9 s.** Wide enough that the observed
///   separation is not itself a fingerprint (a constant stagger would be one),
///   sampled fresh per gap from a CSPRNG.
/// * **[kPublishStaggerMaxSpread] = 30 s** caps the whole burst. It sits
///   below `kLocationPublishOverlapGuard` (60 s), so a burst always finishes
///   before another burst may begin; at half of the no-gap invariant's margin
///   (`LOCATION_MESSAGE_RETENTION_SECS` 228 s − `kLocationPublishMaxInterval`
///   168 s = 60 s); and far under `kStreamPositionMaxAge` (168 s), the app's
///   own definition of a GPS fix still fresh enough to publish — so the one
///   fix taken at burst start is still legitimate for the last circle in the
///   burst — which is only true because the burst takes ONE fix and shares it
///   (`BurstFix`), on every plane.
///
/// When a burst has more circles than fit in the spread at
/// [kPublishStaggerMaxGap], the per-gap ceiling shrinks — but never below
/// `minGap + 1 s`, so it stays both above one second AND non-degenerate
/// (`PublishStagger.maxGapFor`). Past [kMaxCirclesPerBurst] the floor no
/// longer fits inside the budget, and it is the BURST that yields rather than
/// either property: the extra circles are deferred to the next tick, exactly
/// as the Android foreground service's own cycle deadline already defers them
/// (`nextBackgroundPublishSlot`'s `deadline`, in `per_circle_due_tracker.dart`
/// — returning `null` leaves the rest due). What that deferral costs is stated
/// on [kMaxCirclesPerBurst] rather than hidden, and [kMaxCirclesPerAccount] is
/// what keeps a production roster from reaching it.
///
/// FFI-free and Riverpod-free on purpose: both the foreground publisher and
/// the background isolate use it, and the decorrelation property must be unit
/// testable without the Rust bridge.
library;

import 'dart:math';

/// Smallest delay between two consecutive kind-445 location publishes.
///
/// MUST stay strictly above one second — `created_at` is whole seconds.
const Duration kPublishStaggerMinGap = Duration(seconds: 2);

/// Largest single sampled gap (before the spread cap shrinks it).
const Duration kPublishStaggerMaxGap = Duration(seconds: 9);

/// Cap on the SCHEDULED spread of one burst (sum of its gaps).
const Duration kPublishStaggerMaxSpread = Duration(seconds: 30);

/// Most circles one burst may publish. The rest are left due for the next
/// tick.
///
/// **Derived, not chosen.** A circle that leads one burst and trails the next
/// waits the cadence ceiling PLUS one burst spread, and the relay must still
/// be holding its previous kind-445 when that lands:
///
/// ```text
/// kLocationPublishMaxInterval (168 s) + spread
///     ≤ LOCATION_MESSAGE_RETENTION_SECS (228 s)
///       − kTtlNetworkBufferSeconds (30 s)
/// ⟹ spread ≤ 30 s = kPublishStaggerMaxSpread
/// ```
///
/// A burst of `n` circles has `n − 1` gaps and `PublishStagger.maxGapFor`
/// never prices one below `kPublishStaggerMinGap + 1 s` (3 s — the floor that
/// keeps the gap both over one whole second and non-degenerate), so:
///
/// ```text
/// n − 1 ≤ kPublishStaggerMaxSpread ÷ (kPublishStaggerMinGap + 1 s)
///       = 30 s ÷ 3 s = 10       ⟹  n ≤ 11
/// ```
///
/// A literal because neither `Duration ~/ Duration` nor `Duration +
/// Duration` is a constant expression; `publish_stagger_test.dart` pins it
/// against exactly that arithmetic, and against `maxSpreadFor` being the
/// largest burst that still fits [kPublishStaggerMaxSpread].
///
/// **What a roster past this costs — said plainly rather than hidden, and
/// UNREACHABLE in production since [kMaxCirclesPerAccount] bounded the
/// roster.** The deferral code below is still here and still correct; what
/// changed is that nothing can hand it more than ten circles. The ladder is
/// kept because it is what lifting the bound would re-open. The
/// burst slice is strict round-robin (`_takeBurstSlice`), so a circle's worst
/// service period is `ceil(N ÷ 11)` bursts, not "two" at every roster:
/// N = 12…22 → 2 intervals (144 s best, 240 s mean, 336 s worst, and 366 s
/// once the burst-position differential is added — a circle can lead one burst
/// and trail the one two ticks later, one whole spread apart); N = 23…33 → 3
/// (216 / 360 / 504 s); N ≥ 34 → 4 or more, where even the BEST case (288 s)
/// exceeds the 228 s retention on every publish rather than on some. From the
/// twelfth circle up, a deferral therefore leaves a peer's marker expired at
/// the relay for most interval pairs, and past thirty-three for all of them.
/// Swept as behaviour by `a deferred circle waits ceil(N / kMaxCirclesPerBurst)
/// bursts` (`test/providers/location_publish_scheduler_provider_test.dart`,
/// whose expectation is a literal `_expectedServicePeriodBursts` table, so
/// moving the cap forces an edit there rather than re-deriving quietly around
/// it) and quoted in seconds by `and past the cap, the deferral ladder in
/// SECONDS` (`publish_stagger_test.dart`).
///
/// **ONE limit on that quotient, and one thing that is NOT a limit.** The
/// period is absolute, not per continuous run: `_rotation` outlives
/// `stopScheduling()`/`startScheduling()` and outlives an emission reporting
/// nothing eligible, so neither a backgrounding nor a failed roster read
/// re-phases whose turn it is (`a deferred circle is not deferred again by
/// every resume`, `a transient empty roster emission does not re-phase whose
/// turn it is`, `a roster change keeps survivors' places in the queue`, plus
/// `scripts/ci/check_publish_rotation_fairness.sh`, which pins the rewind to
/// exactly ONE site inside `build()` and the survivor merge to below the
/// empty-roster guard). It is a period of TURNS, and a turn is a SELECTION
/// rather than a publish: the rotation advances when the tick FIRES, ahead of
/// the chain, the window and the sink, so a slice can lose its turn without
/// publishing — a refused publish window, a pause under it, an iOS burst the
/// coordinator drops — and then waits its whole period over again: one more
/// burst at `N ≤ 11` (up to 336 s against the 228 s retention), and another
/// `ceil(N ÷ 11)` past the cap. What
/// the quotient does not bound is a background PASS: it bounds what the
/// scheduler hands over, and while the iOS sink is installed a tick arriving
/// inside a running burst folds into it
/// (`BackgroundBurstCoordinator._joinable`) rather than opening a socket of its
/// own, so one pass can carry two slices — reachable only at `N ≥ 12`, already
/// past the roster this cap's arithmetic covers.
///
/// What DOES rewind the queue is `build()` — a fresh container, or the
/// invalidate in `IdentityNotifier.deleteIdentity` — and a process restart,
/// which does not persist it. Because the roster keeps
/// `filterPublishEligibleCircles` order (`getVisibleCircles()` orders by
/// `updated_at DESC`), a rebuild rewinds to the SAME head and re-serves the
/// same first slice: a deterministic re-service, not a re-phase. The tail's gap
/// across that boundary is bounded by how often the app resumes rather than
/// unbounded, because `locationPublisherProvider` is deliberately uncapped and
/// fires on cold start, on motion, on accept/create and on a resume MORE THAN
/// 30 s after the last one — `MapShell`'s resume debounce sits ABOVE its
/// invalidate, so a glance inside that window triggers nothing. The cover it
/// gives is not universal either: from 21 circles the one-shot's own spread
/// outlasts `kLocationPublishOverlapGuard`, so the next trigger's invalidate
/// marks the burst in flight superseded and it stops where it stands, with
/// the replacement re-shuffling from the start. Past twenty circles the
/// tail's cover across a rewind is therefore a probability, not a promise.
///
/// TWO baselines, because they answer differently. Against an UNCAPPED
/// coalesced burst the hole opened from the twenty-second circle up
/// (`168 + 3 × 21 = 231 s`) and the cap moves it to the twelfth. Against the
/// ACTUAL predecessor — per-circle schedulers, where δ was each circle's own
/// sampled interval, ≤ 168 s at every roster with no spread and no deferral —
/// there was no hole at ANY roster size and the full 60 s
/// (`2 × kTtlNetworkBufferSeconds`) of margin was intact, so this is a
/// regression at every `N ≥ 12` with no upper bound, and at every `N ≥ 2` in
/// the margin (60 s → 30 s). Taken deliberately (owner, 2026-09-08, option
/// (a)): the cap is what makes the burst span, the single shared GPS fix and
/// `kLocationPublishOverlapGuard` hold for every roster. Past that, no
/// arrangement of the publishes closes it either — `n` events more than
/// [kPublishStaggerMinGap] apart cannot fit inside the 60 s the retention
/// leaves above the cadence ceiling once `n > 31`, a DIFFERENT bound from the
/// service period above because it is about one burst's spread rather than how
/// many bursts a circle waits. Both of those needed a roster bound or a longer
/// retention; the owner took the roster bound on 2026-09-09, so both are now
/// out of production reach rather than live — see [kMaxCirclesPerAccount] for
/// exactly what "out of reach" rests on.
const int kMaxCirclesPerBurst = 11;

/// Most circles one account may hold. Creating a circle or accepting an
/// invitation beyond this is REFUSED (owner decision, 2026-09-09), at the one
/// seam both reach the core through — `NostrCircleService`.
///
/// **Derived from [kMaxCirclesPerBurst], not chosen.** `10 <
/// kMaxCirclesPerBurst` (11) ⟹ every publish-eligible circle fits ONE burst ⟹
/// no circle is ever deferred ⟹ the `ceil(N ÷ kMaxCirclesPerBurst)`
/// service-period ladder above is unreachable in production, and the no-gap
/// floor that `LOCATION_MESSAGE_RETENTION_SECS` (228 s) is sized for holds at
/// every roster the app admits rather than only up to eleven.
///
/// Ten and not eleven because the spare circle is the headroom: it absorbs a
/// future REDUCTION of the burst cap — which is derived from the spread budget
/// and the per-gap floor, so a cadence or freshness change can move it —
/// without re-opening the hole. At eleven the two would have to move together,
/// and the first tightening would defer a tail again.
///
/// Counted over ACCEPTED memberships only: a pending invitation publishes
/// nothing, so it occupies no burst slot until it is accepted, and the accept
/// is itself gated. A blocked or legacy-orphaned circle is counted even though
/// it cannot publish today, because a repair can make it eligible again and the
/// bound has to hold across that.
const int kMaxCirclesPerAccount = 10;

/// Samples CSPRNG delays that keep two circles' kind-445 events out of the
/// same wall-clock second.
///
/// [Random.secure] is the default source: this is a privacy control, so a
/// predictable stream would let an observer undo the decorrelation. Tests
/// inject a seeded [Random] (still a real distribution) or collapse the bounds
/// to [Duration.zero] to keep unrelated tests fast.
class PublishStagger {
  PublishStagger({
    Random? rng,
    Duration minGap = kPublishStaggerMinGap,
    Duration maxGap = kPublishStaggerMaxGap,
    Duration maxSpread = kPublishStaggerMaxSpread,
  }) : assert(minGap <= maxGap, 'minGap must not exceed maxGap'),
       assert(!minGap.isNegative, 'minGap must not be negative'),
       _rng = rng ?? Random.secure(),
       _minGap = minGap,
       _maxGap = maxGap,
       _maxSpread = maxSpread;

  /// A stagger that never waits. For tests whose subject is something other
  /// than the decorrelation itself; production must never construct this.
  PublishStagger.none()
    : _rng = Random(0),
      _minGap = Duration.zero,
      _maxGap = Duration.zero,
      _maxSpread = Duration.zero;

  final Random _rng;
  final Duration _minGap;
  final Duration _maxGap;
  final Duration _maxSpread;

  /// Per-gap ceiling for a burst of [totalPublishes] events.
  ///
  /// Shrinks so `(totalPublishes - 1)` gaps fit inside
  /// [kPublishStaggerMaxSpread], but never below `minGap + 1 s`: the >1 s
  /// separation is the property, the spread cap is only a freshness budget,
  /// so the budget yields first.
  Duration maxGapFor(int totalPublishes) {
    if (totalPublishes <= 1) return _minGap;
    final ceilingMs = _maxGap.inMilliseconds;
    final perGapMs = _maxSpread.inMilliseconds ~/ (totalPublishes - 1);
    final floorMs = min(_minGap.inMilliseconds + 1000, ceilingMs);
    return Duration(milliseconds: perGapMs.clamp(floorMs, ceilingMs));
  }

  /// Worst-case scheduled spread of a burst of [totalPublishes] events.
  ///
  /// Exceeds [kPublishStaggerMaxSpread] only for bursts too large to fit at
  /// the `minGap + 1 s` floor — 12 circles and up — which is exactly where
  /// [kMaxCirclesPerBurst] stops a production burst, so a caller only reaches
  /// the growing branch by asking a hypothetical. Answering it anyway is what
  /// lets the cap be DERIVED from this function rather than asserted beside
  /// it.
  Duration maxSpreadFor(int totalPublishes) => totalPublishes <= 1
      ? Duration.zero
      : maxGapFor(totalPublishes) * (totalPublishes - 1);

  /// One fresh gap, uniform in `[minGap, maxGapFor(totalPublishes)]`.
  Duration sampleGap({int totalPublishes = 2}) {
    final minMs = _minGap.inMilliseconds;
    final maxMs = maxGapFor(totalPublishes).inMilliseconds;
    if (maxMs <= minMs) return Duration(milliseconds: minMs);
    return Duration(milliseconds: minMs + _rng.nextInt(maxMs - minMs + 1));
  }

  /// Gaps to wait BEFORE each publish of a [count]-event burst.
  ///
  /// Index 0 is [Duration.zero] because nothing inside THIS burst precedes it,
  /// and freshness is not spent on a gap nobody can observe; every later entry
  /// is an independent [sampleGap]. A caller whose chain already carries a
  /// publish from an EARLIER burst owns that boundary itself — index 0 says
  /// nothing about it (`LocationPublishSchedulerNotifier._publishBurst`).
  List<Duration> sampleGaps(int count) {
    if (count <= 0) return const <Duration>[];
    return <Duration>[
      Duration.zero,
      for (var i = 1; i < count; i++) sampleGap(totalPublishes: count),
    ];
  }

  /// A CSPRNG permutation of [items].
  ///
  /// Which circle goes first must not be a stable property of the circle set:
  /// a fixed order would make one circle permanently the un-delayed one, i.e.
  /// a second-order fingerprint of the same burst.
  List<T> shuffled<T>(List<T> items) => List<T>.of(items)..shuffle(_rng);
}
