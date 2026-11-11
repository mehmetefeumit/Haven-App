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
`haven-core/.cargo/audit.toml`, not here. An ignore that stops matching any
advisory fails `audit.yml` (`scripts/ci/check_audit_ignores_live.sh`) and is
deleted rather than left to silence the advisory's return.

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

- **The 2026-10-29 batch**, lockfile-only, with no manifest change, in every
  root that resolved each crate:
  - **RUSTSEC-2026-0365** (`negentropy` 0.5.0 / 0.5.1 → 0.5.2; also yanked).
    This was a remote DoS: a relay's NIP-77 message could declare a huge
    `IdList` count and abort the process on allocation. It was reachable because
    Haven runs NIP-77 on its publish pool.
  - **RUSTSEC-2026-0346 / -0347 / -0348 / -0349** (`rustls` 0.23.45 → 0.23.46),
    **RUSTSEC-2026-0382** (`rustls-webpki` 0.103.15 → 0.103.16) and
    **RUSTSEC-2026-0381** (`webpki-roots` → 1.0.10). These cover a ServerHello
    downgrade, a pre-authentication allocation, and trust in distrusted
    intermediates. They were reachable on every relay and Blossom TLS
    connection.
  - **RUSTSEC-2026-0385** (`ctutils` 0.4.2 → 0.4.4) and **RUSTSEC-2026-0338 to
    -0342** (`quinn-proto` → 0.11.18). `quinn-proto` is in the lockfiles but is
    not compiled, because `reqwest`'s `http3` is off. Moving it in
    `haven/rust_builder` also moved `rand` 0.10.0 → 0.10.1.
  - **RUSTSEC-2026-0387** (`crypto-bigint` 0.5.5) and **RUSTSEC-2026-0330 /
    -0331** (`libcrux-kem` 0.0.9) have no semver-compatible fix. They are
    ignored in `audit.toml`, which carries the reachability argument for each:
    no secret reaches the affected `crypto-bigint` code, and `libcrux-kem` is
    not compiled.
- **RUSTSEC-2026-0073 / -0075 / -0124 / -0207 / -0208 / -0209 / -0211 /
  -0212** (the `libcrux` crypto family) — compiled but unreached under MDK
  v0.9.4, and ignored in `audit.toml` on that ground. The MDK v0.10.4 graph
  resolves fixed versions, so the ignores were deleted with the bump and a
  return of any of them fails `cargo audit`.
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
  which pubkeys a client asks about. Haven asks the curated profile pool
  (`profile::relay_pool`) — never a circle's relays, never the discovery plane —
  ONE author per REQ, each from the one pool relay a salted rendezvous hash
  assigns it and at most one more on a miss, in one-shot REQs with no standing
  subscription and no NIP-42 AUTH answer. No relay sees a roster in one request,
  but each sees an install-specific slice of the union of all circles' members,
  and two members of one circle can land on the same relay (P1, under
  *Profile-plane relay separation* below).
- **Permanence.** A published kind-0 is effectively permanent: replaceable ≠
  erasable — indexers and archives keep revisions, and NIP-09 deletion is
  best-effort. The pubkey ↔ name/photo binding survives "delete".

