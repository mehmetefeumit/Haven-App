# Security Policy

## Supported Versions

| Version | Supported          |
| ------- | ------------------ |
| 0.1.x   | :white_check_mark: |

## Reporting a Vulnerability

If you discover a security vulnerability, please report it privately by emailing the maintainers. Do not open a public issue.

## Known Vulnerabilities

New advisories are surfaced by the weekly `cargo audit` CI job; document them
here as they appear. Advisories deliberately *not* blocking CI (unreachable
transitive code, informational warnings) are justified individually in
`haven-core/.cargo/audit.toml`, not here.

### Open, non-blocking

- **RUSTSEC-2026-0237** — `nostr-relay-builder` is **unmaintained**
  (informational; `patched = []`, so there is no version to move to). It is a
  dev-dependency of `haven-core` and of `haven/rust_builder`, a real dependency
  of `tooling/e2e/local-relay`, and a real dependency of `tooling/soak`
  (the Tier-1 soak rig, which embeds it to build the hermetic relays it breaks
  on a schedule). It appears in four of the five audited lockfiles and is
  measured non-blocking: `cargo audit` returns rc 0 and counts it among its
  allowed warnings.

  **No `audit.toml` ignore, deliberately.** `cargo audit`'s ignore list has no
  expiry field, so an ignore is a silencing change with no end date and nothing
  that would ever bring it back for review. The controls instead are: the
  per-lockfile `cargo audit` step for every crate that resolves it (five steps
  in `audit.yml` since the soak crate landed), this row, and the residual
  recorded in `docs/SOAK_LANE.md`.

  **What lifts it:** `nostr-sdk` ≥ 0.45 subsumes the crate. The whole tree is
  pinned to 0.44 against MDK's pinned `nostr` types, so lifting this is a
  graph-wide bump, not a dependency edit. Nothing about it reaches a shipped
  build: the crate is a harness relay, and
  `scripts/ci/check_soak_test_only.sh` / `check_wire_proxy_test_only.sh` are
  what keep it that way.

### Resolved

- **RUSTSEC-2026-0225 / -0226 / -0227 / -0228 / -0229 / -0230** (`nostr`
  0.44.6) and **RUSTSEC-2026-0231 / -0232** (`nostr-relay-pool` 0.44.2) — a
  coordinated batch published 2026-08-01. Fixed by resolving `nostr` to 0.44.7
  and `nostr-relay-pool` to 0.44.3 in **both** lockfiles (2026-08-02); the
  declared constraints are caret `0.44`, so no manifest change was needed.

  Three are directly reachable from Haven's own inputs and are the reason this
  is not a routine bump:

  - **-0232, "Processing of unverified relay events"** (7.5) — Haven ingests
    relay events continuously (kind 445 group messages, 1059 gift wraps, 0/10002
    profile-plane reads). Anything a relay can hand back reaches this path.
  - **-0227, "NIP-44 v2 decryption permits resource exhaustion"** (7.5) — NIP-44
    v2 is the inner layer of the NIP-59 gift wraps carrying kind-444 Welcomes,
    so a hostile or malformed 1059 is a remote input. Same reachability argument
    as RUSTSEC-2026-0216 below, which is a recurrence of the same class.
  - **-0231, "Relay authentication challenges can exhaust memory"** (7.5) — any
    relay Haven connects to can send an AUTH challenge.

  The remaining three are not reachable here but were fixed by the same bump:
  -0226 (wallet event parsers) and -0225 (Debug output exposing NIP-46/NIP-60
  credentials) cover NIPs Haven does not implement — no remote signer, no
  wallet; -0229 (NIP-98 HTTP auth) is unused, Haven's Blossom authorization is
  kind 24242; -0230 (empty NIP-50 search filters) is unused, Haven issues no
  search filters; -0228 (NIP-04) is unused, Haven is NIP-44 only.

- **RUSTSEC-2026-0216** — `nostr` 0.44.2, remote DoS via a malformed NIP-44 v2
  payload (CVSS 7.5; the version was also yanked). Directly relevant: NIP-44 v2
  is the inner layer of the NIP-59 gift wraps Haven ingests from relays for
  kind-444 Welcomes, so a hostile or malformed 1059 was a remote input to the
  affected code. Fixed by resolving `nostr` to 0.44.6 in **both** lockfiles
  (2026-07-27).
- **RUSTSEC-2026-0049 / -0098 / -0099 / -0104** (`rustls-webpki` 0.103.9) and
  **RUSTSEC-2026-0009** (`time` 0.3.46) — TLS certificate/CRL validation flaws
  (incl. a reachable parser panic) and a stack-exhaustion DoS. These were
  present ONLY in `haven/rust_builder/Cargo.lock` — the resolution that ships in
  the app — while `haven-core` had already moved past them, and the audit job
  scanned only `haven-core`, so they were never reported. Fixed by updating that
  lockfile to `rustls-webpki` 0.103.13 / `time` 0.3.54, and the audit workflow
  now scans both lockfiles (2026-07-27).

## Network Threat Model

Haven does not implement network-level anonymity. Relay connections originate
from the user's real IP address, which a relay operator can correlate with
the pubkeys it sees publishing events. Users who require IP-level unlinkability
should run Haven behind a VPN.

Once a user saves a **public Nostr profile** (public-by-default; published on
save — see *Public Nostr Profiles* below), three additional exposures apply:

- **Blossom viewer-IP leak (incl. attacker-chosen host).** Downloading a
  member's profile picture contacts the Blossom host named in that member's
  kind-0 `picture` URL, revealing the **viewer's IP** to it. Because that URL
  is chosen by the member (i.e. attacker-controlled), a malicious member can
  point it at a host they operate and harvest co-members' IPs on every fetch.
  Haven bounds this with connect-time anti-SSRF IP filtering (loopback /
  RFC-1918 / link-local / ULA / multicast / unspecified rejected after DNS
  resolution, redirects disabled), but a legitimate-looking public host still
  sees viewer IPs — irreducible for public hosting; use a VPN.
- **Roster-association leak on fetch.** A relay serving profile fetches sees
  which pubkey set a client asks about. Haven batches the union of ALL known
  member pubkeys across all circles into one TTL-cached REQ on the AUTH-free
  discovery plane (never per-circle partitions, never circle relays, no
  standing subscription, no NIP-42 AUTH answer) — this blurs per-circle
  clustering and bounds request count, but does not eliminate the association
  leak.
- **Permanence.** A published kind-0 is effectively permanent: replaceable ≠
  erasable — indexers and archives keep revisions, and NIP-09 deletion is
  best-effort. The pubkey ↔ name/photo binding survives "delete".

## Security Architecture

### Database Encryption

Haven uses SQLCipher (encrypted SQLite) for all persistent databases. Encryption keys are stored in the system keyring:

- **macOS**: Keychain
- **Linux**: GNOME Keyring / KDE Wallet / Secret Service
- **Windows**: Credential Manager

| Database | Purpose | Service ID | Key ID |
|----------|---------|------------|--------|
| `session.sqlite` | MLS group state (Dark Matter `AccountDeviceSession`; WAL) | `com.oblivioustech.haven` | `mls.session.key.default` |
| `circles.db` | Circle metadata, contacts, memberships | `com.oblivioustech.haven` | `circles.db.key` |
| `tiles.db` | Encrypted map-tile cache | `com.oblivioustech.haven` | `tiles.db.key` |
| `haven_mdk.db` | **LEGACY** — pre-Dark-Matter MLS state, deleted at cutover | `com.oblivioustech.haven` | `mdk.db.key.default` (**LEGACY — destroyed at cutover**) |

All keys are 32 bytes of `OsRng` output. `circles.db` and `tiles.db` apply the
key raw (`PRAGMA key = "x'<64-hex>'"`, KDF bypassed). The MLS `session.sqlite`
key is provisioned differently (security F5): the keyring stores the raw 32
bytes, and Haven feeds their lowercase-hex encoding to the Dark Matter
`storage-sqlite` backend as a **SQLCipher passphrase** (`SqlCipherKey`), which
SQLCipher stretches through PBKDF2 (`cipher_compatibility = 4`) — a pure
defense-in-depth stretch over already-256-bit material. The passphrase is
`Zeroizing` end to end and never logged; `session.sqlite` runs **WAL** (the
legacy MLS DB was rollback-journal) with `secure_delete` and
`cipher_memory_security` (see `haven-core/src/nostr/mls/storage.rs`).

**Dark Matter cutover secure-erase (security F6).** The pre-Dark-Matter
`haven_mdk.db` has no importer: at cutover Haven deletes the old database files
(plus their WAL/SHM/journal sidecars) AND destroys the `mdk.db.key.default`
keyring entry (`destroy_legacy_mls_state`, backed by
`destroy_legacy_mls_key_material`). Unlinking alone is NOT a secure erase — the
old DB was not written with `secure_delete`, and flash wear-levelling leaves
residual ciphertext — so **destroying the key is the practical secure-erase**
for the abandoned SQLCipher database.

Existing unencrypted `circles.db` files are automatically migrated to encrypted
storage on first access via SQLCipher's `sqlcipher_export()` function.

**Linux requirement**: A D-Bus Secret Service provider must be running
(GNOME Keyring, KDE Wallet, or KeePassXC). Without one, circle
operations will be disabled with a descriptive error.

**iOS keychain accessibility (owner-approved tradeoff)**: On iOS the SQLCipher
DB keys (`mls.session.key.default`, `circles.db.key`, `tiles.db.key`; formerly
also the legacy `mdk.db.key.default`, destroyed at the Dark Matter cutover) are
stored with `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` rather than the
keyring library's default `kSecAttrAccessibleWhenUnlocked`. The default makes a
key readable *only while the device is unlocked*, so a background wake while the
device is locked cannot read the key, cannot open the encrypted database, and
location publishing fails silently. `AfterFirstUnlockThisDeviceOnly` makes the
keys readable after the first post-boot unlock — the minimum accessibility that
permits locked-device background location publishing.

- **`ThisDeviceOnly`**: the keys are never iCloud-synced and never migrate
  off-device (no backup/restore to another device).
- **Migration is delete-then-add, made crash-safe with a backup**: re-setting a
  value on an existing keychain item does not change its `kSecAttrAccessible`, so
  each key is migrated once by reading its bytes, deleting the item, and
  re-creating it with the new accessibility. Delete-then-add has a window in
  which the key exists in neither form, and for the MLS key that loss would be
  catastrophic (orphaned encrypted state). To close that window the migration
  stages a **backup** copy of the key (sibling id, same access policy) *before*
  deleting the original, and on the next launch recovers the primary from any
  stranded backup — so at every instant at least one copy holds the bytes and an
  interrupted migration is always recoverable. On an outright re-create failure
  the original bytes are restored immediately. A guard ("marker") entry makes the
  migration idempotent. See `haven-core/src/keyring_policy.rs`. This is a no-op on
  every non-iOS target; macOS/Linux/Windows/Android keychain behavior is
  unchanged.
- **Narrowed seized-device caveat (owner-approved)**: under
  `WhenUnlocked`, re-locking the device re-protects the key so a seized locked
  device could not surrender it. Under `AfterFirstUnlockThisDeviceOnly`, a
  still-powered-on device that has been unlocked at least once since boot can
  have the OS surrender the DB key *while locked*. A device that has been powered
  off (and not yet unlocked since boot) keeps the key sealed. The user explicitly
  approved this tradeoff to enable locked-device background location sharing.

### Sync-state at rest + account-wipe on logout (M10)

The relay live-sync bookkeeping — the persisted receive **cursors** (`sync_cursors`)
and the gift-wrap **dedup set** (`processed_gift_wraps`) — lives **only** inside the
SQLCipher-encrypted `circles.db` (or in memory), never in plaintext
`SharedPreferences`/Hive. A dedicated at-rest test
(`haven-core/tests/sync_state_at_rest_test.rs`) writes high-entropy sentinels to
these tables and byte-scans the DB file **and every sidecar** (`-wal`/`-shm`/
`-journal`) to prove nothing spills in the clear, before and after the handle is
dropped.

The dedup set is **bounded and aged**: rows older than
`PROCESSED_GIFT_WRAP_RETENTION_SECS` (the inbox gift-wrap lookback + 48 h ≈ 9 days,
compile-time-asserted to exceed the lookback) are pruned, with a hard row cap of
`MAX_PROCESSED_GIFT_WRAPS = 10_000`. Pruning runs opportunistically on foreground
and on background wake.

**Wipe-on-leave**: `delete_circle` removes the left group's `sync_cursors` row and
all of its `processed_gift_wraps` rows in the same transaction as the circle delete.

**Wipe-on-logout leaves no decryptable data at rest.** Deleting the identity
tears down all MLS state: it deletes the MLS `session.sqlite` and `circles.db`
files **and removes their keyring keys** (`mls.session.key.default`,
`circles.db.key` — so neither the ciphertext nor the key survives), after
resetting the sync cursors. (Any legacy `haven_mdk.db` + `mdk.db.key.default`
residue is already gone via the one-time cutover erase above; the pre-Dark-
Matter staged-commit markers no longer exist — the engine's typed pending-state
lifecycle replaced them.) A
one-way `_wiped` latch on the circle service closes a re-open race: the M8
maintenance timers run on their own cadence regardless of the live-sync engine
(LIVE by default since M11, but stopped before the wipe on logout — see the
`deleteIdentity` stop-before-wipe ordering), so a maintenance tick could
otherwise call into the circle service *after* the wipe and cause SQLite to
re-create a fresh, decryptable `circles.db` + a fresh keyring key. The latch refuses any re-open once logout has
begun; a re-check after the DB-open FFI and a drain of any in-flight open ensure
the wipe deletes whatever a racing open created, so no decryptable database can
be resurrected. The latch is per-instance and the service is a rebuilt-on-login
provider, so a subsequent login is unaffected.

### Scheduled background wakes (M7)

Since M7-E, Haven schedules OS background wakes so a backgrounded/killed device
can catch up on missed circle updates without a foreground session. The wake
triggers differ per platform: **Android** — a WorkManager periodic task, which
the OS runs at most every ~15 minutes (subject to Doze/battery); **iOS** —
Significant-Location-Change relaunch (movement-triggered) plus a
`BGAppRefreshTask` floor (OS-discretionary timing). No push/FCM/APNs is used —
that is an intentional privacy choice (a push gateway learning every peer's
wake timing is strictly more metadata than a relay; the M7 architecture rejects
it, enforced by a CI guard).

Each wake is **receive-only and consent-gated**:

- A wake invokes only the receive-only sweep (`run_catchup_all_circles`), which
  never authors MLS state.

  *Corrected 2026-08-03:* this bullet previously said the sweep takes a
  "process-global `WRITER_LOCK` via `try_acquire_background()`", yielding to any
  authoring writer. **No such symbol exists** in `haven-core/src` or
  `haven/rust_builder/src` — it was superseded at Dark Matter, and the
  description outlived it here and in
  `haven/lib/src/services/background_catchup_worker.dart`.

  The live mechanism is the Rule-14 `LiveSessionGuard`
  (`haven-core/src/nostr/mls/storage.rs`), and it behaves **oppositely**: it
  fails CLOSED rather than yielding. A background wake that races a live
  foreground/FGS session does not queue behind it and does not skip politely —
  its `CircleManagerFfi::new` throws and the wake accomplishes nothing. The
  fork-safety conclusion still holds (a wake can never author against a
  concurrent writer, because it cannot open the session at all), but the
  mechanism, the failure mode, and the operational consequence are all
  different from what was written.
- Background wakes run only while the user's durable background-sharing consent
  is set: the intent is re-checked at every wake (the Android worker's gate
  chain / the iOS `isEnabled()` predicate) and again inside
  `CatchupService.runCatchup(isBackgroundWake: true)` before any relay contact;
  a wake with consent off (or no identity) makes zero relay connections. The
  compile-time `backgroundCatchupEnabled` flag is additionally re-checked first
  on every Android wake, so a rolled-back build no-ops even a
  previously-registered task.
- A wake that races a logout is fail-closed: a set pending-MLS-wipe marker (or
  an unreadable one) declines the wake before any DB open, and the bootstrap
  loads the identity and bails on a missing one *before* opening `circles.db`,
  so a post-logout wake cannot resurrect (or freshly create) a decryptable DB.

