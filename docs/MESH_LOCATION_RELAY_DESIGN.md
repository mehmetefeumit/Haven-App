# Haven Offline Bluetooth-Mesh Location Relay — Research & Design Document

> Status: **RESEARCH / DESIGN ONLY — no implementation.** Audience: Haven's owner (security-conscious engineer) deciding whether and how to build this.
> Scope: relay Haven's existing E2E-encrypted location updates device-to-device over Bluetooth Low Energy (BLE) when the internet is unavailable, concurrently with the Nostr transport.
> Two dedicated web-research streams were conducted and are incorporated: a **BLE technology-landscape** review (candidate transports, iOS/Android background constraints, plugin reality) and a **prior-mesh-app security-lessons** review (Bridgefy ×2, FireChat, Briar, Berty, Meshtastic, goTenna, bitchat, plus the BLE-tracking / dedup-poisoning / RF-localization attack literature). Sections 4, 5, and 10 are grounded in those findings; primary sources are listed in §15. The remaining open items are **platform behaviors to confirm on real hardware** (iOS background overflow-area, Android `connectedDevice` FGS longevity, peripheral-plugin dual-role), not absent research.
> **Adversarial-review pass applied.** Four expert critiques (Marmot/MLS protocol, security/privacy, Flutter/platform feasibility, Rust/reliability/testability) were folded in. Several premises in the original draft were *wrong* and are corrected here — most importantly: (1) the mesh payload is **not** the unmodified kind-445 event; the producer must strip it to the inner MLS ciphertext or it leaks `nostr_group_id` on the wire; (2) the decrypt-after-buffering window is governed by the **OpenMLS secret tree**, not the exporter-secret window, and is **unproven** — assume past-epoch buffered beacons may be `Unprocessable` until measured; (3) `flutter_blue_plus` is **central-only** and cannot host the GATT peripheral the relay needs; (4) Dart `_seenEventIds` is a **post-decrypt-success** marker, not a free cross-transport ingress gate. Where the critics exposed genuine uncertainty, this document now states it honestly rather than papering over it.

---

## 1. Executive Summary

**Scenario.** A crowd of Haven users is at a protest (or festival, disaster zone, dead-cell-coverage venue). The internet is down — cell network saturated, throttled, or shut off by the state. Haven's normal path (encrypt → publish kind-445 to Nostr relays over WSS) cannot reach anyone. But the people who matter are *physically nearby*. The proposal: when proximate Haven users opt in, their phones form an ad-hoc Bluetooth mesh that **floods the same end-to-end-encrypted location ciphertext** device-to-device, so circle members can still see each other on the map with no infrastructure. Relays (the in-between phones) **cannot decrypt or forge** anything — they shuttle opaque sealed envelopes.

**Goal.** Add a *second, concurrent, best-effort* transport for the same encrypted location payload the kind-445 event already carries. Change the **carrier**, never the **security envelope**. Location-only (no photos), opt-in, default-OFF, with a map-top-right toggle that glows blue when active and surfaces live stats (connected peers, updates relayed).

**Headline recommendation.** **Conditional GO — build the hardware-free pure-logic core and simulator first (Phases 0–2); make the iOS-background-BLE, the plugin/peripheral-role, and the protest-de-anonymization decisions explicitly before committing to public-facing release (Phases 4–5).** Two of those gates (peripheral-role plugin support; the inner-MLS-decryptability window) can *invalidate the architecture as drawn* and are therefore promoted into the Go/No-Go gate, not buried in later sections.

- **Approach:** Port bitchat's proven *managed-flooding* design — TTL-bounded, content-hash seen-cache dedup, jittered "delay + cancel-on-duplicate" rebroadcast, deterministic fanout subset — but carry a **dedicated, tiny, location-only mesh frame** whose payload is the **inner MLS ciphertext only** (NOT the raw Nostr kind-445 event, which would leak the `nostr_group_id` `h` tag in cleartext — see §6.1). Put **all routing/dedup/flood logic in `haven-core` (Rust) as pure functions** that touch no crypto state; keep the MLS decrypt on a separate FFI path; keep Dart as a thin BLE shell. The encrypted *content* is the unmodified MLS ciphertext — **no new cryptography**.
- **Key risks (in priority order):**
  1. **Physical localization (T-C, R-2):** every relaying phone is an RF beacon; direction-finding can locate a specific protester to within meters *despite* perfect content encryption. With a receiver array the adversary can additionally **count** the Haven crowd, **track** a device across MAC rotations via the protocol fingerprint, and **correlate origination timing**. Largely irreducible for any RF mesh; must be disclosed as a *physical* risk in those concrete terms.
  2. **Architecture-invalidating buildability gates (Open Q, promoted):** (a) `flutter_blue_plus` is **central-only** — a peripheral-capable plugin (`bluetooth_low_energy`) or native binding is required, and its dual-role GATT-server capability on *both* OSes is unproven (§4, §12.1); (b) the inner-MLS-message decryptability window across buffered epochs is **not the 5-epoch exporter window** and is unmeasured (§6.4).
  3. **iOS background BLE viability (Open Q):** Apple truncates/rewrites backgrounded advertising and substitutes the app service UUID with the device UUID; un-pre-connected backgrounded devices cannot scan for or be discovered by new peers. iOS v1 is therefore **foreground-or-pre-connected-only** (§4.3) and may face App Store review scrutiny for dual background modes.
  4. **Self-inflicted co-membership oracle (new CRITICAL, T-L):** membership-conditioned relaying lets an active adversary probe which nearby phones hold which circle key. v1 **must** forward-all-opaque (§6.6, §10.1).
  5. **Photo/location indistinguishability (T-K):** the planned profile-pictures feature makes photo and location kind-445 events byte-indistinguishable, so the mesh **cannot** classify them — but the robust defense is the **producer-side allowlist invariant**, not relay-side classification (§9.2).
- **Go/No-Go gate:** GO to build the *testable routing core* now (zero hardware, high value, reusable, provably crypto-free). Gate the *shipped, on-by-anyone* feature behind (a) a P2 spike proving peripheral GATT-server advertising works in the pinned plugin on both OSes, (b) an empirical measurement of the inner-MLS buffered-decrypt window against MDK, (c) a satisfactory iOS-background field result, (d) the commissioned security-lessons review, and (e) explicit owner sign-off on the irreducible localization risk surfaced honestly in-app. **Never present mesh as reliable or as adding confidentiality** — Nostr stays the reliable transport; MLS provides confidentiality with or without the mesh.

---

## 2. Goals, Non-Goals & Requirements

### 2.1 Goals
- **G-A** Relay the existing E2E-encrypted location update to proximate circle members **with no internet**.
- **G-B** Run **concurrently with Nostr**: both transports active whenever both are available; mesh is the offline/degraded path, Nostr the connected path.
- **G-C** **Preserve the security envelope unchanged**: members-only decryption, relays cannot read/forge, no new crypto, no secret ever leaves the device.
- **G-D** **Opt-in, default-OFF**, one-tap kill-switch, honest disclosure (including physical-localization risk).
- **G-E** Map UI: a toggle at the top-right next to settings that **glows blue when on**, a **relayed-updates counter**, and **live stats** (connected peers etc.) on a smooth surface.
- **G-F** **Testable in CI without hardware** for all routing/dedup/flood logic (pure Rust + an in-memory multi-node simulator). *Routing correctness only — throughput/battery/latency are hardware-lab deliverables (§12.3, §12.5).*

### 2.2 Non-Goals (v1)
- **N-A Photos / avatars / any media over the mesh.** Location-only. Photos are bandwidth-prohibitive (~32 KB chunks in bursts vs ~1 KB/location) and structurally excluded (Section 9).
- **N-B Chat / arbitrary messaging.** Only the location beacon.
- **N-C Directed/unicast routing & source routing.** Location is inherently broadcast (every member is a recipient); bitchat's v2 `HAS_ROUTE` source-routing adds a topology subsystem with no payoff for an all-broadcast workload. Managed flooding only.
- **N-D Reliability guarantees.** Mesh is **best-effort**; Nostr remains the reliable transport for safety-critical info.
- **N-E The mesh adding confidentiality.** Confidentiality is MLS's job and exists with or without the mesh. The mesh can only *delay delivery of ciphertext a recipient was already entitled to decrypt*; it adds and removes no MLS membership semantics.
- **N-F Internet bridging by default.** Opt-in altruistic bridge only, gated on the **originator's** consent (Section 7).
- **N-G Background relaying on iOS as a guaranteed capability.** v1 iOS relaying is **foreground-or-pre-connected-only** until P5 confirms otherwise (§4.3).
- **N-H Membership-conditioned relaying.** v1 is **forward-all-opaque**; a node never reveals which circles it belongs to by its forwarding behavior (§6.6, T-L).

