# Stage 1b: MDK v0.10.4 → v0.16.0, session side, with Haven's fanout driver kept (D1)

Scope: the MDK session, engine, storage, peeler and traits side of Stage 1, and the database
upgrade. Stage 1a owns the rust-nostr fork, the relay pool, Rule 16's client, the `user-agent`
header, the relay URL policy (including the `.onion` refusal), NIP-77, the fanout refusal proof and
the NIP-44 Welcome ceiling. Stage 2 owns the move onto `AccountDeviceRuntime`. This part names those
only as interfaces.

The order of work follows the master sequence (steps 12 to 20) in
[`docs/MDK_V016_MIGRATION_PLAN.md`](../MDK_V016_MIGRATION_PLAN.md) §4. Owner decisions D1 to D4 and
the owner items O1 to O13 (§8; master §2–§3) bind this plan. Where an owner item is still open, its
stated default applies. Sibling parts: [`stage0.md`](stage0.md), [`stage1a_nostr.md`](stage1a_nostr.md),
[`stage2_runtime.md`](stage2_runtime.md), all in `docs/mdk-v0.16/`.

Unit ids C1–C18 are this part's own. Stage 2's C1–C28 are concession ids and are always written
"Stage 2 C…" here.

**Citations.**

- `M16:` = MDK `crates/…` at tag v0.16.0 (`a2e0558a`).
- `M10:` = the same at v0.10.4 (`fcc85edd`).
- Unprefixed paths are repository paths. Haven line numbers drift, so the symbol named beside a line
  number is authoritative.

Every MDK claim was re-read in source. **UNVERIFIED** marks anything that was not. Figures that
nobody has measured are tagged **ESTIMATED**.

**Effort is counted in build cycles**, measured on the 4-core build machine:

| Cycle | What it is | Duration |
|---|---|---|
| **C** | `cargo check --all-targets` | ≈ 3.5 min |
| **S** | full haven-core suite | ≈ 30 min |
| **F** | Flutter `analyze` + `test` | ≈ 25 s + ≈ 4 min |
| **K** | full coverage gate | ≈ 31 min |
| **T** | one targeted test binary, built and run | ESTIMATED 3–8 min |

Engineer-days appear only as a secondary, ESTIMATED total.

---

## 1. Decisions this part takes

| # | Question | Decision | Where |
|---|---|---|---|
| 1 | How Haven reaches the session | `AccountDeviceSession::open(SessionConfig::with_storage(..))`, directly. No `AccountDeviceRuntime` anywhere in Stage 1 source. | §2.2, 16.3 |
| 2 | `wrap_group_recovery` | Fail closed with fixed text. Never delegate. | §3, 16.5 |
| 3 | Malformed-slot repoint | Replaced by MDK's model: a new KeyPackage into the slot, never a second signature over one package. | C2 |
| 4 | KeyPackage refresh | O4 default: keep rotating at 0.75 of the package's lifetime (now 30 d → day 22.5). MDK's stored `refresh_at` is set to that same instant (C3). The 6–7 day refresh moves to Stage 2.1. | C3 |
| 5 | First open after the upgrade in the background | O1 default: the open is gated on a Haven build-constant marker. Background sharing pauses until the first foreground open. | 16.3; §9.3 |
| 6 | A store the new build cannot open | O2 default: a typed outcome, never an automatic reset. `StoreNoSpace` is distinguished from the other failures. | 16.3; §9.5 |
| 7 | Cross-circle duplicate pending refs (C12(b)) | Not producible between two rows v0.10.4 restored; possible only for a row v0.10.4 left unrestored (a quarantined group) that v0.16.0 restores (step 16.3). The re-key is dropped. A fail-closed detector, scoped to the refs hydrate binds, refuses the open instead. | 16.3 |
| 8 | Forged-signature kind 445 | Dropped as if withheld. It stays refetchable and is never terminal `Malformed`. | C15 |
| 9 | Deferred-peel caps (O6) | MDK v0.16.0 offers no supported way to set them. Recorded as `T-PEEL-CAP-4X` with an upstream ask, and listed for the owner. | C10 |

### Resolved from source: three open questions

**(a) Can any producer reachable under Haven's configuration emit `PublishWork::AutoPublish` with
non-empty `welcomes`? No.** The engine fills `auto_publish_buf` at five sites:

| Producer | Site | `welcomes` |
|---|---|---|
| Replay rotation | `M16:cgka-engine/src/maintenance.rs:309` | Always empty. It is `SendIntent::SelfUpdate`, built with `consume_proposal_store(false)` and returning `welcomes: Vec::new()` (`M16:cgka-engine/src/self_update.rs:1-5, 165, 255-257`). |
| Eviction / self-removal commit | `M16:cgka-engine/src/message_processor/ingest.rs:2251` | `Vec::new()` |
| Leave step-down | `M16:cgka-engine/src/message_processor/send.rs:1397-1435` | Staged by the leave re-drive (`auto_repropose_leave_request`, `send.rs:1340-1346`) for any stored leave request whose account is an admin among two or more (`next_leave_step`, `:1374-1386`). That covers `SendIntent::StepDownAndLeave`, which Haven never constructs, **and** a plain `Leave` if the account is re-promoted before its SelfRemove commits (Haven demotes itself before leaving, `circle/leave.rs` `LeavePlan`). Either way the commit is an isolated component update that keeps every pending proposal (`PendingProposals::Keep`, `:1424-1427`; `M16:cgka-engine/src/update_group_data.rs:90-103`), so it commits no Add. |
| Hydration of a durable evolution | `M16:cgka-engine/src/engine.rs:2778, 2825` | Non-empty only when the evolution is `RecoverMembers` (`:2705-2716`). That evolution is written only by `prepare_member_recovery` (`M16:cgka-engine/src/maintenance.rs:143`), which is called only for `SendIntent::RecoverMembers` (`M16:cgka-engine/src/message_processor/send.rs:435-440`). Haven never constructs that intent either. |

C1 still records whatever the engine hands over, so the fanout record is true. Its red test is
type-level. §2.4 bans constructing `RecoverMembers` together with the other two intents, so "never
constructed" is enforced rather than merely observed.

**(b) Could the replay-rotation self-update commit a peer's pending Add, so that Haven's Welcome path
addresses an invitee the user did not choose? No, on two independent grounds.**

1. The rotation never commits pending proposals: `consume_proposal_store(false)` and
   `force_self_update(true)` (`M16:cgka-engine/src/self_update.rs:163-166`), as `SendIntent::SelfUpdate`
   documents ("leaves the proposal store untouched", `M16:traits/src/engine.rs` doc above
   `SelfUpdate`).
2. Even if a Welcome reached Haven's confirm-time hand-over, Haven sends a post-confirmation Welcome
   only along a route its own invite path recorded for that recipient. With no route, it sets
   `reinvite` and sends nothing (`haven-core/src/nostr/mls/manager.rs` `hand_over_welcomes`, the
   `commit_notes.welcome_route(..)` lookup ≈ `:8066-8075`). A route is written only from the
   KeyPackage the user picked (`circle/manager.rs` `route_welcomes_with_cascade`, ≈ `:854-905`).

Stage 1 therefore needs no fix here, only a pin:
`self_update_e2e::a_replay_rotation_never_commits_a_peers_pending_proposal` (16.5).

**(c) Does any background drive run `Full`? No.**

- `relay::fanout::Claimed::new` decides `Full` only for `foreground && bridge_may_commit()`
  (`haven-core/src/relay/fanout.rs` ≈ `:620-631`).
- The background sweep `run_catchup_all_circles` passes `DriveMode::FinishOnly`
  (`haven-core/src/relay/catchup.rs` ≈ `:1453-1463`).
- `Full` is reached only by `run_catchup_in_foreground` and foreground-claimed drives.

So O5 ("the replay rotation may ride a full background drive") does not arise in Stage 1. In a
background wake a replay rotation can be staged only by a location send, and Haven rolls it back
unsent (C6).

### Corrections made in review

- `migration_summary()` returns `(migrations applied in this open, duration)`
  (`M16:storage-sqlite/src/protocol/handle.rs:50-53`). It is not a schema version. §9.3 replaces the
  marker design that relied on it.
- C12(b)'s premise was false. v0.10.4's `restore_pending` raises the ref counter past every restored
  ref (`M10:cgka-engine/src/epoch_manager.rs:212-221`). It does not reserve the ref of a row it never
  restores (an `unrecoverable` group, `M10:cgka-engine/src/engine.rs:2080-2083`, or one quarantined
  before the restore), and a `Confirmed` evolution keeps its old ref for good (`M10:cgka-engine/src/publish.rs:246-247`).
- C15's "terminal `Malformed`" was wrong. A Schnorr signature is not covered by the event id, so a
  forged-signature copy shares the genuine copy's id.
- C5 presented the weekly refresh as privacy-positive only. It also publishes a "device alive" signal
  about 52 times a year instead of about 16 (O4).
- Token bans on `StepDownAndLeave`, `EnableAccountDevices` and `.swap(` collided with required
  exhaustive arms and with Haven's own atomics. They are replaced in §2.4.
- The per-file counts and the ratchet against `origin/main` could not be bootstrapped. They are
  replaced by a file allowlist (§2.4).
- Flutter, `flutter_rust_bridge_codegen` 2.11.1 and FRB regeneration run locally. Only the
  emulator and simulator lanes, cross builds, build-check and release-link need GitHub CI.
- "Forbid `transport-nostr`, `nostr-directory`, `marmot-pairing`" is subsumed by the MDK allowlist
  that Stage 0 builds and Stage 1a fills in. That item is dropped.
- C17 (NIP-77 constants) and the `.onion` refusal belong to Stage 1a, and C17 has no residue here.
  The 6–7 day refresh, the T-MAINT-DRIVER holds, T-SCHEDULER arms 2–4 and the T-EPOCH-STALL seeding
  move to Stage 2 (§7).

---

## 2. The guarded exception (step 12)

### 2.1 What `test-support` enables

`M16:marmot-session/Cargo.toml` declares `test-support = []` ("Enable only as a dev-dependency").
It forwards nothing. The feature gates:

- the re-export `pub use session::{AccountDeviceSession, IngestEffects}`
  (`M16:marmot-session/src/lib.rs:41-44`);
- `AccountDeviceRuntime::new`, `session()` and `session_mut()` (`M16:marmot-session/src/runtime.rs:591-594, 665-674`);
- `#[cfg_attr(.., allow(dead_code))]` on seven session methods, among them `ingest`, `epoch` and
  `fresh_key_package`, which Haven calls (`M16:marmot-session/src/session.rs:593, 601, 706, 794, 1384, 1875, 2107`).

Present in every build, with or without the feature:

- `AccountDeviceRuntime::arm_finish_stage_failure` (`runtime.rs:633-639`);
- `audit_recorder() -> &SharedRecorder` (`runtime.rs:676-680`, `session.rs:2125`).

The other features (`dev-device-groups`, `test-policy-overrides`) must never resolve on.

### 2.2 Why the session directly, not the runtime

1. `AccountDeviceRuntime::open` needs a `TransportAdapter`, a routing policy and a KeyPackage
   publisher (`runtime.rs:577-587`). Building them is Stage 2's first work.
2. A runtime that exists but is never driven holds in-memory group state that the session never
   updates (`runtime.rs:604-632`). It would be a second source of truth.
3. What carries over to Stage 2 is the `SessionConfig`. Stage 1 builds exactly the config that
   `AccountDeviceRuntime::open` will take (`with_storage`, 16.3).

### 2.3 Cargo shape

- `haven-core/Cargo.toml` gets
  `marmot-session = { git = MDK, rev = "a2e0558a…", features = ["test-support"] }`, with a comment
  naming `T-SESSION-PRIVATE` and the guard. It is the only edge that enables the feature.
  `haven/rust_builder` and `tooling/soak` receive it through haven-core.
- `cgka-engine` stays a direct dependency. Its resolved feature set must be empty.

### 2.4 Guards

**`scripts/ci/check_private_session_exception.sh` (new).** A static half runs in `repo-guards.yml`
and a `--resolved` half runs in `rust-check.yml` beside `check_mdk_supply_chain.sh --adapter-features`.
Its data file, `scripts/ci/private_session_exception.txt`, holds:

