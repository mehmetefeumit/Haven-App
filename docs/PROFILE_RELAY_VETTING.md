# Profile-relay pool — behavioural vetting

The eight relays in `PRODUCTION_PROFILE_RELAYS`
(`haven-core/src/profile/relay_pool.rs`) are the only servers Haven asks about
other people's names and photos, and the only servers a saved profile is
published to. Choosing them is a privacy decision, and the doc comment on that
constant lists five selection criteria.

Three of the five are statements about Haven's own code and are pinned by tests
that run on every push. **Two are statements about how eight servers Haven does
not operate actually behave, and no test in CI can settle them.** This file is
where that gap is tracked, how it is closed, and what was found the last time
anyone looked.

---

## The five criteria, and who checks them

| # | Criterion | How it is checked |
|---|---|---|
| 1 | Disjoint from the account seed AND the discovery plane | `haven-core/tests/profile_plane_separation.rs` — `pool_is_disjoint_from_account_seed_defaults`, `pool_is_disjoint_from_discovery_plane`. Runs in CI. |
| 2 | Accepts an **unauthenticated kind-0 write** from an arbitrary pubkey | **Probe only.** See below. |
| 3 | **No NIP-42 AUTH requirement on read** | **Probe only.** See below. |
| 4 | `wss://` only | `haven-core/src/profile/relay_pool.rs` — `pool_entries_are_wss_and_unique`. Runs in CI. |
| 5 | Metadata-specialised indexers preferred | Editorial. Not mechanically checkable; argued in the constant's doc comment. |

### Why criteria 2 and 3 matter

Criterion 2 is the one with teeth. Publishing fans out to the whole usable pool,
but a *reader* asks about a given author on the one or two relays that author's
pubkey hashes to on **their** device (`assigned_relay_for_attempt`,
`PROFILE_MAX_RELAY_RANK = 2`). So a single relay that quietly refuses Haven's
kind-0 — or acks it and drops it — makes the user invisible to exactly the peers
whose salt lands there, and to nobody else. The symptom on the peer's phone is a
member tile that never gets a name or a photo: indistinguishable from "this
person never set one".

Criterion 3 is structural. The profile fetch path is built with no signer
(`fetch_profiles_assigned`), so it *cannot* answer a NIP-42 challenge. A relay
that requires AUTH on read is not degraded for Haven, it is inert — and inert in
the same silent way.

---

## Why this is not a CI job

Making CI dial these eight hosts was considered and rejected:

* **It is not hermetic.** The lane would go red on a third party's outage, TLS
  renewal or rate limiter. A gate that fails for reasons outside the repository
  trains everyone to ignore it, and then it protects nothing.
* **It tells eight relay operators when Haven builds.** Every push, from a
  stable CI egress address, indefinitely. Haven's whole profile-plane design is
  about not handing relay operators a durable pattern to look at; a build-cadence
  beacon is a strange thing to volunteer.
* **It writes to other people's servers on a schedule.** Criterion 2 cannot be
  probed without publishing. Once per push is abuse; once per release cycle,
  deliberately, is not.

So the probe is opt-in, and its output is checked in here.

---

## Running the probe

```bash
cd haven-core
HAVEN_PROBE_PROFILE_RELAYS=1 \
  cargo test --test profile_relay_vetting -- --ignored --nocapture
```

The probe is `#[ignore]`d **and** env-gated, so neither `cargo test` nor
`cargo test -- --ignored` alone will dial a third-party host: without the
variable it prints a skip line and returns.

It still cannot rot unnoticed, because three **hermetic self-tests** in the same
file are neither ignored nor gated and run on every `cargo test`. They dial only
in-process loopback relays, and they pin the verdict logic in both directions: a
relay that serves reads and keeps our kind-0 passes; one that refuses the write
fails *carrying the relay's own reason*; one that challenges with NIP-42 on read
fails *as an AUTH failure* rather than timing out into `unknown`. A vetting tool
that cannot fail is worse than no vetting tool, because the findings below would
then record a guarantee nobody holds.

