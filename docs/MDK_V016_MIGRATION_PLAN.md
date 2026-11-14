# MDK v0.10.4 → v0.16.0 migration plan

Canonical plan and decision ledger for moving Haven from MDK v0.10.4
(`fcc85edd`) to MDK v0.16.0 (`a2e0558a`, tagged 2026-11-12). This file is the
master: decisions, stages, the single order of execution, owner items and the
review record. The detail lives in four parts:

| Part | Scope |
|---|---|
| [`mdk-v0.16/stage0.md`](mdk-v0.16/stage0.md) | The safety net, built on today's code before any dependency moves |
| [`mdk-v0.16/stage1a_nostr.md`](mdk-v0.16/stage1a_nostr.md) | Dependency sources, and the rust-nostr 0.44 → fork migration of the relay layer |
| [`mdk-v0.16/stage1b_mdk.md`](mdk-v0.16/stage1b_mdk.md) | MDK API and behaviour changes on the session side, the database upgrade, tracker and docs |
| [`mdk-v0.16/stage2_runtime.md`](mdk-v0.16/stage2_runtime.md) | Onto `AccountDeviceRuntime`, with the concession list |

**Status:** plan confirmed; Stage 0 in progress. Nothing in this file describes
shipped behaviour until the stage that delivers it is marked done below.

| Stage | State |
|---|---|
| 0 — safety net | in progress: steps 2 (timing-dependent tests) and 3 (exhaustive decisions over MDK enums) done; steps 4–10 not started |
| 1 — dependency move | not started |
| 2 — onto the runtime | not started; needs owner rulings R0, C1, C2 first |

## 1. What the upgrade is

It is three migrations in one, 832 upstream commits apart:

1. **MDK v0.10.4 → v0.16.0.** `cgka-session` is renamed `marmot-session`, and
   `AccountDeviceSession` is private in it: the only production entry is
   `AccountDeviceRuntime::open`, with the session re-exported only under the
   `test-support` feature, which upstream marks dev-only
   (`marmot-session/src/lib.rs`, `src/runtime.rs`). The host driver that lived
   in the forbidden `marmot-account` crate now lives in `marmot-session`.
2. **rust-nostr 0.44 (crates.io) → `erskingardner/rust-nostr@e93cc06b`**, a
   fork of the 0.45 development line. MDK's public API carries `nostr` and
   `nostr-sdk` types, so every Cargo root must resolve them from MDK's exact
   revision. `nostr-relay-pool` and `nostr-relay-builder` no longer exist as
   crates; the pool is private inside `nostr-sdk`.
3. **OpenMLS `erskingardner/openmls@59e7d3b` → `openmls/openmls@6100df3f`**
   (upstream main). MDK's changelog names two fixes this carries: a Welcome,
   GroupInfo, Proposal or Commit with deeply nested extensions could abort the
   process (GHSA-gc79-23g3-8g52), and a rejected private message could advance
   its sender's ratchet (GHSA-p276-g3f3-wwgh).

The account database migrates in place, schema 89 → 201, 87 migrations, each
its own transaction with its ledger row inside it. **There is no downgrade:**
a v0.10.4 build refuses the migrated file. Restoring a pre-upgrade copy after
any MLS activity on the new build would rewind epochs, which risks key reuse.
A defect that reaches users is therefore repaired only by a fix-forward
release, which is why the proofs in Stage 0 come before the bump.

### What is in the field

| Haven release | Date | MDK | Path under the new build |
|---|---|---|---|
| v0.1.13 (`a45ab2d8`) | 2026-11-11 | v0.10.4 | in-place migration 89 → 201 |
| v0.1.11, v0.1.12 | 2026-08 | v0.9.4 | Haven's existing one-time reset, untouched by this bump |
| ≤ v0.1.10 | ≤ 2026-07 | `mdk-core` | the same existing reset |

`main` is 77 commits past v0.1.13 on the same MDK. The upgrade fixtures and
the compat "old peer" therefore represent **v0.1.13**, the build users hold,
as well as the pre-bump tree.

### What the release does and does not repay

Of the 65 rows in [`MDK_UPSTREAM_TRACKER.md`](MDK_UPSTREAM_TRACKER.md), read
against v0.16.0 source:

