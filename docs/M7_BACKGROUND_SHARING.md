# M7 — Background Location Sharing (self-owned background catch-up)

**Status:** M7 + M7-E **DONE** (2026-07-05); flags **LIVE on both platforms**
(`backgroundCatchupEnabled=true`, RebootReceiver `enabled="true"`, `autoRunOnBoot:true`, iOS
mirror true-by-default). The only remaining item is a one-time physical-iPhone `BGAppRefreshTask`
fire (§6 owner checklist — `BGTaskScheduler` cannot fire on the Simulator). Ships behind the
compile-time `backgroundCatchupEnabled` flag; **`liveSyncEnabled` (the persistent live-sync engine)
is M11-owned and was still `false` when M7 shipped** — M7 does not flip it. It has defaulted to
**`true`** since M11 Phase B (`live_sync_provider.dart:29-32`, `bool.fromEnvironment('HAVEN_LIVE_SYNC',
defaultValue: true)`, pinned by check 14b in `scripts/ci/check_m7_native_wake_guards.sh` — cited by CHECK NUMBER
because the line range this once named (`:1239-1257`) had drifted onto an unrelated log-case fixture by 2026-09-09).

Migration context: `docs/WN_RELAY_EPOCH_SYNC_MIGRATION.md` (M7 ≈ the self-owned background-delivery
milestone; the former M3/M6/M8 docs are now appendices in that master plan). Siblings:
`docs/M11_ROLLOUT.md`, `docs/E2E_TROUBLESHOOTING.md`.

Architecture at a glance: **OS-scheduled-wake, single-process, receive-only. MIP-05 push REJECTED
on privacy.** The device wakes itself and fetches from the same relays it already uses — zero new
observer, zero new metadata channel. The one hard problem — writer-exclusion — is solved by a
process-global Rust `WRITER_LOCK` (§B). Nothing runs in the background after the user opts out (§C).

---

# Part I — M7 background sharing (approved plan)

*The approved master plan (research → draft → 4 independent reviewers, all APPROVE_WITH_FIXES,
architecture choice unanimous). Every must-fix is folded in below. The single material correction
versus the first draft is §B (writer-exclusion): the draft's "WorkManager shares the FGS's in-memory
gate" was **false** and is replaced by a real process-global Rust lock that all MDK-write paths
acquire.*

## §A. Architecture decision

**Recommendation: (i) OS-scheduled-wake, strict single-process, receive-only. Reject (ii) MIP-05
push. Adopt (iii) hybrid only as "FGS/alive-process owns the active window, a scheduled floor fills
the dead-process gaps" — no push tier.** Deciding lens = the owner's non-negotiable: *no third party
learns who-shares-with-whom, when, or how-often.*

### (ii) MIP-05 push — REJECTED (all four reviewers, security = CRITICAL)
Confirmed in `whitenoise-rs/src/whitenoise/push_notifications.rs` + `Mip05FirebaseMessagingService.kt`.
Requires a notification server + FCM/APNs. Even with a blank encrypted payload:
- **FCM/APNs (Google/Apple, US) always see** a stable per-device push token **and the exact timestamp
  of every wake** = every time someone in one of your circles published a location. A direct
  who/when/how-often signal tied to a device identity on a US third party — strictly more than a
  relay (which sees only a REQ from a pubkey).
- **The notification server sees** sender pubkey, per-server fan-out batch size (≈ circle member
  count), and cadence.
- **Not neutralizable:** self-hosting removes the push server but **cannot remove APNs/FCM** as the
  mandatory silent-delivery transport; rotating tokens reduce linkability but never remove
  wake-timing.

Fork-safety note: push would actually be the *safer* wake trigger (carries no MDK-write obligation).
The rejection is **purely privacy-driven**, and privacy is the deciding lens. Rejected before any
reliability comparison.

### (i) OS-scheduled-wake — RECOMMENDED
No push server, no FCM/APNs, no token. The device wakes itself and fetches from the same relays.
Third parties learn **exactly what foreground operation already reveals** — a relay sees a REQ from a
pubkey. Strict non-regression at the relay/third-party layer.
- **Android:** `flutter_foreground_task` FGS (already integrated, `foregroundServiceType="location"`)
  owns the active window; a `WorkManager` ~15-min periodic floor that runs **only when the FGS is
  dead**; `RebootReceiver` restarts the FGS after reboot when sharing is enabled.
- **iOS:** No push. Keep `UIBackgroundModes` + existing CLLocationManager retention; add
  Significant-Location-Change (SLC) relaunch + `BGAppRefreshTask` floor for the receive-only path.
  OS-local; no server sees anything.

**Accepted tradeoff:** worst-case latency bounded by the floor (Android ~15 min WorkManager minimum;
iOS BGTask best-effort minutes–hours; SLC on ~500 m movement). Acceptable for a location app (peers
publish every ~72–168 s; the FGS covers the Android active window; iOS keeps the main isolate alive
while actively sharing). We trade marginal latency for zero metadata leakage.

**Honest residual observability (LOW):** a scheduled background REQ makes the *wake cadence* visible
to the **relay** as a periodic REQ from the user's pubkey (same as foreground, but now also while
backgrounded), and on-device "sharing is active" remains visible via the FGS notification (Android)
or the status-bar indicator plus the Settings → Location Services attribution (iOS), and via battery
attribution on both. Since P3 the iOS indicator is tier-dependent and the difference is user-visible:
under When-In-Use, a provisional Always and iOS 17 Always it is the **blue bar**; under a positively
confirmed Always it is the **status-bar arrow**, and the arrow plus the Location Services listing are
then the whole of the on-device signal. **Not** a third-party regression (the relay already sees the
pubkey) and inherent to any self-wake model; documented so it isn't mis-sold as invisible.

## §B. Writer-exclusion — the corrected core (THE fix for the revert)

**The hazard (re-confirmed CRITICAL by marmot + rust):** the FGS foreground loop is an **authoring**
MDK writer — `_publishCycle` → `encryptLocation` → `mdk.create_message` (ratchet/DB write,
`manager.rs:~2249`) and the receiver auto-commit inside `fetchMemberLocations` (self-authored commit
finalize). Both `circles.db` and MDK's `haven_mdk.db` are **rollback-journal, `busy_timeout=0`**
(confirmed `storage.rs:313-319`). If a background sweep holds `haven_mdk.db` when the FGS authors, the
FGS write gets `SQLITE_BUSY` → MDK records `Failed` → **never reprocessed → dropped membership commit
= fork on the writer side.** The receive-only sweep's four barriers protect the *sweep*, not the
*other* writer.

**Why the draft's fix was wrong (flutter + rust, HIGH):**
- The FGS authoring writer runs in a **separate Dart isolate with its own `CircleManagerFfi` /
  `CircleStorage` / `Mutex<Connection>`** and **never starts a LiveSyncCore**, so `static SESSION` is
  empty there and it holds **no** `MlsWriteGate`. WorkManager's `BackgroundWorker.kt` spawns a
  **brand-new `FlutterEngine`** → its own Rust runtime → `SESSION=None`. **There is no shared
  in-memory gate to serialize through.**
- `isRunningService` is a **TOCTOU liveness read** (MethodChannel). The FGS can (re)start
  (START_STICKY auto-restart, foreground resume) in the window between the check and the worker's
  first MDK write.

**The fix — one process-global advisory writer lock in Rust (unifies Android + iOS):**

1. **`static WRITER_LOCK: std::sync::Mutex<()>` (or `parking_lot::Mutex`) in the FFI layer.** It is
   process-global: a Rust static lives **once per OS process** and is shared across **all
   isolates/engines** in that process (both the FGS isolate and the WorkManager engine on Android;
   both the foreground and the SLC/BGTask headless engine on iOS load the **same** Rust dylib). This
   is the enabling fact — it works **even when `SESSION` is empty** (cold wake), which is exactly when
   the in-memory gate cannot.
   - **Type is `std::sync`/`parking_lot`, NOT `tokio::sync::Mutex`** (rust, HIGH): the authoring FFI
     methods are sync (`#[frb(sync)]`/`spawn_blocking`); acquiring a tokio async mutex from a
     sync/blocking context deadlocks/panics.
2. **Every MDK-write path acquires it.** Enumerate exhaustively and pin with a test that fails if a
   new MDK-write entrypoint is added without it:
   - **Authoring (priority writer): acquire blocking `lock()`** — `encrypt_location`/`create_message`,
     `self_update`, `add_members`(+welcomes), `remove_members`, `update_admins`, `update_relays`,
     `self_demote`, `finalize_pending_commit`, `clear_pending_commit`, `converge_commit`, and the
     receiver **auto-commit finalize** path. **The FGS authoring path takes nothing today — it MUST be
     modified to take this lock** (a change to the *existing, shipping* foreground publish path — see
     risk note).
   - **Background sweep: acquire `try_lock()`** — `run_catchup_all_circles`/`decrypt_receive_only`.
     On contention → **no-op + re-fetch next sweep** (lossless via the contiguous-prefix cursor). Held
     only for the brief stage/decrypt op.
3. **`isRunningService` (Android) / `isForegroundActive` (iOS) stay as cheap fast-path bails** (skip
   booting a Rust runtime when the FGS clearly owns receive) — **battery optimization, not the safety
   mechanism.** Exclusion is proven by the lock, not the branch, so the TOCTOU window is closed: even
   if both isolates believe they should run, the lock serializes them and the loser yields losslessly.
4. **`gate` argument stays `None` in the floor path** (documented): the sweep's fork-safety for the
   *sweep* side comes from the four Rust barriers (`has_pending_commit` fail-closed pre-decrypt;
   never-author; MDK `OwnCommitPending→CompetingCommit→Skipped` backstop; contiguous-prefix cursor).
   `WRITER_LOCK` is the *writer* exclusion for the concurrently-(re)starting FGS.

**Defense-in-depth (NOT the fix): `PRAGMA busy_timeout=2000` on `circles.db`** (per-`CircleStorage`
instance, `apply_hardening_pragmas`). It only prevents the **marker table**
(`has_pending_commit`/`mark_group_staged`) from spuriously failing-closed/aborting a legitimate stage
under brief contention. It does **nothing** for the actual fork hazard (contention on MDK's
`haven_mdk.db`, which stays `busy_timeout=0`, pristine). Only `WRITER_LOCK` excludes the MDK-DB
collision.

**M4 assertion (rust, precedes M7-C/D):** a unit test asserting `circles.db` is rollback-journal
(`PRAGMA journal_mode` ∈ {`delete`,`truncate`}, not `wal`) and MDK's DB `busy_timeout` is 0, so the
concurrency argument cannot silently drift if a future change flips journal mode.

> **Correction (2026-08-28, Dark Matter): the MDK-DB half of the hazard above no longer applies.**
> Everything §B says about `circles.db` stands. What has changed is the OTHER database. The
> pre-Dark-Matter `haven_mdk.db` really was rollback-journal with `busy_timeout=0`, which is why a
> concurrent writer's `SQLITE_BUSY` was a fork hazard rather than a wait. Its replacement,
> `session.sqlite` under `storage-sqlite`, opens with **WAL journalling and
> `busy_timeout = 5000`** (`SqliteStorageOptions::default()`, `storage-sqlite/src/connection.rs`
> ~361-375, applied in `apply_operational_pragmas` ~506-532), and every multi-write transition goes
> through **`BEGIN IMMEDIATE` with capped exponential backoff** (`begin_immediate_with_retry`,
> ~262-280), surfacing an exhausted retry as the *transient* `StorageError::Busy` rather than a
> fatal backend fault. So contention on the MLS database is now a bounded WAIT with a typed
> transient error, not a silent `Failed` record.
>
> Read §B's `busy_timeout=0` claims (the paragraph above, and the hazard statement near the top of
> this section) as **historical**: they describe the database this milestone was designed against,
> and they are kept because the `WRITER_LOCK` design they justify is still what shipped. The
> file-name and pragma citations are stale; the M4 assertion's MDK half no longer describes the
> engine's DB. `WRITER_LOCK` remains correct and remains the exclusion for `circles.db`, whose
> pragmas are unchanged — this correction narrows the *justification*, not the mechanism.
>
> Practical consequence, recorded because Unit B of
> `docs/BACKGROUND_SHARING_FAILURE_ANALYSIS.md` depends on it: a SECOND connection to
> `session.sqlite` is now a supportable thing to hold (WAL admits one writer plus readers, and the
> busy timeout makes an overlap a wait). Unit B holds exactly one such connection, for the
> stuck-convergence-input sweep, and serializes every access behind the session mutex — see
> `SessionManager::message_store` for why that is not a second `AccountDeviceSession` under
> Security Rule 14.

> **Scope/risk call-out:** unlike the reverted draft (all-new inert code), this design **modifies the
> existing, shipping foreground FGS authoring path** to acquire `WRITER_LOCK`. The lock is held only
> for the brief duration of each MDK write and the background side is the only one that ever yields,
> so foreground publish latency is unaffected in practice — but it is a change to live code, covered
> by the existing foreground-publish tests + the on-device no-fork matrix.

## §C. Privacy — nothing runs in the background after opt-out

Confirmed gap that caused the 2026-07-02 REJECT: `BackgroundSharingNotifier.setEnabled(false)`
(`background_location_provider.dart:179-188`) only flips a bool + persists `kBackgroundSharingKey`; it
cancels **nothing** native. `deleteIdentity` wipes markers/cursors but has **no** scheduler teardown.

- **C1 — `disableBackgroundScheduling()` (new, idempotent), fired from BOTH `setEnabled(false)` AND
  `deleteIdentity`:** `Workmanager().cancelAll()` + `BackgroundLocationManager.stopService()` + iOS
  `stopSLC()` + `BGTaskScheduler.cancelAllTaskRequests()` + clear `kBackgroundIdleKey` /
  `kForegroundActiveAtMsKey`; on delete additionally `wipe_all_staged_commits()` +
  `reset_all_sync_cursors()` (both already exist).
- **C2 — durable-intent re-check as the FIRST executable step of every wake** (after the plugin
  registrant), reading `kBackgroundSharingKey`; if false → clean no-op with **zero** FFI/relay
  activity. `isBackgroundIdle()` encodes liveness, NOT user intent, and must never gate opt-out.
- **C3 — `CatchupService` is the single chokepoint** (rust): it hard-returns when
  `kBackgroundSharingKey` is false, so even a leaked/OS-queued wake cannot reach the FFI. (Do **not**
  push a bg-sharing flag into Rust — keep `run_catchup_all_circles` a pure receive primitive; intent
  is a Dart-policy concern.)
- **C4 — disable-mid-session:** toggling sharing OFF while the app is paused must **stop the running
  iOS 90 s `_receiveTimer`** and gate the foreground resume sweep on intent — not just stop the
  publish stream. Test: zero further catch-up sweeps after a mid-pause disable.
- **C5 — locked-device fail-closed (already enforced):** `has_pending_commit` fails closed
  (`manager.rs:2801`); `run_catchup_all_circles` no-ops to an empty outcome pre-first-unlock
  (`catchup.rs:132`). Device test: a pre-first-unlock wake is a clean no-op (no crash, no partial
  decrypt, no REQ before the key is available).
- **C6 — presence-only across FFI (already true):** outcomes carry only counters; errors route
  through `redact_hex_sequences`. No group-ids/pubkeys/coords cross FFI. **No new FFI metadata in this
  milestone.** Extend the no-key-logging discipline + a CI grep guard to the **new Kotlin worker and
  Swift SLC/BGTask handlers** (new attack surface).

