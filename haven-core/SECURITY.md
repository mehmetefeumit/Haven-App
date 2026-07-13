# Security Policy

## Supported Versions

| Version | Supported          |
| ------- | ------------------ |
| 0.1.x   | :white_check_mark: |

## Reporting a Vulnerability

If you discover a security vulnerability, please report it privately by emailing the maintainers. Do not open a public issue.

## Known Vulnerabilities

None currently tracked. New advisories are surfaced by the weekly
`cargo audit` CI job; document them here as they appear.

## Network Threat Model

Haven does not implement network-level anonymity. Relay connections originate
from the user's real IP address, which a relay operator can correlate with
the pubkeys it sees publishing events. Users who require IP-level unlinkability
should run Haven behind a VPN.

## Security Architecture

### Database Encryption

Haven uses SQLCipher (encrypted SQLite) for all persistent databases. Encryption keys are stored in the system keyring:

- **macOS**: Keychain
- **Linux**: GNOME Keyring / KDE Wallet / Secret Service
- **Windows**: Credential Manager

| Database | Purpose | Service ID | Key ID |
|----------|---------|------------|--------|
| `haven_mdk.db` | MLS group state (via MDK) | `com.oblivioustech.haven` | `mdk.db.key.default` |
| `circles.db` | Circle metadata, contacts, memberships | `com.oblivioustech.haven` | `circles.db.key` |
| `tiles.db` | Encrypted map-tile cache | `com.oblivioustech.haven` | `tiles.db.key` |

All databases use 256-bit AES encryption with raw keys generated from `OsRng`.
Existing unencrypted `circles.db` files are automatically migrated to encrypted
storage on first access via SQLCipher's `sqlcipher_export()` function.

**Linux requirement**: A D-Bus Secret Service provider must be running
(GNOME Keyring, KDE Wallet, or KeePassXC). Without one, circle
operations will be disabled with a descriptive error.

**iOS keychain accessibility (owner-approved tradeoff)**: On iOS the three
SQLCipher DB keys (`mdk.db.key.default`, `circles.db.key`, `tiles.db.key`) are
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
tears down all MLS state: it deletes the `haven_mdk.db` and `circles.db` files
**and removes their keyring keys** (so neither the ciphertext nor the key
survives), after resetting the sync cursors and staged-commit markers. A
one-way `_wiped` latch on the circle service closes a re-open race: the M8
maintenance timers run on their own cadence regardless of the (flag-gated-off)
live-sync engine, so a maintenance tick could otherwise call into the circle
service *after* the wipe and cause SQLite to re-create a fresh, decryptable
`circles.db` + a fresh keyring key. The latch refuses any re-open once logout has
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
  never authors MLS state; its `decrypt_receive_only` path takes the
  process-global `WRITER_LOCK` via `try_acquire_background()`, yielding
  (`Skipped`, no cursor advance, re-fetched next sweep) to any authoring writer
  rather than blocking — so a background wake can never fork a group against a
  concurrent foreground/FGS write.
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

Per-wake relay connections are short-lived (one sweep, then shutdown); the
persistent-connection privacy disclosure is a separate M11 concern (the M6
live-sync engine). Wake markers logged for diagnostics are presence-only
(fixed strings + counts) — never coordinates, pubkeys, group ids, or event ids.

The iOS keychain accessibility tradeoff that lets a locked-but-unlocked-since-
boot device read the SQLCipher key during a background wake is documented under
*Database Encryption* above (owner-approved, `ThisDeviceOnly`, never synced).

### Test-Utils Feature

The `test-utils` feature enables unencrypted storage for testing purposes. This feature:

- Is gated with `#[cfg(any(test, feature = "test-utils"))]`
- Produces a compile error if enabled in release builds
- Should NEVER be enabled in production

### MLS Security

Haven implements the Marmot Protocol for MLS over Nostr. Key security properties:

1. **Key Separation**: MLS signing keys are separate from Nostr identity keys
2. **Ephemeral Keys**: Each group message uses a new keypair
3. **Forward Secrecy**: Provided by MLS epoch rotation
4. **Memory Safety**: Secrets use `Zeroizing<T>` for automatic memory clearing

### Post-Compromise Security window from polling cadence

