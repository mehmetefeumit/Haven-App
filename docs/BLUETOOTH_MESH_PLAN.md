# Haven Bluetooth Mesh — Implementation Plan

> Status: **PLAN — no implementation. Reviewed 2026-11-10.**
> Process: four research streams (this codebase; bitchat's source at both
> repos' heads; platform and CI facts; cryptography and metadata privacy)
> produced the draft. Three independent reviewers (protocol/security,
> platform/background/UX, Rust architecture/CI) then checked it against code
> and primary sources. Their two blockers and fourteen HIGH findings are folded
> in; §13 lists what changed.
> Supersedes the wire format, relay algorithm, UI placement and test strategy
> of `docs/MESH_LOCATION_RELAY_DESIGN.md` (§0.3).
> **Owner decisions of 2026-11-10** on packet lifetime (D-1), auto-off (D-3)
> and background reliability (D-8) are recorded in §11 and designed in §6.4,
> §7.6 and §7.7; §14 lists what they changed. Those edits had their own
> independent review; its three HIGH findings are folded in (§14).
> Evidence tags: **[V]** read from a primary source or this repo's code;
> **[V2]** secondary source; **[U]** unverified — every [U] the plan depends
> on is a gate in §11, never an assumption. Code citations are at `f1dd146`.

## 0. Summary

### 0.1 What is built

An opt-in, default-off second carrier for the location updates Haven already
seals. With mesh on, a phone:

1. wraps each location event the relay path is about to send in a fixed-size,
   fully opaque 1024-byte packet and puts it in a local store;
2. exchanges store contents with nearby mesh phones over Bluetooth LE, in both
   directions, whether or not it can read them;
3. tries to open every new packet with its own circles' mesh keys, and feeds
   what opens into the normal MLS ingest.

The phone's own relay publishing is unchanged, mesh on or off. One thing is
added to what it sends to relays: a fellow member's update it received by
mesh (member bridging, §5.5).

### 0.2 The decisions that shape everything

| # | Decision | Why |
|---|---|---|
| 1 | A packet has **no cleartext field**: no version, hop count, timestamp, id or tag. It is 12 random bytes + ciphertext + 16-byte tag. Its remaining lifetime travels beside its id on each link (§6.4, owner-directed). | Requirement F1. A hop count is "how far it comes from"; a timestamp is age, hence distance; a circle tag links a circle's packets. bitchat exposes sender id, recipient id, timestamp and TTL and calls metadata "the weakest part of this design" [V]. |
| 2 | The packet wraps the **complete signed kind-445 event** under a mesh key derived from the circle's MLS epoch. Never the bare MLS message. | A bare `PrivateMessage` shows `group_id` and `epoch` in clear (RFC 9420 §6.3) — the real MLS group id (Rule 4). The kind-445 `h` tag is a permanent per-circle id [V]. MDK's ingest needs the verified event [V]. |
| 3 | **One seal, two carriers.** The mesh takes the event the relay path sealed and passed its send-time check; it never seals. | No extra ratchet use, except the mesh-only seals of §7.7 R1. The engine dedups the relay copy and the mesh copy as one message, in either arrival order [V]. |
| 4 | **All protocol logic is one sans-IO Rust state machine** (`haven_core::mesh::MeshEngine`); Kotlin and Swift only move bytes. | The only layer CI can test deterministically on every push. Neither bitchat app has multi-device radio tests in CI [V]. |
| 5 | **The engine holds no key.** Wrapping and opening happen in the MLS session's own code; the engine stores and forwards opaque bytes. | Forwarding cannot depend on recognition by construction; no key material is reachable from the native radio interface. |
| 6 | **Forward-all-opaque, flood by inventory, fixed emission schedule with cover packets; every link wrapped in an anonymous Noise session.** | No per-packet routing state. Membership-dependent forwarding would be a co-membership oracle. |

### 0.3 Withdrawn from `MESH_LOCATION_RELAY_DESIGN.md`

- "Option B" payload (bare MLS message): leaks the MLS group id and epoch.
- The frame `[type][ttl][mesh_msg_id][freshness]`: three cleartext fields.
- Its rule "never cache exporter-derived secrets" (R-9/G-11): knowingly
  reversed — the mesh keys for retained epochs are stored (§4.2).
- Top-right toggle: the owner now specifies bottom-left.
- Opt-in internet bridging by any carrier: replaced by member bridging
  (§5.5, D-7). A phone that cannot open a packet still never bridges it.
- Simulator "routing only": replaced by §9.

Its threat analysis (radio localisation, crowd counting, tracking,
forward-all-opaque, photos excluded) stands and is carried into §8.

### 0.4 What this plan cannot promise — read before approving

**Platform**

1. **Two locked iPhones that have never met will not reliably find each
   other**, and an Android phone cannot find a locked iPhone. This is Apple's
   design (§7.2). No CI can prove any iOS radio behaviour.
2. **An iPhone with background sharing off relays on a best-effort basis in
   the background.** iOS suspends the app and runs it for about 10 s per
   Bluetooth event; it may throttle an app woken often (§7.7, D-11). An
   Android phone in the same state forwards whenever traffic arrives, at a
   battery cost (§7.7). CI emulators never sleep, so sleeping-phone behaviour
   is proved only on hardware, which the project does not have
   (`POWER_EFFICIENCY_PLAN.md` §2.5).
3. **With Haven not running in any form** (after boot, or after the system
   killed it, with background sharing off) the phone relays others' packets
   and emits cover packets but sends no location of its own and reads none
   until Haven is opened (§3).
4. **On iOS, switching Bluetooth off in Settings or force-quitting Haven ends
   mesh** until Haven is opened; on iOS 26 a Control Centre toggle or Airplane
   Mode does too [V, TN3115].
5. **Every battery figure is ESTIMATED** (model E), never measured.

**Privacy**

6. **Anyone in radio range can tell a phone runs Haven with mesh on**, count
   such phones, direction-find them, and — by connecting — **re-identify a
   phone after its Bluetooth address rotates** from the set of packets it
   holds. Content, circle and identity stay hidden; presence and movement
   between crowds do not.
7. **A neighbour that is a phone's only link knows which packets that phone
   emitted.** It cannot read them or tell a real update from a cover packet.
   Hiding origin from a lone neighbour is not possible.
7a. **A connected neighbour learns each
   packet's age to within about five minutes**, from the remaining lifetime
   announced with it (§6.4), and so roughly how long it has travelled — not
   from where, whose it is or what it says. A very young packet is more
   likely the announcing phone's own, and about 1 own packet in 67 shows a
   value no carried packet shows between honest phones. This is the price of
   packets that expire everywhere (D-1).
7b. **A removed member can read fixes sealed before the phone learned of the
   removal**, for as long as the phone cannot reach a relay (§7.7).
8. **Whether a phone is asleep is observable** from its emission rhythm. (A
   review found that sending real updates only would let a neighbour who also
   watches the public relays tie a phone to its circle by timing; the fixed
   schedule with cover packets, D-2, is what prevents that.)

**Function**

9. **A flooding mesh has a size ceiling** (§6.6).
9a. **Mesh turns itself off 12 hours after it was turned on or last
    confirmed** (§7.6). An unattended phone stops relaying and sending by mesh
    then. On an iPhone that iOS has suspended, no packet moves after the
    deadline, but the phone may keep advertising its presence until iOS next
    runs Haven.
10. **A circle is silent on mesh while the relay path would hold it**: a
    commit awaiting a relay acknowledgement (including one Haven makes itself,
    such as a departure eviction), a leave in progress, a disbanded circle, a
    routing collision, an unread fetched commit. Offline, most of these last
    until a relay is reachable (list in §5.4).
11. **The mesh carries no commits**, so a member who missed an epoch change
    cannot read members who took it, until relays return.
11a. **Member bridging reaches a hop or two.** A fellow member's update can
    be passed to the relays only within 218 seconds of its sealing (§5.5).
    When it happens, a relay can infer that some member of that circle is
    offline and within mesh reach of the bridging phone's network address;
    when the sender is online too, the same event from two connections links
    their addresses. Bridging stops at the first epoch change the offline
    sender misses, and never carries a mesh-only seal (§7.7 R1), so a
    backgrounded iPhone in those cases is not bridged.
12. **After about 1000 location updates from one sender that a receiver never
    got** (about 20 h at the fastest cadence), that sender is unreadable to
    that receiver until the epoch changes, which needs relays [V, OpenMLS
    forward-distance limit]. This exists today on the relay path; long
    outages make it reachable.

---

## 1. Requirements traceability

| Req | Text (short) | Where met | Proved by (§9.3) |
|---|---|---|---|
| F1 | Encrypted always; intermediaries learn nothing about whose, where, how far; minimal metadata | §4, §5, §6, §8 | T-PRIV-* |
| F2 | Ongoing notification while mesh is on — when the user allows notifications (D-9) | §7.1, §7.2 | T-NOTIF-* |
| F3 | Least power without degrading function | §7.3 | T-PWR-*, ESTIMATED model |
| F4 | Hold the button: circle updates received / updates relayed for others; session and lifetime | §7.5 | T-STAT-* |
| F5 | The phone's own relay publishing unchanged with mesh on or off | §3, §5.1 | T-INDEP-* |
| N1 | Reliable CI incl. end-to-end on every run | §9 | the lanes |
| N2 | Bluetooth attack surface handled | §8 | T-SEC-*, scripted adversary |

---

## 2. Background the design rests on

### 2.1 Haven today [V]

- A location is sealed and published in two Rust calls. `Publishing::
  seal_location` (`haven-core/src/relay/fanout.rs:4660`) returns
  `LocationSeal::Sealed { event, .. }` (`:3167`): a signed kind-445 with tags
  `h` then `expiration = created_at + min(declared, 228)`.
- `Publishing::publish_location` (`fanout.rs:4791`) re-checks immediately
  before the one send: `Expired` if the event is spent, `Superseded` if
  `!record.may_be_sent` (`:4814-4821`) — still a member, same stable epoch,
  no pending input, no staged commit, no leave or hold
  (`haven-core/src/nostr/mls/manager.rs:4777`).
- The sealed event is opaque to Dart (`SealedLocationFfi`,
  `haven/rust_builder/src/api.rs:7617`).
- Sealing has no connectivity precondition in the foreground scheduler and
  the Android foreground service; an unreachable publish ends the record
  (`location_sharing_service.dart:401-424`, `background_location_task.dart`).
  **An iOS background burst seals nothing when it could not receive first**
  (`background_burst_coordinator.dart:568-584`).
- Ingest through the driver: `Publishing::ingest_for_poll` (`fanout.rs:4574`)
  → `SessionManager::process_event_staging` (`manager.rs:3075`) → MDK. Haven's
  ingest does not screen on NIP-40 expiration (`manager.rs:3015-3026`); only
  the relay pool does.
- The application-message tag layout is exactly `[["h",hex],["expiration",dec]]`
  and the content is padded standard base64, so an event rebuilt from its
  fields is byte-exact [V, MDK `transport-nostr-peeler/src/peeler.rs:136-163`].
- MDK exposes the group-event exporter secret for the **current epoch only**
  (`cgka-session/src/lib.rs:793`); while a commit is staged it returns the
  staged epoch's. Haven already reads it in production
  (`manager.rs:3154-3158`).
- One live MLS session per DB (Rule 14), process-global registry.
- No Bluetooth permission, plugin or code exists; no notification code beyond
  `flutter_foreground_task`'s; the bottom-left of the map is empty in
  left-to-right layouts; `MapControls` is pinned bottom-right and
  deliberately not mirrored (`map_page.dart:654-662`).
- `check_no_committed_secrets.sh` fails on any canonical-form UUID in any
  tracked file, with an empty allowlist (`:36-39`).

### 2.2 bitchat [V, iOS `04995f68`, Android `14ab73c4`]

Borrowed: dual role, one service and one characteristic, write-without-
response + notify, RSSI-gated connection budget, pending connects and state
restoration for iOS background, per-type size caps before allocation, an
in-memory multi-node simulator.

Rejected: cleartext header, static identity keys and Noise XX, stable peer id
in the Android scan response, neighbour lists, padding only for some types,
compression (decompression bombs: Bridgefy 2022; bitchat-android's own review),
relaying unauthenticated variable-size types.

Licence: the iOS repo is public domain; the Android repo is GPL-3.0. No
Android code is copied.

### 2.3 Platform facts

- iOS background: scans need explicit service UUIDs, are slower and report
  each peripheral once; background advertising drops the local name and moves
  service UUIDs to an "overflow area" only iOS devices scanning for that UUID
  can match; ~10 s per background wake [V, Apple background guide]. A
  non-Apple central cannot decode the overflow area (Apple engineer, [V2]).
- iOS state restoration: no relaunch after force-quit or the Settings
  Bluetooth switch; from iOS 26 only AccessorySetupKit apps relaunch after a
  Control Centre toggle or Airplane Mode [V, TN3115].
- iOS has no non-dismissable notification. A Live Activity needs a widget
  extension, iOS 16.1+, a foreground start, and ends after 8 h [V].
- Android: `connectedDevice` foreground services have no time limit and may
  start from `BOOT_COMPLETED` on Android 15, given a granted Bluetooth
  runtime permission [V]. A foreground service keeps the process, not the
  processor, awake; alarms in Doze fire at most about every nine minutes [V].
- Android screen off: an unfiltered scan is not started; a filtered
  `LOW_POWER` scan runs at 512 ms / 10.24 s [V, AOSP via LineageOS mirror].
- Android 14+: an ongoing notification can be swiped away except on the lock
  screen; the service keeps running [V].
- Android 10–11: a scan from a service needs background location; API 23–30
  needs Location switched on [V].
- Android Emulator ≥ 33.1.4 shares one virtual BLE medium (netsim) per host;
  Bumble can join it as a scripted peer [V2]. This repo records that several
  emulators thrash on hosted runners (`synthetic_user.dart:9-18`).
- `std::time::Instant` does not advance while the phone sleeps [V].

---

## 3. Architecture

```
 Dart (session-owning isolate)             Rust
┌───────────────────────────┐   ┌─────────────────────────────────────────┐
│ MeshButton, stats sheet   │   │ relay::fanout::publish_location         │
│ MeshController (Riverpod) │   │   after may_be_sent ── mesh::offer() ─┐ │
│ calls mesh_drive each     │◄─►│ Publishing::mesh_drive (session code) │ │
│ drive                     │FRB│   opens untried packets → ingest      │ │
└───────────────────────────┘   │   mesh keys: SessionManager + SQLCipher│ │
                                │                 wrapped 1024-B packet ▼ │
┌───────────────────────────┐   │ mesh::MeshEngine  (keyless, sans-IO)    │
│ Kotlin MeshService (FGS)  │◄─►│   store · links · inventory · limits    │
│ Swift  HavenMeshRadio     │ C │   one instance in a slot in rust_builder│
│ advertise · scan · GATT   │ABI└─────────────────────────────────────────┘
└───────────────────────────┘
```

- **`MeshEngine`** is an owned state machine. Inputs: `now` (suspend-inclusive
  milliseconds supplied by the caller), link up/down, an inbound frame, an
  offered packet, an injected `RngCore`. Outputs: frames per link,
  connect/disconnect decisions, the next wake time. No threads, sockets,
  statics, clock reads or keys. Link-budget and RSSI policy live in it.
  Production holds one instance in a slot in `rust_builder` (as
  `LiveSyncCore` does, `api.rs:12660`) with `OsRng`; tests and the soak rig
  create as many as they need with seeded generators.
- **Native radio modules** call a small poll-style C interface (byte slices in
  and out, no callbacks) exported from `rust_builder`. This is Haven's first
  hand-written `extern "C"`/JNI surface: the shim is logic-free, `unsafe` is
  confined to it, the `jni` crate becomes a direct dependency, and a parity
  guard pins the Kotlin, Swift and Rust declarations against each other.
  `HavenApplication.onCreate` already loads the library in every process
  start, with or without a Flutter engine [V].
- **Session code** owns everything that needs a key: wrapping at hand-off and
  `Publishing::mesh_drive`, one driven call the session owner makes at every
  drive, which opens packets the engine has not yet offered, ingests what
  opens and folds the counters.
- **Independence (F5).** The mesh's contact with the relay path is one
  call, `mesh::offer` (plus the mesh-only mode of §7.7 R1, which adds no
  relay traffic), inside `publish_location` after the `may_be_sent`
  check and before the relay send. It is synchronous, does no I/O, cannot
  fail or block, and returns `()`. Member bridging (§5.5) is the one other
  place the mesh meets the relay layer. A guard allows `mesh::` to be named
  in `relay/` and `nostr/` at those two sites only.
- **Clock.** The native layer supplies a clock that keeps counting during
  sleep (`elapsedRealtime` / `mach_continuous_time`). `Instant::now()` is
  banned in `mesh::` by a guard. Every engine entry point first advances to
  `now`.

No Flutter BLE plugin: none offers dual role with both-manager state
restoration, two are central-only, one needs a commercial licence [V]. No Rust
crate offers the peripheral role on mobile [V].

---

## 4. Packet and keys

### 4.1 Layout

```
packet     1024 B   every byte indistinguishable from random to a non-member
  nonce      12 B   fresh from the CSPRNG per packet
  ct        996 B   ChaCha20-Poly1305(K_mesh, nonce, AAD = "haven/mesh/v1")
  tag        16 B

plaintext   996 B
  format      1 B   0x01 = tag layout [h, expiration]; 0x02 = the same, and
                    the event passed the sender's send-time check and is
                    not mesh-only (§5.5)
  pubkey     32 B   the event's ephemeral key
  sig        64 B
  created_at  8 B
  expiration  8 B
  content_len 2 B
  content   ≤881 B  the kind-445 content, base64-decoded
  padding           zero; the opener verifies it is all zero
```

- Integers are big-endian.
- The recipient rebuilds the event with `h` from the circle whose key opened
  the packet, recomputes `id`, and calls `Event::verify()`. A packet opened
  under the wrong circle's key fails there, because `id` binds `h`.
- A test re-read at every MDK bump pins the tag layout that formats `0x01`
  and `0x02` mean.
- A cover packet is 1024 CSPRNG bytes.
- One size. An event that does not fit is not sent over mesh. Measured in a
  real circle: 546 bytes of content for an ordinary location and 595 for the
  largest the type can serialise, against the 881 limit; a test fails if it
  passes 700 (G-2).
- Packet id = `SHA-256(packet)[..16]`, computed locally.
- The engine never parses, decompresses or allocates from packet contents.
- The service UUID is held as 16 raw bytes in Rust and the platform UUID is
  built at run time; no canonical-form UUID is committed.

### 4.2 Keys

`K_mesh,e = HKDF-SHA256(salt = "haven/mesh/v1", IKM = G_e, info = "packet-aead", 32)`,
`G_e` being the circle's `marmot/group-event` exporter secret at epoch `e`.

- Derived **inside `SessionManager`, under the engine hold, after every engine
  call that can change the epoch**. Never returned to Dart.
- Kept per circle for the current epoch and up to 5 past epochs, pruned in
  step with the engine's retention (Rule 5), in memory under `Zeroizing` and
  **in the SQLCipher store**, so a process restart does not lose the keys for
  peers who are still on an older epoch.
- **What is stored is `G_e` itself** (owner-directed 2026-11-11), and
  `K_mesh` is derived from it on load. The receiver's check that a packet is
  an application message (§4.3) has to remove the kind-445 outer layer, which
  only `G_e` does, and MDK hands out `G_e` for the current epoch alone. MDK's
  own database already keeps full snapshots of the same epochs and both
  databases are keyed under one keyring service, so the copy adds nothing an
  attacker who can open one could not already reach. It is written only while
  mesh is on, deleted when mesh goes off, on leave, disband and identity
  delete, and never crosses the FFI.
- A key read while a commit is staged is the staged epoch's: it is installed
  only when the commit is confirmed and discarded on rollback.
- Receivers try every stored key: at most 10 circles × 6 epochs = 60
  Poly1305 checks per new packet. No recognition tag.
- **Residual:** epochs crossed inside one engine call, or before the feature
  was first enabled, have no key. Tracker row `T-MESH-EXPORTER` asks MDK for
  past-epoch and dedicated-label export (`MLS-Exporter("marmot",
  "haven-mesh-v1")`, the textbook form, RFC 9420 §8.5).
- **Rule 11** is untouched: the kind-445 label and derivation are unchanged
  and `with_exporter_label` is still never called. Its nonce half applies to
  the new layer: a fresh CSPRNG nonce per packet, and a re-broadcast is the
  same bytes.
- Non-key-committing AEAD is not a problem here: keys are uniformly random,
  nothing on air shows whether an open succeeded, and `verify()` binds the
  circle [reviewed].
- Rejected: MDK's safe exporter (needs a new required group component — an
  admin commit per circle and no interop with other Marmot clients).

### 4.3 What the mesh carries — enforced at both ends

Only application messages. **Producer:** `mesh::offer` is reachable only from
`publish_location`. **Receiver:** after open and `verify()`, a preview-peel
(`project_mls_message`, `manager.rs:3180`) drops anything that is not an MLS
application message. Without the receiver check, a malicious member could
deliver a re-wrapped commit ahead of its proposal and stall the victim's
circle for good (tracker `T-COMMIT-BEFORE-PROPOSAL`).

---

## 5. Sending and receiving

### 5.1 Send

1. `publish_location` passes its checks. If mesh is on, `mesh::offer` wraps
   the event under the key of its seal epoch and places the packet in the
   engine's outbox slot for that circle (newest wins). The slot is an opaque
   local number; the engine learns nothing about the circle.
2. An outbox entry is single-use; it is purged at its event's own
   `expiration`, on any epoch change for its circle, and on leave, hold,
   sharing-off, mesh-off and identity delete.
3. The engine emits **one packet per emission slot** (default 90 s ± 30 s
   from its generator, the same parameters on every phone): the outbox entry
   of the least-recently-served circle, or a cover packet (D-2, decided).
4. The emitted packet goes into the store like any other, with its record
   (§6.4), and reaches peers only through §6. There is no "send now" path.
5. After sleep the engine emits at most one packet on waking, whatever the
   outbox holds.

So a neighbour sees one new opaque packet per slot from every awake phone
and cannot tell whether it shares, with how many circles, or whether a given
packet is real; and the slot times are independent of the times the relays
see, so the two cannot be matched. Cost: with `k` sharing circles each
updates every `k × 90 s` on mesh; every phone adds load (§6.6); "passed on"
counts cover packets.

Turning mesh off, and deleting the identity, drop the store, the records, the
outbox and the unread queue at once.

### 5.2 Receive

1. The engine accepts a packet only if it asked for it on that link (§6.3).
   New id → stored and announced to other links, always.
2. At each drive `mesh_drive` takes the packets not yet offered to it, tries
   the keys, rebuilds, verifies, applies §4.3, and hands the event to the
   driver's ingest for its circle through `order_for_ingest`.
3. The mesh plane owns no relay cursor, touches no `relay_floors`, records
   nothing where the relay path reads what it has seen (the NIP-77 pass
   still asks a relay for an update the mesh brought first), and arms no
   history walk: only a full relay drive's ingest arms one. A peer's update
   it brings does end the `Stalled` reading, which moves no walk (§16).
4. Bounds: a per-circle cap on events per drive and a drain budget; nothing
   is drained into a circle held for a pending commit (it would grow the
   engine's uncapped buffer, Rule 12). A packet is marked done only when the
   engine took the event in; otherwise it is offered again while held.
5. Packets not yet offered to `mesh_drive` are kept in a bounded local queue
   (default 8192, oldest dropped) even after their lifetime ends, so a
   phone whose app was not running can still read what passed through it.

A copy that arrived first by relay is a duplicate in the engine: silent.

### 5.3 Freshness

No time inside a packet. Members judge staleness on the MLS-authenticated inner
timestamp as today; the 15-minute `expires_at` and 24 h last-known retention
apply unchanged. An authentic packet replayed later or elsewhere is a
duplicate, or shows as stale.

### 5.4 When a circle is silent on mesh

When the relay path would not send: `SendHeld::AwaitingRelays`,
`StagedWithoutRecord`, `DepartureDue`, `AwaitsForeground`, `RemovalUnmade`,
`Leaving`, `Disbanded`, `RoutingCollision`, `StoredInput`
(`fanout.rs:2967-3021`), plus `Expired`/`Superseded` at publish. Nothing
observable changes on air: the slot carries another circle's update or a
cover packet.

**iOS background:** today a burst that could not receive seals nothing in two
cases (§7.7 R1). With mesh on, such a burst now seals for the mesh only
(D-8, decided).

---

### 5.5 Member bridging (D-7, decided)

When a circle member's phone receives a fellow member's update over the mesh
and has a working relay path, it publishes that same event to the circle's
relays, so members far away can see someone who has no internet. A phone
that cannot open a packet cannot bridge it: it knows neither the relays nor
the routing id.

- **Which events.** Only one that `mesh_drive` ingested and the engine
  answered as a new, authenticated application message — `Processed` with a
  `MessageReceived` for this event's id, carrying a location. Not a
  duplicate (a relay already delivered it), not an own echo, not buffered,
  stale or rejected. Today's receive verdict folds these together
  (`relay/catchup.rs:1327-1332`), so the mesh ingest gains one typed answer.
- **The sender's mark, per event.** Envelope format `0x02` says the event
  passed the sender's send-time check and is not mesh-only. Format `0x01`,
  which mesh-only seals (§7.7 R1) always carry, is never bridged: bridging
  one would hand the relays an event the sender's phone refused to send
  them. The value sits under the mesh key, so a member could flip it — but a
  member can already publish the event itself; it binds honest phones.
- **Receive first.** A phone bridges only in a drive in which its relay
  receive for that circle completed, with the mesh ingest ordered after it;
  if the receive failed it bridges nothing. Otherwise a bridger that had not
  yet fetched a removal — the Android service publishes before it fetches —
  would hand the removed member an offline sender's fix through the relays,
  anywhere, where today it reaches them only within mesh range.
- **The bridger's own check, at the moment of sending.** A candidate is held
  in memory until the same circle's own publish. Immediately before the
  send, in one engine hold: `location_may_be_sent` holds for the event's
  epoch (`manager.rs:4777-4812`), the circle is not disbanded, leaving,
  holding unread input or in a routing collision, and the targets are read
  (`fanout_targets`, `manager.rs:15216`). So a bridger that took in a
  removal after ingesting the packet does not bridge it.
- **The window, both ends.** Never when `location_is_spent`
  (`fanout.rs:2679`): the send begins at most `min(declared, 228) − 10`
  seconds after `created_at` — 218 s at most — by the bridger's clock. Also
  never when `expiration − created_at` exceeds 228 s or `created_at` lies
  ahead of the bridger's clock by more than the send window, so a member
  cannot make honest phones publish an event stamped for the future or for
  years. The expiration is inside the signed event; nothing can extend it.
- **How.** One attempt per relay through `FanoutSend::publish_location`
  (`fanout.rs:825-829`), on the verified, signer-less publish client
  (Rule 16), in a function of its own. No record, no retry, no confirm; a
  bridge interrupted by a kill is lost. Its result goes nowhere — not to the
  health model, and not to the clock-skew detector, which would otherwise
  blame the bridger for the sender's clock. It rides the same circle's own
  publish, so it never wakes the publish pool by itself.
- **Bounds.** Per circle and sender: the newest update only, at most one per
  72 s; plus a total per drive. The sender is MLS-authenticated, so a member
  flooding the mesh gets one bridge per 72 s. Passing on begins no send once
  it has run for one send's time (10 s) in a call, so a relay that withholds
  its answers costs one wait, and what waited is dropped.
- **Always on with mesh**, disclosed in the enable flow; no separate switch.
- **Reach.** The chain is seal, announce tick, hop, the bridger's next
  receive-then-publish (72–168 s apart): it serves members a hop or two
  away, and seldom from an Android phone in the background, whose receives
  are throttled.
- **What relays learn.** Authorship stays hidden (a fresh key per event), but
  a bridged event arrives tens of seconds after its `created_at`, off the
  bridger's own rhythm: a relay can infer that a member of that circle is
  offline and within mesh reach of the bridger's address. If the sender also
  reaches the relay, the same event from two connections links the two
  addresses. For the sender it is a gain: its address never touches the
  relay.
- **Rules and pins it changes.** Rule 13.1 ("only the fanout driver sends a
  kind 445") and the kind-445 table row gain this one send of an event the
  device did not seal. Named as amended: the function-scoped gate
  (`security_rule_gates.rs:4633-4680`, the bridge function names no
  staged-commit symbol), the `fanout.rs` surface list (`:~3085-3200`, which
  fails on any new `Publishing` method), and
  `assert_a_completed_location_send_is_never_made_again` (`:4811-4841`),
  which holds only if `mesh::offer` sits before the relay send and the
  bridge stays out of `settle_locations`.

---

## 6. The mesh protocol

### 6.1 Radio

- One service, one characteristic (write-without-response + notify). The
  advertisement is the service UUID alone. No pairing, no bonding. No
  characteristic exposes a name.
- Every phone advertises and runs a filtered scan.
- Link budget: at most 4 outgoing and 4 incoming, a ceiling the controller
  may not grant. Chosen by RSSI with hysteresis, **with one outgoing and one
  incoming slot filled at random and rotated**, so the nearest attacker
  cannot take every slot.
- Two phones form links in both directions. `HELLO` carries a random value,
  never advertised, renewed at intervals drawn between 7.5 and 22.5 minutes
  so its timing carries no rhythm; it is renewed on every input, so a phone
  that was alone never greets a new link with an old value. Of the links
  showing one value, the first to show it stays and the others are closed.
  No rule can be both symmetric and safe from replay on an anonymous link, so
  when two phones dial each other at the same instant both links may close;
  a jittered back-off heals it. Residual: a peer linked to two phones can
  present one's value to the other and so keep that pair apart, one pair per
  attacker link; the shadowed phone is dialled again after each value change
  and each rotation.
- A link whose peer has not completed the handshake and greeted within 30 s
  is closed.
- GATT, not L2CAP (undocumented background behaviour on iOS).
- Connection parameters: Android `CONNECTION_PRIORITY_LOW_POWER`; iOS
  `setDesiredConnectionLatency(.high)`.

### 6.2 Link frames

Every frame after the handshake (§6.7) is `[type:1][body]`, encrypted:
`HELLO` (the random value above), `HAVE`
(entries of packet id + remaining-lifetime step, §6.4), `WANT` (packet ids), `PKT` (`[index:1][chunk]`), `BYE`. Each
body has a fixed maximum checked before allocation. Every frame is padded to
the link's frame size before sealing, so a frame's length says nothing about
its type or how many ids it carries. An unknown type, an
oversized body, a frame that does not decrypt or a version mismatch closes
the link.

### 6.3 Inventory flood

- On connect, each side announces its whole store as batched `HAVE`, in
  packet-id order. Afterwards it announces newly stored packets the same way
  on one coalesced tick for all links (period fixed by the simulator against
  the lifetime), never immediately, never in arrival order, never to the
  link a packet came from.
- The other side answers `WANT` for ids it lacks. Sends are paced on the
  platform's ready signals and chunked by the MTU each side negotiated.
- A reassembled packet is accepted **only if its id is in that link's
  outstanding `WANT` set**. A request not answered within a timeout (30 s) is
  made of another link that announced the packet, never twice of the same;
  an answer more than two timeouts after its request is unsolicited. A dropped or reordered chunk
  therefore cannot mint a new packet, and an unsolicited `PKT` closes the
  link.
- One mechanism only: a full id list for a 2048-packet store is 32 KB, under
  2 % of what it indexes. No set reconciliation in v1.

### 6.4 Store, lifetime and the per-packet record (D-1, decided)

- Store: bounded (default 2048 packets ≈ 2 MB), memory only, never on disk.
  Own and carried packets are the same rows, evicted by the same rule.
- **Lifetime.** Every packet lives at most `L` (default 20 min) from its
  origin. A `HAVE` entry is the packet id plus one byte: the lifetime
  remaining, in 256 units of `L/256` (about 4.7 s), rounded down. Only
  durations cross a link, never a clock reading, so phones need no common
  time.
  - Fine units matter. With coarse steps every hop would round a whole step
    away, the packet would die after a handful of hops however fast they
    were, and the value would count hops. At 4.7 s a hop loses under one
    unit, so the value tracks elapsed time.
  - Origin: a phone starts each packet it emits, real or cover, at a value
    drawn uniformly from the top quarter (15–20 min), and writes its record
    then. The draw is what blurs a packet's age to about five minutes.
  - Receipt at local time `t` with `r` units announced: `expires = t + r`.
  - Announcing: one unit less than the floor,
    `floor((expires − now) / unit) − 1`, computed when the radio layer polls
    the frame. A packet is announced, and a transfer started, only with two
    whole units left. **A packet whose lifetime has ended is relayed by no
    honest phone.**
  - What that guarantees, with `d` the time from that poll to the peer
    receiving the announcement: the receiver's end lies in
    `(E + d − 2u, E + d − u]` for a sender's end `E`. While `d` is at most
    one unit, no hop and no loop of honest phones extends a lifetime, and
    nothing is announced or sent after origin + `L`. A slower hop adds at
    most `d − u`, and no phone holds a packet past its own first receipt +
    `L`. Each hop costs between one and two units beyond the time elapsed.
- **The record.** For every packet id it has accepted or emitted, a phone
  keeps `{first received, expires, links it came from or went to}` on the
  suspend-inclusive clock, for the **re-accept interval** `2 × L` (40 min)
  from first receipt — longer than the packet itself.
  - **No bounce-back:** a phone never asks for an id it has a record of,
    whatever a peer announces. A packet it has relayed can come back only as
    a 17-byte inventory entry, which is ignored.
  - A packet crosses a given link at most once, and never toward the link it
    came from.
  - After the re-accept interval the record is forgotten and the same bytes
    would be taken as new. By then every honest copy has expired, so only a
    deliberate replay can return; it lives one lifetime at most and circle
    members refuse it as a duplicate.
- **Lying peers.**
  - Under-stating: a phone keeps a packet's bytes, unannounced, until
    `first received + L`, and such rows are the first evicted under pressure.
    If an honest peer later announces a larger value, `expires` is raised
    (never past `first received + L`) and the packet is announced again on
    the next tick. So a peer that hands over a packet early with a tiny
    lifetime does not kill it where an honest path exists.
  - Over-stating cannot make a phone hold a packet past `first received + L`
    or take it twice within 40 min. Toward phones that never saw the packet
    it is no stronger than injecting a new one (§6.5).
  - The value adds no tracking handle beyond the packet id a connected peer
    already sees [reviewed].
- A record is written only for a fully received, hash-checked packet (or an
  emitted one). Records are evicted strictly by age. The record table is
  sized for the accept-rate limit × the re-accept interval, so a flood that
  stays within the rate limit cannot fill it; at the cap the engine refuses
  new packets rather than forget young ids.
- Records are memory only. After a restart a phone may take live packets
  again, once, for their true remaining lifetime, and may count one as
  "passed on" a second time.
- **Cost (§0.4 item 7a).** The link is encrypted (§6.7), so only a connected
  neighbour reads the value. The simulator fixes `L` (G-7).

### 6.5 Limits

- Credit per link slot that **grows with link age**; a new link starts near
  zero. Packets from closed links fall into one "departed" class evicted
  first. Together these stop an attacker who cycles Bluetooth addresses from
  turning the fairness rule against long-lived honest links.
- A global rate limit on new inbound connections and on newly accepted
  packets.
- A link that sends malformed frames or a packet beyond its credit is
  closed.
- The accept allowance is handed out in turns, one packet per link per turn,
  so `k` flooding links take `k / (k + honest)` of it and no more.
- The record table holds everything the allowance can let in over the
  re-accept interval plus the two request timeouts an answer may take, plus
  the phone's own emissions: 11,929 records at the defaults.
- A full table of sighted peers replaces a random unlinked entry, so an
  advertiser flooding addresses cannot keep honest phones out of it.
- No proof of work: affordable for a phone means trivial for an attacker.
- **Stated bound:** a per-link allowance must admit an honest bridge carrying
  a whole cluster, so one attacker link can inject about one maximum-size
  cluster's load, and fairness protects only the first hop. T-SEC-SYBIL
  measures delivery two or more hops from the attacker; the plan claims no
  bound beyond that measurement.

### 6.6 Scale

Each awake phone emits one packet per 90 s. A connected group of `n` phones
sees `n / 90` new packets per second and holds about `13 n` at a 20-minute
lifetime, arrivals and restarts included (§6.4): a 2048-packet store is
lossless to about 150 phones. Radio throughput (estimated 20–60 packets/s
per phone across its links, to be measured) saturates several times above
that, so the store binds first. Beyond the ceiling far-away updates are lost
first. The simulator, with a per-link byte rate, discovery delay, connect
delay, arrivals and restarts, fixes the slot period, lifetime and store size.

### 6.7 Link encryption (D-5, decided)

Every link runs `Noise_NN_25519_ChaChaPoly_SHA256`, hand-written for this
one pattern on crates already in the lockfiles (x25519-dalek,
chacha20poly1305, hkdf, sha2), with every secret it holds zeroized.

- The central sends its ephemeral key (32 bytes); the peripheral answers with
  its own plus a 16-byte tag (48 bytes). The prologue is `"haven/mesh/link"`
  and one version byte, so a version mismatch fails the handshake instead of
  being negotiated down.
- Afterwards every link frame is sealed with the direction's key and a
  counter nonce, adding 16 bytes. Sends are paced on the platform's ready
  signals so frames arrive in order; **any frame that fails to decrypt
  closes the link**, which then reconnects. There is no replay window to get
  wrong: a replayed or reordered frame fails the counter.
- It hides packet ids, which packets move, and packet ages from anyone
  listening without connecting. It authenticates nobody: a peer that
  connects, or sits in the middle, sees everything a neighbour sees (§8.1).
- Pinned byte-for-byte to the public test vectors for this suite (cacophony,
  snow). security-reviewer sign-off is a merge condition.
- A stranger can cost a phone two scalar multiplications per connection; the
  inbound connection rate limit (§6.5) bounds it.

---

## 7. Platform work

### 7.1 Android

- **`MeshService`**: a dedicated Kotlin foreground service, type
  `connectedDevice`, separate from the location service. A combined service
  would need location permission to run mesh and would stop mesh when sharing
  stops [reviewed]. Sticky restart; the boot receiver checks the persisted
  flag and the Bluetooth permission first, catches a refused start, and waits
  for Bluetooth to come on.
- Permissions: `BLUETOOTH_SCAN` (`neverForLocation`), `BLUETOOTH_ADVERTISE`,
  `BLUETOOTH_CONNECT`, `FOREGROUND_SERVICE_CONNECTED_DEVICE`; legacy
  `BLUETOOTH`/`BLUETOOTH_ADMIN` with `maxSdkVersion="30"`. On API 29–30
  searching in the background needs background location; on API 23–30 it
  needs Location on. Where that is missing the status line says the phone can
  be found but cannot search.
- Scan: one `ScanFilter`, `SCAN_MODE_LOW_POWER`. Advertise: low power,
  connectable, interval chosen for iOS background discovery (1022.5 ms on
  API 26+ [U, Apple's recommended list not re-fetched]). `requestMtu(517)`.
  `connectGatt(..., TRANSPORT_LE)`, one operation queue, `close()` after
  every disconnect, status 133 retried, central-only when the controller
  cannot advertise.
- **Notification (F2)**: own channel, low importance, localized, grouped with
  the location notification, no identifier or count in its text; tapping it
  opens the statistics sheet. If the user swipes it away on Android 14+ it is
  posted again at the next screen-off (it cannot be dismissed on the lock
  screen). With notification permission denied mesh still runs (D-9,
  decided): the service keeps working, its notice is hidden from the drawer,
  and the button and its sheet are the indicators.
- Play: the `connectedDevice` declaration is reviewed and Google's examples
  are accessories [V2]. G-4, asked in M0.

### 7.2 iOS

- **`HavenMeshRadio`** (Swift): one `CBCentralManager` and one
  `CBPeripheralManager` with restore identifiers, created natively in
  `didFinishLaunching` from a stored flag (as `AppDelegate.swift:133-139`
  does for location), and **never created while mesh is off** — creation is
  what triggers the Bluetooth prompt and restoration relaunches.
  `UIBackgroundModes` gains `bluetooth-central` and `bluetooth-peripheral`;
  `NSBluetoothAlwaysUsageDescription` is added and registered in the privacy
  manifest.
- Works with the screen locked [V/V2]: links made before locking stay up; a
  locked iPhone finds an Android phone, slowly; a foreground iPhone finds a
  locked one; pending connects to recently seen peers complete when the peer
  returns, until its address rotates (about 15 minutes [U]); with background
  location sharing on, the process is not suspended.
- Does not work reliably: §0.4 items 1 and 4.
- With background sharing off, the engine advances only when a Bluetooth
  event wakes the app (§0.4 item 2).
- Mitigations in scope: keep links across lock; arm pending connects on
  backgrounding; restore both managers on relaunch within the wake budget; a
  notification when a locked iPhone has had no link for a set time.
- Out of scope: decoding Apple's overflow bitmask from Android —
  undocumented, collision-prone, changed across iOS releases [V2].
- **Indicator (F2)**: one local notification with a fixed identifier and
  passive interruption level, so it sits in Notification Centre; added again
  if absent at each move to background, each Bluetooth wake and each
  relaunch; removed at mesh off. A refusal does not stop mesh (D-9). Authorization is requested in the enable
  flow. iOS lets the user clear it; D-3 (auto-off) is the stronger answer to
  "forgot it on". A Live Activity is a later option, not v1: it needs a
  second signed target, iOS 16.1+, and ends after 8 h.

### 7.3 Power and wake-ups (F3)

What wakes the processor for each periodic action:

| Action | Android, sharing on | Android, sharing off | iOS, sharing on | iOS, sharing off |
|---|---|---|---|---|
| Advertise, filtered scan | Bluetooth controller | controller | controller | controller |
| Inbound frame | radio event + timed wake lock held through the engine's next announce tick, with a hard cap | same | process running | Bluetooth wake (~10 s) |
| Emission slot, announce tick, lifetime expiry | location service's existing wake | allow-while-idle alarm (≥ ~9 min in Doze) and any radio event | process running | only on a Bluetooth wake |

- No continuous wake lock is held for the mesh. A lock held while any link is
  up would keep the processor awake whenever another mesh phone is near; that
  is the alternative if hardware shows the timed-lock design drops frames
  (G-10).
- Lowest advertise rate, lowest scan duty, capped links, low-power connection
  parameters, one coalesced announce tick. No battery-saver adaptation in v1:
  it would be one more observable.
- Model E (`POWER_EFFICIENCY_PLAN.md` §6.5a) gains inputs for advertising,
  scan duty, connection events × links, wakes per hour and the timed-lock
  term, each cited and tagged ESTIMATED, the total stated as "+ UNKNOWN AP".
  Nothing is written into `POWER_MEASUREMENT.md`.
- CI proves mechanisms, not milliamps (T-PWR-*), and says so.

### 7.4 Enable flow

Tap → first time, a disclosure sheet (what is shared; §0.4 items 6–8, 7a, 7b and 11a in plain
words; battery note; the platform's background limits; that holding the
button shows statistics) → notification and Bluetooth prompts → radio starts
→ notification appears → button shows the on state, with a snackbar offering
Undo. Turning off is immediate. Bluetooth off or a refused permission leaves
mesh off with fixed copy (Rule 8). The setting is cleared on identity delete.

### 7.5 Button and statistics (F4)

- `MeshButton` in `MapShell.buildLayers`, `Positioned(left: 16, bottom:
  collapsed sheet height + 16)` — **a fixed corner, not mirrored**, like
  `MapControls`, so it cannot land on the zoom buttons in the three
  right-to-left locales. Z-order: after the map, before the dim overlay, so
  the expanded circles sheet covers it as it covers the map controls. 48 dp;
  state shown by icon and label, not colour alone; a dot when at least one
  link is up.
- Tap toggles. Long-press opens the statistics sheet with haptic feedback.
  The same sheet is reachable by a `CustomSemanticsAction` with an
  `onLongPressHint`, from a Settings row, and from the notification. No
  `Tooltip` on the button (its default trigger is long-press); the semantics
  label carries the name.
- The sheet, titled **Mesh activity**:

  |  | Since turned on | All time |
  |---|---|---|
  | Updates from your circles | n | n |
  | Encrypted packets passed on | n | n |

  Footnote: "Passed-on packets can't be read by this phone. They include
  other people's updates and cover traffic." One status line ("Mesh is on ·
  connected / searching / off") and a reset action.
- **Updates from your circles** = updates of other members that the MLS
  engine read for the first time out of a mesh packet. One a relay delivered
  first is not counted, nor is this phone's own, nor one read before — in
  this process or an earlier one, in the same packet or another. **Passed
  on** = unique packets this phone did not emit and could not open, counted
  when first sent to another phone.
- "Since turned on" survives a process restart while mesh stays on. The
  values are four integers in the SQLCipher `user_settings` table — the two
  lifetime totals, and what each read when mesh was last turned on — folded
  at every drive, at every read of the sheet, at mesh off and at the
  deadline: no timestamps, no per-circle or per-peer breakdown. An update is counted once, when the engine answers that it read
  it — off the engine's own durable record of what it has processed, so no
  number of packets, no replay, no restart and no turning mesh off and on
  counts it again. What was counted since the last fold is lost if the process is
  killed; the promise is that the lifetime value never decreases and includes
  everything up to the last fold.
- Exact counts are shown, never logged (Rule 15).
- 13 locales, each translated and independently reviewed.

---

### 7.6 Auto-off (D-3, decided)

- Mesh turns itself off **12 hours** after it was turned on.
- 30 minutes before, a notification says so and offers **Keep on**, which
  restarts the 12 hours from that moment without opening Haven. Turning mesh
  on again, or Keep on in the statistics sheet, does the same.
- At the deadline the radio stops, the Android service ends, the ongoing
  notification is replaced by one saying mesh has stopped, and the button
  shows off. The stopped notice reuses the reminder's identifier, so no stale
  Keep on can remain; after the deadline the only way back is to turn mesh
  on. The sheet shows the time left while mesh is on.
- The deadline is stored, survives restart and reboot, is cleared on identity
  delete, and can never be more than 12 hours ahead (a clock set backwards
  does not extend it). Every wake of the mesh, on both platforms, checks the
  deadline before doing any mesh work.
- Android: one inexact allow-while-idle alarm in `MeshService` (needs no
  permission; exact alarms would). It may fire late, so the check on every
  wake is what enforces the deadline while the phone is in use.
- iOS: the reminder and the stopped notice are time-scheduled when mesh is
  turned on, so they appear while the app is suspended. If the app is running
  the radio stops at the deadline. If iOS has suspended it, no packet moves
  after the deadline — the first wake stops the radio — but the system may
  keep advertising and scanning on Haven's behalf until then; the existing
  background refresh task is requested for the deadline as a best-effort
  earlier wake. Scheduled notices follow elapsed time and the stored deadline
  follows the clock, so they can differ after a clock change.
- Without notification permission there is no reminder and no Keep on tap:
  mesh stops at 12 hours and the app shows it the next time it is opened;
  extending means opening Haven before then.
- **Why 12 hours.** It covers a festival day or a working day; a mesh left on
  by mistake ends within the night; an emergency that lasts longer costs one
  tap every 12 hours. The figure is not derived from a battery measurement
  (none exists). It is one constant.
- **Cost.** A phone whose owner cannot confirm — injured, asleep, separated
  from it — stops relaying and stops sending its location by mesh 12 hours
  after the last confirmation, even if it is the only bridge between two
  groups. 24 hours halves that risk and doubles the time a forgotten mesh
  runs.

### 7.7 Background reliability: what was chosen and what it costs (D-8, decided)

| | Chosen | What it buys | What it costs |
|---|---|---|---|
| R1 | An iOS background burst whose **receive failed** (not one stopped by withdrawn consent or by the app returning to the foreground) **seals for the mesh only** when mesh is on. The seal carries a mesh-only mark inside the opaque sealed value, so Dart cannot route it to a relay; `publish_location` runs its checks, hands the event to the mesh, skips the relay send, ends the record and answers a new `MeshOnly` outcome. A mesh-only seal drives nothing else: it does not re-send a pending commit (the circle stays silent instead), runs no repair or settle, and the burst skips its maintenance step, as its early return does today. The health model does not count it as a relay publish. | A locked iPhone keeps sending its location by mesh when no relay answers. Today it seals nothing in two cases: the poll build when its catch-up did not complete, and the live build when no live session exists and none can be started (`background_burst_coordinator.dart:578-589`). The live build with a session already publishes after a failed open (`:597-647`). | (a) The fix is sealed at the last epoch the phone knows. If a commit the phone could not fetch removed a member, that person — holding the old keys, within reach of the mesh — can read it, until the phone next completes a receive. The Android service (which publishes before it fetches), the foreground path and the iOS live path with a session already carry this exposure. (b) Each such seal uses one MLS message generation, bringing §0.4 item 12 closer. (c) It reverses a recorded rule ("nothing is sealed before a receive has run", `haven-core/SECURITY.md:1693-1695`) for the mesh carrier. The engine's own holds (§5.4), unread stored input included, still apply. |
| R2 | Android, asleep, sharing off: each radio event takes a timed wake lock held through the engine's next announce tick, with a hard cap. | A sleeping Android phone forwards whenever traffic reaches it. | In a busy mesh the processor is awake most of the time. Battery cost unquantified: model E has no figure for an awake processor. Phones with sharing on already hold the location service's wake lock, so nothing is added there. |
| R3 | iOS, sharing off: best effort. Turning mesh on with background sharing off says so and offers to turn background sharing on. | With background sharing on, the app keeps running and mesh is dependable in the background. | Without it, the app runs ~10 s per Bluetooth event and iOS may throttle it. The only way to make a non-sharing iPhone dependable is to keep a location session running for a user who is not sharing: a location permission prompt, the system's location indicator while not sharing, the location hardware powered, and App Review risk (guideline 2.5.4). Not adopted now; specified as the fallback in D-11. |
| R4 | The queue of packets waiting to be read (§5.2) is 8192 packets ≈ 8 MB. | A phone whose app was closed reads, on opening, what passed through it — about two hours' worth in a 100-phone crowd, longer in smaller ones. | 8 MB of memory while mesh is on; beyond the queue the oldest unread packets are dropped. |

What no choice can buy: two locked iPhones that have never met finding each
other; an Android phone finding a locked iPhone; mesh surviving a force-quit
or Bluetooth being switched off on iOS; proof in CI of any sleeping-phone or
iOS radio behaviour (§0.4 items 1, 4).

---

## 8. Security and privacy

### 8.1 Threat model

| Adversary | Learns | Cannot learn | Residual |
|---|---|---|---|
| Passive sniffer | A phone runs Haven mesh; link timing and volume; sleep state | Circle, sender, content, packet ids and ages, hop count, real vs cover | Presence, counting, direction-finding |
| Connected non-member | Packet ids; a neighbour's whole store; first-seen times; each packet's age to within about five minutes | Circle, sender, content, hop count, real vs cover | Re-identifies a phone across address rotation; as a lone neighbour, knows which packets a phone emitted; with many nodes, first-seen timing points at an originating device |
| Malicious member | What the circle shares; which packets are the circle's | Other circles | Can send future-epoch application messages toward the engine buffer, bounded by §5.2 |
| Removed member | Packets sealed at epochs they held, from members who have not seen the removal — on iOS in the background too (§7.7 R1) | Later epochs | An outage freezes epochs, so the window lasts as long as the outage |
| Replay | — | — | Authentic replay is a duplicate or stale (§5.3) |
| Relay operator | With member bridging: that a member of a circle is offline and within mesh reach of the bridger's address; two addresses linked when both send the same event | Who, where, content | §5.5 |
| Device seizure | Lifetime counters; that mesh was used; mesh keys for retained epochs (the same epochs MDK already stores) | Carried packets (memory only) | — |
| Flooder / address cycler / eclipse | — | — | §6.5 |

### 8.2 Rules and documents changed in the same commit as the first code

- **New Security Rule 17 (Mesh):** no cleartext field in a packet; only
  application messages cross the mesh, checked at both ends; a location
  reaches the mesh only after the relay path's send-time check; the engine
  holds no key and forwarding never depends on recognition; the mesh has
  no sealing code of its own, bridges to a relay only an event a member opened and only under §5.5, never holds an MLS
  session; the store is memory only; the advertisement is the UUID alone; no
  pairing; the mesh is lossy by design (the explicit carve-out from Rule 12's
  "never drop").
- Rule 16 gains the mesh ingress (`verify()` before ingest).
- Consciously amended: the "sealed event goes to `publish_location_driven`
  and nowhere else" contract (`api.rs:7612-7615`, `8605-8606`;
  `circle_change_driver.dart:125-128`); the CLAUDE.md kind-445 row ("never
  past its `expiration`" — the mesh carries it past, by design);
  `INV-W-445-EXPIRATION-SCOPE`; `SECURITY.md` retention text;
  `UNRESOLVABLE_INPUT_MAX_AGE_SECS`'s rationale
  (`haven-core/src/nostr/mls/types.rs:563-592`), which assumes nothing
  redelivers after 288 s; the stale "FFI exposes no streams" line; for §5.5, Rule 13.1,
  `haven-core/SECURITY.md:482-494`, the `publish_event` doc at
  `api.rs:9121-9123`, `security_rule_gates.rs:1139-1157`,
  `INV-R-PER-CIRCLE-PUBLISH-DECORRELATED` and a new invariant for the
  relay-side inference; and for §7.7 R1,
  `haven-core/SECURITY.md:1693-1695`, the comment at
  `background_burst_coordinator.dart:573`, and
  `background_burst_coordinator_test.dart:476`, `:601`, `:621`, `:698-708`.
- Rule 15: a new `log_alias` class for a mesh link; Bluetooth addresses,
  peripheral identifiers, packet ids, per-peer RSSI and exact counts never
  reach a log; native lines allowlisted; redacting `Debug` with proof for
  every new type; a planted-identifier test per new line; netsim captures are
  never uploaded unscanned.
- The privacy manifest gains an invariant per promise here and the new usage
  strings.
- Rule 10: the feature adds exposure (§0.4 items 6–8, 7a, 7b, 11a; ciphertext held by
  strangers for a packet's lifetime). It is owner-directed by this request and is
  recorded as such.

### 8.3 Reviews at implementation

security-reviewer on key derivation and storage, the envelope, the C
interface and the ingest seam; marmot-expert on epoch handling;
dependency-auditor on `jni` and on making `hkdf` (pinned to the 0.12 line
already resolved), `chacha20poly1305` and `x25519-dalek` direct dependencies
in all three lockfiles.

---

## 9. Testing (N1)

### 9.1 Layers

| Layer | What runs | Where | Per PR |
|---|---|---|---|
| L1 unit + proptest | envelope, keys, store, credit, frames, reassembly | `haven-core` | yes |
| L2 `mesh_sim` | N real `MeshEngine`s on a virtual radio with a logical clock, seeded generators, per-link byte rate and delays; topology, loss, partition, arrivals, restarts, sleep jumps, adversary nodes | `haven-core/tests/mesh_sim.rs` | yes |
| L3 soak | real MLS engines + in-process relays + the mesh plane under the existing fault layer (`Fault::Down` on every plane is "internet down") | `tooling/soak` | yes |
| L4 Android radio | **one emulator** running the real app, plus host-side peers on the same netsim: a thin Bumble byte pump bridged to a Rust `haven-mesh-peer` binary running the real `MeshEngine`; the adversary is the same binary with a fault script | new `e2e-mesh-android.yml` | yes, after G-1 |
| L5 iOS | simulator, real UI + Rust + notification, with an in-process mesh peer on a debug-only loopback radio, folded into the existing iOS drive | `e2e-ios.yml` | yes |
| L6 guards | repo guards, logscan, privacy manifest | `repo-guards.yml` | yes |
| L7 physical | sleeping processors, iOS locked/background, cross-platform radio | `docs/MESH_DEVICE_MATRIX.md` | DEFERRED, residual stated |

L4 uses one emulator because this repo already records that several thrash on
hosted runners. The scripted peers give ground truth for the counters and
three-node topologies (peer → app → peer).

No sleeps: L1–L3 run on injected clocks; L4–L5 wait on events within budgets
declared in `e2e_lane_budget.manifest`.

### 9.2 What CI does not prove

- Anything about a sleeping processor (emulators do not sleep).
- Any iOS radio behaviour. The Swift adapter runs in CI only if the M0 spike
  of a CoreBluetooth mock succeeds (G-8); otherwise it is unverified in CI and
  that is an owner decision (D-6).
- Battery.

### 9.3 Promise → test

**Privacy**
- **T-PRIV-1** every byte crossing a virtual or netsim link is recorded; no
  planted routing id, MLS group id, pubkey, event id or coordinate appears;
  every packet is exactly 1024 bytes.
- **T-PRIV-2** with a seeded generator, `packet == nonce ‖
  ChaCha20-Poly1305(K, nonce, AAD, plaintext)` against an independent vector,
  the nonce equals the generator's output, the length is exactly 12+996+16
  and the AAD is the constant; a guard pins `OsRng` in production.
- **T-PRIV-3** forwarding traces are identical for a member and a non-member,
  and for own and carried packets, including eviction. Under store pressure
  own packets are one class among the links', evicted by the same rule.
- **T-PRIV-4** a node's emissions are identical in count and timing with 0, 1
  and 10 sharing circles, with a circle held, and across a clock jump (one
  packet on waking).
- **T-PRIV-8** the link handshake and transport match the public vectors for
  `Noise_NN_25519_ChaChaPoly_SHA256`; a recorded link shows no packet id,
  lifetime value or frame type in clear; a wrong version byte fails the
  handshake; a dropped, replayed or reordered frame closes the link.
- **T-PRIV-5** the advertisement and GATT table hold only the service UUID.
- **T-PRIV-6** each of the 8192 single-bit flips makes a packet unopenable
  and leaves forwarding unchanged.

**Security**
- **T-SEC-1** a packet whose rebuilt event fails `verify()` never reaches
  ingest. **T-SEC-2** a member-wrapped commit, proposal or other
  non-application message is dropped at the mesh ingress; `mesh::offer` has
  one call site (guard). **T-SEC-3** malformed, oversized, truncated,
  unsolicited or stalled frames close the link and allocate nothing
  unbounded; dropping, duplicating or reordering any chunk adds no packet id
  to any store and the wanted packet still arrives (proptest + scripted
  peer). **T-SEC-4** an address-cycling attacker cannot evict long-lived
  links' packets; an eclipse attacker cannot hold every slot.
  **T-SEC-SYBIL** delivery two or more hops from an attacker is measured and
  recorded. **T-SEC-5** a flood of future-epoch packets stays within the
  per-drive bounds; nothing is drained into a held circle. **T-SEC-6** mesh
  keys are pruned in step with retention, a staged-epoch key is discarded on
  rollback, and a restart keeps the keys for retained epochs. **T-SEC-7** a
  seal the relay path answers `Superseded`, `Expired` or `Ended` never
  reaches the outbox; leave, sharing-off, epoch change and mesh-off empty it
  before the next slot; mesh-off and identity delete leave no packet, record
  or unread entry. **T-SEC-8** under a flood of records, no phone takes
  a packet again within the re-accept interval.

**Lifetime and bounce-back (D-1)**
- **T-LIFE-1** in every honest simulator run, arrivals and restarts
  included, with announcements arriving within one unit: no phone sends or
  announces a packet after its origin time + `L`, loops of phones included.
  With slower links the excess is at most the sum of `d − u` over the path,
  and never past a phone's own first receipt + `L`.
- **T-LIFE-2** a phone never asks for a packet it has a record of. A packet
  asked of two links (the first not answered within the request timeout)
  arrives at most once on each; only the first copy is stored, the second
  changes nothing but a duplicates count, and a third closes its link. A
  packet never goes toward the link it came from; one offered just before
  the re-accept interval ends is refused and at its end is accepted.
- **T-LIFE-3** an attacker with a head start that hands a fresh packet with
  one unit to the only phone on the path downstream does not stop delivery
  once the honest announcement arrives; a peer announcing the maximum for an
  old packet cannot make any phone hold it past first receipt + `L` or take
  it again within the re-accept interval.
- **T-LIFE-4** in honest runs an announced value never exceeds the true one.
- **T-LIFE-5** on a k-hop line the value lost is between k and 2k units
  plus the time actually elapsed.
- **T-PRIV-7** every value an own packet can first be announced with is also
  reachable by a carried packet on the wire, and the starting value is drawn
  from the generator. Between honest phones the top two values an own packet
  can show (252 and 253 of 255) are above anything a carried one shows: about
  1 own packet in 67 is recognisable that way by a connected neighbour
  (§0.4 item 7a).

**Independence**
- **T-INDEP-1a** (soak) the same profile and seed run with mesh off, then on:
  per device, the multiset of client→relay `EVENT` frames projected to
  (plane, kind, tag names, `expiration − created_at`, verdict) is equal, the
  sequence of seal and publish outcomes is equal apart from mesh-only seals
  (§7.7 R1), which produce no relay frame, and bridged events (§5.5), which
  are counted separately, and the plane oracle shows no new
  frame class at any relay.
- **T-INDEP-1b** `publish_location` returns the same outcome with zero added
  virtual time when the mesh engine is full, stalled, or gone.
- **T-INDEP-1c** guard: `mesh::` is named under `relay/` and `nostr/` only at
  the hand-off and the bridge.
- **T-INDEP-3** with relays down, locations arrive by mesh; when relays
  return nothing is duplicated on the map.
- **T-INDEP-4** with mesh on and sharing off, swiping the app away leaves the
  catch-up worker and a relaunch able to obtain the MLS session; on iOS no
  Bluetooth manager exists while mesh is off.
- The existing core-flow, background-catch-up and foreground-service lanes
  run their relay oracles once more with mesh on and a peer present.

**Member bridging (D-7)**
- **T-BRIDGE-1** a fellow member's update received by mesh within the window
  appears at the circle's relay exactly once. **T-BRIDGE-2** at or past
  218 s it is never sent. **T-BRIDGE-3** a duplicate, own echo, buffered or
  stale event is never sent. **T-BRIDGE-4** format `0x01` (a mesh-only seal
  included) is never sent. **T-BRIDGE-5** a commit or proposal is never sent.
  **T-BRIDGE-6** an event at another epoch than the bridger's, or for a
  circle that is held, leaving or disbanded, is never sent. **T-BRIDGE-7**
  under a flooding member the per-sender and per-drive bounds hold.
  **T-BRIDGE-8** a bridge's result reaches neither the health model nor the
  clock-skew detector, and a drive that publishes nothing of its own bridges
  nothing. **T-BRIDGE-9** (soak) A offline on mesh, B online, C far away
  receives A's update; a member removed before the bridger's last receive
  finds nothing of A's at the relay. **T-BRIDGE-10** a drive whose relay
  receive for the circle failed bridges nothing; an epoch change between
  ingest and send stops the bridge. **T-BRIDGE-11** an event whose
  `expiration − created_at` exceeds 228 s, or whose `created_at` is ahead of
  the clock, is never sent; a relay's refusal is not retried. **T-BRIDGE-12**
  the enable flow's disclosure names bridging.

**Delivery, reliability, performance**
- **T-DELIV-*** line, star, cluster, partition and merge, a carrier walking
  between islands, arrivals and restarts: delivery within stated bounds.
- **T-RELAY-E2E** (L4) peer A → app → peer B: the app passes on a packet it
  cannot open; B receives it; the app's "passed on" count rises by one.
- **T-REL-1** (L4) a peer disconnects mid-packet; the packet arrives after
  reconnect.
- **T-PERF-1** (L2) p95 logical delivery latency and peak store occupancy at
  the supported `n` on throughput-capped links. **T-PERF-2** counted AEAD
  operations per new packet ≤ stored keys. **T-PERF-3** (L4) M packets
  delivered within a declared budget.

**Statistics, notification, background, power, logs**
- **T-STAT-1** both counters equal the peers' ground truth; duplicates and
  own packets are not counted. **T-STAT-2** the lifetime value never
  decreases, includes everything up to the last fold, and resets on identity
  delete. **T-STAT-3** long-press, the semantics action, the Settings row and
  the notification open the same sheet; turning mesh on with background
  sharing off on iOS shows the best-effort notice; the sheet reads correctly through the
  semantics tree; the button and the map controls do not overlap under
  right-to-left, 200 % text and small screens.
- **T-NOTIF-1** mesh on ⇒ notification present; off ⇒ absent. **T-NOTIF-2**
  after a cancel through a test notification listener, the next screen-off
  posts it again. **T-NOTIF-3** with notification permission denied, mesh
  turns on, carries packets, shows its state on the button and sheet, and
  still turns off at the deadline.
- **T-BG-1** (Android emulator) screen off and forced idle, packets still
  flow; process killed, the service returns; reboot with mesh on, mesh
  resumes; reboot with the permission revoked, no crash. The lane states it
  does not prove processor sleep.
- **T-BG-2** an iOS burst whose receive failed: with mesh on it puts one
  packet in the mesh store and sends no relay frame of any kind, a pending commit
  included; with mesh off it seals nothing, as today; a burst stopped by
  withdrawn consent or by returning to the foreground seals nothing either
  way.
- **T-BG-3** packets whose lifetime ended while nobody read them are still
  read at the next drive; past the queue's size the oldest are dropped.
- **T-AUTO-1** on an injected clock mesh stops at the deadline and the
  turned-off notice replaces the ongoing one. **T-AUTO-2** the reminder
  appears 30 minutes before and Keep on moves the deadline 12 hours from
  then. **T-AUTO-3** the deadline survives restart and reboot, and a clock
  set backwards never leaves more than 12 hours. **T-AUTO-4** a wake after
  the deadline does no mesh work before stopping; the pending iOS notices
  are the two expected, and the stopped notice replaces the reminder.
- **T-PWR-1..3** scan and advertise modes and connection priority from one
  constants site with a guard; link cap; no frames with no peers.
- **T-LOG-1** planted identifiers absent from every sink in every lane.

---

## 10. Milestones

Each lands complete with its tests. M1 is a library with no caller. From M2
on, every call site ships behind a compile-time define, default off (the
`HAVEN_LIVE_SYNC` precedent, with coverage's flag-off run), until M5.

| M | Scope | Exit |
|---|---|---|
| M0 | Spikes, not merged: (a) one emulator + Bumble + a Rust peer on netsim on a hosted runner — ≥ 50 consecutive green runs, cold and snapshot boot, peripheral role, ≥ 2+2 links, negotiated MTU, time-to-first-link p99, usable capture; (b) measured sealed-location size; (c) notification re-post mechanism; (d) Swift → Rust smoke build; (e) CoreBluetooth mock in the simulator; (f) the Play declaration and App Review questions | G-1, G-2, G-4, G-6, G-8 answered here |
| M1 | `MeshEngine` + `mesh_sim` with churn; parameters and D-1 decided from data | L1, L2; T-PRIV-1..4,6; T-SEC-3,4,8,SYBIL; T-DELIV; T-PERF-1,2 |
| M2 | Keys in `SessionManager` + store, `mesh::offer`, `mesh_drive`, member bridging, counters; soak scenarios; Rule 17 and the amended documents | L3; T-INDEP-1a..c,3; T-SEC-1,2,5,6,7; T-BRIDGE-1..9; T-STAT-1 |
| M3 | Android: `MeshService`, radio, C interface, notification, permissions, **and** the button, enable flow, sheet and 13 locales; L4 lane | T-BG-1, T-NOTIF, T-PRIV-5, T-PWR, T-RELAY-E2E, T-REL-1, T-PERF-3, T-STAT-2,3, T-INDEP-4; ui-ux review |
| M4 | iOS: `HavenMeshRadio`, restoration, pending connects, notification; L5; the device matrix written and marked DEFERRED | L5 green |
| M5 | Hardening, model E entries, privacy manifest, store declarations; the define flips on | Every gate closed or owner-accepted |

M1 and M2 need no hardware and carry most of the risk. The button is
platform-gated until its platform's radio lands.

---

## 11. Gates and owner decisions

### Gates

- **G-1** the L4 design runs reliably on a hosted runner [U]. If it does not,
  the Android radio has no per-PR proof and requirement N1 is unmet for it;
  a self-hosted runner needs an owner decision.
- **G-2** *answered:* a sealed location is 546–595 bytes of content against
  the 881 limit, pinned by a test (§4.1).
- **G-3** *answered:* Haven seals with no relay reachable in the foreground
  and in the Android foreground service; not in an iOS background burst (D-8).
- **G-4** Google Play accepts `connectedDevice` for phone-to-phone; App
  Review accepts the two Bluetooth background modes [U].
- **G-5** *answered:* §0.4 item 12.
- **G-6** the API 34 emulator image supports the peripheral role and several
  links under netsim and survives snapshot boot [U].
- **G-7** the churn simulation fixes the lifetime `L` and its step (D-1 is
  decided; only the numbers are open).
- **G-8** the Swift adapter can be exercised in CI with a CoreBluetooth mock
  [U].
- **G-9** mesh-on does not change MLS session ownership or reclaim
  (T-INDEP-4).
- **G-10** the timed-wake-lock design delivers frames on a sleeping Android
  phone, and iOS does not throttle a suspended relay woken by frequent
  Bluetooth events [U, hardware only].

### Owner decisions

- **D-1 Packet lifetime — DECIDED 2026-11-10.** Packets expire everywhere:
  a remaining-lifetime value travels with each id on the link, a phone never
  takes back a packet it has a record of, and a record outlives its packet
  (§6.4). Accepted cost: §0.4 item 7a.
- **D-2 Cover traffic — DECIDED 2026-11-11 (final): fixed-rate emission with
  cover packets** (§5.1). The owner first chose real updates only; a review
  showed that would let a neighbour who also watches the relays tie a phone
  to its circle by timing, and the owner returned to cover packets. Accepted
  costs: every phone adds load, a user with `k` circles updates each every
  `k × 90 s` on mesh, "passed on" counts cover packets.
- **D-3 Auto-off — DECIDED 2026-11-10.** 12 hours, with a reminder and a
  one-tap extension (§7.6).
- **D-4 Lifetime counters — DECIDED 2026-11-11: the encrypted store.** An
  examiner needs the unlocked device to read two numbers that say mesh was
  used and how much; no times, circles or peers. Counts since the last fold
  are lost if the process is killed (§7.5).
- **D-5 Link encryption — DECIDED 2026-11-11: hand-written Noise NN**
  (§6.7), pinned to public test vectors, zeroized, with a mandatory security
  review. Considered and not taken: the `snow` library (audited by Trail of
  Bits in January 2024 and widely used, but one maintainer, no release since
  July 2025, and it does not zeroize secrets); no link encryption in v1.
- **D-6 iOS — DECIDED 2026-11-11: ship on both platforms when CI is green.**
  The limits in §0.4 items 1, 2 and 4 are Apple's. Accepted risk: iOS mesh
  reaches users without the project having run it on a real iPhone; an iOS
  radio fault would show only as the status line staying on "searching". The
  device checklist (L7) stays written and DEFERRED.
- **D-7 Internet bridging — DECIDED 2026-11-11: member bridging** (§5.5). A
  phone that cannot open a packet still cannot bridge it. Accepted costs:
  a second way for a kind-445 to leave the device, in the code Rule 13
  guards; reach of a hop or two; the relay-side inference in §0.4 item 11a.
- **D-8 Background reliability — DECIDED 2026-11-10:** as reliable as the
  platforms allow, costs stated (§7.7). Recorded as owner-directed under
  Rule 10: R1 widens the removed-member window on iOS.
- **D-9 Notifications denied — DECIDED 2026-11-11.** Mesh may be turned on
  and works fully without notification permission. Consequence: nothing
  outside the app then shows that mesh is on, and the auto-off gives no
  warning (§7.6).
- **D-11 Non-sharing iPhones in the background — DECIDED 2026-11-11: C,
  with B prepared as a fallback.** Concerns only an
  iPhone with mesh on and background location sharing off (the setting is off
  until the user turns it on); with background sharing on, the app already
  keeps running. bitchat's iOS app declares only the two Bluetooth background
  modes and no keep-alive of any kind [V, `bitchat/Info.plist:50-54` at
  `04995f6`; its location code serves its location channels].
  - **A — Bluetooth wakes only (what bitchat does).** iOS runs Haven for
    about 10 s on each Bluetooth event; the phone forwards inside that
    window. No location permission, indicator or hardware; lowest battery;
    plain App Review case. But nothing runs between events, iOS may throttle
    or end an app that is woken constantly [V wording, never measured here],
    and a restart loses the packets in memory.
  - **B — keep a location session running whenever mesh is on.** The app
    never suspends: forwarding, timers and cover packets run continuously and
    the in-memory store survives. But it needs location permission from
    someone who is not sharing, shows the system location indicator while not
    sharing, keeps the processor awake (battery, unquantified), and uses the
    location background mode for something other than location (guideline
    2.5.4 risk).
  - **C — A, plus an explicit offer to turn background sharing on when mesh
    is turned on** (the plan as written, §7.7 R3).
  - Neither A nor B changes how locked iPhones **find** each other; that
    depends on foreground state, not on whether the app is running (§7.2).
  - **Prepared fallback.** B is specified here and not built, so no unused
    code ships. Trigger: G-10 on hardware, or field evidence, shows iOS
    throttling or ending a suspended relay. Scope when triggered: with mesh
    on and background sharing off, Haven arms its existing background
    location session (`HavenBackgroundSessionHandler`) at the lowest accuracy
    and discards every fix — nothing is sealed or sent; the enable flow asks
    for location permission and says why; the privacy manifest and the
    location usage strings gain the new purpose; a test proves no location
    leaves the device in that state; the App Review question is asked first.
    Until then the engine keeps its iOS-suspended behaviour: forward within
    the wake window, catch up on wake (§7.3).
- **D-10 Offline sealing cadence — DECIDED 2026-11-11: unchanged.** When a
  publish fails Haven retries about every 72 s
  (`background_location_task.dart:2128-2176`), each seal uses one MLS message
  number, and 1000 numbers last about 20 hours (§0.4 item 12).

---

## 12. References

- bitchat iOS `permissionlesstech/bitchat@04995f68`, Android
  `permissionlesstech/bitchat-android@14ab73c4`; `WHITEPAPER.md` v2.0.
- Albrecht, Blasco, Jensen, Mareková, "Mesh Messaging in Large-scale
  Protests: Breaking Bridgefy" (ePrint 2021/214); Albrecht, Eikenberg,
  Paterson, "Breaking Bridgefy, again" (USENIX Security 2022).
- Heinrich et al., "Who Can Find My Devices?" (PoPETs 2021).
- Vahdat, Becker, "Epidemic Routing for Partially-Connected Ad Hoc Networks"
  (2000); Fanti et al., Dandelion++ (2018).
- RFC 9420 §6.3, §8.5, §9.2; Marmot `foundation/wire-envelopes.md`,
  `transports/nostr.md`; MDK at `fcc85edd`; OpenMLS fork at `59e7d3b`
  (`sender_ratchet.rs`).
- Apple: Core Bluetooth Background Processing guide; TN3115 (rev. 2025-09-15);
  ActivityKit "Displaying live data with Live Activities".
- Android: foreground service types, timeouts and background-start rules;
  Bluetooth permissions; Android 13/14/15 behaviour changes; Doze and App
  Standby; `packages/modules/Bluetooth` scan constants (LineageOS mirror,
  Android 16 base).
- google/bumble Android platform and netsim transport docs.

## 13. What the review changed

| Finding | Change |
|---|---|
| Hand-off after seal bypassed the relay path's send-time check (blocker) | `mesh::offer` sits after `may_be_sent`; T-SEC-7 (the outbox it first added went with D-2) |
| No wake source for periodic work on a sleeping phone (blocker) | §7.3 wake table; suspend-inclusive clock; §0.4 items 2, 8; G-10 |
| Memory-only key ring lost the keys for peers on older epochs | Keys derived under the engine hold, stored; staged-epoch rule |
| Engine held keys and an inbox | Keyless engine; recognition in `mesh_drive` |
| A member could inject commits over the mesh | Application-only check at the receiver |
| Address-cycling and eclipse defeated the limits | Age-weighted credit, departed class, random slots |
| A lost chunk minted a garbage packet | Accept only what was asked for; chunk index |
| Unbounded lifetime under churn; immortal packets | Seen-set rules; churn in the simulator; G-7, D-1 |
| iOS background seals nothing offline | §5.4; D-8 |
| Button collided with zoom controls in right-to-left locales | Fixed left corner; z-order; T-STAT-3 |
| Live Activity needs a second signed target and a foreground start | Local notification in v1 |
| Two emulators thrash on hosted runners | One emulator + scripted Rust peers |
| "Byte-identical relay journal" and a statistical distinguisher were not deterministic tests | T-INDEP-1a..c; T-PRIV-2 as a known-answer test |
| Service UUID literal fails the committed-secrets guard | Raw bytes, built at run time |
| Two sync mechanisms | Inventory flood only |
| Residuals missing from the summary | §0.4 items 3, 4, 6–8, 10–12 |

## 14. What the owner decisions of 2026-11-10 changed

| Decision | Change |
|---|---|
| D-1: no bounce-back; a local record of when each packet was received; re-accept only after a set period; expired packets are not relayed | §6.4 rewritten: a 20-minute lifetime carried on the link, a per-packet record kept 40 minutes, lying-peer rules; T-LIFE-1..5, T-PRIV-7; §0.4 item 7a |
| D-8: reliable in foreground and background on every platform | §7.7: mesh-only sealing in iOS bursts that cannot receive, wake lock until sent on Android, a larger unread queue; D-11 raised; §0.4 items 2, 7b |
| D-3: auto-off | §7.6: 12 hours, reminder at 30 minutes, Keep on; T-AUTO-1..3; §0.4 item 9a |
| D-9 (2026-11-11): mesh works with notifications denied | §7.1, §7.2, §7.6; T-NOTIF-3; F2 qualified |
| D-2 (2026-11-11, final): cover packets — after a first choice of real updates only was withdrawn | §5.1, §6.6, T-PRIV-4, T-SEC-7, §0.4 items 3, 7, 8 as originally drafted |
| D-5 (2026-11-11): hand-written Noise NN on every link | §6.7 rewritten; §6.2; §8.1; T-PRIV-8 |
| D-7 (2026-11-11): member bridging | §5.5 new; envelope format `0x02`; T-BRIDGE-1..9; Rule 13.1 and Rule 17 wording; §0.4 item 11a |
| Review of the D-2 and D-7 edits | The circle-linkage finding that reversed D-2; bridging gains receive-first, send-time checks in one hold, both time bounds, T-BRIDGE-10..12; |
| D-4, D-6, D-10 (2026-11-11) | Recorded in §11 as recommended / as milestoned |
| D-11 (2026-11-11): Bluetooth wakes plus an offer to turn background sharing on; location keep-alive specified as a fallback | §11 D-11; G-10 |

The independent review of these edits found, and the text above fixes:

| Finding | Change |
|---|---|
| Coarse lifetime steps lost a whole step per hop: packets died after 5–7 hops and the value counted hops | 256 fine units; random start over the top quarter; T-LIFE-5 |
| A peer handing a packet over early with a tiny lifetime killed it downstream | Bytes kept until first receipt + `L`; re-announce when the value is raised; T-LIFE-3 restated |
| "Relay send skipped" alone still let a mesh-only burst send other relay traffic | Mesh-only mark, `MeshOnly` outcome, nothing else driven; T-BG-2 widened |
| A suspended iPhone can keep advertising past the deadline | Stated in §0.4 item 9a and §7.6; deadline checked on every wake; T-AUTO-4 |
| The sniffer row said age was hidden | §8.1 corrected; D-5 note |

## 15. M1 module layout and engine interface

`haven-core/src/mesh/`, no MDK type, no I/O, no clock read, no static:

| File | Holds |
|---|---|
| `packet.rs` | `Packet` (1024 bytes), `PacketId` (`SHA-256(packet)[..16]`), `MeshKey` (HKDF of §4.2, zeroized), `wrap` / `open` for the envelope of §4.1 |
| `noise.rs` | `Noise_NN_25519_ChaChaPoly_SHA256` handshake and transport of §6.7 |
| `frame.rs` | The link frames of §6.2, encode and bounded decode |
| `store.rs` | Store, per-packet records, lifetime arithmetic, eviction, the unread queue (§5.2, §6.4, §6.5) |
| `engine.rs` | `MeshEngine`: links, inventory flood (§6.3), emission slots and outbox (§5.1), link budget (§6.1), counters |

`MeshEngine<R: RngCore + CryptoRng>` is driven only by calls, each taking
`now_ms` from a clock that keeps counting during sleep:

- in: `link_up(link, role, max_frame, peer)`, `link_down(link)`,
  `receive(link, bytes)`, `sighting(peer, rssi)`, `connect_failed(peer)`,
  `offer(slot, packet, expires_ms)`, `purge(slot)`, `advance()`, `stop()`;
- out: `poll_output(now_ms)` and `poll_output_ready(links, now_ms)` — the
  second serves only links whose radio can send, so a slow link holds up no
  other — yielding `Frame { link, bytes }`, `Close { link }`,
  `Connect { peer }`; `next_wake_ms()`. A frame is built by the poll that
  returns it, so its lifetime values are never stale;
- for session code: `take_unread(max)` returning packets not yet offered to
  it, `mark_read(id, opened)`, `stats()`.

`tests/mesh_sim.rs` runs N engines on a virtual radio with a logical clock
and seeded generators; it owns topology, loss, per-link byte rate and delays.

## 16. Implementation status

**M1 is built** (`haven-core/src/mesh/`, `haven-core/tests/mesh_sim*`): the
packet envelope, the Noise NN link, link frames, the store with records and
lifetimes, the engine and the multi-node simulator. A library with no caller.

- 181 unit and property tests, 38 simulator tests; the crate's other 2,005
  unit tests still pass; no crate or version added to any lockfile.
- Reviewed by independent Opus 5.5 passes: the cryptography (no blocker or
  high finding), the engine (3 high, 4 medium, 3 low — all applied), and a
  re-review of those fixes (2 defects the fixes introduced and 1 loosened
  test — applied), and a last check of those (all three fixed; one
  hardening added: a clock that jumps by years costs bounded work).
- Not run here: the coverage gate, the integration-test suite, and
  `cargo clippy --all-targets` to a clean exit — it stops on three errors in
  two existing test files on rustc 1.97.1, none in mesh code.

Known and not fixed, both low:

- A link whose radio never becomes ready keeps its connection until the
  radio layer drops it, because the close waits behind an unsent `BYE`; the
  engine has already freed the slot.
- A peer evicted from a full table of sighted peers returns without its
  back-off, so a flood of sightings can shorten it.

Parameters still to be fixed from data (G-7): the 150-phone scale was not
simulated; the largest run is 16 phones with the store scaled to match.

**M2 is under way**, to the code-level design in
`docs/BLUETOOTH_MESH_M2_DESIGN.md` (reviewed; its last section overrides its
body). Built:

- **M2a**, `mesh/event.rs` — a sealed location event to the envelope's
  contents and back, returned only if it verifies — with the test that pins
  MDK's tag layout and the size gate.
- **M2b**, the key ring (`nostr/mls/manager/mesh.rs`, a child module of the
  session manager; `circle/storage_mesh.rs`; the `mesh_keys` table). It keeps
  `G_e` and the packet key per circle for the epoch the engine stands on and
  the five before it, one key an epoch number, each with the routing id of
  its epoch. A key is read only while the circle is stable and MDK's
  exported epoch is that epoch, so a staged epoch's is never installed. A
  reselected branch, or a key the engine's contradicts, drops every other
  key of the circle. Keys exist only until the deadline
  `user_settings.mesh_on_until`, never more than twelve hours ahead; with no
  deadline or a passed one — at the open too — every row is deleted. A key is
  kept only for a circle whose row stands, and goes with the circle. The
  circle store now opens with `secure_delete`, as the MLS store does, so a
  deleted key is overwritten in the file and not left in a free page (test:
  `a_deleted_key_leaves_no_bytes_in_the_file`). Residual: the rollback
  journal of the deleting transaction is unlinked, not wiped, and flash
  storage keeps no promise about either; both hold ciphertext under the
  database key.
  **Not as the design has it:** a circle made or joined gets its first key at
  its next state-bearing batch, its first send, or when mesh is next asked
  for, because its row is saved after the batch that founded it; and nothing
  is derived at the open — the stored rows are restored.
- **M2c**, the hand-off (`mesh/handoff.rs`, `SessionManager::mesh_offer`):
  one call in `publish_location`, after its checks and before its relay
  send. The send-time check brings the circle's key in line in its own
  engine hold and reads the circle's turn; the offer is made only if nothing
  silenced the circle since — an epoch change, a commit or proposal of this
  device's recorded, fetched input held unread, a leave asked, sharing
  stopped, the circle's end, mesh off. A send waits for nothing of the
  mesh's: the ring's lock is only tried, the store is not written, and a
  deadline found passed is acted on by the next engine batch. `Handoff`
  keeps the last offer or purge of each of 64 slots for the engine's owner
  to take. Guard `scripts/ci/check_mesh_seams.sh` (T-INDEP-1c).

- **M2d**, the ingress (`Publishing::mesh_drive`; `SessionManager::mesh_read`
  and `ingest_from_mesh`; the counts in `circle/storage_mesh.rs`). A drive
  brings the ring in line with the engine, tries each packet under every
  key, rebuilds and verifies the event, and — before the engine sees
  anything — keeps only an application message whose inner epoch is the
  epoch of the key that opened its packet. A commit, a proposal, and an
  application message of any other epoch are read and dropped (T-SEC-1,
  T-SEC-2, T-SEC-5). What is kept goes into the engine in the finish-only
  mode, in `order_for_ingest`'s order, and is stored by the one persist site.
  **The drive calls no relay**: nothing is settled, driven or unblocked; a
  proposal the hold recorded keeps its record and an advance owed stays
  owed, for the next relay drive. A circle with a commit of this device's
  pending, or holding fetched input unread, takes nothing in; its packets,
  and those the engine did not keep or erred on, are held — the verified
  event, 64 a circle, 32 a circle a drive, oldest first — and go with the
  circle and with mesh. "Updates from your circles" counts an update when
  the engine reads it for the first time (§7.5). The four counts are in
  `user_settings`; the since-on pair starts again when a deadline is stored
  where none stood.
  **Not as the design has it:** the driver names no mesh module, so the
  packets and the answer cross it as `MeshPacket` and `MeshDrive`, declared
  beside the key ring; the ingest has no `observe` flag — the finish-only
  mode is what keeps the stall detector from arming a history walk on a
  mesh packet, and a source gate holds that; the held list keeps opened
  events, not packets to open again;
  `MeshDrive` carries no bridging input. The "passed on" side has its store
  and its fold (`CircleManager::fold_mesh_counts`) and no caller yet, and a
  reset of all four counts is not written: both come with the FFI.
  With it, four findings of the review of M2b/M2c were fixed: a send reads
  its circle's turn before its send-time check, and gets no hand-off if the
  circle fell silent while it checked; a deadline that passed
  with no engine batch ends the keys at the key-package maintenance tick,
  at a mesh drive, and before mesh is turned on again; a forgotten circle's
  delete the store refused is asked again, and the open restores no key of
  a circle whose row is gone; and the seams guard reads `mesh_offer(`
  however it is reached, and every mesh item under `relay/` and `nostr/`.

- **M2e**, the mesh-only seal (`Publishing::seal_for_mesh`, §7.7 R1). It
  seals as `seal_location` does, in the mode that makes no commit whatever
  its caller's, and calls no relay: a commit of this device's that is
  pending stays pending and defers the seal as awaiting relays; an eviction
  that is due is left due and holds it; unread fetched input, a leave and a
  disband hold it as they hold a relay seal; no repair runs and nothing is
  driven. With mesh off nothing is sealed and the engine is not asked.
  `publish_location` runs the same send-time checks, hands the event to the
  mesh as format `0x01`, skips the relay send, ends the record and answers
  `LocationPublish::MeshOnly`; a normal seal is unchanged and goes out as
  `0x02`. The bridge maps the new answer (`LocationPublishFfi::MeshOnly`)
  and the four Dart switches over it take it as neither a relay's answer,
  a failure nor a held send.
  **Not as §7.7 has it:** the mark is not inside the sealed value Dart
  holds. It is kept by the session, with the record's own entry and written
  in the hold that records the seal, so Rust routes the event whatever its
  caller does with it, and a process that did not seal it answers
  `Superseded` (design answer Q-3).
  **Not built here:** `seal_for_mesh` is not exposed over the bridge and the
  burst coordinator does not call it; both come with the FFI (M2g), and
  until then nothing in the app makes a mesh-only seal.
  With it, the findings of the review of M2d were applied. "From your
  circles" is counted off the engine's answer, not off a window of ids (§7.5).
  An update the mesh brings is noted nowhere the relay path reads what it
  has seen — not in the NIP-77 pass's memory, so the pass still asks for it
  by id, and not in the refused ledger — so a relay is asked the same
  whether or not the mesh brought it first. A proposal no record could be
  written for, handed back to a drive or a seal that may call no relay, is
  kept and sent by the next relay drive. A circle's unread input is held
  before the circle is silenced; a send's hand-off is cancelled by its own
  circle's silence and no other's; and an ingest that fails ends its
  circle's turn in that drive.

- **M2f**, member bridging (§5.5; `Publishing::publish_location_and_bridge`
  and its private `bridge_locations`; `SessionManager::mesh_bridge_take` and
  `mesh_bridge_check`; the candidates in the key ring's file). A mesh drive
  keeps a fellow member's location to be passed on when the engine read it
  for the first time and took it in, every packet of it this device opened
  was format `0x02`, this device's last relay fetch of the circle was
  answered to the end, and no leave is asked — the newest of each member,
  four a circle, 32 in all, in memory alone. It is sent by the entry that
  makes this device's own location send, after it, only when a relay took
  that send and only to the circle's relays that did; each event is checked
  against the engine in a hold of its own immediately before its send — the
  check a location of this device's passes at the epoch the update was
  sealed at, the circle still caught up and holding no fetched input unread
  — and against its own stamps: begun before 218 s, no declared life over
  228 s, not stamped ahead of the clock by more than a send. One attempt a
  relay, no record, no retry, the answer read by nothing; one update a
  member each 72 s. What a send does not pass on is dropped, and so is what
  a circle kept when it falls silent on mesh, when its relay receive begins
  again or the live plane pauses, with the circle, and with mesh.
  **Finding 1 of the design's review** is met by tying what is kept to the
  receive it was kept under, and by the caller's word: the entry is told
  whether this drive's relay receive of the circle completed before it, and
  passes nothing on otherwise. **A platform that publishes before it fetches
  therefore bridges nothing** (the Android service, until it has a bridge
  step after its fetch — not built). **Q-4** is met by construction: the
  bridge has no entry of its own.
  **Not as the design has it:** the engine announces an update under the
  SHA-256 of the MLS message its event carries, not under the event's id
  (MDK `content_dedup_id`), so the ingress keeps that digest with each held
  packet and finds the update by it; the per-drive bound is the circle's own
  share, since one send bridges for one circle; the sender's membership is
  not read apart, because the engine authenticated the update at the epoch
  the check requires the circle to stand on still; and the three time checks
  are made in the key ring's file, beside the candidates.
  **Not built here:** no FFI calls the entry, so nothing in the app bridges
  yet; T-BRIDGE-9 (soak) comes with the rig's mesh plane and T-BRIDGE-12
  with the enable flow. `CLAUDE.md` Rule 13.1 and its kind-445 row still say
  that only the fanout driver sends a kind 445 under a record: the sentence
  for the bridge is owed with the FFI that first reaches it.
  With it, four findings of the review of M2e were applied. An update the
  mesh brings stamps no inbound arrival, so it holds no epoch-rotation
  repair back (`CircleManager::fold_mesh_update`); relay input the same hold
  handed back stamps as ever. An update is counted where its packet is
  settled, never while it is held. Proposals owed a send are kept one an
  event id, sixteen at most, the oldest dropped; and the re-owe of one a
  drive could not send is tested.

Residuals of M2e. Two reads of the engine's own durable record of what it
has processed still see an update the mesh brought first, both only after a
relay-plane ingest of the same event has failed: the sweep then takes the
event as the engine's (`relay/catchup.rs` `ingest_judged`), and the NIP-77
pass's memory records it. A mesh update writes one stamp, "a peer's fix
arrived" (`last_peer_event_at_ms`), which the sharing-health model reads; it
no longer writes the inbound-arrival stamp (`last_inbound_event_at_ms`) the
gate of the epoch-rotation repair reads. A peer's update the mesh brings ends
the `Stalled` reading as one from a relay does; it arms no history walk and
moves none.

Residuals of M2f. Which drive a send belongs to is the caller's word
(`received`): this session can say only that its last fetch of the circle
completed and nothing has ended it since, which is also true of a device
that published before the fetch of its next tick. A relay subscriber of the
circle's routing id, not only its operator, sees a bridged event arrive tens
of seconds after its `created_at` (§0.4 item 11a names the operator).

M2f was reviewed (Opus 5.5, 2026-11-11): no blocker or high finding. Fixed
since: an update is kept to pass on only if nothing silenced its circle
between the opening of its packet and the engine taking it in, so a branch
reselected in that hold — same epoch number, another key — keeps nothing;
the bridge tests read the device clock at each drive unless a test sets
one, and the flooding test stamps its own events. Open, for the FFI step:
- a relay that takes this device's own send and withholds its answer on a
  passed-on event costs a send's wait for each, so in a background burst
  every circle's own location is sent before anything is passed on (met in
  M2g-1, below, by bounding what passing on may take of a call);
- bridge tests that set a clock and still use events stamped by the device
  hold only while the test runs for less than about ten seconds;
- not tested: a buffered update (T-BRIDGE-3), a proposal beside the commit
  of T-BRIDGE-5 (the same ingress gate), "once ever" across a restart (the
  engine's durable record is relied on), and the health model of T-BRIDGE-8
  other than by its source gate;
- a device clock set back after a jump forward keeps one member's updates
  from being passed on until the clock passes that instant.
The implementing agent ran no mutation pass on M2f; one was run on the turn
check alone.

Residuals of M2b, both in the tracker row `T-MESH-EXPORTER`: epochs crossed
inside one engine call, and epochs reached while mesh was off, have no key.
Residuals of M2d: an advance the engine is left owing after a mesh ingest
handed stranded input back waits for the next relay drive, with nothing
that asks for one; and no real engine answer was found that leaves a
mesh-admissible event unkept, so that arm is tested through a test seam.

- **M2g-1**, the Rust side of the bridge (`haven/rust_builder/src/api.rs`,
  "Bluetooth mesh FFI"), with the security documentation that was owed. The
  engine has a home: one a process, in the static `MESH`, reached only
  through `with_mesh`, which before every engine call checks the deadline,
  then applies what the session left in the hand-off — a purge empties its
  slot; an offer fills it for as long as its event still has by the wall
  clock, never longer than a location lives (228 s), and one already expired
  empties the slot instead — and only then runs the call. The lock is taken
  only in functions that are not `async`.
  **The engine's clock** is read in Rust for every entry (design answer
  Q-6): `CLOCK_BOOTTIME` on Android and Linux, `CLOCK_MONOTONIC` on Apple
  targets, both through `rustix`, with no `unsafe`. Apple's `clock_gettime(3)`
  says of `CLOCK_MONOTONIC` that it "will continue to increment while the
  system is asleep", and of `CLOCK_UPTIME_RAW` — what `std::time::Instant`
  reads there — that it does not. `rustix` 1.1.3 was in all three lockfiles
  already, so no lockfile gains a crate or a version; but until now only the
  desktop Linux keyring pulled it in, so the Android and iOS libraries
  compile it for the first time — `rustix` and `errno` on both,
  `linux-raw-sys` on Android (`cargo tree -i rustix --target …`, measured
  2026-11-11). **Owner decision open:** keep that (no `unsafe` in Haven's
  code, two or three more crates in the mobile libraries), or read the clock
  through `libc`, which every target already builds, at the price of one
  `unsafe` call. On any other target (Windows) the clock is `Instant`, which
  may stop while the machine sleeps: no radio is planned there.
  **Entries.** `mesh_start` (twelve hours from now; asked while on, it
  restarts them), `mesh_resume` (an engine for a mesh an earlier process left
  on, under the stored deadline, which a restart never moves), `mesh_keep_on`
  (restarts the twelve hours if mesh is on; after the deadline it turns
  nothing on), `mesh_stop`, `mesh_sharing_stopped`, `mesh_stats`,
  `mesh_reset_counts`, and on the relay manager `mesh_drive_driven`,
  `seal_location_for_mesh_driven` and `publish_location_driven`, which now
  takes `received` and goes through `publish_location_and_bridge`. What
  crosses is a fieldless state, bools, the four counts, the time left, and
  the locations every receive path hands over; neither new struct has a
  `Debug`, and the mesh's part of the bridge writes no log line.
  **The deadline** (design answer Q-7) is enforced where an entry is made:
  the engine keeps its own on the engine's clock, every entry that holds the
  session brings it no later than the session's, and the first entry after
  either drops the engine with every packet it held and calls
  `SessionManager::mesh_off`, so every key is deleted. An entry that holds no
  session — the radio's, when it is built — drops the engine at once and
  leaves the keys to the next entry that holds one.
  **Finding 7** is met at the session's open (`CircleManagerFfi::new`) and at
  every start, resume and keep-on: the engine takes that session's hand-off,
  and what the last session left in the outbox, under slot numbers the new
  one does not use, is purged.
  **Counts.** "Passed on" is fed from the engine's own count: each packet a
  drive settles is marked read in the engine, and what the engine has counted
  since the last fold is added to the stored totals at every drive, every
  read of the statistics, at mesh off and at the deadline. The reset of all
  four is written (`CircleManager::reset_mesh_counts`).
  **The open item of M2f** — a relay that takes this device's own send and
  withholds its answer on a passed-on event — is met in the core, by giving
  the bridge its own share of a wake: passing on begins no send once it has
  run for one send's time, so it adds under two to a call whatever the relays
  do. "Every circle's own location first" would need one entry for a whole
  drive's locations; the entries stay one a circle, as the app calls them.
  **Not as the design has it.** No entry takes `now_ms` (Q-6). `mesh_start`
  alone could not keep the deadline's promise — a start after a restart would
  have moved it — so `mesh_resume` and `mesh_keep_on` are entries of their
  own, and the answer is `Started` / `AlreadyOn` / `Off`. `mesh_drive_driven`
  takes neither `foreground` nor `receive_completed`: the core's drive reads
  neither, and it answers `more` when packets still wait. The slot is three
  states, not an `Option`: an engine ended by its deadline at an entry with
  no session leaves what it had passed on, and the keys, owed to the next
  entry that holds one. A poisoned lock does not read as "off" for ever: the
  engine whose call panicked is dropped. `seal_location_for_mesh_driven`
  seals nothing unless an engine runs to carry it. `mesh_stats` carries the
  time left (§7.6: "the sheet shows the time left").
  **Not built here.** The radio (M3): nothing calls `link_up`, `receive` or
  `poll_output` outside a test, and `with_mesh` has no radio-facing entry.
  The Dart side (M2g-2): at this step no Dart code called a mesh entry, the
  burst coordinator sealed nothing for the mesh, and the one Dart caller of
  the location send passed `received: false`; M2g-2a, below, is what stands
  now. The soak scenarios (T-INDEP-1a, T-BRIDGE-9).

Residuals of M2g-1. With no entry at all the engine sits in memory past its
deadline; it does nothing, since only an entry runs it. Across a process
restart the time left is the wall clock's word alone. No test can show that
the engine's clock runs while a device sleeps; that rests on the platforms'
documentation. Two sessions in one process — which only a test has — share
the one slot, and an entry made with a session whose mesh is off ends the
engine.

Review of M2g-1 (independent, read-only): no blocker. Fixed with it: the
documents said a passed deadline's keys go "at the first bridge entry after
it", which holds only while an engine runs — with none, a bridge entry reads
the deadline and deletes nothing, and the core's own paths do; an ask made
as the engine's deadline passed was answered `Off` (the confirmed deadline
now moves before the engine is adopted,
`an_ask_the_session_took_outlives_an_engine_deadline_that_passed_meanwhile`);
`more` had no test (`a_drive_that_leaves_packets_unread_says_so_and_the_next_reads_them`).
Left as found: an engine restarted in the same process after a panic takes
the session's time left, which a wall clock set back since has frozen — the
restart residual, in-process; `mesh_start`'s branch for a store that refuses
the deadline has no test at the bridge, since the real store has no fault
seam (the core's refusal is tested on its own store); an offer's 228 s cap
counts from the entry that applies it, not from the seal. Not confirmed
offline: that Darwin's `CLOCK_MONOTONIC` is free of wall-clock adjustments.

Written with M2g-1: the `haven-core/SECURITY.md` section "Bluetooth mesh
(opt-in second carrier)" and the scope notes beside the `kind:445`
expiration and the coalesced burst; the privacy-manifest invariants for the
keys at rest, the hand-off, the ingress, the mesh-only seal, the engine and
its deadline, the statistics, and the accepted deviation `MESH-BRIDGE` for
what a relay infers from a passed-on update. `CLAUDE.md` is the owner's: the
wording below is proposed, and not applied.

- **M2g-2a**, the Dart side of the bridge, behind a build flag that is off
  (`haven/lib/src/providers/mesh_provider.dart`,
  `haven/lib/src/services/mesh_service.dart`). No UI: no button, no sheet,
  no string. No Rust changed.
  **The flag.** `const meshEnabled = bool.fromEnvironment('HAVEN_MESH')`,
  default off, read through `meshEnabledProvider` so the default test run
  executes both builds. Two gates, and no other way to a mesh entry
  (`test/lints/mesh_entries_behind_flag_test.dart`): `meshServiceProvider`
  answers `null` with the flag off, and the Android service's isolate, which
  has no provider container, builds its mesh service only under the same
  const (a constructor argument). With the flag off nothing reaches the
  bridge whatever is asked of the mesh.
  **The service.** `MeshService` (interface) and `NostrMeshService`: the
  free entries through a seam (`MeshBridge`), the two driven ones through
  `CircleChangeDriver` and so through `NostrRelayService`'s drive registry,
  both among the entries a teardown waits out: neither asks a relay, and the
  session is not released under either. Every failure leaves as one
  fixed-text exception; nothing is logged.
  **Resume** is inside the service: before the first entry made with a
  session, once a session, keyed weakly on the `CircleManagerFfi` the circle
  service hands back — so it cannot run before a manager exists, runs again
  for a session opened since (a hand-back from the Android service), and
  holds no handle past its owner's release. The shell reads the mesh state at
  its start-up, with the identity resolved; the Android service's isolate
  resumes at the first drive of its own session.
  **State.** `meshProvider` holds what `mesh_stats` reports, whole, or
  `null` in a build without the mesh; `turnOn`, `keepOn`, `turnOff`,
  `resetCounts` and `refresh` each read it again. `turnOn` and `keepOn`
  answer whether mesh is on, by the variant: `Started` and `AlreadyOn` are,
  `Off` is not. It is dropped at a login and a logout.
  **The drive** rides three wakes and adds none. A foreground publish tick
  starts it once the tick's relay publishes are made, and does not wait for
  it. An iOS background burst starts it behind the burst's relay receive —
  after the backlog wait or the catch-up, before the first seal — and does
  not wait for it. The Android service's cycle awaits it between its fetch
  and the pool's close. What it read goes through the funnel a relay
  drive's replay goes through (`LocationSharingService.ingestReplayed`; on
  Android, the task's `_ingestReplayed`); where the map reads the cache it is
  told, and where it polls the relays it is not, since telling it would ask
  them. Up to four asks a drive while packets wait.
  **`received`**, the word `publish_location_driven` takes. `true` from one
  path: an iOS background burst, for that burst's own relay receive, by its
  typed answer — with a live plane, an open or a start into the burst that
  succeeded and `BacklogOutcomeFfi.settled`; with none, a catch-up that
  swept, was answered by every relay and was not cut by its deadline
  (`MapShell.catchupCompleted`). `false` from a burst whose open failed or
  whose backlog wait timed out; from a seal for the mesh alone; from the
  foreground tick and from the one-shot publisher, neither of which receives
  anything first; and from the Android service, whose cycle publishes
  (step 8) before it fetches (step 9). The relay path was not reordered to
  make any of these `true`.
  **The burst's mesh-only pass** (§7.7 R1): a burst whose receive FAILED —
  a catch-up that did not complete, or no session and none that could be
  started, the open that found its session gone included — asks whether mesh
  is on; if it is and the burst still owns the wake, each due circle is
  sealed for the mesh alone, the fold is skipped and the burst closes. One
  the foreground took back or whose consent was withdrawn seals nothing;
  with mesh off, and without the flag, the burst is as it was. The failed
  open is still told to the health model; nothing of a mesh-only seal is.
  **Sharing stopped**: `BackgroundSharingNotifier.setEnabled(enabled:
  false)` calls `mesh_sharing_stopped`, once.
  **Not as the design has it.** The foreground says `false`, not
  "`LiveLifecycleFfi.foreground`, `caught_up` decides" (design F.2): a
  standing subscription is no receive of this drive answered to the end,
  and a socket that dropped unseen would make that `true` wrong. The poll
  build's foreground says `false` too: its receive timer and its publish
  tick are separate drives. No mirror test pass is added (design I): the
  flag is injected at both gates, so the default run covers both arms; the
  one const the mesh's Dart code branches on is `liveSyncEnabled`, in a file
  the existing flag-off pass already runs. A mesh-only pass also stops when
  the foreground takes the engine back mid-pass, which the relay pass
  deliberately does not. Design J's line numbers for the burst tests had
  drifted; the tests are found by name.
  **Not built here.** Anything on screen (the button, the sheet, the enable
  flow, the notices): nothing calls `turnOn` outside a test, so mesh cannot
  be turned on in any build. The bridge step after the fetch on Android. The
  radio. The soak scenarios.

Residuals of M2g-2a. A burst does not wait for its mesh drive (the owner's
rule: the relay path never waits on the mesh), so a circle's own send can
begin before the drive has taken a fellow member's update in; that update is
not passed on by that burst and is dropped at its pause. **Owner decision
open:** keep that, or have the burst await the drive — bounded local work,
no relay — before its first seal, which makes passing on certain and holds
the publish for it. Nothing is passed on from Android or from the
foreground on either platform. A drive is a driven entry like the others: a
teardown that shuts the pool or hands the session back waits for one in
flight. A device with no circle eligible to publish arms no tick and drives
the mesh at none, so what it carried is counted as passed on only at a later
drive; the statistics sheet will need a drive of its own. The state is read
at build and after its own entries; a deadline that passes is not pushed.
`LocationSharingService.publishLocation` takes `received` with a default of
`false`, the safe word, so its many test call sites need not say it; the
driver and the circle service require it. Eight of the Dart files this step
touched were not `dart format`-clean before it, and were left as they were
outside the changed lines.

Review of M2g-2a (independent, read-only): no blocker. Fixed, each with a
test that fails without the fix. A mesh-only pass opened its GPS window for
its due circles, so a window that failed was recorded against each as a
failed relay publish — with mesh off the same burst records nothing; it now
opens the window for no circle. A location the mesh brought was logged
under an origin no relay plane used, which told a reader of logs that its
sender had been within radio range; it and a seal's replay now share one.
The Android cycle drove the mesh behind a foreground that had taken
ownership back mid-fetch, on the session the foreground was waiting for; it
no longer does. A resume that failed was remembered for its session, and so
refused every later entry, turning mesh off included; the next entry now
asks again. Raised and not so: that a logout leaves the engine in memory —
`wipe_all_mls_state`, which the logout calls, empties it first. Not
confirmed by the review: how long a mesh drive holds the engine lock on a
device, and whether a drive round that outlasts a burst's teardown brings
back an idle relay manager.

- **M2g-2b**, the soak rig's mesh plane and the two soak scenarios
  (`tooling/soak`: `rig/mesh.rs`, `scenarios/s27_mesh_independence.rs`,
  `scenarios/s28_member_bridging.rs`; `docs/SOAK_LANE.md` has each in full).
  No shipped code changed.
  **The plane.** One `MeshEngine` a device — the product's, at its default
  parameters — each generator seeded from the run's seed and the device's
  ordinal. A scenario says which devices are in radio range; a frame an
  engine hands its radio reaches the peer whole and at once; the engines'
  clock is a number the scenario steps, so an emission slot is reached and
  never waited for. Before each engine call the plane applies what the
  device's session left in its hand-off, by the bridge's own rule
  (`MeshSlot::apply`): an offer for as long as its event still has by the
  wall clock, 228 s at most; one already expired, and a purge, empty the
  slot. A device's unread packets go to its session through
  `Publishing::mesh_drive`, and what the drive settled is marked read.
  **S27, T-INDEP-1a** (`mesh-off-then-on`). One script in one world, twice:
  the mesh off, then on with every device in range of every other. Between
  the passes, per device, the multiset of the `EVENT` frames it sent a relay
  — (plane, kind, tag names, `expiration − created_at`, what the relay
  answered that device's endpoint) — is the same, and so is the answer of
  every seal and send, in order; a mesh drive asks its transport to send
  nothing and moves no cursor or backfill floor; a device reads from the mesh
  only an update whose send-time check passed; and the rig's plane oracle
  (O7) admits every frame of both passes. Counted apart, as the plan has it:
  the seal for the mesh alone (none with the mesh off, no relay frame with it
  on) and the one update passed on to the relay — any other frame carrying an
  event its sender did not seal is a finding. The script: a healthy round in
  which every peer reads each send from the relay before the mesh carries
  it; a device whose own endpoint refuses its events, whose update its peers
  then read from the mesh alone and the next sender passes on; a seal for
  the mesh alone; a send made a whole life after its seal (expired, and never
  handed to the mesh); one more send. Its floor: frames crossed links, an
  update was read from the mesh, it was passed on, a location was sealed for
  the mesh alone, and the refusal fell in both passes.
  **S28, T-BRIDGE-9**, in a circle of three: one offline and on mesh (its
  endpoint refuses its events, its engine is never told of the circle), one
  online and in its range, one far away with a relay and no mesh.
  `bridged-to-the-far-member`: a drive whose caller says `received = false`
  passes nothing on, then or later; a drive whose receive completed passes
  the next update on once a relay, byte for byte, and the far member's live
  plane delivers it. `removed-member-finds-nothing`: the online member
  removes the far one; the offline member, which never hears of it, seals at
  the epoch the removed member can still read; the online member reads that
  update from the mesh and sends with its receive completed; nothing of the
  offline member's is at the relay — its store, the bridger's transport, or
  the removed member's own view of it, which does show the bridger's own
  send. Each arm's floor is the premises of what it grades.
  **Lanes.** Both run in the `pr` soak profile, and so in the nightly and
  the weekly: the PR run budget rose from 1 320 s to 1 440 s (deadline
  25 min) and the nightly's from 6 240 s to 6 300 s (115 min). Each has a
  control that puts the mesh devices out of range and must answer rc 3, and
  `tests/oracles.rs` runs each arm twice under one seed and once under
  another, requiring the same verdict and the same digest of every `EVENT`
  frame sent.
  **Mutation pass, against the product**, each restored after its run:

  | Mutation | Red |
  |---|---|
  | `publish_location` hands off before its send-time checks | S27 `relay-path-moved` |
  | with mesh on, `publish_location` makes no relay send | S27 `relay-path-moved` (S28 rc 3) |
  | `bridge_locations` takes with `received` forced true | S28 first arm, `bridged-past-its-gate` |
  | `mesh_bridge_check` without `location_may_be_sent` | S28 second arm, `bridged-past-its-gate` |
  | `mesh_drive` sends each event it took in to the circle's relays | S27 `relay-path-moved`, and both S28 arms |
  | `mesh_drive` advances the circle's sync cursor | S27 `relay-path-moved` |

  **What the rig needed of haven-core**, in test-only code. The rig's
  devices dial each relay at an address of their own, and
  `RelayMappedFanout::publish_location` (`test-utils`) handed back the
  relays that took a location under the addresses dialled; the bridge
  compares them with the circle's own, so in the rig nothing was ever passed
  on. It now answers under each target's frozen spelling, as the type's
  contract says every answer is (unit test
  `a_mapped_transport_answers_a_location_under_its_frozen_targets`). The
  `security_rule_gates` list of what each file names of the driver's module
  gained the three new rig files.
  **Not as the plan and the design have it.** T-INDEP-1a's "the same profile
  and seed run with mesh off, then on" is two passes of one script in one
  world, the mesh-off pass first: a soak arm has one world. The plane is
  `rig/mesh.rs`, not `rig/plane.rs`, which holds the three environment
  traits a world is generic over.
  **Not built here.** A radio: links are whole and instant, so no loss,
  delay, throughput or connection limit is soaked (the M1 simulator has
  those). The app's own engine home — `with_mesh`, its sleep-counting clock,
  its deadline — is mirrored by rule, not run. With three devices the
  bridger of the removal arm is also the remover; a bridger that has not yet
  fetched another member's removal is covered by the `received = false`
  drive and by T-BRIDGE-10. The bridge's 218 s window, its 72 s spacing and
  its bounds are wall-clock terms the arms do not reach.

Residuals of M2g-2b. The comparison of S27 is by shape: a relay-visible
change that keeps every frame's shape and answer is not seen there. The
relay record is kept per connection, so the same frame sent twice on one
connection is one frame. `CLAUDE.md`'s CI section still calls the PR soak
profile "four durability scenarios"; it is six, and the file is the owner's.

### Proposed CLAUDE.md wording (owner to approve)

Each is the text as it stands, then the text proposed. Nothing in
`CLAUDE.md` has been changed.

**1. The stale sentence in "FFI Wrapper Pattern" (Architecture).**

Old:

> FFI does not expose Rust async streams; relay subscriptions use polling
> (manual refresh / app resume). Upgrading to `StreamSink` via
> `flutter_rust_bridge` is a known follow-up.

New:

> The live-sync engine pushes decrypted events to Dart over one
> `StreamSink<FfiRelayEvent>` (`LiveSyncFfi`); the flag-off build polls
> (manual refresh / app resume).

**2. Security Rule 5 (Secret Lifecycle).** One clause, inserted after the
clause on snapshots and checkpoints.

Old:

> … fork-recovery snapshots and own-commit checkpoints are bounded by
> convergence policy v1 `max_rewind_commits` = 5; a superseded KeyPackage's
> private material is deleted when …

New:

> … fork-recovery snapshots and own-commit checkpoints are bounded by
> convergence policy v1 `max_rewind_commits` = 5; while the Bluetooth mesh is
> on, each circle's `marmot/group-event` exporter secret is also kept by
> Haven — for the epoch the circle stands on and the same 5 before it, never
> for a staged epoch, in memory and in `circles-v2.db` — and every one is
> deleted when mesh is turned off, when its deadline (`mesh_on_until`, never
> more than 12 hours ahead) has passed, and with its circle (tracker
> `T-MESH-EXPORTER`); a superseded KeyPackage's private material is deleted
> when …

**3. Security Rule 13, invariant 1 (One way out).** One sentence, appended.

Old (the invariant's last sentence):

> The relay layer refuses any event that has a record, and the FFI's plain
> publish entry refuses every kind 445 and every kind 1059
> (`security_rule_gates::a_fanout_is_the_only_way_a_commit_leaves_the_device`;
> `the_plain_publish_refuses_a_gift_wrap`;
> `fanout_driver_e2e::nothing_but_the_driver_sends_an_event_that_has_a_fanout_row`).

New (that sentence, then):

> One kind 445 leaves with no record, and it is neither a commit nor a
> proposal: with the Bluetooth mesh on, a fellow member's location the mesh
> brought is passed on by `Publishing::publish_location_and_bridge` — that
> member's own sealed event, byte for byte, behind this device's own location
> send of the same circle and only to the relays that took it, only when the
> caller says the drive's relay receive completed first, once, one attempt a
> relay, never retried, its answer read by nothing
> (`mesh_bridge_e2e`;
> `security_rule_gates::the_bridge_sends_once_and_reads_no_answer`).

**4. Security Rule 16 (Relay Events Are Verified By Haven).** One sentence,
inserted after "A NIP-77 session carries no event; every event a pass leads
to is fetched by id on the publish client and passes `verify()` like any
other."

New sentence:

> The Bluetooth mesh is the one ingress that is not a relay client: the event
> rebuilt from a mesh packet passes `Event::verify()` in
> `mesh::event::rebuild` before anything is handed it, and
> `Publishing::mesh_drive` gives the engine only an application message of
> the epoch whose key opened its packet (Rule 17).

**5. New Security Rule 17.**

> 17. **Bluetooth Mesh**: the mesh is a second carrier for the location
> events the relay path seals, never a second protocol
> (`docs/BLUETOOTH_MESH_PLAN.md`). No cleartext field in a packet; the
> advertisement is the service UUID alone; no pairing. Only application
> messages cross it, checked at both ends: a location reaches the mesh only
> through the one hand-off (`SessionManager::mesh_offer`, once, in
> `Publishing::publish_location`, after the send-time check and before the
> relay send; `scripts/ci/check_mesh_seams.sh`), and a packet reaches the MLS
> engine only as an event that passed `Event::verify()` (Rule 16) and is an
> application message of the very epoch whose key opened it — never a commit
> or a proposal. The mesh has no sealing code of its own and never holds an
> MLS session (Rule 14); the mesh engine holds no key, and forwarding never
> depends on recognition. Mesh keys exist, in memory and at rest, only until
> the deadline `mesh_on_until`, never more than 12 hours ahead, and every
> path that ends mesh deletes them (Rule 5). The engine's store is memory
> only: one engine a process, reached only through `with_mesh`, on a
> monotonic clock that counts sleep and is read in Rust, its lock never held
> across an `.await`; the first entry after the deadline drops it.
> `mesh_drive` calls no relay and changes nothing a relay is asked; the mesh
> passes on to a relay only an event a member opened, and only as Rule 13.1's
> bridge. The mesh is lossy by design — the explicit carve-out from Rule 12's
> "never drop". Nothing of it is logged, and no packet, packet id, key,
> epoch, slot or link count crosses the bridge (Rule 15). NEVER give the mesh
> a way to seal, a second hand-off, an ingest that skips `verify()` or the
> epoch check, a store on disk, or a clock handed in by a caller.

**6. The kind-445 row of "Protocol Quick Reference".** The last sentence.

Old:

> Sent only by the fanout driver (Rule 13): a commit, or a proposal with a
> durable MDK fanout record, until a relay acknowledges it (a proposal no
> record could be written for, once), a location once per relay and never
> past its `expiration`; the FFI's plain publish entry refuses a kind 445.

New:

> Sent to relays only by the fanout driver (Rule 13): a commit, or a proposal
> with a durable MDK fanout record, until a relay acknowledges it (a proposal
> no record could be written for, once), a location once per relay and never
> past its `expiration` — and, with the Bluetooth mesh on, a fellow member's
> location the mesh brought, once, with no record, within 218 s of its
> sealing (Rule 13.1); the FFI's plain publish entry refuses a kind 445. With
> mesh on the same location event also travels in mesh packets, which
> outlive its `expiration` by design (Rule 17).

Next: M3, the radio, and with it everything on screen, as
`docs/BLUETOOTH_MESH_M3_DESIGN.md` has it; and, if Android is to pass
anything on, a bridge step after its fetch.
