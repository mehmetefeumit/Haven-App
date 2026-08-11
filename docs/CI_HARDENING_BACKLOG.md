# CI Hardening Backlog

Tracking document for the CI/privacy-verification audit of 2026-08-01.
**Last updated 2026-08-10.** Items are open unless marked DONE, FIXED,
IMPLEMENTED or RESOLVED. Each carries evidence so it can be picked up cold.

**Context.** The audit asked three questions: is location sharing reliable in
foreground and background on both platforms; can we prove from the relay's side
that only the expected data leaves the device; and can CI self-confirm that the
docs, the code, and the tests still agree. The audit found four live product
defects (a fifth, P0-5, surfaced later while building Workstream B) and a
systematic blind spot — **CI verified structure, logic and liveness, but almost
never delivery** (that the user-visible promise actually held end to end on a
real platform).

The session that produced this document then pivoted to implementing the
profile-plane relay separation (see `haven-core/SECURITY.md`, "Profile-plane
relay separation — accepted deviations").

**Status roll-up as of 2026-08-10.** Done: the relay separation; Workstream A
(A1–A10); Workstream B (B1–B9, which closed most of the delivery blind spot —
B3/B4/B9 now assert a *peer's decrypted* coordinates); P0-1, P0-3, P0-5; and
Workstream C, whose oracles are now WIRED into the Android and iOS lanes —
though they have still never read a journal from a real run, so the first CI
run is the first evidence. C's follow-ups are done — the MLS group-id channel
carries the Rule-4 ground truth over an intercepted control frame, and
`--exclude-conn` is wired on both lanes. Still open: P0-4's backward paging, three latent C findings recorded below, and Workstreams D, E and F.

**Nothing left in Workstream C can be closed by more code.** The two remaining
substantive items — trimming `_assertWirePrivacyInvariants` and the two
allow-list kinds parked at `required: false` — both need the first green
journal to confirm what is actually published.

---

## P0 — live product defects

### P0-1 · Android background location publishing is dead — FIXED 2026-08-03, UNVERIFIED ON A DEVICE

**As found on 2026-08-02** — line citations refreshed 2026-08-07; the tree no
longer behaves this way (see the fix below).

`MapShell._onPaused()` (`haven/lib/src/pages/map_shell.dart:1049`, handing off
via `_handOffMlsSession` at `:763`) stops the main-isolate publish scheduler and
hands off to the foreground service. The FGS isolate then called
`CircleManagerFfi.newInstance`
(`haven/lib/src/services/background_location_task.dart:513`, inside
`_openCircleManager`) while the foreground `NostrCircleService` still held the
Rule-14 `LiveSessionGuard` (`circleServiceProvider` is a plain `Provider`,
released only at logout). Both isolates share one OS process
(`haven/android/app/src/main/AndroidManifest.xml`, no `android:process`),
therefore one `LIVE_SESSIONS` registry, so `acquire` failed closed. The error
was swallowed at `:365-367`, `_circleManager` stayed null, and `_publishCycle`
returned forever at the `_circleManager == null` gate (now `:859`). `onStart`
ran once; no retry. *(The current code re-attempts the open every cycle via
`_ensureSession()` at `:859` and `_attemptSessionReclaim` at `:764`/`:795`.)*

So backgrounding shuts down the only working publisher and hands off to one that
cannot open the database. Permanent per session, not a rare race.

* **DONE:** `onDestroy` now calls `dispose()` before nulling the handle.
* **OPEN:** the architectural fix. Either extend the existing
  `markForegroundActive` handshake to govern session open/close (foreground
  disposes in `_onPaused()`, waits for release, FGS opens; reverse on resume),
  or route FGS publish requests to the live foreground engine via
  `sendDataToMain` and never open a second session. The second satisfies
  Rule 14 by construction rather than by race.
* **NO LONGER BLOCKED — REPRODUCED AT RUNTIME 2026-08-02** by the
  `e2e-fgs-publish` lane on its first run (CI 30753193231). The device check is
  moot; the emulator answered it. Observed sequence, from one logcat:

  ```
  15:14:35.583 [b1] checkpoint A2: foreground CircleManagerFfi open (Rule-14 guard held).
  15:14:37.300 [BackgroundTask] onStart (starter=TaskStarter.developer)
  15:14:37.738 [BackgroundTask] onStart FAILED: String
  ```

  The FGS isolate died 438 ms after starting, while the foreground held the
  guard, and never published. `_circleManager` stayed null exactly as the static
  analysis predicted. The lane's oracle attributed it correctly and unprompted.
* **SECOND REPRODUCTION, DIFFERENT STAGE — 2026-08-03** (CI 30792258968). With
  the pause-time handoff in place the FGS no longer fails at `onStart`; it fails
  one stage later, and silently:

  ```
  [MapShell] handoff: released=true
  [LiveSyncResubscriber] engine not running — full restart instead of delta
  [BackgroundTask] reclaim: declined, main isolate alive
  ```

  Releasing frees the guard for an INSTANT. A paused main isolate is not a dead
  one: a publish chain suspended mid-`await`, the live-sync re-subscriber
  reacting to a circle-set change, and the maintenance ticks that outlive every
  `MapShell` timer all call `getCircleManagerFfi()` and, on a free guard, simply
  re-open. The service's next 72-second tick then found the guard held by a
  provably-alive owner, its reclaim correctly declined (a reclaim is for a dead
  owner), and background publishing stayed dead through the very handoff meant
  to enable it.

* **FIXED 2026-08-03 — the handoff is now durable.** `releaseForHandoff` latches
  the circle service closed for the backgrounded window; every `initialize()`
  fails closed until the app is foregrounded again, so the single chokepoint
  every UI-isolate consumer already funnels through is what holds the handoff.
  The latch is paired with "and we are still backgrounded" so a missed clear
  lapses on its own rather than bricking the database for the process, and
  `_onResumed` ends it explicitly before anything needs the manager. Guarded by
  `scripts/ci/check_mls_session_single_owner.sh` (three sanctioned openers, one
  per isolate) so a fourth call site cannot bypass it.

  The `markForegroundActive`-handshake and `sendDataToMain`-routing options in
  the bullet above are consequently NOT needed for P0-1 itself. Routing remains
  interesting for other reasons (`docs/P0_1_FGS_SESSION_PLAN.md` §4-§7), and its
  own costs are recorded there.

**The lane that caught this twice is now green — 2026-08-07** (CI run
31216078806). `e2e_fgs_publish` passes with the durable handoff in place, so the
fix has runtime proof on the same oracle that produced both reproductions above.
Still an emulator: what remains unverified is a physical device and the
multi-process case, not the mechanism.

### P0-2 · location-settings copy shipped a false claim in 13 locales — FIXED 2026-08-10

`app_en.arb` promised "if the system closes Haven, updates resume when you move
or when the system next wakes the app." Re-verified before the fix rather than
taken on trust: `catchup_service.dart` and `ios_background_catchup.dart` contain
zero publish call sites, `HavenSLCHandler.swift:9-12` describes its own sweep as
"receive-only", and no SLC, geofence or activity-recognition exists anywhere in
`haven/android` or `haven/lib` — so "when you move" had no Android mechanism at
all, and the iOS one that does exist never sends.

**THREE strings carried it, not two.** `locationSettingsIntro` and
`locationSettingsIosLimitedNote` were known. The third —
`locationSettingsToggleSubtitle`, "Keep sharing when the app is closed" — was
found by a TRANSLATOR, not by the code audit, and it was the worst placed: it
renders directly beneath the toggle, immediately above the paragraph stating the
limit, so it contradicted the correction on the same screen. Same lesson as the
`clockSkewAnnouncement` find: an l10n reviewer traces where each string is
CONSUMED, which a code-first pass does not.

All three now say sharing stops until the user reopens the app, and that
background wake-ups only fetch other members' locations. Each `@description`
carries the reasoning and the file references, so the next editor inherits the
argument rather than the conclusion.

Translated into all 12 locales by four agents on disjoint file sets, then
reviewed by independent agents that translated none of the languages they
checked. Every language ACCEPT; nothing above MINOR; every MINOR either cosmetic
or pre-existing in an untouched neighbour.

**What the round taught, worth keeping:**

* **"Closed" is ambiguous in seven of the twelve languages.** `kapalı`, `بسته`,
  `بند`, `बंद`, `बन्द`, `geschlossen` and `إغلاق` all span "not on screen" and
  "shut down" — so the subtitle was not merely imprecise abroad, it was read as
  the false claim. Each fix pairs the platform term for background with an
  explicit RUNNING verb, which is what carries "still alive".
* **Grammar can carry a claim English can only state lexically.** Russian
  perfective future (`возобновится … только когда вы снова откроете`) binds
  resumption to a single user act; the old imperfective-habitual framing is what
  made the false promise readable. Japanese needed a cleft
  (`行われるのは…受信だけで`) because `だけ` after a noun phrase scopes over the
  NOUN — a literal rendering would have excluded fetching other data while
  saying nothing about sending.
* **Translators improved on the source.** Hindi and Nepali each added an
  exclusivity marker the English lacks ("resumes ONLY when you reopen"), and
  French added a contrastive `lui`, on exactly the privacy-critical point.
* **Reviewers caught what translators structurally could not:** cross-string
  inconsistency. German `sobald` / French `dès que` render "whenever" as a
  trigger moment, contradicting each file's own `Solange` / `Tant que` in the
  sibling `privacyWhatOthersSeeCannotPause`. Fixed.
* **One accessibility find worth the whole review:** German elided *Standort* in
  `dein eigener wird dabei nie gesendet`, leaving the nearest overt antecedent
  the PLURAL "circles' locations" — forcing a screen-reader user to reconstruct
  a singular in the one clause where being wrong means believing you are still
  visible. Two words fixed it.

**Left open, deliberately:** the iOS setting labels are wrong or untranslatable
in two locales — Japanese uses `「常に許可」` (Android's label; iOS ships `「常に」`)
and Nepali uses `'सधैँ'` though iOS has no Nepali UI, so that literal string is
never on screen. Both are pre-existing, both also appear in untouched neighbour
strings, and fixing one of a pair breaks the consistency that currently exists.
They belong to a separate pass over the OS-label strings.

### P0-3 · KeyPackage expires at 84 days → accounts silently uninvitable — FIXED 2026-08-04

**As found on 2026-08-04.** `decide_kp_maintenance` (then at
`haven-core/src/relay/maintenance/key_package.rs:236-278`; now `:307`) had four
branches, none time-aware; the module contained zero references to
`not_after`/`not_before`/`Lifetime`/`expire`. It now has five, and branch 2a is
the rotation gate — so the citation above points at the remedy, not the defect.
After the first successful
publish the `existing_d: Some(_)` branch always routes to
`build_kp_maintenance_events_reusing`, which republishes cached bytes, so the
KeyPackage is never re-minted. OpenMLS stamps a default 84-day `Lifetime`
(`openmls-0.8.1/src/key_packages/lifetime.rs`), and RFC 9420 requires an inviter
to validate it at Add time.

Amplifier: the heal path runs the same lifetime gate, so post-expiry a relay drop
cannot be repaired, and `MaintenanceService` swallowed the failure into a state
indistinguishable from "already healthy" (then
`haven/lib/src/services/maintenance_service.dart:44-53`; those lines now carry
the fix's own rationale — that the `.empty()` fallback is what let a dead
publish path read as a healthy one).

**FIXED 2026-08-04 — owner chose lifetime-keyed rotation.** Rotate at
`KP_ROTATE_AT_LIFETIME_FRACTION = 0.75` of the package's OWN lifetime, read off
the validated KeyPackage (`relay/maintenance/kp_lifetime.rs`), never off an
event timestamp.

*Why not the reference app's design.* White Noise rotates on a 30-day timer
keyed to the Nostr event's `created_at` and never parses `not_after` at all —
`grep` for `not_after|not_before|Lifetime` across its core returns nothing. That
is honest for it only because every publish there mints fresh material. **Haven's
heal path republishes cached bytes with a fresh `created_at`**, so an event-age
timer would silently reset on every relay heal while the real `not_after` kept
ticking: a green timer over an expired package. `heal_does_not_reset_the
_rotation_clock` is the test that exists for exactly this.

*Reading the lifetime needed a dependency.* `not_before`/`not_after` are not
reachable through the pinned Dark Matter crates — the engine parses them but
surfaces the numbers only inside the error for a package that already FAILED
validation. `haven-core` now names `openmls` directly, which adds **zero
crates** (both already resolved transitively; `Cargo.lock` grew two lines) and
avoids putting a hand-rolled MLS wire parser in the crypto path. The reader
validates before reading, so a corrupt row cannot dictate rotation timing.

*Design points worth keeping:*

* **Rotation sits ABOVE the heal branch.** Healing first would republish aging
  cached bytes to the dropped relay and only then rotate — two publishes with a
  window where relays serve about-to-die material. `Rotate` targets every
  responder, not just the missing ones.
* **Unreadable lifetime rotates**, and reports a distinct action. "Assume
  fresh" is the defect being fixed; "assume stale" is bounded and
  self-correcting (the replacement is minted by our own engine, so the next
  tick reads `Known`), and a permanently-broken reader is visible rather than
  indistinguishable from health.
* **Migration is free by construction** — keying on `not_after` means an
  already-published account simply reads as past threshold on the next check.
  No special-case path, tested both directions.
* **Monotonic `created_at`.** NIP-01 breaks a `created_at` tie by keeping the
  LOWEST event id, so a same-second replacement can silently fail to replace.
  Copied from the reference app, which is the one piece of its design that
  transfers cleanly.

*A spec MUST we were violating is now closed.* Last-resort init material must be
deleted at the EARLIER of confirmed replacement publication or `not_after`.
Haven satisfied the first bound (the delete sits inside `if published`, and
`publish_event` returns `Ok` only on ≥1 relay ack) but **not** the second, so an
offline or relay-less device retained dead private keys indefinitely — the same
leak the reference app has. `purge_key_package_past_not_after` now runs before
any relay probe, since that bound is transport-independent. The spec's stated
risk: compromising one lets an attacker decrypt every recorded Welcome to it.

*Failure surfacing, the amplifier that hid all of this.* The bigger conflation
was NOT the swallowed exception in `MaintenanceService` — it was that
`republish_key_package` picks its action BEFORE knowing whether the write
landed and signals the ack only through `relays_healed`, which is 0 on
`AllRelaysFailed`. A publish acked by **nobody** arrived in Dart labelled
`republishedFreshD` and scored as success. Classification moved into the FFI
mapping layer; `KeyPackageMaintenanceOutcome` is now a sealed
healthy/published/failed hierarchy whose `.empty()` constructor — the literal
collapse — is deleted, and the scheduler retries on a ladder instead of
sleeping a full interval while the account is uninvitable.

*`relays_targeted` separates two failures that looked identical:* nothing
configured (await user action) from nothing reachable (retry promptly).

*Testing.* 21 lifetime-reader unit tests; `tests/kp_rotation_e2e.rs` (11)
including a security oracle proving a deleted init key actually makes Welcomes
to that package undecryptable; 4 real-FFI tests; 21 Rust mutations and 4 Dart
mutations, 0 survivors. Plus the wire lane below.

*Wire proof — `e2e-kp-rotation`* (`tooling/e2e/ci/run-kp-rotation.sh`,
`haven/integration_test/kp_rotation_wire_test.dart`, 36 self-test fixtures).
Everything above observes rotation from the PUBLISHER's side; this proves the
part a user actually hits — a separate participant fetching from the relay gets
material that validates at Add time AND yields a working group. A Welcome that
is accepted but produces an unusable group is what a "did the Add succeed"
check would wave through, so the lane requires Alice to decrypt what Bob
publishes afterwards.

The threshold is reached by **backdating the device clock 70 days before the
first mint**, then restoring true time. A short-lifetime package was rejected
as unmintable (the 84-day span is not configurable anywhere Haven can reach,
and a hand-built package would not be what the production minter produced); a
forward jump is impossible because `strfry.conf`'s
`rejectEventsNewerThanSeconds = 900` refuses to accept anything from a device
ahead of it; a test-only threshold override was rejected on the precedent
`check_no_exporter_label_override.sh` sets. Backdating leaves the mint, the
stamped `Lifetime`, the reader, the arithmetic, the publish and the relay all
real — the only fiction is *when* the first package was minted, which is the
variable under test. It works because the relay's clock is the one that does
NOT move.

Non-vacuity: the lane requires TWO independent readings of the same claim — the
tick's own `rotatedExpiringMaterial` verdict AND a superseding relay event with
different `content` in the same `d` — so reporting rotation without publishing,
or publishing without re-minting, both fail. The elapsed fraction is computed
from WIRE timestamps and must fall strictly between 75% and 100%, which is also
what separates "threshold fired" from "already expired" (the action name alone
cannot: `rotatedExpiringMaterial` covers both).

**Known gaps, stated rather than implied:** Bob is a separate identity, DB and
MLS state but the SAME OS process — the repo has no multi-process E2E harness.
Android only; `adb root` + `date` has no `simctl` equivalent. 70 days is
simulated, not waited. And the converse heal case is unreachable on the wire by
construction (rotate precedes heal, so a past-threshold package can never be
healed), so the wire lane proves the reachable half and the host suite covers
the other with a fabricated lifetime.

**Lane status:** wired at `ci.yml:206-209` and green as of CI run 31216078806
(2026-08-07). Host-side, `relay::maintenance::kp_lifetime` is 21/21,
`kp_rotation_e2e` 11/11, and `run-kp-rotation.sh --self-test` 36/36.

**Adjacent spec deviation found, NOT fixed:** `mint_d()` generates 16 random
bytes → a 32-char hex `d`, but the Nostr binding requires exactly one
64-character lowercase hex value decoding to 32 bytes. Existing slots are
reused, so a fix affects first publishes only. Follow-up.

**Also found:** `MockRelay` does not implement NIP-01's lower-event-id
tie-break — it takes the last write. Discovered by asserting the spec and
watching it fail. This makes the same-second hazard WORSE, not better, since
the same tie can resolve differently on different relays.

### P0-4 · Catch-up drops offline backlog — OPEN (partial)

`haven-core/src/relay/catchup.rs` fetches with `.limit(512)`. Per NIP-01, `limit`
returns the **newest** *n*, so past 512 events the oldest are never delivered.

* **DONE:** saturation detection. On a saturated window the cursor is held
  (`cursor_advance_ms`), so the tail is no longer silently skipped past.
* **OPEN:** the complete fix is backward paging (`until = oldest_seen`, loop
  until a short page or the deadline). Deferred because it changes fetch
  ordering in the MLS convergence path and wants E2E validation. Until then,
  a circle with a persistently saturated window makes no cursor progress.

### P0-5 · Unauthenticated remote cursor poisoning — FIXED 2026-08-04 (all paths)

Discovered while building the Workstream B clock-skew lane; it is the severe
form of what B8's finding (3) records as a benign clock-skew shape.

**Anyone who has ever observed one of a circle's kind-445 events can
permanently kill that circle's offline catch-up for a chosen member, at will,
for the cost of one event.** No membership, no key material, no authentication
of any kind.

Two independent routes to the same primitive, both landing on the same root
cause — **the persisted sync cursor is derived from the inbound event's OUTER
`created_at`, which is never authenticated for any outcome.** The engine
authenticates the *inner* MLS message; the outer timestamp is a free field
chosen by whoever signs the wrapper, and nothing on the receive side binds
outer to inner (the peeler binds them at *wrap* time only,
`transport-nostr-peeler/src/peeler.rs:162-170`).

1. **Pre-authentication expiration screen.** `SessionManager::process_event`
   short-circuited any event whose NIP-40 `expiration` was past +
   `RECEIVER_EXPIRATION_GRACE_SECS` to `Stale` **before**
   `event_to_transport_message` and before any MLS work. Both cursor gates
   (`live_sync/processor.rs`, `catchup.rs`) treat `Stale` as "advance past
   this".
2. **Re-wrap of a genuine ciphertext.** Take a real kind-445 off the relay,
   re-sign the same content under a throwaway key with an attacker-chosen
   `created_at`, and omit the `expiration` tag. The outer ChaCha20-Poly1305
   layer still opens (same ciphertext, same exporter secret), the inner MLS
   message is genuine and authenticates, the engine returns `Processed` — and
   the cursor advances to the attacker's timestamp. **Works against a fully
   conformant relay and needs no expiration tag at all.**

Routing is by subscription id and the `h` tag, and the `h` tag IS the public
`nostr_group_id`, visible to every relay observer.

Consequence: `since_for_stream` re-derives every subsequent REQ floor from the
poisoned cursor, so every legitimate event below it is outside **every**
future request. The cursor is persisted, so it survives restart. A stranded
location ages out harmlessly; a stranded **commit** breaks the epoch chain
permanently — the exact consequence `catchup.rs`'s own doc gives as the reason
saturation must hold the cursor.

Two further findings from the same investigation:

* Garbage content with a valid `h` returns `IngestOutcome::Stale { PeelFailed }`
  (`cgka-engine/src/message_processor/ingest.rs:309,327,379,402`), which both
  gates also treat as advancing.
* **A future-epoch application message is `Stale { PeelFailed }`, not
  `Buffered`.** So the "the cursor stops at the first `Buffered`" protection
  that the `catchup.rs` and `processor.rs` module docs claim does NOT cover
  the out-of-order case they describe. The docs were asserting a safety
  property the code does not have.

* **DONE (phase 1) 2026-08-03 — a pre-auth drop can no longer move a cursor.**
  `IngestOutcome` / `StaleReason` are upstream `cgka-traits` types, so no
  variant could be added. Instead `process_event` returns a Haven-local
  `ScreenedIngest { Ingested(IngestEffects), RejectedBeforeAuth(_) }`
  (`nostr/mls/types.rs`) — two variants, no field to forget, and the only
  accessor is `fn ingested(self) -> Option<IngestEffects>`, so a caller who
  ignores the `None` arm loses the effects (fails safe) rather than inheriting
  a synthetic "engine said stale" (fails open). `RejectedBeforeAuth` carries no
  timestamp, so there is nothing in the value to advance a cursor *from*. Both
  gates return before routing, publish-work resolution and convergence drain.
  Structurally guarded: `#[deny(clippy::wildcard_enum_match_arm)]` on the two
  cursor-deciding functions makes a future variant silently inheriting
  "advance" a hard error under `-D warnings`. Every cursor advance is also
  clamped to `now` via a shared `cursor_ms_for_event`. 8 mutations, 0
  survivors.

  Catch-up treats the new outcome as SKIP, not STOP, deliberately: the screen
  fires on NIP-40 expiration, and a window opened after any offline gap longer
  than the ~228 s TTL legitimately *begins* with genuinely expired locations
  (a non-NIP-40 relay still serves them). Under a STOP rule the contiguous
  prefix would terminate at index 0 on every such sweep and an attacker would
  buy a permanent stall for one event.

* **DONE (phase 2) 2026-08-04 — the cursor no longer derives from any
  attacker-writable field.** The governing rule is an asymmetry: the ADVANCE
  comes from a trusted local fact; remote timestamps may only HOLD IT BACK.

  *Catch-up* anchors to the **fetch-window open time** — a local `now` read
  taken before the circle's REQ is issued, which doubles as the `since`
  derivation's `now`. A complete window means "these relays handed over
  everything they held as of the moment I asked", and that instant is exactly
  the claim being recorded.

  *Live-sync* anchors to **EOSE**, which turned out to be reachable:
  `RelayMessage::EndOfStoredEvents` arrives on the pool notification stream
  (`nostr-relay-pool-0.44.3/src/relay/inner.rs:1048,413`) and was previously
  folded into a blanket `Ignore`. It now rides the **same bounded mpsc channel
  as events**, deliberately, so the worker sees it only after draining every
  stored event that preceded it. A new `live_sync/anchor.rs` holds a per-circle
  generation `{opened_at_secs, eose_consumed, hold_back_secs}`, opened at each
  REQ issue and redeemed once. `process_group_event` now writes **no cursor on
  any path** — a categorical statement, not a filtered one.

  The advance is `min(local_window_open_time, oldest_unapplied_created_at)`
  clamped to `now`, and `advance_sync_cursor` is monotonic-max. The only
  remotely-written input sits on the `min`'s LOW side, so it can lower the
  result but never raise it, and a hostile low value is a no-op rather than a
  regression. An attacker injecting any number of kind-445s at any `created_at`
  therefore cannot push the persisted REQ floor past a legitimate event.

  **23 mutations, 0 survivors** — three survived first encoding and are
  recorded as such: the rewritten replay test (both rules landed in the same
  second, so it discriminated nothing until a deliberate settle was added), the
  buffered-hold test (fixed by backdating the event), and `Unprocessable` (no
  test existed at all). The mutation runner itself had a bug — its
  compile-error grep matched cargo's own `error: test failed` line — so the
  first three runs were re-done after fixing the detector; no "caught" result
  is a disguised compile failure.

* **`PeelFailed` resolved: do NOT hold.** The fetch-window design makes the
  correctness half moot — `PeelFailed` no longer feeds the advance *value* at
  all — and answers the availability half against holding. The engine already
  persists an undecryptable message as `PeelDeferred` and re-peels it when the
  missing commit lands, so recovery is the engine's, not the cursor's. A
  Haven-side hold would freeze the cursor of any client temporarily unable to
  decrypt, grow the window until `saturated` froze it permanently, and hand an
  attacker a permanent stall for one forged garbage event. Encoded as mutation
  M23, which breaks six tests.

* **Two design costs, accepted and stated.** (a) The catch-up gate requires
  ≥1 relay to respond, not unanimity — unanimity would freeze any circle
  carrying a permanently-dead relay URL, which is the self-inflicted DoS this
  work was told not to create. (b) The live cursor now moves only at re-anchor
  points (start / resume / delta subscribe / bucket re-issue) rather than
  continuously, so a long-lived desktop-style session replays more history on
  restart. On mobile `resume_after_background` fires every foreground and the
  catch-up sweep advances the same cursor independently, so freshness is
  unaffected.

* **The malformed-payload stall lever — CLOSED 2026-08-04, owner-directed.**
  A malformed 445 used to return `Unprocessable`, which HELD a generation's
  advance at an attacker-chosen low timestamp. Bounded to a stall (never a
  skip, never a regression, since the write is monotonic-max) and not new — the
  old contiguous-prefix rule stalled identically — but mintable at will.

  `PreAuthRejection::Malformed` now classifies it as SKIP. The justification:
  `event_to_transport_message` is a pure parse that runs BEFORE the engine, and
  a delivered event with a valid signature but unparseable content was *signed*
  that way, so it is substantively a pre-authentication rejection rather than an
  un-applied message.

  **The boundary is the load-bearing part.** Only failures from that pure
  pre-engine parse may take the arm. A failure originating in the engine, in
  decryption, or anywhere that has already touched key material must keep
  holding the cursor — reclassifying those would hand an attacker a SKIP
  primitive, which is the exact thing this whole item exists to prevent.

  Trade-off accepted explicitly: a genuine peer emitting an unparseable commit
  is now stepped over rather than stalling until someone notices.

* **The residual `Buffered` hold remains, and is correct.** An inbound event
  during this device's own publish-before-apply window still holds the
  generation's advance. That is not attacker-controlled in the same way and the
  hold is the right behaviour there.

* **The Dart poll path — DELETED 2026-08-04, not fixed.**
  `NostrCircleService.advanceGroupCursorToEventSecs` and its FFI
  `cursor_advance_group_to_event` advanced the bare `STREAM_GROUP_445` cursor
  straight from an event's `created_at`, with no clamp and no window. It was
  verified to have no reader — every REQ anchor uses the per-circle
  `group_cursor_stream(hex)` key — so it was write-only and could not interfere
  with the fix above.

  Deleting beat fixing. Dead code carrying a live defect is worse than either
  alone: the danger was never what it did, it was that someone would wire it up
  later without knowing it was unsafe. Zero references now remain in
  `haven-core/src`, `haven/rust_builder/src` or `haven/lib`.

* **The INBOX stream had the same hole, and it was the worst instance — FIXED
  2026-08-04.** `inbox_1059` was advanced straight from a gift wrap's outer
  `created_at`. Unlike the group poll path, **this stream is read**
  (`live_sync/session.rs` derives the inbox REQ floor from it).

  *The threat model is cheaper than the group case and open to the whole
  network.* A kind-1059 is routed by a `#p` tag carrying the recipient's public
  key — published in their kind-0 profile, their kind-10002/10050 relay lists
  and every kind-30443 KeyPackage — and their inbox relays are public too. The
  wrapper is authored by a throwaway ephemeral key **by construction** (NIP-59),
  so there is no author to check. The peel path consults **no MLS state** and
  nothing binds the outer `created_at` to the payload: it needs only a valid
  outer signature, a NIP-44 envelope to the victim's *public* key, rumor kind
  444, one 32-byte `e` tag and non-empty content. No KeyPackage fetch, no group,
  no real Welcome. Cost: one encryption and one publish.

  *And the consequence is total, not partial.* rust-nostr's
  `EventBuilder::gift_wrap` **backdates every wrap by 0–48 h**
  (`RANGE_RANDOM_TIMESTAMP_TWEAK = 0..172800`). Once a future-dated wrap parks
  the cursor ahead of the clock, `cap_timestamp_to_now` pins every later floor
  at `now` — below which even a wrap published *this second* falls. **Invitation
  delivery stops entirely**, permanently and across restarts, because the
  advance is monotonic-max and could never come back down.

  *Fix.* Dart's cursor write was deleted outright and the advance moved into
  Rust, mirroring the group plane: a new `InboxAnchor` opened at the inbox REQ's
  local clock reading and redeemed once on that REQ's EOSE. It deliberately has
  **no hold-back input at all** — `consume_eose(now_secs)` has no parameter a
  wrap timestamp could be threaded through in either direction, because an
  unpeelable wrap is the inbox's analogue of `RejectedBeforeAuth`, and letting
  it hold would sell anyone who knows the victim's npub a permanent stall for
  one free event. `wrap_created_at_secs` was removed from `LiveSyncEvent
  ::Welcome` and `FfiRelayEvent` entirely: it had no other consumer, and leaving
  a remote timestamp next to a cursor is the footgun.

  *A migration was required and is easy to miss.* Deleting the writer does
  nothing for an install that already took a poisoned value, and monotonic-max
  means it could never recover on its own. `CircleStorage::clamp_sync_cursor
  _down_to` (a conditional `UPDATE … WHERE last_synced_ms > ?`, never an upsert)
  is now called from `LiveSyncCore::repair_future_cursors` on every start, for
  the inbox and every subscribed group stream.

  *Two MORE instances found by the sweep*, both unused FFI writers, both
  deleted: the generic `cursor_advance` (let the foreground write any stream to
  any value) and `cursor_seed_if_unset` (could seed a fresh install's cursor to
  any value). **Nothing outside `haven-core` writes a cursor now**, and the
  guard bans `advance_sync_cursor`, `seed_sync_cursor_if_unset`,
  `STREAM_GROUP_445` and `STREAM_INBOX_1059` anywhere under
  `haven/rust_builder/src` — rename-proof, and it covers the whole class rather
  than the three instances.

  *Two things the original framing got wrong*, recorded so the next reader does
  not repeat them: `invitation_provider.dart` was NOT the exploitable writer —
  that poller runs only when `liveSyncEnabled == false`, and in that build
  nothing reads `inbox_1059` (its own `since` is a fixed `now − 2 d 1 h`). The
  live writer was `subscription_service.dart`'s `LiveEventRouter._handleWelcome`.
  And the 7-day lookback does not bound backward poisoning here — it is
  subtracted from a number already ahead of the clock.

  *One mutation survived and is reported as such:* an unconditional clamp to
  `now` is indistinguishable from the legitimate EOSE advance at the e2e level,
  since both land on the same value. It is caught at the storage layer, and the
  e2e test was renamed to what it actually proves.

* **The module docs were asserting a safety property that does not exist**, and
  are corrected. Both `catchup.rs` and `processor.rs` claimed the cursor "stops
  at the first `Buffered` (future-epoch) outcome". False twice over: a
  future-epoch application message is `Stale { PeelFailed }`, and `Buffered`
  actually signals *this device's* publish-before-apply transition.
  `cursor_ms_for_event` now carries a "NOT the cursor advance" warning so
  nobody reaches for it again.

* **`tests/live_sync_cursor_replay_e2e.rs` rewritten** around the corrected
  invariant (its header had pinned the vulnerable behaviour as intended), with
  restart-persistence coverage kept and extended. Three tests in
  `live_sync_engine_e2e_test.rs` and one delivery oracle in `session.rs` needed
  the same treatment: once the cursor moves on EOSE regardless of what was
  routed, a cursor assertion passes vacuously, so those oracles were re-anchored
  on decrypted `LiveSyncEvent::Location` instead.

* **Deliberately NOT done:** moving the expiration screen after MLS
  authentication. It is tractable, but it is not the stronger fix — the
  attacker still reaches the cursor gate via `Processed` and `PeelFailed`
  regardless — and it would run the crypto *before* the check on a screen
  whose stated purpose is defending against a malicious relay replaying stale
  ciphertext, while introducing a new correctness cliff (the receiver would
  re-derive the sender's expiration from its own view of a mutable, committed
  group component, silently discarding authenticated locations on a mismatch).

* **Not a risk:** infinite refetch of expired events. `nostr-database` refuses
  to save an expired event and filters expired events out of every query
  (`nostr-database-0.44.0/src/helper.rs:193,216`), so conformant relays
  genuinely evict; re-dropping is cheap and idempotent regardless.

---

## Workstream A — make "green" mean something

| # | Item | Status |
|---|---|---|
| A1 | `cargo test` + `--all-targets` clippy for `rust_builder` (31 tests at the time, 46 today, incl. 4 privacy oracles, never ran) | **DONE** |
| A2 | Wire orphaned `scripts/ci/check_no_tile_cache_secrets.sh` into repo-guards | **DONE** |
| A3 | Fail the run when tests *skip*; an all-skipped run is textually identical to an all-passed run | **DONE (host suites)** — see below |
| A3b | **Fail the run when tests FAIL but `flutter drive` exits 0** — CONFIRMED LIVE and **DONE 2026-08-02**. See below | **DONE** |
| A4 | `scan-logs-for-secrets.sh` exits 0 when its log files are absent — the crash case. 3 of 6 lane runners never invoke it. Extend `PATTERNS` to hex/base64/bech32 | **DONE 2026-08-03**. See below |
| A5 | Per-path coverage floors + a ratchet. The gate is a single global aggregate (80%/50%), so any critical file may sit at 0%. The Rust threshold also passes on a parse failure | **DONE 2026-08-03**. See below |
| A6 | iOS lanes retry on *any* failure with no flake classifier (`e2e-ios.yml:181,211`), unlike Android's narrow `is_connect_flake` | **DONE 2026-08-03**. See below |
| A7 | Poll/live-sync define leakage: 5 lanes omit the define and silently inherit `liveSyncEnabled = true` | **DONE 2026-08-03**. See below |
| A8 | 4 emulator lanes lack a coreutils `timeout` wrapper; several step caps sit below worst-case runtime (integration 35m vs ~84m) | **DONE 2026-08-03** — first half held, second half was backwards. See below |
| A9 | `haven-core` cannot take `--all-targets` clippy: 71 pre-existing lint errors in never-linted `#[cfg(test)]` code | **DONE** — the count was 123, not 71. See below |
| A10 | The vacuity floors keeping the E2E guards honest were hardcoded minimums, not repo-derived counts (≥10 steps / ≥8 drives against an actual 35 / 18) | **DONE 2026-08-09**. See below |

**A3 — skips are now declared, and the original counts were wrong in both
directions.** The measured surfaces, from real runs on a clean tree:

| Surface | Skips | What they are |
|---|---|---|
| `haven-core` `cargo test` | **21** | 4 live-Blossom round trips, 3 real-OS-keyring SQLCipher openers, and **14 ```` ```ignore ```` doctests** — a surface the item never mentioned |
| `haven/rust_builder` `cargo test` | **5** | real-OS-keyring twins of FFI tests that run in-memory |
| `haven` `flutter test` | **22** | 19 pseudo-locale sweep (gated on the deliberately uncommitted `app_en_XA.arb`) + 3 `Platform.isAndroid` permission cases |

All 26 Rust and 22 Dart skips classify as **legitimate**: every one is gated on
an environment fact a hosted runner cannot supply, and all but the pseudo-locale
sweep have a sibling that DOES run and asserts the same invariant
(`storage_encrypted_opens_or_reports_keyring_unavailable`, the in-memory keyring
twins, T9–T11's `isAndroid` seam). None was an accidental disablement. The two
findings worth carrying: the 14 ignored doctests are unverified API prose that
no reporter had ever named (```` ```no_run ```` would at least compile them),
and *nothing in the repo asserted any of these counts* — the entire set could
have gone to zero silently.

Enforced by `scripts/ci/check_no_undeclared_skips.sh` against
`scripts/ci/expected_test_skips.txt`, wired into the jobs that already run the
tests: all three `rust-check.yml` cargo jobs — `haven-core`, `rust_builder`, and
the `e2e-tooling` job added since (`tooling/e2e/local-relay`, surface
`e2e_tooling`, currently zero declared skips) — (`cargo test | tee`, `set -o pipefail`
so `tee` cannot eat the exit code) and `coverage.yml`'s Flutter job (via
`--file-reporter=json:` — a second reporter alongside the console one, so it
costs no extra run). `repo-guards.yml` carries only the hermetic `--self-test`
(14 fixtures). Failure is symmetric: an undeclared skip fails, and so does a
manifest entry no longer matched, because a stale allowance means the proof it
guarded is gone. The reason string is matched verbatim, so a gate changing cause
(keyring → "flaky") is also a failure. The extractor cross-checks its own parse
against the `N ignored` summaries, so it cannot rot into "0 skips, all
declared".

**Corrections to the item as written.** "~15 keyring-gated proofs" is 11
(3 + 5 keyring, plus 4 Blossom) and misses the 14 doctests entirely. "8 of 10
`e2e_combined` tests" does not hold: `e2e_combined.dart` declares 2
`testWidgets` and contains **zero** `markTestSkipped`. The real integration
figure is **24 of 55** `testWidgets` under `haven/integration_test/` carrying a
`markTestSkipped` escape hatch, concentrated in `relay_customization_publish`
(5/6), `relay_resync_convergence` (3/4), `encryption_pipeline` (2/3) and
`circle_service_remove_member` (2/4) — plus every B-series lane target added
since, each of which is 1/1 or 2/2.

**Still open: the `flutter drive` half.** A skip there is *invisible to the
driver by construction* — a `testWidgets` body that calls `markTestSkipped()`
still completes, so the binding records `_success` and `integrationDriver()`
cannot distinguish it from a pass. `Response.toJson` serializes only failures,
so no driver-side backstop is possible either. The only signal is the `~N`
column of the device reporter forwarded into the drive log, which
`drive-log-lib.sh` already tolerates but does not assert on. Asserting `~0`
there is a one-line predicate, but which of the 24 actually skip on an emulator
is unknown without a run, and guessing wrong turns honestly-green lanes red —
the exact inverse mistake recorded in A3b below. Left for a run that can
measure it.

*Re-verified 2026-08-07:* still open. `DRIVE_LOG_FAILURE_RE`
(`drive-log-lib.sh:74`) tolerates the `~N` column but asserts nothing on it, and
nothing in `tooling/e2e/ci/` or `.github/workflows/` asserts `~0` on a drive log.
The declared-skip counts the manifest pins do still reconcile exactly: `haven-core`
reports 21 ignored, `rust_builder` 5, `flutter test` `~22` — all three matching
`scripts/ci/expected_test_skips.txt` row for row.

**A3b — the worst instance of "green means nothing" found so far, and it was
live in `main`.** In CI run 30753193231 `e2e_profile_android` reported SUCCESS
while its `setUpAll` threw. The drive log contains, in order:

```
I/flutter ( 3849): 00:01 +0: (setUpAll) [E]
I/flutter ( 3849):   set_profile_relays_for_test already installed
All tests passed.                          <- the DRIVER
I/flutter ( 3849): 00:01 +1 -1: Some tests failed.   <- the APP
```

and the harness logged `flutter drive attempt 1/3 (rc=0)`.

Mechanism: `package:integration_test`'s binding records per-test results only
for `testWidgets` bodies, so a failure in `setUpAll` / `tearDownAll` never
enters the map `integrationDriver()` inspects — it reports pass and exits 0.
**Anything failing outside a `testWidgets` body was invisible to every
`flutter drive` lane in this repo.** The identical scenario failed correctly on
iOS, which runs under `flutter test -d <udid>`; that platform split is what
exposed it.

Fixed by `tooling/e2e/ci/drive-log-lib.sh`: a shared predicate that reads what
the APP said rather than trusting the exit code, sourced by
`run-single-avd-scenario.sh` (which `run-integration-tests.sh`,
`run-relay-customization.sh` and `run-flake-stress.sh` all delegate to),
`run-m7-background-catchup.sh`, `run-b1-fgs-publish.sh`, and every direct
`flutter drive` runner added since (`run-b3`, `run-b5`, `run-b6`, `run-b8`,
`run-b9`, `run-kp-rotation`). The iOS runner does not need it as an exit-code
backstop but consumes it anyway: `ios-flake-lib.sh` reuses the predicate as one
of the four conditions its retry gate requires.
Self-tested in `repo-guards` with the verbatim run-30753193231 log as the
critical fixture. Verified at adoption that no other Android lane in that run
carried a swallowed failure, so the guard reddened nothing that was honestly
green.

**Lesson worth carrying forward: a green library self-test proved nothing about
the wiring.** Adversarial review found the predicate was being run over the
ACCUMULATED retry log rather than the final attempt's slice
(`run-single-avd-scenario.sh` truncates once before the retry loop and appends
per attempt). A pre-connect stall is retried WITHOUT consulting
`is_connect_flake`, and reporter output provably precedes `CONNECT_MARKER`, so
attempt 1 could legitimately contain `Some tests failed.`, be retried, and
poison a clean attempt 2 — turning honestly-green runs red, i.e. the exact
inverse of the bug being fixed. All 6 library fixtures passed throughout,
because the predicate was correct and only the bytes handed to it were wrong.
The runner's own `--self-test` now covers the wiring (fixtures 5a/5b/5c: the
accumulated log MUST look failing, the scoped slice MUST NOT, and offset 0 MUST
return everything). When adding a guard, test the call site, not just the
predicate.

