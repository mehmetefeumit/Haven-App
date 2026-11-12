# Own-profile editing: local-first outbox + honest sync (design record)

**Status: SHIPPED 2026-08-22; write path and coverage SUPERSEDED 2026-11-10
(instant save).** Supersedes the write-path section of
`PUBLIC_PROFILE_MIGRATION_PLAN.md`. Read paths and privacy boundaries described
there are unchanged; the photo removal's retraction gate moved into the sync
(below), the deletion's stayed where it was.

## Why

Before this change a display-name save ran, on the tap: a *serial* merge-base
read across all 8 profile-pool relays (≤25 s), then a publish that waited for
OK-acks from *every* relay under one 10 s timeout that discarded partial acks,
× 3 attempts + 2 × 2 s backoff (≤49 s) — on a brand-new cold WebSocket client
each time. Photo saves added synchronous Lanczos image processing on the async
worker and a 30 s-budget Blossom upload in front. The save button stayed
disabled for the whole duration (worst ≈ 74 s / ≈ 104 s; typical 5–15 s), and a
name save disabled the photo controls through a shared loading flag.

The 2026-08-22 shape left three things the owner asked to be gone on
2026-11-10: a visible sync status ("Syncing…", "Published — still syncing to
some relays", a Retry button), a photo removal that was still a synchronous
retraction with a spinner (1–2 s typical, ≤ ~29 s), and a partial-coverage
retry that signed a NEW kind-0 for the WHOLE pool on every pass, forever —
every relay that took a pass held a new public `created_at`, a mark of when
the app was opened.

## What it is now

The White Noise pattern (local-first save, background publish) with the one
thing White Noise lacks: the UI never claims network success it did not get.
The principle that reconciles that with "no hint of background work": **the UI
claims device truth only.** "Saved", "Photo updated" and "Photo removed."
assert that the device holds the edit and will publish it; no screen renders a
relay outcome as a state of the profile. The durable outbox, the honesty of the
*internal* state, and "complete = every usable pool relay serves it" all stay.

```
save / photo / remove tap ──► stage locally (ms): row rewritten, outbox row,
        │                     local_version+1, ladder reset, owed event dropped
        │                     (a removal also drops staged AND published bytes)
        ▼  UI live at once; nothing on screen says synced, syncing or failed
sync_own_profile(own_pk, keys?, clock)
        │   (idempotent, serialized under profile_sync_lock; gate read
        │    `has_published_profile` before any footprint; `keys` is None for
        │    a pass with nothing saved, which signs nothing)
        ├─ nothing saved, no owed event, pool coverage settled ──► NothingPending,
        │      no relay client built
        ├─ owed event for local_version?  ── yes ──► RE-SEND PASS
        │      offer the IDENTICAL signed kind-0 only to uncovered(pool, covered)
        │      read back each relay that answered: Holds ⇒ covered,
        │      Newer ⇒ cache it, drop the debt, fall through to ONE full pass,
        │      Lacks / not drained ⇒ still owed (timestamp refusal + Lacks ⇒
        │      one fresh signing per edit, then owed)
        │      commit_profile_coverage: covered ⊇ pool ⇒ clean; else ladder
        │      (with nothing saved a refused copy is never signed afresh)
        ├─ nothing saved, pool coverage owed ──► COVERAGE PASS (no key, no signing)
        │      read_own_per_relay over the WHOLE pool; act only on a whole read
        │      (every relay ended its answer or serves the newest copy), else
        │      ladder: a silent relay may hold a newer copy — a blank that
        │      retracted the one in hand
        │      no relay serves a profile ⇒ settle, publish nothing
        │      newest copy older than the dated own row ⇒ settle, offer nothing
        │      else offer the IDENTICAL served kind-0 to the relays that
        │      answered without it, read back (an OK is no coverage);
        │      all covered ⇒ covered_pool = pool; else the copy is the owed
        │      event at the unchanged version, ladder advanced
        └─ a save is pending ──► FULL PASS
               Blossom upload of staged picture  ∥  read_own_profile_on_relays
               (every pool relay at once, ≤ 5 s connect + 4 s REQ each)
               cache the newest copy if newer than the row
               nothing saved to publish (a clear alone / an owed blank)?
                 retraction_gate ⇒ Publish | Settle (level locally, send nothing)
                                           | Hold (stay on the ladder)
               upload failed with text or a clear pending ⇒ publish text-only
               merge_base → merge_edits → sign ONE kind-0 → offer_metadata to
               EVERY pool relay, each sent as soon as its own connect succeeds
               commit_profile_sync: every relay ⇒ clean; ≥1 ack ⇒ pending with
               the event + covered set as the owed event, ladder advanced;
               0 acks ⇒ pending, ladder advanced, nothing owed (signs fresh)
```

Triggers: `sync()` after every local save, photo and removal (unconditional; a
fresh edit resets the ladder); `retryIfPending()` on cold start, on app resume
and from ONE foreground timer armed to the ladder's relative due time
(`next_retry_in_secs`) — only while the outbox is pending, the backoff is not
yet due and the app is `resumed`; it is cancelled on pause/hide/detach and on
an identity-scope reset, re-armed on resume, and never armed from a pass that
left the state due — except once per failure streak, 30 s after a pass that
THREW before any attempt was recorded, which would otherwise wait for the next
resume. "Pending" here is `CircleManager::profile_pending_state`: a save to
publish, OR pool coverage owed (below), so the same drivers run a coverage
pass with no Dart of their own. While a sync is in flight another trigger
neither starts nor queues one. Never from the background isolates.

### Key pieces

| Layer | Where | Role |
|---|---|---|
| Pure outbox logic | `haven-core/src/profile/outbox.rs` | `PendingEdits` (sparse, accumulating; `clear_picture` + `clear_version` + the once-per-edit `resigned` marker ride in `edits_json`, no column), `merge_base` (the fetched row is the base unless it is older than the local one — a superseded copy a relay replays is not built on; local row also on a total read miss; `created_at` floor = max(fetched, local)), `served_against` (a relay's served kind-0s against ours by `(created_at, lower id)`: `Holds` / `Newer` / `Lacks`), `uncovered` (parsed-URL set difference, pool order), `owed_event_from_json` (`verify()` + own pubkey + kind 0 on load) |
| Own read | `haven-core/src/profile/fetch.rs::read_own_profile_on_relays` on `read_own_per_relay` | every pool relay at once, each bounded by its own connect + `PROFILE_AUTHOR_FETCH_TIMEOUT` (together `PROFILE_OWN_READ_BOUND`, 9 s); events served before a missed `EOSE` are kept; `newest_own_copy` resolves across relays (newest `created_at`, lower id on a tie); `Published / Absent / Unverified` |
| Profile-plane offer | `haven-core/src/relay/manager.rs::offer_profile_event` (`offer_metadata` in `profile/publish.rs`) | per relay concurrently: connect, then `send_event` under `PROFILE_PUBLISH_ACK_TIMEOUT`; a failed connect is `Unanswered`, never sent; ONE attempt, the full harvest returned even with no ack; `publish_profile_event` (2 attempts / 1 s backoff) stays for the deletion; location path untouched |
| Retraction gate | `haven-core/src/profile/consent.rs::retraction_gate` | pure: `(published_here, OwnReadVerdict, local_dated) → Publish / Settle / Hold`; evaluated in `sync_own_profile` on what the pass will ACTUALLY publish |
| Durable outbox + ledger | `haven-core/src/circle/storage_profile_sync.rs` | `profile_sync_state` (local / synced / published versions, sparse `edits_json`, `picture_staged`, `sync_attempts`, `next_retry_at`, and `covered_pool_json` — the usable pool coverage was last settled against, NULL until it has been; added to an existing database by one guarded `ALTER`) and `profile_publish_debt` (`pubkey, version, event_json, covered_json`; `CREATE TABLE IF NOT EXISTS`, no migration); `profile_coverage_owed`, `settle_profile_coverage`, `owe_profile_coverage`, `record_profile_coverage_attempt` (each a compare-and-set on "this version, nothing pending", and each creates the row an install that saved nothing lacks, so its ladder has somewhere to advance); `stage_own_picture_removal`, `commit_profile_sync`, `profile_publish_debt` + `commit_profile_coverage`, `discard_profile_publish_debt`, `settle_profile_sync`; every commit is one transaction with a compare-and-set |
| Orchestration | `haven-core/src/circle/profile_sync.rs::sync_own_profile` | holds `profile_sync_lock`; takes a clock so the backoff is dated at pass END; outcomes, never `Err`, for upload/publish failures; `ProfileSyncReport { outcome, still_pending }` (no counts; `still_pending` counts owed coverage); every `offer_metadata` and the upload stay in its own body (guard check 6), the coverage decision in `judge_coverage` / `close_coverage` |
| Sealed upload type | `haven-core/src/avatar/image.rs::StagedPicture` | only the sanitizer (or cache rehydration, which recomputes the hash) can mint bytes that reach Blossom |
| FFI | `haven/rust_builder/src/api.rs` | `save_my_profile_local`, `save_my_profile_picture_local`, `remove_my_profile_picture` (no secret, no lock, no relay: `stage_own_picture_removal`, returns the stored row), `sync_my_profile` (pending + pool pre-checks before any key is built, and a key is built only when a save is pending — a coverage pass never touches the secret; clock = `profile_now_secs`), `profile_pending_state` (`pending`, `retry_due`, `next_retry_in_secs: Option<u32>` — relative, ≤ the longest rung, never an instant); `delete_my_public_profile` keeps its own gate and lock; `get_cached_profile` is async |
| Flutter | `providers/profile_sync_provider.dart` | one stateless coalescing `OwnProfileSyncController` (`Notifier<void>`, identity-scoped, non-autoDispose, absent from background isolates): `sync()` unconditional, `retryIfPending()` due-gated, the one foreground timer, a bare `WidgetsBindingObserver` that cancels it off-`resumed` and calls `retryIfPending()` on resume. No widget, no status, no Retry |

## Invariants this design adds (all CI- or test-pinned)

- A local save, photo or removal publishes nothing; only a sync does
  (relay-side event count). The removal is one SQLCipher transaction with no
  lock, no secret and no network: staged and published bytes deleted,
  `picture` cleared on the row, `clear_picture` staged with `clear_version` =
  the new `local_version`, ladder reset, owed event dropped.
- The outbox marker clears only for the version actually published, and fully
  only when every usable pool relay serves it (`stage v1, stage v2, commit v1
  ⇒ still pending`).
- **The owed event.** `profile_publish_debt` holds a row only for a COMPLETE
  signed event (every pending item at `version == local_version`) that at
  least one relay acknowledged, with the relays known to serve it. Every
  staging call (text, picture, removal), the reset and a redirect delete it in
  the same transaction, so a stale re-send can never put a superseded or
  deleted profile back on a relay that missed the later event. It is
  `verify()`-ed on load and dropped if the cached own row is newer than it (a
  fetch cached another client's copy). A re-send goes only to
  `uncovered(pool, covered)`; the OK of a re-send is ignored for coverage —
  only a read-back that serves our id (`Holds`) covers a relay; `Newer`
  redirects (cache, drop the debt, one full pass in the same call, never a
  second); `Lacks` or an unfinished answer keeps it owed. Complete =
  `covered ⊇ usable pool`, so a relay that leaves the pool (retired,
  contaminated, removed by the user) ends its debt at the next pass with no
  network.
- **The covered pool.** "Every usable pool relay serves it" is true of the
  pool as it was. `covered_pool_json` records that pool; coverage is OWED when
  none is recorded (an upgraded install, a storage reset, an identity that
  saved nothing) or the usable pool has a relay it lacks (a release swapped
  pool relays, the user added one). A pool that only shrank owes nothing, an
  underflowed pool owes nothing, and a RETRACTED profile owes nothing: the
  reset a deletion makes (`reset_profile_sync_rows`, which creates the row an
  account that never saved lacks) records "no pool owed" in place of a pool,
  so neither a blank nor — when the deletion could not be verified — the very
  profile the user asked to delete is re-sent to a relay that joins, until
  the next save settles a pool of its own. A coverage pass re-sends the newest own
  kind-0 the pool serves, byte for byte, to the relays that answered without
  it: it never signs, never takes a key, never makes a first public event (no
  relay serves one ⇒ settled with nothing sent), and never acts on a partial
  read or on a copy older than the dated own row — either could put a
  retracted profile on a relay that never had it. Its records are keyed to the
  version it started from, so a save made while it is on the network keeps its
  own owed event and its own ladder. A relay that refuses the served copy as
  too old stays owed on the ladder; nothing is re-dated for it. This is what
  the 2026-10-31 pool swap needed and did not have: profiles saved before it
  stayed on four of the eight relays, and a peer whose two assigned relays
  were both new ones could never resolve them.
- A timestamp-classified refusal of the owed event (prefix only; the text is
  never logged) with a `Lacks` read-back earns ONE fresh signing per edit
  (`resigned`, reset by every staging call); a relay that refuses the fresh
  event too simply stays owed on the ladder and can never force a new event
  onto the healthy relays every pass.
- **What clears a pending removal.** Staging a new photo does NOT reset the
  clear; an uploaded URL wins over it in `to_edits`. Every commit at least one
  relay acknowledged — complete, partial, text-only fallback, coverage —
  clears `clear_picture` iff its version ≥ `clear_version` (by construction
  such an event carried `picture ""` or a URL), inside that commit's
  transaction, BEFORE the own row is rewritten from the event plus what is
  still pending. A removal staged after a new photo gets a newer
  `clear_version` and is still published; a partially published photo clears
  the earlier removal and keeps its URL on the row; no later pass publishes
  `picture ""` after a URL was published. `settle_profile_sync` never levels
  a version with a staged photo.
- **The gate lives where the publish is.** `sync_own_profile` reads
  `has_published_profile` under the lock before any footprint. A pending set
  with saved content (a text edit, a staged picture) publishes
  unconditionally; one carrying nothing saved (a clear alone, an owed blank)
  goes through `retraction_gate`, evaluated after the upload outcome is known:
  Publish (a relay copy was found, or published here with a dated row), Settle
  (never published and every relay answered Absent — leveled locally, nothing
  sent, never a version with a staged photo), Hold (unanswered, or nothing to
  build on — stays on the ladder; the old fail-closed, kept). The removal must
  not read the gate itself: a tap-time read outside the lock could find "never
  published" while a first publish is in flight and stage nothing, and that
  publish would commit the photo as synced; always staging the clear closes it
  (the in-flight commit's CAS fails on the moved `local_version`, its
  `published_events` row arms the gate truthfully, the next pass publishes the
  clear). `delete_my_public_profile` keeps its own lock, gate and
  `PROFILE_RETRACTION_UNVERIFIED` fail-closed in `api.rs`.
- The deletion's blank goes into the same ledger: `wipe_all_profiles` records
  the blank's publication, dates the own row from it, and — when `covered`
  does not cover the pool — owes it (`write_unqueued_publish_owed`) and writes
  the debt row in the wipe's own transaction, so the retry re-sends the
  identical blank; the kind-5 targets the id actually last published.
- The copy a pass reads for its base is cached when it is newer than the row,
  BEFORE the publish: a publish that fails still leaves the row at the newest
  copy read, so the retry cannot build on an older one another relay serves
  (`a_newer_copy_read_for_a_publish_that_failed_is_what_the_retry_builds_on`);
  a redirect caches the newer copy before it discards the debt, so the rebuild's
  floor includes it even if that relay does not answer the second read.
- An upload failure no longer aborts the pass: a pending text edit or clear
  publishes with the picture untouched (`to_edits(None)`), commits as
  not-complete (no debt row; `picture_staged` and the edits kept; ladder
  advanced). A successful commit re-stamps the staged picture row only
  `WHERE sha256 = ?` of the uploaded bytes, so a photo picked mid-upload never
  receives the previous photo's URL.
- Staging never arms the retraction gate (picture rows with an empty URL do not
  count) and never disarms it (a seen kind-0 with `event_created_at > 0` counts).
- Everything uploaded went through `process_own_avatar` (private fields on
  `StagedPicture`; guard check on constructors and staging call sites).
- `profile_sync_state` rows are reset in place, never deleted (version reuse
  would let a stale sync clear a newer marker).
- Retries honour the persisted ladder; the foreground timer arms only when
  pending, not due and `resumed`, never from a pass that left the state due;
  no unconditional network call on start/resume; no profile-sync symbol in the
  background isolates. The backoff is dated at pass end (a slow upload cannot
  come back already due); a clock moved back past the longest rung reads as
  due (one retry, never a loop).
- Guard (`check_profile_privacy_boundaries.sh`): `sync_own_profile` is the
  allowlisted fn whose publish may carry no saved content, with the gate read
  bound lexically before the first footprint and the lock before the gate in
  its OWN body; an allowlisted fn with no footprint in its body is a failure;
  every footprint token (`offer_metadata`, `offer_profile_event`,
  `publish_profile_event`) in `profile_sync.rs` sits inside an allowlisted body;
  `remove_my_profile_picture` is held local (no footprint, no
  `RelayManager::new`, no secret, no lock).
- No relay URL, event id, pubkey, instant or relay prose reaches a log
  (`a_resend_and_a_redirect_log_no_relay_url_event_id_or_pubkey`,
  `a_profile_offer_logs_counts_only`,
  `an_owed_event_that_does_not_verify_is_discarded_and_its_line_names_nothing`);
  the report and the FFI state carry no counts and no instants.
- The supplied identity secret must match the manager's construction identity.

## Deliberately rejected (do not re-add)

- **Persistent profile-plane relay client** — 8 always-open sockets would make
  the low-signal plane a continuous presence beacon.
- **First-ack early return with detached stragglers** — per-relay bounds already
  cap the fan-out; returning early would abandon the sends that let peers (who
  each read from their own salted top-2) resolve the profile.
- **Splitting the retraction functions out of `api.rs`** — the CI guard binds
  the consent gate to the first publish-footprint call in the *same* function
  body; a wrapper would silently un-bind it. *Superseded in form 2026-11-10
  (OD-R2): the removal's publish moved into `sync_own_profile`, and the guard
  now binds more tightly than before — an allowlisted fn with no footprint in
  its own body fails, and every footprint token in `profile_sync.rs` must sit
  inside an allowlisted body — so the reason for the rejection is closed, not
  waived. The deletion stays in `api.rs`.*
- **"Discard pending edit" action** — would create a path to a never-published
  profile, contradicting the owner's publish-unconditionally directive; editing
  again is the cancel.
- **Taking the sync lock inside the local-save path** — it would serialize
  instant saves behind a background sync (the regression this work removes) to
  close a window that needs a whole-profile delete concurrent with a rename.
- **A lock, a secret or a network read in the removal path** — the removal is
  a save; the gate it used to read at tap time is read by the sync, under the
  lock, on what the pass will actually publish.
- **A new event per retry pass** — a new `created_at` and id on every relay
  that takes a pass is a public mark of when the app was opened; the one
  signed event is re-sent instead.
- **Reading the OK string as coverage** — nostr-rs-relay and khatru answer OK
  true to an OLDER replaceable, strfry answers OK false with a non-standard
  prefix; an ack after a re-send proves only that the relay judged it.
  Coverage is a read-back ordered by `(created_at, lowest id)`.
- **Reading healthy relays before a re-send** — a round trip to every relay,
  dead ones included, that still could not prove the send took. The send is
  what should land; the read-back follows it, and only to relays that
  answered the offer.
- **A cap on a relay that never serves the event** (OD-R1) — the cost is one
  dial, one EVENT and at most one REQ to that relay alone, foreground only, on
  the 6 h rung; a cap would make "complete" untrue for that relay's readers.
- **A `staged_picture_url` column** — a Blossom re-upload of the same bytes is
  idempotent (BUD-02: 200 for an existing blob); the rare repeat is one PUT to
  a host that already saw the hash, and a persisted URL could name a blob the
  server has since collected.
- **Skipping the read on a "first" publish** — an imported nsec has no local
  trace of another client's fields; **starting the publish before every relay
  answered the read** — a slow relay may hold the newest copy, and the
  per-relay bound is already the floor.
- **A visible sync status line** (and its Retry) — it rendered a relay outcome
  as a state of the profile; the Identity page renders identically in every
  publish state.
- **A connectivity-package trigger** — link state is not reachability; it
  would fire outside the ladder; a new dependency not justified.
- **A timer that arms from a pass that left the state due** — a tight loop.
  The one bounded exception is a pass that THREW before an attempt was
  recorded: a single 30 s fallback per failure streak (reset by a pass that
  completes, and by a resume), so a persistent local fault costs one retry,
  not one every 30 s.
- **Signing afresh in a coverage pass** — re-dating the copy the pool serves
  would publish, under a new `created_at`, a profile the user did not save
  now; the pass re-sends the bytes that are already public or nothing.
- **Acting on a partial read in a coverage pass** — the relays that did not
  answer may hold a blank or a rename newer than the copy in hand; re-sending
  the older one would put a retracted profile on every relay that lacks it.
- **Marking the pool covered without reading it** (a migration backfill) —
  nothing recorded which relays an earlier build's publish reached, and the
  2026-10-31 swap proves the answer was "not all of today's".

## Accepted costs

- On a *total* merge-base read miss the local row is the base: a field another
  client **added** since our last fetch is lost and a field it **changed** is
  reverted. Requires every pool relay to fail the read; accepted so offline
  edits are never stranded (pinned by test so nobody "fixes" it into deferral).
- **Resolved 2026-11-10 (was the open owner decision).** A partial-coverage
  publish — a save's, a removal's or a deletion's blank — re-sends the ONE
  signed event only to the relays that do not yet serve it, confirms by
  reading each answering relay back, and is redirected onto a newer copy
  another client wrote. On the ladder that is at most four passes in the
  first hour and then at most one per six hours, with **no cap** (OD-R1)
  while one usable pool relay never serves it: one dial, one EVENT and at
  most one REQ to that relay alone per pass, foreground only, no new
  `created_at`; healthy relays see no connection and no frame. The debt ends
  when every relay of the usable pool serves it, when the relay that never
  does leaves the pool, or when a later save, removal, deletion or redirect
  supersedes it.
- A coverage pass costs one single-author `REQ` for the own pubkey to every
  usable pool relay — what a save's merge-base read already shows them — once
  per install after this lands, and again when the usable pool gains a relay.
  While some relay does not answer it repeats on the ladder (the 6 h rung at
  most, foreground only), reading the whole pool each time until one read is
  whole; once a copy is owed, only the relays that lack it are dialled. A
  relay that never takes the served copy (it refuses old timestamps) stays
  owed indefinitely, as OD-R1 already accepts for a save.
- **Not built, owner's call:** a relay that takes the profile and drops it
  LATER is not detected — the one read after upgrade catches a drop that
  already happened, and nothing re-reads a settled pool. Closing that needs a
  periodic pool-wide read, which is a standing cadence signal to eight relays.
- An offline removal is instant on the device while the photo stays public
  until the next pass lands — the same window every other edit has (OD-F3);
  the confirm dialog's disclosure that the image file stays on the server is
  unchanged.
- In the SIGNING pass a relay's OK counts as covered without a read-back; a
  relay that held a newer copy AND did not answer that pass's read is
  believed covered until the next edit (needs both on one relay).
- A pass no relay acknowledged records nothing and signs fresh next time (no
  metadata cost: no relay saw the earlier event).
- During a Blossom outage each rung signs a text-only event while the picture
  stays staged: peers see the new name (and a pending removal) with the old
  photo until Blossom recovers.
- One timestamp re-sign per edit; a relay that refuses that one too stays
  owed, with no further re-sign.
- Each re-send pass costs one own-profile REQ per owed relay that answered the
  offer (never a covered relay, never a silent one).
- Location-plane `try_publish_once` still discards partial acks under its outer
  timeout — a separate follow-up (`publish_before_apply_send_e2e.rs` is its
  proving ground).
