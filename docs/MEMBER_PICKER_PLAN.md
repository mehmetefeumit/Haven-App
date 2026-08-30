# Member picker: resolved names, local directory, and recent contacts

Status: **APPROVED for implementation.** All nine owner decisions taken
(2026-08-24 through 2026-08-28, §10). Produced by seven domain expert agents, then attacked by four
independent reviewers who reproduced the empirical claims and refuted several.
Corrections from that round are marked **[R]**.

## 1. Scope

Inviting someone to a circle meant typing, pasting or scanning a 63-character
`npub1…` into `member_search_bar.dart` — a `StatefulWidget` with no `ref`, no
service, no network. Creating a second circle with someone you already share one
with required pasting their key again. (P2 deleted that widget; the citation is
kept without a line number because the file no longer exists — see §11.)

| # | Requirement | New storage | New wire traffic |
|---|---|---|---|
| R1 | A typed npub, when offered as a pick, shows username + picture | no | only for a stranger |
| R2 | Local directory of everyone you share a circle with; auto-populates the empty field | no | **none** |
| ~~R3~~ | ~~Suggestions from your kind-3 follow list~~ | — | **CANCELLED — see §8** |
| R4 | Locally-known people searchable by npub **and** cached username | no | **none** |
| R5 | Anyone you shared a circle with in the past **3 days** | **yes** | **none** |

With R3 cancelled, **this feature adds exactly one new outbound request**: the
optional single-key lookup in R1 (§10 D2). Everything else is local.

### 1.1 An honest framing

A durable index of every pubkey you have shared a circle with, **with names and
photos**, already exists on disk. `delete_circle`
(`haven-core/src/circle/storage.rs:1302-1393`) cascades eight tables
(`circle_ui_state`, `circle_memberships`, `circles`, `processed_gift_wraps`,
`sync_cursors`, `catchup_backfill_floors`, `catchup_cutoff_holds`,
`last_known_locations`) and never touches `profiles` or `profile_pictures`. This feature does not create that
artifact — it **promotes it to a searchable, displayed surface and adds a
temporal dimension**. That belongs in the copy (§10 D6), not a footnote.

### 1.2 The retention asymmetry

Haven retains a co-member's **coordinates for 1 day**
(`haven-core/src/circle/types.rs:354-360`). R5 retains the **fact of
co-membership for 3 days** (owner-set, reduced from the drafted 7), surviving a
deletion that today wipes everything else about that circle. Three days still
covers the motivating case — starting a second circle with someone shortly after
the first — at 3× the location window rather than 7×.

## 2. Protocol foundations (verified live)

`Filter::pubkey()` filters `#p` (recipient), not author. Use `Filter::author()`.

Kind-3 material is retained here only as the record of a rejected design (§8).
No NIP-02 parsing, fetching or storage is in scope.

## 3. What R2/R4 get from existing surfaces

| Need | Source | Note |
|---|---|---|
| Current co-members | `circlesProvider` → `Circle.members` | |
| Local petnames | **`CircleMember.displayName` already carries it** (`circle/manager.rs:1169-1173`, inside `get_members`) | **[R]** `getAllContacts` is redundant, has zero Dart callers, and is not on the `CircleService` interface — reaching it needs a downcast and breaks mockability |
| Cached kind-0 name | `getCachedProfile` — **verified pure local read** (`rust_builder/src/api.rs:5499-5520`) | |
| Cached 96px thumbnail | `profile_pictures.thumbnail` | |
| Name precedence | `resolveEffectiveMemberName` | |

**[R] Three corrections to the "P1 needs zero FFI" claim:**

1. **R4 needs the fold, and the fold is Rust.** P1 requires exactly one new
   export, `foldForSearch` (§9.3).
2. **No batch cached read exists on the FFI.** `get_profiles(&[String])` exists
   in core but is used only by the *network* path. The only Dart-reachable
   cached read is single-pubkey, so "load once" costs N round-trips × 3 SQLCipher
   queries each. Add `get_cached_profiles(Vec<String>)` or decline it explicitly.
