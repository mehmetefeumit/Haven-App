# M2 design — mesh keys, hand-off, `mesh_drive`, bridging, counters

> Status: **DESIGN for milestone M2 of `docs/BLUETOOTH_MESH_PLAN.md` — drafted
> and independently reviewed 2026-11-11; not yet implemented beyond M2a.**
> The review's findings and its answers to the open questions are in the last
> section and OVERRIDE the body wherever they differ. One question (Q-1, what
> key material is stored at rest) awaits the owner's decision.

Repo at `1c7aac4`. Read-only study; nothing in the repo was changed.
Abbreviations: `mgr` = `haven-core/src/nostr/mls/manager.rs`, `fan` =
`haven-core/src/relay/fanout.rs`, `cm` = `haven-core/src/circle/manager.rs`,
`st` = `haven-core/src/circle/storage.rs`, `api` =
`haven/rust_builder/src/api.rs`, `gates` =
`haven-core/tests/security_rule_gates.rs`, `mdk:` = the pinned checkout
`~/.cargo/git/checkouts/mdk-7d5a3a2420b194f5/fcc85ed/crates/`, `nostr:` =
`~/.cargo/registry/src/*/nostr-0.44.8/src/`. **[U]** marks what I could not
verify. Line numbers are today's, not the plan's `f1dd146`.

## 0. Four findings that change the plan's text (decide before coding)

| # | Finding | Evidence | Consequence |
|---|---|---|---|
| F-1 | **The receiver's application-only check (§4.3) cannot be made for a past epoch with only `K_mesh` stored.** The preview peel needs the epoch's group-event exporter itself: the peeler's key *is* that secret (`mdk:transport-nostr-peeler/src/peeler.rs:85-97`), Haven can read it for the current epoch only (`mdk:cgka-session/src/lib.rs:805-816`), and MDK peels past epochs by rewinding to a retained snapshot inside the engine (`mdk:cgka-engine/src/message_processor/ingest.rs:2832-2870`), with no API for Haven. | `class_at` builds its context from that secret (`mgr:3149-3200`) | Either the ring stores the exporter `G_e` per retained epoch (and derives `K_mesh` from it), or past-epoch packets cannot be ingested after a restart. Q-1. |
| F-2 | **One epoch number can have two keys.** A convergence pass that selects another branch at the same height emits no `EpochChanged` (`mdk:cgka-engine/src/distributed_convergence.rs:1760-1766`: only `if previous_tip != selected_tip`). | — | The ring is keyed by key bytes, not by epoch number, and is refreshed on every state-bearing batch, not on `EpochChanged` alone. |
| F-3 | **A circle's routing id can change at an epoch** (`routing_history`, `st:1276-1291`), and the envelope carries no `h`. | plan §4.1 "rebuilds with `h` from the circle whose key opened" | Each ring entry stores the routing id of its epoch. |
| F-4 | **`take_unread` hands a packet out once** (`haven-core/src/mesh/store.rs:454-460`); plan §5.2.4 says a deferred packet "is offered again while held". | — | Session code keeps its own small bounded list of opened-but-not-yet-ingested packets. |

**G-2 is measured and passes.** A scratch binary outside the repo
(`<session scratchpad>/g2probe/src/main.rs`,
real two-member circle, `SessionManager::send_location`, which uses the same
`location_rumor` as production, `mgr:4524` vs `mgr:2952`) gave, for creator
and joiner alike:

| `LocationMessage` JSON | bytes | kind-445 content, base64 | decoded |
|---|---|---|---|
| `(0.0, 0.0)` | 144 | 724 | **543** |
| `(37.7749295, -122.4194155)` | 160 | 748 | **559** |
| `(-89.99999999999999, -179.99999999999997)` | 175 | 768 | **574** |
| `(-12.345678901234567, -123.45678901234567)` | 176 | 768 | **575** |

`decoded = json + 399` exactly. The limit is 881
(`haven-core/src/mesh/packet.rs:42`), so a location JSON of up to 482 bytes
fits; today's largest is about 180. Headroom ≈ 300 bytes. The plan's "590–640"
was high. M2a turns the probe into a committed test (§B.4).

---

## A. Keys (§4.2)

### A.1 What exists

- Every `&mut AccountDeviceSession` comes from one function,
  `SessionManager::engine` (`mgr:1582`), over `Gated::engine`
  (`haven-core/src/nostr/mls/engine_gate.rs:97-110`); 55 call sites.
- Every engine batch Haven keeps is passed, **with the session still held**,
  through `noted` → `note_effects` (`mgr:9560-9590`; `drain` calls it too,
  `mgr:9553-9557`). `note_effects` already reacts to `EpochChanged`
  (`note_batch`, `mgr:9616-9700`). **This is the choke point.** No test pins
  that every batch reaches it [U], so A.3 adds a second, self-healing sync.
- The exporter is read with
  `session.exporter_secret_with_epoch(group_id, DEFAULT_EXPORTER_LABEL, 32)`
  → `Result<(EpochId, SecretBytes), EngineError>`, `SecretBytes =
  Zeroizing<Vec<u8>>` (`mdk:traits/src/group_context.rs:19`); used at
  `mgr:3157`, `12881`, `12949`, and `exporter_secret` at `mgr:12799`.
- **While a commit is staged it returns the staged epoch and the staged
  secret** (`mdk:cgka-engine/src/engine.rs:3421-3457`:
  `if let Some(staged) = mls_group.pending_commit()`).
- Epoch-changing engine calls and what the batch carries
  (`mdk:traits/src/engine.rs:527-720`): ingest of a commit and the
  convergence advance → `EpochChanged`
  (`mdk:cgka-engine/src/message_processor/ingest.rs:1773`,
  `distributed_convergence.rs:1761`); confirm of an own commit →
  `EpochChanged` or `GroupCreated` (`mdk:cgka-engine/src/publish.rs:324-335`);
  join → `GroupJoined`; branch reselection → `GroupStateInvalidated` /
  `GroupStateRevalidated` / `CommitRolledBack`, with or without
  `EpochChanged` (F-2); open → `PendingCommitRecovered`,
  `GroupHydrationRecovered`. A rollback of a staged commit changes no epoch.
- Retention: 5 past epochs (`mdk:cgka-engine/src/canonicalization.rs:21`,
  `wire_format.rs:46-47`).

### A.2 Layering and placement

`SessionManager` cannot reach `CircleStorage`; `CircleManager` owns both
(`cm:152-156`, `cm:220`) and hands the session three store traits at
construction: `CommitNotes` (`cm:295`), `RefusedRedeliveryLedger` (`cm:298`),
`StallEvidence` (`cm:299`; second constructor `cm:435-436`). Each trait lives
in `nostr/mls/`, has an in-memory default, and is implemented for
`CircleStorage` in `circle/storage_*.rs`
(`circle/storage_commit_notes.rs:601-680` is the model).

**Smallest sound placement: the same pattern.** New file
`haven-core/src/nostr/mls/mesh_keys.rs` (ring + trait), new file
`haven-core/src/circle/storage_mesh.rs` (impl + counters), one line at
`cm:299` and `cm:436`: `session.install_mesh_key_store(storage.clone());`.
No new database, no new open (the SQLite first-use rule is untouched).

### A.3 Data model

```rust
// nostr/mls/mesh_keys.rs — the only file under nostr/ that names `mesh::`.
pub(crate) const MESH_KEYS_PER_CIRCLE: usize =
    cgka_engine::DEFAULT_MAX_PAST_EPOCHS + 1;                    // 6

/// One epoch of one circle. No Clone, Debug, PartialEq.
struct EpochKey {
    epoch: u64,                       // never logged (Rule 15)
    routing: [u8; 32],                // the epoch's nostr_group_id (F-3)
    exporter: Zeroizing<[u8; 32]>,    // G_e: the preview peel's key (F-1, Q-1)
    mesh: MeshKey,                    // MeshKey::derive(&exporter)
}

struct CircleKeys { slot: CircleSlot, keys: Vec<EpochKey> }       // newest first, ≤ 6

pub(crate) struct MeshKeys {
    on: bool,                                   // user_settings 'mesh_on'
    circles: HashMap<GroupId, CircleKeys>,
    next_slot: u32,
    store: Arc<dyn MeshKeyStore>,
}

pub trait MeshKeyStore: Send + Sync {
    fn mesh_on(&self) -> bool;
    fn set_mesh_on(&self, on: bool) -> bool;         // off also deletes every key row
    fn mesh_keys(&self) -> Vec<StoredMeshKey>;        // read once, at install
    fn put_mesh_key(&self, group: &GroupId, epoch: u64, routing: &[u8; 32],
                    exporter: &[u8; 32]) -> bool;
    fn prune_mesh_keys(&self, group: &GroupId, keep: &[u64]);
    fn forget_mesh_keys(&self, group: &GroupId);
}
pub struct NoMeshKeyStore;                        // a session with no circle store
```

