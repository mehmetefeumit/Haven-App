# Haven Bluetooth Mesh — Implementation Plan

> Status: **PLAN — no implementation.** Dated 2026-11-10.
> Supersedes the wire format, relay algorithm, UI placement and test strategy of
> `docs/MESH_LOCATION_RELAY_DESIGN.md` (§0.3 lists what is withdrawn and why).
> Evidence tags: **[V]** read from a primary source or this repo's code during
> planning; **[V2]** read from a secondary source; **[U]** unverified — every
> [U] the plan depends on is a gate in §11, never an assumption.

## 0. Summary

### 0.1 What is built

An opt-in, default-off second carrier for the location updates Haven already
seals. With mesh on, a phone:

1. wraps each location event it seals for the relay path in a fixed-size,
   fully opaque 1024-byte packet and puts it in a local store;
2. exchanges store contents with nearby mesh phones over Bluetooth LE, in both
   directions, whether or not it can read them;
3. tries to open every new packet with its own circles' mesh keys, and feeds
   what opens into the normal MLS ingest.

The relay path is not touched: the same seal is published to relays exactly as
today, mesh on or off.

### 0.2 The five decisions that shape everything

| # | Decision | Why |
|---|---|---|
| 1 | The air carries **no cleartext field at all**: no version, no TTL/hop count, no timestamp, no id, no tag. A packet is 12 random bytes + ciphertext + 16-byte tag. | Requirement 1. A hop count is "how far it comes from"; a timestamp is age, hence distance; a circle tag links a circle's packets. bitchat exposes sender id, recipient id, timestamp and TTL and calls metadata "the weakest part of this design" [V]. |
| 2 | The packet wraps the **complete signed kind-445 event** under a mesh key derived from the circle's current MLS epoch. It never carries the bare MLS message. | The bare `PrivateMessage` has cleartext `group_id` and `epoch` (RFC 9420 §6.3) — it would publish the real MLS group id (Rule 4). The kind-445's `h` tag is a permanent per-circle id [V] and must not be on air either. MDK's peeler needs the verified event to ingest [V]. |
| 3 | **One seal, two carriers.** The mesh takes the event the relay path sealed; it never seals its own. | No extra MLS ratchet use; the engine dedups relay and mesh copies as one message (Marmot dedup id is the hash of the MLS message bytes) [V]. |
| 4 | **All protocol logic is Rust** (`haven-core/src/mesh/`); Kotlin and Swift are byte pumps for the radio. | It is the only layer CI can test deterministically, on every push, on both platforms' logic. Neither bitchat app has multi-device radio tests in CI [V]. |
| 5 | **Forward-all-opaque, epidemic sync, per-node hold time.** A phone forwards every well-formed packet identically; it originates on a fixed schedule whether or not it has anything to say. | The only relay discipline with no per-packet routing state. Forwarding that depends on membership is a co-membership oracle. |

### 0.3 Withdrawn from `MESH_LOCATION_RELAY_DESIGN.md`

- "Option B" payload (bare MLS message): leaks the MLS group id and epoch.
- The frame `[type][ttl][mesh_msg_id][freshness]`: three cleartext fields.
- Top-right toggle: the owner now specifies bottom-left.
- "iOS foreground-or-pre-connected only" as a v1 scope: replaced by §7.2.
- Simulator "routing only": replaced by the five-layer strategy in §9.

Its threat analysis (RF localisation, crowd counting, forward-all-opaque,
photos excluded) stands and is carried into §8.

### 0.4 What this plan cannot promise — read before approving

1. **iPhone-locked to iPhone-locked first discovery is not reliable, by Apple's
   design**, and no CI can prove iOS radio behaviour (the Simulator has no
   CoreBluetooth [V2]). §7.2 lists what does work and the mitigations; the
   residual needs physical devices, which the project does not have
   (`POWER_EFFICIENCY_PLAN.md` §2.5).
2. **Anyone in radio range can tell a phone runs Haven with mesh on**, count
   such phones and direction-find them. Content, circle and identity stay
   hidden; presence does not. This must be disclosed before first enable.
3. **A flooding mesh has a size ceiling.** Every phone carries every packet.
   §6.6 gives the arithmetic; the simulator fixes the numbers.
4. **Every battery figure is ESTIMATED** (model E), never measured.
5. **A circle that entered the outage with an unacknowledged commit is silent
   on mesh** until a relay acknowledges it (Rule 13.4).

---

## 1. Requirements traceability