Haven uses one-shot relay polling rather than persistent WebSocket
subscriptions (see `docs/FLUTTER_RUST_BRIDGE.md` and `haven/lib/src/pages/map_shell.dart`).
Evolution events (kind:445 Commits and Proposals) are polled on a
60-second timer with a 55-second overlap guard. Location publishes from
remaining members occur on the jittered cadence documented above
(uniform on `[72, 168] s`).

Consequence: after an admin issues a removal Commit, a removed member
can still derive the decryption keys for the **outgoing epoch** until
at least one remaining member processes the Commit and publishes a new
location under the new epoch. The worst-case window is approximately:

```
T_pcs ≈ T_evolution_poll + T_publish_jitter_max ≈ 60 s + 168 s ≈ 228 s
```

Typical case is closer to `T_evolution_poll/2 + T_publish_jitter_mean ≈
30 s + 120 s ≈ 150 s`. During this window a removed member who continues
to receive kind:445 events (e.g., from a relay they already know) can
decrypt locations published before the remaining member's epoch
transition lands.

What this provides (mitigations in place):

- The removed member loses access on the next epoch transition,
  bounded by `T_pcs` above — they cannot decrypt indefinitely.
- As of M5, periodic self-update is disabled, so a group with NO
  membership change does not re-key on a timer — stale leaf material is
  only rotated by a real membership change. See "Self-update disabled
  (M5)" below for the accepted forward-secrecy deviation.

What this does **not** provide:

- Sub-second post-removal cutoff. A persistent-subscription model (as
  used by White Noise for chat) would tighten this window to seconds
  but trades reliability on mobile networks (cellular NAT / iOS
  suspension / Android Doze silently break long-lived WebSockets) and
  battery cost (sustained foreground service on Android; APNs/FCM
  third-party push on iOS).

Mitigation options not currently applied:

- Tightening the evolution poll interval from 60 s to e.g. 30 s halves
  the polling component of `T_pcs`. This is a security-meaningful but
  product-level trade-off (network-frequency vs PCS window).
- Event-driven boost: after the local user issues a removal Commit,
  poll evolution at a tighter cadence (e.g. 10–15 s) for a short window
  to confirm propagation before considering the removal effective.

### KeyPackage consumption race from invitation polling cadence

Welcome events (gift-wrapped kind:1059 wrapping kind:444) are polled on
a 2-minute foreground timer; the resume hook in `map_shell.dart`
performs an immediate fetch on app foregrounding. Background polling is
not active on either platform — invitation discovery is foreground- or
resume-driven only.

MIP-00 single-consumption KeyPackages (without the `last_resort`
extension) admit a race where two inviters consume the same KeyPackage
before the invitee can rotate. The post-Welcome rotation in MIP-02 is
designed to close this window; longer invitation polling enlarges it
proportionally because the invitee's rotation lags processing of the
Welcome.

Current foreground worst-case: ~2 minutes between Welcome publish and
local rotation if the user is foregrounded but not actively resuming.
Cold-start latency is bounded by the resume hook (sub-30 s).

Mitigation and residual (M5):

- As of M5, Haven issues NO post-accept or periodic self-update (see
  "Self-update disabled (M5)" below). The MIP-02 post-Welcome rotation
  that would close the consumed-KeyPackage window is therefore NOT
  performed; this residual race is accepted. The forward mitigation is
  `last_resort` KeyPackages (MIP-00), which are not single-consumption,
  tracked separately.

### Self-update disabled (M5) — accepted MIP-02/MIP-03 deviation

Haven disables BOTH periodic (MIP-03 SHOULD) and post-join (MIP-02 MUST,
24 h) leaf-key self-update (`enablePeriodicSelfUpdate = false`).

