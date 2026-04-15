/// Location publishing constants shared across the app.
///
/// ## Publish cadence
///
/// `kLocationUpdateInterval` is the **nominal** (mean) publish cadence.
/// Each tick is rearmed at a CSPRNG-sampled interval in
/// `[kLocationPublishMinInterval, kLocationPublishMaxInterval]` (nominal
/// ± 40%, see `haven-core/src/location/ttl.rs::PUBLISH_INTERVAL_JITTER_FRACTION_BP`).
///
/// ## Outer NIP-40 TTL — no-gap invariant
///
/// The `updateIntervalSecs` passed to `CircleService.encryptLocation`
/// feeds `compute_jittered_ttl_secs` in Rust, which samples the outer
/// kind:445 `expiration` tag uniformly in `[interval, 2 * interval]`.
///
/// For a relay to always have a non-expired event from every active
/// publisher, the **minimum TTL must be at least the maximum publish
/// delay**:
///
/// ```
/// τ_min ≥ δ_max  ⇒  updateIntervalSecs ≥ kLocationPublishMaxInterval
/// ```
///
/// We pass `kLocationPublishMaxInterval.inSeconds` (420 s) rather than
/// the nominal 300 s to close the 120 s worst-case relay gap that
/// would otherwise appear when a late publish (`δ = 420 s`) follows
/// an event that drew the minimum TTL (`τ = 300 s`). The resulting
/// on-wire TTL window is `[420, 840] s` and is part of the receiver
/// contract — `RECEIVER_EXPIRATION_GRACE_SECS = 60 s` in `ttl.rs` sits
/// on top as defense-in-depth against clock skew, not to cover the
/// publish/TTL gap.
///
/// The two jitters (publish interval and TTL) remain sampled
/// independently — only the *range parameter* of the TTL jitter is
/// lifted from `nominal` to `publish_max`.
///
/// ## Overlap guard
///
/// `kLocationPublishOverlapGuard` is the publish-skip guard. It MUST sit
/// strictly below `kLocationPublishMinInterval` so that genuine short-end
/// jittered ticks are not suppressed (which would bias the distribution
/// upward). It exists as defense-in-depth against the
/// `didChangeAppLifecycleState(resumed)` branch in `map_shell.dart` which
/// calls `ref.read(locationPublisherProvider)` independently of the
/// scheduler.
///
// TODO(efe): when user-configurable update intervals are added (settings
// UI), source from a Riverpod provider analogous to
// `senderRetentionProvider`. The FFI already accepts the value per-call.
library;

/// Nominal (mean) publish cadence. Actual ticks are jittered around this
/// value by `JitteredScheduler`; see file-level doc for invariants.
const Duration kLocationUpdateInterval = Duration(minutes: 5);

/// Publish-skip guard; MUST be strictly below
/// `kLocationPublishMinInterval`.
const Duration kLocationPublishOverlapGuard = Duration(minutes: 2, seconds: 30);

/// Minimum jittered publish interval.
///
/// Drift-check only; the authoritative bound lives in Rust at
/// `PUBLISH_INTERVAL_JITTER_FRACTION_BP = 4000`. Computed as
/// `kLocationUpdateInterval * (1 - 0.4)` = 180s.
const Duration kLocationPublishMinInterval = Duration(minutes: 3);

/// Maximum jittered publish interval.
///
/// Drift-check only; the authoritative bound lives in Rust. Computed as
/// `kLocationUpdateInterval * (1 + 0.4)` = 420s.
const Duration kLocationPublishMaxInterval = Duration(minutes: 7);
