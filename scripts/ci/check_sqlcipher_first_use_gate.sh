#!/usr/bin/env bash
# CI guard: every direct SQLite open passes the first-use gate.
#
# ## Why this exists
#
# `sqlite3_initialize` marks the library initialised, releases its mutex, and
# only then runs SQLCipher's own start-up (`sqlcipher_extra_init`) on the thread
# that initialised. Until that returns, `PRAGMA key` fails on every other
# thread. Every Dart isolate shares the one loaded library, so of two stores
# opened at process start — the UI isolate's tile cache, a background isolate's
# circle manager — one could fail to open, and seven tests of one binary once
# did together. `haven_core::sqlcipher_init::ensure` runs that initialisation to
# completion under a lock; it only helps a caller that goes through it
# (docs/MDK_UPSTREAM_TRACKER.md, row T-SQLCIPHER-FIRST-USE).
#
# ## What it enforces
#
#   F1. In every Rust file under the roots that link haven-core's SQLCipher
#       (`haven-core/src`, `haven-core/tests`, `haven/rust_builder/src`,
#       `tooling/soak/src`, `tooling/soak/tests`; line and block comments and
#       string literals dropped, `frb_generated` excluded), each mention of
#       `Connection::open*`, of `open*` / `in_memory*` on `SqliteAccountStorage`,
#       `SqliteStorage` (its deprecated alias) or `SqliteSharedStorage`, and of
#       `AccountDeviceSession::open*` — called or merely named, as in
#       `.map(Connection::open)`, and through a qualified path as well
#       (`<Connection>::open`) — sits in a function that calls
#       `sqlcipher_init::ensure(` BEFORE it. A function ends at its closing
#       brace, and a declaration without a body at its `;`, so nothing after
#       either (a `static` initialiser, say) inherits a gate. Tests are held to
#       it as well: a test whose first act is a raw keyed open is the same
#       race. The gate's own file is the one exemption.
#   F2. The gate is still a gate: `haven-core/src/sqlcipher_init.rs` declares
#       `pub fn ensure(` and opens a connection, and `lib.rs` exports it.
#   F3. The three production store openers are still seen, gated, so a rename
#       cannot leave the scan passing over nothing:
#         nostr/mls/manager.rs  open_session            session.sqlite (both handles)
#         circle/storage.rs     new                     circles.db
#         tiles/storage.rs      open_keyed_connection   tiles.db
#
# What a grep cannot see: an open reached through an alias (`use
# rusqlite::Connection as C`, `type Db = rusqlite::Connection`), a gate call in
# a branch that does not run, an open in a crate outside the scanned roots, and
# code the line scanner misreads (a string literal that spans lines; a function
# not laid out by rustfmt; a declaration without a body whose signature is
# wrapped over several lines, which a `static` below it is then read into). For
# the openers listed in `haven-core/tests/sqlcipher_first_use_gate.rs` that test
# runs each one in a process of its own and fails if the gate has not run by the
# time the open returns. Nothing else detects the rest: review them by hand.
#
# Pure-grep gate (no Rust toolchain), part of the shared repo-guards job.
#
# Usage:
#   check_sqlcipher_first_use_gate.sh            # check the repo
#   check_sqlcipher_first_use_gate.sh --self-test
#
# Exit codes: 0 pass; 1 violation (including a vacuous scan); 2 misuse.

set -Eeuo pipefail
LITERAL_FREE="$(cat "$(dirname "${BASH_SOURCE[0]}")/lib/literal_free.awk")"
readonly LITERAL_FREE

SCRIPT_NAME="check_sqlcipher_first_use_gate"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
readonly SCAN_DIRS=(
  "haven-core/src" "haven-core/tests" "haven/rust_builder/src"
  "tooling/soak/src" "tooling/soak/tests"
)
readonly GATE_FILE="haven-core/src/sqlcipher_init.rs"
readonly ANCHORS=(
  "haven-core/src/nostr/mls/manager.rs:open_session"
  "haven-core/src/circle/storage.rs:new"
  "haven-core/src/tiles/storage.rs:open_keyed_connection"
)
readonly SELF_TEST_FIXTURES=34

log() { printf '\033[1;34m[%s]\033[0m %s\n' "${SCRIPT_NAME}" "$*"; }
fail_msg() { printf '\033[1;31m[%s] FAIL:\033[0m %s\n' "${SCRIPT_NAME}" "$*" >&2; }

