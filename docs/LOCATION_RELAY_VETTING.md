# Location-relay pool — behavioural vetting

The eight relays in `PRODUCTION_LOCATION_RELAYS`
(`haven-core/src/circle/location_pool.rs`) are the relays a new circle is given:
when a create names no relays, Haven draws three of them at random, leaving out
every relay the creator's own identity traffic touches and preferring relays no
invitee lists. Every member of that circle then publishes its encrypted
locations and commits there and reads them back from there. Choosing the pool
is a privacy decision and a reliability decision at once, and the constant's
doc comment lists nine admission criteria, (a) to (i).

Some of them are statements about Haven's own code or about the lists Haven
ships, and are pinned by tests that run on every push. **The rest are
statements about how eight servers Haven does not operate behave, or about who
runs them, and no test in CI can settle them.** This file is where that gap is
tracked, how it is closed, and what was found the last time anyone looked.

---

## The criteria, and who checks them

| # | Criterion | How it is checked |
|---|---|---|
| (a) | `wss://` on a public host | `location_pool_entries_are_wss_public_and_unique` (`circle/location_pool.rs`); a non-public entry is also never drawn (`pick_leaves_out_a_pool_entry_on_a_non_public_host`). Runs in CI. |
| (b) | Keeps an **unauthenticated kind-445** from a never-seen key, in the **location shape** (`h` + `expiration`) and the **commit shape** (`h` only), and serves each back by `#h` | **Probe only** — L2 and L3 below. |
| (c) | **No NIP-42 AUTH** on read or write; not paid, web-of-trust gated or kind-restricted against 445 | **Probe only** — L1 for reads; a paid, gated or restricted relay refuses L2/L3's write. |
| (d) | Answers **Haven's own NIP-77 session** with the probe event | **Probe only** — L4, gating. |
| (e) | One entry per operator; no operator shared with the account seed, discovery or profile plane | Domains: `location_pool_entries_have_distinct_registrable_domains`, `location_pool_is_host_disjoint_from_account_seed_and_discovery`, `location_pool_is_host_disjoint_from_profile_pool` (`tests/profile_plane_separation.rs`). Operators: **by hand** — the operator column below, pairwise distinct (Check 14b). |
| (f) | No TLS terminator or CDN shared with the account or discovery plane | **By hand** — the terminator column below, non-empty (Check 14b); compared against the account and discovery planes' terminators when it is filled in. |
| (g) | NIP-11 `limitation.max_subscriptions` ≥ 16 | **By hand** at vetting, from the relay's NIP-11 document; recorded in the notes. |
| (h) | 90-day reliability evidence, or a company or foundation operator | **By hand** at vetting; recorded in the notes. |
| (i) | Not another Marmot client's default inbox relay | **By hand**; editorial. |

Retention (L5) is evidence, not a criterion: whether the relay serves any
kind-445 older than 30 days.

### Why the probe checks what it checks

* **L1 — a signer-less `#h` read.** Haven's receive planes hold no signer and
  never answer a NIP-42 challenge (Security Rule 16). A relay that challenges on
  read is not degraded for a circle, it is inert — and inert silently: the
  members' fixes simply never arrive.
* **L2 — a location-shaped kind-445 from a fresh key.** Every location goes out
  under a key generated for that one event (Security Rule 2), so a relay that
  refuses unknown authors refuses every Haven send. The read-back is the point:
  an `OK true` followed by a silent drop looks like a published location that
  nobody ever receives.
* **L3 — a commit-shaped kind-445.** Commits ride the same relays and must stay
  there for a member who was offline when it was made. A relay that kept only
  expiring events would pass L2 and silently strand that member at the old
  epoch.
