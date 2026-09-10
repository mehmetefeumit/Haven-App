# Background Location Sharing — Field Failure Analysis and Fix Plan

**Status:** analysis COMPLETE (2026-08-28); fix units A–F ALL IMPLEMENTED + REVIEWED
(2026-08-29; each carries its own status line and review record; nothing is committed yet).
**AMENDED 2026-09-09: a SIXTH silent wedge was added — C5b, the durable variant of C5 that a process
restart does not clear (the OD4-c wedge). It was found by the power epic's own review rather than by this
analysis, which is the point worth keeping: "analysis COMPLETE" was true of the field incident and was
never a closed-world claim about the wedge set. Every five-wedge phrase below reads as five-plus-C5b.**
This is the canonical reference for every session working on the
"sharing stops after a few hours and reopening does not help" incident. Update the work-unit
status lines in place; do not fork this document.

Evidence standard: every claim below was verified at the source by the author and independently
by two reviewers (file:line citations are to the tree at commit `94285f9` + staged changes;
external crates are the pinned versions in `haven-core/Cargo.toml` / `haven/pubspec.lock`).

---

## 1. The field failure

- One circle: 1 iOS + 1 Android device. OS background location granted on both; Haven's
  in-app background-sharing toggle ON on both; both mostly stationary.
- Sharing worked both ways for ~2 hours, then stopped: neither device showed the other, and
  (as far as the owner could tell) neither was sending.
- **Reopening Haven in the foreground on BOTH devices did NOT recover it.**
- A second tester (another iPhone, another circle) reported Haven CONSTANTLY using location
  (blue indicator always on), yet the owner could not see them either.

## 2. Two framing facts that change the whole analysis

1. **In a 2-member circle, one dead device produces the full symptom on both phones.** If A's
   MLS session or receive plane dies, A cannot see B; A also stops publishing, so B cannot see
   A. "Neither showed the other" does NOT require a symmetric bug. The tester's iPhone with
   the permanent blue indicator was alive and publishing — the *owner's* receive plane was dead.
2. **A foreground reopen is not a process restart.** Rust statics (`SESSION`, `LIVE_SESSIONS`),
   Riverpod non-autoDispose providers, the engine's in-memory `EpochManager`, and SQLCipher
   rows all survive it. Every cause ranked 1–5 lives in one of those. **C5b (added 2026-09-09) lives in
   the LAST of them and is the one case a process restart does not clear either, because what survives is
   a staged commit on disk rather than in-memory epoch state.**

## 3. How the pipeline works (verified)

- **Publish** = an MLS application message: `haven-core/src/circle/manager.rs::encrypt_location`
  → `SessionManager::send_location` → `cgka-engine` `do_send`. The sender-ratchet generation
  advances (and is persisted) BEFORE any relay contact. Then `RelayManager::publish_event`
  (`haven-core/src/relay/manager.rs`, 3 attempts, ~49 s worst case). **Every Dart caller drops
  the outcome into a `debugPrint`** (`location_publish_scheduler_provider.dart` `_publishCircle`,
  `location_sharing_provider.dart` `locationPublisherProvider`, `background_location_task.dart`
  `_publishCycle`). Kind-445 events carry NIP-40 `expiration = created_at + 228 s`; relays delete
  them, so a receiver that was down cannot replay what it missed.
- **Receive** on the default build (`liveSyncEnabled = true`) is ONLY the live-sync engine's
  WebSocket REQs (`haven-core/src/relay/live_sync/*`); the 30 s / 60 s / 120 s
  poll fallbacks are compiled out (`map_shell.dart` `_startTimers`).
  *(AMENDED — power-efficiency P4: those REQs are PERSISTENT only while the app is foregrounded.
  Backgrounded on iOS with sharing on the engine is PAUSED between publishes and each publish tick
  opens one bounded burst — REQs re-issued at their persisted cursors, backlog settled, publish, fold,
  settle, pause, sockets closed. Every other pause STOPS the engine. So a "dead receive plane" now
  has one more shape: a background window with nothing publish-eligible, which drives no tick and
  therefore reopens nothing until the next foreground.)* `memberLocationsProvider`
  reads the in-memory cache only. Markers age out ~30–45 min after `expiresAt`
  (`LocationSharingService.cacheEvictionGrace`), so a dead receive plane looks like peers
  "disappearing".
- **Android background** = `flutter_foreground_task` FGS in a separate Dart isolate
  (`background_location_task.dart`): `onRepeatEvent` every 72 s → `_publishCycle` (foreground-
  active gate → Rule-14 session open/reclaim → encrypt+publish per due circle → poll-receive
  every ~120 s). MapShell hands the MLS session to the FGS on pause
  (`_handOffMlsSession` → `NostrCircleService.releaseForHandoff`) and takes it back on resume
  (`_endMlsSessionHandoff` → lazy reopen → `mls_session_handover.dart::requestSessionHandover`
  stops the FGS, waits ≤12 s, restarts it). WorkManager 15-min receive-only floor.
- **iOS background** = the main isolate kept alive by ONE Haven-owned CoreLocation session.
  Since power-plan phase P3 (2026-09-04) its owner is native — `HavenLocationStreamHandler.swift`,
  not geolocator — and the shape is set once in `init` for BOTH accuracy profiles and BOTH toggle
  states: `pausesLocationUpdatesAutomatically = false`, `distanceFilter = kCLDistanceFilterNone`,
  `activityType = .other`, `desiredAccuracy` never coarser than 100 m. What varies with the
  background-sharing toggle is `allowsBackgroundLocationUpdates` (a pure function of it, passed as
  the `listen` argument); what varies with foreground and motion is `desiredAccuracy`, between
  `kCLLocationAccuracyBest` and `kCLLocationAccuracyHundredMeters`. The
  `distanceFilter: -1` sentinel and the toggle-OFF 1 m arm described under Unit F below are RETIRED
  with the plugin path — on iOS there is no distance filter in either state. Plus native
  `HavenBackgroundSessionHandler` (`CLBackgroundActivitySession` / `CLServiceSession`), whose
  indicator/session policy is now tier-dependent (Unit F amendment below).
  Publishing continues on the normal cadence; receive rides those same publish ticks.
  *(AMENDED — power-efficiency P4: "receive = the engine socket" and "the only background healer is
  the 15-min health tick" are both FALSE now. There is no engine socket between publishes — the pause
  CLOSEs every REQ and terminates every relay — and the health tick is FOREGROUND-ONLY on every
  branch, gated both where it is armed and where it fires, because a tick landing mid-burst repaired a
  pool in the middle of `connect()` through the FOREGROUND re-anchor and left standing REQs, a socket
  and a 49 h gift-wrap replay behind at an instant that is not a publish. The bounded burst on each
  publish tick IS the background healer, at 72-168 s rather than 15 min.)*
  The self-heal timer `_liveSyncHealTimer` is CANCELLED for the whole background period
  (`map_shell.dart` `_onPaused`) — unchanged.
  SLC relaunch + `BGAppRefreshTask` are receive-only catch-ups.
- **MLS facts:** epochs advance only on membership changes (`enablePeriodicSelfUpdate = false`,
  M5). OpenMLS `SenderRatchetConfiguration::default()` = `(out_of_order_tolerance 5,
  maximum_forward_distance 1000)`; MDK does not override it (grepped: zero matches).

## 4. Ranked causes

### C1 — Android: the Rule-14 MLS guard is orphaned inside the live process
**PERMANENT. Survives every reopen. Clears only on Force Stop / reboot.**

- `map_shell.dart` `_handOffMlsSession` awaits `_liveSync.stop()` on EVERY Android pause with
  background sharing on.
- `LiveSyncCore::stop` joins the supervisor tasks under a 5 s budget
  (`haven-core/src/relay/live_sync/session.rs` `STOP_JOIN_BUDGET`). On `StopOutcome::TimedOut`,
  `LiveSyncFfi::stop_session` calls `reinstall_after_timed_out_stop`
  (`haven/rust_builder/src/api.rs`), which puts the core — holding `Arc<CircleManager>` and
  therefore the `LiveSessionGuard` (`haven-core/src/nostr/mls/storage.rs` `LIVE_SESSIONS`) —
  BACK into the process-global `SESSION`, and returns `Err`.
- `NostrSubscriptionService.stop()` swallows that error (`debugPrint`), nulls `_engine`, and
  disposes only the FRB handle. `releaseForHandoff` then disposes the foreground's own manager.
  The guard is now held by a Rust static that no Dart handle in any isolate references.
- FGS side: `_ensureSession` → guard held → `_attemptSessionReclaim` → liveness probe → main
  isolate answers → **declined**, every 15 min forever. Foreground side on resume: `initialize()`
  open fails → `requestSessionHandover` stops an FGS that is not the holder → `timedOut` →
  rethrow. `forceReleaseLiveSession` is the only lever and is gated on the main isolate being
  DEAD.
- Trigger: a worker still inside a SQLCipher ingest / convergence drain at the instant of
  pause. Rare per pause; likely across a couple of hours of pocketing.
- User observes: app opens, **circle list empty, bare map, no error** (`circles_provider.dart`
  swallows every failure to `[]`). FGS notification may still read "sending and receiving".

### C2 — One stuck inbound row silently blocks OUTBOUND sends for the circle
**PERMANENT (persisted in SQLCipher). Kills send AND receive from a single event.**

- `cgka-engine/src/message_processor/mod.rs` `do_send`: if `should_queue_outbound_intent` →
  `queue_outbound_intent` (persisted `QueuedOutboundIntent`) instead of encrypting.
  `should_queue_outbound_intent` is true whenever `advance_convergence_inputs_until_settled`
  fails, i.e. whenever any stored message within `[epoch − max_rewind, epoch + max_rewind]`
  (5) is in `MessageState::Created` or `Retryable`. In a stable circle the epoch never moves,
  so that window is the circle's entire life.
- `Created` is written to SQLCipher BEFORE decryption is attempted
  (`message_processor/ingest.rs` `persist_openmls_wire_message(.., Created)` then
  `process_message`); a kill in that gap leaves a durable `Created` row. `Retryable` is written
  by the `process_message` catch-all (incl. `TooDistantInTheFuture`, see C4) and when the group
  cannot ingest.
- `SessionEffects.queued` carries the intent; Haven's `take_app_message`
  (`haven-core/src/circle/manager.rs`) ignores `queued` and returns
  `Err("send produced no ApplicationMessage publish work")`, swallowed by every caller.
  **Haven never references `SendResult::Queued` or `converge_and_drain_queued_outbound_intents`.**
- **Correction (independent review, 2026-08-28):** a current-epoch undecryptable row is given
  the TERMINAL `EpochInvalidated` disposition on the next settled convergence pass
  (`openmls_projection.rs` `message_state_for_invalidated_reason`: `message_epoch > tip →
  Retryable, else EpochInvalidated`), and Haven's `settlement_quiescence_ms: 0`
  (`nostr/mls/manager.rs`) makes every pass settle — so the common case self-heals inside the
  very `do_send` that hit it. The PERMANENT case is a row with `message_epoch > tip` inside the
  `[tip, tip + max_rewind]` ceiling (a peer on a diverged branch / C5): it stays `Retryable`
  and gates sends until Unit B's age-based sweep retires it. Haven's ignoring of
  `SessionEffects.queued` (opaque error, no surfacing) was real and is fixed by Unit B.

### C3 — Receive plane dead-but-"running": relay `CLOSED` deletes the REQ and nothing notices
**Silent background blackout. Recovers ONLY on a foreground resume >30 s after the previous one.**

- nostr-relay-pool 0.44.3 `relay/inner.rs` `handle_relay_message`: `CLOSED` with the default
  (no machine-readable prefix), `duplicate:`, `pow:`, `blocked:`, `invalid:`, `error:`,
  `unsupported:`, `restricted:` → `HandleClosedMsg::Remove` → `remove_subscription`.
  `should_resubscribe` is `false` for a missing sub → never re-issued, not even on a socket
  reconnect. `rate-limited:` / `auth-required:` → `MarkAsClosed` (re-issued only on the next
  socket reconnect).
- Haven's supervisor maps every relay message except EOSE to `Ignore`
  (`live_sync/supervisor.rs` `notification_disposition`). The 15-min health tick reacts only to
  `disconnected > 0` (`live_sync/health.rs` `health_needs_resubscribe`). The Dart self-heal
  short-circuits on `isRunning`, a shutdown flag (`live_sync_resubscriber.dart`
  `_ensureRunningLocked`). **No production code emits `SyncStatusReason::Disconnected` /
  `Reconnecting` / `RelayError`** — the pool `Monitor` is attached (`session.rs`
  `build_engine_client`) but nothing consumes it. The only repair is
  `resume_after_background` (`session.rs`), reached from `map_shell.dart` `_onResumed` behind
  the 30 s debounce, `unawaited`.
- Haven publishes with a fresh ephemeral pubkey per message to public relays
  (`PRODUCTION_DEFAULT_RELAYS`: damus / primal / nos.lol) — the shape most likely to trip a
  relay policy.

### C4 — Sender-ratchet forward-distance exhaustion
**PERMANENT, survives restart. 10–33 h to trigger — NOT this incident's onset, but a certainty
for any receiver offline ~a day.**

- Once a receiver has missed >1000 consecutive application messages from a peer
  (`openmls/src/tree/sender_ratchet.rs` `secret_for_decryption`), every later one fails with
  `SecretTreeError::TooDistantInTheFuture`. `cgka-engine` classifies only `NoPastEpochData` /
  `TooDistantInThePast` specially; `TooDistantInTheFuture` falls to the catch-all →
  `MessageState::Retryable` + `Err(EngineError::Backend)`. On re-delivery the `Retryable`
  record short-circuits to `IngestOutcome::Buffered` WITHOUT re-attempting decrypt
  (`message_processor/store.rs` `recorded_message_outcome`, `mod.rs` `do_ingest`).
- Haven maps the `Err` to `Unprocessable` + a cursor hold-back (`live_sync/processor.rs`).
  Nothing resets the ratchet because no commit ever rotates the epoch — and MDK offers no
  self-update intent; the only rekey Haven can author is a byte-identical admin-policy commit
  by the circle's SOLE admin. Design record: `docs/EPOCH_ROTATION_REPAIR_PLAN.md`.
- Sender burns a generation on every attempt including failed publishes (persisted before
  the wrap). Rate 30–100 msg/h → 10–33 h of continuous miss. The `Retryable` rows it leaves
  then also trigger C2.

### C5 — Non-`Stable` epoch state, or a hydration-quarantined group
**Silent send blackout (Recovering = receive works, send does not).**

- `cgka-engine/src/message_processor/send.rs`: "send requires Stable" →
  `EngineError::InvalidTransition` for `PendingPublish` / `Merging` / `Recovering` /
  `Unrecoverable`. `cgka-traits` `EpochState::can_ingest` excludes `PendingPublish`, `Merging`,
  `Unrecoverable`. `EpochManager` state is in-memory: cleared by a process restart, NOT a
  resume.
- A group quarantined at session-open hydration (`cgka-engine/src/engine.rs`
  `hydrate_one_stored_group` failure) returns `UnknownGroup` on every send and
  `Stale{Quarantined}` on ingest; Haven never calls `retry_hydrate_quarantined_group`
  (`haven-core/src/nostr/mls/manager.rs`, documented). Recurs at every open if deterministic.
- `PendingCommitRecovered` IS handled (folded to a `GroupUpdate`); a failed recovery quarantines.
- **`EpochManager` state clearing on a process restart is TRUE OF THE IN-MEMORY CASE ONLY — added
  2026-09-09.** Where the non-`Stable` state comes from a *staged commit on disk*, the restart does not
  clear it: the commit persists in OpenMLS's `PendingCommit`, and hydrate refuses to recover it whenever
  it removes a member. That case is C5b.

#### C5b — the durable variant of C5, which a process restart does NOT clear (the OD4-c wedge)
**Silent send blackout, PERMANENT. This is a SIXTH silent wedge in substance, and it is filed under C5
rather than as a new top-level cause only because renumbering C1–C6 would invalidate every citation in
this document and in `POWER_EFFICIENCY_PLAN.md`. Read the five-wedge framing below as five-plus-this.**

- **Mechanism.** A receive path that ingests a peer's `SelfRemove` stages a removal-bearing auto-commit
  and, per Security Rule 13, publishes it *before* applying it. A process killed between that publish
  and its confirmation leaves the group one epoch behind with the commit staged on disk while peers move
  on, and later peer commits buffer un-chainable. **Nothing recovers it at the pinned MDK rev**, for two
  independent reasons: a re-fetched own commit comes back terminal (`OwnEcho`) and is discarded, and
  hydrate short-circuits on `staged_removes_member`, so `PendingCommitRecovered` is never emitted for
  this case at all. So unlike C5 proper this is not cleared by a force-stop, and unlike C1 it is not
  cleared by a reboot.
- **Why rolling the commit back is not the fix, and this is the load-bearing fact.** At the pinned rev a
  rollback is a **permanent, silent DROP of the removal**: the engine discards its in-memory
  `SelfRemove` auto-commit schedule *before* staging, `publish_failed` does not re-arm it, and a
  redelivered proposal short-circuits on its own durable `Created` record without rescheduling. The peer
  who asked to leave would stay in the circle, deriving its keys, until some unrelated commit moved the
  epoch — a forward-secrecy failure traded for a liveness one.
- **What landed (owner decision OD4-c, both halves, 2026-09-09).** A BACKGROUND burst no longer publishes
  a removal-bearing auto-commit: it parks it as a durable per-circle obligation (the durable row written
  before the in-memory park, so a crash between the two leaves the state that reports itself) and the
  next FOREGROUND pass publishes it under the same Rule-13 ladder, retrying rather than rolling back.
  And a circle that is wedged anyway — the engine's own terminal verdict, or a parked eviction whose
  session died — is now reported as its own per-circle terminal signal naming the pseudonymous
  `nostr_group_id`, where it was previously flattened into a per-event, self-clearing status that named
  no circle. Both halves are covered by tests that redden when they break.
