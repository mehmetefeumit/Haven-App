# Stage 2 — Haven onto `AccountDeviceRuntime`, piece by piece

Part of the MDK v0.10.4 → v0.16.0 migration (master sequence steps 21–29 in
[`docs/MDK_V016_MIGRATION_PLAN.md`](../MDK_V016_MIGRATION_PLAN.md) §4; sibling parts
[`stage0.md`](stage0.md), [`stage1a_nostr.md`](stage1a_nostr.md), [`stage1b_mdk.md`](stage1b_mdk.md), all in
`docs/mdk-v0.16/`). Stage 1 ships Haven on MDK v0.16.0
with its own fanout driver reaching the now-private `AccountDeviceSession` through `marmot-session/test-support`,
recorded as tracker row **`T-SESSION-PRIVATE`** and held by `scripts/ci/check_private_session_exception.sh`.
Stage 2 moves Haven onto MDK's public `AccountDeviceRuntime` until no non-dev dependency edge of a shipped root
enables `test-support` (owner decision D1), accepting the runtime's behaviour wherever a Haven policy cannot be
expressed through its public surface and host seams (owner decision D2, "concede to finish").

Conventions.

- MDK citations are at tag v0.16.0 (`a2e0558a`): `RT` = `crates/marmot-session/src/runtime.rs`,
  `RT/x.rs` = `crates/marmot-session/src/runtime/x.rs`, `SS` = `crates/marmot-session/src/session.rs`,
  `TA` = `crates/traits/src/transport_adapter.rs`, `ENG/` = `crates/cgka-engine/src/`. Haven paths are
  repository-relative at `cb3b9a6`; `API` = `haven/rust_builder/src/api.rs`.
- `UNVERIFIED` = not confirmed in code; never a guess stated as fact. Every effort, build-time and line-count
  figure is ESTIMATED (build-cycle durations are measured; the counts of cycles are not).
  Counts derived from source constants are marked COMPUTED. No battery figure appears in this part; where an
  energy effect exists it is named, not quantified (model E, `docs/POWER_EFFICIENCY_PLAN.md` §6.5a, has no
  figure for it), so nothing here can be read as a measurement (`scripts/ci/check_estimate_integrity.sh`).
- A "merge" is a green, pushed commit series at a sub-stage boundary, ready for the owner to merge to `main`.

---

## 0. Three rulings the owner gives before Stage 2 starts (master step 21)

Stage 0 and Stage 1 do not wait for these. Stage 2.0 does.

### 0.1 R0 — may Haven's transport adapter decline to send, while reporting the truth about the wire?

**Question.** Most of Haven's send policy (expiry, single attempt, removal floor, `min(2,n)`, 24 h end, pacing,
finish-only, wake budgets) can be kept without editing any MDK record by having Haven's own `TransportAdapter`
decline an attempt and report what really happened at its boundary. MDK's vocabulary supports it:
`NotExposed` = "the adapter proved that no send attempt crossed its external boundary" (`TA:1147-1148`), terminal
(`TA:690-695`), and MDK itself uses it for an adapter-side policy refusal (`over_known_limit`, `TA:1183-1191`);
`RetryableUnavailable` = "a pre-send connectivity/resource failure … without claiming exposure" (`TA:1153-1156`).
The runtime still owns every record, transition, confirm and rollback. The ruling is needed because the adapter
then decides *whether* to dial, not only *what happened*.

**The proof that keeps R0 honest (Rule 13.3).** The adapter's verdict for an endpoint is built only from these
facts, in this order:

1. **Not crossed.** The adapter never called the verified client's send for this event on this endpoint in
   this attempt → `NotExposed` (policy refusal) or `RetryableUnavailable` (closed window, pacing, wake budget).
   The crossing point is the call into the client, recorded durably in the crossings ledger first (§A.2).
2. **Crossed, relay spoke.** Before the send, the adapter takes the relay's gap-reporting notification stream
   (`notifications_with_gaps()`, eager subscription; the Stage 1a §D.1 listener). A verdict other than
   `PossiblyExposed` requires an `OK` frame **for this event id, from this relay, heard on that stream with no
   gap** (no `Lagged`, stream not ended): `OK true` or `duplicate:` → accepted; `OK false` with `rate-limited:`
   → `RetryableUnavailable`; any other `OK false` → `TerminalRejected` (with the `TooLarge` category for a
   size refusal).
3. **Crossed, anything else** → `PossiblyExposed`: a timeout, a socket cut, a gap, an input pre-emption after
   crossing, an entry in the client's `output.failed` map, and **every error carrying the fork's
   `ErrorKind::Rejected`** — the fork produces that kind locally too (`connection_rejected`, `rejected_msg`,
   "authentication rejected", `nostr-sdk/src/error.rs:186-215`, `relay/inner.rs:1966-1970` at fork `e93cc06b`).
   No error kind, no `failed` string and no prefix-looking text is ever a refusal.

This is made structural, not conventional: `H/relay/runtime_adapter.rs` classifies a `WireVerdict`
(`NotCrossed(reason) | Heard { ok, prefix } | Unheard`) whose `Heard` arm only the frame reader constructs; the
`TerminalRejected` and `RetryableUnavailable`-after-crossing arms match `Heard` only. A source guard bans
`ErrorKind::Rejected`, `.failed` and `is_rejected` in the adapter file. Pinning tests (scripted relay,
paused time): `runtime_adapter::a_local_rejected_error_after_crossing_is_possibly_exposed`,
`…a_lagged_listener_after_crossing_is_possibly_exposed`, `…an_ok_false_for_another_event_id_proves_nothing`,
`…a_socket_cut_after_crossing_is_possibly_exposed`,
`…a_commit_is_rolled_back_only_when_every_target_was_heard_to_refuse_it`. The `reason` string is always fixed
Haven text, never relay text, a URL or an id (Rule 15).

**Recommendation: R0 = yes.** It is MDK's own documented vocabulary used as documented, and the proof above is
the one Stage 1 already ships. **If R0 = no:** every KEPT-IN-SEAM row of §B.2 becomes CONCEDED with the cost
stated in its row, and C3 becomes HIGH (a relay set that refuses every target can fork this device off its
circle): sub-stage 2.2 then waits for upstream ask U6.

### 0.2 C1 — a location fanout that can never end, and freezes its circle (HIGH)

- **Scenario.** A location (kind-445 application message) whose first attempt is possibly exposed on every
  relay of its circle and acknowledged by none: the device loses network between handing the event to the
  socket and reading `OK`, and stays off longer than the 228 s NIP-40 lifetime; or a relay withholds `OK`.
- **Who can trigger it.** Ordinary mobile network loss; at will, any relay that is the only one answering for a
  circle.
- **Harm.** The runtime keeps a once-possibly-exposed target outstanding whatever answer follows
  (`TA:684-688`), deletes an application fanout only when complete (`RT:5958-5963`, `RT:4510-4519`), and has no
  expiry in its drive (expiry appears only on its Welcome and KeyPackage paths). The record is a **permanent
  per-circle barrier**: queued changes of that circle are never drained (`RT:4077-4092` → `RT:3910-3921`), and
  every later fanout of the circle — a removal commit whose first `OK` was lost included — is never retried by
  `resume` (`RT:4569-4585`), so that commit stays `PendingPublish` and the circle is frozen both ways until the
  app is reinstalled. Rows grow by up to one per sealed location of the affected circle. Confirmed against
  source at the lines cited.
- **Options.**
  (a) **Hold sub-stage 2.4** (locations onto the runtime) until upstream ask **U1** is in a released MDK tag.
  (b) **Keep one named exception call site** meanwhile: the location seal (`SessionManager::seal_location`,
  through the single `private_session()` choke point, §C.0) with Haven's own location ledger and driver
  (`location_sends`, 2.2a). Stage 2 then exits at 2.5 with exactly that one recorded entry, and
  `marmot-session/test-support` stays on haven-core's normal edge for it — D1's end state is not met until U1.
  (c) **Accept C1**: 2.4 proceeds; the wedge ships as a recorded HIGH; the pinning test
  `location_fanout_e2e::an_application_fanout_ends_at_its_expiration_and_never_blocks` is deleted, and the only
  test of the new behaviour would pin a defect.
- **Recommendation: do not concede — (a) with (b).** Every other sub-stage merges meanwhile (§C).

### 0.3 C2 — a withdrawn own removal silently re-issued (HIGH)

- **Scenario.** Two admins race on one circle; the winning branch removes and re-invites a member, or invites
  one back later; this device reconciles afterwards (possibly days later, offline).
- **Who can trigger it.** Any two admins acting concurrently; T-REISSUE measured such races.
- **Harm.** The runtime re-issues every superseded own commit on every publish batch (`RT:4773-4810`, called
  from `RT:3766`, `:4367`, `:4606`) and from stored state at every maintenance pass (`RT:4847-4868`, `:2554`);
  the engine keeps every named member still on the roster **by member id** (`ENG/own_commit_intent.rs:227-240`),
  and a member invited back has the same id. This device then removes a member another admin chose to keep,
  unattended; the user learns afterwards (`AccountDeviceEffects.superseded_intents`, `RT:7285-7289`). Neither
  the runtime nor the session has a method that takes back a re-queued intent (`SS` and `RT` public methods,
  checked), so owner decision 233 ("offered to the user, never re-issued silently") is lost. Confirmed against
  source at the lines cited.
- **Options.**
  (a) **Hold sub-stage 2.2** (the flip) until upstream ask **U2** is in a released MDK tag. 2.0, 2.1 and 2.2a
  ship; 2.2–2.5 wait; `T-SESSION-PRIVATE` stays at its post-2.1 size (Haven's whole fanout driver on the
  private session).
  (b) **A named exception call site: not available.** The re-issue happens inside the runtime's own publish
  path and maintenance pass, which 2.2 hands over wholesale; no exception site can stop it. Refusing "unknown"
  commits in the adapter was rejected: the adapter sees ciphertext, cannot tell a re-issued removal from the
  runtime's other legitimate commits, and each refusal ends in a rollback the runtime re-issues at the next
  batch.
  (c) **Accept C2**: Haven surfaces every `SupersededIntentReport` of kind `RemoveMembers` as a fixed-copy
  notice written before the call returns (row C2 in §B.1).
- **Recommendation: do not concede — (a).** The price is stated plainly: under (a) the migration stops after
  2.2a until U2 ships. If the owner judges that price too high, (c) is the only other honest choice.

---

## A. Target architecture

### A.1 One runtime, one lock (Rule 14)

```
SessionManager                                   (haven-core/src/nostr/mls/manager.rs, rewritten)
 └─ Gated<HavenRuntime>                          (haven-core/src/nostr/mls/engine_gate.rs, same shape)
     HavenRuntime = AccountDeviceRuntime<HavenAdapter, HavenRouting, HavenKeyPackages>
 └─ message_store: SqliteAccountStorage          (clone of the engine's connection)
 └─ _live_guard: LiveSessionGuard                (unchanged: one live session per DB file, process-wide)
 └─ window: SendWindow, pressure: InputPressure  (shared with HavenAdapter, §A.4)
```

- **Opening, on every opener** — every `CircleManagerFfi::new` caller, all through `SessionManager::new*`: the
  foreground app and the background openers Stage 1b §9.3 names (the WorkManager catch-up worker, the Android
  foreground-service work, the iOS burst); a background opener Stage 1b's generation gate declines opens
  nothing: `sqlcipher_init::ensure()`; Haven opens `SqliteAccountStorage`; the pre-open pass
  runs on it (T-STALE-FANOUT, T-KILL-WINDOW, `cleared_at_open`, and from 2.2a the **location-row retirement
  step**, §C.2a); Haven clones it for `message_store` and hands it to
  `SessionConfig::with_storage(storage, opened_in, identity, peeler)` (`SS:164-178`), then
  `AccountDeviceRuntime::open(config, || Ok((adapter, routing, publisher)))` (`RT:577-587`), which opens the
  session, builds the transport and drives nothing (`RT:596-631`). One connection serves engine and
  second-handle writes; a Haven write can never land inside an engine transaction
  (`with_transaction` takes a synchronous closure, `storage-sqlite/src/base/connection.rs:735-790`), and that the
  shared connection serialises Haven's off-gate reads behind engine transactions (measured by D.3).
