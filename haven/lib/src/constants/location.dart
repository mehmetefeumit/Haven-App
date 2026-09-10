/// Location publishing constants shared across the app.
///
/// ## Publish cadence
///
/// `kLocationUpdateInterval` is the **nominal** (mean) publish cadence.
/// Each tick is rearmed at a CSPRNG-sampled interval in
/// `[kLocationPublishMinInterval, kLocationPublishMaxInterval]` (nominal
/// ± 40%, see `haven-core/src/location/ttl.rs::PUBLISH_INTERVAL_JITTER_FRACTION_BP`).
///
/// One jittered burst per interval publishes every eligible circle it can, so
/// the cadence above is the device's, not each circle's. On the two
/// TIMER-driven planes — the foreground tick and the iOS background burst that
/// shares it — that is one armed wake, so the radio wakes ~30 times an hour for
/// any roster up to `kMaxCirclesPerBurst`; past that a burst defers its tail to
/// the next tick, and the deferred circle then publishes on the tick after —
/// which `kMaxCirclesPerAccount` (10, below the burst cap of 11) keeps out of
/// production reach.
/// The Android foreground service is DELIVERY-driven and holds no publish timer
/// at all: its cadence is the platform location request's, measured per API
/// regime in `test/services/background_fix_request_test.dart`, where one cycle
/// serves the whole roster at every circle count that fits the spread budget.
///
/// Inside a burst the circles are staggered at least `kPublishStaggerMinGap`
/// (2 s) apart so no two of them share a whole-second `created_at`. The ceiling
/// is `kPublishStaggerMaxGap` (9 s) only for small bursts: `PublishStagger`
/// prices each gap at the burst's own size, so the ceiling — and with it the
/// observable delta alphabet — shrinks as the roster grows, down to a 3 s
/// ceiling at `kMaxCirclesPerBurst`. The burst's own timing links the circles
/// to one device and is an accepted deviation; what the stagger still buys
/// against an archive reader is stated, roster by roster, on `PublishStagger`.
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
/// τ (228 s) > δ_max (168 s interval ceiling + 30 s burst spread = 198 s)
/// ```
///
/// Written the other way — `τ > 168 + 60` — it is not an inequality at all but
/// `228 > 228`, because the constant IS `168 + 2 × 30`. The two buffers are
/// spent separately: one covers the burst spread a circle can move across, the
/// other is the propagation and clock-skew margin the inequality leaves over.
/// `haven-core/SECURITY.md` ("The no-gap invariant") states it in this form.
///
/// A single circle's worst-case SCHEDULED inter-publish gap is δ_max = 168 s
/// (the ceiling of the ±40 % cadence jitter) plus the burst spread it can move
/// across — a circle published first in one burst and last in the next waits
/// one spread longer, at most `kPublishStaggerMaxSpread` (30 s). That ceiling
/// is what `kMaxCirclesPerBurst` (11) exists to hold: the per-gap floor is 3 s,
/// so a twelfth circle would push the spread to 33 s and a twenty-second to
/// 63 s, at which point a peer's kind-445 has ALREADY expired when its
/// replacement is created. A burst therefore publishes at most eleven circles
/// and leaves the rest due. The scheduled worst case is ≤ 198 s against a
/// 228 s TTL, leaving the full 30 s of `kTtlNetworkBufferSeconds` for clock
/// skew and propagation.
///
/// **What the cap does NOT fix on its own — and what the roster bound does.**
/// The burst slice is strict round-robin, so a deferred circle's worst service
/// period is `ceil(N / 11)` bursts, not two at every roster: 2 intervals at
/// N = 12…22 (336 s worst, 366 s once the burst-position differential is
/// added), 3 at N = 23…33 (504 s), and 4 or more from N = 34, where even the
/// best case (288 s) is past the retention on every publish. From the twelfth
/// circle up there is therefore a coverage hole, and no arrangement of the
/// publishes closes it: `n` events more than `kPublishStaggerMinGap` apart
/// cannot fit inside the 60 s the retention leaves above the cadence ceiling
/// once `n > 31` — a different bound from the service period above, because it
/// is about one burst's spread rather than how many bursts a circle waits.
/// Closing both needed a roster bound or a longer retention, and the owner took
/// the roster bound on 2026-09-09: `kMaxCirclesPerAccount` (10) refuses the
/// eleventh circle at creation and at accept, so every ladder rung above is
/// UNREACHABLE in production while it holds. The rungs stay documented because
/// the deferral code stays too, and lifting the bound re-opens them exactly as
/// written. See `kMaxCirclesPerBurst` and `kMaxCirclesPerAccount`.
///
/// Both halves of that ladder are pinned: the round-robin period by `a deferred
/// circle waits ceil(N / kMaxCirclesPerBurst) bursts`
/// (`test/providers/location_publish_scheduler_provider_test.dart`, which
/// drives real ticks over both sides of every rung) and the seconds by `and
/// past the cap, the deferral ladder in SECONDS`
/// (`test/services/publish_stagger_test.dart`, which reads them off the cadence
/// constants; its rung table is a literal, so moving the cap forces an edit
/// there). ONE limit on the quotient, and it is not the one this comment used
/// to name: the period is ABSOLUTE, because `_rotation` outlives
/// `stopScheduling()`/`startScheduling()` and outlives an emission reporting
/// nothing eligible, so neither a backgrounding nor a failed roster read
/// re-phases whose turn it is (`a deferred circle is not deferred again by
/// every resume`, `a transient empty roster emission does not re-phase whose
/// turn it is`, `a roster change keeps survivors' places in the queue`). It is
/// a period of TURNS though, and a turn is a SELECTION and not a publish — the
/// rotation advances when the tick FIRES, ahead of the chain, the window and
/// the sink — so a slice that loses its turn without publishing (a refused
/// window, a pause under it, an iOS burst the coordinator drops) waits its
/// whole period again: one more burst at N ≤ 11, up to 336 s against the 228 s
/// retention, and another `ceil(N / 11)` past the cap. The
/// limit that remains is that the quotient bounds what the SCHEDULER hands
/// over, not what a background pass publishes: the iOS coordinator folds a
/// second tick into a running burst (`BackgroundBurstCoordinator._joinable`),
/// so one pass may publish more than `kMaxCirclesPerBurst` — reachable only at
/// N ≥ 12, already past the roster the cap's arithmetic covers. What still
/// rewinds the queue is `build()` (a fresh container, or
/// `IdentityNotifier.deleteIdentity`'s invalidate) and a process restart, which
/// does not persist it; because the roster keeps `filterPublishEligibleCircles`
/// order (`getVisibleCircles()` orders by `updated_at DESC`) that rewind
/// re-serves the SAME first slice — a deterministic re-service, not a re-phase
/// — and the tail's gap across it is bounded by resume frequency rather than
/// unbounded, because the uncapped one-shot (`locationPublisherProvider`) fires
/// on cold start, on motion, on accept/create and on a resume more than 30 s
/// after the last one (`MapShell`'s resume debounce sits ABOVE its invalidate).
/// From 21 circles that cover would be a probability rather than a promise —
/// the one-shot's own spread outlasts `kLocationPublishOverlapGuard`, so the
/// next trigger's invalidate marks the burst in flight superseded and it stops
/// where it stands, with the replacement re-shuffling from the start — and that
/// too is out of reach at `kMaxCirclesPerAccount`.
///
/// The spread cuts BOTH ways on the two timer-driven planes: the tick is a
/// device-level timer, so a circle that trails one burst and leads the next
/// publishes `I − spread` apart — 63 s at two circles, 42 s at eleven, against
/// a disclosed 72 s floor. That is a battery and metadata cost, never a
/// coverage one — a circle publishing at `I − spread` spends one wake sooner
/// than the nominal cadence, which model E prices off the wake COUNT (E-A2,
/// `docs/POWER_EFFICIENCY_PLAN.md` §6.5a): ESTIMATED, never measured, and the
/// metadata half is the extra `created_at` a relay sees. It is the price of a
/// burst order that is a fresh CSPRNG permutation every time.
/// **The floor is an FGS property**: only the
/// foreground service tracks a per-circle due, and `nextBurstDue` never re-arms
/// a circle sooner than `kLocationPublishMinInterval` after its own publish, so
/// no gap it schedules falls below the disclosed minimum. Swept, per API
/// regime, in `background_fix_request_test.dart` (`INV-CADENCE-FLOOR`).
///
/// That margin is also what the Android foreground service's REALIZED gap
/// spends: it publishes on a platform delivery, which arrives a TTFF late.
/// One case exceeds the margin, and it is the only one — API 23–30 (no
/// delayed register, so the regime pays TWO acquisitions per registration)
/// with a 30 s cold TTFF and a long jittered interval: the realized gap
/// reaches the retention when `J + rho + sigma ≥ 178 s` and tops out at
/// 248 s, so a peer's marker expires for at most 20 s before the next
/// publish replaces it. Swept and pinned, per API regime, in
/// `test/services/background_fix_request_test.dart`; closing it would mean
/// shortening the request interval on every device, GNSS duty cycle included.
///
/// **The iOS background burst spends the same margin, and this file used to be
/// silent about it.** A burst's HEAD — `openBackgroundBurst`
/// (`kBurstConnectBudget`, 5 s) + `waitBacklogSettled` (`kBurstBacklogBudget`,
/// 5 s) + `openBurstPublishWindow` (up to `kOneShotLocationTimeout`, 30 s) —
/// sits between the tick and the burst's first publish, and it VARIES between
/// bursts, so it enters the realized gap as a differential exactly as the burst
/// offset does. Worst case the gap is `168 + 40 + spread`: 235 s at FOUR
/// circles and 238 s from five up, where the spread saturates — so iOS
/// background sharing is inside the 228 s retention only up to THREE circles,
/// which is an ordinary roster and not a corner of one. Unlike the Android term
/// above, no test pins it. Two further terms push the NEXT burst late rather
/// than this one: a due maintenance fold (a `KeyPackage` tick waits
/// up to 60 s for the login publish to settle) and the uncapped Rule-13
/// teardown drain, both of which the burst's own bound
/// (`background_burst_coordinator.dart`'s `burstBound`) excludes by design
/// because neither is boundable. In practice the head is ~1-6 s — the connect
/// is a warm WebSocket and the fix is served from the location stream's cache
/// — so this is a worst case rather than a steady state, but it is a real one
/// and it is not covered by the 60 s the retention reserves.
///
/// **A third realized-gap term, and the only one that SCALES with the roster.**
/// The publish pass is serial, and the stagger buys separation on top of each
/// publish rather than inside it. The foreground `_pacedPublish` measures the
/// gap from the previous publish's START, so its span is `Σ max(gap_i, dur_i)`;
/// the background pass awaits the gap AFTER the previous publish returns, so
/// its span is `Σ (dur_i + gap_i+1)` — strictly additive. One publish is priced
/// at `kBurstPublishBudget` (10 s). At `kMaxCirclesPerAccount` — the largest
/// burst a bounded roster can produce — the realized span therefore reaches
/// ≈90 s (foreground shape) or ≈120 s (background), and ≈100 s / ≈130 s at the
/// burst cap one circle further, against the 30 s `kPublishStaggerMaxSpread`
/// the SCHEDULE promises. Unlike the two head terms above it lands TWICE: once
/// in a deferred circle's realized gap,
/// and once in the duration-shaped circle-count estimator a relay reads off the
/// burst's connect-to-disconnect span (`PUB-COALESCE`).
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
/// upward). The one publish it gates is the motion-triggered one
/// (`MapShell._guardedPublish`, `map_shell.dart:1130-1136`, reached only from
/// the motion trigger at `:1122`). The `didChangeAppLifecycleState(resumed)`
/// branch is NOT gated by it: resume unconditionally SETS `_lastPublishTime`
/// (`map_shell.dart:1695`) — which is precisely what makes the guard suppress
/// a motion trigger firing seconds after a resume. The same 60 s doubles as
/// the resume re-anchor throttle window (`MapShell.shouldReanchorOnResume`,
/// `map_shell.dart:168-174`).
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