> **NOTE:** these §C **C1–C6** are the *privacy-teardown* contract. They are DISTINCT from the CI
> runtime-proof "**D6 Phase C1/C2**" in Part II (pending-wipe no-op / no-network-after-disable
> emulator phases). Do not conflate.

**Net guarantee:** after disable, (a) all schedulers are cancelled, (b) any wake already queued by the
OS re-checks intent and no-ops before any relay fetch or FFI call, (c) the `CatchupService`
chokepoint is a third backstop. The app performs **zero** background relay activity post-disable —
proven on device (§F, hard gate).

## §D. Per-platform concrete steps (COMPILED vs INERT, CI-break risk)

### Android
Files: `AndroidManifest.xml`, `pubspec.yaml`, new `background_catchup_worker.dart`, edits to
`background_location_provider.dart` / `background_location_manager.dart`, `identity_provider.dart`.
1. **`workmanager` dep** — *COMPILED.* Pin a known-good version; run `android-build` before merge
   (transitive AGP/Gradle conflict risk).
2. **`callbackDispatcher`** exact order (flutter, HIGH — the intent read must precede `executeTask`):
   `(1) WidgetsFlutterBinding.ensureInitialized()` → `(2) DartPluginRegistrant.ensureInitialized()` →
   `(3)` read `kBackgroundSharingKey`; if false `return Result.success()` → `(4)`
   `FlutterForegroundTask.isRunningService`; if running `return Result.success()` (fast-path bail) →
   `(5) Workmanager().executeTask(...)` whose body calls **only**
   `run_catchup_all_circles(receive_only:true)` (which internally acquires `WRITER_LOCK.try_lock`).
   Do **not** rely on `executeTask` to init the binding (it does so too late for step 3).
3. **`RebootReceiver`** (flutter, HIGH): drop `tools:node="replace"` from **RebootReceiver only** (it
   strips the plugin's `BOOT_COMPLETED` intent-filter); keep it on `RestartReceiver` (do not re-enable
   ANR/kill restarts). Pair atomically with `autoRunOnBoot:true` in `ForegroundTaskOptions` inside
   `BackgroundLocationManager.init()` (the native receiver reads this from SharedPreferences).
4. Permissions: `RECEIVE_BOOT_COMPLETED` (for the receiver); `INTERNET`/FGS already present.

**Amendment (P1, power-efficiency phase 1 — landed, not planned).** Two facts about the Android
backgrounded state changed, and both are properties of the UI isolate rather than of the worker:

5. **The UI isolate's location stream is RELEASED at pause.** `MapShell._onPaused` calls
   `GeolocatorLocationService.suspendStream()` (`map_shell.dart:1319-1324`) BEFORE the ownership
   write `markForegroundActive(active: false)`, so this isolate has let go of GPS before the
   foreground service is told to take over. The call is gated by the keep rule
   `shouldKeepLocationStreamWhilePaused({backgroundSharingEnabled, isIOS}) => bg && isIOS`
   (`location_provider.dart:35-38`) — never by a raw platform branch, which
   `scripts/ci/check_android_location_power.sh` check (8) refuses — so on Android it fires in BOTH
   toggle states. Before P1 the UI isolate's `getPositionStream` registration (1 Hz, 1 m) was never
   cancelled and ran for the whole backgrounded period ALONGSIDE the service's own request; a
   backgrounded Android device now holds exactly the service's registration and nothing else. The
   cached fix is cleared on the CONSENT condition rather than the keep rule (`:1329`): with sharing
   on the warm fix still serves the resume publish, with sharing off no coordinate survives the
   pause on either platform (Rule 10).
6. **With background sharing OFF the live-sync engine is stopped at pause too.**
   `MapShell.shouldStopLiveSyncOnPause` is ~~`!isIOS`~~ **`!(isIOS && backgroundSharingEnabled)`
   (CORRECTED — power-efficiency P4; cite the symbol, the line numbers this row carried have
   drifted)** — "every pause except the one whose process keeps receiving" — and the `_onPaused`
   else-branch calls `_stopLiveSyncBounded()`, which deliberately never `releaseForHandoff()`,
   because with sharing off no isolate reclaims the session and the latch would fail every
   `getCircleManagerFfi()` closed until the next resume. `_healLiveSyncIfStopped()` restarts it on
   resume. Before P1 that pause path stopped only publishing, so a backgrounded Android device with
   sharing off went on holding a standing engine socket until the OS froze the process. The restart
   is cheap because P4-1's bounded inbox lookback landed in the same phase: a re-anchor asks the
   inbox for ≤ 49 h, never 7 days.

   **The `!isIOS` form missed the iOS sharing-OFF arm, which P4 closed.** It made the rule false
   there, so an iPhone whose owner had explicitly turned background sharing off still held every
   per-circle REQ, the inbox REQ, the engine socket and the crate's 55 s pinger until the OS
   suspended the process — the `pausedRelayOwner` fall-through does not cover it, because its only
   effect is shutting the PUBLISH pool and all three of those artefacts belong to the engine pool.
   That arm now STOPS the engine, as Android's does. The remaining iOS arm — sharing ON — is the one
   configuration that neither stops nor holds: the engine is PAUSED between publishes and each
   publish tick opens one bounded burst (`INV-R-BACKGROUND-PRESENCE-ONLY-AT-PUBLISH`, and
   `haven-core/SECURITY.md`, "iOS background sharing: presence only at publish instants (P4)").

   Also landed alongside, and true on both platforms: no maintenance timer (KeyPackage, relay-list,
   subscription-health) is armed while backgrounded — the arming sites read the foreground state and
   re-arm on resume with their normal jittered delays. **P4 hardened the third of those:** the
   subscription-health timer used to be spared on the iOS background-sharing branch, because a
   standing subscription was exactly what it existed to repair; it is now foreground-only on every
   branch, gated at arming AND at fire time, since a tick landing mid-burst repaired a mid-`connect()`
   pool through the FOREGROUND re-anchor and left standing REQs, a socket and a 49 h gift-wrap replay
   behind at an instant that is not a publish.

### iOS
Files: `Info.plist`, `AppDelegate.swift`, new `HavenSLCHandler.swift` + `HavenBGTaskHandler.swift`,
`project.pbxproj`.
1. **Info.plist:** add `BGTaskSchedulerPermittedIdentifiers=[app.haven.catchup]` and add `fetch` to
   `UIBackgroundModes` (`BGTaskScheduler.register` throws without the permitted-identifier). Wrong
   identifier crashes on device → device-validate.
2. **Swift handlers** (flutter, HIGH): declare `HavenSLCHandler`/`HavenBGTaskHandler` as **retained
   properties** on `AppDelegate` (mirror `HavenLocationAuthHandler`); hold the `FlutterMethodChannel`
   as a **strong property** on each handler — **no `[weak channel]`** in the
   `DispatchQueue.main.async` closures (the reverted draft's channel deallocated before use → both
   paths dead). SLC relaunch → `beginBackgroundTask` (~23 s self-cap) → MethodChannel → Dart intent
   re-check → catch-up; BGAppRefreshTask floor likewise, reschedule-first.
3. **Engine mutual-exclusion** is handled by the same Rust `WRITER_LOCK` (§B) — the headless engine's
   catch-up `try_lock`s and no-ops if the foreground engine's authoring holds it. Both engines share
   the one process-global static.

**Every native change is device/CI-only** and ships **inert** (flag OFF, receiver disabled, no task
registered) so `flutter analyze` / `flutter test` / `android-build` / `ios-build` stay green.

## §E. Rust / FFI changes (MDK stays PRISTINE — pin superseded, see below)

> **The PIN this heading carried is history (noted 2026-09-09):** it read "at v0.7.1, rev 93ae324", and the tree has
> pinned MDK v0.9.4, rev `e391adc133a9…`, since the Dark Matter migration of 2026-07-18 (`haven-core/Cargo.toml`).
> "Pristine" — no fork, no patch — is still the rule, and Part III's note carries the rest.

1. **`static WRITER_LOCK` (the main change, §B):** process-global `std::sync::Mutex<()>` /
   `parking_lot::Mutex`; authoring FFI methods `lock()`, `run_catchup_all_circles` `try_lock()` →
   no-op on contention. Enumerate + test every acquirer; guard test that a new MDK-write entrypoint
   without the lock fails. **The existing FGS authoring FFI is modified to take it.**
2. **(§E(2)) `PRAGMA busy_timeout=2000` on `circles.db`** (`apply_hardening_pragmas`) — additive,
   per-`CircleStorage` instance, marker-table defense-in-depth only; MDK's DB untouched.
   *(This item is cited as `§E(2)` from `haven-core/src/circle/storage.rs`.)*
3. **M4 assertion test** (journal-mode rollback + MDK `busy_timeout=0`) — lands before M7-C/D.
4. **No new FFI metadata.** `run_catchup_all_circles` signature unchanged, presence-only.
5. **MDK unchanged** — no fork/patch/upgrade (justification in Part III).

## §F. Test + validation strategy

**Unit-testable here (`cargo test` / `flutter test`):**
- `WRITER_LOCK`: `try_lock` contention → background no-op returns empty outcome; authoring acquires.
- Worker logic as pure Dart: intent-recheck-returns-early-when-disabled; FGS-alive-returns-early.
- `disableBackgroundScheduling()` fans out all cancels from **both** disable and delete (mock+assert).
- Rust barriers (exist): `has_pending_commit` fail-closed; receive-only never authors; cursor stops at
  first skipped event.
- **M4 journal-mode assertion.** FRB smoke test for the unchanged FFI signature.

**Device/CI-only (hard gate — cannot be asserted in `flutter test`):**
- **Writer-exclusion NEGATIVE/TOCTOU proof (marmot, the decisive one):** force the FGS to (re)start
  **after** the `isRunningService` check passes, overlapped with a floor/BGTask wake authoring
  concurrently; assert MDK records **zero `Failed`** and **zero epoch divergence** across many cycles.
  Proves the lock — not the branch — closes the window.
- **No-fork proof:** peer commit arrives while backgrounded; epoch coherence after resume.
- **No-background-network-after-disable (security, hard gate):** enable → background → observe relay
  REQ on a network capture; disable → assert **zero** further REQ/wakes. Empirical acceptance test for
  the "won't violate privacy" bar.
- **Reboot:** enabled-then-reboot restarts the FGS; disabled-then-reboot does nothing.
- **Locked-device:** pre-first-unlock wake → clean no-op.
- **Bug regressions:** no `MissingPluginException` (registrant present); receiver actually fires (no
  `tools:node="replace"` strip); iOS channel not deallocated (strong capture).

*Part II §5/§6/D6 supersede this with the concrete emulator lane, runbook, and owner checklist that
discharge these gates.*

## §G. Milestones + "safe to enable" gate

Ordering respects dependencies (privacy teardown + writer-lock before any wake path is reachable).

- **M7-A (local, FIRST): privacy teardown + flag.** `const backgroundCatchupEnabled = false`;
  `disableBackgroundScheduling()` wired into `setEnabled(false)` + `deleteIdentity`; intent-recheck
  helpers; `CatchupService` chokepoint; C4 mid-pause-disable stop. Fully unit-tested.
- **M7-B (local): Rust `WRITER_LOCK`** across all authoring + catch-up sites (incl. FGS authoring
  path) + `busy_timeout=2000` on `circles.db` + M4 assertion. Unit-tested.
- **M7-C (device/CI): Android native wake, inert.** `workmanager`, `callbackDispatcher` (exact
  order), RebootReceiver manifest fix. Device-validate writer-exclusion + reboot + no-activity-after-
  disable.
- **M7-D (device/CI): iOS native wake, inert.** SLC + BGTask handlers, Info.plist, strong channel
  capture, retained handlers. Device-validate.
- **M7-E: adversarial re-confirmation + enable — ✅ DONE (2026-07-05).** All flags flipped LIVE; the
  Android WorkManager stub replaced with the real background-isolate bootstrap; iOS
  `applicationDidEnterBackground` re-arm closes the upgrade/toggle one-launch arming lag; static guard
  pins the released state (14a–14i); `e2e-background-catchup` emulator runtime-proof lane added. **NOTE:**
  the flag flip is an M7-E step, NOT the M11 rollout — M11 owns `liveSyncEnabled`, which was still
  `false` at M7-E time and defaults to `true` since M11 Phase B
  (`live_sync_provider.dart:29-32`). Full detail = Part II. The one runtime proof CI cannot cover —
  a physical-iPhone `BGAppRefreshTask` fire — is the single remaining owner checklist item (§6).

**"Safe to enable" gate — ALL five required before `backgroundCatchupEnabled = true`:**
1. **marmot APPROVE** — four barriers intact; `WRITER_LOCK` proven to exclude two concurrent MDK
   writers incl. the TOCTOU case; no fork on device.
2. **security APPROVE (must flip from REJECT)** — no third-party metadata channel (no push);
   cancel-on-disable + intent re-check + chokepoint verified; locked-device fail-closed; teardown on
   disable **and** delete; presence-only FFI; **no-activity-after-disable proven on device.**
3. **rust APPROVE** — MDK pristine; `WRITER_LOCK` type/acquirers correct (no deadlock across the sync
   FFI boundary); `busy_timeout` reasoning sound; M4 assertion present.
4. **flutter APPROVE** — registrant order correct; RebootReceiver fires; strong channel capture;
   manifest/plist valid; inert-when-flag-OFF.
5. Green CI (`android-build`, `ios-build`, `flutter test`, `cargo test`) + the §F device matrix.

All five flipped to APPROVE at M7-E (2026-07-05).

---

# Part II — M7-E go-live & implementation

*Replaced the Android WorkManager stub (`_runCatchupViaProviders`) with a real background-isolate
bootstrap, proved it at runtime (local pixel8a AVD + a new CI lane), flipped every M7-owned inert
switch live on BOTH platforms, and pinned the released state in CI. After this landed there is **no
M7-owned inert state left** on either platform.*

**Explicitly NOT in scope:** `liveSyncEnabled` stays `false` (at M7 time; M11-owned, and flipped by
M11 Phase B — see `docs/M11_ROLLOUT.md`. Today `live_sync_provider.dart:29-32` reads
`defaultValue: true`). `enablePeriodicSelfUpdate` stays as-is (M5 kill-switch).
`RestartReceiver` stays `enabled="false"` + `tools:node="replace"` (PERMANENT). A physical-iPhone
BGTask fire is an OWNER item (§6).

## Non-negotiable constraints (binding on the implementer)

1. **NEVER `git commit`/`git push`.** Stage only; the owner commits.
2. **NEVER run `dart format .`** (repo is pre-tall-style; ~96-file churn). Match in-file style by hand.
3. CI clippy = `cargo clippy -- -D warnings` (lib/bins) from `haven-core/`. MDK crates stay pristine.
4. **No new dependencies.** Zero pub/cargo deps added.
5. **No secrets/coordinates/group-ids/pubkeys in ANY log.** All new worker logcat markers are
   presence-only counters (mirroring `CatchupResult`). FFI errors logged as `runtimeType` only.
6. **The consent chokepoint is PRESERVED and extended, never weakened.** Final worker gate order
   (D2): consent → pending-wipe → FGS-alive → foreground-active → sweep. The
   `CatchupService.runCatchup(isBackgroundWake: true)` C3 chokepoint is untouched.