The predicate itself also gained: ANSI-escape stripping (the reporter colourises
the counter and `[E]`, which would have silently collapsed four signals to one
if `_Reporter(color: false)` upstream ever changed), an end-of-line terminator
for counters truncated mid-line by a timeout kill, tolerance of the `~N` skipped
column, and `All tests skipped.` — because `integrationDriver` reports an EMPTY
results map as all-passed, so a target that declares no `testWidgets` at all was
green in every drive lane.

**A4 — "nothing to scan" was reported as "nothing leaked".** `scan_file` opened
with `[[ -f "${file}" ]] || return 0`, and `main` printed `skipping non-existent
path` before exiting 0 via a `nothing to do` branch. So the crash case — a lane
that died before writing its logs — read as a clean privacy verdict. An
unscannable log is now its own failure class with its own exit code (**3**),
distinct from clean (0) and leaking (1), so triage can tell "we found no
material" from "we found no evidence" without parsing prose.

*Empty counts as absent, deliberately.* `cmd > file &` creates the file at
redirection time, before the command writes a byte, so a lane that dies just
after starting its logcat leaves a zero-byte log while one that dies just before
leaves none — the same crash in two states, decided by scheduling. Failing one
and passing the other would make the verdict on an identical failure a coin
flip.

*Wiring.* The three runners that omitted the scanner
(`run-integration-tests.sh`, `run-relay-customization.sh`,
`run-flake-stress.sh`) are all orchestrators that delegate every drive to
`run-single-avd-scenario.sh`, which does scan. That is not sufficient: the inner
runner scans only if it *reaches* its scan, and it runs under `set -e` from the
moment it starts logcat (plus two earlier `exit 2` argument guards), so a build
/ install / config failure exits before scanning — and the orchestrators then
`cp` those never-scanned logs into a `LOG_DIR` the workflow uploads with 14-day
retention. All three now re-scan. `run-flake-stress.sh` is scoped to its
failing-iteration branch because it preserves logs *only* there; an
unconditional scan would hit an empty `LOG_DIR` and redden every green run.