**Relay planes.** Haven keeps four relay lists apart: the account plane (the
user's Inbox and KeyPackage lists, seeded from `PRODUCTION_DEFAULT_RELAYS`:
kinds 10050, 10002 and 30443, the inbound kind 1059 and the inbox REQ — the
user's pubkey is visible there by design), the read-only discovery plane
(`PRODUCTION_DISCOVERY_RELAYS`: other accounts' relay lists and KeyPackages),
the profile plane (`PRODUCTION_PROFILE_RELAYS`: kind 0) and, since 2026-10-31,
the location plane (`PRODUCTION_LOCATION_RELAYS`: the kind 445 of the circles
Haven creates). The seed and discovery lists share hosts; the profile and
location pools share none with any other built-in list
(`tests/profile_plane_separation.rs`).

### The relay-plane allow matrix

Which frame a relay holding each role may receive from Haven. The table is
`ROWS` in `tooling/e2e/local-relay/src/planes/policy.rs`, the one policy every
proof below judges with (`planes::judge::judge`); the crate test
`the_documented_matrix_is_the_policy` fails when this table and `ROWS` differ,
and `the_exported_matrix_is_current` pins the export
(`tooling/e2e/relay_planes.json`, read by the Dart mirror test only). A frame
no row's shape admits — a stray tag or filter key, a filter spanning two rows,
a REQ whose filters land on two planes, `COUNT`, `AUTH`, a `CLOSE` naming a
subscription its relay was never sent, a `NEG-*` naming a session its
connection never opened — is unknown; one a row
admits on a relay its binding does not is a crossing. A relay holding several
roles admits their union: an account's inbox and key-package lists may share a
relay; an own list with a location or discovery relay, and an invitee's list
with any relay, only when the world or lane being judged declares the pair;
and a profile relay shares with nothing, nor a location relay with discovery.
Any other sharing refuses the judgement.
Memberships are intervals, so a frame is judged against what its relay held
when it was sent; a circle's routing counts from the commit's staging.

| Row | Frame | Kinds | Exactly once / required | May repeat / optional | Limit | Author | Admitted on |
|---|---|---|---|---|---|---|---|
| `EV-445C` | EVENT | 445 | `h` | none | - | ephemeral (no known identity), used once | a relay of the `h` circle's routing kept at the instant (the targets frozen at staging, a routing the change leaves included) |
| `EV-445A` | EVENT | 445 | `h`, `expiration` | none | - | ephemeral (no known identity), used once | a relay of the `h` circle's routing current at the instant, or one it left at or after the event's `created_at`; `0 < expiration - created_at <= 228` |
| `EV-1059` | EVENT | 1059 | `p` | none | - | ephemeral (no known identity) | a relay an inbox list of the `p` recipient named at or before the instant |
| `EV-30443` | EVENT | 30443 | `d`, `mls_protocol_version`, `i`, `mls_ciphersuite`, `mls_extensions`, `mls_proposals`, `app_components` | none | - | an account | the author's own key-package list |
| `EV-10002` | EVENT | 10002 | none | `r` | - | an account | the author's own key-package list; no relay it names holds the location, profile or discovery role without holding one of the author's own lists |
| `EV-10050` | EVENT | 10050 | none | `relay` | - | an account | the author's own inbox list; no relay it names holds the location, profile or discovery role without holding one of the author's own lists |
| `EV-0` | EVENT | 0 | none | none | - | an account | a profile relay |
| `EV-5` | EVENT | 5 | none | `e`, `a`, `k` | - | an account | a relay admitting EVERY kind it retracts (each `k`, each `a` coordinate's kind, each `e` id's kind; at least one `k` or `a`): 0 on a profile relay, 10050 / 10002 on the author's own inbox / key-package list current or former, 30443 on the current key-package list |
| `REQ-445-H` | REQ | 445 | `kinds`, `#h` | `since`, `until`, `limit` | any | - | a relay where every `#h` circle's routing stands |
| `REQ-445-IDS` | REQ | 445 | `ids`, `kinds`, `limit` | `#h` | = ids | - | a relay where the routing of every id's circle (the event index) and of every `#h` circle is kept; `limit` = the number of ids |
| `REQ-1059-P` | REQ | 1059 | `kinds`, `#p` | `since`, `limit` | at most 1000 | - | the inbox list of the one `#p` value, which is the sender when the sender is known |
| `REQ-30443-A` | REQ | 30443 | `kinds`, `authors` | `limit` | at most 64 | - | one author: the sender's own key-package list when it is the sender; otherwise a discovery relay or the author's key-package or NIP-65 write list; `limit` 5 (the status probe) also either own list of an account |
| `REQ-10002-A` | REQ | 10002 | `kinds`, `authors` | `limit` | at most 64 | - | one author: the sender's own key-package list when it is the sender; otherwise a discovery relay or the author's key-package or NIP-65 write list; `limit` 5 (the status probe) also either own list of an account |
| `REQ-10050-A` | REQ | 10050 | `kinds`, `authors` | `limit` | at most 64 | - | one author: the sender's own inbox list when it is the sender; otherwise a discovery relay or the author's inbox list; `limit` 5 (the status probe) also either own list of an account |
| `REQ-0-A` | REQ | 0 | `kinds`, `authors` | `limit` | at most 4 | - | one author, a profile relay |
| `NEG-445-H` | NEG-OPEN | 445 | `kinds`, `#h`, `since`, `until`, `limit` | none | at most 16384 | - | one `#h` circle whose routing stands; opening message `6100000200` |

Three proofs judge with it: **L1a / L1b** on every pull request — L1a,
`every_relay_plane_receives_only_its_own_traffic_across_a_circle_lifecycle`
(`haven-core/tests/relay_plane_wire_e2e.rs`): thirteen in-process relays, one
per role, each behind a recording front (`relay::recording_front`), across a
circle's lifecycle, then a crossing planted on each plane, each reported
exactly; L1b, `ffi_account_and_profile_traffic_stays_on_its_planes`
(`haven/rust_builder/src/api.rs`'s tests): the key-package tick, both
relay-list heals and the profile's sync, read and retraction, judged with the
sender known — the soak rig's **O7** (`RelayPlaneContainment`, over worlds
with account and profile relays) and the E2E lanes' **C8**
(`haven-wire-planes` over the wire journal). As of 2026-11-03 the judge, its
own fixture suite (`tooling/e2e/local-relay/tests/wire_planes.rs`), L1a, L1b
O7 and C8 are in place. C8 runs inside the core-flow lanes' wire-oracle step, on
the poll and live-sync variants alike: each proxy listen declares the roles
its relay holds (7788 the account's inbox and key-package relay, which the
harness's default-relay override also makes discovery's — production's own
seed ∩ discovery overlap, declared; 7789 the location pool's entry), each
circle's routing is declared into the journal by the drive, and every
non-harness client→relay frame below the sentinel is judged. It cannot see
Blossom (HTTP, not a relay frame), a frame on a lane without the recorder —
the multi-relay lanes that run without it read each relay's store instead,
which shows no REQ, no NEG and no expired location (`plane_store_check.dart`)
— or which of two roles sharing one listen a frame was for. O7 grades every frame
every device of a soak world sent, after every arm and after the long faulted
nemesis phase, against the ground truth the rig decided (each circle's routing
from the instant it staged it, each device's own lists, the profile pool); its
own controls plant a kind 0 on a location relay, an inbox REQ on a location
relay, a location on a relay its circle never named and a `CLOSE` naming a
subscription its relay was never sent (`tooling/soak/tests/oracles.rs`), and S26 drives the
profile and key-package planes under a downed profile relay. It does not grade
the exact left-routing rule (a member that has not applied a relay change
still seals for the routing it holds, and only L1a judges with one sender) or
the discovery plane, which a soak process points at a port that refuses every
dial. L1a also
holds that no client dials a relay outside its world: in a build with
`test-utils` the admission policy every relay client carries (Rule 16's
`VerifiedEvents`) notes each relay URL before the pool's connection attempt
(`relay::dial_witness`) and admits it exactly as the trait's default does —
the same policy, not a second one, and compiled out of every shipped build.
On its first run L1a found, and the fix closed, the live plane sending a
circle's `CLOSE` to every relay of its pool when it dropped that circle's REQ
— the inbox relay and every other circle's relays learned a subscription id
that joined their planes; it now goes only to the relays that hold the
subscription.
Its last phase pins what the product does today with an invitee's relay
lists that name other planes (the Welcome goes to the first relay of the
inbox list that acknowledges it, and the key-package lookup to every relay
of the NIP-65 write set): the finding set it expects becomes empty when a
rule drops such entries. Residuals: L1a and C8 judge with no
sender, so a request on another identity's own list (an inbox REQ by `#p` of
an account other than the device's) passes there — the per-identity bindings
are proved by L1b and by O7 on a device's own and alias endpoints (O7 judges a
frame on a plane's canonical endpoint — catch-up sweeps, the rig's inbox reads,
an invite's key-package lookup — with no sender too), and C8 proves role
placement on the hermetic lanes, not those bindings.

### The location relay pool

A circle created without named relays — every create the app's UI makes — gets
`min(3, n)` distinct relays drawn with `OsRng` from `PRODUCTION_LOCATION_RELAYS`
(eight entries, `circle::location_pool`; a debug build may install a test list
with `set_location_relays_for_test`, which release builds compile out). Each
entry is normalised, de-duplicated by authority (host and port) and kept only
if `foreign_relay_dialable` admits it and the hard tier below leaves it in; `n`
is how many are left. Two exclusion tiers decide which:

- **Hard — the creator's own identity relays.** No relay whose authority
  appears in the user's Inbox, KeyPackage or Profile lists, the curated profile
  pool, the retired profile relays, the discovery plane, or a contamination-ledger
  row recorded as an inbox, key-package or discovery relay
  (`CircleStorage::identity_relay_authorities`) is ever picked, however it is
  spelled. A Welcome row is not in the tier: that relay took an ephemeral-key
  gift wrap `p`-tagged to an invitee and never saw this account's pubkey. When nothing is left the create is
  refused with the typed `CircleError::NoLocationRelay`
  (`RefusalFfi::NoLocationRelay`, fixed copy telling the user their own lists
  cover every relay Haven uses for circles) before anything is persisted. There
  is no fallback to the full pool, the inbox or the seed.
- **Soft — the invitees' relays.** An entry an invitee lists as an inbox relay
  or a NIP-65 read or write relay is taken only to fill up to `min(3, n)` when
  too few others are left, so a crafted invitee list can neither steer the
  circle onto one relay — the creator's identity relay included — nor block the
  create.

On default settings a location relay therefore receives the circle's kind-445
events, its `#h` REQs, catch-up fetches and NIP-77 passes, and never the inbox
REQ (`#p` = the user's pubkey), a gift wrap, a relay list, a KeyPackage or a
kind 0 of this account. The picked set is the circle's routing component and is
recorded in the contamination ledger as `CircleRouting`, so it never enters the
profile pool. The pick logs nothing. Tests: `tests/location_pool_e2e.rs`,
`tests/location_pool_override.rs` and the unit tests in
`circle/location_pool.rs`; `check_profile_privacy_boundaries.sh` checks 9b
(CSPRNG only), 11 (the named tests exist), 12b (no library test installs the
override) and 14b (every entry has a dated vetting row).

**What remains.**

- One device IP across all four planes, and an iOS background burst that opens
  and closes the whole relay union in the same seconds (P6, RC1).
- Welcome delivery and the KeyPackage fetch still go to the invitee's own
  10050/10002 relays, and an invitee added later whose lists name one of the
  circle's relays causes no re-pick.
- Circles created before 2026-10-31 and circles other clients create keep their
  relays: a change is a commit every member must receive.
- A relay the user removed from their inbox is excluded only best-effort,
  because the ledger keeps a relay's first source only (P7).
- Smaller operators make "all three relays dark" likelier; only an admin's
  relay change rescues such a circle, and `circleRecovery` names the condition
  only while a change awaits a relay's acknowledgement (`AwaitingRelays`).
- A user who puts every pool relay on their own lists cannot create a circle
  until they remove one; the typed refusal says so.

#### The location pool is Haven-specific (LOCATION-POOL)

`PRODUCTION_LOCATION_RELAYS` is a list only Haven uses, and every member of a
circle Haven creates dials the same three of its relays. A network observer who
sees DNS queries or TLS SNI (an ISP, a Wi-Fi operator) can therefore infer from
those hostnames that a device runs Haven and that devices dialling the same
three are probably in one circle, where a default circle used to ride the
account seed (`relay.damus.io`, `relay.primal.net`, `nos.lol`) that most Nostr
clients dial. The pool's operators, together, can enumerate Haven users' IP
addresses, because the pool is Haven-specific. Accepted with the relay-plane
segregation (owner-approved 2026-10-31); there is no mitigation beyond the
recorded absence of network-level unlinkability (P6), and copy must not present
Haven's choice of circle relays as hiding Haven use from the network.

### Relay events are verified by Haven before anything acts on them

A relay is untrusted. It can withhold an event, delay it, reorder it and
replay it. Group traffic is built to tolerate all four (Security Rule 12); a
replaceable or addressable event (kind 0, 10002, 10050, 30443) is only as
fresh as the newest copy the relays that were asked chose to serve, so a relay
asked alone, or the only one to answer in time, can still pass an older
genuine version as current. What a relay must not be able to do is make Haven
act on an event its author did not sign.

**The gap this closes.** `nostr-relay-pool` 0.44.3, which owns every relay
socket, verifies an event's id and signature — unless it has already verified
an event with the same *claimed* id, in which case it hands the new one on
unchecked (`SharedState::verify_and_cache`). The cache is one per client and
shared by all of that client's relays. So a relay that holds no key could show
the client any validly signed event under a subscription nobody opened — an
event it signed itself is enough — and then answer a real request with any
author, kind, content, tags and timestamp under that id; or replay an event an
honest relay had delivered, under another signature. Nothing in Haven checked
either. One such relay could get fields of its choosing signed into the user's
own profile, name and picture any circle member, choose where an invitation
was sent, make Haven sign a deletion of the user's own events, and make a
device lose a group commit for good.

**What Haven verifies.** Every `EVENT` frame the pool would otherwise hand on,
from every relay, on both relay clients (the publish/fetch client behind
`RelayManager` and the live-sync engine client): that the id is the hash of the
event's fields, and that the signature is its author's over that id
(`Event::verify()`). Never the signature alone — a signature covers only the
claimed id, so it still holds over fields swapped under a genuine id. The id is
recomputed from the parsed fields, so a genuine event a relay spells with its
keys in another order, an extra field or other escapes verifies as itself.

**Where, and why there.** In the relay pool's admission hook (`VerifiedEvents`,
`haven-core/src/relay/verified.rs`). The pool calls it for each frame that
passed the pool's own checks — its size and tag limits, NIP-40 expiry, and the
verification it does run on an id it has not seen — and before its database,
before its id-keyed stream de-duplication and before any notification. The
placement is the point. The pool, Haven's per-relay read, the catch-up pager,
the engine and the refused-object ledger each remember an event by its id; a
forgery that reached any of them would be remembered as *the* event with that
id, and the genuine copy — from the same relay a moment later, or from an
honest one — would be discarded as a repeat. A check made on what the pool
hands back would refuse the forgery and have nothing left. Checked in the hook,
a claimed id is the true id everywhere downstream, and every existing id-keyed
memory becomes sound without changing.

One constructor, `verified_client`, builds every relay client in shipped code.
It installs that policy and nothing that could undo it: the client is given no
gossip store, because the SDK hands each event to one before it asks the
policy. `scripts/ci/check_engine_client_options.sh` (check 11) fails if that
file's product code — above its test module or below it — holds a second
construction, names the policy twice or names a gossip store at all, and if
any other source file under `haven-core/src`, `haven/rust_builder/src` or
`tooling/soak/src` names a `Client` or `RelayPool` construction, other than the
marked test witnesses in the files and test modules it lists for them. It is a
text scan: integration tests under `tests/` are not read, and a construction
it cannot spell — a `Default` the compiler infers, a macro handed the type as
an identifier, a constructor a trait provides — is not seen. A client type
with no `Default` that only `verified_client` can build would close that
structurally and is not done; what catches a call site that stops using the
constructor today is the forged-event tests below.

One relay client is not Haven's own code: MDK's `NostrSdkRelayClient`
(`transport-nostr-adapter`, feature `sdk`), which the durable fanout publishes
through. It builds no client. Its only constructor outside its own tests takes
one (`sdk_client.rs:258` at the pinned rev), no other MDK crate Haven links
depends on nostr-sdk, and outside its tests that file names no gossip store and
no admission policy. `RelayManager::fanout_transport` hands it the publish
client, so it sends on the sockets that pool already holds and whatever a relay
sends back on them passes the same policy. It verifies nothing itself: handed
any other client it would be exactly as trustworthy as that client. Check 11
therefore also holds the hand-over — the type named in `relay/manager.rs`
alone, constructed there once, over `self.client`, which every
`Self { client … }` in that file spells as `verified_client(…)` — and
`the_fanout_transport_rides_the_publish_clients_own_socket` fails if MDK's
client opens a socket of its own. Haven calls its `publish_event` and nothing
else. Its other half — a subscribe that connects every relay in the pool, a
forwarder of what the pool notifies, a NIP-77 reconciler that reads the pool's
database — is unused and kept unused by
`scripts/ci/check_publish_client_no_subscription.sh`, which also bans
`subscribe(` / `subscribe_with_id(` on anything but one relay's handle in
`relay/manager.rs`: the publish client's relays carry the READ flag for Haven's
targeted fetches, so each would be sent a pool-wide subscription's filter. That
guard reads those spellings only; the other pool-wide calls a client offers
(`fetch_events(`, `stream_events(`, `sync(`, an untargeted `send_event(`) are
not scanned, and `manager.rs` using only the targeted forms is held by review
and by the tests that count what each relay is sent. That MDK's client builds
no client, installs no gossip store, admission policy or signer is a fact
about MDK's source, not something MDK enforces; a test re-reads that source on
every run (`mdks_relay_client_builds_no_client_and_installs_nothing_on_the_one_it_is_handed`).

**NIP-77 carries no event, and what it leads to is verified.** Haven's own
reconciliation pass (`haven-core/src/relay/negentropy.rs`, through
`RelayManager::neg_remote_ids`) runs on the publish client as a dry run
in the download direction over an empty local set: NEG-OPEN, NEG-MSG and
NEG-CLOSE frames carry ids and nothing else, and no event crosses them. The ids
it learns are fetched by a by-id REQ on the same client, so every event the pass
leads to passes `VerifiedEvents` before the pool stores, de-duplicates or
notifies it (`a_forged_copy_served_to_a_reconciliation_fetch_never_reaches_the_engine`).
One judgement in the pass rests on this rule and on nothing else: an id the
screen refuses before authentication (a kind 445 with a duplicated `h`) is
judged final for the route it was fetched for and not asked for again while
`NegMemo` remembers it (`docs/MDK_UPSTREAM_TRACKER.md` T-NIP77-DRIVER). That is sound only because
`verify()` binds the id to the bytes. A pool that handed on unverified bytes
under a genuine id would let a relay make a genuine commit look refused for
that route, and the window would complete without it. Check 5 of
`check_publish_client_no_subscription.sh` holds the one NEG shape: one
`sync_targeted` call, in `neg_remote_ids`, a dry run, download only, with no
local items. MDK's reconciler stays unused.

The publish client holds no key and never authenticates — two facts, either of
which is enough, and both of which can be changed on a client after it is
built (`Client::set_signer`; `Client::automatic_authentication(&self, enable)`,
`nostr-sdk-0.44.1/src/client/mod.rs:116`). So check 11 holds both in the three
source trees: the words `set_signer` / `unset_signer` and a `.signer(` or
`::signer(` call appear nowhere, and every `automatic_authentication(` is
`automatic_authentication(false)`. With a signer the pool would answer a
relay's NIP-42 challenge with the identity key, on a socket that carries a
circle's routing id, and MDK's relay client would sign an unsigned non-445
event it was handed (an unsigned 445 it refuses, `sdk_client.rs:660-666`). The
scan is of text and does not read `tests/`, where the NIP-42 control client
holds a signer on purpose.
`the_publish_client_holds_no_signer_and_never_authenticates` pins both, and
`the_publish_client_never_answers_a_nip42_challenge` shows the effect against a
relay that demands authentication to write. The fanout transport therefore
treats `auth-required:` as a refusal that cannot change, not as an outage.

### What a relay's refusal has to prove before the fanout may act on it

Security Rule 13 lets a commit be rolled back only when every relay proved it
did not accept it. The proof is made in one place,
`haven-core/src/relay/fanout.rs`. MDK's relay client sends an event up to
three times inside one call and reports its LAST attempt; an earlier attempt
that timed out, or that another publish path's socket repair cut short, may
have been stored while a later one is refused. So a relay-spoken failure —
`TerminalRejected`, or `RetryableUnavailable` with a category — is returned
only when the relay's own `OK` frames for that event id, read from the relay's
notification stream across the call, show an `OK false` for every attempt and
no `OK true`, on a stream that neither dropped a frame nor closed. Anything
less is `PossiblyExposed`, which is never rolled back. An `OK` names an event,
not an attempt, so the count is of that relay's answers for that event inside
the call. It proves every attempt of the call was refused only while no other
frame for that event is outstanding on that relay of the publish client — not
one in flight from another sender, and not one an earlier send left queued: an
attempt made while the socket is down still queues its `EVENT`, the next
connection writes it, and a prompt relay then answers it inside a later call.
So nothing but the fanout driver may ever send a fanout row's event on the
publish client, the driver records every call's outcome on the stored fanout
before the next call for that relay, and a call that never returned is
recorded `PossiblyExposed` first — which a stored fanout does not forget. An
`OK true` for the event heard at any point is the acknowledgement, whatever
MDK's last attempt was told, and so is an `OK false` with the `duplicate:`
prefix. What Haven itself refuses before anything is handed over — a relay
its policy will not dial, bytes that are not a verifiable signed event — is
`NotExposed`. The proof concerns honest relays: one that answers `blocked:`
and stores the event anyway is the residual T-ROLLBACK-RESURRECT records.

### The fanout driver: staged in the engine's hold, resolved on proof

Since W9q this driver is the only way a commit or a proposal leaves the
device. Nothing else confirms or rolls one back: `CircleManager`'s
`confirm_published`, `publish_failed` and `finalize_relay_update`, the
receive ladder, the removal-deferral table and its redemption are gone, the
bridge carries no pending ref, the relay layer refuses an event that has a
record, and the bridge's plain `publish_event` refuses every kind 445 and
every kind 1059
(`security_rule_gates::a_fanout_is_the_only_way_a_commit_leaves_the_device`;
`the_plain_publish_refuses_a_gift_wrap`).
`CLAUDE.md` Security Rule 13 states its six invariants; this section carries
the rest.

One `kind:445` can leave with no record at all, and it is neither a commit
nor a proposal: with the Bluetooth mesh on, a fellow member's location this
device took in by mesh is passed on to the circle's relays (member bridging,
owner decision D-7, `docs/BLUETOOTH_MESH_PLAN.md` §5.5;
`Publishing::publish_location_and_bridge`, which no entry of the bridge calls
before the mesh's own FFI lands). It is that member's own sealed event, byte
for byte; the mesh's ingress admits application messages alone, so no commit
travels this way. It is sent only behind this device's own location send of
the same circle, in the same call, and only to the relays that took that
send; only in a drive whose relay receive completed before it, which is
what the drive's caller states and the core re-checks only as "caught up,
nothing fetched and unread" — a device that publishes before it fetches
passes nothing on; only an update the
engine read for the first time, from packets that all mark it as one a
member may pass on (never a mesh-only seal); and only while a location this
device sealed at the same epoch could itself be sent
(`SessionManager::location_may_be_sent`), so a member removed since is not
handed it. One attempt a relay, never retried, its answer read by nothing;
an event is passed on at most once, at most one a member each 72 seconds, at
most four a send, no later than 218 seconds after it was sealed, and never
when it declares a longer life than 228 seconds or is stamped ahead of this
device's clock. What one send does not pass on is dropped
(`tests/mesh_bridge_e2e.rs`;
`security_rule_gates::the_bridge_sends_once_and_reads_no_answer`). What a
relay can infer from it is in the plan, §0.4 item 11a.

`haven-core/src/relay/fanout.rs` `drive_one` is the one place a commit that
has a durable fanout row is confirmed or rolled back, and `drive_due` runs it
for every stored row. Each send-side change has one entry that stages, drives
and answers with a typed outcome: applied, awaiting relays, undone, queued,
set aside by the engine, or staged with no record
(`relay::fanout::Publishing`, `EvolutionStatus`). A change no relay has
answered for is awaiting relays, never failed, and only "undone" says every
relay refused it and the circle is as it was. `Publishing::resume` drives everything stored. The
catch-up plane has a sweep that stages what it surfaces and drives it
(`relay::catchup::run_catchup_in_foreground`): the eviction of a member who
left, a change the user had queued, and a leave proposed again each get their
record in the lock hold that released them, and the sweep first drives every
stored record that has something due.

The app reaches a drive through **the live plane, while its session's
lifecycle is `Foreground`** (`relay::live_sync::drive::Lifecycle`,
`EngineProcessor::drive_due`) — a lifecycle a session enters only on its
caller's claim, which the Dart layer makes from one strict read (below) —
and through the bridge's `*_driven` entries on `RelayManagerFfi`: since W9n
the send-side changes (add, remove, relay update, a leaving admin's two steps,
the repair) and the re-invite (from foreground maintenance only, at each
health tick: MDK paces the lookups and each record its own sends, so the
drive's named wait does not hold the lookups back); since W9o-1 the ingest
of a polled event
(both polls; an event the engine holds is fetched again and the circle's poll
floor does not pass it) and the drive of stored records for a process the
live plane does not drive (the flag-off configuration, at the foreground
health tick; the Android service's isolate, at each cycle, claiming `false`;
neither sooner than the drive's own wait); since W9o-1b the leave, at the
press and at every wake, and every plane's location seal and its one send.
In the flag-off configuration, then, a record that comes due in front of the
user waits for the next health tick, up to about fifteen minutes, and the
circle roster is read again after that drive. The map shows a member's
location only while the circle's roster, as last read, lists them: a removal
the driver makes after it answered "awaiting relays" is learnt from the
roster alone, and a member just added shows their first fix once the roster
has been read again (the next resume, a group update, or that health tick).
The Android service's two
driven calls make no new commit: with a departed member's removal owed,
its ingest and its drive leave the removal due — no relay called, nothing
staged or recorded — and the circle's driven seal answers held for the
departure (`SendHeld::DepartureDue`), so nothing is sealed at an epoch that
member reads; the removal waits for a foreground, whose first full drive
makes it
(`the_fgs_cycles_finish_only_calls_leave_an_owed_removal_to_a_foreground_and_hold_sends`).
The service's location goes through the driver's seal with that same
`foreground: false`, so the removal and that circle's background sharing
wait for the next foreground: the seal answers held, nothing is sent for
the circle, and the cycle raises no failure and pulls no retry forward.
Every app plane — the foreground scheduler, an iOS burst, the one-shot
publish and that service — seals and sends a location through the driver's
entries (`seal_location_driven`, `publish_location_driven`); WorkManager
seals nothing. Every publish path keeps one clock rule
(`clock_skew::classify_publish_outcome`): a send is a clock refusal only when
no relay took it and a relay's `invalid:`, `blocked:` (khatru's timestamp
policies answer under it) or unprefixed refusal blamed its timestamp — a
timestamp mentioned under `pow:`, `rate-limited:` or any other prefix is
not one; a retry stops on the same reading, whatever the event's age — it
would carry the same timestamp
(`an_old_event_every_relay_refused_on_timestamp_grounds_is_not_retried`);
and a refusal of an event signed more than the alert threshold (120 s) ago
by this device's clock is read as being about this clock only where it says
the event is from the future — a recorded commit sent again hours after it
was signed is refused as too old for its age (khatru's past window is its
operator's; its own example sets two hours), not for a slow clock
(`a_refusal_of_an_old_resend_as_too_old_blames_no_clock`,
`an_old_event_refused_as_too_old_is_no_clock_rejection`; a relay whose
operator set its past window under 120 s can still refuse a fresh event as
too old and raise a false `Behind`) — and relays that disagree on the direction give
the unspecified direction. The location's one send answers it typed, one
variant a direction (`LocationPublishFfi::ClockAhead`, `ClockBehind`,
`ClockUnspecified`), which the app hands to its clock check by variant; a
driven seal, leave, change, ingest or resume carries the same verdict for
the commits its drives sent (`clock_rejected`), read by Haven's own listener
from each relay's answer and judged on the commit's whole stored record — a
commit some relay holds is no clock refusal — the words discarded, and the
app hands it to the same clock check. A
leave asked inside the wait a refused eviction earned waits that wait out,
its intent standing and its sends held, and goes on once it ends — not asked
of the engine meanwhile, where each step would have queued behind the
eviction once per call
(`a_leave_inside_a_refusal_wait_is_neither_lost_nor_made_twice_and_goes_on_after_it`);
an engine that cannot be had, or cannot say whether the eviction is still
scheduled, is waited out too, and the leave is told to come back when that
circle's own wait ends
(`a_leave_inside_a_refusal_wait_waits_it_out_while_the_engine_cannot_be_had`).
A proposal the engine refuses because this device is an admin again — its
own preflight settles what the circle received before it checks, so a
promotion can land inside the call — is planned again with the intent kept:
in a full drive the device steps down and proposes once, and the driver
never answers "must step down"; a wake's carry-on, which makes no commit,
answers `ForegroundOnly` or `Pending` instead until a foreground drive does
(`a_promotion_taken_in_between_the_plan_and_the_proposal_is_stepped_down_from`).
A hand-over or a step-down a stale plan asks for once the circle already
has those admins — two presses of Leave, the second planned before the
first's hand-over landed — is answered as made with nothing staged, read in
the hold that would stage it: MDK stages a policy naming the admins a
circle already has (the epoch-rotation repair relies on that), which would
be a commit for nothing on the wire
(`a_hand_over_planned_before_another_landed_is_not_made_again`).
The app shows a
change's answer by its variant alone: an acknowledged, applied change as
made; anything else that is not awaiting relays or queued as not made.
Awaiting relays, or queued, is never shown as an error: it shows through the
circle's deferred-send cause, the epoch repair's included, and a leave's
sheet dismissed while the call ran still records it. A background isolate's
word is always `false`. Each answers with
a typed outcome — every refusal the app routes on is a typed field, never a
string — and drives in a `Claimed` mode
(`relay::fanout::Claimed`): the full one only while its caller says the app
is in front of its user AND, where a live plane shares the session, that
plane's own lifecycle — set by its claim, in Rust — is the foreground; the
word can narrow that, never widen it, so a stale `true` from a caller gone to
the background commits nothing beside a plane only started, in a burst or a
pause (`a_bridge_calls_word_widens_nothing_beside_a_live_plane`). Read again
at each decision, so it can only narrow. In a process with no live plane the
word is all there is — Android's background service passes `false`, which
nothing in Rust can check — and it is also the claim the away-holds read,
for as long as the call lasts. So a wrong `true` there costs more than a
commit made from the background: for that call it lifts the hold of a relay
change applied away (`AwaitsForeground`), and a location may be sealed for a
circle at relays this device does not yet listen on (the hold of a removal
left unmade is not lifted by any word, decision 238). The guard is in Dart:
the word is `appIsResumed()` in the UI isolate and a constant `false` over
an injected manager, pinned by
`haven/test/lints/foreground_claim_strict_read_test.dart`. A sealed location crosses to the app as an
opaque handle only the send reads: its event, its circle's id and its relays
stay in Rust. One test accessor (`sealed_location_event_json_for_test`)
returns the signed event — the very bytes every relay of the send is handed
— to an integration test, and only in a build with debug assertions; in a
release it answers nothing, and no app Dart names it
(`a_sealed_locations_test_accessor_is_debug_only_and_unused_by_the_app`). Since W9q every plane
is on those entries, and no commit leaves the device any other way. A hold
that records nothing — a plain ingest, the legacy leave — makes no commit of
the engine's own, and hands back sixteen events, not 256, while the live
plane sharing the session is in a burst, paused, or only started. `FinishOnly` sends the frozen bytes
of a pending commit a relay MAY ALREADY HOLD — one acknowledged it, an
attempt may have exposed it, or one was begun and never returned
(`a_relay_may_hold`) — to each relay that was attempted before and is due,
stores each answer, and BEGINS nothing and undoes no record: no rollback of
a record, no bound, no record for a new commit, no full advance, no queued
change, no Welcome, no publish of anything that has no record, and no first
transmission — a record no relay was ever sent, or whose every attempt found
its relay unreachable, is not taken up, and within one that is, a relay
never attempted is not attempted (`never_attempted`): a first transmission the operating system cut
would leave a commit nobody held stored as possibly exposed for good, and so
never undone
(`a_finish_only_call_makes_no_first_transmission_to_any_relay`). What that
costs is a hold, and it is this one: a commit recorded in the foreground and
never sent — or sent only to relays that could not be reached — stays
pending for as long as the app stays away. Its circle is then SILENT, each
send answered as awaiting relays (`SendHeld::AwaitingRelays`), and DEAF:
while a commit of this device's is pending the engine opens nothing the
circle sends and parks every event of it unread, with no cap — another
admin's removal among them — until the app is next opened and a full drive
sends the commit. Accepted as the careful side of the trade (an owner
decision is recorded for it): the other side is a first transmission the
operating system can cut mid-flight. Five things
it does do besides sending. It confirms a pending
commit whose STORED record holds a relay's acknowledgement — one this call
has just stored, or one an earlier call stored, with no relay called again —
when the wake has a whole fold's budget left (`FOLD_BUDGET_MS`) and the
commit does not change its circle's relays. A confirm it has no budget for is
left where it is, the call asks to be driven again, and a send meanwhile is
told what holds it (`SendHeld::Acknowledged`: a relay has acknowledged the
commit, and its confirm is awaited). A change of relays is left to a full
drive however its record stands: applied away from a claimed foreground it
would hold its circle's sends until one (`ChangeNote::AwaitsForeground`,
below), and the full drive applies it without that hold; a record whose
intent cannot be read is taken for one. What is left of a record it
confirmed — the relays still owed, its Welcomes, its end — is a full drive's.
It finishes a confirm whose transaction an earlier call
landed and whose engine half then failed, through the engine's own confirm —
its replay of what was parked and an inputs-only fold of what that hands
back; nothing is decided by it, the commit being already applied and on
record. Where that commit changed the circle's relays it is finished only
once the circle is durably marked as waiting for the foreground
(`ChangeNote::AwaitsForeground`). That mark holds the circle's sends for
every call that is not a claimed foreground's — a burst's, a paused
session's, and one in a session that has only been started, which a
background wake that cold-launched the process also is — answered deferred
and typed (`SendHeld::AwaitsForeground`): finished, the device seals at the
new epoch for the new relays while its subscriptions are still on the set
the app last gave it, so it would miss a later removal and seal for whoever
was removed. The mark ends at the END of a full drive that was still a
claimed foreground's when it ended, that did not end on an error of the
circle's own record — one circle's error holds no other circle's mark — and
was not cut short by its wake — asked again for each circle with the engine
held, so a pause that lands while the drive waits for the engine ends nothing
(`a_change_of_relays_already_applied_is_finished_and_the_circles_row_follows`,
`only_a_drive_that_is_still_a_claimed_foregrounds_ends_a_circles_wait_for_one`,
`a_rows_error_stops_its_own_circle_and_no_other`). That drive is all it waits
for. A circle's subscription follows its routing by itself: whichever
plane moves a circle's row to new relays — the live receive, the live
drive's confirm of this device's own change, a bridge `*_driven` entry,
catch-up — wakes the live session's follow
(`CircleManager::routing_moved`), which moves the circle's REQ onto its
relays now and those of a prior routing (`LiveSyncCore::follow_routing`;
`app-components/nostr-routing-v1.md` 44-63), in a claimed foreground
and in a burst, and once more as a burst opens — while the session is
paused, only its model moves, and the next open issues the REQ
(`the_committer_of_a_relay_change_listens_where_the_circle_now_lives`,
`the_receiver_of_a_peers_relay_change_listens_where_the_circle_now_lives`,
`an_own_relay_change_the_live_drive_confirms_is_followed_with_no_health_tick`,
`an_own_relay_change_a_bridge_entry_confirms_is_followed_with_no_health_tick`).
Nothing in the app calls it; the FFI entry is gone. A routing id another
client's admin rotates is followed the same way (OWNER_ITEMS 196): the row,
its last-known locations, its delivery health and its owed removal move to
the new id, and the routing it leaves is kept as a prior routing, in ONE
transaction (`CircleStorage::follow_routing`), before the plane that applied
the commit collects what the engine staged on the way. Rows already under
the new id — a rotation back to an id the circle used, a write made with
the id it had then — are merged, not refused: a peer's location under the
id being left wins, each health instant keeps the later, an owed removal
keeps the earlier deferral
(`a_rotation_back_to_an_id_with_rows_under_it_merges_them`). A circle that is
deleted takes with it the last-known locations and delivery-health rows under
every routing id it has named — under an id another circle has named too,
nothing tells whose a row is — and the sync state of each id no other circle
still names
(`leaving_a_circle_drops_the_rows_under_an_id_another_circle_shares`). The new id's
sync state starts over, its cursor at the earlier of the prior id's cursor
and the oldest relay `created_at` the engine keeps of the circle's retained
epochs — the rotating commit's among them however late it was applied — or
unset, the stream's cold start, when the engine keeps nothing readable
(`a_rotation_applied_days_after_it_was_made_asks_the_new_id_from_the_rotation`).
A follow that does not happen — a kill between the commit and the persist,
an error reading the engine's routing, its epoch or the store — is never
answered as done: it is made at the next start, catch-up sweep or paused
burst open, which each reconcile every circle's row with its engine routing
(`CircleManager::reconcile_routing`;
`a_rotation_whose_follow_a_kill_missed_is_followed_by_the_next_sweep_after_a_reopen`,
`a_prior_routing_not_kept_or_read_is_said_without_an_identifier`,
`a_store_that_cannot_say_whether_an_id_is_taken_follows_nothing_and_holds_the_circle`).
The prior id stays a prior routing like a prior relay set — listened at, at
the relays it was used with, for the same day; swept by catch-up for that
day; asked for in a history range, at its own relays and by a filter of its
own, at least while an epoch that used it can be fetched (its row is pruned
only at the circle's next routing change); and routing what still
arrives under it, or what a caller writes with it, to the circle under the
id its row now names. A start lists each circle's standing prior ids, the
app taking one out of what it lists wakes the follow that lists it again,
and a circle left has every id it held unlisted by the follow its leave
wakes (`a_start_lists_a_rotated_circles_prior_id_and_a_leave_lists_none_of_its_ids`).
A circle is caught up only once every routing id it is listened at has
ended its stored events — a commit sealed under the prior id by a member
that had not yet taken the rotation in is a branch like any other — and is
read again when one of its ids is unlisted
(`a_circle_waiting_on_a_prior_id_is_caught_up_when_that_id_is_unlisted`).
A rotation onto a routing id another circle on the device holds — as its
routing id, or as a prior routing while an epoch that used it is still
retained (past that window nothing sent under the id can be peeled any
more, its epochs' exporter secrets being gone — though MDK's in-memory
index keeps the route until the session ends, mdk#896 — and the id is
nobody's: `a_prior_routing_id_past_its_epochs_is_nobodys`) — is not
followed, and both circles are held (decision 250, OWNER_ITEMS 200). A
Welcome naming such an id is joined, and its circle's row is written beside
the other's under the same id — the user needs it listed to leave it — and
both circles are held. MDK gives that id's route to the rotated or joined
group, in memory and in its stored routes, so the other circle applies none
of its commits from then on — a removal among them — and would go on
sealing at an epoch a removed member still reads. Both notes are written in
one transaction (`a_note_for_two_circles_lands_on_both_or_neither`). A store
that cannot say whether another circle holds the id holds the moving or
joining circle at once: MDK has moved the route already, and that store
cannot name the circle it may have taken it from. That circle is held only
from the next routing reconcile (each start, sweep and burst open) that
reads the store, which holds both circles of every pair whose rows name
one routing id, or where a prior routing still inside its window names a
circle's current id — a repair after the fact, not a prevention: until it
runs, the circle that lost its route is not held. A prior routing whose
circle's epoch cannot be read holds nothing there; it is asked again at the
next reconcile, since the hold it would set ends only with a leave
(`a_reconcile_that_cannot_read_a_holders_epoch_holds_nothing`). The cost is the moving or
joining circle's sharing until it is left, for a store error at that
instant
(`a_store_that_cannot_say_whether_an_id_is_taken_follows_nothing_and_holds_the_circle`,
`a_welcome_whose_routing_id_the_store_cannot_check_is_joined_and_held`,
`a_welcome_joined_under_a_store_error_holds_the_other_circle_at_the_next_reconcile`).
Neither held circle seals by any call, a claimed foreground's included
(`SendHeld::RoutingCollision`, `ChangeNote::RoutingCollision`,
a level the user cannot acknowledge away; a note store that cannot be read
reads as held). No commit of this device's is made for either but what its
leave needs. A change asked for is refused — an invite, a removal, a change
of its admins or its relays, the rotation repair
(`CircleError::RoutingCollision`) — and none the engine would make is
made: an owed re-invite and a re-issued withdrawn change wait, owed, and an
eviction left due or another deadline's commit is staged by no advance —
the driver's or a receive plane's — and wakes no
receive pass; each would be made at an epoch the engine may not be at. The
eviction is left to the circle's other members — and where this device is
the only other member able to commit it, nobody makes it, which costs
nothing while nothing is sealed (`protocol-core/member-departure.md` 67, a
SHOULD). A withdrawn change left owed in a held circle also holds back
MDK's state-derived clean-up of re-issue records (`own_commit_intent.rs`),
for every circle, until that circle is left: local intent metadata only,
no secret and no traffic
(`a_reinvite_into_a_collided_circle_is_not_made_and_stays_owed`,
`a_withdrawn_change_in_a_collided_circle_is_not_made_and_stays_owed_past_the_leave`,
`a_due_eviction_in_a_collided_circle_is_not_made_and_the_leave_still_ends`).
The leave is made: its proposal of every epoch a recording plane (the
leave call, the foreground live plane, the sweep that drives) is handed,
recorded for and sent to that circle's own relays alone — the circle being
the one MDK's own record of the proposal names, never the shared routing
id and never the call that handed the proposal back, which can be another
circle's leave; one a background plane is handed reaches no relay, and the
leave waits for the next epoch or its bound; the admin hand-over and
step-down it takes first; and — the one commit the engine's own leave call
stages before it proposes — an eviction already due. It answers proposed
only when a record of the proposal the engine minted at its latest
proposing epoch stands and is not spent, or one did and was noted then
(`leave_recorded_v1`, kept because a relay's acknowledgement
ends the record): an earlier epoch's record answers nothing. It ends at its
bound like any other leave
(`a_routing_rotation_onto_another_circles_id_holds_both_circles`,
`a_welcome_naming_another_circles_routing_id_holds_both_circles`,
`a_collided_circles_later_leave_proposal_is_recorded_for_its_own_relays`,
`another_circles_proposal_a_leave_hands_back_goes_to_that_circles_relays`,
`a_leave_proposed_with_no_record_is_not_answered_as_proposed`,
`an_earlier_epochs_standing_record_answers_no_later_leave_as_proposed`,
`a_failed_leave_proposal_is_redriven_byte_identical_in_a_quiet_circle`). The relays
a rotation onto a held id names are recorded in the contamination ledger
though the row follows nothing
(`a_rotation_onto_another_circles_id_records_the_relays_it_names`). While
two rows name one id, a write made with it is given to neither circle, a
held circle's delivery health is unknown — no instant, never one another
circle may have written under the shared id; a held circle's own stamps
from before the collision are not shown either — and
leaving one drops a row keyed by one of its routing ids only when no other
circle names that id, as its routing id or as a prior routing's — so every
row under the shared id stays, the leaver's own among them. The hold
survives a reopen, and one line naming neither says so. Nothing in Haven
can tell when the engine routes both again, so the hold ends only when the
user leaves the circle — each circle's with its own row; leaving one of the
two does not release the other, whose route MDK may still give away until
it re-derives it (`a_routing_rotation_onto_another_circles_id_holds_both_circles`,
`a_welcome_naming_another_circles_routing_id_holds_both_circles`;
`docs/MDK_UPSTREAM_TRACKER.md` T-ROUTING-ROTATION). The follow and its
prior id are pinned by
`a_routing_rotation_another_client_makes_is_followed_with_what_the_circle_keeps`,
`writes_made_with_a_rotated_circles_prior_id_land_on_it_and_go_with_it`,
`a_rotated_routing_id_is_swept_and_the_prior_one_for_a_day_only`,
`the_receiver_of_a_routing_rotation_listens_under_the_new_id_and_the_prior_for_a_day`,
`a_live_circle_listed_under_a_prior_routing_id_is_caught_up_when_both_reqs_end`,
`a_sweep_that_could_not_reach_a_prior_routing_leaves_its_circle_not_caught_up`,
`a_history_range_reaching_back_across_a_rotation_is_asked_under_the_prior_id`,
`a_history_range_never_tells_a_relay_the_circle_left_its_new_id`.
What it costs: for that day a relay that carried both ids is asked for both
by one socket, and so can link them — and after it, a history range a
refused event owes asks every id the circle keeps of each relay it was
used with, so a relay that carried both is asked for both again whenever
such a range is walked, until a routing change made more than the
retained window later prunes the prior id; a prior routing whose relay is dead
holds the circle not caught up — no eviction staged by this device — for up
to that day (OWNER_ITEMS 201). The app's own foreground poll in the poll
configuration fetches the current id only; a prior id is reached there by
the catch-up sweep a resume or a wake runs. A prior routing's relays
are listed for that REQ for a day from when this device recorded the
change, measured on the history row's own write (a clock reading earlier
than the write counts as the day over), and while an epoch that used them
can still be fetched; past the day they are an address the circle's traffic
is fetched at by id only, and the catch-up sweep asks them for the same day
(decision 237; `a_relay_a_circle_left_keeps_its_standing_req_for_a_day_and_no_longer`,
`catchup_sweeps_a_relay_the_circle_left_for_a_day_and_no_longer`). The
session wakes its follow by itself at the first second the earliest prior
routing no longer stands, so the REQ there ends when the day does and the
relay, which no listed REQ then uses, is removed from the pool and its
socket closed, one `disconnect` with nothing re-asserting it
(`a_relay_a_circle_left_is_let_go_when_its_day_ends_with_nothing_asking`).
The wake is a sleep in the running process: a process suspended across the
day's end ends the REQ at its next wake or open, and a clock set back past
the history row's write reads the day as over at the next follow, not on
the timer. A clock stepped forward does not bring the timer forward: the
sleep is measured on the monotonic clock, so the REQ stands as long in
elapsed time as it would have without the step, and outlives the
wall-clock day by the step — at most what the timer had left — unless an
earlier follow reads the day as over. A circle whose move fails stays
listed for the relays it wanted, out of the REQ it shared, and the next
health tick a claimed foreground makes, or the next burst open, issues its
REQ there
(`a_circle_whose_move_fails_stays_listed_and_the_health_repair_issues_it`).
Until a follow runs the circle is still listened for at the relays it
left, and the mark does not wait for that. And a device that APPLIES a
peer's change of relays in a burst is not held at all: the burst's own
follow moves the circle's REQ (above). A process with NO
live plane — the poll configuration, the Android service's isolate, the
app's own isolate before its session is started — has no lifecycle here to
read, and the absence of a claim is read as its absence, never as a claim:
the mark, which whichever process finished the change writes into the one
circle store they share, holds its sends too
(`a_change_of_relays_already_applied_is_finished_and_the_circles_row_follows`).
The cost falls where no plane ever claims the foreground. The Android
service's isolate, and the app's own before its claim, send nothing for
such a circle until the app's claimed foreground has completed a full
drive. A poll-configuration build writes no such mark — it makes no pass
that only finishes — so it meets one only in a store a live-sync build
left, and then cannot end it.
It writes the one record nothing else would keep, for a leave the engine has
minted again. It rolls back through the engine a commit it finds staged with
NO record, which was handed to nobody — the one thing it undoes. And it retires a queued change of the group, its circle told first,
where that change is what holds the circle at its epoch. When what it
retires is a REMOVAL of somebody the circle still lists, who it named is
kept before the change goes — member ids, in the SQLCipher-encrypted circle
store and nowhere else, never in a log
(`an_event_arriving_behind_a_queued_change_in_a_burst_is_applied_and_the_change_retired`)
— beside the note that says a removal was dropped
(`ChangeNote::QueuedRemovalDropped`). While one of them is still in the
circle nothing is sealed for it by any call, a claimed foreground's included
(decision 238; `SendHeld::RemovalUnmade`): the member the admin asked to
remove can still read. A foreground drive does NOT
end that. It ends when nobody the removal named is listed any more — read
from the applied roster, with the names dropped and the note said again as a
change no longer to be made (`ChangeNote::QueuedChangeDropped`: what was
asked for is already so — somebody else removed the member, or they left)
(`the_hold_a_removal_set_aside_raised_ends_when_its_member_is_no_longer_listed`)
— or when the note is acknowledged, which deletes the names with it; they
are deleted with the circle too. A removal the open finds queued is treated
the same, and read again in that open as soon as the engine can say who is
listed (`a_change_found_queued_at_an_open_is_retired_said_and_holds_nothing_back`).
The note shows on the change card in Circle details
(`haven/lib/src/widgets/circles/change_notice_card.dart`), which offers an
admin "Remove again" and acknowledges only on a confirmed "Keep them"; until
the member is removed again or the note acknowledged, such a circle shares
nothing — the price of not sealing, unattended, for somebody the admin asked
to remove. A
process with no live plane reads this hold as well, for the same reason and
at the same cost: on Android the isolate that shares in the background is
such a process, and in the poll configuration the hold stands even in front
of the user
(`an_event_arriving_behind_a_queued_change_in_a_burst_is_applied_and_the_change_retired`).

**A leave holds every send of its circle from the instant it is asked**
(`docs/MDK_UPSTREAM_TRACKER.md` T-LEAVE-FANOUT). What follows is a property
of the driver's entries, `Publishing::leave` and `Publishing::resume_leave`,
which the bridge exposes (`RelayManagerFfi::leave_driven`,
`resume_leave_driven`) and the app's leave alone takes: `leave_driven` at
the press, and `resume_leave_driven` for each circle at every wake — the
foreground's health tick and its start-up and resume relay contact, read
again before each circle so a pause stops it there, each iOS burst, each
Android foreground-service cycle and each WorkManager wake, the last three
claiming no foreground. The leave intent, with the instant
it was first asked for, is written to the circle store before the engine is
asked for anything. From then no call seals a location of the circle — a
claimed foreground's, a burst's, a session's only started, a process's with
no live plane — each answered typed (`SendHeld::Leaving`), and
read again in the engine hold that would seal, after its hand-back of
stranded input and with nothing awaited before the seal
(`a_leave_asked_for_while_the_legacy_seal_hands_back_holds_that_seal`); and
the driver sends no recorded location whose pre-send check — read before the
send begins, which the press does not wait for — finds the intent: a record
not yet sent is deleted. A store that cannot say whether the intent stands is
read as "it does"
(`a_pending_leave_stops_location_publishing_on_every_plane_immediately`,
`an_unattempted_location_for_a_leaving_circle_is_deleted_not_published`,
`an_unreadable_circle_store_holds_every_send_and_logs_nothing_identifying`).
An admin's leave is held from its first step, the hand-over of the circle
(`an_admins_leave_holds_sharing_from_its_first_step`). A circle that is not
stable when Leave is pressed is proposed for by a later attempt
(`Publishing::resume_leave`, which every wake calls); its sharing stays
off meanwhile, and a leave the engine QUEUED behind what it staged first is
taken back out of the queue in that hold, so no later drain mints it outside
a record (`a_leave_pressed_while_a_commit_is_pending_stops_sharing_and_is_proposed_after_the_ack`,
`a_leave_killed_between_the_mark_and_the_proposal_is_reproposed_on_reopen`,
`a_leave_the_engine_queued_is_taken_back_and_proposed_from_its_record`).
Within an epoch the retry is the engine's own stored proposal, byte for byte
(`a_failed_leave_proposal_is_redriven_byte_identical_in_a_quiet_circle`);
for a later epoch the engine mints the next one itself, and the stale
epoch's record is never sent again and is deleted once its attempt paces no
relay (`a_fresh_leave_proposal_for_a_new_epoch_deletes_the_stale_epochs_fanout`).
A drive that makes no new commit sends a leave's proposal too, its first
transmission included: the user asked to leave in front of the app, and
holding it would keep them in the circle
(`a_leave_proposal_is_sent_by_a_drive_that_only_finishes`). The intent ends
with the circle, or when the engine refuses the leave for good — a circle it
does not hold, or, through the legacy `propose_leave` alone, an admin who
must step down first; the driver keeps the intent and steps down instead —
and the circle shares again
(`a_permanently_refused_leave_clears_the_intent_and_keeps_its_directory_semantics`);
an intent the store will not clear keeps holding
(`a_refused_leave_whose_intent_cannot_be_cleared_holds_and_logs_nothing_identifying`).
`resume_leave` ends the leave on this device when it finds this device's copy
marked removed, or `LEAVE_BOUND_MS` (a day) passed on the driver's clock
since the first press, or since the latest press that found no proposal ever
minted (MDK holds no `LeaveRequest` with `last_proposed_epoch`; one it cannot
read counts as minted) — or the intent lying more than an hour
(`RETRY_MAX_MS`) ahead of that clock, which was stepped back
(`a_pending_leave_ends_at_its_bound_anchored_on_the_intent_time`,
`a_press_that_finds_no_proposal_ever_minted_renews_the_leaves_instant`,
`a_leave_whose_intent_lies_ahead_of_a_stepped_back_clock_ends`); Rust arms no
timer for it, and the app carries every leave on (**Driver 2** under
"Bounded leave-removal window under live-sync"). Ending it deletes the circle
row and the circle's location records unsent, and its proposal records then
send nothing — each proposal record's own day runs from its minting; a
record whose circle row cannot be read is neither sent nor ended
(`a_leave_proposal_whose_circles_row_cannot_be_read_is_kept_untouched`) —
and its members keep this device on their roster until a member commits a
`SelfRemove` they hold, or an admin removes it (`a_location_sealed_before_a_leave_is_never_sent_once_the_circle_is_left`,
`a_leave_proposal_is_not_sent_once_the_leave_has_completed`). A process that
died after the engine recorded the leave and before its proposal was recorded
leaves nothing to send at that epoch — the engine refuses a second proposal
for one epoch — and the leave then ends at that bound
(`a_kill_between_the_leave_request_and_its_fanout_put_still_ends_the_leave`).
The app takes these entries alone since W9o-1b, and since W9q the bridge
carries no legacy seal, no `publish_location_event` and no legacy hand-over
or step-down. The legacy leave (`propose_leave`, `complete_leave`) stays in
the bridge for the integration harness; its one residual, an unbounded
legacy leave, does not arise from the app. A legacy leave the engine queued is answered as standing and left in
the engine's queue for its own drain to propose
(`a_legacy_leave_the_engine_queued_stands_and_stays_queued`). A leave's end
forgets the circle's MLS group through MDK's `forget_group_local` before its
row goes (`CircleManager::complete_leave`; a forget the engine refuses keeps
the row and the intent for the next attempt): the group's state, epoch
secrets, records and leave request are deleted, and no key of the group stays
outside it — not a joined member's leaf key, not the new one of an own commit
left pending (`left_circle_e2e::{a_left_circle_leaves_no_mls_state_behind,
forget_group_local_after_applied_leave_leaves_no_outstanding_fanout,
the_forget_leaves_no_key_of_the_group_behind}`). Three things keep a group
unforgotten, asked about again at every foreground drive and at every open
from a durable list of left groups (`left_groups` in the circle store,
written in the transaction that deletes the row;
`a_left_circle_kept_unreadable_is_forgotten_once_readable_after_a_restart`):
a disbanded circle, whose tombstone the forget would delete
(`leaving_a_disbanded_circle_keeps_its_tombstone`; tracker
T-FORGET-TOMBSTONE); a group the engine cannot read (quarantined, not yet
hydrated, a store that does not answer); and an invitation from a member of
its last roster held unanswered — the forget makes MDK refuse every Welcome
written before it, so a re-invite made before this device saw its removal
could never join (`a_reinvite_written_before_the_removal_was_seen_still_joins`;
tracker T-REJOIN-LEAVE). Until it is answered, or the group can be read, the
circle's old epochs' keys stay on the device; its row is gone, so nothing of
the circle is followed, received or sent meanwhile. Invitations held before a
restart are counted durably, and until as many are held again a re-invite not
yet polled back counts as held
(`a_reinvite_not_yet_polled_back_after_a_restart_still_keeps_the_left_group`)
— unless a key package was replaced while none was held: nothing held before
can open the superseded package, so none of it is waited for any more
(`a_key_package_replaced_after_a_restart_ends_the_wait_for_what_was_held_before_it`).
The first receive plane of each session also forgets every
group the session held at its open that no circle row names and no consented
join is still owed for — what a create, join or leave that died midway leaves
— never one made after the open, and none whose row cannot be read
(`an_orphaned_group_is_forgotten_at_the_next_open`,
`an_owed_consented_join_is_never_swept`).

**A circle an admin disbanded is read as disbanded from MDK's tombstone,
every time** — durable, and put back at every open, so a crash that lost the
announcement changes nothing; Haven keeps no disband state of its own, and a
relay cannot forge one (only an authenticated settle writes the tombstone).
Nothing is sealed for it (`SendHeld::Disbanded`), no receive plane or sweep
reads it, and its routing id is unlisted; MDK's settle deleted its records,
queued changes and offers, and Haven clears what it keeps beside them (Welcome
routes, the notes that a Welcome or re-invite is owed, location records) at
the announcement and at every open. A drive whose record the settle deletes
under it writes nothing back, sends nothing more and is no error. The disband
is no removal: the member directory neither keeps its former members current
nor deletes them as severed — they age out as after a leave. Leaving it ends
the circle's row and keeps the tombstone (`disband_e2e`;
`leaving_a_disbanded_circle_keeps_its_tombstone`).

**A change branch selection withdrew is asked of MDK again — a removal
excepted, which is offered to the user instead, as a removal set aside
unmade is** (`docs/MDK_UPSTREAM_TRACKER.md` T-REISSUE). Both run on a full drive (`Publishing::resume`), which the live
plane makes in a claimed foreground (`EngineProcessor::drive_due`): live in
the default configuration. What is owed is read from the store, not from the
process that heard of it — a retained own-commit intent whose commit MDK
parked `ConvergenceDeferred` or `EpochInvalidated`, the read MDK's
state-derived form makes — so a withdrawal a background session heard and
never drove is made by the next foreground one. A withdrawn removal is never
handed to MDK (decision 233): MDK's re-issue names its members by a member id
it cannot tell from a member the circle has since invited back (T-REISSUE ask
4), so it would remove that person unattended. One none of whose named
members is on the applied, stable roster asked for what is already so — the
commonest race, two admins removing the same member — and is deleted as
MDK's own re-issue would answer it (`AlreadySatisfied`), nobody held and
nothing said
(`a_withdrawn_removal_of_a_member_already_gone_is_satisfied_and_says_nothing`);
its members are kept as taken out at that epoch, with their asks spent, for
as long as a reorg could still bring one back — one that does is held and
said again as for any member a withdrawn commit had taken out
(`a_member_an_already_satisfied_removal_named_is_held_again_when_a_reorg_brings_them_back`).
Any other is dropped as an offer at
once, wherever its circle stands: every member it named is kept with its asks
spent — so nothing is sealed for the circle by any call, a claimed
foreground's included, while one is still listed (decision 238) — then `ChangeNote::QueuedRemovalDropped` and
`ChangeNote::ChangeWithdrawn` are said, and only then is MDK's record deleted
(on the second connection, under the engine hold: the engine keeps no such
record in memory, and the delete moves no epoch, consumes no proposal and
touches no ratchet). If a write fails the record stays, nothing is re-issued,
and the next drive tries again. In a circle this device left or no longer
keeps the record goes alone, said to be no member's. The cost: after a race
between admins the user removes again from the notice, and sharing to that
circle stays paused — in the foreground too — until they do, acknowledge the
notice, or the member is no longer listed. Every other withdrawn
change is handed to MDK's own per-commit entry
(`reissue_superseded_own_commit`), one at a time while the drive has room,
never a second implementation: only in a circle this session
has caught up with, that is stable, with no convergence input unresolved, no
commit of this device's staged and — unless it is being left — no group change
queued; or one this device is no longer in, where MDK makes nothing; or one it
keeps no row for (left, its state kept until it is forgotten), where what MDK
queues again is taken back; and not while whether the circle is being left —
Haven's intent, or MDK's own `LeaveRequest`, which a legacy leave writes alone
— cannot be read. MDK's state-derived form re-issues every parked record it
finds, so it runs only once nothing owed is left unasked — for what it alone
does, collecting the records past the rewind horizon; while anything is left
(a circle not yet settled, with a row or without, or a removal whose drop
failed), it does not run, and those records wait. A change still valid is queued again by MDK
and, when the same drive's advance released that copy into a record,
returned `Reissued` (awaiting its relays, not yet made); one the advance did
not release is returned `Queued` — the circle's next full advance makes it,
caught up or not then (MDK regenerates it against the state it holds; made
from an epoch the circle has left it is a rival the circle's branch selection
adjudicates, re-issued by MDK at most twice), or the next open retires it,
saying it was dropped. The answer is typed (`WithdrawnChange { kind,
outcome }`), carried to Dart by the bridge (`ResumeOutcomeFfi.withdrawn`),
where nothing reads it, and discarded by the live plane (the user is told by
the durable note, on the change card): a conflict or
an abandoned change is said durably (`ChangeNote::ChangeWithdrawn`; MDK's
other abandoning answer, a full queue, is never reached, since a circle with a
change queued is not asked about), a spent invite is said as owed again
(`ChangeNote::ReinviteOwed`; MDK keeps that record, and its re-invite is
driven by `reinvite_driven` from the app's foreground maintenance tick —
below),
and in a circle
being left nothing is made again and nothing is counted failed: the
one copy MDK queued again is taken back in the same engine hold through MDK's
own delete, every other change the user queued stands, and a copy that cannot
be taken back is returned `Queued`
(`a_fresh_own_removal_that_loses_to_a_removal_and_an_invite_back_is_dropped_and_held`,
`a_dropped_removal_holds_every_member_it_named`,
`a_withdrawn_removal_whose_drop_cannot_be_said_stays_in_place`,
`a_withdrawn_relay_change_is_still_reissued_through_mdk_and_made`,
`a_withdrawn_change_in_an_unsettled_circle_with_no_row_holds_back_mdks_reissue`,
`a_withdrawn_change_is_not_shown_as_applied`,
`a_withdrawal_a_session_never_drove_is_made_again_by_the_next`,
`a_withdrawn_change_stays_owed_while_the_engine_is_held_or_mdk_errs`,
`a_withdrawn_change_queued_again_and_not_staged_is_returned_queued`,
`an_abandoned_reissue_is_returned_typed_and_the_change_is_not_applied`,
`a_withdrawn_invite_is_said_to_need_a_fresh_invite`,
`a_withdrawn_change_of_a_device_since_removed_is_no_members`,
`a_withdrawn_change_in_a_circle_being_left_is_retired_not_failed`,
`own_commit_intents_are_collected_past_the_rewind_horizon`). A leave
completed while a removal of this device on a withdrawn branch had been
applied stays completed: a removal is terminal for the device that saw it
(Marmot `member-departure.md` 143-144).

A removal the user asked for that a call set aside unmade
(`ChangeNote::QueuedRemovalDropped`) is not asked for again by itself: what
ships is "offered" (decision 233, `REQUEUE_SET_ASIDE_REMOVALS` false). The
members it named stay held — nothing is sealed for the circle by any call,
a claimed foreground's included
(decision 238; OWNER_ITEMS 193): a member the user asked to remove reads
nothing sealed after the ask — and the note stands until the user removes
them again from the change card, which calls the driver's removal for
those still listed, or acknowledges it, which drops the kept
members with the note; a member no longer listed holds nothing
(`a_removal_set_aside_is_held_and_noted_and_never_asked_for_again`,
`a_removal_set_aside_holds_a_claimed_foregrounds_seal_until_it_is_made`,
`a_removal_set_aside_stops_holding_once_its_member_is_no_longer_listed`). The
automatic posture the owner may still choose (OWNER_ITEMS 179), behind the
same switch and tested through a test-only override, asks for it again by a
full drive (decision 180): for the members it named who are still listed;
only in a circle this session has caught up with, that is stable, with no
convergence input unresolved, no commit of this device's staged and no group
change queued — so the ask is staged at once under a record, and one the
engine would queue instead is taken back in its hold and spends nothing — that
this device is not leaving, and only while it is an admin. A member announced
as taken out by a commit this device applied — whoever removed them
(`GroupStateChanged` `MemberRemoved`/`MemberLeft`), or as the applied roster
reads where that batch was lost with its process — no longer holds the circle
and is not asked for again, so one removed and invited back in separate
passes is not removed again. MDK announces a pass's NET membership change and
names its commit only when it accepted one (`distributed_convergence.rs`
1845-1895, 2380-2385), so a pass that accepted several — counted as the epochs
it moved plus the commits it set aside, which errs toward counting a rival
this device never applied — spends the asks of every member it holds,
counted after the same batch's withdrawals have brought members back (MDK
announces `GroupStateInvalidated` for every commit a pass parks, applied here
or not, so a routine fork whose parked rival this device never applied counts
too: the removal it held is then left to the user, a cost in prompt removals,
never a removal made unattended): a
member it removed and invited back is never announced as removed, and is held
and told instead of removed (decision 227). And any applied commit that adds
a member a removal names (`GroupStateChanged` `MemberAdded`, on every plane,
in whatever batch it arrives) spends that member's asks: a re-invite, by
anyone, is the circle's choice, so this device never removes that person
unattended and the user decides from the notice (decision 230). Any withdrawal
(`GroupStateInvalidated`) brings back every member taken out, with the hold
and the note; the ask is kept only for one whose removal was announced with
the withdrawn commit's id, and every other comes back with its asks spent.
Three gaps, two still open: a removal applied with no announcement keyed to it
is brought back by any later withdrawal only with its asks spent; a withdrawal
announcement lost with its process brings back nothing; and — closed by
decision 230 — this device's own removal of a member, keyed, losing to a
co-admin's removal of the same member and their invitation back, which
brought that member back keyed with an ask either in the pass that spends
(the spend ran first) or a pass before the invitation's
(`an_own_removal_that_loses_to_a_removal_and_an_invite_back_is_not_made_again`,
`a_member_brought_back_by_the_pass_that_spends_is_spent_with_the_rest`,
`a_target_any_applied_commit_adds_is_never_asked_for_again`). Each member is
bounded by Haven's own rule, not MDK's (MDK bounds its re-issue by attempts
alone, and its horizon only collects): two asks (`MAX_REQUEUE_ATTEMPTS`, MDK's
number, held equal by a test), each spent before its commit is staged and
refunded when nothing was staged — a spend that cannot be written asks
nothing; none once the circle is more than
`max_rewind_commits` epochs past the epoch the removal was set aside at; and
none for a set-aside copy MDK had itself re-issued. Past a bound the members
stay held — sharing to that circle stays paused, in the foreground too — and
the note stays for the user to acknowledge on the change card. A device
that is no longer an admin asks nothing and keeps the hold, with no expiry:
that errs toward privacy. Once nobody it named is listed, the note is taken
back and nothing is said in its place — what the user asked for holds
(`a_removal_set_aside_is_asked_for_again_and_made_once_the_circle_is_caught_up`,
`a_removal_set_aside_whose_member_is_gone_is_already_made`,
`a_removal_set_aside_is_not_asked_for_again_once_its_member_was_removed_and_invited_back`,
`a_reorg_that_brings_back_a_member_a_removal_named_holds_and_asks_again`,
`a_contested_branch_does_not_remove_a_member_invited_back`,
`a_withdrawal_brings_back_every_target_and_spends_the_asks_of_those_it_cannot_key`,
`a_pass_of_several_commits_spends_every_held_targets_asks`,
`a_deep_reorg_brings_back_a_target_before_anything_forgets_it`,
`a_removal_set_aside_is_not_asked_for_beside_another_staged_commit`,
`a_drive_without_room_to_ask_spends_no_ask`,
`two_removals_set_aside_in_one_circle_keep_their_own_counts`,
`a_removal_asked_for_again_as_often_as_it_may_be_is_abandoned`,
`a_removal_set_aside_expires_past_the_rewind_horizon`,
`a_removal_set_aside_is_not_asked_for_in_a_circle_being_left`,
`a_removal_set_aside_is_not_asked_for_again_by_a_device_no_longer_an_admin`,
`a_removal_whose_requeue_count_cannot_be_read_is_not_asked_for_again`,
`a_removal_asked_for_again_and_made_later_is_not_retyped`,
`a_removal_is_not_asked_for_again_while_its_last_ask_is_pending`).

Both ride B1's mark of a caught-up circle, with its limits: on the sweep one
relay that drained marks it (the live plane needs an EOSE from every relay of
its REQ), a withholding relay's empty EOSE included; a future-epoch
commit parked `TransportDeferred` and stranded rows do not hold it back, so a
lagging circle can be asked of and the ask lose on depth (MDK's attempts then
run down to `Abandoned`); the live plane marks a circle only at an EOSE, so a
relay that never sends one keeps both waiting there; and a sweep's start
forgets the live plane's mark in the same session until that sweep drains.
What a relay sees of either: an ordinary commit on the circle's relays,
through the commit fanout and its per-relay pacing — for one original removal
none beyond the original as shipped, and in the automatic posture at worst
six commits (Haven's two asks, each of which MDK may re-issue twice) — and
for one withdrawn change other than a removal three (the original and MDK's
two re-issues) —
and nothing a drive would not otherwise send; no REQ and no timer of its own.

**A location rides a durable record that ends at its expiration**
(`docs/MDK_UPSTREAM_TRACKER.md` T-APP-TRANSPORT). On the driver's entries —
`Publishing::seal_location`, then `Publishing::publish_location`; the only
send of a location since W9q — a sealed
location is given MDK's own record for an application message in the engine
hold that sealed it: the exact signed event, the relays the circle's routing
names at that moment, and the epoch it was sealed at. That one hold does,
in order: hands the circle's stranded input back, or answers the send held;
reads the caller's mode again, with nothing awaited before the send; seals
nothing for a circle this device is leaving, and lets no call but a claimed
foreground's seal for a circle left waiting for one; makes the send, whose
own gates defer it behind a pending commit or a departure that is due; and
records only a location the engine sealed. A send that is held or deferred
writes no record and leaves nothing a later drive could send
(`a_seal_that_is_held_or_deferred_writes_no_record`). A refused eviction,
and a narrow call's due departure, are read in the hold before that one
(`departure_holds_a_send`) and not again in it: a refusal recorded between
the two holds does not stop that seal. From an eviction every relay refused
until it lands nothing is sealed for the circle: inside the wait the refusal
earned, and after it until the engine's re-armed deadline — when a send's
preflight would stage nothing ahead of it — the seal is answered held for the
departure (`SendHeld::DepartureDue`); once that deadline is reached the
preflight stages the eviction ahead of the send. MDK re-arms that deadline
10–50 ms of monotonic time after the refusal, so the stretch between the wait's
end and it is at most 50 ms, and past the wait it is MDK's preflight that
closes the circle (`departure_held`, its truth table in
`a_departure_holds_a_send_by_its_truth_table`;
`nothing_is_sealed_after_a_refused_eviction_before_its_re_armed_deadline`
asserts nothing sealed on either branch).

The record is not a queue and not a retry. `publish_location` offers the
event to the record's relays ONCE, through Haven's own location transport,
and deletes the record whatever was answered — two store writes a send — so
a send that returned is never made again
(`a_completed_location_send_is_never_retried_and_costs_two_writes`). It is
made only by the session that sealed it, and only when, read in one engine
hold immediately before the send begins: the circle's row still exists; this
device is still a member — MDK's own rule is that a removed copy never
publishes, and a record that cannot be read is a removed one; the circle
stands, stable, on the very epoch the location was sealed at; the engine
reports no unresolved convergence input — a commit, a rival-branch witness,
an open pass or a disband candidate, within five epochs either side (MDK
queues a fresh message then, and a commit taken in may remove a member);
deferred-peel rows and an exhausted foreground budget do not hold it, rows
the device cannot read being no removal it knows of; no commit of this
device's is staged and nothing stranded is owed; no leave is asked for and
no hold of a call that is not a claimed foreground's stands; and a scheduled
departure holds it inside the wait a refused eviction earned, or once due
for a call that makes no commit — the seal hold, above, also holds after
that wait; a record holds no such stretch, being sealed before the
refusal. Haven's hold
does not read the engine's monotonic real-time timer in the full mode, so
the answer does not turn on how much real time passed since the seal: MDK's
preflight stops a seal once the departure is due, and nothing stops a
departure that comes due after the seal. Otherwise the record ends unsent
(`a_location_sealed_before_a_removal_is_never_sent_after_it`,
`a_location_sealed_before_this_device_was_removed_is_never_sent`,
`a_location_of_a_copy_marked_removed_at_its_epoch_is_never_sent`,
`a_location_is_not_sent_while_a_commit_its_circle_took_in_is_unresolved`,
`a_location_another_session_sealed_is_never_sent_by_this_one`,
`a_circle_that_owes_a_removal_under_a_skewed_clock_seals_nothing_while_every_relay_refuses_it`). That
holds of a commit this device has applied before the send begins: bytes
already handed over are not recalled by one applied while they travel.

A record this session did not seal — one a process died with, before its
send or inside it — is never sent (decision 212): the next drive, in either
mode and whatever time it has, and the drive every change makes first,
deletes it without contacting a relay
(`a_location_whose_send_a_process_did_not_finish_is_never_sent_by_another`).
The core cannot tell whether its user still shares — they may have turned
sharing off, or stopped the app to stop it — and a change's first drive
would otherwise send a stale fix just before a removal, or to the relays a
change is leaving. The spec ends the obligation at the event's expiration
and leaves the rest to local policy (`transports/nostr.md` 346-355); the
next tick seals a fresher fix. The store's own faults fall on the safe side:
a location whose record cannot be WRITTEN is not handed out to be sent at
all (`a_location_whose_record_cannot_be_written_is_never_handed_out`), and
one whose record cannot be DELETED after its send is, to the next process,
a record it did not seal, deleted unsent. No record is sent within one
send's window — ten seconds, the connect and the acknowledgement wait — of
its NIP-40 `expiration`, and the first drive at or after that instant
deletes it, in any mode, with no relay contacted
(`an_application_fanout_ends_at_its_expiration_and_never_blocks`); a
configuration that drives nothing leaves it in the store, unsendable, until
a drive runs. A drive that only finishes sends a burst's own location and
deletes one a dead process left
(`a_drive_that_only_finishes_sends_its_own_location_and_deletes_an_interrupted_one`).
A commit's driver does not see a location's record: it is not counted in a
relay's pacing, holds no change of the circle, is taken up only after every
commit and proposal, and a drive never touches one whose send is under way
(`a_concurrent_drive_never_touches_an_in_flight_location`). On these
entries no relay is offered a location's event twice.

**What the engine leaves stranded is detected, said, and handed back**
(`docs/MDK_UPSTREAM_TRACKER.md` T-PARKED-REPLAY). While a commit of this
device's is pending the engine stores, unopened, EVERY `kind:445` of that
circle that arrives — a fix, a proposal and a peer's commit alike, and,
because the gate is ahead of any authentication, whatever anybody who knows
the circle's routing tag sends under it — and reads those rows again only at
the end of a confirm, of a rollback and of a join. A row left in that state
in a circle that holds no pending commit is STRANDED: delivered by nothing
until this device next confirms or rolls back a commit of its own there, and
answered as buffered at every redelivery meanwhile. A re-join does not
deliver a row from before the new copy's join epoch: it ends it undelivered,
the old epoch's state being discarded with the join (Marmot
`member-departure.md` 143-146); what its replay does deliver is what was
parked for the new copy's own epochs — a commit that raced ahead of the
re-add Welcome. Rows get there seven
ways, six of them reproduced on the real engine
(`haven-core/tests/stranded_input_measured_e2e.rs`,
`stranded_input_e2e.rs`): a death after a confirm's transaction; a death
after a rollback's; the engine's own clearing of a staged commit at an open;
a replayed row that errors, with no death at all, which also holds up every
row behind it at every later replay; the engine's sweep of a deferred row
failing on it, with no pending commit involved at all; the engine's own
replay having no room for a row it cannot open — its deferral store full, it
answers `ResourceRefused`, leaves the row as it arrived and goes on, with no
death and no error (`cgka-engine/src/message_processor/mod.rs` 3634-3655),
which anyone who knows the routing tag can bring about; and (read, not run)
a re-join that dies before its replay.
What it costs was measured too: a stranded fix is one missed fix; a stranded
commit of a peer's leaves this device an epoch behind, unable to read what
follows and sealing what a member removed by that commit can still read; a
stranded rival commit the circle kept leaves it alone on a branch of its
own; a stranded leave makes the eviction that names it unappliable for good,
and this device's own next rollback then ends it on a different branch at
the same epoch number — alone there when its key is the higher of the two
committers', joined by each member handed its eviction when it is the
lower.

Haven reads the engine's store for such rows — a group event exactly as it
arrived, awaiting a retry, that the engine does not hold as processed, in a
circle the OPEN engine reports stable and this device is still in — at every
open, after every confirm and rollback it asks of the engine, and wherever a
redelivery is answered from one. A look is bounded and verifies nothing: it
reads no more rows of a circle than one past what Haven may keep for it
(256), through MDK's own streaming read, which filters by state in SQL,
visits in arrival order and stops where its caller has read enough
(`visit_messages_in_states`) — and a relay serving stranded rows again has
their circle scanned once between two looks, however often. It first says so,
durably (`ChangeNote::UnreadChange` for an event that by its stored tags
claims to be a commit or a proposal, `ChangeNote::UnreadLocation` for a
fix): that input is waiting unread, never that the circle is out of step,
because nothing in an unopened event is authenticated.

Then, at the top of every call that hands the engine an event, advances a
circle, or seals or stages for one — every ingest and advance, a location
send, a change of the group, a leave and the admin-policy sends
(`every_entry_that_takes_seals_stages_or_advances_hands_stranded_input_back_first`
enumerates them from the source) — it hands the rows back to the engine one
at a time: the signed event is verified and kept in Haven's own store
(`kept_input`, ciphertext as a relay served it, in the SQLCipher-encrypted
circle database), the engine's row is released through MDK's own
`release_message_for_replay`, the event is ingested through the same screen
and the same engine call a relay's delivery takes, and the kept copy is
destroyed on an answer that says the engine judged the event or holds it
again. A death at any point loses nothing, repeats nothing and keeps the
order (`a_death_at_any_point_of_a_hand_back_loses_nothing_repeats_nothing_and_keeps_the_order`).
The circle a call is for is seen to first — as far as the call's room
goes, below — its state read again
before each event, so nothing new of a circle is taken, sealed or staged
ahead of what that circle was owed: a location asked for right after the
open that found a stranded removal is not sealed for the removed member, and
a change of the group is not staged from the epoch the circle has left. In
order: what an earlier hold kept and the engine was never asked for; the
engine's rows as they arrived; and last what the engine erred on, which is
tried again at each look whatever stopped the entries ahead of it. One call
hands back at most 256 of its own circle's events (`HAND_BACK_WHOLE`), and a
call that makes no commit and runs inside a wake — a burst's, a paused
session's — sixteen
(`HAND_BACK_SLICE`). While the call's own circle still
holds input the hand-back can take and has not — the call's room ran out,
the circle's cap stands, the engine's store refused a release, or a store
could not be read or written before a row was taken over
(`a_hand_back_whose_store_cannot_say_what_stands_holds_its_circle_and_loses_nothing`)
— the call
does nothing else for that circle and says so, typed: the engine is not
asked, an ingest's caller holds its cursor (`GroupProcessOutcome::Held`), a
location send is answered deferred (`CircleError::SendDeferred`) and a
change of the group held (`CircleError::EngineHeld`), and the next call
carries on. Each such hold ends by something that happens: room, at the
next call; the cap, when an entry ends, which every call tries while it
stands; a release or a store that failed, when it answers. An event the
engine has no room for is not kept — its entry ends once its id is on record
as owed its refetch, below — and neither is one the engine erred on AFTER
writing its own record of it, which a member, or one since removed who still
holds the epoch's key, can send without number: so each call ends as many
entries as it had room for, whoever sent them. With N events of anybody's
parked ahead of a stranded removal, that removal is handed back within
⌈(N+1)/256⌉ calls in the foreground and ⌈(N+1)/16⌉ in a burst or beside
one, and no location is sealed for the removed member meanwhile
(`an_outsiders_flood_cannot_keep_a_stranded_removal_from_being_handed_back`,
against the real engine's refusals;
`a_removed_members_messages_the_engine_errs_on_fill_nothing_and_the_removal_behind_them_is_handed_back`,
against its errors). N itself has no bound: MDK caps what it
DEFERS at 2048 rows a circle and not what it parks ahead of the peel. Every
other circle shares one slice of sixteen per call.

What the engine makes of a handed-back event is folded by the plane that was
calling, in the lifecycle it is in, each result under its own circle — a
finish-only plane records and stages nothing for it. The hand-back itself
contacts no relay and issues no REQ. What the engine then makes of the event
is what it makes of a relay's delivery: a handed-back leave has a full plane
stage and publish the eviction, as a delivered leave does. An event is
handed back whatever its tags say: a NIP-40 expiration is unauthenticated
and decides nothing here (Marmot `transports/nostr.md` 190-192), and the
engine reads none when it replays its own rows. An old fix handed back is
shown as no fresher than the time its sender put inside it — the last-known
row ranks by that time, capped by arrival — so it never displaces a newer
fix of the same member
(`a_handed_back_fix_never_displaces_a_newer_one_of_the_same_member`). What
is kept is destroyed with its circle, with the whole store at logout, and
when this device is found removed.

Not repaired, and said: a session with no durable store releases nothing and
holds nothing; a circle holds at most 256 kept events or 4 MiB — only what
the engine has not been asked about yet, and what it erred on with NO RECORD
of its own, count — and while that cap stands what is past it waits with the
engine and the circle's own calls are answered held, each of which asks the
engine again for what fills it. No sender fills it. The engine errs on an
ingest for a fault of its own store, or AFTER it has written its own record
of the event — an application message whose sender's ratchet is further
ahead than the engine will follow (`OpenMLS` answers `TooDistantInTheFuture`
past a thousand generations at MDK's setting; MDK stores the row and its
processed id first and only then errs, `cgka-engine/src/message_processor/
ingest.rs` 1206-1219, 1345-1347). The second kind ends where it is handed
back: the engine holds its id as processed, a redelivery is a duplicate to
it from then on, and nothing of it is kept. So the cap fills only through a
fault of this device's own store, and that hold ends when the store answers
(`past_the_cap_nothing_more_is_taken_over_and_the_circles_calls_wait`). A
row that is not a verifiable event is left
and holds nothing — it can never be handed back, and its note stands; every
event the engine is handed has passed Haven's own verification (Rule 16), so
such a row is a damaged store and not something a sender can cause. A kept
COPY that is no longer its event does not stay: beside the engine's row it
ends and the row is taken over afresh at the next call, and with no row left
it ends with its id owed its refetch. A row
whose release the engine's store refuses is left, with no copy kept beside
it, and holds its circle's calls until the store takes the release, which
every call tries again; so does a store that cannot be read, or will not
take the copy, before a row is taken over. An event the engine errs on with
no record of its own is never given up on — not on a count of tries, and not
on a count of epochs: it is asked for once at each look (an open, a confirm
or rollback, a change of its circle's epoch), keeps its circle told, and
ends when the engine answers for it or its circle is left. How far the
circle has moved says nothing about an event the engine never opened: it may
be from an epoch the device has not reached
(`an_event_the_engine_erred_on_is_not_ended_by_a_count_of_epochs`). An event
the engine has NO ROOM for (`ResourceRefused`, or left unpersisted — an
unknown route excepted, for which nothing is owed) is not kept once its id
is on record in the refused ledger, and is owed its refetch by id like any
other object the engine refused; while that write fails it stays kept. One
the engine DEFERS is the engine's again and is owed nothing, unless the
engine later lets it go, which it announces. That refetch is paced and
forgets nothing. A sweep sends at most two requests of 128 ids a circle
(`REFETCH_REQS_PER_SWEEP`, `REFETCH_IDS_PER_REQ` — MDK's own by-id batch),
whenever in the sweep they are sent, and past 1024 owed ids the rest are
owed as a range of the circle's history, walked down a page budget a pass.
The range's ceiling is never lowered — `created_at` is the sender's to
choose. A pass that halts carries the WALK down from where the last one
stopped, and one that halted on a full page dated entirely in one second
steps the walk below that second and keeps the range owed: events beyond a
relay's page limit that share one second are unreachable by NIP-01 paging,
and everything below them stays reachable. That is exact at Haven's own page
size (500); a relay that clamps `limit` below its pile-up is stepped past by
the one-second confirming step with nothing owed for what it hid, and
NIP-01's tie order (lowest id first) lets whoever dates the pile-up choose
which event at that second falls past the page
(`a_pile_up_dated_in_one_second_cannot_keep_a_commit_below_it_from_being_fetched`).
The walk ends the range only when it has reached the circle's start, every
relay answering in full in the pass that reached the start — a relay
unreachable during an earlier pass of the walk is covered by the same
assumption the cursor makes — with the engine holding something of EVERY
event any pass of it brought back, an event it recorded and then erred on
included (`an_event_the_engine_recorded_and_then_erred_on_keeps_no_range_owed`). The engine announces
nothing when it refuses an event at ingest, so one it had no room for, erred
on, or was never asked about — the circle's stranded input was still being
handed back — is on record nowhere but in the range: a walk that brought one
back begins again at the ceiling
(`a_commit_the_engine_refuses_again_inside_a_range_pass_stays_owed`,
`a_range_pass_the_hand_back_held_ends_nothing`). Ids are asked for from
the front of a queue: one joins at the back when it is recorded and goes to
the back each time it is asked for, so nobody who mints ids — low ones, or
fresh ones for every sweep — keeps theirs ahead of one that was owed first.
An id a sweep could not discharge is asked for again after a minute, then
two, doubling to once a day (`refetch_spacing_secs` — eleven requests for
one id in its first day, one a day after). A new epoch of its circle makes
every owed id and the owed range due at once and ENDS NOTHING: what was
refused for want of room is as a rule an event from an epoch the device has
not reached, and a device many commits behind needs each of them when it
gets there
(`a_device_far_behind_with_no_room_reaches_its_circles_epoch_and_no_owed_commit_ends_on_the_way`).
At a new epoch the owed ids are also ASKED for: by the sweep in which the
epoch moved, out of the same two requests and before that sweep's next
round of advances for the circle (the first two moves of a sweep; the range
at the circle's turn); by the live plane, which holds no REQ of its own to
ask with, through a status the app answers with a refetch at most once a
minute and the plane does not wait for — so there a refused event can still
be overtaken. A
confirm, a rollback and a send that move an epoch ask for nothing — the next
sweep does — so an event refused before them can still be overtaken by what
the next advance settles. When the engine has no room for ANYTHING a request
brought back, the ids already asked for wait at least as long as the soonest
of those just asked; an id that has not had its turn keeps it, and the
sweep's share is asked for in full. The range keeps a schedule of its own: a
pass that carries the walk down leaves the rest due at once; one that
carries it no further — halted where it began, or come to the bottom with
something still owed — doubles the wait before the next, from a minute to a
day; and it is asked for when due whatever the ids beside it are waiting
for, because past the cap an event is owed as part of the range only
(`an_outsiders_refused_flood_cannot_keep_a_members_commit_from_being_fetched`).
While a walk is descending a relay is therefore asked for up to eight pages
of 500 events a sweep, and a minute on the live plane; a walk that keeps
ending with something owed — an outsider's events the relay goes on
serving and the engine goes on refusing — is one such descent a wait, the
wait doubling to a day. A clock stepped back leaves nothing waiting. And an
id is discharged only by a verdict, or when every relay asked answers a
request naming it with no event at all: an answer that brought some of the
ids it was asked for proves nothing about the rest — a relay may clamp
`limit` and send a subset before its EOSE — and those are asked for again
by themselves, keeping their turn
(`an_id_a_relay_left_out_beside_others_it_sent_is_asked_for_again_and_not_given_up`).
A circle the engine
reports halted, or
one
this device was removed from, is not touched, and what is kept for a halted
circle has no time bound; and nothing schedules a hand-back — a row waits
for the next call for its circle on this device, the open-time advance of
every circle being the first. A redelivery answered from a stranded row
Haven can hand back to nobody — one that is not a verifiable event — holds
no cursor: the answer is the stored row's,
the same every time, and a held cursor fetched a commit or a proposal —
which carry no expiration — again at every sweep. One that arrives while
its circle's rows could not be kept or read is held with every other call of
that circle, until the store answers. It is the engine's
behaviour in every mode, and a deviation from the
protocol's durability rules. A death inside a finish-only confirm strands
what was parked exactly as a death inside any other confirm does, and the
next open hands it back; leaving an acknowledged commit pending instead
would go on parking everything its circle receives. The
sweep the app's wakes run (`run_catchup_all_circles`) makes no commit since
W9q: nothing in it can tell a background wake from the foreground, so it
drives in the mode that only finishes — what it receives is settled, and an
eviction left due waits for a foreground drive
(`the_wake_sweep_leaves_the_leave_for_the_first_full_advance`). Its drain of
what the engine still holds buffered stops at the wake's deadline. The resume is not on the one call the app already makes at the right
moments, the KeyPackage tick, for the same reason: that call is also folded
into the iOS background burst, and a background burst publishes no commit: it
would open a publish-before-apply window the OS may end mid-flight. The
driven sweep is for the foreground only, and so is a full resume: the
Android service's resume claims `false` and only finishes.

- **The live plane, and the one lifecycle that makes commits.** A live-sync
  session is in one of four lifecycles, and one value decides how its
  receive engine takes in what the engine hands it and how it drives what is
  stored (`Lifecycle::receives`, `Lifecycle::drives`):
  - *Launched* — started, and not yet claimed for: what every session is
    when its start returns. The core cannot tell a foreground launch from a
    background wake that cold-launched the process, and does not try: a
    session nobody has claimed the foreground for makes no commit and
    records nothing — and no number of unclaimed health ticks changes that.
    Its open-time advance of every circle is the engine's inputs-only one,
    and its receive takes in what it is handed in the mode that makes no
    commit (`Lifecycle::receives`): nothing stages an eviction a burst left
    due (`a_started_session_and_a_burst_make_nothing_of_a_departure`).
    So the claim's drive makes what is due, under a record — unless another
    member's eviction has been applied first, after which nobody here makes
    one. What is already stored it drives in the finish-only mode, once — its
    start asks for that one drive — and it arms no timer for another
    (`a_session_only_started_stages_nothing_at_its_open_and_the_claims_drive_makes_what_is_due`).
  - *Foreground* — entered only on a caller's claim that the app's
    lifecycle state reads `resumed`, carried by the call (`live_sync::Claim`)
    and inferred from nothing. The bridge makes it from the `foreground` flag of the entry
    it was called by, in one place (`foreground_claim`); the Dart layer fills
    that flag from one strict read — the app's lifecycle state is `resumed`
    (`appIsResumed`) — which answers no for a state that has not been set,
    for `inactive`, `hidden`, `paused` and `detached`, and where there is no
    binding. On Android `resumed` is "the activity is resumed AND its window
    has focus": a Haven window that is visible but unfocused (split-screen,
    freeform), or under the notification shade or a system dialog, reads
    `inactive` for as long as that lasts, and a session started then records
    and drives nothing — and no health tick runs — until the user touches
    Haven. Three entries take the claim, and a session's START is not one of
    them: a start runs for seconds (a connect wait, the open-time advance of
    every circle, every REQ), a claim read when it was asked would be acted
    on after the app may have left, and so a start always leaves its session
    *Launched*. The CLAIM itself (`claim_foreground`), which the app's
    service makes from a fresh read the moment its start holds the engine,
    and the heal makes again after every `resumed` event: it touches no REQ,
    and it promotes a *Launched* session only — never one a burst or a pause
    has put in the background. A session it promotes is served as the
    foreground's, once: a circle that can no longer move is named, and a
    drive is asked for, over the session's own sockets; a claim that
    promotes nothing does nothing. The claim itself waits for no relay: it
    holds the lock a pause and a stop take first, so the drive is made on its
    own task
    (`the_claim_that_puts_a_session_in_the_foreground_sends_what_the_poll_left_unsent`)
    — and a commit no relay acknowledged is not sent again before thirty seconds,
    doubling to an hour, however often the app is opened. A
    pause the app issues while `NostrSubscriptionService.start()` is in
    flight waits for that start, its claim included, and then pauses the
    session it produced. A stop ENDS the start: the engine's stop is issued
    at once on the handle the start has built, the start adopts nothing
    while a stop is in flight, a session that came up across the stop is
    stopped again, never adopted and never claimed for, and a stop that
    lands while the start is making its claim stops the session that start
    had adopted; in each case the start fails as ended by a stop, a type of
    its own, so nothing takes a running set from it and nothing counts it as
    a restart that failed. A second start, and a second stop, join the one
    in flight. On every branch whose pause stops the engine that stop is the
    pause's FIRST act: on Android with background sharing on it is issued
    ahead of the two platform writes that hand publishing to the foreground
    service, each of them guarded, so a write that is slow or throws costs
    the service a prompt start and never the stop. Nor does a start issued
    BEHIND a pause bring a session up where that pause stopped the engine: the
    app's
    one `start()` (`LiveSyncResubscriber._fullRestart`) reads whether a
    session is wanted immediately before and after it
    (`MapShell.liveSyncWanted`: not while the lifecycle reads `detached`,
    and not while it reads `paused` on a branch whose pause stops the engine
    — Android always, iOS with background sharing off), so a heal not yet
    at `start()`, a full restart between its stop and its start and a delta
    that falls back to one all start nothing, and the heal timer is never
    armed while the app is away: it is cancelled by a pause, by a detach and
    at dispose; a heal that completes behind that cancel arms nothing; and
    it is armed only by a `resumed` dispatch and, at a mount, only if the
    app reads `resumed` at that instant — a process the operating system
    relaunched in the background mounts under `detached`, `inactive` or
    `paused` and arms none there (the `resumed` the framework synthesises on
    the way out of its seed is P4 residual 12). Only a restart that was
    attempted and failed lengthens its interval. On iOS with
    background sharing on the pause keeps its session, and a start issued
    there from the background is not refused, only ever *Launched*. One is
    made on purpose: where the consent that makes this process the receiver
    resolves after a pause that had read it off and stopped the engine, the
    session is started behind that pause's stop, however long the stop
    takes, and the burst, or the idle close, that pauses it is chained
    behind the start. That edge joins the stop the pause issued and issues
    none: on a pause that kept its session a consent that flaps stops
    nothing and starts nothing. A
    session that DIES there between bursts is not started again by a timer:
    none is armed there. The next burst finds none — read from the typed
    lifecycle, never from an error — and starts one directly into itself
    (decision 190; `LiveSyncFfi::start_session_into_burst`, a session in the
    burst lifecycle from before its first REQ, counted as a burst, its inbox
    REQ on the start's lookback,
    `a_session_started_into_a_burst_reads_as_one_and_keeps_the_starts_inbox_lookback`),
    with the circles and inbox relays a foreground start takes, once the
    background-sharing consent has loaded, where a live session is wanted
    and the burst still owns the wake; it then waits out the backlog and
    pauses as any burst does. A burst that cannot start one publishes nothing
    (nothing is sealed before a receive has run) and reports it to the
    sharing-health model as a failed open, which raises the existing
    lost-subscription fault (`background_burst_coordinator_test.dart`); one
    the foreground took back, or whose consent was withdrawn, meanwhile,
    reports nothing. A burst's drives, and a start's, are bounded by the
    burst's own links (`burstBound`: connect, backlog wait, publish window,
    the publish pass and its stagger), the one deadline the path has while
    the keep-alive session is armed; the settle and the pause's Rule-13
    drain follow those links and are bounded by neither.
    `MapShell`'s own pause and resume handlers are not mounted host-side:
    which of these each branch reaches is pinned from the source and
    exercised on the device lanes only. Each stops after every await once a
    later pause or resume has been dispatched — a count of those two
    dispatches, not a read of the lifecycle, so a pause the user has
    returned from releases and announces nothing even where the window has
    since lost focus. A FOREGROUND OPEN (the app's
    resume, the user's own repair), refused outright without the claim. And
    the HEALTH TICK, which with the claim promotes a started session and
    asks for a drive, and without it changes no lifecycle, asks for no
    drive, re-issues only the
    REQ of each repair key that is due — the endpoints that went quiet, and
    with them a relay-closed inbox key due at that instant — and where the
    whole-session repair was due says so
    (`HealthAction::AwaitingForeground`) instead of making it. Nothing else
    writes this lifecycle: the processor's writers, and its drive, are
    callable from the session alone in a shipped build, and each is counted
    across every source tree
    (`the_live_planes_foreground_is_the_one_product_driver_and_the_open_repairs_a_removal_only`,
    `the_foreground_is_claimed_through_the_bridge_alone`). The core still
    cannot see the screen; what the claim is worth is that it is made from
    that one read and nowhere else. Here every commit and proposal
    the ingest or an advance surfaces is recorded as a durable fanout in the
    hold that staged it (`process_event_staging`, `advance_for_drive`), and a
    task of its own — never the ingest worker, which waits on no relay —
    drives every stored record that has something due
    (`Publishing::resume`).
  - *Burst* — a background burst, from its open to the pause that ends it.
    It makes no commit: what it receives is taken in by the engine's
    inputs-only advance, which stages nothing, so the eviction of a member
    who left comes due and stays due — until a full advance of that circle
    is made, which the first foreground drive makes under a record, or
    until another member's eviction is applied;
    a queued change of the group that holds the circle at its epoch is
    retired, its circle told, and where that change removed a member the
    circle's sends — every call's, a claimed foreground's included — are
    held while that member is still listed and the note unacknowledged
    (above). A
    location asked for meanwhile is not sealed while an
    eviction is due AND a proposal made for the circle's epoch still stands
    — it is answered deferred, typed
    (`SendHeld::DepartureDue`) — and the engine's own commit such a hold
    stages anyway is undone in that hold. A proposal, not "the leave": the
    read is MDK's own re-arm test, which does not tell a leave from another
    kind, so beside a timer the engine left stale a proposal of another kind
    holds a send with no departure behind it; that hold ends when the epoch
    moves or a full advance prunes the timer, and a store that cannot say is
    read as one in which a departure stands. Only rows still unresolved
    are read — not the `Processed` state, where MDK leaves only a proposal
    a commit has consumed and where every location ends — so no number of
    a busy circle's locations, nor an outsider's junk on its routing tag,
    holds a send
    (`a_busy_circles_locations_hold_no_background_send_behind_a_committed_departure`,
    `an_outsiders_flood_on_the_routing_tag_holds_no_background_send`).
    The engine's timer alone holds
    nothing: MDK keeps it in memory and does not drop it when another
    member's eviction is applied, so once that commit has consumed the leave
    the next background send SEALS, at the new epoch and not for the member
    who left
    (`a_departure_another_member_has_committed_holds_no_background_send`;
    tracker T-STALE-DEPARTURE-TIMER). A receive plane's advance beside a
    burst or a pause is the engine's inputs-only one: no eviction is staged
    there, and the user's own leave is not minted again for a sweep to
    publish from the background
    (`the_wake_sweep_leaves_the_leave_for_the_first_full_advance`).
    What the hold does NOT cover: another isolate with its own
    `CircleManager` over the same database (the Android service, a
    background worker) and the poll configuration, each of which drives in
    the mode its own caller names. The hold is the newest live
    plane's to set: a plane let go late cannot lower the hold of the burst
    that replaced it
    (`a_plane_let_go_late_does_not_lower_the_hold_of_the_burst_that_replaced_it`).
    What is stored it drives in the finish-only mode.
  - *Background* — a pause, a stop: no REQ and no socket. It receives what
    is still in flight as a burst does, and drives nothing.
  A drive is asked for when the worker has staged something, wherever a
  caller claims the foreground — the claim behind a start or a heal when it
  promotes, a foreground open, a claimed health tick — and once at a
  session's start and at a background burst's open, each of which only
  finishes; and, in the foreground and inside a burst only, the drive task
  wakes itself when the last drive's own hint falls due — a session only
  started runs the one drive its start asks for and sleeps on nothing;
  elsewhere a relay that did not answer is called again when its schedule
  allows, not at the plane's next periodic wake
  (`EngineProcessor::drive_due_again`; never sooner than five seconds, and
  never on a hint of zero, which says the pass ran out of its own budget). A
  drive that finds nothing due takes no relay and so dials nothing. In the
  full mode a drive also gives the engine's full advance to each circle whose
  eviction of a member who left is due and not made — a burst or a pause
  left it so, or the wait a refusal earned is over
  (`SessionManager::evictions_left_due`): nothing else stages it for
  a device that is not sending. It does so only once the circle is caught
  up in this session — a catch-up sweep's top-down pass answered to the end
  (a relay drained, every other drained or given up on) with nothing it
  fetched held back, or every relay of the live plane's subscription sent
  its end of stored events — with no convergence input unresolved and the
  departure still standing — the live plane's come-back after an open, which
  takes up an advance a drain handed back, is inputs only and stages none
  (`a_come_back_after_an_open_stages_no_eviction_even_in_the_foreground`);
  the live plane asks for a drive when every relay of a subscription has
  sent its end of stored events, so the foreground makes it then
  (`a_self_remove_auto_commit_is_not_made_by_a_burst_and_is_made_by_the_foreground`)
  (`SessionManager::may_stage_left_due`;
  `an_eviction_left_due_is_staged_only_once_its_circle_is_caught_up`,
  `a_sweep_that_held_an_event_back_leaves_its_circle_not_caught_up`). The
  mark is forgotten when the live plane pauses or stops
  (`the_live_planes_end_of_stored_events_leaves_its_circle_caught_up`), when
  it issues the circle's REQ again — a re-anchor, a reconnect's repair, a
  change of the circle's relays — until that REQ's own end of stored events
  (`a_req_issued_again_forgets_the_mark_until_its_own_end_of_stored_events`),
  and when a sweep of the circle begins
  (`a_sweep_answered_to_the_end_leaves_its_circle_caught_up`); a circle store
  that cannot say which circle a sweep means forgets every mark. The same
  mark gates the re-issue and re-queue below.
  Duplicate removals of one departure are adjudicated by convergence
  (Marmot `member-departure.md` 73-75); this is the stronger form of the
  spec's re-check before committing (68-71), so that the device does not
  commit a departure from an epoch it has not caught up with. Its limits:
  one relay that drains is enough; a relay that withholds and answers its
  end of stored events empty makes the circle look caught up; a future-epoch
  commit parked `TransportDeferred` and stranded rows do not hold the mark
  back; on the live plane a relay counts toward the mark only if it was
  connected when it accepted the circle's REQ, and one that never sends its
  end of stored events is left out after `EOSE_WAIT` (five seconds) — at a
  burst's backlog wait, in the foreground on the repair task's timer
  (`the_foreground_releases_a_silent_relay_after_the_eose_wait_without_a_tick`)
  or at a health tick — while one relay's re-issue leaves its REQ's other
  relays owing what they owed
  (`a_single_relays_reissue_keeps_the_buckets_other_relays_in_coverage`); either
  is recorded as owing the circle its history from the `since` it was asked
  (`relay_floors`), the next REQ to it asks from there, and its answer to
  the end of such a REQ ends the debt, so a dead or silent relay delays the
  mark and the cursor advance by at most that wait and the circle loses
  nothing that relay held (Security Rule 12;
  `a_relay_left_out_of_coverage_is_asked_from_its_floor_by_the_next_session`).
  A rotation onto a routing id drops the floors still owed to that id, whose
  sync state starts over from the cursor the rotation sets. A pause forgets
  what every REQ still owed, so nothing a closed REQ owed marks a circle
  caught up while a resume connects, before that circle's own REQ is out
  (`nothing_a_req_owed_at_a_pause_is_released_after_it`).
  A dropped relay no longer re-anchors the session at a health tick: the
  pool retries it alone on its own schedule, a REQ the pool refused for a
  relay that is down is no shortfall and is re-issued alone when the relay
  reconnects — a group REQ from the floor, and the inbox REQ when the last
  open issued it (`a_req_refused_for_a_relay_that_is_down_re_anchors_nothing`,
  `a_relay_that_reconnects_has_its_unheld_reqs_re_issued_alone`,
  `a_relay_that_reconnects_has_its_unheld_inbox_req_re_issued_alone`), a re-issue
  is not opened to a relay that is down, and a burst's backlog wait waits
  on no relay, group or inbox, that was not connected when it took the REQ
  (`tooling/soak` S25 grades all of this over real relays); a flood of events the sweep holds back
  can keep a circle from ever being caught up, and the eviction then waits;
  and the live plane does not read its own intake drops or skipped
  notifications for the mark. Nobody gains read access by any of these: a
  send's preflight and the finish-only departure hold are not on the gate,
  and MDK's own host stages on its timer (`message_processor/mod.rs`
  1785-1791) — this is Haven's local policy, not an MDK gap. A full drive that finds such a wait still
  running reports what is left of it, never under five seconds, so the drive
  task wakes when it ends (`SessionManager::restage_due_after_ms`). What it
  hands back is all
  read: locations a resolution replayed are already stored and stamped as
  arrived by the fold, and go onto the bus as an ingested one does; what
  became of a change is in its circle's durable notes; when there is next
  something to do is kept (`EngineProcessor::drive_retry_after_ms`) and is
  what the drive task sleeps on. A change the user queued is
  given its one attempt by the same drive, and by the ingest of any event
  that arrives behind it (below).
  The session sends a recorded event through a publish pool of its own — a
  `RelayManager` the bridge builds with the session, never the engine client
  and never the pool Dart publishes through, which Dart shuts down and drops
  at every background transition. It carries the driver's sends and nothing
  of anybody else's: recorded commits and proposals, and — only while the
  pass is in the full mode — a Welcome from its delivery record, to its
  invitee's inbox relays, and a proposal no record could be written for. So the
  session can close it wherever it cuts its own radio without cutting
  anybody else's commit between its send and its relay's answer. One
  `disconnect()` closes it for good only because every publish relay is
  registered with reconnection off (`publish_relay_options`).
  *The foreground ends without notice.* The lifecycle flips first, and from
  that moment a pass that began in the foreground READS the finish-only mode
  and goes on reading it whatever the lifecycle becomes: its leash only
  narrows, and one taken outside the foreground never reads the full mode at
  all (`live_sync::drive::Leash`; the drive builds its leash before it reads
  anything else). The same holds for a burst's pass when the burst is
  paused and a started session's when it is claimed: a pass belongs to the
  stretch of the lifecycle it began in, and once that has changed it has no
  budget left for anything it had not begun (`ModeSource::stands`). What the
  engine was already ASKED for runs to its end. A confirm under way at the
  flip completes with its fold, which can record a commit and end the
  record. A publish of something that has no record, already handed to its
  publisher, runs out that publisher's own retries — three attempts,
  forty-nine seconds at most (`PUBLISH_LADDER_MS`). From the flip it decides
  nothing new, and does nothing it had decided and not begun: a pass reads
  its mode, decides, and then waits for the engine — for as long as whatever
  holds it takes, a whole hand-back of stranded input included — so each act
  that may not outlive its lifecycle is asked for again with the engine held
  (`relay::fanout::Still`): a rollback, the bound, a confirm, a Welcome's
  hand-over and a full advance decided before that wait are not made once
  the lifecycle has changed in it, and the record stays exactly as it is
  stored; a send, a leave and an ingest are made in the mode that makes no
  commit, and a send a due departure holds in that mode is held
  (`an_act_decided_before_the_foreground_ended_is_not_made_once_the_engine_is_had`,
  `a_welcome_is_not_handed_over_once_the_engine_is_had_after_the_foreground_ended`,
  `a_pause_that_lands_while_an_event_waits_for_the_engine_stages_nothing`,
  `a_send_whose_foreground_ends_in_its_hand_back_is_held_for_a_due_departure`,
  `a_leave_whose_foreground_ends_in_its_hand_back_records_no_eviction`,
  `an_ingest_whose_foreground_ends_in_its_hand_back_records_no_commit`).
  It takes no further relay, for a recorded event or through the publisher
  of what has
  none, and one it was waiting for is given back uncalled. A relay it
  already held is not used for a record's FIRST send: the mode is read again
  after the relays are taken and again where the attempt is marked, so
  nothing is marked as begun for a commit no relay has been sent
  (`send_what_is_due`); a record a relay may already hold is sent again to a
  relay already held that was attempted before, as the finish-only mode
  sends it. It makes no queued
  change, begins no publish, confirms nothing, rolls nothing back and
  applies no bound; a proposal a hold hands back after the flip is not kept
  for a later foreground; and a Welcome whose send was not begun stays in
  its record for the next full drive. It stores the answers of the calls it
  has out; an acknowledgement among them stays on its record, and the next
  pass that begins — a burst's, a started session's, the foreground's —
  confirms it without calling a relay. A background burst
  opened over a running pass does not wait for it: it meets a pass that can
  decide nothing a burst must not. The pause counts the drive on the same
  in-flight count it waits on for any publish and waits for what the pass
  has out — one call of MDK's relay client, twenty seconds at most, when the
  pass was sending a record; the rest of a confirm's fold or of a
  publisher's retries when the flip found it inside one — and only then cuts
  the radio and closes the drive pool. A stop does not wait: the call under
  way is given up and stored as what it is, an attempt that never returned,
  possibly exposed. If the system suspends or kills the process
  instead, the attempt stays stored as begun and the next drive records it
  possibly exposed before it sends again. A burst whose opener hands over
  the OS budget it measured (`LiveSyncFfi::open_background_burst_within`,
  `start_session_into_burst`) ends every drive pass of the burst by that budget's
  end, so it begins no relay call it has not the room to finish
  (`a_bursts_drive_begins_no_call_its_measured_budget_cannot_finish`,
  `a_burst_opened_within_a_measured_budget_hands_it_to_its_drive`,
  `a_session_started_into_a_burst_within_a_measured_budget_hands_it_to_its_drive`).
  The budget is measured from the call and set under the lifecycle lock as
  the burst is entered, so a pause that had the lock first cannot clear it
  (`a_bursts_measured_budget_survives_a_pause_that_had_the_lock_first`); and
  the end is kept on the monotonic clock beside the wall one, each pass
  taking the earlier, so a wall clock set back during the burst gives no pass
  more room (`a_bursts_measured_end_is_not_stretched_by_a_clock_set_back`).
  Within one pass the wall clock still decides: a step back while a pass
  runs stretches that pass by the step;
  the app's iOS burst calls both, with the budget it measured
  (`burstBound`), and a burst opened the old way has the pass's own budget,
  two rows.
  *What it costs.* A circle with a commit awaiting its relays when the app
  goes to the background is driven from the background in the finish-only
  mode only: each burst's drive sends the same bytes to a relay that was
  attempted before and is due — a commit no relay may hold is not sent from
  the background at all — and a relay's acknowledgement is confirmed there.
  Until then the circle
  does not share from the background: each
  background send for it is answered with the typed deferral and an empty
  hand-back, the queued fix is discarded, nothing is retried in a loop and
  nothing names the circle in a log
  (`a_location_send_for_a_circle_awaiting_its_relay_is_deferred_typed_and_touches_nothing`).
  The user is told what any deferred send tells them — the sharing-health
  model's deferred-send verdict, or from the background the missing publish
  acknowledgement it reads at the next foreground open — and nothing says a
  commit is awaiting its relays. The deferral's `repaired` field reads true
  for such a circle (no stored input gates it; its own pending commit does),
  so nothing may key on it.
  A session's start claims nothing; the app claims for it the moment the
  start has returned, from a fresh read (`NostrSubscriptionService`). Every
  Android return to the foreground starts a session, and so does every iOS
  one with background sharing off; if the app's lifecycle still reads
  `resumed` when that start returns, the session is in the foreground and
  its first drive has been asked for: a record left pending when the app
  went to the background is driven at the next visit that outlasts the
  session's start, on its relays' own schedule and no faster
  (`a_claim_behind_a_start_drives_a_stored_due_record_at_once`,
  `a_silent_relay_is_called_on_its_schedule_however_often_the_app_is_opened`).
  A visit that ends while the start is still in flight claims nothing: the
  stop it issues ends that start, and the pause it issues instead on iOS
  with background sharing on waits for the start and then pauses the session
  it produced. A session whose start returns while the app is NOT
  resumed — a launch behind a system dialog, a return through the app
  switcher, a process the operating system launched in the background, on
  Android a window that is visible but unfocused — stays *Launched* until
  the heal the next `resumed` event runs, which claims for it behind any
  start still in flight; a process whose lifecycle never reads `resumed`
  is never claimed. The claim that promotes a session asks for a drive,
  once, as a foreground open does: on Android a return to the foreground is a
  fresh start and this claim, never a foreground open. A circle MDK halted is
  read as such by every circle read, from MDK's persisted `unrecoverable`
  (`CircleEngineState::Unrecoverable`,
  `an_unrecoverable_circle_reads_as_such_from_the_open_by_its_pseudonymous_id`),
  so nothing has to be announced at the claim. A live session's open-time advance of every circle runs before any
  claim and is the inputs-only one: it releases nothing, and what is due is
  made by the claim's drive, under a record — unless another member's
  eviction is applied first. Where the catch-up sweep is the
  first plane to run in a session, that advance is the sweep's, in the mode
  that only finishes. Every path that is not a circle's record's own drive
  leaves a circle holding a record as it found it — the sweep every wake
  runs, a burst's ingest, a location send
  (`haven-core/tests/live_plane_drive_e2e.rs`).

- **Staged where it is committed.** A session call made in staging mode
  (`SessionManager::send_staging` and the calls built on it,
  `advance_for_drive`, `process_event_staging`, and the driver's own confirm
  and rollback) writes MDK's `OutboundFanout` for every commit and every bare
  proposal the engine hands back before it releases the session lock, and
  returns the row's handle instead of the commit — after a confirm or a
  rollback that FAILED too: what the engine had already emitted is drained and
  recorded in that same hold. A commit whose row cannot be written is rolled
  back in the hold, and so is one with no relay to go to. One that can be
  neither recorded nor rolled back is NOT published — nothing without a row
  leaves the device — and stays staged, holding its circle's sends:
  its author is answered "staged with no record", never "failed", the circle
  keeps a note, and the rollback is tried again at the next staging hold,
  which is safe because nothing was sent. Whether a rollback happened is read
  from the engine's state, not from the call: one that errored after its
  rewind landed is a rollback, its commit is not kept as staged, and what the
  failed call had emitted is taken in the same hold. If the process dies
  first, the next open gives an admin's own removal its row and lets MDK
  clear anything else. A call not made in staging mode — a receive plane
  that does not stage, a legacy leave — makes no commit of the engine's own:
  what it stages is rolled back in its hold, unsent. Beside a
  pending row the engine no longer holds a commit for, a group change is
  refused before the engine is asked, and a commit a receive call staged —
  or the eviction a location send's or a leave's own preflight staged — is
  rolled back in its hold. The same hold undoes an eviction the engine staged
  while its circle is waiting out a refusal (below): the wait binds every
  hold that can stage, not only a staging-mode one.
- **A commit a kill left staged with no row.** What MDK's hydrate does with
  it depends on what it is, and so does what Haven may safely add (each
  measured against the real engine):
  - *An admin's own removal* is left attached with no pending ref, after
    which every convergence pass of the circle fails on that device — sends,
    receives and a peer's commit included. The circle is dead there with or
    without a row, so before the engine opens Haven gives the one unresolved
    removal the user asked for a trial row from its stored signed event, and
    the engine restores it like any staged commit. Whoever staged it without
    a row may have published it before the process died, so the row records
    every relay as one that MAY hold the commit and has not yet answered: a
    relay that holds it answers that it already has it and the commit is
    confirmed; no refusal and no bound ever rolls it back; each relay is
    asked before the row can end; and the circle's mark for "removes nobody"
    is cleared before the row is written. The live plane's foreground drive
    sends it: in the live-sync configuration from the first claim of the
    foreground its session is given — its start, in a resumed app — and in
    the poll configuration the bridge's resume on the foreground health tick
    does (`resume_driven`, on the tick's claim).
    Until then a repaired removal sits restored and unsent — where MDK would
    have left it attached and unsent.
  - *The eviction of a member who left* is left attached too, but the circle
    reads stable, and the eviction another remaining member commits for the
    same departure is applied on this device and ends the state. A row would
    turn that into a pending commit with that very commit held unread behind
    it until a drive resolved it — and a drive in the full mode exists only
    in a claimed foreground, which a device only ever in the background never
    has — so an eviction is given NO row until every device has a foreground
    drive
    (`an_eviction_a_kill_left_with_no_record_is_healed_by_another_members_commit`).
    If this device is the only remaining member, nothing heals it.
  - *Anything else* — an invite, a relay change, a hand-over, a step-down, a
    repair — is CLEARED by MDK and announced, its stored row left as sent.
    Left there, that row is a convergence input the circle's next pass
    applies on this device ALONE, with no relay's acknowledgement — what
    Security Rule 13 exists to prevent. Since W9q every commit is staged
    under its record in the hold that staged it, so one hydrate clears had
    none and never left the device: the open retires its row before the
    session's first engine call (`cleared_at_open`; a row a record still
    names may be held by a relay, and stays), so no pass applies it (tracker
    T-KILL-WINDOW; `a_commit_cleared_at_open_is_retired_and_never_merged`).
    The circle is told the change was undone: noted from what is stored, in
    the pass before the open, so a process that ends before the engine's own
    one-time announcement is collected has still said so, and again when
    that announcement is. Both writes are best-effort. The repair and the
    product's drives change
    together, and a source gate fails when anything of the driver is named
    in a file outside its list — the driver, the catch-up plane, the live
    plane's drive, the relay manager, the bridge's driven entries and the
    soak rig — or more of it than the list allows there, or when the
    repair's coverage changes
    (`the_live_planes_foreground_is_the_one_product_driver_and_the_open_repairs_a_removal_only`).
  - *A removal killed INSIDE the engine's staging call*, before the commit's
    own row was written, leaves nothing to find. For an admin's own removal
    the circle shares as before, the removal not having happened, and the
    next change asked of it is refused once while the engine clears the
    leftover. For an eviction it is worse: the leaver's proposal stays in
    OpenMLS's store, which then refuses to seal anything; the engine never
    stages the eviction again; and nothing stored names the state. The
    circle reads healthy and CANNOT SHARE from this device until a commit of
    that circle is applied here — another member's eviction, or a change
    this device's admin makes, which commits the departure with it by
    reference. Haven says so at the send that fails, typed
    (`CircleError::SendBlockedByDeparture`), and does not mark a change made
    over such a leftover as one a day without relays may undo. In a build
    with debug assertions a second attempt to remove the member who left
    panics inside OpenMLS there; a release build drops the removal and
    commits the departure (tracker T-KILL-WINDOW).
  Not repaired, and said in the log where the store shows it: a circle with
  more than one unresolved commit of its own, and a circle whose routing
  names no relay Haven may dial. A
  trial the engine did not adopt is taken back with its commit's row left as
  found, and a row frozen for no relay is never rolled back.
- **A change the engine queued.** A removal, an invite or a relay change
  asked for while a circle is still settling is queued by the engine and
  answered as queued: nothing has changed yet, so a queued removal's member
  stays in the member directory until the removal is applied — and then
  goes outright, after a restart too: the engine says who a commit removed
  only from memory it does not rebuild, so the driver's confirm reads the
  intent the engine keeps for the commit. A plane that
  drives releases it with MDK's full advance — only while the circle has no
  commit still pending — and records the commit in the hold that released it.
  In that hold every queued copy of the change is retired — the same change
  asked twice is queued twice — and again in the hold that confirms the
  commit, which covers a kill between the two writes and a row the open
  wrote: the engine deletes a queued change only through a link it keeps in
  memory, and a copy left behind would be made a second time (tracker
  T-QUEUED-INTENT-RESTORE). With the queue's copy goes the engine's own
  retry: a queued change every relay refuses is undone and its circle told,
  as a change asked for directly is.
  The engine prepares a queued change at every full advance with no word on
  when it was asked. One whose premise is gone fails the queue each time —
  everything queued behind it waits — and FIRES the day the premise returns.
  So before every full advance Haven itself initiates, the queue is checked
  against the roster and the admin set as the engine will meet it — up to and
  including the first change of the group that is KEPT, and no further: the
  engine prepares that one next and judges what follows against the circle
  it leaves, so an invite of somebody followed by their removal is a removal
  that can be made when its turn comes. A change is retired when it removes
  a member who is no longer in the circle or was asked by a device that is no
  longer an admin. Its circle is told FIRST — the note is the only other
  trace of what the user asked for — and a change whose note cannot be
  written stays queued; a member whose removal became moot
  is deleted from the directory. A member is called gone only while the
  roster the engine reports is the applied one: with a commit of this
  device's own left staged under no ref, the roster is that commit's. A
  removal that names several members is
  retired whole when one of them has gone, as the engine would refuse it
  whole: the others stay in the circle until they are removed again. A
  retirement the store refuses leaves the change queued and takes the note
  back; the next advance tries again. An invite, and a hand-over naming somebody
  who has left, are not judged — a choice, not a limit: who an invite names
  could be read from its KeyPackage, and a hand-over's from its own bytes —
  and stay queued: the full advance then fails, what it left is collected
  with the inputs-only advance, the circle is told its queue is held
  (best-effort, and only for an error that is not transient and that the
  engine did not swallow), and a commit
  that failed advance itself staged is rolled back in the hold. None of this
  holds back the eviction of a member who left where no reservation is in
  play: the engine then runs its own maintenance before it looks at the
  queue (measured); with a fairness slot it prepares a queued admin change
  first. What a queued change
  that cannot be made costs is the changes queued behind it: a removal there
  leaves its member reading the circle until that change is retired.
  A change an ADMIN queued is made at the epoch the device was at when its
  gate opened, ahead of anything the circle has committed since: while it is
  queued the engine applies nothing more it has received until the change
  has had its one attempt (the Marmot one-attempt reservation), and only the
  full advance makes that attempt. So a plane that drives cannot read the
  backlog first; a commit made this way after a long absence is a rival of
  whatever ended that epoch, the circle's branch selection keeps one of the
  two on every device, and when it is not this one the change is set aside
  though a relay acknowledged it — with its row already ended as applied; the
  next full drive once its circle is caught up hands it to MDK's re-issue,
  and what cannot be made again is said (T-REISSUE)
  (`a_queued_admin_change_is_made_ahead_of_the_backlog_as_a_rival_the_circle_adjudicates`).
  The same reservation is what a change LEFT queued meets on every plane that
  does not make the full advance, whose advance is inputs-only
  (`SessionManager::settle_inputs_for_drive`). Once the circle's convergence
  pass has closed, the engine opens no other until the queued change has had
  its one attempt, which such a plane cannot give it; so when input waits
  behind the change and no pass is open to take it up, the change is
  retired, its circle told first (`QueuedChangeDropped`, or
  `QueuedRemovalDropped` with the member it named kept as a target), and the
  advance made again: the device moves with its circle instead of sealing at
  an epoch the circle has left (measured:
  `a_change_left_queued_is_retired_and_told_when_a_commit_waits_behind_it_on_a_plane_that_does_not_drive`,
  `a_queued_removal_in_the_way_is_set_aside_and_told_by_the_catch_up_plane`).
  A change nothing waits behind is kept. What keeps a reservation from standing: the
  driver's entries — remove, add, relay change, hand-over, step-down —
  answer a change the engine queued as `Queued`, typed, and the live plane's
  foreground drive gives every circle that holds a queued
  change of the group the full advance, as does the ingest of any event that
  arrives behind one; the driver's poll entry does the same in the full
  mode. Two more things end one that is found standing. EVERY SESSION OPEN
  THAT HAS A STORE FOR ITS NOTES, in every configuration and before any
  advance, retires each change of a group it finds queued, its circle told
  first (`ChangeNote::QueuedChangeDropped`; a circle that cannot be told
  keeps its change, a change that could not be deleted is not said to have
  been, and a session with nowhere durable to keep a note retires none). It
  runs after the removal repair — a queued removal whose own commit was just
  given its record goes without a note, as does the copy of a change other
  than a removal that a confirmed commit of this device's already made (its
  intent is kept through the rewind horizon); a removal's copy is always said
  and its members held, since a member invited back since is removed by it
  anew, and one whose members are all gone takes its note back at the open
  by itself (`a_queued_change_whose_commit_was_confirmed_is_not_told_as_dropped`,
  `a_queued_removal_of_a_member_invited_back_is_told_and_held_not_dropped`).
  The residual, accepted: an identical admin or profile change the user asked
  again inside the horizon after a kill is retired without a word, as the
  twin of the one made. A failure of either does not
  stop the other: no product path leaves one
  queued on purpose, so one found there is what a take-back the store
  refused, or a process that died between the engine's queue write and the
  take-back, left behind an answer that said "not made"
  (`retire_queued_group_changes`, `no_product_path_leaves_a_group_change_queued`).
  And A SEND-ONLY CALL, which can never make the full advance, retires a
  queued change at the moment it is what holds the circle still — input
  waiting, no pass open to take it up — with the same note, and not before
  (`SessionManager::settle_inputs_for_drive`). That test never answers yes
  because the store could not be read, and it can answer no for a circle
  that IS held: the engine also reports a pass as due while canonical
  applications are pending, and a circle the reservation holds can be in
  that state, so its change stays queued and the circle stays at its epoch.
  A take-back the store refuses
  is told to its circle durably (`ChangeNote::QueuedChangesHeld`) as well as
  logged by kind. What can still hold a reservation within one session: that
  refused take-back, until the next open or the next full advance, on a
  plane that makes none — a session nobody has claimed the foreground for
  and the wake sweep (a background burst and a pause retire the change
  instead, their circle told); a change queued through the driver's own
  entries, which answer "queued"; and a change MDK's re-issue queued again
  that its drive did not stage (`WithdrawnOutcome::Queued`).
- **A proposal.** A plane that drives records a bare proposal — the user's
  own leave, which the engine mints again for each epoch the circle reaches
  and hands back once — as a fanout with nothing to confirm, frozen for the
  circle's relays in the hold that minted it, and sends the same bytes until
  `min(2, n)` relays hold them, a day has passed, or nothing can act on them
  any more. A leave is an offer made for one epoch by a member: once the
  circle has left that epoch — which is also what a leave proposed again for
  the next epoch means — or this device's copy of the circle is marked
  removed, its record makes no further call and goes as a finished one does,
  when that changes no relay's wait. A relay that accepts the socket and
  answers nothing is therefore not shown, again and again for a day, the
  address of somebody who has already gone. A proposal's circle is found by
  the id its event is addressed to, and it is recorded only when exactly one
  live circle answers to that id; otherwise it is published once with no
  record, as a plane that records nothing publishes one — to the relays of
  the FIRST stored circle row with that routing id, live or not: the column is
  not unique, so a circle made to share another's routing id can pull a leave
  to the other's relays. Two rules keep a proposal
  from costing a commit its relay: a proposal's first call waits for the
  relay like any later one — a leave is proposed again at every epoch, and
  any member can move the epoch — and when a relay's wait is over its one
  call goes, within ONE circle, to a commit's record before a proposal's.
  Across circles it goes to whichever record the relay was called for least
  recently, so a commit one circle cannot get a relay to take never keeps
  another circle's leave from that relay. Within a circle nothing
  recorded after a commit that is still pending is sent before that commit is
  resolved. A plane that does not stage publishes a proposal once, with no
  record, in the full mode only.
- **Targets.** The row is frozen for the group's routing component as the
  engine reads it after it returned the commit: the relays of the epoch the
  commit leaves, with every entry Haven may not dial left out. It asks for
  `min(2, n)` acknowledgements, counting distinct relays.
- **Confirm, roll back, or leave.** Confirmed on a relay's acknowledgement
  and never before. Rolled back only when every frozen target is terminal,
  none accepted, and the record's exposure flag is clear — the flag, which
  outlives a later refusal, not the targets' statuses. Anything else is left
  staged. What happened is read from the stored ROW, never from the engine
  call's result: a rollback whose rewind was stored retires the commit's own
  row even when the call then failed. While that row cannot be retired no
  engine call that can run a convergence pass is made at all, for any circle:
  every send, ingest, advance, confirm and rollback takes the
  session through one accessor, which finishes every unfinished rollback
  first and refuses the call when it cannot — the open's own hydrate does
  not go through it; the pass before the open finishes what was stored, and
  a session opened after that pass failed is owed its finish — a convergence
  pass would
  otherwise merge a commit every relay refused (tracker
  T-ROLLBACK-RESURRECT). That covers the driver's rollbacks, by their stored
  row, and the plain rollback of a commit that had no row — the one a hold
  that records nothing makes of what it staged — whose commit the session
  remembers from BEFORE its rewind until its row is retired, so a rollback
  whose caller drops it after the rewind landed is finished by the next
  engine call, and one dropped before it rewound
  anything leaves a commit that is still staged and a row nothing retires; a
  process that dies first leaves that row as
  the interrupted change above. The session's lock is private to the module
  that holds the accessor (`nostr::mls::engine_gate`), so the compiler, not a
  convention, keeps every other path from a mutable session. The refusal is
  typed (`NostrError::EngineHeld`, `CircleError::EngineHeld`); what was being
  ingested is held, not dropped. The same store is needed to write the note
  that says a commit was undone, so the engine is held while that note
  cannot be written too.
- **A confirm that fails is never a failed publish.** The engine merges the
  commit and stores the row as confirmed in one transaction, and can fail
  before it, between it and leaving `PendingPublish`, and after. The error
  does not say which. So the driver never rolls back on it; asks again in the
  same call only when the store was busy, four times at most (MDK's host's
  rule); hands back what the failed call had already emitted beside the error;
  and the next drive reads the stored row: still pending with its
  acknowledgement — confirmed, no relay written to; confirmed with the engine
  still holding the commit — finished with the plain confirm, in the same
  session; confirmed and nothing held — applied. While the engine still holds
  a confirmed commit, every other resolver handed its ref is refused: a plain
  rollback there would rewind the engine under a commit the store has applied
  (tracker T-CONFIRM-ERR).
- **One sender, one call, every outcome stored.** An event that has a row is
  refused by every other publish path of every relay manager in the process,
  and by the live plane's publisher on the engine's own pool
  (`relay::fanout::is_owned`). The registry is filled from the store before
  the engine opens — every stored row, a quarantined group's included — so
  nothing of a new process can publish before it. One drive per row at a
  time; one fanout call per relay at a time, chosen under the session lock,
  and none beside a plain publish to that relay (the relay's gate on the
  publish pool, which `publish_event` also takes): a fanout call that ends
  ambiguously makes MDK's client disconnect the relay, which a plain publish
  in flight would read as its own failure. A target is
  stored `Attempting` before its call and resolved after it, and one found
  `Attempting` — the process died, or the drive was dropped — is stored
  possibly exposed before it is tried again. Two frozen spellings of one relay
  are one call and one answer.
- **One row per circle, bound to its own commit.** MDK's hydrate restores a
  pending commit from a group's first pending row without matching the two,
  and a pending ref is a number that starts over with every session. So before
  the engine opens a rollback an earlier process stored is finished and a row
  that no longer describes its group's staged commit stops being pending:
  deleted, or — when its commit ended applied on this device — kept as
  confirmed for the relays it still owes; a group change is refused, and a
  receive plane's commit rolled back, beside a pending row; a row is matched
  to the engine's commit by its
  origin message as well as its ref; and the session's own resolvers refuse a
  commit that has a row (`NostrError::FanoutOwned`, `CircleError::FanoutOwned`).
  A row with nothing staged behind it and nothing ever sent under it is
  abandoned with its commit's row retired; one an attempt was begun under is
  kept, and its circle takes no new change beside it until the engine's own
  convergence disposes of the commit — at the first deadline any plane serves
  — and the next drive settles the row. If that pass merges the commit, what
  this device then seals is under an epoch its peers have only if a relay
  really took it (tracker T-STALE-FANOUT).
- **Across a restart.** A commit staged with its row is restored by MDK's
  hydrate and the driver sends the row's frozen event again, byte for byte —
  never a commit staged a second time.
- **How often a relay is sent to.** One drive makes at most one call per
  relay and retries nothing itself; it waits for every relay it called to
  answer (MDK's client gives up on one after twenty seconds) and, once the
  commit is resolved, for the engine's own deadlines while what the resolution
  released is folded. A relay that did not accept is sent the event again only
  when it is due: paced per relay across every row that owes it — thirty
  seconds doubling to an hour after an unproven answer, five seconds for the
  first three calls that could not reach it and then the same doubling, at
  least a minute doubling to an hour after a `rate-limited:` — so at most ten
  calls in the hour after its first failure and one an hour after that.
  Driven minute by minute with two circles' commits waiting on one relay,
  that relay is called ten times in its first hour when it cannot be reached
  and six times when it rate-limits, each commit's own first call included,
  and once an hour after
  (`an_unreachable_relay_two_commits_wait_on_is_called_on_one_schedule_minute_by_minute`,
  `a_rate_limiting_relay_two_commits_wait_on_is_called_on_one_schedule_minute_by_minute`).
  Four things add to that schedule, one call each: a commit newly staged
  meanwhile, which calls its soonest relay on its first drive so that a new
  removal is not held behind another commit's back-off; an older row a relay
  still owes when it acknowledges a newer one, which follows in the same
  pass; a stored attempt that lies ahead of the clock — a clock stepped back
  — whose own record is due at once and is stamped again by that call, while
  no other record reads it; and a relay
  that could not be reached, when the live plane sees the network come back
  (`EngineProcessor::network_back` calling `wake_unreachable`): a relay
  dropping while live — never a pause's deliberate termination — that leaves
  the pool, as it stands at that moment, with no relay up, then a relay back;
  at most once in `NETWORK_BACK_FLOOR_MS` (60 s) on the driver's clock, only
  in the foreground or a burst, so a flapping network calls each such relay
  at most once a minute. No timer, wake, REQ or poll is added: the repair
  task's existing notification carries it, and a drive is asked for. A row that has ended keeps counting against its
  relays until its going changes none of their waits — but only its calls
  since the relay last acknowledged anything: what failed before a relay's
  latest acknowledgement is not counted against it. A terminal answer ends
  a target for good. A commit every relay refused that the engine stages
  again by itself — the eviction of a member who left — is staged after a
  wait that doubles from one minute to an hour: the original and five more
  in the first hour (minutes 1, 3, 7, 15, 31), then 63, 123 and hourly, one
  call of MDK's relay client per relay each. That is a ceiling. A full drive
  stages the eviction again at the first drive at or after the wait's end,
  and one that finds the wait still running reports what is left of it, so
  in the foreground the drive task wakes on those minutes; no other path,
  and no device in the background, stages it sooner
  (`a_full_drive_stages_a_refused_eviction_again_when_its_wait_is_over_and_never_before`,
  `a_full_drive_says_when_a_refused_evictions_wait_is_over_and_the_live_plane_wakes_for_it`).
  What a relay that goes on refusing is sent is a NEW commit event each
  time, under the same routing tag.
  The wait is kept with
  the circle, in the encrypted circle store, so a run of short sessions does
  not each stage and send one; a stored wait that lies further ahead of the
  clock than the longest wait — a clock stepped back — is over. It binds
  every hold that can stage the eviction, not only a staging-mode one. A
  LOCATION SEND inside the wait is not made at all: the circle's received
  input is settled
  by MDK's inputs-only advance, which stages nothing, and while the wait
  still runs and the engine still announces the eviction the send is
  answered with the typed deferral without the engine being asked to send
  (`SessionManager::departure_holds_a_send`). Nothing is staged, so nothing
  is undone: no window for a process death inside the engine's own writes of
  a stage, and no dead commit row, per publish tick (measured before this
  change: one stage-and-undo, and one more retired commit row, per send tick
  of a wait). The holds that cannot avoid the engine's preflight — a leave,
  the three admin-policy sends (hand-over, step-down, the epoch-rotation
  repair) and a receive plane's advance — find the eviction due again a few
  tens of milliseconds after the rollback, and an eviction the engine stages
  there inside the wait is undone in that same hold: it was handed to
  nobody, and no relay is called for it
  (`SessionManager::unstaged_beside_a_fanout`). The price is the send: while
  a wait runs this device shares nothing to that circle — a minute at
  first, up to an hour between attempts — and, once the eviction is due,
  nothing is sealed at the epoch the member who left can still read. Before
  it is due a send IS sealed at that epoch: inside the engine's 10–50 ms of
  jitter after the proposal, on a device that has not ingested the proposal,
  and on one whose schedule reads none. From a day after it was
  staged, a pending commit a relay may hold asks for no wake of its own and
  goes to a relay once an hour at most, on the wakes the app has anyway: the
  same bytes sent on a timer from wherever the device is would tell a relay
  that answers nothing where the device is. The resume sends only what is
  due, so a call with nothing due sends nothing; so does the catch-up sweep
  that drives, which adds no call of its own to this schedule — a sweep that
  finds nothing due calls no relay for a record, two sweeps a second apart
  make one call between them, and a relay that is backing off is not called
  because a sweep ran. The live plane adds drives, never calls: one runs
  after a staging and wherever a caller claims the foreground — a start, the
  heal, a foreground open, a claimed health tick — and an inbound event, a
  relay coming back or the app coming to the foreground is never answered
  with a call of its own — driven once a minute through an inbound storm and
  a foreground open and close around every drive, a relay that answers
  nothing is called seven times in its first hour and once in the second
  (`a_silent_relay_is_called_on_its_schedule_whatever_wakes_the_live_plane`).
  A fresh session for every visit changes nothing, because the schedule is
  the stored record's and not the session's: opened and closed three times a
  minute for two hours and five minutes, each visit a receive engine of its
  own in the state a start and the claim behind it leave it, the same relay is called at
  minutes 0, 1, 2, 4, 8, 16, 32, 64 and 124 and at no other
  (`a_silent_relay_is_called_on_its_schedule_however_often_the_app_is_opened`);
  and eight real sessions started one after another, each claimed for behind
  its start,
  two of them in each of the first two minutes, call it at minutes 0, 1, 2
  and 4
  (`real_sessions_started_one_after_another_keep_a_stored_records_schedule`).
  The claim behind a start, with nothing due, runs one drive that reads the
  store, takes no relay and dials nothing
  (`a_launch_with_nothing_due_runs_one_drive_that_takes_no_relay`).
  A bare proposal is paced on the same per-relay
  schedule, with no first call of its own outside it: a relay owed a commit
  of one circle and a leave proposed in another is called once per wait, for
  whichever of the two it was called for least recently — the leave it has
  never been sent, then the commit, in turn — and is sent what it is still
  owed in the pass in which it takes one. A
  relay another send holds is not attempted: the drive takes each relay for
  its call before it stores the attempt, waits five seconds at most, and
  leaves one it could not have exactly as it was — nothing stored, nothing
  counted — asking to be run again five seconds later (nothing schedules
  that run; the plane's next wake makes it). So is a relay that is being
  called for another record. Such a relay is still
  owed its attempt, counts towards no commit's undoing and lengthens no
  wait, however many times it happens; and a commit is undone at its bound
  only by a drive that tried every relay it owed — one in which no relay was
  due does ask — so a device that
  wakes after a day to find its relay held by another send, or by another
  record's call, tries that relay
  once more first. The relay's gate serves whoever waits
  in the order they came, so a waiting call goes ahead of every later send;
  but a call that gives up after its five seconds gives up its place, and
  nothing here bounds how often a commit can find its relay held for longer
  than that. That costs promptness, never safety (tracker T-FANOUT). A
  Welcome is sent from a delivery record of its own once its commit is
  applied (**Welcomes**, below).
- **When a row ends.** An APPLIED commit's row keeps owing each frozen relay
  its attempt — whatever becomes of the commit afterwards — and is deleted
  when two distinct relays hold the commit (one, when one is all it was frozen
  for), or a day after the later of its staging and its first acknowledged
  attempt, but never before every frozen relay has answered one attempt, and
  not until its going changes no relay's wait: until then it is kept and
  makes no call. It holds nothing: only a commit still PENDING holds its
  circle's next change, so one dead relay never blocks a circle — and a later
  commit can therefore reach a relay that never took an earlier one. A
  PENDING commit that was never possibly exposed, that removes nobody, and
  whose relays still cannot be reached or still answer "not now" a day after
  it was staged, is undone through the engine — its targets recorded as not
  taken, the engine's rollback, the commit's own row retired, the row deleted
  — and the circle takes the change again. One a relay may hold is never
  undone, however long. Neither is one that removes a member — the user's own
  removal, or the eviction of a member who left: undone, the circle's waiting
  locations would go out to the member it was meant to cut off, so it stays
  staged, shares nothing while it waits, and is applied by the first relay
  that answers. Whether a commit removes anybody is known only from a mark
  written in the hold that staged it; a commit with no mark is treated as one
  that removes, and the mark is withheld from a circle that holds a proposal
  the commit could have taken in — MDK's projected roster is the one the
  intent asks for, not the one the commit `OpenMLS` built produces. The mark
  is one per circle, cleared before every row is written, a row the open
  writes included. Every rollback is recorded for its circle, typed and
  durable, until it is acknowledged: a change undone, a removal undone. The
  note is written, durably, while the stored row still says the commit was
  rolled back, before the row is deleted, by whichever pass finishes the
  rollback — the drive, the next engine call of the session, or the pass
  before the next open, which is handed the circle store for it. A note that
  cannot be written keeps the row, and the engine held, until it can.
  Reading is not taking (`SessionManager::change_notice`,
  `acknowledge_change_notice`; bridge `change_notice`,
  `acknowledge_shown_notice`): a process that dies after reading is handed
  the note again, and an acknowledgement drops what its notice read — its
  notes, and with a dropped removal the members held beside it — only while
  nothing was written for the circle since the read. A note raised again, or
  a member held, after the read stands, and the next notice shows it; the
  same notice acknowledged twice drops nothing more
  (`a_stored_notice_drops_only_what_it_read`).
  Both bounds are read off the device's clock. An applied commit's row may end
  early on a clock that is wrong, which costs retries only, and ends when a
  stored instant lies further ahead of the clock than any wait. A pending
  commit is undone only on a clock that reads at or past its bound: a clock
  stepped back keeps it pending for the size of the step, and one thrown
  forward finds every relay due, so each is tried once more first (tracker
  T-FANOUT).
  Until its row ends, a commit goes on being sent, on each relay's
  schedule, to every relay it was frozen for that still owes it — a relay
  that is dead, or that a later change took off the circle's list,
  included. Applied, it ends as above; pending, never possibly exposed and
  removing nobody, it is undone a day after its staging, as above; pending
  and possibly exposed, or removing a member, it has no end — the former is
  sent to a relay once an hour at most after its first day, on wakes the app
  has anyway.
- **Never brought back.** A row's delete is the last thing its drive does
  with it, and an update refuses a row the store no longer holds — MDK's put
  would create it — so an answer that outlives its row is not stored. The one
  put after a delete is the open's own, giving a trial row its relays before
  any drive exists.
- **A finished circle's records.** A record whose circle is finished on this
  device — its copy removed or disbanded, or no longer held at all — ends at
  its next drive, in any mode, as a finished record ends, and nothing of it is
  sent; a quarantined or not yet hydrated circle is not finished, and its
  records stay for the retry that brings it back
  (`left_circle_e2e::the_fanout_rows_of_a_group_this_device_was_removed_from_are_deleted`).
  A Welcome accepted over this device's removed or unrecoverable copy of its
  circle deletes, in the hold of the join, every record that copy held before
  it — MDK's replacement join keeps them, and what they would send belongs to
  a branch the circle no longer has (`a_rejoin_deletes_the_groups_fanout_rows`).
- **Welcomes.** An invite made through the driver's entry
  (`Publishing::add_members`, which the app's invite into a circle uses since
  W9n) keeps its Welcomes in
  its commit's row until the first full drive that settles the confirmed
  commit — its hand-over — and only while that commit is this device's
  canonical one: each then goes to a delivery record of its own — MDK's
  `DurableTransportFanout`, with Haven's commit id in its `evolution_id` —
  holding the engine's promoted copy of the gift wrap byte for byte and its
  invitee's inbox relays. Those relays are the invitee's kind-10050 list as
  the caller resolved it when the invite was asked for, less every entry Haven
  may not dial (the foreign-relay filter: `wss` to a public host, at most
  sixteen); they are kept in the circle store's `welcome_routes` table
  (SQLCipher), written after the invite's other checks and before it is
  staged, put back as they were when the invite stages nothing (an earlier
  invite of the same person may still need them), and forgotten once a record
  holds them, when the invite's record ends still holding its Welcomes, or
  when a queued invite is retired at an open. An invitee with no such relay
  cannot be invited: the invite is refused before anything is staged. There is
  no other route — not the invitee's NIP-65 list, which a Haven invitee does
  not read for gift wraps, and never the inviter's own inbox. A route the
  store cannot read, or a Welcome the engine cannot answer for now (its group
  not live), is not taken for "none": the Welcomes stay in the commit's row for
  the next drive. Records are driven by full drives only, from the foreground,
  and add no wake of their own: due relays are tried one at a time, no sooner
  than 30 seconds after the last attempt, the wait doubling to an hour (MDK's
  host's rule), stopping at the first acknowledgement by an inbox relay of
  that event — at most about thirty sends a relay a day. The engine's state is
  read again before each relay after the first. An acknowledgement whose
  completion the engine's store refused is completed by the next drive without
  a send; an answer that could not be stored leaves the relay due again, which
  a relay that took it answers `duplicate:`; and a record another drive ended
  is never written back. A record is driven for a day from its hand-over, and
  ends an hour before its gift wrap — whose `created_at` NIP-59 backdates up to
  two days — would fall below a Haven invitee's 96-hour inbox window, when that
  comes sooner (decision 231). A record that reaches its end unsent is kept,
  inert, sending nothing: the Welcome stays the engine's outstanding one, the
  circle is told again that a Welcome is owed, and no other Welcome's delivery
  takes that note away; the inert record goes once the note was shown, or once
  the engine no longer owes the Welcome. Each Welcome a circle is founded with
  is a delivery obligation of its own from the moment the circle exists
  (`protocol-core/publish-lifecycle.md` 68-75): the create writes its record
  before it returns and before anything is sent — no commit, the routes
  resolved at the create, everything else as above — and a record that cannot
  be written undoes the create (`SessionManager::record_founding_welcomes`;
  `fanout_change_e2e::{a_founding_welcome_is_recorded_before_create_returns_and_before_any_send,
  a_founding_welcome_is_sent_from_its_record_until_an_inbox_relay_takes_it,
  a_founding_welcome_survives_a_restart_and_is_sent_by_the_next_foreground_drive,
  a_founding_welcome_record_that_cannot_be_written_undoes_the_create}`). The
  driver's create (`Publishing::create_circle`, bridge
  `RelayManagerFfi::create_circle_driven`, the app's only create) sends them
  at once and counts as sent only those an inbox relay acknowledged. No other
  path holds a founding Welcome: the core's plain create is built for tests
  alone, and the bridge's plain publish entry refuses every gift wrap, typed
  (`PublishRefusalFfi::GiftWrap`; `the_plain_publish_refuses_a_gift_wrap`),
  so the driver is every Welcome's only sender. A Welcome the engine counts
  outstanding with no record — made before records were kept — is never sent
  from here, and no route is resolved for it
  (`a_founding_welcome_with_no_record_is_never_sent`). Before each send a
  record is asked whether its Welcome is still wanted: one whose invitee is no
  longer on the roster, or whose circle this device's copy has left — removed
  or disbanded — ends as failed, its record with it, and the circle's note
  that a Welcome is owed goes with the last
  (`the_outbox_stops_for_a_removed_invitee_a_disbanded_group_and_an_expired_key_package`,
  `a_welcome_is_not_sent_for_a_circle_this_device_was_removed_from`); a
  roster that cannot be read, or one that only a commit of this device's still
  unpublished would make, waits. A disband's settle ends the circle's records
  itself. A record is also never driven past the `not_after` of the
  `KeyPackage` its Welcome was made for, which is kept with the invitee's route
  (`a_welcomes_bound_is_its_key_packages_not_after_when_sooner`), and ends there
  as at its day. While branch selection has set the commit aside for
  now, nothing is sent; once it has lost for good, each of its Welcomes ends as
  failed — never as delivered — and its record with it, so nothing can later
  send one into an epoch the circle never reached. A rolled-back invite hands
  over nothing. Each retry tells the relays of the invitee's inbox, for up to a
  day, that this device's address sends to that inbox, foreground only — what
  the invite's first send already told them. That a confirm ALONE releases a
  Welcome rests on the shape of an invite's commit, not on a rule about
  commits: it carries a path, and the engine cannot apply a path-bearing
  commit of its own from its stored row, where it can apply one without a
  path — a relay change, a hand-over, a step-down — with no confirm at all
  (tracker T-ROLLBACK-RESURRECT). Haven's invite never grants an admin,
  which is what would make MDK build it without a path
  (`an_invites_commit_is_applied_only_through_a_confirm_at_this_pin`). A
  Welcome found in a state no path of this pin leaves it in — failed, or
  still as its staging wrote it, under an applied commit — is never sent as
  it stands: its circle is told a re-invite is owed. Two recoveries follow
  that note: an invite branch selection withdrew is invited again with fresh
  key packages by `Publishing::reinvite` (bridge `reinvite_driven`, called
  from the app's foreground maintenance tick only; tracker T-REINVITE-DRIVER)
  — only in a circle
  this session has caught up with, stable, with no input unresolved, so no
  lookup is spent and no invite made from an epoch the circle may have left;
  a circle this device left asks no relay, and MDK ends its record. MDK
  refuses a package the withdrawn invite already spent, which an invitee
  keeps published while the invitation is unanswered (Security Rule 5): that
  answer is "package missing", and the package is looked for again on MDK's
  schedule (`a_reinvite_offered_the_spent_package_is_said_to_miss_one_and_stays_owed`,
  `a_reinvite_of_an_unsettled_circle_spends_no_lookup`,
  `a_reinvite_of_a_circle_since_left_asks_no_relay`). A Welcome lost otherwise
  has no MDK record, and only the user removing and re-adding the invitee
  helps.
- **A wake's budget.** A call given a budget is bounded by it as a whole.
  Nothing is begun that the wake could not wait out: a row is taken up only
  while the wake has thirty-one seconds left — five for its relay's gate,
  MDK's client's twenty for the call, six for the deadlines the fold of its
  resolution may wait out; the engine's deadline for a row it no longer holds
  is served only with those six left; a Welcome, a proposal with no row and
  a commit the deferred-send repair handed back are handed to their
  publisher only with its own longest run left, forty-nine seconds. And no
  relay is waited for past the wake's end: an attempt still unanswered then
  is left stored as begun, which the next drive records as possibly exposed
  — what a wake the system cut off leaves — and is never a rollback. What
  was not begun stays stored as it was: a Welcome stays in its record and is
  sent by the next full drive; a commit the repair handed back stays
  staged, neither confirmed nor rolled back. A call that cannot have its
  relay to itself within five seconds is not made: nothing is handed over
  and nothing is stored. A row whose drive ends on an error
  stops the rest of its own circle's rows and no other circle's, and what was
  driven is returned beside that error. A row the engine no longer holds
  that is still unsettled when a resume returns asks to be resumed when the
  engine's own deadline for its circle is due, never sooner than five
  seconds. The resume gives itself two rows' worth; the catch-up sweep that
  drives is bounded, drives included, by the budget it is given — one of
  less than a row's thirty-one seconds reads and records and drives nothing
  — and that budget, which crosses the FFI, is clamped to an hour.
- **What the circle is told.** Eight things that can happen to a change with
  nobody waiting on it are recorded for the circle, typed and durable, until
  the app acknowledges them: a change undone; a removal undone (also said of
  an undone commit whose kind nothing recorded); a commit that the engine has
  set aside for good after a relay was sent it, or cleared at an open after
  whoever staged it may have published it — the circle may be out of step
  with its other members; an invite applied with no Welcome left to deliver;
  a Welcome still owed — written when a hand-over gives one a record and
  again when a record reaches its end unsent, cleared when the circle's last
  record ends delivered, never by another record's end while one inert
  record stands;
  a commit staged that could be neither recorded nor undone; a queued change
  retired unmade; and a queue the engine's advance could not drain. Three are
  written before the only other trace of what they say can go, and what
  cannot be written keeps that trace: a change or a removal undone (the
  stored row stays), a queued change retired unmade (the change stays
  queued). The other five are best-effort — a write that fails leaves a log
  line and nothing else: the circle that may be out of step, the re-invite
  owed, the Welcome owed, the commit staged with no record, the queue that is
  held. None
  carries a name, a key or a count. The change card in Circle details reads
  them and acknowledges what the user has read.

Tests: `haven-core/tests/fanout_driver_e2e.rs`,
`haven-core/tests/fanout_restart_e2e.rs`, `haven-core/tests/fanout_end_e2e.rs`,
`haven-core/tests/fanout_change_e2e.rs`,
`haven-core/tests/live_plane_drive_e2e.rs`,
`haven-core/tests/publish_failed_rewind_e2e.rs`, and the unit tests beside the
driver.

### Relay URLs: one policy, judged on the parsed scheme

Haven dials `wss` relays only (a debug build's loopback opt-in is the one
exception, for hermetic tests). The scheme a URL has is not how its text
begins: `WS://host`, `ws:host`, `ws:/host` and a URL with a tab inside its
scheme all parse as plaintext `ws`. Every decision is therefore made by one
function on the parsed URL, `relay::url_norm::may_dial`: the publish and fetch
validator, the live-sync engine's gate, both normalisers that decide what may
be stored, the relay-list builders (kinds 10002 and 10050) and the validation
of a circle's routing component before Haven writes one. Before this, the
publish validator, the engine gate and the normalisers each tested a raw
prefix. A circle admin on another client could spell a relay `WS://…` in the
routing component — MDK admits any spelling that parses to `ws` — and every
Haven member's engine would have opened its standing subscription to it in the
clear, showing an on-path observer the circle's routing id, the member's
gift-wrap address and the timing; and a relay typed as `ws:host` was stored as
`ws://host`, from where a relay update would have advertised it to every
member's client. Tests: `start_never_dials_a_plaintext_relay_however_its_scheme_is_spelled`,
`a_plaintext_relay_is_refused_however_its_scheme_is_spelled`,
`a_plaintext_relay_is_never_normalized_however_its_scheme_is_spelled`,
`a_relay_list_never_advertises_a_plaintext_relay`,
`a_routing_component_haven_writes_never_names_a_plaintext_relay`.

A routing entry must also be on a public host. Every path that takes a
circle's relays from its routing component — the join and every later
re-derivation (`circle::manager::usable_relays`) and the relays a commit or a
location is frozen for (`fanout_targets`) — keeps only what another account's
relay list may name (`relay::manager::foreign_relay_dialable`: `wss` to a host
MDK's `is_loopback_host` and `is_public_ip` admit, a domain accepted
unresolved apart from the loopback names), so an admin on another client
cannot point a member's sockets at `wss://10.…`, `wss://169.254.169.254` or
`wss://localhost` inside the member's own network. Haven never writes such an
entry: a relay update naming one is refused in fixed text naming no relay
(`circle_relays`), and so is a create whose caller named one (`routing_of`),
before anything is recorded or staged. A create whose caller named no relays
draws them from Haven's location pool (`circle::location_pool::pick_circle_relays`,
*The location relay pool* above) or a debug build's installed test list, which
may name a relay only the device can reach: such an entry is left out with the
pick's other exclusions, and the create is refused (`CircleError::NoLocationRelay`)
only when none is left. Residual: a domain that resolves to a private address, as
for MDK's own `reject_unsafe_relay_host` (tracker T-GROUP-RELAY-HOSTS). Tests:
`a_routing_entry_on_a_non_public_host_is_dropped_on_every_read_path`,
`haven_never_writes_a_routing_relay_on_a_non_public_host`,
`installed_override_reaches_the_pick_and_stays_subject_to_exclusion_and_the_host_rule`,
`pick_leaves_out_a_pool_entry_on_a_non_public_host`,
`a_routing_component_haven_writes_never_names_a_non_public_host`.

A routing component is another client's to write, and what it names that
Haven may not dial is dropped one entry at a time. Every publish validates its
whole target list and the live-sync engine its whole session, so a single
plaintext entry — `ws://….onion` from another Marmot client is the likely
honest case — used to stop every publish to that circle, the relay update that
would repair it, and, through the engine's session start, receiving for every
other circle on the device: a lever one circle's admin held over a member's
other circles. A circle's own relay list is now derived from the component
with each such entry left out, at the join and at every later re-derivation
(`circle::manager::usable_relays`); the component itself is never rewritten.
A circle none of whose entries may be dialled has an empty list: a publish for
it ends in the typed all-relays-failed outcome with nothing dialled, the engine
still starts, and Haven's own relay-update flow refuses to start from an empty
list — whether an admin is offered a repair there is an open product question.
Tests: `tests/foreign_routing_entry_e2e.rs`.

**What a refused event does.** Nothing. It is dropped inside the pool as if the
relay had withheld it: it is not logged (the text would be the relay's, at a
rate the relay chooses — Security Rule 15), it is not counted as an arrival,
the relay's `EOSE` keeps its meaning, nothing records its id as seen, and a
genuine event with the same id is admitted normally afterwards.

**What remains.**

- A relay can still withhold. Verification makes what arrives trustworthy; it
  cannot make anything arrive. The hold-backs and redelivery rules of Security
  Rule 12 are what answer a withholding relay.
- A relay can serve a superseded, genuinely signed replaceable event as the
  newest. Where several relays are asked, the newest `created_at` wins and a
  tie goes to the lower id, as NIP-01 keeps it (`newest_authored`, the per-relay
  page order, `fetch_own_profile`, the profile parser). Where one relay is
  asked for one author — a member's profile — or one answers alone, the only
  defence is the local newer-wins gate, which protects once a newer copy has
  been cached and not before. Haven keeps no high-water mark for another
  account's relay lists or KeyPackages.
- The user's OWN profile is the one replaceable event Haven signs on top of.
  An edit is merged onto the relays' copy only when that copy is at least as
  new as the dated own-profile row this device holds; an older answer is
  superseded and is not built on (`merge_base`), so a relay replaying last
  month's profile cannot get fields removed since signed back. The row is
  written when a profile fetch caches the copy, when the read a publish makes
  for its base finds a newer one — before the publish, so a publish that then
  fails still leaves the row at the newest copy read — when a relay
  acknowledges a publish, and as the blank's record when the profile is
  deleted: dated as the blank is, written only after a relay acknowledged the
  blank and in one transaction with the record of its publication, so a relay
  that never took the blank can neither get the deleted profile cached again
  nor get the next edit built on it. A device with no dated row — a fresh
  import of the key, or the first edit after this release's reset, before a
  fetch has landed — builds on whatever the answering relays serve, and on
  what was saved alone when none answers. One window is not closed: the row
  is written after a relay's acknowledgement, so a process killed between the
  two has published a profile its row does not record, and until a fetch
  serves that profile back the row is older than what the device itself
  signed (closing it needs the intent written before the publish). The cached
  row is a faithful base once it is written from an event: it stores the
  event's whole metadata object, the fields Haven does not model included,
  with the user's own queued edits on top. A row created by saving on a
  device that has not yet fetched or published the profile holds only what
  was saved there, and is dated 0 so that no served copy is ever older.
  Saving an edit and removing the photo both take their base this way; when
  no relay serves the profile the base is the cached row. Removing the photo
  with neither — no relay copy and no dated row — publishes nothing: a no-op
  when every relay answers that no profile is published and this device has
  no record of publishing one, and a failure otherwise. A removal built on
  the cached row publishes a name still waiting in the outbox, since the row
  carries it, and records it as published in the same transaction, with the
  coverage it got; a name it did not publish stays queued and stays on the
  row, as does one saved while the removal was being published. A removal
  some relay of the pool did not acknowledge is not done — that relay still
  serves the photo to the peers who read the profile from it — so it is
  never recorded as synced: with nothing else waiting, the profile it
  published is itself left pending, partly published, and the sync sends it
  to the whole pool again on the backoff any partial publish keeps; with an
  edit waiting, that edit's sync carries it. The blank a deletion publishes
  is owed in the same way when some relay did not acknowledge it, in the
  transaction that wipes the cache; what the retry publishes is a blank
  again, since the row it builds on is the dated blank. The backoff runs
  from when the retraction was recorded, so the status re-read that follows
  it publishes nothing. A photo saved while a removal is running is neither
  reported published nor deleted. One read of the pool serves both the
  retraction's "was anything ever published" gate and its base, for the
  removal and the deletion alike.
- **A publish some pool relay never acknowledges is retried without a cap,
  and each retry is a new public event.** This holds for a saved edit, a
  photo removal and a deletion's blank alike. Every retry pass reads the
  pool once and signs a NEW kind 0 — the same content, a new `created_at`
  and so a new id — for the whole pool. Each relay that takes it therefore
  holds a public mark of when the app was opened: at most four times in the
  first hour (30 s, 2 min, 8 min and 30 min after the last pass) and then at
  most once per six hours, only while the app is opened (cold start, resume,
  and the re-read after a photo removal; never from a background isolate),
  and for as long as one relay of the usable pool does not acknowledge. The
  debt ends when every relay of the pool acknowledges one pass, or when the
  relay that does not leaves the pool — retired in an app release, or
  excluded as contaminated. Until then the status line reads "still
  syncing". A relay that is no longer in this install's usable pool is
  never sent the retraction at all, and the outbox reads synced without it.
  Not bounded in this release (owner decision owed: re-send the one signed
  event instead of minting a new one, and define when a relay holding a
  newer copy from another client ends the debt).
- The policy is not a ban. A relay that sends a forgery is not disconnected,
  demoted or reported: that would be state a relay can reach and a surface the
  user would need, and it cannot be logged per relay.
- A validly signed event of the wrong author or kind is still a relay's to
  send. The checks that bind an answer to the account and kind that were asked
  for are separate, and unchanged (`RelayManager::newest_authored`,
  `pick_keypackage_from_events`, `retain_own_events`, the profile parser).
- The Welcome inside a gift wrap is an unsigned kind-444 rumor (Security Rule
  3). It is never a relay event and is never passed to `verify()`; the gift
  wrap that carries it is, and is.
- A kind-445's outer signature is an ephemeral key's and authenticates no
  member. MLS authenticates the content; this check only stops a forged copy
  from standing in for the genuine one. Anyone can still wrap the same
  ciphertext, or junk, in a new validly signed 445 with any `created_at`, `h`
  or `expiration`; that is a different id, and is what the cursor rules and MLS
  answer.
- Cost: one SHA-256 and one BIP-340 verification per frame the hook is asked
  about, on the sending relay's own socket-reader task, so the back-pressure
  falls on the relay that floods; the CPU it costs is this device's, as the
  pool's own verification of unseen events already was. The pool's own
  first-sight check runs under a cache lock all of a client's relays share, so
  a flood of unverifiable frames from one relay also delays the others; that
  is the pool's behaviour and is unchanged. An event seen for the first time is
  verified twice, by the pool and by the policy. Haven keeps no verification
  cache of its own.
- What was written before this check existed. Released builds had none, so a
  relay could have planted forged state on a device: a cached profile dated
  far in the future (the cache keeps the newer of two, so it would outrank
  every genuine one), picture bytes fetched for it, a sync cursor moved past a
  commit, an engine row marked failed. This release's storage reset
  (`haven-core/src/storage_reset.rs`) deletes every store that could hold any
  of it — the circle store, which holds the profile cache, the cached
  pictures, the cursors, the refused-object ledger, the last-known locations
  and the member directory, and both MLS stores — and the app clears the one
  preference that could carry relay-derived text, the user's own display name.
  Each is first written again from verified events
  (`hard_reset_first_open.rs`
  `nothing_a_relay_planted_before_the_update_outlives_the_reset` for what the
  circle store held, `the_migrated_build_never_opens_a_pre_migration_store`
  for the three other files, and the app's `storage_reset_own_name_test.dart`
  for the preference). The one thing nothing can repair is on the relays: an
  own profile that a forged copy was merged into before the update is now a
  genuine, identity-signed event. Only its name, bio and photo cross to the
  app, where the user sees and can replace them; `lud16`, `lud06`, `nip05`,
  `website`, `banner` and any field Haven does not model never do, and Haven
  carries them across every edit because they may be another client's. After
  the reset the first edit is merged onto that event, so such a field stays
  until the user removes it with a client that shows it. Its date is the
  forger's too: Haven stamped that profile one second past the forged copy's
  `created_at`, which a relay could set to any future instant. Haven's own
  later edits stay ahead of it, but an edit another client stamps with the
  current time does not supersede it until that instant has passed.

Proved by `relay::verified::tests`, `haven-core/tests/forged_relay_event_e2e.rs`,
`haven-core/tests/forged_group_event_e2e.rs` and the two `a_forged_…_via_real_ffi`
tests in `haven/rust_builder/src/api.rs`, each against a scripted relay that
forges on the plane under test. `a_pool_client_without_the_policy_hands_back_a_forgery_of_an_id_it_has_seen`
shows the gap on a client built without the policy, and goes red the day the
pool closes it (`docs/MDK_UPSTREAM_TRACKER.md`, `T-POOL-VERIFY-CACHE`).

## Security Architecture

### Database Encryption

Haven uses SQLCipher (encrypted SQLite) for all persistent databases. Encryption keys are stored in the system keyring:

- **macOS**: Keychain
- **Linux**: GNOME Keyring / KDE Wallet / Secret Service
- **Windows**: Credential Manager

| Database | Purpose | Service ID | Key ID |
|----------|---------|------------|--------|
| `session-v2.sqlite` | MLS group state (MDK v0.10.4 `AccountDeviceSession`; WAL) | `com.oblivioustech.haven` | `mls.session.key.v2` |
| `circles-v2.db` | Circle metadata, contacts, memberships | `com.oblivioustech.haven` | `circles.db.key.v2` |
| `tiles-v2.db` | Encrypted map-tile cache | `com.oblivioustech.haven` | `tiles.db.key.v2` |

The stores that builds before the MDK v0.10.4 migration wrote — `session.sqlite`,
`circles.db`, `tiles.db` and `haven_mdk.db`, keyed by `mls.session.key.default`,
`circles.db.key`, `tiles.db.key` and `mdk.db.key.default` — are deleted with
their keys by the storage reset below and never opened again.

All keys are 32 bytes of `OsRng` output. `circles-v2.db` and `tiles-v2.db` apply
the key raw (`PRAGMA key = "x'<64-hex>'"`, KDF bypassed). The MLS
`session-v2.sqlite` key is provisioned differently (security F5): the keyring stores the raw 32
bytes, and Haven feeds their lowercase-hex encoding to the Dark Matter
`storage-sqlite` backend as a **SQLCipher passphrase** (`SqlCipherKey`), which
SQLCipher stretches through PBKDF2 (`cipher_compatibility = 4`) — a pure
defense-in-depth stretch over already-256-bit material. The passphrase is
`Zeroizing` end to end and never logged; `session-v2.sqlite` runs **WAL** (the
pre-Dark-Matter MLS DB was rollback-journal) with `secure_delete` and
`cipher_memory_security` (see `haven-core/src/nostr/mls/storage.rs`;
`tests/mls_store_memory_security_on.rs`). A test fixture's store
(`StorageConfig::test_storage_options`, test and `test-utils` builds only)
runs it off: the setting is process-wide and one-way, and on it serialises a
test binary's threads behind SQLite's allocator mutex
(`tests/mls_store_memory_security_off_in_tests.rs`).

**MDK v0.10.4 storage reset and secure-erase (owner decision D1).** MDK
v0.10.4 cannot open a v0.9.4 store and Haven carries no importer, so the first
open after the upgrade runs `reset_pre_v2_storage` (`haven-core/src/storage_reset.rs`,
also called by every store opener, since a background isolate may open first):
it deletes all four pre-migration databases with their `-wal`/`-shm`/`-journal`
sidecars AND destroys all four old keyring entries together with each one's
iOS access-policy companions (`{id}.afu.v1`, the migration marker, and
`{id}.afu.bak`, a full copy of the key: a surviving backup is the key at rest),
and the new stores use new file names and new key ids, so a leftover is never
read or reused. Unlinking
alone is NOT a secure erase — the old databases were not all written with
`secure_delete`, and flash wear-levelling leaves residual ciphertext — so
**destroying the key is the practical secure-erase** for an abandoned SQLCipher
database. Circles, memberships, locations, petnames, custom relays, the
relay-list publish toggles, unsynced profile edits and every cache go with them;
the identity key does not. A zero-byte marker (`storage-reset-notice`) records
that the reset deleted the user's data (the session, circle or MDK database; a
tile cache alone owes no notice), and it is written BEFORE anything is deleted:
if it cannot be written the pass deletes nothing, so no circle can vanish without
the notice owed. The publish gate fails closed: it stays shut while the marker
stands OR any pre-migration user store survives (a pass that could not write the
marker, or could not delete a store). A second marker (`storage-reset-prefs`),
written with it, makes the app clear its own preferences naming the deleted
circles (and its local copy of the user's display name, which the deleted outbox
may never have published; it is re-taken from the user's published kind-0)
exactly once, on whichever launch first sees it — never on later launches
while the notice merely waits, and never again on a pass that retries a store it
could not delete: clearing writes a third marker (`storage-reset-prefs-cleared`)
that stops the retry re-owing it, because by then the preferences name circles
made after the reset. The logout wipe removes the notice and that third marker,
both being the departing identity's. Until the user answers the one-time notice
(`acknowledge_storage_reset`), no plane publishes a relay list (kind 10002/10050)
or a KeyPackage, so the defaults the reset restored are never published before
the user is told. The reset logs one boolean, never a path, a count or a key id.

Existing unencrypted `circles-v2.db` files are automatically migrated to encrypted
storage on first access via SQLCipher's `sqlcipher_export()` function.

**First open at process start.** SQLCipher finishes its own start-up after
SQLite has already told every other thread the library is ready, and until it
has, `PRAGMA key` fails. The UI isolate, the Android foreground service and the
catch-up worker are isolates of one process sharing one loaded library, so the
tile cache opening in one and the circle manager opening in another could meet
at process start and one of them fail to open: a tile cache left off until the
next launch, or a background wake that publishes or receives nothing. No data is
at risk in that failure: the key is refused before any page is read, so it is
never mistaken for a wrong key, and nothing is recreated or migrated. Every
store open therefore first runs SQLite's initialisation to completion under a
process-wide lock (`haven_core::sqlcipher_init::ensure`). A failure of the
in-memory open is returned as the caller's storage error and the next open tries
again. A failure of SQLCipher's own start-up is not visible to the gate and
cannot be retried in-process (SQLite has already marked itself initialised);
every keyed open then fails closed until the process restarts.

What holds it, and what each part holds:
`scripts/ci/check_sqlcipher_first_use_gate.sh` holds, from the source text alone,
that every direct SQLite open has the call ahead of it in the same function.
`haven-core/tests/sqlcipher_first_use_gate.rs` runs each store opener it lists
in a process of its own and fails if the gate has not run by the time the open
returns (an opener missing from that list is held by the guard alone); its
second test opens sixteen stores at once as a process's first contact with
SQLite, which shows only that concurrent first opens succeed and do not
deadlock. `sqlcipher_init::tests` hold the gate's blocking and its retry. No CI
test reproduces the race itself. The gap is upstream's
(`docs/MDK_UPSTREAM_TRACKER.md`, T-SQLCIPHER-FIRST-USE).

**Linux requirement**: A D-Bus Secret Service provider must be running
(GNOME Keyring, KDE Wallet, or KeePassXC). Without one, circle
operations will be disabled with a descriptive error.

**iOS keychain accessibility (owner-approved tradeoff)**: On iOS the SQLCipher
DB keys (`mls.session.key.v2`, `circles.db.key.v2`, `tiles.db.key.v2`) are
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
SQLCipher-encrypted `circles-v2.db` (or in memory), never in plaintext
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
tears down all MLS state: it deletes the MLS `session-v2.sqlite` and
`circles-v2.db` files **and removes their keyring keys** (`mls.session.key.v2`,
`circles.db.key.v2`, each with its `.afu.v1`/`.afu.bak` access-policy
companions — so neither the ciphertext nor any copy of the key survives), after
resetting the sync cursors. (Every pre-migration store and key is already gone
via the storage reset above.) A
one-way `_wiped` latch on the circle service closes a re-open race: the M8
maintenance timers run on their own cadence regardless of the live-sync engine
(LIVE by default since M11, but stopped on logout — once before the wipes and
again behind the latch, where nothing can start one, because the shell that
owns its restarts stays mounted across a logout; see `deleteIdentity`. A stop
the engine answers as still holding, or does not answer within the one restart
budget both stops share (65 s in all), does not hold the wipe back — a user who
killed the app during an unbounded wait would keep the key. A stop given up on
is torn down on the Dart side at once: its session delivers nothing more, and
no session is adopted until the engine's stop returns. What that core still
holds is closed by the engine's own stop, which is bounded: it waits one relay
operation for the lifecycle lock and then tears down beside a holder that
will not let go, so its REQs are closed and its relays are told to close
within about seventy seconds whether or not the stop answers drained
(`a_stop_whose_lock_is_held_tears_down_within_its_bound`). One socket can
outlive that: a connection task the stop's bounded termination of every
relay timed out on keeps its socket, with no REQ, until the process exits
(`LiveSyncCore::terminate_all_relays`). Its open handles on the unlinked
files last until its last task ends, at worst until the process ends), so a
maintenance tick could
otherwise call into the circle service *after* the wipe and cause SQLite to
re-create a fresh, decryptable `circles-v2.db` + a fresh keyring key. The latch refuses any re-open once logout has
begun; a re-check after the DB-open FFI and a drain of any in-flight open ensure
the wipe deletes whatever a racing open created, so no decryptable database can
be resurrected. The latch is per-instance and the service is a rebuilt-on-login
provider, so a subsequent login is unaffected.

**What of one identity outlives it into the next in the same process.** One
provider container lives across a logout and the login that follows. Every
provider that was built from the identity — the relay-preferences handle and
the three relay lists, the circle list, the invitation and KeyPackage
providers, the location service with its in-memory cache and its cached
pubkey, the schedulers and the per-identity state notifiers
(`identityScopedProviders`, `haven/lib/src/providers/identity_scope.dart`) — is
dropped at the end of the logout and again at the login, and the live-sync
event router reads its circle service at each event rather than holding the
one it was built with. Before this the next identity's inbox REQ was issued on
the previous identity's cached inbox relay list, which with a customised list
linked the two at that relay; its streamed Welcomes were handed to the wiped
circle service. A provider outside the set that captures an identity-scoped
value while it is built fails `haven/test/providers/identity_scope_test.dart`.
The end of the logout also clears two process-lifetime accumulators outside
that set: the clock-skew detector's evidence (the deleted identity's peers'
pubkeys and clock offsets), which nothing of that identity refills behind the
reset because a wiped location service records no sample, and the event
router's wedge verdicts awaiting confirmation (keyed by its circles' group
ids). It shuts the publish pool — after every stop has returned or been given
up on, after the wipe and after the key is deleted — so the next identity's
first publish opens sockets of its own (`NostrRelayService.shutdown`, which
also shuts a pool still being opened). Before this, the pool's sockets lived
60–70 s past their last send, and the next identity's publishes inside that
window rode them — the Dart side's location, commit, KeyPackage and
relay-list publishes all ride that pool (`RelayManagerFfi`'s own manager) —
which linked the two identities at that relay. No publish of the deleted
identity can start on the pool by then: every publish needs an MLS operation
the latch refuses, and the timers that publish were cancelled before the wipe;
one still out is cut. A fetch can still be made while logged out, so every
login shuts the pool again before it provisions the next identity, and that
identity's first publish or fetch opens a pool of its own whatever the old one
carried. The cost is one fresh connection for the next identity. Profile
publishes build a manager of their own per call, and the live session's
fanout drives use a pool of their own, closed with the session. Each upload
and download of a profile picture builds a Blossom client of its own and drops
it with the request: no connection outlives the request, and no TLS session —
rustls keeps resumption tickets in its client config, one per client — so
nothing one identity's request opened, not even a ticket, is presented by the
next identity's (`no_connection_outlives_its_request`,
`no_tls_session_outlives_its_request`; the cost is a full TLS handshake per
request, and avatars are cached). The relay sockets cannot resume across
identities either: each connection builds a TLS config of its own
(`async-wsocket` 0.13.2 `native/mod.rs` `connect_direct` →
`tokio_tungstenite::client_async_tls`, which with no connector given builds a
fresh rustls `ClientConfig`, and its session cache, per connection —
`tokio-tungstenite` 0.26.2 `tls.rs` 90-128). Of what a relay can
observe or the next identity's engine is started from, two things outlive the
logout: the mounted shell's set of circles its engine restarts re-subscribe,
held until onboarding replaces the shell, which is the only place a login runs
(pinned by the same test); and a stop given up on, whose
core's sockets and REQs last until its bounded stop closes them and whose
open file handles last until its last task ends (above).
The location service's in-memory cache is closed by the wipe, and a streamed
location whose identity the logout has ended before its handler reached the
location service is dropped — the event router forgets the identity at the
logout's end, and an event is judged by the identity current when it arrived
— so no coordinate of the deleted identity's peers is merged behind the
logout, then or after the login. No other stop drops one: after a pause, a
detach or a foreground restart the location service's own state decides: a
paused one persists the fix where it still holds the store (not on Android with
background sharing on, where the store is handed to the foreground service)
and merges nothing into its closed cache.

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

Each wake **receives first, makes no commit, and is consent-gated**:

- A wake runs the receive-only sweep (`run_catchup_all_circles`), which
  authors no MLS state, and then, under the same consent read, carries on
  each leave this device asked for, claiming no foreground
  (`LeaverBackstop` → `resume_leave_driven` with `foreground: false`). That
  carry-on may send the leave's proposal — recorded, or as the record it
  stands under — and may end the leave on this device at its bound or once
  this device's copy is marked removed; it makes no commit: in the mode that
  makes none, an admin's hand-over or step-down is refused (`ForegroundOnly`)
  and no eviction is published (one the leave's preflight stages is undone
  in the same hold).

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
  loads the identity and bails on a missing one *before* opening `circles-v2.db`,
  so a post-logout wake cannot resurrect (or freshly create) a decryptable DB.

Per-wake relay connections here are short-lived (one sweep, then shutdown) —
this is the **no-foreground-service** background path (OS wakes that receive
and carry a leave on, and make no commit),
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
for diagnostics are presence-only (fixed strings + bucketed counts) — never coordinates,
pubkeys, group ids, or event ids.

The iOS keychain accessibility tradeoff that lets a locked-but-unlocked-since-
boot device read the SQLCipher key during a background wake is documented under
*Database Encryption* above (owner-approved, `ThisDeviceOnly`, never synced).

### Test-Utils Feature

The `test-utils` feature enables keyring-free test storage. (For the MLS DB the
Dark Matter backend always encrypts: `SessionManager::new_unencrypted` opens a
temp SQLCipher DB under a fixed test passphrase — the "unencrypted" name is
historical API continuity; `circles-v2.db` test paths remain truly unencrypted.)
This feature:

- Is gated with `#[cfg(any(test, feature = "test-utils"))]`
- Produces a compile error if enabled in release builds
- Should NEVER be enabled in production
- Also builds `relay::scripted_relay`, the loopback relay the forged-event
  tests script, and with it the feature's one optional dependency
  (`tokio-tungstenite`, already in the graph through the relay pool)

### MLS Security

Haven implements the Marmot Protocol (v2, Dark Matter engine) for MLS over
Nostr. Key security properties:

1. **Key Separation**: MLS signing keys are separate from Nostr identity keys —
   formalized on-wire as the mandatory `marmot.member.account-identity-proof.v2`
   LeafNode app component (`0x8009`): a canonical kind-450 event signed by the
   identity key, binding identity pubkey ↔ MLS leaf signature key (see the rebroadcast
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
   A live-sync stop bounded beside a wedged holder returns, but the session
   — its manager, the engine and the `LiveSessionGuard` — is released only
   when the last task holding it ends, and that is not bounded from Haven: a
   task inside an engine call is never aborted, because MDK documents none
   of its calls as cancellation-safe, and one dropped between its store write
   and its in-memory update would part the engine's memory from its store —
   the divergence this invariant exists to prevent. The relay calls such a
   task can wait on the network for are bounded; the rest take only the
   pool's own locks, and an engine call ends with its database work. Until
   the hold ends, `LiveSessionGuard::acquire` refuses a second session on the
   same file (`SessionBusy`) and the stop answers `TimedOut`
   (`a_bounded_stop_beside_a_wedged_holder_leaves_no_second_session_and_no_confirm`,
   `a_stop_beside_a_wedged_holder_leaves_no_foreground_standing`).
6. **A circle is joined only by the user's accept — a confidentiality
   control**: the engine joins any Welcome it ingests, and a joined circle
   receives the user's location. Two independent layers keep a relay from
   joining the user to a group of its choosing. Group-traffic intake on every
   plane (catch-up, poll/decrypt, live, burst) admits kind 445 alone, so a
   gift wrap slipped into a page is refused before the engine
   (`SessionManager::screen_before_auth`); a Welcome enters only through
   `accept_welcome`. And the invitation the user accepts is recorded first in
   an accept-intent ledger (`accept_intents` in `circles-v2.db`: the gift-wrap
   id and the raw key of the inviter the invitation showed, never logged,
   cleared in the transaction that commits the circle); a join the engine
   hands back without a matching intent is acknowledged and kept hidden, never
   made a circle (`CircleManager::record_unrecorded_join`), which also keeps a
   circle the user left from coming back. The consent is to that inviter, the
   NIP-59 seal author: a join whose MLS-authenticated welcomer (MDK's
   `GroupJoined.welcomer`, the GroupInfo signer's leaf) is another key is
   undone wherever it is first seen — at the accept, at an accept repeated
   after one that died, at the next open — by forgetting the group, resolving
   the invitation as a decline and answering `NeedsNewInvite`; a circle row
   the join replaced a removed or unrecoverable copy under goes as at a leave
   (`left_circle_e2e::{welcomer_mismatch_forgets_group,
   a_welcomer_mismatch_over_a_removed_copy_ends_its_circle}`). Only an admin of the
   group, or someone it hands its Welcome to, can cause such a join. The
   `KeyPackage` that Welcome consumed stays consumed: MDK names a Welcome's
   author only by joining it. A Welcome that would replace this device's
   still-active copy of its circle (a removal it never saw, or a fork) is
   joined only on the user's press, given to the offer as it was shown:
   `CircleManager::rejoin_offers_for_invitation` shows MDK's offer with its
   local-branch token, and `confirm_group_rejoin` hands that token back for
   MDK to re-check inside the replacement's own transaction, so a branch that
   moved meanwhile changes nothing and the user is asked again. An offer
   whose author is not the inviter shown, or one for a circle this device has
   asked to leave or whose leave MDK still holds a request for (the join would
   carry that request into the new branch; tracker T-REJOIN-LEAVE), is
   declined with its invitation; a declined offer is never offered again, and
   Haven never calls MDK's automatic `retry_rejoins_after_trusted_removal`
   (`left_circle_e2e::{replacement_welcome_requires_explicit_consent,
   a_declined_rejoin_is_never_offered_again,
   a_rejoin_offer_for_a_circle_being_left_is_declined,
   a_rejoin_offer_whose_author_is_not_the_inviter_is_declined,
   a_consent_the_local_branch_moved_under_is_refused_with_nothing_changed}`).
   Pinned by
   `catchup_sweep_e2e::a_welcome_a_relay_slips_into_a_catchup_page_joins_nothing`,
   `application_output_ack_e2e::{a_join_nobody_accepted_is_acknowledged_and_kept_hidden,
   a_welcome_handed_to_the_poll_plane_joins_nothing,
   a_welcome_delivered_on_the_live_plane_joins_nothing,
   a_left_circle_whose_join_is_handed_back_stays_gone}` and the FFI test
   `an_injected_welcome_through_the_ffi_decrypt_joins_nothing_via_real_ffi`.

#### Identity-proof rebroadcast (kind 450) — irreducible, by design (F12)

Every MLS leaf Haven produces embeds the `marmot.member.account-identity-proof.v2`
app component (`0x8009`): a canonical kind-450 Nostr event (`created_at` = signing
time) Schnorr-signed by
the user's Nostr **identity** key, binding the identity pubkey to the MLS leaf
signature key. Haven never publishes this event to relays — but **any co-member
can extract the proof from the ratchet tree and rebroadcast it**, publicly and
verifiably binding the user's Nostr pubkey to MLS participation. This is
irreducible: co-members necessarily see the credential to validate the group,
and the proof is self-authenticating wherever it lands. Accepted; it discloses
only *that* the pubkey participates in Marmot MLS, and when that leaf was
signed — never message content,
group membership sets, or location data.

#### Convergence-buffer flooding (upstream #757 — closed, not fixed)

The Dark Matter engine persists out-of-order / future-epoch inbound messages in
a durable stored-convergence buffer that currently has **no per-group cap and
no eviction API**. A malicious co-member can flood a group with future-epoch
messages and grow the on-device `session-v2.sqlite` without bound. Haven mitigates
at intake with rate-limit-plus-backpressure (Security Rule 12 — never a silent
drop, because future-epoch catch-up after an offline period is legitimate
backlog), but an intake cap only throttles: once a message is ingested the
engine owns its durable storage, so Haven **cannot bound engine storage**.
Upstream closed #757 as not planned on 2026-10-01 with no fix, so the gap is
unchanged at v0.10.4 and this stays an accepted insider-threat storage-DoS
exposure.

#### A catch-up window the pager cannot finish (NIP-77)

The catch-up pager holds a circle's cursor whenever its chase cannot prove the
window drained: a spent page budget, an unfinished read, the deadline, or a
same-second page that no `until` steps below (C10 in
`docs/BACKGROUND_SHARING_FAILURE_ANALYSIS.md`). Since R4 a sweep also
reconciles each circle's window over NIP-77 after its pager passes
(`haven-core/src/relay/negentropy.rs`). A window the pager could not finish
completes (`reconciled_window`, `haven-core/src/relay/catchup.rs`) only when
every relay of the routing answered a pass covering it whole — not refused,
not failed, not saturated at 16 384 ids — and every id that relay reported and
the device lacked was taken in, or was judged final for that route: refused by
the screen before authentication, asked of the relay that reported it and
absent from its `EOSE`-ended answer, or dropped by the pool's expiry screen. A
routing with any relay that does not speak NIP-77 keeps the pager's rule, so a
window that cannot drain stays held and is never claimed (T-NIP77-FALLBACK).
What a pass fetches goes in through the ordinary stored-batch path: ordered
(`order_for_ingest`, below), its current-epoch commits held until they are
taken in (`SendHeld::StoredInput`), and an object answered `ResourceRefused`
never counted as resolved. Judging a screen-refused id final rests on Rule 16:
`verify()` binds the id to the bytes (see "Relay events are verified by Haven
before anything acts on them").

#### Ingest order: a commit never ahead of the proposal it commits

MDK drops for good a commit it takes in before the proposal it commits, and
keeps the commit's transport id as processed, so no redelivery brings it back
(`docs/MDK_UPSTREAM_TRACKER.md` T-COMMIT-BEFORE-PROPOSAL). A member catching
up after a `SelfRemove` is handed exactly that by a relay serving newest
first, a same-second pair whose ids tie-break the wrong way, a leaver whose
clock runs ahead of the committer's, or a page cut between the two. The
member then stays on the old epoch with the eviction due, makes a rival of its
own, and the circle can split for good. So every receive plane orders each
stored batch before the engine sees it (`SessionManager::order_for_ingest`):
ascending `(created_at, id)`, then every proposal at the circle's current
epoch moved, stably, to the front.

- **What the ordering reads.** It reads the exporter through the live
  session's read guard (one session, Rule 14), with the fixed label (Rule 11).
  The guard is dropped before any peel. The secret moves, without a copy, into
  a snapshot that is dropped before the first ingest (Rule 7). Each event is
  peeled with the preview peeler, and only `(kind, source_epoch)` is read off
  the MLS framing before the inner bytes are dropped. That framing is the
  cleartext handshake the engine peels anyway; no location plaintext is
  involved.
- **What it costs.** One ChaCha20-Poly1305 open per event and no extra REQ.
- **Failure handling.** If the exporter cannot be read, or the ordering
  panics, the batch keeps the order it came in. An event whose own peel or
  parse fails is treated as neither proposal nor commit and keeps its sorted
  place. Nothing is dropped, nothing errs, and nothing is logged, counts
  included (Rule 15).
- **Forged or junk events.** A relay holds no exporter, so what it forges
  keeps its place. A member can make an event look like a proposal, which
  only moves it earlier.
- **Catch-up pager.** It orders each page. A page the chase goes on past
  holds its current-epoch commits until a later page that brought something
  is ingested, and releases them at the chase's end. At every halt (page
  budget, an unfinished read, the deadline) a held commit is recorded as
  deferred instead: it holds the cursor, and the next sweep fetches it again
  (`a_held_eviction_a_halted_chase_never_paged_past_is_deferred_to_the_next_sweep`).
- **No location is sealed past a held commit (Rule 10).** Such a commit may
  remove a member, who would read what this device seals at the epoch before
  it. So while a circle holds a fetched current-epoch commit it has not taken
  in, the driver's seal is deferred, typed, as stored input still owed to the
  circle (`SendHeld::StoredInput`), and nothing is dropped
  (`SessionManager::holds_unread_input`). Two holds feed it:
  - *The pager's*, by event id: a commit is held from the moment its page
    holds it back — not only at a halt, so a seal racing the chase's next
    page is held too — until an ingest on any plane takes that event in,
    with any answer but a want of room (processed, rejected by the protocol,
    invalidated, buffered or retained), so a commit the engine rejects never
    holds sharing back; MDK's `ResourceRefused`, its want of room, is not
    such an answer and leaves the hold standing. No pass that completes
    without it ends the hold, and a join of the group anew — a Welcome
    accepted over a removed copy, or a replacement offer consented to — ends
    every hold of the copy it replaced. While the
    cursor is held below a deferred commit every sweep fetches it again, and
    the live plane's REQ from the cursor asks for it too. A relay that served
    it and then withholds it from every plane keeps the hold — fail closed,
    never silent: every seal answers `SendHeld::StoredInput` — until it is
    taken in or the process restarts (the hold is in memory, and nothing
    fetched survives a restart).
  - *The live plane's*: whatever a REQ holds of its stored replay, counted
    under the lock its flush releases under, until it is taken in — at an
    endpoint's `EOSE` or `CLOSED`, a pause, the release of a relay silent
    past `EOSE_WAIT` (the foreground's own timer, a burst's wait, a health
    tick), the worker's exit, or the count or byte cap. A relay left out of
    its REQ's coverage — not connected, or refusing, when the REQ went out,
    its debt recorded — sends no stored replay at all: what it sends is
    taken in as it comes, and never holds a seal.

  This covers the foreground's seal too: it does not wait for an `EOSE` the
  way a burst does
  (`no_location_is_sealed_while_a_halted_chase_holds_a_fetched_commit`,
  `a_seal_racing_the_next_page_of_a_chase_is_held`,
  `a_pass_that_completes_without_the_held_commit_never_ends_the_hold`,
  `a_held_commit_the_live_plane_takes_in_ends_the_hold`,
  `a_held_commit_a_plain_ingest_takes_in_ends_the_hold`,
  `no_location_is_sealed_while_a_live_req_holds_its_stored_replay`,
  `session::tests::a_relay_left_out_of_coverage_sends_no_stored_replay`).
- **Refetch by id.** It orders what each REQ brings back.
- **Live plane.** It holds what each REQ's endpoints send ahead of their end
  of stored events, and takes the REQ's batch in, ordered, at any endpoint's
  `EOSE` or `CLOSED`. It takes in every REQ's batch at a pause, when a relay
  silent past `EOSE_WAIT` is released (and once more after the release, for
  what arrived while the first flush ran), at the worker's exit, and when
  `WORKER_QUEUE_CAP` events, or `STORED_REPLAY_BYTE_CAP` (8 MiB) of their
  content, are held. That is always before the cursor
  anchor, before the settle a burst waits on, and before the pause ack, so
  Rule 12 holds: nothing is dropped, and no claim gets ahead of what was
  applied. What arrives after an endpoint's `EOSE`, or after its release, is
  taken in as it comes. A background burst rides the same worker. The first
  `EOSE` keeps today's latency, and the release runs before the burst seals,
  so a removal the burst received is applied before its location is
  encrypted (Rule 10;
  `a_removal_a_fast_relay_serves_is_applied_at_its_eose_while_a_slow_relay_stalls`,
  `a_removal_a_relay_serves_before_it_stalls_is_applied_before_the_burst_seals`).
- **Tests.** `haven-core/tests/commit_before_proposal_e2e.rs` covers every
  plane, the fail-open arms, and the four Rule 10 cases. The worker's pause,
  `CLOSED`, count and byte flushes are covered by
  `relay::live_sync::supervisor::stored_replay_tests`. The second flush after
  a release has no deterministic test: it closes an interleaving of the
  worker's hold with the first flush's lock.

**Residuals.**

- A proposal that reaches the live plane only after its REQ's batch was taken
  in, from a slower relay after another relay's `EOSE` — or from a relay that
  chooses to serve the commit without the proposal before its own `EOSE` — is
  not ordered with its commit.
- A live REQ carries no `limit`, so a relay's own default clamp can cut its
  stored replay between a proposal and its commit; a member can engineer the
  cut with same-second junk. The commit is then taken in alone, as above.
- A pair at a future epoch cannot be classified before that epoch arrives. MDK
  retries such deferred rows in insertion order.
- On the foreground's full planes, this device's own auto-commit for the
  proposal can fall due before the commit is taken in. Convergence settles
  the rivals, as it does for real-time arrivals.

#### Publish resolution: what the engine replays, and what Haven owes it

Rule 12's "never silently drop legitimate backlog" has a second edge, and it is
not on the intake side. Between staging a commit and resolving it the engine
BUFFERS everything that arrives for that group, and both resolutions — the
fanout driver's confirm and its rollback (`confirm_published_fanout`,
`publish_failed_fanout`) — end in the engine's replay. That
replay is delivered **at most once**: the engine marks the content row processed
in the same breath as handing it to the application, with no acknowledgement
boundary, so every redelivery afterwards is terminal. A caller that resolved the
ref and discarded the batch lost the peer's position permanently — no re-fetch,
no later convergence pass and no restart brings it back. Haven therefore
persists inside the call, before the resolution returns, and keys the write off
each event's own group id because the engine's buffers are process-global and
one batch can span circles. The same replay carries the next eviction in a leave
cascade and the local user's own re-proposed leave, so a commit or proposal in
it is recorded and driven, never dropped; an `Err` from a
confirm is returned unchanged after the stranded buffer is drained, because at
this pin the merge precedes the replay and a retry or a rollback would act on a
commit the group may already hold. Contract and evidence:
`MARMOT_PROTOCOL_KNOWLEDGE.md`, "What a resolved publish hands back".

**Accepted residuals.** Each is stated where the code makes it, and none is
optional to record:

- **A send drain still drops the engine's RESYNC signals.**
  `PendingCommitRecovered` / `GroupHydrationRecovered` arriving in a send's own
  batch get a bucketed note (`note_dropped_resync_events`) and are not surfaced,
  even though Rule 13 calls the first a MANDATORY resync. The reviewed plan for
  this work specified deleting that function once the fold surfaced the events;
  it was kept instead, because surfacing them means widening the seal's FFI
  return for a signal the RECEIVE path already drives
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
- **A queued invite released by a later advance keeps its Welcomes.** The
  hold that releases it records the commit, and its Welcomes go to delivery
  records over the routes kept when the invite was asked for (above), pinned by
  `released_intent_e2e::a_queued_invite_released_by_the_deferred_send_repair_keeps_its_welcome_obligation`.
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
  batch already handed back is still folded and its replayed locations still
  persisted. What that
  test does NOT cover is the Rule-15 capture of the cap's own warn — the fold is
  private, so no integration test can reach it, and the library test binary's
  single `log` slot belongs to `relay::manager`'s capture; the warn interpolates
  nothing but a bucketed count and is covered statically by
  `scripts/ci/check_no_identifier_logging.sh`. The fold's cap loses no
  schedule: the groups that never got their advance keep theirs in the engine,
  which re-marks them pending on the next advance, and the cap names what it
  stands down from in its own warn rather than stopping silently. What bounds
  a DRIVE is its wake's budget, not a step count: a record it cannot see
  through is not begun and stays stored, staged and unattempted
  (`receive_ladder_e2e::a_drive_stops_at_its_budget_and_every_record_it_did_not_reach_stands`).
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
  membership change does not re-key on a timer. See "Self-update: post-join
  performed, periodic disabled (M5)" below for the accepted forward-secrecy
  deviation.

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
(4 days: NIP-59's 48 h backdating, a day of the Welcome outbox's retries
and a day of slack, decision 231) —
and backgrounded on **iOS** the inbox REQ rides every `INBOX_BURSTS_PER_REQ`-th
publish burst rather than a held socket, so an invitation is picked up at a
publish instant. An account with nothing publish-eligible has no publish
instants, so its invitations arrive on the next foreground; both are stated under
"iOS background sharing: presence only at publish instants (P4)" below. The 2-minute figure below is the **retained short-poll fallback**
(`liveSyncEnabled = false`): there, Welcome events are polled on a
foreground timer jittered uniformly over `[90, 150] s` (2 minutes nominal) — from the inbox list only (`inboxRelaysProvider`: the stored
list kind 10050 is built from, or the compile-time seed while seeding has
failed), over the engine's own 96 h
window (widened from 49 h by decision 231: a wider `since` on the same REQ,
asking each inbox relay for more stored wraps, and no new REQ) — the resume hook in `map_shell.dart` performs an immediate
fetch on app foregrounding, and background polling is not active on either
platform — invitation discovery is foreground- or resume-driven only.

MIP-00 single-consumption KeyPackages (without the `last_resort`
extension) admit a race where two inviters consume the same KeyPackage
before the invitee can rotate. The post-Welcome rotation in MIP-02 is
designed to close this window; longer invitation polling enlarges it
proportionally because the invitee's rotation lags processing of the
Welcome.

Fallback foreground worst-case (`liveSyncEnabled = false`): ~2.5 minutes between
Welcome publish and local rotation if the user is foregrounded but not actively
resuming; cold-start latency is bounded by the resume hook (sub-30 s). Under
live-sync the Welcome is delivered live, so this consumed-KeyPackage window
shrinks to delivery + processing latency (seconds).

Mitigation and residual (M5):

- Haven makes the post-join self-update MDK records at every join (see
  "Self-update: post-join performed, periodic disabled (M5)" below), which
  rotates the joiner's Welcome-derived leaf once the circle is caught up and
  quiet; it does not run on a timer. The forward mitigation — `last_resort` KeyPackages, which are
  not single-consumption — **landed at the Dark Matter cutover**: every
  KeyPackage Haven now mints is marked `last_resort`, so a welcome consuming
  it no longer deletes its private material and the consumed-KeyPackage race
  above is structurally closed (the described residual is historical for
  pre-cutover clients).

### KeyPackage private material: where it lives and when it is deleted

The KeyPackage an account publishes is tracked in MDK's durable
`KeyPackageLifecycleState`, inside the SQLCipher MLS database: the package, its
`d` slot and the signed kind-30443 event exactly as it was first published.
Haven keeps no table of its own (`TrackedKeyPackage`,
`haven-core/src/nostr/mls/manager.rs`; at rest:
`kp_lifecycle_e2e.rs::the_tracked_key_package_is_encrypted_at_rest`).

Security Rule 5 for this material — no init key outlives its use:

- **Consumed ⇒ replaced.** A `last_resort` package survives the Welcome that
  uses it, so it is replaced instead: the engine records the consumption and
  the next maintenance tick mints a replacement into the same slot
  (`a_welcome_that_consumed_our_package_owes_a_replacement`, FFI
  `tc16_a_consumed_key_package_is_replaced_in_the_same_slot_via_real_ffi`).
  The same happens when the tracked package is no longer one this device
  durably owns.
- **…unless an invitation is being held — for at most 72 hours (a deliberate,
  bounded retention).** Haven holds a Welcome un-ingested until the user
  accepts it, and replacing the consumed package deletes its key at the first
  acknowledgement — which would kill every other invitation made for that
  package before the user has answered it. So while an invitation is held
  unanswered, the consumption-triggered replacement waits.
  - **Anyone can cause the hold.** The preview that makes Haven hold an
    invitation is authenticated only by its NIP-59 seal, so a stranger's
    invitation — one the user never answers, or that could never be opened —
    holds the replacement exactly as a friend's does. That is why the hold is
    bounded, and why an invitation that arrives during it does not move the
    bound.
  - **The bound.** The replacement waits at most
    `CONSUMED_KEY_PACKAGE_HOLD_SECS` = 72 hours, counted from the first
    maintenance tick that waited (its instant is kept in `user_settings`, never
    logged). After that the package is replaced even if an invitation is still
    held; that invitation then ends as "ask for a new invite". The bound
    belongs to one consumption: the next acknowledged replacement clears the
    record, and a package consumed later then starts its own — unless that
    clear was lost (residual 3 below), in which case it gets a shorter hold or
    none, never a longer one. A start that cannot be written aborts that tick,
    its rotation included, and the next tick tries again; the `not_after`
    deletion has already run by then and stays the bound.
  - **The clock cannot restart or resume it (fail towards deletion; decision
    taken by the coordinator under the owner's standing directive).** The 72
    hours are read on the device clock. A tick at which that clock reads
    earlier than the recorded start ENDS the hold — the replacement proceeds —
    instead of starting the count again. A hold that has ended, by running
    out or this way, is recorded as ended and does not resume wherever the
    clock goes next; only the acknowledged replacement clears that record.
    Only an absent or unreadable start begins a hold, and it begins exactly
    one. The cost is rare and honest: after a backward clock correction larger
    than the time already waited — a clock reset by a drained battery is one
    — an invitation still held ends as "ask for a new invite". What this does
    not close: a backward step that lands at or after the start leaves the
    hold running until the clock again reads start + 72 hours, so it lasts
    longer in real time by the size of the step, and someone who controls the
    device clock can repeat that — as they can put off rotation and the
    `not_after` deletion, which read the same clock.
  - **What is retained, and for exactly how long.** The private material of a
    KeyPackage a Welcome has consumed, until a relay ACKNOWLEDGES its
    replacement. The replacement is published by the first tick at which no
    invitation is held, the first tick at or after 72 hours from the first
    waiting tick, or the first tick at which the clock reads earlier than
    that tick, whichever comes first. Ticks run only while Haven runs
    (every ten minutes in the foreground), so both ends are ticks that
    actually ran: the first waiting tick can come later than the consumption,
    and the tick that ends the hold later than the 72 hours. With no relay
    acknowledging, the key lives on to the outer bounds, which the hold never
    moves: the first relay-acknowledged replacement after the package's
    rotation point (0.75 of its lifetime — 63 days after `not_before` for the
    84-day lifetime MDK mints), and failing that the first tick at or after
    its `not_after` (84 days and one hour after `not_before`), which deletes
    it with no network at all.
  - **Never held back:** rotation, the replacement of a package whose bundle
    is lost, and the `not_after` deletion.
  - **Three bounded residuals, accepted.** (1) After a restart the held copies
    are gone and the poll brings them back one at a time; if the user answers
    the first one back before a second has been polled back, nothing is held
    in memory, the marker is cleared, and the second invitation — once the
    replacement is acknowledged — ends as "ask for a new invite". (2) A
    replacement that was already staged (minted and signed, waiting for its
    first acknowledgement) when an invitation comes to be held is not held
    back: the tick republishes and promotes it. (3) The hold record is cleared
    after the promotion, in a different database; a kill between the two, or a
    failed delete, leaves it, and the next consumed package then gets a
    shortened hold or none — its held invitation ends as "ask for a new
    invite". Never a longer one.
  - The spec allows the retention (replacement after consumption is a SHOULD;
    a last-resort key MAY be kept after a Welcome,
    `foundation/key-packages.md:86-91`). Pinned in
    `haven/rust_builder/src/api.rs` by `tc18` (the hold), `tc18b` (a decline
    releases it), `tc19` (it survives a restart), `tc20` and `tc21` (what is
    never held back), `tc23` (72 hours and no longer, across a restart),
    `tc24` (a late invitation cannot extend it), `tc25` (a new consumption
    gets its own),
    `tc26` and `tc27` (the marker at an acknowledged replacement), `tc28` (a
    clock set back behind the start ends the hold); and in `haven-core` by
    `a_consumed_key_package_waits_for_a_held_invitation_for_72_hours_from_the_first_wait`,
    `a_clock_set_back_ends_the_hold_and_nothing_resumes_or_restarts_it` and
    `an_unreadable_hold_start_gives_exactly_one_bounded_hold`.
    Decision taken by the coordinator under the owner's standing directive
    (`docs/MDK_UPSTREAM_TRACKER.md` `T-KP-RETENTION`); the owner may overrule
    it.
- **One maintenance tick at a time.** Two overlapping ticks would each mint,
  and the second promotion would delete the first package's key while a relay
  still served it. The tick holds a per-account lock from its sweep to its
  promotion (`SessionManager::key_package_tick`;
  `tc17_overlapping_ticks_publish_one_key_package_into_one_slot_via_real_ffi`).
- **Superseded ⇒ deleted at the confirmed replacement.** A replacement is
  staged, signed once, and republished unchanged until a relay acknowledges
  it; on that acknowledgement the superseded package's private material is
  deleted — not at its `not_after`, up to 84 days later
  (`superseded_kp_material_deleted_on_confirmed_replacement_not_at_not_after`).
  Haven never keeps MDK's `RetainedKeyPackagePrivateMaterial` past that point.
- **Expired ⇒ deleted.** Whatever is still held at `Lifetime.not_after` is
  deleted on the next tick, before anything touches the network
  (`sweep_expired_key_packages`). MDK's own delete and promote validate the
  package first and so refuse one whose lifetime has lapsed; Haven deletes
  that bundle by its ref through its second storage handle (finding it loads
  every stored bundle, the live one's included — MDK has no delete-by-ref and
  no keys-only listing — and only the storage keys are read)
  (`an_expired_key_package_bundle_is_still_deleted`,
  `an_acked_replacement_is_promoted_even_when_a_retired_bundle_has_expired`;
  `docs/MDK_UPSTREAM_TRACKER.md` `T-KP-EXPIRED-DELETE`).

A heal publishes the frozen event byte for byte, so nothing on the heal path
signs, stamps or mints (`a_kp_republish_is_byte_identical_to_the_frozen_signed_event`).

### Epoch stall: a circle that fell behind walks its own history (T-EPOCH-STALL)

A device that missed one commit keeps receiving its circle's later traffic
and can open none of it. Haven runs MDK's epoch-stall detector
(`haven-core/src/nostr/mls/epoch_stall.rs`, ported from `marmot-app`): eight
distinct undecryptable kind-445s at one stalled epoch — or a want of room,
which arms at once — arm a walk of that circle's own history down to its
start (`RefusedRedeliveryLedger::owe_range`, walked by `Refetch::by_range` in
the next sweep, asked for on the live plane through `RefetchOwed`). A commit a
relay served late, under a timestamp no forward sweep reaches, comes back that
way (`a_circle_that_missed_a_commit_backfills_its_history_and_catches_up`).
Only a claimed foreground's ingest arms one; a plane that only finishes opens
no walk. Traffic older than this copy's Welcome is not evidence.

**The walk is bounded** (`INV-R-STALL-BACKFILL-BOUNDED`): at most one arm per
stalled epoch, then one paced re-arm an hour while the circle stays wedged —
except that a walk which brought back something it could not take in re-arms
at once (`rearm_refused_groups`, MDK parity), its next walk paced by the
refused range's doubling waits (`refetch_spacing_secs`: a minute, doubling, at
most a day; a new epoch makes it due at once) —
only inside sweeps the app already runs or the live plane's `RefetchOwed`,
and with no new REQ shape: the walk asks the circle's own `#h`, which the live
REQ already names.

**`Stalled` is the relays' verdict, never a count.** Three walks that each
reached the circle's start with every relay answering, and that brought back
nothing that moved this device, name the circle `Stalled`
(`RecoveryCause::Stalled`); the evidence survives a restart, and a join or an
epoch move ends it. An arm count never does: a flood of minted envelopes can drive arms
(`epoch_stall.rs`, `EPOCH_STALL_ESCALATION_ARM_THRESHOLD`), and reading this device a message a peer sent at
its current epoch ends the run's evidence while keeping its pacing, so a live
peer keeps a flooded circle from reading `Stalled` and the flood still walks
at most hourly — unless it fills the deferred-peel cap, whose refused walks
re-arm at once, paced by the doubling waits
(`a_flood_of_minted_envelopes_walks_history_at_most_hourly_and_a_live_peer_keeps_the_circle_unstalled`).
`Stalled` triggers no automatic action.

**Residual (OI-4, accepted).** An outsider flooding undecryptable envelopes
into a QUIET circle — no peer message read for two hours or more (three
fruitless walks, an hour's pacing apart) — can make
it read `Stalled`: the envelopes cannot be told from a real stall by design.
MDK has the same residual. The copy is non-destructive and offers no retry.

### Self-update: post-join performed, periodic disabled (M5)

Haven makes the one post-join self-update MDK records at every Welcome join
(`protocol-core/joining.md` step 14: "as soon as practical"), and disables
periodic self-update (a MIP-03 SHOULD). MDK v0.10.4 enrols every new group in
periodic rotation by default (`PeriodicMaintenancePolicy::EnabledForNewGroups`),
so the session sets `PeriodicMaintenancePolicy::Disabled` at open, before any
create or join (`SessionManager::open`, pinned by
`the_session_never_enrolls_a_group_in_periodic_rotation`).

**The post-join self-update.** MDK writes a `PostJoin` maintenance obligation
at every join (`cgka-engine/src/group_lifecycle.rs` 52-105); only its
forbidden account crate drives it, so Haven does, state-derived from MDK's own
record (`SessionManager::settle_post_join`, `docs/MDK_UPSTREAM_TRACKER.md`
T-MAINT-DRIVER). The obligation is open exactly while this device is a member
and its canonical leaf is still the one it joined with: a confirmed
self-update, a repair or any own commit that rotated the leaf completes it; a
self-update branch selection later withdraws opens it again; a removal fails
it. A full drive (`Publishing::resume` in `DriveMode::Full`: the live plane's
foreground drive, the bridge's resume in the poll configuration, the
foreground catch-up) makes it once the circle is caught up in this session,
stable, settled, holds nothing of this device's staged, recorded or queued,
holds no pending proposal, and MDK's account crate's windows have passed —
15 s after the end of stored events, then a 60 s quiet window that any epoch
change or accepted proposal restarts, then the obligation's own jitter (at
most 30 s). Those are earliest-allowed times the full drives already running
serve; nothing arms a timer, and no plane that only finishes (a burst, the
foreground service, WorkManager, a background catch-up) makes one. One is made
per resume, and the next circle's waits a CSPRNG gap of 2-30 s more, so two
circles' self-update commits never share a second
(`INV-R-PER-CIRCLE-PUBLISH-DECORRELATED`). One every relay proved it refuses
(a wrong device clock's `invalid:`, a relay's `blocked:`) is rolled back, and
the next waits out the wait that rollback earned, doubling from a minute to an
hour, as another earliest-allowed time: refusing relays are never asked again
at the spacing gap (`post_join_may_stage`, proved by
`self_update_e2e::a_refused_post_join_self_update_is_made_again_only_after_a_doubling_wait`).
That wait holds no location send, so it never reads as a departure due. Residual: on the first foreground
after an install upgrades, each circle this device joined makes its one
self-update within minutes of the others — one rare commit per circle, close
together in time, which a relay archive holding two of them can still
correlate.

Every new join therefore holds the joiner's location sends as *awaiting
relays* until a relay acknowledges its self-update (Rule 13.4): the spec's
"before sending application payloads when feasible" is met.

**No drain authors one.** MDK queues a self-update it cannot make now and
drains it later with none of Haven's gates; the hold that queued it retires
it, and so does the hold of every full advance before it can drain
(`SessionManager::send_self_update_now`, `retire_queued_self_updates`). A
self-update a kill left staged with no record has its durable evolution
deleted before the engine opens, so hydrate clears it instead of restoring it
under a pending ref of its own (`clear_unrecorded_self_updates`); a repair
cleared that way is told as undone. Guarded by
`scripts/ci/check_self_update_sites.sh`; proved by
`self_update_e2e::no_wake_or_elapsed_time_ever_authors_a_self_update`.

**Periodic self-update stays disabled.** Rationale (Haven's own — NOT
attributed to White Noise): leaf rotation on a timer is a commit per member per
interval, each holding its circle's sends until acknowledged, for a gain the
repair and membership changes already cover; the owner keeps it off.

**Residual fork surface (closed for membership commits since M11):** concurrent
MEMBERSHIP commits by multiple admins from the same epoch were a fork risk while
add / remove / demote eagerly finalized on publish-success. The adopt-winner
convergence is the fix — since the Dark Matter migration it is **engine-owned**
(deterministic `CommitOrderingKey` branch selection inside the MDK engine
replaced Haven's hand-rolled `converge_commit` + M6 settle-window, both
deleted) — and since M11 (live-sync enabled by default) it takes production
effect: add / remove / demote finalize through the publish-then-confirm
converging path, so a same-epoch multi-admin membership race deterministically
adopts the protocol winner instead of forking. A self-update converges the
same way: it is `Ordinary`, so a tied privileged commit wins over it, and the
lower committer wins between two ordinary ones (`protocol-core/convergence.md`
358-362). A leave is a
`SelfRemove` **proposal** (not a self-finalized commit); it converges on the
receiving admins' side via the REV-1 drivers, which harden the distributed
`SelfRemove` case (see "Bounded leave-removal window under live-sync" and
"Superseded commit during multi-admin convergence" below). The **retained
short-poll fallback** (`liveSyncEnabled = false`) stays out of this: there the
convergence primitive is compiled but the eager-finalize paths run — a rollback
build reopens the same-epoch membership-race window until it is flipped back.

**The repair.** Any member may tap Repair on a circle whose delivery broke:
a real self-update, rate-limited to one per circle per 24 h by the epoch-age
gate (`docs/EPOCH_ROTATION_REPAIR_PLAN.md`).

Accepted cost (forward secrecy / post-compromise security): after its
post-join self-update, a member's leaf is rotated only by its own repair or a
commit of its own that carries an update path, never on a timer. Consequences:

- If a device is compromised and its current-epoch leaf secret leaks, the
  attacker can derive every FUTURE epoch's secret until that member's leaf is
  rotated again — the exposure window is "until that member's next repair or
  the group's next re-key", not the ~1 h a periodic rotation would provide.
  The 5-epoch exporter-secret prune does NOT rotate the leaf key, so it does
  not bound this.

Accepted by the project owner; re-enabling periodic rotation remains an owner
decision.

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
> with `settlement_quiescence_ms = 0` (no settle delay; since the MDK v0.10.4
> migration MDK's pinned v1 policy, 1 s, which `open` requires), and a peer's
> `SelfRemove` proposal is auto-committed by every remaining member's engine
> (`PublishWork::AutoPublish`, confirmed only on a ≥1-relay OK-ack per Rule
> 13). Driver 1 is therefore engine-owned and stronger — no windowed deferral
> exists anymore — while Driver 2 is now the driver's leave, carried on at
> every wake from an intent the core holds. The bounded-window guarantee and the
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

- **Driver 2 — the leave carried on at every wake (the primary converger for
  the racing case).** The leave is the driver's (`Publishing::leave` /
  `resume_leave`): its intent is written to the circle store before the engine
  is asked, and from then no location of the circle is sealed or sent on any
  plane. Rust arms no timer for `resume_leave`, so each wake carries every
  circle's leave on (`haven/lib/src/services/leaver_backstop.dart`, at most
  once a circle a wake): the foreground's health tick, start-up and resume,
  each iOS burst, each Android foreground-service cycle and each WorkManager
  wake — and, in the foreground only, a group update a poll or the live plane
  reports and the leave's follow-up (at the soonest wait the core named, or
  15 s doubling to the health tick's cadence where it named none). A wake
  honours the wait the core named for each circle except on a group update,
  which asks past it (the update may be the commit that ends the leave); the
  relay schedule stays the core's, per record, either way. Within an epoch the
  retry is the engine's own stored proposal; for a later epoch the engine
  mints the next one, which any receiving member auto-commits once a competing
  window has cleared — what removes the leaver in the common racing case
  above. The leave ends on this device when its copy is marked removed, at
  once when MDK holds the circle unrecoverable (it refuses every outbound
  intent on a halted group, so no proposal could ever leave), or a day after
  the first press. A marker an older build left in
  `SharedPreferences` (the circle's public `nostr_group_id` only) is migrated
  once at start-up: its circle is left through the driver and the key is
  removed.

Net effect: a race-losing leave is retried as fast as the leaver's wakes come
— driven by Driver 2 in the common racing case: seconds while its app is in
front of its user, the next Android foreground-service cycle, iOS burst or
WorkManager wake otherwise (minutes; WorkManager's floor is about fifteen) —
until a day after the first press (`LEAVE_BOUND_MS`). That day bounds the
leaver's retries, not the group's convergence: at it the leaver ends the leave
on its own device whether or not any member committed its removal, and a
removal nobody committed stays in the group until an admin makes it (case (1)
below).

**Precisely-bounded residual (accepted).** The corroboration-gate carries NO
admin-side record of a departing member's intent (it deliberately never acts on
the peeked, unauthenticated `SelfRemove` sender, which closes a forged-removal
vector), so there is no automatic admin-side backstop: a stale ghost is
recoverable only by a normal manual admin removal. Crashing no longer
matters: the intent is durable, and the Android foreground service and
WorkManager carry the leave on without the app being opened. Two cases stay
automatically unconverged. (1) The bound: at `LEAVE_BOUND_MS` (a day after the
press) the leaver ends the leave on its own device whether or not any member
committed it, and if its last proposal was for an epoch the circle has since
left, no member ever commits that stale proposal. (2) No wake: the leaver's
device takes none before the bound — switched off, or background sharing off
with the app never opened again (every background carry-on runs only under
that consent) — while its `SelfRemove` was deferred or lost the order race.
In either case a stale roster ghost remains until an admin removes it. This is not a confidentiality regression for peers: the ghost is a
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

Haven does not drop an inbound event on its tag: a receiver must not judge a
message's validity by `expiration` (Marmot `transports/nostr.md:190-192`), and a
member can stamp a past one on a genuine commit every conformant peer applies.
Relays delete the event at the expiry, and `nostr-relay-pool` drops an
already-expired event before any subscriber sees it, judged by this device's
clock with no grace — so a device whose clock runs 228 s or more fast drops
every live location it is sent (`docs/MDK_UPSTREAM_TRACKER.md` T-NIP40-POOL).
Staleness is judged in presentation, on the MLS-authenticated inner timestamp.

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
    distinction and is the biggest remaining win.
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

`RECEIVER_EXPIRATION_GRACE_SECS = 60 s` is clock-skew slack in Haven's own
reasoning about how long a relay can still serve an event (the stored-input
sweep's horizon); it drops nothing and is **not** load-bearing for gap
coverage.

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
`seal_location_attaches_group_retention_expiration` and
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
  pool — plus the live session's own fanout drive pool while one runs
  (`LiveSyncCore::new_local`) and one more for every isolate that builds its
  own pool, so a shared relay can see up to three connections from the
  foreground isolate alone and can join them by
  source address with no protocol help (the accepted deviation `RC1` records
  this; "one client per relay" was the older, wrong framing).
  A relay that serves *both* a user's gift-wrap inbox (kind 1059 REQ
  filtered by `#p = <user pubkey>`) and that user's group messages (kind 445
  by `#h = <nostr_group_id>`) over the same connection can correlate the real
  identity pubkey with group membership by connection continuity — even
  though kind-445 events themselves carry only ephemeral author keys.
  Protocol design already separates inbox relays (1059) from circle relays
  (445), so this only bites when the *same* relay serves both roles for a
  user. Until 2026-10-31 that was the default: a new circle took the invitees'
  inbox relays, on a default install the same three seed relays as the user's
  own inbox. A circle created since then without named relays takes its relays
  from the location pool, never one on its creator's own lists and, while
  enough others are left, none an invitee lists (*The location relay pool*
  above), so on default lists the join no longer applies to it. It still
  applies to every circle created before that change, to circles other clients
  create, and wherever a member's own lists name one of the circle's relays — a
  user who later adds one to their inbox (the exclusion is applied at create,
  not retroactively), an invitee the pick had to fill from, or a member added
  later. Full mitigation needs per-fetch ephemeral connections or onion
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
  freezes the process — background delivery falls back to the short OS-wake
  sweeps described under "Scheduled background wakes (M7)" (which receive,
  carry a leave on and make no commit), which connect briefly and shut down. On iOS with background sharing
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
  to a relay over this socket. The live engine's **receive client publishes
  nothing**: what the live session sends — the engine's convergence auto-commits
  (per MIP-03), the post-join self-update, a leave's proposal, and a recorded
  commit or Welcome sent again byte for byte — leaves through the fanout driver
  on a publish pool of its own, every kind 445 under an ephemeral key, and only
  a foreground drive begins one. No background plane makes a commit: a burst or
  the foreground service's cycle only finishes what was begun (a recorded
  commit sent again, or confirmed on a stored acknowledgement), and every
  background plane, the OS wake included, carries a leave on (see "Scheduled
  background wakes (M7)"); a resubscribe re-issues REQs and publishes nothing.
  The receive client never holds your private
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
  between publish and confirm on that path is the same commit sent again.**
  A receive-side auto-commit is always removal-bearing, and the engine's
  hydrate deliberately short-circuits on exactly that (`staged_removes_member`),
  so it neither clears the staged commit nor emits `PendingCommitRecovered`; but
  every commit is staged under its durable fanout record, so the next
  foreground drive sends it again, byte for byte, and never rolls it back while
  a relay may hold it. No background plane makes one: the eviction stays due
  until the first foreground drive (residual 4 below).

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
  kind-5), deleted at the MDK v0.10.4 migration, left the same class of trail
  where it ran. This reveals nothing beyond what the
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
  retired kind-10051 relay list. (b) and (c) were scrubbed by a one-time,
  sentinel-gated retraction — a kind-5 NIP-09 deletion of the user's own 443
  by event id plus an empty replaceable kind-10051 — which the MDK v0.10.4
  migration deleted; the malformed-slot retirement of (a) stays. An account
  that never ran the retraction leaves (b) and (c) on its relays, and an
  uncooperative relay may retain them anyway (exposing only an init key already
  bound to the identity pubkey, and a superseded relay list) — a content-free
  lifecycle residual.

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
   (4 days), so at the shipped `INBOX_BURSTS_PER_REQ` every burst asks
   each inbox relay to replay **96 hours of gift wraps keyed on this device's own
   `#p`**, under a stable subscription id. Narrowing that window is not an
   available fix — NIP-59 backdates a wrapper by up to 48 h, a Welcome is sent
   again for up to a day after it was built, the last day is the clock-skew
   margin, and a wrap below the floor is lost *silently*, which is
   indistinguishable from an invitation that was never sent. The lever is the
   fold period, not the lookback.
4. **A crash mid-send no longer wedges a circle: every commit is made under a
   durable record (owner decision OD4-c; W9q retired its interim halves).** The
   underlying MDK behaviour is unchanged: a staged commit with no record that
   removes a member is kept by hydrate and never announced
   (`PendingCommitRecovered` is not emitted for it), and a re-fetched own
   commit comes back terminal (`OwnEcho`). What changed is that Haven no
   longer makes such a commit. A background burst, a session only started and
   the wake sweep make no commit at all: the eviction of a member who left
   comes due and stays due, nothing staged, until the first foreground drive
   makes it — unless another member's eviction is applied first. Every
   commit a plane makes is staged under its fanout record in the hold that
   staged it, so a process the OS ends between SEND and OK leaves a record the
   next foreground drive sends again, byte for byte, and never rolls back
   while a relay may hold it (`od4c_removal_deferral_e2e`,
   `live_plane_drive_e2e::a_started_session_and_a_burst_make_nothing_of_a_departure`).

   **What it detects.** A circle MDK halted is read as such on every circle
   read and after every restart, from MDK's persisted `unrecoverable` flag
   (`SessionManager::unrecoverable`; `CircleEngineState::Unrecoverable`;
   `RecoveryCause::Unrecoverable`), and reads live again the moment an
   authenticated rejoin repairs it in place
   (`a_rejoined_unrecoverable_circle_reads_live_again_in_the_same_session`).
   At v0.10.4 MDK sets the flag only on a missing retained anchor, a missing
   own-commit checkpoint or a frozen-pass integrity failure
   (`distributed_convergence.rs` 536-541, 1011-1030, 1448-1478), so it is
   authoritative: no second observation is waited for. Where the flag gates a
   commit or a roster stamp, a record that cannot be read counts as halted;
   where it is read for the user, it never fails the read, and a quarantined
   circle reads as quarantined. The pseudonymous `nostr_group_id` still
   reaches the bus as a refresh nudge when MDK announces a halt. No receive
   plane follows a halted circle, nor one MDK does not hold live in this
   process (quarantined): the sweep, a live session — whatever the app lists
   — and every NIP-77 pass leave it out (`CircleManager::routable_circles`),
   since it applies nothing it receives and its repair arrives on the inbox;
   its absence advances and ends nothing of it, so a circle the repair brings
   back is taken up from its cursor
   (`negentropy_e2e::no_plane_follows_an_unrecoverable_circle_and_its_absence_moves_nothing`).
   Its leave ends at once, as one at its bound does: MDK refuses every
   outbound intent on a halted group, so nothing could be sent for it
   (`left_circle_e2e::leaving_an_unrecoverable_circle_ends_at_once_and_sends_nothing`).

   **What remains.** (a) While an eviction stands due and unmade after a
   burst, that circle's sends are deferred until the next foreground — on a
   rarely-foregrounded device, a real gap in that circle's sharing, surfaced
   nowhere. (b) A device that ran a build before W9q may hold a staged
   eviction with no record from a kill inside a legacy publish window; hydrate
   keeps it, nothing at the pinned rev re-derives it, and it is not detected —
   the obligation table that once reported it is retired; and a commit such a
   build published with no record, which hydrate cleared, is retired at the
   open as one that never left the device (`cleared_at_open`), so a relay's
   copy of it is answered as a duplicate here. Only development and CI
   installs ever ran such a build: none of the v0.10.4 migration has been
   released. (c) An eviction a
   kill interrupted inside its own staging hold — between the engine's
   staging and the record's write — is the same state; another member's
   eviction commit applied here ends it (tracker T-KILL-WINDOW).
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
   still pending or not held live by the engine — and with no eligible circle there
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
   fetching a code) now costs a pause, a publish-pool reconnect and a 96 h `#p`
   gift-wrap replay each time, where before it cost nothing. Over a long
   background window the trade is clearly a win; over rapid app-switching it is a
   loss. A notification-shade pull is unaffected, because
   `AppLifecycleState.inactive` does not reach the pause path.
9. **A cold launch that backgrounds before its first engine start has been
   ISSUED comes up Live in the background.** The engine start is launched from
   the shell's startup tasks without being awaited, behind the install of the
   re-subscriber that owns it. A pause that lands while the start is in flight
   waits for it and pauses the session it produced. One that lands earlier
   finds nothing to pause, and on this branch the start then goes ahead —
   this process is the receiver, so a session is wanted — only started and
   unclaimed, with standing REQs and the 55 s pinger. Bounded by the first
   publish tick's own teardown in the ordinary case, and unbounded in residual
   7's case, where no tick is coming. The heal backstop cannot make this
   worse — the pause cancels it and only a resume arms it again — and it does
   not close it either. A session that DIES between bursts is started again
   by the next burst that finds none, straight into that burst
   (`start_session_into_burst`, decision 190), with the burst's measured
   budget.
10. **A teardown can cut a drive in flight on the publish pool.** The
    publish-pool shutdown disconnects with no drain of its own; what drains
    first is the teardown's. Three drain: the iOS idle close and the burst
    teardown await every driver entry in flight
    (`NostrRelayService.inFlightDrives`), up to the burst's capped rounds of
    drives that start meanwhile, and give up if that read fails (each read
    waits only for the drives in flight at it, each bounded by the core's
    own budget, so no chain of overlapping drives holds a teardown); the Android
    foreground service's teardown awaits a location's seal and send only
    inside its one bounded drain (`kBackgroundTeardownDrainBudget`) and every
    other driver entry unbounded after it
    (`NostrRelayService.inFlightNonLocationDrives`, decision 252) — waiting a
    location drive out would outlast the resume's handover budget and push it
    into a force-release — and it reads its stop before each step (its
    drive, each circle's leave carry-on, the roster read, the registration,
    the one-shot fix, each seal, each send, each fetch's relay request and
    each fetched event), and latches its relay service at the stop itself,
    before the drains (`NostrRelayService.latch`): from then on the service
    hands out no pool and opens none, so a step that slips past a read fails
    before it reaches a relay, and only a call that already held the pool
    runs on — any other driver entry until it ends, a location's seal or
    send only until the bounded drain gives up on it and the pool is shut
    under it (one lost sample; a commit it carried stays recorded and
    awaiting); an open already under way finishes, is handed to nobody and
    is shut with the pool. Nor does anything after the stop open a session
    or build a relay service: `_ensureAuxServices` (reached from a free
    guard's acquisition, a wiring repair and the start-up bring-up — a
    reclaim never calls it) builds none after the stop and shuts, never
    installed, one whose open straddled it, and every session open
    (`_openCircleManager`, a reclaim's included) opens none after the stop
    and hands back one whose open straddled it (Rule 14). Three do
    not drain: the iOS opt-out release (`MapShell.releaseBurstPlaneOnOptOut`),
    the pause that hands no burst the pool, and logout. Security Rule 13 is
    **upheld** in every case — the core confirms no commit without a relay's
    ack, and one a cut drive was carrying stays recorded and is sent again at
    the next wake — so the exposure is a delayed send, and for a location at
    most one sample, superseded by the next tick.
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
    `active.group_subs`, which `subscribe_circle` and `unsubscribe_circle`
    mutate off a `circlesProvider` emission and the session's own routing
    follow mutates by itself — at every burst open, at every start, and
    whenever any plane moves a circle's row (`run_follow`). So the subscribed
    set is every **accepted** circle *as of the last foreground emission*
    (`LiveSyncResubscriber.groupsForCircles`), each listed where its row now
    routes, while the publish target is
    re-read **fresh** at seal time (`Publishing::seal_location` → `get_circle`,
    frozen into the location's record) and `filterPublishEligibleCircles` additionally excludes a
    circle the engine does not hold live (`CircleEngineState`: quarantined,
    disbanded or `Unrecoverable`) — so such a circle, while it is still
    subscribed, is re-anchored on every burst and never published to at all, a
    permanent mismatch rather than a fractional one. (c) A send that fails or is
    held by the driver (the typed `SendHeld`), and the tail of a
    roster past `kMaxCirclesPerBurst`, which the burst itself defers to the next
    tick. (d) A circle-set change applied **during** the background window. A
    circle the user **left** while backgrounded is unlistened by the follow its
    leave wakes, but one dropped from the roster any other way keeps its `#h`
    REQ re-anchored until the next foreground emission. A **relay-set** or
    routing-id change applied while backgrounded no longer splits the pair: the
    burst open follows the row, and the relays the circle left keep a REQ for a
    day with no `kind:445` of this device's behind it.
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
12. **A process the operating system launched in the background is not
    covered (open).** Everything in this section is about a process that was
    *paused*. On a device the lifecycle is never unset: both embedders seed it
    `detached`. But the binding reads it once, when `main()` initialises it,
    and a lifecycle message the engine receives before then replaces the seed
    with no dispatch. A later one is dispatched, every state on the way
    synthesised, to the observers registered at that instant
    (`ServicesBinding`, pinned by
    `haven/test/framework/lifecycle_synthesis_test.dart`): `detached` →
    `inactive` reaches an observer as `resumed`, `inactive`; `detached` →
    `paused` as `resumed`, `inactive`, `hidden`, `paused`. `main()` awaits its
    start-up work between initialising the binding and `runApp`, so the shell
    is normally not yet one of those observers. A shell therefore mounts under
    whatever the binding already reads, and its handlers run only for changes
    after the mount. Whatever it mounts under, the mount arms its publish
    scheduler, motion trigger, ownership heartbeat and hourly prune. Its
    start-up (`MapShell._runStartupTasks`) contacts relays only if the app
    reads `resumed` when it runs: otherwise the pool pre-warm, the KeyPackage
    publisher, a one-shot location publish to every circle where the
    location disclosure was accepted, the flag-off pollers and, five seconds
    later, a public-profile refresh and a retry of any own-profile publish
    left queued are owed to the first resume
    (`ForegroundStartUpGate`, driven through the binding in
    `haven/test/pages/foreground_start_up_gate_test.dart`). That debt is paid
    at the first resume, inside the resume's 30 s debounce too, once; and the
    lifecycle is read again after the await that opens the pool, so a pause
    landing meanwhile stops the rest of the contact and owes it, whole, to
    the next resume. Carrying on the leaves this device asked for
    (`_carryOnLeaves`) is part of that contact and reads the lifecycle again
    before each circle, so a pause stops it at the next circle — a call
    already under way runs to its end — and it also runs at every resume
    past the debounce; a burst, the Android foreground service and a
    WorkManager wake carry the rest on, claiming no foreground. What else the start-up runs
    regardless: the maintenance timers arm only in front, and the live-sync
    heal starts a session only where one is wanted.
    - Mounted under `detached`: no session is wanted
      (`MapShell.liveSyncWanted`) and no heal timer is armed. The first
      message after the mount is dispatched `resumed` first, so the resume
      handler runs with nobody looking — it opens the location cache, arms
      the foreground timers and the heal timer, re-arms the maintenance
      timers (on iOS inside that dispatch, so their arming gates pass),
      attempts a publish, runs the KeyPackage publisher and a profile
      refresh, and starts a session, which is not claimed for (the claim is
      read when the start holds its engine, and the lifecycle no longer
      reads `resumed` by then) — and pays what the start-up owed. Where
      that message is `paused`, the pause
      handler runs right behind the resume in the same dispatch, and this
      section applies, with residual 9 — the start can reach the engine after
      the pause's teardown, and the session then stands until the next
      burst's teardown. Where it is `inactive`, no pause runs: the session
      holds as in the next case, the heal timer ticks beside it, and the
      KeyPackage and relay-list ticks, gated at arming only, fire and contact
      their relays.
    - Mounted under `inactive` (neither the Android nor the iOS embedder
      sends `hidden`, so no binding rests on it at a mount there): the mount
      starts a session — unclaimed, staging nothing, arming no drive timer
      and no heal timer — that holds its group and inbox REQs and their
      sockets for as long as the process stays there, and the start-up's
      relay contact waits for the first resume. Nothing pauses the session
      while the process stays there, and its publishes are not bursts; if the
      app leaves `inactive` for the background, `paused` is dispatched and
      the pause handler runs then (iOS sends `inactive` from
      `viewWillAppear` whatever follows).
    - Mounted under `paused`: the shell takes the pause it was never
      dispatched (`pausedAtMount`). It stamps no foreground and, once the
      background-sharing consent has loaded (or 5 s after the iOS session
      arm began, if the platform has not answered it, with the consent still
      reading off — `kConsentArmBound`) — read earlier, the pause would take
      the branch of sharing off — runs the pause handler unless a
      lifecycle change has reached it since, so every branch's pause applies:
      on Android the heartbeat is cancelled and, with sharing on, the session
      handed to the foreground service; on iOS with sharing on the burst
      plane is installed and pauses what the start-up starts (residual 9: at
      the next burst's teardown), and a burst that then finds no session
      starts one into itself; with sharing off no session is started.
      The start-up's relay contact is owed to the first resume.

    The `inactive` cases are open on two axes only a device can settle: what
    the binding reads when the shell mounts, and where the launch settles.
    Closing them — starting a session only for a `resumed` that is not the
    synthesised one, or routing an iOS background launch with sharing on
    through the pause branch — waits on an owner decision. Host-side, the
    handlers dispatched back to back are run through `MapShell`'s statics;
    what a shell mounted under `inactive` starts and arms is read from
    source; what one mounted under `paused` does is driven through the binding
    (`haven/test/pages/foreground_start_up_gate_test.dart`), and that
    `MapShell` wires it so is pinned over the source
    (`haven/test/pages/map_shell_mount_lifecycle_test.dart`). No test, host or
    device, launches the app in the background, and that the seed is
    `detached`, and that the engine replaces it until the binding first reads
    it, are read from the Flutter engine and framework source.

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
profile (the retraction no-op gate `has_published_profile`, CI-enforced). A
profile the storage reset forgot is read back from the profile pool instead;
when no pool relay answers, the action fails rather than doing nothing
(`PROFILE_RETRACTION_UNVERIFIED`).
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
- **Fetch-side minimization.** Reads use the curated profile pool, one author
  per one-shot REQ from that author's assigned pool relay (no standing kind-0
  subscription; cached rows refreshed on tiered staleness), and never answer
  NIP-42 AUTH, so the relay cannot attribute the fetcher.

**Residual risks (honest limits):**

- **Permanence.** Kind-0 is a replaceable event, and replaceable ≠ erasable:
  relays, indexers, and archives retain revisions. Once published, the
  pubkey ↔ name/photo association cannot be reliably clawed back.
- **Viewer-IP leak to the picture host.** Viewing other members' photos
  contacts their chosen host (see *Network Threat Model*), including the
  attacker-chosen-host variant. Bounded by the anti-SSRF filter; not
  eliminated for legitimate public hosts. VPN recommended.
- **Roster-association leak.** Profile fetches reveal to each assigned pool
  relay which pubkeys a client is interested in (see *Network Threat Model*).
- **Best-effort delete, and the photo is NOT part of it.** "Delete public
  profile" republishes a blank kind-0 and emits a NIP-09 kind-5 deletion —
  both cooperative-server best-effort, and per the retraction no-op gate they
  only run when a profile was actually published. A blank some pool relay
  did not acknowledge is left owed and published again by the profile sync;
  the kind-5 is sent once. **No Blossom DELETE is
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
location traffic or their profile queries — never both. The pool is
host-disjoint from the account seed, the discovery plane and, since 2026-10-31,
the location pool (`tests/profile_plane_separation.rs`). The same day four
entries moved to `RETIRED_PROFILE_RELAYS`: `wss://nostr.mom`, run by nos.lol's
operator — nos.lol is on the account seed, so one operator saw both planes;
`wss://nostr.bitcoiner.social`, a second slot for offchain.pub's operator;
`wss://nostr.data.haus`, for falling reliability; and `wss://yabu.me`, which
the probe caught refusing kind-0 writes from whole networks by ASN. Their slots
went to `wss://nostr.sathoarder.com`, `wss://user.kindpag.es`,
`wss://relay.nostr.net` and `wss://relay.coinos.io`, so the pool still has
eight entries, and the startup prune removes the retired rows from upgraded
installs. Operator overlap is recorded at vetting; no test can check it. The
residuals below are owner-accepted; they are deviations of record, not open
bugs.

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
  `circles-v2.db` file plus its WAL/SHM/journal sidecars (`delete_circles_db_files`
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