/// Minimum spacing between two runs of the one-shot resume extras.
///
/// The extras are the resume work that is a REPEAT of something already on a
/// periodic timer: the KeyPackage/relay-list probes, the public-profile
/// refresh, the location prune and the tile-cache eviction. Each of them
/// re-runs on its own schedule anyway, so a shade-pull glance that repeats them
/// buys no freshness — it buys relay round-trips and disk work. Ten glances an
/// hour used to be ten of each.
///
/// Derived, not chosen: 10 minutes is `keyPackageMaintenanceInterval`, the
/// SHORTEST of the extras' own timers (the relay-list sweep is 30 min, the
/// health sweep 15 min, the profile anti-entropy sweep 45 min after a 10 min
/// initial delay, the prune hourly). A window longer than the shortest timer
/// would let the throttle, rather than the timer, decide that task's cadence;
/// a shorter one would re-run work whose own schedule has not come round.
/// Pinned against that constant by `resume_extras_provider_test.dart`.
///
/// What is NOT an extra, and therefore never behind this window: the immediate
/// resume publish, the `memberLocationsProvider` invalidation (both are
/// promises the user can see) and the engine re-anchor (which has its own 60 s
/// guard, [kLocationPublishOverlapGuard], because it is a repair, not a sweep).
const Duration kResumeExtrasMinInterval = Duration(minutes: 10);

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
// iOS accuracy profiles (`ios_location_source.dart`)
// ---------------------------------------------------------------------------