```text
# Stage 1 exception (D1). Removal condition: docs/MDK_UPSTREAM_TRACKER.md T-SESSION-PRIVATE.
feature marmot-session test-support haven-core/Cargo.toml
file haven-core/src/nostr/mls/manager.rs
file haven-core/src/circle/manager.rs
…   (one line per production file whose CODE names AccountDeviceSession or IngestEffects)
```

Every step runs even if an earlier one failed.

1. **Feature lines.** Across every `Cargo.toml` of the Cargo roots, a `test-support`, `dev-device-groups`,
   `test-policy-overrides`, `test-crash-hooks` or `test-conformance-*` feature on any MDK crate
   fails, unless it matches a `feature` line. A `feature` line with no matching edge also fails.
2. **Resolved features** (`--resolved`). For each root that resolves `marmot-session`,
   `cargo tree --locked -e normal,build -i marmot-session -f '{p} {f}'` must print exactly
   `default,test-support` while the file has the `feature` line, and exactly `default` once it does
   not. `-i cgka-engine` must print exactly `default`. Any of the dev or test features above anywhere in the
   resolved normal graph fails. This reuses the parsing helpers of `--adapter-features`.
3. **File allowlist.** `\bAccountDeviceSession\b` and `\bIngestEffects\b` may appear in code lines
   only of listed files under `haven-core/src`, `haven/rust_builder/src` and `tooling/soak/src`.
   Comment lines (`//`, `///`, `//!`) do not count. A listed file whose code no longer names either
   type also fails, so the list shrinks with the code. `tests/` directories are exempt. There is no
   git-base comparison.
4. **Bans in shipped source** (the same three trees, as a plain token scan):
   `AccountDeviceRuntime` (Stage 2 relaxes this deliberately), `arm_finish_stage_failure`,
   `session_mut(`, `with_maintenance_timing`, `set_convergence_policy`, `advance_group_recovery`,
   `run_due_maintenance`, `ACCOUNT_DEVICES_COMPONENT`, `transport_nostr::`, `marmot_app`,
   `SessionConfig::new(` (Haven's own `SqliteAccountStorage` open stays the only opener and keeps
   the first-use gate), `deferred_peel_limits`, and any `account_projection` or `SqliteAppStorage`
   write method other than the five reconciliation-inventory calls. The last one prevents turning on
   release journaling that Haven never drains.
5. **Construction ban.** It stops Haven from ever *constructing* `SendIntent::StepDownAndLeave`,
   `SendIntent::EnableAccountDevices` or `SendIntent::RecoverMembers`, while it may still *match* on
   them. Two patterns are used, and the variant names may appear in patterns:

   ```bash
   # (5a) A struct expression not followed by a pattern continuation (=>, |, an `if` guard, or a
   #      single = as in `let PAT = v`). Braces are matched recursively, so nested literals are caught.
   grep -rPzo --include='*.rs' \
     'SendIntent::(StepDownAndLeave|EnableAccountDevices|RecoverMembers)\s*(?<b>\{(?:[^{}]++|(?&b))*\})(?!\s*(=>|\||if\b|=(?![=>])))' \
     haven-core/src haven/rust_builder/src tooling/soak/src
   # (5b) Spellings that would let a construction hide from (5a): a glob, brace or single-variant
   #      import; an alias; and a Haven trait implemented for SendIntent, where `Self::Variant {..}`
   #      constructs.
   grep -rnE --include='*.rs' 'use [^;]*SendIntent::(\*|\{|StepDownAndLeave|EnableAccountDevices|RecoverMembers)|SendIntent as [A-Za-z_]|type [A-Za-z_]+ *= *[^;]*SendIntent\b|impl\b[^{;]*\bfor +([A-Za-z_]+::)*SendIntent\b' \
     haven-core/src haven/rust_builder/src tooling/soak/src
   ```

   S0.5 lets `matches!`, `if let` and comparisons over MDK enums stand only on a line marked
   `// mdk-enum-reviewed:`. A pattern of these three variants nested inside another pattern or a macro
   (`Some(SendIntent::RecoverMembers { .. }) =>`, a tuple pattern, `if let Some(PAT) =`, `matches!(i, PAT)`)
   is followed by `)` or `,`, so (5a) flags it: a fail-closed false positive, rewritten as a `match` on
   the intent itself. A construction by deserialization (`serde` into a `SendIntent`) is invisible to any text
   scan; Haven never deserializes one (it reads queued intents only through MDK), and C7's behaviour
   pins below are the backstop.
   Self-test fixtures, one per case:

   | Fixture | Expected |
   |---|---|
   | `send(SendIntent::StepDownAndLeave { group_id })` | fail |
   | `let i = SendIntent::EnableAccountDevices { group_id: g.clone() };` | fail |
   | `SendIntent::RecoverMembers { group_id, members: vec![GroupMemberRecovery { .. }] }` (nested) | fail |
   | `SendIntent::StepDownAndLeave { group_id } => None,` | pass |
   | `\| SendIntent::EnableAccountDevices { .. }` (or-pattern) | pass |
   | `SendIntent::RecoverMembers { .. } if x =>` | pass |
   | `let SendIntent::StepDownAndLeave { group_id } = i else {` | pass |
   | `use cgka_traits::SendIntent::*;` | fail (5b) |
   | `use marmot_session::SendIntent as Intent;` | fail (5b) |
   | `use cgka_traits::engine::SendIntent::StepDownAndLeave;` | fail (5b) |
   | `impl HavenIntentExt for SendIntent {` | fail (5b) |
   | `Some(SendIntent::RecoverMembers { .. }) =>` | fail (5a; rewritten as a nested `match`) |

   The behaviour is pinned as well: C7's tests assert that no Haven KeyPackage or circle advertises
   or requires 0x800d.
6. **`--self-test`.** `SELF_TEST_FIXTURES` is pinned. The fixtures cover:
   - a planted extra edge (step 1);
   - a resolved `dev-device-groups` (step 2);
   - an unlisted file naming the type in code (step 3), and a doc comment naming it, which must pass;
   - a listed file with no use (step 3);
   - each banned token (step 4);
   - the table above (step 5).

**`check_no_forensic_recorder.sh`, edited by this part only in Stage 1:**

- keep `ForensicRecorder`, `JsonlRecorder`, `marmot_forensics`, `.recorder(` and Stage 0's
  `recorder:\s*Some`;
- add `audit_recorder(` and `SharedRecorder`, the only ways to reach `SharedRecorder::swap`;
- drop the dead tokens `set_recorder` and `set_audit_recorder`;
- add no `.swap(` ban;
- re-pin its self-test count.

### 2.5 Tracker row `T-SESSION-PRIVATE` (one row; Stage 2 updates the same row)

