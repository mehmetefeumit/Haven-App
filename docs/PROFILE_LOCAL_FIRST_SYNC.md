# Own-profile editing: local-first outbox + honest sync (design record)

**Status: SHIPPED 2026-08-22.** Supersedes the write-path section of
`PUBLIC_PROFILE_MIGRATION_PLAN.md`. Read paths, privacy boundaries and the
retraction gates described there are unchanged.

## Why

Before this change a display-name save ran, on the tap: a *serial* merge-base
read across all 8 profile-pool relays (≤25 s), then a publish that waited for
OK-acks from *every* relay under one 10 s timeout that discarded partial acks,
× 3 attempts + 2 × 2 s backoff (≤49 s) — on a brand-new cold WebSocket client
each time. Photo saves added synchronous Lanczos image processing on the async
worker and a 30 s-budget Blossom upload in front. The save button stayed
disabled for the whole duration (worst ≈ 74 s / ≈ 104 s; typical 5–15 s), and a
name save disabled the photo controls through a shared loading flag.

## What it is now

The White Noise pattern (local-first save, background publish) with the one
thing White Noise lacks: the UI never claims network success it did not get.

```
save tap ──► stage edit locally (ms) ──► UI live again, status line: "Syncing…"
                  │  durable outbox row (SQLCipher profile_sync_state)
                  ▼
          sync_own_profile (idempotent, serialized)
            ├─ Blossom upload of staged picture  ∥  concurrent whole-pool
            │                                       merge-base read (12 s budget)
            ├─ merge_base → merge_edits → sign kind-0 → publish to EVERY pool
            │  relay concurrently, each send bounded (6 s ack), ALL acks kept
            └─ commit: full-pool ack ⇒ "synced"; ≥1 ack ⇒ "published, partial"
               (stays pending; re-published opportunistically with persisted
               exponential backoff); 0 acks ⇒ "failed" + Retry
```

Triggers: after every local save, on cold start and on app resume (only when
the outbox is pending **and** the backoff says it is due), and the Retry
button (bypasses backoff; shown only in the failed state). A photo removal is
followed by a re-read of the status through the same due-gated entry
(`triggerProfileSyncRetry`): it publishes only what is pending and due, and
while a sync is in flight it neither starts nor queues another. Never from the
background isolates.

### Key pieces

| Layer | Where | Role |
|---|---|---|
| Pure outbox logic | `haven-core/src/profile/outbox.rs` | `PendingEdits` (sparse, accumulating), `merge_base` (the fetched row is the base unless it is older than the local one — a superseded copy a relay replays is not built on; local row also on a total read miss; `created_at` floor = max(fetched, local)) |
| Concurrent own read | `haven-core/src/profile/fetch.rs::fetch_own_profile` | whole pool, `buffer_unordered(PROFILE_MAX_INFLIGHT_RELAYS)`, `PROFILE_OWN_FETCH_BUDGET`; the answers are resolved together (newest `created_at`, lower id on a tie) |
| Profile-plane publish | `haven-core/src/relay/manager.rs::publish_profile_event` | per-relay `send_event` under `PROFILE_PUBLISH_ACK_TIMEOUT`; no outer timeout; 2 attempts / 1 s backoff; location path untouched |
| Durable outbox | `haven-core/src/circle/storage_profile_sync.rs` | `profile_sync_state` (local / synced / published versions, sparse `edits_json`, `picture_staged`, `sync_attempts`, `next_retry_at`); commit is one transaction with a compare-and-set clear |
| Orchestration | `haven-core/src/circle/profile_sync.rs::sync_own_profile` | holds `profile_sync_lock`; outcomes, never `Err`, for upload/publish failures |
| Sealed upload type | `haven-core/src/avatar/image.rs::StagedPicture` | only the sanitizer (or cache rehydration, which recomputes the hash) can mint bytes that reach Blossom |
| FFI | `haven/rust_builder/src/api.rs` | `save_my_profile_local`, `save_my_profile_picture_local`, `sync_my_profile` (pending + pool pre-checks before any key is built), `profile_pending_state`; `get_cached_profile` is async |
| Flutter | `providers/profile_sync_provider.dart`, `widgets/identity/profile_sync_status_line.dart` | one coalescing controller (unknown / syncing / partial / synced / failed), one status line at page scope, live region announces transitions only |

## Invariants this design adds (all CI- or test-pinned)

- A local save publishes nothing; only a sync does (relay-side event count).
- The outbox marker clears only for the version actually acked, and fully only
  on a full-pool ack (`stage v1, stage v2, commit v1 ⇒ still pending`).
