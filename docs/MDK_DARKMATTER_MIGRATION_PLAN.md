# Haven → MDK 0.9.x "Dark Matter" — Migration Plan

**Status: READINESS BLUEPRINT — do NOT execute now. DM-0 prep is bankable today; DM-1 onward
executes only at the §3 go-signals.**

**Baseline:** Haven on `mdk-core` 0.7.1+21, git rev `93ae324` (repo now `marmot-protocol/mdk`,
formerly `parres-hq/mdk`).
**Target:** the Dark Matter monorepo crate set (`cgka-engine` / `cgka-session` / `cgka-traits` /
`storage-sqlite` / `transport-nostr-peeler`), newest release **v0.9.4** (2026-07-10, rev
`e391adc133a9b60e420da7a0446f014a180ac8d2`).

**Legend:** **[V]** / CONFIRMED = verified in a local clone of the upstream monorepo; **[R]** = from
research docs, not re-checked in the clone; INFERRED = derived conclusion (confidence noted);
**GAP** = no upstream equivalent, Haven-side design needed; **RECONCILED** = two expert drafts
overlapped, one merged position is presented.

---

## Verification record

- **Drafted** 2026-07-16 by a **marmot-expert** (protocol / interop / rollout / security) and a
  **rust-expert** (deps / re-port / storage / FFI / tests / CI), merged into this master reference.
  The draft rests on a four-agent primary-source research pass: upstream Dark Matter
  architecture/API/issue survey, Haven's MDK coupling inventory (file:line), whitenoise-rs migration
  status, and the Marmot v1→v2 wire-format delta — every wire value below was read directly out of a
  local upstream clone (HEAD examined at research time **`609e27d`**).
- **Independently verified** 2026-07-17 by three fresh agents:
  - **marmot-expert** — VERDICT: sound; two "CONFIRMED"-labelled specifics corrected (W4
    tag-handling; the identity-proof spec-vs-code framing) and three missing protocol items added.
    Corrections applied below.
  - **rust-expert** — VERDICT: sound; one overstated dependency claim (keyring-core) removed, two
    evidence inaccuracies fixed (rusqlite `Transaction`, `group_record` async), one mobile-risk
    rating downgraded. Corrections applied below.
  - **security-reviewer** — VERDICT: approve-with-required-changes; 15 findings (F1–F15). **All 15
    are integrated as requirements** in the sections cited beside each.
- The research and verification source files live in the session scratchpad
  (`plan_merged.md`, `verify_{protocol,engineering,security}_findings.md`, `research_*.md`). This
  document is self-contained; the scratchpad is not required to use it.

### Two header reconciliations (read before the wire matrix)

> **Identity-proof version — `.v1` spec vs `.v2` code is a REAL divergence, not a filename artifact
> (corrected 2026-07-17).** The published spec *body* `foundation/account-identity-proof-v1.md`
> specifies **version `0x01`**, domain **`marmot.account-identity-proof.v1`**, and states the proof
> **"is NOT a Nostr event and is never published"** (no kind-450). The shipped *code*
> (`account_identity_proof.rs:36-40,97`, **[V]**) is **version 2**, domain **`…v2`**, extension type
> **`0xF2F1`**, and frames the signing input as a **canonical kind-450 event**. **The code is ahead of
> the published spec** on the version byte, domain string, and event-vs-not-event construction.
> Operational call unchanged: **implement to the code (v2 / `0xF2F1` / kind-450).** This is a
> substantive wire divergence (leaf-extension bytes + `RequiredCapabilities`) that *strengthens*
> go-signal §3.1(2): the Marmot v2 spec is unmerged and out of sync with the engine.

> **kind-445 AAD — the envelope adds NO AAD (CONFIRMED both passes).** `GROUP_AAD = b""`, "the AEAD AAD
> is the empty byte string and is never serialized" (`peeler.rs:35-37,111-118`, **[V]**; wrap
> fails-closed on non-empty AAD). Old MDK also used no AAD and Haven's `peek_crypto` copy assumes empty
> AAD. So the **only** kind-445 crypto change is the exporter *label* (W3); the AEAD shape (12-byte
> random nonce ‖ ciphertext, base64, empty AAD, ChaCha20-Poly1305, 32-byte key) is byte-identical.

---

## 1. Executive summary

This is **not a version bump.** Dark Matter (v0.9.x) is a ground-up rewrite of MDK — new crate
topology (no `mdk-core`), new engine architecture (`AccountDeviceSession` over a `CgkaEngine`, async
+ `&mut`, publish-before-apply enforced by typed `PendingStateRef` tokens), new storage schema
(`cgka_*` tables, **no importer** from `haven_mdk.db`), and a **new, incompatible wire format**
implementing the unmerged Marmot v2 spec. Any one of four independent wire breaks — KeyPackage kind
443→30443, exporter label `"nostr"`→`"marmot/group-event"`, group metadata `0xF2EE`→app-components,
mandatory account-identity-proof leaf extension — makes old and new clients mutually unintelligible;
there is **no bridge mode in the code** (no 443 reader, no `0xF2EE` parser, no `"nostr"`-label
fallback — INFERRED, high confidence). For Haven this means: a rewrite of haven-core's entire MLS
layer (`MdkManager` 36-method re-port, deletion of the peek/un-poison/converge/staged-marker stack
the engine now owns), a rusqlite dependency realignment, an FRB regeneration of the group-lifecycle
FFI surfaces, and a **hard flag-day** with wipe-and-recreate of all MLS state (identity/nsec, kind-0
profile, and petnames survive; circles are re-created by admins via the existing QR-invite motion).

