#!/usr/bin/env bash
# CI guard: no IDENTIFIER may be interpolated into a log, print or panic call
# (Log anonymity pillar, Security Rule 15).
#
# ## Why a second source guard beside check_no_key_logging.sh
#
# The key guard asks one question — "is this value key material?" — and its
# whole design (public names pass, counts pass, `{:?}` passes) follows from it.
# Rule 15 asks a different one: "could a relay operator, a co-member, an
# issue-tracker reader or an OEM log collector use this value to tell this
# user, circle or device apart from any other?" The answer is yes for almost
# everything the key guard lets through: a pubkey, a relay URL (the default
# pool included), a nostr_group_id, a circle name, a coordinate, an absolute
# epoch, an exact count, an absolute instant, and any `{:?}` whose Debug the
# reviewer has not read. The same lexer serves both guards; the vocabulary and
# the verdicts differ, so they are two scripts rather than one with two moods.
#
# ## What is analysed (identical to the key guard)
#
# Per invocation (multi-line, balanced parens): the contents of every
# `{…}` / `${…}` / `$ident` placeholder and the argument expressions with
# string literals removed. Message PROSE is never analysed, so the word
# "relay" in a message is not a hit; the identifier `relay` in an argument is.
# String state is file-scoped, because a literal may span lines.
#
# ## Verdicts
#
#   identifier   an argument/placeholder identifier — or any `_`-part of it
#                after decamelling, or any `.`-path segment — is in the IDENT
#                vocabulary (pubkeys, group ids, event ids, relays, names,
#                coordinates, epochs, counts, instants, ordinals). Exempt: a
#                boolean (`is_`/`has_`/… prefix, `_ok`/`_enabled`/… suffix), a
#                name that says it is an alias/kind/code/status, and — for the
#                magnitude words only — a name that says it is a delta,
#                bucket, duration or retry. `.runtimeType`, `.isEmpty`,
#                `.is_empty()`, `.is_some()`, `.code`, `.kind` — and Dart's
#                `<enum>.name` on a `kind`/`mode`/`outcome`/… receiver —
#                evaluate to something safe and drop their whole expression.
#   prose        an error or remote-text object (`e`, `err`, `message`,
#                `reason`, `content`, …) rendered whole. Relay NOTICE/OK
#                reasons and `SocketException: … 'relay.example'` arrive that
#                way. Log `${e.runtimeType}` / a typed code instead.
#   count        `.length` / `.len()` / `.count()` / `.size` — an exact
#                magnitude. Bucket it (`magnitude_bucket(…)`) or drop it.
#   debug-format `{:?}` / `{:#?}`: renders whatever the type's Debug chooses,
#                and this scanner cannot see the type. Name the reviewed impl
#                on the line (`// log-scan-ok: FooKind Debug redacts`);
#                check_debug_impls_covered.sh is what proves it redacts.
#   shape        an encoding or truncation that renders an identifier
#                whatever its name: `to_hex()`, `hex::encode(`, `.get(..8)`,
#                `.take(4)`, `substring(`, `toRadixString(`, `{:x?}`, typed
#                `PublicKey::`/`EventId::`/`Url::` values, `dbg!`,
#                serialisation. "Redacted" means ABSENT, never a visible
#                prefix, so every truncation is a shape.
#   unknown macro `<crate>::info!` for any crate but `log`, or `#[instrument]`
#                — a logging path this scanner does not read.
#
# What passes: an alias handle (`log_alias::circle(…)` / `logAliasHandle(…)`,
# or a wrapper whose name ends in `_handle`/`_alias`), a bucket
# (`magnitude_bucket(…)`), a relative offset (`relative_secs(…)`),
# `${e.runtimeType}`, `error.code`, a boolean, a delta, and any invocation
# carrying `// log-scan-ok: <reason>` on one of its own lines or the line
# above. The reason is mandatory and the marker never blankets a file.
#
# A blessed NAME is not a blessed value: every definition whose name matches
# the wrapper vocabulary (outside the canonical `log_alias` modules) is read
# too, and must call the canonical module and return a `LogHandle`/`String`
# (Rust) — `fn relay_handle(u: &str) -> &str { u }` is a hole, not a wrapper.
#
# Panic text reaches stderr and logcat outside the logger allowlist, so
# `panic!`, `unreachable!`, the `assert!` family (their operands render as
# `{:?}` on failure) and `.expect(` are scanned like log calls.
#
# A thrown Dart message is a log line too: `flutter drive` prints an uncaught
# exception's `toString()` into the drive transcript, the same uploaded sink a
# panic message reaches on the Rust side — so the Dart `CALL` vocabulary scans
# `fail(` and ANY bare (unnamed) constructor call whose own name ends in
# `Exception(` or `Error(` — Dart's own `StateError`/`ArgumentError`/
# `FormatException`/`Exception`/`UnsupportedError`/`RangeError`/
# `TimeoutException` and every project-defined one alike (`NpubValidation
# Exception(`, `IdentityServiceException(`, …) — exactly like `debugPrint`/
# `print`. The name must start with an (optionally `_`-prefixed) UPPERCASE
# letter — Dart's own class-naming convention — or be the bare word
# `Exception`; this is what keeps an ordinary camelCase method or function
# DECLARATION that happens to end in `Error` (`recordPublishError(Object
# error) {`, `_setError(String? message) {`, a `flutter gen-l10n` string
# builder like `circleMemberRemoveError(String name)`) from being misread as
# a constructor call — the regex sees only `NAME(` shape and cannot tell a
# declaration from a call any other way. Only the bare (unnamed) constructor
# form is recognised —
# `ArgumentError.value(`/`RangeError.range(` are a known gap, not scanned by
# this guard or the harness lint of the same name, because the call name
# immediately preceding `(` is the method (`value`/`range`), not the
# type. As of the 2026-09-16 H6 pass the tree has NO value-bearing
# named-constructor call — every `.value(`/`.range(` site under
# `haven/integration_test` was converted to the bare form or drops the value
# entirely — so the gap is empty, not just unscanned; the self-test pins
# `ArgumentError.value(` as unmatched so a future regression is a tested
# property, not an assumption.
#
# A Dart `String toString()` override is a log line too, and the one nobody
# writes deliberately: it renders the moment the object is interpolated into a
# `debugPrint`, thrown, dumped by a Flutter error handler or printed as a
# failing `expect`'s `Actual:` line — and `check_debug_impls_covered.sh`, the
# guard that enumerates the same class in Rust, reads `impl Debug/Display` and
# `thiserror` only. So the override's BODY is scanned as one invocation: the
# `=>` form to its terminating `;`, the braced form to the brace that closes
# it. Every verdict applies unchanged, with ONE exemption: the object's own
# whole-token `message`/`msg` field, because `'FooException: $message'` is
# Dart's exception idiom and the text was already classified where it was
# CONSTRUCTED (`FooException(` is itself in this vocabulary). Any other prose
# in a `toString()` — `$reason`, `${e.message}`, `$content` — still counts.
#
# `haven/integration_test` is scanned as its own root with its own floor: a
# harness print lands in the drive transcript, which is uploaded on failure,
# so the pillar applies; the harness's own `// harness-log-ok: <reason>` marker
# (the one haven/test/lints/harness_assertion_redaction_test.dart honours) is
# honoured there and only there, under the same reason-required rule.
#
# `tooling/soak` (src AND tests) is scanned the same way — its own Rust pass,
# its own floor, NOT merged into `rust_files` — for a sharper reason than the
# harness's. The soak rig builds real devices, real circles and real relays in
# one process and writes every line it captures to a file the lane uploads, so
# a print there reaches the same artifact a device log does. Two consequences
# are deliberate and are decisions, not omissions:
#
#   * The floor is SEPARATE. Merging the rig into the product's Rust pass would
#     let a collapse in one root be masked by volume in the other, which is the
#     exact rot a floor exists to catch.
#   * The `wrappers` pass is NOT extended to it. That pass requires any
#     function named `*_alias`/`*_handle`/`bucket`/`magnitude_bucket`/
#     `relative_secs` to call `haven_core::log_alias`, and the rig CANNOT: the
#     production salt is `OsRng`, per-process and un-injectable, while the
#     rig's tags must be deterministic for `tests/determinism.rs` to mean
#     anything (same seed ⇒ identical `simdev#`/`simcircle#`/`simrelay#`
#     tables). So the rig mints its own ordinals through functions named
#     OUTSIDE that vocabulary — `sim_tag()`, `sim_magnitude()` — and its tags
#     are disjoint from production's (`simdev#` vs `circle#`), because both land
#     in the same evidence file from the same process. Buying determinism by
#     injecting a salt into `haven_core::log_alias` is the move this exemption
#     exists to forbid.
#
# Not covered, deliberately: generated bindings, Rust `#[cfg(test)]`
# modules (a test's panic message is its diagnostic and never ships; the
# in-process LogCapture tests cover what production code logs UNDER test),
# the `assert!` family, and `format!` strings that become FFI error strings
# (Rule 8 and `redact_hex_sequences` own that boundary). A name-shaped scan cannot see a
# value whose name says nothing (`buf`, `v`); the in-process LogCapture tests
# and the runtime scanner are the other two dimensions.
#
# Exit codes:
#   0  all checks pass
#   1  a violation was found
#   2  expected paths missing / floor breached / self-test failed

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
readonly REPO_ROOT
readonly SCRIPT_NAME='check_no_identifier_logging'

# Anti-vacuity floors: invocations SCANNED, not hits, ~20% below the counts the
# key guard measured (Rust 92, Dart 479). A parser that stopped recognising
# invocations collapses well past them.
readonly MIN_RUST_SITES=70
# Re-measured 2026-09-18: the Dart CALL vocabulary gained the `String
# toString()` override (its BODY is one invocation), which raised the count
# from 776 to 802 invocations under haven/lib — the 26 overrides the tree has.
# The 2026-09-16 (H6) pass before it had widened from a fixed exception-name
# list to ANY (optionally `_`-prefixed) PascalCase identifier ending in
# `Exception`/`Error` (plus the bare word `Exception`), 479 to 776
# (constructor DECLARATIONS forwarding `this.`/`super.` are not calls).
# floor(802 × 0.8).
readonly MIN_DART_SITES=641
# Re-measured 2026-09-18: the same `toString()` widening took
# haven/integration_test from 481 to 485 (4 overrides), and adding `note(`/
# `record(` — b8's own diagnostic sinks, whose arguments no scanner read
# before — took it to 494 (9 call sites; the two DECLARATIONS are typed
# parameter lists and are skipped). floor(494 × 0.8).
readonly MIN_ITEST_SITES=395
# `tooling/soak/{src,tests}`, its own root with its own floor (see the header).
# Re-measured 2026-09-18, the commit that completes the crate: 227 invocations
# under tooling/soak; floor(227 x 0.8) = 181. The provisional 1 was the
# smallest floor that still reds an extractor that stopped matching; now it is the
# same 20 % margin the other roots carry.
# Re-measured 2026-09-19: 334. The review pass added the per-scenario
# mis-configuration controls, the capture binary and the rendering enumeration,
# and every assertion message in them is a panic invocation this scanner reads.
# floor(334 x 0.8) = 267; leaving 181 would have let the extractor lose nearly
# half its population and stay green.
readonly MIN_SOAK_SITES=267
# Same contract for the wrapper-DEFINITION scan, whose population `scan()`'s
# floors cannot see: measured 2 (Rust) and 7 (Dart, haven/lib + the harness)
# on 2026-09-18. floor(2 × 0.8) = 1 and floor(7 × 0.8) = 5 — a lexer that
# stopped recognising definitions collapses past them, and a definition that
# is never read is a `relay_handle` nobody checked.
readonly MIN_RUST_WRAPDEFS=1
readonly MIN_DART_WRAPDEFS=5