| Verdict | Rows |
|---|---|
| Removable once a pinned test proves it | `T-WINDOWS-CI`, `T-NEG-CLOSE`, `T-POOL-TERMINATE-PERMIT`, `T-FAULTED-INGEST-SEEN` |
| Replaceable by a new MDK API | `T-WELCOME-KP-REF`; parts of `T-REJOIN-LEAVE`, `T-LEAVE-FANOUT`, `T-QUEUED-INTENT-RESTORE` |
| Kept deliberately (owner decision) | `T-POOL-VERIFY-CACHE` as a standing guard; `T-KP-CLIENT-RANK`, `T-KP-RETENTION` as deviations |
| Must change to keep working | about a dozen, among them `T-FANOUT`, `T-KP-DRIVER`, `T-ADAPTER-ATTEMPTS`, `T-RESERVATION-READ`, `T-WELCOME-OUTBOX` |
| Ports to re-sync with upstream's current logic | `T-SCHEDULER`, `T-MAINT-DRIVER`, `T-EPOCH-STALL` |
| Gap unchanged; citations refreshed | the remainder, about forty |

The value of the upgrade is the security fixes and staying on a supported
line. It deletes little Haven code by itself; how much Haven sheds is decided
in Stage 2. The release also adds gaps with no row yet: each part lists the
rows it creates.

## 2. Owner decisions

Recorded 2026-11-14.

| # | Decision |
|---|---|
| D1 | **Staged.** Stage 0 on today's code; Stage 1 the dependency move with Haven's own fanout driver kept behind a CI-guarded exception recorded as debt; Stage 2 onto the runtime piece by piece, the exception only allowed to shrink. |
| D2 | **Concede to finish.** Where a Haven policy cannot be expressed through the runtime's public surface and host seams, Haven accepts the runtime's behaviour. Applied narrowly: everything that can be kept honestly inside a host seam is kept; nothing is kept by using an upstream API in a way upstream does not promise; every concession is listed with its cost and its pinning test, and the owner may veto individual items before Stage 2 starts. |
| D3 | **Component `0x800d` (account-devices) is not advertised** in this upgrade. Pinned by a test; a tracker row records the interop limit. |
| D4 | **Haven keeps its own `Event::verify()`** on every relay event, as a standing guard, although the fork closes the forged-id cache hole. Security Rule 16 stands; only its API names change. |

## 3. Owner items, and the default applied until the owner says otherwise

Defaults follow Security Rule 10: the more private or more conservative
choice.

| # | Item | Default |
|---|---|---|
| O1 | After an update, a background wake never starts the 87 migrations; background sharing pauses until Haven is opened once | Yes |
| O2 | A store the new build refuses to migrate is a lockout ended by a fix-forward release, never an automatic reset. A long lockout becomes per-circle loss once relays drop the commits | Yes |
| O3 | No pre-upgrade copy of the database is kept: the un-migrated live file is itself the clean retry source, and a copy would retain past-epoch secrets | Yes |
| O4 | Weekly KeyPackage refresh (a spec SHOULD): a shorter `init_key` window against a public "device alive" signal several times more often | Keep rotating at 0.75 of the 30-day lifetime in Stage 1; revisit in Stage 2 |
| O5 | The engine's replay-rotation self-update may ride a full drive | Accept; it goes through Haven's fanout driver. No full drive exists in the background, so this arises in the foreground only |
| O6 | The storage an outsider can force rises from 64 MiB to 256 MiB per account (MDK's deferred-peel caps; anyone who sees a circle's public `#h` tag). No supported API sets the caps | Inherited with v0.16.0; tracker row `T-PEEL-CAP-4X` and an upstream ask |
| O7 | The `Stalled` verdict rests on fruitless-walk counting MDK deleted | Re-synced where Stage 1 needs it, otherwise in Stage 2 |
| O8 | MDK's `StepDownAndLeave` blocks the last admin | Decided in Stage 2 |
| O9 | A user-initiated "reset circles on this device" as the escape from a long lockout | Not built unless asked |
| O10 | Required status checks on the `main` ruleset (there are none today) | Owner action; the in-repo release gate is extended regardless |
| O11 | Upstream asks | Drafted in the tracker for the owner to file |
| O12 | Suppress the fork's new `user-agent` header with Haven's own header-less WebSocket transport | Yes; keeps today's wire |
| O13 | Refuse a Welcome above today's NIP-44 edge, 65,408 plaintext bytes on each NIP-59 layer, while v0.1.13 may be in the field (the fork removed the ceiling, and a v0.1.13 device cannot open the larger payload). Enforced by Haven's own Welcome signer, so the edge is identical to today's. The refusal reaches the user as a generic error today and that is unchanged; typed copy for it is an optional follow-up | Yes |
| O14 | The release gate also reads the soak, build-check, core E2E and audit jobs, so a release tag waits for them (the iOS lanes are the slowest) | Yes |