3. **`NostrCircleService` hard-coded `status: MembershipStatus.accepted`** on
   the assumption that "members in a visible circle have accepted their
   invitation." (No line number: P1 deleted the field and the fabrication with
   it — `nostr_circle_service.dart` now carries `MembershipStatus.accepted` only
   for the LOCAL user's own membership, at `:450` and `:628`.)

   **[P1 — this bullet's own prescription was WRONG.]** It said "P1 must source
   membership from Rust." Rust has **nothing to source**, and no engineering on
   this pin will change that:

   - Processing a Welcome emits no outbound message and produces **no
     observable artifact for anyone else** (`do_join_welcome` returns a
     `GroupId`, not a `SendResult`; `GroupJoined` fires on the *joiner's* device
     only). MLS has no join acknowledgement.
   - The group state stores `Member { id, credential }` and nothing more — no
     join flag, no liveness, no last-seen. `join_epoch` is **this device's own**
     membership start, not a per-peer field.
   - **Nothing times out.** Over any span, the inviter's device observes
     *exactly nothing* about whether the invitee ever arrived.
   - `circle_memberships.status` tracks **the local user's own** invitation
     state, not peers': the table has no pubkey column, its `inviter_pubkey`
     names who invited *us*, and its doc comment says so.
   - The only true participation signals are a decrypted kind-445 from them or a
     commit they authored — and gating on those would hide every real co-member
     who simply has location sharing **off**, turning R2 into "people who
     recently sent me a location". A strictly worse product *and* a different,
     unstated promise.

   **Resolution: relabel, and delete the fabricated field** (see §7.2 for the
   copy). `status` came out of Dart's `CircleMember`, the fabrication in
   `nostr_circle_service.dart` went, and the two **unreachable** branches in
   `circle_member_tile.dart` went with it. **All three subjects are gone from
   the tree, so none carries a line number any more**: `CircleMember`
   (`circle_service.dart:133-141`) now has exactly `pubkey`, `npub`, `isAdmin`
   and `displayName`, and the only `status` left in `circle_member_tile.dart` is
   `PendingMemberTile`'s unrelated `ValidationStatus` (`:453`, `:464`).

   **Shipped defect this exposed:** because the value was a constant, those
   branches never rendered — yet the strings they carried,
   `circleMemberInvitationPending` ("Invitation Pending") and
   `circleMemberHintPending`, were **translated into all thirteen locales while
   describing a state the app does not model and cannot detect.**

   **[RESOLVED — owner decision 2026-08-25: retire them.]** Both keys are
   deleted from all 13 locales, along with the widgets that carried them. The
   review pass found the problem was larger than these two: `InvitationStatusBadge`
   and `key_display.dart`'s two widgets were also unreachable, bringing the total
   to **16 keys** retired across 13 locales (the 15 orphans plus
   `invitationCardMemberCount`, §10 D7). `key_display.dart` mattered beyond dead
   code — it re-exposed a public `truncateLength` parameter, the very shortening
   lever P0 deleted from `NpubValidator`, so a caller could have re-created a
   4/4 npub. A lint test now fails if any file under `lib/` reintroduces one.

## 4. Inherited constraints

1. **Plane separation** (`profile/relay_pool.rs:1-30`): a relay sees *either*
   kind-445/1059 *or* kind-0 — never both.
2. **Salted assignment**: one author per REQ, rank ≤ 2. `.authors(` is CI-banned.
   The salt is **never rotated**, an accepted cost scoped to a roster of tens —
   which R3's cancellation keeps true.
3. **Union batching**: callers pass the union across all circles, never a
   per-circle partition. CI-confined by Check 7. **[R]** D2's single-key lookup
   punctures this; see §10 D2.
4. **No group identifier at rest.** **[R]** `contaminated_relays`' *stated*
   reason is that contamination is historical/append-only — not group-ID
   avoidance. Don't borrow authority it doesn't have.
5. **Picture URLs never cross the FFI** — verified bytes only. **[R]** `about`
   already crosses with no guard, and §7 says it must never be rendered.
6. **[R] Kind 3 stays forbidden, and no read path is added.** Of the three
   places that name it, the wire allowlist and the E2E relay watch are
   **send-side only**; only `privacy_invariants.json` rule 13 would have caught a
   read filter. With R3 cancelled all three stay green untouched. **[R]** A
   fourth, unnoticed: `req_filters.allowed_keys` omits `search`, so **NIP-50 is
   already forbidden by omission**.

## 5. MLS write-site discipline

### 5.1 `Member.id`, not `Member.credential`

The field named `credential` holds the MLS leaf **signature** key; `Member.id` is
the Nostr identity pubkey (`cgka-engine/src/group_lifecycle.rs:942-954`).

**[R] This trap cannot currently fire** — `haven-core` reads `.credential`
nowhere, and `member_pubkeys` (`nostr/mls/manager.rs:972`) uses `m.id`. Keep it
as a **guard**, not a near-miss.

**[R] Worth a code comment:** upstream's own doc at `traits/src/group.rs:51`
calls `id` the *"signature public key"*. **[R] The contradiction is real but not
where the plan placed it** — lines 54-57 are bare field declarations and
contradict nothing. The contradicting code is in a **different crate**:
`cgka-engine/src/group_lifecycle.rs:946-951`, where `marmot_members` fills `id`
from `basic.identity()` and `credential` from `m.signature_key`. Cite that pair.
**[R]** `.identity` is a Nostr pubkey only because MDK validates it as a 32-byte
BIP-340 key at every ingress; it is opaque bytes in OpenMLS.

### 5.2 `confirm_published` is NOT terminal — the real hazard **[R]**

Branch selection can withdraw a commit the client already published and
confirmed (`SupersededByBranchSelection`). The spec: *"the application treats the
changes it announced as not having happened."*

Alice adds Dave at epoch N; Bob concurrently removes Carol; Alice's branch loses.
Alice already called `confirm_published`, so Dave got a directory row with a
3-day timer. Dave was never a member — and since `delete_circle` deliberately
does not cascade, he sits searchable and one tap from receiving live location
until the row expires.

The union rewrite does not save it: the next sync clears `is_current`, but
`last_shared_day`/`purge_after` survive as a "recent contact".

**Required:** a row may only be **created** from a roster read taken after the
group is `Stable` **and** convergence has drained; a pubkey observed once that
then disappears must be **deleted**, not aged out.

**[R] There is no engine accessor for `EpochState` on this pin — verified
exhaustively.** The `CgkaEngine` trait's entire inspection surface is
`traits/src/engine.rs:683-736`; it carries `members` and `epoch` and no state.
`EpochManager` is `pub(crate)` (`cgka-engine/src/epoch_manager.rs:50`), so is
`Engine.epoch_manager` (`cgka-engine/src/engine.rs:101`), and
`AccountDeviceSession.engine` is not `pub` at all
(`cgka-session/src/lib.rs:134-136`). `EpochState` is never persisted either —
zero matches in `crates/storage-sqlite/src`. The enum is
`traits/src/engine_state.rs:196-209`.

**[R] The conclusion drawn from that — "post-converge must be built from Haven's
own pending-ref bookkeeping" — is FALSE, for two independent reasons.**

**One: a public post-converge accessor exists, and Haven does not call it.**
`AccountDeviceSession::has_pending_convergence_inputs(&self, group_id) ->
SessionResult<bool>` (`cgka-session/src/lib.rs:513-515`), a one-line delegate to
`Engine::has_pending_convergence_inputs`
(`cgka-engine/src/message_processor/mod.rs:458-460`), which is itself a delegate
to `has_unresolved_convergence_inputs` (`:367-456`) — where the semantics
actually live. Exactly: `true`
iff a stored `MessageRecord` in state `Created` or `Retryable` within
`[epoch − max_rewind_commits, epoch + max_rewind_commits]` projects to a Commit
or an Application message. A lone proposal does **not** gate — a proposal only
takes effect once a commit consumes it. Two ways it reports clean when it is
not: it **fails open** on any row it cannot decode or project (counted into a
`skipped_non_resolvable` debug aggregate — deliberate, so one corrupt row cannot
wedge every send forever; `mod.rs:395`, `:414`, `:447-453`), and it returns
`Ok(false)` for `StorageError::NotFound` (`:391`). `false` therefore proves
*nothing resolvable is outstanding*, not a clean slate (§14).

**Two: the prescribed bookkeeping does not cover the hazard's own operation.**
`create_pending` (`circle/manager.rs:83`) is written only by
`register_create_pending` (`:489-494`), from the single call site in
`create_circle` (`:464`) — it tracks **`GroupCreated` pendings only**. Every
`SendResult::GroupEvolution` pending is handed to the caller and Haven core
keeps no record of it: invite (`AddMembersResult.pending`, `:2876`), remove
(`CommitToPublish.pending`, `:2894`), receive-side auto-publish
(`DecryptedIngest.auto_commits`, `:2908`). The hazard above is *Alice adds
Dave* — a `GroupEvolution`. **The bookkeeping for the exact operation in the
hazard does not exist.**

**[R] The gate that IS buildable today, with no new engine API:**

```
is_stable(gid)  ≜  session.epoch(gid) == session.group_record(gid).epoch
```

The two diverge in `PendingPublish` and `Merging` because the stage sites
deliberately leave `group_record.epoch` at the prior value while overwriting
`group_record.members` with the projection — invite at
`cgka-engine/src/message_processor/send.rs:228-231`, remove at `:492-496`.
`session.epoch` resolves through `EpochManager` to `EpochState::epoch()`, which
returns the *projected* epoch (`traits/src/engine_state.rs:218-225`, reached via
`cgka-engine/src/engine.rs:1856-1860` and `epoch_manager.rs:72-74`). Only
`cgka-engine/src/publish.rs:137-142` (merge) and `:293-298` (rollback) re-derive
the two together — which is exactly when they must agree again.

**It has three false positives, and the caller owns all three:**

1. **A solo create.** With no invitees no commit is staged, so
   `projected_epoch = EpochId(0)` (`cgka-engine/src/group_lifecycle.rs:364-381`)
   and equals the stored epoch 0 — `is_stable` reports stable throughout a
   `PendingPublish` create. Reachable: `create_group_with_retention`
   (`nostr/mls/manager.rs:387-440`) has no empty-member guard (§14).
2. **`Recovering`** — `EpochState::epoch()` returns `last_stable_epoch`
   (`engine_state.rs:223`), which is what storage already holds.
3. **`Unrecoverable`** — the same arm, `:224`. §5.3 handles it separately.

A quarantined group is **not** a fourth: `group_record` gates on
`ensure_group_live` (`cgka-engine/src/engine.rs:1464-1466`) while `epoch` does
not (`:1856-1860`), so `is_stable` errors rather than lying.

**[R] A load-bearing fact this plan lacked: the optimistic roster is what EVERY
read returns, not just the union helper.** `do_members` reads the Marmot
record's `members` list (`cgka-engine/src/group_lifecycle.rs:749-756`), and the
send paths overwrite that list with the projected post-merge set before
publishing anything. **Dave is in `session.members()` the instant `send()`
returns** — before a relay has seen the commit, let alone before
`confirm_published`. §5.5's roster-paths note scopes this to
`current_member_union`; it is a property of the accessor, and every roster read
inherits it.

**[R] The spec quote checks out** — verified verbatim against
`protocol-core/convergence.md`, "Applying the selected branch".

### 5.3 Quarantine and `Unrecoverable` — two mechanisms, not one **[R]**

**[R] The quarantine → `UnknownGroup` mapping is the ENGINE's, not Haven's.**
`Engine::ensure_group_live` returns `EngineError::UnknownGroup` for any
quarantined group (`cgka-engine/src/engine.rs:1175-1180`), so quarantine is
deliberately indistinguishable from "unknown" on every accessor. What Haven does
at `nostr/mls/manager.rs:931-947` (`find_group`) is *collapse* that
`UnknownGroup` together with a genuine `StorageError::NotFound` into `Ok(None)`.
The consequence the draft described stands — an error-propagating
`current_member_union` means sync never runs, every peer's timestamp freezes,
and three days later the whole directory purges **including current
co-members** — but the collapse is Haven's to undo, not the engine's.

**[R] Distinguishing them is not a design blocker.**
`AccountDeviceSession::quarantined_groups() -> Vec<(GroupId,
GroupHydrationQuarantineReason)>` is public at `cgka-session/src/lib.rs:286-288`
and Haven wraps it **nowhere**; the reasons are at `traits/src/engine.rs:319-331`.
Reconcile shape: skip any group in `quarantined_groups()`; skip
`Err(Storage(NotFound))`; on **any** other error abort the reconcile and the
purge together. Cost: two thin `SessionManager` (`nostr/mls/manager.rs:142`)
wrappers.

**[R] "Hard-error forever" is really "for the life of the session."** Quarantine
entries are added only at session-open hydration and cleared only by
`retry_hydrate_quarantined_group` (`cgka-engine/src/engine.rs:1210`, exposed at
`cgka-session/src/lib.rs:296-298`), which Haven never calls — so the next
session open re-attempts hydration from scratch and a transiently-bad group
heals on a restart.

**[R] The conflation.** `EpochState::Unrecoverable`
(`traits/src/engine_state.rs:141-149`) and hydration quarantine are unrelated.
`ensure_group_live` checks the quarantine map **only**; an `Unrecoverable` group
is still "live", so `session.members(gid)` returns `Ok(roster frozen at
last_stable_epoch)` with no error at all. §5.5's row *"Any group in
`Unrecoverable`/quarantine → no write"* therefore needs **two** detectors:
quarantine via `quarantined_groups()`, and `Unrecoverable` via tracking
`GroupEvent::GroupUnrecoverable` — which Haven already surfaces, as
`LocationMessageResult::Unrecoverable` (`nostr/mls/manager.rs:1229-1233`).

**[P3] The prescribed three-call gate was not built. Two independent reasons.**

*It has a TOCTOU.* Every `SessionManager` method takes and releases the session
mutex individually, so `has_pending_convergence_inputs` → epoch equality →
`member_pubkeys` drops the lock twice between the verdict and the read. A commit
staged in either window hands the caller exactly the optimistic projection the
gate exists to refuse (§5.2). The window is reachable, not theoretical: the FFI
runs concurrent calls while live sync drives its own tasks against the same
session.

*The `Err(Storage(NotFound))` arm is not expressible at `CircleManager`.*
`member_pubkeys` propagates through `map_mls_err`, which stringifies — there is
no typed `StorageError::NotFound` left to match by the time the caller sees it.
Classification has to happen before stringification, i.e. inside the session
layer.

**Shipped instead: one accessor that takes the lock once.**
`SessionManager::converged_member_pubkeys(&self, group_id) ->
Result<ConvergedRoster>` (`nostr/mls/manager.rs:1069`) delegates to the free
function `converged_roster` (`:1245-1273`), which runs `group_record`, the epoch
equality, `has_pending_convergence_inputs` and `members` against one already-held
guard — so the three reads describe one instant — collapses
`UnknownGroup | Storage(NotFound)` to `Absent` there, and only then drops the
guard so `map_mls_err` runs outside it.

`ConvergedRoster` (`nostr/mls/types.rs:134-170`) is three variants, not
`Option<Vec<String>>`, because `NotConverged` and `Absent` are opposite caller
obligations: `NotConverged` invalidates the WHOLE read (its roster is the
projection), while `Absent` is one circle to skip. Collapsing them costs either a
silently wrong union or a reconcile that never runs. `Converged` also carries
`removed: bool` — §5.5.

**[P3] `has_pending_convergence_inputs` is deliberately NOT exposed as a public
wrapper**, contradicting §14's row and the "two thin wrappers" above. A public
version would release the lock before the caller could read a roster, so it would
be racy by construction and would have no honest caller — and `CLAUDE.md` forbids
a dead API. Its fail-open semantics are documented at the one accessor that
consumes it (`nostr/mls/manager.rs:1049-1055`). `quarantined_group_ids` IS a
public thin wrapper (`:1019`); it drops the upstream
`GroupHydrationQuarantineReason` because Haven exposes no per-group recovery
surface to branch on. **One wrapper and one accessor, not two wrappers.**

**[P3] A quarantined circle SKIPS; it does not defer.** §5.3 reads as though
quarantine and a staged commit deserve the same treatment. They do not:
quarantine cannot heal before the next session open, so deferring on it would
freeze the whole directory until then — which is the failure this section warns
about, arrived at from the other direction. `reconcile_member_directory` reads
the quarantine set once per pass and `continue`s past those circles
(`circle/manager.rs:1240-1245`, `:1260-1262`); their members age out on the
ordinary window and are restored by the first reconcile after the group
re-hydrates. Only `NotConverged` returns `Ok(false)` and defers the pass
(`circle/manager.rs:1283`). Test:
`a_quarantined_circle_is_skipped_without_aborting_the_union` (`:3358`).

### 5.4 Partial rosters: the check was unsound, the invariant is upstream **[R]**

The `filter_map` claim is exact and confirmed. `marmot_members`
(`cgka-engine/src/group_lifecycle.rs:942-954`) silently **drops** any member
whose credential is not a `BasicCredential`, so `get_members` can return `Ok`
with a short roster no `Result` can detect.

**[R] The prescribed check — "compare counts against `member_pubkeys`' own
length" — detects nothing.** `member_pubkeys` *is* `self.members(...)` mapped to
hex (`nostr/mls/manager.rs:967-974`): the same already-filtered vector, so the
comparison is a tautology. Worse, the drop happens at **write** time. Every one
of `marmot_members`' six call sites persists or projects a roster; none reads
one back — merge (`cgka-engine/src/publish.rs:139`), rollback (`:295`),
inbound-commit ingest (`message_processor/ingest.rs:855`), confirm
(`engine.rs:847`), the welcome-join record write
(`group_lifecycle.rs:618`) and the send-path projection
`projected_members_with_pending` (`:853`). So by read time
the short roster is the only roster that exists. **There is no read-side
observation on this pin that can detect the loss.** Delete the prescription
rather than softening it.

**The hazard is closed at ingress instead.** Every seam validates every member
credential strictly and *quarantines* on failure rather than silently
shortening: welcome join (`cgka-engine/src/group_lifecycle.rs:559`), session-open
hydration (`engine.rs:787-791`, mapping the failure to
`GroupHydrationQuarantineReason::MemberValidationFailed`), and the
KeyPackage/invite paths (`cgka-engine/src/key_package.rs:44`, `:78`, `:179`).
The validator
iterates **every** member (`group_lifecycle.rs:872-877`) and requires both
`BasicCredential::try_from` and `validate_credential_identity` — exactly 32
bytes and a valid `k256::schnorr::VerifyingKey` (`identity.rs:121-148`).
Upstream states the resulting invariant in prose at `app_components.rs:451-454`.

So keep §5.4 as a **guard/comment**, like §5.1's, and assert the checkable form:
*a group either hydrates fully or appears in `quarantined_groups()`*.

**[R] Residual asymmetry — `marmot_members` is not the validator.** It runs
`BasicCredential::try_from` but **not** `validate_credential_identity`
(`group_lifecycle.rs:942-954`), so it is strictly weaker than the ingress
validator and must never be treated as one.

**[R] The two swallows stand, and one is the mechanism behind §5.3.**
`admin_pubkeys(...).unwrap_or_default()` (`circle/manager.rs:1157-1164`, inside
`get_members`) turns a failed admin read into "nobody is an admin".
`get_members(...).await.unwrap_or_default()` inside `get_circles` (`:658-661`)
makes a roster-read failure **indistinguishable from an empty circle** — the
concrete route by which a transient failure drives §5.3's purge. The same hazard
already ships benignly in `member_profile_refresh_provider.dart:191-200`
(`_readCircles`).

### 5.5 Write sites

| Point | Write? |
|---|---|
| Post-`confirm_published` **and** post-converge, group `Stable` | **yes** |
| After a welcome is accepted (`GroupJoined`) | **yes** |
| After applying an inbound commit, post-converge | **yes** |
| On `Invalidated` | **yes** — the engine has already rolled back **[R]** |
| KeyPackage fetch at candidate time | no |
| Welcome *preview*, pre-accept | **no** — seal-authenticated only; anyone can gift-wrap a welcome, and a row here breaks decline-leaves-no-trace |
| Decrypting a kind-445 | **no** — a past-epoch message (≤5 epochs) resurrects a removed member |
| Any group in `Unrecoverable`/quarantine | **no** |
| **Explicit removal (either direction)** | **DELETE, immediately** — §10 D3 |
| **[P3] This device evicted — `Group.removed`** | **DELETE** — the only detector for the "they remove you" half of D3 |

**[P1] The two sides of a join learn different things — do not assume symmetry.**
On the *joiner's* device `GroupJoined` carries `welcomer: Option<MemberId>`, so
the joiner learns who invited them. The inviter's device receives **no
corresponding event at all**. §3 explains why that asymmetry is load-bearing.

**[P1] If a participation flag is ever added** (it is not, per §3), §5.5's
kind-445 rule generalises: any such write must be gated on the sender being
present in the **current, post-converge** roster, because a past-epoch message
can arrive from someone removed up to five epochs ago. And §6.1's no-group-column
rule forces it to be a per-pubkey boolean — i.e. a **union-level** claim ("this
person has authenticated to you in *some* circle"), never a per-circle one, and
it must never be rendered inside a per-circle surface where it would read as a
claim about that circle.

**[R] Roster paths a source-scan guard cannot see** (it pins definition sites,
not who learns a roster): live-sync fan-out — `route_events`
(`relay/live_sync/processor.rs:466-508`); receive-side auto-commit on a peer's
`SelfRemove` — `resolve_publish_work` (`:510-527`);
`location_sharing_service.dart:1106` post-finalize `getMembers` and the `:1293`
deferred prune; the `still_a_member` backstop (`circle/manager.rs:297-315`); background
catch-up in the WorkManager isolate; and `current_member_union` itself, which
returns the **projection** for any circle in `PendingPublish`. **[R] The
projection is not a property of the union helper.** It belongs to the accessor:
`session.members()` returns the optimistic post-merge roster for *any* read
during `PendingPublish` (§5.2), so every path in this list inherits it.

**[R] The event fold discards what a per-commit design would need.**
`location_result_from_event` (`nostr/mls/manager.rs:1185-1236`) drops
`GroupEvent::ForkRecovered` and `CommitRolledBack` entirely — they fall through
to `_ => None` (`:1234`, and the reason is stated in the comment at
`:1212-1214`) — and strips `invalidated_commit_id`, `epoch` and `reason` from
`GroupStateInvalidated`, keeping only the group id. **No per-commit withdrawal
reaction is possible without changing the fold.** The union-rewrite design is
unaffected, because "this group changed, re-read it" is all it needs; a design
that withdrew exactly the rows one superseded commit created is not buildable
as-is.

**[R] "On `Invalidated`" is broader than "a commit was withdrawn."** The fold
collapses `AppMessageInvalidated` into the same
`LocationMessageResult::Invalidated` (`:1223-1228`), so the trigger also fires
for a dropped *application* message (e.g. `BeyondAppRetention`). Harmless for a
re-read, wrong as a semantic — do not name the trigger after commits. The §5.5
claim itself is **CONFIRMED on both seams**: the engine has written the
rolled-back state before the app can drain the event.
`message_processor/ingest.rs:914-936` (the record rewrite) precedes the
`GroupStateInvalidated` push at `:970-976`, and
`distributed_convergence.rs:432` (`apply_openmls_canonicalization_result`)
precedes `emit_rolled_back_commits` / `emit_superseded_processed_commits` at
`:482-483`.

**[P3] `Group.removed` is the detector for "they remove you", and without it
half of D3 has no implementation.**

The "you remove them" half is `remove_members` deleting each named row at
STAGING time (`circle/manager.rs:1122-1137`), deliberately unconditional on the
publish: erring toward deleting a row a rollback would restore costs a
convenience, while erring the other way leaves someone the user just removed one
tap from receiving live location. The other direction had no signal at all until
`ConvergedRoster::Converged { removed }` surfaced the engine's `Group.removed`
flag (`traits/src/group.rs:22-38`) — set together with the self-removed
notification, terminal while the removal stays canonical, and clearing only on an
authenticated re-join or a branch selection that supersedes it.

A circle whose flag is set contributes its roster to a **`severed`** set instead
of the union (`circle/manager.rs:1253`, `:1274-1278`), and `severed \ union` is
deleted outright (`:1302-1304`). So being evicted deletes those co-members now,
while anyone still reachable through another circle survives on the union side —
the difference, not the raw roster, is what the delete runs over. Test:
`being_removed_from_a_circle_deletes_its_co_members_immediately` (`:3541`).

**The trap: this must NOT be wired at `complete_leave`.** That is the finalizer of
a VOLUNTARY leave as well (`circle/manager.rs:943`, reached from `propose_leave`
and from `abandon_circle_local_only` at `:956-958`), so deleting there would
erase exactly the recent contacts R5 exists to serve — the person you just left a
circle with is the motivating case for starting a second one.

**[P3] The union excludes the local identity.** Every roster contains this
device, so without the filter every user gets a row offering themselves under
"Members of your circles". `union` and `severed` both drop
`session.identity_pubkey().to_hex()` before any write
(`circle/manager.rs:1288-1293`); pinned by
`the_local_identity_is_never_its_own_directory_entry` (`:3694`).

**[P3] The write sites, as shipped — seven, and the plan's list missed the two
that actually fire.**

| Site | Trigger |
|---|---|
| `circle/manager.rs:988` | `confirm_published` — the first moment an announced membership is applied rather than projected |
| `circle/manager.rs:1024` | `publish_failed` — restores anyone `remove_members` optimistically deleted for the commit that was just discarded |
| `circle/manager.rs:1590` | a welcome **accepted** (never a preview) |
| `circle/manager.rs:1779` | `decrypt_location`, via `DirectoryReconcile::for_receive_results` |
| **`relay/live_sync/processor.rs:392-408`** | `process_group_event`, once per batch after `drain_convergence` returns its accumulated verdict |
| **`relay/catchup.rs:984-1021`** | `ingest_one`, the same shape in the WorkManager isolate |
| `rust_builder/src/api.rs:4057` | the Dart-triggered reconcile; `Rewrite` only, because only a receive path knows the engine withdrew state |

The two bolded rows are the correction. **Live sync has been the default receive
plane since M11 Phase B**, so §5.5's original list — which named only the
`decrypt_location` poll path — described a write site that in production almost
never fires. Both new sites accumulate a `DirectoryReconcile` across the whole
drain and reconcile ONCE at the end, via `Option::max` over the strength-ordered
enum (`circle/manager.rs:2780-2839`): a batch carrying both an ordinary departure
and a withdrawal resolves to `RewriteWithdrawing`, and no reconcile ever reads a
roster mid-drain.

## 6. Data model

### 6.1 Schema — corrected **[R]**

**The drafted 5× measurement is refuted.** Reproduced on the real stack
(SQLite 3.45.3 / SQLCipher 4.5.7, 2200 rows, release, median of 201):

| Query | Normalized | Denormalized |
|---|---|---|
| Hit-heavy | 1.53 ms | 0.10 ms → **15×** |
| Narrowing | 1.38 ms | 1.02 ms → **1.35×** |
| **Ranked fetch, unfiltered (the real operation)** | **0.93 ms** | 0.14 ms |

Absolutes were wrong by ~7×; the ratio varies by an order of magnitude with the
query; and **the benchmark measures an operation the architecture deletes** —
under §9.3 the ranked query runs *once per sheet-open*. 0.93 ms once is not a
schema argument.

**The conclusion survives on a ground the draft never stated.** `profiles` has
**no name column** (`storage.rs:652-660`) — the name lives inside
`metadata_json`, so an unmaterialized query needs `json_extract` + `lower()`
(2.91 ms at 2200, 7.38 ms at 10 000) and, fatally, **`lower()` is not the fold**.

**So a materialized folded column is required — but it belongs in `profiles`,
not `member_directory`.** That fixes three problems at once:

- **It stops the folded name surviving `wipe_all_profiles`.** In the draft's
  schema, a materialized index of *other people's names* outlived the
  "delete my public profile" retraction.
- It makes "one write site for the name" **true**. In the draft it was
  unachievable: the two tables have different row populations.
- **[R]** It corrects a false claim: `profiles` has **three** writers
  (`write_profile_row`, `touch_profiles_hit`, `record_profile_misses` —
  `storage_profile.rs:914`, `:260`, `:315`). Only the first writes the name, but
  a guard written from the draft's sentence would not hold.

**[P3] Not built, and the prescription above is superseded — no folded column
was materialized anywhere.** `profiles` still has exactly the seven columns at
`storage.rs:652-660`, none of them folded. The fold is computed **in Dart, per
candidate, at directory-build time**: `nameKey` for collision comparison and
`searchKeys` (petname, `display_name`, `name`, deduplicated) for matching, both
via `fold(...)` at `member_directory_service.dart:251` and `:260`, feeding
`MemberCandidate` at `:265-274`. Nothing folded is written to SQLite at all, so
the three problems the column was meant to fix do not arise: there is no folded
name to outlive `wipe_all_profiles`, no second write site for the name, and no
`json_extract` + `lower()` query — the ranked read returns pubkeys and the names
arrive through the profile cache. **Do not re-add the column** without a measured
reason; the §9.3 architecture (one ranked read per sheet-open, then a synchronous
in-frame Dart filter) is what removed the need for it. **[P4] The module
comment that still asserted the folded key "lives in `profiles`" has been
corrected** — it now says what is true, that nothing folded is written to SQLite
at all and the search keys are folded per candidate in Dart.

```sql
CREATE TABLE IF NOT EXISTS member_directory (
    pubkey           TEXT PRIMARY KEY,   -- Member.id, lowercase hex
    is_current       INTEGER NOT NULL DEFAULT 0,
    last_shared_day  INTEGER NOT NULL DEFAULT 0,
    tier             INTEGER NOT NULL,   -- 0 = current, 1 = recent (≤3d)
    rank_key         INTEGER NOT NULL,
    purge_after      INTEGER NOT NULL    -- i64::MAX = never
) WITHOUT ROWID;
```

**[P4] Two corrections to what P3 shipped**, both applying the rule that got
`first_seen_day` dropped — no reader, and a partition leak:

* **`updated_day` is gone.** It had no reader anywhere, and because the demotion
  UPDATE carries no `WHERE`, every row held the same value — a per-sync stamp of
  when the directory was last touched, exported to nobody.
* **The table is `WITHOUT ROWID`.** As a rowid table it carried an implicit
  arrival-order counter, and `sync_co_members` inserts each pass's NEW pubkeys in
  `BTreeSet` order while `ON CONFLICT DO UPDATE` preserves existing rowids — so
  each pass's newcomers form a contiguous, pubkey-sorted rowid block and a
  descending pubkey step between consecutive rowids marks a batch boundary:
  "these people arrived together", i.e. a circle's roster. That is exactly the
  `first_seen_day` leak below, re-created by the storage engine.
  `PRAGMA table_info` never reports a rowid, so the column test could not see it;
  `member_directory_stores_no_arrival_order` reads `sqlite_master` and then
  proves `SELECT rowid` no longer answers. Upgraded installs are converted by
  `migrate_directory_to_without_rowid`, which DROPs the legacy table before the
  schema's `CREATE TABLE IF NOT EXISTS` re-declares it (SQLite has no in-place
  conversion, and a copy-and-rename would need the second
  `member_directory`-shaped table the privacy guard forbids). Dropping is the
  privacy-safe direction and costs nothing visible: the reconcile that runs
  before the picker's first read restores every current co-member.

`last_shared_day` stays in the table — `purge_after` is computed from it — but is
no longer exported over the FFI: no Dart consumer ranked, grouped or rendered by
it, so `DirectoryEntryFfi` now carries WHO and WHICH SECTION and nothing else.

**[P3] Shipped** at `haven-core/src/circle/storage.rs`, with the privacy
rationale in the schema comment above it and the module's own statement of the
guarantees at the top of `storage_member_directory.rs`.

**Storage guarantee (owner-required, §10 D3).** This table lives in
`circles.db` — SQLCipher, encrypted at rest, key held in the platform keyring
(Keychain / GNOME Keyring / Credential Manager), never in the app. It is the
strongest store available in this application. It must **not** be written to
`SharedPreferences`/`NSUserDefaults`, `flutter_secure_storage`, or any sidecar
file: logout deletes exactly the encrypted DB files, so a third file would
survive identity deletion. **[P3]** That file deletion IS the logout wipe — there
is no directory wipe method to join. All three properties are separately tested
(`storage_member_directory.rs`, `the_member_directory_does_not_outlive_the_circles_db_file`).

**[R] Dropped from the draft:** the folded name columns (moved to `profiles`);
`npub` (matching happens in Dart, and the 3-way match measured **2× slower**);
`first_seen_day` (no reader — and a partition leak); `updated_at` at second
granularity (re-encoded the cluster); `source_flags` and `follow_position`
(R3 cancelled — there is no second source, so `tier` alone carries it).

**[R] `purge_after` — the draft's hypothesis was refuted.** Measured, `NULL` is
*safer* than a `0` sentinel because the destructive direction fails closed — but
**neither is right**: NULL breaks every read (`>= now` drops rows; `ORDER BY`
sorts NULLs first; `min()`/`count(col)`/`BETWEEN`/`NOT IN` silently exclude
them). Use **`NOT NULL` with `9223372036854775807`**.

**Day bucketing — the draft's reasoning was wrong. [R]** `sync_co_members` is a
full-union rewrite, so every current co-member is stamped in the same pass across
all circles — **the union design, not the bucketing, destroys the current-circle
partition.** The real leaks were `first_seen_day` and second-granularity
`updated_at`; both are now dropped. What remains: the *departure cohort* shares a
freeze day. Day bucketing **raises the cost; it does not eliminate the attack** —
with a 3-day window there are at most 3 live values.

**[R] Scope the threat honestly:** an on-device adversary can already read the
full partition for *current* circles from the engine's `session.sqlite`. The
directory only adds partition information for circles whose other rows
`delete_circle` has already cascaded away.

**[P3] `wipe_member_directory` was DELETED, not wired.** Every logout and
identity-deletion path funnels into `IdentityNotifier.deleteIdentity`
(`identity_provider.dart:204`) → `wipeAllMlsState` (`:332`) →
`wipe_all_mls_state` (`rust_builder/src/api.rs:967-989`), which unlinks
`circles.db` plus its `-wal` / `-shm` / `-journal` sidecars before removing both
keyring keys; `createIdentity` (`identity_provider.dart:87-109`) and
`importFromNsec` (`:128`) retire the circle service only after
`_reconcilePendingMlsWipe` (`:181-199`) has re-run that wipe and confirmed the
marker cleared, failing closed otherwise. **There is no logout path that leaves
the files.**

The belt-and-braces argument — wipe the table too, in case the file delete fails
— was considered and rejected on a stated ground rather than on taste: on a
failed file delete the surviving `circles.db` still holds `circles`, `contacts`,
`profiles` and `profile_pictures`, and the directory's contents (pubkeys and two
day buckets) are a strict subset of what `profiles` already retains **with names
and photos**. A directory-only pre-wipe would be theatre — it would delete the
weakest artifact and leave the strongest, while adding an API and a promise.