| Req | Text (short) | Where met | Proved by |
|---|---|---|---|
| F1 | Encrypted always; intermediaries learn nothing about whose, where, how far; minimal metadata | §4, §5, §6 | T-PRIV-* (§9.3) |
| F2 | Ongoing notification while mesh is on | §7.1, §7.2, §7.4 | T-NOTIF-* |
| F3 | Least power without degrading function | §7.3 | T-PWR-* + ESTIMATED model |
| F4 | Hold the button: circle updates received / updates carried for others, session and lifetime | §7.5 | T-STAT-* |
| F5 | Relay path runs unchanged with mesh on or off | §3, §5.1 | T-INDEP-* |
| N1 | Reliable, high-quality CI incl. end-to-end | §9 | the lanes themselves |
| N2 | Bluetooth as a new attack surface handled securely | §8 | T-SEC-*, adversarial peer |

---

## 2. Background the design rests on

### 2.1 Haven today [V, `file:line` at HEAD f1dd146]

- A location is sealed in Rust: `Publishing::seal_location`
  (`haven-core/src/relay/fanout.rs:4660`) returns
  `LocationSeal::Sealed { event, nostr_group_id, relays }` (`:3167`). The event
  is a signed kind-445 with tags `h` and `expiration = created_at + 228`.
- The sealed event is opaque to Dart (`SealedLocationFfi`,
  `haven/rust_builder/src/api.rs:7617`); a second carrier must be handed it
  inside Rust.
- Ingest: `SessionManager::process_event_staging`
  (`haven-core/src/nostr/mls/manager.rs:3075`) → `screen_before_auth` → MDK
  `session.ingest`. Haven's ingest does **not** screen on NIP-40 expiration
  (`manager.rs:3015-3026`); only the relay pool does. A mesh-delivered event
  older than 228 s is therefore ingestible unchanged.
- Engine dedup is by message id; a duplicate is terminal and harmless.
- `nostr_group_id` never rotates in Haven (`haven-core/SECURITY.md:4940`).
- One live MLS session per DB (Rule 14), process-global registry
  (`haven-core/src/nostr/mls/storage.rs:52`). On Android the UI isolate and the
  foreground-service isolate share the process.
- MDK at the pinned rev exposes `exporter_secret(group, label, len)` only for
  three cached labels, current epoch only; there is no arbitrary-label
  exporter (`cgka-session/src/lib.rs:793`).
- No Bluetooth permission, plugin or code exists. No notification code exists
  beyond `flutter_foreground_task`'s. The bottom-left of the map is empty.

### 2.2 bitchat [V, iOS `04995f68`, Android `14ab73c4`]

Borrowed: dual role (every phone is central and peripheral), one service and
one characteristic, write-without-response + notify, RSSI-gated connection
budget, pending connects for iOS background wake, state restoration, duty
cycling, per-type size caps before allocation, an in-memory multi-node
simulator.

Rejected: cleartext header (sender, recipient, timestamp, TTL), static
identity keys and Noise XX, stable peer id in the Android scan response,
neighbour lists in announces, padding only for some types, compression
(decompression bombs: Bridgefy 2022, bitchat-android review C2), relaying
unauthenticated variable-size types.

Licence: the iOS repo is public domain; the Android repo is GPL-3.0. No
Android code is copied.

### 2.3 Platform facts the design depends on

- iOS background: scans need explicit service UUIDs, are slower, and report
  each peripheral once per scan; background advertising drops the local name
  and moves service UUIDs to an "overflow area" visible only to iOS devices
  scanning for that UUID [V, Apple background guide]. A non-Apple central
  cannot decode it (Apple engineer, [V2]).
- iOS state restoration relaunches a terminated app for Bluetooth events, but
  not after a user force-quit or after Bluetooth is switched off in Settings
  [V, TN3115].
- iOS has no non-dismissable notification. A Live Activity lasts at most 8 h
  active + 4 h on the Lock Screen [V, ActivityKit].
- Android: `connectedDevice` foreground services have no time limit (only
  `dataSync` and `mediaProcessing` do) [V]. With the screen off an unfiltered
  scan is not started; a filtered scan in `LOW_POWER` runs at 512 ms / 10.24 s
  (5 %) [V, AOSP via LineageOS mirror, Android 16 base].
- Android 14+: an ongoing notification is user-dismissable except on the lock
  screen; dismissal does not stop the service [V].
- Android 12+: `BLUETOOTH_SCAN` with `neverForLocation`, `BLUETOOTH_ADVERTISE`,
  `BLUETOOTH_CONNECT`; one "Nearby devices" prompt [V].
- Android Emulator 33.1.4+ shares a virtual BLE medium (netsim) across
  emulators on one host; Bumble can join it as a scripted peer [V2]. Two
  projects report two-emulator BLE working; none on a stock GitHub runner [V2].

---

## 3. Architecture

