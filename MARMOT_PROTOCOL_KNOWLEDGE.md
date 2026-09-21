# Marmot Protocol Knowledge Document

> **Purpose**: Reference documentation for building secure, decentralized applications using the Marmot Protocol ecosystem, as Haven ships it: the **MDK "Dark Matter"** crate set (v0.9.4) implementing the **Marmot v2** wire format. This document reflects the post-migration reality of `haven-core`; the pre-Dark-Matter (MIP-era) protocol facts live in the [Old vs New reference](#old-vs-new-migration-reference) and in git history.

---

## Table of Contents

1. [Overview](#overview)
2. [Spec Restructure: MIPs → Protocol Surfaces](#spec-restructure-mips--protocol-surfaces)
3. [Protocol Architecture](#protocol-architecture)
4. [Security Model](#security-model)
5. [Event Kinds & Wire Format](#event-kinds--wire-format)
6. [App Components](#app-components)
7. [MDK "Dark Matter": The Engine Haven Runs](#mdk-dark-matter-the-engine-haven-runs)
8. [Haven-Specific Choices](#haven-specific-choices)
9. [Old vs New: Migration Reference](#old-vs-new-migration-reference)
10. [Nostr Integration](#nostr-integration)
11. [Development Guidelines](#development-guidelines)
12. [Security Best Practices](#security-best-practices)
13. [Location Sharing Considerations](#location-sharing-considerations)
14. [Resources](#resources)

---

## Overview

### What is Marmot Protocol?

The **Marmot Protocol** is a messaging protocol that combines:
- **MLS (Messaging Layer Security)** - RFC 9420 for efficient E2E encrypted group messaging
- **Nostr Protocol** - Decentralized identity and relay network for transport

**Key Benefits:**
- 🔒 **End-to-End Encrypted**: Messages encrypted on device, only recipients can read
- 🌐 **Decentralized**: No central servers to shut down or compromise
- 🛡️ **Metadata Protection**: Hides who you're talking to, not just what you're saying
- ⚡ **Scalable**: Efficient group messaging (log-scale vs linear) for 2 to thousands of members
- 🔗 **Interoperable**: Works across different clients and implementations
- 🆔 **Identity Freedom**: No phone numbers or email addresses required

### Repository Structure

| Repository | Purpose | License |
|------------|---------|---------|
| [marmot-protocol/marmot](https://github.com/marmot-protocol/marmot) | Protocol specifications (restructured surfaces; MIPs deprecated) | MIT |
| [marmot-protocol/mdk](https://github.com/marmot-protocol/mdk) | Rust SDK — the "Dark Matter" monorepo (engine, session, storage, transports) | MIT |
| [marmot-protocol/whitenoise-rs](https://github.com/marmot-protocol/whitenoise-rs) | Full messaging application library (reference app; AGPL-3.0) | AGPL-3.0 |

### Current Status — read this honestly

⚠️ **NOT SEMVER-STABLE.** The Dark Matter workspace is **git-tag-only** (`publish = false`, never on
crates.io) and self-describes as *"0.9.0, single internal consumer, not semver-stable"*
(`crates/cgka-engine/README.md:72`). Haven pins all five crates to one 40-char rev of the **v0.9.4**
release tag (`e391adc133a9b60e420da7a0446f014a180ac8d2`, 2026-07-10) — bump only to released tags,
never `master` (CLAUDE.md, MDK pinning rule). Known upstream state at pin time, **re-verified
2026-09-05** against a full bare clone of `marmot-protocol/mdk` with both endpoints extracted via
`git archive`, plus `gh api` (Haven's rev `e391adc` is byte-identical to tag `v0.9.4`). The ladder
now runs v0.9.4 → **v0.9.18** (`f734b31`, 2026-09-05) — 15 tags, 452 commits, 166 of them non-merge
commits touching Haven's five pinned crates, and **no CHANGELOG exists for any of the five**. The
bump is scoped as milestone **P4M** in `docs/POWER_EFFICIENCY_PLAN.md` §5.7:

- ~~The **commit-loss / fork-recovery train** (#825, #877, #892 epoch-gap backfill) is in master but
  **unreleased** — a `v0.9.5+` tag containing it is the next bump target.~~
  **CORRECTED 2026-09-05 — both of the two verified PRs SHIPPED, and neither is REACHABLE from
  Haven's pinned crates.** #825 (`363b1fe3`) and #892 (`e6654ece`) both first appear in **v0.9.5**,
  but they land almost entirely outside the five pinned crates and **#892 touches none of them at
  all**; #825's `CursorPersistence{Advance,Frozen}` policy hangs off `MarmotAppConfig` in
  **`marmot-app`**, a crate `haven-core/Cargo.toml:52-53` rejects by name and
  `scripts/ci/check_mdk_supply_chain.sh` (check 1) hard-fails on. **No tag on the ladder makes
  either reachable**, so "bump to a released tag to get the backfill" is not an available move at
  any version — which is what killed option (ii) of the plan's OD4-c. #877 was NOT re-verified and
  stays **UNVERIFIED**.
- **#757 CONFIRMED STILL OPEN** (`gh api` 2026-09-05 → `{"state":"open"}`): the stored-convergence
  buffer has no per-group cap and no eviction API (Security Rule 12), so Haven's intake cap keeps
  its subject at every tag on the ladder — the caps that DID tighten upstream govern the separate
  `PeelDeferred` store, not this buffer. **#864 / #866 / #885 were NOT re-queried**: the "OPEN"
  below is the pin-time record, not a 2026-09-05 fact.
- **#864 (pin-time OPEN, state at v0.9.18 UNVERIFIED)**: five validators embed full group-id hex in
  error strings (Haven keeps `redact_hex_sequences` at the error boundary). **#866 (pin-time OPEN,
  UNVERIFIED)**: a `SQLITE_BUSY` lock-upgrade window in `storage-sqlite`. **#885 (pin-time OPEN,
  UNVERIFIED)**: phantom `committed_from` fork quarantine.
- **The next bump is a coordinated WIRE migration, not a dependency bump.** v0.9.18 introduces
  `ProtocolProfile { Legacy, Current }` (`crates/traits/src/group.rs:25-31`; absent at v0.9.4) and
  moves the account identity proof off leaf extension `0xF2F1` onto app component **`0x8009`**
  (`ACCOUNT_IDENTITY_PROOF_COMPONENT_ID`, `crates/traits/src/app_components/mod.rs:106`; a grep for
  it at v0.9.4 returns empty). Every `Group` this pin wrote loads as `Legacy`
  (`Group.protocol_profile` is `#[serde(default)]`), `AccountDeviceSession::open` REFUSES a `Legacy`
  session, and the opt-out `legacy_compatibility_profile()` is `#[cfg(debug_assertions)]` — i.e.
  **absent from release builds**. Membership changes across the boundary are rejected on send and on
  receive, so an existing circle would keep publishing locations and could never add or remove a
  member again. Blockers, gains and the honest recommendation on whether to take it: P4M.
- The **reference client has not migrated**: whitenoise-rs master still pins old `mdk-core 0.8.0`
  (pin-time record; NOT re-verified 2026-09-05).
- The published **Marmot v2 spec is behind the code** in places — see the
  [identity-proof divergence](#the-identity-proof-spec-vs-code-divergence) below. Where they
  disagree, **the code is authoritative** for Haven.

---

## Spec Restructure: MIPs → Protocol Surfaces

> **The MIP-00…MIP-05 documents are deprecated upstream.** `marmot-protocol/marmot` restructured
> the spec (~2026-07) into five directories — `foundation/`, `protocol-core/`, `app-components/`,
> `transports/`, `features/` — and the MIP numbering no longer exists there. `mip-coverage.md` in
> the spec repo maps the old numbers onto the new surfaces:

| Old MIP | Where it went |
|---------|---------------|
| **MIP-00** (Credentials & KeyPackages) | `foundation/identity`, `foundation/key-packages`, `transports/nostr`, `protocol-core/joining` |
| **MIP-01** (Group construction & group data ext) | `protocol-core/group-setup`, `foundation/canonical-encoding`, `app-components/` |
| **MIP-02** (Welcome events) | `protocol-core/joining`, `transports/nostr` |
| **MIP-03** (Group messages) | `protocol-core/group-messaging`, `protocol-core/member-departure`, `foundation/application-messages` |
| **MIP-04** (Encrypted media) | `features/encrypted-media.md` (**adopted**) |
| **MIP-05** (Push notifications) | `features/push-notifications.md` (optional/draft) |

New surfaces with no MIP ancestor: `foundation/account-identity-proof-v1.md` (**new and
breaking**), `protocol-core/convergence.md` (the concurrent-commit branch-selection algorithm),
`protocol-core/publish-lifecycle.md` (publish-before-apply), `features/multi-device.md` (draft),
`transports/quic.md` (experimental — irrelevant to Haven).

The spec is now **library-neutral** ("Implementations MAY use any MLS library if they produce and
validate the same protocol bytes"); MDK's `cgka-engine` remains **OpenMLS-backed** underneath.

**Per-user profiles are out of scope for Marmot** — all registered app-components are
group-scoped; the spec-blessed join point for member profiles is `group member →
BasicCredential.identity (Nostr pubkey) → kind-0` (see `docs/PUBLIC_PROFILE_MIGRATION_PLAN.md` §2).

### The identity-proof spec-vs-code divergence

The **shipped code** (`cgka-engine/src/account_identity_proof.rs`) carries the proof as custom MLS
**extension type `0xF2F1`**, version 2, domain **`marmot.account-identity-proof.v2`**, signing a
**canonical kind-450 Nostr event** (`created_at = 0`, `d` tag = the domain string). **Haven
implements to the code** — the engine enforces exactly that on ingest
(`InvalidAccountIdentityProof`), so interop is with the pinned MDK, not with the spec text.

The adopted spec has since moved past that carrier: `app-components/account-identity-proof-v2.md`
makes v2 a **required LeafNode app component, id `0x8009`**
(`marmot.member.account-identity-proof.v2`), whose data is a 104-byte `MarmotAuthorizationProof` —
the kind-450 signing event survives, the extension does not, and v0.9.4 knows nothing of `0x8009`.
`foundation/account-identity-proof-v1.md` is now **superseded**, kept only so `0xf2f1` is never
reinterpreted. The pin is therefore *behind* the spec here, where this note once recorded it as
ahead; closing the gap is a wire-format change that arrives with an MDK bump.

> **CORRECTED 2026-09-05 — the CODE has since caught the spec up, upstream, and that is exactly what
> makes the bump a wire break.** `ACCOUNT_IDENTITY_PROOF_COMPONENT_ID = 0x8009` is live in
> `crates/traits/src/app_components/mod.rs:106` at **v0.9.18** (grep for the symbol at v0.9.4 returns
> empty); `0xF2F1` survives there only as the **legacy classifier**, and a leaf mixing the two
> carriers is explicitly rejected. So "arrives with an MDK bump" is now concrete: it arrives with
> `ProtocolProfile::Current`, under the same `Legacy`-refusing session-open gate as everything else
> in that cutover (`docs/POWER_EFFICIENCY_PLAN.md` §5.7, milestone P4M, blocker 3).
>
> **Everything this section and the rest of this document say about `0xF2F1` remains TRUE** for
> Haven's pin and for every circle written under it — it is the UPSTREAM carrier that moved, not
> Haven's. Two further sites still name `0xF2F1` as *the* identity-proof carrier and are **FLAGGED
> here, deliberately NOT changed**, because changing them before the bump would make them wrong
> today: the leaf-extension list under [MLS Configuration](#mls-configuration) (`0xF2F1` MANDATORY,
> and the matching `mls_extensions` tag value in the kind-30443 shape) and `CLAUDE.md:243`'s kind-450
> row. Both are correct at v0.9.4 and both are P4M's to rewrite, in the same commit as the bump.

---

## Protocol Architecture

### Core MLS Concepts

**Groups**: Created with a random MLS group ID (kept private; never published). Groups evolve
through epochs, with changes proposed via `Proposal` messages and committed via `Commit` messages.

**Clients/Members**: Each device/client pair is a `LeafNode` in the MLS tree. State cannot be
shared across clients — joining from 2 devices creates 2 separate members (multi-device is an
upstream draft feature Haven does not use).

**Message Types**:
- **Control Messages**: `Welcome`, `Proposal`, `Commit` (group state evolution)
- **Application Messages**: Actual content sent between members

### MLS Configuration

```rust
// The single hard-enforced ciphersuite (EngineError::UnsupportedCiphersuite otherwise)
// — unchanged across the Dark Matter migration.
MLS_128_DHKEMX25519_AES128GCM_SHA256_Ed25519   // 0x0001

// Leaf extensions Haven's engine advertises (the 30443 `mls_extensions` tag set):
//   0x0003  required_capabilities
//   0x0006  app_data_dictionary        (extensions-draft-08 "safe extensions")
//   0x000a  last_resort
//   0xF2F1  marmot.account-identity-proof.v2  (MANDATORY — engine rejects leaves without it)
//
// Non-default proposal types advertised (the `mls_proposals` tag set):
//   0x0008  app_data_update
//   0x000a  self_remove                (MIP-03 SelfRemove — see Feature Registry below)
```

The old MIP-01 `NostrGroupDataExtension` (`0xF2EE`) is **gone**: group metadata now lives in MLS
**app components** inside the `app_data_dictionary` extension (see [App Components](#app-components)).
The wire-format policy is `PURE_PLAINTEXT_WIRE_FORMAT_POLICY` — see the
[confidentiality caveat](#pure-plaintext-wire-format-the-confidentiality-caveat).

### Data Flow Architecture (Haven's stack)

```
┌──────────────────────────────────────────────────────────────┐
│                       CLIENT DEVICE                          │
│  ┌──────────────────────────────────────────────────────┐    │
│  │  Application layer (Flutter UI / location pipeline)  │    │
│  └──────────────────────────────────────────────────────┘    │
│                          │                                   │
│  ┌──────────────────────────────────────────────────────┐    │
│  │  haven-core relay layer (Haven-owned)                │    │
│  │  - relay subscriptions, cursors, per-relay fan-out   │    │
│  │  - gift-wrap multi-relay cascade, catch-up sweeps    │    │
│  └──────────────────────────────────────────────────────┘    │
│                          │                                   │
│  ┌──────────────────────────────────────────────────────┐    │
│  │  SessionManager (haven-core/src/nostr/mls/manager.rs)│    │
│  │  - tokio::sync::Mutex<AccountDeviceSession>          │    │
│  │  - Rule 14: ONE live session per DB file, ever       │    │
│  └──────────────────────────────────────────────────────┘    │
│                          │                                   │
│  ┌──────────────────────────────────────────────────────┐    │
│  │  cgka-session → cgka-engine (OpenMLS-backed)         │    │
│  │  - ingest / send / advance_convergence               │    │
│  │  - publish-before-apply (PendingStateRef)            │    │
│  │  - stored-convergence buffer, branch selection       │    │
│  ├──────────────────────────────────────────────────────┤    │
│  │  transport-nostr-peeler (wire boundary)              │    │
│  │  - 445 outer AEAD + ephemeral signing, NIP-59 1059   │    │
│  ├──────────────────────────────────────────────────────┤    │
│  │  storage-sqlite (SQLCipher session.sqlite, WAL)      │    │
│  └──────────────────────────────────────────────────────┘    │
└──────────────────────────────────────────────────────────────┘
                           │
                           ▼
           ┌───────────────────────────────┐
           │      Nostr Relay Network      │
           │  - Gift-wrapped Welcomes      │
           │  - Ephemeral Group Events     │
           │  - KeyPackages (30443, NIP-65)│
           └───────────────────────────────┘
```

Haven deliberately does **not** adopt `transport-nostr-adapter`, `marmot-account`, or `marmot-app`
(Haven keeps its own relay plane, keyring integration, and app runtime). `marmot-forensics` is in
the audit graph regardless — `cgka-session` imports it unconditionally — even though Haven installs
no `ForensicRecorder`.

---

## Security Model

### Forward Secrecy & Post-Compromise Security

- **Forward Secrecy**: Past messages remain secure even if current keys are compromised
- **Post-Compromise Security (PCS)**: Key rotation limits impact of future compromises
- Keys are deleted per the engine's retention window (`DEFAULT_MAX_PAST_EPOCHS = 5` past epochs;
  Haven does not override it). Past-epoch outer 445s are decrypted via engine-retained group
  snapshots, not by handing old exporter secrets to the app.

### Key Independence

**Critical**: Marmot does NOT depend on a user's Nostr identity key (nsec) for MLS messaging:
- Compromise of the Nostr identity key does NOT give access to past/future group messages
- MLS signing keys are DISTINCT from Nostr identity keys (Haven Security Rule 1)
- Under Marmot v2 the separation is **formalized on-wire**: every leaf carries the mandatory
  `marmot.account-identity-proof.v2` extension (`0xF2F1`) — a Schnorr signature by the *identity*
  key over a canonical, unpublished kind-450 event binding identity pubkey ↔ MLS leaf signature
  key. The identity key signs only that binding proof, never MLS content.

### Metadata Protection

- **Group ID**: Only `nostr_group_id` (from the `NostrRoutingV1` app component, 0x8004) is
  published; the real MLS group ID never leaves the engine toward relays
- **Ephemeral Publishing**: every kind-445 is signed by a fresh ephemeral keypair (never reused,
  never the identity key)
- **Gift-Wrapped Welcomes**: NIP-59 gift-wrap hides sender/recipient of invitations

### Threat Considerations

| Threat | Mitigation |
|--------|------------|
| Nostr key compromise | MLS keys independent; group messages remain secure |
| Device compromise | Encrypt at rest (SQLCipher), remove inactive members |
| Relay compromise | Messages E2E encrypted; relays see only metadata |
| Network observer | Ephemeral keypairs, outer AEAD + NIP-59 layers |
| Co-member rebroadcasts your identity proof | **Irreducible by design** — any co-member can extract the leaf's kind-450 proof and publish it, publicly binding your pubkey to MLS participation (see `haven-core/SECURITY.md`, F12) |
| Malicious member floods the convergence buffer | Haven-side intake backpressure (Rule 12); engine storage unbounded until upstream #757 closes |

### PURE_PLAINTEXT wire format: the confidentiality caveat

The engine uses OpenMLS's `PURE_PLAINTEXT_WIRE_FORMAT_POLICY` — MLS **PublicMessage** in both
directions (`cgka-engine/src/wire_format.rs`). That policy governs **handshake** messages only
(commits and proposals): `MlsGroup::create_message` frames every application message as a
**PrivateMessage** whatever the policy says (OpenMLS `group/mls_group/application.rs`), so an
application 445 (the kind-25442 location rumor) is doubly encrypted — MLS PrivateMessage inside
the exporter-keyed outer wrap. Consequence, for commit and proposal 445s: **the kind-445 outer
ChaCha20-Poly1305 wrap, keyed by the MLS exporter secret, is their SOLE MLS-level
confidentiality layer** on the wire. Exporter-secret retention is therefore *the*
confidentiality boundary for handshake traffic and the outer of two for application traffic
(Security Rule 5), and the exporter label must never be downgraded (Rule 11; CI guard
`scripts/ci/check_no_exporter_label_override.sh`). Upstream marks this policy
`WIRE_FORMAT_POLICY_REVIEW_REQUIRED` ("Revisit Before External Rollout") — track its resolution.

---

## Event Kinds & Wire Format

Every on-wire value below is what Haven actually publishes/ingests on the pinned v0.9.4 rev.

### Summary table

| Kind | Name | Status | Notes |
|------|------|--------|-------|
| 0 | Public profile metadata | Live | NIP-01/24; identity-key-signed; public-by-default (see CLAUDE.md) |
| 9 | Marmot chat message | **Never emitted** | Marmot's chat kind; receive-only and only paired with `["t","location"]` (see "Why Haven's inner kind is not 9") |
| 1210 | Inner system rows | Live (engine) | Engine-generated membership-change rows inside 445 |
| 25442 | Inner application message | Live | Haven's location content **inside** 445; never published bare |
| 30443 | KeyPackage (addressable) | Live | Replaces 443; published to and fetched from NIP-65 (10002) relays |
| 443 | KeyPackage (legacy) | **RETIRED** | One-time cutover retraction; fetch-filter residue only (see below) |
| 444 | Welcome rumor | Live | UNSIGNED, inside 1059; strict `e` + `relays` tags |
| 445 | Group message | Live | Outer ChaCha20-Poly1305, exporter label `"marmot/group-event"`, ephemeral key per event |
| 450 | Account identity proof | Live (never published) | Canonical event embedded in leaf ext `0xF2F1`; identity-key-signed |
| 1059 | Gift wrap (NIP-59) | Live | Welcome delivery to the recipient's 10050 inbox relays |
| 5 | NIP-09 deletion | Live | Cutover retraction of legacy 443s; best-effort relay hygiene |
| 10002 | NIP-65 relay list | Live | **KeyPackage discovery plane** (replaces 10051) |
| 10050 | NIP-17 inbox relays | Live | Gift-wrap (1059) delivery |
| 10051 | KeyPackage relay list | **RETIRED** | Retracted at cutover via empty replaceable (+ optional kind-5) |

### KeyPackage (kind 30443) — exactly as Haven publishes it

Kind 30443 is **NIP-33 addressable**: `(kind, pubkey, d)` is the coordinate; the `d` tag is a
stable per-account slot, so a republish **supersedes in place** (no accumulation of stale
KeyPackages, unlike the old regular-event 443). Built in
`haven-core/src/relay/maintenance/key_package.rs` (`build_key_package_event`), mirroring the
v0.9.4 `transport-nostr-adapter` tag set; **signed by the identity key**; content =
**base64** of the TLS-serialized MLS KeyPackage. Tags, in order:

```json
{
  "kind": 30443,
  "pubkey": "<identity pubkey>",
  "content": "<base64 KeyPackage bytes>",
  "tags": [
    ["d", "<stable slot id: 64 lowercase hex chars>"],
    ["mls_protocol_version", "1.0"],
    ["i", "<KeyPackage ref, 64-char hex>"],
    ["mls_ciphersuite", "0x0001"],
    ["mls_extensions", "0x0003", "0x0006", "0x000a", "0xf2f1"],
    ["mls_proposals", "0x0008", "0x000a"],
    ["app_components", "0x8001", "0x8003", "0x8004"]
  ]
}
```

- **NO `encoding` tag, NO `relays` tag** (both are old-era artifacts).
- The `i` tag is the MLS KeyPackage ref derived from the wire bytes
  (`cgka_engine::key_package::key_package_metadata` — deriving it also validates the leaf,
  including the identity proof).
- The `mls_*` / `app_components` tag **values are descriptive discovery metadata**: the receive
  path (`SessionManager::key_package_from_event`) base64-decodes the content and validates the
  real MLS bytes; it never parses these tags.
- **Discovery**: published to and fetched from the account's **NIP-65 (kind 10002)** relays.
  *"There is no dedicated KeyPackage relay list"* — kind 10051 is abolished.
- **Last-resort semantics**: every Haven KeyPackage is minted `last_resort`
  (`fresh_key_package` marks it), so the private init material is **never auto-deleted** when a
  welcome consumes it — it is pruned only via explicit `delete_key_package` (on failed publish or
  rotation, mdk#160). The old "consumed KeyPackage" race and the old M8-2
  `has_live_key_material` gate are both dissolved by this. Heal republishes the cached bytes
  verbatim into the same `d` slot (`published_key_packages` tracking:
  `(event_id, d_tag, key_package BLOB, created_at)`, one row per slot).

#### The `d` slot id is shape-normative

The binding does not leave the slot id free: **exactly one `d` tag, whose value is exactly 64
lowercase hex characters decoding to 32 bytes**, generated once from 32 random bytes. It MUST NOT
be derived from an account key, an MLS leaf key, a `KeyPackageRef` or a device label, and a
conformant inviter **MUST reject malformed or incompatible candidates** — so a mis-sized slot id
costs the account exactly what an expired package does: invitations that silently never happen,
with nothing to see on this device. Haven mints it in `mint_d`
(`haven-core/src/relay/maintenance/key_package.rs`) and pins the shape in
`a_first_publish_mints_a_binding_shaped_random_slot_id`
(`haven-core/tests/kp_rotation_e2e.rs`).

**Pre-fix installs published a MALFORMED slot; Haven now RETIRES it, once, per install.** Builds
before the widening minted 16 bytes (32 hex chars). By the binding's own cardinality rule — "if a
required singleton tag is missing, repeated, has no value, or has extra values beyond the one
defined here, the event is malformed" — a 32-hex `d` is not a narrower legal slot, it is a
malformed event, and `foundation/key-packages.md` requires an inviter to "reject malformed or
incompatible candidates before selecting one". A strictly conformant peer therefore could not
invite those accounts at all: keeping the legacy slot is what cost them their invitability.

The "a replacement MUST reuse the same `d`" rule does not forbid the fix: it is scoped to
*replacing the KeyPackage in a slot* ("a routine replacement MUST NOT generate a fresh slot id"),
and the same paragraph contemplates a client generating a different random `d` when it adds
another slot. Retiring a malformed slot for a conformant one is not a routine replacement. Nor
does anything in this tree cache a peer's `d`: the invite path issues
`Filter::kinds([30443, 443]).author(pk).limit(10)` and takes `max_by_key(created_at)` across ALL
slots (`relay/manager.rs`), never filtering on `d` and never storing one. White Noise is no
stricter: `validate_marmot_key_package_strict` checks only that a `d` is PRESENT, and the
fetched-member path (`validate_marmot_key_package_baseline`) does not read it at all.

**The retirement** (`decide_kp_slot_retirement`, run by `maintain_key_package` *ahead of* the
ordinary maintenance decision so nothing is ever published into the slot being retired; sentinel
`kp_slot_retirement_done_v1` in `user_settings`):

1. **Re-point** — `build_kp_slot_repoint_event` re-publishes the **same tracked package** into a
   freshly minted 64-hex slot. Moving the package instead of minting one is what makes the
   migration cheap and safe: no new init material, none consumed, and a peer that already fetched
   the old event holds a `KeyPackageRef` this device still owns, so an **in-flight Welcome against
   the retired coordinate still decrypts**. That is the `(Known, non-empty)` row and no other:
   fresh material is minted whenever the row carries nothing that can be vouched for — no row at
   all; an empty one (a `SeedD` row, or one the `not_after` purge blanked); a `NotCurrent` one
   whose bytes outlived a FAILED purge delete; and an `Unreadable` one, which
   `kp_init_key_purge_due` deliberately never blanks, so a corrupt row arrives here with bytes
   present. In those last two the retired coordinate's package is **not** carried forward and an
   in-flight Welcome against it does not survive — nor could it be, since the event's `i` tag is
   the `KeyPackageRef` derived from those bytes and deriving it validates the leaf. The superseded
   bytes are handed to the engine's `delete_key_package` once the replacement is acked, because
   the retired tracking row is dropped with it and material no row tracks can never reach the
   `not_after` bound again.
2. **Then retract** — and only after at least one relay **OK-ACKED** that publish (Rule 13's
   discipline: sent is not acked): tracking moves to the new slot, the retired row is dropped, and
   `build_kp_slot_retraction` publishes ONE NIP-09 kind-5 deletion naming the orphan by the
   identifier NIP-09 defines for an addressable event — `["a", "30443:<pubkey>:<old d>"]`, under
   which "relays SHOULD delete all versions of the replaceable event up to the `created_at` of the
   deletion request" — plus the observed event id as an `e` tag (NIP-09 takes "one or more `e` or
   `a` tags", and an id lets a relay that indexes deletions by id alone drop what was seen) and
   `["k", "30443"]` (NIP-09's SHOULD). The builder **refuses an empty slot id** (`30443:<pubkey>:`
   addresses every kind-30443 the account has, so it would delete the live slot too) and **refuses
   a binding-shaped one**, which makes retracting the live coordinate unrepresentable.
3. **Sentinel** — latched only when both landed. A failed publish, an unacked retraction, a
   storage-write failure or a tick where no relay answered leaves it unset and the next tick
   resumes. An unacked retraction additionally does **not consume the tick**: nothing was
   published, and the account's own slot is conformant and was observed live by this very tick's
   probe, so the retirement hands the tick back to ordinary maintenance instead. Spending it would
   make a relay that never acks a kind-5 (or refuses the kind outright) stop rotation,
   republish-if-missing and heal from ever running again — an advisory deletion starving the
   clock that keeps the account invitable, while every tick reported `AlreadyHealthy`. A crash between the relay's ACK and the local record is resumed by **adopting** the
   already-published slot — recognised by its content being the tracked package's bytes verbatim —
   rather than minting a second one, which would orphan the first along with the material only a
   tracking row can age out at `not_after`.

   **That resume covers the move path only.** `find_adoptable_kp_slot` recognises the slot by
   CONTENT, so it returns `None` when the row has no bytes to recognise — which is exactly the
   mint path above. A crash in the same window there therefore produces the outcome adoption
   exists to avoid: the next tick mints a second package into a second fresh slot, and the first
   is left published, untracked, and outside every retraction (those only ever name MALFORMED
   coordinates, and this one is conformant). Not closable in this tree: distinguishing "a
   conformant slot this device published" from "another device's, on the same identity" without
   tracked bytes needs an engine-side "do I hold this package?" query, and the pinned MDK exposes
   none — `fresh_key_package` and `delete_key_package` are the whole surface. The window is one
   relay ACK to one row insert, on the mint variant of a once-per-install migration.

Retracting first, or on a tick that could not publish, would risk an account with **no usable
published KeyPackage**, which is strictly worse than a malformed one; the ordering above is what
forbids it. Deletion itself is **advisory**: NIP-09 says relays *SHOULD* delete, and one that
ignores the request keeps serving the orphan. Where the retirement MOVED the package that is
survivable precisely because the orphan carries the same one — a lenient peer selecting it still
gets a `KeyPackage` this device can decrypt — until that package is next rotated or reaches
`not_after`, which are the spec's own deletion bounds. Where it had to MINT (the dead or unreadable
row above), the orphan advertises material the account no longer tracks and whose init key the
acked replacement authorises deleting, so a lenient peer that keeps selecting it can fail to invite
the account — the same outcome that row was already heading for. A relay that was unreachable
during the migration and comes back still serving the orphan is healed by ordinary maintenance on
the next tick (it does not serve the tracked slot, so it is a republish target) and a conformant
candidate joins the malformed one there.

The seed-adoption path (`KpMaintenanceDecision::SeedD`) still adopts whatever non-empty `d` a
relay is already serving with **no width or hex validation**, and that is now self-correcting
rather than terminal: the retirement runs ahead of the maintenance decision, so an adopted
malformed slot is re-pointed before anything is published into it.

Proofs: the pure decision, the two builders and their guards in
`haven-core/src/relay/maintenance/key_package.rs`; the migration end-to-end over an in-process
relay in `haven/rust_builder/src/api.rs` (`tc8_a_pre_fix_install_is_retired_onto_a_conformant_slot_via_real_ffi`,
`tc9_a_conformant_install_is_never_retired_via_real_ffi`,
`tc10_no_retraction_until_the_replacement_is_acked_via_real_ffi`,
`tc11_an_already_published_replacement_is_adopted_via_real_ffi`,
`tc12_a_conformant_account_scrubs_a_leftover_orphan_via_real_ffi`,
`tc13_a_refused_retraction_leaves_the_migration_open_via_real_ffi`,
`tc14_a_never_acked_retraction_does_not_starve_rotation_via_real_ffi`,
`tc15_an_unreadable_row_is_retired_onto_fresh_material_via_real_ffi`).

**Legacy 443 residue**: Haven no longer builds 443 twins. A one-time, sentinel-gated cutover
retraction (`LEGACY_KP_RETRACTION_DONE_KEY`) probes the user's own relays for their old 443 and
10051, then publishes a **kind-5 deletion of the 443 by event id only** (self-authorship-guarded;
deliberately **no `a` coordinate** — 443 is non-addressable, and a `443:<pubkey>:` coordinate
would tell relays to delete *every* 443 by the author) plus an **empty replaceable kind-10051**.
The invite-side fetch filter keeps `kinds([30443, 443])` **only** for batched un-migrated-member
detection ("needs to update" UX); **selection is 30443-only**.

### Welcome (kind 444 inside kind 1059)

Skeleton unchanged from the MIP era: a NIP-59 kind-1059 gift wrap around an **unsigned kind-444
rumor**; rumor content = **base64** welcome bytes. What is new is **strictness** (validated both
directions by the peeler):

- **Exactly one `e` tag** — the KeyPackage event id (30443) the welcome consumed.
- **Exactly one `relays` tag** — the group's relay set, and it must be
  **non-empty, ≤16 entries, each URL ≤512 bytes, ws/wss only**, or the peeler's
  `wrap_welcome_with_metadata` fail-closes. Haven pre-validates via `validate_group_relays`
  (`manager.rs`) before every create/invite so the error surfaces cleanly.
- **CRITICAL (Security Rule 3)**: kind-444 events MUST NOT be signed (only the NIP-59 seal is
  signed) — unchanged, still enforced.

**Ingest semantics changed**: feeding a 1059 into `session.ingest` **auto-joins** the group
(engine `join_welcome` → `GroupEvent::GroupJoined`). There is no pending/declined MLS state
upstream — see [hold-before-ingest](#hold-before-ingest-welcomes-accept--decline) for how Haven
preserves its accept/decline UX.

### Group message (kind 445)

```json
{
  "kind": 445,
  "pubkey": "<fresh ephemeral pubkey — new per message, never reused>",
  "content": "<base64( 12-byte-nonce ‖ ChaCha20-Poly1305 ciphertext )>",
  "tags": [
    ["h", "<nostr_group_id, lowercase hex>"],
    ["expiration", "<application messages ONLY — absent on commits/proposals>"]
  ]
}
```

- **Outer AEAD**: ChaCha20-Poly1305, 32-byte key = `MLS-Exporter("marmot", "group-event", 32)` —
  the label string is `DEFAULT_EXPORTER_LABEL = "marmot/group-event"`
  (`transport-nostr-peeler/src/lib.rs:37`). 12-byte CSPRNG-random nonce prepended to the
  ciphertext, then base64. **The AAD is the empty byte string** and is never serialized (the
  peeler fail-closes on non-empty AAD). This is the same AEAD *shape* as the old stack — the
  **only** crypto change vs the MIP era is the exporter label (`"nostr"` → `"marmot/group-event"`),
  which alone makes old and new 445s mutually undecryptable.
- **NEVER call the peeler's `with_exporter_label` override** — it is the only local lever that can
  downgrade the 445 exporter derivation (Security Rule 11, CI-guarded).
- **Tags**: **exactly one `h` tag is enforced on ingest; all other tags are silently dropped**
  (`transport-nostr-peeler/src/event.rs` — enforcement is exactly-one-`h`; the spec's "MUST NOT
  carry other tags" is an emit-side rule). Haven emits `h` alone on commits and proposals, and
  `h` + NIP-40 `expiration` on application messages — nothing else, ever (see **Expiration**
  below). `causal_deps` is no longer parsed; the old `["encoding","base64"]` tag is no longer
  emitted.
- **`created_at` binding**: the outer event's `created_at` is bound to the inner app event's
  `created_at` for application messages (upstream #630) — a receiver cross-checks them.
- **Expiration**: NIP-40 `expiration` is driven by the **group-level**
  `marmot.group.message-retention.v1` component (0x8005), not a per-send parameter. Haven **does**
  configure it: `create_group` installs 0x8005 with `LOCATION_MESSAGE_RETENTION_SECS` (228 s) into
  every circle (`src/nostr/mls/manager.rs`, constant in `src/location/ttl.rs`), and the peeler
  stamps `["expiration", inner_created_at + 228]` on every **application** 445. Commits and
  proposals carry **no** expiration tag.
  - **A JOINED circle may declare no component at all** (its creator was an older Haven build or
    another Marmot client). The engine then reports `None` for the group and stamps **nothing** —
    which both un-bounds relay residency AND makes the location update read as a membership
    change. Haven bounds this on the send side: `RetentionBoundPeeler`
    (`src/nostr/mls/retention.rs`) is the `TransportPeeler` the session installs, and it supplies
    228 s when the group declares none or zero, caps a longer group policy to 228 s, and honours a
    shorter one. So **every application 445 leaving this device is stamped, in every circle**;
    what the component still decides is what every OTHER member's client does.
  - Consequence for a relay observer: `expiration` presence is a free
    application-vs-control discriminator, and `expiration - created_at == 228` **exactly** is a
    Haven build fingerprint — now also a PER-MEMBER one inside a circle whose declared window is
    absent, zero, or LONGER than 228 s, where Haven's 228 s no longer matches what that circle's
    other clients stamp (or do not). A circle declaring SHORTER is the one foreign case with no
    per-member split: Haven honours that value and stamps it exactly as every other client does.
    All accepted, all wire-visible; see "Metadata Considerations" below.
  - Consequence for tests: an application 445 is evicted by any NIP-40-honouring relay 228 s after
    publication, so an oracle that re-queries them late sees only commits. Capture at publish
    time, not by a late `REQ`.
- **Ephemeral key per message** (Security Rule 2): the peeler generates and signs with a fresh
  keypair per 445; asserted upstream and by Haven's re-expressed uniqueness gate.

### Inner application messages (`MarmotAppEvent`)

The decrypted 445 payload is a `MarmotAppEvent`: an **unsigned** Nostr-shaped inner event with
**strict validation** (engine-enforced on ingest, `InvalidAppMessagePayload`):

- `id` MUST be the **canonical NIP-01 id** over the serialized fields.
- `pubkey` MUST equal the **MLS-authenticated sender's identity** — the engine validates this on
  ingest, and Haven *also* fail-closes on send (`SessionManager::create_message` rejects a rumor
  whose pubkey is not the local identity).
- **No `sig`** field.

**Inner tags are application content, and nothing else.** "Decoders do not police inner tag names.
Tags carry application content; the active transport binding builds the outer envelope's routing
tags from group state, never from the inner event, so an inner tag never affects delivery"
(`foundation/application-messages.md`, adopted); "An inner tag therefore carries application
content only: it never affects addressing, routing, expiry, or branch selection"
(`protocol-core/group-messaging.md`). The MIP-03-era "MUST NOT include `h` tags or any group
identifier" was **replaced by that framing and no longer exists in the spec**. So emitting no tags
at all is trivially conformant; dropping the old `["t","location"]` hashtag was a metadata
improvement, not a compliance fix; and the kind-9 receive gate below reads a `t` tag as application
content — exactly what the spec says it is — not as a protocol-layer read.

Kinds inside the tunnel:
- **kind 25442** (`KIND_LOCATION_UPDATE`, `haven-core/src/nostr/event.rs`) — Haven's location
  updates: the `LocationMessage` JSON as content and **no tags at all**. The kind, not a tag, is
  what marks a payload as a location update, on both sides (`location_rumor` /
  `is_location_rumor`, `haven-core/src/nostr/mls/manager.rs`).
- **kind 1210** — engine-generated **system rows** (membership changes, renames, retention
  changes; backs `GroupStateChanged`).
- **kind 9** — Marmot's chat message. Haven never sends it, and accepts it inbound only when it
  carries `["t","location"]`; see below.

`inner_location_content` gates on the kind before touching the content. An inner event of any
other kind yields empty content, which still surfaces as `LocationMessageResult::Location` with
no location — the caller sees that an authenticated message arrived at this cursor position and
advances past it, rather than treating a peer's chat message as a retriable decrypt failure.
Before this gate every authenticated inner event reached the map layer, excluded only by failing to
deserialize as a `LocationMessage` — a weak filter, because `deny_unknown_fields` is deliberately
**absent** from that struct (an old client's payload still carrying `display_name` must parse, not
hard-fail; pinned by a wire-compat test in `haven-core/src/location/types.rs`), so any foreign
payload carrying the five location keys rendered as a member marker.

#### Why Haven's inner kind is not 9

Kind 9 is `MARMOT_APP_EVENT_KIND_CHAT`, Marmot's default chat kind, so an MDK-based client draws
anything sent on it as chat: the chat-list preview, the unread/mention scan
(`storage-sqlite/src/chat_list.rs`, `marmot-app/src/notifications.rs`) and the notification
classifier (`is_notifiable_message_kind`) are all kind-9 allowlists — White Noise would render a
Haven circle as a stream of unreadable messages with unread badges and push notifications. An
unrecognised kind takes the other path: MDK's timeline projection drops it with
`_ => return Ok(None)` (`storage-sqlite/src/timeline.rs`), so it never becomes a row at all.
Marmot's `foundation/application-messages.md` (adopted) permits exactly that: "Protocol
processing MUST NOT reject an otherwise-valid app payload merely because its event kind is
unknown", and "A client MAY ignore or decline to render unsupported application semantics after
delivering the accepted payload to its application layer". A foreign kind is delivered and then
silently ignored, which is the behaviour Haven wants.

This is an application-layer contract with other Marmot clients, not a Nostr-registry matter: the
inner kind exists only after MLS decryption and never reaches a relay.

**25442** was drawn at random from the ephemeral band (NIP-01: `20000 <= n < 30000`) and checked
unallocated in `nostr-protocol/registry-of-kinds`, the NIPs README kind table, MDK, and Haven.
The band choice is descriptive only — no relay ever classifies this kind.

**Never reuse these inner kinds.** Marmot's registry (`foundation/registries.md`) allocates
`9` chat, `447`/`448`/`449` push-token update/list/removal, `1009` message edit, `1200` agent
text stream start, and `1210` group system rows. `1201`/`1202` (agent activity/operation) read as
"reserved for possible experimental" use in the registry, but are already live in MDK: both are
`cgka-traits` constants and its timeline projection renders both as rows. `446` is the
push-notification rumor; `450`/`451`/`452` are local signing templates that MUST NOT be published.
MDK additionally defines `5` (delete) and `7` (reaction) as inner app kinds. Haven's collision test
also reserves `1209`, which is **not** an allocation — it is in no Marmot registry and no MDK rev —
but deliberate margin next to `1210`.

**Upstream registration of 25442 is advisable, not required.** "The registry is not an allowlist
of inner event kinds" (`foundation/application-messages.md`) — an unallocated kind is conformant on
its own, and other clients handle 25442 under the ordinary unknown-app-event rules. The registry's
"Future adoption MUST add their exact semantics to the main table before relying on them for
interoperability" governs Marmot's own reserved `1201`/`1202` and future *Marmot-defined* app-event
kinds; it does not bind a third party choosing an unallocated number. Filing an entry is still
worth doing, because Marmot defines no third-party or private-use range for inner app kinds:
nothing else stops a future Marmot allocation from landing on 25442.

**The kind-9 receive window is transitional and deliberately narrow.**
`LEGACY_KIND_LOCATION_UPDATE` is accepted on receive only when the rumor also carries
`["t","location"]`. Every Haven build that can still share a group with a current one (v0.1.11,
v0.1.12 — anything earlier is pre-Dark-Matter and cannot decrypt a current 445 at all) stamped
that hashtag, while a White Noise chat message is a bare kind 9. The pair is what keeps a
not-yet-updated member on the map without admitting one chat message. Nothing constructs a rumor
at kind 9 any more.

### Account identity proof (kind 450 — embedded, never published)

The mandatory leaf extension `marmot.account-identity-proof.v2` (`0xF2F1`) contains a Schnorr
signature by the **Nostr identity key** over the canonical NIP-01 id of a kind-450 event with
`created_at = 0` and `d` = `"marmot.account-identity-proof.v2"`, binding
`account identity pubkey ↔ MLS leaf signature public key`. Version byte = 2.

- **Haven never publishes kind-450 to relays.** It exists only inside MLS leaves
  (KeyPackages, Welcomes, the ratchet tree).
- The engine rejects any leaf without a valid proof (`InvalidAccountIdentityProof`) — this is what
  makes the old-client leaf format hard-incompatible (wire break W7).
- Haven's signer (`haven-core/src/nostr/mls/signer.rs`, `HavenIdentityProofSigner`) is
  **hardened** (security F1): it recomputes the canonical proof event itself and signs only that
  id (never a caller-supplied digest), refuses requests for a foreign `account_identity`, and is
  purpose-scoped over Zeroizing secret bytes (not a general `NostrSigner`) — so it can never be
  used as a blind identity-key oracle. Domain separation vs kind-0/24242 signing is inherent
  (kind 450, `created_at=0` → distinct NIP-01 id).
- **Threat note (F12)**: any co-member can extract the proof from your leaf and rebroadcast a
  valid identity-key-signed kind-450 to relays, publicly binding your pubkey to MLS
  participation. Irreducible by design (co-members already see the credential); recorded in
  `haven-core/SECURITY.md`.
- **API stability caveat**: upstream mdk#755 plans to move proof construction/verification to the
  app/session signer-adapter boundary — the `AccountIdentityProofSigner` API is expected to churn.

---

## App Components

The MIP-01 `NostrGroupDataExtension` (`0xF2EE`) is gone. Group metadata now lives in the MLS
`app_data_dictionary` (extensions-draft-08 "safe extensions") as **signed, group-scoped app
components** (`crates/traits/src/app_components/mod.rs`); changes go on-wire as
`SendIntent::UpdateAppComponents` / `UpdateGroupData` commits, validated engine-side.

| ID | Component | Purpose | Haven use |
|----|-----------|---------|-----------|
| 0x0001 | app-components dictionary | Advertises supported/required component ids | implicit |
| 0x0002 | SafeAAD | SafeAAD framing advertisement | not used |
| 0x8001 | `marmot.group.profile.v1` | Group name + description | ✅ (create_group name/desc) |
| 0x8002 | `marmot.group.blossom.image.v1` | Group image via Blossom | not used |
| 0x8003 | `marmot.group.admin-policy.v1` | Admin set / policy | ✅ (admin gating) |
| 0x8004 | `marmot.transport.nostr.routing.v1` | **`NostrRoutingV1 { nostr_group_id: [u8;32], relays }` — THE source of the 445 `h`-tag id + group relay set** | ✅ (minted at create with a random 32-byte id) |
| 0x8005 | `marmot.group.message-retention.v1` | NIP-40 expiration policy | ✅ (minted at create with `LOCATION_MESSAGE_RETENTION_SECS` = 228 s; application 445s only; read back via `SessionManager::group_message_retention_secs`, and bounded on send by `RetentionBoundPeeler` for circles that declare none) |
| 0x8006 | `marmot.group.agent-text-stream.quic.v1` | Agent QUIC streams | not used |
| 0x8007 | `marmot.group.avatar-url.v1` | Group avatar URL | not used |
| 0x8008 | encrypted media | MIP-04 successor (Blossom, per-file keys) | not used |

- **Rule 4 privacy split preserved**: `GroupId` (the MLS id) is engine-internal and never
  published; `NostrRoutingV1.nostr_group_id` is the pseudonymous transport id
  (`session.app_component(gid, NOSTR_ROUTING_COMPONENT_ID)` →
  `SessionManager::group_routing/nostr_group_id_hex`).
- Haven configures `supported_app_components([0x8001, 0x8003, 0x8004, 0x8005])` at session open so
  its KeyPackages advertise support and self-invite/create pass capability validation.
- Per-user profiles are **not** app components (group-scoped only) — user profiles are plain
  Nostr kind-0 (see the spec-restructure section).

---

## MDK "Dark Matter": The Engine Haven Runs

### Crate set and pin

```toml
# haven-core/Cargo.toml — all five at ONE released-tag rev (v0.9.4)
cgka-session           = { git = "https://github.com/marmot-protocol/mdk", rev = "e391adc133a9b60e420da7a0446f014a180ac8d2" }
cgka-engine            = { git = "https://github.com/marmot-protocol/mdk", rev = "e391adc..." }
cgka-traits            = { git = "https://github.com/marmot-protocol/mdk", rev = "e391adc..." }  # dir crates/traits
storage-sqlite         = { git = "https://github.com/marmot-protocol/mdk", rev = "e391adc..." }
transport-nostr-peeler = { git = "https://github.com/marmot-protocol/mdk", rev = "e391adc..." }
```

There is **no `mdk-core` crate anymore.** Constraints that ride along: `rusqlite 0.32` /
`libsqlite3-sys 0.30` (`links = "sqlite3"` — one version per graph, so `circles.db`/`tiles.db`
share the pin), openmls `~0.8.1` with `extensions-draft-08` (enters the graph only through the
engine — Haven has no direct openmls dep), toolchain ≥ 1.90 (upstream is edition 2024).
CI guards: single-version `cargo tree` gates; `uniffi`/`quic`/`agent` crates must stay OUT of the
graph; `marmot-forensics` is audited as an unconditional transitive dep.

### The session model

One **`AccountDeviceSession`** per account-device, opened over one SQLCipher DB
(`session.sqlite`). `open()` is sync and **hydrates authoritative group state into memory**;
every mutating call takes `&mut self` and is `async`. Haven wraps it in
`tokio::sync::Mutex<AccountDeviceSession>` inside `SessionManager`
(`haven-core/src/nostr/mls/manager.rs`) — every session-touching Haven method is therefore
`async`, including the engine's sync reads (they take the same lock).

```rust
SessionConfig::new(db_path, SqlCipherKey::new(passphrase)?, identity /*32B x-only pk*/,
                   // RetentionBoundPeeler wraps the real peeler so every application
                   // 445 is stamped even in a circle that declares no 0x8005.
                   Box::new(RetentionBoundPeeler::new(
                       NostrMlsPeeler::new().with_welcome_signer(keys))))
    .account_identity_proof_signer(signer)      // REQUIRED — open() errors without it
    .supported_app_components([0x8001, 0x8003, 0x8004, 0x8005])
    .convergence_policy(CanonicalizationPolicy { settlement_quiescence_ms: 0, ..default() })
    .feature_registry(self_remove_feature_registry());
let session = AccountDeviceSession::open(config)?;   // sync; hydrates
```

> **Rule 14 (Security, CRITICAL): at most ONE live `AccountDeviceSession` per MLS DB file across
> all isolates/processes.** Two sessions hydrate two divergent in-memory epoch states — not just
> DB corruption but **epoch/exporter-key reuse, i.e. a confidentiality loss**. `storage-sqlite`
> has no OS-level file lock to save you. Haven enforces this structurally: the only
> `AccountDeviceSession::open(` site in the tree is `SessionManager::open_session` (guard test
> `single_account_device_session_construction_site`), and the background-catchup path reuses the
> one process-global `SessionManager` (the old `write_lock.rs` regime is deleted — the session
> mutex subsumes it).

### Ingest and the event stream

```
Event (445/1059) → event_to_transport_message → session.ingest(msg).await
                → IngestEffects { outcome, effects }
```

- **`IngestOutcome::Processed`** — applied; advance your receive cursor.
- **`IngestOutcome::Buffered { group_id, epoch }`** — future-epoch/out-of-order; the engine
  persisted it durably and will replay it. **Never advance the cursor past a Buffered event.**
  The replay comes back in the batch of whatever call RELEASED it — a `confirm_published`, a
  `publish_failed`, an `advance_convergence`, or the convergence settle inside the next `send` —
  and it comes back **once**; see "What a resolved publish hands back" below.
- **`IngestOutcome::Stale { reason }`** — non-error terminal:
  `StaleReason::{AlreadySeen, AlreadyAtEpoch, NotForThisClient, UnknownGroup, OwnEcho,
  PeelFailed, SelfEvicted, Quarantined}`. Advance the cursor.

Application-visible results arrive as an **ordered `GroupEvent` stream** in `effects.events`
(also from `advance_convergence` and `confirm_published`):

| GroupEvent | Meaning | Haven folding (`location_result_from_event`) |
|---|---|---|
| `MessageReceived{group_id, sender, epoch, payload}` | Decrypted inner app message | `Location` (content extracted from the MarmotAppEvent JSON) |
| `GroupJoined{..}` | Welcome accepted, group joined | `Joined` |
| `EpochChanged` / `GroupStateChanged{change, actor, ..}` | Commit applied (membership/admin/rename/retention) | `GroupUpdate` |
| `AppMessageInvalidated` / `GroupStateInvalidated` | Earlier output withdrawn by branch selection — treat as if it never happened | `Invalidated` |
| `GroupUnrecoverable` | Fork/quarantine terminal state — UI must block send/mutate | `Unrecoverable` |
| `PendingCommitRecovered` | Crash between publish and confirm; staged commit cleared at hydrate | **mandatory resync** (Rule 13) |
| `GroupCreated`, fork-recovery bookkeeping (`ForkRecovered`, `CommitRolledBack`) | Bookkeeping | `None` |

A `GroupStateChanged` whose removed member is THIS device (`realize_self_eviction`,
`ingest.rs:1536-1545`) carries the same `GroupUpdate` folding as any other roster move: the fold
is by variant, not by whose leaf went. Every receive plane therefore renders a self-eviction as a
generic refresh signal rather than as "you were removed"; the circle still stops sending, because
the engine's own gate refuses it. Known coarseness, pre-existing on every plane, and deliberately
not special-cased.

### Publish-before-apply (Rule 13)

Mutations (`SendIntent::{Invite, RemoveMembers, UpdateGroupData, UpdateAppComponents}`, group
creation, and engine auto-commits) come back as `SessionEffects.publish` items:

- `PublishWork::ApplicationMessage { msg }` — publish once; no pending ref (app messages don't
  advance the epoch).
- `PublishWork::Proposal { msg }` — e.g. a `SelfRemove`; publish-and-forget, no pending ref.
- `PublishWork::GroupEvolution { msg, welcomes, pending }` / `GroupCreated { .., pending }` /
  `AutoPublish { .., pending }` — **staged, not applied**. Haven publishes the transport
  message(s) through its own relay layer, then calls:
  - `confirm_published(pending)` — **ONLY after ≥1 relay returned an OK-ack** ("acked" means
    acked, never merely "sent"). The engine merges the staged commit and emits the epoch change.
    Welcomes are published only AFTER confirm.
  - `publish_failed(pending)` — the engine discards the staged commit and returns the group to
    `Stable` at the prior epoch.

Between stage and confirm the group is `EpochState::PendingPublish`; inbound messages get
`Buffered` and replay on return to `Stable`. A crash in the window → hydrate clears the staged
commit and emits `PendingCommitRecovered` → treat as a **mandatory resync**. ~~That covers every
staged commit.~~ **CORRECTED 2026-09-05 — it does NOT cover the removal-bearing ones, which is the
case that matters most.** `staged_removes_member` (matching `Proposal::Remove | Proposal::SelfRemove`)
short-circuits the whole emit block at hydrate (`cgka-engine/src/engine.rs:820-828`), deliberately:
rolling a removal back would re-add the departed member and fork convergence. So a peer `SelfRemove`
auto-commit killed between publish and confirm emits **nothing** — no `PendingCommitRecovered`, no
resync signal — and a re-fetch of one's own commit comes back `Stale { OwnEcho }` from the durable
`MessageState::Sent` row (`message_processor/store.rs:24-27`, consulted before any MLS processing at
`ingest.rs:417-420`), so re-downloading it applies nothing.

**And `publish_failed` is not an escape.** Rolling a peer `SelfRemove` auto-commit back DROPS the
removal permanently and silently: the engine removes its in-memory
`scheduled_self_remove_auto_commits` entry before staging, `do_publish_failed` does not re-arm it,
and a redelivery of the proposal short-circuits to `Buffered` off its durable `Created`
`MessageRecord` without reaching the arm that reschedules. Verified by source and by experiment at
`e391adc`: no later `advance_convergence`, no re-ingest, no outbound send and no restart re-derives
it — until some unrelated commit moves the epoch, after which the leaver's own client re-proposes
(`message_processor/send.rs:718-725` gates the re-proposal on exactly that). So a receive plane
holding an `AutoPublish` has exactly three dispositions — publish it, park it
as a durable obligation for a foreground pass (`ReceiveAutoCommitPolicy::DeferToForeground`), or drop
the removal.

Two further consequences, both verified by experiment at `e391adc` and both invisible from every
engine read accessor:

- **A rollback does not restore the circle's sends.** `do_publish_failed` clears the staged COMMIT
  but not the stored PROPOSAL, and `OpenMLS`'s `create_message` refuses while the proposal store is
  non-empty. The next send fails `create_message: GroupStateError(PendingProposal)` and keeps failing
  until some commit merges and empties the store. Rolling back trades a `PendingPublish` refusal for
  a `PendingProposal` one.
- **After a process restart the two layers disagree, and only the send gate can tell.** `EpochManager`
  is in-memory (`cgka-engine/src/epoch_manager.rs` — plain `HashMap`s, `Default`), and hydrate ends by
  calling `set_stable(group.epoch)` unconditionally (`engine.rs:882`) on a record whose epoch was
  already projected PAST the leave. So a group carrying an unrecovered removal-bearing staged commit
  reports `Stable` at epoch N+1 with the leaver already gone from `members`, while `OpenMLS` is still
  at N with the commit staged. `epoch`, `members`, `group_record` and `current_safe_export_epoch` all
  read the projection; a send is the only thing that reports the truth.

Full analysis: `docs/POWER_EFFICIENCY_PLAN.md` §4 OD4-c and §5.4; the owner's decision
(both halves) is implemented in `haven-core/src/relay/auto_commit.rs` +
`live_sync/processor.rs`. The old
`merge_pending_commit`/`clear_pending_commit`/staged-commit-marker machinery is deleted — the
typed `PendingStateRef` lifecycle owns it.

#### What a resolved publish hands BACK

`confirm_published` and `publish_failed` do not resolve a ref and stop. Both end in
`replay_buffered_messages` (`cgka-engine/src/publish.rs:255` and `:331`), and both return a full
`SessionEffects` — which is **a one-shot drain of GLOBAL engine buffers**: `events` (every
`MessageReceived` the window buffered, plus the epoch change), `pending_convergence`, `publish`
and `queued`. Dropped means gone; nothing re-requests any of it.

- **A replayed `MessageReceived` is delivered AT MOST ONCE**, and the engine writes the content
  row `Processed` in the same breath (`message_processor/ingest.rs:760-771`), after which every
  redelivery answers `Stale { AlreadySeen }` (`message_processor/store.rs:24-39`). There is no
  application-acknowledgement boundary, so a caller that folds the batch without persisting loses
  the fix for good. Haven persists INSIDE the call
  (`CircleManager::persist_locations_from_events`), keyed off each event's OWN `group_id`: the
  buffers are global, so one batch can span circles and an ambient id would file a peer under a
  circle they are not in.
- **A peer `SelfRemove` buffered behind a staged commit surfaces on the ROLLBACK rung, never on
  the confirm.** A confirm merges first, so its replay runs at epoch N+1 and a proposal bound to
  epoch N is already dead; `publish_failed` discards the staged commit and replays at the
  ORIGINAL epoch, where the proposal still applies. It arrives as `pending_convergence = [group]`
  with an **empty** `publish` — the eviction `AutoPublish` only materialises on the following
  `advance_convergence` — so a caller that drops `pending_convergence` strands the leave with
  nobody committing it. Haven drains it in the same call
  (`CircleManager::fold_resolved_publish`), with one bounded re-tick budget per call because the
  engine's auto-commit due time is a real `Instant`.
- **An `Err` from `confirm_published` can mean "applied, replay failed".** The durable merge and
  `epoch_manager.confirm_publish` both PRECEDE the replay, and `cgka-session` propagates the
  replay's `?` before `collect_effects` runs — so the caller gets an error and **no** effects
  while everything already emitted sits in the engine's buffers. Never `publish_failed` after it
  and never retry: both act on a commit the group may already hold. Haven drains the stranded
  buffer (`SessionManager::drain`), folds and persists it, and returns the original error
  unchanged.
- **The send path is the same drop at higher frequency.** `do_send` settles stored convergence
  before it encrypts (`should_queue_outbound_intent` → `advance_convergence_inputs_until_settled`
  → `retry_deferred_peels`), so a peer message that could not be peeled when it arrived is
  re-ingested into THAT send's own batch. Haven persists it there too
  (`CircleManager::note_send_drain`, called by all four `take_*` extractors) — which is why a
  location publish cycle is a receive path as well as a send one. An eviction `AutoPublish` the
  same drain co-surfaces (always another circle's — a same-circle staging answers `Queued` and
  takes the deferred branch) is recorded as OWED and not handed to the caller; the engine never
  re-emits it, so `redeem_removal_deferrals` on a foreground live-sync open is its only publisher.
  Residual and the flag-off hole: `haven-core/SECURITY.md`.

### Convergence (the concurrent-commit cure)

The engine owns what Haven used to hand-roll (settle windows, `commit_order_key`, the #633
un-poison workaround — all deleted):

- Every inbound is persisted in the **stored-convergence buffer** with a typed
  `MessageState::{Retryable, PeelDeferred, …}`; future-epoch app messages sit `Retryable`,
  un-peelable ones `PeelDeferred` (retried against retained group snapshots).
- **`advance_convergence(&group_id)`** releases queued work and buffered messages that are now
  safe to apply; call it after ingest batches (`drain_pending_convergence_groups` schedules extra
  ticks). Haven's live-sync processor ticks it after each batch.
- Same-epoch concurrent commits are resolved by **deterministic `CommitOrderingKey` branch
  selection** — `(source_epoch, priority: Privileged > Ordinary, committer, commit_digest)` —
  losers roll back with `…Invalidated` events; even an own *confirmed* commit can lose
  (`GroupStateInvalidated{SupersededByBranchSelection}`). Unresolvable forks →
  `ForkedEpoch` / `GroupUnrecoverable`. The selector/lifecycle/delivery-order are
  Tamarin-modelled upstream — which does **not** substitute for Haven's empirical black-box e2e
  gates (the out-of-order convergence e2e is retained as the F2 gate).
- Upstream **#633** (sticky-`Unprocessable` epoch poison) is fixed by this design; Haven's local
  `retry_failed_future_epoch_messages` workaround is deleted.
- **#757 (OPEN — re-confirmed by `gh api` on 2026-09-05, and still open at MDK v0.9.18)**: the
  buffer has **no per-group cap and no eviction API** — a malicious member
  can grow durable storage with future-epoch messages. Haven mitigates with intake backpressure
  (Rule 12: rate-limit, NEVER silently drop legitimate offline backlog), but an intake cap
  throttles only — it cannot bound engine storage. #757 closure is the real fix.
- **`replay_buffered_messages` retires only `PeelDeferred` rows** (`message_processor/mod.rs`
  `:890-900`): a raw `Retryable` row stays `Retryable` after its content has been applied, and it
  is that row a catch-up cursor is pinned behind. So a resolved publish delivering the buffered
  location does **not** move the cursor, and a green "the fix surfaces on confirm" test must not
  be read as having unpinned it. MDK-side, unreported; owner directive is to leave MDK alone at
  this pin.

### Leave / SelfRemove

- `SendIntent::Leave { group_id }` → a MIP-03 **SelfRemove proposal** (`PublishWork::Proposal`,
  no pending ref — the leaver does not commit its own removal).
- Any remaining member's engine **auto-commits** the proposal
  (`PublishWork::AutoPublish { pending, .. }` — publish, then `confirm_published` on ≥1-relay
  ack like any evolution).
- Admin gating: `AdminCannotSelfRemove` / `AdminDepletion` — an admin must leave the admin set
  first (Haven's `plan_leave` maps this onto its promote-successor/self-demote state machine).
- **Required capability — the self-remove feature registry (load-bearing!)**: the engine's default
  `FeatureRegistry` is EMPTY, so leaves would advertise no `self-remove` proposal capability and a
  peer's auto-commit would fail `ProposalValidationError(UnsupportedProposalType)` — i.e. leaving
  would be silently broken. Haven registers `Feature("self-remove")` →
  `Capability::Proposal(10)` at `RequirementLevel::Required` on every session
  (`self_remove_feature_registry()` in `manager.rs`), which makes `fresh_key_package` advertise
  it and `create_group` require it. This matches the 30443 `mls_proposals` tag (`0x000a` = 10).
- The leaver-side backstop (poll `still_a_member`, re-issue a fresh SelfRemove on a bounded
  budget, durable resume marker) is retained in Haven's circle layer.

### Exporter secrets

`session.exporter_secret(&gid, label, len) -> SecretBytes` (= `Zeroizing<Vec<u8>>`), current
epoch. Retention: `DEFAULT_MAX_PAST_EPOCHS = 5` (`cgka-engine/src/wire_format.rs:38`; replaces
the old name `DEFAULT_EPOCH_LOOKBACK` — same number). Haven does not override it (Rule 5), and
holds essentially no exporter secrets app-side anymore — the peeler owns the 445 crypto.

### Errors

`EngineError` is typed (`UnknownGroup, NotGroupAdmin, AdminCannotSelfRemove, AdminDepletion,
MissingRequiredCapabilities, UnsupportedCiphersuite, InvalidAppMessagePayload,
InvalidAccountIdentityProof, InvalidKeyPackageLifetime, ForkedEpoch, Storage(..), Peeler(..),
…`); `PeelerError::{Malformed, DecryptFailed, StaleEpoch, MissingContext, WrapFailed, Backend}`.
Retryability: `EngineError::is_transient()` (only `StorageError::Busy`); message-level retry is
the `MessageState` machine; `StaleReason` classifies non-errors. **#864 is open** (five
validators embed full group-id hex) — Haven keeps `redact_hex_sequences` at the
`map_mls_err` boundary (Rules 6/8). Note: a never-seen group surfaces as
`Storage(NotFound)`, while `UnknownGroup` means a *quarantined* group (mdk#364) —
`SessionManager::find_group` maps both to `Ok(None)`.

---

## Haven-Specific Choices

These are Haven decisions layered on the engine — not upstream defaults. Do not "simplify" them
away.

### Hold-before-ingest welcomes (accept / decline)

Upstream has **no Declined state**: ingesting a 1059 auto-joins, and the reference app's decline
is join-then-Leave — **visible on the wire and consumes the invite**. Haven preserves its
decline-leaves-no-trace semantics (Rule 10) by never ingesting until the user accepts
(`haven-core/src/nostr/mls/welcome.rs`):

- Inbound 1059s route to the **`PendingWelcomeStore`**, which holds the
  **still-NIP-59-encrypted** gift wrap only (F3: the decrypted welcome bytes carry group-join
  secrets and are NEVER stored; the relay/live-sync pipeline must NOT auto-ingest 1059s).
- **Preview** (`SessionManager::preview_welcome`) uses a standalone peeler `peel_welcome` —
  engine-independent, non-joining — and retains only the inviter pubkey; the decrypted welcome
  bytes are dropped unbound. Group name/relays are unavailable pre-join by design (they live
  inside the encrypted welcome).
- **Accept** = ingest the held 1059 (`accept_welcome`) → engine peels + joins → `GroupJoined`.
- **Decline** = `PendingWelcomeStore::remove` — a local drop; nothing on the wire.

### Convergence policy: `settlement_quiescence_ms = 0`

The engine's default quiescence (1000 ms) means a lone commit ingests as `Buffered` and a single
ingest+advance pass won't release it — the commit can sit until an unrelated later event re-ticks
`advance_convergence`: exactly the delivery-stall class Haven fought pre-migration. Haven sets
**quiescence 0** (immediate settlement) at session open. Fork-safety is preserved: deterministic
`CommitOrderingKey` branch selection and future-epoch buffering (the F2 gate) are independent of
quiescence — only the same-epoch sibling settle *delay* is removed. Flagged for re-review if
concurrent-commit reorg churn (visible flip → deterministic re-converge) becomes material at
larger group scale.

### Single session (Rule 14) and locking

See the boxed rule above. Practical shape: `SessionManager` holds the one
`tokio::sync::Mutex<AccountDeviceSession>`; the mutex guard is held across the mutators' internal
awaits (hence a tokio, not std, mutex); the M7 background-catchup path shares the same manager
instead of opening a second session; `write_lock.rs` is deleted.

### SQLCipher key custody (`session.sqlite`)

`storage-sqlite` takes a **passphrase** (`SqlCipherKey`, PBKDF2 via `PRAGMA key = '<str>'`,
`cipher_compatibility = 4`) and does not touch the platform keyring — Haven provisions the key
(`haven-core/src/nostr/mls/storage.rs`): mint 32 `OsRng` bytes once, store the RAW bytes in the
keyring under (`com.oblivioustech.haven`, **`mls.session.key.default`**), derive the passphrase
as their lowercase-hex encoding (64 chars, `Zeroizing` end-to-end, never logged). The PBKDF2
stretch is defense-in-depth over already-256-bit material. This is deliberately **incompatible**
with `circles.db`/`tiles.db`, which keep the raw-key form (`PRAGMA key = "x'<64-hex>'"`, KDF
bypassed). Storage options are the hardened defaults: **WAL** (the old DB was rollback-journal),
`secure_delete`, `cipher_memory_security`. The legacy `haven_mdk.db` + its `mdk.db.key.default`
keyring entry are deleted/destroyed at cutover — **key destruction is the practical secure-erase**
(security F6). iOS: the new key gets the same `AfterFirstUnlockThisDeviceOnly` policy migration.

### Haven keeps its own relay plane

Subscriptions, cursors, per-relay fan-out, health, catch-up sweeps, and the gift-wrap
**multi-relay cascade** stay Haven-owned (`transport-nostr-adapter` not adopted). The peeler owns
the 1059 *crypto*; Haven's old `giftwrap` decrypt path is deleted. Raw `Event` ↔
`TransportMessage` conversion via `NostrTransportEvent`
(`SessionManager::event_to_transport_message` / `transport_message_to_event`).

---

## Old vs New: Migration Reference

For developers reading pre-2026-07 Haven code, tests, or git history. Any ONE of the starred (★)
rows independently breaks cross-version interop — there is no bridge mode (no 443 reader, no
`0xF2EE` parser, no `"nostr"`-label fallback) — which is why the migration was a hard flag-day
with wipe-and-recreate of all MLS state (identity/nsec, kind-0 profile, and petnames survived).

| Surface | OLD (MIP era / mdk-core 0.7.1) | NEW (Dark Matter v0.9.4) |
|---|---|---|
| ★ KeyPackage kind | 443 (regular event, `encoding` tag, twin-published) | **30443** addressable (`d` slot, `i` ref, no encoding/relays tags) |
| KP discovery | kind 10051 KeyPackage-relay list | **NIP-65 kind 10002** (10051 abolished + retracted; breaking in combination with the KP-kind change) |
| ★ 445 exporter label | `MLS-Exporter("nostr", "nostr", 32)` | `MLS-Exporter("marmot", "group-event", 32)` = `"marmot/group-event"` |
| 445 AEAD shape | base64(nonce‖ct), 12-byte nonce, empty AAD, ChaCha20-Poly1305, ephemeral key/msg | **identical** — only the label differs |
| 445 tags | `h` + `["encoding","base64"]` (+ per-send NIP-40 expiration) | exactly one `h`; others dropped on ingest; expiration = group-level retention component |
| ★ Group metadata | `NostrGroupDataExtension` `0xF2EE` (name/desc/admins/relays/nostr_group_id) | **app components** in `app_data_dictionary` (0x8001/0x8003/0x8004…) |
| ★ Leaf credential | BasicCredential = pubkey hex, no proof | + **mandatory** `marmot.account-identity-proof.v2` leaf ext (`0xF2F1`, kind-450) |
| Welcome (444/1059) | same skeleton, loose tags | same skeleton, **strict** exactly-one `e`/`relays` + relay-set bounds (≤16 / ≤512 B / ws-wss) |
| Inner message | unsigned rumor, loose | `MarmotAppEvent`: canonical NIP-01 id, `pubkey` == MLS sender (enforced) |
| Ciphersuite | 0x0001 | 0x0001 — unchanged |
| Manager | `MdkManager` (sync, `&self`, interior-mutable) | `SessionManager` over `tokio::sync::Mutex<AccountDeviceSession>` (async, `&mut`) |
| Construction | `MDK::new(MdkSqliteStorage::new(path, key)?)` | `SessionConfig` (+ REQUIRED proof signer) → `AccountDeviceSession::open` |
| Receive | `process_message` → `MessageProcessingResult` | `ingest` → `IngestOutcome` × `GroupEvent` stream |
| Commit lifecycle | `merge_pending_commit` / `clear_pending_commit` + Haven staged-commit marker (`staged_commits` table) | `confirm_published` / `publish_failed` over typed `PendingStateRef`; `EpochState::PendingPublish`; `PendingCommitRecovered` at hydrate |
| Out-of-order commits | Haven `retry_failed_future_epoch_messages` (#633 un-poison) + `peek_crypto.rs` + settle-window layer (`settle`/`finalize`/`converge`/`autocommit`/`plan`) + `commit_order_key` | **engine-owned**: stored-convergence buffer + `advance_convergence` + `CommitOrderingKey` branch selection (all the Haven modules deleted) |
| Writer serialization | process-global `write_lock.rs` | the session mutex + **Rule 14** (one session per DB file) |
| MLS DB | `haven_mdk.db`, rollback journal, raw hex key (`mdk.db.key.default`) | `session.sqlite`, **WAL**, passphrase via PBKDF2 (`mls.session.key.default`); new `cgka_*` schema, **no importer** |
| KP lifecycle | single-consumption KPs; M8-2 `has_live_key_material` gate | every KP `last_resort`; explicit `delete_key_package`; gate deleted |
| Welcome accept/decline | MDK pending-welcome state (`accept_welcome`/`decline_welcome`) | engine auto-joins on ingest; Haven **hold-before-ingest** store preserves decline-no-trace |
| Leave | Haven `LeavePlan` + eager self-finalized commit paths | `SendIntent::Leave` → SelfRemove proposal; peers auto-commit (`AutoPublish`); registry `Capability::Proposal(10)` required |
| Retention name | `DEFAULT_EPOCH_LOOKBACK = 5` | `DEFAULT_MAX_PAST_EPOCHS = 5` (same number, engine-internal) |
| Test fixture | `MdkManager::new_unencrypted()` ×2 | `SessionManager::new_unencrypted(dir, &keys)` ×2 (fixed-passphrase temp SQLCipher DB); two-party idiom: KP via `build_kp_maintenance_events` → `create_circle` → `confirm_published` → `process_gift_wrapped_invitation` + `accept_invitation` |

---

## Nostr Integration

### NIP Dependencies

| NIP | Purpose |
|-----|---------|
| NIP-01 | Basic protocol, events, signatures; canonical event ids (inner messages, identity proof) |
| NIP-09 | Deletion requests (legacy-443 retraction; best-effort relay hygiene) |
| NIP-17 | Inbox relays (kind 10050) for gift-wrap delivery |
| NIP-33 | Parameterized-replaceable events (kind 30443 KeyPackages, `d` slot) |
| NIP-40 | Expiration (via the group-level `message-retention.v1` component) |
| NIP-59 | Gift wrapping (welcome delivery, kind 1059) |
| NIP-65 | Relay lists (kind 10002) — the KeyPackage discovery plane |

Note: **NIP-44 is no longer part of the 445 path** (the outer layer is raw ChaCha20-Poly1305 keyed
by the MLS exporter); NIP-59's internals still use NIP-44 for the seal, inside the peeler.

### Relay Usage

**KeyPackage publishing/fetching**: the account's **own NIP-65 (10002) relays** — never a
discovery/default union (own-relays-only invariant in `key_package.rs` maintenance).

**Group messages (445)**: published to the group's relays from the `NostrRoutingV1` component
(0x8004); subscribed by `#h` filter on the same set.

**Welcomes (1059)**: gift-wrapped to the recipient and published to their **10050 inbox relays**;
Haven fans out across relays itself (the peeler only does the crypto).

**nostr crate API reminder** (CLAUDE.md): `Filter::pubkey()` filters by `#p` tag (recipient),
**not** event author; use `Filter::author()` for the author field.

---

## Development Guidelines

### Toolchain

- Required: **Rust ≥ 1.90** (upstream workspace is edition 2024, resolver 3; a 2021-edition crate
  can depend on it — edition is per-crate).
- The five MDK crates are **git dependencies at one pinned rev** (released tags only — see
  CLAUDE.md "MDK pinning"). They are not on crates.io and never will be until upstream says so.

### Testing against the engine

```bash
cd haven-core && cargo test          # full suite (in-memory / temp-file SQLCipher sessions)
cd haven-core && cargo clippy -- -D warnings
```

- `SessionManager::new_unencrypted(dir, &keys)` opens a **fixed-passphrase temp-file SQLCipher**
  DB (the Dark Matter backend always encrypts; the name is retained for API continuity). No
  platform keyring needed. Gated `#[cfg(any(test, feature = "test-utils"))]`.
- Multi-party tests: two `SessionManager`s, two key sets; the canonical two-party idiom is in
  `tests/helpers/mod.rs` (`setup_two_party_group`), validated by `tests/dm_two_party_smoke_test.rs`.
- Security gates that MUST NOT be weakened (CLAUDE.md testing rules): the black-box out-of-order
  convergence e2e (F2), key-separation via identity-proof presence+verify, ephemeral-445
  uniqueness, 444-unsigned, no-MLS-`GroupId`-in-published-events, exporter prune at
  `max_past_epochs = 5`, redaction over `EngineError`/`PeelerError`, the Rule-14
  construction-site scan.

### Key API patterns (Haven surface)

| Task | Call |
|------|------|
| Open the session | `SessionManager::new(data_dir, &keys)` |
| Mint a KeyPackage + 30443 event | `build_kp_maintenance_events(session, keys, own_kp_relays, existing_d)` |
| Create a group | `create_group(key_packages, LocationGroupConfig)` → publish → `confirm_published(pending)` |
| Send a location | `send_location(gid, json)` → publish the `ApplicationMessage` |
| Receive | `process_event(&event)` → branch on `IngestOutcome`, drain `GroupEvent`s |
| Tick convergence | `advance_convergence(gid)` after ingest batches |
| Add / remove members | `add_members` / `remove_members` → publish → confirm/fail |
| Leave | `leave_group(gid)` (SelfRemove proposal — publish, no confirm) |
| Group routing | `group_routing(gid)` / `nostr_group_id_hex(gid)` / `group_relays(gid)` |
| Welcome preview / accept / decline | `preview_welcome` / `accept_welcome` / `PendingWelcomeStore::remove` |

---

## Security Best Practices

### For Application Developers

1. **Wire the identity-proof signer hardened**: recompute-and-sign only the canonical kind-450 id,
   refuse foreign identities, purpose-scope over the nsec (see `signer.rs`). A passthrough signer
   is a blind identity-key oracle.

2. **Respect the retention window**: old exporter secrets age out at `DEFAULT_MAX_PAST_EPOCHS = 5`
   past epochs (Haven does not override). Never retain secrets beyond in-flight decryption needs.

3. **Encrypt at rest**: platform keyring for DB keys; SQLCipher for MLS state
   (`session.sqlite`), circles, tiles. See `haven-core/SECURITY.md`.

4. **Publish-before-apply, honestly**: `confirm_published` only after a real ≥1-relay OK-ack.
   Optimistic confirm = fork exposure. `publish_failed` on failure; `PendingCommitRecovered` =
   mandatory resync.

5. **One session per DB file** (Rule 14) — across isolates AND processes. This is a
   confidentiality control, not a tidiness rule.

6. **Backpressure, never silent drops** (Rule 12): future-epoch backlog after offline periods is
   legitimate traffic; rate-limit intake, don't discard. Know that the engine buffer itself is
   unbounded until #757 closes.

7. **Validate credentials**: the engine enforces inner `pubkey` == MLS sender on ingest; also
   fail-close on send (Haven's `create_message` guard).

### What NOT to Do

❌ Use the same key for Nostr identity and MLS signing
❌ Call the peeler's `with_exporter_label` override (the only local 445-crypto downgrade lever; CI-guarded)
❌ Publish the real MLS group ID (only `nostr_group_id` from the routing component)
❌ Sign kind-444 Welcome events (they must remain unsigned)
❌ Publish kind-450 identity-proof events to relays (leaf-embedded only)
❌ Reuse ephemeral keypairs across group messages
❌ Open a second `AccountDeviceSession` on the same DB (Rule 14)
❌ `confirm_published` on "sent" rather than "acked" (Rule 13)
❌ Auto-ingest 1059s in the receive pipeline (welcomes go to the pending store — F3)
❌ Store decrypted welcome bytes at rest (hold the encrypted 1059 only)
❌ Ship a `FeatureRegistry` without `self-remove` (leaving silently breaks)

---

## Location Sharing Considerations

### Privacy-First Design

When building a location sharing app with Marmot:

1. **Granularity Control**: Allow users to share exact location, approximate area, city/region,
   or availability-only. (Haven ships exact-GPS-only by an explicit 2026-05-18 product decision —
   see project memory.)

2. **Temporal Control**: real-time with configurable intervals, one-time shares, time-limited
   sharing.

3. **Per-Group Settings**: different privacy settings per group.

### Message Format (Haven's inner kind-25442)

```json
{
  "kind": 25442,
  "pubkey": "<member's identity pubkey — MUST equal the MLS sender>",
  "created_at": 1234567890,
  "content": "{\"latitude\":37.7749295,\"longitude\":-122.4194155,\"geohash\":\"9q8yyk8y\",\"timestamp\":\"2026-01-01T00:00:00Z\",\"expires_at\":\"2026-01-01T00:15:00Z\"}",
  "tags": []
}
```

`content` is `serde_json` over `LocationMessage` (`haven-core/src/location/types.rs`) — those
five fields and no others. Device id, raw accuracy, altitude, speed and heading are `#[serde(skip)]`
and never leave the device. `display_name` is a sixth, optional field kept only for read-tolerance:
new clients never emit it (public kind-0 profiles replaced it), but a payload from an old client
that still carries it must deserialize cleanly, so `deny_unknown_fields` must never be added.

The `id` must be the canonical NIP-01 id over the other five members and the `pubkey` must be the
MLS-authenticated sender; the engine validates both on ingest. Inner tags are unconstrained by the
spec — Haven simply emits none (see "Inner application messages" above).

### Metadata Considerations

Even with E2E encryption, consider:
- **Frequency of updates**: more updates = more metadata about user activity (Haven jitters its
  publish cadence — see `SECURITY.md` "Publish cadence: jittered scheduler")
- **Message size patterns**: location updates have consistent size; padding is a known
  follow-up
- **Timing correlation**: synced updates across users create patterns
- **Stable `h` tag**: the per-circle `nostr_group_id` is a permanent routing key — a protocol
  constraint, documented as an accepted leak
- **Retention**: `message-retention.v1` (0x8005) IS wired — application 445s carry a NIP-40
  `expiration` of `created_at + 228 s`, so a cooperating relay drops location ciphertext after
  ~3.8 min, and `RetentionBoundPeeler` keeps that true even in a circle whose creator declared no
  component. Four residual leaks remain: commits/proposals carry **no** expiration (so
  membership-change traffic persists at relay policy), the exact 228 s delta is itself a
  Haven fingerprint, in a circle that declares no component another member's own location
  445s are still unstamped — Haven bounds only what it sends — and the bound WIDENS the
  fingerprint it inherits: where Haven previously emitted nothing in such a circle it now emits
  exactly 228 s, so in a mixed circle a relay can split one `#h` stream into the Haven member's
  location updates and everyone else's, a **per-member** discriminator inside a single group
  rather than a client-wide one. Accepted, and registered as `TTL-FINGERPRINT` in
  `docs/privacy/privacy_invariants.json`

### Implementation Tips

1. **Batch updates**: don't send every GPS tick; aggregate and send periodically
2. **Differential updates**: only send on significant movement
3. **Offline support**: queue location shares; the engine's convergence buffer makes inbound
   catch-up lossless — pair it with cursor discipline (advance on `Processed`/`Stale`, never past
   `Buffered`)
4. **Battery efficiency**: optimize GPS polling based on share settings

---

## Resources

### Official Documentation

- [Marmot Protocol Specs](https://github.com/marmot-protocol/marmot) — restructured surfaces
  (`foundation/`, `protocol-core/`, `app-components/`, `transports/`, `features/`); see
  `mip-coverage.md` for the old-MIP mapping
- [MDK Repository](https://github.com/marmot-protocol/mdk) — the Dark Matter monorepo; reading
  order per its README: engine README → conformance-simulator README → architecture index →
  Tamarin README; `release.md` documents the git-tag-only release surface
- [MLS RFC 9420](https://www.rfc-editor.org/rfc/rfc9420.html)
- [MLS Architecture RFC 9750](https://www.rfc-editor.org/rfc/rfc9750.html)

### Upstream source-of-truth files (in the pinned rev)

- `crates/transport-nostr-peeler/src/{lib.rs,peeler.rs,event.rs}` — 445/1059 wire boundary,
  exporter label, AAD, tag strictness, welcome relay bounds
- `crates/cgka-engine/src/{account_identity_proof.rs,engine.rs,key_package.rs,wire_format.rs}` —
  proof v2/0xF2F1/kind-450, `CommitOrderingKey`, last-resort KPs, `DEFAULT_MAX_PAST_EPOCHS`,
  `PURE_PLAINTEXT` policy
- `crates/traits/src/{types.rs,welcome.rs,ingest.rs,engine.rs,storage.rs}` and
  `crates/traits/src/app_components/{mod,codec,routing}.rs` — component ids, `NostrRoutingV1`
- `crates/cgka-session/src/lib.rs`, `crates/storage-sqlite/src/connection.rs`
- Spec: `foundation/{account-identity-proof-v1,canonical-encoding,application-messages}.md`,
  `transports/nostr.md`, `protocol-core/convergence.md`

### Haven implementation anchors

- `haven-core/src/nostr/mls/{manager,storage,signer,welcome,types}.rs` — SessionManager, key
  custody, hardened proof signer, hold-before-ingest store
- `haven-core/src/relay/maintenance/key_package.rs` — 30443 building, maintenance decision,
  legacy retraction
- `docs/MDK_DARKMATTER_MIGRATION_PLAN.md` — the executed migration plan (wire matrix §4, security
  rules §7)
- `haven-core/SECURITY.md` — key-custody table, threat-model notes (F6/F12, Rule 14, #757)

### Nostr Resources

- [Nostr Protocol](https://github.com/nostr-protocol/nostr)
- [NIPs Repository](https://github.com/nostr-protocol/nips)
- [NIP-EE (Legacy, superseded by Marmot)](https://nips.nostr.com/EE)

### Related Projects

- [OpenMLS](https://github.com/openmls/openmls) — the MLS implementation under `cgka-engine`
  (`~0.8.1` + `extensions-draft-08`)
- [rust-nostr](https://github.com/rust-nostr/nostr) — Nostr Rust libraries (0.44)
- [whitenoise-rs](https://github.com/marmot-protocol/whitenoise-rs) — reference app (AGPL-3.0;
  **not yet migrated to Dark Matter** — its master pins old `mdk-core 0.8.0`; useful only as an
  old-era reference)
- [whitenoise_flutter](https://github.com/marmot-protocol/whitenoise_flutter) — Flutter app

---

## Version History

| Date | Changes |
|------|---------|
| 2026-01-31 | Initial document creation (MIP era, mdk-core 0.5–0.7) |
| 2026-07-12 | Upstream MIP-deprecation note; profiles-out-of-scope clarification |
| 2026-07-17 | **Dark Matter rewrite**: Marmot v2 wire format (30443/10002, `"marmot/group-event"`, app components, identity proof v2), `AccountDeviceSession` engine model, Haven-specific choices, old-vs-new migration reference |

---

*This document is a Claude knowledge reference for developing against the Marmot Protocol as
Haven ships it. Where the published spec and the pinned MDK code disagree, the code is
authoritative; always re-verify against the pinned rev before relying on a wire-format detail.*