**Retention is a deadline for the disk, not an eligibility rule.** The purge
originally ran only inside `reconcile_member_directory`, so on an idle install an
expired row stayed on disk and was still returned by the unfiltered ranked read —
past the window the disclosure copy promises, on exactly the quiet device the
copy is least able to be wrong about. It now runs from three places over one
shared `purge_expired` helper, so they cannot disagree about when a person
expires:

* **[P3] the ranked read**, which opens a transaction, purges and selects inside
  it — DELETE-then-read, honouring D3's "purged by DELETE, never a display
  filter" literally rather than only where a reconcile happened to run first;
* **[P4] every process start**, from `CircleManager::new`. This is the trigger an
  idle device still produces: a stable circle generates no membership change, no
  publish resolution and no welcome, and a user who never opens the invite picker
  never triggers a read — so without it a departed co-member's pubkey sat on disk
  for weeks. A bare purge needs no MLS session, no roster read and no session
  lock, so it rides a database open the constructor was already performing, next
  to the contamination-ledger backfill and the retired-relay prune. No new wake,
  no new battery cost. Failure is logged, never propagated, exactly as those two
  are;
* **[P3] the reconcile**, over the same helper.

The read sweep alone was not enough, and neither is the start sweep alone: the
read bounds what can be SHOWN, the start bounds what is STORED on a device whose
picker is never opened.

### 6.2 The fold — a real bug the draft would have shipped **[R]**