*Two conflations fixed on the back of the new exit code.* `run-b1-fgs-publish.sh`
and the `e2e-fgs-publish.yml` diag step both deleted logs on *any* non-zero
scan. Under rc 3 that would have destroyed the truncated crash artefacts triage
most needs, while labelling them "withheld: secret-leak guard tripped".
Containment now fires on rc 1 only.

`PATTERNS` already covered bech32 (pattern 3, long-standing) and hex / base64
(patterns 5 and 6, added for the FGS lane alongside pattern 7); no extension was
required.

**A5 — both halves of the premise held, and the Flutter half is worse than
"may sit at 0%": three services already do.** Measured from real reports on a
clean tree (`cargo llvm-cov --all-features --lcov`, `flutter test --coverage`):

| Stack | Aggregate | Gate | Slack |
|---|---|---|---|
| haven-core | 90.74% (19419/21400) at pinning; ~91.7% today | 80% | ~2290 → ~2700 lines |
| haven | 64.82% (6944/10712) at pinning; 66.40% (7477/11261) today | 50% | ~1588 → ~1850 lines |

2290 lines is more than any single file in haven-core, so `src/nostr/mls/
manager.rs` (853), `src/nostr/giftwrap.rs` (207) and all of
`src/nostr/encryption/` (126) could go to zero *together* with the gate still
green. Rust's weak points AT PINNING TIME were `src/relay/catchup.rs` **28.50%**
(the same file as the open `limit(512)` defect, `catchup.rs:160`),
`src/relay/auto_commit.rs` 50.85%, `src/location/nostr.rs` 52.54%,
`src/relay/manager.rs` 71.59%. **Three have since been closed and re-pinned** —
catchup.rs 97.14% (floor 95), auto_commit.rs 100.00% (floor 100), manager.rs
75.64% (floor 73) — which is the ratchet working. `src/location/nostr.rs` (~52%)
is the one still open, and `limit(512)` remains uncovered.

Flutter was the literal case the item described (→ shows movement since pinning):

| Path | Coverage |
|---|---|
| `lib/src/services/nostr_relay_preferences_service.dart` | **0.00%** (0/88) — unchanged |
| `lib/src/services/nostr_relay_service.dart` | 0.63% (1/158) → 17.20% (32/186) |
| `lib/src/services/background_location_task.dart` | 1.69% (4/236) → 11.63% (30/258) — the file P0-1 lives in |
| `lib/src/services/nostr_circle_service.dart` | 11.76% (60/510) |
| `lib/src/services/nostr_profile_service.dart` | 23.33% (21/90) |
| `lib/src/services/background_catchup_worker.dart` | 27.71% (23/83) |
| `lib/src/services/nostr_identity_service.dart` | 31.07% (32/103) |
| **`lib/src/services/` (whole layer)** | **48.96%** (1317/2690) → **53.57%** (1584/2957) |

When these floors were pinned, the service layer — every relay connection, every
MLS call, the background publisher — measured 48.96%, *below the 50% threshold
the package passes*, because the widget and provider suites paid for it out of
the shared budget. It has since crossed 53%. At 2957 instrumented lines one point
is ~30 lines, so a single new uncovered file still moves it several points.

The second half held too, and is verified: with `COVERAGE` empty,
`echo " < 80" | bc -l` writes a syntax error to stderr and nothing to stdout,
`(( ))` on the empty string is false, and the job printed
"✅ Coverage % meets threshold 80%" and exited 0. Every way of losing the number
reported success.

*What was built.* `scripts/ci/check_coverage_floors.sh` + the checked-in
manifest `scripts/ci/coverage_floors.txt` — 30 Rust and 24 Flutter paths, each
pinned at `floor(measured) - 2` (or exactly 100 where fully covered), enforced
against the same lcov the aggregates read. The aggregate gates are untouched;
this is additive. The Rust threshold step now validates the parsed value's shape
and runs under `pipefail`.

Three properties make it more than a floor:

* **A ratchet.** Exceeding a floor by ≥5 points fails, naming the number to
  write down. A floor nobody raises silently becomes vacuous — it licenses a
  regression to a level the code left releases ago while still reading as
  protection.
* **100% is pinned exactly.** The margin rule is arithmetically unable to fire
  on a fully covered path (there is no 103%), so `src/nostr/tags.rs` (the
  kind-445 tag allowlist), `src/nostr/mls/welcome.rs` (Rule 3: kind 444 stays
  unsigned), `fresh_secret.dart` (Rule 9) and `live_sync_resubscriber.dart` are
  pinned at 100 and ratchet if pinned lower.
* **A stale entry is a hard failure.** An entry matching no file measures
  nothing, so it can never be below its floor — the skip manifest's lesson
  (`check_no_undeclared_skips.sh` rule 2) applied to coverage. This also covers
  the Dart-specific trap that a lib file no test *imports* is ABSENT from lcov,
  not 0%, and thus invisible to the aggregate in both directions.

One row is still pinned at 0 by arithmetic (`nostr_relay_preferences_service.dart`,
0/88); the other two near-zeros have since ratcheted up
(`background_location_task.dart` to 9, `nostr_relay_service.dart` to 15). That is the
point: the number is now written down in a reviewed file instead of hidden
inside a green aggregate, and the ratchet fires the moment anyone covers 5%.

*Verification.* 31 hermetic self-test fixtures (wired into repo-guards per that
workflow's convention); the guard green against both real reports; **15 mutation
tests** — 5 perturbations of the real lcov (hollowing `mls/manager.rs`, dropping
one line from `welcome.rs`, improving `catchup.rs` to 59%, deleting a pinned
file's record, hollowing `location_sharing_service.dart`) and 10 mutations of
the guard's own logic (inverted comparison, off-by-one boundary, deleted ratchet,
deleted 100% rule, neutered stale check, neutered zero-line check, deleted
empty-manifest check, broken SF extractor, deleted parser-rot guard, ignored
margin override, last-file-wins aggregation, tolerated missing report) — **all
15 killed**. `--list` round-trips to the checked-in floors exactly, margin
overrides included.

*Superseded in part, 2026-08-04.* The floors work above was hardened after a CI
red (run 30964250098) caused by three HAND-EDITED floors sitting 0.06–0.72 points
above their measured values. The manifest is now maintained by two commands and
never by hand: `--lint [--fix]` (the static pin rule, wired at
`repo-guards.yml:462` and in the pre-commit hook) and `--repin <stack> <lcov>`
(raises only, never lowers). The measuring toolchains are pinned in
`scripts/ci/coverage_toolchain.env` (rustc 1.97.1 / Flutter 3.44.8), because a
coverage percentage's denominator is a compiler property, not a test property.
The Flutter aggregate moved out of inline `bc` into the shared
`scripts/ci/check_lcov_aggregate.sh` (`coverage.yml:247`); the Rust one is still
inline but shape-validated. One local gate, `scripts/ci/check_coverage.sh`, now
runs every check `coverage.yml` does.

**A7 — the count was right, the diagnosis was one lane short of the damage.**
"5 lanes omit the define" holds exactly for the E2E lanes: `e2e-integration`,
`e2e-background-catchup`, `e2e-relay-customization`, `e2e-profile` (Android job)
and `e2e-flakiness-stress` all built with no `--dart-define=HAVEN_LIVE_SYNC` and
therefore compiled `liveSyncEnabled = true`. Two *non*-lane workflows omit it
too — `build-check.yml` and `release-build.yml`, 7 workflows and 9 build
invocations in all — but those are correct omissions and are now declared as
such rather than fixed (below).

*The axis was never imaginary.* The worry the item implies — that the poll
variants are lying — does not hold. The dedicated poll lanes are the `e2e_android`
/ `e2e_ios` jobs `ci.yml` calls with no `with:`, and both reusable workflows
default `live_sync: false` and *pass that value explicitly* at the build. Poll
coverage of `e2e_combined` is real. What leaked was the mode of the five lanes
that were never about the receive path at all.

*Nor is there a build-vs-drive split to fix.* Android bakes the define at build
and drives a fixed APK (`flutter drive` never re-passes dart-defines); iOS builds
and drives in one `flutter test -d <udid>`. A drive step cannot set the value, so
there is no lane passing it at one and not the other.

*One lane's inherited value was actively wrong, and expensive.*
`e2e-flakiness-stress` inherited `true`, so since the Phase-B flip it has been
running the ten M11 live-sync scenarios inside a budget derived entirely from the
poll path: its header says it mirrors `e2e-android.yml`, its envelope cites "the
~12-minute `e2e_combined` ceiling", and each iteration gets
`run-single-avd-scenario.sh`'s default 20-minute `DRIVE_TIMEOUT` — against a
suite `e2e-android.yml` explicitly widens to `HAVEN_DRIVE_TIMEOUT=28m` under a
45-minute wrapper. Nightly run 30733446211 shows iterations reporting `+15 -1` /
`+14 -2` (the LIVE test count) and failing on `[MapShell] live-sync start error:
... an MLS session is already open on this database (Rule 14)`; the schedule was
red on 8 of the last 12 nights. It is now `false` — the value its own design
document asks for. No coverage moves: the live suite is a required PR gate in its
own right, sized for itself, and stressing the live path at 28 min × 10
iterations does not fit this job's 330-minute envelope anyway.

*One lane ran two modes at once.* `e2e-profile` built its Android job from Dart's
default (live) and its iOS job from `run-ios-sim-scenario.sh`'s default (poll) —
one lane, one scenario file, two receive paths, neither stated anywhere. Both
halves are green on those values, so both are now written down as-is rather than
unified: flipping iOS to `true` is the production-parity option and is the change
that risks turning a required gate red, so it is left as an owner decision with
the rollback spelled out in the workflow.

*The fix is "no build without an answer", not "pass the define everywhere".*
Every E2E lane now declares its mode in the job `env:` and bakes it at the build.
`build-check.yml` and `release-build.yml` deliberately still pass none — they
build the SHIPPED artifact, whose receive path must come from
`live_sync_provider.dart`'s `defaultValue`, since that const is the documented
one-line M11 §8 rollback lever (pinned by check 14b of
`check_m7_native_wake_guards.sh`). A literal define there would silently outrank
it: a rollback would flip production while CI kept building and blessing the
abandoned path. They declare the *decision* instead, with the token
`HAVEN_LIVE_SYNC-INTENT: production-default`, honoured in those two files only.

*Enforced by* `scripts/ci/check_live_sync_define_declared.sh` (repo-guards, plus
its `--self-test`, 20 fixtures). Check 1 is JOB-scoped, not file-scoped —
`e2e-profile` is why: a file-level check would have let one job declare while its
sibling inherited, which is the defect that shipped. Check 2 pins that the shared
wrappers still FORWARD the define, because a workflow can declare a value that
`build-integration-apks.sh` quietly stops passing, and check 1 would stay green
through it. Comments and `--self-test` invocations are stripped before matching
in both directions, so a job can neither be accused of building because it
mentions a build, nor credited with declaring because it discusses a value.

*Belt and braces at runtime.* EVERY wrapper that compiles the app —
`build-integration-apks.sh`, `run-ios-sim-scenario.sh`, the local-fallback
builds in `run-single-avd-scenario.sh` / `run-m7-background-catchup.sh`,
`scripts/run_e2e_local.sh`, and the per-lane builders added since
(`build-b3-real-gps-apk.sh`, `build-kp-rotation-apk.sh`) — REQUIRES
`HAVEN_LIVE_SYNC` and fail closed on
unset or non-`true`/`false`. The former `:-false` default in the iOS runner was
the last place a caller could decline to answer, and `e2e-profile`'s iOS job was
taking it. `run-single-avd-scenario.sh`'s requirement is scoped to its fallback
branch only, so the CI drive path — which cannot influence a compiled-in define —
is untouched.

**A9 — DONE, and the count in the item was low.** `rust-check.yml` now runs
`cargo clippy --all-targets -- -D warnings` on all three crates (`haven-core`,
`rust_builder`, `tooling/e2e/local-relay`), and the working tree is clean under it. The real figure was **123** findings, not 71: bare
`cargo clippy` selects `--lib`/`--bins` only, so this crate's `#[cfg(test)]`
modules AND its ~29 `tests/*.rs` integration targets (32 today) were never linted.
`--all-targets` also pulls in dev-dependencies, which turns on the `test-utils`
feature — so it lints the `#[cfg(feature = "test-utils")]` lib surface (e.g.
`SessionManager::new_unencrypted`) that bare clippy never compiles either.

The most consequential class among the 123: **24 discarded `#[must_use]`
`StopOutcome`s**. A discarded `TimedOut` reports a drain that did not happen —
the same fail-open shape as the session-teardown bug the `#[must_use]` was
added to catch, sitting unlinted in the tests written to prove it.

**A8 — the wrapper half held; the "caps too low" half was backwards, and the
real defect is its mirror image.**

*The wrapper count was right.* Of the six Android emulator lanes that existed
when the item was written, exactly four ran their drive with no coreutils
`timeout` at all: `e2e-integration`, `e2e-relay-customization`,
`e2e-background-catchup` and `e2e-flakiness-stress`. Only `e2e-android` and
`e2e-profile` had one. A fifth joined since — `e2e-fgs-publish`, created
2026-08-02 — so the count at implementation time was 5 of 7. This matters
because the step cap is not a substitute: on a `reactivecircus/android-emulator-runner`
step it does not reliably reap the action's backgrounded emulator/adb/drive
subtree (recorded in `e2e-android.yml` from runs 28056995601 and 28065762568,
where a hang ran the full ~45 min past a 30-minute step cap to the 60-minute job
cap), and a job-cap death SIGKILLs the runner before every `if: failure()` step —
no logcat, no drive log, no relay log. An unbounded drive step routes every hang
to that outcome.

*No step cap sits below worst-case runtime.* Measured from the GitHub Actions
API across the last 45 `ci.yml` runs (successful steps only):

| Lane | n | p50 | p95 | max | step cap |
|---|---|---|---|---|---|
| `e2e-integration` | 31 | 4.3m | 4.8m | 4.9m | 35m |
| `e2e-android` (poll) | 21 | 4.8m | 5.1m | 5.1m | 30m |
| `e2e-android` (live-sync) | 18 | 6.0m | 6.7m | 6.7m | 55m |
| `e2e-background-catchup` | 33 | 5.5m | 6.8m | 7.2m | 40m |
| `e2e-profile` (Android) | 27 | 2.3m | 2.7m | 2.7m | 30m |
| `e2e-relay-customization` | 34 | 5.8m | 6.5m | **25.8m** | 35m |
| `e2e-flakiness-stress` | 8 | 43.7m | 59.4m | 59.4m | 320m |
| `e2e-ios` `e2e_combined` (poll) | 21 | 18.4m | 24.9m | 25.3m | 65m |
| `e2e-profile` (iOS) | 23 | 15.2m | 32.8m | 34.1m | 65m |

Integration's healthy max is **4.9 minutes against a 35-minute cap** — 7x
headroom, not "35m vs ~84m". The ~84m figure is not a runtime at all; it is the
lane's theoretical *inner* budget (7 targets x a 10m per-drive timeout, plus
overhead). So the item inverted its own finding: the problem was never a cap
below the runtime, it was an **aggregate inner budget above the cap**. With
7x10m of inner bounds under a 35m step cap, a degraded run cannot let its own
per-target timeouts play out — GitHub kills the step first, anonymously. The fix
is an aggregate deadline between them, which is what the wrapper now is.

*Three genuine cap defects the item did not name.*

1. **`e2e-integration`'s APK-build step cap was 45 — equal to its job cap.** An
   equal cap can never fire first, so a hung Gradle build died at the job cap
   with no diagnostics: an inoperative bound that reads, in review, exactly like
   a working one. Build measured p95 14.7 / max 15.4m over 27 runs; now 35.
2. **`e2e-relay-customization`'s job cap was the thinnest envelope in the repo.**
   26 successful runs: p95 21m, **max 40m against a 45m cap** — 89% of its own
   cap on a run that went *green*. The 40-minute run is explained by the 25.8m
   step outlier above: one target wedged on cold attach, burned the full 20m
   per-drive default it inherited from `run-single-avd-scenario.sh`, and passed
   on the retry the lane is designed to make. Job cap now 60 (1.5x observed max),
   and the per-drive default is now 10m in `run-relay-customization.sh`, matching
   its structural sibling `run-integration-tests.sh` — at 20m that retry could
   not complete inside any deadline that also fits under the job cap.
3. **The `Create AVD snapshot` steps (7 lanes then, 13 today) and the
   `Boot iOS simulator` steps (2 then, 4 today) had no bound of any kind** — not a wrapper, not a step
   cap, not an `emulator-boot-timeout`. A step whose entire job is booting an
   emulator, with nothing bounding the boot, and boot is the most common
   emulator hang. Measured 91-130 s (Android snapshot, 23 runs) and 136-215 s
   (iOS boot, 32 runs); both now capped at 15 min with a 7-minute
   `emulator-boot-timeout` on the Android side.