Per-wake relay connections here are short-lived (one sweep, then shutdown) —
this is the **no-foreground-service** background path (receive-only OS wakes),
distinct from the live-sync engine's *standing* connection. That engine (the M6
live-sync engine, LIVE by default since M11) keeps its socket up in the
**foreground** and nowhere else. On **iOS** with background sharing on it no
longer holds one through the backgrounded period either — since the P4 power
phase it is PAUSED between publishes and each publish tick opens one bounded
burst, so between bursts it holds no standing REQ and no socket it asked for
(the crate's own retry loop can still re-open one, which the radio-off watch
cuts and counts — see "iOS background sharing: presence only at publish
instants (P4)" below); with
background sharing off the pause STOPS it, as Android's does. On **Android** it
holds none while backgrounded, in either toggle state: with
background sharing **ON** pausing the app stops the engine before handing the
MLS session to the foreground service (`MapShell._handOffMlsSession`), and the
service isolate never opens an engine socket of its own; with background sharing
**OFF** the pause path stops it through `MapShell._stopLiveSyncBounded()`
without releasing the Rule-14 guard, since no isolate reclaims the session in
that state. Both are selected by the one rule
`MapShell.shouldStopLiveSyncOnPause`. So on Android these short OS-wake sweeps and — with
sharing on — the service's own per-cycle poll are the whole of the backgrounded
receive path, and the engine socket no longer waits for the OS to freeze the
process. The publish client is a separate socket, closed on the same pause path
(`MapShell._shutdownPublishPool` →
`NostrRelayService.shutdown` → `RelayManager`, not the engine's
`build_engine_client`); since P1 it also carries no keepalive and sleeps between
publish bursts. (Symbols, not line numbers: every line
citation this paragraph used to carry had drifted by hundreds of lines.) The
engine's persistent-connection model is disclosed separately under
**"Persistent receive connection (live-sync engine)"** in the
relay-observable-metadata section below. Wake markers logged
for diagnostics are presence-only (fixed strings + counts) — never coordinates,
pubkeys, group ids, or event ids.

The iOS keychain accessibility tradeoff that lets a locked-but-unlocked-since-
boot device read the SQLCipher key during a background wake is documented under
*Database Encryption* above (owner-approved, `ThisDeviceOnly`, never synced).

### Test-Utils Feature

The `test-utils` feature enables keyring-free test storage. (For the MLS DB the
Dark Matter backend always encrypts: `SessionManager::new_unencrypted` opens a
temp SQLCipher DB under a fixed test passphrase — the "unencrypted" name is
historical API continuity; `circles.db` test paths remain truly unencrypted.)
This feature:

- Is gated with `#[cfg(any(test, feature = "test-utils"))]`
- Produces a compile error if enabled in release builds
- Should NEVER be enabled in production

### MLS Security

Haven implements the Marmot Protocol (v2, Dark Matter engine) for MLS over
Nostr. Key security properties:

1. **Key Separation**: MLS signing keys are separate from Nostr identity keys —
   formalized on-wire as the mandatory `marmot.account-identity-proof.v2` MLS
   leaf extension (`0xF2F1`): a canonical kind-450 event signed by the identity
   key, binding identity pubkey ↔ MLS leaf signature key (see the rebroadcast
   threat note below)
2. **Ephemeral Keys**: Each group message uses a new keypair
3. **Forward Secrecy**: Provided by MLS epoch rotation
4. **Memory Safety**: Secrets use `Zeroizing<T>` for automatic memory clearing
5. **Single-session invariant (Rule 14) — a confidentiality control**: at most
   ONE live `AccountDeviceSession` per MLS DB file across all isolates and
   processes. The engine hydrates authoritative epoch state into memory at
   open; two live sessions diverge in-memory and risk **epoch/exporter-key
   reuse and forward-secrecy erosion** — a confidentiality loss, not merely DB
   corruption (`storage-sqlite` takes no OS-level file lock to save you).
   Enforced structurally: the only `AccountDeviceSession::open(` call site in
   the tree is `SessionManager::open_session` (guard test
   `single_account_device_session_construction_site`), and background catch-up
   reuses the one process-global session rather than opening a second one.

#### Identity-proof rebroadcast (kind 450) — irreducible, by design (F12)

Every MLS leaf Haven produces embeds the `marmot.account-identity-proof.v2`
extension: a canonical kind-450 Nostr event (`created_at = 0`) Schnorr-signed by
the user's Nostr **identity** key, binding the identity pubkey to the MLS leaf
signature key. Haven never publishes this event to relays — but **any co-member
can extract the proof from the ratchet tree and rebroadcast it**, publicly and
verifiably binding the user's Nostr pubkey to MLS participation. This is
irreducible: co-members necessarily see the credential to validate the group,
and the proof is self-authenticating wherever it lands. Accepted; it discloses
only *that* the pubkey participates in Marmot MLS — never message content,
group membership sets, or location data.

#### Convergence-buffer flooding (upstream #757 — OPEN)

The Dark Matter engine persists out-of-order / future-epoch inbound messages in
a durable stored-convergence buffer that currently has **no per-group cap and
no eviction API**. A malicious co-member can flood a group with future-epoch
messages and grow the on-device `session.sqlite` without bound. Haven mitigates
at intake with rate-limit-plus-backpressure (Security Rule 12 — never a silent
drop, because future-epoch catch-up after an offline period is legitimate
backlog), but an intake cap only throttles: once a message is ingested the
engine owns its durable storage, so Haven **cannot bound engine storage**.
Closure of upstream #757 is the real fix; until then this is an accepted
insider-threat storage-DoS exposure.

#### Publish resolution: what the engine replays, and what Haven owes it

Rule 12's "never silently drop legitimate backlog" has a second edge, and it is
not on the intake side. Between staging a commit and resolving it the engine
BUFFERS everything that arrives for that group, and both resolutions —
`confirm_published` and `publish_failed` — end in the engine's replay. That
replay is delivered **at most once**: the engine marks the content row processed
in the same breath as handing it to the application, with no acknowledgement
boundary, so every redelivery afterwards is terminal. A caller that resolved the
ref and discarded the batch lost the peer's position permanently — no re-fetch,
no later convergence pass and no restart brings it back. Haven therefore
persists inside the call, before the resolution returns, and keys the write off
each event's own group id because the engine's buffers are process-global and
one batch can span circles. The same replay carries the next eviction in a leave
cascade and the local user's own re-proposed leave, so publish work is folded
back into the plane's own Rule-13 ladder rather than dropped; an `Err` from a
confirm is returned unchanged after the stranded buffer is drained, because at
this pin the merge precedes the replay and a retry or a rollback would act on a
commit the group may already hold. Contract and evidence:
`MARMOT_PROTOCOL_KNOWLEDGE.md`, "What a resolved publish hands back".

**Accepted residuals.** Each is stated where the code makes it, and none is
optional to record:

- **A send-path co-drained eviction commit is recorded as owed, not handed to
  the caller, and `redeem_removal_deferrals` is its ONLY recovery.** A send
  drains the same global publish buffer, so it can surface an `AutoPublish` it
  was not after — always for a DIFFERENT circle, because a same-circle staging
  puts the group in `PendingPublish` and the send comes back `Queued` down the
  deferred branch instead. Haven records the obligation
  (`CircleManager::surface_co_drained_auto_commits`) and leaves the commit
  staged rather than dropping a live `PendingStateRef`, which is what keeps the
  removal from going silent.

  It is not surfaced across the FFI, and **that circle's next send does not
  recover it**: the send does come back `SendDeferred`, but
  `CircleManager::collect_deferred_work` reads only that call's own publish
  vector, and the engine never re-emits the `AutoPublish` — the schedule entry
  is consumed before staging and `publish_failed` does not re-arm it, which is
  the same fact `CircleManager::orphaned_removal_deferrals` is built on. The one
  production driver is
  `EngineProcessor::redeem_removal_deferrals`, gated on a FOREGROUND live-sync
  open.

  So: in the Android foreground service and the iOS burst the in-memory ref dies
  with the isolate while the durable row survives, and the next foreground
  live-sync open reports the circle — honest, not silent. In a
  `HAVEN_LIVE_SYNC=false` build **neither the redeemer nor the reporter is
  compiled in**: that circle is left unsendable, owed and unreported beyond the
  generic "sharing is stalled" signal its own publish cycle raises. It cannot
  manufacture a false report — the obligation is only recorded for a commit the
  engine has genuinely staged, so the circle really cannot send, and a circle
  that recovers clears the row on its next successful send or on an
  `EpochChanged`. It is still a strict improvement on the behaviour it replaced,
  which dropped the ref with no durable row at all and left the wedge invisible
  everywhere. Closing it means widening `encrypt_location`'s FFI return with the
  commits it collected.
- **A send drain still drops the engine's RESYNC signals.**
  `PendingCommitRecovered` / `GroupHydrationRecovered` arriving in a send's own
  batch get a bucketed note (`note_dropped_resync_events`) and are not surfaced,
  even though Rule 13 calls the first a MANDATORY resync. The reviewed plan for
  this work specified deleting that function once the fold surfaced the events;
  it was kept instead, because surfacing them means widening
  `encrypt_location`'s FFI return for a signal the RECEIVE path already drives
  authoritatively — catch-up runs first after every open and folds both events
  to a `GroupUpdate`. The deviation is recorded here and at the function itself;
  the same FFI widening closes it.
- **A sender-declared `timestamp` is still not bounded from above; only its
  RANK is.** Nothing constrains the instant a peer stamps inside the ciphertext,
  and Haven deliberately keeps it verbatim — clamping what is stored would
  discard an honest, legitimately clock-skewed peer's own data (**owner
  decision**). What changed is the newer-wins guard it used to drive. A fix now
  ranks by `min(timestamp, updated_at)` — the sender's reading bounded above by
  the instant THIS device received it, ties breaking on the raw `timestamp` —
  in the `last_known_locations` upsert (`circle/storage.rs`) and, identically,
  in the Flutter in-memory cache; the two must agree, or the next hydration
  moves the marker to a fix one layer rejected. The cache asks that in two
  shapes: an ARRIVING fix against a cached row uses `MemberLocation.outranks`,
  the `WHERE` clause's mirror, while two rows that have BOTH already been
  ranked — the hydration case — use `MemberLocation.isFresherThan` and compare
  recorded ranks. The distinction is load-bearing: raising a stored
  future-dated row's ceiling to the other row's later receipt at hydration ties
  the two and lets the inflated reading win the tie-break, handing the pin
  straight back.
  The ceiling is monotonic per row (`max` of the two receipt instants) because
  the RECEIVER's clock can step back too, and a ceiling taken from the arriving
  fix alone would then discard the peer's whole stream until it recovered —
  permanently, since the engine delivers each message at most once.
  So what **now holds**: an hour-ahead fix ranks at its ARRIVAL, so a fast or
  hostile clock can no longer pin a marker for the length of its skew.
  Ranking by arrival ALONE would have been wrong the other way — the
  convergence replay delivers genuinely old fixes late, and one would overwrite
  a fresher live row — which is why the sender's reading still decides whenever
  it is in the past. Each of the rule's three elements — the ceiling, the
  sender's reading, and the ceiling's monotonicity — has a mutation that the
  other two pins survive:
  `last_known_upsert_takes_an_honest_fix_after_a_future_dated_one`,
  `last_known_upsert_ignores_a_replayed_old_fix_received_later` and
  `last_known_upsert_survives_a_receiver_clock_stepping_backwards`.
  What does **NOT** hold, and the list is not closed:
  - The pin is bounded by a DELIVERY LATENCY, not by nothing. A fix only
    outranks the poisoned one if it was CAPTURED after the poisoned one
    ARRIVED, so the poisoned position holds for however long that round trip
    took: up to a fetch interval in poll mode, and after a replay, however
    late the replay was. For a one-off future-dated fix it is therefore not
    "the peer's next fix" that displaces it but the first fix captured after
    that arrival. (Sub-second resolution would not change this; `updated_at`
    being second-resolution only affects the same-second tie, which the
    `timestamp` tie-break already resolves in the peer's favour.)
  - A skewed peer's own marker can move BACKWARDS by up to the skew. Once the
    future-dated row's rank is pulled down to its arrival, ANY later-arriving
    fix from that peer with a `timestamp` between that arrival and the inflated
    reading displaces it — including a genuinely older one. This is inherent to
    the owner's decision: once a sender's claim is untrusted there is no
    trustworthy order between it and that sender's other claims.
  - Under a backward step of the RECEIVER's clock the surviving row is
    order-dependent: A(ts 100, received 100) then B(ts 110, received 50) ends
    on B, while B then A ends on A. Bounded by the size of the step and
    self-healing once the clock passes the stored receipt again, and the cache
    and the store stay in agreement throughout — they evaluate the same rule on
    the same pair — so what varies is which of two near-contemporaneous fixes
    is shown, never whether the two layers hold different ones.
  - A skewed peer's own marker still reads as freshly seen for as long as their
    clock leads, because the display buckets a negative age into the same
    untagged bucket as a fresh fix (`kMemberAgePillThreshold`,
    `widgets/map/member_marker.dart`) rather than rendering a wall-clock
    reading of somebody else's device as "-59m".
  - Sender-controlled RETENTION is not bounded at all: `expires_at` /
    `purge_after` derive from the same unbounded `timestamp`, so a future-dated
    fix lingers in the cache and the store longer than an honest one.

  Do not describe the rank bound as a defence against any of these.
- **A drained `GroupEvolution`'s welcomes are not published.** `CommitToPublish`
  carries no welcomes, so a queued invite released by a convergence drain hands
  back a commit whose invitees receive nothing. Pre-existing in
  `CircleManager::collect_deferred_work`; the fold now emits a bucketed warning
  every time it happens rather than letting it be silent, pinned by
  `security_rule_gates::drained_group_evolution_welcomes_are_never_dropped_silently`.
- **The publish-resolution fold's BATCH cap is unreachable in production, so its
  disposition is driven in-crate rather than end to end.** `MAX_FOLD_BATCHES`
  bounds how many engine batches one fold GENERATES work from; reaching it needs
  33 groups in a single `pending_convergence` drain, and nothing accumulates
  them: `collect_effects` empties that buffer on the way out of every engine
  call, and the only scheduler a publish resolution reaches
  (`replay_buffered_messages`) is single-group. The stored-message write fault
  does not accumulate them either — it breaks the terminal row write of an
  application-message ingest, which schedules no convergence. Measured over the
  whole suite, a fold walks at most three batches and spends at most one
  re-tick. The disposition is therefore pinned where the fold can be handed its
  batch directly, by
  `circle::manager::tests::the_batch_cap_stops_generating_without_dropping_what_it_holds`:
  crossing the cap stops the advances and the re-ticks and nothing else, so a
  batch already handed back is still folded, its eviction still surfaced with
  its obligation recorded, and its replayed locations still persisted. What that
  test does NOT cover is the Rule-15 capture of the cap's own warn — the fold is
  private, so no integration test can reach it, and the library test binary's
  single `log` slot belongs to `relay::manager`'s capture; the warn interpolates
  nothing but a bucketed count and is covered statically by
  `scripts/ci/check_no_identifier_logging.sh`. The identical disposition on the
  pass that has a publisher (`MAX_REDEMPTION_STEPS`) IS driven end to end, and
  the fold's cap loses no schedule: the groups that never got their advance keep
  theirs in the engine, which re-marks them pending on the next advance. Both
  caps name what they stand down from in their own warn rather than stopping
  silently.
  The receive LADDER's cap (`RESOLVE_RUNAWAY_CAP`) is tested end to end —
  through many small circles rather than a deep cascade, because it bounds the
  WORK one call does and a k-deep cascade costs O(k³) in the harness (measured:
  116 s at nine leavers, past fifteen minutes at seventeen). That measurement is
  recorded in `haven-core/tests/receive_ladder_e2e.rs` beside the test it shaped.
- **The cursor stays pinned behind the row the replay does not retire.** An
  MDK-side residual, recorded in `MARMOT_PROTOCOL_KNOWLEDGE.md` beside #757.

### Post-Compromise Security window from polling cadence

Since M11 (live-sync enabled by default) Haven holds a **persistent foreground
receive connection**: evolution events (kind:445 Commits and Proposals) arrive
over a live subscription in **sub-second** time rather than on a poll timer, so
the evolution-receive term of the window below collapses to the publish term
alone (`T_pcs ≈ δ_max`). The figures in this section describe the
**retained short-poll fallback** (`liveSyncEnabled = false`, the ≥1-release
rollback path; see `docs/M11_ROLLOUT.md` §8 and
`haven/lib/src/pages/map_shell.dart`), where evolution events (kind:445 Commits
and Proposals) are polled on a 60-second timer with a 55-second overlap guard.
The publish term is the same on both paths — coalescing is in the scheduler, not
in the receive plane. A remaining member's publishes into one circle arrive on
the jittered cadence documented above (uniform on `[72, 168] s`) **plus the
burst-position differential** since `PUB-COALESCE`: one coalesced burst
publishes every eligible circle, so a circle that leads one burst and trails the
next waits up to one `kPublishStaggerMaxSpread` (30 s) longer. That is the
no-gap invariant's `δ_max = 198 s` for a roster of at most `kMaxCirclesPerBurst`
(11) circles, and it would grow with the deferral past that (the service-period
figures under "The no-gap invariant" — 366 s scheduled worst at N ≤ 22). Since
`kMaxCirclesPerAccount` (10) bounds the roster below the burst cap, the 198 s
figure is the actual worst case rather than a case among several.

Consequence: after an admin issues a removal Commit, a removed member
can still derive the decryption keys for the **outgoing epoch** until
at least one remaining member processes the Commit and publishes a new
location under the new epoch. The worst-case window is approximately:

```
T_pcs ≈ T_evolution_poll + δ_max ≈ 60 s + 198 s ≈ 258 s     (N ≤ 11 circles)
```

The `168 s` this term used to carry was the publish-interval ceiling alone,
which stopped being the worst case at `PUB-COALESCE`. Past eleven circles the
deferral would push it further, in the same steps the no-gap invariant
enumerates — a roster the account bound refuses, so `258 s` is the worst case
and not a rung.
Typical case is closer to `T_evolution_poll/2 + T_publish_jitter_mean +
E[burst offset] ≈ 30 s + 120 s + a few seconds ≈ 150 s` — the burst offset is a
mean of ≈ 2.5–5.5 s per intervening gap, so it moves the typical figure by
seconds and the worst case by the whole spread.

During this window a removed member who continues to receive kind:445 events
(e.g., from a relay they already know) can decrypt locations published before
the remaining member's epoch transition lands.

What this provides (mitigations in place):

- The removed member loses access on the next epoch transition,
  bounded by `T_pcs` above — they cannot decrypt indefinitely.
- As of M5, periodic self-update is disabled, so a group with NO
  membership change does not re-key on a timer — stale leaf material is
  only rotated by a real membership change. See "Self-update disabled
  (M5)" below for the accepted forward-secrecy deviation.

What live-sync now provides (M11), inverting the prior limitation:

- **Sub-second post-removal cutoff (foreground).** With the persistent
  subscription Haven now holds in the foreground, the receive term of `T_pcs`
  tightens to seconds — a removed member's stale-epoch access ends as soon as a
  remaining member's post-removal location lands, not up to a poll interval
  later. The classic mobile-WebSocket trade (cellular NAT / iOS suspension /
  Android Doze silently break long-lived sockets; sustained foreground service
  on Android) is accepted and mitigated: the M7 catch-up sweeps + the persisted
  receive cursor make both the flag-off fallback and the backgrounded case
  **lossless** (eventual-on-next-foreground, nothing dropped), and on iOS with
  background sharing on the backgrounded receive term is one bounded burst per
  publish tick rather than a held socket, so the receive term there is the
  publish cadence (72-168 s) plus the burst, not sub-second, and Haven
  deliberately takes **no** APNs/FCM third-party push (M9 deferred). The
  `T_pcs` figures above are the retained-fallback bound.

Mitigation options not currently applied:

- Tightening the evolution poll interval from 60 s to e.g. 30 s halves
  the polling component of `T_pcs`. This is a security-meaningful but
  product-level trade-off (network-frequency vs PCS window).
- Event-driven boost: after the local user issues a removal Commit,
  poll evolution at a tighter cadence (e.g. 10–15 s) for a short window
  to confirm propagation before considering the removal effective.

### KeyPackage consumption race from invitation polling cadence

Since M11 (live-sync enabled by default) Welcome events (gift-wrapped
kind:1059 wrapping kind:444) arrive over the inbox `#p` live subscription, so
foreground invitation discovery is **live** (no periodic-arrival pattern; the
presence signal is the socket, not a poll). Two bounds on that, both landed
since: the 7-day gift-wrap lookback is now the **cold-start** window only — every
REQ made against a persisted cursor asks for `INBOX_RESUBSCRIBE_LOOKBACK_SECS`
(2 days + 1 hour), sized to NIP-59's 48 h backdating plus an hour of clock skew —
and backgrounded on **iOS** the inbox REQ rides every `INBOX_BURSTS_PER_REQ`-th
publish burst rather than a held socket, so an invitation is picked up at a
publish instant. An account with nothing publish-eligible has no publish
instants, so its invitations arrive on the next foreground; both are stated under
"iOS background sharing: presence only at publish instants (P4)" below. The 2-minute figure below is the **retained short-poll fallback**
(`liveSyncEnabled = false`): there, Welcome events are polled on a 2-minute
foreground timer, the resume hook in `map_shell.dart` performs an immediate
fetch on app foregrounding, and background polling is not active on either
platform — invitation discovery is foreground- or resume-driven only.

MIP-00 single-consumption KeyPackages (without the `last_resort`
extension) admit a race where two inviters consume the same KeyPackage
before the invitee can rotate. The post-Welcome rotation in MIP-02 is
designed to close this window; longer invitation polling enlarges it
proportionally because the invitee's rotation lags processing of the
Welcome.

Fallback foreground worst-case (`liveSyncEnabled = false`): ~2 minutes between
Welcome publish and local rotation if the user is foregrounded but not actively
resuming; cold-start latency is bounded by the resume hook (sub-30 s). Under
live-sync the Welcome is delivered live, so this consumed-KeyPackage window
shrinks to delivery + processing latency (seconds).

Mitigation and residual (M5):

- As of M5, Haven issues NO post-accept or periodic self-update (see
  "Self-update disabled (M5)" below). The MIP-02 post-Welcome rotation
  that would close the consumed-KeyPackage window is therefore NOT
  performed. The forward mitigation — `last_resort` KeyPackages, which are
  not single-consumption — **landed at the Dark Matter cutover**: every
  KeyPackage Haven now mints is marked `last_resort`, so a welcome consuming
  it no longer deletes its private material and the consumed-KeyPackage race
  above is structurally closed (the described residual is historical for
  pre-cutover clients).

### Self-update disabled (M5) — accepted MIP-02/MIP-03 deviation

Haven disables BOTH periodic (MIP-03 SHOULD) and post-join (MIP-02 MUST,
24 h) leaf-key self-update (`enablePeriodicSelfUpdate = false`).

Rationale (Haven's own — NOT attributed to White Noise): Nostr provides no
commit-serializing Delivery Service, so leaderless self-update is the
dominant generator of MLS epoch forks — two members rotating from the same
epoch and each eagerly merging their own commit diverge permanently.
Removing the periodic/post-join driver removes that generator.

**Residual fork surface (closed for membership commits since M11):** concurrent
MEMBERSHIP commits by multiple admins from the same epoch were a fork risk while
add / remove / demote eagerly finalized on publish-success. The adopt-winner
convergence is the fix — since the Dark Matter migration it is **engine-owned**
(deterministic `CommitOrderingKey` branch selection inside the MDK engine
replaced Haven's hand-rolled `converge_commit` + M6 settle-window, both
deleted) — and since M11 (live-sync enabled by default) it takes production
effect: add / remove / demote finalize through the publish-then-confirm
converging path, so a same-epoch multi-admin membership race deterministically
adopts the protocol winner instead of forking. A leave is a
`SelfRemove` **proposal** (not a self-finalized commit); it converges on the
receiving admins' side via the REV-1 drivers, which harden the distributed
`SelfRemove` case (see "Bounded leave-removal window under live-sync" and
"Superseded commit during multi-admin convergence" below). Two scopes remain out
of this: **self-update** commits, which stay disabled entirely
(`enablePeriodicSelfUpdate = false`, this section) so they generate no fork; and
the **retained short-poll fallback** (`liveSyncEnabled = false`), where the
convergence primitive is compiled but the eager-finalize paths run — a rollback
build reopens the same-epoch membership-race window until it is flipped back.

Accepted cost (forward secrecy / post-compromise security): a member's
leaf key material is re-keyed only by a real **membership** change
(add/remove/leave), never by a self-action. Consequences:

- A joiner keeps the leaf/init key material from the adder's Welcome until
  the next membership change.
- If a device is compromised and its current-epoch leaf secret leaks, the
  attacker can derive every FUTURE epoch's secret until a membership change
  re-keys the group — the exposure window is "until next membership churn",
  not the ~1 h the periodic rotation provided. The 5-epoch exporter-secret
  prune does NOT rotate the leaf key, so it does not bound this.

Accepted by the project owner; the fork-safety precondition for reverting is
now met by the engine-owned convergence (Dark Matter branch selection makes
concurrent self-updates converge deterministically) — re-enabling remains an
owner decision (flip `enablePeriodicSelfUpdate`).

Inverse risk (documented, bounded by M7): a burst of >5 membership changes
while a device is suspended could advance the group past
`DEFAULT_MAX_PAST_EPOCHS` (5; the Dark Matter engine's past-epoch retention,
formerly named `DEFAULT_EPOCH_LOOKBACK`) for that device, leaving in-flight
kind:445 **application messages** at the aged-out epoch undecryptable. (Under
the Dark Matter engine future-epoch commits are buffered and replayed, so the
group state itself recovers; only the aged-out epoch's application messages are
lost.) M7's catch-up bounds the offline epoch lag.

### Bounded leave-removal window under live-sync (REV-1)

> **Dark Matter update (2026-07-17).** The window mechanics below describe the
> pre-migration Haven-side implementation. At the Dark Matter cutover the Haven
> settle-window layer was deleted: same-epoch concurrent commits now converge
> inside the MDK engine via deterministic `CommitOrderingKey` branch selection
> with `settlement_quiescence_ms = 0` (no settle delay), and a peer's
> `SelfRemove` proposal is auto-committed by every remaining member's engine
> (`PublishWork::AutoPublish`, confirmed only on a ≥1-relay OK-ack per Rule
> 13). Driver 1 is therefore engine-owned and stronger — no windowed deferral
> exists anymore — while Driver 2 (the leaver's `still_a_member` backstop with
> the durable resume marker) is retained. The bounded-window guarantee and the
> residual analysis below still hold; the "~8 s settle window" is historical.

This section applies when the live-sync engine is enabled — the **default since
M11**. Only in the retained short-poll fallback (`liveSyncEnabled = false`) are
leaves unaffected by REV-1 and this window does not exist.

Under live-sync a foreground membership commit opens an ~8 s "settle window"
during which concurrent same-epoch commits are collected so the MIP-03 winner is
deterministically adopted instead of forking (see "Superseded commit during
multi-admin convergence (M6)" below). A departing member publishes its leave as
an MLS `SelfRemove` proposal; if that proposal lands inside a remaining member's
open settle window it is deferred rather than committed immediately. Left
unconverged, a race-losing `SelfRemove` would strand the leaver in the roster.

REV-1 converges the deferred leave within a bounded window via two drivers:

- **Driver 1 — redundant non-windowed commit.** The `SelfRemove` is delivered to
  every member, but only those with an open settle window for that circle defer
  it. Any member NOT in a window processes it normally and auto-commits it —
  fully MLS-signature-verified — into a removal commit. That removal commit
  actually evicts the leaver only if it WINS the MIP-03 concurrent-commit order
  race against the non-removal commit that opened the window (the membership op
  the deferring member published early). When the non-removal commit wins —
  which needs only a single pre-windowed member, and is therefore common in the
  racing case — the leaver is not removed on this pass and the now-epoch-stale
  `SelfRemove` is dropped everywhere; convergence falls to Driver 2. (The same
  happens when EVERY member is windowed at once and none auto-commits.) Either
  way the group deterministically stays on ONE branch — no fork.

- **Driver 2 — leaver backstop (the primary converger for the racing case).**
  After publishing, the leaver polls its own membership (`still_a_member`) and,
  on each poll where it is still a member, re-issues a FRESH `SelfRemove` until
  it observes its removal — bounded to a small budget, after which it wipes its
  key material regardless. A fresh `SelfRemove` is a new-epoch proposal, so any
  receiving member auto-commits it once the competing window has cleared — this
  is what actually removes the leaver in the common racing case above, not just
  the all-windowed corner. The re-issue is gated on the identity still existing
  (a concurrent logout aborts it, so no MLS state is written against a wiped
  identity). The leave intent is DURABLE — a marker in local `SharedPreferences`
  holding only the circle's public `nostr_group_id` (never the MLS group id, a
  pubkey, or secret material) — so a leaver killed mid-backstop resumes and
  finishes the leave on its next launch.

Net effect: a race-losing leave is converged within a bounded window (seconds to
tens of seconds — driven by Driver 2 in the common racing case) rather than
lingering unbounded.

**Precisely-bounded residual (accepted).** The corroboration-gate carries NO
admin-side record of a departing member's intent (it deliberately never acts on
the peeked, unauthenticated `SelfRemove` sender, which closes a forged-removal
vector), so there is no automatic admin-side backstop: a stale ghost is
recoverable only by a normal manual admin removal. The single
automatically-unconverged case is the conjunction of ALL of: the leaver crashes
mid-leave, AND its `SelfRemove` was deferred or lost the order race on the
remaining members, AND the leaver never re-opens the app (so the durable resume
never runs). Only then does a stale roster ghost remain until an admin removes
it. This is not a confidentiality regression for peers: the ghost is a
departing, trusted, non-adversarial member who stays authorized until removed —
exactly the posture of a member who had not yet chosen to leave — so no
forward-secrecy property is weakened for anyone else. It is net-positive versus
the unbounded ghost that a race-losing leave would otherwise leave behind.

### Outer kind:445 metadata: group-governed NIP-40 expiration

> **Corrected 2026-08-13.** A "Dark Matter update (2026-07-17)" note here said
> the retention component was one "Haven has **not yet configured**", and that
> until it landed Haven 445s carried **no** expiration tag with receiver-side
> enforcement inactive. That stopped being true when retention was wired in the
> Dark Matter round-2 fix, and the note outlived it — describing a gap the code
> had closed, and forbidding a claim (`privacyWhatOthersSeeDetailExpiry`, "Haven
> asks relays to drop location messages after about four minutes") that the code
> actually makes true. The section below describes what ships.

The per-send jittered TTL this section used to document is retired: the engine's
send path takes no per-send expiration. NIP-40 expiration on kind-445 is
governed by the group-level `marmot.group.message-retention.v1` component
(0x8005), which Haven declares in `supported_app_components` and supplies at
group creation with `LOCATION_MESSAGE_RETENTION_SECS` (`src/nostr/mls/manager.rs`,
`src/location/ttl.rs`). The engine then stamps every **application** kind:445
with `expiration = inner_created_at + retention`.

`LOCATION_MESSAGE_RETENTION_SECS = 228 s` = 168 s maximum publish interval
(`kLocationPublishMaxInterval`, the ceiling of the ±40 % cadence jitter) + 2 × 30 s
network buffer. That is the data-minimizing value that still satisfies the no-gap
invariant in the publish-cadence section below — for a roster of at most
`kMaxCirclesPerBurst` (11) circles. One coalesced burst per interval publishes
every eligible circle (see "Coalesced multi-circle publish bursts
(PUB-COALESCE)"), so a member re-publishes at most every 168 s and a circle that
leads one burst and trails the next waits at most one burst spread
(`kPublishStaggerMaxSpread`, 30 s) longer: a worst-case **scheduled** gap of
198 s, leaving one whole `kTtlNetworkBufferSeconds` (30 s of the `2 × 30 s`
above) for propagation and clock skew, with the burst spread spending the
other. Past eleven circles a burst defers its tail to the next tick and
that bound stops holding — stated in full under the no-gap invariant below.

Receivers enforce the tag with a `RECEIVER_EXPIRATION_GRACE_SECS = 60` skew
window, in `SessionManager::process_event` — the choke point every receive plane
(poll drain, live-sync, background catch-up) funnels through.

**The component governs the group, so a joined circle can lack it.** It is
supplied at group CREATION, which means a circle created by anything other than
a current Haven build — an older one, or another Marmot client — carries no
retention policy, and upstream then reports `None` for the group and stamps **no
expiration at all** on this device's own application 445s. Both halves of what
the app used to tell the user invert together in that case, in opposite
directions: the four-minute claim goes false, AND an unstamped location update
is misclassified as a membership change by any relay watching the circle's `#h`
(see the discriminator below). Since 2026-08-29 neither half is stated to the
user — the sentence lived on the deleted Privacy page — so this is a property of
the wire, not of any copy. Haven closes that on the send side with
`RetentionBoundPeeler` (`src/nostr/mls/retention.rs`), the transport peeler the
session installs: it delegates every operation to the real Nostr peeler but
bounds an APPLICATION message's retention on the way through — Haven's own
window when the group declares none or zero, capped to that window when the
group declares longer, honoured as-is when the group declares shorter. The
session is constructed with exactly one peeler, and the engine's send path
reaches the wire only through its `wrap_group_message_with_metadata` — inside
which the real peeler mints the ephemeral key, builds the tag set and signs the
kind-445 — so there is no second handle a send path could route around it by.
Commits and proposals pass through untouched.

Honouring a SHORTER declared window is a deliberate non-floor, and it is the
one direction of this bound that can cost the user something. A circle whose
creator declares, say, one second gets every Haven member's location dropped by
a NIP-40-honouring relay almost immediately. Haven does not floor it, because a
floor would mean asking relays to hold location ciphertext LONGER than the
circle declared — a privacy regression in Haven's code to compensate for a
functional choice in a group it does not administer — and it would not restore
what was lost: the same component governs every other member's client, so the
members that stranger's window is hiding stay hidden either way. Shorter is
also strictly more data-minimizing, which is the direction Rule 10 points. The
no-gap invariant below is therefore scoped to circles Haven created, where
Haven picks both the publish cadence and the window; in a joined circle the
window is the group's, and a too-short one is a visibility cost Haven cannot
repair.

It is no longer an unshown one. The circle-details sheet reports the EFFECTIVE
window for the messages this device sends into that circle — the same
`bounded_retention_secs` value the peeler stamps, never the raw declaration —
on the subtitle line beside the member count ("3 members · epoch 14 · expiry
30 sec"), exactly in seconds below a minute so a seconds-long foreign window
reads as alarming instead of being rounded away, and spelled out for screen
readers. A circle with no live MLS group shows no window at all rather than
falling back to Haven's, which would report "about four minutes" for a circle
that cannot send. What the sheet does not explain is WHY a window is short: it
reports the number, not whose client chose it. Held by
`INV-U-CIRCLE-EXPIRY-SHOWN-IS-EXPIRY-SENT` in
`docs/privacy/privacy_invariants.json`.

This is deliberately NOT an `UpdateAppComponents` repair of the joined group.
Writing the component is admin-gated upstream (`require_admin`) and a joiner is
not an admin, so the repair cannot fire where the gap appears; and staging an
epoch-advancing commit inside the join path would risk pinning the group in
`PendingPublish`, which buffers every inbound message forever — a silent loss of
the whole circle, strictly worse than the leak. The residue is stated under
"What this does not provide" below.

What this provides:

- Bounds relay-side residency to roughly two publish cycles, so stale
  ciphertext does not accumulate on relays indefinitely.
- Defense-in-depth against a relay replaying stale ciphertext.
- A single group-level value, so the TTL cannot drift per call site — the
  per-send design had one Dart caller computing it, and nothing checked it.
- A send-side bound under it, so the group-level value cannot fail OPEN: the
  worst a circle's declared policy can do to Haven's own location data is
  shorten its life. Not free — it costs a broadened fingerprint and, at the
  short end, silent invisibility; both are under "does not provide" below.

What this does **not** provide, including one property the retired design had:

- **It no longer defeats a constant-TTL fingerprint — it creates one.** The
  retired per-send design sampled the TTL to avoid identifying Haven clients
  among mixed MLS-over-Nostr traffic; a deterministic 228 s is exactly the
  fingerprint that was being avoided. Accepted: group-level retention is what
  the protocol now offers, and the alternative is no expiry at all.
- **The send-side bound BROADENS that fingerprint, and this is the cost side of
  it.** Before the bound, in a circle declaring no 0x8005, Haven emitted no
  expiration — indistinguishable from every other client in that circle. It now
  emits exactly 228 s there. So in a MIXED circle a relay can partition one
  circle's `#h` stream into "the Haven member's location updates" (`expiration −
  created_at == 228`) and everything else, which is a **per-member discriminator
  inside a single circle** — sharper than the client-wide one above, because it
  attributes traffic within a group whose membership the relay cannot otherwise
  resolve. The same partition appears wherever the group's declared window
  differs from what Haven stamps — i.e. in a circle declaring nothing, zero, or
  LONGER than 228 s. A circle declaring SHORTER is the one foreign case with no
  per-member split: Haven honours that value and stamps it exactly as every
  other client in the circle does. Accepted as the price of the two properties
  the bound buys (bounded residency, and location traffic not masquerading as
  membership traffic), but it is a real widening and is registered as
  `TTL-FINGERPRINT` rather than left to be inferred.
- **Carrying the tag at all is a public discriminator.** Only application
  messages are stamped — commits and proposals are never stamped, because
  expiring group history would break late joiners — so among the 445s THIS
  device sends, one *without* an expiration is visibly a group-control message
  rather than a location update. That class is wider than membership: an admin
  handoff and a change to the circle's relays are `UpdateAppComponents` commits
  and are un-stamped too. This **is not disclosed to the user anywhere**: the
  sentence that carried it (`privacyWhatOthersSeeDetailExpiry`, "a membership or
  settings change", scoped to "the messages your phone sends" for the reason in
  the next bullet) was deleted with the Settings → Privacy page on 2026-08-29.
  The behaviour is unchanged and stays pinned by this section and by the
  manifest's residual; it is an undisclosed residue, recorded here so a future
  disclosure surface can pick it up deliberately.
- **It bounds only what this device authors.** In a circle created without the
  component, another member's own location 445s still carry no expiration: they
  may be retained indefinitely, and they read as membership changes to any relay
  serving that circle. Haven cannot bound a message it does not send, and (see
  above) will not mutate a group it does not administer to try. The user-facing
  sentence used to sit under "what others see" without distinguishing "the
  messages Haven sends" from "the messages in this circle", which in a mixed
  circle pointed a relay at the wrong conclusion about a real position report;
  it is now scoped to the messages this device sends. What is left is the
  residue itself, disclosed nowhere in the app: another member's location 445s
  in such a circle. Recorded as the residual on
  `INV-W-445-EXPIRATION-SCOPE`.
- It does not hide publish cadence; that is the jittered scheduler's job, in
  the next section.
- Expiry is a **request**. A relay is free to ignore NIP-40 and retain the
  event; the copy says "asks", deliberately, and must never be phrased as a
  guarantee.

The clock-skew leak the retired design carried is gone with it: `expiration −
created_at` is no longer sampled, so it reveals nothing about the publisher's
offset that the outer `created_at` did not already reveal. It is **not** a
constant per circle, and describing it that way would hide the fingerprint
above. Per SENDER it takes one of three values: 228 s in any circle Haven
created; 228 s in a joined circle that declares nothing, zero, or a window
longer than 228 s (the capped case — where every non-Haven member stamps the
longer value, or none at all); and the group's own window where that is shorter
than 228 s, which is the only case in which every member of a circle agrees.

`compute_jittered_ttl_secs` is retained in `src/location/ttl.rs` (dead-code
allowed, with its unit tests) as the reference helper should a per-send TTL path
ever return. The `clippy.toml` `disallowed-methods` deny on `rand::thread_rng`
still governs the surviving randomness in this file — the publish-cadence jitter
must go through `rand::rngs::OsRng`, which wraps `getrandom` directly without a
cached PRNG.

### Publish cadence: jittered scheduler

Haven publishes kind:445 location events on a **jittered** cadence
around a 2-minute nominal mean. Each tick is sampled uniformly from
`[72 s, 168 s]` (nominal ± 40%) via `OsRng` — see
`compute_jittered_publish_interval_secs` in `src/location/ttl.rs` and
`PUBLISH_INTERVAL_JITTER_FRACTION_BP = 4_000`. The Dart scheduler
(`haven/lib/src/services/jittered_scheduler.dart`) is a
self-rescheduling one-shot timer that asks the Rust side for a fresh
interval on every rearm.

In addition to the scheduled cadence, a **motion-triggered publish**
fires when the device has moved more than 100 m since the last publish
AND a 60-second overlap guard has elapsed. The overlap guard prevents the
motion path from exceeding the scheduled publish rate floor (72 s) by
more than 12 s.

**What that costs, stated as a mechanism and an ESTIMATE rather than as a
verdict** (this paragraph said "adding no extra battery cost" until
2026-09-09, which was untagged and wrong in the same breath). The
mechanism: the *fix* is free — the trigger reads the GPS stream already
consumed for the user's own map marker, so it adds no location
registration and no acquisition of its own. The *publish* is not free: it
is an additional kind-445, i.e. an additional radio wake that would not
otherwise have happened. Estimation model E prices radio energy per wake
(E-A2, `POWER_EFFICIENCY_PLAN.md` §6.5a), so one extra background wake
per hour is **ESTIMATED** at ≈ 0.021 %/h at `c = 1` and proportionally
less as wakes coalesce. Nothing here was measured on any handset (§2.5 —
no hardware for the duration), and the wake count itself is bounded by
the 60 s overlap guard rather than by the trigger. The shape this
paragraph used to be — an energy verdict wearing a negation, which no
`%/h` grep can see — is now caught by
`scripts/ci/check_estimate_integrity.sh` across code and CI; this file is
Markdown and outside that guard's roots, so it stays covered by
`POWER_EFFICIENCY_PLAN.md` §5.6's sweep, which is the stated scope gap.

**Activity-level correlation surface**: motion-triggered publishes
create a bimodal traffic profile that a relay observer can use to
distinguish moving users (higher publish rate) from stationary ones.
This is an accepted tradeoff for UX responsiveness. Future mitigation
options include rate-capping motion triggers at `kLocationPublishMinInterval`
or emitting decoy publishes for stationary users.

What this provides:

- Defeats per-event linking by publish rhythm. A relay can no longer
  classify an author as "a Haven client" solely by observing
  equally-spaced 2-minute arrivals.
- Raises the cost of short-window statistical averaging. At σ ≈ 28 s
  on `[72, 168]` s, an attacker needs ~200 samples (~6.6 h of
  continuous observation at the 2-minute cadence) to recover the mean
  publish rate to within ±5%. The shorter cadence reduces this window
  from ~16 h (prior 5-minute cadence) — an accepted tradeoff for the
  UX improvement.

What this does **not** provide:

- Long-run mean is still recoverable. Jitter defeats short-window
  classification, not indefinite averaging.
- It does not address the dominant remaining relay fingerprints:
  - **Stable `h` tag per circle** — unavoidable under NIP-EE as the
    routing key; documented as a known leak, not a fix target.
  - **Predictable ciphertext length.** Location payloads cluster in
    the ~300–700 B range, distinguishing them from chat events at
    the relay. Padding to a fixed block size would collapse this
    distinction and is the biggest remaining win — filed as a
    follow-up in `docs/LOCATION_SHARING_SECURITY_BACKLOG.md`.
- Since M11 (live-sync default) the receiver side holds a **standing REQ**
  rather than a periodic fetch *while the app is foregrounded*, so there is no
  fixed arrival cadence — the relay-visible signal is the continuous socket (see
  "Persistent receive connection (live-sync engine)" above), not a poll pattern.
  Backgrounded on iOS with sharing on there is no standing REQ: each publish tick
  opens one bounded burst, so for a circle relay the receive REQ arrives on the
  same jittered publish cadence as the `kind:445` it already carries, while an
  inbox-ONLY relay sees a REQ/CLOSE cadence that is itself a presence signal —
  both under "iOS background sharing: presence only at publish instants (P4)". In the retained
  short-poll fallback (`liveSyncEnabled = false`) the 30 s fetch cadence on the
  receiver side (`map_shell.dart`) is fixed and creates a predictable arrival
  pattern at relays; see "Post-Compromise Security window from polling cadence"
  below for the related security-side trade-off.

#### Coalesced multi-circle publish bursts (PUB-COALESCE)

Owner decision **OD3** (accepted 2026-08-29) replaced the per-circle publish
schedules with **one coalesced burst per interval that publishes every
publish-eligible circle**. Radio wakes fall from ≈ N × 30/h to ≈ 30/h on every
plane. This is an accepted deviation, registered as `PUB-COALESCE` in
`docs/privacy/privacy_invariants.json`; the invariant it replaces
(`INV-R-PER-CIRCLE-PUBLISH-DECORRELATED`) is downgraded to it rather than
deleted.

**What was given up was never held.** Per-circle decorrelation did not survive a
*shared* relay: the live-sync engine's multiplexed `#h` REQ already tells any
relay in a circle's routing set "this one socket watches circles {A, B, C}", and
every circle's `kind:445` leaves over one publish socket. What the schedules
bought was weak protection against colluding relays that ignore IP — and P6
leaves IP-level joining intact anyway. That is what was dropped.

**Cost 1 — a shared rhythm links circles across disjoint relay sets.** With one
tick sequence per device, circles held on *disjoint* relay sets emit identical
inter-burst intervals. Anyone holding two of your circles' relay archives — each
relay carrying only ONE of those circles — can match the interval sequences and
tell the two circles belong to the same phone. The linkage is therefore **not**
limited to relays that carry several of your circles.

**Cost 2 — the number of circles you are in becomes a single-relay,
duration-shaped observable.** A burst holds its connection across the *whole*
staggered publish pass, and the span grows by one stagger gap per additional
eligible circle (mean 5.5 s while the per-gap ceiling is the full 9 s, narrowing
toward 2.5 s as the burst approaches the cap; the *scheduled* pass is bounded by
`kPublishStaggerMaxSpread` = 30 s, while the *realized* one is the third
realized-gap term recorded under "The no-gap invariant" below). Which socket carries it splits by plane, and the split is the claim:

* **iOS background.** The connection is the engine socket: `resume_burst`
  `add_relay`s and `connect()`s the entire relay **union** — every circle's
  relays *and* the inbox relays (`relay_union`,
  `src/relay/live_sync/session.rs`) — at the open, disconnecting only at the
  pause that follows the pass. Every relay in that union can measure the span:
  one carrying a single circle of yours, and an inbox-only relay carrying none.
  Here the span is structural, not merely bounded: `build_engine_client` passes
  no `RelayOptions` at all, so the engine pool keeps `sleep_when_idle: false`
  and — holding standing REQs — could not sleep even if it did not.
* **The Android foreground service.** There is no engine socket on this plane at
  all — the service holds only a `NostrRelayService` publish pool — so the pool
  *is* the carrier. `RelayManager::shutdown` is a **collective**
  `client.disconnect()`, and the service calls it at step 9b of every delivery
  cycle and again in `onDestroy`, so a relay carrying exactly one circle in a pass sees
  connect-at-its-own-publish → disconnect-at-teardown: a tail that grows with
  the circles published *after* it and, over the CSPRNG burst permutation,
  reaches the whole pass length. That one is a **bound rather than a structural
  invariant**, and the difference is worth keeping: the publish pool DOES sleep
  when idle, so a relay left silent for `PUBLISH_POOL_IDLE_TIMEOUT` (10 s) past
  its own next idle poll can sleep mid-pass and end its own observation early —
  only reachable on a long cycle whose fetch phase touches other relays, since
  the publish pass itself sits well inside one poll period. The next send
  revives it. Nothing sequences that, so it narrows the leak by luck, not by
  design.
* **The foreground.** There is no collective disconnect here.
  `publish_relay_options()` is `ping(false).reconnect(false)
  .sleep_when_idle(true).idle_timeout(10 s)`, and the idle poll is a one-minute
  crate constant evaluated inside each relay's own connection task, so each
  relay's socket sleeps independently in **(60 s, 70 s]** measured from the
  connect that opened it — the same thing as "after its own last send" for a
  single-circle publish, where connect and send share one wake, and sooner than
  that for a relay published to early in a multi-circle pass. The span a
  foreground relay measures is its own, not the pass's.

Stated sharply: **the old scheme leaked N only as a *rate*, to shared relays
that already read it off the multiplexed filter; the new scheme leaks it as a
*duration*, to relays that previously could not know it at all.**
`kMaxCirclesPerAccount` (10) bounds the roster and therefore the estimator, one
circle under the `kMaxCirclesPerBurst` (11) at which the per-gap ceiling
saturates. This cost was found in review of the P5 change and is recorded here
first; nothing in the plan that authorised OD3 states it.

**Cost 3 — N also leaks through the *signed timestamps*, and this one persists.**
`PublishStagger.maxGapFor(n)` is deterministic and, in milliseconds, injective
over n = 5…11 (9 000 / 7 500 / 6 000 / 5 000 / 4 285 / 3 750 / 3 333 / 3 000; only
2, 3 and 4 collapse, all three at the 9 s ceiling), and the expected whole-burst
span rises monotonically with it: ≈5.5 s at two circles, ≈11 at three, ≈16.5 at
four, up to ≈24 s at ten — the largest burst a bounded roster can produce
(≈25 s at eleven is `maxGapFor`'s answer one circle further, which no observer
reaches while the bound holds). An observer holding kind-445
archives of two of your circles — precisely the adversary Cost 1 hands the *link*
to — reads one whole-second delta per burst. Over a handful of bursts the largest
delta estimates the burst span (monotone in n) and the lowest cluster's upper
edge estimates the per-gap ceiling. **That ceiling does not invert to a single n,
because `created_at` is whole seconds and the millisecond injectivity does not
survive the quantization**: the observable alphabet resolves the roster exactly
at five and six circles and only to a PAIR at seven/eight and nine/ten, which
share `{2…5}` and `{2,3,4}` respectively (the swept table under "What the
stagger still buys" below; eleven resolves exactly as well, and no roster
reaches it). Separating a pair needs the span term or the delta
*frequencies* rather than the ceiling, i.e. more bursts — a cost in samples, not
a bound: the count still leaks, one bit coarser on the two colliding pairs —
four of the six sizes above four that the roster bound admits. A relay
carrying several of your circles reads adjacent pairs directly and converges
faster. It is worse than Cost 2's duration in three ways: it needs no socket
observation at all (a passive archive scraper suffices), connection noise does
not defeat it, and it **persists**, because the delta is inside the signed event
and therefore in every archive of it. It compounds with Cost 1: link, then
count. `kMaxCirclesPerAccount` bounds the estimate at ten — a ceiling on the
estimate, not a mitigation. Pinned by `the per-gap ceiling is the priced table,
for every burst size` (`haven/test/services/publish_stagger_test.dart`).

**What the stagger still buys — narrower than it used to be stated, and
roster-scoped.** The CSPRNG gap between consecutive encrypts is kept and its
constants did not move. It is **not** "the archive-adversary defence": after
coalescing, the archive reader gets the link anyway from the shared inter-burst
interval sequence above. What it buys is bounded by *how many distinct
whole-second offsets a burst can print*, and `maxGapFor` prices every gap at the
burst's own size, so that alphabet **thins monotonically** with the roster:
`{2…9}` (eight values) up to four circles, `{2…8}` at five, `{2…6}` at six,
`{2…5}` at seven and eight, and `{2,3,4}` at `kMaxCirclesPerAccount` (ten), the
largest burst a bounded roster can produce. (`maxGapFor` keeps answering one
circle further, at `kMaxCirclesPerBurst`, where the alphabet is exactly `{2,3}`;
no observer reaches it while the bound holds.) Coalescing is
what caused the thinning — before it, every gap was priced at the default
`totalPublishes = 2` and the alphabet was always eight.

At small rosters the downgrade in *kind* is real. A byte-identical `created_at`
— which is what two encrypts inside one whole second produce, inside the
*signed* event — is a zero-cost **equality join** over a whole-network index
(`created_at_A == created_at_B`), decisive on a single burst and requiring no
hypothesis about who anyone is; eight admissible offsets force a **windowed
correlation** instead, in which the reader must first hypothesise that two
specific circles share a device and then test that against a matching sequence
of offsets. **At the roster bound it barely is.** A three-element alphabet is
three shifted equality joins over that same whole-network index — still
un-targeted mass linkage — so what survives at ten circles is a constant factor,
not a change in kind. Swept, as set equality per burst size, by `expected
whole-second delta alphabet, swept over every burst size the app admits`; the
older eight-value assertion is scoped to the two-circle case it actually draws.

**Not affected.** The cadence bounds (`[72, 168] s`, ±40 % CSPRNG), the TTL web,
the ephemeral per-message author key, the motion trigger and the wire format all
stand unchanged; nothing here moved a byte on the wire. The burst's per-circle
freshness is unchanged too: the tick samples the same interval each circle used
to sample for itself.

#### The no-gap invariant

> **Corrected 2026-08-13**, together with the retention section above. This
> subsection described the retired per-send jittered TTL as if it were live —
> "sampled independently", a Dart-supplied `update_interval_secs = 198 s`, a
> `[198, 396] s` residency window, and a two-timestamp joint distribution. None
> of that ships. The retention rewrite 60 lines above had left this half behind.

There is only ONE jitter now: the publish interval. The TTL is not sampled at
all — it is the group's fixed `message-retention.v1` value.

**Scope: a circle Haven created.** The arithmetic below holds where Haven picks
both sides of it. In a joined circle the window is the creator's, and the
send-side bound honours a shorter one as declared (see "Honouring a SHORTER
declared window" above), so a foreign creator can set a window under `δ_max` and
break gap-freeness for every member. That is not a Haven bug to fix by widening
— see there for why — but it is the reason this invariant cannot be stated
app-wide.

A relay must always hold at least one non-expired event from every active
publisher. For events `E_n` published at `T_n` with TTL `τ`, gap-freeness
requires `δ_n ≤ τ` for every `n`, where `δ_n = T_{n+1} − T_n`; worst case
`δ_max ≤ τ`.

**Second scope: a roster of at most eleven circles — and the app admits at most
ten.** Since `PUB-COALESCE` one burst publishes every eligible circle,
and a burst that runs out of spread budget **defers** its tail. `δ` is therefore
no longer the sampled interval alone: a circle that leads one burst and trails
the next also waits that burst's spread. Past `kMaxCirclesPerBurst` the deferral
multiplies the interval by `ceil(N / 11)` — it does not merely double it — and
the invariant would fail. It cannot be reached: the owner bounded the account
roster at `kMaxCirclesPerAccount` = 10 on 2026-09-09, one circle below the burst
cap, refused at circle creation and at invitation accept
(`haven/lib/src/services/nostr_circle_service.dart`, the one seam both reach the
core through — and the only two operations the core CREATES a `circles` row from:
`create_circle_with_config`, which upserts through `CircleStorage::save_circle`,
and `record_processed_invitation`, which runs its own `INSERT INTO circles`.
`save_circle` has three further non-test callers —
`resync_circle_relays_from_mdk`, `add_members`, `remove_members` — and each
reads the row back with `get_circle` first and returns early when there is none,
so none of them can mint one. The gate also RESERVES the admitted slot
(`_reservedRosterSlots`), because the row exists only once the core write
returns: without the reservation simultaneous accepts each read the same
pre-growth roster). So this second scope is a bound on a variable the app itself
bounds tighter, and the arithmetic below holds for every roster a user can have.
What a roster past eleven WOULD cost is kept below, unchanged, because the
deferral code is still there and lifting the bound re-opens it verbatim.

With `PUBLISH_INTERVAL_JITTER_FRACTION_BP = 4_000` around a 2-minute nominal,
the sampled interval is uniform in `[72, 168] s`, so its ceiling is 168 s. Add
the burst spread a circle can move across — at most `kPublishStaggerMaxSpread`
= 30 s, and `maxSpreadFor(11) = 30 s` exactly, which is what fixes the cap at
eleven — and `δ_max = 168 + 30 = 198 s` for any roster the burst does not
defer. The TTL is the constant `LOCATION_MESSAGE_RETENTION_SECS = 228 s`. Thus
`τ = 228 s > δ_max = 198 s` ✓, with 30 s left for propagation and clock skew —
one whole `kTtlNetworkBufferSeconds`, i.e. half of the `2 × 30 s` the constant
is built from; the burst spread is what now spends the other half. Swept over
**every** admissible burst size
rather than asserted at one point, with an anti-vacuity assertion that one more
circle than the cap breaks it, by `the no-gap invariant holds across the WHOLE
admissible range, with the disclosed propagation margin intact`
(`haven/test/services/publish_stagger_test.dart`).

**What a roster past eleven costs — out of reach since 2026-09-09, and kept
here because the code that would produce it is.** The burst slice is
strict round-robin (`_takeBurstSlice` takes `kMaxCirclesPerBurst` per tick and
rotates), so a deferred circle's worst service period is `ceil(N / 11)` bursts
rather than two at every roster: **N = 12…22 → 2** sampled intervals (144 s
best, 240 s mean, 336 s worst — and **366 s** once the burst-position
differential is added, because a circle may lead one burst and trail the one two
ticks later, a whole `kPublishStaggerMaxSpread` apart); **N = 23…33 → 3**
(216 / 360 / 504 s); **N ≥ 34 → 4 or more**, where even the *best* case (288 s)
exceeds the 228 s retention on **every** publish rather than on some. Most
deferrals therefore leave a peer's marker expired at the relay *before its
replacement is created*, and past thirty-three all of them do.

That ladder is **pinned rather than left as prose**, in two halves. The
round-robin period itself is swept over *both* sides of every rung (11, 12, 13,
22, 23, 24, 33, 34) by `a deferred circle waits ceil(N / kMaxCirclesPerBurst)
bursts` (`haven/test/providers/location_publish_scheduler_provider_test.dart`),
which drives real ticks and records which burst served each circle, so it fails
if the slice size or the rotate moves; and the seconds those periods are quoted
in are read off the cadence constants by `and past the cap, the deferral ladder
in SECONDS` (`haven/test/services/publish_stagger_test.dart`), which also pins
the two retention crossings — the best case still inside 228 s at two bursts,
and past it at four.

**One limit on that quotient**, not visible from the arithmetic and stated here
rather than left to be discovered: the cap bounds what the scheduler *hands
over*, not what a background pass publishes — while the iOS sink is installed, a
tick arriving inside a running burst folds into it
(`BackgroundBurstCoordinator._joinable`) rather than opening a socket of its
own, so one pass can carry two slices and
publish more than `kMaxCirclesPerBurst`. That is reachable only at `N ≥ 12`,
i.e. already outside the roster this invariant is scoped to.

**The period is absolute, and this subsection used to say otherwise (corrected
with the mechanism, 2026-09-09).** It described the rotation as cleared by every
`stopScheduling()` — a per-**continuous-run** period — and concluded that a
circle past the first slice on a device that backgrounds often has an
**unbounded** gap. The resets were fixed at the source: `_rotation` now outlives
`stopScheduling()`/`startScheduling()` **and** outlives an emission reporting
nothing eligible (`circlesProvider` degrades any roster-read failure to `[]`, so
an empty emission is as often a transient FFI/keyring error as a real
departure), so neither a backgrounding nor a failed roster read re-phases whose
turn it is. Three tests in
`haven/test/providers/location_publish_scheduler_provider_test.dart` hold it: `a
deferred circle is not deferred again by every resume`, `a transient empty roster
emission does not re-phase whose turn it is`, and `a roster change keeps
survivors' places in the queue`; and the guard
`scripts/ci/check_publish_rotation_fairness.sh` pins the structural half — the
rewind at exactly ONE site inside `build()`, and the survivor merge below the
empty-roster guard rather than above it.

**Absolute, but a period of TURNS — and a turn is a SELECTION, not a publish.**
The rotation advances when the tick FIRES, ahead of the chain, the publish
window and the sink, so a slice can lose its turn without publishing anything:
the window refuses it (no identity, the disclosure not accepted, a fix that
timed out), the app pauses under it, or the iOS coordinator drops a queued
burst. The health model is told — a refused window is attributed to every circle
waiting on it — the queue is not, so the circle waits its whole period over
again: one more burst at `N ≤ 11`, which puts its gap at up to 336 s against the
228 s retention, and another `ceil(N / 11)` bursts past the cap. So the ladder
above is the period between a circle's TURNS and a lower bound on the period
between its publishes, never the latter on its own.

What still rewinds the queue is `build()` — a fresh container, or the invalidate
in `IdentityNotifier.deleteIdentity` — and a process restart, which does not
persist it. Because the roster keeps `filterPublishEligibleCircles` order
(`getVisibleCircles()` orders by `updated_at DESC`), that rewind returns to the
**same** head and re-serves the same first slice: a deterministic re-service,
not a re-phase. And the tail's gap across such a boundary is bounded by how
often the app resumes rather than unbounded, because the deliberately
**uncapped** one-shot burst (`locationPublisherProvider`) fires on cold start,
on the motion trigger, on accept/create and on **a resume more than 30 s after
the last one** — `MapShell`'s resume debounce sits ABOVE its invalidate, so a
glance inside that window is not a trigger. **That cover stops being a promise
at twenty-one circles**, which is where the one-shot's own spread outlasts
`kLocationPublishOverlapGuard`: the next trigger's `invalidate` marks the burst
in flight superseded and it stops where it stands, the replacement re-shuffling
from the start, so the abandoned burst never reaches its tail. Past twenty
circles "every session publishes to every circle at least once" — which this
paragraph asserted flatly until 2026-09-09 — would be a probability, not a
promise; that too needs `N ≥ 21` and is out of reach at
`kMaxCirclesPerAccount`.

**Two baselines, because they answer differently.** Against an **uncapped
coalesced** burst the hole opened from the twenty-second circle up
(`168 + 3 × 21 = 231 s`) and the cap moves it to the **twelfth**. Against the
**actual predecessor** — per-circle schedulers, where δ was each circle's own
sampled interval, ≤ 168 s at every N, with no spread and no deferral — there was
**no hole at any roster size** and the full 60 s (`2 × kTtlNetworkBufferSeconds`)
of margin was intact. So this is a regression at **every N ≥ 12** for the hole,
with **no upper bound**, and at **every N ≥ 2** for the margin (60 s → 30 s). It
was taken deliberately (owner decision 2026-09-08, option (a)) because the cap is
what makes the burst's own span, its single shared GPS fix and
`kLocationPublishOverlapGuard` hold for **every** roster instead of only for
small ones. The hole is structural, not a defect to fix in the scheduler: `n`
events more than `kPublishStaggerMinGap` (2 s) apart cannot fit inside the 60 s
the retention leaves above the cadence ceiling once `n > 31` — a *different*
bound from the service period above, because it is about ONE burst's spread
rather than how many bursts a circle waits — so past about thirty-one circles no
arrangement of the publishes closes it at all. Closing both needed a **roster
bound or a longer retention**; the owner took the **roster bound** on
2026-09-09 (`kMaxCirclesPerAccount` = 10), which moves the whole `N ≥ 12` half
from live to latent-behind-a-bound without touching the wire. **The `N ≥ 2`
margin halving is NOT closed by it** — the burst spread still spends one
`kTtlNetworkBufferSeconds`, so this invariant runs on 30 s of propagation and
clock-skew margin where the per-circle predecessor had 60 s, at every roster
from two circles up. That is the residual this entry still carries; the
`ceil(N / 11)` ladder is no longer one. The arithmetic is on
`kMaxCirclesPerBurst` and `kMaxCirclesPerAccount`
(`haven/lib/src/services/publish_stagger.dart`), and the refusal, per entry
point, in `haven/test/services/nostr_circle_service_roster_bound_test.dart`.

Three **realized**-gap terms sit outside the scheduled bound above, and are
stated where they arise rather than folded in here. Two are **head** terms that
do not scale with the roster: the Android foreground service publishes on a
platform delivery that arrives a TTFF late (worst case 248 s on API 23–30, swept
per regime in `haven/test/services/background_fix_request_test.dart`), and the
iOS burst head — connect, backlog wait and one-shot fix — adds up to 40 s before
the burst's first publish. **Both of those head terms cross the retention, and
this paragraph used to say so for only one of them** (corrected 2026-09-09). The
heads themselves do not scale with the roster; the iOS CROSSING does, because the
head varies between bursts and so enters the realized gap as a differential *on
top of* the burst spread: `168 + 40 + spread` reaches 235 s at four circles and
238 s from five up, where the spread saturates. So iOS is inside 228 s only up to
three circles, and neither crossing is covered by the 30 s this invariant
reserves — both are realized terms outside its scheduled bound, stated on
`haven/lib/src/constants/location.dart`. The **third scales with N**, and it is the one
coalescing introduced: the pass is serial, and the stagger buys separation *on
top of* each publish rather than inside it. The foreground `_pacedPublish`
measures the gap from the previous publish's **start**, so the span is
`Σ max(gap_i, dur_i)`; the background pass awaits the gap **after** the previous
publish returns, so it is `Σ (dur_i + gap_i+1)` — strictly additive. One publish
is priced at `kBurstPublishBudget` (10 s), so at the largest burst a bounded
roster can produce the realized span reaches ≈90 s (foreground shape) or ≈120 s
(background) — ≈100 s and ≈130 s at the cap one circle further — against a
**scheduled** 30 s spread. It lands twice: once in a deferred circle's realized
gap, and once in Cost 2's duration-shaped circle-count estimator. All three are
documented on `haven/lib/src/constants/location.dart`.

The 60 s figure is the constant's own derivation (`168 + 2 × 30`), and it is pinned
in **both** directions by `narrowing_the_retention_would_strand_a_returning
_member` and `widening_the_retention_would_outlive_the_disclosed_expiry`
(`tests/privacy_copy_ties.rs`), which read the Dart ceiling rather than
mirroring it — so widening the publish jitter without widening retention fails
loudly instead of silently reopening the gap.

`RECEIVER_EXPIRATION_GRACE_SECS = 60 s` sits on top as clock-skew
defense-in-depth against a replay-near-boundary attack; it is **not**
load-bearing for gap coverage.

Cost: relay-side residency is a constant 228 s, shorter than the retired
design's `[198, 396] s`. The traffic cost of the 2-minute cadence is accepted
for the UX improvement (worst-case viewer staleness ~3.5 min for scheduled
publishes, sub-minute via the motion-triggered path).

The two-timestamp correlation residual this subsection used to file as a
follow-up is **narrowed, not closed**. `expiration − created_at` is no longer
sampled, so the joint distribution the retired design leaked is gone. It is not
"the same constant on every application 445": it is the same constant on every
445 THIS device sends into a circle whose declared window is absent, zero or
≥ 228 s, and the group's own value where that is shorter — which the retention
section above enumerates, and which the bound made a supported case rather than
an impossible one. A relay therefore still reads one bit per sender per circle:
which of those the sender is in. That is the `TTL-FINGERPRINT` widening, filed
there; what is genuinely closed is the *skew* leak, not the *correlation* one.

Even the narrowed form depends on the engine binding the outer `created_at` to
the inner one it derives the expiration from — pinned only incidentally, by
`encrypt_location_attaches_group_retention_expiration` and
`a_shorter_group_policy_reaches_the_wire_as_declared` comparing against the
OUTER `created_at` (`src/circle/manager.rs`). An engine change that decouples
the two would re-open the skew leak, and would do so silently.

### Relay-observable metadata and correlation (accepted)

Beyond event *content* (which is E2E-encrypted) and the timing mitigations
above, a curious or malicious relay still observes connection- and
protocol-level metadata. The following are **accepted** residuals — none
expose location, usernames, or key material, but they are documented so the
threat model is honest:

- **Relay-session linking.** Haven runs at least TWO long-lived `nostr-sdk`
  clients per process — the live-sync engine's receive client and the publish
  pool — plus one more for every isolate that builds its own pool, so a shared
  relay sees two or three connections from the same address and can join them by
  source address with no protocol help (the accepted deviation `RC1` records
  this; "one client per relay" was the older, wrong framing).
  A relay that serves *both* a user's gift-wrap inbox (kind 1059 REQ
  filtered by `#p = <user pubkey>`) and that user's group messages (kind 445
  by `#h = <nostr_group_id>`) over the same connection can correlate the real
  identity pubkey with group membership by connection continuity — even
  though kind-445 events themselves carry only ephemeral author keys.
  Protocol design already separates inbox relays (1059) from circle relays
  (445), so this only bites when the *same* relay serves both roles for a
  user. Full mitigation needs per-fetch ephemeral connections or onion
  routing (out of scope for v1). Since M11 (live-sync enabled by default) the
  engine holds this as a **standing** connection rather than a per-fetch one
  while the app is in the **foreground**, on both platforms, so the `#p`↔`#h`
  same-socket correlation is continuous for as long as that socket is held.
  Backgrounded it is not held: on Android the pause stops the engine in either
  toggle state, and on iOS with background sharing on the engine is paused
  between publishes and the two filters ride one bounded burst per publish tick
  — the same-socket join is then per-burst rather than continuous, and the
  inbox filter rides only every `INBOX_BURSTS_PER_REQ`-th burst. Both are set
  out in the **Persistent receive connection** bullet immediately below.

- **Persistent receive connection (live-sync engine).** Haven holds a standing
  WebSocket to your configured circle/inbox relays while the app is in the
  **foreground**, on both platforms. It no longer holds one while the app is
  backgrounded, in either toggle state, on either platform — that changed on
  Android with the P1 power phase and on iOS with P4. On **iOS while background
  location sharing is enabled** (an opt-in) the CoreLocation session keeps the
  process executable, and the engine spends the background window PAUSED between
  publishes: each publish tick opens one bounded burst and closes it again, so a
  circle relay sees the device present at the burst instants and absent between
  them. At the BURST instants, not at the instants its own kind-445 reveals: one
  burst re-anchors every circle and connects the whole relay union while only
  the circles then due publish, and a burst whose publish window refuses sends
  nothing at all. That is stated in full,
  with the residuals it carries, under **"iOS background sharing: presence only
  at publish instants (P4)"** at the end of this section. The foreground socket
  is not idle: the pool pings every 55 s per relay
  (`nostr-relay-pool` 0.44.3, `src/relay/constants.rs:34` `PING_INTERVAL`), so a
  foregrounded client is a continuously present, continuously observed one. That
  55 s ping is the **engine** pool's alone, and deliberately so — it is the
  only traffic on a socket that holds standing REQs, and without it a
  dead-but-open relay would go unnoticed until the 15-minute health tick (which
  is itself foreground-only, see the P4 subsection). Since P1 the **publish**
  pool sends no keepalives at all and closes within roughly a minute of the
  last publish
  (the module-level `publish_relay_options` in `relay/manager.rs`:
  `ping(false).reconnect(false).sleep_when_idle(true)` with a 10 s idle timeout
  polled once a minute inside each relay's own connection task, so the real
  socket lifetime is (60 s, 70 s] from that connect — the same as "from the last
  send" whenever a publish is a single event), and every fetch primitive leaves
  no subscription registered
  behind it, so nothing holds that socket awake between bursts. A relay in the
  publish set therefore sees a device present at the publish instants and
  absent between them, rather than continuously — pinned by
  `INV-R-PUBLISH-POOL-NO-KEEPALIVE` and
  `scripts/ci/check_engine_client_options.sh`. On **Android** the engine is
  STOPPED at the pause, in BOTH toggle states, since the P1 power phase: with
  background sharing **ON** pausing the app stops the engine before the MLS
  session is handed to the foreground service (`MapShell._handOffMlsSession`)
  and the service isolate never opens one; with background sharing **OFF** the
  pause path stops it through `MapShell._stopLiveSyncBounded()`, which
  deliberately does not release the Rule-14 guard because no isolate reclaims
  it, and the resume heal restarts the engine. So a backgrounded Android device
  holds no receive connection at all — where it previously went on holding one,
  and on being observed, until the OS froze the process. The publish client is
  a separate socket with a separate policy and is shut down on the same pause
  path (`MapShell._shutdownPublishPool` → `NostrRelayService.shutdown` →
  `RelayManager`, not the engine's `build_engine_client`); on the iOS burst
  branch that shutdown is the last link of the burst teardown. Wherever the
  receive connection is absent — Android backgrounded in either toggle state,
  iOS with background sharing off, or either platform once the OS suspends or
  freezes the process — background delivery falls back to the short,
  receive-only OS-wake sweeps described under "Scheduled background wakes
  (M7)", which connect briefly and shut down. On iOS with background sharing
  **on**, delivery between bursts is the next burst, and those OS-wake sweeps
  take over only once the OS suspends the process. One case in that enumeration
  is NOT an OS-discretionary wake and is called out because it is materially
  different: in a **rollback build** (`liveSyncEnabled = false`) on iOS with
  background sharing on, there is no engine to pause, and
  `MapShell._startIosBackgroundReceiveTimer` — whose only guard is
  `if (liveSyncEnabled) return;` — arms a 90 s `Timer.periodic` that runs the
  receive-only catch-up sweep for the whole background window. That is a
  fixed-cadence background presence signal on the publish pool's own
  connections, not a wake the OS chose the timing of, and it exists only on the
  flag-off path. A
  relay learns **that you are online, and which circles you watch, for as long
  as that connection is held** — a continuous presence signal the previous
  short-poll model exposed only in bursts; this is irreducible while a live
  connection is held. Because one connection serves both your circle
  subscriptions (`#h`) and your invitation inbox (`#p`, keyed to your stable
  public key), a relay that is in **both** a circle's relay set and your inbox
  relay set can link your public key to that circle for the session. We
  minimize exposure by: (a) connecting **only** to relays you configured (never
  a discovery/default relay — the engine client sets no `.gossip(...)`, so
  NIP-65 gossip is off, PSI-8); (b) scoping subscriptions to exactly your
  joined circles and dropping a circle's subscription the moment you leave; (c)
  closing all subscriptions and the socket on logout; (d) deriving subscription
  IDs from a **per-session random salt never written to disk**
  (`generate_session_salt`, an ephemeral `Zeroizing<[u8; 16]>`), so a relay
  cannot link your subscriptions across app sessions (PSI-2); and (e)
  **disabling NIP-42 authentication** on the receive connection
  (`automatic_authentication(false)`), so your signing identity is never sent
  to a relay over this socket. The live engine's **notification/decrypt plane
  is receive-only**; its only relay *publishes* are ephemeral-keyed convergence
  auto-commit commits (per MIP-03), including ones triggered while reprocessing
  received commits on foreground resume. Background catch-up and resubscribe are
  receive-only — they re-issue REQs, never publish. It never holds your private
  Nostr signing key, and never sends key material or your real MLS group
  identifier over the wire (only the pseudonymous `nostr_group_id`). To also
  hide your IP / online-presence from the relay operator, run Haven behind a
  VPN or Tor (e.g. Mullvad).

- **Stable `h`-tag traffic analysis.** `nostr_group_id` is a permanent
  per-circle identifier. A relay can track a circle's message volume,
  cadence, and approximate membership (by counting distinct ephemeral author
  keys over time). The ephemeral-key-per-message design prevents *sender*
  attribution, and the jittered publish cadence (above) blunts timing
  analysis, but the `h`-tag linkability itself is a MIP-03 constraint with no
  app-layer fix.

- **Superseded commit during multi-admin convergence.** Under concurrent-commit
  convergence (engine-owned `CommitOrderingKey` branch selection since the Dark
  Matter cutover; previously the M6 settle window — active whenever the
  live-sync engine is on, the default since M11), two admins committing from
  the same epoch each publish their commit before branch selection resolves, so
  the group deterministically adopts the winner instead of forking. The losing
  admin's commit is therefore
  briefly observable on the relay before it is superseded. This reveals only
  that *a concurrent-admin race occurred* (an extra same-epoch `kind:445` under
  the circle's stable `h` tag) — never the membership target, which lives inside
  the encrypted MLS commit, not the relay-visible tags. It is the same class of
  metadata as the stable-`h`-tag and ephemeral-author-counting residuals above.
  The same applies to the receiver-side path: multiple members' engines
  auto-committing the same peer `SelfRemove` (`PublishWork::AutoPublish`) each
  publish their commit during convergence — another superseded same-epoch commit
  on the relay, never the membership target. **What follows a process kill
  between publish and confirm on that path is NOT a re-publish, and this bullet
  said otherwise until 2026-09-09.** A receive-side auto-commit is always
  removal-bearing, and the engine's hydrate deliberately short-circuits on
  exactly that (`staged_removes_member`), so it neither clears the staged commit
  nor emits `PendingCommitRecovered`: nothing re-commits, and the group is
  wedged rather than recovered (residual 4 below). Since 2026-09-09 a BACKGROUND
  burst does not open that window at all — it parks the eviction as a durable
  per-circle obligation and the next foreground pass publishes it — so on that
  plane there is no kill-between-publish-and-confirm to describe. The foreground
  and Android catch-up paths still publish it, so the residual stands there.

- **Incremental subscribe/unsubscribe REQ shape (live-sync engine).** When the
  live-sync engine is on, a circle added mid-session (create / accept an
  invitation) is subscribed as its OWN dedicated `kind:445` REQ — a "dynamic
  singleton" with its own subscription id and its own `since` — rather than being
  folded into an existing multiplexed `#h` bucket, so it does not collapse the
  bucket's shared `since` and replay every co-subscribed circle's history. Two
  relay-observable, strictly-transient residuals follow, neither of which exposes
  location, identity, key material, or the real MLS group id:
  - *Retained idle socket after a leave.* On leaving a circle, the engine CLOSEs
    that circle's REQ (dropping its `#h` from the wire filter — the drop-on-leave
    property is preserved), but it deliberately does NOT `remove_relay` the
    relay from the pool: a `remove_relay` could disrupt the shared pool and race
    an in-flight receiver-side convergence publish over that relay. So if the
    left circle's relay was unique to it, an idle own-relay socket (no active
    REQ) lingers until the next session teardown — logout / full-session
    restart / background-resume re-anchor — clears it via `client.shutdown()`.
    The relay learns only that an authless connection it already had stays open a
    while longer; the left circle's `#h` is no longer on the wire.
  - *Singleton REQ-count accumulation.* Until the next full session start
    re-buckets the whole set, `N` circles that share a relay set and were added
    incrementally appear as `N` separate REQs on that relay instead of one
    multiplexed bucket. Only the REQ *count* grows; the set of `#h` values the
    relay sees is unchanged, and it is still one socket per relay (no new
    connection, no amplification regression). This is the same class of metadata
    as the stable-`h`-tag residual above (PSI-8 / §H2 own-relays-only accounting)
    and self-heals on the next full `start_session` / background-resume, which
    re-folds the singletons back into their relay-set buckets.

- **Relay-list rotation trail.** When Haven unpublishes a relay-list category
  (kind 10050 inbox / kind 10002 NIP-65 KeyPackage-discovery list — the latter
  replaced the kind-10051 KeyPackage-relay list at the Dark Matter cutover) —
  e.g. after the user edits their relays — its unpublish path emits a NIP-09
  kind-5 deletion (signed by the identity key) alongside the empty replacement
  event, so a relay that retained the old list learns the change history. The
  one-time cutover retraction of the retired kind-10051 (empty replaceable +
  kind-5) leaves the same class of trail. This reveals nothing beyond what the
  relay-list events already exposed; the deletion is a best-effort tidy-up for
  cooperative relays (`relay::publishers::build_nip09_deletion`).

- **KeyPackage residue.** Since the Dark Matter cutover, KeyPackages are
  NIP-33-addressable kind-30443 events: a republish into the same stable `d`
  slot supersedes the previous one in place, so routine maintenance does not
  accumulate current-format KeyPackages on relays (this closes the old
  Finding-A2 accumulation gap for the new format). Retirement is the one thing
  that does add a coordinate: a pre-width-fix install's malformed slot is left
  behind by the move onto a binding-shaped one, so such an account publishes TWO
  live coordinates until a relay honours the advisory NIP-09 deletion of the
  old one — supersession cannot reach it, because it is a different `d`. The
  residue is therefore three classes, not two: (a) that retired 32-hex
  coordinate, which discloses an era marker (which build of Haven first
  published the account) and never key material — the `d` is CSPRNG-random and
  derived from nothing; (b) legacy non-addressable kind-443 events; and (c) the
  retired kind-10051 relay list. (b) and (c) are scrubbed by a one-time,
  sentinel-gated retraction
  (`RelayManagerFfi::retract_legacy_key_material`): a kind-5 NIP-09 deletion of
  the user's own 443 by event id (self-authorship-guarded; deliberately no
  `a`-coordinate, since a `443:<pubkey>:` coordinate would over-delete) plus an
  empty replaceable kind-10051. Both are best-effort on cooperative relays; an
  uncooperative relay may retain the old 443 (exposing only an init key already
  bound to the identity pubkey) — a content-free lifecycle residual.

- **Client fingerprint.** The relay WebSocket handshake carries `nostr-sdk`'s
  default `User-Agent` (e.g. `nostr-sdk/0.44`). This is **not** unique to
  Haven — every `nostr-sdk` client of that version sends the same value — but
  it narrows the anonymity set from "all WebSocket clients" to "nostr-sdk
  clients of version X". Suppressing it depends on upstream `nostr-sdk`
  support for overriding the header.

#### iOS background sharing: presence only at publish instants (P4)

Since the P4 power phase, a backgrounded iPhone with background location
sharing **on** no longer holds the live-sync engine's socket for the whole
background window. The claim, in the only form that is true — read it with the
eleven residuals below, every one of which is scoped against it:

> While backgrounded on iOS with sharing on, Haven opens a relay connection only
> at its own publish *ticks*, and between them holds no standing subscription and
> no socket it asked for.

Read "publish tick", never "publish": one tick opens **one burst**, and a burst
re-anchors *every* circle, connects the *whole* relay union, and — since
`PUB-COALESCE` — publishes every publish-eligible circle rather than the ones a
per-circle schedule made due. What a burst is still not is a per-circle event,
what it still does not do is guarantee a send at all, and what it now *adds* is
a duration that scales with the circle count: all three are residual 11 below.

Each publish tick runs one bounded **burst**, in the isolate that owns the MLS
session (Security Rule 14): re-issue every REQ at its persisted cursor, wait for
the stored replay to land (`BURST_BACKLOG_WAIT_SECS`, per `(relay,
subscription)` endpoint) so a peer's commit received here is applied *before*
this device encrypts its own location, publish, fold any due KeyPackage /
relay-list maintenance onto the warm publish pool, settle
(`COMMIT_SETTLE_WINDOW_SECS` from the last commit activity, capped by
`BURST_SETTLE_CAP_SECS`, which bounds idle follow-on activity only and never an
in-flight publish), pause the engine, drain any commit-critical publish still on
the shared publish pool (uncapped, Security Rule 13), close that pool. The pause
CLOSEs every REQ, sweeps any that a partial `unsubscribe_all` left registered, drains
what is already downloaded through a marker rather than forgetting it, waits
uncapped for every in-flight publish, and only then terminates every relay —
`client.disconnect()`, re-read and re-asserted, never `client.shutdown()` — so
that where the termination converges, `nostr-relay-pool`'s per-relay connection
task and its 55 s pinger exit with it.
Each of those links except the Rule-13 wait is bounded
(`RELAY_LIFECYCLE_OP_TIMEOUT`) and logs-and-proceeds on expiry rather than
refusing to finish, and the drain is best-effort: on a dead ingest worker or an
unacked marker the router is cleared directly and the undrained backlog is
re-downloaded by the next re-anchor.

The termination is a **repair plus a watch, not a prevention** — a class of
exception in its own right, alongside the foreground handback (residual 5) and
the cold launch (residual 9), and not a detail of either.
`InnerRelay::disconnect` fires its termination notification *before* it stores
`Terminated`, and that notification is a single permit; a connection task woken
inside that window can re-read a live status, mark the relay `Disconnected`,
sleep its retry interval and then re-open a **real socket** over the pause's
`Terminated`, holding it with 55 s pings for the rest of the gap. The race is
inside the pinned crate, between two of its adjacent statements, so the engine
cannot make it impossible: `terminate_all_relays` re-asserts up to
`RELAY_TERMINATE_ROUNDS` times and, on non-convergence, warns with a **count
only**. What is promised instead is that no such socket *survives* —
`run_monitor`'s radio-off watch cuts every connect transition that happens while
the radio is off, including the strand the loop cannot see at all (a
`Disconnected` write that landed *before* the pool's `Terminated` store), and
`LiveSyncCore::unrequested_connections` is how many there were. A non-zero count
is the honest reading of this promise, not a contradiction of it.

A pause that has nothing to send runs that same teardown on its own, so the gap
before the first burst is covered too. The three **relay-contacting** Dart
maintenance timers — KeyPackage, relay-list and the 15-min subscription-health
tick — are foreground-only on this branch: `suspendForBackground` cancels all
three at the pause, health is gated again where it fires and the other two at
arming only. The burst *is* their repair, at 72–168 s rather than 15 min. The
fourth timer is **not** foreground-only in that sense; it is residual 2's second
case. Pinned by `INV-R-BACKGROUND-PRESENCE-ONLY-AT-PUBLISH` and
`scripts/ci/check_engine_client_options.sh` — which gates the pause body's
*shape* (no `forget_*`, no literal `client.shutdown()`, no timer inside
`terminate_all_relays`, the FFI forwarding, the publish pool holding no REQ) and
not the order of its steps; see that invariant's `residual` for what CI does and
does not hold here.

What a relay learns depends on its role. A **circle** relay sees the device
present at every **burst** instant and absent between them. Since
`PUB-COALESCE` that presence **coincides** with the `kind:445` it carries on
essentially every burst — one burst publishes every publish-eligible circle — so
what is left over is not a fraction but two things, both of them residual 11:
the four narrow classes in which a REQ/CLOSE arrives with **no** `kind:445` for
the circle it re-anchored, and a burst **length** that scales with the circle
count. An **inbox-only** relay, one holding this
account's `kind:10050` inbox but none of its circles, carries no `kind:445` at
all: where it used to see one continuous socket it now sees a REQ/CLOSE pair
every 72–168 s (the 120 s nominal cadence, jittered by ±40 %), which is itself
the inference *"this pubkey is background-sharing right now"* for that relay
class alone. The lever is
`INBOX_BURSTS_PER_REQ`, the number of background bursts between two inbox REQs:
raising it so that `k × kLocationUpdateInterval ≥ 10 min` removes the cadence
signal at the cost of up to that much background invitation latency, which is an
accepted decision (OD4-b) currently blocked on a separate defect. At the shipped
value of that constant the inference stands, and it is accepted here rather than
mitigated.

Eleven residuals, none of them optional:

1. **72–168 s is the stationary cadence, not a ceiling, and the motion trigger
   publishes outside the burst plane.** A movement-driven publish goes out
   through the location publisher rather than through the burst coordinator and
   issues no REQ, so it is a publish instant holding no subscription and the
   sentence above survives it. Two things it does change. Its socket is the
   publish pool's, which the burst plane does not own: it is closed by the next
   burst's teardown, or failing that by the pool's own idle sleep, which is
   **(60 s, 70 s]** by construction — a 10 s idle timeout polled once a minute
   from inside the connection task — not "within seconds". And while the user is
   moving, the floor between publishes is `kLocationPublishOverlapGuard` (60 s),
   so 72–168 s describes a stationary device and never bounds how often a
   backgrounded one connects.
2. **"No relay traffic between bursts" — never "no timer wake", and the
   periodic one is not gone either.** Two cases, both CPU-only and neither
   contacting a relay. (a) A subscription repair armed *before* the pause keeps
   the deadline it already had and fires once, up to `BACKOFF_MAX_SECS` (30 s)
   into the pause; it finds the engine paused, re-parks, and arms no new
   deadline while paused — at most once per pause. (b) The public-profile
   anti-entropy sweep is the fourth `MaintenanceSchedulerNotifier` timer and the
   one `suspendForBackground` does **not** cancel: `_armProfileAntiEntropy` has
   no arming gate, the gate is inside `_runProfileAntiEntropyTick`, and the
   backgrounded branch *re-arms itself* before returning. So it keeps firing for
   the whole background window at ~45 min ±25 % — roughly 9–14 wakes over eight
   hours. It reaches no relay (the tick returns before
   `MemberProfileRefreshNotifier` is touched) and it opens no socket, so nothing
   above is falsified; what is falsified is "no periodic wake". Only the three
   relay-contacting timers are foreground-only, and only those three are what
   `foregroundGatedTimersArmedForTest` pins.
3. **`since` ≈ the previous burst is true of the GROUP plane only.** Each
   circle's REQ opens at its persisted cursor less
   `GROUP_RESUBSCRIBE_BUFFER_SECS`. The inbox REQ does not: every burst open is
   a re-subscribe, and a re-subscribe carries `INBOX_RESUBSCRIBE_LOOKBACK_SECS`
   (2 days + 1 hour), so at the shipped `INBOX_BURSTS_PER_REQ` every burst asks
   each inbox relay to replay **49 hours of gift wraps keyed on this device's own
   `#p`**, under a stable subscription id. Narrowing that window is not an
   available fix — NIP-59 backdates a wrapper by up to 48 h, the extra hour is
   the clock-skew margin, and a wrap below the floor is lost *silently*, which is
   indistinguishable from an invitation that was never sent. The lever is the
   fold period, not the lookback.
4. **A crash mid-burst does NOT self-heal, and the engine still does not
   recover a group wedged this way — but a background burst no longer creates
   one (owner decision OD4-c, both halves implemented 2026-09-09).** The
   underlying MDK behaviour is unchanged and is the reason the control exists: a
   group left one epoch behind with a staged commit on disk while peers move on
   buffers every later peer commit un-chainably, for two independent reasons at
   the pinned rev — a re-fetched own commit comes back terminal (`OwnEcho`) and
   is discarded, and the engine's crash-recovery path short-circuits for any
   staged commit that removes a member, so `PendingCommitRecovered` is never
   emitted for this case at all. Nothing here describes a recovery, because
   there is none to describe: no re-REQ restores it.

   **What the control removes.** A receive-side auto-commit is always
   removal-bearing — it commits a departing peer's `SelfRemove` — and inside a
   BACKGROUND burst it is now neither published nor rolled back. It is parked as
   a durable per-circle obligation, the durable row written before the in-memory
   park, and published only by the next FOREGROUND pass under the same Rule-13
   ladder; a publish that gets no relay ack stays owed and is retried. So the
   burst opens no publish-before-apply window for the OS to end mid-flight,
   which is the exposure P4's premise created. Rolling back instead is not the
   safe alternative it looks like: at the pinned rev it is a permanent, silent
   DROP of the removal — the engine discards its in-memory auto-commit schedule
   before staging, `publish_failed` does not re-arm it, and a redelivered
   proposal short-circuits on its own durable record — so the departing member
   would keep deriving the circle's keys until some unrelated commit moved the
   epoch. Rule 13 is upheld throughout: nothing confirms before a relay ack.

   **What it detects.** A circle that is wedged anyway — the engine's own
   terminal verdict, or a parked eviction whose session died — is now reported
   as its own per-circle terminal signal naming the pseudonymous
   `nostr_group_id` (Rule 4), where it used to be flattened into a per-event,
   self-clearing status that named no circle. The repair is a re-invite.

   **What remains, and none of it is optional to state.** (a) The verdict is now
   **consumed**: the live-sync status handler reads it ahead of its null-reason
   early return, resolves the circle and marks it blocked, and the
   circle-details banner names that circle and offers a re-create which opens
   the create flow with the circle's display name pre-filled and touches the
   broken group not at all, so the cached roster stays readable beneath it. No
   new copy was needed — the affordance reuses a string already shipped in every
   locale. What remains here is a **delay**, and it is deliberate: the mark
   requires two observations of the same circle in different re-anchor
   generations, counted off the re-anchor marker on the same ordered stream
   rather than off a clock, because one verdict can race a remaining peer's
   healing commit and telling a user to rebuild a circle that works costs them
   the whole roster's invitations. So the banner appears on the SECOND
   foreground open — the same horizon as the repair itself, since a foreground
   open is also the only place a parked eviction is published, so the wait costs
   the announcement and no recovery. (b) While a parked eviction stands, that
   circle's sends are refused by the engine's `Stable`-only send gate until the
   next foreground pass — on a rarely-foregrounded device, a real gap in that
   circle's sharing, surfaced nowhere. (c) A device wedged by a session that
   predates this code carries no durable row and is **undetectable**: no read
   accessor at the pinned rev exposes whether a staged commit is present. (d) A
   circle a remaining peer already healed can be reported once, until that
   circle's next successful publish discharges the row. (e) The SUPPRESSION is
   scoped to the live-sync burst plane: the **Android background catch-up
   sweep** still publishes a removal-bearing auto-commit rather than parking
   one. That is now a **finding** rather than the argument this list
   used to record, and it is stated at the call site and asserted by tests: a
   park needs somewhere to be redeemed, and a `PendingStateRef` is valid only
   inside the session that staged it, so a sweep driven from a background
   isolate — which holds its own manager over the same database file — could
   never publish what it parked. Publishing there trades a removal that usually
   lands for a circle that is certainly wedged, so it publishes; what it pays
   instead are the two guarantees that are now **tree-wide**. It records the
   obligation BEFORE the publish, so a wake window the OS ends mid-publish
   leaves a durable row and the next foreground open reports the wedge rather
   than it being invisible; and it never rolls the commit back on a no-ack,
   because that is the permanent silent drop above — the obligation simply
   stands. Both guarantees live at the one rung all four planes share
   (`CircleManager::publish_failed` for the no-rollback half,
   `CircleManager::owe_removal_publish` for the write-ahead half), which is what
   makes them bind the two planes that resolve the commit from Dart as well as
   the two that resolve it in Rust. (f) **No plane can redeem an obligation
   another session recorded.** The live `PendingStateRef`s die with their
   isolate and hydrate short-circuits on a staged commit that removes a member,
   so nothing at the pinned rev can re-derive a staged eviction from group
   state. A row the Android foreground service or the WorkManager catch-up
   worker wrote is therefore REPORTED on the next foreground open and never
   published: that wedge is loud and terminal, and its repair is re-creating the
   circle. Strictly better than the silent permanent drop it replaced, and not a
   heal. Both halves of the control are covered by tests that redden when they
   break, and so are the two tree-wide guarantees and the consumer in (a); (b)
   through (d) and (f) are not, because each is an absence rather than a
   behaviour.
5. **A teardown that stops at the foreground handback does not close the publish
   pool.** Each teardown link re-reads whether the foreground has taken the
   engine back and stops there rather than pausing an engine the foreground now
   owns; a teardown that stops before the pool shutdown leaves that pool open.
   Deliberate: the app is on screen and publishing over it, and forcing the
   shutdown at the handback would race the resume publish — the shutdown
   disconnects with no drain of *ordinary* publishes — and cost a cold reconnect
   at the moment the user is watching the map. It is bounded rather than
   open-ended: the next pause closes it, through the burst that pause drives or
   through the idle close it takes instead, and a teardown that outlives the
   widget still closes the pool handle captured at startup.
6. **The past-epoch outer peel is pinned by no gate of ours.**
   `security_rule_gates.rs` pins the engine's epoch retention window
   (`DEFAULT_MAX_PAST_EPOCHS`, `app_message_past_epoch_limit()`), but the outer
   peel a one-epoch-behind burst relies on runs on
   `ConvergencePolicy::max_rewind_commits`, taken from the upstream default and
   pinned nowhere in this repository. Extending the gate is owed; until it lands
   this part of the guarantee rests on an upstream default rather than on a test,
   and is stated that way rather than as unconditional.
7. **An account with nothing publish-eligible receives NOTHING while
   backgrounded.** The teardown runs at the pause instant even when no circle is
   eligible to publish — a fresh install, the last circle left, every circle
   blocked, legacy-orphaned or still pending — and with no eligible circle there
   is no publish tick, so nothing reopens the engine until the next foreground.
   Gift-wrapped invitations (`kind:1059`) therefore arrive on resume rather than
   in the background, where the inherited foreground REQ used to deliver them.
   This is the intended trade — the alternative is an unbounded standing REQ for
   an account sharing with nobody, and the background-wake rules forbid a Dart
   timer to reach the inbox any other way — but it is a real change to the
   receive plane and is not presented as pure gain.
8. **The 60 s resume re-anchor throttle is bypassed on this branch.** A resume
   re-anchors whenever the engine is paused or a burst is still in flight, and
   after the teardown the engine is paused at essentially every resume here, so
   the throttle never fires. The bypass is individually correct — a paused engine
   held no REQ, so "the first re-anchor already covered that window" is false of
   it — but the cost recurs: a quick out-and-back (app switcher, lock and unlock,
   fetching a code) now costs a pause, a publish-pool reconnect and a 49 h `#p`
   gift-wrap replay each time, where before it cost nothing. Over a long
   background window the trade is clearly a win; over rapid app-switching it is a
   loss. A notification-shade pull is unaffected, because
   `AppLifecycleState.inactive` does not reach the pause path.
9. **A cold launch that backgrounds before the engine has started comes up Live
   in the background.** The engine start is launched from the shell's startup
   tasks without being awaited. A pause landing first runs the teardown against a
   session that does not exist yet — the pause returns "no session", which is
   caught and logged — and the start then completes in the background, with
   standing REQs and the 55 s pinger. Bounded by the first publish tick's own
   teardown in the ordinary case, and unbounded in residual 7's case, where no
   tick is coming. The periodic backstop that re-anchors a paused engine cannot
   make this worse — it is gated on the app being foregrounded, precisely so a
   re-arm landing after a pause cannot put a REQ back — and it does not close it
   either.
10. **The idle close can cut an ordinary in-flight publish.** The publish-pool
    shutdown disconnects with no drain of ordinary publishes, and the pause path
    now reaches it where it previously did not. Security Rule 13 is **upheld** —
    commit-critical ladders are awaited, unbounded, before the shutdown — and the
    motion trigger is largely self-excluded, because the idle arm is taken
    precisely when the last publish is still inside the same 60 s guard the
    motion trigger obeys. The exposure is therefore at most one location sample,
    superseded by the next tick. For residual 7's case it is strictly safer than
    before, where the same pool was shut with no drain at all.
11. **A circle relay's REQ/CLOSE pair still does not coincide with this
    device's `kind:445` for its circle — in four narrow classes — and the
    burst now has a LENGTH that leaks the circle count.**
    `LiveSyncCore::resume_burst` re-anchors the whole stored live set — every
    `active.group_subs` entry — and calls `client.connect()` on the whole relay
    union, while `BackgroundBurstCoordinator._publishPass` sends to
    `_pendingCircles()`. Since `PUB-COALESCE` those two sets are the same set on
    essentially every burst: one burst publishes every publish-eligible circle,
    so a relay carrying circle B sees the REQ/CLOSE pair and this device's
    `kind:445` for B together. What remains is four classes, not a fraction.
    (a) The open precedes the publish *unconditionally*: if
    `openBurstPublishWindow` returns null — no identity, the prominent
    disclosure not accepted, location permission revoked, a one-shot GPS fix
    that timed out — or consent flips inside the pass, the pass clears the due
    set and returns, and the burst that already re-issued every REQ publishes
    **zero** `kind:445`. (b) The two sets are read from different places, and
    the subscription side is a **stored snapshot**. `resume_burst` re-anchors
    `active.group_subs`, which is mutated only by `subscribe_circle`,
    `unsubscribe_circle` and the relay-update paths — all driven by
    `LiveSyncResubscriber._applyDelta` off a `circlesProvider` emission, and
    nothing re-derives it while backgrounded (the coordinator drives its work by
    direct call precisely because a provider invalidation schedules a rebuild a
    paused app never performs). So the subscribed set is every **accepted**
    circle *as of the last foreground emission*
    (`LiveSyncResubscriber.groupsForCircles`), while the publish target is
    re-read **fresh** at encrypt time (`encrypt_location` → `get_circle` →
    `circle.relays`) and `filterPublishEligibleCircles` additionally excludes an
    `isLegacyOrphaned` circle and one the engine has flagged `Unrecoverable` — so
    such a circle is re-anchored on every burst and never published to at all, a
    permanent mismatch rather than a fractional one. (c) A send that fails or is
    deferred by the engine (`CircleError::SendDeferred`), and the tail of a
    roster past `kMaxCirclesPerBurst`, which the burst itself defers to the next
    tick. (d) A change applied **during** the background window, where the two
    sides diverge because only one of them is re-read. A circle **removed**
    while backgrounded keeps its `#h` REQ re-anchored on every burst with no
    `kind:445` behind it, unbounded until the next foreground emission reaches
    `_applyDelta`; and a **relay-set change** applied while backgrounded leaves
    the OLD relays subscribed and the NEW ones published to, so each set sees one
    half of the pair.
    So the argument this section makes correctly for inbox-only relays ("a
    REQ/CLOSE pair is itself an inference") still applies to circle relays, now
    minus a correlation with a `kind:445` that is almost always there.
    **What coalescing added** is the burst's *duration*: the union connection is
    held across the whole staggered publish pass, so its connect→disconnect span
    grows with the number of eligible circles (saturating at
    `kMaxCirclesPerBurst`) and is a single-relay estimator of that count for
    every relay in the union — one carrying a single circle, and an inbox-only
    relay carrying none. That is registered as `PUB-COALESCE`, not as a lever:
    the levers here are `INBOX_BURSTS_PER_REQ` for the inbox plane only, and
    for the group plane nothing short of per-circle bursts, which would multiply
    connections by N, restore the per-circle wake cost OD3 removed, and is not
    proposed.

The complementary arm is simpler and is stated with it: on **iOS with background
sharing off**, and on **Android in both toggle states**, the pause STOPS the
engine rather than pausing it (`MapShell.shouldStopLiveSyncOnPause` =
`!(isIOS && backgroundSharingEnabled)` — "every pause except the one whose
process keeps receiving"), and stopping is the recoverable direction, since the
resume heal restarts a stopped engine where a paused one is invisible to it. The
iOS sharing-off arm is the one that rule used to miss: `!isIOS` made it false
there, so a user who had explicitly turned background sharing off still held
every per-circle REQ, the inbox REQ, the engine socket and the 55 s pinger until
the OS suspended the process.

## Public Nostr Profiles (kind 0 + Blossom)

> **Owner-directed privacy reversal (recorded 2026-07-12; made
> public-by-default 2026-07-16).** Haven is migrating from MLS-encrypted
> in-group profile sharing (display names piggybacked in location JSON, avatars
> as padded kind-445 chunk messages) to standard public Nostr profiles,
> matching the White Noise reference app. The statements this section
> previously made — that a profile picture is never published as a kind-0
> profile, never uploaded to Blossom, and never sent over HTTP — **no longer
> hold once the user saves a profile.** Design of record:
> `docs/PUBLIC_PROFILE_MIGRATION_PLAN.md`. The legacy MLS avatar system has been
> removed by the cutover. The `HAVEN_PUBLIC_PROFILES` build flag (default ON)
> now only gates whether the app *fetches and displays other members'* public
> profiles — it is never a user-facing opt-out for publishing one's own.

**Public-by-default (no consent toggle).** Publishing a public profile is
**unconditional**: saving a display name or photo publishes the kind-0 (and
uploads the photo) immediately — there is no consent flag and no publish-time
gate. That a saved profile is public on the Nostr network is disclosed to the
user in **onboarding and on the Identity settings page** (a UI concern), not
enforced by a toggle in the Rust layer. Retraction actions
(`remove_my_profile_picture`, `delete_my_public_profile`) are a no-op unless a
profile/picture was actually published — they must never CREATE a public
footprint (blank kind-0 / kind-5) for a pubkey that has no prior published
profile (the retraction no-op gate `has_published_profile`, CI-enforced).
`nip05` / `website` (DNS-verifiable dox handles) are never written by Haven's
UI.

**What becomes public.** A kind-0 metadata event (`name`,
`display_name`, `picture`) under the user's Nostr **identity** pubkey on public
relays, and the profile photo as an **unencrypted, content-addressed blob** on
a Blossom server (default `https://blossom.primal.net`; the operator sees the
uploader's pubkey and IP). Anyone — not just circle members — can read both,
and the pubkey ↔ name/photo binding is **effectively permanent** (see the
permanence caveat below). Member profiles are resolved from relays by pubkey
(the MLS leaf's `BasicCredential.identity` IS the member's Nostr pubkey), and
pictures are downloaded by Rust and rendered from bytes — no URL ever crosses
the FFI, and `Image.network` stays banned.

**Protections that DO hold:**

- **EXIF/GPS strip before upload.** The image is decoded to raw pixels and
  re-encoded to a fresh JPEG (the existing `avatar/image.rs` sanitizer)
  **before** any public upload, structurally dropping EXIF/GPS/XMP/ICC/
  thumbnails. Critical for a location app — a camera selfie can embed home
  coordinates. (White Noise uploads the raw file; Haven does not.)
- **HTTPS-only Blossom.** No plaintext `http://` surface (loopback exempt in
  debug/e2e builds only); `DEFAULT_BLOSSOM_SERVER` must be `https://`.
  CI-enforced.
- **Anti-SSRF connect-time IP filtering on download.** A member's kind-0
  `picture` URL is attacker-controlled. The downloader resolves the host and
  rejects loopback / RFC-1918 / link-local (169.254/16, fe80::/10) / ULA
  (fc00::/7) / unspecified / multicast socket addresses (name-based checks are
  insufficient: DNS rebinding), disables redirects, prechecks Content-Length
  with a streamed size cap, verifies `sha256(raw) == URL hash`, and
  re-validates through the decode-bomb-defended image pipeline.
- **Identity-key-only signing.** kind-0 and kind-24242 (Blossom auth) are
  signed by the Nostr identity key — never the MLS signing key, never anything
  exporter-secret-derived. Enforced three ways: API shape (no MLS handle is
  reachable from `haven-core/src/profile/`), runtime tests
  (`event.pubkey == identity`), and the CI import-boundary check (the profile
  module must not reference `crate::circle`, `crate::nostr::mls`, `mdk`, or
  `exporter_secret` — `scripts/ci/check_profile_privacy_boundaries.sh`).
- **No group identifiers in profile paths.** Profile fetches are
  `authors` + `kind 0` only — no `h` tag, never a circle's relays; the cache
  is keyed by pubkey with no circle/group column; Blossom URLs are
  content-addressed; `published_events` rows carry no group column.
  CI-enforced (no circle/group tokens, kind-0 construction confined to the
  profile module).
- **kind-24242 never reaches a relay.** Blossom authorization events travel
  only in the HTTP `Authorization` header.
- **Fetch-side minimization.** Reads use the AUTH-free discovery relays with
  bounded one-shot batched fetches (union of all circles' members, TTL cache,
  no standing kind-0 subscription) and never answer NIP-42 AUTH, so the relay
  cannot attribute the fetcher.

**Residual risks (honest limits):**

- **Permanence.** Kind-0 is a replaceable event, and replaceable ≠ erasable:
  relays, indexers, and archives retain revisions. Once published, the
  pubkey ↔ name/photo association cannot be reliably clawed back.
- **Viewer-IP leak to the picture host.** Viewing other members' photos
  contacts their chosen host (see *Network Threat Model*), including the
  attacker-chosen-host variant. Bounded by the anti-SSRF filter; not
  eliminated for legitimate public hosts. VPN recommended.
- **Roster-association leak.** Profile fetches reveal to the discovery relay
  which pubkeys a client is interested in (see *Network Threat Model*).
- **Best-effort delete, and the photo is NOT part of it.** "Delete public
  profile" republishes a blank kind-0 and emits a NIP-09 kind-5 deletion —
  both cooperative-server best-effort, and per the retraction no-op gate they
  only run when a profile was actually published. **No Blossom DELETE is
  issued.** This bullet claimed one until 2026-08-13; there is no `.delete(`,
  `Method::DELETE` or `"DELETE"` anywhere under `src/profile/` or `src/avatar/`,
  and the FFI's own doc comment on `delete_my_public_profile` records the blob
  DELETE as deferred. The uploaded image therefore survives profile deletion
  indefinitely, as does any copy already fetched. The user-facing copy has
  always said so, and still does — `photoHeaderRemoveBody` ("the image file
  stays on the server that hosts it") and `identityAdvancedDeleteBody` ("your
  photo on the image host that stores it"); a third carrier,
  `privacyPublicProfileRemovalIsNotDeletion`, was cited here until 2026-09-09
  and no longer exists, because the owner removed the Privacy page and every
  `privacy*` key with it on 2026-08-29 (`docs/privacy/README.md` — such a key
  must not be recreated). It was this document that was wrong about the DELETE,
  in the direction that would make a maintainer read the copy as over-cautious.
  Nothing here guarantees erasure.
- **Same pubkey as your circles.** The public profile is not a separate
  persona: it binds the name/photo to the same pubkey used for circle
  invitations and KeyPackages. The onboarding and Identity-page disclosures
  state this explicitly.

**Legacy MLS avatars (removed at cutover).** The previous system — E2E-encrypted
avatars sent inline as padded kind-445 chunk messages, stored only as
SQLCipher-encrypted BLOBs, with no relay/CDN/HTTP surface — was **removed** at
the public-profile cutover, together with its
`scripts/ci/check_avatar_privacy_boundaries.sh` guard. The one still-relevant
invariant that guard enforced — the global `Image.network` ban (Flutter must
render pictures from Rust-downloaded, anti-SSRF-filtered bytes, never a URL) —
now lives in `scripts/ci/check_profile_privacy_boundaries.sh` (Check 1). For the
full historical design notes (padding/burst residuals, sticky-avatar forward
secrecy, per-circle salted blob keys, `FLAG_SECURE`), see this section in git
history prior to 2026-07-14.

### Profile-plane relay separation — accepted deviations

Haven routes kind-0 profile traffic to a curated relay pool
(`profile::relay_pool`) that is disjoint from every relay carrying the user's
kind-445 / kind-1059 traffic, and requests each member's kind-0 from exactly
ONE pool relay chosen by a stable salted rendezvous hash
(`profile::assignment`). A relay therefore sees either the user's encrypted
location traffic or their profile queries — never both. The residuals below are
owner-accepted; they are deviations of record, not open bugs.

#### The guarantee is bounded — collisions are expected (P1)

**Achieved:** the two planes are relay-disjoint; no single REQ ever discloses a
co-membership set (one author per REQ); no relay observes a whole roster; each
pool relay sees an install-specific ~`1/N` sample of the *blended union across
all circles*, which it cannot partition back into circles.

**NOT achieved:** "no relay ever learns two members of the same circle."
Assignment hashes the pubkey, so collisions follow the birthday bound — roughly
**79 %** for a 5-member roster over an 8-relay pool. Collision-free-per-roster
assignment would require the profile module to know roster membership, which
its import boundary forbids by design (that boundary is what keeps circle
identifiers out of the profile plane). What a collision leaks is "this install
is interested in these two pubkeys" — **not** "these two pubkeys share a
circle", because the queried set is the cross-circle union. Do not restate this
guarantee more strongly than the code delivers.

#### Publish fans out to the whole pool (P2)

A peer's assignment salt is private to their install, so Haven cannot know
which pool relay a peer will read it from. Publishing the user's own kind-0 to
a subset would make them invisible to every peer assigned elsewhere, so publish
targets the **entire** usable pool. Consequence: every pool relay learns
`(our pubkey, our IP)`, and the one that also serves our reads can link our
identity to our ~`1/N` contact sample. Reads remain unauthenticated — the fetch
path is built with no signer and structurally cannot answer a NIP-42 challenge
— so this is IP-level linkage only, never an authenticated one.

#### No kind-10002 for the profile plane (P3)

Haven deliberately publishes **no** NIP-65 relay list naming the profile pool.
Such an event is signed by the identity key and publicly fetchable, so it would
hand any observer — including a circle relay operator who already sees this
account's gift wraps and KeyPackages — a pointer joining the identity to its
profile plane, reconstructing the exact cross-plane link the pool exists to
break, and more reliably than traffic analysis could. Accepted cost:
outbox-model external clients (Damus, Amethyst) may fail to resolve a Haven
user's profile; mitigated by biasing the pool toward widely-polled indexers.
Enforced by `check_profile_privacy_boundaries.sh` (Check 10) and by
`RelayType::Profile::to_kind()` returning `None`.

#### Merge-base narrowing reverses MEDIUM-4 (P4)

The kind-0 merge base is now fetched from the pool only. Haven will therefore
stop seeing kind-0 edits another client made on relays outside the pool, so a
Haven save can drop fields set elsewhere. This is a **deliberate reversal** of
the earlier MEDIUM-4 fix (`self_merge_base_relays`, now deleted), which existed
precisely to prevent that. It is accepted because the alternative — reading the
merge base from the user's NIP-65 write relays — is the cross-plane read this
redesign eliminates. Do not "re-fix" MEDIUM-4 by widening the merge-base relay
set.

#### The assignment salt is never rotated (P5)

Rotation looks privacy-preserving and is strictly worse in aggregate: each
rotation discloses every contact to an **additional** relay, so after `k`
rotations up to `min(k, N)` relays know each contact, converging on full
disclosure. A stable per-install salt fixes each author's relay for the life of
the install, so the disclosure set never grows. Accepted cost: the assigned
relay accumulates a durable "this IP is persistently interested in this pubkey"
observation. The salt is zeroized on drop, redacted in `Debug`, and never
crosses the FFI.

It must also not outlive the identity: a second identity on the same device that
inherited the first's salt would reuse its assignment, and any pool relay serving
both could link them. Two distinct paths destroy it, and they are proven by two
distinct tests — do not read either as covering the other:

* **Profile delete** (`delete_my_public_profile`) calls `wipe_all_profiles`,
  which drops the salt row inside its own transaction. Pinned by
  `profile_relay_salt_is_cleared_by_wipe_all_profiles`.
* **Logout** does *not* reach `wipe_all_profiles` at all. It deletes the whole
  `circles.db` file plus its WAL/SHM/journal sidecars (`delete_circles_db_files`
  in the FFI wipe), which takes the salt with it *because the `user_settings`
  row is the salt's only persistence* — there is no keyring entry and no sidecar
  copy. That is the load-bearing property, and it is what
  `profile_relay_salt_does_not_outlive_the_circles_db_file` pins: it mints a
  salt in a file-backed database, deletes the same file set the logout wipe
  deletes, reopens, and requires an independently minted salt.

#### IP-level linkage is out of scope (P6)

Haven ships no Tor or proxy support. A pool relay observes the user's IP on
both publish and read. The salted partition limits **what** a relay learns, not
**who** it is talking to. Any future claim of network-level unlinkability needs
transport work, not assignment work.

#### Historical contamination is unrecoverable (P7)

The contamination ledger (`circle::contamination`) is append-only precisely
because contamination is historical: a relay that routed a circle's kind-445
last month saw those events, and leaving the circle does not un-see them. But
Welcome-delivery relays were persisted **nowhere** before this change — the
cascade resolves them from the invitee's KeyPackage at send time — so relays
that received a Welcome before the upgrade cannot be folded in by
`refresh_contamination_ledger` and will not be excluded. Circle-routing and
user-relay contamination backfills correctly; the Welcome set does not.

## Dependency Auditing

Run security audits regularly:

```bash
# Install cargo-audit
cargo install cargo-audit

# Run audit
cargo audit

# Check for outdated dependencies
cargo outdated
```