* **L4 — NIP-77, gating.** A commit buried past a relay's replay limit can only
  be found again by a NIP-77 pass (`MARMOT_PROTOCOL_KNOWLEDGE.md`, and tracker
  `T-NIP77-FALLBACK`, whose removal condition is that every relay a circle can
  use speaks it). Haven now chooses these relays, so it can meet that. The probe
  runs **Haven's own session** — `RelayManager::neg_probe_ids`, over
  `neg_prepare` and `neg_remote_ids`, the one session shape
  `scripts/ci/check_publish_client_no_subscription.sh` check 5 pins — with
  Haven's own negotiation wait. A relay that answers the opening message more
  slowly than that from your vantage is reported `unknown`, which is the truth
  about it for Haven from there. It passes only if the relay reports exactly the
  L3 event (the L2 event when L3 was refused) and nothing else.

---

## Why this is not a CI job

For the same reasons as the profile probe (`docs/PROFILE_RELAY_VETTING.md`,
"Why this is not a CI job"): a lane that dials eight third-party hosts goes red
on their outages, not on Haven's regressions; it tells eight operators when
Haven builds, every push, from a stable address; and criteria (b)–(d) cannot be
probed without writing to their servers. So the probe is opt-in, and its output
is checked in here.

---

## Running the probe

```bash
cd haven-core
HAVEN_PROBE_LOCATION_RELAYS=1 \
  cargo test --test location_relay_vetting -- --ignored --nocapture
```

The probe is `#[ignore]`d **and** env-gated: without the variable it prints a
skip line and returns, so neither `cargo test` nor `cargo test -- --ignored`
alone dials a third-party host.

It cannot rot unnoticed, because five **hermetic self-tests** in the same file
run on every `cargo test`, against in-process relays only, and print no relay
address: a relay that serves `#h` reads and keeps both shapes passes every
column (`location_probe_passes_a_relay_that_serves_445_reads_and_keeps_both_shapes`);
one that refuses the writes fails both write columns carrying its own reason
(`location_probe_fails_a_relay_that_refuses_445_writes`); one that acks and
serves nothing fails both as a silent drop
(`location_probe_fails_a_relay_that_acks_445_and_serves_nothing`); one that
challenges on read fails L1 as an AUTH failure
(`location_probe_fails_a_relay_that_demands_nip42_auth_on_read`); and L4 tells
a relay that answers with the probe event from one that refuses NIP-77, one
that stays silent, one that answers without the event and one that answers
with more than it (`location_probe_reports_nip77_support_of_each_kind`).

For each relay it:

1. connects a **signer-less** client, so an `AUTH` challenge reaches the probe
   instead of being answered;
2. **L1** — opens one `REQ {"kinds":[445],"#h":[<random>],"limit":1}`: `EOSE`
   is a pass, an `AUTH` challenge or a `CLOSED` a fail, silence `unknown`;
3. **L2** — publishes a location-shaped kind-445 and reads it back by `#h`;
4. **L3** — publishes a commit-shaped kind-445 under its own fresh key and reads
   it back by `#h`;
5. **L4** — runs Haven's NIP-77 session over the L3 event's `#h` and second;
6. sends a **NIP-09 kind-5** from the L3 key naming the L3 event (best effort,
   after L4 needed the event; skipped when the relay refused L3);
7. **L5** — asks `{"kinds":[445],"until":<now − 30 days>,"limit":1}`, read only;
8. prints the Markdown table below, then fails if any relay is short of a pass
   in L1–L4 — after reporting all eight. `unknown` is never a pass.

Each probe event is built with `nostr::EventBuilder` in the test, never
through the peeler or MDK: kind 445, signed by a key generated for that event,
tags exactly `h` (32 `OsRng` bytes, hex) and — for the location shape —
`expiration` = `created_at` + 228 s (`LOCATION_MESSAGE_RETENTION_SECS`), and
content the standard base64 of random bytes of a sealed location's length.

### Before you run it — what it costs

* **Your IP is disclosed to all eight hosts**, as a client that writes and
  reads kind-445 and opens a NIP-77 session. Haven ships no Tor or proxy
  support, and neither does this probe. Run it from a vantage point you are
  willing to associate with Haven maintenance — a VPN or Tor exit is
  reasonable — and note it under **Vantage**.
