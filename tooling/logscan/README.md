# `haven-logscan`

The runtime proof of Haven's log-anonymity rule (CLAUDE.md's **Log anonymity**
pillar and **Security Rule 15**): nothing that could identify a user, or tell one
user, circle or device apart from another, may reach a log — in any build, at any
level, **in any encoding, full or truncated**.

A lane captures a logcat, a `log show` export, a drive transcript, a relay log
and a handful of diag files, and then uploads them to a public repository for 14
days. This crate is what decides whether that is safe:

* the run **declares** every value it mints over the wire proxy's control channel
  (`HAVEN_NEEDLE_DECL`, written to `/tmp/haven-soak/needles/<role>.needles.decl`);
* `seal` **expands** each declared value into every encoding this tree can render
  it in and writes a sealed manifest;
* `scan` streams every captured sink once, looking for those terms plus the
  structural shapes an **undeclared** identifier takes, and reports
  `sink:line` with a class and an encoding — never a value.

It is a standalone Cargo project (like `tooling/e2e/local-relay`): never part of
the app build, buildable on a runner with no mobile toolchain, and deliberately
**Unix-only** — the `0700`/`0600` modes and `O_EXCL` below are the path
discipline, not a convenience, so this crate does not belong in
`cross-check.yml`.

## Commands

```bash
cargo fmt --check
cargo clippy --all-targets -- -D warnings
cargo test
cargo run --release -- --self-test
```

```
haven-logscan seal  --run-id <id> [--decl <file.needles.decl>]...
                    [--host-decl <class>=<value>]... [--expect <class>=<min>]...
                    [--floor <sink>=<min-lines>]... [--exempt-endpoint <url|host|ip>]...
                    --out /tmp/haven-soak/needles/<run-id>.needles.json
haven-logscan scan  --manifest <path> [--sink <class>=<path>[,<path>...]]...
                    [--segments <class>=<n>]... [--plants-in <class>=<path>]...
                    [--report <path.ndjson>] [--disclose-values]
haven-logscan plant --manifest <path> --sink dart --phase open|close
haven-logscan --self-test
```

`seal` prints **counts only** (values, terms, dropped, coverage gaps, plants,
ledger claims) and never a value. `scan` writes `LEAK:` lines and problems to
stderr, a one-line summary to stdout, and the same findings as NDJSON to
`--report`:

```
LEAK: /tmp/adb-logcat.log:4211 [nostr_group_id/hex-prefix8] tag=flutter ×3
LEAK: /tmp/flutter-drive.log:88 [S5] tag=- ×1
```

`tag=` carries the entry's own log tag for `logcat` and the process name for
`ios`, both drawn from the sink's declared owned-tag list, and `-` elsewhere. It
is deliberately **not** a prefix of the line: a line prefix can carry
remote-authored text, which Rule 15 forbids printing.

`--disclose-values` is the single exception. It prints the matched text, warns on
stderr naming the file it writes into, and is banned from every workflow and
non-interactive runner by `scripts/ci/check_wire_proxy_test_only.sh`. Use it
locally, on a reproduction, and delete what it writes.

## Exit codes

| rc | meaning | who fixes it |
|---|---|---|
| 0 | clean: every sink present, regular, readable, above its floor, segments and ledger reconciled, every positive control caught | — |
| 1 | **leak**: a needle term or a non-allowlisted structural hit | the app (and the caller deletes the sink before any upload) |
| 2 | **guard broken**: bad arguments, a mis-shaped manifest, a bad out path, an expired allowlist entry, a dangling proof, a plant that trips a structural rule | the instrument |
| 3 | **unusable**: an absent/irregular/unreadable/empty sink, a declaration sidecar that cannot be read or parsed, a ledger mismatch, a segment-count mismatch, **any** missed or undeclared positive control | the capture, not the app |
| 4 | **meta floor**: below a line floor, no manifest, a declaration floor unmet, a manifest with no searchable term at all, a value nobody confirmed was planted | the scenario |

Aggregation across sinks is `1 > 2 > 3 > 4 > 0`: a leak anywhere takes the
containment branch even if another sink was unusable. `seal` writes **no
manifest** when its own verdict is not 0 — a manifest that proves too little must
not become the basis of a clean verdict.

## Path discipline

The manifest holds every value the run minted (real MLS group ids, pubkeys,
names, coordinates, and the commitments of the secrets). It is the most sensitive
file on the runner, so:

