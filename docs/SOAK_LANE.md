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

Five more, specific to this tier and listed here so nobody has to infer them:

* **The KeyPackage plane is DISCOVERY-free.** A world's members are still
  invited from key packages minted in process and handed to `create_circle` as
  values: nothing fetches a kind 30443 and no NIP-65 (kind 10002) list is read.
  What S12's `kp-rotation-slot` adds is the other half — a real 30443 published
  into a real slot on a real plane, read back from the plane's own store, and
  the rotation decision taken against the package's own MLS lifetime. Green
  therefore says nothing about KeyPackage *discovery*, and it does say that the
  rotation policy, the stable slot and the monotonic replacement stamp behave
  over a relay — but only where S12 RUNS, which is not the PR lane: it is a
  nightly scenario and no scheduler dispatches one yet. `kp_rotation_e2e` still
  owns the shipped tick that drives them. S12's second arm,
  `kp-expired-rejected`, reaches the cliff itself as BYTES: it mints an expired
  package in the device's own production shape (capabilities and extensions
  copied from a package the session just minted, the account-identity proof
  re-signed over a fresh MLS signer) and asks the engine's own
  `key_package_metadata`, which refuses it with the lifetime-validity variant,
  while a twin differing only in its lifetime clears the whole chain and
  haven-core's own `read_kp_lifetime` classifies the refused bytes `NotCurrent`
  (positively unusable, not unreadable). The copy
  is not optional: `OpenMLS` checks the lifetime LAST, and a hand-built package
  missing one capability was measured to fail with `UnsupportedExtension`
  instead — the false negative the twin exists to exclude. **What that arm does
  NOT prove:** a relay never rejects an expired 30443 — nothing in NIP-01/NIP-33
  or strfry expires a kind-30443 by its embedded MLS lifetime — and wall-clock
  ageing is not reached, because the rejection is a function of the bytes
  (Tier 2's −70 d clock jump is the wall-clock analogue). The invite path's
  refusal is pinned upstream (`cgka-engine/tests/group_creation.rs:695`, and
  `:730` for the range), `DEFAULT_KEY_PACKAGE_LIFETIME_SECONDS` is 84 days while
  7 261 200 s (84 d + 1 h) is the MAX RANGE, and `has_acceptable_range()` is
  `OpenMLS`'s policy, not a Marmot one. Measured cost: 1.8 s of wall per run
  of the arm in `cargo test` (world build included), 26.75 s of derived bound.
* **The relay double DOES enforce NIP-40 `expiration` on save, and that is why
  an expired event can only be injected.** Measured at this pin, not assumed:
  the plane's store is `nostr-database`'s full `MemoryDatabase`, whose
  `index_event` rejects an already-expired event with
  `RejectedReason::Expired` and whose bulk import filters expired events out.
  So nothing can SEED one, and S09's expired recipe is written straight onto a
  subscriber's socket by the fault layer instead — which is also why that
  recipe's evidence is the plane's ledger rather than the client: a conformant
  `nostr_sdk` drops an already-expired event before it emits any notification.
  A *stored* event that expires later is a different case and is not graded.
* **`relay/forge.rs` forges WEBSOCKET FRAMES, and — since S09 — whole events
  under a key belonging to nobody.** It writes `CLOSED`, `NOTICE`, `EOSE` and
  duplicate `EVENT` frames into the client-facing stream, and it mints the four
  outsider recipes S09 injects (expired, doubled `#h`, undecodable, and an
  observed ciphertext re-signed at a `created_at` of the adversary's choosing).
  Every event the rig puts on the wire as a MEMBER is still minted by haven-core
  and signed by a real key; what this crate fabricates, it fabricates as the
  attacker, and never stores.
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

## Which safety invariants the rig actually grades

PLAN §2.1 lists nine. The rig grades **S1, S5 and S7**, partially grades **S3**
and **S6** (S6's advance side only — its hold-back side is still structural), and
grades **none of S2, S4, S8, S9**. Spelled out, so a reader of the green tick
knows what it covered:

| # | PLAN §2.1 invariant | Graded? |
|---|---|---|
| S1 | Single branch (current-epoch cross-decrypt both ways, round-unique payloads) | **GRADED** — oracle O1, round-unique payloads. Both directions where it matters: every scenario's CLOSING round probes each chain pair BOTH ways, with the device that was restarted, reopened or resumed sending FIRST (a rebuilt epoch or exporter is invisible to the device itself and shows only as a peer failing to decrypt what it produced), and the nemesis phase's teardown round sweeps every ordered pair. Intermediate rounds stay one-directional over a spanning chain, which is the cost trade `Reach::These` exists for |
| S2 | Post-removal unreadability | **GRADED** — oracle O3 (`RemovalUnreadability`), produced by S21's two O3 arms, graded APART because the delivery paths prove different things. `removal-delivered-commit` delivers the commit and asserts every later 445 is `Stale{SelfEvicted}` carrying no token: the BOOKKEEPING gate (MDK's `!is_active()`), and nothing about key material. `removal-withheld-commit` holds the commit back (`DropClass::Handshake` on the evictee's endpoint for the whole arm) so the evictee's group stays active and the peel is genuinely attempted, and asserts every post-removal probe is `Stale{PeelFailed}` carrying no token, with a stored row that NEVER resolves (read terminally after the closing round). O3 does NOT grade the RFC 9420 §12.4 forward-secrecy property (a Remove's `UpdatePath` blanks the leaf): that is openmls's, tested upstream, and is unreachable from Haven's code — an evictee that never received the commit has no epoch-N+1 exporter secret whether or not the `UpdatePath` was correct, so `PeelFailed` on the withheld path cannot distinguish a broken Remove. §12.4 is the basis O3 relies on, never what the soak measures |
| S3 | Publish-before-apply (Rule 13) | **PARTIAL** — per COMMIT, not per transition. One rung in the rig resolves a pending state (`rig::circle::resolve_one`, reached only through `publish_and_resolve` and the ladder `resolve_ingest` that drains what a resolution's own replay hands back), and it confirms only on an acknowledgement a relay's client-facing ledger really carried; S18's three arms assert the gap from both sides (stored HERE, unacknowledged THERE), assert that a rolled-back commit left the whole circle on one epoch, and assert from the rebind counters that no socket went away while the ack was withheld. Three more arms reach the same rule from other sides: S05's `confirm-err-is-not-a-failure` (an `Err` from `confirm_published` is not a publish failure), and S22's `oversized-commit` and `oversized-removal-wedges-the-circle` (a refusal the publisher hears, rolled back and — for an owed removal — deliberately not). What is NOT graded is the universal form — "every observed epoch transition has a stored, acked commit" — because no oracle walks the ledger against the epoch history. That walk needs a per-transition record the Phase-1 ledger does not keep |
| S4 | Nothing identifying on the wire | **NOT GRADED** — the wire oracles are the e2e lanes' (`check-wire-journal.sh` and friends); the rig still has no wire journal, and Phase 2 adds none |
| S5 | Retention window (5 past epochs) | **GRADED** — O4, over BOTH edges, produced by S04's `offline-past-retention`: one ciphertext sealed exactly `DEFAULT_MAX_PAST_EPOCHS` advances below the reader's tip still decrypts, and one a single epoch older does not. The window is READ from the engine at runtime, never restated, and each edge's distance is MEASURED from the epochs the run really reached — a world that did not reach the intended shape answers "this proved nothing" (one side of the window fed twice) rather than reporting a violation the arm manufactured. What it adds over `haven-core`'s own `rule5_retention_constants_are_pinned` and `rule5_epoch_n_ciphertext_still_decrypts_at_the_window_edge` is those two edges over a real relay and a real live plane, across a pause and a catch-up — and nothing else |
| S6 | Cursor integrity | **PARTIAL — the ADVANCE side only.** S09's two arms grade what an adversary can and cannot do to a persisted anchor. The first is a standing outsider forging at the circle's public `#h` every round for the whole arm — three recipes per round, expired, doubled `#h` and undecodable — which moves neither `read_sync_cursor` nor `read_backfill_floor`, while a legitimate fix delivered in the SAME round proves the plane was carrying anything at all, and a catch-up sweep that still advances locally is the control that keeps the whole arm from being satisfied by a build where advance had been deleted. The second injects ONE forgery, after the original it copies has been folded: an observed ciphertext re-signed a day ahead, which applies nothing a second time and moves neither anchor. And the catch-up sweep's own advance is required to land inside a bracket taken from the same wall clock the sweep opens its window with, which is the advance's PROVENANCE rather than its arithmetic and which a forged `created_at` a day ahead could not satisfy. **The HOLD-BACK side is still structural only, and the reason is measured, not assumed:** reading it needs an event that is DELIVERED and un-applied while a subscription generation is open, and at this pin the rig cannot produce one — a message sealed at an epoch the receiver has not reached peel-fails (the kind-445 outer layer is keyed by the sender's epoch exporter), and the buffering outcome the engine does produce (the publish-before-apply transition, which S19's `commit-gap` arm grades) leaves no gating row, its delivery landing only once the transition ENDS, on the confirm's own replay, which is not a window a cursor is read against. `haven-core`'s own anchor tests still cover the hold-back |
| S7 | One session per DB (Rule 14) | **GRADED** — every restart asserts `is_session_live` true before and false after, against a bounded poll, on the `session.sqlite` PATH (a directory computes a key nothing is registered under and answers `Ok(false)` for ever) |
| S8 | Bounded removal-effectiveness lag | **GRADED** — S21's `removal-lag` arm: after the removal is confirmed by ≥ 1 remaining member, every remaining member reaches the post-removal epoch inside `B(S21)` and none is left publishing at the pre-removal epoch over the trailing `location_publish_window()` (`Absence::RemovalPublishTail`), while the evictee's last readable fix is one minted before the removal. In Tier 1 the epoch is the harness ledger's, not a relay-visible wire fact |
| S9 | Nonce uniqueness (Rule 11) | **NOT GRADED** — nearly free once the relay ledger keeps 445 `content` prefixes, which is Phase 2 |

Oracle **O3** (`RemovalUnreadability`) **is in the registry**, and S21's two O3
arms (`removal-withheld-commit`, `removal-delivered-commit`) produce the state it
grades, so S2 is graded by running arms. O3 is deliberately NOT named "forward
secrecy": it grades post-removal UNREADABILITY on both delivery paths and cites
RFC 9420 §12.4 as the basis it relies on, never as something the soak measures
(§12.4's `UpdatePath`/blanked-leaf property is openmls's, tested upstream, and is
unreachable from Haven's code — the evictee's engine refuses after eviction and
cannot peel without the new epoch's exporter secret). **O4 is also in the
registry**, and S04's `offline-past-retention` is the arm that produces the
state it grades.

## Which scenarios have no lane execution yet

Twenty-one scenarios exist: **S01, S02, S03, S04, S05, S06, S08, S09, S10, S11,
S12, S13, S14, S16, S17, S18, S19, S20, S21, S22, S23**.

* `pr` (the only profile CI dispatches) runs **S01's single-relay outage arm,
  S06, S11 and S13**.
* **S02, S03, S04, S05, S08, S09, S10, S12, S14, S16, S17, S18, S19, S20, S21,
  S22 and S23 have NO lane execution yet.** The nightly and weekly scheduler workflows are still to come;
  `soak-core.yml` carries their jobs so there is something to call, and nothing
  calls them. Those seventeen run in `tests/oracles.rs` and under
  `scripts/run_soak_local.sh core --profile nightly`.

A green `soak-core-pr` therefore says nothing about a receiver partitioned
behind a second publisher (S02), a commit a relay forgot before a paused member
returned (S03), the member-absence spans and
the retention window (S04), the publish→confirm window (S05), a commit buried
on the live plane past a relay's replay cap (S08), the
cursor-poisoning adversary and the two anchors (S09), the ten-circle roster
under one outage (S10), the KeyPackage rotation slot (S12), a same-epoch commit
race (S14), the three durable stores a flood can grow (S16), the CLOSED-prefix
behaviour (S17), the three swallowed-OK Rule-13 arms (S18), duplicate/reorder
delivery and the commit-gap fold (S19), the catch-up sweep under clamped,
refused, cold and forged pages (S20), post-removal unreadability and the
removal lag (S21), the oversized commit, Welcome and removal wedge (S22) or the
chained-commit backlog C7 records (S23) beyond what a unit test proves.

### The first recorded expectation, and what makes it stale

S14's `race-anchor-exhausted` asserts a KNOWN-BAD outcome rather than grading
it. Two devices commit from one epoch, each walks its own branch past
`max_rewind_commits` (read from the policy the session installs, never
restated), and neither can converge the other's sibling afterwards. What is left
is a **twin fork**: both devices report the same epoch, the same roster and a
healthy send path, and only a bidirectional cross-decrypt says otherwise.

*At this commit Haven raises no per-circle verdict for that state.* The arm
asserts the fork AND the silence — `unrecoverable_circles()` empty, no
`GroupUnrecoverable` on either device's bus — as its expectation, so both
directions are covered: if the fork stops happening, the canary is unmet and the
arm is **rc 3**, "the recorded expectation is stale"; if a verdict starts
appearing, the silence canary is unmet and it is **rc 3** again, which is the
correct signal — the recorded expectation must be replaced by a graded one in
the same commit. Changing it in either direction without citing OD-1 (DECIDED, a
per-circle verdict inside the circle's details sheet; NOT BUILT) is a regression.
The 684-second form of that silence is asserted by S03's weekly arm
`lost-commit-unnamed` (below); a second eleven-minute absence here would buy no
further claim, which is why every arm in that scenario declares no absence
window at all.

The scenario's other three arms assert the opposite and GRADE it: a race that
does not converge is a finding about the subject, reported as
`branch-diverged` / `epoch-diverged` / `roster-diverged` at rc 1, never as a
floor that went unmet.

### The second recorded expectation: a removal obligation that can never be discharged

S22's `oversized-removal-wedges-the-circle` is the same shape for a different
gap. A peer proposes its own removal, this device's engine stages the eviction
commit, the plane refuses it for its size — and `publish_failed` deliberately
does NOT roll it back, because rolling one back is a silent, permanent drop of
the eviction and would leave the leaver deriving the group's keys until some
unrelated commit moved the epoch. Parking is therefore correct and is already
decided. What is undecided is the obligation itself: every retry refuses for the
same reason the first one did, so it can never be discharged, and the circle
stays in its publish-before-apply transition for ever.

*At this commit Haven raises no verdict for that state either.* The arm asserts
the whole of it as its expectation: the evictee still in the roster of the member
that never saw the commit, a send that fails, an inbound fix that is buffered
before the peel rather than applied, `unrecoverable_circles()` empty with no
`GroupUnrecoverable` on any bus, a staged COMMIT rather than the stranded
PROPOSAL a rollback would have left, and the obligation outliving three
foreground publish passes — paired with its own control, because the arm then
lifts the cap and lands the same commit, which discharges it. That release is
what keeps "still owed after three passes" from being satisfied by a world in
which nothing can be published at all, and it is also what keeps the DEVICE
gradeable afterwards: an unredeemed eviction obligation is a per-device read, so
O2 and O6 would otherwise report it — correctly — for every later round. A real
oversized removal has no such release, and that permanence is the whole of OQ-A.
Both directions are covered exactly as S14's are: if the wedge stops
happening the canary is unmet and the arm is **rc 3**, "the recorded expectation
is stale"; if a verdict starts appearing the silence canary is unmet and it is
**rc 3** again, because the recorded expectation must then be replaced by a
graded one in the same commit. Changing it in either direction without citing
OD-1 (DECIDED — a per-circle verdict in the circle's details sheet — and NOT
BUILT) and owner decision OQ-A (name the undischargeable obligation as its own
cause, because its remedy differs: the user cannot retry, and a banner offering
"retry" would offer something that can never succeed) is a regression.

The circle it wedges is built with `build_extra_circle` and is deliberately
outside `world.circles()`: a circle that never sends again may not be one a
world-wide oracle grades, and that is also why the arm declares
`epochs_crossed: 0` and carries every epoch claim as a canary instead.

S22's other three arms GRADE their promise: a size refusal is
machine-readable, nothing is applied locally, the same commit one byte of cap
the other way is acked and applied, and two relays refuse the same bytes rather
than one of them taking it. Tier 1 asserts the CLASSIFICATION and the local
no-apply against a cap MEASURED off this run's own event; T2-19 hits a real
strfry's real `maxEventSize`. Neither subsumes the other.

### The third recorded expectation: a member stranded behind a lost commit

S03's two arms record the shape behind "sharing stops after hours" that needs
no fork and no wedge: a member is paused across one confirmed commit, the
relay's store is wiped before it resumes, and its resume re-subscribes from the
persisted cursor and finds nothing. It is left one epoch below its peers, and
every later commit and fix is sealed above what it holds. The engine's own
signature is a stranded EPOCH and a churning `PeelDeferred` store — each later
445 refused at the outer wrap, retained, retried `MAX_DEFERRED_PEEL_ATTEMPTS`
times and retired — never a growing `Buffered` chain, so the arm keys on the
epoch and the cross-decrypt and never on a buffered count. The strand is
one-directional at that distance: the committer still holds the stranded
epoch's exporter secret for the whole retention window, so the stranded
member's own fixes keep reaching its peers while theirs never reach it, and its
send path stays open. That asymmetry is the user-visible shape: everybody
else's locations stop arriving, with nothing saying so.

*At this commit Haven raises no per-circle verdict for a device stranded behind
a lost commit. This arm asserts that silence. OD-1 is DECIDED — a per-circle
verdict inside the circle's details sheet — and is NOT BUILT. When it lands,
this arm's absence assertion becomes a presence assertion within
`silence_window()`; changing it in either direction without citing OD-1 is a
regression.* The silence is read on every surface haven-core has:
`unrecoverable_circles()` empty on every device, no `GroupUnrecoverable` on any
bus, and the circle-health row readable and carrying no peer-event stamp — that
stamp is the app layer's (`CircleManagerFfi::note_peer_event`), so at this tier
haven-core itself records nothing about the strand at all.

The arm carries its own control, run FIRST: the same pause, handshake
partition, commit, heal and resume with the store KEPT converges all three, so
the wipe — read back off the relay's own store before and after — is the cause
and not the partition. The nightly `lost-commit-strands` grades O6 (the
stranded world is quiet: nothing staged, nothing in flight, no gating row) and
O5 (every refusal is one the classifier accounts for) and deliberately not O1
or O2, which would report the divergence the arm induced at rc 1. The weekly
`lost-commit-unnamed` then waits out the product's whole delivery-silence
window with the engine's own health repair driven throughout, and requires that
nothing named the circle across it and the device is still stranded when it
ends; like S17's `full-intake` it is weekly-only and outside the crate's own
sweep, because an absence window may never be scaled or shortened.

### What S02 deliberately does not assert

S02's two arms grade what Tier 1 CAN: a receiver whose ENGINE endpoint drops
one class of frame at a time keeps the relay's store and acknowledgements
intact, the unpartitioned witness keeps folding the publisher's fixes
throughout, the commit never crosses the partitioned endpoint (final, because a
fix published after it does cross and one connection's frames are written in
order), and a pause-and-resume recovers the commit from a cursor that never
went backwards. The catalogue's "the victim recovers no location published
during the partition" is NOT asserted: it needs the TTL horizon, and the expiry
screen is a WALL read on the wall side of the rig's clock partition, so no
policy step can age an event into it — stepping the policy clock to reach it
is exactly what `check_soak_clock_partition.sh` catches. The forged-expiry
vector is S09's. A scenario that partitions an engine endpoint must also run no
catch-up sweep while the partition stands: the sweep dials the plane's
canonical endpoint for every circle and would heal it by the other path.

### What the crate's own tests run instead, and how much of it

`tests/oracles.rs` runs **every registered arm** as its own test — all
fifty-five but five (two excluded, three expected red — S23, S05's
`kill-receive-auto-commit` and S08's `buried-past-the-cap`, below) — rather
than one "smallest arm" per scenario. That
distinction is the whole point: an ordering over arms tie-breaks positionally,
and the version that ordered by derived deadline left most of the registry with
no success path anywhere, including BOTH of the Rule-13 arms S18 exists for. The
two exclusions are S03's `lost-commit-unnamed` and S17's `full-intake`, whose
bounds each start at the 684-second delivery-silence window, and
`the_happy_path_sweep_runs_every_arm_but_the_one_it_excludes` asserts that the
excluded set is exactly those two arms — so a new arm cannot join it silently.

Beside the sweep there is **one deliberate mis-configuration control per
scenario**, twenty-one in all, each running the real arm against a world arranged
so the condition it grades cannot arise — a partition armed on the witness
instead of the victim, an endpoint that is gone so no commit is ever stored to
be lost, a second endpoint that never returns, a
policy clock that starts past the horizon the arm is supposed to straddle, a
swallowed acknowledgement that stops the victim circle existing or leaves no
confirm that could fail, an endpoint that is gone so no epoch can be crossed
above an absent device, a race in which neither sibling can be confirmed, no
subscription open for a forgery to land on, no plane serving the KeyPackage slot
a rotation would be decided for (and, S12's second control, a package minted
unexpired so the engine has nothing to refuse), nothing reaching a relay to be refused by one,
a store with no backlog for a catch-up sweep to drain, a seed the relay serves whole so no commit is buried under it, and a closed endpoint with nothing to duplicate — each requiring the verdict to be
**rc 3**, the world proving nothing, rather than the rc 0 every oracle would
otherwise hand it.

### The ten-circle roster, and THE BOUND RULE

S10's `ten-circle-roster` grows the world to the whole roster —
`kMaxCirclesPerAccount = 10`, the bound the app refuses an eleventh circle at —
through the same create-and-join path every other circle took, adopts each one
into the world's table so every world-wide oracle grades all ten, and tells
every running engine about it the way the app does for a circle it just created
or joined (a REQ of its own on every plane). One probe round across all ten,
one outage and heal on one plane, and a closing round across all ten, both
directions. Its four canaries: every one of the ten delivered to every device
(the starvation detector), no gating row anywhere, an outage that manufactured
no commit activity on any device (DM-5a, compared in process), and every REQ
the session expects still live in the pool after the reconnect — the adopted
circles' own among them, which at ten circles is what catches a pool that
silently stopped registering a bucket. It records, and does not decide, OD-11:
the ten routing ids are pairwise distinct and every device's own circle table
still answers for all ten at the end, so nothing rotated across the run.

**The bound rule, which carries the claim (decision 0.24): the world-level
deadline is the PER-CIRCLE bound — 171.75 s, the pool's reconnect ladder plus
two round trips — and never ten times it.** The planes are concurrent, and a
linear bound would hide a serialization bug behind slack. If the measured run
cannot meet the per-circle bound at ten circles, that is the finding S10 exists
for, and the bound is never widened to fit it. Measured 2026-09-25 at the PR
shape (eight circles built by the arm): under 16 s including the world build.

### Expected red: S23, and the promotion rule

One arm in the nightly is REQUIRED to be red. S23's `chained-commit-backlog`
grades C7 (`docs/BACKGROUND_SHARING_FAILURE_ANALYSIS.md`): a member paused
across TWO confirmed commits is served them newest-first on its resume — the
page order is pinned by waiting the wall second out between the commits, read
back off the relay's own store, so the strand is the same every night and never
a coin toss on event-id order — and the newer commit cannot peel until the older
is applied, is retained as a `PeelDeferred` row, and is retried only by a sweep
the receive plane never reaches. The device sits one epoch below its peers;
three further fixes from the committer do not move it. Unlike S03 and S14, whose
recorded silences are decided and not built (OD-1), this is a PRODUCT DEFECT
that nobody decided, so it is GRADED rather than recorded: the closing round —
witness leading, so the victim's first probe is a receive — reports
`epoch-diverged` (O2) and `probe-not-delivered` towards the victim (O1) at
**rc 1**, and the nightly carries that red until the fix lands.

What the arm ALSO measured, 2026-09-25: the stranded device's OWN next seal
(`encrypt_location`, nothing published) drains the retained commit — the send
path's settle reaches the deferred-peel sweep the receive path never does — and
it converges. So the blackout is bounded by the victim's own publish cadence
while it is sharing, and unbounded only for a device that receives without
sending; C7's "permanent" reads as "until this device next publishes". The arm
records that lever as its last canary, after the grade, so the recovery is
evidence beside the finding rather than a substitute for it.

`tests/oracles.rs` names the arm in `EXPECTED_RED`, beside
`EXCLUDED_FROM_THE_SWEEP`, with that one reason. Its own test requires rc 1
with both findings, and its FIRST assertion is the promotion rule: **the day the
arm grades rc 0, C7 is fixed, and the arm is promoted to `SWEPT` (and deleted
from `EXPECTED_RED`) in the same change** — never left asserting a defect the
product no longer has, and never quietly re-listed as a recorded expectation.
The product fix — a sweep of deferred peels on resume or on a timer,
independent of whether a peelable event arrived — is not designed in the soak.
Its mis-configuration control withholds the handshake class from the victim's
own endpoint, so no backlog is ever served to it: a device that received no
chain cannot be stranded behind one (that is S03's strand, a partition's), the
served-backlog canary cannot hold, and the arm reports rc 3.

### Expected red: S05's receive-plane kill (C9, attribution OPEN)

A second arm is REQUIRED to be red, for a reason that is measured but not yet
attributed. S05's `kill-receive-auto-commit` subscribes ONE device's live engine
to an extra circle, lets that engine fold a peer's published leave inside a
background burst (the eviction is parked, owed, and nothing is on the wire),
then publishes it from a foreground open into an `OK` the device's own endpoint
swallows, and hard-kills and reopens the device. After the reopen the
obligation is orphaned: the next foreground open publishes nothing,
`orphaned_removal_deferrals()` names the circle and the device's own verdict
sweep emits `GroupUnrecoverable` for it (`unrecoverable_circles()` stays empty —
it is the engine's latch alone). Recorded on the timeline as `after-kill` /
`removal-reported`, the OD4-c answer for a hard kill in that window.

Two findings make it red. **A:** every send on the wedged circle is refused
with no typed reason at either layer, so the classifier can only call it a
`Defect` — hydrate marks the group stable at the epoch the staged commit
projected while `OpenMLS` still holds that removal-bearing commit; the arm
records the refusal and hands O5 nothing. **B:** a peer's own commit of the
same removal, acknowledged and confirmed, is answered `Buffered` by the reopened
device and never heals it, so O2 and O6 report the owed eviction at **rc 1**.
`haven-core`'s `a_deferral_a_peer_healed_after_a_restart_is_not_reported` heals
the same shape on a bare processor, and a replica of it still does; the
difference lies in the live-engine restart path and is not pinned, so **whether
this is the product's or the rig's is OPEN** (C9 in
`docs/BACKGROUND_SHARING_FAILURE_ANALYSIS.md`, owner question OQ-U; the
reproduction and every hypothesis ruled out are in the 2c S05 implementation
notes of the Phase-2 plan). The promotion rule is S23's: its own test asserts rc
1 with O2's `removal-owed` for the killed device, and the day it grades rc 0 it
is promoted to `SWEPT` in the same change. Its mis-configuration control
swallows nothing, so the eviction is acknowledged before the kill and nothing is
left to orphan: rc 3.

S05's other two new arms are swept. `kill-send-plane` kills a device between
SEND and confirm of its own relay-list commit (a swallowed `OK`, the commit
stored and unacknowledged, on an extra circle no peer receives), after the same
update acknowledged has advanced the circle: the reopened device reports
nothing unrecoverable, has no gating row, and sends again (recorded as
`sends-resumed`), and the `Restarted` record carries the C1 release and reopen
latencies. Its control acknowledges the commit, so the kill has no window to
land in: rc 3. `negative-gates-silent` holds one staged eviction and reads the
committer's own live-engine verdict at each of the five OD4-c non-wedge states
in turn — awaiting its own ack, its endpoint dark, its engine paused, a
future-epoch fix from a world circle it missed, an unprocessable event — five
canaries, because one read at the end would pass a verdict that fired and
cleared; it then lands the eviction on an acknowledged publish. Every restart
here is a clean cancel, not a SIGKILL, and the kill kind is not what either kill
arm measures (`Soft` reaches the same outcomes; each doc says why). Measured
2026-09-27 in `cargo test`, three runs each: `kill-send-plane` 44.7 s of wall
(79.75 s of bound; release 21 ms, reopen 174-192 ms), `kill-receive-auto-commit`
about 38 s (79.75 s; release 20-21 ms, reopen 175-190 ms),
`negative-gates-silent` 0.6 s (35.75 s).

### Expected red: S08's live-plane burial (C8)

A third arm is REQUIRED to be red. S08's `buried-past-the-cap`
(`scenarios/s08_live_plane_burial.rs`) grades C8
(`docs/BACKGROUND_SHARING_FAILURE_ANALYSIS.md`): the victim is paused, the
admin hands the admin bit to the witness (a confirmed commit, stored on every
plane, applied live by the witness), the arm waits out
`Absence::ResubscribeLookback` — `GROUP_RESUBSCRIBE_BUFFER_SECS` plus one wall
second, derived in `oracle::bounds` and read back against the commit's stamp in
the relay's own store — and then writes 501 outsider kind-445s carrying the
circle's `#h` into every store (`SimRelay::store`, no more than half a catch-up
page in any wall second). The victim resumes. Haven's live group REQ sets no
`limit`, so the relay serves its default 500 (`RELAY_DEFAULT_REPLAY_CAP`, pinned
on the wire in `tests/relay_faults.rs` because `default_filter_limit` is
`pub(crate)` with no getter) — every one a forgery — and an `EOSE`; the live
plane trusts it, the cursor passes the commit, and neither a second REQ nor a
clean catch-up sweep (every circle swept, nothing truncated, no deadline, no
relay error) asks for it again. The closing round reports `epoch-diverged` (O2)
and `probe-not-delivered` towards the victim (O1) at **rc 1**.

The five canaries are the burial's CONDITIONS, never its symptoms — the real
commit, the lookback waited, every store's newest page all forgeries and a full
page served to the victim on every plane, a fresh REQ answered on every plane,
the clean sweep — so a product that serves the buried commit grades **rc 0**,
not rc 3, and the arm's own test fails its first assertion with the promotion
rule: C8 is fixed, promote to `SWEPT` in the same change. Measured: feeding the
buried commit to the victim after the burial fires exactly that assertion; with
the seed one second after the commit instead of a lookback after it, the live
page still lacks the commit and the SWEEP recovers it (rc 0) — which is why the
lookback is waited; and a seed of 501 forgeries all inside one second left even
that sweep with two pages of forgeries, no commit and no truncation reported,
which is the sweep's one-second pile-up residual reaching further than
`catchup.rs` says, and why the seed is spread. Its mis-configuration control
runs the arm over a seed BELOW the cap: the commit is on the page, the victim
converges, and the capped-page canary goes unmet — rc 3.

`unpacked-control` is the same world with sixteen forgeries: the commit is
served on every plane, the victim applies it live, its cursor moves past it,
and `relay_health()` reports every expected REQ live. It is swept, and runs in
`weekly` only, for the nightly's budget: the burial alone brings the priced
nightly to 4 798.75 s of 4 800, both would be 4 895.50 (`tests/budget.rs` is
the gate). Measured 2026-09-27 in `cargo test`: about 78 s of wall for the
burial and 71 s for the control, each against a 96.75 s bound — the 61 s
lookback is most of both, and the burial's failing O1 probe pays its whole
round-trip bound.

**What S08 is not any longer.** PLAN §2.5 designed S08 around the intake cap:
`packed-window` would replay more than `WORKER_QUEUE_CAP` (8 192) and read the
hold the full queue puts on the cursor. Measured, that is out of Tier 1's reach
for three reasons none of which is the product's: the relay serves at most 500
per REQ, so no replay reaches the queue; the relay pool's 35 000-id tracker
(`nostr-relay-pool-0.44.3/src/relay/inner.rs:1209-1239`) drops an id it has
already seen in the session, so `DoubleEveryEvent` doubles nothing that reaches
Haven and a carried-over hold PINS the cursor instead of being re-asked; and a
relay rate-limits publishing to sixty events a minute per connection, so a
backlog can only be seeded. OQ-D (`packed-window` weekly-only until seven clean
weeklies) is OVERTAKEN BY MEASUREMENT: there is no such arm. **The Tier-1/Tier-2
halves:** S08 drives the re-anchor itself (`go_offline`/`come_online`) and
asserts the core's half; WHEN the app re-anchors — resume, the Dart
`subscriptionHealthInterval` backstop — is Dart's schedule, which Tier 1 does
not run and Tier 2 owns. Neither half covers the other.

### Durable-storage growth: S16's three arms are three different stores

"The engine bounds its storage" is true of exactly ONE of the three stores an
inbound kind-445 can land in at the pinned engine, and S16 measures each on its
own terms (Rule 12; `scenarios/s16_storage_growth.rs`, one arm per store, all
three nightly). Where an event lands depends on who sealed it and on the group's
epoch state when it arrives, because the peel runs after the `can_ingest` gate
and before anything convergence-related:

* **`outsider-flood` — the CAPPED `PeelDeferred` store.** Forgeries an outsider
  can mint from the circle's public `#h` — content that decodes, sealed by no
  member — reach the peel and fail there, and the engine retains them up to
  `MAX_PEEL_DEFERRED_ROWS_PER_GROUP` (256, read from `cgka-engine` at runtime,
  never restated; the crate's first and only direct MDK dependency). The arm feeds
  the store PAST the cap and asserts that exactly `cap` rows were retained and
  every later one was dropped unpersisted — the drop path held for the whole
  overflow, not for a boundary — then one more forgery over the live plane, after
  the cap, which leaves no row either. The classification of those drops,
  `PeelDeferredCapped`, is set from the ABSENCE of a row: the engine answers a
  capped drop and an ordinary peel failure with the same `Stale{PeelFailed}`, so
  only a scenario that flooded the store can tell them apart, and the doc says so.
  Dropping above the cap is NOT a Rule-12 breach — the input is un-peelable, so
  it cannot be legitimate backlog for this device at this epoch, and transport
  redelivery is the recovery path once the backlog drains — and the arm records
  that tension rather than hiding it. Measured 2026-09-26: 264 feeds in under a
  second, and neither of the other two stores moved.
* **`member-future-header-flood` — the UNCAPPED convergence buffer (#757).**
  A co-member seals kind-445s whose OUTER layer peels at the receiver's epoch
  and whose cleartext inner header claims a far-future epoch, through
  haven-core's `forge_future_header_445_for_test` (only a member holds the key
  to mint one), publishes them, and the victim receives them over the wire like
  any 445. `convergence_buffer_len_for_test` — the one instrument that sees this
  store, because `gating_input_count` skips rows above the future horizon — is
  read before the flood as the in-arm control and after every seal, and must
  grow with every one: a strictly increasing curve compared in process, never
  rendered. The stored row's state is read back to prove the flood entered
  convergence and not `PeelDeferred` (without that read the arm would be
  `outsider-flood` wearing this label). An outsider's re-signed replay of one
  seal is carried to the victim and grows nothing (the store is keyed by content).
  Then a real commit lands with the buffer full and the victim follows it, a fix
  crosses the SIBLING circle in the same store, and the far-future rows are all
  still there — nothing drains them, because nothing can.
* **`pending-window-flood` — the UNCAPPED raw `Retryable` persist, OUTSIDER-
  reachable (owner decision OQ-B).** While a group is `PendingPublish` the
  `can_ingest` gate persists EVERY inbound event raw, before the peel, keyed on
  the transport id the sender chose, with no cap at all. The arm opens the window
  the way the product opens it — a swallowed acknowledgement holds a staged
  relay-list commit in its publish-before-apply transition — feeds outsider
  forgeries into it and reads one raw `Retryable` row per forgery (plus one
  carried over the live plane), heals the plane, and the SAME commit is
  acknowledged, confirmed and the circle sends again. Under Rule 13 an
  acknowledgement that does arrive closes the window at once, and the arm
  confirms it rather than hold a window open by hand — none of its canaries can
  then hold, so it is rc 3; no test reaches that branch, because a swallowed
  acknowledgement cannot be un-swallowed from outside the arm. The scenario's
  mis-configuration control is `member-future-header-flood` on a downed plane
  (`tests/oracles.rs`). The flood is eight rows, not the other store's cap, because the confirm
  REPLAYS every raw row the window took — measured 2026-09-26 at roughly a
  quarter of a second per row (85 s for 300), after which 256 have become
  `PeelDeferred` and the rest stay `Retryable` for good; the record is in
  `MARMOT_PROTOCOL_KNOWLEDGE.md` beside #757.

**The recording story (decision 0.31).** The bucket policy renders `5+` from a
flood's third sample and a byte delta as `5+` always, so the growth CURVE is
unrepresentable in the timeline under Rule 15 as implemented. Every count and
byte figure is compared in process; the timeline carries one `buffer-grew`
record per arm with `grew` / `did-not-grow` and nothing else, and the arms
sample every device's session store between feeds against the rig's declared
ceiling (`SESSION_STORE_CEILING_BYTES`, the same one the driver samples at
teardown) — crossing it mid-arm is rc 3, the sim hitting its own guard.

**What the wire proved, and what it did not, until this scenario.** An injected
forgery used to be written on every connection once per matching subscription
plane-wide, and a relay pool notifies an event once per id — so a real engine
saw the injection on its own REQ only if its subscription id happened to sort
first, and S09's wire canaries were (honestly) wire-only. The proxy now writes
an injected `EVENT` on a connection only for the subscriptions that connection
opened, pinned by `tests/relay_faults.rs`, and every S16 arm's live-plane canary
reads the injected event's row (or its absence) out of the ENGINE's store.

### The catch-up sweep under page faults: S20's five arms

RLY-05 was five ways for `run_catchup_all_circles` to call a window finished when
it was not, or never finished at all. S20 (`scenarios/s20_catchup_sweep.rs`, all
five arms nightly) rebuilds each against the real relay double. Every arm seeds a
backlog of GENUINE kind-445s — locations members sealed and never published,
written into every plane's store with `SimRelay::store`, one per circle per wall
second, none in the second a cursor already names — and a seed reaches no live
subscriber, so the harness-driven sweep is the only way the backlog reaches the
device. Every arm is `Undisturbed`: the sweep runs on the device's own
`RelayManager` with an injected `max_duration_secs`, and no live socket is ever
closed, so the pool's reconnect ladder is not in the path. The faults are
relay-global by construction — the sweep dials the canonical endpoint it reads
out of storage — so there is no per-device arm, and because the sweep takes every
circle in an order the product chooses over one connection per relay, every
circle is seeded alike and the one circle a single-shot fault met is found from
the ledger, never assumed.

| arm | sub-defect | what is asserted |
|---|---|---|
| `healthy-drain` | control | the same backlog `clamped-limit` walks down drains in ONE pass: every circle swept, every event applied, every cursor advanced, no deadline, no relay error |
| `clamped-limit` | (c), (d) | every page clamped to two events, so no page can ever satisfy `page.len() >= CATCHUP_MAX_EVENTS_PER_PAGE`; a backlog sized from `CATCHUP_MAX_PAGES_PER_CIRCLE` is fetched whole and the window is still HELD (the budget ran out on the confirming page), and the next sweep resumes at the backfill floor — a band of ONE event on its own ceiling, inclusive at both ends — composes it, and advances |
| `refused-page` | (a) | the relay that answered page one refuses page two (`CLOSED "error:"`): exactly that circle holds, every other advances, and the next sweep finishes the chase |
| `cold-first-connect` | (e) | the second plane refuses the sweep's first connection and answers every later page; no circle is held, so the late relay was not marked silent and no page started from a poisoned floor |
| `future-dated-page` | (b) | a whole page (`CATCHUP_MAX_EVENTS_PER_PAGE`) of rewraps dated a day ahead in every circle's store: none is served, and every cursor lands on the sweep's own open time |

An advance is asserted on the cursor VALUE read back, strictly above where it
was and inside a bracket of two readings of the wall clock the sweep opens its
window with; a hold is bounded from above by the oldest backlog event. The
mis-configuration control is `healthy-drain` over an empty store: the sweep
drains nothing, the advance still lands, and the drain canary has nothing to
have drained — rc 3. Each arm was also run with the product behaviour it grades
deleted from `catchup.rs` (the chased-empty-page hold, the first page's
`until`, the contribution rule, the ceiling's one-second offset, the
`responded` gate on `silent`), and each went rc 3 while `healthy-drain` stayed
clean. `the_boundary_is_the_maximum_across_truncating_relays` remains the unit
proof of the cross-relay boundary rule. **What S20 does not assert** is the
`since` edge of (d): a sweep's floor is its cursor less a re-verification buffer,
never an event's second, so no genuine event can be placed on it.

Measured 2026-09-26, `cargo test`, world build included, three runs each:
`healthy-drain` 9.1–9.3 s, `clamped-limit` 11.5–11.8 s, `refused-page` 4.1–4.2 s,
`cold-first-connect` 2.9–3.7 s, `future-dated-page` 2.9 s, the control 1.4 s —
against 26.75 s of derived bound each (133.75 s for the five). The two long arms
are the backlog's one-event-per-second mint.

**Found while building it (owner decision pending):** the page-bound fix closes
(b) for a FUTURE-dated page only. A full page of kind-445s dated inside ONE
second of the window — here, the same rewraps dated at their source's own
second — is served, keeps the chase alive by page size, repeats at a boundary
that cannot descend, and halts: measured, three consecutive sweeps held every
circle and never served the genuine event one second below the pile-up. The
forgeries carry no `expiration`, so nothing retires them. Recorded as **C10** in
`docs/BACKGROUND_SHARING_FAILURE_ANALYSIS.md` (mechanism and `catchup.rs`
cites); not graded — whether it gets an expected-red arm is owner question OQ-V.

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
little". One taxonomy holds across the tree, and `soak_finalize` has since landed
on it (`tooling/e2e/ci/run-soak-core.sh`), so §9.3's wording is SUPERSEDED rather
than pending a change. This is recorded, not silently reconciled.

---

## Evidence, and the two trees

There are two trees and the split is the policy, not a convenience:

| Tree | What is in it | May it be uploaded? |
|---|---|---|
| `/tmp/haven-soak/needles/` | the sealed needle manifest — every value the run declared, verbatim | **Never.** Wholly upload-banned (`check_wire_proxy_test_only.sh` checks 3 and 6). No workflow or `tooling/e2e/ci` runner may name a path under it in an upload `path:`, a `$GITHUB_STEP_SUMMARY` write, a `gh issue`/`gh pr` body, or under `cat`/`tee`/`head`/`tail`/`awk`/`sed`/`jq`/… Writing, deleting and passing it as an argument are what a lane legitimately does |
| `/tmp/haven-soak/evidence/<per-process>/` | each scenario's captured lines, scanned in place | Never, same ban |
| `${RUNNER_TEMP}/soak-upload/` | the banner, the machine-readable verdict, the materialised schedule, the timeline, the redirected rig stdout, any first-violation snapshot | **This is the only uploadable tree**, as one `upload-artifact` step with `if-no-files-found: error` |

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
The other two jobs are the same shape (135 against 129, 355 against 340). What
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
declares once for every lane) and refuses a deadline below that, so an inner
bound large enough to let a healthy run finish — the 1320 s budget — cannot sit
under the 1380 s deadline: with the allowance it prices the lane at 1500 s and
would force the deadline to about 25 m for no diagnostic gain, since the rig's
own rc taxonomy is what names WHAT went wrong and a deadline only ever names
THAT it hung. The
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

## The verdict

Written to `${RUNNER_TEMP}/soak-upload/verdict.log` at the end of the run,
beside the banner: the banner is for a person, this is for the job that has to
decide, without one, whether a night went red and what to say about it.

One JSON object, one line, `.log` like every other artifact so the same scans
select it. Its field set is an **allowlist**, pinned by equality as
`verdict::VERDICT_KEYS` and asserted in `tooling/soak/tests/verdict_fields.rs`:

```
profile  seed  schedule_tag  commit  rustc  rc  rc_name
scenario  arm  invariant  tick  bound_secs  observed_secs  finding_class  handles[]
```

A clean run carries the first seven and **no violation field at all**, so "is
there a finding here?" is answerable without a rule. `invariant` is absent from a
violation too when what broke was the arm's own expectation floor rather than one
of the registry's promises, because a borrowed id would make a reader group a
floor with an oracle.

**Why an allowlist and not a re-scan.** A scanner finds what it was told to look
for. Re-scanning a composed issue body catches a structural shape — a long hex
run, a coordinate, an endpoint — and provably **cannot** catch an undeclared
value such as a petname or a display name, because nothing declared it. So the
guarantee is that no field CAN carry one: every value is a repository fact, a
literal from one of the crate's closed vocabularies, a delta, a duration, or one
of the rig's own handles. The scan over the tree stays, as the backstop.

**`finding_class` and `handles[]` are separate fields**, never the rendered
finding sentence: a reader outside the process needs a classification it can
group by and a handle list it can bound, and the sentence's shape is not pinned.

**The two free-form fields are validated ON WRITE** as well as by whatever reads
the file — `handles[]` element-wise against the rig's own handle vocabulary,
`invariant` against the CLOSED set of ids the oracle registry mints rather than
against the `INV-` shape, since `INV-` plus an upper-case run also describes an
event id. A verdict that fails either check is **not written at all**: an absent
file reads as "no verdict", which a reader already has a branch for, while a
written one would be published as validated. Dropping it costs the run nothing
else — its own exit code is still its verdict, and the driver does not turn a
refused verdict into a rig fault.

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
scheduler seed is public repository metadata, and the `pr` seed is the
`DEFAULT_SEED` constant in `tooling/soak/src/main.rs`: the PR lane passes no
`--seed` and no profile TOML carries a seed at all, so a PR run is reproducible
from the repository alone. Neither identifies a user, a circle or a device: they
identify a SHAPE, and that shape is in the repo.

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
| `scripts/ci/check_no_kp_lifetime_override.sh` | No shipped Rust path (`haven-core/src`, `haven/rust_builder/src`, comments included) names `key_package_lifetime`: S12's `kp-expired-rejected` sets the lifetime on purpose, and the same call in the product could lengthen `not_after` past the rotation (OD-8) |
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
