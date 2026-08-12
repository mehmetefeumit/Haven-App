#!/usr/bin/env bash
# CI guard: no key material may be INTERPOLATED into a log or print call
# (Security Rule 6, "NEVER log, print, or expose key material").
#
# ## Why a source guard, when a runtime scanner already exists
#
# `tooling/e2e/ci/scan-logs-for-secrets.sh` greps CAPTURED device logs for seven
# secret SHAPES (64-hex, nsec1…, base64 blobs, …). That is a strong last line,
# and it is the only line: it can only catch material that a lane happened to
# execute, in a build whose level cap let the record through, in a shape the
# seven patterns anticipate. A `Zeroizing<[u8; 32]>` rendered as
# `[171, 205, ...]` by a `{:?}` is none of those things, and a code path that
# only runs on a real device is not covered at all.
#
# This guard reads the SOURCE, so it covers every path, every build profile and
# every encoding — but only for the one question a static reader can answer:
# does a value that LOOKS like key material get interpolated into a log call.
#
# ## What is analysed, and what deliberately is not
#
# For each log/print invocation (multi-line, balanced parens) two texts are
# collected and NOTHING else:
#
#   * the contents of each `{…}` / `${…}` / `$ident` placeholder, and
#   * the argument expressions, with string literals removed.
#
# The message PROSE is therefore never analysed. That is the whole reason the
# check can be aggressive about the word "key" without drowning: a line reading
# `log::warn!("MLS session DB key migration deferred: {e}")` contributes the
# single token `e`, not the word "key". String state is carried ACROSS lines,
# because a Rust/Dart literal may span newlines and a per-line reset reads the
# continuation as code — which is exactly how prose leaks into the analysed
# text and produces the false positives that get a guard deleted.
#
# The collected text is then tokenised into identifiers and each token is
# classified, so `wire_token()` is not "a token" and `pubkey` is not "a key".
#
# Not covered, deliberately: generated bindings (`frb_generated.rs` — machine
# output, and it logs nothing), test trees (not shipped; the runtime scanner
# covers what a lane prints), and interpolation of a value whose NAME says
# nothing (`canonical`, `buf`). A name-shaped check cannot see the last one,
# and pretending otherwise by banning `{:?}` outright would ban the safe
# redacting `Debug` impls this codebase writes on purpose.
#
# ## Suppressing a reviewed site
#
#   log::debug!("signer ready {:?}", signer);  // log-scan-ok: Debug redacts
#
# The marker must sit on one of the invocation's OWN lines or on the line
# immediately above it, and must carry a reason. It cannot be hoisted to the
# top of a file to bless everything below — a file-wide opt-out is how this
# class of guard stops being read.
#
# ## Checks
#
#   1. Rust: no `log::{trace,debug,info,warn,error}!`, `print*!`, `dbg!` in
#      haven-core/src or haven/rust_builder/src interpolates a secret-shaped
#      expression.
#   2. Dart: no `debugPrint(`/`print(` in haven/lib does.
#   3. The `keyring_core` → Off log filter is installed for EVERY logger
#      backend `init_app` installs, on every platform. keyring-core logs
#      `created entry {:?}` / `get secret from entry {:?}` at DEBUG and the
#      credential `Debug` is the STORE's to define, so this is a dependency
#      whose disclosure Haven cannot fix at the call site — only by dropping
#      its target. Filtering it on Android alone (which is what the tree did)
#      keys a confidentiality property to one target while FRB installs an
#      unfiltered `oslog` backend on the other shipped one. The install ORDER is
#      checked with it: both backends are first-call-wins, so a filtered one
#      installed after `setup_default_user_utils()` loses to FRB's unfiltered
#      pair and silently no-ops.
#
# Each check carries an anti-vacuity floor: an extractor that has stopped
# matching would otherwise report "0 interpolations, none secret" forever.
#
# Exit codes:
#   0  all checks pass
#   1  a violation was found
#   2  expected paths missing / self-test failed (the guard itself is broken)

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
readonly REPO_ROOT
readonly SCRIPT_NAME='check_no_key_logging'

