# Power Efficiency — Implementation Plan

**Status:** PLAN v3.1 — 2026-08-29: de-scoped the same day for the owner's removal of the Settings → Privacy page and every `privacy*` ARB key (13 locales): every copy round, copy-tie test and disclosure edit that targeted that page is gone; the behaviours, the invariants (now without disclosure keys — a permitted state since 2026-08-29) and the surviving settings/notification copy work are unchanged (§8). v3 — 2026-08-29: two independent review rounds by 8 reviewers (security, Marmot/MLS, Rust, iOS, Android, Flutter, test/CI, UI/UX); round 1: all BLOCKER/MAJOR findings applied, MINOR/BAR-RAISE applied unless listed under "Not applied"; round 2 (confirmation): every round-1 item confirmed LANDED or DECLINED-ACCEPTED and all confirmation-round items applied (§8); OWNER DECISIONS TAKEN 2026-08-29 (all recommendations accepted — see §4); previously awaiting owner decisions OD1/OD3/OD4/OD4-b/OD-P2-2/OD-P2-3/OD-P3-b/OD-P3-c; nothing implemented.

**Purpose.** A 2-member iOS+Android circle with background sharing ON drained both phones and showed a
permanent blue location pill on the iPhone, although Haven publishes only every 72–168 s. This document is
the single source for fixing that without moving anything on the wire, weakening a promise, or reopening
the 2 h silent wedge of `docs/BACKGROUND_SHARING_FAILURE_ANALYSIS.md` (FA). It merges four expert drafts
(verification/CI, iOS, Android, network) over one synthesis; every file:line was re-read in the working
tree on 2026-08-29 (uncommitted units A–F present) unless tagged **I** (inferred) or **U** (unknown);
**V** = verified in code or a primary doc. Conflicts between drafts are resolved here as "decision + why".

**How to read / how to use with agents.** §1–§2 are the facts; §3 the FINAL decisions D0–D8 (do not
re-litigate — if a decision is wrong, say so in review with evidence); §4 the owner decisions; §5 one section
per phase P0–P6 with the template headings; §6 the cross-phase verification map, risk register, rollback
story and the hardware protocol; §7 the consolidated appendices (ARB keys, guards, manifest, red tests,
V/I/U ledger); §8 the review record (v2: what each of the eight reviewers changed, and what was declined with
evidence). Each phase runs as **an implementer wave** (one agent per work packet, packets marked
sequential/parallel, each with its own done-criteria and commands) followed by **an independent reviewer
wave** (the phase's reviewer checklist + §6.1 "lands together" rows are the merge gate). Phases are
independently shippable and independently revertible (§6.4). Commands every packet ends with unless the
packet says otherwise: `cd haven && flutter test && flutter analyze`, `cd haven-core && cargo test && cargo clippy -- -D warnings && cargo fmt --check`,
the touched guards' `--self-test`, `scripts/ci/check_privacy_invariants.sh`, `scripts/ci/check_coverage.sh --static-only`.

---

## 1. The field report and root causes

Field report (2026-08-29): iOS + Android, one circle, background sharing ON, both mostly stationary; heavy
drain on both; a CONSTANT blue status-bar pill on iOS. Reference apps (Life360, Snapchat, Find My) show no
constant pill. Publish cadence is `kLocationUpdateInterval` 2 min ± 40 % CSPRNG jitter = [72, 168] s
(`haven/lib/src/constants/location.dart`).

### 1.1 Root causes (ranked; V unless marked)

| # | Cause | Where | Why it costs | Why the pill |
|---|---|---|---|---|
| R-A | iOS: ONE continuous `startUpdatingLocation` session at `kCLLocationAccuracyBest`, `distanceFilter = None`, `pausesLocationUpdatesAutomatically = NO`, 24/7 while background sharing ON; nothing lowers it on pause; > 98 % of ~1 Hz fixes are discarded. Apple's own recommended shape for background continuity is "no auto-pause AND a coarse accuracy" (doc on `pausesLocationUpdatesAutomatically`); OwnTracks calls this configuration "Move mode" (~25 %/day vs 1–2 %/day). | `geolocator_location_service.dart:653-674`; `geolocator_apple GeolocationHandler.m:122-135` | GNSS cannot be duty-cycled by the OS; CPU never idles (per-fix channel delivery) | — |
| R-B | iOS: three independent, each-sufficient pill causes, all ON: (A) a When-In-Use app doing background location (pill mandatory, flag ignored); (B) `showsBackgroundLocationIndicator = true` (only matters under Always; default false); (C) a held `CLBackgroundActivitySession` ("just creating the session displays the indicator", WWDC23 10180; Apple positions it as the *When-In-Use* mechanism). Under Always only B and C apply — both Haven's choice. | service `:660-661`; `HavenBackgroundSessionHandler.swift:134-136` | (C) also keeps the app executable, which is why everything else keeps running | constant because the session never pauses and C is held for the app's lifetime |
| R-C | Android: the UI isolate's `locationStreamProvider` (`AndroidSettings(distanceFilter: 1, intervalDuration: 1 s, forceLocationManager: true)`, non-autoDispose) is NEVER cancelled on pause; the FGS lifts the uid to foreground importance so the OS 30-min background throttle never applies → 1 Hz `QUALITY_HIGH_ACCURACY` GNSS for the whole background session. On API 31+ the plugin's LocationManager path picks the platform `fused` provider (GPS-only on 23–30). The FGS additionally issues a 30 s HIGH_ACCURACY one-shot per 72 s tick (its own stream cache is always empty). | `location_provider.dart:42-54`; `map_shell.dart` `_onPaused`; `background_location_task.dart` | continuous GNSS ≈ 60–85 mA (Karki & Won) | no pill on Android; same drain |
| R-D | Android: `flutter_foreground_task` holds a permanent, untimed `PARTIAL_WAKE_LOCK` (Haven never sets `allowWakeLock: false`); the 72 s repeat is a coroutine `delay()` loop that NEEDS the lock; battery-optimisation exemption also requested. CPU never suspends while background sharing is ON. Every reference app except Traccar holds no wake lock. | `background_location_manager.dart:134-144`; plugin `ForegroundService.kt:288-289,427-435` | AP never reaches suspend | — |
| R-E | Both: nostr-relay-pool 0.44.3 defaults on BOTH relay pools (engine `Client` + publish `RelayManager` `Client`; the FGS isolate keeps a third): unconditional WebSocket ping every 55 s per socket, `sleep_when_idle = false`, reconnect never gives up. Radio energy is per WAKE not per byte (LTE ≈ 13 J per isolated wake; 10 KB ≈ 0.05 J). Keepalives ≈ 70–90 % of background network wakes: ≈ 150 wakes/h iOS-bg, ≈ 140 Android-bg for one circle (I). | `session.rs:92-105,531`; `manager.rs:291`; crate `constants.rs:34` | modem never reaches deep idle on cellular | — |
| R-F | Both: nothing background-gated on iOS-bg: N per-circle publish timers + motion trigger + per-fix `MapPage` FFI/`setState`, KeyPackage 10-min / relay-list 30-min / subscription-health 15-min timers (the health tick's 684 s silence window < 900 s tick guarantees a REQ re-issue on every quiet circle; any relay drop → full re-anchor incl. **7-day** inbox replay because the inbox `since` ignores the subscribe phase). WorkManager spins a FlutterEngine every 15 min only to no-op while the FGS is alive. `SharingHealthBanner` `_rerender` 72 s timer runs while backgrounded (V for existence; U whether the widget is disposed on pause — §5.1 rule). Resume fires an N-circle burst + 30443/10050/10002 probes + kind-0 fetch + engine re-anchor (7-day replay) + 2 prunes + tile eviction. | pipeline audit H3–H11; `sharing_health_banner.dart:195-207` | many small wakes; the 7-day replay is the big one | — |
| R-G | Foreground publish plane = N independent timers for N circles (each its own access gate, MLS encrypt, 3-relay publish, DB write, health refresh); the Android FGS already batches due circles into one wake + one fix. Per-circle timing decorrelation is already defeated at shared relays by the multiplexed `#h` REQ (one REQ names all of a relay set's circles) and the single publish socket; only the archive `created_at` equality leak is real, and a ≥ 2 s stagger closes it. | `location_publish_scheduler_provider.dart`; `per_circle_due_tracker.dart:178-191`; `planes/mod.rs:52-57,160-203`; `publish_stagger.dart` | linear in circle count | — |

### 1.2 Documentation drift found in passing (fixed by P0 unless a later phase changes the truth again)

| file:line | Wrong today | Truth (source) |
|---|---|---|
| `docs/M7_BACKGROUND_SHARING.md:3-8`, `:332-336`, `:462` | `liveSyncEnabled` "stays `false`" | defaults TRUE since M11 Phase B (`bool.fromEnvironment('HAVEN_LIVE_SYNC', defaultValue: true)`, guard 14b) |
| `M7:838-840`, `M7:1196-1199`, `docs/CI_HARDENING_BACKLOG.md:2110`, `FA:58-62` | "1 m distance filter in background" | the bg-on iOS arm carries `kCLDistanceFilterNone` (`-1`, Unit F 2026-08-28); the opt-out arm keeps 1 m |
| `docs/M11_ROLLOUT.md:117`, `haven-core/SECURITY.md:873-878` | standing socket exists "while the app is in the foreground"; "iOS background suspension drops the socket" | on iOS with background sharing ON the process stays executable and the socket persists, pinging every 55 s (P4 makes the original sentence true again) |
| `SECURITY.md:257-263` | engine keeps its socket "on Android while the foreground service is active — in the background too" | FALSE: `_handOffMlsSession` stops it (`map_shell.dart:1322`); the FGS never starts one |
| `FA:250-253` | Life360/Find My/Snapchat use "kCLDistanceFilterNone, best accuracy, indicator on" | UNCITED and contradicted by the field report; no source claims Best + no filter + pill |
| `haven/lib/src/constants/location.dart:49-50` | overlap guard "gates … the `didChangeAppLifecycleState(resumed)` branch" | resume SETS `_lastPublishTime`; the guard gates motion-triggered publishes only (V-tag `_onResumed` before editing) |
| `haven-core/src/relay/live_sync/config.rs:268-271` | `HEALTH_CHECK_SECS = 900`, `RELAY_LIST_SECS = 1800` | dead (no reader outside the definitions — V; live timers are Dart, `maintenance_scheduler_provider.dart:101-133`) |
| `haven/lib/src/services/ios_location_auth_service.dart:3-5` | "Continuous background location delivery … requires 'Always'" | background continuation needs only When-In-Use (foreground-started session); Always buys the receive-only SLC/region relaunch (`geolocator_location_service.dart:641-643`) |
| `haven/android/app/src/main/AndroidManifest.xml:117` | cites `docs/MAP_AND_PRIVACY_BACKLOG.md` | file does not exist; point at `docs/privacy/README.md` + `haven-core/SECURITY.md` (the behaviour statements that remain after the Privacy page's removal, 2026-08-29) + note the Play declaration is console-side |
| `docs/WN_RELAY_EPOCH_SYNC_MIGRATION.md:178,:243` | "Android 15 6-hour FGS timeout … `location` is NOT exempt" | U/likely wrong — the 6 h cap targets `dataSync`/`mediaProcessing`; verify against developer.android.com "Foreground service timeouts" (Android 15) and correct with URL + date |
| `docs/MESH_LOCATION_RELAY_DESIGN.md:181,:422-423` | per-send jittered TTL `[interval, 2×interval]` | retention is the group's 0x8005 component (228 s); per-send jitter retired 2026-08-13 (SECURITY.md) |
| `FA:218-222` | "iOS MAY resume publishing after a jetsam kill + movement" | contradicts `INV-L-IOS-WAKES-RECEIVE-ONLY`. Today the hole is REAL: a relaunched process's cold-start publish (`map_shell.dart:499-501`) reaches `getCurrentLocation()` whose backgrounded shortcut (`:711-724`) is keyed off `_foregroundActive`, written only by MapShell's `paused` dispatch — if that dispatch is not delivered on a background launch (V-P1-1, U) the plugin one-shot starts a manager from the background. P3 closes BOTH halves: the native owner refuses a background-capable START, and the shortcut consults the native `backgrounded` status (D1 (vi)); P0 marks the FA sentence "unverified today; closed by P3" |
| `docs/privacy/privacy_invariants.json` `accepted_deviations[RC1].summary` | "One persistent client per relay … over the same connection" | INCOMPLETE today: two `Client`s per process (engine `session.rs:102`, publish `manager.rs:291`) — the publish socket is a second connection from the same address. The user-facing sentence that carried the "one connection" claim left with the Privacy page (2026-08-29), so no copy is affected; P0 records the two-socket fact in the RC1 summary (prose only, no key/status change — no ratchet item); P4 narrows the RC1 statement (§5.4) |
| `docs/WN_RELAY_EPOCH_SYNC_MIGRATION.md:312-313` | module-layout excerpt lists `HEALTH_CHECK_SECS`/`RELAY_LIST_SECS` | the constants are dead and P0 deletes them — the excerpt is edited in the same commit (nothing else references the names — V) |

Line-citation drift in this plan (harmless; P0-B re-reads before editing): `background_location_task.dart:586-594` → `:592-600` (`onReceiveData`), `:519` → `:525` (drain), `:662` → `:668`, `:1607-1616` → `:1610-1620`; `constants/location.dart:146-158` → `:131-148`; `map_shell.dart:1315-1318` is the COMMENT — the bounded stop is `_handOffMlsSession` `:899-916`; `:1225-1230` is `_onDetached`'s UNBOUNDED stop.

---

## 2. Platform facts that bound the design (V unless marked)

### 2.1 iOS

- iOS has NO periodic background wake: BGAppRefresh is opportunistic, BGProcessing idle-only, `beginBackgroundTask` ~30 s one-off, silent push excluded (no APNs by policy), audio/VoIP forbidden (2.5.4), SLC floor 500 m / 5 min. "GPS off, wake every 2 min" is impossible. The realistic minimum is a CHEAP continuous session that keeps the process alive (timers + sockets survive).
- **The 16.4 rule (Apple DTS, thread 726945, re-fetched 2026-08-29 — V):** an app calling BOTH `startUpdatingLocation()` and SLC keeps delivering in the background iff `allowsBackgroundLocationUpdates = true`, `distanceFilter = kCLDistanceFilterNone` and `desiredAccuracy ≤ kCLLocationAccuracyHundredMeters` (numeric < 1000) with the indicator OFF — or the indicator ON with anything. The "both" precondition is Haven's own case under Always (SLC is Always-gated, `HavenSLCHandler.swift:207-223`); under When-In-Use Haven runs no SLC and the pill is mandatory anyway. Apple's `pausesLocationUpdatesAutomatically` doc recommends "disable + `ThreeKilometers` in the background"; the plan stops at 100 m because of this rule. WWDC24 caveat (V): Core Location "does not take measures to keep apps running continuously when it has nothing to deliver" — whether locationd has something to deliver every few seconds at 100 m / no filter on a desk is I (the `startUpdatingLocation` doc promises nothing periodic) ⇒ "hours stationary" is V-P3-3 and a HARDWARE MERGE GATE for P3 (§5.3), not an acceptance item. `CLLocationUpdate.liveUpdates` auto-pauses (process suspended, socket dies) → breaks the 228 s no-gap invariant → rejected until the protocol has a "stationary since" semantic.
- **Indicator rules:** under **Always** the pill is optional (`showsBackgroundLocationIndicator`, default false, affects ONLY Always apps, toggleable "at any time" on a running manager — QA1965 V) and `CLBackgroundActivitySession` is unnecessary (iOS 18: `CLServiceSession(.always)` taken in the foreground is the requirement per WWDC24 — stated for the modern APIs; whether the legacy `startUpdatingLocation` path is covered is unstated, which is why the `.always` session stays; iOS 17: `allowsBackgroundLocationUpdates` + Always suffices). Under **When-In-Use** the pill is mandatory (QA1965) and honest, and WWDC24 (V) says CL delivers nothing to a backgrounded WIU app without a LiveActivity or `CLBackgroundActivitySession`. Hiding the pill saves nothing by itself; the drain fix is the accuracy tier. Reference apps under Always (Traccar iOS, OwnTracks Move, Overland) never set the flag → no pill. **Provisional Always:** `authorizationStatus` reports `.authorizedAlways` while the second prompt is unanswered (`requestAlwaysAuthorization()` doc, V) although the EFFECTIVE authorization is When-In-Use; `CLServiceSessionDiagnostic` exposes `alwaysAuthorizationDenied` (documented: explicit denial only), `authorizationRequestInProgress` and `insufficientlyInUse` (EMPTY doc abstracts — U semantics), and WWDC24 says the first diagnostic arrives with `authorizationRequestInProgress` already false when authorization is settled ⇒ D2 fails SAFE (WIU policy until a diagnostic positively confirms Always). `locationManagerDidChangeAuthorization` fires at manager CREATION and in the background (V) — D2 must never withdraw an in-use claim from a background callback.
- Where Wi-Fi/cell cannot resolve 100 m (rural, some indoor) the 100 m tier IS GPS, duty-cycled by locationd ("Core Location turns on the hardware it needs", V) — the tier is a power CEILING the OS chooses under, not "Wi-Fi/cell" by definition; the §6.5 template records the observed profile duty.
- **EventChannel error contract (V, `platform_channel.dart:710-721`):** an exception thrown by the platform `listen` call is passed to `FlutterError.reportError` and NEVER added to the stream; only errors the native side pushes through the event sink arrive as `PlatformException`. The iOS engine cancels an existing sink before delivering a new `listen` (`FlutterChannels.mm`, I). ⇒ every native refusal/denial is emitted through the sink (D1).
- `desiredAccuracy` can be changed LIVE on a running `CLLocationManager` (V for the API; the background effect is I — V-P3-2). geolocator cannot express that (start/stop only) and the `-1` vs `0` mapper bug shows plugin fragility. R7 (`M7:1157-1160`, guard check 12): a stream must not be (re)started while backgrounded — CI run 32661622879 is exactly that failure class. ⇒ two-profile accuracy on iOS requires a Haven-owned native `CLLocationManager`.
- `requestLocation()` "does nothing" while the same manager is updating (research §2.2) — a native one-shot needs a second manager, which is why one-shots stay on geolocator (D1).
- Energy tiers (best available measurement, Evgenii 12 h background): 100 m ≈ 0.3 %/h vs 10 m ≈ 1.8 %/h; GPS tiers cost 4–6× the 100 m tier. No Apple mA table exists; every battery claim is a hardware deliverable (`MESH_LOCATION_RELAY_DESIGN.md:401`).
- Stuck-indicator bug (iOS 18/26, DTS forums 771422/783585): after invalidating a WIU activity session the pill can stay stuck; no code mitigation exists (M7 §6 item 0c records it).
- Nothing runs Swift unit tests in CI (`build-check.yml:158` builds only; `RunnerTests.swift` is not executed) — native config is guard-pinned, not test-pinned; runtime pins are the lanes.

### 2.2 Android

- For request intervals > 10 s the GNSS provider/HAL duty-cycles ITSELF: `GnssLocationProvider` sets `mFixInterval = request interval` (`:1034`); with HAL `CAPABILITY_SCHEDULING` the chip is told `minInterval = mFixInterval` (`:1238`) and searches per chip policy with NO framework give-up (U per chip); without it the framework runs the chip at 1 Hz and after each fix with `mFixInterval > GPS_POLLING_THRESHOLD_INTERVAL` (10 s, `:228`, "Typical hot TTFF is ~5 seconds") calls `hibernate()` → `stopNavigating()` + `ELAPSED_REALTIME_WAKEUP` at `now + mFixInterval` from the LAST FIX (`:1338-1344`, `:1401-1409`); a request `≥ NO_FIX_TIMEOUT` (60 s, `:223`) arms a give-up alarm ONLY without `CAPABILITY_SCHEDULING` (`:1254-1261`). Wake lock and alarm are the SYSTEM's (`:327,:423`). Those alarms produce NO app callback when there is no fix — indoors on a GNSS-only device nothing wakes the app (the B-2 finding, D4). (AOSP frameworks/base main, fetched 2026-08-29.)
- **Delivery semantics** (`LocationProviderManager.java`): historical delivery on registration for apps targeting S+ — a cached location younger than `getIntervalMillis()` is delivered immediately when `intervalMillis > MIN_REQUEST_DELAY_MS` (30 s) (`:868-898`, `:181`) ⇒ every re-registration with `I > 30 s` re-delivers the fix just consumed (same `Location` object ⇒ same `timestamp`), and a request with `I ≤ 30 s` gets NO historical delivery and is a continuous request. **S+ delayed register (V, `:2239-2283`, `:2452-2487`):** after cancel+listen the manager DELAYS applying the new registration's provider request by `interval − age(lastLocation)` (a never-delivered registration is treated as having received the cached last location) and applies it at once only when that delay is < 30 s; so after the FGS consumes a fix at `t_f` and re-registers at `R ≈ t_f + δ`, GNSS restarts at ≈ `t_f + I` and delivers at ≈ `t_f + I + TTFF` — this, not the registration instant, is why both HAL scheduling models coincide, and, for `I ≥ 62 s`, cancel+listen within ms costs no extra acquisition on S+ (the provider is stopped on cancel and restarted `I − δ` later); at the 31 s floor with δ > 1 s the delayed register is < 30 s, the provider request applies at once and one extra hot start precedes the hibernate — harmless. The provider never emits EARLY (a hibernating provider sleeps until `lastFix + I`; a scheduling chip is chip-timed); the fastest-interval gate (`delta < minUpdateInterval − min(10 % × interval, 30 s)`, `:174,:177,:947-960`, measured against the registration's last DELIVERED location incl. the historical one) is what the manager would ACCEPT, not what arrives — deliveries are late by TTFF, never early. **API 23–30** run the R-and-below service: no historical delivery, no delayed register; cancel+listen restarts GNSS immediately (one extra hot acquisition ≈ 1–5 s, I) and hibernates from THAT fix → delivery ≈ `R + TTFF₁ + I + TTFF₂`; androidx's final fallback there is `requestLocationUpdates(provider, I, 0, listener, looper)` (`LocationManagerCompat.java:290-297`, implicit fastest interval I/6) — reached only if the greylist reflection fails (I). `dumpsys location` prints each registration as `<CallerIdentity> [bg] Request[<provider> @<TimeUtils.formatDuration> HIGH_ACCURACY(, minUpdateInterval=… only if < interval)(, minUpdateDistance=… only if > 0)]` (`:753-775`; `LocationRequest.toString()`): the FGS request (min interval == interval, distance 0) prints NEITHER suffix; the UI request prints `minUpdateDistance=1.0`; intervals print as `@+1m40s0ms`, never as milliseconds. `dumpsys power` prints held locks with their age: `PARTIAL_WAKE_LOCK 'Haven:publish' ACQ=-12s345ms (uid=…)` (`PowerManagerService.WakeLock.toString`).
- **Plugin registration side-costs (V):** every `LocationManagerClient` registration also installs `addNmeaListener` + `registerGnssStatusCallback` whenever FINE is granted on API ≥ 24 (`NmeaClient.java:70-86`, called at `LocationManagerClient.java:189`, independent of `useMSLAltitude`) — while the GNSS engine navigates for ANY consumer Haven's main thread receives ~1 Hz satellite-status callbacks and several NMEA sentences per second (TTFF seconds outdoors, up to 60 s per interval indoors on non-scheduling HALs); the plugin's `isBetterLocation` (`:46-76,208-217`) drops a newer fix that is > 200 m less accurate within 2 min, so a Dart delivery is a SUBSET of platform delivery; the plugin's `getCurrentPosition` 30 s cap is geolocator's Dart `timeLimit` (`geolocator_android.dart:112-135`) — the native request keeps searching until Dart cancels. A Haven-owned native `LocationListener`/`PendingIntent` registration installs none of the listeners and can name the provider (P2b design, D4).
- **What geolocator sends** (`geolocator_android-5.0.2`): `AndroidSettings` serialises `accuracy`, `distanceFilter`, `timeInterval`, `forceLocationManager` (`android_settings.dart:74-83`); `forceLocationManager: true` → `LocationManagerClient` unconditionally (`StreamHandlerImpl.java:133-135`, `GeolocationManager.java:76-78`); `startPositionUpdates` (`LocationManagerClient.java:148-197`) builds `LocationRequestCompat.Builder(timeInterval).setMinUpdateDistanceMeters(distanceFilter).setMinUpdateIntervalMillis(timeInterval).setQuality(accuracyToQuality(accuracy))` (`:182-185`; best/high → `QUALITY_HIGH_ACCURACY` `:99-112`); provider via `determineProvider` (`:78-97`): `lowest → PASSIVE`, else `fused` on API ≥ 31 when enabled, else `gps`, else `network`. `maxUpdateDelay` is never set (no batching — unreachable and unwanted). A stream with `intervalDuration: 100 s` truly yields a 100 s platform request (androidx core 1.16.0 forwards `minTime = intervalDuration` on every API level).
- Two plugin traps: **re-registration = cancel + re-listen** (`GeolocatorAndroid.getPositionStream` caches `_positionStream` regardless of new settings, `geolocator_android.dart:169-171`; only `onCancel` nulls it `:207-212` → `removeUpdates`, `LocationManagerClient.java:201-205`; a new listen's `currentBestLocation = null` so its first location is always forwarded `:208-217`); **`timeLimit` on a stream is an inter-event timeout that CLOSES the stream** (`geolocator_android.dart:177-191`), which the service maps to `_noteAccessLost('position stream closed')` + cleared cache (`geolocator_location_service.dart:816-819`) → the background profile carries NO `timeLimit`.
- Each Dart isolate has its own `GeolocatorAndroid` + `GeolocatorPlugin` (`GeolocatorPlugin.onAttachedToEngine` per engine, `:64-81`), so two isolates CAN hold two native registrations. The FGS engine registers `GeneratedPluginRegistrant` (`ForegroundTask.kt:49`; geolocator at `GeneratedPluginRegistrant.java:34`); the plugin binds its service asynchronously (`GeolocatorPlugin.java:80`) and `onListen` returns SILENTLY without events until bound (`StreamHandlerImpl.java:108-111`).
- A location-type FGS keeps network + wake locks through Doze and has no 6 h limit; exact alarms are denied by default on 13+/14+, WorkManager is floored at 15 min, so the ONLY reliable ≤ 168 s background wake for a non-exempt app is location delivery itself. geolocator's one-shot is capped at 30 s by its Dart `timeLimit` (the native request searches until Dart cancels). The framework holds a wake lock only while dispatching a fix to the listener; Haven's fix→encrypt→publish→ack path needs its own SCOPED, timed lock (GPSLogger model). `flutter_foreground_task-9.2.2` exposes `FlutterForegroundTaskPlugin.addTaskLifecycleListener(listener)` (`FlutterForegroundTaskPlugin.kt:16-21`) whose `onEngineCreate(flutterEngine)` hands Haven the FGS engine before the task starts (`FlutterForegroundTaskLifecycleListener.kt:6-13`, called at `ForegroundTask.kt:55`); `ForegroundService.onDestroy` runs only on a graceful stop (`ForegroundService.kt:196-216`), `onTaskRemoved` only on swipe (`:218-225`); the Dart `allowAutoRestart` default `true` (`foreground_task_options.dart:13`) arms a 5 s `RestartReceiver` alarm on a non-graceful destroy (`:207-215`), inert only because m7 check 14d keeps that receiver disabled. `ForegroundTask.destroy()` (`ForegroundTask.kt:155-173`) invokes Dart's `onDestroy` ASYNCHRONOUSLY and then calls `onTaskDestroy()`/`onEngineWillDestroy()` synchronously — i.e. BEFORE Dart's bounded drain has started (D4). The plugin's repeat is `delay(interval)` on `Dispatchers.Default` — CLOCK_MONOTONIC, awake time only (I) — under an untimed non-ref-counted `PARTIAL_WAKE_LOCK "ForegroundService:WakeLock"` gated only by `allowWakeLock` (`ForegroundService.kt:426-436`); `PowerManager.WakeLock.acquire(timeout)` on a held non-ref-counted lock re-posts the timeout and `release()` when not held is a no-op (`PowerManager.java:3930-3950, 3984-4000` — V, closes V-P2-3). Ordinary `AlarmManager.set()` alarms of a battery-exempt uid DO fire in Doze (`AlarmManagerService.java:2734-2740`, `FLAG_ALLOW_WHILE_IDLE_UNRESTRICTED`) but are inexact (heuristic window, up to ~75 % late); exact alarms need `SCHEDULE_EXACT_ALARM` (default-denied on 13+, Play-policed, a special-access prompt). `play-services-location:21.2.0` is compiled in unconditionally (F-Droid gap is build-classpath; out of scope). geolocator 5.0.2 has NO provider selector: `AndroidSettings` maps `accuracy` to quality only (`lowest` → PASSIVE), `fused` on API ≥ 31 whenever enabled (`LocationManagerClient.java:78-112`) — a "`gps` provider fallback" does not exist on the plugin path.

### 2.2a Flutter / Riverpod lifecycle facts that bound P1 and P4 (V; riverpod 2.6.1, flutter_riverpod 2.6.1, Flutter 3.41)

- Flutter disables frames on `paused`/`hidden`/`detached` BEFORE observers run (`SchedulerBinding.handleAppLifecycleStateChanged`, `scheduler/binding.dart:414-427`; `WidgetsBinding` calls `super` first, then `observer.didChangeAppLifecycleState`); `scheduleFrame()` bails while `!framesEnabled` (`:946-947`).
- A `StateProvider` write notifies `watch`-dependents SYNCHRONOUSLY (`element.dart:567-603` → `invalidateSelf` `:292-298`), and `invalidateSelf` runs `runOnDispose()` at once — for a `StreamProvider` that CANCELS the old subscription on the spot (`async_notifier/base.dart:425-433`) — but the re-`create` is only SCHEDULED (`scheduler.dart:65-81`) through flutter_riverpod's vsync, `Future.microtask(markNeedsBuild)` on the `UncontrolledProviderScope` element (`framework.dart:330-343`), i.e. inside a FRAME. A second write before the rebuild early-returns (`:293`): exactly ONE deferred rebuild, at the first frame after resume, with the value written LAST.
- Consequences: (1) no provider body executes while the app is paused unless something forces a flush (`ref.read(provider)` → `flush()` `:320-326`; nothing in `lib/` does so while paused — consumers are `map_page.dart:538` listen, `map_shell.dart:1061` listenManual, `location_access_provider.dart:239` listen); (2) a lifecycle RELEASE that rides a rebuild happens at RESUME, not at pause; (3) `ref.invalidate(locationStreamProvider)` from the access watchdog while paused (`location_access_provider.dart:523`) cancels the running stream NOW and rebuilds at resume; (4) `ProviderContainer` unit tests do NOT reproduce this (without a Flutter vsync the scheduler uses `Future(task)`, `scheduler.dart:8-10`) — a test that pumps one event-loop turn happily executes a paused branch that production never runs; (5) nothing in a background burst (P4) may depend on a `ref.watch`-driven rebuild — only Timers, `listenManual` callbacks, `ref.read` and Notifier writes run while paused.
- `riverpod_lint`/`custom_lint` are not in `pubspec.yaml` (V) — `ref.read` inside a provider body is legal and must be documented as deliberate where used.

### 2.3 Network (nostr-relay-pool 0.44.3 / nostr-sdk 0.44.1, pinned; no fork)

| # | Fact | Where |
|---|---|---|
| F1 | `RelayOptions::default()`: `reconnect: true, sleep_when_idle: false, idle_timeout: 300 s, retry_interval: 10 s, adjust_retry_interval: true`; builders `.ping(bool)`, `.reconnect`, `.sleep_when_idle`, `.idle_timeout` | `options.rs:34-49, :92-106, :150-160` |
| F2 | Default flags `READ\|WRITE\|PING`; `has_ping()` public; `Relay::flags()/opts()/status()/stats()` public | `flags.rs:24-28, :181`; `relay/mod.rs:221-256` |
| F3 | `PING_INTERVAL = 55 s` const; pinger loops unconditionally and checks `flags.has_ping()` live each tick; `SLEEP_INTERVAL` 60 s | `constants.rs:34, :38`; `inner.rs:982-994` |
| F4 | `should_sleep`: false if `!sleep_when_idle`, false if ANY subscription registered, else idle ≥ `idle_timeout` from `last_activity_at` (outbound only) or `connected_at`; monitor runs every `SLEEP_INTERVAL` inside `post_connection` only | `inner.rs:444-476, :480-505, :760-790, :965-978` |
| F5 | `can_connect()` = `Initialized \| Terminated \| Sleeping`; `reconnect: false` ⇒ `Terminated` after a drop, loop exits; `reconnect: true` retries every 10–60 s forever | `status.rs:120-122`; `relay/mod.rs:288-300, :358-386`; `inner.rs:572-597` |
| F6 | **The `add_relay` flag-OR trap:** `RelayPool::add_relay(url, opts)` → `Ok(false)` if present (flags untouched); `Client::add_relay` → `compose_relay_opts` then `flags(READ\|WRITE\|PING)` and on an EXISTING relay `relay.flags().add(flag)` — i.e. any later `Client::add_relay` on the same URL silently re-enables PING | `pool/mod.rs:266-300`; `client/mod.rs:232-313, :329-336`; `client/options.rs:124, :158-169` |
| F7 | `Pool::disconnect` → `Terminated` (not shutdown); `Client::shutdown` empties the pool (engine `stop_inner`) | `pool/mod.rs:503-512`; `inner.rs:1255-1270`; `session.rs:1050-1080` |
| F8 | Haven publish client: `Client::builder().build()`, `client.add_relay` ×3 (`:307`, `:617`, `:1253`), `try_connect_relay(CONNECTION_TIMEOUT = 5 s)`, `send_event_to` under `DEFAULT_TIMEOUT = 10 s`, `publish_with_retry(MAX_PUBLISH_ATTEMPTS = 3, PUBLISH_RETRY_BACKOFF = 2 s)`; `shutdown` = `disconnect` | `manager.rs:35, :86, :105, :112, :291, :303-337, :355-450, :610-630, :1240-1262, :1531-1533` |
| F9 | Engine client: `ClientOptions::default().verify_subscriptions(false).automatic_authentication(false).pool(...)`; relays via `client.add_relay` at start and `subscribe_circle`; auto-commit publisher = `client.clone()` (engine sockets) | `session.rs:92-105, :531-541, :737, :1246`; `auto_commit.rs` |
| F10 | `Sleeping` is in NO health bucket; `run_monitor` maps it to `None`; comments say "the engine never enables sleep_when_idle" | `session.rs:1540-1574, :1904-1940`; `health.rs` |
| F11 | `resume_after_background`: lifecycle lock → `connect()` → `wait_for_connection(5 s)` → shutdown check → `register_and_subscribe(active, Resubscribe)` → `BackgroundResumed` | `session.rs:1117-1170` |
| F12 | `stop_inner`: `unsubscribe_all` (bounded 10 s) → `client.shutdown()` → `router.clear()` → `forget_inbox_subscription` → `SessionStopped`; `stop` is terminal (salt zeroized; `start` on a stopped core fails closed) | `session.rs:1050-1112` |
| F13 | Anchors: `open_generation` carries an unapplied hold-back; `forget` DROPS it; `suppress_open_generations` burns the EOSE advance and keeps it; `note_delivery_gap` = suppress group + inbox (the Rule-12 path) | `anchor.rs:166-175, :207-215, :230-235`; `processor.rs:360-363` |
| F14 | Worker looks `(relay, sub)` up in the router first; unknown ⇒ dropped; EOSE → `anchor_end_of_stored_events`; `CLOSED` → `repair.note_closed` | `supervisor.rs:585-620, :515-525` |
| F15 | Cursor: inbox lookback 7 d applied on EVERY REQ (inbox branch runs BEFORE the phase match); group buffers 10 s / 60 s; cold seed 24 h | `cursor.rs:72, :77, :261-272`; `session.rs:56` |
| F16 | Settle window 8 s; `SUBSCRIBE_CONNECT_WAIT` 5 s; `RELAY_LIFECYCLE_OP_TIMEOUT` 10 s; `MAX_CONVERGENCE_RETICKS` 6 × 20 ms | `config.rs:110, :123, :144`; `auto_commit.rs:61, :68` |
| F17 | FFI: `LiveSyncFfi::{start_session, stop_session, resume_after_background, subscribe_circle, unsubscribe_circle, is_running, live_events}`; `maintain_subscription_health` gated on `SESSION`; `SubscriptionHealthActionFfi`; `RelayManagerFfi::new_instance` | `api.rs:11038-11270, :11317-11326, :7463, :7563-7567` |
| F18 | Dart pause: iOS+bg-ON branch stops nothing; heal timer cancelled first; resume re-anchors behind a 60 s throttle | `map_shell.dart:143-146, :169-176, :1252-1263, :1335-1363, :1455-1463, :1563-1625` |
| F19 | Maintenance timers 10/30/15 min ± 25 % ungated; profile 45 min foreground-gated; KP/relay-list go through `NostrRelayService` → `RelayManagerFfi` (publish pool) | `maintenance_scheduler_provider.dart`; `nostr_relay_service.dart:431-470` |
| F20 | Location publishes: FG scheduler → `LocationSharingService.publishLocation` → `_relayService.publishEvent`; FGS `_publishCircle` → `_relayService!.publishEvent` | `location_publish_scheduler_provider.dart`; `location_sharing_service.dart:298-351`; `background_location_task.dart:1294-1330` |
| F21 | Stagger: min 2 s, max 9 s, spread 30 s; `maxGapFor` floors at `min+1 s`; FGS horizon `timestamp + kPublishStaggerMaxSpread` | `publish_stagger.dart:72-78, :119-133`; `background_location_task.dart:1209-1222` |
| F22 | `kReceiveSilenceThreshold = 2×168 + 228 = 564 s` (foreground-only model tick) | `sharing_health_provider.dart:76-94` |
| F23 | Manifest: `INV-R-PER-CIRCLE-PUBLISH-DECORRELATED` enforced (3 wiring tests; no disclosure key since the Privacy page's removal, 2026-08-29); `INV-R-CROSS-PLANE-CORRELATION` accepted (RC1); `INV-R-TRAFFIC-METADATA-OBSERVABLE` enforced; `ratchet_override` ABSENT today (the gate defaults `.ratchet_override.items // []`, `check_privacy_invariants.sh:1738-1739`) | `docs/privacy/privacy_invariants.json` |
| F24 | `send_event_to` waits for EVERY targeted relay's OK up to `WAIT_FOR_OK_TIMEOUT` = 10 s; `Relay::send_event` returns `Ok(EventId)` only on `OK true`, `Err(RelayMessage)` on `OK false`, internal bound 10 s; a per-relay window needs a fan-out over `Relay::send_event` via `Client::relay(url)` | `constants.rs:10`; `relay/mod.rs:434-466`; `inner.rs:1361-1392`; `client/mod.rs:224` |
| F25 | A `wait_for_ok` timeout is NOT a status transition: the relay stays `Connected` and `try_connect_relay` returns at once for a `Connected` relay; a silently dead socket is retired only by the sleep monitor (≤ 70 s after the last send) or a receive error | `relay/mod.rs:365-367`; `inner.rs:444-476, :965-978` |
| F26 | `should_sleep` checks the WHOLE `atomic.subscriptions` map — auto-closing fetch REQs included — so a per-relay fetch in flight keeps the socket awake until its REQ auto-closes; `pinger()` pings immediately on its first loop iteration, then every 55 s (one ping frame per fresh connect) | `inner.rs:444-456, :982-994` |
| F27 | `InnerRelay::unsubscribe_all` iterates ids and `?`-propagates the FIRST `send_msg` error (`_unsubscribe_long_lived_subscription` removes the id then sends CLOSE) — on a relay where `ensure_operational` errors every later id stays REGISTERED and is re-sent by `post_connection → resubscribe()` on the next connect, ahead of anything the session issues | `inner.rs:265-272, :753-757, :1395-1406, :1685-1717` |
| F28 | `run_repair` calls `plane.repair.take_due()` BEFORE `reissue`; `take_due` clears `due_at`, bumps `attempts` and arms the next backoff — an early return inside `reissue` CONSUMES the pending re-issue | `session.rs:1862-1877`; `repair.rs:182-199` |
| F29 | The engine auto-commit publish is `Client::send_event_to` awaited INLINE in the serial worker (10 s per-relay OK wait); `route_events` matches `Location \| GroupUpdate \| Joined \| Invalidated \| Unrecoverable` — there is no `EpochChanged` variant; a `Buffered` verdict is the FUTURE-epoch case, a one-epoch-behind message decrypts from past-epoch keys | `processor.rs:465-470, :560-600, :613-620`; `auto_commit.rs:110-122`; `wire_format.rs:52-57`; `MARMOT_PROTOCOL_KNOWLEDGE.md:726-727` |
| F30 | `CursorAnchors::note_eose(group_hex)` consumes a circle's single generation on the FIRST relay's EOSE of a multi-relay bucket; the expected `(relay, sub)` endpoint set is already tracked by `probe_subscriptions`/`open_delivery_windows`; the worker resolves the router at PROCESSING time, so everything still queued in the 8192-deep intake when the router is cleared is dropped | `anchor.rs:221-232`; `session.rs:430-436`; `supervisor.rs:537-548, :606-613`; `config.rs:42` |
| F31 | `run_monitor` emits `SyncStatusReason::Disconnected` PER RELAY on every `Terminated` transition; Dart maps it to `SyncConnectionPhase.disconnected`, health stamps `_disconnectedSince` and confirms `relayDisconnected` after 168 s; `LiveSyncResubscriber.ensureRunning` reads `isRunning`, which stays `true` while paused | `session.rs:1904-1935`; `live_sync_provider.dart:153-154`; `sharing_health_provider.dart:68, :288-295, :425-443`; `:456-465` |
| F32 | `subscribe_circle` today does pool add + connect + wait, the cold-start cursor seed, the dynamic sub-id derivation, router registration and the REQ; `resume_after_background` re-issues the STORED `active` set and never calls `add_relay`; `bucket_since` reads an unseeded cursor as `unwrap_or(0)` → a `since = 0` REQ is forbidden | `session.rs:1232-1272, :360-375, :1117-1170`; `cursor.rs:7-8` |
| F33 | Inbox cursor floor = `clamp(cursor − L, 0, now)`; the cursor advances only to the local open time of an inbox REQ whose EOSE the worker consumed; `start` seeds an unset cursor at `now − 24 h`; NIP-59 backdates by ≤ 172 800 s; `storage.rs` ties gift-wrap dedup retention to the 7 d constant | `anchor.rs:336-355`; `processor.rs:391-400`; `session.rs:693-708`; `nostr-0.44.7 nip59.rs:23`; `storage.rs:3065-3066` |
| F34 | `RelayManager::subscribe` (long-lived `subscribe_to`, no auto-close) has NO caller in `haven-core/src` or `rust_builder/src` (V, grep 2026-08-29); a future caller would keep the ping-less publish pool from ever sleeping AND create a silent-dead standing REQ (the C3 class) | `manager.rs:660-700` |
| F35 | tokio in `haven-core` is built WITHOUT `test-util` (`tokio::time::pause()` does not compile); `nostr-relay-builder` is a dev-dependency (`MockRelay`, `LocalRelay`, `WritePolicy` `NeverAnswer`/`RejectEverything`, recording `QueryPolicy`) available to lib unit tests; `SLEEP_INTERVAL` is 60 s in the build Haven links (the 1 s value is the CRATE's `#[cfg(test)]`) | `haven-core/Cargo.toml:122, :232, :240`; `constants.rs:36-41`; `publish_before_apply_send_e2e.rs:97-128`; `catchup_sweep_e2e.rs:1300-1315` |

**Wake model:** a reconnect (DNS+TCP+TLS1.3+WS) ≈ 0.5 J inside a wake — persistent-vs-reconnect is decided purely by wake COUNT. Carrier NAT floors: worst measured 255 s; the ≤ 168 s publish cadence sits inside every floor. **Engine-pool trap:** `ping(false)` on the ENGINE pool is unsafe while it holds standing REQs: its socket then carries no traffic (publishes go over the OTHER pool), a NAT drop is silent, and the 15-min health tick is the only detector → re-creates the C3 blackout. Safe only when the engine has no standing REQ (P4's burst mode) or the pools are merged (rejected — see D6).

### 2.4 The privacy-manifest gate (`scripts/ci/check_privacy_invariants.sh`)

There is no commit-message token. The ratchet reads `docs/privacy/privacy_invariants.json` → `.ratchet_override.items[]` and `.ratchet_override.reason` (≥ 40 chars) (`:1700-1770`; fixtures `:2580-2586`); item ids are `<INV-ID>.deleted`, `<INV-ID>.status`, `<INV-ID>.disclosure:<arbKeyOrNonArbId>`, `<INV-ID>.assertion:<arbKey>`, `<INV-ID>.unbacked:<arbKey>`. An override is compared against the PR's base; after merge it is STALE on the next PR (`:1751-1757` fails a stale override) — every override is deleted in the first follow-up commit (§5.7). A re-worded value under an unchanged key is invisible to the ratchet — hence every re-worded claim gets a copy-tie test (README "What the gate cannot prove"). Rule 15: `doc_anchors`/`source` fragments must be real headings; rule 3: cited test names must keep existing; rule 12 sweeps English claims. Since 2026-08-29 an invariant or accepted deviation may carry ZERO disclosure keys (the Privacy page is gone; the README records the owner decision), and the ratchet no longer demands an override for a disclosure/assertion key whose ARB string no longer exists — only for one that still does. README: platform-asymmetric strings get one invariant per platform.

---
## 3. Decisions D0–D8 (FINAL — synthesis amended by the drafts)

Each decision states the mechanism, then the amendments the drafts proved necessary ("decision + why"). Do
not re-litigate in implementation; a reviewer who finds a decision wrong reports it with evidence.

### D0 — Nothing on the wire changes
Publish cadence stays 72–168 s (CSPRNG ± 40 %), kind-445 retention 228 s (`haven-core/src/location/ttl.rs`),
the no-gap invariant (228 > 168 + 60 buffer), per-message ephemeral keys, publish-before-apply (Rule 13),
single MLS session (Rule 14), no push plane, exact coordinates as measured (`raw_accuracy` stays
`#[serde(skip)]`, `types.rs:85-86`), opt-out ⇒ no keep-alive/session/region/wake, iOS post-termination
wakes receive-only, no new dependency, no telemetry/battery SDK. **Wire timestamp is PUBLISH time, not fix
time (V):** `LocationSharingService.publishLocation` passes only latitude/longitude
(`location_sharing_service.dart:298-320`); `LocationMessage::new` stamps `timestamp: Utc::now()` at encrypt
(`types.rs:163`); peers' age pill reads that payload timestamp (`location_sharing_service.dart:724-745` →
`member_marker.dart:66,152-154`, `kMemberAgePillThreshold` 5 min). A fix up to 168 s old
(`kStreamPositionMaxAge`, `constants/location.dart:158`) is already published under a fresh timestamp today,
so D1's stationary re-send changes nothing on the wire; it needs a **freshness rule** (D1), not a
timestamp rule. No `ratchet_override` follows.

### D1 — iOS: Haven-owned native location manager with two live accuracy profiles
New `haven/ios/Runner/HavenLocationStreamHandler.swift` (MethodChannel `haven.app/ios_location_stream`:
`setProfile`, `lastBestFix`, `clearLastBestFix`, `status`; EventChannel `haven.app/ios_location_stream/events`)
replaces geolocator's `getPositionStream` ON iOS ONLY; Android keeps geolocator; `GeolocatorLocationService`
routes by platform (the "one `getPositionStream` site" invariant becomes "one stream owner per platform").
Configuration set once in `init`: `pausesLocationUpdatesAutomatically = false` (R4),
`distanceFilter = kCLDistanceFilterNone` (16.4 rule, both profiles), `activityType = .other`,
`desiredAccuracy = kCLLocationAccuracyBest`; `allowsBackgroundLocationUpdates = allowsBg` where
`let allowsBg = args["allowsBackgroundLocationUpdates"] as? Bool ?? false` on ONE line of `onListen` (R8 — a
pure function of the toggle, never a literal, never `?? true`); `startUpdatingLocation()` only in `onListen`,
which REFUSES a background-capable start while `applicationState == .background` (R7,
`INV-L-IOS-WAKES-RECEIVE-ONLY`; `== .background`, not `!= .active` — Flutter's `resumed` arrives from
`applicationDidBecomeActive`, so a legitimate start can land while UIKit reports `.inactive`). **Errors go through
the SINK, never the `onListen` return value** (§2.1 EventChannel contract): `onListen` returns `nil` and on refusal
calls `events(FlutterError(code: "background_start_refused", message: nil, details: nil))` then
`events(FlutterEndOfEventStream)`; `didFailWithError` likewise (`code: .denied ? "denied" : "failed"`, message =
the error TYPE only). A second `listen` is engine-driven (the engine cancels the existing sink first), so
`already_listening` is unreachable — `guard sink == nil` stays as a log-free `return nil`, with no test pinned on it.
Profiles: **Best** while foregrounded OR moving; **HundredMeters** while backgrounded AND stationary — switched
by a live `desiredAccuracy` write, never a restart; exactly two accuracy values may ever be assigned (a third,
coarser tier would recreate the 16.4 suspension shape). Only fixes delivered under the Best PROFILE are ever
published or cached: the handler records `bestSince = Date()` on every switch to Best and sets `lastBestFix` only
when `manager.desiredAccuracy == kCLLocationAccuracyBest && loc.timestamp >= bestSince` (a fix computed under the
100 m tier that arrives just after a switch is thereby excluded); 100 m fixes feed the movement detector and the
freshness bound only, so peers never receive a coordinate the app asked for at a coarsened tier — the
invariant is named `INV-L-IOS-PUBLISH-INPUT-BEST-PROFILE-ONLY`, not "GPS-grade" (it carries no disclosure key: the
Privacy-page sentence that stated the no-coarsening property was removed with the page on 2026-08-29). `onCancel` →
`stopUpdatingLocation()`, `allowsBackgroundLocationUpdates = false`, `lastBestFix = nil`, `sink = nil` (Rule 10:
no full-precision coordinate outlives the session in native memory); `clearLastBestFix` is invoked from
`GeolocatorLocationService.clearCachedPosition()` (logout, opt-out pause) so the Dart and native copies always
clear together. `status()` → `["running", "allowsBackgroundLocationUpdates", "showsBackgroundLocationIndicator",
"profile", "authorization", "backgrounded"]` (booleans/enum strings; Dart reads it with
`invokeMapMethod<String, Object?>` — the map mixes `Bool` and `String` — and fails closed on a missing OR
wrong-typed key).
**Amendments:** (i) the stationary/moving **profile controller lives in Dart** because no Swift unit test runs in
CI (§2.1), as ONE new class `IosLocationSource` (`haven/lib/src/services/ios_location_source.dart` = the channel
service + the PURE controller + the single confirm `Timer`) exposing `Stream<Position> positions({required bool allowsBackgroundLocationUpdates})`
(Best-profile fixes only), `Future<Position?> lastBestFix()`, `Future<void> clearLastBestFix()`,
`void onForeground(bool)`, `DateTime? get lastConfirmedAt`, `Future<IosLocationStreamStatus> status()`; the
controller is pure (`Duration? nextDeadline(now)` / `onDeadline(now)` / `onFix(fix, now)` on fixed `DateTime`s — no
`fake_async` needed), so `GeolocatorLocationService` routes in one expression and reads `lastConfirmedAt` in its
freshness rule (≈ 10 new lines in the 890-line service instead of ≈ 80; the 85 % floor row stays intact) —
constants `kStationaryDwell = kLocationUpdateInterval` (120 s), `kStationaryConfirmMaxAge = kStreamPositionMaxAge ~/ 2`
(84 s), `kStationaryConfirmMaxAccuracyMeters = kMotionTriggerDistanceMeters` (100 m — see (iv));
(ii) **one-shots stay on geolocator** (`_currentPositionSettings`, `geolocator_location_service.dart:612-621, 727-732`):
`requestLocation()` does nothing while the same manager updates (§2.1), so a native one-shot would need a
second manager — fewer managers wins, and `kOneShotLocationTimeout`/b5 stay untouched; (iii) **last-known
is routed native**: the plugin's `getLastKnownPosition` reads a plugin manager that never started under the
native owner (`.location` on a never-started manager is U), so the iOS backgrounded fallback reads the native
owner's last **Best** fix (deterministic, only-Best); (iv) **freshness rule and its bound**: `getCurrentLocation`
serves the cached Best fix while `now − (lastConfirmedAt ?? cached.timestamp) ≤ kStreamPositionMaxAge`, where a
100 m-tier fix `g` with `g.accuracy ≤ kStationaryConfirmMaxAccuracyMeters` (100 m) CONFIRMS the anchor when
`d(g, anchor) < kMotionTriggerDistanceMeters` and MOVES the profile to Best when `d ≥ kMotionTriggerDistanceMeters`;
a coarser fix neither confirms nor moves (a fix that cannot resolve 100 m cannot vouch for 100 m of stillness —
the 84 s escalation to Best then decides with GPS truth). Bound, stated in the constants' docs and beside OD-P3-d
(no user-facing surface since the Privacy page's removal, 2026-08-29): while confirming fixes keep arriving, a true displacement
below `kMotionTriggerDistanceMeters + kStationaryConfirmMaxAccuracyMeters` = 200 m can go undetected (the
served coordinate is then up to 200 m stale until the next Best fix or the 84 s escalation), against today's
100 m of Best-grade travel — the background sensitivity is "100 m, judged by fixes no coarser than 100 m". On
Android `lastConfirmedAt == cached.timestamp` always, nothing moves. `_noteAccessLost` nulls the confirmed age
together with the cache (the two fields move together). (v) existing `HavenSLCHandler` (SLC + 500 m relaunch
region) is untouched as the receive-only relaunch net. (vi) **the cold-cache shortcut reads the NATIVE lifecycle**:
`getCurrentLocation` on iOS consults `(await _iosSource.status()).backgrounded` for the backgrounded shortcut
(`:711-724`) instead of `_foregroundActive` (fail-closed: an unreadable status counts as backgrounded), so a
background-launched process (SLC/region/BGTask relaunch — the FA:218-222 hole) serves `lastBestFix()` (nil after
termination) and never starts the plugin one-shot from the background; the guard pins `lastBestFix(` before
`getCurrentPosition(` in the `getCurrentLocation` body (line-order, like check 12). With (vi) the wake is
receive-only by construction on BOTH paths (stream start refused; one-shot unreachable), which is what the amended
`INV-L-IOS-WAKES-RECEIVE-ONLY` statement may claim. (vii) **Profile duty, stated honestly:** in poor coverage the
controller cycles ≥ 120 s Best → 84 s HundredMeters → …, i.e. up to ≈ 59 % of the time at Best; the "4–6× cheaper"
figure is Evgenii's bare-session number and excludes this — the §6.5 template records the observed
"profile duty (% at Best)" from Console `locationd` accuracy lines, which is the number that tells the owner
whether 84 s / 120 s (OD-P3-a) are right. Running `CLLocationManager`s on iOS after P3: exactly one for updates
(Haven's) + the unchanged SLC/auth managers.

### D2 — iOS indicator/session policy by tier
One predicate, **`alwaysConfirmed`**, owned by `HavenBackgroundSessionHandler` and FAIL-SAFE: it is `false` until
(iOS 18+) the held `CLServiceSession(.always)`'s `diagnostics` stream has yielded a diagnostic with
`alwaysAuthorizationDenied == false && authorizationRequestInProgress == false && insufficientlyInUse == false`
(WWDC24 V: for a settled authorization the first diagnostic arrives at once with `authorizationRequestInProgress`
already false, so a real-Always user is confirmed within the same `arm()`); on iOS 17 (no diagnostics) it stays
`false`. Provisional Always — `authorizationStatus == .authorizedAlways` while the effective grant is When-In-Use
(§2.1) — therefore never takes the Always branch: that cohort keeps the activity session and the pill, the
honest state for what the OS itself treats as WIU, instead of the 2026-08-20 field-failure shape (no activity
session under an effectively-WIU app, `M7:817-819`). `arm()` (`HavenBackgroundSessionHandler.swift:134-136`):
`let wantsActivitySession = status == .authorizedWhenInUse || !alwaysConfirmed`; the activity session is created
when `wantsActivitySession` and nothing holds one; it is invalidated and nilled ONLY when `!wantsActivitySession`
AND `UIApplication.shared.applicationState != .background` — **`arm()` never withdraws an in-use claim while
backgrounded** (a WIU→Always upgrade delivered in the background via `locationManagerDidChangeAuthorization`
would otherwise drop the only keep-alive while its `.always` replacement cannot start outside the foreground —
the FA wedge shape, and the DTS stuck-indicator path); the existing `applicationWillEnterForeground` re-arm
(`AppDelegate.swift:292-299`, check 9) performs the deferred invalidate at the next foreground. `disarm()`
(`:158-167`, toggle-off, Rule 10) stays unconditional — header sentence: "arm() never withdraws a claim while
backgrounded; disarm() always does" (the sentence M7 §6 0c references). **The confirmation is ASYNCHRONOUS** —
`CLServiceSession.diagnostics` is an `AsyncSequence`; even the "immediate" first diagnostic lands AFTER `arm()`
returns — so the diagnostics observer (main-actor hop) does three things when it flips `alwaysConfirmed`: sets the
flag, RE-RUNS `arm()` (the foreground-only invalidate rule applies, so a confirmation that lands while backgrounded
leaves the session until the next foreground) and fires `onAlwaysConfirmedChanged` → the stream handler's
`applyIndicatorPolicy()`. Without that, every REAL-Always launch would run its first `arm()` unconfirmed (activity
session created, indicator `true`) and nothing would undo it until the next `applicationWillEnterForeground` — OD1
would not materialise through the whole first background period after each launch. Indicator: the stream handler
re-applies `manager.showsBackgroundLocationIndicator = !sessionHandler.alwaysConfirmed` at start, on every
authorization callback and on `onAlwaysConfirmedChanged` (under When-In-Use the OS ignores the flag — pill mandatory — so `true` there is documentation-honest;
under CONFIRMED Always the flag is the only remaining pill source once the activity session is gone).
`CLServiceSession(.always)` on iOS 18+ (`:137-151`, retaken at both launch branches `AppDelegate.swift:104` and
every foreground `:115`) unchanged. `AppDelegate` wires `locationStreamHandler.onAuthorizationChanged = { [weak self] in self?.backgroundSessionHandler.arm() }`;
because the delegate fires at manager CREATION, `arm()` (idempotent, UserDefaults-only) can first run from that
callback — harmless, but the wiring is assigned only AFTER `backgroundSessionHandler.register(with:)` (line-order
guard pin, like check 12) so the documented synchronous `arm()` site keeps its meaning. `status()` gains
`alwaysConfirmed`. The Always upgrade prompt stays tied to the background toggle. **Copy is driven by the same
state, not by `authorizationStatus`:** the iOS guidance card renders ONLY under `IosAuthStatus.always` (today's
`Platform.isIOS && !iosLimited`, `location_settings_page.dart:158-160, :298`, also renders it for
notDetermined/restricted/denied/unknown — false tier-specific text for a denied user) and is composed of a
tier-neutral base key + ONE indicator sentence chosen by the handler's `backgroundActivitySessionHeld`
(`IosBackgroundSessionStatus`, `ios_background_session_service.dart:32-47`, via a provider invalidated on toggle
AND on `AppLifecycleState.resumed`) + the catch-up key rendered LAST (so VoiceOver hears session → indicator →
catch-up): held → the "blue location bar" sentence (provisional Always on iOS 18+ and EVERY iOS 17 Always user —
no diagnostics API there), not held → the "small location arrow" sentence; under When-In-Use the limited note
carries the bar sentence (13 locales, §7.1). ⇒ **OD1**: indicator OFF under CONFIRMED Always, no extra setting (simplicity; the OS arrow +
Settings attribution + Haven's toggle remain visible) — honest consequence: provisional users see the pill until
they answer the second prompt. ⇒ **OD-P3-b** (iOS 17 provisional): the WIU policy unconditionally — "treat as
Always" is the UNSAFE direction (silent publish loss for that cohort); the cost is a pill for a small cohort.

### D3 — Android: FGS owns one long-interval platform request while backgrounded; UI stream lives only while foregrounded
**Part 1 (P1):** the UI isolate's plugin subscription is released on pause by a SERVICE-LEVEL synchronous
gate (`GeolocatorLocationService.suspendStream()` / `resumeStream()`, §3.1) called directly from
`_onPaused`/`_onResumed` — never by a Riverpod rebuild, which cannot run while paused (§2.2a); on Android it is
released in BOTH toggle states, BEFORE the ownership stamp is written (mirroring the MLS handoff order),
restored first thing on resume. Foreground stream settings unchanged (1 m / 1 s while the map is on screen is a
foreground use case; b5's discriminator depends on it).
**Part 2 (P2a):** the FGS isolate holds ONE geolocator stream on its own `GeolocatorLocationService`,
`AndroidSettings(accuracy: best, forceLocationManager: true, distanceFilter: 0, intervalDuration: I)` with NO
`timeLimit`; publish on delivery; re-register after each cycle to the next pre-sampled CSPRNG due.
**Amendments:** (i) **WorkManager registration UNCHANGED** (verification G2 + Android precision 1): the
15-min floor exists for an FGS killed by OOM/`am kill`, on which NO Dart or Kotlin hook runs
(`ForegroundService.kt:196-216`, `:218-225`) and a force-stop strips JobScheduler jobs until the next launch
(`M7:764`) — "re-register on death" is dead code exactly when it matters; the `e2e-background-catchup`
Phase A oracle discovers the job id right after enable (`run-m7-background-catchup.sh:669-713`) and guard
checks 7/11 (`check_m7_native_wake_guards.sh`) pin registration at enable. The lever that stays is the
worker's cheap bail at gate 3 (`background_catchup_worker.dart:294-304`, reads `kForegroundActiveAtMsKey` /
`isRunningService` BEFORE `RustLib.init()` — V-tag the order). Cost accepted: ≈ 4 no-op engine spin-ups/h
while the FGS is alive (`M7:433-441` "≤ ~31 s per wake"); revisit only if the P0 baseline attributes
measurable cost, and then with a new Phase A′ oracle ("job registered after FGS death") in the same commit.
(ii) **The one-shot survives, UNCHANGED, as the ≥ 168 s no-delivery fallback inside `getCurrentLocation()`**
(`geolocator_location_service.dart:727-749`), reached by the watchdog only after `kStreamPositionMaxAge`
without a delivery (indoors on a GNSS-only device). Keeping `getCurrentLocation()` as the ONLY coordinate
producer in the cycle keeps `INV-L-ACCESS-GATE-PRECEDES-FIX` and `INV-L-BACKGROUND-DISCLOSURE-GATE` literally
intact (`check_location_access_gate.sh` is name-bound; `background_location_disclosure_gate_test.dart:124-147`
pins `gateAt < indexOf('getCurrentLocation(')`). (iii) **Interval formula**
`I = clamp(target − now, kMinFixRequestInterval, hi)`, `target = earliestDue − kBackgroundFixLeadTime`,
`hi = kLocationPublishMaxInterval`; `kBackgroundFixLeadTime = 10 s` (AOSP hot-TTFF figure,
`GnssLocationProvider.java:228`); `kMinFixRequestInterval = MIN_REQUEST_DELAY_MS + 1 s = 31 s`
(`LocationProviderManager.java:181` — the ONLY platform lower bound that matters: above it the S+
historical-delivery / delayed-register regime applies; `I = 0` would be a continuous HIGH_ACCURACY request with
NO historical delivery, and a 72 s floor anchored at the last publish would starve a second circle due 31–71 s
later by up to 41 s → 219–239 s realized gap, a TTL breach); `kRegistrationSlack = 5 s` (an aligned
registration is never re-issued — the loop breaker against historical re-delivery); registered at the START of
the cycle with pre-sampled jitter. **The initial `I` is never 0, and the handoff costs no one-shot on S+:** the FGS isolate's
`GeolocatorLocationService` is a SEPARATE instance (`:668`) with an EMPTY cache — the UI's warm fix is not there —
so the first cycle registers first (the registration precedes `getCurrentLocation()` by design) and then awaits the
FIRST delivery with a ≤ 2 s bound before reading: on S+ the historical delivery (the UI stream's seconds-old fix)
arrives within ms of `requestLocationUpdates` (§2.2) and the circles `seedStaggered` made due NOW publish from it;
on API ≤ 30 (no historical delivery) the ≤ 2 s wait lapses and today's one-shot runs ONCE. The cycle then
registers for `earliestDue − lead ≥ 62 s`. **Gap proof, per API level (the mechanism is the S+ delayed
register, §2.2, anchored at the LAST FIX `t_f`, not at the registration instant):** a circle publishes at P with
J ∈ [72,168] → due D = P + J; the cycle consumed the fix at `t_f ≈ P − δ` and re-registers at `R ≈ t_f + δ`
with `I = D − 10 − t_f`; on **S+** the manager restarts GNSS at `t_f + I = D − 10` and delivers at
`D − 10 + TTFF` (never early — the 10 % fastest-interval band is what the gate would accept, not what arrives);
`dueKeysUpTo(now + kBackgroundFixHorizon)` (30 s, a constant of ITS OWN, decoupled from
`kPublishStaggerMaxSpread` — it must only exceed the lead so a fix delivered ahead of its due finds the circle
due, and 30 s keeps today's batching window for a sibling due shortly after) selects the circle; realized gap
∈ [J − δ, J + max(0, TTFF − 10)] ⊂ [72 − δ, 168 s] for hot TTFF ≤ 10 s; cold TTFF 30 s → ≤ 188 s (eats 20 s
of the 60 s buffer). On **API 23–30** (no delayed register) cancel+listen restarts GNSS at once and hibernates
from that fix: gap ≤ J + TTFF₁ + TTFF₂ − 10 → ≤ 218 s with two cold acquisitions (rare — ephemeris survives
≤ 168 s gaps, I). Single faults stay inside 228 s; STACKED faults (cold TTFF + a delivery→Dart suspend gap,
P2b only) do not — recorded in the risk register (§6.3 C6). No fix → the 168 s watchdog fallback publishes
last-known ≤ 168 + 30 s, as today (the watchdog keeps its wake source in P2a — D4). Today's worst case is WORSE
(V): the 72 s poll with a 30 s horizon publishes a circle due at D at the first tick T ∈ [D − 30, D + 42] plus a
30 s one-shot → up to 240 s > 228 s TTL. **Registration cost the energy model must carry:** every plugin
registration also installs the NMEA + `GnssStatus` listeners (§2.2) — ~1 Hz main-thread callbacks whenever the
GNSS engine navigates for any consumer (TTFF seconds outdoors, up to 60 s per interval indoors on a
non-scheduling HAL); the AP is not idle during a search. There is NO "`gps` provider fallback" on the plugin
path (geolocator 5.0.2 has no provider selector, §2.2): if GMS `fused` ignores the interval for HIGH_ACCURACY
(I-P2-2, decided by the hardware GPS-time row) the remedy is the native registration of P2b (D4), not a
profile edit. (iv) **The FGS never publishes early on displacement** (verification G10 folded in):
the cycle publishes only circles whose CSPRNG due has come (`dueKeysUpTo`, `per_circle_due_tracker.dart:123-131`);
a delivery with nothing due is consumed silently — but it still REGISTERS: from `Idle` (pause with every
circle due 62–158 s out) the cycle, below both gates, calls `_ensureRegistration(target = earliestDue − lead)`
even when `dueKeys` is empty (otherwise the 72 s watchdog would re-run the same path and publish through the
cache-miss one-shot forever — the steady state P2 retires); `_publishCycle` is the ONLY `_ensureRegistration`
caller (the watchdog, the delivery handler and both signals only ever invoke the cycle), so the disclosure gate
and the foreground gate precede every registration on every path by construction — guard-pinned by count (1)
and order. A delivery that arrives while a cycle is `Cycling` (30 s stagger + 15 s publish + fetch) sets
`_deliveryPending` (no second cycle; both entry points share one event loop, so the hazard is only the
await-separated one); the cycle's `finally` runs ONE follow-up cycle immediately when `_deliveryPending` and
`dueKeysUpTo(now + kBackgroundFixHorizon)` is non-empty (same in-flight guard) and in EITHER case records the
pending fix's timestamp as `_lastConsumedFixTs`, so the next registration's historical re-delivery of that same
fix dedupes (otherwise one spurious nothing-due cycle per re-registration), and the watchdog also runs the
cycle when `_deliveryPending` — a watchdog tick during `Cycling` is otherwise a no-op. `INV-L-MOTION-TRIGGER-BOUNDED`
("only in the Flutter UI isolate") stays literally true; no copy changes in P2.
(v) **Resume ordering:** `resumeStream()` runs FIRST in `_onResumed`, ahead of the 30 s resume debounce, not
after the FGS request stops (two overlapping registrations coalesce at the provider to the tighter one, which
is the foreground policy anyway; waiting would cost the map its first fix); the PAUSE direction keeps the strict
order (`suspendStream()` BEFORE `markForegroundActive(false)`), which is the one that saves power.
(vi) **Pre-existing 30 s-debounce defect (fixed in P1):** a resume inside the debounce returns before
`_startTimers()` (`map_shell.dart:1644-1651` vs `:1690`) AND before the Android ownership-reclaim block
(`:1658-1685`: `markForegroundActive(true)`, `waitUntilIdle()`, `fgsNotificationOpen`, the `_lastPublishTime`
seed from `readLastPublishTime()`), while `_endMlsSessionHandoff()` (`:1602`) and `_healLiveSyncIfStopped()`
(`:1641`) DO run ahead of it and re-take the Rule-14 guard. Consequence of a pause→resume pair within 30 s,
stated exactly: the foreground publish scheduler (`:763`), heartbeat (`:750`), motion trigger (`:770`) and the
receive/invitation/prune/evolution timers (`:1438-1441`) stay STOPPED; with sharing ON the ownership stamp stays
`0` (written at pause), so the FGS sees no foreground owner, `_ensureSession` finds the guard held by the alive
UI and the reclaim correctly DECLINES (`background_location_task.dart:869-906`) — NOBODY publishes, and the FGS
notification keeps saying "sending and receiving" (set at `:1328-1334`, never refreshed on the debounced path);
with sharing OFF nobody publishes either. Fix: the WHOLE reclaim block and an unconditional `_startTimers()`
(idempotent — it cancels first, `:737-743`) move ahead of the debounce; the debounce guards only the one-shot
extras (§5.1 resume table). The P1 test asserts BOTH that every timer field is non-null after a debounced
resume AND that the ownership stamp is re-written ahead of the debounce, so a future reorder cannot re-open the
"held guard, dead scheduler" state.
(vii) Indoor no-fix: on a non-scheduling HAL the registration searches ≤ 60 s per interval (`NO_FIX_TIMEOUT`)
then hibernates (a scheduling HAL searches per chip policy — U per chip); the platform alarms then produce NO
app callback, so the 168 s watchdog is the ONLY thing that publishes indoors on a GNSS-only device — which is
why P2a KEEPS the plugin wake lock (D4): the watchdog runs the SAME chain as today (one-shot → last-known
regardless of age, `:735-739`) → same publish, same ack stamp, same banner. Residual to document (M7 §D):
GNSS-only devices indoors keep the receiver on ≈ 60 s per 72–168 s interval on non-scheduling HALs (vs 100 %
today) + one 30 s one-shot per 168 s of silence.

### D4 — Android: scoped publish lock now (P2a); the permanent lock goes only with a proven wake source (P2b)
**P2a keeps the plugin's `PARTIAL_WAKE_LOCK`** (`allowWakeLock` left at its default `true`,
`foreground_task_options.dart:10`; the untimed non-refcounted acquire is `ForegroundService.kt:426-436`), because it
is the ONLY wake source of two things the plan must not lose: the no-fix fallback (indoors on a GNSS-only device the
platform alarms wake nothing, §2.2 / D3 (vii) — without a lock the 72 s watchdog is `delay()` on AWAKE time and may
take hours to accrue, and sharing stops silently on the F-Droid cohort the `forceLocationManager` posture exists
for: the FA class, no banner) and the recovery for a silent `onListen` while the plugin service is unbound
(V-P2-2) or a stream error mid-`Armed`. With the lock kept the AP never suspends, so the delivery→Dart window
(U-P2-1) does not exist in P2a. P2a still lands the GNSS saving the plan ranks as the dominant Android drain
(R-C: 60–85 mA → ≈ 5 mA) and is independently measurable and revertible. Guard check (1) pins `allowWakeLock`
ABSENT from `ForegroundTaskOptions(` with the WHY ("the plugin lock is the watchdog's wake source until P2b ships
one"); `INV-L-ANDROID-NO-PERMANENT-WAKE-LOCK` is NOT added in P2a.
**P2a also adds the Haven-owned scoped lock** so P2b is a pure removal: `PARTIAL_WAKE_LOCK` tag `Haven:publish`,
`setReferenceCounted(false)`, `acquire(timeoutMs)` with the timeout coerced to `[1, 30_000]` NATIVELY, idempotent
`release()`; scoped to fix→encrypt→publish→ack→fetch, `await`ed before the first FFI/encrypt (the channel call is
asynchronous — awaiting it makes "acquired before the first encrypt" a real order, not a race), re-acquired before
each per-circle publish (after the stagger sleep) and before the fetch step so the guarantee is "never held more
than 30 s past the last acquire" (re-`acquire` on a held non-refcounted lock re-posts the timeout — V, §2.2).
`kPublishWakeLockTimeout = 2 × kBackgroundTeardownDrainBudget = 30 s` (one relay attempt is 15 s,
`mls_session_handover.dart:68-72`), pinned as `kPublishWakeLockTimeout.inMilliseconds == 30000` in
`location_test.dart` so Dart and Kotlin `MAX_TIMEOUT_MS = 30_000L` cannot drift. **Release ownership:** the Kotlin
lifecycle listeners (`onTaskDestroy`/`onEngineWillDestroy`) do NOT release or detach — the plugin invokes them
synchronously right after it invokes Dart's `onDestroy` ASYNCHRONOUSLY (`ForegroundTask.kt:155-173`), i.e. before
the ≤ 15 s bounded drain + final publish has even started (the plugin's own lock has the same pre-existing defect,
released in `stopForegroundService()` right after `destroyForegroundTask`, `ForegroundService.kt:196-201,294-297`
— P2 must not replicate it); release happens from Dart `onDestroy`'s `finally` after the drain and by the native
≤ 30 s timeout; the channel handler lives until `FlutterEngine.destroy()` tears the messenger down (inside the
invoke callback, after Dart's `onDestroy` returns). **Implemented** WITHOUT a new package and WITHOUT touching
`MainActivity`: one Kotlin `object PublishWakeLock : FlutterForegroundTaskLifecycleListener, MethodChannel.MethodCallHandler`
registered from `HavenApplication.onCreate` (`HavenApplication.kt:36-44`, runs in every process start incl. the
boot restart) via `FlutterForegroundTaskPlugin.addTaskLifecycleListener(PublishWakeLock)`; `onEngineCreate`
installs `MethodChannel("haven.app/publish_wake_lock")` on the FGS engine. Dart wrapper catches ONLY
`MissingPluginException` and `PlatformException` (logging `e.code`, the `ios_background_session_service.dart:121-131`
pattern) — a programming error in the wrapper must not be silenced. `WAKE_LOCK` today arrives only by manifest
merge from the plugin (`flutter_foreground_task/android/src/main/AndroidManifest.xml:5`) → declared explicitly in
Haven's manifest with the INTERNET-style rationale (`AndroidManifest.xml:3-7`) and guarded. The battery-optimisation
exemption request stays (`background_location_manager.dart:172-178`; Play "acceptable use"; protects the FGS on
aggressive OEMs).
**P2b — permanent-lock removal, a separate phase with two merge gates and one policy rule:** (i) a proven wake source for the no-fix
fallback and the `Armed`-with-no-delivery recovery; (ii) the hardware liveness column (relay-side `created_at`
gaps, §6.5) under `dumpsys deviceidle force-idle`, screen-off, cellular, in BOTH battery-exemption states; (iii) the
lock policy is CONDITIONAL on the exemption: `allowWakeLock: !isIgnoringBatteryOptimizations`, re-evaluated at
enable and at every resume, never a literal — Haven soft-fails a declined exemption
(`background_location_manager.dart:172-178`) and for a NON-exempt uid no ordinary alarm fires in Doze
(`AlarmManagerService.java:2734-2740` grants `ALLOW_WHILE_IDLE_UNRESTRICTED` only to `isUidPowerSaveUserExempt`), so
the B-2 silent stop would return for that cohort — it keeps the plugin lock. Recommended design (BR-1): a Haven-owned
Kotlin `LocationListener`/`PendingIntent` registration (`LocationManager.requestLocationUpdates(provider,
LocationRequest{interval I, minUpdateInterval I, HIGH_ACCURACY}, …)`) living in `PublishWakeLock.kt`, whose
receiver acquires `Haven:publish` INSIDE the system's delivery wake lock — closing U-P2-1 by construction —
installs no NMEA/`GnssStatus` listeners, can name `GPS_PROVIDER`/`FUSED_PROVIDER` explicitly (the I-P2-2 remedy),
and leaves geolocator to the UI stream and the one-shots (ios check 2's single `.getPositionStream(` site holds
trivially); ≈ 150 lines of Kotlin + one channel; native config guard-pinned (no Kotlin tests in CI — the Swift
handlers' posture). **Consent (Rule 10) for a registration that OUTLIVES the process:** a `PendingIntent`
registration keeps delivering after the FGS dies without Dart (OOM/`am kill` — no `onDestroy`), and a later toggle
OFF would find nothing to stop — the M7 cancel-on-disable lesson (check 11) reopened natively and
`INV-L-ANDROID-BACKGROUND-SINGLE-GNSS-REQUEST` false. Therefore: the native registration is issued ONLY on a channel
call from `_ensureRegistration` (never from `onEngineCreate`); `disableBackgroundScheduling()` and
`cancelNativeSchedulers` gain a native `cancelRegistration` (the check-11 family, both sites); and the receiver
FAIL-CLOSES — it re-reads the persisted toggle and both disclosure prefs and unregisters itself, dropping the fix
without waking Dart, when any is false or no FGS engine is attached. Guard: no `requestLocationUpdates(` outside
the channel handler; Dart test `a toggle-off with a dead service still cancels the native registration`; B1 P2b
oracle "no Haven request after toggle OFF with the service force-killed". The no-fix watchdog additionally needs a
wake source of its own; candidates, each recorded: an inexact `AlarmManager.set()` — fires in Doze ONLY for a
battery-exempt uid, up to ~75 % late → a BOUNDED TTL breach, never a silent stop — the default candidate for the
exempt cohort, no new permission (the non-exempt cohort keeps the plugin lock, (iii)); `setExactAndAllowWhileIdle` +
`SCHEDULE_EXACT_ALARM` (a NEW disclosure surface — special-access prompt, Play "Alarms & reminders" policy, 13-locale
copy, `docs/privacy` coverage → **OD-P2-3**); a native `GnssStatus.Callback` "session ended without `onFirstFix`"
signal (HAL-dependent under `CAPABILITY_SCHEDULING`, U). **U-P2-1 stated as its consequence, for OD-P2-2:** the
system's delivery wake lock (`LocationProviderManager.mWakeLock`, 30 s, `:1013`) is released when the app's
`onLocationChanged` returns on the main looper (`LocationManager.java:3296-3315`); the plugin's `events.success`
only ENQUEUES to the Dart isolate and Dart's `acquire` is one more hop — if the AP suspends in that gap (rare
but real under Doze, I) the delivery is processed at the NEXT wake, in deep Doze Haven's own next GNSS alarm ≈ `I`
later, so that circle's realized gap ≈ `J + I` ≤ 326 s > 228 s: the marker expires at every peer ONCE. Not merely
"bounded" — a one-cycle TTL breach at probability p, measured on hardware before P2b; moot under P2a.

### D5 — Network step 1: publish pool on-demand, bounded location publish (lands in P1, independent of everything else)
`publish_relay_options()` in `haven-core/src/relay/manager.rs` =
`RelayOptions::default().ping(false).reconnect(false).sleep_when_idle(true).idle_timeout(PUBLISH_POOL_IDLE_TIMEOUT)`,
`PUBLISH_POOL_IDLE_TIMEOUT = 10 s`. After the last send or fetch (F26: an in-flight auto-closing fetch REQ keeps
the socket awake until it closes) the socket carries no keepalive; at the next 60 s monitor tick it goes `Sleeping`
and closes (socket lifetime after a publish in (60 s, 70 s]; one ping frame at each fresh connect, none between
bursts); a NAT-dropped socket is either `Terminated` (no retry loop) or retired by the idle monitor within ≤ 70 s
of the last send — a `wait_for_ok` timeout is NOT a status transition (F25), so a socket that dies silently inside
that window is reused by any publish inside it (a KP publish 20 s after a location, attempts 2–3 of a
`publish_event` ladder) and costs at most one bounded attempt; today's `ping(true)` detects the same drop only at
the next 55 s ping, so this is not a regression. Every use already goes through `try_connect_relay`, which
reconnects from `Sleeping`/`Terminated` in ≤ 5 s inside the same wake (+0.5 J). **Amendments:** (i) all three
`client.add_relay(` sites (`manager.rs:307`, `:617`, `:1253`) become
`client.pool().add_relay(url.as_str(), publish_relay_options())` — a bare `Client::add_relay` would OR `PING`
back (F6) and the pinger reads the flag live (F3); the guard's core check is "no bare `.add_relay(` on the
publish client". (ii) `reconnect(false)` is required: with `reconnect: true` a relay that DROPS never reaches
`Sleeping` (the sleep monitor runs only inside `post_connection`) and retries every 10–60 s forever (F5) —
R-E's "never gives up". (iii) **`publish_location_event(event, relays)` = `publish_with_retry(LOCATION_PUBLISH_ATTEMPTS, Duration::ZERO, |_| fan_out)`**
with `const LOCATION_PUBLISH_ATTEMPTS: u32 = 1;` (`const _: () = assert!(LOCATION_PUBLISH_ATTEMPTS == 1);`) beside
the untouched `publish_event`, so the existing ladder machinery supplies — with its 11 unit tests as pins — the
error CONTRACT Dart already handles: zero acks → `Err(AllRelaysFailed)`, every answering relay blaming the clock →
`Err(DeviceClockRejected)` via `clock_skew::classify_publish_outcome` (`manager.rs:176-220`), which
`nostr_relay_service.dart:552-566` maps to `RelayClockRejectionException` → `recordPublishClockRejection`
(`location_sharing_service.dart:367-374`; b8 pins that branch on the production service), and "never retries"
(`publish_with_retry_honours_single_attempt`). The fan-out attempt is ONE 5 s per-relay window, no separate drain:
validate `wss://`, connect (`add_relays_and_connect`, ≤ 5 s), then `join_all(send_to_one(client, url, event, LOCATION_ACK_WINDOW))`
where `async fn send_to_one(client, url, event, bound) -> (String, AckOutcome)` is factored OUT of
`try_publish_once_harvesting`'s per-relay closure (`:555-575`) and reused by both callers; each relay's
`Relay::send_event` is bounded by `tokio::time::timeout(LOCATION_ACK_WINDOW = 5 s)` (the profile path's shape,
`:130-146`), the fold populates `accepted_by` / `rejected_by` (from `AckOutcome::Refused`) / `failed` (unanswered)
and returns at the slowest BOUNDED relay — 5 s worst, ≈ 25 lines, no `FuturesUnordered`, no two-phase race. A
location needs ≥ 1 ack (`notePublishAcked`), never the full harvest; a stalled relay is therefore waited for at most
5 s, and the worst case per publish is `CONNECTION_TIMEOUT + LOCATION_ACK_WINDOW` = 10 s (`check_teardown_drain_budget.sh`'s
15 s stays literally true as an upper bound; `location_ladder_worst_case_equals_one_publish_attempt` pins 5 + 5).
`const _: () = assert!(LOCATION_ACK_WINDOW.as_millis() <= DEFAULT_TIMEOUT.as_millis())` (`Duration`'s `PartialOrd`
is not usable in a const context; `as_millis` is `const fn`). **Late-ack semantics, stated:** the 5 s cut does not
un-send the EVENT — a relay that acks at 6 s has stored it while Haven records that relay as `failed`; if NO relay
acked the circle stays due and the next tick sends a fresh event (a duplicate at that relay — the same duplicate
today's ladder produces), and if ≥ 1 relay acked the publish is recorded as accepted and the late relay's copy is
simply an extra archive. The new function logs COUNTS only (the `try_publish_once_harvesting` posture, `:583-589`),
pinned by a captured-logger unit test — `check_no_key_logging.sh` covers key material, not URLs, and
`add_relays_and_connect` already prints `{url}` at debug (`:309-330`, unchanged). (iv) **`RelayManager::subscribe`
(`manager.rs:660-700`) is DELETED** (F34: no caller; a future caller would keep the ping-less pool from ever
sleeping and create a silent-dead standing REQ — the C3 class on the pool P1 just made ping-less); guard check (7)
pins "no `subscribe_to(`/`subscribe_with_id_to(` in `manager.rs`". (v) Every fetch primitive must leave NO
subscription registered on any exit path (timeout, CLOSED, error) — `should_sleep` is false while ANY subscription
is registered, so a leaked auto-closing REQ = a never-sleeping ping-less socket; pinned by
`every_fetch_primitive_leaves_no_subscription_registered` (`client.subscriptions()` empty after each `RelayManager`
fetch incl. the `read_one_relays_answer` timeout/CLOSED paths — asserted only after `RelayNotification::SubscriptionAutoClosed { id }`
arrives on a notifications stream subscribed BEFORE the fetch: the crate removes an auto-closing REQ from its own task
after the exit policy fires, and Haven's outer `DEFAULT_TIMEOUT` equals the auto-close timeout, so an immediate read
on the timeout path races by milliseconds), cited from the invariant. `publish_event` (3-attempt
ladder) stays for commits, welcomes, proposals, KP, relay lists, profile (Rule 13: "acked means acked" — an
`Ok(EventId)` from `Relay::send_event` IS a relay OK, `inner.rs:1350`). ENGINE pool untouched in P1 (§2.3 trap); the
guard pins that `session.rs` gains no `.ping(false)` / `.sleep_when_idle(` CALL (the bare word appears in two kept
comments, `:1536`, `:1933`) until P4's state machine owns it. Presence metadata strictly decreases; the engine's 55 s
ping on iOS-bg remains until P4 (stated honestly in P1's docs).

### D6 — Network step 2: iOS background burst receive (P4) [OD4]
While backgrounded on iOS with sharing ON the engine holds NO standing REQ and NO socket between publish
ticks; each tick is one bounded burst in the main isolate (the isolate holding the `AccountDeviceSession`):
open → ingest backlog → publish at the current epoch → fold due maintenance → settle → close. Foreground
keeps today's persistent engine. **Amendments (each V):** (i) NOT "reuse `resume_after_background` unmodified"
and NOT a core per burst: `stop` is terminal and a rebuilt core would rotate the sub-id salt every ~2 min (a
new relay-visible fingerprint; PSI-2 declares intra-session sub-id stability intentional,
`WN_RELAY_EPOCH_SYNC_MIGRATION.md:644`) and re-spawn the Rule-14 task set per burst → ONE new core method
`pause_subscriptions()` (the lifecycle lock is held for the WHOLE call, so a burst open serialises behind a
draining pause and can never have its fresh router entries wiped by the marker; `paused.store(true)`; then, in
this order: **(a)** `bounded(RELAY_LIFECYCLE_OP_TIMEOUT, client.unsubscribe_all())` followed by the POST-CONDITION
sweep `client.subscriptions().await.is_empty()` with a per-id `client.unsubscribe(id)` for every leftover — a
partial `unsubscribe_all` on a non-operational relay leaves later ids REGISTERED and the crate's `resubscribe()`
would re-send that OLD REQ on the next connect ahead of the session's own, letting a stale EOSE consume the new
generation's advance (F27); the sockets stay OPEN (nothing new arrives, but in-flight OKs still can);
**(b)** enqueue a `RawSignal::Pause` marker into the worker intake through an intake `tx` clone the core keeps
(today the only `Sender` lives in `run_receiver`, `supervisor.rs:230-231, :373-430`) — `send().await` under
`bounded(RELAY_LIFECYCLE_OP_TIMEOUT, …)`, NEVER `try_send` (a full intake would drop the marker and the router would
never clear) — then await the worker's ack (`oneshot`) under the same bound, short-circuiting when `wedged` is
already set (a dead worker — `report_worker_gone`, `:291`, the FA C6 class — never acks, and an unbounded await
here would hold the lifecycle lock forever: `stop()` blocks on it, `session.rs:964-967`, a logout hang with the
Rule-14 guard held); on EITHER fallback (timeout or `wedged`) clear the router and call `note_delivery_gap()`
directly and `warn!`. The serial worker processes everything queued AHEAD of the marker — including an inline
auto-commit publish and its 10 s OK wait — before it reaches the marker, so an acked marker means: router clear
(no further ingest ⇒ no further gauge increments), every downloaded event applied — DRAIN-THEN-CLEAR, because the
worker resolves the router at PROCESSING time (F30): clearing first would drop every stored event still queued
from the burst's own replay (a `TimedOut` burst's undrained backlog), burn the generation and re-download the same
window on every burst; **(c)** await `in_flight_publishes == 0` (the D6 (v) gauge; bounded by the crate's 10 s
per-relay OK wait) — the authoritative check at the instant of disconnect, because a live SelfRemove can be
ingested and SENT in the window between `settle_before_pause` returning and the pause reaching this point;
**(d)** `client.disconnect().await` → `Terminated`, never `shutdown` (radio off) — only now, so "the pause can
never cut a commit between SEND and OK" holds by CONSTRUCTION (a disconnect before the marker would cut a commit
the worker ingests after the settle wait, or leave events drained after the disconnect able only to roll back —
the S-1 fork in a ms window); **(e)** `repair.clear()` (P4-M7 below); `active` retained). Burst open = `resume_after_background`,
extended: it clears `paused` under the lock, runs `client.add_relay` over the UNION of `active.group_subs` and
`active.inbox_relays` relay sets BEFORE `connect()` (idempotent, `pool/mod.rs:281-283` — a circle subscribed while
paused is otherwise issued to a relay the pool does not hold, `retry_until_accepted` exhausts, the WHOLE open
fails on the `?` per bucket `:886-890`, and the throw-path rule pauses again: the circle never receives in the
background, silently — the P4 analogue of the FA "stuck row"), and runs a second bounded `unsubscribe_all` before
`connect()` if the pool view is non-empty (a CLOSE queued on a `Terminated` relay is flushed on reconnect ahead
of the new REQ, the order we want). `sleep_when_idle` cannot substitute (F4: never sleeps a relay holding a
subscription; 60 s granularity). **Status while paused:** `pause_subscriptions` emits ONE `SyncStatusReason::Paused`
→ new `SyncConnectionPhase.paused` (clears `_disconnectedSince`, never a fault); `run_monitor`'s per-relay
`Disconnected` on the `Terminated` transitions is SUPPRESSED while `paused` and `recordRelaySubscriptionSignal`
ignores `paused` — otherwise (F31) the health model stamps `_disconnectedSince` and, since a burst interval can be
exactly 168 s, confirms `relayDisconnected` on a deliberate pause; each burst's `Reconnecting`/`Connected` per
relay is harmless status churn while backgrounded (say so in the enum doc). (ii) A `paused` flag gates: `run_repair`
BEFORE `take_due` (`take_due` clears `due_at`, bumps `attempts` and arms the next backoff, F28 — an early return
inside `reissue` would CONSUME the pending re-issue, not keep it; a belt-and-braces `paused` check stays in
`reissue`), and `pause_subscriptions` DRAINS the repair queue (`RepairQueue::clear`) because burst open re-issues
every REQ under a fresh generation by construction — a queued repair firing after burst open would replace a live
REQ and reset its generation mid-burst (the lost `next_allowed_at` throttle for `rate-limited:` closes is already
ignored by today's `resume_after_background`); `maintain_subscription_health` short-circuits BEFORE `health_probe`
→ new `HealthAction::Paused` (the single most important gate: otherwise `health_needs_resubscribe` sees every
relay `Terminated`, calls `resume_after_background` and re-opens standing REQs in the background, silently undoing
P4); `subscribe_circle` while paused = WSS gate → COLD-START CURSOR SEED (`session.rs:1232-1240` — without it the
next burst's `bucket_since` reads `unwrap_or(0)` and issues the forbidden `since = 0` REQ, F32) → derive the
sub-id → push `LiveGroupSub` to `active` (no router entry, no REQ, no `add_relay`; the Dart resubscriber
`map_shell.dart:728-731` is not lifecycle-gated); `unsubscribe_circle` while paused = remove from `active` +
`forget_subscription(hex)` only (its REQ is already closed). (iii) `suppress_open_generations` (via
`note_delivery_gap`), NOT `forget` — `forget` drops the hold-back (F13); a `Buffered` hold-back must survive the
pause so the next burst's `open_generation` carries it. Late EOSE/CLOSED/events after the marker are dropped by
the worker because the router is cleared (F14). The guard pins the two load-bearing facts — no `forget_*` in the
pause path; `disconnect`, never `shutdown` — not a call order. (iv) **Bounded inbox lookback is a PRECONDITION**,
not a nice-to-have: `since_for_stream`'s inbox branch runs before the phase match (F15), so every burst would
replay 7 days of gift wraps → `Resubscribe` uses `INBOX_RESUBSCRIBE_LOOKBACK_SECS = 2 × 86_400 + 3_600` (NIP-59
backdates `created_at` by ≤ 172 800 s; the 7-day figure was "±48 h plus a wide margin", `cursor.rs:74-77`; 1 h
absorbs relay/clock skew); `Initial` keeps 7 d (cold start; the seed is `now − 24 h`, `session.rs:56`; the gift-wrap
dedup retention `storage.rs:3065-3066` is tied to the 7 d constant and stays correct only while `Initial` keeps
it — say so there). The poisoning guarantees stay: the inbox cursor advances ONLY to the REQ's own local open time
on EOSE (`anchor.rs:336-360`), clamped to `now`; no event timestamp enters (`check_no_event_timestamp_cursor_advance.sh`).
**Residuals, stated precisely (F33):** the floor is `clamp(cursor − L, 0, now)`; the cursor is frozen while no
inbox EOSE is consumed, so a 3-day network outage with the process alive leaves floor = `T_lastEOSE − 49 h` and
a wrap with `created_at ≥ arrival − 48 h` is still fetched; a wrap is MISSED iff the sender's clock is > 1 h slow
AND it used a near-maximum backdate — and "recovered by the next cold start" holds only within ≈ 5 d of arrival
(`Initial` = 7 d); second residual: an inbox relay unreachable for > 49 h while another relay advances the single
un-keyed inbox anchor loses wraps only that relay holds (today the same loss at 7 d) — both in the constant's doc.
The foreground re-anchor (F18), CLOSED repairs (`reissue`, `Resubscribe`) and the health tick's
`resume_after_background` all inherit the bound (closes R14's "7 days of gift wraps every re-anchor" for the
FOREGROUND too — a bigger win than "for free"). Other in-tree "7-day replay" statements P4-1 rewrites:
`cursor.rs:20-24`, `anchor.rs:355-359`, `config.rs:249-252`, `session.rs:1656-1660`, FA:697-703. **Rule-10
consequence named, not hidden:** inbox relays (kind 10050, `map_shell.dart:691`) and circle relays are independent
sets (`SECURITY.md:864-866`); today an inbox-ONLY relay sees one continuous socket, after P4 it sees a REQ/CLOSE pair
every 72–168 s ± 40 % = "this pubkey is background-sharing right now" — a NEW inference for that relay class, so OD4
"strictly narrows RC1" is withdrawn; **OD4-b** offers folding the inbox REQ into every k-th burst (≥ 10 min, matching
the KP fold) at ≤ 10 min background invitation latency. (v) `wait_backlog_settled(timeout)` counts EOSEs per expected
`(relay, sub)` ENDPOINT THIS burst issued AND whose REQ the burst's `subscribe_bucket` ACCEPTED (it returns the
accepted relay set — today it accepts ≥ 1 and discards `Output`, and one dead relay in a bucket would otherwise make
every burst `TimedOut`, +5 s and +5 J forever; a burst that issued no inbox REQ — every non-k-th burst under OD4-b —
expects no inbox endpoint, else it times out by construction; the set `probe_subscriptions`/`open_delivery_windows`
already track, `session.rs:430-436`, is the starting point), NOT per circle: a bucket REQ goes to several relays and `note_eose(group_hex)` consumes the circle's single
generation on the FIRST relay's EOSE (F30) while a slower relay — possibly the only one holding Bob's commit — is
still replaying; `BURST_BACKLOG_WAIT_SECS = 5` unchanged; the `Notify` fires from the worker's EOSE/CLOSED handling
per endpoint; after `note_delivery_gap` the anchor's `eose_consumed == true` means "advance burned", not "EOSE
seen", so a Rule-12 intake drop mid-burst reads as `Settled` — accepted (publish anyway, as today) and documented.
`settle_before_pause(timeout)` is STRUCTURAL, not time-based: `EngineProcessor` holds an in-flight gauge
`in_flight_publishes: AtomicUsize`, incremented BEFORE the publisher call in `resolve_publish_work`
(`process_group_event`) and decremented in a drop guard; `settle_before_pause` first awaits `gauge == 0` with NO
cap (the gauge is bounded by the crate's own 10 s per-relay OK wait — the engine auto-commit is `send_event_to`
awaited inline in the serial worker, F29), THEN keeps the sockets open for `COMMIT_SETTLE_WINDOW_SECS` 8 s after the
last commit activity (`GroupUpdate` or `AutoPublish` — `route_events` has no `EpochChanged` variant), the
`BURST_SETTLE_CAP_SECS = 18` cap applying to FOLLOW-ON activity only; a quiet burst pays zero. The gauge is
checked a second time INSIDE `pause_subscriptions`, after the marker ack and before `disconnect` (D6 (i) (c)) —
`settle_before_pause` is a separate FFI call, and the ms window between its return and the pause's `disconnect` is
exactly where a live SelfRemove could otherwise be ingested, sent and cut. Why: a time-based cap
would `disconnect` a commit between SEND and OK, `wait_for_ok` → `Err` → `publish_failed` → rollback to epoch N
while the relay may have stored and served the commit — a roster fork every ~2 min in the background (Rule 13); with
the gauge the worst-case burst is ≤ 18 + 10 s. One-epoch-behind, stated right: if the backlog wait times out the
encrypt may run one epoch behind; peers decrypt that from PAST-epoch keys (`wire_format.rs:52-57`) — `Buffered` is
the FUTURE-epoch verdict — and convergence resolves it on the next burst; never a nonce reuse. (vi) Presence
statement (no user-facing copy: the Privacy page that carried the presence and one-connection sentences was removed
2026-08-29; the statement lives in SECURITY.md/M11, §5.4): background presence is made TRUE on Android by two P1/P2a changes: the FGS shuts its publish pool down at the end of every cycle (`finally`,
after the fetch step — today `_relayService?.shutdown()` runs only in `onDestroy`, `background_location_task.dart:553`,
so under D5 alone the socket would linger ≤ 70 s), and KP/relay-list/health arming is foreground-gated on BOTH
platforms (D8 — today the Android UI isolate's 10-/30-min timers ride the publish pool ungated,
`maintenance_scheduler_provider.dart:224-225,255-264`); the statement says "connects briefly" (D5 worst
10 s, a P4 burst worst ≈ 33 s — never "a few seconds") and that the circles' updates are picked up at the same instants (the
FGS fetch is once per `kLocationUpdateInterval`, `:1406-1408`); the two-socket fact (§1.2) is recorded in the RC1
summary; NEW enforced invariant `INV-R-BACKGROUND-PRESENCE-ONLY-AT-PUBLISH` (no disclosure key);
`INV-R-CROSS-PLANE-CORRELATION` (statement narrowed to "in the foreground" + the inbox-relay cadence residual; no
ARB keys since 2026-08-29); no ratchet item. (vii) The 15-min health tick is NOT folded
(nothing to heal without a standing REQ; the burst re-subscribes by construction); KP 10-min and relay-list 30-min
ARE folded ("if due, run after this burst on the warm socket"). **Dart rules:** the coordinator and everything it
calls while paused use `ref.read` / direct calls / `listenManual` only — no `ref.watch` in
`background_burst_coordinator.dart` (lint test; §2.2a); the burst ends with `pauseSubscriptions()` in a `finally`
on throw AND on cooperative cancellation (the chain re-checks `bgEnabled` between links; a C4 cancel in the last
seconds before suspension must still pause); no `.timeout(` may wrap commit-critical work — `_handleDeferredSend`,
`confirmPublished` AND the `pauseSubscriptions()` link itself (its marker await is bounded by queue depth ×
decrypt time, minutes on a large backlog; the FGS's UNBOUNDED commit-critical drain is the model, `:1425-1438`);
check 8's `.timeout(` sits on `_dispatchTick` as a WATCHDOG that NEVER cancels the running burst (Dart
`Future.timeout` does not cancel the underlying future — the chain must ignore the timeout and only report it),
with `BURST_BOUND` (≤ 5 s connect + 5 s backlog + N × 10 s publish + 28 s settle; the pause link excluded) pinned
`< _publishLinkTimeout` (3 min, `location_publish_scheduler_provider.dart:157`) so a healthy burst is never reported
late for N ≤ 12; the C4 edge REQUESTS cooperative cancellation (the flag the chain checks between links) instead of
calling `relay.shutdown()` while a burst may be mid-`_handleDeferredSend` — the current commit-critical link confirms
or rolls back first, then the `finally` pauses. **Rejected alternative:** merged pools with a ping-less standing REQ — still one radio wake per INBOUND
peer event (research §3.2: 60 vs 30 wakes/h for one circle) and turns the two-socket `#h`/`#p` linkage from probable
to certain. The burst also makes iOS-bg receive symmetric with the Android FGS. ⇒ **OD4** (M11 §6.1 "standing socket
while foregrounded" becomes literally true again; the inbox-only-relay cadence inference is the honest cost) and
**OD4-b**.

### D7 — Publish coalescing (P5) [OD3, separable]
**(a)** One jittered burst per nominal interval publishes every eligible circle in a CSPRNG permutation with
the EXISTING stagger between consecutive encrypts — `kPublishStaggerMinGap` 2 s, `kPublishStaggerMaxGap` 9 s,
`kPublishStaggerMaxSpread` 30 s all UNCHANGED: variant (a) coalesces the WAKE and the burst, it does not shrink
the stagger. Why the numbers stay: the wake count is identical either way (one socket wake per burst; the
longer tail costs ≈ +3 J per extra circle per burst, I — radio energy is per wake, §2.3), and `created_at` is
whole seconds, so a 2.0–2.5 s gap would yield a delta of 2 or 3 s on EVERY burst — exactly the "a constant
stagger is itself a fingerprint" case `publish_stagger.dart:37-39` was written against; 2–9 s keeps the
whole-second deltas spread over eight values. Spread arithmetic, corrected: `maxGapFor` floors the per-gap at
`min + 1 s` = 3 s (`:119-127`), so the 30 s cap engages from n = 5 (30/(n−1) < 9) and yields at n = 12 (per-gap
`max(3, 30/11)` = 3 s → 33 s spread, as the `maxSpreadFor` doc says); the no-gap invariant holds in every regime
(168 + 33 < 228, `ttl.rs`), and the P5 test sweeps n = 2..12: `spread(n) ≤ maxSpreadFor(n)` and
`maxSpreadFor(n) ≤ kPublishStaggerMaxSpread` for n ≤ 11. (The drafted 2.5 s / 5 s constants would ALSO have
broken P2: the FGS due-horizon rode `kPublishStaggerMaxSpread` — now its own `kBackgroundFixHorizon`, D3 (iii).)
Reverses `INV-R-PER-CIRCLE-PUBLISH-DECORRELATED` (2026-07-26) on the honest ground that shared-relay
decorrelation never held (R-G); requires the manifest `ratchet_override`, a new accepted deviation
`PUB-COALESCE` and SECURITY.md/ttl.rs/README rewrites (no copy round: the Privacy page that would have carried the
disclosure was removed 2026-08-29, and a zero-disclosure accepted deviation is a permitted state since then). **What
(a) newly reveals, and the deviation record must say:** with one shared tick sequence, circles on DISJOINT relay sets emit IDENTICAL
inter-burst interval sequences, so relays each carrying only ONE of your circles can match the timing —
"anyone who can see more than one of your circles' relays can tell they belong to the same phone" (the
observer the downgraded invariant names, `privacy_invariants.json:1808`) — not merely "a relay that carries
several of your circles". **(b)** if OD3 is declined: keep per-circle due times and share only the WAKE (and the
access-gate read) when due times fall inside one stagger window — the foreground adopts the FGS's
`PerCircleDueTracker` model, invariant intact. **Honest note:** (b) saves almost nothing on iOS-bg under D6 — N
independent schedules are N bursts per interval (wakes ≈ N × 30/h); coincidence inside a ≤ 30 s window for
uniform [72,168] s draws is occasional. (a) is the only variant that reaches ~30 wakes/h for a multi-circle user;
(b) is a CPU tidy-up worth landing anyway.

### D8 — Foreground/lifecycle hygiene (P1; no promise change)
Self-marker pulse stops after idle / own `RepaintBoundary`; `MapPage` per-fix `setState` throttled to
visibility; `LocationAccessNotifier` watchdog touches a timestamp instead of cancel+recreate per fix (one armed
Timer per interval); resume extras (KP/relay-list probes, profile refresh, prunes, tile eviction) behind
`kResumeExtrasMinInterval = 10 min` (= the KeyPackage maintenance cadence, the shortest of the extras' own
timers, `maintenance_scheduler_provider.dart:101-126`) — the immediate publish on resume, the
`memberLocationsProvider` invalidation and the 60 s-guarded re-anchor stay unconditional (a promise); the
`SharingHealthBanner` widget `_rerender` timer armed only while foregrounded (**rule:** the packet starts with a
failing test proving the timer fires while `AppForegroundNotifier` is false; if it cannot be made to fail the
item is dropped, not implemented — the provider tick is already gated, `sharing_health_provider.dart:186-200`);
the banner's resume re-derivation (`sharing_health_provider.dart:301-306`; `sharing_health_banner.dart:329-346`)
must re-render AND announce (both pinned); the live-region label must not embed the rounded age (`:408` —
TalkBack re-announces a persisting fault every 72 s) BUT the age must stay reachable: every banner child sits under
`ExcludeSemantics` (`sharing_health_banner.dart:415`), so the age `Text` becomes its OWN non-live semantics node
OUTSIDE the excluded subtree while the live node keeps title + epoch message (WCAG 1.3.1); "announce on resume"
means: fault cleared while away → the existing resumed announcement; fault persists → ONE
`SemanticsService.announce(title + age)` on the resume re-derivation (a still-mounted live region does not re-fire);
tests "age is exposed as a non-live node and is stable across ticks", "resume with a persisting fault announces
once"; **maintenance timers foreground-gated on BOTH platforms:** KP 10-min, relay-list 30-min
and health 15-min arming checks the foreground state (today only the profile sweep does,
`maintenance_scheduler_provider.dart:476-496`; the KP/relay-list timers ride the publish pool ungated on Android,
`:224-225,255-264` — periodic connects unrelated to a send, which is what the P4 presence copy denies), re-armed
on resume with their normal jittered delays (test "no maintenance timer is armed while backgrounded on
Android"); release-log `format!` guarded by `log_enabled!`; **engine stopped on Android pause when sharing is
OFF** (`_onPaused` stops it only inside the Android+bg branch `map_shell.dart:1282-1334`; the bg-OFF branch
`:1416-1420` leaves N sockets pinging every 55 s until Doze kills them) through a NEW `_stopLiveSyncBounded()`
extracted from `_handOffMlsSession` (`:899-916` — the `liveSync.stop()` + stillHolding half) and used by BOTH
that branch and `_onDetached` (`:1221-1235`, today an unbounded stop); the bg-OFF branch NEVER calls
`releaseForHandoff()` (`:934-942` latches every `getCircleManagerFfi()` closed until `_endMlsSessionHandoff`;
with sharing OFF nothing reclaims, and the R1 watcher `:1394-1400` would publish against a latched manager).
Because `_healLiveSyncIfStopped()` (`:1641`) restarts the engine on EVERY resume, a glance would cost a cold
start with the 7-day inbox replay — so P4-1 (bounded `Resubscribe` lookback, a pure `cursor.rs` change) lands
INSIDE P1 before this item; a 60 s grace timer before stopping is declined (§8 "Not applied").

### Verification decision — emulator batterystats oracle REPLACED
batterystats' per-uid GPS timer is driven by the GNSS provider's navigating transitions (`noteGpsChanged`); on the
goldfish HAL that signal is I-likely never raised, so the assertion would be vacuous-by-construction. Replaced by
a **`dumpsys location` REGISTRATION oracle** (framework-side, deterministic): while backgrounded Haven's uid holds
exactly ONE location request whose interval is ≥ 72 s after the first publish, and the foreground phase must
first show the 1 s request (anti-vacuity). Sampler mechanics are part of the decision (§5.2 B1): every sample is
ONE `adb shell` invocation that prints the DEVICE time first (`date` + `dumpsys location` + `dumpsys power`) so
samples window on the same clock as the logcat markers (host-clock samples against device-clock markers are the
B8 clock-band trap); period ≤ 5 s; started BEFORE `flutter drive` so the foreground 1 s request cannot be missed;
the `Request[…]` grammar is PARSED (`@+1m40s0ms` durations, §2.2), never grepped for `intervalMillis`; lock
presence is judged by the printed `ACQ=` age, never by a consecutive-sample count (a 30 s hold spans 4 samples at
10 s — boundary-flaky). batterystats stays a HARDWARE metric (P0/P6).

### 3.1 The stream-lifecycle design (cross-draft conflict resolved; rebuilt after review)
The iOS draft proposed a keep rule + a never-completing placeholder; the Android draft a `uiLocationStreamSuspendedProvider`
flag + `Stream.empty()` + `LocationAccessNotifier.suspend()`; the first plan merged them into one provider whose
paused branch released the stream. Review showed that branch CANNOT run at pause time (§2.2a: frames are off, the
rebuild lands at the first frame after resume) — so a release that rides a rebuild happens at RESUME, and the
`appForegroundProvider` default `true` would start a background-capable session on a background launch (fail-OPEN
for R7). **Adopted: a service-level synchronous gate; the provider keeps only what a rebuild can honestly do.**
- **Keep rule** (static beside the two existing truth tables, `map_shell.dart:123-126,143-146`):
  `shouldKeepLocationStreamWhilePaused({bg, isIOS}) = bg && isIOS` (the iOS stream IS the keep-alive, R6/R7; Android
  releases in both toggle states). `isIOSProvider = Provider<bool>((_) => Platform.isIOS)` is the seam host tests
  override (the service already has one at `geolocator_location_service.dart:170-172`; the `MapShell` statics keep
  their explicit `isIOS:` parameter).
- **The gate:** `GeolocatorLocationService` owns the plugin/native subscription behind an outer stream
  returned by `getLocationStream` — ONE single-subscription `StreamController<Position>` PER CALL (its `onCancel`
  cancels the inner subscription and clears the service's current-stream fields; a new call first cancels any
  previous inner), never one controller per service: Riverpod cancels the outer on every toggle rebuild
  (`runOnDispose`) and the deferred rebuild calls `getLocationStream` again, so a shared controller would throw
  `StateError: Stream has already been listened to` on the second `listen` — the F2 trap one layer down, and
  `location_provider_test.dart:157` would go red (a broadcast controller is the acceptable alternative);
  `check_ios_background_publish.sh` check 2 keeps its single `.getPositionStream(` site. `suspendStream()` cancels
  the inner subscription SYNCHRONOUSLY (cancel, not close: the service's `handleDone`/`handleError` do not fire,
  `:793-796`, so the cache survives per the consent rule); `resumeStream()` re-subscribes the inner with the current
  settings whenever the OUTER has a listener — even if the inner errored or completed while foregrounded
  ("subscribed" means "the current outer has a listener"), which is what makes the skipped recovery `invalidate`
  (below) harmless; both are no-ops when the outer has no listener. `_onPaused` calls, before anything else:
  `if (!shouldKeepLocationStreamWhilePaused(bg, isIOS)) service.suspendStream(); if (!bg) service.clearCachedPosition();`
  — the cache is cleared on the CONSENT condition (`!bg`), not on `!keep` (the iOS draft's `!keep` conflated "not
  iOS" with "no consent"; the Android draft's Rule-10 reading wins): with sharing ON the warm Android fix survives for
  the 168 s gate-checked window (freshness is the gate's job) and the resume publish is served from it; with sharing
  OFF no coordinate survives the pause on either platform (native `clearLastBestFix` rides the same call, D1).
  `_onResumed` calls `service.resumeStream()` FIRST — the ONLY restart site, foreground by construction (R7 stays
  structural). The C4 watcher (`_bgSharingPausedSub` false edge, `map_shell.dart:1402-1414`) calls `suspendStream()`
  + `clearCachedPosition()` + `disarm()` DIRECTLY (today's "downgrade via the rebuild" comment `:1409-1411` describes
  a rebuild that is deferred to resume — pre-existing); the R1 edge (false→true while paused) starts nothing (R7);
  the keep-alive is (re)established at the next foreground.
- **`locationStreamProvider`** keeps today's toggle-driven body (`rebuilds the stream with new settings when the
  toggle flips`, `location_provider_test.dart:157`, stays true in the foreground) plus ONE fail-closed guard for the
  background-launch case: `appForegroundProvider` is a `StateProvider<bool>` whose INITIAL value is derived from the
  binding — `switch (WidgetsBinding.instance.lifecycleState) { resumed || inactive || null => true, _ => false }` —
  never a literal `true` (lint test), written from `MapShell._setForegroundActive` (`map_shell.dart:1241`, guarded
  for `mounted` AND `ref` liveness — a `StateProvider` write on a disposed container throws at `detached`
  `:1187-1189`), the ONE place that already mirrors lifecycle into the service (not from `AppForegroundNotifier`,
  whose `ValueListenable` is not Riverpod-observable, `sharing_health_provider.dart:201-210,223`). Body:
  ```dart
  final service = ref.watch(locationServiceProvider);
  final bg = ref.watch(backgroundSharingProvider);
  if (!ref.read(appForegroundProvider)) {
    // Built while not foregrounded: a background launch (SLC/region relaunch before the
    // first frame) or a forced flush. Never START a session here (R7). The resume write
    // rebuilds this provider (the only place that watches the foreground state).
    ref.watch(appForegroundProvider);
    final paused = StreamController<Position>();   // per build — a single-subscription
    ref.onDispose(paused.close);                   // stream cannot be listened to twice
    return paused.stream;                          // never emits, never closes, never errors
  }
  if (!bg) service.clearCachedPosition();   // foreground opt-out: this rebuild DOES run (frames on)
  return service.getLocationStream(backgroundSharingEnabled: bg);
  ```
  The `!bg` clear STAYS in the foreground body: a foreground opt-out (settings page, app open) rebuilds at once —
  §2.2a's frame argument applies only while paused — so today's Rule-10 pin (`location_provider.dart:46-48`, check 5
  `:236-237`, `location_provider_test.dart:182`) keeps its meaning, and the pause-time / C4-watcher clears cover the
  paused cases. The foreground build never watches `appForegroundProvider` (a `watch` there would tear the kept iOS session down
  at the resume rebuild — the reviewer trap); the placeholder is NOT `Stream.empty()` (an empty stream COMPLETES,
  and "a stream that completes WITHOUT error also surfaces the state" is pinned at
  `location_access_provider_test.dart:346-366`) and is per-build (a shared `_never` throws
  `StateError('Stream has already been listened to.')` on the second paused build → `AsyncError` → the outage path
  the placeholder exists to avoid). The `ref.read` inside the body is deliberate (no `riverpod_lint`, §2.2a) and
  guard-pinned (function-shaped `check_stream_provider`, §5.1).
- **`LocationAccessNotifier`:** `suspend()` sets `_suspended` (cancels any armed timer; `_armWatchdog` inert; `_apply`
  never `invalidate`s the stream while suspended — the recovery edge `:523` would otherwise cancel the kept iOS
  session NOW and rebuild at resume, §2.2a); `_suspended` is cleared ONLY by an explicit `resume()`, never by
  `refresh()` — `refresh()` is also reached from the `AsyncError` branch (`:250-263`), `map_page`'s retry and a failed
  one-shot, so a stream error while paused (permission revoked in Settings) would otherwise re-open the 30 s probe
  loop for the whole background; `refresh()` still publishes the verdict while suspended (the banner must be right on
  return). `_onResumed` calls `resume()` then `refresh()` (the source-order test at
  `map_shell_location_access_lifecycle_test.dart:221-254` keeps its `refresh` anchor).
- **Pause/resume ordering:** `didChangeAppLifecycleState(paused)` → `_setForegroundActive(false)` (service flag +
  provider write; no rebuild runs) → `_onPaused()` (`map_shell.dart:1181-1184`): `suspendStream()` (+ cache clear on
  `!bg`) → `locationAccessProvider.notifier.suspend()` (`:1280`) → `stopScheduling`/`_stopMotionTrigger`
  (`:1290-1291`) → `writeLastPublishTime` → `markForegroundActive(false)` (`:1308`) → handoff (`:1322`) → P2a's paused
  signal (only if the handoff succeeded). Resume, with its gates (D3 (vi)):

  | Resume action | Gate |
  |---|---|
  | `resumeStream()`; `locationAccessProvider.notifier.resume()` + `refresh()` (`:1584`); `markForegroundActive(true)` + `waitUntilIdle()` + `fgsNotificationOpen` + `_lastPublishTime` seed (the Android reclaim block, `:1658-1685`); P2a's resumed signal; `_endMlsSessionHandoff()` (`:1602`); `_healLiveSyncIfStopped()` + `_rearmLiveSyncHealTimer()` (`:1641`); `_startTimers()` (`:1690`, idempotent) | none |
  | immediate publish (`locationPublisherProvider`), `memberLocationsProvider` invalidation, 60 s-guarded re-anchor (bypassed when the engine is `Paused`, P4) | 30 s debounce (`:1644-1651`) |
  | KP/relay-list probes, `triggerProfileRefresh`, `_runPrune()`, `tileCacheEvict` | 30 s debounce AND `kResumeExtrasMinInterval` (10 min) |

---

## 4. Owner decisions register

**Decisions taken by the owner on 2026-08-29: every recommendation below is ACCEPTED** — OD1 (indicator off under confirmed Always, no extra setting), OD3 (coalescing variant (a)), OD4 (background burst receive), OD4-b (inbox REQ every k-th burst), OD-P2-1 (FGS owns GPS), OD-P2-2 (P2b = native `PendingIntent` registration, not "measure and accept"), OD-P2-3 (NO `SCHEDULE_EXACT_ALARM`; inexact alarm default), OD-P3-a (120 s), OD-P3-b (WIU policy on iOS 17 provisional Always), OD-P3-c (fund the Always run), OD-P3-d (100 m). The "If declined" column is kept only as the record of the alternative; no phase is gated on a pending decision any more.

| OD | Question | Recommendation | Gates | If declined |
|---|---|---|---|---|
| **OD1** | Indicator OFF under CONFIRMED Always (`showsBackgroundLocationIndicator = !alwaysConfirmed`, no `CLBackgroundActivitySession` there), no extra user setting | YES — the OS arrow, Settings › Privacy › Location Services attribution, Settings › Battery "Background Activity" and Haven's own toggle remain visible; DTS advises against tricks, not against the property; every Always-tier reference app leaves the flag off. Honest consequence: provisional-Always users on iOS 18+ keep the pill until they answer the second prompt, and EVERY iOS 17 Always user keeps it for as long as they stay on iOS 17 (no diagnostics API — `alwaysConfirmed` never becomes true there); the card says so because its indicator sentence follows the handler's state (D2) | P3 copy (base + arrow/bar keys), `INV-L-IOS-INDICATOR-HONEST`, `check_arm_tier_policy`, M7 §6 item 0a (a WP3-2 MERGE gate) | P3 ships the accuracy profiles with the flag left `true` under Always (drain fix intact, pill stays); the arrow key is then never selected and the bar key renders under every tier — copy variant drafted in §7.1 so the copy-tie test has a target either way; a user setting would be one `showsBackgroundLocationIndicator` input to the same Swift line + one ARB key |
| **OD3** | Publish coalescing variant (a): one burst per interval with the EXISTING 2–9 s CSPRNG stagger / 30 s spread; reverses `INV-R-PER-CIRCLE-PUBLISH-DECORRELATED` | YES for multi-circle users (the invariant never held at a shared relay; ~30 wakes/h vs N × 30). Honest cost, newly recorded in SECURITY.md and the deviation entry (no user-facing surface since 2026-08-29): identical inter-burst sequences let ANYONE holding two of your circles' relay archives — each relay carrying only one circle — tell they belong to the same phone | whole P5(a): manifest status → `accepted_deviation` PUB-COALESCE via `ratchet_override`, SECURITY.md subsection (no copy round since the Privacy page's removal, 2026-08-29) | P5(b): wake-sharing only, invariant intact, CPU-only win; default when declined |
| **OD4** | Background burst receive on iOS: presence only at publish instants; foreground unchanged | YES — narrows RC1 (`INV-R-CROSS-PLANE-CORRELATION`) for CIRCLE relays and makes M11 §6.1 literally true again. NOT "strictly": an inbox-ONLY relay (kind 10050 set, independent of the circle sets) today sees one continuous socket and after P4 sees a REQ/CLOSE pair every 72–168 s ± 40 % = "this pubkey is background-sharing now" — named in §5.4, SECURITY.md and the RC1 summary | whole P4 incl. `INV-R-BACKGROUND-PRESENCE-ONLY-AT-PUBLISH` (no copy round since the Privacy page's removal, 2026-08-29) | iOS-bg keeps the standing engine socket (55 s pings, 15-min re-anchors, 7-day inbox replays on drop); P1's D5 and the bounded lookback (landed in P1) still stand |
| **OD4-b** | Fold the inbox (`#p`) REQ into every k-th burst, k chosen so k × nominal interval ≥ 10 min (the KP fold cadence), instead of every burst | YES — removes the inbox-only-relay cadence inference at the cost of ≤ 10 min background invitation latency (invitations are not location-fresh) | P4-2 (`inbox_every_kth_burst`), Rust test `a_burst_reissues_the_inbox_req_every_kth_burst`, P2c oracle "no `#p` REQ between bursts" | inbox REQ on every burst; the inference stays and is disclosed as such |
| **OD-P2-1** | `P0_1_FGS_SESSION_PLAN.md:430-433` GPS-ownership decision — P2 decides "the FGS owns GPS while backgrounded; UI stream released at pause; no `Position` injected across isolates" | accept | P2a doc record | none viable — the alternative (UI isolate keeps GPS) is R-C |
| **OD-P2-2** | The delivery→Dart suspend window U-P2-1 exists ONLY once the plugin lock is gone (P2b); its consequence is a ONE-CYCLE TTL BREACH (realized gap ≈ J + I ≤ 326 s > 228 s: every peer's marker expires once) at a probability p only hardware can measure | decide P2b's design on that consequence: the native `PendingIntent`/`LocationListener` registration (D4, BR-1) closes it BY CONSTRUCTION (the lock is acquired inside the system's delivery hold) — recommended over "measure p and accept" | P2b design + the forced-idle liveness row | accept the breach at measured p (recorded as an accepted residual with its number) |
| **OD-P2-3** | `SCHEDULE_EXACT_ALARM` for the P2b no-fix watchdog: a NEW disclosure surface (special-access "Alarms & reminders" prompt, Play policy exposure, 13-locale copy, `docs/privacy` coverage) | NO — the default candidate is an inexact `AlarmManager.set()` while battery-exempt (fires in Doze, no permission; up to ~75 % late = a BOUNDED TTL breach, never a silent stop); revisit only if the P2b hardware row shows the inexact alarm landing late in practice; declining also means the NON-exempt cohort keeps the plugin lock in P2b (no ordinary alarm fires in Doze without the exemption — D4 (iii)) | P2b | the inexact alarm for the exempt cohort; the plugin lock for the non-exempt cohort (default) |
| **OD-P3-a** | `kStationaryDwell = 120 s` (one nominal interval) before dropping to HundredMeters | 120 s — longer saves less, shorter risks Best↔100 m flapping at walking pace; in poor coverage the controller spends up to ≈ 59 % of the time at Best (120 s Best / 84 s HundredMeters cycles) — the §6.5 "profile duty" column is the number to re-tune on | P3 constant + `location_test.dart` pin | any value is a one-constant edit + pin |
| **OD-P3-b** | Provisional Always on iOS 17 (no diagnostics API): WIU policy (activity session held, pill shown until the second prompt) or "treat as Always" (no pill) | **WIU policy** (recommendation reversed on review): "as Always" removes the one object added after the 2026-08-20 field failure for a cohort the OS itself treats as WIU — silent publish loss, the FA wedge class; the cost is a pill for a small cohort | P3 `arm()` iOS 17 branch (`alwaysConfirmed` stays false) | "as Always" on iOS 17 — must be recorded as an ACCEPTED liveness risk for that cohort with the V-P3-3 device result attached |
| **OD-P3-c** | Fund a second `e2e-ios-background-publish` run under `location-always` (~40 min/run) | YES — its VALUE is the keep-alive proof under the Always SHAPE: publishes continue from the background with NO activity session held and `alwaysConfirmed == true` (a real runtime oracle, and the only CI evidence for a shape whose closest physical neighbour FAILED on 2026-08-20). The pill itself is HARDWARE-ONLY: a simulator cannot show it and `indicatorShown` would be a self-report the Swift guard already pins statically — the run does NOT claim to prove the indicator. Regardless of the decision, hardware 0a (≥ 2 h stationary, Always, accuracy 100 observed in Console) is a WP3-2 merge gate | P3 lane matrix (`ALWAYS_SESSION_OK`, P2a/P2b under Always) | hardware 0a merge gate + b7's session-held-per-tier oracle are the whole proof for the shape |
| **OD-P3-d** | `kStationaryConfirmMaxAccuracyMeters` — the accuracy a 100 m-tier fix needs to CONFIRM stillness | **100 m** (= `kMotionTriggerDistanceMeters`; changed from 200 m on review). Consequence of any cap C, stated: while confirming fixes keep arriving, a true displacement below 100 m + C goes undetected and the served coordinate is up to that stale — 200 m at 100 m, 300 m at 200 m — against today's 100 m of Best-grade travel; a fix that cannot resolve 100 m cannot vouch for 100 m of stillness, so it is ignored and the 84 s escalation decides with GPS truth | P3 constant + pin + controller test `a confirmed anchor is never more than kMotionTriggerDistanceMeters + kStationaryConfirmMaxAccuracyMeters from any confirming fix` | one-constant edit, with the bound in the doc re-derived |

---
## 5. Phases

Phase order and dependencies: P0 → P1 (incl. P4-1's bounded inbox lookback) → {P2a, P3 in parallel} → P4
(needs P1's D5 and P3's native owner for the lane; OD4) → P5 (OD3; needs P4 for the iOS-bg tick sink) → P2b
(needs P2a's hardware row + OD-P2-2/OD-P2-3) → P6. Every phase is independently shippable.

### 5.0 Phase P0 — Baseline measurement + doc-drift fixes + accuracy pins + literal→constant

**Goal / non-goals.** Deliver the two numbers every later phase is judged against (iOS %/h backgrounded-stationary;
Android per-uid GPS / wake-lock / radio time) on the SAME two phones with the SAME protocol P6 re-runs, and land
every pure addition: accuracy pins on both `_streamSettings` arms (today NOTHING pins `LocationAccuracy.best` —
V: `grep LocationAccuracy\. haven/test haven/lib` hits only the comments at `geolocator_location_service.dart:614,:657`),
the §1.2 drift, and three bare cadence literals converted to constants. Non-goals: no mechanism change, no ARB
change, no manifest status change, no new lane. Battery outcome of P0 alone: none — it makes P1–P5 measurable and un-fakeable.

**Design.** (1) `docs/POWER_MEASUREMENT.md` (new) = the procedure (identical for baseline and acceptance) + a
results template appended per run; OS tooling only (guard 9b, `INV-R-NO-TELEMETRY-SDK`); its verbatim spec is
§6.5 — P0-C copies it out. (2) Accuracy pins are M-class assertions beside the existing filter pins so P3's
profile switch is a deliberate edit that fails a named test (the "two branches cannot converge" contract at
`geolocator_location_service_test.dart:936-947`). (3) Literal conversion keeps every tripwire's MEANING: a bare
literal becomes the constant it silently mirrored; a literal deliberately paired with its derivation stays and
gains a `reason:`. (4) Drift is corrected to TODAY's truth (pre-P1); where a later phase changes the truth again
(the standing-socket sentence) P0 writes the current fact and P6 rewrites it. Promises touched: none.
`INV-L-MOTION-TRIGGER-BOUNDED` / `INV-R-TRAFFIC-METADATA-OBSERVABLE` cite `location_test.dart` names — P0 adds
tests there and renames none (rule 3).

**Exact change list.**
- NEW `docs/POWER_MEASUREMENT.md` (§6.5) + NEW `tooling/e2e/ci/summarize-created-at-gaps.sh` with `--self-test` (the liveness column's script — `summarize-wire-journal.sh` parses the proxy journal, not a relay capture).
- `haven/test/services/geolocator_location_service_test.dart`: in `'getLocationStream(backgroundSharingEnabled: true) sets background-capable AppleSettings on iOS'` (`:894-921`) add `expect(settings.accuracy, geo.LocationAccuracy.best);`; same in `'... false) sets background flags explicitly false on iOS'` (`:923-947`) and in `'uses AndroidSettings with distance filter and interval'` (`:732-751`); NEW test `'the requested accuracy is best on every stream arm and on the one-shot — pinned so a profile change is a deliberate edit'` capturing iOS bg-on, iOS bg-off, Android stream, iOS one-shot (`_currentPositionSettings`, `:612-620`), Android one-shot → all five `LocationAccuracy.best`, `reason` naming P3 as the only sanctioned mover.
- `haven/test/services/per_circle_due_tracker_test.dart:196`: `lessThan(const Duration(seconds: 72))` → `lessThan(kBackgroundRepeatInterval)` (the `reason:` two lines below already names it — V).
- `haven/test/services/publish_stagger_test.dart:136-139`: `const Duration(seconds: 228) - kLocationPublishMaxInterval` → `Duration(seconds: kLocationPublishMaxInterval.inSeconds + 2 * kTtlNetworkBufferSeconds) - kLocationPublishMaxInterval` (keep the subtraction shape so "retention minus max interval" stays literally true). Do NOT import `kLocationMessageRetention` from `sharing_health_provider.dart` into a service test — `sharing_health_recording_sites_test.dart:143-150` pins that declaration's exact text and site.
- `haven/test/widgets/circles/circle_details_layout_test.dart:144`: `overrideWith((_) async => 228)` → `overrideWith((_) async => kLocationMessageRetention.inSeconds)` (V-P0-1: confirm the import; else inline as in `publish_stagger_test`).
- `haven/test/services/location_sharing_service_test.dart:172`: KEEP `expect(capturedUpdateIntervalSecs, 198);` and add `reason: 'deliberate tripwire paired with the derivation above — a cadence change must be a visible edit here, never a silent shift'` (same pattern as `sharing_health_provider_test.dart:683-688`; converting it would delete the tripwire).
- Docs: every row of §1.2 (16 edits incl. the two-socket fact recorded in the RC1 `accepted_deviations[]` summary and `WN_RELAY_EPOCH_SYNC_MIGRATION.md:312-313`) plus the citation-drift sweep of this plan — `M7:3-8`, `:332-336` (historical note "(at M7 time; flipped by M11 — see `docs/M11_ROLLOUT.md`)"), `:462` ("`defaultValue: true` within 3 lines of the `bool.fromEnvironment` declaration (14b)"), `:838-840`, `:1196-1199` (keep the `kMotionTriggerDistanceMeters` sentence; "the 5 m drip's only remaining role is to keep fixes flowing"), `FA:58-62`, `FA:250-253` (mark UNCITED, contradicted; replace with `research/reference_apps_strategies.md` §7 findings), `CI_HARDENING_BACKLOG.md:2110` (append a DATED qualifier — a backlog is a log), `M11:117` + `SECURITY.md:873-878` (today's truth: the disclosure got MORE alarming, not less; heading `### Relay-observable metadata and correlation (accepted)` is a manifest `doc_anchors` target — byte-identical), `SECURITY.md:257-263` (Android sentence false), `constants/location.dart:49-50`, `config.rs:268-271` (delete both constants; `cargo clippy -- -D warnings`), `ios_location_auth_service.dart:3-5`, `AndroidManifest.xml:117`, `WN_RELAY_EPOCH_SYNC_MIGRATION.md:178,:243` (U until checked; correct with URL + date), `MESH_LOCATION_RELAY_DESIGN.md:181,:422-423`.
- Guards/ARB/native: none; manifest: the RC1 summary sentence only (prose — no key, status or citation change, so no ratchet item).

**Tests FIRST.**
| file → test → promise it fails on |
|---|
| `geolocator_location_service_test.dart` → `the requested accuracy is best on every stream arm and on the one-shot …` → "the OS is asked for GPS-grade fixes on every path" (P3 rewrites deliberately) |
| same → the three inline `expect(settings.accuracy, best)` additions → same promise per arm |
| `per_circle_due_tracker_test.dart` → existing test, constant-derived bound → fails if `kBackgroundRepeatInterval` decouples from the min interval |
| `publish_stagger_test.dart` → `'the spread budget is dominated by the freshness constants it must respect'` → no-gap slack expressed from `kTtlNetworkBufferSeconds` |
| `circle_details_layout_test.dart` → existing sweep → layout pinned to the app's own retention constant |
| Mutation: add `accuracy: geo.LocationAccuracy.medium` to one arm → exactly that arm's test and the five-way test go red; revert |

No existing test goes red. Commands: `cd haven && flutter test test/services/geolocator_location_service_test.dart test/services/per_circle_due_tracker_test.dart test/services/publish_stagger_test.dart test/widgets/circles/circle_details_layout_test.dart test/services/location_sharing_service_test.dart && flutter analyze`; `cd haven-core && cargo test && cargo clippy -- -D warnings`; `scripts/ci/check_privacy_invariants.sh --no-ratchet` (anchors untouched — must stay green); `scripts/ci/check_coverage.sh --static-only`.

**Implementer work packets.**
| # | Packet | Parallel? | Done when |
|---|---|---|---|
| P0-A | Accuracy pins + three literal conversions + `:172` reason (tests only) | ∥ B, C | the five named tests green; mutation check performed and reverted; `flutter analyze` clean; `--static-only` green |
| P0-B | §1.2 drift (16 edits) + `config.rs` deletion + `ios_location_auth_service.dart` comment + manifest comment + the plan's own citation-drift sweep (§1.2 note) | ∥ | `check_privacy_invariants.sh --no-ratchet` green; `cargo clippy -- -D warnings` green; every replaced sentence cites the source of the new fact |
| P0-C | `docs/POWER_MEASUREMENT.md` (protocol + empty results template, §6.5 verbatim, incl. the mandatory relay-side capture and the profile-duty column) + `tooling/e2e/ci/summarize-created-at-gaps.sh` (+ `--self-test`, healthy/229 s fixture pair) | ∥ | reviewed by the P6 reviewer for reproducibility (a second person can run it from the doc alone); `summarize-created-at-gaps.sh --self-test` green |
| P0-D | **Owner-run baseline** (hardware): run the protocol per platform (S ≥ 3 h on iOS — Settings › Battery is whole-percent, so 60 min cannot resolve a ≤ 1 %/h target — or 3 × 60 min summed; S 60 min on Android; W 30 min both), fill the template, commit under `## Baseline <date> <commit>` | after P0-C | both phones' rows filled; the relay-side `created_at` gap column ≤ 228 s (`kLocationMessageRetention`) throughout — the promise the app makes; today's derived worst case is 240 s (D3 (iii)), so an observed > 228 s gap is a P0 finding (stop and file it under FA §7), never a false failure at 169 s |

**Reviewer checklist.** Every doc edit replaces a wrong fact with a cited right one and deletes no load-bearing
rationale (R1–R14 in `_docs_a11y.md` §0); the `M11:117`/`SECURITY.md:873` rewrite states iOS-bg socket
persistence honestly and keeps the anchor heading byte-identical; no ARB value changed; the accuracy pins assert
on the captured `LocationSettings`, not a mock default; `:172` is still a literal; `POWER_MEASUREMENT.md` names only
OS tooling.

**Risks / rollback.** The baseline may reveal a liveness gap (> 228 s at the relay) — a P0 finding, never a reason
to soften the protocol; the template forces the network column so the owner cannot measure on Wi-Fi twice, and the
start state-of-charge column so %/h figures are comparable.
Rollback: one revert (tests + docs); nothing behavioural.

**Acceptance.** CI: all P0 tests green; guards green; `--static-only` green (tests-only diffs never move floors).
Hardware: `POWER_MEASUREMENT.md` carries one filled baseline row per platform per scenario with raw artefacts named
(batterystats checkin, bugreport zip, iOS Battery screenshots, Energy Log trace) and the app commit hash.

**Owner decisions / open questions.** None blocking. V-P0-1 (import in `circle_details_layout_test`); V-P0-2
(`_onResumed` is set-not-gated by the overlap guard — read before editing the comment); U-P0-1 (WN doc 6 h claim);
U-P0-2 (goldfish HAL GPS navigating signal — CI never depends on it).

### 5.1 Phase P1 — Quick wins, no architecture change (D3 part 1, D5, D8, shared hygiene)

**Goal / non-goals.** While backgrounded: on Android the UI isolate holds NO location registration (today's 1 Hz /
1 m request is never cancelled) and, with sharing OFF, no live-sync engine; on iOS an opt-out user's process
suspends with no location client (today it suspends ≈ 30 s later with the plugin stream still running) and NO
stream is ever (re)started from the background (R7 becomes structural, incl. a background LAUNCH); no maintenance
timer is armed on either platform; the PUBLISH relay pool sends no keepalive frames on any platform and closes
between bursts; one location publish keeps the radio awake ≤ 10 s; every engine re-anchor asks the inbox for
≤ 49 h, never 7 days (P4-1, landed here because the sharing-OFF engine stop would otherwise make every glance a
7-day replay); the banner's 72 s re-render stops off-screen; resume extras get a minimum interval;
`LocationAccessNotifier` stops churning a Timer per fix; the pre-existing 30 s-debounce defect is closed.
Non-goals: FGS internals (P2a), the iOS native owner/profiles (P3), the ENGINE pool's background policy (P4),
coalescing (P5), WorkManager registration (unchanged — D3 (i)), any copy change (none), any wire change.

**Design.**
- **Stream lifecycle** = §3.1 (service-level `suspendStream()`/`resumeStream()` gate called from
  `_onPaused`/`_onResumed`; keep rule `bg && isIOS` via `isIOSProvider`; fail-closed `appForegroundProvider`;
  per-build placeholder; `LocationAccessNotifier.suspend()`/`resume()`). Sequence proofs: iOS bg ON pause →
  keep rule true → `suspendStream()` NOT called → the native/plugin session keeps running (identical to today's
  `_onPaused` iOS branch `map_shell.dart:1335-1362`, which stops nothing); iOS bg OFF pause → `suspendStream()`
  cancels the subscription synchronously (plugin `stopUpdatingLocation`; native `onCancel` after P3) and
  `clearCachedPosition()` runs at pause time (cancel fires neither the error nor the done handler,
  `geolocator_location_service.dart:788-796`) → process suspends with no location client; iOS C4 (bg true→false
  while paused) → the watcher calls `suspendStream()` + `clearCachedPosition()` + `disarm()` directly → keep-alive
  withdrawn → process suspends (replaces today's rebuild-into-a-background-start, `location_provider.dart:19-27`,
  which in fact never ran while paused — §2.2a); iOS R1 (false→true while paused) → nothing starts; the keep-alive
  is (re)established at the NEXT FOREGROUND (R7) — the R1 watcher's scheduler/motion/receive re-arm
  (`map_shell.dart:1389-1400`) stays and publishes from last-known for the ~30 s iOS grants a client-less
  background app (today's behaviour, now stated; a background-capable start iOS refuses — CI run 32661622879,
  `M7:1209-1254`); the access watchdog's recovery edge while paused does NOT `invalidate` (suspended) so it
  cannot cancel the kept session; a background LAUNCH builds the provider with `appForegroundProvider == false`
  and gets the placeholder WHEN the engine populates `initialLifecycleState` (`services/binding.dart:295-299` applies
  it only when non-empty — whether iOS does so on a background launch is U, V-P1-1); when it does not, the value
  is `true` and the load-bearing gates are the native start refusal and the `backgrounded` read (D1) — no
  publish-capable session starts until the first foreground either way. Android: `suspendStream()` in both
  toggle states BEFORE the ownership write; `resumeStream()` first thing on resume, ahead of the debounce.
- **Resume reorder** (`_onResumed`, the §3.1 gate table): `resumeStream()` → `locationAccessProvider.notifier.resume()`
  → `refresh()` (`:1584`) → the WHOLE Android reclaim block moved up from `:1658-1685` (`markForegroundActive(true)`,
  `waitUntilIdle()`, `fgsNotificationOpen`, `_lastPublishTime` seed from `readLastPublishTime()`) → P2a's resumed
  signal (P2a adds the call) → `_endMlsSessionHandoff()` → `_healLiveSyncIfStopped()` + heal-timer re-arm
  (`:1641`, unchanged) → an unconditional `_startTimers()` (moved up from `:1690`; idempotent, `:737-743` — no
  split needed) → the 30 s debounce (`:1644-1651`) → the one-shot extras only.
- **Engine stop when sharing OFF (Android):** static `MapShell.shouldStopLiveSyncOnPause({bg, isIOS}) => !isIOS`
  (bg ON already stops it inside the handoff `:899-916`; bg OFF is new); the `_onPaused` else-branch calls the NEW
  `_stopLiveSyncBounded()` (D8 — the `liveSync.stop()` + stillHolding half extracted from `_handOffMlsSession`,
  also adopted by `_onDetached` `:1221-1235`, so C1's "a second `stop()` path that times out orphans the Rule-14
  guard" has ONE bounded implementation) and never `releaseForHandoff()` (no FGS reclaims with sharing OFF; the
  latch would fail every provider open closed until the next resume). `_healLiveSyncIfStopped()` on resume restarts
  it (`:1641`; `ensureRunning` short-circuits on a running engine) — with the P4-1 bound landed first, that restart
  is a ≤ 49 h inbox REQ + per-circle cursor REQs, one reconnect per glance.
- **P4-1 inside P1:** `cursor.rs` `since_for_stream` matches the inbox branch on `phase` (`Initial` 7 d,
  `Resubscribe` `INBOX_RESUBSCRIBE_LOOKBACK_SECS = 2 × 86_400 + 3_600`, D6 (iv) incl. its residual docs); pure Rust,
  no FFI; the foreground re-anchor, CLOSED repairs and the health tick inherit the bound at once.
- **Maintenance arming foreground-gated on both platforms** (D8): `_armKeyPackage`/`_armRelayList`/`_armHealth`
  check the foreground state (the profile sweep's existing `_appIsForegrounded` read, `maintenance_scheduler_provider.dart:476-496`)
  and are re-armed on resume with their normal jittered delays; `_runHealthTick` on resume stays.
- **D5** = §3 D5 verbatim: `publish_relay_options()`, three `pool().add_relay` swaps, `RelayManager::subscribe`
  deleted, `publish_location_event` = `publish_with_retry(1, ZERO, join_all(send_to_one(…, 5 s)))` (worst 10 s,
  clock-rejection contract preserved, no retry), FFI + `RelayService.publishLocationEvent`, both Dart location call
  sites swapped; commits/welcomes/KP/profile keep `publishEvent`; `haven-core/Cargo.toml` dev-dep tokio gains
  `test-util` (the timing tests run under `#[tokio::test(start_paused = true)]` on PURE futures — a paused clock
  plus live loopback I/O auto-advances past the 5 s window before the handshake completes: flaky by construction).
- **Banner:** `SharingHealthBanner._rerender` (`sharing_health_banner.dart:195-207`) armed only while `copy != null`
  AND `sharingHealthForegroundProvider.value` (`sharing_health_provider.dart:201-244`); on foreground return
  `setState` immediately and re-arm, and the resume re-derivation re-renders AND announces (`:301-306`,
  `sharing_health_banner.dart:329-346`); the live-region label drops the rounded age (`:408`) so a persisting
  fault is not re-announced every 72 s, and the age `Text` is lifted out of the `ExcludeSemantics` subtree (`:415`)
  into its own non-live node so it stays readable; a persisting fault gets one explicit announcement (title + age) on
  the resume re-derivation. Platform-neutral. Red-test-first rule of D8 applies.
- **Resume extras throttle:** `MapShell.shouldRunResumeExtras({DateTime? lastAt, required DateTime now}) => lastAt == null || now.difference(lastAt) >= kResumeExtrasMinInterval`
  (10 min) through one `lastResumeExtrasAtProvider`; gates `keyPackagePublisherProvider` invalidate/read
  (`:1701,:1704`), `triggerProfileRefresh` (`:1706-1710`), `_runPrune()` (`:1731`) and `map_page.dart:228-248`
  `tileCacheEvict` on resume. The immediate publish, `memberLocationsProvider` invalidation and the 60 s-guarded
  re-anchor stay unconditional.
- **Per-fix hygiene (C12b):** `LocationAccessNotifier` keeps ONE armed timer and touches `_lastFixAt` per fix; on
  fire, if `now − _lastFixAt < interval` re-arm for the remainder, else probe. Same observable cadence. (C12a map
  rebuild scope and C12c self-marker pulse: `RepaintBoundary` + stop after idle — UI-shared items in the same
  packet; with the Android stream released on pause the background per-fix cost on Android is already zero.)
- Promises: R7 structural; R8 unchanged (`getLocationStream(backgroundSharingEnabled: bg)`);
  `INV-L-ACCESS-GATE-PRECEDES-FIX` untouched (gate is in the service); Rule 10 strengthened (no keep-alive without
  consent; cache cleared on every pause without consent); live-sync default untouched (runtime lifecycle, guard 14b);
  Rule 13 untouched (commits keep the ladder); presence metadata strictly decreases.

**Exact change list.**
- `haven/lib/src/services/geolocator_location_service.dart` → one outer `StreamController<Position>` PER `getLocationStream` call (`onCancel` cancels the inner and clears the current-stream fields; a new call cancels any previous inner; ONE `.getPositionStream(` site kept), `suspendStream()` / `resumeStream()` (synchronous cancel / re-listen of the inner whenever the current outer has a listener — dead inner included; no-ops otherwise); `clearCachedPosition()` unchanged in shape.
- `haven/lib/src/providers/location_provider.dart` → §3.1 body (toggle-driven + the fail-closed background-launch guard with a per-build placeholder); top-level `@visibleForTesting bool shouldKeepLocationStreamWhilePaused({required bool backgroundSharingEnabled, required bool isIOS})`; `appForegroundProvider` (`StateProvider<bool>`, initial value from `WidgetsBinding.instance.lifecycleState`, never a literal) and `isIOSProvider` live here (one file owns the stream's lifecycle inputs); `:13-41` doc rewritten to the truth table (keep the R8 sentence) + the deliberate `ref.read` note.
- `haven/lib/src/pages/map_shell.dart` → `_setForegroundActive` (`:1241`) also writes `ref.read(appForegroundProvider.notifier).state = active` guarded by `mounted` AND `ref` liveness (`detached`, `:1187-1189`); statics `shouldKeepLocationStreamWhilePaused` (delegates to the provider file's function or vice-versa — ONE definition), `shouldStopLiveSyncOnPause`, `shouldRunResumeExtras`; `_onPaused`: `suspendStream()` (+ `clearCachedPosition()` on `!bg`) first, else-branch `_stopLiveSyncBounded()`; the C4 watcher (`:1402-1414`) calls `suspendStream()` + `clearCachedPosition()` directly; `_onResumed` per the §3.1 gate table (reclaim block + `_startTimers()` ahead of the debounce; no `_startTimers` split); NEW `_stopLiveSyncBounded()` extracted from `_handOffMlsSession` (`:899-916`) and used by `_onDetached`; `_lastResumeExtrasAt` via `lastResumeExtrasAtProvider`.
- `haven/lib/src/pages/map/map_page.dart:228-248` → `tileCacheEvict` on resume behind `shouldRunResumeExtras`.
- `haven/lib/src/providers/location_access_provider.dart` → `_suspended` (`suspend()` / explicit `resume()`; `_apply` skips `ref.invalidate(locationStreamProvider)` `:523` while suspended; `refresh()` never clears it); timestamp-touch watchdog.
- `haven/lib/src/providers/maintenance_scheduler_provider.dart` → foreground gate on `_armKeyPackage`/`_armRelayList`/`_armHealth` (both platforms), re-arm on resume.
- `haven/lib/src/widgets/map/sharing_health_banner.dart` → gated `_rerender`; announce on the resume re-derivation; age removed from the live-region label (`:408`).
- `haven/lib/src/constants/location.dart` → `kResumeExtrasMinInterval`.
- `haven/lib/src/providers/background_location_provider.dart:498-506` → comment recording the WorkManager registration decision + why (D3 (i)).
- `haven-core/src/relay/cursor.rs` → `INBOX_RESUBSCRIBE_LOOKBACK_SECS`; `since_for_stream` inbox branch matches on `phase`; module doc "Inbox (`kind:1059`)" rewritten (7 d initial / 2 d + 1 h resubscribe + the two residuals); doctest updated; `anchor.rs:355-359`, `config.rs:249-252`, `session.rs:1656-1660`, `storage.rs:3065-3066` (dedup retention tied to the `Initial` 7 d) comments corrected in the same commit.
- `haven-core/src/relay/manager.rs` → `PUBLISH_POOL_IDLE_TIMEOUT`, `LOCATION_ACK_WINDOW`, `LOCATION_PUBLISH_ATTEMPTS`, `publish_relay_options()`; `:307`, `:617`, `:1253` → `client.pool().add_relay(url.as_str(), publish_relay_options())` (log line unchanged); `async fn send_to_one` factored out of `try_publish_once_harvesting` (`:555-575`) and reused; `pub async fn publish_location_event` (= `publish_with_retry(LOCATION_PUBLISH_ATTEMPTS, Duration::ZERO, …)`, counts-only logging); `MAX_PUBLISH_ATTEMPTS` doc (`:88-101`) + one sentence; `pub async fn subscribe` (`:660-700`) DELETED. `haven-core/Cargo.toml:240` → tokio dev-dep features + `"test-util"`.
- `haven/rust_builder/src/api.rs` → `RelayManagerFfi::publish_location_event(event_json, relays) -> Result<PublishResultFfi, String>` (the `RelayError` → `String` mapping keeps the `DeviceClockRejected` discriminator `nostr_relay_service.dart:552-566` matches on); `./scripts/regenerate_frb.sh`; `cargo fmt`; `dart format` on generated files only.
- `haven/lib/src/services/relay_service.dart` → abstract `Future<PublishResult> publishLocationEvent({required String eventJson, required List<String> relays})`; `nostr_relay_service.dart` implements (same exception mapping as `publishEvent`); every mock `RelayService` in `haven/test/**` + `haven/integration_test/**` gains it (37 files — the analyzer forces it; budget the packet).
- `haven/lib/src/services/location_sharing_service.dart:340-360` → `publishLocation` calls `publishLocationEvent` (the `on RelayClockRejectionException` branch `:367-374` unchanged); `background_location_task.dart:1326` → `_relayService!.publishLocationEvent(...)` (`_resolveDeferredCommits` / `_publishDeferredProposals` keep `publishEvent`).
- Guards: `scripts/ci/check_engine_client_options.sh` RESTRUCTURED into function-shaped checks returning rc (`check_publish_pool_options <manager.rs>`, `check_engine_pool_options <session.rs>`, `check_ffi_add_relay <api.rs>`; `exit 2` for missing paths; every check runs so one red run reports all violations — today's `set -euo pipefail` + `fail`=`exit 1` aborts at the first) + a `--self-test` (none today), `SELF_TEST_FIXTURES=10` pinned by equality: (3) `manager.rs` defines `fn publish_relay_options` whose body contains `.ping(false)`, `.reconnect(false)`, `.sleep_when_idle(true)`; (4) every `\.add_relay\(` line in `manager.rs` also matches `pool\(\)\.add_relay\(`; (5) `session.rs` contains neither the CALL `\.ping[[:space:]]*\([[:space:]]*false` nor `\.sleep_when_idle[[:space:]]*\(` (whitespace-tolerant like check 1 — the bare word appears in two kept comments, `:1536`, `:1933`, so a substring pin is red on the clean tree); (6) `api.rs` contains no `.add_relay(` except the e2e helper at `:11875` (allowlisted by `// e2e helper`); (7) `manager.rs` contains no `subscribe_to(` / `subscribe_with_id_to(`. Fixtures: clean tree (pass); a comment containing bare `sleep_when_idle` (PASS); `verify_subscriptions(true)`; pin line deleted; `ping(true)` in `publish_relay_options`; `publish_relay_options` missing; bare `client.add_relay(` in manager.rs; `.ping(false)` call in session.rs; `.sleep_when_idle(true)` call in a code line of session.rs; `subscribe_to(` in manager.rs. `.github/workflows/repo-guards.yml` → the enforcing step (`:755-757`) gains a `--self-test` step (rule 6b). (The verification draft's separate `check_relay_pool_options.sh` is subsumed — one guard owns both pools' options.) `scripts/ci/check_ios_background_publish.sh` check 5 (`:229-236`, a whole-file token check) → factored into function-shaped `check_stream_provider <provider.dart>`: slice the `locationStreamProvider` body; require `ref.watch(backgroundSharingProvider)`, `getLocationStream(backgroundSharingEnabled:`, `ref.read(appForegroundProvider)` and `clearCachedPosition()` in the foreground body (today's check-5 Rule-10 pin, `:236-237`, kept); require that the `if (!ref.read(appForegroundProvider))` block contains no `getLocationStream(` and no `ref.watch(appForegroundProvider)` OUTSIDE it (the running foreground build must never watch it); fixtures (5): passes; foreground build watches the foreground provider (fail); a start inside the paused block (fail); the `!bg` clear deleted (fail); body commented out (fail) → `SELF_TEST_FIXTURES` 19 → 24. NEW `scripts/ci/check_android_location_power.sh` created here with checks (7) and (8) of P2a's list — (7) in `map_shell.dart` `_onPaused` the token `suspendStream(` precedes `markForegroundActive(active: false)`; (8) that `suspendStream(` call sits inside a `shouldKeepLocationStreamWhilePaused(` conditional, never a raw `Platform.isIOS`/`isIOS` branch — + `--self-test` (2 pairs; P2a extends it to checks 1–6); wired in `repo-guards.yml` after "Location access gate …" (`:709-721`).
- `docs/privacy/privacy_invariants.json` → NEW `INV-R-PUBLISH-POOL-NO-KEEPALIVE` (enforced): "the publish pool (`RelayManager`, every isolate) is built with `RelayOptions::default().ping(false).reconnect(false).sleep_when_idle(true).idle_timeout(..)` so no keepalive frame leaves the device between publish bursts; every fetch primitive leaves no subscription registered, so the socket can sleep; the engine pool keeps the pool's ping while it holds a standing REQ (turning it off re-creates the C3 blackout)"; no `disclosure_arb_keys` (the Privacy page was removed 2026-08-29); `symbols`: `haven-core/src/relay/manager.rs::publish_relay_options`, `haven-core/src/relay/live_sync/session.rs::build_engine_client` (`:92`) — rule 2 matches the LAST token as a whole word in comment-stripped code, so `RelayManager::new` would look for a literal `new` and be vacuous; `tests`: `publish_relay_options_turn_ping_off`, `engine_pool_keeps_ping_while_subscribed`, `every_fetch_primitive_leaves_no_subscription_registered`; `guards: [scripts/ci/check_engine_client_options.sh]`. No ratchet item.
- Docs: `SECURITY.md` "Persistent receive connection" bullet + `docs/M11_ROLLOUT.md:121` gain "The PUBLISH pool sends no keepalives and closes within ~a minute of the last publish (P1)"; `M7` §D Android (UI stream released on pause; engine stopped with sharing OFF) + a history paragraph (P1 lifecycle rule + the R1 statement); `FA` §C (the debounce defect as a new lesser cause, with its EXACT consequence: with sharing ON the stamp stays 0, the FGS reclaim correctly declines against the alive UI, NOBODY publishes and the notification keeps saying "sending and receiving" — not "the FGS takes over after 144 s"); `FA:697-703` + R14 (every re-anchor now asks ≤ 49 h); `location_access_provider_test.dart:417-440` `reason` text stays true (the FOREGROUND stream keeps 1 m). No FA "Unit H" stub — the entry is written in full when P1 lands.
- ARB: none.

**Tests FIRST.**
- `haven/test/services/geolocator_location_service_test.dart` → `suspendStream cancels the plugin subscription synchronously and keeps the cached fix` (`FakeGeolocatorWrapper` listen/cancel counters; `verify(cancel)` immediately after the call, NO pump, NO microtask; `getCurrentLocation` still served from cache with the mocked gate); `resumeStream re-subscribes with the current settings exactly once`; `suspend/resume are no-ops when the outer has no listener`; `the outer stream survives a suspend/resume pair without completing or erroring` (a listener sees only data); `a toggle rebuild re-listens without error and cancels the previous inner` (two `getLocationStream` calls with a cancel between — no `StateError`, inner cancel count 1); `a recovery observed while suspended yields a fresh inner subscription on resume` (inner errors while suspended; `resumeStream()` re-listens; capture count 2).
- `haven/test/providers/location_provider_test.dart` → `the provider built while not foregrounded starts nothing and its placeholder never completes or errors` (override `appForegroundProvider` false; `getPositionStream` never called; listener sees only `AsyncLoading`); `two consecutive not-foregrounded builds never surface an error or completion` (flush twice — pins the per-build placeholder); `the resume write rebuilds a placeholder build into a running stream`; `the foreground build does not watch the foreground provider` (write false on a running build → NO rebuild, NO cancel through the provider — the keep rule lives in the service gate); `the default of appForegroundProvider is false under a paused binding` (`TestWidgetsFlutterBinding` lifecycle `paused` before the first read → no `getPositionStream`); `:157` "rebuilds the stream with new settings when the toggle flips" unchanged (foreground). Lifecycle cases use `container.listen` + `FakeAsync` and assert on captured call/cancel counts — never `await …future` on a state that can be paused (the placeholder never completes; the test would hang to the framework timeout). `a foreground opt-out clears the cache at the rebuild` (`:182` stays green — the `!bg` clear lives in the foreground body). Tests that build the REAL provider (incl. `:157`) call `TestWidgetsFlutterBinding.ensureInitialized()` first: the initializer reads `WidgetsBinding.instance` and a plain `test()` would throw "Binding has not yet been initialized"; the `null → true` mapping covers a not-yet-dispatched state, not an absent binding. Lint test: `appForegroundProvider`'s initializer references `lifecycleState`, not a literal.
- `haven/test/pages/map_shell_test.dart` → groups `shouldKeepLocationStreamWhilePaused` (4 cells, `isIOS` parameter), `shouldStopLiveSyncOnPause: Android in both toggle states, never iOS`, `shouldRunResumeExtras throttles to kResumeExtrasMinInterval and runs first time`; truth tables gain an ENGINE leg (additive rows only).
- `haven/test/pages/map_shell_location_access_lifecycle_test.dart` (source-order family, `:223-249`) → `suspendStream precedes markForegroundActive(false) in _onPaused`; `suspendStream is guarded by the keep rule, not by a platform branch`; `resumeStream, resume(), refresh(), the reclaim block and _startTimers() all precede the resume debounce` (anchors `resumeStream(`, `readLastPublishTime(`, `_startTimers(` before `_resumeStopwatch.isRunning`); `the bg-OFF Android pause branch calls _stopLiveSyncBounded and never releaseForHandoff`; `_onDetached uses _stopLiveSyncBounded`; behaviour test with the recorded call log (pattern `background_location_provider_test.dart:1338-1385` `stateAtArmTime`) for pause→resume→pause→resume inside 30 s: every timer field non-null, `_lastPublishTime == bgLastPublish`, and the ownership stamp re-written before the debounce; `a paused Android app holds no plugin subscription — asserted without pumping a frame or reading the provider` (the B-1 test: the harness must not call `container.read(locationStreamProvider)` or `pump` between the pause and the assertion); `the bg-OFF Android pause stops the engine without latching a handoff` (`endSessionHandoff()` returns false on resume).
- `haven/test/providers/location_access_provider_test.dart` → `AsyncLoading after suspend() arms nothing`; `a stream error after suspend() runs one refresh and arms nothing`; `a recovery edge while suspended does not invalidate the stream` (fake service `getPositionStream` call-count AND cancel-count unchanged); `resume() then refresh() re-arms exactly one timer`; `per-fix delivery touches the timestamp without re-creating the timer` (FakeAsync `pendingTimers.length` stays 1 across N fixes). `:384-448` "silence is not an alarm" stays as is.
- `haven/test/providers/maintenance_scheduler_provider_test.dart` → `no maintenance timer is armed while backgrounded (both platforms)`; `timers re-arm on resume with their jittered delays`; existing "fires each task exactly once after its initial delay" stays.
- `haven/test/widgets/map/sharing_health_banner_test.dart` → FIRST the red test `the age re-render timer fires while backgrounded` (feasible: widget-test `pump` fires periodic timers regardless of lifecycle and the injected `clock` makes the "old text" assertion meaningful; if it cannot fail, drop the item); then `the age re-render stops while backgrounded and re-renders on return` (override `sharingHealthForegroundProvider` with `ValueNotifier(false)`; advance past a boundary; old text; flip true; new text without a tick); `no re-render timer while healthy`; `the age is exposed as a non-live semantics node and is stable across ticks` (the live node's label carries no age; the age node exists outside the excluded subtree); `resume with a persisting fault announces once` (one `announce` call with title + age); `resume with a cleared fault uses the existing resumed announcement`. `:230-249` stays.
- Rust (`cursor.rs` unit tests): `inbox_subtracts_7_days_regardless_of_phase` (`:419`) goes RED and is REPLACED by `inbox_initial_subtracts_seven_days` + `inbox_resubscribe_subtracts_two_days_plus_one_hour` (both phases pinned by exact value) + `inbox_resubscribe_lookback_covers_nip59_backdating_plus_skew` (`INBOX_RESUBSCRIBE_LOOKBACK_SECS >= 2 * 86_400 + 3_600`); `:421-428`, `:483`, `:500` phase-independence assertions and the `since_for_stream` doctest (`:250-258`) updated alike. `haven-core/tests/inbox_cursor_poisoning_e2e.rs` → keep all three gates; ADD `a_resubscribe_asks_for_two_days_plus_an_hour_never_seven` (inspect the REQ filter at the relay via a recording `QueryPolicy`), `a_wrap_backdated_forty_eight_hours_published_after_the_last_open_is_still_delivered`, `a_wrap_only_the_slow_inbox_relay_holds_is_fetched_within_the_lookback`; `a_future_dated_gift_wrap_never_pushes_the_inbox_cursor_past_the_local_clock` stays green unchanged; `cursor_poisoning_e2e.rs` kept (the bound applies to the INBOX plane only — test).
- Rust (`manager.rs` `#[cfg(test)]`, flags-only and hermetic — no relay needed: `client.pool().add_relay("wss://relay.example", …)` then `client.relay(url).flags().has_ping()`): `publish_relay_options_turn_ping_off` (read/write true, ping false); `a_second_add_of_the_same_url_never_restores_ping` + NEGATIVE control (`client.add_relay(url)` flips `has_ping()` to true — documents the trap; fails if a crate upgrade changes the semantics, which is what we want to know); `engine_pool_keeps_ping_while_subscribed` (`build_engine_client` relay `has_ping() == true`); `publish_location_event_logs_counts_only` (captured logger: no URL in any line emitted by the new fn). `haven-core/tests/publish_pool_idle_e2e.rs` (in-process relay = `nostr-relay-builder`): `the_publish_socket_sleeps_after_a_burst_and_wakes_for_the_next` — subscribe to `relay.notifications()` BEFORE the publish and await `RelayNotification::RelayStatus { status: Sleeping }` under the scaled `wait_budget` pattern of `inbox_cursor_poisoning_e2e.rs:97-110` (never a fixed sleep, never a status poll); a ≈ 60–70 s WALL-CLOCK test by construction (`SLEEP_INTERVAL` is a 60 s crate constant polled inside `post_connection`, unreachable under a paused clock against a real socket) — bounded, event-driven, kept, never `#[ignore]`; then publish again → acked, `Connected`; `a_dropped_publish_socket_does_not_reconnect_on_its_own` (`LocalRelay::shutdown()` → await `Terminated` on the notifications; record `stats().attempts()`; ONE `publish_location_event` → `Err`, attempts grew by EXACTLY 1; restart the relay on the same port (`RelayBuilder::port`) → publish acked, `Connected`); `publish_location_event_folds_a_stalled_relay_after_its_own_window` (two relays, one `NeverAnswer` → `accepted_by == [fast]`, `failed == [stalled]`, elapsed < 10 s as a BOUND, not a race); `publish_location_event_never_retries` (`RejectEverything` relay asked exactly once); `publish_location_event_reports_a_clock_rejection_without_retrying` (`WritePolicy` returning `invalid: created_at is in the future` → `Err(DeviceClockRejected)`, asked once); `every_fetch_primitive_leaves_no_subscription_registered` (`client.subscriptions()` empty after each `RelayManager` fetch incl. the `read_one_relays_answer` timeout and CLOSED paths, asserted only after `RelayNotification::SubscriptionAutoClosed { id }` on a notifications stream subscribed before the fetch — the auto-close removal and the outer timeout coincide, so an immediate read races). PURE timing tests under `#[tokio::test(start_paused = true)]` on `futures::future::{ready, pending}` (no sockets): `the_per_relay_window_returns_at_the_bound_when_nothing_answers` (5 s), `location_ladder_worst_case_equals_one_publish_attempt` (5 + 5; mirrors `profile_publish_ladder_is_strictly_shorter_than_the_location_ladder`, `manager.rs:2192-2224`). `haven-core/tests/security_rule_gates.rs` → `rule13_commits_keep_the_retry_ladder_and_locations_do_not` (source-level, correct predicates: (a) `impl AutoCommitPublisher for RelayManager` in `haven-core/src/relay/auto_commit.rs` calls `publish_event` (`:99`); (b) `impl … for nostr_sdk::Client` (`:117-118`, `send_event_to`) confirms only on `!output.success.is_empty()`; (c) no `PendingStateRef` flows into any `publish_location_event` caller in Rust, `api.rs` or Dart `_handleDeferredSend`).
- Dart: `location_sharing_service_test.dart` → `publishLocation uses the location ladder, not the commit ladder` + `a clock rejection from the location ladder still reaches the detector` (typed `RelayClockRejectionException`); `background_publish_stagger_teardown_test.dart` (or the FGS unit file) → same for `_publishCircle`.
- Guard mutations: `check_engine_client_options.sh --self-test` 10/10; `check_ios_background_publish.sh --self-test` 24/24; `check_android_location_power.sh --self-test` (7) `suspendStream(` after the ownership write → fail; (8) a raw platform branch around `suspendStream(` → fail.
- Lanes: `e2e-network-reconnect` (b9): add at the end of recovery a location publish through `RelayManagerFfi.publishLocationEvent` acked after the outage (proves the publish pool wakes from `Terminated`/`Sleeping`) with the marker `[b9] PUBLISH_AFTER_IDLE_OK` ASSERTED in `run-b9-network-reconnect.sh` from the first landing (the lane already proves recovery on the same socket lifecycle; a red run is a finding, never a reason to defer the assertion); update its doc (`:20-45`) to state the two pools now differ. B1 (P1 half of the §5.2 sampler): device-time-stamped `dumpsys location` samples at ≤ 5 s started before the drive; ANTI-VACUITY: ≥ 1 pre-`HANDOFF_CONFIRMED` sample shows Haven's 1 s request; ASSERT: no sample after `HANDOFF_CONFIRMED` shows the UI request — identified by its `@+1s0ms` interval WITH the `minUpdateDistance=1.0` suffix (§2.2 grammar); the FGS one-shot's transient ≤ 30 s registration (`_currentPositionSettings`, distance 0, no suffix) is thereby excluded and the oracle is deterministic before P2a ("no request at all" belongs to P2a's `registration armed` marker). B5/B6 unaffected (foreground). `map_shell_ios_receive_timer_test.dart`, `map_shell_receive_recovery_test.dart` (iOS branch untouched) expect green; `location_stream_error_handling_test.dart:452-501` anti-vacuity (≥ 2 listeners) — keep ≥ 2, add the lifecycle wrapper as a listener that handles non-data states.
- Existing red → replacement: `map_shell_test.dart` truth tables (additive rows); `cursor.rs::inbox_subtracts_7_days_regardless_of_phase` → the three exact-value tests above; `background_publish_stagger_teardown_test.dart:45-93` unaffected unless `shutdown()` moves; mocks implementing `RelayService` (compile error, add the method); `manager.rs` `publish_with_retry_*` ×11 unchanged; `check_teardown_drain_budget.sh` unchanged and still true (run it).

**Implementer work packets.**
| # | Packet | Sequencing | Done when |
|---|---|---|---|
| P1-A1 | `GeolocatorLocationService` gate (`suspendStream`/`resumeStream`, outer controller) + service tests; `location_provider.dart` (§3.1) + `appForegroundProvider` (fail-closed) + `isIOSProvider` + statics + provider/map_shell static tests; `check_stream_provider` (24) | first (touches the seam both halves share) | service + provider + static tests green; `check_ios_background_publish.sh` + `--self-test` (24) green |
| P1-A2 | `_onPaused`/`_onResumed` per the §3.1 gate table incl. the debounce fix and the C4 watcher, `_stopLiveSyncBounded()` (bg-OFF + `_onDetached`), `LocationAccessNotifier` suspend/`resume()` + timestamp watchdog, maintenance arming gate, source-order + no-frame + call-log tests, `check_android_location_power.sh` (7)(8) + self-test | after A1 | `flutter test test/pages test/providers`; `check_ios_background_publish.sh`, `check_location_access_gate.sh`, `check_live_sync_restart_budget.sh`, `check_mls_session_single_owner.sh`; `flutter analyze` |
| P1-A3 | Banner gating (red test first) + announce/live-region + resume-extras throttle + tile-evict gate + C12a/C12c hygiene + tests | ∥ A2 | `flutter test test/widgets/map/sharing_health_banner_test.dart test/pages` |
| P1-N0 | Rust `cursor.rs` bounded `Resubscribe` inbox lookback (P4-1) + unit tests + the three poisoning e2e additions + the four comment corrections | first of the Rust packets | `cargo test`, clippy, fmt; `check_no_event_timestamp_cursor_advance.sh` green |
| P1-N1 | Rust: `publish_relay_options` + three swaps + `RelayManager::subscribe` deletion + flags/idle/fetch tests + `test-util` dev-dep | ∥ A1–A3, after N0 | `cargo test`, clippy, fmt; guard checks 3–5, 7 pass on the tree |
| P1-N2 | Rust+FFI: `send_to_one` factoring + `publish_location_event` + pure timing tests + relay-backed shape tests + FFI + `regenerate_frb.sh` | after N1 | Rust tests green; `flutter analyze` clean |
| P1-N3 | Guard restructure (function-shaped) + checks 3–7 + `--self-test` + `repo-guards.yml` self-test step | ∥ N1 | `--self-test` 10/10 |
| P1-N4 | Dart `RelayService.publishLocationEvent`, two call-site swaps, 37 mocks, Dart tests, b9 assertion | after N2 | `flutter test`, `flutter analyze`, `--static-only`, `check_privacy_invariants.sh` |
| P1-D | Docs + manifest invariant + B1 sampler (P1 half) + full `check_coverage.sh` before push | last | anchors intact (rule 15); floors: `lib/src/providers/|84` (measured 86.13 %), `lib/src/services/|65` (67.08 %), `rust|src/relay/manager.rs|78` (80.14 %, gains two functions + tests) absorb new lines — expect RATCHET not HOLD; `cursor.rs` gets a `--list`-derived row; re-pin from the P1 CI run only |

**Reviewer checklist.** Make the release depend on a `ref.watch`/`ref.invalidate` alone ("a simplification") — the no-frame test must go red (§2.2a). Try to make the running build `ref.watch(appForegroundProvider)` — the kept iOS session would be torn down at the resume rebuild and never restarted (R7); `check_stream_provider` must fail. Try `Stream.empty()` or a shared placeholder — the completion-surfacing test and the two-builds test must go red. Set `appForegroundProvider`'s default to a literal `true` — the paused-binding test and the lint must go red. Confirm `clearCachedPosition()` never runs on the iOS+bg or Android+bg pause path. Confirm no listener treats `AsyncLoading` as an outage (`map_page.dart:305-310` keeps loading; motion trigger stopped; access notifier suspended) and that `refresh()` from a stream error while suspended arms nothing. Make the iOS branch call `suspendStream()` (must be impossible by the keep rule + guard (8)). Pause/resume within 30 s and show any timer dead or the ownership stamp still 0 (must be re-armed / re-written). Pause with sharing OFF on Android and find an open engine socket, or a latched `releaseForHandoff()`. Find a maintenance timer armed while backgrounded on Android. Find a Timer created per fix. Find a resume within 10 min that re-runs the 30443/10050/10002 probes; confirm the immediate resume publish still runs unconditionally. D5: add `client.add_relay(` anywhere on the publish client — the guard must fail; run the negative control; confirm `reconnect(false)` cannot strand a COMMIT (`publish_event` re-drives `add_relays_and_connect` on every attempt, `:389-403`, which calls `try_connect_relay` from `Terminated`); Rule 13: `publish_location_event` unreachable from any path carrying a `PendingStateRef`, and the rule-13 gate's three predicates (auto_commit.rs `RelayManager` impl → `publish_event`; `Client` impl → `send_event_to` + `!success.is_empty()`); B8: a clock-rejected location publish still raises `RelayClockRejectionException`; C3: no `.ping(false)`/`.sleep_when_idle(` CALL leaked into `session.rs` (the comment fixture must PASS); the new fn logs no URL (captured-logger test — `check_no_key_logging.sh` does not check URLs). C1: both engine-stop paths use `_stopLiveSyncBounded()` (`mls_session_handle_release_test`, `map_shell_detached_release_test`, b1 `HANDOFF_CONFIRMED`). C6: banner/maintenance gating must not touch `_liveSyncHealTimer` re-arm (`map_shell_receive_recovery_test`). P4-1: plant a 7-day `Resubscribe` REQ — the relay-side test must go red; the three poisoning gates still green. Test reliability: the idle e2e waits on a broadcast state transition with a scaled budget (≈ 70 s wall clock, stated); every timing test is pure under `start_paused`; no relay-backed test asserts an elapsed window; no `Future.delayed` in new Dart tests; no lifecycle test awaits `.future` on a pausable state.

**Risks / rollback.** A `StateProvider` write inside a lifecycle callback during widget tear-down (`detached`) — guarded by `mounted` + `ref` liveness (change list). V-P1-1 (does the iOS engine populate `initialLifecycleState` on a background launch, and does Flutter deliver the initial `paused` to MapShell?) is U and NOT load-bearing: when the state is populated the default is `false`; when it is empty `lifecycleState == null` maps to `true` (fail-open) and the native start refusal + the `backgrounded` read (D1) are the gates that hold; no write during build is needed either way. Cold-start race the retry ladder was added for (`manager.rs:88-101`): with `try_connect_relay` awaiting `Connected` the send lands on a live socket; if field data shows first-publish drops, add ONE re-send at +5 s inside the same 10 s window — never cross-wake retries. A relay cannot sleep mid-`send_event` (activity updated on send; sleep needs ≥ 10 s idle). Rollback: one commit — `RelayOptions` back to default + `RelayManager::subscribe` restored + both Dart call sites back to `publishEvent` + guard checks/fixtures AND the `repo-guards.yml` self-test step reverted (the guard would otherwise fail, by design) + the manifest invariant deleted (`ratchet_override.items: ["INV-R-PUBLISH-POOL-NO-KEEPALIVE.deleted"]`) + `cursor.rs` bound reverted with its tests, provider back to the toggle-only body, service gate calls removed, lifecycle/banner/extras/maintenance gates removed; no persisted state.

**Acceptance.** CI: all tests above green; guards 10/10, 24/24 and the new Android guard green; `check_teardown_drain_budget.sh`, `check_privacy_invariants.sh`, `check_no_event_timestamp_cursor_advance.sh`, `check_coverage.sh` green; `e2e-ios-background-publish` P1/P2a/P2b/P3 unchanged and green (its enable happens foregrounded; check 12 `:381-400` unaffected); b7 both tiers green; B1 shows the UI request (`@+1s0ms` + `minUpdateDistance=1.0`) before `HANDOFF_CONFIRMED` and never after it. Hardware (owner): `dumpsys location` on a backgrounded Android shows no 1 s Haven request (before P2a, GNSS blame already drops to the FGS one-shot's TTFF per tick); with sharing OFF `dumpsys activity services` shows no Haven sockets after Doze; an opt-out iOS user's process loses its RunningBoard "Location subscription" assertion at pause (M7 §6 toggle-OFF expectation `:836-838`; the lane's P3 phase proves the toggle-off-while-paused case — the pause-with-toggle-off case is hardware-only, or b7's WIU run adds "toggle off, pause, `status()` shows no session"); Battery Historian `mobile_radio` / Xcode Energy gauge over 60 min: no 55 s bars attributable to the publish pool (residual on iOS-bg until P4: the engine's own 55 s bars).

**Owner decisions / open questions.** None owner-level. V-P1-1 (U — `initialLifecycleState` population on an iOS background launch; not load-bearing: the native refusal + `backgrounded` read are the gates); V-P1-2 → V (`ClientOptions::default().autoconnect` does not auto-spawn a connect on `pool().add_relay` — pool-level add never autoconnects, `pool/mod.rs:257-262`; sdk autoconnect only inside `Client::add_relay`, `client/mod.rs:305-308`; `RelayOptions::default()` equals what `compose_relay_opts` yields for the publish client's default `ClientOptions`, `client/mod.rs:232-283`, so nothing is lost by bypassing `Client::add_relay`); V-P1-3 (cancelling the geolocator subscription while paused does not trip `StreamHandlerImpl.setActivity(null)`'s `stopListening()` path, `StreamHandlerImpl.java:46-53` — observe "Geolocator position updates stopped" exactly once in logcat; note the FGS engine's cancel runs `disposeListeners(true)` → `canStopLocationService(true)` on the SHARED bound service with an under-counting `listenerCount`, `GeolocatorLocationService.java:86-90,127-131` — harmless today, no `foregroundNotificationConfig`); V-P1-4 (`sharing_health_banner.dart:200` timer actually fires while backgrounded — the red test decides); V-P1-5 → V (`RelayManager::subscribe` has no caller — grep 2026-08-29); I-P1-1 (real-network `Sleeping` timing 60–70 s — hardware, not a correctness input).

### 5.2 Phase P2a — Android FGS: delivery-driven cadence, one-shot demoted, scoped publish lock (D3 part 2 + D4 P2a); Phase P2b — permanent-lock removal (gated)

**Goal / non-goals (P2a).** Backgrounded with sharing ON (after P1 released the UI stream): GNSS is duty-cycled by
the platform itself — the FGS isolate owns ONE `LocationManager` registration whose interval is the time to the
next CSPRNG due minus a 10 s lead (floored at 31 s), so the receiver runs ≈ hot-TTFF per publish instead of 100 %
(research §1.5/§1.7: ≈ 5 mA average vs 60–85 mA); the per-tick 30 s HIGH_ACCURACY one-shot no longer runs in
steady state; the scoped `Haven:publish` lock (fix→encrypt→publish→ack→fetch, ≤ 30 s past the last acquire) is in
place so P2b is a pure removal; the FGS shuts its publish pool at the end of every cycle (the presence copy's
Android truth, D6 (vi)). The plugin's permanent `PARTIAL_WAKE_LOCK` STAYS in P2a (D4): it is the wake source of
the indoor/no-fix fallback and of the `Armed`-without-delivery recovery, so the AP does not suspend between
publishes yet — the P2a saving is the GNSS receiver, not the AP. Nothing on the wire changes. Non-goals: the
foreground stream (1 m / 1 s), iOS (P3), relay pools beyond the per-cycle shutdown (D5/D6), motion awareness in
the FGS (none today, none after), Play-Services-free flavour, batching, the native registration (P2b).
**P2b** (after P2a's hardware row, OD-P2-2, OD-P2-3): `allowWakeLock: !isIgnoringBatteryOptimizations` (the plugin lock stays for the non-exempt cohort — no ordinary alarm fires in Doze without the exemption) + the native `PendingIntent`/
`LocationListener` registration acquiring `Haven:publish` inside the system's delivery hold + a wake source for the
no-fix watchdog (the inexact exempt alarm by default) + `INV-L-ANDROID-NO-PERMANENT-WAKE-LOCK`; merge gates =
the emulator no-fix oracle (Doze policy) AND the forced-idle hardware liveness row (AP suspension is provable only
on hardware). P2b is specified by D4 and the rows below marked (P2b); its packets are cut when P2a's numbers are in.

**Design.**
- **Isolate state:** `Idle` (foreground owns; no registration), `Armed{target}` (registration live), `Cycling`
  (+ `_deliveryPending`). Inputs: **watchdog tick** (plugin repeat, 72 s — punctual in P2a because the plugin lock
  stays), **delivery** (stream event), **signal** (`foreground-paused` / `foreground-resumed` from the UI isolate over
  `FlutterForegroundTask.sendDataToTask` → `ForegroundService.sendData` → `task.invokeMethod("onReceiveData")` →
  `TaskHandler.onReceiveData` — `flutter_foreground_task.dart:275`, `ForegroundService.kt:74`, `ForegroundTask.kt:140-144`,
  routed at `background_location_task.dart:592-600`). EVERY input only ever invokes `_publishCycle`; a watchdog tick
  during `Cycling` is a no-op; a delivery during `Cycling` sets `_deliveryPending` (D3 (iv)).
- **The cycle (`_publishCycle`, on any input):** on a delivery `if f.timestamp == lastConsumedFixTs → return`
  (historical re-delivery dedupe); `await wakeLock.acquire(kPublishWakeLockTimeout)` (awaited — a real order);
  gates unchanged (identity, foreground `:1092-1111`, session, disclosure); eligible circles, prune, `seedStaggered`
  (unchanged); `dueKeys = dueKeysUpTo(keys, now + kBackgroundFixHorizon)`; PRE-SAMPLE `J_c` per due circle (CSPRNG,
  existing sampler `:1610-1620`); plan slots (existing stagger rule `:1265-1271`) → `earliestDue = min(slot_c + J_c ∪ dueAt(non-due))`;
  `_ensureRegistration(target = earliestDue − kBackgroundFixLeadTime)` — ONE cancel+listen BEFORE any publish, and
  the ONLY call site, reached EVEN WHEN `dueKeys` is empty (from `Idle` with everything due 62–158 s out the
  registration must still be armed; otherwise the watchdog would publish through the cache-miss one-shot forever);
  if `dueKeys` is empty → release, return; `position = getCurrentLocation()` (cache hit on the delivered fix — the
  tee `:806-809` is what the delivery filled; gate + app-op corroboration unchanged `:686-704`); per due circle
  (stagger, foreground re-check, encrypt, publish via `publishLocationEvent`, `notePublishAcked` — unchanged
  `:1256-1373`; the lock re-acquired after each stagger sleep) → `markPublished(key, publishStart, J_c)` with the
  PRE-SAMPLED value; on failure leave due (unchanged) and shorten the registration to `kBackgroundRepeatInterval − lead`
  (retry parity); fetch step if due (lock re-acquired; unchanged `:1401-1444`); `await _relayService?.shutdown()`
  (the per-cycle pool close — reconnects via `try_connect_relay` next cycle, +0.5 J); `writeLastPublishTime`; prune;
  `finally`: release lock, then if `_deliveryPending` and something is due within the horizon → one follow-up cycle.
- **`_ensureRegistration(target)`:** if a registration exists and `|registeredTarget − target| ≤ kRegistrationSlack`
  (5 s) keep it (loop breaker: a re-registration re-delivers the historical fix, dropped by the timestamp dedupe; an
  aligned target is never re-registered); else cancel the subscription (if any) and
  `getLocationStream(profile: backgroundService(interval: nextFixRequestInterval(...)))` — never below
  `kMinFixRequestInterval` (31 s) — on the isolate's own `GeolocatorLocationService` (`_locationService`, built at
  `:668`); the subscription's data callback is `delivery`. `onDestroy` cancels it first (before the drain at `:525`);
  the foreground gate cancels it (`Idle`). Cancel, never close, so a warm fix survives (`:793-796`). A Dart delivery
  is a subset of platform delivery (the plugin's `isBetterLocation` drops a newer, much coarser fix, §2.2) — the
  watchdog is the backstop, which is why it keeps its wake source.
- **Interval formula** = D3 (iii) as a pure function in `background_fix_request.dart`; constants
  `kBackgroundFixLeadTime` 10 s, `kMinFixRequestInterval` 31 s, `kBackgroundFixHorizon` 30 s, `kRegistrationSlack` 5 s,
  `kPublishWakeLockTimeout` 30 s. Gap proof = D3 (iii), per API level. Wasted-fix bound: the only non-publishing
  deliveries are the historical re-delivery (zero GNSS cost) and a sibling-circle fix consumed by the 30 s horizon —
  ≈ one GNSS fix per publish.
- **Watchdog (`onRepeatEvent`, 72 s — `kBackgroundRepeatInterval` unchanged; `kForegroundActiveAtMsKey`'s 144 s
  staleness stays derived from it, `location.dart:114-129`, `background_location_manager_test.dart:104-118`):** (1)
  prefs reload + foreground-ownership gate (on `active` also cancels the registration → `Idle`); (2) backgrounded and
  `Idle` → run the cycle (which registers below both gates — never a direct registration from the watchdog); (3)
  `Armed` and `now − lastDeliveryAt > kStreamPositionMaxAge` (or the stream errored, or `_deliveryPending`) → run the
  cycle, whose `getCurrentLocation()` cache-misses into today's one-shot→last-known chain, and re-register. In P2a it
  cannot stall (plugin lock); in P2b it needs the wake source D4 names.
- **Wake lock** = D4 (P2a: plugin lock kept + scoped lock added; release owned by Dart `onDestroy`'s `finally` and
  the native timeout, never by the Kotlin lifecycle listeners). **Ownership invariant** becomes lifecycle-exclusive:
  the UI isolate's stream exists only while foregrounded (P1); the FGS registration exists only after the UI released
  ownership (`markForegroundActive(false)` is written after `suspendStream()`; the FGS registers only after reading
  it). `check_ios_background_publish.sh` check 2 ("ONE `.getPositionStream(` site in the service", `:185-196`) stays
  LITERALLY true — the FGS reuses `GeolocatorLocationService.getLocationStream` on its own instance; its header is
  re-worded ("one plugin boundary; one owner per isolate, exclusive by lifecycle"). FGS plugin availability: the
  first registration happens seconds after `onStart` (RustLib + keyring + DB) so the async service bind (§2.2) is
  complete in practice; the watchdog's "Armed with no delivery" path re-registers if it ever is not (V-P2-2).
- **Paused signal only on a completed handoff:** `_onPaused` sends `kForegroundPausedSignal` only `if (handedOff)`
  (`_handOffMlsSession` returns false on stillHolding, `map_shell.dart:918-931`); an unconditional signal would move
  the FGS reclaim probe to "immediately, while a timed-out stop unwinds".
- **Promises (SYNTHESIS §4):** ciphertext-only egress (the fix still reaches only `encryptLocation` `:1296-1304`);
  access gate above every read (`getCurrentLocation()` unchanged; registration behind the disclosure gate and the
  foreground gate by source order — test + guard); toggle OFF ⇒ nothing (provider stops the service
  `background_location_provider.dart:445-449` → `onDestroy` cancels the registration and releases the lock);
  decorrelation + jitter (`seedStaggered`, `dueKeysUpTo`, `nextBackgroundPublishSlot`, `markPublished`, the CSPRNG
  sampler unchanged — the sample is drawn earlier, not differently); TTL web (≤ 168 s + TTFF − 10 s; constants and
  tests untouched); motion-trigger leak (no motion awareness added); presence-only logging (ages, counts, trigger
  names only; Kotlin file added to check 10's list); single MLS session (no new `CircleManagerFfi.newInstance`
  site); FGS notification "sending and receiving" (fetch step unchanged); live-sync default untouched; Play dialog
  "every couple of minutes" (`location_disclosure_dialog.dart:74-77`) is [46 s, 168 s] realized — unchanged claim;
  battery-opt strings unchanged. **Realized intervals sit CLOSER to the CSPRNG sample than today** (today: J + [0, 72] poll slip), so the disclosed jitter shape is better honoured; the Play dialog's "every couple of minutes" is [72 − δ, 168] s realized.

**Exact change list (P2a).**
- `haven/lib/src/constants/location.dart` → `kBackgroundFixLeadTime` (10 s; doc: AOSP hot-TTFF), `kMinFixRequestInterval` (31 s; doc: `MIN_REQUEST_DELAY_MS` + 1 s, `LocationProviderManager.java:181`, with the M-2/M-9 reasoning), `kBackgroundFixHorizon` (30 s; doc: must exceed the lead; keeps the FGS batching window; NOT the stagger spread), `kRegistrationSlack` (5 s), `kPublishWakeLockTimeout` (= `kBackgroundTeardownDrainBudget * 2`, imported from `mls_session_handover.dart` — or move the budget constant here; keep `check_teardown_drain_budget.sh` green), `kForegroundPausedSignal` / `kForegroundResumedSignal` (presence-only strings); `background_location_task.dart:1217` reads `kBackgroundFixHorizon` instead of `kPublishStaggerMaxSpread`; rewrite the `kBackgroundRepeatInterval` doc (`:93-98` → watchdog, no longer the cadence poll).
- `haven/lib/src/services/geolocator_location_service.dart` → `getLocationStream` gains `profile` (sealed `AndroidStreamProfile { foreground; backgroundService(Duration interval) }`, default foreground; iOS ignores it); `_streamSettings` Android arm: foreground unchanged, `backgroundService` → `AndroidSettings(forceLocationManager: true, distanceFilter: 0, intervalDuration: interval)` with NO `timeLimit` and explicit `accuracy: LocationAccuracy.best` on BOTH arms; `bool hasFreshStreamFix({DateTime Function() now})` — a boolean, never a coordinate (outside the gated readers; `check_location_access_gate.sh` untouched). The ONE `.getPositionStream(` site (`:799-804`) stays the only one.
- NEW `haven/lib/src/services/background_fix_request.dart` (pure) → `nextFixRequestInterval({required DateTime earliestDue, required DateTime now, required DateTime plannedPublishStart})`, `registrationIsAligned(registeredTarget, target)`.
- `haven/lib/src/services/per_circle_due_tracker.dart` → `DateTime? earliestDue(Iterable<String> keys)`; header `:16-20` re-worded.
- `haven/lib/src/services/background_location_task.dart` → fields `_fixSub`, `_registeredTarget`, `_lastConsumedFixTs`, `_lastDeliveryAt`, `_deliveryPending`; `_onFixDelivered`, `_ensureRegistration` (ONE call site), `_cancelRegistration`; `_publishCycle` restructured (pre-sampled `J_c`, registration before the loop and even with nothing due, `markPublished` with the pre-sampled value, failure → retry cadence, per-cycle `_relayService?.shutdown()`, `finally` follow-up cycle); `onRepeatEvent` → watchdog that only invokes the cycle; `onReceiveData` routes the two signals (`:592-600`); `onDestroy` cancels the registration first, runs the drain WITH the lock held, and releases it in `finally`; header `:8-14` rewritten. KEEP the anchors the source-order tests grep: `if (foregroundActive) {`, `await _ensureSession()`, `_repairSharingServices()`, `if (!backgroundPublishDisclosureAccepted(`, `getCurrentLocation(`, `encryptLocation(`.
- NEW `haven/lib/src/services/publish_wake_lock.dart` → `MethodChannel('haven.app/publish_wake_lock')`; `Future<void> acquire({Duration timeout = kPublishWakeLockTimeout})`, `Future<void> release()`; `on MissingPluginException` (hosts/iOS/tests — the channel exists only in the FGS engine) and `on PlatformException catch (e)` (log `e.code` only) → no-op; anything else propagates.
- `haven/lib/src/services/background_location_manager.dart` → `ForegroundTaskOptions(` (`:134-144`) UNCHANGED — `allowWakeLock` deliberately ABSENT with a two-line WHY (wake source of the no-fix fallback until P2b); `signalTask(String)` over `FlutterForegroundTask.sendDataToTask` (no-op when the service is not running — the plugin drops it).
- `haven/lib/src/pages/map_shell.dart` → `_onPaused` Android: after `_handOffMlsSession()` (`:1322`) `if (handedOff) BackgroundLocationManager.signalTask(kForegroundPausedSignal)`; `_onResumed`: `signalTask(kForegroundResumedSignal)` immediately after the (P1-moved) `markForegroundActive(true)`.
- `haven/test/mocks/background_task_fakes.dart` → `FakeLocationService` gains a `StreamController<Position>` per `getLocationStream(profile:)` call, `capturedProfiles`, `streamListeners`, `hasFreshStreamFix`, and `deliverFix(Position)` which ALSO becomes what `getCurrentLocation()` serves (mirrors the real tee `:806-809`) plus a separate `oneShotRequests` counter incremented only when no delivered fix is fresh (`fixRequests` today counts every `getCurrentLocation()` call, `:285-291`, which the cycle MUST still make — an oracle on it would assert the cycle never calls the method it must call); `BackgroundTaskHarness.signal(String)`, a fake wake-lock channel recorder (`acquireCalls` with timeouts, `releaseCalls`, order-stamped against `encryptLocation`), a fake `RelayService` counting `shutdown()` calls.
- Kotlin (`haven/android/app/src/main/kotlin/com/oblivioustech/haven/`): NEW `PublishWakeLock.kt` → `object PublishWakeLock : FlutterForegroundTaskLifecycleListener, MethodChannel.MethodCallHandler`; `onEngineCreate` → `MethodChannel(engine.dartExecutor.binaryMessenger, "haven.app/publish_wake_lock").setMethodCallHandler(this)`; `"acquire"` → `timeoutMs.coerceIn(1L, MAX_TIMEOUT_MS)` (`MAX_TIMEOUT_MS = 30_000L`), lazily `newWakeLock(PARTIAL_WAKE_LOCK, "Haven:publish").apply { setReferenceCounted(false) }`, `acquire(ms)`; `"release"` → `if (lock?.isHeld == true) lock.release()`; `onTaskDestroy` / `onEngineWillDestroy` → NOTHING (no release, no `setMethodCallHandler(null)` — D4 release ownership); logs nothing but the method name, never `Log.e(…, e)` with a Throwable or error text. `HavenApplication.kt` `onCreate` (`:36-44`) → `FlutterForegroundTaskPlugin.addTaskLifecycleListener(PublishWakeLock)`. `MainActivity.kt` unchanged (`:1-5`).
- `haven/android/app/src/main/AndroidManifest.xml` → `<uses-permission android:name="android.permission.WAKE_LOCK" />` with the scoped-lock / explicit-declaration comment (as INTERNET, `:3-7`).
- Guards: `scripts/ci/check_android_location_power.sh` (created in P1) gains checks 1–6, function-shaped, fixtures pinned by EQUALITY (each check one passing + one mutated; count stated in the script): (1) the `ForegroundTaskOptions(` slice of `background_location_manager.dart` (comment-stripped) contains NO `allowWakeLock` (P2a; P2b flips this check to `allowWakeLock:` bound to the battery-exemption predicate, never a literal); (2) `PublishWakeLock.kt` contains `PARTIAL_WAKE_LOCK`, `setReferenceCounted(false)`, `coerceIn(1L, MAX_TIMEOUT_MS)`, `MAX_TIMEOUT_MS = 30_000L`, `acquire(` with an argument and no bare `acquire()`, and NO `setMethodCallHandler(null)` / `release()` inside `onTaskDestroy`/`onEngineWillDestroy`; `HavenApplication.kt` contains `addTaskLifecycleListener(PublishWakeLock)`; (3) Haven's manifest declares `WAKE_LOCK` (pattern `check_internet_permission.sh:30-40`); (4) `getLocationStream(` is called from exactly `location_provider.dart` and `background_location_task.dart` under `haven/lib` (interface declaration excluded); (5) `_ensureRegistration(` has exactly ONE call site outside its definition, inside `_publishCycle`, after `if (foregroundActive) {` AND after `if (!backgroundPublishDisclosureAccepted(`; `onDestroy` contains `_cancelRegistration(` before `_inFlightPublish?.timeout(`; (6) the `backgroundService` arm of `_streamSettings` contains no `timeLimit:` and does contain `forceLocationManager: true` and `distanceFilter: 0`. `check_ios_background_publish.sh` → header `:2-30` and check 2 comment re-worded; `SELF_TEST_FIXTURES` stays at P1's 23. `check_m7_native_wake_guards.sh` check 10 (`:1246-1268`, a hard-coded six-file loop with `LOG_FN='(NSLog|os_log|print|debugPrint|debugLog)'` — it cannot see Kotlin `Log.*` and its `errl` scan is log-line-scoped, so `Log.e(TAG, "acquire failed", e)` passes today) → FACTORED into `presence_only_log_scan <file>` driven by a second fixture block (`EXPECTED_LOG_FIXTURES` pinned by equality): `LOG_FN` gains `Log\.[dweiv]\(`; the error-internals pattern gains the 3-arg Kotlin form (a Throwable as last argument, `,[[:space:]]*(e|err|error|t)[[:space:]]*\)`) and `\$\{?e\b`; `PublishWakeLock.kt` appended to the list; fixtures: today's six files pass; `Log.d("lat=$lat")` fails; `Log.e(TAG, "x", e)` fails; `Log.d(TAG, "acquire")` passes; `NSLog("\(location.coordinate)")` fails. `check_location_access_gate.sh`: if `_publishCycle`'s read path changes, checks 1–3 (name-bound) re-pointed in the same commit; `--self-test`. `check_mls_session_single_owner.sh`: still exactly three `CircleManagerFfi.newInstance` files. `session_reclaim_gate_test.dart:338-410` source-order anchors kept verbatim.
- `docs/privacy/privacy_invariants.json` → `INV-L-BACKGROUND-DISCLOSURE-GATE`: `tests` ADD `the gate precedes the stream registration as well as the one-shot`; `guards` ADD `scripts/ci/check_android_location_power.sh`; statement extended "…precedes both `getCurrentLocation()` and the background stream registration…"; its cited test `the gate precedes location COLLECTION, not just publication` keeps its NAME (token `getCurrentLocation(` still the collection call). NEW `INV-L-ANDROID-BACKGROUND-SINGLE-GNSS-REQUEST` (enforced): "while backgrounded with sharing ON exactly one platform location request exists (the FGS's, interval ≥ `kMinFixRequestInterval`; for the circle just published ≥ `kLocationPublishMinInterval − kBackgroundFixLeadTime` = 62 s), the UI stream having been cancelled before it is registered; the FGS publishes on delivery and never sooner than its registered interval on displacement"; no `disclosure_arb_keys` (the Privacy page was removed 2026-08-29); tests: `the registration is re-issued to the earliest pre-sampled due BEFORE the first publish`, `a delivery that finds a circle due within the horizon publishes only that circle`, the P1 no-frame case. `INV-L-ANDROID-NO-PERMANENT-WAKE-LOCK` is a P2b addition (statement: no permanent lock while battery-exempt — `allowWakeLock` bound to the exemption state, the plugin lock kept only while the exemption is not granted — + scoped acquire/release on every path incl. failure + the native registration acquires inside the system's hold, is issued only from `_ensureRegistration` and is cancelled at both disable sites; tests `fgs_no_permanent_wake_lock_test` + `the wake lock is acquired before the first encrypt, re-acquired before the fetch, and released on every exit path`). Additions only — no ratchet item.
- Docs: `M7` §D Android (`:212-228`) FGS request model + indoor residual; D4 (`:443-450`) "2×72 s" stays; §5 runbook (`:743-805`) steps 9–10 (`dumpsys location` registration read, `dumpsys power` lock read, exact greps); §7 (`:900-923`) P2 revert list; §9 (`:936-958`) rows "FGS holds one ≥ 72 s registration → b1 registration oracle", "no permanent wake lock → b1 `dumpsys power` oracle + guard", "UI stream released before handoff → guard (7) + b1 oracle". `P0_1_FGS_SESSION_PLAN.md:430-433` → decision RESOLVED (OD-P2-1); `:382,:410-415` bridge/hold sizing re-derived. `FA:198-201` ("timer under a partial wake lock … Doze is NOT a cause") → the repeat is a watchdog, the cadence rides the platform's location alarm, the only lock is the scoped `Haven:publish`; `FA:51-57` mechanism list; `M7:57-61`; `CI_HARDENING_BACKLOG.md:1553-1556` (144 s gate unchanged — note only), `:1590` unchanged; `MESH_LOCATION_RELAY_DESIGN.md:140` unchanged. Doc comments: task header, `per_circle_due_tracker.dart:16-20`, `location.dart:93-98`, `background_location_provider.dart:402-405` (service kept alive across pause/resume — still true); `kStreamPositionMaxAge` rationale gains "FGS delivered fix".
- ARB: none (`fgsNotificationSharing` stays literally true; `locationSettingsBatteryOptNote`/`AndroidBattery` unchanged). 13 locales untouched.

**Tests FIRST** (`flutter test`; no sleeps — the harness drives `onRepeatEvent`, `deliverFix`, `signal` with injected `DateTime`s; the stagger sampler is the existing zero-gap double).
- NEW `test/services/background_fix_request_test.dart`: `targets the earliest due minus the fix lead`; `never requests an interval at or below MIN_REQUEST_DELAY_MS (30 s) — the floor is kMinFixRequestInterval`; `the initial registration after a publish asks for at least kLocationPublishMinInterval − kBackgroundFixLeadTime` (62 s); `a second circle due between 31 s and 71 s after a publish gets its own fix at its due − lead` (the M-9 window, swept over D_B ∈ (P_A + 30, P_A + 82)); `the fix horizon exceeds the lead` (`kBackgroundFixHorizon > kBackgroundFixLeadTime`, and is independent of `kPublishStaggerMaxSpread` — lint that the task reads the horizon constant); `worst-case inter-publish gap never exceeds kLocationPublishMaxInterval for a hot fix` (EXHAUSTIVE and cheap — a proof, not a sample: API model {S+ delayed register anchored at `t_f`; ≤ 30 registration-anchored with two TTFFs} × J ∈ [72,168] s × TTFF ∈ [0,10] s × cycle latency δ ∈ [0,30] s × the M-9 sibling window — fails if the registration moves to the end of the cycle or the floor rises to 72 s); `cold TTFF stays inside the retention on S+ (≤ 188 s) and is bounded on ≤ 30 (≤ 218 s)`; `registrationIsAligned tolerates kRegistrationSlack and no more`.
- `test/services/per_circle_due_tracker_test.dart` → `earliestDue is the minimum over tracked keys and null when nothing is tracked`.
- `test/services/background_location_task_publish_cycle_test.dart`: `a delivered fix drives the cycle without a one-shot` (`harness.location.oneShotRequests == 0`; `getCurrentLocation()` still called and served from the delivered fix); `the registration is re-issued to the earliest pre-sampled due BEFORE the first publish` (captured `backgroundService(interval)` == `nextFixRequestInterval(...)` of the sampled J, capture precedes the first `encryptLocation`); `a tick with nothing due from Idle registers for the earliest due and never one-shots` (S-5: `oneShotRequests == 0`; capture == `nextFixRequestInterval`); `a re-delivered fix with an identical timestamp runs no second cycle`; `a delivery with nothing due publishes nothing and keeps the registration`; `a delivery that finds a circle due within the horizon publishes only that circle` (a large displacement between two deliveries changes nothing — D3 (iv)); `a fix delivered mid-cycle is consumed by a follow-up cycle, never lost` (`deliverFix` while a publish future is held open; a second encrypt after the first completes; `oneShotRequests` unchanged); `a follow-up cycle dedupes the historical re-delivery of the pending fix` (the same timestamp re-delivered after the follow-up's registration runs no cycle); `the first cycle after handoff awaits the historical delivery and needs no one-shot` (a fix delivered within the ≤ 2 s bound → `oneShotRequests == 0`) and `without a historical delivery the first cycle one-shots once` (nothing delivered within the bound → `oneShotRequests == 1`, never 2); `a failed publish leaves the circle due and shortens the registration to the retry cadence`; `an aligned registration is never re-issued` (capture count stays 1 across three deliveries); `the watchdog with a fresh delivery touches nothing`; `the watchdog after kStreamPositionMaxAge of silence takes the one-shot fallback and re-registers` (`oneShotRequests == 1`, new capture); `the foreground taking ownership cancels the registration and empties the schedule` (`streamListeners == 0` + existing prune assertion; extend `background_location_task_cycle_gates_test.dart:140-181`); `the foreground-paused signal runs a cycle immediately, the resumed signal cancels immediately`; `onDestroy cancels the registration before draining, holds the lock through the drain and releases it last` (`acquireCalls` during the drain succeed; `releaseCalls.last` after the drain); `the wake lock is acquired before the first encrypt, re-acquired before the fetch, and released on every exit path` (every `acquire` timeout `== kPublishWakeLockTimeout`; release on success, encrypt throw, relay throw, `_shuttingDown`); `the publish pool is shut down at the end of every cycle` (fake relay `shutdownCalls == cycles`); the wrapper-level `verifyNever(getCurrentPosition)` lives in `geolocator_location_service_test`, not the harness.
- `test/pages/map_shell_location_access_lifecycle_test.dart` → `a declined handoff sends no paused signal` (S-13).
- `test/services/background_location_disclosure_gate_test.dart` → `the gate precedes the stream registration as well as the one-shot` (source order on `_ensureRegistration(`/`getLocationStream(`).
- `test/services/geolocator_location_service_test.dart` → `backgroundService profile requests best accuracy, no distance filter, the requested interval, the platform LocationManager, and NO timeLimit`; `foreground profile is unchanged (best, 1 m, 1 s)`; `hasFreshStreamFix reports freshness without producing a coordinate` (mock that throws on any coordinate read). `:535-536,:851,:973` (one-shot `forceLocationManager`/`timeLimit`) stay — the UI path keeps the one-shot.
- NEW `test/services/publish_wake_lock_test.dart` → `acquire forwards the timeout in ms`; `acquire never asks for more than kPublishWakeLockTimeout`; `a missing channel is a no-op, not an error`; `release is idempotent`.
- NEW `test/lints/fgs_plugin_wake_lock_policy_test.dart` (family of `fgs_notification_localized_test.dart`; the `fn_slice` idiom on the `ForegroundTaskOptions(` constructor, `//` comments stripped, `expect(slice, isNotEmpty)` anti-vacuity — a file-wide `contains` would be satisfied by the WHY comment): P2a `allowWakeLock is not set (the plugin lock is the watchdog's wake source until P2b)`; P2b flips it to `binds allowWakeLock to the battery-exemption state (never a literal)`.
- `test/constants/location_test.dart` → `kBackgroundFixLeadTime is 10 s`, `kMinFixRequestInterval is 31 s`, `kBackgroundFixHorizon exceeds the lead`, `kPublishWakeLockTimeout is twice one relay attempt and exactly 30000 ms` (the Kotlin `MAX_TIMEOUT_MS` twin).
- Guard mutations (`check_android_location_power.sh --self-test`): `allowWakeLock: true` / `allowWakeLock: false` present (P2a); bare `acquire()`; `MAX_TIMEOUT_MS = 60_000L`; a detaching/releasing lifecycle listener; a third `getLocationStream(` file; a second `_ensureRegistration(` call site; registration above the disclosure gate; `timeLimit:` in the background arm; `onDestroy` without `_cancelRegistration(`; manifest without `WAKE_LOCK`; raw platform branch around `suspendStream(`; `suspendStream(` after `markForegroundActive(false)` — each FAILS, each positive twin PASSES, count pinned.
- Existing red → replacement: `background_location_task_publish_cycle_test.dart:250` `'re-arms on the nominal cadence when the jitter sampler is …'` — sample drawn before the publish; assertion stays (`dueOf == publishStart + J`), fake-sampler call order changes; stagger tests `:753-786` unchanged. `background_location_task_cycle_gates_test.dart:115-138` `'a cold service restart … defers'` → extend with `streamListeners == 0`. `background_location_task_reclaim_orchestration_test` if `_publishCycle`'s signature changes → same orchestration assertions. `session_reclaim_gate_test.dart:338-410` → green (anchors kept). `background_location_manager_test.dart:72-118` unchanged (72 s repeat stays as watchdog; staleness `2×kBackgroundRepeatInterval`). `per_circle_due_tracker_test` otherwise unchanged.
- **Lane `e2e-fgs-publish` (B1)** — `run-b1-fgs-publish.sh` + `b1_fgs_live_foreground_test.dart`: the hold becomes constant-derived, `_postPauseHoldDuration = kLocationPublishMaxInterval + const Duration(seconds: 32)` (the `ios_bg_publish_test.dart:352` idiom; value 200 s unchanged, so no window widens; reason "≥ 1 delivery-driven publish inside one max interval + slack" — the old "2 ticks (144 s) plus slack" derivation is dead) and the 10 s `geo fix` drip stays (`:628-631`; the drip only keeps goldfish "fixed" — the platform's fastest-interval gate spaces deliveries, so the drip must not be what makes the lane pass). NEW oracle steps, parsed never grepped, every sample ONE `adb shell 'date "+%m-%d %H:%M:%S.000"; dumpsys location; dumpsys power'` invocation (DEVICE clock — the B1 window is defined on logcat device timestamps via `window_between_markers`, `:787`; a host-clock sampler is the B8 clock-band trap), period 5 s, started BEFORE `flutter drive` (a 10 s cadence started later can miss the foreground 1 s request entirely and fail the anti-vacuity read on a healthy run): (5) extract Haven's registrations (identity = package/uid; `Request[<provider> @<duration> HIGH_ACCURACY…]` per `LocationProviderManager.toString` `:753-775`, the interval PARSED from `TimeUtils.formatDuration` grammar `+1m40s0ms`; the FGS request prints no `minUpdateInterval`/`minUpdateDistance` suffix, the UI request prints `minUpdateDistance=1.0`); ASSERT after `HANDOFF_CONFIRMED`: no sample shows a Haven request with an interval < 62 s (= `kLocationPublishMinInterval − kBackgroundFixLeadTime`, the two literals named beside the formula — the single-circle lane's registration after a publish is `I = J − 10 − δ ∈ [62, 158] s`, and a retry registration after a FAILED publish is `kBackgroundRepeatInterval − lead` = 62 s too; the wrapper comment says that a failed publish on the hermetic relay inside the window is itself a finding, so nobody widens the bound) once the first `Published to ≥1` is logged, and no sample ever shows two Haven requests; ANTI-VACUITY: at least one pre-`HANDOFF_CONFIRMED` sample shows the `@+1s0ms` request; (6) from the same sample: `ForegroundService:WakeLock` present throughout in P2a (its absence is the P2b oracle); `Haven:publish`, when present, has `ACQ=` age ≤ `kPublishWakeLockTimeout` (30 s) — never a consecutive-sample count (a legitimate cycle re-acquires across the stagger + publish + fetch and a 30 s hold spans 4 samples at 10 s: boundary-flaky); (7) publish count in the window ≥ 2 (first ≈ immediately after the paused signal, second ≤ 168 s later) and consecutive `[BackgroundTask] cycle trigger=delivery` markers that led to a publish ≥ 55 s apart — `floor(0.9 × (kLocationPublishMinInterval − kBackgroundFixLeadTime))` = 55 s, the two literals named beside the formula in the wrapper (a healthy boundary run lands at 55.8 s; "≥ 56 s" would red it), pinned by a shell fixture pair at 55 (pass) / 54 (fail); measured on DELIVERY markers so a slow ack cannot shrink the gap; print `dumpsys batterystats --checkin | grep gps` as evidence only. **(8) No-fix chain oracle (BR-2; Doze-policy half only — AP suspension is hardware-only, said in the lane header):** after the first delivery-driven publish, stop the `geo fix` drip, `adb shell dumpsys deviceidle force-idle`, and assert a last-known publish within `kStreamPositionMaxAge + kOneShotLocationTimeout + slack` with a `[BackgroundTask] cycle trigger=watchdog` marker; in P2b this row is the merge gate for the wake source. V-P2-1 closed by FIXTURE, not by a CI run: the `dumpsys location` and `dumpsys power` grammars (§2.2) are shell self-test fixtures in the SAME commit as the oracle (sample with a 1 s request only pre-window → pass; 1 s request inside the window → fail; two Haven requests in one sample → fail; `Haven:publish` with `ACQ=-31s000ms` → fail; no pre-pause 1 s request → fail — anti-vacuity); the first CI run confirms the grammar against the API-34 image. `check_e2e_step_timeout_ordering.sh`. Lanes B3/B5/B6/B9, `e2e-background-catchup`, `e2e_combined`: unaffected — B5's stream-silence discriminator (`b5_permission_revocation_test.dart:365-377`) runs FOREGROUNDED with the unchanged 1 m / 1 s stream (grep for `AppLifecycleState` = 0 hits; `run-b5-permission-revocation.sh:191,1947` mention `distanceFilter: 1` for that FOREGROUND stream — still true after every phase); B6 is foreground (`publishNow`, `:394-397`); B9 fakes location. Recorded so nobody "fixes" them.

**Implementer work packets** (sequential unless marked ∥).
| # | Packet | Sequencing | Done when |
|---|---|---|---|
| P2a-1 | constants (incl. `kMinFixRequestInterval`, `kBackgroundFixHorizon`) + `background_fix_request.dart` + `PerCircleDueTracker.earliestDue` + the exhaustive property test | ∥ P2a-2 | `flutter test test/services/background_fix_request_test.dart test/services/per_circle_due_tracker_test.dart test/constants/location_test.dart`; `flutter analyze` |
| P2a-2 | `GeolocatorLocationService` profile + `hasFreshStreamFix` + tests; `check_ios_background_publish.sh` header re-word | ∥ P2a-1 | `flutter test test/services/geolocator_location_service_test.dart test/providers/location_provider_test.dart`; `check_ios_background_publish.sh` + `--self-test` (24); `check_location_access_gate.sh` |
| P2a-3 | Kotlin `PublishWakeLock.kt` (no release in listeners) + `HavenApplication` registration + manifest `WAKE_LOCK` + Dart `publish_wake_lock.dart` + the wake-lock policy lint test (P2a form) + guard checks 1–3 + m7 check-10 factoring with the Kotlin patterns and fixtures | after P2a-1/2 | `flutter build apk --debug` compiles; `flutter test test/services/publish_wake_lock_test.dart test/lints/fgs_plugin_wake_lock_policy_test.dart`; guard + `--self-test`; `check_m7_native_wake_guards.sh` (+ `--self-test`, log-fixture count pinned) with the new file listed |
| P2a-4 | `background_location_task.dart` delivery-driven cycle (registration even with nothing due; `_deliveryPending`; per-cycle pool shutdown; lock through the drain) + watchdog + signals + fakes/harness (`deliverFix`, `oneShotRequests`) + all cycle tests + disclosure-gate order test + guard checks 4–6 + manifest additions | after P2a-3 | `flutter test test/services/`; guard self-tests; `flutter analyze`; `check_privacy_invariants.sh`; `--static-only` |
| P2a-5 | `map_shell.dart` signals (`if (handedOff)` paused signal; resumed signal; P1 owns the surrounding reorder) + the S-13 test + docs | after P2a-4 | anchors intact (rule 15); `flutter analyze` |
| P2a-6 | B1 lane oracle steps 5–8 + the grammar shell fixtures (same commit) + constant-derived hold | after P2a-4 | `bash tooling/e2e/ci/run-b1-fgs-publish.sh --self-test` (14 → 16+); `check_e2e_step_timeout_ordering.sh`; one green `e2e-fgs-publish` run; full `check_coverage.sh` before push — floors `background_location_task.dart|80` (measured 82.95 %, 287/346; the drafts' "27" is stale — the staged file is authoritative), `background_location_manager.dart|52`, `geolocator_location_service.dart|85`; NEW files (`background_fix_request.dart`, `publish_wake_lock.dart`) get `--list`-derived rows; a rewrite that lands without tests goes HOLD → tests, never a number; moving the cycle into a new file changes the denominator → re-pin BOTH rows from the P2a CI run with `--repin` only |
| P2b-1 | (after P2a's hardware row + OD-P2-2/OD-P2-3) native `LocationListener`/`PendingIntent` registration in `PublishWakeLock.kt` (acquire inside the delivery hold; provider named), FGS registration routed to it ONLY via `_ensureRegistration`'s channel call, native `cancelRegistration` at both disable sites, the fail-closed receiver, no-fix watchdog wake source (inexact alarm for the exempt cohort), `allowWakeLock: !isIgnoringBatteryOptimizations` re-evaluated at enable/resume, guard check (1) flipped to the exemption predicate + native pins (no `requestLocationUpdates(` outside the channel handler), `INV-L-ANDROID-NO-PERMANENT-WAKE-LOCK`, lint test flipped, B1 step (6) inverted for the exempt run (`ForegroundService:WakeLock` NEVER present) + the toggle-OFF-with-force-killed-service oracle | after P2a | all of the above green; `a toggle-off with a dead service still cancels the native registration` green; the BR-2 no-fix oracle green under forced idle; the forced-idle HARDWARE liveness row (relay-side gaps ≤ 228 s, screen-off, cellular) recorded in BOTH exemption states BEFORE merge |

**Reviewer checklist.** Security/privacy: no coordinate in any new `debugPrint`/Kotlin log; `PublishWakeLock.kt` logs nothing but method names and the factored check 10 catches a planted `Log.e(TAG, "x", e)`; the registration cannot precede the disclosure gate or the foreground gate on ANY path (watchdog, delivery, signal) — try to reach `_ensureRegistration` from `onStart`/`onReceiveData`/`onRepeatEvent` directly (guard (5)'s count must fail); the paused signal must not bypass `prefs.reload()` (a paused signal while `kForegroundActiveAtMsKey` is still fresh must NOT register) and must not be sent on a declined handoff; Rule 4 keys hex only; no new `CircleManagerFfi.newInstance` site. Liveness vs FA: inject a fake that re-delivers the last fix on every registration (dedupe + alignment must hold); a stream that never delivers (V-P2-2) — the 168 s watchdog must recover (it keeps its wake source in P2a — remove the plugin lock and show the indoor row still passes: must be impossible in P2a); a stream error mid-Armed → re-registration, not permanent `Idle`; a delivery mid-cycle → follow-up cycle, never lost; from `Idle` with nothing due → registered, no one-shot; `onDestroy` ordering (cancel → bounded drain UNDER the lock → unbounded commit-critical drain → release → dispose) unchanged in shape; the 144 s stamp staleness still lets the FGS take over after a UI kill; `_shutdownSignal` still aborts the wait paths; reclaim ordering (`session_reclaim_gate_test`, `background_location_task_reclaim_orchestration_test`, `session_guard_contention_test`). Cadence: the exhaustive property test proves no gap > 168 s + max(0, TTFF − 10) on S+ and ≤ 218 s on ≤ 30, that no request is ever ≤ 30 s, and that a sibling due 31–71 s after a publish is NOT starved (the 72 s floor must fail it). Wake lock: every `acquire` timeout ≤ 30 s natively coerced; `release` on every exit incl. `_unlessShuttingDown` null returns; nothing holds the lock across a `_sleepUnlessShuttingDown` > 30 s without re-acquiring; the Kotlin listeners must not release or detach (guard (2) fixture). Test reliability: no `Future.delayed`; the harness injects `now`; the B1 oracle parses device-stamped samples, its anti-vacuity read is asserted, the lock bound is an age, and the grammar fixtures land in the same commit. Copy: nothing user-visible changed; the motion-trigger bound (`INV-L-MOTION-TRIGGER-BOUNDED`) still holds (no displacement logic anywhere in the FGS).

**Risks / rollback.** GMS `fused` (API 31+ Play devices) may ignore the interval for HIGH_ACCURACY and keep GNSS on (I-P2-2) — detected by the hardware gps time; there is NO geolocator `gps` fallback (§2.2) — the remedy is P2b's native registration naming the provider. Goldfish `Request[…]` grammar differs → the fixture fails loudly on the first run and is corrected once. Cold TTFF after an indoor stretch: 188 s single-fault on S+ (218 s on ≤ 30); stacked with a P2b suspend gap it exceeds 228 s — §6.3 C6. OEMs that kill services without wake locks more readily — moot in P2a (plugin lock kept); in P2b the FGS is still type `location`, exemption still requested. Rollback: ONE revert of the P2a commit series restores the tick-driven cycle and the one-shot; the guard checks 1–6, the m7 check-10 factoring + list entry (the deleted Kotlin file must leave the list in the same revert — `code_view` of a missing file is red), the lane steps and fixtures, the Kotlin file, the `INV-L-BACKGROUND-DISCLOSURE-GATE` edit (its added test name + guard — rule 3/6 otherwise red) and `INV-L-ANDROID-BACKGROUND-SINGLE-GNSS-REQUEST` (`.deleted`) revert with it; P2b's revert additionally restores `allowWakeLock` default, guard (1)'s P2a form, the lint test's P2a form and deletes `INV-L-ANDROID-NO-PERMANENT-WAKE-LOCK` (`.deleted`); no wire, DB, prefs-key or copy change to migrate.

**Acceptance.** CI: all tests above green; `check_android_location_power.sh` + `--self-test` green; `e2e-fgs-publish` green with the registration oracle (one Haven request, interval ≥ 62 s = `kLocationPublishMinInterval − kBackgroundFixLeadTime` after the first publish — the single-circle lane's registration is `I = J − 10 − δ ∈ [62, 158] s`, so a 72 s bound would red a correct build on ≈ 10 % of cycles, whenever J < 82 s; the `@+1s0ms` request observed pre-handoff), the `dumpsys power` oracle (`Haven:publish` `ACQ=` age ≤ 30 s at every sample), ≥ 2 delivery-driven publishes ≥ 55 s apart in a 200 s hold, the no-fix chain oracle under forced idle; `check_privacy_invariants.sh` green with additions only; coverage gate green. Hardware (owner, `POWER_MEASUREMENT.md`): `dumpsys batterystats --reset` → 60 min backgrounded stationary → per-uid gps time ≤ 10 % of the window (vs ≈ 100 % today), `dumpsys location` shows the ≥ 62 s Haven request and the listener counts (gnss status / nmea); 60 min walking → every relay-observed `created_at` gap ≤ 228 s (acceptance target ≤ 188 s, T-2); indoors 30 min → publishes continue (last-known path) and no "not sending" banner. P2b adds: partial wake-lock time ≤ 1 % of the window, no Haven partial lock older than 30 s at any sample, the indoor row under `dumpsys deviceidle force-idle`, screen-off, cellular.

**Owner decisions / open questions.** OD-P2-1, OD-P2-2, OD-P2-3. V-P2-1 (`dumpsys location` grammar on the CI API-34 image — pre-stated from `LocationRequest.toString()`, closed by the fixture, confirmed on the first run); V-P2-2 (first FGS listen after `onStart` receives events — assert via a `[BackgroundTask] registration armed` marker followed by a delivery in B1); V-P2-3 → V (`PowerManager.WakeLock.acquire(timeout)` on a held non-refcounted lock re-posts the timer, `PowerManager.java:3930-3950, 3984-4000`); V-P2-4 → V (`addTaskLifecycleListener` from `Application.onCreate` precedes the boot-restart engine — `ForegroundService.kt:45-54,173-178`, `ForegroundTask.kt:47-70`, `RebootReceiver.kt:43-46`; confirm on `adb reboot` in M7 runbook step 7); I-P2-1 (HAL `CAPABILITY_SCHEDULING` on the owner's phones — informational, also decides the indoor residual); I-P2-2 (GMS fused duty-cycling); U-P2-1 (delivery→Dart wake window — P2b only; consequence stated in D4).

### 5.3 Phase P3 — iOS native location owner with accuracy profiles + tier-based indicator/session policy + copy/l10n (D1, D2) [OD1]

**Goal / non-goals.** Background sharing ON, stationary: the GNSS receiver is no longer held at Best 24/7; while
backgrounded AND stationary the ONE CoreLocation session runs at `kCLLocationAccuracyHundredMeters` (Wi-Fi/cell,
≈ 4–6× cheaper than a GPS tier) and returns to Best on movement or foreground — a live `desiredAccuracy` change,
never a restart. Under CONFIRMED **Always** the constant blue pill disappears; under **When-In-Use** — and under a
provisional or iOS 17 Always, which the OS treats as WIU — the pill stays (mandatory, honest) and the activity
session stays; every relaunched process is receive-only on BOTH paths (stream start refused, one-shot unreachable
from the background). Cadence, TTL web, motion trigger, decorrelation, wire payload and receive plane untouched
(D0). Non-goals: no `liveUpdates`, no SLC/region change (`HavenSLCHandler` untouched), no Android change, no push,
no dependency, no user setting (OD1), no change to what leaves the device.

**Design.**
- **Native owner `HavenLocationStreamHandler.swift`** (D1): registered like the other handlers
  (`AppDelegate.swift:17-34,47-61`: retained `private let locationStreamHandler = HavenLocationStreamHandler()`;
  `register(with: messenger)` inside the `FlutterViewController` block). Channel names follow
  `HavenBackgroundSessionHandler.channelName` (`:53`) / `HavenSLCHandler` (`:78,85`); one handler per channel name
  (the SLC file's warning `:80-84`). `init` sets the four pinned properties; `onListen(arguments:)` is the only
  `startUpdatingLocation()` site and ALWAYS returns `nil` — every outcome travels through the sink (§2.1):
  `guard sink == nil else { return nil }` (a re-listen is engine-driven: the engine cancels the existing sink first,
  so this is unreachable defensive code — no error, no test); `let allowsBg = args["allowsBackgroundLocationUpdates"] as? Bool ?? false`
  (one line — the derivation is guard-pinned; `?? true` or a literal must fail);
  `if allowsBg && UIApplication.shared.applicationState == .background { events(FlutterError(code: "background_start_refused", message: nil, details: nil)); events(FlutterEndOfEventStream); return nil }`
  (`== .background`, never `!= .active`); `manager.allowsBackgroundLocationUpdates = allowsBg`;
  `applyIndicatorPolicy()` (`= !sessionHandler.alwaysConfirmed`, D2); `bestSince = Date()`; `desiredAccuracy = Best`
  (every start is foregrounded); `startUpdatingLocation()`. `onCancel` → `stopUpdatingLocation()`,
  `allowsBackgroundLocationUpdates = false`, `lastBestFix = nil`, `sink = nil` — the only stop path (the service
  gate's cancel or a provider disposal). `setProfile(best|hundredMeters)` → the two `desiredAccuracy` values; a switch
  to Best records `bestSince = Date()`. `didUpdateLocations`: for each location
  `if manager.desiredAccuracy == kCLLocationAccuracyBest && loc.timestamp >= bestSince { lastBestFix = loc }`; sink map
  `["lat","lon","tsMs","acc","alt","speed","course","profile": "best"|"hundredMeters"]` where `profile` is the
  computed with the SAME predicate as `lastBestFix` — `manager.desiredAccuracy == kCLLocationAccuracyBest && loc.timestamp >= bestSince`
  — so a fix computed under the previous tier is tagged `hundredMeters`, kept out of the cache and never emitted; Dart
  never needs a second clock, and the tier race has one source of truth. `didFailWithError` →
  `events(FlutterError(code: (error as? CLError)?.code == .denied ? "denied" : "failed", message: "\(type(of: error))", details: nil))`
  — type only, never `localizedDescription` (m7 check 10 `:1247-1262`). `status()` →
  `["running","allowsBackgroundLocationUpdates","showsBackgroundLocationIndicator","profile","authorization","backgrounded"]`
  (booleans/enum strings only; `backgrounded = applicationState == .background`). `lastBestFix()` → map or nil;
  `clearLastBestFix()` → nil. No logging (posture of the session handler, check 8 `:296-299`). Relaunch via
  SLC/region/BGTask: `applicationState == .background` at `onListen` ⇒ refused, AND the Dart cold-cache shortcut
  reads `backgrounded` (below) so the plugin one-shot is unreachable too — the wake is receive-only BY CONSTRUCTION
  on both paths (closes FA:218-222). Nothing version-gated (APIs iOS 15.5-safe); the session handler keeps its
  `#available` guards (`:134-151`).
- **Dart `IosLocationSource`** (`haven/lib/src/services/ios_location_source.dart`, ONE class = channel service +
  pure controller + the single confirm `Timer`; channel half mirrors `ios_background_session_service.dart:62-152`):
  `Stream<Position> positions({required bool allowsBackgroundLocationUpdates})` (EventChannel
  `receiveBroadcastStream(args)` — one subscriber by construction; emits Best-profile fixes ONLY, already converted),
  `Future<Position?> lastBestFix()`, `Future<void> clearLastBestFix()`, `void onForeground(bool)`,
  `DateTime? get lastConfirmedAt`, `Future<IosLocationStreamStatus> status()` (parsed with
  `invokeMapMethod<String, Object?>`, fail-closed on a missing OR wrong-typed key — `backgrounded` defaults to
  `true`); `NoopIosLocationSource` (never emits; non-iOS); `createIosLocationSource()`. Errors: a
  `PlatformException(code)` pushed by the native sink is re-thrown into the stream (the service's `handleError`
  clears the cache and forwards, `:812-815`). Internally `IosFix` carries `profile`, `accuracy`, `timestamp`,
  coordinates; a `hundredMeters` fix feeds the controller and never leaves the class.
- **`GeolocatorLocationService` integration (≈ 10 lines):** constructor gains `IosLocationSource? iosSource` (seam
  like `isIOS`, `:170-172`); `getLocationStream` (`:798-822`) routes in one expression with ONE geolocator site and
  ONE native site:
  ```dart
  final source = _isIOS
      ? _iosSource.positions(allowsBackgroundLocationUpdates: backgroundSharingEnabled)
      : _geolocator.getPositionStream(locationSettings: _streamSettings()).map(_convertPosition);
  return source.map((p) { _lastStreamPosition = p; return p; }).transform(/* existing error/done handlers */);
  ```
  (the outer controller of the P1 gate wraps this). `_streamSettings` (`:653-674`) → Android-only; the iOS arm and
  `_kIosNoDistanceFilter` (`:17-31`) are deleted (the iOS shape lives in Swift where it is applied; the `-1`
  pointer-compare trap `:113-114` / `FA:1071-1079` becomes moot — say so in the guard header so nobody re-adds
  the constant). `_currentPositionSettings` (`:612-621`) keeps `AppleSettings(timeLimit: kOneShotLocationTimeout)`.
  `getCurrentLocation` (`:677-750`): freshness = D1 (iv) reading `_iosSource.lastConfirmedAt`; the iOS backgrounded
  shortcut `:711-724` is keyed off `(await _iosSource.status()).backgrounded` (fail-closed) instead of
  `_foregroundActive`, and calls `_getLastKnownPosition()` = `_isIOS ? _iosSource.lastBestFix() : _geolocator.getLastKnownPosition()`
  (the helper name contains `getLastKnownPosition(` so `check_location_access_gate.sh`'s order pins `:173-181`
  keep matching; the gate still precedes it; the new ios check pins `lastBestFix(` before `getCurrentPosition(`).
  `_platformStillPermitsLocation` (`:593-605`) unchanged. `foregroundActive` setter (`:298`) forwards
  `onForeground(value)`; `clearCachedPosition()` (`:343`) also calls `_iosSource.clearLastBestFix()`;
  `_noteAccessLost` clears the confirmed age together with the cache. Doc comments `:117-162`, `:185-224`,
  `:623-652` rewritten (delete "with the indicator giving the user continuous transparency", `:640-641`).
- **Profile controller** (inside `IosLocationSource`, PURE: `onFix(fix, now)`, `onForeground(v, now)`,
  `Duration? nextDeadline(now)`, `onDeadline(now)` on fixed `DateTime`s — no `fake_async`; the single `Timer` is
  armed by the class from `nextDeadline`). State: `profile ∈ {best, hundredMeters}`, `foreground`, `anchor` (last
  Best fix), `movedAt` (last displacement ≥ threshold, or the backgrounding instant), `confirmedAt` (last fix that
  confirmed the anchor). `d = haversine(f, anchor)` (the `map_shell.dart:1102-1125` formula moved to
  `haven/lib/src/utils/geo_distance.dart` so the controller and the motion trigger share one). Transitions:
  `onForeground(true)` → `best` (always); `onForeground(false)` → stay `best`, `movedAt = now`. `best`, Best fix `f`:
  `anchor = f`; if `d_prev ≥ kMotionTriggerDistanceMeters` → `movedAt = f.ts`; if `!foreground && f.ts − movedAt ≥ kStationaryDwell`
  → `hundredMeters`, `confirmedAt = f.ts`. `hundredMeters`, fix `g` with `g.accuracy ≤ kStationaryConfirmMaxAccuracyMeters`
  (100 m): if `d ≥ kMotionTriggerDistanceMeters` → `best`, `movedAt = g.ts` (anchor unchanged until the first Best fix
  replaces it); else `confirmedAt = g.ts` (re-arm the confirm deadline). Coarser fixes are IGNORED (neither confirm nor
  move — a fix that cannot resolve 100 m cannot vouch for 100 m of stillness). Confirm deadline
  (`kStationaryConfirmMaxAge` after `confirmedAt`) → `best`, `movedAt = now` (dwell restarts: ≥ 120 s of Best before
  dropping again — the honest fallback when the OS delivers nothing usable; freshness outranks power). Stream
  cancel/error/done → reset; the next start is Best by construction. Bound (D1 (iv)): a confirmed anchor is never
  more than `kMotionTriggerDistanceMeters + kStationaryConfirmMaxAccuracyMeters` = 200 m from any confirming fix —
  the invariant's granularity (`INV-L-MOTION-TRIGGER-BOUNDED`, ~100 m)
  plus the fix's own error radius; Wi-Fi jitter inside 100 m cannot flap the profile, a genuine 100 m move is seen
  with any ≤ 100 m fix, and a Wi-Fi position jump ≥ 100 m costs one 120 s Best excursion and, correctly, no publish.
- **Session handler tier policy** (D2) at `HavenBackgroundSessionHandler.swift:134-136`:
  ```swift
  if #available(iOS 17.0, *) {
    // alwaysConfirmed: false until the .always service session's diagnostics say so (iOS 18+);
    // always false on iOS 17. Provisional Always therefore keeps the WIU posture.
    let wantsActivitySession = status == .authorizedWhenInUse || !alwaysConfirmed
    if wantsActivitySession {
      if backgroundActivity == nil { backgroundActivity = CLBackgroundActivitySession() }
    } else if UIApplication.shared.applicationState != .background {
      // arm() never withdraws a claim while backgrounded; disarm() always does.
      (backgroundActivity as? CLBackgroundActivitySession)?.invalidate()
      backgroundActivity = nil
    }
  }
  ```
  `alwaysConfirmed` is set by a diagnostics observer on the held `.always` session (`:137-151`; iOS 18+) whose body,
  on the main actor, sets the flag, re-runs `arm()` and fires `onAlwaysConfirmedChanged` → `applyIndicatorPolicy()`
  (the diagnostic arrives after `arm()` has returned — D2); it is also re-evaluated on every `arm()`; `disarm()` `:158-167` unchanged and unconditional; `status()` `:172-182` gains
  `alwaysConfirmed`. Stuck-indicator record = D2 / M7 §6 0c.
- **Traffic-shape proof (no ratchet):** publish instants come from exactly three unchanged drivers — per-circle
  `JitteredScheduler` ticks (`location_publish_scheduler_provider.dart:267-335`), the motion trigger
  (`map_shell.dart:1102-1148`: ≥ 100 m from the last publish point AND ≥ 60 s overlap guard), the resume burst
  (`:1696-1703`). The profile switch is a property write: publishes nothing, opens no socket. The motion trigger's
  INPUT is the emitted stream, which contains Best fixes only, so while stationary it receives nothing and cannot
  fire; the same displacement that fires it today first flips the profile to Best (on a 100 m-tier fix) and then
  fires the trigger on the next Best fix — DELAYED by one delivery (seconds), never advanced or added. A
  noise-induced Best switch produces no publish unless a Best fix really is ≥ 100 m from the last publish point.
  The set of publish instants is a function of (scheduler CSPRNG, real ≥ 100 m displacements, overlap guard)
  exactly as today; the schedule is identical in both profiles; no new moving/stationary signal exists on the
  wire. `kMotionTriggerDistanceMeters`/`kLocationPublishOverlapGuard` untouched (`location_test.dart:26-33,72-77`).
  **Payload shape:** ciphertext LENGTH is relay-visible (`SECURITY.md:729-770`, sizes not padded) — a re-sent Best
  fix carries no extra field/flag: the Rust test `resent_fix_payload_has_identical_shape` asserts
  `serde_json::to_vec(resent).len() == serde_json::to_vec(fresh_same_coordinate).len()` (bytes, not key sets —
  `LocationMessage` serialises latitude, longitude, geohash(8), timestamp, expires_at, `types.rs:55-99`, and
  serde_json's shortest-round-trip f64 makes length a function of digit count) and records the residual honestly:
  length varies with the coordinate VALUE in every version, so the claim is "a re-send adds no signal", never "no
  signal in size"; `raw_accuracy` still skipped.
- **Lifecycle interactions:** toggle ON (foreground UI): `setEnabled` persists → `arm()` → state flip
  (`background_location_provider.dart:263-272`, check 10) → provider rebuild → `onCancel` → `onListen(allowsBg: true)`
  in the foreground → Best. Toggle OFF while paused (C4): the P1 watcher calls `suspendStream()` (native `onCancel`
  clears `allowsBackgroundLocationUpdates` and `lastBestFix`) + `clearCachedPosition()` and `disarm()` (`:301`)
  releases the sessions → suspends. Identity deletion: `cancelNativeSchedulers` disarms (check 10); logout
  `clearCachedPosition` now also clears the native copy. Resume: `_setForegroundActive(true)` → `onForeground(true)`
  → `setProfile(best)`; `_onResumed` unchanged otherwise. `locationAccessProvider` recovery/`refresh()`: a foreground
  `invalidate` restarts in the foreground; while suspended it never invalidates (P1). Authorization change while
  backgrounded: `arm()` may ADD an activity session (downgrade to WIU) but never removes one until the next
  foreground (D2).

**Exact change list.**
- Native: NEW `haven/ios/Runner/HavenLocationStreamHandler.swift`; `haven/ios/Runner.xcodeproj/project.pbxproj` (objectVersion 54, `:6`, explicit file lists) by the precedent of the four existing handlers (`:14-17`, `:55-58`, `:130-133`, `:304-307`): ids `5E10CA750000000000000001` (PBXFileReference, after `:58`) and `5E10CA750000000000000002` (PBXBuildFile, after `:17`); one line in the Runner group children (after `:133`) and one in the `Sources` phase (after `:307`) — `grep -c 'HavenLocationStreamHandler.swift' project.pbxproj` must be 4 (FA:1080 avoided a pbxproj edit for the *region* because it fit an existing handler; a new updates-owner is a new concern and follows the 2026-08-20 session-handler precedent). `AppDelegate.swift:17-34,47-61` → retain + register (with the others; only the BGTask handler must precede `super.application(…)`, `:223-226`); `locationStreamHandler.onAuthorizationChanged = { [weak self] in self?.backgroundSessionHandler.arm() }` assigned AFTER `backgroundSessionHandler.register(with:)` (line-order pin — the delegate fires at manager creation). `HavenBackgroundSessionHandler.swift:134-136` → `alwaysConfirmed` + tier branch + the background guard; iOS 18 diagnostics observer; `status()` gains `alwaysConfirmed`; header `:15-17` ("created under When-In-Use and until Always is CONFIRMED — under confirmed Always it would be the pill; arm() never withdraws a claim while backgrounded; disarm() always does").
- Dart: NEW `ios_location_source.dart` (channel + controller + timer, one class), `utils/geo_distance.dart` (`haversineMeters` moved out of `map_shell.dart:1150-1170`); `geolocator_location_service.dart` edits above; `constants/location.dart` → three constants (`kStationaryConfirmMaxAccuracyMeters = kMotionTriggerDistanceMeters`, doc with the 200 m bound) + `kStreamPositionMaxAge` doc `:131-148` ("a fix at most this old — or, on iOS while stationary, a Best-profile fix CONFIRMED this recently by a ≤ 100 m-accuracy fix within 100 m of it; undetected displacement while confirming < 200 m"); `service_providers.dart:107-128` → `iosLocationSourceProvider` (shape of `:115-119`); `locationServiceProvider` passes it; `ios_location_auth_service.dart:3-5` → "Background sharing continues under While-In-Use (with the OS's blue location bar); 'Always', once confirmed, is what lets Haven not show that bar and catch up after termination." ("not show", never "hide"); `location_settings_page.dart:158-160, :298-310` → the guidance card renders only under `IosAuthStatus.always` and composes base + (`backgroundActivitySessionHeld ? bar : arrow`) from a `iosIndicatorSentenceProvider` (reads `iosBackgroundSessionServiceProvider.status()`, invalidated on toggle `:113` AND on `AppLifecycleState.resumed` from the page, together with `iosLocationPermissionProvider`); `map_shell.dart:376-391` comments; `ios_background_session_service.dart:32-47` parser gains `alwaysConfirmed` (and `indicatorShown` if OD-P3-c lands) with its fail-closed tests extended.
- ARB (13 files: en, ar, de, es, fa, fr, hi, ja, ne, pt, ru, tr, ur): `locationSettingsIosGuidance` (`:473`, becomes the tier-neutral BASE), NEW `locationSettingsIosCatchUp` (the catch-up sentence moved out of the guidance value; the 12 translations copied byte-for-byte, never re-translated; rendered LAST), NEW `locationSettingsIosIndicatorArrow`, NEW `locationSettingsIosIndicatorBar`, `locationSettingsIosLimitedNote` (`:453`) per §7.1 (English + `@description` verbatim there), plus the adopted bar-raise NEW `settingsLocationSubtitleOn` / `settingsLocationSubtitleOff` (the Settings hub Location tile's dynamic subtitle, §7.1). `locationSettingsIntro`/`ToggleSubtitle` untouched. Workflow (P6 rule 8 — binding for every round): translator agent ×12 → INDEPENDENT reviewer agent ×12 handed the GATING FACTS (which key renders under which tier/handler state; the base key must not name any indicator; the arrow/bar keys name exactly one; no "pause"/"timer"; Apple's localized Settings menu names, tier-neutral "Location Services settings" wording because iOS 15 has no "Privacy & Security" menu) who check the translator's REASONING, not just output (register, plurals, RTL for ar/fa/ur, screen-reader readability) → `dart run scripts/ci/arb_parity_check.dart haven/lib/l10n` → `cd haven && flutter gen-l10n` (warning-free) → `l10n-check.yml`; `l10n-ai-review.yml` advisory.
- Non-ARB copy: `.github/workflows/e2e-ios-auth-tier.yml:10-16` → "…keeps delivering under 'When In Use', with the blue location bar (mandatory there); under a confirmed 'Always' Haven shows no bar."; `run-b7-ios-auth-tier.sh:10-16` same; `tooling/e2e/ci/run-ios-bg-publish.sh:248-270` drip comment (no filter; the drip's job is delivery + staying below 100 m); `haven/integration_test/ios_bg_publish_test.dart:410-433` `_failIfSuspended` names the native session (`HavenLocationStreamHandler`, `allowsBackgroundLocationUpdates` parameter); `geolocator_location_service.dart:637-641` comment rewritten with the tier rule; `CLAUDE.md:258` lane sentence → "native CoreLocation session armed (tier-dependent indicator/session oracle) + publishes continue under the 100 m stationary profile + toggle-off silence".
- Guards (`scripts/ci/check_ios_background_publish.sh`): file list `:34-43` → add `STREAM_HANDLER`, `IOS_SOURCE`, `PBXPROJ`. Check 2 (`:192-196`) → keep "exactly 1 `.getPositionStream(`"; ADD "exactly 1 `.positions(`" in the service and `receiveBroadcastStream(` only in `ios_location_source.dart` under `haven/lib`. Check 3 (`:201-206`) → `AppleSettings(` banned inside `_streamSettings`. Check 4 `check_stream_settings` (`:100-128`) → REPLACED by `check_ios_stream_route <service.dart>`: `getLocationStream` body contains `positions(allowsBackgroundLocationUpdates: backgroundSharingEnabled)` exactly; file-wide NO other `allowsBackgroundLocationUpdates *:` (R8); `_streamSettings` has no `AppleSettings(`; `getCurrentLocation` body references `lastBestFix(` BEFORE `getCurrentPosition(` (line-order, like check 12 — the F4 route); `clearCachedPosition` body contains `clearLastBestFix(`. Fixtures (8): passes; `allowsBackgroundLocationUpdates: true` literal; second `.positions(`; `AppleSettings(` back; one-shot before `lastBestFix(`; `clearLastBestFix(` missing; `_foregroundActive` back in the backgrounded shortcut; everything commented out (anti-vacuity). NEW `check_native_stream_handler <swift>`: `init` contains `pausesLocationUpdatesAutomatically = false`, `distanceFilter = kCLDistanceFilterNone`, `activityType = .other`; file-wide exactly one `distanceFilter =` and one `pausesLocationUpdatesAutomatically =`; `desiredAccuracy =` names ONLY `kCLLocationAccuracyBest`/`kCLLocationAccuracyHundredMeters`; `onListen` contains the one-line `allowsBg = ` + `args["allowsBackgroundLocationUpdates"] as? Bool ?? false`, `applicationState == .background` AND `background_start_refused` emitted via `events(FlutterError(` (never `return FlutterError(`), `allowsBackgroundLocationUpdates = allowsBg`, and is the only `startUpdatingLocation()` site; `showsBackgroundLocationIndicator = !` + `alwaysConfirmed` exactly once and no other assignment; `lastBestFix =` only inside `if manager.desiredAccuracy == kCLLocationAccuracyBest && loc.timestamp >= bestSince`; `onCancel` contains `lastBestFix = nil`; `clearLastBestFix` handled; no `NSLog\(|[^a-zA-Z]print\(|localizedDescription`. Fixtures (16): passes; auto-pause on; `distanceFilter = 100`; third tier; literal `true`; `?? true`; `let allowsBg = true`; R7 gate removed; R7 gate written as `!= .active`; `return FlutterError(` from `onListen`; indicator hardcoded `true`; second `startUpdatingLocation()`; `lastBestFix` under 100 m; `lastBestFix` without the `bestSince` comparison; `onCancel` without `lastBestFix = nil`; coordinate reaches `NSLog`. Check 8 (`:277-310`) → factored `check_arm_tier_policy <swift>` CARRYING all eight existing assertions (consent key, disclosure key, `disarm()` in arm, `.authorizedWhenInUse`, `#available(iOS 17.0, *)`, `CLBackgroundActivitySession()`, `.authorizedAlways`, no `NSLog/print`, disarm invalidates + nils both — the Rule-10 fail-closed gate that must never rot) plus: `CLBackgroundActivitySession()` AFTER `wantsActivitySession` inside `arm()`, `wantsActivitySession` derived from `.authorizedWhenInUse ||` + `!alwaysConfirmed`, the invalidate inside `applicationState != .background`, `arm()` contains `backgroundActivity = nil`, the diagnostics observer's body contains both `arm()` and `onAlwaysConfirmedChanged` (a confirmation must re-run the policy, not just set a flag); fixtures (7): passes; unconditional creation; Always branch no longer nils; WIU branch deleted; activity session gated on `.authorizedWhenInUse` alone (provisional falls through); invalidate without the `applicationState` guard; observer sets `alwaysConfirmed` without re-arming. Check 7 (`:260-266`) → add `IOS_SOURCE` to the Dart presence-only list. Check 9 (`:320-327`) → `locationStreamHandler.register(with: messenger)` + `onAuthorizationChanged` wiring AFTER `backgroundSessionHandler.register(with:` (line-order). Checks 11 + 12 (`:349-400`) → factored `check_bg_publish_drive <dart>`: check 11's banned list gains `iosLocationSourceProvider.override`, `NoopIosLocationSource`, `FakeIosLocationSource` (a faked native source reproduces the CI 32646436116 vacuity with the old check green); fixtures (2): passes; native provider overridden → fail. NEW check 14: pbxproj references the Swift file exactly 4× (valid because the new file's comments carry `.swift`; do not generalise to the BGTask precedent whose fileRef comment omits it — a file on disk but absent from the project compiles nowhere and fails silently as `MissingPluginException`, which the Dart source swallows as "no native handler"). `SELF_TEST_FIXTURES` pinned by equality at what lands (expected 47 = 8 route + 16 native + 7 tier + 2 drive + 9 region + 5 stream-provider from P1) at `:440`; header `:2-29` (incl. "the `-1` mapper trap is moot under the native owner") and the `OK:` line `:654` rewritten. `scripts/ci/check_m7_native_wake_guards.sh` → check 10 (factored in P2a): add `"$STREAM_HANDLER"` and `"$IOS_SOURCE"` to the list (the `SENS` scan catches `\(location`, `coordinate`, `latitude`, `\blat\b|\blon\b` in Swift and Dart — the sink map's `"lat"` dictionary KEY is not interpolation and does not false-positive; a `debugPrint('$fix')` in Dart would) + one planted-coordinate fixture per file; check 13 (`:1304-1311`, AppDelegate stored-property pin by NAME) gains `locationStreamHandler`. `check_no_key_logging.sh:705-707` scans Rust + all of `haven/lib` (no Swift list) — no change. `.github/workflows/repo-guards.yml:129-145` comment block → native-owner pins; steps `:691-701` unchanged.
- `docs/privacy/privacy_invariants.json` (host tests ONLY are cited — rule 4 rejects `haven/integration_test/**` citations that `markTestSkipped(`, which b7 does at `:265`; b7 stays a LANE oracle in §6.1): `INV-L-IOS-WAKES-RECEIVE-ONLY` → `assertion_arb_keys` become `[locationSettingsIosCatchUp, locationSettingsIosLimitedNote]` — the catch-up sentence MOVES verbatim out of `locationSettingsIosGuidance` into its own key (render order base → indicator → catch-up, UX N-2), which the ratchet reads as a dropped assertion key on the guidance key → `ratchet_override.items: ["INV-L-IOS-WAKES-RECEIVE-ONLY.assertion:locationSettingsIosGuidance"]` with a ≥ 40-char reason naming the verbatim move, deleted in the first commit after merge (P6 rule 2 — a key that merely moves is not a weakening, but the gate cannot see that by itself); add symbol `haven/ios/Runner/HavenLocationStreamHandler.swift::onListen` and tests `ios_location_source_test.dart → 'a background_start_refused error pushed through the sink surfaces as a stream error'`, `geolocator_location_service_test.dart → 'a backgrounded cold cache on iOS never starts the one-shot, even when the lifecycle hint says foreground'`, and the copy-tie `(c)` (the FIRST test that actually reads its two assertion keys — today's `background_claim_accuracy_test.dart` reads the plist + `LocationDisclosureStrings`, never the ARB keys, `:272-297`); statement gains "…and the native updates owner refuses a background-capable start from the background while the cold-cache shortcut reads the native lifecycle, so a relaunched process cannot resume publishing". NEW `INV-L-IOS-INDICATOR-HONEST` (enforced): "Under confirmed Always, `showsBackgroundLocationIndicator` is false and no `CLBackgroundActivitySession` is held (the OS arrow is the only signal); under When-In-Use, provisional Always and iOS 17 Always the activity session is held and the blue bar is shown; the settings copy selects its indicator sentence from the handler's own state." `assertion_arb_keys: [locationSettingsIosGuidance, locationSettingsIosIndicatorArrow, locationSettingsIosIndicatorBar, locationSettingsIosLimitedNote]`; `symbols`: `HavenBackgroundSessionHandler.swift::arm`, `HavenLocationStreamHandler.swift`; `tests`: `test/lints/ios_indicator_copy_accuracy_test.dart`, `test/l10n/location_settings_copy_accuracy_test.dart`, `test/pages/location_settings_page_test.dart → 'the indicator sentence follows the session handler state'`; `guards: [scripts/ci/check_ios_background_publish.sh]`. NEW `INV-L-IOS-PUBLISH-INPUT-BEST-PROFILE-ONLY` (enforced): "On iOS only fixes delivered under the Best profile (`desiredAccuracy == kCLLocationAccuracyBest` and computed after the switch) are cached as the publish input or returned as last-known; 100 m-tier fixes serve only the movement detector and the freshness bound; the native and Dart copies clear together; a re-sent stationary fix serialises to the same length as a fresh one at the same coordinate." Symbols `IosLocationSource`, `HavenLocationStreamHandler.swift::lastBestFix`; tests: the three only-Best tests + the two clear tests + Rust `resent_fix_payload_has_identical_shape`; guards: `check_ios_background_publish.sh`; no disclosure key (the Privacy page was removed 2026-08-29). The ONLY `ratchet_override` in P3 is the catch-up key move above (nothing weakened).
- Docs: `M7:816-845` §6 item 0 → split, never deleted, and **0a becomes a WP3-2 MERGE gate**, not an acceptance item: **0a (Always)** open Haven, fix on map, Home, ≥ 2 h stationary; EXPECTED: NO blue bar, status-bar arrow only; Settings › Privacy › Location Services › Haven shows the arrow; Settings › Battery lists Haven with "Background Activity"; peer keeps receiving on 72–168 s with no relay-side gap > 228 s for ≥ 2 h (the original wedge test); Console.app `locationd` shows the client's accuracy dropping to 100 (I: locationd logs `desiredAccuracy`) after ~2 min and the "Location subscription" RunningBoard assertion held (`:829-835` recipe); walk ≥ 150 m → peer sees the move within one interval and accuracy returns to Best; **0a-provisional row** (reset TCC, enable from Settings first so the grant is provisional): EXPECTED pill + continuity (the WIU posture) and, after answering the second prompt WHILE HAVEN IS BACKGROUNDED, publishing must not stop and the bar clears at the next foreground — V-P3-3/V-P3-4 are closed by this row. **0b (When-In-Use)** as today's item 0 (blue bar expected, mandatory). **0c (stuck indicator)** after 0a/0b toggle OFF and confirm the bar/arrow clears within a minute on iOS 18 and 26 (DTS 771422/783585); if it sticks, file Feedback and record; 0c cites the handler header sentence "arm() never withdraws a claim while backgrounded; disarm() always does". Toggle-OFF expectations (`:836-841`) with the stale "1 m distance filter" corrected (`:838-840`, `:1198-1199`, `CI_HARDENING_BACKLOG.md:2110`, `FA:58-62` — P0 did today's truth; P3 re-states for the native owner). `M7:69-73` honesty statement: the arrow + Settings attribution as the iOS visible signal under confirmed Always. FA Unit F (`:1059-1086`) amendment: "2026-08-29 (power plan P3): the iOS updates owner is `HavenLocationStreamHandler.swift`. The 16.4 shape is honoured in BOTH profiles — `allowsBackgroundLocationUpdates` on, `distanceFilter = kCLDistanceFilterNone`, `desiredAccuracy` ≤ 100 m (Best foregrounded/moving, HundredMeters backgrounded+stationary), `pausesLocationUpdatesAutomatically = false`. R2 (`:205-210`) re-argued against the DTS text: the indicator is offered as an ALTERNATIVE to that shape, not a requirement on top of it, so under CONFIRMED Always it is no longer part of the anti-suspension posture; under When-In-Use and until Always is confirmed it remains (mandatory). The `distanceFilter: -1` geolocator workaround is retired with the plugin path." FA `:218-222` → "relaunch cannot resume publishing: the native owner refuses a background-capable start and the cold-cache shortcut reads the native lifecycle." `MESH_LOCATION_RELAY_DESIGN.md:304` G-10 → "the map's own sharing control and the Android notification signal it; on iOS the status-bar arrow (no blue bar under confirmed Always)". `PrivacyInfo.xcprivacy` unchanged (PreciseLocation still true — only Best-profile fixes are published).

**Tests FIRST** (host Dart, red before code).
- NEW `haven/test/services/ios_location_source_test.dart` — controller half (pure, fixed `DateTime`s, no `fake_async`): `foreground always yields Best`; `backgrounded: no ≥100 m displacement for kStationaryDwell drops to HundredMeters; a ≥100 m step within the dwell restarts it`; `stationary: a ≤100 m-accuracy fix ≥100 m away switches to Best; one inside 100 m only confirms`; `a fix coarser than kStationaryConfirmMaxAccuracyMeters neither confirms nor moves`; `a confirmed anchor is never more than kMotionTriggerDistanceMeters + kStationaryConfirmMaxAccuracyMeters from any confirming fix` (the 200 m bound); `no confirmation for kStationaryConfirmMaxAge escalates to Best and restarts the dwell` (`nextDeadline`/`onDeadline`); `resume from stationary returns Best immediately (property write, no restart)`; `the anchor is only ever a Best fix`; `a Best-profile fix stamped before the switch to Best is not cached` (the `bestSince` rule, mirrored in Dart). Channel half (mocks, pattern `ios_background_session_service_test.dart:32-100`): `positions passes allowsBackgroundLocationUpdates as the listen argument`; `a background_start_refused error pushed through the sink surfaces as a stream error` (the fake native emits through the EVENT SINK, never a `listen` failure — §2.1); `status parses the native map and fails closed on a missing or wrong-typed key (backgrounded defaults to true)`; `lastBestFix null-safe`; `clearLastBestFix invokes the channel`; `Noop never emits on non-iOS`.
- `geolocator_location_service_test.dart`: `iOS routes the stream to the native source with allowsBackgroundLocationUpdates == the toggle, and never calls getPositionStream` (both toggle values; `verifyNever`); `a HundredMeters fix is never emitted and never replaces the cached Best fix`; `a confirming fix refreshes the freshness bound: the cached Best fix is served past its own age`; `with no confirmation the cached Best fix ages out at kStreamPositionMaxAge`; `backgrounded iOS with a cold cache reads the native lastBestFix, never the plugin last-known, never the one-shot`; `a backgrounded cold cache on iOS never starts the one-shot, even when the lifecycle hint says foreground` (fake `status()` reporting `backgrounded: true`; `verifyNever(getCurrentPosition)`); `clearCachedPosition clears the native last-Best fix`; `a toggle-off pause leaves no native last-Best fix` (with the P1 gate); `a native background_start_refused error clears the cache and reaches subscribers` (existing semantics `:1953-1973`); `stream cancel resets the profile controller and cancels the confirm timer`; `setProfile is invoked exactly once per transition`; `a lost access clears the confirmed age with the cache`; Android arm: `getPositionStream` called once with unchanged settings (`distanceFilter 1`, `intervalDuration 1 s`, `forceLocationManager`, `accuracy best`).
- `location_provider_test.dart` → `:134,:146,:157` rewritten against a `FakeIosLocationSource` (captured `allowsBackgroundLocationUpdates`); `:182` cache-clear kept; `:141-143,:153-154` (flags in a settings object) → "the provider passes the toggle to the platform router" + the P1 lifecycle cases.
- `test/constants/location_test.dart` → `kStationaryDwell == kLocationUpdateInterval`; `kStationaryConfirmMaxAge < kStreamPositionMaxAge && == 84 s`; `kStationaryConfirmMaxAccuracyMeters == kMotionTriggerDistanceMeters`; `kStationaryConfirmMaxAge + kStationaryDwell` ordering sanity (escalation lands a Best fix inside the cache bound).
- NEW `haven/test/lints/ios_indicator_copy_accuracy_test.dart` (pattern `background_claim_accuracy_test.dart`): reads `app_en.arb` + the Swift file — the BASE key must not contain "blue", the PHRASE "blue location bar", "indicator" or "arrow" while the Swift policy line is `= !` + `alwaysConfirmed` (bare "bar" is NOT forbidden anywhere — the arrow key legitimately says "status bar"); the arrow key must contain "arrow" and "status bar" and neither "blue" nor "blue location bar"; the bar key and the limited note must contain "blue location bar"; the catch-up key must equal the sentence removed from the old guidance value; no key contains "low-power"/"low power" (a battery promise) or "pause"/"paused"/"timer"; anti-vacuity (all strings and the Swift line found). NEW `haven/test/l10n/location_settings_copy_accuracy_test.dart` (13 locales; pattern `repair_copy_accuracy_test.dart`; per-locale vocabulary = the "blue" WORD, the "blue location bar" PHRASE as translated, the "arrow" term, the "status bar" term): (a) the base key contains none of the locale's "blue" word, "blue location bar" phrase, "indicator" or "arrow" terms; (b) the arrow key contains the locale's "arrow" term and none of its "blue" word / "blue location bar" phrase — its "status bar" term (de "Statusleiste", ar "شريط الحالة") is allowed and required; the bar key and the limited note contain the locale's "blue location bar" phrase; (c) the CATCH-UP key and the limited note contain the locale's "Always" term and a "closes/ends the app" phrase (mirrors `background_claim_accuracy_test`; this clause IS the pin of the moved catch-up sentence — no gate pins its bytes) and the catch-up value is byte-identical to the sentence removed from that locale's guidance value; (d) every supported locale has a vocabulary entry AND its forbidden list contains the OLD sentence's words (e.g. `app_de.arb:111` "durchgehende"/"blaue", `app_ar.arb:111` "متواصلة"/"أزرق") so an untouched translation under a re-worded key is caught; (e) the scanner catches a planted violation in both directions — the planted phrase is "blue location bar", the passing fixture contains "status bar".
- NEW `haven/test/pages/location_settings_page_test.dart` → `the guidance card renders only under Always; nothing under denied/notDetermined/restricted/unknown; the limited note under whenInUse`; `the card renders base, then the indicator sentence, then the catch-up sentence` (semantics traversal order); `the indicator sentence follows the session handler state` (fake session service held → bar sentence, not held → arrow sentence); `the permission and indicator providers are invalidated on resume` (fake auth service flipping tier across a simulated `AppLifecycleState.resumed`).
- NEW `haven/test/lints/ios_stream_handler_registration_test.dart` (or guard check 14) → pbxproj references the Swift file 4×.
- Rust: `resent_fix_payload_has_identical_shape` (serialized LENGTH equal for a re-sent vs fresh fix at the same coordinate; `raw_accuracy` still `#[serde(skip)]`; the residual recorded in the test doc).
- `background_location_provider_test.dart:1333-1385` (`stateAtArmTime` ordering) → keep; ADD tier cases (fake handler reports tier + `alwaysConfirmed`): confirmed Always → `backgroundActivitySessionHeld == false && serviceSessionHeld == true`; WIU → the inverse; Always with `alwaysConfirmed: false` (provisional / iOS 17) → `held == true`; `a delayed confirmation releases the activity session and re-applies the indicator` (fake handler reports `alwaysConfirmed: false` at `arm()`, then flips it and fires `onAlwaysConfirmedChanged` — `held` becomes false and the indicator policy is re-applied without a foreground transition).
- Guard mutations: `bash scripts/ci/check_ios_background_publish.sh --self-test` → 43 (pinned by equality at what lands); each fixture written before its grep; `check_m7_native_wake_guards.sh --self-test` log-fixture count bumped by exactly the two planted files.
- Existing red → replacement (never loosened): `geolocator_location_service_test.dart:894-963` (iOS `AppleSettings` shape incl. `:919 showBackgroundLocationIndicator isTrue`, `:917 distanceFilter -1`, `:958`) → retired WITH the branch; replaced by the iOS-route tests (R8 moves from "flags in a settings object" to "the listen argument == toggle" — same promise, new carrier) + the Swift guard; the P0 five-way accuracy test drops its two iOS-stream arms and keeps the Android arm + both one-shots; Android test `:965-975` stays. Cache family (`:1040-1057,:1065-1076,:1996-2014,:2153-2176,:1963-1971`) unchanged in substance + one case "a HundredMeters-profile fix is NOT cached as publishable". "Doomed one-shot" (`:1134-1153, :2017-2035`; backgrounded iOS cold cache → plugin last-known) → same promise ("never the one-shot"), fallback now `iosStream.lastBestFix()`. `location_provider_test.dart:142` (`showBackgroundLocationIndicator`) → dropped WITH its carrier; the policy is asserted natively (lane P1) + copy-tie + guard. `location_access_provider_test.dart:424` reason → iOS half reworded ("the native session delivers whatever CoreLocation computes; silence is still not evidence"); assertion unchanged. `map_shell_test.dart`, `ios_background_session_service_test.dart` unchanged. `ios_bg_publish_test.dart` P1 `:751-760` (`backgroundActivitySessionHeld isTrue`) → the WIU run PINS the tier it observed right after the enable: `expect(tier, IosAuthStatus.whenInUse, reason: 'this run proves the WIU branch; a provisional Always here means the sim escalated and the lane is no longer measuring what its header says')` (`:762-765` today accepts either value — under the new policy a silent branch swap would run the Always shape non-deterministically and red P2b "honestly" on some runs; a tier flip is now a red, attributable run); then `expect(held, isTrue)`; NEW after the fresh-fix wait `:790-806`: `streamStatus = await iosSource.status()` → `running`, `allowsBackgroundLocationUpdates == true`, `showsBackgroundLocationIndicator == true`, `profile == best`, `backgrounded == false` (the WIU run is otherwise UNCHANGED — verification G6). P2b `:961-1000`: NEW profile oracle read from the backgrounded process before the count is asserted, as a BOUNDED POLL on the existing heartbeat pattern (a single read is a coin flip if V-P3-1 fails — the confirm deadline escalates every 84 s): "`hundredMeters` observed at least once after ≥ `kStationaryDwell` of backgrounding, within `kStationaryDwell + kStationaryConfirmMaxAge`", printed with the poll count (proves the profile ENGAGES in the background and that publishing continued under it); on re-foreground (`finally`) no pump-dependent assertion. P3 `:1160-1185` unchanged. **Always run (OD-P3-c, recommended):** a second matrix job under `location-always` asserting `held == false && serviceSessionHeld == true && alwaysConfirmed == true` plus P2a/P2b under that shape (the keep-alive proof for the shape whose physical neighbour failed; NOT a pill oracle — a simulator cannot show it), marker `[bg-publish] ALWAYS_SESSION_OK`; shell fixtures C2–C5 extended; `check_live_sync_define_declared.sh` for the new matrix job; if the simulator suspends under that shape the lane says so before a physical phone does. `b7_ios_auth_tier_test.dart:386-390` reason 'a continuous session with the blue indicator' → 'a location session that drops to a coarser tier while still, with the OS arrow and no blue bar once Always is confirmed, plus catch-up after iOS closes the app'; NEW in both runs (session status is independent of the faked location service — `_seedPublishPrefs` `:427` makes `_load()` arm, `background_location_provider.dart:163-165`): `expect((await sessionService.status()).backgroundActivitySessionHeld, tier == IosAuthStatus.whenInUse)` and, under `location-always` (a FULL grant), `alwaysConfirmed == true` asserted through a BOUNDED status poll (the diagnostic lands asynchronously after `arm()` returns — a single read right after `arm()` is a race) — the one CI observation of the diagnostics path (the lane already runs under `location-always`, `run-b7-ios-auth-tier.sh:10`). `e2e-ios-real-gps` (b4): unchanged (one-shot stays geolocator; `getCurrentLocationFresh` tolerance 1e-5° unchanged). Guard checks 11/12 keep their meaning (production location service AND production native source; fresh fix from the REBUILT stream before READY — the native stream must still surface a fresh timestamp on `locationStreamProvider`; the pump is still required, `markNeedsBuild` deferral is Riverpod's).

**Implementer work packets.**
| # | Packet | Sequencing | Done when |
|---|---|---|---|
| WP3-0 | Tests (red): all host tests above + guard fixtures against hand-written Swift/Dart snippets | first | `cd haven && flutter test test/services test/providers test/constants test/lints test/pages` red on the new files; `check_ios_background_publish.sh --self-test` expected 47, red until the greps exist |
| WP3-1 | Dart: `ios_location_source.dart` (channel + pure controller + timer), `geo_distance.dart`, constants, service integration (route, backgrounded shortcut, native clear), `service_providers.dart`, settings-page gating + indicator-sentence provider | ∥ WP3-2 (WP3-1's fake-channel tests define the wire shape both implement) | `flutter test test/services/geolocator_location_service_test.dart test/services/ios_location_source_test.dart test/providers/location_provider_test.dart test/constants/location_test.dart test/pages/location_settings_page_test.dart && flutter analyze && bash scripts/ci/check_location_access_gate.sh` |
| WP3-2 | Swift: stream handler (sink errors, `bestSince`, `onCancel` clear, `clearLastBestFix`, `backgrounded` status), pbxproj (4 lines), `AppDelegate.swift` (wiring order), session handler `alwaysConfirmed` + tier branch + background guard + diagnostics observer | ∥ WP3-1 | `cd haven && flutter build ios --debug --no-codesign` (macOS) compiles and `build-check.yml`'s iOS job is green on the branch; `ios_bg_publish_test.dart` P1 passes on a booted sim with `simctl privacy grant location` (and under `location-always`: `held == false`, `serviceSessionHeld == true`, `alwaysConfirmed == true`); **MERGE GATE: hardware M7 §6 0a (≥ 2 h stationary under Always, accuracy 100 observed in Console, RunningBoard assertion held, no relay-side gap > 228 s) and the 0a-provisional row recorded in `POWER_MEASUREMENT.md`** — the shape shipped under Always has no other runtime evidence and its closest physical neighbour failed on 2026-08-20 |
| WP3-3 | Guards: checks 2/3/4/7/8/9/11/12/14 rewrite, self-test 43, m7 check-10 list + check-13 name, repo-guards comment | after WP3-1+2 | `bash scripts/ci/check_ios_background_publish.sh && … --self-test && bash scripts/ci/check_m7_native_wake_guards.sh && … --self-test` |
| WP3-4 | Copy + l10n: ARB en (base + arrow + bar + limited note) + `@description`s, 12 translators, 12 reviewers with the gating facts and reasoning check, parity, gen-l10n, both copy-tie tests (old-sentence forbidden lists), b7 reason text, non-ARB comments | ∥ WP3-3 | `dart run scripts/ci/arb_parity_check.dart haven/lib/l10n`; `flutter gen-l10n` warning-free; copy-tie tests green |
| WP3-5 | Lanes: bg-publish P1 tier pin + status oracle + P2b bounded profile poll + `_failIfSuspended` text; the Always matrix job (OD-P3-c); b7 session + `alwaysConfirmed` oracles; runner comments; `check_e2e_step_timeout_ordering.sh` derivation for the new job | after WP3-2 | `bash tooling/e2e/ci/run-ios-bg-publish.sh --self-test`; `bash tooling/e2e/ci/run-b7-ios-auth-tier.sh --self-test`; all lanes green on the branch |
| WP3-6 | Docs + manifest: M7 §6 0a (merge gate) / 0a-provisional / 0b / 0c + history, FA amendment, stale 1 m sentences, MESH G-10, `CLAUDE.md:258`, `privacy_invariants.json` (host tests only) | last | `check_privacy_invariants.sh --baseline-ref origin/main`; `--static-only`; floor `geolocator_location_service.dart|85` (measured 87.86 %, 123/140): the iOS branch shrinks → denominator drops → likely RATCHET; `ios_location_source.dart` gets a `--list`-derived row; re-pin from the P3 CI run; Swift is outside lcov |
| — | then full `flutter test`, `cargo test` (unchanged Rust — run anyway), reviewer wave | | |

**Reviewer checklist.** Only-Best: find any path that puts a `hundredMeters` fix — or a Best-profile fix stamped before `bestSince` — into `_lastStreamPosition`, the emitted stream, `lastBestFix`, or the motion trigger (try the first-fix-after-switch race and `lastBestFix` under a profile flip mid-`didUpdateLocations`). Rule 10: find a native `lastBestFix` that survives `onCancel`, a toggle-off pause or logout. Freshness: with the confirm deadline removed, does a stationary user ever publish a coordinate older than 168 s + one delivery? With it, does escalation restart the dwell (no Best/100 m flapping every 84 s in good signal — a confirming fix re-arms it)? Is the 200 m undetected-move bound stated where OD-P3-d is decided? R7: grep for any `startUpdatingLocation()` reachable with `allowsBackgroundLocationUpdates == true` while `applicationState == .background` (incl. the SLC-relaunch and the R1 edge), AND any `getCurrentPosition` reachable from a background-launched process (the `backgrounded` read must be fail-closed); the P1 provider must not `watch` the foreground provider in the running build. Errors: comment the `events(FlutterError(` out and return it instead — the sink test must go red (a returned `FlutterError` is reported, never streamed). Wedge regressions vs FA: both profiles keep `kCLDistanceFilterNone` + ≤ 100 m + `allowsBackgroundLocationUpdates` (16.4 shape); no `pausesLocationUpdatesAutomatically = true` anywhere; Unit C's health tick untouched; Rule 14 untouched. Indicator honesty: under WIU the activity session is created and the flag `true`; under CONFIRMED Always neither; under provisional Always / iOS 17 the WIU posture (gate the activity session on `.authorizedWhenInUse` alone — the tier fixture must fail); a WIU→Always upgrade delivered while backgrounded must NOT invalidate the activity session (the `applicationState` fixture must fail); runtime downgrade with the app backgrounded → next foreground re-arms. Privacy metadata: the switch touches no socket; publish instants unchanged; `raw_accuracy` still skipped; a re-send serialises to the same length; no coordinate reaches a log in Swift or Dart. Copy: every sentence of the four keys against the Swift policy and the settings-page gating (`location_settings_page.dart:158-160,213,298-310`): the base key names no indicator; the arrow/bar sentence is chosen by handler state, never by tier; nothing renders under denied/notDetermined; no "low-power" battery promise, no "›", one noun ("blue location bar"), tier-neutral Settings wording (iOS 15 has no "Privacy & Security" menu); the OD1-declined variant exists; the catch-up sentence is unchanged and pinned by clause (c). A11y: the Always card is read by VoiceOver in one paragraph — short sentences, "→" (read aloud) not "›"; the pre-existing gap (no `Semantics` hint on the toggle) is unchanged and noted for ui-ux-reviewer. Test reliability: no real timers in controller tests; the P2b oracle is a bounded poll on the heartbeat pattern, never a single read or a sleep. Guard rot: try each fixture's mutation on the real files; comment the Swift policy line out (anti-vacuity); override `iosLocationSourceProvider` in the drive — check 11 must fail.

**Risks / rollback.** Simulator drip under `HundredMeters` (V-P3-1): if `simctl location set` is not delivered at the 100 m tier, the P2b confirm deadline escalates to Best every 84 s and the bounded poll still observes `hundredMeters` at least once; if the sim never delivers under 100 m at all, the profile oracle moves to a unit-level proof and the lane keeps P1/P2a/P2b/P3 (never a widened window) — a documented downgrade of a runtime oracle, recorded in the lane header if taken. Provisional Always (V-P3-3): the fail-safe policy keeps that cohort on the WIU posture, so keep-alive cannot regress there; the residual is a pill until the second prompt (OD1/OD-P3-b). "Hours stationary at 100 m / no filter keeps the process alive" is I until hardware 0a passes — hence the merge gate. Stuck indicator on disarm: cosmetic, reported; §6 0c. Poor-signal indoor steady state: the controller spends up to ≈ 59 % of the time at Best (escalation every 84 s) — no worse than today; measured via the profile-duty column. pbxproj by hand: verified by every iOS build; check 14 pins the four references. Rollback in ONE commit: revert `getLocationStream`'s iOS branch to the geolocator arm (restoring `_streamSettings` iOS arm + `_kIosNoDistanceFilter`), the backgrounded shortcut, the native clear and the session handler's tier branch; the Swift file may stay compiled and unused (nothing subscribes) BUT the manifest symbol/test additions to `INV-L-IOS-WAKES-RECEIVE-ONLY` and the m7 check-10/13 list entries revert with the Dart tests (rule 3 is red if a cited test is deleted while the symbol stays); guards/tests/ARB ×13 (five keys)/copy-tie tests (with their two invariants → override items)/settings-page gating revert with it; b7/bg lanes back to one run. The session handler's arm/disarm contract is untouched by the revert; the WIU pill is honest in both states.

**Acceptance.** CI: all tests above green; `check_ios_background_publish.sh` + `--self-test` (47); `check_m7_native_wake_guards.sh` with the two new files scanned and the log-fixture count pinned; `check_location_access_gate.sh`; `check_privacy_invariants.sh` with no override and no integration-test citation; `l10n-check.yml` (13 locales); `e2e-ios-background-publish` green with the tier-pinned P1, the P2b bounded profile poll (`hundredMeters` observed from the backgrounded process) and ≥ 2 events/396 s, plus the Always job (OD-P3-c); b7 both tiers green with the session-held oracle inverted per tier and `alwaysConfirmed` true under the full grant; `build-check` iOS green; `e2e-ios` / `e2e-ios-real-gps` green. Hardware (owner, M7 §6 0a is a WP3-2 MERGE gate; 0b/0c acceptance): under confirmed Always no blue bar for ≥ 10 min backgrounded stationary; publishes on cadence with no relay-side gap > 228 s for ≥ 2 h; accuracy observed dropping to 100 m within ~2 min and returning to Best on a ≥ 150 m walk; the provisional row passes; Settings › Battery over ≥ 3 h on the same phone: background sharing ≤ ~1 %/h stationary (reachable with P1+P4; I: 1.5–2.5 %/h after P3 alone — §6.6 relative thresholds apply); under WIU the bar is visible and publishing continues; toggle OFF clears the bar within a minute on iOS 18 and 26.

**Owner decisions / open questions.** OD1, OD-P3-a/b/c/d. V-P3-1 (sim delivers under `HundredMeters`; I: yes, the sim ignores the tier); V-P3-2 (live `desiredAccuracy` change on a running backgrounded session honoured without restart — V for the API, I for the background effect; 0a decides); V-P3-3 (the CONFIRMED-Always shape — no activity session, flag false — keeps a foreground-started session delivering for hours on iOS 17/18/26 — physical device, 0a MERGE gate; the provisional cohort no longer depends on it); V-P3-4 (`CLServiceSessionDiagnostic` values under provisional Always — the 0a-provisional row; b7's full grant observes the confirmed case); V-P3-5 (stuck-indicator reproduction after `disarm()`); I-P3-1 (delivery rate at 100 m/no filter on a stationary device — drives how often the 84 s escalation fires; the profile-duty column); U: all energy figures — hardware only.

### 5.4 Phase P4 — iOS background burst receive + maintenance fold + bounded inbox lookback (D6) [OD4]

**Goal / non-goals.** While backgrounded on iOS with sharing ON the engine holds NO standing REQ and NO socket
between publish ticks; each tick is one bounded burst in the main isolate (the `AccountDeviceSession` holder,
Rule 14): open → ingest backlog → publish at the current epoch → fold due maintenance → settle → close. Battery:
≈ 150 → ≈ 30 radio wakes/h for a 1-circle user on cellular (research §3.2), ≈ 3.1 %/h → ≈ 0.65 %/h on the
LTE-2012 model; the engine's 55 s pinger, the 15-min health re-anchor and the 7-day inbox replays leave the
background. Non-goals: the foreground (persistent engine unchanged); Android (the FGS already has no engine); per-circle
coalescing (P5); the location owner (P3); any wire change.

**Design.**
- **Engine state machine (`LiveSyncCore`):** `Stopped` → `Live` (today) → **`Paused`** (new) → `Live` (burst open) →
  `Paused` … → `Stopped`. One core per session; salt, supervisor tasks, router object and anchors persist across pauses
  (the repair queue is drained at pause — D6 (ii)). `pause_subscriptions()` = D6 (i), under the lifecycle lock for the whole
  call: `unsubscribe_all` (bounded) + the post-condition sweep (`client.subscriptions()` empty, per-id `unsubscribe`
  for leftovers; sockets stay open) → `RawSignal::Pause` marker `send().await` + ack, both under
  `RELAY_LIFECYCLE_OP_TIMEOUT`, short-circuit on `wedged`, direct router-clear + `note_delivery_gap()` fallback (the
  worker drains everything ahead of the marker — inline auto-commits and their OKs included — then clears the router
  + `note_delivery_gap()` and acks) → await `in_flight_publishes == 0` → `client.disconnect()` (radio off;
  `Terminated`, never `shutdown`) → `repair.clear()`.
  What the guard pins: no `forget_*` in the pause path; `disconnect`, never `shutdown`; no standing-REQ call reachable
  from the burst entry point — not a call order. Status: ONE `SyncStatusReason::Paused`; `run_monitor`'s per-relay
  `Disconnected` suppressed while paused (F31). Burst open = `resume_after_background` (F11) + (i) clears `paused`
  before `connect()` under the lock; (ii) `client.add_relay` over the relay UNION of `active` (a circle subscribed while
  paused would otherwise be issued to a relay the pool does not hold and fail the whole open — F32); (iii) a second
  bounded `unsubscribe_all` if the pool view is non-empty (a partial pause sweep would otherwise let the crate's
  `resubscribe()` re-send an OLD REQ ahead of the session's — F27); (iv) `register_and_subscribe(.., Resubscribe)`
  yields the bounded inbox lookback (P4-1, landed in P1) — the inbox REQ on every k-th burst only, if OD4-b is taken.
  `connect()` from `Terminated` spawns fresh connection tasks (F5); `wait_for_connection(5 s)`; every REQ re-issued
  under its frozen sub-id at its persisted cursor; generations re-open at the burst's `now` carrying any hold-back
  (F13). `wait_backlog_settled(timeout) -> BacklogOutcome { Settled, TimedOut }`: waits until every expected
  `(relay, sub)` ENDPOINT THIS burst issued AND whose REQ `subscribe_bucket` accepted (it returns the accepted relay set; a burst without an inbox REQ expects no inbox endpoint; the set `probe_subscriptions`/`open_delivery_windows` track,
  `session.rs:430-436`) has EOSE'd or CLOSED, behind a `tokio::sync::Notify` the worker fires per endpoint (no polling)
  — per endpoint, not per circle, because `note_eose(group_hex)` consumes the circle's single generation on the FIRST
  relay's EOSE while a slower relay may still be replaying the peer's commit (F30). Because the worker is serial (F14),
  a consumed endpoint means every stored event that relay sent before its EOSE was ingested, `resolve_publish_work`
  ran (`processor.rs:465-470`) and `drain_convergence` re-ticked (`:529-556`); after `note_delivery_gap` the anchor's
  `eose_consumed` means "advance burned", so a Rule-12 intake drop mid-burst reads as `Settled` — accepted (publish
  anyway, as today's foreground), documented on the flag. `BURST_BACKLOG_WAIT_SECS = 5` (≥ `SUBSCRIBE_CONNECT_WAIT`, ≪
  the 10 s send window; a relay that never EOSEs makes the burst publish anyway — as today's foreground); `TimedOut`
  reported to Dart (health counter, presence-only). `settle_before_pause(timeout)` = D6 (v): FIRST awaits the in-flight
  publish gauge (`EngineProcessor.in_flight_publishes`, incremented before the publisher call in `resolve_publish_work`,
  decremented in a drop guard) to reach zero with NO cap (bounded by the crate's 10 s per-relay OK wait), THEN keeps
  sockets open until `COMMIT_SETTLE_WINDOW_SECS` (8 s) after the LAST commit activity (`route_events` `GroupUpdate` or
  `resolve_publish_work` `AutoPublish` — there is no `EpochChanged` variant), the `BURST_SETTLE_CAP_SECS = 18` cap
  bounding FOLLOW-ON activity only (a commit landing at t≈10 s still gets its 8 s window; a commit whose OK is in flight
  is never cut — Rule 13); a quiet burst pays zero; internal `settle_before_pause_with(window, cap, clock)` so the window
  logic is unit-tested on a virtual clock. `paused` gates = D6 (ii): `run_repair` returns BEFORE `take_due` (an early
  return inside `reissue` would consume the pending re-issue, F28; a belt-and-braces `paused` check stays in `reissue`);
  `maintain_subscription_health` short-circuits before `health_probe` → `HealthAction::Paused`; `subscribe_circle`
  while paused = WSS gate → cold-start cursor seed → sub-id → `active` push (no router entry, no REQ, no `add_relay`);
  `unsubscribe_circle` while paused = `active` removal + `forget_subscription(hex)`. `stop` from `Paused`: unchanged
  (`stop_inner` idempotent over a closed pool). After a pause the only Rust tasks alive are the four supervisor tasks
  parked on channels; the crate's per-relay connection task (and its pinger) exits on `Terminated` (`inner.rs:566`) — no
  timer wake remains in Rust.
- **Burst sequence (Dart, main isolate, iOS-bg only)** — `BackgroundBurstCoordinator` (new, FFI-free core + thin runner;
  injectable clock/engine/relay/maintenance/publisher; no `Timer` of its own — ticks come from the schedulers) serialises
  bursts on one chain (a second tick during a burst joins it: its circle is published in the running burst if not yet
  encrypted, else deferred): 1. `engine.resumeAfterBackground()` (≤ 5 s connect wait). 2. `engine.waitBacklogSettled()`
  (≤ 5 s) — a received commit is applied so the encrypt runs at the current epoch; a `SelfRemove` auto-commit staged here
  is published over the ENGINE sockets and confirmed only on a ≥ 1-relay OK inside `resolve_publish_work` (F9, Rule 13) —
  inside this burst, on warm sockets. 3. `getCurrentLocation()` once (access gate first) → per due circle `publishLocation`
  (encrypt → `publishLocationEvent`, D5's 15 s worst case) with the P5 stagger; a `LocationPublishDeferred` outcome surfaces
  staged commits exactly as today (`_handleDeferredSend` → `publishEvent` ladder, `confirm_published` on ack) — still inside
  the burst. 4. `if (keyPackageDue) maintainKeyPackage(); if (relayListDue) maintainRelayList();` on the warm publish pool
  (F19) — direct method calls, never provider invalidations; the health tick is NOT folded. 5. `engine.settleBeforePause()`
  (0 s quiet; ≤ 18 + 10 s if a commit moved) → `engine.pauseSubscriptions()` → `relay.shutdown()` on the publish pool
  (F8 `disconnect`; with D5 the sockets would sleep within ≤ 70 s, but an explicit close ends the radio tail at once — a
  burst costs `0.3 J + (T_burst + 11.6 s) × 1.06 W`, `T_burst` typically 2–4 s → ≈ 15 J, worst ≈ 23 J at the 10 s send
  bound, commit-settle worst ≈ 40 J; research §4). Steps 5's pause runs in a `finally` — on a throw AND on cooperative
  cancellation (the chain re-checks `bgEnabled` between links; a C4 cancel in the last seconds before suspension must
  still pause). NO `.timeout(` wraps commit-critical work (`_handleDeferredSend`, `confirmPublished`, and the
  `pauseSubscriptions()` link — its marker drain is bounded by backlog size, not by a clock; the FGS's unbounded
  commit-critical drain is the model); the C6 `.timeout(` check 8 resolves sits on `_dispatchTick`
  (`_onCircleTick` → `_dispatchTick` → `sink?.onTick(...) ?? _pacedPublish(...)`) as a WATCHDOG only — Dart
  `Future.timeout` does not cancel the underlying future, the chain ignores it and it merely reports — with
  `BURST_BOUND` (≤ 5 s connect + 5 s backlog + N × 10 s publish + 28 s settle, pause link excluded) pinned
  `< _publishLinkTimeout` (3 min, `:157`) so a healthy burst is never reported late for N ≤ 12. The coordinator and everything it calls while paused use `ref.read` / direct calls /
  `listenManual` only — no `ref.watch` in `background_burst_coordinator.dart` (lint test; §2.2a). Foreground resume:
  `_onResumed` calls `resumeAfterBackground()` behind the 60 s throttle (F18) — bypassed when the engine is `Paused` (a
  paused engine has NO REQ, so "re-queries a window the last one covered" does not apply). Pause: the iOS+bg-ON branch
  (`map_shell.dart:1335-1363`) installs the coordinator, runs an IMMEDIATE first burst if the last publish is older than
  `kLocationPublishOverlapGuard` (else schedules as today), after which the engine is `Paused`. The `_bgSharingPausedSub`
  C4 edge (toggle OFF mid-pause) REQUESTS cooperative cancellation when a burst is running (the current
  commit-critical link confirms or rolls back, then the `finally` pauses and shuts the pool) and, with no burst
  running, calls `pauseSubscriptions()` + `relay.shutdown()` directly — either way opt-out leaves NO socket. Status while paused: `SyncConnectionPhase.paused` (no fault; `_disconnectedSince` cleared; the per-relay
  `Reconnecting`/`Connected` churn on each burst is harmless and documented).
- **Bounded inbox lookback** = D6 (iv), landed in P1 (P1-N0); P4 relies on it and adds OD4-b's k-th-burst inbox fold.
- **Marmot safety across socket close/open:** the `AccountDeviceSession` never closes; epoch state, sender ratchet and
  exporter secrets are untouched by socket lifecycle (sockets in the nostr `Client`, MLS state in `SessionManager`,
  `MARMOT_PROTOCOL_KNOWLEDGE.md:687-716`); no second session (Rule 14, `check_mls_session_single_owner.sh`); every burst
  sends at the ratchet's next generation; `DEFAULT_MAX_PAST_EPOCHS = 5` is consumed only on real offline gaps and the
  ≤ 168 s inter-burst gap is far inside it (Rule 5). A commit received in a burst is applied before encrypt; if the wait
  times out (or a slow relay's replay lands after the fast relay's EOSE — now bounded per endpoint) the encrypt may run one
  epoch behind — peers DECRYPT it from past-epoch keys (`wire_format.rs:52-57`; `Buffered` is the FUTURE-epoch verdict) and
  convergence resolves it on the next burst — never a nonce reuse (Rule 11 gate is socket-independent). A commit Haven
  must publish is acked inside the burst or rolled back (`publish_then_resolve`; `settle_before_pause` holds the socket
  until the in-flight gauge is zero; `publish_failed` restores `Stable`) — the pause can never cut a commit between SEND
  and OK; `PendingCommitRecovered` (crash mid-burst) → the next burst's full re-REQ IS the mandatory resync. Rule 12:
  intake unchanged (`WORKER_QUEUE_CAP` + hold-back); local processing outlasts the SOCKET but not the pause — the `Pause`
  marker guarantees everything downloaded is processed before the router clears (CPU, not radio). R14: no standing REQ
  ⇒ nothing to heal; a `CLOSED` inside a burst is repaired inside it or by the next; the C3 blackout class cannot persist
  longer than one publish interval in the background.
- **Privacy metadata statement** (for SECURITY.md / M11 §6.1): while backgrounded on iOS with sharing on,
  Haven connects only at the instants it publishes its own location (every 72–168 s) — instants CIRCLE relays already
  learn from the kind-445 — and disconnects within seconds (worst ≈ 33 s with a commit settle); no continuous online
  signal, no standing subscription. Each burst's REQ carries `since` ≈ the previous burst time, which the relay served and
  already knows. The burst opens the engine socket and the publish socket from the same address in the same seconds — the
  same two-socket linkability as today's foreground, not a new one (the two-socket fact of §1.2, recorded in the RC1
  summary). **New inference, named:** an INBOX-ONLY relay (kind 10050 set, independent of
  the circle sets, `SECURITY.md:864-866`) learns nothing from a kind-445 it never carries; today it sees one continuous
  socket, after P4 it sees a REQ/CLOSE pair every 72–168 s ± 40 % = "this pubkey is background-sharing now" — OD4-b (inbox
  REQ on every k-th burst, ≥ 10 min) removes the cadence signal at ≤ 10 min invitation latency; without it the inference
  is disclosed in SECURITY.md and the RC1 summary. "Updates arrive in seconds" is a FOREGROUND property; in the background
  peers' positions are picked up at each own publish instant (worst case one peer interval + one own interval + burst ≈
  346 s < `kReceiveSilenceThreshold` 564 s, F22, so the health model's receive verdict stays consistent on resume).

**Exact change list.**
- `haven-core/src/relay/live_sync/config.rs` → `BURST_BACKLOG_WAIT_SECS = 5`, `BURST_SETTLE_CAP_SECS = 18` (+ `const _: () = assert!(BURST_SETTLE_CAP_SECS >= COMMIT_SETTLE_WINDOW_SECS + 10)`; doc: the cap bounds idle follow-on activity, never an in-flight publish), `INBOX_BURSTS_PER_REQ` (k = 1 today; OD4-b sets k so that k × `kLocationUpdateInterval` ≥ 10 min — the invariant statement names the constant, never a value, so it stays true whichever way OD4-b goes).
- (`cursor.rs` bounded lookback: landed in P1-N0.)
- `haven-core/src/relay/live_sync/anchor.rs` → `CursorAnchors::all_consumed()`, `InboxAnchor::is_consumed()` (presence-only; doc: after `note_delivery_gap` "consumed" means "advance burned"). `supervisor.rs` → `RawSignal::Pause { ack: oneshot::Sender }` marker handling (drain-then-clear + `note_delivery_gap()` + ack), the intake `Sender` cloned onto the core (today it lives only in `run_receiver`, `:230-231`), `subscribe_bucket` returning the ACCEPTED relay set, per-endpoint `eose_seen: HashSet<RepairKey>` in the delivery tracker (the worker already has the key, `:585-600`) firing `eose_notify`. `processor.rs` → `eose_notify: Notify`; `pub async fn wait_backlog_settled(&self, expected_endpoints: &[(RelayUrl, SubscriptionId)], timeout)`; `in_flight_publishes: AtomicUsize` with a drop guard around the publisher call in `resolve_publish_work`; `commit_activity` counter + `last_commit_activity_at` (`Instant`) updated in `route_events` (`GroupUpdate`) and `resolve_publish_work` (`AutoPublish`). `repair.rs` → `RepairQueue::clear`. `session.rs` → `paused: AtomicBool`; `pause_subscriptions` (lifecycle lock held throughout: sweep → bounded marker `send().await` + ack with the `wedged` short-circuit and the direct-clear fallback → gauge zero → `disconnect` → `repair.clear()`), `wait_backlog_settled`, `settle_before_pause` (+ `settle_before_pause_with(window, cap, clock)`), `is_paused`; `resume_after_background` clears `paused` under the lock, `add_relay`s the `active` union and re-sweeps before `connect()`, and issues the inbox REQ on every k-th burst; gates in `run_repair` (before `take_due`), `reissue`, `maintain_subscription_health`, `subscribe_circle` (seeds the cursor), `unsubscribe_circle`; `SyncStatusReason::Paused` emitted once, `run_monitor` suppresses `Disconnected` while paused; the two comments saying "the engine never enables sleep_when_idle" stay true — leave them. `health.rs` → `HealthAction::Paused` (+ doc row).
- `haven/rust_builder/src/api.rs` → `SubscriptionHealthActionFfi::Paused`, `SyncStatusReasonFfi::Paused`, `LiveSyncFfi::{pause_subscriptions, wait_backlog_settled, settle_before_pause}` (`async fn … -> Result<_, String>` through `live_session_core()`, pattern `:11187-11200`) and `#[frb(sync)] is_paused -> bool` (pattern `is_running`, `:11246-11250`); regenerate. `haven/lib/src/services/relay_service.dart` → `SubscriptionHealthAction.paused` (the exhaustive switches in `maintenance_scheduler_provider.dart:_runHealthTick` `:454-460` and `subscription_health_mapping_test.dart` catch it at compile time); `live_sync_provider.dart:153-154` → `SyncConnectionPhase.paused`; `sharing_health_provider.dart:288-295` → `paused` clears `_disconnectedSince` and `recordRelaySubscriptionSignal` ignores it. `subscription_service.dart` + `nostr_subscription_service.dart` → `pauseSubscriptions()`, `waitBacklogSettled()`, `settleBeforePause()`, `isPaused`.
- NEW `haven/lib/src/services/background_burst_coordinator.dart` (no `ref.watch`; `finally` pause on throw and cancellation; `BURST_BOUND` constant).
- `haven/lib/src/pages/map_shell.dart:1335-1363` → installs the coordinator and hands the scheduler ticks to it (`LocationPublishSchedulerNotifier` gains `setTickSink(BurstSink?)`; `null` = today's direct publish; `_dispatchTick` carries the `.timeout(`); `:1455-1463` `shouldKeepRelayConnectedWhilePaused` → the predicate is DELETED (the coordinator owns the publish socket per burst); its static tests replaced by the coordinator's "socket closed after burst" test; the pause truth table gains a THIRD state (`burst`) rather than flipping a bool (R14 caveat in a `reason`); `_onResumed` bypasses the 60 s re-anchor throttle when `engine.isPaused`; `_bgSharingPausedSub` C4 edge → also `pauseSubscriptions()`.
- `haven/lib/src/providers/maintenance_scheduler_provider.dart` → `runKeyPackageIfDue(now)` / `runRelayListIfDue(now)` (reuse `_isCurrent`/in-flight guards; "due" = last completion older than the jittered interval; direct calls from the coordinator); the P1 foreground gate already keeps KP/relay-list/health timers un-armed while paused on every platform — P4 adds nothing there; R14 (a) "never re-add a background Dart timer" becomes a lint test.
- Guards: `check_engine_client_options.sh` `check_engine_pool_options` → `session.rs` still contains no `.sleep_when_idle(`/`.ping(false)` CALL, AND `fn pause_subscriptions`'s body contains `note_delivery_gap` (or the marker that reaches it), contains NO `forget_` token, and contains `client.disconnect()` and NO `client.shutdown()`; plus "no `subscribe_long_lived`/standing-REQ call reachable from the background-burst entry point" (token-bound); +3 fixtures (count 13): `forget_inbox_subscription` instead of `note_delivery_gap` (drops hold-backs); `client.shutdown()` instead of `disconnect()`; a standing-REQ call in the burst path — NO call-order fixtures (the order is not the cursor-safety argument; F3 changes it anyway). `check_live_sync_restart_budget.sh` is a numeric-derivation guard over `config.rs`/`cursor.rs`/`live_sync_resubscriber.dart`/`location.dart` (script lines 44-49, 148-205) and is NOT the home for a Dart source-order pin — "`_onResumed` references `isPaused` beside `shouldReanchorOnResume`" lives in `map_shell_location_access_lifecycle_test.dart` (the P1 source-order family); the shell guard is unchanged. `check_ios_background_publish.sh` → the iOS pause branch must call `pauseSubscriptions` on the C4 edge (extends check 6's neighbourhood; +1 fixture: 47 → 48 after P3, 23 → 24 if P4 lands first). `check_no_event_timestamp_cursor_advance.sh` must stay green (the burst anchors on EOSE/cursor). `check_m7_native_wake_guards.sh` 14b untouched (runtime decision, not a define flip). Extend check 13's token scan (iOS post-termination receive-only) to the coordinator: the burst is reachable only from the RUNNING process's publish tick, never from SLC/BGTask entry points (`ios_background_catchup.dart`/`HavenSLCHandler.swift`).
- ARB: `locationSettingsIosGuidance` 2nd sentence only if it mentions receiving (verify; P3 owns the 1st). `fgsNotificationSharing` stays literally true. No presence/one-connection copy round and no `presence_copy_accuracy_test`: the Privacy page that carried both sentences was removed 2026-08-29.
- `docs/privacy/privacy_invariants.json` → NEW `INV-R-BACKGROUND-PRESENCE-ONLY-AT-PUBLISH` (enforced): "While backgrounded on iOS with background sharing on, the engine holds no standing subscription and no socket between publish bursts; each publish tick runs one bounded burst (REQ at the persisted cursor, inbox lookback ≤ 2 d + 1 h and the inbox REQ every `INBOX_BURSTS_PER_REQ`-th burst (k = 1 unless OD4-b), never the 7-day cold window → ingest → publish → per-relay ack window 5 s → settle (in-flight publishes always complete) → close); on Android the foreground service shuts its publish pool at the end of every cycle; presence is revealed only at publish instants (and, to inbox-only relays, at every `INBOX_BURSTS_PER_REQ`-th one); the burst re-subscribes by construction." no `disclosure_arb_keys` (Privacy page removed 2026-08-29); tests = Rust `pause_subscriptions_leaves_no_subscription_in_the_pool`, `burst_ingests_a_peer_commit_before_the_location_is_encrypted`, `a_burst_reissues_the_inbox_req_every_kth_burst` + Dart coordinator tests + the FGS `the publish pool is shut down at the end of every cycle`; guard `check_engine_client_options.sh`. `INV-R-CROSS-PLANE-CORRELATION` (RC1): statement narrowed for CIRCLE relays ("standing while on screen; on iOS-bg one bounded burst per publish tick") and EXTENDED with the inbox-only-relay cadence residual, no ARB keys (its Privacy-page keys were deleted 2026-08-29); `accepted_deviations[RC1].summary` amended (narrowing + the named residual; "strictly narrows" is not claimed). `INV-L-ANDROID-REBOOT-RESURRECTS-PUBLISHING` unaffected. No `ratchet_override`.
- Docs: `SECURITY.md:873-900` bullet rewritten per the metadata statement incl. the inbox-only-relay inference and OD4-b (also `:257-263` Android sentence, `:876-879`, `:864-866` cross-reference); `docs/M11_ROLLOUT.md:117, :121` (P0's correction REVERSED to the original "while the app is in the foreground" + the Android-FGS clause + "on iOS in the background, one bounded burst per own publish" — the OD4 record); `WN_RELAY_EPOCH_SYNC_MIGRATION.md:63,:130,:168-176` iOS matrix rows, `:653-656` residual 1 scoped to foreground; `FA` Unit C notes + `:45-47` (the burst IS the iOS-bg receive path), `:62-65`/`:835-845` (the deleted 10-min re-anchor: the burst is NOT timer-driven, it rides the publish tick and the lookback is bounded — precisely what made the deleted one harmful), R14 (the 15-min tick is the FOREGROUND healer); `M7` §6 item 0 gains "no relay traffic between publishes" as an observable (Console `nw_connection` / relay-side log); `haven/test/pages/map/map_page_location_access_test.dart:10` doc comment (cites the deleted predicate) re-worded; `CI_HARDENING_BACKLOG.md:165` "Route 2 rejected" — consistent; dated note.

**Tests FIRST.**
- Rust (`session.rs` tests + NEW `haven-core/tests/live_sync_burst_e2e.rs`, in-process relay; the multi-member harness is `live_sync_two_engine_converge_e2e.rs` / `live_sync_engine_e2e_test.rs` — `selfremove_autopublish_e2e.rs` drives a `FakePublisher`, not a relay): `pause_subscriptions_leaves_no_subscription_in_the_pool` (`client.subscriptions()` empty; every relay `Terminated`); `a_partial_unsubscribe_all_is_swept_before_disconnect` (a relay whose `ensure_operational` errors → leftover ids are unsubscribed one by one; pool view empty); `a_stale_relay_side_req_never_precedes_the_bursts_own_req` (plant a leftover subscription on the core's client with the same sub-id and an older `since` while paused; open a burst; a recording `QueryPolicy` — precedent `catchup_sweep_e2e.rs:1300-1315` — shows the first REQ the relay admits for that sub-id carries the session's `since`, and the persisted cursor advances only after the session's own EOSE); `a_late_eose_after_pause_never_advances_a_cursor` (CLOSE, inject EOSE for the old sub-id → cursor unchanged); `a_backlog_larger_than_the_backlog_wait_is_ingested_by_the_burst_that_downloaded_it` (N slow events + EOSE; every event reaches the engine exactly once; the next REQ's `since` advanced — fails if the router is cleared before the drain); `a_hold_back_survives_pause_and_is_re_requested_by_the_next_burst` (deliver a `Buffered` future-epoch event, pause, burst → after the next burst's EOSE the PERSISTED CURSOR ≤ the held `created_at` AND the engine still holds the buffered message — the anchor bounds the next ADVANCE, `anchor.rs:101-109`, it does not lower `since` — fails if pause `forget`s anchors); `a_closed_queued_before_pause_does_not_reopen_a_req_while_paused` and `a_closed_queued_before_pause_does_not_fire_after_the_next_burst_opens` (relay-side REQ count for that sub-id == 1 in the burst); `subscribe_circle_while_paused_updates_the_model_but_opens_nothing`; `subscribe_circle_while_paused_seeds_the_cursor_so_the_next_burst_never_asks_since_zero`; `a_circle_added_while_paused_is_live_after_the_next_burst` (relay added while paused; after burst open its `QueryPolicy` has seen one REQ whose `#h` contains the new hex, and a peer 445 is decrypted); `maintain_subscription_health_while_paused_reports_paused_and_touches_no_socket`; `pause_emits_paused_not_disconnected` (one `Paused`, zero `Disconnected` across the pause); `burst_ingests_a_peer_commit_before_the_location_is_encrypted` (TWO relays, only the SLOW one holding Bob's commit; Alice's burst: `Settled` only after both endpoints, `group_epoch` advanced, then `encrypt_location` → a 445 Bob decrypts at the new epoch); `a_self_remove_auto_commit_is_published_and_confirmed_inside_the_burst` (real engine `Client` over a `MockRelay`, three members; `confirm_published` on the relay's OK; Bob decrypts the eviction); `pause_never_disconnects_while_an_auto_commit_awaits_its_ok` (the S-1/F2/P4-M5 gate, driven THROUGH the intake — Bob's SelfRemove proposal arrives as a relay event, never via a direct `resolve_publish_work` call — against a `WritePolicy` that releases the OK on an OBSERVED condition: the policy sees the close path pending (a hook on the pause's first step), or after a bounded yield ≤ 3 s, far from the crate's 10 s bound — never a wall-clock literal near it (a 9.5 s hold against a 10 s bound is a CI timing race); the call must return AFTER the ack with the commit CONFIRMED, never rolled back; a `NeverAnswer` variant returns after the crate's 10 s bound with the group rolled back to `Stable` and only THEN disconnected; the recording policy's ordering counter shows the relay never observed a CLOSE/disconnect before the publish resolved — relay-backed, outcome sets + ordering only, never an elapsed window; ≤ 10 s wall clock, stated); `a_commit_arriving_between_settle_and_pause_is_still_confirmed` (relay withholds the OK; deliver the proposal AFTER `settle_before_pause` returned; call `pause_subscriptions`; the OK is released once the close path is observed pending; group ends Stable-confirmed, matching the relay's stored state); `pause_subscriptions_completes_within_the_lifecycle_bound_when_the_worker_is_dead` (kill the worker → `wedged`; the call returns within `RELAY_LIFECYCLE_OP_TIMEOUT`, router cleared by the fallback, `note_delivery_gap` called, and a subsequent `stop()` does not hang); `a_burst_open_racing_a_draining_pause_waits_for_the_clear` (open a burst while the marker drain is in progress — the router entries of the NEW burst survive, i.e. the open serialised behind the lock); `a_non_kth_burst_settles_without_an_inbox_endpoint` (under k > 1 a burst that issued no inbox REQ returns `Settled` without waiting on the inbox); `a_dead_relay_in_a_bucket_does_not_time_out_the_burst` (one relay of a two-relay bucket refuses the REQ; the burst settles on the accepted endpoint alone); `settle_before_pause_with_returns_at_once_on_a_quiet_burst` and `…caps_follow_on_activity_at_eighteen_seconds` (PURE, `start_paused`, on the injected clock); `wait_backlog_settled_times_out_without_a_relay_eose_and_reports_it` (pure, `start_paused`, a `pending()` endpoint); `background_burst_holds_no_standing_req` (client-side, equivalent by construction: every `client.relay(url).status() == Terminated` and `client.subscriptions().is_empty()` between bursts — `MockRelay` subscription introspection is U in `nostr-relay-builder` 0.44; keep the relay-side phrasing only if the builder exposes it); `a_burst_reissues_the_inbox_req_every_kth_burst` (OD4-b; recording `QueryPolicy` on the inbox relay: `#p` REQs == ceil(bursts / k)). `security_rule_gates.rs` → `rule13_a_burst_never_pauses_with_a_pending_publish_outstanding` (the gauge: `in_flight_publishes == 0` at the instant `disconnect()` is called — asserted through the recording policy's disconnect observation — and never pauses in `PendingPublish`); `rule14_pause_and_burst_open_no_second_session` (no new `AccountDeviceSession::open`/`newInstance` site; `LIVE_SESSIONS` stays 1 across 3 bursts); `a_burst_backlog_larger_than_the_intake_cap_holds_the_cursor` (helper at `security_rule_gates.rs:465`). (`cursor.rs` / poisoning tests: landed in P1.)
- Dart NEW `test/services/background_burst_coordinator_test.dart` (fakes + `FakeAsync`/injected clock): `a tick opens, drains, publishes, folds due maintenance, settles, closes — in that order`; `a second tick during a burst joins it instead of opening a second socket`; `the publish socket is shut down after every burst`; `the engine is paused after every burst`; `maintenance runs only when due and only after the publish, by direct call`; `the health tick is never armed while paused`; `toggle-off mid-pause pauses the engine and shuts the relay` (C4); `resume while paused re-anchors regardless of the 60 s throttle`; `a burst that throws mid-chain still pauses` and `a burst interrupted by cancellation still pauses` (try/finally + `bgEnabled` re-check between links — otherwise the engine is left `Live` with standing REQs forever: fail-safe for delivery, silent battery regression); `a C4 edge during a deferred-commit link lets it confirm or roll back before the pool is shut`; `the outer tick timeout never cancels a running burst` (fire the watchdog mid-burst; the burst completes and pauses; the timeout is only reported); `commit-critical links, including the pause link, carry no timeout`; `BURST_BOUND is below the publish link timeout`. `test/lints/background_burst_coordinator_lint_test.dart` (AST, family of `self_update_disabled_test.dart`): no `ref.watch(` in the coordinator file. `test/providers/sharing_health_provider_test.dart` → `a paused engine never yields a relayDisconnected verdict, however long the pause` (FakeAsync 10 min of `paused`). `test/pages/map_shell_location_access_lifecycle_test.dart` → `_onResumed references isPaused beside shouldReanchorOnResume` (source-order). `test/providers/maintenance_scheduler_provider_test.dart` → `runIfDue` tests + "a due KP/relay-list job runs after the burst on the warm socket, never on its own background timer"; existing "fires each task exactly once after its initial delay" stays. `test/widgets/map/sharing_health_banner_test.dart:241` → "re-renders every 72 s while foregrounded and not at all while backgrounded" (strengthened; P1 may already have landed it). FA:693-709 delivery-silence re-anchor: the 684 s arm becomes foreground-only — test that it does not fire while backgrounded on iOS.
- Existing red → replacement: `map_shell` static tests for `shouldKeepRelayConnectedWhilePaused` → deleted with the predicate; replaced by the coordinator's socket-closed test (behavioural, stronger) and the three-state truth-table row. `map_shell_receive_recovery_test.dart:388-405` (`kLiveSyncRestartBudget` 65 s < 90 s heal floor) unchanged (foreground). `ios_bg_publish_test.dart` P2a/P2b: the driven tick now runs a burst; P2a's oracle (Bob's relay subscription sees Alice's 445) unchanged; ADD **P2c** as an IN-PROCESS oracle (the iOS lane runs `tooling/e2e/local-relay` — no strfry, no wire proxy, log lines "listening"/"shutting down" only, `main.rs:54,59`; and the macOS wrapper cannot encrypt an MLS message): keep Bob (`SyntheticUser`, own DB — Rule 14 unaffected; `check_mls_session_single_owner.sh` does not scan integration tests) ALIVE across the pause instead of disposing him at `:705`; the DRIVE calls `bob.publishLocation(...)` (`synthetic_user.dart:449`) after P2a; then bounded-poll `subscriptionService.isPaused == true` between ticks (the "no standing REQ" half in CI, with the Rust in-process test) and `memberLocationsProvider` (or the decrypted-event stream) for Bob's fix within `kLocationPublishMaxInterval + BURST_BOUND`, print `[bg-publish] BACKGROUND_RECEIVE_OK`; shell fixture C7 for the missing marker; relay-side REQ/CLOSE counts (incl. "no `#p` REQ between bursts") only if the local relay gains a `REQ/CLOSE/disconnect` log line with a connection id — a tooling change with its own fixture, listed as optional evidence, not a free oracle; `DISABLE_WAIT_SECS` (`run-ios-bg-publish.sh:220-224`, 655 s + 37 % today) re-derived in the wrapper comment (655 + 200 + margin) and `check_e2e_step_timeout_ordering.sh` re-run with the new inner/step/job derivation (today 45 min inner via `nick-fields/retry`, 95 step, 115 job — `e2e-ios-background-publish.yml:97,181,184`); the workflow header lists P2c. `b9` (Android, foreground) unchanged. Guards: `check_engine_client_options.sh --self-test` 13/13; `check_ios_background_publish.sh --self-test` (48/25).

**Implementer work packets** (sequential unless noted).
| # | Packet | Sequencing | Done when |
|---|---|---|---|
| P4-1 | (landed in P1 as P1-N0 — the bounded lookback is a precondition of the sharing-OFF engine stop too) | — | — |
| P4-2 | Rust engine: `paused`, `pause_subscriptions` (sweep, marker, repair clear), per-endpoint EOSE tracking, in-flight gauge, `wait_backlog_settled`, `settle_before_pause(_with)`, burst-open relay union + re-sweep, paused `subscribe_circle` seed, gates, `Paused` status + monitor suppression, k-th-burst inbox fold, `HealthAction::Paused`, Rust tests + rule gates | first | all Rust tests green; `check_engine_pool_options` (13 fixtures) green |
| P4-3 | FFI methods + enum variants; regenerate | after P4-2 | `flutter analyze` clean (exhaustive switches list every site) |
| P4-4 | Dart coordinator (no `ref.watch`; cancellation-safe `finally`; `BURST_BOUND`) + scheduler sink/`_dispatchTick` + maintenance `runIfDue` + `paused` phase mapping + unit/lint tests | after P4-3 | `flutter test` green |
| P4-5 | Dart lifecycle wiring: `map_shell.dart` pause/resume/C4 edges, three-state table, `isPaused` source-order test; guards + fixtures | after P4-4 | `flutter test`, `flutter analyze`, both guards' `--self-test`, `check_location_access_gate.sh` check 8, `--static-only` |
| P4-6 | Manifest + docs: invariant + RC1 residual, SECURITY/M11/WN/FA/M7 (no copy round — the Privacy page was removed 2026-08-29) | ∥ P4-5 | `check_privacy_invariants.sh` green |
| P4-7 | Lane: `ios_bg_publish_test.dart` P2c (Bob alive; in-process oracle; C7) + wrapper budget re-derivation + workflow header | after P4-5 | `check_e2e_step_timeout_ordering.sh`; green lane run; floors `src/relay/live_sync/|95` (97.24 %), `session.rs|94` (96.19 %): new burst code needs its e2e tests in the same commit or HOLD; `background_burst_coordinator.dart` gets a `--list`-derived row |

**Reviewer checklist.** Break the cursor: any path where a burst advances a cursor past an un-applied event (late EOSE, CLOSED-then-reissue race, hold-back dropped by pause, a stale relay-side REQ re-sent by the crate ahead of the session's, a fast relay's EOSE settling the burst while the slow relay still replays) — the guard pins `note_delivery_gap`-not-`forget_*` because `forget_*` silently loses hold-backs. Break Rule 12: clear the router before the drain — the backlog test must go red. Break Rule 13: deliver a proposal AFTER `settleBeforePause()` returned and BEFORE `pauseSubscriptions()` reaches `disconnect` — the marker ack + gauge check inside the pause must let the commit CONFIRM; release the OK on an observed condition, never a wall-clock literal near the 10 s bound; kill the worker and pause — the call must return within `RELAY_LIFECYCLE_OP_TIMEOUT` and a later `stop()` must not hang; open a burst while a pause is draining — the new burst's router entries must survive; with a never-acking relay the group returns to `Stable` before the disconnect (V-P4-1 → V: `disconnect` makes `wait_for_ok` `Err(PrematureExit)`/`Err(NotConnected)`, `inner.rs:1382-1389` — never a false confirm, which is exactly why the gauge must prevent the disconnect). Break the gates: queue a CLOSED before the pause and show a REQ re-issued after burst open (must be impossible — the queue is drained); make `maintain_subscription_health` reach `health_probe` while paused (must be impossible — it would `resume_after_background` in the background); subscribe a circle with a new relay while paused and show the burst open failing or the circle silent. Break Rule 14: any second session/isolate opened by the coordinator; `check_mls_session_single_owner.sh` still three files. Liveness vs FA C/D: with no standing REQ the banner cannot claim a dead receive plane in the background (model tick foreground-only; `paused` never stamps `_disconnectedSince`; on resume re-derived from `lastPeerAt`, bounded 346 s < 564 s). Opt-out: toggle OFF mid-pause ⇒ no REQ, no socket, no timer — C4 test AND guard; a cancelled burst still pauses. Copy: 13 locales keep "which circle tags you are following", say "briefly", never "in seconds" for the background, never "one connection"; rule 12 sweep. Test reliability: every wait on a `Notify`/state transition with a scaled budget or a virtual clock; no paused clock against a live socket; grep new tests for `sleep(`. Wedge: the throw-path AND cancellation-path tests exist. C5: a pending commit is confirmed only on OK-ack (`check_e2e_publish_before_apply.sh`, `auto_commit.rs` at floor 100). C6: `_dispatchTick` carries the `.timeout(` (`check_location_access_gate.sh` check 8 resolves it), `BURST_BOUND < _publishLinkTimeout`, and NO timeout wraps commit-critical work. Dart: no `ref.watch` in the coordinator (lint); nothing in the burst path waits on a rebuild.

**Risks / rollback.** A relay that never EOSEs makes every burst wait 5 s (+5 J each): bounded, surfaced as `TimedOut`. iOS suspends mid-burst (it should not while the location session is live — R6, which P3's hardware 0a gate proves; if the 100 m shape does NOT keep the process alive on hardware, P4's burst loses its clock too — the same merge gate): the next burst re-anchors at the cursor; a commit mid-publish is `PendingCommitRecovered` → resync. Coordinator bug leaving the engine `Live`: fail-safe for delivery, visible as the 55 s bars returning; P2c catches the standing-REQ case in CI. Rollback: one commit making the iOS pause branch not install the coordinator (three-state row back to keep-socket; standing REQ restored on iOS-bg); Rust additions inert when unused BUT the guard fixtures for `pause_subscriptions` and the `isPaused` source-order test revert with the Dart (they would otherwise be red); RC1 summary back, the invariant deleted (override item) and P0's "today's truth" sentence re-applied in M11/SECURITY — the SECURITY.md/M11 statement MUST revert in the same commit (it would otherwise overclaim; no user-facing copy is involved since the Privacy page's removal, 2026-08-29). Cursors are untouched; the standing REQ resumes from the persisted cursor (with P1's bounded lookback).

**Acceptance.** CI: all tests above; P2c green on `e2e-ios-background-publish`; both guards' self-tests; `check_privacy_invariants.sh`; l10n gates; `check_e2e_step_timeout_ordering.sh` with the re-derived budget. Hardware (owner, `POWER_MEASUREMENT.md` + M7 §6): 60 min backgrounded, sharing ON, cellular: Xcode Energy gauge networking bars only at publish instants; relay-side log shows one REQ/CLOSE pair per publish on circle relays, one per k bursts on inbox relays (OD4-b), and no traffic between; Battery ≤ ~1 %/h stationary over ≥ 3 h with P3 in place.

**Owner decisions / open questions.** OD4, OD4-b. V-P4-1 → V (`Client::disconnect` mid-`send_event` yields `Err`, never a false confirm — `inner.rs:1255-1270, :1382-1389`; the gauge prevents the disconnect); I-P4-1 (5 s backlog wait vs typical strfry EOSE ~100 ms, `config.rs` §P-15 — expected never to bind; measure on the owner's relays); U-P4-1 (iOS `nw_connection` teardown on `disconnect` completes before the radio tail — hardware only); U-P4-2 (`MockRelay` subscription introspection in `nostr-relay-builder` 0.44 — the client-side oracle is used regardless).

### 5.5 Phase P5 — Publish coalescing (D7) [OD3 — separable]

Honest starting point (F21, F23, research §3.6): shared-relay decorrelation never held — the multiplexed `#h` REQ
(`planes/mod.rs:160-203`) already tells every shared relay "this socket watches circles {A,B,C}", and all circles'
publishes leave over one publish socket. What the per-circle schedule still buys: (i) protection against colluding
relays that ignore IP (weak); (ii) — through the stagger, not the schedule — distinct whole-second `created_at`s against
an archive adversary (real). Variant (a) keeps (ii) and drops (i); variant (b) keeps both and saves far less.

#### Variant (a) — full coalescing (OD3 = YES)
**Goal / non-goals.** One jittered burst per nominal interval publishes every eligible circle: wakes ≈ 30/h regardless of
circle count on every plane (FG, iOS-bg via P4, Android FGS). Non-goals: cadence bounds, TTL web, ephemeral keys, the
motion trigger, any wire change.
**Design.** ONE `JitteredScheduler` (`jittered_scheduler.dart`) per plane instead of N; its tick publishes the eligible set in
a CSPRNG permutation with consecutive encrypts separated by the EXISTING CSPRNG gap in [2 s, 9 s] under the existing 30 s
spread cap (D7 — the stagger constants do not move; only the WAKE is shared); the last circle's fix age ≤ 33 s
(12 circles) ≪ `kStreamPositionMaxAge`. The FGS keeps `PerCircleDueTracker` as bookkeeping but seeds ONE shared due time
(`seedIfAbsent(all, from)`) and `markPublished` re-arms all keys from the same CSPRNG sample; `seedStaggered` is deleted.
Foreground and iOS-bg: the P4 coordinator receives one tick per interval; `locationPublishSchedulerProvider` keeps its
`_publishChain`/watchdog with one scheduler. No-gap invariant: every circle still publishes every ≤ 168 s + ≤ 33 s spread
(inside the 60 s margin); `INV-W-445-EXPIRATION-WINDOW` stays true; `ttl.rs:63-66` / `SECURITY.md:586` prose re-worded.
Motion trigger unchanged (fires a burst through the same path).
**Exact change list.** `publish_stagger.dart` → constants UNCHANGED; header re-worded (the stagger is the archive-adversary
defence — distinct whole-second `created_at`s spread over eight values; the schedule is no longer a privacy mechanism).
`location_publish_scheduler_provider.dart` → one scheduler; `_onTick` publishes `filterPublishEligibleCircles` in
`stagger.shuffled` order with `sampleGaps`; `trackedCircleKeysForTest` → `eligibleKeysForTest`. `per_circle_due_tracker.dart`
→ delete `seedStaggered`; header; `background_location_task.dart:1206-1222` seeds the shared time. `constants/location.dart`
header → "one jittered burst per interval; circles staggered 2–9 s for distinct `created_at`s". `haven-core/src/location/ttl.rs:63-66`
doc; `SECURITY.md:584-587` (R12 sentence) rewritten + NEW subsection `#### Coalesced multi-circle publish bursts (PUB-COALESCE)`
under `### Publish cadence: jittered scheduler` (`:729`; heading `#### The no-gap invariant` `:787` untouched — manifest
anchor). `docs/privacy/privacy_invariants.json`: `INV-R-PER-CIRCLE-PUBLISH-DECORRELATED` → `status: "accepted_deviation"`,
`accepted_deviation_id: "PUB-COALESCE"`, `tests` replaced by the new burst tests (kept ≥ 1 so no `.unbacked`), statement
"Circles publish in one burst per interval, consecutive encrypts 2–9 s apart so no two circles share a kind-445
`created_at`; every relay carrying any of your circles sees the same burst rhythm, so relays each holding only ONE of
your circles can match the timing"; no disclosure key (the Privacy page was removed 2026-08-29; a zero-disclosure accepted deviation is a permitted state since then); NEW `accepted_deviations[]` entry
`{ "id": "PUB-COALESCE", "source": "haven-core/SECURITY.md#coalesced-multi-circle-publish-bursts-pub-coalesce", "summary": "shared-relay decorrelation was never effective while the multiplexed #h subscription and the single publish socket exist; with one shared tick sequence, circles on disjoint relay sets emit identical inter-burst intervals, so anyone holding two of your circles' relay archives can tell they belong to the same phone; the 2–9 s CSPRNG stagger is retained solely so archived events carry distinct timestamps", "forbidden_claim": "Copy must not present per-circle timing as preventing a relay from linking your circles, must not limit the linkage to relays that carry several of your circles, and must not present the stagger as more than distinct timestamps." }`;
`"ratchet_override": { "reason": "INV-R-PER-CIRCLE-PUBLISH-DECORRELATED is downgraded to accepted deviation PUB-COALESCE: per-circle schedules never decorrelated circles at a shared relay (multiplexed #h REQ, one publish socket) and cost one radio wake per circle per interval; the archive-timestamp defence is kept via the 2–9 s stagger. Owner decision OD3, <date>.", "items": ["INV-R-PER-CIRCLE-PUBLISH-DECORRELATED.status"] }`
(exact item id per `check_privacy_invariants.sh:1712`); the FIRST commit after merge deletes the block (`:2586`
fails a stale override). `INV-R-TRAFFIC-METADATA-OBSERVABLE` keeps citing `'the production stagger draws from a CSPRNG'`
(name kept verbatim). `docs/privacy/README.md` deviation list (+1, the
`jq` snapshot sentence); `P0_1_FGS_SESSION_PLAN.md:83,:453` (nonce-window/duplicate-publish reasoning now "one burst");
`CI_HARDENING_BACKLOG.md:1590`; `haven/integration_test/e2e/e2e_combined.dart:297` "2–9 s" stays TRUE (record so nobody
"fixes" it). Guards: none new; `check_publish_jitter_fraction_parity.sh` unchanged; NEW fixture in the
`publish_decorrelation_wiring_test` lint: `Random.secure()` still the RNG.
**Tests FIRST.** `test/lints/publish_decorrelation_wiring_test.dart` → the three manifest-cited tests are REPLACED (not deleted
first) by `every circle is published in one burst per tick`, `consecutive encrypts are ≥ 2 s and ≤ 9 s apart (gap sampled per pair)`,
`burst spread for N in 2..12 never exceeds maxSpreadFor(N), and maxSpreadFor(N) ≤ kPublishStaggerMaxSpread for N ≤ 11` (the
assertion that FAILS on a 2.5 s max gap — with `floorMs = min(minGap + 1 s, ceiling)` the cap could never engage and the
spread would be 2.5 × (n−1) unbounded by it), keeping `the production stagger draws from a CSPRNG`; the manifest `tests[]` lists
the new names in the same commit (rule 3). `publish_stagger_test.dart:125-144` → bounds UNCHANGED; ADD `whole-second created_at
deltas take at least five distinct values over 1000 sampled gaps` (the fingerprint defence); "gaps stay inside the per-gap
ceiling" and CSPRNG tests unchanged. `background_fix_request_test.dart`'s horizon pin is UNAFFECTED (decoupled in P2a —
record it as P5(a) collateral checked). `per_circle_due_tracker_test.dart` → `seedStaggered` group deleted; `two circles seeded
together get independent, decorrelated phases` inverted to `all circles share one due time and re-arm together`; `:314-420`
"deferred not compressed" kept. `location_publish_scheduler_provider_test.dart:123-127,:146-151` → `one independent scheduler per
eligible circle` → `one scheduler publishes every eligible circle per tick`; `a per-circle tick publishes ONLY that circle` deleted
(its promise is reversed by OD3 — record in the PR); `encryptConcurrencyPeak == 1` KEPT. `location_publish_decorrelation_test.dart:120-254,:398-405`
→ every `greaterThan(1000)` and "order varies" assertion kept (the `created_at` defence IS these); spread bound stays 30 s
(33 s at n = 12 — the existing `maxSpreadFor` doc); only "never concurrent across INDEPENDENT timers" premises dropped.
`background_publish_stagger_teardown_test` unchanged (the FGS already batches). Rust `ttl.rs`
doc-only; `publish_interval_jitter_fraction_bp_is_pinned` unchanged. Lanes: a 2-circle HOST test is required; an FGS-lane
assertion ("multiple circles' 445s arrive within one 30 s window") exists ONLY if a 2-circle E2E target is funded — no lane
row is claimed otherwise (a host test cannot back a lane row).
**Packets.** P5a-1 (Dart plane, 1 d): scheduler + tracker + tests (no constant change). P5a-2 (manifest + docs, ¼ d, ∥): override
block, deviation entry, SECURITY.md subsection, README deviation list, `check_privacy_invariants.sh`. P5a-3 (optional 2-circle target, ½ d, after P5a-1).
**Reviewer checklist.** Produce two circles with equal `created_at` (mock clock at a second boundary) — must be impossible; produce a
constant whole-second delta across bursts — the distinct-values test must go red on a 2–2.5 s gap; the override is REMOVED in the
follow-up commit; no copy anywhere (13 locales, `LocationDisclosureStrings`, `SECURITY.md`) still claims circles are unlinkable by
timing OR limits the linkage to shared relays; R10's ≥ 40 % CSPRNG jitter untouched; burst spread ≤ 33 s so a hung circle cannot
wedge siblings (`publishLinkTimeoutForTest` becomes load-bearing); the P2a horizon constant is untouched.
**Risks / rollback / acceptance.** Rollback = revert the Dart plane commit AND restore the manifest status (an UPGRADE needs no override —
restore, do not override) + PUB-COALESCE entry + SECURITY.md heading. Acceptance: hardware wake count ≈ 30/h for a
3-circle user (vs ≈ 90 under (b)). OD3 required before P5a-2.

#### Variant (b) — wake-sharing only (OD3 = NO; invariant intact)
**Goal.** Keep `INV-R-PER-CIRCLE-PUBLISH-DECORRELATED` enforced verbatim; share only the WAKE (and the access-gate read) when two
independent due times fall inside one stagger window. Battery: removes N−1 access-gate reads and timer wakes per coincident cycle;
radio wakes stay ≈ N × 30/h — state plainly in the P1/P4 docs that (b) is a CPU tidy-up, not the multi-circle radio fix.
**Design.** Foreground: replace N `JitteredScheduler`s with ONE `PerCircleDueTracker` (the FGS model) driven by a single master
tick armed at `min(nextDueAt) − now`; on fire publish `dueKeysUpTo(now + kPublishStaggerMaxSpread)` with the existing 2–9 s gaps
and `nextBackgroundPublishSlot` rule; re-arm to the new minimum; seeds through `seedStaggered` (the manifest's cited test names —
"seeds per-circle schedules through the STAGGERED seed", "does not seed every circle at the cycle timestamp", "paces each publish
through the running-gap slot rule" — stay valid, now true of BOTH planes). iOS-bg (P4): the coordinator receives one master tick
per due window; a burst publishes only the due circles. No copy, manifest or doc change beyond noting the foreground uses the FGS model.
**Exact change list.** `location_publish_scheduler_provider.dart` → one `Timer` + `PerCircleDueTracker` + `PublishStagger` (~−60 lines);
`jittered_scheduler.dart` kept for other users or deleted if unreferenced; `per_circle_due_tracker.dart` header "both planes";
`publish_stagger.dart` constants unchanged (as in (a) — the stagger never moves in either variant).
**Tests FIRST.** `location_publish_scheduler_provider_test.dart`: `one independent scheduler per eligible circle` → `one master timer, one due time per circle`;
`a per-circle tick publishes ONLY that circle` → `a master tick publishes only the circles that are due`; add `the master timer re-arms to the earliest due time`.
`publish_decorrelation_wiring_test.dart`: extend the source-grep of the three cited tests to cover `location_publish_scheduler_provider.dart`.
Nothing else goes red.
**Packet / reviewer / rollback / acceptance.** One packet (1 d). Reviewer: two circles never share a wall-clock second (existing suite);
a circle is never published EARLY to share a wake (only `dueKeysUpTo(now + spread)`, ≤ 30 s early — the FGS's accepted behaviour).
Rollback = revert one file. Acceptance: unchanged hardware numbers vs P4; CPU-only win. No owner decision needed (default when OD3 is declined).

### 5.6 Phase P6 — Closure

**Goal / non-goals.** Nothing in P1–P5 may be committed with stale copy, a dangling manifest citation, a red gate, or an
unverified battery claim. P6 is mostly the per-phase **"lands together" matrix** (§6.1) that P1–P5's implementers execute
inside their own commits, plus what can only happen at the end: the hardware acceptance run, the coverage-floor re-pin from
CI, the stale-override deletion and the final doc reconciliation. Non-goals: no mechanism work; no new promise.

**Design — the rules every phase commit obeys.**
1. Copy, invariant, test, doc move in ONE commit: a re-worded ARB key lands with its `@description`, 12 translations (translator agent per language + independent reviewer agent per language), `dart scripts/ci/arb_parity_check.dart haven/lib/l10n`, `flutter gen-l10n` (warning-free), the manifest note, the copy-tie test and the doc line.
2. The ratchet is manifest-embedded (§2.4): a status downgrade or dropped key is named in `ratchet_override.items` with a ≥ 40-char reason in the SAME commit; deleted in the first commit after merge. A key that merely moves between invariants is not a weakening; a re-worded value under the same key is invisible to the ratchet — hence rule 3.
3. A re-worded claim gets a copy-tie test in `haven/test/l10n/` (pattern `repair_copy_accuracy_test.dart`: per-locale forbidden/required vocabulary, `every supported locale has a forbidden list` anti-vacuity, `the scanner actually catches a violation` self-check).
4. Guards grow by fixtures, never by loosening: every regex change ships with a fixture that fails on the old shape; `SELF_TEST_FIXTURES` bumped to the exact count; new native/Dart files appended to the scanned lists.
5. Floors move only via `--repin` from a CI lcov artifact; a HOLD row needs tests; every NEW privacy- or liveness-critical file (`ios_location_source.dart`, `background_fix_request.dart`, `publish_wake_lock.dart`, `background_burst_coordinator.dart`, `cursor.rs`) gets its own row from `--list <stack> <ci-lcov>` in the phase's re-pin commit, then `--lint` (directory rows alone would let one critical file hollow out while its neighbours compensate — the file rows exist for exactly that, `coverage_floors.txt:1-2`).
6. Every red test is replaced by an assertion of equal or greater strength on the new mechanism (§7.4); never `skip`, never a widened window.
7. Docs cite the phase that changed the fact, dated; load-bearing rationales R1–R14 are amended, not deleted; every phase's doc sweep includes the stale references its mechanism falsifies (`map_page_location_access_test.dart:10` for P4, the `ios_background_session_service_test.dart` parser cases for P3, and the ones recorded as STILL TRUE — `e2e_combined.dart:297`, `run-b5-permission-revocation.sh:191,1947` — so nobody "fixes" them).
8. **l10n, binding for every round:** translator agent per language → an INDEPENDENT reviewer agent per language that is HANDED the gating facts (which key renders under which tier/handler state; no "pause"/"paused"/"timer"; Apple's localized Settings menu names, tier-neutral where iOS versions differ) and checks the translator's REASONING, not just the output (register, plurals, RTL for ar/fa/ur, screen-reader readability); every locale's copy-tie forbidden list contains the OLD sentence's words (e.g. `app_de.arb:111` "durchgehende"/"blaue", `app_ar.arb:111` "متواصلة"/"أزرق") so an untouched translation under a re-worded key is caught; `dart run scripts/ci/arb_parity_check.dart haven/lib/l10n` + `flutter gen-l10n` warning-free.

**Exact change list (P6-proper).**
| Item | Detail |
|---|---|
| Hardware acceptance | Re-run `docs/POWER_MEASUREMENT.md` on the same two phones at the final commit (and, cheaper, after P2a and after P3 as intermediate gates — ≥ 3 h iOS S-window, ~2 h Android per run); P3's 0a and P2b's forced-idle rows are MERGE gates of those phases, not acceptance items. Fill rows under `## Acceptance <date> <commit>`. |
| M7 §6 item 0 re-run | Owner: the P3-rewritten item executed on the physical iPhone under BOTH tiers plus the provisional row; result recorded in M7 §6 (the ⚠️ RE-RUN REQUIRED banner is removed only by a recorded pass; 0a itself was already recorded at the P3 merge). |
| Floors | after the last mechanism phase's CI run: `gh run download <id> -n flutter-coverage-report` → `scripts/ci/check_coverage_floors.sh --repin flutter haven/coverage/lcov_filtered.info`; `gh run download <id> -n rust-coverage-report` → `--repin rust haven-core/coverage.lcov`; `--list` rows for any new file still missing one; then `--lint`. Never from a local run (local Flutter 3.41 ≠ pinned 3.44.8; local rustc 1.92 ≠ 1.97.1 — `check_coverage.sh` refuses the wrong rustc but a hand edit would not be refused). Artifacts expire in 30 days — download in the same week. |
| Stale overrides | delete any `ratchet_override` left by P5 (and any phase that needed one); `check_privacy_invariants.sh --baseline-ref origin/main` must report 0 declared overrides. |
| FA §7 | add "Unit H — Power (P1–P5)" with the per-phase mechanism, the measured before/after rows, and the wedge-regression tests (§6.2) — in full, not a stub. |
| README (privacy) | deviation register snapshot sentence updated if PUB-COALESCE was added; "What the gate cannot prove" gains: native config is guard-pinned, not test-pinned. |
| `CLAUDE.md` | `:258` lane sentence (P3); Commands block unchanged; add `docs/POWER_MEASUREMENT.md` and this plan to References. |
| M11/SECURITY | final disclosure accuracy per P4 (or P0's "today's truth" if OD4 declined). |

**Tests FIRST (P6-proper).** No product code, so its "tests" are gate runs: `scripts/ci/check_privacy_invariants.sh --baseline-ref origin/main`
(0 overrides, all citations resolve), `scripts/ci/check_coverage_floors.sh --lint`, `dart scripts/ci/arb_parity_check.dart haven/lib/l10n`,
`cd haven && flutter gen-l10n && flutter test test/l10n/`, every `--self-test` in `repo-guards.yml` (`scripts/ci/run_source_guards.sh` runs the
argument-less half locally).

**Work packets.**
| # | Packet | Sequencing |
|---|---|---|
| P6-A | Per-phase matrix execution — NOT a separate packet: each of P1–P5's packets carries its §6.1 row as done-criteria (the reviewer refuses a phase PR missing any cell) | inside P1–P5 |
| P6-B | Hardware acceptance run (owner) + fill template | after the last mechanism phase (intermediate runs after P2, P3 recommended) |
| P6-C | Floors re-pin from the final CI run + stale-override deletion + FA Unit H + README/CLAUDE.md/M11/SECURITY touches | after P6-B's CI run; ONE commit |
| P6-D | M7 §6 item 0 re-run (owner, physical iPhone, both tiers) | any time after P3; recorded before release |

**Reviewer checklist (second wave, all phases).** Diff the manifest: every new invariant cites tests/guards that EXIST (grep), no `accepted_deviation`
carries an assertion key, every new `doc_anchors`/`source` fragment is a real heading, `SELF_TEST_FIXTURES` equals the fixture count. Every ARB key
touched appears in 13 files with placeholders intact; translator/reviewer transcripts show reasoning per language and the reviewer received the gating facts. Every re-worded claim has a
copy-tie test whose forbidden list would catch the OLD sentence (plant it and watch it fail). No lane window widened; every replaced assertion is at
least as strong (read the test body, not its name). Presence-only logging in every new native file (lists updated; a planted coordinate log AND a planted `Log.e(TAG, "x", e)` fail).
Hardware rows exist and the relay-side liveness column is ≤ 228 s (≤ 188 s after P2a) in every accepted run. `git diff` of `coverage_floors.txt` contains only `--repin`/`--list` output.

**Risks / rollback.** A phase merged with its matrix row half-done (copy in English only; a guard step without `--self-test`; an override left
stale) — the reviewer checklist is the merge gate. Rollback of P6-proper: revert the closure commit as a WHOLE (floors reverting DOWN is exactly
what `--repin` forbids — never partially).

**Acceptance.** CI-provable: all gates green on `main` with 0 ratchet overrides; new guards enforce (not self-test-only — rule 6b); matrix lanes
green on the final commit. Hardware: §6.6 thresholds.

**Owner decisions / open questions.** OD1, OD3, OD4, OD4-b, OD-P2-2, OD-P2-3, OD-P3-b, OD-P3-c (whole rows). V-P1-4 (banner timer), U-P0-1 (Android-15 6 h claim), U-P0-2 (goldfish GPS navigating — CI never depends on it).

---

## 6. Cross-phase verification, risks, rollback, measurement

### 6.1 The "lands together" matrix (per phase; each row is a done-criterion of that phase's packets)

| Phase | ARB / l10n | Manifest | Guards | Tests red → replacement | Lanes | Docs | Floors |
|---|---|---|---|---|---|---|---|
| P1 | none | NEW `INV-R-PUBLISH-POOL-NO-KEEPALIVE` (enforced; no disclosure key; symbols `publish_relay_options`/`build_engine_client`; fetch-primitive test; no ratchet) | `check_engine_client_options.sh` function-shaped, checks 3–7 + `--self-test` 10 + the repo-guards self-test step; `check_android_location_power.sh` (7)(8); ios `check_stream_provider` (4 fixtures → 23) | `map_shell_test` additive rows; service gate tests; `location_provider_test` fail-closed/placeholder cases; the no-frame release test; `location_access_provider_test` suspend/`resume()` cases; `cursor.rs::inbox_subtracts_7_days_regardless_of_phase` → three exact-value tests; `location_stream_error_handling_test:452-501` ≥ 2 listeners kept; 37 `RelayService` mocks gain a method | b9 `PUBLISH_AFTER_IDLE_OK` asserted from the first landing; B1 device-stamped sampler: the UI request (`@+1s0ms` + `minUpdateDistance=1.0`) pre-handoff, never after | SECURITY/M11 publish-pool sentence; M7 §D + history; FA §C debounce cause with its exact consequence; FA:697-703 + R14 (≤ 49 h re-anchors) | providers 84 / services 65 / `manager.rs` 78 absorb; `cursor.rs` `--list` row; RATCHET expected; re-pin from CI |
| P2a | none (`fgsNotificationSharing`, battery-opt strings unchanged) | `INV-L-BACKGROUND-DISCLOSURE-GATE` additions; NEW `INV-L-ANDROID-BACKGROUND-SINGLE-GNSS-REQUEST`; no ratchet | `check_android_location_power.sh` 1–6 (function-shaped; (1) pins `allowWakeLock` ABSENT; (2) no release/detach in listeners; (5) one `_ensureRegistration(` site); m7 check 10 FACTORED (`presence_only_log_scan`, Kotlin `Log.*` + Throwable patterns, `EXPECTED_LOG_FIXTURES`) + `PublishWakeLock.kt`; `check_location_access_gate.sh` tokens re-pointed if needed; ios header re-word (24 stays); `check_mls_session_single_owner.sh` three files | `background_location_disclosure_gate_test:124-147` same name/new token/same `gateAt < collectAt`; `session_reclaim_gate_test:338-410` anchors kept; `…reclaim_orchestration_test` same assertions; `…publish_cycle_test:250` sampler order; `…cycle_gates_test:115-138` + `streamListeners == 0`; `geolocator…_test:535-536,:851,:973` stay; harness `oneShotRequests == 0` (never `fixRequests`); `a declined handoff sends no paused signal` | B1 oracle steps 5–8 (parsed `Request[…]` + `ACQ=` age from device-stamped ≤ 5 s samples started before the drive; ≥ 55 s delivery spacing with the fixture pair; no-fix chain under forced idle); constant-derived 200 s hold; grammar fixtures in the same commit; B3/B5/B6/B9/catch-up/combined untouched | FA:198-201, :51-57; M7 §D/§5/§7/§9, :57-61 (incl. the NMEA/GnssStatus listener cost and the per-HAL indoor residual); P0_1 `:430-433` RESOLVED, `:382,:410-415`; CI_HARDENING `:1553-1556` note | `background_location_task.dart|80`, `background_location_manager.dart|52`, `geolocator_location_service.dart|85`; `background_fix_request.dart`, `publish_wake_lock.dart` `--list` rows; HOLD → tests; re-pin both rows |
| P2b [OD-P2-2, OD-P2-3] | none unless `SCHEDULE_EXACT_ALARM` is chosen (then a 13-locale round + `docs/privacy`) | NEW `INV-L-ANDROID-NO-PERMANENT-WAKE-LOCK` ("no permanent lock while battery-exempt; the plugin lock is kept only while the exemption is not granted; the native registration is issued only from `_ensureRegistration` and cancelled at both disable sites"); no ratchet | `check_android_location_power.sh` (1) flipped to the exemption predicate + native registration pins (channel-only `requestLocationUpdates(`, `cancelRegistration` at both disable sites) | `fgs_plugin_wake_lock_policy_test` flipped; native-registration harness tests incl. `a toggle-off with a dead service still cancels the native registration` | B1 step (6) inverted for the exempt run; toggle-OFF-with-force-killed-service oracle; the no-fix oracle as MERGE gate; forced-idle hardware row in BOTH exemption states | M7 §D/§5; FA:198-201 final | re-pin |
| P3 [OD1, OD-P3-b/c/d] | `locationSettingsIosGuidance` (base), NEW `locationSettingsIosCatchUp` (12 translations copied verbatim, rendered last), NEW `locationSettingsIosIndicatorArrow`, NEW `locationSettingsIosIndicatorBar`, `locationSettingsIosLimitedNote` ×13 + `@description`s; copy-tie lint + l10n tests with old-sentence forbidden lists | `INV-L-IOS-WAKES-RECEIVE-ONLY` amended (symbol + two host tests + copy-tie (c); assertion keys → `locationSettingsIosCatchUp` + `locationSettingsIosLimitedNote`); NEW `INV-L-IOS-INDICATOR-HONEST` (four assertion keys; host tests only), `INV-L-IOS-PUBLISH-INPUT-BEST-PROFILE-ONLY`; ONE ratchet item (`.assertion:locationSettingsIosGuidance` — the verbatim catch-up key move; deleted next commit) | `check_ios_background_publish.sh` checks 2/3/4/7/8/9/11/12/14 → `SELF_TEST_FIXTURES=47` (pinned at what lands); m7 check-10 list (+2 files, +2 planted fixtures) + check-13 name; repo-guards comment | `geolocator…_test:894-963` retired with the branch → route tests + Swift guard; cache family + "coarse never cached" + native clear + backgrounded-shortcut cases; doomed one-shot → `lastBestFix`; `location_provider_test:141-143,:153-154` → router pass-through; `background_location_provider_test:1333-1385` + three tier cases; `location_access_provider_test:424` reason; settings-page tests; b7 reason + session + `alwaysConfirmed` oracles; `ios_bg_publish` P1 tier-PINNED + status oracle, P2b bounded profile poll | `e2e-ios-background-publish` (WIU pinned; Always job under OD-P3-c); `e2e-ios-auth-tier.yml:13` header; b4 unchanged; `build-check` iOS green on the branch; **hardware 0a + 0a-provisional = WP3-2 merge gate** | M7 §6 0a (merge gate)/0a-provisional/0b/0c + `:69-73` + history; FA Unit F amendment + `:218-222`; MESH G-10; `CLAUDE.md:258`; service/auth-service comments ("not show"); `PrivacyInfo.xcprivacy` unchanged | `geolocator_location_service.dart|85` denominator drops → RATCHET; `ios_location_source.dart` `--list` row; Swift outside lcov |
| P4 [OD4, OD4-b] | none (the presence/one-connection sentences left with the Privacy page, 2026-08-29) | NEW `INV-R-BACKGROUND-PRESENCE-ONLY-AT-PUBLISH` (no disclosure key; FGS per-cycle shutdown; k-th-burst inbox); RC1 statement narrowed for circle relays + inbox-only residual named; no ratchet | `check_engine_pool_options` rewrite (13: `note_delivery_gap`-not-`forget_*`, `disconnect`-not-`shutdown`, no standing REQ from the burst entry — no order fixtures); ios +1 (48/25); check 13 token scan extended; `check_no_event_timestamp_cursor_advance.sh` green; 14b untouched; restart-budget guard UNCHANGED (the `isPaused` pin is a Dart source-order test) | `map_shell` predicate tests → coordinator socket-closed test + three-state row; FA:693-709 arm foreground-only test; banner test strengthened; `sharing_health_provider_test` paused-never-disconnected; coordinator lint (no `ref.watch`) | `ios_bg_publish` P2c IN-PROCESS (Bob alive, `isPaused` + decrypt marker, C7) + header + re-derived `DISABLE_WAIT_SECS`; `e2e-ios-live-sync` unchanged; b9 unchanged | SECURITY `:873-900` (+ inbox-only relay inference, OD4-b), `:257-263`, `:876-879`; M11 `:117,:121`; WN `:63,:130,:168-176,:653-656`; FA Unit C, `:45-47`, `:62-65`, `:835-845`, R14; M7 §6 observable; `map_page_location_access_test.dart:10`; CI_HARDENING `:165` note | `live_sync/|95`, `session.rs|94`: e2e tests in the same commit or HOLD; `background_burst_coordinator.dart` `--list` row |
| P5(a) [OD3] | none (Privacy page removed 2026-08-29) | `INV-R-PER-CIRCLE-PUBLISH-DECORRELATED` → accepted_deviation PUB-COALESCE (disjoint-relay linkage named in the deviation entry; no disclosure key); new deviation entry; `ratchet_override` (deleted next commit) | none new; wiring-test RNG fixture; jitter parity unchanged; stagger constants untouched | `location_publish_scheduler_provider_test:123-127,:146-151`; `publish_decorrelation_wiring_test` ×3 replaced incl. the n = 2..12 spread test; `location_publish_decorrelation_test` premises; `per_circle_due_tracker_test` seedStaggered group; `publish_stagger_test` + distinct-deltas test; `background_fix_request_test` horizon pin checked unaffected | none (unless a 2-circle target is funded) | SECURITY `:584-587` + new subsection; `ttl.rs:63-66`; README deviations; P0_1 `:83,:453`; CI_HARDENING `:1590`; `e2e_combined.dart:297` still true | — |
| P5(b) | none | none | none | scheduler provider tests renamed; wiring lint extended | none | header notes | — |

### 6.2 Promises → proof, per phase (LB = load-bearing verbatim; D = descriptive)

| Promise | P1 | P2 | P3 | P4 | P5 |
|---|---|---|---|---|---|
| LB ciphertext-only egress; payload = coordinate + timestamp; `raw_accuracy` skipped | `check_inner_location_kind.sh`, wire journal, `location_message_json_excludes_private_fields` | + FGS delivered-fix path via `encryption_pipeline_test` | + `resent_fix_payload_has_identical_shape` | same (burst uses the same encrypt path) | same |
| LB access gate above every read; cache = freshness not consent | `check_location_access_gate.sh`; service gate tests "suspension keeps the warm fix; opt-out clears it (at pause time)" | gate tokens re-pointed; `the gate precedes location COLLECTION…` name kept; registration-order test + single `_ensureRegistration(` site (guard count) | native stream enters through `getLocationStream` → cache tests unchanged; "coarse fix never cached"; native `lastBestFix` clears with the Dart cache; the backgrounded shortcut reads the native lifecycle | — | — |
| LB toggle OFF ⇒ no keep-alive/session/region/wake | `_onPaused` clears the cache synchronously on `!bg`; C4 watcher cancels the kept iOS stream directly | P2a: plugin lock kept (deliberate; guard (1) pins ABSENT); P2b: `allowWakeLock` bound to the exemption state (plugin lock kept while not exempt) pin; native registration cancelled at both disable sites, fail-closed receiver; scoped lock released on the toggle-off path | guard check 4 (`allowsBackgroundLocationUpdates = allowsBg`, derivation pinned), `check_arm_tier_policy` (disarm unconditional), provider disarm cases, `ios_bg_publish` P3, `a toggle-off pause leaves no native last-Best fix` | burst never runs with toggle OFF: C4 test + guard + P3 silence diff; a cancelled burst still pauses | — |
| LB iOS post-termination wakes receive-only | `background_claim_accuracy_test` ×5, m7 guards, ios check 13; fail-closed `appForegroundProvider` on a background launch | — | native owner refuses a background START (guard + source test) AND the one-shot is unreachable from a background launch (native `backgrounded` read; guard order pin + service test); no publish site in the Swift file (check 13 extended) | burst reachable only from the running process's tick (check 13 token scan on the coordinator) | — |
| LB no push / no telemetry SDK | guard 9/9b | — | — | — | — |
| LB per-circle decorrelation + ≥ 40 % CSPRNG jitter | `publish_decorrelation_wiring_test` ×3, `check_publish_jitter_fraction_parity.sh`, `location_test` 72/168 | same (sample drawn earlier, not differently) | same | same | OD3: status → accepted_deviation via override; the EXISTING 2–9 s CSPRNG stagger + distinct-deltas test; jitter parity unchanged |
| LB 228/168/60 TTL web; every interval ≤ 168 s in every profile | `privacy_copy_ties.rs` ×2 (the widening/narrowing bounds — the two copy pins left with the Privacy page, 2026-08-29), clock-skew parity, `location_test` | `worst-case inter-publish gap never exceeds kLocationPublishMaxInterval` (exhaustive, both API anchors, the 31–71 s sibling window); ≤ 30 bounded at 218 s | schedule identical in both profiles (scheduler never consults the profile) | burst bound tests (per-relay ack 5 s; in-flight publishes always complete; `BURST_BOUND < _publishLinkTimeout`; total < `kTtlNetworkBufferSeconds` on a quiet burst) | `kPublishStaggerMaxSpread` 30 s pins; n = 2..12 spread test; horizon decoupled |
| LB motion-trigger leak bounded; trigger only in UI isolate | `location_test` 100 m/60 s pins | "a delivery … publishes only that circle" (no early publish on displacement) | Best-while-moving test (movement detector raises the profile, does not publish); the 200 m undetected-move bound stated and tested | — | — |
| LB foreground sharing unpausable | `background_location_disclosure_gate_test` "foreground publisher still enforces its own gate"; ios check 6 | — | stationary profile never skips a tick (scheduler publishes the last Best fix) | — | — |
| LB presence-only logging | guard check 7 / m7 check 10 | check 10 FACTORED; Kotlin file listed; planted `Log.d("lat=$lat")` AND `Log.e(TAG, "x", e)` fixtures | Swift + Dart files listed + planted fixtures | — | — |
| LB single MLS session / single stream owner / single liveness port | `check_mls_session_single_owner.sh`, `check_liveness_port_single_owner.sh`, ios check 2 | unchanged (FGS isolate keeps its own plugin instance; no new isolate); lifecycle-exclusive ownership guard | check 2 → "one owner per platform" with fixtures | burst runs in the session-holder isolate (`rule14_…`, `session_guard_contention_test`) | — |
| LB Android asymmetry sentences + FGS notification literal truth | `fgs_notification_localized_test`, guards 14c/14d/14e | notification unchanged; "FGS still receives per tick" | — | Android untouched | — |
| LB live-sync live by default (14b) | 14b unchanged | — | — | 14b unchanged; background policy is a runtime three-state (`map_shell_test`) | — |
| LB consent record (Play dialog, iOS usage strings) | `location_disclosure_dialog_test`, `background_claim_accuracy_test` | same | same (no plist edit) | same | same |
| D `locationSettingsIosGuidance` 1st sentence | — | — | copy-tie tests (13 locales) + b7 | — | — |
| D service comment "indicator … transparency" | — | — | rewritten; reviewer item | — | — |
| D M7 §6 item 0 EXPECTED | — | — | rewritten; owner re-run recorded (P6-D) | + "no relay traffic between publishes" | — |
| D `e2e-ios-auth-tier.yml:13`, `ios_location_auth_service.dart:3-5` | P0 fixed the service comment | — | workflow header + comment | — | — |
| D `ios_bg_publish` P1 | — | — | WIU run pins its tier + native status oracle; Always job under OD-P3-c (keep-alive proof, never a pill oracle) | P2c in-process receive marker | — |
| D mechanism prose (`-1/1 m/1 s`, `best`) | — | FGS prose | native prose; P0 accuracy pins retired for iOS arms | — | — |
| D `kStreamPositionMaxAge` rationale | — | + "FGS delivered fix" | + "confirmed by a 100 m-tier fix" | — | — |
| D battery-opt strings; health thresholds; 5-min pill | unchanged | unchanged (exemption still requested) | unchanged | unchanged | unchanged |

**The four hardest cases, resolved:** (1) geolocator cache family + iOS "doomed one-shot": unchanged in substance under D1 because
the native stream enters through the same service seam; the one-shot stays geolocator so only the last-known `verifyNever` target
moves. (2) b5's 1 m/1 s discriminator: untouched (foreground; grep `AppLifecycleState` = 0 hits); its tripwire is the Android
foreground `AndroidSettings` pin at `geolocator_location_service_test.dart:749-751`. (3) b7's Always card: assertion unchanged,
reason changed, real pin added as a 13-locale copy-tie (and the manifest cites only the host tests — b7 `markTestSkipped`s).
(4) `ios_bg_publish` P1: the WIU run now PINS the tier it observed (a provisional escalation is a red, attributable run, not a
silent branch swap); the Always-shape runtime evidence is the OD-P3-c job plus b7's session-status + `alwaysConfirmed` reads,
and the pill itself is hardware-only. (5) The Android release on pause: a Riverpod rebuild cannot run while paused (§2.2a), so
the release is a service-level call and its test must not pump a frame or read the provider.

### 6.3 Risk register — FA wedge causes C1–C6 × phases, and the test that guards each

| Cause | P1 | P2 | P3 | P4 | P5 |
|---|---|---|---|---|---|
| **C1** Rule-14 guard orphaned (stop timed out → `reinstall_after_timed_out_stop`) | engine stop on Android pause w/ sharing OFF and `_onDetached` both use ONE `_stopLiveSyncBounded()` extracted from `_handOffMlsSession`; never `releaseForHandoff()` without an FGS to reclaim; `check_mls_session_single_owner.sh`, `mls_session_handle_release_test`, `map_shell_detached_release_test`, b1 `HANDOFF_CONFIRMED`; the debounced resume re-writes the ownership stamp | FGS cycle rewrite keeps reclaim ordering: `session_reclaim_gate_test`, `background_location_task_reclaim_orchestration_test`, `session_guard_contention_test` (e2e-integration); the paused signal only on a completed handoff | none (iOS has no handoff) | burst opens/closes the session in the holder isolate only: `rule14_…` + `check_mls_session_single_owner.sh` | none |
| **C2** stuck inbound row gates outbound | none | none | none | burst ORDER ingest-before-publish (Rust test, per-endpoint EOSE); drain-then-clear on pause (backlog test); Unit B sweep still runs inside the burst (test) | none |
| **C3** relay CLOSED, dead-but-running | `.ping(false)` on the ENGINE pool would remove the only traffic on a socket with standing REQs → call-shape guard check 5 + `engine_pool_keeps_ping_while_subscribed`; a leaked fetch REQ on the ping-less publish pool → `every_fetch_primitive_leaves_no_subscription_registered`; `RelayManager::subscribe` deleted | none | none | background: no standing REQ to lose (`background_burst_holds_no_standing_req`); stale relay-side REQs swept at pause and before open; a queued CLOSED cannot fire after open; `maintain_subscription_health` cannot reach `health_probe` while paused; foreground: 15-min tick unchanged (`health.rs` tests) | none |
| **C4** ratchet 1000 exhaustion | none (rate unchanged: `location_test` pins); bounded inbox lookback (P1) must not skip circle events: `cursor_poisoning_e2e.rs` kept; bound applies to the INBOX plane only | FGS interval ∈ [72,168] test | profile never changes rate | per-burst rate = per-tick rate (test) | per-circle rate unchanged (each circle once per interval — test) |
| **C5** non-Stable epoch / quarantined group | none | none | none | burst settles convergence before close; the marker ack + gauge check before `disconnect` (both inside `pause_subscriptions`, under the lifecycle lock) mean a pause can never cut a commit between SEND and OK; pending commit confirmed only on OK-ack (`check_e2e_publish_before_apply.sh`, `auto_commit.rs` at floor 100, `pause_never_disconnects_while_an_auto_commit_awaits_its_ok`) | none |
| **C6** `_startLiveSync` one-shot / heal hang / worker death / clock skew / handover race / wake lock | banner/maintenance gating must not touch `_liveSyncHealTimer` re-arm (`map_shell_receive_recovery_test`); the debounce fix must keep `_rearmLiveSyncHealTimer()` on the debounced path; B8's clock-rejection branch preserved through `publish_with_retry(1, …)` | P2a keeps the plugin lock so the no-fix watchdog stays punctual; P2b: cadence punctuality from delivery — hardware liveness column under forced idle + `dumpsys power` + the emulator no-fix oracle; STACKED faults (cold TTFF + a suspend gap) exceed 228 s — P2b risk named; handover drain budget unchanged (`check_teardown_drain_budget.sh`) | none | `_dispatchTick` carries the `.timeout(` (`check_location_access_gate.sh` check 8); `BURST_BOUND < _publishLinkTimeout`; NO timeout on commit-critical links; throw AND cancellation paths pause | burst spread ≤ 33 s so a hung circle cannot wedge siblings (`publishLinkTimeoutForTest` load-bearing) |
| **Unit F (R7)** stream (re)started while backgrounded | `resumeStream()` is the only restart site and runs from `_onResumed`; `appForegroundProvider` fail-closed on a background launch; the running build never watches the foreground provider (guard); a recovery edge while suspended never invalidates; no lifecycle action rides a rebuild (§2.2a; the no-frame test) | none | native `startUpdatingLocation()` only from a foreground entry (guard + sink-error test); the one-shot unreachable from a background launch (native `backgrounded` read) | none | none |

### 6.4 Rollback story — one commit re-inerts each phase

| Phase | The one-commit revert | What stays harmless |
|---|---|---|
| P0 | revert tests/docs | nothing behavioural |
| P1 | `RelayOptions` back to default + `RelayManager::subscribe` restored + Dart call sites back to `publishEvent` + guard checks/fixtures AND the `repo-guards.yml` self-test step reverted + `INV-R-PUBLISH-POOL-NO-KEEPALIVE` deleted (`ratchet_override.items: ["INV-R-PUBLISH-POOL-NO-KEEPALIVE.deleted"]`) + `cursor.rs` bound and its tests reverted; service gate calls removed; provider back to the toggle-only body; banner/extras/engine-stop/maintenance gates removed | a sleeping publish pool reconnects on next publish anyway; no persisted state |
| P2a | FGS back to the 72 s one-shot cycle, delete `PublishWakeLock.kt` + manifest permission + guard checks 1–6 + the m7 check-10 factoring/list entry (a listed-but-deleted file is red) + `INV-L-BACKGROUND-DISCLOSURE-GATE`'s added test/guard (rule 3/6) + `INV-L-ANDROID-BACKGROUND-SINGLE-GNSS-REQUEST` (`.deleted`), B1 oracle steps + fixtures back, `signalTask` calls removed | field devices keep the 72 s repeat either way; no persisted state |
| P2b | `allowWakeLock` default restored, native registration removed, guard (1) + lint test back to their P2a forms, `INV-L-ANDROID-NO-PERMANENT-WAKE-LOCK` (`.deleted`), B1 step (6) back | P2a stays in place |
| P3 | `getLocationStream` iOS branch back to the geolocator arm (`_streamSettings` iOS arm + `_kIosNoDistanceFilter` restored), the backgrounded shortcut and native clear back, session handler tier branch back, ios guard fixtures back to 24, ARB ×13 back (five keys), settings-page gating back, copy-tie tests deleted with their two invariants (override items) AND the `INV-L-IOS-WAKES-RECEIVE-ONLY` symbol/test additions and m7 check-10/13 list entries (rule 3 is red if a cited test goes while the symbol stays), b7/bg-lane oracles back; the Swift file may stay compiled and unused | the session handler's arm/disarm contract is untouched; the WIU pill is honest in both states |
| P4 | three-state pause row back to keep-socket, coordinator removed, standing REQ restored on iOS-bg, RC1 summary back, invariant deleted (override), P0's "today's truth" sentence re-applied in M11/SECURITY; Rust additions may stay (inert) BUT the `check_engine_pool_options` pause fixtures and the `isPaused` source-order test revert with the Dart | cursors untouched; the standing REQ resumes from the persisted cursor with P1's bounded lookback |
| P5(a) | per-circle schedulers restored, manifest status back to enforced (an UPGRADE needs no override — restore, do not override), PUB-COALESCE entry + SECURITY.md heading removed | the FGS batching model is pre-existing |
| P6 | revert the closure commit as a whole | — |

Each revert is verified by the same gates as the forward commit (`check_privacy_invariants.sh --baseline-ref`, guard self-tests,
`flutter test`, `cargo test`) — a revert that leaves a dangling citation or a stale override is itself red, which is the point.

### 6.5 Hardware measurement protocol — verbatim spec for `docs/POWER_MEASUREMENT.md` (created by P0-C)

**Common.** Same two phones every run (record model, OS build, Haven commit, build type = release wrapper
`scripts/build_release.sh`); 2-member circle (iPhone ↔ Android), background sharing ON on the device under test, the peer
publishing normally; screen off; Low Power Mode / Battery Saver OFF; Wi-Fi state FIXED per run and recorded (run the
stationary window on cellular-only once and Wi-Fi once — radio cost is per wake and differs); no other location app running;
phone unplugged for the whole window (Android batterystats only accrues on-battery); START STATE OF CHARGE fixed (80–90 %)
and start/end % recorded (iOS %/h drifts with SoC — rows at different SoC are not comparable). Record the iOS authorization
tier (Always confirmed / provisional / When-In-Use) and the Android fused backend (`dumpsys location | grep -i fused`).
**The liveness capture is MANDATORY:** every run records the relay-side `created_at` sequence for the device under test — a
hermetic strfry (or `nak req` against the owner's relays) capturing the `#h` REQ for the circle, summarised by the NEW
`tooling/e2e/ci/summarize-created-at-gaps.sh` (created by P0-C: reads a strfry export or `nak req` ndjson, groups by
`#h`, prints the largest consecutive `created_at` delta per circle with the offending pair, exit 1 above the given
bound; `--self-test` fixture pair — a healthy sequence passes, a 229 s gap fails; NOT `summarize-wire-journal.sh`,
which parses the wire-PROXY ndjson journal, `tooling/e2e/ci/summarize-wire-journal.sh:1-20`, and never a relay
capture) — and the column "max relay gap (s)" is that script's output. The
receiver's screen is NOT a liveness instrument: the Android peer's FGS fetch runs once per `kLocationUpdateInterval` and the
age pill thresholds at 5 min, so a receiver-side gap routinely reads 168 + 120 s on a healthy run. Threshold: ≤ 228 s
(`kLocationMessageRetention`) for a baseline row, ≤ 188 s for an acceptance row after P2a (D3 (iii)); today's derived worst
case is 240 s, so a baseline gap > 228 s is a P0 finding.

**Scenarios.** S (stationary): device on a desk, app backgrounded via Home — ≥ 3 h on iOS (Settings › Battery is
whole-percent: a ≤ 1 %/h target needs ≥ 3 counts, and a relative threshold whose baseline is < 4 % over the window is not
resolvable — extend the window), 60 min on Android. W (walking, 30 min): normal walk, phone in pocket.

**iOS.** (1) On-device Energy Log — the PRIMARY iOS metric: Settings → Developer → Logging → Energy → start before
backgrounding, stop after; import into Xcode Instruments (File → Import Logged Data from Device) and read the Haven process
energy impact + Location/Network subcomponents — avoids Xcode-attached runs, which keep the process alive and skew the result.
(2) Settings → Battery → screenshot "Last 24 Hours" per-app row for Haven (%, on-screen vs background minutes) at T0 and
T0+window (iOS has no reset; subtract) — the SECONDARY metric. (3) Device console (Xcode → Devices → Open Console) filtered on
`locationd` for `"Location subscription"` RunningBoard assertions, `runningboardd` `Suspending task` (M7:829-835 recipe) —
the liveness oracle that replaces the pill in item 0 — and the client's `desiredAccuracy` lines, from which the "profile duty
(% at Best)" column is computed (the number OD-P3-a is re-tuned on). (4) Note whether the status-bar indicator (pill vs arrow
vs none) is visible at T0+5 min and at the end.

**Android.** `adb tcpip 5555` before unplugging (or reconnect only at the end). `adb shell dumpsys batterystats --reset` →
`--enable full-wake-history` → unplug → run S then W → at the end: `adb shell dumpsys batterystats > bs.txt`,
`adb shell dumpsys batterystats --checkin > bs.checkin`, `adb bugreport br.zip` (Battery Historian). During the run (over Wi-Fi
adb, ~every 15 min): `dumpsys location` (Haven's live registrations: provider, interval as `@+1m40s0ms`, `minUpdateDistance`,
foreground flag; AND the "gnss status listeners" / "nmea listeners" counts — the plugin registers both, §2.2),
`dumpsys power | grep -A3 -i 'wake lock'` (PARTIAL locks held by Haven's uid and their `ACQ=` age), `dumpsys gnss` (fix count,
TTFF, "GNSS Power" if the HAL reports it, `CAPABILITY_SCHEDULING` — I-P2-1). P2b rows additionally run under
`dumpsys deviceidle force-idle`, screen off, cellular. Metrics from `bs.txt` under Haven's uid: the `GPS` sensor time line,
`Wake lock … partial` time, `Mobile radio active` time, `Wifi` scan/running, `CPU` user+system; plus the per-uid share of
discharge. Battery Historian: `mobile_radio`, `gps`, `wake_lock` bars.

**Results template** (one row per run): `date | commit | platform+OS | scenario | network | tier/backend | start→end SoC % | duration | Energy Log impact | iOS Δ% + bg minutes | profile duty (% at Best) | Android GPS sensor s | wake-lock s | mobile-radio active s | discharge share | max relay gap s | relay capture file | indicator seen | notes`.
Baseline rows go under `## Baseline <date> <commit>`; acceptance rows under `## Acceptance <date> <commit>`; the P3 0a and
P2b forced-idle merge-gate rows under `## Merge gate <phase> <date> <commit>`.

### 6.6 Hardware acceptance thresholds (owner-run; absolute AND relative, with a liveness clause)

| Metric | Threshold (absolute) | Threshold (relative to P0 baseline) |
|---|---|---|
| iOS, background sharing ON, stationary ≥ 3 h, confirmed Always | ≤ 1 %/h on the Energy Log impact (Δ% secondary; reachable after P1+P3+P4; I: 1.5–2.5 %/h after P3 alone) | ≤ baseline/4 (only resolvable if the baseline is ≥ 4 % over the window — else extend) |
| iOS, same, When-In-Use / provisional | ≤ 1.5 %/h (pill + activity session held; I) | ≤ baseline/3 |
| iOS, walking 30 min | no absolute (GPS-grade by design) | ≤ baseline/2 |
| Android, stationary 60 min (P2a) | GPS sensor time ≤ 10 % of window; mobile-radio active ≤ baseline/3; the plugin lock is EXPECTED (P2a keeps it) | GPS time ≤ baseline/8 |
| Android, stationary 60 min under forced idle (P2b merge gate), run in BOTH exemption states | exempt: `dumpsys power` shows NO `ForegroundService:WakeLock` and NO Haven partial lock older than 30 s at any sample, partial wake-lock time ≤ 1 % of the window; non-exempt: the plugin lock is EXPECTED (conditional policy) and GPS time still ≤ 10 %; both: indoor/no-fix publishes continue, relay-side gaps ≤ 228 s | — |
| Both | max relay-side `created_at` gap ≤ 228 s in a baseline row, ≤ 188 s in an acceptance row after P2a (liveness); indicator state as D2 predicts for the recorded tier; profile duty recorded | — |

If a row fails its absolute but passes its relative threshold, the phase is not rejected — the absolute figures are
extrapolations (Evgenii's bare-session numbers; no Apple mA table exists) and the owner re-sets the absolute from the
measured value in `POWER_MEASUREMENT.md` with the reason. A power win that reopens the 2 h wedge fails on the liveness clause;
a merge-gate row (P3 0a, P2b forced idle) that fails its liveness clause blocks the phase, not the release.

---
## 7. Appendices

### 7.1 Consolidated ARB key changes (13 locales: en, ar, de, es, fa, fr, hi, ja, ne, pt, ru, tr, ur; workflow per CLAUDE.md l10n rule)

Only surfaces that still exist: the four Privacy-page rows v3 carried here (presence, one-connection, jitter detail, the activity-pattern band note) left with the page on 2026-08-29; their gating facts survive in D6 (vi)/D7 and `haven-core/SECURITY.md`.

| Key (`app_en.arb`) | New English text | `@description` (essentials) | Phase | Copy-tie test |
|---|---|---|---|---|
| `locationSettingsIosGuidance` (`:473`) — becomes the tier-neutral BASE | "While background sharing is on, Haven keeps a location session running so your circles keep seeing you." | iOS-only reliability card, rendered ONLY under `IosAuthStatus.always` (the page gate changes from `!iosLimited`, which also rendered it under denied/notDetermined/restricted/unknown), composed in this ORDER: base → exactly ONE of the two indicator keys (chosen by the session handler's `backgroundActivitySessionHeld` — never by tier) → the catch-up key, so VoiceOver hears session → indicator → catch-up and the termination sentence comes last. MUST NOT name any indicator ("blue", the phrase "blue location bar", "arrow", "indicator" — bare "bar" is not a forbidden word), make a battery promise ("low-power" is banned — the session is at GPS accuracy while moving or on screen), or say "pause"/"timer". The accuracy tier lives HERE, not in the copy: while stationary in the background the session runs at ~100 m accuracy and returns to GPS accuracy on movement. | P3 | `ios_indicator_copy_accuracy_test.dart` (en ↔ Swift), `l10n/location_settings_copy_accuracy_test.dart` (13 locales), `pages/location_settings_page_test.dart` (asserts the render order); b7 as a lane oracle |
| NEW `locationSettingsIosCatchUp` | "Granting \"Always\" additionally lets Haven catch up on your circles after iOS closes the app." | The catch-up sentence MOVED verbatim out of `locationSettingsIosGuidance` into its own key so it can render LAST; the 12 translations are COPIED byte-for-byte from the existing guidance values (no re-translation; the rule-12 sweep and copy-tie clause (c) stay valid). It carries the `INV-L-IOS-WAKES-RECEIVE-ONLY` assertion (a key MOVE — the ratchet sees a dropped assertion key on the guidance key → one `ratchet_override` item, §7.3). Must keep saying catch-up, never resumed sharing. | P3 | copy-tie clause (c); page order test |
| NEW `locationSettingsIosIndicatorArrow` | "iOS shows its small location arrow in the status bar while Haven uses your location, and lists Haven in your iPhone's Location Services settings." | Selected when the handler holds NO activity session = CONFIRMED Always (`alwaysConfirmed`, D2). Tier-neutral Settings wording on purpose: iOS 15 (deployment target 15.5) has "Settings → Privacy → Location Services", iOS 16+ "Privacy & Security" — a version split localizers cannot fix; use the OS's localized "Location Services" name. Breadcrumbs, where any, use "→" (read by screen readers; the ARB convention, `locationSettingsAndroidBattery` `:465`), never "›". Never "blue" nor the phrase "blue location bar" ("status bar" is required — bare "bar" is fine). If OD1 is declined this key is never selected — say so here. | P3 | same tests |
| NEW `locationSettingsIosIndicatorBar` | "While Haven shares in the background with this permission, iOS shows its blue location bar at the top of the screen." | Selected when the handler holds a `CLBackgroundActivitySession`: provisional Always, iOS 17 Always, and — if OD1 is declined — every Always. ONE noun everywhere: "blue location bar" (never indicator/pill). This key IS the OD1-declined variant of the card, so the copy-tie test has a target in both outcomes. | P3 | same tests |
| `locationSettingsIosLimitedNote` (`:453`) | "Sharing keeps working in the background with your current permission, and iOS shows its blue location bar at the top of the screen while it does. Choose 'Always' for Haven in Settings so Haven can also catch up on your circles' locations after iOS closes the app. Your own sharing resumes when you reopen Haven." | Renders only under While-In-Use. Sentence order is state → advice → resume (the bar sentence is NOT appended after "resumes when you reopen Haven" — disjointed). The bar sentence is TRUE there on iOS 15–26 (mandatory OS behaviour, QA1965; Haven also holds a `CLBackgroundActivitySession`). Under confirmed Always the card shows the arrow key instead — never merge the two. `background_claim_accuracy_test.dart:106-138` passes either way (V). | P3 | same tests |
| NEW `settingsLocationSubtitleOn` / `settingsLocationSubtitleOff` | "Background sharing on" / "Only while Haven is open" | Dynamic subtitle of the Settings hub Location tile, driven by `backgroundSharingProvider`; merges into the tile's semantics (name = title + subtitle; a hub tile has no toggle state to announce); it reports the SETTING, never service health — "Only while Haven is open" is true on both platforms with the toggle off — the one standing affordance that says what the app is doing without a map-shell indicator (no Always-tier reference app has one; a foreground-only banner would compete with the two fault banners); no platform words, no indicator words. | P3 (adopted bar-raise) | widget test from the provider (both values; semantics label contains the subtitle) |
| `fgsNotificationSharing`, `locationSettingsBatteryOptNote`/`AndroidBattery`, `locationSettingsIntro`/`ToggleSubtitle`, `LocationDisclosureStrings.*`, the Play dialog, `fgsChannelDescription` | UNCHANGED — each stays literally true (§3 D1/D3/D4/D6 proofs; verified by the UI/UX review) | — | all | existing tests |

### 7.2 Consolidated guard changes

| Script | Check | What it pins | Fixtures / count | Phase |
|---|---|---|---|---|
| `scripts/ci/check_engine_client_options.sh` | RESTRUCTURED into function-shaped checks returning rc (`check_publish_pool_options`, `check_engine_pool_options`, `check_ffi_add_relay`; every check runs; `exit 2` for missing paths) + checks 3–7 + `--self-test` (none today) + a `--self-test` step in `repo-guards.yml` | `fn publish_relay_options` body has `.ping(false)`, `.reconnect(false)`, `.sleep_when_idle(true)`; every `.add_relay(` in `manager.rs` is `pool().add_relay(`; `session.rs` has neither the CALL `\.ping[[:space:]]*\([[:space:]]*false` nor `\.sleep_when_idle[[:space:]]*\(` (the bare word is in two kept comments); `api.rs` has no `.add_relay(` except the `// e2e helper` at `:11875`; `manager.rs` has no `subscribe_to(`/`subscribe_with_id_to(` | `SELF_TEST_FIXTURES=10` by equality (clean; comment with bare `sleep_when_idle` PASSES; `verify_subscriptions(true)`; pin deleted; `ping(true)`; fn missing; bare `client.add_relay(`; `.ping(false)` call in session.rs; `.sleep_when_idle(true)` call in session.rs; `subscribe_to(` in manager.rs) | P1 |
| same | `check_engine_pool_options` REWRITTEN | + `fn pause_subscriptions` body reaches `note_delivery_gap` (directly or via the `Pause` marker), contains NO `forget_` token, contains `client.disconnect()` and NO `client.shutdown()`; no standing-REQ call reachable from the burst entry — NO call-order pins | 13 (+`forget_inbox_subscription` in the pause path; `client.shutdown()` instead of `disconnect()`; a standing-REQ call in the burst path) | P4 |
| `scripts/ci/check_android_location_power.sh` NEW (repo-guards step after "Location access gate …" `:709-721`) | (7)(8) | `suspendStream(` precedes `markForegroundActive(active: false)` in `_onPaused`; that call sits inside a `shouldKeepLocationStreamWhilePaused(` conditional, never a raw platform branch | 2 pairs | P1 |
| same | 1–6 (function-shaped) | (1) `ForegroundTaskOptions(` slice (comment-stripped) has NO `allowWakeLock` — P2a; (2) `PublishWakeLock.kt` shape (`PARTIAL_WAKE_LOCK`, `setReferenceCounted(false)`, `coerceIn(1L, MAX_TIMEOUT_MS)`, `MAX_TIMEOUT_MS = 30_000L`, no bare `acquire()`, NO `setMethodCallHandler(null)`/`release()` inside the lifecycle listeners) + `addTaskLifecycleListener(PublishWakeLock)`; (3) manifest `WAKE_LOCK`; (4) `getLocationStream(` called only from `location_provider.dart` + `background_location_task.dart`; (5) exactly ONE `_ensureRegistration(` call site, inside `_publishCycle` after both gates, `_cancelRegistration(` before `_inFlightPublish?.timeout(` in `onDestroy`; (6) background arm has no `timeLimit:`, has `forceLocationManager: true` + `distanceFilter: 0` | each check one passing + one mutated, pinned by equality | P2a |
| same | (1) flipped + native pins | `allowWakeLock:` bound to the exemption predicate (`!isIgnoringBatteryOptimizations`), never a literal; native registration acquires inside the delivery hold; no `requestLocationUpdates(` outside the channel handler; `cancelRegistration` at both disable sites; the receiver re-reads the toggle + both disclosure prefs | +5 | P2b |
| `scripts/ci/check_ios_background_publish.sh` | 5 → function-shaped `check_stream_provider` | `locationStreamProvider` body: `ref.watch(backgroundSharingProvider)`, `getLocationStream(backgroundSharingEnabled:`, `ref.read(appForegroundProvider)`; no `getLocationStream(` inside the not-foregrounded block; no `ref.watch(appForegroundProvider)` outside it | 4 (passes; foreground build watches; start inside the paused block; body commented out) → 23 | P1 |
| same | header + check 2 comment | "one plugin boundary; one owner per isolate, exclusive by lifecycle" | none (24) | P2a |
| same | 2, 3, 4 (→ `check_ios_stream_route` incl. `lastBestFix(` before `getCurrentPosition(` and `clearLastBestFix(`), NEW `check_native_stream_handler` (16: incl. `allowsBg` derivation, `?? true`, `!= .active`, `return FlutterError(`, `bestSince`, `onCancel` clear), 8 (→ `check_arm_tier_policy` carrying all eight existing pins + `alwaysConfirmed` + the background guard), 7, 9 (wiring order), 11 + 12 (→ `check_bg_publish_drive`, native source provider banned), NEW 14 (pbxproj ×4), file list, header (`-1` trap moot), `OK:` line | §5.3 Guards | `SELF_TEST_FIXTURES=47` expected (8 route + 16 native + 7 tier + 2 drive + 9 region + 5 provider), pinned by equality at what lands | P3 |
| same | 6 neighbourhood | iOS pause branch calls `pauseSubscriptions` on the C4 edge | +1 (48; 25 if before P3) | P4 |
| `scripts/ci/check_m7_native_wake_guards.sh` | 10 FACTORED into `presence_only_log_scan <file>` + a second fixture block (`EXPECTED_LOG_FIXTURES` by equality); `LOG_FN` + `Log\.[dweiv]\(`; error-internals + the Kotlin 3-arg Throwable form and `\$\{?e\b`; 13 list | + `PublishWakeLock.kt` (P2a); + `HavenLocationStreamHandler.swift`, `ios_location_source.dart` (P3); check 13 + `locationStreamHandler` (P3) | today's six files pass; `Log.d("lat=$lat")` fails; `Log.e(TAG, "x", e)` fails; `Log.d(TAG, "acquire")` passes; `NSLog("\(location.coordinate)")` fails; one planted-coordinate fixture per new file | P2a, P3 |
| `scripts/ci/check_live_sync_restart_budget.sh` | UNCHANGED | it is a numeric-derivation guard over `config.rs`/`cursor.rs`/`live_sync_resubscriber.dart`/`location.dart`; the "`_onResumed` references `isPaused` beside `shouldReanchorOnResume`" pin is a source-order TEST in `map_shell_location_access_lifecycle_test.dart` | — | P4 |
| `scripts/ci/check_location_access_gate.sh` | 1–3 (name-bound); 8 | re-pointed only if `_publishCycle`'s read path changes; `getLocationStream(` order pins; `getLastKnownPosition(` token kept by the helper name; check 8 resolves `_dispatchTick`'s `.timeout(` (P4) | `--self-test` | P2a, P3, P4 |
| `scripts/ci/check_mls_session_single_owner.sh`, `check_liveness_port_single_owner.sh`, `check_teardown_drain_budget.sh`, `check_no_event_timestamp_cursor_advance.sh`, `check_publish_jitter_fraction_parity.sh`, `check_e2e_publish_before_apply.sh`, m7 14b, `check_no_key_logging.sh` (key material only — it does not check URLs) | unchanged | must stay green (run them) | — | all |
| `tooling/e2e/ci/run-b1-fgs-publish.sh`, `run-ios-bg-publish.sh`, `run-b7-ios-auth-tier.sh`, `run-b9-network-reconnect.sh` | lane self-tests | B1 oracle steps 5–8 with the `dumpsys location`/`dumpsys power` grammar fixtures and the 55/54 s pair in the same commit; bg-publish P1 tier pin + status oracle, P2b bounded poll, P2c in-process marker (+ C7, + `ALWAYS_SESSION_OK` in the Always job); b7 session + `alwaysConfirmed` oracles; b9 `PUBLISH_AFTER_IDLE_OK` asserted from the first landing | per lane `--self-test` (B1 14 → 16+) | P2a, P3, P4, P1 |

### 7.3 Consolidated `docs/privacy/privacy_invariants.json` changes

| Id | Phase | New / edit | Status | Keys | Override needed? |
|---|---|---|---|---|---|
| `INV-R-PUBLISH-POOL-NO-KEEPALIVE` | P1 | NEW (symbols `publish_relay_options`, `build_engine_client` — rule 2 matches the last token, so `RelayManager::new` would be vacuous; tests incl. `every_fetch_primitive_leaves_no_subscription_registered`) | enforced | none | no (deleting it on rollback: `.deleted`) |
| `INV-L-BACKGROUND-DISCLOSURE-GATE` | P2a | edit (tests/guards/statement additions; cited test name kept) | enforced | unchanged | no |
| `INV-L-ANDROID-BACKGROUND-SINGLE-GNSS-REQUEST` | P2a | NEW (interval ≥ `kMinFixRequestInterval`; ≥ 62 s for the circle just published) | enforced | none | no |
| `INV-L-ANDROID-NO-PERMANENT-WAKE-LOCK` | P2b (NOT P2a — the plugin lock is kept there on purpose) | NEW | enforced | none | no |
| `INV-L-IOS-WAKES-RECEIVE-ONLY` | P3 | edit (symbol `HavenLocationStreamHandler.swift::onListen` + host tests `ios_location_source_test`, `geolocator_location_service_test` backgrounded-cold-cache + copy-tie clause (c) — the first tests that read its assertion keys; statement; assertion keys → `locationSettingsIosCatchUp` + `locationSettingsIosLimitedNote`: the catch-up sentence moves verbatim into its own key) | enforced | `locationSettingsIosGuidance` → `locationSettingsIosCatchUp` (verbatim move) | **YES**: `items: ["INV-L-IOS-WAKES-RECEIVE-ONLY.assertion:locationSettingsIosGuidance"]`, reason names the byte-identical move; deleted in the next commit |
| `INV-L-IOS-INDICATOR-HONEST` | P3 | NEW (host tests ONLY — b7 `markTestSkipped`s and rule 4 rejects integration-test citations) | enforced | assertion `locationSettingsIosGuidance`, `locationSettingsIosIndicatorArrow`, `locationSettingsIosIndicatorBar`, `locationSettingsIosLimitedNote` | no |
| `INV-L-IOS-PUBLISH-INPUT-BEST-PROFILE-ONLY` | P3 | NEW ("delivered under the Best profile", not "GPS-grade"; native + Dart copies clear together; equal serialized length on re-send) | enforced | none | no |
| `INV-R-BACKGROUND-PRESENCE-ONLY-AT-PUBLISH` | P4 | NEW (FGS per-cycle shutdown; inbox REQ every k-th burst; in-flight publishes always complete) | enforced | none | no |
| `INV-R-CROSS-PLANE-CORRELATION` (RC1) | P4 | edit (statement narrowed for circle relays AND extended with the inbox-only-relay cadence residual; `accepted_deviations[RC1].summary` amended — "strictly narrows" is not claimed) | accepted_deviation | none (its Privacy-page keys were deleted 2026-08-29) | no (narrowing + a named residual) |
| `INV-R-PER-CIRCLE-PUBLISH-DECORRELATED` | P5(a) | edit: status enforced → accepted_deviation `PUB-COALESCE`; tests renamed; statement rewritten | accepted_deviation | none (a zero-disclosure accepted deviation is permitted since 2026-08-29) | **YES**: `items: ["INV-R-PER-CIRCLE-PUBLISH-DECORRELATED.status"]`, reason ≥ 40 chars; deleted in the next commit |
| `accepted_deviations[]` `PUB-COALESCE` | P5(a) | NEW entry (`source` = `haven-core/SECURITY.md#coalesced-multi-circle-publish-bursts-pub-coalesce`, a heading P5 creates — rule 15) | — | — | — |
| `INV-R-TRAFFIC-METADATA-OBSERVABLE`, `INV-L-MOTION-TRIGGER-BOUNDED`, `INV-W-445-EXPIRATION-WINDOW`, `INV-L-ANDROID-REBOOT-RESURRECTS-PUBLISHING`, `INV-R-ENGINE-NO-GOSSIP-NO-AUTH` | — | cited test names kept (`'the production stagger draws from a CSPRNG'`, `location_test` names) | unchanged | unchanged | no |
| Rollback of any phase that ADDED an invariant | — | deletion | — | — | YES: `<INV-ID>.deleted` in the revert commit |

### 7.4 Consolidated red tests → replacement assertions

| Phase | Goes red | Replacement (never weaker) |
|---|---|---|
| P1 | `location_provider_test.dart:157` "rebuilds the stream with new settings when the toggle flips" | still true in the foreground (the provider body stays toggle-driven); the not-foregrounded cases use `container.listen` + `FakeAsync`, never `await …future` (the placeholder never completes) |
| P1 | `map_shell_test.dart` truth tables | additive rows only (keep rule, engine leg, extras throttle) |
| P1 | `location_stream_error_handling_test.dart:452-501` (≥ 2 listeners) if a listener moves | keep ≥ 2; the service's outer controller counted as a listener handling non-data states |
| P1 | every mock `RelayService` (37 files) | gains `publishLocationEvent` (compile error, not behaviour) |
| P1 | `b9_network_reconnect_test.dart` doc `:20-45` | doc states the two pools differ; assertion ADDED from the first landing (publish acked after outage) |
| P1 | `cursor.rs::inbox_subtracts_7_days_regardless_of_phase` (`:419`), `:421-428`, `:483`, `:500`, the `since_for_stream` doctest | `inbox_initial_subtracts_seven_days` + `inbox_resubscribe_subtracts_two_days_plus_one_hour` + `inbox_resubscribe_lookback_covers_nip59_backdating_plus_skew` (both phases pinned by exact value — never weaker) |
| P2a | `background_location_disclosure_gate_test.dart:124-147` (`collectAt == -1`) | same name, same `gateAt < collectAt`; registration-order sibling added on `_ensureRegistration(` |
| P2a | `session_reclaim_gate_test.dart:338-410` source-order pins | anchors kept verbatim → green; if a token must move, same order promise |
| P2a | `background_location_task_reclaim_orchestration_test` (if `_publishCycle` signature changes) | same orchestration assertions |
| P2a | `background_location_task_publish_cycle_test.dart:250` | `dueOf == publishStart + J` kept; sampler call order changes |
| P2a | `background_location_task_cycle_gates_test.dart:115-138` | extended with `streamListeners == 0` |
| P2a | harness `fixRequests` oracles (counts every `getCurrentLocation()` call, which the cycle must still make) | `oneShotRequests` (incremented only on a cache miss) — the same promise, a non-inverted oracle |
| P2a | B1 hold literal `Duration(seconds: 200)` + comment "2 ticks (144 s) plus slack" | `kLocationPublishMaxInterval + 32 s` (value unchanged; no window widens); `dumpsys location`/`dumpsys power` parsed oracles + ≥ 55 s spacing + no-fix chain ADDED |
| P3 | `geolocator_location_service_test.dart:894-963` (iOS `AppleSettings`, `:917`, `:919`, `:958`) | retired with the branch → iOS-route tests (R8 on the listen argument) + Swift guard check `check_native_stream_handler` + lane runtime |
| P3 | `geolocator_location_service_test.dart:1134-1153, :2017-2035` (doomed one-shot) | same promise ("never the one-shot"); fallback `iosSource.lastBestFix()`; PLUS the backgrounded-cold-cache case keyed off the native `backgrounded` read |
| P3 | P0's five-way accuracy test (iOS stream arms) | Android arm + both one-shots kept; iOS stream accuracy pinned by the guard's two-tier rule |
| P3 | `location_provider_test.dart:141-143,:153-154` (`:142` `showBackgroundLocationIndicator`) | provider→router pass-through; the indicator policy asserted natively (lane) + copy-tie + guard |
| P3 | `location_access_provider_test.dart:424` reason text | prose only; assertion unchanged |
| P3 | ios guard fixtures (24 after P1) | rewritten set, 47 expected, count pinned by equality |
| P3 | `ios_bg_publish_test.dart` P1 `:751-765` (accepts WIU or provisional Always) | the WIU run PINS `tier == whenInUse` (a tier flip is a red run, not a silent branch swap) + `held == true` + native `status()` oracle; P2b bounded profile poll; the Always shape gets its own job |
| P3 | b7 `:386-390` reason | prose + session-held oracle per tier + `alwaysConfirmed == true` under the full grant |
| P3 | `ios_background_session_service_test.dart` fixed 3-key parser cases | gain `alwaysConfirmed` (and `indicatorShown` if the Always job reads it) |
| P4 | `map_shell` static tests for `shouldKeepRelayConnectedWhilePaused` | deleted with the predicate; coordinator socket-closed test + three-state row |
| P4 | FA:693-709 silence-arm test (if one exists for background) | "does not fire while backgrounded on iOS" |
| P4 | `sharing_health_banner_test.dart:241` | "…while foregrounded and not at all while backgrounded" |
| P5(a) | `location_publish_scheduler_provider_test.dart:123-127,:146-151`; `publish_decorrelation_wiring_test` ×3 names; `location_publish_decorrelation_test` timer-independence premises; `per_circle_due_tracker_test` `seedStaggered` group | burst assertions with the EXISTING 2–9 s CSPRNG stagger; the n = 2..12 spread test; `encryptConcurrencyPeak == 1` kept; every `greaterThan(1000)` / "order varies" kept; manifest citations renamed in the same commit; `publish_stagger_test:125-144` and `background_fix_request_test`'s horizon pin do NOT go red (constants untouched; horizon decoupled in P2a) — recorded as checked collateral |
| P5(b) | `location_publish_scheduler_provider_test` two names | master-timer assertions; wiring lint extended to both planes |

### 7.5 Open questions — V/I/U ledger (who resolves, when)

| Id | Tag | Question | Resolver / when |
|---|---|---|---|
| V-P0-1 | V | `circle_details_layout_test.dart` can import `sharing_health_provider.dart` without a Riverpod dependency the harness lacks | P0-A implementer |
| V-P0-2 | V | `map_shell.dart` `_onResumed` is set-not-gated by the overlap guard | P0-B implementer before editing `location.dart:49-50` |
| U-P0-1 | U | WN doc's Android-15 6 h `location` FGS timeout claim | P0-B, developer.android.com "Foreground service timeouts" |
| U-P0-2 | U | goldfish HAL raises GPS "navigating" (bears only on the dropped batterystats oracle) | nobody needs to; recorded |
| V-P1-1 | U (not load-bearing) | whether the iOS engine populates `initialLifecycleState` on a background launch — `readInitialLifecycleStateFromNativeWindow` (`services/binding.dart:295-299`) applies it only when non-empty; if empty, `lifecycleState == null` maps the `appForegroundProvider` default to `true` (fail-open). Harmless: the native start refusal and the `backgrounded` read (D1) are the gates | P1-A1 (observe on an SLC relaunch; nothing depends on it) |
| V-P1-2 | **V** | `ClientOptions::default().autoconnect` does not spawn a connect on `pool().add_relay` (`pool/mod.rs:257-262`; `client/mod.rs:305-308`); `RelayOptions::default()` equals `compose_relay_opts`' output for the default `ClientOptions` (`client/mod.rs:232-283`) | closed by the Rust review |
| V-P1-3 | V | cancelling the geolocator subscription while paused does not trip `StreamHandlerImpl.setActivity(null)`'s `stopListening()` (`StreamHandlerImpl.java:46-53`) — "Geolocator position updates stopped" once in logcat; the FGS engine's cancel under-counts `listenerCount` on the shared bound service (`GeolocatorLocationService.java:86-90,127-131`) — harmless today | P1-A2 on device |
| V-P1-4 | V | `sharing_health_banner.dart:200` timer fires while backgrounded (the red test decides; drop the item if it cannot fail) | P1-A3 |
| V-P1-5 | **V** | `RelayManager::subscribe` (`manager.rs:660-700`) has no caller | closed by grep 2026-08-29 |
| I-P1-1 | I | real-network `Sleeping` timing 60–70 s | hardware; not a correctness input |
| V-P2-1 | V (pre-stated) | `dumpsys location` `Request[…]` / `dumpsys power` `ACQ=` grammar on the CI API-34 image — derived from `LocationRequest.toString()` / `WakeLock.toString()` (§2.2) | P2a-6: shell fixtures in the SAME commit; the first run confirms |
| V-P2-2 | V | first FGS stream listen after `onStart` receives events (plugin service bind complete) | P2a-6 via `[BackgroundTask] registration armed` + delivery in B1 |
| V-P2-3 | **V** | `PowerManager.WakeLock.acquire(timeout)` on a held non-refcounted lock re-posts the release timer; `release()` when not held is a no-op (`PowerManager.java:3930-3950, 3984-4000`) | closed by the Android review |
| V-P2-4 | **V** | `addTaskLifecycleListener` from `Application.onCreate` precedes the boot-restart engine (`ForegroundService.kt:45-54,173-178`, `ForegroundTask.kt:47-70`, `RebootReceiver.kt:43-46`) | closed; confirm on `adb reboot` (M7 runbook step 7) |
| I-P2-1 | I | HAL `CAPABILITY_SCHEDULING` on the owner's phones (`dumpsys gnss`) — also decides the indoor residual (60 s search vs chip policy) | informational, hardware run |
| I-P2-2 | I | GMS `fused` duty-cycles a 60–158 s HIGH_ACCURACY request (attested developer behaviour; GMS is closed) | hardware gps time; remedy = P2b native registration naming the provider (no plugin `gps` fallback exists) |
| U-P2-1 | U (P2b only) | delivery→Dart wake window on aggressive suspend — consequence = a one-cycle TTL breach (D4) | P2b hardware under forced idle; OD-P2-2; closed by construction with the native registration |
| V-P3-1 | V | simulator delivers `simctl location set` fixes under `kCLLocationAccuracyHundredMeters` (I: yes) | WP3-5 bounded profile poll |
| V-P3-2 | V/I | live `desiredAccuracy` change on a running backgrounded session honoured without restart | owner device, M7 §6 0a (merge gate) |
| V-P3-3 | U → merge gate | the CONFIRMED-Always shape (no activity session, flag false, 100 m / no filter) keeps a foreground-started session delivering for HOURS on iOS 17/18/26 (Apple guarantees delivery for the shape but "takes no measures … when it has nothing to deliver") | owner device, M7 §6 0a ≥ 2 h — a WP3-2 MERGE gate; the provisional cohort no longer depends on it |
| V-P3-4 | U → 0a-provisional row | `CLServiceSessionDiagnostic` values observed under provisional Always (two of three properties have empty doc abstracts) | owner device, iOS 18+; b7's full grant observes the confirmed case in CI |
| V-P3-5 | U | stuck-indicator reproduction after `disarm()` on iOS 18/26 | owner, M7 §6 0c; Apple Feedback if reproduced |
| I-P3-1 | I | delivery rate at 100 m/no filter on a stationary device (drives the 84 s escalation frequency; the profile-duty column) | hardware log |
| V-P4-1 | **V** | `Client::disconnect` mid-`send_event` yields `Err(PrematureExit)`/`Err(NotConnected)` (`inner.rs:1255-1270, :1382-1389`) — never a false confirm; the in-flight gauge prevents the disconnect | closed by the Rust review |
| I-P4-1 | I | 5 s backlog wait vs strfry EOSE ~100 ms (`config.rs` §P-15) — expected never to bind | owner's relays |
| U-P4-1 | U | iOS `nw_connection` teardown on `disconnect` completes before the radio tail | hardware |
| U-P4-2 | U | `MockRelay` subscription introspection in `nostr-relay-builder` 0.44 (the client-side no-standing-REQ oracle is used regardless) | P4-2 |
| U-all | U | every energy figure in this plan (Evgenii, Karki & Won, LTE-2012 models) | hardware only (`MESH_LOCATION_RELAY_DESIGN.md:401`) |

### 7.6 Source reports

Investigation reports, 2026-08-29 (scratchpad artefacts; paths are ephemeral and not cited): common brief; synthesis
(root causes R-A…R-G, decisions D0–D8, promise map, phase skeleton); context audits — iOS stack, Android stack,
pipeline/network, constraint map (+ tests/lanes, docs/a11y); research — iOS CoreLocation power (Apple docs, WWDC23 10180,
DTS threads 726945/771422/783585, QA1965, `CLServiceSessionDiagnostic`), Android location power (AOSP frameworks/base main
`GnssLocationProvider.java`, `LocationProviderManager.java`, `ListenerMultiplexer`; `geolocator_android-5.0.2`;
`flutter_foreground_task-9.2.2`; androidx core 1.16.0), network/socket power (`nostr-relay-pool-0.44.3`, `nostr-sdk-0.44.1`,
LTE/5G wake-energy models), reference-app strategies (Life360, Find My, Snapchat, OwnTracks, Traccar, Overland, GPSLogger,
Home Assistant); and the four phase drafts — verification/CI/copy/docs (P0, P6, verification map, risk register, rollback),
iOS (P3 + P1 iOS half), Android (P2 + P1 Android half), network (D5, P4, P5); and the eight independent reviews of the v1
plan (security, Marmot/MLS, Rust, iOS, Android, Flutter, test/CI, UI/UX — §8) whose primary-source re-verification
(Apple doc JSON, WWDC23/24 transcripts, DTS 726945, AOSP `PowerManager`/`AlarmManagerService`/`LocationManager`,
riverpod/flutter_riverpod 2.6.1, Flutter 3.41 scheduler/widgets bindings, nostr-relay-pool 0.44.3) is folded into §2.
In-repo canonical siblings: `docs/BACKGROUND_SHARING_FAILURE_ANALYSIS.md`, `docs/M7_BACKGROUND_SHARING.md`,
`docs/M11_ROLLOUT.md`, `haven-core/SECURITY.md`, `docs/privacy/README.md`, `docs/privacy/privacy_invariants.json`.

---
## 8. Review record (v2 round 1 and v3 confirmation round, 2026-08-29)

Eight independent reviewers read the v1 plan against the working tree and the primary sources; every verdict was
APPROVE-WITH-CHANGES. The same eight then re-read v2 (confirmation round, table at the end of this section):
every round-1 item was confirmed LANDED or DECLINED-ACCEPTED, and the small set of NEW items they raised — mostly
problems the round-1 fixes themselves introduced — is applied in v3. Every BLOCKER/MAJOR was applied; every MINOR/BAR-RAISE was applied unless listed under "Not
applied" with the evidence. A finding that changed a design changed the DESIGN text (§2–§3) and its phase (§5); nothing
was appended as a footnote. Where reviewers overlapped, one design was written per topic (the cross-review resolutions:
P4 settle/pause, guard call-shapes, the P1 stream release, the P2a/P2b split, P3 fail-safe Always, D5 contract, P5 stagger,
P4 copy, P0/P6 measurement).

| Reviewer | Verdict | Mandatory ids | Where each landed (mandatory → non-mandatory) |
|---|---|---|---|
| security-reviewer | APPROVE-WITH-CHANGES | S-1…S-7 | S-1 → D6 (v) in-flight gauge, §5.4 tests; S-2 → D6 (vi), P2a cycle (`_relayService?.shutdown()` per cycle), §7.1 (the presence-row half superseded 2026-08-29: privacy page removed; the per-cycle shutdown stands); S-3 → §5.3 manifest (host tests only; b7 a lane oracle); S-4 → D1 (`onCancel` clear, `clearLastBestFix`), §5.3 guards/tests; S-5 → D3 (iv), P2a cycle/tests/guard (5); S-6 → P2a m7 check-10 factoring (with T-7); S-7 → D6 (iv), OD4 (no "strictly"), OD4-b, RC1 residual. S-8 → D7/§7.1; S-9 → §5.3 payload (length equality + residual); S-10 → D5 (v), P1 tests/invariant; S-11 → D8/P1 (`_stopLiveSyncBounded`); S-12 → P1 rule-13 gate predicates; S-13 → P2a paused signal `if (handedOff)`; S-14 → P1 manifest symbols; S-15 → D1 `bestSince` (timestamp half) + invariant rename — accuracy half declined (below); S-16 → D4/P2a constants test |
| marmot-expert | APPROVE-WITH-CHANGES | F1…F6 | F1 → D5/P1 guard call-shape pin (with rust D5-M2); F2 → D6 (v) (with S-1); F3 → D6 (i) drain-then-clear + backlog test; F4 → D6 `Paused` phase + `run_monitor` suppression + Dart tests; F5 → D6 (v) per-endpoint EOSE + two-relay commit test; F6 → D7 (stagger kept), §5.5 tests, §7.1 disclosure (superseded 2026-08-29: privacy page removed; the deviation entry carries it). F7 → D6 (iv) residuals; F8 → D6 (iv)/§7.4 (`cursor.rs` rows, `storage.rs` note); F9 → D6 (iii)/§7.2 (no order fixtures); F10 → D6 (v)/§5.4 wording; F11 → D6 (ii) cold seed + test; F12 → D5 (iii) late-ack semantics; F13 → §5.4 hold-back oracle; F14 → §5.4 P2c (relay-side `#p` count only as optional evidence; deterministic form = the k-th-burst Rust test) |
| rust-expert | APPROVE-WITH-CHANGES | D5-M1…M4, P4-M5…M9 | D5-M1 → D5/P1 (`test-util`, pure timing tests); D5-M2 → P1 guard; D5-M3 → D5 (iii) `publish_with_retry(1, ZERO, …)`, B8 preserved; D5-M4 → D5 (iii) one 5 s window, worst 10 s, tests renamed; P4-M5 → D6 (v) (with S-1/F2); P4-M6 → D6 (i)/(ii) relay union, paused `subscribe_circle`; P4-M7 → D6 (ii) `run_repair` gate before `take_due`, queue drained; P4-M8 → §7.4/P1 red→replacement; P4-M9 → D6 (i) post-condition sweep + pre-connect sweep + stale-REQ test. D5-m1 → D5 wording; D5-m2 → D5 `as_millis`; D5-m3 → D5/P1 counts-only log + captured-logger test; D5-m4 → P1 (60–70 s wall clock, notifications-based); D5-m5 → P1 (attempts +1 exact); D5-B1 → D5 `send_to_one`; D5-B2 → P1 pure race tests; D5-B3 → D5 (iv) `RelayManager::subscribe` deleted + check 7; P4-m1 → D6 status; P4-m2 → D6 (v); P4-m3 → D6 (iv)/P1 comment sweep; P4-m4 → §5.4/§7.2 (restart-budget guard unchanged; Dart source-order test); P4-m5 → §5.4 harness + `settle_before_pause_with`; P5-m1 → D7 (33 s regime); X-1/X-4 → D5; X-2 → P1 (flags-only tests hermetic); X-3 → §1.2/P0 |
| iOS/CoreLocation reviewer | APPROVE-WITH-CHANGES | F1…F6 | F1 → §7.1 (negation sentence deleted; with flutter F17/UX-2); F2 → D2 `alwaysConfirmed` fail-safe, §5.3 tier fixtures, 0a-provisional row, OD-P3-b reversed; F3 → D2 background guard + fixture; F4 → D1 (vi) route (b) native `backgrounded` read + guard order pin + test, §1.2; F5 → §5.3 lane tier pin, the Always job (OD-P3-c), hardware 0a as WP3-2 merge gate; F6 → D1 (iv) 100 m cap + 200 m bound + test, OD-P3-d. F7 → §7.1 (tier-neutral Settings wording; no "low-power"; card gating); F8 → §7.1 (clause (c) is the pin); F9 → invariant renamed; F10 → D1 (vii)/§6.5 profile duty; F11 → D1/§5.3 guards (derivation pin, `!= .active`, check 8 carries all eight); F12 → D2 header sentence, 0c; F13 → D2/§5.3 wiring order pin; F14–F16 verified (F16 → §2.1 merge-gate statement); F17 → D1 status typing, WP3-2 `build-check`; F18 → §5.3 check 11 symbol, b7 `alwaysConfirmed`, `-1` trap note; F19 → D6/§5.4 cancellation `finally`; F20 → P1 acceptance/change list |
| Android reviewer | APPROVE-WITH-CHANGES | B-1, B-2, M-1…M-9 | B-1 → §2.2a facts, §3.1 service gate, D3 part 1, P1 no-frame test/guard (7)(8); B-2 → D4/§5.2 P2a/P2b split, OD-P2-3, guard (1) inverted, invariant deferred; M-1 → D4/P2a Kotlin listeners no release/detach + test + fixture; M-2 + M-9 → D3 (iii) `kMinFixRequestInterval` 31 s, tests; M-3 → §2.2/D3 (iii) per-API gap proof + exhaustive property test; M-4 → §2.2/D3/§6.5 listener cost; M-5 → D3/§5.2 (no `gps` fallback; P2b remedy); M-6 → D4/OD-P2-2 one-cycle TTL breach; M-7 → D3 (iv)/P2a guard (5) single call site; M-8 → D3 (vi)/P1 FA §C narrative + stamp test. m-1 → D3 (vii); m-2/m-3 → §2.2/B1 (`ACQ=` age; grammar); m-4 → §2.2/P2a; m-5 → V-P1-3; m-6/m-7/m-9 → §2.2; m-8 → §3.1 rewrite; m-10 → D4 (`await` acquire); BR-1 → D4 P2b design; BR-2 → B1 step (8); BR-3 → P2a exhaustive test; BR-4 → B1 grammar fixtures same commit |
| flutter-expert | APPROVE-WITH-CHANGES | F1, F2, F3, F4, F6, F7, F8, F12, F13, F14, F16, F17, F18, F22 | F1/F2/F3/F6/F7/F22 → §2.2a, §3.1 (synchronous cache clear in `_onPaused`; per-build placeholder; `_suspended` cleared only by `resume()`; guard (7) token; binding-derived default; `isIOSProvider`), P1 tests; F4 → D3 (vi)/P1 (whole reclaim block + `_startTimers()` ahead; gate table); F8 → D1/§2.1 (sink errors) + guard fixture; F12 → D3 (iv)/P2a `_deliveryPending`; F13 → P2a harness `oneShotRequests`; F14 → B1 lock-age oracle; F16 → D6/P4 (no `ref.watch`; lint); F17 → §7.1; F18 → D6 (vi)/§7.1 ("briefly" + FGS per-cycle shutdown; the copy half superseded 2026-08-29: privacy page removed). F5 → D3 (vi) consequence; F9 → D1; F10 → D1 (i) `IosLocationSource`; F11 → D1 (iv)/§7.1 @description (the @description half superseded 2026-08-29: privacy page removed); F15 → D4 catch clauses; F19 → P1 tests (`listen` + `FakeAsync`); F20 → P6 rule 5; F21 → §1.2; F23(a)(b) → D8/P1 (P4-1 inside P1; `_stopLiveSyncBounded`) — F23(c) declined (below); F24 → OD1 variant drafted (§7.1) |
| test/CI reviewer | APPROVE-WITH-CHANGES | T-1 (BLOCKER), T-2, T-3 + T-4, T-5, T-6/T-7/T-8/T-10, T-9 | T-1 → D3 (iii) `kBackgroundFixHorizon`, D7 (stagger unchanged), §5.5 n = 2..12 test, §7.4 collateral; T-2 → P0-D, §6.5 (relay capture mandatory, ≥ 3 h, SoC), §6.6; T-3 → B1 55 s formula + fixture pair; T-4 → "Verification decision" + B1 sampler mechanics; T-5 → §5.4 P2c in-process oracle, budget re-derivation; T-6 → P1 `check_stream_provider` (24); T-7 → P2a m7 check-10 factoring (with S-6); T-8 → §5.3 `check_bg_publish_drive`; T-9 → P1-D/P6 rule 5 (`manager.rs`, `cursor.rs`, `--list` rows); T-10 → P1 engine guard restructure + self-test step. T-11 → §6.4 + each phase's rollback; T-13 → B1 constant-derived hold; T-14 → P1 b9 asserted from the first landing; T-15 → D6/§5.4 `_dispatchTick` + `BURST_BOUND`; T-16 → P1 (wall-clock stated, kept); T-17 → §5.3 bounded profile poll; T-18 → OD-P3-c reconciled with ios F5 (below); T-19 → P1 manifest symbols; T-20 → §5.5 (no lane row unless funded); T-21 → P2a comment-stripped slice lint; T-22 → §5.4; T-23 → P6 rule 7 + phase sweeps; T-24 → P1 (37 mocks); T-27 → §5.3 manifest; T-29 → §5.4 client-side oracle, U-P4-2 |
| ui-ux-reviewer | APPROVE-WITH-CHANGES | UX-1…UX-7 | UX-1 → D2/§5.3 (card only under `always`; page test); UX-2 → §7.1 (with ios F1/flutter F17); UX-3 → D2/§5.3/§7.1 (arrow/bar keys chosen by handler state; provider invalidated on toggle + resume); UX-4 → §7.1 (no battery promise, "→", one noun); UX-5 → §7.1 limited-note order; UX-6 → D8/P1 (maintenance arming gated on both platforms), D6 (vi)/§7.1 copy (the copy half superseded 2026-08-29: privacy page removed); UX-7 → §1.2/P4 (the one-connection sentence — superseded 2026-08-29: privacy page removed; the two-socket fact stays in the RC1 summary). UX-8 → §5.3 comment "not show", forbidden pause/timer; UX-9 → D2 (invalidate on resume) + the settings-hub subtitle bar-raise adopted in P3 (§7.1); UX-10 → D8/P1 banner announce + live-region label; UX-11 verified; UX-12 → P6 rule 8 (binding l10n process) |

**Genuinely incompatible mandatory changes, and how they were resolved.** (1) ios F5 (fund the `location-always`
bg-publish job) vs testing T-18 (decline OD-P3-c: a simulator cannot show the pill) — both are right about different
things: the job is kept and recommended on the KEEP-ALIVE basis (publishes continue from the background with no activity
session held and `alwaysConfirmed == true` — the only CI runtime evidence for a shape whose physical neighbour failed on
2026-08-20) and it makes NO pill claim; the pill stays hardware-only (§4 OD-P3-c). (2) android B-2 (keep the plugin lock)
vs the v1 P2 guard/invariant/tests that pinned `allowWakeLock: false` and vs security S-16's scoped-lock pin — resolved by
splitting P2 into P2a (plugin lock kept AND the scoped lock added, guard (1) pins `allowWakeLock` ABSENT, no
`INV-L-ANDROID-NO-PERMANENT-WAKE-LOCK`) and P2b (removal, gated on a wake source + forced-idle hardware liveness).
(3) marmot F6 (keep the 2–9 s stagger; whole-second deltas) vs the v1 D7 2–2.5 s / 5 s and testing T-1's option (b)
("state honestly that spread = maxGap × (n−1)") — resolved by keeping every stagger constant (T-1 allowed either; F6's
fingerprint argument decided it) and decoupling P2a's horizon (T-1 (a)). (4) security S-2 (make the presence sentence
true on Android by shutting the FGS pool per cycle) vs flutter F18 (reword to "connects briefly") — both applied: the
shutdown lands in P2a AND the wording is "briefly" (D5 worst 10 s, a burst worst ≈ 33 s, so "a few seconds" would still
overclaim) — the wording half is superseded 2026-08-29 (privacy page removed; "briefly" survives in the SECURITY.md/M11 statement). (5) ux UX-4 (delete "low-power" — a battery promise) vs ios F7 (qualify it with "while you stay still") —
the stricter one wins: the word is banned in copy and the tier is stated in the `@description`. (6) rust P4-m4 (the
restart-budget guard is a numeric-derivation guard) vs the v1 P4 row that extended it with a Dart source-order pin —
the pin moved to `map_shell_location_access_lifecycle_test.dart`; the guard is unchanged.

**Not applied (with evidence).**
- security S-15, the `horizontalAccuracy <= kStationaryConfirmMaxAccuracyMeters` filter on `lastBestFix` (the `bestSince`
  timestamp half IS applied): today the stream cache takes every delivered fix regardless of accuracy
  (`geolocator_location_service.dart:806-809` tee into `_lastStreamPosition`); filtering the PUBLISH INPUT by accuracy
  would make a poor-signal user publish a stale last-known instead of the best available fix — a liveness/UX change on
  what is published, which D0 forbids and which no other reviewer asked for. The tier race S-15 targets is closed by the
  timestamp comparison alone.
- flutter F23(c), a 60 s grace `Timer` before the sharing-OFF engine stop on Android ("if declined, say why"): the
  timer would keep N engine sockets pinging every 55 s (the crate default the engine client keeps, `session.rs:92-105`,
  §2.3 F3) for 60 s after EVERY pause on the platform whose stated P1 goal is "no live-sync engine with sharing OFF while
  backgrounded", and it is exactly the background Dart timer P4's R14 (a) lint bans; with P4-1 landed first (F23(a),
  applied) a glance costs one reconnect ≈ 0.5 J (§2.3 wake model) plus a ≤ 49 h inbox REQ — cheaper than 60 s of
  pinging sockets, and simpler (one fewer timer).
- testing T-18 as written ("decline OD-P3-c"): not adopted; reconciled with ios F5 as above — T-18's fact (the pill is
  unobservable on a simulator; `indicatorShown` would be a self-report the Swift guard already pins) is recorded in
  OD-P3-c and the job asserts session state, never the indicator.
- marmot F14's relay-side "no `#p` REQ between bursts" as a lane oracle: the iOS lane's `tooling/e2e/local-relay` logs
  only "listening"/"shutting down" (`main.rs:54,59`, testing T-5 V), so it is listed as optional evidence behind a
  tooling change; the deterministic form is the `a_burst_reissues_the_inbox_req_every_kth_burst` Rust test (OD4-b).
- Alternatives the same reviewers offered beside their recommended fix and which were therefore not taken: android B-1
  option 1 (a synchronous `ref.read` flush — leans on Riverpod internals, leaves resume frame-bound); ios F1's
  negation-with-vocabulary variant (the sentence was deleted — UX-2/flutter F17 agree); flutter F1's `ref.onDispose`
  cache-clear site (the synchronous `_onPaused` site was chosen — one place, no rebuild dependence); rust D5-M4's
  "keep the drain and rename the test" (the one-window design was adopted).

### Confirmation round (v2 → v3)

Every reviewer confirmed all of their round-1 items as LANDED (or DECLINED-ACCEPTED where §8 declined them) and
raised the items below; all are applied. Converging items were merged into ONE design per topic: the P4 pause
order (security NEW-1 = rust N2 = marmot N1/N2, with rust N1's dead-worker bound and rust N4/marmot N3's accepted-
endpoint set), the copy-tie vocabulary rule (ux N-1 = flutter N4; ux N-6b = flutter N5), and the P2b lock policy
(android N-2 with security NEW-2).

| Reviewer | Verdict | New ids | Where each landed |
|---|---|---|---|
| security-reviewer | APPROVE-WITH-CHANGES | NEW-1, NEW-2 (MAJOR); NEW-3, NEW-4 (MINOR) | NEW-1 → D6 (i) (c)/(d): marker acked and gauge zero BEFORE `disconnect`, all inside `pause_subscriptions` under the lifecycle lock; `a_commit_arriving_between_settle_and_pause_is_still_confirmed`; `rule13_…` asserts gauge == 0 at the disconnect instant (§5.4, §6.3 C5). NEW-2 → D4 (P2b consent design: channel-only native registration from `_ensureRegistration`, `cancelRegistration` at both disable sites, fail-closed receiver, guard + Dart test + B1 force-kill oracle), P2b-1, §6.1/§7.2/§7.3 P2b rows. NEW-3 → `INBOX_BURSTS_PER_REQ` named in the invariant statement (k = 1 unless OD4-b), `config.rs` doc. NEW-4 → D6 Dart rules + §5.4 step 5/C4 edge: `_dispatchTick`'s timeout is a watchdog that never cancels; C4 requests cooperative cancellation; two coordinator tests |
| marmot-expert | APPROVE-WITH-CHANGES | N1 (MANDATORY); N2, N3 | N1 → D6 (i): the lifecycle lock is held across the marker await, the pause link is commit-critical (no Dart timeout, excluded from `BURST_BOUND`); `a_burst_open_racing_a_draining_pause_waits_for_the_clear`. N2 → D6 (i) (b): `send().await` under `RELAY_LIFECYCLE_OP_TIMEOUT`, never `try_send`. N3 → D6 (v)/§5.4: the expected endpoint set is what THIS burst issued (no inbox endpoint on a non-k-th burst); `a_non_kth_burst_settles_without_an_inbox_endpoint` |
| rust-expert | APPROVE-WITH-CHANGES | N1, N2 (MAJOR); N3, N4 | N1 → D6 (i) (b): intake `tx` clone on the core, bounded send + ack, `wedged` short-circuit, direct router-clear + `note_delivery_gap()` fallback; `pause_subscriptions_completes_within_the_lifecycle_bound_when_the_worker_is_dead`; §5.4 change list. N2 → D6 (i) order (a)→(b) marker→(c) gauge→(d) disconnect→(e) repair clear; `pause_never_disconnects…` driven through the intake. N3 → D5 (v) + P1 test: assert only after `RelayNotification::SubscriptionAutoClosed`. N4 → D6 (v)/§5.4: `subscribe_bucket` returns the accepted relay set; `a_dead_relay_in_a_bucket_does_not_time_out_the_burst` |
| iOS/CoreLocation reviewer | APPROVE-WITH-CHANGES | N1, N3 (MAJOR); N2, N4 | N1 → D2 + §5.3: the diagnostics observer sets `alwaysConfirmed`, re-runs `arm()` (foreground-only invalidate) and fires `onAlwaysConfirmedChanged` → `applyIndicatorPolicy()`; `check_arm_tier_policy` pins the observer body (+1 fixture); `background_location_provider_test` delayed-confirmation case; b7 asserts `alwaysConfirmed` via a bounded status poll. N3 → §3.1 body keeps `if (!bg) service.clearCachedPosition();` (foreground opt-out clears at the rebuild), `check_stream_provider` pins it (+1 fixture; counts 24/47/48), `location_provider_test.dart:182` stays green (§5.1, §7.4). N2 → V-P1-1 re-tagged U, not load-bearing (`services/binding.dart:295-299`), §3.1/§5.1/§7.5. N4 → §5.3: the native `profile` tag uses the `lastBestFix` predicate (one source of truth) |
| Android reviewer | APPROVE-WITH-CHANGES | N-1, N-2 (MAJOR); N-3, N-4, N-5 | N-1 → §5.2 B1 (5)/acceptance + `INV-L-ANDROID-BACKGROUND-SINGLE-GNSS-REQUEST`: bound = `kLocationPublishMinInterval − kBackgroundFixLeadTime` = 62 s for the circle just published, ≥ `kMinFixRequestInterval` otherwise (a 72 s bound would red ≈ 10 % of correct cycles); the P1 half re-keyed on the UI request's `minUpdateDistance=1.0` suffix. N-2 → D4 (iii) + P2b-1 + §6.1/§6.6/§7.2/OD-P2-3: `allowWakeLock: !isIgnoringBatteryOptimizations` re-evaluated at enable/resume (`AlarmManagerService.java:2734-2740`); forced-idle hardware row in BOTH exemption states. N-3 → D3 (iii): the FGS service instance has an empty cache; the first cycle awaits the historical delivery ≤ 2 s, one-shot only on ≤ 30; two tests. N-4 → D3 (iv): the follow-up cycle records `_lastConsumedFixTs`; test. N-5 → §2.2: "no extra acquisition" holds for I ≥ 62 s |
| flutter-expert | APPROVE-WITH-CHANGES | N1, N4 (MAJOR); N2, N3, N5 | N1 → §3.1/§5.1: one outer `StreamController` PER `getLocationStream` call (`onCancel` cancels the inner; a new call cancels any previous inner) or a broadcast controller; `a toggle rebuild re-listens without error and cancels the previous inner`. N2 → §3.1: `resumeStream()` re-subscribes whenever the current outer has a listener, dead inner included; test. N3 → §5.1 tests: `TestWidgetsFlutterBinding.ensureInitialized()` for tests building the real provider. N4 → §5.3 tests + §7.1 (with ux N-1): forbid the "blue" word and the "blue location bar" phrase, never bare "bar"; the arrow key keeps "status bar". N5 → §5.4 ARB (with ux N-6b): sentence-scoped scanner per locale (superseded 2026-08-29: privacy page removed) |
| test/CI reviewer | APPROVE-WITH-CHANGES | N-1 (MAJOR); N-2, N-3 | N-1 → §5.4 tests + checklist: the OK is released on an OBSERVED condition (close path pending, or a ≤ 3 s bounded yield far from the 10 s bound), never a 9.5 s literal; the commit is driven through the intake. N-2 → §6.5 + P0 change list/P0-C: NEW `tooling/e2e/ci/summarize-created-at-gaps.sh` with `--self-test` (`summarize-wire-journal.sh` parses the proxy journal, not a relay capture). N-3 → §5.2 B1 (5): the retry registration after a failed publish is 62 s and passes; the wrapper comment records that a failed publish inside the window is itself a finding, so nobody widens the bound |
| ui-ux-reviewer | APPROVE-WITH-CHANGES | N-1, N-2 (MAJOR); N-4 (mandatory precision); N-3, N-5, N-6 | N-1 → §5.3 tests/§7.1 (with flutter N4). N-2 → §7.1 NEW `locationSettingsIosCatchUp` (verbatim copies, rendered last), D2 composition order, §5.3 ARB/manifest/page test, §7.3 (assertion-key move → one `ratchet_override` item, deleted next commit). N-3 → §7.1/§5.4: "carries your own updates"; forbid the OLD shape "one connection to each relay"/"single connection" only (superseded 2026-08-29: privacy page removed). N-4 → D8/§5.1: the age `Text` is its own non-live semantics node outside the `ExcludeSemantics` subtree (`:415`); fault-persists → one `announce(title + age)` on the resume re-derivation; two tests. N-5 → §7.1 subtitle reports the SETTING. N-6a → §7.1 OD4-declined per-platform presence variant (superseded 2026-08-29: privacy page removed); N-6b → sentence-scoped copy-tie (superseded likewise); N-6c → OD1/D2: the pill cohort is provisional Always on iOS 18+ AND every iOS 17 Always user |

Nothing from the confirmation round was declined.

### Owner directive after v3 (v3.1)

| Reviewer | Verdict | New ids | Where each landed |
|---|---|---|---|
| owner | DIRECTIVE 2026-08-29: Privacy page removed; plan de-scoped accordingly | Settings → Privacy page and every `privacy*` ARB key deleted (13 locales); an invariant or accepted deviation may carry zero disclosure keys | Status line; §1.2 (RC1 summary row replaces the one-connection ARB row; AndroidManifest citation re-pointed); §2.3 F23; §2.4; D1 (iv); D3 (iv); D6 (vi); D7; §4 OD3/OD4; P0 docs; P1/P2a/P3/P4/P5 manifest + ARB lines and packets (P4-6, P5a-2); §6.1 rule 8 + matrix; §6.2 TTL row; §6.4 P4/P5 rows; §7.1 (four rows removed); §7.3 Keys column; §8 resolutions marked superseded. Behaviours, invariants, tests, guards and the `locationSettings*`/`settingsLocationSubtitle*`/FGS-notification copy work are unchanged |
