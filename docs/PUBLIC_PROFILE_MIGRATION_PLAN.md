# Public Nostr Profiles Migration Plan (kind-0 + Blossom)

**Status: FINAL DRAFT — reviewed, pending owner approval.**

Haven migrates from MLS-encrypted in-group profile sharing (display names piggybacked in
location JSON, avatars as padded kind-445 chunk messages) to standard public Nostr
profiles, matching the White Noise reference app: kind-0 metadata (name / display_name /
picture) published under the user's Nostr identity key, profile pictures hosted on a
Blossom server, and member profiles resolved from relays by pubkey.

Process: four-way research pass (live NIP/BUD spec verification, the restructured Marmot
spec, the White Noise checkouts at `whitenoise/` + `whitenoise-rs/`, full inventory of
Haven's current implementation) → first draft by Rust/Flutter/testing expert agents →
independent verification by a second set of four expert agents (protocol, security,
Rust, Flutter), all returning APPROVE-WITH-CHANGES. Every confirmed finding is folded
into this document; §11 records the review outcome.

---

## 1. Privacy posture change (read first)

This migration **deliberately reverses** Haven's documented privacy model
(`CLAUDE.md` "No public profiles", `SECURITY.md` avatar section) at the owner's explicit
direction. What changes:

| | Today (MLS in-group) | After (public kind-0 + Blossom) |
|---|---|---|
| Who can see name/photo | Circle members only, after MLS decryption | **Anyone**, on public relays / by URL |
| Durability | Deleted with circle state | **Effectively permanent** (replaceable ≠ erasable; indexers/archives keep revisions; NIP-09 is best-effort) |
| Photo hosting | Encrypted SQLCipher blobs, never leaves MLS | **Public, unencrypted** blob on a Blossom server (server sees uploader pubkey + IP; viewers leak IP to host) |
| Fetch-side leak | None (relays can't cluster 445 traffic) | Relay sees which pubkey sets a client asks about (association leak — bounded, not eliminated, by the mitigations below) |

**Baseline mitigations (non-negotiable, all enforced by tests/CI):**

1. Public profile publishing is **opt-in, default OFF**, gated by an explicit consent
   dialog AND a Rust-side persisted consent flag that hard-errors on publish attempts
   (defense in depth — a Dart bug cannot bypass it).
2. Retraction actions are never consent-gated, but are a **no-op unless something was
   actually published** — they must never CREATE a public footprint (blank kind-0 /
   kind-5) for a pubkey that has no prior published profile. (Security review F2.)
3. `nip05` / `website` are never written by Haven's UI (DNS-verifiable dox handles).
4. EXIF/GPS/XMP are stripped and the image re-encoded **before** any public upload
   (reusing the existing `avatar/image.rs` sanitizer — WN uploads the raw file; we don't).
5. HTTPS-only Blossom (loopback exempt in debug builds only), **plus connect-time IP
   filtering on picture downloads** — a member's kind-0 `picture` URL is
   attacker-controlled; without filtering it is an SSRF + automatic co-member
   IP-harvesting primitive (Security review F1, BLOCKER — see §4 blossom.rs).
6. Profile fetch/publish never touches circle relays, never carries any group
   identifier, and uses bounded one-shot fetches — **no standing kind-0 subscription**
   (deliberate divergence from WN, which holds standing discovery subs).
7. Profile fetches **union all known member pubkeys across all circles** into one
   batched, TTL-cached REQ — never a clean per-circle roster partition, which would
   hand the relay exact co-membership clusters. Honest framing: this bounds request
   count and blurs per-circle clustering; it does **not** eliminate the association
   leak (Haven has no follow-list cover traffic). (Security review F5.)
8. Consent copy states: same pubkey as your circles (not a separate persona),
   effectively permanent, the photo host sees uploader pubkey+IP, **viewing other
   members' photos contacts their chosen host** (residual leak documented), VPN
   recommended.
9. "Delete public profile" exists but is documented best-effort (blank kind-0
   republish + NIP-09 + Blossom DELETE) — and per (2), only when a profile exists.
10. Metadata reads go to AUTH-free discovery relays; the fetch path must never answer
    NIP-42 AUTH (test-pinned), so the relay cannot attribute the fetcher.

**Docs that must change in the same landing as the code (M0/M13):**
`CLAUDE.md` — Privacy Model section (the "Pubkey-only identity / relays never see
usernames" bullet becomes conditional on consent-OFF) and an explicit note that the
public-profile module is an owner-directed Rule-10 exception (so future maintenance
doesn't read it as a regression to revert). `haven-core/SECURITY.md` — the **entire
"Avatars (Private Profile Pictures)" section (~lines 576–684)** is rewritten (it
currently states avatars are never published as kind-0/uploaded to Blossom — false
after this change), and the Network Threat Model section gains the Blossom viewer-IP
leak (including the attacker-chosen-host variant) and the permanence caveat.
`MARMOT_PROTOCOL_KNOWLEDGE.md` — annotate that the MIP-era docs are deprecated
upstream (restructured spec). In-app visibility copy (§6.5), onboarding copy.

---

## 2. Protocol foundations (verified against live specs + pinned crate sources)

- **Kind 0 (NIP-01/NIP-24)**: `content` is a JSON-*stringified* object. Fields:
  `name`, `about`, `picture` (NIP-01); `display_name`, `website`, `banner` (NIP-24;
  `bot`/`birthday` are also NIP-24 but are NOT first-class fields in the pinned
  `nostr` 0.44 crate — they round-trip via `Metadata.custom` only). Deprecated
  `displayName`/`username`: read defensively (they land in `custom`), never write.
  **NIP-24: `name` should always be set** when publishing (we mirror `display_name`
  into `name` if empty — app-level logic; `EventBuilder::metadata` does not do it).
  Replaceable: relays keep only the newest per pubkey (tie → **lowest event id**, which
  Haven implements spec-correctly; WN's `>=`-wins tie-break is arguably not compliant).
  **Update = full replace** → correct edit is fetch-latest → merge → republish the
  whole object (unknown fields preserved via `nostr::Metadata.custom`, verified:
  `#[serde(flatten)] BTreeMap<String, Value>` in nostr-0.44 nip01.rs).
- **NIP-65 (kind 10002)**: fetch events *from* a user via their **write** relays;
  pragmatic read path = indexer/discovery relays (same acknowledged simplification WN
  makes). Haven already has `PRODUCTION_DISCOVERY_RELAYS` (`src/relay/discovery.rs`) —
  the same six relays WN uses — and `fetch_nip65_relays`-style precedent for the fetch
  shape. Note: the existing helper extracts **read** relays; the publish path needs a
  new `extract_nip65_write_relays` (Rust review).
- **Blossom**: BUD-02 upload = `PUT /upload`, raw bytes; response blob descriptor
  `{url, sha256, size, type, uploaded}` (201 new / 200 exists). Auth event = kind
  **24242**, never published to relays: `t` tag matching the verb, `expiration`
  (future, required), `x` (sha256 over the EXACT uploaded bytes), `created_at` in the
  past, human-readable `content`, transmitted in the `Authorization: Nostr <base64>`
  header. **Encoding note (protocol+Rust reviews)**: current BUD-11 spec text says
  base64url-no-padding, but the pinned `nostr-blossom` 0.44.0 emits **standard base64
  with padding** — which is what WN ships and what production Blossom servers accept.
  v1 follows the crate's proven behavior; the divergence is documented and the
  real-Blossom-container e2e test empirically verifies interop. BUD-03 = kind 10063
  server list — **not published in v1** (WN parity); we do implement sha256-extraction
  fallback parsing on read. Blossom chosen over NIP-96 (ecosystem standard; WN uses
  `nostr-blossom`, no NIP-96 anywhere).
- **Marmot**: per-user profiles are **out of scope** for the protocol (no normative
  guidance; all registered app-components are group-scoped). The MLS leaf's
  `BasicCredential.identity` IS the member's Nostr pubkey (bound by the mandatory
  account-identity-proof extension; already asserted in Haven's own
  `mls_e2e_security_tests.rs`), so `group members → pubkey → kind-0` is the
  spec-blessed join point — exactly WN's `groups.members() → resolve_user(pubkey)`.
  Removing Haven's in-group profile messages is cleanly compatible ("unknown
  app-event kinds SHOULD NOT break group state"; Haven's MDK layer maps decrypted
  content generically without schema branching, verified). **Do not adopt kind-3
  contact lists** (would self-publish the social graph).
- **Crate compatibility (verified at source level)**: haven-core locks `nostr` 0.44.2 /
  `nostr-sdk` 0.44.1; `nostr-blossom 0.44.0` depends on the same `nostr` 0.44 line +
  `reqwest 0.12` with `rustls-tls`, which resolves to the **rustls 0.23 + ring +
  webpki-roots** stack haven-core already ships (zero `aws-lc-*` in either lockfile —
  the NDK cross-compile trap is avoided). Pin `nostr-blossom = "=0.44.0"` (MDK-pin
  discipline). `BlossomAuthorizationOptions` lets the caller set `expiration` and
  `content`, and `x` is computed over the exact bytes passed to `upload_blob` — so the
  crate satisfies all BUD-11 MUSTs (`created_at` is stamped `now()`, valid); the
  hand-rolled client is a contingency, not the expected path (Rust review).

---

## 3. Resolved design decisions

| # | Decision | Resolution |
|---|---|---|
| D1 | Opt-in | Default OFF. Consent flag persisted **Rust-side** in `circles.db` (`user_settings` key `profile_publish_opt_in`); publish FFI hard-errors without it (never a silent no-op); Flutter shows the consent dialog and reads the flag via FFI. Retraction (`remove_my_profile_picture`, `delete_my_public_profile`) is never consent-gated but is a **no-op unless a profile/picture was actually published** (gated on `published_events` kind-0 row / cached Known picture — it must never mint a first public event for a never-consented pubkey). |
| D2 | Fetch transport | **All network I/O in Rust** (relay fetch/publish via existing `RelayManager`; Blossom via HTTP in core). Flutter renders bytes via existing `HavenAvatar`/`Image.memory`; **no URL ever crosses the FFI** (download resolves the URL from the Rust cache row). The `Image.network` ban stays true and enforced. Downloads are size-capped, sha256-verified, decode-bomb re-validated, **connect-time IP-filtered (anti-SSRF)**, cached in SQLCipher. |
| D3 | Refresh strategy | Bounded one-shot batched fetch + TTL cache (default 6 h). Triggers: circle open, app resume when stale, explicit refresh. No standing subscription; profile fetch never rides the live-sync engine. |
| D4 | Relay sets | Reads: `discovery_relays()` (existing AUTH-free plane; fetch path never answers NIP-42 AUTH — test-pinned). Writes: user's NIP-65 **write** relays if configured (new `extract_nip65_write_relays` helper), else discovery relays. **Fail-closed** if the effective set is empty. Never a circle's relays. |
| D5 | Blossom server | Single default `https://blossom.primal.net` (WN parity), constant in `profile/config.rs`. User-configurable override + kind-10063 publishing deferred (v2). Hash-fallback URL parsing implemented on read. |
| D6 | Local nicknames | `contacts.display_name` becomes a purely user-set petname override (auto-populate from location messages is deleted). Precedence for **other members**: local nickname → kind-0 `display_name` → kind-0 `name` → npub prefix + initials. **The self row keeps its dedicated resolution path** (today's `isSelfMember` branch) and never goes through the generic resolver, so the member list and Identity page always agree (Flutter review F3). |
| D7 | Own profile offline | Own kind-0 + picture bytes cached in `circles.db`; `ownProfileProvider` resolves **synchronously from cache and never throws on connectivity failure**; network refresh is a background augmentation delivered by invalidation (Flutter review F2). Edits publish when online; relay `OK=false` rejections surface as generic errors (protocol review 2.5). |
| D8 | Wire compat | `LocationMessage.display_name` stops being sent (field stays serde-tolerant on read); old clients' avatar chunk messages are ignored without state damage. **Parse failure ≠ decrypt failure**: successfully-decrypted content that doesn't parse as a location is marked **seen/skipped**, never classified as a retriable decrypt failure (which would reprocess legacy avatar chunks forever — protocol review 4.3). |
| D9 | HTTP stack | `nostr-blossom = "=0.44.0"` for upload (the crate pins `x`/`expiration` via `BlossomAuthorizationOptions`; auth header is standard-base64-with-padding — see §2). Direct `reqwest = "=0.12.x"` with `default-features = false, features = ["rustls-tls", "stream"]` for the capped streaming download — this **unifies on nostr-blossom's existing reqwest-0.12/ring instance** (no second reqwest major, no `rustls-no-provider`, no provider-install, no aws-lc; Rust review F1). Hand-rolled BUD-02 client demoted to contingency. |
| D10 | Logout/delete | Local rows wiped with `circles.db` (existing flow). "Delete public profile" action: blank kind-0 republish + NIP-09 deletion (reuses `build_nip09_deletion`) + Blossom DELETE; documented best-effort; no-op without a prior published profile (D1). |
| D11 | Cutover | Build-time flag `HAVEN_PUBLIC_PROFILES` (default off, `HAVEN_LIVE_SYNC` precedent): new system lands flag-gated while old system keeps working; one final coordinated commit flips the flag and deletes the old system + its tests (coverage gate only ever sees fully-tested end states). |
| D12 | Name source of truth | Consent OFF: display name stays local-only (SharedPreferences, today's behavior) — visible only to self; others see npub + initials. Consent ON: the **fetched kind-0 value is authoritative** for the Identity page (owner's directive); the local pref becomes a write-through fallback cache. Edits fetch-merge-publish. Multi-device caveat (protocol review): replaceable-event convergence is `created_at`-ordered, so a skewed clock on another device can transiently out-rank a later edit — accepted, one-line note in docs. **Implementation prerequisite (Flutter review F1)**: `DisplayNameCard`'s seed-once guard is relaxed to "reseed whenever `_status == saved`" (refuse to clobber `unsaved`/`saving`/`failed` only), so the slower kind-0 fetch result can land after the initial cache seed. |

---

## 4. Rust core (`haven-core`)

### 4.1 New module `haven-core/src/profile/`

A directory module with a hard import boundary — **no `use crate::circle`, no
`use crate::nostr::mls`, no `mdk`/`exporter_secret` references** (CI-enforced at the
import level, not just identifier tokens — security review F3):

```
profile/
  mod.rs      — re-exports; module docs stating the import-boundary invariant
  types.rs    — ProfileMetadata (wraps nostr::Metadata incl. `custom` map),
                ProfileState { Unknown, Known } (tri-state; blank {} kind-0 = Known),
                CachedProfile { pubkey_hex, metadata, state, event_created_at, fetched_at },
                ProfilePicture { url, sha256_hex, canonical, thumbnail }
  parse.rs    — parse_newest_metadata(): filter kind==0 && author matches; NIP-01
                signature/id validity is enforced (nostr-sdk verifies on ingest; pinned
                by a forged-signature integration test); newest created_at wins (tie →
                lowest id); malformed events skipped; deprecated displayName/username
                resolved from `custom` on read, never written
  merge.rs    — merge_edits(base, ProfileEdits): mutate only edited fields on the
                FRESHEST fetched metadata; `custom` preserved (value-level equality —
                JSON key order normalizes through Metadata, so tests compare parsed
                values, not raw bytes); ProfileEdits { display_name, about, picture }:
                None=untouched, Some("")=clear
  consent.rs  — get/set `profile_publish_opt_in` (user_settings row, default
                absent=false); ensure_profile_publish_consent() — hard Err;
                has_published_profile() — the retraction no-op gate (D1)
  fetch.rs    — fetch_profiles(relay, authors, profile_relays): ONE
                Filter::new().authors(..).kind(Kind::Metadata).limit(N) (`.authors`,
                NEVER `.pubkey`; defensive limit bounds non-pruning relays); callers
                pass the UNION of all known member pubkeys across circles (§1.7);
                ≤500 authors per REQ; bounded timeout; fail-closed on empty
                relays/authors; misses recorded as Unknown rows; soft size guard on
                user-editable fields before publish
  publish.rs  — build_metadata_event() (EventBuilder::metadata + NIP-24 name rule;
                no client/app-identifying tags — test-pinned); publish via RelayManager
                surfacing OK=false rejections as generic errors; optimistic local cache
                write; record in `published_events` (enables NIP-09 + the D1 gate);
                delete_public_profile() (blank kind-0 + kind-5 + Blossom DELETE;
                no-op without prior publish)
  blossom.rs  — upload_profile_picture(): require_https → process_own_avatar (sanitize)
                → sha256 of exact post-pipeline bytes → nostr-blossom upload_blob signed
                by identity Keys (BlossomAuthorizationOptions: expiration=now+60s) →
                verify descriptor sha == our hash.
                download_profile_picture(): require_https, redirects disabled,
                **anti-SSRF connect-time IP filter** — resolve-then-reject loopback /
                RFC-1918 / link-local (169.254/16, fe80::/10) / ULA (fc00::/7) /
                unspecified / multicast socket addresses (name-based checks are
                insufficient: DNS rebinding), Content-Length precheck + streamed
                512 KB cap, sha256(raw)==URL-hash check, re-validate via
                process_inbound_avatar; shared lazy reqwest Client (no cookies,
                generic UA). Release-profile loopback rejection is cfg-gated and NOT
                covered by the default debug test run — stated, not claimed.
  config.rs   — PROFILE_TTL_SECS=6h, PROFILE_FETCH_MAX_AUTHORS=500, PROFILE_FETCH_TIMEOUT,
                BLOSSOM_TIMEOUT, BLOSSOM_AUTH_EXPIRY=60s, DEFAULT_BLOSSOM_SERVER (https),
                profile_read_relays()=discovery_relays(),
                profile_write_relays(user_nip65_write) — user's write relays else discovery
  error.rs    — ProfileError (thiserror), redacting Debug; profile errors carry hex
                (not npub/bech32) identifiers so `redact_hex_sequences` applies
```

**Cache glue lives in `circle/storage_profile.rs`** (NOT `profile/cache.rs` — a
`ProfileStore` inside `profile/` would import `CircleStorage` and violate the module's
own import boundary; `storage_avatar.rs`/`storage_relay_prefs.rs` set the extension
convention; Rust review F3). `profile/` defines the row types; `circle/storage_profile.rs`
implements upsert/get/mark-unknown/picture-roundtrip on `CircleStorage`. Consider
relocating `redact_hex_sequences` from `nostr::mls::manager` to a neutral util module
so `profile/error.rs` doesn't reach into the MLS module for a pure function.

### 4.2 Cache schema (added to `circles.db` `initialize_schema()` — inherits keyring
key, hardening PRAGMAs, wipe-on-logout)

```sql
CREATE TABLE IF NOT EXISTS profiles (
    pubkey            TEXT PRIMARY KEY,            -- hex; NO circle/group column (tested)
    metadata_json     TEXT NOT NULL DEFAULT '{}',  -- raw kind-0 content (round-trips custom)
    state             INTEGER NOT NULL DEFAULT 0,  -- 0=Unknown, 1=Known
    event_created_at  INTEGER NOT NULL DEFAULT 0,  -- newer-wins gate
    fetched_at        INTEGER NOT NULL             -- TTL base
);
CREATE TABLE IF NOT EXISTS profile_pictures (
    pubkey     TEXT PRIMARY KEY,
    url        TEXT NOT NULL,      -- never crosses the FFI (D2)
    sha256     BLOB NOT NULL,      -- raw-download hash (Blossom commitment)
    canonical  BLOB NOT NULL,      -- re-encoded 512px JPEG (render source)
    thumbnail  BLOB NOT NULL,      -- 96px (markers)
    updated_at INTEGER NOT NULL
);
```

Own profile is an ordinary row (no sentinel). Legacy avatar tables dropped by a
one-shot sentinel-guarded migration (`user_settings` key `profile_migration_v1`) —
**drop `avatar_assignments` and `circle_salts` before `avatar_blobs`** (FK ordering)
or wrap the txn in `PRAGMA foreign_keys=OFF` (security review F10).

### 4.3 Deletions (at cutover, D11)

- `avatar/chunk.rs`, `avatar/manifest.rs`, `circle/avatar_reassembly.rs`,
  `circle/storage_avatar.rs` (whole files).
- `avatar/config.rs`: all `AVATAR_CHUNK_*`/orphan/reassembly constants. **Keep** the
  image-tier constants + `DecodeLimits` (reused by profile pipeline). `avatar/`
  remains as the pure image-sanitization module (keep the name; update module docs).
- `circle/manager.rs`: `build_avatar_share`, `build_avatar_clear`,
  `wrap_avatar_chunks`, `ingest_incoming_avatar_message*`,
  `route_decrypted_avatar_inner`, `apply_avatar_clear`, `ingest_avatar_part`,
  `finalize_received_avatar`, the `avatar_reassembly` field, membership-change avatar
  cleanup hooks (`:1034`, `:1227`, **and the `:1739` `remove_member_avatar` call inside
  the receive path** — Rust review), and their in-module tests. Verified: no
  cross-module functional caller outside `manager.rs` + the FFI avatar block.
- `LocationMessage.display_name`: send-side always absent (field keeps
  `#[serde(default, skip_serializing_if)]` read tolerance); `with_display_name`
  removed from the send path; both FFI encrypt call sites (`api.rs:2222`, `:2252`)
  updated. `sanitize_display_name` **moves** to serve the local petname setter (tests
  move with it; no other consumer, verified). `last_known_locations.display_name` /
  `contacts.display_name` columns stay (petname layer; `precision_label` precedent).

### 4.4 Security invariants (tested + CI-enforced)

- kind-0 + kind-24242 signed by the **Nostr identity key only** (`Keys::new(secret)`
  per-call at the FFI boundary, `Zeroizing` input, dropped immediately) — never the
  MLS signing key, never exporter-secret-derived. Enforced three ways: API shape (no
  MLS handle reachable from `profile/`), runtime test (`event.pubkey == identity`),
  and the **CI import-boundary grep** (security review F3).
- No group identifiers anywhere: filters are `authors`+`kind:0` only; no `h` tag;
  cache keyed by pubkey; Blossom URLs content-addressed; `published_events` rows carry
  no group column (verified).
- kind-24242 never reaches a relay (builder returns a header string, takes no relay client).
- The ungated retraction builders (blank kind-0, kind-5) are an explicit, documented
  **allowlist** in the CI consent-gate check, and are provably incapable of emitting
  new profile content (blank/deletion only, and only when `has_published_profile()`)
  — security review F4.
- Public profile data is deliberately public → `Zeroizing` applies only to the
  identity secret and raw gallery bytes; `ProcessedAvatar` keeps its existing
  `Zeroizing` fields (not weakened).

---

## 5. FFI (`haven/rust_builder/src/api.rs`)

New banner block `// ==================== Profile (public Nostr metadata)` in the slot
the avatar block vacates. All methods are `&self` on `CircleManagerFfi` (consent flag +
cache live in `circles.db`; a `CoreRelayManager` is constructed internally — cheap,
stateless, precedented). Conventions: `Result<T, String>`, `redact_hex_sequences` on
errors, redacting `Debug`, `run_blocking` for CPU/DB, async for I/O.

```rust
pub struct ProfileMetadataFfi { pubkey_hex, npub, display_name, name, about,
                                has_picture: bool, is_known, fetched_at }
// NOTE: no picture URL field — URLs never cross the FFI (D2); Flutter needs only
// bytes (below) + pictureHash for decode-cache keying.
pub struct ProfilePictureRefFfi { pubkey_hex, sha256_hex }

// consent (sync)
get_profile_publish_consent() -> bool
set_profile_publish_consent(enabled: bool)
// reads
fetch_member_profiles(pubkeys_hex, force) -> Vec<ProfileMetadataFfi> // async; UNION of
                                                                     // all circles' members
download_member_picture(pubkey_hex)          // async; URL resolved from the Rust cache
                                             // row; anti-SSRF filter applies
get_cached_profile(pubkey_hex) -> Option<ProfileMetadataFfi>         // sync
get_profile_thumbnail / get_profile_picture (pubkey_hex) -> Option<Vec<u8>>
// own profile
fetch_my_profile() -> ProfileMetadataFfi     // NO secret param — reads need no signer
                                             // (security review F7); pubkey from the
                                             // manager's identity context
publish_my_profile(secret, display_name, about) -> ProfileMetadataFfi  // fetch-merge-publish; consent-gated
upload_my_profile_picture(secret, raw) -> ProfilePictureRefFfi         // sanitize→upload→publish; consent-gated
remove_my_profile_picture(secret) -> ProfileMetadataFfi  // NOT consent-gated; no-op if never published
delete_my_public_profile(secret)                         // NOT consent-gated; no-op if never published
// petnames (sync)
set_local_nickname(pubkey_hex, nickname)
```

Deleted: the whole avatar FFI block (`set_my_avatar`, `clear_my_avatar`,
`get_my_avatar*`, `build_avatar_share_events`, `build_avatar_clear_event`,
`ingest_incoming_avatar_message`, `get_avatar_thumbnail`, `get_member_avatar`,
`AvatarMetaFfi`, `AvatarIngestResultFfi`) + the `display_name` param of
`encrypt_location`/publish. After edits: `./scripts/regenerate_frb.sh`, `cargo fmt`,
`dart format`, both suites. FFI functions stay thin pass-throughs (business logic in
`haven-core::profile::*` where Rust coverage counts — the rust_builder crate is not in
the coverage run).

---

## 6. Flutter (`haven/`)

### 6.1 Service layer

- `lib/src/services/profile_service.dart`: `ProfileService` interface + `Profile`
  value class (`pubkeyHex, name, displayName, about, pictureBytes, pictureHash,
  knownAt`) + `ProfileServiceException`. **Bytes only — no URL field.** Methods:
  `getOwnProfile({forceRefresh})`, `updateOwnProfile({displayName, about})`,
  `setOwnAvatar(raw)`, `removeOwnAvatar()`, `getPublishConsent()/setPublishConsent()`
  (FFI-backed, D1), `getMemberProfile`, `refreshMemberProfiles(pubkeys, {force})`.
- `NostrProfileService`: DI mirrors `NostrCircleService` (identity service + manager
  factory reusing the open circle-manager handle); fail-closed consent check before
  publish methods (in addition to the Rust gate); `on Object catch` + `debugPrint` +
  generic `ProfileServiceException` at every FFI site.
- `service_providers.dart`: `profileServiceProvider` singleton.
  `MockProfileService` in `test/mocks/` (style of `mock_circle_service.dart`; note
  `mock_circle_service.dart`'s avatar-method overrides (~lines 656–813) are deleted
  with the interface); `DEPENDENCY_INJECTION_EXAMPLES.md` gains a section.

### 6.2 Providers

- `own_profile_provider.dart` (replaces `own_avatar_provider.dart`):
  `ownProfileProvider` (autoDispose FutureProvider) — **resolves from the sync FFI
  cache read and never throws on connectivity**; network refresh arrives via
  invalidation (D7). `OwnProfileController` (AsyncNotifier, **non-autoDispose**):
  saveDisplayName / setAvatar — consent-gated; removeAvatar — NOT gated (no-op
  Rust-side if never published); refresh. `ref.invalidate(ownProfileProvider)` after
  mutations.
- `member_profile_provider.dart` (replaces `member_avatar_provider.dart`):
  `memberProfileProvider` — family keyed by plain `String pubkeyHex` (the
  `(mlsGroupId, pubkey)` composite key and every `mlsGroupId` plumbing parameter in
  tiles/markers is deleted, not left unused). Whole-family `ref.invalidate` after
  batch refreshes (valid Riverpod 2.6 API, verified).
- `profile_publish_consent_provider.dart`: `StateNotifierProvider` exposing a
  watchable bool + `ensureConsent(context)` / `disable()` (mirrors the
  `location_disclosure_provider` state+gate shape — Flutter review F6).
- `member_profile_refresh_provider.dart`: **non-autoDispose** (the
  `OwnAvatarController` precedent — a fire-and-forget Future that later calls
  `ref.invalidate` must not hold a disposable ref; Flutter review F5).
  `refreshRoster({force})` batches the **union of all circles' member pubkeys** (§1.7)
  in one FFI call → invalidate the family. No periodic timer.
- Refresh triggers: circle-select sites (`circle_list_tile.dart`,
  `circle_selector.dart`), `map_shell.dart` `_onResumed()` (alongside existing
  invalidations), refresh icon on Identity page + circle sheet header
  (RefreshRingButton reuse deferred — needs a per-relay-outcome FFI shape).

### 6.3 UI

- **Identity page**: new "Public Profile" `SwitchListTile` section wired to the
  consent provider (enable = dialog; disable = immediate). `_VisibilityNote` becomes
  consent-conditional (Off: "name and photo stay on this device…"; On: "visible to
  anyone on the Nostr network — not just your circles"). When consent is ON the page
  shows/edits the **fetched public profile** (D12); first post-consent fetch may
  surface an existing external profile with an info row. Photo header taps are
  consent-gated (photo has no pre-consent channel); picker/crop UI reused, rewired to
  `OwnProfileController` (mechanical — verified against the current ternary-gated
  `onAvatarTap` structure).
- **DisplayNameCard**: consent OFF → local save only (today). Consent ON → seeded
  from fetched kind-0; save = local write-through + `saveDisplayName` publish; caption
  "This name is also published to your public Nostr profile." **The seed-once guard
  (`_seedSilently`/`_loaded`) is relaxed to reseed whenever `_status == saved`** so
  the slower kind-0 fetch can land without clobbering in-progress edits (D12 /
  Flutter review F1). The error branch keeps a usable `TextField` (the provider never
  throws for connectivity, D7 — no uneditable-field regression).
- **Onboarding** `display_name_screen.dart`: unchanged code; copy updated ("stored
  only on this device unless you make it public later in Settings").
- **Member tiles**: `_MemberAvatar` reads `ownProfileProvider` (self) /
  `memberProfileProvider(pubkey)` (others); `HavenAvatar`, initials, deterministic
  glyph fallbacks reused. `member_display.dart` gains pure
  `resolveEffectiveMemberName(localOverride, profile, npubFallback)` implementing the
  D6 precedence **for non-self members only**; the self row keeps today's dedicated
  `isSelfMember` branch (D6 / Flutter review F3). The existing
  "self-row-never-reads-member-store" test assertion is preserved, re-pointed.
- **Map markers** (Flutter review F4 — under-specified in the draft, now explicit):
  `MemberLocation.displayName` deletion removes the markers' name source, which feeds
  `markerInitials` and the off-screen bubble semantics label for EVERY marker.
  Resolution: `memberLocationsProvider`'s body resolves each member's effective name
  via a **cache-only** profile read (sync FFI `get_cached_profile` + petname; no
  network in the poll path) and carries it on the marker props, keeping the marker
  layer itself non-reactive. `_AvatarLoader` keys its decode cache off
  `profile.pictureHash`; `AvatarImageCache` unchanged.
- **New petname UI** (decision made now, per Flutter review F10): a **member detail
  bottom sheet** (`member_detail_sheet.dart`, additive — opened from the tile,
  containing nickname editing + copy-npub) rather than a `PopupMenuButton`
  consolidation. Zero `PopupMenuButton` usage exists in the app; the tile carries
  1,799 lines of hand-built semantics tests that a menu rework would put at risk. The
  tile's existing tap/long-press semantics tree stays untouched; the sheet gets its
  own from-scratch test suite. `CircleService.setContactDisplayName` (always-set)
  replaces the deleted if-absent auto-populate variant.

### 6.4 Removals/rewires

Deleted: `own_avatar_provider.dart`, `member_avatar_provider.dart`,
`avatar_anti_entropy_provider.dart`, epoch-reshare hooks
(`evolution_poller_provider.dart`, `subscriptionServiceProvider.onGroupUpdated`
avatar branch), `_ingestAvatar` + its 3 call sites and `onAvatarComplete` plumbing,
`MemberLocation.displayName`/`avatarContentHash`, `LocationFetchResult.contactsUpdated`
**and its `||`-branch consumer in `location_sharing_provider.dart:71-75`** (Flutter
review F8b), `DecryptedLocation.displayName`, `background_location_task.dart`'s
display-name read + `encryptLocation` param, `CircleService`'s avatar interface
sections + `mock_circle_service.dart`'s avatar overrides. `displayNameProvider`/
`IdentityService` name storage stays (local fallback + consent-OFF path, D12).

### 6.5 l10n

~22 new keys (consent dialog — whose body copy now also discloses the
viewing-contacts-the-host leak per §1.8 — toggle subtitles, visibility notes Off/On,
publish caption, member detail sheet + nickname strings, generic errors) + 3 value
rewrites where current copy becomes false (`onboardingDisplayNameBody`,
`photoHeaderRemoveBody` "for everyone in your circles", `avatarPickerPhotoUpdated`
"end-to-end encrypted"); legacy `identityVisibilityNote` retired. All
picker/crop/fullscreen/semantics keys reused (verified present in `app_en.arb`).
Full 13-locale pipeline per CLAUDE.md: per-language translate agents + independent
reviewer agents + `arb_parity_check.dart` + warning-free `flutter gen-l10n`.

---

## 7. Testing plan

### 7.1 Rust (named tests; unit tier always-run, ≥80% coverage holds)

- **parse**: newest_created_at_wins; tie_breaks_on_lowest_id; empty_object_is_known;
  malformed_skipped_not_error; author_mismatch_dropped; deprecated_displayName/username_resolve;
  no_events_is_unknown.
- **merge**: preserves_untouched_known_fields; preserves_custom_unknown_fields
  (lud16-set-by-another-client canary); clear_with_empty_string; leaves_field_on_none.
  Proptest: arbitrary base (incl. random custom map) + sparse edits → non-edited
  fields **value-equal** through merge→serialize→parse (JSON key order normalizes;
  compare parsed values, not raw bytes — Rust review); precedence resolver never
  panics/never empty.
- **consent**: defaults_false_on_fresh_state; publish_returns_consent_required_error
  (hard Err, not silent no-op); succeeds_after_grant;
  revoke_stops_future_publishes_but_does_not_claim_unpublish;
  **remove_picture_when_no_profile_is_noop**;
  **delete_when_no_profile_publishes_nothing** (security review F2).
- **publish**: signs_with_identity_key (event.pubkey == identity);
  name_rule_mirrors_display_name; fresh_created_at_each_call;
  no_partial_delete_of_other_clients_fields; event_contains_no_circle_or_group_identifiers
  **extended to no client/app-identifying tags** (security review F9);
  ok_false_rejection_surfaces_generic_error; blank_republish_empty.
- **fetch**: fail-closed on empty relays (WN parity) / empty authors;
  batches_into_one_authors_filter (with `.limit`); chunks_over_500;
  uses_author_not_pubkey_tag (pins the CLAUDE.md `#p` gotcha); TTL respected / force
  bypasses; bounded on slow relay; absent authors → Unknown rows;
  **fetch_path_never_answers_nip42_auth** (security review F11).
- **blossom** (mockito for HTTP): 24242 kind/t/expiration-future/created_at-past/
  x-matches-sanitized-bytes (not raw input!)/**auth-header-is-standard-base64-padded**
  (matches the pinned crate + production servers; BUD-11 divergence documented — §2);
  auth_event_never_published (API-shape); EXIF stripped before hash (kamadak-exif
  golden test); https-only (loopback-allowed branch runs under debug; the release
  rejection branch is cfg-gated and NOT claimed as covered by the default run);
  **download_rejects_private_and_loopback_ips** (anti-SSRF: loopback, RFC-1918,
  link-local, ULA — security review F1); download sha-mismatch rejected; size-cap on
  Content-Length AND streamed overrun; 500/malformed-descriptor/missing-sha handled
  as errors not panics; redirect refused.
- **cache** (`circle/storage_profile.rs`): upsert/get; newer_than_cached gate;
  unknown rows suppress refetch; picture byte round-trip; `PRAGMA table_info` asserts
  **no circle/group column**; wipe-on-logout coverage; legacy-drop FK ordering.
- **Integration** (`haven-core/tests/`, in-process `nostr-relay-builder` — existing
  dev-dep): `profile_kind0_round_trip_e2e.rs` (publish→fetch; two publishes
  newest-wins; second-client-writes-lud16 → edit preserves it;
  **forged_signature_kind0_rejected** — protocol review 2.7);
  `profile_group_isolation_e2e.rs` (two relays: profile fetch never dials the
  "circle" relay; publish carries no h-tag/group id). Container-gated
  (`HAVEN_E2E_BLOSSOM`, `#[ignore]`, mirrors `HAVEN_E2E_RELAY`):
  `profile_blossom_integration_test.rs` (upload→download byte-identical after
  revalidation — also the empirical auth-encoding interop proof; duplicate upload →
  200; adversarial mismatched-sha server rejected).
- **Wire-compat regression**: `new_client_ignores_legacy_display_name_field_in_location_json`
  (also pins that `deny_unknown_fields` never creeps in);
  `haven_avatar_inner_kind9_from_old_client_ignored_without_state_damage` — asserting
  specifically that the message is marked **seen/skipped (not decrypt-failed/retried)**
  and the processing cursor advances (protocol review 4.3).

### 7.2 Flutter (mocked FFI via `MockProfileService`; ≥50% holds)

- **Delete**: avatar_anti_entropy / avatar_m3_epoch_reshare / own_avatar_controller_m2 /
  member_avatar_provider / circle_service_avatar(_m2) tests (with their subjects, at cutover).
- **Adapt**: evolution_poller (keep groupUpdated invalidations),
  location_sharing_service (keep decrypt/persist tests; drop avatar/auto-populate; add
  the seen-vs-retry legacy-content case), circle_member_tile (re-point avatar sources;
  **preserve the self-row-never-reads-member-store assertion** — verified real at
  `circle_member_tile_test.dart:1376-1394` — and every semantics assertion),
  avatar_picker / identity_photo_header (+ consent-gate cases), member_markers_layer /
  member_marker (name-from-cache-resolution cases), identity_page (visibility Off/On;
  already DI-testable without live FFI, verified), display_name_card (**reseed-on-saved
  cases**: kind-0 fetch result reseeds a saved field; never clobbers unsaved/saving),
  haven_avatar/initials/image-cache (fixtures only).
- **Create**: profile_service_test (arg forwarding; typed errors; **never leaks raw
  `$e`/hex** — redaction canary); own_profile_provider_test (consent default-off;
  no-publish-before-consent at provider layer; **retraction-always-allowed**;
  cache-first-never-throws; invalidation on success only);
  profile_publish_consent_provider_test (dialog decline/accept; single refresh
  trigger; disable-no-dialog); member_profile_provider_test (plain-string key;
  error-swallowing); member_profile_refresh_provider_test (forwards force; unions
  across circles; invalidates family; swallows failures); member_display_test
  extension (four-tier precedence table-driven for non-self; **self keeps the
  dedicated branch** — self/others split asserted; profile-less npub fallback;
  grapheme-safe initials); member_detail_sheet_test (nickname save/clear/cancel;
  copy-npub; its own semantics suite); public_profile_consent_dialog_test (permanence +
  pubkey-binding + Blossom exposure incl. viewer-leak copy present; explicit accept
  only); display_name_card_test addition — **saving with consent OFF calls no publish
  (`verifyNever`)**: the single most important new test; profile_avatar_source_test
  (widget accepts only `Uint8List`, never a URL).
- **Widen (not weaken)** `test/security/image_network_ban_test.dart`: add
  `CachedNetworkImage(` literal ban + `cached_network_image` pubspec-absence check.
- **integration_test/**: replace the avatar scenario in `e2e_combined.dart` with the
  profile scenario; new "zero kind-0 events and zero Blossom uploads observed while
  consent is default-off" relay-log assertion.

### 7.3 CI

- **Guard rewrite** (the `repo-guards.yml` Public-profile privacy boundaries step + `scripts/ci/check_profile_privacy_boundaries.sh`
  replacing the avatar guard; same strict-bash + trap-cleanup + banner-scoped style).
  Six checks: (1) global `Image.network(` ban in `haven/lib` (belt-and-braces with
  the Dart test); (2) no circle/group tokens
  (`nostr_group_id|MlsGroupId|mls_group_id|GroupId|circle_id|CircleId`) in
  `haven-core/src/profile/**`, profile Dart files, or the profile FFI banner range;
  (3) **import-boundary check**: `haven-core/src/profile/**` must not contain
  `use crate::circle`, `use crate::nostr::mls`, `mdk`, or `exporter_secret`
  (security review F3 — this, not (2), is what enforces key-separation structurally);
  (4) kind-0 construction (`Kind::Metadata`/kind-0 ctors regex) **confined** to the
  profile module — complement scan, with an explicit, documented **allowlist** for the
  ungated retraction builders (blank/deletion only; a mis-added ungated publisher
  fails the check — security review F4); (5) HTTPS-only Blossom (no `http://` literal
  outside loopback; `DEFAULT_BLOSSOM_SERVER` must start `https://`); (6) consent gate
  **structurally bound** inside the publish function bodies (function-span technique
  from `check_m7_native_wake_guards.sh`). Guard lands FIRST and fails exit-2
  (misconfiguration) until `profile/` exists — the correct RED state.
- **New e2e lane** `e2e-profile.yml` (parallel with existing lanes): Android job =
  existing strfry script + new `tooling/e2e/ci/start-blossom.sh` running
  `ghcr.io/hzrd149/blossom-server` **sha256-pinned** (WN's digest; re-verify) with a
  checked-in config; emulator reaches `ws://10.0.2.2:7777` / `http://10.0.2.2:3000`
  (`HAVEN_E2E_BLOSSOM_URL` dart-define; loopback/private-IP exemptions for the
  anti-SSRF filter are debug/e2e-cfg-gated). iOS job = new `tooling/e2e/local-blossom`
  Rust binary (macOS runners have no Docker; mirrors `local-relay`). Scenario
  (`integration_test/e2e/e2e_profile_sharing.dart`, two synthetic users): consent
  default-off asserted → A opts in, sets name+photo → kind-0 on strfry + blob on
  Blossom asserted → B resolves and displays → A edits name → B refresh shows new
  name AND same photo (merge didn't clobber `picture`) → A deletes profile → B falls
  back to npub+initials, no crash.
- **Coverage sequencing**: old and new systems coexist flag-gated (D11); the deletion
  commit ships with the new tests already green so `coverage.yml`/`check_coverage.sh`
  only ever evaluate fully-tested end states. Run `check_coverage.sh` locally before
  and after the deletion commit. Thresholds unchanged (80/50).

---

## 8. Milestones (TDD-ordered; R=Rust, F=Flutter, T=test/CI)

| # | Work | Depends on |
|---|---|---|
| M0 | Docs: CLAUDE.md privacy model + Rule-10 exception note, SECURITY.md avatar section + threat model, MARMOT_PROTOCOL_KNOWLEDGE.md annotation (land with code, not after) | — |
| M1 | Guard first: `check_profile_privacy_boundaries.sh` (6 checks incl. import boundary + allowlist) + workflow wired into ci.yml (RED = exit-2) | — |
| M2 | R0 deps: `nostr-blossom =0.44.0`, direct `reqwest =0.12` (`default-features=false`, `rustls-tls`+`stream`), `mockito` dev-dep; **cross-build proof on Android NDK + iOS** (owner runs; low-risk — WN ships the same stack) | — |
| M3 | R1 types/parse/merge + consent (incl. retraction no-op gate) — tests first, pure, no I/O | — |
| M4 | R2 cache: `circle/storage_profile.rs` + tables + sentinel-guarded legacy DROP (FK ordering) | M3 |
| M5 | R3 fetch/publish over RelayManager (+ `extract_nip65_write_relays`) + in-process-relay integration tests (incl. forged-sig, no-AUTH, isolation) | M3,M4 |
| M6 | R4 Blossom upload/download **incl. the anti-SSRF connect-time IP filter** + mockito tests | M2,M3 |
| M7 | F1 Flutter scaffolding (interface, mock, widened image ban test, EN l10n keys, `HAVEN_PUBLIC_PROFILES` flag) — parallel with M3–M6 | — |
| M8 | R6 FFI block + regenerate_frb; F2 `NostrProfileService` + providers (flag-gated; refresh provider non-autoDispose) | M4–M7 |
| M9 | F3/F4 Identity UI + consent flow (DisplayNameCard reseed relaxation; cache-first own-profile provider) + member tiles/markers (self-row dedicated path; marker names resolved cache-only in the locations provider) + refresh triggers | M8 |
| M10 | F5 member detail sheet (petnames + copy-npub; tile semantics untouched) | M8 |
| M11 | T8 e2e lane: blossom scripts + local-blossom binary + `e2e_profile_sharing.dart` + `e2e-profile.yml` | M9 |
| M12 | F6 l10n: 13-locale translate + independent review agents; parity + gen-l10n clean | M9,M10 |
| M13 | Wire-compat tests written GREEN against old paths (incl. seen-vs-retry routing), then **cutover commit**: flip/remove flag; delete old Rust modules + FFI + Flutter files + their tests; wire-compat stays GREEN; coverage checked before/after | M5,M6,M9–M12 |
| M14 | Full sweep: cargo test/clippy/fmt, flutter test/analyze, coverage, all guards, all e2e lanes; **security-reviewer** pass (identity-signer FFI paths, SSRF filter, retraction gates) + **ui-ux-reviewer** pass (consent dialog, visibility notes, member detail sheet a11y) | M13 |

## 9. Open items for the owner

1. **Approve the privacy reversal** as described in §1 (this plan implements it with
   opt-in default OFF and the listed mitigations; in-app and repo docs updated
   accordingly). The residual leaks that CANNOT be engineered away: permanent
   pubkey↔name/photo binding once published; relay-visible association of the queried
   pubkey set; viewer IP exposure to the (member-chosen) picture host — bounded by the
   anti-SSRF filter but not eliminated for legitimate public hosts.
2. Run the M2 Android/iOS cross-builds (only build-provable fact in the plan).
3. Default Blossom server `blossom.primal.net` acceptable for v1? (third-party
   operator sees uploader pubkey+IP; configurable override is deferred to v2).
4. E2E lanes run on your CI; local validation here is limited to unit/integration tiers.

## 10. Cross-draft reconciliations

- Consent flag: Rust-persisted in `circles.db` (not SharedPreferences) — the CI
  structural gate and the "Dart bug can't bypass" property depend on it; Flutter
  reads/writes via sync FFI.
- Own name source of truth: local-only when consent OFF; fetched kind-0
  authoritative when ON (owner directive), local pref demoted to write-through
  fallback.
- `image_network_ban_test.dart`: widened, never replaced.
- Cutover: flag-gated coexistence (HAVEN_LIVE_SYNC precedent) + single coordinated
  deletion commit, satisfying the coverage-sequencing rule.

## 11. Independent review record (2026-07-12)

Four independent expert reviews, all **APPROVE-WITH-CHANGES**; every confirmed finding
is folded into this document:

- **Security**: BLOCKER — attacker-controlled `picture` URL = SSRF + co-member
  IP-harvesting primitive → connect-time IP filtering added (§4 blossom.rs, M6) +
  consent-copy and SECURITY.md disclosure. Retraction-creates-footprint fixed via the
  no-op gate (D1). Import-boundary CI check added; consent-guard allowlist documented
  and tested; roster fetches union all circles; `fetch_my_profile` no longer takes the
  secret; SECURITY.md scope corrected to the full avatar section + threat model; npub
  redaction gap noted (profile errors carry hex); no-client-tag test; DROP-TABLE FK
  ordering; no-NIP-42-AUTH test.
- **Protocol**: base64 encoding claim corrected (pinned crate = standard padded;
  BUD-11 divergence documented; e2e container test is the interop proof).
  Parse-failure ≠ decrypt-failure routing specified (D8) with the seen/skip test.
  `OK=false` publish handling + soft size guard added; defensive `.limit()`;
  NIP-01 verification stated + forged-signature test; `bot`/`birthday`-via-custom
  noted; multi-device clock-skew caveat recorded (D12).
- **Rust**: reqwest incantation corrected to `=0.12` + `rustls-tls`+`stream`
  (unifies with nostr-blossom's ring; no second reqwest major, no provider install).
  `profile/cache.rs` contradiction resolved → `circle/storage_profile.rs`.
  `download_member_picture` URL parameter removed (URL never leaves Rust; FFI struct
  drops `picture_url` for `has_picture`). `upload_blob` CAN pin `x`/`expiration` →
  hand-roll demoted to contingency. New `extract_nip65_write_relays` helper;
  `manager.rs:1739` caller added to deletions; release-loopback-rejection coverage
  honestly stated; merge proptest asserts value-equality.
- **Flutter**: BLOCKER — DisplayNameCard seed-once guard incompatible with the
  dual-source design → reseed-on-saved relaxation (D12, §6.3). BLOCKER — self-row
  resolution ambiguity → dedicated self path retained (D6, §6.3). Marker name
  rendering after `MemberLocation.displayName` deletion specified (cache-only
  resolution in the locations provider). Refresh provider non-autoDispose. Consent
  provider is a watchable StateNotifier. Member detail sheet chosen over
  PopupMenuButton (a11y test surface). `mock_circle_service` avatar overrides +
  `location_sharing_provider.dart:71-75` consumer added to deletions.
