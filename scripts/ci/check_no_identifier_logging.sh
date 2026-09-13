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
# Not covered, deliberately: generated bindings, `haven/integration_test`
# (Phase 0b — the harness announces canaries on purpose), Rust `#[cfg(test)]`
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
readonly MIN_DART_SITES=380

# The vocabulary. Whole decamelled identifiers and every `_`-part of them.
# STRONG words identify on their own; WEAK words are magnitudes and instants,
# which a delta/bucket/duration part may relativise.
readonly STRONG_WORDS='nostr_group_id group_hex group_id gid group circle circle_id h_tag npub nsec pubkey pub_key public_key pk author sender recipient inviter event_id evt evt_id evt_tag evt_prefix d_tag slot sub_id subscription_id relay relays relay_url url urls host domain endpoint uri ip ssid display_name petname nickname circle_name name title label about notes blossom picture avatar sha256 digest hash hex bech32 hash_code lat latitude lon longitude geohash altitude speed heading accuracy device_id locale tz timezone id ids peer peers member members contact contacts owner admin admins index idx ordinal seq sequence serial'
readonly WEAK_WORDS='epoch since until created_at timestamp at_ms instant count size total len'
readonly PROSE_WORDS='e err error exception ex cause stack_trace stack trace panic reason message msg notice detail details description text body content payload raw json response resp line summary'
readonly BOOL_PREFIXES='is has was were are can could should needs did does will had have must may'
readonly BOOL_SUFFIXES='ok enabled disabled present known ready changed stale fresh valid missing configured allowed dirty reachable healthy acked sent done empty matched verified exists supported granted denied needed required connected'
# A name that says it is a classification, not a value.
readonly CLASS_PARTS='alias handle kind code class variant tier policy mode status state phase outcome verdict decision action'
# ...and, for magnitude/instant words only, one that says it is relative.
readonly RELATIVE_PARTS='delta diff behind ahead gap lag offset elapsed relative bucket bucketed ago duration latency timeout interval delay backoff max min limit cap threshold budget quota retry retries attempt attempts'

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
export STRONG_WORDS WEAK_WORDS PROSE_WORDS BOOL_PREFIXES BOOL_SUFFIXES CLASS_PARTS RELATIVE_PARTS SHAPES_RUST SHAPES_DART

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
  nshapes = split(ENVIRON[(lang == "rust") ? "SHAPES_RUST" : "SHAPES_DART"], SH, "\n")
  for (i = 1; i <= nshapes; i++) { split(SH[i], kv, "\t"); SLABEL[i] = kv[1]; SRE[i] = kv[2] }
  MARKER = "log-scan-ok:[ \t]*[^ \t]"
  if (lang == "rust") {
    CALL  = "(log::(log|trace|debug|info|warn|error)|(^|[^A-Za-z0-9_:])(trace|debug|info|warn|error|println|eprintln|print|eprint|dbg|panic|unreachable|assert|assert_eq|assert_ne|debug_assert|debug_assert_eq|debug_assert_ne))![ \t]*\\(|\\.expect\\([ \t]*&?format!\\("
    WRAP  = "(^|[^A-Za-z0-9_])(log_alias::[a-z_]+|[a-z0-9_]*_(handle|alias)|magnitude_bucket|bucket|relative_secs|relative_ms|since_origin)[ \t]*\\("
    SAFE  = "[A-Za-z_][A-Za-z0-9_.]*\\.((is_empty|is_some|is_none|is_ok|is_err)\\(\\)|(code|kind)(\\(\\))?)"
    COUNT = "[A-Za-z_][A-Za-z0-9_.]*\\.(len|count)\\(\\)"
    UNKNOWN = "(^|[^A-Za-z0-9_])[A-Za-z0-9_]+::(trace|debug|info|warn|error|event)!"
  } else {
    CALL  = "(^|[^A-Za-z0-9_.])(debugPrint|debugPrintThrottled|print|developer\\.log|dev\\.log|stderr\\.write|stderr\\.writeln|stdout\\.write|stdout\\.writeln|assert)[ \t]*\\("
    WRAP  = "(^|[^A-Za-z0-9_.])(logAliasHandle|logAlias|(_?[a-z][a-zA-Z0-9_]*)?(Handle|Alias)|magnitudeBucket|bucket|relativeSecs|relativeMs|sinceOrigin)[ \t]*\\("
    # `.name` on an enum is Dart's variant-name idiom (`outcome.name`); on a
    # circle it is user text. The receiver's last segment decides.
    # `details.library` is FlutterErrorDetails' library NAME ("widgets library").
    SAFE  = "[A-Za-z_][A-Za-z0-9_.]*\\.(runtimeType|isEmpty|isNotEmpty|code|kind|library)|([A-Za-z_][A-Za-z0-9_.]*\\.)?(kind|mode|status|state|outcome|decision|category|phase|tier|action|policy|verdict|class|variant|level)\\.name"
    COUNT = "[A-Za-z_][A-Za-z0-9_.]*\\.(length|size)"
    UNKNOWN = ""
  }
  BOUND = "([^A-Za-z0-9_(]|$)"
}