**`str::to_lowercase()` is context-sensitive.** Rust applies the Unicode
`Final_Sigma` rule, so `Σ` → `ς` word-finally and `σ` elsewhere. The fold is
therefore **non-compositional**, and substring search over independently folded
strings breaks:

```
fold("ΣΙΣΥΦΟΣ") = "σισυφος"     (final ς)
fold("ΣΙΣ")     = "σις"         (ς — but it is medial in the name)
"σισυφος".contains("σις")  →  FALSE
```

A Greek user typing the first three letters of a name, in caps, gets **zero
results**. Present in the all-Rust path too. A sweep found 18 non-compositional
pairs out of 729, **every one `X + Σ`**. Neither obvious repair suffices alone:

| Fold | `ΣΙΣΥΦΟΣ ← ΣΙΣ` | `Γιώργος ← ΓΙΩΡΓΟΣ` |
|---|---|---|
| `str::to_lowercase` (draft) | ✗ | ✓ |
| per-char `char::to_lowercase` | ✓ | ✗ |
| **per-char + explicit `ς`→`σ`** | ✓ | ✓ |

**Corrected spec:** per-character `char::to_lowercase` → NFKD → drop
*decorative* combining marks → drop `Cc` and everything invisible → lowercase
AGAIN → map `U+03C2 → U+03C3` → transliterate. The draft's "documented
non-equivalence: Greek final sigma" is **deleted and inverted into a test that
they DO unify** — as written it pre-authorised a bug.

**[P0] The last two steps are ordered, and getting it wrong is not idempotent.**
The transliteration table is keyed on lowercase, and NFKD can yield an
UPPERCASE letter. Exactly two scalars in all of Unicode decompose to an
uppercase table key — U+1D2D → `Æ` and U+A7F8 → `Ħ` — so looking the table up
before the post-NFKD lowercase pass folded `ᴭ` to `æ` while `æ` folds to `ae`.
`prop_fold_is_idempotent_and_never_panics` reached one of them about once in 592
runs; the sweep that replaced it (`fold_is_a_fixed_point_for_every_scalar_value_in_unicode`,
1 114 112 scalars, ~2 s) decides it.

**[P0] "Drop combining marks" is wrong for three shipped locales.** A matra is a
LETTER in Devanagari and U+3099 is what makes `だ` out of `た`, so a blanket
mark-drop reduced `नेपाल` to `नपल` and merged `कमला`/`कमल`, `राम`/`रमा`,
`ガンダム`/`ガンタム`. Corrected: drop a mark only where it is optional
*pointing* — Latin/Greek/Cyrillic accents, Arabic harakat, Hebrew niqqud — from
an explicit range table (`DECORATIVE_MARK_RANGES`), and keep every other mark.
Latin, Greek, Cyrillic, Arabic and Hebrew behaviour is unchanged; hi, ne and ja
lose accent-insensitivity they never wanted and gain correct keys. A mark the
table misses stays in the key, which costs a search miss and never a wrong
match.

**[R] Second gap: stroke and ligature letters.** NFKD removes only *combining*
marks:

```
Đurđević → "đurđevic" ← "durdevic" ✗    Bjørn → "bjørn" ← "bjorn" ✗
Łukasz   → "łukasz"   ← "lukasz"   ✗    Þórir → "þorir" ← "thorir" ✗
Nguyễn Đức → "nguyen đuc" ← "nguyen duc" ✗
```

`đ ø ł ħ æ ð þ` cover Croatian, Serbian, Bosnian, Norwegian, Danish, Polish,
Icelandic and Vietnamese. Add an explicit transliteration table, or say so in the
copy. **[P0] Done — the table** (`haven-core/src/directory/fold.rs:68-82`) **also
carries `ı`, `œ`, `ß` and `ŧ`.**

**[R] Third: "drop Cc/Cf" is not buildable from `unicode-normalization`.** It
exposes no general categories, and `char::is_control` is **Cc only** — exactly
the bug §7.3 diagnoses. Nothing in `Cargo.lock` provides Cf except
`icu_properties` (transitive via `url`→`idna`). The fold needs a hand-rolled Cf
table or a promoted dependency. **The draft's "unifies rather than widens" claim
covered only half of what the fold requires.**

**Verified and load-bearing:** deleting members of a canonically ordered run
leaves it canonically ordered, and no transliteration expansion introduces a
non-starter — so the marks the fold now KEEPS leave the output NFKD-normalised
and re-folding is a fixed point. (The draft rested on a different fact — that no
code point with `ccc != 0` escapes `is_combining_mark` — which was true, and
load-bearing only while every mark was dropped.)

**Why not FTS5** (available; ICU is not): `LIKE`/`NOCASE` are ASCII-only
(`'ÄBC' LIKE '%äbc%'` → 0), so R4 would silently fail for Turkish, German, Greek
and French names. `unicode61` gives token-**prefix** matching only; `trigram`
does **no** diacritic folding. **[R]** The dismissal survives on the prefix-only
ground alone — `unicode61` *does* fold case and strip diacritics.

## 7. Anti-impersonation

### 7.1 The npub is always visible, at 12/6

Prefix 12 exposes 7 data chars (2³⁵ ≈ 34 s to grind at 10⁹ keys/s); adding the
6-char bech32 checksum reaches 2⁶⁵ ≈ 1,200 years. An attacker cannot *solve* for
a target checksum — a secp256k1 point can only be sampled. **The suffix must come
from the end;** a prefix-only "cleanup" is a real regression. Verified
independently by two reviewers.

**[R] FOUR truncation formats existed in this flow, and the two the draft missed
were the weakest and most dangerous.** The table below is the **pre-P0** state;
none of these line numbers resolves any more, because P0 deleted every literal:

| Site | Format | Grind cost |
|---|---|---|
| `circle_member_tile.dart` | 12/6 | ~2⁶⁵ |
| `PendingMemberTile` | 10/4 default | — |
| **`selected_members_list.dart`** | **8/4** | **≈2³⁵ ≈ 34 s** |
| **`selected_members_list.dart`** | **6/3** | **≈2²⁰ ≈ milliseconds** |

The last two were the **staged-member chips on the create-circle screen** — the
confirmation surface for who you are about to share live location with.

**[P0 outcome]** There were **eight** call sites, not four — `member_detail_sheet.dart`
and `remove_member_action.dart` were already at 12/6 but restated the
literals. All eight now source from `NpubValidator.shortenForDisplay`
(`npub_validator.dart:109`), whose `prefixLength`/`suffixLength` parameters were
**deleted**: they were the mechanism by which every weak variant appeared, and
after the audit no caller wanted anything else. There is now no argument a future
call site can pass to shorten it.

**[P3] The eight, as they stand** — `circle_member_tile.dart:138`, `:330`,
`:483`; `member_detail_sheet.dart:91`; `remove_member_action.dart:119`;
`selected_members_list.dart:85`; `invitation_card.dart:288`; and P2's new
`member_picker.dart:277`. A lint test fails if a ninth format appears
(`test/lints/single_npub_display_format_test.dart`).

**The three related surfaces P0 found — two are now CLOSED:**

- ~~**`invitation_card.dart:86`** renders the *inviter's* pubkey as **hex at 8/4
  = 48 bits**~~ — **CLOSED.** The card now renders `invitation.inviterNpub`
  (bech32) through `shortenForDisplay` at 12/6 (`invitation_card.dart:288`), so
  the join screen carries the same 2⁶⁵ grind cost as the roster. The conversion
  step the draft said was needed is the `inviterNpub` field itself
  (`circle_service.dart:334`), which the FFI already supplies.