*Two lanes that HAD a wrapper had it wired so the inner bound could never fire.*
`e2e-android`'s poll path paired a **20m** `HAVEN_DRIVE_TIMEOUT` with a **16m**
outer wrapper, and `e2e-profile`'s Android drive inherited the same 20m default
under the same 16m wrapper. The outer SIGTERM always landed first, so
`run-single-avd-scenario.sh`'s attributable `flutter drive for X exceeded 20m`
was unreachable and every poll hang surfaced as a bare rc=124. Worse, the
harness's own documented retry budget — `(DRIVE_MAX_ATTEMPTS-1) x
CONNECT_WATCHDOG + DRIVE_TIMEOUT + overhead = 2x5 + 20 + 3 = 33 min` — did not
fit under 16 minutes either, so a run that hit the connect watchdog twice and
then recovered was killed mid-recovery. Both are now 12m inner / 26m wrapper
(budget 2x5 + 12 + 3 = 25), which fits. Net effect on a plain hang: it now dies
at ~13 min **named** instead of at 16 min anonymous.

*What landed.* `tooling/e2e/ci/run-with-deadline.sh` is the shared inner bound —
a coreutils `timeout` plus a banner naming the lane, because a raw `timeout`
that fires prints nothing and reads identically to a dozen other failures. It
distinguishes its own deadline from a command that exited 124 on its own (an
inner per-drive timeout propagating up) by elapsed time, so triage is never sent
to the wrong bound. Every Android lane now runs its drive under it. The iOS
lanes keep `nick-fields/retry`'s `timeout_minutes` — the macos-* runners have no
GNU `timeout` — and were already correctly ordered.

The resulting ladder, verified by the guard on every lane (which now covers 35
emulator/simulator steps and 18 drives; the table lists the lanes that existed at
the time — every lane added since inherits the same shape):

| Lane | per-drive | deadline | step cap | job cap |
|---|---|---|---|---|
| `e2e-android` (poll) | 12m | 26m | 35 | 60 |
| `e2e-android` (live-sync) | 28m | 45m | 55 | 90 |
| `e2e-profile` (Android) | 12m | 26m | 35 | 60 |
| `e2e-integration` | 10m | 25m | 35 | 45 |
| `e2e-relay-customization` | 10m | 25m | 35 | 60 |
| `e2e-background-catchup` | 10m | 30m | 40 | 60 |
| `e2e-fgs-publish` | 18m | 25m | 35 | 70 |
| `e2e-flakiness-stress` | 20m | 310m | 320 | 330 |
| `e2e-ios` `e2e_combined` | 30m x2 / 45m x2 | (retry action) | 65 / 95 | 90 / 155 |
| `e2e-ios` bg-mirror | 20m x2 | (retry action) | 45 | 90 / 155 |
| `e2e-profile` (iOS) | 30m x2 | (retry action) | 65 | 90 |

Step caps must CLEAR `deadline + 1m kill grace + 7m emulator boot`, which is the
arithmetic `e2e-android.yml` already did by hand; the guard now enforces it as a
strict lower bound rather than leaving it maintained by hand (real caps sit 1-2m
above the sum, e.g. 26+1+7=34 against a 35 cap).

*Kept true by `scripts/ci/check_e2e_step_timeout_ordering.sh`* (repo-guards),
which fails on: a drive step with no inner deadline (C1); an inner budget at or
above the step cap (C2); any step cap at or above its job cap (C3); a per-drive
timeout at or above the deadline that would preempt it (C4); an
emulator/simulator step with no cap or no boot timeout (C5). Both branches of
every `${{ inputs.live_sync && A || B }}` are checked, so a lane cannot be
correct in one variant and broken in the other.

**A10 — the anti-vacuity floor was itself vacuous, FIXED 2026-08-09.** The guard
refused to pass on fewer than 10 emulator/simulator steps or 8 drives. That is
the wrong SHAPE, not merely the wrong number: it was written when the repo had
~11 lanes, and by 35 steps / 18 drives the extractor could have lost two thirds
of them and still cleared it. A floor that does not move with the repo stops
being a floor.

It is now derived FROM the repo, by a different mechanism than the extractor
uses — the extractor parses workflow YAML into per-step records and classifies
them; the check greps the raw files for the marker strings. Two independent
readings of one source, so when the record parser rots the grep still sees the
lane and the mismatch NAMES it. Three layers:

* **an exact count** — `uses:` appears exactly once per step, so the number of
  `reactivecircus/android-emulator-runner` lines *is* the number of emulator
  steps (26 today). Not a floor, an equality.
* **set coverage** — every workflow carrying an emulator/simulator marker must
  contribute at least one counted step, reported by filename.
* **set coverage for drives** — same argument one level down, so a broken
  `is_drive_body()` cannot leave C1/C2/C4 silently asserting nothing.

Full-line comments are stripped first, exactly as the extractor strips them from
step bodies: a commented-out `uses:` line would otherwise read as a lane the
extractor had lost, and a guard that reds on a correct repo gets deleted rather
than fixed. `repo-guards.yml`'s hermetic `--self-test` invocations carry the same
marker strings and are excluded for the same reason.

Six hermetic fixtures (18 cases total, up from 12), and the check was
mutation-tested in both directions: neutering any of the three layers, dropping
either file-set accumulator, or removing the comment stripping is caught by the
self-test ALONE — no real repo needed. Breaking `is_emulator_step`,
`is_simulator_body` or `is_drive_body` against the real tree is caught too, each
naming the lanes that went dark. 12 hermetic fixtures, each a lane shape that
actually occurred here; both it and the wrapper are mutation-tested.

*Not addressed, deliberately.* The iOS poll `e2e_combined` attempt cap (30m) sits
above its measured max (25.3m) but by only ~18%. It has not produced a false red
and widening it cascades into the step and job caps, so it is left as a
watch-item rather than a change without a failure to justify it.


**A6 — the premise held, and the evidence is stronger than the item claimed.**
`e2e-ios.yml:181,211` are the two `max_attempts: 2` lines, and neither step (nor
`e2e-profile.yml`'s iOS job, a **third** retry site the item missed — five sites
today, all narrowed the same way) sets
`retry_on`, so `nick-fields/retry`'s default `any` applied: every non-zero exit
was retried, a genuine assertion failure exactly like a simulator that never
launched.

*Measured, not assumed.* 97 iOS jobs / 156 attempts pulled from `gh api
.../actions/jobs/<id>/logs` (2026-07-13 → 2026-08-03):

| What attempt 1 did | Attempts | Retried? |
|---|---|---|
| Failed fast with reporter output naming the failure | 19 | yes, every one |
| Built, then never emitted a single reporter line, until the attempt timeout | 8 | yes — 4 then went GREEN |

The 19 include `::error::9 tests passed, 1 failed.` (job 89823392716), the FE-2
member-count `TestFailure` (job 88159861218) and the `set_profile_relays_for_test
already installed` setUpAll throw (job 91511139791, run 30753193231 — the same
failure that exposed A3b on the Android side). No observed green was ever
*produced* by retrying one of those, but nothing prevented it; each also cost a
full ~7-11 min Xcode rebuild.

The 8 are one signature, every time: `Xcode build done. <N>s` followed by
silence. That is the "~10% iOS-simulator launch/attach flake (presents as a HANG,
not a fast fail)" the workflow comments already asserted — now confirmed at ~5%
of attempts, always post-build and always pre-test.

*What was built.* `tooling/e2e/ci/ios-flake-lib.sh` — the iOS twin of
`is_connect_flake`, admitting that ONE signature and nothing else. It requires
four independent things before calling a failure retryable: a marker written by
our own watchdog, evidence the build completed, no trace anywhere that a test
ran (both reporters — CI gets test_core's GitHub reporter, `::group::✅` /
`🎉 N tests passed.`, which shares not one literal with the compact reporter),
and silence from `drive-log-lib.sh`'s independent app-side predicate, reused
rather than reimplemented.

*A log alone cannot tell a stall from a mid-suite kill*, so
`run-ios-sim-scenario.sh` now runs a first-test watchdog: once `Xcode build
done.` appears, the suite has 300 s to say anything (measured build-done → first
reporter line is 32 s median / 53 s p90 / 94 s max over 164 attempts). It kills
and marks a stall instead of letting the outer timeout swallow it anonymously.
It deliberately does not bound the BUILD — a hung build is deterministic, and
retrying it hides it.

*`nick-fields/retry` has no predicate input*, so the refusal lives in the command
it re-runs: a per-scenario verdict file, stamped `unproven` **before** the suite
starts and upgraded to `retryable` only by an attempt that reached classification
and proved the stall. Anything else — a genuine failure, a crash, an
outer-timeout SIGKILL, an unparseable verdict — makes attempt 2 exit immediately
with the original code. Fails closed: absence of evidence is not evidence of a
flake, which is A4's lesson pointed the other way.

*Gated by two `--self-test`s in `repo-guards.yml`* (19 predicate + 8 gate + 2
recording fixtures; 7 watchdog fixtures). The watchdog set drives the REAL
watchdog against a stubbed process and then hands its output to the REAL
classifier, so the marker one writes and the marker the other requires cannot
drift apart. Mutation-tested: 16 of 18 mutations are caught, and the 2 survivors
are the deliberately-redundant pair of activity checks inside one loop iteration
— removing BOTH is caught, and no hermetic fixture can separate them.

---

## Workstream B — location reliability

**Nothing in CI exercises real location acquisition.** Every scenario injects
`FakeLocationService`, whose `getLocationStream()` yields one position then
completes (`haven/integration_test/e2e/_lib/fake_location_service.dart:47`), so
stream-lifecycle bugs — the class behind the iOS background regression — are
structurally untestable. Below the Dart `GeolocatorWrapper` mock nothing tests
the platform channel, `AppleSettings`, or the Android FGS.

**Trap that governs every scenario below — found building B1, 2026-08-02.**
`flutter_test` **unmounts the widget tree on a PASSING test**
(`flutter_test/lib/src/binding.dart:1684-1691`,
`runApp(Container(…)) // Unmount any remaining widgets`, guarded only by
`_pendingExceptionDetails == null`). `IntegrationTestWidgetsFlutterBinding` does
not override it. So any scenario that expects app state to survive *past* the
drive is building on sand: the `ProviderScope` is disposed, which fires
`backgroundServiceLifecycleProvider`'s `ref.onDispose(() => fns.stop())` and
**stops the foreground service**, and `_MapShellState.dispose()` removes the
lifecycle observer so a later `adb shell input keyevent HOME` never reaches
`_onPaused()`. Any scenario needing a real pause must deliver it **inside** the
test body — `tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused)`
runs MapShell's genuine `didChangeAppLifecycleState` → `_onPaused()` — and hold
the body open while the assertion window runs. Applies to B1 and to B5–B9.

Second trap, same origin: the FGS's foreground-active gate goes stale after
`2 * kBackgroundRepeatInterval` = 144s. Once the UI is gone the flag ages out and
the FGS publishes happily — **from a fresh process with no foreground session at
all**, which passes a naive oracle while exercising none of the contention. Any
scenario asserting cross-isolate behaviour must prove same-process identity (the
PID column of `logcat -v threadtime` is enough).

| # | Scenario | Mechanism | Est. |
|---|---|---|---|
| B1 | FGS-with-live-foreground (catches P0-1) — **IMPLEMENTED 2026-08-02**, `e2e-fgs-publish` lane. **P0-1 was REPRODUCED on the first run**; green since (CI 31216078806, 2026-08-07) | in-drive lifecycle pause, then: `Initialized (… locationSharing=true)` present (positive Rule-14 oracle, not an absence check), `onStart FAILED` absent, `Published to N/…` N≥1 **parsed and windowed to after the pause**, and publishing PID == handoff PID | ~5m |
| B2 | **Background delivery assertion — IMPLEMENTED 2026-08-03.** The premise held exactly; the prescribed *mechanism* was not needed — see below | the lane's cold worker now arms the `ws://` opt-in through a CI-only WorkManager dispatcher that delegates to the production wake body, and `M7_REQUIRE_DECRYPT=1` is set in the workflow | M |
| B3 | Android real GPS — **IMPLEMENTED 2026-08-03**, `e2e-real-gps` lane. **The premise was HALF FALSE: three of the four mechanisms already existed in B1; the missing piece was the ORACLE — see below** | no `locationServiceProvider` override; `pm grant` verified through `dumpsys package`; `adb emu geo fix` on a re-issue loop; and the part nothing else did — a SEPARATE peer decrypts the kind-445 and its coordinates are compared numerically against the injection within 1e-5 | ~10m |
| B4 | iOS real GPS — **IMPLEMENTED 2026-08-03**, `e2e-ios-real-gps` lane. **The premise HELD; two corrections to the ordering and the cadence it implies — see below** | `simctl privacy grant location` + `simctl location set`, in the only order that works (build → install → grant → seed → drive, with `HAVEN_E2E_IOS_SKIP_UNINSTALL=1`), both subcommands probed for support rather than assumed; the drive asserts a peer's decrypted coordinates against the seed within 1e-5 and prints a terminal `[b4] PEER_DECRYPT_MATCH` the shell requires | ~15m |
| B5 | Permission revocation mid-session — **IMPLEMENTED 2026-08-03**, `e2e-permission-revocation` lane. **The premise held, but the item's own mechanism ENDS the session it wants to observe — see below** | `pm revoke` (+ `set-permission-flags user-fixed`), VERIFIED via `dumpsys package`, issued under a backgrounded drive; then a SECOND drive of the same target against the same install, because the revoke kills the app process. Absence is proven off the RELAY: a diff over kind-445-with-`expiration` event ids, polled across a bounded window | ~30m |
| B6 | Location provider toggle — **IMPLEMENTED 2026-08-03**, `e2e-location-provider-toggle` lane. **The item's claim was HALF wrong; the app does NOT surface the disabled state — see below** | `cmd location set-location-enabled false` mid-drive (the drive is backgrounded and toggled underneath, since the subject is one continuous session), then back on | ~25m |
| B7 | iOS WhenInUse vs Always — **IMPLEMENTED 2026-08-03**, `e2e-ios-auth-tier` lane. **The obvious framing of this item was INVERTED — see below** | one drive target run twice on one sim: `simctl privacy grant location-always` then `grant location`; each run reads the tier back through the production `MethodChannel` bridge and asserts the honest per-tier copy + continued background publishing; the shell then requires the two runs to have observed DIFFERENT tiers | ~35m |
| B8 | Clock jump ±6h — **IMPLEMENTED 2026-08-03, RE-SCOPED 2026-08-05**, `e2e-clock-skew` lane. **The premise HELD and the app was defective in both directions — see below** | `adb root` + a pinned `auto_time`, then a shell servo that fulfils `[b8] REQ_CLOCK` requests the drive emits, with an adb read-back per jump; the drive GATES the two skew SIGNALS (typed `DeviceClockRejected`, two-member in-ciphertext corroboration) and RECORDS the delivery cost as evidence. It does **not** assert relay acceptance or peer decrypt: a NIP-40-enforcing strfry refuses both skew directions at ingest, so there is no accepted event to measure | ~30m |
| B9 | Network loss/reconnect — **IMPLEMENTED 2026-08-03**, `e2e-network-reconnect` lane. **The item's MECHANISM does not exist; the premise it stands on HELD — see below** | `cmd connectivity airplane-mode enable` (device-wide, read back through `settings get global airplane_mode_on`) + a host-side iptables REJECT of the relay port for immediacy, both applied under a backgrounded drive; the drive proves the outage with its own in-process WebSocket probe and asserts a PEER location published after the reconnect is DECRYPTED (new coordinates, not presence) | ~25m |

**Lane status 2026-08-07.** All nine lanes are wired into the PR orchestrator
(`ci.yml:168, 180, 192, 220, 234, 249, 261, 274`, plus `e2e-background-catchup.yml:157`)
and every one was `success` in CI run 31216078806: `e2e_fgs_publish`,
`e2e_background_catchup`, `e2e_real_gps`, `e2e_ios_real_gps`,
`e2e_permission_revocation`, `e2e_location_provider_toggle`, `e2e_ios_auth_tier`,
`e2e_clock_skew`, `e2e_network_reconnect`. Every `--self-test` is invoked from
`repo-guards.yml`; none is orphaned. Several findings below still read as
though B2, B6 and B8 are unproven — that was the 2026-08-03 state.

**Also landed in this workstream: the publish-timestamp correlation fix.**
Parallel multi-circle publishing put one `created_at` on every circle's
kind-445, which a relay reads as "these circles share a member" without
decrypting anything. `haven/lib/src/services/publish_stagger.dart` spaces them
by a CSPRNG gap — `kPublishStaggerMinGap` 2 s (`:72`), `kPublishStaggerMaxGap`
9 s (`:75`), `kPublishStaggerMaxSpread` 30 s (`:78`) — and shuffles per-circle
order. Wired into the foreground path at
`providers/location_sharing_provider.dart:249-256` (which carries the
`NEVER restore Future.wait here` comment) and into the Android **foreground
service** at `services/background_location_task.dart:206, 938, 950, 985, 994` —
`flutter_foreground_task`'s `TaskHandler`, NOT WorkManager. Pinned by
`test/services/publish_stagger_test.dart`, which asserts
`kPublishStaggerMaxSpread < kStreamPositionMaxAge` (`:142`) so the stagger can
never outlive the freshness window it publishes into.

**Two guards this workstream produced, named here so they are findable:**
`scripts/ci/check_no_event_timestamp_cursor_advance.sh` (`repo-guards.yml:349`)
fails the build if any sync-cursor advance is derived from an inbound event's
`created_at`, or if any FFI entry point raises a cursor at all;
`scripts/ci/check_clock_skew_policy_parity.sh` pins the Dart mirrors
`kClockSkewAlertThreshold` 120 s and `kClockSkewTotalLossThreshold` 288 s
(`constants/location.dart:231`, `:207`) against `CLOCK_SKEW_ALERT_THRESHOLD_SECS`
/ `TOTAL_LOSS_SKEW_SECS` (`relay/clock_skew.rs:111`, `:78`). The user-facing
surface for the slow-clock verdict is
`widgets/location/clock_skew_banner.dart`, rendered from
`widgets/map/map_status_banners.dart:82` behind `LocationAccessBanner` so the
two never stack.

**B9 — `adb emu network disable/enable` IS NOT A COMMAND.** The emulator
console's `network` takes exactly four subcommands — `status`, `speed`,
`delay`, `capture` — confirmed against the help strings compiled into the
shipped `qemu-system-x86_64` (`network capture start <file>`,
`'network delay <latency>' allows you to…`, `'network speed <speed>' allows you
to…`; no `disable`/`enable` string exists anywhere in the binary). The only
connectivity kill switch the console offers is `gsm data <state>`, which
reaches the CELLULAR path, while an API-34 `google_apis` AVD routes over its
emulated Wi-Fi — so the item as written would have been a near-no-op that left
the lane green and disconnected nothing. The lane uses
`cmd connectivity airplane-mode enable` with an authoritative
`settings get global airplane_mode_on` read-back (the same "exit code is
worthless" trap `pm grant` has), plus an iptables REJECT of the strfry port on
the runner host — the emulator proxies guest TCP through host sockets under
QEMU SLIRP, the property `setup-network-guard.sh` already documents, so a host
OUTPUT rule reaches the guest connection and kills the socket with an RST
instead of leaving it to a 55 s WebSocket `PING_INTERVAL`.

**The premise itself held, and the recovery machinery is real but layered.**
Three independent mechanisms can restore live receive, spanning two orders of
magnitude:

1. the relay pool's own reconnect. `build_engine_client`
   (`haven-core/src/relay/live_sync/session.rs:64`) builds the client from
   `RelayPoolOptions::default()` / `ClientOptions::default()` and adds every
   relay with a bare `client.add_relay(...)` (`:485`, `:1045`), so each relay
   carries `RelayOptions::default()` — `reconnect: true`,
   `DEFAULT_RETRY_INTERVAL` 10 s adapting to `MAX_RETRY_INTERVAL` 60 s — and
   `post_connection` calls `resubscribe()`,
   which re-sends every stored filter VERBATIM (same subscription id, same
   `since`), so the relay replays whatever landed during the gap.
   `should_resubscribe` returns true after a drop because
   `connected_at > subscribed_at`;
2. Haven's M8 subscription-health tick (`maintainSubscriptionHealth` →
   `resume_after_background` at the persisted cursor when any relay is
   `Disconnected`), scheduled at +90 s then every 15 min;
3. `MapShell._healLiveSyncIfStopped` → `LiveSyncResubscriber.ensureRunning()`
   — the ONLY thing that restarts an engine `NostrSubscriptionService
   ._onStreamClosed` tore down — on a jittered 90–150 s timer that DOUBLES per
   consecutive failure up to ×8. A heal attempt made while the network is still
   down counts as a failure, so one wasted tick pushes the next out to
   180–300 s.

The lane's recovery budget (330 s) is sized to (3), not (1): a lane budgeted
for the fast path would report a product defect every time the slow path
legitimately ran. Which path a run took is recorded, not asserted
(`[b9] ENGINE_DURING_OUTAGE running=…`), because both are correct outcomes.

Two dead things surfaced while verifying the premise, neither load-bearing:
`BACKOFF_MIN_SECS` / `BACKOFF_MAX_SECS`
(`haven-core/src/relay/live_sync/config.rs`) are documented as the "supervisor
reconnect backoff" and are referenced NOWHERE — there is no supervisor-side
reconnect; the pool owns it. And `Monitor::new(64)` is installed on the engine
client with a comment admitting the task that consumes it is still a follow-up,
so reconnect re-anchoring is entirely the pool's `resubscribe()` today.

**Backlog replay is only partially provable from one emulator.** Bob and Alice
share one device, so an outage that stops Alice receiving also stops Bob
publishing. The lane gets as close as that topology allows: Bob's first
post-outage kind-445 is ENCRYPTED while still offline (local MLS work), so its
`created_at` falls inside the blackout, and it is published the instant
connectivity returns. A genuine "peer published while the receiver was
partitioned" proof needs a second, independently-connected publisher — a
`strfry import` of an adb-exported event, or a host-side relay client — and is
left as a follow-up.

**B2 — the premise HELD, verbatim and in production evidence. IMPLEMENTED
2026-08-03.** `M7_REQUIRE_DECRYPT` was read in exactly one place
(`tooling/e2e/ci/run-m7-background-catchup.sh`), defaulted to `0`, and appeared
in no workflow — `grep -rn M7_REQUIRE_DECRYPT .github/` returned nothing. At 0
the lane asserted `bootstrap ok` + `sweep complete:` + `circles>=1`; at 1 it
would additionally require `locations>=1 && relayErrors==0`.

**Turning it on would NOT have passed**, and the last green run says so
outright (CI 30792258968, `e2e_background_catchup`):

```
[phase-a] sweep counters: circles=1 locations=0 relayErrors=1
[phase-a] NOTE: decryption NOT observed in the cold worker …
```

The cause is a HARNESS gap, not a product defect, and that distinction is the
whole finding. `allow_ws_loopback_for_test` is an install-once `OnceLock` with
no on-disk form, so the worker process WorkManager starts after `am kill` never
inherits it; `validate_single_relay_url` then rejected `ws://10.0.2.2:7777`
before a socket was ever opened. The worker never reached the relay — nothing
about background *delivery* had been exercised, in either direction.

**The prescribed mechanism (a data-dir sentinel read at Rust init) was not
needed and was not built.** It would have put a persistent, on-disk lever
capable of relaxing the `wss://`-only transport policy into the app itself,
guarded only by `#[cfg(debug_assertions)]` plus a CI grep. The cheaper and
strictly safer seam was already there: WorkManager resolves ONE callback handle
per app, so a CI-only `@pragma('vm:entry-point')` dispatcher
(`haven/integration_test/e2e/_lib/m7_worker_ci_oneoff.dart`) can arm the opt-in
inside the cold process and then delegate to the production wake body. The only
production change is that `callbackDispatcher`'s task body is now the public
`runBackgroundCatchupWake()` — same reads, same gates, same sweep — so the lane
runs the app's wake and not a lookalike. Nothing test-only entered `haven/lib`,
and `scripts/ci/check_m7_background_delivery_assertion.sh` fails the build if it
ever does.

Two things came out of it beyond the assertion itself:

* **The C1/C2 negative phases were over-determined.** They assert "the gate
  declined the wake AND strfry stayed silent" — but with the opt-in absent, a
  leaked wake could not have reached the relay with every gate wide open. The
  silence proved the harness. The dispatcher now arms the opt-in for all three
  targets and both phases require the armed marker, so the silence proves the
  GATE.
