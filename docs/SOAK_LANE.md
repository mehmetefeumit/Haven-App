# The Tier-1 soak lane (`tooling/soak`, the `haven-soak` rig)

The functional lanes drive a real app on a real emulator through a real user
flow, once, on a healthy network. The classes of failure that produced the
"sharing stops after hours" incident are not in that space: they need a world
that is broken deliberately and repeatedly, over a schedule, with the
invariants checked at every quiescent instant rather than at the end.

That is what this rig is. It builds a whole Haven world IN PROCESS — several
devices, each with a real `CircleManager`, a real SQLCipher store and a real
live-sync engine, against hermetic `nostr-relay-builder` relays it can take
down, wipe, close, reorder and lie to on a seeded schedule — and grades the
result against oracles. There is no emulator, no simulator and no app: the
subject is `haven-core`.

- The lane: `.github/workflows/soak-core.yml`, called from `ci.yml` stage 4
  with `profile: pr`, `needs: [rust]`.
- The crate's own job: `rust-check.yml`'s `soak-tooling`.
- The runner: `tooling/e2e/ci/run-soak-core.sh` (Linux only).
- Locally: `scripts/run_soak_local.sh core [--profile P] [--count N] [--seed S]`.

---

## What green proves, and what it does not

Stated in PLAN §13's own words, because a soak lane is exactly the kind of
instrument whose green is read for more than it says.

**Green means:** for the seeds and the gated scenario set, at this commit and
toolchain, no declared invariant was violated within the declared window,
every scheduled nemesis fired and was observed, and no needle of a blocking
class appeared in any captured sink.

