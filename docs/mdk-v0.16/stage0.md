# Stage 0 — the safety net, built on today's code (MDK v0.10.4 → v0.16.0)

Status: plan, revised after independent review (2026-11-14). Nothing here has
been implemented.

Part of `docs/MDK_V016_MIGRATION_PLAN.md`, beside
`docs/mdk-v0.16/stage1a_nostr.md` (Stage 1a), `docs/mdk-v0.16/stage1b_mdk.md`
(Stage 1b) and `docs/mdk-v0.16/stage2_runtime.md` (Stage 2). Owner decisions
(D1–D4), owner items (O1–O13), migration rulings (R1–R6) and the master step
numbers are those of the master document. Review-finding ids ("T/CI HIGH-3",
"Eng M7", X1–X16) are mapped in Appendix C.

Stage 0 is everything that must exist, and be green on today's tree (MDK
`fcc85edd`, nostr 0.44, OpenMLS fork `59e7d3b`), before the dependency move
(Stage 1) starts. Stage 1 is then judged by it. Each unit says what it proves
today and what it turns red, or keeps green, at Stage 1.

Paths are relative to the repository root. `file:line` citations are at
`9a27d4a8` (the working branch after `main` was merged in).

---

## 0. Facts this stage rests on

### 0.1 What users hold

| Haven release | Date | MDK | Path under the new build |
|---|---|---|---|
| `v0.1.13` (`a45ab2d8`) | 2026-11-11 | v0.10.4 (`fcc85edd`) | in-place migration (schema 89 → 201) |
| `v0.1.11`, `v0.1.12` | 2026-08 | v0.9.4 | Haven's existing one-time reset (`storage_reset::reset_pre_v2_storage`, `haven-core/src/storage_reset.rs:94`), unchanged |
| ≤ `v0.1.10` | ≤ 2026-07 | old `mdk-core` | the same reset |

The working tree is 79 commits past `v0.1.13` and still on MDK v0.10.4. The
previous-release fixture and the compatibility "old peer" therefore represent
**`v0.1.13`**, the build users run, and not only today's tree (§S0.2a.4,
Appendix A).

### 0.2 Branch and merge points

Work happens on `claude/awesome-galileo-o5vxwd`; `main` was merged in at
`9a27d4a8`. "Merged" below means a green, pushed commit series on that branch,
ready for the owner to merge. The end of Stage 0 is a pull-request point.

### 0.3 Cost is counted in build cycles

Measured on the build machine (4 cores), 2026-11-14:

| Symbol | Cycle | Cost |
|---|---|---|
| **T** | full haven-core suite (4,135 tests) | ≈ 30 min (measured) |
| **C** | `cargo check --all-targets` or `cargo clippy --all-targets`, one root | ≈ 3.5 min (measured) |
| **F** | Flutter unit + widget suite (5,874 tests) | ≈ 4 min (measured) |
| **A** | `flutter analyze` | ≈ 25 s (measured) |
| **t** | one haven-core integration-test binary, incremental build + run | 4–6 min (ESTIMATED) |
| **K** | `tooling/soak` at `--profile soak` | cold ≈ 25 min, warm 5–8 min (ESTIMATED) |
| **W** / **X** | one `fixture write` / one `fixture check` invocation | 5–10 min / 2–4 min (ESTIMATED) |
| **P** | one push for a GitHub-only lane | — |

Engineer-day figures appear only as a secondary, ESTIMATED total (§2). Every
cycle count in §2's table and in a step's **Cost** line is ESTIMATED; only the
four durations marked "measured" above were measured.

### 0.4 What runs locally

Rust (all roots), Docker relays, the soak rig, `flutter analyze`,
`flutter test`, `flutter gen-l10n`, the ARB parity check and
`./scripts/regenerate_frb.sh` all run on the build machine: Flutter 3.44.8 and
`flutter_rust_bridge_codegen` 2.11.1 are installed, and regeneration of the
unchanged tree produces zero diff. **GitHub-CI-only:** emulator and simulator
lanes, Apple/Windows/Android cross builds, `build-check`, `release-link`, the
release gate's API reads, and repository settings.

---

## 1. Capture before the bump (cannot be reconstructed after it)

Each item is produced by today's code. After Stage 1 the harnesses are ported
to the new APIs, so a later reconstruction would mean keeping two harness
versions alive. Capture them now.

- [ ] **`fixtures/upgrade/haven-v0.1.13/`**: written by `v0.1.13` plus the
      test-only harness (S0.1, S0.2a.4).
- [ ] **`fixtures/upgrade/haven-pre-bump/`**: written by the last Stage 0
      commit (S0.1).
- [ ] **Old-peer binary for `v0.1.13`**, with its `cargo vendor` tarball,
      harness patch, rustc version and SHA-256, stored as a release asset
      (S0.2).
- [ ] **Wire-equivalence golden transcripts**, including the KeyPackage
      protocol tag values and the handshake header-name set (S0.9, S0.4b).
- [ ] **Cost-ledger baseline**: five runs per scenario and per soak `pr` arm,
      plus the open-time bucket from the CI runner image (S0.9).
- [ ] **Dependency-surface inventories and resolved feature sets** of
      `nostr` / `nostr-sdk` (S0.3).
- [ ] **Behavioural tests green on 0.44 that Stage 1 must keep green**: NIP-42
      with a positive control, no `user-agent`, re-issue, silent REQ, lag,
      targeted-fetch end shapes, gossip fence, NIP-44 edge and oversized-Welcome
      refusal (S0.4, S0.9, S0.10).
- [ ] **`haven/rust_builder` coverage floor** (S0.7).
- [ ] **The libfaketime probe verdict on the runner image** (S0.1). It decides
      which instants the committed fixtures are checked at.