Rationale (Haven's own — NOT attributed to White Noise): Nostr provides no
commit-serializing Delivery Service, so leaderless self-update is the
dominant generator of MLS epoch forks — two members rotating from the same
epoch and each eagerly merging their own commit diverge permanently.
Removing the periodic/post-join driver removes that generator.

**Residual fork surface (not yet closed):** concurrent MEMBERSHIP commits by
multiple admins from the same epoch can still fork — production add / remove /
leave / demote paths still eagerly finalize on publish-success. The M4
adopt-winner convergence primitive (`CircleManager::converge_commit`, proven in
haven-core tests) is the fix, but it ships flag-off and is NOT yet wired into
those paths; it takes production effect only once M3 wires it in (fed by the
settle-window). Until then, multi-admin same-epoch membership races remain a
live fork risk.

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

Accepted by the project owner; revertible once M3's settle-window + M4's
convergence make concurrent self-updates fork-safe (flip
`enablePeriodicSelfUpdate`).

Inverse risk (documented, bounded by M7): a burst of >5 membership changes
while a device is suspended could advance the group past
`DEFAULT_EPOCH_LOOKBACK` (5) for that device, rendering in-flight kind:445
events at the old epoch permanently Unprocessable. M7's catch-up bounds the
offline epoch lag.

### Bounded leave-removal window under live-sync (REV-1)

This section applies ONLY when the live-sync engine is enabled (the Phase-B
flag). With live-sync off, leaves are unaffected by REV-1 and this window does
not exist.

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

### Outer kind:445 metadata: jittered NIP-40 expiration

Each kind:445 wrapper for a **location update** carries a NIP-40
`["expiration", ts]` tag with `ts` sampled uniformly from
`[update_interval, 2 × update_interval]` seconds in the future, using
`OsRng` (CSPRNG). See `src/location/ttl.rs`.

The Dart call site in `location_sharing_service.dart` passes
`kLocationPublishMaxInterval.inSeconds + kTtlNetworkBufferSeconds`
(= 168 + 30 = 198 s) — this lifts the TTL floor above the maximum
jittered publish delay (168 s) with a 30 s network-propagation buffer,
producing an on-wire TTL window of `[198, 396] s`. See the "Publish
cadence: jittered scheduler" section below for the no-gap invariant
that motivates this choice.

What this provides:

- Bounds relay-side residency to ~1–2 publish cycles, so stale ciphertext
  does not accumulate on relays indefinitely.
- Prevents a constant-TTL fingerprint that would identify Haven clients
  among mixed MLS-over-Nostr traffic on shared relays.
- Defense-in-depth against relay replay past the inner
  `LocationMessage.expires_at`. Receivers also enforce the expiration
  tag in `CircleManager::decrypt_location` with a 60-second
  clock-skew grace window.

What this does **not** provide:

- It does not hide publish cadence on its own — publish-cadence
  fingerprinting is addressed separately by the jittered scheduler
  documented in the next section.
- It does not prevent a relay (or NIP-42-authed observer) from estimating
  the user's local clock skew from the absolute expiration timestamp.
  A single observation leaks `±interval` worth of uncertainty, but an
  attacker observing `N` events from the same author can average
  `(expiration − created_at)` across samples; the estimate converges to
  within roughly `interval / √(12 N)` of the true mean offset, so
  repeated observation narrows the leak below one interval. Mitigation
  is bounded by the desire to keep the tag wire-format self-evident;
  we accept the residual leak.
- Welcomes (kind:444 gift-wrapped inner), commits, and proposals
  (also kind:445) intentionally do **not** carry an expiration tag —
  expiring those would break late joiners. Only the location path uses
  the jittered tag.

The randomness source is gated with a `clippy.toml`
`disallowed-methods` deny on `rand::thread_rng`; the jitter path must
go through `rand::rngs::OsRng`, which wraps `getrandom` directly
without a cached PRNG.

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
AND a 60-second overlap guard has elapsed. This piggybacks on the GPS
stream already consumed for the user's own map marker, adding no extra
battery cost. The overlap guard prevents the motion path from exceeding
the scheduled publish rate floor (72 s) by more than 12 s.

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
- The 30 s fetch polling cadence on the receiver side
  (`map_shell.dart`) is fixed and creates a predictable arrival
  pattern at relays. See "Post-Compromise Security window from polling
  cadence" below for the related security-side trade-off.

#### Independence from the TTL jitter, and the no-gap invariant

The publish-interval jitter and the outer-event TTL jitter are sampled
**independently** — coupling their per-tick values would entangle the
relay-residency bound (TTL) with arrival-time unlinkability (publish
interval), two knobs we want to tune separately.

However, the *range parameter* of the TTL jitter is deliberately
chosen so that a relay always has at least one non-expired event from
every active publisher. Formally, for events `E_n` published at time
`T_n` with TTL `τ_n`, gap-freeness requires:

```
δ_n ≤ τ_n   for every n   where   δ_n = T_{n+1} − T_n
```

Worst-case: `δ_max ≤ τ_min`.

With `PUBLISH_INTERVAL_JITTER_FRACTION_BP = 4_000` and a 2-minute
nominal publish cadence, the publish gap `δ` is uniform in
`[72, 168] s`, so `δ_max = 168 s`. The Dart call site passes
`update_interval_secs = 198 s` (`publish_max + 30 s` network buffer)
to `encrypt_location`, which makes the Rust-side TTL `τ` uniform in
`[198, 396] s`. Thus `τ_min = 198 s > δ_max = 168 s` ✓ — a relay with
any queried publisher always has a valid event, with a 30 s margin for
network propagation latency.

`RECEIVER_EXPIRATION_GRACE_SECS = 60 s` sits on top of this as
clock-skew defense-in-depth against a replay-near-boundary attack;
it is **not** load-bearing for gap coverage.

Cost of the 2-minute cadence: relay-side residency is `[198, 396] s`
(mean ≈ 297 s). More frequent publishes increase relay traffic by ~2.5×
compared to the prior 5-minute cadence, but each event carries a
shorter TTL so mean residency decreases from 630 s to 297 s. We accept
the traffic cost for the UX improvement (worst-case viewer staleness
drops from ~7.5 min to ~3.5 min for scheduled publishes, and to
sub-minute via the motion-triggered publish path).

A low-priority residual: a relay that correlates both timestamps
(`created_at`, `expiration`) per event could detect the joint
distribution across consecutive events. Filed as a follow-up.

### Relay-observable metadata and correlation (accepted)

Beyond event *content* (which is E2E-encrypted) and the timing mitigations
above, a curious or malicious relay still observes connection- and
protocol-level metadata. The following are **accepted** residuals — none
expose location, usernames, or key material, but they are documented so the
threat model is honest:

- **Relay-session linking.** Haven uses one persistent `nostr-sdk` client per
  relay. A relay that serves *both* a user's gift-wrap inbox (kind 1059 REQ
  filtered by `#p = <user pubkey>`) and that user's group messages (kind 445
  by `#h = <nostr_group_id>`) over the same connection can correlate the real
  identity pubkey with group membership by connection continuity — even
  though kind-445 events themselves carry only ephemeral author keys.
  Protocol design already separates inbox relays (1059) from circle relays
  (445), so this only bites when the *same* relay serves both roles for a
  user. Full mitigation needs per-fetch ephemeral connections or onion
  routing (out of scope for v1).