**Green does not prove:** seeds not run; anything beyond the profile's own
window; real-device suspension or any battery figure; an identifying value in
an encoding the manifest does not expand (the scanner's ledger names the gaps);
that a value printed by a step whose stdout is the public job log was contained
— there, prevention (the redirection rule
`check_logscan_wired_everywhere.sh` enforces) is the only control; the sharer's
timezone (the host log stamp is structural); single-branch soundness if a
future MDK bump wires app witnesses.

Five more, specific to Phase 1 and listed here so nobody has to infer them:

* **The KeyPackage plane is bypassed.** A world's members are invited from key
  packages minted in process and handed to `create_circle` as values: nothing
  publishes a kind 30443, nothing fetches one, no NIP-65 (kind 10002) list is
  read, and no rotation happens. Green here says nothing about KeyPackage
  publication, discovery or rotation — `kp_rotation_e2e` owns that plane.
* **The relay double does not enforce NIP-40 `expiration`.** A real relay drops
  an expired kind-445 and refuses to serve it back; `nostr-relay-builder`'s
  store does neither, so a long arm can be served catch-up pages a real relay
  would not have. What mitigates it is client-side: Haven screens the
  expiration on receive (`nostr/mls/manager.rs`), and the rig's own arms are
  short against the 228 s retention. Nothing here grades relay-side expiry.
* **`relay/forge.rs` forges WEBSOCKET FRAMES, not Nostr events.** It writes
  `CLOSED`, `NOTICE`, `EOSE` and duplicate `EVENT` frames into the
  client-facing stream. Every event the rig puts on the wire is minted by
  haven-core and signed by a real key; nothing in this crate fabricates one.
* **Recall for engine-minted secrets is structural, not declared.** The rig
  declares every value it mints — device keys, pubkeys, group ids, circle
  names, relay URLs, event ids, coordinates — through typed wrappers, and those
  become needles the scanner searches for by value. Exporter secrets and epoch
  secrets are minted INSIDE the MLS engine and have no accessor, so the rig
  cannot declare them and no scan can search for them by value. What covers
  them is the structural rules (S1/S4/S8 in `tooling/logscan`), which match on
  SHAPE. That is a real gap, and it is the same one PLAN §8.2 records.
* **A `{:?}` of a value bound to a local name is outside the source guard.**
  `check_soak_test_only.sh` check 5 bans the Debug format family over any
  `haven_core`/`cgka`/`nostr`/`openmls` value, matched per invocation. A
  foreign value assigned to a local binding on one line and formatted on
  another is not seen. The rig's crate-local `Debug` test covers what the rig
  itself defines; nothing covers the third case but review.

---

## Which safety invariants Phase 1 actually grades

PLAN §2.1 lists nine. Phase 1 grades **S1 and S7**, partially grades **S3** and
**S5**, grades **S6 structurally only**, and grades **none of S2, S4, S8, S9**.
Spelled out, so a reader of the green tick knows what it covered:

| # | PLAN §2.1 invariant | Phase 1 |
|---|---|---|
| S1 | Single branch (current-epoch cross-decrypt both ways, round-unique payloads) | **GRADED** — oracle O1, round-unique payloads. Both directions where it matters: every scenario's CLOSING round probes each chain pair BOTH ways, with the device that was restarted, reopened or resumed sending FIRST (a rebuilt epoch or exporter is invisible to the device itself and shows only as a peer failing to decrypt what it produced), and the nemesis phase's teardown round sweeps every ordered pair. Intermediate rounds stay one-directional over a spanning chain, which is the cost trade `Reach::These` exists for |
| S2 | Forward secrecy after removal | **NOT GRADED** — needs O3 and scenarios S02/S21, both Phase 2 |
| S3 | Publish-before-apply (Rule 13) | **PARTIAL** — per COMMIT, not per transition. Exactly one function in the rig resolves a pending state (`publish_and_resolve`), and it confirms only on an acknowledgement a relay's client-facing ledger really carried; S18's three arms assert the gap from both sides (stored HERE, unacknowledged THERE), assert that a rolled-back commit left the whole circle on one epoch, and assert from the rebind counters that no socket went away while the ack was withheld. What is NOT graded is the universal form — "every observed epoch transition has a stored, acked commit" — because no oracle walks the ledger against the epoch history. That walk needs a per-transition record the Phase-1 ledger does not keep |
| S4 | Nothing identifying on the wire | **NOT GRADED** — the wire oracles are the e2e lanes' (`check-wire-journal.sh` and friends); the rig has no wire journal in Phase 1 |
| S5 | Retention window (5 past epochs) | **PARTIAL** — O5 classifies an undecryptable row, but O4 (the window edge) is Phase 2, so "nothing older decrypts" is not asserted |
| S6 | Cursor integrity | **STRUCTURAL ONLY** — and the reason is measured, not assumed. Reading the hold-back needs an event that is DELIVERED and un-applied while a subscription generation is open, and at this pin the rig cannot produce one: a message sealed at an epoch the receiver has not reached peel-fails (the kind-445 outer layer is keyed by the sender's epoch exporter), and the buffering outcome the engine does produce — the publish-before-apply transition, which S19's `commit-gap` arm grades — leaves no gating row and no delivery to read a cursor against. Separately, every event the rig can mint through the product is dated `now`, so "advanced from the REQ's open instant" and "advanced from the event's `created_at`" are observationally identical at one-second resolution. What covers S6 is `haven-core`'s own anchor tests plus the structural fact that the rig never writes a cursor |
| S7 | One session per DB (Rule 14) | **GRADED** — every restart asserts `is_session_live` true before and false after, against a bounded poll, on the `session.sqlite` PATH (a directory computes a key nothing is registered under and answers `Ok(false)` for ever) |
| S8 | Bounded removal-effectiveness lag | **NOT GRADED** — scenario S21, Phase 2 |
| S9 | Nonce uniqueness (Rule 11) | **NOT GRADED** — nearly free once the relay ledger keeps 445 `content` prefixes, which is Phase 2 |

Oracles **O3** (forward secrecy) and **O4** (retention window) are likewise not
in the Phase-1 registry. The registry simply does not contain them: there is no
stub, no skipped test and no "pending" row, because a scaffold that asserts
nothing reports coverage it does not have.

## Which scenarios have no lane execution yet

Seven scenarios exist this phase: **S01, S06, S11, S13, S17, S18, S19**.

* `pr` (the only profile CI dispatches) runs **S01's single-relay outage arm,
  S06, S11 and S13**.
* **S17, S18 and S19 have NO lane execution until Phase 2.** The nightly and
  weekly scheduler workflows are Phase 2; `soak-core.yml` carries their jobs so
  there is something to call, and nothing calls them. Those three run in
  `tests/oracles.rs` and under
  `scripts/run_soak_local.sh core --profile nightly`.

A green `soak-core-pr` therefore says nothing about the CLOSED-prefix
behaviour (S17), the swallowed-OK Rule-13 arm (S18) or duplicate/reorder
delivery (S19) beyond what a unit test proves.

### What the crate's own tests run instead, and how much of it

`tests/oracles.rs` runs **every registered arm** as its own test — all sixteen
but one — rather than one "smallest arm" per scenario. That distinction is the
whole point: an ordering over arms tie-breaks positionally, and the version
that ordered by derived deadline left eight of the sixteen with no success path
anywhere, including BOTH of the Rule-13 arms S18 exists for. The one exclusion
is S17's `full-intake`, whose bound starts at the 684-second delivery-silence
window, and `the_happy_path_sweep_runs_every_arm_but_the_one_it_excludes`
asserts that the excluded set is exactly that one arm — so a new arm cannot
join it silently.

Beside the sweep there is **one deliberate mis-configuration control per
scenario**, seven in all, each running the real arm against a world arranged so
the condition it grades cannot arise — a second endpoint that never returns, a
policy clock that starts past the horizon the arm is supposed to straddle, a
swallowed acknowledgement that stops the victim circle existing, a closed
endpoint with nothing to duplicate — and each requiring the verdict to be
**rc 3**, the world proving nothing, rather than the rc 0 every oracle would
otherwise hand it.

---

## The rc taxonomy, and the two markers

The rig reuses `haven-logscan`'s five constants with the same meanings, folded
with `worse()` — **1 > 2 > 3 > 4 > 0** — end to end: in the rig, in
`run-soak-core.sh`, and in `scripts/run_soak_local.sh`.

| rc | Meaning | Example |
|---|---|---|
| 0 | Clean: every scheduled fault fired and was observed, every floor met, no invariant violated, every scan clean | — |
| 1 | **Violation or leak** | O1 red after quiescence (violation); a relay URL in a captured line (leak) |
| 2 | **The rig is broken**, not the subject | `allow_ws_loopback_for_test` returned `Err`; S13's key set-difference was not exactly one; a leaked `Arc` kept the session live |
| 3 | **Unusable**: the world or schedule proves nothing | a scheduled fault never fired; an expectation floor unmet; a shape plant missed |
| 4 | **Proves too little**: an intact run with an UNGRADED verdict | a manifest with no searchable term; a declaration floor unmet |

**rc 1 carries two opposite evidence contracts**, so the run emits two markers
and the scan verdict and the invariant verdict are folded separately:

* `LEAK.marker` — a capture carried a declared identifier. `run-soak-core.sh`
  removes the whole evidence tree and leaves one harness-authored line in its
  place, so the lane's `if-no-files-found: error` upload publishes the FACT of
  containment and not the evidence. The class, encoding and `sink:line` of each
  finding are in the job log; no value is recorded anywhere.
* `VIOLATION.marker` — an invariant broke. The first-violation snapshot is the
  whole point and is preserved and uploaded.

**Recorded taxonomy residual.** PLAN §9.3 labels rc 4 `SCANNER_BROKEN` / INFRA.
That is rc **2**'s meaning in the shared taxonomy
(`tooling/logscan/src/lib.rs`), where rc 4 is a META floor — "the run proves too
little". One taxonomy holds across the tree; §9.3's wording is corrected in the
change that lands `soak_finalize` in Phase 2. This is recorded, not silently
reconciled.

---

## Evidence, and the two trees

There are two trees and the split is the policy, not a convenience:

| Tree | What is in it | May it be uploaded? |
|---|---|---|
| `/tmp/haven-soak/needles/` | the sealed needle manifest — every value the run declared, verbatim | **Never.** Wholly upload-banned (`check_wire_proxy_test_only.sh` checks 3 and 6). No workflow or `tooling/e2e/ci` runner may name a path under it in an upload `path:`, a `$GITHUB_STEP_SUMMARY` write, a `gh issue`/`gh pr` body, or under `cat`/`tee`/`head`/`tail`/`awk`/`sed`/`jq`/… Writing, deleting and passing it as an argument are what a lane legitimately does |
| `/tmp/haven-soak/evidence/<per-process>/` | each scenario's captured lines, scanned in place | Never, same ban |
| `${RUNNER_TEMP}/soak-upload/` | the banner, the materialised schedule, the timeline, the redirected rig stdout, any first-violation snapshot | **This is the only uploadable tree**, as one `upload-artifact` step with `if-no-files-found: error` |

**The evidence directory is minted per process, and a clean capture leaves
nothing in it.** Per process (`run-<pid>-<nonce>`, created `0700` under a root
that takes the needle directory's own four checks — symlinked parent refused,
mode asserted after creation — and each file opened `0600`) because the path
was fixed: two soak binaries on one runner wrote each other's scenarios, and a
run inherited whatever a previous one had left. The file is removed the moment
the scan says the capture is **clean** — a green run has no reason to leave the
subject's own lines on a disk — and removed again, as containment, when the
scan says it holds a declared value. It is KEPT only for the verdicts in
between, where reading the lines is the diagnosis. The directory's name is
never printed: a finding names the capture's LABEL (`s01-outage:12 class=…`),
which is also what keeps two runs' reports byte-identical.

**Correction against PLAN §9.3, recorded here rather than applied silently:**
the plan puts the uploadable subtree at `/tmp/haven-soak/upload/`. It cannot
live there. The ban above is keyed on the `/tmp/haven-soak` ROOT — deliberately,
because a location-keyed ban was defeated twice by callers moving a path — so
an `upload/` subtree under it would be a permanent, guard-visible violation.
The uploadable tree is therefore `${RUNNER_TEMP}/soak-upload/`.

### The sealed manifest, and the trade behind it (owner decision Q5)

The rig writes its sealed manifest to disk **only** when `--needle-manifest
<path>` is passed, and only CI passes it. A local run seals in memory, scans in
process, and leaves nothing behind (`scripts/run_soak_local.sh` refuses the
flag outright).

CI passes it because the lane has a real reader for it and a landed guard that
removes it: `run-soak-core.sh` hands the path to `scan-logs.sh --manifest`, and
`check_logscan_wired_everywhere.sh` rules (h)/(i) require `rotate-needle-dir.sh`
before the first capture and an `always()` discard after every upload.

The alternative the security review asked for — strictly in memory, never on
disk — has a cost that is worth stating: the lane's second scan would then have
to be `--rules-only`, which rule (g) of that guard forbids outside
`rust-check.yml`/`coverage.yml`, because a rules-only verdict certifies that the
structural rules RAN and says nothing about whether a declared value is absent.
The trade is real. It was decided in favour of the on-disk manifest with the
rotation and the discard.

### Why the lane scans twice

Neither manifest subsumes the other, so `run-soak-core.sh` runs the wrapper
twice over the same files:

1. against the manifest the **rig** sealed from its own declarations — the only
   thing that can search for a value this run actually minted; and
2. through `logscan_gate host`, whose seal adds the harness's fixed **host**
   needles and the lane's endpoint exemptions — which the rig has no way to
   declare.

They are two manifests on purpose: `logscan_seal` REUSES whatever sits at its
own run-id path, so a rig manifest written there would replace the host needles
rather than add to them. The rig's manifest is suffixed (`<run-id>-soak`) for
exactly that reason.

**Both passes rest on the plant the rig prints on its own stdout.** The tree
they read is scanned as the `soak` class, which requires a `rust` OPENING plant
(`tooling/logscan/policy.toml`), and the rig's per-scenario plants are in the
per-scenario captures — a tree nothing may upload and neither pass reads. So the
rig opens its stdout with a plant of its own and closes it with one, first line
and last, before the plan line and the banner: that stream is a capture of the
class, and the reach it has to prove is the lane's REDIRECTION of it, not the
log backend. Without it both passes are rc 3 ("positive control missed") on
every healthy run, which is how a control gets deleted instead of fixed. The
plant is written and flushed before the first world is built, so a reaped run
carries it too; `tooling/soak/tests/lane_capture.rs` drives a real run and
replays both halves — the tree as it stands, and the same tree with the opening
line removed.

### ...and why that pair runs from three places

The deadline is `timeout`, which signals the whole PROCESS GROUP: an overrunning
run dies between the rig and the scan, and the upload step — gated on the job
not being cancelled — would then publish a tree nothing had read. So the pair
above is a function (`soak_finalize`) reached three ways: at the end of a
healthy run, from the runner's own TERM/INT/EXIT traps inside the 60 s kill
grace, and once more from the lane's own `Scan the soak evidence before upload`
step, which runs `run-soak-core.sh --scan-only <profile>` on `!cancelled()` —
the only one of the three a SIGKILL after the grace cannot skip. Once entered,
the scan IGNORES TERM, INT and HUP for the rest of the process: the deadline
signals the whole group, so it lands inside the scan as readily as before it,
and a handler re-entering mid-pass left the tree emptied by the key-material
floor and never contained. What can still stop it is the SIGKILL 60 s later,
which is what the lane's own step is for. Within one process the scan runs
once and a second call answers with the first pass's verdict; across processes
it is idempotent: a second pass over a clean tree re-reads it, over a CONTAINED one
reports the leak that emptied it without re-reading the harness's own note, and
over a tree the drive never created (a build step failed above it) reports
nothing at all rather than a second red. `check_soak_lane_reachable.sh` L7 is
what holds that step in place, and holds its condition off the drive's outcome:
a scan keyed on the drive succeeding is skipped in exactly the case it exists
for.

A reaped run's scan is searched for the values that run minted, because the rig
seals INCREMENTALLY: the manifest is re-sealed as each world is built and again
as each arm finishes, written to a sibling and renamed over the target, so a
reader that opens the path at any instant gets a complete manifest — the
previous seal or the current one, never half of one. The window this leaves is
a world's first mint to its first seal, and those are the same instant: a world
declares through the seam as it is constructed, and `world_for` seals before it
hands the world back. The runner's **rc 4** branch (intact, kept, UNGRADED)
therefore now reports the one case that remains: a run reaped before its FIRST
world was built, which has nothing to search for because it minted nothing.

---

## Timing: the honest p95, and what the lane costs the pipeline

**The ≤ 8 min p95 in PLAN §12 is the lane JOB's own wall time, job-start to
job-end, on WARM-CACHE runs, excluding queue time.** It is not a
commit-to-green figure. `soak-core-pr` is `needs: [rust]`, and stage 1's
`haven-core` job runs about 18 m 49 s, so the lane begins roughly 19 minutes
into every run no matter how fast it is. A cache-miss run (a cold build is
plausibly 10–25 minutes, bounded by the 40-minute job cap) is recorded with its
cache-miss evidence line and excluded from the p95 rather than averaged into
it.

Three numbers that are easy to conflate, and are not the same thing:

| Number | What it is |
|---|---|
| **1320 s** (`pr`) | the RUN budget: the work the profile TOML declares — the ARMS *and* the background nemesis phase the driver walks before them. `tests/budget.rs` proves Σ(derived deadline of every declared arm) + Σ(one graded round per scheduled probe, plus the teardown round) + margin fits it |
| **23m** | the inner DEADLINE, the budget plus twice the margin so a hung run is killed with time left to finalise. `run-with-deadline.sh` prints which bound fired and its number, where a bare `timeout` would leave an anonymous 124 |
| **25 / 65 min** | the drive step's cap and the job's |

**Why the ceiling sits so far above the measured run (D4).** A healthy `pr` run
measures about **twenty seconds**; the budget above is **1 320**. The two are
not in tension, because a derived bound is only ever PAID when something fails
to happen. The arms cost ~261 s of bound and the background schedule ~1 016 s —
five graded probe rounds at the pool's own 123-second reconnect ladder plus the
teardown sweep — and every one of those seconds is a ceiling on a wait that
normally returns in milliseconds. Pricing the phase at anything less would be
asserting a bound the product does not have, which is the one thing this table
may not do.

The cost of the wider ceiling is therefore not lane time. It is **how long a
HUNG run blocks a pull request before it is reaped**: 23 minutes instead of 6.
Nothing else changes — the p95 stays at build + ~20 s, and what names WHAT went
wrong is still the rig's rc taxonomy, never the deadline.

**Recorded, for the lane's owner:** the `pr` job cap sits at **65**, above the
sum of its step caps (10 scanner + 25 rig build + 25 drive = 60), so the
drive's own 23-minute deadline is what reaps a hung run rather than the job's
anonymous timeout — which is the outcome the ordering rules exist to prevent.
The other two jobs are the same shape (125 against 119, 355 against 340). What
is still missing is C6's other term: job cap ≥ Σ step caps **+ declared
uncapped minutes**, and that declaration has to be MEASURED. C6 therefore
deliberately does not cover the soak jobs yet (see "Two decisions inside those
guards" below); it joins C1–C5 over them in the commit that can cite real runs,
and the caps may need to move again then.

`check_soak_lane_reachable.sh` ties the TOML's declared deadline to the
workflow's literal, in both directions, because they are two files edited by
two owners and the failure when they disagree — a reaper firing before the rig
can finalise — reads as an anonymous timeout.

**The lane carries ONE inner bound, deliberately.** There is no second
`timeout` around the rig itself. `check_e2e_lane_budget.sh` prices a lane as
(the sum of its bounded waits + a flat 180 s unbounded-work allowance it
declares once for every lane) and refuses a deadline below that, so a ~5 m inner
bound under a 6 m deadline is arithmetically impossible: it would force the
deadline to about 9 m for no diagnostic gain, since the rig's own rc taxonomy is
what names WHAT went wrong and a deadline only ever names THAT it hung. The
`cargo run` is unbounded work that is not a wait, so the budget guard prices it
by that allowance alone — which is the honest reading: the deadline is the
bound. The manifest section for `run-soak-core.sh` says so where the arithmetic
lives.

### The cost to the whole pipeline

`soak-tooling` lives inside `rust-check.yml`, which **every stage-4 lane waits
on**. A cold build there delays the entire pipeline, not just this lane. That
is why it carries an explicit `timeout-minutes: 45` (the only job in that
workflow that does) and why it shares ONE `shared-key: soak-crate` cache with
all three `soak-core.yml` jobs — `key:` appends to the automatic job-scoped key,
which would give four jobs four cold builds of the same crate. `soak-tooling`
runs inside the `rust` dependency the lane needs, so the cache is written before
the lane starts.

Measured warm baseline for context (run 35376588206): `haven-core` clippy
2 m 26 s, `cargo test` 10 m 55 s, `build --release --lib` 4 m 27 s; the two
pre-existing tooling jobs under a minute each, but neither compiles
`haven-core`. This one does, with `test-utils` on, which pulls `libsqlite3-sys`
with `bundled-sqlcipher-vendored-openssl` — a vendored OpenSSL and SQLCipher
built from source — and `[profile.soak]` is a new target subdirectory on top of
that. `[profile.soak]` deliberately does **not** set `debug = 1`: the symbols
would inflate a cache sharing one 10 GB LRU budget with four other crates'
caches, and the timeline, not a backtrace, is this rig's diagnostic. The first
CI run reports the `soak-crate` cache size as the evidence for that choice.
(`Swatinem/rust-cache` finds a profile directory to prune by the
`deps`/`.fingerprint`/`build` markers inside it rather than by a fixed
debug/release list, so `target/soak` is cleaned like any other.)

---

## The banner

Written to `${RUNNER_TEMP}/soak-upload/banner.log` **before the run starts**, so
an rc-3 run — "the faults never fired" — still has its seed on record.

```
haven-soak profile=pr seed=0x…  commit=<short sha, <=12 hex> rustc=<version> schedule=<8 hex>
  rc_names=0clean/1violation-or-leak/2rig/3unusable/4meta
  measured: wall=<s>s peak_rss=<MiB>MiB
  S07 amplification factor: not measured (Phase 2)
```

**Why the seed and the schedule tag are printable.** Every preimage of a
scheduler seed is public repository metadata, and the `pr` seed is checked into
`tooling/soak/profiles/pr.toml`. Neither identifies a user, a circle or a
device: they identify a SHAPE, and that shape is in the repo.

**Why both are truncated.** The banner is scanned as a `soak` sink like every
other capture, and `haven-logscan`'s structural rule S2 matches 32–63 hex — so a
40-hex commit sha would red the run's own scan. `commit` is therefore a short
sha of at most 12 hex and the schedule tag is 8. The interpolated BINDING names
matter as much as the values, because the identifier source guard reads argument
identifiers and `digest`/`hash`/`hex`/`sha256` are strong words there: the
bindings are `commit_short` and `schedule_tag`. No `log-scan-ok` marker is
budgeted for the banner, so there is no escape hatch here.

**What is exact, and why.** Measured wall time, peak RSS and observed recovery
durations: they are measurements and durations, which CLAUDE.md allows, and none
differentiates a user. Everything else is bucketed (every magnitude of the
world's behaviour), a delta (every epoch, rendered from the world origin) or an
offset (every instant, from the run origin). The banner prints **no** shape
counts at all — not `relays=3` — because CLAUDE.md forbids exact counts outright
and the profile name plus the schedule tag identify the shape completely, the
TOML being in the repository.

**The S07 line prints the literal words "not measured (Phase 2)", never an
estimate.** That is a deviation from PLAN §12's Phase-1 acceptance row, which
asks the banner to print the S07 amplification factor "replacing estimates";
§4.2 makes S07 weekly-only and Phase 1 does not run it. Recorded here rather
than resolved silently (owner decision Q4).

---

## Residuals

* **RUSTSEC-2026-0237** — `nostr-relay-builder` is unmaintained
  (informational, `patched = []`, no version to move to). The soak crate embeds
  it to build the relays it breaks; it is already carried by three of the four
  other audited lockfiles. Measured non-blocking: `cargo audit` returns rc 0 and
  counts it among its allowed warnings. **There is deliberately no `audit.toml`
  ignore** — cargo-audit's ignore list has no expiry field, so an ignore is a
  silencing change with no end date. The controls are the fifth per-lockfile
  step in `audit.yml`, the row in `haven-core/SECURITY.md`, and this line. What
  lifts it: `nostr-sdk` ≥ 0.45 subsumes the crate, and the tree is pinned to
  0.44 against MDK's `nostr` types, so lifting it is a graph-wide bump.
  `check_mdk_supply_chain.sh` reads `haven-core/Cargo.lock` only, so this
  lockfile is outside its scope; `soak-tooling`'s own one-version step is the
  only other control over what this crate resolves.
* **`nostr::Keys` cannot be zeroized.** Every raw secret byte the harness
  materialises is `Zeroizing`, and `SimDevice`'s secret-bearing fields derive
  `ZeroizeOnDrop`, but `nostr::Keys` holds a `ConversationKey` shape the
  upstream crate does not zeroize — the same residual
  `haven-core/SECURITY.md` records for the product. A named residual, not a
  silent omission.
* **Engine-minted secrets are undeclarable** — see "What green does not prove"
  above.
* **The rc-4 label in PLAN §9.3** — see "The rc taxonomy" above.
* **No `#[serde(deny_unknown_fields)]` on the timeline reader.** PLAN §3.10 asks
  for one. `TimelineLine` keeps a `#[serde(flatten)]` map instead, which is the
  STRONGER of the two for what the field-class test is for: `deny_unknown_fields`
  would make an unclassified field fail to PARSE, and the test would then read a
  file with a hole in it; the flatten map takes the field, hands it to the
  classifier, and fails on the class nobody wrote. The deviation is recorded
  rather than reconciled.
* **The timeline's file name.** PLAN §3.10 names it `soak-timeline-<seed>.log`.
  The lane passes an explicit `--timeline-out` so the file lands inside the
  uploadable tree, which means the lane's copy is named by its path and not by
  its seed; there is exactly one run per profile in a job, and the seed is on
  the banner beside it. A local run keeps the seed-suffixed default.

---

## Guards

| Guard | What it owns |
|---|---|
| `scripts/ci/check_soak_test_only.sh` | The rig stays out of the app and out of every build path; `test-utils` stays a DEV edge of `rust_builder` and is in no `[features]` alias of any manifest, `default` included (that one word would open the probe seams on every DEBUG build, where the `compile_error!` never fires); no shipped manifest sets `debug-assertions = true` under any `[profile.*]` (that one line disarms haven-core's `compile_error!`); no `{:?}` of a foreign type in the rig; the timeline field-class test exists and pins its count |
| `scripts/ci/check_soak_clock_partition.sh` | The two clocks do not convert, and neither reaches the other's seams. Its seam vocabulary is derived from `haven-core`, so a rename is BROKEN rather than clean |
| `scripts/ci/check_soak_lane_reachable.sh` | Something RUNS the rig: `ci.yml` calls the `pr` profile on `needs: [rust]`, the job names are inside the pattern `e2e-flakiness.yml` counts, `rust-check.yml` self-tests the shipped binary, every job drives through the gated runner under an inner deadline and uploads only after it, every job also scans in a step of its own whose condition the drive's outcome cannot switch off (L7), the profiles nest, and the TOML's deadline equals the workflow's literal |
| `check_e2e_step_timeout_ordering.sh` + `check_e2e_lane_budget.sh` | Extended with `is_soak_body()` (excluding `--self-test`). Before it, a plain `ubuntu-latest` `run:` step got C3 alone: the lane could have driven the rig with no inner deadline at all and both guards would have reported it compliant |
| `check_no_identifier_logging.sh`, `check_no_key_logging.sh` | `tooling/soak` as its own root with its own floor in each |
| `check_logscan_policy.sh` | `DECLARED_PLANTS_OFF['soak']` — the rig has no Dart channel, so a declared Dart plant would be a control nothing could satisfy; its `rust` shape plant is what proves the sink was reached |
| `check_logscan_wired_everywhere.sh` | `run-soak-core.sh` in `RUNNER_PINS`, paired with the fixture in its own `--self-test` that pins the gate |
| `check_e2e_publish_before_apply.sh` | `tooling/soak` as a second root beside the Dart harnesses: a file that calls `confirm_published` or `finalize_relay_update` must also CALL a witness (`publish_witnessed`, `publish_and_resolve`, `publish_and_confirm`, `witnessed_ok`). Definitions and comments do not count — a test that implements `fn witnessed_ok` for its own relay double has witnessed nothing |

### Two decisions inside those guards, recorded

* **The `wrappers` pass is NOT extended to `tooling/soak`.**
  `check_no_identifier_logging.sh` requires any function named
  `*_alias`/`*_handle`/`bucket`/`magnitude_bucket`/`relative_secs` to be built
  on `haven_core::log_alias`. The rig cannot be: production's salt is `OsRng`,
  per-process and un-injectable, while the rig's tags must be DETERMINISTIC or
  `tests/determinism.rs` means nothing. So the rig mints its own ordinals
  through functions named outside that vocabulary (`sim_tag`, `sim_magnitude`),
  and its tags are disjoint from production's (`simdev#`, `simcircle#`,
  `simrelay#`, `simevt#` against `circle#`, `peer#`, `event#`, `relay#`) because
  both land in the same evidence file from the same process. Buying determinism
  by injecting a salt into `haven_core::log_alias` is the move this exemption
  exists to forbid.
* **C6 (job cap ≥ Σ step caps + declared uncapped minutes) does not cover the
  soak jobs yet.** C6 demands a `# job-uncapped-minutes: <m> (<N> runs, worst
  <run id>)` declaration whose whole point is that it is MEASURED. A lane that
  has never run cannot state one, and a fabricated declaration is worse than
  none — it is a number a reviewer would try to re-derive and find nothing
  behind. C1–C5 cover the soak steps today; C6 joins them in the commit that
  can cite real runs.

---

## Reproducing a failure

```
scripts/run_soak_local.sh core --profile pr --seed <the seed from the banner> --count 3
```

A defect reproduces at **every** run of one seed. Anything less is a race in the
rig, and a race in the rig is a bug in the rig: this harness is not allowed to
be flaky, so the fix is the race, never a retry or a loosened bound
(CLAUDE.md, test reliability).

`--stop-at-step <n>` takes the same first-violation snapshot a real violation
would, with rc 0, which is how you walk a schedule up to the tick before the
break.
