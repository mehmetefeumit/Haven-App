# Marmot Protocol Knowledge Document

> **Purpose**: Reference documentation for building secure, decentralized applications using the Marmot Protocol ecosystem, as Haven ships it: the **MDK "Dark Matter"** crate set (pinned at **v0.10.4**; a passage written at the earlier v0.9.4 pin still carries that version and its line numbers unless it says otherwise) implementing the **Marmot v2** wire format. This document reflects the post-migration reality of `haven-core`; the pre-Dark-Matter (MIP-era) protocol facts live in the [Old vs New reference](#old-vs-new-migration-reference) and in git history.

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
| [marmot-protocol/whitenoise-ios](https://github.com/marmot-protocol/whitenoise-ios) | Reference client (iPhone), on MDK's own runtime via the `MarmotKit` UniFFI package | AGPL-3.0 |
| [marmot-protocol/whitenoise-android](https://github.com/marmot-protocol/whitenoise-android) | Reference client (Android), on the same Marmot bindings | AGPL-3.0 |

### Current Status — read this honestly

⚠️ **NOT SEMVER-STABLE.** The Dark Matter workspace is **git-tag-only** (`publish = false`, never on
crates.io) and self-describes as *"`0.9.0`, single internal consumer, not semver-stable"*
(`crates/cgka-engine/README.md:152` at v0.10.4, whose workspace version is `0.10.4`). Haven pins its six MDK crates (`cgka-session`, `cgka-engine`,
`cgka-traits`, `storage-sqlite`, `transport-nostr-peeler`, `transport-nostr-adapter`) to one 40-char
rev of the **v0.10.4** release tag (`fcc85edd8dbd07c8293c899ee52230f72c54c897`,
`scripts/ci/mdk_pins.env`) — bump only to released tags, never `master` (CLAUDE.md, MDK pinning
rule). Until the v0.10.4 migration it pinned five of them to **v0.9.4**
(`e391adc133a9b60e420da7a0446f014a180ac8d2`, 2026-07-10), and the rest of this status note is the
record of that pin. Known upstream state at that pin's time, **re-verified
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
- **#757 CONFIRMED STILL OPEN** (`gh api` 2026-09-05 → `{"state":"open"}`; MDK closed it as not
  planned on 2026-10-01, with no fix, so the gap stands at v0.10.4): the stored-convergence
  buffer has no per-group cap and no eviction API (Security Rule 12), so Haven's intake cap keeps
  its subject at every tag on the ladder — the caps that DID tighten upstream govern the separate
  `PeelDeferred` store, not this buffer. **#864 / #866 / #885 were NOT re-queried**: the "OPEN"
  below is the pin-time record, not a 2026-09-05 fact.
- **#864 (pin-time OPEN, state at v0.9.18 UNVERIFIED)**: five validators embed full group-id hex in
  error strings (Haven keeps `redact_hex_sequences` at the error boundary). **#866 (pin-time OPEN,
  UNVERIFIED)**: a `SQLITE_BUSY` lock-upgrade window in `storage-sqlite`. **#885 (pin-time OPEN,
  UNVERIFIED)**: phantom `committed_from` fork quarantine. All three were closed on 2026-07-23 —
  #864 and #866 by PR #1043, #885 by PR #889 — and ship from v0.9.5, so the v0.10.4 pin carries
  the fixes.
- **The next bump is a coordinated WIRE migration, not a dependency bump.** v0.9.18 introduces
  `ProtocolProfile { Legacy, Current }` (`crates/traits/src/group.rs:25-31`; absent at v0.9.4) and
  moves the account identity proof off leaf extension `0xF2F1` onto app component **`0x8009`**
  (`ACCOUNT_IDENTITY_PROOF_COMPONENT_ID`, `crates/traits/src/app_components/mod.rs:106`; a grep for
  it at v0.9.4 returns empty). Every `Group` this pin wrote loads as `Legacy`
  (`Group.protocol_profile` is `#[serde(default)]`), `AccountDeviceSession::open` REFUSES a `Legacy`
  session, and the opt-out `legacy_compatibility_profile()` is `#[cfg(debug_assertions)]` — i.e.
  **absent from release builds**. Membership changes across the boundary are rejected on send and on
  receive, so an existing circle would keep publishing locations and could never add or remove a
  member again. Blockers, gains and the honest recommendation on whether to take it: P4M. It was
  taken: Haven moved to v0.10.4 with a hard reset of every store (`haven-core/src/storage_reset.rs`)
  and opens Current-profile sessions only.
- The **reference client has not migrated**: whitenoise-rs master still pins old `mdk-core 0.8.0`
  (pin-time record; NOT re-verified 2026-09-05). whitenoise-rs was archived on 2026-08-05; the
  reference clients now are whitenoise-ios and whitenoise-android, which run MDK's own
  `marmot-app` runtime through its UniFFI bindings — crates Haven may not depend on.