- **What the consumer added, 2026-09-09.** The verdict is no longer merely emitted: the live-sync status
  handler reads it ahead of its null-reason early return, resolves the circle and marks it blocked, and the
  circle-details banner NAMES that circle and offers a re-create which pre-fills its display name and
  touches the broken group not at all. It costs a delay rather than an absence: the mark requires two
  observations of the same circle in different re-anchor generations — counted off the re-anchor marker on
  the same ordered stream, not off a clock — because one verdict can race a remaining peer's healing commit,
  and telling a user to rebuild a circle that works costs them the whole roster's invitations. So the banner
  appears on the SECOND foreground open, which is the same horizon as the repair itself.
- **What is STILL SILENT or STILL TERMINAL, which is why this row stays in a failure-analysis document.**
  While a parked eviction stands in a live session it is deliberately not reported, so that circle's sends
  are refused until the next foreground pass with nothing saying so. A device wedged by a session predating
  the control carries no durable row and is undetectable. The **Android background catch-up sweep** still
  publishes a removal-bearing auto-commit rather than parking one — and that is now a FINDING rather than the
  argument this row used to record, stated at the call site and asserted by tests: a park needs somewhere to
  be redeemed and a `PendingStateRef` is valid only inside the session that staged it, so a sweep driven from
  a background isolate could never publish what it parked. What it pays instead are the two guarantees that
  are now TREE-WIDE, at the one rung all four planes share: no plane rolls a removal-bearing auto-commit back
  (`CircleManager::publish_failed`), and every plane records the obligation BEFORE it opens the
  publish-before-apply window (`CircleManager::owe_removal_publish`), so a wake window the OS ends
  mid-publish leaves a durable row the next foreground open reports. **And redemption ACROSS a session is
  impossible at this rev**: the live `PendingStateRef`s die with their isolate and hydrate short-circuits on
  `staged_removes_member`, so an obligation the foreground service or the WorkManager worker recorded is
  reported and never published. Those wedges are LOUD AND TERMINAL — repaired by re-creating the circle —
  which is strictly better than the silent permanent drop they replaced, and is not a heal.
- Full record: `POWER_EFFICIENCY_PLAN.md` §4 OD4-c and §5.4 (L-121 the decision, L-133 the
  implementation); disclosed as residual 4 of `SECURITY.md`'s "iOS background sharing: presence only at
  publish instants (P4)".

### C6 — Contributing / lesser (all verified)

- `_startLiveSync` is one-shot (`_startupTasksStarted`) and swallows failure; a failed FIRST
  start leaves `_liveSyncResubscriber` null → self-heal and `resumeAfterBackground` are no-ops
  for the rest of the process (`map_shell.dart`).
- A HANG (not a throw) inside `LiveSyncResubscriber.ensureRunning()` kills the heal timer
  permanently (re-armed via `whenComplete`).
- Worker death is invisible: `supervisor.rs` `run_receiver` matches only
  `TrySendError::Full`; `Closed` has no arm; `is_running()` stays true.
- Clock skew: a receiver whose clock is >288 s fast drops 100 % of inbound with no log and no
  cursor hold-back (`nostr/mls/manager.rs` `process_event` expiration screen). The "clock behind"
  detector needs 2 corroborating peers — **structurally unreachable in a 2-member circle**
  (`clock_skew_detector.dart`). A BACKWARD clock jump makes
  `BackgroundLocationManager.isForegroundActive()` true (negative age) and mutes the FGS.
- Handover race: `requestSessionHandover` waits ≤12 s but the FGS `onDestroy` awaits an
  in-flight publish (up to ~49 s relay retry + 30 s GPS one-shot). Transient — the heal timer
  recovers within ~2.5 min — but it makes the handover budget dishonest.
  **Fixed in Unit A**: the drain is bounded at one publish attempt and the budget derives
  from it.
- Android FGS: `RestartReceiver` is disabled by design; the repeat timer is a coroutine
  `delay()` under a partial wake lock. An FGS at `PROCESS_STATE_FOREGROUND_SERVICE` keeps its
  wake lock and network in Doze, so Doze is NOT a cause; OEM app-killers remain a separate risk.
  A declined battery-optimization exemption is never persisted or surfaced.
- **The 30 s resume debounce made a glance-and-return a total publish stop (Android, sharing ON).**
  Found and FIXED during power-efficiency phase P1 (2026-09-03), but it is a pre-existing wedge
  cause of this incident's own shape and belongs here rather than in that plan. `_onPaused` stops
  the foreground publish scheduler, the foreground-active heartbeat and the motion trigger, writes
  `markForegroundActive(active: false)` (the ownership stamp → 0) and hands the MLS session to the
  service. `_onResumed` ended the handoff and re-armed the heal timer, and then **early-returned at
  the 30 s debounce** — ahead of `markForegroundActive(true)`, ahead of the `_lastPublishTime`
  re-seed and ahead of `_startTimers()`. So a pause→resume inside 30 s — a shade pull, a
  notification tap, an app switch and back — left the app in a state where NOBODY published: the
  foreground scheduler was stopped and not re-armed, while the service, which the ended handoff had
  just locked out of the MLS database, could not open it either and its reclaim correctly declined
  against a provably alive UI. The exact consequence matters because it is the opposite of the
  reassuring reading: this is not "the FGS takes over after 144 s". The ownership stamp stays 0, so
  the service never even reports itself gated out, and the notification goes on saying
  `fgsNotificationSharing` — "sending and receiving" — for as long as the user keeps glancing.
  Every subsequent glance inside 30 s of the last one renews it; only a resume that finally lands
  outside the window restores publishing.
  **Fix (P1):** the resume sequence is reordered so that everything a paused app must undo runs
  BEFORE the debounce — `resumeStream()` → `locationAccessProvider.resume()`/`refresh()` → the whole
  Android reclaim block (`markForegroundActive(true)`, drain wait, notification text,
  `_lastPublishTime` seeded from `readLastPublishTime()`) → `_endMlsSessionHandoff()` →
  `_healLiveSyncIfStopped()` → an unconditional, idempotent `_startTimers()` → and only then the
  debounce, which now guards the one-shot resume extras alone. Held by the source-order family in
  `map_shell_location_access_lifecycle_test.dart`: `'the reclaim block and _startTimers() precede the
  debounce'` requires `markForegroundActive(active: true)`, `waitUntilIdle()`,
  `readLastPublishTime()` and `_startTimers()` to appear ahead of the `_resumeStopwatch.isRunning`
  guard, and `'the debounced early return carries no repair of its own'` fails if anything
  load-bearing is left trapped below it.

### Downgraded hypotheses (kept so nobody re-investigates them)

- **iOS OS suspension while stationary.** Apple DTS: the iOS 16.4+ suspension applies to apps
  running BOTH `startUpdatingLocation` and SLC with *low accuracy + a distance filter*, and is
  avoided by `showsBackgroundLocationIndicator = true`. Haven: best accuracy, indicator on,
  `pausesLocationUpdatesAutomatically = false`. The tester's permanent indicator is consistent
  with an alive process. Apple's stated requirement for continuous background updates is still
  `distanceFilter` UNSET / `kCLDistanceFilterNone`. Haven set `1` when this was written; fix F
  landed it (`_kIosNoDistanceFilter` = `-1`, `geolocator_location_service.dart:659`) on the
  toggle-ON arm only.
  **Amended 2026-09-04 (power plan P3) — read the DTS text again, because this paragraph is the
  one the indicator policy was resting on.** The indicator is offered there as an ALTERNATIVE to
  the delivery shape, not as a requirement stacked on top of it: an app keeps delivering in the
  background either with `allowsBackgroundLocationUpdates = true`, no distance filter and an
  accuracy no coarser than 100 m (indicator OFF), **or** with the indicator ON and anything. So
  under a POSITIVELY CONFIRMED Always — where P3 clears
  `showsBackgroundLocationIndicator` and releases the `CLBackgroundActivitySession` — the
  indicator is no longer part of the anti-suspension posture, and the whole weight sits on the
  16.4 shape, which `HavenLocationStreamHandler.init` now pins for both accuracy profiles. Under
  When-In-Use, under a provisional Always and on iOS 17 the indicator remains, is mandatory, and
  the activity session is still held. **This is the un-evidenced half of P3:** whether the
  shape-only posture survives HOURS of a stationary desk is UNKNOWN (V-P3-3), no simulator can
  answer it, and the closest physical neighbour of that configuration is what failed on
  2026-08-20. See `docs/M7_BACKGROUND_SHARING.md` §6 item 0a (DEFERRED, still authoritative) and
  `docs/POWER_EFFICIENCY_PLAN.md` §5.3 Risks / rollback for the containment and the one-line
  revert.
- **Android Doze / wake lock** — see C6.
- **`circlesProvider` cached `[]` during the handoff window** — requires a provider
  re-evaluation while `_handoffHolds`, which nothing normally triggers on Android (engine
  stopped) and is impossible on iOS (no handoff). Still worth invalidating on resume (fix C).
- **Sender-side generation rollback / duplicate-delivery `SecretReuse`** — refuted (advance
  persisted before wrap; `MessageId` = event id, dedup before peel).
- **Rule-14 across processes** — refuted (no `android:process`, one iOS target).
- Flutter dispatches `PlatformDispatcher.initialLifecycleState` to observers, so on an iOS SLC
  background relaunch MapShell gets `paused` on the bg-sharing branch (which stops nothing) and
  `MapPage` restarts the geolocator stream inside an SLC-triggered launch — the one background
  case Apple permits. iOS MAY therefore resume publishing after a jetsam kill + ≥500 m movement.
  **CLOSED by P3 (2026-09-04): a relaunch is receive-only BY CONSTRUCTION, on both paths.** As
  written above this contradicted `INV-L-IOS-WAKES-RECEIVE-ONLY`
  (`docs/privacy/privacy_invariants.json`), which promises every iOS wake path is receive-only,
  and the hole was real: a relaunched process's cold-start publish reaches `getCurrentLocation()`,
  whose backgrounded shortcut used to be keyed off `_foregroundActive` — a field that defaults
  `true` and is written only by `MapShell._setForegroundActive` off the `paused` lifecycle
  dispatch — so if that dispatch was not delivered on a background launch the plugin one-shot
  would start a `CLLocationManager` from the background. Both halves are now shut: (a) the native
  updates owner's `onListen` refuses a background-capable start while
  `applicationState == .background` and reports the refusal through the event sink, and (b) the
  cold-cache shortcut reads the NATIVE lifecycle (`IosLocationSource.status().backgrounded`,
  fail-closed — an unreadable status counts as backgrounded), so the plugin one-shot is
  unreachable from a background-launched process rather than merely unlikely. A relaunch can
  therefore catch up on what peers sent; it cannot resume this device's own publishing until the
  user reopens the app. The remaining wake paths (SLC, region, `BGAppRefreshTask`) carry no
  publish call site at all, which is the other half of the same invariant.

## 5. Mapping to the field evidence, and how to distinguish the causes

Most likely story: the Android phone hit C1 (or C2) → stopped publishing AND receiving; the
iPhone kept publishing (blue indicator) but its live REQ was gone (C3) or it had nothing to
receive. Reopening changed nothing: C1/C2 survive a resume; C3 is repaired only on a resume
>30 s after the previous one.

| Check | Points to |
|---|---|
| Open Haven on Android: **empty circle list + bare map, no error** | C1 (DB unopenable) |
| **Force-stop both apps, relaunch.** Recovers → in-process (C1/C3). Does not → persisted (C2/C4/C5, and C5b — the one case a *reboot* does not clear either) | the single highest-value experiment |
| Circle-details epoch differs persistently between the two phones | fork → C5 |
| Debug log `send produced no ApplicationMessage publish work` | C2 |
| Debug log `Removing subscription.` (nostr-relay-pool) | C3 |
| Debug log `live session did not stop cleanly` / `[live_sync] stop:` without clean teardown | C1 |
| Debug log `[BackgroundTask] reclaim: declined, main isolate alive` every ~15 min | C1 |
| `[LiveSyncResubscriber] engine stopped — self-heal restart` NEVER appears while a peer is invisible | engine reports RUNNING → C3 |
| SQLCipher: message rows in `Created`/`Retryable` within ±5 of the group epoch on a quiet circle | C2 (smoking gun) |
| `date` on both phones to the second | clock skew (C6); the banner cannot fire in a 2-member circle |

Every one of these failure modes is COMPLETELY silent to the user: the only map banners are
`LocationAccessBanner` and `ClockSkewBanner`, and `syncStatusProvider` can never show a relay
problem because nothing emits one. That silence is itself a defect (fix D).

## 6. How the reference apps stay reliable

Life360 / Find My / Snapchat do not have a cleverer keep-alive. They (a) layer wake sources —
significant-location-change PLUS a region monitor around the current fix so termination is
always recoverable; Android FGS + WorkManager floor (+ push for the big players, rejected here
on privacy grounds, see `docs/M7_BACKGROUND_SHARING.md` §A) — (b) assume the process dies and
make every restart path idempotent, and (c) never let a dead pipeline look healthy: per-member
"last updated X min ago" and an explicit "sharing paused" state.

**Retracted 2026-08-30 (P0 doc-drift sweep).** The list above also used to claim these apps run
"iOS legacy `startUpdatingLocation` with `kCLDistanceFilterNone`, best accuracy, indicator on".
That was UNCITED — nothing in this document, its sources, or `docs/POWER_EFFICIENCY_PLAN.md`
§7.6's research set supports it — and the field evidence contradicts it. That configuration is
precisely what Haven itself runs (`geolocator_location_service.dart:657-667`); it drained both
test phones, and under a When-In-Use app doing background location the blue pill it produces is
mandatory — yet none of the three reference apps shows a constant pill
(`docs/POWER_EFFICIENCY_PLAN.md` §1 field report and §1.1 R-A/R-B, 2026-08-29). Do not re-cite
the sentence, and do not use it to justify keeping Haven's continuous best-accuracy session. Haven already has the layering;
it lacks a liveness check that measures DELIVERY rather than a flag, recovery that does not
require the process to die, and any visibility.

## 7. Fix plan — work units

Ordering: A and D first (A is the most probable permanent wedge; without D nobody can tell which
fix worked), then B and C, then E and F. Every unit: smallest correct implementation; a test that
FAILS when the promise breaks; no stubs; no weakened tests; stage only, never commit
(`feedback_never_commit_on_user_behalf`); never `dart format .`; FFI changes go through
`scripts/regenerate_frb.sh`; crypto/MLS-touching code gets a security review.

### Unit A — Kill the Rule-14 orphan (C1) and make the handover honest
**Status:** IMPLEMENTED + REVIEWED (APPROVED with minor fixes applied)

**Implementation notes**
- `NostrCircleService` gained two sibling seams next to `sessionHandover` (now returning
  `HandoverOutcome`, not `bool`): `isSessionLive` + `forceReleaseLiveSession`, wired ONLY in
  `circleServiceProvider`. `_recoverHeldSession` retries the open exactly once — immediately
  on `released`, or after a force-release on `timedOut` **and only with the registry re-read
  as still held**. `timedOut` is the sole eligible verdict (`backgrounded` would end
  background sharing; `stopFailed` and `notHeld` establish nothing about who holds the guard),
  and a `noSession` release positively freed nothing so it buys no retry.
  `withInjectedManager` nulls both seams, so the background isolate keeps exactly one
  liveness-probed route to that call.
- `SubscriptionService.stop()` returns `LiveSyncStopOutcome` (`idle`/`stopped`/`stillHolding`);
  `NostrSubscriptionService` retries a failed `stopSession()` once (Rust reinstalls the wedged
  core into `SESSION`, so the second call re-joins the same handles) and **latches**
  `stillHolding` until a successful `start()` — otherwise the next stop would answer `idle`
  while the guard was still held. `_handOffMlsSession` returns whether the handoff happened;
  on `stillHolding` it declines `releaseForHandoff` entirely AND sets an honest notification
  ("Haven is paused — open the app to resume sharing") instead of claiming it is sending.
- FGS teardown is now TWO drains. The location publish is bounded by
  `kBackgroundTeardownDrainBudget` (15 s = one relay attempt) and may be abandoned — a lost
  sample, no staged commit. The commit-critical window (`fetchMemberLocations`, which can
  publish *and confirm* a receiver-side auto-commit) is tracked separately in
  `_inFlightCommitCritical` and drained **unbounded**, because cutting it between
  `publishEvent` and `confirmPublished` breaks Rule 13 and wedges the group in
  `PendingPublish`. Plus `_shuttingDown` checks before each `encryptLocation` and each fetch,
  a GPS one-shot raced against `_shutdownSignal`, and `_ensureSession` refusing while stopping.
  `handoverTimeout` derives from the budget (15 + 5 = 20 s); its doc is explicit that this
  bounds the WAIT, not the release — an abandoned publish keeps its `Arc<CoreCircleManager>`
  until its ladder ends, which is why a `timedOut` handover leads to the force-release retry
  rather than a dead end.
- New CI guard `scripts/ci/check_teardown_drain_budget.sh` (+ `--self-test`, wired as two
  steps in `repo-guards.yml`) pins the Dart budget against `CONNECTION_TIMEOUT +
  DEFAULT_TIMEOUT` in `haven-core/src/relay/manager.rs` across the language boundary.
- Seams left for later units: `onStopOutcome` is exposed but unwired (Unit D routes it into
  `syncStatusProvider`).