* **It writes two events to each server you do not own.** One location-shaped
  kind-445 that every NIP-40 relay drops 228 s later, and one commit-shaped
  kind-445 with no expiration, which a relay may keep **for good**: the kind-5
  that follows is best effort, and a relay is free to ignore NIP-09. Both are
  opaque by construction — every Haven, MDK or White Noise read names the `#h`
  of a group it holds, a random 32-byte `h` names none, and the random content
  fails authentication under every key — so they reach no client and decrypt
  for no one. They are, all the same, permanent writes to a third party's
  database, in the same class as the profile probe's kind-0.
* **It proves the pool at one moment, from one place.** A relay that adds a
  paywall, an AUTH requirement or a write filter next month will not announce
  it, and small relays die (the profile pool lost four of eight within months).
  Re-run before each release that ships a pool change, whenever circles
  created on the pool go dark in the field, and at least once a release cycle.

---

## Findings

**Status: VETTED — every pool entry passed L1–L4.**
**Last run: 2026-10-31.**

| relay | serves #h reads without AUTH | keeps a location-shaped 445 | keeps a commit-shaped 445 | NIP-77 | retention ≥30d | operator | terminator |
|---|---|---|---|---|---|---|---|
| `wss://nostrelay.circum.space` | pass | pass | pass | pass | pass | `1a5cff51…` (NIP-11 pubkey) | rh-tec Business GmbH, DE |
| `wss://relay.artx.market` | pass | pass | pass | pass | unknown — served no kind-445 older than 30 days | `e8d667dd…` (NIP-66 `p`) | DigitalOcean |
| `wss://relay.lanavault.space` | pass | pass | pass | pass | pass | no NIP-11 pubkey; a private operator reachable through the NIP-11 contact field | Hetzner Online GmbH, FI |
| `wss://relay.mwaters.net` | pass | pass | pass | pass | pass | `386058f5…` (NIP-11 pubkey) | OVH SAS, FR |
| `wss://relay.nostr.com` | pass | pass | pass | pass | pass | `c1fc7771…` (NIP-11 pubkey and NIP-66 `p`; nostr.com) | DigitalOcean, DE |
| `wss://relay.nostr.hu` | pass | pass | pass | pass | pass | `9be17e37…` (NIP-11 pubkey and NIP-66 `p`; Magyar Nostr, nostr.hu) | ATW Internet Kft., HU (37.221.212.198) |
| `wss://relay.nostr.wirednet.jp` | pass | pass | pass | pass | pass | `634bd19e…` (NIP-66 `p`; imksoo) | SAKURA Internet Inc., JP |
| `wss://relay.satlantis.io` | pass | pass | pass | pass | pass | `7107a209…` (NIP-11 pubkey and NIP-66 `p`; Satlantis) | Amazon Technologies Inc., US |

Vantage: maintainer's development machine, residential connection (EU).

Notes on the 2026-10-31 run:

* No terminator above is one the account seed or the discovery plane resolves
  to: `relay.damus.io` and `relay.primal.net` are Cloudflare-fronted, and no
  pool entry is (criterion (f)). The Cloudflare-fronted candidates that passed
  the probe — `wss://relay.coinos.io`, `wss://relay.nostr.net` — were left out
  of this pool for that reason; `relay.coinos.io` and `relay.nostr.net` sit on
  the profile plane instead, which already carries the pubkey.
* Operators are pairwise distinct and none runs a relay on the account seed,
  the discovery plane or the profile pool. `relay.lanavault.space` publishes
  no NIP-11 `pubkey`; its NIP-11 `contact` is a private address, which this
  record deliberately does not copy. Hosting is given as the organisation the
  resolved address belongs to; addresses themselves are not recorded.
* Criterion (g), NIP-11 `limitation.max_subscriptions`: nostr.com 200,
  nostr.hu 20, lanavault.space 200, circum.space 30, mwaters.net 50,
  satlantis.io 20, wirednet.jp (not published in NIP-11 at vetting; strfry
  default 20), artx.market (strfry default 20). All ≥ 16.