- **The lock.** The runtime owns the session by value; every mutating method takes `&mut self`. Haven keeps its
  tokio `Mutex` inside `Gated`; every FFI call, receive plane, catch-up sweep, KeyPackage tick and background
  burst reaches the runtime only through `SessionManager`. `Gated::engine` keeps finishing owed rollback
  retirements before handing out `&mut` (T-ROLLBACK-RESURRECT), keyed on `PendingResolution::RolledBack` and
  `PublishFailure.message_id` (`RT:7264`, `RT:7290`).
- **Never drop a runtime future.** Cancel-safety between engine steps is UNVERIFIED; every call is bounded
  through the adapter (§A.4), never by dropping it. A guard bans `select!`/`timeout` around a runtime call in
  `SessionManager`.

### A.2 `HavenAdapter: TransportAdapter` (`TA:1421-1476`)

One type in `haven-core/src/relay/runtime_adapter.rs`, over the existing verified publish client
(`relay::verified::verified_client`, Rule 16; no signer, no NIP-42), the per-relay gate, and a durable Haven
ledger in the circle store: *crossings* `(event id, endpoint, crossed_at, acked)`, the removal-commit ids Haven
staged, and the per-circle removal epoch floor.

| Trait method | When the runtime calls it | Haven's answer |
|---|---|---|
| `activate_account`, `sync_account_groups` | only from host-called `activate_transport` / `sync_transport_groups` (`RT:1212-1260`) | Haven calls neither (guard); `Ok(())`, counted; a canary asserts the count stays 0 |
| `deactivate_account` | never | `Ok(())`, counted |
| `receive` | never | `Err(Other("not served"))`, fixed text, counted; Haven's receive planes feed `ingest_delivery` |
| `publish(request)` | frozen group fanouts, one single-endpoint request per due target (`RT:5718-5800`); Welcome publishes (`RT:6026-6032`) | §A.3 pipeline; exactly one receipt or failure per endpoint |
| `size_class_over_known_limits` | before staging an invite (`RT:3695-3730`, `:7112`) | Haven's own constants only. It judges event sizes against relay limits; the pre-fork NIP-44 ceiling of owner item O13 is enforced by the Welcome signer, not here (`T-NIP44-WELCOME-CEILING`, row C28). **No NIP-11 fetch** (none exists in Haven today; the adapter file may import no HTTP client — guard) |

`WelcomeSizeCheck::oversized_welcome` (`TA:1481-1485`), consulted for a founding create before the engine writes
anything, gives the same answer.

### A.3 The publish pipeline (per endpoint; every verdict per §0.1)

1. **Shape.** Decode the signed event. Only kinds 445 and 1059 are sent; anything else → `NotExposed`.
2. **URL policy.** `url_norm::may_dial`; for a group target also `foreign_relay_dialable` → else `NotExposed`.
3. **Window** (§A.4). Closed → `RetryableUnavailable`. Background and the event never crossed to any endpoint →
   `RetryableUnavailable` (finish-only, C5a). Past the wake's deadline → `RetryableUnavailable`.
4. **Application message** (the only events carrying NIP-40 `expiration` in Haven): within `LOCATION_SEND_MS`
   of expiry (`haven-core/src/relay/fanout.rs:2741`) → `NotExposed`; already crossed to this endpoint →
   `NotExposed` (single attempt); sealed below the circle's removal epoch floor → `NotExposed`.
5. **Commit end.** Confirmed commit with ≥ `min(2,n)` acknowledgements, or older than 24 h, never crossed to this
   endpoint → `NotExposed`; pending non-removal commit older than 24 h, never crossed to this endpoint →
   `NotExposed` (when every target ends so, the runtime rolls back on proof, `RT:5986-5995`).
6. **Pacing.** Per-relay cooldown across rows, `rate-limited:` back-off, Haven's unavailable ladder
   (`haven-core/src/relay/fanout.rs:947-970`) → `RetryableUnavailable`.
7. **Cross.** Take the gap-reporting stream; write the crossing durably; call the client's send.
8. **Await** `OK` for `min(ATTEMPT_CEILING, wake deadline)`, racing input pressure (§A.4).
9. **Classify** strictly per §0.1. The T-CLOCK-SKEW verdict is read from the heard frame and recorded on a side
   channel (`ResumeOutcomeFfi.clock_rejected`, `API:8059`).

### A.4 Send windows and input pressure

- `SendWindow` is set by `SessionManager` under the lock: **Closed** during `ingest_delivery` and
  `advance_convergence`; **Drive{foreground, deadline}** during `drain`, `resume_outbound_fanouts`, `send*`,
  `publish_prepared_session_effects_with_audit_context`, `rollback_prepared_session_commit`,
  `run_due_maintenance`, `deliver_owed_welcomes_with_audit_context` and the KeyPackage entries.
- **No relay I/O inside ingest or convergence.** Ingest publishes the batch's effects inline (`RT:4327-4335`)
  and advance resumes the group's fanouts first (`RT:3907-3924`); with the window closed nothing crosses, the
  records stay outstanding with no exposure claimed, and the next drive sends them.
- **No rollback inside a call that then runs a pass** (C3). `advance_convergence` can roll back and then run a
  pass in the same call (`RT:3907-3924`), and a rolled-back commit's own row is still a graph input
  (`ENG/openmls_projection.rs:3466-3482`). With the window closed no target of that call ends terminal; rollbacks
  happen only in drive calls, which run no pass (`RT:4246-4252`), and Haven retires the row before releasing
  the lock.
- **Due-before-advance.** Before `advance_convergence(g)`, if `outbound_fanout_retry_delay_ms(g)` (`RT:4117`)
  is `Some(0)`, Haven drives `g` first under the same lock.
- **Input pressure.** `InputPressure` counts FFI callers waiting for the lock on behalf of user input (a tap that
  changes something, or a screen read). While non-zero the adapter refuses new attempts
  (`RetryableUnavailable`), ends uncrossed in-flight attempts (`RetryableUnavailable`), and gives crossed ones
  `PREEMPT_GRACE` (proposed 250 ms) for their `OK`, then ends them `PossiblyExposed` (never a rollback).
  `advance_convergence` also receives the same signal as the runtime's own yield
  (`advance_convergence_with_publication_progress_and_yield`, `RT:3876-3891`).
- **Bound:** a drive holds the lock for engine time plus at most `ATTEMPT_CEILING` with no input waiting, and
  engine time plus `PREEMPT_GRACE` once input waits (gate M3).

### A.5 `HavenRouting: TransportRoutingPolicy` (`crates/marmot-session/src/routing.rs:9-19`)

Synchronous `&self` methods over an `Arc<RwLock<RoutingCache>>`, refreshed inside the same lock hold after open
and after every runtime call that can change routing (routing-component change, rotation, join, leave).
`local_inbox_endpoints` = kind-10050 list; `key_package_endpoints` = the stored NIP-65 list Haven's kind 10002 is
built from, `may_dial`-filtered; `publish_target(GroupMessage)` = the circle's relays from the routing component
of the epoch the commit **leaves**, filtered by `foreign_relay_dialable`, de-duplicated on the parsed URL, empty →
`Err(MissingGroupRoute)` (the runtime rolls back the unstaged commit, `RT:5543-5554`);
`publish_target(Welcome)` = the invitee's inbox relays as fetched for the invite (discovery fallback);
`required_acks` = 1 (Rule 13.2). The discovery and profile planes never touch the runtime.

### A.6 `HavenKeyPackages: KeyPackagePublisher` — isolated because provisional

Upstream calls the boundary provisional (`crates/marmot-session/README.md`, "Routing model"), so the impl lives
alone in `haven-core/src/relay/key_package_publisher.rs`; no other file names the trait. `legacy_slot_id` = the
`d` slot Haven's lifecycle row holds (so no second slot is minted); `prepare_key_package` = the kind-30443
template from MDK's `NostrKeyPackagePublication`, signed once by the identity key; `publish_prepared_key_package`
= the exact bytes through §A.3 steps 2 and 6–9 (`unexposed` before crossing, `exposed` after);
`withdraw_key_package_slot` / `delete_key_package_event` = identity-signed kind-5 deletions.

### A.7 Clocks, randomness, timing, pause

- `with_maintenance_sources(wall, monotonic, random)` (`RT:641-652`) and `SessionConfig::maintenance_sources`
  (`SS:275-281`) receive **the same** `HavenClock`/`HavenRandom`. Runtime time decisions are then injectable;
  the engine's convergence budgets still read `Instant::now()` (`ENG/message_processor/mod.rs:1322`, `:1920`) —
  T-CONVERGENCE-CLOCK stays (U14).
- `MaintenanceTiming::default()` in production; `immediate()` only in tests (guard: `with_maintenance_timing(`
  outside tests).
- Maintenance is **paused** for every background tick and while an invitation is held unanswered (C11);
  resumed on a foreground claim with none held. Paused maintenance still finishes prepared publications and
  prepares no new private material (`RT:2597`, `RT:2634`).
- `set_periodic_maintenance_policy` is never called (guard).

### A.8 Fate of `SessionManager`'s responsibilities

| Responsibility | Where it goes |
|---|---|
| Rule 14 single live session; engine gate | stays, wrapping the runtime |
| Pre-open pass (stale rows, kill-window repair, `cleared_at_open`) | stays; plus the location-row retirement step (2.2a) |
| Second handle | stays, shrinks (queued-location discard, expired-bundle delete, lost-Welcome end go) |
| Ingest screening, `order_for_ingest`, unread-input holds, refused ledger, cursor (Rule 12) | stays above the runtime; the engine call becomes `ingest_delivery` (`RT:4258-4277`) |
| Convergence scheduling, epoch-stall detector, parked passes | stays (T-SCHEDULER, T-EPOCH-STALL), calling `advance_convergence`; adds `convergence_pass_parked` / `retry_failed_convergence_pass` |
| Fanout driver, Welcome outbox, re-issue/re-queue, too-large refusal (`relay/fanout.rs`, `manager.rs:4466-9090`) | deleted in 2.2 → runtime + adapter + routing |
| KeyPackage lifecycle (`manager.rs:12132-12500`, `relay/maintenance/key_package.rs`, `kp_lifetime.rs`) | deleted in 2.1 → runtime + `HavenKeyPackages`; Haven keeps the tick and the hold |
| Post-join/self-update driver (T-MAINT-DRIVER) | deleted in 2.3 → `run_due_maintenance`; Haven keeps the 24 h repair via `schedule_manual_self_update` (`RT:2247`) |
| Change notes, Welcome preview/accept, UI reads | stay, fed from `AccountDeviceEffects` / runtime reads |
| Location seal/send | 2.2a Haven ledger; 2.4 `send(AppMessage{expected_epoch: Some(pin)})` or, under C1 option (b), the one exception site |
| Test fault hooks (`manager.rs:5282-5381`, `:9137`) | deleted with the driver; faults move into a scripted `HavenAdapter` and injected clocks |

`RecoveryCause`/`SendHeld` move to `haven-core/src/relay/circle_hold.rs`, rebuilt over runtime reads
(`has_pending_outbound_fanouts` `RT:4094`, `queued_outbound_intents_blocked_by_fanouts` `RT:4077`,
`leave_in_progress` `RT:1135`, `undelivered_commit` `RT:3952`) and the engine's typed `AppMessageEpochUnsettled`.

### A.9 Haven's own stores