* the directory is `/tmp/haven-soak/needles` **unconditionally** — no environment
  override, no `--dir` flag, because a relocatable path defeats the upload ban
  (`scripts/ci/check_wire_proxy_test_only.sh:180-191` records that defeat twice);
* `--out` must end in `.needles.json`, which is what the repo guard keys on;
* the directory is created `0700` and refused if it is anything else, and the
  file is created `O_EXCL` with mode `0600` — a second seal never overwrites the
  first;
* secret-class values (`nsec`, `secret`) are **committed**: the manifest stores
  `sha256(raw)`, `raw_withheld: true`, and only the digest's encodings are
  searchable. Raw-secret recall is carried by
  `tooling/e2e/ci/scan-logs-for-secrets.sh`'s keyword-anchored patterns and by
  S1/S2/S4/S8/S9.

`policy.toml` and `allowlist.json` are **compiled in** (`include_str!`) for the
same reason: an instrument whose rules a caller can substitute at runtime is a
flag, not a guard. Changing either means a reviewed diff and a rebuild.

## Positive controls (plants)

A plant proves **sink reach only** — that the file the scanner read is the file
the run wrote. Nothing else here can prove that: a wrong path, a rotated log, a
dead capture and a mis-installed log backend all look clean to a needle search.

* **Dart** plants are the only declared ones. The harness mints one token per
  phase (`logscan-plant-dart-<open|close>-<10 chars>`), declares it over
  `HAVEN_NEEDLE_DECL`, and `debugPrint`s it, so it reaches both the device log
  and the drive transcript. `seal` adopts the **last** declaration in the
  sidecar per (emitter, phase) — the Android lane's connect-flake retry re-runs
  the drive target and re-declares — and keeps the earlier tokens as
  `superseded`, which are ignored on sight. Position, not `seq`: the proxy's
  sequence counter restarts at 0 in a new process while it appends to a sidecar
  it did not create, so ordering by `seq` would let a restarted lane's stale
  token outrank the fresh one. A plant-shaped Dart token matching
  **no** declaration is rc 3: a declaration was lost. When no declaration
  arrived at all, `seal` mints the token itself and `plant` prints it.
* **Rust**, **Kotlin** and **Swift** plants are undeclared and matched by shape
  (there is no native harness channel to declare through): `logcat` requires a
  `rust` and a `kotlin` **opening** token, `ios` a `rust` and a `swift` one, at
  least once per sink class. Only the `-open-` phase counts, because what these
  prove is that the emitter's backend was installed at launch.
* Each declared token must appear **at least once** in every scanned sink class
  that carries Dart output (`logcat`/`ios` and `drive`). "At least once", not
  "exactly once", because the retry legitimately leaves both attempts' tokens in
  a concatenated log; `--plants-in <class>=<path>` narrows reconciliation to one
  file of the class (the lane passes its final-attempt drive slice) while every
  file is still searched for needles.
* A plant is **structurally inert by construction**: the alphabet
  (`ABCDEFGHJKLMNPQRSTUVWXYZ23456789`) contains no `1`, no punctuation, and no run
  longer than 10 characters, so no rule of either scanner can fire inside a
  token. `assert_inert` re-checks it anyway and is rc 2 — a mis-designed control
  must never be rc 1, because rc 1 deletes the evidence the control exists to
  prove.

## Encodings and the ledger

`policy.toml`'s `[ledger]` is a hand-written claim per `(class, encoding)`:
`covered`, a `gap` with a reason, or a `not_gaps` entry for a rendering that is
out of scope entirely. Every seal reconciles it against what the expander
actually produced, and four disagreements are rc 3:

1. a `covered` label the expander does not search;
2. a `gap` label it does search;
3. a label nothing in the ledger declares;
4. a gap with no reason.

The model is `CanaryEncodingLedger` in
`haven/integration_test/e2e/_lib/wire_canaries.dart`, including its central
discipline: the ledger's boundaries are **literals**, never computed from the
expander's constants, because a ledger that recomputed them would follow a
narrowing change instead of reporting it.

Every label produces either a term or a recorded drop, never nothing. A drop is
one of:

| drop | meaning | satisfies a `covered` claim? |
|---|---|---|
| `alias` | the same string is already searched under another label (or the same string under the case-insensitive automaton) | yes — nothing is lost |
| `unavailable` | the declared VALUE has no such rendering (a name too short for this prefix, a negative axis with no `+` form, a term below the global floor, a term identical to sink furniture) | yes |
| `policy-gap` | the expander deliberately does not search it | no — this is the only kind a `gap` claim accepts |

