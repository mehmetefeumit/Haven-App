# Power Efficiency — Implementation Plan

**Status:** PLAN v3.3 — 2026-09-05: the owner brought the **MDK v0.9.4 → v0.9.18 migration into scope as a milestone**, recorded as **P4M** (§5.7) — a coordinated WIRE migration, not a dependency bump, sequenced AFTER P6 and outside the P0→P6 chain (it delivers no power saving, it cannot precede or accompany P4/P5, and it is the only item in this plan a revert cannot undo). Its evidence falsifies one thing the plan asserted: the epoch-gap backfill (#825/#892) **shipped in v0.9.5 and is still unreachable** from Haven's five pinned crates at every tag, so **OD4-c's option (ii) is DEAD** and OD4-c now collapses to option (i) or a named residual (§4, §5.4). **That last clause is v3.3's own state and was SUPERSEDED on 2026-09-09: the owner took option (iv) AND option (i), rejected the named residual outright, and the Rust half landed the same day — only (i)'s Dart consumer is owed (§4 OD4-c, L-121, L-133). This version line is kept as dated history, not as current status.** Nothing on the wire, no promise and no mechanism decision (D0–D8) changed. v3.2 — 2026-08-30: amended for the owner's constraint of the same day — **no macOS machine and no iPhone for the duration of this project** (§2.5). P0-D's hardware baseline is **NOT AVAILABLE** and is replaced by **estimation model E** (§6.5a), whose every output is tagged **ESTIMATED** and may never be read as measured; every gate in this document is now typed **POWER-MEASUREMENT** (the owner has authorised replacing these with estimates) or **LIVENESS / WEDGE-SAFETY** (an estimate cannot substitute — re-based on the strongest evidence CI can still produce, residual stated); **P2b is PARKED** (its gate is forced-idle hardware liveness, which cannot be met) and P2a is confirmed shippable without it; P3's physical merge gate is re-based on CI evidence with its residual stated in full; `docs/POWER_MEASUREMENT.md` is **DEFERRED but intact and still authoritative** for the day hardware returns, its Android half runnable earlier. Nothing on the wire, no promise and no mechanism decision (D0–D8) changed. v3.1 — 2026-08-29: de-scoped the same day for the owner's removal of the Settings → Privacy page and every `privacy*` ARB key (13 locales): every copy round, copy-tie test and disclosure edit that targeted that page is gone; the behaviours, the invariants (now without disclosure keys — a permitted state since 2026-08-29) and the surviving settings/notification copy work are unchanged (§8). v3 — 2026-08-29: two independent review rounds by 8 reviewers (security, Marmot/MLS, Rust, iOS, Android, Flutter, test/CI, UI/UX); round 1: all BLOCKER/MAJOR findings applied, MINOR/BAR-RAISE applied unless listed under "Not applied"; round 2 (confirmation): every round-1 item confirmed LANDED or DECLINED-ACCEPTED and all confirmation-round items applied (§8); OWNER DECISIONS TAKEN 2026-08-29 (all recommendations accepted — see §4); previously awaiting owner decisions OD1/OD3/OD4/OD4-b/OD-P2-2/OD-P2-3/OD-P3-b/OD-P3-c; nothing implemented.

**Purpose.** A 2-member iOS+Android circle with background sharing ON drained both phones and showed a
permanent blue location pill on the iPhone, although Haven publishes only every 72–168 s. This document is
the single source for fixing that without moving anything on the wire, weakening a promise, or reopening
the 2 h silent wedge of `docs/BACKGROUND_SHARING_FAILURE_ANALYSIS.md` (FA). It merges four expert drafts
(verification/CI, iOS, Android, network) over one synthesis; every file:line was re-read in the working
tree on 2026-08-29 (uncommitted units A–F present) unless tagged **I** (inferred) or **U** (unknown);
**V** = verified in code or a primary doc. Conflicts between drafts are resolved here as "decision + why".

**How to read / how to use with agents.** §1–§2 are the facts; §3 the FINAL decisions D0–D8 (do not
re-litigate — if a decision is wrong, say so in review with evidence); §4 the owner decisions; §5 one section
per phase P0–P6 with the template headings, plus §5.7's milestone **P4M** — the same headings, but NOT a phase and
NOT in the chain; §6 the cross-phase verification map, risk register, rollback
story and the hardware protocol; §7 the consolidated appendices (ARB keys, guards, manifest, red tests,
V/I/U ledger); §8 the review record (v2: what each of the eight reviewers changed, and what was declined with
evidence); §9 the **decision ledger** — every decision this epic has taken, in the order it was taken, each with
what it rejected, what it costs and what evidence would overturn it, plus the correction chains and one index of
everything still open. Start there when the question is *why is it like this*; §9 points into §3–§8 for the
argument and never restates it. Each phase runs as **an implementer wave** (one agent per work packet, packets marked
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

**The V tag covers the MECHANISM, never the energy figure beside it.** Every mA, joule, `%/h` and `%/day` in the
"Why it costs" column is a **published third-party figure** (Karki & Won, OwnTracks, Evgenii, the LTE-2012 radio
model), measured by somebody else on somebody else's hardware and quoted here with its source. None was measured on
Haven, on either platform, ever — they are model E's inputs (§6.5a (i)), and everything this plan derives from them
is **ESTIMATED** (§2.5, §7.5 U-all). Read the column as "why this mechanism costs energy", not as a measurement of
this app.

| # | Cause | Where | Why it costs | Why the pill |
|---|---|---|---|---|
| R-A | iOS: ONE continuous `startUpdatingLocation` session at `kCLLocationAccuracyBest`, `distanceFilter = None`, `pausesLocationUpdatesAutomatically = NO`, 24/7 while background sharing ON; nothing lowers it on pause; > 98 % of ~1 Hz fixes are discarded. Apple's own recommended shape for background continuity is "no auto-pause AND a coarse accuracy" (doc on `pausesLocationUpdatesAutomatically`); OwnTracks calls this configuration "Move mode" (~25 %/day vs 1–2 %/day). | `geolocator_location_service.dart:653-674`; `geolocator_apple GeolocationHandler.m:122-135` | GNSS cannot be duty-cycled by the OS; CPU never idles (per-fix channel delivery) | — |
| R-B | iOS: three independent, each-sufficient pill causes, all ON: (A) a When-In-Use app doing background location (pill mandatory, flag ignored); (B) `showsBackgroundLocationIndicator = true` (only matters under Always; default false); (C) a held `CLBackgroundActivitySession` ("just creating the session displays the indicator", WWDC23 10180; Apple positions it as the *When-In-Use* mechanism). Under Always only B and C apply — both Haven's choice. | service `:660-661`; `HavenBackgroundSessionHandler.swift:134-136` | (C) also keeps the app executable, which is why everything else keeps running | constant because the session never pauses and C is held for the app's lifetime |
| R-C | Android: the UI isolate's `locationStreamProvider` (`AndroidSettings(distanceFilter: 1, intervalDuration: 1 s, forceLocationManager: true)`, non-autoDispose) is NEVER cancelled on pause; the FGS lifts the uid to foreground importance so the OS 30-min background throttle never applies → 1 Hz `QUALITY_HIGH_ACCURACY` GNSS for the whole background session. On API 31+ the plugin's LocationManager path picks the platform `fused` provider (GPS-only on 23–30). The FGS additionally issues a 30 s HIGH_ACCURACY one-shot per 72 s tick (its own stream cache is always empty). | `location_provider.dart:42-54`; `map_shell.dart` `_onPaused`; `background_location_task.dart` | continuous GNSS ≈ 60–85 mA (Karki & Won) | no pill on Android; same drain |
| R-D | Android: `flutter_foreground_task` holds a permanent, untimed `PARTIAL_WAKE_LOCK` (Haven never sets `allowWakeLock: false`); the 72 s repeat is a coroutine `delay()` loop that NEEDS the lock; battery-optimisation exemption also requested. CPU never suspends while background sharing is ON. Every reference app except Traccar holds no wake lock. | `background_location_manager.dart:134-144`; plugin `ForegroundService.kt:288-289,427-435` | AP never reaches suspend | — |
| R-E | Both: nostr-relay-pool 0.44.3 defaults on BOTH relay pools (engine `Client` + publish `RelayManager` `Client`; the FGS isolate keeps a third): unconditional WebSocket ping every 55 s per socket, `sleep_when_idle = false`, reconnect never gives up. Radio energy is per WAKE not per byte (LTE ≈ 13 J per isolated wake; 10 KB ≈ 0.05 J). Keepalives ≈ 70–90 % of background network wakes: ≈ 150 wakes/h iOS-bg, ≈ 140 Android-bg for one circle (I). | `session.rs:92-105,531`; `manager.rs:412` (was `:291` before P1-N1/N2); crate `constants.rs:34` | modem never reaches deep idle on cellular | — |
| R-F | Both: nothing background-gated on iOS-bg: N per-circle publish timers + motion trigger + per-fix `MapPage` FFI/`setState`, KeyPackage 10-min / relay-list 30-min / subscription-health 15-min timers (the health tick's 684 s silence window < 900 s tick guarantees a REQ re-issue on every quiet circle; any relay drop → full re-anchor incl. **7-day** inbox replay because the inbox `since` ignores the subscribe phase). WorkManager spins a FlutterEngine every 15 min only to no-op while the FGS is alive. `SharingHealthBanner` `_rerender` 72 s timer runs while backgrounded (V for existence; U whether the widget is disposed on pause — §5.1 rule). Resume fires an N-circle burst + 30443/10050/10002 probes + kind-0 fetch + engine re-anchor (7-day replay) + 2 prunes + tile eviction. | pipeline audit H3–H11; `sharing_health_banner.dart:195-207` | many small wakes; the 7-day replay is the big one | — |
| R-G | Foreground publish plane = N independent timers for N circles (each its own access gate, MLS encrypt, 3-relay publish, DB write, health refresh); the Android FGS already batches due circles into one wake + one fix. Per-circle timing decorrelation is already defeated at shared relays by the multiplexed `#h` REQ (one REQ names all of a relay set's circles) and the single publish socket; only the archive `created_at` equality leak is real, and a ≥ 2 s stagger closes it. | `location_publish_scheduler_provider.dart`; `per_circle_due_tracker.dart:178-191`; `planes/mod.rs:52-57,160-203`; `publish_stagger.dart` | linear in circle count | — |

### 1.2 Documentation drift found in passing (fixed by P0 unless a later phase changes the truth again)

**Status: every row LANDED 2026-08-30 (P0-B).** The "Wrong today" column and the `file:line` column
below both describe the tree as of 2026-08-29, before the fixes; they are the record of what was wrong
and where, not a description of HEAD. Each fix states the corrected fact in place with its own source
citation. Four findings the fixes turned up, worth keeping:
(a) **the `WN_RELAY_EPOCH_SYNC_MIGRATION.md` 6 h row was not merely unverified but false** — Android's
own page says "*Currently*, this restriction only applies to `dataSync` and `mediaProcessing` foreground
service types" (https://developer.android.com/develop/background-work/services/fgs/timeout, verified
2026-08-30), and Android 16/API 36 adds nothing to that list, so `location` has never been subject to
it and there is no exempt-list to be absent from; the doc's earlier "CORRECTION" was itself the error.
Two hedges carried into every site of the retraction so it is not over-broad in turn: the "Currently"
is Google's own, so the list can widen and must be re-checked, not cached; and the separate
`shortService` type does carry its own ~3-minute cap — a different restriction, which Haven does not use;
(b) **no row turned out to depend on Privacy-page copy** — the RC1 row already accounted for the
2026-08-29 removal, and the `AndroidManifest.xml` row was re-pointed at `docs/privacy/README.md` +
`haven-core/SECURITY.md` as planned, so nothing here is obsolete-because-the-page-is-gone;
(c) **`FA:250-253`'s replacement could not cite `research/reference_apps_strategies.md`** — §7.6 states
the research reports are ephemeral scratchpad artefacts whose paths are not citable, so the sentence
was retracted as UNCITED against the in-repo field report (§1 and §1.1 R-A/R-B) instead of being
re-sourced.
(d) **the `AndroidManifest.xml` row was not the only dead `MAP_AND_PRIVACY_BACKLOG.md` citation** — the
P0-B review found three more (`haven/DEVELOPMENT.md:132`, `haven/assets/certs/stadia_ca.pem:9`,
`haven/lib/src/constants/tiles.dart:19`). No document in this tree carries the material any more, so
each pointer was replaced by the fact it was standing in for (Stadia's operational safeguards are
console-side; the pem header IS the CA-refetch runbook; the placeholder domain/mailbox are tracked
nowhere and are used only by the OSM-fallback User-Agent). Nothing automated catches these — rule 15
of the privacy manifest only covers references the manifest itself declares.

| file:line (pre-fix) | Wrong on 2026-08-29 | Truth (source) |
|---|---|---|
| `docs/M7_BACKGROUND_SHARING.md:3-8`, `:332-336`, `:462` | `liveSyncEnabled` "stays `false`" | defaults TRUE since M11 Phase B (`bool.fromEnvironment('HAVEN_LIVE_SYNC', defaultValue: true)`, guard 14b) |
| `M7` §6 item 0, `M7`'s 2026-08-23 changelog entry, `docs/CI_HARDENING_BACKLOG.md` (the app-ops paragraph), `FA` §3 "How the pipeline works" | "1 m distance filter in background" | ~~the bg-on iOS arm carries `kCLDistanceFilterNone` (`-1`, Unit F 2026-08-28); the opt-out arm keeps 1 m~~ → **superseded by P3 (2026-09-04): iOS has NO distance filter in either toggle state** — `HavenLocationStreamHandler.init` sets `kCLDistanceFilterNone` once for both accuracy profiles, and `_kIosNoDistanceFilter` is deleted. 1 m survives only on Android's foreground arm (the background-service arm is 0). All four sites re-stated by WP3-6 |
| `docs/M11_ROLLOUT.md:117`, `haven-core/SECURITY.md:873-878` | standing socket exists "while the app is in the foreground"; "iOS background suspension drops the socket" | on iOS with background sharing ON the process stays executable and the socket persists, pinging every 55 s (P4 makes the original sentence true again) |
| `SECURITY.md:257-263` | engine keeps its socket "on Android while the foreground service is active — in the background too" | FALSE **with background sharing ON**: `_handOffMlsSession` stops it (the branch at `map_shell.dart:1282`, `:1322`) and the FGS never starts one. Scoped 2026-08-30 after review: with sharing **OFF** nothing in Haven stopped the engine — that pause path closed only the publish client (a different `Client` from the engine's) — so the socket lived until the OS froze the process. **SUPERSEDED by P1-A2 (2026-09-03): the bg-OFF Android pause now calls `_stopLiveSyncBounded()` (`map_shell.dart:925`, called at `:1504`) without releasing the Rule-14 guard, so Android holds no engine socket while backgrounded in either toggle state. The landed sentences are `SECURITY.md`'s M7 paragraph and its "Persistent receive connection" bullet, both rewritten by P1-D; current line citations are `map_shell.dart:1390` → `_handOffMlsSession` `:949-985`, publish client `nostr_relay_service.dart:675-685` → `manager.rs:412`, engine `session.rs:92`** |
| `FA:250-253` | Life360/Find My/Snapchat use "kCLDistanceFilterNone, best accuracy, indicator on" | UNCITED and contradicted by the field report; no source claims Best + no filter + pill |
| `haven/lib/src/constants/location.dart:49-50` | overlap guard "gates … the `didChangeAppLifecycleState(resumed)` branch" | resume SETS `_lastPublishTime`; the guard gates motion-triggered publishes only (V-tag `_onResumed` before editing) |
| `haven-core/src/relay/live_sync/config.rs:268-271` | `HEALTH_CHECK_SECS = 900`, `RELAY_LIST_SECS = 1800` | dead (no reader outside the definitions — V; live timers are Dart, `maintenance_scheduler_provider.dart:101-133`) |
| `haven/lib/src/services/ios_location_auth_service.dart:3-5` | "Continuous background location delivery … requires 'Always'" | background continuation needs only When-In-Use (foreground-started session); Always buys the receive-only SLC/region relaunch (`geolocator_location_service.dart:641-643`) |
| `haven/android/app/src/main/AndroidManifest.xml:117` | cites `docs/MAP_AND_PRIVACY_BACKLOG.md` | file does not exist; point at `docs/privacy/README.md` + `haven-core/SECURITY.md` (the behaviour statements that remain after the Privacy page's removal, 2026-08-29) + note the Play declaration is console-side |
| `docs/WN_RELAY_EPOCH_SYNC_MIGRATION.md:178,:243` | "Android 15 6-hour FGS timeout … `location` is NOT exempt" | U/likely wrong — the 6 h cap targets `dataSync`/`mediaProcessing`; verify against developer.android.com "Foreground service timeouts" (Android 15) and correct with URL + date |
| `docs/MESH_LOCATION_RELAY_DESIGN.md:181,:422-423` | per-send jittered TTL `[interval, 2×interval]` | retention is the group's 0x8005 component (228 s); per-send jitter retired 2026-08-13 (SECURITY.md) |
| `FA` downgraded-hypotheses bullet on the SLC background relaunch | "iOS MAY resume publishing after a jetsam kill + movement" | contradicts `INV-L-IOS-WAKES-RECEIVE-ONLY`. Today the hole is REAL: a relaunched process's cold-start publish (`map_shell.dart:499-501`) reaches `getCurrentLocation()` whose backgrounded shortcut (`:711-724`) is keyed off `_foregroundActive`, written only by MapShell's `paused` dispatch — if that dispatch is not delivered on a background launch (V-P1-1, U) the plugin one-shot starts a manager from the background. P3 closes BOTH halves: the native owner refuses a background-capable START, and the shortcut consults the native `backgrounded` status (D1 (vi)); P0 marked the FA sentence "unverified today; closed by P3", and **WP3-6 closed it for real on 2026-09-04** — the bullet now reads "CLOSED by P3: a relaunch is receive-only BY CONSTRUCTION, on both paths" and names the two mechanisms |
| `docs/privacy/privacy_invariants.json` `accepted_deviations[RC1].summary` | "One persistent client per relay … over the same connection" | INCOMPLETE today: two `Client`s per process (engine `session.rs:92`, publish `manager.rs:412` — both re-verified and re-cited by P1-D; the `:102`/`:291` pair this plan carried was already stale for `build_engine_client` and drifted for `RelayManager::new` when P1-N1/N2 added `publish_relay_options`, `send_to_one` and `publish_location_event`) — the publish socket is a second connection from the same address. The user-facing sentence that carried the "one connection" claim left with the Privacy page (2026-08-29), so no copy is affected; P0 records the two-socket fact in the RC1 summary (prose only, no key/status change — no ratchet item); P4 narrows the RC1 statement (§5.4) |
| `docs/WN_RELAY_EPOCH_SYNC_MIGRATION.md:312-313` | module-layout excerpt lists `HEALTH_CHECK_SECS`/`RELAY_LIST_SECS` | the constants are dead and P0 deletes them — the excerpt is edited in the same commit (nothing else references the names — V) |

**Line-citation drift in this plan — the LEDGER ITSELF is retired, 2026-09-09, and replaced by symbol citations.** It was declared RESOLVED on 2026-08-30 by P0-B and corrected again on 2026-09-03 by P1-D, and by the time P4 and P5 had moved `map_shell.dart` again **every entry in it was drifted** — `_stopLiveSyncBounded()` was recorded at `:925` and is at `:1535`, `_handOffMlsSession` at `:949-985` and is at `:1559`, `_onDetached` at `:1265` and is at `:1880`, `kStreamPositionMaxAge` at `:131-148` and is at `:412`, `build_engine_client` at `session.rs:92` and is at `:94`, `RelayManager::new` at `manager.rs:412` and is at `:419`. A ledger of line numbers is a ledger that goes stale on the next refactor, and re-pinning it a third time would only have set the fourth drift running. **So there are no numbers here any more, and the rule is: cite the SYMBOL.** The sites the ledger existed for, by symbol: `background_location_task.dart` → `onReceiveData`, the `_inFlightPublish` drain in `onDestroy`, `_dueWithinHorizon`, `_sampleJitteredInterval`; `constants/location.dart` → `kStreamPositionMaxAge`; `map_shell.dart` → `_stopLiveSyncBounded()` (the ONE bounded engine stop), `_handOffMlsSession()` (its Android caller) and `_onDetached()` (which since P1 goes through `_stopLiveSyncBounded()` and has no unbounded stop left — that was the ledger's one substantive finding, and it is closed); `geolocator_location_service.dart` → the `denied`-branch no-background-prompt reasoning on `checkPermission`/`getCurrentLocation`; `sharing_health_banner.dart`, `location_provider.dart`, `maintenance_scheduler_provider.dart` → the widgets/notifiers those citations named, which were re-verified as correct and are cited by symbol wherever the body needs them; `haven-core` → `build_engine_client` (`relay/live_sync/session.rs`) and `RelayManager::new` (`relay/manager.rs`); and `PING_INTERVAL` (55 s) in `nostr-relay-pool`'s own `constants.rs`, which is a pinned external crate and moves only on a version bump.

---

## 2. Platform facts that bound the design (V unless marked)

### 2.1 iOS

- iOS has NO periodic background wake: BGAppRefresh is opportunistic, BGProcessing idle-only, `beginBackgroundTask` ~30 s one-off, silent push excluded (no APNs by policy), audio/VoIP forbidden (2.5.4), SLC floor 500 m / 5 min. "GPS off, wake every 2 min" is impossible. The realistic minimum is a CHEAP continuous session that keeps the process alive (timers + sockets survive).
- **The 16.4 rule (Apple DTS, thread 726945, re-fetched 2026-08-29 — V):** an app calling BOTH `startUpdatingLocation()` and SLC keeps delivering in the background iff `allowsBackgroundLocationUpdates = true`, `distanceFilter = kCLDistanceFilterNone` and `desiredAccuracy ≤ kCLLocationAccuracyHundredMeters` (numeric < 1000) with the indicator OFF — or the indicator ON with anything. The "both" precondition is Haven's own case under Always (SLC is Always-gated, `HavenSLCHandler.swift:207-223`); under When-In-Use Haven runs no SLC and the pill is mandatory anyway. Apple's `pausesLocationUpdatesAutomatically` doc recommends "disable + `ThreeKilometers` in the background"; the plan stops at 100 m because of this rule. WWDC24 caveat (V): Core Location "does not take measures to keep apps running continuously when it has nothing to deliver" — whether locationd has something to deliver every few seconds at 100 m / no filter on a desk is I (the `startUpdatingLocation` doc promises nothing periodic) ⇒ "hours stationary" is V-P3-3 and was a HARDWARE MERGE GATE for P3 (§5.3), not an acceptance item — **amended 2026-08-30 (§2.5): that gate is DEFERRED (no iPhone) and re-based on the CI bundle in §5.3 WP3-2; V-P3-3 stays UNKNOWN and is P3's stated residual.** `CLLocationUpdate.liveUpdates` auto-pauses (process suspended, socket dies) → breaks the 228 s no-gap invariant → rejected until the protocol has a "stationary since" semantic.
- **Indicator rules:** under **Always** the pill is optional (`showsBackgroundLocationIndicator`, default false, affects ONLY Always apps, toggleable "at any time" on a running manager — QA1965 V) and `CLBackgroundActivitySession` is unnecessary (iOS 18: `CLServiceSession(.always)` taken in the foreground is the requirement per WWDC24 — stated for the modern APIs; whether the legacy `startUpdatingLocation` path is covered is unstated, which is why the `.always` session stays; iOS 17: `allowsBackgroundLocationUpdates` + Always suffices). Under **When-In-Use** the pill is mandatory (QA1965) and honest, and WWDC24 (V) says CL delivers nothing to a backgrounded WIU app without a LiveActivity or `CLBackgroundActivitySession`. Hiding the pill saves nothing by itself; the drain fix is the accuracy tier. Reference apps under Always (Traccar iOS, OwnTracks Move, Overland) never set the flag → no pill. **Provisional Always:** `authorizationStatus` reports `.authorizedAlways` while the second prompt is unanswered (`requestAlwaysAuthorization()` doc, V) although the EFFECTIVE authorization is When-In-Use; `CLServiceSessionDiagnostic` exposes `alwaysAuthorizationDenied` (documented: explicit denial only), `authorizationRequestInProgress` and `insufficientlyInUse` (EMPTY doc abstracts — U semantics), and WWDC24 says the first diagnostic arrives with `authorizationRequestInProgress` already false when authorization is settled ⇒ D2 fails SAFE (WIU policy until a diagnostic positively confirms Always). `locationManagerDidChangeAuthorization` fires at manager CREATION and in the background (V) — D2 must never withdraw an in-use claim from a background callback.
- Where Wi-Fi/cell cannot resolve 100 m (rural, some indoor) the 100 m tier IS GPS, duty-cycled by locationd ("Core Location turns on the hardware it needs", V) — the tier is a power CEILING the OS chooses under, not "Wi-Fi/cell" by definition; the §6.5 template records the observed profile duty.
- **EventChannel error contract (V, `platform_channel.dart:710-721`):** an exception thrown by the platform `listen` call is passed to `FlutterError.reportError` and NEVER added to the stream; only errors the native side pushes through the event sink arrive as `PlatformException`. The iOS engine cancels an existing sink before delivering a new `listen` (`FlutterChannels.mm`, I). ⇒ every native refusal/denial is emitted through the sink (D1).
- `desiredAccuracy` can be changed LIVE on a running `CLLocationManager` (V for the API; the background effect is I — V-P3-2). geolocator cannot express that (start/stop only) and the `-1` vs `0` mapper bug shows plugin fragility. R7 (`M7`'s 2026-08-24 changelog entry — "a background-capable session may only be established while the app is in use"; guard check 12): a stream must not be (re)started while backgrounded — CI run 32661622879 is exactly that failure class. ⇒ two-profile accuracy on iOS requires a Haven-owned native `CLLocationManager`.
- `requestLocation()` "does nothing" while the same manager is updating (research §2.2) — a native one-shot needs a second manager, which is why one-shots stay on geolocator (D1).
- Energy tiers (best available measurement, Evgenii 12 h background): 100 m ≈ 0.3 %/h vs 10 m ≈ 1.8 %/h; GPS tiers cost 4–6× the 100 m tier. No Apple mA table exists; every battery claim is a hardware deliverable (`MESH_LOCATION_RELAY_DESIGN.md:401`) — **and 2026-08-30 there is no hardware (§2.5), so these two figures are model E's only iOS location inputs (E-I4) and every iOS %/h in this plan is ESTIMATED from them.**
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
| F29 | The engine auto-commit publish is `Client::send_event_to` awaited INLINE in the serial worker (10 s per-relay OK wait); `route_events` matches `Location \| GroupUpdate \| Joined \| Invalidated \| Unrecoverable` — there is no `EpochChanged` variant; a `Buffered` verdict is the FUTURE-epoch case, a one-epoch-behind message decrypts from past-epoch keys | `processor.rs:465-470, :560-600, :613-620`; `auto_commit.rs:110-122`; `wire_format.rs:52-57`; `MARMOT_PROTOCOL_KNOWLEDGE.md:772-773` (re-pointed 2026-09-05 — that file gained ~46 lines above this anchor when its upstream-state block was corrected; the anchor text is unchanged) |
| F30 | `CursorAnchors::note_eose(group_hex)` consumes a circle's single generation on the FIRST relay's EOSE of a multi-relay bucket; the expected `(relay, sub)` endpoint set is already tracked by `probe_subscriptions`/`open_delivery_windows`; the worker resolves the router at PROCESSING time, so everything still queued in the 8192-deep intake when the router is cleared is dropped | `anchor.rs:221-232`; `session.rs:430-436`; `supervisor.rs:537-548, :606-613`; `config.rs:42` |
| F31 | `run_monitor` emits `SyncStatusReason::Disconnected` PER RELAY on every `Terminated` transition; Dart maps it to `SyncConnectionPhase.disconnected`, health stamps `_disconnectedSince` and confirms `relayDisconnected` after 168 s; `LiveSyncResubscriber.ensureRunning` reads `isRunning`, which stays `true` while paused | `session.rs:1904-1935`; `live_sync_provider.dart:153-154`; `sharing_health_provider.dart:68, :288-295, :425-443`; `:456-465` |
| F32 | `subscribe_circle` today does pool add + connect + wait, the cold-start cursor seed, the dynamic sub-id derivation, router registration and the REQ; `resume_after_background` re-issues the STORED `active` set and never calls `add_relay`; `bucket_since` reads an unseeded cursor as `unwrap_or(0)` → a `since = 0` REQ is forbidden | `session.rs:1232-1272, :360-375, :1117-1170`; `cursor.rs:7-8` |
| F33 | Inbox cursor floor = `clamp(cursor − L, 0, now)`; the cursor advances only to the local open time of an inbox REQ whose EOSE the worker consumed; `start` seeds an unset cursor at `now − 24 h`; NIP-59 backdates by ≤ 172 800 s; `storage.rs` ties gift-wrap dedup retention to the 7 d constant | `anchor.rs:336-355`; `processor.rs:391-400`; `session.rs:693-708`; `nostr-0.44.7 nip59.rs:23`; `storage.rs:3065-3066` |
| F34 | `RelayManager::subscribe` (long-lived `subscribe_to`, no auto-close) has NO caller in `haven-core/src` or `rust_builder/src` (V, grep 2026-08-29); a future caller would keep the ping-less publish pool from ever sleeping AND create a silent-dead standing REQ (the C3 class) | `manager.rs:660-700` |
| F35 | ~~tokio in `haven-core` is built WITHOUT `test-util` (`tokio::time::pause()` does not compile)~~ **FALSE — CORRECTED 2026-09-05: `test-util` IS in `haven-core`'s dev-dependencies (`Cargo.toml:239-249`, with a comment explaining it is what `start_paused = true` needs), so `tokio::time::pause()` and `#[tokio::test(start_paused = true)]` compile and are used (`session.rs:4668`, `:4726`, `:4802`). This row caused P4 to specify an injected-`clock` parameter that the implementation correctly did not build — see §5.4.**; `nostr-relay-builder` is a dev-dependency (`MockRelay`, `LocalRelay`, `WritePolicy` `NeverAnswer`/`RejectEverything`, recording `QueryPolicy`) available to lib unit tests; `SLEEP_INTERVAL` is 60 s in the build Haven links (the 1 s value is the CRATE's `#[cfg(test)]`) | `haven-core/Cargo.toml:122, :232, :240`; `constants.rs:36-41`; `publish_before_apply_send_e2e.rs:97-128`; `catchup_sweep_e2e.rs:1300-1315` |

**Wake model:** a reconnect (DNS+TCP+TLS1.3+WS) ≈ 0.5 J inside a wake — persistent-vs-reconnect is decided purely by wake COUNT. **Every joule figure in this plan — here and at every site that cites "the wake model" — is arithmetic over the published LTE-2012 model (E-I6), i.e. ESTIMATED and never measured on Haven** (§2.5, §6.5a); only the wake COUNTS are properties of this code. Carrier NAT floors: worst measured 255 s; the ≤ 168 s publish cadence sits inside every floor. **Engine-pool trap:** `ping(false)` on the ENGINE pool is unsafe while it holds standing REQs: its socket then carries no traffic (publishes go over the OTHER pool), a NAT drop is silent, and the 15-min health tick is the only detector → re-creates the C3 blackout. Safe only when the engine has no standing REQ (P4's burst mode) or the pools are merged (rejected — see D6).

### 2.4 The privacy-manifest gate (`scripts/ci/check_privacy_invariants.sh`)

There is no commit-message token. The ratchet reads `docs/privacy/privacy_invariants.json` → `.ratchet_override.items[]` and `.ratchet_override.reason` (≥ 40 chars) (`:1700-1770`; fixtures `:2580-2586`); item ids are `<INV-ID>.deleted`, `<INV-ID>.status`, `<INV-ID>.disclosure:<arbKeyOrNonArbId>`, `<INV-ID>.assertion:<arbKey>`, `<INV-ID>.unbacked:<arbKey>`. An override is compared against the PR's base; after merge it is STALE on the next PR (`:1751-1757` fails a stale override) — every override is deleted in the first follow-up commit (§5.7). A re-worded value under an unchanged key is invisible to the ratchet — hence every re-worded claim gets a copy-tie test (README "What the gate cannot prove"). Rule 15: `doc_anchors`/`source` fragments must be real headings; rule 3: cited test names must keep existing; rule 12 sweeps English claims. Since 2026-08-29 an invariant or accepted deviation may carry ZERO disclosure keys (the Privacy page is gone; the README records the owner decision), and the ratchet no longer demands an override for a disclosure/assertion key whose ARB string no longer exists — only for one that still does. README: platform-asymmetric strings get one invariant per platform.

### 2.5 The hardware constraint (owner-directed 2026-08-30) and the two kinds of gate

**Constraint, verbatim.** "Assume throughout the implementation of the power changes that we do not have access to a
macOS machine or an iPhone to get benchmarks. Start with estimations, and/or measurements where necessary. As we
collect more data from the using patterns post-release, potentially CI steps, etc., we will have a better idea of what
the power usage ended up looking like from the user's perspective when we are complete. We can invest in follow-ups
later."

**What is NOT lost (V, re-checked 2026-08-30).** Not Swift, and not the simulator. `e2e-ios.yml`,
`e2e-ios-background-publish.yml`, `e2e-ios-auth-tier.yml`, `e2e-ios-real-gps.yml`, `e2e-profile.yml`,
`cross-check.yml`, `build-check.yml` and `release-build.yml` all `runs-on: macos-latest`, so iOS code still COMPILES
on every PR, `check_ios_background_publish.sh` / `check_m7_native_wake_guards.sh` still run, and every simulator
behavioural oracle — including the real OS background transition of `e2e-ios-background-publish` — still executes.
The plan's iOS *mechanism* work is therefore fully reviewable and fully gate-able; nothing in P3 or P4 becomes
unverifiable code.

**What IS lost.** (a) **Every battery figure, on both platforms** — no device SoC delta, no Energy Log, no
`batterystats`, no Battery Historian, no discharge share: these need a phone on battery, and the Android half needs
an Android phone the project also does not have on hand (§6.5a distinguishes the two). (b) **Every
physical-device-only observation**: the status-bar pill vs arrow (a simulator cannot render it — OD-P3-c already said
so), true OS process suspension, Android AP suspend under Doze, the `CLServiceSessionDiagnostic` values under a
provisional Always grant, the `locationd` `desiredAccuracy` console trace the profile-duty column is computed from,
and the HAL's `CAPABILITY_SCHEDULING` answer (I-P2-1). `docs/M7_BACKGROUND_SHARING.md` §6 already records why the
simulator cannot stand in for the last class: `BGTaskScheduler` "refuses to run on the Simulator" (`M7` §6 intro), and
the 2026-08-23 investigation concluded that where the simulator's suspension policy is absent "the continuity claim
must move out of CI to §6 item 0 — never into a widened window" (`M7`'s 2026-08-23 second changelog entry). That sentence is the reason the
physical checklist exists, and it is why §6.6's liveness clause below is re-based rather than deleted.

**"Post-release data" is NOT instrumentation, and must never become it.** Haven ships no analytics, crash-reporting
or attribution SDK, and a guard enforces it: `INV-R-NO-TELEMETRY-SDK` (`docs/privacy/privacy_invariants.json:1515`) is
backed by `check_m7_native_wake_guards.sh` check 9b, whose dependency scan fails on an analytics/crash/ads package
name in pub, Gradle, CocoaPods or Cargo, including one vendored inside another plugin's artifact
(`check_m7_native_wake_guards.sh:218-233, 360-481`). So the owner's "data from the using patterns post-release" means,
and can only mean, two things: **owner/user observation** of their own devices (Settings › Battery per-app row, "is
the pill there", "did sharing stop overnight", a peer's marker age) and **CI-observable proxies** (§6.5a (ii)).
Nobody may later plan a telemetry, metrics or "anonymous usage" feature to close this measurement gap — that is a
Rule-10 privacy regression dressed as a measurement plan, and it would red the guard on the first commit.

**The two kinds of gate.** This plan wrote its gates as one undifferentiated class ("Hardware (owner)"). They are
two, and only one may be replaced by an estimate:

| Class | What the gate asserts | Treatment under the constraint |
|---|---|---|
| **POWER-MEASUREMENT gate** | an energy number: device SoC %/h, GPS sensor time, mobile-radio-active time, wake-lock time, discharge share, Energy Log impact, profile duty | **REPLACED BY AN ESTIMATE** — authorised by the owner. The number comes from model E (§6.5a) and is tagged **ESTIMATED** at every site where it appears. It is never written, cited or summarised as measured, and it can never *fail*: an estimate that disagrees with a future measurement means the model was wrong, not that the phase regressed. |
| **LIVENESS / WEDGE-SAFETY gate** | publishing never stops: no relay-side `created_at` gap > 228 s, no FA C1–C6 silent wedge, the process still wakes on cadence, the session is still armed for the granted tier, the toggle still silences everything | **NOT replaceable by an estimate** — an estimated wedge is worthless, and the 2026-08-20 field failure is exactly the class an estimate cannot see. **RE-BASED** on the strongest evidence CI can still produce (emulator + simulator runtime lanes graded by the relay-side `created_at` grader), with the **residual stated in full** at each site: what the re-based evidence does *not* prove, and what would still have to be observed on a device. |

Applied at every gate site: the per-phase **Acceptance** blocks (§5.0–§5.6), the "lands together" matrix (§6.1), the
acceptance thresholds (§6.6) and the owner-decision register (§4). Where one gate mixed both classes — P3's item 0a
asserted "no blue bar AND no relay gap > 228 s for ≥ 2 h" in one breath — it is split into its two halves and each
half takes its own treatment (§5.3, §6.6).

**Epistemic tags, extended.** The existing V / I / U ledger (§7.5) gains one tag for this amendment:
**ESTIMATED** = produced by model E's arithmetic from cited third-party figures and stated parameters; strictly
weaker than **I** (which at least names an inference about *this* code), and never to be upgraded to V by repetition.
**NOT AVAILABLE** = the resolver named for a V/I/U row is a device this project does not have; the row stays open,
its resolver becomes "when hardware returns", and nothing downstream may quietly assume it resolved.

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
`events(FlutterEndOfEventStream)`; `didFailWithError` likewise (**`CLError.locationUnknown` is DROPPED, not
forwarded — see the correction below**; otherwise `code: .denied ? "denied" : "failed"`, message =
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
background-launched process (SLC/region/BGTask relaunch — the FA relaunch hole — its downgraded-hypotheses bullet on the SLC background relaunch) serves `lastBestFix()` (nil after
termination) and never starts the plugin one-shot from the background; the guard pins `lastBestFix(` before
`getCurrentPosition(` in the `getCurrentLocation` body (line-order, like check 12). With (vi) the wake is
receive-only by construction on BOTH paths (stream start refused; one-shot unreachable), which is what the amended
`INV-L-IOS-WAKES-RECEIVE-ONLY` statement may claim. (vii) **Profile duty, stated honestly:** in poor coverage the
controller cycles ≥ 120 s Best → 84 s HundredMeters → …, i.e. up to ≈ 59 % of the time at Best — **ESTIMATED
arithmetic on those two constants (E-I10), never an observation**; the "4–6× cheaper"
figure is Evgenii's bare-session number and excludes this — the §6.5 template's
"profile duty (% at Best)" column, read from Console `locationd` accuracy lines, is the number that WOULD tell the
owner whether 84 s / 120 s (OD-P3-a) are right, and it is **DEFERRED**: it needs a physical iPhone (§2.5), so no
run of it exists and 120 s ships un-tuned. Running `CLLocationManager`s on iOS after P3: exactly one for updates
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
session under an effectively-WIU app — `M7`'s 2026-08-20 changelog entry). `arm()` (`HavenBackgroundSessionHandler.swift:134-136`):
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
tier-neutral base key + ONE indicator sentence chosen by the handler's `alwaysConfirmed`
(`IosBackgroundSessionStatus`, `ios_background_session_service.dart:32-47`, via a provider invalidated on toggle
AND on `AppLifecycleState.resumed`) + ~~the catch-up key rendered LAST~~ **nothing else — the catch-up key was
deleted 2026-09-04 (CI-R23); the card is TWO sentences** (so VoiceOver hears session → indicator →
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
∈ [J − δ, J + max(0, TTFF − 10)] ⊂ [72 − δ, 168 s] for hot TTFF ≤ 10 s; cold TTFF 30 s → ≤ **198 s**, 30 s clear of the retention.
(This section said ≤ 188 s until 2026-09-04; that was an artefact of the old cold sweep running σ = 0, not a
property of S+.) On **API 23–30** (no delayed register) cancel+listen restarts GNSS at once and hibernates
from that fix: gap ≤ `J + TTFF₁ + TTFF₂ − 10 + ρ + σ` with two cold acquisitions (rare — ephemeris survives
≤ 168 s gaps, I).
**ACCEPTED RESIDUAL — the 228 s bound does NOT hold unconditionally on API 23–30 (decision W-3, 2026-09-04).**
Read this as a bounded, accepted defect with a named trigger, never as a passing invariant. ρ is the
delivery→registration latency (the gates), σ the registration→publish latency (fix read, stagger, encrypt); the
code declares ρ ≤ `kBackgroundFixHorizon − kBackgroundFixLeadTime` = 20 s and ρ + σ ≤ `kPublishStaggerMaxSpread`
= 30 s legal. The legacy regime pays TWO acquisitions and eats ρ and σ at both ends, so at the 30 s cold TTFF
this section already sizes, the realized gap is **`60 + min(J − 10 + σ, 168) + ρ`** — the inner `min` is
`nextFixRequestInterval`'s own result `I = min(J − 10 + σ, 158 + σ, 168)` (the middle term never binds, since
`J ≤ 168 ⇒ J − 10 ≤ 158`), and **that ceiling is exactly why the worst case is 248 s and not 268 s**: past
`J + σ = 178` the interval stops tracking the due-time and the gap flattens to `228 + ρ`. (This paragraph said
`J + 50 + ρ + σ` until the re-review of 2026-09-04. That form is the uncapped region only; it overstates the gap
wherever the ceiling binds — at J = 168, σ = 30, ρ = 20 it gives 268 against a true 248, and it disagrees with the
worst case asserted three sentences later. The breach condition is unaffected: `J + ρ + σ ≥ 178` holds in BOTH
regions, verified point-by-point over the swept space.) **Trigger, exactly:** `Api.legacy` AND a cold
acquisition AND `J + ρ + σ ≥ 178 s`. **Worst realized gap: 248 s** against the 228 s retention — so the
user-visible consequence is that a peer's marker is ABSENT for **at most 20 s**, once, before the next publish
restores it. S+ never breaches at all (worst cold gap 198 s, because the delayed register anchors on the last fix
and ρ falls out). API 23–30 is in scope because `minSdk = 23` (`haven/android/app/build.gradle.kts:36`). **No AP suspend is
involved** — this is P2a's own regime with the plugin lock held, not the P2b stack. **Why it is accepted rather than fixed (reasoning REPLACED 2026-09-04; the
earlier "every lever pays in S+ duty cycle" was simply wrong and is retracted — an API-level branch costs nothing
on S+ by construction).** The lever that would close it is a **legacy-only interval ceiling of 147 s**
(= `228 − 2·30 − 20 − 1`), and it works: swept, it empties the breach set outright and takes the legacy worst gap
**248 s → 227 s**. It is not taken, for two independent reasons, both pinned by
`background_fix_request_test.dart`'s `the ceiling that would close the residual, and the acquisition it would
waste — why it is not taken`.
**(1) There is no cheap API read to branch on.** Nothing in `haven/lib`, the Kotlin sources or `pubspec.yaml`
reads `Build.VERSION.SDK_INT` today (no `device_info_plus`; V — zero hits), and the consumer is the Activity-less
FGS isolate. Taking the lever therefore means a SECOND native channel installed from `HavenApplication.onCreate`,
its value cached across an async hop, threaded into `background_fix_request.dart` — a file that is pure by design
precisely so the gap proof can be an exhaustive sweep — plus a fail-open/fail-closed policy for
`MissingPluginException`, plus new source guards, since this repo has no JVM tests.
**(2) The ceiling is not free on the very cohort it protects** — the leg the re-review missed, and the decisive
one. A cap moves the DELIVERY, not the due-time, so the consumed fix's age stops self-correcting to the lead and
WALKS: `age ← J + age − 147`. One step from the steady state at the top of the jitter band gives
`10 + 168 − 147 = 31 s`, already past `kBackgroundFixHorizon` (30 s) — a delivery that selects no circle, i.e. a
GNSS acquisition spent for nothing, and on HOT fixes rather than only the cold ones the residual concerns. The
lever would trade a bounded 20 s marker gap on old devices for wasted acquisitions on those same devices.
**The residual's entry price, from the sweep:** with `J ≤ 168` and a breach sum of 178, it is unreachable below
**10 s of in-cycle latency** (`min(ρ + σ)` over the breach set = 10, V). A single-circle cycle spends about 1 s;
only a multi-circle decorrelation burst spends ten. So it is narrow in reach as well as bounded in consequence —
≤ 20 s, once, API 23–30, cold acquisition, multi-circle.
The guard is unchanged and already in place: `background_fix_request_test.dart`'s cold group now covers the same ρ ≤ 20 / σ ≤ 30
space as the hot one (441 (ρ, σ) pairs × 97 J × 2 API models) and asserts the breach SET as an EQUALITY —
`legacy && J + ρ + σ ≥ 178` — plus both worst gaps (198 s / 248 s) and the 20 s overrun by value, so the residual
cannot silently grow and cannot silently be declared gone. **That extension also closes the defect that hid it:**
the two halves of one proof disagreed about what was legal — the hot group swept ρ and σ while the cold group ran
ρ = σ = 0 — which is how a 941 094-point sweep missed a 228 s breach. STACKED faults (cold TTFF + a
delivery→Dart suspend gap, P2b only) exceed the retention by a wider margin still — risk register, §6.3 C6. No fix → the 168 s watchdog fallback publishes
last-known ≤ 168 + 30 s, as today (the watchdog keeps its wake source in P2a — D4). Today's worst case is WORSE
(V): the 72 s poll with a 30 s horizon publishes a circle due at D at the first tick T ∈ [D − 30, D + 42] plus a
30 s one-shot → up to 240 s > 228 s TTL. **Registration cost the energy model must carry:** every plugin
registration also installs the NMEA + `GnssStatus` listeners (§2.2) — ~1 Hz main-thread callbacks whenever the
GNSS engine navigates for any consumer (TTFF seconds outdoors, up to 60 s per interval indoors on a
non-scheduling HAL); the AP is not idle during a search. There is NO "`gps` provider fallback" on the plugin
path (geolocator 5.0.2 has no provider selector, §2.2): if GMS `fused` ignores the interval for HIGH_ACCURACY
(I-P2-2, ~~decided by the hardware GPS-time row~~ → **NOT AVAILABLE (§2.5); the attestation stands unconfirmed and its remedy is PARKED with P2b**) the remedy is the native registration of P2b (D4), not a
profile edit. (iv) **The FGS never publishes early on displacement** (verification G10 folded in):
the cycle publishes only circles whose CSPRNG due has come (`dueKeysUpTo`, `per_circle_due_tracker.dart:123-131`);
a delivery with nothing due is consumed silently — but it still REGISTERS: from `Idle` (pause with every
circle due 62–158 s out) the cycle, below both gates, calls `_ensureRegistration(target = earliestDue − lead)`
even when `dueKeys` is empty (otherwise the 72 s watchdog would re-run the same path and publish through the
cache-miss one-shot forever — the steady state P2 retires); `_publishCycle` is the ONLY `_ensureRegistration`
caller (the watchdog, the delivery handler and both signals only ever invoke the cycle), so the disclosure gate
and the foreground gate precede every registration on every path by construction — guard-pinned by count
(EXACTLY 2 as landed, both inside the cycle — §5.2's LANDED RECORD) and order. A delivery that arrives while a
cycle is `Cycling` (30 s stagger + 15 s publish + fetch) sets `_deliveryPending` (no second cycle; both entry
points share one event loop, so the hazard is only the await-separated one); the cycle's `finally` runs ONE
follow-up cycle immediately when `_deliveryPending` and `dueKeysUpTo(now + kBackgroundFixHorizon)` is non-empty
(same in-flight guard) and in EITHER case records the pending fix's timestamp as `_lastConsumedFixTs`, so the
next registration's historical re-delivery of that same fix dedupes (otherwise one spurious nothing-due cycle
per re-registration), and the watchdog also runs the cycle when `_deliveryPending` — a watchdog tick during
`Cycling` is otherwise a no-op. `INV-L-MOTION-TRIGGER-BOUNDED` ("only in the Flutter UI isolate") stays
literally true; no copy changes in P2.
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
today) + one 30 s one-shot per 168 s of silence. **That ≈ 60 s is optimistic at the FLOOR, and the reason is in
§2.2 already (recorded 2026-09-04, P2a review round): the give-up alarm is armed only for a request `≥ NO_FIX_TIMEOUT`
(60 s), so a registration issued at `kMinFixRequestInterval` (31 s) gets no framework give-up at all** — the chip
runs at 1 Hz until a fix arrives or until Haven's own ≤ 72 s watchdog re-aims, which makes the watchdog, not the
platform, the bound on an indoor search. The floor is reachable in ordinary operation, not only in corners:
`CI_HARDENING_BACKLOG.md` (P2a review pass, 2026-09-04) carries the reachability arithmetic and the candidate fixes.

### D4 — Android: scoped publish lock now (P2a); the permanent lock goes only with a proven wake source (P2b)
**P2a keeps the plugin's `PARTIAL_WAKE_LOCK`** (`allowWakeLock` left at its default `true`,
`foreground_task_options.dart:10`; the untimed non-refcounted acquire is `ForegroundService.kt:426-436`), because it
is the ONLY wake source of two things the plan must not lose: the no-fix fallback (indoors on a GNSS-only device the
platform alarms wake nothing, §2.2 / D3 (vii) — without a lock the 72 s watchdog is `delay()` on AWAKE time and may
take hours to accrue, and sharing stops silently on the F-Droid cohort the `forceLocationManager` posture exists
for: the FA class, no banner) and the recovery for a silent `onListen` while the plugin service is unbound
(V-P2-2) or a stream error mid-`Armed`. With the lock kept the AP never suspends, so the delivery→Dart window
(U-P2-1) does not exist in P2a. P2a still lands the GNSS saving §1.1 ranks FIRST among the Android causes
(R-C: 60–85 mA → ≈ 5 mA — the two published third-party draw figures, §1.1). ~~the dominant Android
drain~~ — **struck 2026-09-09: that is a magnitude claim, and it is model E's to make, not this
sentence's.** §1.1's ranking is by MECHANISM; model E's own baseline row (§6.5a (ii)) gives the Android
location term as **ESTIMATED** 1.33–1.89 %/h against a radio term of 0.44–2.91 %/h, so which term
dominates depends entirely on the wake-coalescing parameter `c` (E-P2, i.e. on cellular vs Wi-Fi) — and
§6.5a finding 2 records the radio term as the wider uncertainty of the two. Nothing here is measured and is revertible and measurable in
principle, but **not measured**: that needs an Android handset (§2.5), so what CI holds instead is the mechanism
proxy, B1's parsed registration oracle. Guard check (1) pins `allowWakeLock`
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
"bounded" — a one-cycle TTL breach at probability p, ~~measured on hardware before P2b~~ → **p is UNMEASURABLE for the duration (§2.5), which is one of the two reasons P2b is PARKED; moot under P2a, which keeps the lock.**

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
reconnects from `Sleeping`/`Terminated` in ≤ 5 s inside the same wake (+0.5 J, ESTIMATED — §2.3 wake model). **Amendments:** (i) all three
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
`every_fetch_primitive_leaves_no_subscription_registered`, cited from the invariant.
**What that test actually drives — corrected 2026-09-03, because the draft this sentence replaced overstated it
(SEC-F5).** It drives `read_one_relays_answer`'s **EOSE and CLOSED** exits (the CLOSED one through a
`RefuseAuthor` query policy, which is the arm that returns while the pool's own auto-close handler is still
waiting). It does **not** drive the **timeout** exit, and that exit is exercised by no test at all: producing it
against an in-process relay means holding a REQ open past `DEFAULT_TIMEOUT` with a fixed sleep, which the Testing
Requirements forbid outright. Nor does the assertion ride `RelayNotification::SubscriptionAutoClosed { id }` as
drafted — `client.subscriptions()` reports only LONG-LIVED registrations (the crate filters the auto-closing ones
out), so it is read immediately after each fetch to catch the `subscribe_to` class, and the auto-closing REQs,
invisible there, are covered by the socket actually reaching `Sleeping`, which reads the unfiltered map. The code
is safe on the timeout path either way — the same `CLOSE` runs — but that path is REASONED, not pinned, and any
later claim to the contrary is a doc regression. `publish_event` (3-attempt
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
every 72–168 s (the 120 s nominal cadence, jittered ±40 %) = "this pubkey is background-sharing right now" — a NEW inference for that relay class, so OD4
"strictly narrows RC1" is withdrawn; **OD4-b** offers folding the inbox REQ into every k-th burst (≥ 10 min, matching
the KP fold) at ≤ 10 min background invitation latency. (v) `wait_backlog_settled(timeout)` counts EOSEs per expected
`(relay, sub)` ENDPOINT THIS burst issued AND whose REQ the burst's `subscribe_bucket` ACCEPTED (it returns the
accepted relay set — today it accepts ≥ 1 and discards `Output`, and one dead relay in a bucket would otherwise make
every burst `TimedOut`, +5 s and (ESTIMATED, §2.3 wake model) +5 J forever; a burst that issued no inbox REQ — every non-k-th burst under OD4-b —
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
longer tail costs ≈ +3 J per extra circle per burst, ESTIMATED — radio energy is per wake, §2.3), and `created_at` is
whole seconds, so a 2.0–2.5 s gap would yield a delta of 2 or 3 s on EVERY burst — exactly the "a constant
stagger is itself a fingerprint" case `publish_stagger.dart:37-39` was written against; ~~2–9 s keeps the
whole-second deltas spread over eight values~~ **CORRECTED 2026-09-08 against P5a-2 as shipped — the alphabet is
ROSTER-DEPENDENT and the flat "eight values" is false from five circles up.** `maxGapFor(n) = clamp(30 s ÷ (n − 1),
3 s, 9 s)` prices every gap at the burst's OWN size, so the observable whole-second delta alphabet thins
monotonically: `{2…9}` (eight values) up to FOUR circles, `{2…8}` at five, `{2…6}` at six, `{2…5}` at seven and
eight, `{2,3,4}` at nine and ten, and exactly `{2,3}` at `kMaxCirclesPerBurst`. **Coalescing itself caused the
thinning** — before P5 every gap was priced at the default `totalPublishes = 2`, so it was always eight — and the
eight-value proof this sentence rested on draws at that same default, so it only ever pinned `n = 2`. Pinned per
burst size, as SET EQUALITY, by `expected whole-second delta alphabet, swept over every burst size the app admits`.
Spread arithmetic, corrected: `maxGapFor` floors the per-gap at
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

**Decisions taken by the owner on 2026-08-29: every recommendation below is ACCEPTED** — OD1 (indicator off under confirmed Always, no extra setting), OD3 (coalescing variant (a)), OD4 (background burst receive), OD4-b (inbox REQ every k-th burst), OD-P2-1 (FGS owns GPS), OD-P2-2 (P2b = native `PendingIntent` registration, not "measure and accept"), OD-P2-3 (NO `SCHEDULE_EXACT_ALARM`; inexact alarm default), OD-P3-a (120 s), OD-P3-b (WIU policy on iOS 17 provisional Always), OD-P3-c (fund the Always run), OD-P3-d (100 m). The "If declined" column is kept only as the record of the alternative; ~~no phase is gated on a pending decision any more~~ **CORRECTED 2026-09-05: one is. `OD4-c` (below) was opened by the review of the shipped P4-2 and is UNDECIDED; it gates P4's completion, not its landing. Every other row here remains decided.** A SECOND undecided item exists and is deliberately NOT given a row here, because it belongs to a milestone outside the P0→P6 chain: **the P4M flag day** (§5.7) — whether to execute the MDK v0.9.4 → v0.9.18 migration at all, given that it re-creates every circle, loses group history and cannot be reverted. §5.7's packet P4M-2 is where that decision is taken, and its recommendation is *not yet*. It gates nothing in P0–P6.

**2026-09-09 — this register carries NO open row, and the two sentences above about open rows are superseded, not
merely struck.** The owner took **OD4-c** on that date (BOTH halves — option (iv) *and* option (i); L-121) and
**OD4-d** with it (buy the coverage back; L-122), so "CORRECTED 2026-09-05: one is" and OD4-c's "TWO open rows" note
describe a state that ended on 2026-09-09. Three decisions taken the same day are NEW rows, tabled after the
2026-09-04 group below: **OD5-a** — the account's circle roster is bounded at **10**; **OD-P2-4** — P2b's
forced-idle merge gate holds **228 s**; **OD-P4M-1** — do not bump MDK while its OpenMLS is an untagged fork head,
and the gate that unblocks it is a tagged OpenMLS. The **P4M flag day** still has no row here and is still taken at
§5.7's P4M-2 — OD-P4M-1 is its supply-chain PRECONDITION, not the flag-day decision — so the paragraph above about
the flag day stands unchanged. **Decided is not built** — and on 2026-09-09 that shrank to nothing: ~~OD4-c's implementation is OWED~~ **OD4-c's RUST implementation LANDED the same day it was decided (option (iv)'s durable per-circle deferral and option (i)'s per-circle `GroupUnrecoverable` verdict, 18 new tests; L-133)** ~~**What is still owed of it is (i)'s DART CONSUMER: the verdict is emitted and observable across the FFI, and nothing reads it, so the user is still not told**~~ **and (i)'s DART CONSUMER LANDED WITH IT (L-134): the verdict is read, the circle is marked blocked, and the banner names it and offers the re-create — announced on the second foreground open, which is a debounce and not a gap, since it is also the horizon at which the repair becomes possible**, and ~~OD4-d's and OD5-a's are in progress~~ **BOTH OF THOSE LANDED THE SAME DAY TOO** —
**OD4-d's on 2026-09-09, the day it was decided, and the five decisions its implementation itself took are
L-126–L-130; OD5-a's likewise, reviewed on two planes, with the first implementation's check found ADVISORY UNDER
CONCURRENCY and the review the thing that made it a bound (L-132)**; §9.9's "work owed by a decision already
taken" carries ~~all three~~ ~~**the two that are not built**~~ ~~**what is left of them — OD4-c's Dart consumer,
and OD5-a**~~ ~~**exactly ONE item now: OD4-c's Dart consumer**, and no phase may report it as closed.~~ **NONE of
the three, as of 2026-09-09: OD4-c's consumer was the last of them and it landed (L-134), so every one of that day's
decisions is built and no row here holds a phase open.**

**Amended 2026-08-30 for the hardware constraint (§2.5).** Six of these decisions named a physical device as the
thing that would settle them — "decide on measured data", "revisit if the hardware row shows…", "hardware 0a is a
merge gate", "re-tune on the profile-duty column". None can be settled that way for the duration. **No decision is
reopened and no recommendation is reversed**; what changes is *what the owner is deciding on instead*, stated per
row below. The general substitution: where a row said "decide on the measurement", it now reads "decide on the
mechanism proof CI can produce plus model E's ESTIMATE (§6.5a), and record the residual as an accepted, named
unknown" — never "decide later", because a deferred decision would block a phase the owner has already said should
proceed. Two decisions genuinely change status: **OD-P2-2 and OD-P2-3 now gate a PARKED phase** (§5.2 P2b), so their
practical effect is deferred with it.

| OD | Question | Recommendation | Gates | If declined |
|---|---|---|---|---|
| **OD1** | Indicator OFF under CONFIRMED Always (`showsBackgroundLocationIndicator = !alwaysConfirmed`, no `CLBackgroundActivitySession` there), no extra user setting | YES — the OS arrow, Settings › Privacy › Location Services attribution, Settings › Battery "Background Activity" and Haven's own toggle remain visible; DTS advises against tricks, not against the property; every Always-tier reference app leaves the flag off. Honest consequence: provisional-Always users on iOS 18+ keep the pill until they answer the second prompt, and EVERY iOS 17 Always user keeps it for as long as they stay on iOS 17 (no diagnostics API — `alwaysConfirmed` never becomes true there); the card says so because its indicator sentence follows the handler's state (D2) | P3 copy (base + arrow/bar keys), `INV-L-IOS-INDICATOR-HONEST`, `check_arm_tier_policy`, M7 §6 item 0a — **AMENDED 2026-08-30 (§2.5): 0a is DEFERRED and the WP3-2 merge gate is re-based on CI evidence (§5.3)**. This decision's *user-visible* half — whether the pill actually disappears under confirmed Always — becomes **UNKNOWN until a device sees it**: `showsBackgroundLocationIndicator = !alwaysConfirmed` is statically guard-pinned and the tier branch is oracle-tested on the simulator, but no simulator renders a status bar. What the owner is deciding on instead: Apple's documented semantics for the property (QA1965, §2.1) plus the guard + tier oracles, with the honest residual that the *rendering* is unproven. The copy is safe either way because the indicator sentence follows the handler's state, not an assumption about the OS | P3 ships the accuracy profiles with the flag left `true` under Always (drain fix intact, pill stays); the arrow key is then never selected and the bar key renders under every tier — copy variant drafted in §7.1 so the copy-tie test has a target either way; a user setting would be one `showsBackgroundLocationIndicator` input to the same Swift line + one ARB key |
| **OD3** | Publish coalescing variant (a): one burst per interval with the EXISTING CSPRNG stagger (`2 s` to `maxGapFor(n)`, i.e. 2–9 s only up to four circles) / 30 s spread; reverses `INV-R-PER-CIRCLE-PUBLISH-DECORRELATED` | YES for multi-circle users (the invariant never held at a shared relay; ~30 wakes/h vs N × 30). ~~Honest cost, newly recorded in SECURITY.md and the deviation entry: identical inter-burst sequences let ANYONE holding two of your circles' relay archives — each relay carrying only one circle — tell they belong to the same phone~~ **THIS ROW LISTED ONE COST. THE SHIPPED RECORD CARRIES THREE (corrected 2026-09-08 against `PUB-COALESCE` as landed; no user-facing surface since 2026-08-29).** **(1)** identical inter-burst sequences let ANYONE holding two of your circles' relay archives — each relay carrying only ONE circle — tell they belong to the same phone. **(2)** the circle COUNT becomes a single-relay observable as a DURATION, and which socket carries it **splits by plane**: on iOS-bg the burst holds the engine socket across the whole staggered pass over the entire relay union, and on the Android foreground service `RelayManager::shutdown` is a **collective** `client.disconnect()` called at every cycle teardown, so a relay carrying exactly ONE circle sees connect-at-its-own-publish through disconnect-at-teardown — a tail that grows with the circles published after it; in the FOREGROUND there is no collective disconnect (`publish_relay_options()` is `sleep_when_idle(true).idle_timeout(10 s)`), so each relay's socket sleeps independently in (60 s, 70 s] after its OWN last send and measures only its own span. **(3)** the count ALSO leaks through the **signed kind-445 timestamps**, because `maxGapFor` is deterministic and INJECTIVE over `n = 5…11`: one whole-second delta per burst inverts to the roster size. That carrier is worse than (2) in three ways — it needs no socket observation, connection noise does not defeat it, and it PERSISTS inside the signed event in every archive of it — and it compounds with (1): link first, then count | whole P5(a): manifest status → `accepted_deviation` PUB-COALESCE via `ratchet_override`, SECURITY.md subsection (no copy round since the Privacy page's removal, 2026-08-29) | P5(b): wake-sharing only, invariant intact, CPU-only win; default when declined |
| **OD4** | Background burst receive on iOS: presence only at publish-TICK instants; foreground unchanged. **CORRECTED 2026-09-08 — this row said "publish instants" and that framing is FALSE for a multi-circle account.** A burst opens EVERY circle's REQ and dials EVERY circle's relay (`resume_burst` re-anchors the whole `active.group_subs` set; `client.connect()` takes the whole union), while `_publishPass` sends only to `_pendingCircles()` — and per-circle schedules are DECORRELATED by design (`INV-R-PER-CIRCLE-PUBLISH-DECORRELATED`). So a relay carrying circle B sees a REQ/CLOSE pair on every burst but this device's kind-445 for B on only ~1/N of them. Unconditionally too: the open precedes the publish, so an `openBurstPublishWindow` that returns null (no identity, disclosure not accepted, permission revoked, GPS timeout) or a consent flip inside the pass leaves a REQ/CLOSE pair with NO kind-445 at all. Disclosed as SECURITY.md residual 11 | YES — narrows RC1 (`INV-R-CROSS-PLANE-CORRELATION`) for CIRCLE relays and makes M11 §6.1 literally true again. NOT "strictly": an inbox-ONLY relay (kind 10050 set, independent of the circle sets) today sees one continuous socket and after P4 sees a REQ/CLOSE pair every 72–168 s (the 120 s nominal cadence, jittered ±40 %) = "this pubkey is background-sharing now" — named in §5.4, SECURITY.md and the RC1 summary | whole P4 incl. `INV-R-BACKGROUND-PRESENCE-ONLY-AT-PUBLISH` (no copy round since the Privacy page's removal, 2026-08-29) | iOS-bg keeps the standing engine socket (55 s pings, 15-min re-anchors, 7-day inbox replays on drop); P1's D5 and the bounded lookback (landed in P1) still stand |
| **OD4-b** | Fold the inbox (`#p`) REQ into every k-th burst, k chosen so k × nominal interval ≥ 10 min (the KP fold cadence), instead of every burst | YES — removes the inbox-only-relay cadence inference at the cost of ~~≤ 10 min background invitation latency~~ **CORRECTED 2026-09-07: the latency term must be RE-DERIVED before `k` is raised, because the shipped counter does not behave the way this row assumed. `k` counts BURSTS, not publish ticks (a joined tick issues no REQ and never reaches the Rust fold decision), and a burst that FAILS TO OPEN still consumes a fold position — the counter increments ahead of both post-connect failure exits. So the worst-case gap between inbox REQs is `2k − 1` intervals, not `k`, and the honest cost is up to ≈ 2× the figure this row carries. §5.4 has the mechanism** (invitations are not location-fresh) | P4-2 (`inbox_every_kth_burst`), Rust test `a_burst_reissues_the_inbox_req_every_kth_burst`, P2c oracle "no `#p` REQ between bursts" | inbox REQ on every burst; the inference stays and is disclosed as such |
| **OD4-c** (~~OPEN~~ ~~**DECIDED 2026-09-09 — IMPLEMENTATION OWED**~~ ~~**DECIDED 2026-09-09, AND THE RUST HALF IMPLEMENTED THE SAME DAY; (i)'s DART CONSUMER IS STILL OWED, so no phase may report OD4-c as CLOSED**~~ **DECIDED 2026-09-09 AND FULLY IMPLEMENTED THE SAME DAY — BOTH HALVES, (i)'s DART CONSUMER INCLUDED, so this row is CLOSED and no longer gates P4 — L-121, L-133, L-134**; added 2026-09-05; ~~**the one row in this register that is NOT decided**~~ ~~— **OD4-d joined it 2026-09-08, so this register now carries TWO open rows**~~ **— OD4-d was decided the same day, so this register carries NO open row; L-121**) | A burst killed mid-publish leaves the group wedged, and the engine does not recover it. Two independent reasons, both verified against the pinned MDK v0.9.4 (`e391adc`): (a) the re-fetched own commit comes back TERMINAL — a durable `MessageRecord` in `MessageState::Sent` maps to `IngestOutcome::Stale { OwnEcho }` (`message_processor/store.rs:24-27`) and that recorded outcome is consulted FIRST in `do_ingest` (`ingest.rs:417-420`), so the next burst's full re-REQ re-downloads the bytes and discards them: the device stays at epoch N while peers are at N+1 and later peer commits buffer un-chainable; (b) for the removal-bearing case every burst can stage — a peer `SelfRemove` auto-commit from `resolve_publish_work` — `PendingCommitRecovered` is never emitted at all, because hydrate short-circuits on `staged_removes_member` (`engine.rs:820-828`). ~~The upstream fix (epoch-gap backfill, #825/#877/#892) is in MDK master and UNRELEASED at the pin (`MARMOT_PROTOCOL_KNOWLEDGE.md:57-59`).~~ **CORRECTED 2026-09-05 (verified against a full MDK clone, both endpoints extracted with `git archive`): #825 (`363b1fe3`) and #892 (`e6654ece`) SHIPPED in v0.9.5 — and are UNREACHABLE from Haven's five pinned crates at every tag up to v0.9.18. #892 touches none of the five; #825's `CursorPersistence{Advance,Frozen}` policy lives on `MarmotAppConfig` in `marmot-app`, which `haven-core/Cargo.toml:52-53` rejects and `check_mdk_supply_chain.sh` hard-fails on. #877 UNVERIFIED. There is therefore no tag to bump TO for this fix (§5.7 P4M, central finding).** Both behaviours predate P4; P4 multiplies the EXPOSURE, because its premise is a process iOS may kill between bursts and every burst that ingests a peer `SelfRemove` opens a publish-before-apply window | **NO RECOMMENDATION IS MADE — this row needs an owner decision, and the plan deliberately does not pre-empt it.** The two honest options named by the review: **(i)** surface the stuck state as a `GroupUnrecoverable`-class status and force a re-invite (Haven-side, shippable at the current pin, costs the affected circle a re-invite); ~~**(ii)** make a bump to a RELEASED MDK tag containing the epoch-gap backfill a **P4 precondition** (no Haven-side workaround, but P4 then waits on an upstream tag that does not exist yet, and the bump is itself a migration under the MDK pinning rule).~~ ~~**OPTION (ii) IS DEAD — CORRECTED 2026-09-05.**~~ **THAT CORRECTION WAS ITSELF WRONG — RE-CORRECTED 2026-09-08 against a full clone, every tag v0.9.4→v0.9.19 read as source.** The narrow fact stands: the #825/#892 BACKFILL is unreachable at every tag through v0.9.19 (`CursorPersistence` and `client/epoch_stall.rs` live only in `marmot-app` / `marmot-c` / `marmot-uniffi` / `cli` / `marmot-forensics`, never in the five pinned crates). **The INFERENCE drawn from it was false.** "The backfill is unreachable" does not imply "no bump fixes OD4-c": **v0.9.5 (`5729f6cd`, commit `b5297d4d` #1098) shipped a DIFFERENT and sufficient mechanism — durable outbound-fanout resumption — entirely inside `cgka-traits`, `storage-sqlite`, `cgka-engine` and `cgka-session`, ALL FOUR OF WHICH HAVEN PINS.** Hydrate gained a `restored_pending` branch computed from `list_outbound_fanouts_for_group` **above** the `staged_removes_member` guard, which became four-way (`&& !restored_pending && !restored_durable_evolution`); when it fires, `epoch_manager.restore_pending(...)` brings the group back in `PendingPublish` **removal-bearing or not**. That is OD4-c mechanism (b) directly, and it makes mechanism (a) irrelevant (the crash is recovered locally from the frozen event, so the `OwnEcho` discard no longer matters — that discard is itself UNCHANGED at every tag). It needs NOTHING from a rejected crate: `OutboundFanout::stage()` is `pub` in `cgka-traits` and `put_outbound_fanout`/`outbound_fanouts`/`delete_outbound_fanout` are `pub` on `AccountDeviceSession`. **It is OPT-IN**: the engine reads fanouts on hydrate but never writes one for Haven-authored or auto-commit publishes (MDK's own writer is `marmot-account::runtime::publish_one`, which Haven rejects), so Haven must stage them in `auto_commit.rs` / `processor.rs::resolve_publish_work`. Take **v0.9.12 or later**, never v0.9.5–v0.9.11: those demand a `fork-{prior_epoch}-…` snapshot and QUARANTINE the group if absent. **So the reason not to bump is the flag day, NOT unreachability** — and per §5.7 that flag day lands in full at v0.9.5, the first rung, not at v0.9.18. Also closed: **#877 (`2a437a70`) is IRRELEVANT, not merely unverified** — it touches only `incident-replay` and `cgka-conformance-simulator`, zero pinned crates. ~~**OD4-c therefore collapses to option (i) or to an explicitly accepted residual** — and it stays UNDECIDED between those two; the plan still does not pre-empt it. Recording the risk and shipping without (i) is a REMAINING option only if the owner says so explicitly, and it must then be written down as an accepted, named residual — not left implicit~~ **DECIDED BY THE OWNER 2026-09-09 — BOTH HALVES: option (iv) AND option (i)**, ~~and the implementation is OWED (L-121).~~ **and the RUST implementation LANDED the same day (L-121, L-133): `ReceiveAutoCommitPolicy::DeferToForeground` for (iv), read by `EngineProcessor` from one atomic the session writes from its typed `BurstKind` before any REQ; `LiveSyncEvent::GroupUnrecoverable { nostr_group_id }` for (i), crossing the FFI as the additive nullable `unrecoverableNostrGroupId`. ~~Only (i)'s DART CONSUMER is still owed — nothing reads the verdict, so the user is not told.~~ **AND (i)'s DART CONSUMER LANDED THE SAME DAY TOO (L-134): the live-sync status handler reads `unrecoverableNostrGroupId` ahead of its null-reason early return, resolves the circle and marks it blocked, and the circle-details banner names that circle and offers a re-create that pre-fills its display name without touching the broken group. It announces on the SECOND foreground open — a two-observation debounce keyed to re-anchor GENERATIONS rather than to a clock — because one verdict can race a remaining peer's healing commit, and that is the same horizon as the repair itself. ZERO ARB keys were added: English-only is a red gate here, so the affordance reuses `legacyCircleRecreateCta`, already in all thirteen locales.** **(iv)** keep removal-bearing auto-commits OUT of background bursts, which removes the route every burst can hit — the peer `SelfRemove` auto-commit `resolve_publish_work` stages inside a burst, i.e. mechanism (b) above, the one hydrate never emits `PendingCommitRecovered` for because it short-circuits on `staged_removes_member`. **(i)** detect the stuck state that survives (iv), surface it as a `GroupUnrecoverable`-class status and force a re-invite. **(i) is not optional, and the reason is the pillar order rather than a preference:** for a location-sharing app a user who believes they are sharing and is not is a **safety** failure, not a UX one — this wedge is SILENT and indistinguishable from "my friend stopped sharing", and silence is the worse half, which is exactly what (iv) alone would leave. **Option (iii) — accept it as a bare residual — is EXPLICITLY REJECTED**, which retires the "REMAINING option" this cell held open: shipping with the risk merely recorded is no longer available. (ii) stayed dead | ~~P4 completion (P4-7's "phase complete")~~ ~~**P4 completion now waits on the IMPLEMENTATION, not on the decision (2026-09-09): the decision is taken, no phase may report OD4-c as CLOSED, and §9.9's owed list carries it**~~ **P4 completion no longer waits on OD4-c at all (2026-09-09): decision taken, both halves implemented, §9.9's owed list carries NO OD4-c item (L-121, L-133, L-134)**; §5.4 Design + Risks rows (both cross-reference this row); ~~no test covers either branch today and **the Rule-13 source gate stays green through both**, so nothing goes red to remind us — which is why each half lands with a test that reddens when that half breaks~~ **BOTH BRANCHES NOW REDDEN (2026-09-09): `haven-core/tests/od4c_removal_deferral_e2e.rs` carries the behavioural proofs and `security_rule_gates.rs::od4c_a_background_burst_cannot_publish_a_removal_bearing_auto_commit` pins the structure — that the receive path resolves through the policy-taking entry point and never the unconditional publisher, that the policy is set before the burst's REQ, that `start` never redeems, and that the redemption never rolls back. A SECOND structural gate, `security_rule_gates.rs::od4c_no_plane_can_roll_back_or_hide_a_removal_bearing_auto_commit`, extends both facts off the burst plane: the fail rung refuses to roll a removal-bearing commit back for EVERY caller (including the two Dart planes), every plane records the obligation write-ahead, a confirmed publish discharges it, the `EpochChanged` fold clears only an orphaned one, and the catch-up sweep never redeems. ~~What still has NO test is the half that has no code: nothing consumes the verdict~~ **THAT CLAUSE IS NOW WRONG AND IS STRUCK RATHER THAN QUIETLY EDITED: the half HAS code, it landed 2026-09-09, and it has tests of its own — the status router's wedge cases (one verdict does not block, a repeat in the same re-anchor does not block, a later re-anchor does, it blocks only the circle it names) and the banner's re-create cases. Nothing about OD4-c is now untested; what is left is the residual list in §5.4 and residual 4 of `SECURITY.md`** (L-133, L-134) | ~~if (i) is declined, (ii) gates P4 on an upstream release~~ **— (ii) no longer exists (2026-09-05)** and **(iii) was rejected outright on 2026-09-09**, so this column is history: nothing here is declined any more. **What would INVALIDATE the decision:** evidence that the wedge is unreachable at the shipped pin `e391adc`, or an upstream fix landing INSIDE the five pinned crates *without* the flag-day cost — v0.9.5's durable outbound-fanout resumption is such a fix and does NOT qualify, because at v0.9.5 the flag day is already paid in full (L-93) and the untagged-OpenMLS gate now sits in front of it (L-124) |
| **OD4-d** (~~OPEN~~ ~~**DECIDED 2026-09-09 — IMPLEMENTATION IN PROGRESS**~~ **DECIDED 2026-09-09 AND LANDED THE SAME DAY — CLOSED**; added 2026-09-08) | P4-7 flipped this lane from `HAVEN_LIVE_SYNC: "false"` to `"true"`, which was right (P2c cannot exist without the receive engine, and true is the shipped default) but silently ended the only real-OS-backgrounding coverage the POLL configuration of the iOS background branch had. `OVERLAY_BUNDLE_ID` / `com.apple.Preferences` occur in `e2e-ios-background-publish` and nowhere else in the repo; `e2e-ios` runs its poll variant FOREGROUNDED. The compensating control three files claimed — "its own background receive timer is pinned by `check_ios_background_publish.sh` check 6" — **does not exist**: check 6 pins the C4 watcher and a negative about where that watcher may live, and deleting `_startIosBackgroundReceiveTimer` outright leaves it passing (mutation-tested). So nothing pins that the poll path's background receive timer exists, fires, or reaches `_runBackgroundCatchUp` → `runCatchup(isBackgroundWake: true)`. **Buy the coverage back, or accept the gap?** | ~~**NOT TAKEN — owner's call, deliberately left open** (CLAUDE.md "STOP and ask").~~ **TAKEN BY THE OWNER 2026-09-09 — BUY THE COVERAGE BACK, option (b), and it LANDED the same day (L-122; the five decisions the implementation itself took are L-126–L-130).** The leg as costed: **(b)** a second matrix leg on `when-in-use` only, `HAVEN_LIVE_SYNC: "false"`, running P1/P2a/P2b/P3 and SKIPPING P2c (which has no session to read without the engine) — ~~one extra ~65-minute macOS job per run of the lane~~ **~62 minutes as it landed, and it does not SKIP P2c so much as branch away from it; the landed record at the end of this cell has both corrections**. **Why one job is worth it:** the poll path is a SHIPPED ROLLBACK configuration with its own distinct background branch — a 90 s `Timer.periodic` → `runCatchup(isBackgroundWake: true)`, not the burst coordinator — and its failure mode is **silent sharing loss**, which is the worst possible thing to discover while reaching for a rollback during an incident. **Rejected: accept the gap** — the branch would ship with host tests and the foregrounded core-flow lane only, and a rollback would then be taken on faith. The cheaper partial — a STATIC existence pin in check 6 (`_startIosBackgroundReceiveTimer` still exists and still calls `_runBackgroundCatchUp`) — is not the decision and never substitutes for it: it is structure, not runtime coverage, and L-98 is the record of what happens when structure is cited as coverage. **LANDED 2026-09-09 — what shipped, where it differs from the costing above, and the ceiling a green may never be read past.** The lane runs **three legs over two axes**, as explicit `include:` entries rather than a crossed matrix — `when-in-use-live-sync`, `always-live-sync`, `when-in-use-poll` — with `leg` replacing `tier` as the per-job identity (job name, cargo cache key, failure artifact), and there is deliberately **no `(always, poll)` leg**: the poll leg's subject is the receive PLANE, orthogonal to the grant, so a fourth ~62-minute macOS job would only re-read a tier policy the always-live-sync leg already proves (L-126). **The cost, corrected: one extra ~62-minute job, not the ~65 this row costed.** 65 was the LIVE-SYNC per-attempt deadline (22 min of fixed overhead + the drive target's `Timeout(40 min)`); the poll leg's drive `Timeout` is **37 min**, because P2d costs 362 s where P2c costs 490 and its P1 loses both the confirmed-Always poll and the 95 s standing-REQ wait — so the per-attempt deadline has to CLEAR 22 + 37 = 59 min and is set at **62 min/attempt** (which also keeps 62 − 37 = 25 ≥ 22, the margin check 15 enforces), and `DISABLE_WAIT_POLL_SECS` is 1310 s against the live-sync legs' 1440. **And the leg does not SKIP P2c, it BRANCHES** (L-128): the drive reads `if (liveSyncEnabled) { P2c } else { P2d }` at compile time, so exactly one of the two runs, neither is ever skipped and no undeclared-skip manifest row was needed — and P2c's foreground control arm became two-armed, `poolSubscriptionCount()` reading non-zero on a live-sync leg and having to THROW on the poll one, which is the observable statement of WHY P2c cannot exist there. **What the leg PROVES:** a peer publishes a sentinel fix while Alice is OS-backgrounded, **no tick is driven**, and `MapShell._startIosBackgroundReceiveTimer`'s 90 s `Timer.periodic` → `_runBackgroundCatchUp()` → `CatchupService.runCatchup(isBackgroundWake: true)` must land that peer's location — coordinates asserted, never mere presence — in the **PERSISTED** last-known store (`snapshotLastKnownForCircle`), compared against a pre-publish baseline. Its window is 215 s (two 90 s ticks + the sweep's own 20 s deadline + 15 s of slack) and the SECOND tick is a race fix rather than slack (L-129). New guard **check 16** (`check_poll_path_receive_cadence`) pins `map_shell.dart`'s 90 to the drive's `_pollPathReceiveInterval` (L-130). The per-leg completion gate demands four shared proofs plus exactly one per axis, each REFUSED on the legs that must not produce it, and the poll leg's set is **five, not the four this row's "skip P2c" implied** (L-127). Wrapper self-test fixtures 53 → 64; the guard's own fixture total is `SELF_TEST_FIXTURES` in `check_ios_background_publish.sh` and is deliberately not quoted here — this cell carried `163 → 177` and the constant had moved again within the day (§9.9's fixture-count rule; L-130). **THE CEILING.** The leg does **not** prove the burst plane (this build lacks it); **not** the C3 chokepoint that refuses a wake after consent withdrawal (the C4 watcher cancels this timer on that edge before the chokepoint is reached; host tests own both halves); and **not** the timer across a jetsam kill, an SLC relaunch, or hours. A green shows **ONE real backgrounding for the length of the lane's window, on a simulator that cannot be suspended like a phone.** `check_ios_background_publish.sh` check 6 still does not stand in for any of this — check 16 and P2d are what do. The physical-device ceiling is UNCHANGED: `docs/M7_BACKGROUND_SHARING.md` §6 item 0/0a stays DEFERRED and nothing here may be cited against it | the lane's own "What this lane does NOT prove" header; §5.4's landed correction; the drive target's library doc — **all three carriers now state the retraction (re-verified in the working tree 2026-09-08; this cell said the third was "still to be retracted", which is no longer true)**. **And from 2026-09-09 the retraction has a DECISION behind it rather than a gap: the coverage the disproved claim stood in for ~~is being~~ was bought back (L-122), and the lane's "does NOT prove" header is what the new leg's own header ~~must be~~ was written against — it now carries the poll leg's own ceiling paragraph.** **The last stale carrier was CLAUDE.md's "CI Pipeline" entry, which still called this configuration UNCOVERED and OD4-d open; corrected 2026-09-09.** | ~~the flag-off iOS background branch ships with host tests and the foregrounded core-flow lane only, and every document naming that gap must keep naming it — the residual is the decision, not a caveat on it~~ **— that was the "accept the gap" branch and it was NOT taken (2026-09-09).** This column is history: ~~until the second leg is green every document naming the gap must keep naming it, and the day it is green they state what it actually covers — the when-in-use tier, flag off, P1/P2a/P2b/P3, no P2c~~ **— that instruction is DISCHARGED (2026-09-09), and its last clause was wrong about the leg it described: the leg covers the when-in-use tier, flag off, P1/P2a/P2b/P3 and P2d IN P2c's PLACE, which is a branch and not an absence** |
| **OD-P2-1** | `P0_1_FGS_SESSION_PLAN.md:430-433` GPS-ownership decision — P2 decides "the FGS owns GPS while backgrounded; UI stream released at pause; no `Position` injected across isolates" | accept | P2a doc record | none viable — the alternative (UI isolate keeps GPS) is R-C |
| **OD-P2-2** | The delivery→Dart suspend window U-P2-1 exists ONLY once the plugin lock is gone (P2b); its consequence is a ONE-CYCLE TTL BREACH (realized gap ≈ J + I ≤ 326 s > 228 s: every peer's marker expires once) at a probability p only hardware can measure | decide P2b's design on that consequence: the native `PendingIntent`/`LocationListener` registration (D4, BR-1) closes it BY CONSTRUCTION (the lock is acquired inside the system's delivery hold) — recommended over "measure p and accept". **AMENDED 2026-08-30 (§2.5): p is now UNMEASURABLE, which STRENGTHENS the same recommendation rather than reopening it.** The alternative was always "measure p and accept a known number"; with no Android phone there is no number to accept, so the only remaining choices are "close it by construction" (the recommendation) or "accept a TTL breach of unknown probability", and the second is precisely the FA wedge posture this plan exists to end. What the owner is deciding on instead: the CONSTRUCTION argument (the lock is taken inside the system's delivery hold, so no window exists to measure) plus the emulator no-fix chain oracle under `dumpsys deviceidle force-idle` (B1 step (8)), which proves the Doze *policy* half — **LANDED 2026-09-04 as a second forced-idle phase after `HOLD_COMPLETE` (§5.2 step (8)): `state=IDLE` read back from `dumpsys deviceidle get deep` AND a `trigger=watchdog` publish within 302 s, six fixtures. This half of what the owner is deciding on is now held, not owed.** Residual, stated: the emulator does not suspend the AP, so "the delivery wakes Dart on a genuinely suspended AP" stays **NOT AVAILABLE** (U-P2-1) | P2b design + the forced-idle liveness row — **the liveness row is unmeetable, so P2b is PARKED (§5.2); this decision travels with it** | accept the breach at an UNMEASURABLE p — rejected as a matter of record on 2026-08-30: an accepted residual with no number is not an accepted residual |
| **OD-P2-3** | `SCHEDULE_EXACT_ALARM` for the P2b no-fix watchdog: a NEW disclosure surface (special-access "Alarms & reminders" prompt, Play policy exposure, 13-locale copy, `docs/privacy` coverage) | NO — the default candidate is an inexact `AlarmManager.set()` while battery-exempt (fires in Doze, no permission; up to ~75 % late = a BOUNDED TTL breach, never a silent stop); revisit only if the P2b hardware row shows the inexact alarm landing late in practice; declining also means the NON-exempt cohort keeps the plugin lock in P2b (no ordinary alarm fires in Doze without the exemption — D4 (iii)). **AMENDED 2026-08-30 (§2.5): the revisit trigger no longer exists** — there is no hardware row to show the alarm landing late. The NO stands on its own terms, which never depended on a measurement (a new special-access prompt, Play-policy exposure and a 13-locale copy round are costs known without a phone); what is lost is only the ability to discover that the inexact alarm's ~75 % lateness is unacceptable in practice. That discovery is now deferred to the P2b un-park, and the bounded-breach-never-silent-stop argument (AlarmManagerService `FLAG_ALLOW_WHILE_IDLE_UNRESTRICTED`, §2.2) is what the decision rests on | P2b — **PARKED (§5.2); this decision travels with it** | the inexact alarm for the exempt cohort; the plugin lock for the non-exempt cohort (default) |
| **OD-P3-a** | `kStationaryDwell = 120 s` (one nominal interval) before dropping to HundredMeters | 120 s — longer saves less, shorter risks Best↔100 m flapping at walking pace; in poor coverage the controller spends up to ≈ 59 % of the time at Best (120 s Best / 84 s HundredMeters cycles) — the §6.5 "profile duty" column is the number to re-tune on. **AMENDED 2026-08-30 (§2.5): the profile-duty column is DEFERRED** — it is computed from a `locationd` console trace on a physical iPhone, so 120 s ships un-tuned and STAYS un-tuned until hardware returns. What the owner is deciding on instead: the flap-risk argument alone (120 s = one nominal interval; shorter flaps at walking pace, longer saves less), which never needed a measurement. The ≈ 59 % worst-case Best duty in poor coverage remains an **ESTIMATED** arithmetic consequence of the 120 s / 84 s cycle (§6.5a), not an observation, and it is the first thing to re-check on the first real device | P3 constant + `location_test.dart` pin | any value is a one-constant edit + pin |
| **OD-P3-b** | Provisional Always on iOS 17 (no diagnostics API): WIU policy (activity session held, pill shown until the second prompt) or "treat as Always" (no pill) | **WIU policy** (recommendation reversed on review): "as Always" removes the one object added after the 2026-08-20 field failure for a cohort the OS itself treats as WIU — silent publish loss, the FA wedge class; the cost is a pill for a small cohort. **AMENDED 2026-08-30 (§2.5): this decision is the one the constraint most strongly VINDICATES.** WIU policy is the fail-safe branch — it keeps the object added after the 2026-08-20 field failure — and its alternative was only ever defensible with a device result attached (see "If declined"). With no device, "treat as Always" would ship an un-evidenced liveness change to a cohort the OS treats as WIU; that is not available. No change to the recommendation; the residual (a pill for provisional and iOS-17-Always users) is unchanged and is disclosed by the card | P3 `arm()` iOS 17 branch (`alwaysConfirmed` stays false) | "as Always" on iOS 17 — must be recorded as an ACCEPTED liveness risk for that cohort with the V-P3-3 device result attached. **NOT AVAILABLE 2026-08-30**: V-P3-3 cannot be produced, so this alternative is unavailable, not merely un-recommended |
| **OD-P3-c** | Fund a second `e2e-ios-background-publish` run under `location-always` (~40 min/run) | YES — its VALUE is the keep-alive proof under the Always SHAPE: publishes continue from the background with NO activity session held and `alwaysConfirmed == true` (a real runtime oracle, and the only CI evidence for a shape whose closest physical neighbour FAILED on 2026-08-20). The pill itself is HARDWARE-ONLY: a simulator cannot show it and `indicatorShown` would be a self-report the Swift guard already pins statically — the run does NOT claim to prove the indicator. Regardless of the decision, hardware 0a (≥ 2 h stationary, Always, accuracy 100 observed in Console) is a WP3-2 merge gate. **AMENDED 2026-08-30 (§2.5): hardware 0a is DEFERRED, so this run stops being "a second line of evidence" and becomes THE ONLY runtime evidence for the Always shape.** The YES therefore hardens from "worth ~40 min/run" to "mandatory": declining it would leave the shape shipped under Always with static guards and host tests only. Everything the row already says about what it does NOT prove (the pill is hardware-only; `indicatorShown` would be a self-report) stands unchanged and is now the plan's stated residual, not a caveat | P3 lane matrix (`ALWAYS_SESSION_OK`, P2a/P2b under Always) | hardware 0a merge gate + b7's session-held-per-tier oracle are the whole proof for the shape — **and with 0a deferred, declining this run would leave NO runtime proof at all for the Always shape** |
| **OD-P3-d** | `kStationaryConfirmMaxAccuracyMeters` — the accuracy a 100 m-tier fix needs to CONFIRM stillness | **100 m** (= `kMotionTriggerDistanceMeters`; changed from 200 m on review). Consequence of any cap C, stated: while confirming fixes keep arriving, a true displacement below 100 m + C goes undetected and the served coordinate is up to that stale — 200 m at 100 m, 300 m at 200 m — against today's 100 m of Best-grade travel; a fix that cannot resolve 100 m cannot vouch for 100 m of stillness, so it is ignored and the 84 s escalation decides with GPS truth | P3 constant + pin + controller test `a confirmed anchor is never more than kMotionTriggerDistanceMeters + kStationaryConfirmMaxAccuracyMeters from any confirming fix` | one-constant edit, with the bound in the doc re-derived |

---

**Three further decisions taken by the owner on 2026-09-04**, arising from the P3 security and UI/UX review
waves (§8). All three ACCEPTED as recommended:

| OD | Question | Decision |
|---|---|---|
| **OD-P3-e** | The confirmation chain removes the 168 s ceiling on how old a PUBLISHED coordinate may be: a stationary backgrounded device re-publishes the same Best anchor indefinitely, each stamped `Utc::now()` at encrypt, so a peer's age pill reads "just now" for a fix that may be hours old and up to ≈ 200 m wrong. Sending the true fix age would need a new wire field, which D0 forbids. | **CAP THE CHAIN, and test it.** A confirmed anchor may not be served beyond a bounded multiple of `kStreamPositionMaxAge` no matter how many coarse fixes confirm it; anchor age becomes a SECOND escalation trigger alongside `kStationaryConfirmMaxAge` (which only fires when *nothing* confirms). Bounded staleness, no wire change, a modest battery cost. The 200 m displacement bound — currently asserted by no test — gets one at the same time. |
| **OD-P3-f** | The iOS settings copy is true in every state once the sharing-off defect is fixed, but has five source-level weaknesses (dangling "this permission"; a While-In-Use note whose advice silently removes the bar it just promised; an English-only doubled "While… While…" that the reviewer wave already fixed in 12 locales; a vague "lists Haven" that is the transparency payload for the cohort that LOST the bar; a 70-word intro with a comma splice showing both platforms to every reader). Each needs a fresh 12-language translation + review wave. | **FULL English revision, ONE wave.** The cost of a wave is the 12 reviewers, not the string count, so a minimal fix costs nearly the same as doing it properly. |
| **OD-P3-g** (LANDED 2026-09-04) | `location_disclosure_dialog.dart` holds the prominent-disclosure consent strings as hard-coded English `static const`, not ARB — so users in the other 12 languages are asked to consent in English. Pre-existing; not introduced by P3. | **LOCALIZE IT NOW**, folded into the OD-P3-f wave. Consent the user cannot read is a weak basis for a permission gate. Note the manifest tie: `LocationDisclosureStrings.backgroundIos` is a `non_arb_claims` carrier of `INV-L-IOS-WAKES-RECEIVE-ONLY`, so the move changes a carrier's KIND and must be reflected in `privacy_invariants.json` and proved against the ratchet. |

---

**Three further decisions taken by the owner on 2026-09-09**, arising from P5(a)'s deferral arithmetic, the review
of the shipped P4-7 lane and the MDK v0.9.18 survey. Each is recorded with the gate it must clear, because two of
them are "not yet" rather than "yes", and a "not yet" with no named gate is how an item rots (§9.9).

| OD | Question | Decision |
|---|---|---|
| **OD5-a** | P5(a)'s cap defers a burst's tail past `kMaxCirclesPerBurst` = 11, and a deferred circle's realized gap is TWO sampled intervals — 144 s best, **240 s mean**, 336 s worst — against the **228 s** kind-445 retention, so most deferrals leave a peer's marker expired; it worsens to three intervals at 23–33 circles and four or more from 34 (L-100, L-101). **Nothing in the app bounds the roster.** Close the hole with a roster bound, close it with a longer retention, or accept it? | **BOUND THE ROSTER AT 10 CIRCLES** — decided 2026-09-09 (L-123), ~~implementation in progress~~ **LANDED and reviewed on two planes the same day (L-132); the first implementation's check was ADVISORY UNDER CONCURRENCY and the review is what made it a bound**. **The argument is a trilemma, not a one-liner:** a wide whole-second delta alphabet, no retention hole, and large rosters are **mutually exclusive**, because the 30 s burst-spread budget (`kPublishStaggerMaxSpread`) comes out of the retention margin and the burst's *n − 1* gaps must fit inside it. At ten circles **no circle is ever deferred**, so the hole disappears at every reachable roster, with **one circle of headroom** below `kMaxCirclesPerBurst = 11` — which is why 10 and not 11. **As it lands:** the constant is `kMaxCirclesPerAccount` beside `kMaxCirclesPerBurst` in `publish_stagger.dart`, and the refusal is enforced in `NostrCircleService` at the only two calls that grow a roster — `createCircle` and `acceptInvitation` — as a typed `CircleRosterFullException` (a POLICY refusal, so the copy can name the limit and the remedy instead of "please try again"), counting ACCEPTED memberships only and failing CLOSED on a roster read that throws. **Rejected, with reasons:** *lowering the burst cap instead* — it widens the alphabet but makes deferral, and therefore the hole, start EARLIER; *lengthening `LOCATION_MESSAGE_RETENTION_SECS`* — events then live longer on relays, which is worse privacy (and a wire change D0 forbids); *accepting the hole* — a silent coverage failure a peer experiences as "their location stopped updating". **The honest cost, disclosed rather than hidden:** a NEW user-visible limit — an eleventh circle is refused — and the stagger's whole-second delta alphabet still thins with the user's own roster, `{2…9}` at four circles or fewer down to `{2,3,4}` at ten. |
| **OD-P2-4** | D3 (iii)'s accepted residual puts the worst realized no-gap figure at **248 s** on Android API 23–30 (cold acquisition; L-50). `POWER_MEASUREMENT.md` §7's forced-idle row cross-referenced that residual and left it undecided whether it extends to **P2b's forced-idle merge gate**. | **IT DOES NOT — the forced-idle gate holds 228 s** (L-125). Forced idle is the scenario that gate exists to catch: if a real device cannot meet 228 s there, that is a **finding to file**, not a threshold to relax, and loosening a merge gate to accommodate untested platform behaviour is how a real regression ships. The 248 s residual is unchanged where it was accepted — an ordinary acceptance row on API 23–30 — and does not travel to this gate. **The row was cross-referenced-but-undecided until today and is now decided;** `POWER_MEASUREMENT.md` §7's cell was the one site still reading "left open" and now records the decision and the scoping (edited 2026-09-09, same day). |
| **OD-P4M-1** | From v0.9.5 the MDK workspace replaces crates.io OpenMLS with `git = "https://github.com/erskingardner/openmls.git", rev = "59e7d3b2…"` — the head of `refs/heads/codex/reject-app-data-trailing-bytes` on a fork carrying **no tags at all**, force-pushable and deletable (§5.7 finding (3), blocker B1; L-94). Bump anyway? | **DO NOT BUMP while that is true — and this is a "not yet", not a "no"** (L-124). For a cryptographic application, taking an untagged branch head as the supply-chain anchor **for the MLS implementation itself** outweighs the four wedges the bump would fix, and it contradicts the project's own pinning rule that a released tag is the only acceptable supply-chain anchor. **The action is to raise it upstream and ask for a tagged OpenMLS.** This is **not** a rejection of the bump's value: it would fix **OD4-c** (v0.9.5's durable outbound-fanout resumption, reachable inside the five pinned crates — L-93), the **sender-ratchet reorder** wedge, the **Rule-12 no-eviction caveat CLAUDE.md itself records**, and the iOS `0xdead10cc` SIGKILL class. **The unblock condition — the gate — is a tagged OpenMLS dependency**, recorded so a future reader re-checks that one fact instead of re-deriving the whole survey. The flag day itself stays a separate, untaken decision at P4M-2, now behind this gate. |

## 5. Phases

Phase order and dependencies: P0 → P1 (incl. P4-1's bounded inbox lookback) → {P2a, P3 in parallel} → P4
(needs P1's D5 and P3's native owner for the lane; OD4) → P5 (OD3; needs P4 for the iOS-bg tick sink) → P2b
~~(needs P2a's hardware row + OD-P2-2/OD-P2-3)~~ **— P2b is PARKED 2026-08-30 (§5.2, §2.5): its gate is forced-idle hardware liveness, which cannot be met, and its saving (the AP-suspend term) cannot even be estimated (§6.5a E-P3). The chain is now P0 → P1 → {P2a, P3} → P4 → P5 → P6, with P2b out of it entirely** → P6. Every phase is independently shippable, and P2a in particular is self-contained without P2b (§5.2).

**Milestone P4M (§5.7, added 2026-09-05) is NOT in that chain.** It runs after P6 closes, alone: it cannot be P4's precondition (the fix that made it one is unreachable at every MDK tag), it cannot run beside P4 or P5 (it moves `IngestOutcome`, `StaleReason`, `GroupEvent` and `PublishWork` underneath both), and it contributes nothing to power. It is also the one item here that a revert cannot undo — the storage migrations have no `down` — so it goes last and only on an explicit owner flag-day decision. The recommendation in §5.7 is to take **P4M-1 only** for now.

### 5.0 Phase P0 — Baseline (ESTIMATED, model E — the measured one is NOT AVAILABLE, §2.5) + doc-drift fixes + accuracy pins + literal→constant

**Goal / non-goals.** ~~Deliver the two numbers every later phase is judged against (iOS %/h backgrounded-stationary;
Android per-uid GPS / wake-lock / radio time) on the SAME two phones with the SAME protocol P6 re-runs~~ —
**AMENDED 2026-08-30 (§2.5): the two numbers CANNOT be delivered; there is no iPhone, no macOS machine and no
Android handset for the duration.** P0's baseline goal is replaced by: deliver an **ESTIMATED** baseline from model
E (§6.5a) and the CI-observable **mechanism proxies** that stand in for it (§6.5a (ii)), and keep
`docs/POWER_MEASUREMENT.md` as the protocol to run when hardware returns. Everything else in P0 is unchanged and
lands as written: accuracy pins on both `_streamSettings` arms (today NOTHING pins `LocationAccuracy.best` —
V: `grep LocationAccuracy\. haven/test haven/lib` hits only the comments at `geolocator_location_service.dart:614,:657`),
the §1.2 drift, and three bare cadence literals converted to constants. Non-goals: no mechanism change, no ARB
change, no manifest status change, no new lane. Battery outcome of P0 alone: none — it makes P1–P5 ~~measurable~~ **estimable and, in mechanism, un-fakeable** (§2.5: the estimate is authorised; the mechanism proofs are not negotiable).

**Design.** (1) `docs/POWER_MEASUREMENT.md` (new) = the procedure (identical for baseline and acceptance) + a
results template appended per run; OS tooling only (guard 9b, `INV-R-NO-TELEMETRY-SDK`); its verbatim spec is
§6.5 — P0-C copies it out. **AMENDED 2026-08-30 (§2.5): the document LANDS AS SPECIFIED and is then marked DEFERRED
at the top — it is not cut down, not simplified and not "left for later", because a protocol written now, while the
constants and the reasoning are fresh, is exactly what a future hardware campaign will need and what a
reconstructed-from-memory version would get wrong.** Its Android half needs only an Android phone and `adb` on any
laptop, so it is runnable strictly earlier than the iOS half (which needs both an iPhone and macOS/Xcode); the
banner says so, so an Android device turning up is immediately actionable. (2) Accuracy pins are M-class assertions beside the existing filter pins so P3's
profile switch is a deliberate edit that fails a named test (the "two branches cannot converge" contract at
`geolocator_location_service_test.dart:936-947`). (3) Literal conversion keeps every tripwire's MEANING: a bare
literal becomes the constant it silently mirrored; a literal deliberately paired with its derivation stays and
gains a `reason:`. (4) Drift is corrected to TODAY's truth (pre-P1); where a later phase changes the truth again
(the standing-socket sentence) P0 writes the current fact and P6 rewrites it. Promises touched: none.
`INV-L-MOTION-TRIGGER-BOUNDED` / `INV-R-TRAFFIC-METADATA-OBSERVABLE` cite `location_test.dart` names — P0 adds
tests there and renames none (rule 3).

**Exact change list.**
- NEW `docs/POWER_MEASUREMENT.md` (§6.5) + NEW `tooling/e2e/ci/summarize-created-at-gaps.sh` with `--self-test` (the liveness column's script — `summarize-wire-journal.sh` parses the proxy journal, not a relay capture). Post-review (2026-08-30) the grader takes `--publishers` and a DECLARED run window (`--from`/`--until`) as REQUIRED input: without the window it grades only `last − first` of the events it observed, so a device that publishes for 30 min of a 3 h run and then dies, or one silent for the first 2.5 h, both read "worst gap 120 s, OK" — the exact field failure the instrument exists to catch. Head/tail silence is graded as a gap, the whole-span count floor is taken over the declared window, an undeclared run is `UNGRADED` (exit 5, never a pass), and one circle split across two capture files is refused (exit 3) rather than graded as two series whose seam belongs to neither.
- `haven/test/services/geolocator_location_service_test.dart`: in `'getLocationStream(backgroundSharingEnabled: true) sets background-capable AppleSettings on iOS'` (`:894-921`) add `expect(settings.accuracy, geo.LocationAccuracy.best);`; same in `'... false) sets background flags explicitly false on iOS'` (`:923-947`) and in `'uses AndroidSettings with distance filter and interval'` (`:732-751`); NEW test `'the requested accuracy is best on every stream arm and on the one-shot — pinned so a profile change is a deliberate edit'` capturing iOS bg-on, iOS bg-off, Android stream, iOS one-shot (`_currentPositionSettings`, `:612-620`), Android one-shot → all five `LocationAccuracy.best`, `reason` naming P3 as the only sanctioned mover.
- `haven/test/services/per_circle_due_tracker_test.dart:196`: `lessThan(const Duration(seconds: 72))` → `lessThan(kBackgroundRepeatInterval)` (the `reason:` two lines below already names it — V).
- `haven/test/services/publish_stagger_test.dart:136-139`: **the literal→constant conversion is WITHDRAWN (review, 2026-08-30; P0-A).** `Duration(seconds: kLocationPublishMaxInterval.inSeconds + 2 * kTtlNetworkBufferSeconds) - kLocationPublishMaxInterval` cancels algebraically to `2 * kTtlNetworkBufferSeconds`, so the bound stops moving with the cadence ceiling: mutating `kLocationPublishMaxInterval` 168→220 keeps the converted form GREEN where the literal reddens (both runs performed, 2026-08-30). The site keeps `const Duration(seconds: 228) - kLocationPublishMaxInterval` and gains a `reason:` naming `LOCATION_MESSAGE_RETENTION_SECS` in `haven-core/src/location/ttl.rs` — the same treatment as `location_sharing_service_test.dart:172` below, and for the same reason: a literal paired with its own derivation IS the tripwire. (Importing `kLocationMessageRetention` from `sharing_health_provider.dart` into a service test remains out: `sharing_health_recording_sites_test.dart:143-150` pins that declaration's exact text and site.)
- `haven/test/widgets/circles/circle_details_layout_test.dart:144`: `overrideWith((_) async => 228)` → `overrideWith((_) async => kLocationMessageRetention.inSeconds)` — DOCUMENTATION, not a tripwire (review, 2026-08-30). The fixture now tracks the app's own constant instead of a stale literal, which is the whole benefit; it cannot fail when the constant moves, because the sweep asserts the ABSENCE of overflow and that is value-insensitive. Verified: with `kTtlNetworkBufferSeconds` mutated 30→300 the file's 39 tests stay green while `circle_details_expiry_test.dart` goes 4 red — the value-sensitive pin lives there (`:56-60`, the literal "4 min" is also a privacy-copy claim), and it is not being moved.
- `haven/test/services/location_sharing_service_test.dart:172`: KEEP `expect(capturedUpdateIntervalSecs, 198);` and add `reason: 'deliberate tripwire paired with the derivation above — a cadence change must be a visible edit here, never a silent shift'` (same pattern as `sharing_health_provider_test.dart:683-688`; converting it would delete the tripwire).
- Docs: every row of §1.2 (16 edits incl. the two-socket fact recorded in the RC1 `accepted_deviations[]` summary and `WN_RELAY_EPOCH_SYNC_MIGRATION.md:312-313`) plus the citation-drift sweep of this plan — `M7:3-8`, `:332-336` (historical note "(at M7 time; flipped by M11 — see `docs/M11_ROLLOUT.md`)"), `:462` ("`defaultValue: true` within 3 lines of the `bool.fromEnvironment` declaration (14b)"), `:838-840`, `:1196-1199` (keep the `kMotionTriggerDistanceMeters` sentence; "the 5 m drip's only remaining role is to keep fixes flowing"), `FA:58-62`, `FA:250-253` (mark UNCITED, contradicted; retract against the in-repo field report — §7.6 makes the research reports ephemeral and explicitly not citable, so `research/reference_apps_strategies.md` is NOT a usable source), `CI_HARDENING_BACKLOG.md:2110` (append a DATED qualifier — a backlog is a log), `M11:117` + `SECURITY.md:873-878` (today's truth: the disclosure got MORE alarming, not less; heading `### Relay-observable metadata and correlation (accepted)` is a manifest `doc_anchors` target — byte-identical), `SECURITY.md:257-263` (Android sentence false), `constants/location.dart:49-50`, `config.rs:268-271` (delete both constants; `cargo clippy -- -D warnings`), `ios_location_auth_service.dart:3-5`, `AndroidManifest.xml:117`, `WN_RELAY_EPOCH_SYNC_MIGRATION.md:178,:243` (U until checked; correct with URL + date), `MESH_LOCATION_RELAY_DESIGN.md:181,:422-423`.
- Guards/ARB/native: one step only — `.github/workflows/repo-guards.yml` gains `summarize-created-at-gaps.sh --self-test` beside the other `tooling/e2e/ci` harness self-tests (`jq` is already ensured in that job), so the grader's fixtures cannot rot; no new script, no new workflow (§7.2). ARB/native: none; manifest: the RC1 summary sentence only (prose — no key, status or citation change, so no ratchet item).

**Tests FIRST.**
| file → test → promise it fails on |
|---|
| `geolocator_location_service_test.dart` → `the requested accuracy is best on every stream arm and on the one-shot …` → "the OS is asked for GPS-grade fixes on every path" (P3 rewrites deliberately) |
| same → the three inline `expect(settings.accuracy, best)` additions → same promise per arm |
| `per_circle_due_tracker_test.dart` → existing test, constant-derived bound → fails if `kBackgroundRepeatInterval` decouples from the min interval |
| `publish_stagger_test.dart` → `'the spread budget is dominated by the freshness constants it must respect'` → no-gap slack pinned to the wire literal 228, so a `kLocationPublishMaxInterval` change is a visible edit here (mutation 168→220 reddens it; the withdrawn conversion did not) |
| `circle_details_layout_test.dart` → existing sweep → no promise: the sweep asserts absence of overflow, which no retention value can break. The edit makes the fixture track the app's constant instead of a stale literal — accuracy, not coverage |
| Mutation: add `accuracy: geo.LocationAccuracy.medium` to one arm → exactly that arm's test and the five-way test go red; revert |

No existing test goes red. Commands: `cd haven && flutter test test/services/geolocator_location_service_test.dart test/services/per_circle_due_tracker_test.dart test/services/publish_stagger_test.dart test/widgets/circles/circle_details_layout_test.dart test/services/location_sharing_service_test.dart && flutter analyze`; `cd haven-core && cargo test && cargo clippy -- -D warnings`; `scripts/ci/check_privacy_invariants.sh --no-ratchet` (anchors untouched — must stay green); `scripts/ci/check_coverage.sh --static-only`.

**Implementer work packets.**
| # | Packet | Parallel? | Done when |
|---|---|---|---|
| P0-A | Accuracy pins + three literal conversions + `:172` reason (tests only) | ∥ B, C | the five named tests green; mutation check performed and reverted; `flutter analyze` clean; `--static-only` green |
| P0-B | §1.2 drift (16 edits) + `config.rs` deletion + `ios_location_auth_service.dart` comment + manifest comment + the plan's own citation-drift sweep (§1.2 note) | ∥ | `check_privacy_invariants.sh --no-ratchet` green; `cargo clippy -- -D warnings` green; every replaced sentence cites the source of the new fact |
| P0-C | `docs/POWER_MEASUREMENT.md` (protocol + empty results template, §6.5 verbatim, incl. the mandatory relay-side capture and the profile-duty column) + `tooling/e2e/ci/summarize-created-at-gaps.sh` (+ `--self-test`, healthy/229 s fixture pair) + its `--self-test` step in `repo-guards.yml` | ∥ | reviewed by the P6 reviewer for reproducibility (a second person can run it from the doc alone); `summarize-created-at-gaps.sh --self-test` green, count pinned by equality; the review's four false-green captures (dies at 30 min of a declared 3 h window; silent for the first 2.5 h; a 2-publisher capture declared as 1; one circle split across two files) each exit non-zero and each is a fixture. **Where §6.5 above still calls the Energy Log the PRIMARY iOS metric, the delivered `POWER_MEASUREMENT.md` §4/§7 and §6.6 supersede it** — the Energy Log reports a score, not %/h (see §6.6) |
| ~~P0-D~~ | ~~**Owner-run baseline** (hardware): run the protocol per platform (S ≥ 3 h on iOS — Settings › Battery is whole-percent, so 60 min cannot resolve a ≤ 1 %/h target — or 3 × 60 min summed; S 60 min on Android; W 30 min both), fill the template, commit under `## Baseline <date> <commit>`~~ | ~~after P0-C~~ | **NOT AVAILABLE 2026-08-30 (§2.5)** — no iPhone, no macOS machine, no Android handset. The baseline this packet exists to produce is a POWER-MEASUREMENT gate, which the owner has authorised replacing with an estimate. Superseded by P0-D′ below; the row is kept struck-through, not deleted, so nobody later reads a missing baseline as "somebody forgot" |
| **P0-D′** | **ESTIMATION MODEL + PROXY REGISTER** (replaces P0-D): write §6.5a — model E's inputs, parameters, arithmetic and the ESTIMATED per-phase before/after table — and the CI-observable proxy register that states, per model term, which lane/oracle proves the MECHANISM changed. Mark `docs/POWER_MEASUREMENT.md` DEFERRED at the top (protocol intact, still authoritative, Android half runnable earlier) | after P0-C | §6.5a exists with every input carrying an in-document citation, every parameter declared as an assumption, and every output tagged **ESTIMATED**; the proxy register names a real lane, oracle or host test for every term (each verified to exist by grep, not by recollection); `POWER_MEASUREMENT.md` carries the deferral banner and no protocol step is weakened or deleted; **no number anywhere in the plan reads as measured** (a reviewer sweep for the words "measured", "observed" and "%/h" that are not tagged) |

**Reviewer checklist.** Every doc edit replaces a wrong fact with a cited right one and deletes no load-bearing
rationale (R1–R14 in `_docs_a11y.md` §0); the `M11:117`/`SECURITY.md:873` rewrite states iOS-bg socket
persistence honestly and keeps the anchor heading byte-identical; no ARB value changed; the accuracy pins assert
on the captured `LocationSettings`, not a mock default; `:172` is still a literal; `POWER_MEASUREMENT.md` names only
OS tooling.

**Risks / rollback.** ~~The baseline may reveal a liveness gap (> 228 s at the relay) — a P0 finding, never a reason
to soften the protocol; the template forces the network column so the owner cannot measure on Wi-Fi twice, and the
start state-of-charge column so %/h figures are comparable.~~ **AMENDED 2026-08-30 (§2.5).** The risk inverts: with
no baseline row, every later phase's "relative to the P0 baseline" threshold has no denominator, so the RELATIVE
column of §6.6 is as unevaluable as the absolute one — both are re-stated as ESTIMATED in §6.6, and neither may be
quoted as a result. The controls the template forces (fixed network, fixed start SoC) still matter, but only for the
day the protocol is finally run. The real new risk is **estimate creep**: a number produced by §6.5a's arithmetic
being restated three documents later without its tag, and read as a result. Mitigations: every model output carries
the word ESTIMATED in the same sentence; §6.6 has no un-tagged number left; the P6 reviewer checklist adds a sweep
for un-tagged energy figures.
Rollback: one revert (tests + docs); nothing behavioural.

**Acceptance.** CI: all P0 tests green; guards green; `--static-only` green (tests-only diffs never move floors).
**LIVENESS gate (re-based):** none for P0 — P0 changes no mechanism, so there is nothing for it to keep alive; the
existing lanes stay green, which is the whole of its runtime obligation.
**POWER-MEASUREMENT gate (estimate-replaced):** ~~`POWER_MEASUREMENT.md` carries one filled baseline row per platform
per scenario with raw artefacts named (batterystats checkin, bugreport zip, iOS Battery screenshots, Energy Log
trace) and the app commit hash~~ → §6.5a carries the **ESTIMATED** baseline for both platforms, with every input
cited and every parameter declared; `POWER_MEASUREMENT.md` §9 stays EMPTY under `## Baseline`, which is the honest
state — an empty results table is a missing measurement, and a table filled with estimates would be a forged one.
**Never write an estimate into `POWER_MEASUREMENT.md`.** That document records measurements only; model E lives in
this plan.

**Owner decisions / open questions.** None blocking.
**V-P0-1 RESOLVED 2026-08-30 (P0-A):** the import is clean — `circle_details_layout_test.dart` imports
`package:haven/src/providers/sharing_health_provider.dart` and the file's 39 tests pass, so no inline
copy of the derivation is needed. See the change-list row above for what that edit does and does not buy.
**V-P0-2 RESOLVED 2026-08-30 (P0-B):** confirmed set-not-gated — `_onResumed` writes `_lastPublishTime`
unconditionally (`map_shell.dart:1695`) and the guard is consulted only by `_guardedPublish`
(`:1130-1136`), reached only from the motion trigger (`:1122`); the constant's doc and the
call-site comment (`map_shell.dart:1119-1121`) now both say so.
**U-P0-1 RESOLVED 2026-08-30 (P0-B):** the WN 6 h claim is FALSE, not merely unverified — the Android 15
timeout covers only `dataSync` and `mediaProcessing`, in Google's own words "*Currently*"
(https://developer.android.com/develop/background-work/services/fgs/timeout, verified 2026-08-30;
Android 16/API 36 unchanged), so `location` was never subject to it; both WN sites carry the retraction
with the URL, the date, the "Currently" hedge, and the note that the separate `shortService` type has
its own ~3-minute cap. U-P0-2 (goldfish HAL GPS navigating signal — CI never depends on it) stands.

### 5.1 Phase P1 — Quick wins, no architecture change (D3 part 1, D5, D8, shared hygiene)

**Goal / non-goals.** While backgrounded: on Android the UI isolate holds NO location registration (today's 1 Hz /
1 m request is never cancelled) and, with sharing OFF, no live-sync engine; on iOS an opt-out user's process
suspends with no location client (today it suspends ≈ 30 s later with the plugin stream still running) and NO
stream is ever (re)started from the background (R7 becomes structural, incl. a background LAUNCH); no maintenance
timer is armed while backgrounded on either platform — true only WITH the pause-side cancel the P1 review pass
is landing; as P1 first landed, arming was foreground-gated but nothing cancelled an already-armed timer, so one
of each survived the pause and fired while away (LANDED RECORD); the PUBLISH relay pool sends no keepalive frames on any platform and closes
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
- Guards: `scripts/ci/check_engine_client_options.sh` RESTRUCTURED into function-shaped checks returning rc (`check_publish_pool_options <manager.rs>`, `check_engine_pool_options <session.rs>`, `check_ffi_add_relay <api.rs>`; `exit 2` for missing paths; every check runs so one red run reports all violations — today's `set -euo pipefail` + `fail`=`exit 1` aborts at the first) + a `--self-test` (none today), `SELF_TEST_FIXTURES=12` pinned by equality: (3) `manager.rs` defines `fn publish_relay_options` whose body contains `.ping(false)`, `.reconnect(false)`, `.sleep_when_idle(true)`; (4) every `.add_relay(` call in `manager.rs` passes `publish_relay_options()`, read off that call's balanced argument list (joined across lines, comment-stripped view), with exactly one allowlisted exception — the negative control at `manager.rs:3019`, marked `// negative control` — REPLACING the draft's `pool\(\)\.add_relay\(` line match, which is unsatisfiable because rustfmt splits the chain; since `Client::add_relay` takes a URL and nothing else, an options argument is reachable ONLY through `RelayPool::add_relay`, so the options are an exact proxy for the pool-level call under any formatting; (5) `session.rs` contains neither the CALL `\.ping[[:space:]]*\([[:space:]]*false` nor `\.sleep_when_idle[[:space:]]*\(` (whitespace-tolerant like check 1 — the bare word appears in two kept comments, `:1536`, `:1933`, so a substring pin is red on the clean tree); (6) `api.rs` contains no `.add_relay(` except the e2e helper `fetch_by_kind` (allowlisted by a `// e2e helper` marker added by this packet); (7) `manager.rs` contains no `subscribe_to(` / `subscribe_with_id_to(`. Fixtures: clean tree (pass); a comment containing bare `sleep_when_idle` (PASS); `verify_subscriptions(true)`; pin line deleted; `ping(true)` in `publish_relay_options`; `publish_relay_options` missing; bare `client.add_relay(` in manager.rs; `.ping(false)` call in session.rs; `.sleep_when_idle(true)` call in a code line of session.rs; `subscribe_to(` in manager.rs; an unmarked `.add_relay(` in api.rs (check 6 had no failing direction otherwise); a SECOND `// negative control` marker in manager.rs (the allowlist may not grow) — 12, each asserting on the failure MESSAGE, not only the rc. `.github/workflows/repo-guards.yml` → the enforcing step gains a `--self-test` step beside it (rule 6b). (The verification draft's separate `check_relay_pool_options.sh` is subsumed — one guard owns both pools' options.) `scripts/ci/check_ios_background_publish.sh` check 5 (`:229-236`, a whole-file token check) → factored into function-shaped `check_stream_provider <provider.dart>`: slice the `locationStreamProvider` body; require `ref.watch(backgroundSharingProvider)`, `getLocationStream(backgroundSharingEnabled:`, `ref.read(appForegroundProvider)` and `clearCachedPosition()` in the foreground body (today's check-5 Rule-10 pin, `:236-237`, kept); require that the `if (!ref.read(appForegroundProvider))` block contains no `getLocationStream(` and no `ref.watch(appForegroundProvider)` OUTSIDE it (the running foreground build must never watch it); fixtures (5): passes; foreground build watches the foreground provider (fail); a start inside the paused block (fail); the `!bg` clear deleted (fail); body commented out (fail) → `SELF_TEST_FIXTURES` 19 → 24. NEW `scripts/ci/check_android_location_power.sh` created here with checks (7) and (8) of P2a's list — (7) in `map_shell.dart` `_onPaused` the token `suspendStream(` precedes `markForegroundActive(active: false)`; (8) that `suspendStream(` call sits inside a `shouldKeepLocationStreamWhilePaused(` conditional, never a raw `Platform.isIOS`/`isIOS` branch — + `--self-test` (2 pairs; P2a extends it to checks 1–6); wired in `repo-guards.yml` after "Location access gate …" (`:709-721`).
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
- Guard mutations: `check_engine_client_options.sh --self-test` 12/12; `check_ios_background_publish.sh --self-test` 24/24; `check_android_location_power.sh --self-test` (7) `suspendStream(` after the ownership write → fail; (8) a raw platform branch around `suspendStream(` → fail.
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
| P1-N3 | Guard restructure (function-shaped) + checks 3–7 + `--self-test` + `repo-guards.yml` self-test step | ∥ N1 | `--self-test` 12/12 |
| P1-N4 | Dart `RelayService.publishLocationEvent`, two call-site swaps, 37 mocks, Dart tests, b9 assertion | after N2 | `flutter test`, `flutter analyze`, `--static-only`, `check_privacy_invariants.sh` |
| P1-D | Docs + manifest invariant + B1 sampler (P1 half) + full `check_coverage.sh` before push | last | anchors intact (rule 15); floors: `lib/src/providers/|84` (measured 86.13 %), `lib/src/services/|65` (67.08 %), `rust|src/relay/manager.rs|78` (80.14 %, gains two functions + tests) absorb new lines — expect RATCHET not HOLD; `cursor.rs` gets a `--list`-derived row; re-pin from the P1 CI run only |

**Reviewer checklist.** Make the release depend on a `ref.watch`/`ref.invalidate` alone ("a simplification") — the no-frame test must go red (§2.2a). Try to make the running build `ref.watch(appForegroundProvider)` — the kept iOS session would be torn down at the resume rebuild and never restarted (R7); `check_stream_provider` must fail. Try `Stream.empty()` or a shared placeholder — the completion-surfacing test and the two-builds test must go red. Set `appForegroundProvider`'s default to a literal `true` — the paused-binding test and the lint must go red. Confirm `clearCachedPosition()` never runs on the iOS+bg or Android+bg pause path. Confirm no listener treats `AsyncLoading` as an outage (`map_page.dart:305-310` keeps loading; motion trigger stopped; access notifier suspended) and that `refresh()` from a stream error while suspended arms nothing. Make the iOS branch call `suspendStream()` (must be impossible by the keep rule + guard (8)). Pause/resume within 30 s and show any timer dead or the ownership stamp still 0 (must be re-armed / re-written). Pause with sharing OFF on Android and find an open engine socket, or a latched `releaseForHandoff()`. Find a maintenance timer armed while backgrounded on Android. Find a Timer created per fix. Find a resume within 10 min that re-runs the 30443/10050/10002 probes; confirm the immediate resume publish still runs unconditionally. D5: add `client.add_relay(` anywhere on the publish client — the guard must fail; run the negative control; confirm `reconnect(false)` cannot strand a COMMIT (`publish_event` re-drives `add_relays_and_connect` on every attempt, `:389-403`, which calls `try_connect_relay` from `Terminated`); Rule 13: `publish_location_event` unreachable from any path carrying a `PendingStateRef`, and the rule-13 gate's three predicates (auto_commit.rs `RelayManager` impl → `publish_event`; `Client` impl → `send_event_to` + `!success.is_empty()`); B8: a clock-rejected location publish still raises `RelayClockRejectionException`; C3: no `.ping(false)`/`.sleep_when_idle(` CALL leaked into `session.rs` (the comment fixture must PASS); the new fn logs no URL (captured-logger test — `check_no_key_logging.sh` does not check URLs). C1: both engine-stop paths use `_stopLiveSyncBounded()` (`mls_session_handle_release_test`, `map_shell_detached_release_test`, b1 `HANDOFF_CONFIRMED`). C6: banner/maintenance gating must not touch `_liveSyncHealTimer` re-arm (`map_shell_receive_recovery_test`). P4-1: plant a 7-day `Resubscribe` REQ — the relay-side test must go red; the three poisoning gates still green. Test reliability: the idle e2e waits on a broadcast state transition with a scaled budget (≈ 70 s wall clock, stated); every timing test is pure under `start_paused`; no relay-backed test asserts an elapsed window; no `Future.delayed` in new Dart tests; no lifecycle test awaits `.future` on a pausable state.

**Risks / rollback.** A `StateProvider` write inside a lifecycle callback during widget tear-down (`detached`) — guarded by `mounted` + `ref` liveness (change list). V-P1-1 (does the iOS engine populate `initialLifecycleState` on a background launch, and does Flutter deliver the initial `paused` to MapShell?) is U and NOT load-bearing: when the state is populated the default is `false`; when it is empty `lifecycleState == null` maps to `true` (fail-open) and the native start refusal + the `backgrounded` read (D1) are the gates that hold; no write during build is needed either way. Cold-start race the retry ladder was added for (`manager.rs:88-101`): with `try_connect_relay` awaiting `Connected` the send lands on a live socket; if field data shows first-publish drops, add ONE re-send at +5 s inside the same 10 s window — never cross-wake retries. A relay cannot sleep mid-`send_event` (activity updated on send; sleep needs ≥ 10 s idle). Rollback: one commit — `RelayOptions` back to default + `RelayManager::subscribe` restored + both Dart call sites back to `publishEvent` + guard checks/fixtures AND the `repo-guards.yml` self-test step reverted (the guard would otherwise fail, by design) + the manifest invariant deleted (`ratchet_override.items: ["INV-R-PUBLISH-POOL-NO-KEEPALIVE.deleted"]`) + `cursor.rs` bound reverted with its tests, provider back to the toggle-only body, service gate calls removed, lifecycle/banner/extras/maintenance gates removed; no persisted state.

**Acceptance.** CI: all tests above green; guards 12/12, 24/24 and the new Android guard green; `check_teardown_drain_budget.sh`, `check_privacy_invariants.sh`, `check_no_event_timestamp_cursor_advance.sh`, `check_coverage.sh` green; `e2e-ios-background-publish` P1/P2a/P2b/P3 unchanged and green (its enable happens foregrounded; check 12 `:381-400` unaffected); b7 both tiers green; B1 shows the UI request (`@+1s0ms` + `minUpdateDistance=1.0`) before `HANDOFF_CONFIRMED` and never after it. **LIVENESS gate (re-based, 2026-08-30 — §2.5; PARTIALLY MET, 2026-09-03):** b9's `PUBLISH_AFTER_IDLE_OK` is asserted from the first landing (a publish still goes out after the pool has been allowed to sleep, which is the whole risk D5 introduces) — that half is **MET** (`run-b9-network-reconnect.sh:238`, `b9_network_reconnect_test.dart:356`). **The grader half is NOT MET, and must not be read as green.** `tooling/e2e/ci/summarize-created-at-gaps.sh` is still invoked in CI only as `--self-test` (`repo-guards.yml`, step **"E2E harness self-test (relay liveness grader)"** — cited by STEP NAME from 2026-09-09, because every line number this document has used for it drifted: `:1278`, then `:1311`, then `:1330`, which by then resolved to the KeyPackage-rotation oracle's comment block, i.e. a different guard's self-test that looks like the right answer. The stale and are corrected everywhere, 2026-09-03): no lane feeds it a real capture, so the relay-side gap oracle is fixture-tested and proves nothing about any build. P1-D investigated wiring it and did not, for reasons that are properties of the lanes rather than of the instrument, recorded here so the next attempt starts from them:

- **Android, `e2e-fgs-publish` (B1) — the export is trivial, the WINDOW is not.** The capture is one `docker exec ${STRFRY_CONTAINER} ${STRFRY_BIN} scan '{"kinds":[445]}'`, the shape `run-b9-network-reconnect.sh` already uses through `strfry-lib.sh`, and the declared window is the lane's own `[b1] HANDOFF_CONFIRMED` → `[b1] HOLD_COMPLETE` span. It fails on two compounding facts. (i) `_postPauseHoldDuration` is 200 s and `--max-gap` is 228 s, so **the gap bound cannot fire inside the window at all**. (ii) The grader FAILS a series carrying fewer than two events ("a single observation bounds nothing", `summarize-created-at-gaps.sh:697-702`), while a healthy B1 run is only guaranteed ONE background publish: the FGS cycles at 0/72/144 s inside the hold and its next per-circle due interval is drawn from [72, 168] s, so any draw above 144 s legitimately puts the second publish at the 216 s cycle — outside the hold — which is a quarter of a uniform ±40 % jitter, and the drive never asserts a foreground publish before the pause either. Wiring it as-is is a ~1-in-4 flake, which the Testing Requirements forbid outright. The obvious fix — lengthen the hold — is the one §5.2 explicitly forbids ("value unchanged; no window widens"). **Correction, 2026-09-04 (P2a review round): fact (ii) died with P2a's landing and only fact (i) survives.** It was written against the 72 s POLL that P2a retires — "the FGS cycles at 0/72/144 s inside the hold" is that poll — whereas the delivery-driven cadence aims the registration at `due − lead`, so the second publish lands one CSPRNG draw (≤ `kLocationPublishMaxInterval`) after the first and the constant-derived 200 s hold covers a full draw plus slack by construction. B1 step (7) accordingly asserts ≥ 2 successful publishes in the window today, and does not flake. That removes the event-count objection; it does not remove (i) or (iii), which are the reasons the graded capture stays DEFERRED (§5.2 Acceptance). **And a third fact, found in the review pass (CI-R16, 2026-09-03), which does not bite B1 but kills the general form: a post-hoc `strfry scan` is TTL-TRUNCATED.** Application kind-445s carry `expiration = created_at + 228 s` and both hermetic relays honour NIP-40 — strfry evicts on its own cron (`run-b5-permission-revocation.sh:606-608`) and the iOS lane's in-memory relay ages events out the same way (`run-ios-bg-publish.sh:78-80`) — so a scan taken after the fact returns at most the trailing ~228 s of any window, whatever `--from`/`--until` declares. B1 survives that only by accident (its 200 s hold is shorter than the TTL); ANY window long enough to satisfy `--max-gap` is by construction long enough to have lost its own head to eviction, so "declare a long window, scan at the end" is not a design that can be made to work. A capture for a gradeable window has to be taken DURING it (repeated scans, or a live subscription) — or read off an instrument that records transmission rather than storage, which is the next bullet.
- **iOS, `e2e-ios-background-publish` — the window is right, the CAPTURE does not exist.** P2b is a 396 s backgrounded window and the drive already ASSERTS ≥ 2 scheduler-timed kind-445 events inside it (`ios_bg_publish_test.dart`, `kBackgroundPublishMarker count=`), so both of B1's problems disappear at once: the window exceeds 228 s and the two-event floor is met by the lane's own gate. What is missing is any way to read the relay: that lane runs `tooling/e2e/local-relay`, an in-memory `LocalRelay` (`src/main.rs`) with no export path of any kind. Making it gradeable takes four pieces — (a) a new `tooling/e2e/local-relay/src/bin/dump_events.rs` that REQs `{"kinds":[445]}` over `ws://127.0.0.1:$PORT` and prints one event per line (the crate already depends on the same `nostr` line, and the lane already builds it); (b) the drive emitting the P2b window's `from`/`until` epochs beside its existing handshake file, which the wrapper already sweeps out of the rotating data container (`SIGNAL_NAME`); (c) an export-and-grade step in `run-ios-bg-publish.sh` with `--publishers 1` plus its own `--self-test` fixture; (d) `jq` on the macOS runner. **This is the one that should be funded** — it is roughly a day on the repo's most flake-sensitive lane and cannot be validated locally, so it belongs in its own packet with its own lane run, not appended to a docs packet.
- **The one capture that is immune by construction is the wire-proxy JOURNAL — and it already runs (CI-R16, 2026-09-03).** `tooling/e2e/local-relay`'s proxy records what was **sent**, before any relay stores or evicts it, and says so in its own header (`local-relay/src/lib.rs:12-19`: "records what was sent, which is also why it is immune to NIP-40 eviction"). It is already wired into the Android and iOS core-flow lanes (`e2e-android.yml`, `e2e-ios.yml`, through `start-wire-proxy.sh`), so no new instrument is needed. Feeding it to the grader takes exactly one `jq` transform: the grader's normaliser accepts a bare event object or a `["EVENT", <sub-id>, {…}]` relay-to-client frame (length ≥ 3, `summarize-created-at-gaps.sh:357-360`), while a client-to-relay publish is the length-2 `["EVENT", {…}]`, which normalises to `BAD` — so the journal has to be projected (`select(.type == "frame" and .dir == "c2r") | .frame | select(.[0] == "EVENT") | .[1]`) before it is graded. **Three honest caveats, all of which have to be answered before this is worth funding, and none of which is fatal to the idea:** (a) **B1 does not run the proxy** — only the core-flow lanes do — so this rescues nothing about the FGS window; (b) those lanes run a scripted ~720 s scenario driven by explicit drive steps, not by the jittered publish cadence the grader exists to grade, so a "gap" measured there is a property of the script, and a grader wired to it would go red the first time a step is reordered rather than the first time a device goes quiet; (c) the journal's UPLOADABLE form is a field allowlist that deliberately drops event `id` and every tag VALUE, `h` included (`local-relay/src/summarize.rs:13-32`) — which are precisely the grader's series key and the identifiers it prints for the worst gap (`summarize-created-at-gaps.sh:717`) — so the grade must be computed IN-LANE against the raw journal (never uploaded, by `check_wire_proxy_test_only.sh`), and the grader's own stdout then has to be treated as a step-log exposure surface, not merely piped through.

Until (b) lands, P1's liveness evidence is b9's marker plus the host tests, and §6.6's grader row is **NOT MET**. No hardware was ever load-bearing here; this gap is CI work that has not been done.
**POWER-MEASUREMENT gate (estimate-replaced, §2.5):** ~~Battery Historian `mobile_radio` / Xcode Energy gauge over 60 min: no 55 s bars attributable to the publish pool~~ → **ESTIMATED** from model E (§6.5a): removing one always-pinging socket removes ≈ 65 keepalive wakes/h, worth ≈ **0.2–1.4 %/h** depending on how much the wakes coalesce with other traffic (§6.5a parameter `c`; 0.20 %/h at `c = 0.15`, 1.35 %/h at `c = 1`). The **CI-checkable proxy that must hold** is the *wake count*, which is where the whole radio term comes from and which is provable without a radio: the publish pool carries no PING flag and holds no standing subscription — `INV-R-PUBLISH-POOL-NO-KEEPALIVE`, `check_engine_client_options.sh` checks 3–7, and the host tests `engine_pool_keeps_ping_while_subscribed` (the engine pool must KEEP its ping — the C3 trap) and `every_fetch_primitive_leaves_no_subscription_registered`. Note for anyone tempted to count pings on the wire instead: the e2e wire proxy **forwards but does not record** WebSocket Ping/Pong (`tooling/e2e/local-relay/src/proxy.rs:20,1037`), so the journal cannot count keepalives — the static/host-test evidence above is the count.
**DEFERRED (run when hardware returns):** `dumpsys location` on a backgrounded Android showing no 1 s Haven request; with sharing OFF, `dumpsys activity services` showing no Haven sockets after Doze; an opt-out iOS user's process losing its RunningBoard "Location subscription" assertion at pause (M7 §6 toggle-OFF expectation `:836-838`). Partial substitutes that DO run today: B1's device-stamped sampler shows the UI request (`@+1s0ms` + `minUpdateDistance=1.0`) pre-handoff and never after it (the first of these on an emulator), and b7's WIU run can add "toggle off, pause, `status()` shows no session" on the simulator (the third, minus the RunningBoard assertion itself). **RESIDUAL:** the Doze socket-teardown observation has no CI substitute at all.

**Owner decisions / open questions.** None owner-level. V-P1-1 (U — `initialLifecycleState` population on an iOS background launch; not load-bearing: the native refusal + `backgrounded` read are the gates); V-P1-2 → V (`ClientOptions::default().autoconnect` does not auto-spawn a connect on `pool().add_relay` — pool-level add never autoconnects, `pool/mod.rs:257-262`; sdk autoconnect only inside `Client::add_relay`, `client/mod.rs:305-308`; `RelayOptions::default()` equals what `compose_relay_opts` yields for the publish client's default `ClientOptions`, `client/mod.rs:232-283`, so nothing is lost by bypassing `Client::add_relay`); V-P1-3 (cancelling the geolocator subscription while paused does not trip `StreamHandlerImpl.setActivity(null)`'s `stopListening()` path, `StreamHandlerImpl.java:46-53` — observe "Geolocator position updates stopped" exactly once in logcat; note the FGS engine's cancel runs `disposeListeners(true)` → `canStopLocationService(true)` on the SHARED bound service with an under-counting `listenerCount`, `GeolocatorLocationService.java:86-90,127-131` — harmless today, no `foregroundNotificationConfig`); V-P1-4 (`sharing_health_banner.dart:200` timer actually fires while backgrounded — the red test decides); V-P1-5 → V (`RelayManager::subscribe` has no caller — grep 2026-08-29); I-P1-1 (real-network `Sleeping` timing 60–70 s — hardware, not a correctness input).

**LANDED RECORD (written by P1-D, 2026-09-03 — what shipped, where it differs from the section above).**
Every bullet below was re-read in the working tree. Where one contradicts the design/change-list above,
the bullet is the truth and the text above is the draft it replaced.

**Review wave, 2026-09-03 — four independent reviews of P1 as landed.** The wave found no privacy or security
regression and no wire change, and it did not find the phases' mechanisms wrong. What it found was of one kind:
**claims that outran their evidence**, plus one cross-packet interaction no single-packet review could see. The
findings, and where each is written up:
- **A cross-packet interaction that was a live defect, not a doc problem** (below): P1-A2's "stop the engine on
  pause when sharing is OFF" plus P1-N0's phase-keyed inbox lookback produced a **7-day gift-wrap replay on
  every Android glance**, because the inbox plane inherited the GROUP plane's `Initial` phase on every engine
  start. The fix is in the tree; see the bullet below for the shape and for why each packet was individually
  correct.
- **Three reviewers independently found the debounce fix untested** (the C6 bullet below) — the single
  most-repeated finding of the wave.
- **The Rule-13 "checkable property" claim was false as written** (the P1-N4 bullet above): the gate is
  file-level over the FFI verbs and does not reach the `CircleService` indirection Dart actually uses.
- **Two overclaims corrected in place**: this phase's goal sentence said no maintenance timer is armed while
  backgrounded (arming was gated; cancelling was not — the cancel is being landed by this pass, see below), and
  §3 D5 said the fetch-primitive test pins `read_one_relays_answer`'s timeout path (it drives EOSE and CLOSED
  only, and the timeout exit is not producible against an in-process relay without a forbidden sleep).
- **One drafted test was dropped without declaring it** (below), leaving the 5 s ack window unpinned.
- **Doc drift**: four stale `repo-guards.yml` citations for the grader step (`:1311` / `:1278`, all four
  re-pointed — to `:1327` here on 2026-09-03 and, once more, to the `run:` line itself (`:1330`) on 2026-09-04,
  after the P2a review round found them landing three lines above the invocation they name), and three cells
  OUTSIDE this record still carrying numbers it had already superseded — §6.1's guards
  and floors cells and §7.4's mock row. That is the drift lesson worth keeping: this record's "the bullet is the
  truth" clause reaches the §5.1 draft above it and **nothing else**, so a correction made only here leaves
  every cross-reference table stating the superseded number. All corrected 2026-09-03.
- **Four items that are real but out of P1's scope** are carried into `docs/CI_HARDENING_BACKLOG.md` rather
  than fixed here, each with its file references and what closing it would take: three guard-quality gaps
  (CI-R7 fixtures that assert only `rc`; CI-R8 a fixture count printed but never pinned; CI-R9 an OWED coverage
  floor that only prose enforces) and the `manager.rs` debug-log/policy-comment contradiction (SEC-F6 — not a
  shipped leak, since release builds cap the level at `Warn`).

- **P1-N4 added a file the change list does not name: `haven/lib/src/services/background_deferred_send.dart`.**
  The deferred-commit ladder moved OUT of `background_location_task.dart` rather than staying beside the
  location plane, because the Rule-13 gate is **file-level**, not function-level:
  `assert_no_dart_file_publishes_a_location_and_a_commit` (`haven-core/tests/security_rule_gates.rs`) reds
  any file under `haven/lib/src` that contains `publishLocationEvent(` together with `confirmPublished(` or
  `publishFailed(`. So the change list's "`background_location_task.dart:1326` → `publishLocationEvent(...)`
  (`_resolveDeferredCommits` / `_publishDeferredProposals` keep `publishEvent`)" is not satisfiable as
  written — one file cannot hold both planes.
  **What the split does and does not prove — corrected 2026-09-03 (SEC-F3); the first version of this bullet,
  and the doc comment at the top of the new file, both said the split makes "no caller carrying a pending ref
  can reach the one-shot publish" a *checkable property*. It does not, and the claim has to be retired rather
  than softened.** Three separate things are true, and only the first two are enforcement:
  - The **Rust file-level gate** proves exactly one thing: no file under `haven/lib/src` names
    `publishLocationEvent(` alongside the FFI-level `confirmPublished(` / `publishFailed(`. As written it
    misses the indirection Dart actually resolves staged commits through — `CircleService`'s
    `confirmPendingCommit(` / `failPendingCommit(`. As P1 landed, `location_sharing_service.dart` therefore
    held BOTH planes — the one-shot `publishLocationEvent(` and the auto-commit's `confirmPendingCommit(` /
    `failPendingCommit(` — and passed the gate. Demonstrated by mutation during the review: routing that file's
    auto-commit publish to `publishLocationEvent` leaves the Rust gate GREEN. **Both halves are being fixed in
    the P1 review pass**: the gate is being extended to the `CircleService` verbs, and the auto-commit plane is
    being moved out of `location_sharing_service.dart` into its own file, so the end state is one file per
    plane on the foreground path as well as the background one. Read the tree, not these paths, for where the
    two planes live once that lands.
  - The **Dart AST inventory test** (`haven/test/lints/location_publish_ladder_sites_test.dart`) is what
    actually caught that mutation. It parses every `publishEvent` / `publishLocationEvent` invocation under
    `lib/src` and pins the inventory — file, enclosing member, method — by **exact equality**, so a new or
    moved one-shot caller fails by name whether or not it shares a file with a commit resolver.
  - The **file split** is therefore a *consequence* of the gate being file-level rather than function-level:
    it is what lets `background_deferred_send.dart` keep the Rule-13 ladder in a file that never mentions the
    one-shot publish. It is a real structural improvement and it makes the two planes reviewable at a glance,
    but it is not itself the guarantee, and nothing about a file boundary stops a Dart import from crossing it.
    The guarantee is the inventory test plus the (extended) gate.
- **The `RelayService` mock fan-out was 9 mock classes across 10 files, not "37 files".** The analyzer
  forces exactly the classes that `implements RelayService`; the estimate counted files mentioning the type.
- **Guard fixture counts as landed:** `check_engine_client_options.sh` **12** (as drafted);
  `check_ios_background_publish.sh` **24** (the §5.1 body's number — §7.2's "→ 23" is wrong and is corrected
  there); NEW `check_android_location_power.sh` **6** fixtures, i.e. three pairs rather than the drafted two —
  checks (7) and (8) got a third pair for "the release is gone entirely" / "only a comment describes the
  release", because a token check with no deletion fixture passes a file whose call was removed. It is wired at
  `repo-guards.yml:735` with its `--self-test` at `:739`, after the two "Location access gate" steps (`:716`,
  `:726`) as the change list intended — the change list's `:709-721` was the location-access-gate step range at
  drafting time, not the new guard's own. **The review pass is raising that count** (a seventh fixture for an
  unconditional release sitting AFTER a keep-rule branch, which the two-message check (8) could not previously
  distinguish), so quote `SELF_TEST_FIXTURES` from the guard rather than this bullet. **Its fixtures assert the
  return code only, never the failure MESSAGE** — unlike the sibling `check_engine_client_options.sh`, whose
  `_fixture()` takes a `want-msg` substring — and two of them trip the same message, so a check-numbering
  regression would be invisible; carried as CI-R7 in `docs/CI_HARDENING_BACKLOG.md` rather than fixed here.
- **P1-A2 closed a PRE-EXISTING wedge defect, and it is written up in the incident doc rather than here.**
  A pause→resume inside the 30 s resume debounce returned early ahead of `markForegroundActive(true)`, the
  `_lastPublishTime` re-seed and `_startTimers()`, so a glance-and-return left the foreground publish
  scheduler, the foreground heartbeat and the motion trigger stopped, the ownership stamp reading
  "backgrounded", the service locked out of the MLS database by the already-ended handoff — and the FGS
  notification still saying "sending and receiving". It is a cause of the field incident's own shape, so it
  is recorded as a C6 lesser cause in `docs/BACKGROUND_SHARING_FAILURE_ANALYSIS.md`, with the fix and the
  source-order tests that hold it. Note for the reviewer: the drafted *behaviour* test (a recorded call log
  over pause→resume→pause→resume inside 30 s asserting every timer field non-null and
  `_lastPublishTime == bgLastPublish`) did NOT land; the promise is held by the source-order family in
  `map_shell_location_access_lifecycle_test.dart` alone (`'the reclaim block and _startTimers() precede the
  debounce'`, `'the debounced early return carries no repair of its own'`). That is weaker than drafted —
  it pins the ORDER of four anchors, not the resulting state — and is left as an open item rather than
  silently re-scoped. **Three of the four independent reviewers in the 2026-09-03 wave flagged this same gap
  without seeing each other's reports** — the clearest signal in the whole wave that a source-order family
  reads, to a reader, as coverage it does not have. Closing it (the recorded call log over
  pause→resume→pause→resume inside 30 s, asserting every timer field non-null and
  `_lastPublishTime == bgLastPublish`) is the highest-value single item left in P1 and is **being fixed in the
  P1 review pass**.
- **`live_sync_cursor_replay_e2e.rs` was NOT a wait-budget problem, and the budget scale must not be
  credited with fixing it.** Verified root cause: the test sampled its cold-seed cursor baseline AFTER
  `engine1.start()` had already opened the REQ, so on an in-process relay the `EOSE` regularly anchored the
  cursor BEFORE the sample was taken. The sampled "cold seed" was then the advance itself, and the test went
  on to wait for a value strictly ABOVE it — a SECOND advance that a spent generation never issues
  (`anchor::CircleAnchor::eose_consumed`: one generation advances at most once, and nothing in that test
  re-issues the REQ). The wait therefore burned its whole budget and failed **whatever the budget was** —
  held open at 120 s under saturating load, the advance still never came — while passing on an idle machine
  where the sample won the race. The fix is to wait for a value knowable BEFORE the session exists (the
  REQ's local open time) instead of one sampled after it: `wait_cursor_above(floor: Option<i64>)` became
  `wait_cursor_at_least(target_ms: i64)`, with an explicit `read_sync_cursor == None` precondition assert so
  the cold state is proven rather than assumed. `haven-core/tests/inbox_cursor_poisoning_e2e.rs` was immune
  to the same shape throughout for one reason: it always passes a COMPUTED floor, never a sampled one.
  `HAVEN_TEST_WAIT_SCALE` (4 in `coverage.yml` and `check_coverage.sh`) exists only for the ordinary
  slowness of an instrumented build, and the file's three fixed sleeps are deliberately NOT scaled — two are
  absence windows whose expiry is their success path, and the third only separates two candidate timestamps
  by whole seconds.
- **Floors: ONE ratchet, not three, and it is not where the packet row predicted.** The P1-D row above
  expects `lib/src/providers/|84`, `lib/src/services/|65` and `rust|src/relay/manager.rs|78` to *absorb*
  P1's new lines. Measured on the pinned rustc 1.97.1 and a local Flutter 3.41.0: the two Flutter
  aggregates absorbed them exactly as predicted and did not move past their margins (providers 85.76 %
  against 84, services 67.26 % against 65; aggregate 73.62 % against the 50 % gate, all 24 pinned Flutter
  paths at or above floor, no ratchet, no HOLD). `manager.rs` did NOT absorb them — `publish_relay_options`,
  `send_to_one` and `publish_location_event` arrived with their own tests, so the file went 80.14 % → 90.52 %
  and RATCHETED: floor 78 → 88, re-pinned with `check_coverage_floors.sh --repin rust`, never by hand.
  NEW row `rust|src/relay/cursor.rs|100` (measured 100.00 %, 174/174) added as the packet's `--list`-derived
  row, pinned exactly at 100 for the reason `tags.rs` is: both its promises — no cursor advance on an event's
  own `created_at`, and the phase-dependent inbox `since` — are all-or-nothing.
  **One floor row is OWED and could not be written here:** `lib/src/services/background_deferred_send.dart`
  (N4's new file, and the Rule-13 commit plane) warrants a row, but a Flutter floor is a ratio whose
  denominator is the SDK's instrumented-line count and the local SDK is 3.41.0 against the pinned 3.44.8 —
  the gate itself refuses a re-pin from that measurement, and this run shows why the direction is not
  guessable (3.41 read `background_location_task.dart` 0.23 points HIGHER on 19 FEWER instrumented lines,
  and `nostr_relay_service.dart` 0.81 points LOWER on 8 MORE). It measures 81.82 % (18/22) locally, which
  would pin at 79; add it with `--repin flutter <lcov>` from the next CI coverage artifact. The pending row
  is recorded in `scripts/ci/coverage_floors.txt` beside its neighbours so it cannot be forgotten.
- **A cross-packet interaction made every Android glance a 7-day gift-wrap replay, and neither packet was
  wrong on its own.** P1-A2 stops the live-sync engine at pause when background sharing is OFF; P1-N0 bounds
  the inbox lookback but only in `SubscribePhase::Resubscribe` (`INBOX_RESUBSCRIBE_LOOKBACK_SECS` = 2 d + 1 h),
  leaving `Initial` at 7 days for a device that cannot know how long it was gone. The seam between them is
  that `LiveSyncCore::start` passed ONE phase to both planes, so a freshly started engine issued its inbox REQ
  as `Initial` — and after P1-A2 the engine is freshly started on **every glance**, several times an hour. The
  result was a 7-day gift-wrap window asked of every inbox relay, per glance: the exact metadata burst the
  bound existed to remove, arrived at by landing two individually correct packets in one phase. The fix keys
  the two planes separately (`register_and_subscribe` now takes `phase` and `inbox_phase`): the GROUP buffer
  still asks "how long was this socket down", which only the caller knows, while the INBOX phase asks "do we
  know when we last heard an EOSE" — which the PERSISTED cursor answers across process lifetimes, so a fresh
  core over a known inbox cursor is a group `Initial` and an inbox `Resubscribe`. The cursor read is
  deliberately taken BEFORE the cold-start seed writes one; taken after, a genuine cold start would read as a
  resubscribe and silently under-fetch. Lesson for later phases, which land packets in parallel by design:
  a per-packet review cannot see this class, because each packet is correct in isolation and the defect lives
  in the composition.
- **The goal's "no maintenance timer is armed while backgrounded" was FALSE as landed.** What P1 gated is
  ARMING: `_armKeyPackage` / `_armRelayList` / `_armHealth` each return early when the app is not foregrounded,
  and `rearmForForeground()` (called from `MapShell._onResumed`) is the only thing that brings them back. What
  P1 did NOT add is a CANCEL at pause — so a timer already armed when the app went away survived, fired once
  while backgrounded, opened the relay sockets the gate exists to prevent, and only then re-armed into the gate
  and stopped. One `KeyPackage` probe, one relay-list probe and one health tick per backgrounding, worst case:
  small in energy terms, but it is a *presence* signal to a relay from a device the plan says is silent, which
  is the part that matters. The pause-side cancel (`suspendForBackground()`, called from `MapShell._onPaused`
  beside `rearmForForeground()` on resume) is **being landed by the P1 review pass**, after which the goal
  sentence is true as originally written. The lesson is the one the wave kept finding: a gate on the ARMING
  path is not a gate on the STATE, and a goal written in terms of the state has to be proved against the
  state — here, a test that pauses with a timer already pending and asserts it does not fire.
- **A drafted test was dropped without declaring it, which is exactly the failure the Testing Requirements
  name.** §5.1's "Tests FIRST" lists two pure `start_paused` timing tests.
  `location_ladder_worst_case_equals_one_publish_attempt` landed;
  `the_per_relay_window_returns_at_the_bound_when_nothing_answers` did not, and nothing recorded the drop. The
  consequence is narrow but real: the surviving test drives `publish_with_retry`'s arithmetic over an attempt
  future that *simulates* the 5 s wait, so `LOCATION_ACK_WINDOW` is pinned as an INPUT to the ladder and never
  as the bound `send_to_one` actually enforces; the relay-backed
  `publish_location_event_folds_a_stalled_relay_after_its_own_window` asserts only `elapsed <
  CONNECTION_TIMEOUT + LOCATION_ACK_WINDOW + wait_budget(10)`, a bound, deliberately not the window. So the 5 s
  per-relay ack window — the constant that bounds how long one publish keeps the radio awake, and therefore the
  whole D5 energy claim — went unpinned from landing until the review found it. Restoring the test is **being
  fixed in the P1 review pass**.
- **The LIVENESS gate's grader step is still NOT WIRED — see the Acceptance block above, which says so.**

### 5.2 Phase P2a — Android FGS: delivery-driven cadence, one-shot demoted, scoped publish lock (D3 part 2 + D4 P2a); Phase P2b — permanent-lock removal (gated)

**Goal / non-goals (P2a).** Backgrounded with sharing ON (after P1 released the UI stream): GNSS is duty-cycled by
the platform itself — the FGS isolate owns ONE `LocationManager` registration whose interval is the time to the
next CSPRNG due minus a 10 s lead (floored at 31 s), so the receiver runs ≈ hot-TTFF per publish instead of 100 %
(research §1.5/§1.7: ≈ 5 mA average vs 60–85 mA); the per-tick 30 s HIGH_ACCURACY one-shot no longer runs in
steady state; the scoped `Haven:publish` lock (fix→encrypt→publish→ack→fetch, ≤ 30 s past the last acquire) is in
place so P2b is a pure removal; the FGS shuts its publish pool at the end of every cycle (the presence copy's
Android truth, D6 (vi)). The plugin's permanent `PARTIAL_WAKE_LOCK` STAYS in P2a (D4): it is the wake source of
the indoor/no-fix fallback and of the `Armed`-without-delivery recovery, so the AP does not suspend between
publishes yet — the P2a saving is the GNSS receiver, not the AP. Nothing on the wire changes.
**P2a is SELF-CONTAINED and shippable with P2b parked (confirmed 2026-08-30, §2.5).** Re-read to be sure rather than
assumed: P2a's own design *keeps* the plugin's permanent wake lock, and keeps it deliberately — guard
`check_android_location_power.sh` check (1) pins `allowWakeLock` **ABSENT** (i.e. the plugin default `true` is in
force), and §6.2's "toggle OFF ⇒ no keep-alive" row records "P2a: plugin lock kept (deliberate; guard (1) pins
ABSENT)". So P2a depends on P2b for nothing: it does not half-remove the lock, does not introduce a native
registration, and does not need a new wake source, because the wake source it relies on is the one still there.
P2b is a *pure removal* layered on top — which is exactly what "so P2b is a pure removal" in the goal above already
promised, and what makes parking it a no-op for P2a's correctness. The only thing the park defers is the **AP-suspend
saving** (magnitude UNKNOWN, §6.5a); the GNSS duty-cycle saving, the demoted one-shot, the scoped `Haven:publish`
lock and the per-cycle publish-pool shutdown all land in P2a and all carry their own CI oracles. Non-goals: the
foreground stream (1 m / 1 s), iOS (P3), relay pools beyond the per-cycle shutdown (D5/D6), motion awareness in
the FGS (none today, none after), Play-Services-free flavour, batching, the native registration (P2b).
**P2b — PARKED 2026-08-30 (§2.5). Do not implement; do not cut its packets.** Its design is unchanged and stays
specified by D4 and the rows below marked (P2b): `allowWakeLock: !isIgnoringBatteryOptimizations` (the plugin lock
stays for the non-exempt cohort — no ordinary alarm fires in Doze without the exemption) + the native
`PendingIntent`/`LocationListener` registration acquiring `Haven:publish` inside the system's delivery hold + a wake
source for the no-fix watchdog (the inexact exempt alarm by default) + `INV-L-ANDROID-NO-PERMANENT-WAKE-LOCK`.
**Why parked, precisely.** P2b's merge gates were "the emulator no-fix oracle (Doze policy) **AND** the forced-idle
hardware liveness row". The second is a **LIVENESS gate**, and §2.5 says a liveness gate may not be replaced by an
estimate. It is also not re-basable: what P2b removes is the object that keeps the application processor awake, so
the question it must answer — *does a location delivery still wake Dart once the AP is genuinely suspended?* — is
about a state the emulator never enters (B1's lane header says so: "AP suspension is hardware-only"). That sentence is
about P2b and is correct about P2b; it is **not** a ground for dropping B1 step (8), which was only ever scoped to the
Doze-POLICY half and which the emulator can show (correction, 2026-09-04 — see §5.2's step (8) status).
The emulator oracle proves the Doze **policy** half and nothing about the **suspend** half, so shipping P2b now would
be shipping the removal of a wake source with no evidence that the replacement wake source fires. That is the exact
shape of the 2026-08-20 field failure. **Un-park condition:** one Android handset (no iPhone, no macOS needed) plus
the `POWER_MEASUREMENT.md` §5 Android run under `dumpsys deviceidle force-idle`, screen off, cellular, in BOTH
exemption states. **And the bound that run is graded against is 228 s, not 248 s — owner decision 2026-09-09 (§4
OD-P2-4, L-125): D3 (iii)'s accepted 248 s cold residual on API 23–30 does NOT extend to this gate, because forced
idle is the scenario the gate exists to catch. A handset that misses 228 s there has produced a finding to FILE, and
P2b stays parked on that finding rather than merging against a relaxed number.** OD-P2-2, OD-P2-3 and now OD-P2-4
travel with the park (§4).
**What parking costs, stated:** the **AP-suspend saving** — the one term of the Android drain that P2a deliberately
does not touch. Its magnitude is **UNKNOWN**, not merely estimated: no figure in §2 or the source reports gives an
awake-but-idle application-processor draw, so model E (§6.5a) carries this term as UNKNOWN rather than inventing one.
P2a's saving is the GNSS receiver and the radio wakes; P2b's would have been the AP. Anyone reading "Android is
fixed" after P2a is reading it wrong, and §6.5a's table says so per term.

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
  (the per-cycle pool close — reconnects via `try_connect_relay` next cycle, +0.5 J ESTIMATED, §2.3 wake model); `writeLastPublishTime`; prune;
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
  sampler unchanged — the sample is drawn earlier, not differently); TTL web — constants and tests untouched, but the REALIZED bound is
  `max(J, min(J − 10 + σ, 168) + TTFF)` on S+ — ρ falls out, worst cold 198 s — and
  `max(J, 2·TTFF + min(J − 10 + σ, 168) + ρ)` on API 23–30, worst cold **248 s**, past the 228 s retention
  (trigger, lever analysis and decision status in D3 (iii); risk row §6.3 C6). The "≤ 168 s + TTFF − 10 s" this
  bullet carried until 2026-09-04 was the σ = 0 case, and the per-API forms that briefly replaced it dropped the
  interval ceiling; both understated the legacy regime); motion-trigger leak (no motion awareness added); presence-only logging (ages, counts, trigger
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
- NEW `test/services/background_fix_request_test.dart`: `targets the earliest due minus the fix lead`; `never requests an interval at or below MIN_REQUEST_DELAY_MS (30 s) — the floor is kMinFixRequestInterval`; `the initial registration after a publish asks for at least kLocationPublishMinInterval − kBackgroundFixLeadTime` (62 s); `a second circle due between 31 s and 71 s after a publish gets its own fix at its due − lead` (the M-9 window, swept over D_B ∈ (P_A + 30, P_A + 82)); `the fix horizon exceeds the lead` (`kBackgroundFixHorizon > kBackgroundFixLeadTime`, and is independent of `kPublishStaggerMaxSpread` — lint that the task reads the horizon constant); `worst-case inter-publish gap never exceeds kLocationPublishMaxInterval for a hot fix` (EXHAUSTIVE and cheap — a proof, not a sample: API model {S+ delayed register anchored at `t_f`; ≤ 30 registration-anchored with two TTFFs} × J ∈ [72,168] s × TTFF ∈ [0,10] s × cycle latency δ ∈ [0,30] s × the M-9 sibling window — fails if the registration moves to the end of the cycle or the floor rises to 72 s); `a cold TTFF outruns the lead, and on API ≤ 30 it outruns the retention as well — the residual, exactly` (as landed: the breach SET pinned by equality — `legacy && J + ρ + σ ≥ 178` — plus the worst gaps 198 s / 248 s and the 20 s overrun by value; the draft's `cold TTFF stays inside the retention on S+ (≤ 188 s) and is bounded on ≤ 30 (≤ 218 s)` was the σ = 0 case and asserted a bound that does not hold, W-3 2026-09-04); `registrationIsAligned tolerates kRegistrationSlack and no more`.
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
- **Lane `e2e-fgs-publish` (B1)** — `run-b1-fgs-publish.sh` + `b1_fgs_live_foreground_test.dart`: the hold becomes constant-derived, `_postPauseHoldDuration = kLocationPublishMaxInterval + const Duration(seconds: 32)` (the `ios_bg_publish_test.dart:352` idiom; value 200 s unchanged, so no window widens; reason "≥ 1 delivery-driven publish inside one max interval + slack" — the old "2 ticks (144 s) plus slack" derivation is dead) and the 10 s `geo fix` drip stays (`:628-631`; the drip only keeps goldfish "fixed" — the platform's fastest-interval gate spaces deliveries, so the drip must not be what makes the lane pass). NEW oracle steps, parsed never grepped, every sample ONE `adb shell 'date "+%m-%d %H:%M:%S.000"; dumpsys location; dumpsys power'` invocation (DEVICE clock — the B1 window is defined on logcat device timestamps via `window_between_markers`, `:787`; a host-clock sampler is the B8 clock-band trap), period 5 s, started BEFORE `flutter drive` (a 10 s cadence started later can miss the foreground 1 s request entirely and fail the anti-vacuity read on a healthy run): (5) extract Haven's registrations (identity = package/uid; `Request[<provider> @<duration> HIGH_ACCURACY…]` per `LocationProviderManager.toString` `:753-775`, the interval PARSED from `TimeUtils.formatDuration` grammar `+1m40s0ms`; the FGS request prints no `minUpdateInterval`/`minUpdateDistance` suffix, the UI request prints `minUpdateDistance=1.0`); ASSERT after `HANDOFF_CONFIRMED`: no sample shows a Haven request with an interval < 62 s (= `kLocationPublishMinInterval − kBackgroundFixLeadTime`, the two literals named beside the formula — the single-circle lane's registration after a publish is `I = J − 10 − δ ∈ [62, 158] s`, and a retry registration after a FAILED publish is `kBackgroundRepeatInterval − lead` = 62 s too; the wrapper comment says that a failed publish on the hermetic relay inside the window is itself a finding, so nobody widens the bound) once the first `Published to ≥1` is logged, and no sample ever shows two Haven requests; ANTI-VACUITY: at least one pre-`HANDOFF_CONFIRMED` sample shows the `@+1s0ms` request; (6) from the same sample: `ForegroundService:WakeLock` present throughout in P2a (its absence is the P2b oracle); `Haven:publish`, when present, has `ACQ=` age ≤ `kPublishWakeLockTimeout` (30 s) — never a consecutive-sample count (a legitimate cycle re-acquires across the stagger + publish + fetch and a 30 s hold spans 4 samples at 10 s: boundary-flaky); (7) publish count in the window ≥ 2 (first ≈ immediately after the paused signal, second ≤ 168 s later) and consecutive `[BackgroundTask] cycle trigger=delivery` markers that led to a publish ≥ 55 s apart — `floor(0.9 × (kLocationPublishMinInterval − kBackgroundFixLeadTime))` = 55 s, the two literals named beside the formula in the wrapper (a healthy boundary run lands at 55.8 s; "≥ 56 s" would red it), pinned by a shell fixture pair at 55 (pass) / 54 (fail); measured on DELIVERY markers so a slow ack cannot shrink the gap; print `dumpsys batterystats --checkin | grep gps` as evidence only. **(8) No-fix chain oracle (BR-2; Doze-policy half only — AP suspension is hardware-only, said in the lane header):** after the first delivery-driven publish, stop the `geo fix` drip, `adb shell dumpsys deviceidle force-idle`, and assert a last-known publish within `kStreamPositionMaxAge + kOneShotLocationTimeout + slack` with a `[BackgroundTask] cycle trigger=watchdog` marker; in P2b this row is the merge gate for the wake source. **LANDED 2026-09-04 (B1 lane fix pass) — as a SECOND forced-idle phase after `HOLD_COMPLETE`, not as a widened hold, so steps 5–7 still read exactly the span they always did and no P2a bound moved.** The drive prints `[b1] IDLE_PHASE_BEGIN`, holds `_forcedIdleHoldDuration` = `kStreamPositionMaxAge + kBackgroundRepeatInterval + kFirstDeliveryWait + kOneShotLocationTimeout + 60 s` = **332 s** (each term is one link of the chain: the cached stream fix must age out, the watchdog can only start a cycle on a tick, the cold cache waits for an answer that will not come, the one-shot cannot succeed before `getLastKnownPosition()` answers), then `[b1] IDLE_PHASE_END`. A shell watcher kills the `geo fix` drip and runs `battery unplug` / `dumpsys deviceidle enable deep` / `force-idle`, stamping logcat with an authoritative `dumpsys deviceidle get deep` read-back — because `force-idle` exits 0 on a device that refuses to doze, so its exit code proves nothing. The oracle requires **BOTH** `state=IDLE` and a `trigger=watchdog` publish within **302 s** (the same sum at a 30 s margin instead of the drive's 60, so the publish it looks for always falls inside the hold). Six fixtures pin it: at-bound pass, silence fail, `state=ACTIVE` fail, no-stamp fail, bound+1 fail, delivery-driven-publish fail. Lane bounds moved with it: drive target 10→14 m, `flutter drive` 18→20 m, deadline 25→28 m, step 35→38 m. **The reviewer's objection that "AP suspension is unassertable" was a category error, and the landing settles it:** this step is scoped to the Doze-POLICY half in its own first clause above, and Doze policy is exactly what `force-idle` puts an emulator into. The suspend half was never step (8)'s to prove — it is P2b's, and it is why P2b is PARKED. V-P2-1 closed by FIXTURE, not by a CI run: the `dumpsys location` and `dumpsys power` grammars (§2.2) are shell self-test fixtures in the SAME commit as the oracle (sample with a 1 s request only pre-window → pass; 1 s request inside the window → fail; two Haven requests in one sample → fail; `Haven:publish` with `ACQ=-31s000ms` → fail; no pre-pause 1 s request → fail — anti-vacuity); the first CI run confirms the grammar against the API-34 image. `check_e2e_step_timeout_ordering.sh`. Lanes B3/B5/B6/B9, `e2e-background-catchup`, `e2e_combined`: unaffected — B5's stream-silence discriminator (`b5_permission_revocation_test.dart:365-377`) runs FOREGROUNDED with the unchanged 1 m / 1 s stream (grep for `AppLifecycleState` = 0 hits; `run-b5-permission-revocation.sh:191,1947` mention `distanceFilter: 1` for that FOREGROUND stream — still true after every phase); B6 is foreground (`publishNow`, `:394-397`); B9 fakes location. Recorded so nobody "fixes" them.

**Implementer work packets** (sequential unless marked ∥).
| # | Packet | Sequencing | Done when |
|---|---|---|---|
| P2a-1 | constants (incl. `kMinFixRequestInterval`, `kBackgroundFixHorizon`) + `background_fix_request.dart` + `PerCircleDueTracker.earliestDue` + the exhaustive property test | ∥ P2a-2 | `flutter test test/services/background_fix_request_test.dart test/services/per_circle_due_tracker_test.dart test/constants/location_test.dart`; `flutter analyze` |
| P2a-2 | `GeolocatorLocationService` profile + `hasFreshStreamFix` + tests; `check_ios_background_publish.sh` header re-word | ∥ P2a-1 | `flutter test test/services/geolocator_location_service_test.dart test/providers/location_provider_test.dart`; `check_ios_background_publish.sh` + `--self-test` (24); `check_location_access_gate.sh` |
| P2a-3 | Kotlin `PublishWakeLock.kt` (no release in listeners) + `HavenApplication` registration + manifest `WAKE_LOCK` + Dart `publish_wake_lock.dart` + the wake-lock policy lint test (P2a form) + guard checks 1–3 + m7 check-10 factoring with the Kotlin patterns and fixtures | after P2a-1/2 | `flutter build apk --debug` compiles; `flutter test test/services/publish_wake_lock_test.dart test/lints/fgs_plugin_wake_lock_policy_test.dart`; guard + `--self-test`; `check_m7_native_wake_guards.sh` (+ `--self-test`, log-fixture count pinned) with the new file listed |
| P2a-4 | `background_location_task.dart` delivery-driven cycle (registration even with nothing due; `_deliveryPending`; per-cycle pool shutdown; lock through the drain) + watchdog + signals + fakes/harness (`deliverFix`, `oneShotRequests`) + all cycle tests + disclosure-gate order test + guard checks 4–6 + manifest additions | after P2a-3 | `flutter test test/services/`; guard self-tests; `flutter analyze`; `check_privacy_invariants.sh`; `--static-only` |
| P2a-5 | `map_shell.dart` signals (`if (handedOff)` paused signal; resumed signal; P1 owns the surrounding reorder) + the S-13 test + docs | after P2a-4 | anchors intact (rule 15); `flutter analyze` |
| P2a-6 | B1 lane oracle steps 5–8 + the grammar shell fixtures (same commit) + constant-derived hold — **steps 5–8 all landed; the wrapper prints `[8/8]` (step (8) as a second forced-idle phase, 2026-09-04)** | after P2a-4 | `bash tooling/e2e/ci/run-b1-fgs-publish.sh --self-test` (**54**, pinned by EQUALITY); `check_e2e_step_timeout_ordering.sh`; one green `e2e-fgs-publish` run; full `check_coverage.sh` before push — floors `background_location_task.dart|80` (measured 82.95 %, 287/346; the drafts' "27" is stale — the staged file is authoritative), `background_location_manager.dart|52`, `geolocator_location_service.dart|85`; NEW files (`background_fix_request.dart`, `publish_wake_lock.dart`) get `--list`-derived rows; a rewrite that lands without tests goes HOLD → tests, never a number; moving the cycle into a new file changes the denominator → re-pin BOTH rows from the P2a CI run with `--repin` only |
| P2b-1 **[PARKED 2026-08-30 — do not start; §5.2]** | ~~(after P2a's hardware row + OD-P2-2/OD-P2-3)~~ (after an Android handset exists — §6.7 follow-up 1) native `LocationListener`/`PendingIntent` registration in `PublishWakeLock.kt` (acquire inside the delivery hold; provider named), FGS registration routed to it ONLY via `_ensureRegistration`'s channel call, native `cancelRegistration` at both disable sites, the fail-closed receiver, no-fix watchdog wake source (inexact alarm for the exempt cohort), `allowWakeLock: !isIgnoringBatteryOptimizations` re-evaluated at enable/resume, guard check (1) flipped to the exemption predicate + native pins (no `requestLocationUpdates(` outside the channel handler), `INV-L-ANDROID-NO-PERMANENT-WAKE-LOCK`, lint test flipped, B1 step (6) inverted for the exempt run (`ForegroundService:WakeLock` NEVER present) + the toggle-OFF-with-force-killed-service oracle | after P2a | all of the above green; `a toggle-off with a dead service still cancels the native registration` green; the BR-2 no-fix oracle green under forced idle; the forced-idle HARDWARE liveness row (relay-side gaps ≤ 228 s, screen-off, cellular) recorded in BOTH exemption states BEFORE merge — **this last criterion is why the packet is PARKED: it is a LIVENESS gate (§2.5) and no estimate may stand in for it** |

**Reviewer checklist.** Security/privacy: no coordinate in any new `debugPrint`/Kotlin log; `PublishWakeLock.kt` logs nothing but method names and the factored check 10 catches a planted `Log.e(TAG, "x", e)`; the registration cannot precede the disclosure gate or the foreground gate on ANY path (watchdog, delivery, signal) — try to reach `_ensureRegistration` from `onStart`/`onReceiveData`/`onRepeatEvent` directly (guard (5)'s count must fail); the paused signal must not bypass `prefs.reload()` (a paused signal while `kForegroundActiveAtMsKey` is still fresh must NOT register) and must not be sent on a declined handoff; Rule 4 keys hex only; no new `CircleManagerFfi.newInstance` site. Liveness vs FA: inject a fake that re-delivers the last fix on every registration (dedupe + alignment must hold); a stream that never delivers (V-P2-2) — the 168 s watchdog must recover (it keeps its wake source in P2a — remove the plugin lock and show the indoor row still passes: must be impossible in P2a); a stream error mid-Armed → re-registration, not permanent `Idle`; a delivery mid-cycle → follow-up cycle, never lost; from `Idle` with nothing due → registered, no one-shot; `onDestroy` ordering (cancel → bounded drain UNDER the lock → unbounded commit-critical drain → release → dispose) unchanged in shape; the 144 s stamp staleness still lets the FGS take over after a UI kill; `_shutdownSignal` still aborts the wait paths; reclaim ordering (`session_reclaim_gate_test`, `background_location_task_reclaim_orchestration_test`, `session_guard_contention_test`). Cadence: the exhaustive property test proves no gap > 168 s + max(0, TTFF − 10) on S+ (worst cold 198 s) and states API ≤ 30's cold residual as an EQUALITY rather than a bound — breach set `J + ρ + σ ≥ 178 s`, worst 248 s, ACCEPTED (W-3; D3 (iii)) — that no request is ever ≤ 30 s, and that a sibling due 31–71 s after a publish is NOT starved (the 72 s floor must fail it). Wake lock: every `acquire` timeout ≤ 30 s natively coerced; `release` on every exit incl. `_unlessShuttingDown` null returns; nothing holds the lock across a `_sleepUnlessShuttingDown` > 30 s without re-acquiring; the Kotlin listeners must not release or detach (guard (2) fixture). Test reliability: no `Future.delayed`; the harness injects `now`; the B1 oracle parses device-stamped samples, its anti-vacuity read is asserted, the lock bound is an age, and the grammar fixtures land in the same commit. Copy: nothing user-visible changed; the motion-trigger bound (`INV-L-MOTION-TRIGGER-BOUNDED`) still holds (no displacement logic anywhere in the FGS).

**Risks / rollback.** GMS `fused` (API 31+ Play devices) may ignore the interval for HIGH_ACCURACY and keep GNSS on (I-P2-2) — ~~detected by the hardware gps time~~ → **undetectable for the duration (§2.5): the emulator is not GMS `fused`, so this risk ships unmeasured under P2a**; there is NO geolocator `gps` fallback (§2.2) — the remedy is P2b's native registration naming the provider. Goldfish `Request[…]` grammar differs → the fixture fails loudly on the first run and is corrected once. Cold TTFF after an indoor stretch: 198 s single-fault on S+, and on API 23–30 **248 s — past the 228 s retention, ACCEPTED (W-3, D3 (iii))**; stacked with a P2b suspend gap it exceeds 228 s — §6.3 C6. OEMs that kill services without wake locks more readily — moot in P2a (plugin lock kept); in P2b the FGS is still type `location`, exemption still requested. Rollback: ONE revert of the P2a commit series restores the tick-driven cycle and the one-shot; the guard checks 1–6, the m7 check-10 factoring + list entry (the deleted Kotlin file must leave the list in the same revert — `code_view` of a missing file is red), the lane steps and fixtures, the Kotlin file, the `INV-L-BACKGROUND-DISCLOSURE-GATE` edit (its added test name + guard — rule 3/6 otherwise red) and `INV-L-ANDROID-BACKGROUND-SINGLE-GNSS-REQUEST` (`.deleted`) revert with it; P2b's revert additionally restores `allowWakeLock` default, guard (1)'s P2a form, the lint test's P2a form and deletes `INV-L-ANDROID-NO-PERMANENT-WAKE-LOCK` (`.deleted`); no wire, DB, prefs-key or copy change to migrate.

**Acceptance.** CI: all tests above green; `check_android_location_power.sh` + `--self-test` green; `e2e-fgs-publish` green with the registration oracle (one Haven request, interval ≥ 62 s = `kLocationPublishMinInterval − kBackgroundFixLeadTime` after the first publish — the single-circle lane's registration is `I = J − 10 − δ ∈ [62, 158] s`, so a 72 s bound would red a correct build on ≈ 10 % of cycles, whenever J < 82 s; the `@+1s0ms` request observed pre-handoff), the `dumpsys power` oracle (`Haven:publish` `ACQ=` age ≤ 30 s at every sample), in a 200 s hold, ≥ 2 successful publishes with at least one delivery-driven, each delivery-driven publish ≥ 55 s after the `registration armed` line that produced it (step (7), landed — NOT a pair-spacing claim; see the step description), and the no-fix chain oracle under forced idle (step (8), LANDED 2026-09-04: `state=IDLE` read back from `dumpsys deviceidle get deep` AND a `trigger=watchdog` publish within 302 s, in its own phase after `HOLD_COMPLETE`); `run-b1-fgs-publish.sh --self-test` 54/54; `check_privacy_invariants.sh` green with additions only; coverage gate green.
**LIVENESS gate (re-based 2026-08-30 — §2.5; RE-BASED AGAIN 2026-09-04, because the 2026-08-30 wording named a gate that cannot exist).** ~~60 min walking on hardware → every relay-observed `created_at` gap ≤ 228 s; indoors 30 min → publishes continue~~ ~~→ the emulator lane capture graded by `tooling/e2e/ci/summarize-created-at-gaps.sh` with `--publishers` and a DECLARED `--from`/`--until` window, exit 0, max gap ≤ 228 s~~ → **the grader-graded capture is DEFERRED, and is NOT a P2a gate.** The struck wording contradicted §5.1's own investigation of the very same idea, and that investigation is the truth: B1's hold is 200 s against a 228 s `--max-gap`, so the bound **cannot fire inside the window at all**; any window long enough for it to fire is by construction longer than the kind-445 NIP-40 expiration it grades, so a post-hoc `strfry scan` has already lost its own head to eviction (CI-R16, §5.1); and the one capture immune to that by construction — the wire-proxy journal — is not run by B1. The grader is invoked nowhere in CI but its own `--self-test` (`repo-guards.yml`, step "E2E harness self-test (relay liveness grader)"), so it grades no build; §6.6's LIVENESS row already reads **NOT MET**, and that row governs. No P2a summary, commit message or acceptance note may claim a graded gap for this phase. **What un-deferring it takes, unchanged from §6.7 follow-up 3:** run `start-wire-proxy.sh` in B1 (only the core-flow lanes run it today); grade IN-LANE against the RAW journal, because the uploadable summary drops event `id` and every tag value — precisely the grader's series key and the identifiers it prints — which makes the grader's own stdout a step-log exposure surface to handle, not merely a pipe; and give the grade a window of at least 2 × 228 s, which has to be a NEW phase appended to B1, never a widened hold (this section forbids widening, and for the reason it gives).
**The successor gate — it exists, it is wired, and it can fail: B1 step (7).** Two successful publishes inside the `HANDOFF_CONFIRMED → HOLD_COMPLETE` window bound the realized inter-publish gap between them at ≤ the hold, i.e. 200 s < 228 s: the same promise `--max-gap 228` was there to make, expressed as a COUNT over a bounded window instead of a GAP over an unbounded one, and the ≥ 55 s floor half reds a build woken by anything other than its own registered interval. That is a real liveness result for the delivery-driven cadence — a running Haven build on a real Android image, publishing over a real socket to a real relay, read off device-stamped logcat markers — and it is the reason P2a is not shipping on an estimate. What it does not do is grade a series longer than one hold; that is exactly the deferred half above. **RESIDUAL, stated:** the emulator never suspends its AP and its goldfish HAL is not a real GNSS chip, so (a) the AP-suspend wake path is unproven (that is P2b's, now PARKED), (b) `CAPABILITY_SCHEDULING` behaviour and true indoor TTFF are unrepresented (I-P2-1, I-P2-2), and (c) the GMS `fused` backend's real duty-cycling (I-P2-2) is not exercised. None of these can wedge P2a, because P2a keeps the plugin wake lock; they bound how well the *estimate* transfers, not whether publishing continues.
**POWER-MEASUREMENT gate (estimate-replaced, §2.5).** ~~`dumpsys batterystats --reset` → 60 min backgrounded stationary → per-uid gps time ≤ 10 % of the window (vs ≈ 100 % today)~~ → **ESTIMATED** from model E: GNSS duty falls to ≈ 4 % (hot TTFF ≈ 5 s per ≈ 120 s publish cycle, §2.2), i.e. the location term reaches ≈ **0.06–0.11 %/h**. Read the attribution honestly (§6.5a finding 1): baseline ≈ 1.33–1.89 %/h → **P1** (releasing the 1 Hz UI stream) already takes it to ≈ 0.09–0.79 %/h → **P2a** takes it to ≈ 0.06–0.11 %/h. P2a's distinctive win is the *indoor* bound and the delivery-driven cadence, not the headline fix. The **CI-checkable proxy that must hold** is the mechanism, not the milliamps: B1's parsed `dumpsys location` registration oracle shows exactly ONE Haven request whose interval is ≥ 62 s after the first publish and NEVER a second request, with the anti-vacuity read that the `@+1s0ms` UI request WAS present pre-handoff — which is precisely the duty-cycle input model E multiplies. `dumpsys power` shows `Haven:publish` with `ACQ=` age ≤ 30 s at every sample (the scoped lock's bound) and `ForegroundService:WakeLock` present throughout (P2a keeps it, deliberately). ~~P2b adds: partial wake-lock time ≤ 1 % of the window, no Haven partial lock older than 30 s at any sample, the indoor row under `dumpsys deviceidle force-idle`, screen-off, cellular.~~ — **P2b is PARKED; these rows are DEFERRED with it.**

**Owner decisions / open questions.** OD-P2-1, OD-P2-2, OD-P2-3. V-P2-1 (`dumpsys location` grammar on the CI API-34 image — pre-stated from `LocationRequest.toString()`, closed by the fixture, confirmed on the first run); V-P2-2 (first FGS listen after `onStart` receives events — assert via a `[BackgroundTask] registration armed` marker followed by a delivery in B1); V-P2-3 → V (`PowerManager.WakeLock.acquire(timeout)` on a held non-refcounted lock re-posts the timer, `PowerManager.java:3930-3950, 3984-4000`); V-P2-4 → V (`addTaskLifecycleListener` from `Application.onCreate` precedes the boot-restart engine — `ForegroundService.kt:45-54,173-178`, `ForegroundTask.kt:47-70`, `RebootReceiver.kt:43-46`; confirm on `adb reboot` in M7 runbook step 7); I-P2-1 (HAL `CAPABILITY_SCHEDULING` on the owner's phones — informational, also decides the indoor residual); I-P2-2 (GMS fused duty-cycling); U-P2-1 (delivery→Dart wake window — P2b only; consequence stated in D4).

**LANDED RECORD — P2a (opened by P2a-5, 2026-09-03; P2a-1 … P2a-4 as shipped).**
Every bullet below was re-read in the working tree. Where one contradicts the Design or the Exact change list
above, the bullet is the truth and the text above is the draft it replaced. As in P1's record, that clause
reaches §5.2 and **nothing else**, so where a stale claim also sits in a cross-reference table it is corrected
there in the same commit and named here.

- **`_ensureRegistration` has TWO call sites, not one, and guard check (5) pins the count at exactly 2.** The
  draft asked for "ONE cancel+listen BEFORE any publish, and the ONLY call site", "`_ensureRegistration` (ONE
  call site)" and a guard reading "exactly ONE call site outside its definition". The second site is the
  failure path the same draft requires two clauses later — "on failure leave due (unchanged) and shorten the
  registration to `kBackgroundRepeatInterval − lead` (retry parity)" — and **a retry cadence cannot be known
  before the publishes**: it exists only once one of them has failed, so aiming the request for it from the
  pre-burst site would mean predicting the failure. The consent property the count exists to protect is
  unchanged and is now pinned harder than the draft asked: `check_android_location_power.sh` check (5)
  requires the total to be exactly **2** AND every one of them to be inside `_publishCycle`, below both
  `if (foregroundActive) {` and `if (!backgroundPublishDisclosureAccepted(` — so a third route to a platform
  location request fails by count, not by review, and a site that drifts out of the cycle fails even when the
  total is right. The mutation list's "a second `_ensureRegistration(` call site" is therefore a THIRD one in
  the shipped fixtures. Corrected in place outside this section: §3 D3 (iv)'s "guard-pinned by count (1)",
  §6.1's P2a guards cell and §7.2's check-(5) cell.
- **The watchdog also acts when a circle is already OVERDUE** — a fourth condition beside the three enumerated
  above (ownership, `Idle`, and silence past `kStreamPositionMaxAge` / stream error / `_deliveryPending`). It
  is strictly additive liveness and it does NOT re-introduce the 72 s poll this phase retires, because in the
  healthy steady state it is unreachable: the fix is asked for `kBackgroundFixLeadTime` early and
  `dueKeysUpTo(now + kBackgroundFixHorizon)` selects the circle before its due-time, so the delivery has
  already run the cycle by the time a tick could see anything overdue. It fires exactly where the
  delivery-driven path has already failed the circle — a fix that came late, or a publish that did not land —
  which is the FA wedge class this phase must not be able to re-open silently, and it costs nothing in the
  case the phase optimises.
- **`kFirstDeliveryWait` (2 s) is the name of what the draft called "the ≤ 2 s bound"** (D3 (iii), and the two
  first-cycle tests above). The change list's constant roll-call does not name it because the draft treated
  the bound as a literal; as landed it is a documented constant in `constants/location.dart` carrying both
  halves of its own reasoning — why the wait only has to outlast one event-loop hop (on S+ a registration
  whose interval exceeds `MIN_REQUEST_DELAY_MS` is answered immediately from the provider's cached last
  location) and why it is nevertheless 2 s rather than a microtask (the plugin binds its Android service
  asynchronously, so `onListen` returns before anything can be delivered) — and it is pinned in both
  directions by `location_test.dart`: exactly 2 s, and strictly less than `kOneShotLocationTimeout`, so the
  wait can never cost more than the fallback it exists to avoid.
- **P2a-5's two signal call sites landed as specified**, with the paused one conditional
  (`if (handedOff)`) for S-13's reason and `a declined handoff sends no paused signal` asserting the
  CONTAINMENT rather than the order; the sender is `BackgroundLocationManager.signalTask(String)`, whose own
  tests pin that the signal string is the whole payload and that the two signals are forwarded verbatim and
  in order. The resumed signal is likewise pinned to the Android branch and to a position after
  `markForegroundActive(active: true)` — a cancel the service takes while it still reads "no foreground
  owner" is undone by the very next watchdog tick.

**REVIEW ROUND — P2a (two independent reviewers, 2026-09-04).** Same clause as the record above: where a bullet
here contradicts the Design or the Exact change list, the bullet is the truth. Recorded in full because a reader
who never saw the round would otherwise take P2a's green suite as evidence it was not needed.

- **BLOCKER, found and fixed: the watchdog's early returns latched `_inFlightPublish` forever, and background
  sharing published once per backgrounding and then stopped ≈ 72 s later.** `onRepeatEvent` claims the in-flight
  slot before running the watchdog, but two of the watchdog's exits — the foreground-ownership yield and the
  healthy "nothing to do" return — never reach the release in `_runCycleWithIdleTracking`'s `finally`. A slot left
  pointing at a COMPLETED future is indistinguishable from a running cycle, so from that tick on every later tick,
  every delivery and both handoff signals read "a cycle is in flight" and returned. That is the **FA wedge class**
  exactly — a silent stop with a live service, a held Rule-14 guard and a notification still saying "sending and
  receiving" — reintroduced by the very phase that exists to close it. Reproduced, then fixed by `_trackCycle`,
  which owns the slot for EVERY exit and releases it with an `identical` check (the cycle path releases from
  underneath it, and a later input may already have claimed the slot by the time the tracked future settles).
- **28 green tests in the cycle's own file missed it, and the reason is a test-design lesson worth more than the
  bug.** Every one of them ended with the no-op tick as its LAST action, so each asserted the tick did nothing —
  which is correct — and none asserted the isolate could still do something AFTERWARDS. A latch is invisible to a
  suite that never drives a second input past it. The two regression tests added are named for the property, not
  the mechanism: `a tick that finds nothing to do leaves the cadence alive` and `a tick that yields to the
  foreground leaves the isolate able to take publishing back`
  (`background_location_task_delivery_cycle_test.dart`). Generalise the rule: a test for a guard that CLAIMS a
  resource must outlive the claim.
- **The new standing registration had no CURRENT-consent gate.** The disclosure flags were checked once on the
  path that enables sharing, but a registration that outlives the cycle which armed it keeps the GNSS receiver
  scheduled for a user who has since revoked in Settings. As landed, the cycle reads the freshly reloaded `prefs`
  snapshot and requires BOTH `kLocationDisclosureAcceptedKey` and the background half every cycle, so a revocation
  written by the UI isolate is honoured on the very next one; `check_android_location_power.sh` check (5) pins
  every `_ensureRegistration(` site below both that gate and the foreground gate, so the property is structural
  rather than reviewed.
- **The scoped wake lock was released out from under the teardown drain.** `ForegroundTask.destroy` invokes Dart's
  `onDestroy` ASYNCHRONOUSLY and then calls the Kotlin lifecycle listeners SYNCHRONOUSLY, so a `release()` (or a
  handler detach) in `onTaskDestroy`/`onEngineWillDestroy` drops the CPU out from under the bounded drain — the
  last publish of the session — before it has started. Both hooks are now deliberately empty, with the ordering as
  their stated WHY, release owned by Dart's `finally`, and `MAX_TIMEOUT_MS` as the backstop for a process that
  never gets there; guard check (2) fails a listener that releases or detaches.
- **`onEngineCreate` was unpinned, which made the whole feature silently deletable.** The channel is installed from
  `HavenApplication.onCreate` via `FlutterForegroundTaskPlugin.addTaskLifecycleListener(PublishWakeLock)` — the only
  hook that sees the foreground-service engine before the Dart entrypoint runs, and the only place that runs for
  the Activity-less starts (boot restart, headless wake). Delete that one line and every `acquire` becomes a
  `MissingPluginException` the Dart side deliberately swallows as a no-op: no error, no red test, and no wake lock.
  Now guarded by name with two mutation fixtures (the line deleted; the line commented out).
- **Two B1 oracles could not fire as written, and are now evidence rather than gates.** A relay-side line-count
  check could not fail in either direction (the FGS's own connect plus strfry's expired-event cron guarantee new
  lines), and an emulator `batterystats` GNSS threshold has no referent on a goldfish HAL that contains no
  receiver. Both are printed and never asserted (`run-b1-fgs-publish.sh:1892`, `:1901`), and the wake-lock
  *sighting* count is demoted for the same reason (a cycle can complete inside one sample period, so "seen at
  least once" is a coin flip; the BOUND is what is asserted). A gate that cannot fail is this repo's documented
  recurring failure mode, and three of them reached review in one lane.
- **Two findings from the round are NOT P2a's to fix and are carried in `docs/CI_HARDENING_BACKLOG.md`** (P2a
  review pass, 2026-09-04): the `kMinFixRequestInterval` floor sitting under AOSP's `NO_FIX_TIMEOUT`, and the
  process-singleton `PublishWakeLock` against the plugin's destroy-then-recreate engine lifecycle.
- **Two contradictions the round found in this document are resolved above, not here:** the P2a liveness gate that
  was simultaneously required and shown impossible (§5.2 Acceptance — the grader half is now DEFERRED with step (7)
  named as its successor), and B1 step (8), which was required in five places and implemented in none. **Step (8)
  has since LANDED (B1 lane fix pass, 2026-09-04)** as a second forced-idle phase after `HOLD_COMPLETE`, and the
  landing settles the argument the round had about it: the "AP suspension is unassertable" objection was a category
  error, because the step was always scoped to the Doze-POLICY half — which `dumpsys deviceidle force-idle` produces
  on an emulator, and which the oracle now reads back rather than assuming (`state=IDLE` from `get deep`, because
  `force-idle` exits 0 on a device that refuses to doze). Every one of the eight sites is updated. The legacy
  cold-TTFF residual is recorded in D3 (iii) and §6.3 C6.
- **RE-REVIEW, 2026-09-04 — the phase's clearest lesson: the first fix pass INTRODUCED a MAJOR defect, and the
  tests written in that same pass structurally could not reach it.** MAJOR-1: `onDestroy` re-takes the scoped lock
  and holds it across the bounded drain (`background_location_task.dart:865`), but a cycle the drain ABANDONS at
  its timeout keeps running, and when it reaches its own `finally` it calls `release()` (`:2039`) on the
  process-wide, non-reference-counted lock — dropping the hold the teardown had just re-taken, out from under the
  last publish of the session. Both wake-lock tests written in the same pass wedged the in-flight cycle on a future
  that never completes, so neither could ever drive the abandoned cycle to its `finally`: the assertion the pass
  needed was the one its own test shape excluded. **A fix pass is where the next defect gets planted** — the
  `_inFlightPublish` latch above was a P2a defect found by review, MAJOR-1 was a REVIEW-PASS defect found only by a
  second review with fresh eyes, and the same is true of the two statements this document had to correct (D3 (iii)'s
  gap formula, which contradicted the worst case three sentences below it, and its lever analysis, which was wrong
  about the API-level branch). Nothing here was caught by a green suite.
- **A counting bug found by the same pass, worth keeping as the reason for an idiom.** B1's `--self-test` used to
  end in a hard-coded "all N fixtures passed" with no counter: it ANNOUNCED 40 while the file contained 41, so
  deleting a case would have changed neither the message nor the exit code. The count is now incremented per case
  and compared by EQUALITY (`SELF_TEST_FIXTURES=54`), the shape `check_android_location_power.sh` and
  `summarize-created-at-gaps.sh` already use — and the same shape CI-R8 asks for in
  `check_location_access_gate.sh`, which still prints its count without pinning it.

### 5.3 Phase P3 — iOS native location owner with accuracy profiles + tier-based indicator/session policy + copy/l10n (D1, D2) [OD1]

**Goal / non-goals.** Background sharing ON, stationary: the GNSS receiver is no longer held at Best 24/7; while
backgrounded AND stationary the ONE CoreLocation session runs at `kCLLocationAccuracyHundredMeters` (Wi-Fi/cell,
≈ 4–6× cheaper than a GPS tier — E-I4, a published third-party ratio, ESTIMATED and never measured here) and
returns to Best on movement or foreground — a live `desiredAccuracy` change,
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
  — **CORRECTED 2026-09-04 (P3 security review, F1): `CLError.locationUnknown` returns EARLY and is never
  forwarded.** It is Apple's documented "no fix right now, still trying" signal and is common INDOORS, which is
  exactly where the coarse tier runs. Forwarding it made the Dart `onError` handler call `_resetSession()`, which
  set the controller and `_requestedProfile` back to Best while the NATIVE manager stayed at 100 m; every later fix
  then arrived tagged `hundredMeters`, was dropped as non-Best, and `_applyProfile()` saw no difference to correct —
  so one ordinary indoor moment silently ended background sharing until the user reopened the app. The filter is
  only half the fix: `_requestedProfile` is now nullable and the ERROR path records `null` ("native tier unknown")
  so the next `_applyProfile()` re-issues `setProfile` unconditionally. The filter alone leaves `.network` and
  friends able to desync; the sentinel alone leaves the session flipping to Best on every indoor moment. Errors are
  still pushed through the sink and `denied` is still distinguished, so filtering cannot become swallowing —
  `check_ios_background_publish.sh` pins all three properties.
  — type only, never `localizedDescription` (m7 check 10 `:1247-1262`). `status()` →
  `["running","allowsBackgroundLocationUpdates","showsBackgroundLocationIndicator","profile","authorization","backgrounded"]`
  (booleans/enum strings only; `backgrounded = applicationState == .background`). `lastBestFix()` → map or nil;
  `clearLastBestFix()` → nil. No logging (posture of the session handler, check 8 `:296-299`). Relaunch via
  SLC/region/BGTask: `applicationState == .background` at `onListen` ⇒ refused, AND the Dart cold-cache shortcut
  reads `backgrounded` (below) so the plugin one-shot is unreachable too — the wake is receive-only BY CONSTRUCTION
  on both paths (closes the FA relaunch hole). Nothing version-gated (APIs iOS 15.5-safe); the session handler keeps its
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
  pointer-compare trap `:113-114` / FA Unit F's note on geolocator's pointer-comparing `LocationDistanceMapper` becomes moot — say so in the guard header so nobody re-adds
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
  signal in size"; `raw_accuracy` still skipped. **NOT LANDED (recorded 2026-09-04, WP3-6): that Rust test was never written** — grepped, no `resent_fix_payload_has_identical_shape` and no equivalent anywhere in `haven-core` or `haven/test`. The rest of this block stands on its own (the profile switch is a property write; the publish instants come from three unchanged drivers), so what is missing is the PIN, not the argument; `INV-L-IOS-PUBLISH-INPUT-BEST-PROFILE-ONLY` therefore omits the equal-length clause rather than citing a test that does not exist. Carried as CI-R21 in `docs/CI_HARDENING_BACKLOG.md`.
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
- Native: NEW `haven/ios/Runner/HavenLocationStreamHandler.swift`; `haven/ios/Runner.xcodeproj/project.pbxproj` (objectVersion 54, `:6`, explicit file lists) by the precedent of the four existing handlers (`:14-17`, `:55-58`, `:130-133`, `:304-307`): ids `5E10CA750000000000000001` (PBXFileReference, after `:58`) and `5E10CA750000000000000002` (PBXBuildFile, after `:17`); one line in the Runner group children (after `:133`) and one in the `Sources` phase (after `:307`) — `grep -c 'HavenLocationStreamHandler.swift' project.pbxproj` must be 4 (FA Unit F avoided a pbxproj edit for the *region* because it fit an existing handler; a new updates-owner is a new concern and follows the 2026-08-20 session-handler precedent). `AppDelegate.swift:17-34,47-61` → retain + register (with the others; only the BGTask handler must precede `super.application(…)`, `:223-226`); `locationStreamHandler.onAuthorizationChanged = { [weak self] in self?.backgroundSessionHandler.arm() }` assigned AFTER `backgroundSessionHandler.register(with:)` (line-order pin — the delegate fires at manager creation). `HavenBackgroundSessionHandler.swift:134-136` → `alwaysConfirmed` + tier branch + the background guard; iOS 18 diagnostics observer; `status()` gains `alwaysConfirmed`; header `:15-17` ("created under When-In-Use and until Always is CONFIRMED — under confirmed Always it would be the pill; arm() never withdraws a claim while backgrounded; disarm() always does").
- Dart: NEW `ios_location_source.dart` (channel + controller + timer, one class), `utils/geo_distance.dart` (`haversineMeters` moved out of `map_shell.dart:1150-1170`); `geolocator_location_service.dart` edits above; `constants/location.dart` → three constants (`kStationaryConfirmMaxAccuracyMeters = kMotionTriggerDistanceMeters`, doc with the 200 m bound) + `kStreamPositionMaxAge` doc `:131-148` ("a fix at most this old — or, on iOS while stationary, a Best-profile fix CONFIRMED this recently by a ≤ 100 m-accuracy fix within 100 m of it; undetected displacement while confirming < 200 m"); `service_providers.dart:107-128` → `iosLocationSourceProvider` (shape of `:115-119`); `locationServiceProvider` passes it; `ios_location_auth_service.dart:3-5` → "Background sharing continues under While-In-Use (with the OS's blue location bar); 'Always', once confirmed, is what lets Haven not show that bar and catch up after termination." ("not show", never "hide"); `location_settings_page.dart:158-160, :298-310` → the guidance card renders only under `IosAuthStatus.always` and composes base + (`alwaysConfirmed ? arrow : bar`) from a `iosIndicatorSentenceProvider` (**corrected
2026-09-04: the selector is `alwaysConfirmed`, NOT `backgroundActivitySessionHeld` — the latter is false on the
iOS 15/16 floor while the bar is up, so it would pick the arrow sentence for a user looking at a bar;
`ios_indicator_copy_accuracy_test.dart` now fails if that name is used as the selector**) (reads `iosBackgroundSessionServiceProvider.status()`, invalidated on toggle `:113` AND on `AppLifecycleState.resumed` from the page, together with `iosLocationPermissionProvider`) (**CORRECTED 2026-09-04, second pass: the provider is `FutureProvider<IosIndicatorSentence?>` and answers `null` while the handler reports `armed == false` — a new `armed` key on the status channel, set on `arm()`'s gates-passed path and cleared by `disarm()`. `disarm()` clears `alwaysConfirmed` UNCONDITIONALLY, so with background sharing off that false was a teardown residue, not a tier reading, and the card told a confirmed-Always iPhone "iOS shows its blue location bar" at the exact moment it was deciding whether to turn sharing on — the promise this whole tier split exists to avoid. `null` reuses the card's existing "wait rather than guess" gate, so the toggle being off needs no separate gate on the card. The page now also invalidates the provider on the DISABLE edge, which only the enable and resume paths did**); `map_shell.dart:376-391` comments; `ios_background_session_service.dart:32-47` parser gains `alwaysConfirmed` (and `indicatorShown` if OD-P3-c lands) with its fail-closed tests extended.
- ARB (13 files: en, ar, de, es, fa, fr, hi, ja, ne, pt, ru, tr, ur): `locationSettingsIosGuidance` (`:473`, becomes the tier-neutral BASE), ~~NEW `locationSettingsIosCatchUp` (the catch-up sentence moved out of the guidance value; the 12 translations copied byte-for-byte, never re-translated; rendered LAST)~~ **DELETED 2026-09-04 (CI-R23): the card renders ONLY under Always, so the sentence's inducement to GRANT Always reached nobody and it was never composed in; it shipped unread in 13 locales and the key, its `@description` and its twelve translations are now gone — the card is TWO sentences**, NEW `locationSettingsIosIndicatorArrow`, NEW `locationSettingsIosIndicatorBar`, `locationSettingsIosLimitedNote` (`:453`) per §7.1 (English + `@description` verbatim there), plus the adopted bar-raise NEW `settingsLocationSubtitleOn` / `settingsLocationSubtitleOff` (the Settings hub Location tile's dynamic subtitle, §7.1). `locationSettingsIntro`/`ToggleSubtitle` untouched. Workflow (P6 rule 8 — binding for every round): translator agent ×12 → INDEPENDENT reviewer agent ×12 handed the GATING FACTS (which key renders under which tier/handler state; the base key must not name any indicator; the arrow/bar keys name exactly one; no "pause"/"timer"; Apple's localized Settings menu names, tier-neutral "Location Services settings" wording because iOS 15 has no "Privacy & Security" menu) who check the translator's REASONING, not just output (register, plurals, RTL for ar/fa/ur, screen-reader readability) → `dart run scripts/ci/arb_parity_check.dart haven/lib/l10n` → `cd haven && flutter gen-l10n` (warning-free) → `l10n-check.yml`; `l10n-ai-review.yml` advisory.
- Non-ARB copy: `.github/workflows/e2e-ios-auth-tier.yml:10-16` → "…keeps delivering under 'When In Use', with the blue location bar (mandatory there); under a confirmed 'Always' Haven shows no bar."; `run-b7-ios-auth-tier.sh:10-16` same; `tooling/e2e/ci/run-ios-bg-publish.sh:248-270` drip comment (no filter; the drip's job is delivery + staying below 100 m); `haven/integration_test/ios_bg_publish_test.dart:410-433` `_failIfSuspended` names the native session (`HavenLocationStreamHandler`, `allowsBackgroundLocationUpdates` parameter); `geolocator_location_service.dart:637-641` comment rewritten with the tier rule; `CLAUDE.md:258` lane sentence → "native CoreLocation session armed (tier-dependent indicator/session oracle) + publishes continue under the 100 m stationary profile + toggle-off silence".
- Guards (`scripts/ci/check_ios_background_publish.sh`): file list `:34-43` → add `STREAM_HANDLER`, `IOS_SOURCE`, `PBXPROJ`. Check 2 (`:192-196`) → keep "exactly 1 `.getPositionStream(`"; ADD "exactly 1 `.positions(`" in the service and `receiveBroadcastStream(` only in `ios_location_source.dart` under `haven/lib`. Check 3 (`:201-206`) → `AppleSettings(` banned inside `_streamSettings`. Check 4 `check_stream_settings` (`:100-128`) → REPLACED by `check_ios_stream_route <service.dart>`: `getLocationStream` body contains `positions(allowsBackgroundLocationUpdates: backgroundSharingEnabled)` exactly; file-wide NO other `allowsBackgroundLocationUpdates *:` (R8); `_streamSettings` has no `AppleSettings(`; `getCurrentLocation` body references `lastBestFix(` BEFORE `getCurrentPosition(` (line-order, like check 12 — the F4 route); `clearCachedPosition` body contains `clearLastBestFix(`. Fixtures (8): passes; `allowsBackgroundLocationUpdates: true` literal; second `.positions(`; `AppleSettings(` back; one-shot before `lastBestFix(`; `clearLastBestFix(` missing; `_foregroundActive` back in the backgrounded shortcut; everything commented out (anti-vacuity). NEW `check_native_stream_handler <swift>`: `init` contains `pausesLocationUpdatesAutomatically = false`, `distanceFilter = kCLDistanceFilterNone`, `activityType = .other`; file-wide exactly one `distanceFilter =` and one `pausesLocationUpdatesAutomatically =`; `desiredAccuracy =` names ONLY `kCLLocationAccuracyBest`/`kCLLocationAccuracyHundredMeters`; `onListen` contains the one-line `allowsBg = ` + `args["allowsBackgroundLocationUpdates"] as? Bool ?? false`, `applicationState == .background` AND `background_start_refused` emitted via `events(FlutterError(` (never `return FlutterError(`), `allowsBackgroundLocationUpdates = allowsBg`, and is the only `startUpdatingLocation()` site; `showsBackgroundLocationIndicator = !` + `alwaysConfirmed` exactly once and no other assignment; `lastBestFix =` only inside `if manager.desiredAccuracy == kCLLocationAccuracyBest && loc.timestamp >= bestSince`; `onCancel` contains `lastBestFix = nil`; `clearLastBestFix` handled; no `NSLog\(|[^a-zA-Z]print\(|localizedDescription`. Fixtures (16): passes; auto-pause on; `distanceFilter = 100`; third tier; literal `true`; `?? true`; `let allowsBg = true`; R7 gate removed; R7 gate written as `!= .active`; `return FlutterError(` from `onListen`; indicator hardcoded `true`; second `startUpdatingLocation()`; `lastBestFix` under 100 m; `lastBestFix` without the `bestSince` comparison; `onCancel` without `lastBestFix = nil`; coordinate reaches `NSLog`. Check 8 (`:277-310`) → factored `check_arm_tier_policy <swift>` CARRYING all eight existing assertions (consent key, disclosure key, `disarm()` in arm, `.authorizedWhenInUse`, `#available(iOS 17.0, *)`, `CLBackgroundActivitySession()`, `.authorizedAlways`, no `NSLog/print`, disarm invalidates + nils both — the Rule-10 fail-closed gate that must never rot) plus: `CLBackgroundActivitySession()` AFTER `wantsActivitySession` inside `arm()`, `wantsActivitySession` derived from `.authorizedWhenInUse ||` + `!alwaysConfirmed`, the invalidate inside `applicationState != .background`, `arm()` contains `backgroundActivity = nil`, the diagnostics observer's body contains both `arm()` and `onAlwaysConfirmedChanged` (a confirmation must re-run the policy, not just set a flag); fixtures (7): passes; unconditional creation; Always branch no longer nils; WIU branch deleted; activity session gated on `.authorizedWhenInUse` alone (provisional falls through); invalidate without the `applicationState` guard; observer sets `alwaysConfirmed` without re-arming. Check 7 (`:260-266`) → add `IOS_SOURCE` to the Dart presence-only list. Check 9 (`:320-327`) → `locationStreamHandler.register(with: messenger)` + `onAuthorizationChanged` wiring AFTER `backgroundSessionHandler.register(with:` (line-order). Checks 11 + 12 (`:349-400`) → factored `check_bg_publish_drive <dart>`: check 11's banned list gains `iosLocationSourceProvider.override`, `NoopIosLocationSource`, `FakeIosLocationSource` (a faked native source reproduces the CI 32646436116 vacuity with the old check green); fixtures (2): passes; native provider overridden → fail. NEW check 14: pbxproj references the Swift file exactly 4× (valid because the new file's comments carry `.swift`; do not generalise to the BGTask precedent whose fileRef comment omits it — a file on disk but absent from the project compiles nowhere and fails silently as `MissingPluginException`, which the Dart source swallows as "no native handler"). `SELF_TEST_FIXTURES` pinned by equality at what lands (expected 47 = 8 route + 16 native + 7 tier + 2 drive + 9 region + 5 stream-provider from P1) at `:440`; header `:2-29` (incl. "the `-1` mapper trap is moot under the native owner") and the `OK:` line `:654` rewritten. `scripts/ci/check_m7_native_wake_guards.sh` → check 10 (factored in P2a): add `"$STREAM_HANDLER"` and `"$IOS_SOURCE"` to the list (the `SENS` scan catches `\(location`, `coordinate`, `latitude`, `\blat\b|\blon\b` in Swift and Dart — the sink map's `"lat"` dictionary KEY is not interpolation and does not false-positive; a `debugPrint('$fix')` in Dart would) + one planted-coordinate fixture per file; check 13 (`:1304-1311`, AppDelegate stored-property pin by NAME) gains `locationStreamHandler`. `check_no_key_logging.sh:705-707` scans Rust + all of `haven/lib` (no Swift list) — no change. `.github/workflows/repo-guards.yml:129-145` comment block → native-owner pins; steps `:691-701` unchanged.
- `docs/privacy/privacy_invariants.json` (host tests ONLY are cited — rule 4 rejects `haven/integration_test/**` citations that `markTestSkipped(`, which b7 does at `:265`; b7 stays a LANE oracle in §6.1): `INV-L-IOS-WAKES-RECEIVE-ONLY` → `assertion_arb_keys` become ~~`[locationSettingsIosCatchUp, locationSettingsIosLimitedNote]`~~ **`[locationSettingsIosLimitedNote]` (corrected 2026-09-04, CI-R23: the catch-up key was deleted unrendered; the note is the sole ARB assertion carrier, and the disclosure key `locationSettingsIntro` still states the receive-only limit in every state)** — ~~the catch-up sentence MOVES verbatim out of `locationSettingsIosGuidance` into its own key (render order base → indicator → catch-up, UX N-2)~~ (as planned; the third sentence was never composed in and the key is gone — the rendered order is base → indicator), which the ratchet reads as a dropped assertion key on the guidance key → `ratchet_override.items: ["INV-L-IOS-WAKES-RECEIVE-ONLY.assertion:locationSettingsIosGuidance"]` with a ≥ 40-char reason naming the verbatim move, deleted in the first commit after merge (P6 rule 2 — a key that merely moves is not a weakening, but the gate cannot see that by itself); add symbol `haven/ios/Runner/HavenLocationStreamHandler.swift::onListen` and tests `ios_location_source_test.dart → 'a background_start_refused error pushed through the sink surfaces as a stream error'`, `geolocator_location_service_test.dart → 'a backgrounded cold cache on iOS never starts the one-shot, even when the lifecycle hint says foreground'`, and the copy-tie `(c)` (the FIRST test that actually reads its two assertion keys — today's `background_claim_accuracy_test.dart` reads the plist + `LocationDisclosureStrings`, never the ARB keys, `:272-297` — **superseded 2026-09-04 (OD-P3-g): the consent copy IS ARB now, that test reads it through `AppLocalizations`, and it gained a claim-level divergence group tying `locationDisclosureBackgroundIos` to `locationSettingsIntro`**)); statement gains "…and the native updates owner refuses a background-capable start from the background while the cold-cache shortcut reads the native lifecycle, so a relaunched process cannot resume publishing". NEW `INV-L-IOS-INDICATOR-HONEST` (enforced): "Under confirmed Always, `showsBackgroundLocationIndicator` is false and no `CLBackgroundActivitySession` is held (the OS arrow is the only signal); under When-In-Use, provisional Always and iOS 17 Always the activity session is held and the blue bar is shown; the settings copy selects its indicator sentence from the handler's own state." `assertion_arb_keys: [locationSettingsIosGuidance, locationSettingsIosIndicatorArrow, locationSettingsIosIndicatorBar, locationSettingsIosLimitedNote]`; `symbols`: `HavenBackgroundSessionHandler.swift::arm`, `HavenLocationStreamHandler.swift`; `tests`: `test/lints/ios_indicator_copy_accuracy_test.dart`, `test/l10n/location_settings_copy_accuracy_test.dart`, `test/pages/location_settings_page_test.dart → 'the indicator sentence follows the session handler state'`; `guards: [scripts/ci/check_ios_background_publish.sh]`. NEW `INV-L-IOS-PUBLISH-INPUT-BEST-PROFILE-ONLY` (enforced): "On iOS only fixes delivered under the Best profile (`desiredAccuracy == kCLLocationAccuracyBest` and computed after the switch) are cached as the publish input or returned as last-known; 100 m-tier fixes serve only the movement detector and the freshness bound; the native and Dart copies clear together; a re-sent stationary fix serialises to the same length as a fresh one at the same coordinate." Symbols `IosLocationSource`, `HavenLocationStreamHandler.swift::lastBestFix`; tests: the three only-Best tests + the two clear tests + Rust `resent_fix_payload_has_identical_shape`; guards: `check_ios_background_publish.sh`; no disclosure key (the Privacy page was removed 2026-08-29). ~~The ONLY `ratchet_override` in P3 is the catch-up key move above (nothing weakened).~~ **CORRECTED 2026-09-04 (WP3-6, verified against the gate): P3 needs NO `ratchet_override` at all, and writing the planned one REDS the build.** `enumerate_weakenings` subtracts `$still` — the set of assertion keys claimed anywhere in the NEW manifest — before enumerating a dropped assertion (`check_privacy_invariants.sh`, and its header says so in as many words: *"A key that merely MOVES between invariants is not a weakening — the promise still stands and is still proved"*). Because `INV-L-IOS-INDICATOR-HONEST` claims `locationSettingsIosGuidance` as an assertion key, exactly as this list specifies, the key is still claimed and the drop is never enumerated; an override naming it is then STALE and fails the ratchet's second half. Tried and confirmed on the branch: with the override present the gate fails with *"ratchet_override names item(s) that are NOT weakened by this change"*; with it absent the gate is green. Do NOT un-claim the guidance key to make the override necessary — that would drop live assertion coverage for a bookkeeping formality. The standing trap the override rule exists for is unchanged and still applies to every override that IS needed (P5(a)'s, for one): an override is compared against the PR's base, so after merge it goes stale on the next PR and must be deleted in the first follow-up commit.
- Docs: `M7` §6 item 0 → split, never deleted, and ~~**0a becomes a WP3-2 MERGE gate**, not an acceptance item~~ → **AMENDED 2026-08-30 (§2.5): 0a and 0a-provisional are written into M7 §6 exactly as specified below but headed `DEFERRED — no iPhone available (see docs/POWER_EFFICIENCY_PLAN.md §2.5); STILL AUTHORITATIVE, run when hardware returns`; the WP3-2 merge gate is the re-based CI bundle instead (WP3-2 row), and M7's ⚠️ RE-RUN REQUIRED banner STAYS.** Writing them now is the point: the steps, the expected observations and the Console recipe are cheapest to record while the design is fresh, and a checklist reconstructed later would omit exactly the details that make it decisive. **0a (Always)** open Haven, fix on map, Home, ≥ 2 h stationary; EXPECTED: NO blue bar, status-bar arrow only; Settings › Privacy › Location Services › Haven shows the arrow; Settings › Battery lists Haven with "Background Activity"; peer keeps receiving on 72–168 s with no relay-side gap > 228 s for ≥ 2 h (the original wedge test); Console.app `locationd` shows the client's accuracy dropping to 100 (I: locationd logs `desiredAccuracy`) after ~2 min and the "Location subscription" RunningBoard assertion held (the Console recipe now written into §6 item 0 itself); walk ≥ 150 m → peer sees the move within one interval and accuracy returns to Best; **0a-provisional row** (reset TCC, enable from Settings first so the grant is provisional): EXPECTED pill + continuity (the WIU posture) and, after answering the second prompt WHILE HAVEN IS BACKGROUNDED, publishing must not stop and the bar clears at the next foreground — V-P3-3/V-P3-4 are closed by this row. **0b (When-In-Use)** as today's item 0 (blue bar expected, mandatory). **0c (stuck indicator)** after 0a/0b toggle OFF and confirm the bar/arrow clears within a minute on iOS 18 and 26 (DTS 771422/783585); if it sticks, file Feedback and record; 0c cites the handler header sentence "arm() never withdraws a claim while backgrounded; disarm() always does". Toggle-OFF expectations (`:836-841`) with the stale "1 m distance filter" corrected (`:838-840`, `:1198-1199`, the `CI_HARDENING_BACKLOG.md` app-ops paragraph, `FA` §3 "How the pipeline works" — P0 did today's truth; P3 re-states for the native owner). `M7` §A "Honest residual observability" statement: the arrow + Settings attribution as the iOS visible signal under confirmed Always. FA Unit F amendment: "2026-08-29 (power plan P3): the iOS updates owner is `HavenLocationStreamHandler.swift`. The 16.4 shape is honoured in BOTH profiles — `allowsBackgroundLocationUpdates` on, `distanceFilter = kCLDistanceFilterNone`, `desiredAccuracy` ≤ 100 m (Best foregrounded/moving, HundredMeters backgrounded+stationary), `pausesLocationUpdatesAutomatically = false`. R2 (`:205-210`) re-argued against the DTS text: the indicator is offered as an ALTERNATIVE to that shape, not a requirement on top of it, so under CONFIRMED Always it is no longer part of the anti-suspension posture; under When-In-Use and until Always is confirmed it remains (mandatory). The `distanceFilter: -1` geolocator workaround is retired with the plugin path." FA `:218-222` → "relaunch cannot resume publishing: the native owner refuses a background-capable start and the cold-cache shortcut reads the native lifecycle." `MESH_LOCATION_RELAY_DESIGN.md:304` G-10 → "the map's own sharing control and the Android notification signal it; on iOS the status-bar arrow (no blue bar under confirmed Always)". `PrivacyInfo.xcprivacy` unchanged (PreciseLocation still true — only Best-profile fixes are published).

**Tests FIRST** (host Dart, red before code).
- NEW `haven/test/services/ios_location_source_test.dart` — controller half (pure, fixed `DateTime`s, no `fake_async`): `foreground always yields Best`; `backgrounded: no ≥100 m displacement for kStationaryDwell drops to HundredMeters; a ≥100 m step within the dwell restarts it`; `stationary: a ≤100 m-accuracy fix ≥100 m away switches to Best; one inside 100 m only confirms`; `a fix coarser than kStationaryConfirmMaxAccuracyMeters neither confirms nor moves`; `a confirmed anchor is never more than kMotionTriggerDistanceMeters + kStationaryConfirmMaxAccuracyMeters from any confirming fix` (the 200 m bound); `no confirmation for kStationaryConfirmMaxAge escalates to Best and restarts the dwell` (`nextDeadline`/`onDeadline`); `resume from stationary returns Best immediately (property write, no restart)`; `the anchor is only ever a Best fix`; `a Best-profile fix stamped before the switch to Best is not cached` (the `bestSince` rule, mirrored in Dart). Channel half (mocks, pattern `ios_background_session_service_test.dart:32-100`): `positions passes allowsBackgroundLocationUpdates as the listen argument`; `a background_start_refused error pushed through the sink surfaces as a stream error` (the fake native emits through the EVENT SINK, never a `listen` failure — §2.1); `status parses the native map and fails closed on a missing or wrong-typed key (backgrounded defaults to true)`; `lastBestFix null-safe`; `clearLastBestFix invokes the channel`; `Noop never emits on non-iOS`.
- `geolocator_location_service_test.dart`: `iOS routes the stream to the native source with allowsBackgroundLocationUpdates == the toggle, and never calls getPositionStream` (both toggle values; `verifyNever`); `a HundredMeters fix is never emitted and never replaces the cached Best fix`; `a confirming fix refreshes the freshness bound: the cached Best fix is served past its own age`; `with no confirmation the cached Best fix ages out at kStreamPositionMaxAge`; `backgrounded iOS with a cold cache reads the native lastBestFix, never the plugin last-known, never the one-shot`; `a backgrounded cold cache on iOS never starts the one-shot, even when the lifecycle hint says foreground` (fake `status()` reporting `backgrounded: true`; `verifyNever(getCurrentPosition)`); `clearCachedPosition clears the native last-Best fix`; `a toggle-off pause leaves no native last-Best fix` (with the P1 gate); `a native background_start_refused error clears the cache and reaches subscribers` (existing semantics `:1953-1973`); `stream cancel resets the profile controller and cancels the confirm timer`; `setProfile is invoked exactly once per transition`; `a lost access clears the confirmed age with the cache`; Android arm: `getPositionStream` called once with unchanged settings (`distanceFilter 1`, `intervalDuration 1 s`, `forceLocationManager`, `accuracy best`).
- `location_provider_test.dart` → `:134,:146,:157` rewritten against a `FakeIosLocationSource` (captured `allowsBackgroundLocationUpdates`); `:182` cache-clear kept; `:141-143,:153-154` (flags in a settings object) → "the provider passes the toggle to the platform router" + the P1 lifecycle cases.
- `test/constants/location_test.dart` → `kStationaryDwell == kLocationUpdateInterval`; `kStationaryConfirmMaxAge < kStreamPositionMaxAge && == 84 s`; `kStationaryConfirmMaxAccuracyMeters == kMotionTriggerDistanceMeters`; `kStationaryConfirmMaxAge + kStationaryDwell` ordering sanity (escalation lands a Best fix inside the cache bound).
- NEW `haven/test/lints/ios_indicator_copy_accuracy_test.dart` (pattern `background_claim_accuracy_test.dart`): reads `app_en.arb` + the Swift file — the BASE key must not contain "blue", the PHRASE "blue location bar", "indicator" or "arrow" while the Swift policy line is `= !` + `alwaysConfirmed` (bare "bar" is NOT forbidden anywhere — the arrow key legitimately says "status bar"); the arrow key must contain "arrow" and "status bar" and neither "blue" nor "blue location bar"; the bar key and the limited note must contain "blue location bar"; ~~the catch-up key must equal the sentence removed from the old guidance value;~~ (dropped with the key, CI-R23) no key contains "low-power"/"low power" (a battery promise) or "pause"/"paused"/"timer"; anti-vacuity (all strings and the Swift line found). NEW `haven/test/l10n/location_settings_copy_accuracy_test.dart` (13 locales; pattern `repair_copy_accuracy_test.dart`; per-locale vocabulary = the "blue" WORD, the "blue location bar" PHRASE as translated, the "arrow" term, the "status bar" term): (a) the base key contains none of the locale's "blue" word, "blue location bar" phrase, "indicator" or "arrow" terms; (b) the arrow key contains the locale's "arrow" term and none of its "blue" word / "blue location bar" phrase — its "status bar" term (de "Statusleiste", ar "شريط الحالة") is allowed and required; the bar key and the limited note contain the locale's "blue location bar" phrase; (c) ~~the CATCH-UP key and~~ the limited note contain**s** the locale's "Always" term and a "closes/ends the app" phrase (mirrors `background_claim_accuracy_test`) ~~and the catch-up value is byte-identical to the sentence removed from that locale's guidance value~~ (catch-up half dropped 2026-09-04 with the key, CI-R23); (d) every supported locale has a vocabulary entry AND its forbidden list contains the OLD sentence's words (e.g. `app_de.arb:111` "durchgehende"/"blaue", `app_ar.arb:111` "متواصلة"/"أزرق") so an untouched translation under a re-worded key is caught; (e) the scanner catches a planted violation in both directions — the planted phrase is "blue location bar", the passing fixture contains "status bar".
- NEW `haven/test/pages/location_settings_page_test.dart` → `the guidance card renders only under Always; nothing under denied/notDetermined/restricted/unknown; the limited note under whenInUse`; `the card renders base, then the indicator sentence` (one paragraph; ~~then the catch-up sentence~~ never landed — CI-R23); `the indicator sentence follows the session handler state` (fake session service held → bar sentence, not held → arrow sentence); `the permission and indicator providers are invalidated on resume` (fake auth service flipping tier across a simulated `AppLifecycleState.resumed`).
- NEW `haven/test/lints/ios_stream_handler_registration_test.dart` (or guard check 14) → pbxproj references the Swift file 4×.
- Rust: `resent_fix_payload_has_identical_shape` (serialized LENGTH equal for a re-sent vs fresh fix at the same coordinate; `raw_accuracy` still `#[serde(skip)]`; the residual recorded in the test doc). **NOT WRITTEN — still owed (CI-R21).**
- `background_location_provider_test.dart:1333-1385` (`stateAtArmTime` ordering) → keep; ADD tier cases (fake handler reports tier + `alwaysConfirmed`): confirmed Always → `backgroundActivitySessionHeld == false && serviceSessionHeld == true`; WIU → the inverse; Always with `alwaysConfirmed: false` (provisional / iOS 17) → `held == true`; `a delayed confirmation releases the activity session and re-applies the indicator` (fake handler reports `alwaysConfirmed: false` at `arm()`, then flips it and fires `onAlwaysConfirmedChanged` — `held` becomes false and the indicator policy is re-applied without a foreground transition).
- Guard mutations: `bash scripts/ci/check_ios_background_publish.sh --self-test` → 43 (pinned by equality at what lands); each fixture written before its grep; `check_m7_native_wake_guards.sh --self-test` log-fixture count bumped by exactly the two planted files.
- Existing red → replacement (never loosened): `geolocator_location_service_test.dart:894-963` (iOS `AppleSettings` shape incl. `:919 showBackgroundLocationIndicator isTrue`, `:917 distanceFilter -1`, `:958`) → retired WITH the branch; replaced by the iOS-route tests (R8 moves from "flags in a settings object" to "the listen argument == toggle" — same promise, new carrier) + the Swift guard; the P0 five-way accuracy test drops its two iOS-stream arms and keeps the Android arm + both one-shots; Android test `:965-975` stays. Cache family (`:1040-1057,:1065-1076,:1996-2014,:2153-2176,:1963-1971`) unchanged in substance + one case "a HundredMeters-profile fix is NOT cached as publishable". "Doomed one-shot" (`:1134-1153, :2017-2035`; backgrounded iOS cold cache → plugin last-known) → same promise ("never the one-shot"), fallback now `iosStream.lastBestFix()`. `location_provider_test.dart:142` (`showBackgroundLocationIndicator`) → dropped WITH its carrier; the policy is asserted natively (lane P1) + copy-tie + guard. `location_access_provider_test.dart:424` reason → iOS half reworded ("the native session delivers whatever CoreLocation computes; silence is still not evidence"); assertion unchanged. `map_shell_test.dart`, `ios_background_session_service_test.dart` unchanged. `ios_bg_publish_test.dart` P1 `:751-760` (`backgroundActivitySessionHeld isTrue`) → the WIU run PINS the tier it observed right after the enable: `expect(tier, IosAuthStatus.whenInUse, reason: 'this run proves the WIU branch; a provisional Always here means the sim escalated and the lane is no longer measuring what its header says')` (`:762-765` today accepts either value — under the new policy a silent branch swap would run the Always shape non-deterministically and red P2b "honestly" on some runs; a tier flip is now a red, attributable run); then `expect(held, isTrue)`; NEW after the fresh-fix wait `:790-806`: `streamStatus = await iosSource.status()` → `running`, `allowsBackgroundLocationUpdates == true`, `showsBackgroundLocationIndicator == true`, `profile == best`, `backgrounded == false` (the WIU run is otherwise UNCHANGED — verification G6). P2b `:961-1000`: NEW profile oracle read from the backgrounded process before the count is asserted, as a BOUNDED POLL on the existing heartbeat pattern (a single read is a coin flip if V-P3-1 fails — the confirm deadline escalates every 84 s): "`hundredMeters` observed at least once after ≥ `kStationaryDwell` of backgrounding, within `kStationaryDwell + kStationaryConfirmMaxAge`", printed with the poll count (proves the profile ENGAGES in the background and that publishing continued under it); on re-foreground (`finally`) no pump-dependent assertion. P3 `:1160-1185` unchanged. **Always run (OD-P3-c, recommended):** a second matrix job under `location-always` asserting `held == false && serviceSessionHeld == true && alwaysConfirmed == true` plus P2a/P2b under that shape (the keep-alive proof for the shape whose physical neighbour failed; NOT a pill oracle — a simulator cannot show it), marker `[bg-publish] ALWAYS_SESSION_OK`; shell fixtures C2–C5 extended; `check_live_sync_define_declared.sh` for the new matrix job; if the simulator suspends under that shape the lane says so before a physical phone does. `b7_ios_auth_tier_test.dart:386-390` reason 'a continuous session with the blue indicator' → 'a location session that drops to a coarser tier while still, with the OS arrow and no blue bar once Always is confirmed, plus catch-up after iOS closes the app'; NEW in both runs (session status is independent of the faked location service — `_seedPublishPrefs` `:427` makes `_load()` arm, `background_location_provider.dart:163-165`): `expect((await sessionService.status()).backgroundActivitySessionHeld, tier == IosAuthStatus.whenInUse)` and, under `location-always` (a FULL grant), `alwaysConfirmed == true` asserted through a BOUNDED status poll (the diagnostic lands asynchronously after `arm()` returns — a single read right after `arm()` is a race) — the one CI observation of the diagnostics path (the lane already runs under `location-always`, `run-b7-ios-auth-tier.sh:10`). `e2e-ios-real-gps` (b4): unchanged (one-shot stays geolocator; `getCurrentLocationFresh` tolerance 1e-5° unchanged). Guard checks 11/12 keep their meaning (production location service AND production native source; fresh fix from the REBUILT stream before READY — the native stream must still surface a fresh timestamp on `locationStreamProvider`; the pump is still required, `markNeedsBuild` deferral is Riverpod's).

**Implementer work packets.**
| # | Packet | Sequencing | Done when |
|---|---|---|---|
| WP3-0 | Tests (red): all host tests above + guard fixtures against hand-written Swift/Dart snippets | first | `cd haven && flutter test test/services test/providers test/constants test/lints test/pages` red on the new files; `check_ios_background_publish.sh --self-test` expected 47, red until the greps exist |
| WP3-1 | Dart: `ios_location_source.dart` (channel + pure controller + timer), `geo_distance.dart`, constants, service integration (route, backgrounded shortcut, native clear), `service_providers.dart`, settings-page gating + indicator-sentence provider | ∥ WP3-2 (WP3-1's fake-channel tests define the wire shape both implement) | `flutter test test/services/geolocator_location_service_test.dart test/services/ios_location_source_test.dart test/providers/location_provider_test.dart test/constants/location_test.dart test/pages/location_settings_page_test.dart && flutter analyze && bash scripts/ci/check_location_access_gate.sh` |
| WP3-2 | Swift: stream handler (sink errors, `bestSince`, `onCancel` clear, `clearLastBestFix`, `backgrounded` status), pbxproj (4 lines), `AppDelegate.swift` (wiring order), session handler `alwaysConfirmed` + tier branch + background guard + diagnostics observer | ∥ WP3-1 | `cd haven && flutter build ios --debug --no-codesign` (macOS) compiles and `build-check.yml`'s iOS job is green on the branch; `ios_bg_publish_test.dart` P1 passes on a booted sim with `simctl privacy grant location` (and under `location-always`: `held == false`, `serviceSessionHeld == true`, `alwaysConfirmed == true`); ~~**MERGE GATE: hardware M7 §6 0a (≥ 2 h stationary under Always, accuracy 100 observed in Console, RunningBoard assertion held, no relay-side gap > 228 s) and the 0a-provisional row recorded in `POWER_MEASUREMENT.md`**~~ — **RE-BASED 2026-08-30 (§2.5): 0a is UNMEETABLE (no iPhone) and is DEFERRED, not dropped.** The merge gate becomes the strongest bundle CI can still produce, and **all four parts must hold**: (1) `e2e-ios-background-publish` green in the **Always** matrix job (OD-P3-c, now mandatory) — publishes continue from a genuinely backgrounded process with NO activity session held, `held == false`, `serviceSessionHeld == true`, `alwaysConfirmed == true`, and ≥ 2 events / 396 s; (2) the same lane green in the **WIU** job with its tier PINNED, so a provisional escalation is a red attributable run rather than a silent branch swap; (3) `e2e-ios-auth-tier` (b7) green with the session-held oracle inverted per tier and the `alwaysConfirmed` read — the tier→policy mapping is what OD1 and OD-P3-b rest on; (4) the Swift/static bundle: `check_ios_background_publish.sh` (checks 2/3/4/7/8/9/11/12/14, `SELF_TEST_FIXTURES` at what lands, including the `allowsBackgroundLocationUpdates = allowsBg` derivation pin and the disarm-unconditional `check_arm_tier_policy`), `check_m7_native_wake_guards.sh` check 13's token scan proving no publish site in the Swift file, and the 13-locale copy ties. Plus the liveness grader (below) run over the lane's own relay capture. **RESIDUAL, stated plainly and not hedged:** the simulator **cannot prove OS suspension** (`M7`'s 2026-08-23 second changelog entry), cannot render the status bar, and cannot run for two hours of stationary wall-clock; so V-P3-3 — "does the confirmed-Always shape, with no activity session and the flag false, keep a foreground-started session delivering for HOURS" — remains **UNKNOWN**, and **the closest physical neighbour of this exact configuration FAILED in the field on 2026-08-20** (`M7`'s 2026-08-20 changelog entry — the failure that motivated the session hardening in the first place). CI can show the shape survives a background transition and keeps publishing for the lane's window; it cannot show it survives an afternoon. See the risk control in **Risks / rollback** below — the change is already behind the background-sharing toggle, so the honest disposition is a staged landing plus owner observation, never a claim that 0a was met |
| WP3-3 | Guards: checks 2/3/4/7/8/9/11/12/14 rewrite, self-test 43, m7 check-10 list + check-13 name, repo-guards comment | after WP3-1+2 | `bash scripts/ci/check_ios_background_publish.sh && … --self-test && bash scripts/ci/check_m7_native_wake_guards.sh && … --self-test` |
| WP3-4 | Copy + l10n: ARB en (base + arrow + bar + limited note) + `@description`s, 12 translators, 12 reviewers with the gating facts and reasoning check, parity, gen-l10n, both copy-tie tests (old-sentence forbidden lists), b7 reason text, non-ARB comments | ∥ WP3-3 | `dart run scripts/ci/arb_parity_check.dart haven/lib/l10n`; `flutter gen-l10n` warning-free; copy-tie tests green |
| WP3-5 | Lanes: bg-publish P1 tier pin + status oracle + P2b bounded profile poll + `_failIfSuspended` text; the Always matrix job (OD-P3-c); b7 session + `alwaysConfirmed` oracles; runner comments; `check_e2e_step_timeout_ordering.sh` derivation for the new job | after WP3-2 | `bash tooling/e2e/ci/run-ios-bg-publish.sh --self-test`; `bash tooling/e2e/ci/run-b7-ios-auth-tier.sh --self-test`; all lanes green on the branch |
| WP3-6 | Docs + manifest: M7 §6 item 0 split into 0a / 0a-provisional / 0b / 0c (all headed DEFERRED, banner kept) + a P3 changelog entry, the FA Unit F amendment (incl. the R2 re-argument and the receive-only-relaunch closure), the stale 1 m sentences, MESH G-10, `CLAUDE.md`, `privacy_invariants.json` (host tests only). **LANDED 2026-09-04.** Three manifest changes: `INV-L-IOS-WAKES-RECEIVE-ONLY` re-stated and re-keyed to ~~`locationSettingsIosCatchUp` + ~~`locationSettingsIosLimitedNote` (the catch-up key deleted unrendered 2026-09-04, CI-R23); NEW `INV-L-IOS-INDICATOR-HONEST`; NEW `INV-L-IOS-PUBLISH-INPUT-BEST-PROFILE-ONLY` (without the un-tested equal-length clause). **No `ratchet_override` — see the correction in the change list above.** | last | `check_privacy_invariants.sh --baseline-ref origin/main`; `--static-only`; floor `geolocator_location_service.dart|85` (measured 87.86 %, 123/140): the iOS branch shrinks → denominator drops → likely RATCHET; `ios_location_source.dart` gets a `--list`-derived row; re-pin from the P3 CI run; Swift is outside lcov |
| — | then full `flutter test`, `cargo test` (unchanged Rust — run anyway), reviewer wave | | |

**Reviewer checklist.** Only-Best: find any path that puts a `hundredMeters` fix — or a Best-profile fix stamped before `bestSince` — into `_lastStreamPosition`, the emitted stream, `lastBestFix`, or the motion trigger (try the first-fix-after-switch race and `lastBestFix` under a profile flip mid-`didUpdateLocations`). Rule 10: find a native `lastBestFix` that survives `onCancel`, a toggle-off pause or logout. Freshness: with the confirm deadline removed, does a stationary user ever publish a coordinate older than 168 s + one delivery? With it, does escalation restart the dwell (no Best/100 m flapping every 84 s in good signal — a confirming fix re-arms it)? Is the 200 m undetected-move bound stated where OD-P3-d is decided? R7: grep for any `startUpdatingLocation()` reachable with `allowsBackgroundLocationUpdates == true` while `applicationState == .background` (incl. the SLC-relaunch and the R1 edge), AND any `getCurrentPosition` reachable from a background-launched process (the `backgrounded` read must be fail-closed); the P1 provider must not `watch` the foreground provider in the running build. Errors: comment the `events(FlutterError(` out and return it instead — the sink test must go red (a returned `FlutterError` is reported, never streamed). Wedge regressions vs FA: both profiles keep `kCLDistanceFilterNone` + ≤ 100 m + `allowsBackgroundLocationUpdates` (16.4 shape); no `pausesLocationUpdatesAutomatically = true` anywhere; Unit C's health tick untouched; Rule 14 untouched. Indicator honesty: under WIU the activity session is created and the flag `true`; under CONFIRMED Always neither; under provisional Always / iOS 17 the WIU posture (gate the activity session on `.authorizedWhenInUse` alone — the tier fixture must fail); a WIU→Always upgrade delivered while backgrounded must NOT invalidate the activity session (the `applicationState` fixture must fail); runtime downgrade with the app backgrounded → next foreground re-arms. Privacy metadata: the switch touches no socket; publish instants unchanged; `raw_accuracy` still skipped; a re-send serialises to the same length; no coordinate reaches a log in Swift or Dart. Copy: every sentence of the four keys against the Swift policy and the settings-page gating (`location_settings_page.dart:158-160,213,298-310`): the base key names no indicator; the arrow/bar sentence is chosen by handler state, never by tier; nothing renders under denied/notDetermined; no "low-power" battery promise, no "›", one noun ("blue location bar"), tier-neutral Settings wording (iOS 15 has no "Privacy & Security" menu); the OD1-declined variant exists; ~~the catch-up sentence is unchanged and pinned by clause (c)~~ (the catch-up key was deleted 2026-09-04, CI-R23; clause (c) now pins the While-In-Use note alone). A11y: the Always card is read by VoiceOver in one paragraph — short sentences, "→" (read aloud) not "›"; the pre-existing gap (no `Semantics` hint on the toggle) is unchanged and noted for ui-ux-reviewer. Test reliability: no real timers in controller tests; the P2b oracle is a bounded poll on the heartbeat pattern, never a single read or a sleep. Guard rot: try each fixture's mutation on the real files; comment the Swift policy line out (anti-vacuity); override `iosLocationSourceProvider` in the drive — check 11 must fail.

**Risks / rollback.** Simulator drip under `HundredMeters` (V-P3-1): if `simctl location set` is not delivered at the 100 m tier, the P2b confirm deadline escalates to Best every 84 s and the bounded poll still observes `hundredMeters` at least once; if the sim never delivers under 100 m at all, the profile oracle moves to a unit-level proof and the lane keeps P1/P2a/P2b/P3 (never a widened window) — a documented downgrade of a runtime oracle, recorded in the lane header if taken. Provisional Always (V-P3-3): the fail-safe policy keeps that cohort on the WIU posture, so keep-alive cannot regress there; the residual is a pill until the second prompt (OD1/OD-P3-b). "Hours stationary at 100 m / no filter keeps the process alive" is I until hardware 0a passes — hence the merge gate. **AMENDED 2026-08-30 (§2.5) — the risk control that does not need hardware.** With 0a deferred, this stays I, and the plan must neither pretend the gate was met nor block a phase the owner wants shipped. The disposition, in order: (1) **it is already behind a toggle** — every path P3 touches runs only while background sharing is ON (`INV-L-BACKGROUND-DISCLOSURE-GATE`; the C4 watcher tears the session down on the false edge), so a user who never enables it is untouched by P3 and a user who did can turn it off and see everything stop — that is the containment, and it exists today; (2) **the fail-safe posture stays fail-safe** — OD-P3-b keeps provisional and iOS-17 Always on the WIU policy (activity session held, pill shown), so the cohort whose authorization the OS treats as WIU keeps the exact object added after the 2026-08-20 failure, and only *confirmed* Always (iOS 18+, second prompt answered, `CLServiceSessionDiagnostic` positively confirming) enters the un-evidenced shape; (3) **land it staged, and say so** — P3 merges on the re-based bundle above, and the un-evidenced half is recorded as an open risk in this plan, in M7 §6 0a (marked DEFERRED, still authoritative) and in FA Unit F, so the next person reads "unproven on a device", not "proven"; (4) **the owner watches their own device when one exists** — the observation is cheap and needs no instrumentation: leave the phone on a desk for an afternoon with sharing on and ask the peer whether the marker aged past 4 minutes. If it did, 0a failed and the confirmed-Always branch reverts to holding the activity session (a one-line change to the tier branch, and the copy already follows the handler's state). **Do NOT** attempt to buy this evidence by widening a lane window, by treating simulator continuity as device continuity, or by adding any in-app reporting (§2.5). Stuck indicator on disarm: cosmetic, reported; §6 0c. Poor-signal indoor steady state: the controller spends up to ≈ 59 % of the time at Best (escalation every 84 s) — no worse than today; measured via the profile-duty column. pbxproj by hand: verified by every iOS build; check 14 pins the four references. Rollback in ONE commit: revert `getLocationStream`'s iOS branch to the geolocator arm (restoring `_streamSettings` iOS arm + `_kIosNoDistanceFilter`), the backgrounded shortcut, the native clear and the session handler's tier branch; the Swift file may stay compiled and unused (nothing subscribes) BUT the manifest symbol/test additions to `INV-L-IOS-WAKES-RECEIVE-ONLY` and the m7 check-10/13 list entries revert with the Dart tests (rule 3 is red if a cited test is deleted while the symbol stays); guards/tests/ARB ×13 (five keys)/copy-tie tests (with their two invariants → override items)/settings-page gating revert with it; b7/bg lanes back to one run. The session handler's arm/disarm contract is untouched by the revert; the WIU pill is honest in both states.

**Acceptance.** CI: all tests above green; `check_ios_background_publish.sh` + `--self-test` (47); `check_m7_native_wake_guards.sh` with the two new files scanned and the log-fixture count pinned; `check_location_access_gate.sh`; `check_privacy_invariants.sh` with no override and no integration-test citation; `l10n-check.yml` (13 locales); `e2e-ios-background-publish` green with the tier-pinned P1, the P2b bounded profile poll (`hundredMeters` observed from the backgrounded process) and ≥ 2 events/396 s, plus the Always job (OD-P3-c); b7 both tiers green with the session-held oracle inverted per tier and `alwaysConfirmed` true under the full grant; `build-check` iOS green; `e2e-ios` / `e2e-ios-real-gps` green. **LIVENESS gate (re-based, 2026-08-30 — §2.5):** the four-part WP3-2 bundle above, plus the grader (exit 0, declared window) over the bg-publish lane's relay capture. ~~publishes on cadence with no relay-side gap > 228 s for ≥ 2 h~~ → for the lane's window, from a genuinely backgrounded process, in BOTH tier jobs. **RESIDUAL:** hours-scale continuity under confirmed Always is UNKNOWN (V-P3-3); OS suspension is not reproducible on the simulator; see the staged risk control in **Risks / rollback**.
**POWER-MEASUREMENT gate (estimate-replaced, §2.5):** ~~Settings › Battery over ≥ 3 h on the same phone: background sharing ≤ ~1 %/h stationary~~ → **ESTIMATED** from model E (§6.5a): the iOS location term falls from ≈ 1.0–1.8 %/h (continuous Best) to ≈ 0.3 %/h in good coverage, and to ≈ 1.0 %/h in coverage poor enough to hold the controller at Best ≈ 59 % of the time — i.e. a 4–6× cut on the location term where the tier actually engages, and near-zero where it does not. The **CI-checkable proxy that must hold**: the lane's P2b bounded profile poll observes `hundredMeters` from the backgrounded process (the tier really is requested and really is honoured by CoreLocation, not just written to a field) and the WIU job's tier pin stays green. What CI does NOT check: how often the escalation fires on a real desk (I-P3-1) and therefore the true profile duty — the split between the 0.3 and the 1.0 figures is unobserved.
**DEFERRED, still authoritative (run when hardware returns):** M7 §6 0a (≥ 2 h stationary under confirmed Always: no blue bar, arrow only, accuracy observed dropping to 100 m within ~2 min in Console, RunningBoard assertion held, no relay-side gap > 228 s, accuracy back to Best on a ≥ 150 m walk), the 0a-provisional row, 0b (WIU: bar visible, publishing continues) and 0c (toggle OFF clears the bar within a minute on iOS 18 and 26). These are marked DEFERRED in M7 §6 by WP3-6 — never deleted, and the ⚠️ RE-RUN REQUIRED banner stays, because a deferred proof is still an owed proof.

**Owner decisions / open questions.** OD1, OD-P3-a/b/c/d. V-P3-1 (sim delivers under `HundredMeters`; I: yes, the sim ignores the tier); V-P3-2 / V-P3-3 / V-P3-4 / V-P3-5 / I-P3-1 — **all five re-tagged NOT AVAILABLE on 2026-08-30 (§2.5, §7.5): there is no iPhone, so 0a and 0a-provisional are DEFERRED and the WP3-2 merge gate is the re-based CI bundle instead.** V-P3-3 is the residual P3 ships with and it is stated in full in **Risks / rollback** above; V-P3-4 costs no liveness because D2 fails safe; V-P3-5 was never actionable (no code mitigation exists, §2.1); I-P3-1 is the largest single source of spread in model E's iOS estimate (§6.5a). V-P3-1 (sim delivers under `HundredMeters`; I: yes, the sim ignores the tier) is unaffected — it is a simulator question and CI still answers it. U: all energy figures — hardware only, and now ESTIMATED via model E (§6.5a).

#### P3 coverage-floor debt — OWED, re-pin from the P3 CI run (2026-09-04)

The full local gate passes (`rust=pass flutter=pass`), but P3 has OUTGROWN three
Flutter floors by ≥ 5 points, which CI's pinned SDK will read as RATCHET
failures:

| manifest line | path | measured | floor | owed |
|---|---|---|---|---|
| 251 | `lib/src/services/` | 70.25 % | 65 | **68** |
| 268 | `lib/src/services/geolocator_location_service.dart` | 90.95 % | 85 | **88** |
| 282 | `lib/src/services/background_location_task.dart` | 87.21 % | 80 | **85** |

§5.3's WP3-6 row predicted the `geolocator_location_service.dart` row exactly —
the iOS branch shrinks, the denominator drops, coverage rises through the floor.

**These CANNOT be re-pinned from a local run** and must not be hand-edited. The
measurement above was taken on Flutter 3.41.0 against the pinned 3.44.8
(`scripts/ci/coverage_toolchain.env`), and the gate says so itself: *"Do NOT
re-pin the manifest from this run: `--repin` needs CI's SDK, or it writes floors
CI cannot satisfy."* A percentage is a ratio whose denominator is a compiler
property. So the first CI run on this branch is EXPECTED to fail these three
rows; the loop is: push → take `coverage.yml`'s Flutter lcov artifact →
`scripts/ci/check_coverage_floors.sh --repin flutter <lcov>` (raises only, never
lowers) → commit the manifest. Guessing the values here would violate the pin
rule (`floor == floor(measured) − 2` on CI's instrument).

Still owed from before P3, same mechanism: the `background_deferred_send.dart`
row.

Re-measured 2026-09-05 after the OD-P3-e cap, the CI-R20/R23 cleanups and the
second l10n wave: the same three rows, same owed floors. Everything else in the
gate is green — `rust=pass flutter=pass`, and the aggregate never moved.

### 5.4 Phase P4 — iOS background burst receive + maintenance fold + bounded inbox lookback (D6) [OD4]

**Goal / non-goals.** While backgrounded on iOS with sharing ON the engine holds NO standing REQ and NO socket
between publish ticks (**QUALIFIED 2026-09-07: read this goal against the "Residuals P4-6 MUST disclose" list
below — it holds of the steady state between two bursts, and TEN named cases sit outside it (the list was
renumbered 2026-09-08: item 2 is resolved, four were added). The unqualified
sentence must never leave §5.4**); each tick is one bounded burst in the main isolate (the `AccountDeviceSession` holder,
Rule 14): open → ingest backlog → publish at the current epoch → fold due maintenance → settle → close. Battery:
≈ 150 → ≈ 30 radio wakes/h for a 1-circle user on cellular (research §3.2). The wake counts are this code's
property; the energy is not. **ESTIMATED (model E, §6.5a — never measured, and the RADIO TERM only, not a device
total): that count change moves the radio term from ≈ 0.5–3.1 %/h to ≈ 0.1–0.6 %/h**, the width being wake
coalescing `c` ∈ [0.15, 1.0] (E-P2). This line quoted "3.1 → 0.65 %/h" until 2026-09-08; that pair was the `c = 1`
endpoint of the same arithmetic, restated to two significant figures as though it were a result. The engine's 55 s
pinger, the 15-min health re-anchor and the 7-day inbox replays leave the background. **Qualified 2026-09-05: the 7-day replay is gone (P1 bounded it), but at the SHIPPED
`INBOX_BURSTS_PER_REQ = 1` a 49-hour inbox replay is issued on EVERY burst — more often, not less, than the pattern
this line implies. See the Privacy metadata statement below and OD4-b.** Non-goals: the foreground (persistent engine unchanged); Android (the FGS already has no engine); per-circle
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
  (F13). `wait_backlog_settled() -> BacklogOutcome { Settled, TimedOut }` (**shipped shape, CORRECTED 2026-09-05: the
  session-level method takes NO timeout — it reads this burst's endpoints and applies `BURST_BACKLOG_WAIT` itself,
  `session.rs:1532`; the `(expected_endpoints, timeout)` signature in the change list below is the PROCESSOR-level
  one**): waits until every expected
  `(relay, sub)` ENDPOINT THIS burst issued AND whose REQ `subscribe_bucket` accepted (it returns the accepted relay set; a burst without an inbox REQ expects no inbox endpoint; the set `probe_subscriptions`/`open_delivery_windows` track,
  `session.rs:430-436`) has EOSE'd or CLOSED, behind a `tokio::sync::Notify` the worker fires per endpoint (no polling)
  — per endpoint, not per circle, because `note_eose(group_hex)` consumes the circle's single generation on the FIRST
  relay's EOSE while a slower relay may still be replaying the peer's commit (F30). **RATIONALE CORRECTED 2026-09-05 —
  per-endpoint settling does NOT close the fast-relay-EOSE hazard, and this sentence read as if it did.** What it
  fixes is delivery TIMING: the burst no longer publishes while a slow relay is still replaying. The CURSOR is still
  per circle, so on a `TimedOut` outcome a burst can still advance past a window a slow relay never served — and,
  unlike the foreground, there is no standing REQ and no later re-request to pick it up: in the background the missed
  window is simply gone until something else re-anchors. **CLOSED IN CODE 2026-09-07 — this paragraph's "being fixed in a separate
  packet" instruction is spent; do not re-derive the caveat from it.** The advance is now gated on `EoseCoverage`
  (`processor.rs`, `note_eose_endpoint`): `anchor_end_of_stored_events` early-returns unless every accepting relay
  answered, so a `TimedOut` burst issues no advance at all rather than advancing past a window a slow relay never
  served. Pinned by `a_burst_that_did_not_settle_every_endpoint_leaves_no_advance_standing` (all three arms: no
  advance while one endpoint is silent, the event is really deliverable, and the advance DOES land once every
  endpoint answers). "Settled per endpoint" is therefore now a cursor-safety property as well as a timing one. Because the worker is serial (F14),
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
  is never cut — Rule 13); a quiet burst pays zero; internal ~~`settle_before_pause_with(window, cap, clock)`~~
  **CORRECTED 2026-09-05: the shipped signature is `settle_before_pause_with(window, cap)` (`session.rs:1571`) — no
  `clock` parameter. It was only ever there to work around F35's claim that tokio is built without `test-util`, and
  F35 was itself stale (see its row in §2): `test-util` IS in `haven-core`'s dev-dependencies (`Cargo.toml:249`), so
  `#[tokio::test(start_paused = true)]` compiles and the window logic is unit-tested on tokio's VIRTUAL clock with no
  injected clock at all (`session.rs:4668`, `:4726`). Do not re-add the parameter.** `paused` gates = D6 (ii): `run_repair` returns BEFORE `take_due` (an early
  return inside `reissue` would consume the pending re-issue, F28; a belt-and-braces `paused` check stays in `reissue`);
  `maintain_subscription_health` short-circuits before `health_probe` → `HealthAction::Paused`; `subscribe_circle`
  while paused = WSS gate → cold-start cursor seed → sub-id → `active` push (no router entry, no REQ, no `add_relay`);
  `unsubscribe_circle` while paused = `active` removal + `forget_subscription(hex)`. `stop` from `Paused`: unchanged
  (`stop_inner` idempotent over a closed pool). After a pause the only Rust tasks alive are the four supervisor tasks
  parked on channels; the crate's per-relay connection task (and its pinger) exits on `Terminated` (`inner.rs:566`) —
  ~~no timer wake remains in Rust~~ **CORRECTED 2026-09-05 (review of the shipped P4-2): no RADIO wake and no
  *periodic* timer remains — but a timer wake can still fire. A repair armed BEFORE the pause keeps its deadline, so
  `run_repair`'s `sleep_until_opt(deadline)` wakes once, up to `BACKOFF_MAX_SECS` (30 s, `config.rs:208`) into the
  pause, sees `paused` and re-parks. CPU only, no socket, at most once per pause. P4-6's SECURITY.md sentence must
  therefore say "no relay traffic between bursts and no periodic wake", never "no timer wake" — the weaker sentence is
  the true one.**
  **LANDED CORRECTION 2026-09-05 — the `paused` gate's PLACEMENT in `run_repair` is load-bearing, and its first
  shipped form busy-spun.** The gate must stay BEFORE `take_due` (F28: `take_due` clears `due_at`, bumps `attempts`
  and arms the next backoff, so an early return below it would CONSUME the pending re-issue rather than defer it) —
  but `next_deadline()` returns a deadline already in the PAST for an entry that is due, so `sleep_until_opt` returned
  immediately and the `paused` `continue` looped straight back into it: one core pinned at 100 % for the entire pause
  (measured 726,416 iterations in a ~2 s test). A battery defect of precisely the class this phase exists to remove,
  inside the phase that removes it — and invisible to every guard, because the source shape the guard checks was
  correct. Fixed in code (separate packet); the correct shape keeps the gate before `take_due` AND parks the task
  while paused instead of re-evaluating a past deadline. Any later edit to this gate must preserve BOTH properties,
  and the phase's own tests must keep a case that fails on a spinning pause.
- **Burst sequence (Dart, main isolate, iOS-bg only)** — `BackgroundBurstCoordinator` (new, FFI-free core + thin runner;
  injectable clock/engine/relay/maintenance/publisher; no `Timer` of its own — ticks come from the schedulers) serialises
  bursts on one chain (a second tick during a burst joins it: its circle is published in the running burst if not yet
  encrypted, else deferred): 1. ~~`engine.resumeAfterBackground()`~~ **`engine.openBackgroundBurst()` — CORRECTED 2026-09-07.** P4-2 split the two entry points: `open_background_burst()` is the BURST entry and takes the `INBOX_BURSTS_PER_REQ` fold decision on a background-only counter, while `resume_after_background()` is the FOREGROUND re-anchor and always carries the inbox REQ at any k. Calling the foreground one here would silently disable OD4-b's mitigation — no error, no failing test. `check_engine_client_options.sh` check 9 pins the FFI delegation; nothing pins the Dart call site. It also THROWS on failure (unlike `resumeAfterBackground`), and a failed open leaves the engine CONNECTED with partial REQs, so the `finally` must settle-and-pause even on the throw path (≤ 5 s connect wait). 2. `engine.waitBacklogSettled()`
  (≤ 5 s) — a received commit is applied so the encrypt runs at the current epoch; a `SelfRemove` auto-commit staged here
  is published over the ENGINE sockets and confirmed only on a ≥ 1-relay OK inside `resolve_publish_work` (F9, Rule 13) —
  inside this burst, on warm sockets. 3. `getCurrentLocation()` once (access gate first) → per due circle `publishLocation`
  (encrypt → `publishLocationEvent`, D5's 15 s worst case) with the P5 stagger; a `LocationPublishDeferred` outcome surfaces
  staged commits exactly as today (`_handleDeferredSend` → `publishEvent` ladder, `confirm_published` on ack) — still inside
  the burst. 4. `if (keyPackageDue) maintainKeyPackage(); if (relayListDue) maintainRelayList();` on the warm publish pool
  (F19) — direct method calls, never provider invalidations; the health tick is NOT folded. 5. `engine.settleBeforePause()`
  (0 s quiet; ≤ 18 + 10 s if a commit moved) → `engine.pauseSubscriptions()` → **an UNBOUNDED commit-critical drain over
  the publish pool (added by P4-5's second HIGH fix, below)** → `relay.shutdown()` on the publish pool,
  **with a `foregrounded` pull re-read before EACH of those links (P4-5's first HIGH fix)**
  (F8 `disconnect`; with D5 the sockets would sleep within ≤ 70 s, but an explicit close ends the radio tail at once — a
  burst costs `0.3 J + (T_burst + 11.6 s) × 1.06 W`, `T_burst` typically 2–4 s → ≈ 15 J, worst ≈ 23 J at the 10 s send
  bound, commit-settle worst ≈ 40 J — all four figures ESTIMATED from the LTE-2012 model, research §4, never measured). Steps 5's pause runs in a `finally` — on a throw AND on cooperative
  cancellation (the chain re-checks `bgEnabled` between links; a C4 cancel in the last seconds before suspension must
  still pause). NO `.timeout(` wraps commit-critical work (`_handleDeferredSend`, `confirmPublished`, and the
  `pauseSubscriptions()` link — its marker drain is bounded by backlog size, not by a clock; the FGS's unbounded
  commit-critical drain is the model); the C6 `.timeout(` check 8 resolves sits on `_dispatchTick`
  (~~`_onCircleTick` → `_dispatchTick` → `sink?.onTick(...) ?? _pacedPublish(...)`~~ **CORRECTED 2026-09-07: that literal shape contradicts an invariant already documented in the file it describes.** One
  `.timeout(` over both branches folds `_pacedPublish`'s decorrelation wait INTO `_publishLinkTimeout`, and
  `_pacedPublish` records why that wait sits OUTSIDE it: a deliberate gap must never read as a hang and
  abandon the link. The shipped shape branches FIRST and wraps only the sink — `if (sink == null) return
  _pacedPublish(...)`, else `sink.onTick(...).timeout(_publishLinkTimeout, onTimeout: report)` — with
  `_pacedPublish` keeping its own inner timeout around `_publishCircle` alone. Two timeouts on two
  branches, never one over both) as a WATCHDOG only — Dart
  `Future.timeout` does not cancel the underlying future, the chain ignores it and it merely reports — with
  ~~`BURST_BOUND` (≤ 5 s connect + 5 s backlog + N × 10 s publish + 28 s settle, pause link excluded) pinned
  `< _publishLinkTimeout` (3 min, `:157`) so a healthy burst is never reported late for N ≤ 12~~
  **RE-SCOPED, NOT ENLARGED — LANDED CORRECTION 2026-09-07; the whole record is in the "burst bound"
  bullet below.** The coordinator and everything it calls while paused use `ref.read` / direct calls /
  `listenManual` only — no `ref.watch` in `background_burst_coordinator.dart` (lint test; §2.2a). Foreground resume:
  `_onResumed` calls `resumeAfterBackground()` behind the 60 s throttle (F18) — bypassed when the engine is `Paused` (a
  paused engine has NO REQ, so "re-queries a window the last one covered" does not apply). Pause: the iOS+bg-ON branch
  (`map_shell.dart:1335-1363`) installs the coordinator, runs an IMMEDIATE first burst if the last publish is older than
  `kLocationPublishOverlapGuard` (else schedules as today), after which the engine is `Paused`. The `_bgSharingPausedSub`
  C4 edge (toggle OFF mid-pause) REQUESTS cooperative cancellation when a burst is running (the current
  commit-critical link confirms or rolls back, then the `finally` pauses and shuts the pool) and, with no burst
  running, calls `pauseSubscriptions()` + `relay.shutdown()` directly — either way opt-out leaves NO socket.
  Status while paused: `SyncConnectionPhase.paused` (no fault; `_disconnectedSince` cleared; the per-relay
  `Reconnecting`/`Connected` churn on each burst is harmless and documented).
  **LANDED CORRECTION 2026-09-07 — the WAIT on a burst in flight was under-derived and expired on HEALTHY
  bursts.** `kOptOutBurstWait` was 38 s, pricing its `pause_subscriptions` term at "the crate's 10 s
  per-relay OK wait" — but that is `wait_for_ok`, a publish primitive, and not the engine's pause at all.
  The pause spends **four** separately bounded `RELAY_LIFECYCLE_OP_TIMEOUT` (10 s) steps —
  `unsubscribe_all`, the leftover-subscription probe, the `RawSignal::Pause` marker send and the worker's
  ack of it — before it even REACHES its uncapped Rule-13 drain. At 38 s the wait therefore timed out on
  healthy bursts and the direct pause ran underneath one: the exact thing the wait exists to avoid. It is
  now **68 s** = 10 (the single-attempt publish the burst may be inside) + 18 (`BURST_SETTLE_CAP_SECS`) +
  40 (the four bounded steps), pinned to the Rust source by `map_shell_burst_wiring_test.dart`. The
  leftover SWEEP's extra per-REQ op and the uncapped drain behind it are deliberately NOT priced — being
  unpriceable is what makes this a BOUND on the wait rather than an await — and both teardown links are
  ISSUED together rather than awaited in sequence, so a wedged engine cannot starve the pool shutdown
  behind it (consent withdrawn, publish sockets open for the life of the process).
- **The burst bound — LANDED CORRECTION 2026-09-07. Four successive values were wrong, and the fix was to
  RE-SCOPE the bound, not to enlarge it.** The record, because the record is the point: this plan said `N ≤ 12`; a
  correction raised it to `N ≤ 14` using the plan's own stagger-less formula; the implementer computed 11 by adding
  the stagger; a reviewer then showed 11 unsound too, because the formula omits the PAUSE while `_closeBurst`
  measured elapsed time THROUGH it — and the pause ends in the engine's `wait_publishes_drained()`, which is
  **uncapped by design** (Security Rule 13). **A bound containing an unbounded term is not a bound**, and no honest
  bound on a WHOLE burst exists. What shipped bounds only the links the burst OWNS —
  `burstBound(circles, stagger)` = `kBurstConnectBudget` (5 s) + `kBurstBacklogBudget` (5 s) +
  `kBurstWindowBudget` (one GPS window, `kOneShotLocationTimeout`) + `kBurstPublishBudget` × circles +
  `burstStaggerSpread(circles)` — and the over-budget stamp is taken BEFORE the maintenance fold and the teardown
  (`_reportOverBudget` in the inner `finally`), so the two unboundable links sit outside both the sum and the
  elapsed time measured against it. Three consequences, each reversing a sentence an earlier draft asserted:
  **(i) the stagger term is JOIN-AWARE** — `Σ maxGapFor(k)` for `k = 2..n`, ≈ 59.9 s at n = 11, not
  `maxSpreadFor`'s 30 s: a burst GROWS (a tick landing mid-pass joins it), so the k-th gap was sampled while only
  k circles were pending, at the wider ceiling that applied then, and pricing every gap at the burst's FINAL size
  understates the spread a joining burst can actually reach.
  **(ii) A HEALTHY burst can exceed the watchdog, and that is not a fault** — the watchdog's entire contract is to
  report and never cancel (cutting a burst short would leave the engine live with standing REQs for the rest of
  the background window, or a commit between SEND and OK). So no `N ≤ …` claim of the retracted kind may be
  restated in any form; where the sum crosses `kPublishLinkTimeout` is pinned behaviourally by
  `background_burst_coordinator_test.dart` (`burstBound(3) < kPublishLinkTimeout < burstBound(12)`), never by a
  number carried in prose.
  **(iii) `kMaxBurstCircles` is DELETED, not tuned.** Enforcing a cap would defer a due circle's location for the
  sake of keeping a log line accurate — trading the user-visible promise for the diagnostic — and the whole-burst
  quantity it claimed to bound does not exist to be capped.
  One constant survives every round unchanged: **`kBurstPublishBudget = 10 s` was right all along**, because
  `LOCATION_PUBLISH_ATTEMPTS == 1` (pinned by a compile-time assert in `haven-core/src/relay/manager.rs`), so 10 s
  is `CONNECTION_TIMEOUT` + `LOCATION_ACK_WINDOW` for the WHOLE ladder. Only its "per attempt" doc was wrong. The
  ≈ 49 s three-attempt ladder belongs to commits and KeyPackages — i.e. to the maintenance fold — which is exactly
  why the fold is excluded.
- **What advances the inbox fold counter — RECORDED 2026-09-07. §5.4 was silent on both halves, and each changes
  what OD4-b's `k` actually buys.**
  **(i) A JOINED tick does not advance it, and cannot.** A tick landing while a burst is joinable returns the
  running burst's chain and issues no REQ of its own; the fold decision is taken in Rust, once, inside
  `open_background_burst` → `resume_burst`, which a joined tick never reaches. So `k` counts BURSTS, not publish
  ticks — which is what OD4-b intends, but it was never written down and the obvious reading ("every k-th tick")
  is wrong for any multi-circle user.
  **(ii) A burst that FAILS TO OPEN still consumes a fold position.** `background_bursts.fetch_add(1, …)` runs
  ahead of BOTH post-connect failure exits — the `shutdown` re-check after `wait_for_connection`, and a failing
  `register_and_subscribe` — so the position is spent whether or not any REQ was issued. Consequence at `k > 1`: a
  failed open both skips the inbox REQ it might have carried AND pushes the next one out by another `k` intervals,
  so the worst-case gap between inbox REQs is `2k − 1` intervals, not `k`. OD4-b's "≤ 10 min invitation latency"
  does not price that today, and it must be re-derived when `k` is raised.
- **A failed engine open still PUBLISHES — decision recorded 2026-09-07; §5.4 never stated it.** On a throw from
  `openBackgroundBurst()` the coordinator skips the backlog wait (waiting on a backlog nobody requested spends the
  whole budget learning nothing) and still runs the publish pass. Sound, for reasons worth writing down rather
  than rediscovering: the publish pool is a genuinely separate `Client`, so a dead engine open costs the publish
  path nothing; and a location encrypted one epoch behind IS decryptable by peers — the outer ChaCha20 layer peels
  from the retained-anchor snapshot, the kind-445 nonce is CSPRNG per message (Rule 11, socket-independent), and
  application messages advance no epoch, so `Buffered` — the FUTURE-epoch verdict — is not what a one-behind
  message hits. **The residual, named:** a PERSISTENT open failure compounds. Once more than the engine's retained
  past epochs' worth of peer commits have gone un-ingested, this device's kind-445s become undecryptable to every
  peer — silently, while relay acks keep coming back on this side and peers' markers freeze. So a RUN of failed
  opens is evidence, not noise: a consecutive-failed-open counter (reset to `0` by any success) now feeds the
  receive-plane signals of the sharing-health model, the way a refused GPS window does, instead of dying in a
  `debugPrint`.
- **The paused-session socket strand — LANDED CORRECTION 2026-09-07. A confirmed upstream defect, reproduced on
  the wire, that made "no socket between bursts" false for entire inter-burst gaps.** `nostr-relay-pool` 0.44.3's
  `InnerRelay::disconnect` fires its termination notify BEFORE it stores `Terminated`, and that notify is a
  `Notify::notify_one` — one permit, not a latch. A connection task woken inside that gap finishes its close,
  re-reads a status the store has not yet landed on, concludes it was not terminated, marks the relay
  `Disconnected` and sleeps its retry interval — with the one permit that could have broken that sleep already
  spent. Ten seconds later it opens a **real socket**, holds it alive with the crate's 55 s ping indefinitely with
  no REQ on it, and the next burst silently ADOPTS it (`rebuild_stalled_relays` skips `Connected` by design and
  `connect()` is a no-op on it), so the leak is invisible from inside the engine. Measured **48/150** disconnects
  on a multi-threaded runtime under 2× oversubscription, **0/150** on `current_thread`, 0/300 on an idle host: the
  window is the parallel gap between two adjacent statements, which makes it a property of the machine — and a
  backgrounded phone is the loaded case permanently. That is also why no test here waits for it to FIRE; one that
  did would assert nothing on an idle runner. **Haven cannot make it impossible** — the race is inside a pinned
  crate — so the phase guarantees instead that none SURVIVES: `terminate_all_relays()` re-asserts `disconnect()`
  until the pool proves quiet (bounded, and holding no timer: each round yields once, because convergence is
  decided by a status read and never by a clock, and the uncapped Rule-13 gauge wait ahead of it means nothing
  after it may wait on the clock), and only once it returns does `radio_off` go up — arming `run_monitor`'s watch
  to CUT and COUNT any relay that comes up while the radio is off, and never to REPORT it as connectivity, which
  would have the health model clear its "disconnected since" stamp on the strength of a socket the engine did not
  open. **Worth filing upstream:** swapping the two statements closes it, and upstream fixed the sibling defect
  deliberately in v0.37.0.
- **Why the WATCH, not the re-assert, is the guarantee — recorded 2026-09-07.** There is a SECOND strand shape the
  re-assert loop's fingerprint cannot see: the interleaving in which the task's `Disconnected` write lands BEFORE
  the pool's `Terminated` store. That relay reads as correctly terminated to `unterminated_relay_count()`, so the
  loop converges and returns — and the task still re-connects a retry interval later. The bounded loop is a repair
  for the shape it CAN see; the radio-off watch is what makes the pause a closed loop rather than a probabilistic
  one, and it is the backstop the promise actually rests on. Do not re-describe the re-assert as the guarantee.
- **Two HIGH defects P4-5 introduced and closed — LANDED CORRECTION 2026-09-07.**
  **(i) A resume landing MID-BURST left the engine paused IN THE FOREGROUND.** The teardown read the world once at
  the top, so a resume between the settle and the pause let the pause run anyway, underneath a foreground that had
  already taken the engine back — and nothing recovers that: `ensureRunning` reads `isRunning` (true across a
  pause), `_fullRestart` declines while paused, and `SharingHealthNotifier.refresh()` early-returns while paused,
  so the banner holds at "healthy" while the device receives NOTHING until the next background→foreground cycle.
  Fixed with a `foregrounded` PULL re-read before EACH teardown link (`_handedBack`), never once at the top and
  never as a latch: one coordinator serves every pause of a mount, so a flag that only ever went true would leave
  every burst after the first resume holding its sockets for the whole background window — strictly worse than the
  defect it closes. The publish PASS is deliberately NOT gated the same way; stopping mid-pass would silently skip
  circles whose locations are due, where stopping the teardown only leaves the foreground owning what it already
  owns.
  **(ii) The end-of-burst publish-pool shutdown could cut a commit between SEND and OK (Rule 13).** The pool is not
  the burst's: the motion trigger keeps running while backgrounded on iOS and publishes over the same pool,
  unawaited by and invisible to the coordinator, and that path reaches the deferred-send ladder while
  `shutdownPublishPool` disconnects with no drain of any kind — so a commit mid-ladder loses its ack and is rolled
  back on a relay that may already have stored and served it. Fixed with an UNBOUNDED drain before the shutdown
  (bounding it would be the same defect, since a `.timeout(` cancels no Rust future — it only returns here and
  lets the socket be cut underneath the commit), fed by a new commit-critical registry in `LocationSharingService`
  (`inFlightCommitCritical`) and re-read after each round, because the trigger can start a ladder INSIDE one.
  Rounds after the first are capped at three: the trigger publishes at most once per `kLocationPublishOverlapGuard`
  (60 s), so a fourth adopted ladder means the registry is answering with something other than the work in flight,
  and without the cap a registry that manufactures a future per read spins here forever — no burst ever completes
  again, both pools stay open, background sharing ends for the process, and the only trace is one log line
  repeating. The cap bounds nothing the drain promises: the ladder in flight when the pool would have been shut is
  always awaited to its own conclusion.
- **Two items owed, recorded 2026-09-07 rather than left implicit.**
  **(i)** `trackCommitCriticalForTest` is a test-only entry point now standing on `LocationSharingService`'s
  PUBLIC surface — the price of making the Rule-13 drain testable without the Rust bridge. It is not a stub and
  not dead code (it pushes through the same `_awaitCommitCritical` registration the production call sites use),
  but it is production API that exists for a test, and it is owed a revisit if the service ever gains a seam that
  does not need it.
  **(ii) The coordinator's JOIN branch is now a genuine redundancy, and no test distinguishes it.** After the
  refused-window drain landed — `_publishPass` clears `_due` on a device-level refusal, and `_runBurst`
  early-returns on an empty `_due` as "drained by the burst this one queued behind" — a tick that JOINS a running
  burst and a tick that QUEUES BEHIND one are observationally identical: the drain removed the observable the old
  tests relied on. Both paths were kept deliberately (the join is the cheaper and more honest expression of
  "publish this circle in the burst already running"), and the gap is reported HERE rather than papered over with
  a proxy assertion that would pass for the wrong reason.
- **P4-7's lane oracle, and three things §5.4 got wrong about it — LANDED CORRECTION 2026-09-08.**
  **(i) `isPaused` is not an oracle, and this section specified it twice.** The "Existing red → replacement" line
  above asks P2c to "bounded-poll `subscriptionService.isPaused == true` between ticks", and the Acceptance paragraph
  repeats it. It cannot carry the claim: the core raises `paused` as the FIRST statement of `pause_subscriptions`,
  before `unsubscribe_all`, before the router drain, before the uncapped Rule-13 publish gauge and before
  `disconnect()`, so it reads `true` through a pause that dropped no REQ, one still draining and one whose disconnect
  never happened — every state P2c exists to catch. It also reads `false` for a failed FFI read and for "there is no
  session". What landed reads `pool_subscription_count()` instead (`LiveSyncFfi`, exposed by P4-2 and until now
  consumed by nothing in Dart), through a new pass-through on `NostrSubscriptionService` — deliberately NOT on the
  `SubscriptionService` interface, since no production caller decides anything from it and the two that read
  `isPaused` must keep reading that. It THROWS with no session rather than answering `0`, because zero is the value
  the promise is kept by. Paired with a **control arm**: the same counter read non-zero while foregrounded, before the
  backgrounding, so a counter that could only ever read zero cannot prove the promise for free. `check_ios_background_publish.sh`
  check 12 now pins all four halves (the count is read, `isPaused` is not — over a string-stripped view, so the
  drive's own prose about the flag cannot trip its own ban — the `> 0` control exists, the `== 0` wait exists, and the
  terminal marker is printed after it).
  **(ii) The lane could not host P2c at all as it stood: it ran `HAVEN_LIVE_SYNC: "false"`.** With the receive engine
  compiled out there is no session to hold — or not hold — a subscription, and every burst's open fails into the
  coordinator's failed-open branch, so P2a/P2b were measuring a degenerate burst: the publish half of a mechanism
  whose ingest half no lane exercised under a real backgrounding. The lane now compiles it IN, which is also the app's
  own default. The cost is named rather than absorbed: no lane now puts the POLL configuration of the iOS background
  branch through a real OS backgrounding. ~~(it is the rollback path of a flag that defaults on, its receive timer is
  pinned by guard check 6, and the iOS core-flow lane still runs both variants)~~ **CORRECTED 2026-09-08 — the middle
  clause was FALSE, and it was the clause doing the work.** `check_ios_background_publish.sh` check 6 pins the C4
  disable-while-paused watcher (`shouldKeepPublishingWhilePaused` is still called, `_bgSharingPausedSub =
  ref.listenManual<bool>(backgroundSharingProvider` is still installed) plus a NEGATIVE — that
  `_startIosBackgroundReceiveTimer`'s body installs no `listenManual` of its own, itself wrapped in `if [[ -n
  "$receive_timer_body" ]]`. Mutation-tested: deleting `_startIosBackgroundReceiveTimer` **entirely** leaves check 6
  passing. Nothing in the repo pins that the poll path's background receive timer exists, fires, or reaches
  `_runBackgroundCatchUp` → `runCatchup(isBackgroundWake: true)`. And the coverage really is gone rather than moved:
  `OVERLAY_BUNDLE_ID` / `com.apple.Preferences` occur in this lane and nowhere else, so it is the only real-OS
  backgrounding on iOS in the repo, and `e2e-ios` exercises the poll path FOREGROUNDED. What survives of the original
  sentence is only its first and last clauses — the configuration is the rollback path of a flag that defaults on, and
  the core-flow lane still runs both variants foregrounded. ~~**The flag-off iOS background branch is therefore
  UNCOVERED, with no compensating control**~~ — **true when written on 2026-09-08 and NOT TRUE from 2026-09-09; the
  closure is two sentences down** — and this was recorded as an owner decision (**OD4-d**, §4) rather than
  written off — **and that decision was TAKEN on 2026-09-09: the coverage is bought back with a second matrix leg on
  `when-in-use` only, `HAVEN_LIVE_SYNC: "false"`, running P1/P2a/P2b/P3 and skipping P2c, one extra ~65-minute macOS
  job (L-122)** — that being the COSTING, and both of those last two details changed in the build.
  ~~The branch stays UNCOVERED until that leg is green, and a static existence pin in check 6 is a
  complement that may never be cited as the runtime coverage~~: a substitute justification inside the argument that licenses a coverage reduction is worse than the
  reduction. **CLOSED THE SAME DAY — the leg LANDED, so the "stays UNCOVERED" clause above is history and the
  costing in the sentence before it is wrong in two places.** As shipped it is a THIRD leg of a three-leg matrix
  (`when-in-use-live-sync`, `always-live-sync`, `when-in-use-poll`, `leg` being the per-job identity and no
  `(always, poll)` combination by design — L-126), it costs **~62 minutes and not ~65** (the poll drive's `Timeout`
  is 37 min, not 40, because P2d costs 362 s where P2c costs 490 — L-129), and it does **not skip** P2c: the drive
  branches on the compiled `liveSyncEnabled` and runs **P2d** instead (L-128), so nothing is skipped and no
  undeclared-skip row was needed. P2d proves the poll path's background branch end to end — a peer publishes while
  Alice is OS-backgrounded, **no tick is driven**, and `MapShell._startIosBackgroundReceiveTimer`'s 90 s
  `Timer.periodic` → `_runBackgroundCatchUp()` → `CatchupService.runCatchup(isBackgroundWake: true)` must land that
  peer's coordinates in the PERSISTED last-known store against a pre-publish baseline — and new guard **check 16**
  pins the product's 90 s cadence to the drive's `_pollPathReceiveInterval` (L-130). **The retraction itself is
  UNCHANGED: check 6 still does not stand in for any of this; check 16 and P2d are what do.** The leg's own ceiling
  (no burst plane, no C3 chokepoint, no jetsam kill, no SLC relaunch, no hours — ONE real backgrounding on a
  simulator that cannot be suspended like a phone) is stated in §4's OD4-d row and in the lane header, and
  `docs/M7_BACKGROUND_SHARING.md` §6 item 0/0a stays DEFERRED regardless.
  `e2e-ios-background-publish.yml`'s "What this lane does NOT prove" carries the retraction, and since the leg
  landed it carries the poll leg's own ceiling beside it. The claim had a
  THIRD carrier — the drive target's own library doc (`haven/integration_test/ios_bg_publish_test.dart`) — and
  **it has since been retracted there too: RE-VERIFIED 2026-09-08, that doc now carries the retraction in OD4-d's
  own terms** ("deleting the method outright leaves check 6 green, verified by mutation"), so **all three carriers
  state the retraction and no site contradicts another.** The earlier wording here — "must be retracted there too;
  until it is, HEAD contradicts itself" — was wrong twice over once P4-7 was read against the working tree rather
  than the index: HEAD asserts nothing either way, because the whole P4-7 packet is uncommitted and HEAD carries
  neither the claim nor the retraction.
  **(iii) "C7" is a wrapper SELF-TEST FIXTURE, not a risk-register row.** `run-ios-bg-publish.sh --self-test` grades
  its completion gate with fixtures labelled C1–C6, and the P4-7 row's "shell fixture C7 for the missing marker" is
  the next in that series: a log carrying every other terminal proof but not `BACKGROUND_RECEIVE_OK` must be REFUSED.
  It landed as exactly that. The collision with §6.3's FA wedge causes C1–C6 is a coincidence and has already cost one
  reader a search; §6.3 needs no C7 row, because the wedge P4 adds (a burst killed mid-publish) is recorded in its C5
  cell as a sub-case pointing at OD4-c — ~~uncovered~~ **covered on the burst plane, and detectable on every
  other plane, since 2026-09-09, with what the control does NOT remove stated in the same cell (L-133, L-134)**.
  **What P2c does NOT prove, stated because a green will be over-read otherwise:** that no SOCKET is open between
  bursts. The count is of subscriptions, not connections; the iOS lane runs `tooling/e2e/local-relay`, which journals
  no REQ/CLOSE frames (the recording wire proxy that would is started by the core-flow lanes, not by this one); and
  WS Ping/Pong is invisible to both.
  The socket half stays where it already is — `live_sync_burst_e2e.rs`, on `relay_health()`.
  ~~**Budgets re-derived, not bumped.** P2c's own phases (peer publish ≤ 15 s, the driven burst priced at
  `burstBound(1)` 50 s + the teardown a burst still owes 58 s, the member-cache poll 30 s, the between-bursts poll
  `burstBound(1)` + `kOptOutBurstWait` = 118 s, plus two heartbeat drains) and P2a's tick await becoming a whole burst
  take the backgrounded phase from 655 s to 1050 s, so `DISABLE_WAIT_SECS` goes 900 → **1440** at the same ~37 % margin
  the old budget carried.~~ **RE-DERIVED AGAIN 2026-09-08 — the 1050 s sum priced two terms that are not bounds, and
  the ~37 % margin was an accident the reasoning did not contain.** Two corrections, each independent:
  **(a) an awaited tick is bounded by `kPublishLinkTimeout` (180 s), not by `burstBound(1) + kOptOutBurstWait`
  (108 s).** P2a and P2c both `await triggerTickForTest`, which returns the scheduler's FIFO `_publishChain`, and
  `_dispatchTick` wraps each link in `.timeout(kPublishLinkTimeout)`. `burstBound`'s own doc says the maintenance fold
  and the teardown are outside it and that "no bound on a whole burst exists"; `kOptOutBurstWait`'s says the Rule-13
  drain is deliberately unpriced. Unpriceability is a good argument for a bound on an in-app wait and no argument at
  all for omitting a term from a CI wall clock, which elapses whether or not anyone can price it.
  **(b) the P2c peer publish is ≤ 112 s, not ≤ 15 s.** `TestRelay.publishAndAwaitOk` is wrapped in
  `_reissuingAcrossReconnect`, which runs `_maxReconnectAttempts` (3) re-issues **plus a final attempt** = 4, each able
  to spend `_awaitWritable`'s `_reconnectBudget` (`1 + Σ_{k<3}(2^k + 5)` = 23 s) before its 5 s OK wait: 4 × 28.
  **(c) P2a gained a term after the first re-derivation** (drive-side re-derivation, same day): `MapShell._onPaused`
  drives a burst SYNCHRONOUSLY inside the lifecycle dispatch, before the drive's 250 ms poll has seen the pause, so an
  anchor taken at the transition lets that burst satisfy P2a's collect and the tick P2a drives goes unasserted. The
  drive now waits it out first — `burstBound(1)` 50 + `_relayObservationSlack` 15 = 65 s, plus a heartbeat drain and
  two `_anchorAfterCurrentSecond` spins.
  The corrected sum, every term citing the constant that enforces it: paused-transition poll 180
  (`_pausedTransitionWindow`) + P2a 65 + 20 + 2 (pause-burst wait, drain, anchors) + 180 (`kPublishLinkTimeout`) +
  P2b 396 (`_postBackgroundPublishWindow`) + 20 (`_heartbeatInterval`) + 1 (anchor) + P2c 112 + 180 + 55
  (`_peerFixWindow` + a `_statusPollInterval` + a drain) + 143 (`burstBound(1)` 50 + `kOptOutBurstWait` 68 + a poll
  interval + a drain) + P3 baseline 15 (`_snapshotFetchWindow`) = **1369 s**. The 143 s term is now a CEILING on
  retries rather than a window the phase spends: the between-bursts poll takes `decideOnFirstAnswer`, so it ends on
  the engine's first ANSWER and only a read that keeps THROWING can reach the deadline.
  **1440 survives — by ~5 %, not ~37 % and not the ~12 % of the first re-derivation** — and it is left there rather
  than inflated, for a reason the earlier text did not have: the deadline is bounded from ABOVE as well as below, and
  the two bounds are ~100 s apart. Below, the 1369 s sum. Above, the drive's own `Timeout(40 min)`, which on the
  measured shape is spent ~515 s before the backgrounding (setup + P1) and ~410 s after the disable (settle +
  snapshot + disarm poll + teardown), leaving **~1475 s** for this window — so a larger `DISABLE_WAIT_SECS` is
  unreachable, the drive dies first, `bgp_wait_until` reports "the drive exited" and its rc is collected, which is the
  better red because the drive's Timeout names the failing test and this deadline names nothing. The sum is still not
  a worst case and cannot be made one (`_publishChain` has no enforced DEPTH, so each awaited tick is priced for one
  link and a queued link costs another 180 s → 1549 s), but 1549 s is past that ~1475 s ceiling too. Exceeding the
  deadline is not a kill either: the wrapper WARNs and falls through to the DISARM wait, so the re-foreground — the
  thing that would corrupt P3, by leaving it measuring a foregrounded app that keeps publishing — is at 1650 s, past
  the drive's own ceiling. Undersizing costs attribution, never a false green.
  `DISARM_WAIT_SECS` is UNCHANGED and independently re-checked twice: P2c runs entirely before the disable, so it
  moves when the DISABLED signal arrives and nothing about the window after it — both its bounds are still the drive's
  200 s settle window and the 228 s kind-445 expiration. The drive's own `Timeout` goes 30 → 40 min; its worst-case
  phase sum re-derived on (a), (b) and (c) is ≈ 38 min (~2280 s), i.e. **~5 % of headroom, not the ~20 % "≈ 32 min"
  implied** — thin, and deliberately not spent, because both `kPublishLinkTimeout` terms are WATCHDOG exits that a
  healthy localhost burst never approaches — and
  because that Timeout is the innermost bound the retry deadline must clear build + rebuild + attach + 40 + teardown:
  45 → **65** min/attempt, step 95 → **135**. That 22 min of fixed overhead was documented on both sides and enforced
  by nothing (`check_e2e_step_timeout_ordering.sh` deliberately excludes harness-internal values), so it is now
  `check_ios_background_publish.sh` **check 15**, which reads the drive's `Timeout` and the workflow's
  `timeout_minutes` and refuses a raise of either alone. The job cap goes 115 → ~~155~~ **175**: 155 could not hold,
  by the lane header's own numbers — six uncapped setup steps sized at 10–15 m, then boot 15 + drive 135 = 150, then
  the uncapped `log collect` and `.logarchive` upload, i.e. a 160–165 m worst case under a 155 m cap, which is the one
  ordering the guard exists to forbid (a job-cap SIGKILL skips every `if: always()` diagnostic). The shape was
  pre-existing (10–15 + 15 + 95 = 120–125 > 115) and `check_e2e_step_timeout_ordering.sh` cannot see it — its C3
  compares one step to the job, never the sum — so the arithmetic is now written out in the workflow beside the
  number. Still ordered as that guard requires.
- **Bounded inbox lookback** = D6 (iv), landed in P1 (P1-N0); P4 relies on it and adds OD4-b's k-th-burst inbox fold.
- **Marmot safety across socket close/open:** the `AccountDeviceSession` never closes; epoch state, sender ratchet and
  exporter secrets are untouched by socket lifecycle (sockets in the nostr `Client`, MLS state in `SessionManager`,
  `MARMOT_PROTOCOL_KNOWLEDGE.md:733-762` (re-pointed 2026-09-05, same reason)); no second session (Rule 14, `check_mls_session_single_owner.sh`); every burst
  sends at the ratchet's next generation; ~~`DEFAULT_MAX_PAST_EPOCHS = 5` is consumed only on real offline gaps and the
  ≤ 168 s inter-burst gap is far inside it (Rule 5)~~ **CORRECTED 2026-09-05 — a category error: `max_past_epochs` is
  an epoch COUNT, and a time gap consumes nothing. What consumes the window is the number of COMMITS between a
  message's epoch and the receiver's tip, however fast or slow they arrived. The conclusion survives, on the right
  reason: a device that bursts every 72–168 s ingests each burst's commits inside that burst, so it can fall behind by
  at most one burst's worth of commits — nowhere near 5 — and a long offline gap is dangerous because of the COMMITS
  it accumulates, not because of its duration (Rule 5). SECOND CONSTANT, unpinned, found by the same review: a peer
  decrypting a one-epoch-behind kind-445's OUTER ChaCha20 layer does not run on `max_past_epochs` at all — it runs on
  the retained-anchor snapshot fallback, whose horizon is `ConvergencePolicy::max_rewind_commits` (default 5,
  `cgka-engine/src/convergence.rs:15,24` at the pinned rev `e391adc`). `security_rule_gates.rs` pins
  `DEFAULT_MAX_PAST_EPOCHS == 5` and `app_message_past_epoch_limit() == 5` (`:380-392`) but NOT `max_rewind_commits`,
  so an upstream default change would silently break past-epoch OUTER peel — the exact mechanism the sentence below
  relies on — with nothing going red. Extending that gate to pin `max_rewind_commits` is OWED (separate packet).**
  A commit received in a burst is applied before encrypt; if the wait
  times out (or a slow relay's replay lands after the fast relay's EOSE — now bounded per endpoint) the encrypt may run one
  epoch behind — peers DECRYPT it from past-epoch keys (`wire_format.rs:52-57`; `Buffered` is the FUTURE-epoch verdict) and
  convergence resolves it on the next burst — never a nonce reuse (Rule 11 gate is socket-independent). A commit Haven
  must publish is acked inside the burst or rolled back (`publish_then_resolve`; `settle_before_pause` holds the socket
  until the in-flight gauge is zero; `publish_failed` restores `Stable`) — the pause can never cut a commit between SEND
  and OK; ~~`PendingCommitRecovered` (crash mid-burst) → the next burst's full re-REQ IS the mandatory resync~~
  **FALSE — CORRECTED 2026-09-05 (Marmot review against the pinned MDK v0.9.4 checkout, rev `e391adc`). The claim is
  wrong in two independent ways, and each alone defeats it.**
  **(a) The re-fetched own commit comes back TERMINAL, so the re-REQ resyncs nothing.** A durable `MessageRecord` in
  state `MessageState::Sent` maps to `IngestOutcome::Stale { reason: OwnEcho }`
  (`cgka-engine/src/message_processor/store.rs:24-27`), and `recorded_message_outcome` is consulted FIRST in
  `do_ingest`, before any MLS processing (`message_processor/ingest.rs:417-420`). The row is written at STAGE time and
  is not rewritten on rollback. So the next burst re-downloads the exact commit bytes and discards them without
  applying: the device stays at epoch N while peers are at N+1, and subsequent peer commits at source-epoch N+1 buffer
  and cannot chain. ~~Real recovery needs the epoch-gap-backfill train (upstream #825 / #877 / #892), which is in MDK
  master and **NOT in the v0.9.4 pin** — already recorded at `MARMOT_PROTOCOL_KNOWLEDGE.md:57-59`.~~
  **CORRECTED 2026-09-05: the train SHIPPED (v0.9.5) and is STILL out of reach.** #825 and #892 land outside Haven's
  five pinned crates — #892 touches none of them — and #825's policy type lives in `marmot-app`, which the manifest
  and `check_mdk_supply_chain.sh` both reject. **No MDK tag on the ladder up to v0.9.18 brings this fix into Haven's
  graph** (§5.7 P4M, central finding), so "wait for the bump" is not a recovery plan and never was one; the recovery
  has to be Haven-side or accepted. The Haven-side fix for the burst cursor hole is therefore NOT duplicated work
  and must not be paused pending an upstream release.
  **(b) For the case a burst actually creates, `PendingCommitRecovered` is never emitted at all.** Crash recovery is
  deliberately scoped to staged commits that remove NO member: `staged_removes_member` matching
  `Proposal::Remove | Proposal::SelfRemove` short-circuits the whole emit block (`cgka-engine/src/engine.rs:820-828`,
  with the upstream comment explaining why — rolling back a removal would re-add the departed member and fork
  convergence). A peer `SelfRemove` auto-commit — exactly what `resolve_publish_work` stages inside EVERY burst — is
  removal-bearing. Killed mid-publish it survives on disk with no `PendingStateRef`; hydrate emits nothing; the epoch
  manager records the record's already-advanced epoch while the MLS group sits one epoch lower with a stuck
  `PendingCommit`.
  **Both behaviours predate P4 and neither is P4's defect. What P4 changes is EXPOSURE**: the phase's whole premise is
  a process iOS may kill between bursts, and every burst that ingests a peer `SelfRemove` opens a publish-before-apply
  window. **No test covers either branch today, and the Rule-13 source gate would stay green through both** — the gate
  proves Haven never confirms before an ack, not that the engine recovers after a kill.
  ~~**The Haven-side control is an OPEN OWNER DECISION — OD4-c in §4 (added 2026-09-05).** Two honest options were
  named, and this plan deliberately does NOT pick one:~~ **DECIDED BY THE OWNER 2026-09-09 — the Haven-side control
  is BOTH halves, and its RUST half LANDED the same day (§4 OD4-c, L-121, L-133).** **(iv)** keep removal-bearing auto-commits OUT of background
  bursts, which removes the route every burst can hit — the peer `SelfRemove` auto-commit `resolve_publish_work`
  stages inside a burst, i.e. the removal-bearing mechanism hydrate never emits `PendingCommitRecovered` for.
  **As it LANDED, (iv) PARKS the commit rather than rolling it back, and that choice is load-bearing rather than
  stylistic: at the pinned rev `e391adc` a bare rollback is a PERMANENT, SILENT DROP of the removal** — verified at
  source and through the real engine — **because the engine removes its in-memory
  `scheduled_self_remove_auto_commits` entry BEFORE staging, `do_publish_failed` does not re-arm it, and a
  redelivery of the leaver's proposal short-circuits to `Buffered` off its durable `MessageState::Created` record
  without rescheduling (the leaver's own re-proposal is gated on the epoch having moved). The peer who asked to
  leave would stay in the circle, deriving its keys, until some unrelated commit moved the epoch.** So the commit
  stays staged and the device owes its publish: `CircleManager::defer_removal_commit` writes the durable
  `deferred_removal_commits` row FIRST and only then parks the commit in memory, so a crash between the two leaves
  the state that REPORTS itself rather than the state that hides; a park that cannot be recorded at all — no
  `nostr_group_id` on the commit event, no circle row for it, or a failed durable write — hands the commit back to
  the normal Rule-13 ladder, because a deferral nobody can redeem is worse than a publish.
  **AND (i)** surface the stuck state that survives (iv) as a `GroupUnrecoverable`-class
  status and force a re-invite — **not optional: a user who believes they are sharing and is not is a SAFETY failure,
  not a UX one, and this wedge is silent, so silence is the worse half and (iv) alone would leave it.** **(iii) —
  accept it as a bare residual — was EXPLICITLY REJECTED.** ~~(ii) make a bump to a released MDK tag containing the epoch-gap backfill a P4
  PRECONDITION~~ — **(ii) is DEAD as of 2026-09-05 (the fix is unreachable at every tag; §5.7)**, ~~leaving (i) or an
  explicitly accepted, named residual~~ **and what it left is settled above: (iv) AND (i), with the residual option
  (iii) rejected.** *That last parenthetical is one of the sites §9.9 flags as still carrying the
  inference L-93 superseded — the narrow fact is that the #825/#892 backfill is unreachable, not that no bump fixes
  OD4-c; it belongs to the packet that owns those sites, and it changes nothing today, because L-124 blocks any bump
  on the untagged-OpenMLS anchor regardless.* ~~**Until (iv) and (i) LAND, no P4 text may describe a crash mid-burst as
  self-healing — the decision does not close this gap, the code does.**~~ **BOTH LANDED 2026-09-09 (L-133), and the
  rule survives them in a NARROWER form, because nothing about the ENGINE changed: no P4 text may describe a crash
  mid-burst as self-healing, and a group already wedged stays wedged. What changed is that a background burst no
  longer opens the window at all — the eviction is parked and published by the next FOREGROUND open, which is also
  the only place a parked commit is redeemed, deliberately NOT `start`, because `start` cannot tell a foreground
  launch from a background wake that cold-launched the process — and that a wedged group is now NAMED as
  `LiveSyncEvent::GroupUnrecoverable`, per circle, instead of flattened into the per-event, self-clearing
  `SyncStatusReason::Unprocessable` that named none. Three things survive the control and each must keep being
  stated: while a parked eviction stands, that circle's `encrypt_location` fails the engine's "send requires
  Stable" gate until the next foreground open (a real per-circle gap in sharing on a rarely-foregrounded device,
  surfaced to nobody); the Android background catch-up sweep still publishes a removal-bearing auto-commit through
  the unconditional resolver (`catchup.rs`) — a FINDING rather than an argument since 2026-09-09, recorded at that
  call site and asserted by tests, because a park needs somewhere to be redeemed and a `PendingStateRef` is valid
  only inside the session that staged it; what the sweep pays instead are the two guarantees that are now
  TREE-WIDE at the one rung all four planes share, no rollback of a removal-bearing commit
  (`CircleManager::publish_failed`) and a write-ahead record of the obligation
  (`CircleManager::owe_removal_publish`); ~~and (i) is HALF built — nothing consumes the verdict, so the user is
  still not told~~ **and (i) is now FULLY built (L-134): the status handler reads the verdict, marks the circle
  blocked, and the banner names it and offers the re-create, announced on the SECOND foreground open by a
  two-observation debounce keyed to re-anchor generations. What is NOT closed is redemption ACROSS a session —
  the live `PendingStateRef`s die with their isolate and hydrate short-circuits on `staged_removes_member`, so an
  obligation the foreground service or the WorkManager worker recorded is REPORTED and never published: loud and
  terminal, repaired by re-creating the circle, which is strictly better than the silent permanent drop it
  replaced and is not a heal**.** Rule 12:
  intake unchanged (`WORKER_QUEUE_CAP` + hold-back); local processing outlasts the SOCKET but not the pause — the `Pause`
  marker guarantees everything downloaded is processed before the router clears (CPU, not radio). R14: no standing REQ
  ⇒ nothing to heal; a `CLOSED` inside a burst is repaired inside it or by the next; the C3 blackout class cannot persist
  longer than one publish interval in the background.
- **Privacy metadata statement** (for SECURITY.md / M11 §6.1): while backgrounded on iOS with sharing on,
  Haven connects only at the instants it publishes its own location (every 72–168 s) — instants CIRCLE relays already
  learn from the kind-445 — and disconnects within seconds (worst ≈ 33 s with a commit settle); no continuous online
  signal, no standing subscription. ~~Each burst's REQ carries `since` ≈ the previous burst time, which the relay served and
  already knows.~~ **CORRECTED 2026-09-05 — true of the GROUP plane, FALSE of the INBOX plane, and P4-6 must not
  assert the retracted sentence in SECURITY.md.** The group REQ does carry `since` ≈ the previous burst's cursor. The
  inbox REQ does not: its floor comes from `INBOX_RESUBSCRIBE_LOOKBACK_SECS` (2 d + 1 h = 49 h,
  `cursor.rs:147`, `:358`) on every `SubscribePhase::Resubscribe`, and every burst open is a `Resubscribe`. At the
  SHIPPED `INBOX_BURSTS_PER_REQ = 1` (`config.rs:336`) that means every burst — every 72–168 s — asks each inbox relay
  to replay **49 hours of gift wraps keyed on the device's own `#p`**, under a stable sub-id.
  **This codebase already made the opposite judgement, in writing.** `LiveSyncCore::probe_subscriptions`' doc
  (`session.rs:2108-2110`) records why the health tick's inbox-silence arm was DELETED: re-issuing that REQ would mean
  "the device would ask its relays to replay two days of gift wraps keyed on its own `#p` every quarter of an hour —
  battery, relay load, and a standing re-advertisement of 'this npub is here, asking about itself'". P4 at k = 1 does
  exactly that, **5–12× more often** than the pattern that was deleted for being too costly (900 s then, versus the
  72–168 s publish interval now), and no doc acknowledged the reversal until this note.
  **Narrowing the lookback is NOT an available fix** (verified 2026-09-05, do not re-propose it): the 49 h floor
  exists because NIP-59 gift wraps are backdated up to 48 h, plus an hour of clock-skew margin, and `cursor.rs`'s own
  doc states that a wrap below the floor is lost SILENTLY — "an invitation that is never fetched is indistinguishable
  from one that was never sent" (`cursor.rs:133`). Cutting the window trades a metadata leak for silently dropped
  invitations.
  **The real mitigation is raising `INBOX_BURSTS_PER_REQ`, and OD4-b ALREADY AUTHORISES it** (§4 register, accepted
  2026-08-29: k such that k × interval ≥ 10 min). The shipped k = 1 is this plan's own placeholder, not a decision:
  raising it IMPLEMENTS an accepted decision rather than opening a new one. It is currently BLOCKED on a separate
  defect — at k > 1 a foreground re-anchor CLOSES the standing inbox REQ without re-issuing it — being fixed in code
  now; k must not be raised before that fix lands, or invitations stall until the next k-th burst.
  The burst opens the engine socket and the publish socket from the same address in the same seconds — the
  same two-socket linkability as today's foreground, not a new one (the two-socket fact of §1.2, recorded in the RC1
  summary). **New inference, named:** an INBOX-ONLY relay (kind 10050 set, independent of
  the circle sets, `SECURITY.md:864-866`) learns nothing from a kind-445 it never carries; today it sees one continuous
  socket, after P4 it sees a REQ/CLOSE pair every 72–168 s (the 120 s nominal cadence, jittered ±40 %) = "this pubkey is background-sharing now" — OD4-b (inbox
  REQ on every k-th burst, ≥ 10 min) removes the cadence signal at ≤ 10 min invitation latency; without it the inference
  is disclosed in SECURITY.md and the RC1 summary. "Updates arrive in seconds" is a FOREGROUND property; in the background
  peers' positions are picked up at each own publish instant (worst case one peer interval + one own interval + burst ≈
  346 s < `kReceiveSilenceThreshold` 564 s, F22, so the health model's receive verdict stays consistent on resume).

**Gap-closure decision record (2026-09-08) — three independent Opus 5 reviewers, unanimous. Do not re-open
without new evidence; in particular, do not "simplify" the fix into any option struck through here.**

The invariant could not land as drafted, because the code left three ways for a backgrounded pause to keep the
engine's standing REQ, its socket and the crate's 55 s keepalive. Two decisions at the pause instant read
DIFFERENT inputs: `shouldBurstImmediatelyOnPause` asked "should I publish now?" and `pausedRelayOwner` asked
"could a burst run?" — and when the first said no and the second said "a burst will close it", nothing closed
anything. The deeper error was a two-pool conflation: `pausedRelayOwner`'s `none` branch shuts the PUBLISH pool
(`RelayManager`, `.ping(false).reconnect(false).sleep_when_idle(true)`), while all three artefacts belong to the
ENGINE pool (`build_engine_client`, `RelayOptions::default()` ⇒ ping on, reconnect on, never idle out), which
only `pauseSubscriptions()` closes. A one-predicate fix would therefore have closed the wrong socket and left the
sentence false.

**ADOPTED: reframe the socket decision from "could a burst run?" to "is a burst running?", and route the close
through the coordinator's existing teardown.** `closeIdle()` queues `_closeBurst` on the same `_chain` under the
same `_bursting` flag a burst raises — which is load-bearing three times over: it cannot interleave with a burst,
a mid-pause opt-out waits for it through `runningBurst` instead of pausing underneath it, and it inherits both
the per-link handback re-reads and the UNBOUNDED commit-critical drain (Rule 13) instead of open-coding them.
Needed no Rust change: `pause_subscriptions` from the plain foreground-running state was already correct,
idempotent and green (`pause_subscriptions_leaves_no_subscription_in_the_pool`), and the settle/pause pairing was
already covered by `a_commit_arriving_between_settle_and_pause_is_still_confirmed`.

Struck through, with the reason each was rejected — all three reviewers independently:

- ~~**Always drive an immediate burst at the pause.**~~ Emits a duplicate kind-445 to every circle relay within
  60 s of the last one, discarding the overlap guard's own justification. MORE presence revealed, not less, plus
  a radio wake and a GPS window. Also fixes nothing for an account with nothing eligible.
- ~~**Leave the code; qualify the invariant.**~~ Procedurally available (`ratcheted` + a stated residual needs no
  override), and rejected on the merits: the residual is not an accepted engineering trade-off like the 49 h
  inbox lookback, it is a branch nobody meant to leave open, removable by moving one decision's input. It fires
  on the DOMINANT interaction (open, glance, background within 60 s), and it could not cover the
  nothing-eligible case honestly — that clause would have read "and indefinitely, for an account with nothing to
  publish". Buying documentation accuracy with the pillar that ranks first is the trade CLAUDE.md forbids.
- ~~**Reuse `releaseBurstPlaneOnOptOut` for the pause close.**~~ It has no handback gate (correct for consent
  withdrawal, wrong here — a resume 300 ms later must STOP the close, not race it) and no commit-critical drain,
  so reusing it would have imported a Rule-13 hole onto the most frequent pause path in the app.
- ~~**A publish-less "ingest and close" burst reusing the already-open socket.**~~ Not a passive re-use:
  `open_background_burst` does `unsubscribe_all` (CLOSE frames), `connect()`, re-issues every REQ, and at the
  shipped `INBOX_BURSTS_PER_REQ = 1` emits the 49 h `#p` gift-wrap query and consumes a fold slot. That is
  presence revealed at a NON-publish instant, on the exact plane the invariant is about — privacy-inferior to
  what was adopted, for a freshness gain nothing consumes.
- ~~**Force the publish-pool shutdown at the foreground handback.**~~ Races the resume publish
  (`_shutdownPublishPool` disconnects with no drain of ordinary publishes, and `_onResumed` publishes
  immediately), costs a cold reconnect at the one moment the user is watching the map, and would require
  inverting three tests that assert the opposite as a positive property. No privacy is gained by closing the
  socket of an app that is on screen.
- ~~**Delete `shouldBurstImmediatelyOnPause` entirely** (its socket-closing justification evaporates once a
  plain close path exists).~~ Considered and DECLINED for this packet only, not refuted: it changes observable
  publish behaviour and touches the P2a e2e oracle. Revisit if that oracle is being re-derived anyway.

**Residuals P4-6 MUST disclose — the list, assembled 2026-09-07 from the review of the shipped P4-2/P4-4/P4-5.
Build SECURITY.md from THIS, item by item; it supersedes the three-point instruction the P4-6 packet row used to
carry (those three are items 4, 3 and 5 below).**

The headline sentence needs qualifying before it is even true. The qualified form, which every item below is
scoped against: *"While backgrounded on iOS with sharing on, Haven opens a relay connection only at the instants
it publishes its own location, and holds no standing subscription between them."*

1. **The motion trigger publishes OUTSIDE the burst plane.** It keeps running while paused, publishes through
   `locationPublisherProvider` rather than through the coordinator, and issues no REQ — so the qualified sentence
   SURVIVES it: a motion publish is a publish instant and holds no subscription. Two things it does change, and
   the sentence must not hide either: its socket is closed only by the NEXT burst's teardown or by the publish
   pool's own idle sleep, which is **(60 s, 70 s]** by construction (the pool polls idleness once a minute from
   inside the connection task) — not "within seconds"; and while the user is MOVING it lowers the publish-cadence
   floor to `kLocationPublishOverlapGuard` (60 s), so "every 72–168 s" is the STATIONARY cadence, never a ceiling
   on how often a backgrounded device connects.
2. ~~**A pause whose last publish falls inside `kLocationPublishOverlapGuard` drives NO immediate burst**~~
   **RESOLVED 2026-09-07 — do NOT disclose it, and do not re-derive it from the code as it reads today.** It was
   real: a pause inside the overlap guard drove no burst, and a pause with nothing eligible could not drive one
   ever, so the FOREGROUND's standing REQ, its socket and the crate's 55 s keepalive persisted past the pause —
   to the first per-circle tick in the first case (≤ `kLocationPublishMaxInterval`, mean ≈60 s, on the dominant
   open/glance/background interaction) and for the WHOLE background window in the second. The
   `pausedRelayOwner` fall-through covered NEITHER, in spite of appearances: its only effect is an unawaited
   shutdown of the PUBLISH pool, and all three of those artefacts belong to the engine pool, which only
   `pauseSubscriptions()` closes. Both exits now run the coordinator's own teardown
   (`BackgroundBurstCoordinator.closeIdle` — settle, pause engine, Rule-13 commit-critical drain, pool shutdown;
   four links, of which the drain is a no-op in the common case, which is why the Dart test's ordered log asserts
   three). `hasBurstableCircle` is gone from `pausedRelayOwner` with it: one owner per plane, or the unawaited
   shutdown races the drain. **Scope precisely — this closed the background-SHARING arm, and a second fix closed
   the other one.** `shouldStopLiveSyncOnPause` was `!isIOS`, so iOS with sharing OFF also left the engine
   neither stopped nor paused, holding the same three artefacts for the whole window; it is now
   `!(isIOS && backgroundSharingEnabled)` — "every pause except the one whose process keeps receiving" — so that
   arm STOPS the engine, as Android-with-sharing-off already did. Stopping is the recoverable direction
   (`_healLiveSyncIfStopped` handles `isRunning == false`; it cannot see `paused`). Every pause on the iOS branch
   therefore now ends with the engine closed, by one of those two mechanisms.
3. **"No relay traffic between bursts and no PERIODIC wake" — never "no timer wake."** A repair armed BEFORE the
   pause keeps its deadline and fires once, up to `BACKOFF_MAX_SECS` (30 s) into the pause, sees `paused` and
   re-parks. CPU only, no socket, at most once per pause.
4. **`since` ≈ the previous burst is true of the GROUP plane only.** The inbox plane carries
   `INBOX_RESUBSCRIBE_LOOKBACK_SECS` (49 h) on every `Resubscribe`, i.e. on every fold — and at the shipped
   `INBOX_BURSTS_PER_REQ`, on every burst.
5. **A crash mid-burst does NOT self-heal.** ~~OD4-c is open, so~~ ~~**OD4-c is DECIDED (2026-09-09, both halves —
   §4, L-121) and UNBUILT, so the obligation is unchanged and its WORDING is not:**~~ **OD4-c is DECIDED and its RUST
   half is BUILT (2026-09-09; §4, L-121, L-133), which changes WHAT item 5 discloses and not whether:** no P4-6
   sentence may describe recovery — neither `PendingCommitRecovered` nor the next burst's full re-REQ restores a
   group wedged this way, and nothing about the engine moved. What is disclosed now is what the control removes and
   what it leaves: a background BURST no longer opens the publish-before-apply window (the eviction is parked as a
   durable per-circle row and published by the next FOREGROUND open), and a group already wedged is NAMED per circle
   rather than flattened into a self-clearing status **and NAMED to the user: (i)'s Dart consumer landed the same
   day (L-134), so the verdict is read, the circle is marked blocked, and the banner names it and offers the
   re-create, on the second foreground open** — while the parked circle's sends stay refused until that
   foreground open, the Android catch-up sweep still publishes rather than parks (a finding, stated at the call
   site and tested: a park is unredeemable from a background isolate), and an obligation recorded by ANOTHER
   session is reported but can never be published at this rev. ~~item 5 is disclosed as a **decided control that
   has not shipped**~~ It is
   still **never an accepted residual**, because option (iii) was rejected.
6. **A teardown that stops at the foreground handback does not explicitly close the publish pool**, and falls back
   to the same (60 s, 70 s] idle sleep as item 1. Deliberate, and now BOUNDED rather than open-ended: the app is
   on screen, holding sockets by design, and the next pause's teardown — the burst it drives, or its idle close —
   shuts the pool. Forcing the shutdown at the handback instead would race the resume publish
   (`_shutdownPublishPool` disconnects with no drain of ordinary publishes) and cost a cold reconnect at the one
   moment the user is watching the map. The unmounted-shell half of this item is RESOLVED: the pool handle is
   captured at startup (`_runStartupTasks`), so a teardown that outlives the widget closes what it captured.
   (The mid-opt-out path DOES close it: both teardown links are issued together, so a wedged engine cannot
   starve the shutdown.)
7. **`max_rewind_commits` is pinned by no gate.** `security_rule_gates.rs` pins `DEFAULT_MAX_PAST_EPOCHS == 5` and
   `app_message_past_epoch_limit() == 5`, but the past-epoch OUTER peel that a one-epoch-behind burst relies on
   runs on `ConvergencePolicy::max_rewind_commits`, taken from the upstream default. Extending the gate is OWED
   (separate packet); until it lands the guarantee rests on an upstream default, and P4-6 must say so rather than
   state the peel as unconditional.
8. **An account with nothing publish-eligible receives NOTHING while backgrounded.** Closing item 2 pauses the
   engine at the pause instant even when no circle is eligible (fresh install, left the last circle, all blocked,
   all legacy-orphaned, all still pending) — and with no eligible circle there is no publish tick, so nothing
   reopens it until the next foreground. Gift-wrapped invitations (kind 1059) therefore arrive on resume, not in
   the background, where before the fix the inherited foreground REQ delivered them. This is the intended trade —
   the alternative is an unbounded standing REQ for an account sharing with nobody, and R14 forbids a background
   timer to reach the inbox any other way — but it is a real receive-plane change and must not be presented as
   pure gain.
9. **The resume re-anchor throttle is bypassed on this branch.** `_onResumed` re-anchors when
   `engine.isPaused || burstInFlight != null || shouldReanchorOnResume(...)`, and after the fix the engine is
   paused at essentially EVERY resume of the iOS background-sharing branch, so the 60 s throttle never fires
   there. The bypass is individually correct (a paused engine held no REQ, so "the first re-anchor already
   covered that window" is false of it), but the cost is real and recurs: a quick out-and-back — app switcher,
   lock/unlock, fetching a 2FA code — now costs a pause, a pool reconnect and a 49 h `#p` gift-wrap inbox replay
   each time, where before it cost nothing. For a long background window the trade is clearly a win; for rapid
   app-switching it is a loss. (`AppLifecycleState.inactive` does not reach `_onPaused`, so a notification-shade
   pull is not affected.) Mitigating would mean distinguishing "paused, but recently enough that the foreground's
   own prior REQ still covers the window" — machinery not currently judged worth its complexity, and recorded
   here instead.
10. **A cold launch that backgrounds before the engine has started comes up Live in the background.**
   `_startLiveSync()` is `unawaited` from `_runStartupTasks`. A pause landing first runs the teardown against a
   session that does not exist yet — `pauseSubscriptions` returns `NoSession`, which is caught and logged — and
   the start then completes in the background with standing REQs and the 55 s pinger. Bounded by the first
   publish tick's burst teardown (≤ `kLocationPublishMaxInterval`) in the ordinary case, and unbounded in the
   item-8 case, where no tick is coming. The `reanchorPausedEngine` backstop cannot make this worse — it is gated
   on `appForegroundProvider` precisely so a re-arm landing after a pause cannot put a REQ back — but it does not
   close this either.
11. **The idle close can cut an ordinary in-flight publish.** `_shutdownPublishPool` disconnects with no drain of
   ordinary publishes, and the pause path now reaches it where it previously did not. Security Rule 13 is
   UPHELD — commit-critical ladders are awaited unbounded through `_drainCommitCritical`, and the motion trigger
   is largely self-excluded because the idle arm is taken precisely when the last publish is inside the same 60 s
   guard `_guardedPublish` enforces — so the exposure is at most one location sample, superseded by the next
   tick. For the nothing-eligible case it is strictly SAFER than before, where the same pool was shut with no
   drain at all.

**Exact change list.**
- `haven-core/src/relay/live_sync/config.rs` → `BURST_BACKLOG_WAIT_SECS = 5`, `BURST_SETTLE_CAP_SECS = 18` (+ `const _: () = assert!(BURST_SETTLE_CAP_SECS >= COMMIT_SETTLE_WINDOW_SECS + 10)`; doc: the cap bounds idle follow-on activity, never an in-flight publish), `INBOX_BURSTS_PER_REQ` (k = 1 today; OD4-b sets k so that k × `kLocationUpdateInterval` ≥ 10 min — the invariant statement names the constant, never a value, so it stays true whichever way OD4-b goes). **STATUS 2026-09-05: shipped at k = 1 (`INBOX_BURSTS_PER_REQ` in `config.rs`; ~~`:336`~~ **the line moved — CORRECTED 2026-09-07, cite the constant**), which is this plan's PLACEHOLDER, not a decision. OD4-b is already ACCEPTED (§4, 2026-08-29), so raising k implements a taken decision — it is not a new one and needs no further sign-off. It is BLOCKED on one defect: at k > 1 a foreground re-anchor closes the standing inbox REQ without re-issuing it, so invitations would stall until the next k-th burst. Fixed in code (separate packet); raise k only after it lands. Until then every burst asks each inbox relay for 49 h of `#p` gift wraps — see the corrected Privacy metadata statement.**
- (`cursor.rs` bounded lookback: landed in P1-N0.)
- `haven-core/src/relay/live_sync/anchor.rs` → `CursorAnchors::all_consumed()`, `InboxAnchor::is_consumed()` (presence-only; doc: after `note_delivery_gap` "consumed" means "advance burned"). `supervisor.rs` → `RawSignal::Pause { ack: oneshot::Sender }` marker handling (drain-then-clear + `note_delivery_gap()` + ack), the intake `Sender` cloned onto the core (today it lives only in `run_receiver`, `:230-231`), `subscribe_bucket` returning the ACCEPTED relay set, per-endpoint `eose_seen: HashSet<RepairKey>` in the delivery tracker (the worker already has the key, `:585-600`) firing `eose_notify`. `processor.rs` → `eose_notify: Notify`; `pub async fn wait_backlog_settled(&self, expected_endpoints: &[(RelayUrl, SubscriptionId)], timeout)`; `in_flight_publishes: AtomicUsize` with a drop guard around the publisher call in `resolve_publish_work`; `commit_activity` counter + `last_commit_activity_at` (`Instant`) updated in `route_events` (`GroupUpdate`) and `resolve_publish_work` (`AutoPublish`). `repair.rs` → `RepairQueue::clear`. `session.rs` → `paused: AtomicBool`; `pause_subscriptions` (lifecycle lock held throughout: sweep → bounded marker `send().await` + ack with the `wedged` short-circuit and the direct-clear fallback → gauge zero → `disconnect` → `repair.clear()`), `wait_backlog_settled`, `settle_before_pause` (+ `settle_before_pause_with(window, cap)` — **no `clock` parameter; F35 was stale, `test-util` is a dev-dependency and `start_paused` works. CORRECTED 2026-09-05**), `is_paused`; ~~`resume_after_background` … issues the inbox REQ on every k-th burst~~ **CORRECTED 2026-09-07: P4-2 SPLIT the entry points and the fold moved off this one. `resume_burst(kind, inbox_every)` is the shared body; `resume_after_background()` calls it with `BurstKind::Foreground`, which ALWAYS carries the inbox REQ at any `k`, and `open_background_burst()` calls it with `BurstKind::Background`, which is the only caller that reads or advances the fold counter. The split is load-bearing, not cosmetic: a foreground re-anchor's `unsubscribe_all` is unconditional, so one that folded the inbox away would CLOSE the standing kind-1059 REQ without re-issuing it and no invitation could arrive for as long as the app stayed open — the very defect that blocks raising `k`.** `resume_burst` clears `paused` (and the radio-off flag) under the lock and RESTORES both on every failure exit, `add_relay`s the `active` union, re-sweeps before `connect()`, and folds the inbox on a background burst only; gates in `run_repair` (before `take_due`), `reissue`, `maintain_subscription_health`, `subscribe_circle` (seeds the cursor), `unsubscribe_circle`; `SyncStatusReason::Paused` emitted once, `run_monitor` suppresses `Disconnected` while paused; the two comments saying "the engine never enables sleep_when_idle" stay true — leave them. `health.rs` → `HealthAction::Paused` (+ doc row). **`open_background_burst()` is the BURST entry and `resume_after_background()` the FOREGROUND re-anchor; both delegate to `resume_burst(kind, inbox_every)` — added to this list 2026-09-07, because P4-2 landed a split this line never named.** **Every `session.rs:NNNN` citation in §5.4 has drifted and NONE should be trusted — noted 2026-09-07.** P4-2 and its follow-ups moved the file by hundreds of lines: `wait_backlog_settled` is no longer at `:1532`, `settle_before_pause_with` no longer at `:1571`, the `probe_subscriptions` doc that records the deleted inbox-silence arm no longer at `:2108-2110`, the drain test no longer at `:5627`. The symbols are stable and the line numbers are not; cite the symbol.
- `haven/rust_builder/src/api.rs` → `SubscriptionHealthActionFfi::Paused`, `SyncStatusReasonFfi::Paused`, `LiveSyncFfi::{pause_subscriptions, wait_backlog_settled, settle_before_pause}` (`async fn … -> Result<_, String>` through `live_session_core()`, pattern `:11187-11200`) and `#[frb(sync)] is_paused -> bool` (pattern `is_running`, `:11246-11250`); regenerate. `haven/lib/src/services/relay_service.dart` → `SubscriptionHealthAction.paused` (the exhaustive switches in `maintenance_scheduler_provider.dart:_runHealthTick` `:454-460` and `subscription_health_mapping_test.dart` catch it at compile time); `live_sync_provider.dart:153-154` → `SyncConnectionPhase.paused`; `sharing_health_provider.dart:288-295` → `paused` clears `_disconnectedSince` and `recordRelaySubscriptionSignal` ignores it. `subscription_service.dart` + `nostr_subscription_service.dart` → `pauseSubscriptions()`, `waitBacklogSettled()`, `settleBeforePause()`, `isPaused`.
- NEW `haven/lib/src/services/background_burst_coordinator.dart` (no `ref.watch`; `finally` pause on throw and cancellation; `BURST_BOUND` constant).
- `haven/lib/src/pages/map_shell.dart:1335-1363` → installs the coordinator and hands the scheduler ticks to it (`LocationPublishSchedulerNotifier` gains `setTickSink(BurstSink?)`; `null` = today's direct publish; `_dispatchTick` carries the `.timeout(`); `:1455-1463` `shouldKeepRelayConnectedWhilePaused` → the predicate is DELETED (the coordinator owns the publish socket per burst); its static tests replaced by the coordinator's "socket closed after burst" test; the pause truth table gains a THIRD state (`burst`) rather than flipping a bool (R14 caveat in a `reason`); `_onResumed` bypasses the 60 s re-anchor throttle when `engine.isPaused`; `_bgSharingPausedSub` C4 edge → also `pauseSubscriptions()`.
- `haven/lib/src/providers/maintenance_scheduler_provider.dart` → `runKeyPackageIfDue(now)` / `runRelayListIfDue(now)` (reuse `_isCurrent`/in-flight guards; "due" = last completion older than the jittered interval; direct calls from the coordinator); ~~the P1 foreground gate already keeps KP/relay-list/health timers un-armed while paused on every platform — P4 adds nothing there~~ **FALSE — LANDED CORRECTION 2026-09-07. True of `KeyPackage` and relay-list; FALSE of HEALTH, and health is the one of the three that could undo the whole phase.** P1's gate deliberately spared it: `_backgroundReceiveActive()` was `backgroundSharingEnabled && isIOS` — the SAME predicate as P4's burst branch — and `suspendForBackground()` cancelled the other two while leaving the health timer armed, because on that branch a standing subscription was precisely what the tick existed to repair. P4 removes the thing being repaired, and the carve-out became a live defect. **The Rust `paused` gate does not catch it**: `maintain_subscription_health` short-circuits only if `paused` is already true ON ENTRY, and `resume_burst` clears `paused` for the burst's whole duration — so a tick landing MID-BURST passes the gate, reads a pool in the middle of `connect()` as dropped, and repairs it through `resume_after_background()`, the FOREGROUND entry, which carries the inbox REQ at any `k`. One such tick leaves standing REQs, an open socket and a 49 h gift-wrap replay keyed on this npub **at an instant that is not a publish**, and it persists to the next burst's pause. A 15-min tick against a 72–168 s burst is expected to land inside one roughly one to three times per 8-hour background window. **Fixed:** health is foreground-only on every branch, gated at BOTH ends — at arming (`_armHealth` is the single arming site and refuses while backgrounded; `suspendForBackground` now cancels all three; the R1 consent edge's `rearmHealthForBackgroundReceive` routes through `_armHealth` and therefore arms nothing while paused) and at fire time (`_runHealthTick`'s `_appIsForegrounded()` refusal, for the timer armed in the foreground that fires after the pause and before `MapShell` has suspended). R14 (a) "never re-add a background Dart timer" becomes a lint test.
- Guards: `check_engine_client_options.sh` `check_engine_pool_options` → `session.rs` still contains no `.sleep_when_idle(`/`.ping(false)` CALL, AND `fn pause_subscriptions`'s body contains `note_delivery_gap` (or the marker that reaches it), contains NO `forget_` token, and contains `client.disconnect()` and NO `client.shutdown()`; plus "no `subscribe_long_lived`/standing-REQ call reachable from the background-burst entry point" (token-bound); +3 fixtures ~~(count 13)~~ ~~**(CORRECTED 2026-09-05: … now carries 21 … `SELF_TEST_FIXTURES=21`, `check_engine_client_options.sh:505`)**~~ **STALE AGAIN — CORRECTED 2026-09-07, and the correction is now stated as the RULE rather than as a fourth number: the total is whatever `SELF_TEST_FIXTURES` in `scripts/ci/check_engine_client_options.sh` reads when you look, and `:505` was not where it lived either. Three successive corrections to this one figure each went stale inside a fortnight, which is the argument for the rule rather than an exception to it: CITE THE CONSTANT and NEVER a value or a line, in this plan or in a commit message.**: `forget_inbox_subscription` instead of `note_delivery_gap` (drops hold-backs); `client.shutdown()` instead of `disconnect()`; a standing-REQ call in the burst path — NO call-order fixtures (the order is not the cursor-safety argument; F3 changes it anyway). `check_live_sync_restart_budget.sh` is a numeric-derivation guard over `config.rs`/`cursor.rs`/`live_sync_resubscriber.dart`/`location.dart` (script lines 44-49, 148-205) and is NOT the home for a Dart source-order pin — "`_onResumed` references `isPaused` beside `shouldReanchorOnResume`" lives in `map_shell_location_access_lifecycle_test.dart` (the P1 source-order family); the shell guard is unchanged. `check_ios_background_publish.sh` → the iOS pause branch must call `pauseSubscriptions` on the C4 edge (extends check 6's neighbourhood; +1 fixture: ~~47 → 48 after P3, 23 → 24 if P4 lands first~~ ~~**CORRECTED 2026-09-05: … `SELF_TEST_FIXTURES=118` (`:1423`)**~~ **STALE AGAIN, AND THEN AGAIN — the 2026-09-07 correction wrote `SELF_TEST_FIXTURES=144` at `:1709` and BOTH halves have since moved once more, exactly as that correction predicted of itself. No fifth number is written here: read `SELF_TEST_FIXTURES` out of `check_ios_background_publish.sh`. Every generation of this citation (48/25, then 118, then 144) had moved before the next reader arrived, number and line together**). `check_no_event_timestamp_cursor_advance.sh` must stay green (the burst anchors on EOSE/cursor). `check_m7_native_wake_guards.sh` 14b untouched (runtime decision, not a define flip). Extend check 13's token scan (iOS post-termination receive-only) to the coordinator: the burst is reachable only from the RUNNING process's publish tick, never from SLC/BGTask entry points (`ios_background_catchup.dart`/`HavenSLCHandler.swift`).
- ARB: `locationSettingsIosGuidance` 2nd sentence only if it mentions receiving (verify; P3 owns the 1st). `fgsNotificationSharing` stays literally true. No presence/one-connection copy round and no `presence_copy_accuracy_test`: the Privacy page that carried both sentences was removed 2026-08-29.
- `docs/privacy/privacy_invariants.json` → NEW `INV-R-BACKGROUND-PRESENCE-ONLY-AT-PUBLISH` (enforced): "While backgrounded on iOS with background sharing on, the engine holds no standing subscription and no socket between publish bursts; each publish tick runs one bounded burst (REQ at the persisted cursor, inbox lookback ≤ 2 d + 1 h and the inbox REQ every `INBOX_BURSTS_PER_REQ`-th burst (k = 1 unless OD4-b), never the 7-day cold window → ingest → publish → per-relay ack window 5 s → settle (in-flight publishes always complete) → close); on Android the foreground service shuts its publish pool at the end of every cycle; presence is revealed only at publish instants (and, to inbox-only relays, at every `INBOX_BURSTS_PER_REQ`-th one); the burst re-subscribes by construction." **QUALIFIED 2026-09-07, REVISED 2026-09-08 after the gap closure — read THIS version, not the one it replaces.** ~~It is NOT true of the first gap after a pause that drove no immediate burst (residual 2), nor of a teardown that stopped at the foreground handback (residual 6).~~ Residual 2 is now RESOLVED IN CODE: every pause on the iOS branch ends with the engine closed — `BackgroundBurstCoordinator.closeIdle` on the background-sharing arm, `shouldStopLiveSyncOnPause` on the other — so the first gap after a pause is no longer an exception and the invariant may state it. The scope clause P4-6 should land, which is defensible from the code as it now reads: *"While backgrounded on iOS with background sharing ON, from the completion of the pause branch's teardown until the next burst's open, the engine holds no standing subscription and no socket — except where the teardown stopped because the foreground reclaimed the engine (residual 6), or where the engine's own startup completed after that teardown ran (residual 10). The publish pool is a separate plane: the motion trigger may re-open it between bursts (residual 1), and it is closed by the next burst's teardown or by its own (60 s, 70 s] idle sleep."* That is stronger than the superseded qualification and weaker than the unqualified headline. Land it with the residual list, or the manifest asserts something the code does not — the failure mode a ratcheted invariant exists to prevent. no `disclosure_arb_keys` (Privacy page removed 2026-08-29); tests = Rust `pause_subscriptions_leaves_no_subscription_in_the_pool`, `burst_ingests_a_peer_commit_before_the_location_is_encrypted`, `a_burst_reissues_the_inbox_req_every_kth_burst` + Dart coordinator tests + the FGS `the publish pool is shut down at the end of every cycle`; guard `check_engine_client_options.sh`. `INV-R-CROSS-PLANE-CORRELATION` (RC1): statement narrowed for CIRCLE relays ("standing while on screen; on iOS-bg one bounded burst per publish tick") and EXTENDED with the inbox-only-relay cadence residual, no ARB keys (its Privacy-page keys were deleted 2026-08-29); `accepted_deviations[RC1].summary` amended (narrowing + the named residual; "strictly narrows" is not claimed). `INV-L-ANDROID-REBOOT-RESURRECTS-PUBLISHING` unaffected. No `ratchet_override`.
- Docs: `SECURITY.md:873-900` bullet rewritten per the metadata statement incl. the inbox-only-relay inference and OD4-b (also `:257-263` Android sentence, `:876-879`, `:864-866` cross-reference); `docs/M11_ROLLOUT.md:117, :121` (P0's correction REVERSED to the original "while the app is in the foreground" + the Android-FGS clause + "on iOS in the background, one bounded burst per own publish" — the OD4 record); `WN_RELAY_EPOCH_SYNC_MIGRATION.md:63,:130,:168-176` iOS matrix rows, `:653-656` residual 1 scoped to foreground; `FA` Unit C notes + `:45-47` (the burst IS the iOS-bg receive path), `:62-65`/`:835-845` (the deleted 10-min re-anchor: the burst is NOT timer-driven, it rides the publish tick and the lookback is bounded — precisely what made the deleted one harmful), R14 (the 15-min tick is the FOREGROUND healer); `M7` §6 item 0 gains "no relay traffic between publishes" as an observable (Console `nw_connection` / relay-side log); `haven/test/pages/map/map_page_location_access_test.dart:10` doc comment (cites the deleted predicate) re-worded; `CI_HARDENING_BACKLOG.md:165` "Route 2 rejected" — consistent; dated note.

**Tests FIRST.**
- Rust (`session.rs` tests + NEW `haven-core/tests/live_sync_burst_e2e.rs`, in-process relay; the multi-member harness is `live_sync_two_engine_converge_e2e.rs` / `live_sync_engine_e2e_test.rs` — `selfremove_autopublish_e2e.rs` drives a `FakePublisher`, not a relay): `pause_subscriptions_leaves_no_subscription_in_the_pool` (`client.subscriptions()` empty; every relay `Terminated`); `a_partial_unsubscribe_all_is_swept_before_disconnect` (a relay whose `ensure_operational` errors → leftover ids are unsubscribed one by one; pool view empty); `a_stale_relay_side_req_never_precedes_the_bursts_own_req` (plant a leftover subscription on the core's client with the same sub-id and an older `since` while paused; open a burst; a recording `QueryPolicy` — precedent `catchup_sweep_e2e.rs:1300-1315` — shows the first REQ the relay admits for that sub-id carries the session's `since`, and the persisted cursor advances only after the session's own EOSE); `a_late_eose_after_pause_never_advances_a_cursor` (CLOSE, inject EOSE for the old sub-id → cursor unchanged); ~~`a_backlog_larger_than_the_backlog_wait_is_ingested_by_the_burst_that_downloaded_it` (N slow events + EOSE; every event reaches the engine exactly once; the next REQ's `since` advanced — fails if the router is cleared before the drain)~~ **REMOVED 2026-09-05, correctly: as specified it counted Location bus events, which measures MDK semantics rather than Rule 12 — out-of-order application messages return `Stale { PeelFailed }` and are RETAINED, and relays replay newest-first, so the "exactly once on the bus" oracle was never a statement about the drain. Replaced by `pause_subscriptions_drains_the_intake_before_it_clears_the_router` (`session.rs:5627`). THE REPLACEMENT IS WEAKER THAN REQUIRED, and this is an open gap, not a closed item: the reviewer-checklist attack below — "clear the router before the drain" — does NOT currently go red. A stronger replacement is being written (separate packet); P4 is not done until that attack reddens something.** `a_hold_back_survives_pause_and_is_re_requested_by_the_next_burst` (deliver a `Buffered` future-epoch event, pause, burst → after the next burst's EOSE the PERSISTED CURSOR ≤ the held `created_at` AND the engine still holds the buffered message — the anchor bounds the next ADVANCE, `anchor.rs:101-109`, it does not lower `since` — fails if pause `forget`s anchors); `a_closed_queued_before_pause_does_not_reopen_a_req_while_paused` and `a_closed_queued_before_pause_does_not_fire_after_the_next_burst_opens` (relay-side REQ count for that sub-id == 1 in the burst); `subscribe_circle_while_paused_updates_the_model_but_opens_nothing`; `subscribe_circle_while_paused_seeds_the_cursor_so_the_next_burst_never_asks_since_zero`; `a_circle_added_while_paused_is_live_after_the_next_burst` (relay added while paused; after burst open its `QueryPolicy` has seen one REQ whose `#h` contains the new hex, and a peer 445 is decrypted); `maintain_subscription_health_while_paused_reports_paused_and_touches_no_socket`; `pause_emits_paused_not_disconnected` (one `Paused`, zero `Disconnected` across the pause); `burst_ingests_a_peer_commit_before_the_location_is_encrypted` (TWO relays, only the SLOW one holding Bob's commit; Alice's burst: `Settled` only after both endpoints, `group_epoch` advanced, then `encrypt_location` → a 445 Bob decrypts at the new epoch); ~~`a_self_remove_auto_commit_is_published_and_confirmed_inside_the_burst` (real engine `Client` over a `MockRelay`, three members; `confirm_published` on the relay's OK; Bob decrypts the eviction)~~ **REWRITTEN AND RENAMED 2026-09-09 to `a_self_remove_auto_commit_is_deferred_by_the_burst_and_published_by_the_foreground`, because OD4-c option (iv) INVERTED what it asserts: the burst must NOT publish the eviction, it must park it, and the next FOREGROUND open publishes and confirms it. Same harness (real engine `Client` over a `MockRelay`, three members; Bob decrypts the eviction); the `confirm_published` moves to the foreground pass (L-133)**; `pause_never_disconnects_while_an_auto_commit_awaits_its_ok` (the S-1/F2/P4-M5 gate, driven THROUGH the intake — Bob's SelfRemove proposal arrives as a relay event, never via a direct `resolve_publish_work` call — against a `WritePolicy` that releases the OK on an OBSERVED condition: the policy sees the close path pending (a hook on the pause's first step), or after a bounded yield ≤ 3 s, far from the crate's 10 s bound — never a wall-clock literal near it (a 9.5 s hold against a 10 s bound is a CI timing race); the call must return AFTER the ack with the commit CONFIRMED, never rolled back; a `NeverAnswer` variant returns after the crate's 10 s bound with the group rolled back to `Stable` and only THEN disconnected; the recording policy's ordering counter shows the relay never observed a CLOSE/disconnect before the publish resolved — relay-backed, outcome sets + ordering only, never an elapsed window; ≤ 10 s wall clock, stated); `a_commit_arriving_between_settle_and_pause_is_still_confirmed` (relay withholds the OK; deliver the proposal AFTER `settle_before_pause` returned; call `pause_subscriptions`; the OK is released once the close path is observed pending; group ends Stable-confirmed, matching the relay's stored state); `pause_subscriptions_completes_within_the_lifecycle_bound_when_the_worker_is_dead` (kill the worker → `wedged`; the call returns within `RELAY_LIFECYCLE_OP_TIMEOUT`, router cleared by the fallback, `note_delivery_gap` called, and a subsequent `stop()` does not hang); `a_burst_open_racing_a_draining_pause_waits_for_the_clear` (open a burst while the marker drain is in progress — the router entries of the NEW burst survive, i.e. the open serialised behind the lock); `a_non_kth_burst_settles_without_an_inbox_endpoint` (under k > 1 a burst that issued no inbox REQ returns `Settled` without waiting on the inbox); `a_dead_relay_in_a_bucket_does_not_time_out_the_burst` (one relay of a two-relay bucket refuses the REQ; the burst settles on the accepted endpoint alone); `settle_before_pause_with_returns_at_once_on_a_quiet_burst` and `…caps_follow_on_activity_at_eighteen_seconds` (PURE, `start_paused`, on ~~the injected clock~~ **tokio's virtual clock — no clock is injected; F35 was stale, see above**); `wait_backlog_settled_times_out_without_a_relay_eose_and_reports_it` (pure, `start_paused`, a `pending()` endpoint); `background_burst_holds_no_standing_req` (client-side, equivalent by construction: every `client.relay(url).status() == Terminated` and `client.subscriptions().is_empty()` between bursts — `MockRelay` subscription introspection is U in `nostr-relay-builder` 0.44; keep the relay-side phrasing only if the builder exposes it); `a_burst_reissues_the_inbox_req_every_kth_burst` (OD4-b; recording `QueryPolicy` on the inbox relay: `#p` REQs == ceil(bursts / k)). `security_rule_gates.rs` → `rule13_a_burst_never_pauses_with_a_pending_publish_outstanding` (the gauge: `in_flight_publishes == 0` at the instant `disconnect()` is called — asserted through the recording policy's disconnect observation — and never pauses in `PendingPublish`); `rule14_pause_and_burst_open_no_second_session` (no new `AccountDeviceSession::open`/`newInstance` site; `LIVE_SESSIONS` stays 1 across 3 bursts); `a_burst_backlog_larger_than_the_intake_cap_holds_the_cursor` (helper at `security_rule_gates.rs:465`). (`cursor.rs` / poisoning tests: landed in P1.)
- Dart NEW `test/services/background_burst_coordinator_test.dart` (fakes + `FakeAsync`/injected clock): `a tick opens, drains, publishes, folds due maintenance, settles, closes — in that order`; `a second tick during a burst joins it instead of opening a second socket`; `the publish socket is shut down after every burst`; `the engine is paused after every burst`; `maintenance runs only when due and only after the publish, by direct call`; `the health tick is never armed while paused` (**LANDED CORRECTION 2026-09-07 — read this line as the lesson of the phase, not as a checked box. §5.4 SPECIFIED this exact test in P4-4 and IT WAS NEVER WRITTEN.** The health carve-out corrected above therefore shipped through P4-4 AND P4-5 with the specification naming, in writing, the one assertion that would have reddened it. A spec'd test nobody writes reports coverage the phase does not have — exactly as a stubbed one does — and nothing counts specified-but-absent tests: no coverage floor, no guard and no reviewer checklist line looks for them. It exists now, as `the health tick is never armed while the engine is paused` in `test/providers/maintenance_scheduler_provider_test.dart` rather than in the coordinator's file, because the arming rule belongs to the scheduler and that is where it can be broken); `toggle-off mid-pause pauses the engine and shuts the relay` (C4); `resume while paused re-anchors regardless of the 60 s throttle`; `a burst that throws mid-chain still pauses` and `a burst interrupted by cancellation still pauses` (try/finally + `bgEnabled` re-check between links — otherwise the engine is left `Live` with standing REQs forever: fail-safe for delivery, silent battery regression); `a C4 edge during a deferred-commit link lets it confirm or roll back before the pool is shut`; `the outer tick timeout never cancels a running burst` (fire the watchdog mid-burst; the burst completes and pauses; the timeout is only reported); `commit-critical links, including the pause link, carry no timeout`; `BURST_BOUND is below the publish link timeout`. `test/lints/background_burst_coordinator_lint_test.dart` (AST, family of `self_update_disabled_test.dart`): no `ref.watch(` in the coordinator file. `test/providers/sharing_health_provider_test.dart` → `a paused engine never yields a relayDisconnected verdict, however long the pause` (FakeAsync 10 min of `paused`). `test/pages/map_shell_location_access_lifecycle_test.dart` → `_onResumed references isPaused beside shouldReanchorOnResume` (source-order). `test/providers/maintenance_scheduler_provider_test.dart` → `runIfDue` tests + "a due KP/relay-list job runs after the burst on the warm socket, never on its own background timer"; existing "fires each task exactly once after its initial delay" stays. `test/widgets/map/sharing_health_banner_test.dart:241` → "re-renders every 72 s while foregrounded and not at all while backgrounded" (strengthened; P1 may already have landed it). FA:693-709 delivery-silence re-anchor: the 684 s arm becomes foreground-only — test that it does not fire while backgrounded on iOS.
- Existing red → replacement: `map_shell` static tests for `shouldKeepRelayConnectedWhilePaused` → deleted with the predicate; replaced by the coordinator's socket-closed test (behavioural, stronger) and the three-state truth-table row. `map_shell_receive_recovery_test.dart:388-405` (`kLiveSyncRestartBudget` 65 s < 90 s heal floor) unchanged (foreground). `ios_bg_publish_test.dart` P2a/P2b: the driven tick now runs a burst; P2a's oracle (Bob's relay subscription sees Alice's 445) unchanged; ADD **P2c** as an IN-PROCESS oracle (the iOS lane runs `tooling/e2e/local-relay` — no strfry, no wire proxy, log lines "listening"/"shutting down" only, `main.rs:54,59`; and the macOS wrapper cannot encrypt an MLS message): keep Bob (`SyntheticUser`, own DB — Rule 14 unaffected; `check_mls_session_single_owner.sh` does not scan integration tests) ALIVE across the pause instead of disposing him at `:705`; the DRIVE calls `bob.publishLocation(...)` (`synthetic_user.dart:449`) after P2a; then bounded-poll `subscriptionService.isPaused == true` between ticks (the "no standing REQ" half in CI, with the Rust in-process test) and `memberLocationsProvider` (or the decrypted-event stream) for Bob's fix within `kLocationPublishMaxInterval + BURST_BOUND`, print `[bg-publish] BACKGROUND_RECEIVE_OK`; shell fixture C7 for the missing marker; relay-side REQ/CLOSE counts (incl. "no `#p` REQ between bursts") only if the local relay gains a `REQ/CLOSE/disconnect` log line with a connection id — a tooling change with its own fixture, listed as optional evidence, not a free oracle; `DISABLE_WAIT_SECS` (`run-ios-bg-publish.sh:220-224`, 655 s + 37 % today) re-derived in the wrapper comment (655 + 200 + margin) and `check_e2e_step_timeout_ordering.sh` re-run with the new inner/step/job derivation (today 45 min inner via `nick-fields/retry`, 95 step, 115 job — `e2e-ios-background-publish.yml:97,181,184`); the workflow header lists P2c. `b9` (Android, foreground) unchanged. Guards: `check_engine_client_options.sh --self-test` and `check_ios_background_publish.sh --self-test` must each pass at their own `SELF_TEST_FIXTURES` (~~13/13~~ ~~21/21~~ / ~~48/25~~ ~~118~~ — **every literal count this row has ever carried has gone stale; CORRECTED 2026-09-07 to name the constants instead of any value. The guards pin their counts by EQUALITY, so the script is the authority and a number in this plan can only be wrong later**).

**Implementer work packets** (sequential unless noted).
| # | Packet | Sequencing | Done when |
|---|---|---|---|
| P4-1 | (landed in P1 as P1-N0 — the bounded lookback is a precondition of the sharing-OFF engine stop too) | — | — |
| P4-2 | Rust engine: `paused`, `pause_subscriptions` (sweep, marker, repair clear), per-endpoint EOSE tracking, in-flight gauge, `wait_backlog_settled`, `settle_before_pause(_with)`, burst-open relay union + re-sweep, paused `subscribe_circle` seed, gates, `Paused` status + monitor suppression, k-th-burst inbox fold, `HealthAction::Paused`, Rust tests + rule gates | first | all Rust tests green; `check_engine_pool_options` (at its `SELF_TEST_FIXTURES`, ~~13~~ ~~21~~ — **CORRECTED 2026-09-07: read the constant, never a value carried here**) green — **LANDED 2026-09-05, with the five corrections recorded in §5.4 (OD4-c crash-recovery claim, `max_past_epochs`, the `run_repair` busy-spin, the inbox `since` claim, F30's rationale)** |
| P4-3 | FFI methods + enum variants; regenerate | after P4-2 | `flutter analyze` clean (exhaustive switches list every site) |
| P4-4 | Dart coordinator (no `ref.watch`; cancellation-safe `finally`; `burstBound`) + scheduler sink/`_dispatchTick` + maintenance `runIfDue` + `paused` phase mapping + unit/lint tests | after P4-3 | `flutter test` green — **LANDED, with the corrections recorded in §5.4: the burst bound re-scoped and `kMaxBurstCircles` deleted, `_dispatchTick`'s watchdog on the sink branch only, the failed-open-still-publishes decision written down. The health-timer carve-out (§5.4, A1) shipped THROUGH this packet: its own spec'd test was never written** |
| P4-5 | Dart lifecycle wiring: `map_shell.dart` pause/resume/C4 edges, three-state table, `isPaused` source-order test; guards + fixtures | after P4-4 | `flutter test`, `flutter analyze`, both guards' `--self-test`, `check_location_access_gate.sh` check 8, `--static-only` — **LANDED, after closing the TWO HIGH defects it introduced (§5.4: the resume-mid-burst pause in the foreground, and the pool shutdown racing the motion trigger's commit ladder) and re-deriving `kOptOutBurstWait` 38 s → 68 s** |
| P4-6 | Manifest + docs: invariant + RC1 residual, SECURITY/M11/WN/FA/M7 (no copy round — the Privacy page was removed 2026-08-29). **Build the SECURITY.md text from the "Residuals P4-6 MUST disclose" list (2026-09-07) in the Design section above — the qualified headline sentence plus EVERY UNRESOLVED item, never from the superseded metadata statement. **Renumbered 2026-09-08: the list now runs to 11, item 2 is RESOLVED IN CODE and must NOT be disclosed, and items 8-11 are new.** The three points this row used to carry are items 4, 3 and 5; the motion trigger's plane and its 60 s floor, the early-stopped teardown and the unpinned `max_rewind_commits` came from the review of the shipped P4-2/P4-4/P4-5; items 8-11 (nothing-eligible accounts receive nothing backgrounded, the bypassed resume throttle, a cold launch that starts Live in the background, and the ordinary publish an idle close can cut) came from the review of the gap-closure itself. None are optional. ~~If OD4-c is still open when this packet runs, item 5 is disclosed as an accepted, named residual~~ ~~**CORRECTED 2026-09-09: OD4-c is DECIDED in both halves (L-121) and its code is OWED, and option (iii) — the accepted residual — was rejected. Item 5 is therefore disclosed as a decided-but-unshipped control, and it stops being disclosed only when (iv) and (i) land with their tests**~~ **CORRECTED AGAIN THE SAME DAY (2026-09-09): the RUST code LANDED (L-133), so item 5 is not a decided-but-unshipped control either. It is disclosed as what shipped and what did not — the burst no longer opens the window and a wedged circle is named, while the parked circle's send block until the next foreground open, the Android catch-up sweep and the absent Dart consumer all remain. Option (iii) is still rejected, so none of that is an accepted residual** | ∥ P4-5 | `check_privacy_invariants.sh` green; **no SECURITY.md sentence traceable to a struck-through claim in §5.4** |
| P4-7 | Lane: `ios_bg_publish_test.dart` P2c (Bob alive; in-process oracle; C7 = the WRAPPER self-test fixture in the C1–C6 series, not a §6.3 row) + wrapper budget re-derivation + workflow header | after P4-5 | `check_e2e_step_timeout_ordering.sh`; green lane run; floors `src/relay/live_sync/|95` (97.24 %), `session.rs|94` (96.19 %): new burst code needs its e2e tests in the same commit or HOLD; `background_burst_coordinator.dart` gets a `--list`-derived row — **LANDED 2026-09-08 except that row, with the three corrections in the Design section (the `isPaused` oracle replaced by the pool subscription count + a foreground control arm; the lane's `HAVEN_LIVE_SYNC` flipped to `true`, without which P2c cannot exist; C7 disambiguated) and the budgets re-derived to 1440 s / 65 / 135 / 155. The Rust floors are already at those values and P4-7 touched no Rust. The coordinator's floor row is OWED, on the `background_deferred_send.dart` precedent recorded in `coverage_floors.txt`: it measures 98.25 % (112/114) on a LOCAL Flutter 3.41, the manifest is pinned on 3.44.8, and this branch's aggregate rows already read points above their pins on that same local SDK — so it is re-pinned with `--repin flutter <lcov>` from the CI artifact, in the sweep that discharges the P3 floor debt** |

**Reviewer checklist.** Break the cursor: any path where a burst advances a cursor past an un-applied event (late EOSE, CLOSED-then-reissue race, hold-back dropped by pause, a stale relay-side REQ re-sent by the crate ahead of the session's, a fast relay's EOSE settling the burst while the slow relay still replays) — the guard pins `note_delivery_gap`-not-`forget_*` because `forget_*` silently loses hold-backs. Break Rule 12: clear the router before the drain — the backlog test must go red (**as of 2026-09-05 it does NOT: the test that carried this attack was removed as unsound and its replacement does not catch the mutation — see the Tests-FIRST entry. This checklist line is currently unbacked and stays here as the specification of what is owed**). Break Rule 13: deliver a proposal AFTER `settleBeforePause()` returned and BEFORE `pauseSubscriptions()` reaches `disconnect` — the marker ack + gauge check inside the pause must let the commit CONFIRM; release the OK on an observed condition, never a wall-clock literal near the 10 s bound; kill the worker and pause — the call must return within `RELAY_LIFECYCLE_OP_TIMEOUT` and a later `stop()` must not hang; open a burst while a pause is draining — the new burst's router entries must survive; with a never-acking relay the group returns to `Stable` before the disconnect (V-P4-1 → V: `disconnect` makes `wait_for_ok` `Err(PrematureExit)`/`Err(NotConnected)`, `inner.rs:1382-1389` — never a false confirm, which is exactly why the gauge must prevent the disconnect). Break the gates: queue a CLOSED before the pause and show a REQ re-issued after burst open (must be impossible — the queue is drained); make `maintain_subscription_health` reach `health_probe` while paused (must be impossible — it would `resume_after_background` in the background); subscribe a circle with a new relay while paused and show the burst open failing or the circle silent. Break Rule 14: any second session/isolate opened by the coordinator; `check_mls_session_single_owner.sh` still three files. Liveness vs FA C/D: with no standing REQ the banner cannot claim a dead receive plane in the background (model tick foreground-only; `paused` never stamps `_disconnectedSince`; on resume re-derived from `lastPeerAt`, bounded 346 s < 564 s). Opt-out: toggle OFF mid-pause ⇒ no REQ, no socket, no timer — C4 test AND guard; a cancelled burst still pauses. Copy: 13 locales keep "which circle tags you are following", say "briefly", never "in seconds" for the background, never "one connection"; rule 12 sweep. Test reliability: every wait on a `Notify`/state transition with a scaled budget or a virtual clock; no paused clock against a live socket; grep new tests for `sleep(`. Wedge: the throw-path AND cancellation-path tests exist. C5: a pending commit is confirmed only on OK-ack (`check_e2e_publish_before_apply.sh`, `auto_commit.rs` at floor 100). C6: `_dispatchTick` carries the `.timeout(` on its SINK branch only (`check_location_access_gate.sh` check 8 resolves it; the direct branch keeps its own inner timeout OUTSIDE the decorrelation wait), ~~`BURST_BOUND < _publishLinkTimeout`~~ **CORRECTED 2026-09-07 — that comparison is not an invariant and must not be checked as one: `burstBound` bounds the burst's own links only, the fold and the Rule-13 drain are excluded by design, and a HEALTHY burst may exceed `kPublishLinkTimeout`. What to break instead: fire the watchdog mid-burst and prove the burst still reaches its own settle, pause and socket close — a cancellation here is the defect, a report is the contract**, and NO timeout wraps commit-critical work. Dart: no `ref.watch` in the coordinator (lint); nothing in the burst path waits on a rebuild.

**Risks / rollback.** A relay that never EOSEs makes every burst wait 5 s (+5 J each, ESTIMATED — §2.3 wake model): bounded, surfaced as `TimedOut`. iOS suspends mid-burst (it should not while the location session is live — R6, which ~~P3's hardware 0a gate proves~~ **P3's 0a would have proved and no longer can: 0a is DEFERRED (§2.5), so this risk is now shared with P3 and stated the same way — if the 100 m shape does NOT keep the process alive on a real device, P4's burst loses its clock too. The staged risk control is P3's (§5.3 Risks): both phases sit behind the background-sharing toggle, and the owner's own-device observation is what would surface it**): the next burst re-anchors at the cursor; ~~a commit mid-publish is `PendingCommitRecovered` → resync~~ **FALSE, CORRECTED 2026-09-05 — see the Design section's `PendingCommitRecovered` note. A commit killed mid-publish does NOT self-heal: (a) the re-fetched own commit returns `Stale { OwnEcho }` from the durable `MessageState::Sent` row, consulted before any MLS processing, so the re-REQ applies nothing and the device stays an epoch behind while later peer commits buffer un-chainable; and (b) for a peer `SelfRemove` auto-commit — the removal-bearing case every burst can stage — `PendingCommitRecovered` is not emitted at all, because hydrate deliberately skips removal-bearing staged commits. ~~The MDK fix (epoch-gap backfill, #825/#877/#892) is unreleased at the v0.9.4 pin.~~ **CORRECTED 2026-09-05: it shipped in v0.9.5 and is unreachable from Haven's pinned crates at every tag through v0.9.18 (§5.7) — so no bump fixes this.** This is a REAL residual risk of P4 with no test and no green-to-red gate today: the Haven-side control is **OD4-c** (§4, ~~open — force a `GroupUnrecoverable`-class re-invite~~ **DECIDED 2026-09-09: option (iv), keep removal-bearing auto-commits out of background bursts, AND option (i), the `GroupUnrecoverable`-class status plus a forced re-invite — L-121**, ~~or make a released-tag MDK bump a P4 precondition~~ ~~**or accept a named residual; the bump option is dead**~~ **the accepted-residual option (iii) was rejected outright and the bump option was already dead**), and ~~it must be decided before P4-7 claims the phase is complete~~ **the CODE must land before P4-7 claims the phase is complete: the decision alone closes nothing. The RUST code LANDED on 2026-09-09 — a burst parks the eviction instead of publishing it, and a wedged circle is named — so what P4-7 now waits on is (i)'s DART CONSUMER, which does not exist: the verdict is emitted and nothing reads it (L-133)**.** Coordinator bug leaving the engine `Live`: fail-safe for delivery, visible as the 55 s bars returning; P2c catches the standing-REQ case in CI. Rollback: one commit making the iOS pause branch not install the coordinator (three-state row back to keep-socket; standing REQ restored on iOS-bg); Rust additions inert when unused BUT the guard fixtures for `pause_subscriptions` and the `isPaused` source-order test revert with the Dart (they would otherwise be red); RC1 summary back, the invariant deleted (override item) and P0's "today's truth" sentence re-applied in M11/SECURITY — the SECURITY.md/M11 statement MUST revert in the same commit (it would otherwise overclaim; no user-facing copy is involved since the Privacy page's removal, 2026-08-29). Cursors are untouched; the standing REQ resumes from the persisted cursor (with P1's bounded lookback).

**Acceptance.** CI: all tests above; P2c green on `e2e-ios-background-publish`; both guards' self-tests; `check_privacy_invariants.sh`; l10n gates; `check_e2e_step_timeout_ordering.sh` with the re-derived budget. **LIVENESS gate (re-based, 2026-08-30 — §2.5):** P2c on `e2e-ios-background-publish` is the whole of it and is already CI-borne — Bob stays alive in-process, ~~`isPaused` holds~~ **the engine's POOL SUBSCRIPTION COUNT reaches zero between bursts and was non-zero in the foreground (CORRECTED 2026-09-08, P4-7 as landed — `is_paused` is raised as the first statement of the pause, before a single REQ is dropped, so it reads `true` through every state this gate exists to catch; see the P4-7 landed correction in the Design section)**, the decrypt marker lands (C7), and the burst ingests before it publishes; plus the grader over the lane capture. The burst is the mechanism most able to wedge receive (C2/C3/C5), and every one of those has a Rust or lane test in §6.3 — none needed a phone.
**POWER-MEASUREMENT gate (estimate-replaced, §2.5):** ~~Xcode Energy gauge networking bars only at publish instants; Battery ≤ ~1 %/h stationary over ≥ 3 h with P3 in place~~ → **ESTIMATED** from model E (§6.5a): closing the engine's standing socket on iOS-bg removes the last ≈ 55 keepalive wakes/h and the 15-min re-anchors, worth ≈ **0.2–1.1 %/h**, and takes the iOS background wake count from ≈ 150/h to ≈ 30/h — the publish instants themselves. Combined with P1 and P3 the ESTIMATED iOS stationary total lands at ≈ 0.4–1.6 %/h with a mid-range near 0.6 %/h — which straddles §6.6's "≤ 1 %/h" and is now openly labelled as its origin: a target derived from an estimate, not a threshold derived from a measurement.
**The CI-checkable proxy that must hold** (and it is a strong one, because it is the same claim stated structurally): ~~relay-side log shows one REQ/CLOSE pair per publish on circle relays, one per k bursts on inbox relays (OD4-b), and no traffic between~~ → this is exactly what the lane already asserts client-side — `background_burst_holds_no_standing_req`, ~~the P2c oracle "no `#p` REQ between bursts"~~ **the P2c oracle as landed, which is the engine's pool SUBSCRIPTION COUNT reaching zero between bursts (CORRECTED 2026-09-08): the `#p` REQ shape is NOT among the things the iOS lane checks, because the lane runs `tooling/e2e/local-relay`, whose only log lines are "listening" and "shutting down" (`main.rs:54,59`) — the recording wire proxy that WOULD journal them is started by the core-flow lanes (`e2e-ios.yml`, `e2e-android.yml`), never by this one. The inbox-REQ half is covered in-process by `a_burst_reissues_the_inbox_req_every_kth_burst`, not on the wire**, `a_burst_reissues_the_inbox_req_every_kth_burst`, and `check_engine_client_options.sh`'s `check_engine_pool_options`, check **(8)** (~~check 13~~ — that number exists in NO revision of this script; its numbered checks run 1–10, corrected to the symbol 2026-09-09) (`note_delivery_gap` not `forget_*`, `disconnect` not `shutdown`, no standing REQ from the burst entry). Application-level REQ/CLOSE/EVENT frames ARE recorded by the wire proxy, so the "one pair per publish, nothing between" shape is countable in CI; only the WS keepalive frames are not (`proxy.rs:20,1037`), and P4's whole point is that after it there are none to count.

**Owner decisions / open questions.** OD4, OD4-b, **OD4-c (~~OPEN~~ ~~DECIDED 2026-09-09~~ DECIDED AND THE RUST HALF LANDED 2026-09-09 — added 2026-09-05; crash-mid-burst recovery, §4; the owner took BOTH option (iv) and option (i) and rejected (iii), so P4 is not COMPLETE until that CODE LANDS — ~~which it has not~~ the Rust half did, the same day, and (i)'s DART CONSUMER did not, so the gate moved from the decision to the implementation and then to the half of it that faces the user; L-121, L-133)**, **OD4-d (~~OPEN~~ ~~DECIDED 2026-09-09~~ DECIDED AND LANDED 2026-09-09 — added 2026-09-08; P4-7's HAVEN_LIVE_SYNC flip left the POLL configuration of the iOS background branch with no real-OS-backgrounding coverage and no compensating control, and the owner bought the coverage back with a when-in-use/flag-off lane leg that ~~is in progress~~ shipped the same day, as the matrix's THIRD leg, asserting P2d in P2c's place at ~62 minutes; §4, L-122, L-126–L-130)**. **OD4-b is accepted but NOT YET IMPLEMENTED**: the shipped `INBOX_BURSTS_PER_REQ = 1` is this plan's placeholder, and raising k is implementing an accepted decision, blocked only on the foreground-re-anchor-closes-the-inbox-REQ defect (see the Privacy metadata statement). V-P4-1 → V (`Client::disconnect` mid-`send_event` yields `Err`, never a false confirm — `inner.rs:1255-1270, :1382-1389`; the gauge prevents the disconnect); I-P4-1 (5 s backlog wait vs typical strfry EOSE ~100 ms, `config.rs` §P-15 — expected never to bind; measure on the owner's relays); U-P4-1 (iOS `nw_connection` teardown on `disconnect` completes before the radio tail — hardware only → **NOT AVAILABLE (§2.5); bears only on how much of P4's ESTIMATED radio saving is realised, never on delivery**); U-P4-2 (`MockRelay` subscription introspection in `nostr-relay-builder` 0.44 — the client-side oracle is used regardless).

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
spread cap (D7 — the stagger constants do not move; only the WAKE is shared); ~~the last circle's fix age ≤ 33 s
(12 circles)~~ **AS SHIPPED: ≤ 30 s at `kMaxCirclesPerBurst` = 11** — 33 s is `maxSpreadFor(12)`, i.e. one circle past the
cap the draft did not yet have, and both figures are ≪ `kStreamPositionMaxAge`. The FGS keeps `PerCircleDueTracker` as
bookkeeping but seeds ONE shared due time
(`seedIfAbsent(all, from)`) and `markPublished` re-arms all keys from the same CSPRNG sample; `seedStaggered` is deleted.
Foreground and iOS-bg: the P4 coordinator receives one tick per interval; `locationPublishSchedulerProvider` keeps its
`_publishChain`/watchdog with one scheduler. No-gap invariant: every circle still publishes every ≤ 168 s + ≤ 30 s spread
(inside 30 s of margin, the other 30 s now spent by the burst spread) **for a roster up to eleven, which the roster bound
of 2026-09-09 makes every roster the app admits**; ~~`INV-W-445-EXPIRATION-WINDOW` stays true~~ **— the 60 s figure was
FALSE AS SHIPPED and is struck, 2026-09-09, rather than left to be contradicted by the paragraphs below that record what
actually landed.** That invariant STAYS `enforced`: an earlier revision of this tree moved it `enforced` →
**`ratcheted`** with an added residual for the past-eleven hole and named it as a NINTH `ratchet_override` item, and the
roster bound (`kMaxCirclesPerAccount` = 10) put that hole out of production reach, so the entry returned to the base
ref's rank and the item was deleted with the downgrade it allowed — **8 items now, not nine**. The working tree states
more and PROVES more at the same rank, which is why the return needs no override at all. What the bound does NOT close
is the 60 s → 30 s margin halving at every `N ≥ 2`, recorded in the `PUB-COALESCE` block — and **30 s is a worst-case
BOUND, not the margin at every roster**: the spread that spends it is `maxSpreadFor(n)`, so the margin is 51/42/33 s at
n = 2/3/4 and 30 s only from five circles up. Nothing on the wire changed; what changed is that the entry now states the
bound it always had. (This clause is not
covered by the "BOTH DRAFTS ABOVE ARE SUPERSEDED" header further down — that header is scoped to the two manifest
paragraphs, which is how this one survived.) `ttl.rs`'s `LOCATION_MESSAGE_RETENTION_SECS` doc / `SECURITY.md`'s "The no-gap invariant" prose re-worded.
Motion trigger unchanged (fires a burst through the same path).
**ROSTER BOUND — owner decision 2026-09-09 (§4 OD5-a, L-123), LANDED and reviewed on two planes the same day
(L-132), so read the paragraph above as the shape of the hole and this one as what closes it.** The account's circle roster is bounded at **10
circles** — `kMaxCirclesPerAccount`, beside `kMaxCirclesPerBurst = 11` in `publish_stagger.dart`, refused in
`NostrCircleService` at `createCircle` and `acceptInvitation` (the only two calls that grow a roster) as a typed
`CircleRosterFullException`, counting ACCEPTED memberships and failing CLOSED on an unreadable roster — so **no
circle is ever deferred** and the no-gap floor holds at every
roster the app admits. The argument is a **trilemma, not a one-liner**: a wide whole-second delta alphabet, no
retention hole, and large rosters are mutually exclusive, because the 30 s spread budget comes out of the retention
margin and the burst's *n − 1* gaps must fit inside it — a deferred circle's gap is two sampled intervals (144 s best,
**240 s mean**, 336 s worst) against the **228 s** retention, which is why most deferrals leave a peer's marker
expired, and it worsens to three intervals at 23–33 circles and four or more from 34 (L-100, L-101). **Rejected, with
reasons:** lowering the burst cap instead (it widens the alphabet but makes deferral, and therefore the hole, start
EARLIER); lengthening `LOCATION_MESSAGE_RETENTION_SECS` (events then live longer on relays — worse privacy, and D0
forbids the wire change); accepting the hole (a silent coverage failure a peer experiences as "their location stopped
updating"). **Costs, disclosed rather than hidden:** an eleventh circle is REFUSED — a new user-visible limit, with
its own copy in 13 locales — and the delta alphabet still thins with the user's own roster, `{2…9}` at four circles or
fewer down to `{2,3,4}` at ten. **Two quantities there, and they are NOT one number said twice:** the gap is SAMPLED in
milliseconds over `[2 s, maxGapFor(n)]`, which at ten circles is `2–3.333 s` (a 3333 ms ceiling); what an archive reader
can OBSERVE is the whole-second delta, whose alphabet at ten is `{2,3,4}` — three values, because the delta of two
floors reaches `ceil` of the ceiling rather than `floor` of it. Quoting the millisecond range as the alphabet, or the
reverse, is an error an earlier revision of this reasoning actually made. **What the bound does NOT retire:** `kMaxCirclesPerBurst` stays 11 and the burst arithmetic stays
exactly as pinned, so the cap-literal `{2,3}` assertion inside `expected whole-second delta alphabet, swept over every
burst size the app admits` now pins a burst size production can no longer reach — that is the deliberate one-circle
headroom, not dead weight, and the sweep keeps it. ~~**One manifest consequence the bound raises and this plan does not
settle for the packet that lands it:** `INV-W-445-EXPIRATION-WINDOW` was downgraded `enforced` → `ratcheted` precisely
because the no-gap floor fails past eleven circles; with the roster bounded at ten that reason no longer holds at any
reachable roster, so whether the entry is upgraded back — an upgrade needs no `ratchet_override`, per this section's
rollback note — is that packet's call, along with the residual text the entry carries.~~ **SETTLED BY THE PACKET,
2026-09-09:** the entry STAYS `enforced` — the rank it already carried at the base ref — and
`INV-W-445-EXPIRATION-WINDOW.status` was DELETED from `ratchet_override.items`, which is why the block holds **8** items
and not nine. The residual text stays and now states MORE than it did: the bound, and the propagation margin the burst
spread shares. Neither half of that is prose-only — a reviewer exercised the gate in BOTH directions on the landed
shape, so flipping the entry to `ratcheted` reds as an unstated weakening and keeping the item at `enforced` reds as a
stale allowance (L-132).
**Exact change list.** `publish_stagger.dart` → constants UNCHANGED; header re-worded (the stagger is the archive-adversary
defence — ~~distinct whole-second `created_at`s spread over eight values~~ **CORRECTED 2026-09-08: the shipped header states a
ROSTER-SCOPED alphabet — `{2…9}` to four circles, `{2,3,4}` at `kMaxCirclesPerAccount` (10), the largest burst a
bounded roster can produce, with `{2,3}` named only as `maxGapFor`'s next answer at `kMaxCirclesPerBurst` and
unreachable while the bound holds — never a flat eight, and no longer
calls the stagger "the archive-adversary defence" at all** — the schedule is no longer a privacy mechanism).
`location_publish_scheduler_provider.dart` → one scheduler; `_onTick` publishes `filterPublishEligibleCircles` in
`stagger.shuffled` order with `sampleGaps`; `trackedCircleKeysForTest` → `eligibleKeysForTest`. `per_circle_due_tracker.dart`
→ delete `seedStaggered`; header; `background_location_task.dart:1206-1222` seeds the shared time. `constants/location.dart`
header → ~~"one jittered burst per interval; circles staggered 2–9 s for distinct `created_at`s"~~ **AS SHIPPED
2026-09-08: "2–9 s" is the ceiling at a burst of four or fewer; the header states `maxGapFor`'s roster-scoped
alphabet and the `ceil(N ÷ 11)` service period instead**. ~~`haven-core/src/location/ttl.rs:63-66`~~
**the line citation DRIFTED — CORRECTED 2026-09-08 to the symbol, which is where the ladder now
sits: `haven-core/src/location/ttl.rs`'s `LOCATION_MESSAGE_RETENTION_SECS`**
doc; `SECURITY.md:584-587` (R12 sentence) rewritten + NEW subsection `#### Coalesced multi-circle publish bursts (PUB-COALESCE)`
under `### Publish cadence: jittered scheduler` (`:729`; heading `#### The no-gap invariant` `:787` untouched — manifest
anchor). `docs/privacy/privacy_invariants.json`: `INV-R-PER-CIRCLE-PUBLISH-DECORRELATED` → `status: "accepted_deviation"`,
`accepted_deviation_id: "PUB-COALESCE"`, `tests` replaced by the new burst tests (kept ≥ 1 so no `.unbacked`), statement
~~"Circles publish in one burst per interval, consecutive encrypts 2–9 s apart so no two circles share a kind-445
`created_at`; every relay carrying any of your circles sees the same burst rhythm, so relays each holding only ONE of
your circles can match the timing"~~ **SUPERSEDED BY WHAT SHIPPED 2026-09-08.** The landed statement is retitled
("One burst publishes every eligible circle; only the CSPRNG stagger keeps their created_at stamps apart") and states
three things this draft did not: the encrypts are `2 s`–`maxGapFor(n)` apart, not a flat 2–9 s; the surviving stagger
claim is roster-scoped and falls to a TWO-element alphabet at the cap; and the circle COUNT is a single-relay
observable in two shapes — a connect-to-disconnect DURATION and, separately, the signed `created_at` deltas; no disclosure key (the Privacy page was removed 2026-08-29; a zero-disclosure accepted deviation is a permitted state since then); NEW `accepted_deviations[]` entry
`{ "id": "PUB-COALESCE", "source": "haven-core/SECURITY.md#coalesced-multi-circle-publish-bursts-pub-coalesce", "summary": "shared-relay decorrelation was never effective while the multiplexed #h subscription and the single publish socket exist; with one shared tick sequence, circles on disjoint relay sets emit identical inter-burst intervals, so anyone holding two of your circles' relay archives can tell they belong to the same phone; the 2–9 s CSPRNG stagger is retained solely so archived events carry distinct timestamps", "forbidden_claim": "Copy must not present per-circle timing as preventing a relay from linking your circles, must not limit the linkage to relays that carry several of your circles, and must not present the stagger as more than distinct timestamps." }`;
`"ratchet_override": { "reason": "INV-R-PER-CIRCLE-PUBLISH-DECORRELATED is downgraded to accepted deviation PUB-COALESCE: per-circle schedules never decorrelated circles at a shared relay (multiplexed #h REQ, one publish socket) and cost one radio wake per circle per interval; the archive-timestamp defence is kept via the 2–9 s stagger. Owner decision OD3, <date>.", "items": ["INV-R-PER-CIRCLE-PUBLISH-DECORRELATED.status"] }`
**BOTH DRAFTS ABOVE ARE SUPERSEDED BY WHAT SHIPPED 2026-09-08 — read the manifest, not this paragraph.** The landed
`PUB-COALESCE` entry carries a much broader `summary` (all three costs of OD3, the per-plane split of the duration
carrier, the `maxGapFor` injectivity channel, and the twice-narrowed stagger claim) and a `forbidden_claim` that bans
three further things this draft did not: limiting the linkage to relays carrying SEVERAL of your circles, presenting the
stagger as more than a roster-dependent count of distinct stamps, and claiming a relay learns nothing about how many
circles you are in. And the landed `ratchet_override` carries **EIGHT** items, not one — the SEVEN OD-P3-g
disclosure-carrier moves plus `INV-R-PER-CIRCLE-PUBLISH-DECORRELATED.status`. ~~and a **new
`INV-W-445-EXPIRATION-WINDOW.status`**, because that invariant moved `enforced` → **`ratcheted`**~~ **CORRECTED
2026-09-09: there is no ninth item, and the eight-disclosure-move count was wrong too — the disclosure carriers are
SEVEN. An earlier revision of this same unmerged tree did add a ninth item and did move that entry to `ratcheted`, for
the past-eleven-circles hole; the roster bound (`kMaxCirclesPerAccount` = 10) put the hole out of production reach, so
the entry went back to `enforced` — the base ref's rank — and the item was deleted with the downgrade it allowed.**
Nothing about the wire changed, and the entry still states the bound it always had; what the `ratcheted` reasoning got
right is that **the ratchet reads neither a narrowed statement nor an added residual**, so a real regression there would
sit entirely in prose where CI never opens it — which is why the landed shape states more and PROVES more at the same
rank instead of buying the statement with a downgrade, and why a reviewer exercised the gate in both directions over it
(L-132). (Exact item ids per `check_privacy_invariants.sh`; the FIRST commit
after merge deletes the whole block, which is compared against the PR base and therefore goes stale on the next PR.) `INV-R-TRAFFIC-METADATA-OBSERVABLE` keeps citing `'the production stagger draws from a CSPRNG'`
(name kept verbatim). `docs/privacy/README.md` deviation list (+1, the
`jq` snapshot sentence); `P0_1_FGS_SESSION_PLAN.md:83,:453` (nonce-window/duplicate-publish reasoning now "one burst");
`CI_HARDENING_BACKLOG.md:1590`; ~~`haven/integration_test/e2e/e2e_combined.dart:297` "2–9 s" stays TRUE (record so nobody
"fixes" it)~~ **CORRECTED 2026-09-08: it does NOT stay true as a burst-wide statement.** 2–9 s is the ceiling only
while a burst holds four circles or fewer; at the cap the ceiling is 3 s. It remains true of that lane's own two-circle
fixture, which is a different claim, and the site is being re-scoped by the packet that owns it. Guards: none new; `check_publish_jitter_fraction_parity.sh` unchanged; NEW fixture in the
`publish_decorrelation_wiring_test` lint: `Random.secure()` still the RNG.
**Tests FIRST.** `test/lints/publish_decorrelation_wiring_test.dart` → the three manifest-cited tests are REPLACED (not deleted
first) by `every circle is published in one burst per tick`, `consecutive encrypts are ≥ 2 s and ≤ 9 s apart (gap sampled per pair)`,
`burst spread for N in 2..12 never exceeds maxSpreadFor(N), and maxSpreadFor(N) ≤ kPublishStaggerMaxSpread for N ≤ 11` (the
assertion that FAILS on a 2.5 s max gap — with `floorMs = min(minGap + 1 s, ceiling)` the cap could never engage and the
spread would be 2.5 × (n−1) unbounded by it), keeping `the production stagger draws from a CSPRNG`; the manifest `tests[]` lists
the new names in the same commit (rule 3). `publish_stagger_test.dart:125-144` → bounds UNCHANGED; ~~ADD `whole-second created_at
deltas take at least five distinct values over 1000 sampled gaps` (the fingerprint defence)~~ **AS SHIPPED 2026-09-08 it is
THREE tests, and the "at least k values" shape was deliberately rejected: it is exactly the shape that let the flat
eight-value claim stand while the alphabet at eleven circles was two.** The landed names are `whole-second created_at
deltas take all EIGHT distinct values over 1000 sampled gaps, at the DEFAULT burst size of two` (renamed to say what it
actually pins), `expected whole-second delta alphabet, swept over every burst size the app admits` (SET EQUALITY per burst
size, against a pinned table, plus a literal `{2, 3}` at the cap), and `the per-gap ceiling is the priced table, for every
burst size` (values not formula, and strictly decreasing from six circles up — which is what makes the span invertible
to `n`). The third lint name also landed differently: `a sampled burst never overruns its predicted spread, for every burst
size the app admits`, which is the name the manifest cites. "Gaps stay inside the per-gap ceiling" and CSPRNG tests
unchanged. `background_fix_request_test.dart`'s horizon pin is UNAFFECTED (decoupled in P2a —
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
follow-up commit; no copy anywhere (13 locales, the `locationDisclosure*` ARB keys — `LocationDisclosureStrings` was retired 2026-09-04 by OD-P3-g, `SECURITY.md`) still claims circles are unlinkable by
timing OR limits the linkage to shared relays; R10's ≥ 40 % CSPRNG jitter untouched; burst spread ≤ 33 s so a hung circle cannot
wedge siblings (`publishLinkTimeoutForTest` becomes load-bearing); the P2a horizon constant is untouched.
**Risks / rollback / acceptance.** Rollback = revert the Dart plane commit AND restore the manifest status (an UPGRADE needs no override —
restore, do not override) + PUB-COALESCE entry + SECURITY.md heading. Acceptance: ~~hardware~~ **ESTIMATED (§6.5a)** wake count ≈ 30/h for a
3-circle user (vs ≈ 90 under (b)). OD3 required before P5a-2.

#### Variant (b) — wake-sharing only (OD3 = NO; invariant intact)
**Goal.** Keep `INV-R-PER-CIRCLE-PUBLISH-DECORRELATED` enforced verbatim; share only the WAKE (and the access-gate read) when two
independent due times fall inside one stagger window. Battery: removes N−1 access-gate reads and timer wakes per coincident cycle;
radio wakes stay ≈ N × 30/h — state plainly in the P1/P4 docs that (b) is a CPU tidy-up, not the multi-circle radio fix.
**Design.** Foreground: replace N `JitteredScheduler`s with ONE `PerCircleDueTracker` (the FGS model) driven by a single master
tick armed at `min(nextDueAt) − now`; on fire publish `dueKeysUpTo(now + kPublishStaggerMaxSpread)` with the existing gaps
(`2 s`–`maxGapFor(n)`, so 2–9 s only while the due set is four circles or fewer — variant (b) shares the same sampler and
inherits the same roster-scoped alphabet)
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
Rollback = revert one file. Acceptance: ~~unchanged hardware numbers vs P4~~ → **unchanged ESTIMATED figures vs P4 (§6.5a: wake-sharing moves no wake count, so model E predicts no change); the win is CPU-only and is not estimated at all, because model E has no CPU term (E-P3).** No owner decision needed (default when OD3 is declined).

### 5.6 Phase P6 — Closure

**Goal / non-goals.** Nothing in P1–P5 may be committed with stale copy, a dangling manifest citation, a red gate, or an
unverified battery claim. P6 is mostly the per-phase **"lands together" matrix** (§6.1) that P1–P5's implementers execute
inside their own commits, plus what can only happen at the end: ~~the hardware acceptance run~~ **(DEFERRED, §2.5 — see
P6-B′)**, the coverage-floor re-pin from CI, the stale-override deletion and the final doc reconciliation. Non-goals:
no mechanism work; no new promise. **Amended 2026-08-30:** P6's "no unverified battery claim" rule *tightens* under
the constraint rather than relaxing — with every battery figure now an estimate, the closure sweep's job is to prove
that no estimate anywhere in the tree reads as a measurement.

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
| ~~Hardware acceptance~~ → **DEFERRED (§2.5)** | ~~Re-run `docs/POWER_MEASUREMENT.md` on the same two phones at the final commit (and, cheaper, after P2a and after P3 as intermediate gates — ≥ 3 h iOS S-window, ~2 h Android per run)~~ — no phones for the duration. `## Acceptance` in `POWER_MEASUREMENT.md` stays EMPTY; an empty table is the honest record of a measurement not taken, and filling it from model E would be a forgery (§5.0 Acceptance). P3's 0a is DEFERRED with its merge gate re-based (§5.3); P2b's forced-idle row is unmeetable and P2b is PARKED (§5.2). |
| **NEW — estimate-integrity sweep** → **now a GUARD, `scripts/ci/check_estimate_integrity.sh` (rewritten 2026-09-09)** | ~~Grep the whole tree for `%/h`, `mA`, "battery", "measured", "observed", "baseline"~~ — **that definition is the documented CAUSE of the misses this row exists to prevent.** A six-word grep cannot see a claim with no number in it, so two whole classes survived two manual sweeps: a **zero-cost verdict** (`SECURITY.md`'s "adding no extra battery cost") and a **directional claim** (two different terms each called "the dominant cost"). The rule is unchanged — every energy figure traceable to model E carries **ESTIMATED** in the same sentence, anchored to model E or §6.5a, and every DEFERRED proof says so where it is cited — but it is now enforced by a guard over **ten shapes**: `%/h`·`%/day`; mA/mAh; joules; wakes/h; a percentage beside a unit of time (a duty cycle is an energy figure — E-A1/E-A3 multiply it straight into `%/h`); a before/after pair of energy figures; a **zero-cost verdict**; a **directional claim** (a superlative predicated *of* an energy term); a causal energy assertion ("burning wakeups, and therefore battery"); and a measurement verdict over an energy term. Attribution must be a model-E anchor or a NAMED instrument from a closed list, and it must sit in the claim's OWN paragraph. 42 fixtures, both directions; it fails CLOSED on a root that matches no file and on an allowlist entry that has stopped matching. **`docs/` is deliberately NOT in the guard's scope yet, and that is a stated gap rather than a claim of completeness:** `docs/` is where the creep LANDS rather than where it starts (all three classes the adversarial review found were in code comments and test `reason:` strings), and §6.5a's own tables are thirty energy figures inside six Markdown rows, where the guard's paragraph unit corresponds to nothing — gating those needs a table-cell scanner, not a wider root list. Until one exists, `docs/` stays covered by this row's manual sweep, which is exactly the process the guard exists because of. |
| ~~M7 §6 item 0 re-run~~ → **DEFERRED (§2.5)** | ~~Owner: the P3-rewritten item executed on the physical iPhone under BOTH tiers plus the provisional row~~ — no iPhone. P3 (WP3-6) writes 0a/0a-provisional/0b/0c into M7 §6 in full, headed DEFERRED and still authoritative; **the ⚠️ RE-RUN REQUIRED banner STAYS** (it is removed only by a recorded pass, and there will be none). Nothing about the checklist is softened, shortened or moved — a deferred proof is an owed proof. |
| Floors | after the last mechanism phase's CI run: `gh run download <id> -n flutter-coverage-report` → `scripts/ci/check_coverage_floors.sh --repin flutter haven/coverage/lcov_filtered.info`; `gh run download <id> -n rust-coverage-report` → `--repin rust haven-core/coverage.lcov`; `--list` rows for any new file still missing one; then `--lint`. Never from a local run (local Flutter 3.41 ≠ pinned 3.44.8; local rustc 1.92 ≠ 1.97.1 — `check_coverage.sh` refuses the wrong rustc but a hand edit would not be refused). Artifacts expire in 30 days — download in the same week. |
| Stale overrides | delete any `ratchet_override` left by P5 (and any phase that needed one); `check_privacy_invariants.sh --baseline-ref origin/main` must report 0 declared overrides. |
| FA §7 | add "Unit H — Power (P1–P5)" with the per-phase mechanism, the **ESTIMATED** before/after rows (model E, §6.5a — ~~"the measured before/after rows"~~, **corrected 2026-09-09**: this row asked for measurements four lines below the sweep that forbids them, and Unit H as shipped says so in its own preamble — "every energy figure below is ESTIMATED, and none of it was measured"), and the wedge-regression tests (§6.2) — in full, not a stub. |
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
| ~~P6-B~~ | ~~Hardware acceptance run (owner) + fill template~~ — **NOT AVAILABLE (§2.5)** | ~~after the last mechanism phase~~ |
| **P6-B′** — **EXECUTED 2026-09-08 (L-119)** | Estimate-integrity sweep (change list above) + confirm `POWER_MEASUREMENT.md`'s `## Baseline` and `## Acceptance` tables are still empty and its deferral banner still accurate + re-read §6.5a against the phases as they actually landed (if a phase shipped differently, the model's inputs move and the ESTIMATED table is re-derived in this commit). **Outcome:** `## Baseline` empty and no `## Acceptance`/`## Merge gate`/`## Deferred proof` section exists at all (recorded there as the state, not an omission); banner corrected — it named only the missing macOS machine and iPhone; §6.5a re-read against P3-as-shipped (E-I10 gains OD-P3-e's anchor cap, no row moves) and P5(a)-as-shipped (a row of its own, unchanged at one circle by construction) | after the last mechanism phase; ONE commit with P6-C |
| P6-C | Floors re-pin from the final CI run + stale-override deletion + FA Unit H + README/CLAUDE.md/M11/SECURITY touches | after P6-B's CI run; ONE commit |
| ~~P6-D~~ | ~~M7 §6 item 0 re-run (owner, physical iPhone, both tiers)~~ — **DEFERRED (§2.5)**; the checklist is written by WP3-6 and stands owed, banner intact | ~~before release~~ → when hardware returns |

**Reviewer checklist (second wave, all phases).** Diff the manifest: every new invariant cites tests/guards that EXIST (grep), no `accepted_deviation`
carries an assertion key, every new `doc_anchors`/`source` fragment is a real heading, `SELF_TEST_FIXTURES` equals the fixture count. Every ARB key
touched appears in 13 files with placeholders intact; translator/reviewer transcripts show reasoning per language and the reviewer received the gating facts. Every re-worded claim has a
copy-tie test whose forbidden list would catch the OLD sentence (plant it and watch it fail). No lane window widened; every replaced assertion is at
least as strong (read the test body, not its name). Presence-only logging in every new native file (lists updated; a planted coordinate log AND a planted `Log.e(TAG, "x", e)` fail).
~~Hardware rows exist and the relay-side liveness column is ≤ 228 s (≤ 188 s after P2a) in every accepted run.~~ **AMENDED 2026-08-30 (§2.5): there are no hardware rows.** ~~Instead: the grader ran with `--publishers` and a DECLARED window over every phase lane's capture and exited **0**.~~ **THAT REPLACEMENT RE-COMMITTED THE ERROR THIS PLAN HAD ALREADY NAMED AND DATED — struck 2026-09-09.** No lane exports a capture to the grader (§5.6 Acceptance; §5.1's LIVENESS block lists the four pieces that would close it), so "the grader ran over every phase lane's capture" is a checklist item no reviewer can satisfy — and §6.5a states the lesson in as many words: "stating it as a requirement while no phase can meet it is what produced a gate that was simultaneously required and impossible." **What a reviewer checks instead:** that no commit REPORTS the LIVENESS clause as MET (nobody may, until a lane feeds the grader a capture), and that wherever a capture IS graded — by hand off a phone, or by the first lane to add the export step — the run was GRADED (`--publishers` **and** a declared `--from`/`--until`) and exited **0**, with the bound read PER API LEVEL and **never as a tighter post-P2a figure** (this sentence carried "≤ 188 s after P2a" until 2026-09-08; §6.5 retracted that number on 2026-09-04 as an artefact of a σ = 0 sweep; the bound is ≤ 228 s on iOS and API 31+, ≤ 248 s on API 23–30 as D3 (iii)'s ACCEPTED cold residual, and ≤ 198 s is the post-P2a acceptance figure for API 31+ only — so a row records its API level or the number means nothing; and the iOS 228 s is a ONE-CIRCLE bound, which is all `POWER_MEASUREMENT.md` control 3 admits — `constants/location.dart` derives 238 s for iOS once a burst spread enters the realized gap) — check the exit code, not the printed number. And: no energy figure anywhere in the diff appears without **ESTIMATED** in the same sentence, which since 2026-09-09 is enforced by `scripts/ci/check_estimate_integrity.sh` over code and CI rather than by the P6-B′ sweep alone (`docs/` is still the sweep's, by the stated scope gap). `git diff` of `coverage_floors.txt` contains only `--repin`/`--list` output.

**Risks / rollback.** A phase merged with its matrix row half-done (copy in English only; a guard step without `--self-test`; an override left
stale) — the reviewer checklist is the merge gate. Rollback of P6-proper: revert the closure commit as a WHOLE (floors reverting DOWN is exactly
what `--repin` forbids — never partially).

**Acceptance.** CI-provable: all gates green on `main` with 0 ratchet overrides; new guards enforce (not self-test-only — rule 6b); matrix lanes
green on the final commit. ~~Hardware: §6.6 thresholds.~~ **AMENDED 2026-08-30 (§2.5): §6.6's LIVENESS row (grader exit 0, ≤ 228 s over a
declared window — never a tighter post-P2a figure: D3 (iii)'s accepted residual reaches 248 s on API 23–30) is the only failable acceptance clause; its POWER-MEASUREMENT rows are ESTIMATED predictions paired with CI proxies, and the P6-B′
estimate-integrity sweep is what closes them.** **Read that with §6.6's own row, and re-verified 2026-09-08 by
P6-B′: the only failable clause is not wired to anything.** No lane exports a capture to the grader — its sole
invocation in the tree is `--self-test` in `repo-guards.yml`, which proves the instrument and not any build — so
the clause is failable in principle and inert in CI. What actually reds a P6 commit is the mechanism half: the
per-phase CI proxies of §6.6's right-hand column (B1's parsed `dumpsys` oracles, the bg-publish lane's tier and
session oracles, the no-standing-REQ tests), the guards, and 0 ratchet overrides. Nobody may report the LIVENESS
clause as MET until a lane feeds it a capture (§5.1's LIVENESS block lists the four pieces).

**Owner decisions / open questions** (line rewritten 2026-09-08 by P6-B′ — it listed eight rows as open that §4
records as ACCEPTED on 2026-08-29, and omitted both rows that are). ~~**OPEN:** **OD4-c** — the crash-mid-burst
control, option (i) `GroupUnrecoverable` + re-invite or a named accepted residual; gates P4 being called COMPLETE,
not its landing. **OD4-d** — buy back the flag-off iOS background coverage or accept the gap; **no gate**, the lane
is green either way. Those are §4's only two open rows (§9.9 indexes both).~~ **BOTH DECIDED 2026-09-09, and §4 now
carries NO open row.** **OD4-c** was taken in BOTH halves — option (iv), keep removal-bearing auto-commits out of
background bursts, AND option (i), the `GroupUnrecoverable`-class status plus a forced re-invite, with option (iii)
rejected — and its RUST CODE LANDED the same day (L-133) while (i)'s DART CONSUMER did not, so it still gates P4 being called
COMPLETE: the gate moved from the decision to the implementation, and then to the half of the implementation the user
can see (L-121). **OD4-d** was taken by buying the coverage back — a lane leg on `when-in-use` with the
flag off — and it LANDED the same day, as the matrix's THIRD leg, running P2d where the live-sync legs run P2c
(L-122; the implementation's own five decisions are L-126–L-130). Three further decisions of the same date are NEW §4 rows and belong to phases other
than P6: **OD5-a** (the roster is bounded at 10 — L-123), **OD-P2-4** (P2b's forced-idle gate holds 228 s — L-125) and
**OD-P4M-1** (do not bump MDK while its OpenMLS is an untagged fork head; the gate is a tagged OpenMLS — L-124). **DECIDED 2026-08-29, not open:** OD1,
OD3, OD4, OD4-b, OD-P2-2, OD-P2-3, OD-P3-b, OD-P3-c — of which OD-P2-2 and OD-P2-3 travel with **PARKED** P2b
(§5.2), which needs one Android handset and not a decision. **RESOLVED, not open:** V-P1-4 (the banner timer does
fire while backgrounded — P1-A3, §7.5) and U-P0-1 (the Android-15 6 h `location` FGS-timeout claim is FALSE, not
merely unverified — L-39, §5.0). **Still standing:** U-P0-2 (goldfish GPS navigating — CI never depends on it).
Outside the P0→P6 chain, and therefore outside this phase: the P4M flag day (§5.7 P4M-2) and the untagged-OpenMLS
supply-chain question (L-94) — **the second of which was DECIDED on 2026-09-09 (do not bump while the anchor is a
branch head; unblock = a tagged OpenMLS; §4 OD-P4M-1, L-124), which leaves the flag day itself as the only untaken
decision of the pair, now behind that gate.**

---

### 5.7 Milestone P4M — MDK v0.9.4 → v0.9.18: a coordinated WIRE migration, not a dependency bump [owner-scoped 2026-09-05; OD4-c]

**Read the name literally, and do not shorten it in conversation.** Calling this "the MDK bump" is the single
most dangerous thing anyone can do to it. Nothing here resembles raising a `Cargo.toml` rev: the five pinned
crates change by +80,616 / −10,264 lines, the account identity proof moves to a different on-wire carrier, every
`Group` this pin has ever written is classified `Legacy` and **refused at session open** by a release build that
has no opt-out, and 33 forward-only storage migrations run the first time `open_encrypted*` is called with no
dry-run and no `down`. It is a coordinated flag day for every circle and every member. Every fact below was
verified on 2026-09-05 against a full bare clone of `marmot-protocol/mdk` with **both** endpoints extracted via
`git archive`, plus `gh api`; Haven's pinned rev `e391adc` is byte-identical to tag `v0.9.4`. Where a claim was
not verified it says so, in the same sentence.

**Sequencing — decided here, and the decision is "not next".** P4M runs **after P6 closes, outside the P0→P6
chain**, and never before, nor beside, P4 or P5. Three reasons, each sufficient on its own:

1. **It cannot be P4's precondition.** That is exactly what OD4-c option (ii) proposed, and the central finding
   below kills it: the epoch-gap backfill is unreachable from Haven's five crates at **every** tag on the
   ladder, so gating P4 on a released tag buys P4 nothing and costs a flag day. OD4-c's row in §4 is corrected
   accordingly.
2. **It cannot run beside P4 or P5.** The bump moves the precise surfaces those phases are built on:
   `IngestOutcome` 3 → 8 variants, `StaleReason::PeelFailed` REMOVED with five more variants deprecated-and-no-
   longer-emitted (`OwnEcho` among them — the variant OD4-c's analysis turns on), `GroupEvent::ForkRecovered`
   removed, a NEW `PublishWork::FoundingGroupCreated`, and `expiration_timestamp()`'s return type changed.
   Landing them concurrently means re-reviewing every burst assertion in §5.4 and every coalescing assertion in
   §5.5 against an engine that is moving underneath them — and a red test in that window belongs to nobody in
   particular, which is how the FA wedges were born.
3. **It delivers no power saving at all.** Not one item in the gains list below is an energy item. P4M is
   recorded in this document because this plan is the project's single sequencing record and because OD4-c
   named the bump — not because it belongs to the power programme. §6.5a's model is untouched by it, and P6's
   estimate-integrity sweep has nothing to sweep here.

**Goal / non-goals.** Goal: move all five pinned crates from `e391adc` (v0.9.4) to `f734b31` (v0.9.18) in ONE
commit, re-create every circle onto `ProtocolProfile::Current` under an owner-accepted flag day, and delete the
direct `openmls` dependency the bump makes redundant. Non-goals: a partial bump (`libsqlite3-sys` is a
`links = "sqlite3"` crate — exactly one version per graph — so bumping some crates is a link error, not a
degraded build); adopting `marmot-app` / `marmot-account` / `transport-nostr-adapter` (the rejection in
`haven-core/Cargo.toml:52-53` and `check_mdk_supply_chain.sh` check 1 stands, and this migration does not
re-open it); harvesting any gain early (nothing on this ladder is separable from the profile cutover); any
power, wire-cadence or promise change beyond the carrier move the cutover forces.

**The ladder (V, complete).** v0.9.4 `e391adc` 2026-07-10 (Haven's pin) → v0.9.5 `5729f6c` 07-25 → v0.9.6 07-26
→ v0.9.7 07-26 → v0.9.8 07-27 → v0.9.9 07-28 → v0.9.10 07-29 → v0.9.11 08-10 → v0.9.12 08-13 → v0.9.13 08-18 →
v0.9.14 08-19 → v0.9.15 08-25 → v0.9.16 09-01 → v0.9.17 09-02 → v0.9.18 `f734b31` 09-05. 452 commits; **166
non-merge commits touch the five pinned crates**. Diffstat over those five: `cgka-engine` +45,908/−7,299;
`storage-sqlite` +27,317/−2,394; `cgka-traits` +5,844/−418; `cgka-session` +1,182/−103;
`transport-nostr-peeler` +365/−50. **No CHANGELOG exists for any of the five**, so every claim in this section
came from reading the diff, and any claim a future reader adds must too.

**THE CENTRAL FINDING — the motivation for bumping is unreachable, at every tag.** Both commit-loss PRs first
ship in **v0.9.5** (#825 = `363b1fe3`, #892 = `e6654ece`) — so "unreleased" was already stale — but **both land
almost entirely outside Haven's five pinned crates, and #892 touches ZERO of them.** #825's
`CursorPersistence{Advance,Frozen}` policy lives on `MarmotAppConfig` in **`marmot-app`**, the crate
`haven-core/Cargo.toml:52-53` rejects by name and `scripts/ci/check_mdk_supply_chain.sh` hard-fails on. **No
version on this ladder makes either reachable.** Two consequences, both of which must be carried wherever the
old claim was:
- **RE-CORRECTED 2026-09-08 — THE THREE FINDINGS BELOW SUPERSEDE THIS SECTION'S CENTRAL CLAIM.**
  **(1) The ladder has NO cheap rung: every element of the migration cost is already present at v0.9.5, the FIRST
  tag after the pin, not at v0.9.18.** The strict profile cutover is `c2a4c2a6` (v0.9.5): `EngineBuilder::build()`
  refuses a `Legacy` engine, `legacy_compatibility_profile()` is `#[cfg(debug_assertions)]` on BOTH `EngineBuilder`
  and `SessionConfig`, and `AccountDeviceSession::open` has an explicit `#[cfg(not(debug_assertions))]` refusal —
  **no release-build opt-out, confirmed at v0.9.5 AND v0.9.19.** `retire_non_current_key_packages()` runs
  UNCONDITIONALLY on open from v0.9.5, destroying the private half of every published kind-30443, so an in-flight
  Welcome addressed to a pre-bump KeyPackage becomes permanently undecryptable. Migrations are forward-only with
  NO `down` at any tag and `reject_unknown_future_migrations` already at v0.9.4, so irreversibility starts at
  v0.9.5's first 9 migrations (26 → 35; v0.9.18 = 59; v0.9.19 = 64). **The decision is binary at step one.**
  **(2) The membership freeze is narrower than "circles stop working", and that is a TRAP, not a comfort.** Legacy
  groups are NOT quarantined: location `AppMessage`s, removals, leaves and `UpdateAppComponents` all keep working;
  ONLY `Add` is blocked (upstream: *"Strict cutover freezes membership growth in legacy groups"*). So every E2E
  lane that merely sends locations stays GREEN on a silently membership-frozen circle. Cross-version invitations
  break in BOTH directions during any rollout window.
  **(3) NEW, and stated nowhere in this plan before: from v0.9.5 the MDK workspace abandons crates.io OpenMLS for
  a PERSONAL FORK AT AN UNTAGGED BRANCH HEAD.** v0.9.4 uses `openmls = "~0.8.1"`; v0.9.5→v0.9.19 use
  `git = "https://github.com/erskingardner/openmls.git", rev = "59e7d3b2…"`, which is the head of
  `refs/heads/codex/reject-app-data-trailing-bytes` on a fork carrying **no tags at all** — force-pushable and
  deletable. CLAUDE.md's pinning rule exists precisely because "a released tag is the only acceptable
  supply-chain anchor", so the bump transitively abandons that for the MLS implementation itself, and it collides
  with Haven's own direct `openmls` dependency (`relay::maintenance::kp_lifetime`), which must be deleted or
  repointed at the same fork to avoid two OpenMLS crates in the graph. **This is an owner-level supply-chain
  decision, not an implementation detail, and it is arguably a harder blocker than the flag day.**
  **What the bump WOULD buy, which this section wrongly said was nothing** (all in pinned crates): OD4-c's fix
  (§4, v0.9.5 `b5297d4d`, opt-in); **v0.9.11 `8cfd2667` (#1341) the sender-ratchet reorder policy** —
  `out_of_order_tolerance` 5 → 100 and `maximum_forward_distance` 1000, plus an in-place `set_configuration`
  repair at hydrate for existing groups, i.e. the upstream half of the "ratchet 1000" wedge in
  `docs/BACKGROUND_SHARING_FAILURE_ANALYSIS.md`; **v0.9.11 `2c3eb1e6`/`cb138622`/`03b03eb5` bounded convergence
  retention** (`TransportDeferredCapacity`, `MAX_DEFERRED_PEEL_ATTEMPTS = 32`, 30-day residence), which directly
  answers the Security-Rule-12 caveat in CLAUDE.md that the engine "has no per-group cap and no eviction API";
  **v0.9.11 `7e5a3048` (#1246)** app sends during `PendingPublish`/`Merging`/`Recovering` return `Queued` instead
  of an illegal-transition error (the "stuck Created row gating sends" wedge); and **v0.9.11 `dcf27f22` (#1333)
  explicit storage close**, written for iOS `RUNNINGBOARD 0xdead10cc` SIGKILLs from suspending while holding a
  WAL `-shm` lock — directly load-bearing for P3/P4's premise. Wire-facing invariants are UNAFFECTED at every
  tag: `DEFAULT_EXPORTER_LABEL = "marmot/group-event"` and the `with_exporter_label` override are unchanged
  (Rule 11 and its guard stay exactly as relevant), and `DEFAULT_MAX_PAST_EPOCHS` is still 5 (Rule 5).
  **One silent-regression trap to gate any bump on:** `IngestOutcome` gains `TransportDeferred` and
  `ResourceRefused`, which are UN-APPLIED verdicts. The enum is not `#[non_exhaustive]`, so
  `catchup.rs:1031-1034` and `live_sync/processor.rs:753-760` fail loudly — good — but folding the new variants
  into the `Stale`/`Applied` arms rather than the `Buffered` arm would advance the cursor past events the engine
  could not peel. That is silent location loss, and it is the one thing to gate on beyond the flag day.
- ~~**Migrating does NOT resolve OD4-c.**~~ **FALSE — see the re-correction above.** Option (ii) — "gate P4 on a released MDK tag containing the epoch-gap
  backfill" — is **DEAD, not merely unattractive**: the tag exists and the fix is still out of reach. OD4-c
  collapses to option (i) (the Haven-side `GroupUnrecoverable`-class status and forced re-invite) or to an
  explicitly accepted, named residual. §4's row is corrected; §5.4's Design and Risks notes are corrected.
- **Haven's in-flight hand fix for the burst cursor hole is NOT duplicated work**, and must not be paused "until
  the bump lands". Nothing on the ladder replaces it.

**The five blockers.** None is a "risk" in the register sense — each is a thing that is true today and must be
answered before a single line changes.

| # | Blocker | Verified shape | What it costs |
|---|---|---|---|
| B1 | **openmls moved to a personal git fork** | `github.com/erskingardner/openmls`, rev `59e7d3b2` — an unreleased COMMIT, not a tag; feature renamed `extensions-draft-08` → `extensions-draft` | Cargo does not unify a registry package with a git package, so Haven's direct crates.io `openmls ~0.8.1` would create **two `openmls 0.8.1` builds = two MLS type universes** — precisely what `haven-core/Cargo.toml:85` forbids in writing. It also splits the RustCrypto stack (V in the upstream `Cargo.lock`: sha2 0.10.9 **and** 0.11.0, hmac 0.12.1/0.13.0, hkdf 0.12.4/0.13.0, digest 0.10.7/0.11.3). And it conflicts with Haven's own anchor rule — "released tags only, never a master HEAD" — one level down. **Dissolves for the DIRECT dep if Haven deletes it (see gains); it does NOT dissolve for the transitive graph, which still resolves an unreleased fork commit.** **AND SINCE 2026-09-09 THIS IS THE MILESTONE'S PRECONDITION, not one blocker of five: the owner's decision is DO NOT BUMP while the anchor is an untagged branch head, the unblock condition is a TAGGED OpenMLS, and the action is to raise it upstream (§4 OD-P4M-1, L-124)** |
| B2 | **rusqlite 0.32 → 0.40.1, libsqlite3-sys 0.30 → 0.38.1 (a git rev)**, upstream carrying two `[patch.crates-io]` entries | `links = "sqlite3"` ⇒ exactly one version per graph; `circles.db` / `tiles.db` share the pin (`MARMOT_PROTOCOL_KNOWLEDGE.md`, crate-set constraints) | A partial bump is an immediate link error. **I (standard Cargo semantics, not read off the tree): `[patch]` is not inherited through a git dependency**, so Haven would resolve `libsqlite3-sys` from crates.io and inherit the SQLCipher mlock WARN spam upstream patched away — **on Android specifically**, which is where the log surface is user-visible in `logcat` and where presence-only logging is guard-checked |
| B3 | **The profile cutover — a WIRE BREAK that permanently freezes membership on every existing circle** | `ProtocolProfile { Legacy, Current }` is NEW (`traits/src/group.rs:25-31`; absent at v0.9.4). `Group.protocol_profile` is `#[serde(default)]` ⇒ every circle Haven has written loads `Legacy`. `SessionConfig::new` defaults `Current`; `AccountDeviceSession::open` **REJECTS** a `Legacy` session; the escape hatch `legacy_compatibility_profile()` is `#[cfg(debug_assertions)]` — **absent from release builds, so Haven cannot opt out where it matters**. Adding a member to a legacy group is rejected on SEND (`send.rs:154`, `mod.rs:533`, `mod.rs:710`) AND on RECEIVE (`ingest.rs:1256`, `:1628` → `terminalize_rejected_proposal`). Welcomes across the boundary are refused (`group_lifecycle.rs:1101-1102`). Every open also calls `retire_non_current_key_packages()` | An un-upgraded peer who adds a member advances to epoch N+1 while upgraded Haven stays at N — **permanent per-circle divergence**, not a transient fork. The `retire_*` sweep DELETES the device's own KeyPackages whose leaf proof classifies legacy, so published kind-30443s become unusable and in-flight Welcomes targeting them can never be processed (the `d`-slot machinery of `MARMOT_PROTOCOL_KNOWLEDGE.md` cannot save them — the material is gone). Location updates on EXISTING circles keep working (`app_components.rs:803-805` early-returns `Ok` for `Legacy`), which is the trap: the app looks healthy while membership is frozen. **There is no in-place upgrade path.** Migration = re-creating every circle with fresh Welcomes to every member; group history is lost; every member must be online AND upgraded. A coordinated flag day, and the only kind of change in this project that a user can neither see coming nor undo |
| B4 | **A SILENT break at two call sites** | `haven-core/src/circle/manager.rs:3731` and `haven/rust_builder/src/api.rs:12703` are `if let PublishWork::GroupCreated { welcomes, pending } = work`. From **v0.9.9** current-profile creation returns a NEW variant `PublishWork::FoundingGroupCreated { welcomes }` carrying **no `PendingStateRef`** | An `if let` that stops matching **compiles clean and silently does nothing**: circle creation would produce no publish work and no error. The three `match` sites (incl. `manager.rs:2593`) fail loudly instead — the compiler protects the wrong half of the tree. Rule 13 impact, and it is structural: with no `pending` there is nothing to `confirm_published`, so Haven's publish-before-apply-on-create contract and the E2E invariant "`createCircle` without `confirmPublished` pins the group in `PendingPublish`" (the `createCircleConfirmed` helper and its CI guard) become **profile-dependent** rather than absolute |
| B5 | **33 forward-only storage migrations; downgrade refused BY DESIGN** | 26 → 59, contiguous; all 26 originals byte-identical (append-only). `migrations::run_all` runs unconditionally **inside connection open** — merely calling `open_encrypted*` migrates the user's database. No dry-run, no opt-out, and **no `down` functions at all**. `0047` drops and rebuilds `cgka_messages` (content-preserving, structurally irreversible); `0057` has an EMPTY `apply` whose only purpose is to erect the downgrade gate (MLS values now carry a MessagePack prefix v0.9.4 cannot decode); v0.9.4 opening a v0.9.18 DB errors | **Rollback is not a revert** (§6.4's one-commit rule does not reach this milestone). A rollback build must WIPE and re-provision the MLS DB — i.e. re-join every circle — which is the same user cost as the forward flag day, paid twice. **Coverage gap, V: upstream's oldest migration fixture is already at migration 46**, so Haven's real 26 → 59 path is **untested upstream** and Haven must build a v0.9.4-written fixture before running the chain on anyone's device |

**`0x8009` — YES, adopted; this IS the wire migration.** `ACCOUNT_IDENTITY_PROOF_COMPONENT_ID = 0x8009`
(`traits/src/app_components/mod.rs:106`) does not exist at v0.9.4 (grep returns empty). `0xF2F1` survives only
as the legacy classifier, with explicit mixed-carrier rejection — the same `Legacy`/`Current` mechanism as B3,
which is why the identity-proof carrier and the membership freeze are one change and not two.
`MARMOT_PROTOCOL_KNOWLEDGE.md`'s identity-proof section carries the corrected record and flags the two sites
(its MLS-configuration leaf list, and `CLAUDE.md:243`) that P4M must rewrite **in the bump commit and not
before** — both are correct today.

**What Haven gains.** Real, and none of it is power:
- **`IngestEffects.left_object_unpersisted` + `Engine::last_ingest_left_object_unpersisted()`** — documented
  upstream as NOT derivable from `IngestOutcome`, and the highest-value API on this ladder for cursor work:
  it is the direct answer to "may I advance past this?", which Haven currently infers.
- **`DeferralLineage { Uncontested, ContestedFork }`** — says whether a relay backfill can help at all.
- **The NIP-77 transport-reconciliation substrate** (`transport_reconciliation.rs` + migration `0054`), NEW in
  the pinned `storage-sqlite`, repairing history below a `since` floor **without trusting timestamps** — the
  class of defect §5.4's burst cursor hole belongs to. Honest caveat: the reconcile **DRIVER** lives in
  unpinned `marmot-app`, so Haven inherits the substrate and would write the driver.
- **`EngineError::privacy_safe_kind()`** — an upstream-owned redaction surface beside Haven's
  `redact_hex_sequences` (bears on #864's subject; #864's own state is UNVERIFIED).
- **Convergence-based fork resolution** replacing the deleted `fork_recovery.rs` (609 lines, #1293, v0.9.12),
  and two durable pre-peel dedup tables.
- **The one real deletion: `KeyPackageMetadata` went 2 → 9 fields, including `not_before` / `not_after`.**
  Haven's direct `openmls` dependency exists for **exactly that one reason**
  (`haven-core/Cargo.toml:69-96` — the rationale block and the two deps it justifies, `relay::maintenance::kp_lifetime`), so it can go — which also dissolves B1
  for the direct dep and removes the `~0.8.1` + `extensions-draft-08` feature-matching obligation from the
  manifest.

**What Haven canNOT delete — record these so nobody re-scopes the milestone on hope.** All three were the
obvious "the bump lets us throw this away" candidates, and all three are wrong:
- **The convergence send-gate re-implementation stays.** V by exhaustive grep over v0.9.18:
  `gating_convergence_inputs` and `retire_convergence_input` **do not exist**;
  `discard_queued_outbound_intents_for_removed_group` is still `pub(crate)`; `Engine::storage` is a private
  field with **no public accessor**. Haven's second `SqliteAccountStorage` on the live session DB,
  `scan_group_inputs`, `convergence_rewind_for_group`, `gating_projection`, the sweep family,
  `pending_proposal_in_window` and the discard helpers all keep their subject. Still a live upstream ask worth
  filing — it is the one item here where an upstream issue would pay for itself.
- **The epoch-rotation repair subsystem (~1,500 lines, `haven-core/src/circle/rotation.rs`) stays.** V:
  OpenMLS's `SenderRatchetConfiguration::default()` is `new(5, 1000)` — `out_of_order_tolerance` 5,
  `maximum_forward_distance` 1000. v0.9.4 sets **neither** (grep empty), so the defaults apply. v0.9.18 sets
  both at `wire_format.rs:53,57`: tolerance **5 → 100**, forward distance **1000 → 1000, UNCHANGED**.
  `rotation.rs:6` names `maximum_forward_distance` as its subject. **The knob the subsystem exists for did not
  move.**
- **The Rule 12 intake cap stays** — #757 CONFIRMED still OPEN (`gh api` 2026-09-05, `{"state":"open"}`). The
  caps that did tighten govern the separate `PeelDeferred` store, not the stored-convergence buffer.

**Other breaking changes to record** (each is a compile break, a silent break, or a behaviour change Haven's
tests assert on today): `IngestOutcome` 3 → 8 variants; `StaleReason::PeelFailed` REMOVED and five variants
deprecated-and-no-longer-emitted (incl. `OwnEcho` — which §5.4's OD4-c analysis reasons from);
`GroupEvent::ForkRecovered` removed; `GroupMessageMetadataError` deleted and `expiration_timestamp()` changed
from `Result<Option<u64>, _>` to `Option<u64>` — **a SILENT break wherever it is used with `?`**;
`EngineBuilder::build()` now hard-rejects a non-default `max_past_epochs` without a test feature;
`compare_scores` drops the `valid_commit_depth` tie-breaker, so identical inputs can select a **different branch
winner** (Haven's convergence e2e oracles assert on winners); session open now hydrates ALL stored groups unless
deferred, making open cost O(stored groups) — an app-launch latency change, on the path Rule 14 serialises;
kind-445 tags now strictly validated **pre-decryption** (exactly one lowercase-hex `h`, at most one
`expiration`, nothing else — Haven already emits exactly this shape, but **hand-built test fixtures must be
lowercase**); expiration overflow now silently OMITS the tag instead of failing the wrap, so the clock-skew
lanes must assert the tag's PRESENCE, not merely a successful publish. MSRV `rust-toolchain.toml` 1.90.0 →
**1.97.1** (the coverage toolchain pin in `scripts/ci/coverage_toolchain.env` moves with it, floors re-pinned in
the same commit per §5.6 rule 5). **Rule 11 is fully safe, V**: the peeler's nonce handling is a zero-diff,
`DEFAULT_EXPORTER_LABEL` is unchanged, and `with_exporter_label` still exists at `peeler.rs:60` — so
`check_no_exporter_label_override.sh` remains both necessary and sufficient, and must not be retired as
"obsolete after the bump".

**Exact change list.** `haven-core/Cargo.toml` → five revs `e391adc` → `f734b31` in one edit, the pin comment
rewritten to name the released tag **v0.9.18** and the fork-openmls consequence, the direct `openmls` /
`openmls_rust_crypto` deps DELETED with their rationale block (the lifetime now comes from
`KeyPackageMetadata`), `rusqlite`/`libsqlite3-sys` re-unified across `circles.db`/`tiles.db`, MSRV. →
`haven-core/src/relay/maintenance/kp_lifetime.rs` reads `not_before`/`not_after` off `KeyPackageMetadata`. →
every `IngestOutcome` / `StaleReason` / `GroupEvent` match site (`live_sync/processor.rs`, `manager.rs`,
`location_result_from_event`) exhaustively re-matched — **no `_ =>` arm may be added to absorb the new
variants**, because absorbing them is how a cursor advances past an unapplied event. → **B4's two `if let`
sites converted to `match` before anything else compiles**, so the new variant fails loudly.
→ `expiration_timestamp()` call sites de-`?`-ed. → `security_rule_gates.rs` re-pinned (incl. the OWED
`max_rewind_commits` pin from §5.4, which becomes mandatory here since `EngineBuilder::build()`'s new rejection
touches the neighbouring constant). → `scripts/ci/check_mdk_supply_chain.sh` gains a check that the graph holds
**one** `openmls` and that it is the fork rev the workspace names (the current single-version `cargo tree` gate
is necessary but no longer sufficient once a git source is in play). → `MARMOT_PROTOCOL_KNOWLEDGE.md` §Overview
status block, MLS-configuration leaf list (`0xF2F1` → `0x8009`), kind-450 section, kind-30443 `mls_extensions`
tag values, `IngestOutcome`/`StaleReason`/`GroupEvent` tables, crate-set constraints; `CLAUDE.md:243` + the MDK
pinning rule's tag; `haven-core/SECURITY.md` (owned by another agent — hand it the carrier change and the
`privacy_safe_kind` addition, do not edit it here).

**Tests FIRST.** `a_v094_written_database_migrates_to_59_and_opens` — the fixture upstream does not have: a
`session.sqlite` written by the CURRENT pin, checked in as a binary fixture with the script that regenerates it,
run through `open_encrypted*` and asserted to reach migration 59 with every circle, KeyPackage row and cursor
intact. `a_v0918_database_is_refused_by_the_v094_binary` (the downgrade gate, asserted as an ERROR and not a
wipe). `a_legacy_group_is_refused_at_session_open_in_a_release_profile` (`legacy_compatibility_profile()` is
debug-only — the test must assert the RELEASE behaviour, not the debug one, or it proves nothing).
`adding_a_member_to_a_legacy_group_is_rejected_on_send_and_on_receive` (both halves; the receive half is what
produces permanent divergence). `founding_group_creation_yields_publish_work_and_a_confirmable_pending`
(B4's silent break, red before the `match` conversion). `a_lowercase_h_tag_is_required_pre_decryption` over the
hand-built fixtures. `an_expiration_overflow_omits_the_tag_and_the_clock_skew_lane_notices` (assert presence).
`the_exporter_label_is_unchanged_across_the_bump` (Rule 11, cheap, and it is the one crypto invariant a reader
will assume moved). Plus: the whole existing suite is the migration's real test surface, and **any test that
goes red is presumed to be reporting a real semantic change until proven otherwise** — §5.6 rule 6 applies
without exception here, because a bump is exactly the situation in which "adjust the assertion" feels
reasonable.

**Implementer work packets** (sequential unless noted; each is its own reviewer wave, and P4M-1 can be done
without committing to the migration at all).
| # | Packet | Sequencing | Done when |
|---|---|---|---|
| P4M-1 | **Decision packet, no code.** The v0.9.4-written DB fixture + regeneration script; the `match`-conversion of B4's two `if let` sites (correct and shippable at the CURRENT pin — it makes the future break loud and costs nothing now); the two upstream asks filed (a public `Engine::storage`/convergence-gating surface; a release-safe legacy compatibility path or an in-place upgrade) | first; **shippable independently of the rest of P4M** | fixture reproducible from the script; `cargo test` green at the current pin; both upstream issues have numbers recorded here |
| P4M-2 | Owner flag-day decision (below) + the user-facing plan for it: what every user sees, what they must do, what is lost (group history), and the copy/l10n round that carries it (13 locales, §5.6 rule 8) | after P4M-1; **gates everything after it** — **and since 2026-09-09 it is itself gated: OD-P4M-1 refuses the bump while MDK's OpenMLS is an untagged fork head, so P4M-2 does not start until that dependency is a TAGGED OpenMLS (L-124)** | decision recorded in §4 as a new OD row with its date; copy drafted, not yet landed. **The supply-chain half of that record now exists — §4 OD-P4M-1 — and it is NOT the flag-day decision** |
| P4M-3 | Manifest bump + compile-break sweep: five revs, direct `openmls` deletion, `kp_lifetime` on `KeyPackageMetadata`, exhaustive re-match of every changed enum, `expiration_timestamp()` sites, MSRV + coverage-toolchain pin | after P4M-2 | `cargo test`, `cargo clippy -- -D warnings`, `cargo fmt --check`, `check_mdk_supply_chain.sh`, single-`openmls` `cargo tree` |
| P4M-4 | Storage migration proof: the 26 → 59 fixture test, the downgrade-refusal test, the Android `libsqlite3-sys` log-surface check (B2's inherited WARN spam is presence-only-logging's problem, not just noise) | ∥ P4M-3 | both migration tests green; `logcat` scan clean on the Android lane |
| P4M-5 | Profile cutover: circle re-creation flow, Welcome re-issue to every member, the `retire_non_current_key_packages()` consequence handled (KeyPackage re-mint + republish before any user can be invited), the legacy-refusal tests | after P4M-3 | the four B3 tests green; E2E lanes green with a re-created circle |
| P4M-6 | Docs + guards: `MARMOT_PROTOCOL_KNOWLEDGE.md` sweep (carrier, tables, constraints), `CLAUDE.md:243` + the pinning rule, supply-chain guard fixture for the fork rev, `check_no_exporter_label_override.sh` explicitly RETAINED with a note saying why the bump did not obsolete it | ∥ P4M-5 | guards' `--self-test`; no doc sentence in the tree still names `0xF2F1` as the CURRENT carrier; no sentence claims the backfill arrived |
| P4M-7 | Floors re-pin from the CI run under the NEW toolchain (rustc 1.97.1 changes the denominator — §"Coverage toolchains are pinned"), stale-override deletion, closure note here | last | `--repin` from CI lcov then `--lint`; `check_coverage.sh` green |

**Reviewer checklist (written as attacks; a green run is not a pass).** **Break the profile gate:** point a
release build at a `Legacy` DB and show it opens — if it does, `legacy_compatibility_profile()` leaked out of
`#[cfg(debug_assertions)]` or someone added a fallback; the refusal is the invariant. **Break the flag day:**
add a member to a circle from an un-upgraded peer while an upgraded one watches, and show both ends at the same
epoch — they must NOT be; the divergence is permanent and the test that proves it must assert the RECEIVE
rejection, not just the send one. **Break B4 silently:** revert one `match` to `if let`, create a circle, and
show the suite still green — if it is, `founding_group_creation_yields_publish_work_and_a_confirmable_pending`
is not doing its job and the whole class of silent-variant breaks is unguarded. **Break the DB:** run the
migration chain on the v0.9.4 fixture twice, and on a fixture written mid-chain, and then open it with a
v0.9.4 binary — a wipe instead of an error is a data-loss defect, not a downgrade gate. **Break the graph:**
`cargo tree -i openmls` after the bump — two versions is two MLS type universes and a silent
confidentiality-relevant split, and the single-version gate must fail on it while the git source is in play.
**Break Rule 11:** grep the peeler diff for a nonce or label change and re-run
`check_no_exporter_label_override.sh` — the claim "unchanged" is the one an implementer is most likely to take
on trust. **Break the gains:** grep v0.9.18 for `gating_convergence_inputs`, `retire_convergence_input` and a
public `Engine::storage` before deleting ONE line of `circle/rotation.rs` or the convergence send-gate — the
"we can delete this now" instinct is what this section's "canNOT delete" list exists to stop. **Break the
motivation:** ask anyone proposing this migration to name the file, in a PINNED crate, where the epoch-gap
backfill lands. There is none.

**Risks / rollback.** The rollback story of §6.4 **does not extend to this milestone and must not be claimed to**:
B5's migrations have no `down`, `0057` erects a deliberate downgrade gate, and `0047` is structurally
irreversible, so "one commit re-inerts the phase" is false here. A rollback ships a build that WIPES and
re-provisions the MLS DB — every circle re-joined, a second flag day. That asymmetry is the single strongest
argument for the sequencing above: P4M is the only item in this plan that cannot be undone by a revert, so it
goes last, alone, and only on an explicit owner decision. Second risk: the migration looks healthy while it is
broken — legacy circles keep publishing locations (`app_components.rs:803-805`), so a partial flag day presents
as "everything works" until someone tries to add a member. Third: B4's silence, which P4M-1 removes at the
current pin precisely so it can never be discovered late.

**Acceptance.** CI: the full suite at the new pin with **no assertion weakened** (§5.6 rule 6, read the test
bodies); the four B3 tests; both B5 migration tests; single-`openmls` supply-chain gate; every E2E lane green
against a **re-created** circle; guards' `--self-test`; floors re-pinned from the new toolchain's CI lcov.
Not-CI, and stated as such: the flag day itself is user-visible and unmeasurable here.

**OWNER DECISION 2026-09-09 — DO NOT BUMP, and the binding reason is finding (3) above rather than this
paragraph's motivation clause (§4 OD-P4M-1, L-124).** The owner took the recommendation below on a narrower and
stronger ground than it argues: from v0.9.5 MDK depends on an **untagged personal fork of OpenMLS**
(`erskingardner/openmls`, rev `59e7d3b2…` — the head of `refs/heads/codex/reject-app-data-trailing-bytes`, on a fork
with no tags at all, force-pushable and deletable), and for a cryptographic application an untagged branch head as the
supply-chain anchor **for the MLS implementation itself** outweighs the four wedges the bump WOULD fix — OD4-c's
durable outbound-fanout resumption, the sender-ratchet reorder policy, the Rule-12 no-eviction caveat CLAUDE.md itself
records, and the iOS `0xdead10cc` storage close, all four named in the re-correction above and all four real. **It is
a "not yet", not a "no": the unblock condition is a TAGGED OpenMLS dependency, and the action is to raise it upstream
and ask for one.** Read the paragraph below with that in hand — its "the one thing that motivated the bump is
unreachable at every tag" clause is one of the sites §9.9 records as still carrying the inference L-93 superseded, and
this decision does not rest on it.

**Recommendation — honest, and it is not "take it".** **DO NOT execute P4M yet.** The evidence does not support
it: the one thing that motivated the bump is unreachable at every tag, the gains are real but none is urgent
and none is a power win, and the cost is a coordinated, irreversible flag day that re-creates every circle and
loses group history — paid again, in full, if we ever roll back. Take **P4M-1 now** (the fixture, the two
`match` conversions, the two upstream issues): it is cheap, correct at the current pin, and removes the silent
break before it can bite. Then hold, and revisit when ANY of these becomes true: (a) upstream ships a
release-safe legacy path or an in-place `Legacy → Current` upgrade, which turns the flag day into an ordinary
bump; (b) a security fix lands in a pinned crate — that reverses the calculation immediately and the flag day
becomes the cost of doing business; or (c) the install base is small enough, and the owner says so, that a
coordinated re-create is acceptable. **And (d), added by the owner's decision of 2026-09-09 and PRECEDING all three: a TAGGED OpenMLS dependency in the MDK workspace.** (d) is a **gate**, not a trigger — (a) or (c) firing while OpenMLS is still an untagged fork head does not license the bump, and if (b) fires the owner re-takes the call rather than either side being assumed (§4 OD-P4M-1, L-124). **What is NOT a reason to take it:** OD4-c (unreachable), the convergence
send-gate (still ours), `rotation.rs` (its knob did not move), or the Rule 12 cap (#757 still open).

**Owner decisions / open questions.** The flag day itself is a **NEW owner decision** and P4M-2 is where it is
taken — ~~it is not covered by any row in §4 today~~, and no packet after P4M-1 may start without it. **AMENDED
2026-09-09: the flag day is still that decision and is still taken at P4M-2, but it now sits behind a gate that IS in
§4 — OD-P4M-1, "do not bump while OpenMLS is an untagged fork head; unblock = a tagged OpenMLS" (L-124) — so no
packet after P4M-1 starts without BOTH.** OD4-c is
CORRECTED by this section (option (ii) dead) ~~but remains OPEN on its own terms~~ **and is no longer open: it was
DECIDED on 2026-09-09 in both halves — option (iv) plus option (i), with (iii) rejected — and its RUST implementation
LANDED the same day ~~, leaving only (i)'s Dart consumer owed~~ **— and (i)'s Dart consumer landed with it, so
nothing of OD4-c is owed (L-121, L-133, L-134)**.
**Not verified — record as such, and do not launder these into facts by repetition:** per-release commit hashes
and PR numbers beyond `d7236f43 (#1110)`; upstream's own migration-cost figures; exact method-count deltas;
whether nostr-sdk's REQ-before-filter-registration race is fixed (that is a `nostr-relay-pool` property, not
MDK's, and it is unaffected by this bump either way); #877's landing; #864 / #866 / #885's state at
v0.9.18. **No `cargo check` was run against v0.9.18**, so the compile-break list above is derived from enum,
struct and signature diffs plus Haven's call sites — it is a lower bound on the breakage, never an upper one.

---

## 6. Cross-phase verification, risks, rollback, measurement

### 6.1 The "lands together" matrix (per phase; each row is a done-criterion of that phase's packets)

| Phase | ARB / l10n | Manifest | Guards | Tests red → replacement | Lanes | Docs | Floors |
|---|---|---|---|---|---|---|---|
| P1 | none | NEW `INV-R-PUBLISH-POOL-NO-KEEPALIVE` (enforced; no disclosure key; symbols `publish_relay_options`/`build_engine_client`; fetch-primitive test; no ratchet) | `check_engine_client_options.sh` function-shaped, checks 3–7 + `--self-test` 12 + the repo-guards self-test step; `check_android_location_power.sh` (7)(8), 6 fixtures as landed (the review pass adds a seventh — read `SELF_TEST_FIXTURES`, which is pinned by equality); ios `check_stream_provider` (→ 24) | `map_shell_test` additive rows; service gate tests; `location_provider_test` fail-closed/placeholder cases; the no-frame release test; `location_access_provider_test` suspend/`resume()` cases; `cursor.rs::inbox_subtracts_7_days_regardless_of_phase` → three exact-value tests; `location_stream_error_handling_test:452-501` ≥ 2 listeners kept; the `RelayService` mocks gain a method — **9 mock classes, and the token now appears in 10 test files** (the drafted "37" counted files mentioning the type; the analyzer forces exactly the classes that `implements RelayService`, plus `FakeNostrRelayService`) | b9 `PUBLISH_AFTER_IDLE_OK` asserted from the first landing — **DONE**. B1 device-stamped sampler (the UI request `@+1s0ms` + `minUpdateDistance=1.0` pre-handoff, never after) — **NOT DONE in P1**; it is an oracle over `dumpsys location` that belongs with P2a's own steps (5)–(8) on the same sampler, and splitting it across two phases would land half a grammar. The grader step is **NOT DONE** either — §5.1 LIVENESS block | SECURITY/M11 publish-pool sentence; M7 §D + history; FA C6 debounce cause with its exact consequence; the FA health-tick note + the deleted-re-anchor note + the glance-throttle note (≤ 49 h `Resubscribe` re-anchors; the drafted `:697-703` had drifted — the claims live at `:723`, `:861`, `:882` of the pre-edit file) — all **DONE**. **Review wave 2026-09-03: see §5.1's LANDED RECORD** — four independent reviews, one live cross-packet defect (a 7-day gift-wrap replay on every Android glance), three overclaims corrected, one undeclared test drop, four items carried to `docs/CI_HARDENING_BACKLOG.md` (CI-R7/R8/R9, SEC-F6) | **As MEASURED, not as predicted:** providers 84 and services 65 absorbed (85.76 % / 67.26 %, no ratchet); `manager.rs` did NOT absorb and **RATCHETED 78 → 88** (80.14 % → 90.52 %), re-pinned with `--repin rust`; NEW `rust\|src/relay/cursor.rs\|100` (100.00 %, 174/174) is the `--list`-derived row; **one row is still OWED** — `lib/src/services/background_deferred_send.dart`, recorded only as prose in `coverage_floors.txt` because a Flutter floor cannot be pinned off a local SDK, to be added with `--repin flutter <lcov>` from a CI artifact |
| P2a | none (`fgsNotificationSharing`, battery-opt strings unchanged) | `INV-L-BACKGROUND-DISCLOSURE-GATE` additions; NEW `INV-L-ANDROID-BACKGROUND-SINGLE-GNSS-REQUEST`; no ratchet | `check_android_location_power.sh` 1–6 (function-shaped; (1) pins `allowWakeLock` ABSENT; (2) no release/detach in listeners; (5) exactly 2 `_ensureRegistration(` sites, both in `_publishCycle`); m7 check 10 FACTORED (`presence_only_log_scan`, Kotlin `Log.*` + Throwable patterns, `EXPECTED_LOG_FIXTURES`) + `PublishWakeLock.kt`; `check_location_access_gate.sh` tokens re-pointed if needed; ios header re-word (24 stays); `check_mls_session_single_owner.sh` three files | `background_location_disclosure_gate_test:124-147` same name/new token/same `gateAt < collectAt`; `session_reclaim_gate_test:338-410` anchors kept; `…reclaim_orchestration_test` same assertions; `…publish_cycle_test:250` sampler order; `…cycle_gates_test:115-138` + `streamListeners == 0`; `geolocator…_test:535-536,:851,:973` stay; harness `oneShotRequests == 0` (never `fixRequests`); `a declined handoff sends no paused signal` | B1 oracle steps 5–8 (parsed `Request[…]` + `ACQ=` age from device-stamped ≤ 5 s samples started before the drive; ≥ 55 s delivery spacing with the fixture pair; no-fix chain under forced idle) — **all landed, `[8/8]`; (8) is a second forced-idle phase after `HOLD_COMPLETE`, so steps 5–7 read an unchanged span**; constant-derived 200 s hold; grammar fixtures in the same commit; B3/B5/B6/B9/catch-up/combined untouched | FA:198-201, :51-57; M7 §D/§5/§7/§9, :57-61 (incl. the NMEA/GnssStatus listener cost and the per-HAL indoor residual); P0_1 `:430-433` RESOLVED, `:382,:410-415`; CI_HARDENING `:1553-1556` note | `background_location_task.dart|80`, `background_location_manager.dart|52`, `geolocator_location_service.dart|85`; `background_fix_request.dart`, `publish_wake_lock.dart` `--list` rows; HOLD → tests; re-pin both rows |
| P2b [OD-P2-2, OD-P2-3] | none unless `SCHEDULE_EXACT_ALARM` is chosen (then a 13-locale round + `docs/privacy`) | NEW `INV-L-ANDROID-NO-PERMANENT-WAKE-LOCK` ("no permanent lock while battery-exempt; the plugin lock is kept only while the exemption is not granted; the native registration is issued only from `_ensureRegistration` and cancelled at both disable sites"); no ratchet | `check_android_location_power.sh` (1) flipped to the exemption predicate + native registration pins (channel-only `requestLocationUpdates(`, `cancelRegistration` at both disable sites) | `fgs_plugin_wake_lock_policy_test` flipped; native-registration harness tests incl. `a toggle-off with a dead service still cancels the native registration` | **P2b PARKED 2026-08-30 (§5.2)** — B1 step (6) inverted for the exempt run; toggle-OFF-with-force-killed-service oracle; the no-fix oracle as MERGE gate; ~~forced-idle hardware row in BOTH exemption states~~ (unmeetable: the emulator never suspends the AP — the row that parks the phase) | M7 §D/§5; FA:198-201 final | re-pin |
| P3 [OD1, OD-P3-b/c/d] | `locationSettingsIosGuidance` (base), ~~NEW `locationSettingsIosCatchUp`~~ (deleted unrendered 2026-09-04, CI-R23), NEW `locationSettingsIosIndicatorArrow`, NEW `locationSettingsIosIndicatorBar`, `locationSettingsIosLimitedNote` ×13 + `@description`s; copy-tie lint + l10n tests with old-sentence forbidden lists | `INV-L-IOS-WAKES-RECEIVE-ONLY` amended (symbol + two host tests + copy-tie (c); assertion keys → ~~`locationSettingsIosCatchUp` + ~~`locationSettingsIosLimitedNote`, CI-R23); NEW `INV-L-IOS-INDICATOR-HONEST` (four assertion keys; host tests only), `INV-L-IOS-PUBLISH-INPUT-BEST-PROFILE-ONLY`; ~~ONE ratchet item (`.assertion:locationSettingsIosGuidance` — the verbatim catch-up key move; deleted next commit)~~ → **NO ratchet item** (corrected 2026-09-04, verified against the gate — see §5.3 and §7.3) | `check_ios_background_publish.sh` checks 2/3/4/7/8/9/11/12/14 → `SELF_TEST_FIXTURES=47` (pinned at what lands); m7 check-10 list (+2 files, +2 planted fixtures) + check-13 name; repo-guards comment | `geolocator…_test:894-963` retired with the branch → route tests + Swift guard; cache family + "coarse never cached" + native clear + backgrounded-shortcut cases; doomed one-shot → `lastBestFix`; `location_provider_test:141-143,:153-154` → router pass-through; `background_location_provider_test:1333-1385` + three tier cases; `location_access_provider_test:424` reason; settings-page tests; b7 reason + session + `alwaysConfirmed` oracles; `ios_bg_publish` P1 tier-PINNED + status oracle, P2b bounded profile poll | `e2e-ios-background-publish` (WIU pinned; **Always job under OD-P3-c, now MANDATORY — it is the only runtime evidence for the Always shape**); `e2e-ios-auth-tier.yml:13` header; b4 unchanged; `build-check` iOS green on the branch; ~~**hardware 0a + 0a-provisional = WP3-2 merge gate**~~ → **re-based 2026-08-30 (§2.5) on the four-part CI bundle in §5.3 WP3-2; 0a/0a-provisional DEFERRED, residual stated** | M7 §6 0a (merge gate)/0a-provisional/0b/0c + `:69-73` + history; FA Unit F amendment + `:218-222`; MESH G-10; `CLAUDE.md:258`; service/auth-service comments ("not show"); `PrivacyInfo.xcprivacy` unchanged | `geolocator_location_service.dart|85` denominator drops → RATCHET; `ios_location_source.dart` `--list` row; Swift outside lcov |
| P4 [OD4, OD4-b] | none (the presence/one-connection sentences left with the Privacy page, 2026-08-29) | NEW `INV-R-BACKGROUND-PRESENCE-ONLY-AT-PUBLISH` (no disclosure key; FGS per-cycle shutdown; k-th-burst inbox); RC1 statement narrowed for circle relays + inbox-only residual named; no ratchet | `check_engine_pool_options` rewrite (~~13~~ **21**: `note_delivery_gap`-not-`forget_*`, `disconnect`-not-`shutdown`, no standing REQ from the burst entry — no order fixtures); ios +1 (~~48/25~~ **118 today**); check 13 token scan extended; `check_no_event_timestamp_cursor_advance.sh` green; 14b untouched; restart-budget guard UNCHANGED (the `isPaused` pin is a Dart source-order test) | `map_shell` predicate tests → coordinator socket-closed test + three-state row; FA:693-709 arm foreground-only test; banner test strengthened; `sharing_health_provider_test` paused-never-disconnected; coordinator lint (no `ref.watch`) | `ios_bg_publish` P2c IN-PROCESS (Bob alive, ~~`isPaused`~~ **the pool subscription count, zero between bursts against a non-zero foreground control — CORRECTED 2026-09-08** + decrypt marker, C7) + header + re-derived `DISABLE_WAIT_SECS` **(900 → 1440 s, with the drive `Timeout` 30 → 40 min and the lane envelope 45/95/115 → 65/135/155) + `HAVEN_LIVE_SYNC` `false` → `true` on the lane, without which there is no engine to burst**; `e2e-ios-live-sync` unchanged; b9 unchanged | SECURITY `:873-900` (+ inbox-only relay inference, OD4-b), `:257-263`, `:876-879`; M11 `:117,:121`; WN `:63,:130,:168-176,:653-656`; FA Unit C, `:45-47`, `:62-65`, `:835-845`, R14; M7 §6 observable; `map_page_location_access_test.dart:10`; CI_HARDENING `:165` note | `live_sync/|95`, `session.rs|94`: e2e tests in the same commit or HOLD; `background_burst_coordinator.dart` `--list` row |
| P5(a) [OD3] | none (Privacy page removed 2026-08-29) | `INV-R-PER-CIRCLE-PUBLISH-DECORRELATED` → accepted_deviation PUB-COALESCE (disjoint-relay linkage named in the deviation entry; no disclosure key); new deviation entry; `ratchet_override` (deleted next commit) | none new; wiring-test RNG fixture; jitter parity unchanged; stagger constants untouched | `location_publish_scheduler_provider_test:123-127,:146-151`; `publish_decorrelation_wiring_test` ×3 replaced incl. the n = 2..12 spread test; `location_publish_decorrelation_test` premises; `per_circle_due_tracker_test` seedStaggered group; `publish_stagger_test` + distinct-deltas test; `background_fix_request_test` horizon pin checked unaffected | none (unless a 2-circle target is funded) | SECURITY `:584-587` + new subsection; `ttl.rs`'s `LOCATION_MESSAGE_RETENTION_SECS` doc; README deviations; P0_1 `:83,:453`; CI_HARDENING `:1590`; `e2e_combined.dart:297` still true | — |
| P5(b) | none | none | none | scheduler provider tests renamed; wiring lint extended | none | header notes | — |
| **P4M** (§5.7 — **not in the P0→P6 chain**) | the flag-day copy round only, and only after P4M-2 (13 locales, §5.6 rule 8) | none new: the carrier move `0xF2F1` → `0x8009` is a wire/doc fact, not a manifest status change — re-read this cell if P4M-2 lands user-visible copy | `check_mdk_supply_chain.sh` gains a fork-rev + single-`openmls` fixture; `check_no_exporter_label_override.sh` explicitly RETAINED with a note that the bump did NOT obsolete it | nothing may be weakened: every red test at the new pin is presumed to report a real semantic change until proven otherwise (§5.6 rule 6). NEW: the four B3 legacy-refusal tests, both B5 migration tests, B4's founding-creation test | every E2E lane re-run against a **RE-CREATED** circle — a legacy circle still passes the location lanes while its membership is frozen, so a green lane on a legacy circle proves nothing | `MARMOT_PROTOCOL_KNOWLEDGE.md` (carrier, tables, crate-set constraints), `CLAUDE.md:243` + the MDK pinning rule's tag; SECURITY.md is another agent's file — hand it the carrier change, do not edit it | re-pinned from a CI run under rustc **1.97.1**: the MSRV move changes the instrumented denominator, so every floor is re-measured, never carried forward |

**Gate category per phase (added 2026-08-30 — §2.5).** Every cell above is a CI artefact and none of them was ever a
hardware gate, so the matrix itself survives the constraint intact. What the constraint touches is the *merge gate*
that sat beside each row. Restated with its class:

| Phase | POWER-MEASUREMENT gate (estimate-replaced; §6.5a) | LIVENESS / WEDGE-SAFETY gate (re-based; residual) | Net change |
|---|---|---|---|
| P0 | the whole packet — P0-D **NOT AVAILABLE**, superseded by P0-D′ (model E + proxy register) | none (P0 changes no mechanism) | baseline becomes ESTIMATED |
| P1 | radio-wake energy → ESTIMATED −65 wakes/h; proxy = `INV-R-PUBLISH-POOL-NO-KEEPALIVE` + guard checks 3–7 + the two host tests | b9 `PUBLISH_AFTER_IDLE_OK` (MET, asserted from the first landing) + the grader (**NOT MET — no lane feeds it a capture; §5.1's LIVENESS block**) — **unchanged, was never hardware**; residual: no Doze socket-teardown observation | none material |
| P2a | GPS sensor time → ESTIMATED duty ≈ 100 % → ≈ 4 %; proxy = B1's parsed `dumpsys location` registration oracle (one request, ≥ 62 s, anti-vacuity on the pre-handoff 1 s request) | **B1 step (7)'s cadence oracle — LANDED and failable** (inside the 200 s `HANDOFF_CONFIRMED → HOLD_COMPLETE` window: ≥ 2 successful publishes, at least one delivery-driven, each delivery-driven publish ≥ 55 s after its OWN `registration armed` line — deliberately not a pair-spacing claim, because a healthy 200 s hold produces one delivery window, fixtures 45/46. The ≥ 2-publish half is the in-window realized-gap bound of ≤ 200 s < 228 s; the ≥ 55 s half is the anti-poll bound); **B1 step (8)'s no-fix chain under forced idle — LANDED 2026-09-04** (`state=IDLE` read back AND a `trigger=watchdog` publish within 302 s), which is the Doze-policy half OD-P2-2 rests on; **the grader half is DEFERRED, not a gate** — a 228 s bound cannot fire in a 200 s window and a longer window loses its head to NIP-40 eviction (§5.2 Acceptance, §6.7 follow-up 3). Residual: emulator never suspends the AP, goldfish ≠ a GNSS chip, GMS `fused` duty-cycling unexercised | ships |
| **P2b** | — | **forced-idle hardware liveness — UNMEETABLE.** The gate asks whether a delivery wakes Dart on a suspended AP; the emulator never suspends one | **PARKED (§5.2)**; AP-suspend saving UNKNOWN |
| P3 | iOS location tier → ESTIMATED 4–6× cut on the location term; proxy = the lane's bounded profile poll observing `hundredMeters` from the backgrounded process | **re-based** to the four-part WP3-2 bundle + grader; residual: no OS suspension, no status bar, no hours-scale window, and the closest physical neighbour failed 2026-08-20 | ships **staged** (§5.3 Risks) |
| P4 | background wake count → ESTIMATED ≈ 150/h → ≈ 30/h; proxy = the no-standing-REQ tests + `check_engine_client_options.sh`'s `check_engine_pool_options` check (8) + the countable REQ/CLOSE shape in the wire journal | P2c in-process receive marker + C2/C3/C5 tests — **unchanged, was never hardware** | none material |
| P5 | CPU/wake sharing — no threshold was ever set | none | none |
| P6 | the acceptance re-run → **DEFERRED**; §6.6 becomes an ESTIMATED table | the grader over every lane capture, and 0 ratchet overrides | closure is CI-only |
| **P4M** | **none** — it saves no energy, has no §6.5a input and no power gate; that is one of the three reasons it is sequenced out of the chain | the migration proofs, all CI-borne and none hardware: legacy refusal on send AND receive, the 26 → 59 fixture, downgrade-refused-not-wiped, B4's founding-creation test | out of the chain; **recommended NOT executed yet** (§5.7) |

Read the table this way: **no phase loses a liveness gate except P2b, which is why P2b alone is parked.** Every
other phase's liveness evidence was already CI-borne or is re-basable onto CI with a stated residual; only the
energy numbers move to estimates.

### 6.2 Promises → proof, per phase (LB = load-bearing verbatim; D = descriptive)

| Promise | P1 | P2 | P3 | P4 | P5 |
|---|---|---|---|---|---|
| LB ciphertext-only egress; payload = coordinate + timestamp; `raw_accuracy` skipped | `check_inner_location_kind.sh`, wire journal, `location_message_json_excludes_private_fields` | + FGS delivered-fix path via `encryption_pipeline_test` | + `resent_fix_payload_has_identical_shape` | same (burst uses the same encrypt path) | same |
| LB access gate above every read; cache = freshness not consent | `check_location_access_gate.sh`; service gate tests "suspension keeps the warm fix; opt-out clears it (at pause time)" | gate tokens re-pointed; `the gate precedes location COLLECTION…` name kept; registration-order test + single `_ensureRegistration(` site (guard count) | native stream enters through `getLocationStream` → cache tests unchanged; "coarse fix never cached"; native `lastBestFix` clears with the Dart cache; the backgrounded shortcut reads the native lifecycle | — | — |
| LB toggle OFF ⇒ no keep-alive/session/region/wake | `_onPaused` clears the cache synchronously on `!bg`; C4 watcher cancels the kept iOS stream directly | P2a: plugin lock kept (deliberate; guard (1) pins ABSENT); P2b: `allowWakeLock` bound to the exemption state (plugin lock kept while not exempt) pin; native registration cancelled at both disable sites, fail-closed receiver; scoped lock released on the toggle-off path | guard check 4 (`allowsBackgroundLocationUpdates = allowsBg`, derivation pinned), `check_arm_tier_policy` (disarm unconditional), provider disarm cases, `ios_bg_publish` P3, `a toggle-off pause leaves no native last-Best fix` | burst never runs with toggle OFF: C4 test + guard + P3 silence diff; a cancelled burst still pauses | — |
| LB iOS post-termination wakes receive-only | `background_claim_accuracy_test` ×5, `check_m7_native_wake_guards.sh` check 13 (AppDelegate retains both wake handlers as STORED properties), `check_ios_background_publish.sh` check 13 (the SLC relaunch region lives and dies with SLC, on the same receive-only Dart channel) — named by SCRIPT because the two are different checks that share a number, and "m7 guards, ios check 13" resolved to whichever the reader guessed; fail-closed `appForegroundProvider` on a background launch | — | native owner refuses a background START (guard + source test) AND the one-shot is unreachable from a background launch (native `backgrounded` read; guard order pin + service test); no publish site in the Swift file (`check_m7_native_wake_guards.sh` check 13, extended to the stream handler: a token scan banning `URLSession`/`NWConnection`/`invokeMethod(` in the one native file that holds every coordinate) | burst reachable only from the running process's tick (`check_m7_native_wake_guards.sh` check 13's token scan, extended to the coordinator) | — |
| LB no push / no telemetry SDK | guard 9/9b | — | — | — | — |
| LB per-circle decorrelation + ≥ 40 % CSPRNG jitter | `publish_decorrelation_wiring_test` ×3, `check_publish_jitter_fraction_parity.sh`, `location_test` 72/168 | same (sample drawn earlier, not differently) | same | same | OD3: status → accepted_deviation via override (**EIGHT override items as landed — corrected 2026-09-09: `INV-W-445-EXPIRATION-WINDOW` STAYS `enforced`, and the `.status` item an earlier revision added was deleted with the `ratcheted` downgrade it allowed once the roster bound put the past-eleven hole out of reach, L-132**); the EXISTING CSPRNG stagger, whose alphabet is **roster-scoped — `{2…9}` to four circles and `{2,3,4}` at `kMaxCirclesPerAccount` (10), the largest burst a bounded roster can produce, with `{2,3}` only `maxGapFor`'s answer one circle further, where nothing reaches** — pinned by three tests, not one (`…at the DEFAULT burst size of two`, `expected whole-second delta alphabet, swept over every burst size the app admits`, `the per-gap ceiling is the priced table, for every burst size`); jitter parity unchanged |
| LB 228/168/60 TTL web; every interval ≤ 168 s in every profile | `privacy_copy_ties.rs` ×2 (the widening/narrowing bounds — the two copy pins left with the Privacy page, 2026-08-29), clock-skew parity, `location_test` | `worst-case inter-publish gap never exceeds kLocationPublishMaxInterval` (exhaustive, both API anchors, the 31–71 s sibling window); API ≤ 30's cold residual pinned by equality at 248 s worst / 20 s overrun, ACCEPTED (W-3) | schedule identical in both profiles (scheduler never consults the profile) | burst bound tests (per-relay ack 5 s; in-flight publishes always complete; `BURST_BOUND < _publishLinkTimeout`; total < `kTtlNetworkBufferSeconds` on a quiet burst) | `kPublishStaggerMaxSpread` 30 s pins; n = 2..12 spread test; horizon decoupled |
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
| **C2** stuck inbound row gates outbound | none | none | none | burst ORDER ingest-before-publish (Rust test, per-endpoint EOSE); drain-then-clear on pause ~~(backlog test)~~ **(CORRECTED 2026-09-05: the backlog test was removed as unsound and its replacement does not go red on "clear the router before the drain" — this cell currently NAMES COVERAGE THAT DOES NOT EXIST; a stronger replacement is owed, §5.4)**; Unit B sweep still runs inside the burst (test) | none |
| **C3** relay CLOSED, dead-but-running | `.ping(false)` on the ENGINE pool would remove the only traffic on a socket with standing REQs → call-shape guard check 5 + `engine_pool_keeps_ping_while_subscribed`; a leaked fetch REQ on the ping-less publish pool → `every_fetch_primitive_leaves_no_subscription_registered`; `RelayManager::subscribe` deleted | none | none | background: no standing REQ to lose (`background_burst_holds_no_standing_req`); stale relay-side REQs swept at pause and before open; a queued CLOSED cannot fire after open; `maintain_subscription_health` cannot reach `health_probe` while paused; foreground: 15-min tick unchanged (`health.rs` tests) | none |
| **C4** ratchet 1000 exhaustion | none (rate unchanged: `location_test` pins); bounded inbox lookback (P1) must not skip circle events: `cursor_poisoning_e2e.rs` kept; bound applies to the INBOX plane only | FGS interval ∈ [72,168] test | profile never changes rate | per-burst rate = per-tick rate (test) | per-circle rate unchanged (each circle once per interval — test) |
| **C5** non-Stable epoch / quarantined group | none | none | none | burst settles convergence before close; the marker ack + gauge check before `disconnect` (both inside `pause_subscriptions`, under the lifecycle lock) mean a pause can never cut a commit between SEND and OK; pending commit confirmed only on OK-ack (`check_e2e_publish_before_apply.sh`, `auto_commit.rs` at floor 100, `pause_never_disconnects_while_an_auto_commit_awaits_its_ok`). **UNCOVERED SUB-CASE, added 2026-09-05: a burst KILLED mid-publish (not paused) leaves the group wedged and the engine does not recover it — the re-fetched own commit returns `Stale { OwnEcho }`, and for a removal-bearing staged commit `PendingCommitRecovered` is never emitted. No test; the Rule-13 source gate stays green. Control = OD4-c (§4, ~~OPEN~~ **DECIDED 2026-09-09 — option (iv) + option (i), code OWED, so this sub-case stays UNCOVERED until it lands; L-121**)** — **COVERED ON THE BURST PLANE 2026-09-09 (L-133): a burst no longer publishes a removal-bearing auto-commit at all, so it opens no window to be killed in; the eviction is parked as a durable per-circle row and the next FOREGROUND open publishes it under the Rule-13 ladder, retrying rather than rolling back. `od4c_removal_deferral_e2e.rs` and `security_rule_gates.rs::od4c_a_background_burst_cannot_publish_a_removal_bearing_auto_commit` redden when either property breaks. **What stays UNCOVERED:** the ENGINE is unchanged, so a group already wedged is still wedged — it is now NAMED as `LiveSyncEvent::GroupUnrecoverable` ~~and nothing consumes that verdict~~ **and the verdict IS consumed as of the same day (L-134): the status handler reads it, marks the circle blocked, and the banner names it and offers the re-create, on the second foreground open**; the Android background catch-up sweep still publishes a removal-bearing auto-commit rather than parking one **— a finding since 2026-09-09, stated at the call site and tested, paid for by the two tree-wide guarantees (no rollback at `CircleManager::publish_failed`, write-ahead record at `CircleManager::owe_removal_publish`)**; a device wedged by a session that predates this code carries no durable row and is undetectable; **and an obligation recorded by ANOTHER session is reported but never redeemable at this rev** | none |
| **C6** `_startLiveSync` one-shot / heal hang / worker death / clock skew / handover race / wake lock | banner/maintenance gating must not touch `_liveSyncHealTimer` re-arm (`map_shell_receive_recovery_test`); the debounce fix must keep `_rearmLiveSyncHealTimer()` on the debounced path; B8's clock-rejection branch preserved through `publish_with_retry(1, …)` | P2a keeps the plugin lock so the no-fix watchdog stays punctual; P2b **PARKED (§5.2)**: cadence punctuality from delivery would need the ~~hardware liveness column under forced idle~~ that does not exist, leaving only `dumpsys power` + the emulator no-fix oracle — which prove the Doze policy, not the suspend. STACKED faults (cold TTFF + a suspend gap) exceed 228 s; with P2a keeping the plugin lock the stack cannot form, which is the parked phase's risk, not P2a's. **The suspend stack is not the only route past 228 s, and P2a ships with the other one ACCEPTED (W-3, 2026-09-04):** on `Api.legacy` (API 23–30; `minSdk = 23`) a COLD acquisition alone breaches it, because that regime pays two acquisitions and the in-cycle latencies ρ (≤ 20 s) and σ (ρ + σ ≤ 30 s) the code declares legal — realized gap `60 + min(J − 10 + σ, 168) + ρ` (the interval ceiling is why the worst case is 248 s and not 268 s; the `J + 50 + ρ + σ` this row carried until the 2026-09-04 re-review was the uncapped region only), at or past the retention whenever `J + ρ + σ ≥ 178 s` — true in the capped and uncapped regions alike — worst **248 s**, i.e. a peer's marker absent for **at most 20 s** before the next publish restores it. Once per occurrence, in P2a's own regime, plugin lock held, no AP suspend anywhere in it; S+ never breaches (worst cold gap 198 s). ACCEPTED, not fixed — reasoning replaced 2026-09-04 (the earlier "every lever pays in S+ duty cycle" was wrong and is retracted): the lever that would close it is a legacy-only 147 s ceiling, which swept does empty the breach set (248 s → 227 s), but (1) nothing in the repo reads `Build.VERSION.SDK_INT` today, so it costs a second native channel into a deliberately pure function plus a missing-plugin policy and new source guards, and (2) a cap moves the DELIVERY not the due-time, so fix age walks (`age ← J + age − 147`) — one step from steady state at the top of the band is `10 + 168 − 147 = 31 s`, past `kBackgroundFixHorizon` (30 s), i.e. a delivery that selects no circle and a GNSS acquisition wasted, on HOT fixes, on the same old devices the ceiling protects. Entry price, from the sweep: unreachable below 10 s of in-cycle latency, which only a multi-circle burst spends. Guarded instead by an EQUALITY: the cold sweep covers the full ρ/σ space and pins the breach set, both worst gaps and the 20 s overrun by value, so this residual can neither grow nor be declared gone without a red test. Derivation in D3 (iii) | none | `_dispatchTick` carries the `.timeout(` (`check_location_access_gate.sh` check 8); `BURST_BOUND < _publishLinkTimeout`; NO timeout on commit-critical links; throw AND cancellation paths pause | burst spread ≤ 33 s so a hung circle cannot wedge siblings (`publishLinkTimeoutForTest` load-bearing) |
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
| **P4M** | **NONE — this milestone breaks the one-commit rule, and this table must not be read as covering it.** Storage migrations 27–59 have no `down`, `0057` is a deliberate downgrade gate and `0047` is structurally irreversible, so a "revert" build must WIPE and re-provision the MLS DB: every circle re-joined, a second flag day. **P4M-1 alone** (the fixture, the two `if let` → `match` conversions, the upstream issues) IS revertible in one commit — part of why it is separable from the rest | nothing is harmless here. Plan the forward step as unrepeatable, and see §5.7 Risks |

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
age pill thresholds at 5 min, so a receiver-side gap routinely reads 168 + 120 s on a healthy run. Threshold, **per API
level for a baseline row too — a flat ≤ 228 s here contradicted the correction four lines down until 2026-09-09**: ≤ 228 s
(`kLocationMessageRetention`) on iOS and on Android API 31+, and **≤ 248 s on API 23–30**, because a baseline row is a row
of the SHIPPED build and that regime's derived worst realized gap IS 248 s (same shape as `POWER_MEASUREMENT.md` §3.5).
The iOS 228 s is a ONE-CIRCLE number (`POWER_MEASUREMENT.md` control 3, derived worst 208 s): `constants/location.dart`
derives 238 s for iOS once a burst spread enters the realized gap, which no row of this campaign has. For an acceptance
row after P2a, **≤ 198 s on API 31+ and ≤ 248 s on
API 23–30** (D3 (iii) — the second is the ACCEPTED cold residual, so record the API level with the row or the number
means nothing; the ≤ 188 s this said until 2026-09-04 was the σ = 0 case). ~~Today's derived worst case is 240 s, so a
baseline gap > 228 s is a P0 finding.~~ **CORRECTED 2026-09-08 (P6-B′): the 240 s is the PRE-P2a shape (72 s poll,
30 s horizon, 30 s one-shot), which was "today" on 2026-08-30 and is history since P2a landed on 2026-09-04.** A
baseline row taken now is a row of the SHIPPED build, so its derived worst realized gap is the same 198 s (API 31+) /
248 s (API 23–30) / 208 s (iOS, one circle) set: a gap > 228 s is a P0 finding on iOS and on API 31+, while on API 23–30
the 228–248 s band is D3 (iii)'s accepted residual and only > 248 s is a finding.

**Scenarios.** S (stationary): device on a desk, app backgrounded via Home — ≥ 3 h on iOS (Settings › Battery is
whole-percent: a ≤ 1 %/h target needs ≥ 3 counts, and a relative threshold whose baseline is < 4 % over the window is not
resolvable — extend the window), 60 min on Android. W (walking, 30 min): normal walk, phone in pocket.

**iOS.** (1) On-device Energy Log — ATTRIBUTION evidence, not the primary metric (corrected by review 2026-08-30;
the primary number is device SoC %/h, see §6.6 and `docs/POWER_MEASUREMENT.md` §4/§7 — the Energy Log reports an
impact SCORE and component states, never percent per hour): Settings → Developer → Logging → Energy → start before
backgrounding, stop after; import into Xcode Instruments (File → Import Logged Data from Device) and read the Haven process
energy impact + Location/Network subcomponents — avoids Xcode-attached runs, which keep the process alive and skew the result.
(2) Settings → Battery → screenshot "Last 24 Hours" per-app row for Haven (%, on-screen vs background minutes) at T0 and
T0+window (iOS has no reset; subtract) — the SECONDARY metric. (3) Device console (Xcode → Devices → Open Console) filtered on
`locationd` for `"Location subscription"` RunningBoard assertions, `runningboardd` `Suspending task` (the recipe in `M7` §6 item 0) —
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

### 6.5a Estimation model E — the ESTIMATED baseline that replaces P0-D (added 2026-08-30, §2.5)

**What this is, and what it is not.** §6.5 above is a measurement protocol that cannot be run: there is no iPhone,
no macOS machine and no Android handset for the duration (§2.5). Model E is what stands in its place for the
POWER-MEASUREMENT class of gate. It is **arithmetic over published third-party figures and declared assumptions**.
It produces numbers. Those numbers are **ESTIMATED** — not measured, not observed, not "approximately measured" —
and every one of them is tagged at every site it appears. An estimate cannot fail an acceptance test; if a future
measurement disagrees with model E, **the model was wrong**, and the model is what gets corrected. Nothing in
`docs/POWER_MEASUREMENT.md` is ever filled in from here (§5.0 Acceptance).

**(i) The model**

*Inputs — every one already cited elsewhere in this plan; none is new, and none was produced by this project.*

| Id | Input | Value | Cited at |
|---|---|---|---|
| E-I1 | continuous GNSS draw (Android) | 60–85 mA | §1.1 R-C (Karki & Won) |
| E-I2 | duty-cycled GNSS draw, one fix per publish (Android) | ≈ 5 mA average | §5.2 goal (research §1.5/§1.7) |
| E-I3 | typical hot TTFF | ≈ 5 s | §2.2 (`GnssLocationProvider:228`, "Typical hot TTFF is ~5 seconds") |
| E-I4 | iOS accuracy-tier cost | 100 m ≈ 0.3 %/h; 10 m ≈ 1.8 %/h; GPS tiers cost 4–6× the 100 m tier | §2.1 (Evgenii, 12 h background) |
| E-I5 | iOS "Move mode" whole-day cost | ≈ 25 %/day (≈ 1.04 %/h) vs 1–2 %/day (≈ 0.04–0.08 %/h) | §1.1 R-A (OwnTracks) |
| E-I6 | LTE radio energy | ≈ 13 J per **isolated** wake; 10 KB ≈ 0.05 J; a reconnect ≈ 0.5 J *inside* a wake | §1.1 R-E, §2.3 wake model |
| E-I7 | background wake counts today, one circle | ≈ 150/h iOS-bg, ≈ 140/h Android-bg; keepalives are 70–90 % of them (tagged **I** at source, so E's radio rows are I-grade at best) | §1.1 R-E |
| E-I8 | keepalive cadence | `PING_INTERVAL` 55 s per socket ⇒ ≈ 65 wakes/h per pinging socket | §2.3 F3 |
| E-I9 | publish cadence | 120 s nominal, [72, 168] s ⇒ ≈ 30/h (bounds 21–50/h) | §1, `constants/location.dart` |
| E-I10 | stationary controller duty | dwell 120 s, escalation every 84 s ⇒ ≤ ≈ 59 % of the window at Best in poor coverage, ≈ 0 % in good coverage. **Amended 2026-09-08 (P6-B′), because P3 shipped a trigger this input predates:** OD-P3-e's anchor cap (`kStationaryAnchorMaxAge` = 5 min) escalates even while coarse fixes keep confirming, at ≈ 12 Best DELIVERIES per hour ⇒ ≈ 1 % duty, so good coverage is `d ≈ 0.01` and not 0. Through E-A3 that is ≈ 0.31 %/h against the ≈ 0.3 the table below quotes — inside its own rounding, so no row moves | OD-P3-a, OD-P3-e |
| E-I11 | Android one-shot cap | the FGS per-tick one-shot is capped at 30 s by geolocator's Dart `timeLimit`; it ends on first fix | §2.2, §1.1 R-C |

*Parameters — assumptions this model DECLARES. They are not facts, and substituting real values is the first thing
a hardware campaign does.*

| Id | Parameter | Value used | Effect on every output |
|---|---|---|---|
| E-P1 | battery | 4500 mAh at 3.85 V ⇒ ≈ 17.3 Wh ≈ 62 400 J; **1 % SoC ≈ 624 J**; **1 mA sustained ≈ 0.022 %/h**, i.e. `%/h ≈ mA / 45` | a mid-range handset, chosen because nobody knows what the owner's phones are. Every %/h below scales inversely with capacity: a 5000 mAh phone reads ≈ 10 % lower, a 3200 mAh phone ≈ 40 % higher. **This alone makes an absolute %/h target unusable as a threshold.** |
| E-P2 | wake coalescing `c` ∈ [0.15, 1.0] | the fraction of E-I6's isolated-wake energy actually paid when a wake lands inside a previous wake's radio tail | two sockets pinging at 55 s produce wakes ≈ 27 s apart on average — far outside any published LTE tail — so on **cellular** `c` sits near 1; on **Wi-Fi** the per-wake regime is different and much cheaper. This is exactly why §6.5's controls fix the network per run. Every radio figure below is a RANGE because of `c`, and the width is honesty, not hedging. |
| E-P3 | application-processor awake-but-idle draw | **UNKNOWN — no figure exists in §2 or the source reports** | model E therefore has **no AP term at all**. Consequences: the Android baseline is understated by an unknown amount (R-D: the permanent wake lock means the AP never suspends), and **P2b's saving cannot be estimated even in principle** — which is a second, independent reason P2b is PARKED (§5.2) rather than "shipped on an estimate". |

*Arithmetic — three formulas, used everywhere below.*
- **E-A1 (location, Android):** `%/h = duty × mA_gnss / 45` (E-P1, E-I1/E-I2).
- **E-A2 (radio):** `%/h = wakes_per_hour × 13 J × c / 624 J = wakes_per_hour × c × 0.0208`. So **one background wake
  per hour ≈ 0.021 %/h** at `c = 1`; 65 keepalives/h ≈ **1.35 %/h** at `c = 1` and ≈ **0.20 %/h** at `c = 0.15`.
- **E-A3 (location, iOS):** `%/h = d × Best + (1 − d) × 0.3`, where `d` is the profile duty at Best (E-I10) and
  `Best ≈ 1.2–1.8 %/h` (E-I4's "4–6× the 100 m tier"; corroborated independently by E-I5's ≈ 1.04 %/h, a different
  app on a different handset — agreement to within a factor of ~1.5 is the most the two sources support).

**(ii) The ESTIMATED per-phase table** — stationary, backgrounded, sharing ON, one circle, cellular, screen off.
**Every cell is ESTIMATED.** Ranges are `c ∈ [0.15, 1.0]` unless stated.

Each `Δ` below is the change in the **term(s) that phase touches**. Do NOT subtract two totals end-to-end: ranges
compose, so an endpoint difference between two total columns is not a saving.

| Phase (cumulative) | iOS location term | iOS radio term (wakes/h) | **iOS total (ESTIMATED)** | Android location term | Android radio term (wakes/h) | **Android total (ESTIMATED)** |
|---|---|---|---|---|---|---|
| **Baseline (today)** | Best 24/7, `d = 1` ⇒ **1.2–1.8** | ≈ 150 ⇒ **0.47–3.12** | **1.7–4.9 %/h** | 1 Hz UI stream never cancelled, duty ≈ 100 % ⇒ **1.33–1.89** | ≈ 140 ⇒ **0.44–2.91** | **1.8–4.8 %/h** *plus an UNKNOWN AP term (E-P3)* |
| **+ P1** (publish pool on-demand, no keepalive; UI stream released at pause — Android only, iOS keeps it by the keep rule §3.1) | unchanged **1.2–1.8** | ≈ 85 ⇒ **0.27–1.77** | **1.5–3.6 %/h** (Δ radio −0.20 to −1.35) | UI stream gone; only the FGS one-shot per **72 s** tick (`kBackgroundRepeatInterval`), duty = min(TTFF, 30 s)/72 s ≈ **7 % outdoors to 42 % indoors** ⇒ **0.09–0.79** | ≈ 75 ⇒ **0.23–1.56** | **0.3–2.4 %/h** *+ UNKNOWN AP* (Δ location −0.54 to −1.80, Δ radio −0.20 to −1.35) |
| **+ P2a** (Android only: one duty-cycled registration, one-shot demoted, per-cycle pool shutdown) | — | — | — | hot TTFF once per publish cycle ⇒ ≈ 5 s / ≈ 120 s ≈ **4 %** duty ⇒ **0.06–0.11** (E-I2's ≈ 5 mA gives 0.11 independently — two routes agreeing) | ≈ 30 ⇒ **0.09–0.62** | **0.15–0.73 %/h** *+ UNKNOWN AP, untouched by P2a* (Δ location −0.03 to −0.68, Δ radio −0.14 to −0.94) |
| **+ P3** (iOS only: two accuracy profiles) | `d ≈ 0` good coverage ⇒ **0.3**; `d = 0.59` poor ⇒ **1.0** | unchanged ≈ 85 | **0.6–2.8 %/h** (Δ location −0.2 poor-coverage to −1.5 good-coverage — the spread IS I-P3-1, unobserved) | — | — | — |
| **+ P4** (iOS only: burst receive, engine socket closed while paused) | unchanged **0.3–1.0** | ≈ 30 ⇒ **0.09–0.62** | **0.4–1.6 %/h**, mid-range (good coverage, `c ≈ 0.5`) ≈ **0.6 %/h** (Δ radio −0.17 to −1.14) | — | — | — |
| **+ P5(a)** (both planes: one coalesced burst per interval, ≤ 11 circles each) | unchanged | unchanged at ONE circle | **unchanged** | unchanged | unchanged at ONE circle | **unchanged** |
| **+ P2b** *(PARKED)* | — | — | — | unchanged | unchanged | **cannot be estimated**: the term P2b removes is E-P3, which has no value |

**P5(a) is invisible in this table by construction, and that is not a claim that it saves nothing** (row added
2026-09-08 by P6-B′; P5(a) landed after this section was written). The table's subject is ONE circle, and P5(a)
coalesces N per-circle bursts into one — at N = 1 there is nothing to coalesce. Its saving is multi-circle only and
is **ESTIMATED** the same way everything else here is: wakes ≈ N × 30/h → ≈ 30/h per plane, i.e. ≈ (N − 1) × 30 ×
`c` × 0.0208 %/h off the radio term (E-A2) — at N = 4 that is ≈ 1.9 %/h at `c = 1` and ≈ 0.28 %/h at `c = 0.15`.
Past eleven circles the coalescing itself defers (L-100), which is a liveness cost and not an energy one.

**Three findings the model itself produces**, each worth acting on and none of which needed a phone:
1. **Most of the Android GNSS win is P1's, not P2a's.** Releasing the never-cancelled 1 Hz UI stream at pause takes
   the duty from ≈ 100 % to the FGS one-shot's ≈ 7–42 % (5–30 s per 72 s tick); P2a then takes ≈ 7–42 % to ≈ 4 % and,
   more importantly, bounds the *indoor* case (a hibernating provider searching per its own policy, instead of a 30 s-capped
   re-acquisition every tick). P2a's headline claim should be *cadence and the indoor tail*, not "the GNSS fix".
   The plan's own P1 acceptance already hinted at this ("GNSS blame already drops to the FGS one-shot's TTFF per
   tick"); the arithmetic makes it the primary reading.
2. **The radio term is the widest uncertainty on both platforms** — wider than the location term the plan is
   mostly about — and it is dominated entirely by `c` (E-P2), i.e. by whether the run is on cellular or Wi-Fi.
   Any future measurement that does not fix the network per run will produce numbers that cannot be compared.
3. **§6.6's "≤ 1 %/h" absolute target is a model output, not a measurement.** The P1+P3+P4 iOS estimate is
   0.4–1.6 %/h with a mid-range near 0.6, and the target was set at 1. It was always an extrapolation (the plan
   said so: "the absolute figures are extrapolations"); it is now openly labelled as such, and it must never be
   quoted as a result.

**(iii) The CI-observable proxy register** — what CI *can* still prove. Each row proves that **the mechanism
changed**, which is the *input* to model E. **No row proves a milliamp, a percent, or a joule.**

| Model term | CI proxy that must hold | Lane / guard / test | What it does NOT prove |
|---|---|---|---|
| Android GNSS duty (E-A1) | exactly ONE Haven location registration while backgrounded, interval ≥ 62 s, parsed from `Request[…]` grammar, never two in one sample; anti-vacuity: the `@+1s0ms` UI request WAS present pre-handoff | `e2e-fgs-publish` (B1) steps (5)/(7), device-stamped ≤ 5 s samples of `dumpsys location`, started before `flutter drive`; grammar pinned by shell fixtures | the GNSS chip's actual behaviour — goldfish is not a receiver, `CAPABILITY_SCHEDULING` is unrepresented (I-P2-1, I-P2-2), and no mA is observable |
| Android wake-lock policy | `Haven:publish` present only with `ACQ=` age ≤ 30 s; `ForegroundService:WakeLock` present throughout in P2a (its ABSENCE would be the P2b oracle) | B1 step (6), `dumpsys power`; `check_android_location_power.sh` (1) pins `allowWakeLock` ABSENT | **AP suspension** — the emulator never suspends. This is the gap that parks P2b |
| Radio wake count (E-A2) | the publish pool carries no PING flag and leaves no registered subscription behind | `INV-R-PUBLISH-POOL-NO-KEEPALIVE`; `check_engine_client_options.sh` checks 3–7; host tests `engine_pool_keeps_ping_while_subscribed` (the engine pool must KEEP its ping — the C3 trap) and `every_fetch_primitive_leaves_no_subscription_registered` | anything about radio *energy*. Note also that the e2e wire proxy **forwards but does not record** WebSocket Ping/Pong (`tooling/e2e/local-relay/src/proxy.rs:20,1037`), so keepalives are **not countable on the wire** — the count is a static/host-test property, not an observation |
| iOS background wake shape (P4) | one REQ/CLOSE pair per publish, nothing between; inbox REQ only every k-th burst | `background_burst_holds_no_standing_req`; P2c oracle "no `#p` REQ between bursts"; `a_burst_reissues_the_inbox_req_every_kth_burst`; `check_engine_client_options.sh`'s `check_engine_pool_options`, check **(8)** — the `pause_subscriptions` body pins (`note_delivery_gap` not `forget_*`, `terminate_all_relays()` not `client.shutdown()`, and `terminate_all_relays`' own re-asserting `client.disconnect()`) plus the standing-REQ scan of `resume_burst`. ~~check 13~~ was a dangling number: this script's numbered checks run 1–10. Application-level frames ARE journaled, so the shape is countable | the energy of those wakes, and the radio tail behaviour (U-P4-1) |
| iOS accuracy tier (E-A3) | `hundredMeters` observed from the **backgrounded** process — the tier is really requested and really honoured, not merely written to a field | `e2e-ios-background-publish` P2b bounded profile poll; WIU job's tier PIN | the profile *duty* (I-P3-1) — how often the 84 s escalation fires on a real desk is unobserved, and it is the whole difference between the 0.3 and 1.0 estimates |
| iOS tier→policy mapping | session held under WIU, not held under confirmed Always; `alwaysConfirmed == true` under a full grant | `e2e-ios-auth-tier` (b7); `check_arm_tier_policy`; `check_ios_background_publish.sh` check 4's derivation pin | whether the status bar actually renders the arrow instead of the pill — no simulator draws it |
| **LIVENESS (all phases)** | max relay-side `created_at` gap within the row's own per-API bound over a **declared** window, grader exit **0** with `--publishers` given — **≤ 228 s** on iOS and Android API 31+, and **≤ 248 s** on Android API 23–30, which is D3 (iii)'s ACCEPTED cold residual and not a slacker gate (the bound is per API level, so a row that does not record its level cannot be read; `≤ 198 s` is the post-P2a acceptance figure for API 31+ and **never a tighter one** — §6.5 retracted 188 s on 2026-09-04). This cell said a flat 228 s until 2026-09-09, while its §6.6 sibling already carried the caveat | `tooling/e2e/ci/summarize-created-at-gaps.sh` run over an emulator/simulator lane capture; head/tail silence graded as a gap; an undeclared window is `UNGRADED` (exit 5), never a pass. **NEW WORK, not a free ride:** the only invocation in the tree today is the `--self-test` in `repo-guards.yml`'s step "E2E harness self-test (relay liveness grader)" — no lane exports its strfry or grades it. Each phase's lane packet must add the export-and-grade step (export to ndjson, pass `--publishers` and the lane's declared `--from`/`--until`, require exit 0). **AMENDED 2026-09-04 (P2a review round): "must" is not achievable per phase, and stating it as a requirement while no phase can meet it is what produced a gate that was simultaneously required and impossible.** A relay-side export can only be graded over a window LONGER than the 228 s bound, and any such window has already lost its head to NIP-40 eviction (CI-R16) — so the step is owed by whichever lane first gets a jittered-cadence window of ≥ 2 × 228 s captured from an eviction-immune instrument (the wire-proxy journal), not by every phase in turn. P1 records it NOT MET (§5.1); P2a records it DEFERRED with B1 step (7) named as the successor that does gate it (§5.2 Acceptance) | continuity beyond the lane's window; OS suspension; a device that merely *slowed* behind a healthy peer (§3.6 of `POWER_MEASUREMENT.md`) |

**A green CI run proves the mechanism changed and that publishing did not stop inside the lane's window. It does
not prove a battery number, and no combination of these rows ever will.** Say it that way in every summary.

**(iv) `docs/POWER_MEASUREMENT.md` is DEFERRED, intact and still authoritative.** It is not cut down, not
simplified, and not replaced by this section. It carries a deferral banner at the top and its `## Baseline` table
stays empty. Its **Android half (§5 + §3 + §1) needs only an Android phone and `adb` on any laptop** — no macOS, no
iPhone — so it is runnable strictly earlier than the iOS half, and the banner says so: an Android device turning up
is immediately actionable, and would settle E-I1/E-I2, E-P1, E-P3 and I-P2-1/I-P2-2 in one 60-minute run.

### 6.6 ~~Hardware acceptance thresholds (owner-run; absolute AND relative, with a liveness clause)~~ → Acceptance: ESTIMATED change + CI-checkable proxy, with a hard liveness clause (rewritten 2026-08-30, §2.5)

**Both the absolute and the relative battery columns are unevaluable.** The absolute column needed a phone on
battery; the relative column needed a P0 baseline row to divide by, and P0-D is NOT AVAILABLE (§5.0), so it has no
denominator either. Both are therefore restated below as **ESTIMATED change** (model E, §6.5a) — a prediction, not a
threshold — paired with the **CI-checkable proxy that must hold**, which is a real gate and does red a build. The
**LIVENESS row is the only row in this table that can fail** — but read that precisely, because this paragraph
read as "and it reds a build" until 2026-09-09: it is failable **in principle and inert in CI**, since no lane
feeds the grader a capture (§5.6 Acceptance, §5.1's LIVENESS block). The rows that actually red a build are the
right-hand column's mechanism proxies.

| Metric | **ESTIMATED change** (model E, §6.5a — never measured) | **CI-checkable proxy that MUST hold** |
|---|---|---|
| iOS, background sharing ON, stationary, confirmed Always | after P1+P3+P4: ≈ **1.7–4.9 → 0.4–1.6 %/h**, mid-range ≈ 0.6 %/h; after P3 alone ≈ 1.5–3.6 → 0.6–2.8 %/h. The old "≤ 1 %/h" absolute was itself this model's output, not a measurement (§6.5a finding 3) | the bg-publish lane's **Always** job green: publishes continue from a backgrounded process with `held == false`, `serviceSessionHeld == true`, `alwaysConfirmed == true`, ≥ 2 events / 396 s; the bounded profile poll observes `hundredMeters` from the backgrounded process |
| iOS, same, When-In-Use / provisional | same location saving; the activity session and pill are retained by policy (OD-P3-b), which costs nothing measurable in this model — the session is a claim, not a radio | the bg-publish lane's **WIU** job green with its tier PINNED (a provisional escalation must be a red attributable run, never a silent branch swap); b7's session-held oracle inverted per tier |
| iOS, walking | no estimate: the controller is at Best by design while moving, so the location term is the baseline term. P3 is not a walking-mode change | the Best-while-moving test (the movement detector raises the profile and does not publish); `e2e-ios-real-gps` green |
| Android, stationary (P2a) | GNSS duty ≈ **100 % → ≈ 7–42 % (P1) → ≈ 4 % (P2a)** ⇒ location term ≈ **1.33–1.89 → 0.09–0.79 → 0.06–0.11 %/h**; most of the drop is P1's stream release, and P2a's distinctive share is the last step plus the indoor bound (§6.5a finding 1). Radio ≈ 140 → ≈ 75 (P1) → ≈ 30 wakes/h (P2a) | B1's parsed `dumpsys location` oracle: exactly ONE Haven request, interval ≥ 62 s after the first publish, never two in a sample, with the pre-handoff `@+1s0ms` anti-vacuity read; `dumpsys power` shows `Haven:publish` `ACQ=` age ≤ 30 s and `ForegroundService:WakeLock` present throughout (P2a keeps it, deliberately) |
| Android, forced idle (**was the P2b merge gate**) | **NOT ESTIMABLE.** The term P2b removes is the AP awake-idle draw, and model E has no value for it (E-P3) | **NONE — the gate cannot be met and P2b is PARKED (§5.2).** The emulator does not suspend its AP, so no CI proxy exists for the question P2b must answer. **And when P2b un-parks, the liveness bound its forced-idle row is graded against is 228 s, NOT 248 s — owner decision 2026-09-09 (§4 OD-P2-4, L-125): D3 (iii)'s accepted cold residual does not extend to the scenario this gate exists to catch, and a device that misses 228 s there is a finding to file rather than a threshold to relax** |
| **LIVENESS — the only failable row here** — **NOT MET, re-verified 2026-09-08 by P6-B′ and again 2026-09-09: no lane feeds the grader a capture (§5.1 LIVENESS block); the only CI invocation is the `--self-test` in `repo-guards.yml`'s step "E2E harness self-test (relay liveness grader)"**. So it is failable **in principle and inert in CI**, which is what §5.6 Acceptance says in those words; this row was headed "HARD GATE" until 2026-09-09, and nothing in CI reds on it. What reds a build is the mechanism half — this table's right-hand column | not a battery figure at all | the grader exits **0** — GRADED, i.e. `--publishers` **and** the declared `--from`/`--until` window both given — with a max relay-side `created_at` gap **≤ 228 s** (never a tighter post-P2a figure — D3 (iii)'s accepted cold residual reaches 248 s on API 23–30) over a capture taken from an **emulator or simulator lane run**, not a phone. A gap figure without exit 0 behind it is not a liveness result (5 = head/tail silence ungraded, 3 = the capture proves nothing). Head and tail silence are graded as gaps and the whole-span count floor applies, so a run that publishes for 30 minutes of a declared 3-hour window fails — which is the field shape this instrument exists to catch |
| *(DEFERRED, still owed)* indicator state as D2 predicts for the recorded tier; profile duty recorded | — | **no CI substitute**: no simulator renders a status bar, and the profile-duty column is computed from a physical-device `locationd` console trace |

**Why the liveness clause survives without a phone, and what it does not cover.** The grader takes a relay-side
capture and a declared window; it does not care what produced the events. An emulator or simulator lane publishing
to the lane's own relay is a real Haven build, doing real MLS encryption, over a real socket, and the resulting
`created_at` series is graded by the same instrument the hardware protocol uses — so the *instrument* is unchanged
and only the *subject* is. **Residual, stated:** the window is a lane's minutes, not an afternoon; the emulator does
not suspend its AP and the simulator's suspension policy is absent (`M7`'s 2026-08-23 second changelog entry); and a device that merely
*slowed* behind a healthy peer is invisible to a multi-publisher capture (`POWER_MEASUREMENT.md` §3.6). So the
clause proves *"this build does not wedge"*, and does not prove *"this build survives eight hours in a pocket"*.

**Say this exactly, in every summary and every commit message: a green CI run proves the mechanism changed and that
publishing did not stop within the lane's window. It does not prove a battery number.** No estimate in §6.5a may
be restated without the word ESTIMATED in the same sentence, and no row of this table may be quoted as a result.

**The iOS rows are stated in device SoC %/h, not in Energy Log impact (review, 2026-08-30).** Instruments'
Energy Log reports an energy-impact SCORE plus component states, not battery percent per hour, and there is no
conversion; Settings → Battery's per-app row is a SHARE of app-attributed usage whose rows sum to 100 %, so a
delta between two screenshots moves when other apps run. Neither is a rate, so neither can carry a %/h
threshold. Both are still recorded on every row as ATTRIBUTION evidence — they answer "was it Haven?", and
which subsystem — while the whole-device SoC delta over the window, which the §6.5 controls make attributable
by leaving nothing else running, is the number. `docs/POWER_MEASUREMENT.md` §4 and §7 carry the operative
wording; where §6.5 above still reads "PRIMARY iOS metric" of the Energy Log it is superseded by that document
and by this row.

~~If a row fails its absolute but passes its relative threshold, the phase is not rejected — the absolute figures are
extrapolations (Evgenii's bare-session numbers; no Apple mA table exists) and the owner re-sets the absolute from the
measured value in `POWER_MEASUREMENT.md` with the reason.~~ **AMENDED 2026-08-30 (§2.5): there is no absolute row to
fail and no relative row to pass — both are ESTIMATED predictions now, and a prediction is not a gate.** The
re-setting instruction survives and is the right one for the day hardware returns: the owner runs §6.5's protocol,
writes the measured value into `POWER_MEASUREMENT.md`, and *that* value replaces model E's estimate everywhere,
with the reason recorded. Until then, the paragraph above about SoC vs Energy Log stands as guidance for that future
run, not as a description of anything anyone has done.

**What still blocks, and what does not.** A power win that reopens the 2 h wedge fails on the LIVENESS clause — that
is unchanged, and it is the only clause in this table with teeth **in principle**. Say the second half too, because
this sentence stopped short of it until 2026-09-09: those teeth are not yet wired to CI, since no lane feeds the
grader a capture, so what actually blocks a merge today is the right-hand column's mechanism proxies (§5.6
Acceptance). ~~a merge-gate row (P3 0a, P2b forced idle) that fails its
liveness clause blocks the phase, not the release~~ → **P3's 0a is DEFERRED and its merge gate is re-based on the
CI bundle (§5.3), which does block the phase; P2b's forced-idle row is unmeetable, so P2b is PARKED rather than
merged on weaker evidence.** The distinction the original sentence drew — a merge-gate failure blocks its phase, not
the release — is preserved exactly: parking P2b blocks P2b and nothing else, and P2a, P1, P3, P4 and P5 ship.

### 6.7 What we will know, and when (added 2026-08-30, §2.5)

The constraint does not make this work unverifiable; it moves the boundary between what is proven and what is
predicted. This section says where that boundary now runs, so nobody has to reconstruct it from the phase sections.

**What CI proves today — mechanism and in-window liveness.** That exactly one Android location registration exists
while backgrounded and that its interval is ≥ 62 s (B1's parsed `dumpsys location` oracle, with its anti-vacuity
read). That the scoped `Haven:publish` lock is never held longer than 30 s and that the plugin lock is still there in
P2a. That the publish pool carries no keepalive and leaks no subscription, and that the engine pool *keeps* its ping
while subscribed. That iOS asks for, and CoreLocation honours, `hundredMeters` from a genuinely backgrounded process.
That the session/indicator policy follows the granted tier in both directions, and that a provisional escalation
reds the run instead of silently swapping branches. That a backgrounded iOS process keeps publishing across a real
OS background transition on the simulator. That a burst holds no standing REQ and folds the inbox every k-th time.
And — the one that matters most — that across every one of those lane runs the relay-side `created_at` series has no
gap over 228 s, graded over a **declared** window by an instrument whose own fixtures are self-tested in
`repo-guards.yml`. That is a large amount of proof, and none of it needs a phone.
**Correction, 2026-09-03:** the last of those is written in the present tense and is not true yet — the grader is
invoked only as `--self-test` and no lane feeds it a capture, so today it proves the instrument, not any build.
Every other claim in this paragraph is either already CI-borne or is a done-criterion of the phase that owns it;
this one is a claim about work item 3 below, which has not been done. Read it as the target, not the state.

**What only a device can prove — three things, and they are the same three every time.** (1) **A battery number**:
device SoC %/h, GPS sensor seconds, radio-active seconds, wake-lock seconds, discharge share. No emulator, simulator
or model produces one. (2) **Rendering**: whether the status bar shows the blue pill, the arrow, or nothing, under
each authorization tier — and whether the iOS 18/26 stuck-indicator bug (V-P3-5) bites on disarm. (3) **True
suspension**: whether the confirmed-Always shape keeps delivering for *hours* (V-P3-3), whether a location delivery
wakes Dart once the Android AP is genuinely asleep (U-P2-1, the reason P2b is parked), and what the real HAL and GMS
`fused` backend do (I-P2-1, I-P2-2). Everything in §7.5 tagged NOT AVAILABLE falls into one of these three.

**What the owner can observe post-release, with no telemetry.** Haven ships no analytics and never will (§2.5), so
this is deliberately low-tech, and it is enough to catch every failure this plan is afraid of. On the owner's own
phone: leave it on a desk overnight with sharing on and look at Settings › Battery in the morning — a per-app row
that has grown instead of shrunk is a finding; look at the status bar after backgrounding under each tier; and ask
the peer device whether the marker ever aged past the 5-minute pill. That is a **weak proxy for** the 228 s
liveness clause, not the *user-visible form* of it (corrected 2026-09-09): the pill thresholds at
`kMemberAgePillThreshold` = **300 s**, above the 228 s bound, and the receiving phone's own fetch runs once per
`kLocationUpdateInterval` — `POWER_MEASUREMENT.md` §3.1 argues from exactly that pair that a healthy run
routinely *reads* as `168 + 120 s` stale, so the pill cannot resolve the clause and the evidence has to come
from the relay. A pill that DOES go grey is worth reporting; a pill that does not is not a pass. From users, unprompted and unsolicited: "my battery got better/worse after the update", "the blue
bar is gone", "it stopped sharing again" — the third is the one to treat as a P0 incident, because it is the FA
wedge reported in the only channel that exists. None of this is data collection; all of it is somebody looking at
their own phone and saying so.

**Follow-ups to fund later, in the order they buy the most.**
1. **One Android handset** (no macOS, no iPhone). Unblocks: the entire `POWER_MEASUREMENT.md` §5 Android run, which
   settles E-I1/E-I2, E-P1 and E-P3 in one 60-minute window; the P2b forced-idle liveness row, which **un-parks
   P2b**; and I-P2-1/I-P2-2. Highest value per unit of cost by a wide margin, because it converts a parked phase
   into a shippable one and replaces three model parameters with measurements.
2. **One iPhone** (plus a macOS machine for the Console/Instruments half — an iPhone alone still gives Settings ›
   Battery, the status bar, and the peer's marker age, which is most of item 0a). Unblocks: M7 §6 0a / 0a-provisional
   / 0b / 0c, V-P3-2 through V-P3-5, the profile-duty column and OD-P3-a's re-tuning, and the iOS half of §6.6.
3. **A standing CI step that grades each lane's relay-side traffic.** Note the honest starting point: today the
   grader is invoked in CI only as `--self-test` (`repo-guards.yml`, step "E2E harness self-test (relay liveness
   grader)" — by step NAME, never a line number: this citation has drifted three times, most recently onto a
   DIFFERENT guard's self-test) — the instrument is built and fixture-tested, but nothing yet feeds it a real capture. The re-based
   liveness gate (§6.6) makes each phase's lane packet add an export-and-grade step. This is the "potentially CI
   steps" the owner named, it needs no hardware at all, and it is the highest-value follow-up that can start
   immediately.
   **P1 did NOT deliver its share of this, and the reason narrows the follow-up rather than excusing it (2026-09-03).**
   The hard part is finding a lane whose window is BOTH longer than the 228 s bound and guaranteed to carry two
   location events, because the grader fails a one-event series. No Android lane has one: the only natural-cadence
   publish window in the tree is B1's 200 s hold, which is shorter than the bound. (Its *event-count* half was
   fixed by P2a's landing — the delivery-driven cadence guarantees a second publish inside one
   `kLocationPublishMaxInterval`, which step (7) now asserts — so the remaining obstacle is the window LENGTH
   alone; corrected 2026-09-04.) The lane that does have one is `e2e-ios-background-publish` (P2b, 396 s, ≥ 2 events already
   asserted), and it runs the in-memory `local-relay` with no export path — so the first concrete unit of this
   follow-up is **a `dump_events` bin for `tooling/e2e/local-relay` plus a window-declaring handshake from the iOS
   drive**, not a generic sweep over every lane. §5.1's LIVENESS block carries the full four-part list.
   **"Generalise the strfry export to a standing step" is withdrawn as written (CI-R16, 2026-09-03).** A post-hoc
   `docker exec … strfry scan` is **TTL-truncated**: kind-445 application messages carry
   `expiration = created_at + 228 s`, both hermetic relays honour NIP-40 (strfry on its own eviction cron; the
   iOS lane's `LocalRelay` the same way), so a scan taken at the end of a run returns at most the trailing ~228 s
   of it — and any window long enough to make `--max-gap` meaningful is, by construction, long enough to have lost
   its own head. Grading a long window off a relay therefore needs a capture taken DURING it (repeated scans or a
   live subscription), not one export at the end. The capture that has no such problem is the **wire-proxy
   journal**, which records what was SENT and is immune to eviction by construction
   (`tooling/e2e/local-relay/src/lib.rs:12-19`) and already runs in the Android and iOS core-flow lanes; wiring it
   costs one `jq` projection, because the grader rejects the length-2 `["EVENT", {…}]` client frame. Its three
   caveats — B1 does not run the proxy; the lanes that do run a scripted ~720 s scenario with no jittered cadence
   to grade; and the uploadable summary redacts exactly the event ids and `h` values the grader keys and prints on
   — are set out in §5.1's LIVENESS block, and they are what a funded attempt has to answer first.
4. **Re-derive model E from the first real rows.** The day either device exists, the first job is not a new
   measurement campaign — it is substituting E-P1, E-P2 and E-P3, re-running the arithmetic, and recording how far
   the estimates were off. That number is the honest measure of how much any of §6.5a should have been believed.

---
## 7. Appendices

### 7.1 Consolidated ARB key changes (13 locales: en, ar, de, es, fa, fr, hi, ja, ne, pt, ru, tr, ur; workflow per CLAUDE.md l10n rule)

Only surfaces that still exist: the four Privacy-page rows v3 carried here (presence, one-connection, jitter detail, the activity-pattern band note) left with the page on 2026-08-29; their gating facts survive in D6 (vi)/D7 and `haven-core/SECURITY.md`.

| Key (`app_en.arb`) | New English text | `@description` (essentials) | Phase | Copy-tie test |
|---|---|---|---|---|
| `locationSettingsIosGuidance` (`:473`) — becomes the tier-neutral BASE | "While background sharing is on, Haven keeps a location session running so your circles keep seeing you." | iOS-only reliability card, rendered ONLY under `IosAuthStatus.always` (the page gate changes from `!iosLimited`, which also rendered it under denied/notDetermined/restricted/unknown), composed in this ORDER: base → exactly ONE of the two indicator keys (chosen by the session handler's `alwaysConfirmed` — never by tier, and never by `backgroundActivitySessionHeld`, which is false on the iOS 15/16 floor while the bar is up) → **and nothing else. CORRECTED 2026-09-04: the card is TWO sentences; the catch-up key was deleted (CI-R23) once the tier gate left it no reader.** MUST NOT name any indicator ("blue", the phrase "blue location bar", "arrow", "indicator" — bare "bar" is not a forbidden word), make a battery promise ("low-power" is banned — the session is at GPS accuracy while moving or on screen), or say "pause"/"timer". The accuracy tier lives HERE, not in the copy: while stationary in the background the session runs at ~100 m accuracy and returns to GPS accuracy on movement. | P3 | `ios_indicator_copy_accuracy_test.dart` (en ↔ Swift), `l10n/location_settings_copy_accuracy_test.dart` (13 locales), `pages/location_settings_page_test.dart` (asserts the render order); b7 as a lane oracle |
| ~~NEW `locationSettingsIosCatchUp`~~ **DELETED 2026-09-04 (CI-R23)** | ~~"Granting \"Always\" additionally lets Haven catch up on your circles after iOS closes the app."~~ | Added in P3 so the catch-up sentence could render LAST, then never composed in: the card is gated on `IosAuthStatus.always`, so an inducement to GRANT "Always" reaches only readers who already hold it. It shipped in 13 locales and rendered nowhere, and was deleted with its `@description`, its twelve translations and its byte-identity pin. The `INV-L-IOS-WAKES-RECEIVE-ONLY` assertion it carried rests on `locationSettingsIosLimitedNote`, which renders under While-In-Use — the cohort the advice is actually for — and on the disclosure key `locationSettingsIntro`, which renders in every state. No `ratchet_override` was needed (§7.3). | P3 (removed) | — |
| NEW `locationSettingsIosIndicatorArrow` | "iOS shows its small location arrow in the status bar while Haven uses your location, and lists Haven in your iPhone's Location Services settings." | Selected when the handler reports `alwaysConfirmed` true — a CONFIRMED Always, which holds no activity session (D2). NOT "holds no activity session": that set also contains unconfirmed iOS 15/16 users, who must get the bar sentence. Tier-neutral Settings wording on purpose: iOS 15 (deployment target 15.5) has "Settings → Privacy → Location Services", iOS 16+ "Privacy & Security" — a version split localizers cannot fix; use the OS's localized "Location Services" name. Breadcrumbs, where any, use "→" (read by screen readers; the ARB convention, `locationSettingsAndroidBattery` `:465`), never "›". Never "blue" nor the phrase "blue location bar" ("status bar" is required — bare "bar" is fine). If OD1 is declined this key is never selected — say so here. | P3 | same tests |
| NEW `locationSettingsIosIndicatorBar` | "While Haven shares in the background with this permission, iOS shows its blue location bar at the top of the screen." | Selected when the handler reports `alwaysConfirmed` false: provisional Always, iOS 17 Always, the iOS 15/16 floor (no `CLServiceSession` API at all), and — if OD1 is declined — every Always. ONE noun everywhere: "blue location bar" (never indicator/pill). This key IS the OD1-declined variant of the card, so the copy-tie test has a target in both outcomes. | P3 | same tests |
| `locationSettingsIosLimitedNote` (`:453`) | "Sharing keeps working in the background with your current permission, and iOS shows its blue location bar at the top of the screen while it does. Choose 'Always' for Haven in Settings so Haven can also catch up on your circles' locations after iOS closes the app. Your own sharing resumes when you reopen Haven." | Renders only under While-In-Use. Sentence order is state → advice → resume (the bar sentence is NOT appended after "resumes when you reopen Haven" — disjointed). The bar sentence is TRUE there on iOS 15–26 (mandatory OS behaviour, QA1965; Haven also holds a `CLBackgroundActivitySession`). Under confirmed Always the card shows the arrow key instead — never merge the two. `background_claim_accuracy_test.dart:106-138` passes either way (V). | P3 | same tests |
| NEW `settingsLocationSubtitleOn` / `settingsLocationSubtitleOff` | "Background sharing on" / "Only while Haven is open" | Dynamic subtitle of the Settings hub Location tile, driven by `backgroundSharingProvider`; merges into the tile's semantics (name = title + subtitle; a hub tile has no toggle state to announce); it reports the SETTING, never service health — "Only while Haven is open" is true on both platforms with the toggle off — the one standing affordance that says what the app is doing without a map-shell indicator (no Always-tier reference app has one; a foreground-only banner would compete with the two fault banners); no platform words, no indicator words. | P3 (adopted bar-raise) | widget test from the provider (both values; semantics label contains the subtitle) |
| `fgsNotificationSharing`, `locationSettingsBatteryOptNote`/`AndroidBattery`, `locationSettingsIntro`/`ToggleSubtitle`, ~~`LocationDisclosureStrings.*`~~ **the `locationDisclosure*` ARB keys (moved out of hard-coded Dart 2026-09-04, OD-P3-g; `locationDisclosureBackgroundIos` took the same prose repairs as `locationSettingsIntro` and is now tied to it by a claim-level divergence test)**, the Play dialog, `fgsChannelDescription` | UNCHANGED — each stays literally true (§3 D1/D3/D4/D6 proofs; verified by the UI/UX review) | — | all | existing tests |

### 7.1a l10n reviewer wave — outcome and corrections (2026-09-03/04)

CLAUDE.md requires per-language translation agents AND a **separate, independent
reviewer agent per language**. That wave ran in three batches (de/fr/es/pt ·
ru/tr/ja · ar/fa/ur/hi/ne), judging both the output **and the translators'
stated reasoning**. Verdicts: 3 APPROVE (de, ar, ur), 9 APPROVE-WITH-CHANGES, 0
rejected. Every reviewer-supplied replacement was applied verbatim.

**Substantive copy defects caught (all would have shipped):**

- **tr** — `konum oku` is a translator coinage; Apple's Turkish ships `ok
  simgesi`. The premise behind the coinage was real (bare `ok` occurs 30+ times
  in the file, so it needed qualifying) but the conclusion did not follow.
- **ja** — `掲載します` is publication register ("carried in a publication");
  the file uses 表示 11×, and Apple uses 表示されます.
- **ru** — `с этим разрешением` put the permission into the *recipient* slot of
  "share WITH someone"; `указывает` was a gloss for "lists".
- **es/pt** — a doubled connector against the base sentence (`Mientras`/
  `Enquanto` → `Cuando`/`Quando`).
- **es** — an unclosed preposed adverbial let `hace iOS` garden-path as "*while
  iOS does it*", silently swapping the subordinate clause's subject.
- **fr** — the menu name needed guillemets (with NBSP).

**The cross-cutting rule the wave produced.** The iOS menu name had been
localized inconsistently — and almost exactly backwards. RULE ADOPTED: *name the
menu in the locale's own language only where Apple SHIPS iOS in that language
AND the exact shipped string is verified; otherwise keep the English "Location
Services", matching each ARB file's existing convention for OS menu names.*
Applications: **ar** `خدمات الموقع` kept (verified); **hi** `स्थान सेवाएँ` →
`स्थान सेवा` (Apple ships the singular); **fa** and **ne** → English, because
Apple ships **no iOS UI at all** in Persian or Nepali, so a translated name
pointed at something that exists on no iPhone; **ur** now uses
`لوکیشن کی خدمات`.

The ur decision was recorded with a wrong reason **twice**, and the second
correction is the instructive one. The original note said Apple ships no Urdu
iOS UI — false; Urdu is a shipped System Language per
`apple.com/ios/feature-availability` (the iPhone tech-specs language list omits
it, but that list also omits Bangla, Gujarati, Kannada, Malayalam, Marathi,
Odia, Punjabi, Tamil, Telugu and English (India), and links out to
feature-availability — it is a stale marketing subset, not the criterion). The
replacement note said the exact Urdu string could not be verified — also false,
and false for a reason worth keeping: the check had looked only at Apple KB
102647/102515, which serve **English** on `ur-IN`. Apple translates the *device
User Guides* into Urdu, and `لوکیشن کی خدمات` appears 19× in each of the
independently-translated iPhone and iPad guides
(`support.apple.com/ur-in/guide/iphone/iph3dd5f9be/ios`,
`.../guide/ipad/ipadb7c27772/ipados`), with the full path
`سیٹنگ > رازداری اور تحفظ > لوکیشن کی خدمات`. **A negative result from one
Apple surface is not a negative result** — when a KB article is untranslated,
check the User Guide before concluding the vendor ships no term. ur's `'Always'`
correctly stays English on a narrower verified ground: Apple's Urdu guides print
`ہمیشہ` only as running prose, never as a quoted control label, so there is no
shipped string to quote. de/fr/es/pt/ru/tr/ja were
verified against two independent Apple articles required to agree; **fr** is
confirmed SINGULAR `Service de localisation`.

**Reasoning errors with acceptable output** — recorded because the next change
inherits the reasoning, not the output: the "reuses the toggle title's noun
phrase" rationale held only for de (fr/es/pt were byte-identical to existing
snack strings; ru/ja were lifted from the guidance string), and the "mirrors the
intro clause" rationale was false for tr, fa and hi.

**Guard weakness found and fixed.** ru's `barPhrase` was pinned in the
ACCUSATIVE only, so a rewording into the nominative would have slipped past
*both* the "must name the bar" and the "must not name the bar" checks at once —
failing open in both directions simultaneously. Bar phrases are now pinned as
case-invariant **stems** in all 13 locales (ru `полос`; tr `konum çubu`,
qualified to miss `durum çubuğunda` and cut before the k/ğ alternation; ja
`位置情報バー`, since bare `バー` collides with `ステータスバー`). Because a stem
drops the colour adjective, a companion assertion now requires the locale's word
for "blue" in the bar string and the note — without it the shortened stem would
have quietly weakened the required direction to "names *any* bar at all".
Self-tests pin the ru accusative/nominative pair and the tr suffixed/bare pair.

**Attribution defect found after the wave, and the 13-locale clearance.** The
bar sentence exists to say the blue bar is the OS's *mandatory* behaviour, not
Haven's choice — the `@description` says so, and
`test/lints/background_claim_accuracy_test.dart` guards the claim family. In
**hi** the sentence could be parsed the other way round: `iOS स्क्रीन` merges
into one noun phrase ("the iOS screen"), the verb loses its overt subject, the
जब…तब correlative supplies **Haven** from the previous clause, and the reflexive
`अपनी` then makes it *Haven's* blue bar. The misreading is self-consistent —
apps do draw their own UI — so nothing prompts the reader to re-parse. Fixed by
moving the object ahead of the locative (`iOS अपनी नीली स्थान पट्टी स्क्रीन के
शीर्ष पर दिखाता है`): a genitive cannot be the second member of an N-N compound,
so `iOS स्क्रीन` becomes unconstructible and `अपनी` sits adjacent to its binder.
The attribution is now enforced by structure, not context. The `hi` limited note
carries the same trigger but not the same consequence (its only recoverable
subject is `साझाकरण`, and "sharing shows its own bar" is incoherent, so the
reader recovers `iOS`) — it garden-paths without misleading, and was reordered
for readability, not correctness.

**ur carried the same defect at BOTH call sites, and worse.** An independent
Urdu reviewer confirmed the compound reading is not merely available there but
is the file's own default: `app_ur.arb` already writes `OS ترتیبات`,
`Nostr نیٹ ورک`, `Haven اکاؤنٹ` and — in the neighbouring arrow string —
`iOS اسٹیٹس بار`, so the reader is trained to parse `iOS اسکرین` as "the iOS
screen". Urdu is pro-drop, so the stranded clause triggers no repair, and the
file treats both `iOS` and `Haven` as masculine, so agreement gives no signal
either. In `…IndicatorBar` the misparse completes silently (the جب-clause
subject `Haven` is masculine and matches `دکھاتا ہے`); in `…LimitedNote` the
feminine `شیئرنگ` blocks the nearest antecedent but only forces a search that
lands on `Haven` anyway. Fixed with two DIFFERENT structures, each argued from
its own clause: the bar string fronts the locative so `iOS` sits immediately
before `اپنی` (a possessive adjective cannot be a compound's second member), and
the note keeps its word order and instead breaks the compound with an explicit
possessor, `iOS آپ کی اسکرین` (Urdu cannot stack a bare possessor before a
genitive one). The three reviewers who fixed this defect independently chose
three different repairs; none was applied by analogy. `…IndicatorArrow` was
assessed and left alone — it has no `اپنی`, and its second conjunct
self-corrects, since a null-`Haven` subject would read "Haven lists Haven".

The mechanism needs BOTH an `iOS`+noun compound *and* a possessive that can
rebind. Checked in all 13; only hi and ur have both, each other locale being
protected by a different feature — ja `iOS は` and ne `iOS ले` mark the subject
explicitly (ne uses the reflexive `आफ्नो`, but the ergative anchors it), tr uses
a comma, ar is verb-first (`يعرض iOS`), fa and ru carry no possessive at all,
and de/en/es/fr/pt place iOS in unambiguous subject position ahead of theirs. A
future rewording that introduces a possessive into fa/ru, or drops a subject
marker in ja/ne/tr, re-opens this — the check is "can the bar's owner be read as
Haven", not "is the grammar valid".

**Open, minor:** fr guillemet spacing is now mixed in-file (~~the new arrow string
uses U+00A0, five older strings use U+0020~~ **measured 2026-09-09: THREE strings use U+00A0 — all three new or changed
in this batch — and THREE use U+0020. The six-string total was right; the per-side split was not. Guillemets ONLY: the
file's colon convention is settled 28:0 on a plain space, so this asks for no change there**). NBSP is the typographically correct
half — a breaking space lets `»` wrap alone — but two of the older strings are
outside P3, so harmonizing them is an owner call.

### 7.1b Second l10n wave — the revised copy + the consent dialog (2026-09-04/05)

OD-P3-f and OD-P3-g put 13 keys × 12 locales through the full CLAUDE.md
workflow again (translator agents ×3 batches → INDEPENDENT reviewer agents ×3).
The reviewers judged **reasoning as well as output**, which is what caught the
items below.

**Defects that would have shipped:**

- **tr `olduğundan` → `olduğunda`** — the translator's form is CAUSAL ("because
  your permission is Always, iOS shows the blue bar"). False in the dangerous
  direction: the tier does not cause the bar (a While-In-Use user gets it too),
  and it is a CONFIRMED Always that removes it. One suffix, asserting the
  opposite of the phase's central fact.
- **pt `locationDisclosureHow` attribution leak** — one `que` governing three
  coordinated finite clauses. Portuguese also permits re-parsing clauses 2-3 as
  new main clauses with the same fronted subject, at which point **Haven
  asserts Stadia's cookie and retention policy as its own fact**. Fixed by
  repeating `que`. de/fr are structurally immune (infinitive complements cannot
  be main clauses); es already repeated it; pt was the only misparseable one.
- **ja 「常に許可」 → 「常に」** ×3 — Apple's ja page lists the per-app *Settings
  rows* as 「…このアプリの使用中」「常に」; the 〜許可 forms are the *alert*
  buttons. The copy points the reader at Settings.
- **ja arrow repeated connector** — a NEW instance of the "While… While…"
  defect, in the ARROW composition, which nobody had checked because every
  earlier repair was on the bar sentence. Base and arrow both opened on the
  identical morpheme 「間、」. Fixed by fronting 「iOS は、」.
- **es intro not self-contained** — the iPhone sentence said `ese envío`,
  anaphoric to a noun introduced in the *Android* sentence, defeating the whole
  point of the platform split (a reader must be able to skip the sentence about
  the other phone).
- **es `durante un rato`** — quantified Apple's window downward to "a few
  minutes"; Apple documents up to 24 h. The window is deliberately unquantified.

**Guard fragilities found (act on these before trusting the guard):**

- **tr near-miss by ONE letter**: `locationSettingsIosGuidance` contains
  `konum oturumu`, which misses the pinned `konum ok` stem only because of the
  `t`. A rewording could collide silently.
- **fr depends on an apostrophe codepoint**: the guard pins `barre d'état` with
  U+0027 and `app_fr.arb` happens to use U+0027 in all 163 apostrophes. Had the
  file used U+2019 the guard would have failed OPEN in the forbidden direction
  too — the same both-directions failure the ru accusative pin had.
- **ru coincidence, not design**: the guard's `oldSentence` ban list contains
  `синий индикатор`, which is Apple's own ru wording for the indicator. It is
  scoped to the base sentence only, so there is no conflict today.

**Corrected premises (the output was fine; the reasoning was not):**

- "Apple documents no name for the blue indicator" — **false in ru/tr/ja**;
  Apple describes it (`mavi bir çubuk`, `синий индикатор`,
  「青いカプセル状のアイコン」), but with two different descriptions per language
  across two pages, so there is no shipped LABEL. The coinages stand because the
  English key fixes one noun and bans "indicator"/"pill", not because Apple is
  silent.
- "`app_de.arb` quotes OS menu names undeclined" — **false**; its only other
  example is `aus den „Ruhenden Apps“`, article supplied AND declined inside the
  quotes. The real rule is narrower: `unter` + a quoted heading takes no
  declension; other prepositions still inflect.

**Verified externally** (the translators had no network): Google's published
prominent-disclosure localizations — de and pt-BR are exact character matches,
es was a hybrid of the es-ES and es-419 forms and is now aligned to es-419, fr
deviates only where Google labels the text *recommended*; ru/tr/ja carry
Google's sanctioned accepted-phrases. All 12 keep "uses", never "collects".
Apple's menu names re-confirmed from raw HTML, two sources each — fr is the
SINGULAR `Service de localisation` (the plural appears only in generic prose,
never as the screen name) and es `Servicios de localización` is WRONG for the
screen name.

**Out of scope, flagged not changed:** `app_ja.arb`'s
`locationSettingsAndroidBattery` renders "Battery → Unrestricted" as
「バッテリー → 常に許可」; Android ja ships 「制限なし」. Needs its own 12-locale
audit. And es `locationSettingsIosGuidance` uses a bare infinitive as subject
where the note below it uses `el uso compartido en segundo plano`.

### 7.2 Consolidated guard changes

| Script | Check | What it pins | Fixtures / count | Phase |
|---|---|---|---|---|
| `scripts/ci/check_engine_client_options.sh` | RESTRUCTURED into function-shaped checks returning rc (`check_publish_pool_options`, `check_engine_pool_options`, `check_ffi_add_relay`; every check runs; `exit 2` for missing paths) + checks 3–7 + `--self-test` (none today) + a `--self-test` step in `repo-guards.yml` | `fn publish_relay_options` body has `.ping(false)`, `.reconnect(false)`, `.sleep_when_idle(true)`; every `.add_relay(` in `manager.rs` passes `publish_relay_options()` (exactly one `// negative control` exception); `session.rs` has neither the CALL `\.ping[[:space:]]*\([[:space:]]*false` nor `\.sleep_when_idle[[:space:]]*\(` (the bare word is in two kept comments); `api.rs` has no `.add_relay(` except the `// e2e helper` in `fetch_by_kind`; `manager.rs` has no `subscribe_to(`/`subscribe_with_id_to(` | `SELF_TEST_FIXTURES=12` by equality, asserting on the message (clean; comment with bare `sleep_when_idle` PASSES; `verify_subscriptions(true)`; pin deleted; `ping(true)`; fn missing; bare `client.add_relay(`; `.ping(false)` call in session.rs; `.sleep_when_idle(true)` call in session.rs; `subscribe_to(` in manager.rs; unmarked `.add_relay(` in api.rs; a second `// negative control` marker) | P1 |
| same | `check_engine_pool_options` REWRITTEN | + `fn pause_subscriptions` body reaches `note_delivery_gap` (directly or via the `Pause` marker), contains NO `forget_` token, contains `client.disconnect()` and NO `client.shutdown()`; no standing-REQ call reachable from the burst entry — NO call-order pins | 13 (+`forget_inbox_subscription` in the pause path; `client.shutdown()` instead of `disconnect()`; a standing-REQ call in the burst path) | P4 |
| `scripts/ci/check_android_location_power.sh` NEW (repo-guards step after "Location access gate …" `:709-721`) | (7)(8) | `suspendStream(` precedes `markForegroundActive(active: false)` in `_onPaused`; that call sits inside a `shouldKeepLocationStreamWhilePaused(` conditional, never a raw platform branch | **6 as landed** (three pairs, not two: a deletion pair was added — a token check with no "the call is gone entirely" / "only a comment describes it" fixture passes a file whose call was removed) | P1 |
| same | 1–6 (function-shaped) | (1) `ForegroundTaskOptions(` slice (comment-stripped) has NO `allowWakeLock` — P2a; (2) `PublishWakeLock.kt` shape (`PARTIAL_WAKE_LOCK`, `setReferenceCounted(false)`, `coerceIn(1L, MAX_TIMEOUT_MS)`, `MAX_TIMEOUT_MS = 30_000L`, no bare `acquire()`, NO `setMethodCallHandler(null)`/`release()` inside the lifecycle listeners) + `addTaskLifecycleListener(PublishWakeLock)`; (3) manifest `WAKE_LOCK`; (4) `getLocationStream(` called only from `location_provider.dart` + `background_location_task.dart`; (5) exactly TWO `_ensureRegistration(` call sites (the aim, and the retry cadence), both inside `_publishCycle` after both gates, `_cancelRegistration(` before `_inFlightPublish?.timeout(` in `onDestroy`; (6) background arm has no `timeLimit:`, has `forceLocationManager: true` + `distanceFilter: 0` | each check one passing + one mutated, pinned by equality | P2a |
| same | (1) flipped + native pins | `allowWakeLock:` bound to the exemption predicate (`!isIgnoringBatteryOptimizations`), never a literal; native registration acquires inside the delivery hold; no `requestLocationUpdates(` outside the channel handler; `cancelRegistration` at both disable sites; the receiver re-reads the toggle + both disclosure prefs | +5 | P2b |
| `scripts/ci/check_ios_background_publish.sh` | 5 → function-shaped `check_stream_provider` | `locationStreamProvider` body: `ref.watch(backgroundSharingProvider)`, `getLocationStream(backgroundSharingEnabled:`, `ref.read(appForegroundProvider)`; no `getLocationStream(` inside the not-foregrounded block; no `ref.watch(appForegroundProvider)` outside it | 5 (passes; foreground build watches; start inside the paused block; the `!bg` clear deleted; body commented out) → **24 as landed** (the "→ 23" this row carried was an arithmetic slip against §5.1's own 19 → 24) | P1 |
| same | header + check 2 comment | "one plugin boundary; one owner per isolate, exclusive by lifecycle" | none (24) | P2a |
| same | 2, 3, 4 (→ `check_ios_stream_route` incl. `lastBestFix(` before `getCurrentPosition(` and `clearLastBestFix(`), NEW `check_native_stream_handler` (16: incl. `allowsBg` derivation, `?? true`, `!= .active`, `return FlutterError(`, `bestSince`, `onCancel` clear), 8 (→ `check_arm_tier_policy` carrying all eight existing pins + `alwaysConfirmed` + the background guard), 7, 9 (wiring order), 11 + 12 (→ `check_bg_publish_drive`, native source provider banned), NEW 14 (pbxproj ×4), file list, header (`-1` trap moot), `OK:` line | §5.3 Guards | `SELF_TEST_FIXTURES=47` expected (8 route + 16 native + 7 tier + 2 drive + 9 region + 5 provider), pinned by equality at what lands | P3 |
| same | 6 neighbourhood | iOS pause branch calls `pauseSubscriptions` on the C4 edge | +1 (48; 25 if before P3) | P4 |
| `scripts/ci/check_m7_native_wake_guards.sh` | 10 FACTORED into `presence_only_log_scan <file>` + a second fixture block (`EXPECTED_LOG_FIXTURES` by equality); `LOG_FN` + `Log\.[dweiv]\(`; error-internals + the Kotlin 3-arg Throwable form and `\$\{?e\b`; 13 list | + `PublishWakeLock.kt` (P2a); + `HavenLocationStreamHandler.swift`, `ios_location_source.dart` (P3); check 13 + `locationStreamHandler` (P3) | today's six files pass; `Log.d("lat=$lat")` fails; `Log.e(TAG, "x", e)` fails; `Log.d(TAG, "acquire")` passes; `NSLog("\(location.coordinate)")` fails; one planted-coordinate fixture per new file | P2a, P3 |
| `scripts/ci/check_live_sync_restart_budget.sh` | UNCHANGED | it is a numeric-derivation guard over `config.rs`/`cursor.rs`/`live_sync_resubscriber.dart`/`location.dart`; the "`_onResumed` references `isPaused` beside `shouldReanchorOnResume`" pin is a source-order TEST in `map_shell_location_access_lifecycle_test.dart` | — | P4 |
| `scripts/ci/check_location_access_gate.sh` | 1–3 (name-bound); 8 | re-pointed only if `_publishCycle`'s read path changes; `getLocationStream(` order pins; `getLastKnownPosition(` token kept by the helper name; check 8 resolves `_dispatchTick`'s `.timeout(` (P4) | `--self-test` | P2a, P3, P4 |
| `scripts/ci/check_mls_session_single_owner.sh`, `check_liveness_port_single_owner.sh`, `check_teardown_drain_budget.sh`, `check_no_event_timestamp_cursor_advance.sh`, `check_publish_jitter_fraction_parity.sh`, `check_e2e_publish_before_apply.sh`, m7 14b, `check_no_key_logging.sh` (key material only — it does not check URLs) | unchanged | must stay green (run them) | — | all |
| `tooling/e2e/ci/summarize-created-at-gaps.sh` NEW (repo-guards step beside the other `tooling/e2e/ci` harness self-tests) | ~~`--self-test` only — the grader runs on the owner's laptop over a hardware capture, never in CI~~ → **AMENDED 2026-08-30 (§2.5): with no hardware, the re-based LIVENESS gate (§6.6) runs the grader IN CI over each phase lane's own strfry export. That export-and-grade step DOES NOT EXIST TODAY (the only invocation in the tree is the `--self-test` in `repo-guards.yml`'s step "E2E harness self-test (relay liveness grader)") — it is NEW work each phase's lane packet must add: export the lane's strfry to ndjson, pass `--publishers` and the lane's declared `--from`/`--until`, and require exit 0. §6.7 follow-up 3 generalises it to a standing step. The `--self-test` step stays exactly as it is.** **STATUS 2026-09-03 (P1-D): STILL NOT DONE, and the reason is a lane property, not an instrument one.** B1 is the only Android lane with a natural-cadence publish window and its 200 s hold is shorter than `--max-gap` (228 s), so the bound cannot fire in it (the second half of this objection as written on 2026-09-03 — "a healthy run can legitimately carry ONE event" — was true of the retired 72 s poll and died with P2a's landing; step (7) asserts ≥ 2 publishes in the window today, corrected 2026-09-04); the iOS bg-publish lane has the right 396 s window and an already-asserted ≥ 2 events but runs the in-memory `local-relay`, which cannot be exported at all. The four pieces that would close it are itemised in §5.1's LIVENESS block. **A further correction (CI-R16, 2026-09-03): "export the lane's strfry at the end and grade it" does not generalise — a post-hoc `strfry scan` is TTL-truncated by the kind-445 NIP-40 expiration (228 s), so it returns at most the trailing ~228 s of any window, and any window wide enough for `--max-gap` to mean something has already lost its head. See §6.7 follow-up 3 and §5.1's LIVENESS block for the wire-proxy-journal alternative and its three caveats.** Every phase that quotes this row must state NOT MET until they land — **P2a stopped quoting it as a gate on 2026-09-04 and records it DEFERRED with its successor named (§5.2 Acceptance); P1 already records NOT MET (§5.1).** | that the relay-side liveness oracle can still fail: head/tail silence against the declared `--from`/`--until` window, both event-count floors, the split-circle refusal, and that an undeclared window is UNGRADED (5) rather than OK | `SELF_TEST_FIXTURES=40` by equality | P0 |
| `tooling/e2e/ci/run-b1-fgs-publish.sh`, `run-ios-bg-publish.sh`, `run-b7-ios-auth-tier.sh`, `run-b9-network-reconnect.sh` | lane self-tests | B1 oracle steps 5–8 with the `dumpsys location`/`dumpsys power` grammar fixtures and the 55/54 s pair in the same commit (**5–8 all landed, `[8/8]`, 2026-09-04**); bg-publish P1 tier pin + status oracle, P2b bounded poll, P2c in-process marker (+ C7, + `ALWAYS_SESSION_OK` in the Always job); b7 session + `alwaysConfirmed` oracles; b9 `PUBLISH_AFTER_IDLE_OK` asserted from the first landing | per lane `--self-test` (**B1 54**, equality-pinned) | P2a, P3, P4, P1 |

### 7.3 Consolidated `docs/privacy/privacy_invariants.json` changes

| Id | Phase | New / edit | Status | Keys | Override needed? |
|---|---|---|---|---|---|
| `INV-R-PUBLISH-POOL-NO-KEEPALIVE` | P1 | NEW (symbols `publish_relay_options`, `build_engine_client` — rule 2 matches the last token, so `RelayManager::new` would be vacuous; tests incl. `every_fetch_primitive_leaves_no_subscription_registered`) | enforced | none | no (deleting it on rollback: `.deleted`) |
| `INV-L-BACKGROUND-DISCLOSURE-GATE` | P2a | edit (tests/guards/statement additions; cited test name kept) | enforced | unchanged | no |
| `INV-L-ANDROID-BACKGROUND-SINGLE-GNSS-REQUEST` | P2a | NEW (interval ≥ `kMinFixRequestInterval`; ≥ 62 s for the circle just published) | enforced | none | no |
| `INV-L-ANDROID-NO-PERMANENT-WAKE-LOCK` | P2b (NOT P2a — the plugin lock is kept there on purpose) | NEW | enforced | none | no |
| `INV-L-IOS-WAKES-RECEIVE-ONLY` | P3 | edit (symbol `HavenLocationStreamHandler.swift::onListen` + host tests `ios_location_source_test`, `geolocator_location_service_test` backgrounded-cold-cache + copy-tie clause (c) — the first tests that read its assertion keys; statement; assertion keys → ~~`locationSettingsIosCatchUp` + ~~`locationSettingsIosLimitedNote`: the catch-up key was deleted unrendered on 2026-09-04, CI-R23, leaving the note as the sole ARB assertion carrier) | enforced | `locationSettingsIosGuidance` → ~~`locationSettingsIosCatchUp` (verbatim move)~~ → the note alone; a key deleted from the ARB is exempt from the assertion enumeration (`still_in_arb`), so this drop needs no override either | ~~YES~~ → **NO (corrected 2026-09-04, WP3-6, verified against the gate).** The guidance key is still claimed as an assertion by `INV-L-IOS-INDICATOR-HONEST` below, and `enumerate_weakenings` subtracts every key still claimed anywhere before enumerating a dropped assertion — so nothing is enumerated, and the planned override is STALE and reds the ratchet. See §5.3 |
| `INV-L-IOS-INDICATOR-HONEST` | P3 | NEW (host tests ONLY — b7 `markTestSkipped`s and rule 4 rejects integration-test citations) | enforced | assertion `locationSettingsIosGuidance`, `locationSettingsIosIndicatorArrow`, `locationSettingsIosIndicatorBar`, `locationSettingsIosLimitedNote` | no |
| `INV-L-IOS-PUBLISH-INPUT-BEST-PROFILE-ONLY` | P3 | NEW ("delivered under the Best profile", not "GPS-grade"; native + Dart copies clear together). **Landed 2026-09-04 WITHOUT the equal-serialized-length clause:** `resent_fix_payload_has_identical_shape` was never written (grepped — no such test in `haven-core`), so the invariant neither states that property nor cites a test for it. Carried as CI-R21 in `docs/CI_HARDENING_BACKLOG.md` | enforced | none | no |
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
| P1 | every mock `RelayService` — **9 classes, 10 files as landed** (the drafted "37 files" counted mentions of the type) | gains `publishLocationEvent` (compile error, not behaviour) |
| P1 | `b9_network_reconnect_test.dart` doc `:20-45` | doc states the two pools differ; assertion ADDED from the first landing (publish acked after outage) |
| P1 | `cursor.rs::inbox_subtracts_7_days_regardless_of_phase` (`:419`), `:421-428`, `:483`, `:500`, the `since_for_stream` doctest | `inbox_initial_subtracts_seven_days` + `inbox_resubscribe_subtracts_two_days_plus_one_hour` + `inbox_resubscribe_lookback_covers_nip59_backdating_plus_skew` (both phases pinned by exact value — never weaker) |
| P2a | `background_location_disclosure_gate_test.dart:124-147` (`collectAt == -1`) | same name, same `gateAt < collectAt`; registration-order sibling added on `_ensureRegistration(` |
| P2a | `session_reclaim_gate_test.dart:338-410` source-order pins | anchors kept verbatim → green; if a token must move, same order promise |
| P2a | `background_location_task_reclaim_orchestration_test` (if `_publishCycle` signature changes) | same orchestration assertions |
| P2a | `background_location_task_publish_cycle_test.dart:250` | `dueOf == publishStart + J` kept; sampler call order changes |
| P2a | `background_location_task_cycle_gates_test.dart:115-138` | extended with `streamListeners == 0` |
| P2a | harness `fixRequests` oracles (counts every `getCurrentLocation()` call, which the cycle must still make) | `oneShotRequests` (incremented only on a cache miss) — the same promise, a non-inverted oracle |
| P2a | B1 hold literal `Duration(seconds: 200)` + comment "2 ticks (144 s) plus slack" | `kLocationPublishMaxInterval + 32 s` (value unchanged; no window widens); `dumpsys location`/`dumpsys power` parsed oracles + ≥ 55 s spacing + the forced-idle no-fix chain (step (8), its own phase after `HOLD_COMPLETE`) ADDED |
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
| P4 | FA Unit C's silence-arm test (if one exists for background) | "does not fire while backgrounded on iOS" |
| P4 | `sharing_health_banner_test.dart:241` | "…while foregrounded and not at all while backgrounded" |
| P5(a) | `location_publish_scheduler_provider_test.dart:123-127,:146-151`; `publish_decorrelation_wiring_test` ×3 names; `location_publish_decorrelation_test` timer-independence premises; `per_circle_due_tracker_test` `seedStaggered` group; **`publish_stagger_test`'s eight-value test RENAMED** | burst assertions with the EXISTING CSPRNG stagger (`2 s`–`maxGapFor(n)`); `a sampled burst never overruns its predicted spread, for every burst size the app admits`; `encryptConcurrencyPeak == 1` kept; every `greaterThan(1000)` / "order varies" kept; manifest citations renamed in the same commit. **CORRECTED 2026-09-08 — `publish_stagger_test` DID go red and was not pure collateral:** its eight-value test is now `whole-second created_at deltas take all EIGHT distinct values over 1000 sampled gaps, **at the DEFAULT burst size of two**`, because eight was only ever true at `totalPublishes = 2`; and TWO tests were added beside it — `expected whole-second delta alphabet, swept over every burst size the app admits` and `the per-gap ceiling is the priced table, for every burst size`. `background_fix_request_test`'s horizon pin is the only genuine untouched collateral (constants untouched; horizon decoupled in P2a) |
| P5(b) | `location_publish_scheduler_provider_test` two names | master-timer assertions; wiring lint extended to both planes |

### 7.5 Open questions — V/I/U ledger (who resolves, when)

**Amended 2026-08-30 (§2.5).** Twelve rows below named a physical device as their resolver. Those resolvers do not
exist for the duration, so each is re-tagged **NOT AVAILABLE** — the row stays OPEN, its resolver becomes "when
hardware returns", and **nothing downstream may treat it as resolved**. The new **ESTIMATED** tag (§2.5) marks a
value produced by model E's arithmetic; it is strictly weaker than **I** and never becomes **V** by being repeated.
Four rows are load-bearing enough to name here: **U-P2-1** parks P2b (§5.2); **V-P3-3** is the one V-tag P3's
original merge gate rested on, and its absence is the residual stated in §5.3; **V-P3-4** and **V-P3-5** are why the
provisional cohort keeps the fail-safe WIU posture and why the stuck-indicator bug stays a known-unmitigated
cosmetic risk. The rest are informational and block nothing.

| Id | Tag | Question | Resolver / when |
|---|---|---|---|
| V-P0-1 | **V** | `circle_details_layout_test.dart` can import `sharing_health_provider.dart` without a Riverpod dependency the harness lacks | RESOLVED 2026-08-30 (P0-A): yes — import added, the file's 39 tests pass. The row it feeds is documentation, not a tripwire (§5.0) |
| V-P0-2 | V | `map_shell.dart` `_onResumed` is set-not-gated by the overlap guard | P0-B implementer before editing `location.dart:49-50` |
| U-P0-1 | **V** (was U; re-tagged 2026-09-08 by P6-B′ — §5.0 and L-39 had recorded this resolved since 2026-08-30 while this row still read `U`) | WN doc's Android-15 6 h `location` FGS timeout claim | RESOLVED 2026-08-30 (P0-B): the claim is **FALSE**, not merely unverified — the timeout covers only `dataSync`/`mediaProcessing` ("*Currently*", developer.android.com "Foreground service timeouts", verified 2026-08-30; API 36 unchanged), so `location` was never subject to it. Both WN sites carry the retraction |
| U-P0-2 | U | goldfish HAL raises GPS "navigating" (bears only on the dropped batterystats oracle) | nobody needs to; recorded |
| V-P1-1 | U (not load-bearing) | whether the iOS engine populates `initialLifecycleState` on a background launch — `readInitialLifecycleStateFromNativeWindow` (`services/binding.dart:295-299`) applies it only when non-empty; if empty, `lifecycleState == null` maps the `appForegroundProvider` default to `true` (fail-open). Harmless: the native start refusal and the `backgrounded` read (D1) are the gates | P1-A1 (observe on an SLC relaunch; nothing depends on it) |
| V-P1-2 | **V** | `ClientOptions::default().autoconnect` does not spawn a connect on `pool().add_relay` (`pool/mod.rs:257-262`; `client/mod.rs:305-308`); `RelayOptions::default()` equals `compose_relay_opts`' output for the default `ClientOptions` (`client/mod.rs:232-283`) | closed by the Rust review |
| V-P1-3 | V | cancelling the geolocator subscription while paused does not trip `StreamHandlerImpl.setActivity(null)`'s `stopListening()` (`StreamHandlerImpl.java:46-53`) — "Geolocator position updates stopped" once in logcat; the FGS engine's cancel under-counts `listenerCount` on the shared bound service (`GeolocatorLocationService.java:86-90,127-131`) — harmless today | P1-A2 on device |
| V-P1-4 | **V** | `sharing_health_banner.dart:200` timer fires while backgrounded (the red test decides; drop the item if it cannot fail) | RESOLVED by P1-A3: it does. The gated behaviour is held by `sharing_health_banner_test.dart` `'stops while backgrounded and re-renders on return'`, `'is not armed at all while the pipeline is healthy'`, `'re-arms when a fault appears and stops when it clears'`, and the a11y split by `'the live region carries the cause, never the age'` |
| V-P1-5 | **V** | `RelayManager::subscribe` (`manager.rs:660-700`) has no caller | closed by grep 2026-08-29; DELETED by P1-N1, and its absence is now pinned by `check_engine_client_options.sh` check 7 (no `subscribe_to(` / `subscribe_with_id_to(` in `manager.rs`) |
| I-P1-1 | I → **NOT AVAILABLE** | real-network `Sleeping` timing 60–70 s | ~~hardware~~ → when hardware returns; not a correctness input, blocks nothing |
| V-P1-6 | **V** | whether `live_sync_cursor_replay_e2e.rs`'s intermittent failure was a wait budget too small for an instrumented build | RESOLVED by P1-N0, and the answer is NO. It sampled its cold-seed baseline AFTER `engine1.start()` opened the REQ, so a fast in-process relay's `EOSE` anchored the cursor before the read; the test then waited for a SECOND advance that a spent generation never issues (`anchor::CircleAnchor::eose_consumed`). Budget-independent — reproduced at a 120 s budget under load. Fixed by waiting for a target knowable before the session exists (`wait_cursor_at_least`) plus a `read_sync_cursor == None` precondition. `inbox_cursor_poisoning_e2e.rs` was immune because it always passes a COMPUTED floor. `HAVEN_TEST_WAIT_SCALE` must not be credited |
| V-P2-1 | V (pre-stated) | `dumpsys location` `Request[…]` / `dumpsys power` `ACQ=` grammar on the CI API-34 image — derived from `LocationRequest.toString()` / `WakeLock.toString()` (§2.2) | P2a-6: shell fixtures in the SAME commit; the first run confirms |
| V-P2-2 | V | first FGS stream listen after `onStart` receives events (plugin service bind complete) | P2a-6 via `[BackgroundTask] registration armed` + delivery in B1 |
| V-P2-3 | **V** | `PowerManager.WakeLock.acquire(timeout)` on a held non-refcounted lock re-posts the release timer; `release()` when not held is a no-op (`PowerManager.java:3930-3950, 3984-4000`) | closed by the Android review |
| V-P2-4 | **V** | `addTaskLifecycleListener` from `Application.onCreate` precedes the boot-restart engine (`ForegroundService.kt:45-54,173-178`, `ForegroundTask.kt:47-70`, `RebootReceiver.kt:43-46`) | closed; confirm on `adb reboot` (M7 runbook step 7) |
| I-P2-1 | I → **NOT AVAILABLE** | HAL `CAPABILITY_SCHEDULING` on the owner's phones (`dumpsys gnss`) — also decides the indoor residual (60 s search vs chip policy) | ~~informational, hardware run~~ → **one Android handset** settles it in the 60-min §5 run (§6.7 follow-up 1). Until then the indoor residual is an ESTIMATED range (§6.5a), not a number |
| I-P2-2 | I → **NOT AVAILABLE** | GMS `fused` duty-cycles a 60–158 s HIGH_ACCURACY request (attested developer behaviour; GMS is closed) | ~~hardware gps time~~ → when hardware returns. Note the remedy — the P2b native registration naming the provider — is itself **PARKED** (§5.2), so if this attestation is wrong the fallback is unavailable too. The emulator cannot substitute: goldfish is not GMS `fused` |
| U-P2-1 | U → **NOT AVAILABLE (load-bearing)** | delivery→Dart wake window on aggressive suspend — consequence = a one-cycle TTL breach (D4) | ~~P2b hardware under forced idle~~ → **this is the row that PARKS P2b** (§5.2): the emulator never suspends its AP, so the question cannot be asked in CI, and OD-P2-2's alternative ("accept the breach at a measured p") has no p to accept. Closed by construction *if* the native registration ever lands — which is what un-parking means |
| V-P3-1 | V | simulator delivers `simctl location set` fixes under `kCLLocationAccuracyHundredMeters` (I: yes) | WP3-5 bounded profile poll |
| V-P3-2 | V/I → **NOT AVAILABLE** for the background half | live `desiredAccuracy` change on a running backgrounded session honoured without restart | ~~owner device, M7 §6 0a~~ → V for the API (§2.1); the background EFFECT is **DEFERRED**. Partial CI substitute: the bg-publish lane's bounded profile poll observes `hundredMeters` from the backgrounded process, which shows the change is honoured *at all* — not that it is honoured *without a restart* over hours |
| V-P3-3 | U → **NOT AVAILABLE (load-bearing)** | the CONFIRMED-Always shape (no activity session, flag false, 100 m / no filter) keeps a foreground-started session delivering for HOURS on iOS 17/18/26 (Apple guarantees delivery for the shape but "takes no measures … when it has nothing to deliver") | ~~owner device, M7 §6 0a ≥ 2 h — a WP3-2 MERGE gate~~ → **DEFERRED; the merge gate is re-based on the CI bundle (§5.3 WP3-2)**. This row IS P3's stated residual: the simulator cannot prove suspension (`M7`'s 2026-08-23 second changelog entry) and the closest physical neighbour of this shape failed in the field on 2026-08-20 (`M7`'s changelog entry of that date). `M7` §6 item 0 now carries the four DEFERRED rows that would close it. The provisional cohort still does not depend on it (OD-P3-b keeps them on the WIU posture) — only confirmed-Always users ride the unproven shape, behind the background-sharing toggle |
| V-P3-4 | U → **NOT AVAILABLE** | `CLServiceSessionDiagnostic` values observed under provisional Always (two of three properties have empty doc abstracts) | ~~owner device, iOS 18+~~ → **DEFERRED**; b7's full grant still observes the CONFIRMED case in CI, so the branch that matters for liveness is exercised. The unobserved half is exactly the one D2 already fails SAFE on (WIU policy until a diagnostic positively confirms Always), so the missing evidence cannot cost liveness — only the pill, for that cohort |
| V-P3-5 | U → **NOT AVAILABLE** | stuck-indicator reproduction after `disarm()` on iOS 18/26 | ~~owner, M7 §6 0c~~ → **DEFERRED**; no simulator renders a status bar. Unchanged in substance: §2.1 already records that no code mitigation exists, so this was never actionable — only observable |
| I-P3-1 | I → **NOT AVAILABLE** | delivery rate at 100 m/no filter on a stationary device (drives the 84 s escalation frequency; the profile-duty column) | ~~hardware log~~ → **DEFERRED**. This is the single largest source of spread in model E's iOS estimate: it is the whole difference between ≈ 0.3 %/h (good coverage, `d ≈ 0`) and ≈ 1.0 %/h (poor coverage, `d = 0.59`) in §6.5a, and it is why OD-P3-a's 120 s ships un-tuned |
| V-P4-1 | **V** | `Client::disconnect` mid-`send_event` yields `Err(PrematureExit)`/`Err(NotConnected)` (`inner.rs:1255-1270, :1382-1389`) — never a false confirm; the in-flight gauge prevents the disconnect | closed by the Rust review |
| I-P4-1 | I | 5 s backlog wait vs strfry EOSE ~100 ms (`config.rs` §P-15) — expected never to bind | ~~owner's relays~~ → the lane's own strfry exercises the same bound in CI; a real-relay confirmation is DEFERRED but nothing depends on it |
| U-P4-1 | U → **NOT AVAILABLE** | iOS `nw_connection` teardown on `disconnect` completes before the radio tail | ~~hardware~~ → **DEFERRED**; bears only on how much of P4's ESTIMATED radio saving is realised (§6.5a parameter `c`), never on whether the burst delivers |
| U-P4-2 | U | `MockRelay` subscription introspection in `nostr-relay-builder` 0.44 (the client-side no-standing-REQ oracle is used regardless) | P4-2 |
| V-P4M-1 | **V** | both commit-loss PRs ship in v0.9.5 (#825 = `363b1fe3`, #892 = `e6654ece`) and NEITHER is reachable from Haven's five pinned crates — #892 touches none of them, #825's `CursorPersistence` policy hangs off `MarmotAppConfig` in `marmot-app` | closed 2026-09-05 (full MDK clone, both endpoints via `git archive`; `e391adc` byte-identical to `v0.9.4`). **This is the row that kills OD4-c option (ii)** |
| V-P4M-2 | **V** | Rule 11 across the bump: the peeler's nonce handling is a zero-diff, `DEFAULT_EXPORTER_LABEL` is unchanged, `with_exporter_label` still exists at `peeler.rs:60` | closed 2026-09-05; `check_no_exporter_label_override.sh` stays necessary AND sufficient — never retire it as "obsolete after the bump" |
| V-P4M-3 | **V** | the knob `circle/rotation.rs` exists for did not move: OpenMLS `SenderRatchetConfiguration::default()` = `(5, 1000)`; v0.9.4 sets neither; v0.9.18 sets tolerance 5 → 100 and `maximum_forward_distance` 1000 → **1000, unchanged** | closed 2026-09-05; ~1,500 lines that cannot be deleted by bumping |
| I-P4M-1 | **I** | `[patch.crates-io]` is not inherited through a git dependency, so Haven would resolve `libsqlite3-sys` from crates.io and inherit the SQLCipher mlock WARN spam upstream patched away — on Android specifically | standard Cargo semantics, **not read off the tree**; P4M-4 confirms it with the first Android build's `logcat` scan |
| U-P4M-1 | **U** | what else breaks at compile time — **no `cargo check` was run against v0.9.18** | P4M-3's first build. Until then §5.7's break list is a LOWER bound on the breakage, never an upper one |
| U-P4M-2 | **U** | #877's landing; #864 / #866 / #885's state at v0.9.18; upstream's own migration-cost figures; per-release hashes/PR numbers beyond `d7236f43 (#1110)`; exact method-count deltas | not queried 2026-09-05; re-query before P4M-2 and never carry the pin-time "OPEN" forward as a current fact |
| U-all | U → **ESTIMATED, NOT AVAILABLE** | every energy figure in this plan (Evgenii, Karki & Won, LTE-2012 models) — and now every figure model E derives from them (§6.5a) | ~~hardware only~~ → **hardware only, and there is none** (`MESH_LOCATION_RELAY_DESIGN.md:401`). This row is the reason §2.5 types every gate: it was always true that no energy figure here was measured, and the constraint makes it the plan's normal condition rather than a caveat. Every §6.5a output inherits this tag |

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

---

## 9. Decision ledger

**What this is.** One chronological index of every decision this epic has taken, so that a defect surfacing
months from now can be answered with *why is it like this, what else was considered, and what would tell us we
were wrong* — without re-reading eight sections and reconstructing the order in which the reasoning changed.

**What it is NOT.** It does not re-argue anything. Where a decision already has a full record — §4's owner
register, §5.4's "Gap-closure decision record (2026-09-08)", §5.7's five blockers — the row is a POINTER plus the
two things those records mostly do not carry: what the decision costs, and **what evidence would invalidate it**.
Read the row to find the decision; read the section it names for the argument. Where a row and the section it
points at disagree, the section is authoritative for the reasoning and this ledger is authoritative for the
*order* — and the disagreement is a defect to fix, not a choice to make.

**Why the corrections are in here as rows of their own.** Several of these decisions corrected earlier ones, and
three corrected a correction. A future reader needs the CHAIN, not the surviving link: the chain is what says
which kind of reasoning failed here before. So both ends of a chain stay, each in its own date position, and the
Status column says which end you are holding: a row whose decision IS the standing correction reads `CORRECTION`;
a row whose decision was REPLACED reads `SUPERSEDED` and names its replacement. **Filter for "what still stands"
by taking `DECIDED` + `CORRECTION`, never by dropping every row whose text retracts something** — most of the
retracting rows ARE the current truth. Eleven of them were mislabelled `SUPERSEDED` until 2026-09-08, which
inverted the ledger for exactly the reader it exists for: filtering on that label would have discarded the
corrections and kept the claims they retract. `CORRECTION` is reserved for a row whose decision IS the retraction;
a `DECIDED` row may still carry a correction inside a larger decision (L-51, L-62, L-71, L-74, L-86, L-93, L-99),
so it is a refinement of `DECIDED`, never a third thing. §9.8 lists the chains end to end.

**Reading a row.**

| Column | Means |
|---|---|
| **#** | Stable id. Cite it as `L-nn`; ids are never reused or renumbered. |
| **Date** | When the decision was TAKEN (not when it was implemented). Ids are assigned in the order rows were WRITTEN and are never reused or renumbered, so **the id sequence is not a date sequence**: rows are grouped under dated subsection headings, and inside §9.4 L-40–L-42 (2026-09-04) sit above L-43–L-48 (2026-09-03), while every row in §9.10 carries a date earlier than §9.7's. Read the Date column and the subsection heading for the order, never the id. |
| **Status** | `DECIDED` — taken and standing. `CORRECTION` — taken and standing, AND the decision IS the correction of an earlier claim or decision: it names what it retracts, nothing has replaced it, and it belongs to "what still stands". `OPEN` — named, deliberately not taken, someone must take it. `SUPERSEDED` — taken and later REPLACED; the replacement is named and this row is history, not current truth. `PARKED` — taken, but its gate cannot be met for the duration. `OWED` — decided, and the work it implies has not landed. |
| **Decision** | What was decided, and the one-or-two-sentence reason. Ends with `→ §x` for the full argument. |
| **Rejected — and why** | The alternatives that were on the table. A rejection with no reason is not recorded as a rejection. |
| **Cost** | The honest downside the decision buys. `—` means the record states none, which is itself worth noticing. |
| **Invalidated by** | The observation that would mean this decision is wrong. This is the column the ledger exists for: it is written so that someone who sees that observation knows to come back here, and so that "we never thought about it" is never the answer. |

**Size.** 134 rows, `L-01`–`L-134`, contiguous and each id used once, across §9.1–§9.10 (§9.7a, §9.7b, §9.7c, §9.7d,
§9.7e and §9.7f included). **It read "119 rows, `L-01`–`L-119`" until 2026-09-09 — already stale by one before that day's five rows
were added, because L-120 was appended to §9.10 without this sentence being touched, and it then read "125" for as
long as it took OD4-d's implementation to add §9.7b's five, and "131" for as long as it took the roster bound's own
landing to add §9.7d's one, and "132" for as long as it took OD4-c's own implementation to add §9.7e's one, and "133" for as
long as it took OD4-c's CONSUMER to add §9.7f's one. That is
the failure mode the next clause exists for.** That figure is a
convenience and not an authority — re-derive it with `grep -c '^| \*\*L-' docs/POWER_EFFICIENCY_PLAN.md` rather
than trusting this sentence, for the same reason the citations below are symbols and not line numbers.

**Citations.** Symbols and section headings only, never `file:NNNN` — every line citation in this document has
drifted at least once (§1.2 carries the record of that), and a ledger that rots is worse than none.

**Relationship to §7.5.** §7.5 tracks open FACTS (V/I/U — what we do not know). §9 tracks taken DECISIONS (what we
chose, given what we knew). A §7.5 row resolving is a common way for a §9 row's "Invalidated by" to fire.
### 9.1 Before the epic — the one prior decision this plan reverses

| # | Date | Status | Decision | Rejected — and why | Cost | Invalidated by |
|---|---|---|---|---|---|---|
| **L-01** | 2026-07-26 | **SUPERSEDED** by L-24 (the decision) and L-100 (as landed) | `INV-R-PER-CIRCLE-PUBLISH-DECORRELATED`: each circle publishes on its own staggered schedule, so a user in several circles emits no synchronous burst an observer watching more than one relay could tie together. Predates this epic; recorded here because everything OD3/P5 does is a reversal of it | — (not this epic's record) | One radio wake per circle per interval — the cost that opened this epic (§1.1 R-G) | Already invalidated: §1.1 R-G showed the property never held at a shared relay (the multiplexed `#h` REQ names every circle of a relay set on one socket, and every circle publishes over one publish socket) |

### 9.2 2026-08-29 — the founding decisions (D0–D8, §3) and the owner register (§4)

D0–D8 were taken as one synthesis over four expert drafts and two review rounds; §3's own instruction is *do not
re-litigate — if a decision is wrong, say so in review with evidence*. §4's register was accepted in one sitting
the same day. The rows below are the index; §3 and §4 carry the arguments.

| # | Date | Status | Decision | Rejected — and why | Cost | Invalidated by |
|---|---|---|---|---|---|---|
| **L-02** | 2026-08-29 | DECIDED | **D0 — nothing on the wire changes.** Cadence 72–168 s, kind-445 retention 228 s, no-gap invariant, ephemeral key per message, Rule 13, Rule 14, no push plane, exact coordinates, no new dependency, no telemetry. A power fix that moved the wire would be a protocol change wearing a battery costume → §3 D0 | A push plane (would need a third party in the delivery path); coarsening coordinates (`raw_accuracy` stays `#[serde(skip)]`) | Every saving must come from *when* Haven wakes, never from *what* it sends — which is why P1–P5 are all lifecycle work | Any measurement showing the remaining wake budget cannot reach an acceptable drain without a cadence or retention change. Nothing in model E (§6.5a) says that today |
| **L-03** | 2026-08-29 | DECIDED | **D0 sub-decision — the wire timestamp is PUBLISH time, not fix time.** `LocationMessage::new` stamps `Utc::now()` at encrypt, so a peer's age pill measures how long ago the message was sent. D1's stationary re-send therefore needs a FRESHNESS rule, not a timestamp rule → §3 D0 | A timestamp rule (send the fix's own age) — it would be a wire field, which D0 forbids | Fix staleness is invisible on the wire; a peer cannot tell a fresh fix from a re-served anchor | A user-visible complaint that "just now" was hours stale — which is exactly what OD-P3-e (L-40) later capped rather than disclosed |
| **L-04** | 2026-08-29 | DECIDED | **D1 — iOS gets a Haven-owned native location stream** (`HavenLocationStreamHandler`) with exactly two live accuracy profiles, Best and HundredMeters, switched by a live `desiredAccuracy` write and never by a restart; only Best-profile fixes are published (`bestSince`, `INV-L-IOS-PUBLISH-INPUT-BEST-PROFILE-ONLY`). R-A's 24/7 Best/no-filter session is the single largest iOS term → §3 D1 | A third, coarser tier (recreates the iOS 16.4 suspension shape); a session restart per profile change (drops the background continuation); errors returned from `onListen` rather than through the sink (EventChannel contract, §2.1) | Two stream owners instead of one — the "one `getPositionStream` site" invariant weakens to "one stream owner per platform" | A device observation that a live `desiredAccuracy` write on a running backgrounded session is NOT honoured without a restart (V-P3-2, §7.5 — **NOT AVAILABLE**) |
| **L-05** | 2026-08-29 | DECIDED | **D1 (i) — the profile controller lives in Dart, not Swift** (`IosLocationSource`), as a pure controller (`nextDeadline`/`onDeadline`/`onFix`) needing no `fake_async` → §3 D1 (i) | A Swift controller — no Swift unit test runs in CI (§2.1), so the logic would ship unproven | ~10 lines added to an 890-line service; the Swift side stays a transport | A CI capability to unit-test Swift, which would remove the whole reason |
| **L-06** | 2026-08-29 | DECIDED | **D1 (ii) — one-shots stay on geolocator** on both platforms → §3 D1 (ii) | A native one-shot: `requestLocation()` does nothing while the same manager is updating, so it needs a SECOND `CLLocationManager`. Fewer managers wins | The plugin boundary survives on the one-shot path, so `check_single_plugin_boundary` still has two owners to police | A native one-shot that needs no second manager (an API change) |
| **L-07** | 2026-08-29 | DECIDED | **D1 (iv) — a coarse fix confirms stillness only if `accuracy ≤ kStationaryConfirmMaxAccuracyMeters`**; a coarser one neither confirms nor moves → §3 D1 (iv), OD-P3-d | A cap of 200 m (a fix that cannot resolve 100 m cannot vouch for 100 m of stillness) | **Stated, not hidden:** a true displacement below `kMotionTriggerDistanceMeters + kStationaryConfirmMaxAccuracyMeters` (200 m) goes undetected, and the served coordinate is up to that stale — against today's 100 m | A field report of markers lagging by roughly 200 m while stationary-confirmed. Bounded since 2026-09-04 by OD-P3-e's anchor-age cap (L-40) |
| **L-08** | 2026-08-29 | DECIDED | **D1 (vi) — the backgrounded cold-cache shortcut reads the NATIVE lifecycle** (`status().backgrounded`), fail-closed, not Dart's `_foregroundActive` → §3 D1 (vi) | Keeping `_foregroundActive`: it is written only by MapShell's `paused` dispatch, so a background launch that never delivers that dispatch would start a manager from the background (the FA-downgraded SLC hypothesis, §1.2) | A MethodChannel round-trip on a path that used to read a field | Evidence that the native status can itself be wrong on a background launch |
| **L-09** | 2026-08-29 | DECIDED | **D2 — indicator/session policy by tier, on a fail-safe predicate.** `alwaysConfirmed` is false until an iOS 18+ `CLServiceSession(.always)` diagnostic proves a real Always grant; `wantsActivitySession = whenInUse ‖ !alwaysConfirmed`; `arm()` never withdraws an in-use claim while backgrounded, `disarm()` always does; the diagnostics observer re-runs `arm()` when confirmation lands → §3 D2, OD1, OD-P3-b | Treating provisional Always as Always (the UNSAFE direction — silent publish loss for a cohort the OS treats as When-In-Use, i.e. the 2026-08-20 field-failure shape); synchronous confirmation (the first diagnostic lands after `arm()` returns); driving the copy off `authorizationStatus` (renders tier text to denied/notDetermined users) | Provisional-Always users on iOS 18+, and EVERY iOS 17 Always user, keep the pill — iOS 17 has no diagnostics API, so `alwaysConfirmed` never becomes true there | A diagnostics API on iOS 17, or a device observation that the pill persists under CONFIRMED Always with the flag false (V-P3-3/V-P3-4, §7.5 — **NOT AVAILABLE**) |
| **L-10** | 2026-08-29 | DECIDED | **D3 (P1 half) — the UI isolate's location stream is released on pause by a service-level SYNCHRONOUS gate** (`suspendStream()`/`resumeStream()`), called directly from `_onPaused`/`_onResumed`, on Android in both toggle states → §3 D3, §3.1 | Release by a Riverpod rebuild — **a rebuild cannot run while paused** (§2.2a), so it would happen at RESUME, and `appForegroundProvider`'s default would then start a background-capable session on a background launch (fail-OPEN for R7) | The provider keeps only what a rebuild can honestly do; the C4 opt-out watcher must call `suspendStream()`/`clearCachedPosition()`/`disarm()` directly | A Riverpod/Flutter change that runs provider rebuilds while the app is paused |
| **L-11** | 2026-08-29 | DECIDED | **D3 (P2a half) — the Android foreground service owns ONE long-interval platform request while backgrounded** and publishes on delivery, re-registering to the next pre-sampled due; the UI stream lives only while foregrounded → §3 D3, OD-P2-1 | The UI isolate keeping GPS — that IS root cause R-C, so there is no viable alternative | The FGS becomes the sole GPS owner in the background, so a defect there is a total sharing outage rather than a degraded one | A regime where a single long-interval request cannot be honoured (I-P2-2: GMS `fused` may ignore the interval — **NOT AVAILABLE**, remedy parked with P2b) |
| **L-12** | 2026-08-29 | DECIDED | **D3 (i) — the WorkManager registration is left UNCHANGED** → §3 D3 (i) | "Re-register on death" — it is dead code exactly when it matters: no Dart or Kotlin hook runs on an OOM kill, an `am kill` or a force-stop, and force-stop strips JobScheduler jobs anyway | **Accepted:** ≈4 no-op FlutterEngine spin-ups per hour while the FGS is alive | A new Phase-A′ oracle that can prove a re-registration path actually fires; the decision says to revisit only with that oracle in the same commit |
| **L-13** | 2026-08-29 | DECIDED | **D3 (ii) — the FGS one-shot survives unchanged** as the ≥168 s no-delivery fallback → §3 D3 (ii) | Deleting it with the delivery-driven cadence: `INV-L-ACCESS-GATE-PRECEDES-FIX` and `INV-L-BACKGROUND-DISCLOSURE-GATE` are name-bound guards over that call, and deleting it would make them vacuous rather than true | One extra acquisition per 168 s of delivery silence | A guard rewrite that binds those invariants to the delivery path instead |
| **L-14** | 2026-08-29 | DECIDED | **D3 (iii) — the platform interval is `clamp(target − now, kMinFixRequestInterval, hi)` with a 10 s lead**, and `kBackgroundFixHorizon` is its OWN constant, deliberately decoupled from `kPublishStaggerMaxSpread` → §3 D3 (iii) | `I = 0` (continuous HIGH_ACCURACY, and no historical delivery); a 72 s floor anchored at the last publish (starves a second circle by up to 41 s → a 219–239 s realized gap, i.e. a TTL breach); riding `kPublishStaggerMaxSpread` (P5 would then move a P2 constant) | Two constants that look alike and must not be unified | A change to the stagger budget that ought to move the fix horizon — the decoupling would then be hiding a real coupling |
| **L-15** | 2026-08-29 | DECIDED | **D4 — P2a KEEPS the plugin's permanent `PARTIAL_WAKE_LOCK`** and adds a Haven-owned scoped lock (`Haven:publish`, non-refcounted, native timeout coerced into [1, 30 000] ms) so that P2b becomes a pure removal → §3 D4 | Removing the permanent lock in P2a — without it the 72 s watchdog is a `delay()` on AWAKE time and sharing stops SILENTLY on the `forceLocationManager` cohort (the FA class: no banner, no error); releasing the lock from the Kotlin lifecycle listeners (they run before the ≤15 s drain has started — the plugin's own pre-existing defect, which P2 must not copy); issuing the P2b registration from `onEngineCreate` (a `PendingIntent` outlives the process, so a later toggle-OFF finds nothing to stop — Rule 10) | The AP never suspends under P2a; P2a still books the dominant Android saving (R-C, 60–85 mA → ≈5 mA) | A proven wake source that survives without the lock — which is exactly P2b's gate (L-33, PARKED) |
| **L-16** | 2026-08-29 | DECIDED | **D5 — the publish pool becomes on-demand**: `publish_relay_options()` = `default().ping(false).reconnect(false).sleep_when_idle(true).idle_timeout(10 s)`, so a publish socket lives (60 s, 70 s] and emits one ping frame per fresh connect and none between bursts → §3 D5 | `sleep_when_idle` alone with `reconnect: true` — a dropped relay then never reaches `Sleeping` and retries every 10–60 s forever (R-E's "never gives up"); a bare `Client::add_relay` (it ORs `PING` back — F6), hence the guard on `pool().add_relay` | A silently dead socket inside the ≤70 s window is reused by the next publish and costs one bounded attempt; a relay acking at 6 s has stored an event Haven records as failed, so a retry can duplicate at that relay | Evidence that the crate's idle sleep does not fire on a real network in 60–70 s (I-P1-1, §7.5 — **NOT AVAILABLE**) |
| **L-17** | 2026-08-29 | DECIDED | **D5 (iii) — location publishes take ONE attempt** (`LOCATION_PUBLISH_ATTEMPTS = 1`) over one 5 s per-relay window via `send_to_one`, reusing the ladder's error contract → §3 D5 (iii) | `FuturesUnordered` + a two-phase race, and a separate drain — ≈25 lines and neither needed | A publish that loses its ack window is not retried; the next tick's fix supersedes it | A cadence where one lost publish matters — i.e. any change that lengthens the interval past the retention margin |
| **L-18** | 2026-08-29 | DECIDED | **D5 (iv) — `RelayManager::subscribe` is DELETED** (no caller; V-P1-5) → §3 D5 (iv) | Leaving it: a future caller would keep the ping-less pool from ever sleeping and would create a silently dead standing REQ | A capability removed rather than documented | A genuine need to subscribe on the publish pool, which would have to re-open the ping/sleep question first |
| **L-19** | 2026-08-29 | DECIDED | **D6 — iOS background receive becomes a bounded BURST per publish tick** (open → ingest → publish → fold maintenance → settle → close) with no standing REQ and no socket between ticks; a new `pause_subscriptions()` with ordered steps, `disconnect()` never `shutdown`, and a drain-then-clear marker → §3 D6, OD4 | **Merged pools with a ping-less standing REQ** — still one radio wake per INBOUND peer event (60 vs 30 wakes/h for one circle) and it turns the two-socket `#h`/`#p` linkage from probable to certain; rebuilding the core per burst (rotates the sub-id salt every ~2 min = a new relay-visible fingerprint, and re-spawns the Rule-14 task set); `try_send` for the pause marker (a full intake would drop it); clear-then-drain (drops stored events still queued) | Status churn per burst; a one-epoch-behind encrypt when the backlog wait times out; and a NEW inference for inbox-only relays (see L-22) | A relay-side observation of a socket or REQ between bursts. Partly already fired: the paused-session socket strand (L-81) and residual items 8/10 (§5.4) are named exceptions |
| **L-20** | 2026-08-29 | DECIDED | **D6 (iv) — the bounded inbox lookback is a PRECONDITION, not part of P4**: `INBOX_RESUBSCRIBE_LOOKBACK_SECS` = 2 d + 1 h on every `Resubscribe`, 7 d kept for `Initial`. It lands INSIDE P1 (as P1-N0) because D8 stops the engine on the Android bg-OFF pause and `_healLiveSyncIfStopped` would otherwise make every glance cost a 7-day replay → §3 D6 (iv), D8 | Narrowing further: NIP-59 wraps are backdated up to 48 h, and `cursor.rs` records that a wrap below the floor is lost SILENTLY | Two residuals named at source: a sender clock >1 h fast with a near-maximum backdate, and a relay unreachable for >49 h | A NIP-59 change to the backdating window; or evidence that 49 h of `#p` replay is itself the dominant cost (which it partly became — see L-69) |
| **L-21** | 2026-08-29 | DECIDED | **D6 (v) — the pre-pause settle is STRUCTURAL, not time-based**: wait for the in-flight publish gauge to reach zero with NO cap, then hold sockets `COMMIT_SETTLE_WINDOW_SECS` past the last commit activity, capped only on idle FOLLOW-ON activity → §3 D6 (v) | A time-based cap over the whole settle — it would cut a commit between SEND and OK, rolling back locally while the relay stored it: **a roster fork every ~2 min in the background** (Rule 13) | A burst can outlast any bound anyone would like to put on it — which is why no honest whole-burst bound exists (L-77) | A Rule-13-safe way to bound the drain, which does not exist while a Dart `.timeout(` cancels no Rust future |
| **L-22** | 2026-08-29 | DECIDED | **OD4 "strictly narrows RC1" is WITHDRAWN in the same breath as OD4 is accepted.** An inbox-only relay (kind 10050 set, independent of the circle sets) carries no kind-445, so after P4 it sees a REQ/CLOSE pair every 72–168 s and learns "this pubkey is background-sharing now" — a NEW inference for that relay class → §3 D6 (vi), §4 OD4 | Claiming the narrowing unqualified — it is false for that relay class | A metadata inference that did not exist before P4, disclosed rather than removed | OD4-b actually being implemented at k > 1 (L-23) removes the cadence signal; it is still at k = 1 (L-70) |
| **L-23** | 2026-08-29 | DECIDED / **OWED** | **OD4-b — fold the inbox `#p` REQ into every k-th burst**, k such that k × nominal ≥ 10 min → §4 OD4-b | Issuing it on every burst: the cadence inference of L-22 then stays and must be disclosed | Background invitation latency. **The latency figure this row carries was corrected 2026-09-07 (L-87) and must be re-derived before k is raised** | The re-derivation showing the true worst case unacceptable; or the k > 1 re-anchor defect proving unfixable (L-70) |
| **L-24** | 2026-08-29 | DECIDED | **OD3 — publish coalescing variant (a)**: one burst per interval publishes every eligible circle, with the EXISTING stagger constants (2 s / 9 s / 30 s) untouched. Reverses L-01 on the honest ground that shared-relay decorrelation never held → §3 D7, §4 OD3, §5.5 | Variant (b), wake-sharing only — it saves almost nothing on iOS-bg under D6 (N schedules are N bursts per interval), and is a CPU tidy-up; the drafted 2.5 s / 5 s stagger constants — a 2.0–2.5 s gap yields a whole-second delta of 2 or 3 s on EVERY burst, which is the constant-stagger fingerprint the stagger exists to prevent, and they would also have broken P2's due horizon | **THREE costs, not the one this row first carried — corrected 2026-09-08 against `PUB-COALESCE` as shipped.** (1) circles on DISJOINT relay sets emit identical inter-burst sequences, so anyone holding two of your circles' relay archives can tell they belong to the same phone — broader than "a relay that carries several of your circles". (2) the circle COUNT becomes a single-relay observable as a connect-to-disconnect DURATION, and the carrier splits by plane: the iOS-bg engine socket spans the whole pass over the relay union, the Android FGS shuts its publish pool with a COLLECTIVE `client.disconnect()` at every teardown, and the FOREGROUND has no collective disconnect at all — each socket sleeps independently in (60 s, 70 s] after its own last send. (3) the count leaks a second time through the SIGNED `created_at` deltas, because `maxGapFor` is injective over `n = 5…11`; that carrier needs no socket, survives connection noise, and PERSISTS in every archive of the events | A deployment where per-circle relay sets are genuinely disjoint AND the archive adversary is real — in which case the stagger is the only remaining defence, and it only breaks `created_at` equality. **And it breaks less of it as the roster grows:** the alphabet is `{2…9}` up to four circles and `{2,3,4}` at `kMaxCirclesPerAccount` (10), the largest burst a bounded roster can produce, where three shifted equality joins over the same whole-network index remain un-targeted mass linkage — a constant factor, not a change in kind. `maxGapFor`'s next answer, `{2,3}` at `kMaxCirclesPerBurst`, is one circle past anything the app admits since the roster bound landed (L-123, L-132), so it is not the shipped alphabet |
| **L-25** | 2026-08-29 | DECIDED | **D8 — foreground/lifecycle hygiene**, including maintenance timers foreground-gated on BOTH platforms and **the engine stopped on the Android pause when sharing is OFF**, through a new `_stopLiveSyncBounded()` shared with `_onDetached` → §3 D8 | Calling `releaseForHandoff()` on the bg-OFF branch — it latches every `getCircleManagerFfi()` closed and nothing reclaims, so the R1 watcher would publish against a latched manager; **a 60 s grace timer before stopping — DECLINED** (§8 "Not applied") | A glance costs a cold engine start, which is why L-20 had to land first | Evidence that cold restarts on every resume cost more than the sockets they close |
| **L-26** | 2026-08-29 | DECIDED | **D8 self-imposed kill rule for the banner timer:** the packet starts with a failing test proving the timer fires while backgrounded; **if it cannot be made to fail, the item is DROPPED, not implemented** → §3 D8 | Implementing on suspicion — an unfalsifiable item is a guess with a commit attached | One item's fate depends on a test that might not exist | Nothing: this is a method, and it worked (V-P1-4 resolved: the timer does fire) |
| **L-27** | 2026-08-29 | DECIDED | **D8 accessibility shape: the age is its own NON-LIVE semantics node outside `ExcludeSemantics`**, and the live region carries title + epoch only → §3 D8 | Embedding the rounded age in the live-region label — TalkBack would re-announce a persisting fault every 72 s | Two semantics nodes where one would have compiled | A screen-reader change that makes live-region re-announcement inaudible |
| **L-28** | 2026-08-29 | DECIDED | **The emulator `batterystats` GPS oracle is REPLACED by a `dumpsys location` REGISTRATION oracle** (exactly ONE request at interval ≥ 72 s while backgrounded, with the foreground 1 s request as the anti-vacuity control) → §3 "Verification decision" | The batterystats per-uid GPS timer: it rides `noteGpsChanged` from the GNSS provider's navigating transitions, which the goldfish HAL is likely never to raise — **the assertion would be vacuous by construction** | The oracle is framework-side registration evidence, not energy evidence; batterystats stays a hardware metric | A goldfish HAL that does raise the transition (U-P0-2, §7.5 — nobody needs it) |
| **L-29** | 2026-08-29 | DECIDED | **§3.1 — one single-subscription `StreamController` PER `getLocationStream` call**; `suspendStream()` cancels (not closes) the inner subscription so the cache survives; the cache is cleared on the CONSENT condition (`!bg`), not on `!keep` → §3.1 | One controller per service (`StateError` on the second `listen`); `Stream.empty()` as the paused placeholder (it COMPLETES, and completion-without-error is pinned as surfacing state); a shared `_never` (throws on the second paused build); the iOS draft's `!keep` cache clear (conflates "not iOS" with "no consent" — the Rule-10 reading wins); `ref.watch(appForegroundProvider)` in the foreground build (**the reviewer trap** — it tears the kept iOS session down at the resume rebuild) | A per-call controller discipline replaces a one-site simplification | A Riverpod idiom that makes the rebuild-based release honest (see L-10) |
| **L-30** | 2026-08-29 | DECIDED | **Owner directive v3.1 — the Settings → Privacy page and every `privacy*` ARB key are deleted (13 locales)**; an invariant or accepted deviation may now carry ZERO disclosure keys → §8 "Owner directive after v3" | Keeping the page: this was an owner directive, not a trade the plan made | Every copy round, copy-tie test and disclosure edit aimed at that page left the plan; disclosure now happens in `SECURITY.md` and the manifest, not in the app | Nothing in this plan — reinstating it is an owner decision. `docs/privacy/README.md` records that an empty `disclosure_arb_keys` is a permitted state |
### 9.3 2026-08-30 — the hardware constraint, and what it did NOT change

The owner's constraint of this day (no macOS machine, no iPhone, no Android handset for the duration — §2.5)
re-based every gate in the plan. **No decision was reopened and no recommendation was reversed**; what changed is
what the owner is deciding ON. These rows exist so that when hardware returns, the re-based gates can be found and
re-run rather than quietly forgotten.

| # | Date | Status | Decision | Rejected — and why | Cost | Invalidated by |
|---|---|---|---|---|---|---|
| **L-31** | 2026-08-30 | DECIDED (owner-directed) | **Energy numbers become ESTIMATES; liveness proofs do not.** Gates are typed into two classes: a **POWER-MEASUREMENT gate** may be replaced by model E's arithmetic and is tagged `ESTIMATED` at every site; a **LIVENESS / WEDGE-SAFETY gate** may NOT, and is re-based on the strongest CI evidence with its residual stated in full → §2.5 | Treating all gates as one class (the plan's original wording) — an estimated wedge is worthless, and the 2026-08-20 field failure is exactly the class an estimate cannot see; deferring the phases until hardware returns (the owner wants them shipped) | Every energy figure in this plan is now weaker than **I**, and can never *fail* — an estimate that disagrees with a future measurement means the model was wrong, not that the phase regressed | Hardware returning. §6.7 lists what each device buys and in what order |
| **L-32** | 2026-08-30 | DECIDED (owner-directed) | **"Post-release data" means owner/user observation and CI proxies — never instrumentation.** Nobody may later plan telemetry, metrics or "anonymous usage" to close the measurement gap → §2.5 | Any analytics/crash/attribution SDK: `INV-R-NO-TELEMETRY-SDK` and `check_m7_native_wake_guards.sh` check 9b would red on the first commit, and it is a Rule-10 regression dressed as a measurement plan | The measurement gap stays open indefinitely | Nothing may invalidate this one. It is a floor, and it is guard-enforced |
| **L-33** | 2026-08-30 | **PARKED** | **P2b is parked — do not implement, do not cut its packets.** Its second merge gate is a LIVENESS gate (does a delivery wake Dart on a genuinely suspended AP?), which §2.5 forbids replacing with an estimate and which the emulator cannot re-base — it never suspends the AP → §5.2, §2.5, U-P2-1 | Shipping P2b anyway: it removes a wake source with no evidence the replacement fires, "the exact shape of the 2026-08-20 field failure"; measuring `p` and accepting it (OD-P2-2) — with no phone there is no number to accept, and *an accepted residual with no number is not an accepted residual* | **The AP-suspend saving is UNKNOWN, not estimated** — model E carries it as UNKNOWN rather than inventing a figure. Anyone reading "Android is fixed" after P2a is reading it wrong | **Un-park condition, written down:** one Android handset (no Apple hardware needed) plus `POWER_MEASUREMENT.md` §5 under `dumpsys deviceidle force-idle`, screen off, cellular, in BOTH battery-exemption states |
| **L-34** | 2026-08-30 | DECIDED | **P0-D (the owner-run hardware baseline) is struck but KEPT struck-through, not deleted**, and replaced by **P0-D′**: estimation model E plus a CI proxy register. P0-D′'s done-criterion includes a reviewer sweep proving **no number anywhere in the plan reads as measured** → §5.0, §6.5a | Deleting the row — "so nobody later reads a missing baseline as 'somebody forgot'"; filling `POWER_MEASUREMENT.md` with estimates — an empty results table is a missing measurement, a filled-with-estimates one would be a forged one | Later phases have no measured denominator, so §6.6's relative column is as unevaluable as its absolute one | The first real measurement. Note the standing risk P0 named: **estimate creep** — a model-E figure restated three documents later without its `ESTIMATED` tag |
| **L-35** | 2026-08-30 | DECIDED | **`docs/POWER_MEASUREMENT.md` lands IN FULL and is then banner-DEFERRED** — not cut down, not simplified, not left for later → §5.0 P0-C | Deferring the writing: "a protocol written now, while the constants and the reasoning are fresh, is exactly what a future hardware campaign will need and what a reconstructed-from-memory version would get wrong" | A document nobody can execute yet. Its Android half is runnable strictly earlier (a handset + `adb`), and the banner says so | Nothing — it is a deferred asset, not a claim |
| **L-36** | 2026-08-30 | DECIDED | **The `created_at` grader requires `--publishers` AND a DECLARED window.** Without `--from`/`--until` it would grade only `last − first`, so head/tail silence would vanish; an undeclared run exits `UNGRADED` (5), never a pass, and a circle split across two capture files is refused (3) → §5.0 P0-C, §7.2 | Grading an undeclared window — two named false-green field shapes | Every caller must know and declare its own window | A capture format that carries its own window |
| **L-37** | 2026-08-30 | DECIDED | **The `publish_stagger_test.dart` literal→constant conversion is WITHDRAWN** — the converted form cancels algebraically to `2 × kTtlNetworkBufferSeconds` and so stays GREEN under a `kLocationPublishMaxInterval` 168 → 220 mutation that the literal reddens. Both mutation runs were performed → §5.0 P0-A | The conversion, and importing `kLocationMessageRetention` from `sharing_health_provider.dart` into a service test (another test pins that declaration's site) | A literal `228` survives in a test, with a `reason:` naming `LOCATION_MESSAGE_RETENTION_SECS` | A shared source of truth across the FFI, which does not exist |
| **L-38** | 2026-08-30 | DECIDED | **The `circle_details_layout_test.dart` conversion is re-classified as DOCUMENTATION, not a tripwire**, proven by a `kTtlNetworkBufferSeconds` 30 → 300 mutation that leaves its 39 tests green while `circle_details_expiry_test.dart` goes 4 red → §5.0 P0-A | Presenting it as a pin — a pin that cannot fail is this repo's documented recurring failure mode | One fewer claimed tripwire | A rewrite that makes the layout test value-sensitive |
| **L-39** | 2026-08-30 | DECIDED | **`docs/WN_RELAY_EPOCH_SYNC_MIGRATION.md`'s Android-15 6 h FGS timeout claim is FALSE, not merely unverified** — the cap covers `dataSync`/`mediaProcessing` only, and the doc's earlier "CORRECTION" was itself the error. Two hedges carried to every retraction site: Google's "*Currently*" means the list can widen and must be re-checked, and `shortService` does carry its own ~3-minute cap → §1.2, §5.0 (U-P0-1) | Leaving it as U — an unverified claim that is load-bearing for a background design is a decision by default | Two hedges to maintain at four sites | Google widening the timeout list to include `location`. **Re-check, never cache** |

### 9.4 2026-09-03 / 2026-09-04 — P1, P2a and P3 as they actually landed

This is where the epic began correcting ITSELF: every row below is a decision taken because a review of shipped
code contradicted something this plan asserted.

| # | Date | Status | Decision | Rejected — and why | Cost | Invalidated by |
|---|---|---|---|---|---|---|
| **L-40** | 2026-09-04 | DECIDED (owner) | **OD-P3-e — CAP THE CONFIRMATION CHAIN, and test it.** A confirmed anchor may not be served beyond a bounded multiple of `kStreamPositionMaxAge` no matter how many coarse fixes confirm it; anchor age becomes a SECOND escalation trigger alongside `kStationaryConfirmMaxAge`. The 200 m displacement bound of L-07 gets its first test at the same time → §4 OD-P3-e | Sending the true fix age — that is a new wire field, which D0 forbids; leaving it uncapped — a peer's age pill would read "just now" for a fix hours old and up to ≈ 200 m wrong | A modest battery cost: a stationary device now escalates on age as well as on silence | A cheaper way to express fix age that D0 permits |
| **L-41** | 2026-09-04 | DECIDED (owner) | **OD-P3-f — a FULL English revision of the iOS settings copy in ONE 12-language wave.** The cost of a wave is the twelve reviewers, not the string count, so a minimal fix costs nearly the same as doing it properly → §4 OD-P3-f, §7.1b | A minimal fix of the five named weaknesses | One more full reviewer wave | — |
| **L-42** | 2026-09-04 | DECIDED (owner) | **OD-P3-g — localize the prominent-disclosure consent strings NOW**, folded into the OD-P3-f wave. Consent the user cannot read is a weak basis for a permission gate → §4 OD-P3-g | Leaving them hard-coded English (pre-existing, not introduced by P3) | The move changes a manifest carrier's KIND (`LocationDisclosureStrings.backgroundIos` was a `non_arb_claims` carrier of `INV-L-IOS-WAKES-RECEIVE-ONLY`) and must be proved against the ratchet | — |
| **L-43** | 2026-09-03 | **SUPERSEDED** by the P1 review pass | **P1's goal sentence "no maintenance timer is armed while backgrounded" was FALSE as landed.** Arming was foreground-gated, but nothing cancelled an already-armed timer, so one of each survived the pause and fired while away. Closed by `suspendForBackground()` from `MapShell._onPaused` → §5.1 | Softening the sentence instead of landing the cancel | One KeyPackage probe, one relay-list probe and one health tick per backgrounding until the cancel landed — small in energy, but a PRESENCE signal from a device the plan calls silent | **The lesson, which is the reusable part: a gate on the ARMING path is not a gate on the STATE.** Any future "we gate that" claim about a timer must say which of the two it gates |
| **L-44** | 2026-09-03 | DECIDED | **The Rule-13 "one file cannot publish a location and a commit" gate is FILE-level, so `background_deferred_send.dart` is split out** — the change list's instruction to put both in `background_location_task.dart` was not satisfiable as written → §5.1 | Keeping one file and relying on the gate | A new file with no coverage floor of its own — still **OWED** (see L-46) | A gate that reasons about call sites rather than files |
| **L-45** | 2026-09-03 | **CORRECTION** — retires SEC-F3's claim; not softened | **SEC-F3: the claim that the publish-ladder gate is a "checkable property" DOES NOT HOLD and is retired.** The gate misses the `CircleService` indirection (`confirmPendingCommit(` / `failPendingCommit(`), demonstrated by mutation with the gate GREEN. The real guarantee is the Dart AST inventory test `location_publish_ladder_sites_test.dart` plus the extended gate; the file split is a consequence, not the guarantee → §5.1 | Softening the claim — "the claim has to be retired rather than softened" | A guarantee that rests on an AST test rather than on a grep | A grep-shaped gate that can see through an indirection, which is a contradiction in terms |
| **L-46** | 2026-09-03 | **OWED** | **Coverage floors are re-pinned by `--repin`, never by hand.** P1 produced ONE ratchet, not the three predicted: `src/relay/manager.rs` 80.14 % → 90.52 %, floor 78 → 88; a new `src/relay/cursor.rs` row pinned exactly at 100 → §5.1, `scripts/ci/coverage_floors.txt` | Hand-editing — the file's own header records that hand-editing is what broke it (three rows tightened to 0.06–0.72 points of headroom, one of which reddened CI run 30964250098 on seven hundredths of a point) | Floor rows for `background_deferred_send.dart` and (later) `background_burst_coordinator.dart` cannot be written from a local SDK and stay **OWED** | A local toolchain matching `coverage_toolchain.env`. Until then a locally-measured floor is a floor CI cannot satisfy |
| **L-47** | 2026-09-03 | DECIDED | **`live_sync_cursor_replay_e2e.rs`'s intermittent failure was NOT a wait-budget problem, and the budget scale must not be credited with fixing it.** It sampled its cold-seed baseline AFTER the REQ opened. Fixed by `wait_cursor_at_least(target_ms)` plus a `read_sync_cursor == None` precondition; `HAVEN_TEST_WAIT_SCALE` exists only for instrumented-build slowness and three fixed sleeps are deliberately NOT scaled → §5.1, V-P1-6 | Scaling the budget — it would have hidden the race the test found (Testing Requirements rule 8) | — | Nothing; this is the correct diagnosis, and the record exists so the wrong one is not re-adopted |
| **L-48** | 2026-09-03 | DECIDED | **A cross-packet defect neither packet owned:** P1-A2 + P1-N0 together produced a 7-day gift-wrap replay on every Android glance, because `LiveSyncCore::start` passed ONE phase to both planes. Fixed by giving `register_and_subscribe` a `phase` AND an `inbox_phase`, with the cursor read taken BEFORE the cold-start seed writes one → §5.1 | Per-packet review — **which structurally cannot see this class**, and that is the recorded lesson | — | Nothing. The lesson is procedural: a phase's reviewer wave must read the packets' INTERACTION, not each packet |
| **L-49** | 2026-09-04 | DECIDED | **P2a's B1 lane gains a SECOND forced-idle phase after `HOLD_COMPLETE`**, requiring BOTH `state=IDLE` read back from `dumpsys deviceidle get deep` AND a `trigger=watchdog` publish within 302 s (six fixtures) — so OD-P2-2's Doze-POLICY half is held, not owed → §5.2 | Trusting `force-idle`'s exit code (it exits 0 on a device that refuses to doze); widening the existing hold (steps 5–7 must keep reading the span they always did, so no P2a bound moves) | Lane bounds moved (drive 10 → 14 m, `flutter drive` 18 → 20 m, deadline 25 → 28 m, step 35 → 38 m) | The AP-suspend half remains **NOT AVAILABLE** (U-P2-1) — the emulator never suspends. The reviewer objection that "AP suspension is unassertable" was a category error, and this landing settles it |
| **L-50** | 2026-09-04 | DECIDED — **accepted residual (W-3)** | **The 228 s no-gap bound does NOT hold unconditionally on Android API 23–30.** Trigger: `Api.legacy` AND a cold acquisition AND `J + ρ + σ ≥ 178 s`; worst realized gap **248 s** against a 228 s retention, i.e. a peer's marker absent for at most 20 s, once. Read it as a bounded, accepted defect with a named trigger, never as a passing invariant → §3 D3 (iii), §5.2 | **A legacy-only 147 s interval ceiling** — it *works* (empties the breach set) and is still not taken, for two reasons, both pinned by a test that names them: (1) nothing reads `Build.VERSION.SDK_INT` today, so branching costs a second native channel threaded into a deliberately pure file plus a fail-open/closed policy; (2) the ceiling is not free on the cohort it protects — the consumed fix's age walks past the 30 s horizon, spending GNSS acquisitions for nothing | A ≤ 20 s marker gap on the legacy cohort, once per triggering cycle | Evidence that the 20 s gap is user-visible in practice, or a cheap API read appearing (e.g. `device_info_plus` arriving for another reason) |
| **L-51** | 2026-09-04 | DECIDED | **Two P2a arithmetic statements are CORRECTED rather than defended.** The gap formula `J + 50 + ρ + σ` was the uncapped region only and overstated the breach (268 vs a true 248); the "every lever pays in S+ duty cycle" reasoning was simply wrong and is **retracted** — an API-level branch costs nothing on S+ by construction → §3 D3 (iii) | Keeping either — a wrong argument for a right conclusion is a trap for the next reader | — | — |
| **L-52** | 2026-09-04 | DECIDED | **The proof defect that HID L-50 is disclosed:** the hot sweep varied ρ and σ while the cold group ran ρ = σ = 0, "which is how a 941 094-point sweep missed a 228 s breach". The breach SET is now asserted as an EQUALITY, and today's worse worst case (240 s) is stated to keep the comparison honest → §3 D3 (iii) | Fixing the sweep quietly | — | **The reusable lesson: a large parameter sweep proves nothing about the parameters it holds at zero.** Check the sweep's own coverage before crediting its result |
| **L-53** | 2026-09-04 | DECIDED | **P2a's review found a BLOCKER of the exact class the phase exists to remove**, and it is recorded rather than absorbed: a watchdog early return latched `_inFlightPublish` forever, so background sharing published once per backgrounding and then stopped ≈ 72 s later. Fixed with `_trackCycle` owning the slot on every exit under an `identical` check → §5.2 | — | **28 green tests missed it**, because every one of them ended with the no-op tick as its last action | **The generalised rule, worth more than the fix: a test for a guard that CLAIMS a resource must outlive the claim.** Any suite whose last action is the claim proves nothing about its release |
| **L-54** | 2026-09-04 | DECIDED | **A fix pass is where the next defect gets planted.** P2a's first fix pass INTRODUCED a MAJOR defect (an abandoned cycle's `finally` releasing the process-wide non-refcounted lock out from under the teardown's hold), and the tests written in that same pass structurally could not reach it → §5.2 re-review | — | — | Nothing. This is a standing procedural finding: a fix pass gets its own independent review, not the author's |
| **L-55** | 2026-09-04 | DECIDED | **Two B1 oracles are demoted from GATES to EVIDENCE** (the relay-side line count and the emulator `batterystats` GNSS threshold), as is the wake-lock sighting count → §5.2 | Keeping them as gates — "a gate that cannot fail is this repo's documented recurring failure mode, and three of them reached review in one lane" | Fewer gates, honestly counted | An oracle that can be made failable |
| **L-56** | 2026-09-04 | DECIDED | **WP3-2's hardware merge gate (M7 §6 0a) is RE-BASED on a four-part CI bundle**, all four required: the `e2e-ios-background-publish` lane green in the **Always** matrix job (which is why OD-P3-c hardens from "worth ~40 min/run" to mandatory), the same lane green in **WIU** with the tier pinned, `e2e-ios-auth-tier` with the inverted session-held oracle, and the Swift/static bundle plus 13-locale copy ties → §5.3 | Blocking P3 on a gate that cannot be met; pretending the gate was met | **Residual, unhedged:** the simulator cannot prove OS suspension, cannot render the status bar and cannot run two stationary hours; V-P3-3 stays UNKNOWN, **and the closest physical neighbour of this exact configuration FAILED in the field on 2026-08-20** | An iPhone. M7 §6 items 0a/0a-provisional/0b/0c are written in full, headed DEFERRED, banner intact |
| **L-57** | 2026-09-04 | DECIDED | **P3 ships STAGED, and says so** — behind the background-sharing toggle, in the fail-safe posture for provisional/iOS-17 Always, recorded as an open risk in this plan, in M7 §6 0a and in FA Unit F "so the next person reads 'unproven on a device', not 'proven'"; the owner watches their own device when one exists, and a failure reverts the confirmed-Always branch to holding the activity session (a one-line change) → §5.3 Risks | **Explicitly prohibited:** buying the evidence by widening a lane window, by treating simulator continuity as device continuity, or by adding any in-app reporting | A phase shipped on an unproven continuity claim, with a named one-line rollback | The owner's desk-afternoon check, when hardware exists |
| **L-58** | 2026-09-04 | DECIDED | **`CLError.locationUnknown` returns EARLY and is never forwarded, AND `_requestedProfile` becomes nullable** (the error path records "native tier unknown" so the next `_applyProfile()` re-issues `setProfile` unconditionally) → §5.3 (F1) | Either half alone: the filter alone leaves `.network` and friends able to desync; the sentinel alone leaves the session flipping to Best on every indoor moment | A filter on an error path, which must never become swallowing — `denied` is still distinguished and all three properties are guard-pinned | Evidence of an error class that should reach Dart and does not. **What it fixed is worth remembering: one ordinary indoor moment silently ended background sharing until the user reopened the app** |
| **L-59** | 2026-09-04 | **CORRECTION** — supersedes §1.2's own earlier correction | **iOS has NO distance filter in EITHER toggle state.** `HavenLocationStreamHandler.init` sets `kCLDistanceFilterNone` once for both profiles, `_kIosNoDistanceFilter` is deleted, and the geolocator `-1` pointer-compare trap is retired with the plugin path. 1 m survives only on Android's foreground arm → §1.2, §5.3 | Keeping the constant "for safety" — the guard header now says why it must not be re-added | The whole iOS `AppleSettings` test family retires WITH the branch; R8 moves from "flags in a settings object" to "the listen argument equals the toggle" — same promise, new carrier | A return to the plugin path on iOS |
| **L-60** | 2026-09-04 | **CORRECTION** (CI-R23) | **`locationSettingsIosCatchUp` is DELETED — key, `@description` and twelve translations.** The card renders only under Always, so a sentence urging the user to GRANT Always reached nobody; it shipped unread in 13 locales and was never composed in. The card is TWO sentences → §5.3, §7.1 | Keeping it and fixing the composition — nothing consumes it under any tier | Every artefact that referenced it (copy-tie clause, l10n clause, page test, reviewer checklist, WP3-6 re-keying) had to be struck in the same pass | **The lesson: a key added for a render order nobody verified is a key nobody reads.** Verify the render path before translating into thirteen languages |
| **L-61** | 2026-09-04 | **CORRECTION** — the planned override REDS the build | **P3 needs NO `ratchet_override` at all.** `enumerate_weakenings` subtracts `$still`, and `INV-L-IOS-INDICATOR-HONEST` still claims `locationSettingsIosGuidance`, so the key drop is never enumerated and a written override is STALE. Tried both ways on the branch → §5.3 (WP3-6) | **Un-claiming the guidance key to make the override necessary — explicitly rejected**: it would drop live assertion coverage for a bookkeeping formality | One planned artefact deleted | The standing stale-override trap still applies where an override IS needed — P5(a) is the next one |
| **L-62** | 2026-09-04 | DECIDED (corrected twice the same day) | **The indicator sentence is selected by `alwaysConfirmed`, and the provider answers `null` while the handler reports `armed == false`.** First correction: not `backgroundActivitySessionHeld`, which is false on the iOS 15/16 floor while the bar is up, so it would show the arrow sentence to a user looking at a bar. Second: `disarm()` clears `alwaysConfirmed` unconditionally, so with sharing OFF the card told a confirmed-Always iPhone "iOS shows its blue location bar" at the exact moment it was deciding whether to turn sharing on → §5.3 | Both earlier selectors; the page now also invalidates on the DISABLE edge, not only on enable and resume | A new `armed` status key and a nullable provider | `ios_indicator_copy_accuracy_test.dart` fails if the wrong selector name reappears — this is one of the few rows with a live tripwire |
| **L-63** | 2026-09-04 | **OWED** (CI-R21) | **`resent_fix_payload_has_identical_shape` was never written**, so `INV-L-IOS-PUBLISH-INPUT-BEST-PROFILE-ONLY` omits the equal-length clause rather than citing a test that does not exist → §5.3 | Citing the test anyway — the manifest would then claim coverage it does not have | The argument stands unpinned. The honest residual is retained in the design: ciphertext length varies with the coordinate VALUE, so the claim is "a re-send adds no signal", never "no signal in size" | Writing the test. **Note the internal tension recorded by the review: the invariant's `tests:` list in the change list still enumerates it** |
| **L-64** | 2026-09-04 | **OWED** | **The three P3 coverage floors are re-pinned from CI's lcov, never locally**, so the first CI run on this branch is EXPECTED to fail them → §5.3 "P3 coverage-floor debt" | Hand-editing or guessing — a percentage is a ratio whose denominator is a compiler property, and guessing violates the pin rule | Three expected red rows and one push-measure-repin loop | CI's own artifact. WP3-6 predicted the `geolocator_location_service.dart` row exactly: the iOS branch shrinks, the denominator drops, coverage rises through the floor |
### 9.5 2026-09-05 — the review of shipped P4-2, and the MDK survey

| # | Date | Status | Decision | Rejected — and why | Cost | Invalidated by |
|---|---|---|---|---|---|---|
| **L-65** | 2026-09-05 | ~~**OPEN**~~ **DECIDED 2026-09-09 by L-121** — both halves ((iv) + (i)); (iii) rejected; ~~the work is OWED~~ ~~**the RUST work LANDED the same day (L-133); (i)'s Dart consumer is what is still owed**~~ **ALL of it LANDED the same day: the Rust half is L-133 and (i)'s Dart consumer is L-134** | **OD4-c is OPENED, and the plan deliberately makes NO recommendation.** A burst killed mid-publish leaves the group wedged, verified against the pinned MDK v0.9.4 in two independent ways: the re-fetched own commit comes back TERMINAL (`MessageState::Sent` → `IngestOutcome::Stale { OwnEcho }`, consulted first in `do_ingest`), and for the removal-bearing case `PendingCommitRecovered` is never emitted at all (hydrate short-circuits on `staged_removes_member`). Both predate P4; what P4 changes is EXPOSURE → §4 OD4-c, §5.4 | The plan picking one of the two options for the owner — it is a user-visible failure mode with a re-invite cost, so CLAUDE.md's "STOP and ask" applies | **No test covers either branch, and the Rule-13 source gate stays GREEN through both** — nothing goes red to remind us. Until it is decided, no P4 text may describe a crash mid-burst as self-healing | Either option being taken: (i) a `GroupUnrecoverable`-class status forcing a re-invite, or an explicitly accepted, named residual written into `SECURITY.md`. **Recording the risk and shipping without (i) is only available if the owner says so explicitly** |
| **L-66** | 2026-09-05 | **SUPERSEDED** by L-93 | **OD4-c option (ii) — "gate P4 on a released MDK tag containing the epoch-gap backfill" — is declared DEAD.** #825 and #892 shipped in v0.9.5 and are unreachable from Haven's five pinned crates at every tag; #825's policy type lives in `marmot-app`, which the manifest and `check_mdk_supply_chain.sh` both reject → §4 OD4-c, §5.7 | Waiting for an upstream release — there is no tag to bump TO for that fix | OD4-c collapses to option (i) or a named residual — **and the reasoning behind that collapse was wrong, see L-93** | Already invalidated on 2026-09-08. **The narrow fact survived; the INFERENCE drawn from it did not** |
| **L-67** | 2026-09-05 | DECIDED | **P4M (MDK v0.9.4 → v0.9.18) is brought into scope as a MILESTONE and sequenced OUT of the P0→P6 chain**, to run after P6 closes, alone. Read the name literally — "calling this 'the MDK bump' is the single most dangerous thing anyone can do to it": 33 forward-only migrations, no `down` at any tag, 166 non-merge commits in the pinned crates, no CHANGELOG for any of them → §5.7 | Making it P4's precondition (that is option (ii), L-66/L-93); running it beside P4 or P5 — it moves `IngestOutcome`, `StaleReason`, `GroupEvent` and `PublishWork` underneath both, and "a red test in that window belongs to nobody in particular, which is how the FA wedges were born"; a partial bump (`libsqlite3-sys` is a `links = "sqlite3"` crate, so a partial bump is a link error, not a degraded build) | It is recorded in a POWER plan although it delivers **no power saving at all** — because this is the project's only sequencing record for it | Nothing about sequencing. **§6.4's one-commit rollback rule does not reach this milestone and must not be claimed to** |
| **L-68** | 2026-09-05 | DECIDED (recommendation) | **DO NOT execute P4M yet. Take P4M-1 only** — the v0.9.4-written DB fixture, the `match`-conversion of B4's two `if let` sites (correct and shippable at the CURRENT pin: it makes the future break loud and costs nothing now), and two upstream asks. The flag day itself is a NEW owner decision taken at P4M-2, covered by no §4 row today → §5.7 | Taking the migration now: the cost is a coordinated, irreversible flag day paid again in full on rollback ("rollback is not a revert" — a rollback build must WIPE and re-provision) | Real gains stay on the table: the OD4-c fix, the sender-ratchet reorder policy (the upstream half of the "ratchet 1000" wedge), bounded convergence retention, `Queued`-instead-of-illegal-transition, and the explicit storage close written for iOS `RUNNINGBOARD 0xdead10cc` | **Three named triggers: (a)** upstream ships a release-safe legacy path or an in-place `Legacy → Current` upgrade; **(b)** a security fix lands in a pinned crate — "that reverses the calculation immediately"; **(c)** the install base is small enough and the owner says so. **Explicitly NOT reasons:** OD4-c, the convergence send-gate, `rotation.rs`, or the Rule-12 cap. **CONFIRMED BY THE OWNER 2026-09-09 (L-124), with a FOURTH item that GATES the other three: (d) a TAGGED OpenMLS dependency.** The owner's ground is narrower and stronger than this row's — an untagged personal-fork branch head as the anchor for the MLS implementation itself — so (a) and (c) no longer suffice alone and (b) sends the call back to the owner rather than clearing the gate. **And read this cell's "NOT reasons" list against L-93: it was written on the inference L-93 superseded.** v0.9.5's durable outbound-fanout resumption WOULD fix OD4-c inside four pinned crates; the owner's decision treats that as real value the supply-chain gate outweighs, not as nothing |
| **L-69** | 2026-09-05 | **CORRECTION** — retracts §5.4's `since` sentence for the INBOX plane | **"Each burst's REQ carries `since` ≈ the previous burst time" is TRUE of the GROUP plane and FALSE of the INBOX plane**, and P4-6 must not assert it in `SECURITY.md`. Every burst open is a `Resubscribe`, so at the shipped k = 1 the device asks each inbox relay to replay **49 hours of gift wraps keyed on its own `#p`, every 72–168 s** → §5.4 Privacy metadata statement | Narrowing the lookback — verified and explicitly not re-proposable: the 49 h floor exists because NIP-59 wraps are backdated up to 48 h plus an hour of skew, and `cursor.rs` records that a wrap below the floor is lost SILENTLY ("an invitation that is never fetched is indistinguishable from one that was never sent") | **This codebase had already made the opposite judgement in writing.** `probe_subscriptions`' doc records why the health tick's inbox-silence arm was DELETED — the same 2-day replay, at 900 s. P4 at k = 1 does it **5–12× more often**, and no doc acknowledged the reversal until this note | Raising `INBOX_BURSTS_PER_REQ` (L-70), which OD4-b already authorises |
| **L-70** | 2026-09-05 | **OWED** | **The shipped `INBOX_BURSTS_PER_REQ = 1` is this plan's PLACEHOLDER, not a decision.** Raising k IMPLEMENTS the already-accepted OD4-b and needs no further sign-off → §5.4 change list | Treating k = 1 as settled | It is BLOCKED on one defect: at k > 1 a foreground re-anchor CLOSES the standing inbox REQ without re-issuing it, so invitations would stall until the next k-th burst | That defect landing. **Do not raise k before it does** |
| **L-71** | 2026-09-05 | DECIDED — **category error corrected**, plus an OWED gate | **`DEFAULT_MAX_PAST_EPOCHS` is an epoch COUNT; a time gap consumes nothing.** The conclusion survives on the right reason: a device that bursts every 72–168 s ingests each burst's commits inside that burst, so it falls behind by at most one burst's worth of COMMITS. A long offline gap is dangerous because of the commits it accumulates, not its duration → §5.4 | The original "the ≤ 168 s inter-burst gap is far inside `DEFAULT_MAX_PAST_EPOCHS`" argument | **A second constant, unpinned:** the past-epoch OUTER peel a one-behind burst relies on runs on `ConvergencePolicy::max_rewind_commits` (upstream default 5), which `security_rule_gates.rs` does NOT pin — so an upstream default change would silently break it with nothing going red | Extending `security_rule_gates.rs` to pin `max_rewind_commits`. **OWED, separate packet.** Until it lands, the guarantee rests on an upstream default and P4-6 must say so |
| **L-72** | 2026-09-05 | **CORRECTION** — stale premise (F35) removed | **`settle_before_pause_with(window, cap)` takes NO `clock` parameter, and it must not be re-added.** The parameter existed only to work around F35's claim that tokio is built without `test-util`, and F35 was itself stale: `test-util` IS in `haven-core`'s dev-dependencies, so `#[tokio::test(start_paused = true)]` compiles and the window logic is unit-tested on tokio's virtual clock with no injected clock at all → §2 F35, §5.4 | Keeping the injected clock "for testability" — it tests nothing tokio's virtual clock does not | — | A tokio change removing `test-util` from the graph |
| **L-73** | 2026-09-05 | DECIDED | **The `paused` gate in `run_repair` must stay BEFORE `take_due` AND park the task while paused.** Its first shipped form kept the placement and busy-spun: `next_deadline()` returns a deadline already in the PAST for a due entry, so `sleep_until_opt` returned immediately and the `paused` `continue` looped straight back — one core pinned at 100 % for the entire pause (726 416 iterations in a ~2 s test) → §5.4 | Moving the gate below `take_due` — `take_due` clears `due_at`, bumps `attempts` and arms the next backoff, so an early return there would CONSUME the pending re-issue rather than defer it (F28) | **A battery defect of precisely the class this phase exists to remove, inside the phase that removes it — and invisible to every guard, because the source shape the guard checks was correct** | Any later edit to this gate. Both properties must survive, and the phase's tests must keep a case that fails on a spinning pause |
| **L-74** | 2026-09-05 | DECIDED — **rationale corrected**, coverage gap left OPEN | **Per-endpoint settling does NOT close the fast-relay-EOSE hazard**, and the paragraph that read as if it did is corrected. What it fixes is delivery TIMING: the burst no longer publishes while a slow relay is still replaying → §5.4, §6.3 C2 | Leaving the stronger reading — the cursor is still per circle, so a `TimedOut` burst could advance past a window a slow relay never served (closed separately, see **L-86** — `EoseCoverage` / `anchor_end_of_stored_events`; the "L-87" this row first cited is the `2k − 1` inbox-fold row and has nothing to do with the cursor) | **§6.3's C2 cell currently NAMES COVERAGE THAT DOES NOT EXIST:** the backlog test that carried the "clear the router before the drain" attack was removed as unsound, and its replacement does not go red on that mutation | A stronger replacement test landing. **OWED** |

### 9.6 2026-09-07 — the review of shipped P4-4 and P4-5

Every row here is a decision taken because the shipped code contradicted §5.4. Read them as a set: the phase's
own review found one upstream defect on the wire, two HIGH defects the phase itself introduced, four wrong
values for one bound, and two claims that had to be withdrawn.

| # | Date | Status | Decision | Rejected — and why | Cost | Invalidated by |
|---|---|---|---|---|---|---|
| **L-75** | 2026-09-07 | DECIDED | **P4's headline sentence is QUALIFIED, and `SECURITY.md` is built from the residual list rather than from the metadata statement.** The qualified form: *"While backgrounded on iOS with sharing on, Haven opens a relay connection only at the instants it publishes its own location, and holds no standing subscription between them."* The unqualified sentence must never leave §5.4 → §5.4 "Residuals P4-6 MUST disclose" | Shipping the unqualified sentence — ten (later eleven) named cases sit outside it | A disclosure built item-by-item instead of from one paragraph | Any residual being closed in code — item 2 already was (L-90). Each closure must be struck from the list, not silently dropped |
| **L-76** | 2026-09-07 | DECIDED | **`openBackgroundBurst()` is the burst entry; `resumeAfterBackground()` is the FOREGROUND re-anchor.** P4-2 split them because only the first takes the `INBOX_BURSTS_PER_REQ` fold decision, on a background-only counter → §5.4 | Reusing the foreground entry in the coordinator — it would **silently disable OD4-b's mitigation: no error, no failing test** | `openBackgroundBurst()` THROWS on failure, and a failed open leaves the engine CONNECTED with partial REQs, so the `finally` must settle-and-pause even on the throw path | `check_engine_client_options.sh` check 9 pins the FFI delegation. **Nothing pins the Dart call site** — that is the live exposure |
| **L-77** | 2026-09-07 | **CORRECTION** — four values, then a re-scope | **The burst bound is RE-SCOPED, not enlarged, and `kMaxBurstCircles` is DELETED.** `burstBound(circles, stagger)` covers only the links the burst OWNS, and the over-budget stamp is taken BEFORE the maintenance fold and the teardown, so the two unboundable links sit outside both the sum and the elapsed time measured against it → §5.4 "The burst bound" | **The record is the point:** this plan said `N ≤ 12`; a correction raised it to 14 on the plan's own stagger-less formula; the implementer computed 11 by adding the stagger; a reviewer showed 11 unsound too, because the formula omits the PAUSE while `_closeBurst` measured elapsed time THROUGH it — and the pause ends in an uncapped Rule-13 drain. **A bound containing an unbounded term is not a bound.** Capping the burst was rejected separately: it would defer a due circle's location to keep a log line accurate | **A HEALTHY burst can exceed the watchdog, and that is not a fault** — the watchdog reports and never cancels, because cutting a burst short leaves the engine live with standing REQs, or a commit between SEND and OK | Where the sum crosses `kPublishLinkTimeout` is pinned behaviourally (`burstBound(3) < kPublishLinkTimeout < burstBound(12)`), never by a number in prose. **No `N ≤ …` claim of the retracted kind may be restated in any form.** One constant survived every round: `kBurstPublishBudget = 10 s` was right all along, because `LOCATION_PUBLISH_ATTEMPTS == 1` |
| **L-78** | 2026-09-07 | **CORRECTION** — §5.4's literal shape retracted | **The tick watchdog wraps the SINK branch only.** The shape §5.4 specified (`sink?.onTick(...) ?? _pacedPublish(...)` under one `.timeout(`) contradicts an invariant documented in the very file it describes: one timeout over both branches folds `_pacedPublish`'s decorrelation wait INTO the link timeout, and a deliberate gap must never read as a hang → §5.4 | The one-timeout shape | Two timeouts on two branches instead of one | A change that removes the decorrelation wait from that path |
| **L-79** | 2026-09-07 | DECIDED | **`kOptOutBurstWait` is 68 s, not 38 s** = 10 (the single-attempt publish the burst may be inside) + 18 (`BURST_SETTLE_CAP_SECS`) + 40 (the pause's four bounded `RELAY_LIFECYCLE_OP_TIMEOUT` steps), pinned to the Rust source by a Dart test → §5.4 | 38 s, which priced the pause at "the crate's 10 s per-relay OK wait" — but that is `wait_for_ok`, a PUBLISH primitive, and not the engine's pause at all. At 38 s the wait timed out on HEALTHY bursts and the direct pause ran underneath one: the exact thing the wait exists to avoid | The leftover sweep's extra per-REQ op and the uncapped Rule-13 drain behind it are **deliberately not priced** — being unpriceable is what makes this a BOUND on the wait rather than an await | Both teardown links are ISSUED together rather than awaited in sequence, so a wedged engine cannot starve the pool shutdown behind it. A change to that issuing order invalidates the bound |
| **L-80** | 2026-09-07 | DECIDED | **A failed engine open still PUBLISHES.** The coordinator skips the backlog wait (waiting on a backlog nobody requested spends the whole budget learning nothing) and runs the publish pass: the publish pool is a separate `Client`, and a location encrypted one epoch behind IS decryptable by peers (the outer ChaCha20 layer peels from the retained-anchor snapshot, the nonce is CSPRNG per message, and application messages advance no epoch, so `Buffered` — the FUTURE-epoch verdict — is not what a one-behind message hits) → §5.4 | Skipping the publish on a failed open — the location plane costs the engine nothing | **The residual, named:** a PERSISTENT open failure compounds. Once more than the retained past epochs' worth of peer commits have gone un-ingested, this device's kind-445s become undecryptable to every peer — silently, while relay acks keep coming back on this side | A consecutive-failed-open counter (reset by any success) now feeds the receive-plane signals of the sharing-health model instead of dying in a `debugPrint`. **A RUN of failed opens is evidence, not noise** |
| **L-81** | 2026-09-07 | DECIDED | **A confirmed upstream defect makes "no socket between bursts" false for entire inter-burst gaps, and Haven cannot make it impossible — so the phase guarantees instead that none SURVIVES.** `nostr-relay-pool` 0.44.3's `InnerRelay::disconnect` fires its termination notify BEFORE storing `Terminated`, and that notify is a one-permit `notify_one`; a task woken inside the gap marks the relay `Disconnected`, sleeps its retry interval with the permit already spent, then opens a **real socket** held alive by the crate's 55 s ping with no REQ on it — which the next burst silently ADOPTS. `terminate_all_relays()` re-asserts `disconnect()` until the pool proves quiet, and only then does `radio_off` go up → §5.4 | Patching the crate (it is pinned); waiting for the race to fire in a test — measured **48/150** disconnects under 2× oversubscription, **0/150** on `current_thread`, 0/300 on an idle host, so the window is a property of the machine and a backgrounded phone is the loaded case permanently. **A test that waited for it would assert nothing on an idle runner** | A bounded re-assert loop and a watch, where a correct crate would need neither | **Worth filing upstream** — swapping the two statements closes it, and upstream fixed the sibling defect deliberately in v0.37.0 |
| **L-82** | 2026-09-07 | DECIDED | **The radio-off WATCH, not the re-assert loop, is the guarantee.** A second strand shape exists that the loop's fingerprint cannot see — the task's `Disconnected` write landing BEFORE the pool's `Terminated` store — which reads as correctly terminated to the loop, so it converges and returns while the task still re-connects a retry interval later. The watch CUTS and COUNTS any relay that comes up while the radio is off, and never REPORTS it as connectivity → §5.4 | Describing the re-assert as the guarantee — it is a repair for the shape it CAN see | An extra counter (`unrequested_connections`) and a monitor arm | **Do not re-describe the re-assert as the guarantee.** Reporting such a socket as connectivity would have the health model clear its "disconnected since" stamp on the strength of a socket the engine did not open |
| **L-83** | 2026-09-07 | DECIDED | **Two HIGH defects P4-5 introduced, and how each was closed.** (i) A resume landing MID-BURST left the engine paused IN THE FOREGROUND, unrecoverably (`ensureRunning` reads `isRunning`, true across a pause; `_fullRestart` declines while paused; the health notifier early-returns while paused, so the banner holds at "healthy" while the device receives NOTHING). Fixed with a `foregrounded` PULL re-read before EACH teardown link. (ii) The end-of-burst pool shutdown could cut a commit between SEND and OK, because the motion trigger publishes over the same pool unawaited by the coordinator. Fixed with an UNBOUNDED commit-critical drain before the shutdown → §5.4 | A latch for (i) — one coordinator serves every pause of a mount, so a flag that only ever went true would leave every burst after the first resume holding its sockets for the whole background window: **strictly worse than the defect it closes**. A bounded drain for (ii) — a `.timeout(` cancels no Rust future, so bounding it is the same defect | The publish PASS is deliberately NOT handback-gated: stopping mid-pass would silently skip due circles, where stopping the teardown only leaves the foreground owning what it already owns. The drain's rounds after the first are capped at three | The 3-round cap rests on the trigger publishing at most once per `kLocationPublishOverlapGuard`. If that guard changes, a fourth adopted ladder stops meaning "the registry is lying" |
| **L-84** | 2026-09-07 | **OWED** ×2 | **Two items are recorded rather than left implicit.** (i) `trackCommitCriticalForTest` is a test-only entry point standing on `LocationSharingService`'s PUBLIC surface — the price of making the Rule-13 drain testable without the Rust bridge. Not a stub and not dead code, but production API that exists for a test. (ii) The coordinator's JOIN branch is now a genuine redundancy and **no test distinguishes it** from queueing behind a burst → §5.4 | Papering over (ii) with a proxy assertion that would pass for the wrong reason | (i) is owed a revisit if the service ever gains a seam that does not need it; (ii) is a real gap, reported rather than hidden | A seam for (i); an observable that separates join from queue for (ii) — the refused-window drain removed the one the old tests relied on |
| **L-85** | 2026-09-07 | **CORRECTION** — the change list's claim was false | **P1's foreground gate spared the HEALTH timer, and health is the one of the three that could undo the whole phase.** The claim that "the P1 foreground gate already keeps KP/relay-list/health timers un-armed while paused, so P4 adds nothing there" is TRUE of KeyPackage and relay-list and FALSE of health → §5.4 change list | Carrying the claim | A carve-out that had to be found by review rather than by a test | Whatever re-arms the health tick on this branch. `maintain_subscription_health` short-circuits to `HealthAction::Paused`, but the Dart timer is the outer half |
| **L-86** | 2026-09-07 | DECIDED | **The stale-EOSE cursor caveat is CLOSED IN CODE, and §5.4's "being fixed in a separate packet" instruction is spent — do not re-derive the caveat from it.** The advance is now gated on `EoseCoverage`: `anchor_end_of_stored_events` early-returns unless every accepting relay answered, so a `TimedOut` burst issues no advance at all → §5.4 | Leaving the instruction in place — an instruction to fix something already fixed is how a correct file gets "corrected" back | — | Pinned by `a_burst_that_did_not_settle_every_endpoint_leaves_no_advance_standing`, all three arms. **"Settled per endpoint" is now a cursor-safety property as well as a timing one** |
| **L-87** | 2026-09-07 | DECIDED | **`k` counts BURSTS, not publish ticks — and a burst that FAILS TO OPEN still consumes a fold position.** A joined tick issues no REQ and never reaches the Rust fold decision; `background_bursts.fetch_add` runs ahead of BOTH post-connect failure exits. So the worst-case gap between inbox REQs is **`2k − 1` intervals, not `k`** → §5.4, §4 OD4-b | The obvious reading ("every k-th tick"), which is wrong for any multi-circle user | **OD4-b's "≤ 10 min invitation latency" does not price this**, and the honest cost is up to ≈ 2× the figure that row carries | It must be re-derived before k is raised (L-70) |
| **L-88** | 2026-09-07 | DECIDED | **The residual list gains the motion trigger's own plane.** It publishes OUTSIDE the burst plane, issues no REQ (so the qualified sentence survives it), but its socket is closed only by the NEXT burst's teardown or by the pool's own **(60 s, 70 s]** idle sleep — not "within seconds" — and while the user is MOVING it lowers the publish-cadence floor to `kLocationPublishOverlapGuard`, so "every 72–168 s" is the STATIONARY cadence, never a ceiling → §5.4 residual 1 | Presenting 72–168 s as a ceiling on how often a backgrounded device connects | Two things the headline sentence must not hide | A change routing the motion trigger through the coordinator |
### 9.7 2026-09-08 — the gap closure, P4-7, P5(a), two corrections of corrections, and the P6-B′ estimate-integrity sweep

| # | Date | Status | Decision | Rejected — and why | Cost | Invalidated by |
|---|---|---|---|---|---|---|
| **L-89** | 2026-09-08 | DECIDED (three independent reviewers, unanimous) | **Reframe the pause-instant socket decision from "could a burst run?" to "is a burst running?", and route the close through the coordinator's existing teardown.** `closeIdle()` queues `_closeBurst` on the same `_chain` under the same `_bursting` flag, which is load-bearing three times over: it cannot interleave with a burst, a mid-pause opt-out waits for it through `runningBurst` instead of pausing underneath it, and it inherits both the per-link handback re-reads and the unbounded Rule-13 drain instead of open-coding them. **Needed no Rust change** → §5.4 "Gap-closure decision record (2026-09-08)" | Five options struck with reasons, plus one declined: **always drive an immediate burst at the pause** (a duplicate kind-445 within 60 s of the last, discarding the overlap guard's own justification — MORE presence revealed, and it fixes nothing for an account with nothing eligible); **leave the code and qualify the invariant** (procedurally available and rejected on the merits — the residual is a branch nobody meant to leave open, it fires on the DOMINANT interaction, and buying documentation accuracy with the pillar that ranks first is the trade CLAUDE.md forbids); **reuse `releaseBurstPlaneOnOptOut`** (no handback gate, no commit-critical drain — it would import a Rule-13 hole onto the most frequent pause path in the app); **a publish-less "ingest and close" burst** (not a passive re-use: it does `unsubscribe_all`, `connect()`, re-issues every REQ, emits the 49 h `#p` query and consumes a fold slot — presence revealed at a NON-publish instant, privacy-inferior to what was adopted); **force the publish-pool shutdown at the foreground handback** (races the resume publish, costs a cold reconnect while the user watches the map, and would require inverting three tests that assert the opposite as a positive property) | The deeper error it fixes was a two-pool conflation: `pausedRelayOwner`'s `none` branch shuts the PUBLISH pool, while all three leaked artefacts belong to the ENGINE pool. **A one-predicate fix would have closed the wrong socket and left the sentence false** | **Do not "simplify" the fix into any option struck here** without new evidence. Note separately: **deleting `shouldBurstImmediatelyOnPause` entirely was DECLINED for this packet only, and is NOT refuted** — it changes observable publish behaviour and touches the P2a e2e oracle. Revisit if that oracle is being re-derived anyway |
| **L-90** | 2026-09-08 | DECIDED | **`shouldStopLiveSyncOnPause` is widened from `!isIOS` to `!(isIOS && backgroundSharingEnabled)`** — "every pause except the one whose process keeps receiving" — so iOS with background sharing OFF now STOPS the engine, as Android-with-sharing-off already did → §5.4 residual 2, `MapShell.shouldStopLiveSyncOnPause` | Pausing that arm instead: **stopping is the recoverable direction.** `_healLiveSyncIfStopped()` restarts a STOPPED engine on every resume and on every heal tick; a PAUSED engine is invisible to it (`isRunning` stays true across a pause) and needs the separate `reanchorPausedEngine` repair | Before this, that arm left the engine neither stopped nor paused, holding every REQ, its socket and the crate's 55 s keepalive for the whole background window | A future need to keep an iOS sharing-OFF engine alive — which would have to answer the recovery question first |
| **L-91** | 2026-09-08 | DECIDED | **The residual list is renumbered to eleven: item 2 is RESOLVED IN CODE and must NOT be disclosed, and items 8–11 are new** — an account with nothing publish-eligible receives NOTHING while backgrounded; the resume re-anchor throttle is bypassed on this branch; a cold launch that backgrounds before the engine starts comes up Live in the background; and the idle close can cut an ordinary in-flight publish → §5.4 | Presenting the gap closure as pure gain — items 8 and 9 are real receive-plane costs of closing it | Item 8 is the intended trade (the alternative is an unbounded standing REQ for an account sharing with nobody, and R14 forbids a background timer to reach the inbox any other way); item 9 makes a quick out-and-back cost a pause, a pool reconnect and a 49 h `#p` replay each time, where before it cost nothing | Item 9's mitigation — distinguishing "paused, but recently enough that the foreground's own prior REQ still covers the window" — is machinery **not currently judged worth its complexity**, and is recorded here rather than forgotten |
| **L-92** | 2026-09-08 | **SUPERSEDED** largely by L-100 — OD4's own framing | **OD4's "presence only at publish instants" is FALSE for a multi-circle account.** A burst opens EVERY circle's REQ and dials EVERY circle's relay, while the publish pass sends only to the due set — and the open precedes the publish unconditionally, so a burst whose window returns null or whose consent flips leaves a REQ/CLOSE pair with NO kind-445 at all. Disclosed as a `SECURITY.md` residual → §4 OD4 | Leaving the row's framing | A relay carrying circle B saw a REQ/CLOSE pair on every burst and this device's kind-445 for B on only ~1/N of them | **Largely resolved by P5(a) (L-100): with one burst publishing every eligible circle, the REQ set and the publish set now coincide for any roster inside `kMaxCirclesPerBurst`.** What survives is the roster past eleven and the null-window/consent-flip bursts — **and the first of those two goes away with the roster bound at 10 (L-123, decided 2026-09-09), leaving only the null-window/consent-flip bursts.** **This row's text has not been updated for that — see §9.9** |
| **L-93** | 2026-09-08 | DECIDED — **a correction of a correction** | **L-66's narrow fact stands; its INFERENCE was false.** "The #825/#892 backfill is unreachable at every tag" does not imply "no bump fixes OD4-c": **v0.9.5 shipped a different and sufficient mechanism — durable outbound-fanout resumption — entirely inside `cgka-traits`, `storage-sqlite`, `cgka-engine` and `cgka-session`, all four of which Haven pins.** Hydrate gained a `restored_pending` branch computed ABOVE the `staged_removes_member` guard, which became four-way; when it fires, `restore_pending(...)` brings the group back in `PendingPublish` removal-bearing or not — OD4-c mechanism (b) directly, which makes mechanism (a) irrelevant. **So the reason not to bump is the FLAG DAY, not unreachability** → §4 OD4-c, §5.7 | Carrying the "no bump fixes it" inference. Also settled: **#877 is IRRELEVANT, not merely unverified** (it touches only `incident-replay` and the conformance simulator) | It is **OPT-IN**: the engine reads fanouts on hydrate but never writes one for Haven-authored or auto-commit publishes, so Haven must stage them itself. And it must be **v0.9.12 or later, never v0.9.5–v0.9.11**, which demand a `fork-{prior_epoch}-…` snapshot and QUARANTINE the group if absent | **OD4-c stays UNDECIDED between option (i) and an accepted residual — the plan still does not pre-empt it.** Note the standing defect this row exposes: **SEVEN sites still assert the superseded claim** — §5.7's central-finding HEADLINE, its sequencing reason 1, its Recommendation, its "Break the motivation" reviewer attack, the surviving body of its struck bullet, §7.5's `V-P4M-1`, and one site OUTSIDE §5.7 entirely (§5's phase-chain preamble), plus §5.4's two OD4-c cross-references. §9.9 enumerates them — **and an EIGHTH carrier, found 2026-09-09: L-68's own "Invalidated by" cell, whose "Explicitly NOT reasons" list names OD4-c. It is the only carrier that corrects itself in place, and since L-124 its conclusion is right for a stronger reason, so §9.9 lists it apart rather than as work owed** |
| **L-94** | 2026-09-08 | ~~**OPEN (owner-level)**~~ **DECIDED 2026-09-09 by L-124** — do not bump while the anchor is an untagged branch head; the gate is a tagged OpenMLS | **From v0.9.5 the MDK workspace abandons crates.io OpenMLS for a PERSONAL FORK AT AN UNTAGGED BRANCH HEAD** — the head of a feature branch on a fork carrying no tags at all, force-pushable and deletable. CLAUDE.md's pinning rule exists precisely because a released tag is the only acceptable supply-chain anchor, so the bump transitively abandons that for the MLS implementation itself → §5.7 finding (3), blocker B1 | — (this is a finding, not an option) | It collides with Haven's own direct `openmls` dependency: Cargo does not unify a registry package with a git package, so the two would be **two MLS type universes**, and it splits the RustCrypto stack. Dissolves for the DIRECT dep if Haven deletes it; **does NOT dissolve for the transitive graph** | Upstream tagging the fork, or returning to a released OpenMLS. **This is an owner-level supply-chain decision, not an implementation detail, and it is arguably a harder blocker than the flag day** |
| **L-95** | 2026-09-08 | DECIDED — **plan spec overridden by the implementer** | **P2c reads `poolSubscriptionCount()`, not `isPaused`, and §5.4 specified `isPaused` twice.** It cannot carry the claim: the core raises `paused` as the FIRST statement of `pause_subscriptions`, before `unsubscribe_all`, before the router drain, before the uncapped Rule-13 gauge and before `disconnect()` — so it reads `true` through a pause that dropped no REQ, one still draining and one whose disconnect never happened: **every state P2c exists to catch.** It also reads `false` for a failed FFI read and for "there is no session" → §5.4 P4-7, §4 | `isPaused` as the oracle; answering `0` when there is no session — the new read THROWS instead, "because zero is the value the promise is kept by" | The pass-through is deliberately NOT on the `SubscriptionService` interface: no production caller decides anything from it, and the two callers that read `isPaused` must keep reading that | Paired with a **control arm** — the same counter read non-zero while foregrounded, before the backgrounding — so a counter that could only ever read zero cannot prove the promise for free. `check_ios_background_publish.sh` check 12 pins all four halves over a string-stripped view |
| **L-96** | 2026-09-08 | **CORRECTION** — plan claim withdrawn, re-declining L-111 | **The P2c oracle "no `#p` REQ between bursts" cannot be delivered by that lane and the claim is withdrawn.** The iOS lane runs `tooling/e2e/local-relay`, which journals no REQ/CLOSE frames — the recording wire proxy that would is started by the core-flow lanes, not by this one — and WS Ping/Pong is invisible to both → §5.4 | Restating the proxy in weaker words | **What P2c does NOT prove, stated because a green will be over-read otherwise: that no SOCKET is open between bursts.** The count is of subscriptions, not connections | The socket half stays where it already is: `live_sync_burst_e2e.rs`, on `relay_health()` |
| **L-97** | 2026-09-08 | ~~**OPEN**~~ **DECIDED 2026-09-09 by L-122** — recorded as **OD4-d**; the coverage is bought back and the leg ~~is in progress~~ **LANDED the same day** (L-126–L-130 are the decisions that landing took) | **`HAVEN_LIVE_SYNC` is flipped `false` → `true` on `e2e-ios-background-publish`.** Right — P2c cannot exist without the receive engine, and `true` is the shipped default; with the engine compiled out every burst's open failed and P2a/P2b were measuring a degenerate burst → §4 OD4-d, §5.4 | Absorbing the cost silently | **The cost is named rather than absorbed: no lane now puts the POLL configuration of the iOS background branch through a real OS backgrounding.** `OVERLAY_BUNDLE_ID` / `com.apple.Preferences` occur in this lane and nowhere else, and `e2e-ios` runs its poll variant FOREGROUNDED | **The owner's call, deliberately left open.** The costed option: a second matrix leg on `when-in-use` only with `HAVEN_LIVE_SYNC: "false"`, running P1/P2a/P2b/P3 and skipping P2c — one extra ~65-minute macOS job per run. A cheaper partial (a STATIC existence pin in check 6) is also **not taken unilaterally**, and must never be cited as runtime coverage |
| **L-98** | 2026-09-08 | **CORRECTION** — the compensating control did not exist | **The claim that "the poll path's own background receive timer is pinned by `check_ios_background_publish.sh` check 6" is FALSE, and it was the clause doing the work.** Check 6 pins the C4 disable-while-paused watcher plus a NEGATIVE about where that watcher may live, itself wrapped in a non-empty guard. **Mutation-tested: deleting `_startIosBackgroundReceiveTimer` entirely leaves check 6 passing** → §5.4, §4 OD4-d | Retaining any part of the sentence except its first and last clauses | **Nothing in the repo pins that the poll path's background receive timer exists, fires, or reaches `_runBackgroundCatchUp` → `runCatchup(isBackgroundWake: true)`** | The claim was named in **three carriers, and as of 2026-09-08 all three state the RETRACTION** (each re-read in the working tree): the lane's own "What this lane does NOT prove" header, §5.4's landed correction, and the drive target's library doc (`haven/integration_test/ios_bg_publish_test.dart`), which carries it in OD4-d's own terms — check 6 pins the C4 watcher plus a negative that is itself skipped when the method is absent, so deleting `_startIosBackgroundReceiveTimer` leaves the check green. **Nothing in the working tree contradicts itself on this point any more, and HEAD asserts nothing either way** — the whole P4-7 packet is uncommitted, so HEAD carries neither the claim nor the retraction. Both sentences that said the drive doc was "still to be retracted" — §4's OD4-d row and §5.4's own correction — were fixed in the same pass, so **no site in this plan now asserts either the claim or its incompleteness.** **The rule this establishes: a substitute justification inside the argument that licenses a coverage reduction is worse than the reduction** |
| **L-99** | 2026-09-08 | DECIDED | **The lane's `DISABLE_WAIT_SECS` re-derivation is redone, and 1440 s survives by ~5 %, not the ~37 % the first re-derivation claimed.** Two independent corrections: an awaited tick is bounded by `kPublishLinkTimeout` (180 s), not by `burstBound(1) + kOptOutBurstWait` (108 s) — "unpriceability is a good argument for a bound on an in-app wait and no argument at all for omitting a term from a CI wall clock"; and the P2c peer publish is ≤ 112 s, not ≤ 15 s. A third term was added drive-side the same day → §5.4 | Inflating the deadline: it is bounded from ABOVE as well as below, and the two bounds are ~100 s apart — a larger value is unreachable because the drive's own `Timeout` dies first, **which is the better red, because the drive's Timeout names the failing test and this deadline names nothing** | The sum is still not a worst case and cannot be made one (`_publishChain` has no enforced DEPTH). Exceeding the deadline is not a kill: the wrapper WARNs and falls through, so **undersizing costs attribution, never a false green** | The job cap goes 115 → **175** (155 could not hold by the lane header's own numbers, and a job-cap SIGKILL skips every `if: always()` diagnostic), and **new guard check 15** (`check_bg_publish_timeout_ladder`) reads the drive's `Timeout` and the workflow's `timeout_minutes` and refuses `attempt_min − drive_min < 22`. **It is ONE-DIRECTIONAL, and "refuses a raise of either alone" is half true:** it reds on a raise of the drive `Timeout` alone and on a CUT of `timeout_minutes` alone, but a RAISE of `timeout_minutes` alone widens the gap and stays green — the function bounds the ladder from below only and reads no step cap or job cap at all. 22 minutes of fixed overhead that was documented on both sides and enforced by nothing |
| **L-100** | 2026-09-08 | DECIDED (owner-taken) | **OD3 / P5(a) N-bound — option (a): cap circles per burst and defer the rest.** `kMaxCirclesPerBurst = 11`, **derived rather than chosen**: `n − 1 ≤ kPublishStaggerMaxSpread ÷ (kPublishStaggerMinGap + 1 s) = 30 ÷ 3 = 10`. What the cap buys is a bounded `maxSpreadFor`, so the burst's own span, the shared GPS fix and the overlap guard hold for **every** roster → §5.5, `kMaxCirclesPerBurst` | **Option (b) — deriving the per-gap floor from retention** — rejected because gaps below 2 s collapse the whole-second `created_at` separation that `PUB-COALESCE` exists to retain, which is the only defence the coalescing keeps | **This MOVES a wire-visible hole rather than closing it, and the constant's own doc says so.** ~~A deferred circle's realized gap is two sampled intervals — 144 s best, 336 s worst, mean 240 s~~ **CORRECTED 2026-09-08 against `_takeBurstSlice` as shipped: "two intervals" holds only to N = 22.** The slice is strict round-robin (`min(_rotation.length, 11)`, then rotate), so a circle's worst SERVICE PERIOD is `ceil(N ÷ 11)` bursts: **N = 12…22 → 2** (144 s best, 240 s mean, 336 s worst, and **366 s** once the burst-position differential is counted — a circle may lead one burst and trail the one two ticks later, a whole `kPublishStaggerMaxSpread` apart); **N = 23…33 → 3** (216 / 360 / 504 s); **N ≥ 34 → 4 or more**, where even the BEST case (288 s) exceeds the 228 s retention on EVERY publish rather than on some. **And there are TWO baselines.** Against an UNCAPPED coalesced burst the hole opened at `N ≥ 22` (`168 + 3 × 21 = 231 s`) and the cap moves it to `N = 12`. Against the ACTUAL predecessor — per-circle schedulers, where the gap was each circle's own sampled interval, ≤ 168 s at every roster, no spread and no deferral — **there was no hole at ANY roster size and the full 60 s of margin was intact, so this is a regression at every `N ≥ 12` with NO upper bound, and at every `N ≥ 2` in the propagation margin (60 s → 30 s)**. **ONE limit on that quotient, and the second one this column carried was RETIRED BY A FIX, not by a re-wording (2026-09-09).** ~~(1) `_rotation` is cleared by every `stopScheduling()`, so the service period is per CONTINUOUS RUN rather than absolute — a roster that stops and restarts re-phases whose turn it is instead of resuming it~~ — **both halves false since the resets were fixed at the source.** `_rotation` now outlives `stopScheduling()`/`startScheduling()` **and** outlives an emission reporting nothing eligible (`circlesProvider` degrades ANY roster-read failure to `[]`), so neither a backgrounding nor a failed roster read re-phases whose turn it is; the service period is ABSOLUTE. Three new tests hold it, all in `location_publish_scheduler_provider_test.dart`: `a deferred circle is not deferred again by every resume`, `a transient empty roster emission does not re-phase whose turn it is`, `a roster change keeps survivors' places in the queue`. What still rewinds the queue is `build()` — a fresh container, or the invalidate in `IdentityNotifier.deleteIdentity` — and a process restart, which does not persist it; and because the roster keeps `filterPublishEligibleCircles` order (`getVisibleCircles()` orders by `updated_at DESC`) a rewind returns to the SAME head and re-serves the SAME first slice, which is a deterministic re-service and not a re-phase. **And this column retired "unbounded" without ever stating what replaced it — supplied 2026-09-09, from the same wording its sibling row and §6.3's troubleshooting row already carry:** the tail's gap across a rewind is bounded by how often the app RESUMES, because the deliberately uncapped one-shot (`locationPublisherProvider`) fires on cold start, on motion, on accept/create and on **a resume more than 30 s after the last one** (`MapShell`'s resume debounce sits ABOVE its invalidate, so a glance inside that window triggers nothing) — and **from 21 circles that cover is a probability rather than a promise**, because the one-shot's own spread outlasts `kLocationPublishOverlapGuard`, so the next trigger's `invalidate` marks the burst in flight superseded and it stops where it stands, the replacement re-shuffling from the start. **A second thing the ABSOLUTE period does not say:** it is a period of TURNS, and a turn is a SELECTION rather than a publish — the rotation advances when the tick FIRES, ahead of the chain, the window and the sink — so a slice that loses its turn without publishing (a refused publish window, a pause under it, an iOS burst the coordinator drops) waits its whole period over again: one more burst at `N ≤ 11`, up to 336 s against the 228 s retention, and another `ceil(N ÷ 11)` past the cap. **Two costs of the rotation fix itself, recorded 2026-09-09 rather than discovered later.** (i) An ACCEPTED RESIDUAL: in the production-unreachable state — a rotation holding only circles nothing can publish — a tick driven there through the test seam advances the rotation before finding nothing publishable, so that tick spends a turn. Preserving the turn would need a partition-and-rotate loop written for a state no armed timer can reach, which is more machinery than the state is worth. (ii) A DISCLOSED COST: the transient-empty-emission branch keeps the rotation but still nulls `_scheduler`, so the next healthy emission samples a FRESH `[72, 168] s` interval — a transient roster-read failure therefore spends up to one whole interval of freshness even though it costs no turn. That bites hardest backgrounded on iOS, where every reachable `circlesProvider` invalidation rides an INBOUND PEER EVENT: the re-arm waits for a peer to publish. **The limit that remains is the only one:** the cap bounds what the SCHEDULER HANDS OVER, not what a background pass publishes — `BackgroundBurstCoordinator._publishPass` loops on `_pendingCircles()` while `_joinable` admits mid-burst ticks, so a second tick folding into a running burst publishes MORE than `kMaxCirclesPerBurst` in one pass — reachable only at `N ≥ 12`, i.e. already outside the roster this cap's arithmetic covers | **The ladder is now pinned in BOTH halves, and what this column used to name pins neither.** ~~Sweeping `n = 2..kMaxCirclesPerBurst` in `publish_stagger_test.dart`~~ names the CAP-DERIVATION tests there — `kMaxCirclesPerBurst is DERIVED from the spread budget and the per-gap floor, not chosen` and `the no-gap invariant holds across the WHOLE admissible range, with the disclosed propagation margin intact` — which are arithmetic on `maxSpreadFor`/`maxGapFor` and the three stagger constants, i.e. about ONE burst's spread and silent on how many bursts a circle waits. The period itself is behaviour: `a deferred circle waits ceil(N / kMaxCirclesPerBurst) bursts — the service-period ladder, not "two intervals" at every roster` (`location_publish_scheduler_provider_test.dart`) drives real ticks, records which burst served each circle, and asserts the max consecutive-service gap on BOTH sides of every rung (11, 12, 13, 22, 23, 24, 33, 34) with an anti-vacuity cardinality check — so it reddens if `_takeBurstSlice`'s size or its rotate moves. The seconds are `and past the cap, the deferral ladder in SECONDS — the figures the record quotes for a ceil(N / kMaxCirclesPerBurst) service period` (`publish_stagger_test.dart`), which reads 144/240/336, 366 with the differential, 216/360/504 and 288 off the cadence constants and pins the two retention crossings — so a cadence change is a visible edit here rather than a silent re-derivation that moves this prose away from its proof |
| **L-101** | 2026-09-08 | ~~**OPEN**~~ ~~**DECIDED 2026-09-09 by L-123**~~ **CLOSED 2026-09-09** — decided by L-123 and LANDED the same day (L-132); what outlives it is a different and much smaller residual | **CLOSED AT EVERY REACHABLE ROSTER, and every circle count in this row is now arithmetic about a roster the app REFUSES** — kept unstruck because it is exactly what lifting the bound re-opens, and because the sweeps still pin it. As written: **the coverage hole past eleven circles is STRUCTURAL and no arrangement of the publishes closes it:** `n` events more than `kPublishStaggerMinGap` (2 s) apart cannot fit inside the 60 s the retention leaves above the cadence ceiling once `n > 31`, i.e. from `n = 32`. **The `N ≥ 22` in L-100's Cost column is the SAME pigeonhole fact measured against a different gap floor** — the 3 s the burst actually paces to (`kPublishStaggerMinGap + 1 s`, which is also what L-100's cap derivation divides by) — so 22 and 32 are two readings of one arithmetic, not a correction of one another, and a reader who assumes one floor throughout will find the 31 off by one. **The 33 and 34 in L-100 are measured differently again and must not be conflated with either:** they come from the `ceil(N ÷ 11)` SERVICE PERIOD — how many bursts a circle waits — while 22, 31 and 32 are all about ONE burst's spread. The shipped sites carry that disambiguating clause; this row mirrors it. **Since 2026-09-09 all five of those numbers — 22, 31, 32, 33, 34 — describe rosters `kMaxCirclesPerAccount` (10) refuses, so the disambiguation is no longer about a live hole; it is about which arithmetic re-opens first if the bound is ever lifted, and a reader who mixes the two readings will re-derive the wrong one (L-132).** **Since 2026-09-08 the two readings also have two DIFFERENT proofs, which is what makes the disambiguation checkable rather than a claim about prose:** the service-period side is behaviour — `a deferred circle waits ceil(N / kMaxCirclesPerBurst) bursts` (`location_publish_scheduler_provider_test.dart`) drives real ticks over both sides of every rung, and `and past the cap, the deferral ladder in SECONDS` (`publish_stagger_test.dart`) quotes it in seconds — while THIS row's 22/31/32 stay with `kMaxCirclesPerBurst is DERIVED from the spread budget and the per-gap floor, not chosen` and `the no-gap invariant holds across the WHOLE admissible range` (`publish_stagger_test.dart`), which are spread arithmetic and say nothing about how many bursts a circle waits. **The ONE scope limit recorded on L-100 attaches to the SERVICE PERIOD only and not to this bound** (a second tick folding into a running iOS pass): the pigeonhole here is a property of one burst's spread, so a doubled pass does not relax it. L-100 carried a second limit — the rotation cleared by `stopScheduling()` — until 2026-09-09, when the resets were fixed at the source rather than re-worded; it attached to the service period too, so its removal leaves this bound exactly where it was. ~~**Nothing in the app bounds the roster.**~~ **FALSE SINCE 2026-09-09:** `kMaxCirclesPerAccount` (10) bounds it, refused in `NostrCircleService` at `createCircle` and `acceptInvitation`, so `n` never reaches 12 — let alone 22, 31, 32, 33 or 34 — and this hole is CLOSED rather than shrunk. Closing it needed a **roster bound** or a **longer retention** — both owner decisions, ~~neither taken~~ **and the ROSTER BOUND was TAKEN on 2026-09-09 (bounded at 10, one below the cap; L-123) and LANDED the same day (L-132), which closes this hole at every reachable roster instead of shrinking it; the retention alternative was rejected as worse privacy and a wire change**. **THE RESIDUAL THAT OUTLIVES THIS ROW, narrowed to what the bound genuinely does not close:** the propagation and clock-skew margin halved **60 s → 30 s at every `N ≥ 2`**, because the burst spread spends one of the two `kTtlNetworkBufferSeconds` the retention is built from. That 30 s is a worst-case BOUND and not the margin at every roster — the spread is `maxSpreadFor(n)`, so the margin is 51/42/33 s at n = 2/3/4 and 30 s only from five circles up. It is recorded in the `PUB-COALESCE` `ratchet_override` block, deliberately in the block for the change that caused it, and indexed as a standing accepted residual in §9.9** → `kMaxCirclesPerBurst` (**defined in `haven/lib/src/services/publish_stagger.dart`; `constants/location.dart` only QUOTES it**), §5.5 | Presenting the cap as a fix — it is a bound on the burst, not on the gap | ~~From the twelfth circle up, a deferral leaves a peer's marker expired at the relay for most interval pairs~~ — **unreachable since the bound landed. What remains is the 30 s of propagation and clock-skew margin the burst spread spends at every `N ≥ 2`, plus the whole deferral ladder staying in the tree as documentation of what lifting the bound would re-open** | ~~Either owner decision.~~ Both were priced here: a longer retention is a wire change (D0, L-02) and a roster bound is a product decision, which is exactly why neither was taken *here* — **and the bound was then taken on 2026-09-09 as exactly that product decision (L-123) and landed the same day (L-132), while the retention half was rejected rather than deferred.** What would re-open THIS row is the account bound being lifted or raised past `kMaxCirclesPerBurst`, or a burst-cap REDUCTION that pulls the first deferral back under the account bound — either makes every rung above live again, exactly as written |
| **L-102** | 2026-09-08 | DECIDED | **A burst re-arms every circle it published onto ONE due: `nextBurstDue` = `max(firstPublishStartedAt + interval, lastPublishStartedAt + minInterval)`** — one interval after the burst's FIRST publish started, floored at `kLocationPublishMinInterval` after its LAST publish **STARTED**. **Both terms anchor on a publish's START; no completion instant reaches the helper at all, so "after it FINISHED" — which this row said, and which `nextBurstDue`'s own doc comment still says — is exactly the clause a reader would code against and it is wrong** (the parameter is named `lastPublishStartedAt`; the source comment is another packet's to fix). Equal dues are not tidiness: `dueKeysUpTo` orders by due ascending, so distinct dues make the next burst's order a function of this burst's, the CSPRNG permutation becomes dead code after the first burst, and the whole-second delta between two circles climbs to a fixed value and prints it every burst — the constant delta the stagger exists to break → `nextBurstDue`, §5.5 | **Both single anchors, each now pinned as a dead mutant:** anchoring at the burst's **LAST** publish makes the circle that published FIRST wait `interval + spread` plus another spread inside the next burst — `168 + 30 + 30 = 228 s`, exactly the retention, breaking `INV-STAGGER-BOUND`; anchoring at the **FIRST** publish alone lets the circle that published LAST publish again `interval − spread` later — **42 s against the disclosed 72 s floor** | Two terms instead of one | **The floor is an FGS property.** Only the foreground service tracks a per-circle due; on the two TIMER-driven planes a circle that trails one burst and leads the next still publishes `I − spread` apart — 42 s at eleven circles. That is a battery and metadata cost, never a coverage one, and it is stated on `constants/location.dart` rather than hidden |
| **L-103** | 2026-09-08 | DECIDED — **a defect fixed outside its brief** | **The FGS burst deadline is anchored at the burst's FIRST PUBLISH, not at the cycle start** — in the planning pass and in the publish loop. The fix is deliberately taken outside P5's brief because it is **the actual cause of the roster split earlier reviews computed**: the fix is delivered `kBackgroundFixLeadTime` BEFORE the due it was taken for, so a deadline measured from the cycle start hands the burst only `30 − lead` seconds of its own budget and splits rosters that fit — **one wake per interval becoming two, on the plane whose wake count is the whole point** → `background_location_task.dart`, `publish_decorrelation_wiring_test.dart` | Leaving it: the split shape was 2.2 circles per cycle at n = 4 rising to 5.7 at n = 12 — 1.8–2.1 cycles per circle-interval and **54–63 wakes an hour instead of 30**. **Those figures are COMPUTED, not observed, and they are a COMMENT about the RETIRED per-circle-due configuration — this cell called them "measured" twice until 2026-09-09, contradicting the corrected attribution in `BACKGROUND_SHARING_FAILURE_ANALYSIS.md` Unit H.** `FgsModel` is test-only, sweeps `circles = 1..8`, and so cannot produce an `n = 12` figure at all; the live assertion is the opposite (`INV-COALESCE` requires every circle in every serving cycle, i.e. 1.00 cycles per circle-interval), and no cycle on any device or emulator was ever counted | A fix in a phase that did not scope it, recorded here so it is not read as scope creep | Pinned in both places by `the burst budget is anchored at the first PUBLISH, not at the cycle start`, and swept by `INV-COALESCE` — **whose reach is NARROWER than "every roster inside the budget", stated here rather than inherited, because an unearned "every" is the exact over-claim L-38 and L-55 police.** The sweep runs `circles 1..8` and stops there deliberately (its own comment says so: a 12-circle roster is cut whenever its sampled gaps reach the 30 s spread, and the deferred circle's realized gap then runs to ~310 s, past the retention). **That ~310 s is neither retired nor a contradiction of L-100's ladder, and must not be "corrected" against it** (recorded 2026-09-09): it is this MODEL's own figure at an unswept roster — driven at `circleCount: 12`, worst realized 311/314 s — and it disagrees with 336/366 s because it is a DIFFERENT MECHANISM. The FGS plane cuts on the burst's SPREAD (the 3 s per-gap floor needs 33 s at n = 12, so the cycle drops what will not fit its 30 s budget) and re-serves on the NEXT DELIVERY, whereas a timer-driven burst defers a whole slice for `ceil(N ÷ 11)` bursts. Neither figure may be used to correct the other; the test file's own comment carries the same disambiguation. The `INV-COALESCE` assertion is additionally gated on `!early`, so the foreign-early-fix arm is covered by the other invariants of that sweep and not by this one. **Rosters 9–11 are inside `kMaxCirclesPerBurst` and unswept — that is the gap.** Within 1..8 and `!early` it IS exact at every API regime, TTFF and gate delay, at 1.00 cycles per circle-interval |
| **L-104** | 2026-09-08 | DECIDED | **FIVE groups of host assertions are REVERSED by coalescing, and the reversals are recorded so they do not read as coverage quietly dropped:** `one independent scheduler per eligible circle` → `one scheduler publishes every eligible circle per tick`; `a per-circle tick publishes ONLY that circle` → deleted, its promise reversed by OD3; `two circles seeded together get independent, decorrelated phases` → `a burst re-arms every circle it published onto ONE due`; **the three manifest-cited `publish_decorrelation_wiring_test.dart` tests are REPLACED IN PLACE, never deleted first** (so the manifest never cites a name that does not exist — rule 3 makes the `tests[]` edit ride the same commit); and `location_publish_decorrelation_test.dart`'s **"never concurrent across INDEPENDENT timers" premises are DROPPED**, while its `greaterThan(1000)` CSPRNG and order-varies assertions are kept → §5.5 "Tests FIRST" | Keeping the old names over new bodies — the promise changed, so the name must | Every assertion that survives the reversal was kept: `encryptConcurrencyPeak == 1`, the `greaterThan(1000)` CSPRNG checks and the order-varies checks are the `created_at` defence and are untouched. **The whole-second-delta test was NOT untouched, and P5a-2 is where that surfaced:** it is renamed `…, at the DEFAULT burst size of two`, because eight distinct values was only ever true at `totalPublishes = 2`, and two tests were added beside it — `expected whole-second delta alphabet, swept over every burst size the app admits` and `the per-gap ceiling is the priced table, for every burst size` | **The manifest HAS caught up — re-verified against the working tree, 2026-09-08.** `INV-R-PER-CIRCLE-PUBLISH-DECORRELATED` is `accepted_deviation` carrying `accepted_deviation_id: "PUB-COALESCE"`, retitled *"One burst publishes every eligible circle; only the CSPRNG stagger keeps their created_at stamps apart"*, and its `tests[]` cites EIGHT tests, **all of which exist** — including the two `publish_decorrelation_wiring_test.dart` names an earlier pass of this ledger reported as gone. They were never gone: Dart splits a long test name across adjacent string literals, so a whole-string grep reports a live citation as dead. **Join the literals before concluding a citation has rotted.** P5a-2's manifest half is LANDED, not OWED. What would invalidate the reversal now: a `tests[]` entry that stops resolving, or a re-upgrade to `enforced` without restoring per-circle schedules |
| **L-105** | 2026-09-08 | DECIDED | **The privacy manifest's anti-vacuity floors are re-pinned at `floor(0.9 × measured)` across all six counts.** "~90 % is a rule, not a slogan, and it has to be RE-APPLIED as the manifest grows or the header stops describing the constants under it". **And the rule is ALREADY broken again in two of the six — measured against the working tree on 2026-09-08, not against the index that carried the re-pin.** `count_metrics` yields **91 / 65 / 15 / 22 / 284 / 29** against floors **81 / 58 / 13 / 19 / 250 / 25**: `FLOOR_TESTS` needs 255 and `FLOOR_DOC_REFS` needs 26, because the manifest grew inside the same uncommitted edit that re-pinned them. The rule's own failure mode arriving inside the commit that states it is the strongest possible argument for it → `count_metrics`, `check_floors`, `scripts/ci/check_privacy_invariants.sh` | Leaving them: the TEST floor had drifted far below the rule — **and by MORE than this row first said. The "67 % / 89 citations of slack" it carried (and the guard's own header still carries) is arithmetically consistent only with a measured 269; the tree measures 284, so against the pre-repin `FLOOR_TESTS=180` the real drift is 63.4 % of measured and 104 citations of slack** — better than a third of the register could have been de-cited with the gate still green. The ARB-key floor was at 74 % (48/65) and the doc-ref floor at 76 % (22/29), not the 79 % the header states | A legitimate removal costs one extra override line | The one lowering on record is the ARB-key floor, 119 → 48 — **and the date is 2026-08-30, in `1da5234` ("ops: remove the privacy information page for now"), not 2026-08-29: both `2594821` and `f786356` still carry `FLOOR_ARB_KEYS=119`.** It rode the owner's deletion of the 85 `privacy*` strings (L-30); the invariants those strings hung off are all still there. **Raise them with the manifest; never lower one to make a diff green** |
| **L-106** | 2026-09-08 | DECIDED | **A guard citation was disproved by mutation: `check_ios_background_publish.sh` stays GREEN with both socket-closing links deleted from `_closeBurst`.** The guard pins `pauseSubscriptions` and `shutdownPublishPool` in `releaseBurstPlaneOnOptOut`'s body — the C4 opt-out path — and reads nothing in the coordinator's own teardown → `check_c4_optout_release`, `BackgroundBurstCoordinator._closeBurst` | Citing the guard for the teardown | **The teardown's ordering and unconditional-ness are held by behavioural Dart tests alone.** That is not weaker in kind — the guard's own comment says the runner question is behavioural — but the CITATION was wrong, and a wrong citation is what stops the next person looking | Extending the guard to `_closeBurst`, or citing the behavioural tests instead. Until then, no document may say the burst teardown's socket close is guard-pinned |
| **L-119** | 2026-09-08 | DECIDED — **the P6-B′ estimate-integrity sweep** | **Every energy figure in the tree now names what produced it, at the site where it is read.** Three classes were separated and each is treated differently forever: a **third-party published figure** (Karki & Won's 60–85 mA, OwnTracks' 25 %/day, Evgenii's tier costs, the LTE-2012 joules) keeps its citation and is never called a measurement of Haven — §1.1 now says so for its whole "Why it costs" column, and §2.3 says it for every joule figure downstream of the wake model; a **model-E output** (%/h, GNSS duty, profile duty) carries **ESTIMATED** in its own sentence — added at §3 D1 (vii), §5.3's goal, §5.4's goal, `constants/location.dart`'s two profile-duty comments and `ios_location_source_test.dart`; a **figure that is neither** is retracted rather than softened → §5.6 P6-B′ | Leaving the tag to section context. A reader lands on one sentence, not on a section, which is why the rule is *same sentence* and why the sweep exists at all | Two retractions and one re-tag: §5.4's "≈ 3.1 %/h → ≈ 0.65 %/h" was the `c = 1` endpoint of a range restated as a result (now ≈ 0.5–3.1 → ≈ 0.1–0.6 %/h, radio term only); the **≤ 188 s post-P2a liveness bound** is retired from `POWER_MEASUREMENT.md` §3.5/§3.6/§7, the grader's header and §5.6's reviewer checklist, because §6.5 retracted it on 2026-09-04 and D3 (iii)'s accepted cold residual reaches 248 s on API 23–30; and `POWER_MEASUREMENT.md`'s deferral banner named only the missing macOS machine and iPhone while §2.5 also records no Android handset | A measurement. The day one exists, §6.5's protocol runs and its value REPLACES the estimate at every site this sweep tagged — the tags are the index of what has to be revisited |

### 9.7a 2026-09-09 — the five owner decisions that emptied §4's open list

Five decisions taken in one sitting, and they are grouped here because they were taken together rather than because
they belong to one phase: two close §4's only open rows (OD4-c, OD4-d), one closes the roster question P5(a) opened,
one answers the MDK survey's supply-chain finding, and one settles a merge-gate threshold that had been
cross-referenced but never decided. **Three of the five were decided-and-unbuilt when this was written, which is a state this ledger
has a word for (`OWED`), and it is the state to watch: a decision written up as though it were a control is the same
error class as a guard claim nobody exercised (L-98, L-106) — the silence it was taken to end is still there until
the code is.** **OD4-d is no longer one of them: its leg LANDED on 2026-09-09, and the five decisions that landing
itself took are §9.7b's L-126–L-130. Nor is the roster bound — it landed the same day too, and its landing row is
§9.7d's L-132, which exists mainly to record that its first check was ADVISORY UNDER CONCURRENCY and that a review is
what turned it into a bound. ~~L-121 is the only one of the three still owed.~~ **Nor, since the same day, is L-121:
its RUST half landed too, and the row for that landing — including the fact that fixed its shape — is §9.7e's L-133.
~~What is still owed of L-121 is the ONE half of it a user could see, (i)'s Dart consumer, so the pattern this paragraph
warns about survives in its narrowest form: the mechanism exists, the silence does not end until something reads
it.~~ **NOTHING of L-121 is owed as of the same day: (i)'s Dart consumer landed too, and its row is §9.7f's L-134. So
all five of this sitting's decisions are built, and the pattern this paragraph warns about was closed the way it says
it has to be — by code, not by a write-up.**
`L-120` also carries this date and sits in §9.10 for the reason that subsection gives: it is a finding about the ledger,
not a decision the phases took.

| # | Date | Status | Decision | Rejected — and why | Cost | Invalidated by |
|---|---|---|---|---|---|---|
| **L-121** | 2026-09-09 | **DECIDED** (owner) — ~~and **OWED**~~ ~~**RUST half LANDED 2026-09-09 (L-133); (i)'s Dart consumer still OWED**~~ **FULLY LANDED 2026-09-09: Rust half L-133, (i)'s Dart consumer L-134** | **OD4-c is TAKEN, and it is BOTH halves: option (iv) AND option (i).** **(iv)** keep removal-bearing auto-commits OUT of background bursts, which removes the route every burst can hit — the peer `SelfRemove` auto-commit `resolve_publish_work` stages inside a burst, i.e. mechanism (b), the removal-bearing case hydrate never emits `PendingCommitRecovered` for because it short-circuits on `staged_removes_member`. **(i)** detect the stuck state that survives (iv), surface it as a `GroupUnrecoverable`-class status and force a re-invite. **(i) is not optional, and the reason is the pillar order rather than taste:** for a location-sharing app a user who believes they are sharing and is not is a **safety** failure, not a UX one — the wedge is SILENT, indistinguishable from "my friend stopped sharing", and silence is the worse half → §4 OD4-c, §5.4 | **(iii) accept it as a bare residual — EXPLICITLY REJECTED**, and it was the standing alternative: it is the option that keeps the silence, which is the FA wedge class this whole plan exists to end. **(iv) alone** — it closes the route a background burst opens and nothing else, so mechanism (a) (a Haven-authored commit re-fetched as `Stale { OwnEcho }` off its durable `MessageState::Sent` row) still wedges a group, still silently. **(i) alone** — detection on a path (iv) can remove outright, i.e. treating the symptom while every burst keeps opening the window. **(ii)** was already dead and is not this row's business (the bump route is L-124's) | ~~**A DECIDED CONTROL THAT DOES NOT EXIST YET, and no phase may report OD4-c as closed.**~~ ~~**THE RUST HALF EXISTS AS OF 2026-09-09 (L-133), and no phase may report OD4-c as closed while (i)'s Dart consumer does not: the verdict is emitted and nothing reads it, so the SILENCE this row calls a safety failure has not ended.**~~ **BOTH HALVES EXIST AS OF 2026-09-09 — Rust in L-133, (i)'s Dart consumer in L-134 — so the SILENCE this row calls a safety failure HAS ended and OD4-c no longer holds P4 open. The cost that replaced it is an announcement delayed to the SECOND foreground open, which is also the first moment the repair is possible.** (iv) takes a departing peer's removal commit out of the background, so the epoch advance waits for a foreground pass — slower leaves on a device that is rarely foregrounded — and it must not open a Rule-13 hole where it removes the publish. (i) costs the affected circle a re-invite and needs a user-visible surface with its copy round. Neither half has a test today and the Rule-13 source gate stays green through both, so **nothing reddens to remind us until they land with their own tests** | Evidence that the wedge is UNREACHABLE at the shipped pin `e391adc` — a reading of `do_ingest`'s recorded-outcome-first order, or of hydrate's `staged_removes_member` short-circuit, that finds recovery where L-65 found none. Or an upstream fix landing INSIDE the five pinned crates **without the flag-day cost**: v0.9.5's durable outbound-fanout resumption is exactly such a fix and does **not** qualify, because at v0.9.5 the strict profile cutover, the unconditional `retire_non_current_key_packages()` sweep and nine forward-only migrations are already paid in full (L-93) — and since the same day the untagged-OpenMLS gate sits in front of it too (L-124) |
| **L-122** | 2026-09-09 | **DECIDED** (owner) — ~~and **OWED** (in progress this session)~~ **and LANDED 2026-09-09, the same day** | **OD4-d is TAKEN: buy the coverage back.** A second `e2e-ios-background-publish` matrix leg on **`when-in-use` only**, `HAVEN_LIVE_SYNC: "false"`, running P1/P2a/P2b/P3 and ~~**skipping P2c**~~ **— as it landed, running P2d where the live-sync legs run P2c, a compile-time BRANCH rather than a skip (L-128)** (which has no session to read with the receive engine compiled out). **Why:** the poll path is a SHIPPED ROLLBACK configuration with its own distinct background branch — a 90 s `Timer.periodic` → `runCatchup(isBackgroundWake: true)`, not the burst coordinator — and its failure mode is **silent sharing loss**, the worst possible thing to discover while reaching for a rollback during an incident → §4 OD4-d, §5.4 | **Accept the gap** — the residual L-97 costed: the branch would ship with host tests and the foregrounded core-flow lane only, and a rollback would be taken on faith. **The cheaper partial as a SUBSTITUTE** — a static existence pin in check 6 — rejected in that role and not as an addition: it is structure, not runtime coverage, and L-98 is the record of what happens when structure is cited as coverage | ~~**One extra ~65-minute macOS job per run of the lane.**~~ **~62 minutes as it landed** — 65 was the live-sync per-attempt deadline, and the poll leg's drive `Timeout` is 37 min rather than 40 (L-129). And the leg proves less than its live-sync sibling by construction: with no P2c it says nothing about subscriptions between bursts on the poll path, which its own "does NOT prove" header has to say — **and by the same construction it proves one thing they cannot, which is why the ceiling is stated on both sides** | The poll configuration ceasing to be reachable in a release build — the day `HAVEN_LIVE_SYNC=false` stops being a shipped rollback path, this leg tests a configuration nobody can select. **What does NOT invalidate it:** the retracted "check 6 compensates" claim (L-98, mutation-disproved and now retracted in all three carriers) — that retraction is why the decision was needed, never an argument against it |
| **L-123** | 2026-09-09 | **DECIDED** (owner) — ~~and **OWED** (in progress this session)~~ **and LANDED 2026-09-09, the same day; how it landed, and what the review of it changed, is §9.7d's L-132** | **The account's circle roster is BOUND AT 10 circles.** **The argument is the trilemma, not a one-liner:** a wide whole-second delta alphabet, no retention hole, and large rosters are **mutually exclusive**, because the 30 s burst-spread budget comes out of the retention margin and the burst's *n − 1* gaps must fit inside it. A deferred circle's gap is two sampled intervals — 144 s best, **240 s mean**, 336 s worst — against the **228 s** retention, so most deferrals leave a peer's marker expired, and it worsens to three intervals at 23–33 circles and four or more from 34. Bounding at 10 means **no circle is ever deferred**, so the hole disappears at every reachable roster, with **one circle of headroom** below `kMaxCirclesPerBurst = 11` — which is why 10 and not 11. As it lands the constant is `kMaxCirclesPerAccount` and the refusal is a typed `CircleRosterFullException` raised in `NostrCircleService` at `createCircle` and `acceptInvitation`, the only two calls that grow a roster, counting ACCEPTED memberships and failing CLOSED → §4 OD5-a, §5.5, `kMaxCirclesPerAccount`, L-100, L-101 | **Lowering the burst cap instead** — it widens the delta alphabet but makes deferral, and therefore the hole, start EARLIER, i.e. it buys the weaker guarantee at a higher price. **Lengthening `LOCATION_MESSAGE_RETENTION_SECS`** — events then live longer on relays, which is worse privacy, and it is a wire change D0 forbids (L-02). **Accepting the hole** — a silent coverage failure a peer experiences as "their location stopped updating", which is the class this plan exists to end | **A NEW user-visible limit: an eleventh circle is REFUSED**, with the refusal copy and its 13 locales. And the alphabet still thins with the user's own roster — `{2…9}` at four circles or fewer down to `{2,3,4}` at ten — which is disclosed rather than hidden. `kMaxCirclesPerBurst` stays 11, so the cap-literal `{2,3}` assertion in the burst-size sweep now pins a size production cannot reach: deliberate headroom, and the sweep keeps it | A change that **decouples the burst spread from the retention margin** — the trilemma dissolves with it and 10 stops being derived from anything. Or **evidence that real users routinely exceed ten circles**, at which point the bound is the wrong horn and the retention question reopens as a wire decision (D0, L-02) rather than a product one |
| **L-124** | 2026-09-09 | **DECIDED** (owner) — a **"not yet"** with a named gate | **DO NOT bump MDK while it depends on an untagged personal fork of OpenMLS.** From v0.9.5 the MDK workspace replaces crates.io OpenMLS with `git = "https://github.com/erskingardner/openmls.git", rev = "59e7d3b2…"` — the head of `refs/heads/codex/reject-app-data-trailing-bytes` on a fork carrying **no tags at all**, force-pushable and deletable. For a cryptographic application, taking an untagged branch head as the supply-chain anchor **for the MLS implementation itself** outweighs the four wedges the bump would fix, and it contradicts the project's own rule that a released tag is the only acceptable supply-chain anchor. **The action is to raise it upstream and ask for a tagged OpenMLS** → §4 OD-P4M-1, §5.7 finding (3) and blocker B1, L-94 | **Taking the bump now — and the rejection is NOT a claim that it buys nothing.** It would fix **OD4-c** (v0.9.5's durable outbound-fanout resumption, inside four crates Haven already pins — L-93), the **sender-ratchet reorder** wedge (v0.9.11), the **Rule-12 no-eviction caveat CLAUDE.md itself records** (v0.9.11's bounded convergence retention), and the iOS **`0xdead10cc`** SIGKILL class (v0.9.11's explicit storage close). All four are real; none outweighs the anchor. Also rejected: **repointing Haven's own direct `openmls` at the same fork** to dissolve blocker B1 — that buys a compile and keeps the anchor | **The four wedges stay unfixed at `e391adc`**, which makes L-121's Haven-side control load-bearing rather than belt-and-braces, and `rotation.rs` (~1,500 lines) plus the convergence send-gate re-implementation stay ours. Nothing about the flag day gets cheaper by waiting | **The gate: a TAGGED OpenMLS dependency in the MDK workspace** — a released tag, not a branch head. Re-check that one fact instead of re-deriving the survey. Per §5.7's revisit conditions a security fix landing in a pinned crate reverses the calculation immediately, but it does **not** clear this gate by itself: it sends the call back to the owner rather than either side being assumed |
| **L-125** | 2026-09-09 | **DECIDED** (owner) | **P2b's forced-idle merge gate holds 228 s: D3 (iii)'s accepted 248 s residual (API 23–30, cold acquisition) does NOT extend to it.** Forced idle is the scenario that gate exists to catch, so a real device that cannot meet 228 s there has produced a **finding to FILE**, not a threshold to relax — loosening a merge gate to accommodate untested platform behaviour is how a real regression ships. The 248 s residual is unchanged where it was accepted, on an ordinary acceptance row for that API regime → §4 OD-P2-4, §5.2 un-park condition, §6.6 | **Extending the residual to this gate for consistency with the acceptance row two lines below it in `POWER_MEASUREMENT.md` §7** — consistency is the wrong axis: the residual was accepted for the shipped build's ordinary cold path (L-50), and it was never evidence about a suspended AP, which is the state this gate is about | P2b, already **PARKED** (L-33), un-parks against the tighter of the two bounds, so a handset that misses 228 s under forced idle keeps it parked on a finding instead of merging on a relaxed gate. **That is the intended direction, not a side effect** | A device run under `dumpsys deviceidle force-idle` showing 228 s unmeetable for a reason D3's residual already covers — which is a finding to record and re-derive, moving the number by an argument rather than by convenience. **Row history, because it matters to a reader who finds two numbers:** this was cross-referenced-but-undecided in `POWER_MEASUREMENT.md` §7 until today; that cell now states the 228 s gate and scopes the residual to the ordinary cold path, so no site still calls the question open |

### 9.7b 2026-09-09 — the five decisions OD4-d's implementation itself took

L-122 is the OWNER's row: it names a leg and says why one job is worth it. Building that leg forced five further
choices the decision did not settle, and each is a place a later reader would otherwise re-derive — or, worse,
"simplify" back. They sit in their own subsection for the reason §9.4 keeps a phase's decision apart from how it
landed: mixing the two makes it impossible to tell which was the owner's call. All five are DECIDED **and built** —
the leg is in the tree, and every number below was read out of it rather than out of the packet's own report.

| # | Date | Status | Decision | Rejected — and why | Cost | Invalidated by |
|---|---|---|---|---|---|---|
| **L-126** | 2026-09-09 | **DECIDED** — and built | **The lane's three legs are explicit `include:` entries over two axes, and there is deliberately NO `(always, poll)` leg.** `leg` — `when-in-use-live-sync`, `always-live-sync`, `when-in-use-poll` — replaces `tier` as the per-job identity: job name, cargo cache key and failure-artifact name. The poll leg's subject is the receive PLANE, which is orthogonal to the grant, so the shipped receive path is measured by two legs and the flag-off rollback path by one → §4 OD4-d, §5.4 | **The full 2×2 cross.** A fourth ~62-minute macOS job would only re-read a tier policy the always-live-sync leg already proves, on the runner class this repo pays most for. **Keeping `tier` as the job identity** — it stopped being unique the moment a second When-In-Use leg existed, and two jobs sharing a cache key and an artifact name is an error on the upload rather than a warning | **The `(always, poll)` combination is untested.** A regression that appears only when the confirmed-Always posture meets a build with no receive engine would not be seen here, and nothing else in the repo produces that pair under a real backgrounding | Any code that makes the tier posture READ the compiled receive plane, or the reverse. The two are independent today — the native session handler decides on the grant, the receive plane is a compile-time flag — and the moment one consults the other the fourth leg stops being redundant |
| **L-127** | 2026-09-09 | **DECIDED** — and built | **The completion gate demands four SHARED proofs plus exactly one per axis, each REFUSED on the legs that must not produce it — so the poll leg's set is FIVE, not the four the decision's "skip P2c" implied.** `BACKGROUND_CATCHUP_OK` stands where `BACKGROUND_RECEIVE_OK` stands on a live-sync leg, and `ALWAYS_SESSION_OK` is demanded only under the Always tier. A drive that exits 0 over a skipped or early-returning body fails the lane, and so does a run whose grant, compiled tier and compiled receive plane do not all describe one leg → §4 OD4-d, §5.4 | **Four proofs — what the decision's "skip P2c" implied**, on the assumption that the poll leg would have no receive phase at all. P2d landed as a REAL phase, so four would have made its early return invisible: the leg would go green having published for the whole window and never asked whether the background receive timer fired — the only reason the leg exists. **A count-based gate of any size** — fixture PF3 is the one no count can see, the live-sync leg's own passing log read as the poll leg, five proofs present and the wrong plane proved | Two receive-plane markers to keep in step with two planes instead of one, and a gate that has to be told which leg it is grading — so an unrecognised tier or an unrecognised live-sync value has to fail CLOSED (fixtures A4, PF5) rather than fall back to the smaller demand | A poll receive phase that legitimately cannot print a terminal proof: if P2d were replaced by something with no observable side effect, the fifth demand would red a correct run. Adding a phase does not invalidate this — it adds a proof |
| **L-128** | 2026-09-09 | **DECIDED** — and built | **The drive BRANCHES at compile time rather than skipping: `if (liveSyncEnabled) { P2c } else { P2d }`.** Exactly one of the two runs, neither is ever skipped, and no undeclared-skip manifest row was needed. P2c's foreground control arm became two-armed with it: `poolSubscriptionCount()` must read non-zero on a live-sync leg — otherwise P2c's between-bursts zero is free — and must **THROW** on the poll leg, because a session-less read deliberately never answers 0. That throw is the observable statement of WHY P2c cannot exist there → §4 OD4-d, §5.4 | **Skipping P2c**, which is how the decision was costed. A skip has to be DECLARED to the undeclared-skip gate, and it leaves the leg's identity unasserted: a build whose `--dart-define` and whose `HAVEN_LIVE_SYNC` came apart would run every other assertion identically and quietly measure the burst plane. **Relaxing the throw to accept a live session** — rejected permanently, not merely now, because the assertion is the identity | The poll leg carries an assertion whose PASS is an exception, which reads oddly to anyone meeting it first and needs its own paragraph to explain. It is also a tripwire on a PRODUCT path rather than on the lane: it reds if anything starts an engine in a flag-off build | `poolSubscriptionCount()` learning to answer 0 for a session-less engine. The read would then pass on both planes, stop telling them apart, and the leg-identity assertion would have to move to something else |
| **L-129** | 2026-09-09 | **DECIDED** — and built | **P2d's catch-up window is 215 s — two 90 s ticks plus the sweep's own 20 s deadline plus 15 s of relay slack — and the SECOND tick is a race fix, not slack.** A sweep whose window opened in the same whole second the peer's event was stored can miss that event and still advance the group cursor to that second, because the advance anchor is the local clock read BEFORE the REQ goes out; nothing recovers it inside that sweep. The next one does: every group re-read starts `GROUP_RESUBSCRIBE_BUFFER_SECS` (60 s) below the cursor, two orders of magnitude more than the one second at risk → §5.4 | **A one-tick window.** One second at risk in a 90 s interval is a roughly 1-in-90 failure, which presents as a FLAKE and not as a red: it covers the ordinary interleaving and fails only on the one the second tick exists for. **Retrying the peer's publish** so the sweep is bound to see it — that replaces the mechanism under test with the drive's own retry, and the timer IS the subject | 215 s is P2d's largest single term, and it is what makes the poll leg's arithmetic its own rather than inherited: `DISABLE_WAIT_POLL_SECS` is 1310 s against the live-sync legs' 1440, and the drive's `Timeout` is 37 min rather than 40 (P2d 362 s against P2c's 490) | A cursor advance that anchors on the newest event actually READ rather than on a pre-REQ clock read — the same-second loss becomes impossible then and one tick would do. Nothing about the 90 s cadence itself invalidates it; that is check 16's business (L-130) |
| **L-130** | 2026-09-09 | **DECIDED** — and built | **Check 16, `check_poll_path_receive_cadence`, pins `map_shell.dart`'s `Timer.periodic(const Duration(seconds: 90))` to the drive's `_pollPathReceiveInterval`** — slicing the method by its DECLARATION and not by its name, because the name occurs at two earlier call sites and anchoring on the first match is exactly how check 6's negative ended up asserted about the pause branch instead. It fails CLOSED when the method is gone, and says to remove the leg and the check in the same commit → §4 OD4-d, §5.4 | **A comment tying the two numbers**, and the failure mode is the whole argument: a cadence raised in the product and not in the drive leaves P2d's window spanning ONE tick where its derivation needs two, which is a flake and not a red (L-129) — the lane would have to hit the same-second race to notice, and nothing else in the repo compares the two numbers. **Exporting the cadence so the drive could import it** was not available: the 90 is an inline literal, and this guard stands in for the import | A guard pinned to a literal: a legitimate cadence change breaks it for the right reason and a refactor of the timer's SHAPE breaks it for the wrong one, which is why both `lfail`s name what to re-point. One more numbered check on a script whose self-test set grew in the same packet — by how much is a question for `SELF_TEST_FIXTURES` in `check_ios_background_publish.sh` and not for this cell: the two generations of the figure this ledger did carry (163, then 177) were each stale within a day, which is §9.9's fixture-count rule proving itself on the row that raised the count | The cadence becoming an exported constant the drive imports. The guard is redundant then and should be DELETED rather than kept as decoration — a pin that no longer pins anything is the same class of claim L-98 caught from the other direction |

### 9.7c 2026-09-09 — the flag-off engine start OD4-d's packet surfaced, reviewed and fixed

One row, and it sits apart from §9.7b for the reason that subsection's own intro gives: L-126–L-130 are choices
**building the leg** forced, while this is a PRODUCT defect the leg's control arm caught on its way past. §9.9 had
carried it as an open question that "deliberately takes no side" pending a review; the review reported, so the row
records the outcome and — the part a later reader would otherwise re-derive — why the fix went somewhere the
question did not predict.

| # | Date | Status | Decision | Rejected — and why | Cost | Invalidated by |
|---|---|---|---|---|---|---|
| **L-131** | 2026-09-09 | **CORRECTION** — and fixed | **A flag-off build DID start a live-sync engine, and the gate landed at the shared door: `if (!liveSyncEnabled) return;` as the first statement of `MapShell._healLiveSyncIfStopped`.** Two callers reached that method without consulting the flag — `_onResumed`, deliberately ahead of its own debounce, and `_restartReceiveAfterPausedStop` from the R1 consent edge, which can run in a PAUSED process — so any `resumed` dispatch (app switch, shade pull, lock-screen check) built a `LiveSyncResubscriber` and started a session in the one build whose whole promise is that it never does. The door is provably single: `.ensureRunning()` occurs exactly once in the shell, inside that method → §9.9, L-128 | **A re-read of the flag at the two entry points**, which is what §9.9's open entry predicted and what a minimal diff suggests. Rejected because it gates the CALLERS and not the STATE — L-43's lesson, and the heal already has four callers: the next one added would rediscover this defect, and a reviewer reading either call site would see a gate and stop looking. **Gating `_installLiveSync` instead** — that is one statement lower than the install, so the flag-off build still pays for the re-subscriber and the `circlesProvider` listener | The gate is invisible at the call sites, so a reader at `_onResumed` sees an unconditional heal and must follow it one hop to learn the build matters. Paid down by the doc comment on the method, which states the gate and names both unconditional callers | `poolSubscriptionCount()` learning to answer 0 for a session-less engine, which is the same observation that invalidates L-128 — the poll leg's throwing arm is the runtime detector for this defect returning, and the two host tests in `map_shell_receive_recovery_test.dart` are the static one. A behavioural host test is NOT available: `liveSyncEnabled` is a `const bool.fromEnvironment`, and `MapShell` reaches the Rust bridge in `initState` and cannot be pumped (CLAUDE.md) |

### 9.7d 2026-09-09 — the roster bound as it landed, and what the review of it changed

L-123 is the OWNER's row: bound the roster at ten, and why ten. This row is how that bound reached the tree, and it is
here rather than folded into L-123 for the reason §9.4 keeps a phase's decision apart from how it landed — plus one
specific thing a future reader needs and a decision row never carries: **the first implementation of this bound did not
hold, and a review is what found that out.** A bound whose check is advisory is worse than a documented absence of one,
because every document downstream then reasons from a guarantee that is not there.

| # | Date | Status | Decision | Rejected — and why | Cost | Invalidated by |
|---|---|---|---|---|---|---|
| **L-132** | 2026-09-09 | **DECIDED** — built, then hardened by review | **The roster bound as it actually LANDED: `kMaxCirclesPerAccount = 10`, refused at both roster-growing seams, and `INV-W-445-EXPIRATION-WINDOW` back at `enforced` with its override item deleted.** **DERIVED, not chosen:** `10 < kMaxCirclesPerBurst` (11) ⇒ every publish-eligible circle fits ONE burst ⇒ no circle is ever deferred ⇒ the `ceil(N ÷ kMaxCirclesPerBurst)` service-period ladder is unreachable in production, and a deferral would now begin at TWELVE. The constant sits beside `kMaxCirclesPerBurst` in `publish_stagger.dart`; `_refuseIfRosterFull` in `NostrCircleService` gates `createCircle` and `acceptInvitation` — the only two calls that grow a roster — throwing a typed `CircleRosterFullException`, counting ACCEPTED memberships only and failing CLOSED on a roster read that throws. **The part a future reader needs most: as first written the bound was ADVISORY UNDER CONCURRENCY, and the review is what made it a bound.** The gate read the roster and returned before either caller had written a row, so two growths in flight at nine held circles each saw nine and each proceeded — past the bound, with no error anywhere. It now takes an in-flight RESERVATION (`_reservedRosterSlots`) before returning, released on success and on failure and deliberately NOT on a refusal (a refusal reserves nothing, so releasing there would drive the count negative and admit the next attempt at the bound). The same review found the AST inventory guard blind in three ways — cascade sections carry no `target` of their own, a tear-off never appears as a `MethodInvocation`, and `lib/main.dart` sits outside `lib/src` — all three fixed. **Manifest half:** `INV-W-445-EXPIRATION-WINDOW` STAYS `enforced`, the rank it already carried at the base ref, and `INV-W-445-EXPIRATION-WINDOW.status` was DELETED from `ratchet_override.items`, leaving **EIGHT** items; the entry states more and proves more at the same rank, which needs no override at all → §4 OD5-a, §5.5, L-101, L-123 | **A longer `LOCATION_MESSAGE_RETENTION_SECS`** — the other horn of L-101's trilemma, and rejected twice over: it is a WIRE change D0 forbids (L-02), and it buys coverage by leaving location ciphertext on relays LONGER, i.e. worse privacy for better liveness, which is the wrong direction for this app. **The do-nothing residual** — accept the hole, which a peer experiences as "their location stopped updating" with no error on either side and nothing in any log; that silence is the class this whole epic exists to end. (Lowering the burst cap instead was priced and rejected on L-123: it widens the delta alphabet but pulls the first deferral EARLIER.) | **An account cannot hold more than ten circles.** Refused with its own copy at BOTH entry points — `nameCircleRosterFullError` in `name_circle_page.dart` and `invitationRosterFullError` in `invitation_card.dart` — with all twelve non-English locales translated and reviewed. The reservation is process-local state on a singleton service, so it bounds concurrent growths within one isolate and nothing beyond that, which is all the two roster-growing calls need. The deferral ladder, the `ceil(N ÷ 11)` service-period arithmetic and the cap-literal `{2,3}` assertion all STAY in the tree as documentation of a state production cannot reach — deliberate, because they are exactly what lifting the bound re-opens. **And the bound closes neither the 60 s → 30 s margin halving at every `N ≥ 2` nor the two realized-gap terms outside the invariant** — the iOS burst head, which crosses the 228 s retention from FOUR circles up, and the serial pass span; both are indexed as standing residuals in §9.9 | **Evidence that real users routinely hold more than ten circles** — then ten is the wrong horn and the retention question reopens as a wire decision (D0, L-02) rather than a product one. **Restoring per-circle publish schedules**, or any change that decouples the burst spread from the retention margin: δ becomes each circle's own sampled interval again, with no spread and no deferral, and the bound stops being derived from anything. Mechanically, two regressions make it advisory again and each has a test: `kMaxCirclesPerAccount ≥ kMaxCirclesPerBurst` re-opens the deferral branch on the first tick, and a reservation that leaks — released on a refusal, or not released when the core throws — restores the concurrency overshoot (`nostr_circle_service_roster_bound_test.dart`'s two-growths group; `circle_roster_bound_sites_test.dart` for the inventory) |

### 9.7e 2026-09-09 — OD4-c's control as it landed, and the fact that fixed its shape

One row, and it sits apart from L-121 for the reason §9.7b and §9.7d exist: a DECISION and an IMPLEMENTATION are
different records, and this implementation discovered something the decision did not know. L-121 left the burst's
disposition open between publishing and rolling back; building it established that **rolling back is a permanent,
silent drop of the removal at the pinned rev**, which is the same failure class the decision was taken to end. So the
shape — park, durably, and redeem only in the foreground — is forced by evidence rather than chosen. L-121 stays as
the decision; this row is what building it cost and what it did **not** buy.

| # | Date | Status | Decision | Rejected — and why | Cost | Invalidated by |
|---|---|---|---|---|---|---|
| **L-133** | 2026-09-09 | **DECIDED** — RUST half **LANDED** the same day; ~~(i)'s Dart consumer stays **OWED**~~ **(i)'s Dart consumer landed too — L-134** | **OD4-c's control as it landed, and the one fact that fixed its shape: a bare ROLLBACK of a receive-side auto-commit is a PERMANENT, SILENT DROP of the removal.** Verified at the pinned rev `e391adc` both at source and through the real engine by probe: the engine removes its in-memory `scheduled_self_remove_auto_commits` entry BEFORE staging, `do_publish_failed` does not re-arm it, the leaver's proposal keeps a durable `MessageState::Created` record that makes `recorded_message_outcome` answer `Buffered` and return early, and the leaver's own re-proposal is gated on the epoch having moved — so the peer who asked to leave stays in the circle, deriving its keys, until some unrelated commit moves the epoch. **(iv) therefore PARKS.** `ReceiveAutoCommitPolicy::DeferToForeground` is read by `EngineProcessor` from ONE atomic that `resume_burst` writes from its typed `BurstKind` before any REQ, so the scoping is a state read rather than a convention; `CircleManager::defer_removal_commit` writes the durable `deferred_removal_commits` row FIRST and parks the commit second, so a crash between the two leaves the state that REPORTS itself; a park that cannot be recorded falls through to the normal Rule-13 ladder; redemption is a FOREGROUND open only, and an unacked redemption stays owed and retries rather than rolling back. **(i) is `LiveSyncEvent::GroupUnrecoverable { nostr_group_id }`** — per circle, terminal, pseudonymous — from two sources: the engine's own verdict (previously flattened into the per-event, self-clearing `SyncStatusReason::Unprocessable`, which named no circle) and a durable deferral with no live in-memory twin, evaluated only on a foreground re-anchor. 18 new tests → §4 OD4-c, §5.4 | **Rolling back inside the burst** — the obvious "safe" disposition, and the reason this row exists at all: it is the silent permanent drop above, i.e. this document's own wedge class in a new costume. **Skipping the convergence drain** — leaving the group pending instead of staging: the engine re-queues the group until its jitter elapses, so a receive pass that advances only once drains it out of the pending set with the eviction never surfacing. **Redeeming at `start`** — `start` cannot tell a foreground launch from a background wake that cold-launched the process, so redeeming there re-creates exactly the publish-before-apply window (iv) removes. **A bare accepted residual (option (iii))** — rejected by the owner on the pillar order, and that rejection is L-121's, not this row's | **A per-circle SEND BLOCK with no user-visible surface.** While a parked eviction stands, that circle's `encrypt_location` fails the engine's "send requires Stable" gate until the next FOREGROUND open — on a device that is rarely foregrounded, a real gap in that circle's sharing — and ~~**nothing tells the user**, because the verdict is emitted and unread: it rides `FfiRelayEventKind::Status` with a null `statusReason`, which the one Dart consumer of that kind returns early on, so it is discarded rather than merely unhandled~~ **that particular circle-level refusal still tells the user nothing, because a LIVE parked eviction is deliberately not reported (only an orphaned one is) — but the VERDICT is no longer unread: L-134's consumer moved the `unrecoverableNostrGroupId` read AHEAD of that early return**. ~~**What already existed keeps working and covers neither source:** the circle-details blocked banner (`circleBlockedBannerTitle`, via `markCircleBlocked`) fires on the foreground DECRYPT/fold result and is session-scoped, and `sharingHealthRepairNeedsNewCircle` is the reply to a Repair tap — neither is reachable from the live-sync bus, and neither can see a durable deferral.~~ **CORRECTED BY L-134: the blocked banner is now reachable from the live-sync bus, because the consumer drives the same `markCircleBlocked` marker, so the surface that already existed is the surface the verdict lights — `sharingHealthRepairNeedsNewCircle` remains the Repair-tap reply and remains unreachable from the bus.** Nothing user-visible was LOST either: the `Unprocessable` status this verdict replaced only ever reached `SyncStatus.lastIssue`, which no widget reads. Two limits of the detection: a circle a remaining peer ALREADY healed can be reported once before its next successful publish discharges the row (at `e391adc` no read accessor reveals a staged commit), and a device wedged by a session PREDATING this code carries no row and is undetectable. And (iv) is scoped to the burst plane: the Android background catch-up sweep still publishes a removal-bearing auto-commit through the unconditional resolver ~~, and the argument that a foreground service holding a wake lock makes that safe is recorded neither at the site nor in a test~~ **— and the REASON was replaced as well as recorded (L-134): it publishes because a park needs somewhere to be redeemed and a `PendingStateRef` is valid only inside the session that staged it, so a background isolate could never publish what it parked. That is stated at the call site and asserted by tests, and what the sweep pays instead are the two tree-wide guarantees (no rollback at `CircleManager::publish_failed`, write-ahead record at `CircleManager::owe_removal_publish`). The wake-lock argument is retired, not merely unproven** | **An upstream MDK change that RE-ARMS the auto-commit on `publish_failed`** — the park's whole justification is that it does not, so a rev where a rollback is recoverable makes the park unnecessary machinery. Or a **RELEASED tag whose durable outbound-fanout resumption makes the park unnecessary**: v0.9.5's `restored_pending` is exactly that mechanism, and reachable inside four crates Haven already pins — it does **not** qualify today, because at v0.9.5 the flag day is paid in full (L-93) and L-124's untagged-OpenMLS gate sits in front of it. And, as for L-121 itself, evidence that the wedge is unreachable at `e391adc` |

### 9.7f 2026-09-09 — OD4-c's consumer, and the tree-wide invariant that building it forced

One row, for the reason §9.7b, §9.7d and §9.7e exist: an IMPLEMENTATION is its own record, and this one discovered
something neither L-121 nor L-133 knew. L-133 established what a burst must not do; writing the consumer established
that the burst was only one of FOUR planes holding the same commit, and that they differed not in publishing it but in
what they did when no relay acked — all four through a fail rung that drops the eviction permanently and silently. So
the control that closes OD4-c is not the consumer, it is the invariant the consumer needed in order to have anything
honest to report. L-121 stays as the decision, L-133 as the burst-plane control, and this row is the consumer plus the
guarantee that made it truthful on every plane.

| # | Date | Status | Decision | Rejected — and why | Cost | Invalidated by |
|---|---|---|---|---|---|---|
| **L-134** | 2026-09-09 | **DECIDED** — **LANDED** the same day; OD4-c CLOSED in both halves | **(i)'s DART CONSUMER, and the tree-wide invariant building it forced.** The consumer is small and its placement is the whole design: `LiveEventRouter._handleStatus` reads `unrecoverableNostrGroupId` BEFORE its null-reason early return — the return that used to DISCARD the verdict — resolves the circle and marks it blocked (`markCircleBlocked`), so the circle-details banner that already disabled send/mutate for a blocked circle becomes the surface the verdict lights; the banner gained a re-create that opens the create flow with the circle's display name pre-filled and touches the broken group not at all. Building it exposed that the four planes which can hold a removal-bearing auto-commit differed not in PUBLISHING but in what they did on NO-ACK: all four called the Rule-13 fail rung, which at `e391adc` discards the eviction permanently and silently. So the fix is ONE invariant with two halves, placed at the point all four converge rather than at four call sites (two of them resolve the commit from Dart, so no Rust call-site rule could reach them): **write-ahead** — `CircleManager::owe_removal_publish` records the durable row plus the in-memory commit BEFORE the publish-before-apply window opens — and **no rollback anywhere** — `CircleManager::publish_failed` keeps an owed removal-bearing commit staged instead of discarding it, and `confirm_published` discharges it. `catchup.rs` still publishes, and the REASON is now at the call site instead of being an argument in a doc: a park needs somewhere to be redeemed and a `PendingStateRef` is valid only inside the session that staged it. `rollback_receive_publish_work` was renamed `park_or_rollback_receive_publish_work` because the old name described the bug. Six new Rust screens carry the invariant — five behavioural in `od4c_removal_deferral_e2e.rs` (the FFI fail rung keeps the removal owed, a plane killed mid-publish stays detectable, a publishing plane records before it publishes, the deferred-send plane owes before it crosses the FFI, a burst never publishes an obligation already owed) plus the second structural gate `security_rule_gates.rs::od4c_no_plane_can_roll_back_or_hide_a_removal_bearing_auto_commit` — and the consumer has its own: the router's eight wedge cases in `subscription_service_test.dart` and the banner's re-create cases in `blocked_circle_banner_test.dart`, with `removal_commit_disposition_claims_test.dart` pinning the corrected Dart doc claims in BOTH directions → §4 OD4-c, §5.4, and `SECURITY.md` residual 4 | **A verdict acted on at FIRST sight** — the obvious consumer, and the one this row exists to refuse: the report sweep runs immediately after a re-anchor subscribes and can race a remaining peer's healing commit, so a single verdict would sometimes tell a user to rebuild a circle that works, at the price of the whole roster's invitations. **A TIME-based debounce** — a clock, a timer or a settle window would have been a Rule-13-shaped mistake in a new place; the engine already emits `SyncStatusReason::BackgroundResumed` in order at the head of every re-anchor and one sweep names a circle at most once, so re-anchor GENERATIONS give the same screen with no timing assumption beyond the stream's own. **A per-plane rule** — four call sites, two behind the FFI, and a fifth plane written later would not inherit it. **NEW COPY for the affordance** — a template key missing from a shipped locale is a RED gate here (`l10n.yaml`'s `untranslated-messages-file` plus step 1 of `check_l10n_parity.sh`), so an English-only string could not have landed at all; `legacyCircleRecreateCta` already says exactly this in all thirteen locales. **LEAVING or MUTATING the broken group for the user** — the re-create leaves the old row alone, because the user chooses when, and whether, to lose what the circle still shows | **The announcement waits for the SECOND foreground open.** That is the debounce, not a bug, and it is the same horizon as the repair itself — a foreground open is also the only place a parked eviction is published — so the wait costs the announcement and never a recovery; on a device that is rarely foregrounded it is nonetheless a real delay before the user learns a circle is dead. **And redemption ACROSS a session stays impossible at this rev:** an obligation recorded by the Android foreground service or the WorkManager catch-up worker is REPORTED but can never be published, because its `PendingStateRef` died with the isolate and hydrate short-circuits on `staged_removes_member`. Those wedges are now LOUD BUT TERMINAL — named to the user, repaired only by re-creating the circle. Strictly better than the silent permanent drop they replaced, and NOT a heal, which is why this row says so rather than reporting OD4-c as a fix | **A rev where a staged eviction can be re-derived from group state** — v0.9.5's durable outbound-fanout resumption is exactly that shape and would turn the cross-session terminal case into a recoverable one, retiring the loud-but-terminal wording above; it does not qualify today for L-93's and L-124's reasons. Or **field evidence that the two-observation debounce hides a real wedge for longer than a user tolerates**, which would move the argument from "one verdict has a false positive" to "the false positive is cheaper than the delay" |

### 9.8 The correction chains

Each chain below is a case where this plan's own reasoning was wrong. They are collected because the CHAIN is
the lesson — a reader who sees only the surviving link learns nothing about which kind of argument fails here.

1. **OD4-c's upstream fix — three links.** *(L-65 → L-66 → L-93)* "The backfill is in MDK master and UNRELEASED"
   → "it SHIPPED in v0.9.5 and is unreachable from every pinned crate at every tag, so option (ii) is DEAD" →
   "the narrow fact stands but the INFERENCE was false: v0.9.5's durable outbound-fanout resumption fixes
   OD4-c inside four crates Haven already pins, so the reason not to bump is the flag day."
   **What failed:** a true fact about one mechanism was generalised into a claim about the whole ladder. The
   correction that killed option (ii) was itself confidently written and independently verified — and still
   wrong at the level of inference.
2. **The burst bound — five links.** *(L-77)* `N ≤ 12` → `N ≤ 14` (the plan's own stagger-less formula) →
   `11` (the implementer, adding the stagger) → `11 is unsound too` (the reviewer: the formula omits the pause,
   which ends in an uncapped Rule-13 drain) → **re-scope, do not enlarge.**
   **What failed:** four successive attempts to find the right VALUE for a quantity that does not exist. A bound
   containing an unbounded term is not a bound, and no honest bound on a whole burst exists.
3. **The stale-EOSE caveat — an instruction that outlived its subject.** *(L-74 → L-86)* §5.4 derived a real
   cursor hazard, instructed a fix "in a separate packet", and the fix landed — leaving a live instruction to
   fix something already fixed. **What failed:** an instruction written in the imperative with no expiry. The
   entry now says the instruction is *spent* and forbids re-deriving the caveat from it.
4. **P4-6's headline invariant — false for the accounts it mattered most for, then largely rescued by another
   phase.** *(L-92 → L-100)* "presence only at publish instants" was false for a multi-circle account, because
   the burst opens every circle's REQ while the publish pass sent only to the due set. P5(a)'s coalescing then
   made the two sets coincide for any roster inside the cap. **What failed:** a statement true of the
   one-circle case, generalised.
5. **The compensating control that did not exist.** *(L-98)* Three carriers were named for the claim that the
   poll path's background receive timer was pinned by a guard check; mutation showed deleting the timer outright
   left the check passing. **All three now state the retraction** — the lane header, §5.4's correction and the
   drive target's library doc — so the count of documents still asserting it in the working tree is **zero**, and
   the two sentences that still called the third carrier *un-retracted* were corrected with it.
   **What failed:** a citation asserted, never exercised — which is why the ledger's own citations are symbols
   and section names, and why mutation is the only test of a guard claim.
6. **The `_closeBurst` guard citation.** *(L-106)* Same shape, same day, different guard: the check that names
   both socket-closing links names them in a *different* function. **Two instances in one review is a pattern,
   not a coincidence.**
7. **The manifest floors.** *(L-105)* A header said the anti-vacuity floors sit at ~90 % of the measured
   manifest; the test floor had drifted to 67 %. **What failed:** a rule stated once and never re-applied as the
   thing it constrains grew.
8. **P1's "no maintenance timer is armed while backgrounded".** *(L-43)* True of the arming path, false of the
   state. **A gate on the ARMING path is not a gate on the STATE.**
9. **P2a's accepted residual.** *(L-50 → L-51 → L-52)* The bound, the formula and the justification were each
   wrong in turn — the gap formula overstated the breach, the "every lever pays in S+ duty cycle" reasoning was
   retracted outright, and the 941 094-point sweep that should have caught the breach held ρ and σ at zero in
   exactly the group that breaches.
10. **The `isPaused` oracle.** *(L-95)* §5.4 specified it twice; it is raised as the first statement of the
    pause, so a lane built on it would go green while proving nothing. **A flag set at the start of a sequence
    cannot witness the sequence.**
11. **The `ur` menu name — three links, and the SECOND correction is the reusable one.** *(L-116)* "Apple ships
    no Urdu iOS UI, so keep the English name" → "Urdu IS a shipped System Language, but the exact Urdu string
    cannot be verified, so keep English" → "`لوکیشن کی خدمات` appears 19× in each of the independently
    translated iPhone and iPad User Guides, with the full path; only KB 102647/102515 are untranslated, and those
    serve English on `ur-IN`." **What failed, twice: a negative result from ONE vendor surface was taken for a
    negative result.** The rule this leaves behind — when a KB article is untranslated, check the User Guide
    before concluding the vendor ships no term — is why `ur`'s `'Always'` correctly STAYS English on the
    narrower ground that Apple's Urdu guides print `ہمیشہ` only as running prose, never as a quoted control label.
12. **The relay-side "no `#p` REQ between bursts" oracle — a decision the plan LOST and then re-made.**
    *(L-111 → §5.4 → L-96)* DECLINED in §8 "Not applied" on 2026-08-29, because the iOS lane's
    `tooling/e2e/local-relay` journals only "listening"/"shutting down" → re-specified in §5.4 as a P2c oracle,
    and written into §4's OD4-b "Gates" column as though it were available → withdrawn again by L-96 on
    2026-09-08, on the same ground, as though the finding were new. **What failed: a declined item was
    re-proposed inside a later phase's change list, and nothing connected the two.** This chain is the argument
    for §9 existing at all — two rounds of reasoning were spent reaching a conclusion the plan had already
    written down, in the same document.

### 9.9 Still open — the index

Everything below is a decision nobody has taken, work a taken decision implies that has not landed, a residual
someone ACCEPTED and will meet again, or a document that contradicts HEAD or itself. It is an index; each row's
own entry carries the argument. **Four groups, and the third is the one a live defect six months out is most
likely to land on** — an index of undone work and stale prose alone leads a reader to none of the accepted
residuals, which is what it did until 2026-09-08.

**Owner decisions, untaken — with the owner and the gate each must clear.** There is no calendar in this plan, so
a "decide by" is written as the gate the decision must precede. **Where that column reads *no gate*, the decision
can rot indefinitely, and saying so is the point** — ~~OD4-c has sat since 2026-09-05 behind "the owner's call,
deliberately left open" with nothing forcing it~~ **and OD4-c is the record of it: it sat from 2026-09-05 to
2026-09-09 behind "the owner's call, deliberately left open", with nothing forcing it, and was then taken. FOUR of
the seven rows this table carried were decided on 2026-09-09 (L-121, L-122, L-123, L-124), which is what shrank it to
three — and none of them was forced by a gate. A FOURTH row was then ADDED the same day, and not by a decision: the
final review of OD4-c's own consumer found that the POLL configuration reaches neither half of it (last row below), so
this table stands at four rather than three.**

| Decision | Row | Whose call | Decide by (the gate it must precede) |
|---|---|---|---|
| The MDK flag day itself — covered by no §4 row today, and its supply-chain PRECONDITION now is (OD-P4M-1) | L-68, L-93 | owner | **P4M-2, and not before OD-P4M-1's gate clears** — a tagged OpenMLS (L-124). No packet after P4M-1 may start without both |
| fr guillemet spacing harmonisation — NBSP vs breaking space across six strings, **three each way** (corrected 2026-09-09; guillemets only — the colon convention is settled 28:0 on a plain space) | L-117 | owner | **the next fr copy round that touches those three older strings**, at which point harmonising is free |
| **P2b's un-park needs no decision — it needs one Android handset** | L-33 | — | `POWER_MEASUREMENT.md` §5 under `dumpsys deviceidle force-idle`, both battery-exemption states — graded against **228 s**, which is now decided rather than cross-referenced (OD-P2-4, L-125) |
| **Neither half of OD4-c has a consumer in the POLL configuration** (added 2026-09-09, from the review of L-134). `redeem_removal_deferrals` and `report_unrecoverable_circles` are called from ONE place in production code, their own unit tests aside — `live_sync/session.rs`, on a FOREGROUND burst open — so in a `HAVEN_LIVE_SYNC=false` build, where no session is ever started (L-131 gated the only door), neither runs. An unacked publish on the poll plane therefore records a removal obligation (`CircleManager::owe_removal_publish`, write-ahead, and correctly never rolled back) that **nobody will ever publish**, and a circle wedged that way gets **no per-circle `GroupUnrecoverable` verdict**, so the blocked banner and its re-create never name it. **It is NOT a regression and must not be read as one:** the rollback this deferral replaced dropped the removal too, the generic sharing-health banner is flag-independent and still fires, and a circle whose own decrypt returns `Unrecoverable` is still marked blocked by `_convertLocationEventResult` on either plane — what is missing on the poll plane is only the parked-obligation half. **Redeem on the poll plane, name the wedge there some other way, or accept that the flag-off build detects a wedge and never says so?** | L-121, L-131, L-133, L-134 | owner | *no gate* — nothing forces it while `HAVEN_LIVE_SYNC=false` is a shipped rollback path. It must precede either of that path's two exits: retiring the flag (the question dissolves) or making the receive plane runtime-selectable (the poll plane stops being a rollback and becomes a configuration users hold) |

**Decided on 2026-09-09 and therefore no longer in this table** — written out so a reader who remembers a row here
finds where it went, instead of re-deriving it (chain 12's lesson): **OD4-c** → L-121, both halves, option (iv) plus
option (i), (iii) rejected, ~~implementation OWED~~ ~~**Rust implementation LANDED 2026-09-09 (L-133), (i)'s Dart
consumer owed**~~ **FULLY IMPLEMENTED 2026-09-09 — Rust half L-133, (i)'s Dart consumer L-134**; **OD4-d** → L-122, the when-in-use/flag-off lane leg, ~~in
progress~~ **LANDED the same day, as the matrix's third leg (§9.7b, L-126–L-130)**; **the roster bound** → L-123,
bounded at 10, ~~in progress~~ **LANDED and reviewed on two planes the same day (§9.7d, L-132)**; **the untagged-OpenMLS supply-chain question** →
L-124, do not bump, gate = a tagged OpenMLS. **All four LEFT this group, and they did not all land in one place:** L-121,
L-122 and L-123 moved into the owed-work group below, because decided is not built; L-124 needs no work here and its
only remaining trace in this table is the gate now attached to the flag-day row. **L-122 and L-123 then left the
owed-work group too, on the same day, because both were built — the only OD4-d entries below it now are its residual
ceiling and the product finding its own control arm turned up, and the roster bound's only surviving entry is the
margin halving in the residual table, which is an accepted residual rather than work owed. ~~L-121 is the one still
owed.~~ ~~**L-121's own RUST half then landed the same day (§9.7e, L-133), so what is left of it in the owed-work group
below is (i)'s DART CONSUMER alone — the verdict is emitted, nothing reads it, and until something does, the wedge is
detected and the user is not told.**~~ **L-121 LEFT THE OWED-WORK GROUP TOO, on the same day: its Rust half is §9.7e's
L-133 and (i)'s Dart consumer is §9.7f's L-134, so ALL FOUR of the rows this paragraph tracks are built and the
owed-work group below carries NO OD4-c item. What survives of OD4-c there is nothing; what survives of it anywhere is
the residual list in §5.4 and residual 4 of `SECURITY.md`.**

**Work owed by a decision already taken.** Raise `INBOX_BURSTS_PER_REQ` once the k > 1 re-anchor defect lands,
re-deriving OD4-b's latency on the `2k − 1` worst case (L-70, L-87). Pin `max_rewind_commits` in
`security_rule_gates.rs` (L-71). Replace the C2 backlog test that was removed as unsound (L-74). Write
`resent_fix_payload_has_identical_shape` (L-63, CI-R21). Write
`the_per_relay_window_returns_at_the_bound_when_nothing_answers`, which never landed and leaves
`LOCATION_ACK_WINDOW` — the constant that bounds how long one publish keeps the radio awake — pinned only as an
INPUT to the ladder's arithmetic (**L-113; this item was missing from this list until 2026-09-08**). Re-pin the
three P3 coverage floors and add the `background_deferred_send.dart` and `background_burst_coordinator.dart` rows
from CI's lcov (L-46, L-64). Wire the `created_at` grader to a lane that can feed it — still `--self-test`-only
(L-36, §6.6 LIVENESS row). `trackCommitCriticalForTest`'s revisit and a test that distinguishes the
coordinator's join branch (L-84). Re-pin the anti-vacuity floors in `check_privacy_invariants.sh` that this working
tree's own manifest has already outgrown — **FOUR of the six, not the two this item named when it was written**:
`FLOOR_INVARIANTS`, `FLOOR_GUARDS`, `FLOOR_TESTS` and `FLOOR_DOC_REFS` all sit below the `floor(0.9 × measured)` rule
the guard's own header states, while `FLOOR_ARB_KEYS` and `FLOOR_EVENT_KINDS` still satisfy it (L-105). **No value is
written here, deliberately** — this item once carried two, and both were wrong before anyone read them: one of them
would have LOWERED the constant the file already holds (which that header forbids outright) and the other was already
the constant, i.e. a no-op. Read all six off the `[rule 14]` line `count_metrics` prints, at the moment of the re-pin,
and re-pin LAST — after the session's final citation has landed, because every added citation moves the denominator
(the same failure mode as the fixture-count rule in the contradictions list below).
**Added 2026-09-09, all three from that day's owner decisions, and none of them is a
residual — they are code a taken decision requires:** ~~build OD4-c's control, BOTH halves — (iv) keep removal-bearing
auto-commits out of background bursts and (i) surface the survivor as a `GroupUnrecoverable`-class status with a forced
re-invite, each with a test that reddens when its half breaks~~ ~~**THE RUST HALF IS DONE 2026-09-09 (L-133) … WHAT IS
STILL OWED is (i)'s DART CONSUMER**~~ **DONE 2026-09-09, BOTH HALVES, so OD4-c is no longer an item in this list at
all.** (iv) is `ReceiveAutoCommitPolicy::DeferToForeground` plus the durable `deferred_removal_commits` park and a
foreground-only redemption that retries rather than rolling back; (i) is the per-circle
`LiveSyncEvent::GroupUnrecoverable`, crossing the FFI as `unrecoverableNostrGroupId`, and its DART CONSUMER landed with
it (L-134): the status handler reads the verdict ahead of the null-reason early return, marks the circle blocked, and
the circle-details banner names that circle and offers a re-create that pre-fills its display name without touching
the broken group — on the SECOND foreground open, by a two-observation debounce keyed to re-anchor generations, because
one verdict can race a remaining peer's healing commit. Zero ARB keys were added, because English-only is a red gate
here. **What is NOT owed but must keep being stated** (residual, not work): the parked circle's `encrypt_location`
stays refused until the next foreground open; the Android catch-up sweep still publishes rather than parks, which is
now a FINDING at the call site with tests behind it (a park is unredeemable from a background isolate) paid for by the
two tree-wide guarantees; and redemption ACROSS a session is impossible at this rev, so an obligation another session
recorded is reported but terminal. ~~**P4 may not be called COMPLETE until the consumer lands**~~ **P4's OD4-c
precondition is MET — nothing about OD4-c holds P4's completion any more** (L-121, L-133, L-134). ~~Add the second `e2e-ios-background-publish` matrix leg — `when-in-use`, `HAVEN_LIVE_SYNC: "false"`,
P1/P2a/P2b/P3, no P2c — and write its "does NOT prove" header against what it actually covers (L-122; in
progress).~~ **DONE 2026-09-09 — the leg landed as the matrix's THIRD leg, running P2d where the live-sync legs run
P2c (a branch, not the "no P2c" this item assumed), and its header carries its own ceiling paragraph. Nothing about
it is owed; what it does NOT cover is a residual below, and the guard-fixture re-pin it implies is the coordinator's
last step, not this list's (L-122, §9.7b).**
~~Bound the roster at 10, with the refusal copy the new user-visible limit needs (L-123; in progress).~~ **DONE
2026-09-09** — `kMaxCirclesPerAccount` (10) is refused at `createCircle` and at `acceptInvitation` through
`_refuseIfRosterFull`, the typed `CircleRosterFullException` carries its own copy at BOTH entry points, all twelve
non-English locales are translated and reviewed, and the review that followed turned an advisory check into a real one
(an in-flight reservation, `_reservedRosterSlots`) and un-blinded the AST inventory guard (L-132). Nothing about the
bound itself is owed. **What IS owed, and it belongs to the no-gap invariant rather than to the bound:** the iOS
burst-HEAD realized-gap term crosses the 228 s retention from FOUR circles up and — unlike the Android 248 s term of the
same family, pinned by equality — has no test of its own, and the serial publish-pass span (≈90 s foreground / ≈120 s
background at ten circles, against the 30 s the SCHEDULE promises) is unpinned in the same way. Both are stated in
`constants/location.dart` and indexed in the residual table below. If a pin has since landed for either, this item is
that pin's record and not a claim it is still missing — read the test file, not this line.

**Standing accepted residuals — what they cost, and the trigger that brings each one back.** These are DECIDED,
not open: each was accepted with its reason, and each will present as a defect one day. **A live defect report is
far more likely to be one of these than a regression**, so check this table before opening an investigation.

| Residual | Row | Trigger — what has to be true for it to bite | What the user or the relay sees |
|---|---|---|---|
| The legacy 248 s no-gap breach (W-3) | L-50, L-51, L-52 | `Api.legacy` (Android API 23–30) AND a COLD acquisition AND `J + ρ + σ ≥ 178 s` | a peer's marker absent for at most 20 s, once per triggering cycle, against a 228 s retention. The legacy-only 147 s interval ceiling that empties the breach set was priced and NOT taken |
| The deferral hole past eleven circles — **and it deepens in bands, it does not plateau**. ~~**BEING CLOSED, NOT ACCEPTED, since 2026-09-09: the roster bound at 10 (L-123) makes every trigger in this row unreachable, so it is live only until that bound lands — and then it stops being a residual rather than becoming a smaller one**~~ **CLOSED, NOT ACCEPTED — the bound LANDED on 2026-09-09 (L-123, L-132) and makes every trigger in this row unreachable, so this stopped being a residual rather than becoming a smaller one. It is kept in full because it is the complete statement of what lifting the bound re-opens: before opening an investigation against it, check that `kMaxCirclesPerAccount` still refuses the eleventh circle — if it does, the report is not this** | L-100, L-101, L-132 | a roster of 12 or more circles, on any plane. `_takeBurstSlice` is strict round-robin, so the worst SERVICE PERIOD is `ceil(N ÷ 11)` bursts: **12…22 → 2**, **23…33 → 3**, **≥ 34 → 4 or more**. **ONE limit on that period before you read a report against it, and the shape a field report has.** On iOS-with-sharing-on the coordinator can fold a second tick into a running burst (`_joinable`), publishing more than eleven circles in one pass, so a report there may show a SHORTER gap than the period predicts. Otherwise the period is ABSOLUTE and the observed gaps DO line up with the ladder: ~~it is per CONTINUOUS RUN, `stopScheduling()` clears `_rotation`, and a circle past the first slice on a device that backgrounds often is deferred again on every run with an UNBOUNDED gap~~ — **retired 2026-09-09 by a fix at the source, not a re-wording.** `_rotation` outlives `stopScheduling()`/`startScheduling()` and outlives an emission reporting nothing eligible, so neither a backgrounding nor a failed roster read re-phases whose turn it is. Only `build()` (a fresh container, or `IdentityNotifier.deleteIdentity`'s invalidate) and a process restart rewind the queue, and because the roster keeps `filterPublishEligibleCircles` order that rewind re-serves the SAME first slice — a deterministic re-service, not a re-phase — whose tail gap is bounded by resume frequency rather than unbounded, because the deliberately uncapped one-shot (`locationPublisherProvider`) fires on cold start, on motion, on accept/create and on a resume more than 30 s after the last one (`MapShell`'s resume debounce sits ABOVE its invalidate). **So the shape a "one circle never updates" report actually has** is: the tail is served once per foreground session by the one-shot, and once per `ceil(N ÷ 11)` bursts by the scheduler — **with two things a field report can show that neither of those numbers predicts.** From 21 circles the one-shot's own spread outlasts `kLocationPublishOverlapGuard`, so a fresh trigger's `invalidate` supersedes the burst in flight and it stops where it stands: past twenty circles "once per session" is a probability, not a promise. And a turn is a SELECTION rather than a publish — the rotation advances when the tick FIRES, ahead of the chain, the window and the sink — so a refused publish window, a pause under the slice, or an iOS burst the coordinator drops costs a circle its turn without a publish, and it then waits its whole period again (one more burst at `N ≤ 11`, another `ceil(N ÷ 11)` past the cap). The ladder itself is pinned by `a deferred circle waits ceil(N / kMaxCirclesPerBurst) bursts` (`location_publish_scheduler_provider_test.dart`, whose rung expectation is now a literal `_expectedServicePeriodBursts` table, so moving the cap forces an edit there) and `and past the cap, the deferral ladder in SECONDS` (`publish_stagger_test.dart`); both measure INSIDE the one remaining limit and cannot see it, which is why it is written down here, while the three lifecycle properties that replaced the retired second limit have tests of their own (`a deferred circle is not deferred again by every resume`, `a transient empty roster emission does not re-phase whose turn it is`, `a roster change keeps survivors' places in the queue`) and a guard, `scripts/ci/check_publish_rotation_fairness.sh` | at 12…22 the realized gap is two sampled intervals — 144 s best, 240 s mean, 336 s worst, **366 s** once the burst-position differential is counted — so MOST deferrals leave the peer's marker expired. At 23…33 it is 216 / 360 / 504 s. **From 34 up even the BEST case (288 s) exceeds the 228 s retention on EVERY publish**, so the marker is expired always rather than usually. Against the UNCAPPED coalesced burst the cap moved the onset from `N ≥ 22` to `N = 12`; **against the ACTUAL per-circle predecessor there was no hole at any roster and the full 60 s of margin was intact, so it is a regression at every `N ≥ 12` with no upper bound, and at every `N ≥ 2` in the propagation margin (60 s → 30 s)** |
| The propagation margin halved, **60 s → 30 s at every `N ≥ 2`** — the one thing the roster bound does NOT close | L-100, L-101, L-132 | any roster of two or more circles, on every plane. `LOCATION_MESSAGE_RETENTION_SECS` is `kLocationPublishMaxInterval + 2 × kTtlNetworkBufferSeconds`; the burst spread now spends one of those two buffers, so only the second is left for propagation and clock skew. **30 s is a worst-case BOUND and not the margin at every roster** — the spread is `maxSpreadFor(n)`, so the margin is 51 s at two circles, 42 s at three, 33 s at four and 30 s only from five up. Against the ACTUAL predecessor (per-circle schedulers: δ was each circle's own sampled interval, no spread, no deferral) the full 60 s was intact at every roster | nothing at all, until a relay's clock skew or a slow propagation eats the remaining margin — at which point a peer's kind-445 has already expired at that relay when its replacement is created, and the marker blinks out for the difference. Recorded on `INV-W-445-EXPIRATION-WINDOW`'s residual and in the `PUB-COALESCE` `ratchet_override` block — deliberately in the block for the change that CAUSED it, so it lands in a reviewed diff and not only in prose |
| Two realized-gap terms that sit OUTSIDE the no-gap invariant and that **no test pins**, one of them crossing the retention at an ordinary roster | L-132, §5.5, `constants/location.dart` | **(a) the iOS background burst HEAD.** `openBackgroundBurst` (`kBurstConnectBudget`, 5 s) + `waitBacklogSettled` (`kBurstBacklogBudget`, 5 s) + `openBurstPublishWindow` (up to `kOneShotLocationTimeout`, 30 s) sits between the tick and the burst's first publish and VARIES between bursts, so it enters the realized gap as a differential exactly as the burst offset does: worst case `168 + 40 + spread` = **226 s at three circles, 235 s at four, 238 s from five up**, i.e. inside the 228 s retention only up to THREE circles. In practice the head is ~1–6 s (warm socket, fix served from the stream cache), so it is a worst case — a real one. **(b) the serial publish PASS, the only term that scales with the roster.** One publish is priced at `kBurstPublishBudget` (10 s) and the pass is serial, so the realized span reaches **≈90 s (foreground shape) or ≈120 s (background)** at `kMaxCirclesPerAccount`, against the 30 s `kPublishStaggerMaxSpread` the SCHEDULE promises | (a) on iOS background sharing a peer's marker expires before its replacement lands, from four circles up — an ordinary roster, not a corner of one. (b) lands TWICE: in a deferred circle's realized gap, and in the duration-shaped circle-count estimator a relay reads off the burst's connect-to-disconnect span (`PUB-COALESCE`). **The Android term of the same family IS pinned** — 248 s, by equality, in `background_fix_request_test.dart`, the row above — which is what makes these two conspicuous: same family, same document, no proof. A pin for (a) is owed above; read the test file rather than this cell to learn whether it has landed |
| The inbox-only-relay cadence inference | L-22, L-69, L-70 | an account whose kind-10050 inbox set is disjoint from every circle relay set, with background sharing ON | that relay sees a REQ/CLOSE pair every 72–168 s carrying no kind-445 at all = "this pubkey is background-sharing now". It closes when `INBOX_BURSTS_PER_REQ` rises above 1, which is blocked on the k > 1 re-anchor defect |
| The disjoint-relay archive correlation — **and the surviving defence is roster-scoped** | L-24, L-104 | per-circle relay sets genuinely disjoint AND an adversary holding two of those archives. **The downgrade weakens as the roster grows**, because `maxGapFor(n) = clamp(30 s ÷ (n − 1), 3 s, 9 s)` prices every gap at the burst's own size | identical inter-burst interval sequences identify the circles as one phone. The CSPRNG stagger breaks only `created_at` EQUALITY, and how much that buys depends on `n`: at `{2…9}` (up to four circles) eight admissible offsets force a windowed correlation needing a targeted hypothesis, so the downgrade from a zero-cost mass join to targeted confirmation is real. **At `kMaxCirclesPerAccount` (10) — the largest burst a bounded roster can produce — the alphabet is `{2,3,4}`: three shifted equality joins over the same whole-network index, i.e. still UN-TARGETED mass linkage.** So "a downgrade in kind, and that is the whole of what it buys" is true at small rosters only; at the bound what survives is a constant factor. `maxGapFor` keeps answering one circle further, where the alphabet is `{2,3}`, and no observer reaches that while the roster bound holds — **quoting the cap's two values as the SHIPPED alphabet overstates the leak by a third, which is the mutation `scripts/ci/check_delta_alphabet_parity.sh` was written to red (repo-guards step "Delta-alphabet parity"; L-132)**. Pinned per burst size by `expected whole-second delta alphabet, swept over every burst size the app admits`, with `{2,3}` asserted as a literal at the cap |
| The compounding failed engine open | L-80 | a PERSISTENT open failure while the publish pool keeps acking | once more than the retained past epochs' worth of peer commits have gone un-ingested, this device's kind-445s become undecryptable to EVERY peer — silently, while relay acks keep arriving on this side. The consecutive-failed-open counter feeding the receive-plane signals is the instrument: a RUN is evidence, not noise |
| A re-anchored `#h` REQ with no kind-445 to pair it with | L-92, L-100 | four classes: `openBurstPublishWindow` returns null (no identity, disclosure not accepted, permission revoked, one-shot GPS timeout); consent flips inside the publish pass; a circle in the live set that is not publish-eligible (`isLegacyOrphaned`, engine-flagged Unrecoverable — a PERMANENT mismatch, not a fractional one); the tail of a roster past `kMaxCirclesPerBurst` (**which the roster bound at 10 makes unreachable once it lands — L-123, 2026-09-09; the other three classes are untouched by it**) | the relay sees presence at an instant this device published nothing. Coalescing made the REQ set and the publish set coincide for every ELIGIBLE circle, so these four classes are what survives |
| A real socket inside an inter-burst gap, held by the crate's 55 s ping | L-19, L-81, L-82 | a LOADED machine — measured 48/150 disconnects under 2× oversubscription, 0/150 on `current_thread`, 0/300 idle. A backgrounded phone is the loaded case permanently | the promise is not that no such socket OPENS (the race is between two adjacent statements of a pinned crate's `InnerRelay::disconnect`) but that none SURVIVES: the radio-off watch cuts and COUNTS every one in `unrequested_connections`, and never reports it as connectivity |
| The 49 h inbox-lookback floor's two edges | L-20, L-69 | a sender whose clock is more than 1 h fast combined with a near-maximum NIP-59 backdate; or an inbox relay unreachable for more than 49 h while another advances the single cursor | an invitation is lost SILENTLY — `cursor.rs` records that a wrap below the floor is indistinguishable from one never sent. Narrowing the window is verified and explicitly NOT re-proposable |
| What the iOS background lane cannot show, on EITHER receive plane — a coverage ceiling accepted as one, not a defect | L-122, §9.7b (L-126, L-129) | a background-execution bug only a real device surfaces: a jetsam kill, a Significant-Location-Change relaunch, `BGTaskScheduler`, or simply hours. A green leg shows ONE real backgrounding for the length of the lane's window, on a simulator that cannot be suspended the way a phone is. The poll leg additionally shows nothing about the burst plane (that build lacks it) and nothing about the C3 chokepoint that must refuse a wake after consent withdrawal — the C4 watcher cancels the timer on that edge before the chokepoint is reached, and host tests own both halves. And there is no `(always, poll)` leg at all (L-126) | sharing that stops after hours, or a wake that arrives after consent was withdrawn — neither of which any lane can red. **`check_ios_background_publish.sh` check 6 does not stand in for any of it** (L-98); check 16 and P2d cover what CI can cover, and `docs/M7_BACKGROUND_SHARING.md` §6 item 0/0a is the only proof of the rest — DEFERRED for want of an iPhone, and never met by a green here |

**Documents that contradict HEAD or each other.** Defects found while building and then reviewing this ledger,
recorded here rather than fixed in passing, because each belongs to a packet that owns it:

- **§5.7's re-correction reached its central-finding BLOCK but not that block's own headline, nor six sites
  beyond it.** All of these still state the narrow fact in a form that carries the superseded INFERENCE ("no bump
  fixes OD4-c"), which L-93 killed: (1) the central finding's **own headline** — "THE CENTRAL FINDING — the
  motivation for bumping is unreachable, at every tag" — together with the "**No version on this ladder makes
  either reachable**" sentence sitting directly above the bullet that supersedes it; (2) §5.7's sequencing reason
  1 ("the central finding below kills it … gating P4 on a released tag buys P4 nothing"); (3) §5.7's
  Recommendation ("the one thing that motivated the bump is unreachable at every tag") and its "What is NOT a
  reason to take it: OD4-c (unreachable)"; (4) the "Break the motivation" reviewer attack ("name the file, in a
  PINNED crate, where the epoch-gap backfill lands. There is none."); (5) the surviving body of the struck
  "Migrating does NOT resolve OD4-c" bullet; (6) §7.5's `V-P4M-1`, whose last clause reads "**This is the row that
  kills OD4-c option (ii)**"; and (7) **one site OUTSIDE §5.7 entirely** — §5's phase-chain preamble, "it cannot
  be P4's precondition (the fix that made it one is unreachable at every MDK tag)" — plus §5.4's two OD4-c
  cross-references ("'wait for the bump' is not a recovery plan", "(ii) is DEAD as of 2026-09-05"). §7.5 also
  still has **no row at all** for the untagged-fork finding (L-93, L-94). **An EIGHTH carrier was found on
  2026-09-09 and is different in kind, which is why it is listed apart from the seven:** L-68's "Invalidated by"
  cell names OD4-c in its "Explicitly NOT reasons" list — written on the superseded inference — but it is the one
  carrier that already corrects itself in place, in its own last sentence, and since L-124 its conclusion is
  independently right for a stronger reason (the untagged-OpenMLS gate, not unreachability). It needs no edit; it
  is recorded here so a sweep for the class finds nine sites and not seven.
- **The check-6 retraction is COMPLETE, and this entry is kept as CLOSED rather than deleted** so the next reader
  does not re-derive the gap from L-98's own text. All three named carriers state it — the lane's "What this lane
  does NOT prove" header, §5.4's landed correction, and the drive target's library doc
  (`haven/integration_test/ios_bg_publish_test.dart`), in OD4-d's own terms. §4's OD4-d row and §5.4's correction
  said the drive doc was "still to be retracted"; both were corrected on 2026-09-08. HEAD contradicts nothing
  either way: the whole P4-7 packet is uncommitted, so HEAD carries neither the claim nor the retraction (L-98).
  **A FOURTH carrier surfaced on 2026-09-09 and is now corrected too: CLAUDE.md's "CI Pipeline" entry, which still
  described the poll configuration as shipping UNCOVERED and OD4-d as an open owner decision after the leg that
  closes it had landed.** And the retraction itself is unchanged by that landing — check 6 still does not stand in
  for the poll path's background receive timer; what changed is that the coverage it was falsely credited with now
  exists, in P2d and check 16 (L-122, §9.7b). Any future sentence pairing check 6 with the poll receive path is the
  same defect returning.
- **§5.5 still reads as a forward plan** although P5(a) has landed; its packet rows carry no LANDED record, and
  §6.1's P5(a) row is likewise un-updated. Its manifest half HAS landed and §9.9 said otherwise until
  2026-09-08 — see L-104, and do not re-derive the OWED item from this bullet (L-86's failure mode).
- **§4's OD4 row has not been updated for L-100** — the multi-circle correction it carries is now largely
  resolved by coalescing, and L-92's own "Invalidated by" is where that is recorded.
- **Every fixture count carried in prose is stale, and the bullet that used to sit here framed it as a symmetric
  disagreement, which it is not.** The tree's totals live in `SELF_TEST_FIXTURES` in `check_engine_client_options.sh`
  and in `SELF_TEST_FIXTURES` in `check_ios_background_publish.sh`, and **this bullet deliberately no longer names
  either: read the constant.** It carried ~~`163`~~ for the iOS script, then ~~`177`~~ after OD4-d's leg raised it
  (L-130), and the constant had moved AGAIN before the bullet was next opened — **the number moved twice while the
  bullet whose whole thesis is "never carry the number in prose" was being written, which is the evidence for the rule
  and the reason a third generation of it is not written down here.** The plan carries: §6.1's "`check_engine_pool_options`
  rewrite (~~13~~ **21**)" and "ios +1 (~~48/25~~ **118 today**)"; §7.2's 13 for that same rewrite and "24 as
  landed" for `check_stream_provider`; "expected 47" in three places in §5.3; and §5.4's two correction chains,
  which reached **44** for the first guard and **144** for the second before **both were de-numbered on 2026-09-09 and
  now point at the constant instead** — the second figure had gone stale a further generation by then, which is what
  finally settled that counting the generations is the wrong response to this. **They are not one quantity contradicting itself:** some are
  per-check fixture DELTAS a packet adds, others whole-script TOTALS, and mixing the two is exactly what makes
  the disagreement look symmetric. Which is why the standing rule is *read the `SELF_TEST_FIXTURES` constant out
  of the script at the moment you need it, never a value carried in prose* — and why this bullet now names neither
  script's total at all. The figures it used to carry (44 for the engine guard, 163 then 177 for the iOS one) were each
  read on the day they were written; the engine one happens to have held and the iOS one has since moved twice, and
  which of the two is which is not knowable from prose — which is the whole point.
- **§6.2 cites `resent_fix_payload_has_identical_shape`**, which §7.3 records as never written (L-63).
- ~~**§5.6's "Owner decisions / open questions" line is stale in WHOLE, not only in its V-P1-4 clause.**~~ **FIXED
  2026-09-08 by P6-B′.** It had listed OD1, OD3, OD4, OD4-b, OD-P2-2, OD-P2-3, OD-P3-b and OD-P3-c as open while
  §4's opening sentence records all eight as ACCEPTED on 2026-08-29; V-P1-4 is RESOLVED (§7.5, by P1-A3) and
  U-P0-1 is RESOLVED (L-39 — the claim is FALSE, not merely unverified); only U-P0-2 still stands, and the line
  omitted the two rows that ARE open, OD4-c and OD4-d. The rewritten line says all of that. **Both of those rows were
  then DECIDED on 2026-09-09 (L-121, L-122) and the same line was amended again, so a reader arriving at this bullet
  should not expect to find two open rows named there.**
- ~~**§7.5 still types U-P0-1 as `U`**~~ **FIXED 2026-09-08 by P6-B′** — the row now reads **V** and carries the
  resolution. §5.0 had recorded it RESOLVED on 2026-08-30 by P0-B and L-39 calls the underlying claim FALSE: one
  fact, two epistemic tags, one document, for nine days.
- **`_dispatchTick` no longer exists** — the shipped name is `_dispatchBurst`, with `_publishBurst` as its no-sink
  fallback. It survives in **three code sites** (a doc comment in `location_publish_scheduler_provider.dart`, a
  comment in `haven/integration_test/ios_bg_publish_test.dart`, and one in `tooling/e2e/ci/run-ios-bg-publish.sh`)
  and **eleven** places in this plan. **Two of the eleven are worse than stale, because they attribute the
  `.timeout(` to a guard pin:** "check 8's `.timeout(` sits on `_dispatchTick`" in §3 D6 and the same sentence in
  §5.4 — and check 8 lives in `check_location_access_gate.sh`, whose passing fixture
  (`GOOD_SCHEDULER_DELEGATED`) is written against `_dispatchBurst` and `_publishBurst`. **The same §5.4
  correction also names `_pacedPublish` as the no-sink fallback** (`if (sink == null) return _pacedPublish(...)`);
  the shipped line is `if (sink == null) return _publishBurst(burst, generation);`, and `_pacedPublish` is what
  `_publishBurst` calls per circle (L-78).
- **Three more names this plan asks a reader to grep for and they are not in the tree** (found 2026-09-09 by
  sweeping every backticked identifier in this document against the code; same class as `_dispatchTick`, and none of
  them changes an argument): §5.2's `fgs_no_permanent_wake_lock_test` shipped as
  `haven/test/lints/fgs_plugin_wake_lock_policy_test.dart` (whose groups carry the same two promises); §5.2's
  `markPublished(key, publishStart, J_c)` shipped as `PerCircleDueTracker.markBurstPublished(keys, dueAt)`, i.e. per
  BURST rather than per circle, which is what the coalesced tick actually calls; and §5.4/P4-4's maintenance
  `runIfDue` shipped as the PAIR `runKeyPackageIfDue` / `runRelayListIfDue` — a shorthand in this document, two real
  methods in `maintenance_scheduler_provider.dart` and two in the coordinator's port. The remaining absentees the same
  sweep found are all deliberate: a deleted symbol (`kMaxBurstCircles`, L-77), a rejected draft
  (`uiLocationStreamSuspendedProvider`), a struck ARB key (`locationSettingsIosCatchUp`), a test explicitly NOT
  written (`presence_copy_accuracy_test`, `resent_fix_payload_has_identical_shape`), or an upstream symbol
  (`compare_scores`, `compose_relay_opts`, `listenerCount`).
- **`check_privacy_invariants.sh`'s own header is stale in the same two ways L-105 records:** it states the test
  floor "had drifted to 67% of measured — 89 citations of slack" and the doc-ref floor to 79%, both computed
  against a smaller manifest than the tree holds (the true figures are 63.4%/104 and 76%), and the six floors it
  re-pinned no longer satisfy the `floor(0.9 × measured)` rule the same header states. That file is another
  packet's (L-105).
- **`nextBurstDue`'s own doc comment says "never sooner than `minInterval` after it FINISHED"** while both of its
  parameters are publish START instants. The helper is correct; the sentence is what a reader would code against
  (L-102).
- **`POWER_MEASUREMENT.md` §7's forced-idle row said the 228-vs-248 question was "an owner call and is left open".**
  **CLOSED 2026-09-09, the same day it was flagged:** the cell now states the gate as ≤ 228 s at every API level and
  scopes D3 (iii)'s 248 s residual to the ordinary cold path, citing §4 OD-P2-4 and L-125. Listed here because a reader
  arriving from either document should be able to see that the two once disagreed and no longer do.
- ~~**`MapShell._onResumed` may start a live-sync engine in a FLAG-OFF build, which would mean the documented
  rollback path is not the path a rolled-back build runs.**~~ **CONFIRMED REAL — it WAS a defect — and FIXED
  2026-09-09 (L-131).** Kept here, struck rather than deleted, because what was believed while it was open is the
  useful part: the entry predicted the wrong SHAPE of fix. `_onResumed` called `_healLiveSyncIfStopped()`
  unconditionally, ahead of its own debounce, and neither that method nor `_installLiveSync` re-read
  `liveSyncEnabled` — so a `resumed` lifecycle dispatch reaching a mounted `MapShell` in such a build installed a
  re-subscriber and started a session, and an app switch, a shade pull or a lock-screen check was enough to do it.
  **A SECOND ungated caller came out of the same review, `_restartReceiveAfterPausedStop`** — reached from the R1
  consent-edge watcher, so it could start one from a PAUSED process. Raised by OD4-d's packet, out of the poll
  leg's own control arm: that leg asserts `poolSubscriptionCount()` THROWS (L-128), which is precisely the
  assertion an existing engine would red. ~~A review is in flight and this entry deliberately takes no side.~~
  ~~the fix is a re-read of the flag at both entry points~~ — **the fix is ONE `if (!liveSyncEnabled) return;` at
  the top of `_healLiveSyncIfStopped`, the shared door**, not a re-read at each entry point: the shell's only
  `.ensureRunning()` call site lives inside that method, so gating the door covers both callers AND any future
  one, where two call-site gates would have left the next caller to rediscover this. `docs/M11_ROLLOUT.md`'s
  one-commit rollback recipe DID overstate what the flag buys — "the reverted build never starts the engine" was
  false until the fix, and its parenthetical reason (`_runStartupTasks`'s else-branch) was never the thing holding
  it; that line is corrected. Gate and door are pinned by two host tests in
  `haven/test/pages/map_shell_receive_recovery_test.dart`. **Either way the arm is the detector**, so a poll leg
  that begins failing on that assertion is this question answering itself — and it must be read, never relaxed.

### 9.10 Rows this ledger's first pass missed (appended 2026-09-08)

Every row here carries the date its decision was TAKEN, which is earlier than §9.7's — ids are append-only, so
this subsection is out of date order by construction, and the legend says so. Twelve rows: **four** owner
decisions §4 records and §9 did not (L-107–L-110); **two** claim retractions with coverage or disclosure
consequences (L-112, L-118); **one** undeclared test drop that leaves a load-bearing constant unpinned (L-113);
**two** §5.2 review findings whose fixes are guard-pinned rather than reviewed, the family §9.8 calls a pattern
(L-114, L-115); **one** decision this plan lost and re-made (L-111); **one** correction of a correction (L-116);
and **one** open l10n call §9.9 had been indexing with no row to point at (L-117). **Thirteenth row, appended 2026-09-09 and out of date order like the rest of this subsection: L-120**, the dead-citation class — recorded here rather than in §9.7 because it is a finding ABOUT this ledger, not a decision the phases took.

| # | Date | Status | Decision | Rejected — and why | Cost | Invalidated by |
|---|---|---|---|---|---|---|
| **L-107** | 2026-08-29 | DECIDED (owner) | **OD1 — the background location indicator is OFF under CONFIRMED Always (`showsBackgroundLocationIndicator = !alwaysConfirmed`), and there is NO extra user setting.** L-09 records D2's tier PREDICATE; this row records the product decision that predicate serves: transparency stays on the surfaces the OS owns — the arrow, Settings › Privacy › Location Services attribution, Settings › Battery "Background Activity" — plus Haven's own toggle, and Apple DTS advises against tricks, not against the property → §4 OD1 | **A user setting to force the pill on** — one `showsBackgroundLocationIndicator` input to the same Swift line plus one ARB key, declined because every Always-tier reference app leaves the flag off and a control whose only effect is to re-add an OS indicator carries no decision. **Leaving the flag `true` under Always** (the "If declined" variant) — it keeps the pill for everyone and forfeits the tier half of the drain fix | Provisional-Always users on iOS 18+ keep the pill until they answer the second prompt, and EVERY iOS 17 Always user keeps it for as long as they stay on iOS 17 — no diagnostics API, so `alwaysConfirmed` never becomes true there. **And the user-visible half is UNKNOWN, not estimated:** no simulator renders a status bar, so whether the pill actually disappears under confirmed Always is unproven (§2.5) | A device seeing the pill PERSIST under confirmed Always. The copy is safe either way because the indicator sentence follows the handler's state rather than an assumption about the OS (L-62), and `check_arm_tier_policy` pins the flag's derivation statically |
| **L-108** | 2026-08-29 | DECIDED (owner) | **OD-P2-2 — P2b closes the delivery→Dart suspend window BY CONSTRUCTION**, through the native `PendingIntent`/`LocationListener` registration that acquires the lock INSIDE the system's delivery hold, so no window exists to measure → §4 OD-P2-2, §3 D4 (BR-1) | **"Measure `p` and accept it"** — the probability that a delivery fails to wake Dart on a suspended AP. L-33 carries this alternative only as something it rejected; the ACCEPTED half is this row. **AMENDED 2026-08-30: `p` became unmeasurable, which STRENGTHENS the recommendation rather than reopening it** — with no handset there is no number to accept, and an accepted residual with no number is not an accepted residual | The construction argument is the whole of the evidence for the wake half. The emulator's Doze-POLICY oracle (LANDED 2026-09-04, L-49) proves the policy half and can never prove suspension | It travels with P2b, which is PARKED (L-33): U-P2-1 stays NOT AVAILABLE until one Android handset exists. A native API change that makes the registration unable to hold the lock inside the delivery would reopen it |
| **L-109** | 2026-08-29 | DECIDED (owner) | **OD-P2-3 — NO `SCHEDULE_EXACT_ALARM`.** P2b's no-fix watchdog is an inexact `AlarmManager.set()` while battery-exempt, which DOES fire in Doze with no permission (`FLAG_ALLOW_WHILE_IDLE_UNRESTRICTED`, §2.2). Up to ~75 % late is a **BOUNDED TTL breach, never a silent stop** — which is the distinction this whole plan turns on → §4 OD-P2-3 | The exact alarm: a NEW special-access surface ("Alarms & reminders"), Play-policy exposure, a 13-locale copy round and `docs/privacy` coverage — every one of those costs is known without a phone, which is why the NO never depended on a measurement. **AMENDED 2026-08-30: the revisit trigger — "if the P2b hardware row shows the alarm landing late" — NO LONGER EXISTS**, so the decision now rests on the bounded-breach argument alone | The NON-exempt cohort keeps the plugin's permanent lock in P2b, because no ordinary alarm fires in Doze without the exemption (D4 (iii)). And the ~75 % lateness is un-observed: nobody can discover it is unacceptable in practice until the un-park | Travels with P2b (L-33). A handset showing the inexact alarm landing late enough to breach more than one cycle would reopen the exact-alarm question with its disclosure costs unchanged |
| **L-110** | 2026-08-29 | DECIDED (owner) | **OD-P3-a — `kStationaryDwell = 120 s`** (one nominal interval) before the iOS profile drops from Best to HundredMeters → §4 OD-P3-a | **LONGER** — saves less; **SHORTER** — flaps Best↔100 m at walking pace. Both were priced on the flap-risk argument alone, which never needed a device, and neither was taken | In poor coverage the controller spends up to **≈ 59 %** of the time at Best (120 s Best / 84 s HundredMeters cycles). **That figure is ESTIMATED arithmetic and never an observation** (§6.5a), and the §6.5 "profile duty" column that was meant to re-tune it is **DEFERRED** — it comes from a `locationd` console trace on a physical iPhone, so 120 s ships un-tuned and STAYS un-tuned | The first real profile-duty trace, and it is the first thing to re-check on the first device. Being wrong is cheap — a one-constant edit plus its pin in `location_test.dart` — which is why it was taken without the measurement instead of deferred with P2b |
| **L-111** | 2026-08-29 | DECIDED | **marmot F14's relay-side "no `#p` REQ between bursts" is DECLINED as a lane oracle.** The iOS lane's `tooling/e2e/local-relay` journals only "listening" and "shutting down", so the frames the oracle reads are never written; it is recorded as optional evidence behind a tooling change, and the deterministic form is the Rust test `a_burst_reissues_the_inbox_req_every_kth_burst` → §8 "Not applied", §4 OD4-b | Adopting it as written — a lane oracle whose input the lane does not produce is a gate that cannot fail, this repo's documented recurring failure mode (L-38, L-55) | **The decision was then LOST.** §5.4 re-specified the same oracle for P2c and §4's OD4-b "Gates" column names it as available, so the plan spent a second full round of reasoning re-deriving this decline as L-96 on 2026-09-08. Nothing connected the two until this row — §9.8 chain 12 | A recording wire proxy on THIS lane. The core-flow lanes start one; this lane does not, and WS Ping/Pong is invisible to both — so the oracle becomes producible only through the tooling change the decline named |
| **L-112** | 2026-09-03 | **CORRECTION** — §3 D5 (v)'s overclaim retired | **The claim that `every_fetch_primitive_leaves_no_subscription_registered` pins `read_one_relays_answer`'s TIMEOUT path is RETRACTED.** It drives the EOSE and CLOSED exits only, the CLOSED one through a `RefuseAuthor` query policy; **the timeout exit is exercised by no test at all**, because producing it against an in-process relay means holding a REQ open past `DEFAULT_TIMEOUT` with a fixed sleep, which the Testing Requirements forbid outright → §3 D5 (v), §5.1 (SEC-F5) | Keeping the stronger sentence. Also dropped: the drafted assertion riding `RelayNotification::SubscriptionAutoClosed { id }` — `client.subscriptions()` reports only LONG-LIVED registrations, so auto-closing REQs are invisible there and are covered instead by the socket reaching `Sleeping`, which reads the unfiltered map | The code is safe on the timeout path either way — the same `CLOSE` runs — but that path is **REASONED, not pinned**, and the invariant it serves (`should_sleep` is false while ANY subscription is registered) therefore has one exit with nothing behind it | A way to produce the timeout exit without a sleep. Until then **any later claim that the timeout path is pinned is a doc regression**, and this row exists so the next reader recognises it as one rather than as a fact |
| **L-113** | 2026-09-03 | **OWED** | **A drafted test was dropped without declaring it, and this row is the declaration: `the_per_relay_window_returns_at_the_bound_when_nothing_answers` never landed** — re-verified absent from `haven-core` on 2026-09-08 — so `LOCATION_ACK_WINDOW` is pinned as an INPUT to the ladder's arithmetic and never as the bound `send_to_one` actually enforces → §5.1 review record | Crediting the surviving test: `location_ladder_worst_case_equals_one_publish_attempt` drives `publish_with_retry` over an attempt future that only SIMULATES the 5 s wait. And crediting the relay-backed `publish_location_event_folds_a_stalled_relay_after_its_own_window`, which asserts `elapsed < CONNECTION_TIMEOUT + LOCATION_ACK_WINDOW + wait_budget(10)` — a bound, deliberately not the window | **The constant that bounds how long ONE publish keeps the radio awake, and therefore the whole D5 energy claim, is unpinned.** §5.1 says restoring it is "being fixed in the P1 review pass"; it was not, so that instruction is now L-86's failure mode in its unfixed form — an imperative with no expiry | Writing it. It is a pure `#[tokio::test(start_paused = true)]` over `futures::future::pending`, which is exactly why nothing about the drop was difficult, and why the drop went unnoticed |
| **L-114** | 2026-09-04 | DECIDED | **The new standing FGS registration had NO CURRENT-consent gate, and the fix is STRUCTURAL rather than reviewed.** A registration that outlives the cycle which armed it keeps the GNSS receiver scheduled for a user who has since revoked in Settings; as landed the cycle reads the freshly reloaded `prefs` snapshot and requires BOTH `kLocationDisclosureAcceptedKey` and the background half **every cycle**, so a revocation written by the UI isolate is honoured on the very next one → §5.2 review, Security Rule 10 | Checking the flags ONCE on the path that enables sharing — that is a gate on the ARMING path and not on the STATE, which is L-43's lesson recurring in a second phase and against a privacy pillar rather than a battery one | One `prefs` reload per background cycle | `check_android_location_power.sh` check (5) pins every `_ensureRegistration(` site below both that gate and the foreground gate, so a regression is a red guard rather than a review miss. A restructuring that moves the registration out of the cycle re-opens the question and must re-prove the property |
| **L-115** | 2026-09-04 | DECIDED | **`onEngineCreate` was UNPINNED, which made the whole scoped-wake-lock feature silently deletable — it is now guarded by NAME with two mutation fixtures** (the line deleted; the line commented out). `HavenApplication.onCreate` → `FlutterForegroundTaskPlugin.addTaskLifecycleListener(PublishWakeLock)` is the only hook that sees the foreground-service engine before the Dart entrypoint runs, and the only one that runs for the Activity-less starts — boot restart, headless wake → §5.2 review | Leaving it unpinned because "a channel registration is obvious". Delete that one line and every `acquire` becomes a `MissingPluginException` **the Dart side deliberately swallows as a no-op: no error, no red test, and no wake lock** | A guard pinned to a Kotlin call by name, which a rename breaks for the right reason and an unrelated refactor breaks for the wrong one | Same family as L-98 and L-106 — a guard claim is worth exactly what a mutation run says it is worth. The difference here is that the mutation was run BEFORE the claim was written rather than by a later reviewer |
| **L-116** | 2026-09-04 | **CORRECTION** — a correction of a correction | **`ur` names the iOS menu in Urdu, `لوکیشن کی خدمات`, and the REASON was wrong twice before this.** Original: "Apple ships no Urdu iOS UI" — false; Urdu is a shipped System Language per `apple.com/ios/feature-availability`, and the iPhone tech-specs language list that omits it also omits Bangla, Gujarati, Kannada, Malayalam, Marathi, Odia, Punjabi, Tamil, Telugu and English (India), so it is a stale marketing subset and not the criterion. Replacement: "the exact Urdu string cannot be verified" — also false; it appears **19×** in each of the independently translated iPhone and iPad User Guides, with the full path `سیٹنگ > رازداری اور تحفظ > لوکیشن کی خدمات` → §7.1a | Concluding from Apple KB 102647/102515, which serve **English** on `ur-IN`. **A negative result from ONE Apple surface is not a negative result** — when a KB article is untranslated, check the User Guide before concluding the vendor ships no term | Two rounds of reviewer effort spent on one string's justification: the second round left the OUTPUT unchanged and the third changed it | `ur`'s `'Always'` correctly STAYS English, on the narrower verified ground that Apple's Urdu guides print `ہمیشہ` only as running prose and never as a quoted control label. The same surface that supplied the menu name refuses the tier name, and that asymmetry is the evidence rather than an inconsistency — §9.8 chain 11 |
| **L-117** | 2026-09-04 | **OPEN (owner-level)** | **fr guillemet spacing is left MIXED in-file, and harmonising it is an owner call.** ~~The new arrow string uses U+00A0; five older strings use U+0020~~ **CORRECTED 2026-09-09, measured rather than recalled: of the SIX guillemet-bearing fr strings, THREE use U+00A0 (`locationSettingsIosLimitedNote`, `locationSettingsIosIndicatorArrow`, `locationSettingsIosIndicatorBar`) and THREE use U+0020 (`locationSettingsAndroidVendors`, `nameCircleCreatedPartialSnack`, `nameCircleCreatedSnack`). All three NBSP strings are new or changed in the current staged batch, so only THREE strings are genuinely "older" — the six-string TOTAL was right and the per-side split was not.** **And this row is GUILLEMET-SCOPED ONLY:** the file's colon convention is settled **28:0** on a plain U+0020, so nothing in it asks for a no-break space before a colon — a translator read the row as "avoid all high punctuation" and gave up a colon it never needed to, which is why the scope is now stated instead of implied → §7.1b "Open, minor" | Harmonising unilaterally — two of the older strings sit outside P3, so the change would edit copy this phase does not own | **NBSP is the typographically correct half** (a breaking space lets `»` wrap alone onto its own line), so the three older strings are wrong in a way a French reader can see, and the ARB file is internally inconsistent until someone decides | An owner decision, or the next fr copy round that touches those three strings anyway — at which point harmonising costs nothing and NOT harmonising becomes a choice rather than a deferral |
| **L-118** | 2026-09-05 | **CORRECTION** — §5.4's stronger sentence retracted | **"No timer wake remains in Rust" is RETRACTED, and replaced by "no RADIO wake and no PERIODIC timer".** A repair armed BEFORE the pause keeps its deadline, so `run_repair`'s `sleep_until_opt(deadline)` wakes once — up to `BACKOFF_MAX_SECS` (30 s) into the pause — sees `paused` and re-parks. CPU only, no socket, at most once per pause → §5.4, §5.4 gap-closure item 3 | Keeping the stronger sentence. It is explicitly load-bearing for a user-facing disclosure: **P4-6's `SECURITY.md` sentence must say "no relay traffic between bursts and no periodic wake", never "no timer wake" — the weaker sentence is the true one** | One CPU wake per pause that no phase in this plan removes, and a disclosure sentence harder to read than the one it replaces | A repair-scheduling change that CANCELS armed deadlines at the pause instead of letting them fire and re-park. That would restore the stronger sentence and would then have to prove it against the STATE, because L-43's lesson applies exactly here: a gate on the arming path is not a gate on the state |
| **L-120** | 2026-09-09 | **CORRECTION** — the recurring failure mode, recorded as a class rather than as six more one-off fixes | **A citation that reads as evidence and resolves to nothing is what this epic keeps producing, and P6 — the phase whose job is to police exactly that — produced six more.** Found and fixed in one pass: (a) `check_engine_pool_options` **check 13**, cited three times as the named CI proxy for the P4 iOS wake-shape figure, in a register whose done-criterion was "each verified to exist by grep, not by recollection" — that script's numbered checks run **1–10** and the facts meant are check **(8)**; (b) `ios check 13` beside a separately-named "m7 guards", where `check_ios_background_publish.sh` and `check_m7_native_wake_guards.sh` BOTH have a check 13 and they are different checks, so the citation resolved to whichever the reader guessed; (c) the grader self-test at `repo-guards.yml:1330`, whose real step is ~84 lines lower while `:1330` had drifted onto the KeyPackage-rotation oracle's comment block — **a citation resolving to a plausible-looking wrong thing**, and the third drift of that same citation after `:1278` and `:1311`; (d) this plan's own line-citation drift LEDGER, twice declared RESOLVED and drifted in **every** entry once P4/P5 moved `map_shell.dart`; (e) `ci.yml` crediting the FGS lane with "relay-side corroboration" that `e2e-fgs-publish.yml` says it deliberately deleted as a gate that could not fail; (f) `CI_HARDENING_BACKLOG.md` crediting `MapShell._onPaused()`'s iOS branch with a **per-circle scheduler** that P5(a) removed, behind two drifted line citations. **And the same sweep over `haven-core/src/relay/live_sync/config.rs` turned up four more of the same kind, in one doc comment:** two cited test names and `CircleManager::converge_commit` that do not exist, a whole FORK-SAFETY narrative that is pre-Dark-Matter (Haven installs `settlement_quiescence_ms = 0`; the engine owns convergence), and a `<= 10` **const-assert that has never existed in any revision**. The agent's own words on that last one: "I nearly repeated it." | Re-pinning the numbers a third time — it would only have set the fourth drift running | Every one of these read as evidence to a reviewer, and three of them resolved to something real but wrong, which is strictly worse than resolving to nothing | **The rule, now explicit: cite the SYMBOL, the section heading, or the workflow STEP NAME — never a line number.** §9.8's correction chains and §9.9's index carry this class; the drift ledger in §1.2 is retired rather than re-pinned |


### 9.11 Reverse index — symbol to row

For the reader who arrives holding a symbol rather than a phase: a defect surfaces as `_closeBurst` or
`nextBurstDue`, not as "the P4-5 review". Every entry below is cited by the row it names. Ids only; read the row
for the decision. **Not exhaustive** — it covers the symbols a defect is most likely to be reported against, and
a full-text search for a backticked name is still the fallback.

**Dart — the burst and publish planes.** `_bursting` L-89 · `_chain` L-89 · `_closeBurst` L-77, L-89, L-106 ·
`_dispatchBurst` (ex-`_dispatchTick`) L-78, §9.9 · `_pacedPublish` L-78 · `_publishBurst` L-78, §9.9 ·
`_publishChain` L-99 · `_inFlightPublish` L-53 · `_trackCycle` L-53 · `closeIdle()` L-89 ·
`openBackgroundBurst()` L-76 · `resumeAfterBackground()` L-76 · `releaseBurstPlaneOnOptOut` L-89, L-106 ·
`runningBurst` L-89 · `shouldBurstImmediatelyOnPause` L-89 · `nextBurstDue` L-102 ·
`PerCircleDueTracker.dueKeysUpTo` L-102 · `poolSubscriptionCount()` L-95, L-128 · `trackCommitCriticalForTest` L-84 ·
`burstBound` L-77 · `_refuseIfRosterFull` L-132 · `_reservedRosterSlots` L-132 ·
`LiveEventRouter._handleStatus` L-134 · `_handleUnrecoverable` L-134 · `markCircleBlocked` L-134 ·
`_BlockedCircleBanner` L-134 · `legacyCircleRecreateCta` L-134.

**Dart — lifecycle, stream and health.** `_onPaused` L-10, L-43 · `_onResumed` L-10, L-131 · `_onDetached` L-25 ·
`_stopLiveSyncBounded()` L-25 · `_healLiveSyncIfStopped()` L-20, L-90, L-131, §9.9 ·
`_restartReceiveAfterPausedStop` L-131 · `ensureRunning()` L-131 · `_fullRestart` L-83 ·
`shouldStopLiveSyncOnPause` L-90 · `suspendForBackground()` L-43 · `suspendStream()` L-10, L-29 ·
`resumeStream()` L-10 · `clearCachedPosition()` L-10 · `appForegroundProvider` L-10, L-29 ·
`IosLocationSource` L-05 · `_startIosBackgroundReceiveTimer` L-98, L-128, L-130 · `_runBackgroundCatchUp` L-98, L-128 ·
`CatchupService.runCatchup(isBackgroundWake:)` L-128 · `snapshotLastKnownForCircle` L-128 ·
`LocationDisclosureStrings.backgroundIos` L-42 · `_ensureRegistration(` L-114.

**Rust — engine, cursor and publish.** `pause_subscriptions` L-19, L-95 · `settle_before_pause_with` L-72 ·
`terminate_all_relays()` L-81 · `run_repair` L-73, L-118 · `take_due` L-73 · `sleep_until_opt` L-73, L-118 ·
`anchor_end_of_stored_events` L-86 · `EoseCoverage` L-86 · `unrequested_connections` L-82 ·
`register_and_subscribe` L-48 · `inbox_phase` L-48 · `maintain_subscription_health` L-85 ·
`probe_subscriptions` L-69 · `publish_relay_options()` L-16 · `send_to_one` L-17, L-113 ·
`read_one_relays_answer` L-112 · `RelayManager::subscribe` (deleted) L-18 ·
`ConvergencePolicy::max_rewind_commits` L-71 · `DEFAULT_MAX_PAST_EPOCHS` L-71 · `restored_pending` L-93 ·
`staged_removes_member` L-65, L-93, L-121, L-133 · `resolve_publish_work` L-65, L-121, L-133 ·
`GroupUnrecoverable` L-121, L-133 · `ReceiveAutoCommitPolicy` L-133 ·
`resolve_receive_publish_work_with_policy` L-133 · `set_background_burst` / `auto_commit_policy` L-133 ·
`resume_burst` (`BurstKind`) L-133 · `defer_removal_commit` L-133 · `redeem_removal_deferrals` L-133, L-134 ·
`orphaned_removal_deferrals` L-133, L-134 · `discharge_removal_deferral_after_send` L-133 ·
`report_unrecoverable_circles` L-133, L-134 · `deferred_removal_commits` (table) L-133 ·
`unrecoverable_nostr_group_id` / `unrecoverableNostrGroupId` L-133, L-134 ·
`owe_removal_publish` L-134 · `publish_failed` / `confirm_published` L-134 ·
`park_or_rollback_receive_publish_work` (ex-`rollback_receive_publish_work`) L-134 ·
`resolve_receive_publish_work` L-134 ·
`InnerRelay::disconnect` L-81, L-82.

**Upstream (MDK / OpenMLS), for the reader holding a supply-chain question.** `openmls` fork rev `59e7d3b2`
L-94, L-124 · `retire_non_current_key_packages()` L-124 · `restore_pending(...)` / durable outbound fanout L-93,
L-124 · `check_mdk_supply_chain.sh` L-66, L-93.

**Native.** `HavenLocationStreamHandler` L-04, L-59 · `arm()` L-09, L-107 · `disarm()` L-09, L-10, L-62 ·
`alwaysConfirmed` L-09, L-62, L-107 · `showsBackgroundLocationIndicator` L-107 · `onEngineCreate` L-15, L-115 ·
`PublishWakeLock` L-115 · `CLError.locationUnknown` L-58 · `_requestedProfile` L-58.

**Constants.** `BACKOFF_MAX_SECS` L-118 · `BURST_SETTLE_CAP_SECS` L-79 · `COMMIT_SETTLE_WINDOW_SECS` L-21 ·
`DISABLE_WAIT_SECS` L-99 · `DISABLE_WAIT_POLL_SECS` L-129 · `INBOX_BURSTS_PER_REQ` L-69, L-70, L-76, L-87 ·
`INBOX_RESUBSCRIBE_LOOKBACK_SECS` L-20, L-69 · `kBackgroundFixHorizon` L-14 · `kBackgroundFixLeadTime` L-103 ·
`kLocationPublishMinInterval` L-102 · `kLocationPublishOverlapGuard` L-83, L-88 ·
`kMaxCirclesPerBurst` L-92, L-100, L-101, L-123, L-132 · `kOptOutBurstWait` L-79, L-99 · `kPublishLinkTimeout` L-77, L-99 ·
`kPublishStaggerMaxSpread` L-14, L-100 · `kPublishStaggerMinGap` L-100, L-101 ·
`kStationaryConfirmMaxAccuracyMeters` L-07 · `kStationaryDwell` L-110 · `kStreamPositionMaxAge` L-40 ·
`kTtlNetworkBufferSeconds` L-38 · `LOCATION_ACK_WINDOW` L-113 · `LOCATION_PUBLISH_ATTEMPTS` L-17, L-77 ·
`kMaxCirclesPerAccount` L-123, L-132 · `CircleRosterFullException` L-123, L-132 ·
`LOCATION_MESSAGE_RETENTION_SECS` L-123, L-125 ·
`_pollPathReceiveInterval` L-129, L-130 · `_pollPathCatchupWindow` L-129 ·
`GROUP_RESUBSCRIBE_BUFFER_SECS` L-129 · `RELAY_LIFECYCLE_OP_TIMEOUT` L-79 ·
`SCHEDULE_EXACT_ALARM` L-109 · `SELF_TEST_FIXTURES` §9.9, L-130 · `liveSyncEnabled` (`HAVEN_LIVE_SYNC`) L-131.

**Guards and floors.** `check_android_location_power.sh` (5) L-114 · `check_arm_tier_policy` L-107 ·
`check_bg_publish_timeout_ladder` (15) L-99 · `check_c4_optout_release` L-106 ·
`check_engine_client_options.sh` (9) L-76, §9.9 ·
`check_ios_background_publish.sh` (6, 12) L-95, L-98, L-106; (16, `check_poll_path_receive_cadence`) L-130 ·
`check_location_access_gate.sh` (8) §9.9 · `check_m7_native_wake_guards.sh` (9b) L-32 ·
`check_mdk_supply_chain.sh` L-66, L-93 · `check_privacy_invariants.sh` (`count_metrics`, `check_floors`) L-105 ·
`check_delta_alphabet_parity.sh` L-132 · `coverage_floors.txt` and `--repin` L-46, L-64.

**Tests, and tests that do not exist.** `a_burst_reissues_the_inbox_req_every_kth_burst` L-111 ·
`a_burst_that_did_not_settle_every_endpoint_leaves_no_advance_standing` L-86 · `INV-COALESCE` sweep L-103 ·
`ios_indicator_copy_accuracy_test.dart` L-62 · `location_publish_ladder_sites_test.dart` L-45 ·
`publish_decorrelation_wiring_test.dart` L-103, L-104 · `publish_stagger_test.dart` L-37, L-100 ·
`circle_details_layout_test.dart` L-38 · `live_sync_burst_e2e.rs` L-96 · `live_sync_cursor_replay_e2e.rs` L-47 ·
`security_rule_gates.rs` L-71, L-133 · `od4c_removal_deferral_e2e.rs` L-133 ·
`od4c_a_background_burst_cannot_publish_a_removal_bearing_auto_commit` L-133 ·
`a_self_remove_auto_commit_is_deferred_by_the_burst_and_published_by_the_foreground` L-133 (**renamed**; the
pre-2026-09-09 name `a_self_remove_auto_commit_is_published_and_confirmed_inside_the_burst` asserted the opposite and
exists nowhere) · `nostr_circle_service_roster_bound_test.dart` L-132 ·
`circle_roster_bound_sites_test.dart` L-132 · **never written:** `resent_fix_payload_has_identical_shape` L-63 ·
`the_per_relay_window_returns_at_the_bound_when_nothing_answers` L-113.

**Manifest ids.** `INV-R-PER-CIRCLE-PUBLISH-DECORRELATED` L-01, L-24, L-104 ·
`INV-R-BACKGROUND-PRESENCE-ONLY-AT-PUBLISH` L-75, L-92 · `PUB-COALESCE` L-100, L-104 ·
`INV-L-IOS-PUBLISH-INPUT-BEST-PROFILE-ONLY` L-04, L-63 · `INV-L-IOS-INDICATOR-HONEST` L-61 ·
`INV-STAGGER-BOUND` L-102 · `INV-R-NO-TELEMETRY-SDK` L-32 · `INV-L-ACCESS-GATE-PRECEDES-FIX` L-13 ·
`INV-L-BACKGROUND-DISCLOSURE-GATE` L-13 · `INV-W-445-EXPIRATION-WINDOW` L-101, L-132 ·
`INV-L-WEDGED-CIRCLE-IS-DETECTED-AND-NAMED` L-133, L-134 (raised `ratcheted` → `enforced` when the consumer landed).