# The vocabulary. Whole decamelled identifiers and every `_`-part of them.
# STRONG words identify on their own; WEAK words are magnitudes and instants,
# which a delta/bucket/duration part may relativise.
readonly STRONG_WORDS='nostr_group_id group_hex group_id gid group circle circle_id h_tag npub nsec pubkey pub_key public_key pk author sender recipient inviter event_id evt evt_id evt_tag evt_prefix d_tag slot sub_id subscription_id relay relays relay_url url urls host domain endpoint uri ip ssid display_name petname nickname circle_name name title label about notes blossom picture avatar sha256 digest hash hex bech32 hash_code lat latitude lon longitude geohash altitude speed heading accuracy device_id locale tz timezone id ids peer peers member members contact contacts owner admin admins index idx ordinal seq sequence serial'
readonly WEAK_WORDS='epoch since until created_at timestamp at_ms instant count size total len responders canonical acked inputs sources'
# The INSTANT subset of WEAK_WORDS. A unit part says how a magnitude is
# measured, so `totalMs` is a span rather than a count — but it says nothing
# about an origin, and `pauseSinceSecs` is still somebody's wall clock. Units
# therefore relativise a magnitude and never an instant.
readonly INSTANT_WORDS='epoch since until created_at timestamp at_ms instant'
readonly UNIT_PARTS='secs seconds millis ms'
readonly PROSE_WORDS='e err error exception ex cause stack_trace stack trace panic reason message msg notice detail details description text body content payload raw json response resp line summary result describe rejection'
readonly BOOL_PREFIXES='is has was were are can could should needs did does will had have must may'
# `acked` is deliberately NOT here: it is a WEAK magnitude word, and a name
# cannot be both "a count" and "proof of boolean-ness" — `relaysAcked` is an
# int. A genuine boolean takes a prefix (`wasAcked`, `isAcked`).
readonly BOOL_SUFFIXES='ok enabled disabled present known ready changed stale fresh valid missing configured allowed dirty reachable healthy sent done empty matched verified exists supported granted denied needed required connected'
# A name that says it is a classification, not a value.
readonly CLASS_PARTS='alias handle kind code class variant tier policy mode status state phase outcome verdict decision action'
# ...and, for magnitude/instant words only, one that says it is relative.
readonly RELATIVE_PARTS='delta diff behind ahead gap lag offset elapsed relative bucket bucketed ago duration latency timeout interval delay backoff max min limit cap threshold budget quota retry retries attempt attempts secs seconds millis ms'

log()  { printf '\033[1;34m[%s]\033[0m %s\n' "${SCRIPT_NAME}" "$*"; }
fail() { printf '\033[1;31m[%s] FAIL:\033[0m %s\n' "${SCRIPT_NAME}" "$*" >&2; }
misconfig() { printf '\033[1;31m[%s] BROKEN:\033[0m %s\n' "${SCRIPT_NAME}" "$*" >&2; exit 2; }

# Shapes: `<label>\t<ERE>` per line, matched over placeholder + argument code
# after alias/bucket calls are stripped. Exported through the environment so
# no backslash passes through `awk -v` escape processing.
SHAPES_RUST="$(printf '%s\n' \
  $'to_hex()\tto_hex\\(' \
  $'hex::encode(\thex::encode\\(' \
  $'to_bech32()\tto_(bech32|nostr_uri)\\(' \
  $'prefix slice\t\\.get\\(\\.\\.[0-9]+\\)|\\[[0-9]*\\.\\.=?[0-9]+\\]' \
  $'.take(N)\t\\.take\\([0-9]+' \
  $'truncate(\ttruncate(_chars)?\\(' \
  $'base64\tbase64|STANDARD\\.encode\\(' \
  $'typed identifier value\t(^|[^A-Za-z0-9_])(Keys|SecretKey|PublicKey|EventId|Url|RelayUrl|GroupId)::' \
  $'serialised object\tserde_json::to_string|to_json\\(' \
)"
SHAPES_DART="$(printf '%s\n' \
  $'toRadixString(\ttoRadixString\\(' \
  $'substring(\t\\.substring\\(' \
  $'.take(\t\\.take\\(' \
  $'hex.encode(\t(^|[^A-Za-z0-9_])(hex|HEX)\\.encode\\(' \
  $'base64\tbase64(Url)?Encode\\(|base64\\.encode\\(' \
  $'serialised object\tjsonEncode\\(|json\\.encode\\(|\\.toJson\\(' \
)"
readonly SHAPES_RUST SHAPES_DART
# The scanner reads its vocabulary from the environment: nothing passes through
# `awk -v` escape processing, and a readonly cannot be prefix-assigned anyway.
export STRONG_WORDS WEAK_WORDS INSTANT_WORDS UNIT_PARTS PROSE_WORDS BOOL_PREFIXES BOOL_SUFFIXES CLASS_PARTS RELATIVE_PARTS SHAPES_RUST SHAPES_DART

# ---------------------------------------------------------------------------
# The scanner. One program for both languages; `lang` selects delimiters,
# interpolation syntax and call vocabulary. Prints one line per violating
# invocation and, last, `#sites <n>` for the anti-vacuity floor.
# ---------------------------------------------------------------------------
read -r -d '' SCAN_AWK <<'AWK' || true
function words_re(s) { gsub(/ +/, "|", s); return "^(" s ")$" }
BEGIN {
  STRONG = words_re(ENVIRON["STRONG_WORDS"])
  WEAK   = words_re(ENVIRON["WEAK_WORDS"])
  IDENT  = words_re(ENVIRON["STRONG_WORDS"] " " ENVIRON["WEAK_WORDS"])
  PROSE  = words_re(ENVIRON["PROSE_WORDS"])
  BOOLP  = words_re(ENVIRON["BOOL_PREFIXES"])
  BOOLS  = words_re(ENVIRON["BOOL_SUFFIXES"])
  CLASSP = words_re(ENVIRON["CLASS_PARTS"])
  RELP   = words_re(ENVIRON["RELATIVE_PARTS"])
  INSTP  = words_re(ENVIRON["INSTANT_WORDS"])
  UNITP  = words_re(ENVIRON["UNIT_PARTS"])
  nshapes = split(ENVIRON[(lang == "rust") ? "SHAPES_RUST" : "SHAPES_DART"], SH, "\n")
  for (i = 1; i <= nshapes; i++) { split(SH[i], kv, "\t"); SLABEL[i] = kv[1]; SRE[i] = kv[2] }
  MARKER = "(" markers "):[ \t]*[^ \t]"
  if (lang == "rust") {
    CALL  = "(log::(log|trace|debug|info|warn|error)|(^|[^A-Za-z0-9_:])(trace|debug|info|warn|error|println|eprintln|print|eprint|dbg|panic|unreachable|assert|assert_eq|assert_ne|debug_assert|debug_assert_eq|debug_assert_ne))![ \t]*\\(|\\.expect\\([ \t]*&?format!\\("
    WRAP  = "(^|[^A-Za-z0-9_])(log_alias::[a-z_]+|[a-z0-9_]*_(handle|alias)|magnitude_bucket|bucket|relative_secs|relative_ms|since_origin)[ \t]*\\("
    SAFE  = "[A-Za-z_][A-Za-z0-9_.]*\\.((is_empty|is_some|is_none|is_ok|is_err)\\(\\)|(code|kind)(\\(\\))?)"
    COUNT = "[A-Za-z_][A-Za-z0-9_.]*\\.(len|count)\\(\\)"
    UNKNOWN = "(^|[^A-Za-z0-9_])[A-Za-z0-9_]+::(trace|debug|info|warn|error|event)!"
  } else {
    CALL  = "(^|[^A-Za-z0-9_.])(debugPrint|debugPrintThrottled|print|developer\\.log|dev\\.log|stderr\\.write|stderr\\.writeln|stdout\\.write|stdout\\.writeln|assert|fail|note|record|Exception|_?[A-Z][A-Za-z0-9_]*(Exception|Error))[ \t]*\\(|(^|[^A-Za-z0-9_])String[ \t]+toString\\(\\)[ \t]*(=>|\\{)"
    WRAP  = "(^|[^A-Za-z0-9_.])(logAliasHandle|logAlias|(_?[a-z][a-zA-Z0-9_]*)?(Handle|Alias)|magnitudeBucket|bucket|relativeSecs|relativeMs|sinceOrigin)[ \t]*\\("
    # `.name` on an enum is Dart's variant-name idiom (`outcome.name`,
    # `expectedTier.name`); on a circle it is user text. The receiver's last
    # segment decides, by its last decamelled part.
    # `details.library` is FlutterErrorDetails' library NAME ("widgets library").
    # `?.` is the null-aware spelling of the same accessor.
    # `x != null` / `x == null` renders `true`/`false` whatever `x` holds —
    # the presence-flag idiom (`hasPicture: ${pictureBytes != null}`).
    SAFE  = "[A-Za-z_][A-Za-z0-9_.]*\\??\\.(runtimeType|isEmpty|isNotEmpty|code|kind|library)|([A-Za-z_][A-Za-z0-9_.]*\\??\\.)?(kind|mode|status|state|outcome|decision|disposition|category|phase|tier|action|policy|verdict|class|variant|level)\\.name|[A-Za-z_][A-Za-z0-9_.]*(Kind|Mode|Status|State|Outcome|Decision|Disposition|Category|Phase|Tier|Action|Policy|Verdict|Class|Variant|Level)\\.name|[A-Za-z_][A-Za-z0-9_.]*[ \t]*[!=]=[ \t]*null"
    COUNT = "[A-Za-z_][A-Za-z0-9_.]*\\??\\.(length|size)"
    UNKNOWN = ""
  }
  BOUND = "([^A-Za-z0-9_(]|$)"
}