### 2.3 Requirements
| # | Requirement | Type |
|---|---|---|
| R-1 | Mesh carries only opaque encrypted location; relays never decrypt/forge | MUST |
| R-2 | Concurrent with Nostr; unified cross-transport **display-dedup** on the content id, distinct from forward-dedup (§7.1) | MUST |
| R-3 | Opt-in, default-OFF, instant kill-switch | MUST |
| R-4 | No cleartext `nostr_group_id`, no stable node id, no Nostr-linkable field on the BLE wire — achieved by stripping the outer event to the inner MLS ciphertext (§6.1). The content-derived `mesh_msg_id` is an unavoidable in-flight linker and is excepted (§10.1 T-B). | MUST (with stated exception) |
| R-5 | All **routing/dedup/flood/fragment** logic is pure Rust, CI-testable without a radio **and without MDK/crypto state** (decrypt lives on a separate FFI path) | MUST |
| R-6 | Photos structurally cannot enter the mesh (producer-side allowlist invariant + format gate) | MUST |
| R-7 | Map toggle (blue glow on), relayed counter, live peer stats | MUST |
| R-8 | Honest disclosure incl. physical-localization, crowd-counting, and inter-rotation-tracking risk | MUST |
| R-9 | Never cache or forward exporter or message-tree secrets; buffer lifetime ≤ frame TTL | MUST |
| R-10 | Graceful degradation; never show raw errors (Security Rule #8) | MUST |
| R-11 | Forward-all-opaque relaying; relay scheduling identical regardless of decrypt outcome (no co-membership oracle, §6.6, T-L) | MUST |

---

## 3. How bitchat Implements BLE Mesh

bitchat is the closest production reference (Swift/iOS-centric). Its protocol and — crucially — its **testability decomposition** are the primary borrow. Scope here is BLE-mesh only (its Nostr/geohash transport is excluded). Note that bitchat carries its *own* Noise-encrypted payloads; Haven instead carries MLS ciphertext and **adds no second crypto layer** (§3.6).

### 3.1 Protocol stack & packet format
Four layers: Application (`BitchatMessage`/acks) → Session (`BitchatPacket`: TTL routing, typing, fragmentation, padding) → Encryption (**Noise `Noise_XX_25519_ChaChaPoly_SHA256`**) → Transport (BLE). The relay implication: directed `BitchatPacket`s are the *plaintext payload of a Noise transport message*, so relays forward opaque ciphertext and read only outer routing fields.

**Wire packet** (two versions coexist; v2 is authoritative):
- **v1:** 14-byte fixed header (Version, Type, TTL, Timestamp(8), Flags, PayloadLength(`UInt16`)), then SenderID(8), optional RecipientID(8, broadcast = `0xFF…FF`), Payload, optional Signature(64, Ed25519). *(The whitepaper's "13 bytes" is a rounding error; 14 is the spec.)*
- **v2:** 16-byte header; PayloadLength widened to `UInt32`; new **Source Route** block after RecipientID iff `HAS_ROUTE (0x08)` & version ≥ 2.
- **Flags:** `HAS_RECIPIENT`, `HAS_SIGNATURE`, `IS_COMPRESSED`, `HAS_ROUTE (0x08)`, `IS_RSR (0x10)`.
- **Padding:** all packets padded to **256/512/1024/2048** bytes (PKCS#7-style) to defeat length analysis.

### 3.2 TTL / hop-limit
8-bit TTL set by originator, decremented per hop, dropped at TTL ≤ 0. **Encrypted traffic is deliberately capped at 2 hops** ("limiting metadata spread and path-reconstruction risk") — far below the 255 the field allows. Per-hop random jitter smooths floods and reduces timing correlation. Haven's choice to raise this to 4–5 is a deliberate **reach-over-privacy tradeoff** that is re-justified — not dismissed — in §11.2 and surfaced as an owner decision in §14.

### 3.3 Bloom-gossip dedup
`OptimizedBloomFilter` over recently-seen **packet IDs**: query → if "probably seen", discard (loop suppression); Bloom has false positives (rare, recovered by gossip redundancy) but **no false negatives**. On a new packet: add id → decrement TTL → if TTL > 0, re-broadcast to all peers **except the ingress peer** (split-horizon). Hot-path now lives in isolated pure components (`BLEIngressLinkRegistry` for dedup/last-hop, `BLEFanoutSelector` for broadcast subsetting).

### 3.4 Fragmentation / store-and-forward / source routing
- **Fragmentation:** `fragmentStart`/`Continue`/`End` driven by BLE MTU; reassembled in order; bitchat uses **write-with-response for reliability**. Haven does **not** adopt write-with-response (location is fire-and-forget); the resulting fragment-loss policy is specified explicitly in §11.3 (lose one fragment → drop the whole beacon, rely on next cadence) so it is not left undefined.
- **Store-and-forward / sync:** `DeliveryAck`/`ReadReceipt` + `MessageRetryService`; `RequestSyncManager` reconciles missed messages via **unicast** `REQUEST_SYNC` per peer, with a **±2-min timestamp gate** on normal packets and an `IS_RSR`+`ttl=0` exemption only for solicited responses within a 30 s window (anti-flood). Messages are **ephemeral in-memory only**; panic/triple-tap wipes keys/sessions/state.
- **Source routing (v2):** explicit `[Count][N×8-byte PeerID]` path of intermediate hops only; topology via bidirectionally-confirmed neighbor claims (A claims B *and* B claims A) piggybacked on announces; Ed25519 sig covers the whole packet with **TTL zeroed for signing** so relays' TTL decrement doesn't break it.

### 3.5 Implementation / testability decomposition
The keystone borrow. A 3500-line `BLEService` was split into **~40 tiny pure structs/enums**, each `(data, now, injected-closures) → enum/value`, touching no hardware or queues:
- `RelayController.decide(...) → {shouldRelay, newTTL, delayMs}` — relay-vs-drop, TTL cap, degree-scaled jitter.
- `BLEFanoutSelector` — deterministic SHA256-seeded `log2(n)+1` subset, ingress exclusion, dual-role collapse.
- `BLEConnectionScheduler<Peripheral>` — generic-over-peripheral so tests inject a `FakePeripheral`; RSSI gating, backoff.
- `BLEScanDutyPolicy`, `BLEFragmentAssemblyBuffer`, `BLEPacketFreshnessPolicy`, `LRUDeduplicationCache`, `MeshTopologyTracker`, rate limiters — all pure, table/proptest-tested.
- The impure shell keeps only CoreBluetooth delegates + queue hops; a **single serial `bleQueue` + debug-fence** replaces locks.

### 3.6 What to borrow / what not
| Borrow | Don't borrow |
|---|---|
| The **pure-logic-core / impure-shell split** (≈40 testable units) | Source routing / directed unicast (no payoff for broadcast location) |
| Managed flooding: TTL + content-hash seen-cache + **delay+cancel-on-duplicate** + deterministic fanout subset | Noise XX session layer (Haven already has MLS; **do not add a second crypto layer**) |
| Density-adaptive TTL & degree-scaled jitter; RSSI gating; duty-cycle policy; connection scheduler/backoff | bitchat's chat-tuned 2-hop cap — but adopt its *reasoning* and re-justify Haven's higher cap explicitly (§11.2) |
| Single-owner-queue (→ Rust engine owning `&mut self` on one task, no locks; FFI ownership via the opaque-wrapper `Mutex` pattern, §12.1) | `DeliveryAck`/`ReadReceipt` and write-with-response (location is fire-and-forget, last-writer-wins) |
| `RequestSyncManager` security model **if** sync is added later | bitchat's raw `BitchatPacket`/Noise wire format (Haven carries inner MLS ciphertext instead) |

---

## 4. BLE Mesh Technology Landscape & Recommended Approach

> Grounded in the conducted BLE technology-landscape research plus the bitchat implementation corpus. Confirmed findings carried below: `flutter_blue_plus` is **central-only** (peripheral role needs `bluetooth_low_energy` or native code); on Android, **advertising** is the unthrottled always-on primitive and the `connectedDevice` foreground service is exempt from Android 15's 6-hour FGS timeout; on iOS, a backgrounded peripheral's service UUID is rewritten into the **overflow area** (invisible to Android scanners) — the hardest interop wall. The peripheral-role plugin question (§4.1) remains a hard buildability gate that must be settled by an on-device spike before P2.

### 4.1 Candidate transports
| Approach | Cross-platform iOS↔Android | Relay (recv→fwd) | Background | Verdict |
|---|---|---|---|---|
| **Custom GATT flood** (1 service + 1 read/write/notify characteristic, dual central+peripheral) | **Yes**, *but requires a peripheral-capable plugin* (see below) | Native fit (this is what bitchat does) | Constrained (see §4.3); iOS foreground-or-pre-connected-only in v1 | **RECOMMENDED — contingent on the §4.1 plugin gate** |
| Connectionless advertising-only flood (data in adv/scan-response) | Yes, but tiny payload (≈28 B usable iOS / 31 B adv) | No reliable large-payload path | Worst on iOS (payload rewritten) | Backstop only; too small for ~1 KB beacon |
| Bluetooth **SIG Mesh** | Poor — iOS has no first-class SIG-Mesh stack; provisioning heavy | Yes (designed for it) | Heavy | **Reject** — provisioning model wrong for ad-hoc opt-in crowd |
| Apple **Multipeer** / Android **Nearby** | **No** — platform-siloed, won't bridge iOS↔Android | Yes within one OS | OK within one OS | **Reject** — cross-platform is a hard requirement |
| **Wi-Fi Aware (NAN)** | Improving but uneven; Android-led, iOS support nascent | Yes, higher throughput | Poor/uneven | Future option; **not v1** (verify in web research) |

**Plugin reality (corrected — this was wrong in the draft).** `flutter_blue_plus` is **central-role only**: its own pub.dev page directs peripheral-role users elsewhere ("If you need BLE Peripheral Role, check out FlutterBlePeripheral, or bluetooth_low_energy"). The relay design **requires** a hosted GATT server + advertising (the peripheral role) so neighbors can connect *to* this device. Therefore the transport layer must be built on a **peripheral-capable** plugin:
- **`bluetooth_low_energy`** (v6.x) supports **both** central and peripheral roles on Android and iOS — the leading single-plugin candidate.
- `flutter_ble_peripheral` is peripheral-only and less maintained; pairing it with `flutter_blue_plus` means two plugins contending for the same adapter (risky).

**This is a Go/No-Go item, not a detail.** Before P2 commits, a spike MUST prove the pinned plugin can simultaneously (a) advertise a custom service UUID, (b) host a GATT server with a writable + notify characteristic accepting inbound central connections, and (c) act as a central scanning/connecting/writing — concurrently, on **both** iOS and Android. If it cannot, the entire Layer-C architecture changes (native platform binding) or the feature is infeasible as drawn.

### 4.2 Cross-platform / range / throughput / connection limits
- **Single custom service UUID + single read/write/notify characteristic**, multiplexed by a 1-byte `type` header — exactly bitchat's model; no rich GATT profile needed.
- **Dual role on one device** (central scans/connects/writes; peripheral advertises/notifies) — the keystone of relaying. Each meeting forms links in both directions.
- **Range:** ~10–30 m/hop line-of-sight, degrading to ~10 m through bodies/walls in a crowd.
- **Throughput:** PHY is 1–2 Mbit but **effective app throughput ~5–20 KB/s/link** after connection-interval gating, OS scheduling, background throttling. These are estimates pending hardware-lab measurement (§12.5).
- **MTU:** negotiated 185–512 B (read live via `maximumWriteValueLength`/`maximumUpdateValueLength`; never assume). A ~1 KB padded beacon → **2–3 fragments**.
- **Connection limits:** cap **6 outbound central links**; peripheral side accepts inbound subscribers up to the OS ceiling; collapse dual-role duplicate links per peer.

### 4.3 Background constraints
- **iOS CoreBluetooth:** backgrounded advertising payload is **truncated and the service UUID is substituted with the device UUID** — app-defined-UUID discoverability from background is *not guaranteed*. A backgrounded device that is **not already connected** to a peer cannot reliably scan for new peers (`CBCentralManagerScanOptionAllowDuplicatesKey` is forced false in background) and cannot be discovered by new peers via the app UUID. **Consequence (now a stated v1 constraint, N-G):** iOS mesh relaying is **foreground-or-pre-connected-only**; a connection must exist *before* backgrounding to keep relaying. Requires `bluetooth-central` + `bluetooth-peripheral` `UIBackgroundModes` (App Store review scrutiny + justification). State-restoration (`…RestoreIdentifierKey`, `willRestoreState`) lets the OS relaunch into background to handle BLE events for *existing* connections. Do **not** claim or imply background relaying works on iOS until P5 confirms it with the binary acceptance criterion in §12.5.
- **Android 12+ / 14+:** the app uses `flutter_foreground_task` (`FlutterForegroundTask.startService`, `ForegroundServiceTypes.location`), not a hand-rolled manifest service. BLE-while-backgrounded requires:
  - The **runtime permissions** `BLUETOOTH_SCAN`, `BLUETOOTH_CONNECT`, and `BLUETOOTH_ADVERTISE` (API 31+), which are **not currently in the manifest** and must be added.
  - A foreground service whose declared type includes `connectedDevice`. Because BLE must run in the **foreground Dart isolate** (plugins can't register in the `flutter_foreground_task` background isolate), the cleanest path is a **dedicated Bluetooth foreground service** (or main-activity foreground-only BLE) rather than routing BLE through `BackgroundLocationManager`. If the existing FGS is reused, **both** the Dart `serviceTypes` list (`[location, connectedDevice]`) **and** the Android manifest attribute (`android:foregroundServiceType="location|connectedDevice"`) must change *together* — declaring one without the other throws `SecurityException` on Android 14. The §4.3 framing in the draft ("manifest + service-type change, not a custom platform channel") understated this; it is a permissions + isolate-placement + dual-declaration problem.

### 4.4 Flooding vs routing theory
Routing (source/topology-based) saves airtime for **directed unicast** but needs a maintained topology graph and breaks under churn. **Managed flooding** — TTL + dedup + jittered rebroadcast + fanout subsetting — is the right fit for a **broadcast** workload in a **mobile, partition-prone** crowd: it is robust to churn, needs no topology state, and degrades gracefully. The airtime cost is tamed by **delay+cancel-on-duplicate** and the **deterministic fanout subset**, the two ideas that let BLE flooding survive dense meshes.

### 4.5 Recommendation
**Custom GATT flood (1 service + 1 characteristic, dual-role), on a peripheral-capable plugin (`bluetooth_low_energy` candidate, pending the §4.1 spike), managed flooding only, carrying a dedicated location-only mesh frame whose payload is the inner MLS ciphertext.** It is the only candidate that is simultaneously cross-platform iOS↔Android, relay-capable, background-workable on Android (and foreground/pre-connected on iOS), and a proven match to bitchat's battle-tested design — while letting Haven reuse its MLS ciphertext verbatim and keep all routing logic in testable, crypto-free Rust. **The recommendation is explicitly contingent** on the P2 peripheral-GATT-server spike; if dual-role advertising fails in the pinned plugin on either OS, the architecture must change.

---

## 5. Lessons from Prior Mesh Apps

> Grounded in the conducted prior-mesh-app security-lessons research (primary sources in §15). The throughline: **every prior system failed on metadata/presence, not payload crypto.** Haven's already-correct MLS content envelope is the easy part; the entire design budget goes to wire/relay metadata and physical-presence exposure.

| App | Failure | Haven's posture |
|---|---|---|
| **FireChat** | Marketed as protester-safe but had **no E2E encryption** — messages readable/spoofable. | Opposite by construction: content is **MLS-sealed**; a relay can never read/forge. **UI must not imply the *mesh* adds confidentiality** — MLS does, with or without mesh. |
| **Bridgefy (early)** | Plaintext handshake/headers **leaked social graph + sender identity**; trivial impersonation; MITM/decryption (Martínez et al.). | No plaintext identity/group-id on the wire (G-13) — achieved by stripping to inner MLS ciphertext (§6.1); authenticity from **MLS, not a bespoke handshake**; ephemeral rotating identifiers (G-2). **Invent no custom crypto** — reuse audited MLS ciphertext as the payload; the mesh adds only framing + flooding. ⚠️ The fixed GATT/characteristic/header **protocol fingerprint** is the same class of leak that outed Bridgefy users — acknowledged as a real residual (R-5, §10.3). |
| **Bridgefy (DoS)** | Floodable; broadcast mode **amplified a single sender** across the network. | TTL/hop caps (G-4), per-link rate-limits (G-6), content-hash seen-cache (G-7), hard size cap (G-8). **Honest limit:** there is *no stable origin id* to rate-limit (origin pubkey is ephemeral per MIP-03), so amplification is bounded only by per-link admission × TTL × Sybil-radio count, not by a per-origin cap (§11.1, T-F). Validate worst-case amplification under simulated Sybil **before shipping**. |
| **Both** | **Always-on / always-discoverable** — outed users as app-users. | **Opt-in default-OFF** (G-1) + **rotating identifiers** (G-2). ⚠️ Honest caveat: open stranger-rendezvous requires a *constant, publicly-known service UUID*, so "rotating service identity" is largely **cosmetic** against an adversary who knows Haven's UUID (R-1, §10, G-3 downgraded). |
| **Both** | Implied **reliability** they couldn't deliver in adversarial RF. | Present mesh as **best-effort, complementary to Nostr** (R-4/T-H); disclose physical-localization, crowd-counting, and inter-rotation tracking (R-2/G-10) those apps hid. |

**Briar (good principles to adopt):** strong **metadata-privacy** discipline — minimize what the transport reveals, no public profiles, treat the network layer as untrusted. Haven already follows this (pubkey-only, no public profiles); the mesh must not regress it.

**Cross-cutting lesson:** *don't trust the network layer for anything the crypto layer should own.* Routing/dedup/TTL operate on outer plaintext + opaque bytes only; every confidentiality/authenticity guarantee stays in MLS. The mesh is a dumb, sealed-envelope flooder.

---

## 6. Haven Integration — The Relayable Encrypted Packet

### 6.1 What gets relayed — and the load-bearing correction

The unit of interest is the encrypted location produced by `CircleManager::encrypt_location` (verify symbol; line anchors in this section are approximate and were found to drift — re-anchor against HEAD before P0). On the Nostr wire this is a full **kind-445 `Event`**:

| Field | Value | Where it lives |
|---|---|---|
| `id` | SHA-256 of the serialized event (NIP-01) | **outer plaintext** |
| `pubkey` | **ephemeral** secp256k1, new per message, never reused (MIP-03) | **outer plaintext** (uncorrelatable) |
| `created_at` | Unix ts, **set by the ephemeral signer → attacker-malleable, NOT MLS-authenticated** | **outer plaintext** |
| `kind` | `445` | **outer plaintext** |
| `tags[h]` | `["h", nostr_group_id]` — opaque 32-byte id, **NOT** the real MLS group id, but still a **stable per-circle identifier** | **outer plaintext** |
| `tags[expiration]` | NIP-40, jittered | **outer plaintext** |
| `content` | the **outer NIP-44 v2 ciphertext string MDK produces** — NIP-44 v2 (ChaCha20 + HMAC-SHA256, *not* AEAD ChaCha20-Poly1305) under a keypair *derived from* the exporter secret (label `"nostr"`), wrapping the serialized MLS `MLSMessage` | **ciphertext** (this is the only encrypted field of the event) |
| `sig` | Schnorr over `id` by the ephemeral key | **outer plaintext** (authenticates the wrapper) |

Inside the NIP-44 layer is the serialized MLS `MLSMessage`/`PrivateMessage`, whose own payload (the inner kind-9 rumor with the sender's **real** Nostr pubkey, `[["t","location"]]`, and the `LocationMessage` JSON of `lat`/`lon`/geohash/timestamps) is AEAD-encrypted under the **MLS ciphersuite AEAD — AES-128-GCM** for Haven's `MLS_128_…_AES128GCM_…` suite (*not* ChaCha20). Privacy fields are `#[serde(skip)]`.

> **BLOCKER FIX — the draft's central premise was false.** The original draft said the mesh "reuses the same MLS-derived ciphertext" and that the frame payload *is* `encrypt_location`'s content "only the framing differs." But the `h` tag (`nostr_group_id`), ephemeral pubkey, `created_at`, `kind`, and `sig` are **outer plaintext fields of the Event, not inside any ciphertext.** If the frame payload were the kind-445 event content, the cleartext `nostr_group_id` — a **stable per-circle presence beacon** — would ride the BLE wire, directly violating R-4/G-13 and the T-D mitigation. **The producer MUST strip the outer Event down to only the inner encrypted bytes before enqueueing.** Two coherent options exist; pick one and document it (§6.6 resolves to Option B):
>
> - **Option A — carry the outer NIP-44 `content` string only** (drop `h`/pubkey/`sig`/`created_at`/`expiration`). This keeps MDK's outer authentication and the NIP-44 codec intact, but **loses the stable `event.id`** (which is computed over the whole event incl. `h`/`created_at`), so cross-transport dedup can no longer key on a shared `event.id`.
> - **Option B (RECOMMENDED) — carry the inner serialized `MLSMessage` bytes** as the opaque payload, and derive the mesh's own identifiers (`mesh_msg_id = hash(payload bytes)`, freshness from a mesh-frame field) entirely from the frame. Non-members cannot unify a mesh sighting with a Nostr `event.id`; **members re-derive the linkage only post-decrypt**, which is exactly where display-dedup belongs (§7.1).

**Net plaintext leak on the BLE wire after stripping:** the mesh frame header (`type`, `ttl`, `mesh_msg_id`), the fixed-size padded envelope length, and the ciphertext bytes. **No `h` tag, no ephemeral pubkey, no `created_at`, no Schnorr sig, no NIP-40 tag.** Everything about the actual location, identity, and *circle* is sealed or absent.

### 6.2 It is a self-contained, third-party-relayable blob — **Yes (with two honest caveats)**
- **Self-contained:** the stripped ciphertext carries everything an in-window member needs to decrypt; a mesh node treats it as an opaque byte string. No side state/relay/session needed.
- **Members-only decrypt:** key material is held only by current members; see §6.4 for the *unproven* epoch-tolerance caveat.
- **Cannot be *forged or modified*:** the inner MLS `PrivateMessage` is authenticated under group keys and bound to the sender's credential. Tamper → MLS auth fails. Forge → impossible without the member signing key + group secrets.
- **CAVEAT — *unmodified replay across space/time is fully available to a mesh relay* (T-E expanded to a distinct threat).** A relay cannot alter content, but it can **replay valid ciphertext at a chosen later time/place**. MLS auth and (under Option A) the outer Schnorr sig still verify on an *unmodified* replay. The only bounds are the **inner** `LocationMessage.timestamp`/`expires_at` (member-checked *after* decrypt) and the per-node seen-cache — and the seen-cache is *attacker-influenceable on the mesh* (a fresh node has an empty cache). A stale-but-still-decryptable location replayed into a different cluster is a real integrity-adjacent harm ("member is here" when they are not). **The only real defense is the member-side inner-timestamp check; the outer `created_at`/seen-cache do not stop a cross-cluster replay.** This is documented, not waved away as "replay-with-modification fails."
- **Unlinkable** at the BLE layer beyond the unavoidable in-flight `mesh_msg_id` linker (§10.1 T-B).

This holds because nothing in the *inner* blob depends on the carrier — moving it from WSS to BLE changes the carrier, not the envelope.

### 6.3 The store-and-forward flood design
- **Every node relays; forwarding is decoupled from decryption.** A node that receives a frame: forward-dedups (content-id, pre-decrypt) → checks freshness/eligibility on **outer plaintext + frame fields only** (never decrypts to decide whether to relay) → **schedules a relay via managed flooding** → **independently and off the relay timing path, a member may *attempt* decrypt.** Decrypt outcome MUST NOT influence relay timing, fanout, or whether the frame is forwarded (forward-all-opaque, R-11 / T-L). A non-member relays without ever decrypting; a member relays identically and *additionally* decrypts for its own display.
- **Forward-dedup seen-cache:** bounded LRU keyed on the **content hash of the immutable payload bytes**, evicted by **mesh-local receive time** + LRU (never by the attacker-malleable outer `created_at`).
- **Seen-cache poisoning / suppression resistance (web-grounded — Naor & Yogev, CRYPTO 2015; dedup-poisoning literature):** the dedup id is a **content hash over high-entropy ciphertext** (every beacon uses a fresh ephemeral key per MIP-03), so an attacker **cannot predict a future genuine beacon's id** to pre-seed caches and suppress it — the classic flood-mesh "seed-the-victim's-id-first" suppression attack is structurally infeasible here. Using an **exact bounded LRU set rather than a Bloom filter** (bitchat's choice we deliberately reject) also sidesteps the Naor–Yogev adversarial-Bloom false-positive/timing class entirely. The residual is **cache exhaustion** (flooding junk ids to evict genuine entries), bounded by per-link rate-limiting (G-6) + receive-time eviction (G-7). *Optional hardening (deferred to P5):* compute the dedup id as a **group-secret-keyed MAC over the ciphertext at the producer**, so non-members cannot even compute a genuine id; relays still compare opaque ids, preserving the crypto-free relay core. v1 keeps the plain content hash (unpredictability + rate-limits suffice) because a keyed id complicates cross-transport unification (§7.1).

### 6.4 Epoch / forward-secrecy — **the draft's reasoning was wrong; the window is unproven**

Buffering ciphertext on a relay is safe for confidentiality — **the mesh never relays or derives secrets** (T-J). But the draft's claim that a buffered beacon is "comfortably inside MDK's 5-epoch window" **conflated two different secrets** and is corrected here:

- The **exporter secret** (used to derive the *outer* NIP-44 keypair, MIP-03) is retained by MDK for `DEFAULT_EPOCH_LOOKBACK = 5` past epochs (CLAUDE.md Security Rule #5; Haven does not override it; pruning proven by `p3b_old_exporter_secrets_are_pruned`). The "~2 epoch" wording elsewhere in the MIP-03 discussion is a *stricter spec target*; **the actual configured value in code is 5** and is the figure any FS argument must rest on.
- The **inner MLS `PrivateMessage`** is decrypted with the **OpenMLS secret tree** for the message's epoch, which OpenMLS prunes **more aggressively** than the exporter window and is additionally **generation-gated for replay protection within an epoch**. A beacon buffered across even one commit may decrypt its outer NIP-44 layer yet **fail inner `process_message`** with no clean "still inside the window" guarantee. The draft's "survives one or two membership commits" was an **unproven assertion**.

> **HONEST POSITION (unresolved until measured):** *The inner-message decryptability window across buffered epochs is not the 5-epoch exporter window and is currently unknown.* Until it is measured empirically against MDK (a store-and-forward test that processes N epoch-advancing commits, then replays a buffered kind-445 and asserts decrypt success/failure per N), the design **assumes past-epoch buffered beacons may be permanently `Unprocessable`.** This is an availability degradation, not a confidentiality risk.

Two further consequences the draft missed:
- **Partition-delayed-delivery FS/availability failure.** A beacon that propagates slowly across a partitioned crowd can arrive at a member *after that member's device has advanced epochs and pruned the inner key* → permanently undecryptable (a silent drop the §11.4 latency budget ignores for multi-minute partition/merge).
- **Re-flood-on-merge extends reach beyond the relay model.** The draft's claim that capping buffer lifetime to TTL keeps the mesh "strictly inside the existing on-relay threat model" is **withdrawn.** A Nostr relay holds ciphertext as long as it chooses but delivers near-instantly; the mesh *deliberately re-floods on partition merge* (§11.6), creating a **new propagation vector** (extended effective lifetime + reach) not present in the Nostr transport, and it **exercises the 5-epoch exporter window far more often** than the near-real-time relay path (a larger device-seizure decryption surface for a seized *recipient*, though never for a relay, which holds only opaque bytes).

**What is correct:** the mesh gives **no additional confidentiality** and can only delay delivery of ciphertext a recipient was *already entitled to decrypt while in the epoch*. The draft's "a member who left loses forward access by design" was **wrong and is removed** — MLS removal is enforced by a commit; a not-yet-removed (or already-removed-but-key-retaining) member can decrypt a pre-removal ciphertext whenever it arrives, and store-and-forward *extends* that delivery window rather than closing it. The mesh adds and removes no MLS membership semantics. **Mitigations:** never cache/forward secrets (G-11); cap mesh buffer lifetime to the frame TTL (G-15), justified numerically in §11.5 against epoch cadence; treat past-epoch `Unprocessable` as accepted degradation pending measurement.

### 6.5 Dedup / freshness primitives (all on outer plaintext / frame fields, no decrypt)
- **Forward-dedup → content hash of the payload bytes** (= `mesh_msg_id`). Because each Nostr publish uses a fresh ephemeral key, two beacons with identical coordinates have **different** ids — so the seen-cache suppresses only **re-relaying the same wire bytes**, *not* semantic duplicates. A malicious member re-encrypting near-identical beacons is **not** bounded by the seen-cache; it is bounded by the per-link rate-limit and the per-origin originate floor (§11.1). This is stated as a limit, not sold as a dedup strength.
- **Stale-drop → a mesh-frame freshness field** (carried in the frame, since the outer NIP-40 tag is stripped under Option B) compared with `RECEIVER_EXPIRATION_GRACE_SECS = 60` (reusing the exact constant `decrypt_location` enforces). Note this freshness field, like all outer metadata, is **not MLS-authenticated** and is therefore a hint for *transport hygiene only*; semantic freshness is the member-only inner-timestamp check.
- **Coarse ordering → mesh-local receive time** only. The outer `created_at` is **untrusted** (attacker-malleable on an ephemeral-keyed event; setting it far in the future could pin a beacon atop any `created_at`-ordered queue) and **must never** drive ordering, eviction, or display. Semantic last-writer-wins is a **member-only** decision on the inner authenticated `LocationMessage.timestamp`/`expires_at`.

### 6.6 The frame (NOT a raw Nostr event) — and the forward-all-opaque rule
For the reasons in §6.1 and Sections 9–10, the mesh does **not** forward raw kind-445 events. It wraps the **inner MLS ciphertext** (Option B) in a dedicated frame:

```
[1-byte type][1-byte ttl][8-byte mesh_msg_id][2-byte freshness/expiry][payload = inner MLS ciphertext]
```
with `type ∈ {LocationBlob, Fragment, Announce}`. The payload reuses the same MLS-derived ciphertext (no crypto rework); only the *framing* differs. The frame has **no chunking/manifest capability** beyond MTU fragmentation of a single small blob — avatars structurally cannot inhabit it.

**Relay rule — forward-all-opaque (R-11, resolves the draft's contradiction).** The draft asserted both "allowlist-by-format, outer-plaintext only, never decrypts" *and* "eligibility by local membership match" — these are incompatible, because after stripping there is **no group identifier in the frame** for a non-member to match against, and adding one would reintroduce the T-D/T-L presence beacon G-13 forbids. **v1 resolves this to forward-all-opaque:** a node relays *every* well-formed, fresh, size-valid mesh frame regardless of whether it can decrypt it. "Local membership match" eligibility is **deleted** from the design. Members learn membership **only by attempting decrypt** (which non-members simply skip), strictly off the relay timing path. This also closes the **co-membership oracle (T-L):** because forwarding is identical for members and non-members, an adversary cannot learn who holds which circle key by watching who forwards a probe frame.

Eligibility is therefore purely **format + freshness + size**: *well-formed mesh frame, not expired, within `MAX_RELAY_BYTES` → relay; anything else → drop.* "Drop photos" is a **producer-side invariant** (§9.2), not relay-side classification.

---

## 7. Concurrency with the Nostr / Internet Transport

Both transports run **simultaneously** whenever the internet is up; mesh is the offline/degraded path, Nostr the connected one. The same encrypted location can arrive via both, so cross-transport coordination is mandatory — but the draft's "nearly free via `_seenEventIds`" claim was based on a misreading and is corrected here.

### 7.1 Two distinct dedup layers — the central correction
The draft conflated forwarding dedup with display dedup and wrongly claimed Dart's `_seenEventIds` provides a free cross-transport *ingress* gate. It does not: **`_seenEventIds` is a post-decrypt-SUCCESS marker, deliberately not a pre-decrypt ingress gate** — pre-marking would re-introduce the documented "member joins, admin can't see their location" regression (it would blacklist out-of-order application messages whose epoch-advancing commit hasn't been processed yet). The design therefore separates two layers explicitly:

- **Forward-dedup (pre-decrypt, transport-level):** the Rust `SeenCache` keyed on `mesh_msg_id`/content-hash. Decides whether to *re-broadcast* a frame. Lives entirely in the crypto-free routing core. Dropping a duplicate here is correct and has no bearing on display.
- **Display-dedup (post-decrypt-success, member-level):** the existing Dart `_seenEventIds`, unchanged in semantics. A decrypted location is applied once; a second arrival of the *same decrypted content* via the other transport is a no-op.

**Cross-transport unification.** Under Option B (§6.1), a non-member relay *cannot* unify a mesh sighting with a Nostr `event.id` (the mesh carries no `event.id`). Unification happens **for members, post-decrypt:** the decrypted inner content (sender real-pubkey + inner timestamp, or an inner content hash) is the cross-transport key. The "drop the second transport at ingress before any processing" language in the draft is **withdrawn** for the member path; the correct statement is: *forwarding is deduped pre-decrypt by `mesh_msg_id`; display is deduped post-decrypt by inner content, shared with the Nostr path.*

### 7.2 The "relayed" counter semantics
Increment **once per unique `mesh_msg_id`, at the forward-dedup gate**, when this node actually re-broadcasts a frame (or when it would have, for a member that also decrypts) — never per-transport, never per-arrival. A frame seen twice on the mesh counts once. The counter is a **transport-level** metric (frames this node relayed), independent of the member-level display path, so it does not depend on decrypt outcome and cannot leak membership. Mechanism: Dart calls the FFI per inbound frame and increments the provider from the returned decision (§8.4) — see the corrected push/poll discussion there.

### 7.3 Display authority
**Transport-agnostic.** After decrypt, members apply last-writer-wins on the inner authenticated `LocationMessage.timestamp`/`expires_at` into `LastKnownLocation`. There is no "authoritative transport," only an authoritative *inner payload timestamp*. Neither the mesh's frame fields nor the outer `created_at` ever drive display ordering.

### 7.4 Handoff when internet returns
- **No re-encryption / no re-origination** — the same inner content is already deduped at the member level, so a member won't re-publish what it already displayed.
- **Optional altruistic bridge (opt-in, originator-gated):** a node regaining internet *may* publish still-valid mesh-originated beacons it holds to relays. **This is privacy-*negative* for the originator, not privacy-neutral** (correction): the beacon would **not** have reached relays — the originator was offline by hypothesis — so bridging it reveals to the global relay set that an offline user is now present, plus the full event metadata (`event.id`, ephemeral pubkey, `h` tag) the originator may have *deliberately* kept off-grid. Therefore the bridge MUST be **off by default and gated on the *originator's* consent** (a per-share or persistent "allow bridging my offline beacons" setting), not the bridger's. Each beacon is bridged at most once (member-level dedup).
- Stop mesh-originating once Nostr publish succeeds for the current beacon; **keep mesh relaying active** (a connected node is a valuable bridge for offline neighbors).

---

## 8. UI/UX Specification

Grounded in the actual map control row. The top-right corner currently holds exactly one widget, `SettingsFloatingButton`, as a lone `Positioned` in `map_shell.dart` (symbol-anchored; line numbers drift). The invitations button mirrors it on the left; `MapControls` (zoom/recenter) sits bottom-right.

### 8.1 The mesh-toggle button
Replace the lone `SettingsFloatingButton` with a `Column(mainAxisSize: .min)` in the same `Positioned`: `SettingsFloatingButton` → 8 dp gap → **`MeshToggleButton`**. The new button replicates `SettingsFloatingButton`'s structure exactly: circular `Container`, `BoxShape.circle`, 48 dp `IconButton`, **the same `BoxShadow(black @ alpha 0.15, blur 8, offset (0,2))`** (corrected from the draft's `0.1` — the existing button uses `Colors.black.withValues(alpha: 0.15)`; matching it avoids a visible mismatch). Swap the fill:
- **OFF:** `colorScheme.surface` (matches chrome).
- **ON:** **blue accent glow** — `colorScheme.primary` (or `Colors.blue.shade700`) fill, plus a soft blue glow (a second `BoxShadow` with the accent color, larger blur) so "on" reads at a glance.
- **Glyph:** `LucideIcons.bluetooth` or `LucideIcons.radio` (closest analogues).
- **Badge:** a small numeric badge (top-left corner, white-on-`primary`, ~16 dp) showing the relayed count, styled like an iOS notification badge.

### 8.2 States
| State | Visual |
|---|---|
| **Off** | surface fill, no glow, no badge |
| **Scanning (on, 0 peers)** | blue glow, subtle pulse/indeterminate ring, peer count 0 |
| **Connected (on, ≥1 peer)** | blue glow steady, peer count badge, relayed counter |

### 8.3 Live stats surface (smooth UX)
**Recommended: Option A — tap opens a `showModalBottomSheet`** (mirrors the existing member-marker sheet on the map page). Use the **ambient (default) navigator**, *not* `useRootNavigator: true` (correction — the existing member-marker sheet does **not** pass `useRootNavigator: true`; using the ambient navigator is the correct, desired behavior so the sheet pops to the map sub-tree). Fixed height (~180 dp):
```
[bluetooth] Mesh relay            [ switch ]
────────────────────────────────────────────
Peers connected                         3
Updates relayed                        12
```
A `SwitchListTile` + two `ListTile` stat rows. The badge gives ambient feedback without expanding. (Option B — long-press `OverlayEntry` tooltip — rejected for poor discoverability.)

### 8.4 Live-stats state management (Riverpod) — corrected
- **Provider type:** use **`StateNotifierProvider<MeshStatsNotifier, MeshStats>`** to match Haven's five existing analogues (`BackgroundSharingNotifier`, `DebugLogNotifier`, `ThemeModeController`, `MapStyleController`, `OnboardingController`, `JoinWatcherNotifier`), not the newer `NotifierProvider` API the draft proposed — consistency with the codebase over modernization. `MeshStats { isEnabled, connectedPeers, relayedCount }`.
- **Lifetime:** the provider must be **non-`autoDispose`** (mirroring `backgroundServiceLifecycleProvider`'s documented non-autoDispose reasoning) **or** the always-visible `MeshToggleButton` widget must `watch` it to keep it alive. Otherwise, when the bottom sheet (the only other consumer) is dismissed, an `autoDispose` provider would tear down the timer and freeze the badge. The button watching the provider is the cleaner choice and is REQUIRED.
- **Peer count:** polled via an internal `Timer.periodic` (3 s — connections change on human timescale), started only when enabled, cancelled via `ref.onDispose`. The 3 s poll calls `mesh_poll_stats()`.
- **Relayed count (corrected — no Rust→Dart push exists):** FFI exposes **no streams** (Haven idiom: poll; `StreamSink` is a known follow-up). The Rust relay engine **cannot** push to Dart. Therefore `relayedCount` is **incremented on the Dart side from the return value of `mesh_decode_and_decide`** each time Dart feeds the engine an inbound frame and the decision is "relayed." The draft's "push-incremented from the relay-forward path" framing was misleading and is corrected: *Dart drives the increment.* For real-time feel it can still update between 3 s poll ticks (every inbound frame is a Dart call), smoothed with `TweenAnimationBuilder<int>`/`AnimatedSwitcher`. If exact real-time is later wanted, the `StreamSink` upgrade removes this Dart-driven gap.

### 8.5 Accessibility & disclosure/consent
- Semantics labels for on/off/scanning; the blue glow must not be the *only* signal (badge + label back it; meets non-color-only requirement).
- **First-enable disclosure gate** (mirrors the SEC-H2 background-disclosure pattern): a one-time consent dialog stating plainly that mesh is a **physical** risk, not just a data risk. Expanded copy (the draft's single-device wording understated the threat): *"While mesh is on, your phone transmits Bluetooth to relay encrypted locations nearby. Someone with radio equipment can physically locate your phone, and a network of receivers can estimate how many Haven users are in an area and track a phone's movement even as it changes its Bluetooth address. The content of locations stays encrypted, but the fact that you are transmitting does not."* Decline → mesh stays off.
- **Persistent activity indicator** while active (the blue button is always visible on the map; the Android foreground-service notification also signals it).
- **Kill-switch:** tapping the button off halts all scan/advertise/relay immediately.

---

## 9. Interaction with Profile Pictures (location-only mesh)

### 9.1 Why photos are excluded — bandwidth
A **location** beacon is ~150–300 B plaintext → ~600–850 B on the wire → one 1024-B padded block → 2–3 BLE fragments. A **photo** (per `docs/PROFILE_PICTURES_PLAN.md`, 512×512 WebP/JPEG) is ~30–100 KB → ~2–8 chunks of ~32 KB plaintext each, in bursts. That is **~100× the per-update bandwidth** of a location, on a transport with only ~5–20 KB/s/link. Photos over the mesh would crush airtime and battery (T-G). Hence **location-only**.

### 9.2 The hard problem — and the robust solution (rationale re-ordered)
The profile-pictures plan **deliberately** makes a photo event and a location event **byte- and cadence-indistinguishable to any non-decrypting observer** (same outer **kind 445**, same inner **kind 9**, same `["h", nostr_group_id]` tag, and a deliberately-collided avatar/location padding bucket). A BLE relay is exactly such a non-decrypting observer, so the mesh **cannot** classify a kind-445 blob as location-vs-photo by size, kind, tag, or padding bucket.

**Correction to the draft's emphasis:** the indistinguishability argument is **not** the load-bearing justification for the dedicated frame, because (a) it derives entirely from `PROFILE_PICTURES_PLAN.md` — *a plan, not shipped code* — which Haven's own memory flags as having an **unresolved padding-bucket defect**; if the avatar plan changes its bucketing, this premise evaporates; and (b) even if it holds, the **producer-side allowlist invariant does all the real work anyway.** Therefore the decision rests **solely on the producer-side invariant**, with indistinguishability demoted to a secondary "even relay-side classification can't help" note plus a **cross-check against the avatar plan's final bucketing before P0**.

Options evaluated against the live plan:
| Option | Verdict |
|---|---|
| **(a)** Hard size threshold as *sole* mechanism | **FAILS** per-event (a chunk padded to the location bucket = same size). Useful only as a defense-in-depth backstop on the *mesh* format. |
| **(b)** Route on event kind/tag | **FAILS structurally** — kinds/tags are identical; the only discriminator is *inside* the ciphertext. |
| **(c)** **Dedicated location-only mesh frame + producer-side allowlist** | **RECOMMENDED.** The robust mechanism (see below). |
| **(d)** Cleartext "mesh-eligible" flag on the shared event | **REJECT** — a "this-is-location" fingerprint that regresses indistinguishability and is forgeable/strippable. |
| **(e)** Padding-bucket signaling | **FAILS/DANGEROUS** — buckets are deliberately collided; re-separating them breaks the avatar plan. |

**The mechanism (option c — producer-side invariant first):** the mesh **never relays Nostr kind-445 events** and defines its own tiny, location-only frame (§6.6) that **avatars structurally cannot inhabit** (no chunking/manifest). The authoritative rule is a **producer-side invariant: the output of the avatar-share path is *never* enqueued to the mesh — only the location producer enqueues, and it enqueues only the stripped inner location ciphertext.** This is robust regardless of byte-layout and does not depend on the avatar plan's bucketing. Relay-eligibility is then `format + freshness + size` (§6.6). A **small per-frame size cap** (`MAX_RELAY_BYTES`, ~location-sized) is a belt-and-suspenders backstop, not the primary mechanism.

### 9.3 Cross-feature invariants to enforce
- **Independent, much smaller mesh padding bucket** (sized for tiny location), **decoupled** from the Nostr-side ~32 KB location/avatar bucket. Reusing the Nostr bucket would bloat BLE ~100× and serve no mesh-privacy purpose (the mesh carries no avatars to hide among).
- **Disjoint dedup namespace:** mesh `mesh_msg_id`s must not collide with the avatar reassembler's `(sender_pubkey, version)`/content-hash space or the per-`(circle, member)` location store. Confirm the mesh→`LastKnownLocation` write path cannot be reached by an avatar frame and vice-versa.
- **Separate FFI seams:** mesh frames must **not** route through the avatar ingest, and the inner-`type` avatar dispatcher must never see a mesh frame. The mesh has its own decoder; unknown formats are silently dropped.
- **Residual (acceptable):** the mesh frame format is itself a "this is a Haven mesh packet" signal to a *local* sniffer. Acceptable because the mesh's adversary already sees you transmitting (T-C), and this signal lives **only** on the mesh — it never weakens Nostr-side photo/location indistinguishability. ⚠️ But note the **protocol fingerprint is also a cross-MAC-rotation re-linker** (R-5, §10.3) — a stronger residual than "lives only on the mesh."

---

## 10. Privacy & Security Threat Model & Guardrails

**Framing.** The crypto envelope is unchanged: only members decrypt; relays can't read/forge/modify. What changes is **metadata exposure** and **availability** — and the vantage shifts from *logical* (a Nostr relay) to *physically localized* (a BLE observer). That shift is the root of almost every new threat. Adversary model: **nation-state crowd-sniffing at protests** — passive BLE receiver arrays, mobile direction-finding, and the ability to *be a participant* (run the app and inject frames). Crucially, the adversary can **count** the crowd, **track devices across MAC rotations** via stable wire features, and **correlate origination timing**, not merely DF a single volunteer.

> **Load-bearing decisions:**
> - **G-12:** because profile pictures make relay-side photo/location classification structurally impossible (or at best plan-dependent), **the mesh MUST NOT relay raw Nostr kind-445 events** — it carries its own location-only frame whose payload is the stripped inner MLS ciphertext (§6.1, §9). The robust guarantee is the **producer-side allowlist invariant.**
> - **R-11 / T-L:** **v1 is forward-all-opaque.** Membership-conditioned relaying is forbidden because it is a physical-presence co-membership oracle (§6.6, T-L).

### 10.1 Structured threat model
| ID | Threat | Attacker | Severity | Core mitigation |
|---|---|---|---|---|
| **T-A** | De-anonymization as "a Haven user" via the **constant, publicly-known service UUID** required for open rendezvous | Passive scanner (~10–100 m), no crypto | **CRITICAL** | **Honest:** open stranger-rendezvous requires a constant fingerprintable UUID; rotation is **cosmetic** against an adversary who knows Haven's UUID (G-3 downgraded). Real mitigations: opt-in default-OFF (G-1); minimize *other* wire features; consider connectionless/decoy hardening (G-16/17) |
| **T-B** | BLE tracking despite MAC randomization via any stable wire feature; **the content-derived `mesh_msg_id` and the fixed GATT/header shape are unavoidable cross-rotation linkers** | Passive multi-point receivers | **HIGH** | Rotate the MAC + any *rotatable* id in lockstep (G-2); **but acknowledge `mesh_msg_id` *cannot* rotate — it *is* the dedup key — and the protocol fingerprint links across rotations regardless** (R-5). Minimize, don't pretend to eliminate |
| **T-C** | Physical localization / trilateration **of any transmitter**, **crowd-size estimation**, **inter-rotation device tracking**, and **origination-timing correlation** (the ≥72 s cadence is itself a fingerprint) | Mobile DF / receiver array | **CRITICAL** | **Largely irreducible (R-2).** Reduce duty cycle (TTL/rate/cache/small frames); kill-switch (G-9); opt-in (G-1); **honest disclosure covering count+track+locate** (G-10); no TX-power boost |
| **T-D** | Traffic analysis / social-graph; presence beacons | Passive BLE observer, possibly distributed | **HIGH** | **`nostr_group_id` is stripped, never on the wire** (G-13, §6.1); forward-all-opaque so forwarding reveals no circle membership (R-11); doc in SECURITY.md (G-18) |
| **T-E** | Replay & seen-cache poisoning **(includes authentic unmodified replay across space/time)** | Active participant injecting frames | **MEDIUM (poisoning) / HIGH-adjacent (cross-cluster authentic replay)** | Dedup on **content hash** of immutable bytes (G-7); receive-time eviction; per-peer admission limits (G-6). **Authentic-replay defense is the member-side inner-timestamp check ONLY** (§6.2); outer fields do not stop it |
| **T-F** | Sybil & flooding amplification DoS | Active, multi-radio | **HIGH** | Per-link rate-limit (G-6); TTL/hop cap (G-4); seen-cache (G-7); size cap (G-8). **Honest:** *no stable origin id exists* (ephemeral per MIP-03) so a **per-origin cap is unenforceable**; worst-case amplification = links × TTL × Sybil-radios, bounded only by per-link admission + TTL + dedup (R-3) |
| **T-G** | Battery-drain DoS | Active flooder / high density | **MED–HIGH** | All T-F limits + radio duty-cycling; kill-switch (G-9); default-OFF (G-1) |
| **T-H** | Malicious relay: tamper / drop / selective-forward | Any relay | **HIGH avail. / LOW integrity** | **Tamper/forge/modify fully stopped by MLS.** **Drop/censor + authentic replay cannot be prevented** — mesh is best-effort; **Nostr is the reliable transport** (R-4) |
| **T-I** | Correlation of mesh ids with Nostr pubkey / MLS group | Observer with BLE + relay vantage | **HIGH** | `mesh_msg_id` is content-derived, never reused (fresh ephemeral key → fresh id), never derived from Nostr/MLS *keys* (Key Separation, G-14); under Option B there is **no `event.id`/`h` tag on the wire to correlate**; redact in logs |
| **T-J** | Store-and-forward × forward-secrecy | Seizes relay buffer (useless ciphertext) / compromises a recipient holding in-window keys | **LOW (relay) / MED (recipient seizure)** | Mesh **never caches/forwards secrets** (G-11); cap buffer lifetime to TTL (G-15); **re-flood-on-merge exercises the 5-epoch exporter window more often than the relay path** (§6.4) — accepted, documented |
| **T-K** | Photos must not ride the mesh; the location/photo discriminator must not leak | Relay-class observer / bandwidth DoS | **HIGH** | **Producer-side allowlist invariant** (G-12, primary); dedicated location-only frame; independent small bucket (G-5); disjoint dedup |
| **T-L** | **Co-membership oracle via membership-conditioned relaying** (probe-per-circle reveals who holds which key, with physical location) | Active participant running the app | **CRITICAL** | **Forward-all-opaque is the v1 default (R-11);** relay scheduling identical regardless of decrypt outcome; decrypt strictly off the relay timing path (§6.3, §12.1); no membership-conditioned eligibility |

### 10.2 Consolidated guardrails
| # | Guardrail | Threats | Tier |
|---|---|---|---|
| G-1 | **Opt-in, default-OFF** — never scan/advertise/relay until enabled | T-A, T-C, T-G | **MUST (v1)** |
| G-2 | **Rotate the MAC + all *rotatable* wire ids in lockstep** (address + rotatable payload ids). **Explicitly excepts** the content-derived `mesh_msg_id` and the protocol fingerprint, which cannot rotate (R-5) | T-B, T-I | **MUST (v1)**, with stated exception |
| G-3 | **Non-obvious / minimal service identity.** ⚠️ **Effectiveness downgraded:** open rendezvous forces a constant UUID; rotation is cosmetic vs an adversary who knows it | T-A | **MUST (basic minimization)**; rotation is **cosmetic, not relied upon** |
| G-4 | **Strict TTL + hop cap**; freshness gate (+60 s grace) before processing | T-E, T-F, T-G, T-J | **MUST (v1)** |
| G-5 | **Fixed-size padding buckets** for mesh frames, **independent** of the Nostr ~32 KB bucket | T-B, T-D, T-K | **MUST (v1)** |
| G-6 | **Per-peer (per-link) rate-limiting**, drop excess before flooding | T-E, T-F, T-G | **MUST (v1)** |
| G-7 | **Bounded forward-dedup seen-cache, receive-time+LRU, keyed on content hash** | T-E, T-F, T-G | **MUST (v1)** |
| G-8 | **Location-only size cap** (`MAX_RELAY_BYTES`); no chunking/manifest in the format | T-F, T-G, T-K | **MUST (v1)** |
| G-9 | **Kill-switch** — one-tap stop | T-C, T-G | **MUST (v1)** |
| G-10 | **Disclosure / ongoing consent + visible activity indicator**, covering **locate + count + inter-rotation track** | T-A, T-C, T-G | **MUST (v1)** |
| G-11 | **MLS confidentiality/authenticity preserved; relays never decrypt; no secret (exporter or message-tree) serialized** | T-H, T-J, all confidentiality | **MUST (v1)** |
| G-12 | **Producer-side allowlist invariant (primary); dedicated location-only frame; no kind-445 on mesh; no cleartext discriminator** | T-K, T-D | **MUST (v1)** |
| G-13 | **Strip the outer event to inner MLS ciphertext** — no `h` tag, no pubkey, no `sig`, no `created_at`, no Nostr-linkable field on the wire | T-A, T-D, T-I | **MUST (v1)** |
| G-14 | **Parity with Haven's privacy model** — Key Separation; extend `redact_hex_sequences` to mesh debug | T-I, T-A | **MUST (v1)** |
| G-15 | **Cap mesh buffer lifetime to frame TTL**, justified numerically vs epoch cadence (§11.5) | T-J | **MUST (v1)** |
| G-16 | Radio duty-cycling, relay coalescing | T-C, T-D, T-G | **HARDENING** |
| G-17 | Cover/decoy traffic & randomized relay delay | T-D, T-C | **HARDENING** |
| G-18 | **Add the physical-presence-correlation, crowd-counting, co-membership-oracle, and protocol-fingerprint vectors to `SECURITY.md`** | T-A, T-D, T-L (doc duty) | **MUST (v1)** |

### 10.3 Residual risks (inherent to any RF mesh)
- **R-1 Rendezvous ⇒ recognizability — and the UUID must be constant.** Open stranger-rendezvous *requires* a constant, publicly-known, fingerprintable service UUID. An adversary who knows Haven's UUID (it is in a public app) recognizes the mesh regardless of rotation. **Service-identity rotation is therefore cosmetic; T-A's "no public constant UUID" mitigation is infeasible for an open mesh.** Honestly disclosed.
- **R-2 Transmitting ⇒ locatable, countable, trackable.** A transmitter is an RF beacon; DF/trilateration locates it, a receiver array counts the crowd and tracks devices across MAC rotations via the protocol fingerprint and origination timing, regardless of encryption. **The single most important risk class to disclose.**
- **R-3 Multi-radio Sybil; no enforceable per-origin cap.** Origin identity is the ephemeral per-message pubkey (no stable handle to throttle); per-link limits bound one neighbor; many radios inject more. Goal: graceful degradation, not prevention. Worst-case amplification = links × TTL × Sybil-radios.
- **R-4 Censorship via drop/selective-forward + authentic replay.** MLS stops tamper/forge/read/modify, not silence and not unmodified replay. **Mesh is best-effort; Nostr is reliable; member-side inner-timestamp checks bound replay harm.**
- **R-5 The mesh format / GATT shape is a constant cross-rotation "Haven user" fingerprint.** The fixed header (`type`/`ttl`/`mesh_msg_id`/freshness), single custom characteristic, and GATT layout **re-link rotated MACs and confirm "Haven user," partially defeating G-2 — padding hides frame *contents*, not the *protocol signature*.** This is the same class of leak that sank Bridgefy. Not merely "lives only on the mesh." Mitigate by minimizing distinctive features and considering connectionless/decoy hardening; cannot be eliminated for an interoperable mesh.
- **R-6 Coarse plaintext metadata.** Frame existence/count/timing/TTL/size-bucket observable to anyone in range — the irreducible floor.

### 10.4 Explicit Bridgefy/FireChat avoidance
Recapped from Section 5: **content E2E-sealed (vs FireChat's none); no plaintext identity/handshake/group-id and no custom crypto, achieved by stripping to inner MLS ciphertext (vs Bridgefy's leaks/MITM); amplification bounded only by per-link+TTL+dedup, with an honest "no per-origin cap" caveat (vs Bridgefy's unbounded flood); opt-in default-OFF + rotating identifiers (vs both apps' always-on outing), with the honest caveat that the *constant service UUID and protocol fingerprint still out you as a Haven user* (the residual that sank Bridgefy); best-effort framing + expanded physical-risk disclosure (vs both apps' false reliability/silent localization).** Validate against the commissioned security-lessons review before v1.

---

## 11. Reliability & Performance Engineering

The mesh moves the stripped inner MLS ciphertext; it adds no crypto surface. All routing decision logic is pure `(data, now_ms, injected-closures) → Decision` in `haven-core`; Dart owns only the impure BLE shell; the MLS decrypt is a separate FFI path. **All throughput/capacity/latency/battery numbers below are order-of-magnitude *hypotheses to be validated by the §12.3 simulator (routing only) and the §12.5 hardware lab (timing/throughput/battery)* — they are not engineering conclusions** (§11.7 restates assumptions).

### 11.1 Propagation — managed flooding
Location is **broadcast** (every member is a recipient) → **managed flooding only**, no source routing (N-C). Controls, all ported as pure functions:
1. **Split-horizon** — never re-broadcast on the ingress link (`FanoutSelector` excludes ingress + dual-role duplicate links).
2. **Jittered, scheduled rebroadcast with cancel-on-duplicate** — *the* core anti-storm trick. Schedule the forward after random jitter; if the same id arrives again during the window (and peers > 2), **cancel**. Jitter scales with degree: **10–40 ms at degree ≤2 → 100–220 ms at degree ≥10**, so duplicate-suppression wins the race and only a sparse covering subset re-emits.
3. **Deterministic fanout subset** — forward to a `SHA256(mesh_msg_id‖linkID)`-seeded subset of size **≈ log₂(n)+1**, not all links; deterministic per id so coverage holds while airtime drops. Announces → all links.
4. **Rate limiting** — announce throttle; per-central subscription backoff (anti-enumeration); log rate limiter. **Per-origin originate floor ≥72 s is *advisory only* (R-3): there is no stable origin id to enforce it against** (ephemeral pubkey per message), so it shapes a well-behaved client's own cadence but does not bound a malicious sender — that is bounded only by per-link rate-limits + TTL + dedup.

### 11.2 TTL / hop cap — re-justified against path-reconstruction, not dismissed
**Default TTL = 4 (dense) / 5 (sparse chains).** This is *higher* than bitchat's chat-tuned 2-hop clamp, and the draft dismissed bitchat's cap too glibly. **Honest re-justification:** bitchat caps at 2 specifically to limit **path-reconstruction** — and that risk is *real here too*, because the same `mesh_msg_id` is flooded to every node, so a multi-point passive receiver array can link all sightings of an id and, using the per-hop TTL decrement, reconstruct the propagation path back toward the originator. **Raising the cap to 4–5 is a deliberate reach-over-privacy tradeoff** (a location beacon is *meant* to reach multi-hop members in a venue, and Haven strips the `h` tag so no circle id rides the wire), and it is surfaced as an **explicit owner decision (§14.1 #5)** rather than presented as obviously correct. **Density-adaptive** (`RelayController.decide`): ≥6 peers → clamp ≤4; ≤2 peers → relay at full incoming depth up to 5; medium → 4. **Never originate above 5;** decrement per hop; drop at TTL ≤ 1. Reachability is computed in §11.3 using the *actual fanout subset*, not full-fanout.

### 11.3 Throughput & capacity budget — corrected arithmetic, flagged as hypotheses
- **Packet:** inner kind-9 JSON ~180–260 B → inner MLS ciphertext + frame ~600–850 B → **pad to 1024 B block** → **2–3 fragments** at ~469 B chunk.
- **Per-link app throughput** ~5–20 KB/s (background/OS-throttled) — *hardware-lab figure, unvalidated.*
- **Reachability (corrected):** the fanout subset is `≈ log₂(n)+1 ≈ 3.6` links at n=6, **not 6**. With branching factor ~3–4 over 4 hops, reachable-before-dedup ≈ `3.6⁴ ≈ 168` (sparse-chain regime can be higher per-hop but lower branching). The draft's `6⁴ ≈ 1300` over-counted by ~8× by conflating "links available" with "links forwarded to." For a single dense crowd this still covers a typical venue cluster; the realistic bound is **low hundreds**, not ~1300.
- **Capacity — *unvalidated hypothesis, to be confirmed by the §12.3 simulator, not asserted here*:** with cadence X≈120 s jittered, ~1 KB beacon, ~5 KB/s/link, 6 links, fanout ≈ log₂(n)+1, a hand estimate suggests per-node relay load in the low single-digit KB/s at N≈50. **The "mesh-wide relay multiplier ~3–5" is itself a function of the unresolved fanout/TTL interaction and MUST be derived by the simulator, not by prose.** The comfortable-N ≤ ~50 and ceiling N ≈ 150–250 figures are **hypotheses carried into P3 for the simulator and hardware lab to confirm or refute**, not validated conclusions; the P3 DoD is corrected accordingly (§13).
- **Back-pressure (in order):** outbound buffer caps (drop oldest — a newer location supersedes); **adaptive cadence** (extend own publish interval under congestion); **tighten fanout & TTL with density**; **RSSI gating** (tighten at capacity, partitioning a huge crowd into bridged local clusters, which *lowers* per-node load).
- **Fragment-loss policy (was undefined):** under fire-and-forget (no write-with-response), **if any fragment of a multi-fragment beacon is lost, the whole beacon is dropped** (the assembler expires the partial set at 30 s) and recovery relies on the **next cadence** publish. This is an explicit accepted degradation and a simulator property (§12.3).

### 11.4 Latency & freshness
- **Per-hop** = jitter (10–220 ms) + fragment TX (~80–150 ms for 2–3 fragments) ≈ **100–350 ms**; end-to-end over 4 hops ≈ **0.4–1.4 s** typical (≤~2 s worst case) — *estimates pending hardware-lab measurement.* **Freshness is bounded by publish cadence (minutes), not mesh latency (sub-2 s).** ⚠️ **Exception:** the §6.4 partition-delayed-delivery case (a beacon crossing a multi-minute partition gap) can exceed the inner-epoch window and silently fail to decrypt — the latency budget does **not** cover that path.
- **Freshness gate (mesh-frame field, no decrypt):** the mesh-frame expiry compared with `RECEIVER_EXPIRATION_GRACE_SECS = 60`. Note the *actual* publish-TTL window comes from `compute_jittered_ttl_secs`, which returns `[interval, 2*interval]` over a publish interval jittered to `[72, 168] s`, giving an expiration horizon of **`[72, 336] s`** (corrected — the draft's `[198, 396] s` matched no constant). With the +60 s receiver grace, a beacon lives in the mesh **≤ ~6.6 min** in the worst case (336 + 60 ≈ 396 s), which is where the draft's "≤ 6.6 min" coincidentally landed despite the wrong window. Mesh-local receive time = coarse transport ordering only; semantic LWW is member-only on the inner timestamp.

### 11.5 Store-and-forward buffer
| Parameter | Default | Basis |
|---|---|---|
| Retention TTL | **align to frame expiry, hard cap ≈ 400 s** | beyond ~336+60 s the beacon is useless |
| Per-circle cap | **1–2 latest beacons** | last-writer-wins |
| Total store cap | **200–500 events (~0.2–0.5 MB)** | in-memory only, never persisted |
| Eviction | expiry-first → LRU by **receive time** → oldest | self-purging; never order by outer `created_at` |

**Numeric G-15 justification (was hand-wavy):** the publish cadence is `[72, 168] s` and the frame horizon is `[72, 336] s`. Capping buffer lifetime at ~400 s (one frame horizon + grace) means a buffered beacon spans **at most ~2–5 publish intervals**. Against epoch cadence, membership commits at a protest are bursty but each commit advances at most one epoch; a 400 s buffer therefore straddles a *small but unbounded-in-principle* number of commits. **Because the inner-message decryptability window is unproven (§6.4), the buffer cap does not *guarantee* decryptability — it only bounds the relay's exposure to the 5-epoch *exporter* window and keeps the store small.** Past-epoch `Unprocessable` is accepted (§6.4) and measured in P5.

**Never cache or forward exporter *or* message-tree secrets.** A seized *relay* buffer yields undecryptable blobs; panic-wipe clears it.

### 11.6 Topology & duty cycling
- **Dual-role on a single owner task** (no internal locks; FFI ownership via the opaque-wrapper `Mutex`, §12.1). Max **6** outbound central links; inbound subscribers up to the OS ceiling; collapse dual-role duplicates (prefer write/peripheral side).
- **Scan duty (`ScanDutyPolicy`):** continuous when ≤2 peers or traffic in last 10 s; else sparse 5 s-on/10 s-off, dense (≥6) 3 s-on/15 s-off. Advertising continuous but **minimal payload (service UUID only — no Local Name, no group id, no device id)**.
- **Connection scheduler:** dynamic RSSI gate (−90 default; relax to −100 after 30 s when isolated; tighten to −85 at capacity); **backoff differentiation** (connect *timeout* → 15 s ignore; *disconnect* → only 3 s, since a walked-away peer likely returns); global connect rate-limit; candidate priority queue.
- **Partition/merge:** beacons within TTL re-flood across a newly bridged link; forward-dedup prevents reprocessing. **⚠️ Re-flood-on-merge is a new propagation vector beyond the relay model** (§6.4) and can deliver a beacon *after* a recipient pruned its inner epoch key (§6.4 availability failure). Optional gossip sync (bitchat `RequestSyncManager` security model) is **deferred** — natural re-flood covers most merges.
- **Battery / low-power:** duty-cycle + cancel-on-duplicate is the battery story; tie scan aggressiveness to foreground; OS state-restoration; low-power mode extends publish interval, drops max links 6→3, prefers peripheral-only. *All battery claims are hardware-lab deliverables.*

### 11.7 Default-parameters table (condensed)
| Domain | Parameter | Default |
|---|---|---|
| Propagation | TTL dense/sparse; ceiling | 4 / 5; never >5 — **owner-gated tradeoff (§14.1 #5)** |
| | Rebroadcast jitter | 10–40 ms (≤2) → 100–220 ms (≥10) |
| | Fanout subset | ≈ log₂(n)+1, SHA256-seeded; announces → all |
| | Originate floor | ≥72 s **(advisory; unenforceable per-origin, R-3)** |
| Dedup | Forward-dedup key / LRU cap | `mesh_msg_id` (content hash) / ~2000 entries |
| | Display-dedup | post-decrypt inner content (Dart `_seenEventIds`, unchanged) |
| | Ingress-link registry | ~3 s lifetime |
| Freshness | Staleness gate / publish-TTL horizon | mesh-frame expiry + 60 s grace / **`[72, 336] s` (real constants)** |
| Store-fwd | Retention / per-circle / total | ≤~400 s / 1–2 / 200–500 (~0.5 MB), never persisted; evict by receive time |
| Packet | Inner / on-wire / padded / fragments | ~180–260 B / ~600–850 B / 1024 B / 2–3; **lose a fragment → drop beacon** |
| Capacity | Cadence / per-link / *hypothesized* N / ceiling | 120 s [72,168] / ~5–20 KB/s / *≤~50 (unvalidated)* / *~150–250 (unvalidated)* |
| Topology | Central links / RSSI / backoff | 6 / −90 (→−100/−85) / 15 s timeout, 3 s disconnect |
| | Scan duty / peer timeout | 5s·10s / 3s·15s, continuous if ≤2 or recent / ~8 s inactive |
| Cross-transport | Forward-dedup / counter / display | `mesh_msg_id` / once per `mesh_msg_id` relayed / post-decrypt inner-timestamp LWW |
| BLE privacy | Advertising / group id / MAC | service UUID only / **stripped, never on wire** / rotated random-resolvable (mesh_msg_id excepted) |

**Assumptions:** ~10–30 m/hop (→~10 m through bodies); ~5 KB/s/link conservative (20 KB/s foreground); single connected component for N-estimates (real crowds partition, *lowering* per-node load); v1 broadcast-only; **every capacity/latency/battery number is a design-doc hypothesis requiring simulator (routing) + on-device (timing/throughput/battery) validation — the simulator de-risks *routing correctness only*, not performance.**

---

## 12. Testability Strategy & Rust/Flutter Architecture

**Central rule:** the routing core moves only opaque ciphertext and **touches no crypto state** — never secrets, never plaintext, never the real MLS group id, never MDK. Switching carrier ≠ changing envelope. The MLS decrypt is a **separate FFI path**, so the routing proptests are honestly crypto-free.

### 12.1 Three layers
**Layer A — `haven-core` (Rust): all pure mesh ROUTING logic, hardware-free *and* crypto-free.** New `haven-core/src/mesh/`, every decision a pure `(data, now_ms, injected-closures) → enum/value` (bitchat mold; no BLE, no `tokio`, no clock calls, no MDK, no FFI types):
- `mesh/packet.rs` — frame codec: `[type][ttl][mesh_msg_id][freshness][payload]`; total `Result<_, MeshCodecError>`; payload is **opaque inner MLS ciphertext** (never parses Nostr, never decrypts).
- `mesh/relay.rs` — `RelayController::decide(ttl, degree, is_fragment, now_ms, rng_seed) → {should_relay, new_ttl, delay_ms}`; hard-drop at ttl ≤ 1; degree-adaptive cap; bounded jitter; **identical for all frames regardless of decryptability (forward-all-opaque, T-L).**
- `mesh/fanout.rs` — `FanoutSelector::select(link_ids, ingress_link, mesh_msg_id) → Vec<LinkId>`; deterministic SHA256 subset; ingress excluded.
- `mesh/seen.rs` — `SeenCache`: bounded LRU keyed on **content hash**, evicted by **injected receive-time** (never outer `created_at`).
- `mesh/eligibility.rs` — `relay_eligibility(frame, now_ms) → Forward | Drop(reason)`: **format + freshness + `MAX_RELAY_BYTES` size cap only** (where "location yes / photo no" lives); **never decrypts, never inspects membership** (forward-all-opaque).
- `mesh/freshness.rs` — reuses the exact `RECEIVER_EXPIRATION_GRACE_SECS` constant.
- `mesh/fragment.rs` — `FragmentPlanner::split` + `FragmentAssembler` (`(sender, frag_id)`-keyed, cap 128, 30 s expiry, **lose-a-fragment → whole beacon dropped**, oversize-drop).
- `mesh/dutycycle.rs`, `mesh/limiter.rs` — pure, clock-injected.
- `mesh/engine.rs` — thin orchestrator owning `&mut self` routing state (seen cache, assembler, peer registry); **single-owner, no internal locks**; **holds no secrets and never calls MDK.** A *member-only decrypt attempt is NOT performed here* — the engine emits a "decrypt candidate" the FFI hands to the separate decrypt path.

**Layer B — `rust_builder` FFI: a narrow `#[frb]` boundary**, all `Result<_, String>`, errors re-redacted (`redact_hex_sequences`), **no variant ever carries a secret or the real MLS group id**. **Split so routing is provably crypto-free (corrected):**
1. `mesh_enqueue_outgoing(stripped_inner_ciphertext) → Vec<u8>` — wrap the **already-stripped inner MLS ciphertext** into a frame (no re-encryption; the *producer* strips the event, §6.1).
2. `mesh_decode_and_decide(frame) → MeshDecideResultFfi` — **pure routing, no MDK, fully CI-testable:** decode → forward-dedup on `mesh_msg_id` → freshness/size eligibility → reassemble → returns `relay_frames` (post TTL-decrement + fanout) **and** an optional opaque `decrypt_candidate` (the reassembled inner ciphertext); variants `AlreadySeen | Drop(reason) | RelayOnly | RelayAndDecryptCandidate`. **No secret crosses here.**
3. `decrypt_location(...)` — the **existing** decrypt entry point on `CircleManager`, called **separately** by Dart only when (2) returns a `decrypt_candidate`. This keeps the secret-bearing path out of the routing function and off the relay timing path (T-L).
4. `mesh_poll_stats() → MeshStatsFfi` `{ connected_peers, relayed_count, seen_cache_len }` — synchronous getter (no streams).
5. `mesh_set_enabled(on) → ()` — gates the engine; clears transient routing state on off.

**Engine ownership across FFI:** the `&mut self` engine is held inside the existing opaque-type wrapper behind a `Mutex` (as `CircleManagerFfi` does), so "single-owner, no locks" means *no application-level locks in the routing logic* — the FFI wrapper's `Mutex` provides the serialization. Relay timing is **identical regardless of decrypt outcome** (T-L): decrypt is a separate Dart call whose latency never feeds back into the relay schedule.

**Layer C — Flutter/Dart: thin impure shell.**
- **`MeshTransport`** (abstract + a concrete `BleMeshTransport` on the **peripheral-capable plugin chosen in §4.1**, e.g. `bluetooth_low_energy` — *not* `flutter_blue_plus`, which lacks the peripheral role), injected into `LocationSharingService` like `RelayService`/`CircleService`. Owns central+peripheral, write/notify flush, scan-duty `Timer`, MTU read, lifecycle hooks. Calls Layer B for routing; calls the separate decrypt FFI when a candidate is returned.
- **Producer-side strip + send seam:** the location producer strips the outer event to the inner MLS ciphertext (§6.1) and `unawaited(_meshTransport?.broadcast(innerCiphertext))` fire-and-forget alongside relay publish. **The avatar-share path is never wired to the mesh** (G-12 producer invariant).
- **Receive seam (corrected — both loops):** `MeshTransport.drainInbound()` must be called **at the top of *both*** `fetchMemberLocations` (the 30 s `memberLocationsProvider` loop) **and** `_runEvolutionPoll` (the 60 s `evolutionPollerProvider` loop) — they share `_seenEventIds`, and wiring mesh into only one leaves a cross-loop race where the other re-processes a mesh event before it is marked. Drain **before** any `_seenEventIds` check, and respect the existing `_pauseGeneration` guard (do not inject mesh events past the pause guard). The cross-loop timing window is explicitly acknowledged and must be covered by a test.
- **Android foreground service (corrected):** add the three BLE runtime permissions (`BLUETOOTH_SCAN/CONNECT/ADVERTISE`); place BLE in the **foreground isolate**; use a **dedicated Bluetooth foreground service** (or main-activity foreground-only BLE) declaring `connectedDevice`, rather than routing through the `flutter_foreground_task` background isolate. If reusing the existing FGS, change **both** the Dart `serviceTypes` list **and** the manifest `android:foregroundServiceType` together (else `SecurityException` on Android 14).
- **iOS:** v1 is **foreground-or-pre-connected-only** (§4.3, N-G).
- **UI:** `MeshToggleButton` in the top-right `Column`; **`StateNotifierProvider<MeshStatsNotifier, MeshStats>`** (matching existing analogues), **non-autoDispose or kept alive by the always-visible button**; 3 s poll for peer count; `relayedCount` incremented Dart-side from `mesh_decode_and_decide` return; ambient-navigator `showModalBottomSheet` stats surface.

### 12.2 Rust unit + proptest (runs in `rust-check.yml`, zero hardware, **zero crypto state**)
- **Packet codec round-trip:** `decode(encode(x)) == x`; garbage → `Err`, never panic.
- **TTL monotone + drop-at-0:** `new_ttl < incoming`; `ttl ≤ 1 ⇒ !should_relay`; cap never exceeds incoming depth; jitter in asserted band.
- **Forward-all-opaque invariance:** the relay decision is **identical** for two frames that differ only in whether a member could decrypt them (the routing core has no decrypt input, so this is structural — assert no membership/decrypt parameter exists on `RelayController`/`relay_eligibility`).
- **Seen-cache:** eviction by injected receive-time + compaction; re-insert → `AlreadySeen`; **poisoning property** — N attacker ids cannot evict a real id below capacity; **`created_at` is never an input.**
- **Eligibility / size-cap (load-bearing "location yes / photo no"):** small location frame → `Forward`; oversized → `Drop(TooLarge)`; expired → `Drop`; malformed → `Drop`.
- **Fragment:** `assemble(shuffle(split(blob, mtu))) == Complete(blob)`; **missing fragment never completes and the whole beacon is dropped at 30 s expiry**; oversize → `Oversized`; 128-cap evicts oldest.
- **Freshness:** `expiry + grace − 1` survives, `+ grace + 1` drops — same constant as `decrypt_location`.
- **NEW — scheduled-relay-vs-expiration race:** a frame fresh at ingest but expiring **during** the jittered rebroadcast delay is **not** re-emitted (compose `freshness` with the scheduled relay).
- **NEW — eviction-vs-freshness composition:** seen-cache LRU eviction cannot resurrect a just-expired id (an evicted-then-re-seen expired id is still dropped by freshness).
- **Cross-transport forward-dedup:** same `mesh_msg_id` via two entry points → second `AlreadySeen` (display-dedup is tested in Dart, §12.4, since it is post-decrypt).

### 12.3 THE key deliverable — in-memory multi-node simulator (`haven-core/tests/mesh_sim.rs`) — **routing only**
A deterministic, hardware-free harness validating **logical/routing properties only.** It **cannot** model BLE connection-interval gating, notify-queue backpressure, MTU variance, OS background throttling, or iOS-vs-Android background asymmetry — so it **does not validate throughput/capacity/battery/latency** (those are §12.5 hardware-lab deliverables). The draft's implication that P0–P1 de-risk performance is corrected.
- **`trait MeshLink { fn deliver(from, to, frame, now_ms); }`** with a `FakeLinkGraph` over an in-memory adjacency map: per-edge latency, drop probability, up/down state.
- **`VirtualClock`** advancing `now_ms` in fixed ticks; all jitter/backoff seeded from a fixed RNG → reproducible & `proptest`-shrinkable.
- **Properties (each a test):** flooding convergence/multi-hop delivery (line/star/random, ≥ threshold under drop); **TTL bounding / storm control with the *actual* fanout subset** — bounded total transmissions, sub-linear in edge count via cancel-on-duplicate, and **this is the source of the §11.3 relay-multiplier figure, not prose**; partition/merge convergence with no duplicate *forwarding*; loop-freedom in cyclic topology; size-cap honored end-to-end (oversized dropped at first eligibility check, never propagates); **fragment-loss → whole-beacon-drop**; **churn property — N epoch-advancing commits within one TTL window → bounded undecryptable-on-delivery rate** (models the §6.4 partition-delayed-delivery degradation as an explicit, bounded number rather than an unjustified "fine").

### 12.4 Flutter widget tests (`flutter test` lane)
- **Toggle:** mock `MeshTransport`; tap off→on → assert blue glow + `mesh_set_enabled(true)`; on→off reverts.
- **Stats:** override `meshStatsProvider` with fake `MeshStats(3, 12)` → badge + sheet rows render; Dart-driven `relayedCount` increment from a simulated `mesh_decode_and_decide` "relayed" result updates the badge between poll ticks.
- **Provider lifetime:** `ProviderScope(overrides:[meshTransportProvider.overrideWithValue(...)])` + `fakeAsync` clock → 3 s timer starts only when enabled, cancelled on `onDispose`; **assert the provider stays alive while the toggle button is mounted** (the always-visible button watches it) and the badge keeps updating after the sheet is dismissed.
- **Cross-loop dedup seam:** `MockMeshTransport.drainInbound` returns an event; assert it is processed once even when **both** `fetchMemberLocations` and `_runEvolutionPoll` fire, and that display-dedup is post-decrypt (a not-yet-decryptable out-of-order message is *not* prematurely blacklisted — the regression the draft would have caused).
- **Service seam:** assert `broadcast` is called with the **stripped inner ciphertext** (not the full kind-445 event), and that the avatar-share path is **never** routed to the mesh.

### 12.5 The real-BLE gap — manual device-matrix (carries the perf/background gates)
Real BLE cannot run in CI/emulators. Everything in 12.2–12.4 + the simulator (12.3) covers **routing logic only**; the residual **hardware lab** (checked-in `docs/MESH_DEVICE_MATRIX.md` runbook) carries **all timing/throughput/battery validation and the background gates**, with **binary acceptance criteria**:
- **Peripheral-GATT-server spike (Go/No-Go, §4.1):** the pinned peripheral-capable plugin advertises a custom UUID, hosts a writable+notify characteristic accepting inbound connections, **and** acts as a central — concurrently, on **both** iOS and Android. *Fail → architecture changes.*
- **iOS background (binary):** "relays ≥1 frame after 5 min backgrounded with screen off, given a pre-existing connection" — **else fall back to the documented foreground-or-pre-connected-only constraint (N-G).**
- **Cross-platform iOS↔Android dual-role link;** 4–6-phone N-device flood (line/star/cluster — **confirm the simulator's convergence prediction and the relay multiplier**); background relay (Android `connectedDevice` service); range/partition walk-out (3 s-disconnect vs 15 s-timeout, re-converge on return); MTU/fragmentation across an iOS↔Android link; **battery curve under sustained relay** (no CI proxy exists).
- **Inner-MLS buffered-decrypt measurement (§6.4):** commit N epochs, replay a buffered beacon, record decrypt success/failure per N → fills the unproven window before any reliability claim.

### 12.6 Architecture risks
- **Peripheral-role plugin (Go/No-Go):** `flutter_blue_plus` is central-only and **cannot** host the relay's GATT server; the whole Layer-C design depends on a peripheral-capable plugin proving dual-role on both OSes (§4.1). Promoted to the gate, not buried here.
- **FFI is sync/poll-only** — stats polled (3 s), inbound drained on both receive loops; `relayedCount` incremented Dart-side; a future `StreamSink` upgrade removes poll lag.
- **Foreground-service lifecycle** — BLE permissions + isolate placement + dual-declaration (Dart `serviceTypes` **and** manifest type) are all required; mis-declaration is a hard crash on Android 14. iOS dual background modes face review scrutiny + advertising truncation.
- **`nostr_group_id` privacy** (SECURITY.md duty) — **stripped at the producer**, never on the wire; forward-all-opaque so eligibility never inspects membership.
- **Forward-secrecy / decryptability** — never cache/forward secrets; **the inner-epoch decryptability window is unproven** (§6.4) and measured in P5; past-epoch `Unprocessable` is accepted degradation.
- **Co-membership oracle (T-L)** — routing core has no decrypt input; decrypt is a separate FFI call strictly off the relay timing path; relay decision is structurally membership-blind.

---

## 13. Phased Implementation Roadmap (no code)

| Phase | Scope | Definition of Done |
|---|---|---|
| **P0 — Pure routing core (hardware-free, crypto-free)** | `haven-core/src/mesh/`: packet codec, relay, fanout, seen, eligibility, freshness, fragment, dutycycle, limiter, engine — all pure, **no MDK, no secrets**. | All modules pure functions; full unit + `proptest` suites green in `rust-check.yml`; **size-cap "location yes / photo no" test**, **forward-all-opaque invariance test**, **scheduled-relay-vs-expiration race test**, **eviction-vs-freshness test**, **receive-time eviction (never `created_at`) test** all passing; clippy pedantic/nursery clean; coverage meets the **repo's global 80% Rust gate** (per-module unreachable defensive arms acceptable); **no FFI, no BLE, no MDK, no secrets** in the module. |
| **P1 — Simulator + split FFI boundary** | `tests/mesh_sim.rs` (routing-only); the `mesh_*` FFI fns **split so routing is crypto-free** (decode/decide vs separate decrypt); `MeshTransport` abstract + mock; engine FFI ownership via opaque-wrapper `Mutex`. | Simulator asserts convergence / TTL-bounding (with the **actual fanout subset**) / partition-merge / loop-freedom / size-cap-end-to-end / fragment-loss-drop / **churn→bounded-undecryptable**, deterministic & shrinkable, **and is the source of the §11.3 relay multiplier**; FFI regenerated, `Result<_,String>`, redaction verified, **`mesh_decode_and_decide` carries no secret/real-group-id and no decrypt**; security-reviewer sign-off on the boundary and the forward-all-opaque structure. |
| **P2 — Peripheral spike + single-hop real BLE** | **First:** the §4.1 peripheral-GATT-server Go/No-Go spike on both OSes. **Then:** `BleMeshTransport` dual-role; producer strip + send/receive seams (**both loops**); MAC randomization; service-UUID-only advertising; BLE permissions. | **Spike passes on iOS *and* Android** (else escalate to the owner — architecture change); two physical phones (one iOS, one Android) exchange a stripped-ciphertext frame directly; **display-dedup works across both receive loops**; **no `nostr_group_id`/`h` tag on the wire (sniffer-verified)**; kill-switch halts radio instantly; **inner-MLS buffered-decrypt window measured (§6.4)**. |
| **P3 — Multi-hop flood** | Relay path (forward-all-opaque), scheduled rebroadcast + cancel-on-duplicate, fanout subset, fragmentation/reassembly, duty-cycle, connection scheduler/backoff. | 4–6-phone line/star/cluster: a beacon injected on one reaches all; **measured retransmissions and relay multiplier compared against the simulator's prediction (confirm *or refute* — the capacity numbers are hypotheses, not pre-validated)**; near-MTU blob reassembles across iOS↔Android; **lost-fragment → whole-beacon-drop observed and recovered by next cadence**; partition walk-out re-converges; **battery curve recorded.** |
| **P4 — UI** | `MeshToggleButton` (blue glow, alpha-0.15 shadow), badge + Dart-driven counter, `StateNotifierProvider` poll, **ambient-navigator** `showModalBottomSheet`, **expanded** first-enable disclosure (locate+count+track), Android dedicated-BLE-FGS + permissions, iOS foreground-only constraint. | Widget tests green incl. **provider-stays-alive-via-button** and **cross-loop dedup**; ui-ux + accessibility review pass (non-color-only state, semantics); disclosure gate matches SEC-H2 and states the physical/count/track risk; foreground notification present; **default-OFF verified.** |
| **P5 — Hardening & sign-off** | Wire-feature minimization, duty-cycle/coalescing, per-link rate-limits & **worst-case** Sybil-amplification validation (no per-origin cap), SECURITY.md update (G-18: presence-correlation + crowd-count + co-membership-oracle + protocol-fingerprint), `MESH_DEVICE_MATRIX.md`, reconcile the two missing web reports, finalize inner-decrypt-window measurement. | **Worst-case amplification (links×TTL×Sybil) characterized in sim** (not claimed "bounded" qualitatively); security-reviewer + dependency-auditor pass; SECURITY.md vectors landed; commissioned web reviews reconciled; **owner sign-off on: iOS-background result, peripheral-plugin result, the irreducible localization/count/track risk, and the unproven-decrypt-window degradation** before any public on-by-anyone release. |

P0–P1 are pure value (testable, reusable, low-risk, **routing-only — they do not de-risk performance or buildability**) and should proceed now. P2+ gate on hardware, the peripheral-plugin spike, the inner-decrypt measurement, and the open questions below.

---

## 14. Open Questions & Risks

### 14.1 Decisions needing the owner
1. **Peripheral-role plugin (NEW, architecture-invalidating).** `flutter_blue_plus` cannot host the relay's GATT server. Is `bluetooth_low_energy` (dual-role) acceptable, or is a native binding preferred? The P2 spike decides feasibility; a failure here changes or kills the architecture.
2. **iOS background BLE viability (biggest platform unknown).** Accept the v1 **foreground-or-pre-connected-only** constraint (N-G), or invest in connectionless/state-restoration work? Will dual background modes pass App Store review? Field-test in P2.
3. **Inner-MLS buffered-decrypt window (NEW, correctness-critical).** The store-and-forward decryptability window is unproven (§6.4). Accept "past-epoch buffered beacons may be `Unprocessable`" as a known degradation, pending the P2 measurement?
4. **De-anonymization tolerance at a protest.** Given that the service UUID must be constant and the protocol shape is a fingerprint (R-1, R-5), is the residual "outs you as a Haven user" acceptable for v1, or is connectionless/decoy hardening (G-16/17) required from the start?
5. **TTL cap (4/5) vs bitchat's privacy-clamped 2 — explicit reach-vs-path-reconstruction tradeoff.** Higher TTL means more hops observable to a passive array and easier path-reconstruction toward the originator (§11.2). Accept 4–5 for venue reach? (Recommended yes, but this is genuinely a privacy cost, not a free lunch.)
6. **Altruistic internet-return bridge — originator-gated, off by default.** Confirm bridging is **privacy-negative for the originator** (§7.4) and must be the originator's choice, not the bridger's.
7. **Gossip sync** — defer (recommended) or include for partition-merge robustness?

### 14.2 Biggest risks
- **R-2 / T-C Physical localization + crowd-counting + inter-rotation tracking at a protest (CRITICAL, irreducible).** A transmitter can be DF-located to meters; a receiver array can count and track the Haven crowd across MAC rotations via the protocol fingerprint and origination timing. *This is the defining risk* — disclosed honestly in-app (expanded copy, §8.5) and owner-signed-off before public release.
- **T-L Co-membership oracle (CRITICAL, design-controlled).** Forward-all-opaque (R-11) is non-negotiable; membership-conditioned relaying would let an active adversary map who-is-in-which-circle with physical location.
- **Peripheral-plugin buildability (HIGH, architecture-invalidating).** `flutter_blue_plus` is central-only; resolve in the P2 spike before committing.
- **Inner-MLS decrypt window (HIGH, unproven).** Buffered past-epoch beacons may silently fail to decrypt; measure before claiming reliability.
- **iOS background BLE (HIGH, uncertain).** v1 is foreground/pre-connected-only on iOS; resolve empirically in P2.
- **R-5 Protocol fingerprint defeats MAC rotation (HIGH, irreducible).** The constant GATT/header shape re-links rotated MACs and confirms "Haven user" — the Bridgefy-class residual.
- **Empirical-validation risk (process).** §4–5/§10 are grounded in the conducted web research, but the *platform* claims (iOS overflow-area background behavior, Android `connectedDevice` FGS longevity, peripheral-plugin dual-role on both OSes) must still be confirmed on real hardware in P2 before any reliability claim — research narrows them, hardware settles them.
- **T-F/T-G Sybil/battery DoS (HIGH).** No enforceable per-origin cap; characterize **worst-case** amplification (links×TTL×Sybil) in the sim before shipping.

---

## 15. References

### External
- **bitchat** (BLE-mesh reference, Swift): `bitchat/WHITEPAPER.md`, `bitchat/docs/SOURCE_ROUTING.md`, `bitchat/docs/REQUEST_SYNC_MANAGER.md`, `bitchat/docs/privacy-assessment.md`, `bitchat/docs/ARCHITECTURE_V2.md`, `bitchat/BRING_THE_NOISE.md`; pure-policy sources under `bitchat/bitchat/Services/` (`RelayController.swift`, `BLE/BLEFanoutSelector.swift`, `BLEConnectionScheduler.swift`, `BLEScanDutyPolicy.swift`, `BLEFragmentAssemblyBuffer.swift`, `BLEPacketFreshnessPolicy.swift`, `BLEService.swift`, `MeshTopologyTracker.swift`, `MessageDeduplicationService.swift`, `TransportConfig.swift`).
- **Marmot Protocol** (MIP-00..04): https://github.com/marmot-protocol/marmot — MIP-03 outer content is **NIP-44 v2** (ChaCha20 + HMAC-SHA256) over an exporter-derived keypair wrapping the serialized `MLSMessage`; the inner `PrivateMessage` uses the ciphersuite AEAD (**AES-128-GCM** for Haven's default suite). See `MARMOT_PROTOCOL_KNOWLEDGE.md`.
- **MDK (Rust MLS SDK)**: https://github.com/parres-hq/mdk — exporter-secret retention `DEFAULT_EPOCH_LOOKBACK = 5`; **inner secret-tree pruning is more aggressive and the buffered-decrypt window is unmeasured** (§6.4).
- **whitenoise-rs** (reference app): https://github.com/parres-hq/whitenoise
- **Plugin landscape (verify before P2):** `flutter_blue_plus` is **central-only**; peripheral role requires `bluetooth_low_energy` (dual-role) or `flutter_ble_peripheral` (peripheral-only) — the §4.1 spike is load-bearing.
- **Prior-app security literature (conducted research — primary sources):**
  - Bridgefy: Albrecht/Blasco/Jensen/Mareková, *Breaking Bridgefy* (CT-RSA/FC 2021, eprint 2021/214); Albrecht/Eikenberg/Paterson, *Breaking Bridgefy, again — adopting libsignal is not enough* (USENIX Security 2022). Lessons: plaintext-metadata social-graph leak, MITM, decompression-bomb + forward-before-parse DoS, and the **protocol-fingerprint** outing (R-5).
  - FireChat: Citizen Lab / Global Voices Advox (Hong Kong 2014) — no E2E, public-by-default, spoofable identity (the marketing-vs-threat-model failure).
  - Briar / Bramble Transport Protocol (BTP/BHP specs; CVE-2023-33982) — the metadata-privacy gold standard: 16-byte pseudorandom on-wire tag, length-hiding padding, FS via rotate-and-delete + reordering window.
  - Berty/Wesh; Meshtastic (shared-PSK / plaintext position lessons); goTenna (DEF CON 26/32; CVE-2024-47130); SSB Secret Handshake (Tarr 2015).
- **BLE tracking / localization / dedup attacks (conducted research):** Becker/Li/Starobinski, *Tracking Anonymized BLE Devices* (PETS 2019, MAC-rotation desync); Givehchian et al., *Physical-Layer BLE Location Tracking* (IEEE S&P 2022, ~40–47% uniquely fingerprintable, ~$150 SDR); Zuo et al. (CCS 2019, static-UUID app fingerprinting); Naor & Yogev, *Bloom Filters in Adversarial Environments* (CRYPTO 2015 — keyed-filter requirement, §6.3/§10 T-E); Douceur Sybil (IPTPS 2002); Heilman et al. eclipse (USENIX 2015). Protest-mesh state-of-the-art to read before building: **Amigo (CCS 2025, eprint 2024/1872)** and **ASMesh (CCS 2023)**.
- **BLE platform landscape (conducted research; confirm on hardware in P2):** CoreBluetooth backgrounded service-UUID overflow-area substitution; Android 14 `FOREGROUND_SERVICE_CONNECTED_DEVICE` + runtime `BLUETOOTH_SCAN/CONNECT/ADVERTISE` (+ `neverForLocation`, a privacy win); Android 15 `connectedDevice` FGS 6-hour-timeout exemption; Wi-Fi Aware (NAN) cross-platform immaturity; peripheral-role plugin capability (`bluetooth_low_energy` vs central-only `flutter_blue_plus`); MLS RFC 9420/9750; PADME/PURBs (PETS 2019); Signal sealed-sender break (Martiny et al., NDSS 2021).

### Haven / MIP source pointers
> ⚠️ **All line numbers below are approximate and were found to drift across the codebase. Re-anchor every reference against current `HEAD`, or prefer symbol names (which don't rot), before P0.** Spot-checked corrections: `encrypt_location` ≈ `manager.rs:1656` (not 1579); `decrypt_location` ≈ `:1727` (not 1650); NIP-40 gate ≈ `:1741` (not 1658); send seam ≈ `location_sharing_service.dart:277`; settings-button shadow uses `alpha 0.15` (not 0.1); the member-marker sheet does **not** pass `useRootNavigator: true`.

- Production send/receive: `haven-core/src/circle/manager.rs` — `encrypt_location` (verify line; returns a **full kind-445 Event**, not bare ciphertext — §6.1), `decrypt_location`, NIP-40 gate, dedup precedent `process_invitation`.
- MLS path: `haven-core/src/nostr/mls/manager.rs` — `create_message`, `process_message`, `redact_hex_sequences`.
- Location types/TTL: `haven-core/src/location/types.rs` (`LocationMessage`), `haven-core/src/location/ttl.rs` (`compute_jittered_ttl_secs` → **`[interval, 2*interval]` over `[72,168] s` = `[72,336] s`**, `RECEIVER_EXPIRATION_GRACE_SECS = 60`, stable-`h`-tag leak note).
- Circle types: `haven-core/src/circle/types.rs` (`nostr_group_id`, MLS-id redaction `Debug`, `LastKnownLocation`).
- Kinds / legacy path: `haven-core/src/nostr/event.rs` (`KIND_GROUP_MESSAGE=445`, `KIND_LOCATION_DATA=9`).
- Epoch retention: `haven-core/tests/mls_e2e_security_tests.rs` (`max_past_epochs/DEFAULT_EPOCH_LOOKBACK = 5`, `p3b_old_exporter_secrets_are_pruned`) — **exporter window only; does not establish the inner-message window**.
- Flutter seams: `haven/lib/src/services/location_sharing_service.dart` (send seam; **`_seenEventIds` is a *post-decrypt-success* marker, NOT a pre-decrypt ingress gate** — §7.1; the two receive loops `fetchMemberLocations` and `_runEvolutionPoll` share it); `haven/lib/src/providers/service_providers.dart`; foreground service `haven/lib/src/services/background_location_manager.dart` (uses `flutter_foreground_task`, `ForegroundServiceTypes.location`).
- UI: `haven/lib/src/pages/map_shell.dart`; `haven/lib/src/widgets/common/settings_button.dart` (**shadow alpha 0.15**); `haven/lib/src/widgets/map/map_controls.dart`; `haven/lib/src/pages/map/map_page.dart` (member-marker sheet — **ambient navigator, no `useRootNavigator`**); stats pattern `haven/lib/src/providers/background_location_provider.dart` (non-autoDispose lifecycle precedent); existing `StateNotifierProvider` analogues (`BackgroundSharingNotifier`, `ThemeModeController`, `MapStyleController`, `OnboardingController`).
- Dependency note: **`flutter_blue_plus` is not in `haven/pubspec.yaml`**; a peripheral-capable plugin must be added and proven (§4.1).
- Profile-pictures interaction: `docs/PROFILE_PICTURES_PLAN.md` (§5.1/§5.4 photo↔location indistinguishability & collided padding bucket — **a plan, with an unresolved bucket defect; the producer-side allowlist invariant, not this premise, is the load-bearing defense** — §9.2), `docs/ENCRYPTION.md`.
- New artifacts to create: `haven-core/src/mesh/` (modules above), `haven-core/tests/mesh_sim.rs`, `docs/MESH_DEVICE_MATRIX.md`; SECURITY.md update (G-18).
- FFI boundary to extend: `haven/rust_builder/src/api.rs` (add the **split** `mesh_*` routing fns beside the existing `decrypt_location`).

---

*Owner must-read flags: (1) **The mesh payload is the stripped inner MLS ciphertext, NOT the kind-445 event** — forwarding the raw event leaks the `nostr_group_id` `h` tag on the BLE wire (§6.1). (2) **`flutter_blue_plus` is central-only and cannot relay** — a peripheral-capable plugin must be proven on both OSes before P2 (§4.1); this can change or kill the architecture. (3) **The inner-MLS buffered-decrypt window is unproven** — assume past-epoch buffered beacons may be `Unprocessable` until measured (§6.4). (4) **v1 is forward-all-opaque** to avoid a co-membership oracle (T-L). (5) **`_seenEventIds` is post-decrypt-success, not a free cross-transport ingress gate** — forward-dedup and display-dedup are distinct layers (§7.1). (6) **The physical risk is locate + count + track**, not single-device DF — the in-app disclosure says so (§8.5). (7) The BLE-landscape and security-lessons research is incorporated (§15); the remaining unknowns are **platform behaviors to confirm on real hardware in P2** (iOS overflow-area background, Android `connectedDevice` FGS, peripheral-plugin dual-role), not absent research.*
