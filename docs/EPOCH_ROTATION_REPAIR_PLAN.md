# Unit E — Epoch-rotation repair for sender-ratchet exhaustion (C4)

**Status:** IMPLEMENTED + REVIEWED (all phases; both final re-checks APPROVED; minors applied).
Plan confirmed 2026-08-28 (drafted by a marmot-expert agent, independently confirmed
APPROVE-WITH-FIXES by a security-reviewer agent; every fix is folded in below). Line
citations are to the pinned MDK `e391adc` / OpenMLS `04c50d7` checkouts and the current tree;
re-verify before relying on them. See "Implementation notes (core phase)" at the end for the
exact API the FFI phase must expose, the mutation evidence, and the places the shipped core
deviates from this plan's sketch.

> **Historical note (2026-08-29).** The Settings → Privacy page and every
> `privacy*` ARB string were removed by owner directive. Where this document
> cites one of those keys or the page itself, it is a record of what an audit
> found while they existed — not a surface to check, update or re-verify.
> `docs/privacy/README.md` describes what the manifest covers now.

## 1. What is actually broken (corrected)

- OpenMLS `SenderRatchetConfiguration::default() = (out_of_order_tolerance 5,
  maximum_forward_distance 1000)`; MDK never overrides it (`cgka-engine/src/wire_format.rs`
  `join_config`, `group_lifecycle.rs` create config) although the setters exist
  (`openmls/src/group/mls_group/config.rs`).
- A receiver that has missed >1000 consecutive application messages from one peer gets
  `SecretTreeError::TooDistantInTheFuture` on every later one (`sender_ratchet.rs`
  `secret_for_decryption`). MDK has NO arm for it (`ingest.rs` handles only `NoPastEpochData` /
  `TooDistantInThePast`); it falls to the catch-all → `MessageState::Retryable` + `Err`.
- **C4 is permanent for RECEIVE from that peer until the epoch advances.** Nothing advances it in
  a stable circle: epochs move only on membership changes; there is no self-update intent.