# Splits a line into CODE (string literals and the trailing comment removed),
# STRS (the concatenated literal contents, `${…}` expressions included) and
# COMMENT. The nesting stack (NDEPTH/NKIND/NQ/NBRACE) and ESC are FILE state,
# not line state: a literal may span newlines.
#
# Dart lets a `${…}` hold another literal — `'${ok ? 'a' : 'b'}'`,
# `"${m['k']}"` — so inside an interpolation a quote OPENS a nested string
# rather than closing the outer one. Reading it as a close desyncs the rest of
# the line, and an `//` or an unbalanced paren from the inner literal then
# reaches CODE: the invocation is dropped UNSCANNED (it never reaches emit(),
# so it is not even counted), which reads exactly like a clean one.
function split_line(s,   i, n, c) {
  CODE = ""; STRS = ""; COMMENT = ""
  n = length(s)
  for (i = 1; i <= n; i++) {
    c = substr(s, i, 1)
    if (NDEPTH > 0 && NKIND[NDEPTH] == "S") {
      if (ESC) { ESC = 0; STRS = STRS c; continue }
      if (c == "\\") { ESC = 1; continue }
      if (c == NQ[NDEPTH]) { NDEPTH--; STRS = STRS " "; continue }
      if (lang == "dart" && c == "$" && substr(s, i + 1, 1) == "{") {
        NDEPTH++; NKIND[NDEPTH] = "I"; NBRACE[NDEPTH] = 1
        STRS = STRS "${"; i++
        continue
      }
      # A brace inside a literal NESTED in an interpolation is text, not a
      # delimiter: leaving it in would end placeholders()' `${…}` span early
      # and hide everything the expression says after it.
      if (NDEPTH > 1 && NKIND[NDEPTH - 1] == "I" && (c == "{" || c == "}")) { STRS = STRS " "; continue }
      STRS = STRS c
      continue
    }
    if (NDEPTH > 0 && NKIND[NDEPTH] == "I") {
      # A `${…}` holds an EXPRESSION. It stays in STRS so placeholders() still
      # reads it as one placeholder; a quote in it opens a nested literal,
      # whose own content is the map key / ternary branch being rendered.
      if (c == "\"" || c == "'") { NDEPTH++; NKIND[NDEPTH] = "S"; NQ[NDEPTH] = c; continue }
      if (c == "{") { NBRACE[NDEPTH]++; STRS = STRS c; continue }
      if (c == "}") {
        NBRACE[NDEPTH]--
        if (NBRACE[NDEPTH] == 0) { NDEPTH--; STRS = STRS "}"; continue }
        STRS = STRS c
        continue
      }
      STRS = STRS c
      continue
    }
    if (c == "\"" || (lang == "dart" && c == "'")) { NDEPTH++; NKIND[NDEPTH] = "S"; NQ[NDEPTH] = c; continue }
    # A Rust char literal is not a string opener: `'"'` would otherwise swallow
    # the rest of the file. Lifetimes (`'a` with no closing quote) fall through.
    if (lang == "rust" && c == "'") {
      if (substr(s, i + 2, 1) == "'") { CODE = CODE " "; i += 2; continue }
      if (substr(s, i + 1, 1) == "\\" && substr(s, i + 3, 1) == "'") { CODE = CODE " "; i += 3; continue }
    }
    if (c == "/" && substr(s, i + 1, 1) == "/") { COMMENT = substr(s, i); break }
    CODE = CODE c
  }
}

# Placeholder contents only — never the prose around them. Rust format specs
# are read here too: `?` is a Debug render, `x`/`X` a hex one.
function placeholders(s,   out, rest, p, spec) {
  out = ""; rest = s
  if (lang == "rust") {
    while (match(rest, /\{[^{}]*\}/)) {
      p = substr(rest, RSTART + 1, RLENGTH - 2)
      rest = substr(rest, RSTART + RLENGTH)
      spec = ""
      if (index(p, ":")) { spec = substr(p, index(p, ":") + 1); p = substr(p, 1, index(p, ":") - 1) }
      if (spec ~ /\?/) DBG = 1
      if (spec ~ /[xX]/) HEXF = 1
      out = out " " p
    }
    return out
  }
  while (match(rest, /\$\{[^{}]*\}|\$[A-Za-z_][A-Za-z0-9_.]*/)) {
    p = substr(rest, RSTART, RLENGTH)
    sub(/^\$\{?/, "", p); sub(/\}$/, "", p)
    out = out " " p
    rest = substr(rest, RSTART + RLENGTH)
  }
  return out
}

# Consumes `s` while the invocation is open. Appends the consumed CODE to ARGS,
# leaves whatever followed the closing paren in TAIL, and returns 1 on close.
function consume(s,   i, n, c) {
  n = length(s)
  for (i = 1; i <= n; i++) {
    c = substr(s, i, 1)
    if (c == "(") DEPTH++
    else if (c == ")") {
      DEPTH--
      if (DEPTH == 0) { ARGS = ARGS " " substr(s, 1, i - 1); TAIL = substr(s, i + 1); return 1 }
    }
  }
  ARGS = ARGS " " s
  TAIL = ""
  return 0
}

# consume()'s twin for a `toString()` body, which is delimited by neither end
# of a paren pair: the `=>` form closes at its first top-level `;` (a literal
# one never reaches here — CODE has the string contents removed), the braced
# form at the brace matching the one the CALL match already consumed.
function consume_body(s,   i, n, c) {
  n = length(s)
  for (i = 1; i <= n; i++) {
    c = substr(s, i, 1)
    if (CLOSER == ";") {
      if (c != ";") continue
      ARGS = ARGS " " substr(s, 1, i - 1); TAIL = substr(s, i + 1); return 1
    }
    if (c == "{") DEPTH++
    else if (c == "}") {
      DEPTH--
      if (DEPTH == 0) { ARGS = ARGS " " substr(s, 1, i - 1); TAIL = substr(s, i + 1); return 1 }
    }
  }
  ARGS = ARGS " " s
  TAIL = ""
  return 0
}

# Removes every alias/bucket/relative-time call WITH its balanced argument, so
# the identifier being aliased is not itself classified.
function strip_wrapped(s,   out, i, n, c, depth) {
  out = ""
  while (match(s, WRAP)) {
    # The boundary character is part of the match; keep it.
    out = out substr(s, 1, RSTART - 1) ((substr(s, RSTART, 1) ~ /[A-Za-z0-9_]/) ? "" : substr(s, RSTART, 1)) " wrapped "
    n = length(s); depth = 0
    for (i = RSTART + RLENGTH - 1; i <= n; i++) {
      c = substr(s, i, 1)
      if (c == "(") depth++
      else if (c == ")") { depth--; if (depth == 0) break }
    }
    s = substr(s, i + 1)
  }
  return out s
}

# `mlsDbKey` and `mls_db_key` are one identifier in two casings; splitting on
# the case boundary lets ONE vocabulary serve both languages.
function decamel(s,   i, n, c, p, out) {
  out = ""; n = length(s)
  for (i = 1; i <= n; i++) {
    c = substr(s, i, 1)
    if (c ~ /[A-Z]/) {
      p = (i > 1) ? substr(s, i - 1, 1) : "_"
      if (p ~ /[a-z0-9]/) out = out "_"
    }
    out = out c
  }
  return tolower(out)
}