For each relay it:

1. connects a **signer-less** client — with no signer `nostr-sdk` cannot
   auto-answer a NIP-42 challenge, which is what keeps criterion 3 from becoming
   a tautology;
2. opens one `REQ` for a kind-0 and records what comes back: `EOSE` (pass), an
   `AUTH` challenge or a `CLOSED` (fail), or nothing inside the budget
   (`unknown`);
3. publishes a kind-0 from a **fresh throwaway key**, built by Haven's own
   `build_metadata_event`, then **reads it back**. The read-back is the point: an
   `OK true` followed by a silent drop is exactly the failure criterion 2 names,
   and only a re-`REQ` tells the two apart;
4. republishes a blank kind-0 (`build_blank_metadata_event`) so the relay is left
   holding `{}` rather than an orphan profile. This is a **supersession, not a
   deletion**: no NIP-09 kind-5 is issued and nothing is removed, so each relay
   keeps a signed kind-0 from the throwaway key for as long as it keeps
   anything. It is also best-effort — the send's result is ignored, and the step
   is skipped entirely on the early return where the relay neither acked nor
   rejected the publish, which is exactly the case where it may have stored the
   event anyway;
5. prints the Markdown table below, then fails if any relay failed a criterion —
   after reporting all eight, not at the first bad host.

`unknown` is never counted as a pass. An unanswered probe is precisely the state
this file exists to stop anyone assuming away.

### Before you run it — what it costs

* **Your IP is disclosed to all eight hosts**, as a client that publishes a
  kind-0 and queries kind-0. Haven ships no Tor or proxy support
  (`docs/privacy/privacy_invariants.json`, "no network-level unlinkability"), and
  neither does this probe. Run it from a vantage point you are willing to
  associate with Haven maintenance — a VPN or Tor exit is reasonable, and worth
  noting in the "vantage" row below, because a relay that treats a Tor exit
  differently from a residential address will give a different answer.
* **It writes to servers you do not own, and the write is permanent.** One
  kind-0 per relay per run, from a key generated for that run, superseded a
  moment later by a blank kind-0 — **not retracted**. Nothing issues a kind-5,
  so every relay keeps a signed record from the throwaway key indefinitely; and
  on the "neither acked nor rejected" path the blank republish is skipped
  altogether, so what stays may be the profile rather than the blank. The `name`
  and `about` fields say what the event is, on purpose: camouflaging a write to
  someone else's server to get a cleaner reading is not a trade this project
  makes. If a relay is ever *suspected* of special-casing the name, re-run with
  a neutral one and say so in the notes.
* **It proves the pool at one moment, from one place.** A relay that adds a
  paywall or an AUTH requirement next month will not announce it. Re-run before
  each release that ships a pool change, and whenever profile lookups start
  failing in the field.

---

## Findings

**Status: VETTED — every pool entry passed both criteria.**
**Last run: 2026-08-21.**

| relay | accepts unauthenticated kind-0 write (criterion 2) | no NIP-42 AUTH on read (criterion 3) |
|---|---|---|
| `wss://nostr.bitcoiner.social` | pass | pass |
| `wss://nostr.data.haus` | pass | pass |
| `wss://nostr.mom` | pass | pass |
| `wss://nostr.oxtr.dev` | pass | pass |
| `wss://offchain.pub` | pass | pass |
| `wss://purplepag.es` | pass | pass |
| `wss://soloco.nl` | pass | pass |
| `wss://yabu.me` | pass | pass |

Vantage: maintainer's development machine, residential connection.

Notes:

* This run replaced HALF the original pool, and the field incident that
  triggered it was exactly the symptom §"Why criteria 2 and 3 matter"
  predicts — circle members' tiles never resolved a name or photo while
  location sharing (a different relay plane) kept working:
  * `wss://relay.nostr.bg` — retired: the hostname no longer resolves in DNS.
  * `wss://relay.nostr.band` — retired: WebSocket handshake times out.
  * `wss://relay.nostrplebs.com` — retired: reachable, answers EOSE, but a
    members-only relay; it does not carry general kind-0 traffic and cannot be
    assumed to keep an arbitrary user's profile.
  * `wss://eden.nostr.land` — retired: same members-only shape as above.
