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
///   burst.
///
/// When a burst has more circles than fit in the spread at
/// [kPublishStaggerMaxGap], the per-gap ceiling shrinks — but never below
/// `minGap + 1 s`, so it stays both above one second AND non-degenerate. Past
/// 11 circles the two goals genuinely conflict, and the SPREAD BUDGET is what
/// yields: a burst of 12+ circles can run past 30 s (about 2.7 s per extra
/// circle). That is the right trade. The budget is a freshness preference
/// bounded by `kStreamPositionMaxAge` (168 s — still respected at 60+
/// circles), whereas dropping to a fixed one-second-ish gap would trade away
/// the two properties this exists for. The burst is also self-limiting in
/// practice: a superseding burst cancels the one before it, and the background
/// cycle stops at its own deadline and defers the rest to the next tick.
/// See `PublishStagger.maxGapFor`.
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
  /// the `minGap + 1 s` floor — 12 circles and up — see [maxGapFor].
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
  /// Index 0 is always [Duration.zero] (the burst's first publish is not
  /// delayed — freshness is not spent on a gap nobody can observe), every
  /// later entry is an independent [sampleGap].
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