- `delete_my_public_profile` / `remove_my_profile_picture` hold the sync lock
  **before** reading the retraction gate (guard-checked), so an in-flight sync
  cannot resurrect retracted data; their cancels are narrow (removing a photo
  keeps a pending name edit — unless the removal is built on the cached row,
  which already carries the name: it is then published with the removal and
  the outbox records it as published, in the commit's own transaction). The
  gate and the base come from ONE read of the pool, and a removal with no
  relay copy and no dated row publishes nothing. A deletion leaves the dated
  record of the blank it published as the own row — written with the record
  of the publish in one transaction — so a relay that still serves the
  deleted profile is neither cached again nor built on. A photo saved while a
  removal runs is neither settled nor deleted by it, and a name the removal
  did not publish — queued before it, or saved while it was being published
  — stays queued and stays on the row.
- A photo removal some pool relay did not acknowledge is never recorded as
  synced: that relay still serves the photo. The removal's row, publish
  record and coverage are one transaction (`commit_profile_sync`); with
  nothing else pending it leaves the profile it published as a new pending
  version, partly published, with the ladder advanced, so the next due sync
  sends it to the whole pool again. With an edit pending it adds nothing —
  that edit's sync republishes the whole profile to the whole pool, and the
  edit must not read as partly published when no relay was sent it. The
  blank a deletion publishes is owed the same way, by the same statement
  (`write_unqueued_publish_owed`) in the wipe's own transaction
  (`wipe_all_profiles`); its retry publishes a blank again, because the row
  it builds on is the dated blank. Either backoff runs from when the
  retraction was RECORDED, not from when it began, so the status re-read
  that follows never finds the retry already due.
- The copy a sync or a retraction reads for its base is cached when it is
  newer than the row, BEFORE the publish: a publish that fails still leaves
  the row at the newest copy read, so the retry cannot build on an older one
  another relay serves (`a_newer_copy_read_for_a_publish_that_failed_is_what_the_retry_builds_on`).
- Staging never arms the retraction gate (picture rows with an empty URL do not
  count) and never disarms it (a seen kind-0 with `event_created_at > 0` counts).
- Everything uploaded went through `process_own_avatar` (private fields on
  `StagedPicture`; guard check on constructors and staging call sites).
- `profile_sync_state` rows are reset in place, never deleted (version reuse
  would let a stale sync clear a newer marker).
- Auto-retries honour the persisted ladder; no unconditional network call on
  start/resume; no profile-sync symbol in the background isolates.
- The supplied identity secret must match the manager's construction identity.

## Deliberately rejected (do not re-add)

- **Persistent profile-plane relay client** — 8 always-open sockets would make
  the low-signal plane a continuous presence beacon.
- **First-ack early return with detached stragglers** — per-relay bounds already
  cap the fan-out; returning early would abandon the sends that let peers (who
  each read from their own salted top-2) resolve the profile.
- **Splitting the retraction functions out of `api.rs`** — the CI guard binds
  the consent gate to the first publish-footprint call in the *same* function
  body; a wrapper would silently un-bind it.
- **"Discard pending edit" action** — would create a path to a never-published
  profile, contradicting the owner's publish-unconditionally directive; editing
  again is the cancel.
- **Taking the sync lock inside the local-save path** — it would serialize
  instant saves behind a background sync (the regression this work removes) to
  close a window that needs a whole-profile delete concurrent with a rename.

## Accepted costs

- On a *total* merge-base read miss the local row is the base: a field another
  client **added** since our last fetch is lost and a field it **changed** is
  reverted. Requires every pool relay to fail the read; accepted so offline
  edits are never stranded (pinned by test so nobody "fixes" it into deferral).
- A partial-coverage publish — a save's, a photo removal's or a deletion's
  blank — is retried once per due trigger by reading the pool and signing a
  NEW kind-0 for the whole pool: the same content, `created_at` = the time
  of the pass, hence a new event id. On the ladder that is at most four
  passes in the first hour and then at most one per six hours, with **no
  cap** while one pool relay never acknowledges, and every relay that takes
  a pass holds a new public `created_at` — a mark of when the app was
  opened. The debt ends only when every relay of the usable pool acknowledges
  one pass, or when the relay that never does leaves the pool (retired in an
  app release, or excluded as contaminated); until then the status reads
  "published — still syncing to some relays". Not bounded yet: the owner
  decision is whether to re-send the ONE signed event instead (healthy relays
  then answer "duplicate" and store nothing), and when a relay that holds a
  newer copy from another client — and so refuses the older event for good —
  ends the debt.
- Removing a photo is still a synchronous retraction (≈1–2 s typical, ≤ ~29 s
  worst) — the honest shape for a destructive action; it shows a spinner.
- Location-plane `try_publish_once` still discards partial acks under its outer
  timeout — a separate follow-up (`publish_before_apply_send_e2e.rs` is its
  proving ground).