# Splits a line into CODE (string literals and the trailing comment removed),
# STRS (the concatenated literal contents) and COMMENT. INQ/QC/ESC are FILE
# state, not line state: a literal may span newlines.
function split_line(s,   i, n, c) {
  CODE = ""; STRS = ""; COMMENT = ""
  n = length(s)
  for (i = 1; i <= n; i++) {
    c = substr(s, i, 1)
    if (INQ) {
      if (ESC) { ESC = 0; STRS = STRS c; continue }
      if (c == "\\") { ESC = 1; continue }
      if (c == QC) { INQ = 0; STRS = STRS " "; continue }
      STRS = STRS c
      continue
    }
    if (c == "\"" || (lang == "dart" && c == "'")) { INQ = 1; QC = c; continue }
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
function verdict(tok,   n, i, parts, strong, weak, prose) {
  sub(/^_+/, "", tok)
  if (tok == "") return ""
  if (tok ~ IDENT) return "identifier"
  if (tok ~ PROSE) return "prose"
  n = split(tok, parts, "_")
  if (n < 2) return ""
  if (parts[1] ~ BOOLP || parts[n] ~ BOOLS) return ""
  strong = 0; weak = 0; prose = 0
  for (i = 1; i <= n; i++) {
    if (parts[i] ~ CLASSP) return ""
    if (parts[i] ~ STRONG) strong = 1
    if (parts[i] ~ WEAK) weak = 1
    if (parts[i] ~ PROSE) prose = 1
  }
  if (strong) return "identifier"
  if (weak) {
    for (i = 1; i <= n; i++) if (parts[i] ~ RELP) return ""
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

FNR == 1 { INMAC = 0; INQ = 0; ESC = 0; prev_supp = 0; CFGTEST = 0; SKIPPING = 0; SKIPIND = "" }
{
  split_line($0)
  if (lang == "rust" && skip_test_gated(CODE)) next
  unknown_macros(CODE)
  supp_here = (COMMENT ~ MARKER)
  rest = CODE
  while (1) {
    if (INMAC) {
      if (supp_here) SUPP = 1
      PH = PH placeholders(STRS)
      if (!consume(rest)) break
      emit(); INMAC = 0; rest = TAIL
    } else {
      if (!match(rest, CALL)) break
      INMAC = 1; PH = ""; ARGS = ""; TAIL = ""; DBG = 0; HEXF = 0
      m = substr(rest, RSTART, RLENGTH)
      DEPTH = gsub(/\(/, "(", m)                # `.expect(&format!(` opens two
      KIND = (m ~ /dbg!/) ? "dbg" : ((m ~ /(^|[^A-Za-z0-9_.])(debug_)?assert!?[ \t]*\(/) ? "assert" : "log")
      START = FNR; SRC = $0; sub(/^[ \t]*/, "", SRC)
      SUPP = (prev_supp || supp_here)
      rest = substr(rest, RSTART + RLENGTH)
    }
  }
  prev_supp = supp_here
}
END { printf "#sites %d\n", sites }
AWK
readonly SCAN_AWK

# ---------------------------------------------------------------------------
# Wrapper definitions. A name the scanner blesses must be a real wrapper: its
# body calls the canonical module and (Rust) it returns a handle. The canonical
# modules themselves are exempt — their own unit tests are the proof.
# ---------------------------------------------------------------------------
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

# wrappers <lang> <label> <file...>
wrappers() {
  local lang="$1" label="$2"; shift 2
  local out defs hits
  out="$(run_wrapdef "${lang}" "$@")"
  defs="$(sed -n 's/^#defs //p' <<<"${out}")"
  hits="$(grep -v '^#defs ' <<<"${out}" || true)"
  if [[ -n "${hits}" ]]; then
    fail "${label}: a definition carries a wrapper's NAME without a wrapper's body."
    printf '%s\n' "${hits}" | sed 's/^/    /' >&2
    echo "  The scanner blesses these names; the body must call the canonical log_alias module." >&2
    return 1
  fi
  log "OK: ${label} — ${defs:-0} alias/bucket wrapper definition(s), every one built on log_alias."
}

run_awk() { # run_awk <lang> <file...>
  local lang="$1"; shift
  awk -v lang="${lang}" "${SCAN_AWK}" "$@"
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
# 2 languages x (86 STRONG + 11 WEAK + 27 PROSE) words + 91 hand-written cases
# (shapes, format specs, markers, known-good, floors). An equality pin: a fixture added or lost
# without this line changing is a self-test that no longer says what it runs.
readonly DECLARED_CASES=341

self_test() {
  local tmp fails=0 checked=0
  tmp="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf '${tmp}'" RETURN

  _case() { # _case <label> <lang> <expect-hit:0|1> <ext> <content> [<expect-substring>]
    local label="$1" lang="$2" want="$3" ext="$4" content="$5" need="${6:-}" out got
    checked=$(( checked + 1 ))
    printf '%s' "${content}" > "${tmp}/f.${ext}"
    out="$(run_awk "${lang}" "${tmp}/f.${ext}")"
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
  _case "Dart enum variant name passes (outcome.name)" dart 0 dart "void f() { debugPrint('stop=\${outcome.name} (\${state.mode.name})'); }"
  _case "Dart user text does NOT pass as a variant name (circle.name)" dart 1 dart "void f() { debugPrint('joined \${circle.name}'); }" 'identifier(circle, name)'
  _case "Dart error.code passes" dart 0 dart "void f() { debugPrint('bg task error: \${error.code}'); }"
  _case "Rust e.kind() passes" rust 0 rs 'fn f() { log::warn!("io: {}", e.kind()); }'
  _case "a boolean prefix passes" dart 0 dart "void f() { debugPrint('relay ok: \$isRelayConnected'); }"
  _case "a boolean suffix passes" rust 0 rs 'fn f() { log::info!("{relay_ok}"); }'
  _case "an epoch DELTA passes" rust 0 rs 'fn f() { log::info!("peer is {epoch_delta} behind"); }'
  _case "a retry count passes" dart 0 dart "void f() { debugPrint('attempt \$retryCount'); }"
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
  [[ -d "${core}" ]] || misconfig "${core} not found"
  [[ -d "${ffi}"  ]] || misconfig "${ffi} not found"
  [[ -d "${dart}" ]] || misconfig "${dart} not found"

  local status=0 rc
  local -a rust_files dart_files
  mapfile -t rust_files < <(find "${core}" "${ffi}" -name '*.rs' ! -name 'frb_generated.rs' | sort)
  # `haven/lib/src/rust/` is the generated Dart binding — machine output.
  mapfile -t dart_files < <(find "${dart}" -name '*.dart' -not -path '*/src/rust/*' | sort)
  (( ${#rust_files[@]} > 0 )) || misconfig "no Rust sources found under ${core} / ${ffi}"
  (( ${#dart_files[@]} > 0 )) || misconfig "no Dart sources found under ${dart}"

  rc=0; scan rust "${MIN_RUST_SITES}" 'haven-core/src + rust_builder/src' "${rust_files[@]}" || rc=$?
  (( rc == 2 )) && exit 2
  (( rc == 0 )) || status=1

  rc=0; scan dart "${MIN_DART_SITES}" 'haven/lib' "${dart_files[@]}" || rc=$?
  (( rc == 2 )) && exit 2
  (( rc == 0 )) || status=1

  wrappers rust 'Rust wrapper definitions' "${rust_files[@]}" || status=1
  wrappers dart 'Dart wrapper definitions' "${dart_files[@]}" || status=1

  exit "${status}"
}

main "$@"