```
            Dart (UI isolate / FGS isolate)            Rust: haven-core
┌──────────────────────────────┐     ┌──────────────────────────────────────┐
│ MeshButton, stats sheet,     │     │ relay::fanout  seal_location ──┐     │
│ MeshController (Riverpod)    │◄───►│   (unchanged relay publish)    │copy │
│ session owner: drains inbox  │ FRB │                                ▼     │
└──────────────────────────────┘     │ mesh::  outbox → envelope → STORE    │
                                     │         keyring (Zeroizing)   ▲  │   │
┌──────────────────────────────┐     │         recognise ──► inbox   │  │   │
│ Kotlin MeshService (FGS)     │     │         sync / link state ────┘  │   │
│ Swift  HavenMeshRadio        │◄───►│         limits, stats            │   │
│ advertise · scan · GATT      │ C   │ (process-global, no MLS session) │   │
│ bytes in / bytes out only    │ ABI └──────────────────────────────────────┘
└──────────────────────────────┘
```

- **`haven-core/src/mesh/`** is a process-global engine holding the store, the
  link state machines, the key ring and the counters. It holds **no MLS
  session**: it can run while no Dart isolate is alive, and Rule 14 is
  untouched.
- **Native radio modules** call the engine directly through a small C ABI
  exported from `rust_builder` (Kotlin via JNI — the tree already loads
  `rust_lib_haven` from `Keyring.kt`; Swift via the static library). Dart is
  not on the forwarding path, so forwarding survives a dead or suspended Dart
  isolate.
- **The session owner** (whichever isolate holds `CircleManagerFfi`) does two
  things at each drive: pushes the current mesh keys to the engine, and drains
  the engine's inbox of recovered events into the existing ingest.
- **Independence (F5).** The mesh's only contact with the relay path is one
  read-only copy of an already-sealed event, taken after the seal returns, on
  a bounded non-blocking queue. A full queue drops the mesh copy. No relay-path
  function takes a mesh result, lock or error.

No Flutter BLE plugin is used. `flutter_blue_plus` and `flutter_reactive_ble`
are central-only; `flutter_blue_plus` needs a commercial licence; no plugin
offers dual role with both-manager state restoration [V]. No Rust crate offers
the peripheral role on mobile [V]. Native modules of the size bitchat ships are
the proven route.

---

## 4. Packet and keys

### 4.1 Layout

```
packet     1024 B   every byte indistinguishable from random to a non-member
  nonce      12 B   OsRng, fresh per packet
  ct        996 B   ChaCha20-Poly1305(K_mesh, nonce, AAD = "haven/mesh/v1")
  tag        16 B

plaintext   996 B
  format      1 B   0x01
  pubkey     32 B   the event's ephemeral key
  sig        64 B
  created_at  8 B
  expiration  8 B
  content_len 2 B
  content   ≤881 B  the kind-445 content, base64-decoded
  padding           zero; the opener verifies it is all zero
```

- The recipient rebuilds the event: `h` from the circle whose key opened the
  packet, `id` recomputed, then `Event::verify()` (Rule 16's check, applied to
  this new ingress), then the normal ingest.
- One size, no buckets. An event that does not fit is not sent over mesh.
  Content size is estimated at 550–610 B, not measured; **M1 measures it** and
  fixes the size before anything else is built.
- A dummy is 1024 `OsRng` bytes. Nobody can open it; nobody can tell it apart.
- Packet id = `SHA-256(packet)[..16]`, computed locally, never a wire field.
- A forwarder never parses, decompresses or allocates from packet contents.

### 4.2 Key schedule

`K_mesh,e = HKDF-SHA256(salt = "haven/mesh/v1", IKM = G_e, info = "packet-aead", 32)`
where `G_e` is the circle's `marmot/group-event` exporter secret at epoch `e`.

- Audience = exactly the members who can already read the kind-445.
- The session owner derives `K_mesh` at each epoch change and hands the engine
  a ring of current + up to 5 past epochs per circle, pruned in step with the
  engine's retention (Rule 5). `Zeroizing`, memory only.
- Senders use the current epoch. Receivers try every key in the ring: at most
  10 circles × 6 epochs = 60 Poly1305 checks per new packet.
- No recognition tag: at 60 keys it saves nothing and adds a field.
- **Rule 11** is not touched: the kind-445 exporter label and derivation are
  unchanged, and `with_exporter_label` is still never called. The rule's nonce
  half applies to the new layer and is met by a fresh `OsRng` nonce per packet;
  a re-broadcast is the same bytes, never a re-encryption.
- **Alternatives considered.** (B) a dedicated exporter label,
  `MLS-Exporter("marmot", "haven-mesh-v1")`, is the textbook form (RFC 9420
  §8.5) but MDK does not expose it; a tracker row `T-MESH-EXPORTER` records the
  move to it when it exists. (C) MDK's safe exporter needs a new required
  group component: an admin commit per circle and no interop with other
  Marmot clients. Rejected.
