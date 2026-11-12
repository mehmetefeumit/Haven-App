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
  with `profile: pr`, `needs: [rust-tooling]`.
- The scheduler: `.github/workflows/soak-nightly.yml` (`Soak Nightly`), which
  calls the same lane with `profile: nightly` on four matrix slots, 00:23 UTC
  Monday to Saturday, each slot with its own seed from `scripts/ci/soak_seed.sh`.
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

Six more, specific to this tier and listed here so nobody has to infer them:

* **The KeyPackage plane is DISCOVERY-free.** A world's members are still
  invited from key packages minted in process and handed to `create_circle` as
  values, and no NIP-65 (kind 10002) list is read. One lookup exists: S26's
  invite lookup of each member's own key package on the member's own
  key-package relay, which is what that relay holds — the discovery plane a
  lookup falls back to is a loopback port that refuses every dial, held for
  the process's life (`rig/world.rs` `install_process_globals`), so no soak
  world can reach a public indexer.
  What S12's `kp-rotation-slot` adds is the other half — a real 30443 staged
  through the engine's lifecycle record, published into a real slot on a real
  plane, read back from the plane's own store, and the rotation decision taken
  against the package's own MLS lifetime. It opens on the package the
  world-building join CONSUMED and requires a replacement into the same slot,
  requires a heal to put the same event on the plane byte for byte, and
  requires a tracked package whose private bundle is gone to be replaced
  rather than re-advertised. Green
  therefore says nothing about KeyPackage *discovery*, and it does say that the
  rotation policy, the two replacements no clock decides, the stable slot, the
  frozen event and the monotonic replacement stamp behave
  over a relay — but only where S12 RUNS, which is not the PR lane: it is a
  nightly scenario, so a green PR lane says nothing about it and only a
  scheduled night does. `kp_rotation_e2e` still
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
  recipe's evidence is the plane's ledger rather than the client:
  `nostr-relay-pool` drops an already-expired event before it emits any
  notification, which S09's `past-expiration-dropped-by-the-relay-pool` arm
  records as an expectation. Haven itself does not screen on `expiration`
  (receivers must not judge validity by it, Marmot `transports/nostr.md:190-192`),
  so S09's classification half hands the expired forgery to the processor,
  which refuses it on its content, and `member-commit-past-expiration-applied`
  hands every co-member a member's genuine commit stamped with a past
  `expiration`, which each applies. A *stored* event that expires later is a
  different case and is not graded.
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
* **The Bluetooth radio is a double, and its clock is a number.** S27 and S28
  run the product's own mesh engines, one a device, and the product's own
  hand-off, mesh drive, mesh-only seal and bridge. What carries frames between
  two engines is the rig (`rig/mesh.rs`): a scenario says which devices are in
  range, every frame an engine hands its radio reaches the peer at once and
  whole, and the engines' clock is stepped, never read. Green therefore says
  nothing about Bluetooth — advertising, connection limits, loss, throughput,
  a platform's background rules — nor about the app's own engine home
  (`with_mesh` in the bridge, its sleep-counting clock and its twelve-hour
  deadline), which the rig mirrors by rule and does not run. The offline
  member of S28 is offline by a refusing endpoint and an engine never told of
  the circle, not by a socket that is gone.
* **A `{:?}` of a value bound to a local name is outside the source guard.**
  `check_soak_test_only.sh` check 5 bans the Debug format family over any
  `haven_core`/`cgka`/`nostr`/`openmls` value, matched per invocation. A
  foreign value assigned to a local binding on one line and formatted on
  another is not seen. The rig's crate-local `Debug` test covers what the rig
  itself defines; nothing covers the third case but review.

---

## Which safety invariants the rig actually grades

PLAN §2.1 lists nine. The rig grades **S1, S2, S5, S7 and S8**, partially grades
**S3**, **S4** (its routing half, by O7) and **S6** (S6's advance side only — its
hold-back side is still structural), and grades **S9** not at all. Spelled out, so a reader of the green tick
knows what it covered:

| # | PLAN §2.1 invariant | Graded? |
|---|---|---|
| S1 | Single branch (current-epoch cross-decrypt both ways, round-unique payloads) | **GRADED** — oracle O1, round-unique payloads. Both directions where it matters: every scenario's CLOSING round probes each chain pair BOTH ways, with the device that was restarted, reopened or resumed sending FIRST (a rebuilt epoch or exporter is invisible to the device itself and shows only as a peer failing to decrypt what it produced), and the nemesis phase's teardown round sweeps every ordered pair. Intermediate rounds stay one-directional over a spanning chain, which is the cost trade `Reach::These` exists for |
| S2 | Post-removal unreadability | **GRADED** — oracle O3 (`RemovalUnreadability`), produced by S21's two O3 arms, graded APART because the delivery paths prove different things. `removal-delivered-commit` delivers the commit and asserts every later 445 is `Stale{SelfEvicted}` carrying no token: the BOOKKEEPING gate (MDK's `!is_active()`), and nothing about key material. `removal-withheld-commit` holds the commit back (`DropClass::Handshake` on the evictee's endpoint for the whole arm) so the evictee's group stays active and the peel is genuinely attempted, and asserts every post-removal probe is `Stale{PeelFailed}` carrying no token, with a stored row that NEVER resolves (read terminally after the closing round). O3 does NOT grade the RFC 9420 §12.4 forward-secrecy property (a Remove's `UpdatePath` blanks the leaf): that is openmls's, tested upstream, and is unreachable from Haven's code — an evictee that never received the commit has no epoch-N+1 exporter secret whether or not the `UpdatePath` was correct, so `PeelFailed` on the withheld path cannot distinguish a broken Remove. §12.4 is the basis O3 relies on, never what the soak measures |
| S3 | Publish-before-apply (Rule 13) | **PARTIAL** — per COMMIT, not per transition. Every commit the rig makes is staged, sent, confirmed and rolled back by the PRODUCT's durable-fanout driver (`haven_core::relay::fanout::Publishing`, wrapped as `rig::circle::DeviceDriver`; the world's `change`, `resume`, `leave`, `ingest`, `seal_fix` and `publish_location` are its entries), built as the bridge builds its own — the `Claimed` mode a caller's word and the live plane's standing make, under the bridge's `RESUME_BUDGET_MS` budget, every engine claiming the foreground once started (pinned beside the bridge's in `haven-core/tests/security_rule_gates.rs`) — so the soak grades the shipped publish path; the rig resolves no pending state itself (`check_e2e_publish_before_apply.sh` check 2). S18's five arms assert the gap from both sides (stored HERE, unacknowledged THERE): the commit stays pending, the SAME bytes are sent again on the relay's schedule and confirmed on the acknowledgement that reaches the device, the circle converges with its peers paused or online, a location is deferred while the commit is pending and resumes after it, and a location's application fanout ends with its one offer; the rebind counters show no socket went away while the ack was withheld. Three more arms reach the same rule from other sides: S05's `confirm-err-is-not-a-failure` (W9f: a failed confirm of an acknowledged commit is decided by the stored record, never rolled back, and confirmed by the next drive), and S22's `oversized-commit` and `oversized-removal-wedges-the-circle` (a refusal the publisher hears is rolled back by the driver; for a removal the engine re-arms it). What is NOT graded is the universal form — "every observed epoch transition has a stored, acked commit" — because no oracle walks the ledger against the epoch history. That walk needs a per-transition record the Phase-1 ledger does not keep |
| S4 | Nothing identifying on the wire | **PARTIAL — the ROUTING half GRADED by O7** (`RelayPlaneContainment`, `oracle/planes.rs`): which relay each verb, kind and filter reaches, per circle, recipient and account, after every arm and after the nemesis phase, by the relay-plane judge every layer of the proof shares (see "Relay-plane containment (O7)" below). The CONTENT half — an identifying byte inside a frame — is not graded here; the e2e lanes' wire oracles (`check-wire-journal.sh` and friends) own it |
| S5 | Retention window (5 past epochs) | **GRADED** — O4, over BOTH edges, produced by S04's `offline-past-retention`: one ciphertext sealed exactly `DEFAULT_MAX_PAST_EPOCHS` advances below the reader's tip still decrypts, and one a single epoch older does not. The window is READ from the engine at runtime, never restated, and each edge's distance is MEASURED from the epochs the run really reached — a world that did not reach the intended shape answers "this proved nothing" (one side of the window fed twice) rather than reporting a violation the arm manufactured. What it adds over `haven-core`'s own `rule5_retention_constants_are_pinned` and `rule5_epoch_n_ciphertext_still_decrypts_at_the_window_edge` is those two edges over a real relay and a real live plane, across a pause and a catch-up — and nothing else |
| S6 | Cursor integrity | **PARTIAL — the ADVANCE side only.** S09's first two arms grade what an adversary can and cannot do to a persisted anchor (its other two grade the NIP-40 `expiration`: a member's commit stamped past it is applied, and the relay pool's own drop is recorded). The first is a standing outsider forging at the circle's public `#h` every round for the whole arm — three recipes per round, expired, doubled `#h` and undecodable — which moves neither `read_sync_cursor` nor `read_backfill_floor`, while a legitimate fix delivered in the SAME round proves the plane was carrying anything at all, and a catch-up sweep that still advances locally is the control that keeps the whole arm from being satisfied by a build where advance had been deleted. The second injects ONE forgery, after the original it copies has been folded: an observed ciphertext re-signed a day ahead, which applies nothing a second time and moves neither anchor. And the catch-up sweep's own advance is required to land inside a bracket taken from the same wall clock the sweep opens its window with, which is the advance's PROVENANCE rather than its arithmetic and which a forged `created_at` a day ahead could not satisfy. **The HOLD-BACK side is still structural only, and the reason is measured, not assumed:** reading it needs an event that is DELIVERED and un-applied while a subscription generation is open, and at this pin the rig cannot produce one — a message sealed at an epoch the receiver has not reached peel-fails (the kind-445 outer layer is keyed by the sender's epoch exporter), and the buffering outcome the engine does produce (the publish-before-apply transition, which S19's `commit-gap` arm grades) leaves no gating row, its delivery landing only once the transition ENDS, on the confirm's own replay, which is not a window a cursor is read against. `haven-core`'s own anchor tests still cover the hold-back. S25 grades the advance's other edge, over a dead and an EOSE-silent relay: the cursor advances once the backlog wait is over, never before the silent relay's wait ends, and the fix only the dead relay held still arrives from the floor that relay owes (Rule 12) |
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