# `<line-no><TAB><enclosing fn><TAB><gated|ungated>` for every direct open in a
# file.
#
# Each line is lexed left to right, so a `//` inside a string is not a comment,
# a `"` inside a comment is not a string, and a block comment (nested, or
# spanning lines) is dropped whole. A function is the span from its `fn` line to
# the closing brace at that line's own indentation, which is how rustfmt lays
# every function out; a declaration without a body (a trait's method) ends on
# its own line, at the `;`. An open outside any function (a `static`
# initialiser) is never gated, whatever precedes it: no function there calls
# the gate first.
open_sites() { # open_sites <file>
  awk "${LITERAL_FREE}"'
    function code_of(line,    out, i, n, c, two) {
      out = ""; i = 1; n = length(line)
      while (i <= n) {
        c = substr(line, i, 1); two = substr(line, i, 2)
        if (depth > 0) {
          if (two == "*/") { depth--; i += 2 }
          else if (two == "/*") { depth++; i += 2 }
          else i++
        } else if (two == "//") {
          break
        } else if (two == "/*") {
          depth++; i += 2
        } else if (substr(line, i, 3) == "\047\"\047") {
          i += 3
        } else if (substr(line, i, 4) == "\047\\\"\047") {
          i += 4
        } else if (c == "\"") {
          i++
          while (i <= n) {
            c = substr(line, i, 1)
            if (c == "\\") i += 2
            else if (c == "\"") { i++; break }
            else i++
          }
          out = out "\"\""
        } else {
          out = out c; i++
        }
      }
      return out
    }
    BEGIN {
      left = "(^|[^A-Za-z0-9_])"
      site = left "(Connection>?::open[a-z_]*|(SqliteAccountStorage|SqliteStorage|SqliteSharedStorage)>?::(open|in_memory)[a-z_]*|AccountDeviceSession>?::open[a-z_]*)"
      gate = "sqlcipher_init::ensure[(]"
      depth = 0; in_fn = 0
    }
    {
      t = (depth == 0 && $0 !~ /["\/]/) ? $0 : code_of($0)
      indent = match($0, /[^ ]/) ? RSTART - 1 : 0
      ends_here = 0
      if (match(t, /(^|[^A-Za-z0-9_])fn [A-Za-z_0-9]+/)) {
        f = substr(t, RSTART, RLENGTH); sub(/^.*fn /, "", f)
        fn_name = f; gated = 0; in_fn = 1; fn_indent = indent
        lfree = literal_free(t); tmp = lfree; opens = gsub(/[{]/, "", tmp)
        tmp = lfree; closes = gsub(/[}]/, "", tmp)
        if ((opens > 0 && opens == closes) || t ~ /;[[:space:]]*$/) ends_here = 1
      } else if (in_fn && indent == fn_indent && t ~ /^[[:space:]]*[}]/) {
        ends_here = 1
      }
      g = match(t, gate) ? RSTART : 0
      s = match(t, site) ? RSTART : 0
      if (g && (!s || g < s)) gated = 1
      if (s) printf "%d\t%s\t%s\n", NR, (in_fn ? fn_name : "-"), (in_fn && gated ? "gated" : "ungated")
      if (g) gated = 1
      if (ends_here) { in_fn = 0; gated = 0 }
    }
  ' "$1"
}

run_checks() { # run_checks <root>
  local root="$1" fail=0 f rel line fn state entry d
  local -a files=() dirs=()
  for d in "${SCAN_DIRS[@]}"; do [[ -d "${root}/${d}" ]] && dirs+=("${root}/${d}"); done
  if (( ${#dirs[@]} > 0 )); then
    mapfile -t files < <(find "${dirs[@]}" -name '*.rs' | grep -v frb_generated | sort)
  fi
  if (( ${#files[@]} == 0 )); then
    fail_msg "[F1] no Rust source found: the scan would pass vacuously."
    return 1
  fi

  local -A seen=()
  for f in "${files[@]}"; do
    rel="${f#"${root}/"}"
    [[ "${rel}" == "${GATE_FILE}" ]] && continue
    while IFS=$'\t' read -r line fn state; do
      [[ -n "${line}" ]] || continue
      if [[ "${state}" == gated ]]; then
        seen["${rel}:${fn}"]=1
      else
        fail_msg "[F1] ${rel}:${line} (fn ${fn}) opens SQLite without calling \
\`sqlcipher_init::ensure()\` first in the same function. A store opened while another \
thread is still inside SQLCipher's start-up fails its \`PRAGMA key\`."
        fail=1
      fi
    done < <(open_sites "${f}")
  done

  local gate="${root}/${GATE_FILE}" lib="${root}/haven-core/src/lib.rs"
  if [[ ! -f "${gate}" ]] \
    || ! grep -qE '^pub fn ensure\(' "${gate}" \
    || ! grep -qE 'Connection::open_in_memory\(' "${gate}"; then
    fail_msg "[F2] ${GATE_FILE} no longer declares \`pub fn ensure(\` over an in-memory open: \
the gate every store open calls does not initialise SQLite."
    fail=1
  fi
  if [[ ! -f "${lib}" ]] || ! grep -qE '^pub mod sqlcipher_init;' "${lib}"; then
    fail_msg "[F2] haven-core/src/lib.rs no longer exports \`pub mod sqlcipher_init;\`."
    fail=1
  fi

  for entry in "${ANCHORS[@]}"; do
    if [[ -z "${seen[${entry}]:-}" ]]; then
      fail_msg "[F3] ${entry} is no longer seen as a gated open: update the reviewed \
list, or the scan can pass over nothing."
      fail=1
    fi
  done

  (( fail == 0 )) || return 1
  log "OK: every direct SQLite open passes the first-use gate (${#seen[@]} gated function(s), ${#ANCHORS[@]} production openers anchored)."
}

self_test() {
  local tmp fails=0 checked=0
  tmp="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf '${tmp}'" RETURN

  local gate_src lib_src session_src circle_src tiles_src
  gate_src='pub fn ensure() -> rusqlite::Result<()> {
    run_once(&INITIALISED, || rusqlite::Connection::open_in_memory().map(drop))
}'
  lib_src='pub mod sqlcipher_init;'
  session_src='fn open_session(p: PathBuf, k: Key) -> Result<Self> {
    crate::sqlcipher_init::ensure().map_err(|_| e())?;
    let store = SqliteAccountStorage::open_encrypted_with_options(&p, &k, o())?;
    let session = AccountDeviceSession::open(config)?;
}'
  circle_src='pub fn new(path: &Path) -> Result<Self> {
    crate::sqlcipher_init::ensure()?;
    let conn = Connection::open(path)?;
}'
  tiles_src='fn open_keyed_connection(path: &Path) -> Result<Connection> {
    crate::sqlcipher_init::ensure()?;
    let conn = Connection::open(path)?;
}'

  # _case <label> <want-rc> <relative path> <content>: the passing tree with one
  # file added or replaced (`-` as the content deletes it).
  _case() {
    local label="$1" want="$2" rel="$3" content="$4" t got=0
    checked=$(( checked + 1 ))
    t="${tmp}/case${checked}"
    mkdir -p "${t}/haven-core/src/nostr/mls" "${t}/haven-core/src/circle" \
      "${t}/haven-core/src/tiles" "${t}/haven-core/tests" "${t}/tooling/soak/src"
    printf '%s\n' "${gate_src}" >"${t}/${GATE_FILE}"
    printf '%s\n' "${lib_src}" >"${t}/haven-core/src/lib.rs"
    printf '%s\n' "${session_src}" >"${t}/haven-core/src/nostr/mls/manager.rs"
    printf '%s\n' "${circle_src}" >"${t}/haven-core/src/circle/storage.rs"
    printf '%s\n' "${tiles_src}" >"${t}/haven-core/src/tiles/storage.rs"
    if [[ "${content}" == "-" ]]; then
      rm -f "${t}/${rel}"
    else
      printf '%s\n' "${content}" >"${t}/${rel}"
    fi
    ( run_checks "${t}" ) >/dev/null 2>&1 || got=$?
    if [[ "${got}" -eq "${want}" ]]; then
      printf '  \033[1;32mPASS\033[0m %s (rc=%d)\n' "${label}" "${got}"
    else
      printf '  \033[1;31mFAIL\033[0m %s (want rc=%d, got rc=%d)\n' "${label}" "${want}" "${got}" >&2
      fails=1
    fi
  }

  echo "${SCRIPT_NAME}.sh --self-test"
  _case "every open behind the gate passes" 0 "haven-core/src/extra.rs" \
'fn unrelated() {}'
  _case "an open with no gate call in its function FAILS" 1 "haven-core/src/tiles/storage.rs" \
'fn open_keyed_connection(path: &Path) -> Result<Connection> {
    let conn = Connection::open(path)?;
}'
  _case "a gate call AFTER the open FAILS" 1 "haven-core/src/circle/storage.rs" \
'pub fn new(path: &Path) -> Result<Self> {
    let conn = Connection::open(path)?;
    crate::sqlcipher_init::ensure()?;
}'
  _case "a gate call in an earlier function does not carry over" 1 "haven-core/src/circle/storage.rs" \
'pub fn new(path: &Path) -> Result<Self> {
    crate::sqlcipher_init::ensure()?;
    let conn = Connection::open(path)?;
}
fn migrate(path: &Path) -> Result<Self> {
    let conn = Connection::open(path)?;
}'
  _case "a commented-out gate call does not stand in for the call" 1 "haven-core/src/tiles/storage.rs" \
'fn open_keyed_connection(path: &Path) -> Result<Connection> {
    // crate::sqlcipher_init::ensure()?;
    let conn = Connection::open(path)?;
}'
  _case "a gate call quoted in a string does not stand in for the call" 1 "haven-core/src/tiles/storage.rs" \