- `G_e` is read in production Haven code for the first time. security-reviewer
  sign-off is a merge condition for that change.

### 4.3 What the mesh never carries

Commits, proposals, Welcomes, KeyPackages, profiles, photos. Only a sealed
location. Enforced at the producer (the outbox accepts only
`LocationSeal::Sealed`) and pinned by a test and a repo guard.

---

## 5. Sending and receiving

### 5.1 Send

1. The relay path seals as today. On `Sealed`, if mesh is on, a copy of the
   event and its circle's routing id goes to the mesh outbox, which keeps only
   the newest per circle.
2. The engine emits **one packet per emission slot**. Slots recur at a fixed
   jittered period (default 90 s ± 30 s, `OsRng`), the same for every phone.
   A slot takes the outbox's least-recently-sent circle; with nothing to send
   it emits a dummy.
3. The emitted packet goes into the store like any other and reaches peers
   only through the sync in §6. There is no "send now" path.

A neighbour therefore sees the same thing from every phone: one new packet per
slot. It cannot tell whether the phone shares at all, with how many circles,
or whether a packet is its own.

Cost: with `k` sharing circles each circle updates every `k × 90 s` on mesh.
Owner decision D-2.

### 5.2 Receive

1. A packet arrives on a link. Wrong length → the link is charged and the
   packet dropped. Known id → dropped.
2. New id → stored and scheduled for forwarding. Always, with no dependence on
   step 3.
3. Separately the engine tries the key ring. On success it rebuilds the event,
   verifies it, drops it if the event id was already recovered, and queues it
   in the inbox behind the existing intake cap (Rule 12).
4. The session owner drains the inbox into `process_event_staging` through
   `order_for_ingest`. The location reaches the map and the last-known store
   through the one existing persist site.

A copy that arrived first by relay is a `Duplicate` in the engine: correct and
silent.

### 5.3 Freshness

There is no time on the wire. Members judge staleness on the MLS-authenticated
inner timestamp, as today. The map shows a mesh-delivered location's age from
that timestamp; the 15-minute `expires_at` and the 24 h last-known retention
apply unchanged.

---

## 6. The mesh protocol

### 6.1 Radio

- One 128-bit service UUID, one characteristic (write-without-response +
  notify). The advertisement is the service UUID and nothing else: no local
  name, no service data, no manufacturer data. No pairing, no bonding.
- Every phone advertises and scans. A filtered scan only.
- Link budget: at most 4 outgoing and 4 incoming links (default), chosen by
  RSSI with hysteresis; one connection attempt at a time.
- GATT, not L2CAP: L2CAP's background behaviour on iOS is undocumented and
  1 KB packets do not need its throughput.
- A packet is sent as `ceil(1024 / (mtu − 3))` chunks behind a 1-byte link
  header inside the link frame. Reassembly is per link, one packet at a time,
  fixed 1024-byte buffer, 10 s timeout.

### 6.2 Link frames

`[type:1][body]`, types: `HELLO` (protocol version, store digest), `HAVE`
(packet ids), `WANT` (packet ids), `PKT` (chunk), `BYE`. Every body has a
fixed maximum checked before allocation. An unknown type, an oversized body or
a version mismatch closes the link.

### 6.3 Sync

- On connect both sides run a set reconciliation over packet ids, then send
  what the other lacks.
- While connected, each side sends `HAVE` for newly stored packets in batches
  at a random interval (default 5–15 s), never immediately, in packet-id
  order, never arrival order, and never back to the link a packet came from.
- Reconciliation algorithm: plain id list while a store holds ≤ 256 packets,
  range-based reconciliation above. The choice and its adversarial behaviour
  are fixed by the simulator in M1.

### 6.4 Store

- Bounded (default 2048 packets ≈ 2 MB, memory only, never written to disk).
- A packet is held for a fixed time from **first local receipt** on the
  monotonic clock (default 20 min), then dropped. Its id stays in the seen-set
  (default 24 h, capped) so it is not accepted again.
- Per-link fair quota: when full, eviction takes from the link that
  contributed most, random within it. One neighbour cannot evict the rest.
- Own packets and carried packets are the same rows.

### 6.5 Limits (DoS)

- Per-link token bucket on newly accepted packets, sized from the emission
  rate times a density factor.
- Global ingest ceiling; over it, links are served round-robin.
- A link that sends malformed frames, exceeds its bucket repeatedly or stalls
  a reassembly is closed and its address is ignored for a backoff period held
  in memory under a `log_alias` handle only.