7. **Never lower the quality of a test.** The test that asserts `backgroundCatchupEnabled == false`
   was *designed* to fail at M7-E (`ios_background_catchup_test.dart:286`); flipping it into the
   release-state pin (asserts `true`) is that test performing its documented function — not a
   weakening. `liveSyncEnabled` pin (`live_sync_provider_test.dart:9`) is untouched.
8. **Everything provable.** §9 maps every claim to a unit test, static guard check, emulator phase,
   or owner-checklist item.

## Decisions (D1–D9, one per design question)

### D1 — Stub replacement: DIRECT construction (no Riverpod)

`_runCatchupViaProviders` is replaced by `_runCatchupViaWorkerBootstrap`, which constructs by hand
only the four things `CatchupService` actually needs — **no `ProviderContainer`**:

```dart
Future<void> _runCatchupViaWorkerBootstrap() async {
  await RustLib.init();                        // FFI bridge (worker isolate never ran main())
  await initKeyringStore();                    // platform keyring (idempotent) — see A5
  final dataDir = await const PathProviderDataDirectory().getDataDirectory(); // M7-6, no split-brain
  // step 3b — M10.1 re-check: reload() picks up a cross-isolate pending-wipe write; marker set =>
  // abort BEFORE the DB open can SQLite-create a fresh decryptable DB. (A11: reload re-reads consent too.)
  final prefs = await SharedPreferences.getInstance();
  await prefs.reload();
  if (prefs.getBool(kPendingMlsWipeKey) ?? false) { return; }
  // A2: load identity + bail on null pubkey BEFORE CircleManagerFfi.newInstance (identity-before-DB).
  //  ... loadFromBytes / pubkeyHex(); zero the Dart secret copy in finally ...
  final circleManager = await CircleManagerFfi.newInstance(dataDir: dataDir);
  final relayService = NostrRelayService();
  await relayService.initialize();
  // terminate in the M7 chokepoint — receive-only sweep, NOT the FGS authoring cycle.
  final result = await CatchupService(...).runCatchup(isBackgroundWake: true, maxDurationSecs: 25);
  // presence-only counter log; best-effort relayService.shutdown() in finally.
}
```

**Why not a bare `ProviderContainer`:** main()'s overrides are UI concerns, meaningless in a headless
isolate; reproducing them is dead weight and omitting them diverges from prod composition anyway.
Riverpod's value is reactivity; a run-once isolate has no watchers. Worse, it silently expands the
background attack surface — any future edit to `catchupServiceProvider`'s transitive deps would change
what boots on every 15-minute OS wake with no reviewer looking at the worker file. Direct construction
reuses the field-proven FGS `onStart` bootstrap minus its authoring tail and honors the
one-`CircleManagerFfi`-per-isolate rule by construction. **Why not the full FGS-template clone:** the
worker needs no location/circle/sharing services — `CatchupService` takes a manager factory, a pubkey
thunk, and a relay service. Building less = smaller attack/battery surface, faster wake.

**Plugin availability:** `callbackDispatcher` already runs `WidgetsFlutterBinding.ensureInitialized()`
→ `DartPluginRegistrant.ensureInitialized()` first (pinned by static-guard check 1), so
`shared_preferences`/`flutter_secure_storage`/`path_provider`/`flutter_foreground_task` are reachable
before any gate runs. **Testability:** the gate chain stays in `runBackgroundCatchupTask` with
injected fakes; the FFI-bound bootstrap is proven by the emulator lane (§5 / D6 Phase A), not units.

### D2 — NEW pending-wipe gate: position 2, fail-safe no-op, never wipes from the worker