# Anti-vacuity floors, set ~20% below the counts measured when this landed
# (Rust 92, Dart 479). They are not ratchets — deleting log calls is fine — but
# a parser that has stopped recognising invocations collapses well past them.
readonly MIN_RUST_SITES=70
readonly MIN_DART_SITES=380
# `init_app` installs one backend per shipped platform family (Android, Apple).
readonly MIN_LOG_BACKENDS=2

log()  { printf '\033[1;34m[%s]\033[0m %s\n' "${SCRIPT_NAME}" "$*"; }
fail() { printf '\033[1;31m[%s] FAIL:\033[0m %s\n' "${SCRIPT_NAME}" "$*" >&2; }
misconfig() { printf '\033[1;31m[%s] BROKEN:\033[0m %s\n' "${SCRIPT_NAME}" "$*" >&2; exit 2; }

# ---------------------------------------------------------------------------
# The scanner. One program for both languages; `lang` selects the string
# delimiters and the interpolation syntax. Prints one line per violation and,
# last, `#sites <n>` so the caller can enforce the anti-vacuity floor.
# ---------------------------------------------------------------------------
read -r -d '' SCAN_AWK <<'AWK' || true
BEGIN {
  # A token is classified only if it is a WHOLE identifier, so `wire_token` is
  # not "a token" and `monkey` is not "a key".
  PUBLIC = "^(pubkey|.*_pubkey|public_key|npub|key_id|key_slot|.*key_package.*|keyring.*|keystore.*)$"
  SECRET = "(secret|privkey|priv_key|private_key|seckey|nsec|passphrase|password|seed|psk|entropy|exporter|salt|keypair|api_key|apikey|auth_token|access_token|bearer|credential|plaintext)"
  # `key`, `keys`, `db_key`, `key_bytes`, `group_event_key` — but not `keyring`,
  # which PUBLIC has already excluded.
  KEYLIKE = "^([a-z0-9_]*_)?keys?(_[a-z0-9_]*)?$"
  MARKER  = "log-scan-ok:[ \t]*[^ \t]"
  if (lang == "rust")
    CALL = "(log::(trace|debug|info|warn|error)|println|eprintln|print|eprint|dbg)![ \t]*\\("
  else
    CALL = "(^|[^A-Za-z0-9_.])(debugPrint|print)[ \t]*\\("
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
    if (c == "/" && substr(s, i + 1, 1) == "/") { COMMENT = substr(s, i); break }
    CODE = CODE c
  }
}