- No proof of work: affordable for a phone means trivial for an attacker.
- What is not prevented: an attacker with `k` radios takes about
  `k / (k + honest)` of a store. The simulator characterises the worst case
  (T-SEC-SYBIL); the plan does not call it bounded without that number.

### 6.6 Scale, honestly

Each phone emits one packet per 90 s. In a connected cluster of `n` phones a
store sees `n / 90` new packets per second and holds `n × 1200 / 90 ≈ 13 n`
packets at a 20-minute hold. A 2048-packet store is lossless to about 150
phones; beyond that the fair-quota eviction shortens effective hold time and
far-away updates are lost first. The simulator measures delivery ratio against
`n`, and the hold time, store size and slot period are fixed from it. If the
owner wants festival scale (thousands), dummies (D-2) are the first cost to
revisit.

### 6.7 Link encryption — not in v1

A per-link `Noise_NN` session would hide from a passive sniffer which packet
ids cross a link. It gives nothing against an attacker who simply connects,
which the open mesh allows by design, and it adds a dependency to audit in
three lockfiles. `HELLO` carries a version so it can be added. Owner decision
D-5 presents both views.

---

## 7. Platform work

### 7.1 Android

- **`MeshService`**: a dedicated Kotlin foreground service,
  `foregroundServiceType="connectedDevice"`, separate from the location
  service so neither can stop the other (F5). Started from the UI on enable;
  restarted at boot if mesh was on (`BOOT_COMPLETED` is permitted for this
  type [V]).
- Permissions: `BLUETOOTH_SCAN` (`neverForLocation`), `BLUETOOTH_ADVERTISE`,
  `BLUETOOTH_CONNECT`, `FOREGROUND_SERVICE_CONNECTED_DEVICE`; legacy
  `BLUETOOTH`/`BLUETOOTH_ADMIN` with `maxSdkVersion="30"`. On API 23–30 a scan
  needs location permission; mesh is offered there only when it is already
  granted.
- Scan: one `ScanFilter` on the service UUID, `SCAN_MODE_LOW_POWER`. Advertise:
  `ADVERTISE_MODE_LOW_POWER`, connectable, UUID only. `requestMtu(517)`.
  GATT operations serialised through one queue.
- **Notification (F2)**: own channel, low importance, localized, no
  identifier or count in its text. On Android 14+ the user can swipe it away;
  a `deleteIntent` re-posts it while mesh is on (behaviour to be confirmed in
  the emulator lane, T-NOTIF-2). With `POST_NOTIFICATIONS` denied the service
  still runs; the enable flow asks for the permission and the map button
  remains the indicator.
- Play: the `connectedDevice` declaration is subject to review and Google's
  listed examples are accessories, not phone-to-phone [V2]. Gate G-4.

### 7.2 iOS

- **`HavenMeshRadio`** (Swift): one `CBCentralManager` and one
  `CBPeripheralManager`, both with restore identifiers persisted by the app
  (scene-based apps get nil `launchOptions` [V]). `UIBackgroundModes` gains
  `bluetooth-central` and `bluetooth-peripheral`;
  `NSBluetoothAlwaysUsageDescription` is added and registered in the privacy
  manifest.
