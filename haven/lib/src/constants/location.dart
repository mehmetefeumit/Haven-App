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
// UI), source from a Riverpod provider. The FFI already accepts the
// value per-call.
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
const double kMotionTriggerDistanceMeters = 100;

// ---------------------------------------------------------------------------
// Background service
// ---------------------------------------------------------------------------

/// Repeat interval for the Android foreground-service timer.
///
/// Set to [kLocationPublishMinInterval] (72 s) so the software-jitter
/// logic in `BackgroundLocationTaskHandler.onRepeatEvent` can achieve
/// the full `[72 s, 168 s]` range by skipping early ticks.
const Duration kBackgroundRepeatInterval = kLocationPublishMinInterval;

/// SharedPreferences key for the user's background-sharing toggle.
const String kBackgroundSharingKey = 'haven.background_sharing';

/// SharedPreferences key for the last background publish timestamp
/// (milliseconds since epoch). Used for cross-isolate coordination so
/// the foreground overlap guard seeds correctly on resume.
const String kBackgroundLastPublishMsKey = 'haven.background_last_publish_ms';

/// SharedPreferences key signalling that the background isolate is idle
/// (no in-flight publish cycle). Written by the background task handler
/// on destroy, read by the foreground to avoid starting a new publish
/// while the background is still mid-cycle (MLS single-owner invariant).
const String kBackgroundIdleKey = 'haven.background_idle';

/// SharedPreferences key storing the millisecond timestamp at which the
/// foreground UI isolate last declared itself active. Written by
/// `BackgroundLocationManager.markForegroundActive(active: true)` on
/// app init, resume, and after each successful foreground publish.
/// Written as `0` (or removed) by `markForegroundActive(active: false)`
/// on pause.
///
/// The background task treats the foreground as "active" only when:
///   `now - ts < 2 * kBackgroundRepeatInterval`
///
/// This staleness window means that even if the process is killed (OOM,
/// force-stop, swipe-from-recents) without `_onPaused` firing, the
/// background isolate will resume publishing after at most
/// `2 * kBackgroundRepeatInterval` rather than being blocked
/// forever by a stuck `true` boolean.
const String kForegroundActiveAtMsKey = 'haven.foreground_active_at_ms';

/// Distance filter (metres) for the iOS background location stream.
///
/// Only GPS updates that exceed this threshold trigger a delegate
/// callback. Keeps the stream alive for process retention while
/// avoiding excessive wakeups when stationary.
const double kBackgroundDistanceFilterMeters = 50;

// ---------------------------------------------------------------------------
// Prominent disclosure (Google Play "Prominent Disclosure & Consent")
// ---------------------------------------------------------------------------

/// SharedPreferences key recording that the user accepted the in-app
/// foreground location disclosure shown before the OS permission prompt.
///
/// Play requires an affirmative, in-app disclosure of WHY/WHAT/HOW location
/// is used *before* the runtime permission request; this flag prevents the
/// disclosure from re-prompting once accepted.
const String kLocationDisclosureAcceptedKey =
    'haven.location.disclosure_accepted';

/// SharedPreferences key recording that the user accepted the *background*
/// location disclosure (the stricter variant carrying the "even when the app
/// is closed or not in use" sentence).
///
/// Tracked separately from [kLocationDisclosureAcceptedKey] so background
/// sharing can never be enabled without showing the background-specific
/// disclosure first, even if the foreground disclosure was already accepted.
const String kLocationDisclosureBackgroundAcceptedKey =
    'haven.location.disclosure_background_accepted';