/// How long a backgrounded device must go without a
/// [kMotionTriggerDistanceMeters] displacement before the one CoreLocation
/// session drops from `kCLLocationAccuracyBest` to
/// `kCLLocationAccuracyHundredMeters`.
///
/// [kLocationUpdateInterval] (120 s), not a chosen number: the dwell must
/// outlast one nominal publish cadence, so the device is never judged
/// stationary on evidence shorter than the interval whose publish that
/// judgement coarsens. Shortening it coarsens a user who merely paused at a
/// crossing; lengthening it holds the GPS receiver at Best through the window
/// the whole phase exists to remove.
const Duration kStationaryDwell = kLocationUpdateInterval;

/// How long the coarse profile may run without a fix CONFIRMING the anchor
/// before it escalates back to Best.
///
/// `kStreamPositionMaxAge ~/ 2` = 84 s (`~/` is not a constant expression;
/// `location_test.dart` pins the derivation). Half the freshness window, so an
/// escalation that finds the device has in fact moved still has a full 84 s to
/// land a Best fix before the cached coordinate the publish path serves ages
/// out — freshness outranks power, and this is where that ordering is spent.
///
/// It also bounds the worst case in poor coverage: with nothing usable being
/// delivered the controller cycles [kStationaryDwell] at Best, then this at
/// 100 m, i.e. up to ~59 % of the time at Best — arithmetic on those two
/// constants, so ESTIMATED and never measured
/// (`docs/POWER_EFFICIENCY_PLAN.md` §6.5a, E-I10). That is no worse than
/// today's 24/7 Best. The profile-duty column of `docs/POWER_MEASUREMENT.md`
/// is what would check it against a device, and that column is DEFERRED: it
/// comes from a `locationd` console trace on a physical iPhone, and there is
/// none (§2.5).
const Duration kStationaryConfirmMaxAge = Duration(seconds: 84);