- What works with the screen locked [V/V2]:
  - links established before locking stay up and keep syncing;
  - a locked iPhone, as central, discovers an **Android** phone (normal
    advertisement), slowly;
  - pending `connect()` calls to recently seen peers complete when the peer
    returns and relaunch the app (bitchat's technique);
  - while Haven's background location session runs, the process is not
    suspended, so the engine's timers and the store stay live.
- What does not work reliably: two locked iPhones that have never met
  discovering each other; an Android phone discovering a locked iPhone.
- Mitigations in scope: keep links up across lock; arm pending connects to up
  to 16 recently seen peers on backgrounding; restore both managers on
  relaunch and resume within the ~10 s wake budget; when a locked iPhone has
  had no link for a set time, a local notification says mesh is waiting and
  opening Haven reconnects it.
- Out of scope for v1: decoding Apple's overflow bitmask from Android. It is
  undocumented, collision-prone and has changed across iOS releases [V2].
- **Indicator (F2)**: iOS cannot pin a notification. Mesh on starts a Live
  Activity (iOS 16.1+) — Lock Screen and Dynamic Island — and schedules a
  local notification for when the system ends it at 8 h, saying mesh is still
  on. On iOS 15.5–16.0, and when Live Activities are disabled, a local
  notification is posted at enable and at each return to background. Owner
  decision D-3 offers an auto-off timer as the stronger answer to "do not
  forget it on".
- App Review: two more background modes under guideline 2.5.4. Gate G-4.

### 7.3 Power (F3)

- Advertise at the lowest platform rate; scan filtered at the lowest duty; cap
  links; batch sync so the radio idles between batches; no wake lock held by
  the mesh — the foreground service and the BLE controller's own filtering
  keep it alive.
- Adaptive: with zero links the engine does nothing but advertise and scan;
  with the battery saver on, link budget halves and batch intervals double.
  Emission slots are never skipped (that would be a signal).
- Every figure enters `docs/POWER_EFFICIENCY_PLAN.md` model E as new inputs
  with cited sources and the ESTIMATED tag; nothing is written into
  `docs/POWER_MEASUREMENT.md`. `check_estimate_integrity.sh` covers the new
  code and copy.
- CI proves the mechanisms, not the milliamps: scan mode, advertise mode, link
  cap, batch cadence and "no traffic with no peers" are asserted on the
  emulator and in the simulator (T-PWR-*).

### 7.4 Enable flow

Tap → first time: a disclosure sheet (what is shared, that phones nearby can
detect that Haven mesh is on and locate the phone by radio, battery note,
iOS background limits) → OS permission prompts → radio starts → notification /
Live Activity appears → button shows the on state. Bluetooth off or permission
refused leaves mesh off with fixed copy (Rule 8). The setting persists; it is
cleared on identity delete (`check_identity_delete_prefs_residue.sh`).

### 7.5 Button and statistics (F4)

- `MeshButton` in `MapShell.buildLayers`, `PositionedDirectional(start: 16,
  bottom: 12 % + 16)`, mirroring `MapControls`; 48 dp; tooltip; state shown by
  icon shape and label, not colour alone; a peer-link dot when at least one
  link is up (no count on the map).
- Tap toggles. Long-press opens the statistics sheet, with haptic; a
  `CustomSemanticsAction` "Show mesh statistics" makes it reachable by
  VoiceOver and TalkBack, as `circle_member_tile.dart` does.
- The sheet is one 2 × 2 table:

  |  | This session | All time |
  |---|---|---|
  | From your circles | n | n |
  | Carried for others | n | n |

  plus one status line (on/off, linked or searching) and a reset action.
- **From your circles** = unique packets that opened under one of this
  phone's circle keys and verified. **Carried for others** = unique packets
  this phone did not originate and could not open, counted when first handed
  to another phone. The second number includes cover packets and anything
  else unreadable; the copy says "encrypted updates carried", and the
  disclosure says the phone cannot know what they are.
- Session counters live in the engine. Lifetime counters are two integers in
  the SQLCipher `user_settings` table, folded in by the session owner at each
  drive and at mesh off; no timestamps, no per-circle or per-peer breakdown.
  Exact counts are shown in the UI and never logged (buckets only, Rule 15).
- 13 locales, each translated and independently reviewed per the l10n rules.

---

## 8. Security and privacy

### 8.1 Threat model

| Adversary | Learns | Cannot learn | Residual |
|---|---|---|---|
| Passive sniffer | A phone runs Haven mesh; link timing and volume; which opaque packets cross links it can follow | Circle, sender, content, age, hop count, real vs dummy | Presence, crowd counting, radio direction-finding |
| Mesh participant, not a member | Packet ids; neighbours' store contents; first-seen times | Same as above | With many nodes, first-seen timing points at an originating **device** |
| Malicious circle member | What the circle already shares; which packets are the circle's | Other circles | Can flood future-epoch messages toward the engine buffer (Rule 12 caveat) |
| Removed member | Packets sealed at epochs they held | Later epochs | An outage freezes epochs, so the window lasts as long as the outage |
| Device seizure | Lifetime counters; that mesh was used | Carried packets (memory only) | Member's own key ring is in memory only while running |
| Flooder / Sybil | — | — | Store share ≈ k/(k+honest); battery drain bounded by link caps and buckets |

### 8.2 Rules

- **New Security Rule 17 (Mesh)** for `CLAUDE.md` and `SECURITY.md`, in the
  same commit as the first code: no cleartext field on air; only sealed
  locations enter the outbox; forwarding never depends on recognition; the
  mesh never seals, never bridges a carried packet to a relay, never holds an
  MLS session; packets and the store are memory only; the advertisement is the
  UUID alone; no pairing.
- Rule 4, 11, 13, 14 unchanged (§4, §5). Rule 16 gains the mesh ingress:
  `Event::verify()` before ingest, pinned by a forged-packet test.
- Rule 15: new `log_alias` class for a mesh link; BLE addresses, peripheral
  identifiers, packet ids, RSSI per peer and exact counts never reach a log.
  Every native log line is allowlisted; every new type has a redacting `Debug`
  with its proof; a planted-identifier test covers every new line; logscan
  policy gains the new emitters.
- The privacy manifest gains an invariant per promise in this section and the
  new usage string.
- Rule 10: this feature adds exposure (radio presence; ciphertext held by
  strangers for up to the hold time). It is owner-directed by this request;
  the plan records it as such rather than treating it as neutral.

### 8.3 Reviews

security-reviewer on the key derivation, the envelope, the C ABI and the
ingest seam; marmot-expert on the one-seal-two-carriers claim and epoch
handling; dependency-auditor on any new crate (target: none — `hkdf`,
`chacha20poly1305`, `sha2` are already in the lockfiles; making
`chacha20poly1305` direct again needs the supply-chain guards updated).

---

## 9. Testing (N1)

### 9.1 Layers

| Layer | What runs | Where | Gating |
|---|---|---|---|
| L1 unit + proptest | codec, AEAD, key ring, store, quota, bucket, link frames, reassembly | `haven-core`, `rust-check` + coverage | yes |
| L2 `mesh_sim` | N real mesh engines on a virtual radio with a logical clock: topology, loss, partition, churn, adversary nodes | `haven-core/tests/mesh_sim.rs` | yes |
| L3 soak | real MLS engines + in-process relays + the mesh plane under the fault layer, incl. an "internet down" fault | `tooling/soak`, new scenarios | yes (PR profile) |
| L4 Android radio E2E | two emulators on one netsim medium, real Kotlin stack, real UI on one, plus a Bumble scripted adversary | new `e2e-mesh-android.yml` | yes, after G-1 |
| L5 iOS E2E | simulator, real UI + Rust engine + Swift module behind a debug-only loopback radio | new `e2e-mesh-ios.yml` | yes |
| L6 guards | repo guards, logscan over every sink, privacy manifest | `repo-guards.yml` | yes |
| L7 physical | iOS locked/background matrix, cross-platform radio | `docs/MESH_DEVICE_MATRIX.md` | DEFERRED, residual stated |

No sleeps: L1–L3 run on injected clocks; L4–L5 wait on events with budgets
declared in `e2e_lane_budget.manifest`.

### 9.2 What L4 proves that nothing else can

Advertise/scan/connect on Android's real stack; the foreground service and its
notification; behaviour with the emulator screen off (the AOSP screen-off scan
path is framework code); survival of process death and reboot; the stats sheet
against real traffic; relay publishing unaffected while the emulator's network
is cut and Bluetooth stays up; a hostile peer written in Bumble sending
malformed, oversized, flooding and stalling frames.

### 9.3 Promise → test (each fails when the promise breaks)

- **T-PRIV-1** every byte sent on a virtual or netsim link is recorded; no
  planted `nostr_group_id`, MLS group id, pubkey, event id or coordinate
  appears; every packet is exactly 1024 bytes.
- **T-PRIV-2** two packets of one circle share no field: a distinguisher
  given the key-less view does no better than chance over 10⁵ packets.
- **T-PRIV-3** forwarding is identical for member and non-member: same
  schedule, same order, same bytes, under a logical clock.
- **T-PRIV-4** a node's emissions are identical in count and timing with 0, 1
  and 10 sharing circles.
- **T-PRIV-5** the advertisement and GATT table hold only the UUID
  (netsim capture; Bumble as observer).
- **T-PRIV-6** no time, hop or version field: flipping any wire bit makes the
  packet unopenable and changes nothing in how it is forwarded.
- **T-SEC-1** a packet whose rebuilt event fails `verify()` never reaches
  ingest. **T-SEC-2** only `LocationSeal::Sealed` can enter the outbox (a
  commit, a Welcome, a photo are refused). **T-SEC-3** malformed, oversized,
  truncated and stalled frames close the link and allocate nothing unbounded
  (proptest + Bumble). **T-SEC-4** one flooding neighbour cannot evict other
  links' packets. **T-SEC-SYBIL** worst-case store share is measured and
  recorded. **T-SEC-5** future-epoch packets pass the intake cap, never
  around it. **T-SEC-6** key ring pruned in step with retention; zeroized on
  mesh off.
- **T-INDEP-1** the relay journal of a soak run is byte-identical with mesh on
  and off under the same seed. **T-INDEP-2** a stalled, panicking or full mesh
  engine does not delay or fail a relay publish. **T-INDEP-3** with relays
  unreachable, locations still arrive by mesh; when relays return, nothing is
  duplicated on the map.
- **T-DELIV-1..n** line, star, cluster, partition-and-merge, carrier walking
  between islands: delivery within the hold time; loss bounds under stated
  loss rates.
- **T-STAT-1** both counters equal the simulator's ground truth; duplicates
  and own packets are not counted. **T-STAT-2** lifetime survives restart and
  resets on identity delete. **T-STAT-3** the sheet is reachable and read
  correctly by the semantics tree; long-press and the semantics action open
  the same sheet.
- **T-NOTIF-1** mesh on ⇒ notification present; off ⇒ absent (Android
  emulator; iOS simulator for the Live Activity / local notification).
  **T-NOTIF-2** dismissal re-posts while on.
- **T-BG-1** Android: screen off for a declared interval, packets still flow;
  process killed, service returns; reboot with mesh on, mesh resumes.
- **T-PWR-1..3** scan and advertise modes, link cap, batch cadence, silence
  with no peers.
- **T-LOG-1** planted identifiers absent from every sink in every lane.

---

## 10. Milestones

Each lands complete with its tests; none leaves a stub.

| M | Scope | Exit |
|---|---|---|
| M0 | Spikes, throwaway code not merged: (a) two emulators + Bumble on netsim on a hosted Ubuntu runner; (b) measured kind-445 location size; (c) seal behaviour with no relay reachable; (d) Android `deleteIntent` re-post | Gates G-1..G-3 answered in this document |
| M1 | `mesh::` codec, envelope, key ring, store, limits, sync + `mesh_sim`; parameters fixed from the simulator | L1, L2 green; T-PRIV-1..4,6, T-SEC-3,4,SYBIL, T-DELIV |
| M2 | Seal hand-off, key push, inbox drain, counters; soak scenarios; Rule 17 + docs | L3 green; T-INDEP, T-SEC-1,2,5,6, T-STAT-1 |
| M3 | Android: `MeshService`, radio, C ABI, notification, permissions; L4 lane | T-BG-1, T-NOTIF, T-PRIV-5, T-PWR, Bumble adversary |
| M4 | UI: button, disclosure, stats sheet, 13 locales, a11y | T-STAT-2,3; ui-ux review |
| M5 | iOS: `HavenMeshRadio`, restoration, pending connects, Live Activity; L5 lane | L5 green; device matrix written, marked DEFERRED |
| M6 | Hardening, power model entries, privacy manifest, store declarations | All gates closed or owner-accepted |

M1 and M2 need no hardware and carry most of the risk; they go first.

---

## 11. Gates and owner decisions

### Gates (a "no" changes the plan)

- **G-1** netsim with two emulators and Bumble runs reliably on a hosted
  runner [U]. If not: L4 becomes one emulator + Bumble peers on one netsim; if
  that also fails, a self-hosted runner or the loopback radio, and the
  Android radio joins L7.
- **G-2** a sealed location fits 881 B of content [U, estimated].
- **G-3** Haven still seals a location when no relay is reachable, at a
  cadence the mesh can use [U]. If sealing backs off offline, the plan adds an
  owner decision on sealing for mesh alone.
- **G-4** Google Play accepts `connectedDevice` for phone-to-phone mesh; App
  Review accepts the two Bluetooth background modes [U].
- **G-5** behaviour past 1000 unreceived messages from one sender in a frozen
  epoch (OpenMLS forward-distance limit) [U]; about 20 h at the fastest
  cadence.

### Owner decisions

- **D-1 Packet lifetime.** No time on the wire with a 20-minute per-phone hold
  (recommended; a packet's life is bounded per phone, not globally) — or a
  coarse age bucket inside the authenticated data (hard global bound; leaks
  age and so distance).
- **D-2 Cover traffic.** Fixed-rate emission with dummies (recommended; hides
  whether and how much a phone shares; costs capacity and slows multi-circle
  users) — or emit only real updates (more capacity; a neighbour can count a
  phone's packets).
- **D-3 Auto-off.** None (as requested) — or a timer (e.g. 12 h) with a
  reminder, which is the only real answer to "forgot it on" on iOS.
- **D-4 Lifetime counters.** Persisted in the encrypted store (recommended;
  reveals on seizure that mesh was used) — or session-only.
- **D-5 Link encryption.** Leave out of v1 (recommended: an attacker can
  simply connect) — or add `Noise_NN` now (hides packet movement from a
  purely passive sniffer; new dependency).
- **D-6 iOS residual.** Accept §0.4 item 1 with the mitigations in §7.2, with
  physical verification deferred until devices exist.
- **D-7 Internet bridging.** Never in v1 (recommended): a phone with internet
  does not publish what it carries.

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
  `transports/nostr.md`.
- Apple: Core Bluetooth Background Processing guide; TN3115; ActivityKit
  "Displaying live data with Live Activities".
- Android: foreground service types and timeouts; Bluetooth permissions;
  Android 14 behaviour changes; `packages/modules/Bluetooth` scan constants
  (LineageOS mirror, Android 16 base).
- google/bumble Android platform and netsim transport docs.