- **C2-from-C4 is TRANSIENT, not a closed loop** (correction to the draft and to the analysis
  doc): the `Retryable` row is a canonicalization input, re-fails as
  `UndecryptableInCanonicalState`, and `message_state_for_invalidated_reason`
  (`openmls_projection.rs`, "if message_epoch > resulting_tip { Retryable } else
  { EpochInvalidated }") gives it the TERMINAL `EpochInvalidated` disposition on the next settled
  pass — and Haven's `settlement_quiescence_ms: 0` (`haven-core/src/nostr/mls/manager.rs`) makes
  every pass settle. Haven's own `sweep_group_inputs` (Unit B) terminalizes it independently.
  The PERMANENT C2 case is a row whose `message_epoch > tip` (a peer on a diverged branch):
  it stays `Retryable` inside the `[tip, tip + max_rewind]` ceiling and gates sends until the
  age-based sweep (Unit B) retires it.
- Sender side: the generation is persisted before the wrap; a failed publish still burns one.
  Worst-case cadence 50 gen/h per peer per circle (`ttl.rs` jitter floor 72 s) → ~20 h of
  one-way silence to exhaustion; nominal 30/h → ~33 h.

## 2. Facts that shape the design (all confirmed at source)

- **No self-update intent exists.** `SendIntent` = AppMessage, Invite, RemoveMembers, Leave,
  UpdateAppComponents, UpdateGroupData (`traits/src/engine.rs`). Every commit-producing intent is
  admin-gated (`send.rs`, `update_group_data.rs` `require_admin`). Leave is a proposal.
- **Haven circles have exactly ONE admin (the creator)** (`haven-core/src/circle/manager.rs`
  `.with_admin(creator)`); multi-admin exists only transiently inside handoff / self-demote.
  ⇒ "lowest pubkey commits" is unimplementable; the only possible committer is the sole admin.
- **The only rekey vehicle Haven can author today** is a byte-identical
  `UpdateAppComponents(admin-policy.v1)` commit (`session.update_admin_policy(gid, &current)`),
  which: resets every sender ratchet (fresh `encryption_secret` → fresh `SecretTree`,
  `staged_commit.rs` / `schedule/mod.rs`); emits NO user-visible state change (empty
  `admin_changes`); and carries NO UpdatePath — `force_self_update` defaults false and
  `AppDataUpdate` is not path-required — so it provides **no post-compromise security**. Never
  call it "key rotation" or claim forward-secrecy benefit (documentation-accuracy pillar).
- **Load-bearing invariant that makes the repair work at all:** MDK runs
  `PURE_PLAINTEXT_WIRE_FORMAT_POLICY`, so commits travel as `PublicMessage` and never touch the
  SecretTree (`processing.rs` `will_modify_secret_tree` is PrivateMessage-only). A member whose
  application-message ratchet for a peer is exhausted can therefore still ingest and apply the
  repair commit. This MUST be pinned by the e2e test.
- **The auto-committer is NOT admin-gated** (`auto_committer.rs` `decide_with_reason` checks only
  SelfRemove / not-self / leaver-not-admin), and a SelfRemove-only commit is an authorized
  non-admin shape (`app_components.rs` `is_allowed_non_admin_commit` shape (b)). A non-admin's
  auto-commit can race an admin's rotation at the same epoch → quiescence gate required.
- **Cross-restart twin fork is still live** (M11 §H2): `EpochManager.committed_from` is
  in-memory; after a restart a same-epoch sibling commit falls to `MessageState::Failed`, which is
  excluded from canonicalization inputs. Binding consequence: any Haven commit author must be
  structurally single-committer; "the engine will reconcile it" is not a defence.
- MDK's receiver-side validator ALREADY permits a bare self-update commit from a non-admin
  (`is_allowed_non_admin_commit` shape (a), "self-update only"). Only the `SendIntent` is missing
  upstream — which is why the upstream ask below includes it.
- Rule 5 (`DEFAULT_MAX_PAST_EPOCHS = 5`) is harmless here: application messages expire at 228 s,
  orders of magnitude inside any epoch-retention window.

## 3. Why a PERIODIC rotation is rejected

1. **Margin 1.67×:** a 12 h cadence admits up to 600 generations per epoch against 1000; one
   missed rotation (leader offline 24 h) → 1200 → C4 fires anyway.
2. **It cannot protect the sole admin from its own outage** — only the admin can commit, and the
   device that failed in the field was the owner = admin.
3. **It introduces a NEW permanent blackout mode:** a returning receiver must obtain EVERY commit
   issued while away; commits carry no `expiration` and Marmot/MDK have no resend / external
   commit / re-add-yourself path, so one relay-dropped commit strands the receiver at the old
   epoch. Today's stable circles emit essentially no commits.
4. Periodic per-circle commits are a cross-circle correlation signal at the relay (would need
   independent per-circle phase + ≥±25 % jitter — inapplicable to the repair-triggered design).

## 4. What ships: a REPAIR-TRIGGERED rotation (admin-stuck only)

Same commit, same Rule-13 envelope, invoked only when the circle is already stuck (user tap on
Unit D's "Sharing paused — Repair" banner, or D's automatic repair). No periodic relay metadata;
no new steady-state failure mode; repairs the field case (the admin's own SEND ratchet is fine —
only its DECRYPTION ratchets for peers are exhausted).

**Honest limit, to be disclosed in UI copy and docs:** it repairs the ADMIN-stuck case only. A
stuck non-admin cannot author a commit and there is no "please rekey" message; its path is
disclosure + "ask this circle's admin to remove and re-add you" — until upstream exposes a bare
self-update intent (§6).

### Gates (all necessary; evaluated in a pure, property-tested function)
1. `admins == [self]` (divergence-safe by construction; self-suspends during a handoff).
2. Engine epoch state `Stable`. Preferred: an upstream `AccountDeviceSession::epoch_state(gid)`
   getter and a pre-send gate. Interim: match `SessionError::Engine(EngineError::InvalidTransition
   { from, .. })` BEFORE `map_mls_err` stringifies it (the `AdminCannotSelfRemove` precedent in
   `nostr/mls/manager.rs`), keying on the `from` token from `EpochState::name()` — an
   enum-derived `&'static str`, NOT prose — and say so in the comment; pin the token set in a test.
3. No epoch change observed for the circle within the last 24 h (durable timestamp).
4. Quiescence: no inbound group event for the circle within the last N s and no pending
   proposal (closes the auto-committer race).
5. Main isolate, foreground, live-sync engine running (Rule 14; enforced by a repo guard, not a
   comment). Never from `background_location_task.dart` / `background_catchup_worker.dart`.
6. One rotation per circle per 24 h, persisted.
7. `effects.queued` is checked BEFORE `take_group_evolution` (mirroring Unit B's
   `encrypt_location` handling): a repair issued while the circle is send-gated must surface a
   typed deferred outcome, not the opaque "produced no GroupEvolution publish work" error.

### Files
| File | Change |
|---|---|
| `haven-core/src/circle/rotation.rs` (new) | pure `rotation_decision(self_id, admins, last_epoch_change_at, last_rotation_at, last_inbound_event_at, now) -> Rotate \| Skip(reason)` |
| `haven-core/src/circle/manager.rs` | `repair_epoch_rotation(gid) -> Result<RepairRotationOutcome>` mirroring `propose_self_demote`; byte-identical admin set; `effects.queued` check first |
| `haven-core/src/nostr/mls/manager.rs` | typed `EpochNotStable` per gate 2 |
| `haven-core/src/circle/storage.rs` | presence-only `last_rotation_at`, `last_epoch_change_seen_at` on the existing circle row (shares Unit D's health migration) |
| `haven/rust_builder/src/api.rs` | `repairEpochRotation(mlsGroupId) -> RepairRotationOutcomeFfi` (`CommitToPublishFfi` already has a redacting Debug); `./scripts/regenerate_frb.sh` |
| `haven/lib/src/services/nostr_circle_service.dart` | `repairCircleEpoch` reusing the existing publish → `confirmPublished` on ≥1 OK-ack / `publishFailed` ladder |
| Unit D banner | admin → Repair; non-admin → "ask this circle's admin to re-add you" |
| `haven/lib/src/providers/self_update_provider.dart` | DELETE (documented no-op); also remove its reads in `map_shell.dart` (two sites), delete `haven/test/providers/self_update_provider_test.dart`, fix prose references in `invitation_card.dart`, `live_sync_provider.dart`, `docs/M11_ROLLOUT.md` §10 |
| `haven/test/lints/self_update_disabled_test.dart` | keep the FILE and the test name cited by `docs/privacy/privacy_invariants.json` `INV-E-NO-PERIODIC-REKEY` (`check_privacy_invariants.sh` rule 3 hard-fails on a broken citation); extend it: no `Timer.periodic`/scheduled rotation driver anywhere in `lib/`; `repairEpochRotation` referenced only from the foreground service layer, never from the background isolate files |
| `haven/lib/l10n/app_en.arb` (+ ×13) | `:789` "changes keys only when someone joins or leaves, never on a timer" and `:801` "moves to a new epoch only when its membership changes" become false the moment ANY rotation ships → re-word to "…or when you repair a circle", re-translate ×13 with the mandated translator + independent reviewer agents, `arb_parity_check`, `flutter gen-l10n`; revise `INV-E-NO-PERIODIC-REKEY`'s statement (never-on-a-timer stays TRUE; "only on membership change" does not) and re-run `scripts/ci/check_privacy_invariants.sh` |

### Tests (deterministic; must FAIL when the promise breaks)
- `haven-core/tests/ratchet_forward_distance_e2e.rs`: two `CircleManager::new_unencrypted()`
  engines; B publishes while A ingests nothing until A's first failure; assert the boundary equals
  the CONFIGURED `maximum_forward_distance` read at runtime (not a hard-coded 1000, so the test
  becomes the upstream-fix detector); then `repair_epoch_rotation` on A (the admin) → publish →
  `confirm_published` → deliver the commit to B → **assert A applies the commit while its ratchet
  for B is exhausted** (the PublicMessage invariant) → A decrypts B's next message.
- `rotation.rs` unit + proptest: at most one `Rotate` across any pair of divergent roster views;
  pin `{A}` vs `{A,B}` in both lexicographic orders; negative control showing lowest-pubkey fails.
- Publish-before-apply: zero acks → `publish_failed` → `group_epoch` unchanged and
  `encrypt_location` still `Sent`.
- No phantom `GroupStateChange` on author confirm or peer ingest.
- Gate matrix with an injected clock (admins.len() != 1; admins == [other]; rotation < 24 h ago;
  inbound event inside quiescence; non-Stable; send-gated → typed deferred).
- Isolate/foreground guard (static + behavioural). Copy-accuracy: no "key rotation" / forward-
  secrecy claim in any new string.

## 5. Risks (explicit)
- C4 stays REACHABLE until upstream ships; this shortens recovery from "impossible" to "one tap,
  admin only".
- Non-admin-stuck has no self-service repair until the upstream self-update intent exists.
- Unit B is a prerequisite (a rotation is a `send`; gate 7).
- The cross-restart fork window is pre-existing for every Haven commit; upstream issue below.

### 5.1 The engine re-reads the whole retained message history on every send

`should_queue_outbound_intent` → `advance_convergence_inputs_until_settled` →
`list_messages` walks every retained row for the group on **every** send, and a Haven circle's
tip does not move, so the window never sheds anything. Two further call sites list from
`EpochId(0)` — i.e. the entire history regardless of window — in
`openmls_projection.rs:~674-676` and `:~1174-1176`; and `snapshots/restore.rs:~64-91`
amplifies it again, re-reading the same rows per retained snapshot.

Measured at MDK `e391adc`: **0.31 ms per retained row at `opt-level = 2`**, against a flat
**0.8 ms** for the equivalent OpenMLS-only control — i.e. the cost is the row walk, not the
crypto. At 30 fixes/hour/member a two-member circle accumulates **~10 k rows/week**, so a send
in week two costs seconds of CPU. This is the reason
`tests/ratchet_forward_distance_e2e.rs` cannot walk the boundary through `CircleManager`
(sends 0–100 took 64 s and 100–200 a further 197 s on a debug build; extrapolating to ~1.8 h).

It is a battery and latency cost on every publish, on the device, forever. Not this unit's to
fix — see §6 issue 2 and the safety contract there for why a Haven-side prune is not available.

### 5.2 Two marginal relay inferences the repair adds

Both are weak and neither is a reason not to ship, but they are new and belong on the record:

* A repair commit is a `kind:445` with no `UpdatePath` and no accompanying `kind:1059`s. Its
  size class therefore differs from an invite (which is always accompanied by gift wraps) and
  from a member removal, so a relay can distinguish "this circle re-keyed" from "this circle
  changed membership" without decrypting anything.
* A repair commit appearing after a long gap in a circle's traffic is a signal that **this
  circle was stuck** — the user's own device volunteers, on the wire, that its receive plane
  had failed. The repair is rare and user-triggered, so this is a low-rate leak, but it is
  information a healthy circle never emits.

## 6. Upstream ask (to file against marmot-protocol/mdk; record the link here when filed)

**Title:** Expose `sender_ratchet_configuration`; default `maximum_forward_distance = 1000` makes a
long receive outage a permanent per-peer blackout; add a bare self-update `SendIntent`

**Body (summary):** (a) expose `sender_ratchet_configuration` on `EngineBuilder` /
`AccountDeviceSessionConfig` mirroring `max_past_epochs` (and expose `max_past_epochs` there too);
(b) raise the default `maximum_forward_distance` to 100 000 — no forward-secrecy cost (only
`out_of_order_tolerance` entries are retained; `prune_past_secrets` truncates every call);
(c) **migrate stored groups**: `MlsGroupJoinConfig` is persisted per group and restored on load,
so a new default heals only new groups — reconcile at `hydrate_one_stored_group` via
`MlsGroup::set_configuration`, with a test; (d) give `TooDistantInTheFuture` a TERMINAL typed
disposition (`SenderRatchetExhausted` + `MessageState::Failed` + distinguishable `StaleReason`),
symmetric with the existing `TooDistantInThePast` arm, so apps can surface it; (e) add a bare
self-update `SendIntent` — the receiver-side validator already authorizes that commit shape for
non-admins (`is_allowed_non_admin_commit` shape (a)); (f) note the per-pass DoS bound
`O(#pending_apps × #candidate_paths × distance)` HKDF expansions from a forged generation (read
from `MlsSenderData` before the AEAD open) — bounded because candidate-path replays are
snapshot-rolled-back (`snapshot_guard.rs`) and a failed decrypt never persists, but it argues for
pairing (b) with (d) and with the OpenMLS companion fix; (g) companion OpenMLS issue:
`DecryptionRatchet::secret_for_decryption` pushes every skipped generation then truncates —
push only the final `out_of_order_tolerance` entries (memory O(tolerance) not O(distance));
(h) separate issue: durable `EpochManager.committed_from` (or a non-`Failed` state for a
post-restart sibling commit) so the cross-restart twin fork can be reconciled.

### Upstream issue 2 — the per-send history scan (tracked as "Unit G")

**Title:** Every send re-reads the group's whole retained message history, so send cost grows
without bound in a group whose epoch is stable

**Body (summary):** `do_send` → `should_queue_outbound_intent` →
`advance_convergence_inputs_until_settled` → `list_messages` walks every retained row for the
group, and two further sites (`openmls_projection.rs:~674-676`, `:~1174-1176`) list from
`EpochId(0)` regardless of the convergence window; `snapshots/restore.rs:~64-91` re-reads the
same rows per retained snapshot. Measured: **0.31 ms per retained row at `opt-level = 2`**,
against a flat **0.8 ms** OpenMLS-only control — the cost is the walk, not the crypto. An
application whose groups change epoch rarely (location sharing: ~30 messages/hour/member,
**~10 k rows/week**) pays seconds of CPU per send within a fortnight. Asks: (a) bound the send
gate's scan by the convergence window instead of the full history; (b) make the two
`EpochId(0)` listings window-bounded too; (c) index or cache the gate's predicate rather than
re-deriving it per send; (d) expose a supported prune.

**The safety contract any prune must satisfy** (derived during this review; it is why Haven
cannot simply prune locally):

* An AGE-based prune of terminal application rows is a **convergence deviation**, not an
  optimisation. `Sent`/`Processed` application rows are witness inputs, re-admitted at
  `openmls_projection.rs:~741-748`, and `canonicalization.rs:~642-647` is explicit that a
  different witness set yields a different branch selection — i.e. **a fork**.
* The only spec-safe prune is: **one terminal application row per `(epoch, sender)`** inside
  `app_message_past_epoch_limit` of the tip (witnesses dedup per sender and saturate at
  `witness_quorum_senders_per_epoch`, so beyond the first the rows add no evidence), **plus**
  every row below `tip − app_message_past_epoch_limit`. Never commits, never proposals.
* A Haven-side implementation is **not available**: it would need a third
  `session.sqlite` open site, which `every_mls_database_open_site_is_sanctioned` forbids and
  which would break the Rule-14 argument that guard exists to protect. So this is
  upstream-first.

Haven cannot carry any of this locally (CLAUDE.md: MDK pinned to released tags only;
`check_mdk_supply_chain.sh`); the interim is Units A/C (shrink the outage distribution), D
(surface it), and this unit's repair.

---

## 7. Implementation notes (core phase, 2026-08-28)

Files: `haven-core/src/circle/rotation.rs` (new), `haven-core/src/circle/manager.rs`,
`haven-core/src/circle/mod.rs`, `haven-core/src/circle/storage.rs`,
`haven-core/src/nostr/mls/manager.rs`, `haven-core/src/nostr/error.rs`,
`haven-core/Cargo.toml` (one dev-dependency, see below),
`haven-core/tests/ratchet_forward_distance_e2e.rs` (new),
`haven-core/proptest-regressions/circle/rotation.txt` (new, see deviation 3).
`haven-core/src/nostr/mls/types.rs` needed NO change: `OpenMlsContentKind`,
`MessageState` and `ConvergenceSweep` were already re-exported there by Unit B, and
`ConvergenceSweep` was deliberately not widened (it crosses the FFI). Nothing under `haven/`,
`docs/privacy/**` or the ARBs was touched — that is the FFI/Dart/l10n phase.

**Copy accuracy, deferred with the FFI:** `app_en.arb` `:789` / `:801` ("changes keys only when
someone joins or leaves, never on a timer" / "moves to a new epoch only when its membership
changes") are still TRUE at this commit, because no user action can reach
`repair_epoch_rotation` until the FFI lands. The re-wording, the ×13 re-translation and the
`INV-E-NO-PERIODIC-REKEY` statement revision are phase 2's, and must land in the SAME change as
the FFI — not after it.

## 8. Implementation notes (FFI / Dart / guard / l10n phase, 2026-08-28)

Files: `haven/rust_builder/src/api.rs` (+ regenerated `frb_generated.rs` and
`haven/lib/src/rust/**`), `haven/lib/src/services/circle_service.dart`,
`nostr_circle_service.dart`, `haven/lib/src/providers/sharing_health_provider.dart`,
`haven/lib/src/widgets/map/sharing_health_banner.dart`,
`haven/lib/src/pages/map_shell.dart`, `haven/lib/src/pages/settings/privacy_content.dart`,
`haven/lib/l10n/**` (13 ARBs + regenerated localizations),
`scripts/ci/check_epoch_repair_isolation.sh` (new) + `.github/workflows/repo-guards.yml`,
`docs/privacy/privacy_invariants.json`, `docs/M11_ROLLOUT.md`, and tests.
DELETED: `haven/lib/src/providers/self_update_provider.dart` and its test.

### Mutation evidence for the phase-2 items

Same discipline as §7: each mutation was applied to the working tree, the named tests run, and
the file restored. The rows below cover the security and UI/UX review rounds on the FFI, Dart,
guard and l10n phase.

| Item | Mutation | Result |
|---|---|---|
| SEC-M1 / M4a | guard rewritten from a denylist of background entrypoints to a positive allowlist | a caller outside the allowlist passes the denylist, fails the allowlist (guard `--self-test` fixture) |
| SEC-M1 (re-check) | `sharingRepairProvider` / `repairSelectedCircleEpoch` dropped from `REPAIR_TOKENS` | guard `--self-test` fails on both wrapper probes |
| SEC-M3 | `rotated` arm stops reaching `_publishAndConfirm` | `publish_before_apply_dart_sites_test.dart` red |
| SEC-M3 | `runCatchup` moved after `repairEpochRotation` | same file red |
| S-MIN-3 | the pre-fetch left un-awaited in the same position | same file red (the pin is on the `await`, not the index) |
| S-MIN-4 | `map_err(redact_storage_error)` dropped from `circle_rotation_state` | `a_storage_failure_on_the_repair_surface_arrives_redacted_not_raw` red |
| M4b | a repair scheduled on a `Timer.periodic` | `self_update_disabled_test.dart` red |
| S-MAJ-1 | the wrappers dropped from `_repairIdentifiers` | `detects a scheduled repair through the Dart WRAPPERS` red |
| S-MAJ-1 | the `visitSimpleIdentifier` arm restricted to call targets | same test red — `ref.read(sharingRepairProvider)` is never a `MethodInvocation` |
| S-MAJ-2 | `_maxIndirectionHops` set to 0 | `follows one method extraction out of the callback` + the tear-off fixture red |
| S-MAJ-2 | `_schedulerMethods` emptied | `detects a repair driven by a cron-shaped scheduler` red |
| B1 | the post-chain health gate removed | `sharing_health_epoch_repair_test.dart` red |
| B1 | the receive-fault scope removed from `_epochCopy` | same file red |
| U-N1 | `repairIsFutile` read from the outcome alone, not the earned copy | `a SEND-side fault keeps Repair alive and reasoned` red |
| B2 | `_clearStaleEpochOutcome` made a no-op | both staleness edges red |
| M1 / M2 | the terminal outcome left tappable | the disabled-state test red |
| M3 | the five retryable gates return `null` | `a retryable skip still says something` red |
| M5 / U-N5 | epoch leg moved before the cheap remedies | `sharing_repair_composition_test.dart` red |
| M5 / U-N5 | a throwing resume / publish / refresh left uncontained | one composition test red per leg |
| U-N2 | the English privacy string regains "the person who created the circle" | `repair_copy_accuracy_test.dart` red |
| U-N2 | one locale's privacy string regains a creator + rotation term | same file red |
| U-N4 | both hedges stripped from the English Repair hint | the EN hedge test AND the per-locale `unhedged` list red |
| U-N6 | a terminal string invited a retry | the per-locale retry test red |
| U-N3 | the shadowed `"guards": []` / second `"tests"` restored | `check_privacy_invariants.sh` red on the new rule 1 duplicate-key check |
| UX-m3 | one locale regains the creator claim | `repair_copy_accuracy_test.dart` red |
| SEC-MIN | `map_err(redact_storage_error)` dropped from `get_circle` | `a_broken_circles_read_arrives_redacted_not_raw` red (arrives as `Database`) |
| R2 | ja Repair hint loses its role clause | the new per-locale ROLE check red |
| R2 | de Repair hint loses `möglicherweise` | the new per-locale MODAL check red |
| R2 | ar Repair hint loses `قد` | same check red |
| R4 | (no synthetic mutation needed) | the new control-noun check was red on the SHIPPED fr and ru strings, green after the rework |
| U-N3 (class, not instance) | a duplicate key planted in the self-test's own fixture manifest | `check_privacy_invariants.sh --self-test` fixture red (99 fixtures) |

The duplicate-key rule is worth its own note, because the obvious implementation does not work.
Every JSON reader here — jq included — keeps the LAST occurrence of a repeated key and discards the
first silently, so by the time the manifest is an object the evidence is gone; a pattern match on
the raw text is the thing this file's own comments warn against. The check counts instead: the
STREAMING parser still visits the shadowed value, so the document's value count exceeds the decoded
one by exactly the number of values the parse throws away, and for a duplicate-free document the
two are equal because the stream visits precisely the values the parse keeps. A first attempt
compared streamed leaf PATHS for repeats and was unsound in exactly the case at hand — an empty
array shadowed by a non-empty one produces two different paths, and it passed.

**R2 is worth recording as a failed first attempt.** The hint's modal hedge was pinned as a
FORBIDDEN list of flat phrasings ("gives it a new key"), and two of the three proposed mutations —
deleting `möglicherweise` from German, deleting `قد` from Arabic — stayed GREEN. A forbidden
substring only matches when the verb and its object are contiguous, and half the locales put the
role condition between them, so removing the modal left no forbidden string behind at all. It is
now stated positively: the hint must CONTAIN one of this locale's modal markers. A positive check
cannot be dodged by word order, and when it goes stale it goes stale loudly, as a failure, rather
than silently scanning for a phrasing the app no longer ships — which is exactly what the German
and Arabic entries were doing after the previous round edited those two strings.

**R3 is recorded as a hazard closed, not a defect fixed.** The banner test harness now keys each
pump so every case gets a fresh `State`. No leak is demonstrable on today's code: both state fields
are rewritten on every pump-and-tap, and a `_repairing` genuinely stuck true is caught in BOTH
harness shapes for an unrelated reason — the spinner animates forever and `pumpAndSettle` times
out. The keying forecloses the case a future field written on only some paths would open.

Three items in this round are code-review findings with no test of their own, and are recorded as
such rather than claimed as pinned: **SEC-OBS** (`_schedulerMethods` matching bare `every` /
`interval` collides with `Iterable.every`; deliberate, because the collision can only produce a
loud false positive on a callback that would have to contain a repair call to fire, whereas
dropping the names produces the silent false negative the lint exists to prevent); **S-NIT**
(taking the rotation binding before the early return in `confirm_published` / `publish_failed` —
a bounded, memory-only map that only grows on a rejected confirm); and **S-MIN-2** (a comment in
`nostr_circle_service.dart` that overstated the ordering guarantee; re-scoped to match
`circle::rotation`'s own wording).

### The FFI shapes

`RepairRotationOutcomeFfi { rotated: CommitToPublishFfi?, skipped: SkipReasonFfi?,
deferred_send: DeferredSendFfi? }` — the house three-`Option` convention rather than a tagged
enum, exactly as `EncryptLocationOutcomeFfi` and `LeavePlanFfi` do, with a presence-only `Debug`.
The field is `deferred_send`, not `deferred`, because FRB mangles the latter to `deferred_` in
Dart. `SkipReasonFfi` is a fieldless mirror; `every_skip_reason_crosses_the_boundary_as_itself`
matches it exhaustively, so a new core reason breaks compilation instead of arriving as the wrong
routing decision. Dart narrows all three into a sealed `EpochRepairResult`
(`EpochRepairApplied | EpochRepairSkipped | EpochRepairDeferred`), so the compiler owns
exhaustiveness at every call site.

### `EpochRepairSkipped.isRetryable` is a security-shaped classification, not a convenience

`notSoleAdmin` and `epochUnrecoverable` NEVER clear by waiting. Presenting either as "try again"
is a loop that cannot succeed, so the banner routes each to its own copy and only the other five
reasons fall through to the existing "still not working" behaviour. Pinned by
`the two terminal skips are not offered as retryable`.

### Fetch-first, and what it actually buys

`repairCircleEpoch` awaits `RelayService.runCatchup` before calling the FFI. It is best-effort:
a failed fetch leaves the repair on the engine's ordering guarantee, which is strictly better
than refusing to repair. What it buys is converting a same-epoch race into a clean
`pendingProposal` decline — see §7's gate-4 note for why the race was survivable anyway.

### Copy accuracy: three defects the review round caught, all now fixed

1. **The Repair hint under-described a security-relevant action.** It said only "reconnects and
   retries sending"; the button now also commits a new circle key. The hint says so, and keeps the
   clause CONDITIONAL — a non-owner's tap does not re-key.
2. **"when you repair a circle" was wrong for most readers.** Repair is admin-only, so both
   privacy strings were re-scoped. All three independent locale reviewers flagged this separately.
   The first correction was itself wrong and had to be made twice: it said "the person who created
   a circle", which an admin HANDOFF falsifies — after one, the creator can no longer repair, and
   mid-handoff there are briefly two admins. The strings now name the ROLE, using each locale's
   own Admin badge term (`circleMemberAdmin`), the same term the banner uses. The second round
   found the error had reached FOUR strings in every locale, not the two that were reviewed:
   `sharingHealthRepairNotOwner` and `sharingHealthRepairHint` said it too.
3. **`privacy_content.dart` carried a hardcoded "rotates keys only on membership change"** claim
   outside the ARB, which is exactly the class of stale non-ARB claim Workstream F exists to
   catch. Corrected.

`sharing_health_epoch_repair_test.dart` enforces the English copy: no new string may say "key
rotation", "rotate", or "forward secrecy" (the commit carries no `UpdatePath`), and the success
copy may not say "restored"/"fixed"/"working again" — peers apply the commit when they next
RECEIVE it.

English alone was not enough. `test/l10n/repair_copy_accuracy_test.dart` runs the same four claims
across **every** `supportedLocale`, each with its own forbidden vocabulary, because a guard that
only knows the English words passes every translation unconditionally — which is exactly how the
creator-vs-admin error survived twelve locales at once, and how all twelve came to say the others
catch up "the next time their phones send a location", which is not how the repair propagates. It
also fails if a locale is added without a forbidden list, so a new language cannot be scanned
against nothing and report coverage it does not have.

### The banner review: three defects that were about the MODEL, not the words

The UI/UX round blocked on three things the copy round could not have caught, because each is
about when a string is shown rather than what it says.

**The remedy was routed before the health model was consulted.** `_repair` returned the epoch copy
unconditionally, so a non-admin whose relay fault the EARLIER legs had just fixed was still told to
ask the admin to remove and re-add them — advice about a problem they no longer had. Worse, the
same advice appeared against a SEND-side fault, where a ratchet reset repairs nothing. The health
verdict is now read after the whole chain, and the epoch leg speaks only for a receive-side fault
(`receiveSilent`, or a lost receive subscription). The gate covers the leg as a whole, not each
outcome: against a send fault even "nothing to repair right now" is wrong, because the user reads
it as the verdict on the entire tap.

**The remedy outlived the incident.** The banner's `State` survives the banner disappearing —
`build` returns `SizedBox.shrink()`, it is not unmounted — so the next unrelated fault re-surfaced
the previous incident's advice. It is now cleared on both edges: the fault clearing, and the
selected circle changing (the widget is `const` with no per-circle key, so "this circle's admin"
would otherwise name the wrong person's circle).

**The outcome was announced but not reachable.** Everything under the status node is inside
`ExcludeSemantics`, so a remedy that was rendered there and spoken once was gone the moment the
announcement finished: a screen-reader user who swiped back over the banner heard the fault and
never what to do about it. The outcome is now folded into the live-region label, which both makes
it re-readable and re-announces it on Android — so the explicit `sendAnnouncement` is skipped
whenever the label carries it, or it would be spoken twice. The unresolved announcement remains
for the case where the leg earned no line at all.

Two smaller ones from the same round: the two TERMINAL outcomes now disable the Repair button and
give it a reason (`sharingHealthRepairUnavailableHint`) rather than leaving a live control that
cannot succeed — WCAG 2.1 SC 4.1.2 requires the disabled state to still say why — and the five
retryable gates gained `sharingHealthRepairNothingToDo`, because a tap that produced no visible
change reads as a broken button.

### The l10n rounds and what the reviewers actually caught

Four translator rounds, each with an INDEPENDENT reviewer per locale (the `CLAUDE.md` two-agent
mandate). The reviews were never a formality — every round found copy that was false, not merely
awkward.

Rounds 1–3 (five keys × twelve locales) caught: **French** — `ne reçoit plus` let `jamais` chain
into `ne…plus…jamais`, attaching the timer negation to the delivery clause instead of the key
change; **Arabic / Persian** — a demonstrative that could bind to the wrong antecedent, leaving
the negation ambiguous; **Hindi** — a verbless fragment with a coherent wrong reading;
**Russian** — an ambiguous pronoun antecedent; **Urdu** — number agreement. All three reviewers
independently flagged that the English said "when **you** repair a circle" while repair is
admin-only, which triggered round 3 plus two more English fixes (the a11y hint had become an
incomplete description of a security-relevant action; `privacy_content.dart` carried a hardcoded
"rotates keys only on membership change" outside the ARB).

**Round 4** (ten keys × twelve locales) is the one worth reading, because it caught two errors
that were present in EVERY locale at once — the class a single-locale spot check cannot see:

* **All twelve said the others catch up when their phones next SEND.** They apply the repair when
  they RECEIVE it; the two are unrelated events, and the English had said the same thing before
  round 3 corrected it. Every locale had faithfully translated the wrong claim.
* **Round 3's own fix was wrong.** "The person who created a circle" is falsified by an admin
  HANDOFF: afterwards the creator cannot repair, and mid-handoff there are briefly two admins. The
  strings now name the ROLE via each locale's `circleMemberAdmin` badge term. Two Persian and one
  French reviewer found the same error still sitting in `privacyEncryptionKeysChangeOnMembership`
  and `privacyEncryptionDetailEpochs` — **in the English source**, outside the keys they were
  given — which is how those two came into this round's scope.

Round 4's reviewers were asked to verify the translator's stated REASONING, not only its output,
after the member-picker round found a confident rationale producing misgendered text. That paid
for itself: **eight of twelve reviewers found at least one rationale that did not hold**, most
often a translator describing a substitution it had not actually made (the privacy paragraphs had
no repair clause at all before this unit, so nothing was "swapped"), and in three cases a
linguistic claim that was simply false — Hindi honorific plural is masculine plural, not
gender-neutral; Russian `админ` is a masculine noun neutral by reference, not common gender;
Nepali `-दा` converbs *do* have an honorific form. In each case the output was still right, but
the stated reason was not the reason.

Nine locales took at least one FIX:

| locale | what the independent reviewer changed |
|---|---|
| de | the hint's trailing `wenn`-clause could attach to the whole coordination, so aloud it said reconnecting and re-sending are admin-only — moved into dashes inside the third conjunct |
| es | the role was not scoped to the circle ("whoever has the Administrator role"), so an admin of a DIFFERENT circle would act on it; privacy callout re-ordered, its clitic antecedent had been buried inside a PP |
| fr | `parce qu'il a cessé de recevoir` re-gendered the admin masculine two words after the passive was chosen to avoid exactly that, and moved the symptom onto the person → `les positions n'y arrivent plus`; the elided noun in "passe à une nouvelle" was completed, because the two neighbouring strings make a reader hear *clé*, in the paragraph whose job is to introduce *époque* |
| ar | orthography that changes what a screen reader says: `أُرسل` without the kasra is also readable as 1sg "I send"; moved to the file's `تم + مصدر` idiom, and took the file's own "catch up" collocation, which takes the CHANGE as complement — taking the person reads as physical motion in a location app |
| ja | 渡す means *hand over to another party* in all four of its other uses in this file, so "may hand a new key over" was the opposite of what the button does → 新しい鍵に切り替える |
| pt | `pode dar a ele uma chave nova` reads as conditional permission to the USER (*pode* is 3sg for both), turning the hedge into a flat capability claim, and the animate dative could be heard as "give **him** a new key" |
| ru | bare `Остальные` with no stated referent after a fault line; the hint put 3sg `может` directly after `вы` |
| tr | `istemek` needs an ablative addressee, so the requestee never arrived in the spoken sentence; `Haven anahtarları` parses as the compound "Haven's keys" in a paragraph about keys; two `-DIğIndA` clauses joined by `ve` invited a CONJUNCTIVE reading of the two triggers — factually wrong, since either alone changes the key |
| ur | `ساتھ آنا` is "come along", not "catch up", and reads literally in a location app; `کے ذریعے` is administrative register in a deliberately plain file |
| ne | two strings had been raised to उहाँ-grade, the only two such references in 570 lines |
| fa | `پس از آنکه ... نمی‌رسد` is an English calque; Persian marks anteriority with the past |
| hi | PASS on all ten |

**Round 5** (ten keys × twelve locales) was driven by a single English error and by the shape that
had survived four rounds. `sharingHealthRepairUnavailableHint` said "This circle cannot be
repaired on this phone" — false in one of the two cases it covers, because when the user simply is
not the admin the circle CAN be repaired, which the banner line beside it says outright. Every one
of the twelve locales had translated it faithfully, and in **eleven of them it was a verbatim copy
of the first clause of `sharingHealthRepairNeedsNewCircle`**, so a screen-reader user on the
unrecoverable path heard the same sentence twice in a row. It now says only that the control is
unavailable; the banner carries the reason.

Nine locales' reviewers reported PASS. Four took a FIX, three of which were regressions this
round's own translator introduced — the recurring failure, once more:

* **German** — `Frag diese Person, ob sie dich entfernen und wieder hinzufügen kann` put a second
  `kann` two seconds after the capability `kann` in the preceding sentence, making the ability
  reading live where the English is a flat request. Also `dem Kreis` where every sibling says
  `diesem Kreis`.
* **French** — moving the role condition to the end of the hint let a trailing `si`-clause scope
  over the whole coordination, so it read as "reconnects, resends AND may re-key, *if you are the
  Admin*". The first two happen for everyone, and this hint is spoken while the button is ENABLED,
  i.e. to non-admins. Reverted to the condition inside its own conjunct, as the English has it.
* **Turkish** — splitting the paragraph so each trigger carried its own predicate left the
  "never on a timer" absolute with a null subject two sentences from `Haven`, with `kendi
  yöneticisi` as the nearest nominative: the guarantee shrank from a property of Haven to a
  statement about one person's habits.
* **Portuguese** — `Seu aparelho` where the file says `dispositivo` in eight of nine occurrences.

Reviewers again audited reasoning, not only output, and again it paid: **eight of twelve found at
least one rationale that did not hold**, every time on a string whose OUTPUT was fine. Spanish's
"a bare `Reparar` garden-paths as an imperative" was wrong (every action label in that file is an
infinitive) though the fix was right for a different reason; Japanese's backward-attachment
argument was blocked by a closed `とき` constituent, but the forward priming it half-described is
real; Arabic's maṣdar was not "equally readable" as repairing the ADMIN, though it does garden-path
before `لها` arrives; French's `le`-clitic could never have meant the Admin (a non-reflexive clitic
cannot corefer with its own subject); Persian's "removes a stacked که" claim was backwards — the
new text has two. Two reviewers found errors their translator had CREATED and not noticed: Arabic's
new clause left the "never on a timer" absolute with `مشرفها` as its nearest subject (fixed by
re-naming `Haven`), and Turkish's split did the same thing.

Hindi's reviewer adjudicated an open trade-off the translator had honestly disclosed: three strings
agree a verb with the admin using honorific plural, which in Hindi IS masculine plural. The ruling
was to keep it — `एडमिन` is an invariant loanword with no gender morphology of its own, so the only
gender signal is the verb, where masculine is the unmarked value; the file has no feminine
agreement with a human referent anywhere in 567 strings; and the genuinely neutral alternative
(an agentive passive) would be the only one in the file. Recorded as a language property, not a
copy defect.

**Round 6** was three strings, and all three were the same class of error: a nominalisation
standing where a control should be named.

`sharingHealthRepairUnavailableHint` is spoken while the Repair button is DISABLED, and it covers
two outcomes — the circle is unrecoverable here, OR this user is simply not its admin. In French
("La réparation est indisponible…") and Russian ("Исправление недоступно…") the subject was the
ACT, so aloud both said *repairing this circle is impossible*, which is false in the second case
and directly contradicts the banner line beside it. Russian now names the control and keeps the
label; French names it without the label, because the button's own label and role are spoken
immediately before the hint from the same merged semantics node, so echoing it stutters inside two
seconds. Persian's `sharingHealthRepairSent` had the mirror problem: «رفع مشکل فرستاده شد» sends an
act, which is a category error, and it also left the next sentence's «آن» pointing at nothing
receivable. Naming the message fixes both.

The reviewers again earned their round. French rejected the first replacement on register — the
file's *bare noun + indisponible* pattern is exclusively labels and statuses, never hints, and
every real hint in it is verbal — and supplied the file's own frame instead. Persian asked for one
codepoint: an explicit ezafe kasra on «پیامِ», because unmarked the string contains the garden path
«پیام | رفع مشکل فرستاده شد» — the exact rejected reading — which a TTS engine must guess its way
out of, and the file already marks 24 such heads for the same reason. Two reviewers found their
translator citing a real convention through the wrong line (French's "Cette action est
irréversible" is in `relaySettingsRestoreBody`, not `relaySettingsResetConfirm`; Russian's quoted
-label precedent is a page name, not a control), with the conventions themselves intact. Russian,
which had had no native review until now, was ACCEPTED unchanged and its other nine strings
audited clean.

French's reviewer also caught a documentation regression the code had caused: the English
description for that hint still explained itself with "the banner line beside it is scoped to
receive-side faults", which stopped being true when U-N1 gated `repairIsFutile` on the copy having
been earned — the banner line is now always present when the button is dead. The practical point
survives for a different reason (the button is its own focusable node, so a user arriving by focus
traversal hears the hint and not the line), and the description now says that instead.

**The Japanese punctuation call, decided by the reviewer, not by matching English.**
`sharingHealthRepairUnresolvedAnnouncement` had a 。 added on request. The reviewer counted the
file: 68 announcement/semantics/hint strings, exactly two ending in 。. The string is never
rendered — it is a standalone `sendAnnouncement` utterance — so at default verbosity the 。 buys
nothing, and at raised verbosity VoiceOver speaks it as 「まる」, making the two halves of the SAME
banner's state machine audibly asymmetric for no information. Dropped. The file's real rule is the
one now followed throughout this feature: rendered prose takes 。, spoken-only does not.

### Rule 14 / gate 5

`scripts/ci/check_epoch_repair_isolation.sh` (with `--self-test`, both wired into
`repo-guards.yml`) is a positive **allowlist**: exactly four Dart files plus the FRB output may
name `repairEpochRotation`/`repairCircleEpoch`, and it fails if any of the four stops existing, so
a rename cannot silently empty the allowlist. A denylist of background entrypoints was the first
shape and was wrong — it passes by default for any file nobody thought to list.

Its token list names the Dart WRAPPERS as well as the two FFI methods. That was the re-check's
finding and it was correct: a probe outside the allowlist calling `ref.read(sharingRepairProvider)()`
names neither FFI method and re-keys all the same, so listing only what the wrappers wrap guarded
nothing. Both wrapper shapes are now red fixtures in the guard's `--self-test`.

It deliberately does NOT scan for schedulers. Two allowlisted files hold legitimate unrelated
`Timer.periodic` calls (the banner's re-render tick, the health model's own poll), so a
file-scoped grep flagged them; a line-scoped one is trivially defeated by putting the call on the
next line. Periodicity is owned instead by `self_update_disabled_test.dart`, which parses `lib/`
with `package:analyzer`.

What that lint proves, stated precisely, because the first version's claim was too strong: it
collects every body a scheduler will run later — a function literal argument, and a TEAR-OFF,
which is not a literal at all — then flags a repair name inside that body **or inside a function
it calls, up to two hops within the same file**. Lexical nesting alone was not enough, and the
counter-example was in this repository: `Timer.periodic(d, (_) => _tick())` with the repair inside
`_tick` is the shape `sharing_health_provider.dart` uses for its own health tick, and a walk that
only looks outward from the invocation calls it clean. Two hops, not unbounded, because this is a
syntactic parse of one file with no element model — a name resolves to a same-file declaration or
not at all. Schedulers are matched both by exact call form (`Timer.periodic`, `Future.delayed`,
`Stream.periodic`) and by METHOD NAME alone (`schedule`, `periodic`, `registerPeriodicTask`, …),
because a cron package or a WorkManager binding is reached through an instance whose variable name
the lint cannot know. Its fixtures include the indirection, the tear-off, the cron and
WorkManager shapes, both wrapper shapes, and negatives: an unrelated timer in the same file, an
extraction that never reaches a repair, and the identifier inside a comment or a string.

### The privacy invariants

`INV-E-NO-PERIODIC-REKEY` and `INV-K-M5-SELF-UPDATE-DISABLED` both said keys change *only* on
membership change. Both now state the two triggers and keep the absolute half — nothing re-keys
on a timer — as the claim the copy makes. `INV-K` re-pointed its cited symbol from the deleted
provider to `circle::rotation::rotation_decision`, re-cited the two new lint tests, and gained the
new guard. `check_privacy_invariants.sh` passes with **no declared override**: the ratchet found
no unstated weakening, because the guarantee the copy makes did not weaken — only the description
of what changes an epoch got more complete.

### What is NOT covered by a Dart test, and why

The service ladder itself (`rotated` → publish → confirm; zero-ack → `publishFailed`; `deferred`
→ the auto-commit ladder) has **no pure-Dart test**. `NostrCircleService` reaches the core through
a concrete `CircleManagerFfi`, which cannot be constructed or mocked without the native library —
the same constraint Unit B hit, which is why its ladder tests live at the `LocationSharingService`
layer instead. The ladder itself is the SAME `_publishAndConfirm` helper `updateCircleRelays`,
`removeMember` and the handoff steps already use, and the Rust side pins the Rule-13 contract
(`a_repair_no_relay_acked_applies_nothing_and_leaves_the_circle_sending`,
`a_confirmed_repair_records_the_rate_limit_and_a_rolled_back_one_does_not`).

The review round would not accept that as the whole answer, and it was right not to: "the same
helper as three other call sites" is an argument about the code as written, and nothing would fail
if a later edit stopped using it. So `publish_before_apply_dart_sites_test.dart` gained AST pins on
the ladder's SHAPE — the `rotated` arm reaches `_publishAndConfirm`, the `deferred` arm reaches
`_resolveDeferredWork`, no `.pending` is read without a resolver, and the `runCatchup` call is
positioned before the `repairEpochRotation` call (the fetch-first ordering below, which is
otherwise only a comment). Those are structural, not behavioural — they prove the wiring exists,
not that it behaves — and that distinction is why the paragraph above stays.

What IS tested behaviourally in Dart: the epoch leg's gates and error containment, the outcome
routing, the copy in every locale, and the composition of the four repair legs
(`sharing_repair_composition_test.dart` — the epoch leg runs after resume and publish and before
the refresh, and still runs when an earlier leg throws).

### The FFI phase MUST fetch before rotating

`repairCircleEpoch` has to `await` one relay fetch / live-sync drain for the circle's `#h` and let
it settle BEFORE calling `repairEpochRotation`. The reason is gate 4's exact half: a departure
proposal that is sitting on a relay but has not yet reached this device turns into a same-epoch
race, whereas the same proposal ingested first turns into a clean `Skipped(PendingProposal)`
decline. The engine's ordering makes the race survivable (one extra epoch, never a fork), but the
fetch converts a race into a decline for free, and the user is already waiting on a button press.
Reuse `CatchupService.runCatchup` or `fetchMemberLocations`; do not add a new fetch path.

### The repair is not effective the moment it is confirmed — Unit D's copy must say so

Confirming the commit advances the AUTHOR's epoch. Every peer keeps publishing at the OLD epoch
until it receives and applies the commit, and those publishes stay undecryptable to the author
because they are still sealed under the exhausted ratchet. Recovery for a given peer begins only
once THAT peer has applied the commit and sent its next fix — one relay round trip plus that
peer's own publish cadence (up to 168 s), and longer for a peer that is asleep or offline.

So the user-facing copy must not promise instant recovery, and the "Repair" affordance must not
clear its own banner on the confirm. The honest signal is Unit D's existing delivery evidence:
the banner clears when a peer event actually arrives again.

### The exact core API the FFI phase must expose

- `CircleManager::repair_epoch_rotation(&self, mls_group_id: &GroupId, now_secs: u64)
  -> Result<RepairRotationOutcome>` — the one entry point. `now_secs` is the wall clock in
  Unix seconds (injected so the gates are testable without sleeping; production passes the
  real clock).
- `RepairRotationOutcome` = `Rotated(CommitToPublish)` | `Skipped(SkipReason)` |
  `Deferred(DeferredWork)`, re-exported from `haven_core::circle`. **Match the variant; never
  test error prose** — the same rule Unit B's `SendDeferred` carries, for the same reason.
  - `Rotated` → publish `commit_event`, then `confirm_published` on a ≥1-relay OK-ack or
    `publish_failed` on failure. `CommitToPublishFfi` already exists with a redacting `Debug`.
  - `Skipped(SkipReason)` → a normal, user-visible answer. `SkipReason` is a fieldless enum
    (`NotSoleAdmin`, `EpochNotStable`, `EpochUnrecoverable`, `RecentEpochChange`,
    `RecentInboundTraffic`, `PendingProposal`, `RotatedRecently`), so it crosses the FFI as a
    plain discriminant with nothing to redact. **Three route differently and the UI must not
    collapse them:** `NotSoleAdmin` → "ask this circle's admin to remove and re-add you";
    `EpochUnrecoverable` → the same, and NEVER a retry, because that state does not clear by
    waiting; everything else → "try again shortly".
  - `Deferred(DeferredWork)` → run the SAME Rule-13 ladder Unit B's `SendDeferred.work.commits`
    already has a Dart implementation for (`LocationSharingService._publishAutoCommits`).
- **There is no `note_rotation_confirmed`.** The 24-hour rate limit is recorded inside
  `CircleManager::confirm_published` itself, through an in-memory `pending → nostr_group_id`
  binding registered when the rotation is staged (mirroring the existing `create_pending` map).
  This deviates from the plan's sketch deliberately: an extra FFI call the caller could forget
  would silently leave the circle with no rate limit at all, and folding it in is both smaller
  overall (no FFI method, no Dart call site) and provably correct — `publish_failed` drops the
  binding without recording, so a repair no relay acked is retryable at once.

### Gate 2: the mechanism actually shipped, and why it has TWO outcomes

`AccountDeviceSession` at MDK `e391adc` exposes `epoch`, `members`,
`has_pending_convergence_inputs` and `quarantined_groups`, but **no epoch-state getter**
(confirmed against `crates/cgka-session/src/lib.rs`), so gate 2 is answered in two halves:

- **Pre-send:** `group_is_unrecoverable` is read from the `GroupUnrecoverable` set the receive
  path already records — the only non-`Stable` state observable without attempting a send.
- **Post-send, typed:** `SessionManager::update_admin_policy` no longer routes through
  `Self::send` (which stringifies through `map_mls_err`). It matches
  `SessionError::Engine(EngineError::InvalidTransition { from, .. })` on the `from` token, which
  `EpochState::name()` derives from the enum.

The classifier has **two** buckets, and collapsing them would be a UI defect:
`EPOCH_RETRYABLE_TOKENS = {PendingPublish, Merging, Recovering}` → `NostrError::EpochNotStable`
→ `SkipReason::EpochNotStable` ("try again shortly"); `EPOCH_UNRECOVERABLE_TOKEN` →
`NostrError::EpochUnrecoverable` → `SkipReason::EpochUnrecoverable`, which never clears by
waiting and must never be offered as a retry. `"Stable"` is deliberately in NEITHER set: it is
the one state a commit is accepted from, so it can never be a refusal's `from`, and listing it
would classify a hypothetical future refusal as retryable on no evidence.

This is a **token match, not a distinct upstream variant**: `cgka-engine` reuses one
`InvalidTransition` for a non-`Stable` epoch state, a removed local copy (`from = "Removed"`)
and a leave in flight (`from = "Leaving"`), and only the first two buckets are about the group
settling. The classification is pinned by
`every_epoch_state_name_is_pinned_by_the_token_set`, which builds all five real `EpochState`
values through the public transition API and asserts each lands in **exactly one** bucket, with
an exhaustive `match` so a new upstream variant breaks compilation;
`only_an_epoch_state_transition_maps_to_epoch_not_stable` pins the negative half; and
`a_group_with_a_commit_already_staged_declines_the_repair_as_busy` drives a real staged commit
through the whole path so the classifier is pinned to be ON it. §6(a) removes the interim.

### Gate 4: what stamps the quiescence window, what it is, and the deviation

The time half reads a `circle_health` column, `last_inbound_event_at_ms`, written by
`CircleManager::note_inbound_group_events` from the three receive funnels (the poll path in
`decrypt_location_collecting_commits`, the live-sync processor, and the catch-up sweep, each
including its convergence re-tick). It replaces `last_peer_event_at_ms`, which the review
correctly found INERT here: that column is stamped by Dart only after a peer location was
decrypted **and** persisted, which a C4-stuck admin never manages.

**What this half actually is: a cheap liveness filter, not a delivery-skew bound.** It is
anchored to "when did we last hear anything authenticated", not to any proposal, so a proposal
that never reached this device is closed by nothing in it, at any window size. What closes the
race is:

1. **Every proposal this device ingested** — gate 4's EXACT half, a durable, restart-proof
   storage read that keeps declining until the departure commits.
2. **A proposal that reached a peer but not us** — the ENGINE, though scoped more narrowly than
   an earlier draft of this section claimed. **At the `fork_recovery` seam** the tie is decided by
   priority: both commits carry the same `source_epoch`, `CommitOrderingKey::cmp`
   (`traits/engine.rs`) breaks the tie on `priority`, and the LOWEST key wins
   (`fork_recovery.rs`: a candidate `>=` the incumbent loses). The rotation is an
   `UpdateAppComponents(admin-policy.v1)`, which `commit_ordering_priority_for_staged`
   (`app_components.rs`) classifies `Privileged`; a SelfRemove-only auto-commit is `Ordinary`, and
   `Privileged` is declared first, so it sorts below and the rotation wins.

   **The convergence selector is a different seam and does not agree by construction:** it
   consults priority only FIFTH, after commit depth, witness quorum, valid depth and app-witness
   score. So the rotation *usually* wins, not always — and either way one branch converges and
   every replica lands on it, which is the property that actually matters here. Do not restate
   this as "wins on every replica".

   Residual: one extra epoch, never a fork — plus one cost worth naming. When the rotation
   LOSES, the 24-hour rate limit was still spent on a commit that did not survive, because the
   charge happens at `confirm_published`, before branch selection can be known. That circle waits
   a day for its next repair. Charging on the confirm is nonetheless the right side to err on:
   not charging would let a losing commit be retried in a loop. The pre-existing cross-restart
   twin fork (M11 §H2) is unchanged by this unit and is the only fork-shaped risk here. Pinned by
   `a_rotation_racing_a_departure_at_one_epoch_resolves_to_the_rotation` — the test that fails if
   MDK ever reorders `CommitOrderingPriority`.

So this half is defence in depth over an engine guarantee, which is why it is sized for
cheapness (30 s) rather than for coverage.

**Known ceiling: the window is per-CIRCLE, the traffic is per-PEER.** The stamp advances on any
peer's authenticated event, and Haven publishes each circle on an independent jittered schedule
per member. The chance of a quiet 30 s therefore falls off roughly as 1/N, and **around N ≥ 4
live peers this gate becomes hard to open at all**. That is a real limit on the repair's reach in
larger circles — recorded, not hidden — and another reason this half must never be the only thing
between two committers.

**The deviation from the review's literal wording, stated plainly.** The review asked for the
stamp to be written for "every 445 that reaches the engine, decrypted or not". That was NOT
implemented as written, for two reasons:

1. **It would make the repair unreachable on its own target scenario.** A C4-stuck admin receives
   a peer publish every 72–168 s and decrypts none of them, so any meaningful window is re-armed
   before it can expire and the Repair button becomes permanently inert.
2. **It would be attacker-writable.** A 445 the pre-auth screen rejected, and a 445 the engine
   merely failed on, are both mintable by any observer of the circle's public `#h` tag — a denial
   channel bought for the price of publishing junk.

What ships stamps only the engine's **authenticated** event batch, which is not inert on a stuck
circle (commits and proposals ride `PublicMessage` and reach a device whose application ratchet is
exhausted) and cannot be forged. The window is additionally pinned strictly below
`MIN_UPDATE_INTERVAL_SECS` by `quiescence_window_cannot_be_held_shut_by_a_live_peer`. Tests:
`a_decrypted_peer_location_is_the_inbound_traffic_the_gate_counts` and
`an_undecryptable_peer_message_does_not_hold_the_repair_shut`.

### Gate 4's exact half: the proposal must stop counting, or the gate becomes a wedge

`has_unresolved_convergence_inputs` deliberately does not count a lone uncommitted proposal, and
`scheduled_self_remove_auto_commits` is `pub(crate)` **and** local to this device, so the signal
is a new read: `SessionManager::has_pending_proposal`, over the same window, states and
projection the send gate uses. It fails **closed** — an unreadable store declines the repair.

The predicate is bounded by epoch, and that bound is the whole thing. **The engine never marks a
proposal row `Processed`** — its ingest arm stores the row and returns — so the row keeps its
`Created` state for the life of the group. Counting `Created` proposal rows at any epoch made
every circle that had ever had a departure permanently unrepairable, silently; the review
predicted this (F2) and the new test found it on the first run. What makes a proposal stop
counting is the group moving past the epoch it was made for, which is also MDK's own rule
(`replay_scheduled_self_remove_auto_commit` refuses a proposal whose `source_epoch` no longer
equals the group's) and RFC 9420's. Pinned by
`a_repair_is_possible_again_once_the_departure_commits` (real engine drive: ingest → staged
eviction → confirm → repairable) and `the_pending_proposal_gate_survives_a_process_restart`.

### MUST-1: the repair must never BANK a rotation

`do_send` does not reject a send it cannot perform — it QUEUES the intent, durably, and
`converge_and_drain_queued_outbound_intents` later turns it into a real commit with none of the
gates re-evaluated and no rate limit charged. Queued intent ids are not deduplicated, so every
Repair tap on a stalled circle banked another epoch bump, all landing in a burst when the circle
unblocked. Two independent defences ship, deliberately redundant:

1. **A pre-check.** `gating_input_count(gid) > 0` is asked BEFORE `update_admin_policy`, so on
   the modelled cause the intent is never issued at all.
2. **A take-back.** The `effects.queued` branch — kept as the fail-safe for what the pre-check
   cannot model (a non-`Stable` state the engine reports by queueing, and
   `stage_due_self_remove_auto_commit` staging an eviction inside the call) — discards the
   just-queued rotation via `SessionManager::discard_queued_repair_rotation_intents`. The match
   is an `UpdateAppComponents` for this group whose single update is the admin policy AND whose
   bytes equal `encode_admin_policy_v1(&current_admins)`. **That payload equality is the whole
   discriminator**: it is what a repair rotation is (a no-op re-statement) and what a real
   handoff or self-demote is not, so a queued membership change parked behind the same gate
   survives — pinned by `a_send_gated_repair_leaves_a_queued_membership_change_alone`.

The take-back is best-effort (a storage failure leaves ONE banked rotation, logged); the
pre-check is what makes the invariant hold when it fails. Being redundant, neither alone is
distinguishable by a test — removing either leaves the suite green, removing BOTH turns it red.
That is recorded as-is rather than papered over.

### Storage

Three instants live on the EXISTING `circle_health` row (`last_epoch_change_seen_at_ms`,
`last_rotation_at_ms`, `last_inbound_event_at_ms`), added by a sentinel-guarded additive `ALTER`
(`migrate_add_rotation_columns`, modelled on `migrate_add_profile_miss_columns`) and read
through a separate `CircleRotationState` value. They are deliberately NOT on the `circles` row:
that row is the `Circle` value the FFI mirrors, so widening it would push two internal
bookkeeping instants across the language boundary for no caller. `CircleHealth` is left
untouched for the same reason.

`last_epoch_change_seen_at_ms` is written from `CircleManager::note_epoch_changes`, keyed on
`GroupEvent::EpochChanged` — the only MLS-authenticated statement that the ratchets restarted,
and emitted by the engine from all three places an epoch moves (applying a peer's commit,
confirming our own, a convergence reorg). It is called from `directory_verdict_for_events`
(which every relay plane and both halves of the publish resolution already reach) and from
`decrypt_location_collecting_commits` (which folds to results rather than routing raw events).
The folded `GroupUpdate` is NOT used: it also covers `PendingCommitRecovered` /
`GroupHydrationRecovered`, neither of which resets a ratchet.

### The `maximum_forward_distance` read path, and why the walk left `CircleManager`

`tests/ratchet_forward_distance_e2e.rs` reads
`cgka_engine::wire_format::join_config(DEFAULT_MAX_PAST_EPOCHS).sender_ratchet_configuration()
.maximum_forward_distance()` at runtime. That is **MDK's own join configuration** — literally the
value it hands `StagedWelcome::new_from_welcome` (`group_lifecycle.rs:518-522`) — so the receiver
under test runs the configured distance, not a restatement of 1000. The test asserts the observed
boundary equals it exactly: `distance` decrypts, `distance + 1` is refused with the typed
`SecretTreeError::TooDistantInTheFuture`. It also pins
`join_config().wire_format_policy() == PURE_PLAINTEXT_WIRE_FORMAT_POLICY`, which is the premise the
whole repair rests on.

**The walk cannot go through `CircleManager`, and that is a measurement, not a preference.** The
engine's send path re-reads every retained message for the group on every send
(`should_queue_outbound_intent` → `advance_convergence_inputs_until_settled` → `list_messages`
over `[tip - 5, …]`, and a Haven circle's tip does not move), so the walk is quadratic. Measured at
MDK `e391adc`, debug build: sends 0–100 took 64 s, sends 100–200 a further 197 s — extrapolating to
~1.8 hours for the full 1002-send walk. `MessageStorage` exposes no delete, so the rows that cause
it cannot be pruned. The mechanism test therefore drives OpenMLS directly at MDK's configuration
(3 real parties, 3 real providers, real Welcome join, messages re-serialized over the wire), which
measures the same ratchet under the same numbers in ~2.3 s.

**That quadratic is itself a production finding, recorded rather than hidden:** a circle publishing
~50 fixes an hour into an epoch that never advances pays an O(retained-rows) scan on every publish.
It is not this unit's to fix, and it is not a test artefact.

The commit the mechanism test applies is built the way `cgka-engine`'s
`stage_commit_with_app_data_updates` builds one — an `AppDataUpdate`-only commit, deliberately NOT
`self_update`, because a self-update carries an `UpdatePath` and would test a stronger commit than
Haven can author. The receiving side asserts `staged.update_path_leaf_node().is_none()`, which is
the documentation-accuracy claim ("no post-compromise security") enforced in code rather than
asserted in prose, and then shows the ratchet reset anyway.

The GROUP's persisted `MlsGroupJoinConfig` would be one step more direct still and is deliberately
not read: reaching `MlsGroup::configuration()` needs an OpenMLS storage provider, and the only
handles in the process are `AccountDeviceSession`'s (which exposes none) and the convergence
sweep's second connection — whose reachable surface is pinned by
`the_sweeps_second_connection_touches_only_message_shaped_storage` specifically to EXCLUDE
`mls_storage()`. Weakening that guard to read one integer would trade a confidentiality argument
for a test convenience, and `join_config()` is the same value by construction.

`openmls_basic_credential` (0.5, already in `Cargo.lock` via `cgka-engine`) is a new **dev**
dependency: MDK exposes no signer, and the mechanism test needs one. Zero crates added to the
graph; nothing new ships.

The Haven half of the file (`a_repair_rotation_reaches_the_peer_and_the_circle_keeps_working`)
covers what only the real stack can: `repair_epoch_rotation` → a kind-445 commit → confirm → the
peer applies it → both epochs match → the circle still sends and receives.

### Mutation evidence (every gate, verified by a named red test)

Each mutation was applied to the working tree, the named tests run, and the file restored.

**Round 1 (original implementation)**

| Mutation | Red tests |
|---|---|
| **Gate 1** — `admins.len() != 1 \|\| admins[0] != self` → `admins.contains(self)` | `an_admin_pair_elects_nobody_in_either_lexicographic_order`, `the_lowest_pubkey_is_not_elected_out_of_an_admin_pair`, and both proptests |
| **Gate 4a** — drop the inbound-quiescence window | `inbound_traffic_inside_the_quiescence_window_skips`, `a_timestamp_in_the_future_blocks_rather_than_licenses`, `recent_inbound_traffic_declines_the_repair` |
| **Gate 4b** — drop the pending-proposal check in the pure decision | `a_pending_proposal_skips_however_quiet_the_circle_is`, `an_uncommitted_peer_proposal_declines_the_repair` |
| **Gate 4c** — durable proposal read always answers "nothing pending" | `an_uncommitted_peer_proposal_declines_the_repair` |
| **Gate 7** — stop checking `effects.queued` before `take_group_evolution` | `a_send_gated_circle_defers_the_repair_instead_of_reporting_no_work` |
| **Publish-before-apply (a)** — the repair confirms its own commit | 6 tests incl. `a_repair_no_relay_acked_applies_nothing_and_leaves_the_circle_sending` |
| **Publish-before-apply (b)** — charge the rate limit at stage time | `a_confirmed_repair_records_the_rate_limit_and_a_rolled_back_one_does_not` |
| **E2E anti-vacuity** — probe the refusal edge one generation earlier | `the_forward_distance_boundary_is_mdks_own_and_a_repair_shaped_commit_resets_it` |

**Round 2 (review fixes)**

| Mutation | Red tests |
|---|---|
| **MUST-1**, both halves — no pre-check AND no take-back | `a_send_gated_repair_banks_no_rotation_however_often_it_is_tapped`, `a_send_gated_repair_leaves_a_queued_membership_change_alone` |
| **MUST-1**, either half alone | *green* — the two are deliberately redundant; recorded rather than hidden |
| **MUST-2a** — gate 4 reads the delivery-health column again (the inert signal) | `a_decrypted_peer_location_is_the_inbound_traffic_the_gate_counts`, `recent_inbound_traffic_declines_the_repair` |
| **MUST-2b** — the receive funnel stops stamping the inbound observation | `a_decrypted_peer_location_is_the_inbound_traffic_the_gate_counts` |
| **MUST-3 / F2** — count `Created` proposal rows at any epoch (the pre-fix behaviour) | `a_repair_is_possible_again_once_the_departure_commits` — this is how the wedge was FOUND, not just guarded |
| **MINOR-3** — classify a frozen group as retryable again | `only_an_epoch_state_transition_maps_to_epoch_not_stable` |
| **MINOR-5** — drop an unserializable staged commit instead of rolling it back | `a_rotation_whose_commit_cannot_be_serialized_is_rolled_back` |
| **Gate 2 (round 1)** — stop mapping `InvalidTransition` at all | `a_group_with_a_commit_already_staged_declines_the_repair_as_busy` |

**Round 3 (re-check items)**

| Mutation | Red tests |
|---|---|
| **MAJOR** — `panic!` on entry to `discard_queued_repair_rotation_intents` (the probe that used to stay green) | `the_repair_discard_removes_the_no_op_policy_and_nothing_else` |
| **R4** — remove the pre-check (the take-back then eats a pre-existing no-op intent) | `the_pre_check_keeps_a_send_gated_repair_out_of_the_engines_send_path` |
| **NIT** — narrow the proposal bound to `== tip` | `a_future_epoch_proposal_still_gates_the_repair` |
| **R2 anti-vacuity** — assert the peer lands on a different epoch | `a_rotation_racing_a_departure_at_one_epoch_resolves_to_the_rotation` |

### Deviations from the plan's sketch, recorded

1. `rotation_decision` takes a `RotationInputs` struct rather than eight positional arguments
   (`clippy::too_many_arguments` fires at eight, and the call site reads better).
2. `note_rotation_confirmed` is folded into `confirm_published` — see above.
3. `haven-core/proptest-regressions/circle/rotation.txt` is NEW and kept, per proptest's own
   convention. Its one seed came from `intersecting_divergent_views_elect_at_most_one_member` while
   that test was being strengthened: the first version counted `(member, view)` PAIRS rather than
   DISTINCT members, so an anchor legitimately electing under each of its own several views scored
   4 against a "at most one committer" bound. `rotation_decision` was correct throughout — the
   defect was in the assertion, and the fix was to count distinct members. The seed (an all-zero
   anchor, two identical singleton views, a duplicate candidate) is exactly the de-duplication the
   fix introduced, so it is a meaningful permanent pin against re-introducing pair counting.
4. The two proptests generate their candidate members FROM the admin set plus outsiders, never as
   independent random keys. Two random 32-byte arrays essentially never collide, so the first
   version was vacuous: the gate-1 mutation below (`admins.len() != 1 || …` → `admins.contains(self)`)
   left BOTH proptests green. With the anti-vacuity fix both go red.
5. The proptest's divergence property is stated with the hypothesis that makes it TRUE: over
   admin-set views that pairwise intersect — which is exactly what Haven's two-commit handoff
   maintains (`{A}` → `{A,B}` → `{B}`) — at most one member rotates. The honest boundary (two
   disjoint singleton views DO both elect, and Haven cannot reach that state) is pinned by its
   own named test rather than left implicit.