'fn open_keyed_connection(path: &Path) -> Result<Connection> {
    let why = "crate::sqlcipher_init::ensure()?;";
    let conn = Connection::open(path)?;
}'
  _case "an open named only in a comment or a string is not an open" 0 "haven-core/src/extra.rs" \
'/// Wraps `Connection::open(path)` for the callers above.
fn fixture() {
    let open = "SqliteAccountStorage::open_encrypted(p, k);"; // Connection::open(p)
    let url = "wss://relay.example"; let n = 1;
}'
  _case "a session opened outside the gated opener FAILS" 1 "haven-core/src/extra.rs" \
'fn second_session(config: SessionConfig) -> Result<S> {
    AccountDeviceSession::open(config)
}'
  _case "an in-memory MDK store with no gate call FAILS" 1 "haven-core/src/extra.rs" \
'pub fn in_memory_storage() -> Result<SqliteAccountStorage> {
    SqliteAccountStorage::in_memory().map_err(e)
}'
  _case "a one-line function is read in order: gate then open passes" 0 "haven-core/src/extra.rs" \
'fn mem() -> R { crate::sqlcipher_init::ensure()?; Connection::open_in_memory() }'
  _case "a one-line function is read in order: open then gate FAILS" 1 "haven-core/src/extra.rs" \
