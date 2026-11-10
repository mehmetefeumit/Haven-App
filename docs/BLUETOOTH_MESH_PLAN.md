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

The relay path is not touched: the same sealed event is published to relays
exactly as today, mesh on or off.

### 0.2 The decisions that shape everything

| # | Decision | Why |
|---|---|---|
| 1 | A packet has **no cleartext field**: no version, hop count, timestamp, id or tag. It is 12 random bytes + ciphertext + 16-byte tag. | Requirement F1. A hop count is "how far it comes from"; a timestamp is age, hence distance; a circle tag links a circle's packets. bitchat exposes sender id, recipient id, timestamp and TTL and calls metadata "the weakest part of this design" [V]. |
| 2 | The packet wraps the **complete signed kind-445 event** under a mesh key derived from the circle's MLS epoch. Never the bare MLS message. | A bare `PrivateMessage` shows `group_id` and `epoch` in clear (RFC 9420 §6.3) — the real MLS group id (Rule 4). The kind-445 `h` tag is a permanent per-circle id [V]. MDK's ingest needs the verified event [V]. |
| 3 | **One seal, two carriers.** The mesh takes the event the relay path sealed and passed its send-time check; it never seals. | No extra ratchet use. The engine dedups the relay copy and the mesh copy as one message, in either arrival order [V]. |
| 4 | **All protocol logic is one sans-IO Rust state machine** (`haven_core::mesh::MeshEngine`); Kotlin and Swift only move bytes. | The only layer CI can test deterministically on every push. Neither bitchat app has multi-device radio tests in CI [V]. |
| 5 | **The engine holds no key.** Wrapping and opening happen in the MLS session's own code; the engine stores and forwards opaque bytes. | Forwarding cannot depend on recognition by construction; no key material is reachable from the native radio interface. |
| 6 | **Forward-all-opaque, flood by inventory, fixed emission schedule.** | No per-packet routing state. Membership-dependent forwarding would be a co-membership oracle. |

### 0.3 Withdrawn from `MESH_LOCATION_RELAY_DESIGN.md`

- "Option B" payload (bare MLS message): leaks the MLS group id and epoch.
- The frame `[type][ttl][mesh_msg_id][freshness]`: three cleartext fields.
- Its rule "never cache exporter-derived secrets" (R-9/G-11): knowingly
  reversed — the mesh keys for retained epochs are stored (§4.2).
- Top-right toggle: the owner now specifies bottom-left.
- Opt-in internet bridging: now never (D-7).
- Simulator "routing only": replaced by §9.

Its threat analysis (radio localisation, crowd counting, tracking,
forward-all-opaque, photos excluded) stands and is carried into §8.

### 0.4 What this plan cannot promise — read before approving

**Platform**

1. **Two locked iPhones that have never met will not reliably find each
   other**, and an Android phone cannot find a locked iPhone. This is Apple's
   design (§7.2). No CI can prove any iOS radio behaviour.
2. **A phone asleep with location sharing off is a slow relay.** Android's
   processor sleeps between radio events; iOS suspends the app. Such a phone
   forwards when a neighbour's traffic wakes it and otherwise wakes on a
   coarse timer (§7.3). CI emulators never sleep, so this is proved only on
   hardware, which the project does not have (`POWER_EFFICIENCY_PLAN.md` §2.5).
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
8. **Whether a phone is asleep is observable** from its emission rhythm.

**Function**

9. **A flooding mesh has a size ceiling** (§6.6).
10. **A circle is silent on mesh while the relay path would hold it**: a
    commit awaiting a relay acknowledgement (including one Haven makes itself,
    such as a departure eviction), a leave in progress, a disbanded circle, a
    routing collision, an unread fetched commit. Offline, most of these last
    until a relay is reachable (list in §5.4).
11. **The mesh carries no commits**, so a member who missed an epoch change
    cannot read members who took it, until relays return.
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
| F2 | Ongoing notification while mesh is on | §7.1, §7.2 | T-NOTIF-* |
| F3 | Least power without degrading function | §7.3 | T-PWR-*, ESTIMATED model |
| F4 | Hold the button: circle updates received / updates relayed for others; session and lifetime | §7.5 | T-STAT-* |
| F5 | Relay path unchanged with mesh on or off | §3, §5.1 | T-INDEP-* |
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
- **Independence (F5).** The mesh's only contact with the relay path is one
  call, `mesh::offer`, inside `publish_location` after the `may_be_sent`
  check and before the relay send. It is synchronous, does no I/O, cannot
  fail or block, and returns `()`. A guard allows `mesh::` to be named in
  `relay/` and `nostr/` at that one site only.
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
  format      1 B   0x01 = tag layout [h, expiration]
  pubkey     32 B   the event's ephemeral key
  sig        64 B
  created_at  8 B
  expiration  8 B
  content_len 2 B
  content   ≤881 B  the kind-445 content, base64-decoded
  padding           zero; the opener verifies it is all zero
