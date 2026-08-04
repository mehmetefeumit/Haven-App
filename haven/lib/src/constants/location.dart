/// Location publishing constants shared across the app.
///
/// ## Publish cadence
///
/// `kLocationUpdateInterval` is the **nominal** (mean) publish cadence.
/// Each tick is rearmed at a CSPRNG-sampled interval in
/// `[kLocationPublishMinInterval, kLocationPublishMaxInterval]` (nominal
/// ± 40%, see `haven-core/src/location/ttl.rs::PUBLISH_INTERVAL_JITTER_FRACTION_BP`).
///
/// ## Outer NIP-40 TTL — no-gap invariant (Dark Matter)
///
/// The kind:445 `expiration` tag is derived by the MDK engine as
/// `created_at + retention`, where retention is the group's
/// `message-retention.v1` component haven-core stamps at circle creation:
/// `LOCATION_MESSAGE_RETENTION_SECS = 228 s` =
/// `kLocationPublishMaxInterval + 2 * kTtlNetworkBufferSeconds`
/// (`haven-core/src/location/ttl.rs` — the two sides MUST stay in sync
/// by hand; there is no shared source of truth across the FFI).
///
/// For a relay to always have a non-expired event from every active
/// publisher, the **TTL must exceed the maximum publish delay** with a
/// network-propagation buffer:
///
/// ```
/// τ (228 s) > δ_max (kLocationPublishMaxInterval, 168 s) + 60 s buffer
/// ```
///
/// A single circle's worst-case inter-publish gap is δ_max = 168 s (the
/// ceiling of the ±40 % cadence jitter), so a 228 s TTL always leaves the
/// relay holding a non-expired event per active publisher, with a 60 s
/// margin for clock skew / propagation.
///
/// The pre-Dark-Matter per-send TTL jitter is gone: the engine derives
/// the expiration deterministically, and the wrapped event is signed by
/// an ephemeral key inside the engine's peeler, so no Haven-side
/// per-message TTL variation is possible (or desirable — a jittered
/// delta would single Haven out among engine-derived Marmot clients).
/// `updateIntervalSecs` passed to `CircleService.encryptLocation` is
/// retained for signature stability but no longer drives the TTL.
/// `RECEIVER_EXPIRATION_GRACE_SECS = 60 s` in `ttl.rs` sits on top as
/// defense-in-depth against clock skew, not to cover the publish/TTL
/// gap.
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

/// Maximum age of a cached stream-delivered position that
/// `GeolocatorLocationService.getCurrentLocation()` may serve instead of
/// issuing a fresh one-shot GPS request.
///
/// Freshness is measured against the GPS fix time (`Position.timestamp`),
/// not a Dart-side cached-at clock. Reuses [kLocationPublishMaxInterval]:
/// a fix at most this old is no staler than what an on-time jittered
/// publish tick would have captured anyway. This cache is what lets the
/// iOS background publish path avoid the one-shot `getCurrentPosition`
/// entirely — the plugin's one-time CLLocationManager never enables
/// background delivery, so a backgrounded one-shot can only stall.
///
/// This is a FRESHNESS bound and never a consent bound. Whether the user
/// still has location access is decided per call by
/// `GeolocatorLocationService._ensureAccessOrThrow()`, and any observed
/// loss clears the cache outright, so this window can never become a tail
/// of publishing after a revoked permission or a switched-off provider.
const Duration kStreamPositionMaxAge = kLocationPublishMaxInterval;

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

/// SharedPreferences key storing the millisecond timestamp of the last MLS
/// session-reclaim attempt by the background isolate.
///
/// Backs the rate limit in `BackgroundLocationTaskHandler`: a reclaim stops the
/// live-sync engine, so a tight retry loop against a condition it cannot fix
/// (for example a leaked manager handle, which the reclaim does not own) would
/// keep restarting that teardown every cycle. Persisted rather than held in
/// memory so a service restart cannot reset the limit.
const String kBackgroundSessionReclaimAtMsKey =
    'haven.background_session_reclaim_at_ms';

/// Minimum interval between MLS session-reclaim attempts.
///
/// Long relative to the publish cadence: a genuine orphaned session is
/// permanent until reclaimed, so recovering on the next tick instead of this
/// one costs little, while retrying every tick against an unfixable condition
/// costs a live-sync teardown each time.
const Duration kBackgroundSessionReclaimBackoff = Duration(minutes: 15);

// ---------------------------------------------------------------------------
// Device-clock skew
// ---------------------------------------------------------------------------

/// Skew magnitude at which every location this device publishes is discarded
/// by a correctly-clocked peer.
///
/// A receiver drops an event whose NIP-40 expiration is more than
/// `RECEIVER_EXPIRATION_GRACE_SECS` (60 s) into its past, and the expiration is
/// `created_at + LOCATION_MESSAGE_RETENTION_SECS` (228 s) — both computed from
/// the *sender's* clock. A publisher lagging by this much therefore loses 100 %
/// of its updates while still seeing a successful relay ACK.
///
/// Drift-check only; the authoritative value lives in Rust at
/// `haven_core::relay::clock_skew::TOTAL_LOSS_SKEW_SECS`.
const Duration kClockSkewTotalLossThreshold = Duration(seconds: 288);

/// Skew magnitude at or above which Haven tells the user their clock is wrong.
///
/// Derived from the two constants that bound what actually breaks, not chosen
/// for feel:
///
/// * **Lower bound — do not cry wolf.** `RECEIVER_EXPIRATION_GRACE_SECS` is
///   60 s: the band of disagreement the protocol already absorbs by design.
///   Alerting inside it would fire on skew that costs the user nothing.
///   `2 × 60 = 120` sits strictly outside every tolerated band.
/// * **Upper bound — do not hide real breakage.** At
///   [kClockSkewTotalLossThreshold] (288 s) delivery is already 100 % lost and
///   silent; the alarm must fire well before that.
/// * **It is already a real defect here.** The no-gap invariant is
///   `retention (228 s) > max publish gap (168 s)`. A publisher lagging 120 s
///   has an effective relay residency of `228 − 120 = 108 s`, under the 168 s
///   worst-case inter-publish gap, so peers are *guaranteed* coverage holes.
///
/// Moving this in either direction is a behaviour change: widening hides
/// breakage, narrowing cries wolf. Pinned by `clock_skew_detector_test.dart`
/// and, against the Rust original
/// (`haven_core::relay::clock_skew::CLOCK_SKEW_ALERT_THRESHOLD_SECS`), by
/// `scripts/ci/check_clock_skew_policy_parity.sh`.
const Duration kClockSkewAlertThreshold = Duration(seconds: 120);