`SessionManager` gains one field, `mesh: std::sync::Mutex<MeshState>`
(`MeshState { keys: MeshKeys, handoff: Option<Arc<Handoff>>, held:
VecDeque<Held>, bridge: BridgeBook, mesh_only: HashSet<MessageId> }`), a std
mutex like `unread_input` (`mgr:516`): never held across an `.await`.

`CircleSlot`: `next_slot` is taken the first time a circle gets a key, lives
for the process, is never stored, sent or logged. It is an arrival ordinal
and says nothing about the circle.

### A.4 When a key is installed — one function, three callers

```rust
/// Brings `group`'s newest key in line with the engine. Installs nothing
/// while a commit is staged: the exporter read then is the staged epoch's.
fn sync_mesh_key(&self, held: &AccountDeviceSession, group: &GroupId)
```

1. Return unless `keys.on`.
2. `let Some(EpochState::Stable { epoch }) = held.epoch_state(group)` — else
   return. `PendingPublish` is the staged case (`mgr:5211-5219`).
3. `held.exporter_secret_with_epoch(group, DEFAULT_EXPORTER_LABEL, 32)`;
   return unless the epoch it reports equals `epoch` and the secret is 32
   bytes. Copy into `Zeroizing<[u8; 32]>`; the `SecretBytes` drops zeroized.
4. If an entry with the same exporter bytes exists (`subtle::ConstantTimeEq`,
   already a dependency, `haven-core/Cargo.toml:177`) → nothing changed.
5. Otherwise read the routing id from the routing component (as
   `fanout_targets` does, `mgr:15216-15228`), push the entry to the front,
   drop entries with `entry.epoch + 5 < epoch`, then truncate to 6; write the
   new row and prune the dropped ones; **purge the circle's outbox slot**
   (`handoff.purge(slot)`, §C.3).

Staged-epoch rule: the staged key is never read, so there is nothing to
discard on rollback; the confirm's own batch carries `EpochChanged`
(`mdk:cgka-engine/src/publish.rs:326`) and step 2 then passes. T-SEC-6 pins
both directions.

Callers:

| Caller | Where | Groups |
|---|---|---|
| every engine batch | new last line of `note_effects` (`mgr:9573-9590`): `self.sync_mesh_keys(held, batch.events())` | the `group_id` of every event **except** `MessageReceived`, `AppMessageInvalidated`, `TransportObjectResourceRefused` (the per-location hot path changes no epoch) |
| mesh on, and session open with `mesh_on` stored | `install_mesh_key_store` after the open; `SessionManager::mesh_start` | `held.live_group_ids()` (`mgr:1471`) |
| start of every `mesh_drive` | §D.2 step 1, one engine hold | every live group — heals any batch path that skipped `note_effects` |

Cost of one sync: one cached group load and three HKDF exports
(`mdk:cgka-engine/src/engine.rs:3414-3497`).

Residuals, both already in the plan: epochs crossed inside one engine call,
and epochs crossed while mesh was off, have no key (`T-MESH-EXPORTER`).

### A.5 Persistence

`circles-v2.db`, in the `CREATE TABLE IF NOT EXISTS` batch (`st:917-`), the
pattern every table since the first uses; a new table needs no `ALTER`
migration (those exist only for added columns, e.g.
`migrate_add_rotation_columns`, `st:1638-1665`).

```sql
-- A circle's mesh packet keys for the epochs the engine still retains, kept
-- only while mesh is on. A group id and an epoch at rest, here only (as
-- epoch_stall_evidence); dropped with the circle and when mesh is turned off.
CREATE TABLE IF NOT EXISTS mesh_keys (
    mls_group_id BLOB NOT NULL,
    epoch        INTEGER NOT NULL,
    routing_id   BLOB NOT NULL,
    secret       BLOB NOT NULL,
    PRIMARY KEY (mls_group_id, epoch, secret)
) WITHOUT ROWID;
```

- Keyed by the **MLS group id**: the ring is filled under the engine hold,
  which speaks `GroupId`; `epoch_stall_evidence` already stores
  `mls_group_id` + an absolute epoch (`st:1217-1223`), and `circles` stores
  both ids (`st:919-923`). Rule 4 is about publishing; neither id leaves
  the database.
- Write: `params![group.as_slice(), epoch, &routing[..], &exporter[..]]` —
  borrowed slices, no Rust-side copy.
- Read: `row.get_ref(3)?.as_blob()?` copied straight into a
  `Zeroizing<[u8; 32]>`; never `row.get::<_, Vec<u8>>` (an unzeroized heap
  copy). A row whose blob is not 32 bytes is skipped and deleted.
- `MeshKey` API: with Q-1 = A (store `G_e`) **no accessor is added to
  `MeshKey`**: `MeshKey::derive` rebuilds it at load. With Q-1 = B the
  reviewer's pair is added and `secret` holds `K_mesh`:
  `pub(crate) fn stored_bytes(&self) -> &[u8; 32]`,
  `pub(crate) fn from_stored(bytes: &[u8; 32]) -> Self`.
- `scripts/ci/check_secret_fields_zeroized.sh` scans raw containers in
  secret-named structs: `exporter: Zeroizing<[u8; 32]>` passes; add
  `EpochKey` to `haven-core/tests/zeroization_security.rs`.

### A.6 Deletion

| Event | Hook | Action |
|---|---|---|
| leave completes | `cm:2584-2595` (`complete_leave`), row delete `st:2173-2185` | add `"mesh_keys"` to the table list at `st:2173-2180`; `session.forget_mesh_circle(group)` beside `end_location_records` (`cm:2592`) |
| disband | `reconcile_disbanded`, `cm:1024-1028` | `session.forget_mesh_circle(group)` |
| `forget_group_local` | `mgr:3849-3857` | same call, in the hold |
| mesh off | `SessionManager::mesh_stop` | `store.set_mesh_on(false)` (deletes every row), ring cleared |
| identity delete | `wipe_all_mls_state`, `api:1213-1242` | the database file and its keyring key are deleted; the FFI also empties the engine slot first (§H) |
| pruning | A.4 step 5 | in step with the engine's window |

---

## B. Event ↔ envelope

### B.1 The shape to reproduce

`mdk:transport-nostr-peeler/src/peeler.rs`: content =
`BASE64_STANDARD.encode(nonce ‖ ciphertext)` (`:136`, padded standard
alphabet, `:19`); tags, in order, `Tag::custom("h", [hex::encode(group_id)])`
(`:144-147`, lower-case hex) then, for an application message,
`Tag::custom("expiration", [expiration.to_string()])` (`:148-153`, decimal);
kind 445 (`:159-160`); `created_at` = the inner event's (`:161-163`); signed
by a fresh key (`:139`, `:164-166`). `RetentionBoundPeeler` only changes
which expiration is asked for (`haven-core/src/nostr/mls/retention.rs:110-121`,
`:168-177`).

### B.2 Module

