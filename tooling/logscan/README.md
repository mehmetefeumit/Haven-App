# `haven-logscan`

The runtime proof of Haven's log-anonymity rule (CLAUDE.md's **Log anonymity**
pillar and **Security Rule 15**): nothing that could identify a user, or tell one
user, circle or device apart from another, may reach a log — in any build, at any
level, **in any encoding, full or truncated**.

A lane captures a logcat, a `log show` export, a drive transcript, a relay log
and a handful of diag files, and then uploads them to a public repository for 14
days. This crate is what decides whether that is safe:

* the run **declares** every value it mints over the wire proxy's control channel
  (`HAVEN_NEEDLE_DECL`, written to `/tmp/haven-soak/needles/<role>.needles.decl`),
  or, on a lane with no proxy, the host declares the constants the harness is
  seeded from (`--host-decl`, `--host-seed`);
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
                    [--host-decl <class>=<value>]... [--host-seed <64-hex>]...
                    [--declared-plants dart|none] [--expect <class>=<min>]...
                    [--floor <sink>=<min-lines>]... [--exempt-endpoint <url|host|ip>]...
                    --out /tmp/haven-soak/needles/<run-id>.needles.json
haven-logscan scan  --manifest <path> [--sink <class>=<path>[,<path>...]]...
                    [--segments <class>=<n>]... [--plants-in <class>=<path>]...
                    [--report <path.ndjson>] [--disclose-values]
haven-logscan scan  --rules-only --sink <class>=<path>[,<path>...]...
                    [--segments <class>=<n>]... [--exempt-endpoint <url|host|ip>]...
                    [--report <path.ndjson>]
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

## Declaring from the host

A lane with the wire proxy declares every value it mints over the control
channel. A lane **without** one — every b-lane, the integration, relay-
customization, flake-stress and profile lanes — mints its identities from
constants that are checked into the harness, so the host can declare them
instead. Two flags do that, and the difference between them is what the manifest
is allowed to hold.

* **`--host-decl <class>=<value>`** declares a value the host knows verbatim: a
  role coordinate, a canary stem, a relay URL. A `coordinate` must be `lat,lon`
  in decimal degrees and is refused at the flag rather than deep in the expander
  — a runner's argv is not somewhere a typo should surface three layers down —
  and the refusal withholds the value, because argv reaches a public step log.
* A `circle_name`/`petname` host declaration may be a **stem** rather than a
  whole name: the canary names are `"Qzvx CIRCLE <10 random>"`, and only
  `"Qzvx CIRCLE "` is host-knowable. A stem is searched verbatim and through the
  expander's `utf8-drop1..4` prefix ladder, so it is a real term **only while it
  is at least as long as the sink's term floor** — 8 characters for `logcat` and
  `ios`, 6 elsewhere. The canary stems are 12 characters, so every ladder rung
  down to `drop4` clears both floors; a four-character stem would expand to
  nothing but recorded drops and the seal would refuse the manifest as searching
  for nothing.
* **`--host-seed <64-hex>`** (repeatable) takes the 32-byte secret the harness
  seeds an identity from (`test_user.dart:48-71`) and declares **two** values:
  the derived x-only pubkey as class `pubkey` — public, so every encoding of it
  is searched, `npub` included — and the seed itself as class `nsec`, which is
  secret-class, so the manifest carries `sha256(raw)` and nothing else. The
  derivation is `k256`, a pure-Rust secp256k1: this crate must build on a runner
  with no mobile toolchain, and `haven-core` would drag the whole MLS stack in
  for one scalar multiplication. `seed.rs` pins the harness's three seeds and the
  generator against x-coordinates computed by two independent implementations
  outside this crate. `--expect pubkey=N` counts them like any other declaration,
  so a runner that dropped a seed cannot seal a manifest that reads as complete.

A malformed seed is rc 2 and the error never quotes it. Neither does anything
else: `logscan_never_prints_a_needle` drives every output path with a seed in
argv and asserts that neither the seed nor its pubkey appears in stdout, stderr,
the NDJSON report or the `plant` output — the manifest file is the one place the
pubkey lives, as a searchable term, and the seed never lives anywhere.

The seeds are 32 repeated bytes from a checked-in test file, shared by every run
and never used outside an emulator. They are handled as secret-class because the
SHAPE is what the discipline keys on; do not read that as a claim that argv on a
CI runner is a safe place for a real key.

## Rules-only scans