- **Stable `h`-tag traffic analysis.** `nostr_group_id` is a permanent
  per-circle identifier. A relay can track a circle's message volume,
  cadence, and approximate membership (by counting distinct ephemeral author
  keys over time). The ephemeral-key-per-message design prevents *sender*
  attribution, and the jittered publish cadence (above) blunts timing
  analysis, but the `h`-tag linkability itself is a MIP-03 constraint with no
  app-layer fix.

- **Superseded commit during multi-admin convergence (M6).** Under the M6
  settle-window convergence (enabled only when the live-sync engine is on), two
  admins committing from the same epoch each publish their commit *during* the
  window so the other can collect it and the group deterministically adopts the
  MIP-03 winner instead of forking. The losing admin's commit is therefore
  briefly observable on the relay before it is superseded. This reveals only
  that *a concurrent-admin race occurred* (an extra same-epoch `kind:445` under
  the circle's stable `h` tag) — never the membership target, which lives inside
  the encrypted MLS commit, not the relay-visible tags. It is the same class of
  metadata as the stable-`h`-tag and ephemeral-author-counting residuals above.
  The same applies to the receiver-side path (M6-2): two members auto-committing
  the same peer `SelfRemove` each publish their commit during convergence, and a
  process kill mid-convergence may, on restart, re-publish a fresh same-epoch
  commit (MDK re-stages over the stale pending commit) — another superseded
  same-epoch commit on the relay, never the membership target.

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
  (kind 10050 inbox / kind 10051 KeyPackage-relay list) — e.g. after the user
  edits their relays — its unpublish path emits a NIP-09 kind-5 deletion
  (signed by the identity key) alongside the empty replacement event, so a
  relay that retained the old list learns the change history. This reveals
  nothing beyond what the relay-list events already exposed; the deletion is a
  best-effort tidy-up for cooperative relays
  (`relay::publishers::build_nip09_deletion`, driven from
  `CircleManagerFfi::build_unpublish_relay_list`).

- **KeyPackage residue.** On rotation Haven *does* publish a NIP-09 kind-5
  deletion for the consumed KeyPackage (via `CircleManagerFfi::sign_deletion_event`,
  driven from `key_package_provider.dart`), but only for the single event id it
  re-fetches — the canonical kind-30443. The legacy kind-443 twin is not tracked
  and is never deleted, so old KeyPackages accumulate on relays over time; a
  relay can thus observe the set of a user's past KeyPackages (each exposing
  only an init key already bound to the identity pubkey). This is a known
  lifecycle-hygiene gap (`docs/RELAY_INTERACTION_BACKLOG.md`, Finding A2), not a
  content leak.