/// How old the confirmed Best ANCHOR itself may become before the session
/// escalates to take a real fix — however many coarse fixes have confirmed it.
///
/// The SECOND escalation trigger, and the one that fires where the first
/// cannot. [kStationaryConfirmMaxAge] only ever fires when *nothing* confirms;
/// a stationary device whose coarse fixes keep confirming re-arms it
/// indefinitely, and the wire timestamp of a published location is the instant
/// of the PUBLISH (`haven-core/src/location/types.rs`, `LocationMessage::new`
/// stamps `Utc::now()`), never the instant of the fix. Without a ceiling a
/// peer's marker therefore reads "just now" for a coordinate taken hours ago
/// and up to [kMotionTriggerDistanceMeters] +
/// [kStationaryConfirmMaxAccuracyMeters] wrong. Putting the true fix age on
/// the wire would be a new wire field, which is forbidden, so the age is
/// BOUNDED instead of disclosed (OD-P3-e).
///
/// Five minutes is `kMemberAgePillThreshold` (`widgets/map/member_marker.dart`
/// — the map's age pill and the roster's "last seen" line share it), the
/// owner-chosen age at which Haven starts telling the user a peer's fix is
/// behind. That is what makes this bound statable: **the staleness Haven
/// hides is never greater than the staleness Haven would have shown.** Under
/// that threshold the app deliberately says nothing, so the silent error stays
/// inside the band the app already treats as unremarkable. It is 1.79 ×
/// [kStreamPositionMaxAge] — under the two windows a "second life, never a
/// third" reading would allow — and the honesty bound is the binding one here:
/// the power bound is far looser (see below).
///
/// **What an expiry costs.** One Best DELIVERY, not one dwell: the escalation
/// deliberately leaves the stationary dwell running (`IosProfileController
/// .onDeadline`), so the next Best fix either shows a
/// [kMotionTriggerDistanceMeters] displacement — which the ordinary rule
/// answers with a dwell restart, on GPS truth rather than on the coarse fixes
/// that missed it — or returns the session to the coarse tier at once. A
/// genuinely stationary device pays ~12 excursions of one delivery per hour
/// (≈ 1 % of the time at Best) instead of the ~29 % a
/// [kStationaryDwell]-restarting escalation would cost — both duties are
/// ESTIMATED from the cycle arithmetic and neither has been measured, here or
/// anywhere (`docs/POWER_EFFICIENCY_PLAN.md` §2.5) — and the 200 m
/// undetected displacement of [kStationaryConfirmMaxAccuracyMeters] can now be
/// served for at most this long rather than for ever.
const Duration kStationaryAnchorMaxAge = Duration(minutes: 5);