'fn mem() -> R { let c = Connection::open_in_memory(); crate::sqlcipher_init::ensure()?; c }'
  _case "an integration test whose raw open skips the gate FAILS" 1 "haven-core/tests/raw_open.rs" \
'#[test]
fn keyed() {
    let conn = Connection::open_in_memory().expect("open");
}'
  _case "an ungated open in the soak rig FAILS" 1 "tooling/soak/src/store.rs" \
'fn peek(path: &Path) -> rusqlite::Connection {
    rusqlite::Connection::open_with_flags(path, flags).unwrap()
}'
  _case "a gate that no longer opens a connection FAILS" 1 "${GATE_FILE}" \
'pub fn ensure() -> rusqlite::Result<()> {
    Ok(())
}'
  _case "a missing gate module FAILS" 1 "${GATE_FILE}" "-"
  _case "a production opener that no longer opens FAILS" 1 "haven-core/src/tiles/storage.rs" \
'fn open_keyed_connection(path: &Path) -> Result<Connection> {
    crate::sqlcipher_init::ensure()?;
    other::open(path)
}'

  _case "an MDK in-memory store opened with options, ungated, FAILS" 1 "haven-core/src/extra.rs" \
'pub fn tuned() -> Result<SqliteAccountStorage> {
    SqliteAccountStorage::in_memory_with_options(options()).map_err(e)
}'
  _case "the deprecated SqliteStorage alias, ungated, FAILS" 1 "haven-core/src/extra.rs" \
'fn legacy(p: &Path, k: &SqlCipherKey) -> Result<S> {
    storage_sqlite::SqliteStorage::open_encrypted(p, k).map_err(e)
}'
  _case "the shared store opened on a path, ungated, FAILS" 1 "haven-core/src/extra.rs" \
'fn shared(p: &Path) -> Result<SqliteSharedStorage> {
    SqliteSharedStorage::open(p).map_err(e)
}'
  _case "the shared store opened in memory, ungated, FAILS" 1 "haven-core/src/extra.rs" \
'fn shared() -> Result<SqliteSharedStorage> {
    SqliteSharedStorage::in_memory().map_err(e)
}'
  _case "an open passed as a function value, ungated, FAILS" 1 "haven-core/src/extra.rs" \