`runBackgroundCatchupTask` gains a required injectable `Future<bool> Function() isPendingMlsWipe`
checked as **gate 2**. Final order (with A1's gate 0):

0. **flag** (`backgroundCatchupEnabled`; A1) — FIRST.
1. **consent** (`kBackgroundSharingKey`; read error → treated disabled → `return true`) — C2.
2. **pending-wipe** (`kPendingMlsWipeKey`; marker set → `return true` clean no-op; read error →
   `return true`). Production impl reads the pref **directly** — it must NOT construct
   `PendingMlsWipeService` (that requires a `CircleService`, whose construction path is exactly what
   the gate exists to avoid). The worker NEVER attempts the wipe itself: the wipe needs a
   `CircleService`, would race the main-isolate M10.1 launch retry, and a failed wipe in a headless
   isolate has no user-visible recovery. Declining is the whole job.
3. **FGS-alive** (unchanged; error → proceed).
4. **foreground-active** (D4; error → proceed).
5. sweep.

**Why 2nd, not 3rd:** gates 1–2 are *security* gates (fail-CLOSED, share the already-loaded prefs
instance); gates 3–4 are *battery* gates (fail-OPEN — safe because the sweep is receive-only,
cursor-idempotent, `WRITER_LOCK`-excluded). Grouping security-before-battery means a throwing FGS
check can never leapfrog the wipe check.

**Logout race (job mid-flight while `deleteIdentity` wipes):** mitigations verified in source —
(i) `deleteIdentity` cancels WorkManager via `disableBackgroundScheduling → cancelBackgroundCatchup →
Workmanager().cancelAll()`; (ii) `CatchupService` resolves identity BEFORE `_circleManagerFactory()`,
so a worker starting after the key is deleted fail-closes with zero DB access; (iii) POSIX unlink — a
worker holding an open handle writes to the doomed inode, nothing resurrects at the path;
(iv) M10.1 launch retry re-wipes on next start **only if the marker is still set** (A9). The D1
step-3b re-check shrinks the residual window to milliseconds; worst case = **an empty, freshly-keyed
SQLCipher DB with zero circles/MLS/cursors/secrets** — cosmetic residue, not confidentiality loss.
Fully closing it needs a Rust-side open-refuses-if-marker gate — deliberate non-scope (§8).

### D3 — `maxDurationSecs`: Android worker 25, iOS stays 20

- **Android = 25:** bounds only the Rust sweep deadline (`catchup.rs:128`), not the bootstrap; total
  ≈ 3–6 s cold bootstrap + ≤25 s sweep ≈ ≤~31 s per wake at ≥15-min cadence, far inside
  JobScheduler's ~10-min ceiling. That ceiling is a real bound; the energy is not measured — model E
  prices a wake off its COUNT (E-A2, `docs/POWER_EFFICIENCY_PLAN.md` §6.5a), never its duration, and
  no figure for a wake's own cost exists (E-P3 is UNKNOWN). The word "negligible" used to stand here
  as a verdict on exactly the quantity the model declines to give. Deliberately above the foreground default (20): a cold
  wake is the only receive opportunity a backgrounded device gets; the 512-events/circle flood-guard
  + deadline bound the worst case.
- **iOS = 20 (unchanged, no code change):** the SLC budget is ~23 s inside a ~30 s window and the
  engine is already running (no bootstrap cost). Recorded in the handler doc comment.

### D4 — Foreground-active fast-path: ADD it (gate 4, fail-open)

Injectable `Future<bool> Function() isForegroundActive` (default:
`BackgroundLocationManager.isForegroundActive`, staleness-checked). Catches *FGS-dead-but-UI-active*
(OEM killed the service; user reopened) — the map-shell pollers are already receiving, so the marginal
sweep would pay a full Rust engine + SQLCipher boot for nothing. `kForegroundActiveAtMsKey` auto-
expires after 2×72 s so a stale value cannot permanently starve the floor. Battery gate ONLY;
correctness never depends on it (cursor-idempotent sweep + `WRITER_LOCK`) — hence error → proceed.

### D5 — Release-state guard: extend `check_m7_native_wake_guards.sh` (checks 14a–14i)

Extend the existing guard (wired into every push/PR via the Background-wake invariants step in `repo-guards.yml` → `ci.yml`) rather
than adding a second script. Update its header (which said the guard "intentionally does NOT
hard-enforce the inert ship-state") — post-flip it enforces the RELEASED state. New comment-aware /
xmllint checks:

| # | Pin |
|---|-----|
| 14a | `const bool backgroundCatchupEnabled = true;` in `live_sync_provider.dart` |
| 14b | `liveSyncEnabled` defaults to `true`: `defaultValue: true` within 3 lines of the `bool.fromEnvironment` declaration (`check_m7_native_wake_guards.sh:1239-1257`). At M7-E this pinned `= false`; M11 Phase B flipped the flag and updated the check with it |
| 14c | RebootReceiver `android:enabled="true"` |
| 14d | RestartReceiver STILL `android:enabled="false"` AND carries `tools:node="replace"` |
| 14e | `autoRunOnBoot: true` present in executable code of `background_location_manager.dart` |
| 14f | Worker terminates in the chokepoint: `runCatchup(isBackgroundWake: true` in executable worker code (stub gone) |
| 14g | Pending-wipe gate present: `kPendingMlsWipeKey` read in executable worker code, positioned BEFORE the `runCatchup(` line |
| 14h | (A8) pin `writeCatchupEnabledMirror()` + `registerIosBackgroundCatchupHandler(` call-sites in executable `main.dart` |
| 14i | (A8) pin the new `applicationDidEnterBackground` re-arm in `AppDelegate.swift` |

Not pinned: `maxDurationSecs: 25` (a tuning value). Existing checks 1–13 untouched.

### D6 — Runtime-proof lane: NEW workflow `e2e-background-catchup.yml` + one orchestration script + three integration targets

**New workflow, not new `e2e-integration.yml` targets — because the existing lane's contract breaks
this test:** `run-single-avd-scenario.sh` **force-stops + uninstalls** the package before every drive;
an uninstall clears JobScheduler + app data and `am force-stop` puts the app in stopped state, which
**removes its JobScheduler jobs until the next explicit launch**. The M7 lane's whole point is
adb-driven phases BETWEEN drives against persistent job + app state, plus a guest-OS reboot mid-lane.
**Consequence baked into the script: never `am force-stop` before a force-run.** Cold-process state is
produced with `adb shell input keyevent HOME` + `adb shell am kill com.oblivioustech.haven` (OOM-like
kill; does NOT enter stopped state; jobs survive).

**Files:**
- `.github/workflows/e2e-background-catchup.yml` (reusable, `workflow_call`) + a `ci.yml` fan-out entry
  `needs: [rust-check]`.
- `tooling/e2e/ci/run-m7-background-catchup.sh` — orchestrator (`set -euo pipefail`, trap cleanup,
  per-phase timeouts, evidence → `/tmp/m7-logs/`, ends with `scan-logs-for-secrets.sh /tmp/m7-logs/`).
- Three integration targets (built pre-emulator via the EXISTING `build-integration-apks.sh`):
  - `integration_test/m7_worker_setup_test.dart` — real keyring + identity (A5: install the **real
    platform keyring BEFORE any `_lib` bootstrap** — `TestUser`'s `useInMemoryKeyringForTest()` is
    process-global first-installed-wins and an in-memory key dies with the drive process); creates a
    circle on `HAVEN_E2E_RELAY`; a `SyntheticUser` accepts + publishes ONE location; sets
    `kBackgroundSharingKey=true`; calls `registerBackgroundCatchup()`. Never mounts MapShell (so no
    foreground poller consumes the synthetic location first).
  - `integration_test/m7_worker_pending_wipe_test.dart` — consent true; `kPendingMlsWipeKey=true`;
    re-runs `Workmanager().initialize` + `registerPeriodicTask` (policy `keep`) so the persisted Dart
    callback handle matches THIS binary after `install -r`.
  - `integration_test/m7_worker_disable_test.dart` — clears wipe marker; sets
    `kBackgroundSharingKey=false` **directly via SharedPreferences, deliberately NOT via
    `disableBackgroundScheduling()`** (which would cancel the job — the scenario under test is
    precisely "an OS-queued wake survives opt-out"); re-registers as above.

**Phases (single API-34 google_apis x86_64 AVD, single strfry, host-side script):**

- **Phase A — isolate-bootstrap proof (positive):** fresh install of setup APK → grant
  FINE/COARSE/POST_NOTIFICATIONS (`ACCESS_BACKGROUND_LOCATION` not needed — receive-only, no GPS) →
  drive the setup target → HOME + `am kill` → assert job present in `dumpsys jobscheduler` (job line
  existing = "registration now actually registers") → extract job id(s) → `logcat -c` → force-run
  (A4: `adb shell cmd jobscheduler run -f -n androidx.work.systemjobscheduler com.oblivioustech.haven
  <id>`; androidx.work 2.10.x uses that JobScheduler namespace on API 34+; id extraction is
  namespace-tolerant) → poll streamed logcat (bounded 120 s) for `[CatchupWorker] bootstrap ok` then
  `[CatchupWorker] sweep complete:` → parse counters, assert `circles>=1 && locations>=1 &&
  relayErrors=0` (full relay→MLS-decrypt pipeline inside the worker isolate). *Counter expectations
  pinned on the §5 runbook run FIRST; documented fallback if first-sweep cursor-seeding excludes the
  pre-published location — decided with local evidence, never by weakening CI after the fact.*
- **Phase B — reboot re-arm (consent still ON):** `adb reboot` → `wait-for-device` → poll
  `getprop sys.boot_completed`=1 (300 s bound) → `wm dismiss-keyguard` best-effort → restart host
  logcat capture → **bounded poll** for the SystemJobService job listed again (A6: WorkManager reboot
  survival is via its own `RescheduleReceiver` + Room DB, `setPersisted(false)`, NOT persisted
  JobScheduler jobs — the job may appear seconds-to-tens-of-seconds after boot) → assert RebootReceiver
  runtime-resolvable for BOOT_COMPLETED (`cmd package query-receivers … | grep RebootReceiver`;
  fallback `dumpsys package`) — runtime proof of manifest flip #2 AND that the plugin's intent-filter
  survived the merge → `logcat -c` → force-run → assert `sweep complete` (post-boot cold wake works).
  *The FGS-restart-on-boot (autoRunOnBoot) assert is NOT in CI* (needs a visible-activity enable flow
  + `ACCESS_BACKGROUND_LOCATION`) → §5 step 7 local runbook. **Correction (2026-08-01):** this line
  previously said `pm grant` "cannot grant [ACCESS_BACKGROUND_LOCATION] on API 30+". That is false.
  The permission is `hardRestricted` in AOSP, but `adb install` sets
  `INSTALL_ALL_WHITELIST_RESTRICTED_PERMISSIONS` by default (only `--restrict-permissions` clears
  it), making the package installer-exempt so the grant gate passes. The Android 11 restriction that
  is real governs `requestPermissions()`/`GrantPermissionsActivity` — background location cannot be
  *requested* in the same call as foreground location — and `pm grant` never enters that path. Two
  operational traps: the hard-restricted rejection is a bare `return` after `Log.e`, so a failed
  grant **still exits 0** (verify with `dumpsys package`, never `$?`), and the permission→app-op sync
  is asynchronous on `FgThread`, so poll `cmd appops get` for `allow` rather than reading it once.
  Source-level finding, verified across the android11–android15 AOSP branches; the empirical
  read-back is recorded on every run of the `e2e-fgs-publish` lane's probe. This does **not** by
  itself unblock the on-boot assert — API 34+ additionally refuses to create a `location` foreground
  service from the background without that permission held, which is exactly why it is needed there.
- **Phase C1 — pending-wipe no-op (runtime proof of the NEW gate):** `install -r` pending-wipe APK
  (data preserved) → drive → HOME + `am kill` → snapshot strfry baseline → `logcat -c` → force-run →
  poll for `[CatchupWorker] wake: pending-wipe marker set — no-op` → 5 s settle → assert strfry line
  count unchanged AND logcat contains neither `bootstrap ok` nor `sweep complete`.
- **Phase C2 — no-network-after-disable:** `install -r` disable APK → drive → HOME + `am kill` →
  baseline strfry → `logcat -c` → force-run → poll for `[CatchupWorker] wake: consent disabled —
  no-op` (exact gate-1 exit text) → 5 s settle → same negative asserts as C1. Deterministic: after
  `am kill` the only process that could reach strfry is the worker; the marker proves it exited at
  gate 1 (before any FFI — unit-locked ordering), and the strfry-silence assert corroborates at the
  network layer.

  > **NOTE:** "Phase C1/C2" here are CI *runtime phases*, DISTINCT from the §C privacy-teardown
  > contracts **C1–C6**. Both label sets are retained deliberately.

- **Phase D — TOCTOU writer-exclusion: documented structural argument + existing deterministic tests;
  NO new emulator TOCTOU test.** (i) FGS-vs-worker contention is structurally excluded (gate 3 skips;
  even on the gate error-path bypass the Rust side yields — `decrypt_receive_only` takes
  `try_acquire_background()` and returns `Skipped`, proven by
  `m7b_receive_only_yields_to_skipped_under_authoring_contention` `manager.rs:9765` +
  `background_yields_while_authoring_held` `write_lock.rs:128`). (ii) The remaining real race —
  foreground-UI authoring vs worker sweep — is reachable only when FGS is dead AND UI active; gate 4
  skips it at the Dart layer, and past that the `acquire_authoring` vs non-blocking
  `try_acquire_background` Skipped-not-blocked semantics are covered by those two Rust tests + the
  pending-marker gate test (`m7_receive_only_persists_peer_then_pending_gate_skips_without_decrypt`
  `manager.rs:6691`). An emulator "drive an authoring burst while `cmd jobscheduler run -f` fires"
  test cannot be made deterministic (force-run dispatch latency is ms–seconds jitter) → sleep-tuned
  flakiness, forbidden by the CI-best-practices memory. What the lane DOES assert: Phase A runs the
  sweep against a DB with real authoring history + clean counters, and a SECOND force-run after Phase
  B asserts continued epoch-consistent operation (no `Unprocessable` cascade ⇒ `relayErrors=0`,
  sane counters) — absence-of-fork after concurrent-ish activity.
- **End:** copy logs → `/tmp/m7-logs/`, run `scan-logs-for-secrets.sh` (mandatory, Security Rule 6),
  upload artifacts `if: always()`, `stop-strfry.sh` teardown trap. Script self-guards: first step
  greps `backgroundCatchupEnabled = true` and fails loudly if the flag is off ("lane requires the flag
  ON — remove the ci.yml fan-out entry if rolling back" — ties into §7).

### D7 — iOS wiring proof in CI: one tiny extra sim target + a shell plist assert; the BGTask fire is owner-only

`e2e_combined` pumps `HavenApp` directly — production `main()` never runs, so the mirror write is not
exercisable there. Additions to `e2e-ios.yml` (both cheap, non-flaky):
1. New target `integration_test/ios_bg_mirror_test.dart`, run as a SECOND `run-ios-sim-scenario.sh`
   invocation after `e2e_combined` (same booted sim + relay; pods/Rust cached). Asserts on a real iOS
   runtime: `writeCatchupEnabledMirror()` → SharedPreferences reads back `true`; the Swift teardown
   handlers are reachable — invoke `MethodChannel('haven.app/ios_slc_teardown')/'stopSLC'` and
   `('haven.app/ios_bgtask_teardown')/'cancelAllBGTasks'` and expect normal completion (a
   `MissingPluginException` fails the test — proves AppDelegate wiring + strong handler retention).
   (A10: wrap the second invocation in the existing `nick-fields/retry` pattern.)
2. Shell step: `simctl get_app_container … data` → `plutil -p …/com.oblivioustech.haven.plist` →
   assert `"flutter.background_catchup_enabled" => 1` (belt over the same fact at the OS layer).

NOT asserted in CI: `scheduleNextCatchup`'s `notPermitted` swallow (executes only when `bg_sharing AND
mirror` are both already true — would need a mid-test relaunch for one code-reviewed `catch` arm).
Real BGTask submission/fire → §6 owner checklist.

### D8 — Unit/widget tests (TDD; write before implementation)

See §3. The worker gate-chain tests extend to the two new gates with order-of-calls asserts; the
flag-pin test in `ios_background_catchup_test.dart:282-299` flips to assert `true` (its documented
M7-E behavior). No other test asserts the flag is false (verified by grep); `liveSyncEnabled`'s pin is
M11-owned and untouched. Host-unreachable facts are honestly delegated: WorkManager registration →
Phase A dumpsys; `writeCatchupEnabledMirror` (hard `Platform.isIOS` guard) → D7 sim target;
`autoRunOnBoot`/RebootReceiver → guards 14c/14e + Phase B + runbook step 7.

### D9 — Docs

This document is now the canonical M7 record (Parts I–III). At M7-E landing: the migration-master
milestone banner marks M7-E DONE; in-file docs describing the inert state are updated
(`background_catchup_worker.dart` / `ios_background_catchup.dart` headers,
`live_sync_provider.dart:19-38` flag doc + the stale `// ignore: avoid_redundant_argument_values` at
:38 removed **iff** `flutter analyze` confirms it unnecessary, `AndroidManifest.xml` receiver comment,
`AppDelegate.swift`/Swift-handler "inert" comments, and `main.dart:217-221` per A9); `haven-core/
SECURITY.md` gains a **"Scheduled background wakes (M7)"** subsection (receive-only by construction,
triple consent gating, presence-only logging, M10.1 pending-wipe interaction; wording per A9 — the
wake holds a full `CircleManagerFfi` but invokes only `run_catchup_all_circles`, which never authors,
`try_acquire_background` yielding to any authoring writer; per-platform triggers). The
persistent-connection disclosure remains an M11 item. Owner checklist = §6 (canonical; no separate
file).

## Binding amendments from independent confirmation (2026-07-05) — folded above as current truth, labels retained

Both independent reviewers (security, architecture — read-only) returned APPROVE-WITH-FIXES. These
amend the sections above and take precedence where they conflict; the labels remain referenceable
because external code cites them.

- **A1 (SEC, MEDIUM — rollback completeness):** Add **gate 0** `if (!backgroundCatchupEnabled) return
  true;` FIRST (before consent). The Android worker previously had no compile-time flag gate, so §7's
  "one commit re-inerts everything" was false for in-place-updated devices with a live JobScheduler
  registration. + unit test + guard pin. Final order: **flag → consent → pending-wipe → FGS-alive →
  foreground-active → sweep**.
- **A2 (SEC, MEDIUM-LOW — bootstrap order):** In `_runCatchupViaWorkerBootstrap`, load identity and
  **bail on null pubkey BEFORE `CircleManagerFfi.newInstance`** (D1 sketch had DB-before-identity).
  Closes post-successful-logout residue (fresh empty DB + keyring key that M10.1's retry does NOT
  clean — retry only covers marker-still-set) and makes D2 mitigation (ii) hold in the worker.
- **A3 (ARCH, DEFECT release-visible — iOS arming lag):** `AppDelegate.swift` arms SLC/BGTask in
  `didFinishLaunching` BEFORE Dart writes the mirror, so an upgrading user (and a same-session
  toggle-enabler) arms NOTHING until the second launch. **Fix:** override
  `applicationDidEnterBackground` to call `slcHandler.startMonitoring()` +
  `bgTaskHandler.scheduleNextCatchup()` — both idempotent, `isEnabled()`-gated at call time. Scope
  therefore INCLUDES `ios/Runner/AppDelegate.swift` (plan §2 item 5's "iOS doc-only" is superseded).
- **A4 (ARCH, DEFECT lane-fatal — JobScheduler namespace):** androidx.work 2.10.x schedules into
  namespace `androidx.work.systemjobscheduler` on API 34+. Every force-run must be `cmd jobscheduler
  run -f -n androidx.work.systemjobscheduler com.oblivioustech.haven <jobId>`; dumpsys id extraction
  must be namespace-tolerant.
- **A5 (ARCH, FEASIBILITY — keyring):** `m7_worker_setup_test` must install the **real platform
  keyring BEFORE any `_lib` bootstrap** — `TestUser` calls `useInMemoryKeyringForTest()` (process-
  global, first-installed-wins); an in-memory key dies with the drive process and the separate-process
  worker could never decrypt. Real-keyring viability on the AVD is proven
  (`android_native_keyring_store` + green `keyring_test.dart`).
- **A6 (ARCH, TEXT+FLAKE — reboot mechanism):** WorkManager reboot survival = its own
  `RescheduleReceiver` + Room DB (`setPersisted(false)`), NOT persisted JobScheduler jobs. The
  post-boot "job listed again" assert must be a **bounded poll**.
- **A7 (SEC, LOW — release logcat):** Replicate `main.dart`'s `kReleaseMode` `debugPrint` silencing at
  the top of `callbackDispatcher` (the worker isolate never runs main()'s silencer; CI lanes use debug
  builds so runtime proofs are unaffected).
- **A8 (SEC, LOW — guard pins):** guards **14h** (pin `writeCatchupEnabledMirror()` +
  `registerIosBackgroundCatchupHandler(` call-sites in `main.dart`) and **14i** (pin the new
  `applicationDidEnterBackground` re-arm) — the D7 sim target calls the function itself so it cannot
  detect call-site removal.
- **A9 (DOC accuracy):** D2 text states the launch-retry cleanup applies only to the marker-still-set
  branch. SECURITY.md wording per D9. Add `main.dart:217-221` to the D9 in-file doc list.
- **A10 (POLISH):** export the worker gate-exit marker strings as consts + unit-pin them (the lane
  greps those exact strings; drift = silent lane red); defensive try/catch around the worker's
  `RustLib.init()` (duplicate-init tolerance); wrap the second iOS sim invocation in `nick-fields/
  retry`; prefer strfry connection-line grep over raw `wc -l` for the silence assert; rollback §7 item
  5 explicitly flips `ios_bg_mirror_test.dart`'s internal `isTrue` assert; `setup-network-guard.sh`
  is NOT applicable to the silence assert (blocks 80/443 only, not 7777).
- **A11 (adopted optional):** the step-3b `prefs.reload()` re-reads CONSENT as well as the wipe marker
  (same reload, zero extra cost).

## §2. Exact file-by-file change list

**Flutter/Dart (production):**
1. `live_sync_provider.dart` — `:39` `false` → `true`; update flag doc (:19-38); remove
   `// ignore: avoid_redundant_argument_values` (:38) if analyze confirms it stale.
   `liveSyncEnabled` (:17) untouched.
2. `background_catchup_worker.dart` — (a) `runBackgroundCatchupTask` gains required `isPendingMlsWipe`
   + `isForegroundActive` injectables; gate order **flag → consent → wipe → FGS → foreground →
   sweep**; presence-only `debugPrint` markers on every exit path (exported as consts, A10);
   (b) `callbackDispatcher` wires the two new prod impls (direct `prefs.getBool(kPendingMlsWipeKey)`;
   `BackgroundLocationManager.isForegroundActive`) + gate-0 flag check (A1) + release-logcat silencing
   (A7) + defensive `RustLib.init()` (A10); (c) `_runCatchupViaProviders` stub →
   `_runCatchupViaWorkerBootstrap` per D1 + A2; (d) header doc rewrite. `cancelBackgroundCatchup`
   untouched (flag-independent rollback safety).
3. `background_location_manager.dart` — add `autoRunOnBoot: true` to `ForegroundTaskOptions`.
4. `AndroidManifest.xml` — RebootReceiver `enabled="false"` → `"true"`; comment rewritten.
   RestartReceiver untouched.
5. `ios_background_catchup.dart` — doc-only (header + D3 note).
6. `ios/Runner/AppDelegate.swift` — **(A3, added to scope)** override `applicationDidEnterBackground`
   to re-arm SLC/BGTask idempotently.

**Tests:** `background_catchup_worker_test.dart` (extend), `ios_background_catchup_test.dart` (flip
the flag pin), new `m7_worker_setup_test.dart` / `m7_worker_pending_wipe_test.dart` /
`m7_worker_disable_test.dart` (D6), new `ios_bg_mirror_test.dart` (D7).

**CI:** `scripts/ci/check_m7_native_wake_guards.sh` (checks 14a–14i + header, D5),
`.github/workflows/e2e-background-catchup.yml` (new, D6), `ci.yml` (fan-out `needs: [rust-check]`),
`e2e-ios.yml` (second scenario + plist assert, D7), `tooling/e2e/ci/run-m7-background-catchup.sh`
(new orchestrator). `build-integration-apks.sh` needs NO change.

**Docs:** this file + `docs/WN_RELAY_EPOCH_SYNC_MIGRATION.md` + `haven-core/SECURITY.md` per D9.

**Rust: zero changes.** The FFI surface (`run_catchup_all_circles`, `rust_builder/src/api.rs`) and
core are already complete; no `regenerate_frb.sh` run. MDK pristine.

## §3. New/updated test list (name → what it proves)

**`background_catchup_worker_test.dart` (extend; existing 7 groups preserved, updated for the two new
required params):**
- `pending-wipe marker set → returns true, runCatchup and FGS/foreground checks never called` — gate
  2 exists, fail-closed, ordered AFTER consent (`calls == ['sharingCheck','wipeCheck']`).
- `pending-wipe check throws → returns true (clean no-op), no sweep` — security-gate errors fail closed.
- `consent disabled AND wipe pending → exits at consent (calls == ['sharingCheck'])` — gate 1 first.
- `foreground active → returns true, runCatchup never called` — gate 4 skip.
- `foreground check throws → proceeds to sweep` — battery-gate errors fail open.
- `full green path calls gates in order flag→consent→wipe→fgs→foreground→catchup` — the order pin.
- (existing) sharing-disabled / FGS-alive / sweep-throw→false / sharing-check-throw→true /
  FGS-check-throw→proceed — all preserved unweakened.

**`ios_background_catchup_test.dart`:** group at :282 becomes `backgroundCatchupEnabled — RELEASED as
true (M7-E)` (asserts `isTrue`, reason points at this doc + guard 14a). Existing handler tests already
parameterize the flag via `catchupEnabled` — unaffected.

**Unchanged on purpose:** `catchup_service_test.dart`, `catchup_service_background_gate_test.dart` (C3
chokepoint), `background_scheduling_teardown_test.dart`, `pending_mls_wipe_service_test.dart`,
`live_sync_provider_test.dart` (M11 pin).

**Integration (emulator/sim):** the three `m7_worker_*` targets feed Phases A/C1/C2; `ios_bg_mirror_
test.dart` → mirror=true + Swift channel reachability on real iOS.

**Rust:** no new tests — the deterministic exclusion proofs already exist and are cited by name in
D6 Phase D (`write_lock.rs:128,149`; `manager.rs:6691,9765`).

## §4. CI lane design — summary

| Lane | New/changed | Proves |
|---|---|---|
| `repo-guards.yml` Background-wake invariants (existing, every push) | guard checks 14a–14i | released state pinned; silent regression to inert impossible |
| `e2e-background-catchup.yml` (new, `needs: rust-check`) | Phases A/B/C1/C2 + secret scan | worker isolate boots Rust+SQLCipher+keyring cold; sweep decrypts real peer traffic; job survives reboot; RebootReceiver resolvable; consent + wipe gates hold at runtime with zero network |
| `e2e-ios.yml` (extended) | second target + plist assert | mirror true on-device; Swift handlers registered/reachable |
| `flutter test` / `cargo test` (existing) | §3 units | gate order, fail-modes, flag pins |

All scripts checked-in under `tooling/e2e/ci/` with strict flags + trap cleanup + bounded polls +
evidence-first artifact upload.

## §5. Local-emulator validation runbook (pixel8a AVD; run BEFORE wiring CI, to pin Phase A counters)

```bash
# 0. Start relay + emulator
bash tooling/e2e/ci/start-strfry.sh                      # ws://10.0.2.2:7777 from the AVD
~/Android/Sdk/emulator/emulator -avd pixel8a -no-snapshot-save &
~/Android/Sdk/platform-tools/adb wait-for-device

# 1. Build + drive the setup target
cd haven
export HAVEN_E2E_RELAY=ws://10.0.2.2:7777
flutter build apk --debug --target-platform android-x64 \
  --target=integration_test/m7_worker_setup_test.dart \
  --dart-define=HAVEN_E2E_RELAY=$HAVEN_E2E_RELAY
adb install -r build/app/outputs/flutter-apk/app-debug.apk
adb shell pm grant com.oblivioustech.haven android.permission.ACCESS_FINE_LOCATION
adb shell pm grant com.oblivioustech.haven android.permission.POST_NOTIFICATIONS
flutter drive --driver=test_driver/integration_test.dart \
  --target=integration_test/m7_worker_setup_test.dart --use-application-binary \
  build/app/outputs/flutter-apk/app-debug.apk

# 2. Go cold WITHOUT force-stop (force-stop strips JobScheduler jobs until next launch)
adb shell input keyevent HOME && adb shell am kill com.oblivioustech.haven

# 3. Find + force-run the WorkManager job (A4 namespace)
adb shell dumpsys jobscheduler | grep -n 'com.oblivioustech.haven/androidx.work'
adb logcat -c
adb shell cmd jobscheduler run -f -n androidx.work.systemjobscheduler com.oblivioustech.haven <jobId>
adb logcat -v time | grep -m2 -E 'CatchupWorker.*(bootstrap ok|sweep complete)'
#   RECORD the counters here — they pin the CI Phase A asserts.

# 4. Reboot re-arm
adb reboot && adb wait-for-device
until [ "$(adb shell getprop sys.boot_completed | tr -d '\r')" = "1" ]; do sleep 2; done
adb shell wm dismiss-keyguard || true
adb shell dumpsys jobscheduler | grep com.oblivioustech.haven          # bounded poll (A6)
adb shell cmd package query-receivers --components -a android.intent.action.BOOT_COMPLETED \
  | grep RebootReceiver                                                # receiver live
adb logcat -c && adb shell cmd jobscheduler run -f -n androidx.work.systemjobscheduler \
  com.oblivioustech.haven <jobId>
adb logcat -v time | grep -m1 'sweep complete'                         # post-boot cold wake

# 5. Pending-wipe + disable negatives: repeat step 1's build/drive for
#    m7_worker_pending_wipe_test.dart then m7_worker_disable_test.dart (install -r, NO uninstall),
#    then step 2+3 each time, expecting the respective no-op marker and ZERO new strfry lines.

# 6. Secret scan of everything captured
bash ../tooling/e2e/ci/scan-logs-for-secrets.sh /tmp/local-m7-logs/

# 7. FGS restart-on-boot (autoRunOnBoot) — LOCAL-ONLY (needs the real enable flow):
#    install the plain app APK, onboard, Settings→Location→enable background sharing
#    (grants ACCESS_BACKGROUND_LOCATION via the Settings flow), verify the FGS notification,
#    `adb reboot`, wait for boot, then:
adb shell dumpsys activity services com.oblivioustech.haven | grep -i foreground
#    EXPECT the flutter_foreground_task service resurrected (RebootReceiver + autoRunOnBoot).
#    location-type FGS from BOOT_COMPLETED is permitted on API 34/35 only with bg-location granted.

# 8. `adb root` BOOT_COMPLETED injection (optional faster iteration on google_apis images):
adb root && adb shell am broadcast -a android.intent.action.BOOT_COMPLETED \
  -p com.oblivioustech.haven
```

## §6. Owner checklist (physical iPhone — cannot be automated; Simulator cannot fire BGTasks)

Everything else in M7-E is code-complete, flag-live, unit-tested, statically guarded, and (Android)
runtime-proven in CI + on the local emulator. **One** proof cannot be done by CI or the Simulator and
needs a physical iPhone with Xcode attached, because `BGTaskScheduler` refuses to run on the Simulator
(`.submit()` returns `notPermitted` there, which Haven swallows). Do this once before the public
release.

**DEFERRED IN FULL as of 2026-08-30 — the project has no iPhone** (owner constraint, recorded
verbatim in `docs/POWER_EFFICIENCY_PLAN.md` §2.5). Every item below stays **authoritative and owed**:
none of them has been replaced by a CI lane, and where a phase merged on CI evidence instead — P3 did,
on the re-based bundle in that plan's §5.3 WP3-2 — the item states what that evidence does not reach.
Run the whole checklist when hardware returns; nothing here may be deleted, weakened or silently
treated as satisfied in the meantime.

**Prerequisites:** a physical iPhone; a debug/Release-like build installed from Xcode; background
sharing enabled in Haven (Settings → Location); at least one circle with a peer who will publish a
location. The authorization tier is per row — items 1, 2, 2b and 3 want Always; item 0 has one row per
tier and says which.

0. **Background PUBLISH continuity — four rows: 0a, 0a-provisional, 0b, 0c.**
   **DEFERRED — no iPhone available (see `docs/POWER_EFFICIENCY_PLAN.md` §2.5); STILL
   AUTHORITATIVE, run when hardware returns.** ⚠️ RE-RUN REQUIRED: the first run of this item
   (2026-08-20) FAILED — publishing stopped on backgrounding — which is what motivated the
   session-object hardening (see the history entry of the same date). It has NOT been re-run
   since, and power-efficiency phase P3 (2026-09-04) changed the shape under test again and
   merged on the re-based CI bundle in `docs/POWER_EFFICIENCY_PLAN.md` §5.3 WP3-2 instead,
   because the project has no iPhone. **These rows are an owed proof, not a closed one.** Do
   not delete them, do not fold them back into one, and do not read a green
   `e2e-ios-background-publish` lane as having run them: a simulator cannot suspend a process
   on the OS's own hours-scale schedule (the 2026-08-23 second changelog entry closes with exactly
   that instruction), cannot render the status bar — so it can never tell a pill from an arrow —
   and has no `CLServiceSessionDiagnostic` answer to give
   under a provisional grant. Writing the rows out now is deliberate: the steps, the expected
   observations and the Console recipe are cheapest to record while the design is fresh, and a
   checklist reconstructed later omits exactly the details that make it decisive.

   **Why four rows.** Since P3 the iOS posture is decided by ONE predicate,
   `HavenBackgroundSessionHandler.alwaysConfirmed`, and not by `authorizationStatus`: only a
   POSITIVELY confirmed Always (iOS 18+, a `CLServiceSessionDiagnostic` with
   `alwaysAuthorizationDenied`, `authorizationRequestInProgress` and `insufficientlyInUse` all
   false) releases the `CLBackgroundActivitySession` and clears
   `showsBackgroundLocationIndicator`. When-In-Use, a *provisional* Always (iOS reports
   `.authorizedAlways` while the second prompt is unanswered, though it still treats the app as
   When-In-Use) and every iOS 17 Always (no diagnostics API to confirm with) keep the activity
   session and the blue bar. Each row exercises one of those shapes; 0c exercises the teardown
   they share. **The confirmed-Always shape is the un-evidenced one** — see 0a.

   **Prerequisites for every row:** the prerequisites above, plus Console access to the device
   (recipe below), and the relay-side capture of `docs/POWER_MEASUREMENT.md` §3 running for the
   whole window — a peer's marker is a UI observation, the capture is the evidence. Record each
   row's outcome in `docs/POWER_MEASUREMENT.md` §9 with the date, the iOS build and the commit.

   **Console recipe (all rows).** Xcode → Window → Devices and Simulators → the device → Open
   Console, filtered on `locationd`. The decisive lines, in the order they matter:
   * `"Location subscription"` — the RunningBoard assertion locationd holds on the app. Held =
     the keep-alive was granted; `invalidated` = it was withdrawn; `#Warning Denying process
     assertion` = it was refused outright (that last one is the 2026-08-23 signature of a
     session armed after the app stopped being in use — the 2026-08-23 second changelog entry).
   * `runningboardd` `Suspending task` — the process was suspended. Any occurrence inside a
     row's stationary window fails that row.
   * the client's `desiredAccuracy` lines — the only way to observe the P3 profile switch from
     outside the app, and what `docs/POWER_MEASUREMENT.md` §6 turns into the profile-duty
     column. Expect `kCLLocationAccuracyBest` while foregrounded and a drop to 100 within about
     2 minutes of backgrounding while stationary. (I: locationd is believed to log the client's
     requested accuracy; if it does not on the build you run, record that and fall back to the
     peer-side capture — the profile is then unobservable on-device, which is itself a finding.)

   0a. **Confirmed Always — the shape P3 introduced, and the one no CI can prove.**
   *Setup:* iOS 18 or newer; grant Haven **Always** and ANSWER the second prompt (Settings →
   Privacy & Security → Location Services → Haven → Always) so the grant is confirmed rather
   than provisional; background sharing ON; at least one circle with a peer.
   *Steps:* open Haven, wait for a fix on the map, press Home (do **not** force-quit), leave the
   phone stationary with the screen off for **≥ 2 h**. Then walk ≥ 150 m and stop.
   **Expected:**
   * **No blue bar at any point** — the status-bar location **arrow** only. This is the OD1
     claim, and it is the observation no simulator can make.
   * Settings → Privacy & Security → Location Services shows the arrow next to Haven.
   * Settings → Battery lists Haven with **Background Activity**.
   * The peer keeps receiving on the normal 72–168 s cadence for the whole 2 h, with **no
     relay-side `created_at` gap > 228 s** — the original wedge test. Grade it with
     `docs/POWER_MEASUREMENT.md` §3.5, not by eye.
   * **Added P4 — the receive side is now observable on the same capture.** Each publish instant
     should be accompanied by this device's REQ/CLOSE pair on the group plane, and there should be
     **no REQ from this pubkey between them**: the engine is paused between bursts, so a REQ that
     appears in a gap means something re-anchored in the background that must not have (a health tick
     that stayed armed, or an engine start that completed after the pause). The inbox (`#p`) REQ
     rides only every `INBOX_BURSTS_PER_REQ`-th burst; at the shipped value that is every burst, so a
     `#p` REQ per burst is expected, not a defect. This device's own receive of the PEER's location
     lands at this device's publish instants, not sub-second — worst case one peer interval plus one
     own interval plus the burst, which stays under `kReceiveSilenceThreshold`, so the sharing-health
     banner must still read healthy on resume.
   * Console: the `"Location subscription"` assertion stays held, no `Suspending task`, and the
     client's accuracy drops to 100 within about 2 minutes of backgrounding.
   * After the ≥ 150 m walk: the accuracy returns to Best and the peer sees the move within one
     interval.
   **If it fails** — any gap > 228 s, or any `Suspending task` — the confirmed-Always branch is
   wrong, and the revert is one line: drop `!alwaysConfirmed` from `wantsActivitySession` in
   `HavenBackgroundSessionHandler.arm()` so confirmed Always keeps the activity session and the
   bar like every other tier. The settings copy needs no change; it already follows the
   handler's own state. Record the failure here and in `docs/POWER_EFFICIENCY_PLAN.md` §5.3.

   0a-provisional. **Provisional Always — the fail-safe cohort, and the upgrade edge.**
   *Setup:* reset Haven's location permission (Settings → General → Transfer or Reset iPhone →
   Reset → Reset Location & Privacy, or delete and reinstall), then enable background sharing
   from inside Haven and take the When-In-Use grant, leaving iOS's deferred Always upgrade
   unanswered. While it is unanswered `authorizationStatus` reads `.authorizedAlways` although
   the EFFECTIVE authorization is When-In-Use.
   *Steps:* as 0a, but 30 min of stationary backgrounding is enough for the continuity half.
   Then, **while Haven is still backgrounded**, answer the deferred prompt with *Change to
   Always*. Foreground Haven afterwards.
   **Expected:**
   * The blue bar IS shown and the activity session IS held for the whole provisional period —
     the When-In-Use posture. That is the point of failing safe (OD-P3-b): this cohort keeps the
     exact object added after the 2026-08-20 failure.
   * Publishing does not stop across the instant the prompt is answered. `arm()` never withdraws
     an in-use claim from a background callback, so the session survives the upgrade.
   * The bar clears at the NEXT foreground — the deferred invalidate runs from
     `applicationWillEnterForeground` — and not before.
   This row is what closes the provisional half of V-P3-3 and all of V-P3-4. Nothing in CI can
   produce a provisional grant, so nothing in CI can stand in for it.

   0b. **When-In-Use — the row that already existed, restated for the native owner.**
   *Setup:* background sharing ON and only **When-In-Use** granted (deliberately NOT Always —
   this proves the foreground-started continuation path, backed by the held
   `CLBackgroundActivitySession` on iOS 17+).
   *Steps:* open Haven, confirm a fix on the map, press Home (do **not** force-quit), wait 5+
   minutes stationary.
   **Expected:** the blue status-bar location indicator stays visible the whole time (with the
   session held it shows whenever the app is backgrounded, even between fixes; under
   When-In-Use iOS shows it whether or not Haven asks for it), and a peer device keeps receiving
   this device's location on the normal 72–168 s cadence with no gap after backgrounding —
   movement is NOT required. If it STILL fails with the indicator visible, the failure is
   network-side, not CoreLocation: capture a device log around the publish attempts. If the
   indicator is NOT visible, run the Console recipe above around the backgrounding instant.
   Then repeat with background sharing OFF: **expected** — no blue indicator after
   backgrounding, the app suspends within the OS's normal grace period, and peers stop receiving
   until reopen. Since P3 the toggle-OFF stream is the same native session started with
   `allowsBackgroundLocationUpdates = false` (a pure function of the toggle, guard-pinned), so
   the pre-fix accidental keep-alive is still gone.
   While there, spot-check battery attribution over a longer backgrounded window. **The distance
   filter is no longer a variable here:** since P3 the iOS session belongs to
   `HavenLocationStreamHandler`, whose `init` sets `distanceFilter = kCLDistanceFilterNone` once
   for BOTH accuracy profiles and BOTH toggle states — there is no 1 m arm on iOS any more (1 m
   survives only on Android's foreground arm, and the `distanceFilter: -1` geolocator sentinel
   retired with the plugin path). What varies with the toggle is
   `allowsBackgroundLocationUpdates`; what varies with foreground and motion is
   `desiredAccuracy`, between Best and 100 m.
   Force-quit (swipe-kill) remains out of scope: no iOS app can continue timer-cadence
   publishing after termination, and since P3 a relaunched process is receive-only BY
   CONSTRUCTION on both paths — the native owner refuses a background-capable start from the
   background, and the cold-cache shortcut reads the native lifecycle, so the plugin one-shot is
   unreachable too. Only the receive-only SLC/region relaunch path (items 2 and 2b) survives a
   termination, and only with Always.

   0c. **Stuck indicator on teardown (iOS 18 and 26).**
   *Setup:* run this immediately after 0a, and again immediately after 0b.
   *Steps:* toggle background sharing OFF from Haven's Location settings with the app in the
   foreground, then background the app.
   **Expected:** the arrow (after 0a) or the bar (after 0b) clears within a minute, and Settings
   → Location Services stops showing Haven as active. `disarm()` is unconditional — the handler
   header states the contract in one sentence, *"arm() never withdraws a claim while
   backgrounded; disarm() always does"* — so a residual indicator is an OS defect, not a Haven
   one, and the code has already released everything.
   **Known OS defect, and no code mitigation exists:** after invalidating a When-In-Use activity
   session the pill can stay stuck (Apple DTS forum threads 771422 and 783585, iOS 18/26). If it
   sticks, file Feedback with the Console excerpt and record the iOS build here. Do not "fix" it
   by holding the session longer: that trades a real privacy regression for a cosmetic one.

1. **BGAppRefreshTask fires and runs a real catch-up.** Run from Xcode on the device; enable
   background sharing; confirm a peer can publish. Background the app (Home) — this calls
   `applicationDidEnterBackground`, which arms `scheduleNextCatchup()` (submits a
   `BGAppRefreshTaskRequest` for `app.haven.catchup`). In the LLDB console pause and simulate launch:
   ```
   e -l objc -- (void)[[BGTaskScheduler sharedScheduler] _simulateLaunchForTaskWithIdentifier:@"app.haven.catchup"]
   ```
   then `continue`. **Expected:** `HavenBGTaskHandler.handleBGTask` runs — reschedules the next task,
   re-checks `isEnabled()`, invokes `runCatchup` over `haven.app/ios_background_catchup`. Confirm
   `CatchupService.runCatchup(isBackgroundWake: true)` executed and (if the peer published while
   backgrounded) the location decrypted and applied (visible next foreground). (Identifier =
   `HavenBGTaskHandler.taskIdentifier` = Info.plist `BGTaskSchedulerPermittedIdentifiers[0]` — parity
   CI-pinned by guard check 5.) **Expiration path:** repeat, but before `continue` also run
   ```
   e -l objc -- (void)[[BGTaskScheduler sharedScheduler] _simulateExpirationForTaskWithIdentifier:@"app.haven.catchup"]
   ```
   **Expected:** clean expiration (`setTaskCompleted`), no crash, no watchdog kill.
2. **SLC relaunch after termination.** With bg-sharing on + Always granted, swipe-kill the app (SLC
   persists across termination). Move ~500 m+ (or Xcode *Debug → Simulate Location* / a GPX route).
   **Expected:** iOS relaunches Haven in the background with `launchOptions[.location]`; AppDelegate
   restarts SLC monitoring; the pending event drives a catch-up sweep. Confirm a backgrounded peer
   update was applied.
2b. **Relaunch REGION after termination, where SLC is quiet.** Companion to item 2, and the
   only way to exercise it: `HavenSLCHandler` now also monitors one ~500 m `CLCircularRegion`
   centred on the last delivered fix (re-centred on every SLC delivery), because SLC is driven
   by cell-tower transitions and a terminated app in a tower-sparse area can travel a long way
   before the OS calls anything "significant". Same gates as SLC (enable predicate + Always),
   released by the same `stopSLC`, and it reaches Dart through the same receive-only
   `runCatchup` channel. To test: with bg-sharing on + Always granted, swipe-kill the app,
   then use Xcode *Debug → Simulate Location* (or a real drive) to move **out of** the circle
   around where the app was last running. **Expected:** iOS relaunches Haven with
   `launchOptions[.location]`, `locationManager(_:didExitRegion:)` fires, and a catch-up sweep
   runs — same observable as item 2. Then verify the teardown: disable background sharing and
   confirm the region is released (Xcode's *Debug → Location* with the app relaunched shows no
   further wakes; `stopMonitoring()` iterates `monitoredRegions` so an OS-restored region is
   released too).
   **Honest ceiling — this CANNOT be proven in CI.** Region monitoring, like SLC and
   `BGTaskScheduler`, needs a real relaunch of a terminated process on hardware; the Simulator
   neither terminates nor relaunches an app for a geofence crossing, and the
   `e2e-ios-background-publish` lane only exercises what a still-running, foreground-started
   process keeps alive — the *publish* path on every leg, plus one *receive* plane per leg since
   OD4-d, and never a relaunch. Nothing
   in CI asserts that this region ever fires — only that it is armed and torn down with SLC
   (static guard + host tests). Treat item 2b as unverified until it is run here.
3. **Opt-out + rollback sanity.** Disable background sharing. **Expected:** `stopSLC` +
   `cancelAllBGTasks` fire; repeat steps 1/2 and confirm nothing runs (no wake, no relay contact).
   Re-enable → resumes.
4. **Locked-device wake.** Lock the phone soon after backgrounding; confirm no crash and a clean no-op
   or successful sweep per the keychain-accessibility note in `haven-core/SECURITY.md`.

**Already covered — do NOT re-do here:** Android WorkManager wake / isolate bootstrap+decrypt / reboot
re-arm / consent+pending-wipe no-ops / strfry silence → CI `e2e-background-catchup` lane + the local
pixel8a runbook (§5 / D6). iOS mirror write + handler registration → CI `e2e-ios`
(`ios_bg_mirror_test.dart` + plist assert). Fork-safety / writer exclusion → deterministic Rust tests
(`write_lock.rs`, `manager.rs`).

## §7. Rollback story (one commit re-inerts everything)

A single revert commit flips the four live switches back and removes the two CI expectations that
assume them, restoring the exact pre-M7-E posture (which shipped green):
1. `live_sync_provider.dart`: `backgroundCatchupEnabled = false` (re-add the ignore comment if analyze
   wants it).
2. `AndroidManifest.xml`: RebootReceiver `enabled="false"`.
3. `background_location_manager.dart`: remove `autoRunOnBoot: true`.
4. `check_m7_native_wake_guards.sh`: revert checks 14a/14c/14e/14f/14g/14h/14i (14b/14d — the
   liveSync and RestartReceiver pins — stay; state-independent).
5. `ci.yml`: remove the `e2e-background-catchup` fan-out entry (the lane's script self-guards on the flag
   and fails loudly if forgotten). `e2e-ios.yml` mirror assert flips its expectation or is removed;
   `ios_bg_mirror_test.dart`'s internal `isTrue` assert flips too (A10).
6. `ios_background_catchup_test.dart`: flag pin back to `isFalse`.

Already rollback-safe by prior design (no further action): `cancelBackgroundCatchup()` is
flag-independent so stale WorkManager tasks from a flag-ON build remain cancellable; the iOS mirror is
rewritten `false` on every launch of the rolled-back build, re-inerting Swift scheduling on first run;
the worker bootstrap may remain in-tree dead (registration is flag-gated + the iOS handler gate-0/1
returns). Field devices that never update still hold a registered periodic task — its every wake
re-checks the DURABLE consent key + C3 chokepoint (A1's gate 0 also re-inerts on-update), so user
opt-out remains enforced even on stale builds.

## §8. Explicit out-of-scope

- `liveSyncEnabled` flip, engine e2e, persistent-connection SECURITY.md disclosure → **M11**.
- `enablePeriodicSelfUpdate` (M5 kill-switch) and the self-update path.
- RestartReceiver: stays disabled + `tools:node="replace"` forever (guard-pinned, 14d).
- M9 / MIP-05 push — deferred by owner decision (guard check 9 enforces no push creep).
- Rust-side "refuse to open DB while pending-wipe marker set" (fully closes D2's LOW-severity ms-window;
  deliberate follow-up).
- Physical-ANDROID OEM matrix (aggressive battery managers) — post-release monitoring item; the AVD
  lanes + pixel8a runbook are the M7-E bar per §F.
- Physical-iPhone BGTask fire (§6).
- Any change to `CatchupService`, the FGS publish path, MDK, or the FFI surface.

## §9. Claim → verification map (every load-bearing claim, one line each)

| Claim | Verified by |
|---|---|
| Flag flip is complete & stays flipped | guard 14a + flipped unit pin |
| Registration actually registers (flag ON) | Phase A dumpsys assert |
| Worker isolate boots Rust+keyring+SQLCipher cold | Phase A `bootstrap ok` marker |
| Worker terminates in receive-only chokepoint, not authoring | guard 14f + code review + Phase A counters |
| Sweep decrypts real peer MLS traffic | Phase A `locations>=1` (pinned locally first) |
| Consent gate blocks a leaked wake w/ zero network | Phase C2 marker + strfry-silence |
| NEW pending-wipe gate blocks w/ zero network | unit order tests + Phase C1 |
| Gate order flag→consent→wipe→fgs→foreground | single order unit test + guard 14g |
| Job survives reboot (WorkManager persistence) | Phase B dumpsys-after-boot (bounded poll, A6) |
| RebootReceiver enabled + intent-filter intact at runtime | Phase B query-receivers + guard 14c + check 2 |
| autoRunOnBoot restarts FGS after boot | runbook step 7 (local, deterministic) |
| FGS-vs-worker & authoring-vs-sweep exclusion | Rust tests `write_lock.rs:128` / `manager.rs:9765` + gates 3–4 |
| iOS mirror true + Swift handlers reachable | D7 sim target + plist assert |
| iOS BGTask fires on hardware | owner checklist §6 (explicitly out of CI) |
| No secrets in any new log | presence-only markers by construction + `scan-logs-for-secrets.sh` |
| Rollback is one commit | §7 recipe (switch list closed and enumerated) |

---

# Part III — Design history & correctness contracts

*The fork-safety spine. These binding contracts and the Haven-owned persisted marker are the reason
the receive-only background path is safe without touching MDK. Superseded design drafts (v1→v3.1) are
condensed into the changelog; the load-bearing contracts and the marker design are stated formally
here as current truth.*

## Binding correctness contracts (the spine)

- **C-NOFORK-1 (single author):** No background/catch-up path may ever AUTHOR, STAGE, MERGE-its-own,
  FINALIZE, CONVERGE, or CLEAR a *foreground-authored* commit. Concretely forbidden in
  `decrypt_receive_only`: `self_update`, `add_members`, `remove_members`, `finalize_pending_commit`,
  `converge_commit`, `run_autocommit_converge`, opening a settle window. **Only the single foreground
  process advances epochs via its own commits.**
- **C-NOFORK-2 (regime-2 skip, pre-decrypt):** Before decrypting a group `kind:445`,
  `decrypt_receive_only` MUST check `has_pending_commit(nostr_group_id)` (persisted — the Haven marker
  below). If TRUE → **skip: do not decrypt, do not advance cursor.** Prevents (a) blind-applying a
  same-epoch sibling onto our divergent branch and (b) MDK auto-staging over / clearing the
  foreground's pending commit. Cross-process visible via the shared encrypted DB.
- **C-NOFORK-3 (in-process serialization):** When an engine `SESSION` exists in-process, catch-up
  holds `gate.for_group(hex).lock().await` (the same `MlsWriteGate` the engine worker and foreground
  finalize hold) around each group's decrypt. When no `SESSION` exists (cold background wake / when
  the FGS isolate is the only writer), C-NOFORK-2's persisted check + the process-global `WRITER_LOCK`
  (Part I §B) + MDK's rollback-journal `SQLITE_BUSY` (a second concurrent writer errors, never
  corrupts/forks) are the guard. Both layers together are fork-safe. (Android background is
  SAME-PROCESS ONLY — no separate-process WorkManager MLS writer, since MDK sets no `busy_timeout`.)
