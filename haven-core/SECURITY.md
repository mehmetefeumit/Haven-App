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
| `haven_mdk.db` | MLS group state (via MDK) | `com.haven.app` | `mdk.db.key.default` |
| `circles.db` | Circle metadata, contacts, memberships | `com.haven.app` | `circles.db.key` |

Both databases use 256-bit AES encryption with raw keys generated from `OsRng`.
Existing unencrypted `circles.db` files are automatically migrated to encrypted
storage on first access via SQLCipher's `sqlcipher_export()` function.

**Linux requirement**: A D-Bus Secret Service provider must be running
(GNOME Keyring, KDE Wallet, or KeePassXC). Without one, circle
operations will be disabled with a descriptive error.

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

### Outer kind:445 metadata: jittered NIP-40 expiration

Each kind:445 wrapper for a **location update** carries a NIP-40
`["expiration", ts]` tag with `ts` sampled uniformly from
`[update_interval, 2 × update_interval]` seconds in the future, using
`OsRng` (CSPRNG). See `src/location/ttl.rs`.

The Dart call site in `location_sharing_service.dart` passes
`kLocationPublishMaxInterval.inSeconds` (= 420 s) rather than the
nominal 300 s publish cadence — this lifts the TTL floor to match the
maximum jittered publish delay, producing an on-wire TTL window of
`[420, 840] s`. See the "Publish cadence: jittered scheduler" section
below for the no-gap invariant that motivates this choice.

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
around a 5-minute nominal mean. Each tick is sampled uniformly from
`[3 min, 7 min]` (nominal ± 40%) via `OsRng` — see
`compute_jittered_publish_interval_secs` in `src/location/ttl.rs` and
`PUBLISH_INTERVAL_JITTER_FRACTION_BP = 4_000`. The Dart scheduler
(`haven/lib/src/services/jittered_scheduler.dart`) is a
self-rescheduling one-shot timer that asks the Rust side for a fresh
interval on every rearm.

What this provides:

- Defeats per-event linking by publish rhythm. A relay can no longer
  classify an author as "a Haven client" solely by observing
  equally-spaced 5-minute arrivals.
- Raises the cost of short-window statistical averaging. At σ ≈ 69 s
  on `[180, 420]` s, an attacker needs ~200 samples (~16 h of
  continuous observation) to recover the mean publish rate to within
  ±5 s. A narrower 20% window would have cut that to ~1 h.

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
  (`map_shell.dart`) remains fixed and is tracked as a follow-up.

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

With `PUBLISH_INTERVAL_JITTER_FRACTION_BP = 4_000` the publish gap
`δ` is uniform in `[180, 420] s`, so `δ_max = 420 s`. The Dart call
site passes `update_interval_secs = 420 s` to `encrypt_location`,
which makes the Rust-side TTL `τ` uniform in `[420, 840] s`. Thus
`τ_min = 420 s = δ_max` ✓ — a relay with any queried publisher always
has a valid event.

`RECEIVER_EXPIRATION_GRACE_SECS = 60 s` sits on top of this as
clock-skew defense-in-depth against a replay-near-boundary attack;
it is **not** load-bearing for gap coverage.

Cost of the lifted TTL floor: relay-side residency increases from
`[300, 600] s` (the value before this change) to `[420, 840] s`.
Mean residency rises from 450 s to 630 s (+40%) and max from 600 s
to 840 s (+40%). We accept the residency cost because the dominant
remaining metadata leaks are the stable `h` tag per circle and
ciphertext-length clustering, not TTL duration.

A low-priority residual: a relay that correlates both timestamps
(`created_at`, `expiration`) per event could detect the joint
distribution across consecutive events. Filed as a follow-up.

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