# Placeholder contents only — never the prose around them.
function placeholders(s,   out, rest, p) {
  out = ""; rest = s
  if (lang == "rust") {
    while (match(rest, /\{[^{}]*\}/)) {
      p = substr(rest, RSTART + 1, RLENGTH - 2)
      sub(/:.*$/, "", p)          # `{n:>8}` / `{e:?}` -> `n` / `e`
      out = out " " p
      rest = substr(rest, RSTART + RLENGTH)
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

# `mlsDbKey` and `mls_db_key` are the same identifier wearing each language's
# casing. Splitting on the case boundary lets ONE token vocabulary serve both;
# without it the anchored `KEYLIKE` never matches a Dart name.
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

# An accessor decides what an expression EVALUATES to. `dueKeys.length` is a
# count; a name-shaped check that ignores the tail flags every count taken over
# a secret-shaped collection, which is most of them.
function drop_safe(s) {
  while (match(s, /[A-Za-z_][A-Za-z0-9_.]*\.(length|runtimeType|isEmpty|isNotEmpty|len\(\)|count\(\))/))
    s = substr(s, 1, RSTART - 1) " " substr(s, RSTART + RLENGTH)
  return s
}

function classify(text,   rest, tok, out) {
  out = ""; rest = decamel(drop_safe(text))
  while (match(rest, /[a-z_][a-z0-9_]*/)) {
    tok = substr(rest, RSTART, RLENGTH)
    rest = substr(rest, RSTART + RLENGTH)
    if (tok ~ PUBLIC) continue
    if (tok ~ SECRET || tok ~ KEYLIKE) out = out (out == "" ? "" : ", ") tok
  }
  return out
}

function emit(   bad) {
  sites++
  if (SUPP) return
  bad = classify(PH " " ARGS)
  if (bad != "") printf "%s:%d: interpolates %s | %s\n", FILENAME, START, bad, SRC
}

FNR == 1 { INMAC = 0; INQ = 0; ESC = 0; prev_supp = 0 }
{
  split_line($0)
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
      INMAC = 1; DEPTH = 1; PH = ""; ARGS = ""; TAIL = ""
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

# scan <lang> <min-sites> <label> <file...>
scan() {
  local lang="$1" min="$2" label="$3"; shift 3
  local out sites hits
  out="$(awk -v lang="${lang}" "${SCAN_AWK}" "$@")"
  sites="$(sed -n 's/^#sites //p' <<<"${out}")"
  hits="$(grep -v '^#sites ' <<<"${out}" || true)"

  if [[ -z "${sites}" ]] || (( sites < min )); then
    fail "${label}: found ${sites:-0} log/print invocations, expected >= ${min}."
    echo "  The extractor has stopped matching, so this scan proves nothing." >&2
    echo "  Fix the scanner (or lower the floor deliberately) — do not ignore it." >&2
    return 2
  fi
  if [[ -n "${hits}" ]]; then
    fail "${label}: a log/print call interpolates secret-shaped material (Security Rule 6)."
    printf '%s\n' "${hits}" | sed 's/^/    /' >&2
    echo "  Log the SHAPE, never the value (a count, a bool, a redacting Debug)." >&2
    echo "  If the value is provably safe, say so on the line:  // log-scan-ok: <why>" >&2
    return 1
  fi
  log "OK: ${label} — ${sites} log/print invocations, none interpolate key material."
  return 0
}

# ---------------------------------------------------------------------------
# Check 3: every logger backend installed by `init_app` drops `keyring_core`.
# ---------------------------------------------------------------------------
check_keyring_filter() { # <api.rs path>
  local api="$1" body stmts rc=0 backends=0 targets=''
  local idx=0 frb_idx=-1 last_backend_idx=-1

  body="$(awk '/^pub fn init_app\(\) \{/ { f = 1 } f { print } f && /^\}/ { exit }' "${api}")"
  if [[ -z "${body}" ]]; then
    fail "could not locate init_app() in ${api#"${REPO_ROOT}/"} — update this guard rather than deleting it."
    return 2
  fi

  # One statement per line, comments stripped: a `#[cfg(...)]` attribute and the
  # call it guards are ONE statement, so each install carries its own platform.
  stmts="$(printf '%s\n' "${body}" | sed 's|//.*||' | tr '\n' ' ' | tr ';' '\n')"

  while IFS= read -r stmt; do
    idx=$(( idx + 1 ))
    if [[ "${stmt}" == *setup_default_user_utils* ]]; then
      frb_idx="${idx}"
      continue
    fi
    [[ "${stmt}" == *[Ll]ogger* ]] || continue
    if ! grep -qE '(android_logger::init_once|oslog::OsLogger::new|log::set_boxed_logger|log::set_logger)' <<<"${stmt}"; then
      fail "init_app installs a logger backend this guard does not recognise:"
      printf '    %s\n' "${stmt}" >&2
      echo "  Teach the guard about it — an unknown backend is an unfiltered one." >&2
      rc=1
      continue
    fi
    backends=$(( backends + 1 ))
    last_backend_idx="${idx}"
    if ! grep -qF 'keyring_core' <<<"${stmt}"; then
      fail "a logger backend is installed without the keyring_core filter:"
      printf '    %s\n' "${stmt}" >&2
      echo "  keyring-core logs the credential's Debug at DEBUG; its target must be dropped." >&2
      rc=1
    fi
    while [[ "${stmt}" =~ target_os[[:space:]]*=[[:space:]]*\"([a-z]+)\" ]]; do
      targets+=" ${BASH_REMATCH[1]}"
      stmt="${stmt/${BASH_REMATCH[0]}/}"
    done
  done <<<"${stmts}"

  # The ORDER is the whole fix: both backends are first-call-wins, so ours only
  # preempts FRB's unfiltered pair while it is installed first. Every check
  # above still passes with the two blocks swapped, and keyring-core's DEBUG
  # records — raw SQLCipher DB-key bytes — would be back in the log.
  if (( frb_idx < 0 )); then
    fail "init_app no longer calls setup_default_user_utils()."
    echo "  That call is what our backends must preempt; without it in init_app," >&2
    echo "  this guard cannot see whether FRB installs an unfiltered backend first." >&2
    rc=1
  elif (( last_backend_idx > frb_idx )); then
    fail "a logger backend is installed AFTER setup_default_user_utils()."
    echo "  Both backends are first-call-wins, so FRB's UNFILTERED pair wins and the" >&2
    echo "  filtered one no-ops: install ours BEFORE the FRB call, never after." >&2
    rc=1
  fi

  if (( backends < MIN_LOG_BACKENDS )); then
    fail "init_app installs ${backends} logger backend(s), expected >= ${MIN_LOG_BACKENDS}."
    echo "  FRB installs an unfiltered backend on Android AND on iOS/macOS; ours must" >&2
    echo "  preempt every one of them, or the filter is keyed to a single target." >&2
    rc=1
  fi
  local plat
  for plat in android ios; do
    if [[ " ${targets} " != *" ${plat} "* ]]; then
      fail "no filtered logger backend is installed for target_os=\"${plat}\"."
      echo "  Security Rule 6 is not a per-platform property." >&2
      rc=1
    fi
  done

  (( rc == 0 )) && log "OK: ${backends} logger backend(s), each dropping the keyring_core target, all installed before setup_default_user_utils()."
  return "${rc}"
}

# ---------------------------------------------------------------------------
# Self-test — hermetic fixtures, no repo state.
#
# The fixtures that earn their keep are the ones proving the guard can still
# FAIL (a secret in a placeholder, a secret in an argument, a backend without
# the filter, an Android-only filter, a filtered backend installed too late to
# preempt FRB's) and the ones proving it does not cry
# wolf, because a log guard that flags counts and prose is a guard that gets
# switched off: the four false-positive shapes below are all real lines from
# this tree that earlier drafts of this scanner flagged.
# ---------------------------------------------------------------------------
self_test() {
  # `checked` is COUNTED, never asserted: a hardcoded banner drifts the moment a
  # fixture is added, and a stated count that is already wrong cannot catch the
  # deletion it exists to catch.
  local tmp fails=0 checked=0
  tmp="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf '${tmp}'" RETURN

  _case() { # _case <label> <lang> <expect-hit:0|1> <ext> <content>
    local label="$1" lang="$2" want="$3" ext="$4" content="$5" out got
    checked=$(( checked + 1 ))
    printf '%s' "${content}" > "${tmp}/f.${ext}"
    out="$(awk -v lang="${lang}" "${SCAN_AWK}" "${tmp}/f.${ext}")"
    got=$(grep -cv '^#sites ' <<<"${out}" || true)
    (( got > 0 )) && got=1
    if [[ "${got}" -eq "${want}" ]]; then
      printf '  \033[1;32mPASS\033[0m %s\n' "${label}"
    else
      printf '  \033[1;31mFAIL\033[0m %s (want hit=%d, got hit=%d)\n' "${label}" "${want}" "${got}" >&2
      printf '%s\n' "${out}" | sed 's/^/        /' >&2
      fails=1
    fi
  }

  log "self-test: Rust scanner"

  _case "inline capture of a secret FAILS" rust 1 rs \
'fn f() {
    log::debug!("derived {group_event_key}");
}
'
  _case "positional secret argument FAILS" rust 1 rs \
'fn f() {
    log::info!("stored {}", db_key_bytes);
}
'
  # The invocation this guard exists for is almost never one line.
  _case "secret on a CONTINUATION line FAILS" rust 1 rs \
'fn f() {
    log::warn!(
        "rotated for {} at {}",
        circle_id,
        self.exporter_secret,
    );
}
'
  _case "dbg! of a secret FAILS" rust 1 rs \
'fn f() {
    dbg!(&keypair);
}
'
  # THE false-positive that decides whether this guard survives contact with
  # the tree: `key` in the MESSAGE, only `e` interpolated.
  _case "the word key in PROSE passes" rust 0 rs \
'fn f() {
    log::warn!("MLS session DB key access-policy migration deferred: {e}");
}
'
  # A multi-line literal: with per-line string state the continuation is read as
  # code and every word in it becomes a token. Two real lines were flagged that
  # way before the state was made file-scoped.
  _case "prose in a MULTI-LINE literal passes" rust 0 rs \
'fn f() {
    log::warn!(
        "no relays configured; falling back to defaults \
         (the seed may not have run yet)"
    );
}
'
  _case "counts and enum names pass" rust 0 rs \
'fn f() {
    log::info!("backfilled {n} relay(s); action={:?}", action);
}
'
  _case "a public key is not key material" rust 0 rs \