- **No Haven store references an MDK-internal id or encoding that changes.** Haven's circle store holds only
  stable ids: MLS group id, `nostr_group_id`, transport event ids, gift-wrap ids, absolute epochs; no
  `PendingStateRef`, no MDK table name, no KeyPackage ref (`haven-core/src/circle/storage.rs:1203-1370`). Stage 2's new Haven tables (crossings ledger, removal-commit
  ids, removal epoch floor, `location_sends`, the retirement marker) key on event ids and group ids only.
- **The two databases cannot commit atomically.** Every step that touches both is ordered so a crash falls on
  the safe side and a re-run is harmless:

| Step | Order | Crash between the two writes |
|---|---|---|
| Adapter crossing | crossing row (circle store) before bytes; the runtime's record (session DB) already marks the attempt | over-claims exposure, never under-claims; a re-attempt answers per §A.3 |
| Location-row retirement (2.2a) | delete MDK rows, then write the marker after the open and before the first drive | the step re-runs; no runtime-written application row can exist before the first drive (pinned) |
| `location_sends` drop (2.4) | `DROP TABLE IF EXISTS` in the pre-open pass | re-runs as a no-op |
| Removal epoch floor | written after the removal's confirm effects are folded | a lower floor for one call; locations sealed before it are still refused on resend by the single-attempt rule |

---

## B. The concession list (D2)