`haven-core/src/mesh/event.rs` (names `nostr` types, no MDK type, so it stays
inside the mesh module's rule, `haven-core/src/mesh/mod.rs:4-6`).

```rust
/// The envelope fields of `event`, or `None` unless it is a kind 445 whose
/// tags are exactly `[h, expiration]`, whose content is canonical standard
/// base64 of at most `MAX_CONTENT_LEN` bytes, and which `rebuild` gives back
/// with the same id.
#[must_use]
pub fn parts_of(event: &nostr::Event, format: Format) -> Option<EventParts>;

/// The signed event `parts` describe for the circle routed by `routing`.
/// Not yet authentic: the caller runs `Event::verify()`.
#[must_use]
pub fn rebuild(parts: &EventParts, routing: &[u8; 32]) -> nostr::Event;
```

`rebuild`, exactly:

```rust
let pubkey  = PublicKey::from_byte_array(parts.pubkey);              // nostr:key/public_key.rs:78
let created = Timestamp::from_secs(parts.created_at);
let kind    = Kind::Custom(KIND_GROUP_MESSAGE);
let tags = Tags::from_list(vec![                                       // nostr:event/tag/list.rs:111
    Tag::custom(TagKind::custom("h"), [hex::encode(routing)]),
    Tag::custom(TagKind::custom("expiration"), [parts.expiration.to_string()]),
]);
let content = BASE64_STANDARD.encode(&parts.content);
let id  = EventId::new(&pubkey, &created, &kind, &tags, &content);    // nostr:event/id.rs:42-53
let sig = Signature::from_slice(&parts.sig).ok()?;                     // 64 bytes → Option
Event::new(id, pubkey, created, kind, tags, content, sig)              // nostr:event/mod.rs:133-155
```

(so `rebuild` returns `Option<Event>`; a signature that is not a curve point
encoding is `None`). `id` is recomputed, never carried; `Event::verify()`
(`nostr:event/mod.rs:160-180`) then checks id and signature, and a packet
opened under another circle's key fails there because `id` covers `h`.
`PublicKey::from_byte_array` does not validate; `verify_signature` does
(`nostr:event/mod.rs:208-213`).

`parts_of` reads `event.tags.as_slice()` and each `tag.as_slice()`
(`nostr:event/tag/mod.rs:274`): two tags, names `h` and `expiration`, two
values each; expiration parsed as `u64`; routing = 32 bytes from the hex;
then **`rebuild(&parts, &routing)?.id == event.id`**. That one comparison
replaces separate canonical-form checks (upper-case hex, `+228`, leading
zeros, non-canonical base64): the id covers every string.

### B.3 Rule 16

`rebuild` is not a relay ingress, so no client is built. The mesh ingress
calls `verify()` — never `verify_id()` or `verify_signature()` alone — before
anything else looks at the event; the guard text of Rule 16 gains that
sentence (§K).

### B.4 Tests (M2a)

Helper: `tests/helpers/mod.rs:125-180` `setup_two_party_group`; a sealed
event from `send_445` (`gates:103-117`) or, through the driver,
`helpers/drive.rs:265`.

- `a_sealed_location_survives_the_envelope_byte_for_byte`:
  `rebuild(parts_of(e), ngid) == e` comparing `as_json()`; then through
  `wrap`/`open`.
- `g2_the_largest_location_fits` : the four fixes above plus a proptest over
  `f64` in range; asserts `decoded ≤ MAX_CONTENT_LEN` and pins
  `decoded == json + 399` so a growth in MDK's framing fails at the bump.
- `a_commit_or_a_foreign_shape_has_no_parts`: tags `[h]`, three tags,
  swapped order, non-canonical expiration, kind ≠ 445, 882 content bytes.
- `the_peelers_tag_layout_is_the_one_the_formats_mean`: reads
  `mdk:transport-nostr-peeler/src/peeler.rs` as `mdk_source` does
  (`gates:4852`), pins lines 136-165 (plan §4.1 "re-read at every bump").

---

## C. Hand-off

### C.1 Where

`fan:4791-4825`. In scope at the hand-off: `event`, `message`, `session`,
`now_ms`, `record: LocationToSend`. The seal epoch is **not** in
`LocationToSend` today (`mgr:15174-15183`) but is in scope where it is built:
`application.group_id` and `application.source_epoch` (`mgr:4729-4747`). Add
two fields:

```rust
pub struct LocationToSend {
    pub relays: Vec<String>,
    pub expires_at_secs: u64,
    pub may_be_sent: bool,
    /// The circle and the epoch it was sealed at.
    pub(crate) circle: GroupId,
    pub(crate) sealed_at: EpochId,
    /// Sealed for the mesh alone (§E).
    pub(crate) mesh_only: bool,
}
```

```rust
        if !record.may_be_sent {
            let _ = session.end_location(&message).await;
            return LocationPublish::Superseded;
        }
        session.mesh_offer(event, &record);                       // NEW — the one hand-off
        if record.mesh_only {                                      // NEW (M2d)
            let _ = session.end_location(&message).await;
            return LocationPublish::MeshOnly;
        }
        let sent = self.fanout.publish_location(event, &record.relays).await;
        let _ = session.end_location(&message).await;
        LocationPublish::Sent(sent)
```

```rust
/// Wraps `event` under the key of the epoch it was sealed at and leaves the
/// packet for the mesh engine. Nothing when mesh is off, when that epoch has
/// no key, or when the event does not fit. Synchronous; no I/O; no engine
/// hold; cannot fail.
pub(crate) fn mesh_offer(&self, event: &Event, record: &LocationToSend)
```

Body: lock `self.mesh`; `handoff` is `None` → return; find the entry of
`record.circle` whose `epoch == record.sealed_at.0` (it is the newest:
`may_be_sent` required `Stable { epoch } == source_epoch`, `mgr:4795-4798`);
`parts_of(event, format)` with `Format::NeverBridged` when `mesh_only`, else
`Bridgeable`; `packet::wrap(&entry.mesh, &parts, &mut rand::rngs::OsRng)`;
`handoff.offer(slot, packet, parts.expiration)`. One AEAD over 996 bytes.

### C.2 Why a hand-off map, not the engine lock

The engine will sit behind a mutex the radio thread also takes (M3). A
`try_lock` that fails drops the update; a `lock` makes the relay path wait on
radio work, and T-INDEP-1b names a *stalled* engine. So the relay path never
touches that mutex:

```rust
// haven-core/src/mesh/handoff.rs — no MDK type, no static, no I/O.
pub enum Op { Offer { packet: Packet, expires_at_secs: u64 }, Purge }

pub struct Handoff { ops: std::sync::Mutex<BTreeMap<CircleSlot, Op>> }

impl Handoff {
    pub fn offer(&self, slot: CircleSlot, packet: Packet, expires_at_secs: u64);
    pub fn purge(&self, slot: CircleSlot);
    /// Every pending op, the map left empty: what the engine's owner applies
    /// before any other engine call.
    pub fn take(&self) -> Vec<(CircleSlot, Op)>;
}
```

The latest op per slot is all that matters — an offer replaces what waits, a
purge removes it (`haven-core/src/mesh/engine.rs:639-668`) — so a map of the
last op per slot is equivalent to the ordered stream and is bounded by the
number of slots (cap at `Config::outbox_slots`; a new slot beyond it is
dropped, as the engine would drop it, `engine.rs:650`). Its mutex is held for
one map insert and never across engine work. If nobody drains it (engine
gone, stalled) it holds at most one packet per circle.

The owner applies it (`MeshEngine::apply(&mut self, &Handoff, wall_now_secs,
now_ms)`): `Purge` → `purge(slot, now_ms)`; `Offer` → `offer(slot, packet,
now_ms + (expires_at_secs·1000 − wall_now_ms), now_ms)`, skipped when the
event has already expired by the wall clock.

`Arc<Handoff>` is the whole link between haven-core and the slot in
`rust_builder`: the session holds one clone, the slot the other. No trait
object, no static in haven-core, no new field on `Publishing` (its literal is
built at 20-odd sites, `fan:3482-3501`, `cm:1680-2076`, `api:8327-8341`,
`tooling/soak/src/rig/circle.rs:416-420`, and a gate pins how
(`gates:3201-`)).

### C.3 Purge hooks

| State change | Hook | Verified |
|---|---|---|
| epoch change, own commit confirmed, branch reselected | A.4 step 5 | yes |
| **any** state-bearing batch for the circle (a commit staged, a proposal taken in) | `sync_mesh_keys` in `note_effects`: purge the slot of every group it visits, whether or not the key changed | hook yes; that a staging batch names its group in `events()` [U] — so also purge in `stage_commits` for each recorded `FanoutId::group()` (`mgr:3104-3110`) |
| fetched commit held unread | `hold_pager_commits` (`mgr:3898`), `hold_live_replay` (`mgr:4135`) | yes |
| leave asked | `Publishing::leave` after `circle.mark_leave_intent` (`fan:3730`) → `session.mesh_silence(group)` | yes |
| leave ended, disband | `end_location_records` (`mgr:4817-4829`; callers `cm:1027`, `cm:2592`) | yes |
| sharing turned off | no Rust call exists today; new sync FFI `mesh_sharing_stopped()` purges every slot; Dart calls it where the publish scheduler pauses | Dart site [U] |
| mesh off, identity delete | `MeshEngine::stop` (`engine.rs:684-700`) | yes |
| the event's own expiration | `offer(.., expires_ms, ..)` | yes |

A purge is cheap and conservative: the next own publish offers again.

### C.4 Pinned tests that constrain the code

- `gates:4815-4829`: `publish_location`'s body must contain exactly one
  `.publish_location(` and the squashed text
  `letsent=self.fanout.publish_location(event,&record.relays).await;let_=session.end_location(&message).await;LocationPublish::Sent(sent)`.
  → the hand-off and the mesh-only return go **before** `let sent`; nothing
  may sit between the send and the end; the bridge may not be called from
  inside `publish_location`. **No amendment needed for the hand-off.**
- `gates:4831-4838`: `settle_locations` may not contain `publish_location`
  or `transport` → the bridge stays out of it (unchanged).
- `gates:4633-4680` (`assert_no_rust_function_publishes_a_location_and_a_commit`):
  any function containing `.publish_location(` may not name
  `PendingStateRef`, `confirm_published`, `publish_failed` → holds for
  `bridge_locations` as designed; no amendment, but the bridge's file must be
  one the scan reaches (it is: `fan`).
- `gates:2992-3193` (`the_drivers_public_surface_is_pinned`): the list must
  gain, after `"async fn publish_location"`, `"async fn seal_for_mesh"`,
  `"async fn mesh_drive"`, `"async fn bridge_locations"`, and before them the
  new types in declaration order (`"struct MeshDrive"`, plus any `impl`
  line). **Amended in M2c/M2d/M2e.**
- `gates:1157-1250` (Rule 13.1 source shape): unchanged in text, but its doc
  and §K's rule text gain the bridge. The plain-publish refusal
  (`api:9117-9126`) stays.

---

## D. `mesh_drive` and ingest

### D.1 Reuse

| Piece | Reuse | Note |
|---|---|---|
| `process_event_staging` (`mgr:3067-3112`) | body, through a new private `process_event_staging_as(event, now_ms, still, observe: bool)`; the existing fn passes `true` | `note_ingested(.., observe)` is fed `mode == Full` today (`mgr:3091-3098`); mesh passes `false` and `FinishOnly`, so the stall detector is doubly unfed |
| `screen_before_auth` (`mgr:3227`) | as is, inside the above | |
| `order_for_ingest` (`mgr:3125-3141`) | as is | after D.2 step 4 every class is `Other`; kept for the one ordering rule (Rule 12) |
| `class_at` (`mgr:3176-3200`) | new sibling `class_under(event, epoch, &exporter)` sharing the peel-and-project lines | `class_at` takes a `GroupContextSnapshot`; the sibling builds it from the ring entry (`GroupContextSnapshot::new`, `mdk:traits/src/group_context.rs:61-73`) |
| `took_in` (`mgr:3927-3941`) | as is | decides `mark_read` |
| `fold_staged` (`cm:3112-3131`) → `persist_locations_from_events` (`cm:5154`, reached at `cm:5369/5381/5398`) | as is, `advance = false` | mesh locations are persisted by the one persist site, unchanged |
| `Publishing::settle` (`fan:4414-4428`) | as is | expected to have nothing to drive; never drops what the engine hands back |
| `ingest_for_poll` (`fan:4574-4625`) | **not** reused | it calls `unblock` (a relay call), advances, and returns a cursor verdict (`relay/catchup.rs:1295-1335`); the mesh plane has no cursor |
| `unblock` (`fan:4438-4451`) | never called | a held circle is skipped instead |

No cursor, no `relay_floors`: neither is touched by the functions above
(`cursor_verdict` is called only by `ingest_for_poll`, `fan:4623`).
`note_ingested` does record the event in the in-memory NIP-77 memo
(`mgr:3974-3990`); that is correct (this device now holds the event) and is
never sent.

### D.2 One drive

```rust
// fan, in `impl<T: FanoutSend + ?Sized> Publishing<'_, T>`
/// Reads the mesh packets `taken` and takes in what one of this device's
/// circles sent. Sends nothing.
pub async fn mesh_drive(
    &self,
    circle: &CircleManager,
    taken: Vec<Packet>,
    receive_completed: bool,
) -> MeshDrive

pub struct MeshDrive {
    /// Per packet of `taken`, in order: whether it opened under a key.
    pub read: Vec<(PacketId, bool)>,
    /// Packets that opened, verified and were application messages.
    pub from_circles: u64,
    /// Locations taken in; each is stored already.
    pub replayed: Vec<LocationMessageResult>,
    pub errored: bool,
}
```

The engine is not reachable from haven-core, so the FFI wrapper does the two
engine calls around it: `take_unread(MESH_DRIVE_PACKETS)` before, and
`mark_read(id, opened)` for each `read` entry after (§H). Constants:
`MESH_DRIVE_PACKETS = 256`, `MESH_EVENTS_PER_CIRCLE = 32` per drive,
`MESH_HELD_PACKETS = 256` (F-4).

Steps:

1. `session.sync_all_mesh_keys()` (one hold). Mesh off → return empty.
2. Candidates = the session's held list (F-4) then `taken`.
3. **Trial-open** each packet against every ring entry (≤ 6 × circles
   Poly1305 checks; T-PERF-2 counts them through a test-only counter). No
   key opens → `read.push((id, false))`. A key opens → `(circle, entry,
   parts)`.
4. **Authenticate and classify, before the engine:**
   `rebuild(&parts, &entry.routing)?` → `event.verify()` →
   `class_under(&event, entry.epoch, &entry.exporter)` must be
   `Application` **with `source_epoch == entry.epoch`**. Anything else →
   `read.push((id, true))`, dropped, not counted. (T-SEC-1, T-SEC-2. The
   epoch equality also closes T-SEC-5's flood at the door: an application
   message whose inner epoch is not its key's epoch never reaches the
   engine's buffer. That an honest seal always satisfies it is asserted by a
   test [U until run].)
   `from_circles += 1` here (§7.5: "opened … and verified").
5. Group by circle. For each circle:
   a. `session.staged_commit(group).await.is_some()` (`fan:4512-4517`:
      `AwaitingRelays`, `Acknowledged`, `StagedWithoutRecord`) → every
      packet goes to the held list; nothing reaches the engine (Rule 12, plan
      §5.2.4). Not driven, not unblocked.
   b. Take at most `MESH_EVENTS_PER_CIRCLE`; the rest go to the held list.
   c. `session.order_for_ingest(&group, events).await`.
   d. For each, while `self.allows(FOLD_BUDGET_MS)`:
      `session.ingest_from_mesh(&event, now_ms).await` (below), then
      `circle.fold_staged(effects, false, now_ms, Still::always(&FinishOnly))`
      and `self.settle(circle, recorded, handed_back, false, &mut pass)`.
   e. Answer `Held` → held list; any other → `read.push((id, true))`.
      Answer `New { sender }` with `parts.format == Bridgeable`,
      `receive_completed`, and the circle caught up (§F.2) →
      `session.bridge_candidate(group, sender, event, entry.epoch)`.
6. Held list over `MESH_HELD_PACKETS` → oldest dropped, reported
   `(id, true)`.
7. `circle.fold_mesh_counts(from_circles, 0)` (§G).

```rust
/// One mesh event into the engine, never observed by the stall detector,
/// never in the full mode.
pub(crate) async fn ingest_from_mesh(&self, event: &Event, now_ms: u64)
    -> Result<(MeshIngested, SessionEffects, Vec<FanoutId>)>

pub(crate) enum MeshIngested {
    /// A new authenticated application message carrying a location.
    New { sender: MemberId },
    /// Taken in, and not new: a duplicate, an own echo, stale, buffered,
    /// rejected, or not a location.
    Seen,
    /// Not taken in (`took_in` false): offered again.
    Held,
}
```

`New` = outcome `IngestOutcome::Processed` **and** the batch holds
`GroupEvent::MessageReceived { message_id, sender, .. }` with `message_id`
equal to this event's id (`mdk:traits/src/engine.rs:550-566`) **and**
`location_result_from_event` gives non-empty content (`mgr:13007-13021`)
**and** `sender` is not this device. What MDK answers for a relay-first
duplicate or an own echo is some non-`Processed` outcome or a `Processed`
without that event [U: which `StaleReason`]; the definition does not depend
on it, and T-BRIDGE-3 pins both cases.

---

## E. Mesh-only seal (§7.7 R1)

**The mark lives in the session, not in the value Dart holds.** Plan: "a
mesh-only mark inside the opaque sealed value". Proposed instead: a set
`mesh_only: HashSet<MessageId>` beside `own_locations` (`mgr:686`),
filled in the hold that records the seal, read into
`LocationToSend.mesh_only` (`mgr:4729-4747`), removed in `end_location`
(`mgr:4839-4850`). Stronger than the plan's form — whatever Dart does with a
`SealedLocationFfi`, Rust routes it — and `SealedLocationFfi`
(`api:7617-7619`), `LocationSeal` (`fan:3167-3180`) and `publish_location`'s
signature stay as they are (about 30 test sites destructure or call them). A
process that dies loses the mark and the record with it: a dead process's
record is never sent (`fan:2707-2717`). Q-3.

```rust
/// [`Self::seal_location`] for the mesh alone: nothing is driven, repaired
/// or settled, and no commit is made.
pub async fn seal_for_mesh(&self, circle: &CircleManager, group_id: &GroupId,
                           location: &LocationMessage) -> Result<SealOutcome, CircleError>
```

Against `seal_location` (`fan:4660-4770`):

| Step | `seal_location` | `seal_for_mesh` |
|---|---|---|
| mesh running | — | not running → `Deferred(SendHeld::Nothing)` without touching the engine |
| disbanded / leaving | `fan:4667-4684` | same |
| `unblock` | `fan:4685` | **skipped** — a pending commit stays pending, the seal defers as `AwaitingRelays` |
| unread input | `fan:4688-4696` | same |
| mode | the caller's | `Still::always(&DriveMode::FinishOnly)` (`fan:624-629`): no eviction is committed; due one → `DepartureDue` |
| `seal_location_staging` | `fan:4705-4733` | same, then `session.mark_mesh_only(id)` |
| repair | `fan:4741-4750` | **skipped** |
| settle | `fan:4753` (drives recorded rows) | `self.dispose(..)` only when it has no proposal to send; recorded rows stay stored for the next relay drive |

`LocationPublish::MeshOnly` (new, `fan:2686-2705`) → `LocationPublishFfi::MeshOnly`
(`api:7723-7746`, mapping at `api:7772-7792`). Dart's two exhaustive switches
(`haven/lib/src/services/location_sharing_service.dart:430-449`,
`background_location_task.dart:2117-`) gain the arm in the same commit; it
feeds no health event.

Burst coordinator: the two exits that today publish nothing —
`haven/lib/src/services/background_burst_coordinator.dart:577-584` (catch-up
did not complete) and the `noSession`/`stopped` start that failed (`:586-594`,
`_startedIntoBurst`, `:689-704`). At each, when `meshEnabled`, mesh is on,
`!_foregrounded()` and `_burstEnabled()`: `await _publishPass(meshOnly: true)`
then return, skipping `_foldMaintenance` as the early return already does.
`_receivedWithoutSession` folds the three causes into one `false`
(`:674-681`); it must return which (a small enum) so a foreground or consent
stop still seals nothing.

---

## F. Member bridging (§5.5)

### F.1 Function

```rust
/// Sends, once each, the fellow members' locations this device took in by
/// mesh for `group_id`, to the circle's relays. What the relays answer is
/// read by nothing.
pub async fn bridge_locations(&self, circle: &CircleManager, group_id: &GroupId)
```

In `fan`, `impl Publishing`. Body: `session.bridge_to_send(group_id, now_ms,
self.mode.mode()).await` returns `Vec<(nostr::Event, Vec<String>)>`; for each,
while `self.allows(LOCATION_SEND_MS)`:
`let _ = self.fanout.publish_location(&event, &targets).await;`
(`FanoutSend::publish_location`, `fan:796-829`: one attempt a relay, no relay
taken). No record, no `Driving` claim, no `end_location`, no retry.

**Caller.** Not `publish_location` (C.4). The FFI's
`publish_location_driven` (`api:8629-8640`) after its own send:

```rust
let publish = publishing.publish_location(&circle.inner, &sealed.event).await;
if matches!(publish, LocationPublish::Sent(_)) {
    if let Some(group) = circle.inner.group_of_event(&sealed.event) {   // cm:5057
        publishing.bridge_locations(&circle.inner, &group).await;
    }
}
publish.into()
```

So "a drive that publishes nothing of its own bridges nothing" is structural,
and the soak rig calls the same pair. Cost: when a candidate exists, Dart
gets its own publish's answer up to one location send later. Q-4 (the
alternative is a second FFI call Dart makes after reading the answer).
`group_of_event` is `pub(crate)`; expose a narrow
`Publishing::publish_location_and_bridge` in `fan` instead of widening it —
then the surface list gains that one name and `api` calls it.

### F.2 Receive first

What exists in Rust: `SessionManager::caught_up` — set when a catch-up sweep
finished (`relay/catchup.rs:1620`) or every relay of the live subscription
sent EOSE (`cm:5006`), cleared when the live plane pauses or stops and when a
sweep of the circle begins (`mgr:5549-5596`). It has no non-test reader by
group; add `pub(crate) fn caught_up(&self, group) -> bool`.

It says "the last receive completed and nothing invalidated it", not "in
this drive". So both are required at candidate time (D.2 step 5e):
`receive_completed` (the caller's word for this drive) **and**
`session.caught_up(group)` (Rust's own fact; fails closed).

`receive_completed` per drive — Dart calls `mesh_drive` right after the
drive's receive step and passes that step's typed result:

| Drive | Signal | Verified |
|---|---|---|
| iOS burst | `opened && outcome != BacklogOutcomeFfi.timedOut` (`background_burst_coordinator.dart:637-645`), or `_receivedWithoutSession == true` (`:577-584`) | yes |
| Android task | the tick's fetch completed; the task publishes before it fetches, so a candidate made at tick N is sent at tick N+1's publish, inside the 218 s window or not at all | order per plan §5.5; exact site in `background_location_task.dart` [U] |
| foreground, live build | `LiveLifecycleFfi.foreground`; `caught_up` decides per circle | lifecycle enum yes (`:586-595`) |
| foreground, poll build | the receive timer's `CatchupResult` with `deadlineHit == false && relayErrors == 0` (`relay_service.dart:18-48`) | fields yes, call site [U] |
| no receive step in the drive | `false`: ingest only, no candidate | — |

### F.3 Candidate state

```rust
struct BridgeBook {
    /// Per circle and sender, the newest candidate only.
    waiting: HashMap<(GroupId, MemberId), Candidate>,   // ≤ BRIDGE_WAITING = 64
    /// When each sender was last bridged, on the session's monotonic clock.
    sent: HashMap<(GroupId, MemberId), u64>,
}
struct Candidate { event: nostr::Event, epoch: u64 }
```

In `MeshState` (memory only; a kill loses it, as the plan says). Constants:
`BRIDGE_SENDER_GAP_MS = 72_000`, `BRIDGE_PER_DRIVE = 4`. Dropped with the
circle, at mesh off, and for a circle at every purge of §C.3.

### F.4 Send-time checks — `bridge_to_send`, one engine hold

For each waiting candidate of the circle, newest first, at most
`BRIDGE_PER_DRIVE`; a candidate is removed whatever the verdict:

1. `expiration − created_at ≤ LOCATION_MESSAGE_RETENTION_SECS` (228,
   `haven-core/src/location/ttl.rs:191`).
2. `created_at·1000 ≤ now_ms + LOCATION_SEND_MS`.
3. `!location_is_spent(expiration, now_ms)` (`fan:2679-2681`) — with 1, the
   send begins at most 218 s after `created_at`.
4. `now − sent[(group, sender)] ≥ BRIDGE_SENDER_GAP_MS`.
5. `self.location_may_be_sent(&mut session, group, EpochId(candidate.epoch),
   now_ms, mode)` (`mgr:4777-4812`): member, stable at that very epoch, no
   pending input, no staged commit, nothing stranded, circle row stands, no
   away hold (leave, relay change, removal unmade, routing collision), no due
   departure.
6. `!self.holds_unread_input(group)` (`mgr:3873`) and not disbanded.
7. Targets: `fanout_targets(&session, group)` (`mgr:15216-15240`).

Passing → `sent[..] = now`, returned with its targets. `location_may_be_sent`
is private to `mgr`; `bridge_to_send` lives there too.

Nothing reaches the health model or the clock-skew detector: both read the
`RelayResult` (`api:7772-7788`), which the bridge drops; `send_location`
itself records neither (`relay/manager.rs:1028-1067`).

---

## G. Counters (§7.5)

`user_settings` (`st:1060-1063`, text key/value). Keys:
`mesh_from_circles_total`, `mesh_passed_on_total`, and — because "since
turned on survives a process restart" (plan §7.5) and the engine's
`passed_on` restarts at zero with the process — `mesh_from_circles_on`,
`mesh_passed_on_on`. The plan says "two integers"; the since-on pair makes
four. Q-5.

```rust
// circle/storage_mesh.rs
/// Adds to both pairs in one transaction.
pub(crate) fn add_mesh_counts(&self, from_circles: u64, passed_on: u64) -> Result<()>;
pub(crate) fn mesh_counts(&self) -> Result<MeshCounts>;      // four u64
pub(crate) fn zero_mesh_counts(&self, since_on_only: bool) -> Result<()>;
```

Fold points: end of every `mesh_drive` (`from_circles`, D.2 step 7); the FFI
wrapper after it (`passed_on` delta = `engine.stats().passed_on` − the value
at the last fold, kept in the slot); `mesh_stop` before the engine is
dropped. Mesh on zeroes the since-on pair; "reset" zeroes all four. Identity
delete removes the file (`api:1213-1242`); `check_identity_delete_prefs_residue.sh`
scans Dart `SharedPreferences` constants only (`scripts/ci/check_identity_delete_prefs_residue.sh:17-32`),
so it is touched in M3, when a native-readable mesh flag appears, not here.
Counts are returned to Dart as numbers and appear in no log, `Debug` or
error string.

---

## H. Engine home and FFI

### H.1 The slot

```rust
// api.rs, beside SESSION (api:12645-12660), same shape and rules.
struct MeshSlot {
    engine: MeshEngine<rand::rngs::OsRng>,
    handoff: Arc<haven_core::mesh::handoff::Handoff>,
    folded_passed_on: u64,
}
static MESH: std::sync::Mutex<Option<MeshSlot>> = std::sync::Mutex::new(None);

/// Runs `f` on the engine after applying the hand-off; `None` when mesh is
/// off or the lock is poisoned.
fn with_mesh<T>(now_ms: u64, f: impl FnOnce(&mut MeshSlot) -> T) -> Option<T>;
```

`with_mesh` is the only way to the engine: M3's `extern "C"` functions call
it too, so the FRB half and the radio half share the one static and every
entry applies the hand-off first. `unsafe` stays out of M2.

**Clock.** The engine wants a suspend-inclusive `now_ms` on every call
(`engine.rs:497-500`); M3's native layer supplies it. M2 has no radio, so
every FRB mesh function takes `now_ms: u64` from its caller, exactly as the C
interface will. haven-core and `rust_builder` read no clock for the engine.
Q-6.

### H.2 Functions

```rust
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MeshStartFfi { Started, AlreadyOn, Failed }

/// Turns mesh on: an engine in the slot, the hand-off installed in the
/// session, the setting stored, keys synced, since-on counts zeroed.
pub async fn mesh_start(circle: &CircleManagerFfi, now_ms: u64) -> MeshStartFfi;

/// Turns mesh off: counts folded, engine stopped and dropped, hand-off
/// removed, every stored key deleted.
pub async fn mesh_stop(circle: &CircleManagerFfi, now_ms: u64);

/// Empties every outbox slot: sharing was turned off.
#[frb(sync)] pub fn mesh_sharing_stopped(circle: &CircleManagerFfi);

pub struct MeshStatsFfi {
    pub on: bool,
    pub linked: bool,                 // stats().links > 0; never the count
    pub from_circles_since_on: u64,
    pub passed_on_since_on: u64,
    pub from_circles_total: u64,
    pub passed_on_total: u64,
}
pub async fn mesh_stats(circle: &CircleManagerFfi, now_ms: u64) -> MeshStatsFfi;
pub async fn mesh_reset_counts(circle: &CircleManagerFfi);

pub struct MeshDriveFfi {
    pub replayed: Vec<LocationMessageResultFfi>,   // as IngestOutcomeFfi, api:7543-7558
    pub errored: bool,
}
impl RelayManagerFfi {
    /// Reads what the mesh received and takes in what this device's circles
    /// sent. Nothing when mesh is off.
    pub async fn mesh_drive_driven(&self, circle: &CircleManagerFfi,
        foreground: bool, receive_completed: bool, now_ms: u64) -> MeshDriveFfi;

    /// Seals a fix for the mesh alone (§E).
    pub async fn seal_location_for_mesh_driven(&self, circle: &CircleManagerFfi,
        mls_group_id: Vec<u8>, location: &LocationMessage) -> Result<SealOutcomeFfi, String>;
}
```

`mesh_drive_driven` and the seal belong on `RelayManagerFfi`: they need
`Driving::new(&self.inner, circle, foreground).publishing()`
(`api:8308-8341`), the existing driven-call shape; Dart reaches them through
`CircleChangeDriver` like the other `*_driven` calls. Start, stop and stats
are free functions over the static, as the live-sync entries are. No packet,
packet id, key, epoch, group id or relay crosses: every field above is a
bool, a count or an existing typed result. New types get a redacting `Debug`
or none and an entry in `scripts/ci/debug_impl_allowlist.txt` as that guard
requires. `mesh_drive_driven` body: `with_mesh` → `take_unread(256)`; then
`publishing.mesh_drive(..)`; then `with_mesh` → `mark_read` each, fold
`passed_on`. The engine lock is never held across the `.await`.

`wipe_all_mls_state` (`api:1213`) gains, first, `MESH` emptied
(`engine.stop()`), as the live-sync engine is stopped before it.

Regeneration: `./scripts/regenerate_frb.sh`, then
`scripts/ci/check_generated_bridge_pinned.sh`'s hash.

---

## I. Compile-time define

`HAVEN_LIVE_SYNC` is a Dart const:
`const liveSyncEnabled = bool.fromEnvironment('HAVEN_LIVE_SYNC', defaultValue: true)`
(`haven/lib/src/providers/live_sync_provider.dart:29-32`); every app build
must declare it (`scripts/ci/check_live_sync_define_declared.sh:1-45`); the
branch the default leaves dead is re-run in a second unit pass
(`.github/workflows/coverage.yml:380-383`, `scripts/ci/check_coverage.sh:341-344`).

Mesh: `const meshEnabled = bool.fromEnvironment('HAVEN_MESH');` (default
`false`) in a new `haven/lib/src/providers/mesh_provider.dart`. Every Dart
call site (`meshStart`, `meshDriveDriven`, the burst's mesh-only pass) sits
behind it. The default build is the flag-off build, so no "declared in every
job" guard is needed until M5 flips the default; what is needed is the
mirror of the flag-off pass — one extra `flutter test <mesh test files>
--dart-define=HAVEN_MESH=true` step in `coverage.yml` and
`check_coverage.sh`, so the on-branch executes in a required gate. Per-path
coverage floors: the dead on-branch lowers a file's measured ratio; take the
flag as a constructor argument defaulting to the const (as
`receiveWithoutSession` is injected, `map_shell.dart:1822`) so the default
run covers both arms.

Rust has no define and needs none. With the define off Dart never calls
`mesh_start`, so `mesh_on` is never stored and the slot stays empty:
`mesh_offer` returns at its first line (`handoff` is `None`),
`sync_mesh_key` returns at step 1 (nothing derived, nothing stored),
`mesh_drive_driven` returns empty, `bridge_to_send` finds an empty book. The
only executed differences are three copied fields in `LocationToSend` and
one `user_settings` read at open. **T-INDEP-1 with mesh off therefore holds
by construction**; T-INDEP-1a's mesh-on half is the part that needs the run.
(A process that owns the session with `mesh_on` stored but starts no engine —
a catch-up worker — keeps the keys current and hands nothing off.)

---

## J. Tests

Run-time figures are estimates from the neighbouring tests' shape, not
measured.

| Test | Harness | Asserts | Est. |
|---|---|---|---|
| T-SEC-6 | new `tests/mesh_keys_e2e.rs` on `helpers::setup_two_party_group`, `advance_both` (`gates:165-196`), `CircleManager` with a real store | after each of: commit ingested, own commit confirmed, own commit rolled back, join, create, restart — the ring opens a packet sealed at the current epoch; a staged epoch's key is absent before the confirm and after the rollback; after 6 commits the oldest key no longer opens; restart keeps the retained ones; mesh off leaves no row | 6 tests, ~15 s |
| T-INDEP-1b | `tests/location_fanout_e2e.rs` (`ScriptedFanout`, `FixedClock`, `fan` `mod scripted`) | `publish_location` returns the same `LocationPublish` and the fixed clock has not moved with: no hand-off, a hand-off nobody drains, a hand-off whose every slot is full | ~3 s |
| T-INDEP-1c | new `scripts/ci/check_mesh_seams.sh` in `repo-guards.yml` + self-test | under `haven-core/src/relay` and `src/nostr`, `mesh::` appears only in `nostr/mls/mesh_keys.rs` and in the bodies of `mesh_drive` / `bridge_locations`; `mesh_offer(` is called once, in `publish_location`, before `.publish_location(`; `Instant::now` absent from `src/mesh` | < 1 s |
| T-SEC-7 | `location_fanout_e2e.rs`, `leave_fanout_e2e.rs:900-906` pattern | a publish answered `Superseded`, `Expired`, `Ended` leaves the hand-off empty; leave, epoch change, sharing-off, mesh-off empty a filled slot before the engine's next emission; mesh-off leaves no packet, record, unread or held entry | ~10 s |
| T-SEC-1 | new `tests/mesh_drive_e2e.rs`, two `CircleManager`s, packets built with the sender's ring | a packet whose signature byte is flipped under the right key opens, fails `verify()`, never reaches `ingest` (test-only ingest counter), is marked read | ~3 s |
| T-SEC-2 | same; commit from `update_relays` re-wrapped as `[h, expiration]` with a fresh key | commit, proposal and a non-location application message are dropped before the engine; the circle later takes the real commit from the relay path (no `T-COMMIT-BEFORE-PROPOSAL` stall) | ~5 s |
| T-SEC-5 | same | 1000 packets whose inner epoch is ahead: none reaches the engine; with a commit staged, nothing is ingested and the held list stays ≤ 256; per-circle cap 32 per drive | ~5 s |
| T-PERF-2 | same | AEAD opens per packet ≤ ring size | < 1 s |
| T-STAT-1 | same + `MeshEngine` pair over the sim's virtual link (`tests/mesh_sim/`) | both counters equal ground truth; a relay-first duplicate counts as opened but adds no location; own packets never counted; lifetime never decreases across a fold and a restart | ~5 s |
| T-BG-3 | same | packets past their lifetime in the unread queue are still read; past 8192 the oldest are gone | ~2 s |
| T-INDEP-3 | `tests/mesh_drive_e2e.rs` with `nostr-relay-builder` (as `live_plane_drive_e2e.rs`) | relay down: the location arrives by mesh and is stored once; relay up: the relay copy is `Seen`, one row | ~5 s |
| T-BG-2 (Rust) | `finish_only_e2e.rs` helpers | `seal_for_mesh` + publish → one packet in the hand-off, `location_call_count() == 0`, no commit row driven with a commit pending; mesh off → nothing sealed | ~5 s |
| T-BG-2 (Dart) | `haven/test/services/background_burst_coordinator_test.dart` | the four cases of the plan; the tests at `:476`, `:601`, `:621`, `:698-708` keep their meaning with mesh off and gain mesh-on twins | ~2 s |
| T-BRIDGE-1..8, 10, 11 | new `tests/mesh_bridge_e2e.rs`: three members, `ScriptedFanout` for 2/3/4/5/6/7/8/10/11, an in-process relay for 1 | as the plan lists; 8 also asserts the result type is dropped (no `Pass` field changes) | 11 tests, ~30 s |
| T-BRIDGE-12 | M3 (the enable flow does not exist yet) | — | — |
| T-INDEP-1a, T-BRIDGE-9 | `tooling/soak`: a mesh plane in `rig/plane.rs`, engines per device on the rig's logical clock, two scenarios after `s26` | as the plan; rig internals beyond the file list [U] | PR profile + [U] |
| gates | `gates` | surface list; a new `the_bridge_sends_once_and_reads_no_answer` source gate: `bridge_locations` contains one `.publish_location(`, `let _ =` before it, no `end_location`, no `Pass` | < 1 s |

---

## K. Documents, rules and guards changed with the code

Each location was opened; the sentence to change is quoted.

| Where | Now | Change |
|---|---|---|
| `CLAUDE.md:286` Rule 13.1 | "only the fanout driver … sends it" / kind-445 row `:314` "a location once per relay and never past its `expiration`" | add the bridge's one send of an event the device did not seal; the mesh carries a packet past its event's expiration, by design |
| `CLAUDE.md:297` Rule 16 | relay ingress only | add: a mesh packet's rebuilt event passes `verify()` before ingest |
| `CLAUDE.md` new Rule 17 | — | plan §8.2 text, plus "keys only while mesh is on" |
| `CLAUDE.md:278` Rule 5 | exporter secrets age out | add the mesh ring: same window, deleted at mesh off (and, with Q-1 = A, that it holds the exporter) |
| `CLAUDE.md:107` | "FFI does not expose Rust async streams; relay subscriptions use polling" | stale: `StreamSink<FfiRelayEvent>` exists (`api:12623-12624`) |
| `api:7612-7615` | "it is handed to `publish_location_driven` and to nothing else" | unchanged in fact with §E's design; add that the send may be mesh-only |
| `api:8605-8606` | "The sealed event goes to `Self::publish_location_driven` and nowhere else." | same |
| `haven/lib/src/services/circle_change_driver.dart:126-128` | "the sealed event goes to [publishLocation] and nowhere else" | same |
| `api:9117-9123` | "a commit, a proposal and a location leave the device only under a durable fanout record" | add the bridged event, which has none |
| `haven-core/SECURITY.md:482-494` | "this driver is the only way a commit or a proposal leaves the device" | add the bridge paragraph and its bounds |
| `haven-core/SECURITY.md:1693-1695` | "A burst that cannot start one publishes nothing (nothing is sealed before a receive has run)" | the mesh-only exception and its cost (plan §7.7 R1 (a)–(c)) |
| `background_burst_coordinator.dart:570-575` | "A burst that cannot receive publishes nothing" | same exception |
| `haven-core/src/nostr/mls/types.rs:563-592` | "a conformant relay has deleted the event by then" | the mesh redelivers for up to the packet lifetime and from the unread queue; the bound stays a heuristic and still applies only to application messages |
| `docs/privacy/privacy_invariants.json:2679` `INV-W-445-EXPIRATION-SCOPE`, `:4808` `INV-R-PER-CIRCLE-PUBLISH-DECORRELATED` (+ `haven-core/SECURITY.md:3982`, `:4318`) | — | scope notes; a new invariant for the relay-side inference of a bridge; one per promise of §J |
| `docs/MDK_UPSTREAM_TRACKER.md` | row format as `:60` | new row `T-MESH-EXPORTER` (past-epoch export, dedicated label) with its pinning test |
| `gates:1139-1157` doc, `gates:2992-3193` list | — | as §C.4 |
| `scripts/ci/debug_impl_allowlist.txt`, `check_no_identifier_logging.sh` | — | new types; a planted-identifier test for every new log line (the design adds **no** log line in haven-core) |
| `docs/BLUETOOTH_MESH_PLAN.md` §4.2, §5.2.4, §7.5, §7.7, §16 | — | F-1..F-4, the measured G-2, status |

---

## L. Split

Each lands with its tests green, `cargo clippy --all-targets -- -D warnings`
clean, and no item without a caller (every new item is reached by a test or
by `note_effects`).

| # | Scope | Files | Risk | What could break |
|---|---|---|---|---|
| **M2a** | `mesh/event.rs` (`parts_of`, `rebuild`), the G-2 test, the peeler-layout pin | `mesh/event.rs`, `mesh/mod.rs`, `tests/mesh_event_e2e.rs` | low | nothing existing; `check_debug_impls_covered.sh` if a type gains `Debug` |
| **M2b** | key ring + store + `mesh_keys` table + `mesh_on`; `sync` in `note_effects`; deletion hooks; T-SEC-6. Mesh is switched on in tests through `SessionManager::mesh_start(Arc<Handoff>)` | `nostr/mls/mesh_keys.rs`, `mgr`, `circle/storage_mesh.rs`, `st` (table, delete list), `cm:299/436`, `mesh/handoff.rs`, `tests/mesh_keys_e2e.rs`, `zeroization_security.rs` | **high** — secrets at rest; one line in the hottest function of the session | any test that counts `circles-v2.db` tables or statements (`rusqlite_statement_shape.rs`, `sync_state_at_rest_test.rs` [U]); coverage floors for `st`; needs security-reviewer + marmot-expert |
| **M2c** | hand-off: `LocationToSend` fields, `mesh_offer`, the line in `publish_location`, purge hooks, `MeshEngine::apply`; T-INDEP-1b/1c, T-SEC-7; the seams guard | `mgr`, `fan`, `mesh/engine.rs`, `scripts/ci/check_mesh_seams.sh`, `repo-guards.yml`, `location_fanout_e2e.rs` | medium | `gates:4815-4829` if the line lands after `let sent`; struct-literal sites of `LocationToSend` (one, `mgr:4731`) |
| **M2d** | `mesh_drive`, `ingest_from_mesh`, `class_under`, held list, counters; T-SEC-1/2/5, T-PERF-2, T-STAT-1, T-BG-3, T-INDEP-3 | `fan`, `mgr`, `cm`, `circle/storage_mesh.rs`, `gates` (surface list), `tests/mesh_drive_e2e.rs` | **high** — a new ingest plane | `process_event_staging`'s three callers (`relay/catchup.rs:1081`, `fan:4586`, `relay/live_sync/processor.rs:1593`) if the refactor changes `observe` |
| **M2e** | mesh-only seal: `seal_for_mesh`, the session mark, `LocationPublish::MeshOnly` | `fan`, `mgr`, `gates`, `finish_only_e2e.rs` | medium | every exhaustive `match` on `LocationPublish` in tests (`leave_fanout_e2e.rs:123`, `location_fanout_e2e.rs:156-168`) |
| **M2f** | bridging: `BridgeBook`, `bridge_to_send`, `bridge_locations`, T-BRIDGE-1..8/10/11, the Rule 13.1 text | `fan`, `mgr`, `gates`, `tests/mesh_bridge_e2e.rs`, `CLAUDE.md`, `SECURITY.md` | **high** — a second way out for a kind 445 | `gates:4633-4680` if a pending word enters the function |
| **M2g** | FFI + Dart behind `HAVEN_MESH` + burst coordinator + soak scenarios (T-INDEP-1a, T-BRIDGE-9) + Rule 17 and the remaining documents | `api`, generated bridge, `mesh_provider.dart`, `background_burst_coordinator.dart`, the two publish switches, `tooling/soak`, `coverage.yml`, docs | medium | the bridge hash pin; Dart exhaustive switches; soak budget in `e2e_lane_budget.manifest` |

M2e and M2f are independent of each other; both need M2c and M2d. If the FFI
variant `LocationPublishFfi::MeshOnly` must not exist before Dart handles it,
M2e keeps the core variant and M2g adds the FFI arm.

---

## M. Open questions and contradictions

| # | Question | Recommendation |
|---|---|---|
| **Q-1** (F-1) | What is stored per retained epoch? **A:** the group-event exporter `G_e` (K_mesh derived at load) — the application-only check then works for every retained epoch, across restarts; cost: a second at-rest copy of the kind-445 outer-layer key, in `circles-v2.db`, for the same window MDK's own snapshots cover, only while mesh is on. **B:** `K_mesh` only (the plan's words) — `G_e` is kept in memory; after a restart a packet opened under a past-epoch key cannot be classified and must be dropped, so persisting past keys buys nothing. **C:** nothing stored; ring in memory only (reverses the review finding in plan §13). | **A**, with security-reviewer and owner sign-off, since it goes beyond "a derivative" (plan §4.2) and beyond the reversed R-9/G-11. There is no way to keep the plan's storage and the plan's check together. |
| **Q-2** | T-INDEP-1c as written ("`mesh::` … only at the hand-off and the bridge") cannot hold with keys in `SessionManager` and `mesh_drive` in `fan`. | Guard scope of §J: one named file under `nostr/`, two named function bodies in `fan`, one call site for `mesh_offer`. |
| **Q-3** | The mesh-only mark: inside `SealedLocationFfi` (plan) or in the session keyed by the record (§E)? | Session: stronger, smaller diff. |
| **Q-4** | Where the bridge runs: inside the own-publish FFI call (delays that call's answer by up to one location send when a candidate exists) or as a second call. And does it require the own publish to have been *accepted*, or only *made*? | Inside, after `Sent(_)` (the plan's "rides the same circle's own publish"); owner to confirm "made" vs "accepted". |
| **Q-5** | "Two integers" (§7.5) vs since-on surviving a restart. | Four keys in `user_settings`. |
| **Q-6** | The engine's clock before M3. | `now_ms` is a parameter of every FRB mesh call; M3's native layer is its only real source. No clock read is added in Rust. |
| **Q-7** | Where "mesh is on" lives. Keys must be maintained by whichever process owns the session (foreground, Android service, catch-up worker), including ones that start no radio. | `user_settings 'mesh_on'`, read at session open. M3's native-readable flag mirrors it; a mismatch heals at the next `mesh_start`. |
| Q-8 | Purge on "hold": the plan lists it; holds arise in many places. | §C.3's conservative rule: any state-bearing batch purges the circle's slot. |

Smaller contradictions with the code, already folded in above:

- Plan §2.1 cites `process_event_staging` at `manager.rs:3075`; it is at
  `mgr:3067`. `seal_location` and `publish_location` are where it says.
- Plan §5.5 says today's verdict folds outcomes together at
  `relay/catchup.rs:1327-1332`; correct (`:1326-1332`), and the mesh plane
  does not use that function at all.
- Plan §4.2 "at most 10 circles × 6 epochs": no ten-circle limit was found
  in the code [U]; the bound is the ring's size, whatever the circle count.
- Plan §10 lists T-BRIDGE-1..9 for M2; T-BRIDGE-10 and 11 are core-only and
  land with M2f; T-BRIDGE-12 needs M3's enable flow.
- `MeshEngine::offer` takes `expires_ms` on the engine's clock while an
  event's expiration is wall time; the conversion is done by the engine's
  owner at apply time (§C.2), which the plan does not state.


---

## Review findings (Opus 5.5, 2026-11-11) — these override the body

The review checked the design against the code at `1c7aac4` and MDK `fcc85ed`
and found its reading of the code sound. To fold in before the named step:

| # | Severity | Finding | Change | Before |
|---|---|---|---|---|
| 1 | HIGH | Android bridging breaks receive-first: a candidate made at tick N is sent at tick N+1, whose publish runs before that tick's fetch, and `caught_up` still reads true. A member removed between the ticks can then read an offline member's fix from the relays. | Tie each candidate to the drive that made it; send only from a drive whose receive has completed. On Android: a bridge step after the fetch, or no Android bridging. | M2f |
| 2 | MEDIUM-HIGH | `mesh_drive` can send to relays: step 5d calls `Publishing::settle` → `drive_rows` / `send_unrecorded`; taking in a mesh packet can hand back stranded relay input and record a commit, so a relay publish is timed by a nearby mesh packet. | No `settle`, no `drive_rows` in `mesh_drive`: only dispose the location results; recorded rows wait for the next relay drive. Pin with a zero-transport-call assertion on `mesh_drive`. | M2d |
| 3 | MEDIUM | The key ring can wrap with, and keep, a key from an abandoned branch (two keys for one epoch number). | Sync the key inside `location_to_send`'s engine hold and wrap with the newest entry; drop a circle's past entries on `GroupStateInvalidated`, `CommitRolledBack`, `GroupStateRevalidated`; one key per epoch number; add same-height reselection, routing-id rotation and several epochs in one engine call to T-SEC-6. | M2b |
| 4 | MEDIUM | "Updates from your circles" over-counts: held packets are re-opened and re-counted every drive. | Count only freshly taken packets, or flag held entries as counted. | M2d |
| 5 | MEDIUM | One circle can starve the others' held packets (one global cap). | A quota per circle; an `Err` from the mesh ingest is Held, never read. | M2d |
| 6 | MEDIUM | The relay path can block on a database write: the key sync writes rows under the mutex `mesh_offer` takes inside `publish_location`. | Write after releasing the lock, or `try_lock` in `mesh_offer` and drop the offer on contention. | M2c |
| 7 | MEDIUM | A reopened session loses its hand-off (installed only by `mesh_start`). | Re-install on `AlreadyOn` and whenever a session opens while the slot exists. | M2g |
| 8 | LOW | Leftover key rows at open with mesh off; a fixed-text `Err`; `MeshEngine::apply` wanting a wall clock; fields introduced before the step that uses them. | Delete at open; fixed text; see Q-6; introduce fields with their step. | — |

Gate amendments were judged sound: the surface list gains `seal_for_mesh`,
`mesh_drive`, `bridge_locations`; the function-scoped gate and
`assert_a_completed_location_send_is_never_made_again` still hold with the
hand-off before `let sent`. Rules 14 and 15 hold as designed.

### Answers to the open questions

- **Q-1 (owner's decision).** The premise holds: classifying a packet as an
  application message needs the group-event exporter `G_e`, MDK exposes it for
  the current epoch only and has no preview API. Recommended: store `G_e` per
  retained epoch (derive `K_mesh` from it on load). MDK's own database already
  holds full snapshots of exactly those epochs and both databases are keyed
  under one keyring service, so the added at-rest exposure is nil in practice;
  it needs finding 3 and Q-7 for Rule 5. The alternative that stores nothing
  more: peel every packet with the current `G` only — drop it if it peels and
  is not a current-epoch application message, and hand it to the engine
  unclassified if it does not peel. That gives an attacker nothing the relays
  do not, but it breaks the written promises "checked at both ends" (§4.3,
  Rule 17) and T-SEC-5, and can cost snapshot restores and deferred rows.
- **Q-2.** Guard wording: under `src/relay` and `src/nostr`, a path naming
  the mesh module appears only in `nostr/mls/manager/mesh.rs` (a child module
  of `manager`, re-exporting nothing) and, in `relay/fanout.rs`, only inside
  the bodies of `mesh_drive`, `bridge_locations` and
  `publish_location_and_bridge`; `mesh_offer(` occurs once, inside
  `publish_location`, before `.publish_location(`; `relay/manager.rs`,
  `relay/live_sync/`, `relay/catchup.rs` and `relay/verified.rs` name no mesh
  item. With a mutation self-test.
- **Q-3.** Keep the mesh-only mark in the session, as a per-entry value in
  `own_locations`, not a second set. A restart is safe: a new process answers
  `Superseded`.
- **Q-4.** Bridge only after the own send was accepted by at least one relay,
  and only to the relays that accepted it.
- **Q-5.** Two lifetime totals plus two "at turn-on" baselines; amend plan
  §7.5's "two integers".
- **Q-6.** Do not take `now_ms` from Dart. One suspend-inclusive source read
  in Rust for every entry (`clock_gettime` `BOOTTIME` on Android/Linux,
  `MONOTONIC` on Apple, via `rustix`, already locked; a direct dependency
  needs dependency-auditor; confirm Apple semantics at implementation).
- **Q-7.** Store a deadline, `mesh_on_until` (now + 12 h at most), not a
  flag; every reader treats an expired deadline as off and deletes key rows.

Extra test demanded for M2d: a member re-wraps a current-epoch commit under a
past epoch's mesh key, and a commit ahead of its proposal under its own
epoch's key — no ingest, zero relay sends from `mesh_drive`, and the circle
still converges through the relay path.
