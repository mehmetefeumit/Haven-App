# Stage 1a — dependency sources and the rust-nostr 0.44 → fork migration of Haven's relay layer

Status: plan, revised after independent security, engineering, test/CI and data-integrity review (2026-11-14).
Nothing here has been implemented.

Part of `docs/MDK_V016_MIGRATION_PLAN.md`, beside `docs/mdk-v0.16/stage0.md` (Stage 0, "S0.x" units),
`docs/mdk-v0.16/stage1b_mdk.md` (Stage 1b, "1b") and `docs/mdk-v0.16/stage2_runtime.md` (Stage 2). Owner
decisions (D1–D4), owner items (O1–O13), migration rulings (R1–R6) and the master step numbers are those of the
master document; review-finding ids ("security M1", "engineering M11", X1–X16) are mapped in the review ledger at
the end. "The trial" is a throwaway build of today's tree with the Stage 1 pins, used only to count compile
errors.

Source references:

- **H** = Haven at the planning commit (`haven-core/…`, `haven/rust_builder/…`, `tooling/…`).
- **F** = `erskingardner/rust-nostr@e93cc06b5624f06c21ecd8111a124176eb0c7589` (`nostr/src/…`, `nostr-sdk/src/…`).
- **M16** / **M10** = MDK `a2e0558a` (v0.16.0) / `fcc85edd` (v0.10.4), paths under `crates/`.
- **P44** = crates.io `nostr-0.44.8`, `nostr-sdk-0.44.1`, `nostr-relay-pool-0.44.3`, `async-wsocket-0.13.2`.

Every API claim was read at F, M16 or P44; anything not confirmed is marked UNVERIFIED. Owner decisions bind: D1
(staged; Haven's fanout driver kept in Stage 1), D4 (Rule 16 keeps Haven's own `verify()`), and the R6 defaults
that touch this part: **O12** (no `user-agent`, via Haven's own header-less transport) and **O13** (Haven refuses
exactly the Welcomes the pre-fork NIP-44 encoder refused). Effort is counted in build cycles (R1.c): `cargo check --all-targets`
≈ 3.5 min and a full haven-core suite ≈ 30 min on the build machine (measured 2026-11-14). Flutter, `flutter
analyze`, `flutter test` and `./scripts/regenerate_frb.sh` run locally (R3.i); only emulator/simulator lanes, the
Apple/Windows/Android cross builds, `build-check` and `release-link` are GitHub-CI-only.

---

## 0. Scope and ownership

