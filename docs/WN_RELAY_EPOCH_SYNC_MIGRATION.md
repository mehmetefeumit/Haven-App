# Haven Persistent-Sync Migration (WN relay+epoch sync) — Master Plan & Milestone Index

**Status (2026-07-14):** M1–M8 + M7-E + M10 **DONE**; M9 **DEFERRED**; M11 **DONE** — Phase-A engine wiring + REV-1 committed (`main@b2c82ab`); the flag-on e2e lanes are green on both platforms and promoted into per-commit CI (`b8ee978`); the **Phase-B flip has landed** — `liveSyncEnabled` now defaults **true**, so production ships the persistent live-sync engine. Two non-code residuals remain before tagging a release: one clean per-commit CI run (the first was infra-cancelled mid-emulator-boot, not a scenario failure) and an owner/physical-device foreground↔background socket sanity check (the iOS simulator cannot reproduce real-device suspension). Self-commit was **REMOVED** in M5 (kill-switch + lint guard); the concurrent-self-update fork this migration targets is CLOSED by M5 (remove the cause) + M3/M4 (converge the rest). The retained short-poll receive path stays behind the `false` branch ≥1 release as the one-line rollback.

This is the **master index** for the whole migration. Full design detail for **every** milestone now lives in THIS document: M1/M2/M4/M5/M9/M10 inline in the index below; **M3, M6, and M8 in the appendices at the end** (folded in from their former standalone `docs/M3_STREAMSINK_ENGINE.md` / `M6_SEND_PATH_CONVERGENCE.md` / `M8_SCHEDULED_RESILIENCE.md`, which have been retired). Only **M7** and **M11** retain their own dedicated docs.