/// Coarsest fix (horizontal accuracy, metres) that may vouch for the device
/// having stayed put.
///
/// Equal to [kMotionTriggerDistanceMeters] by construction: a fix that cannot
/// resolve 100 m cannot testify about 100 m of stillness, and a fix coarser
/// than the threshold it is compared against would let noise decide. Coarser
/// fixes are ignored outright — they neither confirm nor move the profile, and
/// the [kStationaryConfirmMaxAge] escalation then decides with GPS truth.
///
/// **The bound this buys, stated plainly (OD-P3-d):** while confirming fixes
/// keep arriving, a real displacement below
/// `kMotionTriggerDistanceMeters + kStationaryConfirmMaxAccuracyMeters` =
/// 200 m can go undetected, and the coordinate served to peers is then up to
/// 200 m stale until the next Best fix or the 84 s escalation. Against today's
/// 100 m of Best-grade travel, the background sensitivity is "100 m, judged by
/// fixes no coarser than 100 m".
///
/// The radius is a ~68 % confidence figure, not a hard limit, so a
/// systematically biased coarse fix can sit inside it and keep confirming an
/// anchor the device has genuinely left. That is why the displacement bound is
/// paired with a TIME bound: [kStationaryAnchorMaxAge] escalates on the
/// anchor's own age no matter how many fixes vouch for it, so an undetected
/// 200 m is served for at most five minutes before GPS truth decides
/// (OD-P3-e).
const double kStationaryConfirmMaxAccuracyMeters = kMotionTriggerDistanceMeters;

// ---------------------------------------------------------------------------
// Background service
// ---------------------------------------------------------------------------

/// Repeat interval for the Android foreground-service timer — the WATCHDOG
/// period, not the publish cadence.
///
/// The cadence is delivery-driven: the service holds one platform location
/// request aimed at the earliest due-time (see [kBackgroundFixLeadTime]) and
/// publishes on its deliveries. This timer only covers the states in which no
/// delivery can arrive — the request was never armed, it went silent (indoors
/// on a GNSS-only device the platform's own retry alarms wake nothing), or it
/// errored — so it is a recovery poll, and a tick that finds a live, delivering
/// request does nothing.
///
/// Still [kLocationPublishMinInterval] (72 s): a recovery that publishes a
/// last-known fix must not itself widen a circle's inter-publish gap past what
/// the shortest jittered interval would have been. `kForegroundActiveAtMsKey`'s
/// 144 s staleness window is derived from it.
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
/// On iOS the window is measured from the last CONFIRMATION rather than from
/// the fix itself: a fix at most this old, **or** a Best-profile fix confirmed
/// this recently by a fix of accuracy at most
/// [kStationaryConfirmMaxAccuracyMeters] taken within
/// [kMotionTriggerDistanceMeters] of it. A stationary device therefore keeps
/// serving the Best coordinate it already has instead of paying for a fresh
/// GPS acquisition every 168 s to learn it has not moved. Undetected
/// displacement while confirming stays under 200 m — see
/// [kStationaryConfirmMaxAccuracyMeters]. On Android nothing confirms, so the
/// window is measured from the fix exactly as it always was.
///
/// A confirmation EXTENDS that window but may not remove it: the fix's own age
/// is capped at [kStationaryAnchorMaxAge] however many confirmations arrive,
/// which is what bounds how stale a published coordinate can be (OD-P3-e).
///
/// This is a FRESHNESS bound and never a consent bound. Whether the user
/// still has location access is decided per call by
/// `GeolocatorLocationService._ensureAccessOrThrow()`, and any observed
/// loss clears the cache outright, so this window can never become a tail
/// of publishing after a revoked permission or a switched-off provider.
const Duration kStreamPositionMaxAge = kLocationPublishMaxInterval;