'fn f() {
    log::debug!("republished key_package for {pubkey}");
}
'
  # `wire_token()` is a clock-skew policy string; an unanchored `token` match
  # flagged it, which is why classification is per-identifier.
  _case "a non-secret identifier containing a class word passes" rust 0 rs \
'fn f() {
    log::warn!("clock {}; retrying={}", complaint.wire_token(), hopeless);
}
'
  _case "suppression on the line ABOVE passes" rust 0 rs \
'fn f() {
    // log-scan-ok: Debug redacts the secret bytes
    log::debug!("signer {:?}", signing_key);
}
'
  _case "trailing suppression on the invocation passes" rust 0 rs \
'fn f() {
    log::debug!("signer {:?}", signing_key); // log-scan-ok: Debug redacts
}
'
  # The property that makes the marker reviewable rather than a mute button.
  _case "suppression with NO reason does not suppress" rust 1 rs \
'fn f() {
    // log-scan-ok:
    log::debug!("signer {:?}", signing_key);
}
'
  # A file-wide opt-out is the failure mode this design exists to prevent.
  _case "a distant suppression does NOT blanket the file" rust 1 rs \
'// log-scan-ok: this file is fine, honest
fn f() {
    log::info!("ok");
    log::debug!("signer {:?}", signing_key);
}
'
  # A commented-out call is not a call.
  _case "a log call inside a comment is not scanned" rust 0 rs \