`scan --rules-only` runs the structural rules and the line floors over a capture
with **no manifest at all**: no needle search, no plant reconciliation, and a
summary that says `rules-only (no manifest: no needle searched, no plant
reconciled)` rather than `plants 0/0`, which would read as controls that passed.

It exists because the unit-test lanes have nothing to declare. A `cargo test` run
mints no circle, no identity and no coordinate that any channel could report, so
the only honest thing a scanner can certify over `rust-check.yml`'s four tee'd
`cargo test` logs and `coverage.yml`'s `flutter test` log is *that the rules
ran*. That is worth certifying — S1, S5, S10 and S12 over a transcript nobody
reads is how a stray `println!` of a group id gets caught — and it is worth
saying out loud that it is all that was certified.

`--rules-only` and `--manifest` are mutually exclusive (rc 2), as is
`--plants-in` with it: a flag that is silently ignored is a false claim of
coverage. `--exempt-endpoint` is accepted **here and only here** (with a manifest
the exemptions are the sealed ones), because a `cargo test` transcript carries
the `#[ignore]` reason that names a local Blossom server by loopback URL, and
S12 is right to see it. Nothing is exempt implicitly.

**Every device lane must NOT use it.** A logcat, a `log show` export or a drive
transcript comes from a run that minted real values, so the manifest is
available and the needle search is the point;
`scripts/ci/check_logscan_wired_everywhere.sh` forbids `--rules-only` outside
`rust-check.yml` and `coverage.yml`.

## Exit codes

| rc | meaning | who fixes it |
|---|---|---|
| 0 | clean: every sink present, regular, readable, above its floor, segments and ledger reconciled, every positive control caught | — |
| 1 | **leak**: a needle term or a non-allowlisted structural hit | the app (and the caller deletes the sink before any upload) |
| 2 | **guard broken**: bad arguments, a mis-shaped manifest, a bad out path, an expired allowlist entry, a dangling proof, a plant that trips a structural rule | the instrument |
| 3 | **unusable**: an absent/irregular/unreadable/empty sink, a capture in a rendering its sink class cannot frame, a declaration sidecar that cannot be read or parsed, a ledger mismatch, a segment-count mismatch, **any** missed or undeclared positive control | the capture, not the app |
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
  **What they bound is weaker than a declared token, and knowingly so**: a fixed
  literal proves the backend reached *this capture at some point in this process
  or boot*, not that it reached it *during this run*. On Android `adb logcat -c`
  before the capture closes most of that gap. On iOS nothing does — `log collect`
  spans the whole simulator boot, and the Swift token is a literal that an
  earlier launch could have written — so an `ios` shape plant is evidence the
  backend exists and is installed, not evidence that this run's records are in
  the file. The per-run DECLARED token is what carries that claim, and it is
  exactly what `ios` does not have yet (`declared_plants_expected = false`).
