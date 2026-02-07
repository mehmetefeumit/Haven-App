# Marmot Protocol Knowledge Document

> **Purpose**: Reference documentation for building secure, decentralized applications using the Marmot Protocol ecosystem, including the Marmot Development Kit (MDK) and whitenoise-rs library.

---

## Table of Contents

1. [Overview](#overview)
2. [Protocol Architecture](#protocol-architecture)
3. [Security Model](#security-model)
4. [Marmot Implementation Proposals (MIPs)](#marmot-implementation-proposals-mips)
5. [MDK (Marmot Development Kit)](#mdk-marmot-development-kit)
6. [whitenoise-rs Library](#whitenoise-rs-library)
7. [Nostr Integration](#nostr-integration)
8. [Event Kinds & Data Structures](#event-kinds--data-structures)
9. [API Reference](#api-reference)
10. [Development Guidelines](#development-guidelines)
11. [Security Best Practices](#security-best-practices)
12. [Location Sharing Considerations](#location-sharing-considerations)

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
| [marmot-protocol/marmot](https://github.com/marmot-protocol/marmot) | Protocol specifications (MIPs) | MIT |
| [marmot-protocol/mdk](https://github.com/marmot-protocol/mdk) | Rust SDK implementation | MIT |
| [marmot-protocol/whitenoise-rs](https://github.com/marmot-protocol/whitenoise-rs) | Full messaging application library | AGPL-3.0 |

### Current Status

⚠️ **ALPHA STATUS**: All implementations are experimental. The protocol may undergo breaking changes. Not recommended for production until stable release.

---

## Protocol Architecture

### Core MLS Concepts

**Groups**: Created with a random 32-byte ID (kept private). Groups evolve through epochs, with changes proposed via `Proposal` messages and committed via `Commit` messages.

**Clients/Members**: Each device/client pair (e.g., "App X on iOS") is a `LeafNode` in the MLS tree. State cannot be shared across clients - joining from 2 devices creates 2 separate members.

**Message Types**:
- **Control Messages**: `Welcome`, `Proposal`, `Commit` (group state evolution)
- **Application Messages**: Actual content sent between members

### MLS Configuration

```rust
// Default ciphersuite for all MDK/Marmot groups
const DEFAULT_CIPHERSUITE: Ciphersuite = 
    Ciphersuite::MLS_128_DHKEMX25519_AES128GCM_SHA256_Ed25519;

// Required MLS extensions for Nostr integration
const REQUIRED_EXTENSIONS: &[ExtensionType] = &[
    ExtensionType::ApplicationId,
    ExtensionType::RatchetTree,
    ExtensionType::RequiredCapabilities,
    ExtensionType::Unknown(0xF2EE),  // Marmot Group Data Extension
];
```

### Data Flow Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                      CLIENT DEVICE                          │
│  ┌─────────────────────────────────────────────────────┐   │
│  │  Application Layer (your location sharing app)      │   │
│  │  - Constructs unsigned Nostr events (kind: 9, etc) │   │
│  │  - Handles UI/UX for location sharing              │   │
│  └─────────────────────────────────────────────────────┘   │
│                          │                                  │
│  ┌─────────────────────────────────────────────────────┐   │
│  │  whitenoise-rs (Application Library)                │   │
│  │  - Manages groups, messages, and user state        │   │
│  │  - Handles relay connections                       │   │
│  │  - Stores encrypted data locally                   │   │
│  └─────────────────────────────────────────────────────┘   │
│                          │                                  │
│  ┌─────────────────────────────────────────────────────┐   │
│  │  MDK (Marmot Development Kit)                       │   │
│  │  - MLS group management                            │   │
│  │  - Key package creation/rotation                   │   │
│  │  - Message encryption/decryption                   │   │
│  └─────────────────────────────────────────────────────┘   │
│                          │                                  │
│  ┌─────────────────────────────────────────────────────┐   │
│  │  OpenMLS (Cryptographic Engine)                     │   │
│  │  - RFC 9420 MLS implementation                     │   │
│  │  - Ratchet tree management                         │   │
│  │  - Cryptographic operations                        │   │
│  └─────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────┘
                           │
                           ▼
           ┌───────────────────────────────┐
           │      Nostr Relay Network      │
           │  - Gift-wrapped Welcomes      │
           │  - Ephemeral Group Events     │
           │  - KeyPackage Events          │
           └───────────────────────────────┘
```

---

## Security Model

### Forward Secrecy & Post-Compromise Security

- **Forward Secrecy**: Past messages remain secure even if current keys are compromised
- **Post-Compromise Security (PCS)**: Key rotation limits impact of future compromises
- Keys are deleted immediately after use (handled by MLS implementation)

### Key Independence

**Critical**: Marmot does NOT depend on a user's Nostr identity key (nsec) for MLS messaging:
- Compromise of Nostr identity key does NOT give access to past/future group messages
- MLS signing keys are DISTINCT from Nostr identity keys
- Signing keys SHOULD be rotated regularly

### Metadata Protection

- **Group ID**: Only `nostr_group_id` (from extension) is published; real MLS group ID stays private
- **Ephemeral Publishing**: Group events use ephemeral keypairs - new keypair per event
- **Gift-Wrapped Welcomes**: NIP-59 gift-wrap hides sender/recipient of invitations

### Threat Considerations

| Threat | Mitigation |
|--------|------------|
| Nostr key compromise | MLS keys independent; group messages remain secure |
| Device compromise | Encrypt at rest, rotate keys, remove inactive members |
| Relay compromise | Messages E2E encrypted; relays see only metadata |
| Network observer | Ephemeral keypairs, NIP-44/59 encryption layers |

---

## Marmot Implementation Proposals (MIPs)

### Required MIPs (for Marmot compatibility)

| MIP | Description | Status |
|-----|-------------|--------|
| **MIP-00** | Credentials & Key Packages | 👀 Review |
| **MIP-01** | Group Construction & Marmot Group Data Extension | 👀 Review |
| **MIP-02** | Welcome Events | 👀 Review |
| **MIP-03** | Group Messages | 👀 Review |

### Optional MIPs

| MIP | Description | Status |
|-----|-------------|--------|
| **MIP-04** | Encrypted Media (images, files via Blossom) | 🚧 Draft |

### MIP-00: Credentials & Key Packages

**MLS Credentials**:
- Use `BasicCredential` type
- `identity` field = 32-byte hex-encoded Nostr public key
- Signing key MUST be different from Nostr identity key
- Signing key SHOULD be rotated over time

**KeyPackage Event (kind: 443)**:
```json
{
  "kind": 443,
  "pubkey": "<main identity pubkey>",
  "content": "<hex-encoded serialized KeyPackageBundle>",
  "tags": [
    ["mls_protocol_version", "1.0"],
    ["ciphersuite", "0x0001"],
    ["extensions", "0x0001, 0x0002, ..."],
    ["client", "<client name>", "<handler event id>", "<relay url>"],
    ["relays", "<relay1>", "<relay2>", ...],
    ["-"]
  ]
}
```

**KeyPackage Relays List (kind: 10051)**:
```json
{
  "kind": 10051,
  "tags": [
    ["relay", "wss://inbox.example.com"],
    ["relay", "wss://relay.example.com"]
  ],
  "content": ""
}
```

### MIP-01: Nostr Group Data Extension

Extension ID: `0xF2EE`

**Stored Data**:
- `nostr_group_id`: 32-byte ID for Nostr (different from MLS group ID, can be rotated)
- `name`: Group name
- `description`: Group description
- `admin_pubkeys`: Array of admin Nostr public keys
- `relays`: Array of relay URLs for the group
- `image_hash`, `image_key`, `image_nonce`: (optional) encrypted group image

### MIP-02: Welcome Events

**Welcome Event (kind: 444)** - sent via NIP-59 gift-wrap:
```json
{
  "kind": 444,
  "pubkey": "<sender nostr pubkey>",
  "content": "<serialized MLSMessage Welcome object>",
  "tags": [
    ["e", "<KeyPackage Event ID used>"],
    ["relays", "<relay1>", "<relay2>", ...]
  ]
}
```
**CRITICAL**: Kind 444 events MUST NOT be signed (ensures unpublishable if leaked).

### MIP-03: Group Messages

**Group Event (kind: 445)**:
```json
{
  "kind": 445,
  "pubkey": "<ephemeral pubkey - new per message>",
  "content": "<NIP-44 encrypted serialized MLSMessage>",
  "tags": [
    ["h", "<nostr_group_id>"]
  ]
}
```

**Encryption Process**:
1. Create MLSMessage (serialized TLS-style)
2. Generate keypair from MLS `exporter_secret` (32-byte, labeled "nostr")
3. Use that keypair for NIP-44 encryption
4. Publish with NEW ephemeral keypair

**Application Messages** (inner content):
- Unsigned Nostr events of appropriate kind
- Use `kind: 9` for chat messages
- `pubkey` must match member's Nostr identity
- MUST NOT include "h" tags or group identifiers

### MIP-04: Encrypted Media (Optional)

Enable with feature flag: `features = ["mip04"]`

For encrypted image/file sharing via Blossom servers. Media is encrypted client-side before upload.

---

## MDK (Marmot Development Kit)

### Installation

```toml
[dependencies]
mdk-core = "0.5.0"
mdk-memory-storage = "0.5.0"   # Development/testing
# OR
mdk-sqlite-storage = "0.5.0"   # Production with persistence

# Optional: encrypted media support
mdk-core = { version = "0.5.0", features = ["mip04"] }
```

### Crate Architecture

| Crate | Purpose |
|-------|---------|
| `mdk-core` | Main library: MLS + Nostr integration |
| `mdk-storage-traits` | Storage abstraction layer |
| `mdk-memory-storage` | In-memory storage (testing) |
| `mdk-sqlite-storage` | SQLite persistent storage |

### Quick Start Example

```rust
use mdk_core::prelude::*;
use mdk_memory_storage::MdkMemoryStorage;
use nostr::{Keys, Kind, RelayUrl};
use nostr::event::builder::EventBuilder;

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    // 1. Generate identities
    let alice_keys = Keys::generate();
    let bob_keys = Keys::generate();

    // 2. Create MDK instances
    let alice_mdk = MDK::new(MdkMemoryStorage::default());
    let bob_mdk = MDK::new(MdkMemoryStorage::default());

    let relay_url = RelayUrl::parse("wss://relay.example.com")?;

    // 3. Bob creates a key package
    let (bob_key_package, tags) = bob_mdk
        .create_key_package_for_event(&bob_keys.public_key(), [relay_url.clone()])?;

    let bob_key_package_event = EventBuilder::new(Kind::MlsKeyPackage, bob_key_package)
        .tags(tags)
        .build(bob_keys.public_key())
        .sign(&bob_keys)
        .await?;

    // 4. Alice creates a group with Bob
    let config = NostrGroupConfigData::new(
        "Alice & Bob".to_string(),
        "Private chat".to_string(),
        None, None, None,  // image fields
        vec![relay_url],
        vec![alice_keys.public_key(), bob_keys.public_key()],
    );

    let group_result = alice_mdk.create_group(
        &alice_keys.public_key(),
        vec![bob_key_package_event],
        config,
    )?;

    // 5. Bob processes the welcome message
    let welcome_rumor = &group_result.welcome_rumors[0];
    bob_mdk.process_welcome(&nostr::EventId::all_zeros(), welcome_rumor)?;

    let welcomes = bob_mdk.get_pending_welcomes()?;
    bob_mdk.accept_welcome(&welcomes[0])?;

    // 6. Alice sends a message
    let message_rumor = EventBuilder::new(Kind::Custom(9), "Hello Bob!")
        .build(alice_keys.public_key());

    let message_event = alice_mdk.create_message(
        &group_result.group.mls_group_id,
        message_rumor
    )?;

    // 7. Bob processes the message
    bob_mdk.process_message(&message_event)?;

    Ok(())
}
```

### Key MDK Functions

```rust
// Key Package Management
mdk.create_key_package_for_event(pubkey, relays) -> (String, Tags)

// Group Management
mdk.create_group(creator_pubkey, key_package_events, config) -> GroupCreateResult
mdk.process_welcome(event_id, welcome_rumor) -> ()
mdk.get_pending_welcomes() -> Vec<PendingWelcome>
mdk.accept_welcome(pending_welcome) -> Group

// Messaging
mdk.create_message(mls_group_id, rumor) -> Event
mdk.process_message(event) -> ProcessedMessage

// Group Operations
mdk.add_members(mls_group_id, key_package_events) -> AddMembersResult
mdk.remove_members(mls_group_id, member_pubkeys) -> RemoveMembersResult
mdk.rotate_signing_key(mls_group_id) -> RotateResult
```

### Storage Backends

**In-Memory (Development)**:
```rust
use mdk_memory_storage::MdkMemoryStorage;
let mdk = MDK::new(MdkMemoryStorage::default());
```

**SQLite (Production)**:
```rust
use mdk_sqlite_storage::MdkSqliteStorage;
let storage = MdkSqliteStorage::new("path/to/database.db").await?;
let mdk = MDK::new(storage);
```

**Custom Storage**: Implement `MdkStorageProvider` trait.

---

## whitenoise-rs Library

### Overview

whitenoise-rs is the full application library built on MDK. It provides:
- Complete group and message management
- Relay connection handling
- Local encrypted storage
- Flutter bridge support (for whitenoise_flutter app)

### License Note

⚠️ **AGPL-3.0**: whitenoise-rs uses AGPL license. If you modify and distribute, you must release source code.

### Key Features

- Frontend-agnostic (supports Flutter, CLI, etc.)
- Integration testing suite
- Development Docker environment (relays + blossom server)

### Development Setup

```bash
# Clone repository
git clone https://github.com/marmot-protocol/whitenoise-rs.git
cd whitenoise-rs

# Start dev services (two Nostr relays + blossom server)
docker compose up -d

# Run integration tests
just int-test

# Pre-commit checks
just precommit
```

### Project Structure

```
whitenoise-rs/
├── src/                    # Rust source code
├── db_migrations/          # SQLite migrations
├── docs/                   # Documentation
├── dev/                    # Development utilities
├── scripts/                # Build/test scripts
├── .test/                  # Test fixtures
├── docker-compose.yml      # Dev environment
└── justfile                # Task runner commands
```

---

## Nostr Integration

### Event Kinds Used

| Kind | Name | Description |
|------|------|-------------|
| 443 | MlsKeyPackage | KeyPackage for MLS group joining |
| 444 | Welcome | Group invitation (gift-wrapped) |
| 445 | GroupMessage | Encrypted group messages |
| 10051 | KeyPackageRelaysList | Where to find user's KeyPackages |
| 9 | ChatMessage | Application-level chat content |

### NIP Dependencies

| NIP | Purpose |
|-----|---------|
| NIP-01 | Basic protocol, events, signatures |
| NIP-44 | Encryption scheme (for group messages) |
| NIP-59 | Gift wrapping (for welcome events) |
| NIP-70 | Protected events (optional `-` tag) |

### Relay Usage

**KeyPackage Publishing**:
- Publish to relays listed in `relays` tag
- Query user's kind:10051 event for their KeyPackage relay list

**Group Messages**:
- Publish to relays in group's `NostrGroupData.relays`
- Use ephemeral keypairs (new per message)

**Welcome Events**:
- Gift-wrap and send directly to recipient
- Include relay list in tags

---

## Event Kinds & Data Structures

### NostrGroupConfigData

```rust
pub struct NostrGroupConfigData {
    pub name: String,
    pub description: String,
    pub image_hash: Option<String>,    // Blossom hash
    pub image_key: Option<Vec<u8>>,    // Encryption key
    pub image_nonce: Option<Vec<u8>>,  // Encryption nonce
    pub relays: Vec<RelayUrl>,
    pub admin_pubkeys: Vec<PublicKey>,
}
```

### GroupCreateResult

```rust
pub struct GroupCreateResult {
    pub group: Group,
    pub welcome_rumors: Vec<UnsignedEvent>,  // Send to new members
    pub commit_event: Event,                  // Publish to group relays
}
```

### Application Message Format

Inner content of kind:445 events should be unsigned Nostr events:

```json
{
  "kind": 9,
  "pubkey": "<member's nostr identity pubkey>",
  "created_at": 1234567890,
  "content": "Hello, group!",
  "tags": []
}
```

**For location sharing**, you might use a custom kind or kind:9 with structured content:
```json
{
  "kind": 9,
  "pubkey": "<member pubkey>",
  "content": "{\"type\":\"location\",\"lat\":37.7749,\"lon\":-122.4194,\"accuracy\":10}",
  "tags": [
    ["t", "location"]
  ]
}
```

---

## API Reference

### MDK Core Types

```rust
// Main MDK instance
pub struct MDK<Storage> { /* ... */ }

// Group representation
pub struct Group {
    pub mls_group_id: Vec<u8>,
    pub nostr_group_id: String,
    pub name: String,
    pub description: String,
    pub admin_pubkeys: Vec<PublicKey>,
    pub relays: Vec<RelayUrl>,
    // ...
}

// Pending welcome awaiting acceptance
pub struct PendingWelcome {
    pub welcome_id: String,
    pub group_name: String,
    pub inviter_pubkey: PublicKey,
    // ...
}

// Processed message result
pub struct ProcessedMessage {
    pub sender_pubkey: PublicKey,
    pub content: Vec<u8>,  // Deserialized inner event
    pub epoch: u64,
    // ...
}
```

### Error Handling

MDK functions return `Result<T, MdkError>`. Handle errors appropriately:

```rust
match mdk.create_group(pubkey, key_packages, config) {
    Ok(result) => { /* success */ },
    Err(MdkError::InvalidKeyPackage(e)) => { /* handle */ },
    Err(MdkError::StorageError(e)) => { /* handle */ },
    Err(e) => { /* other errors */ },
}
```

---

## Development Guidelines

### Rust Toolchain

- Required: Rust 1.90.0 or later
- Recommended: Install `just` for task running

```bash
# macOS
brew install just

# Run tests
just test

# Full check (like CI)
just check-full
```

### Testing Strategy

```bash
# MDK tests
cargo test -p mdk-core
cargo test --features mip04  # With encrypted media

# whitenoise-rs integration tests
just int-test  # Requires Docker services
```

### Code Quality

```bash
just fmt        # Format code
just lint       # Clippy checks
just docs       # Doc checks
just precommit  # All pre-commit checks
```

### Dependencies

Key dependencies in the ecosystem:

```toml
# MLS Implementation
openmls = "..."
openmls_rust_crypto = "..."

# Nostr
nostr = "..."
nostr-sdk = "..."

# Storage
rusqlite = "..."  # For mdk-sqlite-storage
```

---

## Security Best Practices

### For Application Developers

1. **Rotate signing keys regularly**: Call `mdk.rotate_signing_key()` after joining groups and periodically thereafter.

2. **Delete old secrets**: The `exporter_secret` should be deleted after ~2 epochs. MLS libraries handle most key deletion automatically.

3. **Encrypt at rest**: Use platform secure storage for:
   - Nostr identity keys
   - MLS group state
   - Local message database

4. **Remove inactive members**: Periodically audit and remove inactive group members to reduce attack surface.

5. **Self-destructing messages**: Consider implementing message expiration for sensitive content.

6. **Validate credentials**: Always verify that message `pubkey` matches the MLS credential identity.

### What NOT to Do

❌ Use the same key for Nostr identity and MLS signing  
❌ Store `exporter_secret` longer than necessary  
❌ Publish the real MLS group ID (only publish `nostr_group_id`)  
❌ Sign kind:444 Welcome events (they must remain unsigned)  
❌ Reuse ephemeral keypairs across group messages  

---

## Location Sharing Considerations

### Privacy-First Design

When building a location sharing app with Marmot:

1. **Granularity Control**: Allow users to share:
   - Exact location
   - Approximate area (fuzzy location)
   - City/region only
   - "Available" status without location

2. **Temporal Control**:
   - Real-time sharing with configurable intervals
   - One-time share ("I'm here now")
   - Time-limited sharing (share for 1 hour)

3. **Per-Group Settings**: Different privacy settings per group.

### Message Format Suggestion

```json
{
  "kind": 9,
  "content": "{\"type\":\"location_share\",\"data\":{...}}",
  "tags": [
    ["t", "location"],
    ["expiration", "1234567890"]
  ]
}
```

**Location Data Structure**:
```json
{
  "type": "location_share",
  "data": {
    "coordinates": {
      "latitude": 37.7749,
      "longitude": -122.4194,
      "accuracy": 10,
      "altitude": 50,
      "altitude_accuracy": 5
    },
    "timestamp": 1234567890,
    "precision": "exact",  // "exact" | "approximate" | "city"
    "expires_at": 1234571490,
    "moving": false,
    "speed": 0,
    "heading": null
  }
}
```

### Metadata Considerations

Even with E2E encryption, consider:
- **Frequency of updates**: More updates = more metadata about user activity
- **Message size patterns**: Location updates have consistent size; consider padding
- **Timing correlation**: If updates sync across users, patterns emerge

### Implementation Tips

1. **Batch updates**: Don't send every GPS tick; aggregate and send periodically
2. **Differential updates**: Only send changes when significant movement occurs
3. **Offline support**: Queue location shares for when connectivity returns
4. **Battery efficiency**: Optimize GPS polling based on share settings

---

## Quick Reference

### Common Tasks

| Task | Code/Command |
|------|--------------|
| Create MDK instance | `MDK::new(MdkMemoryStorage::default())` |
| Generate key package | `mdk.create_key_package_for_event(pubkey, relays)` |
| Create group | `mdk.create_group(pubkey, key_packages, config)` |
| Send message | `mdk.create_message(group_id, rumor)` |
| Process message | `mdk.process_message(event)` |
| Rotate keys | `mdk.rotate_signing_key(group_id)` |

### Event Kind Quick Reference

| Kind | Use |
|------|-----|
| 443 | Publish KeyPackage |
| 444 | Send Welcome (gift-wrapped) |
| 445 | Group messages |
| 10051 | KeyPackage relay list |
| 9 | Chat message content |

### Feature Flags

| Flag | Purpose |
|------|---------|
| `mip04` | Enable encrypted media support |

---

## Resources

### Official Documentation

- [Marmot Protocol Specs](https://github.com/marmot-protocol/marmot)
- [MDK Repository](https://github.com/marmot-protocol/mdk)
- [whitenoise-rs Repository](https://github.com/marmot-protocol/whitenoise-rs)
- [MLS RFC 9420](https://www.rfc-editor.org/rfc/rfc9420.html)
- [MLS Architecture RFC 9750](https://www.rfc-editor.org/rfc/rfc9750.html)

### Nostr Resources

- [Nostr Protocol](https://github.com/nostr-protocol/nostr)
- [NIPs Repository](https://github.com/nostr-protocol/nips)
- [NIP-EE (Legacy, superseded by Marmot)](https://nips.nostr.com/EE)

### Related Projects

- [OpenMLS](https://github.com/openmls/openmls) - MLS implementation
- [rust-nostr](https://github.com/rust-nostr/nostr) - Nostr Rust libraries
- [marmot-ts](https://github.com/marmot-protocol/marmot-ts) - TypeScript implementation
- [whitenoise_flutter](https://github.com/marmot-protocol/whitenoise_flutter) - Flutter app

---

## Version History

| Date | Changes |
|------|---------|
| 2026-01-31 | Initial document creation |

---

*This document is intended as a Claude knowledge reference for developing applications using the Marmot Protocol ecosystem. Always refer to the official repositories for the most up-to-date information.*