'fn f() {
    // log::debug!("{}", secret_key);
    log::info!("ok");
}
'

  log "self-test: Dart scanner"

  _case "Dart \${} interpolation of a secret FAILS" dart 1 dart \
'void f() {
  debugPrint("loaded \${identity.secretBytes.length} of \$dbKey");
}
'
  _case "Dart bare \$secret interpolation FAILS" dart 1 dart \
"void f() {
  debugPrint('using \$mlsDbKey');
}
"
  _case "Dart runtimeType-only logging passes" dart 0 dart \
"void f() {
  debugPrint('tile fetch failed: \${e.runtimeType}');
}
"
  # A real line from background_location_task.dart. `dueKeys` are circle ids and
  # the interpolated value is their COUNT — the first false positive this guard
  # produced against the tree, and the shape most likely to recur.
  _case "a count over a secret-shaped collection passes" dart 0 dart \
"void f() {
  debugPrint('Published to \$publishCount/\${dueKeys.length} circle(s).');
}
"
  # ...but the accessor must not launder its own receiver's siblings.
  _case "a safe accessor does not bless the rest of the call" dart 1 dart \
"void f() {
  debugPrint('\${dueKeys.length} circles under \$mlsDbKey');
}
"
  # An apostrophe inside a double-quoted string used to flip the quote state and
  # swallow the rest of the file into a literal.
  _case "Dart apostrophe in prose does not desync the lexer" dart 0 dart \