* **A lane with no declaration channel declares none.** A plant proves that the
  APP reached the sink, so the app has to print it, so somebody has to hand it
  one — and only the proxy's channel can. On a proxy-less lane a seal that minted
  a Dart token would demand a control the run cannot possibly satisfy: rc 3 on
  every green lane, which is how a positive control becomes noise and then gets
  deleted. Those lanes seal `--declared-plants none`; the manifest records it,
  `scan` reconciles no Dart token, `plant --sink dart` is rc 2 ("no declaration
  channel"), and both summaries say `declared plants: none (host profile)`. The
  **shape** plants still apply, so a dead capture is still caught. Declaring
  `none` while a sidecar declared a plant is rc 2: the two claims cannot both be
  true.
* Which sink classes must carry the declared tokens is the policy's
  `declared_plants_expected`, not a list in the code. It is `true` for `logcat`
  and `drive`, and `false` for `ios`: no captured `log show` export has yet shown
  a Dart token. That is "unproven", not "impossible" — the Flutter engine routes
  `debugPrint` through `vsyslog`, which does reach the unified log as
  `Runner(Flutter)[pid] … flutter: <msg>` — and the first iOS capture that
  carries one flips the flag to `true` for good. It is `false` for the classes
  that carry no app output at all (`rust-test`, `proxy`, `diag`, `relay`).
  Demanding an unproven control would make every iOS lane rc 3 for a reason that
  is not a privacy fact.
* Each declared token must appear **at least once** in every scanned sink class
  that carries Dart output (the classes with `declared_plants_expected` —
  `logcat` and `drive` today). "At least once", not
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
* **coordinate**: `{lat,lon}/decimal-round4..7`, `/decimal-trunc4..7`,
  `/trimmed`, `/scientific`, `/scientific-dart`, `/comma-decimal`, `/unsigned`,
  `/sign-plus`, and `pair-{latlon,lonlat}/sep-{comma,comma-space,space}`. The
  single-axis ladders start at FOUR decimals: `{lat,lon}/decimal-round3` and
  `/decimal-trunc3` are in `not_gaps`, because a 3-decimal axis is a
  six-character decimal that a millisecond duration or a percentage carries by
  chance (CI run 34766632019 matched one in a relay log). The PAIR labels keep
  three decimals — two axes and a separator are unambiguous — and so does
  `wire_canaries.dart`'s own ledger, because a wire frame has no duration or
  percentage column for a lone axis to collide with. A log does.
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

`utf8/base58`, `utf8/base32`, deeper compositions, `coord/dms`,
`coord/plus-code` and the 3-decimal single axes are declared out of scope in
`policy.toml`'s `not_gaps`, each with the sentence why.

## Sink framing

Terminal escape sequences come off first, on every sink, before anything
matches: SGR colour (`ESC [ … m`) and OSC-8 hyperlinks (`ESC ] 8 ; ; … ESC \`),
in one pass as the bytes enter the scanner, so needles, plants and rules all
read the same plain text. That is a **recall** property rather than a cosmetic
one — CI sets `CARGO_TERM_COLOR=always`, a colour code lands exactly where a
tool highlights a value, and an escape inside a hex run splits it into two
shorter runs that no term and no rule matches. What comes off is the FRAMING,
never the content: an OSC-8 hyperlink's payload is a URL, so only the introducer
(`ESC ] 8 ; ;`) and the terminator are dropped and the target is scanned like any
other URL. A newline always ends a sequence, terminated or not, so a stripped
capture keeps every line number it had — with one exception, in the direction
that cannot hide anything: a FINAL unterminated line made only of escape bytes
strips to nothing and is not counted, which can only make a line floor stricter.

A sink class then says how its lines are shaped, and the shape decides where the
Haven-owned part of a line starts — which is what the structural rules are
allowed to read.

* **`logcat`** — `MM-DD HH:MM:SS.mmm  pid  tid P tag: message`, from
  `adb logcat -v threadtime`. Owned when the tag matches one of the sink's
  `owned_tags` as a prefix (`android_logger` truncates a module path to 23
  characters).
* **`ios`** — a `log show` export in EITHER rendering, because the capture is
  one `--style` flag away from the other:
  * `--style syslog`, which is what all five iOS lanes capture:
    `<date> <time+tz> <host> <process>[<pid>[:<tid>]] <<Type>>: <message>`;
  * the default columnar style:
    `<date> <time+tz> <thread> <type> <activity> <pid> <ttl> <process>: <message>`.

  In both, `<process>` may carry the emitting library in parentheses
  (`Runner(Flutter)`), which is framing rather than identity and is stripped, and
  the message may open with the record's `[subsystem:category]` or an `NSLog`
  prefix, which stay in the body — on iOS the process is `Runner` for everything
  Haven emits, so the subsystem is the only thing that says which layer wrote the
  line. Ownership is an **exact** match of the process name against
  `owned_processes` — never a substring, because a substring test owns
  `RunnerHelper` and, worse, owns any vendor line whose message merely contains
  the word `Runner`, putting remote-authored text under Haven's rules.
* **`plain`** — every line is Haven's in full (drive transcripts, `cargo test`
  and `flutter test` logs, relay and diag files).

A line that does not parse is treated as **not owned**: the rules skip it and
every byte of it is still searched for needles, because a declared value in a
vendor line is still a disclosure in an uploaded artifact. On `ios` that includes
a Haven record's own CONTINUATION lines — a wrapped message or a multi-line panic
body carries no process column, so the structural rules never see anything but
the first line of it, and the needle search is what covers the rest.

A framed sink whose lines **all** fail to parse is rc 3, not rc 0. That is the
one failure mode that otherwise looks exactly like a clean run — a different
`log show --style`, a logcat captured without `-v threadtime`, and the rules
silently do not run over any of it.

`fixtures/format.ios.log` holds one line per documented column variant of BOTH
renderings (plain process, process with a library, a `[subsystem:category]`
message, an `NSLog`-prefixed one, wide columns, `[pid:tid]`, a vendor process, a
process whose NAME contains an owned one, a vendor line whose MESSAGE does, an
unparseable continuation, the two shape plants, and a needle on an un-owned
line), and case P of `--self-test` pins exactly which of them reach the rules.
The file is **specification-derived**, and its header says so, because there is
deliberately **no captured iOS furniture corpus yet**: no iOS lane has ever run the scanner, so the first run is
the corpus source, and it will be mined from a failing run's upload exactly as
the Android one was (run 34766632019). Until then the `ios` framing is proved
against the documented format rather than against a capture, and the rc-3 above
is what turns the difference between the two into a red lane instead of a quiet
pass.

## Structural rules

`S1` 64-hex run · `S2` 32–63-hex run · `S3` bech32 of any HRP · `S4` base64 ≥ 32
characters above a Shannon floor **and carrying two separate digit RUNS or `=`
padding** ·
`S5` decimal coordinate pair · `S6`
geohash-shaped token adjacent to `geohash|geo|gh` (the keyword must be delimited
and separated from the cell by one to eight non-alphanumeric characters, which
covers `geohash=u4pruyd`, `gh: u4pruyd`, `"geohash" : "u4pruyd"` and the
escaped-JSON form while keeping the rule out of a plant token; **a cell that
continues into `::`, `_`, `(` or another letter is a code path, not a cell**) ·
`S7` any `wss?://` URL (the
default pool included — owner-directed) · `S8` `secret|nsec|seed|key` within 24
characters of a blob that looks ENCODED (two digits, base64 punctuation or S4's
entropy floor) and that no letter runs into, so `KeyPackageMaintenanceFailed`
and `KeyCipherImplementationRSA18` are identifiers rather than key material ·
`S9` 32-element decimal array · `S10`
`display_name=|petname=|circle_name=|name=` followed by non-placeholder text ·
`S11` a bare Unix second in the current epoch window on a
`publish|sent|received|since` line · `S12` a dotted-quad, or an IPv6 literal
delimited by non-word characters on both sides and carrying a digit — the
delimiters and the digit are what keep the rule off `haven_core::relay::manager`
and `Option::Some`, which the first CI run of this scanner read as addresses
hundreds of times per transcript.

Four things narrow what the rules catch — two rule qualifiers, one sink-class
exemption and one property of the escape stripper — so all four are written down
as **declared residuals**, the same discipline the ledger's `not_gaps` follow: a
boundary stated in one sentence beats a boundary discovered by an adversarial
reader later.

| residual | what is no longer caught | what carries it instead |
|---|---|---|
| **S4** | a base64 run of 32 or more characters with no `=` padding whose digits are absent or all in ONE contiguous run (roughly one random 44-character blob in a hundred and sixty) | S1/S2 for the hex spellings, S8 when a key word is within 24 characters, the needle search for every value the run declared, and `scan-logs-for-secrets.sh`'s keyword-anchored patterns |
| **S6** | a geohash cell immediately followed by `_`, `(` or `::` | the needle search for a declared coordinate's `geohash` renderings; an undeclared cell in that position is a code path in every capture this tree has produced |
| **cargo's crate-build line** (`rust-test` only) | **S2 and S6 only**, and only on a `Compiling\|Checking\|Downloaded <name> v<semver> [(<source>)]` line: a 32–63-hex run or a geohash-shaped token in the crate-name or source-URL slot. Every other rule still fires on that line, and cargo's other status lines are not exempt at all | the needle search, which reads those lines byte for byte like any other; S1 for a 64-hex run; and the shape itself, which has to be produced deliberately |
| **escaped value** | a value the app printed immediately after a LITERAL `ESC [` it emitted itself: the CSI consumer eats the parameter bytes (digits, `;`, `:`, `<=>?`) up to the first `@`–`~`, so the head of such a value is removed before matching | `tooling/e2e/ci/scan-logs-for-secrets.sh`, which runs FIRST and over raw bytes; and the fact that nothing in this tree emits a bare `ESC [` — the app's own log backends do not colour |

The first three were each paid for by a real transcript and are in
`furniture.rust-test.log` / `furniture.flutter-test.log` now; the fourth is a
property of the stripper rather than a line anyone has captured, and its control
is the unit test that plants an escape inside a hex run. S4's entropy floor
cannot separate `kBackgroundSessionReclaimAtMsKey` (4.33 bits) from a 32-byte
base64 blob (4.5–5.0), and base64 punctuation cannot either, because
`App/haven/test/providers/identity` is a path made of `/`; what a base64 payload
of random bytes has and an identifier does not is SCATTERED digits — 10 of the 64
characters, landing in several separate runs, where an identifier carries a
vocabulary number as one (`Base64`, `Sha256`, `Nip44`). Counting digits rather
than runs is what reddened the Flutter coverage lane of CI run 35244067610 on
three test NAMES, `circleNameBase64dIntoAnUnalignedBlobIsCaught` among them, and
the tightening is nearly free: fewer than two digit runs in a random 44-character
blob happens about once in a hundred and sixty (against once in a hundred and
ninety for fewer than two digits), and in a 32-character one about once in
twenty-eight (against once in thirty-three).

What carries that recall is worth stating precisely, because on a rules-only lane
some of it is not there: S1/S2 catch the value only where it is ALSO spelled in
hex, S8 only where a key word is within 24 characters, the needle search only in
a lane that sealed a manifest (a unit-test transcript seals none), and
`scan-logs-for-secrets.sh`'s patterns need a keyword AND `=` padding. So on a
`cargo test` or `flutter test` transcript an unpadded, keyword-free blob whose
digits are absent or contiguous is a **bare residual** — nothing else is looking.
Two things bound it: a 32-byte secret in standard base64 always ends in `=`, so
the class that matters most is unaffected; and the weakest case, an unpadded
24-byte value encoded in exactly 32 characters, is the ~1-in-28 tail above.

S8 deliberately still
counts digits rather than runs: it fires only within 24 characters of a key word
and only on a blob no letter runs into, and its entropy clause already admits a
long identifier on its own, so narrowing its digit test would cost recall in the
one net that has a keyword anchor and buy nothing. S6's code-path test is what
keeps `location::geohash::tests::nan_latitude_returns_empty` — a delimited
keyword, `::` as the separator, and five geohash-alphabet letters — from
reddening every `cargo test` transcript this tree produces.

The cargo residual is the only exemption that belongs to a SINK CLASS rather than
to a rule, and it is deliberately the narrowest thing that closes the failure it
was written for. Before a single test runs, cargo prints the public pinned git
revision of every git dependency (a 40-hex run, which S2 reads as a truncated id)
and the name of every crate it touches (one of which S6 reads as a cell next to a
`geo` keyword), so both `cargo test` jobs of CI run 35244067610 went rc 1 over
nothing but the toolchain's own output. Neither is a Haven identifier — they are
public facts about this tree's dependency list, printed by cargo rather than by
the app — so `policy.toml`'s `rust-test` sink sets `cargo_status = "exempt"`.

Two bounds make that an exemption rather than a blind spot, and both are
mechanical:

* **one shape.** Only `Compiling|Checking|Downloaded <name> v<major>.<minor>.<patch>`,
  optionally followed by a parenthesised source that must open with a scheme or a
  path separator. The crate slot is a crate NAME, the version is a bare semver
  triple, and the source is not free text. Cargo's other status lines —
  `Finished`, `Running`, `Doc-tests`, `Updating`, `Downloading` — are **not**
  exempt: they trip no rule as cargo prints them (asserted, not assumed), and
  each has an unbounded tail, which is a slot a value can be printed into.
  `Doc-tests <32 hex>`, `Running x (target/<coordinate pair>)` and
  `Updating git repository \`wss://…\`` were all furniture under a wider shape;
  each is a regression test now.
* **two rules.** Only S2 and S6 are skipped, because those are the two shapes
  cargo's own output carries. S1, S3, S4, S5, S7, S8, S9, S10, S11 and S12 all
  still fire on that line, so a 64-hex run, a URL, a coordinate or an address
  inside a cargo-shaped line is reported exactly as it would be anywhere else.

Needle matching is untouched on those lines as on every other, so a declared value
cannot hide behind a cargo verb. What remains is the residual in the table above,
stated plainly: a print of the whole crate-build shape, on the `rust-test` sink,
with a 32–63-hex run or a geohash-shaped token in the crate-name or source slot,
is not reported by S2 or S6. A hex run beginning with a letter does fit the name
slot. Case Q of `--self-test` holds the clean arm and all four mutations.

They run on **Haven-owned lines only** (tag/process scoping) and never on a
`relay` sink. On a `logcat` sink they see the message body (the host's own
timestamp is a documented residual); on `ios` sinks the message after the
columns; on `plain` sinks the whole line — a relay log holding pubkeys and event
ids is not a Haven leak, and a guard that cries wolf on vendor output is a guard
that gets deleted.

On a `plain` sink one physical line is split on **carriage returns** before the
rules see it. A progress reporter writing to a pipe rewrites its status line with
`\r` and no newline, so one line of `flutter test`'s compact output carries
hundreds of independent updates; evaluated as one string, a description ending in
`key` sits inside S8's 24-character window of the NEXT update's timestamp digits.
They are separate records and are evaluated separately. The reported line number
stays the physical one — a segment index would name a position no editor can
find — and needle matching is unaffected, because the window pass reads every
byte either way. The residual: a structural SHAPE that straddles a literal `\r`
inside one physical line is no longer matched, since no segment holds all of it.
A value split across a reporter's status rewrite is not a rendering anything
produces, and the needle search — byte-level, `\r` included — still finds every
declared value across the split. The seven patterns of
`tooling/e2e/ci/scan-logs-for-secrets.sh` are **not** duplicated here; that
script stays the toolchain-free key-material floor and the wrapper runs both.

Only S7 and S12 have a RULE exemption, and only for the endpoints the run
declares with `seal --exempt-endpoint` (the lane's own loopback relay and proxy,
in host, `host:port` and URL spellings — never a path under them). The cargo
crate-build line above is the only SINK-CLASS one: one shape, two rules, one sink
class, and a declared residual. Everything else needs an `allowlist.json` entry.

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
  separator for it. Finally run it over `fixtures/furniture.*.log`: a rule that
  reddens real furniture reddens a real lane, and rc 1 deletes the lane's
  evidence.

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

The four `furniture.*.log` corpora are the one exception, and the
reason is the point: they are **real** lines, verbatim from the uploaded
transcripts of CI run 34766632019, whose first scan returned rc 1 on nothing but
false positives. A synthetic clean fixture only says what the author of a rule
expected a log to look like. These say what a log looks like — tooling preamble,
vendor chatter, Rust module paths, Dart and Java type names, durations, bucket
tokens, alias handles — and every line was reviewed against Rule 15 before it
was pinned (no hex run of eight or more, no key material, no URL, host or
address, no coordinate, no name, no wall-clock instant, nothing the harness
printed about the run). The cargo block of `furniture.rust-test.log` is the one
deliberate exception on two of those counts, and both are public toolchain
facts rather than identifiers: the 40-hex pinned MDK revision, which
`haven-core/Cargo.lock` carries in the clear, and the `github.com` /
`doc.rust-lang.org` URLs cargo itself prints. Neither tells one user, circle or
device from another, and a corpus that omitted them could not prove the lines
that reddened a real lane are furniture. The logcat corpus carries only
Haven-OWNED tags, because
a vendor-tagged line is skipped by tag scoping and would prove nothing. They are
asserted twice: case N of `--self-test` (with the sealed manifest, so needles
count too) and `real_furniture_trips_no_structural_rule` under `cargo test`.
A rule tightening that would redden a real lane is red here first.

`furniture.rust-test.log` and `furniture.flutter-test.log` are the same thing for
the two UNIT-test transcripts, mined from sanitised local transcripts of this tree's
own `cargo test` and `flutter test` runs and from the two red jobs of CI run
35244067610, reviewed line by line — the files
themselves are the record — and they carry the five
shapes those transcripts trip that a device log never does: the module path
`location::geohash::tests::…` (S6), a camel-case Dart test description and a
repository path over the Shannon floor (S4), the compact reporter's
carriage-return-joined status line (S8), the github reporter's one-line-per-test
shape whose names carry a vocabulary number (S4 again, digit runs), and cargo's
own coloured status block — ESCAPE BYTES INCLUDED, which is what makes the
corpus prove the stripper as well as the exemption (S2 on every pinned git
revision, S6 on one crate name; the `Finished`, `Running` and `Doc-tests` lines
in the same block are NOT exempt and are clean on their own, which is what makes
them controls rather than passengers). Each file's header says what was
selected and what was deliberately left out — the `#[ignore]` reason that names a
local Blossom server by loopback URL is NOT in the cargo corpus, because it is a
real address that S12 is right to see and the lanes exempt it explicitly instead;
the app lines whose alias handles the sanitiser masked are not in the Flutter
corpus, because a masked line is not verbatim.

`format.ios.log` is documented under **Sink framing** above: one line per column
variant, and the only fixture in the tree whose shape comes from a specification
rather than from a capture.
