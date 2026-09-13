#!/usr/bin/env bash
# CI guard: every hand-written `Debug`/`Display` impl has a redaction proof
# (Security Rule 15, log anonymity).
#
# ## Why
#
# A derived `Debug` prints every field; a hand-written one prints what its
# author chose — and that choice is exactly where a group id, a pubkey or a
# relay URL slips into a `{:?}` and from there into a log, a panic or an FFI
# error string. The privacy manifest cited four redaction tests while the tree
# carried 73 such impls: the other 69 were vouched for by nobody. This guard
# enumerates the population from SOURCE (comments and string literals stripped,
# so `// impl Debug for X` is not an impl) and fails on any impl that no proof
# names. A `thiserror` derive is a Display too: `#[error("… {0}")]` renders a
# field and `#[error(transparent)]` renders the inner error, so both are
# subjects; an all-constant `#[error("…")]` renders nothing of the value.
#
# ## What counts as a proof, per (file, trait, Type)
#
#   1. an `assert_debug_redacted!(…)` / `assert_display_redacted!(…)` invocation
#      whose argument text names `Type` — quoted, as every real call passes it —
#      in the same file or in the crate's `tests/`; trait-specific, because
#      Display and Debug are two renderings;
#   2. a test fn in the SAME file whose name contains `debug_redacts` /
#      `display_redacts`, whose name or body names `Type`, AND whose body
#      asserts on a rendering (the macros, `assert_rendering_redacted(`, or an
#      `assert!(!….contains(…))`) — a test that constructs the type and asserts
#      nothing is a name, not a proof;
#   3. a row in scripts/ci/debug_impl_allowlist.txt (`path::Type|why|owner`),
#      which is a reviewed exemption and fails when it goes stale.
#
# Anti-vacuity: the population is measured on every run and floored, so an
# extractor that stopped recognising `impl … for` cannot pass on an empty set.
#
# Exit codes:
#   0  every impl is covered and no allowlist row is stale or malformed
#   1  an uncovered impl, a stale row, or a malformed row
#   2  expected paths missing / floor breached / self-test failed (the guard
#      itself is broken)

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
readonly REPO_ROOT
readonly SCRIPT_NAME='check_debug_impls_covered'
readonly ALLOWLIST_REL='scripts/ci/debug_impl_allowlist.txt'

# = floor(73 x 0.8), measured 2026-09-12. Not a ratchet — deleting an impl is
# fine — but an extractor that stopped matching collapses well past it.
readonly MIN_DEBUG_IMPLS=58

log()  { printf '\033[1;34m[%s]\033[0m %s\n' "${SCRIPT_NAME}" "$*"; }
fail() { printf '\033[1;31m[%s] FAIL:\033[0m %s\n' "${SCRIPT_NAME}" "$*" >&2; }
misconfig() { printf '\033[1;31m[%s] BROKEN:\033[0m %s\n' "${SCRIPT_NAME}" "$*" >&2; exit 2; }