/// `timeLimit` on every one-shot `getCurrentPosition` the app issues —
/// balanced for a cold GPS fix against the UX of a stalled read.
///
/// Also the cost of a REFUSAL that the platform declines to signal. An
/// Android app-op denial silently stops delivering rather than raising an
/// error (`LocationProviderManager.Registration.acceptLocationChange` bails
/// on `noteOpNoThrow`), so a one-shot under one ends here and nowhere
/// earlier — which is why this lives beside the cadence constants rather
/// than inside the service: `b5_permission_revocation_test.dart` sizes its
/// observation windows off it, and a window sized independently of it
/// cannot see the refusal it is waiting for.
const Duration kOneShotLocationTimeout = Duration(seconds: 30);

/// How far AHEAD of a circle's due-time the foreground service asks the
/// platform for its next fix.
///
/// AOSP's own hot-TTFF figure: `GPS_POLLING_THRESHOLD_INTERVAL`
/// (`GnssLocationProvider.java:228`, commented "Typical hot TTFF is ~5
/// seconds") is the request interval above which the framework stops the GNSS
/// engine between fixes, so 10 s is the platform's estimate of what a
/// re-acquisition costs.
///
/// It is a BUDGET, not a margin. Everything between the delivery and the
/// encrypt — the acquisition itself plus the cycle's registration→publish
/// latency — is spent out of it, and only the excess reaches the wire: a
/// circle's realized inter-publish gap is `sampled interval + max(0, spent −
/// this)`. Shrink it and an ordinary hot fix pushes the gap past
/// [kLocationPublishMaxInterval], eating the 60 s the 228 s NIP-40 retention
/// leaves above the jitter ceiling. Grow it past [kBackgroundFixHorizon] and
/// every fix arrives before its circle enters the due window: the cycle
/// publishes nothing, re-registers, and pays one GNSS acquisition per cycle
/// for nothing.
const Duration kBackgroundFixLeadTime = Duration(seconds: 10);

/// Floor on the interval of the foreground service's platform location
/// request — a PLATFORM bound, never a cadence bound.
///
/// `LocationProviderManager.MIN_REQUEST_DELAY_MS` (30 s, `:181`) plus a
/// second. At or below that threshold the S+ manager delivers no historical
/// fix and runs the request CONTINUOUSLY at HIGH_ACCURACY — the 100 % GNSS
/// duty cycle the delivery-driven cadence exists to remove. Above it the
/// delayed-register regime applies: the provider hibernates until `lastFix +
/// interval`, which is what duty-cycles the receiver.
///
/// Do NOT re-anchor this at the last publish. A floor of
/// `kLocationPublishMinInterval` (72 s), or of `72 − kBackgroundFixLeadTime`,
/// starves a SECOND circle whose independent cadence falls 31–71 s after
/// another circle's publish — by up to 41 s, i.e. a 219–239 s realized gap,
/// past the retention. The cadence bound comes from the earliest due-time the
/// request is aimed at; this only keeps the aim inside what the platform will
/// schedule. Pinned by the M-9 sweep in `background_fix_request_test.dart`.
const Duration kMinFixRequestInterval = Duration(seconds: 31);

/// How far past a delivered fix the background cycle looks for circles to
/// publish (`dueKeysUpTo(now + this)`).
///
/// MUST exceed [kBackgroundFixLeadTime]: the fix is deliberately taken that
/// long BEFORE the due-time, so the circle it was taken for is still short of
/// due when it arrives. The surplus (20 s) is also the budget for the cycle's
/// own gates — a registration issued more than `this − lead` after its
/// triggering delivery aims the next fix outside this window.
///
/// 30 s keeps the batching window the 72 s poll used to provide, so a sibling
/// due shortly after is served by the SAME fix instead of costing another
/// acquisition.
///
/// Deliberately NOT `kPublishStaggerMaxSpread` (`publish_stagger.dart`), which
/// happens to be 30 s too:
/// the spread caps how long one publish burst may take (a freshness budget on
/// the shared fix), this decides which circles a fix serves. Re-capping the
/// spread must not silently move the due window, so the two are separate
/// constants — pinned by `location_test.dart`.
const Duration kBackgroundFixHorizon = Duration(seconds: 30);