* The four retired hosts are recorded in `RETIRED_PROFILE_RELAYS`
  (`haven-core/src/profile/relay_pool.rs`) so upgraded installs prune their
  seeded rows at startup (`CircleStorage::prune_retired_profile_relays`);
  without that, the union in `usable_profile_relays()` would keep the dead
  hosts in the rendezvous ranking forever.
* Probed but not selected in the same run (all `pass`/`pass` unless noted):
  `wss://relay.nostr.net` and `wss://nostr.sathoarder.com` (bench candidates
  for the next replacement); `wss://user.kindpag.es` (passed, but its operator
  also runs `wss://index.hzrd149.com` on the discovery plane — URL-level
  disjointness would hold while one operator saw both this account's
  KeyPackage/NIP-65 lookups and its kind-0 lookups, so it is excluded on the
  spirit of criterion 1); `wss://nostr21.com` (**FAIL** criterion 2 — rejected
  the publish with an empty OK-false reason).

### After a run

1. Replace the table above with the one the probe printed. It will not be a
   line-for-line swap: the probe collects into a `BTreeMap`, so its rows come
   out sorted alphabetically by URL rather than in `PRODUCTION_PROFILE_RELAYS`
   order. Take the printed rows as the record and let the order change.
2. **Sanitise the cells before pasting them.** A `**FAIL**` or `unknown` cell
   embeds text a third party sent us verbatim — a relay's `CLOSED` message, its
   `OK false` reason — and this file is checked in. Read every cell: keep the
   operator's wording where it explains the verdict, and strip anything that
   would land Markdown, a link, a control character or someone else's payload in
   the repository.
3. Set **Status** to `VETTED` (all pass), or `PARTIAL` with the failing hosts
   named.
4. Set **Last run** to the date, fill in **Vantage** (residential / VPN / Tor,
   and rough region) and any **Notes** — a relay's `OK false` reason string is
   worth keeping, sanitised as above.
5. If a relay fails criterion 2 or 3, it must be **replaced** in
   `PRODUCTION_PROFILE_RELAYS`, not merely noted. A failing entry still occupies
   a rendezvous-hash slot, so every author assigned to it is unresolvable while
   it stays. Replacing one entry also means:
   * re-checking disjointness (`profile_plane_separation.rs` will tell you);
   * keeping the count at eight, or changing the copy that quotes it —
     `privacyRelaysDetailIndexers` and `privacyRelaysDetailProfileLookups` both
     say "eight" in thirteen locales, and `haven-core/tests/privacy_copy_ties.rs`
     holds the constant and the English together;
   * updating the mirrored Dart list `fallbackDefaultProfileRelays`
     (`haven/lib/src/constants/relays.dart`), which
     `scripts/ci/check_profile_privacy_boundaries.sh` check 13 diffs against the
     Rust constant;
   * appending the removed entry to `RETIRED_PROFILE_RELAYS`
     (`haven-core/src/profile/relay_pool.rs`). The constant change alone does
     NOT heal existing installs: their seeded Profile rows outlive it, and
     `usable_profile_relays()` unions the stored rows back in, so the failed
     relay would keep its rendezvous slot forever. The startup prune
     (`CircleStorage::prune_retired_profile_relays`) is what removes those
     rows, and it only knows what the retired list tells it.

Check 14 of `scripts/ci/check_profile_privacy_boundaries.sh` holds this file
and the pool constant together: every `PRODUCTION_PROFILE_RELAYS` entry must
have a `pass`/`pass` row in the findings table above, the Status line must not
read UNVERIFIED, and no retired entry may reappear in the pool. That gate
exists because the original pool shipped unvetted and the gap surfaced as a
field incident — it makes "edit the pool, skip the probe" a red CI instead of
a silent regression, without CI ever dialling a third-party host itself.