# An accessor decides what an expression EVALUATES to: `e.runtimeType` is a
# type name, `relays.length` is a count. Safe ones vanish; counts vanish too
# but leave a verdict behind.
function drop_accessors(s) {
  while (match(s, COUNT)) {
    if (substr(s, RSTART + RLENGTH, 1) ~ /[A-Za-z0-9_(]/) { s = substr(s, 1, RSTART) "~" substr(s, RSTART + 1); continue }
    COUNTHIT = 1
    s = substr(s, 1, RSTART - 1) " " substr(s, RSTART + RLENGTH)
  }
  while (match(s, SAFE)) {
    if (substr(s, RSTART + RLENGTH, 1) ~ /[A-Za-z0-9_(]/) { s = substr(s, 1, RSTART) "~" substr(s, RSTART + 1); continue }
    s = substr(s, 1, RSTART - 1) " " substr(s, RSTART + RLENGTH)
  }
  gsub(/~/, "", s)
  return s
}

function add(list, item) { return (list == "" ? item : list ", " item) }

# One token: identifier / prose / clean. Whole-token matches are decided
# before any exemption — `hashCode` says "code" and is still an identifier.
function verdict(tok,   n, i, parts, pair, strong, weak, instant, prose) {
  sub(/^_+/, "", tok)
  if (tok == "") return ""
  # `'FooException: $message'` is Dart's exception-rendering idiom; the text
  # was classified where the exception was CONSTRUCTED, so the pass-through
  # is not a second dimension — only a marker on every exception class.
  #
  # That premise holds for EXACTLY the classes whose constructor this
  # vocabulary scans, i.e. the ones whose name ends in `Exception`/`Error`.
  # A type that merely `implements Exception` under another name
  # (`class _SocketDied implements Exception`) is never scanned at
  # construction, so its `toString()` is the only reading this guard gets.
  if (KIND == "tostring" && CLASSNAME ~ /(Exception|Error)$/ && (tok == "message" || tok == "msg")) return ""
  if (tok ~ IDENT) return "identifier"
  if (tok ~ PROSE) return "prose"
  n = split(tok, parts, "_")
  if (n < 2) return ""
  if (parts[1] ~ BOOLP || parts[n] ~ BOOLS) return ""
  strong = 0; weak = 0; instant = 0; prose = 0
  for (i = 1; i <= n; i++) {
    if (parts[i] ~ CLASSP) return ""
    if (parts[i] ~ STRONG) strong = 1
    if (parts[i] ~ WEAK) weak = 1
    if (parts[i] ~ INSTP) instant = 1
    if (parts[i] ~ PROSE) prose = 1
    # A multi-word entry (`created_at`, `at_ms`) can only ever match a WHOLE
    # token, so `createdAtSecs`/`expiresAtMs` — three parts, none of them a
    # word on its own — would name an absolute instant and read as clean.
    # Testing adjacent PAIRS is what sees them, and it adds no vocabulary
    # (so a boolean like `published` is still a boolean).
    if (i < n) {
      pair = parts[i] "_" parts[i + 1]
      if (pair ~ STRONG) strong = 1
      if (pair ~ WEAK) weak = 1
      if (pair ~ INSTP) instant = 1
    }
  }
  if (strong) return "identifier"
  if (weak) {
    for (i = 1; i <= n; i++) if (parts[i] ~ RELP && !(instant && parts[i] ~ UNITP)) return ""
    return "identifier"
  }
  if (prose) return "prose"
  return ""
}

function classify(text,   rest, tok, v) {
  IDENTS = ""; PROSES = ""
  # Rust constructors read as words otherwise (`Err(e)` -> `err`).
  if (lang == "rust") gsub(/(^|[^A-Za-z0-9_])(Ok|Err|Some|None)([^A-Za-z0-9_]|$)/, " ", text)
  rest = decamel(text)
  while (match(rest, /[a-z_][a-z0-9_]*/)) {
    tok = substr(rest, RSTART, RLENGTH)
    rest = substr(rest, RSTART + RLENGTH)
    v = verdict(tok)
    if (v == "identifier") IDENTS = add(IDENTS, tok)
    else if (v == "prose") PROSES = add(PROSES, tok)
  }
}

# Everything after the first top-level comma: a plain assert's condition is
# rendered as SOURCE TEXT on failure, never as values — only its message is.
function after_first_comma(s,   i, n, c, depth) {
  n = length(s); depth = 0
  for (i = 1; i <= n; i++) {
    c = substr(s, i, 1)
    if (c == "(" || c == "[" || c == "{") depth++
    else if (c == ")" || c == "]" || c == "}") depth--
    else if (c == "," && depth == 0) return substr(s, i + 1)
  }
  return ""
}

function emit(   f, text, i) {
  sites++
  if (SUPP) return
  f = ""
  if (KIND == "assert") ARGS = after_first_comma(ARGS)
  if (KIND == "dbg") f = add(f, "dbg! renders Debug")
  if (DBG)  f = add(f, "debug-format {:?} (name the reviewed impl: log-scan-ok: <Type> Debug redacts)")
  if (HEXF) f = add(f, "shape(hex format)")
  text = strip_wrapped(PH " " ARGS)
  for (i = 1; i <= nshapes; i++) if (text ~ SRE[i]) f = add(f, "shape(" SLABEL[i] ")")
  COUNTHIT = 0
  text = drop_accessors(text)
  if (COUNTHIT) f = add(f, "count(.length/.len()/.count()/.size — bucket it)")
  classify(text)
  if (IDENTS != "") f = add(f, "identifier(" IDENTS ")")
  if (PROSES != "") f = add(f, "prose(" PROSES ")")
  if (f != "") printf "%s:%d: %s | %s\n", FILENAME, START, f, SRC
}

# `tracing::` and friends: a logging path this scanner does not read.
function unknown_macros(code,   rest, m, pre) {
  if (code ~ /#\[(tracing::)?instrument/) {
    printf "%s:%d: unknown-macro(#[instrument] records every argument's Debug) | %s\n", FILENAME, FNR, $0
  }
  if (UNKNOWN == "") return
  rest = code
  while (match(rest, UNKNOWN)) {
    m = substr(rest, RSTART, RLENGTH)
    rest = substr(rest, RSTART + RLENGTH)
    pre = m; sub(/^[^A-Za-z0-9_]/, "", pre); sub(/::.*$/, "", pre)
    if (pre != "log") printf "%s:%d: unknown-macro(%s:: is not a logger this guard reads) | %s\n", FILENAME, FNR, pre, $0
  }
}

# A test-gated item (`#[cfg(test)]`, `#[cfg(any(test, …))]`) is skipped: a
# `mod tests {`, a `macro_rules!`, a helper `fn`, a `static`. The block ends at
# a `}` on the item's OWN indentation — rustfmt is CI-enforced, and counting
# braces is defeated by the raw-string JSON a test module carries. Returns 1
# while the line belongs to a skipped item.
function skip_test_gated(code,   ind) {
  if (SKIPPING) {
    if (code ~ ("^" SKIPIND "\\}")) SKIPPING = 0
    return 1
  }
  if (code ~ /#\[cfg\((any\(|all\()?test[,)]/) { CFGTEST = 1; return 1 }
  if (!CFGTEST) return 0
  if (code ~ /^[ \t]*(#\[|$)/) return 1          # further attributes, blank
  CFGTEST = 0
  if (index(code, "{")) {
    match(code, /^[ \t]*/); SKIPIND = substr(code, 1, RLENGTH)
    if (code !~ ("^" SKIPIND "[^ \t].*\\}[ \t]*;?[ \t]*$") || index(code, "{") > index(code, "}")) SKIPPING = 1
    return 1
  }
  if (code ~ /;[ \t]*$/) return 1                # a one-line item or statement
  SKIPPING = 1; match(code, /^[ \t]*/); SKIPIND = substr(code, 1, RLENGTH)
  return 1
}

# A file that ends mid-literal means the lexer lost the thread somewhere above,
# and every verdict after that point was reached on a guess. Report it as a
# violation instead of carrying the depth into the next file.
function check_terminated(f, l) {
  if (NDEPTH > 0) printf "%s:%d: lexer(file ends inside a string or ${…} — every verdict in it was reached on a guess) | <EOF>\n", f, l
  NDEPTH = 0
}
FNR == 1 { if (PREVFILE != "") check_terminated(PREVFILE, PREVNR); PREVFILE = FILENAME
           INMAC = 0; ESC = 0; prev_supp = 0; CFGTEST = 0; SKIPPING = 0; SKIPIND = ""; CLASSNAME = "" }
{ PREVNR = FNR }
{
  split_line($0)
  if (lang == "rust" && skip_test_gated(CODE)) next
  unknown_macros(CODE)
  # The enclosing type, for the `toString()` rules. Dart has no nested types,
  # so the last declaration seen above a line IS the one it sits in.
  if (lang == "dart" && match(CODE, /(^|[^A-Za-z0-9_])(class|mixin|enum)[ \t]+_?[A-Za-z][A-Za-z0-9_]*/)) {
    CLASSNAME = substr(CODE, RSTART, RLENGTH); sub(/^.*[ \t]/, "", CLASSNAME)
  }
  supp_here = (COMMENT ~ MARKER)
  rest = CODE
  while (1) {
    if (INMAC) {
      if (supp_here) SUPP = 1
      PH = PH placeholders(STRS)
      if (!((CLOSER == ")") ? consume(rest) : consume_body(rest))) break
      emit(); INMAC = 0; rest = TAIL
    } else {
      if (!match(rest, CALL)) break
      m = substr(rest, RSTART, RLENGTH)
      # `const FooException(this.message)` / `({required super.message})` is a
      # constructor DECLARATION sharing a call's shape; it renders nothing. A
      # `toString()` never is one, and `=> super.toString()` must not read as
      # one either. `void record(String phase, String detail) {` is the same
      # shape again: a parameter list opens with a TYPE (uppercase, by Dart's
      # own naming convention), an argument list never does — `record(phase,
      # failure)` and `note('p', x)` both start lowercase or with a literal.
      if (lang == "dart" && m !~ /toString/ && substr(rest, RSTART + RLENGTH) ~ /^[ \t]*([{[]?[ \t]*(required[ \t]+)?(this|super)\.|(final[ \t]+|const[ \t]+)?[A-Z][A-Za-z0-9_<>?,]*[ \t]+[a-z_])/) {
        rest = substr(rest, RSTART + RLENGTH); continue
      }
      INMAC = 1; PH = ""; ARGS = ""; TAIL = ""; DBG = 0; HEXF = 0
      if (m ~ /toString/) {
        KIND = "tostring"
        CLOSER = (m ~ /\{$/) ? "}" : ";"
        DEPTH = (CLOSER == "}") ? 1 : 0
      } else {
        CLOSER = ")"
        DEPTH = gsub(/\(/, "(", m)              # `.expect(&format!(` opens two
        KIND = (m ~ /dbg!/) ? "dbg" : ((m ~ /(^|[^A-Za-z0-9_.])(debug_)?assert!?[ \t]*\(/) ? "assert" : "log")
      }
      START = FNR; SRC = $0; sub(/^[ \t]*/, "", SRC)
      SUPP = (prev_supp || supp_here)
      rest = substr(rest, RSTART + RLENGTH)
    }
  }
  prev_supp = supp_here
}
END { check_terminated(PREVFILE, PREVNR); printf "#sites %d\n", sites }
AWK
readonly SCAN_AWK

# ---------------------------------------------------------------------------
# Wrapper definitions. A name the scanner blesses must be a real wrapper: its
# body calls the canonical module and (Rust) it returns a handle. The canonical
# modules themselves are exempt — their own unit tests are the proof.
# ---------------------------------------------------------------------------
# Its `code_of` keeps the simpler pre-nesting lexer. A nested-quote desync
# there has three outcomes and only ONE of them is loud: a BODY cut short at a
# fake `}` reds a legitimate wrapper (loud), but a `DEF` line hidden inside a
# mis-opened literal drops the definition from the population entirely, and a
# body EXTENDED past its real end can pick up a `logAliasHandle(` from the next
# function and bless a wrapper that has none — both SILENT. The `#defs` floors
# below are what make the first silent case visible; the second is why this
# comment says "simpler", not "safe".
read -r -d '' WRAPDEF_AWK <<'AWK' || true
BEGIN {
  if (lang == "rust") {
    NAMES = "^([a-z0-9_]*_(handle|alias)|bucket|magnitude_bucket|relative_secs|relative_ms|since_origin)$"
    DEF = "^[ \t]*(pub(\\([a-z]+\\))?[ \t]+)?(const[ \t]+)?fn[ \t]+[a-z0-9_]+[ \t]*[(<]"
    CANON = "/haven-core/src/log_alias\\.rs$"
  } else {
    NAMES = "^(logAliasHandle|logAlias|(_?[a-z][a-zA-Z0-9_]*)?(Handle|Alias)|magnitudeBucket|bucket|relativeSecs|relativeMs|sinceOrigin)$"
    DEF = "^[ \t]*(static[ \t]+)?[A-Za-z_][A-Za-z0-9_<>?, ]*[ \t]+_?[a-z][A-Za-z0-9_]*[ \t]*\\("
    CANON = "/haven/lib/src/utils/log_alias\\.dart$"
  }
}
function code_of(s,   i, n, c, out) {
  out = ""; n = length(s)
  for (i = 1; i <= n; i++) {
    c = substr(s, i, 1)
    if (INQ) {
      if (ESC) { ESC = 0; continue }
      if (c == "\\") { ESC = 1; continue }
      if (c == QC) INQ = 0
      continue
    }
    if (c == "\"" || (lang == "dart" && c == "'")) { INQ = 1; QC = c; out = out " "; continue }
    if (lang == "rust" && c == "'" && (substr(s, i + 2, 1) == "'" || (substr(s, i + 1, 1) == "\\" && substr(s, i + 3, 1) == "'"))) { i += (substr(s, i + 2, 1) == "'") ? 2 : 3; continue }
    if (c == "/" && substr(s, i + 1, 1) == "/") break
    out = out c
  }
  return out
}
function verdict(   why, ret) {
  if (lang == "rust") {
    if (BODY !~ /log_alias::/) why = "body never calls log_alias::"
    ret = SIG; if (!sub(/^.*->[ \t]*/, "", ret)) ret = "()"; sub(/[ \t]*\{.*$/, "", ret); sub(/[ \t]+$/, "", ret)
    if (ret !~ /^(([a-z_]+::)*LogHandle|String)$/) why = why (why == "" ? "" : "; ") "returns `" ret "`, not a LogHandle"
  } else {
    if (BODY !~ /(logAliasHandle|logAlias|magnitudeBucket|relativeSecs|relativeMs|sinceOrigin)[ \t]*\(/) why = "body never calls the canonical log_alias helpers"
  }
  if (why != "") printf "%s:%d: wrapper `%s` is not a wrapper: %s | %s\n", FILENAME, START, NAME, why, SRC
  defs++
}
function skip_test_gated(code) {
  if (SKIPPING) { if (code ~ ("^" SKIPIND "\\}")) SKIPPING = 0; return 1 }
  if (code ~ /#\[cfg\((any\(|all\()?test[,)]/) { CFGTEST = 1; return 1 }
  if (!CFGTEST) return 0
  if (code ~ /^[ \t]*(#\[|$)/) return 1
  CFGTEST = 0
  if (index(code, "{")) {
    match(code, /^[ \t]*/); SKIPIND = substr(code, 1, RLENGTH)
    if (code !~ ("^" SKIPIND "[^ \t].*\\}[ \t]*;?[ \t]*$") || index(code, "{") > index(code, "}")) SKIPPING = 1
    return 1
  }
  if (code ~ /;[ \t]*$/) return 1
  SKIPPING = 1; match(code, /^[ \t]*/); SKIPIND = substr(code, 1, RLENGTH)
  return 1
}
FNR == 1 { INQ = 0; ESC = 0; STATE = 0; CFGTEST = 0; SKIPPING = 0; SKIPIND = "" }
FILENAME ~ CANON { next }
{
  code = code_of($0)
  if (lang == "rust" && STATE == 0 && skip_test_gated(code)) next
  if (STATE == 0) {
    if (code !~ DEF) next
    NAME = code; sub(/^.*fn[ \t]+/, "", NAME); if (lang == "dart") { NAME = code; sub(/[ \t]*\(.*$/, "", NAME); sub(/^.*[ \t]/, "", NAME) }
    sub(/[ \t]*[(<].*$/, "", NAME)
    if (NAME !~ NAMES) next
    STATE = 1; SIG = ""; BODY = ""; DEPTH = 0; START = FNR; SRC = $0; sub(/^[ \t]*/, "", SRC)
  }
  if (STATE == 1) {
    if (lang == "dart" && index(code, "=>") && !index(code, "{")) { BODY = substr(code, index(code, "=>")); STATE = 3 }
    else if (index(code, "{")) { SIG = SIG " " substr(code, 1, index(code, "{")); code = substr(code, index(code, "{")); STATE = 2 }
    else { SIG = SIG " " code; next }
  }
  if (STATE == 2) {
    n = length(code)
    for (i = 1; i <= n; i++) {
      c = substr(code, i, 1)
      if (c == "{") DEPTH++
      else if (c == "}") { DEPTH--; if (DEPTH == 0) { BODY = BODY substr(code, 1, i); verdict(); STATE = 0; break } }
    }
    if (STATE == 2) BODY = BODY code "\n"
    next
  }
  if (STATE == 3) {
    if (index(code, ";")) { BODY = BODY substr(code, 1, index(code, ";")); verdict(); STATE = 0 } else BODY = BODY code "\n"
  }
}
END { printf "#defs %d\n", defs }
AWK
readonly WRAPDEF_AWK

run_wrapdef() { awk -v lang="$1" "${WRAPDEF_AWK}" "${@:2}"; }

# wrappers <lang> <min-defs> <label> <file...>
wrappers() {
  local lang="$1" min="$2" label="$3"; shift 3
  local out defs hits
  out="$(run_wrapdef "${lang}" "$@")"
  defs="$(sed -n 's/^#defs //p' <<<"${out}")"
  hits="$(grep -v '^#defs ' <<<"${out}" || true)"
  if [[ -z "${defs}" ]] || (( defs < min )); then
    fail "${label}: found ${defs:-0} wrapper definition(s), expected >= ${min}."
    echo "  The definition reader has stopped matching, so this check proves nothing." >&2
    return 2
  fi
  if [[ -n "${hits}" ]]; then
    fail "${label}: a definition carries a wrapper's NAME without a wrapper's body."
    printf '%s\n' "${hits}" | sed 's/^/    /' >&2
    echo "  The scanner blesses these names; the body must call the canonical log_alias module." >&2
    return 1
  fi
  log "OK: ${label} — ${defs:-0} alias/bucket wrapper definition(s), every one built on log_alias."
}

# The markers a scan honours: `log-scan-ok` everywhere, plus `harness-log-ok`
# under haven/integration_test (SCAN_MARKERS set by the caller).
run_awk() { # run_awk <lang> <file...>
  local lang="$1"; shift
  awk -v lang="${lang}" -v markers="${SCAN_MARKERS:-log-scan-ok}" "${SCAN_AWK}" "$@"
}

# scan <lang> <min-sites> <label> <file...>
scan() {
  local lang="$1" min="$2" label="$3"; shift 3
  local out sites hits
  out="$(run_awk "${lang}" "$@")"
  sites="$(sed -n 's/^#sites //p' <<<"${out}")"
  hits="$(grep -v '^#sites ' <<<"${out}" || true)"

  if [[ -z "${sites}" ]] || (( sites < min )); then
    fail "${label}: found ${sites:-0} log/print invocations, expected >= ${min}."
    echo "  The extractor has stopped matching, so this scan proves nothing." >&2
    echo "  Fix the scanner (or lower the floor deliberately) — do not ignore it." >&2
    return 2
  fi
  if [[ -n "${hits}" ]]; then
    fail "${label}: $(wc -l <<<"${hits}") log/print/panic call(s) render an identifier (Security Rule 15)."
    printf '%s\n' "${hits}" | sed 's/^/    /' >&2
    echo "  Alias it (log_alias::/logAlias), bucket it, make it relative, log the" >&2
    echo "  runtimeType/typed code — or delete the line. A prefix is still an identifier." >&2
    echo "  A reviewed exception says why on the line:  // log-scan-ok: <why>" >&2
    return 1
  fi
  log "OK: ${label} — ${sites} log/print/panic invocations, none render an identifier."
  return 0
}

camelize() { awk -F_ '{ out = $1; for (i = 2; i <= NF; i++) out = out toupper(substr($i, 1, 1)) substr($i, 2); print out }' <<<"$1"; }

# ---------------------------------------------------------------------------
# Self-test — hermetic fixtures, no repo state. The tables are the contract:
# one known-bad fixture per vocabulary word in each language and one per
# shape, plus the known-good shapes that decide whether the guard survives
# contact with the tree (an alias, a bucket, a relative offset, a boolean, a
# delta, `runtimeType`, `.code`) and the marker rules.
# ---------------------------------------------------------------------------
# 2 languages x (86 STRONG + 16 WEAK + 30 PROSE) words + 144 hand-written
# cases: shapes, format specs, markers, known-good, floors, the Dart
# exception-constructor/`fail(` CALL vocabulary, and the 2026-09-18 pass —
# `String toString()` bodies in both forms and the `$message` exemption's
# class-name gate, the `note(`/`record(` sinks and the typed-parameter
# DECLARATION they must not be read as, the `${…}` nesting lexer (nested
# literals, braces inside them, and the unterminated-file report), the
# unit-vs-instant and adjacent-pair rules, `disposition.name`, the `!= null`
# pair and the `relaysAcked`/`wasAcked` pair. An equality pin: a fixture
# added or lost without this line changing is a self-test that no longer
# says what it runs.
readonly DECLARED_CASES=408

self_test() {
  local tmp fails=0 checked=0
  tmp="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf '${tmp}'" RETURN

  _case() { # _case <label> <lang> <expect-hit:0|1> <ext> <content> [<expect-substring>] [<markers>]
    local label="$1" lang="$2" want="$3" ext="$4" content="$5" need="${6:-}" markers="${7:-log-scan-ok}" out got
    checked=$(( checked + 1 ))
    printf '%s' "${content}" > "${tmp}/f.${ext}"
    out="$(SCAN_MARKERS="${markers}" run_awk "${lang}" "${tmp}/f.${ext}")"
    got=$(grep -cv '^#sites ' <<<"${out}" || true)
    (( got > 0 )) && got=1
    if [[ "${got}" -eq "${want}" ]] && { [[ -z "${need}" ]] || grep -qF -- "${need}" <<<"${out}"; }; then
      printf '  \033[1;32mPASS\033[0m %s\n' "${label}"
    else
      printf '  \033[1;31mFAIL\033[0m %s (want hit=%d%s, got hit=%d)\n' "${label}" "${want}" "${need:+ mentioning \"${need}\"}" "${got}" >&2
      printf '%s\n' "${out}" | sed 's/^/        /' >&2
      fails=1
    fi
  }

  log "self-test: vocabulary, one known-bad fixture per word and language"
  local tok camel kind
  for kind in identifier prose; do
    local words="${STRONG_WORDS} ${WEAK_WORDS}"
    [[ "${kind}" == prose ]] && words="${PROSE_WORDS}"
    for tok in ${words}; do
      _case "Rust ${kind} '${tok}' FAILS" rust 1 rs "fn f() {
    log::info!(\"v={}\", ${tok});
}
" "${kind}(${tok})"
      camel="$(camelize "${tok}")"
      _case "Dart ${kind} '${camel}' FAILS" dart 1 dart "void f() {
  debugPrint('v=\$${camel}');
}
" "${kind}(${tok})"
    done
  done

  log "self-test: forbidden shapes"
  _case "Rust to_hex() FAILS" rust 1 rs 'fn f() { log::info!("{}", v.to_hex()); }' 'shape(to_hex())'
  _case "Rust hex::encode( FAILS" rust 1 rs 'fn f() { log::info!("{}", hex::encode(v)); }' 'shape(hex::encode()'
  _case "Rust to_bech32() FAILS" rust 1 rs 'fn f() { log::info!("{}", v.to_bech32()); }' 'shape(to_bech32())'
  _case "Rust prefix slice .get(..8) FAILS" rust 1 rs 'fn f() { log::info!("{:?}", v.get(..8)); }' 'shape(prefix slice)'
  _case "Rust chars().take(4) FAILS" rust 1 rs 'fn f() { log::info!("{}", v.chars().take(4).collect::<String>()); }' 'shape(.take(N))'
  _case "Rust truncate_chars( FAILS" rust 1 rs 'fn f() { log::info!("{}", truncate_chars(v, 8)); }' 'shape(truncate()'
  _case "Rust base64 FAILS" rust 1 rs 'fn f() { log::info!("{}", base64::encode(v)); }' 'shape(base64)'
  _case "Rust typed PublicKey:: value FAILS" rust 1 rs 'fn f() { log::info!("{}", PublicKey::from_hex(v)?); }' 'shape(typed identifier value)'
  _case "Rust serde_json::to_string FAILS" rust 1 rs 'fn f() { log::info!("{}", serde_json::to_string(&v)?); }' 'shape(serialised object)'
  _case "Dart toRadixString( FAILS" dart 1 dart "void f() { debugPrint('\${v.toRadixString(16)}'); }" 'shape(toRadixString()'
  _case "Dart substring( FAILS" dart 1 dart "void f() { debugPrint('\${v.substring(0, 8)}'); }" 'shape(substring()'
  _case "Dart .take( FAILS" dart 1 dart "void f() { debugPrint('\${v.characters.take(4)}'); }" 'shape(.take()'
  _case "Dart hex.encode( FAILS" dart 1 dart "void f() { debugPrint('\${hex.encode(v)}'); }" 'shape(hex.encode()'
  _case "Dart base64Encode( FAILS" dart 1 dart "void f() { debugPrint('\${base64Encode(v)}'); }" 'shape(base64)'
  _case "Dart jsonEncode( FAILS" dart 1 dart "void f() { debugPrint('\${jsonEncode(v)}'); }" 'shape(serialised object)'

  log "self-test: format specs, counts, dbg!, panics, unknown macros"
  _case "Rust {:?} without a reviewed-Debug marker FAILS" rust 1 rs 'fn f() { log::info!("action={:?}", action); }' 'debug-format'
  _case "Rust {v:#?} FAILS" rust 1 rs 'fn f() { log::info!("{v:#?}"); }' 'debug-format'
  _case "Rust {:x?} FAILS" rust 1 rs 'fn f() { log::info!("{:x?}", v); }' 'shape(hex format)'
  _case "Rust {:02x} FAILS" rust 1 rs 'fn f() { log::info!("{:02x}", v); }' 'shape(hex format)'
  _case "Rust .len() is an exact count FAILS" rust 1 rs 'fn f() { log::info!("n={}", items.len()); }' 'count('
  _case "Dart .length is an exact count FAILS" dart 1 dart "void f() { debugPrint('n=\${items.length}'); }" 'count('
  _case "Dart .size is an exact count FAILS" dart 1 dart "void f() { debugPrint('n=\${items.size}'); }" 'count('
  _case "dbg! FAILS" rust 1 rs 'fn f() { dbg!(&v); }' 'dbg!'
  _case "panic! rendering an identifier FAILS" rust 1 rs 'fn f() { panic!("bad group {gid}"); }' 'identifier(gid)'
  _case "bare info! (use log::info) FAILS" rust 1 rs 'fn f() { info!("{}", npub); }' 'identifier(npub)'
  _case "println! rendering an identifier FAILS" rust 1 rs 'fn f() { println!("{}", relay_url); }' 'identifier(relay_url)'
  _case "Dart print( FAILS" dart 1 dart "void f() { print('\$relayUrl'); }" 'identifier(relay_url)'
  _case "Dart developer.log( FAILS" dart 1 dart "void f() { developer.log('\$npub'); }" 'identifier(npub)'
  _case "Dart StateError( with an identifier FAILS" dart 1 dart "void f() { throw StateError('leak: \$relayUrl'); }" 'identifier(relay_url)'
  _case "Dart fail( with a relay URL FAILS" dart 1 dart "void f() { fail('leak: \$relayUrl'); }" 'identifier(relay_url)'
  _case "Dart note( sink argument is scanned like a debugPrint" dart 1 dart "void f() { note('p', 'n=\${rows.length}'); }" 'count('
  _case "Dart record( sink argument is scanned like a debugPrint" dart 1 dart "void f() { record('p', '\$timestamp'); }" 'identifier(timestamp)'
  _case "a note/record DECLARATION is a typed parameter list, not a call" dart 0 dart "void f() {
  void record(String phase, String detail) { debugPrint('\$phase'); }
  void note(String phase, String detail) { debugPrint('\$phase'); }
}
"
  _case "Dart ArgumentError( with an identifier FAILS" dart 1 dart "void f() { throw ArgumentError('bad \$npub'); }" 'identifier(npub)'
  _case "Dart FormatException( with an identifier FAILS" dart 1 dart "void f() { throw FormatException('bad \$relayUrl'); }" 'identifier(relay_url)'
  _case "Dart Exception( with an identifier FAILS" dart 1 dart "void f() { throw Exception('bad \$pubkey'); }" 'identifier(pubkey)'
  _case "Dart UnsupportedError( with an identifier FAILS" dart 1 dart "void f() { throw UnsupportedError('bad \$npub'); }" 'identifier(npub)'
  _case "Dart RangeError( with an identifier FAILS" dart 1 dart "void f() { throw RangeError('bad \$relayUrl'); }" 'identifier(relay_url)'
  _case "Dart TimeoutException( with an identifier FAILS" dart 1 dart "void f() { throw TimeoutException('bad \$eventId'); }" 'identifier(event_id)'
  _case "Dart StateError( with runtimeType passes" dart 0 dart "void f() { throw StateError('failed: \${e.runtimeType}'); }"
  _case "a Dart constructor declaration forwarding this.message is not a call" dart 0 dart "class FooException implements Exception { const FooException(this.message); final String message; }"
  _case "a Dart constructor declaration with a named required this.message is not a call" dart 0 dart "class FooError extends Error { FooError({required this.message}); final String message; }"
  _case "Dart FormatException( with a fixed literal passes" dart 0 dart "void f() { throw FormatException('a fixed, non-identifying message'); }"
  _case "tracing::info! trips the unknown-macro trap" rust 1 rs 'fn f() { tracing::info!("ok"); }' 'unknown-macro(tracing::'
  _case "#[instrument] trips the unknown-macro trap" rust 1 rs '#[instrument]
fn f(gid: &str) {}
' 'unknown-macro(#[instrument]'
  _case "Rust {e} prose FAILS" rust 1 rs 'fn f() { log::warn!("publish failed: {e}"); }' 'prose(e)'
  _case "Dart \${e.message} prose FAILS" dart 1 dart "void f() { debugPrint('failed: \${e.message}'); }" 'prose('
  _case "Dart hashCode is a pseudonymous identifier FAILS" dart 1 dart "void f() { debugPrint('c=\${circle.hashCode}'); }" 'hash_code'
  _case "a path segment is classified (self.relay_url) FAILS" rust 1 rs 'fn f() { log::info!("{}", self.relay_url); }' 'identifier(relay_url)'
  _case "a decamelled Dart part is classified (adminPubkeyHex) FAILS" dart 1 dart "void f() { debugPrint('\$adminPubkeyHex'); }" 'identifier(admin_pubkey_hex)'
  _case "an identifier on a CONTINUATION line FAILS" rust 1 rs 'fn f() {
    log::warn!(
        "rotated for {} at {}",
        circle_id,
        epoch,
    );
}
' 'identifier(circle_id, epoch)'
  _case "a safe accessor does not bless the rest of the call" dart 1 dart "void f() { debugPrint('\${e.runtimeType} on \$relayUrl'); }" 'identifier(relay_url)'
  _case "the wrapped alias does not bless a sibling argument" rust 1 rs 'fn f() { log::info!("{} {}", log_alias::circle(NostrGroupId(&gid)), pubkey); }' 'identifier(pubkey)'

  _case "a leak-named bucket is not blessed (my_leak_bucket)" rust 1 rs 'fn f() { log::info!("n={}", my_leak_bucket(relays.len())); }' 'count('
  _case ".expect(&format!(..)) FAILS" rust 1 rs 'fn f() { v.expect(&format!("missing {gid}")); }' 'identifier(gid)'
  _case "assert_eq! message args FAIL" rust 1 rs 'fn f() { assert_eq!(a, b, "mismatch on {relay_url}"); }' 'identifier(relay_url)'
  _case "a two-step format (let line = format!(..)) FAILS" rust 1 rs 'fn f() { let line = format!("connected {relay_url}"); log::info!("{line}"); }' 'prose(line)'
  _case "Dart assert message FAILS" dart 1 dart "void f() { assert(ok, 'bad \$npub'); }" 'identifier(npub)'
  _case "a plain assert condition is source text, not a value (passes)" dart 0 dart "void f() { assert(maxSeenEventIds > 0, 'maxSeenEventIds must be positive'); }"
  _case "Rust assert! condition passes, its message args do not" rust 1 rs 'fn f() { assert!(gid.len() == 32); assert!(ok, "{}", relay_url); }' 'identifier(relay_url)'
  _case "Dart details.library is a Flutter library name (passes)" dart 0 dart "void f() { FlutterError.onError = (details) => debugPrint('[FlutterError] \${details.exception.runtimeType} in \${details.library}'); }"

  log "self-test: wrapper definitions"
  _wcase() { # _wcase <label> <lang> <expect-hit:0|1> <relative-path> <content>
    local label="$1" lang="$2" want="$3" rel="$4" content="$5" out got
    checked=$(( checked + 1 ))
    mkdir -p "${tmp}/w/$(dirname "${rel}")"
    printf '%s' "${content}" > "${tmp}/w/${rel}"
    out="$(run_wrapdef "${lang}" "${tmp}/w/${rel}")"
    got=$(grep -cv '^#defs ' <<<"${out}" || true)
    (( got > 0 )) && got=1
    if [[ "${got}" -eq "${want}" ]]; then
      printf '  \033[1;32mPASS\033[0m %s\n' "${label}"
    else
      printf '  \033[1;31mFAIL\033[0m %s (want hit=%d, got hit=%d)\n' "${label}" "${want}" "${got}" >&2
      printf '%s\n' "${out}" | sed 's/^/        /' >&2
      fails=1
    fi
    rm -f "${tmp}/w/${rel}"
  }
  _wcase "a #[cfg(test)] test fn named *_handle is not a wrapper" rust 0 x/api.rs 'fn real() {}
#[cfg(test)]
mod log_anonymity_tests {
    fn rotating_the_salt_invalidates_every_handle() {
        let _ = 1;
    }
}
'
  _wcase "Rust wrapper returning its input FAILS" rust 1 x/relay.rs 'pub(crate) fn relay_handle(u: &str) -> &str {
    u
}
'
  _wcase "Rust wrapper built on log_alias passes" rust 0 x/relay.rs 'pub(crate) fn circle_handle(
    group_id_hex: &str,
) -> LogHandle {
    let bytes = hex::decode(group_id_hex).unwrap_or_default();
    log_alias::circle(NostrGroupId(&bytes))
}
'
  _wcase "Rust bucket defined outside the module without log_alias FAILS" rust 1 x/util.rs 'fn bucket(n: usize) -> &'"'"'static str {
    if n == 0 { "0" } else { "1+" }
}
'
  _wcase "the canonical Rust module is exempt" rust 0 haven-core/src/log_alias.rs 'pub fn bucket(n: usize) -> &'"'"'static str {
    if n == 0 { "0" } else { "1+" }
}
'
  _wcase "Dart wrapper returning its input FAILS" dart 1 x/a.dart 'String relayHandle(String u) => u;
'
  _wcase "Dart wrapper built on logAliasHandle passes" dart 0 x/a.dart 'String circleHandle(String h) {
  return logAliasHandle(LogAliasClass.circle, h);
}
'
  _wcase "a Dart constructor is not a wrapper (_DragHandle)" dart 0 x/a.dart 'class _DragHandle extends StatelessWidget {
  const _DragHandle();
}
'

  log "self-test: known-good shapes"
  _case "Rust alias handle passes" rust 0 rs 'fn f() { log::info!("circle {} ready", log_alias::circle(NostrGroupId(&nostr_group_id))); }'
  _case "Dart alias handle passes" dart 0 dart "void f() { debugPrint('circle \${logAliasHandle(LogAliasClass.circle, nostrGroupId)} ready'); }"
  _case "a path-qualified Rust bucket passes (crate::log_alias::bucket)" rust 0 rs 'fn f() { log::info!("n={}", crate::log_alias::bucket(paths.len())); }' 
  _case "a local *_handle wrapper passes" rust 0 rs 'fn f() { log::debug!("{} closed", circle_handle(&group_id_hex)); }'
  _case "a Dart *Handle wrapper passes" dart 0 dart "void f() { debugPrint('\${circleHandle(groupIdHex)} closed'); }"
  _case "Rust bucket passes" rust 0 rs 'fn f() { log::info!("relays={}", magnitude_bucket(relays.len())); }'
  _case "Dart bucket passes" dart 0 dart "void f() { debugPrint('relays=\${magnitudeBucket(relays.length)}'); }"
  _case "Rust relative offset passes" rust 0 rs 'fn f() { log::debug!("at {}", relative_secs(created_at)); }'
  _case "Dart relative offset passes" dart 0 dart "void f() { debugPrint('at \${relativeSecs(createdAt)}'); }"
  _case "Dart runtimeType passes" dart 0 dart "void f() { debugPrint('fetch failed: \${e.runtimeType}'); }"
  _case "Dart null-aware ?.runtimeType passes" dart 0 dart "void f() { debugPrint('threw=\${error?.runtimeType ?? '-'}'); }"
  _case "Dart enum variant name passes (outcome.name)" dart 0 dart "void f() { debugPrint('stop=\${outcome.name} (\${state.mode.name})'); }"
  _case "Dart enum variant name passes on a class-suffixed receiver (expectedTier.name)" dart 0 dart "void f() { debugPrint('tier=\${expectedTier.name} (\${observedTier.name})'); }"
  _case "Dart enum variant name passes on a retry disposition (disposition.name)" dart 0 dart "void f() { debugPrint('why=\${disposition.name} (\${retryDisposition.name})'); }"
  _case "Dart user text does NOT pass as a variant name (circle.name)" dart 1 dart "void f() { debugPrint('joined \${circle.name}'); }" 'identifier(circle, name)'
  _case "Dart error.code passes" dart 0 dart "void f() { debugPrint('bg task error: \${error.code}'); }"
  _case "Rust e.kind() passes" rust 0 rs 'fn f() { log::warn!("io: {}", e.kind()); }'
  _case "a boolean prefix passes" dart 0 dart "void f() { debugPrint('relay ok: \$isRelayConnected'); }"
  _case "a boolean prefix passes on an ack too (wasAcked)" dart 0 dart "void f() { debugPrint('acked=\$wasAcked'); }"
  _case "a count named relaysAcked is not a boolean (FAILS)" dart 1 dart "void f() { debugPrint('n=\$relaysAcked'); }" 'identifier(relays_acked)'
  _case "a boolean suffix passes" rust 0 rs 'fn f() { log::info!("{relay_ok}"); }'
  _case "an epoch DELTA passes" rust 0 rs 'fn f() { log::info!("peer is {epoch_delta} behind"); }'
  _case "a retry count passes" dart 0 dart "void f() { debugPrint('attempt \$retryCount'); }"
  _case "a unit makes a magnitude a duration (totalMs) passes" dart 0 dart "void f() { debugPrint('took \${totalMs}ms'); }"
  _case "a unit does NOT relativise an instant (pauseSinceSecs) FAILS" dart 1 dart "void f() { debugPrint('since=\$pauseSinceSecs'); }" 'identifier(pause_since_secs)'
  _case "an instant spelled across parts is seen as a pair (createdAtSecs) FAILS" dart 1 dart "void f() { debugPrint('at=\$createdAtSecs'); }" 'identifier(created_at_secs)'
  _case "a pair-spelled instant with a unit still FAILS (expiresAtMs)" dart 1 dart "void f() { debugPrint('exp=\$expiresAtMs'); }" 'identifier(expires_at_ms)'
  _case "a genuine delta on an instant still passes (epochDelta)" dart 0 dart "void f() { debugPrint('behind=\$epochDelta'); }"
  _case "a bare past participle is not an instant (published) passes" dart 0 dart "void f() { debugPrint('state=\$published'); }"
  _case "a null comparison renders a boolean (passes)" dart 0 dart "void f() { debugPrint('hasPicture: \${pictureBytes != null}'); }"
  _case "the SAME value rendered whole is not a boolean (FAILS)" dart 1 dart "void f() { debugPrint('picture: \$pictureBytes'); }" 'identifier(picture_bytes)'
  _case "an alias variable passes" rust 0 rs 'fn f() { log::info!("{relay_alias} closed"); }'
  _case "a classification passes (relay_status)" rust 0 rs 'fn f() { log::info!("{}", relay_status); }'
  _case "vocabulary words in PROSE pass" rust 0 rs 'fn f() { log::warn!("relay url and pubkey rejected: {n}"); }'
  _case "prose in a MULTI-LINE literal passes" rust 0 rs 'fn f() {
    log::warn!(
        "no relays configured; falling back to defaults \
         (the seed may not have run yet)"
    );
}
'
  _case "Rust Err(e) constructor is not prose" rust 0 rs 'fn f() { log::info!("{}", n); let _ = Err(e); }'
  _case "suppression on the line ABOVE passes" rust 0 rs 'fn f() {
    // log-scan-ok: FooKind is a fieldless enum
    log::debug!("kind {:?}", foo_kind);
}
'
  _case "trailing suppression on the invocation passes" rust 0 rs 'fn f() {
    log::debug!("kind {:?}", foo_kind); // log-scan-ok: FooKind Debug redacts
}
'
  _case "suppression with NO reason does not suppress" rust 1 rs 'fn f() {
    // log-scan-ok:
    log::debug!("{}", pubkey);
}
'
  _case "a distant suppression does NOT blanket the file" rust 1 rs '// log-scan-ok: this file is fine, honest
fn f() {
    log::info!("ok");
    log::debug!("{}", pubkey);
}
'
  _case "harness-log-ok with a reason suppresses under the harness marker set" dart 0 dart "void f() {
  // harness-log-ok: parsed by the runner's marker grep
  debugPrint('\$kMarker \$seq');
}
" '' 'log-scan-ok|harness-log-ok'
  _case "harness-log-ok with NO reason does not suppress" dart 1 dart "void f() {
  debugPrint('\$kMarker \$seq'); // harness-log-ok:
}
" 'identifier(seq)' 'log-scan-ok|harness-log-ok'
  _case "harness-log-ok is not honoured outside the harness (haven/lib keeps log-scan-ok only)" dart 1 dart "void f() {
  debugPrint('\$kMarker \$seq'); // harness-log-ok: harness-only marker
}
" 'identifier(seq)'
  _case "a log call inside a comment is not scanned" rust 0 rs 'fn f() {
    // log::debug!("{}", pubkey);
    log::info!("ok");
}
'
  _case "a #[cfg(test)] module is not scanned" rust 0 rs 'fn f() { log::info!("ok"); }
#[cfg(test)]
mod tests {
    fn t() {
        let s = "{";
        panic!("expected InvalidData, got {other:?} for {url}");
    }
}
'
  _case "a #[cfg(test)] module holding raw-string JSON is skipped to its own-indent brace" rust 0 rs 'fn f() { log::info!("ok"); }
#[cfg(test)]
mod tests {
    const BODY: &str = r#"{"sha256":"abc"}"#;
    fn t() {
        let closer = "}";
        assert_eq!(pic.sha256_hex, other.sha256_hex, "{url}");
    }
}
'
  _case "a #[cfg(any(test, ..))] macro_rules! is skipped" rust 0 rs '#[cfg(any(test, feature = "test-utils"))]
#[macro_export]
macro_rules! assert_debug_redacted {
    ($i:expr, $t:expr) => {
        assert!(!rendered.contains(needle), "{type_name} leaked {needle:?}");
    };
}
fn f() { log::info!("ok"); }
'
  _case "a #[cfg(test)] helper fn is skipped and the next item is scanned" rust 1 rs '#[cfg(test)]
fn helper() {
    panic!("{other:?}");
}
fn f() { log::info!("{}", relay_url); }
' 'identifier(relay_url)'
  _case "a user-defined two-argument .expect() is not a panic message" rust 0 rs 'fn f() { self.eose_coverage.expect(sub_id, relays); }'
  _case "a call AFTER a #[cfg(test)] module is still scanned" rust 1 rs '#[cfg(test)]
mod tests {
    fn t() { panic!("{other:?}"); }
}
fn f() { log::info!("{}", relay_url); }
' 'identifier(relay_url)'
  _case "a Rust char literal does not desync the lexer" rust 0 rs "fn f() { let q = '\"'; log::info!(\"n={n}\"); }"
  _case "Dart apostrophe in prose does not desync the lexer" dart 0 dart 'void f() {
  debugPrint("couldn'"'"'t reach the relay");
  debugPrint("count: ${n}");
}
'
  _case "Dart .print( on a receiver is not a print call" dart 0 dart "void f() { buffer.print(relayUrl); }"
  _case "Dart ArgumentError.value( is the documented named-constructor gap (unmatched, not a pass)" dart 0 dart "void f() { throw ArgumentError.value(npub, 'npub', 'bad'); }"

  log "self-test: Dart toString() overrides"
  _case "a toString() interpolating .length is an exact count FAILS" dart 1 dart "class A {
  @override
  String toString() => 'A(n: \${rows.length})';
}
" 'count('
  _case "a toString() interpolating a bucket passes" dart 0 dart "class A {
  @override
  String toString() => 'A(n: \${magnitudeBucket(rows.length)})';
}
"
  _case "a toString() rendering a pubkey prefix FAILS" dart 1 dart "class A {
  @override
  String toString() => 'A(\${pubkey.substring(0, 8)}...)';
}
" 'shape(substring()'
  _case "a toString() rendering an alias handle passes" dart 0 dart "class A {
  @override
  String toString() => 'A(\${logAliasHandle(LogAliasClass.peer, pubkey)})';
}
"
  _case "a BRACED toString() body is scanned to its closing brace" dart 1 dart "class A {
  @override
  String toString() {
    final parts = <String>[relayUrl];
    return parts.join(' ');
  }
}
" 'identifier(relay_url)'
  _case "a toString() rendering its own \$message is the exception idiom" dart 0 dart "class FooException implements Exception {
  @override
  String toString() => 'FooException: \$message';
}
"
  _case "the same \$message in a class NOT named *Exception/*Error FAILS" dart 1 dart "class SocketDied implements Exception {
  @override
  String toString() => 'SocketDied: \$message';
}
" 'prose(message)'
  _case "a toString() rendering any OTHER prose still FAILS" dart 1 dart "class A {
  @override
  String toString() => 'A: \$reason';
}
" 'prose(reason)'
  _case "a toString() forwarding to super is scanned, not read as a declaration" dart 1 dart "class A {
  @override
  String toString() => super.toString() + relayUrl;
}
" 'identifier(relay_url)'
  _case "an absolute instant in a toString() FAILS" dart 1 dart "class A {
  @override
  String toString() => 'A(\$timestamp)';
}
" 'identifier(timestamp)'
  _case "a relative offset in a toString() passes" dart 0 dart "class A {
  @override
  String toString() => 'A(\${relativeSecs(LogOrigin.now(), timestamp)})';
}
"

  log "self-test: nested quotes inside a Dart \${…} interpolation"
  _case "a ternary branch literal does not close the outer string (identifier FAILS)" dart 1 dart "void f() { debugPrint('x=\${flag ? pubkeyHex : '-'}'); }" 'identifier(pubkey_hex)'
  _case "an identifier AFTER a nested literal is still scanned (FAILS)" dart 1 dart "void f() { debugPrint('r=\${ok ? 'wss://x' : relayUrl}'); }" 'identifier(relay_url)'
  _case "a map key literal inside an interpolation FAILS" dart 1 dart "void f() { debugPrint(\"m=\${m['npub']}\"); }" 'identifier(npub)'
  _case "a nested literal does not bless runtimeType's own call (passes)" dart 0 dart "void f() { debugPrint('threw=\${error?.runtimeType ?? '-'}'); }"
  _case "a BRACE inside a nested literal is text, not the end of the placeholder (FAILS)" dart 1 dart "void f() { debugPrint('x=\${ok ? '}' : npub}'); }" 'identifier(npub)'
  _case "a file ending inside an unterminated literal is reported, not guessed" dart 1 dart "void f() { debugPrint('oops); }