/// How far a re-computed fix target may move before the background cycle
/// cancels its live location request and issues a new one.
///
/// The loop breaker. A re-registration costs a cancel + listen and, on S+,
/// re-delivers the fix just consumed — which would drive another cycle, which
/// would re-register. Keeping an aligned registration is what stops that.
///
/// Under [kBackgroundFixLeadTime] by construction: a kept registration is at
/// most this far off the new aim, so it can never deliver AFTER the due-time
/// the lead was reserved for.
const Duration kRegistrationSlack = Duration(seconds: 5);

/// Timeout on the scoped `Haven:publish` wake lock the foreground service holds
/// across fix→encrypt→publish→ack→fetch.
///
/// Twice `kBackgroundTeardownDrainBudget` (one relay publish attempt,
/// `mls_session_handover.dart`): the cycle spends one attempt publishing and
/// one fetching. Not derived in code because neither `Duration.inSeconds` nor
/// `Duration * int` is a constant expression; `location_test.dart` pins the
/// derivation, and pins the 30 000 ms against the Kotlin twin
/// (`PublishWakeLock.MAX_TIMEOUT_MS`) that coerces every request, so the two
/// sides of the channel cannot drift.
const Duration kPublishWakeLockTimeout = Duration(seconds: 30);

/// How long a background cycle whose fix cache is COLD waits for the platform
/// to deliver, before it falls back to the one-shot request.
///
/// The first cycle after a foreground→background handoff is the case: the
/// service isolate builds its own `GeolocatorLocationService`, so the fix the
/// map just had is not in its cache. On Android S+ a registration whose
/// interval exceeds `MIN_REQUEST_DELAY_MS` is answered IMMEDIATELY with the
/// provider's cached last location (`LocationProviderManager:868-898`), so the
/// fix that spares this cycle a 30 s HIGH_ACCURACY one-shot is already in
/// flight when the registration returns — the wait only has to outlast one
/// event-loop hop, not an acquisition. On API ≤ 30 there is no historical
/// delivery, this lapses, and the one-shot runs exactly as it always did.
///
/// Two seconds rather than a microtask because the plugin binds its Android
/// service ASYNCHRONOUSLY and `onListen` returns silently until it is bound
/// (`StreamHandlerImpl.java:108-111`); and far under
/// [kOneShotLocationTimeout], so waiting can never cost more than the fallback
/// it exists to avoid.
const Duration kFirstDeliveryWait = Duration(seconds: 2);

/// Payload the UI isolate sends the foreground-service task when it pauses.
///
/// Presence-only, by construction: the string is the whole message. It says
/// that the UI released publishing, never who the user is, where they are or
/// which circles exist — the task re-reads every one of those from its own
/// gates. It is delivered in-process (`FlutterForegroundTask.sendDataToTask` →
/// `ForegroundService.sendData`), so it reaches no relay and no other app.
///
/// It is a PROMPT, never an authorisation: `onReceiveData` answers it by
/// running the ordinary publish cycle, which reloads preferences and re-runs
/// the foreground-ownership and disclosure gates before anything is collected.
/// A signal that arrives while the ownership stamp is still fresh therefore
/// registers nothing.
const String kForegroundPausedSignal = 'haven.foreground.paused';

/// Payload the UI isolate sends the foreground-service task when it resumes.
///
/// Presence-only for the same reason as [kForegroundPausedSignal]. It only
/// ever REMOVES capability: the task cancels its platform location request the
/// moment it arrives, so the two isolates never hold one at the same time.
const String kForegroundResumedSignal = 'haven.foreground.resumed';

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

/// SharedPreferences key recording that Android still applies battery
/// optimization to Haven (the user declined the exemption, or revoked it
/// later).
///
/// Persisted rather than re-probed on every page build because the answer is
/// only obtainable from the Android plugin, and the page that surfaces it also
/// renders on platforms and test hosts where that plugin is absent. Written by
/// `BackgroundSharingNotifier.setEnabled` on every Android enable and by
/// `BackgroundLocationManager.openBatteryOptimizationSettings` on return from
/// the system screen. Android-only: never written on iOS, so it stays absent
/// (= not denied) there.
const String kBatteryOptimizationDeniedKey =
    'haven.battery_optimization_denied';

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