- **C-CONVERGENT-MERGE:** Passively merging a peer's already-valid broadcast commit
  (`GroupUpdate{None}`, epoch N→N+1) is CONVERGENT, not divergent — it authors nothing. Permitted, and
  advances the cursor (matches `plan_outcome`; peer merge authors nothing — `commit.rs:83`).
- **C-CURSOR (lossless, batch-level):** Per circle, sort candidates ascending by `(created_at, id)`,
  process in order, advance the cursor high-water-mark ONLY to the `created_at` of the last event in
  the longest **contiguous prefix of applied events** (Location or applied `GroupUpdate{None}`). STOP
  the advance at the first skipped / AutoCommit / competing / unprocessable event — so an un-applied
  commit is always re-fetched next wake. (`advance_sync_cursor` is monotonic-max, `manager.rs:2776`; a
  bare per-event advance would permanently skip.)
- **C-BG-MEMBERSHIP (scoped limitation, owner-accepted):** Background catch-up does NOT drive
  membership. A peer proposal that MDK auto-stages during a background decrypt (reachable only when NO
  pending commit pre-existed, per C-NOFORK-2) is **NEVER cleared** — leave the staged commit in place
  (so the marker stays set and future wakes skip), **stop the cursor before it**, and let the
  FOREGROUND engine / anti-entropy converge it on next foreground. A bounded, documented delivery
  deferral consistent with the migration's D3 ("prevent new forks only") and "receive-only =
  eventual-consistency-on-next-foreground." (This corrects v2's clear-then-defer, which permanently
  dropped the leave — MDK's `auto_commit_proposal` `mark_processed`es the proposal, so a cleared
  proposal is never re-delivered.) The AutoCommit case is rare in background (proposals are typically
  admin-committed while the admin is foreground).