- CLOSED in the polish pass (was not Unit A's): all three FGS notification strings are now ARB
  keys (`fgsNotificationSharing` / `fgsNotificationPaused` / `fgsNotificationOpen`), resolved in
  the UI isolate via `appLocalizationsProvider` and passed in — the service isolate has no
  localizations of its own.
- No FFI/Rust change: `isSessionLive`, `forceReleaseLiveSession` and `ForceReleaseOutcomeFfi`
  already existed, and the retry's premise ("a retained handle is still joinable once its task
  completes") is already pinned by `a_timed_out_join_keeps_its_handles_so_a_retry_stays_truthful`
  in `haven-core/src/relay/live_sync/session.rs`.

**Review fixes (mutation-verified)**
- The `stillHolding` decline guard was satisfied by an unrelated `return` further down
  `_handOffMlsSession`, so deleting the decline left it green; it is now anchored on the first
  statement of the release path. `session_reclaim_gate_test.dart` matched only
  `forceReleaseLiveSession(`, so the UI isolate's **tear-off** wiring added a whole second
  route to the destructive call without tripping it; the scan now matches call, tear-off,
  named-argument and parameter forms, asserts the sanctioned file SET (three: the FGS, the
  provider wiring, the service that consumes the seam), and a new group pins the UI route's
  own gates — `timedOut`-only allow-list, registry re-read with no `await` between it and the
  call, fail-closed on an unanswerable query, no loop.
- Re-check round: the latch's fail-closed half had no test — discharging `_stopLeftGuardHeld`
  before `startSession()` resolved survived the whole file, so a start that Rust REFUSED
  (because the wedged core would not stop) read as proof the guard was freed; now pinned by
  `a FAILED start does not discharge the latch`. And the route regex missed a `;`-terminated
  tear-off (`final probe = forceReleaseLiveSession;`), which is a complete route with neither
  a parenthesis nor a comma; the suffix class now includes `;`.

### Unit B — Handle queued outbound intents and stuck inbound rows (C2, C4-adjacent)
**Status:** IMPLEMENTED + REVIEWED (both halves APPROVED; fixes applied)

**Implementation notes (2026-08-28).** Files: `haven-core/src/circle/error.rs`,
`haven-core/src/circle/manager.rs`, `haven-core/src/nostr/mls/manager.rs`,
`haven-core/src/nostr/mls/types.rs`, `haven-core/tests/deferred_location_send_repair_e2e.rs`.

- **The `Deferred` shape is an error variant, not a success enum.**
  `CircleError::SendDeferred { unresolved_inputs: usize, discarded_intents: usize,
  repaired: bool, work: DeferredWork }`. The three scalars are counts and a flag;
  `DeferredWork { commits: Vec<CommitToPublish>, proposals: Vec<Event> }` has a hand-written
  presence-only `Debug`, so the variant's derived `Debug`/`Display` still carry no group id,
  message id, epoch or ciphertext (same posture as `LastMemberAbandon`). Chosen over a new
  `Ok`-side enum for two reasons: the caller genuinely has no location event to publish, and
  every existing `encrypt_location` caller — including the two inside `src/relay/**`, which
  this unit may not edit — keeps compiling unchanged. The FFI pass must classify it by
  **matching the Rust variant** in `api.rs`, never by testing the flattened error prose (Haven
  forbids substring classification of error strings; see
  `nostr::mls::storage::is_session_live`), and it must expose `work.commits` so Dart can run
  the Rule-13 ladder it already has for `DecryptedIngest::auto_commits`.
  `CircleManager::deferred_send_outcome` is deliberately send-kind-agnostic so Unit E can reuse
  it from `take_group_evolution`: the intent discard inside the sweep is restricted to
  `SendIntent::AppMessage`, so a queued group evolution parked behind the same gate is never
  collateral. `DeferredWork` is re-exported from `crate::circle` (one added name in
  `circle/mod.rs`, which another unit also edits).
- **Sweep entrypoint for the FFI:** `CircleManager::sweep_unresolvable_inputs(now_secs: u64) ->
  Result<ConvergenceSweep>` (all circles), delegating to
  `SessionManager::sweep_unresolvable_inputs` / `…_for_group`. `ConvergenceSweep
  { disposed_messages, discarded_intents, gating_rows }` lives in `nostr::mls::types` and is
  counts-only, so it can cross the FFI and reach the UI unredacted. `gating_rows == 0`
  (`is_settled()`) mirrors the engine's own `has_unresolved_convergence_inputs` predicate
  exactly, so it is a faithful "the next send will encrypt" signal for Unit D's banner.
- **Repair entrypoint:** there is no separate one — the repair is what `encrypt_location`
  already does on a deferral: ONE mutating sweep of this circle, then `advance_convergence`,
  then a READ-ONLY re-read of the gate (`SessionManager::gating_input_count`, `ScanMode::CountOnly`)
  — a second mutating sweep would retire rows nobody asked about and report a pass the caller
  never requested. Publish work either step surfaces is handed back in `work`, never confirmed
  and never rolled back. A user-facing "repair sharing" button should call
  `CircleManager::sweep_unresolvable_inputs(now)` and read `is_settled()`. The same sweep also
  runs automatically inside `SessionManager::open_session`, so a force-stop-and-relaunch — the
  only lever the owner actually has — clears the future-epoch shape. The wall clock enters
  through `circle::manager::now_secs()`, which saturates to `0` rather than `unsigned_abs()`:
  on a pre-1970 clock the latter turns a small negative timestamp into a huge positive one and
  mass-retires rows that are seconds old.
- **The terminal disposition is application-messages-only, and that is a fork-safety rule, not
  a scope choice.** Only a `Created`/`Retryable` row that projects to
  `OpenMlsContentKind::Application` and whose outer `created_at` is older than
  `LOCATION_MESSAGE_RETENTION_SECS + RECEIVER_EXPIRATION_GRACE_SECS` (288 s) is written
  `MessageState::Failed`. Such a row was never applied: no group state changed, no epoch
  advanced, no proposal was consumed, the OpenMLS ratchet is untouched, and the receive plane's
  cursor never derived from it — so retiring it cannot fork the group. Commits and proposals
  carry no NIP-40 `expiration`, so a relay keeps them and a later delivery genuinely can
  resolve one; they are never retired at any age, and a circle stuck behind one stays stalled
  **visibly** (`repaired: false`) rather than being forked back to health.
- **A second `SqliteAccountStorage` handle on `session.sqlite` is how this is done, and why.**
  `AccountDeviceSession` exposes no storage handle, no message-state surface and no per-intent
  discard; `Engine::storage`, `queue_outbound_intent` and
  `discard_queued_outbound_intents_for_removed_group` are all `pub(crate)`; the public
  `converge_and_drain_queued_outbound_intents` (reached from Haven's existing
  `advance_convergence` call in the decrypt re-tick loop) only drains **after** convergence
  settles, which is exactly what an unresolvable row prevents. So `SessionManager` opens the
  database a second time and uses the public `cgka_traits::storage` traits plus the public
  `openmls_projection::project_mls_message`. This is **not** a Rule-14 violation: the handle
  hydrates nothing — no `EpochManager`, no OpenMLS group, no exporter secret, no signer — and
  touches only the message-record and outbound-intent tables. Every access is taken while the
  session mutex is held; `storage-sqlite` opens WAL with a 5 s `busy_timeout` and retries
  `BEGIN IMMEDIATE` with backoff (see the Dark Matter correction in
  `docs/M7_BACKGROUND_SHARING.md` §B). It opens with
  `open_encrypted_with_options(.., StorageConfig::storage_options())` — the SAME options the
  session uses, because `journal_mode` is DB-wide and persistent, so two connections opening one
  file with different options do not merely differ, the second re-writes the first's mode. Both
  properties are pinned by in-crate structural tests rather than left to review:
  `every_mls_database_open_site_is_sanctioned` (exactly two production
  `SqliteAccountStorage::open_encrypted*` sites, both inside `nostr/mls/`) and
  `the_sweeps_second_connection_touches_only_message_shaped_storage` (the reachable storage
  surface is an allowlist — group READS, message rows, the intent queue, and the read half of
  the convergence policy; never `mls_storage()`, a snapshot, a welcome or a group write). The
  sweep resolves the rewind window exactly as the engine's `convergence_policy_for_group` does
  — the PERSISTED per-group policy (`ConvergencePolicyStorage`) if one is stored, else the
  session's — and deliberately NOT `max(stored, session)`: this window sizes the GATING COUNT as
  well as the scan, so a wider one over-counts and would report a circle the engine would let
  send as permanently stalled. Matching the engine is what makes `ConvergenceSweep::is_settled()`
  a truthful "the next send will encrypt" signal. Upstream issue 2 below asks for the API that
  removes the second connection entirely.
- **Queued location intents are discarded unconditionally, not by age.** An intent is queued
  only because the circle could not send, so by the time anything reads it the fix has already
  missed a publish cycle and the next tick carries a better one. (There is also no honest age
  to test: `QueuedOutboundIntent.created_at_ms` comes from `Engine::convergence_now_ms`, which
  is elapsed time since *this engine started* — `engine.rs:1262` — not a wall clock, so it is
  neither comparable to a Unix timestamp nor stable across a restart.)
- **The corrected residual, measured shape by shape.** §4 C2's Correction is right and stands
  verbatim; an earlier draft of this unit contradicted it on the strength of a fixture that was
  itself the artifact (it minted a fresh `MessageRecord::id` while the copied payload still
  carried the SOURCE row's embedded `TransportMessage::id`, so the engine — which resolves every
  disposition by the PAYLOAD-embedded id via `project_pending_canonicalization_messages` →
  `persist_openmls_canonicalization_dispositions`, while the send gate reads `MessageRecord::state`
  — could never dispose of the row, and the gate could never stop counting it). With the id
  preserved, and using rows a real device really stored, the boundary at rev `e391adc` is:
  - a **current-epoch** application row (`Created` or `Retryable`, including the C4
    `TooDistantInTheFuture` shape) that the device has never delivered is resolved by the ENGINE,
    inside the very `do_send` that hit it: canonicalization finds it undecryptable on the
    canonical branch and writes the terminal `EpochInvalidated`. It never needed Haven's sweep.
  - a **future-epoch** application row (`tip < source_epoch ≤ tip + max_rewind`) is kept
    `Retryable` deliberately, so the commit that would make it decryptable can still arrive — and
    hydration keeps it for the same reason, so it survives a force-stop and relaunch. When that
    commit never comes, this row gates every send for the circle forever. **This is the shape the
    sweep exists for, and the only application shape that does.**
  - an unresolvable **commit** never settles and is never retired at any age — retiring one would
    trade a stall for a fork. Such a circle stays stalled, visibly (`repaired: false`).
- **Why both entry points survive that narrowing.** The session-open sweep is what a force-stop
  and relaunch needs, because hydration does not clear the future-epoch shape. The runtime path is
  what the field failure needs: an Android foreground reopen is not a process restart (§2), so
  without it a stuck circle waits for a kill the user has no reason to perform, and Unit D's
  "repair" affordance would have nothing to call.
- **Rule 13 on the send path (the second cause of a deferral).**
  `should_queue_outbound_intent` returns true PRECISELY when
  `stage_due_self_remove_auto_commit` has just STAGED a peer's eviction commit, which
  `collect_effects` drains into the deferred send's own effects. `SendDeferred.work.commits`
  carries those `CommitToPublish`es to the caller, which runs the ordinary publish →
  `confirm_published` ladder (Dart's `LocationSharingService._publishAutoCommits`). Nothing is
  confirmed here (it would apply a commit no relay acked) and nothing is rolled back: the engine
  removes the `scheduled_self_remove_auto_commits` entry BEFORE staging and `do_publish_failed`
  does not re-arm it, while a redelivered proposal short-circuits to `Buffered` — so a
  `publish_failed` here would strand the leaver in the circle permanently.
- **Tests** (`haven-core/tests/deferred_location_send_repair_e2e.rs`, 5 cases; 7 mutations, each
  caught by a named red test): the engine clears a current-epoch orphan without the sweep (the
  premise); a future-epoch row stays stuck across a reopen and only the sweep clears it; a
  future-epoch row past the horizon is retired at the next session open; a commit is never retired
  at any age; and a deferral that staged an eviction hands it back UNRESOLVED — with
  `confirm_published`'s own contract as the oracle, since it errors for a ref that was already
  confirmed OR rolled back, catching both wrong dispositions in one call. Plus in-crate structural
  guards pinning the two sanctioned `SqliteAccountStorage::open_encrypted*` sites and the
  message-shaped storage surface the sweep's second connection may reach, and unit tests for the
  age-rule boundary and the leak-free `Debug` of both new types.
**FFI + Dart notes (2026-08-28).** Files: `haven/rust_builder/src/api.rs` (+ regenerated
`frb_generated.rs` / `haven/lib/src/rust/**`), `haven/lib/src/services/circle_service.dart`,
`nostr_circle_service.dart`, `location_sharing_service.dart`,
`haven/lib/src/providers/location_publish_scheduler_provider.dart`,
`location_sharing_provider.dart`, `haven/lib/src/services/background_location_task.dart`, tests.

- **The FFI shapes.** `EncryptLocationOutcomeFfi { sent: Option<EncryptedLocationFfi>,
  deferred_send: Option<DeferredSendFfi> }` (two-`Option` struct, not a tagged enum — the house
  convention that keeps Dart `freezed` out of the bindings, as `LeavePlanFfi` /
  `DecryptOutcomeFfi` already do). `DeferredSendFfi { unresolved_inputs, discarded_intents,
  repaired, commits: Vec<CommitToPublishFfi>, proposals: Vec<String /* event json */> }` with a
  presence-only `Debug`. `ConvergenceSweepFfi { disposed_messages, discarded_intents, gating_rows,
  settled }` from `CircleManagerFfi::sweep_unresolvable_inputs(now_secs)` — Unit D's Repair
  action. The Rust field is `deferred_send`, not `deferred`, because FRB mangles the latter to
  `deferred_` in Dart (it collides with deferred imports).
- **`encrypt_location` was CHANGED, not duplicated.** A second `encrypt_location_or_defer` would
  have been the larger diff, not the smaller: `CircleService` is an abstract class with ~16
  implementors in tests, so ADDING a method breaks every one of them, while changing a return
  type breaks only the two that actually override `encryptLocation`. It also leaves no
  string-flattening path behind for a future caller to pick up.
- **Matched by VARIANT.** `Err(haven_core::circle::CircleError::SendDeferred { .. })` is
  destructured in `api.rs`; nothing anywhere tests error prose. That is a security property, not
  style: Haven's error strings interpolate remote-authored text, so a `contains` over one is a
  channel a remote party can write (`nostr::mls::storage::is_session_live`). Pinned by
  `haven/test/lints/deferred_send_routing_test.dart`.
- **Dart narrows it into sealed types**, so the compiler owns exhaustiveness at every call site:
  `EncryptLocationOutcome` = `LocationEncrypted` | `LocationSendDeferred` (service layer), and
  `LocationSharingService.publishLocation` now returns `LocationPublishOutcome` =
  `LocationPublishSent` | `LocationPublishDeferred`. A deferral is RETURNED, never thrown — it is
  a state carrying work, not a failure.
- **Rule 13 on the deferred path.** `LocationSharingService._handleDeferredSend` runs the existing
  `_publishAutoCommits` ladder over `deferred.commits` (publish → `confirmPendingCommit` on a
  ≥1-relay ack, else `failPendingCommit`), rolling back instead when the circle row is gone (no
  relays to publish to, and an unresolved ref pins the group in `PendingPublish`). Bare
  `proposals` are published with no confirm. The FGS has its own copy of the ladder
  (`_resolveDeferredCommits`) because it drives `CircleManagerFfi` directly; it registers the work
  as `_inFlightCommitCritical` so teardown cannot abandon it between publish and confirm.
- **What a deferral deliberately does NOT record:** no `notePublishAcked` (nothing was delivered
  — Security Rule 13 applies to liveness too) and no clock-skew verdict (no relay saw our
  timestamp, so feeding the detector a non-event would dilute its evidence). The two foreground
  sites call `sharingHealthProvider.recordDeferredSend(circleKey)` instead of
  `recordPublishOutcome`; the FGS has no Riverpod container and persists nothing new — its
  deferral surfaces at the next foreground open through Unit D's model, which derives the outage
  from the MISSING publish-ack timestamp.
- **Tests** (17 new; 4 mutations, each caught by a named red test):
  `haven/test/services/location_sharing_deferred_send_test.dart` (8 — the ladder confirms on an
  ack, rolls back without one, rolls back when the circle is gone, publishes proposals without
  confirming, returns typed counters, publishes no location event, and leaves the sent path
  unchanged), two routing tests in `location_publish_scheduler_provider_test.dart` (a deferral
  reaches `recordDeferredSend` and never `recordPublishOutcome`; a send still reaches the publish
  verdict — anti-vacuity), `haven/test/lints/deferred_send_routing_test.dart` (7 — the variant
  match, the absence of prose classification, the staged work crossing the boundary, and all
  three publish sites incl. the un-executable FGS), and five Rust conversion tests in
  `api.rs::deferred_send_ffi_tests` (every field including the pending token, the presence-only
  `Debug`, and the sweep mapping).
- **Review fixes (2026-08-28).** Every `as` cast on a sealed outcome is now an exhaustive
  `switch`, so a third variant is a COMPILE error at every consumer rather than a runtime failure
  on the publish path — verified by adding a probe variant: 2 consumers of
  `LocationPublishOutcome` (the scheduler and the burst publisher) and 1 of
  `EncryptLocationOutcome` (`LocationSharingService.publishLocation`) all fail to compile. The
  FGS consumes the raw two-`Option` FFI struct, which cannot be sealed, so it uses the explicit
  null-check-and-throw shape `NostrCircleService.encryptLocation` already uses. The FGS also
  publishes a deferral's `proposals` now (it silently dropped them), a deferral no longer
  increments `locationPublisherProvider`'s `published` count (a stalled burst must not read as a
  complete one), and `_resolveDeferredCommits`' `_inFlightCommitCritical` registration — which no
  behavioural test can reach — is pinned by the routing lint.
- **The subscription-health surface is wired.** The earlier note that
  `SubscriptionHealthOutcome` lacked `subscriptions_expected/live/silent` and that `HealthAction`
  had no `TargetedReanchor` is superseded: Unit C landed both in the core, and the FFI mirror,
  the Dart `SubscriptionHealthAction` enum and `nostr_relay_service.dart::maintainSubscriptionHealth`
  now carry them through.

**Upstream MDK issue 1 — `TooDistantInTheFuture` is classified `Retryable`, asymmetrically with
`TooDistantInThePast`** (to file; record the link here). The `sender_ratchet_configuration` half of
the ask lives in `docs/EPOCH_ROTATION_REPAIR_PLAN.md` §6 — cross-referenced, not duplicated here.
> **Title:** `cgka-engine`: `SecretTreeError::TooDistantInTheFuture` is persisted `Retryable`,
> asymmetrically with the past-side arm, so an undecryptable message is never given a terminal
> disposition
>
> **Body:** `ingest.rs` handles the PAST side of the sender ratchet specially:
> `process_message_error_is_too_distant_in_the_past` persists `MessageState::Failed`, tags the
> disposition `PreMembershipEvent` / `ValidHistorySnapshotMissing`, and returns
> `IngestOutcome::Stale { reason: StaleReason::PeelFailed }`. The FUTURE side of the same ratchet
> falls to the catch-all in the same `match`: `update_stored_message_state(&msg.id,
> MessageState::Retryable)` plus an opaque `EngineError::Backend`.
>
> That classification is wrong in the same way the past side would be. OpenMLS's
> `SenderRatchetConfiguration::default()` is `(out_of_order_tolerance 5,
> maximum_forward_distance 1000)`. Once a member has missed more than 1000 consecutive application
> messages from one sender within one epoch, `secret_for_decryption` returns
> `TooDistantInTheFuture` for every later message from that sender at that epoch — permanently,
> because a ratchet cannot be rewound and an application with no periodic self-update never rotates
> the epoch. The row is not awaiting anything: it is undecryptable, and it will stay undecryptable
> until the epoch moves.
>
> Two concrete costs follow from calling it retryable:
>
> - **Redelivery is silently pointless.** `recorded_message_outcome` short-circuits a `Retryable`
>   row to `IngestOutcome::Buffered` WITHOUT re-attempting decryption (`store.rs`), so every later
>   delivery of that message — and of every subsequent message from that sender at that epoch —
>   costs a fetch, a store round trip and a cursor hold-back that can never come to anything.
> - **The application cannot tell this apart from a transient failure.** `EngineError::Backend`
>   with a formatted `ProcessMessageError` is the only signal, so a client that wants to surface
>   "this peer is too far ahead; the group needs an epoch rotation" has to string-match engine
>   prose to find out.
>
> **What this issue is NOT.** An earlier draft of this report claimed such a row permanently gates
> outbound sends via `has_unresolved_convergence_inputs` → `should_queue_outbound_intent`. That was
> measured and is wrong: at rev `e391adc` a `Created`/`Retryable` application row at or below the
> group tip is given the terminal `EpochInvalidated` by the next settled canonicalization pass
> (`openmls_projection::message_state_for_invalidated_reason`), inside the very `do_send` that hit
> it. The send gate recovers on its own. The harm here is wasted redelivery and an untyped signal,
> not a wedged group.
>
> **Proposed fix:** detect `TooDistantInTheFuture` beside the existing past-side arm and treat it
> symmetrically — persist `MessageState::Failed`, tag the disposition
> `MessageDisposition::SenderRatchetExhausted`, and return a distinguishable
> `IngestOutcome::Stale { reason: StaleReason::SenderRatchetExhausted }` (new variant), so
> redelivery is classified `AlreadySeen` instead of re-buffered and an application can surface the
> real remedy without parsing an error string.

**Upstream MDK issue 2 — no public way to retire a stored convergence input or discard one
queued outbound intent** (to file; record the link here).
> **Title:** `cgka-session`: no public API to give a stored message a terminal disposition, or
> to discard a single queued outbound intent
>
> **Body:** `do_send` queues instead of encrypting whenever
> `has_unresolved_convergence_inputs` holds, and that predicate is over stored `MessageRecord`
> rows. For an application whose groups rarely change epoch, one row that can never be resolved
> permanently disables outbound sends: a `Created` row orphaned by a process kill between
> `persist_openmls_wire_message(.., Created)` and `process_message`, or a `Retryable` row from
> issue 1. Transport-level expiry makes this unrecoverable by delivery — the transport
> (Nostr NIP-40, in our case) has already deleted the event, so it can never be re-fetched.
>
> There is no public surface to resolve it. `AccountDeviceSession` exposes no storage handle
> and no message-state or queued-intent methods; `Engine::storage`,
> `queue_outbound_intent` and `discard_queued_outbound_intents_for_removed_group` are
> `pub(crate)`; and the public `converge_and_drain_queued_outbound_intents` only drains once
> `advance_convergence_inputs_until_settled` succeeds — which is precisely what the unresolvable
> row prevents. The only route left is to open a second `SqliteAccountStorage` on the live
> session's database and drive `cgka_traits::storage` directly, which is a shape no application
> should have to build.
>
> **Proposed API on `AccountDeviceSession`:**
> - `fn gating_convergence_inputs(&self, group_id: &GroupId) -> SessionResult<Vec<GatingInput>>`
>   with `GatingInput { id: MessageId, state: MessageState, content_kind: OpenMlsContentKind,
>   source_epoch: Option<u64>, transport_timestamp: Timestamp }` — exactly the rows the send
>   gate counts, so an application decides with the same information the gate uses.
> - `fn retire_convergence_input(&mut self, group_id: &GroupId, id: &MessageId) ->
>   SessionResult<bool>` — write `MessageState::Failed` for a row the application knows the
>   transport can no longer redeliver. It must REFUSE for commits and proposals: an application
>   message that never applied changed no group state, advanced no epoch, consumed no proposal
>   and left the sender ratchet untouched, so retiring it cannot fork the group — a commit can,
>   and an application cannot know a commit is unrecoverable.
> - `fn discard_queued_outbound_intents(&mut self, group_id: &GroupId, ids: &[MessageId]) ->
>   SessionResult<usize>` — the per-intent counterpart of the existing removed-group discard,
>   for transports whose application payloads are ephemeral (location, presence).

**Remaining for the FFI + Dart half:** expose `SendDeferred` as a typed Dart outcome from
`CircleManagerFfi.encrypt_location` (match the variant in `api.rs`, never the error string),
expose `sweep_unresolvable_inputs` as the "repair sharing" entrypoint, and route both into
`syncStatusProvider` with Unit D's banner.

**Original plan (kept for the record):**
- `take_app_message` must distinguish "queued" from "no work": surface
  `SessionEffects.queued` as a typed outcome (`EncryptOutcome::Deferred { reason }`) across the
  FFI instead of an opaque `Err`. Location is ephemeral: do NOT let intents accumulate — on a
  deferred send, discard the queued intent for that group (`discard_queued_outbound_intents`
  or equivalent), mark the circle "sharing paused — repairing", and run a repair
  (`advance_convergence` + `retry_deferred_peels`).
- Session-open sweep (Haven side, via the engine's storage API): a `Created`/`Retryable` row
  whose event is older than `LOCATION_MESSAGE_RETENTION_SECS + RECEIVER_EXPIRATION_GRACE_SECS`
  can never be resolved by re-delivery → give it a terminal disposition (or, if the engine
  offers no API, file upstream and gate sends on the sweep's result rather than the raw
  predicate). Classify `TooDistantInTheFuture` as terminal, not `Retryable` (upstream MDK
  issue — record the link here when filed).
- Tests: Rust integration test that a crash-orphaned `Created` row no longer gates
  `send_location` after the sweep; Dart test that a deferred send surfaces a status and does
  not silently return.

### Unit C — Measure receive liveness by delivery, not by a flag (C3, C6)
**Status:** IMPLEMENTED + REVIEWED (both halves APPROVED; all review fixes applied)

- `supervisor.rs`: handle `RelayMessage::Closed` (and `Notice`) → emit
  `SyncStatusReason::RelayError`/`Disconnected` on the bus AND force a re-`subscribe_bucket`
  for the affected sub (under the lifecycle lock). Handle `TrySendError::Closed` (worker dead)
  → status + `is_running` false.
- `health.rs` / `session.rs`: `health_needs_resubscribe` must also fire when the pool reports
  fewer live subscriptions than the active session model expects, or when a group REQ has seen
  neither EOSE nor an event within N × the publish cadence while a peer is known active.
  Consume the pool `Monitor` (`RelayStatus` changes → status events).
- Dart: take `resumeAfterBackground()` out from behind the 30 s debounce (throttled by its
  own guard — see the Dart notes); make `_startLiveSync` retryable instead of one-shot; bound
  `ensureRunning()` so a hang cannot kill the heal timer; invalidate `circlesProvider` +
  `inboxRelaysProvider` on resume. **The jittered ~10 min background re-anchor this bullet
  originally called for was built and then DELETED** — it is redundant with the health tick and
  actively harmful; see the Dart implementation notes below for the measurement.
- Tests: Rust test with the in-process relay (`nostr-relay-builder`) that a `CLOSED` is
  followed by a fresh REQ and a status event; Dart tests for the retryable start and for the
  resume re-anchor's throttle (the background-cadence tests went with the deleted timer).

Implementation notes — the Rust half (re-reviewed; fixes applied). The hooks the
Dart half wires:

- **`SyncStatusReason::RelayError` is now emitted by production code**, from two
  places: a relay `CLOSED` on a subscription we own, and the ingest worker exiting.
  Dart must stop treating `syncStatusProvider` as inert — this is the signal a
  `MapStatusBanner` (unit D) hangs off. `InboxError` is also newly emitted (a panic in
  gift-wrap serialization, previously an uncaught unwind). On the `CLOSED` path the
  repair is SCHEDULED before the status is emitted, so a consumer seeing `RelayError`
  may rely on the repair already being queued.
- **`SyncStatusReason::Connected` is the paired RECOVERY signal**, and this is new
  meaning for an existing variant: besides "all relays connected at session start", a
  successful re-issue of a lost REQ now emits exactly one `Connected` (both from the
  `CLOSED` repair and from the targeted silence re-anchor). Without it a banner raised
  on `RelayError` would stand indefinitely, because the repair is otherwise silent —
  Dart should map `connected → recordRelaySubscriptionRestored()`. A FAILED re-issue
  emits nothing, so the banner correctly stays up.
- **`SyncStatusReason::Connected` / `Connecting` / `Reconnecting` / `Disconnected`
  now arrive per relay**, from the pool `Monitor` consumer. They are per-relay
  transitions, not a whole-session verdict, so Dart must aggregate (e.g. "any relay
  disconnected") rather than render each one; `Connecting` is a first connect and
  `Reconnecting` is a live session that lost a socket.
- **`isRunning()` now means "not stopped AND the ingest worker is alive"**, so
  `LiveSyncResubscriber._ensureRunningLocked` will finally see `false` for a dead
  receive plane and restart it. It deliberately does NOT fold in "a subscription is
  missing" — that is repairable in place and `maintainSubscriptionHealth` no-ops when
  `isRunning` is false, so folding it in would disable the healer.
- **The 15-minute health tick now heals three things, not one**, and the third gets a
  DIFFERENT remedy. A dropped relay or a REQ missing from the pool still triggers the
  whole-session `resume_after_background`. Delivery silence — a **group** REQ that has
  delivered neither an event nor an EOSE for `3 × LOCATION_MESSAGE_RETENTION_SECS`
  (684 s) — re-issues only the `(relay, sub)` endpoints that went quiet, through the
  same jittered backoff a relay `CLOSED` uses. The inbox plane is exempt from the
  silence arm entirely: a quiet inbox is the NORMAL state, and at the time this landed its
  REQ carried a seven-day gift-wrap lookback in every phase, so an arm that fired on it
  would have every device ask its relays to replay a week of wraps keyed on its own `#p`
  every ~15 min forever — battery, relay load, and a standing re-advertisement of the one
  query that links this npub to itself. **Amended 2026-09-03 (power-efficiency P1): the week-long window is
  now the COLD-START one only.** `since_for_stream` matches the inbox branch on
  `SubscribePhase` (`cursor.rs:348-353`), so `Initial` keeps
  `INBOX_GIFTWRAP_LOOKBACK_SECS` (7 days, `cursor.rs:88`) and every `Resubscribe` — which
  is every re-anchor, every `CLOSED` repair and every health-tick re-issue — asks for
  `INBOX_RESUBSCRIBE_LOOKBACK_SECS` = 2 d + 1 h = 49 h (`cursor.rs:142`), sized to cover
  NIP-59's 48 h gift-wrap backdating plus an hour of clock skew. The exemption itself is
  unchanged and still correct: a quiet inbox is still the normal state, and 49 h replayed
  every ~15 min forever would still be the wrong trade. A relay ending the inbox REQ is
  still caught, by the subscription-presence arm. **`HealthAction::Healthy` therefore stays reachable on a
  normal device**, which is what makes the tick's report meaningful to unit D. ~~This
  tick is the ONLY background re-anchor: the Dart half deliberately adds none, because
  `_runHealthTick` has no foreground gate and so keeps running on the one branch a
  Dart timer could have covered (iOS background sharing, where the process stays
  executable by design)~~ **CORRECTED — power-efficiency P4: there is NO background
  re-anchor at all now, and `_runHealthTick` DOES have a foreground gate.** The tick is
  foreground-only on every branch, gated at both ends — the single arming site refuses
  while backgrounded and the pause cancels all three maintenance timers, and the tick
  itself re-reads the foreground state before it runs, for a timer armed in the
  foreground that fires after the pause. The carve-out that kept it armed on the iOS
  background-sharing branch became a live defect once P4 removed the standing
  subscription it existed to repair: `maintain_subscription_health` short-circuits only
  when `paused` is true ON ENTRY, and a burst clears `paused` for its whole duration, so
  a tick landing MID-BURST read a pool in the middle of `connect()` as dropped and
  repaired it through `resume_after_background()` — the FOREGROUND entry, which carries
  the inbox REQ at any `k` — leaving standing REQs, an open socket and a 49 h gift-wrap
  replay keyed on this npub at an instant that is not a publish, persisting to the next
  burst's pause. At a 15-min tick against a 72-168 s burst that is expected roughly one
  to three times per 8-hour background window. The BURST is the background repair now.
  See the Dart notes.
- **A relay `CLOSED` now heals in seconds, not at the next tick.** A new joined
  supervisor task re-issues the exact `(relay, sub)` under the lifecycle lock, with a
  jittered per-key backoff (immediate for the first `Remove`-class close, full
  `BACKOFF_MAX_SECS` for `rate-limited:` / `auth-required:`). Nothing in Dart needs to
  drive it.
- **No new FFI was added and none is strictly required.** If unit D wants to
  distinguish "worker died" from "a relay ended our REQ" in the UI, that needs either
  a new `FfiSyncStatusReason` variant (e.g. `ReceivePlaneDown`) or a new counter on
  `SubscriptionHealthOutcomeFfi` — `SubscriptionHealthOutcome` was deliberately left
  field-identical so `rust_builder/src/api.rs` did not have to change in this unit.
  The health snapshot already carries `subscriptions_expected` /
  `subscriptions_live` / `subscriptions_silent` in Rust; surfacing them is a one-line
  FFI addition when unit D needs them.
- **The health tick now reports what it SAW, not just what it did** (landed across all
  three layers in one change, so the exhaustive FFI `From` impls never broke).
  `SubscriptionHealthOutcome` / `SubscriptionHealthOutcomeFfi` /
  `SubscriptionHealthResult` gained `subscriptions_expected` / `subscriptions_live` /
  `subscriptions_silent` (Dart: `subscriptionsExpected` / `subscriptionsLive` /
  `subscriptionsSilent`), all zeroed by `engine_off()` and the `.empty()` fallback.
  The `expected − live` shortfall is the ONLY counter that can show a receive blackout
  behind a live socket: the relay stays connected, so `relaysDisconnected` reads 0
  throughout. `subscriptionsSilent` is not a failure signal on its own — an idle
  circle is legitimately silent forever.
- **`HealthAction::TargetedReanchor` is a fourth action** (FFI
  `SubscriptionHealthActionFfi::TargetedReanchor`, Dart
  `SubscriptionHealthAction.targetedReanchor`), so the two re-anchor remedies are
  distinguishable: `Resubscribed` is the whole-session reconnect-and-re-issue,
  `TargetedReanchor` is the per-endpoint silence repair. They differ by orders of
  magnitude in cost, and the targeted one is EXPECTED on an idle device — collapsing
  them would show a normal quiet device as one that keeps losing its relays. For "did
  the receive plane get repaired?" purposes a consumer treats it exactly like
  `resubscribed`; the maintenance tick already does. Everything stays presence-only
  (counts + closed enums).

Rust-half review round 1 (independent, APPROVE-WITH-FIXES) — all applied:

- **MAJOR** the silence arm counted the inbox AND escalated to a whole-session
  re-anchor, so it fired on essentially every tick on every device (684 s window <
  the 900 s tick) and made `Healthy` unreachable — each firing re-issuing every REQ
  on every relay plus a seven-day inbox replay. Inbox silence deleted; group silence
  now re-issues only the quiet endpoints. See the health-tick note above.
- **MINOR-1** a re-issue wiped hold-backs no `EOSE` had yet applied, so a co-bucketed
  relay's stale `EOSE` could redeem the repair's new generation and advance the cursor
  over un-applied events (previously masked by the 60 s resubscribe buffer).
  `CursorAnchors::open_generation` now carries an unapplied hold-back forward, and
  `consume_eose` clears it as it folds it into an advance — so one forged event buys
  one held-back advance, never a permanent pin. The `RawSignal` doc no longer
  overclaims what one channel fixes.
- **MINOR-2** the delivery clock was per circle, so a relay re-subscribing every few
  seconds kept a bucket's clock fresh and masked silence on its other relays. Now
  keyed per `(relay, subscription)`.
- **MINOR-3** a `CLOSED` dropped by a full intake queue now has an explicit arm
  documenting that the subscription-PRESENCE arm (not the silence arm) is its
  deterministic backstop, and why recording it from the receiver would violate Rule 12
  (no router there, so a relay could grow the backoff table with invented sub-ids).
- **MINOR-4/5 + NITs** the `lifecycle` field doc now names `run_repair` as a
  relay-triggered acquirer and states what bounds `stop`'s wait on it;
  `stop_drains_every_supervisor_task_including_a_pending_repair` pins the C1-orphan
  regression; `matching_relay`'s rationale, the `Throttled` due-time (it may now only
  push a re-issue out, never pull it in), the repair table's bound, and two
  assertion-message space runs are corrected.

Rust-half review round 2 (independent, APPROVE-WITH-FIXES) — all applied:

- **BLOCKER-1** `note_subscription_closed` emitted `RelayError` BEFORE queueing the
  repair, so the status published a state that had not happened yet; the two are
  swapped and the order is now documented as a contract. Proven load-bearing: with the
  old order plus a 50 ms insert, the ownership test goes red.
- **BLOCKER-2** the full-intake-queue test drained and refilled the channel, so the
  `CLOSED` could be forwarded into the freed slot. Rewritten to fill the queue once
  and never drain it — both notifications are then necessarily dropped, and the oracle
  is that the broadcast empties (which the receiver can only achieve by continuing
  past the first). No ordering assumption remains.
- **A third flake, found by the mandated 5× run and not present in the review:**
  `a_repair_waiting_for_the_lifecycle_lock_still_exits_on_cancel` asserted
  `pending_len() == 1` after queueing, which races the repair task's own `take_due`
  (4/10 failures). The precondition now asserts the queue is empty BEFORE queueing;
  reaching 0 afterwards is then a sound happens-before edge, since only `take_due`
  lowers it. 30/30 green after, and the test still fails under the unconditional-lock
  mutation.
- **MINOR-A** the "a `CLOSED` is not a delivery" guard was untested (deleting it left
  the suite green); `a_closed_is_not_counted_as_a_delivery` now pins it.
- **MINOR-B** the stale "re-anchors EVERY subscription" wording on
  `maintain_subscription_health` and `HealthAction::Resubscribed` now names both
  remedies and their scopes.

Implementation notes — the Dart half (2026-08-28). Files:
`haven/lib/src/pages/map_shell.dart`, `haven/lib/src/services/live_sync_resubscriber.dart`,
`haven/lib/src/providers/service_providers.dart`, plus
`scripts/ci/check_live_sync_restart_budget.sh` (+ two steps in `repo-guards.yml`).
No FFI change.

- **There is now exactly ONE engine start path, and it is the self-heal.** `_startLiveSync`
  no longer calls `start()` itself; a new `_ensureLiveSyncInstalled()` builds the
  `LiveSyncResubscriber` from the circle snapshot ALONE — before any session exists — and
  `ensureRunning`'s `_fullRestart` performs the first start. That is what makes both halves of
  C6's first defect go away at once: the install is retried on every heal tick (so a transient
  roster read failure costs one tick, not the process), and a failed first start can no longer
  leave `_liveSyncResubscriber` null, which was what made `_healLiveSyncIfStopped` return
  immediately forever and `resumeAfterBackground()` a no-op against a null engine. It also
  satisfies Rule 14 more strongly than before: every start is now serialized on the
  re-subscriber's `_chain`, where the old direct `start()` was not. That forced
  `_ensureRunningLocked`'s `_running.isEmpty → false` guard out, which is itself a fix: the
  inbox REQ (kind 1059 gift wraps) is how invitations arrive and exists independently of any
  circle, so refusing to restart an empty set left a brand-new account — the one account
  guaranteed to have no circles — with no live invitation delivery. The test asserting the old
  rule was rewritten to pin the corrected one (it now also asserts the inbox relays are
  passed), not deleted.
- **`ensureRunning()` is unstrandable in both directions.** A throw out of the chained body
  used to leave the `Completer` uncompleted AND leave `_chain` errored — and `.then` on an
  errored future skips its callback, so ONE escaped throw silently disabled every later delta
  apply as well as every later heal. A hang did the same thing with no error to catch. Both are
  closed by `_chainNext` (absorbs, logs the type, keeps the chain usable) plus a
  `.timeout(kLiveSyncRestartBudget, onTimeout: () => false)`. The hung body is deliberately NOT
  abandoned — it still holds the chain, so nothing starts a second engine behind its back; only
  the caller stops waiting.
- **`kLiveSyncRestartBudget` = 65 s is derived, never chosen:** six
  `RELAY_LIFECYCLE_OP_TIMEOUT_SECS` ops (three bounded pool ops in `stop_inner`, and
  `NostrSubscriptionService.stop` retries a failed `stopSession()` once against the core that
  Rust reinstalls into `SESSION`) plus one `SUBSCRIBE_CONNECT_WAIT_SECS`. The two per-op magnitudes
  are mirrored as Dart constants and pinned across the language boundary by
  `check_live_sync_restart_budget.sh` (7 self-test fixtures, same shape as
  `check_teardown_drain_budget.sh`); the op COUNT is a structural claim no grep can check and is
  documented at the constant. 65 s sits under the heal backstop's 90 s jitter floor, so a
  bounded-out restart always re-arms before the next tick.
- **The iOS background re-anchor was BUILT AND THEN DELETED (review fix).** The idea does not
  survive contact with `since_for_stream` as it then was: its inbox branch was taken BEFORE the
  phase match, so `SubscribePhase::Resubscribe` never narrowed the inbox REQ and every
  `resume_after_background` asked for `INBOX_GIFTWRAP_LOOKBACK_SECS` (7 days) of gift wraps keyed
  on this npub — replaying
  each one through an identity-secret materialisation and an FFI NIP-59 unwrap, plus a pool
  `connect()` and a 5 s wait. Every 10 minutes, backgrounded. Its stated justification was also
  false AT THE TIME: `_runHealthTick` then had NO foreground gate, so on the very branch the timer
  targeted (iOS background sharing, where the process stays executable by design) the 15-minute tick
  kept running — probe-first, and since the Rust half repairs a dropped relay, a missing REQ and a
  delivery-silent REQ. The Dart timer was redundant at best. Deleted rather than tuned; the
  comment at the iOS pause branch now records why nothing is armed there.
  **Amended — power-efficiency P4: the second half of that reasoning has since been INVERTED, and the
  conclusion still holds.** `_runHealthTick` now DOES have a foreground gate, and the health timer is
  no longer armed while backgrounded on any branch — the carve-out that spared it became a live defect
  once P4 removed the standing subscription it existed to repair (a tick landing mid-burst repaired a
  mid-`connect()` pool through the FOREGROUND re-anchor and left REQs, a socket and a 49 h gift-wrap
  replay behind). So nothing periodic re-anchors in the background any more; the bounded burst on each
  publish tick is the repair, at 72-168 s. The deleted timer stays deleted, and for a stronger reason
  than the one written above: it would now be a second background wake source in the phase whose whole
  purpose is removing them (R14).
- **`resumeAfterBackground()` moved ahead of the 30 s resume debounce**, where it always runs.
  It is the only repair that recovers a relay-`CLOSED` REQ, and behind the debounce the glance
  pattern the debounce exists to absorb was exactly what stopped it running — so a user
  reopening the app BECAUSE peers had vanished routinely got no repair. Order on resume is now:
  end the handoff → `_invalidateHandoffWindowPoison()` → re-anchor → heal → debounce. That
  poison sweep is asymmetric on purpose: `circlesProvider` swallows every failure to `[]` and
  caches it as a SUCCESSFUL answer, so a read that lost the race with the Android handoff is
  undetectable afterwards and is invalidated unconditionally, while
  `relayPreferencesServiceProvider` and `inboxRelaysProvider` do cache an `AsyncError` nothing
  else retries but cost FFI reads (and two publish-toggle writes) to rebuild, so only a cached
  error is dropped. It runs immediately after `_endMlsSessionHandoff`'s replay so the
  possibly-empty snapshot that replay just fed the re-subscriber is superseded well inside the
  re-subscriber's own 500 ms debounce. Ahead of the debounce it also needed a throttle of its
  own (review fix): unguarded, ten shade-pull glances became ten pool reconnects and ten inbox
  replays — 7-day ones when this landed, 49 h ones since P1 bounded the `Resubscribe` phase,
  which lowers the cost of each glance but not the reason for the throttle. `MapShell.shouldReanchorOnResume` gates it on
  `kLocationPublishOverlapGuard` (60 s) — the app's existing "do not repeat a relay round-trip
  sooner than this" quantum, numerically the resubscribe clock-skew window
  `GROUP_RESUBSCRIBE_BUFFER_SECS` as well, so a re-anchor inside it re-queries a window the
  previous one already covered and can deliver nothing new.
- **Status → health wiring.** `recordRelaySubscriptionSignal` (named, `@visibleForTesting`, in
  `service_providers.dart`) maps `relayError → recordRelaySubscriptionLost()` and
  `connected` / `backgroundResumed → recordRelaySubscriptionRestored()`, with an EXHAUSTIVE
  switch so a new `FfiSyncStatusReason` variant is a compile error rather than a silently
  ignored signal. `disconnected` / `reconnecting` deliberately feed nothing here — they are
  per-relay socket transitions `SyncStatusNotifier` already aggregates into the phase the health
  model listens to — and `unprocessable` / `inboxError` say nothing about whether the REQ still
  exists. The router's `onStatus` guards the two consumers SEPARATELY, so a failure to reach
  either cannot cost the other.
- **A repaired `CLOSED` had no way to clear the banner (review fix).** Rust raises `RelayError`
  on every `CLOSED`, emits nothing when its own repair task re-issues the REQ, and `Connected`
  fires only on a SOCKET transition — which a `CLOSED` does not cause. So
  `paused(receiveSubscriptionLost)` was a latch with no reset: one throttled subscription on one
  relay would have left a permanent "sharing has stopped" banner up while locations kept
  arriving on the other relays — worse than the silence it replaced. `_runHealthTick` now calls
  `recordRelaySubscriptionRestored()` on `healthy` or `resubscribed` (the tick probes the pool
  AND the live subscription model, so either verdict proves every expected REQ is present);
  `engineOff` inspected no session and clears nothing. The `connected → Restored` mapping stays,
  so a Rust-side emission on a successful re-issue will be picked up when it lands.
- **Concurrent installs are single-flighted (review fix).** Startup and a resume-driven heal
  share no lock and both park on the same `circlesProvider` read, so two re-subscribers could be
  built over one engine — two `_chain`s interleaving stop/start against a shared session, and a
  leaked `listenManual`. The re-entrancy check that shipped first had no test (removing it left
  every test green), so the latch was extracted as `SingleFlight<T>` — a `@visibleForTesting`
  class beside `MapShell`, since `MapShell` itself cannot be pumped — and its semantics are now
  proven directly: one run for concurrent callers, re-runs after settling, and the latch
  released on a throw so a failed install is retried rather than wedged.
- **Tests** (all mutation-verified to fail when their promise breaks): three
  `ensureRunning is unstrandable` cases (escaped throw answers with zero elapsed time; the chain
  still carries later applies after one; a hung start answers at the budget and starts nothing
  second) on `fake_async`; a rewritten circle-less-account case;
  `haven/test/pages/map_shell_receive_recovery_test.dart` (19 cases — the resume throttle and
  `SingleFlight` behaviourally, plus source-scan pins for the single start path, the retryable
  install, the latch, the resume ordering and the `_onPaused` cancel ordering);
  `haven/test/providers/relay_subscription_signal_test.dart` (9 cases on the real
  `sharingHealthProvider` with its injected clock — the status mapping, seven reasons that
  neither raise nor clear, the production hook, and the health tick clearing the latch through
  the real `maintenanceSchedulerProvider`). `check_live_sync_restart_budget.sh` grew an eighth
  fixture: a budget hardcoded to the RIGHT number now fails, because the guard requires the
  initializer to name all three terms it derives from.
- **A note this unit got WRONG and corrected.** The first Dart pass documented "no circles and
  no inbox relays" as unreachable, citing `InboxRelaysNotifier`'s default seeding. Both halves
  were false: `relay_settings_page.dart` marks only the PROFILE pool unremovable, so every inbox
  row offers removal, and `seed_defaults_if_unseeded` returns early once its sentinel exists, so
  it never re-seeds a list the user emptied (the `fallbackDefaultRelays` path only covers a
  seeding THROW). The state is reachable. It fails safely — with no relays the bucket subscribe
  never gets a REQ accepted, so `start_session` tears down and errors instead of installing a
  session that reports `isRunning` while issuing zero REQs, and the heal backs off visibly — so
  no branch was added; the comment now says that instead of the opposite.
- **Known gap.** `docs/M11_ROLLOUT.md`'s startup table still describes engine start as
  `_startLiveSync() → subscriptionServiceProvider → LiveSyncFfi.start_session`. That is still
  true end to end, but the hop is now through the re-subscriber; its line numbers were already
  stale and the file is outside this unit's owned set, so it was left alone rather than
  half-corrected.

### Unit D — Make every silent failure visible
**Status:** IMPLEMENTED + REVIEWED (APPROVED with fixes applied)
- Persist per-circle `last_publish_acked_at` and `last_peer_event_at` (presence-only
  timestamps, SQLCipher `circles.db`), written by both isolates.
- Route `encrypt_location` / publish failures into the health model. **DONE** — the three Dart
  publish sites record their outcome instead of dropping it.
- ~~Route deferred sends (B), engine `Unprocessable` / `Quarantined` / `Unrecoverable`, and relay
  `CLOSED` (C) into `syncStatusProvider`.~~ **DEFERRED to Units B and C**, which own those
  emitters. D emits none of them: it CONSUMES `syncStatusProvider` (the disconnect phase) and
  exposes two typed entry points, `recordDeferredSend` / `recordRelaySubscriptionLost`, for B and
  C to call. Both are implemented and tested here; neither has a production caller yet.
- UI: a `MapStatusBanner` naming the fault and its age, with a Repair action (repair = the unit
  A/B/C recovery paths, plus Unit E's epoch repair, which runs last and only for the selected
  circle). Three of Unit E's outcomes carry their own copy, and the two terminal ones DISABLE the
  button rather than invite a retry that cannot succeed. Plus a per-member "last seen <age>" line
  in the member list. l10n ×13 with
  the mandated translate + independent-review agents and `arb_parity_check`.
- Tests: widget tests that the banner appears/clears on the status transitions; copy-accuracy
  tests per the existing `background_claim_accuracy` pattern.

**Implementation notes**

- **Storage.** New `circle_health` table in `circles.db` (`haven-core/src/circle/storage.rs`),
  keyed by the public `nostr_group_id`, holding only `last_publish_acked_at_ms` and
  `last_peer_event_at_ms`. Both advance by monotonic MAX — the foreground isolate and the
  Android FGS have independent clocks and commit out of order, and a health timestamp that could
  move backwards would manufacture an outage. Dropped with the circle in `delete_circle`, so a
  leave leaves no record of when that circle last worked. Surfaced as
  `CircleManagerFfi::{note_publish_acked, note_peer_event, circle_health}` and read in Dart
  through `CircleHealthService` (`circle_health_service.dart`), which takes the same
  `circleManagerFactory` shape as `NostrProfileService` so no second manager is ever opened.
- **The model.** `sharingHealthProvider` derives one of `healthy` / `publishFailing(since)` /
  `receiveSilent(since)` / `paused(reason, since)` for the SELECTED circle, on an injected clock
  plus a `kLocationPublishMinInterval` re-derivation tick (a silence threshold is crossed by time
  passing, and if everything is dead nothing arrives to trigger a recompute) — see "Two cadences"
  below for when that tick runs. Thresholds are all
  derived from the cadence constants: `kPublishSilenceThreshold` = 2 × `kLocationPublishMaxInterval`
  (336 s), `kReceiveSilenceThreshold` = 2 × max + retention (564 s), and every NAMED cause must
  stand for `kSharingFaultConfirmationWindow` = one max interval (168 s) before it reaches the
  user. It deliberately refuses three verdicts it cannot distinguish from ordinary quiet: a circle
  that has never published, a circle that has never received (a peer who never shared looks
  identical to a dead receive plane), and a solo circle.
- **Typed inputs for B and C, live now.** `recordDeferredSend(circleKey)` →
  `paused(sendDeferred)`, cleared by the next acknowledged publish for that circle;
  `recordRelaySubscriptionLost()` / `recordRelaySubscriptionRestored()` →
  `paused(receiveSubscriptionLost)`. Both are fully implemented and tested, and simply have no
  production caller until B and C land.
- **Cross-isolate reconciliation.** The FGS has no Riverpod container, so its publishes reach the
  model ONLY as the persisted ack — which is why `_evaluate` clears this isolate's in-memory
  failure run whenever the persisted ack is newer than it. Its RECEIVES now arrive the same way:
  `_wireSharingServices` builds the FGS's `LocationSharingService` with a
  `NostrCircleHealthService` whose factory re-reads `_circleManager` on every call (the reclaim
  path re-opens it, so a captured handle would be a disposed one). The persisted receipt stamp is
  therefore the SINGLE source of receive evidence — a cached `MemberLocation.timestamp` is
  deliberately NOT consulted, because it is the sender's clock and a peer running fast could
  otherwise suppress the banner indefinitely.
- **The foreground signal is a bare `WidgetsBindingObserver`, never
  `AppLifecycleListener`.** That class asserts on transitions it judges illegal —
  `paused` → `resumed` among them, i.e. an ordinary Android resume — and it does so
  BEFORE invoking `onStateChange`, so an unusual-but-real platform sequence becomes a
  debug-build crash rather than a missed update. Unit F rejected the same class for the
  same reason (`_ResumeReassertObserver`), every other lifecycle consumer in `lib/src`
  uses a bare observer, this app has a recorded incident of a mid-sequence assert taking
  down startup, and the E2E lanes run debug builds. `AppForegroundNotifier` now carries
  its own tests driving `paused → resumed` through the real binding, because every other
  test overrides the provider and the production class had no coverage at all.
- **Two cadences, deliberately separate.** The model re-derives on a `kSharingHealthTick` timer
  suspended whenever the app leaves the foreground (a backgrounded app has no banner, and at 72 s
  the tick would fire about twice as often as the app's own background wake rate). The BANNER runs
  its own re-render timer while mounted, because the age it prints is a function of the CLOCK, not
  of the verdict: a broken pipeline stays broken, so the verdict stops changing while the age
  keeps growing, and a banner frozen at "about 7 minutes" for an hour is a worse lie than none.
  `refresh()` carries a generation fence so a slow storage read cannot overwrite a newer verdict.
- **What "Repair" does today** (`sharingRepairProvider`, one injectable callback so A/B/C extend
  it in one place): invalidates `circlesProvider` (a failed open leaves it cached at `[]`),
  re-anchors the live-sync subscriptions via `resumeAfterBackground()` — the only repair the
  analysis found actually recovers a relay-dropped REQ — re-runs `locationPublisherProvider`, and
  re-derives the health verdict. The button keeps its label while running (a bare spinner left the
  control with no accessible name, WCAG 2.1 SC 4.1.2), and a repair that does NOT clear the
  verdict is announced, because a live region announces its appearance and never its persistence.
- **Copy accuracy.** THREE headlines, not one: only a dropped relay connection is reported as
  "Location sharing has stopped"; a failing send plane says only that sending stopped, and a
  silent receive plane only that receiving stopped. Telling a user whose sending is broken that
  all of sharing stopped would claim they also cannot see anyone, which may be false.
  Precedence in the map's single banner slot is location-access → clock-skew → sharing-health:
  a wrong clock is a CAUSE of the delivery silence, and "Repair" would republish into the same
  failure while the clock banner sends the user to the setting that fixes it.
- **l10n ×13, in two rounds.** Round 1 shipped 10 keys (translator + independent reviewer agent
  per locale). Round 2 was forced by a finding that outlived round 1: the body string renders under
  all THREE headlines, and every translator who supplied the implied subject ("*sharing* last
  worked…") produced a sentence that is false under "You are not receiving locations". The English
  was therefore rewritten as a bare noun phrase with no subject and no verb —
  `sharingHealthNoUpdates{Minutes,Hours,Days}`, "No updates for about N minutes" — then
  re-translated and re-reviewed across all 12 locales, with the constraint written into the ARB
  description so it cannot be lost again. Round 2 also added
  `sharingHealthRepairUnresolvedAnnouncement` and fixed an Arabic title that claimed "your
  circles", plural, for a single-circle verdict.
- **Known gap.** `CircleMemberTile`'s screen-reader label joins its fragments with an ASCII
  comma (pre-existing; this unit adds one more fragment to it). RTL locales would prefer their own
  separator. Fixing it properly needs a localized composer key across 13 locales and was judged
  disproportionate here — recorded rather than hidden.

### Unit E — Bound the ratchet exposure (C4)
**Status:** IMPLEMENTED + REVIEWED (all phases; both final re-checks APPROVED; minors applied) — see
`docs/EPOCH_ROTATION_REPAIR_PLAN.md` §7 (core: gate mechanisms, mutation evidence, deviations)
and §8 (FFI/Dart/guard/l10n). PERIODIC rotation
REJECTED (cannot protect the sole admin; 1.67× margin; introduces a new permanent blackout).
Ships a REPAIR-TRIGGERED sole-admin rotation + the upstream ask.

**What the review round changed, in one line each.** A send-gated repair used to BANK a queued
rotation per tap (drained later with no gates and no rate limit) — now pre-checked and taken
back. The quiescence gate read a column that is structurally absent on stuck circles — now
stamped from the receive funnels, on authenticated events only. The pending-proposal gate never
cleared, so any circle that had ever had a departure was permanently unrepairable — now bounded
by the proposal's epoch. `Unrecoverable` no longer masquerades as "try again shortly". An
unserializable staged commit is rolled back instead of pinning the group in `PendingPublish`.

**The user-visible shape.** Unit D's Repair button now runs one more leg, last and only for the
selected circle: the epoch-rotation repair. Three of its outcomes get their own copy, because
collapsing them would either invite a retry that cannot succeed (`notSoleAdmin`,
`epochUnrecoverable` never clear by waiting) or claim a recovery that has not happened — peers
apply the commit on their own next epoch pass, so the success copy says the repair was SENT, not
that sharing works again. `self_update_provider.dart` (a documented no-op) is deleted, and a new
`scripts/ci/check_epoch_repair_isolation.sh` keeps the repair foreground-only and unschedulable.

**Two findings this unit surfaced but does NOT fix**, both recorded in
`docs/EPOCH_ROTATION_REPAIR_PLAN.md` §5.1/§6 and tracked as "Unit G": the engine re-reads the
group's whole retained message history on every send (**measured at MDK `e391adc`**: 0.31 ms per
retained row at `opt-level = 2`, against a flat 0.8 ms for the OpenMLS-only control, so the cost is
the row walk and not the crypto; ~10 k rows/week at 30 fixes/h/member — a CPU, and therefore battery,
and latency cost on every publish, this one genuinely measured rather than an output of estimation
model E, `docs/EPOCH_ROTATION_REPAIR_PLAN.md` §5.1 carries the bench), and the only
spec-safe prune is upstream-first because a Haven-side one would need a third `session.sqlite`
open site that the Rule-14 guard forbids.
- Upstream: ask MDK to expose `sender_ratchet_configuration` and raise
  `maximum_forward_distance` (forward derivation is cheap; only `out_of_order_tolerance` costs
  memory). Record the issue link here.
- ~~Haven: a LEADER-ELECTED periodic self-update~~ — **REJECTED and superseded.** Periodic
  rotation cannot protect a sole admin from its own outage, has only a 1.67× margin, and adds a
  new permanent blackout mode; see `docs/EPOCH_ROTATION_REPAIR_PLAN.md` §3. What shipped is a
  REPAIR-TRIGGERED, admin-only, rate-limited rotation with no scheduler anywhere.

### Unit F — Platform hygiene
**Status:** IMPLEMENTED + REVIEWED (APPROVED with cosmetic fixes applied)
- iOS: `distanceFilter` → `kCLDistanceFilterNone` (Apple's stated requirement); keep the
  indicator; add a coarse region monitor around the last fix so termination is relaunch-
  recoverable. Update `scripts/ci/check_ios_background_publish.sh` if it pins the old value.
- Android: re-assert `startService` on every resume (idempotent) so a silently-dead FGS is
  restarted; persist + surface a declined battery-optimization exemption.
- Clock: a self-clock check against relay-observed `created_at` so a 2-member circle is not
  structurally blind; treat a negative age in `isForegroundActive()` as stale.

**Implementation notes**

- **`distanceFilter` is `-1`, not `0`.** geolocator's `LocationDistanceMapper`
  (`geolocator_apple` 2.3.13) *intends* to fold any non-positive value to
  `kCLDistanceFilterNone`, but it compares the boxed `NSNumber` **pointer** against zero, so a
  non-nil `0` is forwarded verbatim and reaches CoreLocation as a 0 m filter. `-1` IS the
  sentinel and is also what a fixed mapper would return, so it lands correctly either way.
  Applied ONLY on the background-capable branch (`backgroundSharingEnabled: true`); opt-out
  users keep the 1 m filter, whose stream never runs backgrounded, so their motion-trigger and
  battery behaviour is unchanged. `check_ios_background_publish.sh` did not pin the old value;
  check 4 now pins both the toggle-keyed filter and the `-1` constant (both mutation-tested).

**Amendment — 2026-09-04 (power-efficiency plan, phase P3). This supersedes the iOS half of Unit
F above; the Android and clock halves are untouched.**

- **The iOS updates owner is `HavenLocationStreamHandler.swift`**, a Haven-owned native
  `CLLocationManager` behind the `haven.app/ios_location_stream` method and event channels. It
  replaces geolocator's `getPositionStream` on iOS only; Android keeps geolocator, and iOS
  one-shots stay on the plugin (`requestLocation()` does nothing while the same manager is
  updating, so a native one-shot would need a second manager).
- **The 16.4 shape is honoured in BOTH accuracy profiles**, set once in `init` and never rewritten:
  `allowsBackgroundLocationUpdates` on (a pure function of the background-sharing toggle, passed as
  the `listen` argument), `distanceFilter = kCLDistanceFilterNone`, `desiredAccuracy` ≤ 100 m —
  `kCLLocationAccuracyBest` while foregrounded or moving, `kCLLocationAccuracyHundredMeters` while
  backgrounded and stationary — and `pausesLocationUpdatesAutomatically = false`. The tier changes
  by a live property write, never by a restart, and exactly two accuracy values may ever be
  assigned: a third, coarser one would recreate the shape the OS is documented to suspend.
- **R2 re-argued against the DTS text.** The indicator is offered there as an ALTERNATIVE to that
  shape, not as a requirement on top of it. So under a positively CONFIRMED Always it is no longer
  part of the anti-suspension posture — `showsBackgroundLocationIndicator` is cleared and the
  `CLBackgroundActivitySession` released, and the 16.4 shape carries the whole weight. Under
  When-In-Use, under a provisional Always and until Always is confirmed (which includes every iOS
  17 Always, since there is no diagnostics API there) the indicator REMAINS and is mandatory, and
  the activity session stays held. That asymmetry is the fail-safe direction: the cohort whose
  authorization the OS itself treats as When-In-Use keeps the exact object that was added after
  the 2026-08-20 failure.
- **The `distanceFilter: -1` geolocator workaround is retired with the plugin path.** The
  pointer-comparing `LocationDistanceMapper` bug that made `-1` rather than `0` the sentinel is no
  longer on any iOS code path, `_kIosNoDistanceFilter` is deleted, and the guard header says so, so
  nobody re-adds the constant. On iOS there is now no distance filter in either toggle state; 1 m
  survives only on Android's foreground arm.
- **What P3 did NOT prove, stated where the fix lives.** Whether the confirmed-Always shape — no
  activity session, indicator flag false — keeps a foreground-started session delivering for HOURS
  is **UNKNOWN** (V-P3-3). No simulator can answer it: it cannot suspend on the OS's hours-scale
  schedule, cannot render the status bar, and cannot run a two-hour stationary window. **The
  closest physical neighbour of this configuration FAILED in the field on 2026-08-20** — the
  failure this whole document exists for. P3 merged on the re-based CI bundle in
  `docs/POWER_EFFICIENCY_PLAN.md` §5.3 WP3-2; `docs/M7_BACKGROUND_SHARING.md` §6 item 0a records
  the physical proof as DEFERRED and still authoritative. Containment: every path P3 touches runs
  only while background sharing is ON, so a user who never enables it is untouched and a user who
  did can turn it off and watch everything stop; and only *confirmed* Always enters the
  un-evidenced shape. If 0a ever fails, the revert is one line — drop `!alwaysConfirmed` from
  `wantsActivitySession` in `HavenBackgroundSessionHandler.arm()` and confirmed Always keeps the
  activity session and the bar like every other tier.
- **The relaunch region lives inside `HavenSLCHandler`, not a new file** — no hand-built pbxproj
  ids, and the SLC gates (enable predicate + `authorizedAlways`), the `stopSLC` teardown and the
  receive-only `runCatchup` channel are reused verbatim. One ~500 m `CLCircularRegion`, exit-only,
  re-centred on every SLC delivery and on its own exit; `stopMonitoring()` iterates
  `monitoredRegions` so an OS-restored region (after a relaunch, where this class holds no
  reference) is released too. No coordinate is logged. **Nothing in CI can prove it fires** —
  new item 2b in `docs/M7_BACKGROUND_SHARING.md` §6 states that ceiling.
- **The FGS resume re-assert uses a bare `WidgetsBindingObserver`, not `AppLifecycleListener`**:
  the latter asserts on transitions it considers illegal (`paused` → `resumed` among them), which
  would turn an unusual platform sequence into a debug-build crash. Installed and removed inside
  `backgroundServiceLifecycleProvider`, so it exists only while the provider is in the
  "should be running" state; only `resumed` re-asserts (Android 12+ rejects a
  `FOREGROUND_SERVICE_LOCATION` start from a non-visible activity).
- **The battery-optimization verdict is persisted by the notifier, not by the callers.** Both
  `setEnabled` callers previously dropped `EnsurePermissionsBatteryOptDenied` on the floor
  (onboarding entirely, the settings page into a transient snackbar), so recording it inside
  `setEnabled` fixes both at once and `create_identity_screen.dart` needed no change. Granting
  the exemption later clears the flag; a notification denial (which returns before the battery
  probe) records nothing rather than guessing.
- **The clock fix is a sole-source EXCEPTION, not a lowered bar.** `minCorroboratingSources`
  stays 2 and governs unchanged whenever a second live sample exists; one member fires only
  when it is the only member heard inside `peerSampleTtl`, i.e. when corroboration is
  structurally unavailable. Everything above one live sample behaves exactly as before. No new
  input, no new plumbing, and `kClockSkewAlertThreshold` / `kClockSkewTotalLossThreshold` are
  untouched (`check_clock_skew_policy_parity.sh` green).
- **A sole source cannot support the corroborated copy, so it gets its own.** Two things a
  single peer does NOT establish. (a) *Whose* clock is wrong: A correct + B fast by 150 s makes
  A's detector fire while B's stays silent (negative offsets are structurally uninformative), so
  the innocent device is the one that gets told. (b) That anything is *lost*: both sides screen
  the NIP-40 expiration with `LOCATION_MESSAGE_RETENTION_SECS` (228 s) +
  `RECEIVER_EXPIRATION_GRACE_SECS` (60 s) of tolerance, so nothing is dropped anywhere until the
  gap passes 288 s — the whole 120–288 s band is a disagreement with no loss. The corroborated
  copy (`clockSkewTitle` + `clockSkewBodyBehind`: "This phone's clock is wrong… the locations it
  sends expire before anyone can see them") is therefore factually false across that band, and
  its remedy could not clear it. `resolveClockSkewCopy` now branches on
  `corroboratingSources == 1` to a hedged title/body/announcement triple that names neither a
  culprit nor a loss; the corroborated branch is unchanged. An earlier draft of this unit
  claimed the sole-source case "breaks delivery in at least one direction" — that was untrue for
  120 < d ≤ 288 and has been removed from the code comment and from here.
- **Blast radius outside the owned set, all test/oracle code:** the B8 lane's
  `checkSingleSourceStaysSilent` asserted the *old* rule, so it became
  `checkSoleSourceRaisesVerdict` (both directions still pinned by
  `haven/test/e2e/clock_skew_oracles_test.dart`), with the drive marker renamed
  `peer-single-source-silent` → `peer-sole-source-raised` and the
  `run-b8-clock-skew.sh --self-test` fixtures updated to match. **The group count is deliberately not carried here
  any more:** this line read "17/17 groups pass" and the script printed 18 by 2026-09-09, and that script's own
  figure is a hardcoded literal in its success line rather than a pinned count — so run it and read the number
  (the rule, and why, is `docs/POWER_EFFICIENCY_PLAN.md` §9.9's fixture-count bullet).
**Review fixes (round 2)**

- **B1 (blocker) closed by a third copy bundle, not by dropping the exception.** The sole-source
  verdict now renders `clockSkewTitleDisagreement` / `clockSkewBodyDisagreement` (+ its own
  screen-reader recovery announcement, because the general one says Haven "is sharing your
  location again" — an over-claim when sharing may never have stopped).
  `resolveClockSkewCopy` branches on `corroboratingSources == 1` via one shared predicate,
  `isSoleSourceVerdict`, so the copy choice and the announcement can never disagree about which
  fault was on screen. Mutation-proved: removing the branch kills 2 tests, widening it to
  `corroboratingSources != 2` kills 2 (it would hedge the relay fault, where nothing IS being
  shared), and dropping the announcement branch kills 1. Also pinned by a new B8 oracle
  (`checkSoleSourceCopyHedged`, marker `peer-sole-source-hedged`, shell self-test fixture 16g)
  that names the two corroborated strings as banned rather than merely checking for the hedged
  ones.
- **M1: the battery-optimization answer is probed, not remembered.** The exemption can be granted
  or revoked from Android Settings or an OEM battery manager without passing through Haven, so
  the persisted flag was write-only and the advisory would have asserted "battery optimization is
  still on" forever after a grant made outside the app. `batteryOptimizationDeniedProvider` now
  owns both the Android gate and a live probe (seam: `batteryOptimizationProbeProvider`); the
  persisted flag survives only as the fallback for a failed probe, which has its own seam and
  test because the real probe cannot be made to fail on a test host.
- **M2: two false claims deleted.** "Strictly stronger than the flat two-source bar" was wrong
  twice — the old rule was also healthy on 1-of-2, and the new one still fires on 2-of-3. Removed
  from the detector, the oracle doc and here; the test that carried it is re-scoped as a
  regression pin on the UNCHANGED bar (it passes identically with the exception reverted).
- **M3: the "a few ms in the future" test was seeding the PAST** and the guard's tolerance is
  zero. Deleted rather than repaired, with the reason zero is correct written into the guard's
  doc: writer and reader share one wall clock and the write happens-before the read, so a
  negative age can only be a real backward step — and a spurious `false` cannot steal a live
  foreground session anyway, because the reclaim path has its own fail-closed two-probe liveness
  gate.
- **m1/m2/m4 (Swift), m3, m5.** `maximumRegionMonitoringDistance` returns -1 when unavailable, so
  the radius is clamped only when it is positive. The region is no longer re-centred on a fix
  older than 300 s: on a region-triggered relaunch `manager.location` is not guaranteed to
  post-date the crossing, and centring on a place the device has already left would silence the
  NEXT departure — skipping leaves the previous circle in place and lets the next SLC delivery
  re-centre. The iOS-17 `CLMonitor` deprecation is noted at the call site (warnings only; no
  `SWIFT_TREAT_WARNINGS_AS_ERRORS`, deployment target 15.5). The resume re-assert documents that
  it can land inside `requestSessionHandover`'s stop-then-poll window, bounded by unit A's
  force-release-and-retry — narrowing it here would reintroduce the silently-dead FGS. The guard
  gained a real `--self-test` (19 fixtures, wired into `repo-guards.yml` as its own step) after
  the review found that `--self-test` was accepted and ignored, and check 4 now pins BOTH arms of
  the ternary — the escape it names (`: 50` on the opt-out arm) is fixture #3.
- **A latent accessibility defect the NIT test found.** Both this page's notes were a `ListTile`
  with a trailing `TextButton`; at a 200 % text scale on a 320 pt phone the button consumes the
  whole tile and Flutter asserts, replacing the note with an error box. Both now share
  `_ActionableNote`, which stacks the action under the message. The pre-existing iOS
  "Always required" note had the same latent defect and is fixed with the same widget; both have
  their own 200 %-scale test, and both fail if the widget is reverted to a `ListTile`.
- **`kBatteryOptimizationDeniedKey` is cleared on identity delete**
  (`check_identity_delete_prefs_residue.sh` was red on it): a cached OS answer, but a fresh
  identity must not inherit a warning earned by the deleted one, and it re-probes live anyway.

**Re-review fixes (round 3, cosmetic)**

- **Two scope claims in the hedged copy were still wrong.** `clockSkewProvider` is app-global —
  every circle feeds one detector — so the banner can be on screen while the map shows a
  different circle than the disagreement came from: the title is now "A clock in **one of your
  circles** is wrong", and both `@` descriptions carry that scope note. And the recovery
  announcement could fire because a second member was heard and re-attributed the outlier while
  the disagreeing sample was still inside `peerSampleTtl`, so "The clocks in this circle agree
  again" was false; it is now "The clock warning is gone" — the one thing certainly true.
  Re-translated ×12 with the mandated translate + independent-review round.
- **A latent 80-char/comment-reference pair and two stale comments** cleaned up: the banner's
  library doc line, a `[batteryOptimizationDeniedProvider]` reference from a service file
  (backticks — the provider is not in that library's scope), test 17's comment still describing
  the `ListTile` layout it no longer uses, and the `relaunchRegionMaxFixAge` doc, which now
  states the too-loose direction it does not defend against (a 300 s-old fix at vehicle speed is
  ~8 km stale) and why that case cannot arise: a crossing-triggered wake carries a fix seconds
  old, and the bound only ever has to reject a previous session's cache.

- **Not done, deliberately:** the analysis suggested a relay-observed `created_at` as the second
  corroborating source. Every producer of one lives in `location_sharing_service.dart` /
  `nostr_relay_service.dart`, and the detector's own doc argues at length that an outer
  kind-445 `created_at` is attacker-writable and must never be used as evidence. The sole-source
  exception achieves the same coverage with no new, weaker input.

### Unit H — Power (P1–P5)
**Status:** IMPLEMENTED + REVIEWED — P1 (2026-09-03), P2a and P3 (2026-09-04), P4 (2026-09-05 …
2026-09-08), P5(a) (2026-09-08); staged, not committed. **P2b is PARKED** (2026-08-30) and ~~**P4 is
not "COMPLETE"** until~~ ~~OD4-c is decided~~ **P4's OD4-c precondition is MET: the decision was taken on
2026-09-09, its Rust half landed the same day, and the Dart consumer that tells the user landed with it
(C5b above), so nothing about OD4-c holds P4's completion any more**; both are stated at the end of this
unit rather than implied. Canonical document: `docs/POWER_EFFICIENCY_PLAN.md` (mechanisms in §5.1–§5.5, the
no-hardware constraint in §2.5, estimation model E in §6.5a, the wedge×phase risk register in
§6.3). This unit records what the power epic did to the machinery THIS document is about.

**Why a power unit belongs in a failure analysis.** Every phase below rewrites a part of the
pipeline a wedge lives in: P1 moves the engine stop and the maintenance timers, P2a rewrites the
Android publish cycle around a platform delivery, P3 replaces the iOS stream owner, P4 pauses the
receive plane between publishes, and P5(a) makes one burst publish every circle. Each is therefore
an opportunity to re-create C1–C5 in new clothing — and one of them did, during its own review
(the P2a entry below). The wedge-regression list at the end of this unit is what stands between a
battery win and the 2026-08-20 failure recurring for a different reason.

**Per-phase mechanism, as landed** (as landed, not as drafted — several phases shipped differently,
and the differences are recorded with them):

- **P1 — quick wins, no architecture change.** Three independent changes. (a) *The publish pool is
  on-demand*: `publish_relay_options()` (`haven-core/src/relay/manager.rs`) is
  `ping(false).reconnect(false).sleep_when_idle(true)` with `PUBLISH_POOL_IDLE_TIMEOUT`, every
  `add_relay` site swapped onto it and `RelayManager::subscribe` deleted, so the publish socket
  emits no keepalive and sleeps `(60 s, 70 s]` after the connect that opened it (the idle poll is a
  one-minute crate constant run inside each relay's own connection task). The ENGINE pool keeps
  its 55 s ping deliberately — see C3. (b) *The location publish is bounded*: `publish_location_event` is
  `publish_with_retry(LOCATION_PUBLISH_ATTEMPTS = 1, ZERO, send_to_one(…, LOCATION_ACK_WINDOW =
  5 s))`, so one publish holds the radio ≤ 10 s and never retries, while `DeviceClockRejected`
  still surfaces (Unit F's clock check keeps its input). (c) *Foreground/lifecycle hygiene*:
  `GeolocatorLocationService.suspendStream()/resumeStream()` behind one outer controller, driven
  from `MapShell._onPaused/_onResumed` through `shouldKeepLocationStreamWhilePaused`, a fail-closed
  `appForegroundProvider`, `shouldStopLiveSyncOnPause` plus the `_stopLiveSyncBounded()` extracted
  from `_handOffMlsSession` (shared with `_onDetached`), `shouldRunResumeExtras`, and
  `LocationAccessNotifier.suspend()/resume()`. **Landed differently:** the goal "no maintenance
  timer is armed while backgrounded" was false on first landing — arming was gated, nothing
  cancelled an already-armed timer, so one KeyPackage probe, one relay-list probe and one health
  tick still fired per backgrounding. `suspendForBackground()` landed in the review pass. The
  lesson generalises to this document's C6 family: *a gate on the arming path is not a gate on the
  state.*
- **P2a — Android FGS: delivery-driven cadence, demoted one-shot, scoped publish lock.** The FGS
  isolate owns ONE platform `LocationManager` registration, aimed at `earliestDue −
  kBackgroundFixLeadTime` and floored at `kMinFixRequestInterval`; the arithmetic is pure in
  `haven/lib/src/services/background_fix_request.dart` (`nextFixRequestInterval`,
  `registrationIsAligned`) over `PerCircleDueTracker.earliestDue`, and every input — a delivery,
  the watchdog, a foreground signal — reaches the same `_publishCycle`, which registers before it
  publishes even when nothing is due. `onRepeatEvent` (72 s) is **demoted to a watchdog**, so the
  per-tick 30 s high-accuracy one-shot no longer runs in steady state and remains only as the
  cache-miss path. The scoped lock is new Kotlin (`PublishWakeLock.kt`: `PARTIAL_WAKE_LOCK`
  `"Haven:publish"`, non-reference-counted, capped at 30 s) held across
  fix→encrypt→publish→ack→fetch and released in Dart's `finally`; the plugin's own permanent
  `PARTIAL_WAKE_LOCK` **stays**, which is what keeps the no-fix watchdog punctual, and removing it
  is the parked P2b. Each cycle also shuts the publish pool (`_relayService?.shutdown()`).
- **P3 — iOS native location owner, two accuracy profiles, tier-based indicator/session policy.**
  `haven/ios/Runner/HavenLocationStreamHandler.swift` is now the only `startUpdatingLocation()`
  site: `pausesLocationUpdatesAutomatically = false`, `distanceFilter = kCLDistanceFilterNone`,
  `allowsBackgroundLocationUpdates` a pure function of the sharing toggle, and exactly two
  admissible `desiredAccuracy` values — `kCLLocationAccuracyBest` foregrounded or moving,
  `kCLLocationAccuracyHundredMeters` backgrounded and stationary — switched by a live property
  write, never by a restart. It **refuses a background-capable start while `applicationState ==
  .background`**, which is Unit F's R7 rule moved into the owner itself. Dart reaches it through
  `IosLocationSource`; only Best-profile fixes stamped after the switch are cached, emitted or
  published. Tier policy lives in `HavenBackgroundSessionHandler.arm()`: `wantsActivitySession =
  status == .authorizedWhenInUse || !alwaysConfirmed`, so the `CLBackgroundActivitySession` and the
  blue bar are held under When-In-Use, under a provisional Always and on iOS 17 (no diagnostics
  API), and released only under a positively **confirmed** Always. That asymmetry is deliberately
  fail-safe: the cohort whose grant the OS itself treats as When-In-Use keeps the exact object
  whose absence produced the 2026-08-20 failure. **Landed differently, and it matters here:**
  `CLError.locationUnknown` now returns early instead of being forwarded, and `_requestedProfile`
  became nullable so the next apply re-issues `setProfile` unconditionally — before that fix one
  ordinary indoor moment ended background sharing until the user reopened the app, which is a wedge
  of exactly this document's kind introduced by a power phase.
- **P4 — iOS background burst receive.** `LiveSyncCore` gains a `Paused` state.
  `pause_subscriptions()` runs under the lifecycle lock: `unsubscribe_all` plus a post-condition
  sweep, a router-drain marker with a worker ack (bounded, with a direct clear and
  `note_delivery_gap()` on a wedged worker), an **uncapped** wait for in-flight publishes (Rule 13),
  `client.disconnect()`, then `terminate_all_relays()` re-asserting until the pool proves quiet,
  after which the radio-off watch cuts and counts any relay that comes back up
  (`unrequested_connections`). Each publish tick then runs exactly ONE bounded burst on one chain
  (`BackgroundBurstCoordinator`): open every REQ at its persisted cursor → wait for the stored
  replay per `(relay, subscription)` endpoint → one GPS fix → publish the due circles staggered →
  fold any due KeyPackage/relay-list maintenance onto the warm publish pool → settle → pause →
  drain commit-critical publishes unbounded → close the publish pool. **Between bursts there is no
  standing subscription and no socket Haven asked for**, and a pause with nothing to publish runs
  the same teardown through `closeIdle()`. The Dart health tick became foreground-only at both
  arming and fire time — the phase's own carve-out, and the one thing that could have undone it
  (C3 below).
- **P5(a) — publish coalescing.** One `JitteredScheduler` per plane instead of one per circle: its
  tick publishes every `filterPublishEligibleCircles` circle in a CSPRNG permutation with per-pair
  gaps from `PublishStagger.sampleGaps`, capped at `kMaxCirclesPerBurst = 11` — *derived* from
  `n − 1 ≤ kPublishStaggerMaxSpread ÷ (kPublishStaggerMinGap + 1 s)` — with a strict round-robin
  `_takeBurstSlice` deferring the tail of a larger roster to the next tick, and every published
  circle re-armed onto ONE `nextBurstDue`. Owner decision OD3, taken as variant (a). It is the one
  phase that changed a privacy claim rather than only a power one:
  `INV-R-PER-CIRCLE-PUBLISH-DECORRELATED` is downgraded to the accepted deviation `PUB-COALESCE`,
  and the three costs it buys are argued in `haven-core/SECURITY.md` under "Coalesced multi-circle
  publish bursts (PUB-COALESCE)". Its liveness cost is stated with it, and it is UNREACHABLE in
  production since the roster bound of 2026-09-09 (`kMaxCirclesPerAccount` = 10, §7): a roster past
  eleven circles
  *would be* served every `ceil(N ÷ 11)` bursts, so at N = 12…22 a circle's worst scheduled gap
  would be 366 s against a 228 s retention, 504 s at N = 23…33, and from N = 34 even the best case
  (288 s) past the retention on every publish — deliberate, owner-taken, recorded under "The no-gap
  invariant", and kept on record because the deferral code is kept and lifting the bound re-opens
  it verbatim. Both halves of that ladder are pinned: the round-robin period over both sides of
  every rung by `a deferred circle waits ceil(N / kMaxCirclesPerBurst) bursts`
  (`haven/test/providers/location_publish_scheduler_provider_test.dart`), the seconds by `and past
  the cap, the deferral ladder in SECONDS` (`haven/test/services/publish_stagger_test.dart`). ONE
  limit on the quotient, because a field report will hit it before the arithmetic does: it bounds
  what the SCHEDULER hands over, not what a background pass publishes — the iOS coordinator folds a
  second tick into a running burst (`BackgroundBurstCoordinator._joinable`), so one pass can publish
  more than `kMaxCirclesPerBurst`, reachable only at N ≥ 12 and so already past the roster the cap
  covers. The period itself is ABSOLUTE: `_rotation` outlives
  `stopScheduling()`/`startScheduling()` and outlives an emission reporting nothing eligible, so
  neither a backgrounding nor a failed roster read re-phases whose turn it is (`a deferred circle is
  not deferred again by every resume`, `a transient empty roster emission does not re-phase whose
  turn it is`, `a roster change keeps survivors' places in the queue`). It is a period of TURNS
  though, and a turn is a SELECTION rather than a publish — the rotation advances when the tick
  FIRES, ahead of the chain, the window and the sink — so a slice that loses its turn without
  publishing (a refused publish window, a pause under it, an iOS burst the coordinator drops) waits
  its whole period over again: one more burst at N ≤ 11, up to 336 s against the 228 s retention,
  and another `ceil(N ÷ 11)` past the cap. Only `build()` — a fresh
  container or `IdentityNotifier.deleteIdentity`'s invalidate — and a process restart rewind it, and
  because the roster keeps `filterPublishEligibleCircles` order (`getVisibleCircles()` orders by
  `updated_at DESC`) a rewind re-serves the SAME first slice rather than re-phasing; the tail's gap
  across that boundary is bounded by resume frequency, not unbounded, because the uncapped one-shot
  (`locationPublisherProvider`) fires on cold start, on motion, on accept/create and on a resume
  more than 30 s after the last one (`MapShell`'s resume debounce sits ABOVE its invalidate). From
  21 circles that cover *would be* a probability rather than a promise — the one-shot's own spread
  outlasts `kLocationPublishOverlapGuard`, so the next trigger's invalidate marks the burst in
  flight superseded and it stops where it stands, with the replacement re-shuffling from the start
  — and that too is out of reach at `kMaxCirclesPerAccount`. At a bounded roster the leading slice
  IS the roster, so a rewind re-serves all of it and there is no tail left to cover.

**Before/after — every energy figure below is ESTIMATED, and none of it was measured.** There are
no measurements to report: the owner constraint of 2026-08-30 removed the iPhone, the macOS machine
and the Android handset for the duration (`POWER_EFFICIENCY_PLAN.md` §2.5), so `POWER_MEASUREMENT.md`
has never been run and its results tables are deliberately empty. The rows below are arithmetic
from estimation model E (§6.5a) over published third-party draw figures and declared parameters —
a prediction, not an observation. An estimate cannot fail: if a future measurement disagrees, the
model was wrong and the model is what gets corrected.

| Phase (cumulative) | iOS total — **ESTIMATED** | Android total — **ESTIMATED** |
|---|---|---|
| Baseline (before P1) | 1.7–4.9 %/h | 1.8–4.8 %/h *plus an UNKNOWN AP term* |
| + P1 | 1.5–3.6 %/h (Δ radio −0.20…−1.35) | 0.3–2.4 %/h (Δ location −0.54…−1.80, Δ radio −0.20…−1.35) |
| + P2a (Android only) | — | 0.15–0.73 %/h (Δ location −0.03…−0.68, Δ radio −0.14…−0.94) |
| + P3 (iOS only) | 0.6–2.8 %/h (Δ location −0.2 poor coverage … −1.5 good coverage) | — |
| + P4 (iOS only) | 0.4–1.6 %/h, mid-range ≈ 0.6 (Δ radio −0.17…−1.14) | — |
| + P5(a) | no separate energy row; the wake count falls from ≈ N × 30/h to ≈ 30/h per plane | same |
| + P2b (PARKED) | — | **cannot be estimated even in principle** |

Three things must be read with that table, or it will be misread. **(1)** The ranges are wide
because of one parameter, the wake-coalescing factor `c ∈ [0.15, 1.0]` (cellular versus Wi-Fi);
the width is honesty, not hedging, and any future measurement that does not fix the network per run
produces numbers that cannot be compared to these. **(2)** Do NOT subtract two total columns:
ranges compose, so each `Δ` is the change in the term that phase touches and an endpoint difference
between two totals is not a saving. **(3)** The absolute `%/h` values assume a 4500 mAh handset
(model E's parameter E-P1) because nobody knows what the owner's phones are — a 5000 mAh phone
reads ≈ 10 % lower, a 3200 mAh phone ≈ 40 % higher — and model E has **no** application-processor
term at all (E-P3 has no published value), so the Android column is understated by an unknown
amount and P2b's saving is unquantifiable rather than merely unmeasured. Model E's own headline
finding is worth repeating because it contradicts the phase names: **most of the Android GNSS win
is P1's, not P2a's** — releasing the never-cancelled 1 Hz UI stream takes the duty from ≈ 100 % to
the FGS one-shot's ≈ 7–42 %, and P2a then takes that to ≈ 4 % and bounds the indoor tail.

**What IS measured, and by which instrument.** These are real observations, and none of them is a
battery figure — with one COMPUTED figure kept in the list and labelled as such, because deleting it
would hide the very confusion this block exists to prevent:

- **Android emulator, `e2e-fgs-publish` (B1), device-clock-stamped `dumpsys` samples every ≤ 5 s.**
  Parsed `dumpsys location`: exactly ONE Haven registration while backgrounded, interval ≥ 62 s,
  never two in a sample, with the pre-handoff UI request (`@+1s0ms` with `minUpdateDistance=1.0`)
  present as the anti-vacuity arm. `dumpsys power`: `Haven:publish` present only with an `ACQ=` age
  ≤ 30 s, `ForegroundService:WakeLock` present throughout. Step (7): ≥ 2 publishes inside a 200 s
  hold with consecutive `cycle trigger=delivery` markers ≥ 55 s apart. Step (8): `dumpsys deviceidle
  get deep` reading `state=IDLE` **and** a watchdog publish within 302 s. `dumpsys batterystats`
  GNSS output is printed as evidence only and gates nothing — the emulator has no receiver.
- **iOS simulator, `e2e-ios-background-publish`, under a real OS background transition.** A bounded
  poll of the live `manager.desiredAccuracy` from the genuinely backgrounded process observes
  `hundredMeters` (the tier was really requested of CoreLocation, not written to a Dart field);
  P2c observes a peer's kind-445 decrypted into the member-location cache during a burst and the
  engine's pool subscription **count** at zero between bursts, with a non-zero foreground control
  arm; on the poll leg P2d observes the 90 s background receive timer's sweep landing a peer's
  kind-445 in the persisted last-known store instead; the tier→policy inversion is observed per
  matrix job.
- **Host (not a device).** `the_publish_socket_sleeps_after_a_burst_and_wakes_for_the_next`
  (`haven-core/src/relay/manager.rs`, against `nostr-relay-builder`'s `LocalRelay`) waits on a real
  socket's `RelayStatus::Sleeping` transition, which is where the idle-close window comes from; the
  upstream disconnect-notify strand reproduced 48/150 under 2× oversubscription and 0/300 idle; a
  first-shipped `run_repair` gate busy-spun 726,416 iterations in a ~2 s test. **The FGS roster
  figures that motivated P5's anchor fix are COMPUTED, not observed — and they are a COMMENT about
  the RETIRED configuration, not an output of the live model** (attribution corrected 2026-09-09;
  correcting the verb alone, as an earlier pass did, left the wrong subject in place). `FgsModel`,
  in `background_fix_request_test.dart`'s `a modelled foreground-service run` group, sweeps
  `circles = 1..8` — the sweep deliberately stops at 8, because past the burst budget the split is
  the `kMaxCirclesPerBurst` deferral — so it **cannot produce an `n = 12` figure at all**. The
  "2.2 circles per cycle at n = 4 rising to 5.7 at n = 12, i.e. 1.8–2.1 cycles per
  circle-interval and 54–63 wakes an hour instead of 30" is that group's own comment describing
  what the model did **while every circle carried its own due**, which is the shape `nextBurstDue`
  replaced. The live ASSERTION is the opposite: `INV-COALESCE` requires
  `minPerServingCycle == circles` — every circle publishes in every serving cycle, i.e. **1.00
  cycles per circle-interval**, exact for every API regime, TTFF and gate delay in the sweep. The
  model drives the real scheduling primitives on a simulated clock while reimplementing the order
  the cycle calls them in (the file's own SCOPE note says so, and names where the shipped ordering
  is pinned instead). No cycle on any device or emulator was counted.

**What nothing measures — say it in this form every time.** A green CI run proves the mechanism
changed and that publishing did not stop inside the lane's window. It proves no milliamp, no
percent and no joule, and no combination of these lanes ever will. Specifically unknown: every
battery figure on both platforms; true OS process suspension and Android AP suspend under Doze
(the emulator never suspends — this is what parks P2b); the iOS profile *duty*, i.e. how often the
84 s escalation fires on a real desk, which is the whole difference between the 0.3 and 1.0 %/h
estimates; whether the status bar renders the arrow rather than the pill (no simulator draws it);
and whether the confirmed-Always shape keeps delivering for HOURS — whose closest physical
neighbour is what failed in the field on 2026-08-20, and which stays owed as
`docs/M7_BACKGROUND_SHARING.md` §6 item 0, banner intact, DEFERRED for lack of an iPhone.

**Wedge-regression tests — which test fails when a phase's mechanism becomes one of the five
wedges** (six, since 2026-09-09: C5b is a wedge in substance and its own row is under C5 above)**.** Read this as the acceptance criterion for the whole unit: a power change that trades any
row here for battery is not a power change, it is this document's incident with better numbers.

- **C1 — Rule-14 guard orphaned.** *P1*: the Android sharing-OFF pause and `_onDetached` both go
  through the one `_stopLiveSyncBounded()`, and neither calls `releaseForHandoff()` where no FGS
  will reclaim — `check_mls_session_single_owner.sh`, `mls_session_handle_release_test`,
  `map_shell_detached_release_test`, and B1's `HANDOFF_CONFIRMED` marker. *P2a*: the rewritten FGS
  cycle preserves the reclaim ordering — `session_reclaim_gate_test.dart`,
  `background_location_task_reclaim_orchestration_test`, `session_guard_contention_test`
  (`e2e-integration`) — and the paused signal is sent only on a completed handoff
  (`map_shell_location_access_lifecycle_test.dart::a declined handoff sends no paused signal`).
  *P3*: none — iOS has no handoff. *P4*: the burst opens and closes the session only in the
  session-holding isolate — `security_rule_gates.rs::rule14_pause_and_burst_open_no_second_session`
  plus `check_mls_session_single_owner.sh`. *P5(a)*: none — one scheduler in the isolate that
  already published.
- **C2 — a stuck inbound row silently blocks outbound sends.** *P4* is the only phase that touches
  the ordering, and it fixes it into the mechanism: a burst ingests before it encrypts
  (`burst_ingests_a_peer_commit_before_the_location_is_encrypted`), a burst that did not settle
  every endpoint advances no cursor
  (`a_burst_that_did_not_settle_every_endpoint_leaves_no_advance_standing`,
  `a_late_eose_after_pause_never_advances_a_cursor`), and a held-back event survives the pause to be
  re-requested (`a_hold_back_survives_pause_and_is_re_requested_by_the_next_burst`). Unit B's repair
  sweep still runs inside the burst. **This row is honestly incomplete**, and it is the one gap in
  this unit that is not merely unmeasured but untested: the original backlog test was removed as
  unsound and its replacement,
  `pause_subscriptions_drains_the_intake_before_it_clears_the_router`, does **not** go red on the
  reviewer's own attack — clearing the router before the drain. A stronger replacement is owed
  (`POWER_EFFICIENCY_PLAN.md` §5.4/§6.3).
- **C3 — receive plane dead-but-"running" after a relay `CLOSED`.** *P1*: the publish pool loses its
  ping, and the ENGINE pool must keep its own, because that ping is the only traffic on a socket
  holding standing REQs — `engine_pool_keeps_ping_while_subscribed` (the trap: `.ping(false)` on the
  engine pool would recreate C3 exactly) plus `check_engine_client_options.sh` checks 3–7; a fetch
  primitive that leaked a REQ onto the ping-less pool would be the same wedge, so
  `every_fetch_primitive_leaves_no_subscription_registered` pins that none does, and
  `RelayManager::subscribe` is deleted. *P2a*: the per-cycle pool shutdown leaves nothing running to
  be dead. *P4*: backgrounded there is no standing REQ to lose
  (`background_burst_holds_no_standing_req`), stale relay-side REQs are swept before the burst issues
  its own (`a_stale_relay_side_req_never_precedes_the_bursts_own_req`,
  `a_partial_unsubscribe_all_is_swept_before_disconnect`), `maintain_subscription_health` cannot
  reach a probe while paused, and the Dart health tick is foreground-only at BOTH arming and fire
  time (`maintenance_scheduler_provider_test.dart::the health tick is never armed while the engine
  is paused`) — a tick landing mid-burst would have repaired through the FOREGROUND entry and left
  standing REQs plus a 49 h `#p` replay at a non-publish instant, which is this phase undoing
  itself. P4 also inherits a new instance of C3's shape from the pinned crate:
  `InnerRelay::disconnect` notifies before it stores `Terminated`, so a connection task can re-open
  a real socket over the pause and hold it with 55 s pings. Haven cannot make that impossible; what
  is promised is that none survives, by the radio-off watch that cuts and counts it
  (`a_socket_re_opened_while_the_radio_is_off_is_cut_and_counted`,
  `LiveSyncCore::unrequested_connections`) — a non-zero count is the honest reading of the promise,
  not a contradiction of it.
- **C4 — sender-ratchet forward-distance exhaustion.** The publish RATE is unchanged by every phase,
  and each pins its own: *P1* `haven/test/constants/location_test.dart`'s cadence pins; *P2a*
  `background_fix_request_test.dart`'s `the realized inter-publish gap` group
  (`never exceeds kLocationPublishMaxInterval for a hot fix`, exhaustive over both API anchors and
  the whole in-cycle latency space); *P3* the scheduler never consults the accuracy profile; *P4* a
  burst's per-circle rate is the tick's rate; *P5(a)* every circle is published exactly once per burst and re-armed onto
  one due (`per_circle_due_tracker_test.dart::a burst re-arms every circle it published onto ONE
  due`), and the deferral past eleven circles publishes a circle *less* often, never more. P1's one
  new risk here is its bounded lookback: it applies to the INBOX plane only, and
  `inbox_cursor_poisoning_e2e.rs` is kept precisely so a narrowed inbox window can never skip a
  circle event.
- **C5 — non-`Stable` epoch / quarantined group.** *P4* is where this lives, because a pause could
  otherwise cut a commit between SEND and OK: the burst settles convergence before it pauses, and
  the drain marker and the publish gauge both sit inside `pause_subscriptions` under the lifecycle
  lock — `pause_never_disconnects_while_an_auto_commit_awaits_its_ok`,
  `a_commit_arriving_between_settle_and_pause_is_still_confirmed`,
  `security_rule_gates.rs::rule13_a_burst_never_pauses_with_a_pending_publish_outstanding`, and
  `check_e2e_publish_before_apply.sh`; the end-of-burst pool shutdown drains commit-critical
  publishes without a bound, which is why Rule 13 survives a mechanism whose whole point is closing
  sockets. **The uncovered sub-case is a burst KILLED mid-publish** rather than paused: the group
  stays one epoch behind with a staged commit on disk, and the engine does not recover it — a
  re-fetched own commit returns terminal (`OwnEcho`) and, for a removal-bearing staged commit,
  `PendingCommitRecovered` is never emitted at all. Both behaviours predate P4; what P4 changes is
  exposure, because its premise is a process iOS may kill between bursts. ~~No test, and the Rule-13
  source gate stays green through it. That is **OD4-c, OPEN** — the control is an owner decision~~
  **CLOSED ON THIS PLANE 2026-09-09: OD4-c was decided in both halves and its Rust implementation
  landed the same day. The burst no longer publishes a removal-bearing auto-commit at all — it parks it
  durably and the next FOREGROUND pass publishes it, retrying rather than rolling back, because a
  rollback is a permanent silent drop of the removal at the pinned rev — and a circle wedged anyway is
  named per circle instead of flattened into a self-clearing status.
  `od4c_removal_deferral_e2e.rs` carries the behavioural proofs and
  `security_rule_gates.rs::od4c_a_background_burst_cannot_publish_a_removal_bearing_auto_commit` pins
  the structure, so this row now has tests that redden. ~~What is NOT closed is written out as C5b under
  C5: nothing consumes the verdict (so the user is still not told), the parked circle's sends stay
  refused until the next foreground pass, a device wedged by an earlier session is undetectable, and the
  Android catch-up sweep still publishes a removal-bearing auto-commit~~ **CONSUMER LANDED THE SAME DAY:
  the verdict is read, the circle is marked blocked and the banner names it and offers the re-create, on the
  SECOND foreground open (a two-observation debounce keyed to re-anchor generations, because one verdict can
  race a peer's healing commit). What is NOT closed is written out as C5b under C5: the parked circle's sends
  stay refused until the next foreground pass, a device wedged by an earlier session is undetectable, the
  Android catch-up sweep still publishes rather than parks — now a finding stated at the call site and
  tested, since a park is unredeemable from a background isolate — and redemption ACROSS a session is
  impossible at this rev, so an obligation another session recorded is reported but terminal**, and it is
  disclosed as residual 4 of `SECURITY.md`'s "iOS background sharing: presence only at
  publish instants (P4)".

**Two more things this unit owes the reader, because they are wedge-shaped and neither is a C1–C5
row.** First, **P2a re-created this document's own failure during its review**: two watchdog early
exits latched `_inFlightPublish` forever, so background sharing published once per backgrounding
and stopped ≈ 72 s later. 28 green tests missed it, because every one of them ended with the no-op
tick as its last action — a test suite can be complete over single actions and blind to the state
they leave. It is now held by `_trackCycle` (which owns the slot on every exit and releases it under
an identity check) and by `background_location_task_delivery_cycle_test.dart`'s `a tick that finds
nothing to do leaves the cadence alive` and `a tick that yields to the foreground leaves the isolate
able to take publishing back`. Second, **the one instrument that would prove "publishing never
stopped" end to end is still wired to no lane**: `tooling/e2e/ci/summarize-created-at-gaps.sh` runs
in CI only as the `--self-test` step in `repo-guards.yml`, so P1 records its liveness row NOT MET
and P2a records it DEFERRED behind B1 step (7). Every liveness claim in this unit is therefore
per-lane and per-window, never continuity — and §1's field failure was a continuity failure, two
hours in.

**Accepted, disclosed, and deliberately not fixed** (listed here so nobody re-opens them as bugs):
P2a's W-3 residual — on API 23–30 a cold acquisition alone reaches a 248 s worst gap against the
228 s retention, i.e. a peer's marker absent for at most 20 s once per occurrence, pinned by
equality in `background_fix_request_test.dart`'s `a cold TTFF outruns the lead, and on API ≤ 30 it
outruns the retention as well — the residual, exactly`, so it can neither grow nor be declared gone
without a red test; P4's residual 7 — an account with nothing publish-eligible receives NOTHING while
backgrounded, because there is no publish tick to carry a burst; and P5(a)'s roster hole — past
eleven circles the deferral exceeds the retention. That last one is **no longer live**: the owner
took the roster bound on 2026-09-09 (`kMaxCirclesPerAccount` = 10, one circle under the burst cap,
refused at circle creation and at invitation accept), so the `ceil(N ÷ 11)` deferral ladder is
unreachable in production and the no-gap floor holds at every roster a user can have. The ladder
stays documented — on `kMaxCirclesPerBurst`, `constants/location.dart`, `ttl.rs`, `SECURITY.md`,
`INV-W-445-EXPIRATION-WINDOW`'s residual and §6's P5(a) row above — because the deferral code stays
too, and lifting the bound re-opens it verbatim.
What the bound does NOT close, and what those sites still carry as residual, is the propagation
margin the burst spread spends: 30 s where the per-circle predecessor had 60 s, at every roster
from two circles up.

## 8. Reviewer record

Independent reviews (2026-08-28, two Opus reviewers, read-only): both confirmed C1 as the top
Android cause and C3 as the dead-but-running receive plane; reviewer A contributed C2 and the
precise C4 timeline; reviewer B contributed the relay `CLOSED` mechanics, the `SESSION`
reinstall path, and the 2-member clock-skew blind spot. Author-verified at source afterwards:
`reinstall_after_timed_out_stop`, `should_resubscribe`, `remove_subscription`,
`should_queue_outbound_intent` → `queue_outbound_intent`, `take_app_message`, the absence of any
Haven handling of `SendResult::Queued`, the absence of any `Disconnected`/`Reconnecting`/
`RelayError` emitter, `send requires Stable`, `can_ingest`, and the `Retryable → Buffered`
short-circuit.

Related: `docs/M7_BACKGROUND_SHARING.md`, `docs/M11_ROLLOUT.md`, `docs/E2E_TROUBLESHOOTING.md`,
`haven-core/SECURITY.md`.