## Circles start settled: the post-join self-update is made at build

Every joiner of a circle the rig builds (`rig/circle.rs` `build_circle`) makes
the one post-join self-update MDK records at its join, through the product's
own full resume (`Publishing::resume`, never a direct call — the
`check_self_update_sites.sh` guard holds that to `Publishing::post_join`) over
a transport on which every relay accepts and nothing is stored
(`CircleManager::resume_accepted_for_test`), and every other device takes the
commit in before the circle's origin epoch is read. No plane therefore holds
a commit the build made: a live REQ opened at the engines' start replays
nothing, and an arm that counts the commits on a relay counts only its own.
A circle an arm builds beside running engines can have a founding Welcome
taken from its record by the admin's live plane before the create's own drive
reaches it; the rig then takes that Welcome from the invitee's inbox — the
one wrap that was not there before the create — and accepts it, and the
create is reported unacknowledged only when no Welcome reached anyone. MDK's windows (15 s grace, 60 s quiet, up to 30 s jitter) are served on
the joiner's injectable session clock, set a day ahead for that one drive and
given back after it; when an earlier circle's post-join on the same device
still spaces this one, the drive runs at the instant the session names. No scenario's measured phase therefore meets a joiner's
first caught-up foreground drive making a commit, and no oracle changed for it.
A circle that stalls (S03's lost commit is the shape) now also exercises the
epoch-stall detector: an arm owes the circle a walk of its own history, which
the next foreground sweep makes.

## Which scenarios have lane execution, and where

Twenty-six scenarios exist: **S01, S02, S03, S04, S05, S06, S08, S09, S10, S11,
S12, S13, S14, S16, S17, S18, S19, S20, S21, S22, S23, S24, S25, S26, S27,
S28**.

* `pr` (the profile `ci.yml` calls on every push) runs **S01's single-relay
  outage arm, S06, S11, S13, and the Bluetooth mesh's S27 and S28**.
* `nightly` runs every other nightly arm — **S02, S03, S04, S05, S08, S09, S10,
  S12, S14, S16, S17, S18, S19, S20, S21, S22, S23, S24 and S26** beside the PR set (S05
  without `kill-receive-auto-commit`, S03 without `lost-commit-unnamed`, S17
  without `full-intake`) — and has LANE execution
  in `soak-nightly.yml` alone: its schedule, four slots a night Monday to
  Saturday, or a dispatch of it; never on a pull request.
* `weekly`'s own arms have **NO lane execution** until Phase 4 adds
  `soak-weekly.yml`; `soak-core.yml` carries the weekly job so there is
  something to call, and nothing calls it. They are S03's
  `lost-commit-unnamed` and S17's `full-intake` — outside the crate's own
  sweep, because their bounds start at the 684-second silence window, so they
  run under `scripts/run_soak_local.sh core --profile weekly` alone — and S05
  `kill-receive-auto-commit`, swept since MDK v0.10.4 and held out of the
  nightly until the owner returns it, and S25's `dead-and-silent-relays`,
  swept by the crate's own tests and out of the nightly by price. None has
  scheduled execution until then.

A green `soak-core-pr` therefore says nothing about a receiver partitioned
behind a second publisher (S02), a commit a relay forgot before a paused member
returned (S03), the member-absence spans and
the retention window (S04), the publish→confirm window (S05), a commit
buried past a relay's replay cap, recovered over NIP-77 and stranded without
it, and the live plane serving one under a page of forgeries (S08), the
cursor-poisoning adversary, the two anchors and the `expiration` that is not a
validity signal (S09), the ten-circle roster
under one outage (S10), the KeyPackage rotation slot (S12), a same-epoch commit
race (S14), the three durable stores a flood can grow and the one ordinary
traffic grows without bound (S16), the CLOSED-prefix
behaviour (S17), the five swallowed-OK Rule-13 arms (S18), duplicate/reorder
delivery and the commit-gap fold (S19), the catch-up sweep under clamped,
refused, cold and forged pages and a same-second pile-up (S20), post-removal unreadability and the
removal lag (S21), the oversized commit, Welcome and removal wedge (S22), the
chained-commit backlog (S23), two circles sharing one routing id (S24) or the
identity planes under a downed profile relay (S26)
beyond what a unit test proves — those are the
nightly's, and only a night's verdict speaks for them. No arm is expected red
since R4's NIP-77 pass fixed the burial past the replay cap on relays that
speak NIP-77 (S08, C8).

### The first recorded expectation, and what makes it stale

S14's `race-anchor-exhausted` asserts a KNOWN-BAD outcome rather than grading
it. Two devices commit from one epoch, each walks its own branch past
`max_rewind_commits` (read from the policy the session installs, never
restated), and neither can converge the other's sibling afterwards. What is left
is a **twin fork**: both devices report the same epoch, the same roster and a
healthy send path, and only a bidirectional cross-decrypt says otherwise.

*At this commit neither `unrecoverable_circles()` nor the bus names that state.* The arm
asserts the fork AND the silence — `unrecoverable_circles()` empty, no
`GroupUnrecoverable` on either device's bus — as its expectation, so both
directions are covered: if the fork stops happening, the canary is unmet and the
arm is **rc 3**, "the recorded expectation is stale"; if a verdict starts
appearing, the silence canary is unmet and it is **rc 3** again, which is the
correct signal — the recorded expectation must be replaced by a graded one in
the same commit. Changing it in either direction without citing OD-1 (BUILT in the
MDK v0.10.4 migration: one per-circle card in the circle's details sheet, read
from haven-core's `circle_recovery`, which no arm reads yet) is a regression.
The 684-second form of that silence is asserted by S03's weekly arm
`lost-commit-unnamed` (below); a second eleven-minute absence here would buy no
further claim, which is why every arm in that scenario declares no absence
window at all.

The scenario's other three arms assert the opposite and GRADE it: a race that
does not converge is a finding about the subject, reported as
`branch-diverged` / `epoch-diverged` / `roster-diverged` at rc 1, never as a
floor that went unmet.

### The second recorded expectation: a removal commit no relay will take

S22's `oversized-removal-wedges-the-circle` is the same shape for a different
gap. A peer proposes its own removal, this device's engine stages the eviction
commit under its record, and every plane refuses it for its size. Which shape
the product then takes is a property of the relays, and the arm MEASURES it off
the rig's own: the relay double answers an oversized frame `OK false invalid:`
(`relay/policies.rs` `OVERSIZE_PREFIX`), a machine-readable rejection. Measured
(2026-10-18): every target proved it refused and none may hold the commit, so the
product's driver ROLLS THE EVICTION BACK; the engine arms the eviction again;
from the refusal until the eviction lands the circle sends nothing — every
location is deferred, typed `DepartureDue` inside Haven's refused-eviction wait
(`RESTAGE_BASE_MS`, doubling to `RETRY_MAX_MS`), and deferred after it — past the wait
by MDK's preflight making the eviction again, which every plane refuses again;
the hold alone covers at most the 50 ms of monotonic time before MDK's re-armed
deadline — while receiving
goes on; the evictee stays in every remaining member's roster; and the circle
is never held in a publish-before-apply transition. (A relay that dropped the frame
with no answer would take the other shape — possibly exposed, so pending with
paced retries and the circle's sends waiting behind it. The rig's relays do not
produce it; tracker row T-OQA records which shape was measured.) The removal
can never land, because every retry is refused for the same reason.

*At this commit no terminal verdict names that state either.* The arm asserts
the whole of it as its expectation — the machine-readable refusal; the rollback,
with no pending record and no publish-before-apply transition, and the re-armed
eviction; the evictee still in the roster of the member that never saw a commit;
a location deferred `DepartureDue` inside the refusal's wait and deferred after
it (which deferral then depends on whether MDK's 10–50 ms re-arm has passed);
`unrecoverable_circles()` empty with no `GroupUnrecoverable` on any bus — paired
with its own control: the arm then lifts the cap, and the product stages the
re-armed eviction again and lands it. That release is what keeps the canaries
from being satisfied by a world in which nothing can be published at all. A
real oversized removal has no such release, and that permanence is the whole of
OQ-A. Both directions are covered exactly as S14's are: if the shape changes the
canary is unmet and the arm is **rc 3**, "the recorded expectation is stale"; if
a verdict starts appearing the silence canary is unmet and it is **rc 3** again,
because the recorded expectation must then be replaced by a graded one in the
same commit. Changing it in either direction without citing OD-1 (BUILT — one
per-circle card in the circle's details sheet, read from `circle_recovery`, which
no arm reads yet) and owner
decision OQ-A (name the state as its own cause, because its remedy differs: the
user cannot retry, and a banner offering "retry" would offer something that can
never succeed) is a regression. The state keeps its existing neutral wording
until W9r names it.

The circle it uses is built with `build_extra_circle` and is deliberately
outside `world.circles()`: a circle whose sends wait on a refused eviction may
not be one a world-wide oracle grades, and that is also why the arm declares
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

*At this commit no terminal verdict names a device stranded behind a lost
commit. This arm asserts that silence. OD-1 is BUILT — one per-circle card
inside the circle's details sheet, read from `circle_recovery`, whose `Stalled`
cause is the epoch-stall detector's for this shape — and no arm reads
`circle_recovery` yet. When one does, this arm's absence assertion becomes a
presence assertion within `silence_window()`; changing it in either direction
without citing OD-1 is a regression.* The silence is read on the surfaces the
rig reads: `unrecoverable_circles()` empty on every device, no
`GroupUnrecoverable` on any bus, and the circle-health row readable and
carrying no peer-event stamp — that stamp is the app layer's
(`CircleManagerFfi::note_peer_event`), so at this tier the health row records
nothing about the strand.

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
during the partition" is NOT asserted: it needs the TTL horizon, and expiry is
judged on WALL clocks — the relay double and `nostr-relay-pool` — on the wall
side of the rig's clock partition, so no
policy step can age an event into it — stepping the policy clock to reach it
is exactly what `check_soak_clock_partition.sh` catches. The forged-expiry
vector is S09's. A scenario that partitions an engine endpoint must also run no
catch-up sweep while the partition stands: the sweep dials the plane's
canonical endpoint for every circle and would heal it by the other path.

### What the crate's own tests run instead, and how much of it

`tests/oracles.rs` runs **every registered arm** as its own test — all
seventy but the two excluded — rather
than one "smallest arm" per scenario. That
distinction is the whole point: an ordering over arms tie-breaks positionally,
and the version that ordered by derived deadline left most of the registry with
no success path anywhere, including BOTH of the Rule-13 arms S18 exists for. The
two exclusions are S03's `lost-commit-unnamed` and S17's `full-intake`, whose
bounds each start at the 684-second delivery-silence window, and
`the_happy_path_sweep_runs_every_arm_but_the_one_it_excludes` asserts that the
excluded set is exactly those two arms — so a new arm cannot join it silently.

Beside the sweep there is **one deliberate mis-configuration control per
scenario**, twenty-six in all, each running the real arm against a world arranged
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
a store with no backlog for a catch-up sweep to drain, a seed the relay serves whole so no commit is buried under it, a closed endpoint with nothing to duplicate, relays that all answer so nothing holds a circle or is owed, and mesh devices out of radio range of each other so nothing is read from the mesh — each requiring the verdict to be
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

### S23: promoted with C7's fix

S23's `chained-commit-backlog` grades C7 (`docs/BACKGROUND_SHARING_FAILURE_ANALYSIS.md`).
A member is paused across TWO confirmed commits and served them newest-first
when it resumes. The page order is pinned: the arm waits out the wall second
between the commits, reading it back off the relay's own store, so the shape is
the same every night and never a coin toss on event-id order. The newer commit
cannot peel until the older one is applied, so the engine retains it as a
`PeelDeferred` row. MDK v0.9.4 retried such a row only inside an advance, and
scheduled none for it.

Until 2026-09-28 the arm was REQUIRED to be red. The device sat one epoch below
its peers, three further fixes from the committer did not move it, and the
closing round reported `epoch-diverged` (O2) and `probe-not-delivered` towards
the victim (O1) at rc 1. The only thing that drained it was the device's own
next seal, whose send-path settle reaches the deferred-peel sweep. So a device
that received without sending stayed stranded indefinitely. Haven's fix drains
the row without waiting for a send. An epoch change in any engine batch leaves
its group owing an advance, and the first receive plane of a newly opened
session advances every circle once. That fix is a Haven-side mitigation of an
MDK gap, tracked as row C7 of `docs/MDK_UPSTREAM_TRACKER.md`. Upstream, MDK PR
#1206 (first in v0.9.11) adds deferral- and hydrate-scheduling, which may cover
C7 — unverified; no upstream issue describes the epoch-change edge. The row's
removal condition is this arm staying green with the Haven drain removed, and
an MDK issue is to be filed for the epoch-change edge if it does not.

Since 2026-10-25 (R2) the second Haven edge is replaced: the first plane of a
session — the live engine's start or any catch-up sweep, a
`HAVEN_LIVE_SYNC=false` build's included — drains the engine's own pending set
in place of advancing every circle (tracker rows C7, T-SCHEDULER), and the
end-of-migration S23 nightly decides whether that stands — if it is red, the
edge is restored. The epoch-change edge is kept: with Haven's in-plane serving
dropped this arm still converged, on the deferred-peel sweep MDK retries inside
the advance that settled a pass (mdk#1206), so no run shows that edge needed —
which proves only that no test sees it go, not that removing it is safe.

The arm now grades rc 0 and is `SWEPT` in `tests/oracles.rs`
(`s23_chained_commit_backlog_holds`). It returned to the nightly in the same
change, as the promotion rule required. The closing round keeps its shape: the
witness leads, so the victim's first probe is a receive, and the victim's own
seal is recorded after the grade, as the last canary. That seal therefore
cannot stand in for the receive-side drain. If the drain regresses, O2 and O1
report it at rc 1 again. Its mis-configuration control
(`s23_one_commit_while_away_is_not_a_chained_backlog`) runs the arm over ONE
commit. A single commit is redelivered and applied on its own, so the chain the
floor demands never forms, and the control reports rc 3 with
`FloorUnmet(EpochsCrossed)`.

### S24: two circles on distinct relays share one routing id

S24's `collided-circles-leave-apart` builds two circles outside the world's
table, each on a plane of its own (`build_extra_circle_on`), and makes the
admin commit a routing update that moves one onto the other's routing id, its
relays unchanged — what another client's admin can do and Haven never does:
the routing component is encoded in the rig (`cgka-traits`, pinned as
`cgka-engine` is), staged through the session under its durable record, and
sent and confirmed by the product's driver; every other member takes the
commit in through the poll. It grades the promise tracker row
T-ROUTING-ROTATION records, over real relays: neither circle is sealed for on
the admin or on a member (`held-circle-sealed`), before the leaves and after
the admin's hand-over — a commit in one of the two, after which MDK may route
the shared id to it again — and every event of the member's leave of one
circle and of the admin's leave of the other (hand-over and proposal) reaches
that circle's own plane and never the other's (`circle-traffic-crossed`,
read off each plane's ledger and store, for every event the arm's drivers
sent, recorded or not), and every handshake either plane holds under the
shared id is one the arm sent for that plane's own circle — one sent for the
other circle is `circle-traffic-crossed`, one sent for neither is Haven
making something for a held circle unasked (`unasked-handshake`). Its canaries are the collision's
conditions — both devices route the moved circle by the other's id, the two
circles name no relay in common — and the two leaves' own: the member's
proposed and on its circle's plane, the admin's handed over (that circle's
epoch moved) and proposed. Its control makes no routing update, so nothing is
held: rc 3. It needs two relays, which `nightly` and `weekly` have.

What it does not soak: an eviction made under two rows. The wake sweep makes
no commit since W9q, and every other plane makes a commit only under a record
whose targets the circle's routing names, so a collided circle — whose sends
are all held — has no eviction to make (protocol F8a).

### S25: a relay that never answers and one that never ends its replay

S25's `dead-and-silent-relays` grades the owner's P2 decision over real relays:
a dead or silent relay does not stall a circle, and Security Rule 12 is kept
while it does not. Plane 0 is the dead relay, plane 1 the silent one; any
further plane answers throughout. The receiver pauses and resumes around each
phase, and each fix is stored on ONE plane through that plane's own store while
it is paused, so which fix arrives says which relay answered.

1. **The dead relay alone** (`unanswering`: every live connection cut, every
   later one accepted and its handshake never answered). The resume's backlog
   wait answers settled — it waits on no relay, group or inbox, that was not
   connected when it took the REQ — and the circle is caught up with its cursor
   advanced (`silent-relay-stalled` otherwise); every fix an answering relay
   held arrives (`held-event-lost`).
2. **The lookback passes** (`Absence::ResubscribeLookback`) and one more resume
   re-anchors past it: from then on a REQ's ordinary `since` no longer reaches
   the fix only the dead relay holds, and only the floor that relay owes
   (`relay_floors`) does.
3. **The silent relay too** (`withhold-eose`: every page served, its `EOSE`
   never sent). It holds the circle until the backlog wait is over — read
   before the wait, which is the only thing in the arm that can release it —
   and not after: caught up, advanced, every answering relay's fix arrived.
4. **Health ticks**: the dead relay is taken `down`, so the receiver's pool
   holds it dropped, and three claimed ticks re-issue no REQ on any plane
   (`resubscribe-unbounded`).
5. **The heal**: inside the pool's reconnect bound the dead relay is asked from
   its floor, gives up the fix only it held (`held-event-lost` otherwise) and
   its `EOSE` ends what it owed.

Its canaries are the faults' conditions: the dead plane held a connection
unanswered, the silent plane kept an `EOSE` from a client and that `EOSE` held
the circle until the wait, the receiver's pool held the dead relay dropped
before the ticks, both relays left out owed the circle a floor, and the dead
relay's floor ended. Its control arms no fault: rc 3. The arm found one gap
itself on its first run: an inbox REQ the pool only queued for a dead relay
kept every resume waiting the whole backlog window
(`a_resume_waits_on_no_inbox_relay_that_is_not_connected`, fixed). Each of
these is RED under the matching product mutation: no release past the wait, a
queued relay counted as covering, a dropped relay re-anchoring the session, the
floor ignored by the next REQ, the inbox's queued relay waited on. It needs two
relays (three to include an answering one, which the crate's own sweep and
`weekly` give it), and it is `weekly`-only: its derived deadline pays the
pool's reconnect ladder and the lookback, which the nightly's slack does not
hold.

### S27: one script, the mesh off and then on (T-INDEP-1a)

S27's `mesh-off-then-on` grades the Bluetooth mesh's independence promise
(`docs/BLUETOOTH_MESH_PLAN.md` §9.3) as far as a relay's own record can show
it: with the mesh on, a device sends a relay the frames it sends with it off.
One script runs twice in one world — the mesh off, then on with every device
in radio range of every other — and the two passes are compared:

* per device, the multiset of the `EVENT` frames it sent a relay, each as
  (plane, kind, tag names, `expiration − created_at`, what the relay answered
  that device's endpoint, how many times it was sent — a frame repeated on
  one connection is one entry of the plane record and two in this count);
* per endpoint of every plane, the canonical endpoint included, how many
  `REQ`, `CLOSE`, `NEG-OPEN` and other frames it carried — and, on the
  canonical endpoint, how many `EVENT`s;
* the answer of every seal and every send, in order.

And inside the mesh-on pass: a mesh drive (`Publishing::mesh_drive`) asks its
transport to send nothing and leaves every circle's cursor and backfill floor
where they were, and a device reads from the mesh only an update whose
send-time check passed.

Any difference is `relay-path-moved`, at rc 1, naming the device whose
endpoint it was or the canonical one. O7 grades every frame of both passes
as it does for every arm. Two things differ by design and are counted apart:
the seal made for the mesh alone (`Publishing::seal_for_mesh`: nothing is
sealed with the mesh off, no relay is handed it with it on), and the one
update a device passes on to the relay, in one frame a relay — any other
frame carrying an event its sender did not seal, and a second frame of that
one, is a finding.

The script: every device seals and sends, each send read by every peer's live
plane before the mesh carries anything, so the mesh's copy is a duplicate and
nothing is passed on; one device's own endpoint then refuses its events
(`refuse-oversize`, no socket closed), it seals and sends, its peers read the
update from the mesh alone and the next device to send passes it on; a device
seals for the mesh alone; a device sends a location a whole life after
sealing it — expired, not sent, and never handed to the mesh; one more send
passes nothing on.

**The windows.** The mark before each pass is taken on a still wire, read as
O6 reads its fingerprint: no endpoint of any plane carrying a new client
frame across three observations a tick apart. A foreground entry's NIP-77
pass ends in the engine before its last frame has left, and stillness is a
condition every end of a session reaches: one the pool finished has its
`NEG-CLOSE` written, one a relay was too slow for or refused sends nothing
more. (A count of `NEG-OPEN`s against `NEG-CLOSE`s is not such a condition:
`nostr-relay-pool` 0.44.3 closes only a session it finished, which
`tests/relay_faults.rs` pins.) Stillness seen is an observation and no
guarantee: a frame a device held back for longer than two ticks would fall
in the wrong pass and read as a moved path. The two passes share one
instant, so every frame after the first mark is in exactly one of them, and
the last mark is taken behind the closing round's settle, so what a device
still had to send when the script ended is counted.

Its six canaries: frames crossed links; a peer read the refused update from
the mesh; that update was passed on; a location was sealed for the mesh
alone; the refusing endpoint refused in both passes; and no wait of the arm
ran out. One control puts no device in range of another, one runs the arm as
after a setting-up wait that ran out: rc 3 each.

**What it does not compare.** The order of a device's frames and when each
was sent; a connection that is opened and carries no frame; and anything
about a frame but its shape — another `created_at`, another routing id or
another filter under the same verb compare equal. Nor a NIP-77 session's
course after its opening — its `NEG-MSG`s and its `NEG-CLOSE`: how many
messages a session takes is the relay's answer, and whether it is closed or
given up is how fast the relay was, so neither is the same from one pass to
the next for any reason of the mesh's. That a session was opened is compared.
`haven-core`'s T-INDEP-1b and the wire lanes hold what a frame says. It is not two runs of a profile
either: an arm has one world, so the passes share its circles, relays and
sessions, the mesh-off pass first.

### S28: member bridging end to end (T-BRIDGE-9)

S28 grades the bridge (plan §5.5) over real relays, in a circle built outside
the world's table. Three members have a part: one offline and on mesh — its
own endpoint refuses its events and its engine is never told of the circle,
so no relay takes anything from it or tells it anything; one online and in
its radio range; one far away, with a relay and no mesh. In the nightly's and
the weekly's worlds the circle has every device of the world in it, four or
five; the others' engines are never told of it.

* `bridged-to-the-far-member`. First the online member sends in a drive whose
  caller says its relay receive had NOT completed (`received = false`): the
  relay takes its own send, and nothing of the offline member's reaches the
  relay then or later. Then, for the offline member's next update, a drive
  whose receive completed: the update is passed on once a relay, byte for
  byte, and the far member's live plane delivers it. An update at a relay
  past the first gate, passed on twice or altered is `bridged-past-its-gate`;
  one passed on and never delivered is `probe-not-delivered`.
* `removed-member-finds-nothing`. The online member removes the far one. The
  offline member never hears of it and seals its next update at the epoch
  the removed member can still read; the online member reads it from the
  mesh and sends with its receive completed. Nothing of the offline member's
  reaches the relay: not its store, not the online member's transport, and
  not the removed member's own view — every kind 445 the relay serves it for
  the circle's routing id, which does show the online member's own
  post-removal send (`bridged-past-its-gate` otherwise).

Each arm's five canaries are the premises of what it grades: every wait of
the setting-up ended in time — each foreground entry's pass, the bridger's
catching up — with mesh on and frames across the link; the offline member's own sends
refused; the update read from the mesh by the bridger AND kept by its session
to be passed on (`mesh_bridge_waiting_for_test`) before each send that must
pass nothing on — a bridger that kept nothing would pass nothing on whatever
its gates did, so that run is rc 3, never clean; the bridger's own send taken
by a relay; and, for the removal, that it stands on the bridger while the
offline member's epoch has not moved, and that the removed member's view
reaches the relay. One control puts the two mesh members out of range, one
runs the first arm as after a setting-up wait that ran out: rc 3 each.

**What it does not soak.** With three devices the bridger is also the
remover, so it knows of the removal from its own commit; a bridger that has
not yet fetched a removal another member made is the first arm's unreceived
drive, and `haven-core`'s T-BRIDGE-10. The bridge's 218-second window, its
72-second spacing per member and its per-drive bounds are wall-clock terms
the arms never reach (`mesh_bridge_e2e` holds them).

### What the three mesh arms cost, and what a seed does

**One wait may run out.** Each arm's own waits — its foreground entries'
passes, S27's still wire, S28's bridger catching up, every delivery it
depends on — are each bounded by a round trip and share one allowance
(`scenarios::Allowance`): after the first that runs out the arm has no bound
left to wait with, and makes no further wait. So each arm is priced at the
closing round and one more round trip (`probe_rounds: 2`, 39.75 s), and
`tests/oracles.rs` holds the price: in a world whose relays deliver no
location to anybody, each arm reports the undelivered location inside its
derived bound. A wait that ends in time is not priced, for these arms as for
every other.

**Which wait it was decides what the run says.** A wait that was not made
grades nothing. A delivery that was waited for and never came is
`probe-not-delivered`, rc 1. A wait of the setting-up that ran out is not a
finding of these arms': no invariant of theirs is about an entry's pass, and
nothing they grade was then observed, so the canary that requires every wait
to have ended goes unmet and the run is rc 3 — while a device that is really
stuck is still named by the closing round, whose probes and seals are graded
on their own bounds. S27 compares nothing after any wait ran out. Two
controls hold this (`late_setup_control`, rc 3 and no delivery named), and
three tests hold what led to it: after a foreground entry whose NIP-77
sessions no relay answered inside the pool's negotiation wait
(`withhold-negentropy`), each arm holds, rc 0.

**Every shape a lane runs.** `tests/oracles.rs` runs the three arms in the
nightly's and the weekly's worlds as well as the PR's.

**Seeds.** Every mesh engine's generator is seeded from the run's seed, and
`rig/mesh.rs`'s own test shows one seed carry the same frames in the same
order over fixed packets. Inside a world that is not so: each packet wraps a
fresh event under a nonce from the OS generator, and an offer's lifetime is
read from the wall clock. What `tests/oracles.rs` proves of a world is less
and other: each arm, run twice under one seed and once under another, gives
the same verdict and the same digest of every `EVENT` frame sent — nothing a
mesh engine draws reaches a relay.

### S05's receive-plane kill: swept since MDK v0.10.4 (C9)

S05's `kill-receive-auto-commit` subscribes ONE device's live engine to an
extra circle and lets that engine take in a peer's published leave inside a
background burst, which makes nothing of it: the eviction comes due and stays
due — nothing staged, nothing owed, nothing on the wire (canary 1). The
foreground open that follows makes it: the session's own drive records the
eviction and sends it into an `OK` the device's own endpoint swallows, and the
device is hard-killed with that call out and reopened (canary 3). The record
outlives the process: the reopened device holds the commit staged under it,
is named by no verdict, and a location
asked for meanwhile is deferred, typed; a BACKGROUND BURST then sends the same
event again when its relay is next due — thirty seconds after the cut attempt
— and confirms it on the acknowledgement, in the mode that only finishes
(canary 2 — which also reads that the device is still in that burst when the
confirm lands), after which the circle sends (canary 4). The arm is priced
with `WithheldAcks::FanoutResends(1)`: its bound is derived, the driver's
own thirty-second wait for a silent relay
(`bounds::fanout_resend_after_silence`, haven-core's
`AMBIGUOUS_RETRY_BASE_MS`) and one round trip, not tuned. Two things the arm
is NOT. Its label is historical: no receive path makes that commit any more
— the foreground's drive does — and the label stays because the lane's
guards, profiles and issue keys are written on it. And the burst it opens is
held open past those thirty seconds, which no real burst is: the arm proves
what a burst's drive does when its relay is due, not that one burst lasts
long enough to see it. At MDK `e391adc` it was
REQUIRED red: the reopened device's sends were refused with no typed reason,
and a peer's own commit of the same removal was answered `Buffered` and never
healed it (C9 in `docs/BACKGROUND_SHARING_FAILURE_ANALYSIS.md`); it has been
`SWEPT` since v0.10.4 (`s05_kill_receive_auto_commit_holds`). It stays in
`weekly` rather than returning to the nightly: that is the owner's call (O5),
and its 65.75 s bound no longer fits the nightly's slack, so returning it raises
the budget (`profiles/nightly.toml`). What
the arm does not kill at: the two other boundaries of a finish-only confirm —
after a stored acknowledgement and before the confirm, and after the
confirm's transaction — which haven-core's `finish_only_e2e` and
`stranded_input_e2e` hold on the real engine.

S05's `confirm-err-is-not-a-failure` changed shape with the same bump: the
write fault it plants now aborts an ingest before anything is emitted and
leaves the object recorded as seen (tracker T-FAULTED-INGEST-SEEN), so there is
no stranded batch for the failing confirm to fold. Its fourth canary is now a
RECORDED EXPECTATION that the fix is absent, and its fifth grades the promise
re-authored around v0.10.4's confirm (W9f): the stored record decides, nothing
is rolled back, and the next drive confirms it. The fifth OD4-c gate in
`negative-gates-silent` induces the unprocessable event the same way, because
an envelope nobody can open is the engine's own terminal verdict at v0.10.4.

S05's other two new arms are swept. `kill-send-plane` kills a device between
SEND and confirm of its own relay-list commit (a swallowed `OK`, the commit
stored and unacknowledged, on an extra circle outside the world's table), after the same
update acknowledged has advanced the circle: the reopened device reports
nothing unrecoverable, has no gating row, and sends again (recorded as
`sends-resumed`), and the `Restarted` record carries the C1 release and reopen
latencies. Its control acknowledges the commit, so the kill has no window to
land in: rc 3. `negative-gates-silent` holds one staged eviction — surfaced
through the FFI receive plane and owed, never parked by a burst — and reads the
committer's own live-engine verdict at each of the five OD4-c non-wedge states
in turn — awaiting its own ack, its endpoint dark, its engine paused, a
future-epoch fix from a world circle it missed, an unprocessable event — five
canaries, because one read at the end would pass a verdict that fired and
cleared; it then lands the eviction on an acknowledged publish. Every restart
here is a clean cancel, not a SIGKILL, and the kill kind is not what either kill
arm measures (each doc says why). Measured
2026-09-27 in `cargo test`, three runs each: `kill-send-plane` 44.7 s of wall
(79.75 s of bound; release 21 ms, reopen 174-192 ms), `kill-receive-auto-commit`
about 38 s (79.75 s; release 20-21 ms, reopen 175-190 ms) — re-measured
2026-10-10 as re-authored: about 39 s of wall against a 65.75 s bound —,
`negative-gates-silent` 0.6 s (35.75 s).

### S05's wake-sweep kill: green since W9q (decision 27)

The wake sweep (`run_catchup_all_circles`, the sweep every app wake runs)
makes no commit since W9q: nothing in it can tell a background wake from the
foreground, so it drives in the mode that only finishes. S05's
`kill-sweep-eviction` grades that. The wake is modelled as the background
process it is: the committer's engine is stopped, every other remaining member
is paused so no live plane takes the leave in, and one sweep takes the leave in
under a silence on every plane that would swallow the `OK` of anything it sent.
Canaries are the path's conditions — the sweep left the eviction due, with
nothing staged, recorded or on the relays; the process dead with no engine to
bring back; the foreground back, its engine started and the driver's resume
making the eviction under a record, sent once and acknowledged, and applied —
and every oracle holds (`s05_kill_sweep_eviction_is_green_on_the_driven_path`).
Its control runs the sweep under no silence: the fault the floor counts never
falls, rc 3. Priced `WithheldAcks::None`: the sweep sends nothing into the
silence. Until W9q the arm was EXPECTED RED — the sweep staged and sent the
eviction through the receive ladder under a legacy obligation, and a kill in
that window left it unmade and the committer's next send refused (measured
2026-10-18); it returned to the nightly with the fix.

### S08's live-plane burial (C8), fixed by the NIP-77 pass

S08's `buried-past-the-cap` was REQUIRED to be red until R4. It
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
plane trusts it and the cursor passes the commit. Before R4 neither a second
REQ nor a clean catch-up sweep (every circle swept, nothing truncated, no
deadline, no relay error) asked for it again, and the closing round reported
`epoch-diverged` (O2) and `probe-not-delivered` towards the victim (O1) at
**rc 1**. Since R4 the victim's foreground entry and its sweep reconcile the
circle's window against each relay over NIP-77
(`haven-core/src/relay/negentropy.rs`), advertising nothing, learn the commit's
id the capped page left out and fetch it by id from the relay that reported
it: the arm grades **rc 0**, is swept, and runs in the nightly.

The canaries are the burial's CONDITIONS, never its symptoms — the real
commit, the lookback waited, every store's newest page all forgeries and a full
page served to the victim on every plane, a fresh REQ answered on every plane,
the clean sweep, and (the sixth, since R4) a reconciliation that crossed every
plane — so a product that serves the buried commit grades **rc 0**, not rc 3.
That is how the arm's own test saw C8 fixed: it failed its first assertion with
the promotion rule, and the arm moved to `SWEPT` in the same change. Measured
before R4: feeding the buried commit to the victim after the burial fired
exactly that assertion; with
the seed one second after the commit instead of a lookback after it, the live
page still lacks the commit and the SWEEP recovers it (rc 0) — which is why the
lookback is waited; and a seed of 501 forgeries all inside one second left even
that sweep with two pages of forgeries, no commit and no truncation reported,
which is the sweep's one-second pile-up residual reaching further than
`catchup.rs` says, and why the seed is spread. Its mis-configuration control
runs the arm over a seed BELOW the cap: the commit is on the page, the victim
converges, and the capped-page canary goes unmet — rc 3.

`buried-on-a-relay-without-negentropy` is the strand where the pass cannot
reach, RECORDED: every plane refuses NIP-77 (`Fault::RefusesNegentropy`, the
proxy answering a `NEG-OPEN` with strfry's `NOTICE "ERROR: bad msg: unknown
cmd"` and forwarding nothing; the ledger counts NIP-77 frames per device in
both directions), the burial is on a circle built outside the world's — so the
closing round grades the world's circle — and the victim's strand on that
circle is a canary beside the refusal. The residual is `T-NIP77-FALLBACK` in
`docs/MDK_UPSTREAM_TRACKER.md`; the day a relay without NIP-77 stops stranding,
the arm is rc 3 and is re-decided.

`unpacked-control` is the same world with sixteen forgeries: the commit is
served on every plane, the victim applies it live, its cursor moves past it,
and `relay_health()` reports every expected REQ live. It is swept, and it runs
in the NIGHTLY as the burial arm's control — the same world and every step but
the cap, so a night that holds it says the live plane serves a commit under
forgeries at all, which is the premise the burial arm rests on. The priced
nightly plus its margin is 6 310.25 s of 6 360 (`tests/budget.rs` is the gate;
the budget was raised from 4 800 when S16 `processed-ids-growth` joined, from
4 860 when R4 returned the burial to the nightly beside the recorded arm and
S20's two pile-ups, from 5 100 when S26 joined, and from 6 240 when S27 and
S28 joined, with the deadline, the step cap and the job cap that move with
it: 116 m, 118, 156; W9p's re-pricing onto
the driver's own waits lowered the run and left the budget, which moves only
when the run outgrows it).
Measured 2026-10-26 in `cargo test`, ten runs each, all green: the burial
86-87 s and the recorded relay-without-NIP-77 arm 80-81 s, each against a
96.75 s bound; S20's two pile-up arms 24-27 s each, most of it the NIP-77
spacing they wait out.
Measured 2026-09-27 in `cargo test`: about 78 s of wall for the
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

### Durable-storage growth: S16's four arms are four different stores

"The engine bounds its storage" is true of exactly ONE of the three stores an
inbound kind-445 can land in at the pinned engine, and S16 measures each on its
own terms (Rule 12; `scenarios/s16_storage_growth.rs`, one arm per store, all
nightly). A fourth arm records a store that ordinary traffic grows. Where an event lands depends on who sealed it and on the group's
epoch state when it arrives, because the peel runs after the `can_ingest` gate
and before anything convergence-related:

* **`outsider-flood` — the CAPPED `PeelDeferred` store.** Forgeries an outsider
  can mint from the circle's public `#h` — content that decodes, sealed by no
  member — reach the peel and fail there, and the engine retains them up to
  `MAX_PEEL_DEFERRED_ROWS_PER_GROUP` (2048 at MDK v0.10.4, read from `cgka-engine`
  at runtime, never restated; the crate's first and only direct MDK dependency).
  The arm feeds the store PAST the cap and asserts that exactly `cap` rows were
  retained, that every later feed was REFUSED — MDK v0.10.4 answers
  `ResourceRefused { TransportDeferredCapacity }`, which the classifier reads
  positively as `PeelDeferredCapped` — with no row, that the row cap and not the
  16 MiB byte budget is what bound, then one more forgery over the live plane,
  after the cap, which leaves no row either. A refusal is never recorded as
  seen: Haven holds the cursor at it and refetches it
  (`haven-core/tests/resource_refused_e2e.rs`), which is why refusing above the
  cap is not a Rule-12 breach. **Red at the bump, fixed in Haven:** each send
  gives the rows still untried under the current context a foreground peel
  opportunity of 250 ms or 4 rows (`cgka-engine/src/message_processor/mod.rs:215-222,1208-1230`)
  and queues the send when it runs out, and every commit re-arms all of them,
  so after a 2048-row flood the victim's next sends were deferred for about
  four publish cycles. Haven now gives every untried row its try before the
  send, as far as the wake has room — a background burst's end cuts the drain,
  and the send is then held for the next wake (`CircleManager::seal_location_staging`;
  `docs/MDK_UPSTREAM_TRACKER.md` T-FOREGROUND-PEEL;
  `haven-core/tests/resource_refused_e2e.rs`
  `a_full_deferred_peel_store_never_defers_the_next_location_send`), the
  closing round's sends go out, and the arm is `SWEPT` and back in the nightly.
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
  `MARMOT_PROTOCOL_KNOWLEDGE.md` beside #757 (measured at `e391adc`, whose
  cap was 256).
* **`processed-ids-growth` — the UNPRUNED processed-transport-id table, a
  RECORDED EXPECTATION** (`docs/MDK_UPSTREAM_TRACKER.md` T-DEDUPE-GROWTH). MDK
  v0.10.4 records one `cgka_processed_transport_ids` row per wrapper it peeled
  and keeps it for the life of the group
  (`storage-sqlite/src/migrations/0058_processed_transport_ids.rs`); only
  forgetting the group deletes the rows. No adversary is needed: every
  location a member receives adds one. The arm sends eight fixes and reads the
  count after each through `processed_transport_id_count_for_test` (seam 10;
  one step per fix), hands the first fix to the victim again (a duplicate
  records nothing, so the count is of wrappers peeled, not of deliveries),
  then walks the group `DEFAULT_MAX_PAST_EPOCHS + 2` commits forward — one row
  per commit followed — and reads the count once more: every row is still
  there, though the engine no longer holds a key for the epoch the fixes were
  sealed in. That last reading is the expectation. The day MDK prunes the
  table it is unmet and the arm is **rc 3**, "the recorded expectation is
  stale", and is replaced by a graded bound in the same change. Its
  mis-configuration control runs it on a downed plane: nothing is carried,
  nothing is peeled, rc 3. It says nothing about how fast the table fills on a
  device; no figure for that has been measured.

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

### Relay addresses no plane serves

Most arms move an epoch by committing a relay list that names one more
address — `wss://<salt>.example.com` — so the commit is a real change. Since
the routing follow, the product follows each circle to what it lists, so that
address is dialled. Dialled as written it would leave the host (a DNS query
at the least), so the rig's address map (`rig/address_map.rs` `endpoint_map`)
gives each such address an endpoint of its own: a listener of its own in front
of the world's FIRST plane's relay, one per address per device (sixteen per
device, `ALIAS_ENDPOINTS`; a world that names more fails its teardown rather
than folding two addresses into one relay). Each is therefore a relay of its
own to the device's pool, to the driver's per-relay gate and to the
`min(2, n)` count of relays that acknowledged, and it takes every fault aimed
at its plane or at its device. Before W9p-2 the map made such an address a
second NAME for the first plane's own endpoint: one relay counted as two, and
both names shared the driver's per-relay gate, which is keyed on the mapped
address (`RelayMappedFanout::take`).

Why the address is mapped at all was measured on 2026-10-18 (W9p-1): left
unmapped, S04's `offline-across-commits` reddened in an A/B run on exactly the
terms a dead relay then produced — its REQ never live, the burst's backlog
wait timed out, the cursor advance never redeemed — while S14's red that day
had a separate cause (its isolation premise; fixed apart). A dead relay no
longer holds a circle: since W9p-2 the live plane counts a relay toward a
circle's coverage only if it was connected when it took the REQ, releases one
that never ends its replay after `EOSE_WAIT`, and records what each relay left
out owes (`relay_floors`); S25 grades exactly that over real relays. The map
stays because a hermetic world dials nothing off the machine.

To O7 each such address is a LOCATION relay of its own, judged by the address
a circle's commit named, never by the plane whose relay its listener fronts:
a frame on a device's alias endpoint is a frame on the relay that address
stands for (`AliasBook::stands_for`), so a `#h` for one circle on an address
only another circle's routing named is a crossing like any other.

### Relay-plane containment (O7)

`RelayPlaneContainment` (`INV-O7`, `oracle/planes.rs`) grades every frame a
device sent against the relay-plane allow matrix — the one in
`tooling/e2e/local-relay/src/planes/policy.rs`, mirrored in
`haven-core/SECURITY.md` and judged by the same `judge()` haven-core's L1a,
`rust_builder`'s L1b and the E2E lanes' C8 call — after every arm
(`Scenario::run`, so no arm grades it and none is exempt) and after the
nemesis phase (`grade_settled`).

* **Roles in the world.** A world's relays are three sets, never one
  relabelled (`WorldShape`): the LOCATION planes every circle routes over
  (`relays`, what an arm calls "the relays"), the ACCOUNT planes (every
  device's inbox on the first, its key package on the second when there are
  two — `pr` has one, so its single account plane carries both lists and the
  `#p`/`#h` split is graded on every PR; `nightly` and `weekly` have two, so
  the two lists are told apart) and the PROFILE planes (none in `pr`, three in
  `nightly`/`weekly`, the product's `PROFILE_POOL_MIN`). A device's engine
  holds the location planes and its inbox plane (`SimWorld::engine_planes`);
  S01's all-relay and rolling outages roll over exactly those, the device fully
  offline.
* **The ground truth is the rig's.** Each circle's routing is recorded where
  the rig decides it — at build, at the staging of every relay change (before
  a byte of the commit leaves, whatever the commit then comes to), and at
  S24's routing commit — never read back from the product. A relay a change
  leaves stays admissible for what its circle may still send there: commits
  frozen to it, `#h` REQs within the prior routing's 24-hour standing
  (`PRIOR_ROUTING_STANDS_SECS`, longer than any soak world — the
  `routing_retained_epochs` half of the standing is not graded), and a location
  from a member that has not applied the change yet, whose seal instant the
  rig knows for no member but the one that staged it. The exact left-routing
  rule (a location sealed after a change goes only to the new routing) is
  graded by L1a, with one sender; the soak grades that a location never
  reaches a relay its circle's routing never named, and that no circle's
  traffic reaches an account or profile plane.
* **Senders.** A frame on a device's own or alias endpoint is judged with that
  device's pubkey as the sender, so the per-identity bindings hold (a `#p`
  REQ names the sender, a key package is the sender's own); a frame on a
  plane's canonical endpoint (catch-up sweeps, the rig's inbox reads, an
  invite's key-package lookup) is judged with the union rules.
* **Rig traffic needs no exemption.** The rig publishes by ROW
  (`SimWorld::publish_witnessed`): a key package and the key-package list to
  the device's key-package plane, the inbox list to its inbox plane, a kind
  445 to the location planes of its circle's routing; anything else is
  refused (`RigError::UnknownTarget`). Forgeries (`Fault::Inject`) and seeds
  (`SimRelay::store`) never cross the client→relay path, and both are
  indexed by the circle they carry so a by-id fetch of one is judged.
* **The record.** Every client→relay data frame — text, binary, unparsable,
  `COUNT`, `AUTH`, a REQ a `CLOSED` fault refused — is recorded at the proxy's
  one choke point, before anything parses it, under its endpoint and
  connection (`relay/ledger.rs`). It keeps the projection the judge reads
  (an event without its content and signature, a filter without its window,
  the subscription id kept for the `CLOSE` rule), so a REQ re-issued on its
  connection is one entry — but every reconnect is a new connection and every
  fetch a new subscription id, so the record grows with a world's faults and
  fetches. `PLANE_SHAPES_CAP` 4096 and `PLANE_IDS_CAP` 65 536 per plane bound
  it; a record that hits a cap answers `plane-record-full`, rc 2 — never a
  silent drop. The marks measured so far are single arms (at most 66 shapes
  and 1 010 ids a plane); the long nemesis worlds are measured by the nightly
  run, and a cap moves only from a measured mark.
* **Findings.** `plane-crossed-event`, `plane-crossed-request` and
  `plane-unknown-frame` (rc 1) name the plane's and the device's handles, the
  matrix row and the judge's class literal, nothing else; a `CLOSE` naming a
  subscription its relay was never sent is an unknown frame, never
  special-cased. `plane-unobserved` (rc 4) is the vacuity, per ROLE: the
  location planes must have carried a `#h` REQ (`REQ-445-H`) and the account
  planes the inbox REQ (`REQ-1059-P`), and a profile plane an arm declared
  driven (S26) a profile publish (`EV-0`) and a profile lookup (`REQ-0-A`).
* **Advisory.** `coverage.log`'s `plane_overlaps` buckets how many relays of
  the fullest graded world held two planes at once (in `pr`, the one account
  plane carrying both lists). An overlap is admitted by the policy, never a
  crossing; the count is what a night can say about the correlation
  containment cannot grade.
* **Discovery is not graded by the soak**: the discovery override is
  process-global and install-once, and `cargo test` runs worlds concurrently.
  A soak process points it at a loopback port bound and never listened on,
  held for the process's life, so a lookup that fell back to discovery is
  refused before it is a frame. L1a grades the discovery plane on every PR.

### The MDK v0.10.4 bump: what moved in the rig

* **The classifier** (`oracle/undecryptable.rs`) maps v0.10.4's outcomes:
  `Ignored` by category (duplicate, own echo, routing, and a new `Invalid` for
  input the engine proves can never apply), `LocalState` (removed, quarantined,
  a new `RejoinPending`), `TransportDeferred` → `PeelFailed`, `ResourceRefused`
  → `PeelDeferredCapped`, `Rejected` → `Invalid`, and the live `Stale` reasons.
  A same-epoch race's sibling is now HELD for the convergence pass that
  adjudicates it, so the branch is read off the sibling's stored row once that
  pass closes (`classify_settled_sibling`: `Processed` adopted,
  `ConvergenceDeferred` lost). `Quarantined` is now reachable through the rig.
* **S06** — an unresolvable application row no longer gates the circle at all
  (it gates only as a branch witness beside competing commit edges), so the arm
  now asserts the row neither gates nor survives a sweep past the horizon.
* **S09** — the two forgeries the parse can read are the ENGINE's own verdict
  (terminal or retained), never an ingest failure; the cursor holds for neither.
* **S12** — the twin is minted in the Current profile: the proof is LeafNode
  component 0x8009 in the app-data dictionary.
* **S14** `race-restart-before-confirm` — the second racer's commit is staged
  in the core's STAGING MODE, with its durable `OutboundFanout` row written in
  the same lock hold, and published by the core's fanout driver
  (`haven-core/src/relay/fanout.rs`) — the path every product commit but one
  now takes (the exception: the wake sweep's, below). The driver sends into relays that store the commit while the
  device's endpoint swallows the `OK`: the commit is on the relay, unresolved
  on the device, and the process is killed there — between the relay's
  acknowledgement and the local confirm. Canary 2 is now "the send path is
  STILL shut after the reopen, held by one pending fanout carrying the staged
  commit's id": MDK's hydrate restores the pending commit from the row instead
  of clearing it (`cgka-engine/src/engine.rs:1894-1947,2084-2110`). The arm
  then has the product resume it (`drive_due`), stepping the driver's pacing
  clock over the wait the driver itself names rather than sitting through it;
  the relay answers the byte-identical event and the commit applies. Both
  commits are then delivered both ways and the arm grades one surviving
  branch, as before. The swallowed acknowledgement costs one call of MDK's
  relay client — twenty seconds of real time, priced as
  `WithheldAcks::FanoutDrives(1)` (`bounds::fanout_call_ceiling`).
  **Why it was red on some seeds:** while the rig published the commit itself
  and dropped the pending ref, the kill left a staged commit with no row;
  hydrate cleared it, and the reopened device's first convergence pass then
  merged that commit's own stored row alone — so whenever the content ordering
  favoured the peer's commit, each device kept its own branch (a twin fork no
  later input healed; 35–45 % of runs). A commit staged with its row has no
  such state. Since W9q no path stages without a row: the wake sweep makes no
  commit at all, and S05 `kill-sweep-eviction` grades that. Since the routing follow
  an engine listens to every circle its device holds, the extra circle
  included, so every S14 arm now stops both racers' engines for the race and
  starts them after its reads.
* **S18** `create` (now `swallowed-ok-founding-welcome`) — a founding create
  is canonical at v0.10.4, so an
  unacknowledged welcome leaves the circle on the admin's device and nobody
  else's; the rig reports it unacknowledged rather than rolled back.
* **S19** `duplicate-replay` — went red at the bump because Haven never
  acknowledged MDK's durable application outputs, which re-emits every
  decrypted fix at each session open; fixed in `haven-core`
  (`SessionManager::note_batch`, `tests/application_output_ack_e2e.rs`).
* Every rig seam that hands a peer commit to a device now serves the
  convergence deadline MDK announces, the way a receive plane does
  (`settle_receive_for_test`).

### The catch-up sweep under page faults: S20's five arms

RLY-05 was five ways for `run_catchup_all_circles` to call a window finished when
it was not, or never finished at all. S20 (`scenarios/s20_catchup_sweep.rs`; these
five arms and the two pile-up arms below, all nightly) rebuilds each against the
real relay double. Every arm seeds a
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

**Found while building it (owner question OQ-V):** the page-bound fix closes
(b) for a FUTURE-dated page only. A full page of kind-445s dated inside ONE
second of the window — here, the same rewraps dated at their source's own
second — is served, keeps the chase alive by page size, repeats at a boundary
that cannot descend, and halts: measured, three consecutive sweeps held every
circle and never served the genuine event one second below the pile-up. The
forgeries carry no `expiration`, so nothing retires them. Recorded as **C10** in
`docs/BACKGROUND_SHARING_FAILURE_ANALYSIS.md` (mechanism and `catchup.rs`
cites). R4 answers it with the NIP-77 pass and grades it: `same-second-pile-up`
seeds one genuine location per circle and, in the second above it, a whole page
of events the screen refuses before authentication, then runs two sweeps on
relays that speak NIP-77 — a genuine location never taken in is O1's
`probe-not-delivered`, and a circle whose cursor neither sweep advanced is the
new `cursor-held` finding (rc 1). `same-second-pile-up-without-negentropy` is
the same seed on relays that refuse NIP-77, RECORDED: the window stays held and
the location unreached (`T-NIP77-FALLBACK`). Both wait out the pass spacing
(`Absence::NegentropySpacing`, `NEG_PASS_SPACING_MS`) before seeding, so a pass
a wake began at the world's start cannot stand in for the sweep's.

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
commit-to-green figure. `soak-core-pr` is `needs: [rust-tooling]`, so the lane
begins when stage 1's `soak-tooling` job ends (37 minutes in run 41379633131),
no matter how fast it is. A cache-miss run (a cold build is
plausibly 10–25 minutes, bounded by the 40-minute job cap) is recorded with its
cache-miss evidence line and excluded from the p95 rather than averaged into
it.

Three numbers that are easy to conflate, and are not the same thing:

| Number | What it is |
|---|---|
| **1440 s** (`pr`) | the RUN budget: the work the profile TOML declares — the ARMS *and* the background nemesis phase the driver walks before them. `tests/budget.rs` proves Σ(derived deadline of every declared arm) + Σ(one graded round per scheduled probe, plus the teardown round) + margin fits it |
| **25m** | the inner DEADLINE, the budget plus twice the margin so a hung run is killed with time left to finalise. `run-with-deadline.sh` prints which bound fired and its number, where a bare `timeout` would leave an anonymous 124 |
| **27 / 65 min** | the drive step's cap and the job's |

**Why the ceiling sits so far above the measured run (D4).** A healthy `pr` run
measures **about a hundred seconds** (104 to 119 s over four runs, 2026-11-11:
seven worlds built and torn down, the three mesh arms themselves 0 s, 4 s and
5 s); the budget above is **1 440**. The two are
not in tension, because a derived bound is only ever PAID when something fails
to happen. The arms cost ~380 s of bound and the background schedule ~1 016 s —
five graded probe rounds at the pool's own 123-second reconnect ladder plus the
teardown sweep — and every one of those seconds is a ceiling on a wait that
normally returns in milliseconds. Pricing the phase at anything less would be
asserting a bound the product does not have, which is the one thing this table
may not do.

The cost of the wider ceiling is therefore not lane time. It is **how long a
HUNG run blocks a pull request before it is reaped**: 25 minutes instead of 6.
Nothing else changes — the p95 stays at build plus the run, and what names WHAT went
wrong is still the rig's rc taxonomy, never the deadline.

**Recorded, for the lane's owner:** the `pr` job cap sits at **65**, above the
sum of its step caps (10 scanner + 25 rig build + 27 drive = 62), so the
drive's own 25-minute deadline is what reaps a hung run rather than the job's
anonymous timeout — which is the outcome the ordering rules exist to prevent.
The other two jobs are the same shape (156 against 153, 355 against 340). What
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
bound large enough to let a healthy run finish — the 1440 s budget — cannot sit
under the 1500 s deadline: with the allowance it prices the lane at 1620 s and
would force the deadline to about 27 m for no diagnostic gain, since the rig's
own rc taxonomy is what names WHAT went wrong and a deadline only ever names
THAT it hung. The
`cargo run` is unbounded work that is not a wait, so the budget guard prices it
by that allowance alone — which is the honest reading: the deadline is the
bound. The manifest section for `run-soak-core.sh` says so where the arithmetic
lives.

### The cost to the whole pipeline

`soak-tooling` lives inside `rust-check.yml`'s `tooling` group, which `ci.yml`
calls as `rust-tooling` and which only this lane waits on; the other stage-4
lanes wait on the `core` group (`rust`). A cold build there delays this lane.
That is why it carries an explicit `timeout-minutes: 60` (the only job in that
workflow that does) and why it shares ONE `shared-key: soak-crate` cache with
all three `soak-core.yml` jobs — `key:` appends to the automatic job-scoped key,
which would give four jobs four cold builds of the same crate. `soak-tooling`
runs inside the `rust-tooling` dependency the lane needs, so the cache is written
before the lane starts.

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
floor with an oracle. An arm that checks its canaries through
`vacuity::Canaries` (S02 today; the others still count) ends its report line
with the ordinals it missed — `missed=1,3` — because a `CanariesCaught` floor
unmet by one of several instantaneous checks is otherwise unreadable: CI run
41671663759 lost one of S02's four in a 2 s arm, and the count alone could not
say which.

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
  S07 amplification factor: not measured (Phase 2)
  measured: wall=<s>s peak_rss=<MiB>MiB peak_session_store=<quarter of the ceiling>
```

**Why the seed and the schedule tag are printable.** Every preimage of a
scheduler seed is public repository metadata, and the `pr` seed is the
`DEFAULT_SEED` constant in `tooling/soak/src/main.rs`: the PR lane passes no
`--seed` and no profile TOML carries a seed at all, so a PR run is reproducible
from the repository alone. A scheduled slot's seed is
`scripts/ci/soak_seed.sh --seed nightly <run date> <slot>`, every input of which
is public run metadata. Neither identifies a user, a circle or a device: they
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
  What this crate resolves is also held by `check_mdk_supply_chain.sh` and
  `check_lockfile_universe.sh`, which read this lockfile next to haven-core's
  and rust_builder's.
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
| `scripts/ci/check_soak_lane_reachable.sh` | Something RUNS the rig: `ci.yml` calls the `pr` profile on `needs: [rust-tooling]`, the caller of `rust-check.yml`'s `tooling` group, a scheduler's matrix caller carries its slot in its name, which the issue filer finds each slot's job by, `rust-check.yml` self-tests the shipped binary, every job in every `soak-*.yml` (the count pinned) drives through the gated runner under an inner deadline and uploads only after it — in a scheduler the skip is structural (the job that `uses:` the reusable, and `prepare`/`file-issue` by id with their reasons), so a job running `run_soak_local.sh` or the bare rig is read and fails — every such job also scans in a step of its own whose condition the drive's outcome cannot switch off (L7), the profiles nest over (scenario, arm) pairs, the TOML's deadline equals the workflow's literal, and `soak-nightly.yml` calls the nightly with per-slot seeds, off every other cron, non-cancelling, each checkout granted, one artifact name per slot (L8) |
| `scripts/ci/soak_seed.sh` (`--self-test`) | The one seed definition, used by the scheduler and every reproduction of a night: `0x` + 16 hex of `sha256("<profile>\|<date>\|<slot>")`, the date the RUN's `created_at`; a known vector from an independent hash, every refusal printing no seed, and a recording `gh` that reds if `/attempts/<n>` is ever read |
| `check_e2e_step_timeout_ordering.sh` + `check_e2e_lane_budget.sh` | Extended with `is_soak_body()` (excluding `--self-test`). Before it, a plain `ubuntu-latest` `run:` step got C3 alone: the lane could have driven the rig with no inner deadline at all and both guards would have reported it compliant |
| `check_no_identifier_logging.sh`, `check_no_key_logging.sh` | `tooling/soak` as its own root with its own floor in each |
| `check_logscan_policy.sh` | `DECLARED_PLANTS_OFF['soak']` — the rig has no Dart channel, so a declared Dart plant would be a control nothing could satisfy; its `rust` shape plant is what proves the sink was reached |
| `check_logscan_wired_everywhere.sh` | `run-soak-core.sh` in `RUNNER_PINS`, paired with the fixture in its own `--self-test` that pins the gate |
| `check_e2e_publish_before_apply.sh` | `tooling/soak` as a second root beside the Dart harnesses (check 2): no file resolves a staged commit itself — none calls `confirm_published(`, `finalize_relay_update(`, `publish_failed(` or `decrypt_location_collecting_commits(` — and the rig's publish path (`src/rig/circle.rs`) builds the product's driver (`Publishing { … }`). Comments do not count either way |

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

## When a night goes red

A night is the four slots of one scheduled `Soak Nightly` run. Each slot's
`verdict.log` (and banner) carries the RIG's rc. The lane's own scans are
folded with it by the runner (**1 > 2 > 3 > 4 > 0**) into the slot JOB's
result, not into the file: a slot can therefore be red with a `verdict.log`
that says rc 0, and `file-issue` reads the slot jobs' conclusions to catch
exactly that (`lane-red`, below). The artifact is
`soak-core-nightly-<slot>-<run id>`, kept 14 days.

| rc | What it means for a night | What to do |
|---|---|---|
| 1 | A **violation** (`VIOLATION.marker`: an invariant broke; the first-violation snapshot is uploaded) or a **leak** (`LEAK.marker`: a capture carried a declared identifier; the tree was emptied and only the fact of containment is published) | A violation is a finding about `haven-core`: reproduce it from the seed. A leak is a Rule-15 breach in the product or the rig, and outranks everything else in the night |
| 2 | **The rig is broken**, not the subject | A rig bug. Fix the rig; a night with an rc 2 slot proves nothing about the product |
| 3 | **The night proves nothing**: a scheduled fault never fired, an expectation floor was unmet, or a recorded expectation (S03, S14 and S22; S08's, S16's and S20's recorded arms; S05's and S09's recorded canaries) went stale | Read the banner and the schedule, not the app. A stale recorded expectation is replaced by a graded one in the same commit (see "The first recorded expectation") |
| 4 | **Proves too little**: an intact run with an ungraded verdict — typically reaped before its first world was built | Treat as infrastructure until shown otherwise |
| — | **No verdict**: the slot uploaded nothing (the build failed, so the drive never started) or its artifact is empty | Read the job log; a runner loss is re-run once by `rerun-runner-losses.yml` |
| — | **Lane red** (`lane-red`): the rig said rc 0 but the slot's job is red — the lane's own scan (a leak is rc 1, an unusable or ungraded capture 3 or 4) or a step after the drive reddened it | Read that slot's scan step and job log; the verdict has nothing to say about it |

**The issue that is filed.** After the four slots finish, `file-issue`
(`scripts/ci/file_soak_issue.sh`) files ONE issue per distinct key — the
invariant id for a violation, else its finding class, else
`violation-or-leak`, `leak-contained`, `rig-broken`, `no-faults-fired`,
`ungraded`, `no-verdict` or `lane-red` — titled `soak(nightly): <key>` and
labelled `soak` and `soak:core`, never assigned. Four slots red on one
invariant are one issue with four slot blocks; a later night red on the same
key comments on the open issue rather than opening another. The body is the
nineteen allowlisted keys and nothing else (profile, slot, run URL and
attempt, commit, toolchain, seed, schedule tag, rc, scenario, arm, invariant,
tick, the bound and the observed seconds, the rig's own handles, its finding
class, the repro command and the artifact name) — no log line, no path, no
host, no name; a synthetic key carries only the profile, slot, run URL,
attempt and artifact. Only a SCHEDULED run files; a `workflow_dispatch` repro
runs the same script with nothing sent. A runner-loss re-run re-runs
`file-issue` too: a slot re-run GREEN is no longer red, so attempt 2 files
nothing for it and the `no-verdict` issue attempt 1 filed stays uncommented
and stale until a person closes it; attempt 2 re-comments on every key still
red.

**The filing path has been proven live once** (OQ-G, the recipe in
`docs/E2E_TROUBLESHOOTING.md`). From a scratch branch carrying two changes —
S01's `single-relay-outage` arm downing every plane and never healing (in
place of the recipe's derived bound), and a `--file` condition true for a
dispatch — run 36380550952 filed issue #8, `soak(nightly): INV-O1`, with four
slot blocks of the nineteen allowlisted fields, and a second dispatch, run
36381827460, commented on #8 rather than opening another. Neither mutation
reached `main`; #8 was closed and the branch deleted on 2026-09-28.

**Reproducing it.** The seed is in the issue body and on the slot's banner:

```
scripts/run_soak_local.sh core --profile nightly --seed <s> --count 3
```

3/3 red is a defect; anything less is a race in the rig, which is a rig bug
("Reproducing a failure", below). To re-run the whole night on demand, dispatch
`Soak Nightly` with that `seed` (every slot then runs it, and no API call or
date is involved) and `slots` 1–4.

**The promotion rule.** An arm moves between tiers only in a commit that cites
at least fourteen consecutive green nights — consecutive SCHEDULED nights,
since there is no Sunday run, and green meaning ALL FOUR slots green, read from
the four `core` jobs rather than from the run's conclusion (`gh run list
--workflow soak-nightly.yml --event schedule`, then each run's jobs) — with
zero rc 3 for that scenario (an rc 3 reds its slot, so a green night already has none).
PR-gated ⊆ nightly-gated stays enforced by L5; nothing from Phase 2 moves to
the PR lane before then.

**No expected-red arm is in the nightly.** `verdict.log` records a run's
FIRST violation only, so in the nightly an expected-red arm would be the
violation every night reported: every later defect would be masked from the
issue path, no night could be all-slot green, and the
fourteen-night count could never start. An arm required red runs in `weekly`
(no scheduled execution until Phase 4) and is asserted red on every commit by
`tests/oracles.rs` `EXPECTED_RED` in `cargo test` (the `soak-tooling` job),
which is empty today. A red night is therefore a finding. An expected-red arm's
own test fails its first assertion the day it grades rc 0, which is the commit
that promotes it to `SWEPT`, removes it from `EXPECTED_RED` and returns it to
the nightly — as S23 `chained-commit-backlog` (C7), S16 `outsider-flood`, S05
`kill-sweep-eviction` (W9q) and S08 `buried-past-the-cap` (C8, R4) did.

**Owner items for the commit that closes the fourteen-night gate** (none is
done yet, because each needs measured runs):

* the C6 `# job-uncapped-minutes: <m> (<N> runs, worst <run id>)` declaration
  for the three `soak-core.yml` jobs, citing real slot runs;
* `is_soak_body` OR-ed into `check_e2e_step_timeout_ordering.sh`'s C6 branch,
  so C6 covers the soak jobs as C1–C5 already do;
* any job-cap change that measurement forces;
* the measured per-slot minutes written here in place of the plan's
  ≈ 22-minute estimate — and the night-one checkpoint: a warm slot measuring
  over 40 minutes cuts a scheduled night to two slots, the one line
  `DEFAULT_SLOTS` in `scripts/ci/soak_seed.sh`.

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

---

## coverage.log

Written beside `verdict.log` at the end of every run (`tooling/soak/src/coverage.rs`),
one JSON object on one line and nothing else:
`{"triples":[{"scenario","nemesis","invariant","first_tick"}],"plane_overlaps","profile","seed"}`.
`plane_overlaps` is O7's advisory count — how many relays of the fullest graded
world held two planes at once — as a bucket (`0`, `1`, `2-4`, `5+`), never a
count and never a verdict.
A triple is an invariant GRADED under a fault the world had really taken:
`scenario` is a registry id, or one of the background phase's two literals —
`nemesis` for a probe round the schedule asked for, `settled` for the teardown
round graded after its last tick; `nemesis` is a `Fault::label` read from the
relay planes' own ledgers or a `DeviceOp::label` (`restart-soft`,
`restart-hard`, `go-offline`, `come-online`, `step-policy-offset`) a device
recorded taking — what was recorded taken, never what the schedule or an arm
said it would apply, so a device-only arm (S06, S11) has triples too;
`invariant` is the `INV-` id `verdict.log` spells, and `first_tick` the grading
world's tick when that triple first appeared — a count from the world's
origin, never an instant. A world that took no fault reaches no triple, so a
clean empty schedule writes `"triples":[]`, and S13 — whose fault is a lost
store, not a device operation or a relay fault — writes none. An arm's world
is not ticked by the schedule, so its triples carry that world's own tick.
**The knee is the first probe after the last new fault label**: the largest
`first_tick` among the `nemesis` triples. The teardown round has its own
literal because it is graded at the schedule's last tick every night; under
`nemesis` the knee would be the schedule's length, a constant. The key sets
are pinned by equality and every value is checked against its closed
vocabulary in `tooling/soak/tests/coverage_fields.rs` (a wildcard-free match
over `Fault` and over `DeviceOp`), and `tests/run_markers.rs` drives a real run
and pins its WHOLE triple array. It is a
`.log` in the upload tree, so the lane's two scans read it as a `soak` sink like
every other file there. It renders no count of circles, members, relays or
events and no instant.