- The published **Marmot v2 spec and the code have diverged** — see the
  [identity-proof divergence](#the-identity-proof-spec-vs-code-divergence) below, closed at
  v0.10.4. Where they
  disagree, **the code is authoritative** for Haven.

---

## Spec Restructure: MIPs → Protocol Surfaces

> **The MIP-00…MIP-05 documents are deprecated upstream.** `marmot-protocol/marmot` restructured
> the spec (~2026-07) into five directories — `foundation/`, `protocol-core/`, `app-components/`,
> `transports/`, `features/` — and the MIP numbering no longer exists there. `mip-coverage.md` in
> the spec repo maps the old numbers onto the new surfaces:

| Old MIP | Where it went |
|---------|---------------|
| **MIP-00** (Credentials & KeyPackages) | `foundation/identity`, `foundation/key-packages`, `app-components/account-identity-proof-v2` (new, breaking), `transports/nostr`, `protocol-core/joining` |
| **MIP-01** (Group construction & group data ext) | `protocol-core/group-setup`, `foundation/canonical-encoding`, `app-components/` |
| **MIP-02** (Welcome events) | `protocol-core/joining`, `transports/nostr` |
| **MIP-03** (Group messages) | `protocol-core/group-messaging`, `protocol-core/member-departure`, `foundation/application-messages` |
| **MIP-04** (Encrypted media) | `features/encrypted-media.md` (**adopted**), component `group-encrypted-media-v2` (v1 frozen) |
| **MIP-05** (Push notifications) | `features/push-notifications.md` (optional/draft) |
| **MIP-06** (Multi-device, branch draft) | `features/multi-device.md`, `app-components/multi-device-join-authorization-v1` |

New surfaces with no MIP ancestor: `protocol-core/convergence.md` (the concurrent-commit
branch-selection algorithm and the fixed policy v1), `protocol-core/publish-lifecycle.md`
(publish-before-apply), `protocol-core/{durability,group-state,inbound-processing,retained-history}.md`,
`foundation/{authorization-proofs,conformance}.md`, `app-components/group-lifecycle-v1.md`
(disband, 0x800c), `features/content-moderation.md`, and `transports/quic.md` (experimental —
irrelevant to Haven). `foundation/account-identity-proof-v1.md` survives only as the superseded
record of `0xf2f1`.

The spec is now **library-neutral** ("Implementations MAY use any MLS library if they produce and
validate the same protocol bytes"); MDK's `cgka-engine` remains **OpenMLS-backed** underneath.

**Per-user profiles are out of scope for Marmot** — all registered app-components are
group-scoped; the spec-blessed join point for member profiles is `group member →
BasicCredential.identity (Nostr pubkey) → kind-0` (see `docs/PUBLIC_PROFILE_MIGRATION_PLAN.md` §2).

### The identity-proof spec-vs-code divergence

**Closed by the v0.10.4 migration; what follows is the record from the v0.9.4 pin.** Haven's leaves
now carry the spec's component `0x8009` (see
[the kind-450 section](#account-identity-proof-kind-450--embedded-never-published)).

At the v0.9.4 pin the **shipped code** (`cgka-engine/src/account_identity_proof.rs`) carried the
proof as custom MLS **extension type `0xF2F1`**, version 2, domain
**`marmot.account-identity-proof.v2`**, signing a **canonical kind-450 Nostr event**
(`created_at = 0`, `d` tag = the domain string). **Haven implemented to the code** — the engine
enforced exactly that on ingest (`InvalidAccountIdentityProof`), so interop was with the pinned
MDK, not with the spec text.

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
> **Everything this section said about `0xF2F1` remained TRUE** for Haven's v0.9.4 pin and for
> every circle written under it (all deleted by the v0.10.4 reset) — it is the UPSTREAM carrier that moved, not
> Haven's. Two further sites still name `0xF2F1` as *the* identity-proof carrier and are **FLAGGED
> here, deliberately NOT changed**, because changing them before the bump would make them wrong
> today: the leaf-extension list under [MLS Configuration](#mls-configuration) (`0xF2F1` MANDATORY,
> and the matching `mls_extensions` tag value in the kind-30443 shape) and `CLAUDE.md:243`'s kind-450
> row. Both are correct at v0.9.4 and both are P4M's to rewrite, in the same commit as the bump.
> (Both were rewritten with the v0.10.4 bump: at that pin `0xF2F1` is MDK's legacy classifier
> only, and a Current leaf advertises and carries `0x8009`.)

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
//   0x0006  app_data_dictionary        (MLS extensions draft-10)
// RFC 9420 §7.2 defaults (extension types 1–5, proposal types 1–7) are never advertised
// (cgka-engine/src/capabilities.rs:19-21); last-resort marking is the KeyPackage-level
// component 0x0004, and the identity proof is LeafNode component 0x8009 — neither is an
// MLS extension type.
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
│  │  - relay subscriptions, cursors, NIP-77 by-id pass   │    │
│  │  - the fanout driver (commits, proposals, Welcomes)  │    │
│  │  - catch-up sweeps                                   │    │
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
│  │  storage-sqlite (SQLCipher session-v2.sqlite, WAL)   │    │
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

Haven deliberately does **not** adopt `marmot-account`, `marmot-app`, or the account and
subscription plane of `transport-nostr-adapter` (Haven keeps its own relay plane, keyring
integration, and app runtime). From the adapter it takes two pieces: the kind-30443 event template,
and — behind the crate's one feature, `sdk` — the relay client's classified publish, which the
durable fanout runs over Haven's own publish client. `marmot-forensics` is in
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
- Under Marmot v2 the separation is **formalized on-wire**: every leaf carries the required
  `marmot.member.account-identity-proof.v2` LeafNode app component (`0x8009`) — a Schnorr signature
  by the *identity* key over a canonical, unpublished kind-450 event binding identity pubkey ↔ MLS
  leaf signature key. The identity key signs only that binding proof, never MLS content.

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
| Malicious member floods the convergence buffer | Haven-side intake backpressure (Rule 12); engine storage stays unbounded (upstream #757, closed not planned with no fix) |

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
`scripts/ci/check_no_exporter_label_override.sh`). The spec now makes `PublicMessage` the first
profile's handshake format and requires every transport to keep those bytes confidential
(`foundation/mls-protocol.md:33-43`); MDK still marks the policy
`WIRE_FORMAT_POLICY_REVIEW_REQUIRED` ("Revisit Before External Rollout", `wire_format.rs:62`).

---

## Event Kinds & Wire Format

Every on-wire value below is what Haven actually publishes/ingests on the pinned v0.10.4 rev.

### Summary table

| Kind | Name | Status | Notes |
|------|------|--------|-------|
| 0 | Public profile metadata | Live | NIP-01/24; identity-key-signed; public-by-default (see CLAUDE.md) |
| 9 | Marmot chat message | **Never emitted, never folded** | Marmot's chat kind; not a location on receive either since the MDK v0.10.4 migration (see "Why Haven's inner kind is not 9") |
| 1210 | Inner system rows | Live (engine) | Synthesized locally from MLS-authenticated group state, not sent as a message |
| 25442 | Inner application message | Live | Haven's location content **inside** 445; never published bare |
| 30443 | KeyPackage (addressable) | Live | Replaces 443; published to the account's own NIP-65 (10002) relays, fetched from an invitee's write-capable set |
| 443 | KeyPackage (legacy) | **RETIRED** | Never built, fetched or retracted any more (see below) |
| 444 | Welcome rumor | Live | UNSIGNED, inside 1059; strict `e` + `relays` tags |
| 445 | Group message | Live | Outer ChaCha20-Poly1305, exporter label `"marmot/group-event"`, ephemeral key per event |
| 450 | Account identity proof | Live (never published) | Local signing template for LeafNode component `0x8009`; identity-key-signed |
| 1059 | Gift wrap (NIP-59) | Live | Exactly one `p` tag; Welcome delivery to the recipient's 10050 inbox relays |
| 5 | NIP-09 deletion | Live | Retraction of a malformed pre-fix KeyPackage slot; best-effort relay hygiene |
| 10002 | NIP-65 relay list | Live | **KeyPackage discovery plane** (replaces 10051) |
| 10050 | NIP-17 inbox relays | Live | Gift-wrap (1059) delivery |
| 10051 | KeyPackage relay list | **RETIRED** | Never built; the one-time cutover retraction has since been deleted |

### KeyPackage (kind 30443) — exactly as Haven publishes it

Kind 30443 is **NIP-33 addressable**: `(kind, pubkey, d)` is the coordinate; the `d` tag is a
stable per-account slot, so a republish **supersedes in place** (no accumulation of stale
KeyPackages, unlike the old regular-event 443). Built in
`haven-core/src/relay/maintenance/key_package.rs` (`build_key_package_event`), which fills MDK
v0.10.4's own template (`NostrKeyPackagePublication::to_event_at`,
`transport-nostr-adapter/src/key_package.rs:43-110`) from the package's decoded metadata;
**signed by the identity key**; content = **base64** of an `MLSMessage` in the `mls_key_package`
wire format (`foundation/key-packages.md:37-41`). Tags,
in the template's order, with the values a Haven package carries today:

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
    ["mls_extensions", "0x0006"],
    ["mls_proposals", "0x0008", "0x000a"],
    ["app_components", "0x8001", "0x8003", "0x8004", "0x8005", "0x8009", "0x800c"]
  ]
}
```

- **NO `encoding` tag, NO `relays` tag** (both are old-era artifacts).
- The `i` tag is the MLS KeyPackage ref derived from the wire bytes
  (`cgka_engine::key_package::key_package_metadata` — deriving it also validates the leaf,
  including the identity proof).
- The `mls_*` / `app_components` tag values are an **advertisement and fetch filter, never the
  truth** — the MLS bytes are. The publish side fills MDK's own template
  (`NostrKeyPackagePublication::to_event_at`, `client_name: None`) from the package's decoded
  metadata, so a tag cannot say something the package does not. The receive side holds a
  candidate to the same rule **before it may be selected**: `KeyPackageCandidate::validate`
  (`relay/maintenance/key_package.rs`) requires a Current-profile package whose credential is the
  event author, each of the seven tags exactly once, version `1.0`, `i` equal to the decoded
  ref and every id-list equal to the decoded metadata.
- **Selection** (`pick_keypackage_from_events`, `relay/manager.rs`; Marmot
  `foundation/key-packages.md:65-75`, "reject malformed or incompatible candidates before
  selecting one"), in this order:
  1. the newest event of each `d` slot is the slot's only candidate even when it is invalid, across
     both tiers of the discovery cascade (a replaced event is never revived);
  2. invalid candidates are dropped;
  3. candidates the invite TARGET cannot admit are dropped — the target is a new Haven circle or
     the existing circle the person is being added to, and the rule is MDK's own
     `KeyPackageRequirements` (`SessionManager::key_package_admission_rule`), so freshness never
     puts an inadmissible package ahead of an admissible one;
  4. the rest are ranked: a package published with no `client` label before one another app
     labelled (Haven's own tier, tracker `T-KP-CLIENT-RANK`: a Welcome built on another app's
     package reaches that app, and Haven could never open it), then the spec's order —
     non-last-resort, newer `created_at`, lower `KeyPackageRef`.
  When nothing is admissible the best valid candidate is handed back so the UI says the person
  cannot be invited, and when nothing is valid a pre-migration package so it says "needs to
  update" — neither is ever invited.
- **Discovery**: published to the account's own **NIP-65 (kind 10002)** list — the stored list
  Haven's 10002 is built from, unmarked `r` tags, so every entry is write-capable — and fetched
  from an invitee's 10002 write-capable set (`write` or unmarked, `transports/nostr.md:297-302`),
  falling back to the read-only discovery plane when that set is empty or holds no usable package
  (`RelayManager::fetch_keypackage_for_invite`). Kind 10051 is abolished.
- **Last-resort semantics**: every Haven KeyPackage is minted last-resort (the engine marks it
  with the empty `last_resort_key_package` component `0x0004` in the KeyPackage-level
  dictionary — not an MLS extension type), so the private init material is **never
  auto-deleted** when a welcome consumes it. A
  consumed package is still **replaced**: the engine records the consumption
  (`KeyPackageLifecycleState::last_consumed_key_package_ref`) and the next maintenance tick mints
  a replacement into the same `d` slot (`KpMaintenanceDecision::Replace`), as it does when the
  tracked package is no longer one this device durably owns. **One exception:** Haven holds a
  Welcome un-ingested until the user accepts it, so while an invitation is held unanswered the
  tick leaves the consumed package in place (the replacement's acknowledgement would delete the
  key every other held invitation needs) until the device clock reads 72 hours or more past the
  first tick that waited, or reads earlier than that tick; a hold that has ended stays ended
  until the replacement is acknowledged. A stranger's invitation causes the hold as a friend's
  does, which is why it is bounded. The consumed key itself goes when a relay acknowledges the
  replacement, or at the first maintenance tick at or after its `not_after`, whichever comes
  first. Rotation, a lost bundle and the `not_after` deletion do not wait.
- **One tick at a time**: `maintain_key_package` holds a per-account lock
  (`SessionManager::key_package_tick`) from its expiry sweep to its promotion.
- **Where the tracked package lives**: in MDK's durable `KeyPackageLifecycleState`, inside the
  encrypted MLS database — Haven keeps no table of its own (`TrackedKeyPackage`,
  `nostr/mls/manager.rs`). The record holds the package, its slot and the **signed event exactly
  as it was first published** (`SignedPublicationArtifact`). A replacement is staged
  (`stage_key_package_replacement`), signed once, republished until a relay acks, and only then
  promoted (`promote_key_package_lifecycle`).
- **Heal** republishes that frozen event byte for byte — same id, same `created_at` — so a relay
  hiccup can neither re-sign a package nor restart its lifetime.
- **Deletion bounds** (Security Rule 5): the superseded package's private material is deleted
  when its replacement is **confirmed** (first relay ack), not at its `not_after`; whatever is
  still held at `not_after` is deleted then (`sweep_expired_key_packages`). MDK's own delete and
  promote refuse a package whose lifetime has lapsed, so an expired bundle is removed by ref
  through Haven's second storage handle (tracker `T-KP-EXPIRED-DELETE`).

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
`Filter::kind(30443).author(pk).limit(10)` and ranks the valid candidates across ALL slots
(`pick_keypackage_from_events`, `relay/manager.rs`), never filtering on `d` and never storing
one. MDK v0.10.4's own receive path is no stricter about the slot: it requires only that a `d` is
present and non-empty (`marmot-app/src/key_package_records.rs:372-376`).

**The retirement** (`decide_kp_slot_retirement`, run by `maintain_key_package` *ahead of* the
ordinary maintenance decision so nothing is ever published into the slot being retired; sentinel
`kp_slot_retirement_done_v1` in `user_settings`):

1. **Re-point** — `build_kp_slot_repoint_event` re-publishes the **same tracked package** into a
   freshly minted 64-hex slot. Moving the package instead of minting one is what makes the
   migration cheap and safe: no new init material, none consumed, and a peer that already fetched
   the old event holds a `KeyPackageRef` this device still owns, so an **in-flight Welcome against
   the retired coordinate still decrypts**. That is the tracked package whose lifetime reads
   `Known` and no other: fresh material is minted whenever the record carries nothing that can be
   vouched for — no record at all; an adopted slot, which holds no package; and a package whose
   lifetime reads `NotCurrent` or `Unreadable`. In those the retired coordinate's package is
   **not** carried forward and an in-flight Welcome against it does not survive — nor could it
   be, since the event's `i` tag is the `KeyPackageRef` derived from those bytes and deriving it
   validates the leaf. A package the mint supersedes is deleted when the replacement is acked,
   like any other superseded package (`promote_key_package`).
2. **Then retract** — and only after at least one relay **OK-ACKED** that publish (Rule 13's
   discipline: sent is not acked): the record is re-pointed to the new slot
   (`repoint_key_package_slot`), and
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
   rather than minting a second one, which would orphan the first.

   **The mint path needs no such recognition.** A minted replacement is staged in the lifecycle
   record — package, slot and signed event — BEFORE anything is published, so a crash anywhere
   after that is resumed by republishing the same event into the same slot until a relay acks it
   (the tick's staged-replacement branch, which runs ahead of the retirement), never by minting a
   second package into a second slot.

Retracting first, or on a tick that could not publish, would risk an account with **no usable
published KeyPackage**, which is strictly worse than a malformed one; the ordering above is what
forbids it. Deletion itself is **advisory**: NIP-09 says relays *SHOULD* delete, and one that
ignores the request keeps serving the orphan. Where the retirement MOVED the package that is
survivable precisely because the orphan carries the same one — a lenient peer selecting it still
gets a `KeyPackage` this device can decrypt — until that package is next rotated or reaches
`not_after`, which are the spec's own deletion bounds. Where it had to MINT (the dead or unreadable
package above), the orphan advertises material the account no longer tracks and whose init key the
acked replacement authorises deleting, so a lenient peer that keeps selecting it can fail to invite
the account — the same outcome that package was already heading for. A relay that was unreachable
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

**Legacy 443 residue**: none left. Haven builds no 443 twin and no 10051, and the one-time cutover
retraction of the old 443 and 10051 (`LEGACY_KP_RETRACTION_DONE_KEY`) has since been deleted. The
invite-side fetch asks for kind 30443 alone; "needs to update" is now a 30443 whose package carries
the pre-migration (Legacy-profile) identity proof (`kp_event_is_pre_migration`,
`relay/maintenance/key_package.rs`), and such a package is never invited.

### Welcome (kind 444 inside kind 1059)

Skeleton unchanged from the MIP era: a NIP-59 kind-1059 gift wrap around an **unsigned kind-444
rumor**; rumor content = **base64** welcome bytes. What is new is **strictness** (validated both
directions by the peeler):

- **Exactly one `e` tag** — the KeyPackage event id (30443) the welcome consumed.
- **Exactly one `relays` tag** — the group's relay set, and it must be
  **non-empty, ≤16 entries, each URL ≤512 bytes, ws/wss only**, or the peeler's
  `wrap_welcome_with_metadata` fail-closes. Haven checks the set with MDK's own
  `NostrRoutingV1::new` plus its dial policy (`routing_of`, `manager.rs`; a relay update
  also earlier through `circle::manager::circle_relays`) so the error surfaces cleanly.
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
- **Tags**: **exactly one `h` tag and at most one `expiration` tag; any other tag makes the event
  `Malformed`** (`transport-nostr-peeler/src/event.rs:78-139`, `kind_445_transport_group_id`;
  Marmot `transports/nostr.md`: "a kind `445` event MUST NOT carry any other tag"). The
  expiration's syntax is checked, its value never compared to a clock. Haven emits `h` alone on
  commits and proposals, and
  `h` + NIP-40 `expiration` on application messages — nothing else, ever (see **Expiration**
  below). `causal_deps` is no longer parsed; the old `["encoding","base64"]` tag is no longer
  emitted.
- **`created_at` binding**: the outer event's `created_at` is bound to the inner app event's
  `created_at` for application messages (upstream #630, `peeler.rs:154-163`), so the sender and
  every receiver record the same time; commits and proposals keep the wrap time.
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
    what the component still decides is what every OTHER member's client does. This is a
    **recorded deviation from MDK and from the spec** (`docs/MDK_UPSTREAM_TRACKER.md`
    T-RETENTION-DEVIATION): MDK stamps nothing where a group declares nothing, and stamps the
    group's own window where it declares a longer one, as `transports/nostr.md` ("Message
    expiration") asks (a SHOULD). Interop holds because receivers never judge a message by the tag. Where the group declares a window of 1–228 s — every Haven-created
    circle declares 228 — the wrapper changes nothing and the stamp is MDK's own
    (`nostr::mls::retention::tests::retention_wrapper_is_identity_in_haven_circles`).
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
improvement, not a compliance fix.

Kinds inside the tunnel:
- **kind 25442** (`KIND_LOCATION_UPDATE`, `haven-core/src/nostr/event.rs`) — Haven's location
  updates: the `LocationMessage` JSON as content and **no tags at all**. The kind, not a tag, is
  what marks a payload as a location update, on both sides (`location_rumor` /
  `is_location_rumor`, `haven-core/src/nostr/mls/manager.rs`).
- **kind 1210** — **system rows** (membership changes, renames, `group_disbanded`, …) that each
  client synthesizes locally from MLS-authenticated group state, not sent as a message
  (`foundation/application-messages.md`, "Group system events").
- **kind 9** — Marmot's chat message. Haven neither sends it nor folds it as a location; see below.

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
anything sent on it as chat: the chat-list preview and the unread/mention scan
(`storage-sqlite/src/chat_list.rs`) and the notification classifier
(`notification_traffic_for_kind`, `marmot-app/src/notifications.rs:1861`) are allowlists kind 9
is on — White Noise would render a Haven circle as a stream of unreadable messages with unread
badges and push notifications. An unrecognised kind is on none of them. It is not dropped,
though: at v0.10.4 MDK's timeline projection gives every kind it does not know a generic row
(`_ => timeline_row_from_custom_event`, `storage-sqlite/src/timeline.rs:2124`; only the modifier
kinds get none), so an app built on that store keeps a Haven location payload as a timeline row;
what White Noise does with such a row is unverified. Marmot's `foundation/application-messages.md` (adopted) permits
both: "Protocol processing MUST NOT reject an otherwise-valid app payload merely because its event
kind is unknown", and "A client MAY ignore or decline to render unsupported application semantics
after delivering the accepted payload to its application layer".

This is an application-layer contract with other Marmot clients, not a Nostr-registry matter: the
inner kind exists only after MLS decryption and never reaches a relay.

**25442** was drawn at random from the ephemeral band (NIP-01: `20000 <= n < 30000`) and checked
unallocated in `nostr-protocol/registry-of-kinds`, the NIPs README kind table, MDK, and Haven.
The band choice is descriptive only — no relay ever classifies this kind.

**Never reuse these inner kinds.** Marmot's registry (`foundation/registries.md`) allocates
`9` chat, `447`/`448`/`449` push-token update/list/removal, `1009` message edit, `1018`/`1068`
NIP-88 poll response/poll, `1200` agent text stream start, `1210` group system rows, and
`1984`/`1985`/`4891` content report, report-dismissal label and admin content deletion. `1201`/`1202` (agent activity/operation) read as
"reserved for possible experimental" use in the registry, but are already live in MDK: both are
`cgka-traits` constants and its timeline projection renders both as rows. `446` is the
push-notification rumor; `450`/`451`/`452` are local signing templates that MUST NOT be published.
MDK additionally defines `5` (delete) and `7` (reaction) as inner app kinds. Haven's collision test
(`location_update_kind_collides_with_no_allocated_kind`, `nostr/event.rs`) lists every kind above.
It also reserves `1209`, which is **not** an allocation — it is in no Marmot registry and no MDK rev —
but deliberate margin next to `1210`.

**Upstream registration of 25442 is advisable, not required.** "The registry is not an allowlist
of inner event kinds" (`foundation/application-messages.md`) — an unallocated kind is conformant on
its own, and other clients handle 25442 under the ordinary unknown-app-event rules. The registry's
"Future adoption MUST add their exact semantics to the main table before relying on them for
interoperability" governs Marmot's own reserved `1201`/`1202` and future *Marmot-defined* app-event
kinds; it does not bind a third party choosing an unallocated number. Filing an entry is still
worth doing, because Marmot defines no third-party or private-use range for inner app kinds:
nothing else stops a future Marmot allocation from landing on 25442.

**The kind-9 receive window is closed.** It admitted a kind-9 rumor carrying `["t","location"]`
from the v0.1.11/v0.1.12 builds; the MDK v0.10.4 migration's storage reset removed every circle
those builds could share, so the arm and `LEGACY_KIND_LOCATION_UPDATE` were deleted. Nothing
constructs or folds a kind-9 rumor any more.

### Account identity proof (kind 450 — embedded, never published)

The required LeafNode app component `marmot.member.account-identity-proof.v2` (`0x8009`) holds
one 104-byte `MarmotAuthorizationProof` (`signer_pubkey[32]`, `created_at` u64, `signature[64]`):
a Schnorr signature by the **Nostr identity key** over the canonical NIP-01 id of a local kind-450
event whose `created_at` is the signing time, whose tags are exactly `d`
(`"marmot.account-identity-proof.v2"`), `component` (`0x8009`), `ciphersuite`,
`signature_scheme` and `mls_signature_key`, in that order, and whose content is a fixed string —
binding `account identity pubkey ↔ MLS leaf signature public key`
(`app-components/account-identity-proof-v2.md`). Every GroupContext requires `0x8009`.

- **Haven never publishes kind-450 to relays.** It exists only inside MLS leaves
  (KeyPackages, Welcomes, the ratchet tree).
- The engine rejects any leaf without a valid proof (`InvalidAccountIdentityProof`), and a leaf
  that mixes the legacy `0xF2F1` extension with `0x8009` — this is what makes old leaf formats
  hard-incompatible (wire break W7 at the Dark Matter cutover, the Legacy/Current split at
  v0.10.4).
- Haven's signer (`haven-core/src/nostr/mls/signer.rs`, `HavenIdentityProofSigner`) is
  **hardened** (security F1): it recomputes the canonical proof event itself and signs only that
  id (never a caller-supplied digest), refuses requests for a foreign `account_identity`, and is
  purpose-scoped over Zeroizing secret bytes (not a general `NostrSigner`) — so it can never be
  used as a blind identity-key oracle. Domain separation vs kind-0/24242 signing is inherent
  (kind 450 with its fixed tags and content → an id no kind-0 or kind-24242 event shares).
- **Threat note (F12)**: any co-member can extract the proof from your leaf and rebroadcast a
  valid identity-key-signed kind-450 to relays, publicly binding your pubkey to MLS
  participation. Irreducible by design (co-members already see the credential); recorded in
  `haven-core/SECURITY.md`.

---

## App Components

The MIP-01 `NostrGroupDataExtension` (`0xF2EE`) is gone. Group metadata now lives in the MLS
`app_data_dictionary` (MLS extensions draft-10 "safe extensions") as **signed, group-scoped app
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
| 0x8008 | `marmot.group.encrypted-media.v1` | MIP-04 successor (Blossom, per-file keys; frozen) | not used |
| 0x8009 | `marmot.member.account-identity-proof.v2` | LeafNode-only identity proof (see kind 450 above) | ✅ (every leaf; required by every circle) |
| 0x800a | `marmot.authorization.multi-device-join.v1` | Draft multi-device join | not used |
| 0x800b | `marmot.group.encrypted-media.v2` | Encrypted media v2 | never advertised |
| 0x800c | `marmot.group.lifecycle.v1` | Group lifecycle — an admin may disband | ✅ (required by every new group) |

- **Disband (0x800c)**: once an admin disbands a circle, Haven reads MDK's tombstone and seals
  nothing for it, asks no relay for it, and never calls MDK's `forget_group_local` for it (its
  live MLS state the engine already deleted at the disband). Haven offers no disband of its own.
- **Rule 4 privacy split preserved**: `GroupId` (the MLS id) is engine-internal and never
  published; `NostrRoutingV1.nostr_group_id` is the pseudonymous transport id
  (`session.app_component(gid, NOSTR_ROUTING_COMPONENT_ID)` →
  `SessionManager::group_routing/nostr_group_id_hex`).
- Haven configures `supported_app_components` at session open with MDK's
  `default_group_components()` (0x8001, 0x8003, 0x800c) plus 0x8004 and 0x8005
  (`haven_app_components`, `manager.rs`); the engine adds 0x8009 to every Current leaf, so a Haven
  KeyPackage advertises 0x8001, 0x8003, 0x8004, 0x8005, 0x8009 and 0x800c.
- Per-user profiles are **not** app components (group-scoped only) — user profiles are plain
  Nostr kind-0 (see the spec-restructure section).

---

## MDK "Dark Matter": The Engine Haven Runs

### Crate set and pin

```toml
# haven-core/Cargo.toml — all six at ONE released-tag rev (v0.10.4)
cgka-session            = { git = "https://github.com/marmot-protocol/mdk", rev = "fcc85edd8dbd07c8293c899ee52230f72c54c897" }
cgka-engine             = { git = "https://github.com/marmot-protocol/mdk", rev = "fcc85edd..." }
cgka-traits             = { git = "https://github.com/marmot-protocol/mdk", rev = "fcc85edd..." }  # dir crates/traits
storage-sqlite          = { git = "https://github.com/marmot-protocol/mdk", rev = "fcc85edd..." }
transport-nostr-peeler  = { git = "https://github.com/marmot-protocol/mdk", rev = "fcc85edd..." }
transport-nostr-adapter = { git = "https://github.com/marmot-protocol/mdk", rev = "fcc85edd...", features = ["sdk"] }
```

There is **no `mdk-core` crate anymore.** Constraints that ride along: `rusqlite =0.40.1` /
`libsqlite3-sys =0.38.1`, the latter patched to the SQLCipher 4.17 source in every Cargo root
(`links = "sqlite3"` — one version per graph, so `circles.db`/`tiles.db` share the pin), the OpenMLS
fork rev MDK requires (`erskingardner/openmls@59e7d3b`, which enters the shipped graph only through
the engine; `haven-core` names the same rev for its tests), toolchain ≥ 1.97.1.
CI guards: single-version `cargo tree` gates; `uniffi`/`quic`/`agent` crates must stay OUT of the
graph; `marmot-forensics` is audited as an unconditional transitive dep.

### The session model

One **`AccountDeviceSession`** per account-device, opened over one SQLCipher DB
(`session-v2.sqlite`). `open()` is sync and **hydrates authoritative group state into memory**;
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
    .supported_app_components(haven_app_components()) // 0x8001 0x8003 0x800c + 0x8004 0x8005
    .feature_registry(self_remove_feature_registry());
    // No convergence_policy: open() refuses anything but MDK's pinned v1.
let session = AccountDeviceSession::open(config)?;   // sync; hydrates; Current profile
session.put_periodic_maintenance_policy(PeriodicMaintenancePolicy::Disabled)?;
```