- **`SelectedMembersSummary` is still fed hex, not an npub**
  (`name_circle_page.dart:166-169` maps `memberKeyPackages` to `kp.pubkey`), so
  the create-circle confirmation renders a hex fragment through an npub helper.
  Not a downgrade (12+6 hex chars pin 72 bits vs the old 6/3's 36), but a user
  cannot cross-check a hex fragment against the npub they were handed. **Still
  open** — P2 rebuilt the picker, not this summary.
- ~~`key_display.dart`'s two widgets~~ — **DELETED**, not "left alone": §3's D7
  orphan sweep removed the file along with its public `truncateLength`
  parameter. There is no `key_display.dart` in the tree.

### 7.2 Two tiers, by section, achromatic

With R3 cancelled there are exactly two sections. Headers state the tier once,
structurally; per-row badges are what a scanning eye skips and ellipsize at 2x.

**[P1] The drafted headers claimed more than Haven can prove and are replaced.**
Per §3, Haven cannot detect whether anyone accepted an invitation, so a header
implying an established relationship is unbacked. What the roster *does*
establish is **provenance**: this pubkey is on the member list of a circle on
this device, placed there by an MLS-authenticated commit, with its identity proof
verified. So the headers state roster membership and nothing else:

| Tier | Header | Replaces |
|---|---|---|
| 0 | **"Members of your circles"** | ~~"In a circle with you"~~ |
| 1 | **"Recently in your circles"** | ~~"Shared a circle in the last 3 days"~~ |

**Banned from either header** — each is a claim about the peer's *device* state,
which Haven has no way to observe: *joined*, *accepted*, *confirmed*, *verified*,
*active*, *connected*, *sharing with you*.

**The copy-accuracy test must pin the semantics, not the string** (a header grep
is brittle): assert that **a member added by an applied commit who has never sent
a message still appears in tier 0**. That fails the moment someone "improves" the
section by filtering on participation, which is the actual regression to guard
against. Pair it with: tier 0 is populated exclusively from a post-converge
roster union, and nothing appears there that is absent from that union.

**Achromatic.** `HavenSecurityColors.encrypted` (#16A34A) is **3.30:1** and
`warning` (#D97706) **3.19:1** — both fail WCAG AA as text (they pass for large
text and non-text UI at 3:1, so the qualifier is load-bearing). Independently,
green already means "KeyPackage validated" on the staged tile.

Screen readers never hear section headers when swiping row-by-row, so **the tier
is repeated in every row's semantics label**.

**No circle is ever named at rest** (§10 D4). The single exception: a circle name
may be shown to break a **display-name collision** between two co-members, where
it is the only local disambiguator. Colliding names mark **every** colliding row.
**Local petnames win and say so.** **Never render `about`.**

#### 7.2.1 The collision label is label-value, not a prepositional phrase **[P3]**

`memberPickerCollisionCircleLabel` was drafted as a bare prepositional phrase —
"In {circleName}". **It is now a label-value construction — "Circle:
{circleName}" — in English and eleven of the twelve translations**
(`app_en.arb` and siblings; the rule is written into the key's own ARB
description so a future translator cannot re-derive the bad shape).

**Why the bare form had to go: on realistic input it is a FALSE LOCATION CLAIM.**
"In Family", "In Brooklyn" — and the per-locale equivalents — collide with
ordinary locative idiom, so in a *location-sharing* app the disambiguator reads
as an announcement of where the person is. The failing inputs are not contrived:
they include the circle names `nameCircleNameHint` itself suggests. The
label-value shape also sidesteps case government and possessive re-readings, and
it needs no quotation marks.

**Two exceptions, each on its own evidence:**

- **Russian keeps the anchored, quoted form** — `В круге «{circleName}»`
  (`app_ru.arb:323`). There is no locative homonym to trip over, and «…» is a
  genuine in-file convention rather than an import: eleven `ru` strings already
  quote a user-supplied name that way, including `nameCircleCreatedSnack`'s
  `Круг «{name}» создан`. Changing it would have made `ru` the odd one out
  against its own file to match a rule written for a hazard `ru` does not have.
- **German MOVED to label-value** (`Kreis: {circleName}`) rather than keeping an
  anchored form, because `Kreis` is also the German word for an administrative
  **district**. Its anchored form was therefore itself a location claim — the
  exact defect the rule exists to prevent, arrived at through a homonym instead
  of through idiom.

**Quotation marks are not an accessibility fix.** Screen readers do not speak
them at default verbosity, so quote-based disambiguation is inert on the audio
path — it buys nothing for the reader who most needs the row's boundaries made
explicit. That is why the rule is *shape* (label + colon + value), which
survives being spoken, rather than *punctuation*.

#### 7.2.2 The disambiguator must actually distinguish **[P3]**

The first implementation gave **each colliding row its own alphabetically-first
circle, chosen independently**. When two colliding people shared that circle, both
rows rendered the same name and **the disambiguator disambiguated nothing** —
worse than silence, because a reader takes a difference in the note to mean a
difference in the people.

Shipped instead: `_distinguishingCircleName`
(`member_directory_service.dart:423-431`) takes the alphabetically first of the
row's own circles that is **not** in the union of every OTHER colliding row's
circles, and returns `null` when no such circle exists — in which case the row
renders no note at all. `_markCollidingNames` (`:362-401`) builds the exclusion
set from each rival's *full* circle list rather than from what that rival ends up
showing, so the choice does not depend on which row is considered first. The
always-visible 12/6 npub (§7.1) remains the unconditional differentiator when the
note is absent.

**Known inconsistency to fix in the code, not here:** the ARB description for
`@memberPickerCollisionCircleLabel` still tells translators that `{circleName}`
is "chosen INDEPENDENTLY for each colliding row — the alphabetically first circle
THAT row's person shares with the user". That is precisely the behaviour
`_distinguishingCircleName` replaced. The description's *translation* rules
(label-value shape, never a locative, never "a shared circle") are all still
correct; only the selection sentence is stale.

Two scope rules ride with it, both stated at `:350-361`: the pass is **tier-0
only** (a recent contact is no longer a co-member of anything, so no current
circle could be the reason their name collides), and it compares the **exact
rendered `displayName`, never the folded search key** — two names that merely
fold alike are not a rendered collision, and marking them would name a circle
nobody needed.

#### 7.2.3 Bidi isolation: one rule, two contradictory comments reconciled **[P3]**

An isolate (`U+2068` FSI / `U+2069` PDI) **protects nothing on the speech or
braille path** — both read a string's codepoints in logical order, with no
paragraph layout for an unterminated override to escape. It is kept anyway
wherever **other label text FOLLOWS the untrusted substring inside the same
joined string**, because that is exactly what an override could otherwise
swallow, and because it costs nothing: never spoken, never a braille cell.

Applied to the picker row (`member_picker.dart:448-459` states the doctrine;
`:388-401` applies it):

- The **rendered** collision label **is** isolated (`:293-296`). The circle name
  is remote-supplied — it comes from the MLS group record, chosen by whoever
  created the group, not by the local user — and it shares a paragraph with app
  text.
- In the **semantics** label, `identity` is isolated (`:415`) because the tier,
  the nickname note, the collision note and any refusal reason all follow it in
  the same joined string. `collisionLabel` is passed through **un-isolated**
  (`:316`, built from the raw name at `:290-292`): nothing follows it, so there
  is nothing left for an isolate to protect.

#### 7.2.4 The ASCII comma in the semantics join — RESOLVED AS COSMETIC **[P3]**

`_semanticsLabel` joins its parts with `', '` (`member_picker.dart:420`). Raised
three times as a possible RTL defect; **it is not one, and it is not to be raised
a fourth**:

1. **U+002C and U+060C share a Unicode bidi class (CS).** The bidirectional
   algorithm cannot distinguish them, so substituting the Arabic comma changes
   nothing the algorithm does.
2. **Speech consumes logical order**, so no isolate and no separator choice can
   reorder what is spoken.
3. **A semantics label is never laid out.** There is no visual run for a
   separator to sit wrongly inside.
4. **The "fix" had negative expected value.** ASCII comma is in every TTS
   engine's punctuation table; U+060C is the likelier omission in a minor engine,
   where it would be spoken as an unknown character or dropped.

### 7.3 Sanitization — corrected **[R]**

There was no kind-0 sanitizer; `sanitize_display_name` lived in
`location/types.rs`, was Cc-only, capped at 64 *chars*, and ran only on the
contact path. `ProfileMetadataFfi` shipped raw name fields across the FFI.
**[P0] It has since moved and been rewritten** to the spec below:
`haven-core/src/directory/sanitize.rs:48`, wired at `write_profile_row` and
`map_profile_row` (`storage_profile.rs:914`, `:948`) and still applied to the
legacy location-JSON display name from `circle/manager.rs:1638` and `:1659`.
`location/types.rs` retains no sanitizer — only a pointer to the new home, at
`:419-421`.

**[R] The draft's strip table contradicted itself** — it said keep U+200E/U+200F
and strip "other Cc/Cf", but those **are** Cf. It also omitted U+061C and would,
read literally, strip the emoji tag characters. Corrected:

| Codepoints | Action |
|---|---|
| U+202A–202E, U+2066–2069 | **strip** — their effect *is* the attack |
| U+200E, U+200F, U+061C | **keep** (explicitly, ahead of the strip rule) |
| U+200C ZWNJ, U+200D ZWJ | **keep — mandatory** for fa/ur/hi/ne orthography and emoji |
| U+E0020–E007F | **keep** — emoji tag sequences |
| U+FE0F VS-16 | **keep** — selects emoji presentation; without it `❤️` redraws as the text glyph and every RGI ZWJ sequence built on it breaks |
| U+200B, U+2060, U+FEFF, U+00AD, remaining `Cc` / invisible | strip |
| whitespace runs | collapse |
| length | cap at 48 grapheme clusters **and 32 chars per cluster** |

**[P0] The strip rule is NOT "Cc or Cf" — the attack is not confined to `Cf`.**
U+3164 HANGUL FILLER, U+115F, U+1160 and U+FFA0 are general category **`Lo`**
(letters) and U+034F and the variation selectors are `Mn`; every one of them
renders as nothing, and a `Cf`-only rule let `Al<U+3164>ice` through — a name
that renders as `Alice`, compares unequal to it, and Haven would have signed and
published it. The predicate is the union of `Cf` and
**`Default_Ignorable_Code_Point`** (25 ranges, hand-enumerated from Unicode
17.0.0 in `directory/invisible.rs`, pinned by a test that fails when
`unicode-normalization` / `unicode-segmentation` move past that release). Note
the fail-open direction is OPPOSITE for the two callers: a code point the table
misses costs the fold a search miss, and costs the sanitizer an invisible
character **on the screen**.

**[P0] "Non-empty" is not "renderable".** The keep-list is precisely the set of
characters that are invisible *and* kept, so `{"display_name":"\u200E"}`
survived the strip, `String.trim()` on the Dart side does not remove LRM either,
and the name precedence rendered a blank row instead of falling through to the
npub. The emptiness test is "anything renderable remains" (`is_renderable`:
not on the keep-list, and not the interior space the collapse emits). The same
test is what makes `enforce_name_rule`'s `trim`-based blankness check sound on
the publish path — otherwise `{"name":"\u200E","display_name":"Alice"}`
published both fields, disagreeing.

**[P0] The cluster cap bounds clusters, not size.** `a` + 100 000 combining
marks is ONE cluster and 200 001 bytes; `A` + 100 000 tag characters is 400 001.
A second cap of **32 chars per cluster** ends the name at the first cluster that
breaks it (ending, not skipping, is what keeps "no leading space, no double
space" true). 32 admits every RGI emoji sequence (longest is 10 code points) and
every UAX #15 Stream-Safe cluster (a starter plus at most 30 non-starters), and
bounds the whole stored name at 48 × 32 = 1 536 chars.

**[R] The search fold and the collision fold must be different functions.** The
draft claimed the ZWNJ residual is "caught by collision detection", but collision
detection was specified as a homoglyph table, which has nothing to do with
invisible joiners. And if collision ran over the *search* fold (which strips Cf),
**every legitimate Persian/Urdu name pair differing only by ZWNJ would be flagged
as impersonation** — a false positive aimed at the users the carve-out protects.

**Bidi:** the npub is always its own `Text` on its own line, never concatenated
with the name. The name takes direction from its own first strong character. The
only concatenation is the semantics label, where the name is wrapped in FSI/PDI.

**[R] Consider cutting the confusables table entirely** — it buys little next to
the always-visible 12/6 npub and adds a curated Unicode table with no upstream.

## 8. Deliberately not built: follow-list suggestions (do not re-add)

**Owner decision, 2026-08-24: R3 is cancelled entirely.** This section is the
record so it is not re-litigated as an oversight.

**Why it was dropped:**

1. **It is a no-op for almost every user.** Haven generates a fresh identity at
   onboarding and **never publishes a kind-3**. Only an `import_from_nsec`
   identity has a follow list at all.
2. **The subtraction attack.** The draft recommended a relay plane on the basis
   that it avoided this attack. **[R] That was wrong** — the attack is not caused
   by the kind-3 read but by resolving followed *strangers'* kind-0 on the
   profile plane, which creates a lookup stream that mixes co-members with
   follows. A relay can fetch the (public) follow list itself and subtract,
   sharpening its ~1/8 slice into a co-membership candidate set: prior ≈33%,
   ~100% precision after. Moving the read does not mitigate it.
3. **[R] The draft's plane table was incoherent.** It rejected the discovery
   plane because those relays carry kind-445/1059, then picked the account plane
   — which *is* a strict subset of the discovery set.
4. **The salt-burn, never stated in the draft.** The profile relay salt is
   deliberately never rotated, an accepted cost scoped to a roster of tens.
   Resolving follows would make each pool relay a durable, timestamped holder of
   ~1/8 of the user's follow graph — widening that accepted deviation by 10–100×.
5. **R1/R2/R4/R5 deliver the whole "stop pasting npubs" outcome** with no
   dependency on it.

**Consequences, all positive:** no NIP-02 parsing, fetching or storage; no
relay-plane decision; no new privacy-manifest entry; no new E2E lane; no new
guard script; the kind-3 prohibitions stay green untouched; and constraint §4.2's
"scoped to a roster of tens" stays true.

**Haven must never write kind 3.** Firm and permanent, independent of this
decision.

## 9. Flutter architecture

### 9.1 Layout — the draft's restructure is CUT **[R]**

The draft claimed `create_circle_page.dart` puts an intrinsically-sized empty
state in a tight `Expanded`. **It did not** — it wrapped it in `HavenScrollFill`
with the reasoning in a comment directly above. (No line numbers: P2 rebuilt the
page on a `CustomScrollView`, per the conclusion below, so `HavenScrollFill` is
gone from this file — it survives at `circles_page.dart:138`,
`map_page.dart:614`, `:696` and `relay_settings_page.dart:118`, `:127`.)

Worse, `AddMemberPage` **already implements what the draft called its
"fallback"**, and the failure that produced it is recorded with a CI run id:
`add_member_page_test.dart:868-881` cites *"CI run 31462924650 produced `A
RenderFlex overflowed by 7.8 pixels on the bottom`"* (`:876-877`) on an iPhone 15 — a
**larger** device than the 320×568 being budgeted. The draft proposed reverting
to the shape that already failed.

Arithmetic at 2.0x German: field ≈80 dp + reserved 2-line error ≈64 dp + gap 16 +
two-line CTA ≈80 dp = **~240 dp** against ~189 dp available. Even the draft's
optimistic ~152 dp leaves the `Expanded` 37 dp — less than one 48 dp row.

**Adopt `AddMemberPage`'s shipped shape on both pages**: one `CustomScrollView`,
only the CTA pinned. Already proven at 2x German with the keyboard by four
existing tests.

**[R] Do not delete `memberSearchHelper`.** It is not a duplicate of
`createCircleEmptyMessage` — it is the only place the app says *where an ID comes
from*.

### 9.2 Layout stability while typing

Abandon `errorText` (it grows the field mid-keystroke); errors go to a
height-reserved helper line. Fixed-width suffix box. Fixed-height section
headers; a zero-match section is omitted header and all. **No list
insert/remove animation.**

**[R] `onSubmitted → stage` is load-bearing and the draft nearly broke it.**
Removing the "+" button on the grounds that "the typed-ID row now owns" staging
would make `receiveAction(TextInputAction.done)` stage nothing, and **both E2E
lanes hang to their 60 s timeout**. Full contract: the page type stays findable;
the keyed field resolves to exactly one focusable editable owning the `TextInput`
connection when `receiveAction` fires; submitting stages; staging flips the CTA
to a **`FilledButton`** with non-null `onPressed` (the predicate returns false
forever for any other type — a silent hang, not a clear failure);
`AddMemberPage` pops on success.

**[R] Cut the "byte-identical rect across 63 keystrokes" invariant** — implied
once `errorText` is gone, and as a stated rule it invites a brittle golden-rect
test. Assert the real regression: *the rect does not change when the error
appears or clears.*

### 9.3 Filtering — resolved **[R]**

The draft's synthesis (Rust-folded keys + a *debounced* FFI query fold) was
self-defeating: the fold gates the filter, so a debounced fold is a debounced
filter. It also manufactured a stale-in-flight race neither original position had.

**The premise that "an FFI call lands after the frame" is false for
`#[frb(sync)]`.** Verified structurally: the generated body is a direct
`dart:ffi` call on the calling thread — **no isolate hop, no port, no future**.
The repo already ships 38 `#[frb(sync)]` sites in `rust_builder/src/api.rs`;
`default_relays()` returns `List<String>`, not a `Future`.

**Adopt:** Rust materializes the folded search key per row; a **top-level**
`#[frb(sync)] fold_for_search` for the query, called **undebounced** on every
keystroke; Dart filters synchronously in the same frame. Top-level matters twice
— no opaque handle (avoiding the off-interface downcast) and it mirrors
`default_relays()`.

A sync call throws when `RustLib` is uninitialized, which is every
`flutter test`. The repo already solved this — `relays.dart:31-38` wraps the sync
getter in try/catch with a pinned fallback and a CI diff. Reuse that shape.

**Pure-Dart fold rejected.** **Dart core has no NFKD at all**, so a Dart fold
means a second, independently-versioned Unicode database drifting on every
dependency bump. Its `toLowerCase()` also disagrees on the cases the fold exists
for: `Ärger`, `Straße`, `Đurđević`, `Çağrı`.

**[P1 correction — this paragraph originally cited the wrong evidence.]** It
claimed Dart disagrees on `İstanbul` and `ΟΔΥΣΣΕΑΣ`. It does not: Dart yields
`istanbul` and `οδυσσεασ`, which is **exactly what the shipped fold produces**.
Those two disagree with `str::to_lowercase`, whose `Final_Sigma` context rule and
combining-dot output §6.2 deliberately **rejects** — so they argue against a
design haven-core turned down, not against this one. The claim propagated into
`api.rs`, its generated Dart, and `search_fold.dart` before being caught; all
four sites are corrected.

Measured Dart filter over 2000 rows: **0.063 ms** (hit) to **0.72 ms** (full
scan). **Caveat:** an FRB sync round-trip was not wall-clocked; it runs on the
platform thread and should be measured on a mid-range Android device before the
design is locked.

### 9.4 Providers and avatars

Row avatars watch the existing `memberProfileProvider` — pure local read,
autoDispose, error-swallowing.

**[R] `AvatarImageCache`'s real disqualifier:** it is a **process-global
singleton** whose only production consumer is the map marker layer. Feeding
picker rows into it would evict the `ui.Image`s `CustomPainter.paint` needs
*synchronously* — **the picker would degrade the map.**

**[R] The 8 MiB `ImageCache` is Haven's override**, documented as *"a privacy
bound, not a performance cache — keep it small."* Flutter's default is 100 MiB.

**[R] The draft bounds image cost and never bounds SQLCipher cost.** Each newly
built row instantiates an autoDispose provider → one cached-profile read → **three
SQLCipher queries**. A fling building 30–60 rows/s issues that many reads and
discards most before they resolve. Needs a bound.

**Picture cache cap (§10 D5): 50 people, LRU by last render**, enforced in Rust
with a test. With R3 cancelled the natural population is roster-sized anyway; the
cap makes the ceiling explicit rather than emergent.

### 9.5 A pre-existing bug **[R]**

`create_circle_page.dart` contains no identity read anywhere: a user can stage
their own npub, `_validateMember` finds their own KeyPackage and marks it
`valid`, and it proceeds to `NameCirclePage`.

**[R] Two refinements:** "Already in this circle" for self is *literally true*,
just unhelpfully generic — the sharper defect is that the check sits **after** a
network KeyPackage fetch, so offline it **fails open** and the self-add is never
identified. Three disabled reasons are needed, not two: *already staged*
(exists), *already in this circle*, and *that's you*.

### 9.6 Accessibility

One semantics node per row. The list is **not** a live region — a `liveRegion`
re-announces its whole subtree on every rebuild (documented in-repo at
`profile_sync_status_line.dart:32-33`). Instead: one debounced announcement per
*settled* query (400 ms **and** the result set actually changed). Zero results is
announced once. **Visual filtering stays 0 ms.**

**[R] The npub must NOT go in the `CustomSemanticsAction` label.** Those actions
have value equality on `(label, hint, action)` and are interned in **static,
monotonically-growing maps with no production prune path**. Today's usage is safe
because the label is a constant l10n string. A label containing the npub interns
**one permanent entry per npub ever rendered** — identifier material held for the
process lifetime, outside SQLCipher, unreachable by the logout wipe. Keep the
label constant and announce the chunked npub from the callback.

**[R]** The draft claimed this diverges from `CircleMemberTile`. It does not —
that tile puts the npub in the label only as a *fallback* when no name resolved.

**[R] ~~The npub currently ellipsizes.~~ [P0] REVERSED — the tree now says the
opposite, deliberately.** `circle_member_tile.dart:325-335` states the rule in
place: the npub subtitle "keeps the same no-ellipsis rule the title applies to
it — the roster is where a user checks who they are sharing live location with,
so it must not clip the six checksum characters the 12/6 form exists for." The
tile ellipsizes only the *title* and only when a real name occupies it
(`:258-259`), and the admin chip (`:362-363`), which is a label that survives
clipping. So "make it deliberately and everywhere" was done, in the direction
opposite to the one this bullet assumed; no picker row may re-introduce
ellipsis on an npub.

**[R] `enableIMEPersonalizedLearning` is the flag that controls the learned
dictionary — not `autocorrect`/`enableSuggestions`, which is what the draft
claimed.** It appeared **nowhere** in `haven/lib`, so the guarantee was unmet on
the *existing* field. **[P0] Now set `false` on all seven text fields** —
`name_circle_page.dart:140`, `import_nsec_screen.dart`,
`create_identity_screen.dart`, `add_relay_sheet.dart`,
`member_detail_sheet.dart`, `member_search_field.dart`,
`display_name_card.dart`. **[R]** Android
**Content Capture** is a separate, on-by-default OS egress path that will now
read a rendered contact list; disclosed in copy (§10 D6).

## 10. Decisions taken (owner, 2026-08-24)

**D1 — Follow-list suggestions: CANCELLED.** Not built, not deferred. §8 is the
record. R3 struck from scope.

**D2 — Typed-stranger resolve: BUILD, narrowly.** Auto-resolve fires only on a
**complete, valid** npub — never on a partial prefix, never for a suggestion row.
**No picture is downloaded until the person is selected** (a picture URL is an
HTTP GET to a host the profile's owner chose, from the user's IP). **[R]** The
draft overstated its novelty: `_onMemberAdded` already fires `fetchKeyPackage` on
add, so the pasted key already leaves the device; the real delta is *a different
plane* and *500 ms earlier*. **[R]** It punctures Check 7 — a singleton
non-union intent-bearing REQ is what that guard prevents — so the replacement
confinement is a designed change, not a guard tweak.

**D3 — Retention: 3 days, and delete on removal.** Reduced from the drafted 7.
Day-coarse. Purged by **DELETE**, never a display filter. A deliberate removal in
**either direction** — you remove them, or they remove you — deletes the row
immediately rather than aging it out. Stored only in the SQLCipher-encrypted
`circles.db` with its key in the platform keyring; never in preferences, secure
storage, or any sidecar file; joins the logout wipe.

**[R] The spec justification was overstated.** Local persistence is **outside
the spec's scope** — `principles.md` says the protocol documents "SHOULD NOT
describe … database tables". The one adjacent clause is permissive, not
authorising: `protocol-core/member-departure.md` ("Realizing removal") lets a
client "retain previously delivered content and group history for local display"
or "discard the local group copy at any time", but that is scoped to a *removed
member's own copy of that group*, never to a cross-group index of pubkeys.
Nothing prohibits the directory, so it remains a product choice — on that ground,
not the stated one. Cite the restructured tree when citing at all: MIP-00…MIP-05
are deprecated upstream and the normative surfaces are `foundation/`,
`protocol-core/`, `app-components/`, `features/`, `transports/`
(`MARMOT_PROTOCOL_KNOWLEDGE.md:70-85`).

**D4 — Auto-populate: yes, unconditionally.** The list renders as soon as the
picker opens. **No Privacy toggle** — the owner declined it; the feature is not
optional and does not gain a disable switch. **No circle is named at rest**; a
circle name appears only to break a display-name collision (§7.2). Android blocks
screenshots app-wide; **iOS blurs only the app-switcher preview**, and neither
covers accessibility scraping or Content Capture — disclosed in D6.

**D5 — Picture cache: capped at 50 people, LRU, test-enforced.** iOS backup
posture **unchanged** in this work, but recorded as its own gap (§14): the file
travels as ciphertext with a device-only key, so a restore to a *different*
device cannot open it, but a same-device restore can. The *reason* that is
acceptable changes when the payload becomes a named, photographed contact list,
so it deserves its own decision on its own timeline.

**D6 — Disclosure copy: ships with the feature.** One paragraph stating what is
kept, that it never leaves the device, and that it is erased after **3 days** —
with the number tied to the retention constant by a copy-tie test, so the two
cannot drift. Also states the Android Content Capture gap, the one exposure the
app cannot close itself. Translated into all thirteen locales as part of done,
with the independent per-language reviewer pass, not as a follow-up.

**[P4] D6 is CANCELLED, not deferred (updated 2026-08-29).** The Settings →
Privacy page and every `privacy*` string were REMOVED by owner directive, so
there is no overhaul to wait for and no disclosure paragraph is owed by this
plan. `privacyWhatOthersSeeMembersDirectory` exists in no ARB file and must not
be created; `INV-D-DIRECTORY-RETENTION-BOUNDED` carries empty
`disclosure_arb_keys`, which is a permitted state (`docs/privacy/README.md`).
The retention constant stays test-enforced on its own. The drafted paragraph
below is kept only as raw material should a future surface want it — it is not a
pending obligation, and nothing in CI checks it. A
drafted English value and its full `@`-description survive as a JSON fragment in
this session's scratchpad
(`.../scratchpad/DEFERRED_d6_directory_disclosure.json`) — **a session-scoped
temp file that does not survive a session restart**, which is why the drafted
paragraph itself is reproduced below rather than only cited:

> Haven keeps a list on this phone of the people you share a circle with, so you
> can add someone to another circle without typing their key again. An entry is a
> public key and the day you last shared a circle with that person — no name, no
> photo, and no record of which circle. The list lives in the same encrypted
> database as your circles and is never sent anywhere. An entry lasts as long as
> you share a circle with that person, and for up to three days after the last
> day you shared one; removing someone, or being removed by them, erases their
> entry at once. Nothing counts down in the background: an entry past its three
> days can no longer be shown to you, and it is erased no later than the next
> time you start the app or open the list of people to invite. Erasing an entry
> is not the same as forgetting the person — their cached name and photo, and
> this phone's encrypted record of every circle it has been in, are kept
> separately and stay until you delete your identity.

Six clauses, each load-bearing, each depending on something the overhaul must not
break:

1. **A row holds a public key and a day bucket and nothing else** —
   `INV-D-DIRECTORY-HOLDS-NO-CIRCLE-IDENTIFIER`. The picker *does* show a circle
   name in one case (`memberPickerCollisionCircleLabel`), but reads it from the
   user's current circles at display time, never from a stored row: keep the
   clause about what an ENTRY contains.
2. **"the same encrypted database as your circles"** is literal —
   `INV-D-DIRECTORY-NEVER-LEAVES-SQLCIPHER`, and the whole of the logout
   guarantee.
3. **"The list … is never sent anywhere" is scoped to the LIST and must stay
   scoped.** It must never widen into "nothing about these people leaves the
   phone", which is false: inviting fetches a KeyPackage from a relay, and typing
   an unknown key asks a relay to resolve it — disclosed where it happens, by
   `memberPickerStrangerLookupNote`.
4. **"up to three days" is `DIRECTORY_RETENTION_DAYS = 3`.** "Up to" is required
   and must survive translation — retention is measured from the START of the
   last day a circle was shared, so the window is at most three days and usually
   shorter. Never an exact timer, never a setting.
5. **"Nothing counts down in the background" is not hedging** — §14's
   three-on-demand-sweeps row. Translate so it is true of the STORED row as well
   as of what is displayed.
6. **The final sentence exists because everything above it would otherwise imply
   a forgetting the app does not perform** (§1.1): `delete_circle` never touches
   `profiles`/`profile_pictures`, and **the MLS group record is never deleted at
   all** — Haven calls no group delete, and at the pinned MDK rev the engine has
   no group-deletion path to call: `StorageProvider::delete_group` is never
   invoked from engine code and a left group's record is retained
   (`cgka-engine/src/engine.rs:200`). So the MLS store keeps the name and the
   full roster of every circle this device has joined until identity deletion.
   Do not drop this sentence and do not soften it into "some data may remain".

**What the deferral costs, precisely.** The copy-tie test that would pin the
wording to the constant is deferred with the copy, so **until the overhaul
nothing mechanically prevents `DIRECTORY_RETENTION_DAYS` and the eventual
paragraph from drifting.** The constant itself stays test-enforced
(`retention_is_the_owner_decided_three_days`,
`retention_ends_exactly_three_days_after_the_last_shared_day`); it is
specifically the copy→constant link that is absent. When the overhaul lands the
paragraph, `haven-core/tests/privacy_copy_ties.rs` gains the case in the same
commit — the drafted English keeps *"for up to three days after the last day you
shared one"* contiguous precisely so a substring match can find it — and
`INV-D-DIRECTORY-RETENTION-BOUNDED` gains its `disclosure_arb_keys` entry, which
it carries empty today for this reason.

**D7 — Invitation-card copy (owner, 2026-08-25).** Four decisions taken after
the review wave surfaced them:

1. **"New Circle" is replaced by a localized "Circle invitation" heading.** The
   card was rendering a hard-coded English literal as its largest element in all
   13 locales, because pre-join the real name is inside the encrypted Welcome.
   New key `invitationCardHeading`, translated per-language.
2. **The member count is removed entirely** — visible line, semantics
   placeholder, ARB key, and the dead field chain beneath it.
   `known_member_count` was a `const` returning **always 1** (the roster is
   encrypted pre-join), so "1 member" asserted something Haven cannot know. The
   screen-reader string was additionally not plural-aware, so it spoke "1
   members" — and since the count was always 1, that ungrammatical branch was
   the *only* one that ever fired, in every locale.
3. **The local nickname wins, and says so.** The card was the one surface not
   passing `localOverride` into `resolveEffectiveMemberName`, so a stranger's
   self-chosen kind-0 name overrode the user's own petname — the one name an
   attacker cannot forge losing to the one they picked, on the highest-stakes
   screen. Now marked with a discreet tag icon: achromatic (neither
   `HavenSecurityColors.encrypted` nor `warning` — both fail WCAG AA as text, and
   green already means "KeyPackage validated"), text-scaled, RTL-positioned, with
   a screen-reader label. New key `invitationCardNicknameNote`.
4. **All orphaned strings retired** — 16 keys × 13 locales (§3).

**Translation process:** one translator agent per language, then independent
per-language reviewers, per `CLAUDE.md`. That pass found the English source
itself is at fault in one place: *"invited by {inviter}"* hides a participle
agreeing with **the reader**, whose gender Haven cannot know. Spanish,
Portuguese, French, German and Persian each independently diagnosed it and each
independently replaced it with a "sent by" construction. **The English should
follow**, or five locales stay quietly diverged to repair a source-language
defect. Russian found a sharper variant: the obvious one-sentence repair lets an
`npub1…` value re-parse as a genitive attribute — heard as *"into npub1abc…'s
circle"* — smuggling an apparent circle identity into the one string that exists
to avoid naming one.

**D8 — iOS backup posture: ACCEPTED, no change (owner, 2026-08-28).** D5 held
this open deliberately: the posture was acceptable *while the payload was small*,
and that reason "changes when the payload becomes a named, photographed contact
list, so it deserves its own decision on its own timeline." P3 shipped that
payload. The trigger is met, the decision is taken, and it is **no change**.

**The posture, verified rather than assumed.** `circles.db` — which now carries
the member directory beside the circles, the cached kind-0 names and the profile
pictures — is opened at `<data dir>/circles.db` (`manager.rs:169`), and the data
dir is `getApplicationDocumentsDirectory()` + `/haven` with **no platform
branch** (`data_directory_provider.dart:44-47`; that file's own doc records the
iOS App-Group branch as still unwritten). On iOS that is `Documents/`, the
**most-backed-up location the OS offers**, and **`NSURLIsExcludedFromBackupKey`
appears nowhere in the tree** — not in `haven/ios/Runner/`, not in any Dart or
Rust path, not in a checked-in plugin. Android is unaffected:
`allowBackup="false"`, with no `dataExtractionRules` and no
`fullBackupContent` anywhere (`AndroidManifest.xml:48`). The asymmetry is real
and one-sided. What travels into the backup is ciphertext whose key is a
Keychain item marked `…ThisDeviceOnly` (deviation `IOS-KEYCHAIN`), so a restore
onto a **different** device cannot open it; a **same-device** restore can, and
that is the half that costs something.

**The consequence is a copy constraint, not a code one.** Logout and Delete
Identity destroy the directory by deleting the `circles.db` file set — the file
and its `-journal`/`-wal`/`-shm` sidecars, plus `session.sqlite` and both keyring
entries (`api.rs:877`, `:983-986`). A same-device restore reinstates a snapshot
taken *before* that deletion, so the destruction is **device-local, not
absolute**, and there is no reach-into-the-backup Haven could write. Registered
in `docs/privacy/privacy_invariants.json` as accepted deviation **`IOS-BACKUP`**,
whose `forbidden_claim` binds every future string: **no user-facing copy may say
that logging out or deleting your identity *irreversibly* destroys the on-device
directory**, or anything else living in `circles.db`. Today's copy survives that
test, but only just — `identityAdvancedDeleteBody` says "deletes your identity
and all circle data **from this phone**", which describes the act and claims no
permanence — and D6's closing sentence, the one that already refuses to imply a
forgetting the app does not perform, must not acquire one.

**`INV-D-DIRECTORY-NEVER-LEAVES-SQLCIPHER` stays `enforced`, deliberately.** What
that invariant checks is that the rows have **no second home** — no
`SharedPreferences`/`NSUserDefaults` entry, no secure-storage item, no sidecar
file, no second `Connection` — and a backup is not a second home Haven writes: it
is the OS copying the one home wholesale, still inside SQLCipher, still keyed by
a device-only Keychain item. The rows are never outside the encrypted container,
which is the claim as titled. Downgrading would report Haven's storage discipline
as partly enforced when it is not partly anything, and would spend the ratchet's
signal on the wrong event — the ratchet exists to catch the day a real second
home appears. What the backup falsifies is the *corollary* the statement had
appended, "deleting the file set destroys it" read as absolute; that corollary is
now scoped in the statement, and a `note` on the invariant carries the backup
case with the deviation named. `accepted_deviation` was not available either:
that status requires a disclosure (manifest rule 9) and the directory's
disclosure is D6, deferred — filing it would mean inventing a disclosure that
does not exist, which is exactly why deviation `P4` is referenced by no invariant
at all.

**D9 — Retention enforcement: ACCEPTED as three on-demand sweeps, no scheduler
(owner, 2026-08-28).** The three-day window is held by three runs of one
`DELETE … WHERE purge_after < ?1` (`storage_member_directory.rs:491-496`): at
every process start (`CircleManager::new` → `sweep_expired_directory_members`,
`manager.rs:172`, `:258-267`), inside the ranked read's own transaction *before*
it selects (`storage_member_directory.rs:341`), and at the tail of every
reconcile (`manager.rs:1573-1574`). **There is no timer and no background wake.**
Nothing in `maintenance_scheduler_provider.dart` names the directory; the one
hourly `Timer.periodic` (`map_shell.dart:676`) prunes last-known *locations*; and
the bare sweep has no FFI export a scheduler could call. The Android catch-up
worker and the iOS background path reach the startup sweep only because building
a `CircleManager` is something they already do.

A timer and a background wake were both considered and **declined**: they would
buy the earlier deletion of a row **nothing can read** — the read that would
return it purges first, in the same transaction — at the price of periodic
wakeups, on a battery budget this feature has no claim on.

**Two accepted consequences, both of which the eventual copy must survive.**
First, on a device where the app is never opened an expired row **outlives its
deadline on disk**, until the next process start, ranked read or reconcile —
whichever comes first. Second, all three sweeps compare against the **device wall
clock** with no monotonic floor anywhere in the path (`chrono::Utc::now()` at
startup; `DateTime.now()` marshalled through `nowUnixSecs` for the other two,
`nostr_circle_service.dart:1869,1882`; `ClockSkewDetector` is wired to location
publishing and names the directory nowhere), so a forward jump purges early and a
backward jump makes every sweep a no-op — expiry is not delayed but
**suspended**, and because the ranked read's sweep is that same comparison such a
row stays both stored *and* returnable. Irreducible without a trusted clock
(§14); accepted here rather than left open.

**D6's drafted paragraph was built for exactly this, and it is still accurate.**
Its two load-bearing sentences — *"Nothing counts down in the background"* and
*"it is erased no later than the next time you start the app or open the list of
people to invite"* — are true of **storage**, not merely of display; they name
the two triggers a user can actually cause; and they describe no countdown and no
timer. Nothing in D6 needs rewording on account of D9. **One caveat travels with
them and must not be lost:** both sentences are silently conditional on the clock
moving forward, because "past its three days" means real time to a reader and
device time to the code. Whoever writes the final copy inherits that, and may not
resolve it by promising a fixed wall-clock window — which is why §14 states the
clock residual as a *disclosure* dependency rather than a code one.

## 11. Phasing

| Phase | Content | New FFI | Req |
|---|---|---|---|
| ~~**P0**~~ | **DONE 2026-08-25.** Corrected fold + display sanitizer in `haven-core/src/directory/`; sanitizer wired at `write_profile_row` **and** `map_profile_row`; all **eight** npub sites unified on 12/6 behind `NpubValidator.shortenForDisplay`; `enableIMEPersonalizedLearning: false` on all seven text fields; autofill disabled at every field (six via `kNoAutofill`, the seventh a `TextFormField` already defaulting to `null` — §15); `foldForSearch` exported `#[frb(sync)]` (`rust_builder/src/api.rs:6098`) | `foldForSearch` ✅ | hardened |
| ~~**P1**~~ | **DONE.** Directory service + providers, current co-members. **No membership source was added** — §3's own [P1] correction stands: `status` was DELETED from Dart's `CircleMember` (`circle_service.dart:133-141`) rather than sourced. The batch cached read shipped as a concurrent Dart fan-out over the existing single-pubkey read (`NostrProfileService.getCachedMemberProfiles`, `nostr_profile_service.dart:282-319`), not the `get_cached_profiles(Vec<String>)` §3 floated | none | R2, R4 |
| ~~**P2**~~ | **DONE.** `member_search_bar.dart` deleted; `MemberSearchField` + `MemberPickerResults` (`widgets/circles/member_search_field.dart`, `member_picker.dart`) on both `create_circle_page.dart:97,139` and `add_member_page.dart:116,158`; ARB ×13 (7 `memberPicker*` keys in every locale); self-check fix via `selfNpub` (`create_circle_page.dart:193`) | no | R1 (cached) |
| ~~**P3**~~ | **DONE.** `member_directory` (`storage.rs`) + 3-day sync/purge, removal-deletes in **both** directions (§5.5), union gated on `ConvergedRoster` — **not** the "pending-ref-aware union" this row named, which §5.2 refuted — and **no wipe method**: logout is the `circles.db` file deletion (§6.1). Two things this row originally understated: the retention purge also runs **inside the ranked read**, so the window holds on an install that never reconciles; and the seven write sites include the two live-sync/catch-up ones §5.5's original list missed. **[P4]** the purge additionally runs at every process start, the schema is `WITHOUT ROWID` with `updated_day` removed, and the FFI row no longer carries a day bucket (§6.1) | `rankedDirectoryMembers`, `reconcileMemberDirectory` ✅ | R5 |
| **P4** | Typed-stranger resolve (D2). **The disclosure copy (D6) is CANCELLED** (2026-08-29) — the Settings → Privacy page and every `privacy*` string were removed by owner directive, so no paragraph is owed; the drafted text is kept in D6 as raw material only | no | R1 (strangers) |

Five phases, not six. **[R] P0 also needs a decision the draft fudged:** the
sanitizer is either Rust at the cache-write boundary (in which case the Dart
rendering sites need no change) or Dart. Pick one before P0 starts.

## 12. Test strategy

**Determinism.** Time is an `i64` parameter everywhere; retention asserted at
exact values (259 200 included / 259 201 excluded), never a band.

**[R] Cut the constructor-injected debounce `Duration`.** `testWidgets` already
runs in fake time, and the shipped precedent uses a private const with no
injection. The scheduler-load reasoning applies only to a real `Future.delayed`
outside the tester.

**[R] The stale-in-flight test** applies only to the D2 network resolve, not to
filtering.

**[R] The rank-order test doesn't test what it names** — a Rust proptest over the
sort is not a test of the rendered tree.

**[R] The wire-canary claim contradicts its own exception.** "No typed character
in any outbound frame" fails on D2's *correct* path, since a complete npub leaves
as hex. Re-scope to "no query string that is not a complete validated npub", and
have the checker bech32-decode before comparing.

**[R] Re-scope the closed-world claim** to "closed-world over Nostr relay frames;
open-world elsewhere." The IME dictionary, clipboard, Content Capture and any
HTTPS egress are outside the wire proxy and the network guard.

**[R] There was no `member_search_bar_test.dart` at all** — the widget being
rebuilt had no dedicated suite, and the E2E contract in §9.2 rested on behaviour
nothing unit-tested. **[P2] CLOSED:** the replacement widgets ship with
`test/widgets/circles/member_search_field_test.dart` and
`member_picker_test.dart`.

**[R] Missing UI states** the draft omitted: directory loading; directory read
failure (indistinguishable from "you know nobody"); `ValidationStatus.needsUpdate`;
per-row retry; `_isAdding` in-flight submit; and the page-level `_errorMessage`,
which is unreserved-height chrome between the list and the CTA.

**E2E:** with R3 cancelled, no new lane and no new relay topology is needed.
Extend the existing circle-flow assertions. Assert **content, not presence**:
the profile fetch returns a negative-cache row for an unresolved pubkey.

**[R] Drop the "~150 tests" figure.** Name the promises; let the count fall out.

## 13. CI guards

| Guard | Status |
|---|---|
| Kind-3 publish/read ban | **Keep the existing three mechanisms untouched.** With R3 cancelled nothing is added and nothing is loosened |
| Check 16 — picture URL in `api.rs` / bindings | **Keep.** Check 1 bans `Image.network` in Dart only; the no-URL contract in `api.rs` is a doc comment with nothing enforcing it. Extend to cover `about` |
| Directory retention + storage-location guard | **SHIPPED** as `scripts/ci/check_member_directory_privacy.sh` (1009 lines, five checks, hermetic `--self-test`), wired into `repo-guards.yml:583` + `:597` **[P3]** |
| `check_directory_logic_not_in_ffi.sh` | **Cut.** Not greppable in general; will false-red on refactors |
| Retention/copy parity | **Cut as a script; add a case to `haven-core/tests/privacy_copy_ties.rs`**, which already does exactly this (D6). **[P4] Deferred with the copy** — the case cannot be written against a string that does not exist, so the constant and the eventual wording are unlinked until the privacy-page overhaul lands both together (§14) |
| Check 7 extension | **Reframe** — D2 *loosens* Check 7; that is a design, not a tweak |
| `check_directory_plane_separation.sh` | **Cut entirely** — moot with R3 cancelled |

**Manifest:** `INV-D-SEARCH-QUERY-NEVER-LEAVES-DEVICE`,
`INV-D-DIRECTORY-HOLDS-NO-CIRCLE-IDENTIFIER`,
`INV-D-DIRECTORY-RETENTION-BOUNDED` (3 days),
`INV-D-DIRECTORY-NEVER-LEAVES-SQLCIPHER`.

**[P3] Three of the four were filed; the fourth was deliberately not.**
`docs/privacy/privacy_invariants.json` now carries
`INV-D-DIRECTORY-HOLDS-NO-CIRCLE-IDENTIFIER` (`:3164`) and
`INV-D-DIRECTORY-RETENTION-BOUNDED` (`:3202`) as **ratcheted**, and
`INV-D-DIRECTORY-NEVER-LEAVES-SQLCIPHER` (`:3248`) as **enforced**.

`INV-D-SEARCH-QUERY-NEVER-LEAVES-DEVICE` was **not filed, and must not be filed
under that name**: after D2 the claim is simply false — a complete validated npub
leaves as hex, which is the *correct* path. Its honest form is bounded twice
over: §12 already re-scoped egress to "closed-world over Nostr relay frames;
open-world elsewhere", and the residual it would then have to name is Android
Content Capture reading the rendered list, whose disclosure is **D6 — now
deferred with the privacy-page overhaul, not scheduled for P4**. So the invariant
is blocked on the copy that would make it true, not on an oversight, and stays
blocked for as long as the copy does. Filing a false invariant costs more than
filing none: the manifest is what the app's remaining user-facing claims are
checked against (the Privacy page it was originally written against was removed
on 2026-08-29).

**[P3] The five checks**, all of which run even after an earlier one fails:
(1) no circle/group/MLS identifier in any statement naming `member_directory`;
(2) exactly one writer and no companion table (including via a migration
`ALTER` a fresh `in_memory()` open never takes); (3a) the retention purge is
scheduled wherever the directory API is wired — an in-module test cannot see its
own caller; (3b) expiry is a `DELETE`, never a read-side filter; (4) no home
outside `circles.db` — no second `Connection`, file or keyring blob in Rust, no
`SharedPreferences`/secure storage/file write in Dart, and no native code naming
the table. **[P4] Check 4's Dart lane was widened**: filename convention alone
(`*member_director*`, `member_pick*`, `member_search*`) left `member_avatar.dart`,
`search_fold.dart`, `create_circle_page.dart` and `add_member_page.dart` outside
the scan, so a recent-searches cache or a staged-member draft written to
preferences from any of them passed silently. The surface is now the union of
that convention and the **import closure over a pinned seed set** (the row,
staged-pick and query-fold modules), which covers all four and covers a future
consumer whatever it is named. `member_directory_service.dart` is deliberately
NOT a seed: `service_providers.dart` imports it, and seeding on the app-wide DI
file would red this guard on an unrelated provider and blame the directory.
Three anti-vacuity floors — one per lane plus one on the union — plus a pinned
existence check on every seed, so a rename exits 2 instead of shrinking the scan.
The guard deliberately does NOT re-implement what
`storage_member_directory.rs`'s own `PRAGMA table_info` and retention tests
already pin. `check_directory_logic_not_in_ffi.sh` and
`check_directory_plane_separation.sh` were cut as planned and never written.

## 14. Known gaps

| Gap | Control |
|---|---|
| Locale-correct folding is impossible without a locale | Rules documented; each non-equivalence has a test asserting the *limitation*. Copy must not promise "finds any spelling" |
| ~~Stroke/ligature letters (`đ ø ł æ þ`) need an explicit table~~ — **CLOSED.** The table shipped (`haven-core/src/directory/fold.rs:68-82`): `æ→ae`, `ð đ→d`, `ħ→h`, `ı→i`, `ł→l`, `ø→o`, `œ→oe`, `ß→ss`, `þ→th`, `ŧ→t` — wider than the six the gap named, keyed on lowercase and applied AFTER the post-NFKD lowercase pass (§6.2's [P0] ordering) | Residual: the table is closed-world. A stroke or ligature letter outside it stays in the key — a search miss, never a wrong match. `fold_transliterates_stroke_and_ligature_letters` and `fold_transliterates_uppercase_stroke_letters_via_the_lowercase_table` pin what is covered |
| **The retention clock is untrusted in BOTH directions** — every sweep compares `purge_after` against the device wall clock (`chrono::Utc::now()` at process start; `DateTime.now()` marshalled through `nowUnixSecs` for the ranked read and the reconcile, `nostr_circle_service.dart:1869,1882`), and there is **no monotonic floor anywhere in the path** | Forward jump: purges EARLY — bounded, affects only recent contacts, self-healing for current members. **Backward jump is the mirror case and is worse for the promise.** `purge_expired` is `DELETE … WHERE purge_after < ?1`, so under a rolled-back clock the three sweeps still run and delete nothing; and because the ranked read's in-transaction sweep is that same comparison, a row past its window is both **still stored** and **still returned** for as long as the clock reads earlier than its deadline. Expiry is not delayed, it is suspended. Irreducible without a trusted clock — SQLCipher offers no monotonic counter and a boot-relative clock does not survive a reboot — so it is stated, not fixed. It is stated *here* because a disclosure that claims a fixed window (D6) depends on it. **Accepted alongside the enforcement model (D9, owner 2026-08-28)**, which takes both residuals in one decision: the eventual copy may not resolve this by promising a fixed wall-clock window |
| ~~**[P3] Retention is enforced on demand, not by a timer** — a device that neither opens the picker nor reconciles keeps expired rows **on disk** past three days~~ — **[P4] CLOSED.** `CircleManager::new` sweeps at every process start, the trigger an idle device still produces, at the cost of one indexed DELETE on a database open that already happens | **ACCEPTED, not open (D9, owner 2026-08-28)** — a timer and a background wake were both considered and declined: they buy the earlier deletion of a row nothing can read, at the price of periodic wakeups. Residual, and still a residual: three on-demand sweeps rather than a timer, so the row survives the interval between its deadline and the next process start, ranked read or reconcile — during which nothing can read it, because the read that would purges first. A device on which the app never runs at all keeps it until the app next runs. Note also that `sync_co_members` can mint an already-expired row: a departure noticed days late expires against the last day shared, not the day it was noticed — the conservative direction |
| `api.rs` logic is invisible to the coverage gate | Accept it, or measure `rust_builder` separately |
| Screen-reader *perception* is untestable | Emit-once is machine-checked; perception stays a manual pre-release item |
| Egress proof is closed-world only over Nostr relay frames | §12 |
| Day bucketing raises the re-partition cost, does not eliminate it | §6.1 |
| **iOS backup carries the encrypted DB** — **ACCEPTED, not open (D8, owner 2026-08-28)**; D5's trigger fired when the payload became a named, photographed contact list, and the decision taken was *no change* | Residual, and still a residual. `circles.db` sits under `getApplicationDocumentsDirectory()/haven` with no platform branch and **no `NSURLIsExcludedFromBackupKey` anywhere in the tree**, so it travels into every iOS backup; Android is unaffected (`allowBackup="false"`). Ciphertext + a `…ThisDeviceOnly` Keychain key means a different-device restore cannot open it — a **same-device restore can**, which makes the logout/Delete-Identity deletion device-local rather than absolute. Registered as accepted deviation **`IOS-BACKUP`** in `docs/privacy/privacy_invariants.json`; its `forbidden_claim` binds all future copy — nothing may say a logout or an identity deletion *irreversibly* destroys the directory. `INV-D-DIRECTORY-NEVER-LEAVES-SQLCIPHER` stays `enforced` and carries the reasoning in its `note` (D8) |
| **Android Content Capture reads on-screen text** | Cannot be closed by the app for this surface; disclosure deferred with D6 |
| **[P4] The D6 disclosure copy is CANCELLED (2026-08-29), and its copy-tie test with it** — the Settings → Privacy page and every `privacy*` string were removed by owner directive, so `privacyWhatOthersSeeMembersDirectory` exists in no ARB file, must not be created, and `haven-core/tests/privacy_copy_ties.rs` carries no member-directory case | **There is no copy for the constant to drift from; this is now a closed item, not a debt.** The constant stays test-enforced on its own (`retention_is_the_owner_decided_three_days`, `retention_ends_exactly_three_days_after_the_last_shared_day`); it is the copy→constant *link* that is absent, and only that. The drafted paragraph and its six load-bearing clauses are recorded in D6 so the overhaul does not rewrite it from scratch, and `INV-D-DIRECTORY-RETENTION-BOUNDED` carries empty `disclosure_arb_keys` for exactly this reason. Two constraints the honest copy must keep: the window is held by **three on-demand sweeps, not a scheduler** (**D9**, accepted 2026-08-28), so a row can outlive its deadline on disk until the next launch — during which no read can return it, because the read purges first; and the copy **must not claim Haven forgets who you shared a circle with** — Haven calls no group delete and the pinned MDK engine has none to call (`StorageProvider::delete_group` is never invoked from engine code; a left group's record is retained — `cgka-engine/src/engine.rs:200`), so the MLS store retains every circle's name and full roster until identity deletion |
| ~~**[P0] Devanagari matras are dropped by the fold**~~ — **FIXED.** The fold now drops a mark only where it is optional pointing (§6.2); `कमला`/`कमल`, `राम`/`रमा` and `ガンダム`/`ガンタム` are distinct keys again | Residual: hi/ne/ja get no folding at all beyond case + NFKD, and hiragana is **not** unified with katakana, so a Japanese user typing `たなか` will not find `タナカ`. That is a search MISS (retypeable), not a wrong match. Copy must not promise "finds any spelling" |
| **Kana script unification is not implemented** — the one-line `U+3041..3096 → +0x60` map that would make `だいすけ` ≡ `ダイスケ` | Deliberately out of scope: it reduces false negatives, whereas the fix above removed false positives. Raise as its own change if `ja` search quality is measured |
| **`fetch_my_profile`'s `get_profile(...).unwrap_or(cp)` fallback would render an unsanitized fetched row** | Unreachable — `upsert_profile_if_newer` and `touch_profiles_hit` both leave a row, so the `unwrap_or` never fires. Closing it properly means `upsert_profile_if_newer` returning the winning row, as `upsert_profile` now does |
| **[P0] Sync-bridge call not wall-clocked on a device** — no Android hardware available on the dev machine | Generated binding verified to return `String`, not `Future`, so there is no isolate hop by construction. Measure on a mid-range Android device before P1 locks the no-debounce design; the fallback is a one-line debounce |
| **[P0] `unicode-segmentation` MSRV asymmetry** — the crate declares MSRV 1.85.0 under a caret range; the coverage lane is pinned at rustc 1.97.1 while every other lane floats on stable | Ample headroom today. A future 1.x MSRV bump past the pin would redden the coverage lane *alone* — remember when bumping the pin |
| **[P0] Shipped binary-size delta unmeasured** — the new crate carries ~293 KB of Unicode 17 table *source* | Only the grapheme path is referenced; release LTO + `--gc-sections` should drop the rest. Measure with a release build if APK size becomes a concern |
| **[R] `has_pending_convergence_inputs` fails OPEN** — the only post-converge gate on this pin returns `false` for a row it cannot decode or project, and for `StorageError::NotFound` (§5.2) | `false` means "nothing *resolvable* is outstanding", not "clean slate". The skip count is a `tracing::debug!` aggregate inside the engine with no accessor, so Haven cannot observe it. Pair the gate with `is_stable` rather than trusting either alone; a directory row is cheap to withdraw (§5.2's delete-on-disappear rule) and that is the real backstop. **[P3]** Shipped exactly so: the pairing lives INSIDE `converged_member_pubkeys`, under one lock, and the predicate is never exposed on its own (§5.3) |
| **[R] `is_stable` false-positives on a solo create** — `projected_epoch = EpochId(0)` equals the stored epoch, and `create_group_with_retention` has no empty-member guard (§5.2) | Benign *for this feature*: a zero-invitee create projects a roster of one — the creator — so there is no peer pubkey a phantom row could be written from. It stops being benign for any caller that reads the gate as "no commit is in flight" |
| **[P3] A withdrawal verdict is lost across process death** — if the process dies between the engine durably rolling a commit back and the app draining `GroupStateInvalidated`, the `RewriteWithdrawing` verdict is gone, and a row that should have been deleted ages out over three days instead | **Not closable at this layer.** The re-hydration events that would carry the news — `PendingCommitRecovered` and `GroupHydrationRecovered` — fold to `GroupUpdate` (`nostr/mls/manager.rs:1215-1222`), which is also every ordinary departure, so promoting them to withdrawing would delete every departure the instant a device restarts and destroy R5 outright. A per-commit reaction is not buildable either: the fold strips `invalidated_commit_id` (§5.5). The backstop is the bounded retention window — three days, not forever |
| **[R] A short roster is undetectable at read time** — the `filter_map` drop happens at write time and no `Result` carries it (§5.4) | Closed upstream, not locally: every ingress seam validates all member credentials and quarantines on failure. The checkable form is *a group either hydrates fully or appears in `quarantined_groups()`* — assert that, and never treat `marmot_members` as the validator |

## 15. Doc bugs found while planning

- **`CLAUDE.md:117`** states `cargo clippy -- -D warnings`; CI runs
  **`--all-targets`** (`rust-check.yml:54`, `:112`, `:179`). The bare form lints
  lib/bins only and once left 123 findings unlinted.
- **[R] `CLAUDE.md:270` cites `docs/FLUTTER_RUST_BRIDGE.md`, which does not
  exist.**
- **[R] Upstream MDK `traits/src/group.rs:51`** documents `id` as the
  *"signature public key"*. **[R]** The code it contradicts is not three lines
  below (54-57 are bare field declarations) but in another crate —
  `cgka-engine/src/group_lifecycle.rs:946-951`. Worth a code comment where Haven
  reads `m.id`.
- **[P0] `haven-core/SECURITY.md:13-18` says "None currently open"**, and states
  that non-blocking advisories are "justified individually in
  `haven-core/.cargo/audit.toml`". **Eight advisories appear in neither place.**
  They pass CI only because `cargo-audit` treats informational advisories as
  non-fatal by default — not because anyone assessed them. Six post-date the last
  curation. The one to look at first is **RUSTSEC-2026-0243: `nostr-relay-pool`
  declared unmaintained on 2026-08-03** — the crate Haven's entire relay plane
  runs on. Pre-existing and unrelated to this feature, but a real gap against the
  documentation-accuracy pillar.
- **[P0] `autofillHints` does not default to `null`** — Flutter's default is
  `const <String>[]`, and only `null` yields `AutofillConfiguration.disabled`.
  With the default, a field's *current editing value* is handed to the platform
  autofill service, and `obscureText: true` does not gate it. **[P0] CLOSED, and
  wider than the two fields this bullet credited.** Six fields now pass the named
  constant `kNoAutofill` (`= null`, `constants/text_input_privacy.dart:25`):
  nsec import (`:125`), relay URL (`add_relay_sheet.dart:196`), display name
  (`create_identity_screen.dart:346`, `display_name_card.dart:303`), member
  search (`member_search_field.dart:136`) and member petname
  (`member_detail_sheet.dart:271`). The seventh — circle name
  (`name_circle_page.dart:117`) — is a `TextFormField`, whose own default is
  already `null`, and passing the constant there is flagged redundant. **No
  field carries the framework default any more.**