" 'lexer(file ends inside'
  _case "a file ending with every literal closed is silent" dart 0 dart "void f() { debugPrint('fine'); }
"

  log "self-test: anti-vacuity floor"
  local out sites
  checked=$(( checked + 1 ))
  printf 'fn f() { log::info!("ok"); log::warn!("{n}"); }\n' > "${tmp}/two.rs"
  out="$(run_awk rust "${tmp}/two.rs")"
  sites="$(sed -n 's/^#sites //p' <<<"${out}")"
  if [[ "${sites}" == "2" ]]; then
    printf '  \033[1;32mPASS\033[0m the scanner reports its invocation count\n'
  else
    printf '  \033[1;31mFAIL\033[0m expected #sites 2, got %s\n' "${sites:-<none>}" >&2
    fails=1
  fi
  checked=$(( checked + 1 ))
  # The swallow this guard's Dart lexer used to have: the `//` inside the
  # nested literal reached CODE, ate the rest of the line as a comment, and
  # left the invocation open — so BOTH calls went uncounted and unreported.
  # `#sites` is the only thing that can see that, because a dropped
  # invocation reads exactly like a clean one.
  printf "void f() { debugPrint('r=\${ok ? 'wss://x' : relayUrl}'); }\nvoid g() { debugPrint('ok'); }\n" > "${tmp}/nested.dart"
  out="$(run_awk dart "${tmp}/nested.dart")"
  sites="$(sed -n 's/^#sites //p' <<<"${out}")"
  if [[ "${sites}" == "2" ]]; then
    printf '  \033[1;32mPASS\033[0m a nested-quote interpolation does not swallow its invocation\n'
  else
    printf '  \033[1;31mFAIL\033[0m nested-quote file reported #sites %s, expected 2\n' "${sites:-<none>}" >&2
    fails=1
  fi
  checked=$(( checked + 1 ))
  printf 'fn f() { let x = 1; }\n' > "${tmp}/none.rs"
  out="$(run_awk rust "${tmp}/none.rs")"
  if [[ "$(sed -n 's/^#sites //p' <<<"${out}")" == "0" ]]; then
    printf '  \033[1;32mPASS\033[0m a file with no recognised call reports 0 sites (floor reds)\n'
  else
    printf '  \033[1;31mFAIL\033[0m expected #sites 0\n' >&2
    fails=1
  fi

  if (( fails )); then
    fail "self-test failed — this guard cannot be trusted until it is fixed"
    exit 2
  fi
  if (( checked != DECLARED_CASES )); then
    fail "self-test ran ${checked} cases but declares ${DECLARED_CASES} — re-pin DECLARED_CASES with the fixture change that moved it"
    exit 2
  fi
  log "OK: self-test passed (${checked} fixtures, as declared)."
}