Label vocabulary, by class kind:

* **bytes** (`nsec`, `secret`, `mls_group_id`, `nostr_group_id`, `pubkey`,
  `event_id`): `hex-lower`, `hex-upper`, `hex-prefix8/12/16`, `hex-spaced`,
  `hex-reversed-bytes`, `rust-debug-x`, `rust-debug-upper-x`, `rust-debug-02x`,
  `rust-debug-alt-x`, `dart-radix16-unpadded`, `base64-{std,url}-align{0,1,2}`
  (± `-padded`), `debug-array`, `debug-array-compact`, `sha256-hex`,
  `sha256-hex-prefix8/16`, plus `bech32-<hrp>`/`-upper` per HRP and
  `bech32-<hrp>-tlv-hint` as a declared gap.
* **text** (`circle_name`, `display_name`, `petname`, `about`, `device_id`,
  `kp_slot`, `subscription_id`): `utf8`, `nfc`, `nfd`, `nfkc`, `nfkd`, `lower`,
  `upper`, `casefold`, `search-fold`, `percent-component`, `percent-form`,
  `json-escaped`, `latin1-from-char-codes`, each also with **one** `base64`
  layer, plus the `utf8-drop1..4` prefix ladder.
* **coordinate**: `{lat,lon}/decimal-round3..7`, `/decimal-trunc3..7`,
  `/trimmed`, `/scientific`, `/scientific-dart`, `/comma-decimal`, `/unsigned`,
  `/sign-plus`, and `pair-{latlon,lonlat}/sep-{comma,comma-space,space}`.
* **geohash**: `full`, `prefix6..8`. `prefix4`/`prefix5` are in `not_gaps`: they
  are below the global term floor for EVERY value, so they are not produced at
  all rather than produced and dropped (a drop would have satisfied a `covered`
  claim and let the ledger promise a search nothing performs).
* **url** (`relay_url`, `blossom_url`): `as-declared`, `no-trailing-slash`,
  `trailing-slash`, `scheme-alt`, `host-only`, `host-upper`, `host-punycode`,
  `with-port`, `without-port`, `percent-encoded`.

Three notes on the encoders:

* `search-fold` is a **port** of `haven_core::directory::fold_for_search`
  (`haven-core/src/directory/fold.rs:89-124`, reached from Dart through
  `haven/lib/src/utils/search_fold.dart`, pinned by
  `haven/test/utils/search_fold_test.dart`). It is a port and not a dependency
  because `haven-core` drags the whole MLS stack; `fold_matches_the_app_vectors`
  asserts the same vectors the app's own tests assert, so a drift in either
  direction is a failing test here.
* `rust-debug-alt-x` is the **whitespace-collapsed single-line normalisation** of
  Rust's multi-line `{:#x?}` dump. That is matchable because the `logcat`
  reassembly pass joins consecutive entries of one record with each entry's
  whitespace runs — the leading one included — collapsed to a single space, so
  the indent `{:#x?}` puts before every element becomes the `, ` the term
  carries. `a_multiline_rust_hex_dump_split_across_entries_is_rejoined` builds
  the haystack from a real `format!("{bytes:#x?}")`, so the claim tracks what
  the compiler prints rather than what this file says it prints.
* `base64-*-align{1,2}` are alignment **cores**: whole 3-byte groups starting at
  the first group boundary inside the value, so the term survives whatever
  precedes the value in the encoded stream and whatever padding follows. The
  `-padded` labels therefore collapse into aliases.

`utf8/base58`, `utf8/base32`, deeper compositions, `coord/dms` and
`coord/plus-code` are declared out of scope in `policy.toml`'s `not_gaps`, each
with the sentence why.

## Structural rules

`S1` 64-hex run · `S2` 32–63-hex run · `S3` bech32 of any HRP · `S4` base64 ≥ 32
characters above a Shannon floor · `S5` decimal coordinate pair · `S6`
geohash-shaped token adjacent to `geohash|geo|gh` (the keyword must be delimited
and separated from the cell by one to eight non-alphanumeric characters, which
covers `geohash=u4pruyd`, `gh: u4pruyd`, `"geohash" : "u4pruyd"` and the
escaped-JSON form while keeping the rule out of a plant token) · `S7` any `wss?://` URL (the
default pool included — owner-directed) · `S8` `secret|nsec|seed|key` within 24
characters of a blob · `S9` 32-element decimal array · `S10`
`display_name=|petname=|circle_name=|name=` followed by non-placeholder text ·
`S11` a bare Unix second in the current epoch window on a
`publish|sent|received|since` line · `S12` a dotted-quad or IPv6 literal.

