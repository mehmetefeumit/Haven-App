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
/// publisher, the **minimum TTL must exceed the maximum publish delay**
/// with a network-propagation buffer:
///
/// ```
/// τ_min > δ_max  ⇒  updateIntervalSecs > kLocationPublishMaxInterval
/// ```
///
/// We pass `kLocationPublishMaxInterval.inSeconds + 30` (198 s) rather
/// than the nominal 120 s to:
///
///  1. Close the gap that would appear when a late publish (`δ = 168 s`)
///     follows an event that drew the minimum TTL (`τ = 120 s`).
///  2. Add a 30 s network-propagation buffer so L₁ reaches the relay
///     before L₀'s TTL expires even under moderate latency.
///
/// The resulting on-wire TTL window is `[198, 396] s` and is part of the
/// receiver contract — `RECEIVER_EXPIRATION_GRACE_SECS = 60 s` in
/// `ttl.rs` sits on top as defense-in-depth against clock skew, not to
/// cover the publish/TTL gap.
///
/// The two jitters (publish interval and TTL) remain sampled
/// independently — only the *range parameter* of the TTL jitter is
/// lifted from `nominal` to `publish_max + 30`.
///
/// ## Overlap guard
///
/// `kLocationPublishOverlapGuard` is the publish-skip guard. It MUST sit
/// strictly below `kLocationPublishMinInterval` so that genuine short-end
/// jittered ticks are not suppressed (which would bias the distribution
/// upward). It also gates motion-triggered publishes and the
/// `didChangeAppLifecycleState(resumed)` branch in `map_shell.dart`.
///
// TODO(efe): when user-configurable update intervals are added (settings
// UI), source from a Riverpod provider analogous to
// `senderRetentionProvider`. The FFI already accepts the value per-call.
library;

/// Nominal (mean) publish cadence. Actual ticks are jittered around this
/// value by `JitteredScheduler`; see file-level doc for invariants.
const Duration kLocationUpdateInterval = Duration(minutes: 2);

/// Publish-skip guard; MUST be strictly below
/// `kLocationPublishMinInterval`. Also gates motion-triggered publishes
/// in `map_shell.dart`.
const Duration kLocationPublishOverlapGuard = Duration(seconds: 60);

/// Minimum jittered publish interval.
///
/// Drift-check only; the authoritative bound lives in Rust at
/// `PUBLISH_INTERVAL_JITTER_FRACTION_BP = 4000`. Computed as
/// `kLocationUpdateInterval * (1 - 0.4)` = 72s.
const Duration kLocationPublishMinInterval = Duration(seconds: 72);

/// Maximum jittered publish interval.
///
/// Drift-check only; the authoritative bound lives in Rust. Computed as
/// `kLocationUpdateInterval * (1 + 0.4)` = 168s.
const Duration kLocationPublishMaxInterval = Duration(seconds: 168);

/// Network-propagation buffer added to `kLocationPublishMaxInterval`
/// when computing the TTL floor passed to Rust. Ensures the minimum
/// sampled TTL (τ_min) exceeds the maximum publish delay (δ_max) by
/// enough margin to absorb relay-to-relay propagation latency.
const int kTtlNetworkBufferSeconds = 30;

/// Minimum distance in metres the device must move before a
/// motion-triggered publish fires (subject to [kLocationPublishOverlapGuard]).
const double kMotionTriggerDistanceMeters = 100.0;