'void f() {
  debugPrint("couldn'"'"'t reach the relay");
  debugPrint("count: ${n}");
}
'
  _case "Dart .print( on a receiver is not a print call" dart 0 dart \
"void f() {
  buffer.print(secretKey);
}
"

  log "self-test: anti-vacuity floor"
  local out sites
  checked=$(( checked + 1 ))
  printf 'fn f() { log::info!("ok"); }\n' > "${tmp}/one.rs"
  out="$(awk -v lang=rust "${SCAN_AWK}" "${tmp}/one.rs")"
  sites="$(sed -n 's/^#sites //p' <<<"${out}")"
  if [[ "${sites}" == "1" ]]; then
    printf '  \033[1;32mPASS\033[0m the scanner reports its invocation count\n'
  else
    printf '  \033[1;31mFAIL\033[0m expected #sites 1, got %s\n' "${sites:-<none>}" >&2
    fails=1
  fi
  # A file whose log macro was renamed must collapse the count to 0, which is
  # what the floor in `scan` turns into a red. Without this the guard would
  # report "no secrets" over a tree it could no longer parse.
  checked=$(( checked + 1 ))
  printf 'fn f() { tracing::info!("ok"); }\n' > "${tmp}/none.rs"
  out="$(awk -v lang=rust "${SCAN_AWK}" "${tmp}/none.rs")"
  if [[ "$(sed -n 's/^#sites //p' <<<"${out}")" == "0" ]]; then
    printf '  \033[1;32mPASS\033[0m an unrecognised macro collapses the count (floor reds)\n'
  else
    printf '  \033[1;31mFAIL\033[0m expected #sites 0 for an unrecognised macro\n' >&2
    fails=1
  fi

  log "self-test: keyring_core filter (check 3)"

  _kc_case() { # _kc_case <label> <expect-rc> <content>
    local label="$1" want="$2" content="$3" got=0
    checked=$(( checked + 1 ))
    printf '%s' "${content}" > "${tmp}/api.rs"
    ( check_keyring_filter "${tmp}/api.rs" ) >/dev/null 2>&1 || got=$?
    if [[ "${got}" -eq "${want}" ]]; then
      printf '  \033[1;32mPASS\033[0m %s (rc=%d)\n' "${label}" "${got}"
    else
      printf '  \033[1;31mFAIL\033[0m %s (want rc=%d, got rc=%d)\n' "${label}" "${want}" "${got}" >&2
      fails=1
    fi
  }

  _kc_case "both platforms filtered passes" 0 \
'pub fn init_app() {
    #[cfg(target_os = "android")]
    android_logger::init_once(
        android_logger::Config::default()
            .with_filter(
                android_logger::FilterBuilder::new()
                    .filter_module("keyring_core", log::LevelFilter::Off)
                    .build(),
            ),
    );
    #[cfg(any(target_os = "ios", target_os = "macos"))]
    let _ = oslog::OsLogger::new("frb_user")
        .category_level_filter("keyring_core", log::LevelFilter::Off)
        .init();
    flutter_rust_bridge::setup_default_user_utils();
}
'
  # THE regression this check exists for: the state the tree shipped in.
  _kc_case "Android-only filtering FAILS" 1 \