**1a owns:** every `nostr` / `nostr-sdk` type and call; the client constructor and Security Rule 16 (code and
CLAUDE.md text, X15); the relay pool, test relays and `tooling/e2e/local-relay`; pins, manifests and lockfiles; the
*values* in the supply-chain guards (the mechanisms are Stage 0's, X4–X6/X13); the fanout's *relay* side (the
listener and the refusal proof rule, §D.1); NIP-77 including its constants and sentinel (X7); the relay URL policy
including the `.onion` refusal (X11, R4.k); and the oversized-Welcome refusal (R4.a, §C.8).

**1b owns** the `marmot-session` / `cgka-*` API changes, the `possible_exposure()` audit (X8; 1a contributes one
test, §D.2), the test SQLCipher key (R4.e, in the pins step), the single `api.rs` semantic batch, and the CLAUDE.md
"MDK pinning" bullet and the SECURITY.md/tracker edit as the one docs editor (X15; 1a supplies the facts in §C.7
and §E).

**One editor per shared file** (engineering §3): `relay/fanout.rs` is 1a's until CP-T and 1b's afterwards, so
§D.1's semantic change (step 16.2) is made by the file's owner from this specification, with the tests in the
1a-owned `tests/fanout_transport_matrix.rs`. `nostr/mls/*` (including `signer.rs`, where §C.8's check lives, and
the peeler construction in `manager.rs`) is 1b's after 1a's step-13 path-script commit; §C.8 is specified and tested
here and committed by the files' owner.

**What Stage 0 must already have delivered** (all green on v0.10.4, R3):

| Stage 0 unit | What 1a relies on |
|---|---|
| S0.10 pre-bump refactors (R3.k) | `nostr::{event,key,types,filter,message}::…` and `nostr::nips::nip01::Metadata` paths (bilingual at P44 `nostr/src/lib.rs:43-65`); `SecretKey::generate` in `nostr/keys.rs` and `identity/keypair.rs`; the shared source-asserting `mdk_source` / `sdk_source` helper; the deletion of `nostr::encryption` **with the ceiling promise still pinned** (§C.8.4) |
| S0.3 G3 / G4–G5 / G6 | universe guard with per-root expected subsets and a nostr source check; MDK allowlist and `--nostr-features`; `tooling/soak/tests/pool_constants.rs` in place of the `rust-check.yml` reconnect step |
| S0.4a / S0.4b / S0.4c | the NIP-42 no-answer test with its positive control; the handshake header-name test (renamed `no_relay_socket_sends_a_user_agent`, X9); the re-issue and silent-REQ delivery tests |
| S0.4d | the lag test `a_lagged_notification_stream_holds_every_owed_cursor`; `targeted_fetch_end_shapes.rs` (EOSE, cap, CLOSED, disconnect, idle timeout, forged frame) against Haven's own fetch function |
| S0.9 (R3.a) | the wire-equivalence golden transcripts (W1–W15; W10 is a NIP-77 pass cut at Haven's deadline through `neg_remote_ids`, which records the T-NEG-CLOSE gap) and the count-based cost ledger |
| S0.10 item 4 | the oversized-invite product test `an_invite_whose_welcome_exceeds_the_nip44_ceiling_sends_nothing` |

The raw-pool gap test for T-POOL-TERMINATE-PERMIT is **not** written: a test against the 0.44 pool's private
shape cannot compile on F, so it would be rewritten rather than flipped (engineering M11). That removal rests on
F's structure plus the promise tests (§E).

---

## 1. Facts that shape this part (verified at F / M16 / P44)

1. **NIP-44 has no plaintext ceiling at F.** F's v2 codec takes up to `u32::MAX` bytes and switches to a 6-byte
   extended length prefix at 65 536 bytes (`F nostr/src/nips/nip44/v2.rs:28-29,102-114`). The RNG-backed
   `nostr::nips::nip44::encrypt` / `encrypt_with_rng` still exist (`F nostr/src/nips/nip44/impl.rs:113-152`); what
   is gone is the low-level nonce-less `v2::encrypt_to_bytes` (F keeps only `encrypt_to_bytes_with_nonce`,
   `v2.rs:204`). P44 refuses to encrypt more than 65 408 bytes (`nostr-0.44.8/src/nips/nip44/v2.rs:35,334-336`),
   and a P44 receiver decodes only the two-byte prefix, at most 65 603 payload bytes (`:30-38,260-262,297`). MDK
   v0.16.0's peeler produces extended-length Welcomes (`M16 transport-nostr-peeler/src/peeler.rs:1287-1338`, a
   ≈150-member circle). Haven keeps refusing them (§C.8).
2. **`nostr::encryption` has no production caller** (not in `api.rs`, not in `haven-core/src` outside the module).
   Its users are two test files: `haven-core/tests/proptest_security.rs` **and**
   `haven-core/tests/nip44_plaintext_ceiling.rs`. Deleting it also deletes its two `TODO(security)` lines
   (`nostr/encryption/mod.rs:31,65`).
3. **0.44 sends no `user-agent`; F's default transport sends `nostr-sdk/0.45.4`**
   (`F nostr-sdk/src/transport/websocket.rs:23-24,96-100`; no `user-agent` anywhere in P44's pool, sdk,
   `async-wsocket-0.13.2` or `tungstenite-0.26.2`). `haven-core/SECURITY.md:5149-5154` says the handshake carries
   `nostr-sdk`'s default `User-Agent`; that is false today (pre-existing doc defect) and is corrected (§C.7).
4. **`Relay::queue()` is gone** (no `fn queue` under `F nostr-sdk/src/relay/`). The race Haven's wedge detector
   (`H relay/manager.rs:352-405`) looks for is closed structurally: `Connected` is published only under the
   connection-task ownership lock and only for a dial that was not superseded (`F relay/inner.rs:814,843,1066-1106`).
5. **F refuses a REQ whose id the relay still holds** (`F relay/inner.rs:536-553`, "subscription ID already
   exists"); a registration survives a `rate-limited:` CLOSED (`:1441-1470`) and a silent live REQ. Upstream's
   atomic `Relay::reissue_subscription` (`up/master f7ebc0a8`, PR #1495) is not in the fork.
6. **`subscribe_long_lived` registers before it sends the REQ** (`F relay/api/subscribe.rs:94-120`), so the race
   `check_engine_client_options.sh` checks 1–2 and `H live_sync/session.rs:89-110` describe no longer exists.
   `verify_subscriptions` stays off for a different, true reason (§C.2).
7. **`Client::add_relay(url).opts(x)` replaces the client-composed options** (`F client/api/add.rs:131-137`); on
   an existing relay `add_relay` ORs capabilities and leaves its options alone (`F pool/mod.rs:176-185`). PING is no
   longer a capability (`F relay/capabilities.rs:37-61`); it is the per-relay, immutable `RelayOptions::ping`.
8. **The admission policy's `BoxedFuture` is `pub(crate)`** (`F nostr-sdk/src/future.rs:3`); implementers spell
   `Pin<Box<dyn Future<Output = Result<AdmitStatus, nostr_sdk::error::Error>> + Send + 'a>>`.
9. **The client database Haven gets cannot hold NIP-77 items.** `ClientBuilder::default()`'s database is the
   private id-only `MemoryEventsTracker`, whose `negentropy_items` always answers `Vec::new()`
   (`F nostr-sdk/src/events_tracker.rs:92-97`). `Relay::sync` reads that database when `.items(..)` is not given
   (`F relay/api/sync.rs:104-110`). The "advertises nothing" promise therefore needs a test whose positive control
   uses a database that *can* answer (§B.3.5).
10. **The fork's pinger signals at connection start and the sender loop takes the signal at its next idle
    `select!`** (`F relay/inner.rs:193-195` `notify_one`, `:1419-1430`, `:1244-1290`); reconnect off ends a dropped
    connection in `Terminated`, on in `Disconnected` (`:945-957`). Both are what §B.3.3's behavioural option tests
    observe.

---

## A. Manifests, pins, lockfiles (master step 12 — the RED-WINDOW opens here)

### A.1 Roots

| Root | Links MDK | Links nostr | Action |
|---|---|---|---|
| `haven-core` | yes | yes (+ dev `nostr-relay-builder`, dev path dep `haven-local-relay`) | full edit |
| `haven/rust_builder` | via haven-core | `nostr`; dev `nostr-sdk`, `nostr-relay-builder` | edit |
| `tooling/soak` | `cgka-engine`, `cgka-traits`, openmls | `nostr`, `nostr-sdk`, `nostr-relay-builder`, `nostr-database`; dep `haven-local-relay` | edit |
| `tooling/e2e/local-relay` | no | `nostr-relay-builder 0.44`, `tokio-tungstenite 0.26` | **must move** (it lands in haven-core's and soak's locks as a path dependency; left behind it is a second nostr universe) |
| `tooling/logscan`, `tooling/e2e/local-blossom` | no | no | none |

Git sources are spelled byte-identically to MDK's workspace (`M16 Cargo.toml:58-61,134-136`): rust-nostr URL
without `.git`, openmls with `.git`, full 40-hex revs, never abbreviated. Shorthands:
`NOSTR_GIT = git = "https://github.com/erskingardner/rust-nostr", rev = "e93cc06b5624f06c21ecd8111a124176eb0c7589"`;
`MDK_GIT = git = "https://github.com/marmot-protocol/mdk", rev = "a2e0558a634bbd20607cdd5afb93abc6220ee58d"`;
`OPENMLS_GIT = git = "https://github.com/openmls/openmls.git", rev = "6100df3fb1d8c3eeab53e349fcbd621f98c44fe2"`.

### A.2 `haven-core/Cargo.toml` (line numbers at H)

| Line | Today | Stage 1a |
|---|---|---|
| 45 | `nostr = { version = "0.44", features = ["std", "nip44"] }` | `nostr = { NOSTR_GIT, default-features = false, features = ["std", "os-rng", "nip59"] }` — `os-rng` for `Keys::generate` / `SecretKey::generate` and the RNG-backed `nip44::encrypt` the tests call; `nip59` (implies `nip44`) for `giftwrap.rs`' `UnwrappedGift`, which today arrives only through nostr-sdk's feature that F removed |
| 47-69 | comment naming v0.10.4, `cgka-session` | dependency facts rewritten for v0.16.0 / `marmot-session` (semantic lines are 1b's) |
| 71 | `cgka-session = { git mdk, rev fcc85edd }` | `marmot-session = { MDK_GIT }` — 1b adds `features = ["test-support"]` (D1 exception) and its guard |
| 72-75, 79 | `cgka-engine`, `cgka-traits`, `storage-sqlite`, `transport-nostr-peeler`, `transport-nostr-adapter(features=["sdk"])` | same names, `MDK_GIT` |
| 100, 104, 281-282 | `rusqlite =0.40.1`, `libsqlite3-sys =0.38.1`, `[patch.crates-io]` | unchanged byte for byte (`M16 Cargo.toml:143,187-190`) |
| 116 | `nostr-sdk = { version = "0.44", default-features = false, features = ["nip44","nip59"] }` | `nostr-sdk = { NOSTR_GIT, default-features = false, features = ["ring", "rustls-tls-webpki-roots"] }` (§A.3) |
| new | — | `async-wsocket = { version = "0.17", default-features = false, features = ["ring", "rustls-tls-webpki-roots", "socks"] }` for the header-less transport (§C.4); exactly nostr-sdk's own requirement, so it unifies (0.17.0 is already in the resolved graph) |
| new | — | `negentropy = "0.5"` (already in the graph) for the typed NIP-77 refusal (§B.3.5) |
| 149 | test-utils `tokio-tungstenite 0.26` | `0.28` (in the graph through `async-wsocket 0.17`) |
| 233 | dev `nostr-relay-builder = "0.44"` | **delete** |
| 252 | dev `nostr-sdk = { version = "0.44", … }` | `nostr-sdk = { NOSTR_GIT, default-features = false, features = ["ring", "rustls-tls-webpki-roots", "local-relay"] }` |
| new dev | — | `nostr-memory = { NOSTR_GIT }` (`MemoryDatabase` the e2e tests seed relays with, `F database/nostr-memory/src/lib.rs:28`) |
| 262-264 | dev openmls family at `erskingardner/openmls@59e7d3b` | `openmls = { OPENMLS_GIT, features = ["extensions-draft"] }`, `openmls_rust_crypto = { OPENMLS_GIT, features = ["extensions-draft"] }`, `openmls_basic_credential = { OPENMLS_GIT }` (mirrors `M16 Cargo.toml:58-61`) |
| 269 | dev `tokio-tungstenite 0.26` | `0.28` |

No direct `secp256k1` dependency: the Stage-0 `SecretKey::generate` refactor removed the last secp256k1 type names
(the trial's E0432 at `keys.rs:9`, `identity/keypair.rs:24`, `event.rs:271`); `event.rs` names
`nostr::event::Signature`.

### A.3 TLS and trust anchors (unchanged)

P44: `nostr-relay-pool` → `async-wsocket 0.13` → `tokio-tungstenite 0.26` with `rustls-tls-webpki-roots` hard-wired
(`async-wsocket-0.13.2/Cargo.toml:125-127`), ring provider. F: `nostr-sdk` `ring` + `rustls-tls-webpki-roots` →
`async-wsocket 0.17` → `tokio-tungstenite 0.28`, same `ring 0.17.14`, `rustls 0.23.x`, `webpki-roots 1.0.10`.
Declaring the features makes Haven's choice explicit (MDK enables nostr-sdk's defaults anyway,
`M16 Cargo.toml:135`). `grep -c aws-lc Cargo.lock` = 0 in every root still holds.

### A.4 Other roots

- **`haven/rust_builder/Cargo.toml`**: `:13` `nostr = { NOSTR_GIT, default-features = false, features = ["std"] }`;
  dev `:37` delete `nostr-relay-builder`; dev `:41` `nostr-sdk = { NOSTR_GIT, default-features = false, features =
  ["ring","rustls-tls-webpki-roots","local-relay"] }`. The "exact patch pin" comments now say the one-universe
  guarantee is the git rev, held by `check_lockfile_universe.sh`. `[patch]` unchanged.
- **`tooling/soak/Cargo.toml`**: `:46-49` → `nostr = { NOSTR_GIT, default-features = false, features =
  ["std","os-rng","nip59"] }`, `nostr-sdk = { NOSTR_GIT, …, "local-relay" }`, delete `nostr-relay-builder`,
  `nostr-database = "=0.44.0"` → `nostr-memory = { NOSTR_GIT }` (add `nostr-database = { NOSTR_GIT }` only if a
  trait import still needs it). `:77,82` → `MDK_GIT`; `:93-95` openmls → `OPENMLS_GIT` with MDK's features.
- **`tooling/e2e/local-relay/Cargo.toml`**: `nostr-relay-builder = "0.44"` → `nostr-sdk = { NOSTR_GIT,
  default-features = false, features = ["local-relay"] }` (+ `nostr-memory` if the binary seeds a database);
  `tokio-tungstenite` → `0.28`. Header comment: "the same git rev as the app, held by the universe guard". This
  crate is also the iOS-lane relay binary (`src/main.rs:43-50`), so §B.5's limit configuration is a CI-observable
  change listed in the PR.

### A.5 Lockfiles: minimal re-resolution

Never `cargo generate-lockfile` or a bare `cargo update` (that drifts `cc`, `log`, `tokio`, …). Per root, in this
order (`local-relay` first: haven-core and soak resolve it as a path dependency):

```bash
for r in tooling/e2e/local-relay haven-core haven/rust_builder tooling/soak; do
  (cd "$r" && cargo metadata --format-version 1 >/dev/null)   # resolves only changed requirements
done
```

If a requirement cannot be met by a locked version, run **one** `cargo update -p <crate>` for exactly that crate,
**in every root that needs it**, and record it. Known from the trial: `cargo update -p ctutils` (0.4.4 → 0.4.8,
RustCrypto 0.14). Haven's lock is **not** aligned to MDK's lock: MDK's lock is not a Haven build input, Haven's
resolution is newer for most shared crates, and the 11 older ones carry no known defect (registry crates stay
under `cargo audit`). No `--precise` raises are made.

**Expected deltas** (verified in the commit): gone — `cgka-session`, `nostr-relay-pool` (RUSTSEC-2026-0243),
`nostr-relay-builder` (RUSTSEC-2026-0237), `nostr 0.44.8`, `nostr-database 0.44.0`, `nostr-gossip 0.44.0`,
`instant` (RUSTSEC-2024-0384), `async-wsocket 0.13.2`, `tokio-tungstenite`/`tungstenite 0.26.2`, `secp256k1 0.29.1`;
new — `marmot-session`, `fs-private`, `media-store`, `nostr-memory 0.45.2`, `opaquerr`, `universal-time`,
`tokio-stream`, `btreecap`, `faster-hex`, `bitcoin-*`.

`--locked` in all six roots (the CI form):

```bash
for r in haven-core haven/rust_builder tooling/soak tooling/e2e/local-relay tooling/logscan tooling/e2e/local-blossom; do
  (cd "$r" && cargo metadata --locked --format-version 1 >/dev/null) || echo "UNLOCKED: $r"
done
```

### A.6 `scripts/ci/mdk_pins.env`

```sh
# The MDK release rev (v0.16.0).
HAVEN_MDK_REV=a2e0558a634bbd20607cdd5afb93abc6220ee58d
HAVEN_MDK_SOURCE="git+https://github.com/marmot-protocol/mdk?rev=${HAVEN_MDK_REV}#${HAVEN_MDK_REV}"

# Upstream OpenMLS main, exact-pinned by MDK v0.16.0 (Cargo.toml 50-61): draft-10
# last-resort encoding (#2133), RustCrypto 0.14 / HPKE 0.8 (#2249/#2261) and the
# 0.9.1/0.9.2 security fixes, which no OpenMLS release carries together yet
# (docs/MDK_UPSTREAM_TRACKER.md T-OPENMLS-UPSTREAM-MAIN).
HAVEN_OPENMLS_SOURCE="git+https://github.com/openmls/openmls.git?rev=6100df3fb1d8c3eeab53e349fcbd621f98c44fe2#6100df3fb1d8c3eeab53e349fcbd621f98c44fe2"

# The rust-nostr fork MDK v0.16.0 builds on (Cargo.toml 134-136). Version alone
# cannot tell it from crates.io 0.45.x, and another rev is another type universe
# (docs/MDK_UPSTREAM_TRACKER.md T-NOSTR-FORK).
HAVEN_NOSTR_REV=e93cc06b5624f06c21ecd8111a124176eb0c7589
HAVEN_NOSTR_SOURCE="git+https://github.com/erskingardner/rust-nostr?rev=${HAVEN_NOSTR_REV}#${HAVEN_NOSTR_REV}"
```

`HAVEN_NOSTR_SOURCE` replaces Stage 0's registry value (added in S0.10, read by S0.3 G3 and the shared source helper), so Stage 1 changes the pin explicitly.
`HAVEN_LIBSQLITE3_*` unchanged. The strings are exactly what Cargo writes (`M16 Cargo.lock`, `nostr 0.45.5`).

### A.7 Guard **values** (mechanisms are Stage 0's; X4–X6)

- **`check_lockfile_universe.sh`**: `DEPENDENT_ROOTS` gains `tooling/e2e/local-relay` with its own expected
  subset — the nostr family only: `nostr nostr-sdk nostr-database nostr-gossip nostr-memory async-wsocket
  tokio-tungstenite` (recorded from its resolved lock in step 12); MDK crate list `cgka-session` →
  `marmot-session`; `UNIVERSE` drops `nostr-relay-pool`, adds `nostr-memory async-wsocket tokio-tungstenite
  marmot-session fs-private media-store`; the nostr source check covers `nostr nostr-sdk nostr-database
  nostr-gossip nostr-memory` against `HAVEN_NOSTR_SOURCE`; any package named `nostr-relay-pool` or
  `nostr-relay-builder` in any root fails. Fixtures added to Stage 0's set: "the v0.16.0 shape passes",
  "`nostr-relay-builder` in local-relay's lock fails", "an abbreviated rev fails"; `SELF_TEST_FIXTURES` re-pinned
  by equality from Stage 0's count.
- **`check_mdk_supply_chain.sh`**: allowlist values `marmot-session cgka-engine cgka-traits storage-sqlite
  transport-nostr-peeler transport-nostr-adapter marmot-forensics fs-private media-store` (the set resolved at
  v0.16.0; 1b's extra forbid list is dropped, engineering A4); `ADAPTER_DEPS` → `async-trait async-wsocket base64
  cgka-traits futures hex nostr nostr-gossip nostr-sdk serde serde_json sha2 tokio tokio-socks tokio-tungstenite
  tokio-util tracing transport-nostr-peeler zeroize`; fixture `adapter-no-sdk` removes all six `sdk` deps;
  `--nostr-features` values: `nostr` = `alloc nip04 nip44 nip49 nip59 os-rng rand std`, `nostr-sdk` = `default
  local-relay ring rustls-tls-webpki-roots` (expected; re-recorded with `cargo tree -e features,no-dev` in step
  12). There is no "fork rev equals MDK's" check: one source per crate is already enforced
  by the universe guard, and the check would always fail in the toolchain-free repo-guards job.
- **`tooling/soak/tests/pool_constants.rs`** (X4): re-pointed in step 16.1 (§B.3.9), not in the pins step; in
  between it fails loudly ("pinned against nothing") and is in the red inventory.
- **`audit.yml`, `haven-core/.cargo/audit.toml`**: delete the stale ignores RUSTSEC-2024-0384, -2026-0387,
  -0330, -0331, -0097 (`check_audit_ignores_live.sh` fails otherwise) and the soak RUSTSEC-2026-0237 comment
  (`audit.yml:56-77`). Advisory blindness of git sources is recorded in T-NOSTR-FORK.

---

## B. API migration

### B.1 Paths and mechanical renames

Stage 0 lands the bilingual `nostr::` module paths (R3.k). Stage 1 rewrites only what exists at F alone:

| 0.44 path | Fork path |
|---|---|
| `nostr_sdk::{Client, ClientBuilder, ClientNotification}` | `nostr_sdk::client::…` |
| `nostr_sdk::{Relay, RelayOptions, RelayStatus, RelayCapabilities, SleepWhenIdle, SyncOptions, SyncDirection, SubscribeAutoCloseOptions, ReqExitPolicy, RelayNotification}` | `nostr_sdk::relay::…` |
| `nostr_sdk::pool::monitor::{Monitor, MonitorNotification}` | `nostr_sdk::monitor::…` |
| `nostr_sdk::pool::policy::{AdmitPolicy, AdmitStatus, PolicyError}` | `nostr_sdk::policy::{AdmitPolicy, AdmitStatus}`; error `nostr_sdk::error::Error` |
| `nostr_sdk::RelayPoolNotification` | `nostr_sdk::client::ClientNotification` (+ `nostr_sdk::NotificationUpdate`, `F nostr-sdk/src/lib.rs:28`) |
| `nostr_sdk::{ClientOptions, RelayPoolOptions, SubscribeOptions, RelayServiceFlags}` | removed (§B.3) |
| `nostr_relay_builder::{LocalRelay, RelayBuilder, MockRelay, prelude::*}` | `nostr_sdk::local_relay::{LocalRelay, LocalRelayBuilder, MockRelay, WritePolicy, QueryPolicy, WritePolicyResult, QueryPolicyResult}` (`F nostr-sdk/src/local_relay/{builder.rs:67,122,161-180,282, mock.rs:15}`) |
| `nostr_database::{MemoryDatabase, MemoryDatabaseOptions}` | `nostr_memory::MemoryDatabase::{builder().max_events(n).build(), unbounded(), bounded(n)}` |
| `nostr::JsonUtil` import | delete (`as_json`/`from_json` are inherent, `F nostr/src/util/json.rs:25-50`) |
| `nostr::util::BoxedFuture` | spell `Pin<Box<dyn Future<Output = T> + Send + 'a>>` |
| `SingleLetterTag::lowercase(Alphabet::H)` | `SingleLetterTag::LOWERCASE_H` (`F filter/single_letter.rs:80`; `_P` :104, `_D` :68, `_X` :128) |

Convention: explicit module paths, never `prelude::*` (`wildcard_imports` is pedantic; `nostr::prelude` is
`#[doc(hidden)]` with ambiguous glob re-exports, `F nostr/src/prelude.rs:7-10`). A scripted rewrite is safe for
path rows only; it lands as one commit with nothing else in it.

Behaviour-preserving renames, each compile-checked:

| 0.44 | Fork | Sites |
|---|---|---|
| `EventBuilder::sign_with_keys(&k)` | `FinalizeEvent::finalize(&k)` (`F nostr/src/event/builder.rs:45`) | 166 |
| `.sign(&signer).await` | `FinalizeEventAsync::finalize_async(&signer)` (`:58`) | 15 |
| `.build(pubkey)` | `FinalizeUnsignedEvent::finalize_unsigned(pubkey)` (`:31`) | ≈69 `.build(` hits, hand-checked |
| `EventBuilder::{text_note, metadata, delete, gift_wrap}` | `EventBuilder::new(Kind::…, …)` / templates `Metadata`, `EventDeletionRequest`, `GiftWrapBuilder` (`nips/nip59.rs:273`) | mostly tests; `giftwrap.rs:147` fixture → `transport_nostr_peeler::gift_wrap_rumor` (production's own path) |
| `Tag::custom(TagKind::…, v)`, `TagKind::h()` | `Tag::custom("h", v)` (`F event/tag/mod.rs:337-348`) | `profile/blossom.rs:342-343` (BUD-11 `x` tag) + tests |
| `as_standardized() == Some(TagStandard::Expiration(ts))` | `event.tags.expiration()` (`F event/tag/list.rs:152`) | `circle/manager.rs:12987-13190` tests, soak `forge.rs:400` |
| `EventId::all_zeros()` | `EventId::from_byte_array([0; 32])` (`event/id.rs:70-75`) | 12 |
| `RelayStatus` exhaustive matches | add `Shutdown` (`F relay/status.rs:69`) | `session.rs` |
| `force_remove_all_relays()` (deprecated at F) | `remove_all_relays().force()` (its exact body, `F client/mod.rs:454-461`) | `manager.rs:2306-2311` until §B.3.9 |

### B.2 Module inventory and the compile partition

Trial error counts are name-resolution only (209 in the lib; later phases hidden); Stage 0's path refactor
removes a large share. Partition for parallel engineers (§F.2):

| Partition | Files | Redesign items |
|---|---|---|
| **P-pool** | `relay/{verified,dial_witness,url_norm,manager,publishers,catchup,negentropy,types,scripted_relay,recording_front}.rs` | §B.3.2–3, B.3.5, B.3.8–9, §C |
| **P-live** | `relay/live_sync/*` (session 10.5 k lines, supervisor, processor, drive, router, repair, planes) | §B.3.1, B.3.4 |
| **P-fanout** | `relay/fanout.rs` (8.2 k), `relay/maintenance/*` | §B.3.6–7, §D (mechanical only before CP-T) |
| **P-misc** | `nostr/{keys,event,giftwrap}.rs`, `identity/*`, `circle/*`, `profile/*`, `util.rs`, `log_alias.rs` | renames only |
| **1b** | `nostr/mls/*` | 1b's part |
| **P-ffi / P-soak / P-relay** (step 14) | `haven/rust_builder/src/api.rs` (paths, `MockRelay`, FFI forged-event tests `:14210-14312`); `tooling/soak/src`; `tooling/e2e/local-relay/src` (`loopback.rs:41-86`, `main.rs:43-50`, `selftest.rs:90,130` → `LocalRelay::builder().addr(..).port(..).build()`, `F local_relay/builder.rs:609`) | §B.5 |
| **Tests** (step 14) | in-file `#[cfg(test)]` modules with their file; `haven-core/tests/` by family: forged/verify/fanout matrix/negentropy → P-pool and P-fanout; live-sync/catch-up/inbox/burst → P-live; profile/KP/circle/discovery → P-misc; MDK-session-heavy e2e → 1b | |

`api.rs` gets no FFI signature change from 1a, but its content hash follows the file (`check_generated_bridge_pinned.sh`
:15-18), so 1a's step-14 edits are covered by the one regeneration in step 17 (X12, §F).

### B.3 Redesign items — the sweep's mechanical port, then the semantic unit

Rule (R4.d): before CP-T every edit is the smallest change that compiles **and keeps today's behaviour**; every
behaviour change is a later red → green commit pair. Where keeping today's behaviour is impossible (no API), that is
said.

#### B.3.1 Notification streams (Rule 12 lag evidence)

Today `run_receiver` takes a `broadcast::Receiver<RelayPoolNotification>` (`H session.rs:1326`) and
`Err(RecvError::Lagged(_)) => processor.note_delivery_gap()` (`H supervisor.rs:556`). F's `Client::notifications()`
hides lag (`F client/mod.rs:197-226`); `notifications_with_gaps()` (`:240-270`) yields
`NotificationUpdate::{Notification, Lagged}` and subscribes eagerly at the call.

- **Sweep port (behaviour-preserving):** every consumer moves to `notifications_with_gaps()` —
  `Lagged { .. } => processor.note_delivery_gap()`, stream end ⇒ break (was `Closed`),
  `ClientNotification::Shutdown` ⇒ `Stop`; `notification_disposition` (`H supervisor.rs:225-236`) re-typed onto
  `ClientNotification` with the same arms. Taking the stream before `spawn_supervisor` keeps "receiver exists
  before the first REQ". The channel size is Haven's `POOL_NOTIF_CAP` (8192) through `verified_client` (F default
  4096, `F client/builder.rs:233`). Same move for `read_one_relays_answer`, the fanout listener (§B.3.6) and
  `manager.rs:2480,4345,4987,5286`. `Monitor::subscribe()` stays a `broadcast::Receiver` (`F monitor.rs:44`).
  Porting to the legacy `notifications()` would compile and silently drop the evidence, so it is not a mechanical
  port.
- **Semantic unit 16.1:** check 11 bans `.notifications()` in the three source trees (self-test fixture plants it).
- **Test:** S0.4d's `a_lagged_notification_stream_holds_every_owed_cursor` passes unchanged (its shape is
  Stage 0's: channel size 2; a test-utils gate holds the receiver loop before its first poll; ten events and an
  EOSE; a second stream the test takes, here `notifications_with_gaps()`, polled until it yields the EOSE after its
  own `Lagged`; then the product's first item is `Lagged`, the cursor does not advance and the floors stay owed).

#### B.3.2 `client.relay()` returns `Result<Option<Relay>>`

`H manager.rs:713` `if client.relay(url).await.is_ok() { continue; }` compiles at F and is always true for a
parseable URL (`F client/mod.rs:311-318`): `register_publish_relays` would register nothing, MDK would add every
target with SDK defaults, and targeted fetch / NEG would fail `read_disabled` (`F relay/inner.rs:1948-1958`).

- **Sweep port:** today's meaning is "the pool holds this relay", so every site becomes
  `matches!(client.relay(u).await, Ok(Some(_)))` / `let Ok(Some(relay)) = … else`. `.is_ok_and(|relay| …)` sites
  (`H session.rs:770, 4255`) take the same shape. Tests `manager.rs:4568,5840,6617` that assert `.is_err()` for a
  relay that is gone assert `Ok(None)`.
- **Semantic unit 16.1:** check 11 bans `.relay(…).await.is_ok()` / `.is_err()` in product code; new test
  `register_publish_relays_registers_a_relay_the_pool_does_not_hold` (afterwards `Ok(Some(_))`, READ|WRITE, and the
  behavioural option probes of §B.3.3).

#### B.3.3 Relay registration and options

- **Sweep port:** `publish_relay_options()` (`H manager.rs:292-298`) becomes a function over the `AddRelay` builder
  so client-composed options survive (fact 7): `.capabilities(READ | WRITE).ping(false).reconnect(false)
  .sleep_when_idle(SleepWhenIdle::Enabled { timeout: PUBLISH_POOL_IDLE_TIMEOUT })` (`F client/api/add.rs:38-127`);
  never `.opts(..)`. The "take PING back off" block (`H manager.rs:2488-2497`) and its `RelayServiceFlags` import
  are deleted: PING is not a capability and MDK touches only capabilities on a held relay
  (`M16 sdk_client.rs:5444,5453`). The read-lock-first `relay()` probe stays (the pool still holds the relays read
  lock across the OK wait, `F pool/mod.rs:494-541`). Engine pool (`build_engine_client`, `H session.rs:112-123`)
  keeps ping and never sleeps.
- **Semantic unit 16.1:** `admit_relay` (§C.3) refuses any relay `may_dial` refuses, including MDK's own adds
  (the residual race in which MDK adds a target Haven had not registered keeps SDK defaults until
  `pin_new_relay_retry_interval` re-adds it, `M16 sdk_client.rs:5271-5330`); checks 3–4 rewritten: the body of
  `fn publish_relay_options` carries `.ping(false)`, `.reconnect(false)`, `SleepWhenIdle::Enabled` and no `.opts(`;
  every `.add_relay(` in `manager.rs` goes through it.
- **Tests — behaviour, never a `Debug` rendering** (tests M11; `RelayOptions` fields are `pub(crate)` with no
  getters, `F relay/options.rs:33-48`). One helper, `assert_publish_options_behave(manager, front, url)`, drives
  the publish client through `RecordingFront` (extended to record WebSocket control frames) and asserts:
  1. **no keepalive:** the front withholds the `OK` for one published event until Haven's own ack window ends;
     the fork's pinger signals at connection start and the sender loop takes the stored signal at its first idle
     `select!` (fact 10), so ping-on would put a `Ping` frame on the wire inside that window; the front records
     none. Positive control in the same test: the engine client through the same front, whose `Ping` arrives and
     releases the withheld answer (event-driven, no sleep).
  2. **no reconnect:** the front drops the socket; the relay's status notification reaches `Terminated` (reconnect
     on would give `Disconnected`, `F relay/inner.rs:945-957`), and `dial_witness` records no further dial;
     control: the engine client reaches `Disconnected`.
  3. **capabilities:** `relay.capabilities()` is READ|WRITE (a public typed accessor).
  4. **sleeps when idle:** after the last send the status notification reaches `Sleeping` (F polls every
     `SLEEP_INTERVAL` = 60 s, `F relay/constants.rs:31`, so this probe runs once, in
     `the_publish_pool_sleeps_after_its_idle_window`, not in every caller of the helper).

  The helper is called by the rewritten `publish_relay_options_turn_ping_off`,
  `a_second_add_of_the_same_url_never_restores_ping`, `a_fanout_publish_never_leaves_its_target_pinging`,
  `fanout_client_relays_keep_haven_options_across_every_adapter_call` (`H manager.rs:4280,4316,5056,4522`) and by
  `mdk_never_removes_or_reconfigures_a_relay_haven_registered` (§D.3), after every MDK adapter call including a
  `PossiblyExposed` one. `a_targeted_fetch_on_the_publish_client_needs_the_read_flag` asserts the READ capability.

#### B.3.4 Subscription issue and re-issue under stable ids

Issue: `subscribe_with_id_to(urls, id, filter, opts)` → `client.subscribe(ReqTarget::manual(…)).with_id(id)`
(`F client/mod.rs:779`, `client/api/subscribe.rs:37-67`) → `Output<SubscriptionId>` (`success`/`failed` per relay,
as today). A fresh id per relay behaves as today.

- **Sweep port:** today's re-issue shape (`H session.rs:4238-4297`, `reanchor_silent_subscriptions`): one
  same-id `relay.subscribe(filters).with_id(id)`. At F this is refused for a still-registered id (fact 5) and lands
  in `Output.failed` as "the relay refused the REQ" — so S0.4c's `a_req_closed_rate_limited_is_reissued_and_delivers`
  and `a_silent_req_released_and_reissued_delivers` go red in the inventory. That is the intended red.
- **Semantic unit 16.6 (green):** Haven keeps the **same** subscription id and re-issues by
  unsubscribe-then-subscribe:

  ```
  let Ok(Some(relay)) = client.relay(&key.relay_url).await else { return };
  if relay.status() != Connected { return }
  if relay.subscription(&key.sub_id).await.is_some() {
      relay.unsubscribe(&key.sub_id).await;              // removes the registration, sends CLOSE
  }
  relay.subscribe(filters).with_id(key.sub_id.clone()).await   // registers, then sends REQ
  ```

  Wire effect: after a `Remove`-class CLOSED the relay sees today's frame (REQ only); after `rate-limited:` or for
  a silent live REQ it sees one CLOSE before the REQ. NIP-01 makes a same-id REQ replace the old one anyway and the
  new REQ asks from the floor's `since`, so nothing is lost; two queued frames, non-atomic, harmless for the same
  reason. A fresh id per issue was rejected: it rewrites the router, `RepairKey` and EOSE accounting keyed by
  `(relay, sub_id)` for no gain over the upstream API that already exists (T-REQ-REISSUE, §E). (S0.4c's tests assert delivery, not id
  equality, so they hold for this design.)
- **Tests:** the two S0.4c tests green; new `a_reissue_of_a_req_the_relay_still_holds_reaches_the_wire_from_the_floor`
  (live REQ, and after `rate-limited:`; the front shows CLOSE then REQ with the floor's `since`; outcome success;
  coverage not narrowed); `a_single_relays_reissue_keeps_the_buckets_other_relays_in_coverage` and
  `a_reissue_for_a_relay_that_is_down_is_not_made` (`H session.rs:8530`) unchanged.
- Haven keeps its notification-ordered EOSE accounting (Rule 12's stored-replay rule needs the ordering);
  `Relay::subscription_received_eose` (`F relay/mod.rs:211`) is unordered relative to the stream and is not adopted.
  T-POOL-QUEUED-ACCEPT's queueing is unchanged (`F relay/inner.rs:425-478`); `SubscribeCtx::cover`'s `connected()`
  check stays.
- **Pause:** a paused engine `disconnect`s; registrations persist and are restored on reconnect
  (`F relay/inner.rs:674-701`, `should_resubscribe`). Check 8 pins `pause_subscriptions`' body; that body is
  re-derived against F's restore rule in 16.6, judged by S0.9's "pause/resume" golden transcript.

#### B.3.5 NIP-77 on a `Relay` handle

`neg_remote_ids` (`H manager.rs:1983-2027`) used `client.pool().sync_targeted(…)`; `pool()` is private at F
(`F client/mod.rs:147-150`).

- **Sweep port (today's semantics):**

  ```
  let Ok(Some(relay)) = self.client.relay(url.as_str()).await else { return NegAnswer::Failed };
  if !relay.status().is_connected() { return NegAnswer::Failed }
  let opts = SyncOptions::new().initial_timeout(NEG_NEGOTIATION_WAIT)
              .direction(SyncDirection::Down).dry_run();               // F relay/options.rs:262-306
  match timeout_at(ends, relay.sync(filter).items(Vec::new()).opts(opts).with_outcomes()).await {
      Err(_elapsed)                     => NegAnswer::Failed,           // dropped future: F sends NEG-CLOSE
      Ok(Err(_preflight))               => NegAnswer::Failed,
      Ok(Ok(o)) if o.error.is_none()    => NegAnswer::from_remote(o.summary.remote),
      Ok(Ok(o))                         => NegAnswer::from_failure(&o.error.unwrap().to_string()),  // today's text rule
  }
  ```

  `Relay::sync` holds only the relay handle (`F relay/api/sync.rs:96-118`), so `neg_prepare`'s pool-read-lock
  rationale (`H manager.rs:1958-1960`) is rewritten; registration-before-session stays. Today's waits, batch and
  `< NEG_SET_LIMIT` saturation rule are kept.
- **Semantic unit 16.6:**
  - Classification by type (Rule 8): `Unsupported` iff `e.kind() == nostr_sdk::error::ErrorKind::Unsupported`
    (`negentropy_not_supported`, `F error.rs:215-217`) or `e.source()` downcasts to
    `negentropy::Error::UnsupportedProtocolVersion` (`F relay/api/sync.rs:672-673`); everything else `Failed`.
    `NEG_REFUSALS` (`H negentropy.rs:58-62`) and `from_failure(&str)` are deleted. Red:
    `a_nip77_refusal_is_classified_unsupported_by_type` (red if the text rule no longer matches F's wording, or by
    the guard ban on `NEG_REFUSALS`). Whether opaquerr generates the `kind()` accessor is UNVERIFIED (engineering
    §6); if it does not, the variant is matched through the public constructor's kind query F exposes, still never
    by text.
  - Constants (X7, owned here): MDK moved to 20 s / 5 s / 512 / `16_384 + 1` (`M16 sdk_client.rs:86-110`). Haven
    keeps `NEG_ROUTE_WAIT = 2 s`, `NEG_NEGOTIATION_WAIT = 500 ms`, `NEG_REPLAY_BATCH = 128` as **Haven's own**
    burst values (R6 default: MDK's longer waits are not copied into background bursts), documented in
    `negentropy.rs` against the burst's wall-time budget (`docs/POWER_EFFICIENCY_PLAN.md`); that comment gives no
    energy figure, or tags it `ESTIMATED` per `check_estimate_integrity.sh`. Haven adopts MDK's set-limit sentinel:
    filter `.limit(16_385)`, `Saturated` iff `remote.len() >= 16_385`, keep the 16 384 lowest. Red:
    `a_remote_set_of_exactly_the_limit_is_whole_and_one_more_is_saturated` (red under today's `<` rule for exactly
    16 384). 1b's C17 is deleted (X7).
  - Guard: `check_publish_client_no_subscription.sh` check 5 rewritten — every `.sync(` in `haven-core/src` is on a
    `Relay` handle and its chain carries `.items(Vec::new())` and `.dry_run()`; `Client::sync`, `sync_with`,
    `sync_targeted` are banned.
- **"Advertises nothing", re-specified** (tests M12). `a_negentropy_session_advertises_nothing_the_device_holds`
  (`H tests/negentropy_e2e.rs:440-520`) keeps its MDK-inventory seeding and adds what the fork actually reads: (a)
  before the pass, a fetch through the publish client takes in the circle's seeded events, so the client database
  has seen them; (b) premise assertion: the publish client's database answers `negentropy_items(filter)` with
  nothing (fact 9) — this goes red if the default database ever becomes item-capable, the case in which a missing
  `.items(Vec::new())` would leak; (c) **positive control** `a_negentropy_session_without_an_explicit_item_set_advertises_the_client_database`:
  a test-witness client built over a seeded `nostr_memory::MemoryDatabase`, running `Relay::sync` without
  `.items(..)` against the same `NegWire`, shows a `NEG-OPEN` that is not the empty set's `6100000200` — proving
  the wire assertion sees an advertisement when one happens. The product assertions (every `NEG-OPEN` is
  `6100000200`; no id or fingerprint in any `NEG-MSG`; by-id ask only to the reporting relay, with the circle's
  `#h`) are unchanged.

#### B.3.6 Haven's own sends and the fanout listener

`client.send_event_to(urls, &ev)` → `client.send_event(&ev).to(urls).ok_timeout(DEFAULT_TIMEOUT)`
(`F client/api/send_event.rs:155-236`) → `SendEventOutput` (`success`/`failed` per relay). This is the sweep port;
the rules below are part of it because each keeps today's behaviour:

- **Always `.to(..)`**: without it F broadcasts to every WRITE relay (`:420-432`) and MDK ORs WRITE onto every
  relay it touches. Guard (16.1, `check_publish_client_no_subscription.sh`): every `.send_event(` chain in
  `haven-core/src` carries `.to(`; `.broadcast()`, `.to_nip17()`, `.to_nip65()` banned. S0.9's golden transcripts
  make a missed `.to(..)` a behavioural red too.
- `.save_into_database(false)` explicitly on Haven's own sends (F defaults true, `:142`), so no consumer comes to
  depend on the seen-tracker marking Haven's own ids; MDK's path keeps its default.
- `failed` strings are relay-authored text (`F pool/mod.rs:536-538`): never logged or put in an FFI string (Rule
  15); `clock_skew::classify_clock_refusal` stays the one compare-only reader.
- `ok_timeout(DEFAULT_TIMEOUT)` is passed explicitly so the const-assert at `H manager.rs:214-221`
  (`LOCATION_ACK_WINDOW` 5 s, `PROFILE_PUBLISH_ACK_TIMEOUT` 6 s strictly below the pool's wait) compares Haven
  values, not an SDK default.

Fanout listener (`H fanout.rs:142,295-344`), sweep port: `relay.notifications_with_gaps()` taken before the MDK
call (eager, `F relay/mod.rs:281-301`), drained after it without waiting:
`loop { match tokio::task::unconstrained(stream.next()).now_or_never() { Some(Some(Notification(RelayNotification::Message{message}))) => …, Some(Some(Lagged{..})) => complete = false, Some(Some(_)) => {}, Some(None) => { complete = false; break }, None => break } }`.
`unconstrained` stops tokio's co-op budget from returning `Pending` on a ready item (which would under-count
refusals: safe, but proofs would become `PossiblyExposed`). The proof rule itself stays today's in the sweep and
changes in 16.2 (§D.1).

#### B.3.7 Publishers and maintenance

Paths, `finalize`, the send builder of §B.3.6. KeyPackage: `NostrKeyPackagePublication::to_event_at(..)
.finalize(&keys)` (MDK does the same, `M16 transport-nostr-peeler/src/event.rs:659`). Event id and serialisation are
unchanged (`F nostr/src/event/id.rs:42-53` = P44). F no longer strips self-tags, and no Haven production builder
tags its own signer (every `Tag::public_key(` in H is under `#[cfg(test)]`, signed by other keys).

#### B.3.8 Targeted fetch

`read_one_relays_answer` (`H manager.rs:2122`) hand-rolls an auto-closing REQ, a notification loop, a manual
CLOSE on early exit, an arrival-counted intake cap, dedup and sort.

- **Sweep port:** the same loop over `relay.notifications_with_gaps()` (a lag ends the read not drained, as a
  broadcast lag does today); the manual CLOSE stays.
- **Semantic unit 16.6:** replaced by `Client::acquire_events(ReqTarget::single(url, [filter]),
  AcquisitionLimits::new(1, cap, bytes, timeout))` (`F client/api/acquire_events.rs:84`,
  `relay/api/acquire_events.rs:30-113`; MDK uses it, `M16 transport-nostr-adapter/src/acquisition.rs`). Its events
  pass `admit_event` before anything else (`F relay/inner.rs:1712-1720`), so Rule 16 holds on this path. Mapping:
  drained ⇔ `Completed`; every other `AcquisitionEnd` — `ExitLimitReached`, `ItemBudgetExceeded`,
  `ByteBudgetExceeded`, **`Cancelled`**, `TimedOut`, `Disconnected`, `ReceiveLoss(n)`, `RelayClosed(String)`,
  `Rejected(String)`, `Failed(Error)` (`:84-110`) — not drained. The string variants are matched by variant and
  the string dropped unread (Rule 15). Haven keeps its own dedup and newest-first / lower-id sort. The gate is
  S0.4d's `targeted_fetch_end_shapes.rs`, **unchanged**, passing on the new reader (no dual-reader parity harness, engineering
  M10). `raw_received_items` / `oldest_raw_created_at` are counted before verification (`F relay/inner.rs:1591-1606`)
  and are never read: check 11 bans `raw_received` / `oldest_raw` in Haven sources.
- `fetch_events_from(urls, filter, timeout)` (7 sites) → `client.fetch_events(ReqTarget::manual(..)).timeout(t)`
  (`F client/api/fetch_events.rs:17-100`), `.with_outcomes()` where completeness matters; this is a sweep port.

#### B.3.9 Shutdown, wedge recovery, connect timeouts, SDK-derived constants

- **Wedge detector — removed in the sweep, the one forced exception.** `recover_wedged_publish_sockets` /
  `terminate_wedged_socket` (`H manager.rs:352-405`) read `relay.queue()`, which F does not have (fact 4); no
  compiling port keeps it. It is deleted with its test
  `the_recovery_terminates_a_real_socket_that_holds_an_unread_message`; the promise tests in §E's
  T-POOL-TERMINATE-PERMIT row judge the result in the red inventory.
- **Semantic unit 16.6:** `RelayManager::shutdown` (`H manager.rs:2309`) becomes `self.client.disconnect().await`
  only; the drop after `PossiblyExposed` (`H manager.rs:2505-2509`) is deleted;
  `rule13_a_burst_never_pauses_with_a_pending_publish_outstanding` (pins the body) is re-pinned in the same commit.
- **Connect timeouts.** Sweep port: `verified_client` sets `connect_timeout` explicitly to the value each pool
  effectively has today (engine 60 s, 0.44's `DEFAULT_CONNECTION_TIMEOUT`; publish pool Haven's
  `CONNECTION_TIMEOUT`), so no bound moves in the sweep. **Semantic unit 16.1:** the engine moves to F's 15 s as a
  Haven constant `ENGINE_CONNECT_TIMEOUT` (the future-facing value: upstream's default, named in Haven so no bound
  depends on an SDK default). Consequences, all in the same commit pair: T-POOL-QUEUED-ACCEPT's grace becomes 15 s
  (`F relay/inner.rs:425-461`); soak `pool_reconnect()` (`tooling/soak/src/oracle/bounds.rs:65-84`) becomes
  `MAX_RETRY_INTERVAL (60) + max(JITTER_RANGE) (3) + ENGINE_CONNECT_TIMEOUT (15)` = **78 s** (was 123 s);
  `pool_constants.rs` (X4) is re-pointed to read `nostr-sdk/src/relay/constants.rs` from the package whose source is
  `HAVEN_NOSTR_SOURCE` (`MAX_RETRY_INTERVAL` 60 s :16, `JITTER_RANGE` −3..=3 :17) and `ENGINE_CONNECT_TIMEOUT`
  from haven-core; every bound derived from 123 s (soak liveness, the `e2e-network-reconnect.yml:41` comment,
  `haven/lib/src/constants/location.dart` / `service_providers.dart` citations) is re-derived. Red: the re-pointed
  `pool_constants.rs` (the old package is absent).
- `rebuild_stalled_relays` (`H session.rs:2404-2490`) is kept and ported mechanically. F keeps a connect issued
  while the old task stops (`F relay/inner.rs:823-829,1004-1015`, `10a84d96`, `514f4050`), so it is recorded in
  T-POOL-TERMINATE-PERMIT as the next removal candidate, with removal condition "a Haven-seam test shows a stalled
  relay reachable again within the bound with the rebuild deleted".
- Other SDK constants re-cited to F (`relay/constants.rs`): ping 55 s (:27, engine only), retry 10 s → 60 s
  adaptive ±3 s (:13,16,17), NIP-77 frame limit 60 000 (:19), message size 5 MiB (:11), relay notification channel
  2048 (:5), `MIN_ATTEMPTS`/`MIN_SUCCESS_RATE` (:24-25). `SECURITY.md:4973` (`PING_INTERVAL`) re-pointed.

### B.4 Timestamps

`nostr::Timestamp::now()` (`F nostr/src/types/time.rs:45`) is unchanged in meaning. The NIP-40 expiry drop still
runs on the device clock before verification (`F relay/inner.rs:1704-1707`; `Event::is_expired`,
`F nostr/src/event/mod.rs:237-255`) — T-NIP40-POOL unchanged.

### B.5 Test relays and fixtures

- `nostr_relay_builder::{LocalRelay::new(RelayBuilder…), MockRelay}` → `nostr_sdk::local_relay::{LocalRelay::builder()…build(),
  LocalRelay::new(), MockRelay::run()}`; `PolicyResult` → `WritePolicyResult` / `QueryPolicyResult` over
  `(&Event, &SocketAddr)` / `(&mut Filter, &SocketAddr)` (`F local_relay/builder.rs:67-180`).
- **F's local relay has default limits** (`F local_relay/builder.rs:21-29,333-375`): 1 200 queries/min, 6 000
  messages/min, **60 notes/min**, 20 filters/REQ, **`max_filter_limit: 500`**, **64 KiB max event**, 1 MiB
  subscription bytes, 50 000 negentropy items, 10 negentropy subs, kinds 13/9734/22242/24242/27235 blacklisted,
  expired events refused on write and filtered on query (`local/inner.rs:593,1414`). One helper,
  `haven_core::relay::test_relay::builder()` (test-utils), sets every limit Haven's tests rely on explicitly
  (filter limit ≥ 16 385, write rate unbounded for soak, negentropy items ≥ 16 385, max event size above the
  largest event any arm produces, blacklist empty unless a test opts in). `tooling/e2e/local-relay` cannot depend
  on haven-core and holds the same values; a haven-core test (which has `haven-local-relay` as a dev path
  dependency) asserts the two sets are equal. No assertion is loosened; a test or lane that goes red for a relay
  limit gets the limit configured. The iOS-lane binary uses the same configuration (listed in the PR).
- `MemoryDatabase::with_opts(..)` → `nostr_memory::MemoryDatabase::builder().max_events(n).build()` (soak
  `relay/mod.rs:39,80,162,273,430`; tests `{refused_backlog,key_package_discovery,forged_group_event,resource_refused,commit_before_proposal}_e2e.rs`).
- `scripted_relay.rs`, `recording_front.rs`, soak `relay/proxy.rs`, `local-relay/src/proxy.rs`: tokio-tungstenite
  0.26 → 0.28 (message text/bytes types; `accept_hdr_async` shape UNVERIFIED in detail, compile-guided).
- S22's header (`tooling/soak/src/scenarios/s22_oversized_event.rs:13`) says `nostr-relay-builder` has no
  event-size knob; F's builder has one. The rig sets it above everything and keeps arming its measured synthetic
  cap through its own policy, so the arm's variable is unchanged; the sentence is rewritten (and §C.8.5).
- Test witnesses (`check_engine_client_options.sh` `TEST_WITNESS_FILES`): test clients keep their `// test witness`
  markers; counts re-pinned.

---

## C. Security Rule 16 on the fork (D4: Haven keeps its own `verify()`)

The security review re-verified §C.1–C.4 against source.

### C.1 Inbound path at F

`handle_event_msg` (`F nostr-sdk/src/relay/inner.rs:1585`): size/tag limits → optional `verify_subscriptions` →
NIP-40 expiry drop (`:1705`) → `state.verify_and_cache(&event)` (`:1710`; id recomputed, then a cache bound to the
signature, `F shared.rs:73-102`) → **`admit_event`** (`:1713-1720`; `Rejected` ⇒ `Ok(None)`, no notification) →
`check_id` / `save_event` → first-seen `RelayNotification::Event` (`:1723-1760`) → gossip only if configured
(`:1765-1772`) → `RelayNotification::Message` for every delivery (`:1496-1502`). Acquisition frames pass
`admit_event` too. Haven's policy therefore still runs before the pool stores, de-duplicates by id or notifies
anything. `MemoryEventsTracker` never answers `Deleted` (`F events_tracker.rs:44-71`), so a signed kind-5 from a
hostile relay cannot suppress a genuine id pool-wide. A forged frame ends in `tracing::error!` (`:1505-1511`),
harmless while no subscriber exists (`check_no_tracing_sink.sh`).

### C.2 `verified_client` — exhaustive destructure and literal (semantic unit 16.1)

```rust
pub fn verified_client(monitor: Option<Monitor>, channel: NonZeroUsize, connect_timeout: Duration) -> Client {
    // Exhaustive: a field the pinned fork adds is a compile error here until it is decided.
    let ClientBuilder {
        websocket_transport: _, admit_policy: _, authenticator: _, database, gossip: _,
        gossip_config, monitor: _, proxy: _, max_relays: _, notification_channel_size: _,
        connect_timeout: _, relay_limits, max_avg_latency, sleep_when_idle,
        verify_subscriptions: _, ban_relay_on_mismatch: _,
    } = ClientBuilder::default();
    ClientBuilder {
        websocket_transport: Arc::new(HeaderlessTransport),          // §C.4
        admit_policy: Some(Arc::new(VerifiedEvents)),
        authenticator: None,                                         // no NIP-42 answer, ever
        database,                                                    // F's id-only tracker
        gossip: None,                                                // no gossip store
        gossip_config,
        monitor,
        proxy: None,
        max_relays: None,
        notification_channel_size: channel,
        connect_timeout,
        relay_limits, max_avg_latency, sleep_when_idle,
        verify_subscriptions: false,                                 // redundant with plane_wants_event; a second, silent drop path
        ban_relay_on_mismatch: false,
    }
    .build()
}
```

All 16 fields are `pub` and the struct is not `#[non_exhaustive]` (`F client/builder.rs:175-238`), so this compiles
and turns every fork bump that adds a field into a decision. `MemoryEventsTracker` is private (`F lib.rs:10`), so
`database` is taken from `ClientBuilder::default()`. There is no post-build authenticator setter on `Client` or
`Relay`; `RelayPool` is `pub(crate)`. Callers: `RelayManager::new` (`None`, 4096, Haven's `CONNECTION_TIMEOUT`),
`build_engine_client` (`Some(Monitor::new(64))`, `POOL_NOTIF_CAP`, `ENGINE_CONNECT_TIMEOUT`).

The sweep port before 16.1 is the fork builder with today's settings (admission policy with `admit_event` only, no
authenticator, no gossip, default transport, `verify_subscriptions(false)`, today's timeouts); its default
transport sends the `user-agent`, so S0.4b's test is red in the inventory until 16.1.

### C.3 `VerifiedEvents` hooks (`F nostr-sdk/src/policy.rs:47-95`)

| Hook | Called at | Haven returns |
|---|---|---|
| `admit_event(url, sub_id, event)` | `F relay/inner.rs:1713` | `event.verify().is_ok()` ? `Success` : `Rejected { reason: None }` (D4) |
| `admit_auth(url)` | `F relay/inner.rs:1962-1973`, before any authenticator | **always `Rejected { reason: None }`** — a structural second lock behind `authenticator: None` (with no authenticator F never queues a challenge, `:1491`) |
| `admit_relay(url)` | `F pool/mod.rs:169-182`, every `add_relay` incl. MDK's | `may_dial(url)` ? `Success` : `Rejected { reason: None }`. A refusal returns `Ok(false)`; MDK's `retain_publish_relay` then reports `RetryableUnavailable "connect relay failed"` (`M16 sdk_client.rs:5522-5527`), so Haven's own `NotExposed` pre-check (`H manager.rs:2468-2471`) stays the primary gate — a pool refusal must not look like an outage |
| `admit_connection(url)` | `F relay/inner.rs:748-752` (task loop `:891`, `try_connect.rs:70`) | under `cfg(any(test, feature = "test-utils"))` `dial_witness::note(url)` first, then `may_dial(url)` — every dial passes this hook, so the witness sees every dial |

Every hook returns no reason (Rule 15) and logs nothing; the struct stays field-less. Signature per fact 8.

### C.4 The `user-agent` header (O12)

F's `DefaultWebsocketTransport` inserts `user-agent: nostr-sdk/0.45.4`; `async_wsocket::WebSocket::connect(url, &mode)`
sends no extra headers (`async-wsocket-0.17.0/src/native/mod.rs:28-30`). Haven supplies `HeaderlessTransport`
through the public `ClientBuilder.websocket_transport` (`F transport/websocket.rs:58-70`): `support_ping() = true`;
`connect` maps `proxy` exactly as F's default does and calls `WebSocket::connect`; the sink is wrapped by a copy of
F's private `TransportSink` adapter (`F transport/websocket.rs:113-130`) mapping errors with the public
`nostr_sdk::error::Error::transport` — **never `sink_map_err`**, which F warns may panic (`:113-115`, rust-nostr
#984). The stream is `rx.map_err(Error::transport)`. TLS roots and URL policy are unaffected (policy runs in the
admission hooks before the transport is called; F has no other HTTP path). This mirrors the default minus one
header because upstream offers no option to omit it (T-WS-USER-AGENT, with that upstream ask). `SECURITY.md:5149-5154`
is rewritten to "no `User-Agent` is sent; pinned by `no_relay_socket_sends_a_user_agent`".

**Tests (X9):** S0.4b's `no_relay_socket_sends_a_user_agent` (header-name set per connection for the publish
client, the engine client and the NEG pass; `user-agent` absent) is red in the inventory and green after 16.1
unchanged. 1a adds only its control: a test-witness client built with `DefaultWebsocketTransport` through the same
`RecordingFront` shows `user-agent` in its header names, so the capture can see the header.

### C.5 No gossip, no authenticator, no manual AUTH, no relay server in shipped code

Guarantees: (1) the exhaustive literal sets `gossip: None`, `authenticator: None`; (2) check 11 (§C.6) bans every
other spelling, manual NIP-42 frames included; (3) relay *servers* are kept out of shipped code at compile level:
`haven-core/clippy.toml` and `haven/rust_builder/clippy.toml` gain `disallowed-types` entries for
`nostr_sdk::local_relay::{LocalRelay, LocalRelayBuilder, MockRelay}` (T-SDK-SHIPPED-FEATURES compiles a WebSocket
relay server into the shipped library through MDK's feature); every test module that uses them carries
`#[allow(clippy::disallowed_types)]` on its `mod` item (as MDK's `sdk_client.rs` does for
`disallowed_methods`), and check 11 asserts each such `allow` sits directly under a `#[cfg(test)]` or
`#[cfg(any(test, feature = "test-utils"))]` attribute.

Behaviour tests:

- **NIP-42 (X10):** S0.4a's test (scripted challenge, `require_auth`, `auths() == 0` on the publish client, the
  engine and the NEG pass). At Stage 1 only its control client is respelled:
  `Client::builder().authenticator(SignerAuthenticator::new(keys)).build()` (a test-witness client in `tests/`;
  `F authenticator.rs:23-60`), which must still obtain the stored event with `auths() ≥ 1`. No separate
  `LocalRelay` NIP-42 test is written.
- **No gossip store:** `a_verified_client_has_no_gossip_store` (16.1) — `client.send_event(&ev).to_nip65().await`
  on each client `verified_client` builds fails (`gossip not configured`, `F client/api/send_event.rs:410-414`)
  and the recording front sees no frame. Its positive control: a test-witness client with a gossip store does
  send. (Stage 0's S0.6 fences the existing absence window in `live_sync_privacy_config_e2e.rs:368-385`.)
- `verified.rs` tests: `the_policy_admits_a_genuine_event_and_refuses_every_forgery_of_it` and
  `the_verified_client_drops_the_forgery_and_keeps_the_genuine_event_behind_it` keep their assertions (fixtures use
  `nostr::event::Signature`, `Keys::sign_schnorr`, `F nostr/src/key/mod.rs:180`).
  `a_pool_client_without_the_policy_hands_back_a_forgery_of_an_id_it_has_seen` **goes red at F** (the fork closed
  the hole) and becomes `a_pool_client_without_the_policy_refuses_every_forgery_of_an_id_it_has_seen` (a
  policy-less test-witness client, `[genuine]` for all six shapes), which pins the fork's fix and re-runs at every
  fork bump. `the_constructor_hands_on_the_callers_options_and_monitor` → monitor present/absent and channel size
  observed. The old `a_client_built_here_never_answers_a_nip42_challenge_whatever_it_was_asked`
  (`H verified.rs:98-106`, reads `pool().state()`) no longer compiles and is superseded by S0.4a's test.

### C.6 Check 11 rewrite (`scripts/ci/check_engine_client_options.sh:793-…`, semantic unit 16.1)

| Class | Spellings at F / M16 | Rule |
|---|---|---|
| Client construction | `Client::new`, `Client::default`, `Client::builder`, `ClientBuilder::new`, `ClientBuilder::default`, `ClientBuilder {` literal, `<Client>::` / `<ClientBuilder>::` (`F client/mod.rs:76-106`, `client/builder.rs:214-243`) | only inside `verified_client` (one literal + one `ClientBuilder::default()` destructure) and witness lines |
| Standalone relay | `Relay::new`, `Relay::builder`, `RelayBuilder::new`, `RelayBuilder {` (client-side, `F relay/mod.rs:144-150`, `relay/builder.rs:17-126`) | banned outside witnesses |
| Authenticator | `.authenticator(`, `authenticator:` other than `authenticator: None` in `verified_client`, `.authenticator =`, `Authenticator` trait / `impl … for`, `SignerAuthenticator`, `make_auth_event` (`F authenticator.rs:12-69`, `client/builder.rs:290`, `relay/builder.rs:102`); MDK `NostrSdkRelayClient::with_account_signer`, `.register_account(` (`M16 sdk_client.rs:2372-2433`) | banned except the one `authenticator: None` |
| Manual NIP-42 frame | `ClientMessage::Auth`, `ClientMessage::auth(`, `EventBuilder::auth(`, `Kind::Authentication` | banned in the three trees (none today) |
| Gossip | `.gossip(`, `gossip:` other than `gossip: None`, `.gossip =`, `IntoNostrGossip`, `NostrGossip`, `nostr_gossip::`, `add_gossip_relay`, `RelayCapabilities::GOSSIP` | banned except the one `gossip: None` |
| Transport | `.websocket_transport(`, `.websocket_transport =`, `websocket_transport:` other than `Arc::new(HeaderlessTransport)`, `impl WebSocketTransport for` other than `HeaderlessTransport` in `verified.rs`, `IntoWebSocketTransport`, `DefaultWebsocketTransport` | one transport, in `verified.rs` |
| Policy | `.admit_policy(`, `.admit_policy =`, `admit_policy:` other than `Some(Arc::new(VerifiedEvents))`, `impl AdmitPolicy for` outside `verified.rs` (+ witnesses) | one policy |
| Database | `database:` other than the destructured passthrough | as today |
| MDK client constructors | `NostrSdkRelayClient::new(self.client.clone())` exactly once in `fn fanout_transport` (kept); `NostrSdkRelayClient::{from_builder, from_builder_with_liveness, new_with_liveness, multi_account, with_account_signer}`, `.register_account(`, `transport_nostr_adapter::network_proxy`, `nostr_builder(`, `socks5_proxy(` (`M16 sdk_client.rs:2312-2537`, `network_proxy.rs:39-140`) | banned |
| Legacy stream | `.notifications()` | banned (§B.3.1) |
| Relay lookup | `.relay(…).await.is_ok()` / `.is_err()` | banned (§B.3.2) |
| Acquisition raw evidence | `raw_received`, `oldest_raw` | banned (§B.3.8) |
| Relay-server allow | `allow(clippy::disallowed_types)` not directly under a test cfg | banned (§C.5) |
| `verified_client` body | contains `admit_policy:Some(Arc::new(VerifiedEvents))`, `authenticator:None`, `gossip:None`, `websocket_transport:Arc::new(HeaderlessTransport)`, `verify_subscriptions:false`, `let ClientBuilder{` with no `..` | each its own message |
| `VerifiedEvents` | `admit_event` calls `event.verify()` and neither `verify_signature` nor `verify_id`; `admit_auth` returns `Rejected{reason:None}` unconditionally; `admit_relay` / `admit_connection` call `may_dial`; no `log::` / `tracing::` / `reason:Some` / `AdmitStatus::rejected(` | |

Deleted clauses: `set_signer|unset_signer|.signer(|::signer` and `automatic_authentication(` — no such API at F
(`grep F nostr-sdk/src` = 0), so they could never fail. Residual kept in the rule text: a text scan cannot see a
`Default` the compiler infers or a struct built through a macro, and does not read `tests/`.

Self-test: one mutation fixture per row (each spelling planted in a fixture tree, run through the script itself with
`REPO_ROOT_OVERRIDE`, never re-evaluated in Rust), plus "the v0.16.0 tree shape passes", "`authenticator: Some(..)`
in `verified_client` fails", "a second `impl WebSocketTransport` fails", "`.opts(` in `publish_relay_options`
fails", "a `ClientBuilder {..}` with `..Default::default()` fails". The signer/auth fixtures go.
`SELF_TEST_FIXTURES` is re-pinned by equality.

Check 7 is rewritten for F's builder: every `.subscribe(` in `manager.rs` is an auto-closing acquisition/fetch, every
standing REQ lives in `live_sync/session.rs`. `check_publish_client_no_subscription.sh` checks 1–2 add MDK's
subscription-plane entry points (`acquire_history`, `reconnect_relay`, `sync_liveness_config`, `notifications`,
`SdkSweepRelay`, `dispatch_sdk_replay`; `M16 transport-nostr-adapter/src/lib.rs:107-113`).

### C.7 Rule 16 text and the facts for the docs editor

**Replacement for CLAUDE.md Security Rule 16** (1a's text, X15; guarantees unchanged, API names and fork facts
updated):

> 16. **Relay Events Are Verified By Haven**: every relay client in shipped code is built by `haven-core/src/relay/verified.rs` `verified_client`, from an exhaustively destructured `nostr_sdk::client::ClientBuilder` (a field the pinned fork adds is a compile error until decided) with exactly: Haven's admission policy `VerifiedEvents`, whose `admit_event` calls `Event::verify()` — id AND signature — on every relay `EVENT` before the pool stores it, de-duplicates it by id or notifies anything, as a standing guard independent of the SDK's own check (the pinned fork recomputes the id and binds its verification cache to the signature; Haven does not rest this rule on a personal fork), whose `admit_auth` refuses every NIP-42 authentication and whose `admit_relay` / `admit_connection` refuse every relay `relay::url_norm::may_dial` refuses; `authenticator: None`; `gossip: None`; and Haven's `HeaderlessTransport`, which sends no `user-agent`. NEVER construct a `Client`, `ClientBuilder`, `Relay` or `RelayBuilder` anywhere else (a test's own client carries a trailing `// test witness`, in the files check 11 lists); NEVER install an `Authenticator` (with one the pool answers a relay's NIP-42 challenge, binding the identity key to group traffic), build a NIP-42 `AUTH` message, install a gossip store, a second admission policy or another WebSocket transport; NEVER use a relay server (`LocalRelay`, `MockRelay`) outside test code (`disallowed-types` in both shipped roots' `clippy.toml`); NEVER read relay events through the lag-hiding `notifications()` stream (Rule 12); NEVER hand MDK's `NostrSdkRelayClient` any client but the publish client or call its client-building or signer-installing constructors (`from_builder`, `multi_account`, `with_account_signer`, `register_account`) — one site, `RelayManager::fanout_transport`, check 11; NEVER call its subscription half (`scripts/ci/check_publish_client_no_subscription.sh`); and at every MDK bump `NostrSdkRelayClient::new`, its opaque publish arm and `network_proxy.rs` are re-read (`mdks_relay_client_builds_no_client_and_installs_nothing_on_the_one_it_is_handed`), as is its in-call retry rule (`mdks_publish_loop_returns_terminal_at_once_and_carries_earlier_ambiguity`). NEVER replace `verify()` with `verify_signature()` or `verify_id()`, NEVER move the check to after an id-keyed de-duplication, and NEVER pass a kind-444 Welcome rumor to it (Rule 3). A NIP-77 session carries no event and runs on a `Relay` handle with an explicitly empty item set; every event a pass leads to is fetched by id on the publish client and passes `verify()` like any other. Judging an id the screen refused before authentication as final for its route (Rule 12) rests on `verify()` binding the id to the bytes (`T-NIP77-DRIVER`). The policy logs nothing and gives no reason (Rule 15); a forged event is dropped as if withheld, and the relay that sent it is not banned. Verification proves authorship, not freshness: [the existing kind-0/10002/10050 freshness sentence, unchanged]. Guarded by `scripts/ci/check_engine_client_options.sh` check 11 — a text scan that does not read `tests/` and cannot see a `Default` the compiler infers; tracker `T-POOL-VERIFY-CACHE` (standing guard), `T-FORGED-COPY-SEEN`, `T-NOSTR-FORK`, `T-WS-USER-AGENT`.

**Facts supplied to the docs editor (1b, master step 18):**

- CLAUDE.md "Relay clients": MDK's relay client builds no client on the `new(client)` path Haven uses (its other
  constructors do and are banned); NIP-77 runs only as Haven's own dry-run NEG on a `Relay` handle of the publish
  pool with `.items(Vec::new())` (`check_publish_client_no_subscription.sh` check 5).
- CLAUDE.md "Relay URLs": `may_dial` is `wss` to any host **except a `.onion` name** (§C.9), plus the debug
  loopback `ws` opt-in.
- CLAUDE.md "MDK pinning": crate list with `marmot-session`; OpenMLS upstream `openmls/openmls@6100df3…`; the
  rust-nostr fork rev; `nostr` / `nostr-sdk` feature sets held by `--nostr-features`.
- CLAUDE.md `test-utils` bullet: `relay::dial_witness` is noted by `admit_connection`, which then applies `may_dial`.
- `haven-core/SECURITY.md`: `:24` (RUSTSEC-2026-0237 → historical), `:41`, `:76-79`, `:101-105` (0.44 advisory
  history kept, marked superseded), `:341` (fork facts + standing guard), `:444-448` (signer /
  `automatic_authentication` → authenticator / `admit_auth`), `:4309` (NIP-40 drop point → F), `:4973`
  (`PING_INTERVAL` → `F relay/constants.rs:27`), `:5037` (`automatic_authentication(false)` → `authenticator: None` +
  `admit_auth`), `:5149-5154` (user-agent, §C.4), `:5188` (termination permit → fixed at F); a new paragraph for
  §C.8 (oversized Welcome).

### C.8 The oversized-Welcome refusal (R4.a, O13)

**C.8.1 The promise and why the fork breaks it.** Today a Welcome is refused on the device when the plaintext of
either NIP-59 layer exceeds 65 408 bytes (`MAX_SUPPORTED_PLAINTEXT_SIZE` = 65 536 − 128,
`nostr-0.44.8/src/nips/nip44/v2.rs:35`), which P44's `pad` refuses (`:334-336`). The two plaintexts are the rumor's
JSON, which the Welcome signer's `nip44_encrypt` turns into the seal's content (`nostr-0.44.8/src/nips/nip59.rs:159`),
and the signed seal's JSON, which `EventBuilder::gift_wrap_from_seal` encrypts under a one-time key
(`nostr-0.44.8/src/event/builder.rs:1496-1501`). Nothing else in the chain refuses on size. MDK's peeler maps the
refusal to `PeelerError::WrapFailed("NIP-59 gift wrap: …")` (`M10 transport-nostr-peeler/src/peeler.rs:360-362`),
and the add or create fails before any Welcome is sent. At F nothing in the chain refuses: F's `nip44::encrypt`
takes up to `u32::MAX` bytes (fact 1), MDK's `gift_wrap_rumor` calls `GiftWrapBuilder` directly
(`M16 transport-nostr-peeler/src/nip59.rs:18-27`), and `NostrMlsPeeler::wrap_welcome_with_metadata` validates only
the AAD, emptiness and the relays tag (`M16 peeler.rs:486-531`); MDK's own test wraps a ≈55 KB Welcome with
extended prefixes on both layers (`:1287-1338`). MDK's `WelcomeSizeCheck` (`M16 traits/src/transport_adapter.rs:1477-1486`,
mdk#2334) judges founding Welcomes against known *relay* event limits and runs only on creates
(`M16 cgka-engine/src/group_lifecycle.rs:861-869`); it does not express receiver compatibility. A v0.1.13 device
(P44) cannot decode an extended-prefix payload, so a new-build admin inviting into a large circle would send a
Welcome the invitee cannot open.

**C.8.2 The rule, and where it is enforced.** Haven refuses **exactly** what P44's encoder refuses today: a Welcome
is refused iff the rumor's JSON or the signed seal's JSON is longer than `LEGACY_NIP44_MAX_PLAINTEXT = 65_408`
bytes. At F the same two strings are produced at the same two points: the seal layer calls the signer's
`nip44_encrypt` with `rumor.as_json()` (`F nostr/src/nips/nip59.rs:238-245`, through MDK's `SdkSigner`,
`M16 transport-nostr-peeler/src/signer.rs:182-191`), and `make_gift_wrap` encrypts `seal.as_json()` of the `Event`
the signer's `sign_event` returned for the kind-13 seal (`F nip59.rs:247-248, 358-374`).

Neither plaintext is visible to `RetentionBoundPeeler::wrap_welcome_with_metadata` (`haven-core/src/nostr/mls/retention.rs:186-199`):
it receives the finished gift wrap, whose outer layer only the recipient can open, and the outer payload's length
gives only the padding bucket (every plaintext from 57 345 to 65 535 bytes pads to the same 65 603-byte payload,
`F v2.rs:106-114, 383-390`). A check there could match today's edge only by an argument over the seal's shape, not
by construction. Both plaintexts do pass through the Welcome signer Haven hands MDK's peeler. So the check lives
in a new `LegacyNip44WelcomeSigner` in `haven-core/src/nostr/mls/signer.rs` (beside `HavenIdentityProofSigner`): a
`MarmotNostrSigner` (`M16 signer.rs:47-73`, public) over the identity `Keys` that delegates every method and adds
two refusals:

1. `nip44_encrypt(pk, content)`: `content.len() > 65_408` ⇒ `Err(MarmotSignerError)` before delegating. This is
   the seal layer's edge, byte for byte P44's `pad`.
2. `sign_event(unsigned)` with `unsigned.kind == Kind::Seal` (13): sign by delegation, then
   `event.as_json().len() > 65_408` ⇒ `Err(MarmotSignerError)`. This is the gift-wrap layer's edge, measured on the
   exact string `make_gift_wrap` encrypts next. Every other kind is signed unchanged.

The session's peeler is built with it: `NostrMlsPeeler::new().with_welcome_signer_arc(LegacyNip44WelcomeSigner::arc(keys.clone()))`
(`M16 peeler.rs:124-127`) replaces `with_welcome_signer(keys.clone())` (`haven-core/src/nostr/mls/manager.rs:1374`);
`RetentionBoundPeeler` still wraps that peeler and its `wrap_welcome_with_metadata` keeps delegating. It is the one
peeler the session is constructed with, so every Welcome the engine wraps passes through the signer: invites
(`M16 cgka-engine/src/message_processor/send.rs:731-771`, `wrap_staged_welcomes`), creates
(`group_lifecycle.rs:827-858`) and recovery Welcomes alike, in Stage 1 and, through the same peeler construction, on
the runtime in Stage 2. The engine wraps every Welcome **before** it records anything: "a Welcome that cannot be
wrapped … refuses the intent with nothing written" (`send.rs:724-730`; creates `group_lifecycle.rs:827-829`). So a
refusal leaves no staged commit, no fanout record, no epoch change and nothing on the wire. The preview peeler
(`manager.rs:1376`) shares the signer and only decrypts. The key is the identity key, as today (Rule 1 unchanged);
the signer gets the security-reviewer pass.

The refusal text is fixed and names no size or count (Rule 15), nothing is logged, and the signer's `Debug` is
redacted like `HavenIdentityProofSigner`'s (`check_debug_impls_covered.sh`).

**Why this is exactly today's edge.** Today's refused set is {rumor JSON > 65 408} ∪ {seal JSON > 65 408}, and the
new refused set is the same two predicates on the same two strings, so there is no widening and no narrowing.
In practice the gift-wrap layer binds: the seal's JSON is the base64 of the rumor's padded payload plus a fixed
envelope, so a rumor of at most 40 960 bytes gives a seal of about 55 000 bytes and one byte more gives about
66 000 (computed from the padding rule; an observation the check does not rely on).

**User-visible outcome — unchanged.** The refusal travels the same path as today's: `MarmotSignerError` → F's
`Error::crypto` → `PeelerError::WrapFailed("NIP-59 gift wrap: …")` (`M16 nip59.rs:22-26`) → `EngineError::Peeler`
→ the circle change fails → the FFI's generic, redacted failure (`haven/rust_builder/src/api.rs:7274-7285,7355-7380`).
Today's refusal is **not** a typed outcome (there is no `RefusalFfi` for it), and Stage 1 keeps it that way: no new
`api.rs` distinction, no new copy. A typed "too large to invite into from this version" refusal is an optional
follow-up after Stage 1, not part of this migration.

Inbound is unaffected: Haven decodes extended-length Welcomes other clients send (security A10 — F's decoder
accepts up to the 5 MiB frame limit, a few MiB of transient allocation per hostile gift wrap; recorded in the row).

**C.8.3 Tests.**

- `haven-core/tests/nip44_plaintext_ceiling.rs`, rewritten (16.4 pair, see C.8.4 for its red). Every assertion is
  at the exact edge, 65 408 accepted and 65 409 refused, on each layer:
  1. `the_welcome_signer_encrypts_65408_bytes_and_refuses_65409`: `LegacyNip44WelcomeSigner::nip44_encrypt` of a
     65 408-byte plaintext returns a payload the recipient decrypts back to it; 65 409 bytes returns `Err`, whose
     text contains no digit (Rule 15). Control: plain `Keys` (F) encrypts the 65 409-byte plaintext, so the refusal
     is Haven's, not the library's.
  2. `the_welcome_signer_signs_a_seal_of_65408_json_bytes_and_refuses_65409`: a kind-13 unsigned event whose
     content is sized so its signed JSON is exactly 65 408 bytes is signed (and `as_json().len() == 65_408`); one
     content byte more returns `Err`. Control: a kind-1 event of 65 409 signed JSON bytes is signed.
  3. `a_welcome_wrap_refuses_exactly_what_the_pre_fork_encoder_refused`: through `RetentionBoundPeeler` over the
     real `NostrMlsPeeler` built as the session builds it. The test holds the recipient's key, so it unwraps every
     gift wrap it gets (F's NIP-59 extract) and measures both plaintexts. A binary search over the MLS payload
     length finds the largest `n` that wraps; for `n`, the rumor JSON and the seal JSON are both ≤ 65 408 bytes.
     Premise: the same inner peeler with a plain `Keys` Welcome signer wraps `n + 1`, and its unwrapped seal JSON is
     longer than 65 408 bytes. Haven's wrap of `n + 1` returns `Err(PeelerError::WrapFailed(_))`. Together these pin "wrapped
     ⇔ both layers ≤ 65 408", which is today's predicate.
- Stage 0's `an_invite_whose_welcome_exceeds_the_nip44_ceiling_sends_nothing` (S0.10) stays green
  unchanged, and 16.4 adds two assertions that v0.16.0's wrap-before-record order makes true (§C.8.2): afterwards no
  fanout row (`fanout_shapes_for_test`), and the circle's sends are not held. Its premise is unchanged: enough
  synthetic invitees that the inner peeler alone would emit an extended outer layer (MDK's test: ≈150 members).
- Stage 0's compat oversized-Welcome case (run B, R3.f) records today's outcome against a v0.10.4 peer and must
  give the same outcome on the new build.

**C.8.4 `nostr::encryption`, `proptest_security.rs` and the order of work.** The deletion is allowed before the
bump only with this promise pinned (R3.k), so it lands in Stage 0 as one commit:

- delete `haven-core/src/nostr/encryption/` and `pub mod encryption;` (`nostr/mod.rs:43`); remove the
  `rust|src/nostr/encryption/|97` row with `scripts/ci/check_coverage_floors.sh --drop-stale`, never by hand;
- `nip44_plaintext_ceiling.rs` keeps only its `nip44::encrypt` half (the NIP-59 path), which on 0.44 pins the
  device-side refusal through the dependency; the half that called Haven's wrapper goes with the wrapper;
- `proptest_security.rs`: the NIP-44 properties are re-pointed from Haven's wrapper to `nostr::nips::nip44::{encrypt,
  decrypt}` over sender/receiver `Keys` (the API the NIP-59 layers use), so every property Welcomes rely on stays
  proved on the production path: distinct keys → distinct ciphertexts, ciphertext longer than plaintext and never
  containing it, randomised encryption, deterministic decryption, MAC / nonce / wrong-key / any-authenticated-byte
  tamper fails (the version byte is read by the top-level `decrypt`, so the tamper range widens to `0..len`),
  round trip over diverse plaintext, empty plaintext refused, invalid base64 refused. `all_zero_key_encryption_roundtrips`
  is deleted: it tested a raw conversation key fed to Haven's wrapper, which the keys API cannot express (an
  all-zero secret key is invalid, already pinned by `keypair_from_all_zeros_fails`). The keypair properties are
  unchanged. `diverse_key_strategy` gives way to `valid_secret_key_strategy`.

At the bump: the sweep ports `matches!(…, Err(nip44::Error::V2(ErrorV2::MessageTooLong)))` to `.is_err()` (F's
`ErrorV2` is private, `F v2.rs:49-58`); that assertion is red at F — the observed red — and 16.4 turns it green with
the §C.8.2 check and the rewritten file.

**C.8.5 S22's reasoning, restated.** `tooling/soak/src/scenarios/s22_oversized_event.rs:24-31` ("What this scenario
is NOT about") becomes: the pinned rust-nostr has no NIP-44 plaintext ceiling any more; Haven refuses on the device,
before anything is staged, exactly the Welcomes the pre-fork encoder refused (`LegacyNip44WelcomeSigner`, tracker
T-NIP44-WELCOME-CEILING); that refusal is a function of two lengths and is proved in haven-core
(`nip44_plaintext_ceiling.rs`, `an_invite_whose_welcome_exceeds_the_nip44_ceiling_sends_nothing`), not by
a soak arm. The
Welcome arm stays a RELAY-side refusal (`:362-366` reworded to "not Haven's legacy-size refusal").

### C.9 The `.onion` refusal (X11, R4.k; semantic unit 16.5)

Haven's `foreign_relay_dialable` (`H relay/manager.rs:2550-2563`) admits `wss://*.onion`; dialling one hands the
name to the system resolver (Haven has no Tor transport), a privacy leak to the network. MDK refuses every `.onion`
endpoint (`M16 transport-nostr/src/safety.rs:584-626`, `TorRequired`). The refusal goes in `relay::url_norm::may_dial`
— the one scheme policy every validator, normaliser, list builder, `foreign_relay_dialable` and now the
`admit_relay` / `admit_connection` hooks call — so it holds on every plane, for user-named and foreign relays and
for MDK's own adds: a domain host whose name, trailing dots trimmed, ends in `.onion` (ASCII case-insensitive) is
not dialled. A user-named list containing one is refused in the existing fixed text that names no relay; a foreign
entry is dropped, never the list. Tests: `a_foreign_onion_relay_is_dropped_and_never_resolved` (no `admit_connection`
call is witnessed for it — the hook runs before the transport resolves), `a_user_named_onion_relay_is_refused_in_fixed_text`,
and `may_dial` unit cases (`.onion`, `.ONION.`, `onion.example.com` allowed). Noted in T-FOREIGN-RELAYS (no MDK gap).

---

## D. MDK relay-client changes the fanout absorbs

### D.1 The refusal proof under MDK's early return (Rule 13.3; semantic unit 16.2)

MDK still makes up to 3 attempts (`M16 sdk_client.rs:61`, 600 ms backoff, 12 s per attempt, 20 s ceiling,
`:57-70`), but a `TerminalRejected` attempt (`blocked:`, `invalid:`, `pow:`, `restricted:`, `unsupported:`, too
large) now **returns at once** (`:4941-4943`, mdk#2270), and any earlier `PossiblyExposed` attempt or timeout forces
the result to `PossiblyExposed` (`:4896,4917-4926`, mdk#2998). Haven's proof `refusals == MDK_ATTEMPTS_PER_CALL`
(`H fanout.rs:349-351`) would turn every proven terminal refusal into `PossiblyExposed` — no rollback, the circle
held up to 24 h (13.4). The sweep keeps today's rule; S0.9's golden (one EVENT instead of three for `blocked:`) and
the matrix's `blocked:` row are its observed reds.

New rule (`Answers::proves(kind)`); `n` = `OK false` frames for this event id heard from this relay, `complete` =
no gap and the stream not ended:

| MDK's classification | Proven iff | Why sound |
|---|---|---|
| `TerminalRejected` (any category) | `complete && !accepted && 1 <= n <= MDK_ATTEMPTS_PER_CALL` | MDK returns Terminal only if no earlier attempt was ambiguous or timed out (`:4917-4926`), so every earlier attempt was a relay-spoken non-storing refusal, each an `OK false`; the call ends at the terminal one. `n == 0` or a gap ⇒ not proven |
| `RetryableUnavailable` with category (`rate-limited`, `auth-required`) | `complete && !accepted && n == MDK_ATTEMPTS_PER_CALL` | unchanged |
| `RetryableUnavailable` without category, `NotExposed`, `PossiblyExposed` | n/a | unchanged |
| any, with `OK true` / `duplicate:` heard | `Accepted` (13.2) | unchanged |

Not proven ⇒ `PossiblyExposed` (byte-identical resend, never a rollback). A verdict comes only from a relay frame
Haven heard — never from the SDK's error kind or a `failed` string, which F fills with local failures too
(`F pool/mod.rs:525-538`, `error.rs:186-215`); this is also Stage 2's rule (R4.c). `AuthRequired` is upgraded to
`TerminalRejected` only when proven. `MDK_ATTEMPTS_PER_CALL` (now the upper bound) is still read from MDK's source.
Haven does not re-classify categories; it checks that the relay's own frames bear MDK's category out. The clock
complaint (T-CLOCK-SKEW) stays on the same listener.

Matrix (`haven-core/tests/fanout_transport_matrix.rs`, scripted relay, frames counted on the recording front):

| Relay answers (per attempt) | MDK result | Haven outcome | Frames sent |
|---|---|---|---|
| `blocked:` | Terminal | **proven TerminalRejected → rollback-eligible** | 1 |
| `invalid:` (clock) | Terminal | proven, clock verdict attached | 1 |
| `rate-limited:`, `blocked:` | Terminal | proven | 2 |
| `rate-limited:` ×2, `blocked:` | Terminal | proven | 3 |
| `rate-limited:` ×3 | RU(rate-limited) | proven RetryableUnavailable | 3 |
| `auth-required:` ×3 | RU(auth) | proven → upgraded TerminalRejected | 3 |
| timeout, `blocked:` | PE (forced) | PossiblyExposed | 2 |
| `error:`, `blocked:` | PE (forced) | PossiblyExposed | 2 |
| `blocked:` with a lagged listener | Terminal | **PossiblyExposed** | 1 |
| `blocked:` whose `OK` the listener never heard (answered on another socket) | Terminal | PossiblyExposed | 1 |
| bytes sent, socket dropped, no `OK` (a local `Rejected`-kind error) | PE | PossiblyExposed (`a_local_rejected_error_after_crossing_is_possibly_exposed`) | 1 |
| `OK true` after MDK's wait ended, then PE | PE | Accepted (13.2) | 1 |
| `duplicate:` | Accepted | Accepted | 1 |
| unprefixed refusal ×3 | PE | PossiblyExposed | 3 |

Flips: `assert_terminal` frame count `== 3` → per row (`H tests/fanout_transport_matrix.rs:95-114`);
`a_relay_spoken_refusal_is_returned_only_when_every_attempt_was_answered_ok_false` and
`auth_required_is_terminal_once_every_attempt_was_answered_with_it` rewritten to the rows; new end-to-end
`a_commit_every_relay_refuses_rolls_back_on_one_frame_per_relay` (`fanout_driver_e2e`) and its negative
`a_commit_refused_after_a_timeout_is_never_rolled_back`. Soak: "a relay that answered `blocked:` is sent the event
three times" → once. The security review could not construct a frame, lag or reconnect sequence under this rule
that rolls back a commit a relay may hold.

### D.2 `possible_exposure()` counts `Attempting` — 1a's one test (X8)

1b's C11 owns the audit of every reader (`H fanout.rs:1361,1479,1728,1756,2026-2029,2472`, `manager.rs:15312`,
`types.rs:812`) and decides what happens to `|| contains(&Attempting)` in `a_relay_may_hold`. 1a contributes
`a_record_left_attempting_by_a_kill_is_never_rolled_back_and_goes_hourly_after_its_first_day` (`fanout_driver_e2e`,
in 16.2), written against `M16 traits/src/transport_adapter.rs:570-581`.

### D.3 WRITE flag and lingering relays on the publish pool

- MDK ORs `WRITE` onto a relay Haven registered (`M16 sdk_client.rs:5444,5453`): harmless, Haven registers
  READ|WRITE and never sends without `.to(..)`.
- MDK-added relays (only in the race) linger idle up to 60 s, at most 16 (`:81-82`, `evict_idle :1939-2034`); relays
  Haven pre-registered are never in MDK's cache and never removed by it (`:5450-5466`). Test (16.1):
  `mdk_never_removes_or_reconfigures_a_relay_haven_registered` — presence (`Ok(Some)`) and §B.3.3's behavioural
  option probes before and after three fanout calls including a `PossiblyExposed` one.
- MDK still disconnects every `PossiblyExposed` endpoint (`reset_ambiguous_publish_relays`, `:5617-5640`); at F the
  next dial works, so Haven's drop goes (§B.3.9), pinned by
  `a_relay_mdk_reset_after_an_ambiguous_publish_is_reachable_again` (kept, now without the drop).
- `observe_socket` attaches read-only monitors (`:5422-5429`): no frames. MDK refuses to sign an unsigned non-445
  event (`:6311-6313`); Haven's `NotExposed` pre-check stays (it also refuses unverifiable bytes).

### D.4 Source-scan tests — cannot go blind

They use Stage 0's shared resolver (`haven-core/tests/helpers/`), which asserts the package's `source` equals
`HAVEN_MDK_SOURCE` / `HAVEN_NOSTR_SOURCE` from `mdk_pins.env`; every extraction asserts exactly one match and a
minimum length; a split marker that fails is a test failure, never "whole file". Stage 1 changes values:

| Test | Reads | Asserts |
|---|---|---|
| `mdks_relay_client_builds_no_client_and_installs_nothing_on_the_one_it_is_handed` | bodies of `pub fn new(client: Client)` and `fn new_with_liveness` (`M16 sdk_client.rs:2312-2357`), the `SdkPublication::OpaqueClient` arm of `send_event_attempt` (`:4829-4843`), `event_for_publish_with_signer` (`:6311-6313`), `network_proxy.rs` | `new`/`new_with_liveness` contain `publication: SdkPublication::OpaqueClient`, `signer: None` and none of `build()`, `builder(`, `ClientBuilder`, `authenticator`, `gossip`, `admit_policy`, `websocket_transport`, `nostr_builder`; the opaque arm is exactly `self.client.send_event(event).to([endpoint.clone()])`; `nostr_builder`'s callers are exactly `multi_account` / `register_account`. Behaviour: an unsigned kind-1 handed to `publish_event` is an `Err` and the front sees no frame |
| `mdks_publish_loop_returns_terminal_at_once_and_carries_earlier_ambiguity` (was `mdks_in_call_attempt_count_is_the_one_the_transport_counts_against`) | `send_event_to_relay` (`:4882-4965`), consts `:57-70` | `SDK_RELAY_PUBLISH_ATTEMPTS: usize = 3` (= `MDK_ATTEMPTS_PER_CALL`); `for attempt in 1..=SDK_RELAY_PUBLISH_ATTEMPTS`; `earlier_ambiguous_attempt |= …PossiblyExposed`; the forcing branch; the timeout arm setting `earlier_ambiguous_attempt = true`; `if terminal_rejection { return Err(failure); }` — each a separate assertion naming the §D.1 row it protects |
| `mdks_call_ceiling_is_the_one_a_drive_is_said_to_wait` | `:70` | 20 s |
| `every_failure_reason_mdks_relay_client_writes_is_fixed_and_none_is_the_drivers_marker` | product half split at `#[cfg(test)]\n// Test fixtures dial local relays directly.\n#[allow(clippy::disallowed_methods)]\nmod tests {` (`M16 :6793-6796`), found exactly once | list incl. `"connect relay timed out"` (`:4798`), `"relay rejected event (…)"` (`:6765-6777`) |
| `neg_constants_match_mdk` → `neg_set_limit_is_mdks_sentinel` + `neg_waits_are_havens_own_and_never_exceed_mdks` | `sdk_client.rs:86-110`, storage-sqlite consts, `F nostr-sdk/src/error.rs`, `negentropy/src/error.rs` | `SDK_RECONCILIATION_SET_LIMIT: usize = 16_384 + 1`, Haven's filter limit 16 385, `NEG_SET_LIMIT == TRANSPORT_RECONCILIATION_MAX_ITEMS_PER_ROUTE`; Haven's waits and batch ≤ MDK's; `negentropy_not_supported` built with `ErrorKind::Unsupported`; `UnsupportedProtocolVersion` is a `negentropy::Error` variant |
| `fanout_pacing_is_mdks_by_value`, `security_rule_gates.rs` `mdk_host_source()` | `marmot-session/src/runtime.rs` (consts `:123-128`, rule `:6749-6780`) | values unchanged (30 s·2^(n−1) cap 1 h; flat 5 s) |
| `relay_pool_expiry_drop_point.rs`, `clock_skew::tests::total_loss_point_is_the_relay_pools_drop_point` | `F nostr-sdk/src/relay/inner.rs` | expiry drop before `verify_and_cache` (`:1705-1710`) |

---

## E. Tracker rows in this area

"Red first" means a Haven-seam test whose red is observed in the step-15 inventory or under a mechanical port,
then turned green by the unit that changes behaviour.

| Row | Verdict | Change | Red / pin | Rewritten facts |
|---|---|---|---|---|
| **T-NIP40-POOL** | KEEP-UPDATE | re-cite | — | drop at `F relay/inner.rs:1704-1707`, before `verify_and_cache` (`:1710`); device clock, no grace; no option disables it; acquisition `raw_received_items` counts it but cannot tell expired from forged |
| **T-POOL-QUEUED-ACCEPT** | KEEP-UPDATE | `Ok(Some(r))` (§B.3.2); re-issue §B.3.4 | S0.4c tests; `a_reissue_of_a_req_the_relay_still_holds_reaches_the_wire_from_the_floor` | queueing unchanged (`F relay/inner.rs:425-478`); grace = `ENGINE_CONNECT_TIMEOUT` 15 s; a REQ queued before a connection is sent once (`:128-141`); per-REQ EOSE exists, not adopted |
| **T-POOL-SEEN** | KEEP-UPDATE | `ClientNotification` disposition; `notifications_with_gaps` | S0.4d lag test + the `.notifications()` ban | first-seen `Event` only on `NotExistent` (`:1723-1764`); `Message` every delivery; 35 000-id LRU; Haven's sends `.save_into_database(false)` |
| **T-POOL-VERIFY-CACHE** | REWRITE as standing guard (D4) | §C | `a_pool_client_without_the_policy_hands_back_…` red at F → `…_refuses_every_forgery…` | gap closed at F (`081e4753`, `a8efab6d`; upstream `0e08c306`, `a991ff00`, crates.io 0.45.5/0.45.6); Haven keeps `verify()` deliberately; residual ask: the cache lock is held across Schnorr (`F shared.rs:74-99`), one hostile relay serialises all; removal condition: none |
| **T-POOL-OPTIONS** | KEEP-UPDATE | `AddRelay` setters; PING clear deleted; `admit_relay` backstop | `register_publish_relays_registers_a_relay_the_pool_does_not_hold`; behavioural option probes | MDK adds unknown targets with SDK defaults (`M16 sdk_client.rs:5472-5478`), re-adds in `pin_new_relay_retry_interval` (`:5271-5330`), ORs WRITE, idle cache 60 s / 16; pool holds the read lock across the OK wait; ping immutable per relay |
| **T-ADAPTER-ATTEMPTS** | MUST-CHANGE | §D.1; §D.4 pin | `blocked:` row (red under the old rule) | ask 2 met (#2998); ask 1 met for terminal categories (#2270); ask 3 (host pacing) unmet, host now `marmot-session/src/runtime.rs`; difference (2) re-justified (MDK refuses to sign); residual: rate-limited / auth-required / `error:` / unprefixed still resent up to 3× |
| **T-CLOCK-SKEW** | KEEP-UPDATE | none | — | MDK keeps only the category (`M16 sdk_client.rs:6773-6777`); reconcile the row's wording with `H fanout.rs:2634-2646` |
| **T-NIP77-DRIVER** | KEEP-UPDATE | `Relay::sync(..).items(Vec::new())`, typed classification | `a_nip77_refusal_is_classified_unsupported_by_type`; re-specified "advertises nothing" + its control | MDK still advertises its inventory (`reconcile_subscription`, `M16 sdk_client.rs:3069-3141`); Haven's waits are its own; sentinel adopted; the default client database cannot answer `negentropy_items` (fact 9) |
| **T-NIP77-FALLBACK** | KEEP-UPDATE | sentinel `16_384 + 1` | `a_remote_set_of_exactly_the_limit_is_whole_and_one_more_is_saturated` | MDK's convention (spec status UNVERIFIED) |
| **T-NEG-CLOSE** | **REMOVE** after proof | none (`close_drive_pool` stays) | S0.9 golden W10 (a pass cut at Haven's deadline, through `neg_remote_ids`) red at F: a `NEG-CLOSE` now appears; the difference is entered in `allowed_differences.toml` naming this row | fixed at F (`SyncCleanup`, `F relay/api/sync.rs:145-187,420-428`, `ea14ca19`); `tooling/e2e/ci/check-wire-journal.sh` (C-NEG) accepts `NEG-CLOSE` and the inert `CLOSE` of the never-opened download id |
| **T-POOL-TERMINATE-PERMIT** | **REMOVE** the mitigations | sweep: wedge detector (no `queue()`); 16.6: `shutdown` = `disconnect`, drop after `PossiblyExposed` deleted | no raw-pool gap test (cannot compile on F); the promise tests stay green **without** the mitigations: `a_relay_registered_but_never_dialled_is_reachable_after_shutdown`, `a_dial_cancelled_mid_handshake_is_healed_by_shutdown`, `a_sleeping_publish_socket_is_reachable_after_shutdown`, `a_relay_mdk_reset_after_an_ambiguous_publish_is_reachable_again`, `a_closed_drive_pool_reaches_its_relays_again`; `rule13_a_burst_never_pauses_with_a_pending_publish_outstanding` re-pinned | fixed at F: permit cleared at every reservation (`F relay/inner.rs:201-206,814-866,999-1020`, `53a3fa44`), a dropped dial resets to `Terminated` (`try_connect.rs:17-28`), superseded dial refused under the ownership lock (`inner.rs:1066-1106`); the removal rests on that structure, not a behavioural reproduction of the 0.44 race (flagged to the owner); `rebuild_stalled_relays` recorded as the next candidate (§B.3.9) |
| **T-LIBSQLITE-PATCH** | KEEP-UPDATE | none | — | MDK v0.16.0 still patches `rusqlite@5ae7fdf`; add RUSTSEC-2026-0459 (SQLite 3.53.3 in SQLCipher 4.17, pre-existing, invisible to cargo-audit on a git source) |
| **T-OPENMLS-FORK** → **T-OPENMLS-UPSTREAM-MAIN** | KEEP-UPDATE | pins | — | upstream `openmls/openmls@6100df3` main because no release carries #2133 + #2249/#2261 + the 0.9.1/0.9.2 fixes together; brings GHSA-gc79-23g3-8g52, -p276-g3f3-wwgh, -94v4-rg25-x625; git source ⇒ no RustSec coverage; removal: an OpenMLS release with all of them and MDK moving to it |
| **T-FOREIGN-RELAYS** | KEEP-UPDATE | `.onion` refused in `may_dial` (§C.9) | `a_foreign_onion_relay_is_dropped_and_never_resolved` | no MDK gap (MDK refuses `.onion` itself) |

New rows:

| Row | Facts | Removal condition | Pinned by |
|---|---|---|---|
| **T-NIP44-WELCOME-CEILING** | F's NIP-44 has an extended length prefix and no plaintext ceiling; MDK's peeler emits extended Welcomes (mdk#2335); a pre-fork receiver (Haven ≤ v0.1.13, other clients on nostr < 0.45) decodes only the two-byte-prefix form. Haven refuses, before anything is staged, exactly the Welcomes the pre-fork encoder refused: rumor JSON or signed seal JSON longer than 65 408 bytes (`LegacyNip44WelcomeSigner`, §C.8.2), through today's generic error path. Inbound extended Welcomes are accepted; F decodes up to the 5 MiB frame limit (security A10, LOW) | the minimum upgrade source decodes extended NIP-44 (a release at or after Stage 1's) **and** the owner judges pre-0.45 Marmot receivers no longer need to join Haven circles | `nip44_plaintext_ceiling.rs`; `an_invite_whose_welcome_exceeds_the_nip44_ceiling_sends_nothing`; compat run B |
| **T-NOSTR-FORK** | Whole nostr graph on `erskingardner/rust-nostr@e93cc06b` (MDK's maintainer's personal fork; 28 commits on `up/master@01f1950c`, lacks ≥ 36 later upstream commits). MDK's public types require the same rev. Git source ⇒ `cargo audit` / RustSec blind; a SHA pin protects content, not availability. Bump procedure: diff fork vs `up/master` and `up/v0.45` security commits and draft an MDK ask for anything missing | MDK moves `nostr`/`nostr-sdk`/`nostr-gossip` to a crates.io release | `check_lockfile_universe.sh` (source pin) |
| **T-NIP44-CT-HMAC** | F compares the NIP-44 v2 HMAC with `!=` (`F v2.rs:285-288`), as P44 does (no regression); upstream fixed in `5dded12d` (crates.io 0.45.6). Not exploitable in Haven: on the outer layer the attacker chooses the ephemeral key; on the seal layer a forged MAC must still decrypt to a seal signed by the claimed sender (`F nips/nip59.rs:403-411`); no remotely observable per-event timing. LOW | MDK re-pins onto a fork rev containing `5dded12d` | a source-pin test asserting the comparison text at the pinned rev |
| **T-REQ-REISSUE** | F refuses a same-id REQ; Haven re-issues by unsubscribe + subscribe on the same id (+1 CLOSE for a still-registered REQ). Upstream `Relay::reissue_subscription` (`f7ebc0a8`, PR #1495) is atomic but not in the fork | MDK pins a rev carrying it; Haven switches and deletes the two-step | `a_reissue_of_a_req_the_relay_still_holds_reaches_the_wire_from_the_floor` |
| **T-WS-USER-AGENT** | Haven supplies `HeaderlessTransport` so no `user-agent` is sent (F's default sends `nostr-sdk/0.45.4`) | upstream offers an option to omit or set handshake headers on the default transport | `no_relay_socket_sends_a_user_agent` + its `DefaultWebsocketTransport` control |
| **T-SDK-SHIPPED-FEATURES** | MDK's workspace enables `nostr-sdk/local-relay` (a WebSocket relay server + `nostr-memory` + `tokio/net`) and `nostr` `nip04`/`nip49` (`M16 Cargo.toml:134-135`); feature unification compiles them into Haven's shipped library. Never called by Haven, held by `disallowed-types` (§C.5) | MDK scopes these features to the crates that need them | `check_mdk_supply_chain.sh --nostr-features`; clippy `disallowed-types` |

Touched, owned elsewhere: T-FORGED-COPY-SEEN (the pool can no longer hand on a forged copy; the engine-side part is
1b's); T-KILL-WINDOW (§D.2, 1b).

---

## F. Order of work (master steps 11–20) and build cycles

### F.1 Steps

Every push is green except inside the RED-WINDOW (steps 12–14). "Merges" means a green, pushed commit series on the
working branch; the owner merges at stage boundaries (R1.a). Local gate per step: `cargo test` / clippy
`--all-targets -D warnings` / fmt in the affected roots, guards with `--self-test`, and — now local — `flutter
analyze`, `flutter test`, `gen-l10n`, ARB parity.

| Step | 1a work | Green when |
|---|---|---|
| **11 Setup** | per-agent git worktrees sharing one `CARGO_TARGET_DIR`; confirm `flutter_rust_bridge_codegen --version` = 2.11.1 (installed, R3.i) | — |
| **12 Pins — RED-WINDOW opens** | §A.2–A.6 manifests, all six lockfiles (`ctutils` per root), `mdk_pins.env`; §A.7 guard values; 1b's test-key change (R4.e) lands in the same step | `cargo metadata --locked` in all six roots; universe and supply-chain guards + `--self-test` green |
| **13 Sweep part 1 (lib)** | one `nostr_sdk` path-script commit (§B.1); then §B.1 renames, §B.3 sweep ports, §C.2 sweep port, by partition (§B.2) | **CP-L:** `cargo check --lib` with and without `--features test-utils`, `cargo clippy --lib -- -D warnings` |
| **14 Sweep part 2 (tests, other roots)** | `tooling/e2e/local-relay` port with explicit limits (first: haven-core and soak compile it); haven-core in-file test modules and `tests/`; `haven/rust_builder` (`api.rs` paths, `MockRelay`, forged-event tests); `tooling/soak` | **CP-T:** `cargo check --all-targets` and clippy green in every root. RED-WINDOW closes for compilation; first push, test failures expected |
| **15 Red inventory** | one full haven-core suite, soak `pr`, S0.1 fixture check, S0.2 compat (old = Stage 0, new = HEAD), the wire-equivalence and cost-ledger comparison; every red assigned to its unit | inventory recorded |
| **16.1 Rule 16 / pool** | §C.2 literal, §C.3 hooks, §C.4 transport, §C.5 clippy entries + gossip test + NIP-42 control respell, §C.6 check 11, §B.3.1 ban, §B.3.2 test + ban, §B.3.3 behaviour tests + checks 3–4, §B.3.9 `ENGINE_CONNECT_TIMEOUT` + `pool_constants.rs` + 78 s, §D.3 test | S0.4a, S0.4b green; listed reds green |
| **16.2 Fanout proof rule** | §D.1 (edit by `fanout.rs`'s owner), matrix, driver e2e; §D.2's one test beside 1b's C11 | matrix + `fanout_driver_e2e` green |
| **16.4 (1a part)** | §C.8.2 `LegacyNip44WelcomeSigner` in `signer.rs` and the peeler construction in `manager.rs` (by their owner), rewritten `nip44_plaintext_ceiling.rs`, the two added invite-e2e assertions, S22 text | ceiling test green; compat oversized-Welcome case same outcome as v0.10.4 |
| **16.5 (1a part)** | §C.9 `.onion` | its tests green |
| **16.6 Relay-layer removals** | NIP-77 typed classification, sentinel, constants tests, check 5, "advertises nothing" re-spec (§B.3.5); `acquire_events` against S0.9's end-shape tests (§B.3.8); same-id re-issue (§B.3.4) and the pause-body re-derivation; T-POOL-TERMINATE-PERMIT removals after their promise tests; T-NEG-CLOSE flip and row removal | each pair green; then full suite, soak `pr`, fixture at all instants, compat all-P0 |
| **17 One `api.rs` batch** | 1b's semantic batch; then **one local `./scripts/regenerate_frb.sh`** covering 1a's step-14 edits too (X12) | `check_generated_bridge_pinned.sh`, `flutter analyze`, `flutter test` |
| **18 Docs** | Rule 16 text (§C.7) to the docs editor with the facts list; tracker rows (§E); `MARMOT_PROTOCOL_KNOWLEDGE.md`, `docs/SOAK_LANE.md`, `docs/POWER_EFFICIENCY_PLAN.md` (NIP-77 waits); every `nostr-relay-pool` behavioural citation (12 src files, 7 tests, 11 soak, `api.rs`, two Dart files) re-derived, not substituted | `grep -rn 'nostr-relay-pool\|nostr-relay-builder\|0\.44\.' --include=*.rs --include=*.md --include=*.dart` reviewed hit by hit; `check_privacy_invariants.sh`; `check_estimate_integrity.sh` |
| **19 Coverage** | `scripts/ci/check_coverage.sh`; floors only via `--repin` (raises) and `--drop-stale` | gate green |
| **20 CI matrix** | push; cross-check (Apple/Windows/Android), build-check, `release-link`, E2E lanes twice (the iOS local-relay lane with the explicit limits), `soak-nightly` dispatch | Stage 1 exit (§F.3) |

Within 16.x every pair is ordered "red observed → behaviour change → mitigation deleted → promise tests green".
Step 16 never starts before step 15's inventory exists. The bridge-pinned guard may be red from step 14 to 17 (if
the content hash covers the edited parts of `api.rs`, UNVERIFIED); it is an expected entry of the red inventory, not
a reason for a second regeneration.

### F.2 Build cycles and the partition

Compilation is one serial resource: one `CARGO_TARGET_DIR` (dependencies built once; each worktree's haven-core is
its own artifact), Cargo's build lock serialising checks, 4 cores. So the sweep runs in **rounds**: engineers
commit their partitions, an integrator merges and runs one `cargo check --message-format short`, the error list is
split by path prefix (§B.2) and every engineer fixes their files in parallel. One check per round, not one per
engineer: a check reports the whole crate's errors at once.

| Phase | Rounds (check cycles) | Compile time at ≤ 3.5 min per check |
|---|---|---|
| CP-L (lib; rustc reports resolution, then type, then borrow errors in successive waves) | 6–8 | ≈ 21–28 min |
| CP-T haven-core `--all-targets` | 5–7 | ≈ 18–25 min |
| CP-T `local-relay`, `rust_builder`, `soak` | 1 + 2–3 + 2–3 | ≈ 18–25 min |
| **Sweep total** | **≈ 16–21** | **≈ 1–1.3 h** |
| Step 15 inventory | 1 full suite + soak `pr` + fixture + compat | ≈ 30 min suite + rig runs |
| Step 16 (1a units) | targeted `cargo test --test …` per pair; one full suite at the end of 16.1, 16.2, 16.6 and one after all units | ≈ 4 × 30 min suite |

All round counts and compile times in this table, and the effort below, are ESTIMATED (they extrapolate the trial's 209 first-wave errors and the
measured per-check and per-suite times; later waves were hidden in the trial). Wall time is dominated by editing,
not compiling. Parallelism: P-pool, P-live, P-fanout, P-misc and 1b in step 13; in step 14, P-relay first, then
haven-core tests by family alongside P-ffi and P-soak once haven-core's lib is stable. Engineer-days, secondary and
ESTIMATED: 1a ≈ 20–28 ED, down from 35–45 now that the bilingual refactors, the wire harness, the gap tests and the
guard mechanisms are Stage 0's and the acquisition parity harness is gone.

### F.3 Stage 1 exit — 1a's entries (R4.m)

Recorded with run ids before the owner merges Stage 1:

- wire-equivalence transcripts equal S0.9's goldens except the reviewed allowlist: `NEG-CLOSE` (+ inert `CLOSE`)
  after a cut NIP-77 session; one `CLOSE` before a re-issued still-registered REQ; one `EVENT` instead of up to three
  for a terminal refusal; any acquisition frame difference listed with its reason — anything else is a behaviour
  change to explain or fix;
- the cost ledger within tolerance (frames by verb, dials, `verify()` calls, events fetched, store pages,
  KeyPackage publications); increases fail unless listed with a reason, improvements recorded;
- compat green against the old peer (both directions, in-place upgrade, downgrade refusal, the oversized-Welcome
  case); `soak-nightly` dispatched on the branch (4 slots); every E2E lane run twice with its result compared with
  the lane's recorded flake rate; cross-check, build-check and `release-link` green;
- coverage re-pinned with `--repin` only.

---

## G. Risks (ranked)

| # | Risk | Severity | Retired by |
|---|---|---|---|
| R1 | Silent loss of Rule 12 lag evidence (`notifications()` compiles) | HIGH | sweep ports to `notifications_with_gaps` only; S0.4d lag test; 16.1 ban |
| R2 | Refused commits never roll back (MDK's early return vs `== 3`) | HIGH | §D.1 rule + matrix; `blocked:` row and S0.9 golden as the reds |
| R3 | Rule 16 guard goes vacuous (signer words dead; authenticator, transport, manual AUTH, standalone relay unscanned) | HIGH | check 11 rewrite with a fixture per spelling; exhaustive `ClientBuilder` literal; clippy `disallowed-types` |
| R4 | `client.relay(..).is_ok()` always true | HIGH | sweep's `Ok(Some(_))` port; ban; registration test |
| R5 | Oversized Welcome sent to a v0.1.13 invitee who cannot open it | MEDIUM | §C.8 check, edge test, invite e2e, compat case |
| R6 | Two nostr universes (local-relay, a leftover dev dep, a registry 0.45.x, an abbreviated rev) | MEDIUM | universe values and fixtures in step 12 |
| R7 | Re-issue / pause semantics under F's registration and restore rules | MEDIUM | S0.4c tests, new re-issue test, S0.9 goldens for re-issue and pause/resume |
| R8 | F's local-relay defaults (500 filter limit, 60 notes/min, 64 KiB events, blacklist, expiry refusal) turn tests and lanes red for non-Haven reasons | MEDIUM | one explicit test-relay builder before any test runs; never loosen assertions |
| R9 | Removing the wedge recovery without a behavioural reproducer (no `queue()`) | MEDIUM | F's ownership lock (`inner.rs:1066-1106`) + promise tests; flagged to the owner |
| R10 | Header-less transport diverges from F's default (proxy, ping, error mapping, sink) | LOW–MEDIUM | copy of F's `TransportSink`; handshake test with its control; full suite over it |
| R11 | Cross-target build of the fork graph (`async-wsocket 0.17`, `getrandom 0.4`, `fs-private`) | MEDIUM, CI-only | push the CP-L commit to `cross-check.yml` before step 14 |
| R12 | Lock re-resolution needs more than `ctutils` in `rust_builder` / `soak` | LOW | one `cargo update -p` each, recorded |
| R13 | Personal-fork availability / a force-push orphaning the pinned SHA | LOW, standing | T-NOSTR-FORK; contingency `[patch."https://github.com/erskingardner/rust-nostr"]` to a byte-identical mirror at the same SHA only if the source disappears |
| R14 | Doc and citation drift (many `nostr-relay-pool 0.44.3` behavioural claims) | LOW, a pillar | step 18 hit-by-hit review |

### Still undetermined

- Error counts after the name-resolution wave (the trial stopped there); the round estimates in §F.2 rest on it.
- Whether `cargo update -p ctutils` is needed in `rust_builder` and `soak` (their locks share the lineage).
- tokio-tungstenite 0.26 → 0.28 detail for the scripted relay and recording front (compile-guided).
- Whether opaquerr's `define_kind!` generates the `kind()` accessor §B.3.5 calls (fallback stated there).
- Whether the FRB content hash covers `api.rs` test modules (decides whether the bridge guard is red in steps 14–17).
- Whether `admit_connection` returning `Rejected` changes a status transition Haven's monitor or health code reads
  (`F relay/inner.rs:891` not traced to its status effect).
- F's `should_resubscribe` across a pause for a subscription still registered at the next burst (re-derived in 16.6).
- Whether a local SDK error string can begin with a NIP-01 prefix (§D.1's rule does not read strings, so this no
  longer decides a verdict; it would only affect the clock classifier's compare).
- GitHub's retention of an orphaned pinned SHA.

---

## Appendix — Review ledger

| Source | Finding | What changed |
|---|---|---|
| Security M1 | Deleting `nostr::encryption` drops the ceiling test; the fork has no ceiling | §C.8: Haven-side refusal at exactly the pre-fork edge on each NIP-59 layer (`LegacyNip44WelcomeSigner`), rewritten ceiling test, Stage 0's invite e2e extended, S22 restated, tracker row, `--drop-stale`, Stage-0 deletion with the promise kept |
| R4.a, exact edge | A payload-length check admitted seal plaintexts of 65 409–65 535 bytes that today's encoder refuses | The check moved into the Welcome signer, which sees both plaintexts; the refused set equals today's by construction (§C.8.2); the tests assert 65 408 / 65 409 on each layer (§C.8.3) |
| Consistency: tracker id | 1a and 1b named the ceiling row differently | `T-NIP44-WELCOME-CEILING`, 1b's name |
| Security, wrong claim | "only user is `proptest_security.rs`" | Fact 2 lists both test files |
| Security, wrong claim | "random-nonce NIP-44 encrypt is gone at F" | Fact 1: RNG-backed `nip44::encrypt` remains; only `v2::encrypt_to_bytes` is gone |
| Security, wrong claim | S0.4c "fresh id per issue" vs 1a | §B.3.4: same id, unsubscribe-then-subscribe; S0.4c prose corrected in Stage 0 |
| Security M5 / R4.c | Verdict only from a heard relay frame | §D.1 states it for Stage 1 and 2; matrix row `a_local_rejected_error_after_crossing_is_possibly_exposed` |
| Security A1 | Ban manual NIP-42 frames | Check 11 row "Manual NIP-42 frame"; Rule 16 text |
| Security A2 | `.websocket_transport =` clause | Added to check 11 (and `.admit_policy =`) |
| Security A3 | Ban relay servers in product sources | §C.5: clippy `disallowed-types` in both shipped roots + check-11 rule on the `allow` placement |
| Security A4 | Copy F's `TransportSink`, no `sink_map_err` | §C.4 |
| Security A10 | Decrypt accepts up to the 5 MiB frame | Note in T-NIP44-WELCOME-CEILING |
| Security A5, A7, A8, A9 | Welcome outbox, `mls_extensions` pin, duplicate refs, NIP-11 | Not applied here: 1b / Stage 2 |
| Security, confirmed | inbound order, builder literal, hooks, user-agent, MDK publish loop, `possible_exposure`, NIP-44 HMAC | Kept; citations tightened (§C.1–C.4, §D.1, §E) |
| Engineering M2 / R4.d | Semantic fixes inside the compile sweep | §B.3 gives each item's mechanical port and its semantic unit; §F.1 follows master steps 12–16 |
| Engineering M3 / X4 | Reconnect-constant guard planned twice | `rust-check.yml` step rewrite dropped; `pool_constants.rs` re-pointed in 16.1 (§B.3.9) |
| Engineering M3 / X5 | Universe guard vs local-relay; fixture count | Per-root subset for local-relay; fixtures counted from Stage 0's (§A.7) |
| Engineering M3 / X6 | Supply-chain mechanism built twice | 1a changes values only (§A.7) |
| Engineering X7 | NIP-77 constants owned twice | Owned here (§B.3.5); 1b C17 deleted; one red-test name |
| Engineering X8 | `possible_exposure` designed twice | §D.2: one contributed test; the audit is 1b's |
| Engineering X9 | User-agent proof twice | S0.4b's test; 1a adds only the `DefaultWebsocketTransport` control (§C.4) |
| Engineering X10 | NIP-42 proof twice | S0.4a's test; control respelled; 1a's `LocalRelay` NIP-42 test dropped (§C.5) |
| Engineering X11 / R4.k | `.onion` ownership | §C.9 in `may_dial` |
| Engineering X12 / M9 / W3 / R4.l | "no FRB regeneration caused by 1a" | Corrected: one local regeneration at step 17 covers 1a's edits; codegen installed (R3.i) |
| Engineering X15 | Rule 16 text ownership | §C.7 is 1a's; other doc facts handed to the docs editor |
| Engineering M7 / R3.k | Bilingual refactors pre-bump | §0 table; §B.1 now covers `nostr_sdk` paths and fork-only renames |
| Engineering M10 / W6 | Parity harness forces a throwaway port; `Cancelled` missing | Parity harness dropped; S0.4d end-shape tests gate `acquire_events`; `Cancelled` in the mapping (§B.3.8) |
| Engineering M11 | Raw-pool gap tests cannot compile on F | T-POOL-TERMINATE-PERMIT gap test dropped; the T-NEG-CLOSE gap is recorded by S0.9's golden W10 (through `neg_remote_ids`) |
| Engineering M12 | File ownership; shared target dir | §0 one-editor rule; §F.2 worktrees + shared `CARGO_TARGET_DIR` + rounds |
| Engineering A2 | "fork rev equals MDK's" check redundant | Dropped (§A.7) |
| Engineering A3 | `--precise` raises are policy without a defect | Dropped (§A.5) |
| Engineering A5 | Test-relay limits duplicated | Equality test in haven-core over both sets (§B.5) |
| Engineering R14 / §5 | Cross-target build CI-only | Kept as R11; CP-L pushed to cross-check |
| Engineering H1, H2, M1, M4–M6, M8, M13 | Exception guard, test key, Stage 2 items | Not applied here: 1b / Stage 0 / Stage 2 (test key in step 12 by 1b, R4.e) |
| Tests HIGH-2 | §F.0 prerequisites absent from Stage 0; no baseline | Moved to S0.4d and S0.9 (§0 table); Stage 1 judged against goldens and cost ledger with an allowlist (§F.3) |
| Tests M11 | Option tests assert a `Debug` string | Behavioural probes: Ping frames, `Terminated` status + no redial, capabilities, `Sleeping` (§B.3.3) |
| Tests M12 | "Advertises nothing" seeds the wrong inventory | Seeds the client database the fork reads, premise on `negentropy_items`, positive control over `MemoryDatabase` (§B.3.5) |
| Tests §4 | Lag test feasibility unverified | Deterministic design: receiver gate + a second stream fenced on the EOSE (§B.3.1) |
| Tests M8 | Gossip absence window | `a_verified_client_has_no_gossip_store` with positive control (§C.5); the timing fence itself is S0.6's |
| Tests M9 / R4.m | No Stage 1 exit checklist | §F.3 |
| Tests M10 / R3.l | `cross-check --locked`, `wn` interop dropped | Not applied here: Stage 0 guard step; `wn` lane P1 after Stage 1 |
| Tests advisory | Run guard self-tests through the script | §C.6 self-test runs the script on planted trees |
| Data review | No finding touches 1a | — (the test key, R4.e, is 1b's in step 12) |
| R1.c | Effort in build cycles | §F.2 |
| R3.i | Flutter local | Every "CI only" statement updated (intro, §F.1 steps 17 and 20) |
| R4.a / O13 | Keep refusing oversized Welcomes | §C.8; corrected premise: today's outcome is untyped, kept unchanged; a typed refusal is an optional follow-up after Stage 1 |
| R4.n | Wrong claims corrected in place | Facts 1–2, §B.3.4, §B.3.8, §F.1 step 17, §A.7 universe subsets |
| R6 O12 | Suppress `user-agent` | §C.4 |