| Field | Content |
|---|---|
| **Gap** | `AccountDeviceSession` became private (mdk#2602, `M16:marmot-session/src/lib.rs:41-44`). Haven's Rule-13 driver needs `confirm_published_fanout`, `publish_failed_fanout`, `advance_convergence_inputs`, `ingest`, `epoch` and the fanout, Welcome and KeyPackage record accessors. The runtime forwards none of them. |
| **Mitigation (debt)** | the normal edge of §2.3 and the guard of §2.4 |
| **Next-bump risk** | `ingest`, `epoch` and `fresh_key_package` survive only as dead-code-allowed helpers (`session.rs:1384, 1875, 601`). |
| **Removal condition** | In every root, no non-dev edge enables `marmot-session/test-support` (guard step 2 prints `default`), and `private_session_exception.txt` holds no `feature` and no `file` line. Stage 2.0 redefines step 3 as a per-function list of `session()`/`session_mut()` call sites; `--require-empty` is the 2.5 exit check. |
| **Pin** | `security_rule_gates::the_private_session_is_reached_only_under_the_recorded_exception` reads the data file and `haven-core/Cargo.toml` and fails both ways. The guard's `--self-test` also pins it. |

The unconditional fault hook gets its own row, `T-FINISH-STAGE-HOOK`. Guard step 4 bans the hook.
The upstream ask is to gate it behind `test-support`.

---

## 3. Step 12: pins (this part's share; Stage 1a moves the revs, lockfiles and supply-chain values)

| Edit | Detail |
|---|---|
| `haven-core/Cargo.toml` | `cgka-session` → `marmot-session` with `features = ["test-support"]` (§2.3). Update the comments that name crates or revs. |
| `haven-core/src/nostr/mls/storage.rs` `test_sqlcipher_key()` | At v0.16, `SqlCipherKey::new` rejects the raw `x'…'` form (`M16:storage-sqlite/src/base/connection.rs:1226-1247`), so every test-utils open would fail at runtime. Replace the string constant with `const TEST_SQLCIPHER_KEY_BYTES: [u8; 32] = [0x01, 0x23, 0x45, 0x67, 0x89, 0xab, 0xcd, 0xef, …×4]` and `Ok(SqlCipherKey::raw(TEST_SQLCIPHER_KEY_BYTES))`. `raw` renders the identical `x'0123…'` PRAGMA (`connection.rs:1257-1268`), so committed SQL fixtures still import. This is the only call site. The production 64-hex passphrase (length 64) is still accepted by `new`. |
| Guards | `check_private_session_exception.sh` plus its data file and self-test; the `check_no_forensic_recorder.sh` edits (§2.4); `check_sqlcipher_first_use_gate.sh` opener list (keep `SqliteStorage`, which still exists as an alias at `M16:storage-sqlite/src/protocol/handle.rs:31`; add `open_encrypted_observed`, `in_memory_for_test`, `open_hardened_sqlcipher`); the `repo-guards.yml` and `rust-check.yml` steps. |
| `T-SESSION-PRIVATE` | A stub row: gap, mitigation and removal condition (full text at step 18). |

**Green:** `cargo metadata --locked` in every root, and every guard with `--self-test`. The tree does
not compile yet; the compile red window opens here.

**Cycles:** none for compiling; guards only.

---

## 4. Steps 13–14: compile-only sweep (session side)

Every edit in this section is a **mechanical port that keeps today's semantics**. Where a break
hides a behaviour decision, the sweep keeps today's behaviour, and the decision lands later as a
red→green pair in step 16.

**File ownership** follows the master order (one editor per shared file):

- `haven-core/src/nostr/mls/*` belongs to 1b, after 1a's scripted import commit.
- `haven-core/src/relay/fanout.rs` belongs to 1a until CP-T, then to 1b.

### 4.1 `haven-core/src/nostr/mls/manager.rs`

| Site | Break | Mechanical port | Semantic follow-up |
|---|---|---|---|
| imports, every `cgka_session::` | crate renamed | `marmot_session::{AccountDeviceSession, IngestEffects, SessionConfig, SessionEffects, SessionError, PublishWork, QueuedIntentRef, CreateGroupEffects}`; prefer the session's re-exports (`lib.rs:47-54`) over `cgka_engine::` paths | — |
| `impl MdkErrorKind for SessionError` | `SessionError::Storage` removed (`session.rs:79-108`) | `Self::Engine(e) => e.kind()` | — |
| `SessionError::Storage(..)` constructions | removed | `SessionError::from(storage_error)` (`session.rs:81-90`) | — |
| `impl MdkErrorKind for StorageError` | `+InvalidAttachmentBody(&'static str)` (`M16:traits/src/storage.rs:45-48`) | `=> "storage_invalid_attachment_body"`; the test `every_storage_error_crosses_as_its_own_fixed_code` gains the variant | — |
| `event_group_id` (exhaustive) | `GroupEvent` +4 (`M16:traits/src/engine.rs:796-845`) | arms → `Some(group_id)` | what Haven does on each event: 16.5 |
| `intent_group`, `group_change_of` | `SendIntent` +12 | `intent_group` → `Some(group_id.clone())`; `group_change_of`: epoch-moving kinds count as a group change, `StepDownAndLeave` → `None` like `Leave` | none: Haven constructs none of them (§2.4) |
| `changes_group` | already an exhaustive `match` after S0.5; new variants break it | arms mirror `is_fair_scheduled_intent(intent, false)` (`M16:cgka-engine/src/message_processor/mod.rs:4586-4638`): the 15 unconditional kinds → `true`; `Add/RemoveOwnAccountDevices` → `false` (no Haven circle requires 0x800d, D3); `AppMessage`, `Leave`, `SelfUpdate`, `StepDownAndLeave` → `false`. Re-point the pin `security_rule_gates.rs` (≈ `:5359`) at `fn is_fair_scheduled_intent(` | none needed: the new kinds are never constructed, so no behaviour can differ (T-RESERVATION-READ) |
| `PublishWork::AutoPublish { msg, .. }` recorded with `&[]` | `AutoPublish.welcomes` (`session.rs:407-412`) | unchanged | C1 (16.4) |
| `stage_key_package_replacement(.., KEY_PACKAGE_REFRESH_LEAD_SECS, ..)` | argument now means refresh-*after* (`M16:cgka-engine/src/maintenance.rs:328-373`) | same constant passed | C3 (16.4) |
| `promote_key_package` marker | consumption moved (`M16:traits/src/maintenance.rs:534-588`) | unchanged | C4 (16.4) |
| `repoint_key_package_slot` | compiles | unchanged | C2 (16.4) |
| `record_transport_reconciliation_item(&route,&item)` | removed | `store.app_storage().record_reconciliation_items(std::iter::once((&route, &item)))` (`M16:storage-sqlite/src/cross/handles.rs:105`; `…/app/transport/transport_reconciliation.rs:150`). **Never** `record_held_reconciliation_items`: it filters on an app seen-index that Haven never fills (`:171`). | pinned in 16.3 |
| inventory and cursor reads | moved to `SqliteAppStorage` | prefix `.app_storage()` | — |
| `oldest_transport_secs` | `into_message() -> Option<TransportMessage>` (`M16:traits/src/message.rs:444-456`) | `None` → "no floor", the same fatal path as today's decode failure. Sibling-Welcome rows are produced only by device-group paths Haven never enables (guard step 2). | — |
| `leave_requested` (second-handle read) | compiles | unchanged | 16.3 |
| test-utils `delete_key_package` | removed from the session | use Haven's `delete_key_package_bundle(&message_store, ref)`; re-point the T-KP-EXPIRED-DELETE pin at `promote_key_package_lifecycle` with an expired retired package (`M16:cgka-engine/src/maintenance.rs:394-430`) | — |
| test using `audit_log_path()` | removed | Delete the assertion, and in the same commit add `security_rule_gates::no_audit_file_is_ever_written`: after an open/send/ingest/close cycle, the data directory holds only Haven's known file set. This keeps the promise without naming `SharedRecorder`. | — |
| test `GroupEvent::MessageReceived {..}` literals | `+sender_leaf_index`, `+encrypted_media_secret` | `None`, `None` | — |
| test `DurableConvergencePass {..}` | `+retry` | `retry: None` | — |
| `NostrMlsPeeler::new().with_welcome_signer(..)` (`manager.rs:1374`) | bound is now `MarmotNostrSigner` | compiles once 1a's `nostr` is the fork; the sweep keeps today's signer | 16.4: the construction becomes `with_welcome_signer_arc(LegacyNip44WelcomeSigner::arc(..))`. The signer lives in `nostr/mls/signer.rs` and is specified in [`stage1a_nostr.md`](stage1a_nostr.md) §C.8; this part owns `manager.rs` and commits the edit (`T-NIP44-WELCOME-CEILING`) |
| open | compiles (`SessionConfig::new` still exists, `session.rs:139`) | keep today's two-open shape | `with_storage`: 16.3 |

### 4.2 Peeler, types, relay layer, circle manager, tests

| Site | Break | Mechanical port |
|---|---|---|
| `nostr/mls/retention.rs` `impl TransportPeeler for RetentionBoundPeeler` | new required `wrap_group_recovery` (`M16:traits/src/peeler.rs:126-133`) | `Err(PeelerError::WrapFailed("group recovery is not sent by this client".into()))`, with a one-line comment naming `T-GROUP-RECOVERY`. Kind 1159 is never sent today, so failing closed *is* today's semantics. Delegating would let a future runtime publish an unrecorded MDK-private kind that the privacy manifest does not list (`M16:transport-nostr-peeler/src/lib.rs:36-49`). Tests: 16.5. |
| `accept_welcome` | `IngestOutcome::GroupRecovery` (`M16:traits/src/ingest.rs:18-20`) | explicit arm → `WelcomeAcceptance::NeedsNewInvite` (never reported as joined) |
| `relay/catchup.rs`, `relay/live_sync/processor.rs` (exhaustive `IngestOutcome`) | same | the plane's existing terminal-ignore arm; never formats `recovery` (Rule 15). Unreachable, because the planes refuse every non-445 first. |
| `nostr/mls/types.rs` `TransportEndpointFailure {..}` | `+size_class` (`M16:traits/src/transport_adapter.rs:1162-1173`) | `size_class: None` |
| `nostr/mls/types.rs` exhaustive `TransportEndpointRejectionCategory` | `+TooLarge` | `TooLarge => "too-large"` (a label; the proof semantics are 1a's) |
| `relay/fanout.rs` failure literals, test receipt | `+size_class`, `+ack_kind` | `None` |
| `NostrRelayClient` doubles | `unsubscribe_account(.., replacements: &[NostrSubscription])` | add the parameter (1a's adapter; listed so that neither part misses it) |
| `circle/manager.rs` `group_id_of` (exhaustive) | `GroupEvent` +4 | `Some(group_id)` |
| `circle/manager.rs` source-scan allow-lists (T-SECOND-HANDLE pins) | `.app_storage().…` spelling | Update the spelling, and add `SqliteAppStorage` to the reachable-surface enumeration of `the_sweeps_second_connection_touches_only_message_shaped_storage`. Widen nothing else. |
| `tests/reissue_e2e.rs` `LeaveRequest {..}` | `+blocked` | `blocked: None` |
| `tests/security_rule_gates.rs` source-pin paths | runtime moved | `marmot-account/src/runtime.rs` → `marmot-session/src/runtime.rs` (+ `runtime/*.rs`), through Stage 0's shared `mdk_source` helper |
| `src/nostr/giftwrap.rs` test fixture `EventBuilder::gift_wrap` | fork API | `transport_nostr_peeler::gift_wrap_rumor` (`M16:transport-nostr-peeler/src/nip59.rs:18-27`): one implementation, the production one |
| soak `oracle/undecryptable.rs` | `GroupRecovery`, `NotAddressedToThisDevice` | terminal arms (not undecryptable) |
| soak `s12_key_package_rotation.rs` | `delete_key_package` | bundle delete |
| `haven/rust_builder/src/api.rs` test `delete_key_package` | removed | bundle delete. It is edited here because the builder must compile. The bridge-hash guard stays red until the single regeneration at step 17; that is a recorded part of the red window. |

**CP-L / CP-T (shared with 1a):**

- `cargo check --lib` passes with and without `test-utils`;
- then `cargo check --all-targets` passes in every root;
- clippy (pedantic + nursery) and fmt pass.

**Cycles (1b share):** ESTIMATED 8–12 C. The master order's whole sweep is 15–25 C.

---

## 5. Step 15: red inventory

1. Run one full haven-core suite (S).
2. Run soak `pr`.
3. Run Stage 0's relay-free open-layer test, `haven-core/tests/upgrade_fixture_open.rs`, over
   both committed fixtures (`fixtures/upgrade/haven-v0.1.13/` and `fixtures/upgrade/haven-pre-bump/`).
4. Run the driven `haven-soak fixture check` at every instant.
5. Run the compat run, with the old peer at v0.1.13 and the new peer at HEAD.
6. Run the cost ledger compared with the Stage 0 baseline (S0.9).

Record every red against the unit below it belongs to. The units' red tests are those observed
reds. A unit whose red did not appear has a vacuous test, and the test is fixed before the fix
lands.

**Cycles:** 1 S, 1 soak `pr`, fixture checks, 1 compat run.

---

## 6. Step 16: semantic units, red → green pairs in the master order

The master order's 16.1 (Rule 16 / pool) and 16.6 (relay-layer removals) belong to Stage 1a. This
part owns 16.3, 16.4, 16.5 and 16.7, and the `possible_exposure` audit inside 16.2.

### Step 16.2 (shared with 1a): `possible_exposure()` audit, C11

- **Break.** `possible_exposure()` is now true for an `Attempting` target, and re-marking such a
  target records exposure (`M16:traits/src/transport_adapter.rs:570-581, 631-660`). This is the safe
  direction.
- **Pairs.** There is one per reading site in `relay/fanout.rs` (the reads at ≈ `1361`, `1479`, `1728`,
  `1756` (24 h undo bound), `2026` and `2472`), plus `manager.rs` `never_attempted`. Each test drives a
  concurrent reader against an in-flight row and asserts four things:
  - no rollback;
  - no 24 h undo;
  - a resend on schedule (Rule 13.3);
  - sends still held as `AwaitingRelays` (Rule 13.4).
- Expected outcomes that change are **re-derived** from Rule 13, never loosened.
  `a_kill_during_the_first_call_is_recorded_possibly_exposed_and_sent_again_on_schedule` now also pins
  MDK #2332. Stage 1a contributes its one test (X8).
- **Cycles:** ESTIMATED 4 pairs ≈ 8 T.

### Step 16.3: storage open and refs

**Gate:** `upgrade_fixture_open.rs` and `fixture check` green on both fixtures, including the
silent-loss assertions of §9.4.

| Unit | Red | Fix |
|---|---|---|
| **`with_storage`** | `the_session_shares_havens_storage_connection` (`shares_connection_with`, `M16:storage-sqlite/src/protocol/handle.rs:203`). It is red on the two-open shape. | Open once with `SqliteAccountStorage::open_encrypted_with_options` (all 87 migrations run there, before anything else), run `settle_fanouts_before_open` on that handle, then `SessionConfig::with_storage(storage, took, identity, peeler)` (`session.rs:164-178`) with `.account_identity_proof_signer(..)`, `.supported_app_components(haven_app_components())` and `.feature_registry(..)`. Rule 14's `LiveSessionGuard` and `sqlcipher_init::ensure()` stay first. This removes the second PBKDF2 open (upstream measurement on a Pixel 8 Pro: ≈ 76 ms per open, MDK `docs/marmot-architecture/storage-format-v2.md:523-575` at v0.16.0), the second migration runner and the cross-connection staleness of the T-SECOND-HANDLE reads. It also gives a deterministic `closer()` (`handle.rs:242`). The whole T-SECOND-HANDLE pin suite runs unchanged. |
| **Responsiveness with one connection** | `an_off_gate_read_answers_while_a_long_convergence_pass_runs`: one shared connection serialises Haven's off-gate reads behind engine transactions. The test asserts that an FFI read issued mid-pass returns within the pass's own bound (injectable clock), not after the whole drive. | If red, the read moves onto the engine gate's yield points. Never a second connection. |
| **`leave_in_progress`** | `an_in_memory_leave_also_declines_a_rejoin_offer` | `leave_requested` → `session.leave_in_progress(group_id).unwrap_or(true)` (`session.rs:1939`), which fails closed. This retires T-SECOND-HANDLE use 14. |
| **NIP-77 inventory funnel** | `the_nip77_inventory_keeps_every_item_it_is_handed`: record N items through Haven's funnel and read back N. It is a pin; it would be red on the held variant. | §4.1 port. |
| **C12(a) trial ref** | `kill_window_e2e::a_trial_record_never_takes_a_ref_a_stored_evolution_holds` | In `try_recordless_removals`: `max(highest_pending_ref, store.pending_ref_high_water()?) + 1` (`M16:traits/src/storage.rs:1299`). A fanout put raises the watermark in the same savepoint (`M16:storage-sqlite/src/protocol/storage/outbound.rs:205-230`). |
| **C12(b) duplicate-ref detector** (decision 7) | `a_store_holding_one_pending_ref_in_two_circles_is_refused_typed_and_untouched`: two `Pending` fanout rows, or two `Prepared`/`Attempting` evolutions, of different restorable groups sharing a ref, written by hand before the first open. Paired negative pin `two_circles_whose_confirmed_evolutions_share_a_ref_open_normally`, run on both fixtures: every v0.10.4 store with two self-updated circles holds such evolutions, because v0.10.4 restarts refs per session and keeps a `Confirmed` evolution's ref (`M10:cgka-engine/src/publish.rs:246-247`). | `settle_fanouts_before_open` lists both tables and counts **only the refs hydrate binds**: fanout rows whose MLS state is pending, and evolutions in phase `Prepared` or `Attempting` (`M16:cgka-engine/src/engine.rs:2693-2700`), of groups not marked `unrecoverable` (hydrate restores none of their refs, `:2555-2557`). Two such refs in different groups fail the open as `StoreCannotOpen` before the session opens, with no write, so hydrate never binds one ref to two circles' commits (`M16:cgka-engine/src/epoch_manager.rs:233-241`). Two rows v0.10.4 restored cannot share a ref (`M10:…/epoch_manager.rs:212-221`); the state needs a row v0.10.4 left unrestored (a group quarantined before its restore) that v0.16.0 restores. Stage 0's F10 recipe moves to the reviewed-unreachable list with that citation. The refusal is whole-store because no supported seam keeps one group out of hydration; it fires only where the harm, a confirm for one circle merging another's commit, would otherwise follow silently. |
| **Typed open errors (§9.5)** | `a_store_mdk_refuses_to_upgrade_is_reported_typed_and_never_reset` (an undecodable fanout row → `StoreCannotOpen`), `a_full_disk_during_the_upgrade_is_reported_as_no_space` (`StorageError::Capacity`, `M16:storage-sqlite/src/base/codec.rs:240`), `a_store_from_a_newer_build_is_reported_typed` (`UnsupportedSchemaVersion`) | `open_error_kind(&NostrError) -> CircleOpenError`, decided by `StorageError` variant through the existing `MdkErrorKind`, never by text (Rule 8). Variants are listed in §9.5. The tests also assert that the file and keyring key are intact, that no reset marker is written, and that while locked out no KeyPackage is published and no MLS signer is minted. |
| **Background gate (§9.3, O1)** | `a_background_wake_never_starts_the_store_upgrade` (fixture database, no marker, background opener → `StoreUpgradePending`, no `cgka_schema_migrations` row added); `a_fresh_install_opened_in_the_background_writes_the_marker`; `the_store_generation_is_the_schema_mdk_creates` | §9.3 |
| **Reset vs migrate** | `storage_upgrade_paths::each_release_in_the_field_takes_its_own_path` (§9.6) | Pin: Haven code the bump does not touch. |
| **C4 marker migration at open** | lands in 16.4 (C4), not here | — |

**Cycles:** ESTIMATED 10 pairs ≈ 20 T, plus fixture checks and 1 S.

### Step 16.4: KeyPackages and Welcomes

**Gate:**

- fixture state "Welcome to a pre-upgrade KeyPackage joins", plus its repointed-slot variant (Stage 0
  fixture);
- compat scenarios "invite built from a KeyPackage published before the upgrade still joins" and
  "KeyPackage rotation by new, used by old".

**C1. `AutoPublish.welcomes` recorded.**

- **Red:** `fanout_driver_e2e::an_engine_staged_commit_records_every_welcome_the_engine_hands_over`.
  It is type-level: feed a synthetic `AutoPublish` with one Welcome through `staged` and assert that
  the record carries it. A reachable producer does not exist (§1(a)).
- **Fix:** `PublishWork::AutoPublish { msg, welcomes, .. } => put_commit_fanout_marked(session, msg, welcomes, pending, now_ms, None)`,
  with the same `carried` bookkeeping as the `GroupEvolution` arm.
- Rewrite the comment: "an engine-staged commit (an eviction, a replay rotation) is never marked as
  removing nobody".
- At confirm, a Welcome whose recipient has no Haven-recorded route ends as `reinvite`; it is not
  sent (§1(b)).
- Kept: the FinishOnly arm records nothing; `restaging_held`; `before = None`.

**C2. Welcome addressing vs the slot repoint.**

- **Break.** The engine joins only when the rumor's `e` claim names a held publication
  (`M16:cgka-engine/src/group_lifecycle.rs:133-162`; `M16:traits/src/maintenance.rs:504-530`).
- Haven's repoint re-signs the same package and overwrites `authored_event_id`. An invite built on the
  first event is then refused as `NotAddressedToThisDevice` (`message_processor/ingest.rs:456-465`).
- **Red:**
  - `kp_lifecycle_e2e::every_publication_of_a_package_this_device_holds_is_answerable`;
  - `a_welcome_built_on_a_current_publication_joins`.
- **Fix.** When the slot is malformed, stage and publish a **new** KeyPackage into the slot through the
  normal stage/promote path. MDK does the same for its own slot repair
  (`M16:marmot-session/src/runtime/own_slot.rs:1-40`).
  - The old package is superseded and deleted at acknowledgement.
  - Delete `repoint_key_package_slot`.
  - A package repointed before the upgrade keeps only its latest id. An invite on its older event
    gets `NeedsNewInvite`, which T-WELCOME-KP-REF (16.7) shows at preview.
- Unchanged: a heal republishes the frozen bytes (`check_key_package_wire_shape.sh`), and the slot's
  `d` value is reused.

**C4. Consumption marker.**

- **Break.** Consumption of a pending replacement now lands in
  `PendingKeyPackageReplacement::consumed_at` (`M16:traits/src/maintenance.rs:534-588`). A consumed
  last-resort package would stay published for weeks.
- **Red:**
  - the existing `kp_lifecycle_e2e::a_package_consumed_before_its_acknowledgement_still_owes_a_replacement`
    and `api.rs` `tc27_…` must be red at step 15; if green, they are vacuous and are fixed first;
  - new: `a_record_written_by_v0_10_4_whose_marker_names_the_pending_package_still_owes_a_replacement`,
    using the fixture shape.
- **Fix.**
  - `state.migrate_legacy_consumption_marker()` (`M16:traits/src/maintenance.rs:549`) runs right after
    each load in `promote_key_package`, and once after the session opens, before the first maintenance
    tick. It is a single `put_key_package_lifecycle` and idempotent, so it survives crash point 6.
  - On promotion, if `replacement.consumed_at.is_some()`, set marker = new current ref and
    `last_consumed_at = consumed_at`. This mirrors `M16:marmot-session/src/runtime.rs:1796-1802`.
  - The 72 h hold in `CircleManager::consumed_key_package_replacement_waits` reads the migrated record.

**C3. Stored refresh point (with O4).**

- **Break.** The third argument changed from refresh-*lead* (`refresh_at = not_after − lead`) to
  refresh-*after* (`refresh_at = min(created + after, not_after)`,
  `M16:cgka-engine/src/maintenance.rs:328-337, 368-373`).
- **Red:** `kp_lifecycle_e2e::the_stored_refresh_point_is_the_one_haven_rotates_at`.
- **Fix.**
  - Haven passes `refresh_after_secs = 0.75 × the package's own lifetime`, which is 22.5 d at 30 d.
  - `kp_lifetime.rs` reads the stored `refresh_at` first, so the two can never diverge.
  - `KEY_PACKAGE_REFRESH_LEAD_SECS` is deleted.
  - Pin `the_stored_refresh_point_is_three_quarters_of_the_lifetime` (O4 default).

**30-day lifetime.**

- `KEY_PACKAGE_LIFETIME_SECS = 30 d` (`M16:cgka-engine/src/key_package.rs:51, 556`). Receivers still
  accept up to 84 d.
- Haven's rotation reads the package's own span, so the mechanism survives. The literals do not:
  - `manager.rs` `KEY_PACKAGE_*`;
  - `relay/maintenance/kp_lifetime.rs`;
  - `relay/maintenance/key_package.rs` (≈ `:1697`);
  - `tests/kp_rotation_e2e.rs:45`;
  - `tests/maintenance_per_relay_e2e_test.rs:47`;
  - `haven/integration_test/kp_rotation_wire_test.dart`;
  - `tooling/e2e/ci/run-kp-rotation.sh`.
- Their reds come from step 15. Every literal and doc changes in the same pair.

**C-RANK.**

- Keep the label tier: Rule 10 default, D-default.
- Adopt `key_package_client_name(&event).is_some()` (`M16:transport-nostr-adapter/src/key_package.rs:35-52`)
  for `client_tagged`.
- **Red:** `a_package_with_two_client_tags_is_ranked_as_mdk_reads_it`.

**Two further pins:**

- `KeyPackageRequirements` now refuses a non-live group (`ensure_group_live`,
  `M16:cgka-engine/src/key_package.rs:305-306`). Red:
  `an_invite_into_a_quarantined_circle_is_refused_with_the_quarantine_outcome`. Fix: map the error to
  the existing quarantine outcome.
- Upstream OpenMLS changed its capability defaults. Pin
  `a_fresh_key_package_advertises_exactly_this_extension_list`, the exact `mls_extensions` ids of a
  fresh KeyPackage. It is green or red at step 15; if red, the list is decided against the CLAUDE.md
  30443 row, never loosened.

**Cycles:** ESTIMATED 10 pairs ≈ 20 T, plus 1 S and the compat scenarios.

### Step 16.5: Rule 13 and ingest

**C6. Replay rotation.**

- **Break.** After canonical apply restores an own-commit checkpoint, the engine owes a self-update
  (`require_replay_rotation`, `M16:cgka-engine/src/maintenance.rs:83`). Until it is acknowledged:
  - every unpinned `AppMessage` is queued (`message_processor/mod.rs:1664-1690`);
  - the rotation is staged by an unpinned send, or by every full advance or drain (`mod.rs:1567-1590`).
- This is a confidentiality fix: a restored sender ratchet would reuse MLS keys and nonces. It is
  accepted.
- **Reds:**
  - `self_update_e2e::a_replay_rotation_leaves_only_through_a_fanout_record`: in a foreground full
    drive, the record exists before any byte leaves, and the commit confirms on the first ack.
  - `finish_only_e2e::a_wake_owing_a_replay_rotation_sends_no_commit_and_seals_no_location`: at most
    one stage-and-rollback per wake.
  - `self_update_e2e::a_replay_rotation_never_commits_a_peers_pending_proposal` (§1(b)).
  - The existing `no_wake_or_elapsed_time_ever_authors_a_self_update` stays green; no background
    drive is `Full` (§1(c)).
- **Fix, only if the second red shows more than one stage per wake.** In FinishOnly, skip the location
  `send` for a circle whose previous send in this process came back queued with an `AutoPublish` that
  had to be rolled back. This is an in-memory mark. `needs_replay_rotation` is `pub(crate)`
  (`maintenance.rs:269`), so the row `T-ENGINE-SELF-UPDATE` asks for a public `replay_rotation_owed`.

**C9. A location queued behind an earlier intent or a rotation** (`EarlierIntentQueued`,
`mod.rs:1697-1710`).

- Haven already discards every queued `AppMessage` for the circle (`discard_queued_location_intents`).
- **Pins (expected green):**
  - `location_fanout_e2e::a_location_queued_behind_an_earlier_change_is_discarded_and_never_sent`;
  - `…_queued_behind_a_replay_rotation_…`.
- If either is red, the fix belongs in `fold_into` or the discard, never in MDK.
- Adopting `expected_epoch: Some(pin)` and deleting the discard is Stage 2 C23, done in one change.

**C13. Confirm `Ok` after a failed replay; non-durable `QueuedIntentRefused`.**

- **Breaks.**
  - `confirm_published*` now returns `Ok` and keeps the group on an in-memory retry list
    (`M16:cgka-engine/src/publish.rs:455-469`; `message_processor/mod.rs:4273-4294`).
  - The refusal is announced after a durable delete (`queued_intent_refusal.rs:43-45`).
- **Re-specified, never weakened:**
  - `a_confirm_error_is_decided_by_the_stored_fanout_row`, failure points 1, 2 and 3;
  - the inverted replay-write leg of `stranded_input_measured_e2e`;
  - new `a_replay_error_without_a_restart_is_delivered_once`;
  - `finish_only_e2e::a_death_inside_a_finish_only_confirm_…`, re-checked;
  - `a_queued_change_mdk_refuses_after_a_crash_still_leaves_its_note`.
- **Fix:** keep `retire_unmakeable_queued_changes` as the durable note-first gate.

**C14. `SupersededIntentOutcome::Conflict`** (`M16:cgka-engine/src/own_commit_intent.rs:578-597, 652-672`).

- **Red:** `reissue_e2e::a_reinvite_whose_fresh_packages_leave_a_lost_device_out_is_said_to_need_a_new_invite`.
- **Fix:** map the variant to the existing "needs a new invite" outcome (Rule 8).

**C15. The peeler no longer verifies kind-445 signatures** (`M16:transport-nostr-peeler/src/peeler.rs:385-388, 618-630`).

- **Red:** `security_rule_gates::a_kind_445_with_a_forged_signature_never_reaches_the_engine_and_the_genuine_copy_still_does`.
  1. On each plane, hand over a 445 with a valid id and a flipped signature byte:
     - the live plane `process_event`;
     - the catch-up pager;
     - NIP-77 fetch-by-id;
     - a background burst.
  2. Assert that the engine never ingests it.
  3. Then deliver the genuine copy with the same id on the same route, and assert that it is taken in.
  4. Assert that NIP-77 completeness does not count the forged delivery.
- **Fix:**
  - `screen_before_auth` calls `event.verify()` (id **and** signature).
  - A failure is **dropped as if withheld**: `Left::Unasked`, no evidence, no final-for-route
    judgement, nothing recorded under the id.
  - An id mismatch keeps today's deterministic rejection.
  - This restores the v0.10.4 property at one site. Cost: one Schnorr verification per ingested 445,
    ESTIMATED small next to the MLS decrypt.

**New `GroupEvent` variants: what Haven does, not just that it compiles.**

| Event | Red | Haven action |
|---|---|---|
| `LocalGroupCopyTerminated { group_id, voluntary }` (`M16:traits/src/engine.rs:796-802`) | `a_terminated_copy_is_re_read_seals_nothing_and_arms_no_retick` | The circle is owed a `circle_recovery` re-read, and its queued location state is discarded. Left vs Removed is never inferred from `voluntary`; Haven keeps its existing classification. If the "no retick" assertion is red, T-SCHEDULER arm 2 (a terminal copy is never `PendingUnopenable`) is ported here; otherwise it waits for Stage 2.3. |
| `LocalGroupCopyRestored { group_id }` | `a_restored_copy_leaves_the_removed_state_without_any_user_action` | Re-read the circle and owe a full advance. Never auto-rejoin or re-prompt. |
| `QueuedIntentRefused { … }` | `a_refused_queued_change_is_noted_by_variant_only` | Map to `ChangeNote::QueuedChangeDropped`, classified only by typed fields. Never log or cross `reason` or `intent_kind` (Rules 8, 15). |
| `GroupMemberLeavesRemoved { … }` | covered by the roster tests | Invalidate the roster cache. Never format the event (absolute epoch and member ids). |

**`wrap_group_recovery`.** The tests for §4.2's fail-closed port:

- `retention::tests::a_group_recovery_is_never_wrapped`: `WrapFailed`, and its `Display` names no id.
- `welcome_preview_e2e::a_group_recovery_gift_wrap_is_never_held_as_an_invitation`: no invitation row
  and no ingest. Its cursor follows the existing failed-preview rule, which this test pins; it must
  never hold the cursor for ever.
- `accept_welcome_never_reports_a_recovery_control_as_joined`.

**T-FAULTED-INGEST-SEEN.**

1. `an_ingest_a_storage_fault_aborted_is_never_redelivered` (`tests/test_utils_seams.rs` ≈ `921-966`)
   must be red at step 15.
2. Add the proposal and current-epoch-commit cases first.
3. Then invert it into `a_redelivery_after_a_storage_fault_is_ingested_and_delivered`.
4. Remove the row for application messages. Any case that still records the object as seen keeps a
   narrowed row.

**Cycles:** ESTIMATED 17 pairs ≈ 34 T, plus 1 S.

### Step 16.7: remaining units

**C7. 0x800d and the device-group components (D3): pins.**

- `components_e2e::no_haven_key_package_or_circle_advertises_or_requires_account_devices`;
- `haven_leaves_advertise_exactly_the_supported_set`;
- `a_circle_cannot_be_made_to_require_account_devices_while_a_haven_member_lacks_it`.

Basis:

- 0x800d is advertised only if the host lists it (`M16:marmot-session/src/session.rs:185`;
  `M16:traits/src/app_components/mod.rs:245-253`), and Haven's `haven_app_components()` does not list
  it.
- An upgrade never adds it (`M16:cgka-engine/src/capability_manager.rs:303-312`).
- 0x800e and 0x800f need `dev-device-groups`, which guard step 2 refuses.
- Leaf refresh and component migration run only in `AccountDeviceRuntime::run_due_maintenance`, which
  Stage 1 never constructs.

**C8 (Rust half) and the T-SCHEDULER arm it needs.**

- **Breaks.**
  - (a) A frozen pass that fails after its decision parks after 12 failures
    (`M16:cgka-engine/src/distributed_convergence.rs:102-116, 2500-2530`). It resumes only on new input
    or `retry_failed_convergence_pass` (`session.rs:1645`).
  - (b) `GroupHydrationQuarantineReason::RewindRestoreFailed` clears only on reopen
    (`M16:traits/src/engine.rs:738-746`). Haven drops the reason, and its copy "a retry may bring it
    back" becomes false.
- **Reds:**
  - `recovery_e2e::a_parked_pass_is_named_and_a_retry_resumes_it`;
  - `recovery_e2e::a_rewind_restore_failure_is_named_and_cleared_by_a_reopen`;
  - `a_parked_pass_arms_no_retick_and_no_timer` (T-SCHEDULER arm 1, the only re-sync this unit needs).
- **Fix.**
  - `RecoveryCause` gains `ConvergenceParked` (after `Stalled`) and `ReopenRepairs` (beside
    `Quarantined`), making 15 causes.
  - `SessionManager::retry_parked_convergence(group)` runs automatically once per circle per foreground
    open (bounded), and is driven by the card's button through FFI (step 17).
  - The `ReopenRepairs` remedy closes the session with `closer()` and reopens it in-process, under the
    Rule 14 guard.
  - `quarantined_group_ids` keeps the reason as a typed flag, and its doc is corrected.

**C10. Deferred-peel caps raised 4× (O6).**

- **Break.** The caps are now 8192 rows per group, 64 MiB per group and 256 MiB per account
  (`M16:cgka-engine/src/message_processor/mod.rs:168, 177, 187`); v0.10.4 had 2048 rows, 16 MiB and
  64 MiB (`M10:…/mod.rs:89, 98, 107`). Haven's derived bounds silently become
  `DEFERRED_PEEL_DRAIN_ADVANCES = 129` and `SEND_PEEL_DRAIN_ADVANCES = 8193`. Anyone who sees a
  circle's public `#h` can make the device store 4× more undecryptable input.
- **Settable? No.**
  - The only override is `EngineBuilder::deferred_peel_limits_for_tests` /
    `Engine::set_deferred_peel_limits_for_tests`, both
    `#[cfg(feature = "test-policy-overrides")]` (`M16:cgka-engine/src/engine.rs:629-640, 843-853`).
    That feature is documented "Production/app consumers must not enable it"
    (`M16:cgka-engine/Cargo.toml` `[features]`). Guard steps 2 and 4 refuse it.
  - `SessionConfig` exposes no cap (`M16:marmot-session/src/session.rs:139-311`: `with_storage`,
    `defer_group_hydration`, `recorder`, `feature_registry`, `account_identity_proof_signer`,
    `supported_app_components`, `protocol_profile`, `legacy_compatibility_profile`, `storage_options`,
    `convergence_policy`, `maintenance_sources`, `with_group_authority_snapshot`).
  - So the new values are upstream behaviour in Stage 1. The row `T-PEEL-CAP-4X` records the bound and
    the ask: a `SessionConfig::deferred_peel_limits(rows, group_bytes, account_bytes)` that may only
    lower MDK's defaults. O6 stays on the owner list.
- **Red:**
  - `foreground_peel_e2e::a_full_store_drains_ahead_of_a_send_within_one_foreground_wake`, with an
    8192-row store under `slow_deferred_peel_writes_for_test` and an **injected** budget, not wall time;
  - the soak S16 `outsider-flood` arm re-graded at 8192 rows.
- **Measurement.** Wall time to drain 8192 rows on the build machine, recorded as a host measurement,
  not a device one.
- **Fix.**
  - Replace the hard-coded `2048` and `4 * 2048` with the constants.
  - Update `manager.rs` drain-bound docs, T-PARKED-REPLAY's N = 8448 → re-derived, and
    `haven-core/SECURITY.md`.
  - **If the red cannot be made green without cutting the drain, STOP and ask.** That is a trade
    between the responsiveness and performance pillars, and it is never taken silently.

**C16. `fs-private` lock text.**

- At v0.16.0, `ensure_private_db_files` no longer reopens descriptors (`M16:fs-private/src/lib.rs:1009, 1031-1076`),
  and `with_storage` removes the second open.
- Correct `LiveSessionGuard`'s rationale (`haven-core/src/nostr/mls/storage.rs` ≈ `:200-210`): SQLite
  locks serialise writers but do not exclude a second process; the per-process registry is Rule 14's
  only authority. This is documentation only.

**T-WELCOME-KP-REF (Rust half).**

- `preview_welcome` reads the rumor's `e` claim and reports `dead` when it names no publication in
  `held_publications()` (`M16:traits/src/maintenance.rs:510`). The accept-time `NeedsNewInvite` is
  kept.
- **Red:**
  - `a_pre_reset_invitation_is_hidden_at_preview`;
  - `a_welcome_built_on_a_pre_repoint_event_is_reported_dead`.

**Gate:** full suite, soak `pr`, fixture checks at every instant, compat at every P0 scenario.

**Cycles:** ESTIMATED 9 pairs ≈ 18 T, plus 1 S, soak `pr` and the S16 re-grade.

---

## 7. What Stage 1 re-syncs, and what waits

**Kept in Stage 1**, each because a Stage 1 behaviour depends on it:

| Re-sync | Why Stage 1 needs it |
|---|---|
| T-SCHEDULER arm 1 (a parked pass arms nothing and is surfaced) | C8: v0.16.0 introduces parking. Without the arm, the retick loop either spins on a parked pass or the circle freezes unnamed. |
| C3 stored `refresh_at` = Haven's rotation instant | MDK now reads the argument as refresh-after. Stage 2's runtime reads this stored field, and devices in the field carry it across the boundary. |
| C4 consumption-marker migration | Without it, a consumed package stays published (privacy). |
| `changes_group` arms mirroring `is_fair_scheduled_intent` | A compile site under S0.5's exhaustive lint. The values are fixed once, at the source of truth. |
| T-SCHEDULER arm 2, only if 16.5's terminated-copy test is red | `LocalGroupCopyTerminated` is new at v0.16.0. |

**Deferred:**

| Item | Goes to | Why |
|---|---|---|
| The 6–7 day KeyPackage refresh | Stage 2.1 | O4 default, and the runtime's own refresh |
| T-MAINT-DRIVER epoch-gap and 1 h undelivered-commit holds | Stage 2.3 | The runtime's `run_due_maintenance` |
| T-SCHEDULER arms 3–4 | Stage 2.3 | Parity ports of behaviour 2.3 adopts natively. The gaps predate the bump. |
| T-EPOCH-STALL seeding from `deferred_stall_evidence` | Stage 2 (O7) | Haven's fruitless-walk detector is Haven code that the bump does not change. |
| The daily own-slot integrity read | Stage 2 (MDK's `own_slot`) | Recorded as `T-OWN-SLOT-CHECK` |

---

## 8. Owner items, with the defaults applied

| # | Item | Default in force | This part's handling |
|---|---|---|---|
| O1 | Background sharing pauses after an update until the first foreground open | Yes | §9.3 gate |
| O2 | A store the new build refuses is a lockout answered by fix-forward, never an automatic reset | Yes | 16.3 typed errors; §9.5 |
| O3 | No pre-upgrade backup copy | Yes | §9.7 |
| O4 | Weekly refresh (spec SHOULD) vs rotation at 0.75 of the lifetime. A weekly refresh shortens `init_key` exposure but publishes a "device alive" signal about 52 times a year instead of about 16. | Keep 0.75 × 30 d | C3; pinned. The 6–7 d refresh goes to Stage 2.1. |
| O5 | The replay rotation may ride a full background drive | Accept | Moot in Stage 1: no background drive is `Full` (§1(c)). |
| O6 | Outsider-forced storage rises from 64 MiB to 256 MiB per account | Not settable (C10) | `T-PEEL-CAP-4X` with the upstream ask; **listed for the owner** |
| O7 | `Stalled` rests on fruitless-walk counting that MDK deleted | Stage 2 | §7 |
| O8 | `StepDownAndLeave` blocks the last admin | Stage 2 decision | Its construction is banned in Stage 1 (§2.4) |
| O9 | User-initiated "reset circles on this device" | Not built | §9.5 states the lockout bound |
| O10 | Required status checks on `main` | Owner action | Stage 0 |
| O11 | Upstream asks | Drafted in the tracker | §11 |
| O12 | Suppress the fork's `user-agent` | Yes | Stage 1a |
| O13 | Refuse Welcomes above the pre-fork NIP-44 limit while v0.1.13 may be in the field | Yes | Stage 1a implements it; the tracker row is written in step 18 |

---

## 9. Database upgrade

### 9.1 Which handle migrates

With `with_storage` there is exactly one open: Haven's
`SqliteAccountStorage::open_encrypted_with_options`. Migrations 1–89 are identical by name. All 87
new migrations (0090–0153, 0160–0180, 0200, 0201) run there, each in its own transaction with the
ledger insert inside it (`M16:storage-sqlite/src/base/migrations.rs:1680-1712`). They run before the
pre-open pass and before the session. A killed migration rolls back alone and re-runs (upstream
real-process-kill test, `:3098-3133`).

### 9.2 The 87 migrations, classified

Haven never populates MDK's app tables. They are written only through `account_projection` and
`timeline` APIs Haven never calls, and the engine's spill paths need an `account_state` row
(`M10:storage-sqlite/src/storage/messages.rs:270-280`).

| Class | Count | Migrations | Can it fail on Haven data? |
|---|---|---|---|
| Additive DDL on new or app tables | 49 | 0091, 0093–0099, 0107, 0116, 0118, 0119, 0122, 0123, 0125–0129, 0131, 0133–0141, 0143–0146, 0148–0152, 0160, 0161, 0163, 0164, 0170–0172, 0176–0178, 0201 | No |
| Additive DDL on a populated protocol table | 1 | 0111 (`cgka_messages` gains 2 columns; 2 index builds over every retained row) | No; cost only |
| Backfill, rebuild or delete in app tables | 30 | 0090, 0092, 0100–0106, 0108–0110, 0112–0115, 0117, 0124, 0130, 0132, 0142, 0147, 0162, 0166–0168, 0173, 0179, 0180, 0200 | No: each is a no-op over empty tables on a Haven database. The FK-suspend preconditions of 0105 and 0113–0115 are the runner's to guarantee. |
| Tolerant backfill reading protocol rows | 3 | 0120 (0 rows on Haven), 0153 (`.ok()`-tolerant), 0169 (12 nullable columns + 8 indexes on the unbounded `cgka_processed_transport_ids`) | No; 0169 has a cost |
| Decode and validate, failing closed | 1 | **0175**: every `cgka_outbound_fanout` and `cgka_group_evolutions` record must decode | **Yes**, on a corrupt row only |
| Drops | 3 | 0121 (a cache), 0165 (a table created in the same upgrade), 0174 (0169's indexes) | No |

Why 0175 refuses only corruption:

- Every type reachable from `OutboundFanout` and `DurableGroupEvolution` changed only additively,
  with `#[serde(default)]`.
- Haven's `settle_fanouts_before_open` already decodes every fanout row at every v0.10.4 open, so a
  row present today decodes.

Two other whole-open decodes outside the migrations:

- `EngineBuilder::build` → `list_pending_application_events()?` (`M16:cgka-engine/src/engine.rs:713`).
  `GroupEvent` grew additively.
- `Identity::load_or_generate` fails closed and never regenerates silently.

Cost: 0169's two full index builds and 0111's two make the first open the expensive one. Stage 1 has
no device measurement of them (ESTIMATED tens of MB of WAL on a large account, UNVERIFIED on a device).
That is the reason for O1.

### 9.3 Background gate and marker (O1)

- **Marker:** the file `session-v2.generation` beside `session-v2.sqlite`. It shares that file's
  backup policy (Android `allowBackup="false"`). It holds the Haven build constant
  `STORE_GENERATION`. Stage 1 sets it to `"mdk-schema-201"`; it is bumped whenever MDK's schema version changes, which the pin below enforces. Stage 2 keeps schema 201, so it does not bump it.
- **Written** after **every** successful open, foreground or background. Otherwise a store created in
  the background would stay gated for ever.
- **Gate:** a background opener (WorkManager catch-up, the iOS burst, Android FGS work) that finds
  `session-v2.sqlite` present and the marker absent or different declines with `StoreUpgradePending`,
  before any keyring read or PBKDF2, with no engine and no relay I/O.
  - A fresh install (no database) is not gated.
  - The first foreground open migrates.
  - The caller states its lifecycle at the call: the Dart side passes the app lifecycle state, not
    which service it is.
- **Pin:** `the_store_generation_is_the_schema_mdk_creates` opens a fresh store with
  `open_encrypted_observed` (`M16:storage-sqlite/src/protocol/handle.rs:126-138`, the production
  options). It asserts that the last `StorageOpenProgress::MigrationStarted(v)` equals the version
  recorded beside `STORE_GENERATION`. The next MDK bump fails it until both are updated.
- **Fail-safe in every direction:** the marker decides only *whether to open*, never *whether data is
  migrated*. A wrong marker costs one deferred background run (marker missing) or one background
  migration (marker ahead after a backup restore). It never costs integrity.

### 9.4 Silent losses at first open, and the assertions that catch them

Neither path produces an error, so typed outcomes cannot report them. The fixture gate catches them
before release. Both depend on code revs and Haven-shaped data, which the fixtures carry, not on
device chance.

| Path | Harm | Assertion (in `upgrade_fixture_open.rs` and `fixture check`, **right after the first open and before any maintenance tick**) |
|---|---|---|
| `retire_non_current_key_packages` at every Current-profile open (`M16:marmot-session/src/session.rs:519-528` → `M16:cgka-engine/src/key_package.rs:426-457`) deletes a bundle that fails to decode under upstream OpenMLS or whose 0x8009 proof no longer validates | Held invitations become unjoinable, and the published 30443 names a key the device no longer has | `key_package_bundle_count_for_test()` equals the manifest's count, and every fixture KeyPackage still answers a Welcome |
| Hydration quarantine per circle: 21 `PendingCommitRecoveryFailed` sites against 8 before, 12 new `RewindRestoreFailed` sites, and the new open-time rewind-guard restore (`M16:cgka-engine/src/openmls_projection.rs:1717-1767`), all swallowed by `hydrate_all_stored_groups` | One circle is dead on this device | `quarantined_group_ids()` is empty except the fixture's deliberately quarantined state; no circle holds a halted `circle_recovery` cause it did not hold before; a quarantined group is never forgotten across the upgrade (Rule 5), so a fix-forward can find it |

### 9.5 Open failures and the lockout (O2, O9)

`CircleManagerFfi::new` returns `Result<Self, CircleOpenErrorFfi>`. The FFI enum is fieldless and is
classified by `StorageError` variant (Rule 8).

| Variant | From | Copy (fixed, every locale) |
|---|---|---|
| `StoreUpgradePending` | background gate | none (background only) |
| `StoreNoSpace` | `Capacity` | "Your phone is out of storage. Free up some space, then open Haven again." |
| `StoreBusy` | `Busy` | retried silently, then generic |
| `StoreCorrupt` | `Corruption` | shared with `StoreCannotOpen` |
| `StoreFromNewerBuild` | `UnsupportedSchemaVersion` | "This data was written by a newer version of Haven. Update Haven." |
| `StoreCannotOpen` | any other non-transient storage error during open, including a 0175 refusal and the duplicate-ref detector | "Haven couldn't open its data on this device. Nothing has been deleted. Update Haven when a new version is available. Sharing on this device is paused until then." |
| `IdentityMissing`, `Other` | as today | as today |

The open is retried at every launch. **Never answered by a reset:** `reset_pre_v2_storage` touches
only pre-v2 names (`haven-core/src/storage_reset.rs`), and no code path deletes `session-v2.sqlite`
or `mls.session.key.v2` on an open error.

**The lockout's honest bound.**

- While a store cannot open, relays keep applying their retention to the circles' commits.
- A fix-forward that lands after a relay has dropped a commit this device never applied leaves that
  circle unable to catch up on this device. That is a **per-circle loss**: an admin must re-invite.
- "Nothing has been deleted" is true of the bytes, not of the circles' future, and the copy does not
  promise more.
- O9's user-initiated reset is not built unless the owner asks. While locked out, no KeyPackage is
  published and no MLS signer is minted (asserted in 16.3).

### 9.6 Reset vs migrate: the three sources in the field

| Release | MDK | Layout | Path |
|---|---|---|---|
| v0.1.13 (`a45ab2d8`) | v0.10.4 | `session-v2.sqlite`, `circles-v2.db`, `mls.session.key.v2` | in-place migration 89 → 201 |
| v0.1.11 – v0.1.12 | v0.9.4 | `session.sqlite`, `circles.db`, keyring `….default` | existing one-time reset, unchanged |
| ≤ v0.1.10 | old `mdk-core` | `haven_mdk.db` | the same reset |

`storage_upgrade_paths::each_release_in_the_field_takes_its_own_path` is relay-free. It builds four
data directories:

1. **The v0.1.13 fixture.** The store migrates to 201, every group hydrates, and no reset marker is
   written.
2. **A v0.9.4-era layout.** The reset deletes it, writes the notice markers, opens a fresh v2 store
   and never attempts to migrate the old file.
3. **A ≤ v0.1.10 layout.** The same as 2.
4. **Both a v2 store and a leftover v0.9.4 file.** Only the old names are deleted, and the v2 file
   migrates.

The test asserts that the classification never runs the other way.

### 9.7 No downgrade, no copy (O3)

- v0.10.4's runner refuses the upgraded file before reading any table
  (`UnsupportedSchemaVersion { found: 201 }`, `M10:storage-sqlite/src/migrations.rs:661, 719-739`),
  and Haven deletes nothing on that error.
- No pre-upgrade copy is kept:
  - A failed migration leaves the live file at its last committed migration, with no MLS state
    advanced. The live file is itself the retry source.
  - A copy that outlives the first MLS write is unsafe to restore (epoch and generation reuse).
  - A copy prolongs retention of past-epoch secrets that the live database prunes (Rule 5).
- Rollout is staged (Play staged rollout; TestFlight → phased release). A bad release is answered only
  by fix-forward.

### 9.8 Crash points

| # | Kill or failure point | Next foreground open | Next background open |
|---|---|---|---|
| 1 | Before any write (keyring, PBKDF2, pragmas) | migrates | declines |
| 2 | Inside migration *k* | *k* rolled back; resumes at *k* | declines |
| 3 | Between migrations | resumes at *k*+1 | declines |
| 4 | During a checkpoint | WAL replayed | — |
| 5 | Inside Haven's pre-open pass (trial rows, duplicate-ref detector) | the pass re-runs; each unit is idempotent and read-only or single-write | declines until the marker exists |
| 6 | Inside session open (KeyPackage retirement, rewind-guard restore, the C4 migration) | redone; each is transactional upstream or a single write | — |
| 7 | After the open, before the marker write | — | declines once (benign) |
| 8 | Marker ahead of the database (backup restore) | migrates | migrates in the background (cost only) |
| 9 | Disk full mid-migration | rolled back; `StoreNoSpace` | declines |
| 10 | Old binary on an upgraded or part-upgraded file | refused before any table read | — |

No crash point leaves a state that an open cannot recover. The only non-recoverable outcomes are
deterministic, not crash-induced:

- a corrupt 0175 input or `pending_application_events` row, which locks out until a fix-forward;
- the silent losses of §9.4, which the fixture gate catches.

### 9.9 Haven's own stores (Stage 1)

- `circles-v2.db` references only stable ids: MLS group id, `nostr_group_id`, transport event ids,
  gift-wrap ids and absolute epochs. It holds no `PendingStateRef`, MDK table name or KeyPackage ref.
- Stage 1 does not change its schema, so there is no two-database atomicity problem in Stage 1.
- The KeyPackage hold state in `user_settings` depends on MDK's lifecycle *semantics*, which C4
  migrates at open.

---

## 10. Step 17: the one `api.rs` batch, regeneration, Dart and l10n (all local)

### 10.1 Rust bridge (`haven/rust_builder/src/api.rs`)

| Change | For |
|---|---|
| `CircleManagerFfi::new(data_dir, identity_secret_bytes, foreground: bool) -> Result<Self, CircleOpenErrorFfi>`; new fieldless `CircleOpenErrorFfi` (§9.5) | §9.3, §9.5 |
| `RecoveryCauseFfi` + `ConvergenceParked`, `ReopenRepairs` | C8 |
| `RelayManagerFfi::retry_parked_convergence_driven(circle)` | C8 |
| `RelayManagerFfi::reopen_circle_store_driven()` (close via `closer()`, reopen, under Rule 14) | C8 `ReopenRepairs` |
| `WelcomePreviewFfi.dead: bool` | T-WELCOME-KP-REF |
| Doc at ≈ `:9571`: "84 days for the OpenMLS default" → 30 days | lifetime |
| Test `delete_key_package` → bundle delete (§4.2) | compile |

Then run `./scripts/regenerate_frb.sh`, once, after the last `api.rs` edit of Stage 1, covering 1a's
edits as well. It rewrites `frb_generated.rs`, `haven/lib/src/rust/*.dart` and
`scripts/ci/generated_bridge.sha256`. Then run `cargo fmt` and `dart format`.
`check_generated_bridge_pinned.sh` must be green.

### 10.2 Dart

| File | Change |
|---|---|
| `haven/lib/src/services/nostr_circle_service.dart` (≈ `:411`), `background_catchup_worker.dart` (≈ `:576`), `background_location_task.dart` (≈ `:1185`), `haven/lib/src/providers/service_providers.dart` | Pass `foreground` from the lifecycle state at the call. Map `CircleOpenErrorFfi` by variant to fixed copy. `StoreUpgradePending` in a background task ends the task quietly. |
| `haven/lib/src/services/circle_service.dart`, `circle_change_driver.dart`, `haven/lib/src/providers/sharing_health_provider.dart` | The two new causes; the driven retry and reopen calls |
| `haven/lib/src/widgets/circles/circles_bottom_sheet.dart` (Circle details sharing card) | Copy and a button for each new cause |
| `haven/lib/src/widgets/circles/invitation_card.dart`, `haven/lib/src/pages/invitations/invitations_page.dart` | A `dead` invitation shows "This invitation has expired. Ask for a new one." with no Accept |
| `haven/lib/src/pages/map_shell.dart` (or the page awaiting the circle service) | Show "Updating your circles…" when the open has not returned within 500 ms. It never blocks a tap. The open already runs off the UI isolate as an FRB async call. |
| Tests under `haven/test/` | A widget test per cause and button; open-error mapping per variant; a dead invitation has no Accept; the indicator appears while the open is pending and a tap during it takes effect (the responsiveness pillar) |

### 10.3 l10n (`haven/lib/l10n/app_*.arb`, 13 locales)

- **New keys:** two cause titles and bodies, two button labels, `StoreNoSpace`, `StoreFromNewerBuild`,
  `StoreCannotOpen`, "Updating your circles…", and the expired invitation.
- **Changed key:** the `Quarantined` body ("a retry may bring it back") becomes true again once
  `ReopenRepairs` takes the reopen-only reason.
- **Process (CLAUDE.md):**
  - one translating agent per language, and an independent reviewer agent per language for
    correctness, readability, accessibility and natural use;
  - then `dart scripts/ci/arb_parity_check.dart`;
  - then `flutter gen-l10n`, which must be warning-free.

**Green (local):** `flutter analyze`, `flutter test`, `flutter gen-l10n`, ARB parity,
`cd haven/rust_builder && cargo test`.

**Cycles:** 1 regeneration, ESTIMATED 3 F, and 1 builder test run.

---

## 11. Step 18: docs, tracker, privacy manifest (single docs editor for Stage 1)

Stage 1a supplies the facts for its rows and the **Rule 16 text verbatim**. This step writes
everything in one change.

### 11.1 CLAUDE.md

| Section | Change |
|---|---|
| MDK pinning | `marmot-session` replaces `cgka-session`; v0.16.0 rev `a2e0558a…`; OpenMLS `openmls/openmls@6100df3…` (from 1a); the `test-support` exception, its guard and `T-SESSION-PRIVATE`; `marmot-forensics` recorder guard now naming `audit_recorder` / `SharedRecorder` |
| SQLite first use | Openers: keep `SqliteStorage` (an alias); add `open_encrypted_observed`, `in_memory_for_test`, `open_hardened_sqlcipher`; the session opens nothing (`with_storage`) |
| Rule 5 | Delete at acknowledgement kept, now a recorded deviation from the spec's 24 h SHOULD (`T-KP-RETENTION`); 30-day lifetime |
| Rule 13 | Test-name citations re-checked against C13's re-specified tests |
| Rule 15 | The never-formatted MDK type examples gain `DeferredStallEvidence`, `QueuedIntentRefused`, `GroupMemberLeavesRemoved`, `GroupRecoveryMessage`; the recorder sentence names `audit_recorder`/`SharedRecorder` |
| Rule 16 | 1a's text |
| Flutter Service Layer | "13 typed causes" → 15 |
| Protocol table | 30443: delete "the one-time malformed-slot repoint signs a second event …", add "a malformed slot is refilled with a new package". 444: "addressed by the rumor's `e` tag; a device joins only a Welcome naming a publication it holds"; the NIP-44 ceiling (O13). 1059: "may carry MDK's private kind-1159 recovery rumor, which Haven never sends and refuses at preview" |
| Group components | The replay rotation is listed as the third permitted self-update: "made by MDK after an own-commit checkpoint restore, staged only in a foreground full drive, under a fanout record; never commits a pending proposal" |
| CI Pipeline | rust-check's `--resolved` step; repo-guards += `check_private_session_exception.sh` |

### 11.2 Other documents

- **`haven-core/SECURITY.md`:**
  - crate names and rev;
  - 84 d → 30 d;
  - 2048 rows → 8192 / 64 MiB / 256 MiB (O6);
  - LiveSessionGuard text (C16);
  - kind 1159;
  - the slot refill;
  - the replay rotation;
  - forged-signature 445 dropped as if withheld.
- **`MARMOT_PROTOCOL_KNOWLEDGE.md`:**
  - crate names and v0.16.0;
  - Welcome `e`-tag addressing;
  - the 30 d lifetime (Haven rotates at 0.75);
  - 0x800d / D3;
  - kind 1159.
- **Current-tense statements** of "84 days", `cgka-session`, `fcc85edd`, "v0.10.4 as current" or the
  2048-row cap, in:
  - `docs/SOAK_LANE.md`, `docs/CI_HARDENING_BACKLOG.md`, `docs/ENCRYPTION.md`;
  - `docs/POWER_EFFICIENCY_PLAN.md`, where any KeyPackage publication figure keeps its ESTIMATED tag;
  - `docs/BACKGROUND_SHARING_FAILURE_ANALYSIS.md`, `docs/M7_BACKGROUND_SHARING.md`;
  - `haven/DEVELOPMENT.md`;
  - code docs (`manager.rs`, `kp_lifetime.rs`, `key_package.rs`, `storage.rs`, `api.rs`,
    `s16_storage_growth.rs`).

  Historical statements stay.
- **Grep recipes** (review every hit):

```bash
rg -n -g '!**/target/**' -g '!**/Cargo.lock' 'cgka[-_]session|fcc85edd|erskingardner/openmls|59e7d3b'
rg -n -g '!**/target/**' '84[ -]?day|7_?261_?200|eighty-four|13 typed causes|thirteen'
rg -n -g '!**/target/**' '2048|MAX_PEEL_DEFERRED|16 ?MiB|64 ?MiB'
rg -n -g '!**/target/**' 'marmot-account/src/runtime|record_transport_reconciliation_item|second event for the same package|repoint'
rg -n -g '!**/target/**' 'set_audit_recorder|set_recorder|SessionError::Storage|delete_key_package\(|audit_log_path'
```

### 11.3 Tracker (`docs/MDK_UPSTREAM_TRACKER.md`)

**New rows:**

| Row | Gap | Mitigation | Removal condition | Pin |
|---|---|---|---|---|
| `T-SESSION-PRIVATE` | §2.5 | §2.5 | §2.5 | §2.5 |
| `T-FINISH-STAGE-HOOK` | `arm_finish_stage_failure` is in every build | guard step 4 | upstream gates it behind `test-support` | guard self-test |
| `T-ENGINE-SELF-UPDATE` | the replay rotation's owed state is private | foreground-full-only record; FinishOnly rollback with a per-wake bound | public `replay_rotation_owed` | C6 |
| `T-QUEUED-REFUSED-DURABLE` | `QueuedIntentRefused` is not durable | note-first pre-check | MDK persists the refusal with the delete | C13 crash test |
| `T-PEEL-CAP-4X` | 8192 rows, 64 MiB/group, 256 MiB/account, not host-settable (`engine.rs:629-640, 843-853`) | drain bounds re-derived; owner informed (O6) | a lower-only `SessionConfig` setter upstream, or the owner accepts | C10 |
| `T-PARKED-PASS` | parking after 12 failures | typed cause, bounded automatic retry, button | none (MDK policy); the row records Haven's surfacing | C8 |
| `T-ACCOUNT-DEVICES` (D3) | 0x800d is not advertised; Haven cannot join groups whose founders all require it | C7 pins | revisit once every install is on the new build | C7 |
| `T-GROUP-RECOVERY` | MDK-private kind 1159 | fail-closed wrap; refused at preview | owner decision in Stage 2 | §4.2 / 16.5 tests |
| `T-OWN-SLOT-CHECK` | no daily own-slot integrity read (spec `key-packages.md:121-140`) | none (the threat is a holder of the account key) | Stage 2 adopts `own_slot` | n/a |
| `T-KP-DELETION-REQUESTS` | selection ignores NIP-09 deletions of 30443 | none yet | Haven filters kind 5 at selection | the row records the gap |
| `T-NIP44-WELCOME-CEILING` | facts and row text from 1a (O13) | the refusal at the pre-fork limit | the minimum upgrade source passes v0.1.13 and pre-0.45 clients are gone | 1a's rewritten `nip44_plaintext_ceiling.rs` |

**Rewritten as deliberate deviations:**

- `T-KP-CLIENT-RANK`: keep the unlabelled preference; another app on the same key would receive circle
  keys.
- `T-KP-RETENTION`: delete at acknowledgement.
- `T-KP-DRIVER`: rotation at 0.75 instead of the spec's weekly SHOULD, under O4, until Stage 2.1.

**Updated (cites and status):**

| Row | Change |
|---|---|
| T-KP-EXPIRED-DELETE | pin re-pointed |
| T-SECOND-HANDLE | uses 14 and 18; the second connection is gone |
| T-STORAGE-KIND | compile arm; ask `StorageError::privacy_safe_kind` |
| T-WELCOME-KP-REF | replaced by the preview read |
| T-STALE-FANOUT / T-KILL-WINDOW | watermark; C12(a); C11 |
| T-CONFIRM-ERR, T-PARKED-REPLAY, T-QUEUED-INTENT-RESTORE | C13 |
| T-REINVITE-DRIVER | C14 |
| T-REJOIN-LEAVE | getter met |
| T-FOREGROUND-PEEL | C10 bound |
| T-RETENTION-DEVIATION | fail-closed wrap |
| T-FAULTED-INGEST-SEEN | removed or narrowed per 16.5 |
| T-RESERVATION-READ | source of truth re-pointed |
| T-SCHEDULER | arm 1 ported; arms 2–4 Stage 2.3 |
| T-MAINT-DRIVER, T-EPOCH-STALL | Stage 2, unchanged otherwise |
| T-FANOUT | "driver kept by D1 via T-SESSION-PRIVATE; removal is Stage 2" |
| T-WINDOWS-CI | **removed**: MDK runs a required `windows-filesystem` job, cited in the removal commit |

"Session close" note: the ask is met by `with_storage` + `closer()`. Every other row in this area is
re-cited at v0.16.0 with no status change.

### 11.4 Privacy manifest (`docs/privacy/privacy_invariants.json`)

`check_privacy_invariants.sh` rule 13 forces re-derivation when `mdk_rev` moves. Record:

- **Unchanged:** kind 445 (outer `h` + `expiration` only, `M16:transport-nostr-peeler/src/peeler.rs:194-212`),
  1059, and 444 (unsigned, `e` + `relays`).
- **New:** the kind-1159 rumor inside a 1059 — never emitted by Haven, refused at preview.
- **Never built by Haven:** kinds 459, 460 and 461, which are built only by device-group paths Haven
  never enables (guard step 2).
- **Not called:** the kind-5 KeyPackage deletion templates.
- **30443:** byte-identical for `client_name: None`.

Then set `mdk_rev` to `a2e0558a…`.

**Green:** `check_privacy_invariants.sh`, every repo guard. **Cycles:** none.

---

## 12. Step 19: coverage

- Run `scripts/ci/check_coverage.sh`: both halves run locally now.
- Then run `scripts/ci/check_coverage_floors.sh --repin rust <lcov>` and `--repin flutter <lcov>`.
  These only raise floors and are never hand-edited. `--lint` must pass.
- `--drop-stale` is used only for a file the change deletes. This part deletes none; Stage 1a's
  `nostr/encryption/` row is 1a's.
- A floor that would fall gets tests, never a lower floor.

**Cycles:** 1–2 K.

## 13. Step 20: push for the CI matrix, and the Stage 1 exit checklist

Push the branch. The working branch is the pull-request point; the owner merges. Each item below is recorded with its run
id.

1. The compat run against the old peer (v0.1.13 build, stored as a durable Release asset), in both
   directions, plus in-place upgrade with a pending commit, and downgrade refusal without
   modification.
2. Fixture checks green at every instant, on both fixtures, including the windowed states in their
   own invocation.
3. A `soak-nightly.yml` dispatch on the branch: 4 slots, green.
4. Every E2E lane run twice, with the second attempts read. Each lane's pass rate is compared with its
   Stage 0 baseline flake rate.
5. Cross-check (Apple, Windows, Android), build-check, release-link and audit, all green: the release
   gate as extended in Stage 0.
6. The cost ledger compared with the Stage 0 baseline. Every increase is listed with its reason;
   improvements are recorded.
7. Coverage re-pinned with `--repin` only.
8. One independent review pass, ranked. Security-reviewer covers C1, C2, C4, C6, C12, C15 and §2. A
   re-review checks only the fixes.

Then the owner merges, and Stage 1 is released.

---

## 14. Effort (ESTIMATED; measured cycle durations, counts estimated)

| Step | Cycles |
|---|---|
| 12 | guards only |
| 13–14 (1b share) | 8–12 C |
| 15 | 1 S + soak `pr` + fixtures + 1 compat |
| 16.2 | ≈ 8 T |
| 16.3 | ≈ 20 T + 1 S |
| 16.4 | ≈ 20 T + 1 S + compat |
| 16.5 | ≈ 34 T + 1 S |
| 16.7 | ≈ 18 T + 1 S + soak `pr` + S16 |
| 17 | 1 regeneration + 3 F + 1 builder test |
| 18 | none |
| 19 | 1–2 K |

That is ≈ 6 S, ≈ 100 T and 1–2 K, roughly 18–22 machine-hours on the serialised 4-core machine
(ESTIMATED). It excludes 1a's share and review time. The secondary estimate is ≈ 33 engineer-days
(ESTIMATED), against 43 before. The deferrals of §7, C17 and the `.onion` refusal going to 1a, and
the dropped re-key account for the difference.

## 15. Interfaces with Stage 1a

1. **Pins and guard values:** revs, `[patch]`, `mdk_pins.env`, the lockfiles, the universe and the
   supply-chain allowlist (step 12).
2. **One `nostr` crate shared with MDK:** the proof signer, the peeler signer, `Event` and
   `UnsignedEvent`.
3. **The terminal-refusal proof under MDK's early return** (16.2). Without it, every outright refusal
   leaves a commit pending for 24 h.
4. **Rule 16 text and the NIP-44 ceiling facts** (step 18).
5. **The adapter's `unsubscribe_account` parameter and the relay-client doubles** (§4.2).

## 16. Risks, ranked

| # | Risk | Severity | Retired by |
|---|---|---|---|
| 1 | 0175 or a whole-open decode refuses a Haven-written row; lockout | HIGH | both fixtures at step 15 / 16.3; typed outcome §9.5 |
| 2 | v0.10.4 MLS state fails to hydrate, or is silently quarantined, under upstream OpenMLS | HIGH | §9.4 assertions; fixture hydrate, send, receive, past-epoch decrypt, pre-upgrade KeyPackage join |
| 3 | Silent KeyPackage retirement at first open | HIGH (privacy and availability) | §9.4 count assertion |
| 4 | Welcome refused after a slot repoint | HIGH | C2 |
| 5 | Exception widened unnoticed | MEDIUM-HIGH | guard at step 12, before any other work |
| 6 | Replay-rotation stage/rollback loop in background | MEDIUM | C6 per-wake bound |
| 7 | Consumed KeyPackage left published | MEDIUM | C4 |
| 8 | Parked pass or rewind quarantine freezes a circle unnamed | MEDIUM | C8 |
| 9 | 4× peel caps break the foreground drain budget | MEDIUM | C10 with STOP-and-ask |
| 10 | Background first open under memory pressure | MEDIUM | §9.3 gate |
| 11 | The next MDK bump deletes `ingest` / `epoch` | LOW now | T-SESSION-PRIVATE; Stage 2 |

## 17. Still undetermined

- On-device time, memory and WAL size of 0169 and 0111 on a large account, and iOS/Android background
  budgets. These are relevant to O1 only.
- MessagePack positional compatibility of every OpenMLS stored entity between the fork and `6100df3`.
  OpenMLS's JSON storage KATs are byte-identical; the MessagePack form is closed only by the fixtures'
  hydrate, decrypt and join assertions.
- Whether `validate_leaf_account_identity_proof` at v0.16.0 accepts every proof v0.10.4 Haven embedded.
  The fixture join asserts it.
- Whether the FRB content hash covers `api.rs` test modules. Irrelevant under one regeneration after
  the last edit.
- Haven's inbox cursor rule for a gift wrap whose preview fails. The 16.5 test pins whatever it is.

---

## Appendix: Review ledger

Source ids: *Eng*, *Sec*, *Data*, *Tests* name the four independent reviews (engineering, security, data integrity, tests and CI) and their finding numbers; *R1–R6* name the binding rulings made on those reviews; D and O items are the owner's (master §2–§3); *Fix-check* rows come from the independent check that each required change landed.

| Source | Finding | What changed |
|---|---|---|
| Eng H1 / W1 | Token bans collide with the exhaustive arms and Haven's `.swap(` | §2.4 step 5: a construction ban with the exact pattern and per-case fixtures; `.swap(` dropped; `audit_recorder(` and `SharedRecorder` banned |
| Eng H2 / X1 / R4.f | The ratchet could not be bootstrapped | §2.4: feature lines + resolved check + file allowlist, no git base; Stage 2.0 redefines it |
| Eng X2 / R4.f | Two rows for one debt | One row, `T-SESSION-PRIVATE` (§2.5); `T-FINISH-STAGE-HOOK` kept as a separate upstream gap |
| Eng M1 / R4.e / Tests M1 | Test SQLCipher key | Step 12: `SqlCipherKey::raw` |
| Eng M2 / R4.d | Red-first ordering | §4 is mechanical only; §5 red inventory; §6 pairs |
| Eng M3 / X7 | C17 duplicated | Deleted here; 1a owns it |
| Eng M3 / X8 | C11 duplicated | 1b owns it (16.2); 1a contributes one test |
| Eng X11 / R4.k | `.onion` | Removed; 1a owns it |
| Eng X13 | Forensic guard tokens | §2.4 |
| Eng M6 | Pre-upgrade KeyPackage join assertion | The 16.4 gate consumes Stage 0's assertion and its repointed variant |
| Eng M8 / R4.g | Throwaway work | §7: the refresh, maintenance and scheduler parity ports and the stall seeding deferred, with reasons for what stays |
| Eng M9 / X12 / R3.i | FRB "CI only" | §10: one local regeneration after the last Stage 1 `api.rs` edit |
| Eng M12 | Shared-file ownership | §4 header |
| Eng A1 / W2 / Data M1 / R4.h | `migration_summary` is not a version | §9.3: `STORE_GENERATION` marker, written after every open, pinned via `open_encrypted_observed` |
| Eng A4 | Redundant forbid list | Dropped |
| Eng A6 | `expected_epoch` pin possible in Stage 1 | Not applied: Stage 2 C23 adopts it and deletes the discard in one change; the discard is pre-existing, not created by this bump |
| Eng A7 | Ban `SessionConfig::new(` | Applied in Stage 1 (§2.4 step 4), since `with_storage` lands here |
| Eng A9 | Comments counted | §2.4 step 3: code lines only |
| Eng X14 / X15 / R1 | Master order; single docs editor | §3–§13 follow steps 12–20; §11 is the single editor |
| Data M1 | Marker API | §9.3 |
| Data M2 | Silent losses at first open | §9.4 assertions |
| Data M3 / R4.j / Sec A8 | C12(b) premise false; not atomic | Re-key dropped; fail-closed detector over the refs hydrate binds (pending fanout rows, `Prepared`/`Attempting` evolutions, restorable groups), with a negative pin that confirmed evolutions sharing a ref still open (16.3); F10 to reviewed-unreachable |
| Fix-check: detector scope | Counting every evolution's `pending_ref` would refuse almost every v0.10.4 store with two self-updated circles (refs restart per session; a `Confirmed` evolution keeps its ref) | Detector narrowed as above; negative pin added |
| Fix-check: resolved-feature values | `cargo tree -f '{f}'` prints `default` alongside any enabled feature | §2.4 step 2 and §2.5 expect `default,test-support` / `default`, as Stage 2's 2.5 exit check does |
| Fix-check: construction-ban escapes | A single-variant `use` and a Haven trait `impl … for SendIntent` escaped (5a)/(5b); nested patterns are flagged, not only `if let` | (5b) extended; three fixtures added; the false-positive rule restated |
| Fix-check: leave step-down producer | Also staged by a plain `Leave` re-drive when the account is an admin among two or more | §1(a) row corrected; the "no Add committed" conclusion holds (isolated update keeps pending proposals) |
| Fix-check: tracker id | The NIP-44 row is Stage 1a's `T-NIP44-WELCOME-CEILING` | §11.3 renamed |
| Data M4 | Production key form | Consumed at the 16.3 gate from Stage 0 scenario 8; production passphrase still accepted (§3) |
| Data M5 / R4.i | `StoreNoSpace` | §9.5, with `Corruption` and `UnsupportedSchemaVersion` kept distinct |
| Data M6 | Fixture gaps | Stage 0 owns the recipes; 16.3/16.4 gates consume them |
| Data M7 / R4.i | Lockout becomes per-circle loss | §9.5 honest bound; copy reworded; no publish or mint while locked out |
| Data (classification, crash points) | — | §9.2, §9.8 |
| Data advisory | One connection serialises reads | 16.3 responsiveness pair |
| Data advisory | iOS backup rewind | Pre-existing; not made worse; not raised further |
| Data confirmed F / R5.d | Haven stores | §9.9 |
| Data HIGH-1 | Location-row retirement | Not applied here: Stage 2 (R5.b) |
| Sec M2 / R4.b | Forged signature filed `Malformed` | C15: dropped as if withheld; the genuine copy is taken in |
| Sec M3 / R6 O6 | 4× storage bound without an owner decision | O6 answered from source (not settable); `T-PEEL-CAP-4X`; owner list |
| Sec M4 / R6 O4 | Weekly refresh cost unstated | O4 default (0.75 × 30 d) applied; both sides stated; weekly refresh to Stage 2.1 |
| Sec A5 | Invitee not chosen | Resolved from source (§1(b)): no; pinned |
| Sec A7 | Pin the exact `mls_extensions` list | 16.4 pin |
| Sec M1 / R4.a | NIP-44 ceiling | 1a implements; tracker row and docs at step 18 |
| Sec "unverified": `AutoPublish` welcomes | — | Resolved (§1(a)): none reachable; C1 red is type-level; `RecoverMembers` construction banned |
| Tests M4 / R3.d | Early open-layer gate | Step 15 and 16.3 use `upgrade_fixture_open.rs` |
| Tests M5 | Shape-level coverage | Stage 0; consumed here |
| Tests M9 / R4.m | Exit checklist | §13 |
| Tests §4 | `KeyPackageRequirements` test unnamed | Named (16.4) |
| Tests §4 | C10 must use an injected budget | 16.7 states it |
| Tests HIGH-2 / R3.a | Cost baseline | Compared at step 15 and the §13 exit |
| Tests M10 / R3.l | `wn` interop | Not applied here: P1 after Stage 1 |
| R2 | Field sources | §9.6 classification test; v0.1.13 as the old peer and fixture |
| R1.c | Build cycles | §14 and per step |
| R4.n | Wrong claims | §1 "Corrections" |
| D3 | 0x800d | C7 pins; construction ban; `T-ACCOUNT-DEVICES` |
| (own) "Could not determine" items of the draft | Producers, invitee, `Full` background drive | Resolved (§1); the remaining ones are in §17 |