**Upstream state:** v0.9.4 is git-tag-only (`publish = false`, never on crates.io), self-described
as "0.9.0, single internal consumer, not semver-stable" (`crates/cgka-engine/README.md:72`, **[V]**),
five releases in five days, and the commit-loss/fork-recovery train (#825/#877/#892) is in master but
**unreleased**. The reference client whitenoise-rs has **not** migrated (master still pins old
`mdk-core 0.8.0` rev `e8cd584`; its `darkmatter-migration` branch is a stale 2-commit PoC from
2026-06-08 that predates v0.9.0, has no PR, and cannot build from a clean clone).

**Recommendation:** **Prepare now, execute at go-signals.** Do the forward-compatible DM-0 work
immediately (repo-URL repoint at the same rev, insulation hardening, `MARMOT_PROTOCOL_KNOWLEDGE.md`
rewrite), keep this plan and the §8 verification list current against upstream, and pull the trigger
when a quorum of the §3 go-signals fires. Migrating today would make Haven the **first external
adopter of an unstable API implementing an unmerged spec**.

**Headline effort:** ~**6–9 weeks** across six milestones DM-0…DM-5 (§9), gated on three critical-path
risks detailed there: single-session-per-DB vs the M7 background isolate; mobile SQLCipher compile; and
the account-identity-proof signer + welcome auto-join as new hard requirements with no old equivalent.

---

## 2. Benefits — why migrate

The engine internalizes exactly the problem class Haven has spent the most defensive engineering on:
out-of-order commits, concurrent-commit forks, publish/merge ordering, and sticky-failure poisoning.

### 2.1 Haven code that becomes DELETABLE (engine-owned convergence replaces the hand-rolled stack)

All cites from verified greps of `/home/efe/Repositories/Haven-App/haven-core/src`; each is DELETABLE
unless noted:

- **`retry_failed_future_epoch_messages` (the #633 un-poison workaround) + its 4 call sites** —
  `circle/manager.rs:1966, 2127, 2715, 2843` (**[V]** grep). #633 is CLOSED pre-import; the engine's
  stored-convergence buffer (typed `MessageState::{Retryable,PeelDeferred,…}` +
  `advance_convergence`) designs the sticky-`Unprocessable` poison out. **The gate test
  `live_sync_out_of_order_commit_e2e.rs` is NOT deleted — it is re-expressed as a black-box
  convergence e2e over the new stack (§5.7, security F2).**
- **`circle::converge::commit_order_key`** — Haven's mirror of MDK's `is_better_candidate`. Superseded
  by the engine's `CommitOrderingKey{source_epoch, priority, committer, commit_digest}` (**[V]**
  engine.rs:238) + branch selection. Haven stops picking winners; the engine does (Tamarin-modelled —
  §2.2 caveat).
- **M7 staged-commit marker + `staged_commits` table** — a Haven-owned mirror of MDK's private
  `pending_commit`. Superseded by `EpochState::PendingPublish` + `PendingStateRef` +
  `PendingCommitRecovered` on hydrate (**[V]**). Delete the marker, its set/clear discipline, and its
  mirror tests.
- **`peek_crypto.rs` verbatim MDK-decrypt copy + `peek_content_type`** — CONFIRMED obviated:
  `TransportPeeler::peel_group_message` is a *public, non-destructive* outer-layer decrypt returning
  `PeeledContent::MlsMessage { bytes }` **without applying** (`peeler.rs:194-242`) — precisely what
  Haven copied `pub(crate)` code to get. The settle-window trial-apply architecture it fed (the whole
  `relay/live_sync/{settle,finalize,converge,autocommit,plan}.rs` layer) is also obviated, collapsing
  to ingest → drain → `advance_convergence` tick. Deletion is contingent on adopting the engine ingest
  loop (a design choice, not a mechanical port — §5.4).
- **`classify_mdk_error` commit-race classifier** — the deepest error-enum coupling. Replaced by
  `IngestOutcome`/`StaleReason`/`MessageState` + the `GroupEvent` stream. **REWRITE, not delete** (new
  taxonomy, new fork-safety tests).
- **`override_d_tag` workaround + twin-443/30443 event building** (`manager.rs:1059,1080`, **[V]**) —
  kind-30443 natively owns the `d`-slot (W1); the twin invariant tests and NIP-70 strip go with it.
- **M8-2 `has_live_key_material` gate — DELETE (RECONCILED).** The new `fresh_key_package` marks every
  KP `mark_as_last_resort` (**[V]** `key_package.rs:102`), so private key material is never auto-deleted
  on join — the gate's premise dissolves. **Deletion is coupled to reworking
  `relay/maintenance/key_package.rs`**, a live consumer of the verdict (`:21,66,77` +
  `circle/manager.rs:3176`, **[V]**) — sequence this in DM-2. Replace with app-side KP lifetime tracking
  + explicit `session.delete_key_package(&kp)`; a live-material query, if ever truly needed, is possible
  via a cloned `SqliteAccountStorage` handle + `mls_storage().key_package(&hash_ref)` (**[V]** engine.rs:90,
  traits/storage.rs:259) — bypasses the session.
- **Gift-wrap NIP-59 crypto (RECONCILED, §8.4 caveat).** The **peeler owns the 1059 crypto now** —
  `peel_welcome` calls `nip59::extract_rumor`; `wrap_welcome_with_metadata(payload, recipient,
  &WelcomeMetadata{key_package_event_id, relays})` calls `EventBuilder::gift_wrap` (**[V]**). Haven's
  `giftwrap::{wrap_welcome,unwrap_welcome}` *crypto* is deletable; the multi-relay **cascade/fan-out
  stays** in Haven's relay layer. `peel_welcome` is standalone (`peeler.rs:244`, **[V]**), so the
  hold-before-ingest preview (§8.4-A, security F3) works without ingesting; finalize scope at §8.4.

### 2.2 New capabilities Haven inherits (spec-backed, Tamarin-checked where noted)

- **SelfRemove / leave semantics** (`SendIntent::Leave` → MIP-03 SelfRemove, `AdminCannotSelfRemove`/
  `AdminDepletion`) — replaces Haven's hand-rolled `LeavePlan`/ghost-admin logic.
- **Welcome re-delivery** (`stored_sent_welcome`, mdk#352) and **fork recovery**
  (`ForkRecovered`/`CommitRolledBack`/`GroupState::Unrecoverable` + `group_forensics`).
- **Retention** (NIP-40, `message-retention.v1`), **encrypted media** (`0x8008`), **push** (MIP-05),
  **multi-device** (draft) — all future opt-ins; do NOT enable by default (Rule 10).
- **Formal assurance (with a mandatory caveat):** the convergence selector / lifecycle / delivery-order
  are **Tamarin-modelled** + `cgka-conformance-simulator` chaos tests. **This does NOT substitute for
  Haven's empirical e2e gates (security F15):** Tamarin models the *protocol abstraction*, not the Rust
  impl of a not-semver-stable engine — the empirical burden (§5.7) stays.
- **Live-sync starvation fix (plausible, not guaranteed):** making `process_group_event` async (§5.4)
  plausibly resolves the Android CPU-starvation hypothesis from the WN flag-on failures.

---

## 3. Readiness & go/no-go gate

**Verdict: DO NOT execute now.** Every ecosystem signal says "pre-stabilization." (CONFIRMED)

- The reference client has **not** migrated (whitenoise-rs master pins `mdk-core 0.8.0` `e8cd584`;
  `darkmatter-migration` is a stale 2-commit PoC that cannot build from a clean clone).
- Upstream self-describes the engine as **"0.9.0, single internal consumer, not semver-stable"**
  (`crates/cgka-engine/README.md:72`, **[V]**). Five releases in five days; the
  commit-loss/fork-recovery machinery is in master but unreleased.
- **Not on crates.io** (`publish = false`); git-tag-only.

### 3.1 Go signals (execute when a quorum is true) — watch list

1. **whitenoise-rs flips.** Its `darkmatter-migration` branch is rebased onto ≥v0.9.x, opens a PR, and
   merges to master — the ecosystem's "it's ready" bell.
2. **Marmot v2 spec merges** in `marmot-protocol/marmot`. **Note the identity-proof divergence** (spec
   body still v1 / no kind-450; code is v2 / kind-450): the spec is materially behind the engine, so
   this signal is not merely cosmetic.
3. **Semver / crates.io.** Either crates.io publication *or* an explicit semver-stability statement in
   `overview/current-state.md`.
4. **A RELEASED TAG (not master HEAD) contains the commit-loss train** — a `v0.9.5+` tag that includes
   `e6654ec` (#892 epoch-gap backfill), `363b1fe` (#825), `2a437a7` (#877). These fix Haven's
   delivery-stall class; migrating to a tag *without* them re-imports a known-fixed bug. **This tag is
   the pin precondition (security F8a): Haven pins a released tag, never a master rev.**
5. **mdk#755 lands (identity-proof signer layering).** `account_identity_proof.rs:8-20` self-documents
   that identity-proof construction/verification "should move to the app/session signer adapter
   boundary" — so the `AccountIdentityProofSigner` API Haven wires as a hard requirement (§7 Rule 1) is
   slated to churn (security F8b). Wait for it to settle.
6. **`WIRE_FORMAT_POLICY_REVIEW_REQUIRED` is resolved.** `wire_format.rs:1-44` uses
   `PURE_PLAINTEXT_WIRE_FORMAT_POLICY` (MLS PublicMessage both directions) under an explicit **"Revisit
   Before External Rollout"** marker — an upstream rollout gate (§7 Rule 5). Its resolution is a
   precondition for external adoption.
7. **Convergence-DoS and redaction issues resolved:** **#757** (unbounded convergence buffer — the real
   fix for Rule 12, security F7), **#885** (phantom `committed_from` fork quarantine), **#864** (group-id
   hex leak in error strings — Rule 6). #757/#864 are Haven-relevant even if unfixed; closure lowers
   Haven's mitigation burden.

### 3.2 What Haven does NOW (all forward-compatible, none blocked on the migration; folded into DM-0)

- **Repo-URL hygiene (do immediately, no behavior change):** repoint the three git deps from
  `parres-hq/mdk` to `marmot-protocol/mdk` at the **same rev `93ae324`** (verified reachable; ancestor
  of tag `archive/mdk-pre-darkmatter-code-import`).
- **Interim pin — keep `93ae324`.** A v0.8.0 (`e8cd584`) bump is upstream-stated failure-path
  byte-identical, so treat it as an *optional, low-value, separately-reviewed* cleanup, **not** on the
  Dark Matter path. Do **not** track `branch = "master"`.
- **Rewrite `MARMOT_PROTOCOL_KNOWLEDGE.md`** — its 443 / 10051 / NIP-44 / `"nostr"`-label / `0xF2EE`
  content is correct only for the deprecated MIP era Haven still ships. Mark each row old-vs-new.
- **Encapsulation hardening:** put all remaining direct exporter-secret + storage-provider access
  behind `MdkManager` methods (already mostly true). Pure insulation; no dependency change.

---

## 4. Wire-format cutover matrix

Every on-wire change, with Haven's current behavior and the interop consequence. **All "NEW" values
CONFIRMED against the clone unless marked.**

| # | Surface | Haven today (cite) | Dark Matter NEW (cite) | Interop consequence |
|---|---|---|---|---|
| W1 | **KeyPackage kind** | Builds **twin 30443+443** already (`api.rs:3307-3446`; `KEY_PACKAGE_KIND_LEGACY=443` canonical 30443) | Kind **30443** only, addressable: `d`=stable slot, `i`=KP ref, `mls_*`/`app_components` tags, base64 content, **no `encoding` tag** | Haven is *partly* there. Retire the 443 twin, add identity-proof/capability tags, native `d`-slot. Old-443-only clients can't find KPs. **BREAKING.** |
| W2 | **KP discovery / relay list** | Kind **10051** KeyPackage-relay list | Kind **10051 abolished**; discover KPs on the account's **NIP-65 kind 10002** relays; NIP-17 **10050** inbox for 1059 (`relay_list.rs:85/102`) | New clients don't read 10051; old clients don't publish 10002. **BREAKING.** Retire 10051; publish 10002. |
| W3 | **kind-445 exporter label** | MLS-Exporter label **`"nostr"`**, context `b"nostr"` (old `groups.rs:436`) | `DEFAULT_EXPORTER_LABEL = "marmot/group-event"` = `MLS-Exporter("marmot","group-event",32)` (`peeler/src/lib.rs:37`) | Divergent `group_event_key` → **no 445 decrypts across versions. BREAKING.** Peeler exposes `with_exporter_label` (override hook) — do NOT use it to stay on `"nostr"`; CI-guarded (Rule 14 note / security F14). |
| W4 | **kind-445 tags** | `h` + MDK-internal `["encoding","base64"]` + optional NIP-40 `expiration` | **Exactly one `h` enforced**; **all other tags silently DROPPED** on ingest, `causal_deps` no longer parsed (`event.rs:43-73`, **[V]**, corrected) | **CORRECTED (protocol W4):** the peeler does **NOT reject** events carrying extra tags — it enforces exactly-one-`h` and ignores the rest (the `event.rs:67-73` MUST-NOT is a *comment*, not enforcement). So old 445s do **not** fail via tag rejection; they fail via **W3** (wrong exporter key → `DecryptFailed`). On migration Haven must simply *stop emitting* `encoding`/`causal_deps` to match the spec MUST-NOT. Also: outer `created_at` now bound to the inner app event's `created_at` (#630, `peeler.rs:162-171`). W4 is **not** load-bearing for the interop verdict. |
| W5 | **kind-445 AEAD shape** | base64(nonce‖ct), 12-byte nonce, empty AAD, ChaCha20-Poly1305, ephemeral key/msg | **Identical** shape (`peeler.rs:120-137`) | **Compatible in shape** — only W3 (label) differs. Ephemeral-key-per-445 asserted upstream (`peeler.rs:740-774`). |
| W6 | **Group metadata extension** | Reads derived `nostr_group_id`/`group_relays`/`group_name` from `NostrGroupDataExtension` (**0xF2EE**) | Gone. MLS `app_data_dictionary` **app components** (draft-08): 0x8001 profile, 0x8003 admin-policy, **0x8004 nostr-routing**, 0x8005 retention, 0x8007 avatar-url, 0x8008 enc-media (`app_components/mod.rs:59-66`) | Old client fails the new group's `RequiredCapabilities`; new engine never reads `0xF2EE`. **BREAKING.** `NostrRoutingV1` (0x8004) is the new source of the `h`-tag id — **Rule-4 privacy split preserved** (`GroupId`=MLS only; `transport_group_id`=nostr_group_id). |
| W7 | **Leaf credential / identity binding** | BasicCredential = pubkey hex, **no proof**; key separation proven by leaf-inspection test (`mls_e2e_security_tests.rs:619-663`) | **Mandatory** LeafNode ext `marmot.account-identity-proof.v2` (**0xF2F1**, kind-450 Schnorr proof over identity↔MLS-sig-key), `InvalidAccountIdentityProof` on ingest (13 sites) | New engine rejects old leaves. **BREAKING.** Haven must wire an `AccountIdentityProofSigner` over its Nostr identity key — §7 Rule 1 (hardened per security F1). |
| W8 | **Welcome (444/1059)** | Haven wraps 1059 itself; MDK produces the unsigned 444 rumor | **Skeleton unchanged**: 1059 → unsigned 444 rumor, base64 content, **strict exactly-one** `e` (KP event id) + `relays` tags, relay values validated (`peeler.rs:244-296`) | Shape-compatible but useless without W1. RECONCILED: move to the peeler's `wrap_welcome_with_metadata`; Rule-3 (444 unsigned) holds. **NEW OBLIGATION (protocol):** the group relay set must be **non-empty, ≤16 entries, each URL ≤512 B, ws/wss only** or `wrap_welcome_with_metadata` fail-closes (`peeler.rs:427-449`) — Haven must validate group relay sets before wrapping (§5.4). |
| W9 | **Inner app message** | Unsigned inner **kind-9** rumor + `["t","location"]` | `MarmotAppEvent`: unsigned, canonical NIP-01 id, **`pubkey` MUST equal MLS-authenticated sender**, no `sig`; `InvalidAppMessagePayload` + sender-validation on ingest | Shape-compatible, **validation stricter**. Haven must set inner `pubkey` = sender identity and produce a canonical id. Verify kind-9 stays the app kind (system rows now inner **kind-1210**). |
| W10 | **Ciphersuite** | 0x0001 (`MLS_128_DHKEMX25519_AES128GCM_SHA256_Ed25519`) | **0x0001 unchanged**, hard-enforced (`EngineError::UnsupportedCiphersuite`, test `scaffold.rs:114-118`) | Compatible. No action. |

**Net interop verdict (INFERRED, high confidence; CONFIRMED by protocol pass):** any one of
**W1/W3/W6/W7** independently breaks cross-version groups. There is **no bridge mode** (no 443 reader,
no `0xF2EE` parser, no `"nostr"`-label fallback; the peeler handles only kinds 445/1059). **W4 is NOT
load-bearing** for this verdict, so its earlier mis-statement is harmless to the conclusion.
⇒ **hard flag-day, §6.**

---

## 5. Engineering plan

### 5.1 Dependency & build changes

#### New crate set (minimal, keep Haven's relay layer)

Haven depends **directly** on five new crates; `AccountDeviceSession` is the ceiling. **[V]**
`cgka-session` imports engine types from `cgka_engine::*` and does not re-export them, so Haven must
also name `cgka-engine` directly.

```toml
# haven-core/Cargo.toml — replace the three mdk-* lines with:
cgka-session          = { git = "https://github.com/marmot-protocol/mdk", rev = "<released-tag rev>" }
cgka-engine           = { git = "https://github.com/marmot-protocol/mdk", rev = "<released-tag rev>" }
cgka-traits           = { git = "https://github.com/marmot-protocol/mdk", rev = "<released-tag rev>" }  # package "cgka-traits", dir crates/traits
storage-sqlite        = { git = "https://github.com/marmot-protocol/mdk", rev = "<released-tag rev>" }
transport-nostr-peeler= { git = "https://github.com/marmot-protocol/mdk", rev = "<released-tag rev>" }
```

**Do NOT adopt:** `transport-nostr-adapter` (Haven keeps its own relay/subscription/cursor plane —
§5.5), `marmot-account` (its keyring-core `AccountSecretStore` duplicates Haven's `keyring_policy` +
platform stores), `marmot-app` (full chat-app runtime — massive overlap). **[V]** `cgka-session` needs
none of them.

**Supply-chain note (security F8c, CORRECTED):** `cgka-session` imports **`marmot-forensics`
unconditionally** (`lib.rs:30-32`, **[V]**) even though `SessionConfig` installs no `ForensicRecorder`
by default. So `marmot-forensics` **is in the trusted/audit graph regardless** — the earlier
"omit for v1" framing was wrong; audit it as a transitive dependency. Add a CI **`cargo tree` gate
asserting the `uniffi` / `quic` / `agent` crates stay OUT** of Haven's graph.

#### Pin strategy — a RELEASED TAG, not master HEAD (security F8a)

Git `rev` of a **released tag** (`v0.9.5+`) that contains the commit-loss train
(`e6654ec`/`363b1fe`/`2a437a7`) — **not** a master rev: pinning master HEAD of a `publish=false`,
"not semver-stable," 5-tags-in-5-days monorepo implementing an unmerged spec is unacceptable
supply-chain exposure. Pin one 40-char rev across all five crates — go-signal §3.1(4).

#### The rusqlite / libsqlite3-sys conflict (links-crate, one version per graph)

**[V]** DM `Cargo.lock`: `rusqlite 0.32.1` / `libsqlite3-sys 0.30.1`; workspace declares
`rusqlite = { version = "0.32", features = ["bundled-sqlcipher-vendored-openssl", "trace"] }`. Haven
currently pins `rusqlite 0.37` / `libsqlite3-sys 0.35`. `libsqlite3-sys` is a `links = "sqlite3"`
crate → exactly one version may exist in the graph. Options:

1. **Downgrade Haven `rusqlite 0.37 → 0.32` + `libsqlite3-sys 0.35 → 0.30` (RECOMMEND).** Haven's
   SQLCipher code uses `params!`/`open`/`open_in_memory`/`execute`/`execute_batch`/`query_row`/
   `query_map`/`OptionalExtension`/`PRAGMA key = "x'..'"`/`Mutex<Connection>` **and
   `Connection::transaction()`/`Transaction` at ~9 sites** (`circle/storage.rs:968,1884`;
   `storage_profile.rs:176,382`; `storage_relay_prefs.rs:236,322,358,385`; `tiles/storage.rs:467` —
   **[V]**, corrected from the earlier "no `Transaction`" claim). No `blob_open`/savepoint/custom
   `ToSql`/`FromSql`/`functions`/`serialize`/`backup`. **`transaction()` + `Transaction::commit()` is
   API-stable across 0.32↔0.37**, so the downgrade stays **low risk**;
   `bundled-sqlcipher-vendored-openssl` exists in `libsqlite3-sys 0.30` (Android-NDK-OpenSSL preserved).
   Bonus: `circles.db`/`tiles.db` and the MDK DB unify on one SQLCipher build.
2. `[patch.crates-io]` the MDK workspace up to 0.37 — **rejected** (patches an unreleased, fast-moving
   dependency; risks `storage-sqlite`'s `trace` feature + PRAGMA-ordering assumptions).

**Action:** flip Haven's two pins to `0.32`/`0.30`; rerun `circles.db`/`tiles.db` SQLCipher tests
(incl. `tile_at_rest_test.rs`).

#### keyring-core — NOT a migration requirement (engineering, CORRECTED)

The earlier draft listed a `keyring-core 0.7 → 1.0` bump. **This is removed.** **[V]** none of the
five crates Haven adopts (cgka-session / cgka-engine / cgka-traits / storage-sqlite /
transport-nostr-peeler) depend on keyring-core — only `marmot-account` and `marmot-uniffi` do, and
both are rejected. There is therefore **no MDK-imposed keyring-core constraint**; Haven's four
platform store crates keep their existing keyring-core independently. Do not touch them for this
migration. (`storage-sqlite → fs-private + rusqlite`; `cgka-session/engine → marmot-forensics only`.)

#### Other unification deltas

- **openmls `extensions-draft-08`** — **[V]** workspace enables it. Haven should need no direct openmls
  types after §5.2 (the M8-2 gate goes away) → **drop the direct `openmls`/`openmls_traits` deps**; if
  any remain, add the feature.
- **chacha20poly1305 0.10.1 / tokio 1.x / nostr 0.44 / zeroize 1.8 / tls_codec 0.4** already unified —
  keep the `cargo tree -i {openmls, chacha20poly1305, nostr, libsqlite3-sys}` single-version gates
  (keyring-core is NOT in this set). **`image 0.25`**: DM has no `image` dep (Haven's avatar pipeline no
  longer unifies with MDK — safe, only ever additive).

#### Toolchain / edition

**[V]** DM workspace = `edition = "2024"`, `resolver = "3"`, toolchain `1.90.0`. A 2021-edition crate
(Haven) can depend on 2024 crates — edition is per-crate; DM's `rust-toolchain.toml` does not propagate
to git-dep consumers, so Haven relies on GH `dtolnay/rust-toolchain@stable` being ≥1.90 (it is). Action:
bump Haven's CI toolchain floor to **≥1.90** + verify Android/iOS cross toolchains. No edition migration.

### 5.2 `MdkManager` re-port map (36 methods → new API)

Structural change: `MDK<MdkSqliteStorage>` (interior-mutable, all `&self`, sync) →
`AccountDeviceSession` whose **mutating** methods take **`&mut self` and are `async`** **[V]**
(`send`/`ingest`/`confirm_published`/`publish_failed`/`create_group`/`fresh_key_package`/
`advance_convergence`); **reads** (`members`/`epoch`/`group_record`/`admin_pubkeys`/`exporter_secret`/
`self_id`/`app_component`) are **sync `&self`** **[V]** (lib.rs:269-578). `CgkaEngine: Send + Sync`. ⇒
`MdkManager` holds `tokio::sync::Mutex<AccountDeviceSession>` (the `&mut` requirement enforces the write
serialization Haven's process-global `write_lock` did by convention). Rename to `SessionManager`.

Construction: `SessionConfig::new(db_path, SqlCipherKey::new(passphrase)?, identity /*32B x-only pk*/,
Box::new(NostrMlsPeeler::new().with_welcome_signer(keys))).account_identity_proof_signer(Arc<dyn …>)`
**[REQUIRED — `open()` errors otherwise]** → `AccountDeviceSession::open(cfg)?` (**sync**; hydrates).
`new_unencrypted` → `SqliteAccountStorage::in_memory()` + `EngineBuilder` (§5.7).

| # | Old `MdkManager` method | New mapping | 1:1? |
|---|---|---|---|
| 1 | `new` / `new_unencrypted` | `SessionConfig`+`AccountDeviceSession::open` / `in_memory()` **[V]** | rewrite |
| 2 | `create_group` | `session.create_group(CreateGroupRequest{name,description,members,required_features,app_components,initial_admins}).await → CreateGroupEffects` **[V]** | **GAP** — name/desc/relays/admins move to `app_components` (routing v1) + `initial_admins`; welcomes come back inside `effects.publish` — publish-then-`confirm_published` |
| 3 | `process_welcome` | **hold the still-encrypted 1059** in Haven's pending store; ingest ONLY at Accept → engine auto-joins → `GroupJoined` (§8.4-A, security F3) | **GAP** |
| 4 | `accept_welcome` | Accept = feed the held 1059 into `session.ingest` (auto-join fires at accept time) | **GAP** |
| 5 | `decline_welcome` | **discard the held 1059 locally — never ingest, no on-wire trace** (preserves current semantics, Rule 10) | **GAP — behavior change avoided by Option A** |
| 6 | `get_pending_welcomes` | Haven-owned pending store (held encrypted 1059s + routing-metadata preview); `WelcomeState::{None,Pending,Active}` has **no Declined** | **GAP** |
| 7 | `create_message` | `session.send(SendIntent::AppMessage{group_id, payload}).await → effects.publish[ApplicationMessage]` **[V]**; payload = `MarmotAppEvent` JSON (unsigned inner kind-9, pubkey==sender) | rewrite; TTL/NIP-40 via `message-retention.v1` component, not per-send `EventTag::expiration` |
| 8 | `process_message` | `session.ingest(TransportMessage).await → IngestEffects{outcome, effects}`, then drain `effects.events` **[V]** | rewrite |
| 9 | `process_message_classified` + `classify_mdk_error` | replaced by `IngestOutcome::{Processed, Buffered{group_id,epoch}, Stale{StaleReason}}` **[V]** + `GroupEvent` stream; commit-race variants are engine-internal | **DELETE** classifier |
| 10 | `peek_content_type` + `peek_crypto.rs` | **DELETE** — non-destructive peek existed only for the trial-apply the engine removes (§5.4) | **DELETE (design change)** |
| 11 | `retry_failed_future_epoch_messages` (#633) | **DELETE** — engine owns deferred retry; #633 fixed pre-import (+ 4 call sites) | **DELETE** |
| 12 | `get_group` | `session.group_record(&gid)? → Group{id,name,description,epoch,members,required_capabilities,removed,join_epoch}` **[V]** (**sync `&self`, NOT async** — corrected) | field renames: no `state`/`nostr_group_id` field — `removed` bool + hydration-quarantine replace `GroupState`; `nostr_group_id` from routing component |
| 13 | `get_groups` | **GAP — no session `list_groups`** **[V]** (upstream friction note). Keep Haven's group registry in `circles.db` | **GAP** |
| 14 | `get_members` | `session.members(&gid)? → Vec<Member{id,credential}>` + `session.admin_pubkeys(&gid)? → Vec<[u8;32]>` **[V]** | 1:1-ish (two calls) |
| 15 | `get_ratchet_tree_info` | no ratchet-tree API on the session, but the leaf-level property it proved is reachable: `session.members()` projects each leaf's signature key (`Member::credential`) beside the account identity (`Member::id`) | **RESOLVED** — `mls_e2e_security_tests.rs::p3a_leaf_signature_key_differs_from_nostr_identity_key` |
| 16 | `get_stored_exporter_secret` (probe) | `session.exporter_secret(&gid,label,len)` presence **[V]** | rewrite/test-only |
| 17 | `leave_group` | `session.send(SendIntent::Leave{group_id}).await → Proposal{msg}` **[V]** | rewrite (no pending/confirm for a bare Proposal) |
| 18 | `self_demote` | `SendIntent::UpdateAppComponents` on `admin-policy.v1` **[V]** | rewrite → app components. No first-class self-demote intent; Haven encodes the policy itself (`encode_admin_policy_v1`) and sends the update — see §11.1. |
| 19 | `self_update` | engine-internal lifecycle **[R]** (Haven's `enablePeriodicSelfUpdate=false` already) | **GAP/obsolete** |
| 20 | `groups_needing_self_update` | `drain_pending_convergence_groups()` **[V]** | **GAP/rewire** |
| 21 | `clear_pending_commit` | `session.publish_failed(pending).await` **[V]** (typed `PendingStateRef`) | rewrite (paired to a specific pending ref) |
| 22 | `delete_group` (local wipe) | **GAP** — no per-group delete; wipe = whole-DB (§5.5); leaving = `SendIntent::Leave`; `removed` marks local copy | **GAP** |
| 23 | `get_messages` / `_paginated` | Haven keeps its own message store / reads storage-sqlite projection tables **[R]** | **GAP** |
| 24 | `add_members` / `_with_welcomes` | `SendIntent::Invite{group_id, key_packages}.await → GroupEvolution{msg,welcomes,pending}` → publish then `confirm_published(pending)` **[V]** | rewrite (publish-before-apply) |
| 25 | `remove_members` | `SendIntent::RemoveMembers{group_id, members}` (admin-gated `NotGroupAdmin`) **[V]** | rewrite |
| 26 | `merge_pending_commit` | `session.confirm_published(pending).await` **[V]** — **session returns `SessionEffects`** (event inserted at lib.rs:528); the engine-level API returns `GroupEvent` — Haven consumes `SessionEffects` (corrected) | rewrite (per-ref, publish-after) |
| 27 | `update_admins` / `update_relays` | `SendIntent::UpdateAppComponents{updates:[admin-policy.v1 / nostr.routing.v1]}` OR `UpdateGroupData{name,description}` **[V]** | rewrite → app components |
| 28 | `get_group_relays` | `session.app_component(&gid, nostr-routing-v1)?` decode `NostrRoutingV1{nostr_group_id,relays}` **[V]** | rewrite |
| 29 | `get_group_by_nostr_id` | keep Haven's `circles.db` nostr_group_id→GroupId index (already exists) | keep Haven index |
| 30 | `create_key_package` / `_with_d` | `session.fresh_key_package().await → KeyPackage{bytes, source}` **[V]**; kind **30443** addressable — `override_d_tag` DELETES | rewrite; event-building/signing stays Haven's (§5.6) |
| 31 | `has_live_key_material` (M8-2 gate) | **DELETE (RECONCILED, §2.1)** — last-resort semantics dissolve the premise; **coupled to reworking `relay/maintenance/key_package.rs`** (live consumer, §2.1) | **GAP — DELETE (sequence in DM-2)** |
| 32 | `to_location_result` (fold) | rewrite over `GroupEvent::MessageReceived` (Location) + `GroupStateChanged`/`EpochChanged` (GroupUpdate) + `AppMessageInvalidated`/`GroupStateInvalidated` (withdraw) **[V]** | rewrite (new taxonomy) |

**Cross-cutting GAPs:** pending-welcome preview/decline (#3–#6, RECONCILED to Option A hold-before-ingest,
§8.4); post-hoc admin grant / self-demote (#18, "lands in a follow-on plan" upstream — verify §8.9);
direct `MessageStorage`/`GroupStorage` access — all DELETE.

### 5.3 Async / `&mut` / locking redesign — replace `write_lock.rs` with session ownership

Today: a process-global `std::sync::Mutex<()>` serializes `haven_mdk.db` writers across Flutter isolates
(busy_timeout=0, non-WAL rollback journal). New model: one long-lived `AccountDeviceSession` with
hydrated in-memory state; mutators need `&mut self` **[V]** ⇒ wrap in
`tokio::sync::Mutex<AccountDeviceSession>`.

**CRITICAL RISK — single-session invariant (§7 Rule 14; blocks DM-3).** The engine hydrates
authoritative state into memory at `open()` (`hydrate_stable_groups_from_storage`, lib.rs:220, **[V]**);
**two live sessions on one DB file = two divergent in-memory states.** `storage-sqlite` has **only** an
in-process `Mutex`+`ThreadId` transaction owner + cross-connection `SQLITE_BUSY` retry — **no OS/file
lock** (fs-private sets file *modes*, not locks) **[V]**; upstream issue-#484's own test opens two
`SqliteAccountStorage` on one file and expects both to write, which makes two divergent `Engine`s
**worse, not safer.** Haven's M7 background-catchup isolate opens its own Rust runtime — the collision
case. This is **not merely corruption but a confidentiality risk** (security F4): divergent epoch state
risks exporter-key/epoch reuse and forward-secrecy erosion. Design (blocks DM-3): (a) route the
background isolate through the same session via a handle, or (b) a cross-isolate exclusive file lock
closing the foreground session before the background one opens. Also intersects **#866** (`SQLITE_BUSY`
window). Flag `m7b_m4_circles_db_is_rollback_journal_not_wal` for revision (MLS DB moves to WAL).

### 5.4 `CircleManager` & live-sync engine impact

**DELETE (engine now owns convergence)** — the §2.1 list, operationally: `retry_failed_future_epoch_
messages` + 4 call sites; `commit_order_key`; the M7 staged-commit marker (`staged_commits` table +
set/clear + mirror tests) → engine `EpochState::PendingPublish`/`PendingStateRef`/
`PendingCommitRecovered`; the `relay/live_sync/{settle,finalize,converge,autocommit,plan}.rs`
settle-window layer + `peek_content_type` → `advance_convergence(&gid)` + `Buffered` replay;
`peek_crypto.rs` + its parity gates.

**REWRITE (publish-before-apply, engine-driven):** replace `merge_pending_commit`/`clear_pending_
commit` with the typed flow: `send`/`advance_convergence`/`ingest` return
`PublishWork::{GroupEvolution,GroupCreated,AutoPublish}` carrying `pending: PendingStateRef` (**[V]**).
Haven publishes `msg`(+`welcomes`) through its **own relay layer**, then `confirm_published(pending)`
on **≥1-relay ack** (§7 Rule 13, security F13) or `publish_failed(pending)` on failure. `AutoPublish`
(engine auto-committed a peer SelfRemove) replaces Haven's `EngineDecryptOutcome::AutoCommit`. **Inline
processing becomes async:** `process_group_event` calls `session.ingest(..).await` — already on the
tokio worker, so awaiting is strictly better and **plausibly resolves the Android CPU-starvation
hypothesis.** Keep `catch_unwind` panic isolation around the await.

**NEW — group-relay-set validation (protocol W8).** Before any `wrap_welcome_with_metadata`, Haven
must ensure the group's relay list is **non-empty, ≤16 entries, each URL ≤512 B, ws/wss only**
(`peeler.rs:427-449` fail-closes otherwise). Add a validation gate + test in the relay layer.

**STAYS (Haven-owned):** relay subscriptions, cursors, per-relay fan-out, health, `since` lookback
(Haven does NOT adopt `transport-nostr-adapter`); gift-wrap **fan-out** (peeler owns the 1059 *crypto*,
Haven the multi-relay cascade); raw `Event` ↔ `TransportMessage` conversion via `NostrTransportEvent`
(**[V]** event.rs:32,77,82,100); `resync_circle_relays_from_mdk` re-pointed at the routing-component
decode (§5.2 #28).

### 5.5 Storage & data-layer plan

- **`haven_mdk.db` → `session.sqlite` (new schema, NO importer).** **[V/R]** Brand-new `cgka_*` tables +
  bespoke OpenMLS value store, no legacy import (§4). ⇒ **wipe-and-recreate**: on first launch delete the
  old `haven_mdk.db` (+ WAL/SHM/journal sidecars — `delete_mdk_db_files` does this), open a fresh
  `session.sqlite` behind a one-time migration guard keyed off DB filename presence. **Cutover secret
  hygiene (security F6):** unlink ≠ secure-erase — the old DB was **not** written with `secure_delete`
  and flash wear-leveling leaves residual ciphertext, so on cutover Haven MUST also **destroy the old
  keyring entry `mdk.db.key.default`** — key destruction is the practical secure-erase for SQLCipher.
- **SQLCipher key via `SqlCipherKey` — passphrase decision + entropy spec (security F5).** **[V]**
  `SqlCipherKey::new(impl Into<String>)` (Zeroizing, rejects empty) applies `PRAGMA key = '<str>'` — a
  **passphrase through SQLCipher's PBKDF2**, `cipher_compatibility=4` (connection.rs:381/477). This is
  **cryptographically incompatible** with Haven's current raw-key form (`PRAGMA key = "x'<64-hex>'"`,
  KDF bypassed). Since the DB is wiped-and-recreated: **mint a fresh string passphrase for
  `session.sqlite`, persist it in the keyring, pass it verbatim to `SqlCipherKey::new`.** **Required
  spec:** the passphrase MUST be the **hex or base64 encoding of ≥256-bit `OsRng` output** (raw bytes
  are not valid UTF-8; encode them), `Zeroizing`-wrapped end-to-end (keyring buffer included), **never
  logged**; the PBKDF2 stretch is then pure defense-in-depth. `circles.db`/`tiles.db` keep the raw-hex
  scheme. Good defaults confirmed: WAL, `secure_delete=true`, `cipher_memory_security=true` (conn.rs:371-384).
- **`circles.db` `hash_ref` rows — RECONCILED.** With the M8-2 gate deleted (§5.2 #31) and KPs re-minted
  post-wipe, the `published_key_packages.key_package_hash_ref` rows lose their consumer (and the
  `KeyPackageRef` encoding likely changes anyway). **Clear `published_key_packages` on cutover** (no schema migration).
- **`tiles.db`** unaffected **except** the rusqlite `0.37→0.32` downgrade (re-run
  `tile_at_rest_test.rs`); **iOS keyring** `ensure_db_key_after_first_unlock` still applies to the new
  `session.sqlite` key entry (unchanged; no keyring-core bump — §5.1).

### 5.6 FFI / `rust_builder` impact

Haven's FFI is insulated by mirror types (no `mdk_*`/`openmls*` reaches Dart); FRB regeneration is
driven by **semantic**, not type, changes:

- **`GroupId` mirror**: cgka-traits `GroupId` API is **`new(bytes)`/`as_slice()`/`into_bytes()`/
  `as_ref()`** (Debug/Display=hex) **[V]** types.rs:11-55 — **NOT** WN's `from_slice`/`to_vec` wrapper;
  Haven's FFI `GroupId::from_slice` mirror maps to `::new`, byte contract unchanged. The
  **`hash_ref: Vec<u8>`** field loses its consumer with the M8-2 gate deleted — keep (opaque) or drop;
  encoding is moot once rows re-seed. Low churn.
- **`DecryptOutcomeFfi`/`DecryptOutcomeKindFfi`**: the new taxonomy (`GroupEvent` + `IngestOutcome` +
  `AppMessageInvalidated`/`GroupStateInvalidated`) is richer; the Dart cursor-advancement contract
  changes (advance on `Processed`/`Stale`, rely on engine buffering for out-of-order). **Real
  Dart-visible semantic change → FRB regeneration required.**
- **`GroupState`**: add an **`Unrecoverable`** case (engine `GroupUnrecoverable`); UI must block
  send/mutate (§7 Rule 8). FRB regen.
- **`UpdateGroupResultFfi`**: evolution JSON + welcomes now come as
  `PublishWork::GroupEvolution{msg:TransportMessage, welcomes, pending}` → publish/confirm lifecycle
  shape changes → FRB regen. (Wipe/init/keyring FFI change only filename — no keyring-core-version.)
- **Conclusion:** semantics do **not** fully preserve → **plan FRB regeneration** for these four
  surfaces + their Dart consumers.

### 5.7 Test & CI migration

**DELETE (workaround/peek/marker gates that lose their subject):**
- `rev1_peek_*` decrypt-parity + classify + fail-safe gates, `peek_crypto.rs:130-285` unit suite, the
  `chacha20poly1305` parity-pin rationale — DELETE with peek. M7 staged-commit marker suite — DELETE
  with the marker; re-express crash-recovery via the engine's `PendingCommitRecovered` at hydrate.

**KEEP-AND-RE-EXPRESS — security black-box gates (security F2 + F9; do NOT drop).** Haven's
test-coverage invariant forbids weakening a gate to accommodate a change. Every security gate below
migrates to an **automated black-box gate over `SessionManager` / the new stack**, not a deletion:
- **`live_sync_out_of_order_commit_e2e` (F2, was slated for deletion)** → re-express as a **black-box
  multi-party real-out-of-order convergence e2e**: all members converge to one epoch, no stuck/poisoned
  message, location delivered. Delete only the workaround-*internal* assertions, never the end-state
  proof — trusting an unproven engine is exactly when this gate matters most.
- **Rule 1 key-separation** (was `get_ratchet_tree_info` leaf inspection) → **DONE.** The ratchet-tree
  API is gone, but the leaf read is not: `session.members()` carries each leaf's signature key
  (`Member::credential`) beside the account identity (`Member::id`), so the direct assertion
  **MLS sig-key ≠ Nostr identity key** survives verbatim in
  `p3a_leaf_signature_key_differs_from_nostr_identity_key`. The weaker re-expression this plan
  proposed — "identity-proof present + verifies" — is kept as the complementary ON-WIRE half
  (`p3a_key_separation_identity_proof_enforced_and_identity_not_used_for_group_messages`, W7), never
  as the substitute: the proof binds the account to the leaf and never requires the two keys to
  differ, so it verifies happily under the mutation that reuses the Nostr secret as the MLS signer.
- **Rule 2 ephemeral-445 uniqueness** (fresh ephemeral per 445), **Rule 3 444-unsigned** (rumor
  unsigned, only 1059 seal signed), **Rule 4 group-id privacy** (**no real MLS `GroupId` in any
  published event**) → each an assertion over the send/publish path.
- **Rule 5 exporter prune+zeroize** → re-point `p3b_old_exporter_secrets_are_pruned` at
  `EngineBuilder::max_past_epochs` (default `DEFAULT_MAX_PAST_EPOCHS = 5`, wire_format.rs:38 — do not
  override); past-epoch 445s now via retained snapshots not app-held secrets, so the assertion shape
  changes, the number preserved.
- **Rule 6/8 redaction** → gate over the new `EngineError`/`PeelerError` taxonomy (#864 still open —
  five validators embed full group-id hex; keep `redact_hex_sequences` at the boundary).

**REWRITE / RE-POINT:**
- **`m7b_every_mdk_write_site_acquires_the_writer_lock`** (`EXPECTED_WRITE_SITES = 28`): rewrite to scan
  for `session.<mut method>(` under `session.lock().await`; re-derive the count from the ported write
  list (send/ingest/confirm_published/publish_failed/create_group/fresh_key_package/delete_key_package/
  advance_convergence). **`classify_mdk_error_*`** → DELETE or re-express over
  `IngestOutcome`/`StaleReason`/`EngineError`.

**CONSTRUCTION-PATTERN migration (~100 integration tests):** `MdkManager::new_unencrypted()` ×N →
`SqliteAccountStorage::in_memory()` + `EngineBuilder` (or a `SessionManager::in_memory()` ctor) **[V]**
connection.rs:417; the two-party fixture becomes two in-memory sessions; the `test-utils` feature is
replaced by public `in_memory()` and may be dropped. **NOT affected:** `proptest_*`, `tile_at_rest_test`
(except rusqlite downgrade), `profile_*`, `relay_*`, `zeroization_security.rs` (re-verify DM secret
types — `SecretBytes = Zeroizing<Vec<u8>>`, `SqlCipherKey(Zeroizing<String>)`).

**CI:** re-baseline coverage after the large deletions (ratio should hold). **Keep the SQLCipher
Android/iOS cross-check** (`bundled-sqlcipher-vendored-openssl` on `storage-sqlite`) as a DM-1 exit
criterion (§8.6); `fs-private` downgraded to routine verify (§5.8). Add a **`cargo tree` supply-chain
gate** (one version per unified crate; `uniffi`/`quic`/`agent` absent — security F8c) and a **grep
guard that Haven never calls `with_exporter_label`** (the override is Haven-constructed, not
wire-negotiated — closes the only local downgrade lever, security F14). Run clippy pedantic+nursery
over the new async/`&mut`/`.await`-in-lock sites. e2e lanes: relay kind **443 → 30443** on kind-10002
relays (welcome/445 unchanged in kind); DB-wipe scripts already handle `session.sqlite`; the
two-relay/background-catchup/profile lanes need the KP-kind + welcome-lifecycle updates.

### 5.8 Mobile-compile risk re-rating (engineering, CORRECTED)

`fs-private` was previously a critical-path risk; **downgrade to verify-in-DM-1.** **[V]** it is
cross-platform ("Mode application is Unix-only; elsewhere the helpers create the artifacts and the mode
calls are no-ops", lib.rs:9-10); every unix block has a `#[cfg(not(unix))]` no-op, and the unix-socket
code (`bind_unix_listener_private`) is `#[cfg(unix)]` and **not called by the DB path**. Android/iOS
**are** `unix`, so `std::os::unix::fs` applies; no `/proc`/xattrs/`target_os` code. The only genuine
cross-compile risk on the `open_encrypted → ensure_private_db_files → fs_private` path is the bundled
SQLCipher build — which Haven already ships. **Keep the SQLCipher Android+iOS cross-check as a DM-1
exit criterion; treat `fs-private` as routine.**

---

## 6. Rollout / flag-day plan

No wire bridge (§4) + no DB migration path ⇒ a coordinated cutover. Haven-specific facts that make it
tractable: circles are **small family groups**, **admin = circle creator**, **invites are
QR-delivered** in person, and **identity keys survive** (nsec is a Nostr key — MLS keys were always
separate per Rule 1).

**Survives:** Nostr identity (nsec), kind-0 public profile + Blossom avatar (identity-key-signed,
protocol-independent), local petnames/settings.
**Lost / recreated:** all MLS group state, all circles (admin re-creates), all memberships (members
re-invited), all published KeyPackages (new 30443 on NIP-65), the persisted `hash_ref` rows (cleared +
re-seeded, §5.5).

**Cutover design:**
1. **App-version gate + kill-switch.** Ship the Dark Matter build behind a version flag (mirror
   `HAVEN_LIVE_SYNC`); a new-stack client MUST NOT attempt old-stack groups and vice-versa. Coordinate
   per-circle: the circle updates, then the admin re-creates it.
2. **Re-onboarding UX (identity preserved).** On first launch: keep the nsec, wipe MLS state (reuse
   `wipe_all_mls_state`; **also destroy `mdk.db.key.default` per §5.5 / F6**), publish a fresh **30443**
   to the user's **10002** relays, surface a one-time explainer. No re-generation/re-login. **Offline
   window (security F10b):** if offline after wipe, the fresh 30443 is not yet published so the user is
   temporarily **un-invitable** — show this and retry on reconnect.
3. **Admin re-creates, members re-accept.** The creator re-creates each circle and re-issues **QR
   invites**. Provide an in-app "circles to re-create" checklist seeded from the old roster — **the
   old-roster read is LOCAL-ONLY, never published, cleared after re-creation** (security F10c), for
   admin convenience only, never a source of migrated MLS bytes.
4. **Un-migrated members.** A member still on the old build is invisible to the new circle. **Detection
   MUST batch (security F11):** fold the presence check (old-stack 443/10051 vs a 30443) into the
   **existing KP-discovery REQ** — no per-target probe pattern (mirror SECURITY.md profile-fetch
   batching). UX: **"needs to update"**; block invite until they publish a 30443. Do not silently drop
   or attempt cross-stack messaging.
5. **Relay hygiene — NON-OPTIONAL (security F10a).** On cutover: **stop publishing** 443 twins + 10051
   lists; publish 10002 (NIP-65) + 10050 (inbox); and **actively retract the 10051 list + clean up stale
   443s** (kind-5 deletion or empty replaceable, mirror WN #845). **Not optional** — a live 10051/443
   lets an old-stack client mint a welcome the new client cannot process. New KP rotation follows
   last-resort semantics (pruned only via explicit `delete_key_package`).
6. **Transitional dual-stack build — REJECTED.** `libsqlite3-sys` is a `links` crate (one version per
   binary; DM pins rusqlite 0.32 vs Haven's 0.37) so two MDK generations cannot coexist; and with no
   shared group state or wire bridge, a dual stack buys only a longer, error-prone transition surface
   with no interop gain. **Single hard cutover per app version, coordinated per-circle by the admin.**
   (INFERRED, high confidence.)

---

## 7. Security review & new rules

Mapping Haven's Security Rules 1–10 onto the new stack. **COMPLIANT** = posture preserved; **PORT** =
same rule, new wiring; **MITIGATE** = new Haven-side obligation. Security findings F1–F15 are folded in.

- **Rule 1 — Key separation (MLS sig ≠ Nostr identity).** COMPLIANT + PORT, **with a mandatory
  hardening spec (security F1).** Now formalized on-wire as the `account-identity-proof.v2` leaf ext
  (W7). Haven wires its identity key as the `AccountIdentityProofSigner` (required at `SessionConfig`).
  The signer signs a Schnorr sig over a kind-450 event — **if it signs an arbitrary handed-in digest it
  is a blind identity-key oracle.** REQUIRED: it MUST (i) **recompute `request.proof_event()` itself and
  sign only that canonical id**, (ii) **assert `request.account_identity == local identity pubkey`**
  (refuse foreign identities), (iii) be a **purpose-scoped wrapper over the nsec — never a general
  `NostrSigner`.** Add a test. Domain separation is inherent (kind 450, `created_at=0`) so cross-replay
  to kind-0/24242 is blocked by the NIP-01 id — but only if (i) holds. **Stability caveat (F8b /
  go-signal §3.1(5)):** `account_identity_proof.rs:8-20` documents (mdk#755) that this signer/verify
  layering is pre-refactor and will move — treat the API as in-flux; a DM-2 risk.
- **Rule 2 — Ephemeral key per kind-445.** COMPLIANT. Engine/peeler generates a fresh ephemeral per
  445 (`peeler.rs:144`, asserted `:740-774`). Keep it delegated; keep the re-expressed uniqueness gate
  (§5.7).
- **Rule 3 — kind-444 unsigned.** COMPLIANT. Rumor unsigned; only the 1059 seal signed.
- **Rule 4 — Group-ID privacy.** COMPLIANT. `GroupId`=MLS-only never leaves the engine; `NostrRoutingV1`
  (0x8004) supplies the transport id (W6). Keep boundary redaction on every FFI type + the re-expressed
  "no MLS `GroupId` in any published event" gate (§5.7).
- **Rule 5 — Exporter retention (`DEFAULT_EPOCH_LOOKBACK`=5).** COMPLIANT (aligned). Now engine-internal
  `DEFAULT_MAX_PAST_EPOCHS = 5` (**[V]** wire_format.rs:38), configurable — **do not override.** Verify
  pruning still zeroizes. **Pure-plaintext posture (protocol finding):** `wire_format.rs:1-44` uses
  `PURE_PLAINTEXT_WIRE_FORMAT_POLICY` (MLS PublicMessage both directions), so **the kind-445 outer
  ChaCha20 wrap keyed by the exporter secret is the SOLE MLS-level confidentiality layer** — making
  exporter-secret retention *the* confidentiality boundary. Upstream marks this "Revisit Before External
  Rollout" (`WIRE_FORMAT_POLICY_REVIEW_REQUIRED`) — its resolution is go-signal §3.1(6).
- **Rule 6 — No key logging.** PORT/verify. **#864 (OPEN): five validators embed full group-id hex in
  `EngineError::Other`.** MITIGATE: keep `redact_hex_sequences` at the new error boundary
  (`EngineError`→`CircleError::Mls`) + a redaction gate over the new taxonomy until #864 closes (also a
  §3.1 go-signal).
- **Rule 7 — Zeroization.** COMPLIANT. New `SecretBytes`/`SqlCipherKey` are `Zeroizing`, Debug-redacted;
  re-verify `zeroization_security.rs`. Two folded-in specs: **(a) SQLCipher passphrase (F5)** — full
  spec in §5.5 (hex/base64 of ≥256-bit `OsRng`, `Zeroizing` end-to-end, never logged). **(b) Welcome
  secret-at-rest (F3)** — under Option A hold the **still-NIP-59-encrypted 1059**, never the decrypted
  `welcome_bytes` (which carry MLS join secrets); unwrap only at Accept; preview from routing metadata;
  `Zeroizing` + **wipe-on-decline**; never log. Add the invariant (+test) that Haven's relay/live-sync
  pipeline **must NOT auto-`ingest` 1059s** — they route to the pending store (`peel_welcome` is
  standalone at `peeler.rs:244`, so preview-without-ingest is feasible).
- **Rule 8 — No raw errors in UI.** PORT (see Rule 6). Add `GroupState::Unrecoverable` as a first-class
  **blocked-group** UI state (no send/mutate); FFI shape in §5.6.
- **Rule 9 — Dart secret lifetime.** COMPLIANT (the engine reduces Haven's direct exporter-secret
  handling to near-zero).
- **Rule 10 — Privacy first.** COMPLIANT. Encrypted-media/push are opt-in and unused; do not enable by
  default. The welcome-decline regression (§8.4) is resolved in Rule-10's favor by hold-before-ingest
  (Option A) — decline leaves no on-wire trace.

**Threat-model additions:**
- **Publicly rebroadcastable identity binding (security F12).** Any co-member can extract the leaf
  identity-proof and rebroadcast a valid identity-key-signed kind-450 (`created_at=0`) event to relays,
  **publicly binding the Nostr pubkey to MLS participation.** Irreducible (co-members already see the
  credential), but **document it in SECURITY.md / the threat model.**
- **Nonce RNG (security F14, INFO).** The 445 nonce uses `rand::thread_rng()` (`peeler.rs:121`), not
  `OsRng` — a CSPRNG (acceptable) and engine-owned. No action.
- **Formal-methods caveat (security F15).** Tamarin models the protocol abstraction, not the Rust impl
  of a not-semver-stable engine; it does not reduce the empirical e2e burden (§2.2, §5.7).

**Database posture (WAL — see §5.3).** SQLCipher stays first-class; the MLS DB moves from Haven's
rollback-journal/`busy_timeout=0` to `storage-sqlite`'s **WAL**, so Haven must re-derive its
cross-isolate write story — and the invariant is now stronger than write serialization: **at most one
live `AccountDeviceSession` per DB file** (Rule 14).

**NEW rules to add to CLAUDE.md:**
- **Rule 11 — ChaCha20-Poly1305 nonce uniqueness.** The 445 nonce MUST be CSPRNG-random (12 bytes) and
  MUST NOT repeat under a fixed epoch `group_event_key`. The engine does this; add a nonce-uniqueness
  assertion to Haven's send-path tests (empty AAD = no extra binding).
- **Rule 12 — Convergence-buffer flooding (#757).** The stored-convergence buffer has **no per-group
  cap** (OPEN upstream; §3.1 go-signal). MITIGATE with **rate-limit-with-backpressure, NEVER a silent
  drop of legitimate offline backlog** (future-epoch catch-up is legitimate). **Honest limit (security
  F7):** once Haven `ingest`s, the engine owns the durable buffer with **no eviction API**, so a
  Haven-side intake cap alone is **insufficient** — **#757 closure is the real fix**; the cap is intake
  throttling, not a bound on engine storage.
- **Rule 13 — Publish-before-apply discipline.** The engine enforces it via `PendingStateRef`. **"Acked"
  MUST mean ≥1 relay returned OK before `confirm_published` — never "sent" (security F13)** — to avoid
  optimistic-merge forks (matches WN `publish_and_merge`). Treat `PendingCommitRecovered` as a mandatory
  resync.
- **Rule 14 — Single-session invariant — PROMOTE NOW (security F4).** At most one live
  `AccountDeviceSession` per MLS DB file across all isolates/processes. **Adopt as a hard rule
  immediately (not "once M7 lands").** Two live sessions = divergent in-memory epoch state = **not just
  corruption but exporter-key/epoch reuse and forward-secrecy erosion.** The M7 background-isolate
  decision (§8.5) is a **blocker for DM-3.**

---

## 8. Open questions & pre-implementation verification list

Each must be confirmed against the clone before coding — interop correctness is byte-exact. Detail
lives in the referenced section; this is the checklist index.

1. **Identity-proof spec-vs-code** (header reconciliation, §8.1). Implement to the code (`0xF2F1`, kind
   450, domain `.v2`, `VERSION=2`, `created_at=0`, Schnorr over the canonical kind-450 id); the spec
   body is behind the code — reinforces go-signal §3.1(2). Ensure `RequiredCapabilities` matches what
   peers advertise. (CONFIRMED code; spec out of sync.)
2. **Canonical app-component encoding** (§5.2 #28, Rule 4). Read `canonical-encoding.md` +
   `app_components/{codec,routing}.rs`: `NostrRoutingV1` (0x8004) is the authoritative `h`-tag source;
   verify its byte layout and that no `0xF2EE` remnant is read. (UNVERIFIED — codec not read
   line-by-line.)
3. **Inner application-message rules** (W9). Read `application-messages.md`: `MarmotAppEvent` canonical
   NIP-01 id, inner `pubkey` == MLS sender, kind-9 location + `["t","location"]` survives (system rows
   are inner **kind-1210** — do not collide). (Partly CONFIRMED via code.)
4. **Welcome hold-before-ingest** (§8.4 below / §5.2 #3–#6 / §7 Rule 7b). Verify ingest is the *only*
   auto-join trigger and preview derives from routing metadata (no secret decryption). CONFIRMED: no
   `Declined` state, ingest auto-joins.
   - **§8.4 Option A (adopted).** Hold the still-encrypted 1059 until Accept; discard on Decline with no
     on-wire trace (preserves current semantics, Rule 10). **Option B (only if A infeasible):**
     ingested-but-pending projection, Decline = join-then-SelfRemove — weaker; document the leak.
5. **§8.5 — M7 background-isolate / single-session invariant** (Rule 14; **blocks DM-3**, highest risk).
   Decide (a) shared-session handle vs (b) cross-isolate exclusive file lock. Confirm `storage-sqlite`
   WAL semantics + #866's `SQLITE_BUSY` window; determine whether any process-global writer lock
   survives (subsumes the WAL write-serialization detail — check `connection.rs`).
6. **§8.6 — mobile SQLCipher cross-compile** (DM-1 exit criterion). Prove `cargo check --target
   aarch64-linux-android` / `aarch64-apple-ios` on the pinned tag before DM-2. `fs-private` is routine
   (§5.8); the bundled-SQLCipher build is the real gate.
7. **`RequiredCapabilities` superset composition** (W6/W7). Verify the exact required set `create_group`
   emits so Haven's KeyPackages advertise a superset (else self-invite fails). (UNVERIFIED.)
8. **Persisted `hash_ref` reseed** (§5.5/§5.6). Clear `published_key_packages` on cutover, re-seed from
   fresh 30443 KPs; confirm the new `KeyPackage.source`/metadata shape before finalizing the FFI field.
9. **GroupId API + admin-policy surface** (§5.6). Confirm `GroupId` = `new`/`as_slice`/`into_bytes`/
   `as_ref` (not WN's `from_slice`/`to_vec`). RESOLVED: `propose_admin_handoff` routes through
   `UpdateAppComponents(admin-policy.v1)`; post-hoc admin promotion works today (§11.1).

---

## 9. Phasing & effort

**DM-0 is safe to do now on the *current* pin** and absorbs all §3.2 do-now items. The
do-not-migrate-yet posture stands (§3) — DM-1 onward executes only at go-signals.

| Milestone | Content | Effort | Critical-path risk |
|---|---|---|---|
| **DM-0** (now, forward-compatible) | Repo-URL repoint `parres-hq/mdk` → `marmot-protocol/mdk` @ same rev `93ae324`; keep `93ae324`; encapsulate direct exporter-secret + storage-provider access behind `MdkManager`; rewrite `MARMOT_PROTOCOL_KNOWLEDGE.md` old-vs-new (§4). No DM dependency change. | S (1–2 d) + doc rewrite | none — pure insulation/hygiene |
| **DM-1** deps + storage skeleton | Flip Cargo to the five DM crates @ a **released tag** containing the commit-loss train (§5.1, §3.1(4)); downgrade rusqlite 0.37→0.32 + libsqlite3-sys 0.35→0.30; toolchain ≥1.90; **NO keyring-core bump** (not a requirement — §5.1); `cargo tree` supply-chain gate (uniffi/quic/agent out; marmot-forensics audited); prove `cargo build` + **cross-check Android/iOS SQLCipher** (§8.6 exit criterion, fs-private routine); wire `SqlCipherKey` fresh-passphrase scheme (§5.5, F5). | M (3–5 d) | rusqlite downgrade vs circles/tiles; **mobile SQLCipher cross-compile**; released-tag availability |
| **DM-2** SessionManager port | Rewrite `MdkManager`→`SessionManager` (`tokio::sync::Mutex<AccountDeviceSession>`); build `NostrMlsPeeler` + the **hardened `AccountIdentityProofSigner`** (§7 Rule 1 / F1); port the 36 methods incl. hold-before-ingest welcome store (§8.4-A / F3); implement `NostrTransportEvent` ↔ relay conversion; delete peek/un-poison/classifier; **delete M8-2 gate AND rework `relay/maintenance/key_package.rs`** (coupled consumer — §2.1). | L (1.5–2.5 wk) | account-identity-proof signer (in-flux, mdk#755); async+`&mut` ripple; welcome verification (§8.4) |
| **DM-3** engine/convergence rewire | Publish-before-apply flow (`PendingStateRef` confirm/fail, Rule 13 ≥1-relay-ack); collapse settle-window/converge/marker into `ingest`+`advance_convergence`; make `process_group_event` async; group-relay-set validation (W8); **resolve the single-session cross-isolate invariant (Rule 14, blocks this milestone)**; Rule-12 backpressure. | L (1.5–2.5 wk) | **single-session-per-DB vs M7 background isolate** (highest risk) |
| **DM-4** FFI + Dart | FRB regen for DecryptOutcome/UpdateGroupResult/GroupState(+Unrecoverable)/welcome-lifecycle (§5.6); rework Dart cursor-advancement (engine owns retry); `Unrecoverable` UI-block (Rule 8); wipe-and-recreate guard + `published_key_packages` clear + **`mdk.db.key.default` destruction** (§5.5, F6). | M (4–6 d) | Dart cursor/retry semantics; Unrecoverable UX |
| **DM-5** tests/CI + cutover | Migrate ~100 tests to `in_memory()`; **re-express (not delete) the security black-box gates** incl. the out-of-order convergence e2e (§5.7, F2/F9); rewrite the write-site guard; add the `with_exporter_label` grep guard (F14); re-baseline coverage; e2e 443→30443 + 10002/10050; flag-gated cutover with **non-optional 10051/443 retraction** + batched un-migrated detection (§6, F10/F11); new security-rule tests. | L (1–2 wk) | coverage re-baseline; e2e on real relays; re-onboarding correctness |

**Total rough order: ~6–9 weeks** — optimistic given first-external-adopter status and unproven mobile
SQLCipher build — gated on the three critical-path risks: (1) single-session-per-DB vs the background
isolate (§5.3/§8.5), (2) mobile SQLCipher cross-compile (§8.6), (3) the account-identity-proof signer +
welcome auto-join as new hard requirements with no old equivalent (§7 Rule 1 / §8.4).

---

## 10. Appendix: Haven files to re-verify / rewrite at execution

`haven-core/src/nostr/mls/{manager.rs,peek_crypto.rs,types.rs,storage.rs}`,
`haven-core/src/nostr/giftwrap.rs`, `haven-core/src/circle/{manager.rs,converge.rs,storage.rs}`,
`haven-core/src/relay/maintenance/key_package.rs` (M8-2 coupling — §2.1/§5.2 #31),
`haven-core/src/relay/live_sync/{settle,finalize,converge,autocommit,plan,processor}.rs`,
`haven-core/Cargo.toml`, `haven/rust_builder/src/api.rs`,
`MARMOT_PROTOCOL_KNOWLEDGE.md` (stale — DM-0 rewrite), `haven-core/SECURITY.md` (threat-model additions
F6/F12; passphrase scheme F5), `CLAUDE.md` (new Rules 11–14).

**Upstream source-of-truth files (in the examined clone, HEAD `609e27d`):**
`crates/transport-nostr-peeler/src/{lib.rs,peeler.rs,event.rs}`,
`crates/cgka-engine/src/{account_identity_proof.rs,engine.rs,key_package.rs,wire_format.rs}`,
`crates/traits/src/{types.rs,welcome.rs,ingest.rs,engine.rs,storage.rs,app_components/{mod,codec,routing}.rs}`,
`crates/cgka-session/src/lib.rs`, `crates/storage-sqlite/src/connection.rs`, and the marmot spec files
`foundation/{account-identity-proof-v1,canonical-encoding,application-messages}.md`,
`transports/nostr.md`.

## 11. Known limitations post-migration (upstream-blocked)

Functional gaps the migration was completed *around* — capabilities the MDK v0.9.4
**public** API was assessed as not exposing.

> **Read §11.1 before trusting any entry here.** The one item originally recorded
> in this section turned out not to be an upstream gap at all: the operation was
> reachable through the public API the whole time, and only a *convenience
> encoder* was missing. Before recording a capability as upstream-blocked, check
> whether MDK's own out-of-crate consumers (`cgka-conformance-simulator`, the
> `crates/cgka-engine/tests/` suites) perform it — if they do, it is public API by
> construction, and its conformance vectors under
> `crates/cgka-conformance-simulator/vectors/` are the contract to code against.

### 11.1 Admin hand off / self-demote → **RESOLVED 2026-07-26 (was never an upstream gap)**

**Status:** RESOLVED and shipped. `LeavePlan::AdminHandoff` and `LeavePlan::AdminDemote`
both complete end-to-end; a circle's admin leaves like anyone else.

**What the original assessment got wrong.** The group admin set did move from the old
`NostrGroupDataExtension` (0xF2EE) into the MLS app component
`marmot.group.admin-policy.v1` (0x8003), and it is true that MDK v0.9.4 re-exports a
convenience encoder for the *routing* component (`encode_nostr_routing_v1`) but none for
admin-policy — `cgka_engine::app_components::encode_admin_policy` is `pub(crate)`. The
error was concluding from a missing *convenience helper* that the *operation* was
unreachable. It is not: an admin-policy update is an ordinary
`SendIntent::UpdateAppComponents{ component_id: GROUP_ADMIN_POLICY_COMPONENT_ID, data }`
through the public engine API, and every primitive needed to build `data`
(`GROUP_ADMIN_POLICY_COMPONENT_ID`, `AppComponentData`, `encode_quic_varint`) is public in
`cgka-traits`.

**Evidence it is a supported public operation, not a reach into internals:**

* MDK's own `cgka-conformance-simulator` — a crate *external* to `cgka-engine`, subject to
  the same public API — implements `update_admin_policy` exactly this way, hand-encoding
  the component bytes (`crates/cgka-conformance-simulator/src/client.rs`).
* It ships a versioned conformance vector for the scenario at the pinned release:
  `vectors/admin-policy-update.v1.json`, `conformance_version: "0.9.4"`, including the
  `not_group_admin` and empty-admin-set rejection cases.
* The engine *validates* the component on the way in (`validate_app_component_update` →
  `decode_admin_policy`, plus `require_admin` and `reject_admins_without_member_leaf`), so
  a malformed or unauthorized policy fails closed and loudly at commit time — it can never
  half-apply or silently corrupt group state.

**Wire format** (`admin-policy.v1`): a QUIC varint byte-length prefix followed by the
concatenated 32-byte x-only admin pubkeys, ascending byte order, no duplicates. The
decoder rejects trailing bytes, a non-multiple-of-32 length, and any unsorted or duplicated
key. Haven encodes it in one place — `encode_admin_policy_v1` in
`haven-core/src/nostr/mls/manager.rs`, behind `SessionManager::update_admin_policy`.

**What now works:**

| `LeavePlan` case | Works? |
|---|---|
| `NonAdmin` (SelfRemove) | ✅ |
| `Abandon` (sole remaining member) | ✅ |
| `OrphanLocalOnly` (local delete) | ✅ |
| `AdminHandoff` (sole admin **with** other members → promote successor + self-demote) | ✅ |
| `AdminDemote` (one of several admins → self-demote) | ✅ |

The promote step is **additive** (successor is added to the existing admin set, the caller
is not dropped), so the group is admin-covered at every intermediate epoch and a crash
between the two commits resumes on the `AdminDemote` leg without re-promoting.
`propose_self_demote` fails closed when the caller is the last admin, so a circle can never
be left with an empty admin set.

**Removed with the limitation:** the admin-only UI note
(`circles_bottom_sheet.dart`), its l10n key `leaveCircleAdminLimitationNote` across all 13
locales, and `WidgetKeys.leaveCircleAdminLimitationNote`. The widget suite that asserted
the note is repurposed as `leave_circle_admin_parity_test.dart` — a regression pin that an
admin's Leave CTA is enabled and carries no caveat copy.

**Coverage restored** (all previously descoped *because of* the phantom gap):

* `haven-core/src/circle/manager.rs` — `admin_handoff_end_to_end` (replaces
  `propose_admin_handoff_is_a_documented_gap`), plus
  `propose_self_demote_by_sole_admin_is_rejected` and
  `propose_admin_handoff_rejects_a_non_member_successor`.
* `haven-core/tests/circle_integration_test.rs` —
  `admin_handoff_transfers_admin_and_group_stays_usable` (un-deleted): three-party
  cross-party convergence on the new admin set, the demoted admin losing admin-only
  authority, the successor gaining it, and location still round-tripping afterwards.
* `haven/integration_test/circle_admin_leave_ghost_test.dart` — the 2-admin variant is
  restored, so the `AdminCannotSelfRemove` tripwire again rules out the
  "a second admin lets you bypass self-demote" loophole rather than being confounded by
  admin-depletion.
* `haven/integration_test/e2e/e2e_combined.dart` PHASE 5 — unchanged; it always encoded the
  correct behaviour (3 commits: AdminHandoff → SelfDemote → SelfRemove, epoch +3) and was
  the CI lane failing against the stubs.