'fn all(paths: &[PathBuf]) -> Vec<rusqlite::Result<Connection>> {
    paths.iter().map(Connection::open).collect()
}'
  _case "an open bound to a name, ungated, FAILS" 1 "haven-core/src/extra.rs" \
'fn later(path: &Path) -> rusqlite::Result<Connection> {
    let open = Connection::open;
    open(path)
}'
  _case "a static after a gated function does not inherit its gate" 1 "haven-core/src/tiles/storage.rs" \
'fn open_keyed_connection(path: &Path) -> Result<Connection> {
    crate::sqlcipher_init::ensure()?;
    let conn = Connection::open(path)?;
}

static DB: LazyLock<Connection> = LazyLock::new(|| Connection::open_in_memory().unwrap());'
  _case "a gate call inside a block comment does not stand in for the call" 1 "haven-core/src/tiles/storage.rs" \
'fn open_keyed_connection(path: &Path) -> Result<Connection> {
    /* crate::sqlcipher_init::ensure()?; */
    let conn = Connection::open(path)?;
}'
  _case "a gate call inside a block comment that spans lines does not either" 1 "haven-core/src/tiles/storage.rs" \
'fn open_keyed_connection(path: &Path) -> Result<Connection> {
    /* not yet: /* block comments nest */
    crate::sqlcipher_init::ensure()?;
    */
    let conn = Connection::open(path)?;
}'
  _case "an open inside a block comment is not an open" 0 "haven-core/src/extra.rs" \
'fn fixture() {
    /* let conn = Connection::open(path)?;
       SqliteAccountStorage::in_memory(); */
    let n = 1; /* AccountDeviceSession::open(config) */
}'
  _case "another type whose name ends in Connection is not SQLite" 0 "haven-core/src/extra.rs" \
'fn dial(addr: &str) -> Result<RelayConnection> {
    let pool = QuicConnection::open_bi(addr)?;
    RelayConnection::open(addr)
}'
  _case "a const inside a gated function does not end its gate" 0 "haven-core/src/tiles/storage.rs" \
'fn open_keyed_connection(path: &Path) -> Result<Connection> {
    crate::sqlcipher_init::ensure()?;
    const BUSY_MS: u32 = 2000;
    static ONCE: Once = Once::new();
    let conn = Connection::open(path)?;
}'
  _case "an open outside any function is never gated, whatever precedes it" 1 "haven-core/src/extra.rs" \
'static A: LazyLock<Connection> = LazyLock::new(|| {
    crate::sqlcipher_init::ensure().unwrap();
    Connection::open_in_memory().unwrap()
});'
  _case "a nested function does not inherit the outer one's gate" 1 "haven-core/src/extra.rs" \
'fn outer(path: &Path) -> rusqlite::Result<Connection> {
    crate::sqlcipher_init::ensure()?;
    fn inner(path: &Path) -> rusqlite::Result<Connection> {
        Connection::open(path)
    }
    inner(path)
}'
  _case "an open outside any function is not gated after a declaration without a body either" 1 "haven-core/src/extra.rs" \
'trait Store {
    fn load(&self) -> Result<Row>;
}

static A: LazyLock<Connection> = LazyLock::new(|| {
    crate::sqlcipher_init::ensure().unwrap();
    Connection::open_in_memory().unwrap()
});'
  _case "an open through a qualified path, ungated, FAILS" 1 "haven-core/src/extra.rs" \
'fn raw(path: &Path) -> rusqlite::Result<Connection> {
    <Connection>::open(path)
}'
  _case "an MDK store through a qualified path, ungated, FAILS" 1 "haven-core/src/extra.rs" \
'fn mem() -> Result<SqliteAccountStorage> {
    <storage_sqlite::SqliteAccountStorage>::in_memory().map_err(e)
}'
  _case "a session through a qualified path, ungated, FAILS" 1 "haven-core/src/extra.rs" \
'fn second_session(config: SessionConfig) -> Result<S> {
    <AccountDeviceSession>::open(config)
}'

  if (( fails )); then echo "self-test: FAILED" >&2; return 1; fi
  if (( checked != SELF_TEST_FIXTURES )); then
    echo "self-test: ran ${checked} fixture(s), expected exactly ${SELF_TEST_FIXTURES}." >&2
    return 1
  fi
  log "OK: self-test passed (${checked} fixtures)."
}

case "${1:-}" in
  --self-test) self_test ;;
  '') run_checks "${REPO_ROOT}" ;;
  *) echo "usage: $(basename "$0") [--self-test]" >&2; exit 2 ;;
esac