| Milestone | Dedicated doc |
|-----------|---------------|
| M3 — StreamSink engine | [Appendix M3](#appendix-m3--streamsink-engine) (in this doc) |
| M6 — Send-path / live-stream consumer | [Appendix M6](#appendix-m6--send-path-convergence) (in this doc) |
| M7 (+M7-E) — Self-owned background | `docs/M7_BACKGROUND_SHARING.md` |
| M8 — Scheduled resilience | [Appendix M8](#appendix-m8--scheduled-resilience) (in this doc) |
| M11 (+REV-1) — Rollout | `docs/M11_ROLLOUT.md` |
| E2E CI playbook | `docs/E2E_TROUBLESHOOTING.md` |

---

## North Star

**Verbatim:** "Haven ensures that the circle members are always in sync, and all users are getting the events for all of their circles at all times (foreground AND background)."

**Honest 3-tier SLA decomposition (judged per platform):**
1. **Foreground = GUARANTEED** real-time sub-second via live StreamSink (M3/M6).
2. **Background wakes = BEST-EFFORT** — a tiered ladder of OS wakes (FGS / SLC / BGTask / WorkManager).
3. **Next foreground = GUARANTEED-eventually** catch-up from a persisted, success-gated SQLCipher cursor (M1/M2/M7). Nothing is permanently lost while the device eventually opens the app: the 3-state decrypt outcome never advances the cursor past an unprocessed commit, and the broadcast bus's `Lagged` drops are replayed from the cursor.

**Receive-only / stationary caveat (headline limitation, not buried):** the literal "at all times, background" is met ONLY for (a) foreground users and (b) background-*share*-enabled users (Android FGS warm path). For **receive-only / stationary** users, M1–M8 deliver "eventually-consistent on next foreground," NOT "at all times." True near-real-time delivery to a stationary, suspended device requires the MIP-05 push gateway (M9), which is **user-gated**.

**Current scope (2026-06-28 owner decision):** **M9 is DEFERRED.** The build-out is M1–M8 + M10 + M11 with **no push dependency**. After those complete we **measure real background-delivery performance without push**, then decide whether M9 is worth its cost. Until that go/no-go, the accepted north-star posture is: foreground real-time + lossless eventual-consistency-on-next-foreground for everyone (best-effort wakes via FGS/SLC/BGTask), with the stationary/receive-only near-real-time guarantee explicitly deferred.

---

## Target Architecture (one coherent picture)

```
                         ┌────────────── haven-core (pure Rust) ──────────────┐
 Flutter (foreground)    │  static SESSION: RwLock<Option<Arc<LiveSyncCore>>> │  ← resettable (logout/relogin)
   LiveSyncController ───┼─► LiveSyncCore {                                    │
     listens Stream      │     group_plane (445 #h multiplex, verify_subs,     │
     routes variants     │                 own dedicated Client)               │
     start/stop/resume   │     inbox_plane (1059 #p, 7d lookback)              │
                         │     [discovery_plane: NOT IMPLEMENTED this set]     │
   ▲ broadcast::Receiver │     router (relay_url,sub_id)->ctx (pre-registered) │
   │  (StreamSink loop)  │     cursor store (SQLCipher circles.db)             │
   │                     │     scheduler: HealthCheck(15m)+RelayList(30m)      │
   │                     │     broadcast::Sender<FfiRelayEvent>                │
   │                     │     processor: decrypt → advance-cursor-on-success  │
   └─────────────────────┼──────────────────────────────────────────────────  │
   Publishing stays      │  static CIRCLE_MANAGER: RwLock<Option<Arc<…>>>      │  ← resettable, ONE MLS writer/process
   request/response  ◄───┼─    publish_with_retry; converging commit primitive │
   (RelayManager)        │     run_catchup_all_circles(receive_only, deadline) │  ← shared by ALL wake paths
                         └─────────────────────────────────────────────────────┘
 Background (separate):  iOS NSE / SLC / BGTask ; Android FGS+FCM/UnifiedPush+WorkManager
                         all call run_catchup_all_circles(receive_only=true, deadline) over App-Group circles.db
```

### Single-ownership decisions (resolve cross-slice contradictions)

1. **Globals use `RwLock<Option<Arc<…>>>`, NOT `OnceLock`.** Both `SESSION` and `CIRCLE_MANAGER` match the existing `TILE_CACHE` precedent (`api.rs:846`). `OnceLock` is write-once and cannot be reset on logout/identity-switch (a verified blocker). The `Option` wrapper lets `stop_session`/wipe-on-logout tear down inner state and re-login rebuild it. Async fallible init runs under the write-lock (or `tokio::sync::OnceCell` for the inner build) — never `std::sync::OnceLock::get_or_init` (sync + infallible, unfit for async relay connect).
2. **One new opaque FFI type `LiveSyncFfi`** holding `Arc<CoreCircleManager>` + relay `Client`. Exactly ONE StreamSink method: `live_events(&self, sink: StreamSink<FfiRelayEvent>)`. All lifecycle controls are plain `async fn -> Result<(),String>`. Session/notification tasks spawn in `start_session` into the global, NEVER inside `live_events` (T1).
3. **`CircleManager` becomes a process global** so the session processor, the converging-commit primitive, and `run_catchup_all_circles` share ONE MLS writer. `CircleManagerFfi::new_instance`/`init_circle_manager` borrow the global `Arc`; keyring-init sequence preserved. Rust unit-test isolation: `#[cfg(test)]` constructor builds a local `LiveSyncCore`/`CircleManager` without touching the static, or tests serialize behind a test mutex.
4. **`FfiRelayEvent` = ONE tagged enum** (Dart sealed class): `Location`, `GroupUpdate`, `Welcome`, `Unprocessable`, `Status`. Rust decrypts ONCE, emits decrypted fields (no Dart re-decrypt). Every leaf gets a redacting `Debug` (group-id/coordinates/secret bytes), mirroring `DecryptResultFfi` (`api.rs:1682-1730`). The `Status`/error variant carries ONLY a **closed enum of generic reasons — never a raw String** (Security Rule 8). FRB enum-with-data codegen verified in the regen smoke step (fallback = struct-of-options discriminant).
5. **`run_catchup_all_circles(receive_only, max_duration_secs)` is the single bounded primitive** shared by resume, iOS SLC/BGTask/NSE, Android FCM/UnifiedPush/WorkManager. **`receive_only=true` (mandatory for ALL background/second-process callers) processes ONLY `ApplicationMessage` results and SILENTLY DROPS Proposal/Commit/Unprocessable WITHOUT staging** — closing the NSE-corrupts-MLS-state hole (auto-committing a Proposal stages a pending commit → `OwnCommitPending` in the main app). Background DB opens additionally use `SQLITE_OPEN_READONLY` where the platform allows. ALL epoch-advancing work (Commits, SelfRemove, convergence) happens ONLY in the foreground process under `receive_only=false`.
6. **Decrypt contract = explicit outcome at the FFI.** Replace `Ok(None)` at `api.rs:3478/3482` by surfacing the EXISTING core `LocationMessageResult` variants through `DecryptOutcomeFfi { Location | GroupUpdate | Unprocessable | PreviouslyFailed }`. Cursor advances ONLY on `Location`/`GroupUpdate`; `Unprocessable`/`PreviouslyFailed` leave the cursor put so the event replays.
7. **Discovery plane (peer 10002/10050/10051 watching) is NOT implemented** in this set. In-band `resync_circle_relays_from_mdk` after commits keeps relay sets fresh. WN's `discovery_sync_worker.rs` is **background reading only** — do NOT port.

### Cursor store — ONE design

Table in **`circles.db` (SQLCipher), created inside the existing `initialize_schema()`** (runs on every open; additive `CREATE TABLE IF NOT EXISTS`, no versioned migration, no rusqlite checksum issue):

```
sync_cursors(stream TEXT PRIMARY KEY, last_synced_ms INTEGER NOT NULL DEFAULT 0)
```

Streams: `'group_445'`, `'inbox_1059'`. Single-identity Haven (an `account_pubkey` column is additive if multi-identity ever lands). **Advance is an atomic conditional UPDATE at the SQL layer** — `UPDATE sync_cursors SET last_synced_ms=:ms WHERE :ms > last_synced_ms` — NOT read-modify-write in Rust, so concurrent foreground/background writers across the App-Group DB cannot lose an update (WAL serializes file-level writes). **`since` derivation:** group `since = cursor_secs - 60` (resubscribe) / `- 10` (initial); **inbox `since = cursor_secs - 604800` (7-day gift-wrap lookback) applied to EVERY kind-1059 REQ**, not just first subscription (cursor stores the raw rumor timestamp; the 7d subtract happens live in `since_for_stream` when `stream==inbox_1059`). All `since` capped to `now`. **Seed-if-unset = `now - 24h`** for field circles (no full-history avalanche). **Bootstrap order is mandatory: seed cursor (M1) BEFORE starting any subscription (M3)**, so a `since=None` "send all history" window can never open.

### T1–T10 resolutions (condensed)

- **T1:** Session/tasks spawn in `start_session` into the `RwLock<Option<Arc>>` global; `live_events` only borrows a `broadcast::Receiver` and loops `recv→sink.add` (`Lagged`→continue, send-err→break+`Ok(())`). "Sink closed" ≠ "session stopped"; only `stop_session` tears down planes (client `Shutdown` exits the self-restarting loop, then drops the global inner). AtomicBool double-spawn guard. FRB's default executor is a single persistent Tokio runtime (`SimpleAsyncRuntime`), so `tokio::spawn` from an async FFI method survives — no second runtime anywhere (the iOS C-ABI in M9 runs in a separate *process*, the only place a dedicated runtime is built).
- **T2:** Foreground = live stream; background = `run_catchup_all_circles(receive_only=true)`; resume = same primitive re-anchored at cursor. Dedup via `event_id` + Dart `_seenEventIds` + MDK processed-message gate.
- **T3:** ONE standing multiplexed `#h` REQ per relay-set REPLACES three jittered poll loops (30/60/3600s) → net fewer REQ ops + no connect/disconnect churn. Scope to own relay set + `nostr_group_id` only (never real MLS group id); sub-ids HMAC-hashed with a **per-session ephemeral salt (not persisted)**. Honest delta in SECURITY.md: a persistent socket creates a continuous online-presence signal + a long-lived (socket ↔ set-of-nostr_group_ids) correlation for the session — a metadata change vs short polls that cannot be eliminated while holding a live connection; mitigations = own-relays-only + Tor/VPN (Mullvad) onboarding guidance.
- **T4:** SQLCipher-persisted, atomic-conditional-max, advance-only-on-success; inbox advances on the decrypted RUMOR timestamp with the 7d subtract on every REQ; capped to now.
- **T5:** See M5 — periodic AND post-join self-update both disabled; deviation scoped as MIP-02 (post-join MUST) + MIP-03 (rotation), documented with the joiner-leaf-key exposure window.
- **T6:** `publish_and_merge_commit_converging` with DETERMINISTIC MIP-03 winner `(min created_at, then lexicographically min id)`; tolerant of all three MDK outcomes (`Err` / `Unprocessable` / silent-advance). NOT a WN port (see M4).
- **T7:** Additive schema; seed `now-24h`; phased + flag-gated; FRB regen clean; e2e lanes extended; coverage held.
- **T8:** See the background-delivery matrix.
- **T9:** MIP-05 token gossip + content-free FCM/UnifiedPush wake + iOS NSE + optional self-hostable gateway; privacy cost analyzed (M9).
- **T10:** `#h`-multiplexed REQ per relay-set bucket; live `subscribe_circle`/`unsubscribe_circle` on join/leave/relay-change.

---

## Milestone index (M1–M11, dependency-ordered)

### M1 — Cursor store + surface existing decrypt variants at FFI + deviation docs + Android INTERNET — DONE
**Why first:** smallest, self-contained; immediately stops the silent `Unprocessable` skip even on the current in-memory cursor.
- **`haven-core/src/circle/storage.rs`:** add `sync_cursors` table inside `initialize_schema`; `update_sync_cursor_max(conn,stream,ms)` as the atomic conditional `UPDATE … WHERE :ms > last_synced_ms`; `read_sync_cursor(conn,stream)`.
- **new `haven-core/src/relay/cursor.rs`:** consts `STREAM_GROUP_445`, `STREAM_INBOX_1059`, `GROUP_INITIAL_BUFFER_SECS=10`, `GROUP_RESUBSCRIBE_BUFFER_SECS=60`, `INBOX_GIFTWRAP_LOOKBACK_SECS=604800`; `since_for_stream(stream, cursor)` (subtract 7d for inbox, 10/60s for group, cap to now), `cap_timestamp_to_now`, `clear_cursor`.
- **`api.rs`:** replace `Ok(None)` at 3478/3482 by surfacing the EXISTING `LocationMessageResult` variants through `DecryptOutcomeFfi { Location|GroupUpdate|Unprocessable|PreviouslyFailed }` (redacting `Debug`); existing `decrypt_location` keeps a thin compat shim during rollout. Cursor accessors `cursor_get`/`cursor_seed_if_unset`/`cursor_reset` (NO `cursor_set`); `cursor_reset` wired to wipe-on-logout in M10 so it is not dead FFI. **The 4-way decrypt distinction ALREADY EXISTS in core (`types.rs LocationMessageResult`); M1 only SURFACES it — no core decrypt re-architecture.**
- **Android manifest:** add `<uses-permission android:name="android.permission.INTERNET" />` to `src/main/AndroidManifest.xml` **now** (pulled forward from M7 — release builds must not depend on transitive merge); CI guard lands with the FGS work in M7.
- **Docs:** SECURITY.md + MARMOT_PROTOCOL_KNOWLEDGE.md — self-update deviation (D2) + persistent-REQ metadata analysis (T3).
- **Acceptance:** monotonic/persist/since-buffer/giftwrap-7d-subtract/cap-now unit tests; `Unprocessable`→no-advance; **a regression test reproducing the EXACT original bug** (two members each holding the sibling commit the other dropped → divergent N+1) proving M4 heals a *fresh* race and that a *pre-existing* field fork is correctly NOT auto-healed (D3); FRB regen clean; coverage held; no Dart behavior change yet.

### M2 — Wire cursor into existing polling path (de-risk before stream) — DONE
- **`location_sharing_service.dart`:** after successful `Location`/`GroupUpdate` decrypt call `advanceGroupCursor(created_at)`; after invitation success call `advanceInboxCursor(rumor_created_at)`. Keep `_lastFetchTime`/`_seenEventIds` during rollout. `Unprocessable`→do NOT advance, leave id un-seen.
- **Acceptance:** no-advance-on-Unprocessable; cursor-survives-restart e2e; existing 30/60s polling still functions; flag `liveSyncEnabled=false`.

### M3 — Rust persistent session engine (planes + router + notification task + StreamSink bridge) — DONE
New `haven-core/src/relay/live_sync/` — `LiveSyncCore` in the resettable `SESSION` global; group 445-`#h` multiplex (dedicated Client with `verify_subscriptions`, `subscribe_with_id_to`), inbox 1059-`#p` 7d lookback, relay-set bucketing, pre-registered router, self-restarting 1s→30s notification task, `broadcast(256)`/`mpsc(1000)` bus. Promotes `CircleManager` to a process global; adds `LiveSyncFfi` opaque type with the single `live_events` StreamSink method + `start/stop/resume/subscribe_circle/unsubscribe_circle/run_catchup/is_running`. Logging is `log::` only (never `tracing`). **→ full design: [Appendix M3](#appendix-m3--streamsink-engine), at the end of this doc.**

### M4 — Adopt-winner convergence primitive (Haven-original; HARD-depends on M3 for full guarantee) — DONE
**Explicitly NOT a WN port** — WN has no adopt-winner/created_at-tiebreak/clear-and-adopt logic (it clears pending only on publish failure and delegates concurrent-commit handling to MDK). The sole precedent is Haven's own test (`manager.rs:4331-4538`), which does manual (not deterministic-winner) convergence. M4 builds the deterministic primitive from scratch.
- **Prerequisite test (blocks M4):** pin the ACTUAL MDK `93ae324` `process_message` behavior when a local pending commit exists — assert which of {`Err(OwnCommitPending)`, `Unprocessable`, silent-advance} occurs (`process.rs:79` shows `OwnCommitPending` reachable). The primitive is built tolerant of all three; the "mandatory clear-before-process" framing is DROPPED unless this test proves it required.
- **`haven-core/src/circle/manager.rs`:** `publish_and_merge_commit_converging(our_commit, group_id, staged_epoch, publish, competing_commits) -> CommitConvergence{Merged|AdoptedWinner{intent_still_pending}|Rolledback}`. Deterministic winner `(min created_at, then lexicographically min id)` — matches the verbatim MIP-03 rule. Loser: attempt-apply → unconditional `clear_pending_commit` (assert it zeroizes staged key material via MDK; test no stale staged secret survives `AdoptedWinner`) → re-attempt-apply → re-stage own intent only if still pending. Bounded re-stage ≤2 (P-6 asserts termination). Implements MIP-03 "retain previous group states temporarily" via M3's settle-window buffer.
- **FFI:** `publish_and_merge_commit_converging(our_commit_json, mls_group_id, staged_epoch, competing_commit_jsons, relays) -> CommitConvergenceFfi`.
- **Wiring — ALL live finalize sites:** `nostr_circle_service.dart:510`, `nostr_circle_service.dart:933`, `location_sharing_service.dart:834` → converging call (competing commits fed from M3's `COMMIT_SETTLE_WINDOW_SECS` buffer). **The settle window engages ONLY for competing same-epoch membership commits — NEVER for ordinary 445 location events** (30s location sends are not delayed/dropped). Common case (one SelfRemove, no competitor) still just finalizes. Membership add/remove route through converging when `admin_pubkeys.len() > 1`; single-admin short-circuits to `Merged`. Single-admin-two-devices and non-admin-SelfRemove-racing-admin-commit are residual races covered by the slower `Unprocessable`→clear→adopt path (the deterministic winner makes them convergent even outside the settle window).
- **CI grep-guard:** no un-converged `finalizePendingCommit` remains on a multi-admin commit path.
- **Ordering:** M4 can be DEVELOPED in parallel with M3 but its full fork-safety guarantee REQUIRES M3's settle-window buffer; if M4 lands first it degrades to eager-merge (still buggy) until M3 — NOT shipped flag-on before M3.
- **Acceptance:** P-1..P-6 (concurrent self-update converge; deterministic winner by created_at; id tiebreak both sides agree; admin-remove deterministic; receiver SelfRemove converge; intent-not-subsumed bounded re-stage); two-peers-pick-same-winner; no-stale-staged-secret; the M1 exact-original-bug regression. Security-reviewer gate.

### M5 — Disable periodic AND post-join self-update (Dart-only; self-commit REMOVED) — DONE
- **Files:** delete `_selfUpdateTimer` + field/cancels + resume invalidate; gate `selfUpdateProvider` behind `const enablePeriodicSelfUpdate=false`. **Keep exactly ONE non-timer call site** (on-demand path routed through M4's converging primitive) so `unused_element` does not fire and on-demand self-update remains available.
- **D2 / SECURITY.md / MARMOT_PROTOCOL_KNOWLEDGE.md:** document that this disables BOTH (a) periodic MIP-03 rotation AND (b) the **MIP-02 post-join self-update** (`groups_needing_self_update` returns post-join-incomplete groups — verified `manager.rs:2469` + provider doc). State the concrete exposure: a joined member keeps the leaf/init key material from the adder's commit/Welcome until the next membership change; a device compromise leaks an epoch key NOT refreshed by any self-action. Do NOT claim WN "concludes leaderless self-update is the dominant fork generator" — that is Haven's own (sound) reasoning; WN's source only comments post-welcome self-update is "temporarily disabled."
- **MDK post-join flag handling:** MDK still tracks post-join-incomplete state internally; document whether the on-demand path ignores or honors-on-demand it, so a deferred rotation cannot silently race a membership commit (route any such rotation through M4).
- **Acceptance:** epoch unchanged over simulated multi-hour idle; advances on membership add; add/remove/leave green; timer-not-created.

### M6 — Flutter live-stream consumer + lifecycle reconciliation + poller removal — DONE
New `NostrSubscriptionService` (interface + impl) consumes the `FfiRelayEvent` stream via a `StreamSubscription` held in state (no `flutter_hooks`) and routes variants to provider invalidations; new `sync_status_provider`; `handleStreamedLocation`/`handleStreamedEvolution` + `isEventSeen` on `LocationSharingService`; removes the three `map_shell` timers (`_receiveTimer`/`_evolutionTimer`/`_selfUpdateTimer`) and deletes `evolution_poller_provider.dart` (its **avatar epoch re-share side-effect is preserved** in `GroupUpdate` routing). `liveSyncEnabled` flips ON here; polling stays behind the `false` branch ≥1 release, and the dedup `_seenEventIds` set is the flag-flip reconciliation mechanism. **→ full design: [Appendix M6](#appendix-m6--send-path-convergence), at the end of this doc.**

### M7 (+M7-E) — Self-owned background: catch-up primitive + iOS SLC/BGTask + Android FGS re-arm + WorkManager + App-Group DB — DONE (GO-LIVE flags flipped)
`run_catchup_all_circles` (cursor-anchored, deadline-bounded, `receive_only=true` drops all non-ApplicationMessage results) is the single primitive for every wake. iOS: `HavenSLCHandler` (Significant-Location-Change relaunch), `HavenBGTaskHandler` (`BGAppRefreshTask` id `app.haven.catchup`), rewired ~90s receive timer, `applicationDidEnterBackground` re-arm; no new Info.plist background mode (SLC reuses `location`). Android: `RebootReceiver` re-enabled (gated on bg-sharing), `flutter_workmanager` 15-min floor, INTERNET already in prod manifest (M1) + CI release-manifest guard lands here. MLS single-writer enforced: only the foreground process advances epochs; the WorkManager worker checks `isBackgroundIdle()`. iOS App-Group `circles.db` migration (copy-then-delete-with-sentinel) lands here, once. M7-E flipped all flags LIVE (`backgroundCatchupEnabled=true`, `RebootReceiver enabled`, `autoRunOnBoot:true`) with the real Android background-isolate bootstrap. Remaining OWNER-only: one physical-iPhone BGTask-fire test (simulator cannot fire BGTaskScheduler). **→ full design: `docs/M7_BACKGROUND_SHARING.md`.**

### M8 — Scheduled resilience (health check + relay-list maintenance) — DONE
Generic async cron (`Task` trait, native async-fn-in-trait preferred over `async-trait`; `tokio::interval` `MissedTickBehavior::Skip` + fire-on-start + `watch` shutdown) over `Arc<LiveSyncCore>`: `SubscriptionHealthCheck` (15m: MDK-vs-plane group-count parity + reconnect/resubscribe at cursor-buffer; falls back to connectivity-only if enumeration is too costly) and `RelayListMaintenance` (30m: republish own 10050/10051), plus M8-2 KeyPackageMaintenance and M8-4 per-relay probe. Redacted `log::` logging; clippy pedantic+nursery budgeted. **→ full design: [Appendix M8](#appendix-m8--scheduled-resilience), at the end of this doc.**

### M9 — MIP-05 push (server-gated; near-real-time stationary-iOS) — DEFERRED (decide later, after measurement)
**Scope decision (2026-06-28, owner):** M9 is deferred and NOT part of the current build-out. M1–M8 + M10 + M11 ship without any push dependency. Once they complete, measure real-world background-delivery behaviour without push (next-foreground latency, SLC/BGTask/FGS wake coverage, battery, the receive-only/stationary gap) and only THEN decide whether the push-gateway dependency (APNs/NSE/entitlements, FCM + UnifiedPush, self-hostable gateway, residual metadata oracle) is worth adding. Do not implement any part of M9 (including the M9.0 `mip05` feature flip) before that decision. Full design retained, ready to execute:
- **Prerequisite (M9.0):** enable the existing MDK pin's `mip05` feature — `mdk-core = { …, rev = "93ae324…", features = ["mip05"] }` (symbols present at this exact rev; a feature-flag flip, NOT a fork migration). Re-validate the rusqlite/keyring version lock; re-run cross-check on all targets. Security-reviewer gate.
- **Rust:** `haven-core/src/circle/push_tokens.rs` (`circle_push_tokens` table; `publish_notification_requests_after_location` using `build_notification_batches`; **fresh ephemeral key per wrap; ±48h jitter; quantified decoy ratio + jitter distribution as TESTED invariants**). Token-request publication is **coarse-cadence (NOT per-location)** to flatten the activity beacon. The push `server_pubkey` and its relays MUST be DISTINCT from any circle relay (co-location = correlation) — unit-asserted no `relay_hint`/`server_pubkey` ever flows to a circle relay. C-ABI `#[no_mangle] extern "C" fn haven_collect_after_push(...)` (`#[cfg(target_os="ios")]`): **primitives/lengths only, NO raw-pointer deref** (repo denies `unsafe_code`); clamps to 25s; opens App-Group `circles.db`; runs `run_catchup_all_circles(receive_only=true)` in its OWN dedicated runtime (separate process).
- **iOS NSE:** decision LOCKED to **WAKE-and-persist-only** — the NSE holds no MLS group secrets and calls no MDK write path; shows a privacy-safe generic body and triggers catch-up (decrypt-in-extension rejected: 24MB cap, opaque OS logging, staged-commit hazard). Entitlements (`aps-environment`, App Group `group.com.oblivioustech.haven`, keychain-access-group); add `remote-notification` mode; **ALERT push (not silent content-available)** with a generic body (no location/names/group-id).
- **Android:** `HavenMessagingService.kt` (content-free data-only wake → expedited WorkManager; **drop any message carrying a notification block — TESTED invariant**), `HavenCatchupWorker.kt`; `firebase_messaging` **in a separate build flavor so GrapheneOS/de-Googled users get an FCM-free APK**; UnifiedPush path (Haven-original) for no-GMS — same drop-notification-block invariant; **explicit no-push startup fallback** (neither FCM nor a UnifiedPush distributor present → app starts cleanly, foreground-only + catch-up).
- **Gateway:** self-hostable STATELESS relay-watcher reference impl + Docker; server pubkey compile-time const, user-overridable. **The gateway watches its OWN inbox for kind-446 notification-requests addressed to it — it NEVER subscribes to a user's `#h`/`#p`** (a naive `#h`/`#p`-watching gateway is explicitly REJECTED).
- **Privacy disclosure (SECURITY.md):** the gateway still observes per-batch recipient COUNT, server-relay timing, and a per-user activity beacon (mitigated by coarse cadence + decoys); FCM/APNs see token↔device linkage + a contentless wake. Document the residual oracle honestly.
- **Per-circle teardown:** leaving a circle publishes a kind-449 token removal + purges `circle_push_tokens` for that group (mirror WN's `GroupPushToken::delete`).
- **Acceptance:** ephemeral-key-per-wrap + decoy-ratio + no-relay_hint-to-circle-relay unit asserts BEFORE any push ships; NSE wake-only enforced in review; push body never carries location/names/group-id; drop-notification-block invariant (FCM + UnifiedPush). Security-reviewer gate.

### M10 — Privacy/security hardening sweep (cross-cutting DoD) — DONE (flag-OFF build; 3-round adversarial QC, findings folded)
Cursor + dedup set bounded/aged-out with an explicit cap + test (hard requirement); dedup set lives ONLY in SQLCipher / in-memory, never plaintext shared-prefs/Hive. **Wipe-on-logout AND wipe-on-LEAVE:** logout purges `sync_cursors`, tears down sink + notification tasks, sends per-relay `unsubscribe` (CLOSE) for every group + inbox REQ, then client `Shutdown`, **sets the `RwLock<Option<Arc>>` globals' inner to `None`** (the reason for not using `OnceLock`), de-registers push token (kind-449 best-effort, only when push active), zeroizes in-flight buffers; leaving a single circle drops its REQ + purges its cursor row + cached push tokens + buffered events + kind-449. All sink errors pre-redacted to the closed `Status` enum; `evolution_mls_group_id` stays internal. Debug-redaction test over EVERY `FfiRelayEvent` variant. Non-secret comparisons (event-id/sub-id/winner tiebreak) noted as such; any secret-adjacent token comparison uses `subtle` ct-eq.

**Shipped (2026-07-04):**
- **A — dedup bounded/aged (`storage.rs`):** `prune_processed_gift_wraps(now_secs)` (retention DELETE `PROCESSED_GIFT_WRAP_RETENTION_SECS = INBOX_GIFTWRAP_LOOKBACK_SECS + 48h` ≈ 9d, compile-time-asserted `>` lookback) + row-cap `MAX_PROCESSED_GIFT_WRAPS = 10_000`; `wipe_all_processed_gift_wraps()`. Wired to prune on foreground (`map_shell._runPrune`) + background wake. SQLCipher-only.
- **C — wipe-on-LEAVE (`storage.rs delete_circle`):** the delete tx also removes the group's `sync_cursors` row (`"{STREAM_GROUP_445}:{hex(ngid)}"`) + all `processed_gift_wraps` rows bound to the leaving group (empty-blob failure sentinels intentionally spared).
- **Wipe-on-logout (`identity_provider.deleteIdentity` + `nostr_circle_service`):** cancels the maintenance scheduler → `closeAndInvalidate()` (drops the MDK handle + sets a one-way `_wiped` re-open latch) → `wipeAllMlsState()` (deletes circles.db + haven_mdk.db files **and** their keyring keys) → invalidates the service; plus the staged-commit wipe + `resetAllSyncCursors()`. The `_wiped` latch closes the logout re-open race (a mid-`initialize()` tick is refused; `closeAndInvalidate` DRAINS any in-flight open before returning). `_wiped` is per-instance; `circleServiceProvider` is a `Provider`, so a fresh login rebuilds an un-wiped instance (no login-after-logout bricking).
- **D — at-rest CI test (`tests/sync_state_at_rest_test.rs`):** high-entropy sentinels round-trip through the cipher; a raw byte-scan of the DB file + every sidecar (`-wal`/`-shm`/`-journal`) confirms no plaintext leak, pre- and post-drop.
- **E — redaction tests (`relay/live_sync/event.rs`):** the `FfiRelayEvent`/decrypt-outcome Debug-redaction test extended over `AutoCommit`/`PreviouslyFailed`/`OtherError`.
- **Engine/push-coupled DoD items are INERT-by-design in this flag-OFF build:** per-relay `unsubscribe`/CLOSE + client `Shutdown` + sink/notification-task teardown (no standing subscription yet — handled by the engine's own `stop()` when M11 flips it ON); kind-449 push-token de-register (M9 DEFERRED). Documented as deliberately deferred, not skipped.

### M11 (+REV-1) — Rollout, flags, e2e, CI — DONE
`liveSyncEnabled` (polling kept behind the false branch ≥1 release as the one-line rollback) is flipped here — it now defaults **true** (Phase B). e2e_combined extensions: live-stream sub-second delivery; concurrent-commit convergence (real relay, empirically tunes `COMMIT_SETTLE_WINDOW_SECS` against strfry propagation and asserts it stays under the membership-commit latency budget); Unprocessable-adopted-not-skipped; cursor-survives-restart; many-circle multiplexed delivery; NIP-59 backdated gift-wrap via 7d lookback; Android-INTERNET-present. e2e-ios lane updated; coverage gates 80% Rust / 10% Flutter held. **Current state:** Phase-A engine wiring + REV-1 committed (`main@b2c82ab`); the flag-on e2e lanes are green on both platforms and promoted into per-commit CI (`b8ee978`); the **Phase-B flip has landed** — `liveSyncEnabled` defaults `true`, the SECURITY.md persistent-connection disclosure is in, and guard-14b is inverted to pin the live state. Residual non-code gates before a release tag: one clean per-commit CI run + an owner/physical-device foreground↔background socket sanity check. **→ full design + rollout state: `docs/M11_ROLLOUT.md`; CI playbook: `docs/E2E_TROUBLESHOOTING.md`.**

---

## Per-Platform Background Delivery Matrix

HONEST per-platform guarantee. Three SLA tiers: (1) Foreground = GUARANTEED real-time sub-second via live StreamSink (M3/M6). (2) Background wakes = BEST-EFFORT. (3) Next foreground = GUARANTEED-eventually catch-up from the persisted SQLCipher cursor (M1/M2/M7) — no event permanently lost while the device eventually opens the app, because the 3-state decrypt outcome never advances the cursor past an unprocessed commit and the broadcast bus's Lagged-drops are replayed from the cursor.

**Critical honesty caveat (folded in from verification):** the literal "all users... at all times, background" is met ONLY for (a) foreground users and (b) background-SHARE-enabled users (Android FGS warm path). RECEIVE-ONLY and stationary users get eventual-consistency-on-next-foreground from M1–M8, and near-real-time ONLY with M9 (user-gated). This is a headline limitation, not an implementation detail.

### iOS
- **Foreground (app open):** GUARANTEED real-time sub-second (live stream).
- **Background, moving, CLLocationManager session active + background-sharing ON:** BEST-EFFORT, ~90s cadence cursor-anchored receive timer (M7), only while the OS keeps the location session warm.
- **Suspended/killed, device moves ~500m, Always-location + Background-App-Refresh ON:** BEST-EFFORT via Significant Location Change relaunch → `receive_only` catch-up (M7). Fires on THIS device's movement only; nothing for a stationary device.
- **Suspended/killed, opportunistic BGAppRefreshTask:** BEST-EFFORT, OS-scheduled ~hours, blocked by Low Power Mode / disabled Background App Refresh (M7). Safety net, not a guarantee. Fires regardless of the background-share toggle (receive ≠ share).
- **Suspended/killed, stationary, near-real-time:** ONLY with MIP-05 ALERT push + wake-only NSE (M9, user-gated). Even then Apple gives NO background-delivery SLA; alert push + NSE is far more reliable than silent content-available push (rate-limited ~2-3/hr). NSE is WAKE-AND-PERSIST-ONLY: holds no MLS secrets, performs no MDK writes (receive_only catch-up on next foreground does the MLS work), reuses App-Group circles.db.
- **Next app open:** GUARANTEED catch-up from the persisted cursor (M1/M7).
- **Honest user-facing line:** "Open: instant. Closed: delivered next time you open Haven (nothing lost), or sooner if you move or enable the optional push service — Apple does not guarantee background delivery for stationary devices."

### Android
- **Foreground OR location-FGS running (background-sharing ON):** NEAR-GUARANTEED real-time via live StreamSink inside the FGS — BUT bounded by the **Android 15 (targetSdk 35) 6-hour FGS timeout**. CORRECTION: `foregroundServiceType=location` is NOT on the Android-15 timeout-exempt list (exempt: camera, connectedDevice, health, mediaPlayback, mediaProjection, microphone, phoneCall, remoteMessaging, systemExempted). So after ~6h continuous, Android may kill the FGS unless charging or the user interacts. RebootReceiver (M7) re-arms on boot; WorkManager 15-min floor + FCM/UnifiedPush wake (M9) provide best-effort catch-up until the FGS restarts or the app reopens. OEM battery killers can also kill it sooner.
- **FGS not running, GMS present:** BEST-EFFORT via content-free high-priority FCM data wake → expedited WorkManager → `receive_only` catch-up (M9). FCM may rate-limit/defer.
- **FGS not running, no-GMS/GrapheneOS:** BEST-EFFORT via UnifiedPush wake (M9, distributor-dependent); degrades gracefully to foreground-only + catch-up if no distributor installed.
- **Any state:** WorkManager 15-min periodic floor (M7), deferred in Doze. Lossless safety net, not real-time.
- **Next app open:** GUARANTEED catch-up from the persisted cursor.
- **Receive-only (background SHARE off, default):** no FGS → no warm connection → eventual-consistency-on-next-foreground (or push if M9 active). The FGS real-time line does NOT apply to receive-only users.
- **Honest user-facing line:** "With background sharing on, Haven keeps a live relay connection and delivers in real time (Android may recycle the service after ~6 hours; it auto-restarts and catches up from a saved sync point). GrapheneOS/de-Googled devices use UnifiedPush instead of Google push."

### Push payloads (both platforms)
CONTENT-FREE wakes: the gateway sees only opaque per-group-ephemeral-encrypted device tokens + decoys + timing — never content/sender/recipient/group-id/membership. **Residual oracles honestly disclosed:** the gateway observes per-batch recipient COUNT, server-relay timing, and a per-user activity beacon (mitigated by coarse-cadence token requests + quantified decoy ratio + ±48h jitter); FCM/APNs additionally see token↔device linkage + a contentless wake. The push `server_pubkey` and its relays are DISTINCT from any circle relay (no co-location correlation). A naive relay-watching gateway that subscribes to a user's `#h`/`#p` is explicitly REJECTED; the gateway watches only its own inbox for kind-446 requests addressed to it.

---

## Self-update deviation (D2) — documented, accepted, correctly scoped

Periodic **AND post-join (MIP-02)** self-update DISABLED (M5). Epochs advance only on real membership churn. **This abandons a MIP-02 MUST (post-join self-update within 24h of joining), not merely a MIP-03 rotation** — the original framing under-disclosed this and is corrected. MIP-03's concurrent-commit rule is honored by M4's deterministic winner; MIP-03 self-update is "MAY" (any member) and Commits MUST NOT combine self-update with other proposals (verified verbatim).

**Tradeoff:** a joined/static member keeps the leaf/init key material from the adder's commit/Welcome until the next membership change; a device compromise leaks an epoch key NOT refreshed by any self-action (PCS/forward-secrecy refresh weakened; exposure window = "until next membership change").

**Rationale (Haven's own, NOT attributed to WN):** Nostr relays provide no commit serialization, so leaderless periodic self-update is the dominant fork generator.

**Surviving mitigations:** membership commits re-key; MIP-00 key separation intact; 5-epoch exporter-secret prune unaffected (a stable single-epoch circle exerts no pruning pressure — SAFER for the lookback window); on-demand self-update remains available (routed through M4).

**Inverse risk documented:** a burst of rapid membership changes could advance >5 epochs faster than a long-suspended device catches up, pushing a needed `exporter_secret` past `DEFAULT_EPOCH_LOOKBACK` and rendering in-flight 445s permanently `Unprocessable` — the T8 catch-up cadence is designed to bound epoch lag below 5, and the loss case is documented. Recorded in SECURITY.md + MARMOT_PROTOCOL_KNOWLEDGE.md.

---

## Verified evidence anchors (source-confirmed; corrections folded in)

- `api.rs:3478` (`Unprocessable`→`Ok(None)`) and `api.rs:3482` (`PreviouslyFailed`→`Ok(None)`) — the silent-drop / cursor-skip bug. **CONFIRMED.**
- **The 4-way decrypt distinction ALREADY EXISTS in core:** `haven-core/src/nostr/mls/types.rs` `LocationMessageResult` has `Location|GroupUpdate|Unprocessable|PreviouslyFailed` with redacting `Debug`. The defect is PURELY at the FFI boundary (`api.rs:3478/3482` flatten two variants to `Ok(None)`). M1 surfaces existing variants; it does NOT re-architect core decrypt.
- `haven-core/src/relay/manager.rs:161` — one bare `Client::builder().build()`, no `verify_subscriptions`. **CONFIRMED.** `manager.rs:397-455` — dead-from-Flutter `subscribe()` using auto-id `subscribe_to` (`manager.rs:414`). **CONFIRMED.**
- `self_update_provider.dart` — hourly `groupsNeedingSelfUpdate(3600)`; its doc AND `manager.rs:2469-2475` BOTH say the query returns groups "where the post-join rotation is incomplete." **=> Disabling this timer ALSO disables the MIP-02 post-join self-update. CONFIRMED** (corrected throughout — see M5/D2).
- **`finalize_pending_commit` production sites (full inventory):** `nostr_circle_service.dart:510` (on-demand/self-update publish), `nostr_circle_service.dart:933` (`_publishEvolutionEvent` membership-commit), `location_sharing_service.dart:834` (receiver auto-commit), `location_sharing_service.dart:1375` (evolution poller — DELETED by M6). **CONFIRMED — the original 2-site citation was incomplete; M4 wires all three live paths.**
- FRB **2.11.1** pinned (`rust_builder/Cargo.toml`, `pubspec.yaml`); ships `StreamSink` + `add()`/`add_error()`. **No FRB bump.** (Haven's `frb_generated.rs` has no StreamSink yet; M3 adds the first StreamSink fn + regenerates.)
- nostr/nostr-sdk **0.44**; `subscribe_with_id_to`, `handle_notifications`, `verify_subscriptions` (build-time Client option) all present.
- **MDK rev `93ae324` (parres-hq/mdk) — the SAME fork Haven already pins — DOES contain `mip05`** at `crates/mdk-core/src/mip05/` with `encrypt_push_token`/`decrypt_push_token` (`crypto.rs:18`), `build_notification_batches` (`notifications.rs:129`), kinds 446/447/448/449 (`types.rs:188-219`). `mip05` is a **declared-but-not-enabled feature** (`haven-core Cargo.toml:42` has NO `features=["mip05"]`). **=> M9's prerequisite is to ADD `features=["mip05"]` to the existing pin, NOT migrate to a different fork.**
- `mdk-core` `process_message`: `Err(Error::OwnCommitPending)` at `messages/process.rs:79`; auto-committing an incoming Proposal STAGES a pending commit. **CONFIRMED — load-bearing for the NSE/background read-path-only constraint (M7/M9).**
- iOS `UIBackgroundModes = [location]` only; no `remote-notification`, no entitlements file. **CONFIRMED.**
- Android: FGS `foregroundServiceType="location"`; `targetSdk = 35`; **INTERNET present ONLY in debug/profile manifests, ABSENT from `src/main/AndroidManifest.xml`.** **CONFIRMED — release relies on transitive plugin manifest-merge; fragile, fixed early (M1) with the CI guard in M7.**
- **MIP-03 concurrent-commit rule (verbatim from marmot-protocol/marmot master `03.md`):** "Choose the Commit with the earliest `created_at` timestamp"; "If timestamps are identical, choose the Commit with the lexicographically smallest `id`"; "Reject all other competing Commits"; "Clients SHOULD retain previous group states temporarily to enable recovery from forked states." Self-update: "Any member (admin or non-admin) MAY create a self-update Commit" and "Self-update Commits MUST NOT include any other proposals." **CONFIRMED.**
- **WN notification task IS self-restarting** in the local `whitenoise-rs` checkout: `session.rs:907+` spawns a `loop { handle_notifications(...) }` with 1s→30s backoff, JoinHandle intentionally unstored, AtomicBool double-spawn guard, exits on `RelayPoolNotification::Shutdown`. **CONFIRMED — resolves the verifier conflict; the plan's self-restarting design is correct and retained.**
- WN buffer constants: `SUBSCRIPTION_BUFFER_SECS=10` (`subscriptions.rs:35`), `RESUBSCRIBE_BUFFER_SECS=60` (`mod.rs:1106`), `GIFTWRAP_LOOKBACK_BUFFER=7d` via `adjust_since_for_giftwrap` (`setup.rs:955-956`). **CONFIRMED — 10s initial since-buffer, 60s post-teardown resubscribe (correcting an earlier conflation to 60s).**

---

## OUT OF SCOPE (explicit)

- **M9 (MIP-05 push) — DEFERRED for this build-out (2026-06-28 owner decision).** Ship M1–M8, M10, M11 with no push dependency, then measure background-delivery performance without push and decide go/no-go. The receive-only/stationary near-real-time gap stays open (eventual-on-foreground, lossless) until that decision.
- Automatic re-Welcome / resync recovery for ALREADY-forked field circles (D3). M1+M4 PREVENT new forks and make remaining commit paths fork-safe, but do NOT auto-heal pre-existing field forks.
- Discovery plane (peer relay-list watching) — NOT implemented; WN's `discovery_sync_worker.rs` is background reading only.
- KeyPackage / consumed-KP maintenance tasks (separate workstream; M8 covers scheduled resilience).
- Multi-identity cursor partitioning (forward-compat note only — an `account_pubkey` column is additive).

---

## Changelog (condensed)

Seven independent expert verifiers (marmot/rust/flutter/nostr/security/platform-background/completeness) each returned `approve_with_changes` at high confidence; all must-fixes were folded in. Load-bearing accuracy disputes were re-verified against source rather than trusting any single verifier. Corrections applied during finalization:

- **MDK mip05:** corrected the security verifier's "wrong fork" claim — the existing pin (parres-hq/mdk @ `93ae324`) DOES contain `mip05`; M9.0 is a `features=["mip05"]` flip, not a fork migration.
- **M5 / D2:** corrected the self-update deviation scope — `groups_needing_self_update` returns post-join-incomplete groups, so disabling the timer ALSO disables the MIP-02 24h post-join MUST. D2 now discloses BOTH periodic (MIP-03) and post-join (MIP-02) disablement + the joiner-leaf-key exposure window.
- **M4 finalize-site inventory completed:** all live sites verified (`nostr_circle_service.dart:510` + `933`, `location_sharing_service.dart:834`; `1375` deleted by M6). Added a CI grep-guard. The original 2-site citation was incomplete.
- **Globals `OnceLock` → `RwLock<Option<Arc<…>>>`** (matching `TILE_CACHE`) so logout/relogin can reset the session and CircleManager — closes the write-once-cannot-reset blocker.
- **NSE/background MLS corruption hole closed:** `run_catchup_all_circles` gained a `receive_only` flag that processes ONLY `ApplicationMessage` and drops Proposal/Commit/Unprocessable without staging (auto-committing a proposal stages a pending commit → `OwnCommitPending`, `process.rs:79`). NSE locked to WAKE-AND-PERSIST-ONLY.
- **Android 6-hour FGS timeout corrected:** `foregroundServiceType=location` is NOT timeout-exempt on Android 15 (targetSdk=35); the matrix was downgraded from unbounded "NEAR-GUARANTEED" to "NEAR-GUARANTEED up to ~6h" with WorkManager/FCM/RebootReceiver recovery.
- **Android INTERNET permission** verified absent from `src/main/AndroidManifest.xml` (only debug/profile); the manifest fix was pulled forward to M1, CI guard in M7.
- **M1 reframed:** the 4-way decrypt distinction ALREADY EXISTS in core; M1 only surfaces it at the FFI — no core decrypt re-architecture.
- **`verify_subscriptions`** clarified as a build-time whole-Client option → the group plane MUST own a dedicated Client (cannot share RelayManager's publish Client); accounted for in T3 metadata.
- **M4 re-labeled Haven-original (NOT a WN port);** added the prerequisite test pinning MDK `process_message`-under-pending-commit behavior; the primitive is tolerant of all three documented outcomes; the unproven "mandatory clear-before-process" framing was dropped.
- **MIP-03 winner rule confirmed verbatim** from the live spec (earliest created_at, tiebreak lexicographically smallest id, reject others, retain prior states); self-update MAY / MUST-NOT-combine confirmed.
- **Inbox 7-day gift-wrap lookback** now applied to EVERY kind-1059 REQ (cursor stores raw rumor timestamp; 7d subtract live in `since_for_stream`) — closes the dormant-device missed-gift-wrap gap.
- **WN self-restarting notification task conflict resolved** in favor of local source (`session.rs:907+` IS a 1s→30s restart loop); the plan's design is retained.
- **Buffer constants corrected:** 10s initial / 60s resubscribe / 7d gift-wrap (was conflated to 60s).
- **Cursor advance** made an atomic SQL conditional `UPDATE … WHERE :ms > last_synced_ms` to prevent lost updates across the foreground/background process split.
- **Avatar epoch re-share side-effect** (`evolution_poller_provider.dart:80-96`) explicitly preserved in M6's `GroupUpdate` routing — closes the silent avatar-delivery regression.
- **Removed `flutter_hooks`/`useStream` from M6** (not a Haven dep); specified `StreamSubscription`-in-State consumption. `log::` pinned over `tracing`; `async-trait` made conditional (prefer native async-fn-in-trait); FRB single-Tokio-runtime cited; second-runtime hazard scoped to the separate-process iOS C-ABI only.
- **M9 push privacy hardened:** coarse-cadence (not per-location) token requests; quantified decoy ratio + jitter as tested invariants; `server_pubkey`/relays distinct from circle relays; drop-notification-block invariant (FCM + UnifiedPush); GrapheneOS FCM-free flavor + no-push startup fallback; correct gateway subscription mechanism (own-inbox kind-446, not user `#h`/`#p`); C-ABI primitives-only (no unsafe deref).
- **M6 rollback safety:** polling kept behind `liveSyncEnabled==false` ≥1 release; dedup `_seenEventIds` is the flag-flip reconciliation mechanism; `pollEvolutionEvents` retained as the catch-up hook; `requestCatchUp()` flagged as a NEW method.
- **M10 wipe extended to wipe-on-LEAVE** (per-circle cursor/token/buffer/kind-449 teardown); cursor/dedup bounding made a hard requirement; the `Status`/error variant restricted to a closed reason enum (no raw String) per Security Rule 8.
- **Per-platform honesty caveat added:** "at all times background" holds only for foreground + background-share users; receive-only/stationary get eventual-consistency until M9.

### Deferred / open items

- `COMMIT_SETTLE_WINDOW_SECS` has no data-driven starting value; tuned empirically in M11 against real strfry propagation. If the empirically-needed window exceeds the tolerable membership-commit latency budget, the resolution (accept slower membership commits vs slower convergence) is a product call deferred to that measurement.
- MDK `process_message` behavior under a held pending commit is documented (Haven's own test, `manager.rs:4413-4456`) as VARIABLE across {`Err(OwnCommitPending)`, `Unprocessable`, silent-advance}. The M4 prerequisite test pins it for rev `93ae324`; a future MDK bump could change it — M4's tolerate-all-three design mitigates but does not eliminate this coupling.
- Whether the M8 15-min health-check parity probe (`get_active_groups` epoch/relay enumeration) is cheap enough at scale is unverified; falls back to connectivity-only (weaker) if not.
- M9 is entirely gated on an explicit USER DECISION about accepting a push-gateway dependency (and the ASC/entitlements/Firebase setup it entails); until then, stationary-iOS and Android-receive-only near-real-time are not delivered.
- FRB enum-with-data (sealed class) codegen for `FfiRelayEvent`/`DecryptOutcomeFfi` is assumed correct but MUST be verified in the regen smoke step; fallback is a struct-of-options discriminant (loses exhaustive Dart match).


---

## Appendix M3 — StreamSink engine

> Folded in from the former `docs/M3_STREAMSINK_ENGINE.md` (retired 2026-07-16 — content moved here verbatim). This is the full design detail the M3 row in the milestone index above points to.

Status: M3 (a+b+c-core) COMPLETE + fully QC'd (2026-06-30), STAGED. Ships **dark** behind the Dart `liveSyncEnabled` flag (flipped by M11); polling continues until M6 flips it. Remaining for full M3: the settle/converge SEND-path FFI (built with M6) + `run_catchup` (M7).

**Scope:** the haven-core receive engine (`haven-core/src/relay/live_sync/`) + the FFI surface (`LiveSyncFfi` in `haven/rust_builder/src/api.rs`) that M6 consumes. Produced by an 11-agent design+confirmation workflow, then ~15 adversarial QC passes across M3a/M3b/M3c; all APIs re-verified against nostr-sdk 0.44.1, nostr-relay-pool 0.44.0, MDK `93ae324`, FRB 2.11.1 source. All three FRB STEP-0 spikes empirically proven.

**Siblings:** WN relay+epoch migration master (this document), M6 send-path convergence (Appendix M6), [M7 background sharing](M7_BACKGROUND_SHARING.md), M8 scheduled resilience (Appendix M8), [M11 rollout](M11_ROLLOUT.md).

---

### Sub-milestones (each independently testable)

- **M3a — Pure engine core** (NO relay, NO StreamSink): `event_bus.rs` (broadcast cap 8192; Lagged⇒continue, Closed⇒Ok), `router.rs`, `planes/{group,inbox,mod}.rs` filter builders + `build_relay_set_subscriptions` (URL normalize+dedup, hex-`#h`, SHA256 ephemeral-salt 16-hex sub-ids), `settle.rs` (`CommitSettleBuffer` keyed by `(group_id_hex, staged_epoch)`; `CommitClassification`; MAX 16 FIFO; TTL prune), `LiveSyncEvent`, `error.rs` (redaction-safe Display), `config.rs`. Plumbs a `CommitClassification` signal into `to_location_result`/`decrypt_location`. No Client, no static, no FFI — pure data tested against a mock decrypt.
- **M3b — Live session over a real relay** (engine-internal, no FFI): `LiveSyncCore` + `new_local`; ONE engine Client; `supervisor.rs` (RAW `client.notifications()` loop + Monitor reconnect task); `ingest.rs`+`processor.rs` (spawn_blocking decrypt under `MlsWriteGate`); `MlsWriteGate`; start/stop/resume/subscribe/unsubscribe lifecycle; settle-flush interval; `catchup.rs` signature; `health.rs` skeleton. Promotes CircleManager+RelayManager to globals with a `new_local`+`TEST_LOCK` seam. Adds `nostr-relay-builder="0.44"` dev-dep + loopback harness.
- **M3c — FFI surface + StreamSink + FRB regen:** `LiveSyncFfi` opaque + `FfiRelayEvent` (struct-of-discriminant, Debug-redacted) + `FfiGroupSpec` + `FfiSyncStatusReason` + globals. Implements the `live_events` StreamSink loop; runs `./scripts/regenerate_frb.sh`; adds the Android INTERNET-present CI guard. The 3 STEP-0 spikes are proven here.

---

### Implementation blueprint (as shipped)

#### §0. Globals & manager promotion

```rust
// haven/rust_builder/src/api.rs — mirror TILE_CACHE (api.rs:846)
static SESSION:        RwLock<Option<Arc<LiveSyncCore>>>       = RwLock::new(None);
static CIRCLE_MANAGER: RwLock<Option<Arc<CoreCircleManager>>>  = RwLock::new(None);
static RELAY_MANAGER:  RwLock<Option<Arc<CoreRelayManager>>>   = RwLock::new(None); // run_catchup needs it
```
- `std::sync::RwLock<Option<Arc<…>>>`, NOT `OnceLock` (Option = logout-resettable). Guard dropped (Arc cloned out) before any `.await`.
- **NEVER `.unwrap()` a global guard at the FFI boundary.** Every access: `SESSION.write().map_err(|_| "session lock poisoned".to_string())?` — the `current_cache` precedent (api.rs:990-998). A poisoned lock returns `Err`, never panics.
- `CircleManagerFfi::new` and `RelayManagerFfi::new` set their globals (set-once-per-login). Engine, M6 `converge_commit`, and M7 catch-up borrow the SAME `Arc<CoreCircleManager>` → exactly ONE MLS state owner.
- **Test isolation:** `#[cfg(test)] LiveSyncCore::new_local(circle, client)` builds a core without touching statics; `static TEST_LOCK: Mutex<()>` serializes the few tests exercising globals.

#### §1. Module layout — `haven-core/src/relay/live_sync/`

```
live_sync/
  mod.rs        // LiveSyncCore re-exports, LiveSyncEvent enum
  config.rs     // BUS_CAP=8192, POOL_NOTIF_CAP=8192, WORKER_QUEUE_CAP, COMMIT_SETTLE_WINDOW_SECS=8,
                //   MAX_SETTLE_COMMITS=16, BACKOFF_MIN=1s/MAX=30s, HEALTH_CHECK_SECS=900,
                //   RELAY_LIST_SECS=1800, SUB_ID_PREFIX_BYTES=8
  planes/{mod,group,inbox}.rs  // PlaneKind; build_relay_set_subscriptions; 445 #h / 1059 #p filters
  router.rs     // (RelayUrl, SubscriptionId) -> SubCtx; CircleCtx settle buffer per #h
  event_bus.rs  // broadcast::Sender<LiveSyncEvent> (cap 8192); Lagged/Closed helpers
  settle.rs     // CommitSettleBuffer keyed by (group_id_hex, staged_epoch); CommitClassification; TTL prune
  plan.rs       // plan_outcome(outcome, window_open) — cursor-gating + buffer-on-open-window
  supervisor.rs // RAW notifications() loop (NOT handle_notifications) + Monitor reconnect task
  processor.rs  // EngineProcessor: regime gate -> serialized decrypt via MlsWriteGate -> per-circle
                //   cursor advance-on-success -> settle-buffer -> bus.send
  gate.rs       // MlsWriteGate (per-circle async mutex) + generate_session_salt (OsRng, Zeroizing)
  session.rs    // LiveSyncCore: new_local/start/stop/resume_after_background/is_running/bus/settle/gate
  catchup.rs    // run_catchup_all_circles signature + foreground (receive_only=false) body
  health.rs     // scheduler spawn/shutdown SKELETON (Task bodies = M8)
  error.rs      // LiveSyncError (thiserror; Display redaction-safe, no hex>=16 / secret)
```
Registered `pub mod live_sync;` in `relay/mod.rs`.

#### §2. LiveSyncCore

```rust
pub struct LiveSyncCore {
    client: nostr_sdk::Client,                  // ONE engine Client (options below)
    circle: Arc<CoreCircleManager>,             // the one MLS state owner (CIRCLE_MANAGER global)
    relay:  Arc<CoreRelayManager>,              // for run_catchup_all_circles (RELAY_MANAGER global)
    write_gate: Arc<MlsWriteGate>,              // serializes ALL MDK-mutating calls
    router: tokio::sync::RwLock<Router>,
    bus: tokio::sync::broadcast::Sender<LiveSyncEvent>,  // cap 8192
    own_pubkey: nostr::PublicKey,               // relay-public; inbox #p
    sub_salt: zeroize::Zeroizing<[u8; 16]>,     // per-session ephemeral, OsRng, never persisted
    active: RwLock<Option<(Vec<CircleSpec>, Vec<String>)>>, // start inputs, for resume
    notif_running: std::sync::atomic::AtomicBool, // secondary double-spawn guard
    shutdown: std::sync::atomic::AtomicBool,      // explicit graceful-shutdown flag
}
```

**THE engine Client (VERIFIED):**
```rust
let pool_opts   = RelayPoolOptions::default().notification_channel_size(POOL_NOTIF_CAP); // pool/options.rs:52
let client_opts = ClientOptions::default()
    .verify_subscriptions(true)        // sdk options.rs:130; propagated per-relay (mod.rs:273)
    .automatic_authentication(false)   // sdk options.rs:93 -> pool nip42 off. NIP-42 leak fix.
    .pool(pool_opts);
let monitor = Monitor::new(64);                                            // pool/monitor.rs:34
let client  = Client::builder().opts(client_opts).monitor(monitor).build(); // NO .gossip() (default None)
```
- ONE dedicated Client serves BOTH planes (fewer sockets = amplification mitigation). `ban_relay_on_mismatch` stays default `false` — verify just DROPS mismatched events.
- `.gossip()` is explicitly OMITTED (regression-tested) so own-relays-only cannot regress into NIP-65 auto-discovery.
- `tokio::spawn` from an async `#[frb]` method survives the call (FRB persistent runtime) — proven by STEP-0 spike #1.

**MlsWriteGate:** `decrypt_location` is NOT read-only — it applies peer commits + advances the epoch (MDK `process_message`) and writes circles.db (`resync_circle_relays_from_mdk`, manager.rs:2292). The always-on engine processor therefore races the foreground finalize/converge writer. `MlsWriteGate` is a per-`nostr_group_id` map of `tokio::sync::Mutex<()>` (`HashMap<group_hex, Arc<tokio::Mutex<()>>>`) that EVERY MDK-mutating call acquires: engine `decrypt_location_for_engine`, `finalize_pending_commit`, `converge_commit`, `create_message`, `clear_pending_commit`. Distinct circles write in parallel. This makes "single SERIALIZED MLS writer" true; safe co-existence rests on M5 (no eager self-update) + `converge_commit`'s epoch TOCTOU re-check (manager.rs:2535). (Defensive: MDK storage-level serialization is not relied upon.)

#### §3. Planes & filters (VERIFIED)

**Group (445 `#h` multiplex):**
```rust
let since = since_for_stream(STREAM_GROUP_445, cursor_ms, phase, now_secs); // cursor.rs:102
Filter::new().kind(Kind::Custom(445))
    .custom_tags(SingleLetterTag::lowercase(Alphabet::H), group_ids_hex) // hex::encode(nostr_group_id)
    .since(Timestamp::from(...))
```
`#h` value == `hex::encode(nostr_group_id)`, asserted != real MLS group id. `#h ∉ active CircleCtx` ⇒ drop.

**Inbox (1059 `#p`, 7d lookback):**
```rust
Filter::new().kind(Kind::GiftWrap).pubkey(own_pubkey).since(...) // pubkey() = #p recipient, filter.rs:587
```

**Subscribe call (sdk mod.rs:634):** `subscribe_with_id_to(urls, id: SubscriptionId, filter, opts)`. Single `Filter`, `None` opts for a standing REQ, OUR id for stable router keys. Relays added+connected first (`add_relay`+`connect`, reusing the metadata-minimizing per-URL `try_connect_relay` discipline). Every relay is WSS-gated (`wss://` OR `ws_loopback_allowed_for_test`) BEFORE `add_relay`, fail-closed.

**Relay-set bucketing + sub-id derivation:** normalize (lowercase, strip trailing `/`), dedup so an inbox∩group relay is one connection, bucket circles by identical relay-set → one multiplexed `#h` REQ per bucket.
```rust
fn sub_id(salt:&[u8;16], own_pk:&[u8], plane:&str, idx:usize) -> SubscriptionId {
    let d = Sha256::new().chain_update(salt).chain_update(own_pk)
              .chain_update(plane.as_bytes()).chain_update(idx.to_le_bytes()).finalize();
    SubscriptionId::new(format!("{}_{plane}_{idx}", hex::encode(&d[..SUB_ID_PREFIX_BYTES]))) // 16-hex
}
```
The 8-byte/16-hex prefix sits AT the `redact_hex_sequences` floor (≥16 hex) so sub-ids auto-redact in logs (sha2 already a direct dep). Salt is per-session `Zeroizing`, OsRng, never persisted. The `_{plane}_{idx}` suffix discloses group-vs-inbox to the relay BY DESIGN.

#### §4. Router + settle buffer

```rust
struct SubCtx { plane: PlaneKind, group_ids_hex: HashSet<String> }
struct CircleCtx { settle: HashMap<u64 /*staged_epoch*/, Vec<BufferedCommit>>, deadline_ms: Option<i64> }
struct BufferedCommit { event_json: String, created_at_secs: u64, id_hex: String } // relay-public only
struct Router { subs: HashMap<(RelayUrl, SubscriptionId), SubCtx>, circles: HashMap<String, CircleCtx> }
```
Register BEFORE `subscribe_with_id_to`; rollback ctx on subscribe failure (no leak). `tokio::sync::RwLock`.

#### §5. Supervisor — RAW notifications loop + Monitor reconnect

**Receive is DECOUPLED from decrypt** so the pool notification broadcast (cap 8192) cannot lag while a slow SQLCipher decrypt runs. `handle_notifications` is NOT used: its `while let Ok` (pool/mod.rs:1323) treats BOTH `Lagged` AND `Closed` as `Ok(())`=exit, so a single broadcast lag permanently kills the loop. The rewrite uses a RAW `client.notifications()` receiver (sdk mod.rs:209):

```rust
async fn run_receiver(core: Arc<LiveSyncCore>, tx: mpsc::Sender<RawEvent>) {
    if core.notif_running.swap(true, SeqCst) { return; }
    let mut rx = core.client.notifications();               // subscribed BEFORE first REQ (race fix)
    loop {
        match rx.recv().await {
            Ok(RelayPoolNotification::Shutdown) => break,
            Ok(RelayPoolNotification::Event { relay_url, subscription_id, event }) =>
                { let _ = tx.try_send(RawEvent { .. }); }    // never await -> never lags pool
            Ok(_) => {}
            Err(RecvError::Lagged(_)) => continue,            // explicit: DO NOT exit (cursor+catchup net)
            Err(RecvError::Closed) => break,
        }
    }
    core.notif_running.store(false, SeqCst);
}
```
- `RelayPoolNotification::Event` is sent ONLY first-time-seen and EXCLUDES own events → no per-id dedup on the live path.
- Graceful shutdown is the explicit `core.shutdown` flag set in `stop`; a non-shutdown `Closed` restarts with 1s→30s backoff. `run_worker` drains `tx` and runs the processor one event at a time (`spawn_blocking` decrypt under the write gate); it wraps `process_group_event` in `catch_unwind(AssertUnwindSafe)` + emits `Status(Unprocessable)` on a recovered panic, so a panic in MDK decrypt cannot silently kill the receive path.

**Reconnect re-anchor — Monitor task:** `handle_notifications` does NOT return on a single-relay reconnect (only full-pool teardown), so the old trigger could never fire. Use the Monitor (pool/monitor.rs:14,44; RelayStatus::Connected status.rs:60):
```rust
async fn run_monitor(core: Arc<LiveSyncCore>) {
    let Some(mon) = core.client.monitor() else { return };
    let mut rx = mon.subscribe();
    while let Ok(MonitorNotification::StatusChanged { relay_url, status }) = rx.recv().await {
        if status == RelayStatus::Connected { reanchor_relay(&core, &relay_url).await; } // same id, Resubscribe since
    }
}
```
On a transition to Connected, re-issue that relay's REQs with the SAME `SubscriptionId` (NIP-01 replace) and a fresh `since_for_stream(Resubscribe)` anchored at the cursor. The notifications receiver is NEVER dropped across reconnects (no miss window); pool first-seen dedup makes the brief stale/new overlap latency-only. (The pool's built-in auto-resubscribe replays the stale `since` meanwhile; the Monitor re-anchor is a non-blocking refinement.)

#### §6. Processor (classify → serialized decrypt → per-circle cursor advance → emit)

`EngineProcessor::process_group_event` is SYNCHRONOUS. For each drained `RawEvent`:
1. `router.lookup` → `SubCtx`. Group + `#h ∉ group_ids_hex` ⇒ drop.
2. **Regime gate FIRST (see §7):** `if settle.window_staged_epoch(group_hex).is_some()` (regime 2) → buffer the raw event as a competitor candidate, DO NOT decrypt (a decrypted sibling forks). Else (regime 1) decrypt:
   - `Ok(Location)` → emit `Location`; advance the PER-CIRCLE cursor `group_445:{hex}`.
   - `Ok(GroupUpdate{None})` → emit; advance cursor. (Covers Commit AND PendingProposal/ExternalJoinProposal; only the Commit subvariant advanced the epoch, but cursor advance is safe — nothing left to replay; native rollback already converged any sibling.)
   - `Ok(GroupUpdate{Some})` (peer SelfRemove staged pending) → emit; DO NOT advance, do NOT finalize. M6 finalizes then calls `cursor_advance_group_to_event`.
   - `Ok(Unprocessable | PreviouslyFailed)` → emit `Status{Unprocessable}`; DO NOT advance (M1 lossless replay contract).
   - `Err(_)` competing-commit class → emit `Status{Unprocessable}`; DO NOT advance; `plan_outcome(window_open)` is a secondary guard for these rare `Err`-classified arrivals (the primary defense is the regime gate above).
3. **Inbox (1059):** emit `Welcome{gift_wrap_json}` RAW; the engine never unwraps. Inbox cursor advances only via M6's `cursor_advance_inbox_to_wrap` after a successful `process_gift_wrapped_invitation`.

Cursor advance happens in the processor BEFORE `bus.send`, so a `Lagged` bus drop cannot skip the cursor. `decrypt_location_for_engine` mirrors `decrypt_location`'s NIP-40 expiration drop + best-effort resync, stamps the routed pseudonymous `nostr_group_id` (real MLS GroupId never enters the outcome), and surfaces the classified competing signal.

**Per-circle cursor (gate #3):** `STREAM_GROUP_445` is per-`nostr_group_id` (`group_445:{hex}`), NOT one shared monotonic-max. A single shared cursor would let a busy circle's `Location` advance past a quiet co-multiplexed circle's un-applied commit and skip it on resubscribe. Per-circle keying aligns with how the buffer/converge already key by `nostr_group_id`.

#### §7. Settle-window + regime-1/regime-2 design (as implemented)

The engine BUFFERS read-only; M6 CALLS converge. The design's original assumption — "the racing sibling arrives as `Err(OwnCommitPending)`" — was empirically FALSE. The corrected as-shipped design splits into two regimes, both pinned by green regression tests (see §7 test names):

- **Regime 1 — no own pending commit** (common; all observers/members): process incoming commits in arrival order; MDK's native MIP-03 rollback (`epoch_snapshots`/`create_snapshot`/`is_better_candidate`/`rollback_to_epoch`, present in MDK `93ae324`) converges them deterministically. **NO settle buffer.** `CompetingCommit`/`Unprocessable` → no advance, NO buffer; cursor replay + native rollback reconcile.
- **Regime 2 — we hold our OWN unmerged pending commit** (rare; only the admin inside its ~8s settle window): a sibling racing our pending commit decrypts fine (different sender) and surfaces as `Ok(Commit)` → `GroupUpdate{None}` — MDK ABSORBS the `OwnCommitPending`/`CannotDecryptOwnMessage` error classes internally, so the error-class signal NEVER reaches `plan_outcome`. Blind-applying a sibling FORKS (`sibling_commit_while_holding_pending_applies_and_advances` + `blind_apply_of_siblings_forks_and_does_not_self_reconcile`) and re-delivery does not heal it. **Therefore the regime-2 gate is at the ROUTING layer, BEFORE decrypt:** while a settle window is open for a group, route an incoming same-epoch `kind:445` to the competitor buffer for `converge_commit` to resolve, rather than decrypting it. The structural root cause: `merge_pending_commit` (eager finalize) creates NO epoch snapshot (only `process_commit` does), so a self-finalized admin cannot `is_better_candidate`-rollback → fork. Eager-finalize (White Noise style) does NOT converge two staging admins (`eager_finalize_then_exchange_native_rollback_outcome` asserts `!converged`) — regime 2 genuinely REQUIRES `converge_commit`.

**Buffering + window control:** engine buffers same-epoch competitors into `CircleCtx.settle[staged_epoch]`, keyed per `#h`, bounded `MAX_SETTLE_COMMITS=16` FIFO, relay-public commit JSON only. The window is opened/closed by M6 (it owns OUR staged commit + `staged_epoch` + `CommitIntent`): after staging+publishing, M6 calls `begin_settle_window(group, staged_epoch)`; after `settle_window_secs()`, `take_settle_competitors(group, staged_epoch) -> Vec<String>` → fed to M6 `converge_commit`. The engine NEVER calls `converge_commit` (would re-introduce a second concurrent writer). Single-admin circles short-circuit (M6 skips `begin_settle_window` when `admin_pubkeys.len()==1`). One shared `tokio::time::interval` in the supervisor flushes any `#h` whose `deadline_ms` elapsed. `COMMIT_SETTLE_WINDOW_SECS=8` is a `pub(crate) const` (M11 tunes against strfry); outside the window the slower `Unprocessable→clear→adopt` path still converges, so the window is a latency optimization, not a correctness prerequisite.

**JSON→Event re-parse:** a Rust FFI helper (not Dart) re-parses each settle JSON; a malformed competitor is a HARD error to the finalize site, NEVER silently dropped (a silent drop degrades `competing_commits=[]` → the eager-merge fork leg, manager.rs:2544). An Event-JSON-roundtrip id/created_at equality test pins MIP-03 winner stability.

**Design (B) — REJECTED.** A non-destructive outer-decrypt + MLS-framing peek (to classify commit-vs-location without applying) would need private MDK APIs (`load_mls_group`), exporter-secret access (test-utils-gated), a reimplemented ChaCha20-Poly1305 outer decrypt, and a new `openmls`/`chacha20poly1305` direct dep. The rust agent's probe demonstrated the infeasibility. Not needed anyway: a location decrypts as `ApplicationMessage` and does NOT advance the epoch, so commit-vs-location is distinguishable from the destructive decrypt result itself. `converge_commit` is unchanged (`converge_is_robust_to_competitor_redelivery` proves the current body stays converged after re-delivering both competitors).

**Empirical MDK-behavior test names (all green, in `circle/manager.rs`):** `sibling_commit_while_holding_pending_applies_and_advances`, `blind_apply_of_siblings_forks_and_does_not_self_reconcile`, `no_pending_observers_converge_on_sibling_commits_via_native_rollback`, `converge_is_robust_to_competitor_redelivery`, `eager_finalize_then_exchange_native_rollback_outcome`, `decrypt_for_engine_own_pending_redelivery_is_absorbed_as_group_update` (`decrypt_for_engine_*`), `engine_processor_buffers_sibling_without_forking_when_window_open` + `engine_processor_regime1_processes_location_and_advances_per_circle_cursor` (`engine_processor_*`), `per_circle_cursor_stream_keys_*`.

**MDK-vs-settle reconciliation:** MDK's own `WrongEpoch` rollback handles a sibling arriving AFTER we advanced (no pending). The settle-window handles the BEFORE-merge race (we still hold a pending commit). The two mechanisms agree on the same MIP-03 order key.

#### §8. Teardown & lifecycle

```rust
pub async fn stop(&self) -> Result<(), String> {
    self.shutdown.store(true, SeqCst);
    self.client.unsubscribe_all().await;     // NIP-01 CLOSE all REQs
    self.client.shutdown().await;            // fires Shutdown -> receiver loop breaks
    // caller sets SESSION = None -> last Arc drop closes bus -> live_events sees Closed -> Ok
    Ok(())                                    // sub_salt zeroized on Drop
}
```
- **`start` holds the SESSION write lock for the ENTIRE build** (reserve slot → seed cursors → build Client → connect → acquire notifications receiver + spawn supervisor BEFORE first REQ → subscribe → store Arc). A concurrent second call sees `Some` → `Ok(())` (no second Client). Cursor seed (`seed_sync_cursor_if_unset(now−24h)`) BEFORE subscribe is mandatory. On ANY subscribe failure, `start` tears down (`self.stop()`) — no half-started engine (subscribe logic extracted to `register_and_subscribe`, parameterized by `SubscribePhase`: `Initial` first start, `Resubscribe` = wider 60s buffer on resume).
- `active: RwLock<Option<(Vec<CircleSpec>, Vec<String>)>>` stores the start inputs (set after a SUCCESSFUL subscribe; left `None` on a torn-down failed start).
- `resume_after_background()`: shutdown-guard (→ NoSession if stopped) → `client.connect()` (reconnect dropped relays) → rebuild + re-issue the SAME sub-ids (NIP-01 replace) for the retained circles with `Resubscribe`-phase since (lossless backfill of the offline gap; supervisor + notifications receiver untouched → no miss window) → `BackgroundResumed` status. (M3 fills the `receive_only=false` catchup body; M7 adds the platform wake plumbing + the `receive_only=true` second-process path.)

#### §9. Conflict resolutions (final rulings)

| Conflict | Ruling | Source |
|---|---|---|
| Supervisor lag handling | RAW `client.notifications()` loop, explicit `Lagged=>continue`/`Closed=>break`; decouple receive from decrypt via mpsc; pool cap 8192. NOT `handle_notifications`. | pool/mod.rs:1323; sdk mod.rs:209 |
| Reconnect re-anchor trigger | Monitor `StatusChanged->Connected`, re-issue same-id REQ with Resubscribe `since`. | pool/monitor.rs:14,44 |
| Settle / fork safety | Regime split; regime-2 gate at the ROUTING layer BEFORE decrypt (sibling arrives as `Ok(Commit)`, NOT `Err`). | MDK process.rs:66-88; manager.rs:2275 |
| NIP-42 | `automatic_authentication(false)` on the engine Client (default true). | sdk options.rs:93 |
| PSI-6 wording | "single SERIALIZED MLS writer" + `MlsWriteGate` per-circle mutex; the engine IS a writer. | manager.rs:2245,2292 |
| `FfiRelayEvent` shape | Struct-of-discriminant is PRIMARY (matches DecryptOutcomeFfi); tagged enum was the gated experiment (not needed — regen clean). | api.rs:1866 |
| evolution_mls_group_id over FFI | Do NOT ship raw MLS bytes; M6 passes `nostr_group_id` to a Rust finalize entrypoint that looks up GroupId internally. | Security Rule 4 |
| settle JSON→Event | Re-parse in Rust helper; malformed = hard error, never silent drop. | manager.rs:2544 |
| start idempotency | Hold SESSION write lock through the whole build; receiver+spawn before first REQ. | api.rs:846 |
| Global lock access | `.map_err(...)?`, never `.unwrap()`. | api.rs:990 |
| Engine tokio code | Lives in haven-core (has rt/time/net); rust_builder has only `sync`. | Cargo.toml |
| Relay manager global | NEW `RELAY_MANAGER` static for run_catchup. | nostr verifier gap |

---

### STEP-0 spikes (empirically resolved)

Three FRB 2.11.1 contracts had ZERO in-repo precedent and were unconfirmed in FRB source; all THREE are now empirically PROVEN:

1. **`tokio::spawn` from an async `#[frb]` method outlives the call** (supervisor/Monitor tasks not dropped when `start_session` returns). PROVEN: FRB's default handler is an ambient multi-thread tokio runtime; `spawn` finds the handle; the e2e test proves survival. The engine needs NO stored JoinHandles; `stop()` = cooperative shutdown.
2. **`StreamSink::add` returns `Err` when the Dart side closes** (the `live_events` loop-exit contract). PROVEN by tracing the FRB close handshake: Dart cancel → `receivePort.close` → `post` returns false → `Rust2DartSender` Err → `sink.add` Err → loop break; NO task leak on a Dart-drop-without-stop. Handled defensively regardless (the `Closed` branch exits on `stop_session`).
3. **`./scripts/regenerate_frb.sh` emits a clean `Stream<FfiRelayEvent>` + plain Dart class** for the struct-of-discriminant. PROVEN: `flutter_rust_bridge_codegen generate` produced `Stream<FfiRelayEvent> liveEvents()` + a PLAIN Dart class (no freezed) + plain enums; rust_builder compiles; `flutter analyze` error-free. The tagged-enum sealed-class experiment was therefore unnecessary.

(Deferred to M11: empirical tuning of `COMMIT_SETTLE_WINDOW_SECS` (8s) and bus/pool capacities (8192) against measured strfry propagation; confirmation that the engine Client's in-memory event DB is bounded/id-only over a multi-hour foreground session.)

---

### Final FFI surface (what M6 consumes)

All in `haven/rust_builder/src/api.rs`. EXACT surface M6 consumes.

```rust
// ───────── Globals (near TILE_CACHE, api.rs:846) — accessed via .map_err(...)?, never .unwrap() ─────────
static SESSION:        RwLock<Option<Arc<LiveSyncCore>>>      = RwLock::new(None);
static CIRCLE_MANAGER: RwLock<Option<Arc<CoreCircleManager>>> = RwLock::new(None); // set by CircleManagerFfi::new
static RELAY_MANAGER:  RwLock<Option<Arc<CoreRelayManager>>>  = RwLock::new(None); // set by RelayManagerFfi::new

// ───────── Plain data ─────────
#[derive(Debug, Clone)]
pub struct FfiGroupSpec { pub nostr_group_id: Vec<u8>, pub relays: Vec<String> } // 32 raw bytes; engine hex-encodes
pub struct CatchupResultFfi { pub processed: u32, pub unprocessable: u32, pub hit_deadline: bool }

// ───────── Closed status enum (NEVER a raw String — Security Rule 8) ─────────
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FfiSyncStatusReason {
    Connecting, Connected, Reconnecting, Disconnected,
    Unprocessable, InboxError, RelayError,
    SessionStarted, SessionStopped, BackgroundResumed,
}

// ───────── The streamed event — struct-of-discriminant (matches DecryptOutcomeFfi api.rs:1866) ─────────
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FfiRelayEventKind { Location, GroupUpdate, Welcome, Status }

pub struct FfiRelayEvent {
    pub kind: FfiRelayEventKind,
    // Location:
    pub location: Option<DecryptedLocationFfi>,
    pub nostr_group_id: Option<Vec<u8>>,          // pseudonymous only; NO evolution_mls_group_id anywhere (Rule 4)
    pub event_created_at_secs: Option<i64>,
    // GroupUpdate:
    pub evolution_event_json: Option<String>,     // Some => peer SelfRemove M6 must publish+merge
    pub competing_commits_json: Vec<String>,      // settle siblings (commits only; never location); usually empty
    // Welcome:
    pub gift_wrap_json: Option<String>,           // raw 1059; M6 unwraps via process_gift_wrapped_invitation
    pub wrap_created_at_secs: Option<i64>,
    // Status:
    pub status_reason: Option<FfiSyncStatusReason>,
}
// Hand-written Debug (mirrors DecryptOutcomeFfi Debug api.rs:1893): presence-bools + competing_commits_count only.
//   NO coords, NO group-id bytes, NO evolution/gift-wrap/competing JSON, NO secret. event_created_at_secs may print.

// ───────── Opaque handle ─────────
#[frb(opaque)]
pub struct LiveSyncFfi { circle: Arc<CoreCircleManager> } // borrows CIRCLE_MANAGER; live state lives in SESSION

impl LiveSyncFfi {
    pub fn new_instance(circle: &CircleManagerFfi, own_pubkey_hex: String) -> Result<Self, String>; // validates pubkey

    // Holds SESSION write lock through the whole build; acquires notifications receiver + spawns supervisor
    // BEFORE the first subscribe_with_id_to (race fix). Idempotent.
    pub async fn start_session(&self, groups: Vec<FfiGroupSpec>, inbox_relays: Vec<String>) -> Result<(), String>;

    // THE ONLY StreamSink method. Err if session not started (cold-start race), not a hung stream.
    // sink.add Err (Dart closed) ends THIS loop only; only stop_session tears down. Lagged => continue.
    pub async fn live_events(&self, sink: StreamSink<FfiRelayEvent>) -> Result<(), String>;

    pub async fn stop_session(&self) -> Result<(), String>;            // unsubscribe_all + shutdown + SESSION=None
    pub async fn resume_after_background(&self) -> Result<(), String>; // resubscribe(Resubscribe) + bounded catchup
    #[frb(sync)] pub fn is_running(&self) -> bool;

    // ── SEND-path FFI (DEFERRED, built with M6; engine buffers/surfaces, M6 drives converge) ──
    pub async fn subscribe_circle(&self, spec: FfiGroupSpec) -> Result<(), String>;
    pub async fn unsubscribe_circle(&self, nostr_group_id: Vec<u8>) -> Result<(), String>;
    pub async fn begin_settle_window(&self, nostr_group_id: Vec<u8>, staged_epoch: u64) -> Result<(), String>;
    pub async fn take_settle_competitors(&self, nostr_group_id: Vec<u8>, staged_epoch: u64) -> Result<Vec<String>, String>;
    pub fn parse_competitors(&self, competitors_json: Vec<String>) -> Result<usize, String>; // Rust-side hard-error re-parse
    #[frb(sync)] pub fn settle_window_secs(&self) -> u64;

    // Shared with M7. receive_only=true => process ONLY Location; drop Proposal/Commit/Unprocessable without staging.
    pub async fn run_catchup(&self, group_ids: Vec<Vec<u8>>, receive_only: bool, deadline_ms: i64) -> Result<CatchupResultFfi, String>;
    pub async fn run_health_check(&self) -> Result<(), String>;       // M8 hook; no-op shell in M3
}
```

**Core signature M3 designs for M7 (`catchup.rs`) — uses both globals:**
```rust
pub async fn run_catchup_all_circles(
    circle: Arc<CoreCircleManager>, relay: Arc<CoreRelayManager>,   // RELAY_MANAGER global
    write_gate: Arc<MlsWriteGate>,
    nostr_group_ids: &[[u8;32]],   // empty = all visible circles (get_visible_circles, manager.rs:604)
    receive_only: bool, max_duration_secs: u64,
    event_tx: Option<&broadcast::Sender<LiveSyncEvent>>,
) -> Result<CatchupResult, LiveSyncError>;
```

**Verified generated Dart:** `LiveSyncFfi.newInstance({circleManager, ownPubkeyHex})`, `startSession({groups: List<FfiGroupSpec{nostrGroupId: 32B, relays}>, inboxRelays})`, `stopSession()`, `resumeAfterBackground()`, `isRunning()` (sync), `liveEvents() → Stream<FfiRelayEvent{kind, nostrGroupId, senderPubkey, content, eventCreatedAtSecs, evolutionEventJson, giftWrapJson, wrapCreatedAtSecs, statusReason}>`.

**As-built vs. above:** the M3c-core block shipped the RECEIVE surface (globals SESSION only, `new_instance`/`start_session`/`stop_session`/`resume_after_background`/`is_running`/`live_events`, `FfiRelayEvent`/`FfiSyncStatusReason`/`FfiGroupSpec` + mappers). The SEND-path methods (`subscribe_circle`, `unsubscribe_circle`, settle FFI, `run_catchup`, `CatchupResultFfi`, `CIRCLE_MANAGER`/`RELAY_MANAGER` globals) are the DEFERRED M3c follow-up, wired with M6/M7.

---

### Deferred: dynamic subscription

The engine subscribes to the START-TIME group set only. Dynamic `subscribe_circle`/`unsubscribe_circle` FFI (the multiplex re-issue bookkeeping — CLOSE/re-issue a bucket's `#h` REQ, `router.remove`, purge `CircleCtx`) is DEFERRED. **M6 interim workaround on a circle-set change:** `stop` + `new_local` + `start` (full session restart). Per-circle cursor purge on unsubscribe is M10. (`haven/lib/src/services/live_sync_resubscriber.dart` cites this section.) Also deferred alongside it: the `run_monitor` reconnect re-anchor task (pool auto-resubscribe covers reconnect meanwhile) and `run_catchup`.

---

### Binding processor/supervisor contracts

These are the M6 hand-off contracts and exist ONLY here. The engine-side gate is IMPLEMENTED; the finalize-site contracts are M6's to honor.

1. **(HIGH — engine-side DONE) Regime-2 gate at the ROUTING layer, BEFORE decrypt.** A regime-2 sibling racing our unmerged pending commit surfaces as `Processed(Commit)` → `GroupUpdate{None}` (MDK absorbs the error), NOT `CompetingCommit` — so `plan_outcome`'s `window_open` flag never sees it and cannot prevent the fork (the commit is already applied by the time we'd plan). The processor MUST: `if settle.has_window(group_hex) { buffer the raw event as a candidate; DO NOT call decrypt_location_for_engine }`. Implemented in `processor.rs::process_group_event` + held around `process_group_event` in `run_worker`. Regression: `engine_processor_buffers_sibling_without_forking_when_window_open` (window open → buffered, epoch does NOT advance, decrypt never invoked).

2. **(HIGH — M6/supervisor) Write gate around BOTH writers.** The supervisor MUST acquire `gate.for_group(hex).lock().await` around BOTH (a) `process_group_event` (engine decrypt) AND (b) the foreground converge/finalize writer — a missed gate at either site silently reintroduces the engine-vs-foreground concurrent-MDK-write hazard. The engine side (a) is done in `run_worker`; M6 must add (b). Regression: both MDK-mutating sites share one per-circle `Arc<AsyncMutex>`.

3. **(HIGH — M6) `begin_window` inside the gate, ordered stage→begin_window→release.** The finalize site MUST call `begin_window` inside the SAME `gate.for_group(hex)` critical section as its stage+publish, BEFORE releasing the gate to the engine. A stage→release→begin_window ordering reintroduces the fork. Pin with a stage→release→deliver-sibling→assert-no-fork integration test.

4. **(MEDIUM — M6) Location-filtering at the converge boundary.** The `take_competitors → converge_commit` boundary MUST filter buffered candidates to commit-content events. The gate cannot classify `kind:445` without decrypting (Design B rejected), so a buffered Location could WIN the order key (→ converge `process_message(location)` → no advance → `RolledBack`, degraded) OR EVICT a real sibling commit from the bounded buffer (→ transient fork). Self-healing: the regime-2 cursor does NOT advance, so lossless replay re-fetches the evicted commit and the next window re-converges — but M6 must filter location-winners and SHOULD prefer commit-aware retention. This restores the design's "Location is NEVER a competitor" invariant at the convergence boundary.

5. **(MEDIUM — M6) Atomic window close with merge.** Finalize closes the window atomically with any merge so the "local epoch == staged while window open" invariant holds (the processor passes `staged_epoch` as `insert_competitor`'s `observed_local_epoch`, valid only because no merge occurs during a window). The M6 finalize critical section holds BOTH the settle lock AND the write gate across stage→begin_window and take_competitors→merge.

6. **(MEDIUM — M6/M8) Poison-event dead-letter.** `OtherError`/`Failed` never advances the cursor → a permanently-malformed `kind:445` whose `#h` matches an active circle head-of-line-blocks that circle's cursor across every resubscribe. Add a poison-event counter / dead-letter so one bad event cannot freeze a circle (liveness, not fork).

7. **(MEDIUM — M6) Loser-path test.** `AdoptedWinner{intent_still_pending:true}` re-stage racing a concurrent third commit (the bounded re-stage loop recursing into another convergence). Add with the M6 re-stage wiring.

**Late-better-after-win residual:** when we WIN and `finalize_pending_commit`, a *later* globally-better sibling cannot single-pass roll us back (`merge_pending_commit` creates no snapshot). This is NOT a guaranteed single-pass invariant; convergence for it is owed to M6's bounded re-stage + lossless replay (the regime-2 cursor doesn't advance → the better sibling re-fetches → fresh converge). The observer (no-own-commit) single-pass case IS guaranteed and tested.

---

### Privacy / security model (PSI-1..PSI-9)

#### Invariants (each tested)
- **PSI-1 / Group-ID privacy (Rule 4):** only `hex(nostr_group_id)` enters `#h` filters, sub-ids, logs. The real MLS group id NEVER leaves haven-core — `evolution_mls_group_id` is REMOVED from the FFI; M6 passes `nostr_group_id` back to a Rust finalize entrypoint that looks up the GroupId internally. Test: `#h` == `hex::encode(nostr_group_id)` and != MLS group id bytes; no raw GroupId in any FFI struct.
- **PSI-2 / sub-id non-fingerprintability:** sub-ids = `SHA256(ephemeral_salt ‖ pubkey ‖ plane ‖ idx)[..8]` (16 hex, ≥ the `redact_hex_sequences` floor → auto-redacted). Salt is `Zeroizing<[u8;16]>` from OsRng at `start_session`, never persisted (confirmed distinct from the persisted `circle_salts`/avatar DEC-6 salt), zeroized on Drop. Intra-session stability is INTENTIONAL; cross-session sub-ids differ. The `_{plane}_{idx}` suffix discloses group-vs-inbox by design.
- **PSI-3 / identity-secret containment:** the engine NEVER unwraps gift wraps and NEVER holds the nsec on the long-lived `LiveSyncCore`. 1059 events are emitted raw; M6 unwraps via `process_gift_wrapped_invitation` (per-call Zeroizing). NIP-42 is DISABLED (`automatic_authentication(false)`) so even a future signer mis-attachment cannot link the nsec to circle subscriptions.
- **PSI-4 / no raw errors (Rule 8):** the status reason is the closed `FfiSyncStatusReason` enum. Every leaf Debug is presence-only (no coords/group-id/evolution-JSON/competing-JSON/secret; only count + relay-public timestamps). The CommitClassification branch is presence-only.
- **PSI-5 / no secret retention (Rule 5):** the settle buffer holds only relay-public commit JSON, keyed by `(public group_id, epoch)`, bounded 16, TTL-pruned. No exporter secret, no plaintext. (Residual: relay-public blobs and `gift_wrap_json` transit the unzeroized Dart heap, same class as today.)
- **PSI-6 / single SERIALIZED MLS writer:** the engine processor IS an MLS writer (decrypt applies peer commits + advances the epoch + writes circles.db). `MlsWriteGate` serializes ALL MDK-mutating calls (engine decrypt, finalize, converge, create_message, clear). "Receive-only" is scoped to the NOTIFICATION/processor path (no publish); the SESSION lifecycle (resume→catchup→M6) CAN publish. Test: concurrent engine peer-commit + foreground converge from the same epoch converges deterministically with no corruption.
- **PSI-7 / cursor success-gating:** advance ONLY on `Location`/`GroupUpdate(None)` (in the processor, before `bus.send`); `GroupUpdate(Some)`/inbox advance only via M6 callback; `Unprocessable`/`PreviouslyFailed`/`Err`/`CompetingCommit` NEVER advance. A `Lagged` bus drop cannot skip the cursor. A re-delivered already-applied commit hits MDK's previously-processed gate and does not double-apply (tested).
- **PSI-8 / own-relays-only:** subscribe only to (circle ∪ inbox) relays; NO `.gossip()`, no discovery relay. Test: subscribed set ⊆ configured relays; gossip-omission regression test.
- **PSI-9 / resettable on logout (Rule 10):** `RwLock<Option<Arc>>` (not OnceLock); `stop_session` sets `None`, CLOSEs every REQ (`unsubscribe_all`), `shutdown()`s the Client, drops the engine, zeroizes the salt. Cursor purge is M10 (residual: relay-public `sync_cursors` timestamps remain in circles.db until then).

#### The irreducible presence-signal delta (the honest cost)
A persistent live socket is a continuous foreground online-presence signal plus a long-lived (this-socket ↔ set-of-`#h`) correlation. Vs polling: M3 WINS on PCS-window (toward seconds) and connect/disconnect churn; NEUTRAL on content (still E2E, no key/secret/real-group-id on the wire); introduces TWO honestly-disclosed residuals:
1. **Continuous foreground uptime** (irreducible while holding a live socket).
2. **Same-socket `#p`↔`#h` linkage** — because ONE Client serves BOTH planes, a relay in BOTH a circle's group-relay-set AND the inbox-relay-set sees the user's stable `#p` (1059 recipient pubkey) AND the circle `#h` on the SAME socket, linking "this pubkey watches these circles" for the session. This is a GENUINE regression vs a two-socket design, traded deliberately for fewer sockets (amplification reduction). Plus the joined-circle SET is now a persistent per-session fingerprint.

Mitigations (in scope): own-relays-only + scope-to-joined-circles + drop-on-leave/logout + ephemeral sub-salt + NIP-42 off. Doc-only: VPN/Tor (Mullvad) onboarding guidance.

#### SECURITY.md disclosure text (source of record)
> Extend "Network Threat Model" / "Relay-session linking" with:
>
> **Persistent receive connection (live-sync engine).** Haven holds a standing WebSocket to your configured circle/inbox relays while the app is in the foreground. A relay learns **that you are online, and which circles you watch, for as long as Haven is open** — a continuous presence signal the previous short-poll model exposed only in bursts; this is irreducible while a live connection is held. Because one connection serves both your circle subscriptions (`#h`) and your invitation inbox (`#p`, keyed to your stable public key), a relay that is in **both** a circle's relay set and your inbox relay set can link your public key to that circle for the session. We minimize exposure by: (a) connecting **only** to relays you configured (never a discovery/default relay; NIP-65 gossip is off); (b) scoping subscriptions to exactly your joined circles and dropping a circle's subscription the moment you leave; (c) closing all subscriptions and the socket on logout; (d) deriving subscription IDs from a **per-session random salt never written to disk**, so a relay cannot link your subscriptions across app sessions; and (e) **disabling NIP-42 authentication** on the receive connection, so your signing identity is never sent to a relay over this socket. The live engine's receive path is **receive-only**: it never publishes, never holds your private signing key, and never sends key material or your real MLS group identifier over the wire (only the pseudonymous `nostr_group_id`). To also hide your IP/online-presence from the relay operator, run Haven behind a VPN or Tor (e.g. Mullvad).

---

### Test plan

#### Unit (haven-core, no network) — M3a + parts of M3b
- **Bus:** in-order; `Lagged=>continue`; `Closed=>Ok`; second subscriber after first dropped.
- **Router:** register/lookup/remove; rollback on subscribe failure; sub_ids discriminate Group vs Inbox.
- **Relay-set bucketing:** lowercase + trailing-slash normalize; inbox∩group relay not double-subscribed; same-relay-set circles collapse to one multiplexed `#h`; duplicate URLs deduped.
- **`#h` encoding:** filter value == `hex::encode(nostr_group_id)`, != MLS group id bytes.
- **Inbox filter:** `Kind::GiftWrap` + `#p` (pubkey, NOT author) + 7d lookback; cursor < 7d floored at 0.
- **Sub-id:** two sessions same pubkey differ; stable within a session; 16-hex; salt never persisted.
- **Settle buffer + CommitClassification (LOAD-BEARING):** keys by `(group_id_hex, staged_epoch)`; `begin_window` RETURNS displaced competitors (no silent loss); NEVER buffers `Location`; bound 16 FIFO; TTL prune; drops post-epoch-advance competitors.
- **Processor cursor gating:** Location/GroupUpdate(None) advance the PER-CIRCLE cursor (monotonic-max); GroupUpdate(Some)/Unprocessable/PreviouslyFailed/Err/CompetingCommit do NOT; `#h ∉ ctx` ⇒ drop; re-delivered already-applied commit does not double-apply.
- **Regime-2 gate (THE must-fix):** window open → sibling `kind:445` buffered, epoch does NOT advance, decrypt never invoked.
- **receive_only=true:** only Location processed; Proposal/Commit/Unprocessable dropped without staging.
- **MlsWriteGate:** concurrent engine peer-commit + foreground converge from the same epoch → deterministic, non-corrupt epoch; shared-lock-per-group; distinct groups parallel.
- **Globals:** `stop_session` → SESSION None → `is_running()` false → fresh `start_session` rebuilds. All access via `.map_err`, never `.unwrap()` (poisoned-lock test returns Err, not panic).
- **own-relays-only:** subscribed set ⊆ (circle ∪ inbox); gossip-omission regression.

#### Integration (nostr-relay-builder loopback via `allow_ws_loopback_for_test`; strfry for e2e lanes) — M3b
- Multiplexed `#h` two-circle delivery on ONE socket (`engine_multiplexes_two_circles_and_drops_unsubscribed_h`), per-circle cursor advance.
- Unprocessable 445 → no advance → replayed on stop/start resubscribe.
- `subscribe_circle` adds live without teardown; `unsubscribe_circle` CLOSEs + purges.
- Monitor reconnect: flap ONE relay socket → `StatusChanged->Connected` re-anchors same-id REQ with `Resubscribe` since; receiver never dropped; no miss window (`engine_resume_after_background_re_anchors_and_still_delivers`).
- Lag safety: flood the loopback relay → the RAW receiver `continue`s (decoupled mpsc), engine does NOT die.
- NIP-42: inject an AUTH challenge → assert NO AUTH event sent.
- WSS gate: `engine_relay_allowed_gates_plaintext_ws` + `start_rejects_a_plaintext_ws_relay`.
- No-loss ordering; `verify_subscriptions` drops a mismatched injected event; `stop_session` ends in-flight `live_events` `Ok(())`; NIP-59 ±48h backdated 1059 via 7d lookback.

#### ffi-smoke — M3c
- `regenerate_frb.sh` emits `Stream<FfiRelayEvent>` + plain Dart class; build compiles; `flutter analyze` clean.
- `FfiRelayEvent` Debug over EVERY variant: no coords/group-id/evolution/gift-wrap/competing JSON (count only), no secret. NO `evolution_mls_group_id` anywhere.
- `live_events` before `start_session` → Err (not hung). `parse_competitors` rejects malformed JSON as a hard error. `LiveSyncFfi` opaque; globals' `Arc` Send+Sync (compile assert).

#### M4 fork tests — activatable live over strfry (F3/F5/F8/F9/F12)
M3 supplies live competitor delivery the M4 unit tests stubbed: dual-receiver siblings both pick the same MIP-03 winner (min created_at, then min hex id) and land on epoch N+1 with the same exporter secret; admin-remove racing peer SelfRemove; concurrent adds; equal-created_at id-tiebreak; the losing sibling is buffered+adopted, not dropped+cursor-skipped. Event→JSON→Event preserves id/created_at; a malformed competitor is a hard error and does NOT degrade converge to eager-merge. (M11 tunes the settle window against measured propagation.)

#### Gates per sub-milestone
Each: `cargo fmt --check` + `cargo clippy -- -D warnings` (pedantic+nursery) + `cargo test`. M3c additionally `dart format` + `flutter analyze` + `flutter test`. security-reviewer gate on M3b (MLS-adjacent receive path) and M3c (FFI + StreamSink). Coverage must not regress (80% Rust).

---

### Resume guide

**STATUS:** M3 (a + b + c-core) COMPLETE + fully QC'd (~15 adversarial passes; all 3 FRB STEP-0 spikes empirically proven; all must-fixes folded). The persistent live-sync RECEIVE engine is built end-to-end and PROVEN over a real relay; the FFI surface M6 consumes exists. Everything STAGED uncommitted (user commits; NEVER commit on their behalf).

**VERIFY GREEN:** `cd haven-core && cargo test` → 756 lib + 3 e2e (`live_sync_engine_e2e_test`) + integration; `cargo clippy --lib -- -D warnings`; `cargo fmt --check`; `cargo build --release --lib`. `cd haven/rust_builder && cargo test` → 13; `cargo clippy`. `cd haven && flutter analyze` → 0 errors.

**WHAT EXISTS (key files):**
- Engine: `haven-core/src/relay/live_sync/` — config, error, event (LiveSyncEvent+EngineDecryptOutcome+SyncStatusReason), event_bus, planes/{group,inbox,mod}, router, settle (CommitSettleBuffer), plan (plan_outcome), processor (EngineProcessor regime gate + per-circle cursor), gate (MlsWriteGate + OsRng salt), supervisor (run_receiver/run_worker), session (LiveSyncCore).
- Classifier: `haven-core/src/nostr/mls/manager.rs` (classify_mdk_error, ClassifiedProcessing, process_message_classified) + types.rs (CommitClassification).
- Convergence: `haven-core/src/circle/converge.rs` + `manager.rs::converge_commit` (~2521) + `decrypt_location_for_engine` (~2330).
- Cursor: `haven-core/src/relay/cursor.rs` + `circle/storage.rs` sync_cursors.
- FFI: `haven/rust_builder/src/api.rs` (M3c block at end) → generated `haven/lib/src/rust/api.dart` (LiveSyncFfi, FfiRelayEvent, FfiGroupSpec, enums).
- Regression tests pinning MDK behavior: `circle/manager.rs` (search `no_pending_observers_converge`, `sibling_commit_while_holding_pending`, `blind_apply_of_siblings_forks`, `eager_finalize_then_exchange`, `converge_is_robust_to_competitor_redelivery`, `decrypt_for_engine_*`, `engine_processor_*`).

**NEXT = M6** (Flutter consumer) + the M3c SEND-path FFI. The detailed M6 plan + the BINDING CONTRACTS are in the memory file `project_wn_relay_epoch_migration_plan.md` "CURRENT STATE" section AND in this doc's "Binding processor/supervisor contracts". M3c SEND-path FFI still TODO: `begin_settle_window`/`take_settle_competitors`/`parse_competitors`/`settle_window_secs` + a converge_commit FFI binding (wrap `LiveSyncCore.settle()`/`gate()`); `run_catchup` + `CIRCLE_MANAGER`/`RELAY_MANAGER` globals = M7. M9 push DEFERRED (owner decision).

---

### Changelog (condensed)

Append-only build log, distilled. All dated 2026-06-29 unless noted; each entry green + clippy/fmt clean.

- **M3a implemented + QC'd** (732→741 lib green). Four adversarial reviews: rust APPROVE; security APPROVE-WITH-MUST-FIX (DoS→fork closed by MDK commit *authentication* — only authenticated same-epoch siblings reach the buffer; classifier fails safe); marmot APPROVE-WITH-MUST-FIX (order-key-minimal retention proven fork-safe); test-writer coverage gaps filled. Folded: `begin_window` returns displaced competitors (no silent loss); `BufferedCommit` presence-only Debug; convergence guarantee scoped to "both members that receive the winner within the window"; +9 tests.
- **M3b gates carried from M3a QC:** (1) salt lifecycle (OsRng/Zeroizing/never-persist + negative test); (2) sibling-MDK-return must be empirically pinned + no blind-apply while a window is open; (3) per-circle group cursor (co-multiplexed circles' gaps); (4) forged back-dated competitor → `RolledBack`; (5) NIT distinct `Converging` reason.
- **M3b empirical findings + design resolved:** the design's "sibling arrives as `Err(OwnCommitPending)`" was FALSE — a sibling racing our pending commit returns `Ok(Commit)` and MDK ABSORBS the error classes internally. **Regime split adopted:** regime 1 (no own pending) uses MDK's native MIP-03 rollback (NO buffer); regime 2 (own pending, admin's ~8s window) MUST buffer-before-decrypt + `converge_commit`. **Design (B) (openmls outer-decrypt peek) REJECTED** as infeasible/unnecessary. `converge_commit` left unchanged (`converge_is_robust_to_competitor_redelivery`).
- **M3b engine core built** (740→748 lib): `decrypt_location_for_engine` (regime-1 decrypt, Rule-4 stamp) + `plan_outcome(window_open)` + `EngineProcessor` (routing gate: buffer-before-decrypt when window open) + per-circle cursors + `MlsWriteGate` (per-circle async mutex) + `generate_session_salt` (OsRng/Zeroizing). QC: security APPROVE (`saturating_add` expiration-grace fix folded); marmot APPROVE-WITH-MUST-FIX (found the structural root cause — `merge_pending_commit` creates no snapshot; late-better-after-win owed to M6 re-stage). Binding M3b-processor + M6/supervisor-seam contracts recorded (now in "Binding processor/supervisor contracts").
- **M3b async networking engine built + e2e-proven** (753→756 lib + 3 e2e): `supervisor.rs` (RAW notifications loop + decoupled worker holding the write gate + `catch_unwind`) + `session.rs` `LiveSyncCore` (`new_local`/`start`/`stop`) + `tests/live_sync_engine_e2e_test.rs` over a real MockRelay. QC: security APPROVE-WITH-MUST-FIX (H1 WSS-gate every relay before add_relay — folded; M1 teardown-on-subscribe-failure — folded); rust APPROVE-WITH-MUST-FIX (worker panic isolation, `WORKER_QUEUE_CAP` const — folded). ~6 review passes; all folded.
- **M3b lifecycle:** `resume_after_background` (NIP-01 replace, Resubscribe-phase since, lossless offline-gap backfill) + `active` start-input store + multiplex/resume e2e. rust APPROVE. Deferred (M6 stop+new_local+start meanwhile): dynamic `subscribe_circle`/`unsubscribe_circle`, `run_monitor` reconnect re-anchor, `run_catchup`.
- **M3c core FFI surface built + regenerated** (2026-06-29/30, spike #3 PROVEN): `SESSION` global + `FfiRelayEvent` (struct-of-discriminant, presence-only Debug, NO `evolution_mls_group_id`) + `FfiSyncStatusReason` + `FfiGroupSpec` + mappers + `LiveSyncFfi` (new_instance/start_session/stop_session/resume_after_background/is_running/live_events StreamSink). Regen touched only rust_builder + generated Dart (haven-core untouched); +4 FFI-smoke tests; rust_builder 13 tests + Dart analyze clean.
- **M3c core QC complete (2026-06-30):** security APPROVE (no findings); rust APPROVE — **spikes #1 and #2 empirically proven** (FRB default multi-thread runtime → spawn survives without JoinHandles; Dart-close handshake → `sink.add` Err → loop break, no leak). NO MUST-FIX. **M3 (a+b+c-core) = COMPLETE + FULLY QC'd** (~15 adversarial passes, all 3 STEP-0 spikes proven). Remaining for full M3: settle/converge SEND-path FFI (M6) + `run_catchup` (M7).


---

## Appendix M6 — Send-path convergence

> Folded in from the former `docs/M6_SEND_PATH_CONVERGENCE.md` (retired 2026-07-16 — content moved here verbatim). This is the full design detail the M6 row in the milestone index above points to.

Status: M6 COMPLETE + fully QC'd (2026-07-01), STAGED. Built on the M3 (a+b+c-core) engine. Wired into the 3 finalize sites.

Scope: the SEND-path convergence FFI on `LiveSyncFfi` (thin wrapper over `LiveSyncCore` orchestration in haven-core) + the Dart wiring for the 3 finalize sites (foreground self-update / membership add / remove) and the in-Rust receiver auto-commit path. Master: WN relay+epoch sync migration (this document). Engine: M3 StreamSink engine (Appendix M3).

---

### Pinned facts (from M3 — do not re-derive)

- `converge_commit(&self, mls_group_id, our_commit, staged_epoch, competing_commits, intent) -> CommitConvergence{Merged | AdoptedWinner{intent_still_pending} | RolledBack}` (`manager.rs:2611`). Sync. Does NOT publish. Never leaves a dangling pending commit. Uses ungated `group_epoch_internal` (release-safe).
- `CommitIntent { None | RemoveMembers(Vec<PublicKey>) | AddMembers(Vec<PublicKey>) }`.
- Gate `MlsWriteGate` (`core.gate().for_group(hex) -> Arc<tokio::Mutex<()>>`) + settle buffer (`core.settle() -> Arc<std::Mutex<CommitSettleBuffer>>`) live in `LiveSyncCore` (the `SESSION` global in `rust_builder/api.rs`). `run_worker` already holds `gate.for_group(hex).lock().await` around `process_group_event`.
- Settle buffer API: `begin_window(hex, staged_epoch, deadline_ms) -> Vec<BufferedCommit>` (returns displaced prior competitors); `take_competitors(hex, staged_epoch) -> Vec<BufferedCommit>` (REMOVES the window); `close_window(hex)`; `window_staged_epoch(hex)` (regime-2 signal → buffer-don't-decrypt). `BufferedCommit { event_json, created_at_secs, id_hex }`.
- Engine regime gate (processor.rs): `settle.window_staged_epoch(hex).is_some()` → buffer the raw kind:445 as a competitor, NEVER decrypt (a decrypted sibling forks); else → decrypt + plan + advance per-circle cursor + emit.
- Publish happens in **Dart** (`publishEvolutionEvent` FFI with retry/backoff). Stage and merge are **separate** FFI calls. Legacy finalize: stage (leaves pending) → publish → `finalizePendingCommit` (merge) on success / `clearPendingCommit` on failure. None observes competitors.
- Staged epoch is NOT captured at any Dart site (only epoch FFI accessor is debug-gated) → the converge FFI reads the epoch in Rust.
- The real MLS group id ALREADY crosses the FFI internally (Dart passes it to `finalizePendingCommit`/`clearPendingCommit`). Security Rule 4 is about **relay publication**, not the internal Dart↔Rust boundary. Engine *stream events* still carry only `nostr_group_id` (hot-path minimization).
- A pending commit does NOT advance `group_epoch` (advances only on merge). Reading the epoch before or after staging yields the same `staged_epoch = N`.

---

### Decisions A–G (final rulings)

All three reviewers (marmot + rust + security, read-only) approved against MDK `93ae324` / MIP-03 source.

- **A — publish-DURING-window, not after-converge.** For two concurrent admins at epoch N to converge, **each must publish its commit during the window** so the other collects it as a competitor (the engine buffers same-epoch kind:445 while a window is open). Order: `CS1 stage(pending@N)+open window → publish OUR commit UNCONDITIONALLY → wait settle_window_secs → CS2 take competitors + converge_commit (LOCAL state only)`. Publishing a **losing** commit is harmless: it is at stale epoch N and dropped via `WrongEpoch` (`mdk error_handling.rs:325-431`), no rollback; every member deterministically adopts the MIP-03 winner. `converge_commit`'s logic is orthogonal to whether we published. **This inverts** `converge_commit`'s old "publish only if Merged" doc (the only place that contract lived) — the doc-comments (`manager.rs:2592`, `converge.rs:21-25`) were rewritten. SECURITY.md accepted-residual added: "a superseded same-epoch commit may transiently appear on the relay during multi-admin convergence — reveals a race occurred, not its membership target."
- **B — the two gate critical sections.** CS1 = gate→[read epoch (`group_epoch_internal`)→`begin_window`→stage]→release for publish+wait; CS2 = gate→[`take_competitors`→`converge_commit`→`close_window`]. Releasing the gate during network publish + settle-wait is sound: the window-open invariant makes the engine buffer-not-apply for that circle, so no concurrent engine MLS write. `begin_window`-before-stage is equivalent to the contract's literal stage→begin_window (one held gate; a pending commit doesn't advance the epoch). Lock order uniformly **gate→settle**, no deadlock. **H1 (HIGH):** every `settle().lock()` in a `{}` block with NO `.await`. **H2 (MED):** `.lock().unwrap_or_else(PoisonError::into_inner)`, never `.unwrap()`.
- **C — competitor filtering: pass ALL, accept RolledBack. Do NOT harden.** The settle buffer holds raw kind:445 JSON; the engine can't classify commit-vs-location without decrypting (Design B "peek" rejected). Pass all buffered candidates to `converge_commit`: a Location winner → `process_message(location)` doesn't advance the epoch → step-(d) epoch guard → `RolledBack` (no fork, no dangle, no stale secret → bounded re-stage). Correct but degraded; single-pass hardening (skip a candidate that fails to advance, try next-best) is M11 latency work with its own property test.
- **D — receiver auto-commit (site 3): converge path-B IN-RUST, no Dart round-trip.** When the engine receives a peer's `SelfRemove` proposal, MDK auto-commits it via `stage_commit` (`proposal.rs:329`), leaving the auto-committer in **regime 2**; two concurrent auto-committers fork. A window is required, BUT a Dart round-trip leaves a **dangling pending commit if the app is killed between the `GroupUpdate` emit and CS2** (the migration's motivating lifecycle) — `prune_expired` drops the window without clearing the commit → bricks the member. **The Dart round-trip was therefore rejected.** Instead the **engine** (which owns the `Client`) opens the window, publishes the commit (idempotent/retry-bounded; publish-fail → `clear_pending_commit`+`close_window`), waits the settle interval, calls `converge_commit` itself, then emits a post-convergence `GroupUpdate{None}` to Dart for UI only. This eliminates the `staged_epoch` FFI field, the `nostr→mls` resolver, and `ConvergeKeyFfi`. `converge_after_window` stays **path-A-only** (`mls_group_id`).
- **E — bounded ≤2 re-stage + carry displaced competitors.** `AdoptedWinner{intent_still_pending}` (add/remove only; `None` never re-stages) → Dart re-stages the unsatisfied intent, bounded ≤2 (each retry = fresh CS1→publish→wait→CS2). `begin_window` returns competitors displaced from a prior still-open window; CS1 carries them into the new window (re-inserts), never drops them (no lost-competitor fork). Intent mapping: removeMember → `RemoveMembers([pk])`; addMember → `AddMembers([kp pubkeys])`; self-update + receiver-auto-commit → `None`.
- **F — per-type gated stage variants; engine-off → `Ok(None)`.** The existing stage FFI is un-gated and can't be reused (the stage must be inside the gated section). **`StagedAddFfi.welcome_events` published by Dart ONLY after `Merged`** (welcomes for a losing add reference an epoch that never committed). Engine-off → **`Ok(None)`** (not a sentinel string) so legacy fallback can't fire on a real error. Publish-failure cleanup → an `abort_converging_window` FFI (gated `clear_pending_commit`+`close_window`).
- **G — flag-gated coexistence, not deletion.** `liveSyncEnabled` (Dart const, default OFF, mirrors `enablePeriodicSelfUpdate`). OFF: engine never starts, new FFI never called, legacy eager finalize + pollers run exactly as today (zero behavior change). ON: engine starts, pollers gated off, finalize sites use the converge FFI. Physical deletion of the poller code deferred to M11 (once the flag is permanently ON).

**Architecture:** orchestration lives on `LiveSyncCore` (haven-core), unit-testable; the FFI is a thin wrapper. The gate + settle are keyed by `hex(nostr_group_id)` (the `#h` routing key), so path-A methods take BOTH `mls_group_id` (for `converge_commit`/stage) AND `nostr_group_id` (the gate/settle key — Dart has both from the `Circle`).

### SEND-path FFI surface

On `LiveSyncFfi` — refactored in M6-4 to module-level FRB **free functions** (they only need `SESSION`); all gated via `SESSION`'s core.

```
// sync
settle_window_secs() -> u64

// CS1 (gated: read epoch, begin_window, stage). Returns commit JSON + staged_epoch (+welcomes for add).
stage_self_update_converging(mls_group_id, nostr_group_id) -> StagedCommitFfi
stage_remove_members_converging(mls_group_id, nostr_group_id, member_pubkeys) -> StagedCommitFfi
stage_add_members_converging(identity_secret, mls_group_id, nostr_group_id, members, fallback_relays) -> StagedAddFfi

// CS2 (gated: take_competitors, filter-to-commit, converge_commit, close_window).
converge_after_window(mls_group_id, nostr_group_id, our_commit_json, staged_epoch, intent) -> ConvergeResultFfi

// publish-failure / any-converge-error cleanup (gated: clear_pending_commit + close_window).
abort_converging_window(mls_group_id, nostr_group_id, staged_epoch)
```

Engine off (`SESSION == None`) → all return `Ok(None)` so the Dart caller falls back to the legacy eager path unchanged.

**FFI types (all presence-only `Debug`):** `StagedCommitFfi{ commit_json⟨redacted⟩, staged_epoch }`; `StagedAddFfi{ commit_json⟨redacted⟩, staged_epoch, welcome_events⟨redacted⟩ }`; `ConvergeIntentFfi{ kind: None|Remove|Add, pubkeys⟨count-only⟩ }`; `ConvergeResultFfi{ kind: Merged|AdoptedWinner|RolledBack, intent_still_pending }` (derive OK — non-secret). (`ConvergeKeyFfi` was eliminated by Decision D — path-A-only.)

### M6-2 path-B in-Rust convergence (impl)

When a peer's `SelfRemove` reaches the engine, MDK auto-commits it (`stage_commit`), leaving the auto-committer in **regime 2**; two concurrent auto-committers fork. Decision D: the engine converges it in-Rust, no Dart round-trip. Shipped in `relay/live_sync/autocommit.rs`.

**Internal types (MLS group id stays in-crate, never crosses FFI):**
- `EngineDecryptOutcome::AutoCommit { nostr_group_id, mls_group_id: GroupId, commit_json }` — produced by `decrypt_location_for_engine` for the `GroupUpdate{Some(commit)}` (auto-commit) case. `GroupUpdate{None}` (an *applied* peer commit, no pending) stays → UI.
- `AutoCommitWork { mls_group_id, nostr_group_id, staged_epoch, commit_json }` — handed from `process_group_event` to `run_worker`.
- `GroupProcessOutcome::AutoCommitStaged(Box<AutoCommitWork>)` — new variant.
- `EngineHandles { client, circle, gate, settle, bus }` — bundle threaded into `run_worker` so it can spawn the converge task (the engine was receive-only; this adds publish capability).

**Flow:**
1. `decrypt_location_for_engine` (manager.rs): `GroupUpdate{Some(commit)}` → `AutoCommit{..}`; `{None}` unchanged.
2. `plan_outcome` (plan.rs): defensive no-op `AutoCommit` arm (unreachable — intercepted earlier; needed for exhaustiveness).
3. `process_group_event` (processor.rs, regime 1): on `AutoCommit` → read `staged_epoch = group_epoch_internal` (read-error → `clear_pending_commit`+status+return, no dangle), `begin_window` (fresh — regime-1 guarantees no prior window), return `AutoCommitStaged(work)`. Does NOT advance the cursor (not applied until converged).
4. `run_worker` (supervisor.rs): on `AutoCommitStaged(work)` → `tokio::spawn(run_autocommit_converge(handles.clone(), *work))` AFTER dropping the gate (the open window protects). Gains `handles: EngineHandles`. **Also folds L2**: keys the gate by `hex::encode(&nostr_group_id)` (lowercase).
5. `run_autocommit_converge`: (a) publish `commit_json` to `get_circle(&mls_group_id).relays` via `client.send_event_to` (bounded retry); (b) publish-fail → `gated_abort` + `RelayError` status, return; (c) `sleep(settle_window_secs)`; (d) `gated_converge(.., CommitIntent::None)`; (e) `Ok` → emit `GroupUpdate{None}` (UI: roster changed); `Err` → `gated_abort` + status.
6. **DRY**: `converge_after_window`/`abort_converging_window` bodies extracted into free fns `gated_converge(...)` / `gated_abort(...)`; the `LiveSyncCore` methods and `run_autocommit_converge` are thin reusers (no duplicated protocol-critical converge logic). H1/H2 folded via `WindowCloseGuard`.

**Residual (deferred):** if the engine **process** is killed during the ≤8 s converge task, the pending commit dangles until recovery — far smaller than the rejected Dart-round-trip (process-lifetime vs app-UI-lifetime). On restart the un-advanced cursor re-delivers the `SelfRemove`; MDK recovery of a pre-kill pending commit is the edge to validate. A `prune_expired`→`clear_pending` backstop needs a `nostr→mls` lookup and is deferred to M8.

### M6-3 Dart stream consumer (impl)

The engine delivers decrypted events over `LiveSyncFfi.liveEvents()` (`Stream<FfiRelayEvent>`). M6-3 consumes it, gated behind `liveSyncEnabled` (default OFF → pollers stay; zero behavior change). ON → engine drives receive, the 3 receive pollers gate off, same providers/persistence fed from the stream. With path-B in-Rust, `GroupUpdate` stream events are UI-only. Files: `live_sync_provider.dart`, `subscription_service.dart`, `nostr_subscription_service.dart`.

**Key facts:**
- **`memberLocationsProvider` re-POLLS on invalidate** (calls `fetchMemberLocations`) → a stream-pushed location CANNOT use plain `ref.invalidate` (re-fetches over network). Fix: a cache-only read path.
- Location `content` is serde `LocationMessage` JSON (opaque in Dart) → a Rust FFI parse-helper, no Dart schema duplication.
- Receiver auto-commit is **poller-free** (M6-2 moved it in-Rust) — the stream consumer must NOT reproduce it.
- `epochReshareForCircle(mlsGroupId)` needs the MLS id; GroupUpdate carries only `nostr_group_id` → resolve via `circlesProvider` match on `Circle.nostrGroupId`.
- `liveEvents()` throws with no session (cold-start race) → wrap `.listen()` in try/catch, only after `startSession()` resolves.
- Engine owns reconnection → do NOT `stopSession()` on pause; `resumeAfterBackground()` on resume; `stopSession()` only on logout/dispose.

**New Rust FFI (parse-helper, regen):** `parse_engine_location(content_json) -> Result<LocationContentFfi, String>` reusing `LocationMessage` deserialization. `LocationContentFfi { latitude, longitude, geohash, timestamp_secs, expires_at_secs, display_name: Option<String> }` (sender + nostr_group_id come from the stream event, not the content).

**Flag:** `const liveSyncEnabled = false;` (top-level const, mirrors `enablePeriodicSelfUpdate`) in `lib/src/providers/live_sync_provider.dart`.

**`LocationSharingService` new methods (reuse persist, no poll/auto-commit):**
- `ingestStreamedLocation({circle, decrypted})` — self-echo drop + `_persistDecryptedLocation` + cache merge (timestamp-wins merge is the dedup; no `_seenEventIds`).
- `cachedLocations(circle) -> List<MemberLocation>` — `_hydrateFromStoreIfNeeded` + cache snapshot (non-expired, non-self). The cache-only read.
- `reconcileRoster(circle)` — evict cache members no longer in the MLS roster (reuse `_evictDepartedMembers`) — for GroupUpdate (a departed member must leave the map).

**`memberLocationsProvider`:** when `liveSyncEnabled` → `service.cachedLocations(circle)` (no network); else `fetchMemberLocations`. The stream consumer writes-to-cache then `ref.invalidate(memberLocationsProvider)` → re-reads cache.

**`NostrSubscriptionService` (testable split):**
- `subscription_service.dart`: `abstract SubscriptionService { start(groups, inboxRelays); resumeAfterBackground(); stop(); bool get isRunning }` + `SubscriptionServiceException`.
- `nostr_subscription_service.dart`: `NostrSubscriptionService implements SubscriptionService`. Builds `LiveSyncFfi.newInstance(circle, ownPubkeyHex)`, `startSession`, `liveEvents().listen(handleEvent)`. **`handleEvent(FfiRelayEvent)` is the pure testable router** (deps = `CircleService` + a narrow location-sink + callbacks). Routing:
  - **Location** → parse content (FFI helper) → `DecryptedLocation` → `locationSink.ingestStreamedLocation` → `onLocationsChanged()` (invalidate memberLocations).
  - **GroupUpdate** (UI-only) → resolve circle by nostr_group_id → `locationSink.reconcileRoster` + `onGroupUpdated(circle)` (invalidate circles+memberLocations + `epochReshareForCircle(circle.mlsGroupId)`).
  - **Welcome** → `circleService.processGiftWrappedInvitation(secretBytes, giftWrapJson)` + `advanceInboxCursorToWrapSecs(...)` + `onInvitationReceived()`. Secret bytes zeroized after use (Rule 9).
  - **Status** → `onSyncStatus(statusReason)` → `syncStatusProvider`.
  - All callbacks individually `try/on Object catch`-guarded (per `onAvatarComplete` precedent) so an invalidation failure never kills the stream loop.

**`syncStatusProvider`:** `NotifierProvider` (mirrors `invitationPollStatusProvider`); immutable `SyncStatus` (phase enum from `FfiSyncStatusReason`); the service pushes Status events into it.

**Lifecycle (`map_shell.dart`, all gated `if (liveSyncEnabled)`):**
- `initState` postFrame (after relay init): build `FfiGroupSpec`s from accepted circles + inbox relays → `subscriptionService.start(...)` → consume `liveEvents()`.
- `_onResumed`: `subscriptionService.resumeAfterBackground()`.
- `_startTimers` receive/evolution/invitation + iOS-bg sites: skip when `liveSyncEnabled` (engine replaces them). PRESERVE prune + heartbeat.
- `dispose`: `subscriptionService.stop()`.
- `identity_provider.deleteIdentity`: `await subscriptionService.stop()` BEFORE `service.deleteIdentity()` (best-effort try/catch).

### M6-4 finalize-site wiring (impl)

Wired the converging FFI into the 3 foreground finalize sites (self-update [M5-disabled] / membership add / remove), flag-gated behind `liveSyncEnabled` (default OFF → whole branch tree-shakes out; legacy eager path runs on `staged==null` engine-off flag-race). The loop was extracted into a pure, injected-ops, FFI-free testable free fn **`runConvergeFinalize`** in `haven/lib/src/services/converge_finalize.dart`, honoring: publish-failure → `abort_converging_window`; welcomes-only-after-`Merged`; bounded ≤2 re-stage; **L1** (abort on ANY converge error incl. a converge throw, not just publish-fail). `nostr_circle_service.dart` gained `_convergeContext`/`_abortConvergeAndClear`/`_publishConvergedWelcomes`/`_runConvergingFinalize`.

**Folded must-fix (unanimous):** silent bounded-exhaustion made membership ops report a **false success** (member never added/removed; unlike self-update there is no periodic scheduler to retry). Fix: `runConvergeFinalize` returns **`ConvergeFinalizeOutcome{merged, adoptedSatisfied, notApplied}`**; `removeMember`/`addMember` `throw CircleServiceException` on `notApplied` (user-retryable); self-update ignores it (hourly scheduler retries a rolled-back rotation). Self-update branch is dead under shipped flags (also gated by `enablePeriodicSelfUpdate`=false).

### Deferred hardening (to M8/M11)

- **M11 — contract-#3 liveness:** the Decision-C "pass all candidates" single-pass hardening (a Location-poisoned window degrades liveness only when the flag is ON) with its own property test.
- **M11 — L1 secret re-fetch:** the Dart `identitySecretBytes` stays reachable across the ~25–30 s settle window on the Add re-stage path (Dart has no zeroize); mitigate by re-fetching the secret per re-stage attempt rather than closing over it. (`TODO(M11)` in place.)
- **M11 — `waitWindow` non-cancellability:** the `Future.delayed` settle wait is not cancellable on logout/dispose — cleanup is eventual+correct but not instant.
- **M11 — no Dart re-entrancy guard:** the Rust per-circle gate is the serialization point; no Dart-level guard.
- **M11 — membership-`notApplied` unit test** (deferred-tracked).
- **M8 — `prune_expired`→`clear_pending` wiring:** the backstop that clears a dangling pending commit on a pruned window (needs a `nostr→mls` lookup). `TODO(M8)` in place.

Cross-links: [M7 background sharing](M7_BACKGROUND_SHARING.md), M8 scheduled resilience (Appendix M8), [M11 rollout](M11_ROLLOUT.md).

---

### Changelog (condensed)

- **M6-1 — DONE + QC'd (2026-06-30):** haven-core path-A convergence orchestration on `LiveSyncCore` (`stage_*_converging`/`converge_after_window`/`abort_converging_window` + `settle_window_secs` in `relay/live_sync/finalize.rs`) + FFI wrappers + presence-only Debug + Decision-A doc rewrite + SECURITY.md residual. 8 finalize tests over a real MLS group + 6 FFI smoke tests + regen. rust + security QC APPROVE. Green: haven-core 764 lib, rust_builder 19, Flutter 1478/3.
- **M6-2 — DONE + QC'd (2026-06-30):** path-B in-Rust engine convergence in `relay/live_sync/autocommit.rs` (`run_autocommit_converge`/`publish_commit`/`EngineHandles`/`AutoCommitWork` + `WindowCloseGuard`) + `decrypt_location_for_engine` AutoCommit split + processor window-open + supervisor spawn + DRY `gated_converge`/`gated_abort` + L2 (lowercase gate key). marmot CONFIRM-all + security + rust APPROVE; H1/H2 folded. 9 tests incl. two-auto-committer convergence + a full relay e2e. haven-core 775 lib + 3 e2e green.
- **M6-3 — DONE + QC'd (2026-06-30):** Dart stream consumer + `liveSyncEnabled` flag + `syncStatusProvider` + lifecycle wiring + pollers gated. `parse_engine_location` FFI helper, `live_sync_provider.dart`, `subscription_service.dart` (testable `LiveEventRouter`), `nostr_subscription_service.dart`, `LocationSharingService.{ingestStreamedLocation,cachedLocations,reconcileRoster}`, memberLocationsProvider cache-only path. security + flutter APPROVE (F2/F3/F4/F6 applied; F1/F5 refuted — mlsGroupId is the stable group selector). 11 router/status + 4 ingest tests. Flutter 1496/3.
- **M6-4 — DONE + QC'd (2026-07-01):** wired the converging FFI into the 3 finalize sites; converging methods refactored to module-level FRB free functions; loop extracted into `runConvergeFinalize` (`converge_finalize.dart`) with L1 + bounded ≤2 + welcomes-after-Merged. Adversarial QC (security SAFE-TO-SHIP; marmot CORRECT-AFTER-FIXES; flutter SHIP-AFTER-FIXES). **Folded must-fix:** bounded-exhaustion false-success → `ConvergeFinalizeOutcome{merged,adoptedSatisfied,notApplied}`, membership ops `throw` on `notApplied`. +2 tests. Deferred to M11: L1 secret re-fetch, `waitWindow` cancel, re-entrancy guard. Green: rust_builder 21, 11 `converge_finalize` tests, Flutter 1507/3.
- **M6-5 — DONE (2026-07-01):** final 6-dimension adversarial QC → 0 must-fix, 7 should-fix, 9 nits, 2 false-positives; the rust-core dimension re-run standalone found ONE real latent concurrency bug. **Folded:** (a) **`supervisor.rs run_worker` panic-close race** — the MDK-panic `Err` arm closed the settle window unconditionally after releasing the gate, could clobber a concurrent foreground finalize's window (fork). Fixed with a `had_window_before` snapshot + gate-held conditional close (closes only a window THIS call opened); re-verified FIX-CORRECT. (b) `concurrent_admin_add_distinct_members_converges` test (untested `AddMembers` converge path). (c) `settle.rs` contract-#3 doc reconciled to as-built Decision C. (d) `NostrSubscriptionService` lifecycle test (6 tests). (e) nits: caller secret zeroize (Rule 9), 2 Welcome-zeroize tests, `TODO(M11)` secret-reuse, `TODO(M8)` `prune_expired`→`clear_pending`. GREEN: haven-core 776 lib + 3 e2e; rust_builder 21; Flutter 1515/3. **M6 = COMPLETE + fully QC'd.**


---

## Appendix M8 — Scheduled resilience

> Folded in from the former `docs/M8_SCHEDULED_RESILIENCE.md` (retired 2026-07-16 — content moved here verbatim). This is the full design detail the M8 row in the milestone index above points to.

**Status:** M8 DONE + QC'd, STAGED (2026-07-03/04). Ships inert, self-gated on
`liveSyncEnabled` (flipped by M11). Remaining items DEFERRED to M10/M11.

Nuance on "inert": engine gating is **per-task**. B1 RelayListMaintenance + B2
KeyPackageMaintenance are **engine-independent and run ACTIVE today** — they fix reachability
on the current poll path (KeyPackage discovery, relay-list freshness) regardless of
`liveSyncEnabled`. Only B3 SubscriptionHealthCheck is engine-coupled: its FFI reads `SESSION`
and no-ops while the engine is off, so it **builds inert** and activates with no code change when
M11 flips the flag (like M7-C/D shipped inert).

Scope was owner-APPROVED (2026-07-03) after research → draft → 4 adversarial confirmations
(marmot/rust/nostr/security). **Owner decision:** B2 = **full stable-`d` correctness** (not the
minimal variant).

Siblings: this document is the master plan (see the milestone index above); the engine and
send-path designs are [Appendix M3](#appendix-m3--streamsink-engine) and
[Appendix M6](#appendix-m6--send-path-convergence); background sharing is
[`docs/M7_BACKGROUND_SHARING.md`](M7_BACKGROUND_SHARING.md); rollout is
[`docs/M11_ROLLOUT.md`](M11_ROLLOUT.md).

---

### Architecture (as built)

**Dart-timer-driven FFI, NOT a Rust-core `tokio` scheduler.** A core-resident scheduler is
**impossible**: the **identity secret key lives only in Dart** (Flutter secure storage).
`CircleManager`/`LiveSyncCore` hold pubkey-only, but relay-list/KeyPackage publishing *requires*
the secret to sign (10050/10051/30443/443). A core scheduler cannot sign, and threading the secret
into a long-lived Rust task violates **Security Rule 9** (minimize secret lifetime; re-fetch per
use). So:

- A Dart `MaintenanceScheduler` `Notifier` owns **3 self-rescheduling jittered timers** (mirrors the
  existing invitation/evolution/avatar pollers), anchored after identity load, with a **guaranteed
  cancel path** on logout/teardown. No new Rust runtime.
- Each tick **re-fetches the identity `Zeroizing` secret**, calls an idempotent, **fail-soft** Rust
  FFI maintenance method, and never throws into the app. Secret scrubbed in `finally` (Rule 9).
- Rust owns the *logic* (what/whether to republish); Dart owns the *cadence + secret*.
- FFI methods return **presence-only** outcome enums/counters — never group-ids/URLs/hex.

**Cadence (as built):** KeyPackage nominal 10m, relay-list 30m, health 15m, **all jittered ±25%**
(`Random.secure`, anti-fingerprint — improves on the plan's literal `Timer.periodic`). Fire-on-start
with initial settle delays (KP 2m, relay-list 1m, health 90s). No-overlap guard per task
(skip a tick if the prior run is still in flight); cancel-before-arm on a single-owner timer field.

**FFI landed on `RelayManagerFfi`** (not `CircleManagerFfi` as originally scoped): `maintainRelayList`,
`maintainKeyPackage`, and a free fn `maintain_subscription_health()`.

**Two load-bearing MDK findings** (validated vs the PINNED rev `93ae324`, not the stale `e8cd584`
checkout) — both mean **MDK stays PRISTINE, we only call existing methods**:

1. **MDK has NO `existing_d_tag`.** Its `create_key_package_for_event_with_options` takes a BOOL
   (protected tag); `existing_d_tag`/`KeyPackageOptions` is a LATER rev (WN's). → Stable-`d`
   (MIP-00 #6) is achieved by `create_key_package_with_d` **overriding the kind-30443 event's Nostr
   `["d",<value>]` tag before signing** (a Nostr-addressing change only; the MLS KeyPackage content
   is untouched). No MDK pin change.
2. **MDK has NO live-material query.** → `MdkManager::has_live_key_material(hash_ref)` reaches
   OpenMLS `StorageProvider::key_package<KeyPackageRef,KeyPackage>` via MDK's PUBLIC field
   `pub provider` (mdk-core lib.rs:302). `Some` ⇒ live, `None` ⇒ dead. Requires a **direct
   `openmls = "0.8.1"` dep** (+ non-optional `openmls_traits`); `cargo tree -i openmls` MUST stay a
   single v0.8.1 unified with MDK's lock.

**Conservative live-material gate caveat (until M10):** MDK builds all KPs `last_resort` and Haven
never calls `delete_key_package_from_storage`, so a CONSUMED-but-not-deleted KP still reads LIVE at
this rev. The gate is therefore currently **conservative** — effectively equal to the "republish only
when NO KP is reachable" fallback. It becomes fully correct once **M10** adds KeyPackage deletion.
Owner decision (2026-07-03): **KEEP the openmls infra** (future-proof for M10) rather than simplify.

---

### Tasks B0–B3

#### B0 — Maintenance driver + FFI surface
- Dart `MaintenanceScheduler` `Notifier`: 3 jittered self-rescheduling timers, fire-on-start,
  cancel-all on dispose/logout, per-task no-overlap guard.
- Rust FFI (on `RelayManagerFfi`): `maintainRelayList(secretBytes)`,
  `maintainKeyPackage(secretBytes)`, `maintain_subscription_health()` (no secret). Each returns a
  small **presence-only** outcome enum/counter (never group-ids/URLs). FRB-regen after.

#### B1 — RelayListMaintenance (10050/10051) — engine-independent, ACTIVE
- Cadence 30m. For inbox (10050) + KeyPackage (10051) relay lists: **network-probe OWN configured
  relays** (per-relay, NOT a local-timestamp-only check — must detect relay-side drops). If
  missing/older, republish to **own configured relays only** via core `build_relay_list_event` +
  `dedup_relay_targets` (no default union), honoring the privacy toggle. `record_published_event`
  after.
- **Never NIP-65/kind 10002** — a deliberate Haven spec divergence (current Marmot spec uses 10002
  for KP discovery), documented as intentional, not "N/A".
- New DB: none (reuses `published_events`).
- Files: `relay/maintenance/relay_list.rs` (pure `decide_relay_list`), `relay/publishers.rs`,
  `api.rs`. FFI: `maintainRelayList(identitySecretBytes) -> RelayListMaintenanceOutcomeFfi`.

#### B2 — KeyPackageMaintenance — engine-independent, ACTIVE — full stable-`d` (owner choice)
The highest-value fix (audit #4: the "damus never sees my KeyPackage" reachability class).
- Cadence 10m.
- **Live-material gate (marmot CRITICAL — non-negotiable):** republish is gated on **live local MLS
  init-key material**, NOT relay presence. A relays-only check would republish DEAD KeyPackages
  (whose `init_key` was consumed by a Welcome and deleted locally) → breaks Welcome processing.
  Implemented via `has_live_key_material` (see Architecture; conservative until M10).
- **Republish when:** no live-material KeyPackage is reachable on own KeyPackage relays.
- **Stable `d` (full correctness):**
  - New minimal **`published_key_packages`** SQLCipher table recording per publish: `hash_ref`,
    `event_id`, `kind` (30443/443), `d_tag`, `created_at`. (Consumed/twin-GC lifecycle columns
    DEFERRED to M10.) File: `circle/storage_key_packages.rs`.
  - `create_key_package_with_d` overrides the 30443 Nostr `d` so a rotation **REPLACES the same
    NIP-33 addressable coordinate** instead of minting a new one.
  - **Seed `d` on first run:** probe own KP relays for an existing 30443, extract its `d`, seed
    `published_key_packages` BEFORE generating a new package — so stability holds from cycle 1. An
    **empty on-relay `d`** (malformed/hostile 30443) is NOT adopted as the slot (falls through to a
    fresh-`d` Republish).
- **Supersession:** rely on **NIP-33 same-`d` slot replacement** (authoritative). Do NOT emit a
  redundant id-only NIP-09 kind-5. Any NIP-09 delete (e.g. a legacy 443 twin) MUST use the
  **`a`-coordinate** + a **self-authorship guard** (event author == own pubkey).
- Publish-first-then-delete (never zero KPs on relays). Publish to **own KP relays only**.
- **Pure decision:** `decide_kp_maintenance(&RelayKpSnapshot, live_material_present,
  stored_stable_d) -> KpMaintenanceDecision {NoOp | SeedD | Republish{targets}}`;
  `build_kp_maintenance_events`; `build_legacy_twin_deletion` (a-coordinate + self-authorship guard,
  unit-tested but NOT yet wired into FFI — M10). Files: `relay/maintenance/key_package.rs`,
  `.../maintenance/mod.rs`, `nostr/mls/manager.rs` (`has_live_key_material`,
  `create_key_package_with_d`). FFI: `maintainKeyPackage(identitySecretBytes) ->
  KpMaintenanceOutcomeFfi`.
- **Login-KP tracking (M8-6 fix):** `sign_key_package_event` reuses the stored stable `d`
  (`latest_canonical_d_tag`) + returns `hash_ref`/`d`/event-ids; `record_published_key_packages`
  FFI + `key_package_provider.dart` records after a successful publish. Makes the first maintenance
  tick `AlreadyHealthy` and closes the across-login double-`d`-slot.

#### B3 — SubscriptionHealthCheck — engine-coupled, BUILDS INERT (gated)
- Cadence 15m. FFI reads `SESSION`; `None`/`!is_running()` → `Ok` no-op ("engine off"). Inert while
  `liveSyncEnabled=false`.
- **Default connectivity-only** (not group-count parity as primary): `LiveSyncCore::relay_health`
  counts `Disconnected|Terminated|Banned` (byte-exact mirror of nostr-relay-pool's `pub(crate)`
  `is_disconnected`); if any drop → call existing `resume_after_background()` (re-anchors every
  subscription at the persisted cursor, NIP-01 same-sub-id replace) else `Healthy`.
- **`SESSION` guard discipline (rust CRITICAL):** `live_session_core()` snapshots the `Arc` and
  DROPS the `std::sync` guard BEFORE any `.await` (mirror `api.rs:6068`), else `await_holding_lock`
  + `future_not_send` fail the `-D warnings` build and the task isn't `Send`.
- Accessors return counts / `nostr_group_id` only — never the real MLS group id.
- Files: `relay/live_sync/health.rs` (pure `health_needs_resubscribe` + presence-only
  `HealthAction`/`RelayHealthSnapshot`/`SubscriptionHealthOutcome`), `session.rs`, `live_sync/mod.rs`.
  FFI: free fn `maintain_subscription_health() -> SubscriptionHealthOutcomeFfi` (engine-off →
  `EngineOff`). Dart: `maintainSubscriptionHealth` forward (NO secret/circle) + scheduler's 3rd timer
  (always armed; FFI self-gates to `engineOff` until M11). No new deps (existing nostr-sdk
  `RelayStatus`).

#### Cross-cutting must-fixes (all tasks)
- **Own-relays-only** for every read (probe) AND write. No discovery-plane / cascade / NIP-65 fetch
  inside tasks (no-default-union test).
- **Logging = counts + outcome enums only.** `redact_hex_sequences` does NOT redact relay URLs →
  forbid logging relay URLs / per-relay ids (`wss://`/`ws://`-absence log test). Never raw KP hex /
  group-id / pubkey.
- **MDK pristine** (call existing methods only). No `unsafe`. Clippy pedantic+**nursery** clean.
- **Zero interaction** with the staged-commit/fork model or MLS epochs (maintenance never authors
  group commits; KeyPackages are pre-group init material).

---

### Sub-milestones M8-0..M8-6 (ordering)
- **M8-0** — Dart scheduler skeleton (3 timers, fire-on-start, cancel path) + 3 no-op FFI stubs +
  FRB regen. Pure infra; unit-testable.
- **M8-1** — B1 RelayListMaintenance Rust logic (own-relays probe + republish + record). Active.
- **M8-2** — B2 KeyPackageMaintenance: table + `create_key_package_with_d` + seed-d + live-material
  gate + republish-if-missing/dead. Active. **Highest value.**
- **M8-3** — B3 read-only `LiveSyncCore` accessor (only if parity mode chosen) — skipped
  (connectivity-only chosen).
- **M8-4** — B3 SubscriptionHealthCheck (connectivity-only + `resume_after_background`,
  `SESSION`-gated). Builds inert.
- **M8-5** — Dart wiring: real timers call real FFI; secret re-fetched per tick; cancel on logout.
- **M8-6** — Tests + clippy pedantic+nursery + coverage; then adversarial multi-agent QC.

M8-1 and M8-2 can land + flip active before M8-4 is complete.

---

### Tests / acceptance
- **Local (unit):** infra (fire-on-start, no-overlap, cancel breaks loop, fail-soft continues);
  stable-`d` (identical across two rotations via seed + `create_key_package_with_d`); live-material
  gate (dead KP NOT republished; missing KP republished); own-relays-only target (no default union);
  `wss://`-absence log test; self-authorship guard on NIP-09; empty-seed-`d` guard; B3 `SESSION`-off
  no-op + guard-dropped-before-await + 2 MockRelay e2e (healthy / resubscribe-when-down).
- **Device/relay (e2e, DEFERRED to M11-adjacent):** actual republish-if-missing against strfry;
  another peer fetches the refreshed KeyPackage.
- Clippy pedantic+nursery clean; coverage 80% Rust / 10% Flutter held.
- **Green as staged:** haven-core **861 lib + 5 MockRelay e2e**, rust_builder **22**, Flutter
  **1577/3**; clippy `-D warnings` + fmt clean; 0 analyze errors; no `dart format .` churn.

---

### Privacy / safety
No new metadata surface (own pubkey-visible 10050/10051/30443/443 to own relays; kind-5 only
self-authored, `a`-coordinate). Never kind 0/3, coordinates, names, real group-ids. Own-relays-only
(PSI-8) + redaction are the guardrails. No fork/epoch interaction. Secret zeroized per FFI call and
scrubbed in Dart `finally` (Rule 9). Presence-only counters cross FFI; per-relay `relay_url`-bearing
structs never cross FFI / never logged.

---

### Deferred to M10/M11
- **[M10] KP-lifecycle GC (audit #5/#13):** full `published_key_packages` consumed/twin-GC lifecycle;
  residual NIP-09-after-Welcome GC. Makes the live-material gate fully correct (adds KP deletion, so
  a consumed KP reads DEAD).
- **[M10] Legacy 443-twin GC:** every republish emits a fresh non-addressable 443 twin and nothing
  deletes old ones → unbounded accumulation on own relays. `build_legacy_twin_deletion` exists
  (unit-tested) but is NOT wired into the FFI republish (which inlines its own signing). Wire it or
  stop emitting the twin.
- **[M10] FFI-orchestration MockRelay test infra (medium — critic TC-1):** the per-relay e2e
  (`tests/maintenance_per_relay_e2e_test.rs`) is a hand-written MIRROR of the FFI — it does NOT call
  the real `maintain_*`/`republish_key_package`, so a bug in those FFI helpers passes green. Leaves
  TC-2 (publish-failure counting), TC-3 (newest-list `max_by_key`), TC-7 (`canonical_on_relays` sum)
  + the login-tracking `sign→record→maintainKeyPackage→AlreadyHealthy` e2e untested on the real path.
  Needs RelayManagerFfi + CircleManagerFfi + MockRelay infra in `rust_builder` (currently NO tests/
  dir, NO MockRelay dev-dep). Fold the two FFI-orchestration deferrals together at M10.
- **[M10] Cross-device / pre-tracking KP:** a valid live KP authored from ANOTHER device/session
  (same identity) or before tracking existed reads DEAD (`has_live_key_material` ≈ "event id locally
  tracked" at MDK 93ae324) → perpetual heal target until a SeedD→Republish re-seeds that relay. Out
  of scope; part of M10 KP-lifecycle work.
- **[M11] Health predicate `Initialized`/`Pending`:** `relay_health` counts only
  `Disconnected|Terminated|Banned`; a relay stuck `Initialized`/`Pending` (added, never connected)
  never triggers a re-anchor. Latent (inert until M11); decide semantics + add a test at M11.
- **[M11-gated, recorded]** M11 starvation test should cover the health-tick re-anchor path (settle-
  window Location starvation is a pre-existing M11 liveness gate, not introduced here); M11 rollout
  should empirically validate the pool's auto-reconnect before trusting the 15m backstop; an optional
  per-relay resubscribe primitive (vs the all-relays `resume_after_background`) only if M11 telemetry
  shows frequent health drops.
- **[low] Malformed configured-URL collapses the whole probe:** `fetch_events_per_relay` validates
  the WHOLE URL slice with `?` — one bad stored entry → probe `Err` → NoOp for ALL good relays that
  tick. Configured relays are validated on add (unlikely); pre-filtering to valid URLs would harden.
- **[low, deferred double-slot root fix]** have the login publisher also `record_published_key_package`
  its own `d` (so maintenance has `stored_stable_d` from cycle 1 regardless of timing). The causal
  await + M8-6 login tracking already close the common cases; a genuinely dead/missing KP has a
  bounded ~10m (SeedD → next tick → Republish) republish latency.
- **[pre-existing, noted]** `RelayManager::add_relays_and_connect` logs relay URLs at `log::debug!`
  (shared app-wide, 4+ callers, NOT M8-introduced, release-suppressed at `Warn`). Redact only if an
  app-wide "no relay URL in a log" invariant is enforced.
- **[accepted]** Some storage errors `?`-propagate to the FFI `Result<_,String>` unredacted — but
  Dart's Rule-8 `runtimeType`-only logging + best-effort maintenance (never shows `$e`) mean no leak.

Relay-audit coverage: M8 covers #4 (KP maintenance), #6-for-KPs (stable `d`), #11/#12 (periodic
relay-list/KP re-verify). DEFER → M10: #5, #13, #14 (`processed_gift_wraps` sentinel expiry), #15
(relay telemetry) — all hygiene, not reachability.

---

### Gotchas
- **NEVER run `dart format .`** (whole repo) — local Dart 3.10 tall-style vs the old committed style
  churns ~96 unrelated files (CI doesn't enforce format). Format only specific files / the
  FRB-generated ones. `scripts/regenerate_frb.sh` does NOT run `dart format .` (only echoes a
  reminder) — safe.
- **MDK stays PRISTINE** (rev `93ae324`); never fork/patch; `unsafe_code` denied. Stable-`d` and the
  live-material query both use existing public MDK surface only (Nostr `d`-tag override +
  `pub provider`).
- **Agent stability:** long-running Rust sub-agents can connection-drop or 600s-stall mid-response
  (both did this session, having done most of the work) — triage the working tree + complete/verify
  inline. Prefer tight-scoped agents or inline for moderate pieces.
- `cargo tree -i openmls` MUST stay a single **v0.8.1** (unified with MDK's lock).
- **Clippy:** the exact CI cmd `cargo clippy -- -D warnings` passes; the ~143 `--all-targets`
  failures are test-only lints CI does not run. Relay-URL-in-log findings are debug-build-only
  (release caps `log` to `Warn`).

---

### Changelog (condensed)

- **2026-07-03 — M8-2 / M8-1 Rust core + FFI (owner chose FULL stable-`d`).** Discovered the two
  MDK findings (no `existing_d_tag` → Nostr `d`-override; no live-material query → direct
  `openmls 0.8.1` via `pub provider`). FFI landed on `RelayManagerFfi` (not `CircleManagerFfi`). Live
  gate documented CONSERVATIVE until M10 KP-deletion.
- **2026-07-03 — M8-0 / M8-5 Dart scheduler, adversarial-QC'd (security/flutter/marmot).** Folded:
  - **Causal handoff (marmot MED):** the fixed 2m KP delay was only a *probabilistic* guard against a
    NIP-33 double-`d`-slot race (maintenance probing before the login `keyPackagePublisherProvider`
    publish lands mints a rival `d`). Fix: the first KP tick now `await`s
    `keyPackagePublisherProvider.future` (60s cap, best-effort) BEFORE probing → causal, not timed.
    2m delay is now just a settle.
  - **Generation fence (flutter CRIT):** empirically verified Riverpod REUSES the `NotifierProvider`
    instance across `invalidate`+re-read (one persistent root container). Without a fence, a stale
    in-flight tick's `finally` re-arms a timer for the superseded lifecycle → orphan + double loop.
    Fix: monotonic `_generation` counter gating both reschedule and post-`await` continuation.
    Regression test proven NON-VACUOUS.
  - Rejected flutter's "invalidate-AFTER-delete" (verified WORSE — leaves timers armed during the
    async delete; invalidate-before is safer).
- **2026-07-03 — M8-4 SubscriptionHealthCheck, 3-reviewer-QC'd (security/marmot/rust all clean).**
  Builds inert (2 gates: FFI `SESSION`-None + core `is_running`). Predicate byte-exact vs upstream
  `is_disconnected`; guard-drop-before-await holds (`Send`); zero MLS/epoch interaction. Folded:
  +2 MockRelay e2e for the `Resubscribed` healing branch (rust MED); `Sleeping`-omission doc.
- **2026-07-04 — M8-6 cross-cutting final adversarial QC (8-dim ultracode Workflow, 25 findings /
  4 refuted / 21 surviving).** Critic independently re-verified load-bearing invariants against real
  MDK `93ae324` + nostr-relay-pool 0.44. Verdict: SAFE to ship as staged. Folded:
  - **TOP (login KeyPackage untracked → live-material gate misread the healthy login KP as DEAD and
    force-rotated on cycle 1).** Fix: `sign_key_package_event` reuses the stored stable `d` + returns
    ids; `record_published_key_packages` FFI + `key_package_provider.dart` records post-publish
    (publish-first, best-effort). First tick now `AlreadyHealthy`; closes across-login double-slot.
  - **Cross-generation in-flight-flag race (flutter):** a stale tick's `finally` unconditionally
    cleared the flag → could clobber a fresh generation's no-overlap guard. Fix: gate the reset on
    `_isCurrent(generation)` (all 3 tasks). NON-VACUOUS regression test.
  - **`KeyPackageBundle` Debug leaked `d_tag` + `relays` (Rule 4/6)** — deeper than the finding
    named. Fix: redact `d_tag`, show `relay_count`; hand-written presence-only Debug for
    `KpMaintenanceEvents` + `SignedKeyPackageEventFfi`.
  - **Empty-seed-`d` guard:** `decide_kp_maintenance` no longer adopts an empty on-relay `d` as the
    slot → falls through to fresh-`d` Republish.
  - Refuted 2 false positives: "clippy fails codebase-wide" (only test-only `--all-targets` lints,
    not the CI cmd) and relay-URL-in-log (debug-build-only, release `Warn`).
- **2026-07-04 — Per-relay probe (deferred #37), full design→confirm→implement→QC cycle.** Defect:
  both `maintain_key_package` + `maintain_relay_list_category` used an AGGREGATE `fetch_events`
  (merges across own relays) → a PARTIAL relay-side drop was missed (NoOp) → user undiscoverable on
  the dropped relay. Fix: both use `fetch_events_per_relay`, build RESPONDERS-ONLY snapshots, and
  republish ONLY to responded-but-unhealthy own relays (`Republish{targets}`; all-non-responding →
  NoOp fail-closed). Folded:
  - **PC-1 (real bug the design missed, MED):** `republish_key_package` built KP CONTENT (MIP-00
    `relays` tag) from the SUBSET `targets`, so a healed 30443 advertised only the subset (redundancy
    loss for inviters). Fix: content = FULL own KP relay set, target = subset. Security-reviewer
    confirmed the fix.
  - `first_d`→`min_d` (deterministic `pick_seed_d`); `responded`-semantic documented BENIGN +
    self-limiting (transiently-pooled `Disconnected` reads `responded=true`+empty → a benign heal
    attempt tallied in `relay_errors`). Security review CLEAN (`targets ⊆ configured ⊆ own`
    structural).