# ---------------------------------------------------------------------------
# Shared lexer, two views of a Rust file accumulated into BUF with one entry
# per source line so a match maps back to a line number. String state is FILE
# state: a literal may span lines.
#   keep=0  CODE view: string and char literals blanked, comments dropped —
#           what `impl … for` is matched on, so a literal cannot fake one.
#   keep=1  KEPT view: comments dropped, char literals blanked, string literals
#           preserved and normalised to `"…"` (raw strings re-quoted) — what the
#           proofs are read on, because every real macro call passes the type
#           NAME as a literal. `close_of` balances brackets over this view while
#           skipping literals, so a `"}"` cannot end a body early.
# ---------------------------------------------------------------------------
read -r -d '' LEXER_AWK <<'AWK' || true
function code_only(s,   i, n, c, out, d) {
  out = ""; n = length(s)
  for (i = 1; i <= n; i++) {
    c = substr(s, i, 1)
    if (INBLK) {
      if (c == "*" && substr(s, i + 1, 1) == "/") { INBLK--; i++ }
      else if (c == "/" && substr(s, i + 1, 1) == "*") { INBLK++; i++ }
      continue
    }
    if (INQ) {
      if (RAW) {
        if (c == "\"" && substr(s, i + 1, RAW - 1) == HASHES) { INQ = 0; i += RAW - 1; out = out (keep ? "\"" : " "); continue }
        if (keep) out = out ((c == "\"" || c == "\\") ? "\\" c : c)
        continue
      }
      if (ESC) { ESC = 0; if (keep) out = out c; continue }
      if (c == "\\") { ESC = 1; if (keep) out = out c; continue }
      if (c == "\"") { INQ = 0; out = out (keep ? "\"" : " "); continue }
      if (keep) out = out c
      continue
    }
    if (c == "/" && substr(s, i + 1, 1) == "/") break
    if (c == "/" && substr(s, i + 1, 1) == "*") { INBLK = 1; i++; continue }
    if (c == "\"") { INQ = 1; RAW = 0; if (keep) out = out "\""; continue }
    if (c == "r" && substr(s, i + 1, 1) ~ /[#"]/ \
        && (i == 1 || substr(s, i - 1, 1) !~ /[A-Za-z0-9_]/ || substr(s, i - 1, 1) == "b")) {
      d = 0
      while (substr(s, i + 1 + d, 1) == "#") d++
      if (substr(s, i + 1 + d, 1) == "\"") { INQ = 1; RAW = d + 1; HASHES = substr(s, i + 1, d); i += d + 1; if (keep) out = out "\""; continue }
    }
    # Char literals are blanked; lifetimes (`'a`) stay code.
    if (c == "'") {
      if (substr(s, i + 1, 1) != "\\" && substr(s, i + 2, 1) == "'") { out = out " "; i += 2; continue }
      if (substr(s, i + 1, 1) == "\\") {
        d = index(substr(s, i + 3), "'")
        if (d > 0 && d <= 8) { out = out " "; i += d + 2; continue }
      }
    }
    out = out c
  }
  return out
}
# Index of the bracket closing the one at `start`, skipping string literals.
function close_of(buf, start,   i, n, c, depth, q) {
  n = length(buf); depth = 0; q = 0
  for (i = start; i <= n; i++) {
    c = substr(buf, i, 1)
    if (q) { if (c == "\\") i++; else if (c == "\"") q = 0; continue }
    if (c == "\"") { q = 1; continue }
    if (c == "(" || c == "[" || c == "{") depth++
    else if (c == ")" || c == "]" || c == "}") { depth--; if (depth == 0) return i }
  }
  return n
}
FNR == 1 { if (NR > 1) flush(); BUF = ""; INQ = 0; ESC = 0; RAW = 0; INBLK = 0; FILE = FILENAME }
{ BUF = BUF code_only($0) "\n" }
END { if (NR > 0) flush() }
AWK
readonly LEXER_AWK

# One line per impl: `file \t line \t Debug|Display \t Type`. The header may be
# split by rustfmt (`impl<…> std::fmt::Debug` / `for Type`), so the match runs
# over the whole code view with newlines treated as whitespace.
read -r -d '' ENUM_AWK <<'AWK' || true
BEGIN {
  IMPL_RE = "(^|\n)[ \t]*impl(<[^{;]*>)?[ \t\n]+((std|core)::)?(fmt::)?(Debug|Display)[ \t\n]+for[ \t\n]+&?([A-Za-z_][A-Za-z0-9_]*::)*[A-Za-z_][A-Za-z0-9_]*"
}
function flush(   buf, s, l, m, pre, npre, ln, consumed, trait, ty) {
  buf = BUF; consumed = 0
  while (match(buf, IMPL_RE)) {
    # RSTART/RLENGTH are clobbered by the inner match below: save them first,
    # or the cursor advances by the wrong amount and re-reads the same impl.
    s = RSTART; l = RLENGTH
    m = substr(buf, s, l)
    pre = substr(buf, 1, s - 1)
    npre = gsub(/\n/, "", pre)
    ln = consumed + npre + 1
    if (m ~ /^\n/) ln++
    match(m, /(Debug|Display)[ \t\n]+for[ \t\n]+/)
    trait = (substr(m, RSTART, 5) == "Debug") ? "Debug" : "Display"
    ty = m
    sub(/.*for[ \t\n]+&?/, "", ty)
    sub(/^([A-Za-z_][A-Za-z0-9_]*::)+/, "", ty)
    printf "%s\t%d\t%s\t%s\n", FILE, ln, trait, ty
    consumed += npre + gsub(/\n/, "", m)
    buf = substr(buf, s + l)
  }
}
AWK
readonly ENUM_AWK

# One line per thiserror Display subject: `file \t line \t Display \t Type`,
# at the `#[derive` line. Read on the KEPT view: the placeholder that makes
# `#[error("… {0}")]` a subject lives inside the literal.
read -r -d '' THISERROR_AWK <<'AWK' || true
function flush(   buf, consumed, s, l, m, pre, npre, ln, rest, head, name, attrs, after, open, e, atext, as, ae, a, subject) {
  buf = BUF; consumed = 0
  while (match(buf, /(^|\n)[ \t]*#\[derive\([^)]*\)\]/)) {
    s = RSTART; l = RLENGTH
    m = substr(buf, s, l)
    pre = substr(buf, 1, s - 1); npre = gsub(/\n/, "", pre)
    ln = consumed + npre + 1
    if (m ~ /^\n/) ln++
    rest = substr(buf, s + l)
    if (m ~ /(^|[^A-Za-z0-9_:])(thiserror::)?Error([^A-Za-z0-9_]|$)/ \
        && match(rest, /(^|\n)[ \t]*(pub(\([a-z]+\))?[ \t]+)?(enum|struct)[ \t]+[A-Za-z_][A-Za-z0-9_]*/)) {
      head = substr(rest, RSTART, RLENGTH)
      name = head; sub(/.*(enum|struct)[ \t]+/, "", name)
      # A struct-level `#[error]` sits between the derive and the keyword; a
      # variant-level one sits in the body. A tuple/unit struct has no body.
      attrs = substr(rest, 1, RSTART - 1)
      after = substr(rest, RSTART + RLENGTH)
      open = index(after, "{")
      atext = attrs
      if (open > 0 && index(substr(after, 1, open - 1), ";") == 0) {
        e = close_of(after, open)
        atext = atext substr(after, open, e - open + 1)
      }
      subject = 0
      while (match(atext, /#\[error\(/)) {
        as = RSTART + RLENGTH - 1
        ae = close_of(atext, as)
        a = substr(atext, as, ae - as + 1)
        if (a ~ /^\([ \t\n]*transparent/ || a ~ /"[^"]*\{/) subject = 1
        atext = substr(atext, ae + 1)
      }
      if (subject) printf "%s\t%d\tDisplay\t%s\n", FILE, ln, name
    }
    consumed += npre + gsub(/\n/, "", m)
    buf = rest
  }
}
AWK
readonly THISERROR_AWK

# One line per invocation: `debug|display \t <argument text, one line>`, read
# on the KEPT view so the quoted type name is visible.
read -r -d '' MACRO_AWK <<'AWK' || true
function flush(   buf, m, kind, start, e, text) {
  buf = BUF
  while (match(buf, /(^|[^A-Za-z0-9_])assert_(debug|display)_redacted![ \t\n]*[(\[{]/)) {
    m = substr(buf, RSTART, RLENGTH)
    kind = (index(m, "assert_debug_") > 0) ? "debug" : "display"
    start = RSTART + RLENGTH - 1
    e = close_of(buf, start)
    text = substr(buf, start, e - start + 1)
    gsub(/\n/, " ", text)
    printf "%s\t%s\n", kind, text
    buf = substr(buf, e + 1)
  }
}
AWK
readonly MACRO_AWK

# One line per redaction-named test fn: `<kind> \t name \t <body>`, where
# <kind> is `debug`/`display` for a body that asserts on a rendering and
# `hollow-debug`/`hollow-display` for one that does not. Read on the KEPT view
# (the type name may be a literal); braces balance string-aware.
read -r -d '' TESTFN_AWK <<'AWK' || true
# The macros, the helper they expand to, or a negative containment assertion.
# A positive `assert!(rendered.contains("[REDACTED]"))` says nothing about
# what else the rendering carries and is not evidence.
function evidence(body,   rest, s, e, call) {
  if (body ~ /assert_(debug|display)_redacted!/ || body ~ /assert_rendering_redacted\(/) return 1
  rest = body
  while (match(rest, /assert!\(/)) {
    s = RSTART + RLENGTH - 1
    e = close_of(rest, s)
    call = substr(rest, s, e - s + 1)
    if (call ~ /^\([ \t\n]*!/ && call ~ /\.contains\(/) return 1
    rest = substr(rest, e + 1)
  }
  return 0
}
function flush(   buf, m, name, rest, open, e, body, tag) {
  buf = BUF
  while (match(buf, /(^|[^A-Za-z0-9_])fn[ \t\n]+[A-Za-z0-9_]*(debug|display)_redacts[A-Za-z0-9_]*/)) {
    m = substr(buf, RSTART, RLENGTH)
    sub(/^.*fn[ \t\n]+/, "", m); name = m
    rest = substr(buf, RSTART + RLENGTH)
    open = index(rest, "{")
    if (open == 0) { buf = rest; continue }
    e = close_of(rest, open)
    body = substr(rest, open, e - open + 1)
    gsub(/\n/, " ", body)
    tag = evidence(body) ? "" : "hollow-"
    if (name ~ /debug_redacts/)   printf "%sdebug\t%s\t%s\n", tag, name, body
    if (name ~ /display_redacts/) printf "%sdisplay\t%s\t%s\n", tag, name, body
    buf = substr(rest, e + 1)
  }
}
AWK
readonly TESTFN_AWK

enumerate_impls()  {
  (( $# > 0 )) || return 0
  awk -v keep=0 "${LEXER_AWK}"$'\n'"${ENUM_AWK}" "$@"
  awk -v keep=1 "${LEXER_AWK}"$'\n'"${THISERROR_AWK}" "$@"
}
macro_sites()      { (( $# > 0 )) || return 0; awk -v keep=1 "${LEXER_AWK}"$'\n'"${MACRO_AWK}"  "$@"; }
redaction_tests()  { (( $# > 0 )) || return 0; awk -v keep=1 "${LEXER_AWK}"$'\n'"${TESTFN_AWK}" "$@"; }

# Does any line of <lines> tagged <kind> name <Type> as a whole word? The tag
# column is dropped first so a kind name can never satisfy the match itself.
mentions() { # mentions <kind> <Type> <lines>
  local sel
  sel="$(awk -F'\t' -v k="$1" '$1 == k { $1 = ""; print }' <<<"$3")"
  [[ -n "${sel//[[:space:]]/}" ]] || return 1
  grep -qE "(^|[^A-Za-z0-9_])$2([^A-Za-z0-9_]|$)" <<<"${sel}"
}

trim() { local s="$1"; s="${s#"${s%%[![:space:]]*}"}"; s="${s%"${s##*[![:space:]]}"}"; printf '%s' "${s}"; }

# ---------------------------------------------------------------------------
# The check. Parameterised on root/allowlist/floor so the self-test can drive
# it over a fixture tree.
# ---------------------------------------------------------------------------
check_impls() { # check_impls <root> <allowlist> <floor>
  local root="$1" allow="$2" floor="$3"
  local core="${root}/haven-core/src" ffi="${root}/haven/rust_builder/src" tests="${root}/haven-core/tests"
  local -a files tfiles
  local impls total rc=0 core_test_macros='' uncovered='' stale='' malformed=''
  local n_macro=0 n_test=0 n_allow=0
  local -A ALLOW=() SEEN=() MACROS=() TESTS=()

  [[ -d "${core}" ]] || misconfig "${core} not found"
  [[ -d "${ffi}"  ]] || misconfig "${ffi} not found"
  [[ -f "${allow}" ]] || misconfig "${allow} not found"
  # `frb_generated.rs` is machine output: its impls are the generator's, and
  # regenerating it must not create a coverage obligation.
  mapfile -t files < <(find "${core}" "${ffi}" -name '*.rs' ! -name 'frb_generated.rs' | sort)
  (( ${#files[@]} > 0 )) || misconfig "no Rust sources under ${core} / ${ffi}"

  impls="$(enumerate_impls "${files[@]}")"
  total=0
  [[ -z "${impls}" ]] || total="$(wc -l <<<"${impls}")"
  if (( total < floor )); then
    fail "found ${total} hand-written Debug/Display impl(s), expected >= ${floor}."
    echo "  The extractor has stopped matching, so this check proves nothing." >&2
    echo "  Fix the enumerator (or lower the floor deliberately) — do not ignore it." >&2
    return 2
  fi

  local line key just owner extra n=0
  while IFS= read -r line || [[ -n "${line}" ]]; do
    n=$(( n + 1 ))
    [[ -z "${line//[[:space:]]/}" || "${line}" == \#* ]] && continue
    IFS='|' read -r key just owner extra <<<"${line}"
    key="$(trim "${key}")"; just="$(trim "${just:-}")"; owner="$(trim "${owner:-}")"
    if [[ -n "${extra:-}" || ! "${key}" =~ ^.+::[A-Za-z_][A-Za-z0-9_]*$ || -z "${just}" || -z "${owner}" ]]; then
      malformed+="    ${allow##*/}:${n}: ${line}"$'\n'
      continue
    fi
    ALLOW["${key}"]=1
  done < "${allow}"

  if [[ -d "${tests}" ]]; then
    mapfile -t tfiles < <(find "${tests}" -name '*.rs' | sort)
    core_test_macros="$(macro_sites "${tfiles[@]}")"
  fi

  local file ln trait ty rel kind text hint
  while IFS=$'\t' read -r file ln trait ty; do
    [[ -n "${file}" ]] || continue
    rel="${file#"${root}/"}"
    key="${rel}::${ty}"
    SEEN["${key}"]=1
    kind="${trait,,}"
    [[ -n "${MACROS[${file}]+x}" ]] || MACROS["${file}"]="$(macro_sites "${file}")"
    text="${MACROS[${file}]}"
    [[ "${file}" == "${core}"/* ]] && text+=$'\n'"${core_test_macros}"
    if mentions "${kind}" "${ty}" "${text}"; then n_macro=$(( n_macro + 1 )); continue; fi
    [[ -n "${TESTS[${file}]+x}" ]] || TESTS["${file}"]="$(redaction_tests "${file}")"
    if mentions "${kind}" "${ty}" "${TESTS[${file}]}"; then n_test=$(( n_test + 1 )); continue; fi
    if [[ -n "${ALLOW[${key}]:-}" ]]; then n_allow=$(( n_allow + 1 )); continue; fi
    hint=''
    if mentions "hollow-${kind}" "${ty}" "${TESTS[${file}]}"; then
      hint=" (a *${kind}_redacts* test names it but asserts nothing about its rendering)"
    fi
    uncovered+="    ${rel}:${ln}: ${trait} for ${ty} has no redaction proof${hint}"$'\n'
  done <<<"${impls}"

  if (( ${#ALLOW[@]} > 0 )); then
    for key in "${!ALLOW[@]}"; do
      [[ -n "${SEEN[${key}]:-}" ]] || stale+="    ${key}"$'\n'
    done
  fi

  log "measured ${total} hand-written Debug/Display impl(s): ${n_macro} by macro, ${n_test} by test, ${n_allow} by allowlist."
  if [[ -n "${malformed}" ]]; then
    fail "malformed allowlist row(s) — three non-empty fields 'path::Type|why|owner' are required:"
    printf '%s' "${malformed}" >&2
    rc=1
  fi
  if [[ -n "${stale}" ]]; then
    fail "stale allowlist row(s) — no impl exists for:"
    printf '%s' "${stale}" | sort >&2
    echo "  Delete the row: an allowance that outlives its cause is a proof nobody noticed vanishing." >&2
    rc=1
  fi
  if [[ -n "${uncovered}" ]]; then
    fail "hand-written Debug/Display impl(s) with no redaction proof (Security Rule 15):"
    printf '%s' "${uncovered}" >&2
    echo "  Prove it: assert_debug_redacted!/assert_display_redacted! naming the type, or a" >&2
    echo "  *debug_redacts*/*display_redacts* test in the same file that names it AND asserts" >&2
    echo "  on its rendering. A thiserror #[error(\"… {0}\")] / #[error(transparent)] is a Display." >&2
    echo "  A reviewed exemption goes in ${ALLOWLIST_REL} as 'path::Type|why|owner'." >&2
    rc=1
  fi
  (( rc == 0 )) && log "OK: every impl is covered; no stale or malformed rows."
  return "${rc}"
}

# ---------------------------------------------------------------------------
# Self-test — hermetic fixture trees, no repo state.
# ---------------------------------------------------------------------------
readonly DECLARED_CASES=37

self_test() {
  local tmp fails=0 checked=0
  tmp="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf '${tmp}'" RETURN

  _tree() { # _tree <name> -> prints root
    local t="${tmp}/$1"
    mkdir -p "${t}/haven-core/src" "${t}/haven-core/tests" "${t}/haven/rust_builder/src"
    : > "${t}/allow.txt"
    printf '%s' "${t}"
  }
  _pass() { printf '  \033[1;32mPASS\033[0m %s\n' "$1"; }
  _fail() { printf '  \033[1;31mFAIL\033[0m %s\n' "$1" >&2; fails=1; }

  _enum_case() { # _enum_case <label> <expected 'line\tTrait\tType' lines or ''> <content>
    local label="$1" want="$2" content="$3" got
    checked=$(( checked + 1 ))
    printf '%s' "${content}" > "${tmp}/e.rs"
    got="$(enumerate_impls "${tmp}/e.rs" | cut -f2-)"
    if [[ "${got}" == "${want}" ]]; then _pass "${label}"; else
      _fail "${label} (want [${want}], got [${got}])"
    fi
  }

  _run_case() { # _run_case <label> <expect-rc> <root> <floor> [<expected substring>]
    local label="$1" want="$2" root="$3" floor="$4" needle="${5:-}" out got=0
    checked=$(( checked + 1 ))
    out="$( ( check_impls "${root}" "${root}/allow.txt" "${floor}" ) 2>&1 )" || got=$?
    if [[ "${got}" -ne "${want}" ]]; then
      _fail "${label} (want rc=${want}, got rc=${got})"
      printf '%s\n' "${out}" | sed 's/^/        /' >&2
    elif [[ -n "${needle}" ]] && ! grep -qF -- "${needle}" <<<"${out}"; then
      _fail "${label} (rc ok, but output lacks '${needle}')"
      printf '%s\n' "${out}" | sed 's/^/        /' >&2
    else
      _pass "${label} (rc=${got})"
    fi
  }

  local IMPL_FOO='struct Foo;
impl std::fmt::Debug for Foo {
    fn fmt(&self, f: &mut std::fmt::Formatter<'"'"'_>) -> std::fmt::Result { f.write_str("Foo") }
}
'

  log "self-test: enumeration shapes"

  _enum_case "plain std::fmt::Debug is enumerated" $'2\tDebug\tFoo' "${IMPL_FOO}"
  _enum_case "fmt::Display is enumerated" $'2\tDisplay\tFoo' \
'struct Foo;
impl fmt::Display for Foo {
    fn fmt(&self, f: &mut fmt::Formatter<'"'"'_>) -> fmt::Result { f.write_str("Foo") }
}
'
  _enum_case "imported Debug (use std::fmt::Debug) is enumerated" $'3\tDebug\tFoo' \
'use std::fmt::Debug;
struct Foo;
impl Debug for Foo {
    fn fmt(&self, f: &mut std::fmt::Formatter<'"'"'_>) -> std::fmt::Result { f.write_str("Foo") }
}
'
  _enum_case "generic impl is enumerated with generics stripped" $'1\tDebug\tIdentityManager' \
'impl<S: SecureKeyStorage> std::fmt::Debug for IdentityManager<S> {
    fn fmt(&self, f: &mut std::fmt::Formatter<'"'"'_>) -> std::fmt::Result { f.write_str("IdentityManager") }
}
'
  _enum_case "lifetime impl is enumerated" $'1\tDebug\tBorrowed' \
'impl<'"'"'a> fmt::Debug for Borrowed<'"'"'a> {
    fn fmt(&self, f: &mut fmt::Formatter<'"'"'_>) -> fmt::Result { f.write_str("Borrowed") }
}
'
  _enum_case "where clause on the next line is enumerated" $'2\tDebug\tWrap' \
'use std::fmt::Debug;
impl<T> Debug for Wrap<T>
where
    T: Bar,
{
    fn fmt(&self, f: &mut std::fmt::Formatter<'"'"'_>) -> std::fmt::Result { f.write_str("Wrap") }
}
'
  # rustfmt splits a long header after the trait; the type is on the next line.
  _enum_case "rustfmt-split header is enumerated at the impl line" $'1\tDebug\tManager' \
'impl<S: SecureKeyStorage + Clone + Send> std::fmt::Debug
    for Manager<S>
{
    fn fmt(&self, f: &mut std::fmt::Formatter<'"'"'_>) -> std::fmt::Result { f.write_str("Manager") }
}
'
  _enum_case "impls in comments and string literals are not enumerated" '' \
'// impl std::fmt::Debug for Ghost {
/* impl fmt::Display for Shade {
   still a comment */
const S: &str = "
impl fmt::Debug for Phantom {
";
fn f() {}
'

  log "self-test: thiserror Display subjects"

  _enum_case "a thiserror #[error] with a placeholder is a Display subject" $'1\tDisplay\tE' \
'#[derive(Debug, Error)]
pub enum E {
    #[error("no relays configured")]
    NoRelays,
    #[error("bad {0}")]
    Bad(String),
}
'
  _enum_case "#[error(transparent)] is a Display subject" $'1\tDisplay\tE' \
'#[derive(thiserror::Error, Debug)]
pub enum E {
    #[error(transparent)]
    Inner(#[from] std::io::Error),
}
'
  _enum_case "a struct-level #[error] with a placeholder on a tuple struct is a subject" $'2\tDisplay\tE' \
'use thiserror::Error;
#[derive(Error, Debug)]
#[error("wrapped: {0}")]
pub struct E(String);
'
  _enum_case "all-constant #[error] messages are not a subject" '' \
'#[derive(Debug, Error)]
pub enum E {
    #[error("no relays configured")]
    NoRelays,
    #[error(
        "the session is busy"
    )]
    Busy,
}
'
  _enum_case "a derive without Error is untouched" '' \
'#[derive(Debug, Clone)]
pub struct S {
    x: String,
}
'

  log "self-test: coverage"
  local t

  t="$(_tree uncovered)"
  printf '%s' "${IMPL_FOO}" > "${t}/haven-core/src/a.rs"
  _run_case "an impl with no proof FAILS" 1 "${t}" 1 'haven-core/src/a.rs:2: Debug for Foo has no redaction proof'

  t="$(_tree macro_same_file)"
  printf '%s%s' "${IMPL_FOO}" \
'#[cfg(test)]
mod tests {
    #[test]
    fn rendering_is_redacted() {
        assert_debug_redacted!(
            Foo,
            ["needle"]
        );
    }
}
' > "${t}/haven-core/src/a.rs"
  _run_case "a multi-line assert_debug_redacted! in the same file passes" 0 "${t}" 1 '1 by macro'

  # Every real call passes the type NAME as a string literal. A code view that
  # blanks literals never saw one, and the macro path was inoperative.
  t="$(_tree macro_quoted)"
  printf '%s%s' "${IMPL_FOO}" \
'#[cfg(test)]
mod tests {
    #[test]
    fn t() { crate::assert_debug_redacted!(Foo, "Foo", &[&needle]); }
}
' > "${t}/haven-core/src/a.rs"
  _run_case "a macro naming the type as a string literal passes" 0 "${t}" 1 '1 by macro'

  t="$(_tree macro_commented)"
  printf '%s%s' "${IMPL_FOO}" \
'#[cfg(test)]
mod tests {
    // crate::assert_debug_redacted!(Foo, "Foo", &[&needle]);
    #[test]
    fn t() {}
}
' > "${t}/haven-core/src/a.rs"
  _run_case "a macro inside a comment is not a proof" 1 "${t}" 1 'Debug for Foo has no redaction proof'

  # A `)` inside a needle literal must not end the argument list before the
  # type name.
  t="$(_tree macro_paren_literal)"
  printf '%s%s' "${IMPL_FOO}" \
'#[cfg(test)]
mod tests {
    #[test]
    fn t() { crate::assert_debug_redacted!(make(")"), "Foo", &[")"]); }
}
' > "${t}/haven-core/src/a.rs"
  _run_case "a paren inside a literal does not truncate the macro arguments" 0 "${t}" 1 '1 by macro'

  t="$(_tree macro_tests_dir)"
  printf '%s' "${IMPL_FOO}" > "${t}/haven-core/src/a.rs"
  printf '%s' '#[test]
fn every_rendering_is_redacted() {
    assert_debug_redacted!(Foo, ["needle"]);
}
' > "${t}/haven-core/tests/redaction.rs"
  _run_case "a macro in haven-core/tests passes" 0 "${t}" 1 '1 by macro'

  t="$(_tree macro_other_type)"
  printf '%s%s' "${IMPL_FOO}" \
'#[cfg(test)]
mod tests {
    #[test]
    fn t() { assert_debug_redacted!(Bar::default(), ["needle"]); }
}
' > "${t}/haven-core/src/a.rs"
  _run_case "a macro naming a DIFFERENT type FAILS" 1 "${t}" 1 'Debug for Foo has no redaction proof'

  t="$(_tree display_vs_debug)"
  printf '%s' 'struct Foo;
impl std::fmt::Display for Foo {
    fn fmt(&self, f: &mut std::fmt::Formatter<'"'"'_>) -> std::fmt::Result { f.write_str("Foo") }
}
#[cfg(test)]
mod tests {
    #[test]
    fn t() { assert_debug_redacted!(Foo, ["needle"]); }
}
' > "${t}/haven-core/src/a.rs"
  _run_case "a Display impl is NOT covered by the debug macro" 1 "${t}" 1 'Display for Foo has no redaction proof'

  t="$(_tree display_macro)"
  printf '%s' 'struct Foo;
impl std::fmt::Display for Foo {
    fn fmt(&self, f: &mut std::fmt::Formatter<'"'"'_>) -> std::fmt::Result { f.write_str("Foo") }
}
#[cfg(test)]
mod tests {
    #[test]
    fn t() { assert_display_redacted!(Foo, ["needle"]); }
}
' > "${t}/haven-core/src/a.rs"
  _run_case "a Display impl covered by assert_display_redacted! passes" 0 "${t}" 1 '1 by macro'

  # The `"}"` literal would end the body before `Foo` if braces were balanced
  # over raw text instead of the code view.
  t="$(_tree test_fn)"
  printf '%s%s' "${IMPL_FOO}" \
'#[cfg(test)]
mod tests {
    #[test]
    fn foo_debug_redacts_secret() {
        let close = "}";
        let rendered = format!("{:?}", Foo);
        assert!(!rendered.contains("needle"));
    }
}
' > "${t}/haven-core/src/a.rs"
  _run_case "a *debug_redacts* test whose body names the type passes" 0 "${t}" 1 '1 by test'

  # THE hole the review found: a correctly named test that builds the type and
  # asserts nothing about what it renders.
  t="$(_tree test_fn_hollow)"
  printf '%s%s' "${IMPL_FOO}" \
'#[cfg(test)]
mod tests {
    #[test]
    fn foo_debug_redacts_secret() {
        let rendered = format!("{:?}", Foo);
        assert!(rendered.starts_with("Foo"));
    }
}
' > "${t}/haven-core/src/a.rs"
  _run_case "a *debug_redacts* test that asserts nothing about the rendering FAILS" 1 "${t}" 1 'names it but asserts nothing about its rendering'

  t="$(_tree test_fn_positive_only)"
  printf '%s%s' "${IMPL_FOO}" \
'#[cfg(test)]
mod tests {
    #[test]
    fn foo_debug_redacts_secret() {
        let rendered = format!("{:?}", Foo);
        assert!(rendered.contains("[REDACTED]"));
    }
}
' > "${t}/haven-core/src/a.rs"
  _run_case "a positive contains() assertion is not evidence of redaction" 1 "${t}" 1 'Debug for Foo has no redaction proof'

  t="$(_tree test_fn_helper)"
  printf '%s%s' "${IMPL_FOO}" \
'#[cfg(test)]
mod tests {
    #[test]
    fn foo_debug_redacts_secret() {
        crate::util::assert_rendering_redacted("Debug", "a type", "marker", &format!("{:?}", Foo), &[&needle]);
    }
}
' > "${t}/haven-core/src/a.rs"
  _run_case "a *debug_redacts* test calling assert_rendering_redacted passes" 0 "${t}" 1 '1 by test'

  t="$(_tree thiserror_uncovered)"
  printf '%s' '#[derive(Debug, Error)]
pub enum E {
    #[error("bad {0}")]
    Bad(String),
}
' > "${t}/haven-core/src/a.rs"
  _run_case "an uncovered thiserror Display FAILS at the derive line" 1 "${t}" 1 'haven-core/src/a.rs:1: Display for E has no redaction proof'

  t="$(_tree thiserror_covered)"
  printf '%s' '#[derive(Debug, Error)]
pub enum E {
    #[error("bad {0}")]
    Bad(String),
}
#[cfg(test)]
mod tests {
    #[test]
    fn t() { crate::assert_display_redacted!(E::Bad(needle.into()), "E", marker = "bad", &[&needle]); }
}
' > "${t}/haven-core/src/a.rs"
  _run_case "a thiserror Display covered by assert_display_redacted! passes" 0 "${t}" 1 '1 by macro'

  t="$(_tree test_fn_no_mention)"
  printf '%s%s' "${IMPL_FOO}" \
'#[cfg(test)]
mod tests {
    #[test]
    fn foo_debug_redacts_secret() {
        let rendered = format!("{:?}", make());
        assert!(!rendered.contains("needle"));
    }
}
' > "${t}/haven-core/src/a.rs"
  _run_case "a *debug_redacts* test that never names the type FAILS" 1 "${t}" 1 'Debug for Foo has no redaction proof'

  t="$(_tree test_fn_in_comment)"
  printf '%s%s' "${IMPL_FOO}" \
'#[cfg(test)]
mod tests {
    // fn foo_debug_redacts_secret() { let _ = Foo; }
    #[test]
    fn foo_renders() { let _ = format!("{:?}", Foo); }
}
' > "${t}/haven-core/src/a.rs"
  _run_case "debug_redacts only inside a comment is not a proof" 1 "${t}" 1 'Debug for Foo has no redaction proof'

  t="$(_tree allow_row)"
  printf '%s' "${IMPL_FOO}" > "${t}/haven-core/src/a.rs"
  printf '# header\n\nhaven-core/src/a.rs::Foo | a fixed literal with no fields | D\n' > "${t}/allow.txt"
  _run_case "an allowlist row passes" 0 "${t}" 1 '1 by allowlist'

  t="$(_tree allow_empty_reason)"
  printf '%s' "${IMPL_FOO}" > "${t}/haven-core/src/a.rs"
  printf 'haven-core/src/a.rs::Foo||D\n' > "${t}/allow.txt"
  _run_case "a row with an empty justification FAILS" 1 "${t}" 1 'malformed allowlist row'

  t="$(_tree allow_malformed)"
  printf '%s' "${IMPL_FOO}" > "${t}/haven-core/src/a.rs"
  printf 'haven-core/src/a.rs::Foo|why|D|extra\n' > "${t}/allow.txt"
  _run_case "a row with a fourth field FAILS" 1 "${t}" 1 'malformed allowlist row'

  t="$(_tree allow_stale)"
  printf '%s%s' "${IMPL_FOO}" \
'#[cfg(test)]
mod tests {
    #[test]
    fn t() { assert_debug_redacted!(Foo, ["needle"]); }
}
' > "${t}/haven-core/src/a.rs"
  printf 'haven-core/src/a.rs::Gone|it used to exist|D\n' > "${t}/allow.txt"
  _run_case "a row whose impl no longer exists is STALE and FAILS" 1 "${t}" 1 'stale allowlist row'

  t="$(_tree generated_ignored)"
  printf '%s%s' "${IMPL_FOO}" \
'#[cfg(test)]
mod tests {
    #[test]
    fn t() { assert_debug_redacted!(Foo, ["needle"]); }
}
' > "${t}/haven/rust_builder/src/api.rs"
  printf '%s' 'impl std::fmt::Debug for Generated {
    fn fmt(&self, f: &mut std::fmt::Formatter<'"'"'_>) -> std::fmt::Result { f.write_str("Generated") }
}
' > "${t}/haven/rust_builder/src/frb_generated.rs"
  _run_case "an uncovered impl in frb_generated.rs is not enumerated" 0 "${t}" 1 'measured 1 '

  t="$(_tree ffi_uncovered)"
  printf '%s' "${IMPL_FOO}" > "${t}/haven/rust_builder/src/api.rs"
  _run_case "rust_builder impls are scanned too" 1 "${t}" 1 'haven/rust_builder/src/api.rs:2: Debug for Foo'

  t="$(_tree floor)"
  printf '%s%s' "${IMPL_FOO}" \
'#[cfg(test)]
mod tests {
    #[test]
    fn t() { assert_debug_redacted!(Foo, ["needle"]); }
}
' > "${t}/haven-core/src/a.rs"
  _run_case "fewer impls than the floor is BROKEN, not clean" 2 "${t}" 2 'expected >= 2'

  if (( checked != DECLARED_CASES )); then
    fail "self-test ran ${checked} case(s) but declares ${DECLARED_CASES} — update the pin with the fixtures."
    exit 2
  fi
  if (( fails )); then
    fail "self-test failed — this guard cannot be trusted until it is fixed"
    exit 2
  fi
  log "OK: self-test passed (${checked} fixtures)."
}

# ---------------------------------------------------------------------------
main() {
  if [[ "${1:-}" == "--self-test" ]]; then
    self_test
    exit 0
  fi
  (( $# == 0 )) || misconfig "usage: ${SCRIPT_NAME}.sh [--self-test]"

  local rc=0
  check_impls "${REPO_ROOT}" "${REPO_ROOT}/${ALLOWLIST_REL}" "${MIN_DEBUG_IMPLS}" || rc=$?
  exit "${rc}"
}

main "$@"