- **Client fingerprint.** The relay WebSocket handshake carries `nostr-sdk`'s
  default `User-Agent` (e.g. `nostr-sdk/0.44`). This is **not** unique to
  Haven — every `nostr-sdk` client of that version sends the same value — but
  it narrows the anonymity set from "all WebSocket clients" to "nostr-sdk
  clients of version X". Suppressing it depends on upstream `nostr-sdk`
  support for overriding the header.

## Avatars (Private Profile Pictures)

Per-user avatars are a Haven-specific extension layered on the MIP-03 kind-445
transport. They are **never** published as a Nostr kind-0 profile, uploaded to
Blossom, or sent over HTTP — an avatar is visible only to a user's circle
members and is safe at rest on a seized device.

**Design.** A user's photo is re-encoded on-device to a single canonical
512×512 **JPEG** (a fixed app-wide tier), split into a **fixed number of
equal-size chunks**, each padded so its ciphertext length is constant, and sent
as ordinary kind-445 MLS application messages (inner kind 9) over the same
exporter-secret-derived NIP-44 encryption used for location. Recipients
authenticate the sender via MLS, reassemble, verify a SHA-256 content hash
(constant-time), re-decode under strict resource limits, and store the bytes
**only as SQLCipher-encrypted BLOBs** (keyring-managed key) — never as a
plaintext file. Avatars re-share on change, on epoch/membership change, and
every 24 h (anti-entropy) so late joiners converge.

**What is protected.**
- *Relay invisibility (content + tags):* avatar events share location's exact
  outer profile — only the `["h", nostr_group_id]` tag, a fresh ephemeral
  pubkey per chunk, and a jittered NIP-40 expiration drawn from the **same
  ~minutes window as location** (not a long TTL). No image bytes, MIME,
  dimensions, content hash, or `type` discriminator ever leave the device in
  cleartext, and every avatar chunk has a **constant ciphertext length** with a
  **fixed chunk count**, so the image's size *class* is hidden (all avatars look
  identical on the wire).
- *Honest size/burst residual:* an avatar **share** is NOT byte-indistinguishable
  from a *location* packet — the padded chunks (~4 × tens of KB) are larger than
  a tiny location update, and they arrive as a short burst, so a relay can tell
  *"an avatar share happened"* (the same liveness/timing residual as the stable
  `h` tag and the anti-entropy cadence in §4.3). Closing this would require
  padding **every** location packet up to the avatar bucket — a ~30–50× constant
  bandwidth tax on the highest-frequency channel — which is deliberately not
  done. What stays hidden: the image bytes, its size class, MIME, hash, the
  `type` discriminator, and the sender's identity.
- *EXIF/GPS stripping is structural:* decode → raw pixels → fresh JPEG drops all
  EXIF/GPS/XMP/ICC/thumbnails by construction. Critical for a location app — a
  camera selfie can embed home coordinates.
- *Decode-bomb defense* rests on a pre-decode byte-size cap + a format allowlist
  (JPEG/PNG/WebP only; SVG and all else rejected) **before** the decoder runs —
  not on per-codec feature gating (the `image` crate's codecs are feature-unified
  via mdk-core regardless of what Haven declares).
- *Sender authenticity:* MDK's `verify_rumor_author` binds the inner rumor to
  the sender's MLS leaf credential, so a member cannot publish an avatar that
  displays as another member, and non-members cannot publish at all.