* **`locations>=1` is only an honest decrypt oracle inside the TTL.** The
  engine short-circuits an event past `expiration` + `RECEIVER_EXPIRATION_GRACE_SECS`
  (228 + 60 s) to `Stale`, which the sweep counts as APPLIED with nothing
  decrypted. Phase A therefore also bounds seed→sweep (`M7_DECRYPT_FRESHNESS_S`,
  default 240 s; measured 11–63 s across six 2026-08 runs) and fails with that
  reason named, so a slow run can never pass as a delivered one.

First observed green 2026-08-05 (CI 30980908814) with `M7_REQUIRE_DECRYPT=1`,
and green on every run since (31075503390, 31216078806).

**B3 — the premise was HALF FALSE, and the half that was missing is the
ORACLE, not the plumbing. IMPLEMENTED 2026-08-03.** Read against the tree, three
of the four mechanisms this item prescribes were ALREADY in the B1 lane
(`run-b1-fgs-publish.sh` + `b1_fgs_live_foreground_test.dart`): it declines the
`locationServiceProvider` override, it `pm grant`s the location permissions, and
it seeds `adb emu geo fix`. Writing B3 as specified would have re-plumbed all
three and added nothing.

What did not exist anywhere in the repo was the ASSERTION:

* **B1's oracle is the foreground service's `[BackgroundTask] Published to N/M`
  logcat marker.** It proves a publish HAPPENED and is silent about WHAT was
  published — a stale cached fix, a zeroed position, and the injected
  coordinates all print the identical line.
* **B1 disposes its peer before the proof window opens**, so nothing in that
  lane is positioned to decrypt anything. Across the whole repo, no lane
  asserted a decrypted COORDINATE: every multi-party scenario injects
  `FakeLocationService`, so the value a peer recovered was always a Dart
  constant that had never touched the OS.

So B3 is not a second GPS lane, it is the value oracle: `adb emu geo fix`
injects a known point, the drive target mounts `HavenApp` with **no** location
override, and a genuinely separate peer decrypts the kind-445 and compares the
recovered coordinates against the injection within **1e-5 degrees**. The markers
carry DELTAS, never coordinates.

*The oracle is deliberately doubled.* The numeric comparison can only live in
the drive target (`expect`), but `flutter drive` exits 0 on a failed suite and
on a suite that ran nothing (`drive-log-lib.sh`, run 30753193231), so the shell
independently requires three completion markers — `[b3] REAL_FIX_OBSERVED`
(the OS delivered the injected fix to the production service),
`[b3] PUBLISHED n=<N>` (**parsed**, not grepped: `n=0` is the publisher
reporting it published to nothing, which a presence check would read as a pass),
and `[b3] PEER_DECRYPT_MATCH`.

*Three traps it is built around.* `adb emu geo fix` is a ONE-SHOT injection into
the goldfish GNSS HAL — it starts no stream and the HAL discards any requested
interval — so the fix is re-issued on a loop for the life of the drive, or a
one-shot `getCurrentPosition()` lands in a gap and times out. A REJECTED
`pm grant` still exits 0 (the hard-restricted gate is a bare `return` after a
`Log.e`), so `dumpsys package` is the gate and the drive re-reads the permission
through the plugin as an independent second check. And the `google_apis` AVDs
could resolve geolocator to FUSED while `geo fix` feeds the LocationManager
provider — production already sets `forceLocationManager: true`, so the two
agree, but that flag is where to look first if the lane ever goes dark on a
healthy emulator.

*What was built.* `.github/workflows/e2e-real-gps.yml` +
`tooling/e2e/ci/build-b3-real-gps-apk.sh` + `tooling/e2e/ci/run-b3-real-gps.sh`
+ `haven/integration_test/b3_real_gps_test.dart`, with the shell's parsers
pinned by hermetic `--self-test` fixtures in repo-guards.

**B4 — the premise HELD; two corrections to the mechanism the item implies.
IMPLEMENTED 2026-08-03.** Unlike B3, this one was true as written. Every iOS
scenario overrides `locationServiceProvider` with `FakeLocationService`
(`e2e_combined.dart:475` and `:5172`, `e2e_profile_sharing.dart:706`), and
`run-ios-sim-scenario.sh`'s own header says so — "No native location-permission
grant … so CLLocationManager is never touched". On iOS the "GPS fix" was a Dart
constant, and the authorization path, `AppleSettings` and the simulator location
stack ran nowhere in CI.

Two things the item's phrasing gets wrong about HOW, both found while building
it:

* **`simctl privacy grant location` requires the app to be already INSTALLED**
  — it resolves the bundle id against the simulator's installed apps — and the
  resulting grant does **not** survive a `simctl uninstall`, which the shared
  runner performs on entry for its own hermetic reasons. A `flutter test` builds,
  installs, launches and reports in one step, so there is no gap inside it to
  grant in. The only ordering that works is therefore **build → install → grant
  → seed → drive**, with `HAVEN_E2E_IOS_SKIP_UNINSTALL=1` so the shared runner
  cannot erase the grant between the grant and first launch. Every alternative
  rests on a running CLLocationManager observing a live TCC change, which Apple
  documents nowhere.