* Criterion (h), 90-day reliability (trustedrelays.xyz, single vantage,
  2026-10-30): nostr.com 92, nostr.hu 88, lanavault.space 91, circum.space 91,
  mwaters.net 91, satlantis.io 87 (company operator); **watch items**:
  `relay.nostr.wirednet.jp` 60 and trending down (kept for a published
  operator and Asian coverage; re-probe before the next release), and
  `relay.artx.market` with no 90-day history yet (NIP-66 monitors saw it up on
  2026-10-30; fastest handshake of the set).
* The first run over the pool chosen on read-only evidence failed FIVE of
  eight entries, which no read-only check could have seen: `wss://relay.nostromo.social`,
  `wss://relay.nsnip.io` and `wss://relay.travelsats.ar` refuse writes from a
  key not on their whitelist; `wss://nostr.self-determined.de` refuses a
  first-seen key as rate-limited; `wss://relay.piazza.today` acks the publish
  and then does not serve the event back (silent drop). All five were
  replaced. Of the bench, `wss://chat.wisp.talk` (group-gated) and
  `wss://nostr.dontyou.click` (write permission) also refuse; `wss://nostr.liberty.fans`
  and `wss://relay.nostrdvm.com` passed L1–L4 but publish no operator at all,
  so they stay on the bench behind entries whose operator can be named.
* Also passed L1–L4 and available as the next replacements, in order:
  `wss://nostr.carroarmato0.be` (published operator, residential hosting),
  `wss://nostr.liberty.fans`, `wss://relay.nostrdvm.com` (both anonymous),
  `wss://nostr.data.haus` (90-day reliability 60 and falling).
* Each pass left one expiring location-shaped kind 445 and one commit-shaped
  kind 445 (followed by a NIP-09 deletion the relay may ignore) per relay,
  from throwaway keys.

### After a run

1. Replace the table above with the one the probe printed. Its rows come
   out sorted by URL, not in `PRODUCTION_LOCATION_RELAYS` order; take them as
   the record.
2. **Sanitise every cell before pasting it.** A `**FAIL**` or `unknown` cell
   carries text a third party sent (the probe already drops control characters
   and the table's delimiters, and cuts it short): keep the wording where it
   explains the verdict, strip anything else.
3. Fill in **operator** for every row: the relay's NIP-66 `p` (or its NIP-11
   `pubkey`), with a name where one is known. No operator may appear twice, and
   none may run a relay on the account seed, discovery or profile plane.
4. Fill in **terminator** for every row: the ASN of the address the host
   resolves to, or the TLS certificate's issuer where a CDN fronts it. It must
   not be one the account or discovery plane resolves to (a Cloudflare-fronted
   location relay hands one party both planes' frames from one IP in one
   second).
5. Record, per relay, NIP-11 `limitation.max_subscriptions` (criterion (g)) and
   the 90-day reliability evidence (criterion (h)) under **Notes**.
6. Set **Status** to `VETTED` (every entry passes L1–L4 with operator and
   terminator recorded) or `PARTIAL` with the failing hosts named, and set
   **Last run** and **Vantage**.
7. An entry that fails is **replaced** in `PRODUCTION_LOCATION_RELAYS`, not
   merely noted: a new circle can be drawn onto it. Take the replacement from
   the bench named under **Notes** (next replacements, in order),
   re-run the probe, and keep the count at eight
   (`production_location_relays_count_is_pinned`). `profile_plane_separation.rs`
   re-checks the domains. Circles already created on a failed relay keep it;
   moving them is a commit every member must receive.

Check 14b of `scripts/ci/check_profile_privacy_boundaries.sh` holds this file
and the pool constant together: every `PRODUCTION_LOCATION_RELAYS` entry must
have a row reading `pass` in L1–L4, with an operator and a terminator recorded,
no operator key (the cell's first token) may appear twice, no terminator may be Cloudflare (criterion (f)), and the Status line must not read UNVERIFIED.
Editing the pool without probing it is a red CI, without CI ever dialling a
third-party host. A pool edit without a new recorded run is red by design.