Three rulings are needed before Stage 2 starts, and not before
([`stage2_runtime.md`](mdk-v0.16/stage2_runtime.md)):

| # | Ruling | Recommendation |
|---|---|---|
| R0 | May Haven's transport adapter decline to send, provided it reports the wire truthfully? A refusal counts only when Haven heard the relay's `OK false` for that event on a gap-free stream | Yes |
| C1 | On the runtime, a location whose acknowledgement is lost on every relay never ends and freezes its circle; a relay can cause it | Do not concede |
| C2 | On the runtime, a withdrawn removal is silently made again, including for a member another admin has since invited back | Do not concede |

## 4. Order of execution

One sequence across all parts. Every push is a green state, except the single
compile window marked below. The work is done on the migration branch; stage
boundaries are the natural pull-request points.

**Stage 0 — on today's code.** Each step is green on MDK v0.10.4.

1. Owner items presented; work proceeds on the defaults in §3.
2. Timing-dependent tests fixed: each fixed sleep becomes a wait on an event.
3. Exhaustive matches over MDK enums on Security-Rule decisions, and the lint
   that keeps them so.
4. Refactors that already work on 0.44: one `nostr::` import convention, the
   shared helper for tests that read dependency source.
5. Guards that fail closed: lockfile universe per root, the MDK crate
   allowlist, the dependency-surface test, self-tests for the Security-Rule
   guards.
6. Behavioural proofs written to pass before and after: no NIP-42 answer, the
   handshake header names, subscription re-issue, notification lag; the
   wire-equivalence transcripts and the count-based cost ledger.
7. Soak-rig extensions and the lossless dumper.
8. The previous-release fixtures (v0.1.13 and pre-bump) and their check, with
   a relay-free early gate.
9. The mixed-version compat harness, self-run with both peers the same build.
10. CI wiring: the upgrade job, the extended release gate, the enforced Dart
    lockfile.

**Stage 1 — the dependency move.**

11. Setup: old-peer revision fixed, per-agent worktrees over one target
    directory.
12. Pins: manifests, `mdk_pins.env`, every lockfile, the test database key.
    *The compile window opens.*
13. Compile-only sweep, library. Semantics are ported mechanically; behaviour
    stays as today.
14. Compile-only sweep, tests and the other Cargo roots. *The compile window
    closes.*
15. Red inventory: one full run of the suites, the soak, the fixture check and
    the compat harness against the old peer. Every failure is recorded against
    the unit it belongs to.
16. Semantic units, each a red → green commit pair: Rule 16 and the pool; the
    fanout refusal proof; storage open and pending refs; KeyPackages and
    Welcomes; Rule 13 and ingest; relay-layer removals; the remainder.
17. One `api.rs` batch, one bridge regeneration, then Dart and l10n.
18. Docs, tracker and the privacy manifest, one editor.
19. Coverage re-pin (`--repin` only) and the full coverage gate.
20. The full CI matrix, the Stage 1 exit checklist, independent review, then
    the stage is ready to merge and release. Stage 1 ships the OpenMLS and
    relay-pool fixes.

**Stage 2 — onto the runtime.** Each sub-stage merges when green.

21. Owner rules on R0, C1, C2 and reads the concession list.
22. A fixture written by the Stage 1 release.
23. 2.0 — open through the runtime; the exception guard becomes a per-function
    list.
24. 2.1 — KeyPackages.
25. 2.2a — location records move to a Haven-owned table; the retirement step
    ships here and stays until the minimum upgrade source moves past it.
26. 2.2 — commits, Welcomes, ingest and advance, behind a branch-local switch
    that does not survive the sub-stage.
27. 2.3 — maintenance.
28. 2.4 — locations on the runtime, only if C1 is resolved.
29. 2.5 — `test-support` leaves the shipped roots; `T-SESSION-PRIVATE` retires,
    or records the one entry the owner kept.

## 5. Baselines

Taken on the build machine on today's code (MDK v0.10.4), before any change.
Later runs are compared with these.