- *At rest:* every DB page (including avatar BLOBs) is AES-encrypted by SQLCipher
  with `cipher_memory_security = ON` and `temp_store = MEMORY` (no plaintext
  spill to an unencrypted temp/WAL/journal sidecar — verified by an at-rest
  byte-scan test). The DB key's *availability* (not its strength) is governed by
  the OS keychain accessibility class: on iOS the three DB keys use
  `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` (readable after the first
  post-boot unlock, never iCloud-synced) so the encrypted DB can be opened during
  a locked-device background wake — see the "iOS keychain accessibility" note in
  *Database Encryption* for the owner-approved seized-device tradeoff. Removed members', left circles', and wiped accounts' avatars
  are purged — and the **per-circle DEC-6 salt is purged with them** (dropped in
  the same transaction on circle-leave and on account-wipe), since that row is
  keyed by the real MLS group id; leaving it would let a forensic attacker who
  decrypts the DB recover the group ids and count of left/wiped circles. A
  single member leaving keeps the circle's salt (other members remain).
  App-switcher snapshots are covered by Android `FLAG_SECURE` /
  iOS blur, and the decoded-image cache is evicted on background.

**Residual risks (honest limits).**
- **Sticky-avatar forward secrecy.** Unlike location (refreshes every ~2 min),
  an avatar set once is not re-encrypted every epoch, so a member who is later
  removed keeps the **last avatar they already saw** from cached ciphertext.
  Anti-entropy re-keys avatars for *future* observers but cannot claw back what
  a removed member captured. Mitigation: changing your avatar forces a fresh
  epoch encryption.
- **Live-memory boundary.** Displaying an avatar requires real pixels in a GPU
  texture; a root-level live-memory dumper on an *unlocked, compromised* device
  can read them. `Zeroizing` and ImageCache eviction shorten exposure but cannot
  scrub an on-screen GPU texture. Guarantee: **safe for a seized/offline/locked
  device; best-effort for a live-compromised one.**
- **At-rest == keyring-key secrecy.** The DB key lives in the OS credential
  store. This is **hardware-assisted only on Apple** (Keychain/Secure Enclave);
  on Linux (D-Bus Secret Service) and Windows (DPAPI) it is software-protected,
  and Android does not guarantee TEE/StrongBox. No new trust assumption beyond
  the existing MLS-state DB. **On iOS**, the keychain item's accessibility is
  `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` (not the default
  `WhenUnlocked`): the key stays in the Secure Enclave-backed keychain and never
  syncs to iCloud or another device, but the OS *will* surrender it while the
  device is locked once the device has been unlocked at least once since boot.
  This is the owner-approved minimum that lets a locked-device background wake
  open the DB for location publishing; a powered-off (never-unlocked-since-boot)
  device keeps the key sealed. See *Database Encryption* for the full rationale.
- **Legacy flash residue.** The migration off the old plaintext `avatar_path`
  best-effort deletes the referenced file, but Rust std has no secure-delete; on
  flash/F2FS/SSD wear-leveling the prior plaintext (and OS thumbnails of it,
  possibly GPS-bearing) may persist in unallocated pages. Disclosed, not
  claimed-fixed. The user's own camera-roll original is never touched by Haven.
- **Cross-circle correlation.** Received-avatar blob keys are per-circle salted
  (`sha256(circle_salt || image)`), so a member of two circles cannot link the
  same avatar across them, and a known image cannot be hash-confirmed.
- **Version rollback after a store wipe.** Post-reinstall the device has no
  stored version, so a replayed *old-but-valid* avatar set can be accepted as
  current (an out-of-date face — low harm). Fully closing it needs persistent
  monotonic state that conflicts with the no-plaintext-cache goal.
- **Android `FLAG_SECURE` side-effect.** It also blocks in-app screenshots and
  screen recording app-wide (intentional for a privacy app; removable in
  `MainActivity.kt`). iOS blur covers only the app-switcher snapshot.

**Owner-tunable knobs** live in `haven-core/src/avatar/config.rs` (resolution
tier, JPEG quality, canonical byte budget, chunk count/payload/wire size,
decode limits, reassembly timeout/DoS caps) and the Flutter anti-entropy
interval / data-saver setting. The avatar event TTL deliberately reuses
location's jittered window — do not lengthen it (a distinct TTL would be a
relay-classifiable avatar fingerprint).

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
