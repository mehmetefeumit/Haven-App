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
6. Only the radio's entries run this schedule. Session code — the hand-off
   of item 1, a purge of item 2, a read of what came in, the statistics —
   runs none of the engine's timers: it runs right after a relay send, and
   an emission there would tie a slot to a time a relay saw. A slot that
   fell due is served by the radio's next entry, with what waits then.

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
  away, and never from an Android phone in the background, which seals
  before it fetches and so says "not received" (§16). That phone still takes
  in what the mesh brought it, behind each cycle's fetch — since 2026-11-12
  every cycle that got a publish to a relay fetches.
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
  be found but cannot search. **As researched, 2026-11-12 (§16):** the radio
  is started on API 30 and later only; what this says of API 23–29 stands as
  what those levels would have needed.
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
| Emission slot, announce tick, lifetime expiry | the radio's own timer, the processor kept awake by the location service's wake lock; never the location service's publish (§5.1 item 6) | allow-while-idle alarm (≥ ~9 min in Doze) and any radio event | process running | only on a Bluetooth wake |

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
  ordinal: over the same packets one seed carries the same frames in the
  same order (the plane's own test), but a world's packets are never the same
  twice — fresh events, nonces from the OS generator, lifetimes read from the
  wall clock — so a seed does not reproduce what a world's mesh carried. A
  scenario says which devices are in radio range; a frame an
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
  answered that device's endpoint, how many times it was sent) — is the
  same; so is, per endpoint of every plane and the canonical one included,
  the number of `REQ`, `CLOSE`, `NEG-OPEN` and other frames; and so is the
  answer of every seal and send, in order. The mark before each pass waits
  for a still wire — no endpoint carrying a new frame across three
  observations a tick apart, which every end of a NIP-77 session reaches;
  the pool sends a `NEG-CLOSE` only for a session it finished — the passes
  share one instant, and the last mark is behind the closing settle. A mesh
  drive asks its transport to send
  nothing and moves no cursor or backfill floor; a device reads from the mesh
  only an update whose send-time check passed; and the rig's plane oracle
  (O7) admits every frame of both passes. Counted apart, as the plan has it:
  the seal for the mesh alone (none with the mesh off, no relay frame with it
  on) and the one update passed on to the relay, in one frame a relay — any
  other frame carrying an event its sender did not seal, and a second frame
  of that one, is a finding. The script: a healthy round in
  which every peer reads each send from the relay before the mesh carries
  it; a device whose own endpoint refuses its events, whose update its peers
  then read from the mesh alone and the next sender passes on; a seal for
  the mesh alone; a send made a whole life after its seal (expired, and never
  handed to the mesh); one more send. Its floor: frames crossed links, a
  peer read the refused update from the mesh, it was passed on, a location
  was sealed for the mesh alone, the refusal fell in both passes, and no wait
  of the arm ran out.
  **S28, T-BRIDGE-9**, three members of one circle having a part (a wider
  world's other devices are in the circle and never told of it): one offline
  and on mesh (its endpoint refuses its events, its engine is never told of
  the circle), one online and in its range, one far away with a relay and no
  mesh.
  `bridged-to-the-far-member`: a drive whose caller says `received = false`
  passes nothing on, then or later; a drive whose receive completed passes
  the next update on once a relay, byte for byte, and the far member's live
  plane delivers it. `removed-member-finds-nothing`: the online member
  removes the far one; the offline member, which never hears of it, seals at
  the epoch the removed member can still read; the online member reads that
  update from the mesh and sends with its receive completed; nothing of the
  offline member's is at the relay — its store, the bridger's transport, or
  the removed member's own view of it, which does show the bridger's own
  send. Each arm's floor is the premises of what it grades, among them that
  the bridger's session KEPT the update to pass on before each send that
  must pass nothing on: a run with nothing kept is rc 3, never clean.
  **Lanes.** Both run in the `pr` soak profile, and so in the nightly and
  the weekly: the PR run budget rose from 1 320 s to 1 440 s (deadline
  25 min) and the nightly's from 6 240 s to 6 360 s (116 min). Each arm is
  priced at its closing round and one more round trip: after the first of
  its bounded waits that runs out it makes none, and `tests/oracles.rs`
  holds that price in a world whose relays deliver no location. Which wait
  it was decides what the run says: a delivery waited for and never made is
  `probe-not-delivered`; a wait of the setting-up — an entry's pass, a still
  wire, the bridger's catching up — is no finding of these arms', and the
  run is rc 3; a wait not made grades nothing. Each scenario has a control
  that puts the mesh devices out of range and one that runs it as after a
  setting-up wait that ran out, rc 3 each, and each arm holds after a
  foreground entry whose NIP-77 sessions no relay answered in time (the
  rig's `withhold-negentropy` fault); the arms are run in the nightly's and the
  weekly's worlds too; and each arm, run twice under one seed and once under
  another, must give the same verdict and the same digest of every `EVENT`
  frame sent.
  **Mutation pass, against the product**, each made in a copy of the tree:

  | Mutation | Red |
  |---|---|
  | `publish_location` hands off before its send-time checks | S27 `relay-path-moved` |
  | with mesh on, `publish_location` makes no relay send | S27 `relay-path-moved` (S28 rc 3) |
  | with mesh on, `publish_location` sends its event twice | S27 `relay-path-moved` |
  | `bridge_locations` takes with `received` forced true | S28 first arm, `bridged-past-its-gate` |
  | `bridge_locations` sends each update it passes on twice | S27 `relay-path-moved`; S28 first arm, `bridged-past-its-gate` |
  | `mesh_bridge_check` without `location_may_be_sent` | S28 second arm, `bridged-past-its-gate`, its floor met: the update was kept |
  | `mesh_taken_in` keeps nothing to pass on | rc 3 in S27 and S28's second arm; S28's first arm red, its update never delivered |
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

Residuals of M2g-2b. S27 compares what a relay's record can show of a
device, by shape and by count: not the order of its frames, not when each
was sent, not a connection opened that carries no frame, and nothing a
frame says beyond its shape — another `created_at`, routing id or filter
under the same verb compares equal — and not a NIP-77 session's course
after its opening (`NEG-MSG`, `NEG-CLOSE`), which is the relay's pace. The
marks stand behind a wire seen still for two ticks, which is an observation
and no guarantee: a frame a device still held back longer would fall in the
wrong pass and read as a moved path. A wait that ends in time is not priced,
for these arms as for every other. `CLAUDE.md`'s CI section still calls the PR soak
profile "four durability scenarios"; it is six, and the file is the owner's.

- **M3c**, the Dart seam to the radio, the turn-on, turn-off and keep-on
  ordering and the reconcile (`docs/BLUETOOTH_MESH_M3_DESIGN.md` §C;
  `haven/lib/src/services/mesh_radio.dart`,
  `haven/lib/src/providers/mesh_provider.dart`). Dart only. No UI: no
  button, no sheet, no string. No Kotlin, no Rust, no new package.
  **The seam.** `MeshRadio` (interface) and `AndroidMeshRadio`, over
  `haven.app/mesh_radio` (methods) and `haven.app/mesh_radio_state` (what
  the service reports: a status, or the name of a tapped notice's action).
  `meshRadioProvider` answers `null` unless the build has the flag and the
  platform is Android; with `null` no channel is touched and the mesh is
  driven as M2g-2a left it. The channels are named in that file alone and
  the radio is built in one, behind both gates
  (`mesh_entries_behind_flag_test.dart`). **The channels have no native
  end**: a start answers `failed`, every other entry throws one fixed-text
  exception, nothing is logged — so an Android build with the flag cannot
  turn mesh on, and stores nothing trying.
  **Turning on** (`MeshNotifier.turnOn`, answering a typed `MeshTurnOn`):
  the radio's permission, the caller's confirmation, whether Bluetooth is
  on — each a refusal with nothing to unwind — then `mesh.start()`, then
  `radio.start` with the notices' words under the deadline the engine holds.
  A radio that does not start is stopped and the engine with it, which
  deletes the keys and the deadline; if that fails the keys stay until a
  reconcile.
  **Turning off**: the radio, then the engine whatever the radio did.
  **Keeping on**: the engine, then `radio.sync` with the new deadline.
  **One queue.** A turn-on, a turn-off, a keep-on and a reconcile run one at
  a time in the order asked; a reconcile asked while one of the user's is
  asked or running is dropped, and each of those ends with one of its own.
  **Reconcile** runs at the shell's start-up, at every resume once the
  session is handed back, and on every report of the radio, from what the
  engine and the radio report then: equal, nothing; a radio up beside an
  engine that is off, the radio is stopped and the engine's keys deleted;
  an engine on beside a radio that stopped, the radio is started again if
  the service still wants it and holds its permission, and otherwise — or
  if that start fails — mesh is turned off and `meshStoppedNoticeProvider`
  set, once; an engine that cannot be read, nothing.
  **Logout** stops the radio before `wipe_all_mls_state`; so does the retry
  of that wipe, at a launch and before a new identity.
  **Not as the design has it.** The reporting channel is a message channel,
  not an `EventChannel`: `check_ios_background_publish.sh` allows one
  `receiveBroadcastStream(` under `lib/`, the iOS position stream's. It has
  no listen call, so a missing native end fails nothing, and the native end
  is not told when Dart starts listening. The notices' six strings do not
  exist yet (M3d), so `meshNoticeCopyProvider` answers `null`, and with
  `null` no radio is started: a turn-on fails before anything is asked. The
  Bluetooth-name step is a callback the caller hands `turnOn`, so the name
  never passes through the provider. Both unwinds stop the radio before the
  engine, where the design stops the engine alone: "never a second start"
  would otherwise rest on the native end clearing its flag at every failed
  start. A radio whose status cannot be read is taken as stopped by its own
  doing, so an engine on beside it goes off; the design's table has no such
  row. The start-up's reconcile is skipped under a pause the shell missed —
  a start the system refuses from the background would turn mesh off — and
  left to the first resume. `every_failure_has_fixed_copy` has no ARB key to
  map to: each failure is a variant of `MeshTurnOn`, and no exception text
  leaves the provider. The notification permission is not asked: §C.1 has
  no entry for it.
  **Not built here.** The native end. The strings and everything on screen;
  nothing calls `turnOn` outside a test. A consumer of notice taps
  (`actions`): one listener must take both actions, since a second would
  miss what the native end hands over at the first listen.

Residuals of M3c. A turn-off whose engine stop failed leaves the failure as
the state; if the reconcile that ends it then succeeds, mesh is off, the
state still shows the failure until the next read, and the notice is set
for a stop the user asked for. A radio stopped beside an engine that is off
is left alone whatever the service's flag says, as the design's table has
it. With the flag on and no radio — iOS — turning on still starts an engine
no radio serves, as at M2g-2a, and nothing on screen reaches it. That the
shell reconciles at its start-up and at a resume is pinned from the source,
like its other handlers. Mutation pass: 45 changes of a line or two to the
shipped code, each failing a test.

- **M3a**, the radio's entries over the one engine
  (`docs/BLUETOOTH_MESH_M3_DESIGN.md` §A.1–A.5;
  `haven/rust_builder/src/api.rs`, "Bluetooth mesh FFI"). Rust only, in the
  bridge crate: `haven-core` is not changed, no dependency is added, and
  there is no shim, no Kotlin and no Dart. **Nothing calls the entries in
  this build.**
  **Entries**, all `pub(crate)`, none `async`, none taking a session:
  `radio_resume(left_ms) -> bool`, `radio_left_ms() -> u64`,
  `radio_sighting(peer, rssi)`, `radio_link_up(link, central, att_mtu,
  peer)`, `radio_link_down(link)`, `radio_connect_failed(peer)`,
  `radio_receive(link, frame)`, `radio_poll(ready) -> Option<Vec<u8>>` and
  `radio_wake_in_ms() -> Option<u64>`, with `radio_frame_len(att_mtu)` and
  `RADIO_MAX_FRAME` = 512. Each but the start is `with_mesh` with no session
  and nothing else, so on every one the deadline is checked and the hand-off
  applied before the engine runs, and the clock is read in Rust
  (`the_radio_entries_take_no_session`, a source gate;
  `a_radio_entry_after_the_deadline_drops_the_engine_and_the_next_session_entry_deletes_the_keys`,
  entry by entry). A link and a peer are the radio's numbers.
  **Frame length** is one formula, in Rust: `min(att_mtu − 3, 512)`, and no
  link below 48 — an ATT MTU of 51. The radio hands over the MTU, never a
  length.
  **Bytes.** A frame longer than 512 closes its link and none of it is
  handed to the engine. Of `ready` the first 32 ids are read (`MAX_LINKS`,
  what a packet's record tracks; the engine has eight links), into a stack
  array; it is to name only links that are up. A poll answers one output, `kind ‖ id big-endian ‖ bytes`
  (1 send, 2 close, 3 connect), 9 + 512 bytes at most; the cases are written
  once, in `haven/rust_builder/fixtures/mesh_radio_outputs.txt`, which the
  Kotlin test is to read too. The links' number and rate, and who is
  dialled, stay the engine's.
  **One start (design F-16).** `with_mesh` is the lock and `mesh_run`, which
  takes none; `mesh_take` looks for the running engine and starts one under
  a single hold, for a session's open, for `mesh_open` and for the radio.
  The lock's holders stay four — `with_mesh`, `mesh_owed`, `mesh_empty`,
  `mesh_take` — and the gate names them. A session adopts a running engine;
  the radio adopts nothing, and leaves its hand-off and its deadline alone.
  **The start with no session** (`radio_resume`; design F-1, **owner
  question Q-2, open**): the service's word for how long mesh stays on, cut
  to twelve hours and good for one engine a process, while no session has
  spoken in it (below, "Review of M3a"). Built because §0.4 item 3 promises
  mesh after a reboot. It is that one function, one arm of `mesh_take` and
  the tests under "the start that holds no session": if the owner says no,
  they go and nothing else changes.
  **The session overrules the service.** A session that opens adopts the
  engine and brings its deadline no later than its own — at once, when that
  session's mesh is off.
  **Not as the design has it.** No `proptest`: it is in no lockfile of the
  bridge crate, and adding it adds packages; the two property tests draw
  from a fixed seed with `rand`, which the crate has. A frame too long
  closes its link by an empty frame handed to the engine, which closes a
  link whatever it expects next — the engine has no other way to be told;
  and for a link a radio entry made the bound changes nothing the engine
  would not do itself, since it refuses by length before it reads, so the
  test that holds the bound makes a link the engine was told carries longer
  frames. `check_generated_bridge_pinned.sh` pins the generated files, not
  `api.rs` (design §A.7): nothing was regenerated and no pin moved. The
  codegen does skip a function that is not `pub` — but it lists every such
  function, and every unused type, in a comment at the head of
  `haven/lib/src/rust/api.dart`, so **the next regeneration changes those
  two comment lines** (`mesh_adopt` leaves; `mesh_run`, `mesh_take`, `of`,
  the eleven `radio_*` and the type `Taker` arrive) and nothing else: a
  regeneration in a scratch copy left the other five generated files byte
  for byte. Until the shim calls them the entries are dead code in a build
  that is not a test: each carries
  `#[cfg_attr(not(test), expect(dead_code, …))]`, which M3b must delete —
  an expectation nothing fulfils is a warning. One test seam was added: a
  count, in a test build, of how often a thread took the engine's lock.
  **Not built here.** The shim, `jni`, the confinement of `unsafe`, the
  panic guard and the parity guard (M3b); the gate's clauses about
  `mesh_jni.rs`; the service and its copy of the deadline (M3g).

Residuals of M3a. The reader the tests decode a poll with is the tests'
own; the Kotlin reader is held to the same cases by the fixture, once it
exists. Nothing was type-checked for Android or iOS: no such target is
installed here.
Mutation pass: 35 changes of a line or a few to the shipped code, each
failing a named test. The first pass left two standing — a link too narrow
for a frame handed one all the same, and a start that let go of the lock
and took it again ahead of the point a first seam probed — and the tests
were changed until both fell.

Review of M3a (independent, read-only): no blocker. Fixed with it, in the
bridge and — for the second — in `haven-core`:
**The radio could start an engine after a session had spoken.** `Off` was
one state for a process no session had opened in, one whose session found
mesh off, one where mesh was turned off, and one whose ended engine was
paid for, so the service's remembered word could start twelve keyless hours
after any of them. The slot now starts `Unclaimed`; every entry that holds
a session, `mesh_empty`, `mesh_owed` and a poisoned lock leave `Off`; and
the radio starts an engine from `Unclaimed` alone: once a process, never
after a session's word, a turn-off (from the moment the engine is dropped),
a deadline, a wipe or a panic
(`once_a_session_has_spoken_the_radio_starts_no_engine`). With no session at
all a keyless engine so runs twelve hours at most, once a process; across
restarts the bound is the service's stored deadline (M3g).
**Session code runs no engine timer (R1).** A session's entry ran the
engine's timers exactly when it had just handed a location off — right
after a relay send — because `MeshEngine::offer` and `purge` ran the clock.
With the radio's timer late, emissions, `HELLO` renewals and ticks then fell
at relay-send instants (§5.1's independence); a purge was applied after the
overdue slot had taken what it withdrew (§5.1 item 2, the sharing-stopped
promise); and an offer missed the slot its own entry served. `offer` and
`purge` now name no time and run nothing, and only the radio's entries run
the schedule (§5.1 item 6; `haven-core`:
`session_code_runs_no_timer_and_the_radio_layers_next_call_serves_the_slot_with_what_waits`,
`emissions_fall_where_the_radio_layer_runs_whatever_session_code_does_and_whenever`,
`mesh_sim::a_phone_whose_radio_wakes_late_emits_only_when_it_wakes_whatever_its_session_does`;
bridge:
`no_session_entry_runs_the_engines_timers_and_the_radio_serves_the_slot_with_what_was_left`,
`sharing_stopped_after_a_slot_fell_due_unserved_withdraws_every_location_that_waited`,
`only_the_radios_entries_call_what_runs_the_engines_timers`). A location so
leaves in the first slot the radio serves after its hand-off.
**An ask in the deadline's last moments** that a radio entry got ahead of —
the engine already `Ended` when `mesh_start` reaches it — was answered
`Off`; it now starts an engine under the new deadline, which carries what
the ended one is owed
(`an_ask_the_session_took_starts_an_engine_over_one_a_radio_entry_found_ended`).
Stated: what `radio_poll`'s `ready` may name; that 32 is `MAX_LINKS`, not the
engine's eight links; that a keyless engine's "passed on" also counts what
falls off a full unread queue; that the two source gates read the entries'
own text and no further, and that the bridge's random-input test reaches the
handshake and the length checks only.
**Open, for the owner, not built (R2).** Where a phone's power manager
suspends the processor between the location service's wakes (unverified;
vendor builds), the radio's own entries fall inside those wakes — its
timer's handler, frames answered, `HELLO` renewals, link rotation — so
emission instants can still follow relay sends there. Closing it needs
every on-air timer to run from the radio's alarm alone, at the price of
almost no delivery of this device's own location in that regime. And an
engine's first slot is drawn from the instant it starts, which follows a
relay send when a session's `mesh_resume` starts it: one weak observation a
process start.

- **M3d (English) and M3e**, the mesh's strings and everything on screen
  (`docs/BLUETOOTH_MESH_M3_DESIGN.md` §D, §E;
  `docs/BLUETOOTH_MESH_AURA_DESIGN.md`, whose §11 has what the build found).
  Dart only, behind `HAVEN_MESH` and only where there is a radio. No Kotlin,
  no Rust, no bridge regeneration, no new package. The native end is still
  missing, so a turn-on asks the channel, fails with fixed words and stores
  nothing.
  **Strings.** 67 keys in `app_en.arb`, each with a description that tells
  a translator what the string stands beside and where its length or its
  grammar matters; the English has been through a code review and a review
  of rendered screens (below). All thirteen locales carry them
  ("Localization", below), and `arb_parity_check.dart` passes. `meshNoticeCopyProvider` is filled from them, so a radio can
  be handed its notices; the time mesh turns itself off is a clock time in
  the language's own short form — the `jm` format of the `{time}`
  placeholder in the two keys that tell it, which is the whole of that
  choice (Q-7).
  **What the map is told** (`mesh_provider.dart`; nothing else names the
  radio). `meshAvailableProvider`: a radio exists and has not answered that
  this phone cannot run the mesh — an answer kept for the life of the
  process and stored nowhere, with which the button that could never work
  goes, and the Settings row, the aura and the sheet's own control with it.
  `meshRadioStatusProvider`: the radio's last report, taken as it is pushed
  and read beside every read of the engine's state; a read that fails
  changes nothing, and an answer that lands behind a later read or report
  is dropped. `meshOnUntilProvider`: the deadline by the device's clock,
  kept through a read of the engine that fails and dropped with the
  identity. `meshPhaseProvider` — S1:
  on only while the radio reports that it runs, the engine was on when last
  read, and the deadline has not passed by the device's clock; a timer of
  its own reads the clock again at the deadline and asks nothing of the
  engine, and the shell invalidates it at every resume, where a timer may
  be late. `meshHandOffProvider` — S2: the foreground publish tick and the
  one-shot publisher tell it once a pass, at the first send that got past
  the send-time check (a relay took it or did not, or it was for the mesh
  alone); it counts only while S1 holds and, read afresh, a phone is linked.
  Both tell it through `noteMeshHandOff`, which is not waited for and keeps
  whatever the telling throws, at once or later. It is the hand-off, not
  the radio's emission, and a background burst tells it nothing.
  **Turning on and off** is one flow (`widgets/mesh/mesh_flow.dart`),
  whether asked from the button, from the notice of a stop or from the
  statistics sheet, and one at a time wherever asked. The first turn-on
  shows the disclosure, then asks the permission, then — where the name can
  be read — shows the phone's Bluetooth name, large and first, with the way
  to the system settings that change it, and only then is anything stored;
  the disclosure counts as read once that step is passed, and a logout
  forgets it. Every `MeshTurnOn` has fixed copy, with its remedy where
  there is one. A turn-off is judged by a read made after it: a stop the
  step could not make and its closing reconcile then made is the user's
  own.
  **The button** (`MeshButton`), bottom-left above the collapsed sheet on
  `meshButtonRect`, the same in a right-to-left language, level with the map
  controls opposite and under the expanded sheet; above the map page's own
  scrim and error overlay, since the mesh needs neither tiles nor a fix. A
  tap turns mesh on or off; a hold, the screen reader's own action, the
  Settings row and a tapped notice each open the one statistics sheet
  ("Keep on" from a notice restarts the twelve hours first). To a screen
  reader it is "Bluetooth mesh", on or off as a toggle, and "paused" or
  "connected" as its value: the state is said once. To the eye it is the
  plain Bluetooth icon, outlined while off and on a filled blue while on;
  the connected icon with a dot while a phone is linked; the struck-through
  icon with a blue edge and a pause mark while Bluetooth is off — never
  colour alone. A turn-on under way is a ring on the button, still where
  motion is reduced, and announced once. What the button says — that mesh
  is on, with where the statistics are and an Undo; a failure, with its
  remedy — is said in the app's snackbar for long messages, floated above
  the button and clear of the map controls so that neither is covered, at
  200 % text on a small phone too; it goes by itself after eight seconds
  unless it carries a remedy.
  **A stop the user did not make** — the deadline, a service that stopped,
  the reconcile's own — is a notice beside the button, announced once, that
  stays until dismissed or until mesh is turned on from it. It says "after
  12 hours" where the device's clock has passed the deadline the engine
  gave, the one cause Dart can know, and gives none otherwise.
  `meshStoppedNoticeProvider` is what holds it, set by the reconcile or by
  the button on an unasked change to off, and dropped with the identity. A
  pause is announced. The user's own stop is neither, whenever the radio's
  report of it arrives; a turn-off that failed is not their stop, and nor
  is one that follows their turning mesh on again.
  **The disclosure**, under three headings — what it does, what others can
  learn, good to know — tells §0.4 items 3, 5, 6 (presence, direction
  finding, and that a phone which connects can recognise this one again
  after its address changes), 7, 7a, 7b, 8, 9a and 11a (both of a relay's
  inferences), the Bluetooth name in both directions of connection (F-6),
  and — more than the design's text — that it works only between nearby
  phones with mesh on and that updates can be late or lost. It is reachable
  again from the statistics sheet, with no "Turn on".
  **The statistics sheet**: one status line, the time mesh turns itself
  off, Turn on or Turn off through the flow above with a failure said in
  the sheet, the Bluetooth settings while paused, Keep on, the two things
  counted each with its two counts, the footnote, Reset behind a question.
  A count is one line: drawn smaller where it does not fit, never wrapped
  or cut, in digits of one width. With mesh off the first column is "Last
  session": the core keeps what was counted since the last turn-on until
  the next one (`storage_mesh.rs`: a total less a baseline that only a
  turn-on sets). The sheet drives the mesh once when it opens and reads the
  state; while it is open and the app in front it reads again each minute —
  away, its timer is cancelled — and on every report of the radio. The
  counts are shown and never logged.
  **The aura**: the wave, the hue and the ripple, as the aura design has
  them and its §11 qualifies; the hue is 0.35 at the edge, and the ripple a
  lighter blue on the dark basemap.
  **Not as the designs have them.** The design's keys, as the reviews
  left them: `meshButtonOff`, `…On`, `…OnConnected` and `…Paused` are one
  name and two values (`meshButtonLabel`, `meshButtonValuePaused`,
  `meshButtonValueConnected`); `meshIntroTurnOn` is `meshTurnOn`, used
  wherever mesh is turned on, with `meshTurnOff` beside it;
  `meshStatsSinceOn` is `meshStatsThisSession` and `meshStatsLastSession`;
  and there is no `meshName`, which nothing showed. New:
  `meshButtonHintStats` (the hold's hint is read after "double tap and hold
  to", so it is a verb phrase, not the sheet's title),
  `meshStatsUnavailable`, `meshStatsAbout`, `meshStoppedAfterDeadline`,
  `meshTurningOn`, the disclosure's three headings and the name step's two
  lines. The statistics sheet lays its four counts out as two rows of
  two, each count over its caption, not as a table with column headings: a
  three-column table does not survive 200 % text on a small phone. The
  Bluetooth name is in the disclosure, one tap from the statistics sheet,
  not on the sheet itself: the sheet is to be succinct. An unasked stop is
  a notice that stays, not an announcement alone: an announcement made
  while the app is away is heard by nobody, and M3g's review makes the
  in-app notice the one that must be seen (below). The hold's haptic is the
  ink well's own, on Android; no second one is made. Everything the button
  says is said in the wrapping snackbar the app already has: the Material
  action slot overflows at 200 % text, and a plain snackbar lifted clear of
  the button runs off the top of a small screen. The minute's read drives
  nothing: a timer that drives would be a new wake of the engine
  (`engine_work_no_background_timer_test.dart`). The reduced-motion and
  resume tests of S1 are of the provider, the shell being unpumpable.
  T-NOTIF-3's Dart half is not built: the radio's seam has no entry for the
  notification permission (M3c).
  **Not built here.** The native end, so nothing
  of this has run against a radio. Anything on iOS. A look at any of it on
  a device: the aura's softness, the hue's strength (`kMeshHueEdgeAlpha`,
  0.35 as built; the owner had 0.50 against 0.35 open, and it is that one
  constant) and the ripple's two blues were judged on rendered frames, by
  nobody on a screen.

Residuals of M3d/M3e. `meshNoticeCopyProvider` is still typed to answer
`null`, which now only a test makes it do; the branches that refuse a radio
without words are unreachable in a build and could go with their tests. The
clock time follows the language and not the device's 24-hour switch. The
time shown is the engine's time left added to the clock at each read, so it
can move by a minute between two reads either side of a minute's edge.
"Linked" is as fresh as the last read of the state — a transition, a
reconcile, a publish pass while mesh runs, the open sheet's minute — so the
button's mark can lag a link by as long. The twelve hours in three
strings, and the half hour in one, are tied to no constant Dart can read:
the figures are Rust's. "After 12 hours" is said where the device's clock
has passed the deadline; a clock set forward says it of a stop with
another cause. With the flag on and no
radio — iOS — nothing of the mesh is on screen, and the engine a `turnOn`
would start there is still reachable only from a test. That a phone cannot
run the mesh is forgotten with the process, so the next launch shows the
button once more and asks once more. The statistics sheet's title is "Mesh
activity", not "Bluetooth mesh activity": the longer one takes a third
line at 200 % text on a small phone. There, the name step shows its title,
the name and its two buttons; the sentence about the name, which the
disclosure has just told, and the way to the settings are reached by
scrolling it. The disclosure's assurances about what
a carrying or a connected phone cannot read rest on the core's packet
envelope, which has no row in the privacy manifest yet (owed with the
radio).

Localization of M3d. One translating agent a language for the twelve other
locales, then one independent reviewing agent a language, whose changes the
translator applied or answered; every language was approved with changes,
none as it stood. What the translators found in the English, fixed there:
"doesn't send or read your circles' locations" did not say whose location
is not sent (six languages); "its Bluetooth address" could be either
phone's; and the notice's Dismiss is, in Hindi, Nepali and Turkish, the
word for "turn off" — so the notice and the mesh's brief messages close
with a key of their own, `meshStoppedOk`, never `commonDismiss`. What the
reviewers ruled: "Bluetooth" is written as Android's own interface writes
it in each language — in native script in Arabic, Persian, Hindi, Nepali
and Urdu (where a notification that begins with a Latin word also takes a
left-to-right base direction), in Latin in the other seven; Persian says
«شبکهٔ مش» and never a bare «مش», a homograph; Brazilian Portuguese says
"rede mesh", not "malha". Each language's screen-reader fragments were
written against TalkBack's published templates for that language; in Hindi
those templates are themselves ungrammatical and no fragment makes a
correct sentence — the least bad form is used, and a full-sentence hint in
the app's own words would be the fix. On Android the button's value is
spoken before its name, not after as the first notes said; every
language's fragment stands on its own. Not checked by anyone: any of it on
a device, a screen reader's actual speech, and whether the one-line
notification texts fit a narrow phone — several are longer than the
English and their translators say so.

Reviews of M3d/M3e (two, independent and read-only: the code, then the
screens, rendered from the real widgets at 320×568 and at 200 % text, for
use and accessibility). No blocker. Each finding was checked against the
code or §0.4 first; each behaviour changed has a test that fails without
it. From the code: **the word that mesh is on never left** — in this
Flutter a snackbar with an action persists — and held every later word in
the app behind it; **the word to the ripple could reach a relay publish**,
the scheduler calling the notifier bare, and no test said otherwise — both
publishers now tell it through one guarded helper, tested with a word that
throws at once, one that fails later and one that never answers; **a read
of the radio that failed or came late showed mesh as off** and raised the
notice; **a turn-on answered that it failed beside a mesh that was on**,
where the state could not be read behind a start that answered — it is
turned off again first; **the user's own stop stayed theirs** after a
turn-off that failed; the state was said twice to a screen reader; the
sheet's timer ran while the app was away; a hand-off told while away
played its ripple at the return; and the disclosure left out
re-identification (§0.4 item 6) and the second of a relay's inferences
from bridging (11a). From the screens: a count broken in the middle of a
number at 200 %; the word that mesh is on, lying over the button it came
from; no way on from the sheet the Settings row opens, or from the notice
of a stop; "since turned on" beside "mesh is off"; a name step whose name
was below the fold; icons that struck Bluetooth through while it was on
and not while it was off; a hue that read as a line and a ripple lost on
the dark basemap; a button left on a phone that cannot run the mesh; and
a disclosure of eleven paragraphs with no heading.
Found by the mutation pass, by neither review: a turn-off whose engine
stop failed once and was then made by the turn-off's own closing reconcile
was told as "couldn't turn off" beside a notice that mesh had turned off.
A turn-off is now judged by a read made after it.
Not as a reviewer had it. A stopped notice does not reach the next login:
one raised behind a logout is dropped when the next identity is made
(`mesh_radio_flow_test.dart`, "a notice the radio's own stop raises late
in a logout is not the next identity's"); nothing was changed. A count
needs no line limit inside the box that scales it. "Hold the button" is
"Press and hold": the reviewer's own note that "hold" alone translates
poorly. Not taken: a line for counts that are all zero; "Bluetooth mesh
activity" as the sheet's title (above).
Mutation pass, on the tree as it stands: 163 changes of a line or a few to
the shipped code, each failing a named test — one of them, a deadline
check without which the provider re-arms a timer already due for ever, by
tests that do not complete. Survivors on the way, each now a test or
gone: a pause's mark, a painter's repaint, a ripple that took a member
marker's tap and a key nothing needed (first pass); the paused button's
blue edge, a start announced twice across the name step, a remedy's word
taken away after eight seconds, a word shown for four seconds and not
eight, the hue's falloff, a stop told as the user's after they had turned
mesh on again, an old failure left in the sheet through the next try, and
two line limits and a dialog inset that changed nothing, which went.

Review of M3c (independent, read-only): no blocker; two medium and four
low findings, each checked against the code first. Fixed here, each with a
test that fails without the fix. **A reconcile was dropped while a
transition was asked or running**, and the transition's own closing
reconcile reads the radio before the transition is released: a service that
stopped itself in that window — after a start that answered — left the
engine on with its keys and no radio until the next resume. A reconcile now
runs in its turn behind the transition, once however often it was asked
meanwhile; nothing is dropped. **No radio call was bounded**, so a service
that never answered would hold a logout before its wipe, a launch before
its first frame, and the queue for the life of the process. Every call is
now bounded where it is made (`AndroidMeshRadio`: five seconds; two minutes
for the permission dialog, which waits on a person and whose answer an
activity recreated under it loses), and one not answered by then failed as
one the platform refused. The permission's bound answers as a failure, not
as a refusal: "needs the permission" would be said of a dialog nobody had
answered. **A turn-on and a keep-on answered before their own closing
reconcile**; they answer from the state it left — and where that state
cannot be read, a turn-on turns mesh off again before it answers that it
failed, and a keep-on was kept (the review of that fix, above). **A logout
stopped the
radio late**, behind the live-sync stop and the close; it stops it as soon
as the wipe marker is set. The reason the code had for the late stop was
that behind the close a reconcile could read no engine and so raised no
notice; one raised now is dropped with the identity.

Owed by the native unit, M3g — its acceptance tests on the Dart side's
terms. (a) Once `start` answers `started`, `status` reads a state other
than stopped with `wanted` true before that reply is sent; `stop` clears
`wanted`, and so does a service that stops itself — otherwise the turn-on's
own closing reconcile undoes every turn-on with a notice of a stop by
something else, or reconciles loop. (b) Every channel method answers,
inside the Dart bound. (c) Whether the service reads the logout's wipe
marker itself, so that a logout that died after its radio stop cannot be
followed by a sticky restart. (d) On Android 13 and later without the
notification permission the service's stopped notice is seen by nobody, so
"never on with no radio and no notice" rests on the in-app notice alone;
that notice is built here and stays until dismissed. (e) `start` answers
`unsupported` only for hardware that can never run the mesh: Dart then
removes the button, the aura and the Settings row for the life of the
process, so an adapter that is off at that instant, or any passing error,
is `failed`. (f) `radio_resume` answering false stops nothing: a session
that opened first has claimed the process, and the engine comes at that
session's first mesh entry — so every flow that opens a session with mesh
on must reach one, or mesh reads on in the store with a service running
and no engine.

Re-reviews (independent, read-only). Of the engine and bridge fixes: all
three hold, no blocker; found and left, since it predates them and heals at
the next entry: a turn-on made while another session entry is settling an
ended engine can have its new deadline deleted by that entry's `mesh_off`,
and the tap has to be repeated. Of the UI's fixes: all hold, no blocker;
fixed with it, each with a test: a stopped notice raised by a clock that
ran ahead of a deadline the engine still held stayed up beside a mesh that
was on — a notice is now withdrawn whenever mesh is on; and backing out of
the disclosure took an owed notice away with it — only a flow that ended
or failed does. Left: two requests for the statistics sheet in one frame
open two.

- **M3b**, the JNI shim over the radio's entries, and `unsafe` confined
  (`docs/BLUETOOTH_MESH_M3_DESIGN.md` §A.6, §A.7;
  `haven/rust_builder/src/mesh_jni.rs`, `lib.rs`, `api.rs`;
  `scripts/ci/check_mesh_radio.sh`). Rust in the bridge crate, one guard and
  documents: no Kotlin, no Gradle, no Dart, nothing in `haven-core/src` or
  `tooling/soak`. **No Kotlin declares or calls an export, so nothing runs
  the shim in any build.**
  **Exports**, nine, each `#[no_mangle] pub extern "system" fn
  Java_com_oblivioustech_haven_mesh_MeshNative_<name>`, here with its JNI
  descriptor: `resume (J)Z`, `leftMs ()J`, `sighting (JI)V`,
  `linkUp (JZIJ)V`, `linkDown (J)V`, `connectFailed (J)V`,
  `receive (J[B)V`, `poll ([J)[B`, `wakeInMs ()J`. They are pinned, with
  their Rust types, in `haven/rust_builder/fixtures/mesh_radio_exports.txt`,
  which the Kotlin `external fun`s are to be read against. Each converts its
  arguments, makes one `radio_*` call under the guard and converts the
  answer; of the bridge the shim names the entries, the guard and the frame
  bound, and nothing else. It calls nothing of Java's, keeps no `JavaVM`, no
  reference and no state, attaches no thread, logs and renders nothing.
  **Conversions**, plain functions tested with no JVM: a frame's length is
  read first and one over 512 bytes is not copied out of Java; a poll's list
  is cut to 32 before it is read; `peer < 0` on a link is no peer; a
  negative `leftMs` is none left; `rssi` and `attMtu` are clamped into their
  types; a link's and a peer's number cross bit for bit; `wakeInMs` answers
  −1 for no engine. A JNI call that fails is answered as no engine would
  answer, and the exception it may have left is cleared.
  **The guard** (`radio_guarded`, `catch_unwind`): an unwind out of an
  `extern` function aborts the process, which is the relay path's too
  (design F-14). **What a panic leaves:** the guard answers that entry's
  no-engine value; every engine call runs under the engine's lock, so the
  lock is poisoned before the guard has the panic — the guard hides nothing
  from that path — and the next entry of any kind drops the engine and
  leaves `Off`, from where the radio starts no other. A panic that held no
  lock met no engine and leaves it
  (`a_call_that_panics_under_the_guard_answers_its_no_engine_value_and_leaves_no_engine`).
  **`unsafe`** (design F-8): `lib.rs` denies `unsafe_code` and allows it on
  `mod frb_generated` and `mod mesh_jni`, nowhere else. `api.rs` and the test
  keyring compiled under the deny unchanged — the design's open question. In
  the shim the lint fires on `#[no_mangle]` alone; the file has no `unsafe`
  block.
  **Dead code.** With the shim their only caller, the entries and the guard
  are dead in a build that has neither the shim nor the tests — every
  target but Android. Deleting the nine `expect(dead_code)` outright left 14
  dead-code errors in the host's non-test build (the nine, the guard,
  `radio_frame_len`, `radio_encoded`, `RADIO_MAX_FRAME`, `Taker::Radio`).
  Each of the ten now carries the expectation under the negation of its
  caller's own condition, `not(any(target_os = "android", test))`: ten
  attributes, where compiling the entries out would take fourteen and a
  second shape of `mesh_take`. A host build with the shim compiled in and no
  tests (a probe `cfg` in place of `target_os = "android"`) is clean, and is
  not when an entry still expects to be dead.
  **`jni`** 0.21, direct for Android and a dev-dependency for the host's
  type-check: `haven/rust_builder/Cargo.lock` gained one line — `"jni"` in
  `rust_lib_haven`'s list — and no package (525 before and after); the other
  two lockfiles did not change. RustSec's advisory database at `fd6f398`
  (2026-11-11) has no advisory for `jni`, `jni-sys`, `cesu8`, `combine`,
  `walkdir` or `same-file`; `cargo-audit` is not installed where this was
  built and was not run.
  **The guard script**, `check_mesh_radio.sh`, two steps of
  `repo-guards.yml`: `unsafe`, `no_mangle` and an ABI string under
  `haven/rust_builder/src` in the generated bridge and the shim alone; the
  deny and its two allowances, and `unsafe_code` named nowhere else; every
  export `#[no_mangle]` above the one header shape, one guarded call of one
  entry with nothing else under the guard, no entry named outside an export;
  the exports equal to the fixture, descriptor included; and on a `JNIEnv`
  the five calls the shim makes (`get_array_length`,
  `get_long_array_region`, `convert_byte_array`, `byte_array_from_slice`,
  `exception_clear`) and no other. 44 self-test fixtures.
  **Source gates**, extended: `the_radio_entries_take_no_session` (the
  shim's one `use` of the bridge names `radio_*` and the frame bound, and it
  names nothing a session is reached by),
  `the_engine_lock_is_taken_only_where_nothing_can_be_awaited` (the shim
  names neither the static nor a lock holder),
  `the_mesh_entries_log_nothing_and_format_nothing` (also reads the shim);
  new: `every_export_is_one_guarded_call` — the nine by name, each its own
  entry and nothing else under the guard, and no `panic!`, `unwrap()` or
  `.expect(` in the shim.
  **Owner question Q-2 is still open.** The `resume` export exists as
  designed, in one place: if the owner says no it goes with `radio_resume` —
  one export, one fixture line, one row of the gate's list.
  **Not as the design has it.** A frame too long is not dropped by a
  `return` (§A.5), which would leave its link up with a frame lost: the
  entry is handed 513 bytes of nothing and closes the link, as it does for
  any frame that long. The second parameter of an export is `JObject`, not
  `JClass`: `MeshNative` implements `MeshEngineApi` (§B.1), so its methods
  have a receiver; the pointer is the same and is never read. The guard
  script's parity check has one side: no `MeshNative.kt` exists, and its
  half lands with the Kotlin. A JNI failure and a negative `leftMs` are
  answered as above, which the design does not say. `clippy::pedantic` and
  `nursery` are `haven-core`'s lints, not this crate's, which has no
  `[lints]` table. Found: `jni`'s wrappers write a `trace` line naming the
  JNI function they call, a fixed word; the bridge's logger admits Haven's
  two targets alone and caps the level below `trace`, so none is emitted.
  **The generated bridge** was not regenerated and no pin moved. A
  regeneration in a scratch copy changed one comment line of
  `haven/lib/src/rust/api.dart` — `radio_guarded` joins the functions listed
  as not `pub` — and left the other four Dart files and `frb_generated.rs`
  byte for byte.
  **Owed.** By the unit that writes `MeshNative.kt` (M3f/M3g): the Kotlin
  half of the guard's check 4, against the same fixture. By the unit that
  first builds the radio for Android: `nm -D` on the built library in
  `build-check.yml`, listing the nine symbols.

Residuals of M3b. No Android target is installed where this was built, so
the `target_os = "android"` configuration was never compiled: that it
compiles, that the nine symbols are exported from the built library, and
that a Kotlin caller reaches them, is proved by nothing until a pull request
runs `cross-check.yml` and `build-check.yml`, and an emulator lane or a
device calls them. On the host the shim is type-checked against `jni` in the
test build and its conversions run; no export is called. When the JVM
cannot allocate a poll's answer the frame that poll took is spent and lost,
and its link ends when the peer refuses the next one. The independent review
and the security-reviewer pass design §H asks for on M3b were not run by the
agent that built it.
Mutation pass: 33 changes of a line or a few to the shim, the guard
function, `lib.rs` and the fixture. Thirty each fail a named test, the
compiler or the guard script. Three stand, and only a call of an export can
kill them: the exception a failed JNI call left not cleared, an argument
converted from another parameter of the same Java type (`linkUp`'s link
taken from `peer`), and an answer inverted (`resume`). Seven of the nine
exports never read their `JNIEnv` and could be called on the host with one
that points nowhere, at the price of an `unsafe` in the shim's test module;
not done. Each of the guard script's twelve failure sites, silenced in turn,
fails its self-test.

Review of M3b (independent, read-only, of `8a04ab3`): no blocker and no
high finding — no crash, abort, deadlock or memory-safety problem reachable
through the shim. One medium and four low, each checked against the code
first; all were as stated. Fixed here, each with a test or a guard fixture
that fails without the fix.
**The guard was the only control inside `mesh_jni.rs`, and ordinary syntax
got past it (medium).** The allowance on the module covers all of it, so
there the compiler reports neither an `unsafe` block nor a second exported
symbol. The guard stopped reading at the first `#[cfg(test)]` line, counted
neither `#[export_name]`, `#[link_section]` nor an `extern fn` with no ABI
string, and saw a call into Java only as `env.<method>(`; the Rust gate
looked for `fn Java_` and banned no `unsafe`. Three plants passed both. The
shim is now two files. `mesh_jni.rs` holds `use`s and the nine exports and
nothing else, each export one call that hands its own parameters on, in the
order declared, to the function of `mesh_radio.rs` named for it; it has no
tests of its own. `mesh_radio.rs`, under the deny, holds the conversions,
the one guarded call of each, and their tests. The guard reads every line
of the first file and holds it to exactly that shape — no `unsafe`,
`export_name`, `link_section`, `used`, `mod`, `impl`, `static`, `cfg`,
`JNIEnv::` or macro in it, as many `extern` keywords as exports — and
holds the second to one guarded call a method, a `JNIEnv` used only as the
parameter `env` for five calls, one `#[cfg(test)]` above `mod tests {` and
nothing behind it; across the crate it now also reads `extern` without an
ABI string, `export_name` and `link_section`. The exports are compared with
the fixture in any order. 80 self-test fixtures; each of the script's
sixteen failure sites, silenced in turn, fails the self-test.
`every_export_is_one_guarded_call` holds the same two steps from the Rust
side. The review's plants, in the exports' file and again in the file under
the deny, and ten variants — the 2024 spelling of `no_mangle`,
`extern "C"`, a bare `extern fn`, an export, two `export_name`s and a
`link_section` in other files of the crate, an `unsafe` block under the
deny, a JNI method called by path, a `JNIEnv` under a second name — each
fail the guard, and the Rust gate or the compiler where they reach.
**Argument order and answers, on the host.**
`the_calls_a_jni_export_forwards_reach_their_entries_each_argument_in_its_place`
runs the seven calls that take no array, on Java's own types, against the
engine: `resume` true exactly when an engine runs; `leftMs`, and `wakeInMs`
with its −1; a sighting of its peer at its strength; `linkUp` under its
link's number, bound to its peer, in its role, over its MTU; `connectFailed`
of its peer; `linkDown` of its link. Two of the three changes that stood in
the first pass now fail it — a link's number taken from `peer`, `resume`'s
answer inverted — and an export that swaps two parameters fails the guard
and the gate.
**Peer numbers (low).** `sighting` and `connectFailed` passed a peer's
number bit for bit while `linkUp` took one below zero for none, so a peer
with the top bit set could be sighted and dialled and never bound to its
link. A peer below zero is now no peer in all three: a sighting or a failed
connect of one makes no entry. The fixture's header says that both numbers
are never negative.
**A caught panic is silent (low), and stays so.** A fixed warning in the
guard would be a log line in the mesh's part of the bridge, which writes
none: `the_mesh_entries_log_nothing_and_format_nothing` holds that and a
ratcheted invariant of the privacy manifest cites it, so the line would
loosen a stated promise, and it would need its own planted-identifier test.
Recorded as a residual in `haven-core/SECURITY.md`: the one sign of a
caught panic is the service stopping.
**Owed, added.** `cross-check.yml`'s Android step is a plain `cargo check`
and denies no warning (low): dead code or an unused import that exists only
in the Android configuration would pass it. To the unit that first builds
the radio for Android, beside the `nm -D` check; the workflow is shared and
was not changed.
The guard's header no longer says the compiler's deny reports `unsafe` a
macro writes: that is relied on for a macro of this crate only, which is
why the exports' file may invoke none.
Mutation pass of this round: 44 changes. Thirteen plants of the kind the
review made, each failing the guard; 29 changes to the calls, the exports
and the conversions, each failing a named test, and the guard where it
reads them. Two stand, and only a JVM can kill them: the exception a failed
JNI call left not cleared, and a change to what `receive` hands over —
`receive` and `poll` read a Java array before anything else.

Re-review of `bd7ff48` (independent, read-only): no behavioural regression
found, and three ways past `check_mesh_radio.sh`, each reproduced on the
reviewer's trees — the guard answered 0 on every one — and each fixed in
the guard, with fixtures that fail without the fix. The first two predate
that commit; the third was introduced by it.
**A module built from another file.** `#[path = "../other.rs"]` above
`mod mesh_jni;` put the allowance on a file no check reads, while the guard
and the Rust tests went on reading `src/mesh_jni.rs`, compiled into
nothing; the same on `mod mesh_radio;` gives check 5 a decoy. The guard now
fails any `path = "…"` in the crate's hand-written source, bare or under
`cfg_attr`, on one line or several, and holds `lib.rs` to the one line
`mod <name>;` for each of the two modules (check 6).
**A comment opener inside a string.** The view the guard reads treated the
`//` of `"//"` and the `/*` of `"/*"` as comments, so the rest of the line,
or the lines up to a later `"*/"`, were hidden from every check: one line
appended to `api.rs` — an allowance, a `no_mangle`, an `extern fn`, an
`unsafe` block — passed checks 1 and 2. The view is now made by a lexer
that knows strings (it is not the compiler; the review of `de152a2`,
below, says what it is): a string runs to its closing quote, on whichever
line that is, with its escapes; a raw string to its own hashes; a
character literal that holds a quote is one; block comments nest. A string
begun on the line above and a raw string that holds a quote were not among
the review's trees; they hid code the same way and are fixtures too. No
line of the crate's source newly fails.
**A `use` over several lines.** Check 3 skipped every line of one until a
line that was exactly `};`, so `}; const _A: &str = "//"; …` and what
followed it was read by nobody, and `use crate::api as mesh_radio;` passed
as a `use`. Both were caught only by `every_export_is_one_guarded_call`. A
`use` in the exports' file is now one line of the shape `use a::b;` or
`use a::{B, C};`, with no rename, no glob and nothing after it; what the
exports forward to is imported as `use crate::mesh_radio;` and in no other
way; and the file's one quote is the `"system"` of an export's header.
The guard's header, its step comment in `repo-guards.yml` and design §A.6
no longer say the guard alone reads the exports' file: the Rust gate reads
it too, and each now names both. The scans whose failure a trailing
`|| true` could swallow — the guard passed with its string-blanking
function deleted — take their view first, so a view that cannot be made
ends the run. 97 self-test fixtures after these fixes (80, and 17: five for
strings, seven for the `use` and the quote, five for check 6); 116 with
M3f's Kotlin checks, below. The reviewer's six trees, in scratch copies
with the new guard, each fail, at the check its plant belongs to.

- **M3f**, the radio's pure Kotlin, its JVM tests and the `android-unit`
  lane (`docs/BLUETOOTH_MESH_M3_DESIGN.md` §B.1–B.10, §G;
  `haven/android/app/src/main/kotlin/com/oblivioustech/haven/mesh/core/`,
  `haven/android/mesh-jvm/`, `scripts/ci/run_mesh_jvm_tests.sh`,
  `.github/workflows/android-unit.yml`, `scripts/ci/check_mesh_radio.sh`).
  Kotlin that imports nothing of Android, a Gradle build of its own, one
  workflow, the guard and documents: no Rust, no Dart, no adapter, no
  manifest, no `MeshNative`. **Nothing but its tests constructs a
  `MeshRadioCore`, and no Kotlin declares a native method, so none of it
  runs in any build.**
  **Classes**, package `com.oblivioustech.haven.mesh.core`:
  `MeshEngineApi` (the nine calls of the fixture, as an interface),
  `RadioOutput` (the reader of a poll's answer), `RadioPort` (every
  platform effect), `MeshRadioCore` (the one operation queue),
  `PeerTable`, `ScanPolicy`, `DeadlinePolicy`, `StartPolicy`,
  `PermissionMatrix`, `MeshRadioConstants`, and `MeshThread` — the fault
  wrapper, and the one stop.
  **What the core holds**, each with the test that fails without it. The
  time left is read first at every input, and with none left nothing else
  is done (`everyInputChecksTheDeadlineBeforeAnythingElse`, T-AUTO-4). A
  frame the engine handed over is sent, the same bytes offered again after
  50 ms three times, or its link is closed and the engine told; a link
  with a frame in flight is offered no other, and one whose completion
  does not come in 10 s is closed (`aPolledFrameIsSentOrItsLinkIsClosed`,
  `aLinkWithAFrameInFlightIsNotReady`,
  `aFrameWhoseCompletionNeverComesClosesItsLink`). The engine is told a
  table's number and never an address, and an inbound link has no peer
  (`anAddressNeverReachesTheEngine`); a connect for a peer the table has
  forgotten is failed at once (`aConnectForAPeerNoLongerKnownFailsAtOnce`).
  A pump takes 64 outputs and comes back
  (`thePumpStopsAtItsBudgetAndComesBack`). The wake is the earliest of the
  engine's, the core's own timers, the scan's restart and the reminder
  (`theWakeIsTheEnginesAndTheLockIsCapped`,
  `theScanRestartIsATermOfTheAlarm`); the timed lock is taken only for an
  inbound frame and a link coming up, for the engine's wake and 250 ms, 10 s
  at most. Four connections may wait to become links, 10 s each, a fifth is
  cancelled at once, and a ninth link is closed
  (`unlinkedConnectionsAreCappedAndTimedOut`,
  `aLinkBeyondTheEnginesEightIsClosed`). With Bluetooth off the engine is
  told every link down and every dial failed, is not polled, and only the
  deadline wakes the phone (`bluetoothOffTellsEveryLinkDownAndSendsNothing`).
  An answer that is no output, and an engine that answers no wake, stop the
  radio (`outputsDecodeAsTheFixtureSays`, `anEngineThatAnswersNoWakeIsGone`).
  **`MeshThread`** (design F-14): anything thrown inside `run` becomes a
  stop the user did not make — every step of it attempted whatever the
  step before threw, then the stopped notice — and nothing leaves, is kept
  or is written: `aRadioPortThatThrowsStopsTheRadioAndNothingEscapes`
  makes each of the port's seven calls and the engine's eight throw in
  turn, with an address in what is thrown, and reads both standard streams
  empty. The test found one fault in the first draft: a link was dropped
  with the port asked to close before the engine was told, so a `close`
  that threw left the engine a link the table had forgotten; the engine is
  now told first, everywhere.
  **The JVM build.** `haven/android/mesh-jvm` is a Gradle build of its own
  — the Kotlin version the app pins (2.2.20 when this landed); JVM target 17
  as the app,
  `-Xjdk-release=17`; warnings are errors — whose one source directory is
  the package above and whose tests are its own. It is not in
  `haven/android/settings.gradle.kts` and the app's build is unchanged.
  Having no Android SDK, it is the proof that the package imports none:
  an Android import fails its compile. The fixture tests read
  `haven/rust_builder/fixtures/` itself: `outputsDecodeAsTheFixtureSays`
  the file Rust's `an_output_is_encoded_as_the_fixture_says` reads, and
  `theEngineInterfaceIsTheNineExportsOfTheFixture` the exports' list, by
  reflection — name and JNI descriptor of each method, and no tenth.
  **Run here:** 26 tests, none skipped, on JDK 21 with Gradle 8.14.3 and
  with the 8.14 the lane fetches, through
  `scripts/ci/run_mesh_jvm_tests.sh`, which reads the verdict from the
  result files and fails when none ran or one was skipped (each tried
  with a stand-in for Gradle). No test sleeps or reads a clock.
  **Mutation pass:** 88 changes of a line or a few to the classes and
  the two fixtures, each run against the whole suite. Eighty-five fail a
  named test — every mutation design §B.10 names among them. Two fail the
  compile: an Android import, and an unused variable, which stood until
  the build's `extraWarnings` was turned on for it. One stands: a safe call
  on a value that cannot be null, which changes no behaviour and draws no
  warning. One more stood in the first pass and is closed: the twelve-hour
  cut of a start was tested against the constant it reads, and is now
  tested against twelve hours.
  **The lane**, `android-unit.yml`, called from `ci.yml` in stage 1: a JDK
  21, the Gradle distribution the app's wrapper pins — fetched and checked
  against the SHA-256 pinned beside it, since the tree has no `gradlew` —
  and the script. **It has never run**: CI runs on pushes and pull requests
  to `main`. Its two commands were run by hand where this was built — the
  fetch, whose checksum matched, and the script. It is not one of the
  release gate's workflows (`check_ci_verdict.sh`), whose pinned job list
  is unchanged. It tees and uploads nothing, and
  `check_logscan_wired_everywhere.sh` records it so: a capture added later
  fails until it is scanned.
  **The guard**, `check_mesh_radio.sh`, checks 7 to 11: in every `.kt`
  under a `mesh/` directory of `app/src` no log call, logger or standard
  stream, and no canonical UUID there or in the JVM tests;
  `MeshRadioConstants.kt` the one file naming an Android scan, advertise
  or connection-priority constant; no row of the native log allowlist for
  a mesh file; no `AndroidManifest.xml` of a flag-off build naming
  Bluetooth, `connectedDevice` or the mesh; and the 26 tests by name,
  each under `@Test`, none ignored. 19 fixtures, 116 in all; each of the
  script's 28 failure sites, silenced in turn, fails the self-test.
  **Not as the design has it** (each recorded in the design, "As built
  (M3f)"). The package is `…mesh.core` and the tests are in the JVM build,
  not `app/src/test`. `RadioPort.connect` takes the address, not the
  peer's number, which the port has no way back from; the port gains
  `scan()` and `remind()`, and the core `startRadio()` and
  `onConnected(link)`, without which the scan's restart, the reminder and
  the unlinked connections of §B.4 have no pure owner. The time left is
  read at the start of an input, not at the start of the pump that ends
  it. A completion that reports failure closes its link. `StartPolicy` is
  one function that takes the foreground start as a step, so the order —
  permission, foreground, engine — is tested; it asks for no engine when
  the stored deadline has passed. With Bluetooth off the reminder's time
  wakes the phone as well as the deadline's. `MeshThread` holds the stop
  as well as the wrapper. The radio's four platform modes are integers
  with the Android constant named beside each, not Android's own
  constants: the package compiles without them. That the advertisement
  carries no service data and no scan response has no constant, and no
  test here.
  **Owner questions still open, each built as designed and in one
  place.** Q-2, an engine started with no session: one `if` of
  `StartPolicy.start`. Q-13, a linked stranger keeping the phone awake: no
  bound beyond `HOLD_CAP_MS`, in the one `holdAwake` of the core.
  **Not proved.** The lane has not run on a runner. The app's own
  Android build has not compiled the new package. No
  adapter exists, so nothing here has met Bluetooth, a `HandlerThread`, an
  alarm, a wake lock or a notification, and nothing ran on an emulator or
  a device. The four integers were read off the platform's reference
  pages (2026-11-12), not checked by a compiler. That the package uses
  nothing absent from Android API 23 is by reading: the build holds it to
  the JDK 17 API, not to Android's. The privacy manifest cites none of the
  tests: `check_privacy_invariants.sh` reads a cited test in Rust or Dart
  only (its rule 3), and the radio's invariants are M3i's.
  **Owed by M3g**, beside what M3b left it: `MeshNative` as the
  implementation of `MeshEngineApi`, with the guard's Kotlin half of check
  4; every callback and handler message inside `MeshThread.run`, one
  `MeshThread` a start, its steps the real ones; one counter of link
  numbers across both roles, from the connection on for an inbound one;
  `onConnected` for a central that connected to Haven's server and for no
  other connection — the core cancels after 10 s whatever it is told of;
  one answer to every `connect`; `send` answering false only when no
  completion will follow; `close` of a number it does not know doing
  nothing; `scan()` doing nothing where `PermissionMatrix.canSearch` is
  false; the mesh's own manifest, and the guard's checks of it and of the
  advertiser's source.

Review of M3f (independent, read-only, of `de152a2`): no blocker and no
high finding. One medium and three low in the Kotlin, each checked against
the code and the engine; all were as stated. Fixed, each with a test that
fails without the fix.
**The peer table undid the engine's defence against one advertiser under
many addresses (medium).** The engine forgets a peer picked at random among
those neither linked nor being dialled, and takes in no unknown peer below
its signal floor. `PeerTable` numbered every sighting and forgot its
oldest: an advertiser rotating 64 addresses, at any signal strength,
pushed every honest address out between two of its own sightings; the
engine still held the honest peer's number, its connect met a forgotten
number, failed and backed off 60 to 90 s, and outgoing links stopped. The
table now forgets one picked at random among the addresses not being
dialled (and, since the re-review below, not of a link this phone
dialled) — `SecureRandom` unless a test hands a picker in — and gives an
address it does not know no number, and the engine no word of it, below
`MeshRadioConstants.RSSI_FLOOR`; a known address's weak sighting is still
told. The floor is the engine's `rssi_floor`, −85, held once in Kotlin and
pinned to the engine's default by `check_mesh_radio.sh` check 12 (the
first `rssi_floor: <integer>,` after `impl Default for Config {`). Were
the two to differ the higher would decide and nothing would break.
`aFloodOfAddressesDoesNotPushOutAPeerUnlessItIsPicked`,
`anAddressBeingDialledOrLinkedIsNeverForgotten`,
`aWeakAddressNotYetKnownTakesNoPlaceAndIsNeverToldToTheEngine`,
`aWeakSightingOfAKnownAddressIsToldToTheEngine`, the table's own
`thePeerTableHoldsSixtyFourAndForgetsOnePickedAmongThoseNotHeld`,
and `theTableABuildHasForgetsByNoFixedRule` for the picker a build has —
whose one in 10^26 is the only chance any test here takes.
**Two changes the suite let through (low; the code was right).** A
completion that freed a link still holding a refused frame, dropping the
frame: `aCompletionWhileARefusedFrameWaitsClosesItsLink`. A dial left
pending after its link came up, so that Bluetooth off told the engine a
connect failed for a linked peer: an assertion in
`bluetoothOffTellsEveryLinkDownAndSendsNothing`.
**A lock for what the engine refuses (low).** The timed wake lock was
taken for a link-up or a frame even when the engine answered that input
with the link's close — no room, its inbound limit, a frame it rejects —
so a peer never admitted could buy ten seconds of wakefulness a try. No
lock is taken when the close of the input's own link comes out of the same
pump (`aLinkTheEngineClosesAtOnceHoldsNoLock`). Owner question Q-13 — a
peer the engine does admit — stands as it was; no other cap was added.
A comment that said more than `DeadlinePolicy.reminderIn` does is
corrected, and the design's §B.2 now lists what the core asks of the
adapters, with two points the review added: the stop's steps cancel the
alarm after the radio-down step, which arms one; and one `onLinkUp` a
connection. 33 JVM tests (26, one renamed, seven added). Mutation pass of
this round: 17 changes, each failing a named test — one of them, the lock
kept for a closed link, first as a compile error (a variable never
reassigned is a warning, and warnings are errors) and then, written so
that it compiles, as the test; and one, a fixed rule in place of the
build's picker, stood until the last of the tests above was written.

Review of the guard and the lane (independent, read-only, of `de152a2`):
the multi-line `use` is closed, no fail-open was found, the workflow's
shell is sound; five ways past the guard or the lane, one of them older
than M3f. **First, what the guard is, since each fix invites the next
plant:** `check_mesh_radio.sh` reads text. It stops ordinary and careless
erosion and makes a deliberate one conspicuous in review; it is not the
compiler and is no proof against code written to be hidden from it, by
someone who could as well edit the guard. It reads the `.rs` files under
the bridge crate's `src/` and nothing else of the crate — not a file
outside `src/`, not a lint level set elsewhere (`[lints]`, `RUSTFLAGS`,
`--cap-lints`, a `build.rs`: today the crate has no `[lints]` table and no
`build.rs`, and the one `RUSTFLAGS` cargokit passes an Android build is a
library search path; nothing pins that).
Its header, its step comment, design §A.6 and `haven-core/SECURITY.md`
now say that, and no longer that it reads "as the compiler does" or that
"the files read are the files compiled". **Owed by M3g**, with the first
build of the radio for Android: the `nm -D` step holds the library's
exported `Java_*` symbols to exactly the nine of the fixture — a check of
the artifact, which no way of writing the source gets past.
Fixed, each with a fixture that fails without the fix:
a character literal followed by a string that holds a quote
(`stringify!('x'"'")`) set the lexer one quote out of step, and an
exported `unsafe fn` then sat in what it took for a comment — a `'` is
now read as an escape up to its closing quote, as one character between
two quotes, or as the quote of a lifetime or label;
`mod mesh_radio;` kept for tests while Android got another module under
the same name, by a `use … as mesh_radio` or by a macro that writes
`#[path = $file]` — `lib.rs` is now held to the exact attribute lines
above each of the two declarations, after the end of another item, with
neither name anywhere else in the file, and `path` followed by `=` fails
whatever follows;
`include!` of a file that is no `.rs` (older than M3f) — banned in the
crate's hand-written source, `include_str!` and `include_bytes!` not;
a logger imported under another name (`import android.util.Log as L`),
or taken as a function reference — the import itself fails, and `Log::`;
and `run_mesh_jvm_tests.sh` said every test ran while asking only for one
— it now fails unless the tests that ran are, by name, the functions the
test sources declare under `@Test`, which an `abstract` test class and a
test filter both fail. **It cannot tell a test whose body was emptied:**
that one runs, passes and is counted, and nothing here says otherwise.
The lane now restores the shared Gradle cache read-only before its build,
as every lane but the writer does, and
`check_gradle_build_hardened.sh` lists the script as a build site, so a
lane that ran it cold fails that guard (15 fixtures there). `.kotlin/` is
ignored beside `build/`. 129 self-test fixtures in `check_mesh_radio.sh`
(116, and 13: two for the character literal, four for the modules and
`include!`, two for the logger, four for the floor and one for a tree
with no engine to read it from); each of its 30 failure sites,
silenced in turn, fails the self-test. The reviewer's trees, in scratch
copies with the new guard and this tree's Kotlin, each fail at the check
its plant belongs to, and the tree with no plant passes.

Re-review of those fixes (independent, read-only, of `a6e3ed8`): nothing
blocking, high or medium; every fix holds. Two low, both fixed.
**The table could forget the address of a peer this phone is linked to**,
which the engine never does: the fix above exempted only an address being
dialled, and a link coming up ends its dial. A flood then cost each linked
peer, once forgotten and seen again under a new number, a second dial that
the engine closes as a duplicate. A link this phone dialled now keeps its
address, and the table forgets neither it nor one being dialled
(`anAddressBeingDialledOrLinkedIsNeverForgotten`, which also holds that
the address is anyone's to forget once the link is down;
`thePeerTableHoldsSixtyFourAndForgetsOnePickedAmongThoseNotHeld`).
**The guard's `path` rule failed ordinary code**: a variable named `path`
assigned at the start of a statement. It now reads `path` and `=` only
where an attribute's argument starts — after `[`, `(` or `,` — and the
self-test's passing tree assigns such a variable; the three plants still
fail. Not changed, and stated: a link dropped for a send that timed out,
in the pump of its own frame, is told down with no close from the engine,
so the hold for that frame stands; it gives a peer nothing a valid frame
does not.

Owner decisions, 2026-11-12 (recorded in full in
`docs/BLUETOOTH_MESH_M3_DESIGN.md` §J, "Decided by the owner"): Android's
own Bluetooth log lines are accepted as the platform's, on the condition
that Haven reduces what they can show as far as it can and randomizes
every identifier it decides, all of them or none; the Bluetooth name is
accepted and disclosed, and removed or obscured if a way exists that is
Haven's to take; a linked stranger keeping the phone awake is accepted and
recorded; the service may start a keyless engine with no session; a draft
pull request is opened now and every lane, old and new, must pass; and the
conditional guarantee on emission times (R1) is enough, R2 not owed. None
of the log or name levers is established yet: M3g begins with that
research.

Research for M3g: Android's logs and the device name (2026-11-12),
recorded in full in `docs/BLUETOOTH_MESH_M3_DESIGN.md` §M. **Paper only:
nothing is built, and nothing has run on an emulator or a device.**
Checked by a research pass over the platform's source and reference
pages, then an independent confirmation that fetched every cited source
again, corrected the first and added to it. The AOSP hosts were
unreachable in both: from API 33 the source read is LineageOS mirrors
tied to build IDs, and no vendor's build was read.
**Established, in source.** Android's GATT classes write, from Haven's
process and in every build, the address of whatever connected — in full
on every release read up to 15 QPR2, its last two bytes from 16 — and a
GATT server is told of every LE connection of the phone, not of Haven's
peers alone (read on Android 16). From API 30
a process decides what its own log calls write: a minimum priority,
which a system property can lower at any moment, and a logger, which
nothing outside the process undoes. A peer can make the phone raise a
pairing dialog; the one public lever is to drop the link. The phone's
own address is the build's: private and rotating by AOSP's default, and
an app can neither choose it nor see which it has. A peer this phone
dials can always read its Bluetooth name; `setDiscoverable(false)`, from
API 34, withholds it from a peer that connects in, except on a
controller with neither extended nor multi advertising.
**The rule that follows** (design §M.3). The radio is started only on
API 30 or later; only with Haven's own logger, which writes nothing but
lines under Haven's tags, and the raised minimum behind it — in force
before any Bluetooth object exists, kept for the life of the process,
checked at every start and while the radio runs; and never bonded: no
permission or call that could pair, and a link dropped the moment its
device starts to bond. Below API 30 `start` answers `unsupported`, which
widens (e) of "Owed by the native unit" above: hardware that can never
run the mesh, or an Android release below 11. **Phones on Android 7 to
10 cannot use the mesh** (Android 6 too when this was written: Haven's
floor is Flutter's default `minSdkVersion`, 23 then and 24 at Flutter
3.50.0, pinned by nothing in Haven; design §M.3, Q-16). The name stays accepted and disclosed; the
phone is not renamed; a peer's address type is not judged (design §M.6,
§M.7); and nothing may claim that every identifier is random.
**Left, and owed.** What stays exposed is design §M.8. The lever costs
Haven's own diagnostics for the whole process, so a mesh lane must not
pass by scanning a capture nothing was written to (M3h). Where the lever
lives, its list of tags, and whether the raised minimum — which drops
Haven's own lines too — stays as the second line, are M3g's first
decisions, the last the owner's if it must give. Nine things are to be
proved before the flag flips (design §M.9). `haven-core/SECURITY.md`,
the privacy manifest and `CLAUDE.md` are unchanged: they describe what
is built. §0.4 owes, with M3g, an item for Android 7 to 10 and, in
item 6, that address rotation is the build's; §7.1 carries a note now.

- **M3g unit 1**, the log lever (`docs/BLUETOOTH_MESH_M3_DESIGN.md` §N.1,
  §N.4, and §N.7 for where the code differs;
  `haven/rust_builder/src/log_lever.rs`, `api.rs`, `mesh_radio.rs`,
  `mesh_jni.rs`, `lib.rs`; `…/mesh/core/LogLever.kt`;
  `scripts/ci/check_mesh_radio.sh`, `check_mesh_radio_symbols.sh`). Rust in
  the bridge crate, one Kotlin interface, two guards, two workflow steps
  and documents: no adapter, no service, no Dart, nothing in
  `haven-core/src` or `tooling/soak`. **Nothing calls the lever: no Kotlin
  declares its two exports, the generated bridge does not name it, and a
  default build differs by two exported symbols. Nothing of it has run on
  Android.**
  **What it is.** A third module the crate's `unsafe_code` deny is lifted
  for. `leverInstall` finds five functions of the platform's `liblog` by
  name — `__android_log_set_logger`, `_logd_logger`, `_write_log_message`,
  `_set_minimum_priority`, `_get_minimum_priority`, each from API 30 — with
  `dlopen("liblog.so")` and `dlsym`, never an `extern` declaration, which
  would be an import Android 7 to 10 cannot bind; hands `liblog` a logger
  of Haven's own; and, in a release build, raises the minimum priority to
  FATAL behind it. `false` where a function is missing. `leverHolds` hands
  the logger in force one empty line for the main buffer at ERROR and
  answers whether Haven's logger counted it and, in a release build,
  whether the floor still reads FATAL or above.
  **What a build writes (owner question Q-14, the recommended form
  built).** A release build's logger counts the line and returns: it reads
  nothing of it and writes none. A debug build's reads the message's size
  and at most eighteen bytes of its tag — never past the NUL, never the
  text — and hands the line to the platform's writer only under one of
  the runtime scanner's `owned_tags`, or one and then `::`; it leaves the
  floor alone. The other form, nothing in any build, is one function
  answering `false` (`lever_writes_own`).
  **Where the decisions are.** In `api.rs`, under the deny: the list
  (`LEVER_OWNED_TAGS`), the match (`lever_owns`), what a line comes to
  (`lever_line`), what a check comes to (`lever_held`), the build's kind
  (`lever_writes_own`). `log_lever.rs` holds what must be `unsafe`: eleven
  blocks, each with its argument — two for the lookup, one for the cast of
  what it found, three for a message's size, tag pointer and tag bytes,
  five for the calls through `liblog`'s functions. The logger and what it
  calls log nothing, format nothing, allocate nothing, take no lock, index
  nothing and add nothing but a wrapping count; it is `extern "C"`, where
  a panic aborts and cannot unwind into `liblog`.
  **Exports**, eleven: `leverInstall ()Z` and `leverHolds ()Z` beside the
  nine, each one forward to `mesh_radio.rs`, there one guarded call of
  `radio_lever_install` / `radio_lever_holds`, which answer `false` when
  they panic. `LogLever` is the pure interface beside `MeshEngineApi`.
  `libc 0.2.180`, already in the lockfile: one edge in
  `haven/rust_builder/Cargo.lock`, no package; the other two lockfiles
  unchanged.
  **Proved here, on the host** (278 Rust tests pass in the bridge crate,
  ten of them new; 33 JVM tests, one renamed): the list is the `logcat` line
  of `tooling/logscan/policy.toml`, read by the test; the match, for every
  entry — itself, with `::`, cut at the bytes read — and against a bare
  prefix, one colon, another case and the platform's own Bluetooth tags;
  that a release build never asks for a line's tag and writes none, that a
  debug build writes only Haven's, that every line is counted and the
  count wraps; what a check comes to for a count that moved or did not
  and each floor from below DEFAULT to SILENT; the logger itself and the
  tag's read, on messages the tests build; a lookup in a library that is
  absent and in one that lacks the functions; both calls answering `false`
  off Android; and, from the source, that the bridge reaches the lever
  through its two entries alone, the generated bridge not at all, and
  that the lever's file and its four decisions hold no word that panics,
  allocates or locks. The lever's file alone, with its decisions, was
  type-checked and linted — clippy, warnings denied — for four Android
  ABIs (`aarch64`, `armv7`, `x86_64`, `i686`) on rustc 1.97.1 and for the
  first two on 1.99, those two in both profiles: the layout assertion
  holds for both pointer widths and `libc` has the three names there.
  **The guard**, `check_mesh_radio.sh`: checks 1, 2 and 6 take a third
  module; check 13 is the lever's file — its `unsafe` as eleven blocks and
  five pointer types, one `extern "C" fn`, no export, no `static mut`, no
  `impl` or `mod`, no `unwrap`, `expect(`, `Box`, `Vec`, `String`, `Mutex`,
  `RwLock`, `radio_`, `log::` or `JNIEnv`, no macro but `cfg!` and the
  layout's one compile-time assertion, no string but the library, the five
  functions, an ABI and the `cfg!`'s target, of `libc` three names by
  their path, of the bridge `lever_*` alone, its tests last; and no file
  of the crate naming `android_log_sys`, or outside the lever one of the
  five. 166 self-test fixtures (129, and 37); each of the eight failure
  sites of check 13, and those of checks 1, 2 and 6, silenced in turn,
  fails the self-test. It reads text: it cannot see an index that could
  panic, nor that an `unsafe` block's argument is true.
  **The artifact**, `check_mesh_radio_symbols.sh`, the step M3b and M3f
  owed: on each ABI's debug APK in `build-check.yml`, the library's
  defined `Java_*` symbols are the fixture's eleven and the keyring's one
  (design N-3), and every undefined `__android_log_*` symbol is one of the
  six `android/log.h` declares with no `__INTRODUCED_IN`. 20 self-test
  fixtures over listings a stand-in for `nm` prints; each of its failure
  sites silenced fails it. Run here against the Flutter engine's own
  library for three ABIs, which the host's `nm` reads: the listing parses
  and that library's three `liblog` imports pass. **It has run on no
  runner**, and what Haven's library imports today is its first run's to
  say. `cross-check.yml`'s Android step is now clippy with warnings
  denied, owed since M3b, **and has not run either**: what it finds in
  the Android-only code already there is not known.
  **Mutation pass**, 22 changes to the Rust and one to the Kotlin: the
  match loosened to a bare prefix, or to one colon; a release build
  writing Haven's lines; the logger forwarding whatever the build, not
  counting, or not asking the decision at all; the check ignoring the
  count, or the floor in a release build; the floor at ERROR; a tag
  dropped from the list, or added; one byte fewer read; an export, a call
  or an entry forwarding to the other's; a panic answered `true`; a short
  message's tag read; the read not stopping at the NUL; a log line or an
  `unwrap` where the logger runs; the Kotlin interface's method retyped —
  each fails a named test. Two stand. A host that looks `liblog.so` up as
  Android does finds none either, so "off Android no lookup is made" is
  read, not tested. And a lookup that takes a missing function for a found
  one answers a table whose null pointer reads, through the option's
  niche, as no table: undefined behaviour the test cannot tell from the
  right answer, so the null check rests on its SAFETY argument alone.
  **Not proved, by anything.** No Android build of the bridge crate was
  made: there is no NDK where this was written. The five functions were
  never resolved; `install` and `holds` have never run past their first
  line — the order of the calls, the sentinel, the floor raised and read
  back — and neither has the forward to the platform's writer: a host has
  no `liblog`, and no stand-in for it was written (design N.1.6's third
  row is not built). So it is not shown that the logger is the one in
  force after the call, that a platform line is dropped, that a property
  set over `adb` brings none back, or that the library still loads on
  Android 7 to 10 — that last is what the artifact step is for. The event,
  statistics and security buffers never reach a logger (design N-1).
  Everything [E] and [H] of design N.1.6 stands as it was. `haven-core/
  SECURITY.md` has the lever under "The radio's entries"; the privacy
  manifest and `CLAUDE.md` are unchanged — the lever is in force in no
  build — and §0.4's two items stay owed to the unit that makes a phone
  refuse.

- **M3g unit 2**, the pure Kotlin additions
  (`docs/BLUETOOTH_MESH_M3_DESIGN.md` §N.1.3, §N.1.5, §N.2.3–N.2.8, and
  §N.7 for where the code differs and for what the adapters owe;
  `…/mesh/core/StartPolicy.kt`, `MeshRadioCore.kt`, `ServerLinks.kt`,
  `GattClientSteps.kt`, `ChannelWords.kt`, `LinkEvents.kt`,
  `MeshRadioConstants.kt`, `MeshThread.kt`; `haven/android/mesh-jvm`'s
  tests; `scripts/ci/check_mesh_radio.sh`). Kotlin that imports nothing
  of Android, its JVM tests, one guard and documents: no adapter, no
  manifest, no Gradle change in the app, no Dart, no Rust. **Nothing
  calls any of it: no service, no channel and no `MeshNative` exist, so
  a build differs by classes nothing loads. Nothing of it has run on
  Android.**
  **What is decided here**, each as a function or a small class with no
  platform call in it:
  whether the radio may start, in §M.3's order — below Android 11 or
  with no Bluetooth LE `unsupported`, with the lever not looked up; a
  lever that is missing `unsupported`; one that does not hold `failed`;
  then the permission (`StartPolicy.refusal`) — and the service's own
  start, which is in the foreground before anything can refuse, asks
  the same again, and stops behind a logout's marker with no notice
  and no engine asked for (`StartPolicy.start`, answering
  `Refused(word, notice)` or `Run(deadline)`);
  that nothing of the radio runs once the lever stopped holding: the
  wrapper every body runs inside asks it before the body, and where it
  does not hold puts it back and stops the radio with its notice, the
  body not run — the service's start excepted, which must reach its
  foreground start and is what puts the lever in (`MeshThread.run`,
  `MeshThread.start`);
  which of the phone's connections are Haven's — a device only from the
  moment it enables notifications on Haven's characteristic, linked then
  if its connection's MTU is known and 51 or more, else at the next MTU
  that is; the MTU kept in memory for each connected device, at most
  64, dropped at its disconnect and with the radio; a write that is
  prepared, at an offset or wants an answer refused and its link ended;
  nothing done to a device that never subscribed but the answer to a
  write on Haven's own descriptor (`ServerLinks`);
  a dial as steps — the connection, the MTU, discovery, the
  subscription, then the link and the connection priority — each
  waiting for its callback, given up after 25 s, a connection that ends
  before its link made once more 300 ms on, every client closed on
  every path, whatever a call to the port throws (`GattClientSteps`);
  that an address the engine asks for again while it is being dialled
  is the same dial (`MeshRadioCore`); that a stop tells the engine
  before an adapter is closed (`MeshThread.steps`);
  that a device Haven holds which starts to bond is ended, and no other
  (owner question Q-15, option (a), as one function; option (b) is that
  function and one branch of an adapter);
  the channel's words, which three of its eleven methods are behind the
  lever, and that a tap on a notice is held until the Flutter engine
  asks for it (`ChannelWords`, `HeldTaps`);
  and the service's and the characteristic's UUIDs, drawn once from the
  system's generator and kept as two numbers each — **fixed for good
  from the first release that has the mesh on**.
  **Proved here, on the JVM** (57 tests, 24 of them new, against fakes
  and a clock the tests move; no sleep, no order between tests): each of
  the above, by a test named for it; that no address reaches what the
  core is told of an inbound link; that a callback of a client already
  closed does nothing; that no call is made on a client before its
  connect or after its close, and no number makes two — the recording
  adapter fails the test otherwise. The package still compiles with no
  Android SDK, warnings as errors.
  **Mutation pass**, 132 changes to the Kotlin: every order, word,
  bound and branch named above altered in turn — the lever asked after
  the time left, or not put back; the permission read before the lever;
  the foreground after a refusal; a notice behind a logout; a link
  before its subscription, or at an MTU below 51; the note kept past a
  disconnect or the radio; a stranger's write answered; option (b)
  built; a client left open; a second connection without end, at once,
  or under the first's number; the priority asked of a closed link; one
  digit of a UUID; a method or a word misspelt; a held tap sent early,
  told twice or lost. 130 fail a named test, two of them only after
  the test was made to: a prepared write that wants no answer, and a
  third connection. An Android import does not compile. **One stands:**
  a call of the JDK that the oldest Android Haven runs on does not have
  (`java.time`) compiles and passes — the JVM build reads JDK 17's API,
  and nothing here holds the pure package to that Android's. None is
  used; a reviewer holds it.
  **Review** (independent, read-only, of `9609128`): no blocker and no
  high finding. Two medium, fixed. **The lever was asked by the core's
  inputs alone**, and a dial's steps and the server's answers are made
  from the platform's callbacks with no such input between them — up to
  25 s of platform calls behind a lever nobody asked: the question is
  now the wrapper's, one site for every body, and the core's own is
  gone. **A port call that threw could leave a client open for the life
  of the process**, and a close that threw in the stop's first step
  skipped the engine being told: the close now follows whatever is
  thrown, the radio's stop asks every client, and `stopRadio` is a step
  of its own before the adapters'. Three low, fixed or recorded: four
  guarantees no test held (a late timer, an MTU of exactly 51 in each
  role, an MTU told out of its turn); two dials for one address; and
  one line on why a stranger's write to the characteristic is left
  unanswered where its write to the descriptor is not. With them, the
  two step classes are final once stopped. The detail, what the review
  found sound and its list of what no test can know before adapters
  exist are design §N.7.
  **Second mutation pass**, 34 changes over what the review changed and
  added — the lever not asked, asked after the body, not put back, or
  not stopping the radio; the start waiting on the lever, or its throw
  leaving the thread; an adapter closed before the engine is told; a
  close skipped behind a throw, in each of five places; a stopped
  class answering, noting or dialling; a late timer making its
  connection; each MTU bound moved by one; an address dialled twice —
  all fail a named test. The first pass was run again over the code as
  it stands: 112 of its changes still apply and each fails a named
  test; the other 18 changed code the review rewrote, and each was made
  again to the new text, among the 34 or beside them, and fails.
  **The guard**, `check_mesh_radio.sh`: check 11 pins the 57 names;
  check 8 gains that `MeshRadioConstants.kt` alone builds a UUID. 170
  self-test fixtures (166, and four); the new clause silenced, and each
  of its three alternatives in turn, fails the self-test.
  **Not proved, by anything.** Every adapter: no code maps a platform
  callback to these inputs or a port's method to a platform call, so
  nothing shows that Android's GATT server and client behave as these
  classes assume — that the server is told of a disconnect, that an MTU
  agreed before a subscription is the one noted, that a write without
  response is paced by its callback, that `cancelConnection` ends
  anything (design N-7: on the one release read it does not), that
  dropping a link ends a pairing, what still arrives after a close.
  That every body runs inside the wrapper, which is now what asks the
  lever, is §B.2's contract and no check until the adapters' guard.
  The lever's two calls are made
  against a fake: `leverInstall` and `leverHolds` have still never run
  on Android, and the rule of unit 1's review — no landing without an
  emulator lane for the unit that first calls them — falls on the unit
  that makes them reachable. The dial's two timers are a handler
  timer's and not the alarm's, so on a sleeping phone they come late:
  measured nowhere. The channel's words agree with `mesh_radio.dart`
  by reading; the check that reads both files is the channel's unit's.
  The UUIDs have been seen by no second implementation. `haven-core/
  SECURITY.md`, the privacy manifest and `CLAUDE.md` are unchanged:
  nothing here is in force in a build.
- **M3g unit 3**, `MeshNative` and the manifest gate
  (`docs/BLUETOOTH_MESH_M3_DESIGN.md` §N.2.1, §N.3, §N.4, and §N.7 for
  what was read, where the code differs and which CI job proves what;
  `…/mesh/MeshNative.kt`; `haven/android/app/build.gradle.kts`;
  `haven/android/app/src/mesh/AndroidManifest.xml`;
  `scripts/ci/check_mesh_manifest.sh`, `check_mesh_radio_constants.sh`,
  `check_mesh_radio.sh`; `build-check.yml`, `repo-guards.yml`). One
  Kotlin object, one manifest, one Gradle switch, two scripts, one CI
  job and documents: no adapter, no service, no channel, no Dart, no
  Rust. **Nothing references `MeshNative`, so no native method is
  called in any build, and a build without the flag — every build a
  script or a release makes — declares and does what it did before.
  Nothing of this unit has been compiled for Android: this machine has
  no Android SDK, and its first build is CI's.**
  **What is built.** `MeshNative`: the eleven native methods of the
  fixture as overrides of the two pure interfaces, and the library
  loaded by the class, since JNI looks a method up in what the class's
  own loader loaded. The mesh's manifest: the three Android 12
  permissions with `BLUETOOTH_SCAN` flagged `neverForLocation`, the two
  legacy ones up to API 30 — Android 11, where the radio starts, has no
  other — the connected-device foreground-service permission, and
  classic Bluetooth and Bluetooth LE as features that are not required;
  the service and the receiver come with their unit. The switch: `app/build.gradle.kts`
  reads `HAVEN_MESH` from the `dart-defines` property the Flutter tool
  hands Gradle, once; with it the mesh's manifest is added to every
  variant and `BuildConfig.HAVEN_MESH` is true, without it neither, and
  a property that is absent or does not decode is off. In
  `build-check.yml`: on each of the three ABI legs' APK, that the merged
  manifest holds nothing of the mesh; and a fourth job, the only build
  with the flag, whose manifest must hold every entry with its
  attributes, whose library must export the eleven symbols, and against
  whose `android.jar` the four radio modes `MeshRadioConstants.kt`
  holds as integers are compared.
  **Proved here.** The class compiles against the two interfaces under
  the JVM build's own options, in a scratch copy of that build, and the
  class file's eleven `native` methods are the fixture's names and
  descriptors. The switch's expression, under the Gradle the app pins,
  is on for exactly a last `HAVEN_MESH=true` among fourteen values of
  the property, and its two blocks take the overloads meant, against
  stand-ins with the signatures of AGP 9.3's reference. The manifest
  check, beyond its self-test fixtures (34, and 49 after the review), was
  run with a real `aapt2`
  on two APKs linked from the mesh's own manifest and from none, in
  both modes; the constants check, beyond its 19, with a real `javap`
  on two real `android.jar`s. **The guard**, `check_mesh_radio.sh`:
  check 4 gains its Kotlin side — the class a symbol names, each native
  method's name and descriptor against the fixture, the library, and no
  native method in another file — and check 14 is new, the switch
  written once and used twice; 198 self-test fixtures (170, and 28).
  **Mutation pass**, 32 changes to the three scripts, each silencing or
  loosening one clause or moving one pin — in the manifest check, each
  of *off*'s four things not looked for, a missing, doubled or
  re-attributed entry passing, the positive control gone, a dump that
  fails read as empty, each pinned attribute; in the constants check,
  the comparison, the comment, a class that cannot be read, another
  platform's jar; in the guard, each new clause of checks 4 and 14 —
  all fail a self-test fixture.
  **Only CI proves, and has not run** (design §N.7 has the job, the
  claim and what a failure reads for each): that the Gradle script
  evaluates under AGP 9.3 and `addStaticManifestFile` merges the file;
  that `MeshNative.kt` compiles for Android; what a default build's
  merged manifest holds once every dependency's is in it; that the SDK's
  `aapt2` prints the shape read here and is where the check looks for
  it; the four integers against the platform as Google ships it.
  **Not proved, by anything.** That JNI finds the eleven methods: no
  call is made. `BuildConfig.HAVEN_MESH` has no reader until the
  channel. That a release build's shrinker drops the class now and
  keeps it once something calls it. The rule of unit 1's review — no
  landing without an emulator lane for the unit that first calls
  `leverInstall` — still falls on a later unit: `LogLever` has its
  implementation, and nothing constructs anything with it.
  `haven-core/SECURITY.md`, the privacy manifest and
  `haven/DEVELOPMENT.md` change by one sentence each, where they said
  that no Kotlin declares an export and that no workflow passes the
  flag; `CLAUDE.md` is unchanged.
  **Review** (independent, read-only, of `fd72c67`): no blocker and no
  high finding. One medium, fixed. **A release with the flag would have
  been hidden by Play from every phone without Bluetooth**: the two
  legacy permissions each imply `android.hardware.bluetooth` as a
  required feature, whatever their `maxSdkVersion`, and declaring
  Bluetooth LE not required does not take that back — shown with a real
  `aapt2` on the manifest as committed. The manifest now declares that
  feature not required; it is the eighth entry the flag-on check holds;
  and that check also reads `aapt2 dump badging`, which applies Play's
  rules, and fails on any Bluetooth feature listed as required or
  implied. Two low, fixed: the flag-on check now fails anything of the
  mesh that is not one of the entries — another manifest's Bluetooth
  permission, feature or broadcast; and the sentences that still gave
  Haven's floor as API 23, and its range without mesh as Android 6 to
  10, say what is built — Android 7 to 10, the floor being Flutter's
  default (24 at Flutter 3.50.0), which nothing in Haven pins; whether
  it should be pinned is the owner's (design Q-16). A second mutation
  pass, 26 changes to the manifest check, twelve of them to the new
  clauses: all fail a fixture. The badging step, like the rest, has run
  on no APK a build made.
  **The first Android build of the unit (2026-11-14) failed, in every
  lane that builds an APK:** the switch wrote `java.util.Base64` in
  full, and in a build script `java` is the project's extension once a
  plugin adds one. The local run of the expression had been in a
  project with no such plugin. Fixed with an import, and run again in a
  project that applies the `java` plugin, where the failing spelling
  fails with CI's message (design N.7).
- **M3g unit 4**, the radio adapters
  (`docs/BLUETOOTH_MESH_M3_DESIGN.md` §B.1, §B.3, §N.2.2 to §N.2.6, and
  §N.7 for what was read, where the code differs, what the service owes
  it and what only an emulator proves; `…/mesh/MeshLoop.kt`,
  `GattServerAdapter.kt`, `GattClientAdapter.kt`, `AdvertiserAdapter.kt`,
  `ScannerAdapter.kt`; `scripts/ci/check_mesh_radio.sh`). Five Kotlin
  files, the guard and documents: no service, no channel, no manifest
  entry, no Gradle line, no Dart, no Rust, no dependency, no JVM test.
  **Nothing makes an adapter and nothing calls `MeshNative`, so no radio
  starts in any build, with the flag or without. Nothing of this unit
  has been compiled for Android or run on Android: this machine has no
  Android SDK, and its first Android compile is CI's.**
  **What is built.** `MeshLoop`: the one thread of a start and its
  handler; the service's start posted inside `MeshThread.start`, every
  other body — a callback's, a timer's — inside `MeshThread.run`,
  through one function (since the review, below: by the handler itself,
  which a dial also hands the platform). The GATT server: Haven's one service, one
  characteristic (write without response, notify) and its descriptor,
  none of them readable, none asking for encryption; each callback one
  input of the `ServerLinks` made with it; a request answered success
  or a plain refusal (since the review, ATT's "request not supported"). The GATT client: one platform client and one
  callback object for each connection `GattClientSteps` makes, over LE,
  no auto-connect; each callback one input, each step one call. The
  advertisement: the service UUID, the constants' mode and power,
  connectable, no timeout, no name, no power level, no data, no scan
  response, and "not discoverable" from Android 14. The scan: one
  filter on the service UUID in the constants' mode, started when the
  core says and only where a scan would be given results. Where
  Android 13 gave a call or a callback a form that carries the value,
  both forms are there, each for its own levels.
  **Proved here** — by a compiler and a class-file reader, nothing
  more. The radio's whole Kotlin (the pure package, `MeshNative`, the
  five files) compiles with no warning, warnings being errors and the
  extended ones on, in a scratch Gradle build with the JVM build's
  Kotlin (2.4.20) and options whose compile classpath is a copy of API
  36's `android.jar`; the same against copies of 34 and 35. Against API
  23's — the distribution's package — it fails on exactly the seven
  members that are newer, each of which the code calls behind
  `SDK_INT`, names for a constant the compiler inlines, or overrides:
  so every other member exists on every level Haven installs on. The
  class files name thirty platform classes, all in API 23's jar. With
  the four suppressions taken out the compile fails on the eight
  deprecation warnings they cover and nothing else. The level each newer
  member came at, and five things the code rests on — which
  notification callback the platform calls on which release, what
  throws with Bluetooth off, that a dial by address finds its type,
  what a refusal goes out as, that an unreadable attribute is refused
  by the stack — were read on the reference pages and in mirrors of
  the platform's source (design §N.7 has the files and lines); none of
  it was run.
  **The guard**, `check_mesh_radio.sh`, three new checks. 15: the loop
  is held to its four uses of the handler and its one wrapper; no other
  adapter names a thread, a handler or the wrapper; every platform
  callback outside the pure package is one post through the loop, the
  notification callback of before Android 13 excepted, pinned whole and
  required once. 16: no name that could start a pairing, in any file of
  the radio; the one dial and the one answer pinned. 17: the
  advertisement's three statements pinned, each of its calls written
  once, and no name of a field it must not carry. 276 self-test
  fixtures (198, and 78), one of them a misconfiguration: adapters that
  declare no callback.
  **Mutation pass**, 69 changes to the guard, each dropping one pin,
  allowing one name, or silencing or loosening one clause: the loop's
  five pins and three counts; each of the nine words an adapter may not
  name; the callbacks' comparison, any expression body passing, a body
  that only begins with its post; the older callback absent, or there
  twice; a radio with no callback read as a pass; another source set, or
  the pure package, left unread; check 16's twelve names and three
  patterns, its two pins and two counts; the advertisement's three
  pins, nine calls and seven names. All fail a named fixture. Two
  things the pass changed on the way: one alternative of check 16's
  pattern that no platform name reaches alone was taken out; and ten
  failures of the first run were the fixture count's or a script
  error's, not a fixture's — check 17's fixtures were reading the lists
  they test, and no longer do.
  **Only CI proves, and has not run**: that the five files compile
  under the Android plugin against Google's own `android.jar`, in the
  three legs and in the flag-on job. No job lints them or builds a
  release with them.
  **Not proved, by anything**: every behaviour. No adapter has met a
  Bluetooth stack: that a server opens and a peer finds its service,
  that an advertisement starts and is found, that a dial connects and
  its steps complete, that a frame crosses in either direction, that a
  close ends anything — design §N.7 lists what each rests on and
  whether it was read. The lever's two calls still run nowhere:
  nothing reaches `MeshThread.run` in a build.
  **Found, and put to the owner** (design §N.7): on Android 11 to 12L
  the platform keeps a notification's value and a frame about to be
  written in the same object, on two threads, so a frame on a link this
  phone dialled could be lost or replaced by the peer's own bytes —
  fixed with the review, below. With Bluetooth off two of the adapters'
  closes throw, as read: the service must close each in a `try` of its
  own, or §B.6's pause is a stop with the notice. Still for the owner:
  a GATT server that does not open is a stop with the notice, not a
  phone that only dials; no attribute of Haven's can be read.
  `haven-core/SECURITY.md` changes by one sentence, where it said that
  no platform code scans, advertises or connects: the classes are
  written and nothing makes one. The privacy manifest,
  `haven/DEVELOPMENT.md` and `CLAUDE.md` are unchanged.
  **Review** (independent, read-only, of `f2e55ec`): no blocker and no
  high finding. One medium, fixed. **Before Android 13 a frame this
  phone wrote on a link it dialled could cross a notification** — the
  defect above. The dial now uses `connectGatt`'s form that takes a
  handler, the mesh thread's, so the platform's own write of a
  notification's value runs on the thread a frame is written from. A
  handler takes the platform's `try` away from its runnables, and a
  throw on the mesh thread would end the process the relay path runs
  in: so the handler handed over is the loop's own, which runs every
  message it dispatches inside `MeshThread.run`, the platform's
  included; the service's start alone goes through a second one, since
  it must not be asked the lever. Six low, fixed: the two adapters'
  comments said nothing there could start a pairing, where a peer can
  make the platform ask — by a refused descriptor write, by a Security
  Request, or as a central — and only the bond receiver ends it
  (design §M.4 gains the second); a refusal is now ATT 0x06, "request
  not supported", a code that rests on no cast; a server whose service
  the platform will not begin to add is closed before the throw; **a
  dial is given up at its next callback past its 25 s as well as at
  its timer**, which stops counting while the phone sleeps — in
  `GattClientSteps`, with two JVM tests, 59 in all; design §M.5 says
  that an Android scan is an active one, and what its requests and a
  Haven phone's empty responses tell someone in range — nothing that
  names Haven or the user; and the guard follows a callback's lambda to
  its closing brace, so that work chained behind the post fails, and
  fails `PROPERTY_READ` and `PERMISSION_READ`.
  **Proved here**, as before by a compiler and tests alone: the scratch
  type-check against API 36's, 35's and 34's jars, no warning; against
  API 23's it now fails on ten members, the three more being the dial's
  form, its PHY constant (API 26, as the reference has them) and the
  level named to lint; the 59 JVM tests. `check_mesh_radio.sh`: 280
  self-test fixtures (276, and four), run side by side, as many as
  there are processors — 73 s here where the 276 took three
  minutes, every fixture still the whole guard on a tree of its own.
  **Mutation passes.** 72 changes to checks 15 to 17 as they
  stand — the first pass's again where the text is the same, and for
  what is new: each of the loop's five pins and three counts, what may
  follow a callback's lambda, the two names of a readable attribute,
  the dial's and the answer's new pins — each failing a named fixture.
  Nine changes to `GattClientSteps`: the rule taken out of each
  of its five places in turn, its bound moved a millisecond either way,
  a lost link read as a failed dial, and the rule never true — each
  failing one of the two new tests by name.
  **Not proved, by anything**: as above, and that with a handler the
  platform runs nothing of a client's outside the loop's wrapper, and
  that nothing crosses on Android 11 to 12L — both read in the
  platform's source, neither run. The contract the review set for the
  service is design §N.7.
- **M3g units 5 and 6, and M3h's first slices — designed, not built**
  (`docs/BLUETOOTH_MESH_M3_DESIGN.md` §O; drafted and **confirmed with
  changes by an independent review, both 2026-11-14**, and revised in
  place for it: §O.5 has each finding and what it changed). Paper
  only: no file but that section and this entry changed, and nothing
  was compiled or run for it. What it settles: the service's start,
  pause, alarm, wake lock, stored copy and stop, with the pure classes
  and JVM tests that hold each decision (§O.1) — among them, from the
  review, that nothing is evaluated before the foreground start and
  that a stop cannot bring down a start it did not see (a service
  ended while it owes its foreground ends the relay path's process),
  that the registered receivers are exported, and that a notice's tap
  goes through an activity alias no other app can start; that nothing
  but the Dart channel starts a service that runs a radio (§O.1.9);
  and the order of landing, **two pushes** (§O.3): first everything
  that cannot reach `leverInstall` — the service's classes in no
  manifest, the channel without its three lever-gated methods, and a
  lane with a flag-off control, an API 29 leg and a probe that
  measures what no source could settle — then the manifest's entries,
  the three methods and the lever's own slice, which needs an adapter
  that enables and no peer (§O.2). **Found outside the tree**: one
  open-source project runs two emulators on one virtual Bluetooth
  medium on a GitHub-hosted runner, on the image Haven's lanes boot,
  cold-booted on a pinned emulator; no primary source read names the
  API levels whose image has a virtual controller. Seven questions
  are the owner's, Q-17 to Q-23 (§O.4): none is decided there.
- **M3g units 5 and 6, push A, part 1** — the service's classes in no
  manifest, and the channel without the three methods behind the log
  lever (`docs/BLUETOOTH_MESH_M3_DESIGN.md` §O.3's push A without its
  lane; §O.6 for what was built, each difference from §O, and what is
  proved by what; `…/mesh/MeshService.kt`, `MeshNotices.kt`,
  `MeshPrefs.kt`, `MeshReceiver.kt`, `MeshChannel.kt`, `MainActivity.kt`,
  eleven files of `…/mesh/core/`, `haven/lib/src/services/mesh_radio.dart`,
  `haven/lib/src/providers/mesh_provider.dart`,
  `scripts/ci/check_mesh_radio.sh`). No manifest entry, no permission,
  no Gradle line, no Rust, no dependency. **No manifest declares the
  service, the receiver or the alias, and the channel answers neither
  `bluetoothOn`, `bluetoothName` nor `start`: in no build, with the
  flag or without, is the service made or the log lever reached, and a
  guard says so. Nothing of it has been compiled for Android or run on
  Android. The lane (S0, the probe, S2) is not part of this entry.**
  **What is built.** In the pure package: the start's inputs handed
  over unread, the foreground start first; a stop that lets go of the
  service before anything else and ends it by the last start command
  that joined; which start command makes a start; what boot and the
  alarm do with no service; when the alarm and the wake lock are asked
  of the platform, and how far ahead; a radio's closes, each run
  whatever the one before threw; Bluetooth's switch as a pause; which
  notice goes under which id; a tap read only through the alias, once.
  Fourteen JVM tests, 73 in all. The service, its notices, its stored
  copy and its receiver as §O.1 has them, adapters over those answers.
  The channel: eight methods answered, the three behind the lever
  answered by nobody, so a turn-on in a build with the flag still ends
  at `failed` with nothing stored — now behind the system's permission
  dialog, which the channel does ask. The Dart seam: `supported()`,
  asked before anything of the mesh is drawn — no button on a phone
  that cannot run it — and `actions` asking for the tap that opened the
  app.
  **Read for it**: the engine's wake is never later than its deadline
  (`haven/rust_builder/src/api.rs:13518-13525`, `:13393-13395`;
  `haven-core/src/mesh/engine.rs:759-768`) — §O's open point; the pure
  side takes it as it is.
  **Where it differs from §O** (§O.6 has each with its reason): the
  thread's lever is a function too, so that the native class is first
  named behind the foreground start; a stop leaves the foreground only
  where no start was made since it let go; the alarm is moved for a
  wake that differs by more than a slack either way, and one is always
  armed ahead; the foreground start says "on" and is put right once the
  adapter is read; a `sync` takes the reminder down and one still owed
  is given again; the channel's `stop` answers when the service has
  stopped; a tap is not read from an intent the system replays.
  **Proved here**: the 73 JVM tests; the mesh's Kotlin and
  `MainActivity` type-checked with no warning against copies of API
  36's, 35's and 34's `android.jar` and Flutter's own embedding jar,
  with stand-ins for `BuildConfig` and two `androidx` types; every
  platform member used found in API 36's jar, and the three newer than
  API 30 — all Android 13's — each behind its level; `flutter analyze`
  and the Dart tests, among them one that reads the Kotlin side's words
  and holds them to the Dart side's; `check_mesh_radio.sh`, 431
  self-test fixtures (280, and 151). **Mutation passes**: 143 changes
  to the guard's new clauses, 68 to the new pure code, eight to the
  Dart seam and the channel's words — each failing a named fixture or
  test (six of the guard's by failing the unchanged tree).
  **Only CI proves, and has not run**: the Android compile of the six
  files in the three legs and the flag-on job.
  **Not proved, by anything**: every behaviour of the service on
  Android — a foreground start from the mesh thread, a start command
  behind a stop, the receivers' delivery, the alarm's lateness, a
  notice's tap (§O.6's table). `haven-core/SECURITY.md`, the privacy
  manifest and `haven/DEVELOPMENT.md` change where they said the radio's
  channels have no native end and that there is no service: a channel
  answers what touches no Bluetooth, and the service is written and in
  no manifest. For the owner, beside Q-17 to Q-23: a boot that finds
  the twelve hours passed leaves the flag set and tells nobody.

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

**7. "Rust lints" (Code Quality).** The line says of every crate what holds
for `haven-core`, and since M3b the bridge crate has a rule of its own —
three allowances since M3g's first unit, which the wording below now says.

Old:

> - **Rust lints**: `clippy::pedantic` and `clippy::nursery` are enabled;
>   `unsafe_code` is denied

New:

> - **Rust lints**: `haven-core` enables `clippy::pedantic` and
>   `clippy::nursery` and denies `unsafe_code`. The bridge crate
>   (`haven/rust_builder`) denies `unsafe_code` too, with three allowances
>   and no other: the generated bridge; the Android radio's JNI exports,
>   `mesh_jni.rs`, where the lint fires on `#[no_mangle]` — nothing but
>   those exports may be in that file, each one call into `mesh_radio.rs`,
>   which is under the deny; and the log lever, `log_lever.rs` — a symbol
>   lookup, a C callback and calls through function pointers, whose
>   decisions are `api.rs`'s, under the deny
>   (`scripts/ci/check_mesh_radio.sh`)

Next: M3, the radio, and with it everything on screen, as
`docs/BLUETOOTH_MESH_M3_DESIGN.md` has it; and, if Android is to pass
anything on, a bridge step after its fetch.