They run on **Haven-owned lines only** (tag/process scoping) and never on a
`relay` sink. On a `logcat` sink they see the message body (the host's own
timestamp is a documented residual); on `ios` and `plain` sinks the body is the
whole line — a relay log holding pubkeys and event ids is
not a Haven leak, and a guard that cries wolf on vendor output is a guard that
gets deleted. The seven patterns of
`tooling/e2e/ci/scan-logs-for-secrets.sh` are **not** duplicated here; that
script stays the toolchain-free key-material floor and the wrapper runs both.

Only S7 and S12 have an exemption, and only for the endpoints the run declares
with `seal --exempt-endpoint` (the lane's own loopback relay and proxy, in host,
`host:port` and URL spellings — never a path under them). Everything else needs
an `allowlist.json` entry.

## Allowlist

Structural hits only; a needle hit has no allowlist path, because a needle IS a
value this run minted and there is no benign reason for it to be in a log.

```json
{ "rule": "S7", "scope": { "sink_glob": "*flutter-drive.log", "tag": null },
  "pattern": "^…", "justification": "…", "proof": "file:line or a test name",
  "owner": "…", "expires": "YYYY-MM-DD" }
```

An entry past `expires`, with no justification or owner, or whose `proof` does
not resolve, is **rc 2**: stale allowances cannot accumulate. A `proof`
containing `..` is refused too — a citation that climbs out of the tree proves
nothing about it. The resolution root is the checkout this binary was **built**
from (`CARGO_MANIFEST_DIR/../..`), never the process working directory, so a
citation means the same thing under `cargo test` and under
`tooling/e2e/ci/scan-logs.sh`. The file ships empty (`[]`).

## Adding a class, an encoding or a rule

* **class** — add it to `policy.toml`'s `[classes]` (with `scoped_out` for any
  sink that legitimately holds it) and add a `[ledger.<class>]` table; the policy
  refuses to load a class with no ledger table.
* **encoding** — add the label to the expander's label list AND to the ledger.
  The expander must emit a term or a recorded drop for it on every value, and
  `every_label_renders_exactly` needs a literal expected value computed
  **independently** of the implementation (the existing table was computed in
  Python from the label definitions; do the same).
* **rule** — add it to `RULES`, add its positive AND negative fixture to
  `every_rule_has_a_positive_and_a_negative_fixture`, add a dirty line to
  `fixtures/dirty.logcat.log`, and bump `DIRTY_RULE_LINES`/`RULE_COUNT` in
  `src/selftest.rs`. Then check the new shape cannot fire inside a plant token —
  `the_token_shape_makes_every_rule_unreachable` is the argument — evaluated on
  the token, on the token followed by a geohash-shaped word, and on the line a
  harness actually writes — and S6 is the rule that already had to require a
  separator for it.

## Performance

One streaming pass per file: 1 MiB chunks carrying `max_term_len − 1` bytes of
overlap, one case-insensitive Aho-Corasick automaton for the hex/bech32/name/URL
terms, one case-sensitive automaton for the base64 terms, one `RegexSet` for the
rules. A single logical line is capped at 1 MiB for RULE evaluation while the
window pass still searches every byte of it for needles.

`--self-test` generates a 64 MiB sink, **measures and prints** throughput, and
asserts only the single-pass property (bytes read == file size). There is
deliberately **no timing assertion**: a timing floor on a shared CI runner is a
flake source, which CLAUDE.md forbids. The design goal from the plan is
≥ 300 MB/s/core; the figure measured locally with the full rule set on one core
is ≈ 125 MiB/s (the per-line `RegexSet` dominates), i.e. a 4 GB `log show` export
in well under a minute. Read the printed number, do not assert it.

## Fixtures

`fixtures/` holds the self-test's declaration set, its clean and dirty sinks, the
reassembly sinks and three allowlists. Every value in them is **synthetic**: never
a real key, and never a wire-canary value, so a canary and a needle can never be
mistaken for each other. The dirty fixtures deliberately contain shapes that also
trip `scan-logs-for-secrets.sh`; the clean ones contain none.