## ~~MDK stays PRISTINE at v0.7.1 (rev 93ae324)~~ — the research that forces the Haven-owned marker

> **The PIN in this heading is history, the CONCLUSION is not (noted 2026-09-09).** Haven left v0.7.1 on
> 2026-07-18: the tree pins the five Dark Matter crates at MDK v0.9.4, rev `e391adc133a9…`
> (`haven-core/Cargo.toml`; `docs/MDK_DARKMATTER_MIGRATION_PLAN.md`), and §E's heading in Part II carries the same
> stale pin for the same reason. What survives unchanged is why the Haven-owned marker exists — the pinned rev still
> exposes no public read accessor for a staged commit (`relay/live_sync/processor.rs` says so at `e391adc`, and
> OD4-c's whole shape follows from it) — and the no-fork rule. Read the version numbers in this section as the
> state of the research when it was done.

C-NOFORK-2's ideal primitive would be MDK's `load_mls_group(id)?.pending_commit()`, but it is
**inaccessible in the pinned MDK**: `load_mls_group()` is `#[cfg(feature="debug-examples")]` pub /
else `pub(crate)` (`mdk-core/src/groups.rs:318-337`), maintainer-flagged "not for production use";
`get_group()` returns a storage record with no `pending_commit()`. haven-core does not (and should
not) enable `debug-examples`.

Upstream research (all refs): our pin `93ae324` = v0.7.1; latest tag v0.8.0; `parres-hq/mdk` and
`marmot-protocol/mdk` are the same repo. **NO version/branch exposes a public pending-COMMIT
detector** — v0.8.0's new public `pending_member_changes`/`pending_added_members_pubkeys`/
`pending_removed_members_pubkeys` read `pending_proposals()`, NOT `pending_commit()` (they miss a
staged self-update/membership commit — the actual regime-2 hazard). **NO ref adds `busy_timeout`.**
Owner rule: no fork/patch of MDK; upgrade only if a later commit provides the function — it does not.
→ **MDK stays clean at v0.7.1.** A v0.8.0 upgrade is deferred (orthogonal, high-risk MLS-core bump
that would invalidate the M3b/M4/M6 behavior pins; does not help M7).

## The Haven-owned persisted `staged_commits` marker (replaces the infeasible MDK primitive)

**Table** in `circles.db` (SQLCipher, shared, cross-process visible):
```sql
staged_commits(nostr_group_id_hex PRIMARY KEY, staged_epoch, updated_at)
```
`nostr_group_id_hex` stored **canonical lowercase** (matching `canonical_group_hex`) to avoid a
case-split write/read. `has_pending_commit(nostr_group_id) -> bool` = row exists. This faithfully
mirrors MDK's `pending_commit` lifecycle without touching MDK internals.

**SET at ALL SEVEN staging paths that leave an unmerged MDK pending commit** (the earlier plan listed
4 and MISSED three live Dart admin flows — a fork risk). Implement via ONE private helper
`CircleManager::mark_group_staged(nostr_group_id)` called by each:
1. `self_update` (`manager.rs:2567`)
2. `add_members` / `add_members_with_welcomes` (`:975` / `:1029`)
3. `remove_members` (`:1095`)
4. `propose_admin_handoff` → `update_admins` (`:652`)
5. `propose_self_demote` → `self_demote` (`:855`)
6. `update_circle_relays` → `update_relays` (`:708`)
7. the `AutoCommit` outcome of `process_message_classified`

`create_circle` is EXCLUDED (MDK `create_group` self-merges its initial commit — no pending commit).

**CLEAR via a chokepoint — the two lowest-level verbs** `finalize_pending_commit` (→
`mdk.merge_pending_commit`, `:2551`) and `clear_pending_commit` (→ `mdk.clear_pending_commit`,
`:2597`), via helper `CircleManager::mark_group_unstaged`. EVERY finalize/clear path funnels through
these — `finalize_relay_update` (`:831`), `converge_commit`'s internal clears (`:2658` + loser legs),
`propose_leave`/`complete_leave` pre-clears (`:895` / `:934`), path-B `gated_converge`/`gated_abort` —
so clearing the marker inside those two methods covers all of them automatically.

**Crash-safe ordering (the two DBs cannot be atomic — `circles.db` and MDK's DB have no cross-DB
txn):**
- **SET-BEFORE-STAGE:** mark, then call the MDK stage; on stage error, best-effort un-mark.
- **CLEAR-AFTER-MERGE/CLEAR:** call MDK merge/clear, then un-mark.

A crash in either window leaves a **STALE marker** (MDK has no pending, marker set) → over-skip →
self-heals on next foreground finalize/clear; it **NEVER** leaves the fork-unsafe (staged, unmarked)
state. Pinned by a crash-window-simulation test.

**`has_pending_commit` FAILS CLOSED:** any `circles.db` open/read error (locked-device pre-first-
unlock, momentary lock) → return `true` (assume pending → skip decrypt), NEVER fail-open to `false`.
`run_catchup_all_circles` no-ops cleanly (empty `CatchupOutcome`) when storage is unavailable.

**Marker-consistency invariant (the load-bearing new contract):** the marker MUST be set/cleared
under the same gate as the corresponding MDK stage/finalize/clear, so it can never disagree with MDK's
real `pending_commit` state. A stale marker (set but MDK cleared) = a group wrongly skipped
(liveness; self-heals on next foreground finalize). A missing marker (MDK staged but marker absent) =
a fork risk (bg decrypts a sibling over a real pending commit) — so the WRITE sites must be
exhaustive. Enumerated + tested (`marker_matches_mdk_pending_state_after_every_op` drives each of the
7 staging methods + each finalize/clear path and asserts `has_pending_commit` == MDK's actual state).

**Foreground engine is intentionally marker-BLIND:** `EngineProcessor::process_group_event` does NOT
read the marker (it holds the gate + settle window instead); only `decrypt_receive_only` (catch-up)
reads it. Path-B converge clears the marker via the finalize/clear chokepoints. (Defense-in-depth: the
foreground path-B auto-commit leg also calls `mark_group_staged` to close the marker-absent window
during the settle wait / a mid-converge kill — not a fork, since MDK's
`OwnCommitPending→CompetingCommit→Skipped` is the structural barrier.)

**M10 teardown (lands with the marker):** `wipe_all_staged_commits()` (Rust+FFI) + bulk
`reset_all_sync_cursors()` wired into `deleteIdentity`; `DELETE FROM staged_commits WHERE
nostr_group_id_hex=?` in the `delete_circle` cascade (`storage.rs:824-877`) = wipe-on-leave; Dart:
`Workmanager().cancelAll()`, SLC stop, `BGTaskScheduler.cancelAllTaskRequests()`, clear
`kBackgroundIdleKey`/`kBackgroundSharingKey`.

## DoS + presence-only hardening (folded during implementation)

- `run_catchup_all_circles` caps every REQ (`group_filter(...).limit(CATCHUP_MAX_EVENTS_PER_PAGE=500)`,
  at strfry's `maxFilterLimit` so our own limit is the binding one) AND bounds the backward chase that
  follows a truncated page — `CATCHUP_MAX_PAGES_PER_CIRCLE=8`,
  `CATCHUP_MAX_EVENTS_PER_CIRCLE=4000` accumulated, plus the sweep deadline between pages — AND
  deadline-checks the inner decrypt loop. A malicious relay can't flood a circle's REQ into a
  background CPU/battery DoS, and hitting any bound marks the window incomplete so the cursor holds
  rather than skipping the tail (not a fork).
- `decrypt_receive_only` does NOT call `resync_circle_relays_from_mdk`; `ReceiveOnlyOutcome` /
  `CatchupOutcome` are all-counter structs (leak-free `Debug` by construction); storage-error debug
  logs route through `redact_hex_sequences`.

---

## Changelog (condensed)

- 2026-07-01 — v2 background-catch-up design RE-CONFIRMATION **REJECTED** (marmot): the C-NOFORK-2
  primitive `load_mls_group().pending_commit()` is inaccessible in the pinned MDK; cross-process
  fallback silently loses messages; background AutoCommit clear permanently drops the leave.
- 2026-07-01 — **v3 decision:** MDK stays pristine at v0.7.1 (rev 93ae324); adopt the Haven-owned
  persisted `staged_commits` marker as C-NOFORK-2's cross-process pending-commit detector; Android
  background restricted to same-process only.
- 2026-07-01 — v3.1 corrections folded (marmot round-3 REJECT-but-foldable, security SAFE-TO-BUILD):
  7 exhaustive marker SET sites (was 4); finalize/clear chokepoint; SET-BEFORE-STAGE / CLEAR-AFTER-
  MERGE crash-safe ordering; `has_pending_commit` fails closed; background AutoCommit never clears.
- 2026-07-02 — **M7-0..M7-4 post-implementation QC:** marmot FORK-SAFE, rust SHIP, security
  SAFE-AFTER-FIXES, flutter SHIP-AFTER-FIXES; all must-fixes folded (marker set on the foreground
  path-B auto-commit leg; 512-event/deadline DoS cap; redacted storage-error logs). Ships flag-OFF.
- 2026-07-02 — the first full native-wake draft (Android `workmanager` + `RebootReceiver`; iOS SLC/
  BGTask) was **REVERTED in full** (security REJECT): false "circles.db is WAL" premise (it is
  rollback-journal, `busy_timeout=0`), missing `DartPluginRegistrant`, `tools:node="replace"` on
  RebootReceiver, iOS `[weak channel]` capture, cancel-only-on-delete privacy regression.
- 2026-07-02 — approved master plan (Part I) produced (research → 1 draft → 4 reviewers, all
  APPROVE_WITH_FIXES, architecture unanimous), superseding the reverted native-wake draft; the writer-
  exclusion fix reframed as the real process-global Rust `WRITER_LOCK` (not the false shared-SESSION
  gate). M7-C/M7-D implemented **inert** (flag OFF), staged.
- 2026-07-05 — **M7-E DONE:** all M7 flags flipped LIVE on both platforms; Android WorkManager stub
  replaced with the real background-isolate bootstrap; iOS `applicationDidEnterBackground` re-arm
  added; static guard pins the released state (14a–14i); `e2e-background-catchup` runtime-proof lane added.
  Independent confirmation returned APPROVE-WITH-FIXES; amendments A1–A11 folded (Part II). Only
  remaining item: the physical-iPhone BGTask owner check (§6). `liveSyncEnabled` remains M11-owned and
  `false`.
- 2026-07-19 — **iOS background PUBLISH fix (unified stream).** Part I's premise that "iOS keeps the
  main isolate alive while actively sharing" was found broken in the field: geolocator supports only
  ONE position stream (Dart-side cache + native single-listener), so the pause-time
  `getBackgroundLocationStream()` silently returned the already-active foreground stream and the
  background `AppleSettings` never reached CoreLocation; additionally the publish path's one-shot
  `getCurrentPosition` uses a plugin CLLocationManager that never enables background delivery. Fix
  (separate change, own plan/review cycle): ONE unified stream whose iOS AppleSettings are a pure
  function of the background-sharing toggle (`locationStreamProvider` watches it; toggle-OFF now pins
  `allowsBackgroundLocationUpdates:false` — removing an accidental keep-alive for non-consenting
  users), publish cycles are served from the stream's cached fix, the send scheduler + motion trigger
  keep running through an iOS pause, and the C4 mid-pause-disable watcher moved to `_onPaused`'s iOS
  branch UNCONDITIONALLY (it was previously unreachable under the live `liveSyncEnabled` default —
  found by independent review, fixed pre-implementation). CI: `check_ios_background_publish.sh` in
  repo-guards + host tests; runtime proof = §6 item 0.
- 2026-08-20 — **iOS background PUBLISH hardening (CoreLocation session objects).** The owner's
  physical-iPhone test of §6 item 0 FAILED: publishing stopped on backgrounding despite the
  2026-07-19 fix being verifiably correct at every app layer (Dart pipeline, plugin flag
  application, plist, Keychain accessibility — four independent audits). Diagnosis (strongest
  remaining hypothesis; the legacy contract's documented rules say the config *should* work, but
  the field record of identically-configured apps being suspended on modern iOS is extensive):
  Haven relied solely on the LEGACY `allowsBackgroundLocationUpdates` contract, while Apple's
  supported background-location declaration since iOS 17 is `CLBackgroundActivitySession`
  (the When-In-Use background mechanism — keeps the app "effectively in-use") and since iOS 18
  `CLServiceSession(.always)` (Always is only *effective* for the modern delivery APIs while one
  is held). Fix: new `HavenBackgroundSessionHandler` (ios/Runner) holds both sessions while
  background sharing is enabled — armed synchronously in BOTH `didFinishLaunching` branches (the
  relaunch-retake window is seconds) and on every `applicationWillEnterForeground` (which also
  drops a held `.always` session after a Settings downgrade, closing the only OS-prompt path);
  `CLServiceSession` is created only when Always is ALREADY granted (never prompts). Dart:
  `IosBackgroundSessionService` (channel `haven.app/ios_background_session`), armed by
  `BackgroundSharingNotifier` with load-bearing ordering persist → arm → state-flip
  (session-before-stream-restart rule) and disarmed on every disable (Rule 10). map_shell's
  pause watcher now covers BOTH consent edges (C4 teardown AND the R1 stale-toggle re-arm: a
  pause racing the notifier's async load used to read `false` and never re-arm). CI:
  `check_ios_background_publish.sh` checks 8–10 pin the handler/AppDelegate/notifier invariants;
  NEW `e2e-ios-background-publish` lane drives a REAL OS background transition on the simulator
  (second-app launch → genuine `applicationDidEnterBackground`) and asserts session armed +
  publishes continue + the toggle-off negative twin — the first OS-level backgrounding proof in
  CI. (Amended 2026-08-23: the lane suspended twice, but neither run had a background-capable
  session armed in time, so neither said anything about the simulator either way — see the two
  entries below. §6 item 0 remains the final proof and MUST be re-run on a physical iPhone.)
  Post-implementation security review closed three gaps in the same change: (1) the load-time
  disclosure reconcile now actively disarms + runs `disableBackgroundScheduling` (the native
  launch arm had already read the stale `true` before Dart ran), with the disclosure key ALSO
  ANDed into the native arm predicate as a belt; (2) `arm()` now gates ALL session creation on
  granted authorization (When-In-Use or Always) — creating `CLBackgroundActivitySession` while
  `.notDetermined` (e.g. after a TCC reset with a persisted-true toggle) could otherwise drive a
  launch-time prompt the user never initiated; (3) `cancelNativeSchedulers` now also disarms, so
  identity deletion (which keeps the toggle pref) releases the keep-alive instead of re-arming it
  on every later launch. All three are pinned by guard checks 8/10.
- 2026-08-23 — **The bg-publish lane was proving nothing (CI run 32646436116).** P2 asserted ≥2
  kind-445 events in the 396 s after the real backgrounding and counted 0. Not a publish
  regression: the drive overrode `locationServiceProvider` with `FakeLocationService`, whose
  stream yields once and closes, so `Geolocator.getPositionStream` was never called and NO
  `CLLocationManager` updates session existed in the process — the drive had faked away the one
  mechanism `HavenBackgroundSessionHandler.swift:9-11` names as keeping the app executing
  (`CLBackgroundActivitySession` extends authorization, not execution; the log's
  `serviceSessionHeld=false` after arm is consistent). iOS therefore suspended the app ~28 s
  after backgrounding, and the oracle — co-resident in that process — was frozen with it: the
  P2 heartbeat printed `20s of 396s elapsed` at 15:14:59 and `40s of 396s elapsed` at 15:40:36,
  20 s of Dart clock across 25 min 37 s of wall clock. The 396 s timer expired on resume and
  returned its partial (0) set from a subscription whose socket had died. That the app then
  published while still reporting itself backgrounded (`profile anti-entropy tick skipped
  (background)` in the same instant as `publish done — accepted=1`) is the positive proof the
  publish pipeline was never stopped by backgrounding. **This means the simulator DOES suspend a
  backgrounded app**, correcting the 2026-08-20 entry above — what §6 item 0 still uniquely
  proves is the physical device's keep-alive under a real CoreLocation session, not that
  suspension is unreachable in CI. Fix: the drive runs the production `GeolocatorLocationService`
  (guard check 11 now forbids injecting a fake location service into this lane) behind a
  pre-mount authorization gate; the host drips two simulated fixes 5 m apart every 10 s. With
  background sharing ON the stream sets NO distance filter (`geolocator_location_service.dart:659`
  — `-1` = `kCLDistanceFilterNone`; Unit F, 2026-08-28), so the 5 m step no longer has a filter to
  clear — its only remaining role is to keep fixes flowing. The alternation still matters:
  displacement never nears `kMotionTriggerDistanceMeters` (100 m), so the drip cannot become a
  second publish driver. P2 gained `_failIfSuspended`, which compares wall clock against the wait's own duration
  (slack = 6 missed heartbeats) and reports a freeze as a freeze BEFORE counting, so a suspended
  run can never again be misreported as "the app stopped publishing". The ≥2 bound and the 396 s
  window are unchanged. The host's two waits are now derived rather than picked: `DISABLE_WAIT_SECS`
  = 900 (611 s worst case + half again) and `DISARM_WAIT_SECS` = 210 (200 s settle + 10 s
  in-flight grace), the latter bounded above by the 228 s kind-445 NIP-40 expiration so a leaked
  event cannot age out before the re-fetch sees it — replacing the 1500 s that let this
  suspension burn 25 min and surface as an ambiguous zero.
- 2026-08-23 (second entry) — **The bg-publish lane's own drive never armed the background stream
  (CI run 32661622879).** The 2026-08-23 fix above made the diagnosis honest — `_failIfSuspended`
  correctly reported "iOS SUSPENDED the app during P2: a 396 s wait took 1145 s" — but the lane
  still failed, now with the production `GeolocatorLocationService` AND a live 10 s
  simulated-location drip. That run's own `sim.logarchive`, parsed off the CI artifact, names the
  cause and it is **the drive, not the simulator**: at `20:03:28.804` the toggle flip tore the
  FOREGROUND location subscription down (`LocationSubcription #pwrlog client unsubscribing`) —
  Riverpod's `invalidateSelf` runs a provider's `onDispose` synchronously and defers the REBUILD to
  `markNeedsBuild` — and the replacement subscription with `setAllowsBackgroundLocationUpdates:
  allows:1` did not start until `20:03:36.860`, **0.43 s after SpringBoard had already set
  `visiblity is no`**. Eight seconds with no location session at all, because
  `IntegrationTestWidgetsFlutterBinding` inherits `LiveTestWidgetsFlutterBindingFramePolicy
  .fadePointers`, under which no widget build runs until the test pumps — and the drive pumped
  nowhere between `setEnabled(enabled: true)` and the backgrounding. locationd's response is in the
  same log: `#Warning Denying process assertion` ×10 across `20:03:36.687`-`.862`, then
  `20:03:38.812` it invalidated the `"Location subscription"` RunningBoard assertion it had been
  holding on the app, and at `20:04:12.273` runningboardd logged `Suspending task` once the app's
  own `FinishTask` grace expired. No jetsam, no memory kill; the app stayed suspended 1109.7 s
  until the host re-foregrounded it, and its ~110 queued `didUpdateLocations` callbacks all drained
  within 30 ms of the resume. A background-capable session may only be established while the app is
  in use — this one was established 0.43 s after it stopped being.
  **This retracts the previous entry's inference** that the two prior suspensions demonstrated
  anything about the simulator: run 32646436116 had no location session (faked service) and run
  32661622879 had one that arrived too late, so neither ever tested the keep-alive.
  Fix: P1 now pumps after the enable and waits for a FRESH fix from the rebuilt
  `locationStreamProvider` before signalling READY, so the session is live and delivering while the
  app is unambiguously foregrounded; guard **check 12** pins the pump, the wait and the
  `locationStreamProvider` assertion to the slice between the enable and the READY marker
  (mutation-tested against three ways of removing them). P2 split into **P2a** (a per-circle tick
  driven through the production scheduler from the backgrounded process must reach the relay —
  answerable inside any background grace, so "the pipeline broke" and "the process was frozen" stop
  being the same observation) and **P2b** (the unchanged ≥2 events / 396 s claim, now anchored
  `since` P2a's event so a driven publish cannot count toward it). P3 gained a direct, non-vacuous
  assertion — `isActiveForTest` must be false immediately after the disable, observed from the
  still-backgrounded process — because a suspended app is silent on the wire whether or not the
  disable worked, which made the settle-window diff alone vacuous here.
  **OPEN, and an owner decision if it lands:** Apple lists "the `UIBackgroundModes` key" among the
  features "not available in Simulator"
  (<https://developer.apple.com/documentation/xcode/testing-in-simulator-versus-testing-on-hardware-devices>),
  and DTS advises against testing background execution there at all — which would make P2b
  unprovable in CI regardless of this fix. The log evidence cuts the other way (that simulator's
  locationd did create a `CLBackgroundActivitySession`, did hold a RunningBoard assertion for a
  location client, and did deliver on a 10 s cadence throughout), and both failures are explained
  without it, so the claim is kept. If the next run has P2a green and P2b still reporting a
  suspension, the policy is genuinely absent on the simulator and the continuity claim must move
  out of CI to §6 item 0 — never into a widened window.

- 2026-09-03 — **P1 (power efficiency phase 1): one lifecycle rule for the location stream, and the
  R1 edge stated.** The pause/resume seam had been platform-branchy prose spread across
  `_onPaused`; it is now a single named rule, `shouldKeepLocationStreamWhilePaused({bg, isIOS}) =>
  bg && isIOS` (`location_provider.dart:35-38`), consulted from ONE place
  (`map_shell.dart:1319-1324`) and enforced by `check_android_location_power.sh` checks (7) and (8):
  (7) `suspendStream(` must precede `markForegroundActive(active: false)`, and (8) that call must sit
  inside the keep-rule conditional rather than a raw `Platform.isIOS` branch. The release is a
  direct, synchronous service call and never a provider rebuild — Flutter disables frames before the
  lifecycle observers run, so a release riding a `ref.watch`/`ref.invalidate` lands at RESUME, which
  is the bug this shape exists to prevent (`map_shell.dart:1314-1318`). `locationStreamProvider` is
  additionally fail-closed on a background LAUNCH: it reads `appForegroundProvider`, whose initial
  value is derived from `WidgetsBinding.instance.lifecycleState` rather than a literal, and returns a
  per-build placeholder that never completes instead of starting a session iOS would refuse.
  **The R1 edge, stated because it is a deliberate non-restart:** a background-sharing toggle that
  flips false → true while the app is already paused re-arms the publish scheduler, the motion
  trigger and the iOS receive timer (`map_shell.dart:1457-1468`), and it does NOT restart the
  location stream. The keep-alive is (re)established at the next FOREGROUND; until then the app
  publishes from the last-known fix for the roughly 30 s iOS grants a client-less background app.
  That is not a gap in the fix — a background-capable start issued from the background is refused by
  iOS outright (CI run 32661622879, the 2026-08-24 changelog entry at `:1248-1276`), so restarting
  there would fail loudly and buy
  nothing. The C4 edge (true → false while paused) is the mirror and is deterministic:
  `suspendStream()` + `clearCachedPosition()` + `disarm()` are called directly on the watcher, so
  consent withdrawal stops sharing at once instead of waiting for OS suspension.

- 2026-09-04 — **P3 (power efficiency phase 3): iOS gets a Haven-owned CoreLocation updates
  session, and the indicator becomes tier-dependent.** `HavenLocationStreamHandler.swift` replaces
  geolocator's position stream ON iOS ONLY (Android is untouched, and iOS one-shots stay on the
  plugin because `requestLocation()` does nothing while the same manager is updating). Its `init`
  pins the Apple 16.4 delivery shape once, for BOTH accuracy profiles and BOTH toggle states:
  `pausesLocationUpdatesAutomatically = false`, `distanceFilter = kCLDistanceFilterNone`,
  `activityType = .other`, and a `desiredAccuracy` that is never coarser than 100 m —
  `kCLLocationAccuracyBest` while foregrounded or moving, `kCLLocationAccuracyHundredMeters` while
  backgrounded and stationary, switched by a live property write and never by a restart. **The
  toggle-keyed `distanceFilter: -1` sentinel is retired with the plugin path**, so the "1 m filter
  on the opt-out arm" statement no longer applies to iOS at all (1 m survives only on Android's
  foreground arm). `onListen` is the only `startUpdatingLocation()` site and REFUSES a
  background-capable start while `applicationState == .background`, pushing
  `background_start_refused` through the event SINK (an `onListen` return value is reported to
  `FlutterError` and never reaches the stream); together with the cold-cache shortcut now reading
  the native `backgrounded` status instead of an in-process hint, a relaunched process is
  receive-only BY CONSTRUCTION on both paths — which is what
  `INV-L-IOS-WAKES-RECEIVE-ONLY` may now claim, and what closes the hole the failure analysis
  recorded under its downgraded-hypotheses list. Indicator/session policy moved onto one predicate,
  `HavenBackgroundSessionHandler.alwaysConfirmed` (false until a `CLServiceSessionDiagnostic`
  positively confirms Always on iOS 18+, and always false on iOS 17): confirmed Always releases the
  `CLBackgroundActivitySession` and clears `showsBackgroundLocationIndicator`; When-In-Use, a
  provisional Always and iOS 17 Always keep both. `arm()` never withdraws an in-use claim while
  backgrounded, `disarm()` always does. **What was NOT proven:** §6 item 0 is now four rows (0a
  confirmed Always, 0a-provisional, 0b When-In-Use, 0c stuck indicator) and all four are DEFERRED —
  there is no iPhone. P3 merged on the re-based CI bundle (`docs/POWER_EFFICIENCY_PLAN.md` §5.3
  WP3-2). **V-P3-3 — whether the confirmed-Always shape, with no activity session and the indicator
  flag false, keeps a foreground-started session delivering for HOURS — is UNKNOWN, and the closest
  physical neighbour of that configuration FAILED in the field on 2026-08-20** (the entry above).
  The containment is that every path P3 touches runs only while background sharing is ON, and that
  the fail-safe posture keeps provisional and iOS-17 Always on the When-In-Use shape, so only
  *confirmed* Always enters the un-evidenced one. The revert, if 0a ever fails, is one line in
  `arm()`.
- 2026-09-18 — **iOS reclaimed the drive inside P3's settle window, and the wrapper said nothing
  (CI run 35397118356, `always-live-sync`).** The drive printed every proof through
  `BACKGROUND_SHARING_DISABLED` and then died 42 s later, mid-window, with the test and its
  `tearDownAll` reported as "did not complete". Its own `sim-unified.log` names the sequence and
  the commit under test does not appear in it (that commit changed `toString()` renderings and
  field names only, no background manager, no SLC/BGTask handler, no silence path): at
  `22:18:26.05` the disable dropped every CoreLocation claim — `stopUpdatingLocation`,
  `setAllowsBackgroundLocationUpdates:0`, the service session invalidated,
  `stopMonitoringSignificantLocationChanges`, `cancelAllTaskRequests` — leaving the app holding
  only the two `Flutter debug task` UIApplication background tasks the DEBUG engine begins on
  backgrounding (taskIDs 4 and 6, created at `22:13:27`, never ended). At `22:19:03.899` RunningBoard
  delivered the expiration warning and the invalidation in the same 0.6 ms; unlike every healthy
  run, no `Expiration notification complete`, no `Firing background task expiration handlers` and no
  `Ending task … Flutter debug task` followed, and the process never logged again. The host's
  VM-service connection closed 4.9 s after that, which is what `IntegrationTestTestDevice` turns
  into a closed suite channel and package:test into "did not complete". The Dart heartbeat due 20 s
  after the disable — present in all four comparison runs (35376588206, 35311161479,
  35280144455 x2) — never printed, so the app had already stopped executing before the warning
  arrived. **Not proven, and not provable from the artifact:** which process ended it. `Suspending
  task`/jetsam/watchdog lines belong to `runningboardd`, `SpringBoard` and the kernel, which the
  Runner-scoped export excludes by predicate and the device-wide export excluded by its blind 64 MiB
  TAIL cap — that export's window began at `22:21:56`, 2 min 52 s AFTER the death. Fixes: the
  workflow adds a third, predicate-scoped export (`sim-lifecycle.log`: every non-Runner process's
  lines that name the app, uncapped in practice), so the next occurrence is attributable; and
  `run-ios-bg-publish.sh` shortens the exposure it controls — `bgp_wait_until` measures WALL CLOCK
  instead of summing its own sleeps, and the DISARM budget is anchored on the drive's own disable
  append (`bgp_budget_after_lag`, one-sided so it can never wake the app early), which takes the
  measured 216.8-222.0 s wake-up back to ~210 s and restores the margin to the 238 s kind-445
  eviction bound past which P3's re-fetch collects silence and the wire half passes VACUOUSLY.
  **What no wrapper can fix:** from the disable the app has no execution claim — that is the
  guarantee under test — so the OS may take the process at any point in those 200 s. The DISARM
  wait's drive-exited branch now says so, with the app's process state beside it (calibrated at
  READY, so a read that never saw the app reports `unknown` rather than blaming iOS), instead of
  leaving an rc=79 to be read as an assertion failure.
- 2026-09-21 — **It was `runningboardd`, and P3 no longer needs the app to survive its own window
  (CI run 35622556197, job 106414462583, `when-in-use-live-sync`).** The 2026-09-18 entry above left
  one thing unproven — *which process ended it* — and added `sim-lifecycle.log` so the next
  occurrence would answer it. This is that occurrence, and it does. The drive printed every proof
  through `BACKGROUND_RECEIVE_OK`, disabled at `16:50:04.64`, and died 38 s later. In order:
  `16:50:04.44` the app releases every CoreLocation claim (`stopLocation_nl`, the SLC unsubscribe,
  `CLBackgroundActivitySession … dealloc`, `cancelAllTaskRequests`) — so **P3's native half
  demonstrably ran, from the app, before anything killed it**; `16:50:05.49` `runningboardd`
  invalidates the assertion `locationd` held on the app *because* the app stopped being a location
  client, and activates the delayed shared `FinishTask` assertion in its place; `16:50:34.74`
  "Assertions for process will expire soon"; `16:50:37.84` "Assertion did invalidate due to
  timeout"; `16:50:41.43` "Timed-out waiting for process … to invalidate assertion … Suspending
  task."; `16:50:41.82` "Terminating with context: `<RBSTerminateContext| code:0x2182BAD2 …
  maxTerminationResistance:Interactive>`"; `16:50:42.05` `launchd_sim` records
  `OS_REASON_RUNNINGBOARD`, "ran for 396864ms". **No jetsam of the app, no crash report, no
  `EXC_*`, no `0x8badf00d` watchdog** — and the assertion nobody ever ended is the DEBUG Flutter
  engine's own `Flutter debug task` (taskIDs 4 and 6, created at the backgrounding), which UIKit
  itself warns about in every run of this lane: *"was created over 30 seconds ago. In applications
  running in the background, this creates a risk of termination."* So the terminator is the ordinary
  RunningBoard expiry that follows an app losing its background claim, and the app lost it because
  the disable worked. **Not a product defect: the reclaim is the privacy-best outcome.** Whether the
  frozen process acknowledges the suspension inside RunningBoard's few seconds is an OS scheduling
  race, which is why the same leg was green in 35524002720 (the app stayed suspended for the whole
  207 s and finished P3 after the wake-up).
  Fix: P3's wire half moved to a witness the OS cannot reclaim. `tooling/e2e/ci/bgp-wire-probe.dart`
  (standalone Dart, `dart:io` only) asks the lane's own relay, on EVERY path once the window has
  elapsed, whether any kind-445 was created inside it; `run-ios-bg-publish.sh` holds the window open
  when the drive dies early (capped by the wake-up budget it replaces, so the lane costs no extra
  wall clock) and ends on one of four PROVEN verdicts — `holds`, `leak`, `relaunched`, `unproven` —
  with no default-to-green. Only `holds` excuses anything, and only the two markers a dead process
  could not print. The native half on that path is carried by the reclaim itself: an app still
  holding a location keep-alive is an app iOS keeps executing, which P2a/P2b measure for 400+ s
  every run, and a simulator has no jetsam. What it does **not** prove is that the release was
  *prompt* — the drive's own disarm poll owns that, and the other two legs run it. The count is an
  answer only because the drive disposes the synthetic peer before P3 (the host cannot tell two
  authors apart: ephemeral per-message keys, one shared `h` tag), and the probe carries a control
  question whose answer cannot be zero, so an unread relay is never reported as a silent window.
  Guard **check 19** of `scripts/ci/check_ios_background_publish.sh` pins all four premises (one
  window across three files, the peer disposed first, the probe's control and range, the excuse's
  single source and exact width), mutation-tested; the probe proves itself on the runner in the
  wrapper's preflight.