'pub fn init_app() {
    #[cfg(target_os = "android")]
    android_logger::init_once(
        android_logger::Config::default()
            .with_filter(
                android_logger::FilterBuilder::new()
                    .filter_module("keyring_core", log::LevelFilter::Off)
                    .build(),
            ),
    );
    flutter_rust_bridge::setup_default_user_utils();
}
'
  _kc_case "a backend installed WITHOUT the filter FAILS" 1 \
'pub fn init_app() {
    #[cfg(target_os = "android")]
    android_logger::init_once(android_logger::Config::default());
    #[cfg(any(target_os = "ios", target_os = "macos"))]
    let _ = oslog::OsLogger::new("frb_user")
        .category_level_filter("keyring_core", log::LevelFilter::Off)
        .init();
}
'
  # An unrecognised backend crate must red rather than slip past: the guard
  # cannot vouch for a filter it does not know how to read.
  _kc_case "an unrecognised logger backend FAILS" 1 \
'pub fn init_app() {
    #[cfg(target_os = "android")]
    android_logger::init_once(
        android_logger::Config::default()
            .with_filter(
                android_logger::FilterBuilder::new()
                    .filter_module("keyring_core", log::LevelFilter::Off)
                    .build(),
            ),
    );
    #[cfg(any(target_os = "ios", target_os = "macos"))]
    let _ = oslog::OsLogger::new("frb_user")
        .category_level_filter("keyring_core", log::LevelFilter::Off)
        .init();
    #[cfg(target_os = "linux")]
    let _ = simple_logger::SimpleLogger::new().init();
}
'
  # The mutation every other fixture here passes: both platforms, both filters,
  # and the whole fix undone by moving three lines.
  _kc_case "a backend installed AFTER the FRB call FAILS" 1 \
'pub fn init_app() {
    flutter_rust_bridge::setup_default_user_utils();
    #[cfg(target_os = "android")]
    android_logger::init_once(
        android_logger::Config::default()
            .with_filter(
                android_logger::FilterBuilder::new()
                    .filter_module("keyring_core", log::LevelFilter::Off)
                    .build(),
            ),
    );
    #[cfg(any(target_os = "ios", target_os = "macos"))]
    let _ = oslog::OsLogger::new("frb_user")
        .category_level_filter("keyring_core", log::LevelFilter::Off)
        .init();
}
'
  # Moving the FRB call out of init_app puts the ordering out of this guard's
  # sight, which is a red, not a pass.
  _kc_case "no FRB call to preempt FAILS" 1 \
'pub fn init_app() {
    #[cfg(target_os = "android")]
    android_logger::init_once(
        android_logger::Config::default()
            .with_filter(
                android_logger::FilterBuilder::new()
                    .filter_module("keyring_core", log::LevelFilter::Off)
                    .build(),
            ),
    );
    #[cfg(any(target_os = "ios", target_os = "macos"))]
    let _ = oslog::OsLogger::new("frb_user")
        .category_level_filter("keyring_core", log::LevelFilter::Off)
        .init();
    log::set_max_level(log::LevelFilter::Warn);
}
'
  # The anchor is the one thing a rename silently removes.
  _kc_case "a missing init_app is BROKEN, not clean" 2 \
'pub fn other() {
    let _ = 1;
}
'

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

  local core="${REPO_ROOT}/haven-core/src"
  local ffi="${REPO_ROOT}/haven/rust_builder/src"
  local dart="${REPO_ROOT}/haven/lib"
  local api="${ffi}/api.rs"
  [[ -d "${core}" ]] || misconfig "${core} not found"
  [[ -d "${ffi}"  ]] || misconfig "${ffi} not found"
  [[ -d "${dart}" ]] || misconfig "${dart} not found"
  [[ -f "${api}"  ]] || misconfig "${api} not found"

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

  rc=0; check_keyring_filter "${api}" || rc=$?
  (( rc == 2 )) && exit 2
  (( rc == 0 )) || status=1

  exit "${status}"
}

main "$@"