Read §0 first. Groups: **KEPT-IN-SEAM** (kept through Haven's adapter, routing or windows; needs R0 = yes),
**KEPT ANOTHER WAY** (kept through an on-label public API; independent of R0), **CONCEDED** (the runtime's
behaviour replaces Haven's), **CHANGED — MDK WINS** (spec- or MDK-aligned, not a lost guarantee). Every cost is
ESTIMATED unless marked COMPUTED; each names the §D gate that measures it before the sub-stage merges. "If
R0 = no" is stated per row in B.2 and is "no effect" for every other group.

### B.1 HIGH rows awaiting the owner (§0.2, §0.3)

| ID | Old guarantee (pinning test) | New behaviour | User-visible effect | Cost | Text that changes | Test pinning the new behaviour | Upstream ask |
|---|---|---|---|---|---|---|---|
| **C1** | A location's record ends at its expiration and never blocks (CLAUDE.md kind-445 row; `location_fanout_e2e::an_application_fanout_ends_at_its_expiration_and_never_blocks`, `…a_completed_location_send_is_never_retried_and_costs_two_writes`) | §0.2 (`TA:684-688`, `RT:5958-5963`, `RT:4077-4092`, `RT:4569-4585`) | if accepted: a circle whose location `OK`s were all lost across an outage > 228 s can never again make a change, and a later commit whose `OK` is lost is never retried | rows: unbounded, ≤ 1 per sealed location of an affected circle; liveness: permanent wedge (gates M6, M7) | if accepted: CLAUDE.md kind-445 row, Rule 13 preamble, `haven-core/SECURITY.md:489` | none acceptable; if accepted, `location_fanout_e2e::a_location_whose_acknowledgements_were_all_lost_past_its_expiry_stays_recorded`, labelled as pinning a defect | **U1** → new row T-APP-FANOUT-END |
| **C2** | A withdrawn own removal is offered to the user, never re-issued silently (decision 233; `haven-core/SECURITY.md:1071`, `:1151`; `reissue_e2e::a_fresh_own_removal_that_loses_to_a_removal_and_an_invite_back_is_dropped_and_held`, `requeue_e2e::an_own_removal_that_loses_to_a_removal_and_an_invite_back_is_not_made_again`) | §0.3 (`RT:4773-4810`, `RT:4847-4868`, `ENG/own_commit_intent.rs:227-240`) | if accepted: a member another admin invited back can be removed again by this device unasked; the user is told in the same call | integrity: a membership change against another admin's later decision; no extra relay traffic | if accepted: T-REISSUE deviations (1)–(8); decisions 233/238; SECURITY.md `:1071`, `:1151` | if accepted: `reissue_e2e::a_withdrawn_removal_is_reissued_by_the_runtime_and_the_user_is_told_in_the_same_call` (notice written before return; re-issue is the runtime's) | **U2** → rewrite T-REISSUE |

**C22** (decision 238: nothing sealed while a removal is held unmade, `SendHeld::RemovalUnmade`, `API:7398`)
follows C2: kept while C2 is not conceded (2.2 is held), deleted with `RemovalUnmade` if C2 is accepted.

### B.2 KEPT-IN-SEAM (11 rows; each needs R0 = yes)

| ID | Old guarantee (pinning test) | New behaviour (runtime; Haven's seam) | User-visible effect | Cost | Text that changes | New pinning test | Upstream ask | If R0 = no |
|---|---|---|---|---|---|---|---|---|
| C1a | A location is sent once per relay and never past its `expiration` (kind-445 row) | runtime retries app fanouts with no expiry; adapter refuses near expiry and after one crossing (§A.3 step 4) | none | none on the wire | kind-445 row: "sent by the runtime through Haven's adapter, …" | `location_fanout_e2e::a_location_is_never_sent_past_its_expiration_by_the_runtime` | U1 | CONCEDED: resends of expired locations (relays answer per UNVERIFIED `duplicate:`/`invalid:`), plus C1 |
| C3 | A rolled-back commit is never merged by a later pass on this device alone (T-ROLLBACK-RESURRECT; Rule 13.3; `publish_failed_rewind_e2e`) | runtime rolls back in `drive_outbound_fanout` (`RT:5986-5995`) and may pass in the same `advance_convergence` call (`RT:3907-3924`); closed window in advances + retirement under the lock (§A.4) | none | none | T-ROLLBACK-RESURRECT mechanism text | `rollback_e2e::a_commit_the_runtime_rolled_back_is_never_merged_by_its_next_pass` (fails with Haven's retirement disabled) | U6 | **HIGH**: 2.2 waits for U6 |
| C4a | Relay I/O never under the engine lock; input is never made to wait on a relay (responsiveness pillar; T-FANOUT (32); `live_plane_drive_e2e`, `poll_send_drive_e2e`) | `drive_outbound_fanout` awaits `adapter.publish` under `&mut self` (`RT:5747-5800`); windows keep ingest/advance relay-free, pressure pre-empts drives (§A.4) | a tap or read mid-drive waits ≤ `PREEMPT_GRACE` + one engine step | latency ≤ 250 ms + engine step with input (M3, M9); a commit cut by input is retried after ≥ 30 s (`RT:123`), confirm latency +30 s then (M5) | T-FANOUT (32) | `responsiveness_e2e::input_during_a_publish_takes_effect_before_the_relay_answers` (§D.3) | U4 → T-LOCK-HELD-IO | CONCEDED: input waits up to `ATTEMPT_CEILING` (20 s today, `relay/fanout.rs:180`) — breaks the responsiveness pillar: STOP and ask |
| C5a | Finish-only background: no first transmission, no rollback (`haven-core/SECURITY.md:1586-1620`, `:1782`, `:1971`; `finish_only_e2e::a_finish_only_call_makes_no_first_transmission_to_any_relay`, `…never_rolls_back_whatever_the_relays_prove`) | a resumed `NotAttempted` target is a first transmission (`RT:6757`); adapter refuses first transmissions in background and never answers terminal there | none | none | SECURITY.md finish-only paragraphs name the adapter | both tests re-pointed at the adapter | U5 | CONCEDED: background bursts make first transmissions and may roll back |
| C7a | OD-2 wire: no relay dialled after `min(2,n)` acks; an applied commit's retries end at 24 h (Rule 13 preamble; `fanout_end_e2e`) | runtime ends a fanout only when every target is terminal (`RT:5954-5963`), no age bound for group fanouts; adapter stops dialling (§A.3 step 5) | none | none on the wire | Rule 13 preamble names the adapter | `fanout_end_e2e::after_two_acknowledgements_no_relay_is_dialled_again_and_a_straggler_record_stays` | U3 | CONCEDED: stragglers redialled up to hourly for ever (M1, M5) |
| C8 | 24 h undo of a never-exposed pending commit, never a removal (Rule 13 preamble) | no bound in runtime (`RT:6770-6777`); adapter answers `NotExposed` after 24 h for a never-crossed target of a pending non-removal commit; runtime rolls back on proof | none | none | Rule 13 preamble | `fanout_end_e2e::a_never_exposed_change_is_undone_by_the_runtime_after_a_day_and_a_removal_never_is` | U3 | CONCEDED: a never-sent change stays pending until a relay answers |
| C17a | Welcome pacing and bounds (T-WELCOME-OUTBOX) | runtime re-drives watched Welcomes every pass (`RT/welcome_delivery.rs:547`), 24 h retention (`RT:117`, `:6223`); adapter paces | none | none | kind-444 row: "sent only by the runtime, through Haven's adapter" | `welcome_outcomes_e2e::a_welcome_is_redriven_no_faster_than_havens_pacing` | — | CONCEDED: MDK's 5 s flat retry per Welcome target |
| C18 | Retry cadence: unavailable ladder, `rate-limited:` back-off with jitter, per-relay pacing across rows (`relay/fanout.rs:947-970`) | per target per row: 5 s flat for `RetryableUnavailable`, 30 s doubling to 1 h for `PossiblyExposed` (`RT:6749-6780`); adapter enforces Haven's pacing (MDK precedent `crates/transport-nostr-adapter/src/sdk_client.rs:4785-4801`) | none | attempt counters count local refusals, so back-off reaches 1 h after fewer real sends (M5) | T-FANOUT pacing; T-ADAPTER-ATTEMPTS | `fanout_transport_matrix::a_rate_limited_relay_is_not_dialled_before_its_cooldown_across_rows` | U13 | CONCEDED: MDK's cadence, more dials to a rate-limiting relay (M1, M5) |
| C19a | Wake budgets: no call waits past its wake's deadline (T-FANOUT (21)) | runtime has no deadline; adapter answers `RetryableUnavailable` past it and bounds each attempt by it | none | none | T-FANOUT (21) | `finish_only_e2e::a_wake_never_waits_past_its_deadline_on_the_runtime` (paused time) | U13 | CONCEDED: a burst can overrun its OS budget (iOS reclaim) |
| C24a | A location sealed before a removal is never sent after it (`location_fanout_e2e::a_location_sealed_before_a_removal_is_never_sent_after_it`) | old record retried after the removal; adapter refuses below the removal epoch floor | none | none | none | same test, re-pointed at the adapter | U1 | CONCEDED: a pre-removal location can reach relays after the removal (the removed member cannot decrypt it; metadata only) |
| C25a | A location another process left unfinished is never sent by this one (`…a_location_whose_send_a_process_did_not_finish_is_never_sent_by_another`) | `drain` resumes it; an `Attempting` target is due at once (`RT:4249`, `RT:6757`); the durable crossings ledger refuses the second attempt | none | none | none | same test, re-pointed | U1 | CONCEDED: one duplicate send after a kill |

C1, C24 and C25's *record* tails are C1 (§B.1).

### B.3 KEPT ANOTHER WAY (8 rows; independent of R0)

| ID | Old guarantee (pinning test) | How it is kept (public API) | Effect / cost | Text that changes | New pinning test | Upstream ask |
|---|---|---|---|---|---|---|
| C11 | A consumed KeyPackage stays while an invitation is held unanswered, up to 72 h (Rule 5) | `pause_maintenance` while any invitation is held (`RT:2235`); paused maintenance prepares no new private material (`RT:2597`) | a newly joined circle's post-join rotation waits ≤ 72 h only when two invitations overlap (ESTIMATED rare) | Rule 5 clause names `pause_maintenance` | `kp_lifecycle_e2e::a_held_invitation_pauses_replacement_and_its_welcome_is_accepted_on_day_three` | U8 |
| C16 | No timer-authored self-update except repair and post-join; no 0x800d (D3) | Haven's supported component set stays fixed, so the runtime's leaf refresh (`RT:2706-2707`, `ENG/leaf_advertisement.rs:51-136`) never fires; a future set change costs one spec-conformant refresh per circle within 5 days | none now | group-components paragraph adds the one-off refresh | `self_update_e2e::thirty_simulated_days_of_maintenance_author_no_self_update` (also asserts no 0x800d in any leaf or KeyPackage) | — |
| C17b | Haven's Welcome stops (withdrawn invite never re-driven) | `withdraw_welcome` (`RT/welcome_delivery.rs:352`) | none | retire T-WELCOME-OUTBOX | `welcome_outcomes_e2e::a_withdrawn_invite_is_never_redriven` | — |
| C20 | No automatic group recovery or rejoin publishing | Haven never calls `prepare_group_recovery`, `advance_group_recovery`, `retry_group_rejoin`, `retry_rejoins_after_trusted_removal` (guard); ingest only records authenticated controls (`RT:4278-4311`) | recovery records written on ingest (bound UNVERIFIED) | none | `recovery_e2e::a_recovery_control_is_recorded_and_nothing_is_published` | — |
| C23 | A location is never queued and sent stale (T-SECOND-HANDLE queued-location discard, `manager.rs:11596`) | `SendIntent::AppMessage{expected_epoch: Some(pin)}` makes the engine refuse, typed (`ENG/message_processor/mod.rs:1047-1064`); already available at v0.10.4 — if Stage 1 adopted it, this row is done | none | T-SECOND-HANDLE use list | `location_fanout_e2e::a_location_is_refused_typed_rather_than_queued_while_its_circle_is_unsettled` | — |
| C26 | Rule 13 invariants 1–3, 5, 6 (first half); frozen targets; Rules 14–16 | runtime records before bytes (`RT:5609-5619`, `:5697-5750`), confirms on an ack (`TA:772-777`), rolls back on proof (`RT:5986-5995`), never rolls back on a failed confirm (`RT:5029-5052`), freezes the request (`TA:789-797`) | none | Rule 13.1: "only MDK's runtime, through Haven's adapter, sends"; Rule 16's `RelayManager::fanout_transport` sentence | `security_rule_gates::only_the_runtime_through_havens_adapter_sends_a_recorded_event` | — |
| C27 | The sole admin leaving hands admin to a deterministic successor (`haven-core/src/circle/leave.rs` `LeavePlan::AdminHandoff`) — owner item O8 | Haven keeps `LeavePlan`: for a hand-off it first sends the admin change through the runtime, then `SendIntent::StepDownAndLeave` (`RT:4210-4219`); MDK's last-admin block (`LeaveBlockReason`, `crates/traits/src/storage.rs:661`) is reached only by a race, mapped to a typed `LeaveBlockedFfi` | none (today's behaviour); new copy only for the race | T-LEAVE-FANOUT | `leave_fanout_e2e::the_last_admin_hands_over_and_leaves_through_the_runtime` | — |
| C28 | An oversized Welcome is refused on the device before any relay sees it, at exactly the pre-fork NIP-44 edge of 65,408 plaintext bytes on each NIP-59 layer (owner item O13) | Kept by the same mechanism as in Stage 1: Haven's `LegacyNip44WelcomeSigner`, handed to the peeler the runtime's session holds (`with_welcome_signer_arc`), refuses the encrypt input and the seal before anything is staged. The adapter's `size_class_over_known_limits` and MDK's `WelcomeSizeCheck` see event sizes, never a layer's plaintext, so they cannot decide this edge and are not relied on for it (`RT:3695-3730`, `TA:1476-1485`) | none | `T-NIP44-WELCOME-CEILING`: mechanism unchanged | `welcome_outcomes_e2e::an_oversized_welcome_is_refused_before_any_record_on_the_runtime`, beside Stage 1's `nip44_plaintext_ceiling.rs` | (`T-NIP44-WELCOME-CEILING`'s own removal condition) |

### B.4 CONCEDED (8 rows)

| ID | Old guarantee (pinning test) | New behaviour | User-visible effect | Cost | Text that changes | New pinning test (replaces) | Upstream ask |
|---|---|---|---|---|---|---|---|
| C4b | No lock held across relay I/O even with no input waiting | a drive with no input waiting holds the lock for engine time + `ATTEMPT_CEILING` | a background receive arriving mid-drive waits for the drive | ≤ 20 s per drive against a silent relay (M3) | T-FANOUT (32) | `lock_hold_e2e::a_drive_with_no_input_waiting_holds_the_lock_at_most_one_attempt` | U4 |
| C5b | Background never stages a commit | a background `advance_convergence` may stage this device's eviction or a regenerated queued change, unsent until a foreground drive (`RT:3907-3924`) | after a member leaves, a backgrounded device that staged the eviction stops taking in that circle's traffic until the app is opened (sharing there was already paused by the pending SelfRemove, T-KILL-WINDOW) | one circle's background receive paused from a departure to the next foreground, hours on iOS (ESTIMATED; M4) | SECURITY.md finish-only paragraphs | `finish_only_e2e::a_background_advance_may_stage_an_eviction_and_sends_nothing_until_the_foreground` (replaces `…makes_no_first_send_and_begins_nothing_without_a_rows_budget`) | U5 → T-NO-INPUTS-ONLY |
| C6 | Inputs-only advance on send-only planes and at a Launched open (SECURITY.md `:1605-1620`; `a_started_session_and_a_burst_make_nothing_of_a_departure`) | no inputs-only entry on the runtime (`RT:3910-3921`) | as C5b | as C5b | SECURITY.md "Launched … inputs-only" | `live_plane_drive_e2e::a_started_session_may_stage_a_due_eviction_and_sends_it_only_after_the_claim` | U5 |
| C7b | A confirmed commit's *record* ends at `min(2,n)` acks or 24 h (`FANOUT_BOUND_MS`, `relay/fanout.rs:987`) | a target once possibly exposed stays outstanding, refused locally for ever | none | ≤ 1 row per commit with a possibly-exposed straggler; scan cost (M6, M7) | Rule 13 preamble; SECURITY.md `:489` | covered by C7a's test (asserts the straggler record stays and nothing is dialled) | U3 → T-FANOUT-END |
| C9 | Superseded KeyPackage private material deleted when a relay acks the replacement (Rule 5; T-KP-RETENTION) | kept 24 h after the replacement's confirmed publication or to expiry (`crates/traits/src/maintenance.rs:328`, `:399-415`); no host setting | none | a superseded, unconsumed `init_key` lives ≤ 24 h longer: compromise in that day plus a captured Welcome to the old package lets an attacker join that circle as this device | Rule 5 superseded-KeyPackage clause → "…24 hours after its replacement's publication is confirmed, or at its `not_after`, whichever comes first"; SECURITY.md `:3896` | `kp_lifecycle_e2e::superseded_material_is_kept_for_mdks_grace_and_swept_after_it` | U7 → rewrite T-KP-RETENTION |
| C14 | Rule 13.6: a failed confirm still returns what the commit delivered | `confirm_published_fanout_retrying` propagates `Err` after four transient attempts and drops collected effects (`RT:5029-5052`, `:5974-5984`) | peer locations released by that confirm arrive one drive later — UNVERIFIED that a later `drain` re-delivers them | one drive's delay per failed confirm | Rule 13.6 → "…the next drive delivers what it released" | `fanout_driver_e2e::a_failed_confirm_is_never_a_rollback_and_the_next_drive_delivers_what_it_released` | U10 → T-CONFIRM-ERR |
| C19b | Gate before mark: no attempt counted for a call that never left (T-FANOUT (25)) | the attempt is marked before `adapter.publish` (`RT:5697-5698`, `TA:635-660`) | none | counters only (M5) | T-FANOUT (25) | `fanout_transport_matrix::a_locally_refused_attempt_is_counted_by_the_runtime` | U13 → T-GATE-BEFORE-MARK |
| C21 | Re-issue of a non-removal change only at a full drive in a settled circle (T-REISSUE (1)–(5)) | every batch and every maintenance pass; a stale relay/admin change becomes `Conflict` when the winning branch touched the field (`ENG/own_commit_intent.rs:241-330`; LOW) | a withdrawn relay or admin change is made again sooner | none | T-REISSUE (1)–(5) | `reissue_e2e::a_withdrawn_relay_change_is_reissued_by_the_runtime_in_the_same_batch` | U2 |

### B.5 CHANGED — MDK WINS (4 rows)

| ID | Old | New | Effect / cost | Text that changes | New pinning test |
|---|---|---|---|---|---|
| C10 (owner item O4) | rotate at 0.75 of the lifetime (`relay/maintenance/kp_lifetime.rs:78`): ≈ 16 kind-30443 per account relay per year, COMPUTED | runtime refresh at a random 6–7 d (`RT:98-99`, `:6938-6945`), not host-settable; keeping 0.75 would need pausing all maintenance (off-label) | ≈ 56 publications/yr, COMPUTED (365 / 6.5); shorter `init_key` exposure, but a public weekly "this device is alive" signal on account relays; the extra publishes have an energy cost model E has not estimated. **Recommendation: accept** (spec SHOULD). If vetoed, 2.1 waits for U17 | CLAUDE.md kind-30443 row; `docs/POWER_EFFICIENCY_PLAN.md` KeyPackage entry | `kp_rotation_e2e::the_runtime_refreshes_the_slot_within_seven_days_and_never_mints_a_second_slot` (M8) |
| C12 | one-time malformed-slot repoint signs a second event | MDK's own-slot handling, one event id per package (`crates/traits/src/maintenance.rs:510-531`) | none | kind-30443 row drops the repoint sentence | `kp_rotation_e2e::a_welcome_naming_the_first_event_of_a_package_is_accepted` |
| C13 | seal and publish are two FFI calls (`API:8611`, `:8633`) | `send(AppMessage)` seals, records and drives in one call (`RT:7165-7186`) | a seal waits for the lock during a drive (bounded, C4) | Flutter Service Layer `LocationSharingService` line | `location_fanout_e2e::a_location_is_sealed_and_sent_in_one_call` (U9 would restore the split) |
| C15 | post-join self-update "in a full drive after catch-up …" | runtime obligation: catch-up → EOSE ≤ 5 min → 15 s grace → 60 s quiet → jitter (`RT:2720-2990`) | ≤ 5 min + 75 s + jitter after a join (ESTIMATED) | group-components paragraph | `self_update_e2e::a_joiner_rotates_through_the_runtimes_obligation_after_catch_up` |

### B.6 Mitigations that write records (listed so the owner sees them under D2)

| Mitigation | What Haven writes | Why it is not a hidden shim | Fate |
|---|---|---|---|
| **Location-row retirement step** (2.2a) | deletes, through `StorageProvider::delete_outbound_fanout` (`crates/traits/src/storage.rs:641`), every application fanout row (`application_message: Some`, `TA:270`) in a store last opened by a build that wrote locations into MDK's table | they are Haven's own records, written by Haven's own driver through the public record API (`manager.rs:4641-4693`); left in place they are the C1 wedge on the first runtime drive | ships in 2.2a; **stays** until the minimum upgrade source is past every release that wrote such rows |
| T-KILL-WINDOW repair (`try_recordless_removals`, `manager.rs:14603`) | a `Pending` trial fanout row before open | repairs an engine gap (a removal-bearing staged commit with no row wedges the circle) | kept as recorded debt; trial ref above `pending_ref_high_water()` |
| Network-restored wake (`wake_targets_for_restored_connectivity`) | clears last-attempt times on reconnect | MDK's own `marmot-app` does exactly this (`crates/marmot-app/src/client/sync.rs:489-505`) | adopted in 2.2 |
| `acknowledge_published_app_messages` (`RT:4500-4524`) | deletes accepted, complete app fanouts once Haven stored the outcome | the runtime's own contract | adopted in 2.4 |

---

## C. Sub-stages

Order: **S2-fixture → 2.0 → 2.1 → 2.2a → 2.2 → 2.3 → 2.4 → 2.5.** Each sub-stage merges when green;
nothing waits for 2.5. Holds: 2.2 (and so 2.3–2.5) waits for U2 under the C2 recommendation, and for U6 if
R0 = no; 2.4 waits for U1 under the C1 recommendation, and 2.5 then exits with one entry. Only fanout-free
runtime entries can move while Haven's driver owns fanout rows (`run_due_maintenance` also drains, re-issues,
resumes fanouts and delivers Welcomes, `RT:2511-2555`, `:2896-2950`), so KeyPackages go first and commits,
Welcomes, ingest, drain and advance change owner together; locations leave MDK's table first (2.2a) so 2.2
can land without them.

**Local gate for every merge:** `cargo test`, clippy `--all-targets -D warnings` and fmt in the three roots;
guards with `--self-test`; soak PR profile; `./scripts/regenerate_frb.sh`, `flutter analyze`, `flutter test`,
`flutter gen-l10n` (warning-free) and `arb_parity_check.dart` whenever `api.rs` or l10n changes (all local). **GitHub-CI-only:** emulator/simulator E2E lanes, cross-check (Apple/Windows/Android), build-check,
release-link. A sub-stage that changes a release passes the release gate as Stage 0 extends it. Build-cycle costs
(measured on the build machine): full haven-core suite ≈ 30 min, `cargo check --all-targets` ≈ 3.5 min, Flutter
suite ≈ 4 min, `flutter analyze` ≈ 25 s.

### C.0 The exception guard across Stage 2, and one tracker row

- **Stage 1 leaves** `scripts/ci/check_private_session_exception.sh` in its file-allowlist form: the `feature`
  line, the resolved-feature check per root, and the set of files whose *code lines* may name
  `AccountDeviceSession`/`IngestEffects`. No git-base comparison and no `--require-empty` mode; Stage 2 adds both
  the per-function list and that mode.
- **2.0 redefines it as a per-function list.** All private-session reach goes through one choke point,
  `HavenRuntime::private_session(&mut self) -> &mut AccountDeviceSession` in
  `haven-core/src/nostr/mls/private_session.rs`, the only file in shipped source allowed to contain
  `session_mut(` or `.session()` on the runtime. The data file becomes:
  `feature marmot-session test-support haven-core/Cargo.toml` plus one `site <path> <fn> <n>` line per
  production function calling `private_session(`. Checks: (1) feature lines are the whole truth;
  (2) resolved features per root; (3) every `private_session(` call lies in a listed function with exactly the
  listed count, and no unlisted function calls it (the enclosing function is found textually — the nearest
  preceding `fn` header at lower indentation; the guard is bash with no parser, so the self-test plants nested
  closures and `impl` blocks inside modules); (4) `session_mut(`/`.session()` outside the choke-point file
  fails; (5) **`--require-empty`**: no `site` line, no `feature` line, the choke-point file absent, and step 2
  printing `default` for the shipped roots (Stage 1b's step 2 prints `default,test-support` until then). Each sub-stage deletes its lines in the same change as the code.
  `--require-empty` is the **2.5 exit check**, never a merge gate.
- **One tracker row, `T-SESSION-PRIVATE`** (created by Stage 1), updated by every sub-stage with its remaining
  `site` count. There is no `T-RUNTIME-MIGRATION`. `T-FINISH-STAGE-HOOK` (created by Stage 1) is updated, not
  duplicated.

### S2-fixture — a database written by the Stage-1 release (master step 22; gates 2.0)

`haven-soak fixture write` at the Stage-1 release commit; committed as `fixtures/upgrade/<stage1-release>/` with
Stage 0's recipe (`sqlcipher_export` + `.dump`, time anchors per state, time-limited states written last). Stage 2
is gated on it **and** on the Stage 0 fixtures (`haven-v0.1.13/`, `haven-pre-bump/`), because users may skip the
Stage-1 release. Beyond Stage 0's required shapes it must contain:

1. **Unacknowledged location rows in MDK's fanout table** (the HIGH-1 case): one `Attempting` from a process
   killed between crossing and `OK`; one expired `PossiblyExposed`; one unexpired `NotAttempted`.
2. Haven-driver commit rows in each state: pending with a possibly-exposed target; confirmed-kept straggler
   (OD-2 record); rolled-back marker; T-KILL-WINDOW trial row; a queued intent blocked behind a pending fanout.
3. An undelivered post-confirmation Welcome; a held invitation with its consumed KeyPackage; the Stage-1
   KeyPackage lifecycle row with a pending replacement.
4. A withdrawn own removal held unmade (`RemovalUnmade`) and a withdrawn relay change (C2, C21 first-open
   behaviour); a pending leave.
5. One store keyed the production way (PBKDF2 passphrase) with an un-checkpointed WAL.

Assertions at the first runtime open (written in 2.0, extended per sub-stage): immediately after open and before
any tick, KeyPackage bundle count unchanged and no circle quarantined (except the fixture's own); from 2.2a, no
row of item 1 remains before the first drive and none of those locations is sent; from 2.2, every item-2 row is
driven to confirm or proven rollback under Rule 13, no Welcome is sent twice, and nothing in item 4 is re-issued
unless the owner accepted C2; from 2.1, the slot is adopted, never re-minted.

**Stage 0 fixture consumer (X16).** Stage 0's fixture *assertions* carry over unchanged; the consumer's driver
calls (`Publishing::resume`, `seal_location`, …) are rewritten in the sub-stage that deletes them (2.2 for the
driver, 2.2a/2.4 for the location path).

**Baseline capture.** At the same commit, record the Stage-1 cost ledger (§D.2) for every scenario of the S0.9
ledger and the Stage-2-only metrics.

**Cost (ESTIMATED):** 1 fixture write, 2 check cycles, 1 full suite. ≈ 1.5 h of builds.

### 2.0 — Open through `AccountDeviceRuntime::open` (master step 23)

- **Code.** New `relay/runtime_adapter.rs` (§A.2–A.4, window permanently Closed, so the runtime can send
  nothing), `relay/runtime_routing.rs`, `relay/key_package_publisher.rs` (unused yet), `HavenClock`/`HavenRandom`,
  `nostr/mls/private_session.rs`. `SessionManager::new*` (`manager.rs:1238-1300`, open at `:1404`) →
  `with_storage` + `AccountDeviceRuntime::open`; `Gated<HavenRuntime>`; `message_store` is the clone. Reads with
  a runtime equal (`epoch_state`, `members`, `group_record`, `admin_pubkeys`, `live_group_ids`, `app_component`,
  `exporter_secret*`, `forget_group_local`; `RT:697-964`, `RT:4231`) move to the runtime; every other session
  call goes through `private_session()` (≈ 70 methods).
- **Guards.** C.0 redefinition. Stage 1's ban on `AccountDeviceRuntime` in shipped source is lifted
  deliberately. New bans: `activate_transport`, `sync_transport_groups`, `prepare_group_recovery`,
  `advance_group_recovery`, `retry_group_rejoin`, `retry_rejoins_after_trusted_removal`,
  `run_due_maintenance_holding`, `set_periodic_maintenance_policy`, `with_maintenance_timing(` outside tests,
  `prepare_welcome_retry_task_with_audit_context`, `finish_welcome_publish_task`, an HTTP client in the adapter
  file, and —
  until 2.2 — every runtime method that publishes (`send*`, `drain`, `ingest_delivery*`, `advance_convergence*`,
  `resume_outbound_fanouts`, `run_due_maintenance`, `publish_prepared_*`, `rollback_prepared_*`,
  `queue_app_message*`; the list shrinks per sub-stage). `check_debug_impls_covered.sh` extends `FOREIGN_RE` to
  `AccountDeviceEffects`, `PublishFailure`, `TransportPublishReport`, `SupersededIntentReport`,
  `UnresolvedPublish` (they carry endpoints and prose, `RT:7249-7292`). `check_no_forensic_recorder.sh` gains
  nothing (its tokens are Stage 1's: `audit_recorder(`, `SharedRecorder`; no `.swap(`). Stage 1's
  `SessionConfig::new(` ban stays (Haven's `SqliteAccountStorage` open remains the only opener, first-use gate).
- **Tests.** No family rewritten. New: `runtime_seams_e2e::the_runtime_never_calls_receive_activate_or_sync`,
  `…opening_twice_on_one_file_fails_closed`, `…one_connection_serves_engine_and_second_handle`, and the three
  fixtures opening through the runtime with the S2-fixture assertions.
- **Docs.** CLAUDE.md MDK-pinning bullet (the choke point), Rule 14 names the runtime; tracker
  `T-SESSION-PRIVATE`, `T-SECOND-HANDLE` (one connection now).
- **FFI / Dart / l10n.** None (regeneration shows zero diff).
- **Cost (ESTIMATED):** ≈ 20 check cycles, 3 full suites, 2 soak PR runs ≈ 3 h of builds; 3–5 engineer-days.

### 2.1 — KeyPackage lifecycle onto the runtime (master step 24)

- **Code deleted.** `SessionManager::{fresh_key_package, key_package_tick, tracked_key_package,
  adopt_key_package_slot, stage_key_package, promote_key_package, repoint_key_package_slot,
  sweep_expired_key_packages}` (`manager.rs:12132-12500`), most of `relay/maintenance/key_package.rs` and
  `kp_lifetime.rs` (≈ 1,500 lines). Kept: the tick's claim logic calling the runtime; the invitee-package side
  (T-30443-VALIDATE, T-KP-AUTHOR, T-KP-CLIENT-RANK).
- **Runtime APIs.** `key_package_network_maintenance_due` (`RT:1836`), `key_package_generation_upgrade_due`
  (`RT:1821`), `publish_fresh_key_package` (`RT:1606`), `republish_key_package` (`RT:1274`),
  `sweep_expired_key_package_private_material` (`RT:2142`), `withdraw_key_package_slot` (`RT:1936`),
  `key_package_maintenance_status` (`RT:1808`), `durably_owned_key_packages` (`RT:1814`; handle `Err` as
  "unknown"), `pause_maintenance`/`resume_maintenance`. The publisher goes live; the window opens as Drive for
  these calls only.
- **Deferred from Stage 1 (Stage 1b §7): the KeyPackage refresh cadence, owner item O4** — Haven acts when
  `key_package_network_maintenance_due` says so, which brings MDK's 6–7 d refresh (row C10) under the owner's O4
  ruling. Rows C9, C10, C11, C12 land here.
- **Tests.** `kp_lifecycle_e2e.rs`, `kp_rotation_e2e.rs`, `key_package_*`, soak `s12_key_package_rotation.rs`
  re-proved through the runtime; the §B tests of C9–C12; `…a_legacy_slot_is_adopted_and_no_second_slot_is_minted`
  (all three fixtures), `…the_publisher_signs_once_and_every_retry_sends_the_same_bytes`,
  `…the_30443_tags_are_exactly_the_seven`.
- **Tracker.** Retire T-KP-DRIVER, T-KP-EXPIRED-DELETE; rewrite T-KP-RETENTION (C9); add
  T-KP-PUBLISHER-PROVISIONAL (U16), T-KP-HOLD (C11, U8).
- **FFI.** `maintain_key_package` (`API:9592`) keeps its signature; its mapping is rebuilt over
  `KeyPackageMaintenanceStatus`; regenerate, `flutter analyze`, `flutter test` locally.
- **Docs.** CLAUDE.md Rule 5 KeyPackage clauses, kind-30443 row; SECURITY.md `:3847`, `:3896`;
  `docs/POWER_EFFICIENCY_PLAN.md` KeyPackage entry (count only, energy not estimated).
- **Cost (ESTIMATED):** ≈ 25 check cycles, 4 full suites, 2 Flutter cycles, soak S12 ≈ 3.5 h; 4–6 engineer-days.

### 2.2a — Locations off MDK's fanout table; the retirement step (master step 25)

- **Code.** `put_location_fanout` (`manager.rs:4641-4693`) and the location half of the driver write a
  Haven-owned `location_sends` table (circle store) instead of MDK rows; the seal stays a `private_session()`
  site with `expected_epoch: Some(pin)` (C23).
- **The location-row retirement step.** In the pre-open pass, before `AccountDeviceRuntime::open`, on every
  opener §A.1 names (inside `SessionManager::new*`, so no opener can skip it): if the
  circle store's retirement marker is absent, delete every MDK fanout row whose `application_message` is set
  (`delete_outbound_fanout`). Ending every leftover row is the whole rule: a ≤ 228 s-old fix is re-sealed at the
  next tick anyway, so nothing is moved. The marker is written after the open and **before the first drive
  window**, so no runtime-written application row can exist when the step runs again after a crash; this is
  what keeps the step correct after 2.4, when the runtime itself writes application rows. Idempotent: a re-run
  deletes nothing new. The step **stays in the tree** until the owner raises the minimum upgrade source past
  every release that wrote location rows into MDK's table; its removal is a tracker row
  (`T-LOCATION-ROW-RETIREMENT`, removal condition stated so). Stage 2 keeps MDK schema 201, so Stage 1b's
  `STORE_GENERATION` is not bumped and background openers are not gated: the step runs on them too, which is
  why it is relay-free and touches only MDK's fanout table and the marker.
- **Tests.** `location_fanout_e2e.rs`, `deferred_location_send_repair_e2e.rs`, `application_output_ack_e2e.rs`
  re-pointed at `location_sends`; new `upgrade_e2e::every_location_row_a_previous_release_wrote_is_ended_before_the_runtime_opens`
  (S2-fixture item 1, all three fixtures, foreground and background openers),
  `…a_crash_after_the_retirement_re_runs_it_harmlessly`, and
  `…no_application_row_exists_before_the_first_send_after_open` (pins the marker ordering).
- **Exception list.** Unchanged count.
- **Cost (ESTIMATED):** ≈ 15 check cycles, 3 full suites ≈ 2.5 h; 3–4 engineer-days.

### 2.2 — The flip: commits, Welcomes, ingest, drain, advance, leave (master step 26; held per §0.3)

**The branch-local dual path.** The flip cannot be split into independently green sub-PRs (the
families cannot be re-proved through a runtime path that does not yet exist, and after the flip the old families
are red), so 2.2 is one sub-stage built as a commit series with a temporary switch:

- **The switch** is a haven-core cargo feature `runtime-flip`, forwarded by `tooling/soak` only for the soak
  scenarios ported under it. Enabling it without `debug_assertions` is a `compile_error!` (the `test-utils`
  precedent), so it cannot reach a release binary; `scripts/build_release.sh` passes no features.
- **Commit series.** (1) Scaffold: the runtime path beside the old driver under `cfg(feature = "runtime-flip")`,
  the old under `cfg(not(…))`. (2) One commit per test family: the family's runtime version under the feature,
  its old version kept under `not`; each commit green under both configurations (check + the family's tests
  in each). (3) Rehearsal: the full suite and soak PR profile under the feature. (4) **Final commit:** the
  runtime path unconditional; the old driver, every old family version, the feature, its forwarding and every
  `cfg(feature = "runtime-flip")` deleted; a guard step bans `runtime-flip`/`runtime_flip` in every Cargo.toml,
  source file, script and workflow (self-test plants it). The sub-stage merges only at its final commit.
- **Why this is not a compatibility shim.** A shim is carried across releases to stay compatible with something
  old. The switch exists only between the first and last commit of one sub-stage, is never in a merged tip or a
  release (`compile_error!`), and its absence at the end of 2.2 is proved by a guard. It must not survive the
  sub-stage.

Content:

- **Code deleted.** The staging/confirm/rollback/resume/Welcome-outbox/re-issue/re-queue halves of
  `relay/fanout.rs` (≈ 4,000 lines; the location half stays until 2.4) and of `SessionManager` (`send_staging`
  `:4466`, `*_staging` `:4885-4957`, `advance_for_drive` `:4957`, `stage_commits` `:6876`,
  `reissue_next_withdrawn` `:5902`, `confirm_published`/`publish_failed*` `:4286-4420`; ≈ 3,000 lines); test hooks
  `:5282-5381`, `:8888-9181`.
- **Code written.** The full adapter pipeline (§A.3) with the §0.1 proof, windows and pressure (§A.4);
  `confirm_commit_without_publish_with_audit_context` (`RT:3647`) → record notes →
  `publish_prepared_session_effects_with_audit_context` (`RT:3574`) for Haven's `_driven` entries;
  `rollback_prepared_session_commit` (`RT:3746`); `prepare_create_group_with_optional_app_components_and_audit_context`
  (`RT:3501`); `ingest_delivery` (`RT:4258`); `drain`/`resume_outbound_fanouts` (`RT:4246`, `:4460`);
  `advance_convergence*` with due-before-advance; `outbound_fanout_retry_delay_ms` for the scheduler; Welcome
  delivery/withdraw/redeliver (`RT/welcome_delivery.rs:52`, `:352`, `:310`); `StepDownAndLeave`,
  `leave_in_progress`, `leave_redrive_owed`, `cancel_leave` (C27; Stage 1's construction ban on
  `StepDownAndLeave` is lifted for the leave entry only); `pending_reinvites` / `reserve_reinvite_lookup` /
  `reissue_invite_with_key_packages` (`RT:1185-1210`); the network-restored wake; post-call reconciliation
  (retire rolled-back rows, change notes from `superseded_intents`/`failures`/`welcome_failures`, routing-cache
  refresh). Background bursts and Launched sessions ingest/advance with the window Closed and drive with
  `Drive{foreground: false}`. The soak rig's `RelayMappedFanout` is replaced by `HavenAdapter` behind an address
  map (CLAUDE.md `test-utils` bullet).
- **Test families — each promise kept, or replaced by the §B test of the new behaviour, never loosened.**
  `fanout_driver_e2e`, `fanout_end_e2e`, `fanout_restart_e2e`, `fanout_change_e2e`, `fanout_transport_matrix`,
  `finish_only_e2e`, `publish_before_apply_send_e2e`, `publish_failed_rewind_e2e`, `leave_fanout_e2e`,
  `live_plane_drive_e2e`, `poll_send_drive_e2e`, `send_path_drain_e2e`, `reissue_e2e`, `requeue_e2e`,
  `released_intent_e2e`, `welcome_outcomes_e2e`, `selfremove_autopublish_e2e`, `od4c_removal_deferral_e2e`,
  `security_rule_gates` (Rule-13 gates) — ≈ 46,700 lines; faults injected in a scripted `HavenAdapter`, time by
  `HavenClock`. New: the §0.1 R0 tests, `runtime_seams_e2e::a_drive_call_runs_no_convergence_pass`,
  `…a_possibly_exposed_target_stays_outstanding`, `…retry_delays_are_the_ones_haven_paces_against` (canaries for
  the runtime assumptions this design rests on), and a source-reading drift test of `FROZEN_FANOUT_*`,
  `TRANSPORT_FANOUT_RETENTION_SECS`, `LEAF_REFRESH_WINDOW_SECS`, `KEY_PACKAGE_REPLACEMENT_GRACE_SECS`. Soak S03,
  S05, S06, S14, S18, S19, S21, S22, S23, S25.
- **Tracker.** Retire T-FANOUT, T-WELCOME-OUTBOX; rewrite T-ROLLBACK-RESURRECT (C3, U6), T-CONFIRM-ERR (C14),
  T-REISSUE (C21; C2 per ruling), T-LEAVE-FANOUT (C27), T-ADAPTER-ATTEMPTS (Haven's adapter classifies by frame),
  T-CLOCK-SKEW, T-REINVITE-DRIVER, T-STALE-FANOUT, T-KILL-WINDOW, T-SCHEDULER (shrinks), T-SESSION-PRIVATE. Add
  T-ADAPTER-POLICY-REFUSALS (the §A.3 refusals and why each is truthful; removal: U1/U3/U4/U5), T-LOCK-HELD-IO,
  T-NO-INPUTS-ONLY, T-FANOUT-END, T-GATE-BEFORE-MARK.
- **FFI (regenerated locally).** `_driven` entries (`API:8367-8701`) keep names and outcome structs.
  `ResumeOutcomeFfi.withdrawn`/`requeued` (`API:8046-8060`) → `superseded: Vec<SupersededChangeFfi>`.
  `SendHeldFfi` keeps `RemovalUnmade` unless C2 is accepted. New `LeaveBlockedFfi`. Dart: `CircleChangeDriver`,
  `circleRecovery` mapping and the sharing card, `change_notice_card.dart`, `NostrCircleService`, their tests —
  analyzed and tested locally.
- **l10n.** Fixed copy, every locale, one translating agent per language plus an independent reviewer, then
  `arb_parity_check.dart` and warning-free `flutter gen-l10n`: "You are the last admin. Hand over admin before
  leaving" (the C27 race), "Your earlier change was already made by another admin" (`AlreadySatisfied`), and
  only if C2 is accepted "A removal you made was made again after another admin's change". Each tied to its typed
  outcome by a `privacy_copy_ties.rs`-style test.
- **Docs.** CLAUDE.md Rule 13 (six invariants' wording and test names), Rule 12 (C5b/C6), Rule 16
  (`RelayManager::fanout_transport` / `NostrSdkRelayClient` sentences: MDK's relay client is no longer used and is
  banned), Architecture "Relay clients", `CircleService` line, kind-444/445 rows; SECURITY.md `:459`, `:489`,
  `:1450-1990`, `:3632`, `:4176`; `docs/BACKGROUND_SHARING_FAILURE_ANALYSIS.md`, `docs/SOAK_LANE.md`.
- **Guards.** `check_e2e_publish_before_apply.sh` check 1 bans the runtime's publish entries outside
  `SessionManager`; `check_engine_client_options.sh` check 11 bans `NostrSdkRelayClient`; the adapter-file bans
  of §0.1; `check_advance_convergence_sites.sh` (the scheduler and the due-before-advance helper only);
  `check_self_update_sites.sh` (`schedule_manual_self_update` only from the repair entry); the `runtime-flip` ban.
  `check_mdk_supply_chain.sh`: drop the adapter's `sdk` feature if `NostrKeyPackagePublication` is reachable
  without it (UNVERIFIED).
- **Exit checklist.** Run ids recorded for: every E2E lane run twice (second attempts read,
  compared with the lane's flake-rate baseline from Stage 0), soak-nightly dispatched on the branch, all three
  fixtures, gates M1–M9 within rule.
- **Cost (ESTIMATED):** scaffold ≈ 30 check cycles; 19 family commits × (2 checks + family tests in two configurations)
  ≈ 19 × 20 min; rehearsal 2 full suites; final commit 3 full suites; soak PR × 3; FRB + Flutter ≈ 4 cycles;
  CI E2E twice. ≈ 14 h of builds; 15–25 engineer-days.

### 2.3 — Maintenance onto `run_due_maintenance` (master step 27)

- **Code deleted.** T-MAINT-DRIVER's post-join driver and Haven's Welcome re-drive tick (≈ 800 lines,
  `manager.rs:9203-9271` probes), most of T-SCHEDULER's maintenance arm. The tick calls `run_due_maintenance()`
  in a Drive window (never `_holding`: `held` is fork protection, `RT:2513-2519`); paused per §A.7; marks
  post-join subscription/EOSE/history-fetch (`RT:2319-2470`) from the receive planes; the 24 h repair calls
  `schedule_manual_self_update` (`RT:2247`) with Haven's own rate limit.
- **Maintenance-parity holds deferred from Stage 1 (Stage 1b §7)** now come from the runtime natively and are pinned
  here: the epoch-gap hold (`RT:2516-2520`, `:3000-3005`) and the 1 h undelivered-commit hold
  (`COMMIT_DELIVERY_SELF_UPDATE_HOLD_SECS`, `RT:122`, `:3006-3015`) —
  `self_update_e2e::no_post_join_self_update_while_the_circle_is_known_behind`,
  `…while_a_commit_is_undelivered_for_under_an_hour`; and T-SCHEDULER arms (2)–(4) (no terminal copy is
  `PendingUnopenable`; queued intents not blocked by fanouts before the fanout-retry arm; `leave_redrive_owed`
  as `PendingOutbound`) with one test each. T-EPOCH-STALL re-checked against `deferred_stall_evidence`
  (owner item O7).
- **Tests.** `self_update_e2e` re-proved (C15, C16 tests, D3 pin); `welcome_outcomes_e2e` maintenance arms; soak
  S11, S12, S26.
- **Tracker.** Retire T-MAINT-DRIVER; shrink T-SCHEDULER to receive-side arms.
- **FFI.** None expected (`ResumeOutcomeFfi.retry_after_ms` from `outbound_fanout_retry_delay_ms`).
- **Docs.** CLAUDE.md group-components paragraph; SECURITY.md `:4066`.
- **Cost (ESTIMATED):** ≈ 20 check cycles, 4 full suites, soak × 3 ≈ 3.5 h; 4–6 engineer-days.

### 2.4 — Locations onto the runtime (master step 28; held per §0.2)

- **Precondition.** U1 in a released MDK tag Haven pins, or the owner accepted C1 in writing. Otherwise skip to
  2.5 with the one-site exception (C1 option (b)).
- **Code.** `send(SendIntent::AppMessage{group_id, payload, expected_epoch: Some(pin)})` (`RT:3583`, pin from
  `RT:911`); `AppMessageEpochUnsettled` → `SendHeld`; `published_app_messages` → Haven's last-sent store →
  `acknowledge_published_app_messages` (`RT:4500`); `unresolved_app_messages`/`failed_app_messages` feed the
  scheduler. Delete the location half of `relay/fanout.rs` (≈ 1,500 lines), `send_location_staging`
  (`manager.rs:4542`), `put_location_fanout` (`:4641`); `location_sends` is dropped by an idempotent pre-open
  step (`DROP TABLE IF EXISTS`) that stays as the retirement step does. The 2.2a retirement step **stays**.
- **Tests.** `location_fanout_e2e`, `deferred_location_send_repair_e2e`, `application_output_ack_e2e`,
  `location_clock_verdict_e2e`, `live_sync_burst_e2e`; C1a, C13, C23, C24a, C25a tests; soak S01, S02, S04, S08,
  S10, S16 (application-rows arm), S18.
- **Tracker.** Rewrite T-APP-TRANSPORT; retire T-APP-FANOUT-END if U1 landed, else it is the recorded HIGH.
- **FFI.** `seal_location_driven` + `publish_location_driven` (`API:8611`, `:8633`) → `share_location_driven`;
  Dart `location_publish_scheduler_provider.dart`, `nostr_relay_service.dart`, `LocationSharingService` and
  tests, locally. **l10n.** None.
- **Exit.** As 2.2; M6 shows no unbounded application-row growth on S16/S18.
- **Cost (ESTIMATED):** ≈ 25 check cycles, 4 full suites, 3 Flutter cycles, CI E2E twice ≈ 4 h; 6–10
  engineer-days.

### 2.5 — Remove `test-support` from the shipped roots (master step 29)

- Delete `private_session.rs` and every `site` line; drop `features = ["test-support"]` from haven-core's normal
  edge; tests keep it under `[dev-dependencies]` only. Exit check: `check_private_session_exception.sh
  --require-empty`, scoped to the shipped roots: `haven-core` (no features) and `haven/rust_builder` resolve
  `marmot-session` as exactly `default` on `cargo tree --locked -e normal,build`; for `tooling/soak` (which
  enables `haven-core/test-utils` on a normal edge) the guard asserts only that `test-support`, if present,
  arrives through `test-utils` (itself a compile error without debug assertions). A self-test plants
  `test-support` under `[dev-dependencies]` only and expects `default` on the normal graph (cargo's resolution
  here is UNVERIFIED until that self-test runs).
- **Under C1 option (b):** the exit check is `--require-exactly` the one `site` line naming
  `T-APP-FANOUT-END`; the feature line stays; `T-SESSION-PRIVATE` stays with that entry and D1's end state is
  recorded as not yet met.
- CLAUDE.md MDK-pinning bullet: "`marmot-session` with no feature on a normal edge; `test-support` only as a
  dev-dependency". Retire `T-SESSION-PRIVATE` (or update it, option (b)).
- **Cost (ESTIMATED):** ≈ 5 check cycles, 2 full suites, full CI ≈ 1.5 h; 1–2 engineer-days.

**Total (ESTIMATED):** ≈ 33 h of local builds across the sub-stages plus CI matrix runs at 2.2 and 2.4;
36–58 engineer-days. Net production code ≈ −8,500 deleted, +2,500 written, ≈ 3,500 rewritten.

---

## D. Proving no regression

### D.1 What carries over

- Stage 0's fixture assertions and mixed-version circle tests, at every sub-stage (the consumer's driver calls
  are rewritten where the driver is deleted, X16), plus the S2-fixture.
- The wire allowlist and relay-plane proofs (`relay_plane_wire_e2e`, `relay::recording_front`,
  `relay::dial_witness`): the adapter dials through the same verified client.
- Logscan over every lane's sinks, the `Debug`/`Display` enumeration test, the identifier source guards (with
  `FOREIGN_RE` extended in 2.0). Every new log line (adapter, retirement step, choke point) gets a test that
  plants an identifier and asserts it absent (Rule 15).
- Rule 16 forged-event tests: receive planes unchanged.
- Soak S01–S26 with the same liveness bounds and expectation floors; a bound derived from a Haven constant the
  runtime replaces (e.g. S18's withheld-publish ladder) is re-derived from the runtime's constant and stated in
  the scenario's doc.

### D.2 Cost gates — measured against two baselines

Every gate counts; none times wall-clock. Two baselines:

- **B0 — v0.10.4** (Stage 0 unit S0.9): relay frames by verb per relay, socket dials, `verify()`
  calls, events fetched, store pages, DB-open time (bucketed), KeyPackage publications, per scenario.
- **B1 — the Stage-1 release** (recorded at the S2-fixture step): the same ledger, plus the Stage-2-only
  metrics below.

A ledger metric must hold against **both**: an increase over B0 or B1 fails unless it is listed with its
concession or Stage-1 entry (C10 is the only expected Stage-2 entry); an improvement is recorded. **Deterministic
arms** compare exactly (after ≤ before). **Fault-timed arms** (S18 swallowed `OK`, S21 reconnects, S25 dead relay,
and any arm with a reconnect or a timeout) use the tolerance band S0.9 commits with each arm — its spread over the
fixed seed set — never exact equality; Stage 2 does not widen a band.

| # | Metric | Where | Rule |
|---|---|---|---|
| M1 | Relay frames and bytes per relay per scenario by verb | `recording_front` on soak S01, S05, S18, S21, S25 and the E2E change/location suites | vs B0 and B1, exact or band as above |
| M2 | Scheduler wakes and adapter dials per simulated hour, idle sharing circle, foreground and background | soak S11, injected clock | vs B0 and B1, ≤ |
| M3 | Longest runtime-lock hold during a drive against a relay that never answers, with and without input pressure | `lock_hold_e2e`, scripted relay, paused time | with input ≤ `PREEMPT_GRACE` + longest engine step on the same build; without ≤ `ATTEMPT_CEILING` ≤ 20 s |
| M4 | Commit first-ack → next location first-ack; departure → next taken-in peer location, foreground and background | soak S04/S21, injected clock | foreground vs B1 ≤; background: B1 + the C5b delta, reported |
| M5 | Real dials vs counted attempts per target under a swallowed `OK` (S18) and a dead relay (S25); confirm latency under S18 | soak, injected clock | real dials vs B0 and B1 within band; confirm latency ≤ B1 + 30 s |
| M6 | Durable rows after N simulated hours: fanouts by kind and status, Welcome records, KeyPackage bundles, Haven ledgers | soak S16 new "fanout rows" arm and S18 | no growth after steady state (fails on C1 unless U1 is in) |
| M7 | Records visited per drive | adapter/scheduler counter | bounded by live records |
| M8 | KeyPackage publications per 30 simulated days | soak S12 | vs B0 and B1; the C10 delta is the listed entry |
| M9 | p99 wait of an FFI read (`circle_recovery`, `members`) issued during a drive | `lock_hold_e2e` | ≤ M3's "with input" bound |

### D.3 Responsiveness proof

`responsiveness_e2e::input_during_a_publish_takes_effect_before_the_relay_answers` (paused time): scripted relays
accept the socket and never send `OK`; a foreground drive publishes an invite commit; while that attempt is in
flight the test issues, through the `SessionManager` methods the bridge calls, a change on another circle
(`remove_members_driven`) and a read (`circle_recovery`); both return within `PREEMPT_GRACE` + one engine step
of virtual time; the removal is staged (record exists, circle reads `AwaitingRelays`); the invite's cut attempt
is `PossiblyExposed` and not rolled back; after the relay answers, both commits confirm. Companions:
`…a_peer_location_arriving_mid_drive_is_taken_in_after_at_most_one_grace`, and
`…an_off_gate_read_during_a_long_convergence_pass_returns_within_bound` (the shared connection serialises reads
behind engine transactions).

---

## E. Upstream asks, ranked (for the owner to file)

Ranked HIGH first, then by how much of the migration each unblocks. Each is one issue.

1. **U2 — re-issue policy.** Let a host veto re-issue per superseded intent kind (e.g.
   `ReissuePolicy { removals: Report }` on `SessionConfig`), or add a join-epoch / leaf-generation field to
   `Member` so a re-issued `RemoveMembers` skips a member invited back since. Undoes **C2** (HIGH), C21, C22;
   unblocks 2.2. Row T-REISSUE.
2. **U1 — application-message fanout end.** End an application-message fanout at its NIP-40 expiration
   (`OutboundApplicationMessage.retention`): mark outstanding targets terminal, report it expired, delete the
   record, and never count it as a barrier in `resume_outbound_fanouts_for_group` or
   `queued_outbound_intents_blocked_by_fanouts`. Undoes **C1** (HIGH) and the C1a/C24a/C25a seam refusals;
   unblocks 2.4 and the last exception site. Row T-APP-FANOUT-END.
3. **U6 — rollback retires its row.** Have `publish_failed` move the rolled-back commit's own stored row from
   `Sent` to `Failed` in its rewind transaction. Undoes C3's dependence on the closed window (and its HIGH if
   R0 = no). Row T-ROLLBACK-RESURRECT.
4. **U4 — detached group-fanout task.** Expose a public detached group-fanout task (prepare under `&mut self`,
   run with no engine borrow, finish under `&mut self`) like `PreparedWelcomePublishTask` (`RT:278-318`), and
   un-hide both. Undoes C4a/C4b and most of §A.4. Row T-LOCK-HELD-IO.
5. **U5 — inputs-only advance.** Forward `advance_convergence_inputs` on `AccountDeviceRuntime`, publishing
   nothing the engine did not already stage. Undoes C5a's seam refusal, C5b, C6. Row T-NO-INPUTS-ONLY.
6. **U3 — fanout end policy.** Let the host end a frozen fanout's remaining targets after MLS confirmation by
   acknowledgement count or age, and undo a never-exposed pending non-removal commit after a host-set age (a
   `FanoutEndPolicy` on `TransportRoutingPolicy`). Undoes C7a, C7b, C8. Row T-FANOUT-END.
7. **U13 — attempt counting.** Let an adapter answer "not attempted" without the runtime counting an attempt
   (or mark the attempt at hand-over). Undoes C19b and C18's counter inflation. Row T-GATE-BEFORE-MARK.
8. **U17 — KeyPackage refresh policy.** Let the host set the refresh interval within the lifetime
   (`SessionConfig::key_package_refresh_window(min, max)`). Gives owner item O4 back its choice (C10).
9. **U7 — KeyPackage grace.** Add `SessionConfig::key_package_replacement_grace(Duration)` that may only shorten
   `KEY_PACKAGE_REPLACEMENT_GRACE_SECS`. Undoes C9. Row T-KP-RETENTION.
10. **U10 — effects beside a confirm error.** Return the effects already emitted beside a confirm error (an
    `AccountError` variant carrying `AccountDeviceEffects`). Undoes C14. Row T-CONFIRM-ERR.
11. **U9 — seal-only application entry.** Add `prepare_app_message` / `publish_prepared_app_message`. Undoes C13.
12. **U8 — KeyPackage hold.** Hold a KeyPackage's replacement while a Welcome naming it awaits the host's accept,
    instead of the host pausing all maintenance. Replaces C11's pause. Row T-KP-HOLD.
13. **U14 — convergence clock.** Forward `EngineBuilder::convergence_clock` through `SessionConfig`. Row
    T-CONVERGENCE-CLOCK.
14. **U11 — test hook.** Gate `arm_finish_stage_failure` (`RT:633-639`) behind
    `cfg(any(test, feature = "test-support"))`. Row T-FINISH-STAGE-HOOK.
15. **U12 — recorder swap.** Make installing a recorder on a running session (`SharedRecorder::swap` via
    `audit_recorder()`, `RT:678`) require an explicit feature. Retires the recorder tokens of
    `check_no_forensic_recorder.sh`.
16. **U15 — stable host contract.** Document that `receive`, `activate_account`, `sync_account_groups`,
    `deactivate_account` are optional for hosts that feed `ingest_delivery`, and that
    `TransportEndpointFailureKind`'s rules (incl. sticky exposure) are host contract. Turns Stage 2's canaries
    into contract tests.
17. **U16 — KeyPackage publisher.** Say where `KeyPackagePublisher` is going before changing it, and keep
    `legacy_slot_id` import semantics. Row T-KP-PUBLISHER-PROVISIONAL.

---

## F. Risks, ranked

| # | Risk | Likelihood / impact | Caught by | Mitigation |
|---|---|---|---|---|
| 1 | C1 or C2 conceded without the owner seeing them | — / HIGH | §0 first; 2.2 and 2.4 preconditions | rulings before 2.0 |
| 2 | Leftover location rows wedge circles after an ordinary update | MED / HIGH | 2.2a upgrade tests on all three fixtures | the retirement step ships and stays |
| 3 | Runtime internals change silently at the next bump (sticky exposure `TA:684-688`, barrier rule `RT:4569-4585`, retry constants `RT:117-128`, `run_due_maintenance` content, re-issue timing, "drain runs no pass" `RT:4246-4252`) | MED / HIGH | canaries and the constants drift test (2.2) | bump checklist re-reads `RT:5643-6010`, `RT:2511-2990`; U15 |
| 4 | R0 = no | MED / HIGH | — | C3 HIGH: 2.2 waits for U6 |
| 5 | The `runtime-flip` switch outlives 2.2 | LOW / MED | `compile_error!` in release; the 2.2 guard step | merge only at the final commit |
| 6 | Two drivers on one row during transition | — / HIGH | 2.0 guard bans runtime publish entries until 2.2; 2.2a moves locations off the table | §C order |
| 7 | The retirement step deletes a runtime-written application row | LOW / MED | `…no_application_row_exists_before_the_first_send_after_open` | marker written before the first drive |
| 8 | `KeyPackagePublisher` changes shape | HIGH / LOW | compile error in one file | §A.6 isolation; U16 |
| 9 | `arm_finish_stage_failure` or `SharedRecorder::swap` reached | LOW / MED–HIGH | source guards (Stage 1, 2.0) | U11, U12 |
| 10 | MDK `master` after v0.16.0 (25 commits; `durably_owned_key_packages` fails instead of "not owned"; read-snapshot methods) | LOW / LOW-MED | `Err` handled as "unknown" (2.1 test) | adopt the read snapshot at the next bump |
| 11 | Dropped runtime future (cancel-safety UNVERIFIED) | — / HIGH if done | guard: no `select!`/`timeout` around a runtime call | bound through the adapter only |
| 12 | Routing cache stale at a commit's staging | MED / MED | `fanout_change_e2e::a_relay_change_commit_is_sent_to_the_relays_of_the_epoch_it_leaves` | refresh in the same lock hold |
| 13 | Rewrite of ≈ 46,700 test lines | HIGH / MED | reviewers check "promise kept or replaced per §B" per family commit | the dual path |

---

## G. Not determined (UNVERIFIED)

- Whether the runtime adopts Haven's KeyPackage lifecycle row and slot without `legacy_slot_id` (2.1 fixture
  test decides).
- Whether a Stage-1 Haven-driver commit row is driven by the runtime exactly as its own (S2-fixture item 2, 2.2).
- Whether a later `drain` re-delivers what a failed confirm dropped (C14's severity).
- Whether a location sealed through the exception site (C1 option (b)) leaves any runtime-visible record
  (`a_location_sealed_through_the_exception_site_leaves_no_runtime_record`, 2.2).
- Whether hydration in `AccountDeviceRuntime::open` runs a convergence pass before Haven's first gated call
  (Rule 13.5 ordering; believed unchanged).
- Cancel-safety of dropping a runtime future.
- Whether relays in `PRODUCTION_LOCATION_RELAYS` answer `duplicate:` or `invalid:` to a re-sent expired kind 445
  (only matters if R0 = no; a dry probe measures it).
- Which adapter feature exports `NostrKeyPackagePublication`.
- The bound on recovery records written by group-recovery ingest (C20).
- Cargo's resolution of a dev-dependency-only `test-support` on the normal graph (2.5 self-test).
- Every effort and line figure.

---

## Appendix: Review ledger

Source ids: *Eng*, *Sec*, *Data*, *Tests* name the four independent reviews (engineering, security, data integrity, tests and CI) and their finding numbers; *R1–R6* name the binding rulings made on those reviews; D and O items are the owner's (master §2–§3); *Fix-check* rows come from the independent check that each required change landed.

| Source | Finding | What changed |
|---|---|---|
| Rulings R1.a | Merges are pushed green series at sub-stage boundaries | Conventions; §C |
| Rulings R1.c | Effort in build cycles | Every sub-stage's cost line; total |
| Rulings R3.a / tests HIGH-2 | Baselines from v0.10.4, not only Stage 1 | §D.2 two baselines B0/B1 |
| Rulings R3.i | Flutter is local | §C local gate; every FFI/Dart/l10n line |
| Rulings R4.a / security M1 | Oversized Welcome refused at the pre-fork limit | Row C28: the Welcome signer keeps the edge; §A.2 `size_class_over_known_limits` is not relied on for it |
| Rulings R4.c / security M5 | R0 honest only from heard `OK false` frames | §0.1 proof, `WireVerdict`, guard, five tests |
| Rulings R4.f / engineering H1 | Ban constructing `StepDownAndLeave`, no `.swap(` | 2.0 adds nothing to the recorder guard; 2.2 lifts the construction ban for the leave entry only |
| Rulings R4.f, R5 / engineering H2(b), X1, W4 | Stage 1 has no `--require-empty`; per-function list from 2.0 | §C.0; the wrong premise corrected |
| Engineering H2(c), X3 / R5.a | Merge rule contradicts D1 and is unreachable under C1 (b) | Each sub-stage merges green; `--require-empty` is the 2.5 exit check; (b) exits with one entry |
| Engineering X2 / R4.f | One tracker row `T-SESSION-PRIVATE`; no `T-RUNTIME-MIGRATION`; no duplicate `T-FINISH-STAGE-HOOK` | §C.0; 2.0 tracker list |
| Engineering M4 | 2.2 cannot be green per PR | §C 2.2 dual path, switch spec, guard, "not a shim" argument |
| Engineering M5 / data HIGH-1 / R5.b | No Stage-1-release fixture; migration deleted before it ships | S2-fixture step with required contents; retirement step ships and stays, every opener, idempotent, marker ordering |
| Engineering M8 / R4.g | Deferred Stage-1 work | 2.1 O4 cadence; 2.3 parity holds and T-SCHEDULER arms (2)–(4) |
| Engineering M12 | Shared-file ownership | One sub-stage edits each shared file at a time (sequential sub-stages) |
| Engineering M13 | 2.5 resolved-feature check fails on soak | 2.5 scoped to shipped roots; soak via `test-utils`; dev-dependency self-test |
| Engineering X13 | Recorder-guard tokens owned by Stage 1 | 2.0 adds none |
| Engineering X16 | "Stage 0 fixture carries over unchanged" | Corrected: assertions carry over; driver calls rewritten where deleted |
| Engineering A6 | `expected_epoch` pin available at v0.10.4 | Row C23 notes it may already be done in Stage 1 |
| Engineering A7 | Ban `SessionConfig::new(` | Banned from Stage 1 (Stage 1b §2.4); 2.0 keeps it |
| Data HIGH-1 crash point 11 | Cross-DB step must be idempotent | §A.9 ordering table; end-all, nothing moved |
| Data §3 F / R5.d | Haven stores and two-DB atomicity | §A.9 |
| Data advisory | Shared connection serialises off-gate reads | D.3 third test; §A.1 |
| Data MEDIUM-2 | Silent first-open outcomes | S2-fixture assertions (bundle count, quarantine) |
| Data "could not verify" (runtime and `retention.expires_at`) | — | Moot: leftover rows are retired before the runtime opens |
| Security C1, C2 confirmed HIGH / R5.c | Owner rulings | §0.2, §0.3 with options and recommendations; C2 option (b) shown unavailable |
| Security C21 LOW confirmed | — | Row C21 stays CONCEDED, LOW evidence cited |
| Security M4 | Weekly refresh cost unstated | Row C10 states both sides; O4 ruling; U17 |
| Security A9 | NIP-11 fetch | No fetch; adapter may import no HTTP client (guard) |
| Tests M13 / R3.a | "Exactly" on fault-timed arms flakes | Exact only on deterministic arms; S0.9 bands elsewhere |
| Tests M9 | Exit checklist | 2.2 and 2.4 exits record run ids, E2E twice, flake baselines |
| Tests advisory (`syn`) | Textual parsing limits | §C.0 states the textual rule and its self-test fixtures |
| Rulings R6 O4, O7, O8 | Owner items in Stage 2 | C10 (O4), 2.3 T-EPOCH-STALL (O7), C27 (O8, keep hand-off) |
| Engineering advisories A1–A5, A8–A10; security A1–A8, A10; data advisories on S0.2 and 0174 | — | Not applied here: they concern Stage 0 or Stage 1 |
| Fix-check: openers | The retirement step's opener list named plane standings, not openers | §A.1 and 2.2a name every `CircleManagerFfi::new` caller as Stage 1b §9.3 does; `STORE_GENERATION` is not bumped, so background openers run the step |
| Fix-check: C10 veto | C10 lands in 2.1, but a veto held 2.3 | A veto holds 2.1 for U17 |
| Fix-check: `SessionConfig::new(` | Listed as a new 2.0 ban, but Stage 1 already bans it | Stated as kept from Stage 1 |
| Fix-check: NIP-44 row | Named by ruling, not by tracker row | `T-NIP44-WELCOME-CEILING` (Stage 1a's row) |
| Fix-check: risk ids | §F's R1–R13 collided with ruling R0 | §F rows numbered 1–13 |
| Fix-check: estimates | Cost lines carried no ESTIMATED tag | Every cost line tagged; conventions say which figures are measured |