# ---------------------------------------------------------------------------
main() {
  if [[ "${1:-}" == "--self-test" ]]; then
    self_test
    exit 0
  fi
  (( $# == 0 )) || misconfig "usage: ${SCRIPT_NAME}.sh [--self-test]"

  local core="${REPO_ROOT}/haven-core/src"
  local ffi="${REPO_ROOT}/haven/rust_builder/src"
  local dart="${REPO_ROOT}/haven/lib"
  local itest="${REPO_ROOT}/haven/integration_test"
  [[ -d "${core}" ]] || misconfig "${core} not found"
  [[ -d "${ffi}"  ]] || misconfig "${ffi} not found"
  [[ -d "${dart}" ]] || misconfig "${dart} not found"
  [[ -d "${itest}" ]] || misconfig "${itest} not found"

  local status=0 rc
  local -a rust_files dart_files itest_files
  mapfile -t rust_files < <(find "${core}" "${ffi}" -name '*.rs' ! -name 'frb_generated.rs' | sort)
  # `haven/lib/src/rust/` is the generated Dart binding, and `haven/lib/l10n/`
  # is `flutter gen-l10n` output — both machine output, and an l10n string
  # BUILDER (`String circleMemberRemoveError(String name) => 'Remove $name…'`)
  # is UI copy, not a log/print/panic call; the regex's `NAME(` shape cannot
  # tell that declaration from a call, so a translated key ending in `Error`/
  # `Exception` (e.g. `circleMemberRemoveError`) would otherwise false-positive
  # on every locale file.
  mapfile -t dart_files < <(find "${dart}" -name '*.dart' -not -path '*/src/rust/*' -not -path '*/l10n/*' | sort)
  mapfile -t itest_files < <(find "${itest}" -name '*.dart' | sort)
  (( ${#rust_files[@]} > 0 )) || misconfig "no Rust sources found under ${core} / ${ffi}"
  (( ${#dart_files[@]} > 0 )) || misconfig "no Dart sources found under ${dart}"
  (( ${#itest_files[@]} > 0 )) || misconfig "no Dart sources found under ${itest}"

  rc=0; scan rust "${MIN_RUST_SITES}" 'haven-core/src + rust_builder/src' "${rust_files[@]}" || rc=$?
  (( rc == 2 )) && exit 2
  (( rc == 0 )) || status=1

  rc=0; scan dart "${MIN_DART_SITES}" 'haven/lib' "${dart_files[@]}" || rc=$?
  (( rc == 2 )) && exit 2
  (( rc == 0 )) || status=1

  rc=0; SCAN_MARKERS='log-scan-ok|harness-log-ok' scan dart "${MIN_ITEST_SITES}" 'haven/integration_test' "${itest_files[@]}" || rc=$?
  (( rc == 2 )) && exit 2
  (( rc == 0 )) || status=1

  # The soak rig: a fourth Rust pass, its own root, its own floor, `wrappers`
  # deliberately not extended (header). While the crate is not in the tree the
  # pass says so rather than reporting a clean scan of nothing — an absent
  # subject is not a verdict.
  local soak_src="${REPO_ROOT}/tooling/soak/src"
  local soak_tests="${REPO_ROOT}/tooling/soak/tests"
  local -a soak_files=()
  if [[ -d "${soak_src}" ]]; then
    mapfile -t soak_files < <(find "${soak_src}" "${soak_tests}" -name '*.rs' 2>/dev/null | sort)
  fi
  if (( ${#soak_files[@]} == 0 )); then
    log "SKIP: tooling/soak — the rig is not in the tree yet; nothing scanned, nothing claimed."
  else
    rc=0; scan rust "${MIN_SOAK_SITES}" 'tooling/soak (src + tests)' "${soak_files[@]}" || rc=$?
    (( rc == 2 )) && exit 2
    (( rc == 0 )) || status=1
  fi

  rc=0; wrappers rust "${MIN_RUST_WRAPDEFS}" 'Rust wrapper definitions' "${rust_files[@]}" || rc=$?
  (( rc == 2 )) && exit 2
  (( rc == 0 )) || status=1

  rc=0; wrappers dart "${MIN_DART_WRAPDEFS}" 'Dart wrapper definitions' "${dart_files[@]}" "${itest_files[@]}" || rc=$?
  (( rc == 2 )) && exit 2
  (( rc == 0 )) || status=1

  exit "${status}"
}

main "$@"