- [ ] **Pass-rate baseline** of the last 20 `main` runs of each core E2E lane
      and of `soak-nightly` (S0.7, P0: Stage 1's exit compares against it).

---

## 2. Overview, in execution order

| Step | Unit | Proves | Pri | Build cycles (ESTIMATED count) | Depends on |
|---|---|---|---|---|---|
| 1 | S0.0 | Owner items presented; defaults applied | P0 | 0 | — |
| 2 | S0.6 | Absences are fenced, not timed | P0 (cursor/REQ/reopen sites), P1 (profile/KP) | 1 C + 12 t + 1 T | — |
| 3 | S0.5 | No MDK enum variant reaches a Security-Rule decision unseen | P0 | 4 C + 1 T | — |
| 4 | S0.10 | Bilingual refactors land on 0.44 | P0 | 3 C + 2 t + 1 T | — |
| 5 | S0.3 | Guards fail closed when a dependency name moves | P0 (part P1) | 1 C + 2 t + guard self-tests | S0.10 (resolver) |
| 6 | S0.4, S0.9 | NIP-42, header, re-issue and lag as behaviour; today's wire and costs recorded | P0 | 2 C + 8 t + 1 T + 1 K + 5 soak `pr` runs | S0.3 |
| 7 | S0.2a | Seams: dump/import, production keying, shapes, v0.1.13 portability | P0 | 2 C + 2 t + 1 K | — |
| 8 | S0.1 | Data written by `v0.1.13` opens and keeps its promises | P0 | 2 K + 2 W + ~10 X + 1 t + 1 T | S0.2a |
| 9 | S0.2 | `v0.1.13` and HEAD interoperate; in-place upgrade; downgrade | P0 | 1 K + 4 compat runs × ~3 | S0.2a, S0.1 |
| 10 | S0.7 | CI wiring, release gate, lockfile, `release-link`, coverage floor; exit | P0 (part P1) | 1 T-equivalent coverage run + 1 F + 1 A + ~4 P | all |

P0 total (ESTIMATED): about 7 T + 18 C + 27 t + 5 K, plus the soak and fixture runs. That
is roughly 10–12 hours of machine time (ESTIMATED), serialised on four cores,
plus CI pushes. Secondary figure: about 26–32 engineer-days (ESTIMATED).

### Rules every unit follows

- **No sleeps.** Every wait is a notification (`RecordingFront::wait_for`,
  `haven-core/src/relay/recording_front.rs:122`) or a bounded poll
  (`tooling/soak/src/rig/mod.rs:381` `poll_until`) with a bound from
  `oracle::bounds`. An absence is asserted only after a positive fence: an
  observed event that is ordered after the one whose absence is claimed.
- **Rule 15 holds for the instruments.** Fixtures, transcripts, ledgers and peer
  protocol lines carry `sim` handles or placeholders, never identifiers. Every
  new process's capture passes `haven-logscan`, with its needles declared
  through `SimWorld::declare_to` (`tooling/soak/src/rig/world.rs:742`).
- **Seams are test-only.** Every new seam is
  `#[cfg(any(test, feature = "test-utils"))]`, sits beside the existing ones
  (`haven-core/src/nostr/mls/storage.rs:487-1410`), and is listed in
  `check_soak_test_only.sh`'s seam inventory.
- **Guards follow the house pattern.** Each new guard is a `repo-guards.yml`
  step with a planted-violation `--self-test` and a pinned
  `SELF_TEST_FIXTURES`.
- **No stubs, no skips.** A test that cannot run in an environment fails with a
  fixed message naming what is missing.
- **Review.** S0.4, S0.9 and S0.10 touch Rule 16 and key handling; S0.1 commits
  synthetic key material; S0.5 touches Rule 12/13 decisions. All of them get the
  security-reviewer and test-writer passes before the Stage 0 exit.

---

## Step 1 — S0.0: owner items and branch (P0)

**Goal.** Owner items do not block Stage 0. The owner is shown the list, and
Stage 0 proceeds on the stated defaults.

- Present items O1–O13 (the migration's owner list, with defaults). None of
  them gates a Stage 0 unit.
- Present the three items Stage 0 itself raises, with the defaults applied:
  - **S-O1. The release gate waits for the four core E2E lanes** (S0.7).
    - The iOS core-flow job's timeout is up to 245 min
      (`.github/workflows/e2e-ios.yml:124`), so a tag can wait that long.
    - A flaky failure is answered by `gh run rerun <id> --failed`, which the
      gate already reads through `filter=latest`
      (`scripts/ci/check_ci_verdict.sh:150-153`).
    - Default: yes.
  - **S-O2. The Flutter SDK is pinned in every workflow that runs `pub get`**
    (S0.7). Lockfile enforcement on a floating SDK turns red whenever `stable`
    moves an SDK-pinned package.
    - This changes CLAUDE.md's "Every other workflow keeps floating on `stable`"
      for Flutter; Rust keeps floating.
    - Default: yes.
  - **S-O3. A prerelease, `compat-peer-v0.1.13`**, holds the test-only old-peer
    binary.
    - It is not marked latest, and no workflow triggers on it (only `v*` tags
      trigger `release-build.yml:47`).
    - Default: yes.
- Owner action that cannot be done from the repository: **add required status
  checks to the `main` ruleset** (O10). `main` has no branch protection; its
  only ruleset holds `deletion`, `non_fast_forward` and `required_signatures`.
  The in-repo release gate is extended regardless (S0.7).
- Branch: `main` is already merged in (`9a27d4a8`).

**Exit.** The list is posted, and S-O1 to S-O3 with their defaults are
recorded beside O1–O13 in `docs/MDK_V016_MIGRATION_PLAN.md`.

---

## Step 2 — S0.6: timing-dependent tests made deterministic

**Goal.** Every absence or ordering assertion rests on a fence. No assertion is
weakened, and every precondition is kept.

**P0 sites** (cursor, inbox, REQ and reopen races):

| Site | Today | Fence |
|---|---|---|
| `haven-core/tests/live_sync_cursor_replay_e2e.rs:255` | `sleep(3 s)`, so a per-event advance lands visibly above the anchor | Wait for the wall clock to pass `advanced/1000 + 1` (`wait_until_after`, a condition that must become true, so its expiry never changes the verdict), then publish; keep the precondition assert. Dating the event higher is not enough: the per-event rule this test guards against clamps to `now` (`cursor_ms_for_event`, `haven-core/src/relay/cursor.rs`), and without the wait `now` and the anchor share a second, so the test passes with the defect present. The inbox live-wrap test (`inbox_cursor_poisoning_e2e.rs`) takes the same wait for the same reason |
| same file `:265` | `sleep(3 s)`, then "cursor unchanged" | Bounded wait until `group_events_taken_in_for_test()` (`haven-core/src/relay/live_sync/processor.rs:2494`) holds the event, **then** assert the cursor. A drop before ingest now fails loudly instead of passing vacuously |
| same file `:304` | `sleep(500 ms)` after restart | Use the file's `wait_cursor_at_least(…, opened_at2*1000, …)`, with `opened_at2` sampled before `engine2.start` |
| `inbox_cursor_poisoning_e2e.rs:389, :397, :483` | the same pattern on the inbox plane | Use the wrap's explicit `created_at` (`routed_giftwrap_at`). Fence on the inbox wrap being processed (add `inbox_events_taken_in_for_test` beside `note_taken_in_for_test`, `processor.rs:2483`, if no inbox record exists) |
| `inbox_cursor_poisoning_e2e.rs:466` and `cursor_poisoning_e2e.rs:931` | `drop(…); sleep(50 ms); new_unencrypted(…)`, which races the Rule-14 session release | Bounded poll until `is_session_live(&session_db_path(dir))` (`haven-core/src/nostr/mls/storage.rs:125`) reads `false`, then open. This is exactly the rig's wait (`tooling/soak/src/rig/restart.rs:131-137`) |
| `live_sync_two_engine_converge_e2e.rs:176` | `sleep(500 ms) // both REQs register` | Bounded wait until `endpoint_settled_for_test(&relay)` (`haven-core/src/relay/live_sync/session.rs:1735`) holds for both engines |
| `live_sync_privacy_config_e2e.rs:368-385` | a 1.5 s absence window ("never adopts a gossip-discovered relay"), with no positive fence | See below |

**The gossip site in detail.**

- Arm `DialWatch` (`haven-core/src/relay/dial_witness.rs:33`) before the engine
  starts.
- After the NIP-65 list is stored on g1, drive one complete engine cycle: a REQ
  answered by EOSE on every configured relay, so that `endpoint_settled_for_test`
  holds for all three. Any gossip-driven relay add in nostr-sdk 0.44 happens
  inside such a call.
- Then assert `dials_cover_exactly(dials, configured)` (`dial_witness.rs:70`).

This bounds the absence by completed client calls, not by time. Stage 1
replaces it with `a_verified_client_has_no_gossip_store`. A positive gossip
control is not added at 0.44: no in-memory `NostrGossip` store exists in the
0.44 crates, and the existing test's own note records why an `.invalid` phantom
control is flaky.

**P1 sites.** These sleeps follow a publish that already awaited `OK`, and
`nostr-relay-builder` saves before it sends `OK`. Delete them. Where a raw
`client.send_event` does not await `OK`, wait on `output.success`. Where a
replaceable slot is read, keep a bounded read-back fence.

- `profile_plane_separation.rs:349`
- `profile_kind0_round_trip_e2e.rs:82, 120, 128, 159, 174, 176, 234`. For
  `:120` and `:174`, use `build_metadata_event(…, Some(first.created_at))`
  (`haven-core/src/profile/publish.rs:102-117`) instead of sleeping 1.1 s.
- `profile_group_isolation_e2e.rs:85, 155`
- `maintenance_per_relay_e2e_test.rs:184, 234, 323`
- `kp_rotation_e2e.rs:171` (`settle()`)

**Verification.**

- Local: `cargo test --test <file>` for each file.
- Each changed test runs 20 times in a row under `taskset -c 0,1` (reruns of
  the built binary, no rebuild).
- A mutation is caught: make the processor drop the live event before ingest,
  and `:265` turns red.
- CI: `haven-core-suite`.

**Exit.** No `sleep(` remains at the P0 sites, and each P0 test is green 20/20
under two cores.

**Cost.** 1 C + about 12 t + 1 T.

**Risk.** An inbox "taken in" record may need a new test seam. It is test-only.

---

## Step 3 — S0.5: exhaustive decisions over MDK and rust-nostr enums (P0)

**Goal.** MDK v0.16.0 adds `IngestOutcome::GroupRecovery`, new `SendIntent`
variants (including `StepDownAndLeave` and `EnableAccountDevices`) and four
`GroupEvent` variants. Each would compile silently into today's wildcards. After
this step, every such variant that reaches a Security-Rule decision is a compile
error at Stage 1.

All of `IngestOutcome`, `GroupEvent`, `SendIntent`, `FanoutTargetStatus`,
`StorageError`, `PublishWork`, `EpochState`, `MessageState`, `GroupStateChange`,
`OpenMlsContentKind` and `TransportReconciliationRoute` are exhaustive (no
`#[non_exhaustive]`) at both tags. `nostr::TagStandard` is exhaustive at 0.44.8
and absent from the fork (a loud break at Stage 1). `RelayMessage` is exhaustive
in both. No `#[expect]` exception is therefore needed for a foreign
`#[non_exhaustive]` enum.

### Changes

1. **One Rule-12 classifier.** "Is this ingest taken in, and does the cursor
   hold" is decided four times today, each with a wildcard or `matches!`:
   - `haven-core/src/nostr/mls/manager.rs:3961-3965`
   - `haven-core/src/relay/catchup.rs:1234-1236` and `:1300`
   - `haven-core/src/relay/live_sync/processor.rs:1281`

   They become one exhaustive
   `fn ingest_disposition(&IngestOutcome, left_object_unpersisted) -> Disposition`
   in `nostr/mls/manager.rs`, with variants `TakenIn` / `NoRoom` / `Unpersisted`.
   Each caller maps the `Disposition` to its own result. This deletes code, and
   a new variant breaks compilation in exactly one place.
2. **One Rule-13 classifier.** Today the status decisions are spelled separately:
   - `owes_an_attempt` (`haven-core/src/relay/fanout.rs:1579-1586`, a `_ =>`
     arm);
   - `a_relay_may_hold` (`fanout.rs:2026-2030`, `contains(&Attempting)`);
   - the `all(NotAttempted)` tests at `fanout.rs:1466`, `:2534` and
     `manager.rs:15316`.

   They become exhaustive matches over all six `FanoutTargetStatus` variants
   through one `fn status_exposure(FanoutTargetStatus) -> Exposure`.
3. **Every other wildcard on a listed site** (Appendix B.1) becomes an
   exhaustive match. A `Result`/`Option` wildcard that also swallows `Err`
   (`manager.rs:4113`, `:8270`) gets an explicit `Err(_)` arm whose current
   meaning is stated.
4. **`if let` / `let … else` (16 sites) and `==` / `!=` / `.contains(&…)`
   (17 product sites) over MDK enums.** These are listed with their Rule in
   Appendix B.2 and B.3.
   - The ones on a Security-Rule decision are converted by hand to exhaustive
     `match` (or routed through the two classifiers).
   - The rest carry `// mdk-enum-reviewed: <reason>`.
   - `clippy::wildcard_enum_match_arm` does not see these forms, nor
     `matches!`, whose expansion is an external macro.
5. **The lint.** Add `#![deny(clippy::wildcard_enum_match_arm)]` at the top of:
   - `nostr/mls/manager.rs`
   - `relay/fanout.rs`
   - `circle/manager.rs`
   - `relay/catchup.rs`
   - `relay/manager.rs`
   - `relay/live_sync/processor.rs`
   - `relay/live_sync/supervisor.rs`
   - `haven/rust_builder/src/api.rs` (not `frb_generated.rs`)

   It is a restriction lint, outside pedantic/nursery. The existing clippy steps
   run it at no extra CI time.
6. **The scope test** `mdk_enums_are_matched_exhaustively`, in
   `haven-core/tests/dependency_surface.rs` (S0.3):
   - The enum names are computed from the resolved MDK and nostr sources (all
     `pub enum` items, parsed with `syn`).
   - Every file under `haven-core/src` and `haven/rust_builder/src` (excluding
     `frb_generated.rs`) that names `<MdkEnum>::<Variant>` in a `=>` arm must
     carry the deny attribute.
   - Every `matches!(…, <MdkEnum>::…)`, `if let`/`let … else` pattern, `==`/`!=`
     comparison or `.contains(&<MdkEnum>::…)` must be on a line carrying
     `// mdk-enum-reviewed: <reason>`, with a non-empty reason, or the test
     fails.

**Interface with Stage 1.** Exhaustive arms will name `StepDownAndLeave`,
`EnableAccountDevices` and `RecoverMembers`. Stage 1's guard therefore bans
*constructing* those three intents, never naming the variants in a pattern: a
construction site, a `use` that imports a variant, an alias of `SendIntent`,
and `Self::…` inside an `impl … for SendIntent` are all refused
([`stage1b_mdk.md`](stage1b_mdk.md) §2.4). It adds no `.swap(` token: Haven has
ten legitimate atomic `.swap(` calls.

**Verification.**

- Local: `cargo clippy --all-targets -- -D warnings` in `haven-core` and
  `haven/rust_builder`.
- The full suite runs unchanged. This is a refactor-only commit series, with no
  behaviour change and no test weakened.
- Planted negatives: a `_ =>` on `IngestOutcome` in a scoped module fails
  clippy; an unmarked `if let SendIntent::Leave{..}` fails the scope test.
- CI: the existing clippy steps and `haven-core-suite`.

**Exit.** Clippy is clean, the scope test is green, and both planted negatives
are red.

**Cost.** 4 C (clippy iterations over two roots) + 1 T.

**Risk.** The diff in `manager.rs` is large but mechanical. Review it as a pure
refactor.

---

## Step 4 — S0.10: bilingual refactors before the bump (P0)

**Goal.** Some changes have the same spelling at nostr 0.44 and at the fork.
Landing them on 0.44 shrinks Stage 1's compile sweep, and each is a design
improvement in its own right.

1. **One `nostr::` import convention.** Module paths
   `nostr::{event, key, types, filter, message}::…` and
   `nostr::nips::nip01::Metadata` exist at 0.44 (`nostr-0.44.8/src/lib.rs:43-65`).
   This is the `nostr::` half of Stage 1a's path table; `nostr_sdk::relay::…`
   paths stay for Stage 1.
2. **`SecretKey::generate()` / `Keys::generate()`** replace the direct
   `secp256k1` use in:
   - `haven-core/src/nostr/keys.rs`
   - `haven-core/src/nostr/identity/keypair.rs`
   - `haven-core/src/nostr/event.rs`
   - `haven-core/src/nostr/mls/signer.rs`
   - `haven-core/src/relay/verified.rs` tests

   This needs a security review: key generation.
3. **Shared source-reading helper.** `mdk_source(package, file)` /
   `sdk_source(file)` move into `haven-core/tests/helpers/`, replacing the copies
   at `fanout_transport_matrix.rs:548`, `negentropy_e2e.rs:372` and
   `security_rule_gates.rs:5190`.
   - It resolves the package through `cargo_graph::host_metadata()`
     (`haven-core/tests/cargo_graph/mod.rs:6`).
   - It asserts the package's `source` equals the pin in
     `scripts/ci/mdk_pins.env`. This step adds
     `HAVEN_NOSTR_SOURCE="registry+https://github.com/rust-lang/crates.io-index"`
     there.
   - Every extraction asserts exactly one match and a minimum length.
   - A stale registry copy, or a second `nostr` in the graph (Stage 1 has two),
     can then never be read silently.
   - This also covers the MDK-facing half of the old "anchored reads" item for
     `security_rule_gates.rs`.
4. **Delete `haven_core::nostr::encryption`**, under the NIP-44 ceiling rule:
   Haven keeps refusing any Welcome whose NIP-44 layer exceeds the pre-fork limit
   while `v0.1.13` may be in the field. It has no production caller; its only
   users are two tests. In the same change:
   - **`haven-core/tests/nip44_plaintext_ceiling.rs`** keeps its edge assertions
     on the path the NIP-59 layers call: `nip44::encrypt` accepts exactly 65,408
     bytes and refuses 65,409 with `MessageTooLong`. Only the half that called
     Haven's wrapper goes.
   - It gains a **product edge test** (haven-core e2e, through the driver's
     `add_members` on a local relay behind `RecordingFront`),
     `an_invite_whose_welcome_exceeds_the_nip44_ceiling_sends_nothing`:
     - An invite whose Welcome's seal plaintext exceeds 65,408 bytes fails
       through today's error path: `PeelerError::WrapFailed` →
       `EngineError::Peeler` → the circle change fails → the FFI's generic,
       redacted failure. Today's refusal is **not** a typed outcome, and
       Stage 1 keeps it untyped.
     - The front sees no kind-1059 and no kind-445 frame for that invite, and
       the circle's epoch is unchanged.
     - The control: an invite under the limit is sent.
     - Stage 1a (§C.8.3) adds two assertions at its step 16.4 (no fanout row;
       the circle's sends are not held). They are not asserted on v0.10.4,
       which records the invite's commit message before it wraps the Welcome
       (MDK v0.10.4 `cgka-engine/src/message_processor/send.rs:335-382`).
     - This test is what Stage 1's own refusal must keep green when the fork's
       extended NIP-44 length removes the library limit.
   - `proptest_security.rs`'s NIP-44 properties are re-pointed from Haven's
     wrapper to `nostr::nips::nip44::{encrypt, decrypt}` over sender/receiver
     `Keys`, the API the NIP-59 layers use, so every property Welcomes rely on
     stays proved on the production path. Only
     `all_zero_key_encryption_roundtrips` goes, because the keys API cannot
     express a raw all-zero conversation key (the full list is in
     `docs/mdk-v0.16/stage1a_nostr.md` §C.8.4).
   - The `src/nostr/encryption/` coverage-floor row is removed only with
     `scripts/ci/check_coverage_floors.sh --drop-stale`.
   - The RNG-backed `nostr::nips::nip44::encrypt` still exists at the fork; only
     `v2::encrypt_to_bytes` without a nonce is gone. The Stage 1 rewrite needs
     no hand-port.

**Verification.**

- Local: `cargo check --all-targets` in all three roots, then the suite.
- Security review of items 2 and 4.

**Exit.** The suite is green on 0.44. `encryption` is gone. The ceiling and
product edge tests are green.

**Cost.** 3 C + 2 t + 1 T.

**Risk.** The product edge test needs an invite large enough to cross the
ceiling: a rumor of more than 40,960 bytes, about 150 members (ESTIMATED). The test mints synthetic member
KeyPackages in-process; it publishes none of them as devices.

---

## Step 5 — S0.3: guards that fail closed (P0 except where marked)

**Principle.** A guard keyed to a dependency's spelling must prove the spelling
exists. A rename then turns it red instead of letting it pass silently.

### S0.3c `haven-core/tests/dependency_surface.rs` (new)

Each inventory works the same way:

1. It resolves the crate through the S0.10 helper, which asserts the source.
2. It parses the public surface with `syn`. A column-0 `}` heuristic misses
   nested `impl`s, so it is not used.
3. It compares the surface, in both directions, with an exact committed set
   recorded from today's sources.
4. For each name in the *banned* partition, it runs **the guard script itself**
   against a planted fixture tree (`REPO_ROOT_OVERRIDE`) containing a synthetic
   call (`Type::name(`, `.name(`, `name:`), and asserts the script fails.

Running the script, rather than re-evaluating its regex in Rust, matters because
grep ERE and Rust `regex` differ.

| # | Surface | Guard it keeps honest | Pri |
|---|---|---|---|
| I1 | `pub fn` / builder fields matching `auth\|signer\|authenticat` in `nostr-sdk` `src/client/**` and `nostr-relay-pool` | `check_engine_client_options.sh` check 11 | P0 |
| I2 | Constructors (`new\|builder\|default\|with_*`) on `Client`, `ClientBuilder`, `RelayPool`, `RelayPoolBuilder`, `Relay`, plus any `impl` of a `Relay\|Client\|Pool` type | check 11 `_CLIENT_CONSTRUCTION` | P0 |
| I4 | `pub fn` / fields matching `recorder` in every MDK-sourced crate | `check_no_forensic_recorder.sh` `TOKENS` (`:32`) | P0 |
| I3 | Methods of `NostrRelayClient` / `TransportAdapter` / `NostrTransportAdapter` | `check_publish_client_no_subscription.sh` | P1 |
| I5 | `pub fn (open\|in_memory)…` in `storage-sqlite` and `cgka-session` | `check_sqlcipher_first_use_gate.sh` | P1 |

The enum list S0.5 uses is computed by the same parser. It is not a reviewed
set. The test runs offline, in seconds, in `haven-core-suite` and coverage.

### Per-guard changes

**Check 11 (G1/G2).**
- No new tokens at Stage 0. I1 and I2 make the guard fail closed.
- Add one self-test fixture per class: a `.signer(` field assignment, and a
  `Relay::new(`.

**`check_lockfile_universe.sh` (G3).**
- **Presence is required.** In CORE, `(( n <= 1 ))` (`:93-94`) becomes
  `(( n == 1 ))`.
- **Per-root expected subsets.** Each dependent root declares the `UNIVERSE`
  crates it must hold; a declared crate that is absent is a violation
  (`:98`'s `continue` becomes one). Today all three roots hold all 19 crates.
  Stage 1a adds `tooling/e2e/local-relay` with the nostr family only.
- **New pins.** Add `nostr-gossip` to `UNIVERSE`. Add a source check for
  `nostr nostr-sdk nostr-database nostr-relay-pool nostr-gossip` against
  `HAVEN_NOSTR_SOURCE`, modelled on the OpenMLS loop (`:119-125`).
- Self-test: "absent crate fails" and "nostr from an unpinned source fails".
  `SELF_TEST_FIXTURES` goes 20 → 22; Stage 1 counts from 22.

**`check_mdk_supply_chain.sh` (G4/G5).** Stage 0 builds the mechanisms; Stage 1
changes only the values.
- The MDK half of `FORBIDDEN_CRATES` becomes an **allowlist** equal to
  `cgka-engine cgka-session cgka-traits fs-private marmot-forensics storage-sqlite transport-nostr-adapter transport-nostr-peeler`,
  with a reason each. The non-MDK denylist stays.
- Add `--nostr-features`: `cargo tree -e features,no-dev -i nostr` (and
  `-i nostr-sdk`) on `haven/rust_builder` must equal the sets recorded today.
- Self-tests: "unlisted MDK crate", "missing listed crate", "new nostr feature".
  `SELF_TEST_FIXTURES` goes 18 → 21.

**G6: `tooling/soak/tests/pool_constants.rs`.** It replaces the `find`-based
`rust-check.yml` reconnect step, which is deleted in the same change.
- It resolves `nostr-relay-pool` from the soak root's own graph, and panics if
  the package is absent.
- It parses `DEFAULT_CONNECTION_TIMEOUT`, `MAX_RETRY_INTERVAL` and
  `JITTER_RANGE` (`nostr-relay-pool-0.44.3/src/relay/constants.rs:12,23,24`).
- It asserts `bounds::pool_reconnect() == 60 + 3 + 60` from the parsed values,
  plus the haven-core constants the step grepped.
- Stage 1 re-points it at the fork's `nostr-sdk/src/relay/constants.rs` and
  re-derives the bound.

**G7: `haven-core/tests/mdk_logs_reach_no_haven_sink.rs:28`.**
- The target denylist becomes an allowlist: every captured record's target is
  `haven_core`, the test crate, or `openmls`. The `openmls` line is the
  existing positive anchor.

**G10: `check_no_forensic_recorder.sh`.**
- Add the token regex `recorder:[[:space:]]*Some`. Self-test 8 → 9.
- Stage 1 adds `audit_recorder(` and `SharedRecorder`, and no `.swap(`.

**G11: `check_inner_location_kind.sh` check 6 (`:483-490`).**
- Read `HAVEN_MDK_REV` from `mdk_pins.env` instead of parsing the
  `cgka-session … rev` line. Keep "no pin → fail".

**`check_soak_test_only.sh` `FOREIGN_RE` (`:210`).**
- Derive the crate-prefix alternation from `tooling/soak/Cargo.lock`: every
  MDK-sourced package plus `nostr*` / `openmls*`, with `-` mapped to `_`.
- A planted `marmot_session::X` `{:?}` fails. This catches the Stage 1 rename.

**Cross-check `--locked`.**
- Add `--locked` to the four `cargo check --target` lines in
  `.github/workflows/cross-check.yml:33,37,61,109`.
- A `repo-guards.yml` step fails if any cross-check cargo line lacks it, with
  a self-test.

**G14: fault seams prove they still bite.** P0 for the seams that Rule 12/13
tests use; P1 for the rest.
- Each seam is a trigger installed by a fault seam in
  `haven-core/src/nostr/mls/storage.rs` (`set_*_fault_for_test`, `:681-1381`).
- After arming, the seam makes one engine call that must now fail, and asserts
  the failure.
- A trigger on a table MDK no longer writes would otherwise leave
  "store does not answer" tests passing vacuously after 87 migrations.

**Self-tests for guards that have none.**
- **P0** (Security Rules):
  - `check_no_exporter_label_override.sh` (Rule 11): plant
    `.with_exporter_label(` under `haven-core/src` and under
    `haven/rust_builder/src`.
  - `check_no_event_timestamp_cursor_advance.sh` (Rule 12).
- **P1, after the bump** (unrelated to it): clock-skew parity, INTERNET
  permission, locale privacy, committed secrets, tile cache, tile provider,
  busy marker, liveness port, profile override, l10n parity.

**Verification.**
- Local: every changed guard plus `--self-test`;
  `cargo test --test dependency_surface`; `cargo test --test pool_constants`
  in `tooling/soak`.
- Mutation demonstrations (local, not committed):
  - a lockfile copy with `cgka-session` renamed → G3;
  - a vendored copy of nostr-sdk with `pub fn authenticator` → I1;
  - one constant changed in a vendored `nostr-relay-pool` → G6.
- CI: `repo-guards.yml`, `rust-check.yml`.

**Exit.** Every changed guard is green with its pinned fixture count, and each
mutation is red.

**Cost.** 1 C + 2 t; the guard scripts need no build.

---

## Step 6 — S0.4 and S0.9: behaviour proofs and today's wire and costs

### S0.4a — no NIP-42 answer on any client Haven builds (Rule 16, P0)

New file: `haven-core/tests/relay_auth_and_handshake_e2e.rs`.

**Relay extensions** in `haven-core/src/relay/scripted_relay.rs` (test-utils):
- `challenge_on_connect(text)`: `["AUTH", text]` as the first frame on each
  socket.
- `require_auth()`: until a socket has sent `AUTH`, every REQ is answered
  `CLOSED "auth-required: …"` and every EVENT `OK false "auth-required: …"`.
- `auths()`: counts the `AUTH` frames received. Today `Script::replies` drops
  them (`_ => Vec::new()`).

**Tests**, one per production client:
1. **Publish client** (`RelayManager`, `haven-core/src/relay/manager.rs:636`).
   - Fanout publish → classified `AuthRequired`.
   - Fetch → nothing.
   - Fence: `connections() ≥ 1` and `offers() == 1`.
   - After shutdown, `auths() == 0`.
2. **Live-sync engine** (`LiveSyncCore::new_local`, `session.rs:966`).
   - Fence: the refused-REQ outcome, and the stored event not in
     `group_events_taken_in_for_test`.
   - After `stop()`, `auths() == 0`.
3. **NIP-77 pass**, driven through the catch-up sweep that calls
   `neg_remote_ids` (`relay/manager.rs:1983`). The same pattern.
4. **Positive control.** A test-built
   `Client::builder().signer(keys).opts(ClientOptions::default().automatic_authentication(true))`
   **does** obtain the event, with `auths() ≥ 1`. On 0.44 the pool queues
   `AUTH` only with auto-auth on, and re-subscribes after `auth-required`.
   Stage 1 respells only this control.

### S0.4b — `no_relay_socket_sends_a_user_agent` (P0)

- `RecordingFront` accepts with `tokio_tungstenite::accept_hdr_async` and
  records, per connection, the **names** of the request headers (lower-case,
  never the values).
- For the publish client, the engine client and the NEG pass, the name set on
  every connection equals one pinned set. The expected set is `host`,
  `connection`, `upgrade`, `sec-websocket-version`, `sec-websocket-key`, plus
  possibly `sec-websocket-extensions` (recorded at implementation). It does not
  contain `user-agent`.
- If today's build already sends a `user-agent`, that is reported to the
  owner, never pinned.
- At Stage 1 this goes red on the fork's default transport. Stage 1 adds only
  the `DefaultWebsocketTransport` control.

### S0.4c — relay-pool assumptions as Haven behaviour (P0)

Existing proofs are kept:
- REQ to a disconnected relay is not coverage (`live_sync_engine_e2e_test.rs`,
  `live_sync_burst_e2e.rs`).
- Every delivery is forwarded and Haven de-duplicates
  (`resource_refused_e2e.rs`).
- The NIP-40 drop point (`relay_pool_expiry_drop_point.rs`).
- `client.relay()` on an unknown relay is folded (`relay/manager.rs` tests).

New, in `live_sync_engine_e2e_test.rs`:
- **`a_req_closed_rate_limited_is_reissued_and_delivers`.**
  - Needs a new `ScriptedRelay::answer_once` (one use, newest first).
  - Script B = `[Event(loc), Eose]`, then A = `[Closed("rate-limited: …")]`
    once.
  - Assert the location is taken in and the circle reads caught up.
  - The subscription id is deliberately not asserted. Stage 1 re-issues under
    the **same** id, by unsubscribing then subscribing, and this test must stay
    green on that design.
- **`a_silent_req_released_and_reissued_delivers`.**
  - A = `[Hold(rx)]` once, B = `[Event, Eose]`.
  - Release through `pass_the_eose_wait_for_test` (`session.rs:1719`).
  - Assert delivery.

### S0.4d — the lag test and targeted-fetch end shapes (P0)

**`a_lagged_notification_stream_holds_every_owed_cursor`.**
- A test-utils constructor builds the engine pool with notification capacity
  2 (`RelayPoolOptions::default().notification_channel_size(..)`,
  `session.rs:113`), and a test-utils gate holds the receiver loop before its
  first poll.
- The scripted relay sends ten events and an `EOSE`, then nothing.
- A second receiver the test takes on the same pool before the REQ is polled
  until it yields the `EOSE` after its own `Lagged`. That proves the broadcast
  has overrun the product's receiver, with no timing.
- The gate opens. The product's first item must be `Lagged`, the circle's
  cursor must not advance, and its floors stay owed.
- The same test passes unchanged at Stage 1, where both streams are
  `notifications_with_gaps()` (Stage 1a §B.3.1).

**`targeted_fetch_end_shapes.rs`.**
- Each shape goes through the public `RelayManager` fetch entries that use
  `read_one_relays_answer` (`relay/manager.rs:2122`), against a `ScriptedRelay`
  that gains `Frame::HangUp`. The asserted `(drained, sorted event ids)`:

  | Shape | Drained | Events |
  |---|---|---|
  | `EOSE` | yes | all |
  | cap reached | no | — |
  | `CLOSED` | no | — |
  | socket hang-up | no | — |
  | idle timeout (`Frame::Hold`) | no | — |
  | a forged frame among genuine ones | — | the genuine ones only (Rule 16) |

- The assertions stay unchanged at Stage 1 and must pass on `acquire_events`.
- No parity port of the old loop is needed.

**Raw-pool gap tests are not written.**
- `a_bare_pool_relay_disconnected_without_a_task_never_dials_again` would be
  built on the raw 0.44 pool, so it cannot compile at the fork. It would have
  to be rewritten, not flipped.
- The Stage 1 removal of the wedge mitigation rests on the fork's
  ownership-lock argument plus the kept promise tests.
- The T-NEG-CLOSE gap is recorded instead by S0.9's cut-session golden
  transcript (W10).

### S0.9 — wire-equivalence transcripts and the cost ledger (P0)

**Goal.** Stage 1 is judged against today's wire and today's costs.
- A mechanical rewrite that changes a frame turns a transcript red.
- A regression in volume, such as extra re-issues, a missed `.to(..)`
  broadcast or a heavier fetch, turns the ledger red.
- An improvement is recorded.

**Files.**

| File | Change |
|---|---|
| `haven-core/tests/wire_equivalence.rs` | new |
| `haven-core/tests/wire/golden/<scenario>.jsonl` | committed transcripts |
| `haven-core/tests/wire/allowed_differences.toml` | empty at Stage 0 |
| `haven-core/tests/wire/cost_baseline.json` | the ledger |
| `haven-core/src/relay/recording_front.rs` | adds relay→client frame counts by verb (counts only, no frame text) and the S0.4b header names |
| `haven-core/src/relay/dial_witness.rs` | the existing watch (one per process) also counts admission-policy outcomes. `verified.rs:38` increments `admitted`/`refused` under `#[cfg(any(test, feature = "test-utils"))]`. Counts only, no identifier (Rule 15) |
| `haven-core/src/nostr/mls/storage.rs` | `store_page_count_for_test(db, key)`, through `open_tamper_connection` (`:1266`), after `PRAGMA wal_checkpoint(TRUNCATE)` |
| `CircleStorage` | the same for `circles-v2.db` |
| `tooling/soak/src/relay/ledger.rs` | adds client→relay frame counts by verb and EVENT counts by kind per plane |
| `haven-soak` | gains `--cost-out <path>`, which writes the run's ledger |

**Deterministic scenarios.** Each is driven through Haven's real
`RelayManager`, fanout and live-sync code against `RecordingFront` → a local
relay (or a `ScriptedRelay` where a verdict must be scripted):

| Id | Scenario |
|---|---|
| W1 | location publish |
| W2 | fanout commit accepted |
| W3 | fanout commit `OK false blocked:` |
| W4 | fanout commit `rate-limited:` ×3 |
| W5 | live group + inbox REQ to `EOSE` |
| W6 | re-issue after `CLOSED error:` |
| W7 | re-issue after `CLOSED rate-limited:` |
| W8 | re-anchor of a silent REQ |
| W9 | NIP-77 dry-run pass, complete |
| W10 | NIP-77 pass cut at Haven's deadline (today: no `NEG-CLOSE` on the wire) |
| W11 | targeted fetch by id |
| W12 | KeyPackage publish |
| W13 | kind-0 publish |
| W14 | engine pause/resume |
| W15 | open of the `haven-pre-bump` fixture's subject store (lands with step 8) |

**Transcript normalisation.**
- **Replaced** by first-appearance placeholders (`S1`, `E1`, `P1`, `H1`, …):
  per connection, every subscription id, event id, pubkey, signature, content,
  and `#h`/`#p` value.
- **Bucketed:** `created_at`, `since` and `until` become relative-time buckets
  (Δ from scenario start: 0, ≤1 s, ≤10 s, ≤60 s, ≤600 s, >600 s).
- **Renumbered:** connections become `C1…` by first frame. No URL appears.
- **Kept verbatim:**
  - verbs, kinds, tag names and arity, filter keys, `limit`;
  - the order within a connection;
  - the values of KeyPackage protocol tags (`mls_protocol_version`,
    `mls_ciphersuite`, `mls_extensions`, `mls_proposals`, `app_components`).
    These are protocol constants, not identifiers, so OpenMLS-default drift at
    Stage 1 shows here.
- The recorder refuses to write a transcript containing a run of 64 hex
  characters. That catches an identifier that escaped normalisation.

**Count definitions** (per scenario, per relay ordinal):

| Count | Definition and source |
|---|---|
| `frames_out[verb]` | client→relay frames by verb: REQ, CLOSE, EVENT, COUNT, AUTH, NEG-OPEN, NEG-MSG, NEG-CLOSE (`RecordingFront`) |
| `events_out[kind]` | EVENT frames by kind; `events_out[30443]` is the KeyPackage publications |
| `frames_in[verb]` | relay→client frames by verb; `frames_in[EVENT]` is the events fetched |
| `dials` | `DialWatch::dials().len()` (`dial_witness.rs:45`) |
| `verify` | admitted and refused `Event::verify()` outcomes in the admission policy |
| `pages` | `page_count` of the session store and of `circles-v2.db` at scenario end, minus at start, each after a TRUNCATE checkpoint |
| `open_bucket` | `⌊log2(ms)⌋` of the session open (W15 and each soak device open) |

**Recording.**
- The baseline is recorded on today's tree as five runs of each scenario.
- Each count is committed as `{min, max}`.
- `DialWatch` is one per process, so the scenarios in `wire_equivalence.rs` are
  serialised by a file-local `tokio::sync::Mutex`.
- For the soak `pr` arms (S01's single-relay outage, S06, S11, S13): five seeded
  runs with `--cost-out`, committed as `{min, max}` per arm.

**Comparison rule.** It is enforced by `wire_equivalence.rs` for W1–W15 and by
`haven-soak cost-compare` for the arms.

| Measure | Fails when | Notes |
|---|---|---|
| Transcripts | they are not byte-equal after normalisation, unless the difference matches an `allowed_differences.toml` entry | Each entry names the scenario, the frame inserted or removed, the reason and the tracker row. Goldens change only through `HAVEN_WIRE_BLESS=1` locally; CI never sets it |
| Counts in W1–W14 | value > `max` | value < `min` is printed as an improvement. The baseline is lowered only by a reviewed re-record. All counts except `pages` are expected to have `min == max`; `pages` carries its observed spread |
| Soak arms (fault-timed) | the **median** of five runs > the baseline `max` | a tolerance band, not equality |
| `open_bucket` | ≥ 2 buckets (≥ 4×) above the committed value | Gated only in the CI `upgrade` job, against the value recorded on that runner image. Printed locally, not gated |

Stage 1's known entries in `allowed_differences.toml`:
- `NEG-CLOSE` (plus an inert `CLOSE`) after a cut session;
- one `CLOSE` before a re-issued, still-registered REQ;
- one `EVENT` instead of three for `blocked:`.

Stage 2's measurements extend this ledger rather than re-baselining on the
Stage 1 build.

**Verification and cost (S0.4 + S0.9).**

- Local, in-process tests: `cargo test --test relay_auth_and_handshake_e2e`,
  `--test live_sync_engine_e2e_test`, `--test targeted_fetch_end_shapes` and
  `--test wire_equivalence`.
- Soak baseline: one K plus five `pr` runs, about 100 min (ESTIMATED).
- In CI, transcripts and W counts run per push in `haven-core-suite`. The soak
  ledger runs once now and once at the Stage 1 exit, not per push.
- Cost: 2 C + 8 t + 1 T + 1 K + 5 soak runs.

**Exit.**

- All tests are green on 0.44.
- Goldens and baselines are committed.
- Planted negatives (local):
  - a signer plus `automatic_authentication(true)` in `verified_client` turns
    test 1 red;
  - a `user-agent` injected through a copy of the front turns the header test
    red;
  - an extra `CLOSE` before a re-issue turns W6 red.

**Risks.**

- **Page-count spread:** recorded, not assumed.
- **Lag test:** the receiver gate is a new test-utils seam.

---

## Step 7 — S0.2a: seams and rig extensions for S0.1 and S0.2 (P0)

### S0.2a.1 Rig

**`SimDevice::open_in(tag, routes…, dir: StoreDir, keys, keying: Keying)`**,
next to `open_behind` (`tooling/soak/src/rig/device.rs:212`).
- The `dir` field (`:139`, `tempfile::TempDir` today) becomes
  `enum StoreDir { Temp(TempDir), Kept(PathBuf) }`.
- `Keying` has two variants:
  - `Keying::Test` uses `CircleManager::new_unencrypted`
    (`haven-core/src/circle/manager.rs:435`);
  - `Keying::Production { session_secret, circles_key_hex }` uses the
    production opener `CircleManager::new(dir, keys, Some(circles_key_hex))`
    (`:292`).

**What the production opener exercises.**
- `reset_pre_v2_storage` and the encrypted `circles-v2.db`.
- `SessionManager::new_with_notes` (`haven-core/src/nostr/mls/manager.rs:1255`):
  the keyring passphrase → `cipher_key` → PBKDF2, with
  `StorageConfig::storage_options()`.
- It runs under a test-utils keyring seam,
  `storage::use_mock_keyring_with_session_secret_for_test(secret: &[u8])`.
  The seam installs `keyring_core::mock::Store`, the pattern at
  `storage.rs:1476-1483` and `haven-core/tests/hard_reset_first_open.rs:48-52`,
  and plants the secret under `mls.session.key.v2`.

The mock store is process-global, so at most one production-keyed device opens
per process.

**`SimRelay::start_on(tag, port)` and `Proxy::start_on(…, port)`.**
- Today `tooling/soak/src/relay/mod.rs:117` and `relay/proxy.rs:236` bind
  port 0.
- Relay URLs are written into MLS group context and into `circles-v2.db`. The
  rig's `RelayMappedFanout` maps only the fanout transport; the engine and fetch
  clients dial the stored URL. The consumer must therefore serve the same
  addresses.
- Ports come from 31201–31216, below Linux's ephemeral range (32768–60999).
- Every invocation that binds them runs serially in one CI job (S0.7). None is
  a parallel `cargo test`.

### S0.2a.2 Dump and import: MDK's own recipe

Export:
- `export_store_plain_for_test(db, key, out)` lives in `storage.rs`, on
  `open_tamper_connection` (`:1266`), which already calls
  `sqlcipher_init::ensure()`, sets `cipher_compatibility = 4` and keys.
- It runs
  `ATTACH DATABASE '<out>' AS plain KEY ''; SELECT sqlcipher_export('plain'); DETACH DATABASE plain;`.
- `CircleStorage` gets the same.
- The writer then runs the stock `sqlite3 <plain> .dump`, from the apt package
  `sqlite3` (not installed on the build machine today; installed by the job and
  locally). It deletes the plaintext intermediate.

What `.dump` guarantees:
- It emits tables and rows, then indexes, triggers and views, so **no trigger
  fires on replay**.
- It ends with the `PRAGMA writable_schema` / `sqlite_sequence` block, so
  `AUTOINCREMENT` counters are preserved.
- It reproduces `sqlite_master.sql` verbatim. A later migration splits a stored
  view's SQL text, so this matters.

Import:
- `import_store_sql_for_test(sql, db, key, options)` opens through the same
  first-use-gated path and runs `execute_batch(sql)`. This is how MDK loads its
  own `account-v0.10.4.sql`.
- The key is either `StorageConfig::test_sqlcipher_key()` (`storage.rs:435`) or
  a production key: `cipher_key(passphrase)` (`:1426`), PBKDF2.

It refuses to export, as an error and not a filter, if any `haven_test_%`
object exists.

**Why SQL text.** The files are reviewable as synthetic-only, as MDK's are, and
successive fixtures diff. It is *not* true that an encrypted raw-keyed file
would be unopenable at Stage 1: `SqlCipherKey::raw` renders the same
`x'…'` PRAGMA that `SqlCipherKey::new` refuses. Stage 1 moves
`test_sqlcipher_key()` to `SqlCipherKey::raw`; Stage 1b owns that edit.

Text loses page-level state (an un-checkpointed WAL, free pages). That is
covered by S0.2 run D, which upgrades a live file the old binary wrote.

**Round-trip test.** `haven-core/tests/fixture_dump_round_trip.rs`:
1. Write a small store through product calls.
2. Export it, then `.dump`, then import.
3. Assert equal: `sqlite_master` rows, every table's rows sorted,
   `sqlite_sequence`, `auto_vacuum` and `page_size`.

The import must create the schema **before** MDK's first open. Stage 1's MDK
sets `auto_vacuum = INCREMENTAL` only on a database with no schema, and real
installs have `NONE`.

### S0.2a.3 Shape probe

`fanout_shapes_for_test() -> Vec<FanoutShape>` goes in `manager.rs`, beside
`fanout_probe_for_test` (`:9456`). It is a value-free summary per stored fanout
row:
- the `FanoutPendingKind` discriminant;
- application / proposal / group-evolution;
- the `FanoutTargetStatus` discriminant per target;
- failure with or without a rejection category;
- Haven's `INTERRUPTED` marker;
- whether post-confirmation Welcomes are present.

It is extended with the counts the shape list needs:
- `MessageState` and `EpochState` discriminants;
- `GroupEvolutionPhase` × `pending_ref` presence;
- queued-intent discriminants;
- `pending_application_events` row count.

It renders no identifier.

### S0.2a.4 Building the harness against `v0.1.13`: feasible

The harness is the test-only code of S0.2a, S0.1 and S0.2: `tooling/soak/**`,
plus haven-core hunks that are `#[cfg(any(test, feature = "test-utils"))]`
only. It is kept in commits that touch nothing else, so the same series applies
to `a45ab2d8`.

**Assessment** (Appendix A has the diff). Between `a45ab2d8` and `9a27d4a8`:

- **The MDK pin is identical** (`fcc85edd`). The lockfiles differ only in
  `quinn-*` and `windows-sys` patch versions; the manifests differ only by
  `rust-version`.
- **`haven-core/src/nostr/mls/storage.rs`, the home of every store seam, is
  byte-identical.**
- **Every seam the writer drives exists at `v0.1.13`:**
  `holds_unread_input_for_test`, `fanout_probe_for_test`,
  `welcome_record_ids_for_test`, `key_package_bundle_count_for_test`,
  `stage_unrecorded_for_test`, `hold_pager_commits_for_test`,
  `neg_inventory_for_test`. Each is checked by `git grep` at both revisions.
- **The soak rig differs by +108/−24 lines.** At HEAD:
  - `SimDevice::unread_input_taken_in` is new;
  - the quiescence oracle reads `passes_under_way()`, where `v0.1.13` reads
    `in_flight_publishes()`.

  The harness uses neither, so the series applies to either tree.
- **Commit-hygiene rule.** No harness commit may call an API added after
  `a45ab2d8`. This is enforced mechanically, because the `compat-peer` build
  (S0.2) applies the series with `git am -3` and compiles it.

**Procedure.**

```text
git worktree add "$WT/v0.1.13" a45ab2d8
git -C "$WT/v0.1.13" am -3 <harness series>      # recorded in old_peer.toml
CARGO_TARGET_DIR="$SHARED_TARGET" cargo build --locked --profile soak \
    --manifest-path "$WT/v0.1.13/tooling/soak/Cargo.toml"
```

`$SHARED_TARGET` is shared with the main worktree: the dependency graph is
nearly identical, and disk is limited. In CI the checkout needs the revision
fetched (`fetch-depth: 0`, or `git fetch origin a45ab2d8`).

**Write-path differences the `v0.1.13` fixture therefore covers** (and a
HEAD-only fixture would miss):

| # | Store | `v0.1.13` | HEAD |
|---|---|---|---|
| 1 | `circles-v2.db` `profile_sync_state` | no `covered_pool_json` column | adds it at open (`ALTER TABLE … ADD COLUMN`, `haven-core/src/circle/storage.rs`, `table_has_column` guard), NULL on existing rows |
| 2 | `profile_sync_state` | the own row exists only once a sync wrote one | `ensure_profile_sync_row` (INSERT OR IGNORE) inside the profile transaction (`circle/storage_profile.rs`) |
| 3 | `profiles` miss ladder | `next_retry_at` up to now + 6 h (`PROFILE_MISS_BACKOFF_SECS` = …, 21,600) | ladder capped at 30 min; a `Known` row now honours `next_retry_at`. The difference is in values, not shape |
| 4 | MDK tables (second handle, `manager.rs`) | — | no write-path change. The 46-line diff is read-side (`holds_unread_input` releasing a hold the engine already records) |
| 5 | `relay/fanout.rs` | — | no row-shape change. HEAD adds in-flight counting and stops a drive after its first send once the mode no longer stands, so rows are left in the same shapes, possibly at an earlier status |

**If the series ever fails to apply or build** (for example, a future seam
needs a post-`v0.1.13` API):
1. The `haven-pre-bump` fixture alone is checked.
2. Rows 1–5 are covered by explicit recipes in it:
   - drop the `covered_pool_json` column before export, as the existing test
     `the_covered_pool_column_reaches_an_existing_database_unset` does;
   - delete the own `profile_sync_state` row;
   - write a 6 h `next_retry_at`.
3. Each recipe is asserted at check.

**Cost.** 2 C + 2 t (round-trip test) + 1 K, plus 1 K cold for the `v0.1.13`
worktree in step 8.

**Exit.**

- The round-trip test is green.
- The `v0.1.13` worktree builds with the harness.
- `check_soak_test_only.sh` lists the new seams.

---

## Step 8 — S0.1: previous-release database fixtures (P0)

**Goal.** Before the bump merges, prove two things:
1. Every state a real install can hold, written by `v0.1.13` itself, opens.
2. Each state's promise holds afterwards.

The check is validated now against v0.10.4. At Stage 1 the same check proves
migrations 0090–0201 and upstream OpenMLS. Migration 0175 decodes every
`cgka_outbound_fanout` and `cgka_group_evolutions` row, and refuses the account
on one failure. MDK's own v0.10.4 fixture has zero rows in every table Haven's
Rules 5, 12 and 13 depend on.

### Durable shape

`haven-soak fixture write --out <dir>` and
`haven-soak fixture check --dir <dir> --at <instant> [--state <ids>]` run as
library modules (`tooling/soak/src/fixture/{mod,write,check,manifest}.rs`),
with `fixture` added as a first positional word in `main.rs`.

The rig's exit codes:

| rc | Meaning |
|---|---|
| 0 | clean |
| 1 | violation |
| 2 | rig broken |
| 3 | proves nothing |

The soak rig is the right home: real engines, stores and relays behind a fault
layer; every recipe is an existing arm or rig operation; the Rule-15 posture;
a separate root that never ships; and it is built on every push.

### Committed form

```text
fixtures/upgrade/haven-v0.1.13/      written by a45ab2d8 + harness
fixtures/upgrade/haven-pre-bump/     written by the last Stage 0 commit
  README.md                synthetic-data statement; writer revision; recipe
  manifest.json
  subject/session.sql  subject/circles.sql     account S (member in most circles)
  admin/session.sql    admin/circles.sql       account A (admin of most circles)
  relays/plane-<n>.jsonl                       every event each relay stored
```

**Manifest.**
- `schema`.
- The writer: Haven commit, harness commits, `haven-core/src` tree hash,
  `HAVEN_MDK_REV`, rustc.
- `written_at`, and **one anchor instant per state**.
- Relay ports and plane roles.
- The state → circle handle map (`soak-circle-<n>`).
- The frozen events' JSON, and the withheld backlog's ids.
- The expected values per state: epoch delta, `circle_recovery` cause and
  whether it is time-invariant, KeyPackage bundle count, quarantined set,
  shape multiset, `max(cgka_schema_migrations)`, `page_size`, `auto_vacuum`.
- Per-file SHA-256 and per-table row counts.
- Test-only secrets, all synthetic:
  - `test_only_identity_secret_hex` per account;
  - `test_only_session_secret_hex` and `test_only_circles_key_hex` for S.

**Keying.**
- A is imported under the raw test key.
- **S is imported under the production key form:** a PBKDF2 passphrase,
  production `storage_options()` and an encrypted `circles-v2.db`. It is opened
  through `CircleManager::new` with the mock keyring, so the path every real
  user takes crosses the upgrade.

**Hygiene.**
- The writer asserts that its output contains no UUID shape, so
  `check_no_committed_secrets.sh` stays green with an empty allowlist, and no
  `haven_test_%` object.
- Relay addresses are `ws://127.0.0.1:312xx`.

**Size.** 2–6 MB (ESTIMATED), reported in the pull request.

**Lifetime.** A fixture is written once and never regenerated. A directory is
removed only when the owner raises the minimum upgrade source, in that same
change. Each later storage boundary adds a directory written by the release
before it (the Stage 2 boundary adds one written by the Stage 1 release).

### Required shapes (the writer's self-check: rc 2 if any is missing)

**Criterion.** The coverage criterion is these shapes, **not** "every table
non-empty".
- A shape that cannot be produced at v0.10.4 goes on a reviewed list in the
  README, with the code citation that proves it unreachable.
- A listed shape that is present is also rc 2.
- `circles-v2.db` completeness is not a criterion: the MDK migration never
  touches that file. The Haven-only rows below are kept as P1 for future
  Haven-schema boundaries.

**Windowed states.** F2, F8 and F28 depend on a location's 228 s NIP-40
lifetime. They are written **last**, inside one window, and checked by their
own invocation (`--state F2,F8,F28`, at each state's anchor + 5 s). Before a
windowed assertion, the check asserts that the remaining window covers the
assertion's bound from `oracle::bounds`; if not, rc 2.

**Shared mechanics.**
- Hard kills use `kill_and_reopen(…, KillKind::Hard)`
  (`tooling/soak/src/rig/restart.rs:106`).
- The final export follows a hard drop of S and A, so mid-flight rows stay
  as a killed app leaves them.
- Each recipe runs on its own circle.

| Id | Shape | Producer (existing code) | Pri |
|---|---|---|---|
| F1 | ≥4 circles at later epochs. One has ≥6 commits (past `DEFAULT_MAX_PAST_EPOCHS` = 5). One had a removal (blank tree nodes) | `build_circle`, `World::change` (`Relays`/`Add`/`Remove`), `settle_post_join` | P0 |
| F2 | Offline backlog: A's commit plus three locations withheld from S (**windowed**) | `go_offline`, `World::change`, `World::publish_location`; S04 | P0 |
| F3 | A commit pending behind a swallowed `OK` | S18 `swallowed-ok-relay-update`; proxy `swallow_ok` | P0 |
| F4 | All six `FanoutTargetStatus` values: `Failed` with and without a rejection category; `NotAttempted`; `Attempting` (killed mid-send); `PossiblyExposed` with `INTERRUPTED` | `start_refusing_natively`, proxy `unanswering`, hard kill | P0 |
| F5 | Confirmed by one relay, second acknowledgement owed (kept confirmed row) | first `OK`, second relay `unanswering`, hard kill | P0 |
| F6 | Rolled-back marker plus a `Failed` own-commit row | every target refuses; `finish_rolled_back_in`, `retire_commit` | P0 |
| F7 | Own proposal with a durable record (leave, `OK` swallowed) | `World::leave` under `swallow_ok` | P0 |
| F8 | Location fanout pending its `OK` (**windowed**) | S18 `swallowed-ok-location-send` | P0 |
| F9 | Trial row of a recordless removal; and, if Haven can stage one, a trial row carrying post-confirmation Welcomes (else reviewed list) | `stage_unrecorded_for_test`, reopen, hard kill (`fanout_restart_e2e.rs:1876` recipe) | P0 |
| F10 | Cross-group duplicate pending refs | **Reviewed-unreachable at v0.10.4 unless the writer produces it.** `restore_pending` raises the ref counter past every restored ref (MDK v0.10.4 `cgka-engine/src/epoch_manager.rs:212-221`), so two swallowed-`OK` commits across `kill_and_reopen` do not share a ref. The recipe is still run; its outcome decides the list | P0 (attempt) |
| F11 | A queued change **and** a queued location `AppMessage` intent behind a pending commit | second `World::change` / location while F3's circle is pending | P0 |
| F12 | Own-commit intent marked reinvite-required | `fanout_change_e2e.rs:3488` recipe | P0 |
| F13 | Unacknowledged founding Welcome record, and an invite Welcome record | S18 `swallowed-ok-founding-welcome`; invite under `swallow_ok` | P0 |
| F14 | Invitation held unanswered at S (consumed-KeyPackage hold) | M2 invites S; `process_gift_wrapped_invitation` without accept | P0 |
| F15 | KeyPackage lifecycle: current; superseded awaiting its replacement's `OK`; consumed and owed a replacement; the marker naming the pending replacement | S12 `kp-rotation-slot`; `build_kp_maintenance_events` | P0 |
| F16 | Left circle awaiting forget (an invitation from its last roster is held) | `left_circle_e2e.rs:563` recipe | P0 |
| F17 | Disbanded circle's tombstone | `disband_e2e.rs:167` recipe | P0 |
| F18 | Convergence-buffered future-epoch commit (N+2 present, N+1 withheld) | S19 `commit-gap`; proxy `drop_class` | P0 |
| F19 | `PeelDeferred` rows | `deferred_peel_drain_e2e.rs` recipe | P0 |
| F20 | Processed transport ids (hundreds) | S16 `processed-ids-growth` | P0 |
| F21 | NIP-77 inventory, route cursor and replay cursor | catch-up on a NIP-77 plane | P0 |
| F25 | Unrecoverable (quarantined) circle | S13 `hydration-quarantine` | P0 |
| F27 | A `pending_application_events` row: a location ingested, killed before it was drained | slow drain (existing slow-write seam) + `KillKind::Hard` | P0 |
| F28 | A location from epoch N, kept on the relay and delivered after S applied N+1 (past-epoch decrypt; **windowed**) | withhold the location, apply the commit, release after | P0 |
| F29 | A **received** pending proposal in S's OpenMLS proposal store (a peer's proposal, no commit yet) | a member's leave proposal reaches S; commit withheld | P0 |
| F30 | A stranded rewind-guard snapshot (killed inside a rewind window) | fork-recovery arm + slow-write seam + `KillKind::Hard`; reviewed list with reason if unproducible | P0 (attempt) |
| F31 | `cgka_group_evolutions` in every phase Haven leaves, with `pending_ref` `None` and `Some`, including **two circles whose `Confirmed` evolutions carry the same `pending_ref`** (on v0.10.4 refs restart each session and a confirmed evolution keeps its ref, so this is the ordinary state of a store with two circles that have each self-updated) | by-product of F3–F9, plus one self-update in each of two circles in separate sessions (asserted as a shape) | P0 |
| SH | Every `MessageState` and `EpochState` variant Haven reaches | asserted from the probe; unreachable variants on the reviewed list | P0 |
| F22 | Refused-refetch ledger | S20 `refused-page` | P1 |
| F23 | Non-zero `relay_floors` and backfill floors | S25 `dead-and-silent-relays` | P1 |
| F24 | Routing with a rotated id | S24 `collided-circles-leave-apart` | P1 |
| F26 | `kept_input` and a profile outbox row with debt | `hold_pager_commits_for_test`; `profile_offline_save_e2e.rs` recipe | P1 |

### Time: anchors, and libfaketime only behind a self-probe

**Why time must be faked.** MDK, OpenMLS and SQLite read the wall clock, and so
does Haven at open (37 direct reads in `nostr/mls/manager.rs` and
`circle/manager.rs`). The injectable clocks Haven already has cover only parts:
- `FanoutClock` (`relay/fanout.rs:918`);
- `RelayManager::at_for_test` (`relay/manager.rs:648-655`);
- `kp_lifetime` functions taking `now_secs`.

A committed fixture checked at real time is weeks old. "Fresh" therefore needs a
faked clock.

**The probe.** It runs at the start of **every** `fixture check`, before
anything else. Any failure exits rc 2, "rig broken: clock family X not faked",
never a silent pass. It checks two things:
1. **Static.** `nm -D --undefined-only` on the binary lists `clock_gettime`,
   `gettimeofday` and `time` as dynamic imports. They are therefore
   interposable, and no wall-clock read bypasses libc.
2. **Runtime.** Every clock family reads inside `[target, target + 600 s]`:
   - `std::time::SystemTime::now()` (also behind chrono, nostr and OpenMLS);
   - `chrono::Utc::now()`;
   - `nostr::Timestamp::now()`;
   - SQLite `strftime('%s','now')`, through a test-utils seam on an in-memory
     SQLCipher connection.

**Run environment.** `LD_PRELOAD=libfaketime.so.1`,
`FAKETIME_FMT=%s`, `FAKETIME="@<target>"`, `FAKETIME_DONT_FAKE_MONOTONIC=1`.
Tokio timers stay on the real monotonic clock.

**If the probe passes on the CI image,** the committed fixtures are checked at:

| Instant | Clock | Purpose |
|---|---|---|
| `fresh` | `written_at` + 30 s | non-windowed states |
| anchored | each windowed state's anchor + 5 s | F2, F8, F28 |
| `aged` | + 4 days | past every 24 h and 72 h bound |
| `expired` | + 90 days | past KeyPackage `not_after` |

**Fallback, if the probe fails** on the runner image or a developer machine:
1. The committed fixtures get only the **time-invariant early-gate assertions**
   below.
2. The `fresh` and anchored promises come from a **chain** run at real time:
   the durable `v0.1.13` binary runs `fixture write`, then HEAD runs
   `fixture check --at now` immediately, with the windowed states checked in
   their own invocation right after they are written.
3. The `aged` and `expired` promises rest only on the existing injectable-clock
   tests. This is a recorded residual.

### The early gate (relay-free, in `haven-core`): `haven-core/tests/upgrade_fixture_open.rs`

This gate does not wait for the soak rig to be ported in Stage 1. It is
available at Stage 1's first compile checkpoint.

For each directory under `fixtures/upgrade/`:
1. Import the SQL (S production-keyed under the mock keyring; A test-keyed).
2. Open both accounts, with no relay and no maintenance tick.
3. Assert only what holds at any elapsed time after writing:
   - the open succeeds;
   - `max(cgka_schema_migrations)` equals the test's `EXPECTED_SCHEMA`
     constant (89 now; Stage 1 changes it to 201);
   - every group hydrates, with quarantined ids (`quarantined_group_ids`,
     `manager.rs:12692`) equal to the manifest's set (F25 only);
   - per-circle epochs equal the manifest;
   - `circle_recovery` equals the manifest for every state marked
     time-invariant;
   - **silent-loss checks, immediately after open and before any maintenance
     tick:** `key_package_bundle_count_for_test` (`manager.rs:12544`) equals the
     manifest, and no circle holds a halted cause it did not hold before;
   - every fanout and group-evolution row decodes;
   - the commit, proposal and trial shape multiset is unchanged by the open;
   - no `haven_test_%` object exists;
   - the captured log contains no fixture needle (Rule 15), with at least one
     `haven_core` line as the positive anchor.

**Reset classification** (one relay-free test, in the same file).
- Setup: plant the pre-v2 names a v0.9.4-era build wrote (`session.sqlite`,
  `circles.db`, `haven_mdk.db` and their retired keyring ids, as
  `hard_reset_first_open.rs:60` does). Next to them, import the
  `haven-pre-bump` fixture under the v2 names (`session-v2.sqlite`,
  `circles-v2.db`).
- Open through `CircleManager::new`.
- Assert:
  - the pre-v2 files and keys are gone;
  - the reset notice is owed;
  - the v2 store **opens with its data**: circle count, epochs and the
    KeyPackage count match the manifest. It is never reset.
- A v2-only directory owes no notice.

It runs in `haven-core-suite` and coverage; the mock keyring is serialised by a
file-local mutex. Stage 1b also reuses it for its database-open gate tests.

### The driven check: `fixture check`

**Steps.**
1. Run the clock probe.
2. Import into a fresh temp dir.
3. Bind the planes on the manifest ports and seed them from the JSONL
   (`SimRelay::store`, `tooling/soak/src/relay/mod.rs:253`).
4. Open S (`Keying::Production`) and A (`Keying::Test`) with `open_in`.
5. Drive through product paths only:
   - `Publishing::resume`;
   - `run_catchup_all_circles`;
   - `seal_location` / `publish_location`;
   - `circle_recovery`;
   - invite and accept.
6. Grade with the existing oracles (O1 roster convergence, O2 one branch, O5
   classified undecryptables, O7 containment) and the per-state assertions
   below.
7. Run `haven-logscan` over the capture, with every fixture key, group id,
   routing id and relay address declared as a needle.

Where an assertion says "per SECURITY.md", the bound is encoded exactly as
`haven-core/SECURITY.md` states it, with the line cited. No behaviour is
invented to fit the fixture.

**Per-state assertions** (`fresh` unless noted):

| State | What is asserted |
|---|---|
| All | Both accounts open with no `NostrError`. Every circle's recovery cause matches the manifest. No `PendingCommitRecovered` merge is applied locally (Rule 13.5) |
| F1 | Epochs match. S and A each seal a location the other decrypts. `RosterDigest` equal. One branch |
| F2 (anchored) | The commit applies (epoch +1). All three backlog locations decrypt (Rule 12). The cursor never passes an event not taken in |
| F2 (`aged`) | The commit applies. Expired locations are not delivered and hold no cursor. Fence: caught up after the commit's `EOSE` |
| F3 | `SendHeld::AwaitingRelays` and the inbound hold until acknowledged. The resend is byte-identical to the manifest JSON (13.3). `OK true "duplicate:"` confirms on that acknowledgement only (13.2). Both holds release (13.4). `aged`: the 24 h outcome per SECURITY.md, never a rollback while a target is possibly exposed |
| F4 | Re-attempts only to targets owed one (`owes_an_attempt`). Accepted targets are not re-sent. No rollback while any target is `Attempting` or `PossiblyExposed` |
| F5 | Applied. The event is offered to the second relay until the second acknowledgement or the bound per SECURITY.md. `aged`: the row is retired |
| F6 | Never resurrects: the epoch is unchanged at open and after a catch-up; the circle seals |
| F7 | `resume_leave` completes; the others' roster drops S |
| F8 (anchored) | At most one offer per relay, never past `expiration`. `aged`: never sent, and the row ends |
| F9 | Resolved exactly as `fanout_restart_e2e.rs:1876` asserts |
| F10 | (if produced) Each pending commit stays bound to its own frozen event, resends byte-identically, and confirms independently |
| F11 | The queued change is made after F3 resolves, or retired with its typed outcome. The queued location follows the order Haven gives it today. Neither is dropped silently |
| F12 | `owed_reinvite_count_for_test` (`manager.rs:11006`) is unchanged. `Publishing::reinvite` delivers a joinable Welcome |
| F13 | Each record is redelivered byte-identically and ends on acknowledgement. `aged`: per SECURITY.md. The invitee joins at the current epoch |
| F14 | Still listed; accepting joins. The consumed package is **not** replaced while held. `aged` (≥72 h): the tick replaces it (Rule 5) |
| F15 | The superseded bundle is deleted on its replacement's acknowledgement, or at `not_after` (`expired`). The consumed package's replacement is minted on the first tick. The slot `d` is reused. **A invites S using the 30443 event S published before the upgrade (from the JSONL), and S joins; never `NeedsNewInvite`.** A repointed-slot variant is the same with S's slot repointed before the export |
| F16 | MLS state is present while the hold lasts; forgotten when it ends (`aged`) or after a decline |
| F17 | Seal returns the disbanded `SendHeld`. No REQ carrying the circle's `#h` (fence: the healthy circles' REQs in the same pass). The tombstone is kept |
| F18 | N+1 is fetched; N+1 and N+2 both apply (Rule 12) |
| F19 | Peeled once the epoch is present; no `PeelDeferred` row is left |
| F20 | A replayed processed event is `Ignored` and produces no duplicate location. The processed-id count does not fall |
| F21 | The inventory is unchanged at open; the next pass fetches no inventoried id; cursors are unchanged |
| F25 | Still unrecoverable with the same cause. Never forgotten, so a fix-forward can find it (Rule 5) |
| F27 | The account opens. The pending event is delivered to Haven exactly once |
| F28 (anchored) | S decrypts the epoch-N location with the restored past-epoch secret |
| F29 | The received proposal is still applied by the next commit. O1 holds |
| F30 | (if produced) The open restores no older MLS state over a newer one: epochs never decrease; O2 holds |
| F22–F24, F26 (P1) | The previous plan's assertions (refetch owed; `since` = floor; current routing id; `StoredInput` hold, then same-event profile resend) |

### Where it runs

- **Binary steps, serially, in one CI job** (S0.7 `upgrade`). Not a cargo
  integration test: fixed ports would collide under parallel `#[test]`s, and the
  `soak-tooling` job has no faketime.
- **Early gate:** a normal haven-core test in `haven-core-suite` and coverage.
- **HEAD writer self-check** (HEAD writes, HEAD checks `fresh`). It keeps the
  *next* fixture writable. It runs on pushes to `main` and on pull requests
  touching `haven-core/src/**`, `tooling/soak/**` or `fixtures/**`.

### Local verification

1. `apt-get install -y faketime sqlite3`.
2. Build HEAD and the `v0.1.13` worktree (S0.2a.4) at `--profile soak`.
3. `v0.1.13/haven-soak fixture write --out fixtures/upgrade/haven-v0.1.13`.
4. Probe, then `fixture check` at every instant the probe allows, plus the
   windowed invocation.
5. `cargo test --test upgrade_fixture_open`.

### Exit criteria

- Both fixtures are committed (`haven-pre-bump` from the last Stage 0 commit,
  after S0.5 and S0.10).
- Every allowed instant is rc 0, the early gate is green, and the probe verdict
  is recorded.
- Planted negatives (local), each red with the right rc:
  - delete a `cgka_outbound_fanout` row → F3 rc 1;
  - corrupt one record's JSON → typed open error, rc 1, never a panic;
  - remove a required shape → self-check rc 2;
  - unset `LD_PRELOAD` → probe rc 2.

**Cost.** 1 K cold (the `v0.1.13` worktree) + 1 K warm + 2 W + about 10 X +
1 t + 1 T.

### Risks

- **libfaketime coverage.** The probe decides it; the fallback is stated above.
- **Producibility of F10 and F30.** These go to the reviewed list, with
  citations, if unproducible.
- **Writer runtime.** 5–10 min (ESTIMATED).

---

## Step 9 — S0.2: mixed-version circles (P0)

**Goal.** Through real relays and separate processes, prove that:
- the field build (`v0.1.13`) and HEAD interoperate in one circle in both roles;
- an in-place upgrade with a commit pending completes;
- the old build, handed the upgraded store, reacts as its schema allows without
  damaging the store.

Two haven-core versions cannot link into one binary (`libsqlite3-sys` is a
`links` crate), so each runs as its own process.

### Shape

**Orchestrator.** `haven-soak compat --old <bin> --new <bin> --run <A|B|C|D|all>`,
built at HEAD.
- It owns the in-process `SimRelay`s behind `Proxy` planes, the run directory
  and the timeline.
- It speaks JSON lines to the peers.

**Peers.** `haven-soak peer --store <dir> --handle simdev#N --run <rundir> [--keying production]`.
- Each peer is one `SimDevice` opened with `open_in`.
- It calls `install_process_globals()` (`world.rs:135`).
- It writes its capture to `<rundir>/<handle>.log` and its needles to the
  lane's needle directory.
- A production-keyed peer reads its synthetic session secret from
  `<rundir>/keys/<handle>` into the mock keyring.

**Protocol v1** is frozen: the old binary speaks it for good, and `hello`
negotiates.
- A reply is written only once the action completes on a protocol event.
- Only handles cross stdout; pubkeys travel as files under `<rundir>/ids/`.
- Fixes are computed by the frozen function `fix_for(sender, seq)`.
  Coordinates never cross stdout.
- Replies are typed enums, never prose.

| Request | Product path | Completes when |
|---|---|---|
| `hello` | `schema_version_for_test` (on `open_tamper_connection`) | `{protocol, store_schema}` |
| `open` | `open_in` | returned; a refusal maps to `{refused: "storage_unsupported_schema_version"}` (`map_storage_err`, `manager.rs:176`) |
| `publish_key_package` | `build_kp_maintenance_events`, then a publish | a relay `OK` |
| `create` / `invite` | KeyPackage lookup; `Publishing::create_circle` / `add_members` | Welcome acknowledged / confirmed |
| `invite_many {synthetic: n}` | the same, with n in-process synthetic member KeyPackages | confirmed, or `{refused: "wrap_failed"}` mapped from today's generic error (no typed outcome exists for it) |
| `accept` | inbox fetch; `process_gift_wrapped_invitation` / `accept_invitation`; `settle_post_join` | joined, post-join self-update confirmed |
| `send_location` / `drain` | `seal_location` + `publish_location` / `run_catchup_all_circles` in `poll_until` | acknowledged or a typed `SendHeld` / every expected fix decrypted |
| `remove`, `update_relays`, `handover`, `repair`, `leave` | `Publishing::…` | confirmed, or a typed outcome |
| `report` | `group_epoch`, roster as handles, `circle_recovery`, the circle's required components | immediately |
| `exit` / `abort` | soft drop waiting for session release / `std::process::abort()` | the process exits |

### Four chained runs

Each run is a chain: one setup, then every step in order. The graders are O1,
O2, O5 and O7, plus a **wire check on the proxy ledger**: every kind-445 carries
`h`, or `h` plus `expiration`, and nothing else, and every kind-1059 carries
exactly one `p`.

| Run | Peers | Steps | P0 / P1 |
|---|---|---|---|
| **A** | old admin O1, new N1, N2 | N1/N2 publish KeyPackages → O1 creates and invites N1 → N1 accepts (self-update) → locations both ways → O1 changes relays (REQs follow, O7) → O1 invites N2 → O1 removes N2 (asserted through O5 and the epoch, not an undecryptable count, because a removed member may stop asking) → N1 makes the epoch-rotation repair | P0 up to the repair; then P1 tail: hand-over O1→N1, N1 removes, O1 leaves and forgets |
| **B** | new admin N1, old O1, O2 | A with roles swapped, then the **oversized Welcome**: N1 `invite_many` with n chosen by a size probe so the Welcome's NIP-44 plaintext exceeds 65,408 bytes (about 150 members, ESTIMATED) → refused through today's generic error path; no kind-1059 for it on any plane; the old peers' state is unchanged | P0, with the same P1 tail |
| **C** | O1, N1, then O2 upgraded in place | N1 rotates its KeyPackage twice → O1 invites with the rotated package → joins. O1's package → N1 invites → joins. **A package published before an upgrade:** O2 publishes, `exit`s; a new peer opens O2's store in place; O1 invites using that pre-upgrade 30443 event from the relay → the upgraded peer joins, never `NeedsNewInvite` | P0 |
| **D** | O1 (**production key form**), N1, N2 | O1 stages a relay change under `swallow_ok` and reports pending → `abort` (an un-checkpointed WAL) → a **new** peer opens the same store and identity → `resume` resends the byte-identical event (compared with the proxy ledger) → `duplicate:` → confirmed → locations flow. Then a soft `exit` (TRUNCATE checkpoint); the orchestrator records a **logical-dump hash** (sorted dump through the export seam; never raw file hashes, which `-wal`/`-shm` sidecars break) → the **old** peer `open`s. If `store_schema(new) > store_schema(old)`: `refused` and the dump hash unchanged. If equal (Stage 0): it opens, and `report` shows the circle at its epoch. This proves `v0.1.13` reads a `circles-v2.db` HEAD wrote, extra column included | P0 |

**Risk → run mapping.**

| Interop risk | Run |
|---|---|
| OpenMLS fork (0.8 line) peers vs upstream (0.9 line) peers: every message type in both directions | A, B |
| Welcome addressing by `e` tag | A, B, C |
| KeyPackage lifetime and rotation across versions | C |
| kind-445 outer shape | A, B (ledger wire check) |
| Component advertisement (no 0x800d; required set equal on both sides) | A, B (`report`) |
| Removal and epoch rotation across versions | A, B |
| A KeyPackage published before the upgrade still joins | C |
| Oversized Welcome never reaches an old peer | B |
| In-place upgrade with a pending commit, production key form, live WAL | D |
| Old build on an upgraded store refuses without modifying it | D |

### The old peer, durably

`tooling/soak/compat/old_peer.toml` records:
- `rev = "a45ab2d8…"`;
- the harness commits and their patch SHA-256;
- rustc `1.97.1`;
- the binary's SHA-256;
- the release tag `compat-peer-v0.1.13`.

A dispatch-only job, `compat-peer` in `soak-core.yml` (S-O3):
1. Builds the worktree as in S0.2a.4, with `fetch-depth: 0`.
2. Uploads the binary, the harness patch, a `cargo vendor` tarball of the
   `v0.1.13` soak graph (git dependencies included) and `SHA256SUMS` to that
   prerelease.

The `upgrade` job downloads the binary with `gh release download` and verifies
its SHA-256. If the asset is ever missing, it rebuilds offline from the vendored
tarball. A cache alone would be evicted after seven idle days.

At Stage 1 the same `v0.1.13` peer stays the old side. The lane then remains a
permanent N−1 lane; each release moves `old_peer.toml` to the previous
release.

### Determinism and Rule 15

- There are no sleeps, and requests are strictly sequential, with deadlines
  from `oracle::bounds`. `HAVEN_TEST_WAIT_SCALE` scales transitions only.
- Peers log nothing of their own, and their captures are scanned.
- The orchestrator never echoes a peer line; it prints its own timeline in sim
  vocabulary.

### Verification

- Local: build HEAD and the `v0.1.13` worktree, then
  `haven-soak compat --old <v0.1.13 bin> --new target/soak/haven-soak --run all`.
- CI: the `upgrade` job.

**Exit.**

- Runs A–D pass, with old = `v0.1.13` from the release asset and new = HEAD.
- Planted negatives:
  - one byte of the resent event altered in the comparison → D rc 1;
  - the old peer made to ignore `swallow_ok` → D rc 3.
- Logscan is clean over every capture.

**Cost.** 1 K + four runs × about 3 iterations, about 5–8 min per run
(ESTIMATED).

**Risks.**

- **Protocol v1 is a commitment.** A later need is a backward-compatible
  extension, and a scenario needing more than an old peer offers reports rc 4,
  never a silent skip.
- **The `invite_many` size probe** makes the oversized case cost one large
  commit (ESTIMATED tens of seconds).

---

## Step 10 — S0.7: CI wiring, release gate, lockfile, coverage floor; Stage 0 exit

### Where each proof runs

| Proof | Lane | Gates |
|---|---|---|
| Guards and self-tests (S0.3, `--locked`, lockfile guard) | `repo-guards.yml` steps (every step runs even after a failure) | release (`Repo Guards / Static checks`) |
| `--nostr-features` | `rust-check.yml` beside `--adapter-features` | release |
| `dependency_surface.rs`, S0.4, S0.9 W-scenarios, S0.5 scope test, S0.6, S0.10, the early gate, the round-trip test | `haven-core-suite` and coverage | release |
| `pool_constants.rs` | `soak-tooling` `cargo test` | release |
| S0.1 committed-fixture checks, chains and writer self-check; S0.2 runs A–D | **new job `upgrade` in `soak-core.yml`**, `if: inputs.profile == 'pr'` | release (below) |

**The `upgrade` job.** It is added under `check_soak_lane_reachable.sh`'s rules:
it drives through `tooling/e2e/ci/run-soak-core.sh`, which gains an `upgrade`
mode, under an inner deadline; it scans in a step of its own that the drive's
outcome cannot switch off; and the guard's pins and self-test are extended.

Steps, serially:
1. Restore the rust cache as the `core` job does.
2. `apt-get install -y faketime sqlite3`.
3. `cargo build --profile soak`.
4. Download and verify the old peer.
5. Clock probe.
6. Committed-fixture checks: every directory, every instant the probe allows,
   plus the windowed invocation.
7. The `v0.1.13` chain (old writes, HEAD checks).
8. The HEAD writer self-check, if the paths changed or the event is a push.
9. Compat A–D.
10. The open-bucket comparison.
11. Logscan.

Duration: 15–25 min with a warm build (ESTIMATED), in parallel with the `pr`
job.

### Release gate (the in-repo half of merge and release gating)

Today `scripts/ci/check_ci_verdict.sh:44` gates only `rust-check.yml`,
`cross-check.yml`, `coverage.yml` and `repo-guards.yml`. The extension:

1. **`GATE_WORKFLOWS`** gains `soak-core.yml`, `build-check.yml`,
   `e2e-android.yml`, `e2e-ios.yml` and `audit.yml`.
2. **Several callers per workflow.** `derived_jobs` (`:109-125`) emits
   `<caller> / <job name>` for **every** `ci.yml` caller of a gate workflow,
   instead of failing on more than one. `e2e-android.yml` is called as
   "E2E Core Flow (Android)" and "E2E Core Flow (Android, live-sync)", and
   `e2e-ios.yml` likewise. A workflow with no caller is still rc 2.
3. **Matrix names.** A job name of the form `…${{ matrix.<k> }}…` is expanded
   from that job's literal `strategy.matrix` values, either a `<k>: [..]` list
   or `include: - <k>: v` entries. `build-check.yml:41`'s
   `Android (${{ matrix.arch }})` becomes `(arm64)`, `(arm)` and `(x64)`. Any
   other computed name stays rc 2.
4. **`REQUIRED_JOBS`** gains:
   - `Soak Core (pr profile) / e2e_soak_core_pr`
   - `Soak Core (pr profile) / upgrade`
   - `Debug Builds / Android (arm64)`, `(arm)`, `(x64)`, and `Debug Builds / iOS`
   - `E2E Core Flow (Android) / e2e_android`
   - `E2E Core Flow (Android, live-sync) / e2e_android`
   - `E2E Core Flow (iOS) / e2e_ios`
   - `E2E Core Flow (iOS, live-sync) / e2e_ios`
   - `Dependency Audit / cargo audit (RustSec advisories)`
5. **`EXEMPT_JOBS`** gains `soak-core.yml:e2e_soak_core_nightly`,
   `soak-core.yml:e2e_soak_core_weekly` and `soak-core.yml:compat-peer`, which
   are always skipped in the `pr` call. It also gains
   `build-check.yml:release-link`, which runs only on its path filter. The
   script's "nothing under a gate workflow failed" rule still holds them: a
   `release-link` that ran and failed blocks the release.
6. **Timing.** `DEADLINE_SECS` rises from 5,400 to 15,600, and the gate job's
   `timeout-minutes` (`release-build.yml`) rises from 100 to 270. This covers
   the slowest newly gated job (iOS live-sync core flow, a 245-min job
   timeout).
7. **Self-test.** The green fixture's `E2E Core Flow (iOS) / e2e_ios … failure`
   line, which today proves E2E is ignored, becomes a non-gated lane
   (`E2E Real GPS (Android)`). New fixtures:
   - a failed core E2E lane fails;
   - a multi-caller workflow derives one entry per caller;
   - a matrix name expands;
   - a skipped `release-link` passes and a failed one fails;
   - the soak `nightly`/`weekly` copies are exempt.

   `SELF_TEST_FIXTURES` is re-pinned (18 → 23).
8. **Documentation, same change:**
   - the header of `check_ci_verdict.sh`, which says today that E2E lanes "stay
     out of the gate";
   - `release-build.yml:61-77`;
   - CLAUDE.md's CI-pipeline sentence on the release gate.

**Owner action (O10).** Add required status checks to the `main` ruleset,
naming the same job set. This cannot be done from the repository.

### Flutter lockfile

- Commit the `haven/pubspec.lock` that Flutter 3.44.8 resolves. Today a plain
  `flutter pub get` on the pinned SDK bumps `matcher`, `meta` and `test_api`.
- Every `flutter pub get` becomes `flutter pub get --enforce-lockfile`:
  - 23 workflow sites in 20 workflows, `build-check.yml:115` through `release-build.yml:336`;
  - `scripts/ci/check_l10n_parity.sh:53`.
- Every `subosito/flutter-action` step sets `flutter-version` from
  `HAVEN_COVERAGE_FLUTTER_VERSION` in `scripts/ci/coverage_toolchain.env`, as
  `coverage.yml:283-288` does (S-O2).
- Update CLAUDE.md's coverage-toolchain paragraph in the same change.
- A `repo-guards.yml` step fails on any `pub get` without `--enforce-lockfile`
  and any Flutter setup without the pinned version, with a self-test.
- Local check: `flutter pub get --enforce-lockfile`, then F and A.

### Non-publishing release-mode link build: `release-link` (P0)

A job in `build-check.yml`:
- **Path filter.** It runs only when a diff against the base touches
  `**/Cargo.lock`, `**/Cargo.toml`, `.cargo/config.toml`,
  `haven/rust_builder/cargokit.yaml` or the iOS/macOS podspecs.
- **Builds.** `scripts/build_release.sh apk` and `scripts/build_release.sh ios`
  (no codesign).
- **Key.** A random UUID minted in the job stands in as the Stadia key. It is
  never stored. The wrapper refuses only empty or placeholder keys, and Android
  falls back to debug signing without `key.properties`.
- **Checks.** It reruns the artifact SQLCipher-logger scans (`build-check.yml`)
  on the release artifacts.
- **Publishing.** No upload and no signing.
- **Cost and proof.** 30–40 min per platform (ESTIMATED). It is proved once
  by a push that touches `Cargo.lock`. CI-only.

### `haven/rust_builder` coverage floor (P0)

- Stage 1 rewrites much of `api.rs`, which no coverage run measures today.
- Add `cargo llvm-cov` over `haven/rust_builder`'s own tests to `coverage.yml`
  (`frb_generated.rs` excluded).
- Pin floors with `scripts/ci/check_coverage_floors.sh --repin rust <lcov>`,
  never by hand.
- Local cost: about one T-equivalent (ESTIMATED).

### P1 items in this step

- **Pin cargo-audit.** `cargo install cargo-audit --locked --version <x>`, with
  the version read from the last run's log.
- **cargo-deny** `sources advisories` with `scripts/ci/deny.toml`:
  `unknown-git = "deny"`, and `allow-git` set to exactly the repositories in
  `mdk_pins.env`.
- **The git-source advisory experiment runs now** (about 0.25 day, ESTIMATED).
  - Make a scratch lockfile in which a git-sourced package carries the
    name and version of a crate with a RustSec advisory, and check it with both
    tools.
  - If neither reports it, a mapping step joins `check_lockfile_universe.sh`,
    and a tracker row records the residual.

### Lane pass-rate baseline (P0)

- Read the last 20 `main` push runs of each newly gated E2E lane and of
  `soak-nightly` through `gh api`, and record the pass/fail counts with their
  run ids in the Stage 0 exit pull request.
- Stage 1's exit (`docs/mdk-v0.16/stage1a_nostr.md` §F.3) compares each lane's
  two Stage 1 runs against these counts. Cost: a few `gh api` calls; no build.

### Dropped audit items: where each went

- **White Noise interop** (Haven ↔ MDK's reference client): P1 after Stage 1,
  as a lane driven by MDK's `wn` CLI. At minimum, Haven invites a `wn` account
  (KeyPackage selection with a `client` tag, Welcome `e`-tag addressing).
- **`cross-check --locked`:** this step's guard (S0.3).
- **The iOS-simulator target in cross-check:** P1 after Stage 1.
- **FFI error-string needle test:** Stage 1, with the new error paths.
- **Real-keyring SQLCipher tests:** P2, can follow. The production key form is
  now crossed by the mock-keyring fixture and compat run D.

### Verification of the wiring

- Local:
  - `actionlint` on the changed workflows;
  - every new script step run with bash;
  - `check_ci_verdict.sh` with no arguments (pinned list equals the workflows)
    and with `--self-test`.
- CI-only: job plumbing, path filters, `release-link`, and the gate against a
  real `main` push run.

### Stage 0 exit (the bump may start)

1. Every P0 unit's exit criteria are met, on a pushed, green branch.
2. Both fixtures are committed. Every probe-allowed instant is rc 0, or the
   fallback chain is green. The early gate is green.
3. Compat A–D are green against the released `v0.1.13` peer.
4. Transcripts and the cost baseline are committed.
5. `release-link` has been green once.
6. The extended release gate passes `--self-test` and a real `main` run.
7. The rust_builder floor is pinned, and the lane pass-rate baseline is
   recorded.
8. Security-reviewer and test-writer passes are complete over S0.1, S0.4, S0.5,
   S0.9 and S0.10.
9. The §1 capture checklist is fully ticked.

---

## 3. Local vs GitHub CI

| Item | Local | GitHub CI only |
|---|---|---|
| S0.1 writer/check/probe/early gate; S0.2 runs A–D; `v0.1.13` worktree build | yes (Docker not needed; in-process relays) | runner-image probe verdict; release-asset upload |
| S0.3 guards, inventories, `pool_constants` | yes | — |
| S0.4, S0.5 (clippy on both Rust roots), S0.6, S0.9, S0.10 | yes | — |
| Flutter lockfile, `flutter analyze` / `flutter test`, FRB regeneration | yes (Flutter 3.44.8 and codegen 2.11.1 installed) | — |
| `release-link`, `build-check`, cross builds, E2E lanes, gate API reads | no | yes |
| Required status checks | no | repository settings (owner) |

## 4. Open items and UNVERIFIED

- **libfaketime on `ubuntu-24.04`.** Its interposition and `FAKETIME_FMT=%s`
  are settled by the probe; the fallback is stated.
- **The lag test.** The receiver gate is a new test-utils seam; its shape is
  settled (S0.4d).
- **The oversized-Welcome product test.** What v0.10.4 leaves behind in the
  engine on the refused invite; only the error path, the wire and the epoch are
  asserted at Stage 0.
- **Producibility at v0.10.4** of F10 (expected unreachable), F30 and F9's
  Welcome-carrying trial row.
- **The handshake header-name set and the `nostr`/`nostr-sdk` feature sets.**
  Recorded at implementation.
- **`sqlite3` on the runner image.** It is installed explicitly either way.
- **Whether cargo-audit or cargo-deny match git-sourced packages.** Settled by
  the experiment.
- **`flutter-check.yml` and `l10n-check.yml`.** They gate merges only by
  convention. The extended gate does not add them; adding them is an owner
  choice.
- **Fixture size and writer runtime.** ESTIMATED.

---

## Appendix A — `v0.1.13` vs the working tree (the evidence for S0.2a.4)

`git diff --stat a45ab2d8 9a27d4a8`:

| Path | Files | Insertions | Deletions |
|---|---|---|---|
| `haven-core/src` | 29 | +3,713 | −648 |
| `haven/rust_builder/src` | 2 | +1,974 | −636 |
| `tooling/soak` | 7 | +108 | −24 |

The `haven-core/src` changes are concentrated in:
- `relay/manager.rs` (743 lines);
- `relay/maintenance/own_presence.rs` (new, 787 lines);
- `circle/storage_profile_sync.rs` (500 lines);
- `profile/fetch.rs` (530 lines);
- `relay/live_sync/session.rs` (394 lines).

Store-writing code paths, checked hunk by hunk:

| Path | Change since `v0.1.13` | Row-shape effect |
|---|---|---|
| `nostr/mls/storage.rs` (all store seams) | none | none |
| `nostr/mls/manager.rs` (second-handle writes to MDK tables) | 46 lines: `holds_unread_input` reads the engine's processed record and releases holds; two `.clone()` removals | none (read-side) |
| `relay/fanout.rs` (fanout driver) | `InFlight` counting; a drive stops after its first send once its mode no longer stands; invite lookup via `lookup_member_for_invite` | none; rows may stop at an earlier status, in the same shapes |
| `circle/storage.rs`, `storage_profile_sync.rs` | `profile_sync_state.covered_pool_json` (new column, added at open when absent) | **yes**: column absent in a `v0.1.13` store |
| `circle/storage_profile.rs` | `ensure_profile_sync_row` (INSERT OR IGNORE); miss ladder `[30,120,480,1800]` (was `…, 21600`); `Known` rows honour `next_retry_at` | **yes**: a row may be absent; `next_retry_at` values up to 6 h |
| `circle/storage_relay_prefs.rs`, `circle/manager.rs`, `relay/maintenance/*` | comments; read-side KeyPackage snapshot helpers | none |
| `relay/scripted_relay.rs` (test-utils) | `Frame::Closed` added | test-only; not used by the harness |
| `tooling/soak` | `unread_input_taken_in`; quiescence reads `passes_under_way` | none; the harness avoids both |

---

## Appendix B — MDK-enum decision sites outside `match` arms

### B.1 Wildcard and `matches!` sites converted in S0.5

**Rule 12 ingest disposition (four spellings, one classifier):**
- `nostr/mls/manager.rs:3961-3965`
- `relay/catchup.rs:1234-1236`, `:1300`
- `relay/live_sync/processor.rs:1281`

**Rule 13 status:**
- `relay/fanout.rs:1579-1586` (`owes_an_attempt`)

**Other `_ =>` arms over MDK enums.** All become exhaustive.
- `nostr/mls/manager.rs:347-354`, `:4113` (with `Err`), `:5244`, `:6951`,
  `:7671`, `:8270` (with `Err`), `:8832`, `:10486`, `:11973`, `:12958`
- the `SendIntent` arms `:2513`, `:5474`, `:5491`, `:8487`, `:14145`
- the `GroupEvent` arms `:4268`, `:9623`, `:9654`, `:9710`, `:9789`, `:14253`
- the `OpenMlsContentKind` arms `:3204`, `:13292`
- `relay/fanout.rs:5000`
- `circle/manager.rs:3219`, `:4239`, `:5224`, `:9808`, `:9904`, `:10208`,
  `:11154`, `:12492`, `:12507`, `:12988`, `:13086`, `:13191`
- `relay/live_sync/processor.rs:1471`
- `relay/manager.rs:2175`
- `haven/rust_builder/src/api.rs:16039`, `:16238`, `:16325`

### B.2 `if let` / `let … else` over MDK enums (16)

| Site | Variant | Decision | Action |
|---|---|---|---|
| `nostr/mls/manager.rs:1799` | `PublishWork::Proposal` | which publish work leaves the device (Rule 13.1) | exhaustive `match` |
| `:3339` | `GroupEvent::EpochChanged` | which groups owe an advance (Rule 12) | exhaustive `match` |
| `:3548` | `IngestOutcome::Buffered \| TransportDeferred` | which groups owe service (Rule 12) | classifier |
| `:5933` | `SendIntent::RemoveMembers` | a withdrawn removal is never re-made by itself | exhaustive `match` |
| `:6157` | `SendIntent::Invite` (`let … else`) | owed reinvites (Welcome obligations, Rule 13) | exhaustive `match` |
| `:7881` | `Some(SendIntent::RemoveMembers)` | who a confirmed removal removed | exhaustive `match` |
| `:9606` | `GroupEvent::GroupStateRevalidated` | revalidated removal note | exhaustive `match` |
| `:9715` | `GroupEvent::EpochChanged` | forget gone removal targets | exhaustive `match` |
| `:9737` | `GroupEvent::TransportObjectResourceRefused` | refused ids are refetched, never recorded seen (Rule 12) | exhaustive `match` |
| `:10762` | the same | stall evidence | exhaustive `match` |
| `:11572` | `SendIntent::UpdateAppComponents` | admin-policy read for display | marker |
| `:11934` | `GroupEvent::GroupJoined` | drop rows of a replaced copy; clear pager holds (Rules 5/12) | exhaustive `match` |
| `:14176` | `SendIntent::Invite` | a retired invite's Welcome routes | exhaustive `match` |
| `circle/manager.rs:4049` | `GroupEvent::EpochChanged` (`let … else`) | repair-gate bookkeeping, best-effort | marker |
| `circle/manager.rs:6456` | `PublishWork::FoundingGroupCreated` | founding Welcomes (Rule 13 / Welcome obligations) | exhaustive `match` |
| `circle/manager.rs:6469` | `PublishWork::Proposal` | the leave proposal that leaves the device (Rule 13.1) | exhaustive `match` |

### B.3 `==` / `!=` / `.contains(&…)` over MDK enums (17 product sites)

| Site | Comparison | Decision | Action |
|---|---|---|---|
| `relay/fanout.rs:1466`, `:2534`; `nostr/mls/manager.rs:15316` | all targets `== NotAttempted` | nothing sent under the record (Rule 13.3) | Rule-13 classifier |
| `relay/fanout.rs:2029` | `contains(&Attempting)` | a relay may hold the commit (Rule 13.3) | Rule-13 classifier |
| `nostr/mls/manager.rs:7774` | `contains(&NotAttempted)` | send ordering, fairness only | marker |
| `:13261`, `:13275` | `OpenMlsContentKind::{Application, Commit}` | sweep retiring messages beyond relay retention; commit edges (Rule 12) | exhaustive `match` |
| `:13479` | `!= MessageState::Retryable` | unopened stored event (Rule 12 refetch) | exhaustive `match` |
| `:13691` | `== MessageState::Sent` | `retire_commit` (T-ROLLBACK-RESURRECT, Rule 13.3) | exhaustive `match` |
| `:13804`, `:13813` | `!= Sent`; `== Commit` | own sent commits considered for recovery (Rule 13) | exhaustive `match` |
| `:14294`, `:14295` | `== Processed`; `!= Sent` | Welcome standing (Welcome obligations) | exhaustive `match` |
| `:14913`, `:14969` | `OpenMlsContentKind::Proposal` | proposal-before-commit gating (Rule 12) | exhaustive `match` |
| `:5729` | `GroupEvolutionPhase::Confirmed` | leaf-rotation repair rate limit | marker |
| `relay/manager.rs:2505` | `TransportEndpointFailureKind::PossiblyExposed` | wedge-mitigation drop (deleted at Stage 1) | marker |

---

## Appendix C — Review ledger

Each row maps a migration ruling (R…, `docs/MDK_V016_MIGRATION_PLAN.md`) or a
review finding to the change it caused in this part.

**Review sources:**

| Short name | Review |
|---|---|
| T/CI | tests and CI review |
| Eng | engineering review |
| Data | data-integrity review |
| Sec | security review |

| Source | Finding | Change in this revision |
|---|---|---|
| Rulings R1 | master order is the sequence | Units reordered to steps 1–10 |
| R1.a | branch reality | §0.2; "merge" defined; `main` merged at `9a27d4a8` |
| R1.b | owner items do not block | Step 1; defaults S-O1 to S-O3 added |
| R1.c | build cycles | §0.3 units; every step costed in cycles; engineer-days secondary and ESTIMATED |
| R2.a | represent `v0.1.13` | S0.2a.4 feasibility and procedure; two fixtures; old peer = `v0.1.13`; Appendix A write-path list; fallback recipes |
| R2.b | reset vs migrate classification | Early-gate reset-classification test |
| R3.a | baselines on today's code | New S0.9 (transcripts, counts, scenarios, format, comparison, bands) |
| R3.b | merge and release gating | Step 10 gate extension (multi-caller, matrix, exempt, deadline, self-test, documentation); O10 listed |
| R3.c | fixture | Anchors; windowed states last and separate; MDK dump recipe; rationale corrected; shapes list; F27–F31 added; silent-loss assertions; production-keyed S |
| R3.d | early gate | `upgrade_fixture_open.rs` |
| R3.e | libfaketime | Static and runtime probe on every run; rc 2; fallback chain; injectable clocks cited |
| R3.f | compat right-sizing | Four chained runs; risk mapping; pre-upgrade KeyPackage join; oversized Welcome; release asset |
| R3.g | guards | X4/X5/X6/X13 applied; I3/I5 and ten self-tests P1; Appendix B lists 16 `if let` and 17 comparison sites; Rule sites converted |
| R3.h | timing sites | `live_sync_privacy_config_e2e.rs:368-385` and `cursor_poisoning_e2e.rs:931` added, plus `inbox_cursor_poisoning_e2e.rs:466` (same race, found while checking) |
| R3.i | Flutter local | §0.4 and §3 tables updated; no CI-dispatch regeneration job |
| R3.j | pubspec lockfile | Step 10 lockfile item and guard; S-O2 |
| R3.k | pre-bump refactors | New S0.10 |
| R3.l | dropped items | Step 10 "where each went" |
| R4.a / Sec M1 | NIP-44 ceiling | S0.10 item 4: test kept on the NIP-59 path; product refusal test; `--drop-stale`; the RNG-backed encrypt noted. Premise corrected: today's refusal is the generic error path, not a typed outcome (S0.10, compat B) |
| Consistency: one product test, two names | Stage 0 and Stage 1a named the oversized-invite test differently | one name, `an_invite_whose_welcome_exceeds_the_nip44_ceiling_sends_nothing`; Stage 1a extends it at 16.4 |
| Consistency: `proptest_security.rs` | Stage 0 deleted the NIP-44 properties; Stage 1a re-pointed them for the same commit | re-pointed to `nip44::{encrypt, decrypt}` (Testing Requirement 5); one property goes, with its reason |
| Consistency: lag test specified twice | Stage 0 and Stage 1a gave the lag test different shapes | one shape (S0.4d): capacity 2, a receiver gate, a second receiver fenced on the `EOSE` |
| R4.e / Eng M1 | test key | Stage 1b owns the edit; S0.2a states it |
| R4.n / Sec A6 / Eng A8 | re-issue prose | S0.4c: same id via unsubscribe-then-subscribe; test asserts delivery only |
| T/CI HIGH-1 | no merge or release gating | as R3.b |
| T/CI HIGH-2 | no baseline | as R3.a. Not applied: moving the raw-pool gap tests (R1 order step 6; Eng M11). T-NEG-CLOSE is captured by transcript W10 |
| T/CI HIGH-3 | fresh depends on writer duration | anchors and windowed invocations |
| T/CI M1 | dumper | MDK recipe; round-trip compares pragmas and `sqlite_sequence` |
| T/CI M2 | ports, parallelism, faketime in `soak-tooling` | binary steps, serial, one job; `upgrade` is `pr`-only. Writer self-check runs on pushes and path-filtered pull requests instead of nightly: the nightly calls a different profile, and every push to `main` already runs `pr` |
| T/CI M3 | old peer not durable; not what users run | release asset; `v0.1.13` peer |
| T/CI M4 | gate too late | early gate |
| T/CI M5 | shape-level criterion | shapes list replaces table criterion |
| T/CI M6 | `if let` / `==` missed | S0.5 item 4, scope test, Appendix B |
| T/CI M7 | seam self-probes | G14 P0 for Rule 12/13 seams |
| T/CI M8 | two timing sites | as R3.h |
| T/CI M9 | Stage 1 exit checklist; flake baseline | checklist belongs to Stage 1 (R4.m); pass-rate baseline captured here as P0, because Stage 1's exit compares against it |
| T/CI M10 | dropped audit items | as R3.l |
| T/CI M13 | exact counts on fault-timed arms | median-vs-band rule in S0.9 |
| T/CI advisories | `syn`; run the guard script; source-asserting resolver; `FAKETIME_FMT` and per-run probe; removal via O5 and epoch; worktree fetch | all applied. Not applied: FRB dispatch job (superseded by R3.i, local regeneration) |
| T/CI right-sizing | P1 self-tests, profile sleeps, cargo-deny, FFI needle, keyring | marked P1/P2/Stage 1 as listed; rust_builder floor kept P0 |
| Eng H1 | intent token ban collides with exhaustive arms | S0.5 interface note: Stage 1 bans construction; no `.swap(` |
| Eng H2 | exception guard | not Stage 0 (Stage 1/2) |
| Eng M3 / X4 | reconnect constants | `pool_constants.rs` kept; Stage 1 re-points it |
| Eng X5 | universe per-root subsets | G3 |
| Eng X6 | supply-chain mechanism vs values | G4/G5 |
| Eng X9 / X10 | user-agent and NIP-42 duplicates | S0.4a/S0.4b are the single tests; Stage 1 respells the control only |
| Eng X13 | recorder tokens | G10 token only; Stage 1 adds two; no `.swap(` |
| Eng M6 | pre-upgrade KeyPackage join | F15 assertion plus repointed-slot variant; compat C |
| Eng M7 | bilingual refactors | S0.10 |
| Eng M10 | targeted-fetch end shapes | S0.4d |
| Eng M11 | over/under-scope | `circles-v2.db` criterion dropped, Haven rows P1; compat repair/hand-over/leave as P1 tails; raw-pool gap tests dropped; I3/I5 P1 |
| Eng M12 | worktrees and shared target | `v0.1.13` worktree with shared `CARGO_TARGET_DIR` |
| Eng A10 | fixed ports needed? | checked: `RelayMappedFanout` maps only the fanout transport; ports kept, serial |
| Data §2 (0167 view text) | byte-exact `sqlite_master` | `.dump` preserves it; round-trip asserts it |
| Data MEDIUM-2 | silent first-open loss | early gate and check: KeyPackage count and quarantined set right after open |
| Data MEDIUM-3 | F10 unproducible | reviewed-unreachable with citation unless produced |
| Data MEDIUM-4 | production key form | S production-keyed in both fixtures; compat D |
| Data MEDIUM-6 | missing states | F27–F31 and SH |
| Data advisory | file hashes flake on sidecars | compat D uses a logical-dump hash after TRUNCATE |
| Data advisory | 0169 volume perf fixture | not applied here: Stage 1's database-open gate decision (synthetic rows over a fixture copy) |
| Data §6 | Haven-only ledgers | kept as P1 recipes F22–F24, F26 |
| Sec A7 | pin KeyPackage extension lists | W12 keeps protocol tag values verbatim |
| Sec A1 / A3 | check-11 tokens (manual AUTH, `LocalRelay`) | not applied here: check 11's rewrite is Stage 1a's; S0.4a proves the behaviour now |