| Check | Result |
|---|---|
| `haven-core`, `cargo test --tests` | 104 test binaries; 4,135 passed, 0 failed, 9 ignored (each needs a live Blossom server, the system keyring or third-party relays) |
| `haven-core`, `cargo check --all-targets` | clean |
| `haven`, `flutter test` | 5,903 passed, 0 failed, 5 skipped |
| `haven`, `flutter analyze --no-fatal-infos` | exit 0 |
| `./scripts/regenerate_frb.sh` on the unchanged tree | no diff |

A full `haven-core` suite takes about 30 minutes there, a check about
3.5 minutes and the Flutter suite about 4 minutes, so effort in the parts is
counted in build cycles.

Stage 0 adds what these cannot show: the wire transcripts and the count-based
cost ledger (relay frames by verb, dials, signature verifications, events
fetched, store pages written), recorded before the bump because they cannot be
reconstructed after it.

## 6. What is verified where

| Where | What |
|---|---|
| Build machine | Rust suites in every Cargo root, clippy, fmt, the bash guards, the soak rig with Docker-backed relays, `flutter analyze`, `flutter test`, `gen-l10n`, ARB parity, bridge regeneration |
| GitHub CI only | emulator and simulator lanes, the Android, iOS, macOS and Windows builds, build-check, the release-link build |

## 7. Risks carried

- **A personal fork.** `nostr` and `nostr-sdk` come from a personal
  repository that `cargo audit` cannot see. It lacks upstream's constant-time
  NIP-44 MAC comparison (`5dded12d`); the comparison is unchanged from the
  0.44.8 Haven ships today and is not exploitable in Haven's use. Tracker row
  and upstream ask.
- **Inherited behaviour.** The deferred-peel caps (O6) and the 30-day
  KeyPackage lifetime come with the release.
- **Silent breaks.** The changes that compile and behave differently are
  listed in the parts, each with a test written to fail first. The acceptance
  bar for Stage 1 is those tests, never compilation.
- **The one-way database migration.** Covered by the fixtures written at
  v0.1.13, the relay-free early gate, and the assertions that no KeyPackage
  key is retired and no circle quarantined at first open.
- **Stage 2 may stop partway.** If C2 is not conceded, the runtime migration
  waits on an upstream change after 2.2a, and Haven stays on the guarded
  exception until then.

## 8. Rulings applied during review

The review ledgers at the end of each part cite these by number.

| # | Ruling |
|---|---|
| R1 | One order of execution (§4). Work lands as green, pushed commit series on the migration branch. Owner items do not block Stage 0. Effort is counted in build cycles. |
| R2 | The fixtures and the old peer represent v0.1.13, the build users hold, as well as the pre-bump tree. One relay-free test proves the new build still classifies a v0.9.4-era store as "reset" and a v0.10.4 store as "migrate". |
| R3 | Stage 0: baselines on today's code (wire transcripts, cost ledger, test pass rates); the extended release gate; fixture time anchors, required shapes instead of non-empty tables, MDK's dump recipe, one store keyed the production way; a relay-free early gate; `libfaketime` only behind a self-probe; four chained compat runs; guards corrected; the Dart lockfile enforced; refactors that work on 0.44 land first. |
| R4 | Stage 1: Haven keeps today's Welcome size edge; a forged-signature kind-445 is dropped as if withheld and stays refetchable; the compile sweep ports behaviour mechanically and every behaviour fix is a red → green pair; the exception guard is a feature check plus a file allowlist; work Stage 2 would delete is deferred; the background-open marker holds a Haven build constant; `StoreNoSpace` joins the typed open errors. |
| R5 | Stage 2: each sub-stage merges when green; the location-row retirement step ships and stays; the owner rules on R0, C1 and C2 first. |
| R6 | The owner items and their defaults (§3). |

## 9. Review record

The plan was built and checked in the order the project requires:

1. Thirteen research passes over the upstream diff, the rust-nostr fork, the
   supply chain, CI, and all 65 tracker rows.
2. Two independent architecture analyses of how Haven should sit on v0.16.0.
3. Four expert drafts, one per part.
4. Four independent confirmations (security and protocol; Rust engineering
   and cross-part consistency; tests and CI; data integrity across the
   upgrade). Each returned *confirmed with required changes*.
5. Revision of every part under written rulings, then an independent
   fix-check that each required change landed.

Each part ends with a review ledger: one row per finding, and what changed.
