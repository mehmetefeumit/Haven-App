# Blossom upload servers — vetting

`BLOSSOM_SERVERS` (`haven-core/src/profile/config.rs`) lists the servers a
saved profile photo is uploaded to, tried in order: the next one only after the
previous one failed to hand back a verified descriptor. Whichever server takes
the photo sees the user's pubkey (in the signed upload token) and IP address,
and keeps the image for as long as it chooses; Haven has no Blossom `DELETE`.

What Haven's own code decides is pinned by tests on every push
(`haven-core/src/profile/blossom.rs`, `haven-core/tests/profile_blossom_redirect_e2e.rs`,
`haven-core/tests/profile_local_first_sync_e2e.rs`). **How the three servers,
which Haven does not operate, actually behave is not something CI can settle.**
This file records the evidence each server was chosen on, and what is still
unproven. `scripts/ci/check_profile_privacy_boundaries.sh` (check 16) requires a
row below for every base in the list; it does not require a live probe.

---

## What a server has to do

| # | Criterion | How it is checked |
|---|---|---|
| B1 | Accepts an anonymous `image/jpeg` `PUT /upload` from a key it has never seen (no payment, no allow-list) | **Live probe only.** |
| B2 | Answers with a descriptor whose `sha256`, `size` and URL address are the uploaded bytes', at an `https://` URL on its own site | Haven refuses any other descriptor and moves to the next server (`upload_rejects_a_descriptor_*`, `upload_falls_back_after_a_descriptor_that_does_not_match`). Whether a server passes: **live probe only**. |
| B3 | Decodes the `Authorization` token in the encoding Haven sends it (`BlossomAuthEncoding`) | Haven's encoding per server is pinned (`each_encoding_is_the_one_its_server_decodes`, `upload_auth_header_*`); a refusal is never retried in the other encoding. Whether the server agrees: source evidence below, **live probe** to confirm. |
| B4 | Serves `GET /<sha256>` with the bytes, directly or through at most three `https://` redirects | Haven follows such redirects and checks the final bytes against the requested address (`profile_blossom_redirect_e2e.rs`). Whether a server stays inside them: **live probe only**. |
| — | Its operator's place in Haven's relay planes | Editorial, below. |

A server that fails B1–B3 costs a failed attempt and the next server is asked.
One that fails B4 leaves the photo unloadable on other devices, which no
fallback repairs — the reason Primal, which redirects every `GET`, needed
Haven's download to follow redirects at all.

Two consequences of the fallback are recorded here because no test can make
them false:

* A server that timed out may have stored the bytes before the next server took
  them, so the photo can sit on more than one of these servers.
* BUD-01 obliges a server to redirect a blob only to a URL carrying the same
  sha256. Haven does not depend on it: Primal may answer from any stored copy of
  the bytes, some of them key-addressed, and integrity is the final body's hash
  against the requested address.

## Why this is not a CI job

For the reasons `docs/PROFILE_RELAY_VETTING.md` gives for its relays: a lane
that dials third parties is not hermetic, tells three operators when Haven
builds, and here would write a new image to each of them on every push. Every
CI lane overrides the list with local servers instead
(`set_blossom_server_for_test`).

## Running the probe

```bash
cd haven-core
HAVEN_PROBE_BLOSSOM_SERVERS=1 cargo test --test profile_blossom_integration_test \
  blossom_servers_accept_an_anonymous_avatar_and_serve_it_back -- --ignored --nocapture
```

Per server, a throwaway key uploads a JPEG no server has seen through the
production checks (B1–B3), then downloads it back through the production
redirect path (B4). It prints one Markdown row per server and fails after
reporting every one.

**What it costs:** it writes a JPEG to each of the three servers for good and
shows them the IP address it runs from. Run it deliberately, from a network you
are content to show them, before changing the list or when a field report
suggests a server changed.

## Findings

**Status: source evidence only — the live probe has not been run.** On
2026-11-16 the build sandbox could not reach these hosts, and CI never runs the
probe. Every cell below is read from published source, not observed.

| server | evidence | token encoding | `GET /<sha256>` | operator in Haven's relay planes |
|---|---|---|---|---|
| `https://blossom.primal.net` | PrimalHQ/primal-blossom-server `src/lib.rs` @ 7e595c9: `PUT /upload` stores the exact bytes and answers `url = <base>/<sha256><ext>` on its own host (827-841); requires `t=upload`, an `x` equal to sha256(body) and `expiration > now` (293-327). The OCaml port (`primal-server` `jobs/lib_media/blossom.ml`) agrees. White Noise's `PROFILE_IMAGE_SERVER` (MDK `crates/marmot-app/src/deployment.rs:75` @ 9b1b58f). | padded standard base64, the only form it decodes (`lib.rs:244-246`) | `302` to its media host (`lib.rs:477-479`) | Primal runs `relay.primal.net`, an account-seed and discovery relay |
| `https://blossom.divine.video` | White Noise's production `MEDIA_SERVERS[0]` (MDK `deployment.rs:73-74` @ 9b1b58f). MDK uploads to it with base64url tokens (`media/blossom.rs:2245-2248`) and checks the descriptor's sha256, size, URL address and site (`media/blossom.rs:577-608`), so it accepts anonymous uploads of `application/octet-stream`; `image/jpeg` is not shown. | base64url, unpadded (what MDK sends it) | unknown | none |
| `https://blossom.ditto.pub` | White Noise's production `MEDIA_SERVERS[1]` (MDK `deployment.rs:73-74` @ 9b1b58f), with the same MDK upload and descriptor checks as above; `image/jpeg` is not shown. | base64url, unpadded (what MDK sends it) | unknown | Ditto runs `relay.ditto.pub`, a discovery relay, which already holds this account's relay lists and IP |

Notes:

* A descriptor without a `url` is refused (BUD-02 requires one); MDK would
  synthesise one, Haven moves to the next server.
* Haven sends no `server` tag in the token (BUD-11: none means any server);
  MDK sends one to divine and ditto. Either form is spec-valid.
