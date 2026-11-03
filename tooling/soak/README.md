# `haven-soak` — the Tier-1 soak rig

A whole Haven world in one process, broken on purpose.

A run builds real devices — real MLS stores behind real `LiveSyncCore` engines,
talking to a real in-process relay over a real socket — applies a seeded
schedule of faults to them, and grades what survives. Nothing about the subject
is mocked. The only doubles are the *environment*: the relay plane, the timeline
and the log drain, which is why those three are traits.

## Running it

```bash
cd tooling/soak
CARGO_BUILD_JOBS=2 cargo fmt --check
CARGO_BUILD_JOBS=2 cargo clippy --all-targets -- -D warnings
CARGO_BUILD_JOBS=2 cargo test
CARGO_BUILD_JOBS=2 cargo run --profile soak -- --profile pr --seed 0
```

**`--profile soak` is not optional.** haven-core makes `test-utils` without
debug assertions a compile error, and the `ws://` loopback opt-in every device
needs to dial the world's own relay is `cfg(debug_assertions)` with a release
stub that always fails — so `[profile.soak]` inherits `release` and turns debug
assertions (and overflow checks) back on. `main.rs` refuses to compile without
them rather than failing at 3 a.m. in a lane.

## What a run does

Two phases, and a world of its own for each of them.

1. **The nemesis schedule.** Every tick is walked, every fault fires and heals
   where the schedule says, each scheduled probe is graded (O1), and the world
   the schedule left behind is graded against O1, O2, O6 and O7 (relay-plane
   containment over everything it sent) plus the schedule's own expectation
   floor. Not O5: it grades a set of classifications, and a background
   schedule collects none — an empty set would report that nothing went
   unaccounted for because nothing was looked at.
2. **The declared scenario arms**, in the profile's own order, each graded
   against O7 as well once its body has run.

One world per arm, not one for the run: an arm's expectation floor counts what
its OWN world did (S11's floor includes "nothing was delivered while the circle
was quiet"), so a world carrying the previous arm's in-flight deliveries would
fail a floor for the previous arm's reasons.

The driver lives in the library (`src/driver.rs`) and takes an already-minted
`RunPlan`; `main.rs` is the command line over it. That is what lets
`tests/run_markers.rs` drive a real run with one planted fault and assert what it
left behind, with no test-only branch anywhere in the driver.

## Exit codes

One taxonomy, `haven-logscan`'s, folded with its own `worse()` (`1 > 2 > 3 > 4 >
0`):

| rc | Meaning |
|----|---------|
| 0 | Clean: every scheduled fault fired and was observed, every floor met, no invariant violated, every scan clean |
| 1 | A leak **or** a violation |
| 2 | The rig is broken, not the subject |
| 3 | The world or the schedule proves nothing |
| 4 | An intact run that proves too little — UNGRADED, not clean |

rc 1 carries two opposite evidence contracts, so the two verdicts fold
separately and the run writes a distinct marker for each: `LEAK.marker` (the
lane's containment branch: delete the evidence, upload nothing) and
`VIOLATION.marker` (preserve and upload the first-violation snapshot).

## Log anonymity

Security Rule 15 applies to the rig's own output, so:

* The rig emits **no `log::` records at all**. The timeline is the diagnostic.
* Every `Debug`/`Display` defined here is value-free, and each one is asserted
  by a test that constructs it with needle-shaped values.
* Handles are the rig's own ordinals — `simdev#3`, `simcircle#0`, `simrelay#1`,
  `simevt#12`, `simworld#0` — minted by `sim_tag`. They are deliberately **not**
  `haven_core::log_alias` handles: production's are salted per process from the
  OS CSPRNG and cannot be reproduced, and a determinism test that cannot compare
  two runs' handle tables proves nothing. The `sim` prefix is what keeps every
  rig tag off the word boundary a reader (or a scanner) finds `circle#a91f3c`
  at, so both vocabularies can share one evidence file.
* Magnitudes are bucketed through `sim_magnitude`, which delegates to
  haven-core's bucket policy rather than inventing a second one. Epochs are
  rendered as deltas from the world's origin; instants as offsets from the run's.

## Rule 13 is structural

Every commit the rig makes — a create's included — is staged and sent by
haven-core's durable-fanout driver (`haven_core::relay::fanout::Publishing`),
built per device as the bridge builds its own (`rig::circle::DeviceDriver`): the
commit is recorded before a byte leaves the device, confirmed on a relay's `OK`
— never merely "sent" — rolled back only when every relay proved it refused, and
otherwise kept pending and sent again byte for byte. The rig resolves no
pending state itself (`check_e2e_publish_before_apply.sh` check 2).
`witnessed_ok` asks about the plane's **client-facing** frame stream,
because under a swallowed-`OK` fault the relay stores the event and the client
never hears so, and "the relay has it" is emphatically not an ack.

## Rule 14, and why a restart drops things in that order

The session guard is released when the last `Arc<CircleManager>` goes away, and
the rig's is not the last one: a `LiveSyncCore` holds one, so does its
`EngineProcessor`, and the repair plane clones both into a spawned task.
`stop()` takes `&self`, so it neither consumes the core nor drops those clones.
A restart therefore takes the core OUT and drops it, then takes the manager out
and drops it, and only then waits — bounded — for the registry to say the
session is free. A timeout there is `SessionStillLive`: the rig leaked a handle
(rc 2), never a silent pass.

## Two clocks, one direction

`WallNow` is what a relay cursor, a subscription anchor and a processor window
may see; `PolicyNow` is what decides whether something has aged out. There is no
conversion from the latter to the former — no `From`, no `into_wall()` — because
an offset reaching a cursor comparison fabricates a fork, a replay or a dropped
event, and the rig would then grade the subject on a defect the rig invented.

## Recorded residuals

* **`nostr::Keys` cannot be zeroized.** The type implements no `Zeroize` at the
  pinned version, so neither `Zeroizing<Keys>` nor a `ZeroizeOnDrop` derive over
  it compiles. Every raw secret the harness materialises itself is `Zeroizing`
  (`SimDevice::secret_hex_for_declaration` is the only place it does).
* **Exporter and epoch secrets are undeclarable.** They are minted inside the
  MLS engine and have no accessor, so the rig cannot declare them to the needle
  manifest; recall for them rests on the structural rules alone.
* **The world fingerprint is not the whole quiescence term list.** The
  engine-processor terms (`commit_activity_count`, `all_advances_consumed`) need
  an accessor that does not exist at this pin, so the quiescence predicate reads
  them directly rather than having them half-represented here.
* **`HAVEN_TEST_WAIT_SCALE` stretches delivery budgets only.** The same whole
  multiplier haven-core's own relay-backed tests read, applied at exactly one
  place (`oracle::bounds::round_trip`) so that an absence window structurally
  cannot be reached by it: a scaled budget bounds how long a TRANSITION may
  take, and a larger one can only remove a false negative, while an absence
  window's expiry IS its success path. `tests/wait_scale.rs` is the proof, in a
  process of its own because the scale is process-wide.