```

- The recipient rebuilds the event with `h` from the circle whose key opened
  the packet, recomputes `id`, and calls `Event::verify()`. A packet opened
  under the wrong circle's key fails there, because `id` binds `h`.
- A test re-read at every MDK bump pins the tag layout that format `0x01`
  means.
- One size. An event that does not fit is not sent over mesh. Content is
  computed at 590–640 B, not measured; M0 measures it (G-2).
- A cover packet is 1024 CSPRNG bytes.
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
  peers who are still on an older epoch. MDK already persists the secrets for
  the same epochs; this adds a derivative of them, not a longer window.
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
   of the least-recently-served circle, or a cover packet.
4. The emitted packet goes into the store like any other and reaches peers
   only through §6. There is no "send now" path.
5. After sleep the engine emits at most one packet on waking, whatever the
   outbox holds.

So a non-member neighbour sees one new opaque packet per slot from every
awake phone and cannot tell whether it shares, with how many circles, or
whether a given packet is real. Cost: with `k` sharing circles each updates
every `k × 90 s` on mesh, and an update older than 228 s when its slot comes
is skipped for the next one (D-2).

### 5.2 Receive

1. The engine accepts a packet only if it asked for it on that link (§6.3).
   New id → stored and announced to other links, always.
2. At each drive `mesh_drive` takes the packets not yet offered to it, tries
   the keys, rebuilds, verifies, applies §4.3, and hands the event to the
   driver's ingest for its circle through `order_for_ingest`.
3. The mesh plane owns no relay cursor, touches no `relay_floors`, and does
   not feed the stall detector (`observe = false`), so a crafted packet
   cannot arm a history walk.
4. Bounds: a per-circle cap on events per drive and a drain budget; nothing
   is drained into a circle held for a pending commit (it would grow the
   engine's uncapped buffer, Rule 12). A packet is marked done only when the
   engine took the event in; otherwise it is offered again while held.
5. Packets not yet offered to `mesh_drive` are kept in a bounded local queue
   (default 4096, oldest dropped) even after their forwarding hold ends, so a
   phone whose app was not running can still read what passed through it.

A copy that arrived first by relay is a duplicate in the engine: silent.

### 5.3 Freshness

No time on the wire. Members judge staleness on the MLS-authenticated inner
timestamp as today; the 15-minute `expires_at` and 24 h last-known retention
apply unchanged. An authentic packet replayed later or elsewhere is a
duplicate, or shows as stale.

### 5.4 When a circle is silent on mesh

Exactly when the relay path would not send: `SendHeld::AwaitingRelays`,
`StagedWithoutRecord`, `DepartureDue`, `AwaitsForeground`, `RemovalUnmade`,
`Leaving`, `Disbanded`, `RoutingCollision`, `StoredInput`
(`fanout.rs:2967-3021`), plus `Expired`/`Superseded` at publish. Nothing
observable changes on air: the slot carries another circle's update or a
cover packet.

**iOS background:** a burst that cannot receive seals nothing, so a
backgrounded iPhone with no relay reachable sends no location over mesh.
Owner decision D-8.

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
- Two phones form links in both directions. `HELLO` carries a random value
  regenerated every 15 minutes and never advertised; a phone seeing the same
  value on two links closes one by a fixed rule.
- GATT, not L2CAP (undocumented background behaviour on iOS).
- Connection parameters: Android `CONNECTION_PRIORITY_LOW_POWER`; iOS
  `setDesiredConnectionLatency(.high)`.

### 6.2 Link frames

`[type:1][body]`: `HELLO` (protocol version, the random value above), `HAVE`
(packet ids), `WANT` (packet ids), `PKT` (`[index:1][chunk]`), `BYE`. Each
body has a fixed maximum checked before allocation. An unknown type, an
oversized body or a version mismatch closes the link.

### 6.3 Inventory flood

- On connect, each side announces its whole store as batched `HAVE`, in
  packet-id order. Afterwards it announces newly stored packets the same way
  on one coalesced tick for all links (period fixed by the simulator against
  the hold time), never immediately, never in arrival order, never to the
  link a packet came from.
- The other side answers `WANT` for ids it lacks. Sends are paced on the
  platform's ready signals and chunked by the MTU each side negotiated.
- A reassembled packet is accepted **only if its id is in that link's
  outstanding `WANT` set**; otherwise it is discarded and asked for again, a
  bounded number of times, then on another link. A dropped or reordered chunk
  therefore cannot mint a new packet, and an unsolicited `PKT` closes the
  link.
- One mechanism only: a full id list for a 2048-packet store is 32 KB, under
  2 % of what it indexes. No set reconciliation in v1.

### 6.4 Store

- Bounded (default 2048 packets ≈ 2 MB), memory only, never on disk.
- Hold: a fixed time from first local receipt on the suspend-inclusive clock
  (default 20 min).
- Seen-set: an id is recorded only for a fully received, verified-by-hash
  packet, kept at least twice the hold time, evicted strictly by age. At its
  cap the engine refuses new packets rather than forget young ids.
- Own and carried packets are the same rows, evicted by the same rule.
- **Lifetime under churn is the open design question (G-7).** With a
  per-phone hold and no time on the wire, every newcomer or restarted phone
  accepts whatever a neighbour still holds for a fresh hold period, so a
  packet's global life is unbounded where people keep arriving. The simulator
  measures this with arrivals and restarts. If the delivery targets fail,
  the fallback is a coarse remaining-hold bucket carried in the `HAVE` entry
  — a link field, not a packet field — with a randomised starting value at
  the origin; the receiver holds `min(own, announced)`. That bounds life
  globally and tells a connected neighbour a coarse age. Owner decision D-1.

### 6.5 Limits

- Credit per link slot that **grows with link age**; a new link starts near
  zero. Packets from closed links fall into one "departed" class evicted
  first. Together these stop an attacker who cycles Bluetooth addresses from
  turning the fairness rule against long-lived honest links.
- A global rate limit on new inbound connections and on newly accepted
  packets.
- A link that sends malformed frames or exceeds its credit repeatedly is
  closed.
- No proof of work: affordable for a phone means trivial for an attacker.
- **Stated bound:** a per-link allowance must admit an honest bridge carrying
  a whole cluster, so one attacker link can inject about one maximum-size
  cluster's load, and fairness protects only the first hop. T-SEC-SYBIL
  measures delivery two or more hops from the attacker; the plan claims no
  bound beyond that measurement.

### 6.6 Scale

Each awake phone emits one packet per 90 s. A connected cluster of `n` sees
`n / 90` new packets per second and, without churn, holds about `13 n` at a
20-minute hold: a 2048-packet store is lossless to about 150 phones. Radio
throughput (estimated 20–60 packets/s per phone across its links, to be
measured) saturates several times above that, so the store binds first.
Beyond the ceiling far-away updates are lost first. The simulator, with a
per-link byte rate, discovery delay, connect delay, arrivals and restarts,
fixes the slot period, hold time and store size. If the owner wants festival
scale, cover traffic (D-2) is the first cost to revisit.

### 6.7 Link encryption — not in v1

A per-link `Noise_NN` session would hide from a purely passive sniffer which
packets cross a link. It gives nothing against an attacker who connects,
which an open mesh allows, and adds a dependency in three lockfiles. `HELLO`
carries a version so it can be added. D-5 presents both views.

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
  screen). Whether mesh may run with notifications denied is D-9.
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
  relaunch; removed at mesh off. Authorization is requested in the enable
  flow. iOS lets the user clear it; D-3 (auto-off) is the stronger answer to
  "forgot it on". A Live Activity is a later option, not v1: it needs a
  second signed target, iOS 16.1+, and ends after 8 h.

### 7.3 Power and wake-ups (F3)

What wakes the processor for each periodic action:

| Action | Android, sharing on | Android, sharing off | iOS, sharing on | iOS, sharing off |
|---|---|---|---|---|
| Advertise, filtered scan | Bluetooth controller | controller | controller | controller |
| Inbound frame | radio event + short timed wake lock | same | process running | Bluetooth wake (~10 s) |
| Emission slot, announce tick, hold expiry | location service's existing wake | allow-while-idle alarm (≥ ~9 min in Doze) and any radio event | process running | only on a Bluetooth wake |

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

Tap → first time, a disclosure sheet (what is shared; §0.4 items 6–8 in plain
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
- **Updates from your circles** = unique packets that opened under one of
  this phone's keys and verified. **Passed on** = unique packets this phone
  did not emit and could not open, counted when first sent to another phone.
- "Since turned on" survives a process restart while mesh stays on. Lifetime
  values are two integers in the SQLCipher `user_settings` table, folded at
  every drive and at mesh off: no timestamps, no per-circle or per-peer
  breakdown. What was counted since the last fold is lost if the process is
  killed; the promise is that the lifetime value never decreases and includes
  everything up to the last fold.
- Exact counts are shown, never logged (Rule 15).
- 13 locales, each translated and independently reviewed.

---

## 8. Security and privacy

### 8.1 Threat model

| Adversary | Learns | Cannot learn | Residual |
|---|---|---|---|
| Passive sniffer | A phone runs Haven mesh; link timing and volume; sleep state | Circle, sender, content, age, hop count, real vs cover | Presence, counting, direction-finding |
| Connected non-member | Packet ids; a neighbour's whole store; first-seen times | Same | Re-identifies a phone across address rotation; as a lone neighbour, knows which packets a phone emitted; with many nodes, first-seen timing points at an originating device |
| Malicious member | What the circle shares; which packets are the circle's | Other circles | Can send future-epoch application messages toward the engine buffer, bounded by §5.2 |
| Removed member | Packets sealed at epochs they held, from members who have not seen the removal | Later epochs | An outage freezes epochs, so the window lasts as long as the outage |
| Replay | — | — | Authentic replay is a duplicate or stale (§5.3) |
| Device seizure | Lifetime counters; that mesh was used; mesh keys for retained epochs (the same epochs MDK already stores) | Carried packets (memory only) | — |
| Flooder / address cycler / eclipse | — | — | §6.5 |

### 8.2 Rules and documents changed in the same commit as the first code

- **New Security Rule 17 (Mesh):** no cleartext field in a packet; only
  application messages cross the mesh, checked at both ends; a location
  reaches the mesh only after the relay path's send-time check; the engine
  holds no key and forwarding never depends on recognition; the mesh never
  seals, never bridges a carried packet to a relay, never holds an MLS
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
  redelivers after 288 s; the stale "FFI exposes no streams" line.
- Rule 15: a new `log_alias` class for a mesh link; Bluetooth addresses,
  peripheral identifiers, packet ids, per-peer RSSI and exact counts never
  reach a log; native lines allowlisted; redacting `Debug` with proof for
  every new type; a planted-identifier test per new line; netsim captures are
  never uploaded unscanned.
- The privacy manifest gains an invariant per promise here and the new usage
  strings.
- Rule 10: the feature adds exposure (§0.4 items 6–8; ciphertext held by
  strangers for the hold time). It is owner-directed by this request and is
  recorded as such.

### 8.3 Reviews at implementation

security-reviewer on key derivation and storage, the envelope, the C
interface and the ingest seam; marmot-expert on epoch handling;
dependency-auditor on `jni` and on making `hkdf` (pinned to the 0.12 line
already resolved) and `chacha20poly1305` direct dependencies in all three
lockfiles.

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
  and for own and carried packets, including eviction.
- **T-PRIV-4** a node's emissions are identical in count and timing with 0, 1
  and 10 sharing circles, with a circle held, and across a clock jump.
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
  before the next slot. **T-SEC-8** a flooded seen-set never re-accepts a
  packet within twice the hold time.

**Independence**
- **T-INDEP-1a** (soak) the same profile and seed run with mesh off, then on:
  per device, the multiset of client→relay `EVENT` frames projected to
  (plane, kind, tag names, `expiration − created_at`, verdict) is equal, the
  sequence of seal and publish outcomes is equal, and the plane oracle shows
  no new frame class at any relay.
- **T-INDEP-1b** `publish_location` returns the same outcome with zero added
  virtual time when the mesh outbox is full, never drained, or gone.
- **T-INDEP-1c** guard: one `mesh::` site under `relay/` and `nostr/`.
- **T-INDEP-3** with relays down, locations arrive by mesh; when relays
  return nothing is duplicated on the map.
- **T-INDEP-4** with mesh on and sharing off, swiping the app away leaves the
  catch-up worker and a relaunch able to obtain the MLS session; on iOS no
  Bluetooth manager exists while mesh is off.
- The existing core-flow, background-catch-up and foreground-service lanes
  run their relay oracles once more with mesh on and a peer present.

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
  the notification open the same sheet; it reads correctly through the
  semantics tree; the button and the map controls do not overlap under
  right-to-left, 200 % text and small screens.
- **T-NOTIF-1** mesh on ⇒ notification present; off ⇒ absent. **T-NOTIF-2**
  after a cancel through a test notification listener, the next screen-off
  posts it again.
- **T-BG-1** (Android emulator) screen off and forced idle, packets still
  flow; process killed, the service returns; reboot with mesh on, mesh
  resumes; reboot with the permission revoked, no crash. The lane states it
  does not prove processor sleep.
- **T-PWR-1..3** scan and advertise modes and connection priority from one
  constants site with a guard; link cap; no frames with no peers.
- **T-LOG-1** planted identifiers absent from every sink in every lane.

---

## 10. Milestones

Each lands complete with its tests. Mesh code ships behind a compile-time
define, default off (the `HAVEN_LIVE_SYNC` precedent, with coverage's
flag-off run), until M5.

| M | Scope | Exit |
|---|---|---|
| M0 | Spikes, not merged: (a) one emulator + Bumble + a Rust peer on netsim on a hosted runner — ≥ 50 consecutive green runs, cold and snapshot boot, peripheral role, ≥ 2+2 links, negotiated MTU, time-to-first-link p99, usable capture; (b) measured sealed-location size; (c) notification re-post mechanism; (d) Swift → Rust smoke build; (e) CoreBluetooth mock in the simulator; (f) the Play declaration and App Review questions | G-1, G-2, G-4, G-6, G-8 answered here |
| M1 | `MeshEngine` + `mesh_sim` with churn; parameters and D-1 decided from data | L1, L2; T-PRIV-1..4,6; T-SEC-3,4,8,SYBIL; T-DELIV; T-PERF-1,2 |
| M2 | Keys in `SessionManager` + store, `mesh::offer`, `mesh_drive`, counters; soak scenarios; Rule 17 and the amended documents | L3; T-INDEP-1a..c,3; T-SEC-1,2,5,6,7; T-STAT-1 |
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
- **G-2** a sealed location fits 881 B of content [computed, not measured].
- **G-3** *answered:* Haven seals with no relay reachable in the foreground
  and in the Android foreground service; not in an iOS background burst (D-8).
- **G-4** Google Play accepts `connectedDevice` for phone-to-phone; App
  Review accepts the two Bluetooth background modes [U].
- **G-5** *answered:* §0.4 item 12.
- **G-6** the API 34 emulator image supports the peripheral role and several
  links under netsim and survives snapshot boot [U].
- **G-7** the churn simulation decides packet lifetime (D-1).
- **G-8** the Swift adapter can be exercised in CI with a CoreBluetooth mock
  [U].
- **G-9** mesh-on does not change MLS session ownership or reclaim
  (T-INDEP-4).
- **G-10** the timed-wake-lock design delivers frames on a sleeping Android
  phone [U, hardware only].

### Owner decisions

- **D-1 Packet lifetime.** Nothing about time anywhere (strictest reading of
  F1; global lifetime unbounded under churn) — or a coarse remaining-hold
  value on the link (bounded; a connected neighbour learns a coarse age).
  Recommendation: start with the first, adopt the second only if M1's churn
  data requires it; please say now whether the second is acceptable.
- **D-2 Cover traffic.** Fixed-rate emission with cover packets (recommended:
  hides whether and how much a phone shares; costs capacity, slows
  multi-circle users, and makes "passed on" include cover packets) — or emit
  only real updates.
- **D-3 Auto-off.** None (as requested) — or a timer (e.g. 12 h) with a
  reminder, the only strong answer to "forgot it on" where notifications can
  be cleared.
- **D-4 Lifetime counters.** In the encrypted store (recommended; shows on
  seizure that mesh was used) — or session-only.
- **D-5 Link encryption.** Leave out of v1 (recommended) — or add `Noise_NN`
  now.
- **D-6 iOS residuals.** Accept §0.4 items 1, 2, 4 and, if G-8 fails, a Swift
  adapter unverified in CI, with physical verification deferred until devices
  exist.
- **D-7 Internet bridging.** Never (recommended): a phone with internet does
  not publish what it carries.
- **D-8 iOS background sealing offline.** Keep receive-before-seal (a
  backgrounded iPhone offline sends nothing over mesh) — or let a burst that
  failed to receive *because no relay was reachable* seal for mesh. The
  second weakens a Rule 10 protection: a member whose removal the phone could
  not fetch can still read that fix. The foreground and Android paths already
  behave this way.
- **D-9 Notifications denied.** Mesh cannot be turned on without notification
  permission (recommended: F2 says there is always a notification) — or
  allowed, with the button as the only indicator.
- **D-10 Offline sealing cadence.** Unchanged (as F5 implies) — or seal less
  often while no relay is reachable, which postpones §0.4 item 12.

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
| Hand-off after seal bypassed the relay path's send-time check (blocker) | `mesh::offer` sits after `may_be_sent`; outbox purge rules; T-SEC-7 |
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