Haven never enrols a circle in periodic self-update (MDK's default is `EnabledForNewGroups`), and
makes the one post-join self-update MDK records at every Welcome join from its full drives
(`haven-core/SECURITY.md`, "Self-update: post-join performed, periodic disabled").

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
- **`IngestOutcome::Buffered { group_id, epoch }`** — the engine holds it and has not applied
  it. Two different things answer this way. BEFORE the peel, while a commit of this device's is
  pending, the event is stored unopened as a raw `Retryable` row
  (`message_processor/ingest.rs:566-588`). AFTER the peel, a commit taken up for its convergence
  pass is stored as a content row and its wrapper retired; a redelivery of that one answers
  `Ignored { Duplicate }`, not `Buffered`. **Haven holds the cursor at a `Buffered` event** (MDK's
  own host does not; it holds only on a resource refusal), with two exceptions made in the one
  classifier and the live plane's arm together (`relay::catchup::cursor_verdict`): a
  `Buffered { epoch }` for a circle that is `Stable` at a LATER epoch is read as applied — the
  pass that took the input up has closed; and a `Buffered` answered from a STRANDED row — a raw
  `Retryable` row of a circle the engine reports `Stable`, at either epoch relation — holds
  nothing (`ReceiveOnlyOutcome::Stranded`), because the seam answers every redelivery of it the
  same way and a held cursor would refetch it for as long as a relay serves it. Haven detects
  such rows, tells the circle and hands them back to the engine at the top of every call that
  hands the engine an event, advances a circle, or seals or stages for one — whatever the
  event's NIP-40 tag says, which is unauthenticated and decides nothing
  (`docs/MDK_UPSTREAM_TRACKER.md` T-PARKED-REPLAY).
  The replay comes back in the batch of whatever call RELEASED it — a `confirm_published`, a
  `publish_failed`, an `advance_convergence`, or the convergence settle inside the next `send` —
  and it comes back **once**; see "What a resolved publish hands back" below.
- **`IngestOutcome::Ignored { category }`** — rejected before convergence admission; a
  redelivery of something already recorded is `Ignored { category: Duplicate }` at the pin
  (`message_processor/store.rs:174-183`, `:213-218`), and an own echo, a wrong recipient and an
  unknown group are categories of it too. Advance the cursor.
- **`IngestOutcome::Stale { reason }`** — non-error terminal. At the pin the reasons that are not
  deprecated are `AlreadyAtEpoch`, `PreMembership`, `PredatesLocalCopy`, `BeyondAnchor`,
  `BeyondRollbackHorizon`, `BeyondAppRetention`, `LosingBranch` and
  `InvalidAgainstCanonicalState`; `AlreadySeen`, `NotForThisClient`,
  `UnknownGroup` and `OwnEcho` are deprecated in favour of `Ignored`, and a failed peel, this
  device's own removal and a quarantined group are `TransportDeferred` and
  `LocalState::{Removed, Quarantined}`, not `Stale`. Advance the cursor.
- **`IngestOutcome::ResourceRefused { .. }`** — refused for a local resource bound and never
  recorded as seen: **the cursor holds** (Rule 12; Marmot `transports/nostr.md:164-172`, a range
  holding one is not synchronized despite `EOSE`). `TransportDeferred` (retained and retried by
  the engine), `LocalState` and `Rejected` advance it. Haven's one classifier for every plane that
  polls: `relay::catchup::cursor_verdict`.

Application-visible results arrive as an **ordered `GroupEvent` stream** in `effects.events`
(also from `advance_convergence` and `confirm_published`):

| GroupEvent | Meaning | Haven folding (`location_result_from_event`) |
|---|---|---|
| `MessageReceived{group_id, sender, epoch, payload}` | Decrypted inner app message | `Location` (content extracted from the MarmotAppEvent JSON) |
| `GroupJoined{..}` | Welcome accepted, group joined | `Joined` |
| `EpochChanged` / `GroupStateChanged{change, actor, ..}` | Commit applied (membership/admin/rename/retention) | `GroupUpdate` |
| `AppMessageInvalidated` / `GroupStateInvalidated` | Earlier output withdrawn by branch selection — treat as if it never happened | `Invalidated` |
| `GroupStateRevalidated` | Notifications a branch selection withdrew, restored | `GroupUpdate` |
| `GroupUnrecoverable` | Fork/quarantine terminal state — UI must block send/mutate | `Unrecoverable` |
| `PendingCommitRecovered` | A commit staged with no fanout row, cleared at hydrate | **mandatory resync** (Rule 13) — `GroupUpdate` |
| `GroupHydrationRecovered` | A quarantined group hydrated again | `GroupUpdate` |
| `GroupCreated`, `GroupHydrationQuarantined`, `CommitRolledBack`, `TransportObjectResourceRefused` | Bookkeeping; the refused object is the cursor's concern | `None` |

A `GroupStateChanged` whose removed member is THIS device (`realize_self_eviction`,
`message_processor/ingest.rs:2404` at v0.10.4) carries the same `GroupUpdate` folding as any other roster move: the fold
is by variant, not by whose leaf went. Every receive plane therefore renders a self-eviction as a
generic refresh signal rather than as "you were removed"; the circle still stops sending, because
the engine's own gate refuses it. Known coarseness, pre-existing on every plane, and deliberately
not special-cased.

### Publish-before-apply (Rule 13)

Mutations (`SendIntent::{Invite, RemoveMembers, UpdateGroupData, UpdateAppComponents}`, group
creation, and engine auto-commits) come back as `SessionEffects.publish` items:

- `PublishWork::ApplicationMessage { msg }` — publish once; no pending ref (app messages don't
  advance the epoch).
- `PublishWork::Proposal { msg }` — e.g. a `SelfRemove`; no pending ref. Haven records it as a
  durable fanout in the lock hold that minted it (`SessionManager::put_proposal_fanout`) and the
  driver sends the same bytes until `min(2,n)` relays hold them; one no record could be written
  for is published once (`docs/MDK_UPSTREAM_TRACKER.md` T-LEAVE-FANOUT).
- `PublishWork::FoundingGroupCreated { welcomes }` — a Current-profile create: the group is
  canonical on return, with nothing to confirm or roll back. Each Welcome is its own retryable
  delivery obligation (`protocol-core/publish-lifecycle.md`); Haven writes its record before the
  create returns (`SessionManager::record_founding_welcomes`, bridge `create_circle_driven`).
- `PublishWork::GroupEvolution { msg, welcomes, pending }` / `AutoPublish { .., pending }`
  (`GroupCreated { .., pending }` is the Legacy profile's create) — **staged, not applied**.
  Haven gives each commit a durable MDK fanout record in the lock hold that staged it
  (`SessionManager::stage_commits`), before any byte can leave the device, and only the fanout
  driver (`haven-core/src/relay/fanout.rs`) sends it, one relay per call. Then:
  - `confirm_published_fanout` — on the first relay OK-ack and **on nothing less** ("acked"
    means acked, never merely "sent"). The engine merges the staged commit and emits the epoch
    change. An invite's Welcomes are handed over to their own delivery records only after that.
  - `publish_failed_fanout` — only when every frozen target answered with a proven
    non-acceptance and none was ever possibly exposed; a timeout or a lost `OK` keeps the commit
    pending and the byte-identical event is sent again. The engine discards the staged commit and
    returns the group to `Stable` at the prior epoch.

  The six invariants and their pinning tests are Security Rule 13 in `CLAUDE.md`; the rest
  (frozen targets, `min(2,n)` acknowledgements after a confirm, the 24 h bounds) is in
  `haven-core/SECURITY.md`.

Between stage and confirm the group is `EpochState::PendingPublish`; EVERY inbound `kind:445`
is stored unopened and answered `Buffered` (`message_processor/ingest.rs:566-588`), and is
replayed at the END OF THE CONFIRM OR THE ROLLBACK that returns the group to `Stable`
(`replay_buffered_messages`: `publish.rs:360`, `:536`; a join runs it too, and ends such rows
undelivered — the new copy's epochs begin later) — NOT when hydrate returns
it there by clearing the staged commit, which replays nothing, so MDK leaves those rows stranded
until this device's next own confirm or rollback; Haven hands them back itself (T-PARKED-REPLAY).
Hydrate restores a pending commit from its stored fanout row; a crash that left one staged with
no row → hydrate clears the staged
commit and emits `PendingCommitRecovered` → treat as a **mandatory resync**. MDK would then merge
the cleared commit's own `Sent` row alone at this device's next convergence pass; Haven retires that
row before the session's first engine call, and since every commit is recorded in the hold that
staged it, a commit cleared this way never left the device (Rule 13 invariant 5;
`docs/MDK_UPSTREAM_TRACKER.md` T-ROLLBACK-RESURRECT). ~~That covers every
staged commit.~~ **CORRECTED 2026-09-05 — it does NOT cover the removal-bearing ones, which is the
case that matters most.** `staged_removes_member` (matching `Proposal::Remove | Proposal::SelfRemove`)
short-circuits the whole emit block at hydrate (`cgka-engine/src/engine.rs:1962-1980` at the pinned
v0.10.4), deliberately:
rolling a removal back would re-add the departed member and fork convergence. So a peer `SelfRemove`
auto-commit killed between publish and confirm emits **nothing** — no `PendingCommitRecovered`, no
resync signal — and a re-fetch of one's own commit comes back `Ignored { OwnEcho }` (v0.10.4
`message_processor/mod.rs:738-740`; `Stale { OwnEcho }` at `e391adc`) from the durable
`MessageState::Sent` row, so re-downloading it applies nothing. In Haven a commit killed between
publish and confirm always has its fanout row, from which hydrate restores its pending ref; one
killed inside its staging has none and was never sent. An admin's own removal left that way is
given its row before the engine opens, recorded as possibly exposed; an eviction left that way
stays as MDK leaves it, refusing the circle's sends until another member's commit for the same
leave is applied (`docs/MDK_UPSTREAM_TRACKER.md` T-KILL-WINDOW).

**And `publish_failed` is not an escape** — as measured at `e391adc`; **at the pinned v0.10.4 the
rest of this paragraph and the first of the two consequences below no longer describe the engine**:
its rollback of an eviction clears the proposals that eviction's staging stored and arms the eviction
again (`cgka-engine/src/publish.rs:448-459`, `:531-535`), so a
rolled-back eviction is staged again and the circle's sends are restored meanwhile. What v0.10.4
still leaves is an eviction KILLED INSIDE its staging, whose stored proposal nothing clears
(`docs/MDK_UPSTREAM_TRACKER.md` T-KILL-WINDOW). The older measurement, kept for the record: rolling a
peer `SelfRemove` auto-commit back DROPS the
removal permanently and silently: the engine removes its in-memory
`scheduled_self_remove_auto_commits` entry before staging, `do_publish_failed` does not re-arm it,
and a redelivery of the proposal short-circuits to `Buffered` off its durable `Created`
`MessageRecord` without reaching the arm that reschedules. Verified by source and by experiment at
`e391adc`: no later `advance_convergence`, no re-ingest, no outbound send and no restart re-derives
it — until some unrelated commit moves the epoch, after which the leaver's own client re-proposes
(`message_processor/send.rs:718-725` gates the re-proposal on exactly that). Haven never holds an
`AutoPublish` unrecorded: every commit, an eviction included, is staged under its durable fanout
record in the hold that staged it. A plane that makes no commit — a background burst, the wake
sweep, a session only started — stages no eviction; it stays due in the engine and the first
foreground drive makes it, unless another member's eviction is applied first, after which nobody
on this device makes one.

Two further consequences, both verified by experiment at `e391adc` and both invisible from every
engine read accessor:

- **A rollback does not restore the circle's sends.** `do_publish_failed` clears the staged COMMIT
  but not the stored PROPOSAL, and `OpenMLS`'s `create_message` refuses while the proposal store is
  non-empty. The next send fails `create_message: GroupStateError(PendingProposal)` and keeps failing
  until some commit merges and empties the store. Rolling back trades a `PendingPublish` refusal for
  a `PendingProposal` one.
- **After a process restart the two layers disagree, and only the send gate can tell.** `EpochManager`
  is in-memory (`cgka-engine/src/epoch_manager.rs` — plain `HashMap`s, `Default`), and hydrate ends by
  calling `set_stable(group.epoch)` (v0.10.4 `engine.rs:2113-2115`, and only when no pending fanout
  row or durable evolution was restored for the group; unconditionally at `e391adc`) on a record whose
  epoch was already projected PAST the leave. So a group carrying an unrecovered removal-bearing staged commit
  reports `Stable` at epoch N+1 with the leaver already gone from `members`, while `OpenMLS` is still
  at N with the commit staged. `epoch`, `members`, `group_record` and `current_safe_export_epoch` all
  read the projection; a send is the only thing that reports the truth.

Full analysis: `docs/POWER_EFFICIENCY_PLAN.md` §4 OD4-c and §5.4; the owner's decision is now
implemented by the fanout driver (`haven-core/src/relay/fanout.rs`,
`SessionManager::stage_commits`). The old
`merge_pending_commit`/`clear_pending_commit`/staged-commit-marker machinery is deleted — the
typed `PendingStateRef` lifecycle owns it.

#### What a resolved publish hands BACK

`confirm_published` and `publish_failed` do not resolve a ref and stop. Both end in
`replay_buffered_messages` (v0.10.4 `cgka-engine/src/publish.rs:360` and `:536`), and both return a full
`SessionEffects` — which is **a one-shot drain of GLOBAL engine buffers**: `events` (every
`MessageReceived` the window buffered, plus the epoch change), `pending_convergence`, `publish`
and `queued`. Dropped means gone; nothing re-requests any of it.

- **A replayed `MessageReceived` comes back ONCE in a process**, and the engine writes the content
  row `Processed` in the same breath (`message_processor/ingest.rs:1484-1487`), after which every
  redelivery answers `Ignored { category: Duplicate }` (`message_processor/store.rs:174-183`,
  `:213-218`). There IS an
  application-acknowledgement boundary: in the transaction that marks the row processed the
  engine also writes the delivery to a durable pending-output table
  (`put_pending_application_event`, `traits/src/storage.rs:341-364`), hands every unacknowledged
  one back at the next open, and forgets it only when the host deletes its id — which Haven does
  once its own record of the fix has committed (`SessionManager::acknowledge_outputs`,
  `CircleManager::recover_owed_outputs`). So a batch folded without persisting is handed back at
  the next open, not lost; what is NOT recoverable that way is an event the engine never
  reached — a stranded row. Haven persists INSIDE the call
  (`CircleManager::persist_locations_from_events`), keyed off each event's OWN `group_id`: the
  buffers are global, so one batch can span circles and an ambient id would file a peer under a
  circle they are not in.
- **A peer `SelfRemove` buffered behind a staged commit surfaces on the ROLLBACK rung, never on
  the confirm.** A confirm merges first, so its replay runs at epoch N+1 and a proposal bound to
  epoch N is already dead; `publish_failed` discards the staged commit and replays at the
  ORIGINAL epoch, where the proposal still applies. It arrives as `pending_convergence = [group]`
  with an **empty** `publish` — the eviction `AutoPublish` only materialises on the following
  `advance_convergence` — so a caller that drops `pending_convergence` strands the leave with
  nobody committing it. Haven drains it in the same call (`CircleManager::settle_fanout`), with
  one bounded re-tick budget per call because the engine's auto-commit due time is a real
  `Instant`.
- **An `Err` from `confirm_published` can mean "applied, replay failed".** The durable merge and
  `epoch_manager.confirm_publish` both PRECEDE the replay, and `cgka-session` propagates the
  replay's `?` before `collect_effects` runs — so the caller gets an error and **no** effects
  while everything already emitted sits in the engine's buffers. An error inside the merge's
  transaction rolls it back whole. Haven never rolls back on a confirm's error: it asks again in
  the same call only for an error the store calls transient (`CONFIRM_ATTEMPTS` asks in all),
  drains and stages what the failed call emitted (`SessionManager::drain`), folds it and returns it
  beside the original error, and the next drive decides from the stored fanout row
  (`docs/MDK_UPSTREAM_TRACKER.md` T-CONFIRM-ERR).
- **The send path is the same drop at higher frequency.** `do_send` settles stored convergence
  before it encrypts (`should_queue_outbound_intent` → `advance_convergence_inputs_until_settled`
  → `retry_deferred_peels`), so a peer message that could not be peeled when it arrived is
  re-ingested into THAT send's own batch. Haven persists it there too
  (`CircleManager::note_send_drain`, called wherever a send's batch is taken) — which is why a
  location publish cycle is a receive path as well as a send one. A commit the same drain
  co-surfaces gets its durable fanout record in that hold (`SessionManager::stage_commits`) and is
  driven like any other; one whose record cannot be written is rolled back there, unsent.

### Convergence (the concurrent-commit cure)

The engine owns what Haven used to hand-roll (settle windows, `commit_order_key`, the #633
un-poison workaround — all deleted):

- Every inbound is persisted in the **stored-convergence buffer** with a typed
  `MessageState::{Retryable, PeelDeferred, …}`; future-epoch app messages sit `Retryable`,
  un-peelable ones `PeelDeferred` (retried against retained group snapshots).
- **`advance_convergence(&group_id)`** releases queued work and buffered messages that are now
  safe to apply; call it after ingest batches (`drain_pending_convergence_groups` schedules extra
  ticks). Haven's live-sync processor ticks it after each batch.
- Same-epoch concurrent commits are resolved by **deterministic branch selection**. The spec
  compares eligible branches in SIX steps (`protocol-core/convergence.md:321-328`): higher
  effective commit depth, a witness quorum over none, higher app-witness score, then the tip's
  priority (`privileged` before `ordinary`), lower tip committer, lower tip digest. The
  four-part `CommitOrderingKey` — `(source_epoch, priority, committer, commit_digest)` — is
  only the last three of those for one epoch: depth and witnesses come first. Losers roll back with `…Invalidated` events; even an own *confirmed* commit can lose
  (`GroupStateInvalidated{SupersededByBranchSelection}`). Haven hands an own withdrawn change
  back to MDK's re-issue at a full drive, except a removal: MDK's re-issue names members by a
  member id an account invited back shares with the one named, so a withdrawn removal is dropped
  as an offer — its members kept and the circle's background sends held, the user told — and
  never re-made by itself; nor is a removal set aside unmade ("offered", decision 233; tracker
  `T-REISSUE`). Unresolvable forks →
  `ForkedEpoch` / `GroupUnrecoverable`. The selector/lifecycle/delivery-order are
  Tamarin-modelled upstream — which does **not** substitute for Haven's empirical black-box e2e
  gates (the out-of-order convergence e2e is retained as the F2 gate).
- Upstream **#633** (sticky-`Unprocessable` epoch poison) is fixed by this design; Haven's local
  `retry_failed_future_epoch_messages` workaround is deleted.
- **#757 (OPEN — re-confirmed by `gh api` on 2026-09-05, and still open at MDK v0.9.18)**: the
  buffer has **no per-group cap and no eviction API** — a malicious member
  can grow durable storage with future-epoch messages. Haven mitigates with intake backpressure
  (Rule 12: rate-limit, NEVER silently drop legitimate offline backlog), but an intake cap
  throttles only — it cannot bound engine storage. MDK closed #757 as not planned on 2026-10-01,
  with no fix, so no upstream cap is coming.
- **The relay's own replay cap sits IN FRONT of the intake cap — recorded 2026-09-26 (C8;
  measured by `haven-soak` S08 `buried-past-the-cap`).** Haven's live group REQ sets no `limit`,
  so a relay answers it at its own default (500 for `nostr-relay-builder`) and the intake queue
  (`WORKER_QUEUE_CAP`, 8 192) never sees more than that per REQ. The live plane trusts the `EOSE`
  after that page and advances the cursor, with no truncation rule of the kind the catch-up sweep
  has. So anyone who has seen a circle's public `#h` can bury a real commit under more than the
  cap of signed kind-445s dated after it: once the re-anchor lands 61 s or more after the commit
  (`GROUP_RESUBSCRIBE_BUFFER_SECS` + 1), neither the next REQ nor the sweep asks for it again and
  the device that missed it is stranded. Rule 12's "never silently drop legitimate backlog" is
  broken one layer before the intake cap it names. Since the v0.10.4 migration Haven's own NIP-77
  by-id pass (`haven-core/src/relay/negentropy.rs`) recovers the buried commit from a relay that
  speaks NIP-77; on a relay that does not, the burial stands (a recorded soak arm,
  `docs/BACKGROUND_SHARING_FAILURE_ANALYSIS.md` C8).
  Also measured: the relay pool emits an event only for an id it has not seen this session
  (35 000-id memory database), so the intake hold's "the next REQ asks again" is true on the wire
  and false at the engine within one session.
- **A third store, OUTSIDER-reachable and uncapped — recorded 2026-09-26 (owner decision
  OQ-B; measured by `haven-soak` S16 `pending-window-flood`).** While a group is
  `PendingPublish`/`Merging`, `can_ingest` is false and `ingest_group_message` persists
  EVERY inbound kind-445 as `MessageState::Retryable` — unconditionally, BEFORE the peel,
  with no cap (`cgka-engine/src/message_processor/ingest.rs:566-588` at the v0.10.4 pin), keyed
  on the raw transport id the sender chose (the content-derived id is computed only after a
  successful peel, `:946-957`, so fresh ids defeat the durable dedup seam,
  `recorded_message_outcome`, `message_processor/store.rs:170-220`). The only cap in the
  file is the deferred-peel one (`has_peel_deferred_capacity`, `:461`, `:729`), on branches
  this path never reaches. So anyone who has seen a circle's public `#h` grows the
  victim's durable store one row per event for as long as its publish window stays open
  — a window the fanout driver holds open until a relay acknowledges the commit (a timeout
  never rolls it back), and for ever under S22's undischargeable removal. Measured over
  one window of 300 forged rows: the confirm that closes the window replays every raw
  row (about 285 ms each — 85 s for the window), the first 256 become `PeelDeferred`
  (the other cap), and the remaining 44 stay `Retryable` for good (measured before the
  v0.10.4 pin; at it, the bullet below says which rows a replay leaves), with the store growing from 6.5 MB to 14.5 MB across the
  replay. None of it gates a send (`gating_input_count` reads 0 throughout) and the
  circle recovers, which is what makes it silent. Haven-side mitigation is the same
  intake backpressure #757's is; the persist itself is MDK's, and it is left alone at
  this pin.
- **`replay_buffered_messages` retires every raw row whose re-ingest reaches a verdict**, not
  only a `PeelDeferred` one (`message_processor/mod.rs:3656-3684` at the v0.10.4 pin): a row
  still awaiting retry after its content was applied, found a duplicate or an own echo is
  written `Processed`, and a redelivery is then `Ignored { category: Duplicate }`. What a
  replay LEAVES awaiting retry: a row whose re-ingest answered `Buffered`, `TransportDeferred`,
  quarantined or unknown-group (`:3576-3608`), one refused for want of a deferred-peel slot
  (`ResourceRefused`), every row at and behind this device's own removal — and every row behind
  one that ERRORED, because the error ends the loop (`:3685-3706`). The refused ones and those
  last are stranded rows of T-PARKED-REPLAY: answered `Buffered` on redelivery, and delivered
  only by this device's next own confirm or rollback (a re-join's own replay delivers what was parked for the new copy's epochs — a
  commit that raced ahead of the re-add Welcome — and ends rows from before the new copy's join epoch undelivered). So a green "the
  fix surfaces on confirm" test
  says nothing about a confirm whose replay did not run or did not finish.

### Leave / SelfRemove

- `SendIntent::Leave { group_id }` → a MIP-03 **SelfRemove proposal** (`PublishWork::Proposal`,
  no pending ref — the leaver does not commit its own removal).
- Any remaining member's engine **auto-commits** the proposal
  (`PublishWork::AutoPublish { pending, .. }` — recorded, driven and confirmed on the first
  relay ack like any evolution).
- Admin gating: `AdminCannotSelfRemove` / `AdminDepletion` — an admin must leave the admin set
  first (Haven's `plan_leave` maps this onto its promote-successor/self-demote state machine).
- **Required capability — the self-remove feature registry (load-bearing!)**: the engine's default
  `FeatureRegistry` is EMPTY, so leaves would advertise no `self-remove` proposal capability and a
  peer's auto-commit would fail `ProposalValidationError(UnsupportedProposalType)` — i.e. leaving
  would be silently broken. Haven registers `Feature("self-remove")` →
  `Capability::Proposal(10)` at `RequirementLevel::Required` on every session
  (`self_remove_feature_registry()` in `manager.rs`), which makes `fresh_key_package` advertise
  it and `create_group` require it. This matches the 30443 `mls_proposals` tag (`0x000a` = 10).
- The leaver side is the driver's `Publishing::leave` / `resume_leave`: the intent is written
  first (no location is sealed for the circle from then on), the proposal is recorded and its
  frozen bytes re-sent within an epoch, the engine mints the next one for a later epoch, and the
  leave ends on this device once its copy is marked removed or held unrecoverable (MDK refuses
  every outbound intent on a halted group, so nothing could be sent) or `LEAVE_BOUND_MS` has
  passed.

### Exporter secrets

`session.exporter_secret(&gid, label, len) -> SecretBytes` (= `Zeroizing<Vec<u8>>`), current
epoch. Retention: `DEFAULT_MAX_PAST_EPOCHS = 5` (`cgka-engine/src/wire_format.rs:46`, derived
from convergence policy v1's `V1_APP_MESSAGE_PAST_EPOCH_LIMIT`; it replaced the MIP-era name
`DEFAULT_EPOCH_LOOKBACK` — same number). Haven does not override it (Rule 5), and
holds essentially no exporter secrets app-side anymore — the peeler owns the 445 crypto.

### Errors

`EngineError` is typed (`UnknownGroup, NotGroupAdmin, AdminCannotSelfRemove, AdminDepletion,
MissingRequiredCapabilities, UnsupportedCiphersuite, InvalidAppMessagePayload,
InvalidAccountIdentityProof, InvalidKeyPackageLifetime, ForkedEpoch, Storage(..), Peeler(..),
…`); `PeelerError::{Malformed, InvalidSignature, WrongRecipient, DecryptFailed, StaleEpoch,
MissingContext, WrapFailed, Backend}`.
Retryability: `EngineError::is_transient()` (only `StorageError::Busy`); message-level retry is
the `MessageState` machine; `StaleReason` classifies non-errors, several of its old reasons
deprecated in favour of `IngestOutcome::Ignored { category }` and `LocalState`. #864 (five
validators embedding full group-id hex) was fixed upstream in v0.9.5; Haven still keeps
`redact_hex_sequences` at the `map_mls_err` boundary (Rules 6/8). Note: a never-seen group surfaces as
`Storage(NotFound)`, while `UnknownGroup` means a *quarantined* group (mdk#364) —
`SessionManager::find_group` maps both to `Ok(None)`.

---

## Haven-Specific Choices

These are Haven decisions layered on the engine — not upstream defaults. Do not "simplify" them
away.

### Hold-before-ingest welcomes (accept / decline)

Upstream has **no Declined state** for a first invitation: ingesting a 1059 auto-joins, and MDK's
own app layer declines by leaving the group it already joined (`marmot-app`
`decline_group_invite`) — **visible on the wire and consumes the invite**. (Only a replacement
Welcome waits for explicit consent: `LocalIngestState::RejoinConfirmationRequired`, answered by
`confirm_group_rejoin` / `decline_group_rejoin`.) Haven preserves its
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
- **Decline** = `CircleManager::decline_invitation` → `PendingWelcomeStore::remove_recording` — a
  local drop; nothing on the wire.

### Convergence policy: `settlement_quiescence_ms = 0`

**No longer a Haven choice.** Haven set quiescence 0 at session open under the v0.9.4 pin; at
v0.10.4 convergence policy v1 is a protocol constant every client MUST use exactly
(`protocol-core/convergence.md:41-71`: `max_rewind_commits` 5, app-payload window 5 epochs,
`settlement_quiescence_ms` 1000, `max_convergence_pass_ms` 5000, witness quorum 2 senders × 1
epoch), and `AccountDeviceSession::open` refuses any other policy outside MDK's
`test-policy-overrides` builds (`cgka-engine/src/canonicalization.rs:117-128`). Haven installs
none. So a lone commit can ingest as `Buffered` until its pass's quiescence window closes; Haven's
planes re-advance a group the engine still owes a deadline once it falls due (bounded,
`relay::retick`), so nothing waits for an unrelated later event.

### Single session (Rule 14) and locking

See the boxed rule above. Practical shape: `SessionManager` holds the one
`tokio::sync::Mutex<AccountDeviceSession>`; the mutex guard is held across the mutators' internal
awaits (hence a tokio, not std, mutex); the M7 background-catchup path shares the same manager
instead of opening a second session; `write_lock.rs` is deleted.

### SQLCipher key custody (`session.sqlite`)

`storage-sqlite` takes a **passphrase** (`SqlCipherKey`, PBKDF2 via `PRAGMA key = '<str>'`,
`cipher_compatibility = 4`) and does not touch the platform keyring — Haven provisions the key
(`haven-core/src/nostr/mls/storage.rs`; the file is `session-v2.sqlite` since the v0.10.4 reset):
mint 32 `OsRng` bytes once, store the RAW bytes in the keyring under
(`com.oblivioustech.haven`, **`mls.session.key.v2`**), derive the passphrase
as their lowercase-hex encoding (64 chars, `Zeroizing` end-to-end, never logged). The PBKDF2
stretch is defense-in-depth over already-256-bit material. This is deliberately **incompatible**
with `circles.db`/`tiles.db`, which keep the raw-key form (`PRAGMA key = "x'<64-hex>'"`, KDF
bypassed). Storage options are the hardened defaults: **WAL** (the old DB was rollback-journal),
`secure_delete`, `cipher_memory_security`. The legacy `haven_mdk.db` + its `mdk.db.key.default`
keyring entry are deleted/destroyed at cutover — **key destruction is the practical secure-erase**
(security F6). The v0.10.4 reset does the same for the v0.9.4 stores (`session.sqlite` /
`mls.session.key.default`, and the circle and tile databases; `haven-core/src/storage_reset.rs`).
iOS: the new key gets the same `AfterFirstUnlockThisDeviceOnly` policy migration.

### Haven keeps its own relay plane

Subscriptions, cursors, health, catch-up sweeps, the NIP-77 by-id pass and the **fanout driver**
that sends every commit, recorded proposal and Welcome from MDK's own durable records stay
Haven-owned (the adapter's `NostrTransportAdapter` is not adopted; its relay client is used for
one thing, a classified publish to one relay on Haven's publish client, and its
`reconcile_subscription` is never called — `haven-core/src/relay/negentropy.rs` says why).
The peeler owns the 1059 *crypto*; Haven's old `giftwrap` decrypt path is deleted. Raw `Event` ↔
`TransportMessage` conversion via `NostrTransportEvent`
(`SessionManager::event_to_transport_message` / `transport_message_to_event`).

---

## Old vs New: Migration Reference

For developers reading pre-2026-07 Haven code, tests, or git history. Any ONE of the starred (★)
rows independently breaks cross-version interop — there is no bridge mode (no 443 reader, no
`0xF2EE` parser, no `"nostr"`-label fallback) — which is why the migration was a hard flag-day
with wipe-and-recreate of all MLS state (identity/nsec, kind-0 profile, and petnames survived).
The move to v0.10.4 was a second hard reset (`haven-core/src/storage_reset.rs`). The NEW column
states the current pin.

| Surface | OLD (MIP era / mdk-core 0.7.1) | NEW (Dark Matter, v0.10.4) |
|---|---|---|
| ★ KeyPackage kind | 443 (regular event, `encoding` tag, twin-published) | **30443** addressable (`d` slot, `i` ref, no encoding/relays tags) |
| KP discovery | kind 10051 KeyPackage-relay list | **NIP-65 kind 10002** (10051 abolished + retracted; breaking in combination with the KP-kind change) |
| ★ 445 exporter label | `MLS-Exporter("nostr", "nostr", 32)` | `MLS-Exporter("marmot", "group-event", 32)` = `"marmot/group-event"` |
| 445 AEAD shape | base64(nonce‖ct), 12-byte nonce, empty AAD, ChaCha20-Poly1305, ephemeral key/msg | **identical** — only the label differs |
| 445 tags | `h` + `["encoding","base64"]` (+ per-send NIP-40 expiration) | exactly one `h` (+ `expiration` on application messages); any other tag is `Malformed`; expiration = group-level retention component |
| ★ Group metadata | `NostrGroupDataExtension` `0xF2EE` (name/desc/admins/relays/nostr_group_id) | **app components** in `app_data_dictionary` (0x8001/0x8003/0x8004…) |
| ★ Leaf credential | BasicCredential = pubkey hex, no proof | + **required** `marmot.member.account-identity-proof.v2` LeafNode component (`0x8009`, kind-450; the v0.9.4 pin carried it as leaf ext `0xF2F1`) |
| Welcome (444/1059) | same skeleton, loose tags | same skeleton, **strict** exactly-one `e`/`relays` + relay-set bounds (≤16 / ≤512 B / ws-wss) |
| Inner message | unsigned rumor, loose | `MarmotAppEvent`: canonical NIP-01 id, `pubkey` == MLS sender (enforced) |
| Ciphersuite | 0x0001 | 0x0001 — unchanged |
| Manager | `MdkManager` (sync, `&self`, interior-mutable) | `SessionManager` over `tokio::sync::Mutex<AccountDeviceSession>` (async, `&mut`) |
| Construction | `MDK::new(MdkSqliteStorage::new(path, key)?)` | `SessionConfig` (+ REQUIRED proof signer) → `AccountDeviceSession::open` |
| Receive | `process_message` → `MessageProcessingResult` | `ingest` → `IngestOutcome` × `GroupEvent` stream |
| Commit lifecycle | `merge_pending_commit` / `clear_pending_commit` + Haven staged-commit marker (`staged_commits` table) | `confirm_published_fanout` / `publish_failed_fanout` over a durable MDK fanout record, driven by `relay/fanout.rs`; `EpochState::PendingPublish`; `PendingCommitRecovered` at hydrate |
| Out-of-order commits | Haven `retry_failed_future_epoch_messages` (#633 un-poison) + `peek_crypto.rs` + settle-window layer (`settle`/`finalize`/`converge`/`autocommit`/`plan`) + `commit_order_key` | **engine-owned**: stored-convergence buffer + `advance_convergence` + `CommitOrderingKey` branch selection (all the Haven modules deleted) |
| Writer serialization | process-global `write_lock.rs` | the session mutex + **Rule 14** (one session per DB file) |
| MLS DB | `haven_mdk.db`, rollback journal, raw hex key (`mdk.db.key.default`) | `session-v2.sqlite`, **WAL**, passphrase via PBKDF2 (`mls.session.key.v2`); new `cgka_*` schema, **no importer** |
| KP lifecycle | single-consumption KPs; M8-2 `has_live_key_material` gate | every KP last-resort; MDK's durable `KeyPackageLifecycleState` (stage → ack → promote); gate deleted |
| Welcome accept/decline | MDK pending-welcome state (`accept_welcome`/`decline_welcome`) | engine auto-joins on ingest; Haven **hold-before-ingest** store preserves decline-no-trace |
| Leave | Haven `LeavePlan` + eager self-finalized commit paths | `SendIntent::Leave` → SelfRemove proposal; peers auto-commit (`AutoPublish`); registry `Capability::Proposal(10)` required |
| Retention name | `DEFAULT_EPOCH_LOOKBACK = 5` | `DEFAULT_MAX_PAST_EPOCHS = 5` (same number, engine-internal) |
| Test fixture | `MdkManager::new_unencrypted()` ×2 | `SessionManager::new_unencrypted(dir, &keys)` ×2 (fixed-passphrase temp SQLCipher DB); two-party idiom (`tests/helpers/mod.rs` `setup_two_party_group`): Bob's 30443 → `create_group` (canonical on return, nothing to confirm) → Bob's `accept_welcome` on the founding 1059 |

---

## Nostr Integration

### NIP Dependencies

| NIP | Purpose |
|-----|---------|
| NIP-01 | Basic protocol, events, signatures; canonical event ids (inner messages, identity proof) |
| NIP-09 | Deletion requests (malformed-KeyPackage-slot retraction; best-effort relay hygiene) |
| NIP-17 | Inbox relays (kind 10050) for gift-wrap delivery |
| NIP-33 | Parameterized-replaceable events (kind 30443 KeyPackages, `d` slot) |
| NIP-40 | Expiration (via the group-level `message-retention.v1` component) |
| NIP-59 | Gift wrapping (welcome delivery, kind 1059) |
| NIP-65 | Relay lists (kind 10002) — the KeyPackage discovery plane |
| NIP-77 | Negentropy — Haven's own dry-run by-id recovery of a circle's kind-445 window (`RelayManager::neg_remote_ids`, on the publish client; an empty local set, so the relay learns nothing the device holds) |

Note: **NIP-44 is no longer part of the 445 path** (the outer layer is raw ChaCha20-Poly1305 keyed
by the MLS exporter); NIP-59's internals still use NIP-44 for the seal, inside the peeler.

### Relay Usage

**KeyPackage publishing**: the account's **own NIP-65 (10002) relays** — never a
discovery/default union (own-relays-only invariant in `key_package.rs` maintenance). **Fetching an
invitee's**: their 10002 write-capable set, with the read-only discovery plane as fallback.

**Group messages (445)**: published to the group's relays from the `NostrRoutingV1` component
(0x8004); subscribed by `#h` filter on the same set. A routing update's commit goes to the prior
epoch's address, and members keep fetching a prior `#h` while an epoch that used it is retained
(`app-components/nostr-routing-v1.md`, "Routing rotation"); Haven's relay change keeps the circle's
`nostr_group_id` (`relay_update_intent`, `manager.rs`), and Haven never rotates it.

**Welcomes (1059)**: gift-wrapped to the recipient and published to their **10050 inbox relays**
alone (filtered as any foreign list; no NIP-65 tier, never the sender's own inbox; an invitee with
none cannot be invited). The peeler only does the crypto. Every Welcome is delivered from MDK's own
`DurableTransportFanout` record: an invite's is written at its hand-over — the first full drive that
settles the confirmed commit — and a founding one before the create returns. Haven drives it (full
drives only): the exact stored bytes, one relay at a time, no sooner than 30 s after the last
attempt doubling to an hour, until one inbox relay acknowledges it, for a day from the hand-over or
until an hour before the invitee's 96 h inbox window would lose the backdated wrap, whichever is
sooner (tracker `T-WELCOME-OUTBOX`). The app invites and creates only through the driver
(`add_members_driven`, `create_circle_driven`), and the plain publish entry refuses every kind 1059.

**nostr crate API reminder** (CLAUDE.md): `Filter::pubkey()` filters by `#p` tag (recipient),
**not** event author; use `Filter::author()` for the author field.

---

## Development Guidelines

### Toolchain

- Required: **rustc ≥ 1.97.1** (MDK's `rust-toolchain.toml` pins 1.97.1; CLAUDE.md: the SQLCipher
  patch needs `cfg_select!`). The upstream workspace is edition 2024, resolver 3; Haven's 2021-edition
  crates depend on it — edition is per-crate.
- Pinned alongside: the OpenMLS fork rev MDK requires (`erskingardner/openmls@59e7d3b`, `openmls`
  0.8.1, feature `extensions-draft`), `rusqlite =0.40.1` / `libsqlite3-sys =0.38.1` with the
  SQLCipher 4.17 `[patch.crates-io]` in every Cargo root, and `nostr` 0.44 (0.44.8 in the lockfile).
- The six MDK crates are **git dependencies at one pinned rev** (released tags only — see
  CLAUDE.md "MDK pinning"). They are not on crates.io and never will be until upstream says so.

### Testing against the engine

```bash
cd haven-core && cargo test          # full suite (in-memory / temp-file SQLCipher sessions)
cd haven-core && cargo clippy --all-targets -- -D warnings
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
| Mint a KeyPackage + 30443 event | `build_kp_maintenance_events(session, keys, own_kp_relays, existing_d, prev_created_at)` |
| Create a circle | `relay::fanout::Publishing::create_circle` (bridge `create_circle_driven`); underneath, `SessionManager::create_group` returns `FoundingGroupCreated` — nothing to confirm |
| Add / remove members, relay change, hand-over, step-down, repair | `Publishing::{add_members, remove_members, update_relays, admin_handoff, self_demote, repair_rotation}` — stage under a durable record, drive, answer a typed outcome (bridge `*_driven`) |
| Send a location | `Publishing::seal_location` / `publish_location_and_bridge`, whose own send is `publish_location` (bridge `seal_location_driven` / `publish_location_driven`); for the Bluetooth mesh alone, `Publishing::seal_for_mesh` (bridge `seal_location_for_mesh_driven`) and the same send |
| Read what the Bluetooth mesh received | `Publishing::mesh_drive` (bridge `mesh_drive_driven`) — application messages only, no relay called (`docs/BLUETOOTH_MESH_PLAN.md` §5.2) |
| Receive | `process_event(&event)` → branch on `IngestOutcome`, drain `GroupEvent`s |
| Tick convergence | `advance_convergence(gid)` after ingest batches |
| Drive stored records | `Publishing::resume` (bridge `resume_driven`) |
| Leave | `Publishing::leave` / `resume_leave` (SelfRemove proposal under a record — no confirm) |
| Group routing | `group_routing(gid)` / `nostr_group_id_hex(gid)` / `group_relays(gid)` |
| Welcome preview / accept / decline | `preview_welcome` / `accept_welcome` / `CircleManager::decline_invitation` |

---

## Security Best Practices

### For Application Developers

1. **Wire the identity-proof signer hardened**: recompute-and-sign only the canonical kind-450 id,
   refuse foreign identities, purpose-scope over the nsec (see `signer.rs`). A passthrough signer
   is a blind identity-key oracle.

2. **Respect the retention window**: old exporter secrets age out at `DEFAULT_MAX_PAST_EPOCHS = 5`
   past epochs (Haven does not override). Never retain secrets beyond in-flight decryption needs.

3. **Encrypt at rest**: platform keyring for DB keys; SQLCipher for MLS state
   (`session-v2.sqlite`), circles, tiles. See `haven-core/SECURITY.md`.

4. **Publish-before-apply, honestly**: record every commit durably before any byte leaves; confirm
   only after a real ≥1-relay OK-ack. Optimistic confirm = fork exposure. Roll back only on proof
   that no relay took it — a timeout is possibly exposed, so resend the same bytes;
   `PendingCommitRecovered` = mandatory resync.

5. **One session per DB file** (Rule 14) — across isolates AND processes. This is a
   confidentiality control, not a tidiness rule.

6. **Backpressure, never silent drops** (Rule 12): future-epoch backlog after offline periods is
   legitimate traffic; rate-limit intake, don't discard. Know that the engine buffer itself is
   unbounded (#757, closed upstream as not planned).

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
❌ Confirm a commit on "sent" rather than "acked", or roll one back on a timeout (Rule 13)
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
3. **Offline support**: queue location shares; the engine's convergence buffer keeps offline
   backlog, but catch-up is not lossless: application payloads older than the 5-epoch window are
   gone (`protocol-core/retained-history.md`: no complete offline-history guarantee), and a
   relay's replay cap can bury input. Pair it with cursor discipline (never advance past
   `Buffered` or `ResourceRefused`; `relay::catchup::cursor_verdict`)
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
  proof component 0x8009 (and the legacy 0xF2F1 classifier) / kind-450, `CommitOrderingKey`,
  last-resort KPs, `DEFAULT_MAX_PAST_EPOCHS`, `PURE_PLAINTEXT` policy; `canonicalization.rs` —
  convergence policy v1
- `crates/traits/src/{types.rs,welcome.rs,ingest.rs,engine.rs,storage.rs}` and
  `crates/traits/src/app_components/{mod,codec,routing}.rs` — component ids, `NostrRoutingV1`
- `crates/cgka-session/src/lib.rs`, `crates/storage-sqlite/src/connection.rs`
- Spec: `foundation/{canonical-encoding,application-messages,registries,key-packages}.md`,
  `app-components/account-identity-proof-v2.md` (v1 superseded), `transports/nostr.md`,
  `protocol-core/{convergence,publish-lifecycle,durability}.md`

### Haven implementation anchors

- `haven-core/src/nostr/mls/{manager,storage,signer,welcome,types}.rs` — SessionManager, key
  custody, hardened proof signer, hold-before-ingest store
- `haven-core/src/relay/maintenance/key_package.rs` — 30443 building, maintenance decision,
  malformed-slot retirement
- `haven-core/src/relay/fanout.rs` — the fanout driver (Rule 13); `haven-core/src/relay/negentropy.rs`
  — the NIP-77 pass; `haven-core/src/storage_reset.rs` — the v0.10.4 reset
- `docs/MDK_DARKMATTER_MIGRATION_PLAN.md` — the executed 2026-07 migration plan (wire matrix §4,
  security rules §7)
- `docs/MDK_UPSTREAM_TRACKER.md` — every Haven mitigation of an MDK gap, with its pinning test
- `haven-core/SECURITY.md` — key-custody table, threat-model notes (F6/F12, Rule 14, #757)

### Nostr Resources

- [Nostr Protocol](https://github.com/nostr-protocol/nostr)
- [NIPs Repository](https://github.com/nostr-protocol/nips)
- [NIP-EE (Legacy, superseded by Marmot)](https://nips.nostr.com/EE)

### Related Projects

- [OpenMLS](https://github.com/openmls/openmls) — the MLS implementation under `cgka-engine`
  (0.8.1, through the `erskingardner/openmls` fork at `59e7d3b`, feature `extensions-draft`)
- [rust-nostr](https://github.com/rust-nostr/nostr) — Nostr Rust libraries (0.44)
- [whitenoise-ios](https://github.com/marmot-protocol/whitenoise-ios) and
  [whitenoise-android](https://github.com/marmot-protocol/whitenoise-android) — the current
  reference clients (AGPL-3.0), on MDK's own runtime through its UniFFI bindings
- [whitenoise-rs](https://github.com/marmot-protocol/whitenoise-rs) — the former reference app
  library (AGPL-3.0), archived 2026-08-05; its master pinned old `mdk-core 0.8.0`, so it is an
  old-era reference only. The Flutter app `whitenoise_flutter` is archived too (now
  `marmot-protocol/whitenoise-archive`).

---

## Version History

| Date | Changes |
|------|---------|
| 2026-01-31 | Initial document creation (MIP era, mdk-core 0.5–0.7) |
| 2026-07-12 | Upstream MIP-deprecation note; profiles-out-of-scope clarification |
| 2026-07-17 | **Dark Matter rewrite**: Marmot v2 wire format (30443/10002, `"marmot/group-event"`, app components, identity proof v2), `AccountDeviceSession` engine model, Haven-specific choices, old-vs-new migration reference |
| 2026-10-26 | **MDK v0.10.4**: identity proof as component 0x8009, required 0x800c, Current-profile-only sessions, convergence policy v1 (Haven's quiescence 0 dropped), the fanout driver and durable Welcome records (Rule 13), founding creates with nothing to confirm, 445 tag rejection, NIP-77 by-id pass, the storage reset; current reference clients |

---

*This document is a Claude knowledge reference for developing against the Marmot Protocol as
Haven ships it. Where the published spec and the pinned MDK code disagree, the code is
authoritative; always re-verify against the pinned rev before relying on a wire-format detail.*