* **`simctl location set` needs no re-issue loop.** Unlike `adb emu geo fix`
  (B3's one-shot HAL injection), it is persistent DEVICE state: it holds until
  `clear` or shutdown and is not app-scoped, so it survives the re-install the
  delegated `flutter test` performs. One call is correct, and a missing fix
  therefore means the simulator never delivered — never that a seed expired.
  `simctl location` (with `set`) ships from **Xcode 14**, and `simctl privacy`
  from 11.4; both are still PROBED from their own usage text rather than
  assumed, because a lane whose subject is "did the OS deliver a fix" must not
  discover a missing tool as an ambiguous timeout 20 minutes in. If a future
  image lacks it, raise the image — substituting a fake reinstates the exact
  hole this lane closes.

*A guard gap this surfaced, worth more than the lane's own findings.* B4 was
initially **invisible to `scripts/ci/check_live_sync_define_declared.sh`**: that
guard matches build sites through a literal list of wrapper names (`BUILD_RE`),
and `run-b4-ios-real-gps.sh` — which compiles the app, and therefore bakes in the
receive path — was not in it. The lane passed the guard **vacuously** until the
wrapper was added (the same pass added `build-b3-real-gps-apk.sh` and
`run-b7-ios-auth-tier.sh`, which had the identical hole). A guard whose inventory
is a hand-maintained list only covers what someone remembered to list; this is
the recurring failure mode of this document, found for once inside a guard rather
than inside a lane.

*What was built.* `.github/workflows/e2e-ios-real-gps.yml` +
`tooling/e2e/ci/run-b4-ios-real-gps.sh` +
`haven/integration_test/b4_ios_real_gps_test.dart`. The seed is a
both-negative South-Pacific point so a sign-dropping regression in the encode
path cannot hide behind it, `(0, 0)` is refused as a seed (it is exactly what a
simulator with no simulated location reports), and the shell requires the
terminal `[b4] PEER_DECRYPT_MATCH` because a drive that exits 0 without reaching
its assertions proves nothing (A3b). 17 hermetic `--self-test` fixtures pin all
of it.

*Scope boundary.* The simulator runs no GNSS hardware and does not suspend a
backgrounded app, so this proves the FOREGROUND acquisition → publish →
peer-decrypt chain against real CoreLocation. Real radio behaviour and real
background suspension stay on the physical-device checklist.

**B7 — the premise was INVERTED, and the app was already right. IMPLEMENTED
2026-08-03.** The natural reading of this item — "background publishing needs
Always, so prove the app neither publishes nor claims to under When-In-Use" —
is false on iOS, and a lane built on it would have asserted a false claim
against correct code:

* A CLLocationManager session started while foregrounded with
  `allowsBackgroundLocationUpdates = true` and the `location` UIBackgroundMode
  declared **keeps delivering under When-In-Use**; the blue status-bar indicator
  is the price. `MapShell._onPaused()`'s iOS branch (`map_shell.dart:1049`, branch at `:1111`)
  keeps the per-circle scheduler and the motion trigger running purely on
  `shouldKeepPublishingWhilePaused(backgroundSharingEnabled, isIOS)` — the tier
  is never consulted, deliberately, and `geolocator_location_service.dart:186-199`
  documents why.
* What "Always" genuinely buys is the receive-only SLC relaunch after iOS
  terminates the app: `HavenSLCHandler.startMonitoring()`
  (`HavenSLCHandler.swift:161`) refuses to arm without `.authorizedAlways` and
  says the path is "purely additive".
* **The copy is already honest in both directions**, and the ARB says so
  explicitly: `@locationSettingsIosLimitedNote`'s description requires that
  While-In-Use never be presented as insufficient for background sharing *and*
  never as loss-free. `locationSettingsIosLimitedNote` renders only under
  When-In-Use; `locationSettingsIosGuidance` only under Always. No honesty
  defect was found. (The separate P0-2 over-claim in `locationSettingsIntro` is
  unrelated and still open.)

So the lane asserts what actually varies: the tier the app READS BACK, the copy
it renders for that tier, and that background publishing continues across a real
`AppLifecycleState.paused` under **both**. Its own worst failure mode is
silent-green — if `simctl privacy grant location-always` no-ops, both runs
observe the same tier and every per-tier branch still passes — so
`run-b7-ios-auth-tier.sh` requires the two runs to have observed *different*
tiers and probes `xcrun simctl help privacy` for the `location-always` service
rather than assuming it. A second silent-green route was found in adversarial
review 2026-08-03 and closed: the tier marker is printed **before the first
assertion**, so a `skip: true`, a `markTestSkipped` or an early `return` left
the discrimination gate satisfied while nothing was proved about the copy or the
background publish. The shell now also requires both terminal proofs —
`[b7] COPY_OK` and `[b7] BACKGROUND_PUBLISH_OK`, **one per tier log** — and says
in its failure message that a rc-0 drive missing them is a body that never ran,
not an assertion that fired (24 hermetic `--self-test` fixtures in repo-guards
pin all of it). Not provable on a hosted runner, and still owner-checklist items:
real background delivery on hardware, an actual SLC or BGTask fire.

**B5 — the premise held, but the mechanism it names ENDS the session it wants
to observe.** The item's claim — that `pm revoke` "reaches the
denied/deniedForever branches the fake can never produce" — is correct about
the gap: those branches
(`geolocator_location_service.dart:410-448`, `:726-727`, `:751-754`) are exercised only by
a mocked `GeolocatorWrapper` in
`haven/test/services/geolocator_location_service_test.dart`, and every E2E
scenario injects `FakeLocationService`, whose `checkPermission()` is a
hardcoded `LocationPermissionStatus.always`
(`e2e/_lib/fake_location_service.dart:58-59`). Three things the item did not
anticipate shaped the lane:

* **`pm revoke` KILLS the app process, so "mid-session" is over the moment it
  lands.** AOSP's `PermissionManagerServiceImpl
  .revokeRuntimePermissionInternal` calls back into
  `PackageManagerService.onPermissionRevoked`, which posts
  `killUid(appId, userId, KILL_APP_REASON_PERMISSIONS_REVOKED)`. On Android,
  revocation is therefore enforced by the **platform**, not by Haven, and
  Haven's own denied branches run only on the NEXT launch. A single-drive lane
  (B6's shape) could only ever have proved "a dead process publishes nothing",
  which is true of every app. Hence TWO drives: ACT 1 holds the live session
  for the revoke, ACT 2 relaunches into the revoked state and is where the
  branches actually execute. ACT 1 does **not** assume the kill — if the
  process survives it measures the tail from the inside — and the kill is
  recorded as evidence, never gated on, so a platform that stops killing does
  not redden the lane.
* **THE STALE-FIX CACHE BYPASSES THE PERMISSION GATE TOO — same root cause as
  B6's first finding, now confirmed on the permission path.**
  `getCurrentLocation()` **returned** the cached `_lastStreamPosition` whenever
  the cached GPS **fix time** was within `kStreamPositionMaxAge` (**168 s**) —
  *before* it consulted `isLocationServiceEnabled()` **and before it consulted
  `checkPermission()`**. Nothing cleared that cache on permission loss:
  `clearCachedPosition()` was called only on logout and on background-sharing
  opt-out (`location_provider.dart:47`). *(Pre-fix offsets deliberately omitted
  — the file has since drifted ~340 lines. Post-fix the gate
  `_ensureAccessOrThrow()` runs at `geolocator_location_service.dart:552`, ahead
  of the cache read at `:572`.)* So wherever the process
  survives losing location access, Haven keeps publishing the user's last known
  position for up to 168 s after the permission is gone. On Android `pm revoke`
  masks this — the cache is process-local and dies with the kill — which is
  exactly why ACT 1 MEASURES it (`MIDSESSION_TAIL tail=<S>`) instead of
  assuming either outcome, and why ACT 2's absence window is sized above 168 s.
  **The reachable variant is `appops`**: `cmd appops set <pkg>
  android:fine_location deny` removes location access WITHOUT killing the
  process, and `checkPermission()` — which reads the permission grant via
  `ContextCompat.checkSelfPermission`, not the app-op — keeps reporting
  granted, so the whole gate is bypassed and the cache runs its full 168 s.
  That variant is NOT in this lane (the item names `pm revoke`, and B6 already
  asserts the same tail on the service-enabled path); it is the honest way to
  observe this one, and belongs in a follow-up.

  **FIXED 2026-08-03.** Both halves, because either alone leaves the hole open.
  *Gated read:* `getCurrentLocation()` now opens with `_ensureAccessOrThrow()`,
  and BOTH shortcuts — the cache read and the `_isIOS && !_foregroundActive`
  `getLastKnownPosition()` branch — moved inside its granted arm, so nothing in
  the method can produce a coordinate before the provider-enabled and
  permission reads have run **on that same call**. `getCurrentLocationFresh()`
  was rewritten onto the same helper (it carried a byte-identical inlined
  gate). *Eager invalidation:* a new `_noteAccessLost` nulls the cache from
  every site that learns access ended — the gate's denial branches, the public
  `isLocationServiceEnabled()` / `checkPermission()` / `requestPermission()`
  readers, and a `StreamTransformer` on `getLocationStream()` catching a stream
  **error or close** (cancellation deliberately fires neither, so a settings
  rebuild does not discard the warm fix the iOS background path needs).

  A per-call gate was chosen over a memoised one deliberately: a TTL re-creates
  the exact hole being closed, and the cost is at worst a doubling of two cheap
  property reads the app already performs several times a minute. Mutation M7
  exists to keep that decision from being quietly reversed.

  The fix also closed an adjacent hole nobody had named: a **direct**
  `deniedForever` from `checkPermission()` was never handled — the old code
  branched only on `denied`, so the hardest denial the OS offers fell through
  to the one-shot, whose failure path then returned `getLastKnownPosition()`.

  9 mutations, 0 survivors. Two matter most: M1 (gate moved back below the
  cache read — the defect verbatim) and M9 (the cache made unusable, i.e.
  "fixing" this by re-breaking the iOS background publish path).

  **The `appops` residual is NOT closed**, and is documented at the call site
  rather than implied away: under `appops` the platform simply stops
  delivering, so exposure is bounded by the fix ageing past 168 s or the stream
  reporting error/close — shortened, not eliminated. Closing it needs an
  `AppOpsManager.unsafeCheckOpNoThrow` channel geolocator does not expose.

  `MIDSESSION_TAIL` consequently changes meaning: it was a measurement, it is
  now a **regression signal** (expected ~0; a tail approaching 168 s means the
  ordering was reverted). The lane's windows were deliberately NOT tightened —
  they bound an ABSENCE, so a generous bound makes the assertion stronger and
  is the only thing that would still catch the regression.
* **The publish path RE-PROMPTS — but, since the fix, only while foregrounded.**
  `_ensureAccessOrThrow()` calls `requestPermission()` when `checkPermission()`
  returns `denied` AND `_foregroundActive` is true
  (`geolocator_location_service.dart:410-425`); backgrounded it logs and fails
  closed without prompting. On Android `checkPermissionStatus` can only ever
  return `denied`, never `deniedForever`, without an Activity round-trip, so a
  FOREGROUND publish tick after a revocation raises the SYSTEM permission dialog
  with no user gesture behind it. A background tick can no longer do so. The lane pins `pm set-permission-flags ...
  user-fixed` to keep ACT 2 deterministic and RECORDS the read-back, so a
  missing flag presents as a named finding rather than a hang; the drive target
  bounds the probe and reports a `TimeoutException` as exactly this.

Two lane-design notes worth propagating. **Absence must be a DIFF over event
ids, never a count**: kind-445 location events carry a NIP-40 `expiration`
(`created_at + 228 s`) and strfry deletes them on its expiry cron, so the total
falls on its own and "count unchanged" proves nothing — and the window must be
POLLED, because an event published early can expire before the window closes.
**The `expiration` tag is also the discriminator** that separates a location
publish from the MLS commits ACT 2's own circle creation legitimately emits on
the same kind. And ACT 2 needs `pm clear`, not because the scenario wants it,
but because the E2E keyring is in-memory and process-scoped
(`useInMemoryKeyringForTest`): a second process mints a new SQLCipher
passphrase and physically cannot open ACT 1's MLS database. `pm clear` resets
runtime permissions, so the revoke is re-applied and re-verified after it.

**B6 — the premise held only halfway, and the other half is a live defect.**
The item asks for a lane that "asserts the app stops publishing and surfaces
the disabled state rather than failing silently". Read against the tree **as
found on 2026-08-03**, Haven did the first and **not** the second. Both halves
were fixed the same day; the findings are kept because the lane was built
against them:

* **Stops publishing — yes, but not immediately.** `getCurrentLocation()`
  served the cached `_lastStreamPosition` whenever the cached GPS **fix time**
  was within `kStreamPositionMaxAge` (= `kLocationPublishMaxInterval`, **168 s**)
  and only *then* consulted `isLocationServiceEnabled()` — the ordering the fix
  reversed (`geolocator_location_service.dart:552` now precedes the cache read
  at `:572`). So for up to 168 s after the
  user switches location off, Haven keeps publishing their last known position.
  No *new* information leaves the device, but the peers' "last seen" freshness
  keeps advancing for nearly three minutes after the user said stop. The lane
  MEASURES that tail (`PUBLISH_STOPPED tail=<S>s`) rather than assuming it, and
  only asserts "stopped" outside it — four consecutive zero-publish cycles.
* **Surfaces the disabled state — NO. It failed silently.** Both listeners of
  `locationStreamProvider` handled it with `next.whenData(...)` (in
  `haven/lib/src/pages/map/map_page.dart` and `map_shell.dart`), which discards
  the `LocationServiceDisabledException` the Android plugin raises from
  `LocationManagerClient.onProviderDisabled`. Both call sites are now gone —
  only the comments recording their removal remain (`map_page.dart:274`,
  `map_shell.dart:865`). The map's only error surface was gated on
  `_obfuscatedLocation == null` — false in every mid-session case, since a fix
  is already on screen. The publish paths swallowed the
  `LocationServiceException` into a `debugPrint` and returned 0. Net effect: **location
  sharing stops, the map keeps showing the last fix, and the user is told
  nothing.** The lane asserted the surfacing anyway and WAS expected red on that
  step — the B1 precedent: the red is the deliverable. It is no longer red; see
  the fix below.

  **FIXED 2026-08-03.** A new `locationAccessProvider`
  (`providers/location_access_provider.dart:180`) owns detection, and a new
  `LocationAccessBanner` (`widgets/map/location_access_banner.dart:137`) renders
  it through `MapStatusBanners` (`widgets/map/map_status_banners.dart:81`),
  which `_MapShellState.build` passes to `MapShell.buildLayers` as
  `statusBanners:` (`map_shell.dart:1570`, positioned at `:216-226`). Both
  `whenData` sites are gone — only the comments recording their removal remain
  (`pages/map/map_page.dart:274`, `map_shell.dart:865`).

  Three design points worth keeping:

  * **The cause is never inferred from the exception type** — it always comes
    from the two platform reads. That is load-bearing on iOS, where a denial
    and a transient GPS failure arrive as the *same* generic
    `PositionUpdateException`; naming the cause from the error would be
    confidently wrong there. Pinned by a test that feeds an error *looking*
    like service-disabled while the platform reports a permission problem, and
    asserts the platform wins. Five states are distinguished
    (service off / denied / permanently denied / both / unknown), and `unknown`
    asserts no cause at all — it is what the honest case degrades to.
  * **Detection cannot key on stream events alone.** An Android mid-stream
    permission loss produces no error and no `done` — just silence — so a 30 s
    silence watchdog is the only thing that catches it. Every trigger (error,
    silence, resume, failed one-shot, retry tap) funnels into one `refresh()`.
  * **The stale marker is cleared, not restyled.** A dot under a "location is
    off" banner asserts exactly the thing that is no longer true. Two knock-ons
    are tested: `showLoadingScrim` treats blocked as *not* loading (otherwise
    clearing the marker drops the map behind an eternal "Loading map…"), and
    the full-screen error is suppressed so the banner is the single surface.

  12 mutations, 0 survivors — but **M1 initially SURVIVED, and that was a real
  defect in the test**: with the watchdog running, the `AsyncError` assertion
  passed even with the error branch deleted, because the timer quietly did the
  work. The test named after the `whenData` bug was proving nothing about it.
  Fixed by running that case with the watchdog disabled. Worth carrying: a
  redundant recovery path can silently make the test for the primary path
  vacuous.

  Development also surfaced a genuine production bug: a watchdog tick landing
  after teardown threw `Cannot use a Notifier after it was disposed`.

  Seven new ARB keys were needed after all — the existing pair is only the
  service-off title and the calm first-run body, and reusing that body would
  have told a user whose sharing just *stopped* the same thing it tells a user
  who never started.

  **Adversarial review then found eight further defects in that fix; all are
  closed (2026-08-04, 15 further mutations, 0 survivors).** The two that
  mattered:

  * **The banner was occluded and untappable at the bottom sheet's 0.85 snap.**
    It was Stack child #4, the sheet child #5 with an opaque background: on an
    iPhone 13 only ~15.6 of its 208 dp showed and the remedy button was
    unreachable. The fix is ineffective in a common resting state, and — the
    part that matters for CI — **this lane cannot catch it**, because
    `find.text(...).evaluate()` matches occluded widgets. Fixed by reordering
    the Stack; `MapShell.buildLayers` was extracted `@visibleForTesting` so
    `test/pages/map_shell_banner_layering_test.dart` can compose the REAL
    banner over the REAL sheet and assert by hit test, never by finder.
  * **At 200 % text scale the banner ran off-screen and its guard could not
    fire.** 652 dp at 390 wide, 788 at 320. `PositionedDirectional` without
    `bottom:` leaves max height unbounded, so the Column never overflows — it
    silently leaves the viewport, and the test asserting `takeException(), isNull`
    was structurally incapable of failing while pumping at 320×900, taller than
    any phone. Fixed at both ends; the test now pumps 320×568 and asserts the
    button rect is inside the viewport AND hit-testable.

  Also closed: `notDetermined` was classified as a revocation, so the banner
  claimed "Haven no longer has permission… sharing has stopped" — both clauses
  false — while the OS prompt was still on screen (`classify` now takes
  `everGranted`; on iOS `denied` covers `notDetermined`/`restricted` and
  therefore never means revocation, verified in `AuthorizationStatusMapper.m`);
  a dead disclosure fast path documented as load-bearing; an app-ops test that
  set `permission = denied`, which app-ops provably does not do; `refresh()`
  able to permanently disarm the watchdog via a throw outside its try; and the
  watchdog never cancelled on pause.

  **On app-ops the honest answer is that nothing can be surfaced.** The stream
  carries `distanceFilter: 1`, so a stationary device legitimately emits
  nothing for hours; surfacing on silence alone would fire exactly the false
  alarm another test forbids. The test now asserts current behaviour with the
  limitation named, plus an anti-vacuity clause so it cannot pass because
  nothing ran.

  Two more self-caught vacuities worth recording, both the same shape as M1:
  deleting the "a delivered fix proves access works" fast path failed only a
  stream-churn count while the *state* assertion in the test named for it still
  passed (the watchdog did the work); and `stays quiet before the prominent
  disclosure is accepted` was satisfied by a watchdog that never fired, since
  the provider starts `available`.
* **Recovery is split — and the "dead stream" half of this finding was WRONG.**
  Re-enabling the provider restores publishing via the one-shot
  `getCurrentPosition` path (asserted). The claim that the STREAM cannot come
  back does not hold: `geolocator_android-5.0.2`'s `_wrapStream` returns
  `incoming.asBroadcastStream(onCancel: (sub) { sub.cancel();
  _positionStream = null; })`, so the cache **is** cleared when the last
  listener cancels. A full unsubscribe→resubscribe therefore yields a fresh
  native subscription; the corpse is only handed back if you re-subscribe while
  the old subscription is still alive, and `ref.invalidate` gives the right
  ordering. The recovery edge now does exactly that.

  It remains true that `onProviderDisabled` calls `removeUpdates` and that
  `onProviderEnabled` is empty, so nothing re-arms itself *without* a rebuild.

  **The banner deliberately does not depend on any of it.** State is set before
  the invalidate, and the invalidate is best-effort — pinned by a test whose
  fake hands back the same dead stream forever. A banner stuck on screen after
  the user fixed the problem would be worse than the silence it replaced.
  `STREAM_RECOVERED` / `STREAM_DEAD` stays EVIDENCE-only: the rebuild gives it
  a real chance to flip, but it depends on third-party behaviour and should not
  be promoted to an assertion without a run that shows it stable.

**B8 — the premise held, and the app is defective in BOTH skew directions.**
Verified from source before a line of lane was written, because this backlog
has been wrong several times:

* `created_at` is `SystemTime::now()` with no monotonic source and no
  relay-time correction — the MDK peeler stamps the inner app event with
  `now_unix_seconds()` (`transport-nostr-peeler/src/event.rs:180,217`) and
  **binds the outer kind-445 `created_at` to it** (`peeler.rs:169`).
* The 228 s TTL is real and rides the same clock: Haven stamps every circle
  with `message-retention.v1 = LOCATION_MESSAGE_RETENTION_SECS`
  (`haven-core/src/nostr/mls/manager.rs:338-343`,
  `haven-core/src/location/ttl.rs:80`) and the engine derives the NIP-40
  `expiration` as `inner_created_at + retention` for APPLICATION messages only.
* The `since` cursor is real, but — since the P0-5 fix — it is **not
  event-derived**. `run_catchup_all_circles` advances the persisted cursor to
  the fetch WINDOW's own local open time (`cursor_advance_ms`, `catchup.rs:234`
  → `cursor::cursor_ms_for_window`, `cursor.rs:222`); an unapplied event's
  `created_at` may only hold the advance BACK, never raise it
  (`catchup.rs:23-25` states the contract verbatim). `since_for_stream`
  (`cursor.rs:261-276`) re-derives the next REQ floor as
  `cursor − GROUP_RESUBSCRIBE_BUFFER_SECS` (60 s, `cursor.rs:72`), capped to
  `now`. *(As found on 2026-08-03 the cursor did advance to the sender's
  `created_at`; findings 3 and its mirror below are written against that older
  contract and are marked RESOLVED accordingly.)*
* **Nothing in `haven-core` or `haven/lib` compares the device clock against
  any external reference.** The only clock-skew hardening in the tree is the
  reclaim backoff's backward-jump tolerance
  (`background_location_task.dart:154-164`), which is unrelated.

Three consequences follow, and the lane asserts the correct behaviour against
each rather than documenting the current one:

1. **Fast clock ⇒ the device cannot publish at all, silently.** Every event it
   signs carries a future `created_at`, and a spec-conformant relay bounds
   that (`tooling/e2e/strfry.conf:16`, `rejectEventsNewerThanSeconds = 900`;
   the same guard exists in every mainstream relay). `publishLocation` only
   `debugPrint`s the rejection, so location sharing is dead for the session
   with no user-visible signal and no way for the device to find out why.
2. **Slow clock ⇒ every location is born already expired.** `expiration =
   created_at + 228`, both from the skewed clock, so an event published 6 h
   behind carries an expiration ~6 h in the past *at the moment it is written*.
   A NIP-40-honouring relay may drop it, and a correctly-clocked peer's
   `SessionManager::process_event` (`manager.rs:633-641`) discards it before
   decryption on `RECEIVER_EXPIRATION_GRACE_SECS = 60`. The publisher still
   sees a successful OK-ack and reports success: the loss is total and
   indistinguishable from working.
3. **A backdated event was below the `since` floor forever — RESOLVED by the
   P0-5 cursor fix.** The cursor then sat at the newest applied `created_at`
   and the next window opened only 60 s below it, so anything minted further
   back was outside **every** subsequent REQ. It is now anchored on the fetch
   window's local open time with unapplied events only holding it BACK, so a
   backdated event is re-fetched rather than stranded — CI-enforced by
   `scripts/ci/check_no_event_timestamp_cursor_advance.sh`
   (`repo-guards.yml:349`).
   The Rule-12 saturation guard does not cover this — the window is never full,
   it simply never contains the event — and the same shape is reachable
   without any clock jump, from a peer whose clock merely runs behind. A
   dropped location ages out; a dropped **commit** on this path strands the
   epoch chain, which is the exact consequence `catchup.rs`'s own doc gives as
   the reason saturation must hold the cursor.

The mirror of (3) was analysis-only in the lane and is **also RESOLVED**: a
*future-dated* peer event would then have advanced the cursor past `now`, after
which `since_for_stream`'s `cap_timestamp_to_now` pins every subsequent floor at
`now` for the duration of the skew — i.e. catch-up degrades to "only what is
published after each fetch". It can no longer happen: `cursor_ms_for_window`
clamps through `cap_timestamp_to_now` (`cursor.rs:231`), and no advance is
derived from an event timestamp at all. The lane could not exercise it in any
case, because strfry refuses the ±6 h write in the first place (finding 1).

*(The 2026-08-03 text named `contiguous_prefix_cursor_ms` as the function
applying no ceiling. No such symbol has ever existed in this repo — it was a
misremembered name, and is recorded here so a future reader does not go looking
for it.)*

**That mirror turned out to be the mild form of a SECURITY defect — see P0-5.**
The cursor is derived from the inbound event's OUTER `created_at`, which is
never authenticated for any outcome, so the "skewed peer" framing above
understates it: any relay observer can supply the timestamp deliberately.

**FIXED 2026-08-03 — the silence, in both directions. Not the delivery.**

*Signals, both from connections Haven already makes* (no NTP, no third-party
time host — that would add a correlatable network fingerprint to a
privacy-first app):

* **Ahead — the relay's `OK false` reason.** The swallow was deeper than this
  item described. `publish_with_retry` had `Ok(_) => last_err =
  RelayError::AllRelaysFailed`, discarding the whole `PublishResult` — every
  relay's stated reason — before the FFI; `NostrRelayService.publishEvent`
  then swallowed it twice more into a generic exception. The reason never
  crossed the boundary at all. Now classified before collapsing, returned as a
  typed `RelayError::DeviceClockRejected { complaint }`, and retries stop when
  every answering relay blamed the clock — re-offering the same signed event
  with the same `created_at` is provably hopeless.
* **Behind — MLS-authenticated peer timestamps.** Deliberately NOT the outer
  `created_at` (see P0-5: it is attacker-writable). The detector consumes
  `DecryptedLocation.timestamp` — the sender's own clock reading from *inside*
  the ciphertext — keyed by the MLS-authenticated member id. An outside
  observer cannot contribute a sample at all, since a forged event never
  decrypts. Samples are keyed by member with only the latest kept, so one
  member cannot supply two; a false alarm needs two colluding CURRENT members,
  who already hold the user's location, and the ceiling on their gain is a
  warning banner. Nothing signed, published or stored ever changes.

Only the positive direction is inferred, and that asymmetry is principled: a
correctly-clocked peer never stamps a future time and every source of delay
pushes the observed offset more negative, so a consistently positive offset
can only be clock disagreement. The negative direction is structurally
unobservable here — `process_event` already dropped anything older than
`retention + grace`, so every surviving sample satisfies `offset > −288 s`.

*Threshold* `CLOCK_SKEW_ALERT_THRESHOLD_SECS = 2 * RECEIVER_EXPIRATION_GRACE_SECS`
= 120 s. Lower bound: 60 s is the band the protocol absorbs by design, so
alerting inside it fires on skew that costs the user nothing. Upper bound: at
`228 + 60 = 288 s` a correctly-clocked peer discards 100 % of this device's
locations. And it is already a real defect at 120: the no-gap invariant is
`retention (228) > max publish gap (168)`, so a publisher lagging 120 s has
effective residency 108 s and peers are *guaranteed* coverage holes — asserted
as arithmetic, not prose. Pinned in both directions on both sides; widening
past 228 does not even compile.

*`created_at` is never rewritten.* Correction would need its own analysis —
the TTL, the `since` cursor and the peeler's inner/outer binding all ride that
value.

**Still silent, honestly.** (a) The ahead-direction receive path where no
configured relay bounds `created_at`: inbound events are dropped by the
expiration gate as `StaleReason::AlreadySeen`, a mislabel Haven cannot fix
because `StaleReason` is an upstream `cgka_traits` enum with no `Expired`
variant. (b) The behind direction in an account with exactly one other member
across all circles, since corroboration needs two distinct member ids —
relaxing that would let any single peer's bad clock accuse the user's phone.

**Why the lane WAS red, and was not simply weakened.** As first written, `b8`
asserted that a ±6 h jump leaves *delivery* intact. That is unachievable
without clock correction: `forward-skew-publish` can only be cleared by not
signing a future `created_at`; `backward-skew-retention` / `-receive` follow
mechanically from `expiration = created_at + 228` on the same skewed clock, and
making a peer accept them would mean weakening
`RECEIVER_EXPIRATION_GRACE_SECS`, a replay defence; `backward-skew-catchup` is
a cursor-window property no detection change touches.

A permanently-red lane is worse than no lane — it trains people to ignore it
and cannot detect a regression — so the resolution below re-scoped it rather
than deleting the measurements or relaxing what could still hold. One of the
four supposedly-unachievable properties looked achievable and was KEPT as a
gate: `backward-skew-publish`, on the reasoning that `tooling/e2e/strfry.conf`
sets `rejectEventsOlderThanSeconds = 94608000` (3 years), so a −6 h `created_at`
is accepted and a refusal there would be a real, fixable regression.

> **CORRECTION — 2026-08-05. That premise was wrong, and the gate is now
> narrowed rather than kept whole.** `rejectEventsOlderThanSeconds` is only ONE
> of strfry's two write-time time checks; NIP-40 expiry is a separate ingest
> path with no knob in that config. Haven stamps `expiration = created_at +
> LOCATION_MESSAGE_RETENTION_SECS` with BOTH values taken from the skewed clock,
> so a −6 h event is born ~6 h expired and is refused at ingest — the same
> "cannot publish at all" outcome as `forward-skew-publish`, and with the same
> single lever (clock correction, deferred). CI proved it twice, both times with
> `"invalid: event expired"`: runs 30925179141 and 30964250098. This is the same
> reasoning error the code comment made, and it is why `backward-skew-publish`
> and `forward-skew-publish` were treated asymmetrically when they are
> mechanically symmetric.
>
> `backward-skew-publish` is therefore now **classified, not gated wholesale**:
> a refusal that classifies as `DeviceClockComplaint.behind` (the born-expired
> one) is recorded as EVIDENCE; every other refusal reason — including an
> unrecognised one, which classifies as null — still emits `[b8] FINDING` and
> fails the lane. This keeps the regression-detecting power the decision above
> wanted while removing the part that could never pass. It is a re-scope on new
> evidence, not a relaxation to quiet a red lane; `run-b8-clock-skew.sh:104-105`
> and CLAUDE.md Testing Requirement #5 both forbid the latter.

**OWNER DECISION — TAKEN 2026-08-04: re-scoped to the SIGNALS.** The lane now
gates what the app is actually responsible for and RECORDS what it is not,
using the same evidence-vs-finding split B1, B5, B6 and B9 already use:

* `[b8] FINDING` (**gated**) — a fast clock's relay refusal must reach Dart as
  a typed `RelayError::DeviceClockRejected` rather than collapsed into a
  generic publish failure, and must reach a consumer that raises a verdict; a
  slow clock must be inferred from two distinct MLS-authenticated members'
  in-ciphertext timestamps, and ONE outlying peer must NOT raise it; both
  faults must reach the user saying DIFFERENT things.
* `[b8] EVIDENCE` (**recorded, not gated**) — the delivery each skew direction
  still costs, measured every run — with one caveat added 2026-08-05: because
  a NIP-40-enforcing relay refuses BOTH skew directions at ingest, the
  read-side costs (`backward-skew-retention`, `-receive`, `-catchup`) have no
  accepted event to measure and are reported as a single explicit
  `backward-skew-readside` note stating that they were not measured and why,
  rather than being silently skipped. Re-homing the receiver-expiration gate
  and the cursor-window comparison somewhere they can actually run is open
  work; today they are covered by unit tests only.

This closes the gap the previous paragraph flagged: the detection work was
gated by unit tests only, and is now proven on a device. It is a re-scope, not
a relaxation — the lane asserts strictly more code than it did, and the
delivery cost it stops asserting is the part that provably cannot be fixed
without clock correction (which moves the TTL, the cursor floor and the
peeler's inner/outer binding, and needs its own security analysis). The two
marker classes are parsed by disjoint extractors and `--self-test` fixture (15)
fails if either can be read as the other, so "convert a FINDING to EVIDENCE to
quiet the lane" cannot happen silently.

*Kept true by* `scripts/ci/check_clock_skew_policy_parity.sh` (repo-guards),
which fails if the Rust and Dart thresholds drift apart, if the classifier
token drifts, or if the Rust declaration is renamed such that the guard would
scan nothing — that last one being the vacuity case.

*What was built.* `.github/workflows/e2e-clock-skew.yml` +
`tooling/e2e/ci/run-b8-clock-skew.sh` + `haven/integration_test/
b8_clock_skew_test.dart`. The drive cannot set the system clock, so it ASKS
(`[b8] REQ_CLOCK <seq> <offset>` on logcat) and the shell answers with a real
`adb shell date` against a rooted emulator; the drive then polls its own wall
clock against a monotonic `Stopwatch` until it observes the discontinuity, so
the rendezvous is an observation and never a blind sleep.

*Two vacuity routes, closed explicitly.* The publisher and the receiver share
one device clock, so jumping it moves both and every comparison stays
self-consistent — the naive version of this scenario proves nothing. The
asymmetry comes from the hermetic strfry (the only clock in the lane that does
not move: it judges the fast-clock publish exactly as a correctly-clocked peer
would) and from TIME (the slow-clock event is minted skewed and read back after
the clock is restored). Separately, `date` exits 0 in cases where it changed
nothing — no root, a re-enabled `auto_time`, a read-only clock — so the oracle
keys on a per-jump **adb read-back**, not on an exit code, and Phase 0 fails
closed if `adb root` or the `auto_time` pin does not take. Both halves are
pinned by `--self-test` fixtures in `repo-guards.yml`, the critical one being a
servo record whose drift equals the full requested magnitude (i.e. the clock
never moved); without it the lane could go green having applied no skew at all.

*State hygiene, fixed in adversarial review 2026-08-03.* Phase 0 pins
`auto_time` / `auto_time_zone` to 0 so NITZ/NTP cannot undo a jump, and the EXIT
trap restored the clock VALUE but not the pin — the only unrestored mutation
among the four state-mutating lanes (B5, B6 and B9 all restore theirs). It
outlives the run, and every Android lane shares one `actions/cache` key over
`~/.android/avd/*`, so a pinned-clock AVD could in principle be published to all
of them. The trap now un-pins both, and a `--self-test` fixture asserts
structurally that every global the script pins to 0 has a matching restore to 1
AND that `cleanup()` actually calls it — an unreferenced restore helper restores
nothing.

*Also noted while deriving this, not acted on:* `strfry.conf` sets
`maxFilterLimit = 500` while `CATCHUP_MAX_EVENTS_PER_CIRCLE = 512`, so strfry
clamps the catch-up REQ to 500 and `fo.events.len() >= 512` can never be true
against the hermetic relay — P0-4's saturation detection is untestable in CI as
configured. Belongs to P0-4, not B8.

Also: make the Phase-B re-arm failure fatal (`run-m7-background-catchup.sh:818-821`
is a non-fatal NOTE), and remove the `|| true` from `strfry_conn_count` /
`strfry_line_count` (`:618-625`) — an unreadable container currently makes the
silence proof pass vacuously as `0 == 0`.

**The `|| true` is the smaller half of that defect — CONFIRMED against a real
artifact 2026-08-02** (run `30734503776`, `e2e-background-catchup` →
`strfry.final.log`). Two findings, both evidence-backed:

* `strfry_conn_count`'s pattern
  (`connection (open|opened|established|accepted)|new connection|client
  connected`) matches **zero** lines of a real strfry log, so the Phase-C1/C2
  "authoritative silence proof" is vacuous even when the container reads fine —
  an **eighth** instance of the recurring failure mode. Note the obvious fix is
  also wrong: `Connect from` matches zero lines too. At `dumpInEvents = false` /
  `dumpInReqs = false` (`tooling/e2e/strfry.conf:72-73`) and default verbosity,
  strfry logs **no** connection, REQ or EVENT lines at all. The whole log for a
  full four-phase lane is **13 lines**: startup banner plus one
  `HTTP request for [/]` healthcheck per minute. A real fix needs
  `dumpInEvents`/`dumpInReqs` enabled for the E2E config, or an LMDB-side
  `strfry scan --count` query — not a better grep.
* `strfry_line_count` therefore grows by ~1 line/minute from healthchecks alone,
  independent of any app behaviour. M7 asserts it is *unchanged* across a ~5s
  settle window, so a healthcheck landing inside that window is a spurious RED
  waiting to happen — and any "activity increased" assertion built on it (the
  B1 lane originally had one) is satisfied by healthcheck noise and can never
  discriminate. Removed from B1 for exactly this reason.

**Spike — DONE 2026-08-01. Verdict: the docs were wrong; the conclusion holds.**
`pm grant ACCESS_BACKGROUND_LOCATION` is expected to SUCCEED on API 30+ for an
`adb install`-ed package. The spike's own premise was also wrong in the opposite
direction: the permission **is** `hardRestricted` in AOSP (same class as SMS /
Call Log, unchanged android11→android15). What makes the grant work is the
installer allowlist — `PackageManagerShellCommand.makeInstallParams()` sets
`INSTALL_ALL_WHITELIST_RESTRICTED_PERMISSIONS` unless `--restrict-permissions`
is passed — so the package is installer-exempt and the gate passes. The real
Android 11 restriction governs `requestPermissions()`/`GrantPermissionsActivity`
(background location cannot be *requested* alongside foreground location); the
old claim inferred a `pm grant` limit from a UI-consent limit, which does not
follow.

Two traps this surfaced, both worth propagating:

* **A rejected `pm grant` still exits 0** — the hard-restricted gate is a bare
  `return` after a `Log.e`. Every grant site in `tooling/e2e/ci/` currently
  trusts the exit code or `|| true`s it. Verify with `dumpsys package`.
* **The permission→app-op sync is asynchronous** (`PermissionPolicyService` posts
  to `FgThread`), so `cmd appops get` must be POLLED for `allow`; a single
  immediate read can still show `foreground` on a grant that landed.

Consequences: it does NOT change B1's design — B1 starts the FGS from a visible
activity, where `foregroundServiceType="location"` carries location access
without this permission. It DOES keep FGS-on-boot testing blocked on holding the
permission, because API 34+ refuses to create a `location` FGS from the
background without it. **Empirically CONFIRMED on an API-34 `google_apis` emulator** by the
`e2e-fgs-publish` probe (CI run 30753193231):

```
android.permission.ACCESS_BACKGROUND_LOCATION: granted=true,
  flags=[ USER_SENSITIVE_WHEN_GRANTED|USER_SENSITIVE_WHEN_DENIED|RESTRICTION_INSTALLER_EXEMPT]
```

`granted=true` carrying `RESTRICTION_INSTALLER_EXEMPT` is exactly the installer-
allowlist mechanism predicted above, and logcat contained no
`Cannot grant hard restricted non-exempt permission`. The claim is settled: the
grant works, and FGS-on-boot testing is unblocked on the permission axis.

(Probe caveat: the `cmd appops get <pkg>` read-back printed nothing for the
location ops — with no prior location access there is no entry to report — so
the app-op half of the probe is uninformative as written and burns its full
30s poll. `dumpsys package` is the authoritative signal and did answer.)

**New, unrelated risk this surfaced for B3/B4:** `adb emu geo fix` is a one-shot
injection into the goldfish GNSS HAL with no stream between injections (the HAL
discards the requested interval), so any real-GPS scenario needs a re-issue loop.
Separately, the AVDs run `google_apis` images where geolocator may resolve to
FUSED location while `geo fix` documents only the LocationManager provider —
`forceLocationManager: true` is the diagnostic lever if the emulator goes dark.

**Out of scope for hosted runners** (keep the manual pre-release checklist):
physical-iPhone BGTask/SLC fire, real jetsam suspension, OEM background killers,
true Doze deferral timing, real GPS radio behaviour.

---

## Workstream C — relay-observer privacy oracle

Today's `_assertWirePrivacyInvariants`
(`haven/integration_test/e2e/e2e_combined.dart:4226-4409`) is a **forbid-list by
explicit design** (`:4334-4341`) scoped to one circle's kind-445 stream. A new
kind, a new tag, or an MDK-introduced field passes silently.

It is also **silently degrading**: application kind-445s carry
`expiration = created_at + 228`, the Android lane's strfry enforces NIP-40 (the
iOS lane's `haven-local-relay` does NOT — it retains every event for the process
lifetime, `tooling/e2e/local-relay/src/main.rs`), and the oracle's `collectN`
runs late in a 720s scenario — so on slow runs the location
events are already evicted and the ephemeral-key and no-`p`-tag checks shrink to
the commit subset while `isNotEmpty` stays satisfied by commits.

| # | Item |
|---|---|
| C1 | **Recording WebSocket proxy** in `tooling/e2e/local-relay` — NDJSON of every frame both directions, with `wire_seq`/`conn_id`. Not in-relay hooks: those see only EVENT and REQ, and strfry vs `LocalRelay` differ. Immune to NIP-40 eviction because it records what was *sent*. Fail open |
| C2 | Meta-floors: journal non-empty; ≥1 event per participant pubkey; sentinel-anchored snapshot so background wakes can't race the read |
| C3 | Closed kind set over de-duplicated lines. Use a **set, never a multiset** — counts are nondeterministic. Kinds 0/5 allowed-but-not-required. 10051 is **forbidden**, not allowed: its only live emit path is a one-shot empty retraction on a pre-Dark-Matter migrating install, which no lane is, and allowing it would loosen a check `e2e_combined.dart:4354` already makes (recorded in `wire_allowlist.json` `_disagreements`) |
| C4 | Per-kind `observed ⊆ allowed` **and** `required ⊆ observed` — not exact set equality, which false-reds on absent optional tags. Day-one allow-list is recorded in the audit notes |
| C5.1 | **No two 445s with different `h` share a `created_at`** — the peeler binds outer to inner timestamp, so a relay learns two circles share a member. Live leak |
| C5.2 | **REQ-filter allow-list** — kind-3 is banned as an event; a multi-author `Filter::authors([...])` would re-create the same social-graph disclosure as a different frame type. Currently ABSENT from the tree (`profile/fetch.rs` uses singular `Filter::author`, one relay per author) and banned by `check_profile_privacy_boundaries.sh:628-644`; the wire allow-list is the regression tripwire, not a live-leak finding |
| C5.3 | 445 tag-names ∈ {`h`}, {`h`,`expiration`} — the MDK-bump tripwire |
| C5.4 | No `g`/`alt` tag on any kind — guards `haven-core/src/nostr/event.rs:203-227`, a live-but-unreachable builder emitting a truncated geohash |
| C5.5 | 1059 tag-set == {`p`} — guards the orphaned `giftwrap::wrap_welcome`, still `pub`, which stamps a 30-day expiration |
| C5.6 | Publish-target containment; no event ever reaches an unconfigured default relay |
| C6 | Canaries: circle display name (high value), petname, coordinates. **Drop locale and timezone** — no wire field can carry a timezone, and locale already has a stronger static gate |
| C7 | Egress guard: currently rejects only TCP 80/443 and records nothing. Move to logging-only first (`-j LOG`, publish observed destinations), assert once nightlies show it stable. **Skip the iOS half** — that lane is `macos-latest` (no iptables) and hermeticity is already enforced in-process |

**Scope honestly:** a wire transcript is a *send-side* instrument. It says
nothing about a hostile relay withholding, reordering, or forging inbound events
(eclipse, welcome suppression, stale-KeyPackage serving).

### Status 2026-08-10 — WIRED into both lanes; not yet PROVEN on real traffic

C1–C7 are implemented, wired, and green. The contract they share is published at
`docs/WIRE_JOURNAL.md`; `tooling/e2e/wire_allowlist.json` is the day-one
allow-list, linted by both consumers.

| Item | Artefact | Self-test |
|---|---|---|
| C1 | `tooling/e2e/local-relay/src/{proxy,frame,journal,summarize}.rs`, `bin/wire_proxy.rs` — listens on 7788, forwards to 7777 | 77 Rust tests |
| C2–C4 | `tooling/e2e/ci/check-wire-journal.sh` | 116 fixtures |
| C5.1–C5.9 | `tooling/e2e/ci/check-wire-correlation.sh` | **134 fixtures**, `MIN_CASES=134` (pinned exactly) |
| C6 | `haven/integration_test/e2e/_lib/wire_canaries.dart`, CLI `tooling/e2e/ci/check-wire-canaries.dart` | 85 Dart tests, 177 live terms |
| C7 | `tooling/e2e/ci/setup-network-guard.sh` + `egress-allowlist.txt`, **observe mode** | wired on e2e-android, e2e-profile, e2e-location-provider-toggle |
| — | `scripts/ci/check_wire_proxy_test_only.sh` — the proxy may never be reachable from app code (NEGATIVE half) | green |
| — | `scripts/ci/check_wire_oracle_lane_reachable.sh` — the oracles must be REACHED by a lane (POSITIVE half) | 40 fixtures |

**Wiring, 2026-08-10.** Both `e2e-android.yml` and `e2e-ios.yml` point the app at
the proxy on 7788, mint ONE sentinel token and thread the same string through the
APK build, the drive and the host-side oracles. `e2e_combined.dart` emits the
sentinel from a final `testWidgets` (not `tearDownAll`, whose failures never
reach the map `integrationDriver()` inspects) and plants three canaries with
plant proofs. Android runs all three oracles; iOS runs the journal oracle and C6.

**C5.7/C5.8/C5.9 were added** to carry the Security Rule 2 wire checks that until
now lived only inside `_assertWirePrivacyInvariants`: fresh ephemeral key per
kind-445, no real MLS group id on the wire, no `p` tag on a 445. **The in-drive
assertion is deliberately KEPT, not replaced** — nothing has yet proven the
oracles read real traffic correctly, and porting a check while deleting its only
other implementation leaves a window where neither is proven. Delete it only
after a green journal shows the oracle equivalent firing.

**The MLS group-id channel — LANDED 2026-08-10.** C5.8 needs the real id as
ground truth, and it cannot come from the journal (its absence there IS the
assertion) or from the drive log (uploaded, 14-day retention, and C6's
`--manifest` input). It now travels a device→host control channel:
`["HAVEN_WIRE_MLS_GROUP_ID","<hex>"]` on the same socket as the sentinel, which
the proxy INTERCEPTS — never forwarded, never journalled — appending each
distinct id to a per-instance sidecar the lanes read into `--mls-group-id`.
Interception sits BEFORE `journal.record`, because the journal has no retraction
for a line it already wrote. The ack is emitted only for a value that validated
AND reached the sidecar: an ack meaning merely "I parsed your frame" would let a
lane run C5.8 against a needle set the host never received.

`--exclude-conn` and iOS C5 (gated on `live_sync`) are wired. The
`--mls-group-id-not-asserted` escape hatch remains implemented and fixture-tested
but is **used by no lane**.

**A Rule 4 violation this work introduced, and closed.** The announce was
unconditional, and `e2e-flakiness-stress.yml` drives this same scenario straight
at strfry (`ws://10.0.2.2:7777`, no proxy) nightly — so the real MLS group id
would have gone to a relay, 15 s before the missing ack could be noticed. Both
halves now fail closed: `TestRelay.announceMlsGroupId` throws before anything
reaches the socket when `wireRecorderDeclared` is false, and the caller skips.
The gate is the sentinel define, which `check_wire_oracle_lane_reachable.sh`
link 4 already pins as a lane's declaration that a recorder is in path. Pinned by
`haven/test/lints/wire_mls_group_id_announce_sites_test.dart`.

**Closed by the 2026-08-10 review fleet** (three reviewers over the channel;
each finding fixed and mutation-proven):

* **A Rule 4 violation this work introduced.** The announce was unconditional
  and `e2e-flakiness-stress.yml` drives the same scenario at strfry with no
  recorder, so the real id would have gone out nightly, 15 s before the missing
  ack could reveal it. Both halves now refuse before anything reaches the
  socket, gated on the sentinel define that CI already pins as a lane's
  declaration that a recorder is in path. The refusal is the FIRST statement —
  it was briefly behind a 15 s writability poll despite gating on a
  compile-time constant.
* **Interception was a PARSER property, not a verb property.** Malformed JSON,
  a non-array, or a Binary frame fell through and was both journalled (whole id
  inside a 200-char `raw_preview`) and forwarded. Now a byte-level gate ahead
  of classification; refused without an ack, because acking an unrecordable
  declaration tells the drive the host holds a value it does not.
* **The artifact ban keyed on LOCATION for a file whose path is caller-chosen.**
  Two reviewers defeated it from opposite directions — the `.log` exemption and
  relocating out of `/tmp`. It now keys on the name shape, with fixtures for
  both bypasses and one proving the `.log` exemption is still load-bearing.
* **Three comments claimed a wide safety margin that does not exist.** OpenMLS
  mints a **16-byte** group id (`openmls/src/group/mod.rs:73`,
  `rng.random_vec(16)`) = 32 hex chars, sitting EXACTLY on all three floors.
  Anyone "tightening" one on the strength of those comments hard-fails every
  lane. All three now say the floor is exact.
* **Dart accepted ids Rust rejects** (no maximum vs a 128-hex cap), so an
  over-long id would transmit, be refused silently, and surface as an ack
  timeout blaming the recorder for a caller bug. Both validators now fail on
  the same inputs.
* **The lanes rebuilt the `default` instance's sidecar filename** while reading
  the journal path from a claim in the same file. A stale sidecar is worse than
  a missing one: C5.8 would scan for a previous plane's ids and report clean.
  The recorder now claims the path and both lanes read it.
* **`_announcedMlsGroupIds > 0` could not catch removing ONE call site** — and
  one is enough, since `_m11AliceCreatesCircle` covers the two-circle scenario
  whose 445s are the only ones satisfying C5.1. A source lint pins the site
  count by equality.
* **The iOS envelope omitted an unbounded release cargo build** from its own
  arithmetic. That step is now bounded and counted (195/130). The envelope has
  been wrong twice in the same direction, so every step in the sum is now
  bounded — which is what makes the sum checkable.
* Smaller: `LC_ALL=C` on the two harness-log greps (repo convention, and the
  sentinel line carries a UTF-8 em-dash amid binary log noise); a rejected
  `--mls-group-id` reported by length instead of echoed into a public job log.

**Open, and honestly scoped:**

1. **`--exclude-conn` names one connection SEGMENT, not one actor.** The drive
   opens three `TestRelay` sockets and only `ctx.relay` emits the sentinel; a
   strfry drop mid-scenario mints a fresh `conn_id` the captured value no longer
   covers. Direction is UNDER-exclusion, which INFLATES the participant floors —
   so a green run does not establish the production app transmitted. Both lanes'
   comments now say this. The real fix is every `TestRelay` emitting its own
   sentinel, re-emitted after each reconnect.
2. **The `Duplicate` ack is issued from an in-memory set**, not re-read from the
   file, so an id acked after an external rotation would be acked but absent.
   Self-heals in practice and collapses to `mls_count == 0` → red.
3. **No cap on distinct declarations** — `seen` is an unbounded `BTreeSet`.
   Loopback-only, so inside the runner's trust boundary.

**Two more instances of the recurring failure mode, both self-inflicted this
round** (the count above is now 13):

11. The `--mls-group-id-not-asserted` escape hatch shipped WITHOUT a fixture,
    and its first mutation survived — the same defect it was written to repair.
12. The success banner still read "all nine … hold" three lines under an
    advisory saying C5.8 was never scanned. A banner is an assertion: the line
    a reader greps to conclude "green ⇒ the rule held" must never name an
    invariant that did not run.

**Still blocked on a real journal** (cannot be closed by more code):
`_assertWirePrivacyInvariants`'s trim, and kinds 10002/10050 at
`required: false`. Both need the first green run to confirm what is actually
published. C5.6 remains structurally vacuous in a single-endpoint lane — honest
to keep, but the lane must not be read as proving containment.

**Review-fleet lessons, 2026-08-10** — five reviewers over the wiring round:

* **A success banner is an assertion.** The C5.8 opt-out left the clean line
  still reading "all nine … hold", three lines under an advisory saying C5.8 was
  never scanned. The line a reader greps to conclude "green ⇒ the rule held" must
  never name an invariant that did not run.
* **A precondition must be scoped like the assertion it guards.** C5.7's floor
  was discharged by an identity key seen in EITHER direction while the assertion
  is send-side only, so an inbound peer keypackage satisfied it while the local
  account's key was never in the comparison — a 445 signed by the local identity
  key reported CLEAN.
* **An escape hatch needs its own fixture.** The first banner fix shipped without
  one and survived mutation M6 — the same defect it was repairing.
* **A guard's fixtures are workflow-shaped, and other guards read them.** A new
  guard's heredoc fixtures tripped `check_live_sync_define_declared.sh`. The
  repair over-stripped three ways (comments processed after the awk; unanchored
  `match()` sliding into `<<<` and `1 << shift`) and failed OPEN on a
  receive-path invariant. When stripping is ambiguous, leave it unstripped: a
  false red is seen, an over-strip is a silent green.
* **Set-membership pins leak at the population edge.** `candidates` and `wired`
  derived from the same text meant a lane leaving both simultaneously landed in
  neither, exiting every check silently. The population now reads one call
  deeper, as the link-4 check already did.
* **An exact pin beats slack.** `MIN_CASES` sat 10 below the fixture count on a
  self-refuting rationale (slack "for legitimately-skipped fixtures", one line
  after "every case is unconditional"). Ten cases could be deleted silently.

---

## Workstream D — security-rule enforcement

| Rule | Status | Check |
|---|---|---|
| 12 backpressure | **NONE** — constant referenced at 2 lines, tested nowhere | Fix P0-4, then: publish `limit+k`, assert cursor didn't advance past the batch's oldest and a second sweep delivers the rest |
| 11 nonce | **NONE** (label half guarded; nonce half not) | Pure `haven-core` test using `encrypt_location`'s `event_json` — no relay. All 12-byte prefixes distinct, no fixed-prefix+counter shape, ≥28 decoded bytes. **Drop the uniformity assertion** (powerless at N≈30). Gets Rule 2 distinctness free |
| 8 no raw errors | WEAK — per-site redaction tests at ~5 call sites (`profile_service_test.dart:250`, `live_sync_resubscriber_test.dart:762`, `map_shell_detached_release_test.dart:116/265`, `nostr_subscription_service_test.dart:33`); no repo-wide lint | Dart lint test binding `catch (<ident>)`, flagging interpolation outside `debugPrint`/`assert`, allowlisting `${e.runtimeType}`. A literal `$e` grep is defeated by renaming the variable |
| 14 single session | WEAK — `check_mls_session_single_owner.sh` (`repo-guards.yml:101`) already pins the three-opener set and the handoff latch; the open half is disposal | Static: `newInstance` ⇒ `dispose()` same file. Runtime: B1 |
| 5 retention | WEAK — the behavioural half already exists (`mls_e2e_security_tests.rs:366`: an N+6 ciphertext does not decrypt), but the constants are unpinned (both appear only in comments, `nostr/mls/manager.rs:201-202`, `:962`) and the N+5 positive edge is untested | Pin `app_message_past_epoch_limit == 5` **and** `DEFAULT_MAX_PAST_EPOCHS == 5`; behavioural: ciphertext at epoch N decrypts at N+5, reports expired at N+6. **Not** an at-rest byte scan — SQLCipher always encrypts and no past-epoch exporter secret is persisted, so that check is doubly vacuous |
| 3 444 unsigned | WEAK — type-level only; `UnsignedEvent` silently drops a stray `sig` | Assert the raw decrypted rumor JSON has no `"sig"` key |
| 13 publish-before-apply | WEAK on send side (ack/sent distinction is correct; no test) | DI seam + table test {acked, NAK, timeout, throw} × 4 ops |
| 6 no key logging | WEAK — the only enforcement is `tooling/e2e/ci/scan-logs-for-secrets.sh`: 7 secret-SHAPE patterns over CAPTURED RUNTIME logs, which are device-wide, so the FGS isolate IS covered. There is no source-level log-interpolation guard over the 58 `log::{debug,info,warn}!` sites in `haven-core/src` or the 33 in `rust_builder/src` | Repo-wide log-interpolation guard with inline `// log-scan-ok:` suppressions; make the `keyring_core`→Off filter platform-independent |
| 7 zeroize | WEAK — hand-maintained 2-type whitelist, one type dead | Source-scanning test: secret-shaped field ⇒ `Zeroizing`/`ZeroizeOnDrop` |
| 9 Dart secret lifetime | WEAK — `withFreshSecret` covers all 3 `CircleManagerFfi.newInstance` sites (pinned per-site by `identity_secret_scrub_test.dart:55`, which also asserts the helper really `fillRange`s at `:129`); the gap is ~7 other `getSecretBytes()` sites fetching into a bare unscrubbed local (`name_circle_page.dart:290`, `invitation_provider.dart:114`, `invitation_poll_status_provider.dart:272`, `nostr_profile_service.dart:116/138/185`) | Lint test: `getSecretBytes()` ⇒ `withFreshSecret` or explicit `fillRange` |
| 1 key separation | WEAK — `p3a_…` (`mls_e2e_security_tests.rs:303`) asserts only that the identity key did not sign the 445 | A positive leaf-level test needs an MDK API exposing the leaf signature key; the existing test's own header records that `get_ratchet_tree_info` is gone and Haven no longer deps `openmls` directly, so **first identify the API**, then assert `leaf.signature_key() != identity_pubkey`. Until then the on-wire `assert_ne!` plus the mandatory `account-identity-proof.v2` leaf extension is the whole gate |

Also: `haven/rust_builder` has no `clippy.toml` yet mints both SQLCipher keys —
copy `haven-core`'s `thread_rng` ban.

---

## Workstream E — self-confirming doc↔code↔CI agreement

Two tiers. **The AI can only fail a build, never pass one.**

* **E1 — deterministic hard gate.** `docs/privacy/privacy_invariants.json`: a
  join table mapping invariant → the user-facing claim backing it (ARB key /
  doc anchor) → implementing code symbols → proving tests/guards → status. JSON
  + `jq` so it runs in the toolchain-free repo-guards job.
* **E2 — `check_privacy_invariants.sh`.** Every cited symbol exists; every cited
  test exists *and is not skipped, ignored, or tautological*; **every cited
  guard is still wired in `repo-guards.yml`** (this alone would have caught the
  orphaned tile-cache guard); every UI privacy claim maps to an entry; every
  constructed event kind maps to an entry; ratchet vs merge base.
* **E3 — schema decision that carries the weight.** Split `assertion_arb_keys`
  (promises) from `disclosure_arb_keys` (warnings). Assertions forbidden on
  accepted deviations; disclosures **required and non-removable**. Yields the
  most valuable check in the design: *you cannot silently delete a privacy
  warning*.
* **E4 — constant pinning.** Every constant backing a user-facing claim must be
  pinned by a test that fails on change **in either direction**. Today the
  jitter-fraction test catches widening and *severe* narrowing only
  (`publish_jitter_within_bounds` bounds the range,
  `publish_jitter_distribution_not_degenerate` needs >100 distinct draws — so a
  40%→20% narrowing passes both, and narrowing is the privacy regression); `kMotionTriggerDistanceMeters = 100` is tested only as
  `greaterThan(0)`; `LOCATION_RETENTION_SECS`'s derivation is untested; both
  screenshot protections have no test or guard at all.
* **E5 — AI layer, advisory.** Copy `l10n-ai-review.yml`'s wiring exactly:
  `claude-code-action@v1`, `pull_request` (never `_target`),
  `continue-on-error: true`, sticky comment, prompt declaring diff content
  untrusted. Its job is only what no grep can do — *this change weakens a stated
  guarantee; this new UI string claims something no invariant backs; this test
  was weakened*. Require `file:line` + verbatim quote, re-verified
  deterministically so hallucinations self-demote. Weekly *Manifest Author* job
  proposes updates as a PR; the model's output becomes a reviewed checked-in
  artifact, never in the verdict path. Empty/failed output ⇒ NEUTRAL.
* **Prerequisites:** no `.github/CODEOWNERS` exists and branch protection on
  `main` is still open, so manifest poisoning is only partly mitigable from CI.
  Land the privacy-page copy rewrite before authoring the manifest.

---

## Workstream F — user-facing copy

A full claim register found **113 claims: 9 contradicted, 3 stale, 6 unpinned
constants, 12 undisclosed behaviours**. Only 2 contradictions are fixed (the
relay-list ones, corrected during the relay-separation work).

**Sweep-level finding: no test checks any Privacy claim against BEHAVIOUR.**
`haven/test/pages/settings/privacy_page_test.dart` renders
`privacyHubSummary`/`privacyTitle` and pins the topic list, but asserts only that
the strings APPEAR — never that they are true. All 83 `privacy*` ARB keys can
therefore drift from behaviour with fully green CI. That is the
hole Workstream E exists to close.

Still contradicted:

| Key | Problem |
|---|---|
| `locationSettingsIntro` / `locationSettingsIosLimitedNote` | see P0-2 |
| `privacyWhatOthersSeeScreenshots` | "blocks screenshots everywhere in the app" — `UCropActivity` (`AndroidManifest.xml`) has no `FLAG_SECURE`. Also: **neither screenshot protection has any test or guard**; deleting them breaks nothing |
| `identityAdvancedDeleteBody` | "deletes all circle data from this phone" — `haven.security.pending_leaves` keeps hex `nostr_group_id`s in **plaintext SharedPreferences**, cleared only per-circle on a completed leave; `deleteIdentity` never removes it |
| `privacyHubSummary` | "the one thing that is public is the display name and photo" — kind-10002/10050 relay lists and the kind-30443 KeyPackage are also public and identity-signed. Self-contradicted by the app's own `privacyRelaysDetailKeyListIsPublic` |
| `privacyWhatHavenIsMeansForYou` | "nobody can be made to hand over your data, because nobody is holding it" — Blossom holds the photo permanently (no DELETE exists), relays retain kind-0/10002/10050/30443 |
| `privacyInferenceActivityPattern` | states the 100m movement trigger unconditionally; it does not exist in the Android background isolate at all, and is capped at one publish per 60s |
| `privacyWhatOthersSeeDetailTag` (stale) | "not something Haven can change" is false — MDK 0.9.4 supports rotating the transport group id |
| `privacyRelaysDetailIndexers` | may now overlap the formalized profile pool; needs a look |

Undisclosed behaviours worth deciding on (disclose or change): each roster
member's npub queried ALONE from its one salted-assigned relay out of a curated
pool of **8** public indexers every ~45 min — so an indexer still learns a ~1/8
slice of the union across all circles, with the assignment stable per install;
one socket carrying the npub-bearing `#p` filter *and* every circle's `#h`;
membership-change timing as a public tag discriminator; `circles.db` retaining
every member's coordinates for 24h; and `haven.security.pending_leaves` sitting
in plaintext (it survives `deleteIdentity`).

*(Two items were struck 2026-08-07 as already false of the tree: the roster was
never sent as one batched `authors[]` request — `.authors(` occurs nowhere in
`haven-core/src` and is CI-banned in profile paths — and the FGS isolate's
`debugPrint`s ARE silenced in release, at `background_location_task.dart:67-68`,
with `background_catchup_worker.dart` and `main.dart:77-78` doing the same.)*

---

## Relay separation — residuals

The implementation is complete (`haven-core/SECURITY.md` P1–P7 records the
accepted deviations). One residual remains:

* **RESOLVED 2026-08-07.** Both `e2e_profile_android` and `e2e_profile_ios` ran
  green in CI run 31216078806, exercising the hermetic relay pool, the harness
  wiring and the plane-separation lane. One residual is left, below.
* **The relay pool is behaviourally unvetted.** Two of five selection criteria
  (accepts unauthenticated kind-0 writes; no NIP-42 AUTH on read) require
  probing each host. A relay that silently rejects our publish makes the user
  invisible to every peer whose salt lands there.
* Minor: a whole-relay outage reads as a miss and promotes authors to their
  rank-2 relay. Bounded at two permanently and documented, but a design choice
  worth revisiting.

---

## Cross-cutting note: the recurring failure mode

Six times during this audit, code was found that looked complete, passed review,
and executed nowhere:

1. `check_no_tile_cache_secrets.sh` — written, passing, wired into no workflow.
   **RESOLVED** (A2) — now a step in `repo-guards.yml:301`.
2. `contamination.rs` — 281 lines at the time, never declared in `circle/mod.rs`,
   so never compiled and its 6 tests never ran. **RESOLVED** — now
   `pub mod contamination;` at `circle/mod.rs:31` (319 lines today).
3. A welcome-cascade write site — 17 lines of doc comment explaining why it was
   essential, with the actual call missing.
4. A debug-only relay override that two runtime call sites bypassed by reading
   the raw constant, making it inert.
5. `profile_pool_status` counting from the raw constant while the resolver used
   the effective accessor — with a comment asserting they were the same.
6. `profile_pool_status` itself: exported, bindings generated, called by nothing,
   while another doc claimed Dart surfaced it. **RESOLVED 2026-08-02** — it is
   now the oracle in `e2e_profile_sharing`: the counts are SAMPLED in `setUpAll`
   immediately after the first `CircleManagerFfi` is built (`:587`) and ASSERTED
   in the scenario's first `testWidgets` (`:628-651` —
   `configured == _profileRelayUrls.length`, `excluded == 0`,
   `isUnderflow == false`). Deliberately not asserted in `setUpAll`, whose
   failures never reach the results map `integrationDriver()` inspects
   (`e2e_profile_sharing.dart:578-586` records the reasoning). It is also
   surfaced in production now, via `profilePoolStatusProvider` →
   `relay_settings_page.dart`'s underflow banner. That converts the scenario's
   install-before-any-DB *ordering argument* into a test: a `configured` of 8
   or 11 is the unmistakable signature of the curated PUBLIC pool having been
   seeded, which previously surfaced only as kind-0 timeouts pointing nowhere
   near the cause.

Plus the l10n analogue: two ARB keys whose English changed, where the parity
checker cannot detect a stale translation because it only verifies key presence.

**Three more instances, all produced by the 2026-08-03 defect-fix round itself**
— which is the point: the shape is not historical, it is what this codebase
generates by default when work is done in parallel.

7. `haven-core/src/relay/clock_skew.rs` — 582 lines when found (601 today),
   complete and tested, **not declared in `relay/mod.rs`**. It compiled nowhere
   and ran nowhere until the omission was caught. **RESOLVED** —
   `pub mod clock_skew;` at `relay/mod.rs:28`.
8. `LocationAccessBanner` and later `ClockSkewBanner` — both written, both
   analyzer-clean, both with passing widget tests, and **rendered by nothing**.
   A widget test that pumps a widget in isolation proves it works; it says
   nothing about whether the app ever builds it. **RESOLVED** — both are built
   by `widgets/map/map_status_banners.dart:81-82`, and a source lint
   (`test/lints/location_stream_error_handling_test.dart:526`) now iterates both
   names so a future un-wiring reds.
9. `clockSkewAnnouncement` — an ARB key with a `@` description citing WCAG 2.1
   SC 4.1.3, **translated into 13 locales, and spoken by no code path**. The
   banner set its live-region label to title+body instead. Found by a
   *localization* reviewer, not by any code review, because it was the only
   agent whose job was to trace where each string is consumed. **RESOLVED** —
   the key was deleted from all locales, and
   `test/lints/announcement_keys_reachable_test.dart` now fails any announcement
   key no code path consumes. Its expected set is deliberately EMPTY; that is
   the steady state, and the durable part of the fix.

10. `check_lcov_aggregate.sh --self-test` — 8 fixtures, **wired into no
    workflow**. It runs only inside `scripts/ci/check_coverage.sh:155`, i.e. in
    the local pre-commit/pre-push gate, and nowhere in CI (`repo-guards.yml`
    wires the floors and filter self-tests but not this one). Since this gate
    replaced `very_good_coverage@v3` as the only thing enforcing the Flutter 50%
    aggregate, its self-test decaying would be invisible to CI. Found 2026-08-07
    by the audit of this very list. **RESOLVED 2026-08-09** — now a
    `Coverage lcov aggregate self-test` step in `repo-guards.yml`, with a header
    entry matching its two siblings.

**The fourth shape, and the one that generalises furthest: a test that passes
for a reason other than the one it is named for.** Found four times in one
round, always where a redundant recovery path silently does the work of the
mechanism under test:

* the `AsyncError` test that passed with its error branch deleted, because a
  silence watchdog cleared the state anyway;
* the "a delivered fix clears the state" test whose *state* assertion survived
  deleting the entire fast path, leaving only a stream-churn count with teeth;
* the cache-clear-before-`requestPermission` whose only covering test stubbed
  the re-grant as another denial, so a later clear did the work;
* a guard's own `--self-test` fixture that matched a call site before the
  declaration, so it would have failed a healthy tree while reading as a find.

The tell in every case: **deleting the code under test changes nothing, but
the suite is green because something else compensates.** A mutation that
merely weakens a guard does not catch this — the mutation has to reproduce the
shape the code actually had *before* the fix.

**Any review of this codebase should hunt both shapes specifically**: for every
new module, function, constant, guard, widget, ARB key and test, ask whether it
is actually *reached*; and for every test, ask what else could make it pass.
The first question found nine instances, the second four.

---

## CI run 30925179141 — five red jobs, all diagnosed and fixed 2026-08-04

The first run of the hardening work end to end. Five jobs failed; none of the
five was a false alarm and none was fixed by relaxing an assertion. Recorded
here because the shapes recur.

**1. `Coverage / Rust Coverage` — a time race in a NEW test, not a defect.**
`livesync_a_future_dated_event_cannot_push_the_cursor_past_now`
(`cursor_poisoning_e2e.rs`) asserted `cursor >= before * 1000`, where `before`
was read AFTER several seconds of MLS setup that ran between it and
`note_subscription_opened`. The live plane anchors its advance at the REQ open
time, so the cursor correctly landed a few seconds BELOW `before` — the
assertion demanded an advance PAST the window's own open time, which is exactly
the unsound claim `relay::cursor` exists to refuse. It only ever failed under
`llvm-cov`, whose instrumentation made the setup slow enough to cross a second
boundary. Replaced with the exact expected value (`cursor == opened_at * 1000`)
plus two anti-vacuity bounds, which is deterministic AND strictly stronger. The
four sibling catch-up tests use the same `before`/`after` idiom **correctly** —
there the sweep reads its own window-open time between the two — so they were
left alone.

**2. `E2E iOS Auth Tier` — one hermetic relay, two runs, one seed.** `run_tier`
uninstalled the app between the two tier runs but never reset the relay, so both
runs published a kind-30443 to the same addressable `d` slot from the same
`bobSeed`. The second run's `maintain_key_package` adopted the first run's
KeyPackage instead of publishing (`seededD`, `relaysHealed=0`) and
`SyntheticUser.bootstrap` failed closed. Failing closed was the *good* outcome:
the surviving KeyPackage's private half died with the previous run's data
container, so a Welcome sealed to it would have been undecryptable — a silent,
misattributed failure. Fixed by restarting the relay per tier, the same
discipline the workflow already applies per retry attempt, which also removes
the identical latent hazard for Alice's own KeyPackage. Held by three structural
`--self-test` fixtures (H1/H1b/H1c) that read `run_tier`'s source with comment
lines stripped, so the prose explaining the restart cannot satisfy a grep for
the restart.

**3. `E2E Core Flow (Android, live-sync)` — boot-completed is not
network-ready.** `setUpAll` died two seconds into the drive with
`SocketException: Network is unreachable, errno = 101` reaching
`10.0.2.2:7777`. `sys.boot_completed=1` is the only readiness signal the
emulator action waits for, and on a COLD boot the virtio-wifi interface has not
taken its DHCP lease by then, so the guest has no default route and `connect()`
fails instantly rather than blocking. Nothing retries an ENETUNREACH. The
sibling poll lane won the same race on the same cold boot, which is what makes
this a race and not a config error. Fixed with a guest-network gate in
`run-single-avd-scenario.sh` that polls `/proc/net/route` for a real default
route before driving — waited for, not slept through, so a warm boot pays
nothing. The predicate is pure text and unit-tested; fixture (6c) is the vacuity
case, since loopback is up from the first instant of boot and would satisfy any
naive "is there a 00000000 line" check.

*The host iptables egress guard was ruled out*: it REJECTs tcp/80 and tcp/443
with `tcp-reset` (which is ECONNREFUSED, not ENETUNREACH), never port 7777, and
ACCEPTs `-o lo` first.

*Also confirmed, and deliberately NOT changed*: the drive exited **0** while the
on-device suite failed, so the retry loop broke on `drive_rc == 0` and the
`integrationDriver` blind-spot check fired outside it. Making that check
retryable would weaken the blind-spot detection this round just installed, and
the readiness gate removes the need. Left as is, intentionally.

**4. `E2E Permission Revocation` — the bound was on the probe, not on the
loop.** ACT 2's one-shot GPS probe is bounded by `_gpsProbeTimeout` precisely
because "an unbounded probe would hang to the drive timeout with no
attribution". It timed out and reported correctly. The absence loop then called
`publishNow()` — the same platform path — **unbounded** on its first cycle, and
the drive died at the 13-minute per-test timeout having never printed
`ACT2_DONE`, so the app-side half of the proof was simply absent. Neither caller
supplied a bound: `waitUntilAsync` re-reads its deadline only BETWEEN polls, so
a poll that never returns outlives it. Fixed by bounding `publishNow` itself
(covering both acts), returning `null` rather than `0` for a wedged cycle — a
hung publisher must never read as this lane's passing condition — and gating the
new `wedged=` field in the shell oracle.

Two swallowed shell faults in the same job, both of the recurring `|| true`
shape, both fixed: **`pm clear` printed `Failed` and the lane continued.** It
exits 0 either way, so the exit-code `|| true` checked nothing; by Phase 6's own
comment that means ACT 2 ran on ACT 1's data directory while its in-memory
keyring minted a new SQLCipher passphrase. Now gated on the OUTPUT. And **Phase 6
re-applied `user-fixed` but never read it back**, unlike Phase 4 — so the one
phase that actually governs ACT 2 was the one that never confirmed the system
dialog was suppressed, leaving its stall unattributable. It now performs the
same read-back.

**5. `E2E Clock Skew` — the lane doing its job.** See the B8 owner decision
above, taken in this round.

## CI run 30964250098 — `Coverage / Flutter Coverage`, and the tooling around it 2026-08-04

**The failure.** One line:

```
BELOW   lib/src/services/
        50.99% < floor 51% (1442/2828 lines, manifest line 203).
```

Seven hundredths of a point, on a row nothing in the diff had touched.

**The cause was not coverage.** It was the pin. That row had been hand-written
as `51` against a recorded `# measured 51.06%`, where the file's own documented
rule — `floor(measured) - 2`, which `--list` implements and every other row
followed — gives **49**. A floor 0.06 points under its measurement is not a
floor, it is a tripwire: with 2828 instrumented lines in that directory, one
percentage point is 28 lines, so any unrelated change that adds a few uncovered
lines to the service layer reddens the build.

Two more rows were in the same state and had simply not gone off yet:
`src/relay/catchup.rs` at 97 against 97.14% (0.14 points; the rule gives 95) and
`geolocator_location_service.dart` at 86 against 86.72% (0.72; rule 84). Three
of fifty-four rows had drifted from the rule, and **nothing checked**. The only
thing that could observe a bad pin was a full 11-minute `llvm-cov` run, or a
5-minute `flutter test --coverage` — after the fact, in CI.

*What was built.*

* **`--lint`, a static check of the manifest against its own rule.** Every row
  must carry its `# measured N%` provenance and must be pinned no tighter than
  `floor(measured) - 2` (or exactly 100). It is a **two-sided band**, not a
  one-sided floor: `check_coverage_floors.sh:681` also fails rows pinned too
  LOOSE (5 or more points below their own provenance), so the enforced rule is
  `[measured - RATCHET_MARGIN, floor(measured) - 2]`. (CLAUDE.md's one-line
  summary says every floor "must equal `floor(measured) - 2`", which is stricter
  than what `--lint` enforces — a row one point looser still passes.) No report,
  no toolchain, ~50 ms. Also
  catches duplicate rows and rows with no recorded measurement — a floor nobody
  can re-derive is a floor nobody can review. Wired into repo-guards.yml **and**
  a new pre-commit hook, so the defect above is now caught in the diff that
  writes it. `--lint --fix` rewrites the mechanical ones.
* **`--repin`, so nobody computes a pin by hand again.** Raises floors the code
  has outgrown and refreshes their provenance, in place, preserving every
  comment, margin override and column. It is **one-directional**: a row whose
  coverage FELL is left byte-for-byte alone, because re-pinning downward is
  exactly how a measured regression gets laundered into a permitted one, and
  because rewriting the provenance alone would leave the row failing its own
  lint. Seven floors were raised in the commit that landed this; three tight
  rows were corrected downward by `--lint --fix`, and the rest held.
* **A low-headroom notice.** A row above its floor but within one point of it
  is reported (as a `::warning`, not a failure — the band exists to permit that
  state). `src/location/nostr.rs` measured exactly 50.00% against a floor of 50
  in this run and had said nothing. (Its manifest row still records the earlier
  `# measured 52.54%` — `--repin` never lowers, so a HOLD keeps its old
  provenance.)

**The second failure this run could not have caught: the instrument moves.**
The coverage jobs ran `dtolnay/rust-toolchain@stable` and `channel: stable`.
Coverage is a ratio whose denominator is *instrumented lines* — a property of
the compiler, not of the tests — so a floating toolchain silently re-measures
every path on someone else's release schedule. It already had: `stable` moving
1.92 → 1.97.1 instrumented ~400 fewer lines in haven-core and tripped seven
per-path ratchets in one run with no code change, and Flutter had moved 3.41 →
3.44.8 unnoticed. `scripts/ci/coverage_toolchain.env` now pins both, read by
coverage.yml *and* the local gate; every other workflow keeps floating, so
new-SDK breakage still surfaces — just not as a coverage number nobody changed.

**The third: the local gate was not the thing it claimed to be.**
`check_coverage.sh` said it "mirrors CI" while running four of the workflow's
seven gates. The undeclared-skip check and the rollback-path flag-off run lived
only in the workflow, so a green local run was compatible with a red CI. It also
measured Flutter from the RAW lcov where CI measured a filtered one, and
re-implemented the filter in awk — whose `/\/test\//` cannot match a
package-relative `test/foo.dart` record where lcov's `**/test/**` does, a
divergence invisible only because `flutter test --coverage` happens not to emit
test files today. It is now a **superset**: all seven gates, the filter extracted
to one script both callers invoke (`filter_lcov.sh`), the two stacks run in
parallel (slowest-of rather than sum-of), and the static gates run first and
alone so the common failure costs a second.

`VeryGoodOpenSource/very_good_coverage@v3` went with it. The workflow carried a
NOTE to replace it "before GitHub forces Node 24" — a plan that works only if
someone reads it in time — and the gate is a sum over LH/LF, four lines of awk
now shared with the local run (`check_lcov_aggregate.sh`).

**Honest about what it cannot measure.** rustc is *required* to match the pin
(rustup makes that free), so the Rust half is predictive. There is no equivalent
for Flutter, so a mismatched SDK downgrades the ratio-based verdicts to
ADVISORY, keeps the SDK-independent ones (tests green, no undeclared skips, the
flag-off run) gating, and says so in the verdict. A gate that fails on a number
it knows it cannot measure is a gate that teaches `--no-verify`.

*Verification.* 31 hermetic fixtures on the floors guard (18 existing + 13 new,
covering the tight pin, the fix's column/margin/comment preservation, the
one-directional repin, duplicate rows, missing provenance, and the CHECKED-IN
manifest against the rule), 12 on the filter, and 8 on the aggregate. The floors
and filter self-tests are wired into repo-guards (`:451`, `:462`, `:469`);
the aggregate's 8 ran only inside `scripts/ci/check_coverage.sh:155` — the local
pre-commit/pre-push gate — and nowhere in CI, even though this gate replaced
`very_good_coverage@v3` as the only thing enforcing the Flutter 50% aggregate.
**RESOLVED 2026-08-09**: wired as its own `repo-guards.yml` step.
Verified end to end against a real local run of both stacks: the Rust per-path
table reproduces CI's numbers line for line on the paths whose sources are
unchanged.
