#!/usr/bin/env bash
# CI guard: every native (Kotlin / Swift) log call is individually allowlisted,
# prints only a type name or an enum code, and is compiled out of — or gated
# out of — release (Security Rule 15, log anonymity).
#
# ## Why
#
# The Rust and Dart source guards never see `android.util.Log`, `NSLog` or
# `os_log`, and neither does the release `debugPrint` silencer: a Kotlin
# `Log.e(TAG, "...", t)` ships in every release APK, with the throwable's
# message and stack trace, and an `NSLog` outside `#if DEBUG` lands in the
# unified log for fourteen days. Native code is small enough to review one
# line at a time, so that is exactly what this guard forces: a call that is
# not on the list, or that interpolates anything but a type name / enum code,
# fails, and the list is checked against the tree in BOTH directions (a row
# that matches no call is stale, and fails too).
#
# ## What is checked
#
#   1. Every `Log.[vdiwe](`, `Timber.[vdiwe](`, `println(`, `print(`,
#      `System.out.print(ln)?(` in `haven/android/**/*.kt` and every `NSLog(`,
#      `os_log(`, `Logger(`, `print(`, `debugPrint(`, `dump(` in
#      `haven/ios/Runner/**/*.swift` has a row in
#      `scripts/ci/native_log_allowlist.txt`:
#          <repo-relative path>|<first line of the call, trimmed>|<why>|<owner>
#      Keying on the source line is deliberate: editing the call edits the key,
#      so the row has to be re-reviewed with it.
#   2. WRAPPERS count. Any `fun`/`func` whose body contains one of those calls
#      (today `debugLog(` in both iOS handlers) becomes a call pattern itself,
#      so its callers are scanned under the same rules — otherwise a
#      one-line wrapper is a bypass.
#   3. Every interpolation and every non-literal argument is a type name, an
#      enum code, a forwarded `message`/`msg`/`tag` that is a PARAMETER of the
#      enclosing function (a local `val message = url` is not), or an
#      all-caps constant the same file declares (`const val TAG`,
#      `static let TAG`). Kotlin `${x::class.java.simpleName}` /
#      `${x::class.simpleName}` / `${x.javaClass.simpleName}`; Swift
#      `\(type(of: x))` / `\(x.code)` / `x.code`. `\(error)`, `$url`,
#      `e.localizedDescription` and a trailing throwable all fail.
#   4. Raw calls are gated out of release: Swift inside `#if DEBUG`, Kotlin
#      inside `if (BuildConfig.DEBUG) { … }` (an `else` branch is neither).
#      Wrapper callers need not be — the wrapper's own call is what is gated.
#
# Exit codes:
#   0  every native log call is allowlisted and compliant
#   1  a violation (or a stale allowlist row) was found
#   2  expected paths missing / floor breached / self-test failed

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
readonly REPO_ROOT
readonly SCRIPT_NAME='check_native_log_allowlist'
readonly ALLOWLIST_REL='scripts/ci/native_log_allowlist.txt'

# The four raw calls in the tree today plus the two runtime-log-scanner plants
# (`HavenApplication.onCreate`, `AppDelegate`); wrapper callers come on top. A
# scanner that stopped recognising them would otherwise report "0 calls, all
# listed", and a deleted plant would read as tidiness instead of a lost
# positive control.
readonly MIN_NATIVE_SITES=6

log()  { printf '\033[1;34m[%s]\033[0m %s\n' "${SCRIPT_NAME}" "$*"; }
fail() { printf '\033[1;31m[%s] FAIL:\033[0m %s\n' "${SCRIPT_NAME}" "$*" >&2; }
misconfig() { printf '\033[1;31m[%s] BROKEN:\033[0m %s\n' "${SCRIPT_NAME}" "$*" >&2; exit 2; }

# ---------------------------------------------------------------------------
# One invocation per language over all its files. Prints one row per call:
#   SITE<US>file<US>line<US>raw|wrapper<US>indebug<US>first-line<US>problems
# ---------------------------------------------------------------------------
read -r -d '' SCAN_AWK <<'AWK' || true
BEGIN {
  US = "\037"
  if (lang == "kotlin") {
    RAWNAMES = "Log\\.[vdiwe]|Timber\\.[vdiwe]|System\\.out\\.println|System\\.out\\.print|println|print"
    INTERP_OK = "^[A-Za-z_][A-Za-z0-9_.]*(::class\\.java\\.simpleName|::class\\.simpleName|\\.javaClass\\.simpleName)$"
  } else {
    RAWNAMES = "NSLog|os_log|Logger|debugPrint|print|dump"
    INTERP_OK = "^type\\(of:[[:space:]]*[A-Za-z_][A-Za-z0-9_.]*\\)$|^[A-Za-z_][A-Za-z0-9_.]*\\.code$"
  }
  ARG_OK = "^[A-Za-z_][A-Za-z0-9_.]*\\.code$|^type\\(of:[[:space:]]*[A-Za-z_][A-Za-z0-9_.]*\\)$|^[A-Za-z_][A-Za-z0-9_.]*(::class\\.java\\.simpleName|::class\\.simpleName|\\.javaClass\\.simpleName)$"
  # A bare identifier passes only by CONTEXT: a forwarded message/tag that is
  # a parameter of the enclosing function, or an all-caps constant the file
  # declares. Both are resolved per call site, never by name alone.
  FWD = "^(message|msg|tag)$"
  CONSTNAME = "^[A-Z][A-Z0-9_]*$"
  RAWCALL = "(^|[^A-Za-z0-9_.])(" RAWNAMES ")[[:space:]]*\\("
  nf = 0
}

# Blanks strings, chars and comments one space per character so columns line
# up between the raw and the stripped text. String interpolation (`${…}` in
# Kotlin, `\(…)` in Swift) re-enters code mode with its own nesting depth.
function strip_line(s,   i, n, c, c2, c3, out, closes) {
  out = ""; n = length(s); i = 1
  while (i <= n) {
    c = substr(s, i, 1); c2 = substr(s, i, 2); c3 = substr(s, i, 3)
    if (mode == "bcomment") {
      if (c2 == "/*") { bdepth++; out = out "  "; i += 2; continue }
      if (c2 == "*/") { bdepth--; out = out "  "; i += 2; if (bdepth == 0) mode = "code"; continue }
      out = out " "; i++; continue
    }
    if (mode == "str") {
      closes = triple ? (c3 == "\"\"\"") : (c == "\"")
      if (closes) { out = out (triple ? "   " : " "); i += (triple ? 3 : 1); mode = "code"; continue }
      if (c == "\\") {
        if (lang == "swift" && c2 == "\\(") { lvl++; cd[lvl] = 0; ST[lvl] = triple; out = out "  "; i += 2; mode = "code"; continue }
        out = out "  "; i += 2; continue
      }
      if (lang == "kotlin" && c2 == "${") { lvl++; cd[lvl] = 0; ST[lvl] = triple; out = out "  "; i += 2; mode = "code"; continue }
      out = out " "; i++; continue
    }
    if (c2 == "//") { while (i <= n) { out = out " "; i++ }; break }
    if (c2 == "/*") { mode = "bcomment"; bdepth = 1; out = out "  "; i += 2; continue }
    if (c == "\"") { triple = (c3 == "\"\"\""); out = out (triple ? "   " : " "); i += (triple ? 3 : 1); mode = "str"; continue }
    if (lang == "kotlin" && c == "'" && (substr(s, i + 2, 1) == "'" || (c2 == "'\\" && substr(s, i + 3, 1) == "'"))) {
      closes = (substr(s, i + 2, 1) == "'") ? 3 : 4
      out = out substr("    ", 1, closes); i += closes; continue
    }
    if (lvl > 0) {
      if (lang == "swift") {
        if (c == "(") cd[lvl]++
        else if (c == ")") { if (cd[lvl] == 0) { triple = ST[lvl]; lvl--; mode = "str"; out = out " "; i++; continue }; cd[lvl]-- }
      } else {
        if (c == "{") cd[lvl]++
        else if (c == "}") { if (cd[lvl] == 0) { triple = ST[lvl]; lvl--; mode = "str"; out = out " "; i++; continue }; cd[lvl]-- }
      }
    }
    out = out c; i++
  }
  if (mode == "str" && !triple) mode = "code"
  return out
}

function skip_balanced(s,   i, n, c, depth, op, cl) {
  op = substr(s, 1, 1); cl = (op == "(") ? ")" : "}"
  n = length(s); depth = 0
  for (i = 1; i <= n; i++) {
    c = substr(s, i, 1)
    if (c == op) depth++
    else if (c == cl) { depth--; if (depth == 0) return i }
  }
  return n
}

function line_of(f, pos,   k) {
  for (k = 1; k <= NL[f]; k++) if (LS[f, k] > pos) return k - 1
  return NL[f]
}

function trim(s) { sub(/^[[:space:]]+/, "", s); sub(/[[:space:]]+$/, "", s); return s }

function in_debug(   k) { for (k = 1; k <= dd; k++) if (DS[k]) return 1; return 0 }

FNR == 1 {
  nf++; F[nf] = FILENAME; mode = "code"; lvl = 0; dd = 0
  TX[nf] = ""; RX[nf] = ""; NL[nf] = 0; CONSTS[nf] = " "
}
{
  raw = $0
  if (raw ~ /^[[:space:]]*#if[[:space:]]+DEBUG[[:space:]]*$/) { dd++; DS[dd] = 1 }
  else if (raw ~ /^[[:space:]]*#if([[:space:]]|$)/) { dd++; DS[dd] = 0 }
  else if (raw ~ /^[[:space:]]*#(else|elseif)([[:space:]]|$)/) { if (dd > 0) DS[dd] = 0 }
  else if (raw ~ /^[[:space:]]*#endif([[:space:]]|$)/) { if (dd > 0) dd-- }
  LS[nf, FNR] = length(TX[nf]) + 1
  RAWL[nf, FNR] = raw
  DBG[nf, FNR] = in_debug()
  code = strip_line(raw)
  # All-caps constants this file declares: the only bare identifiers that may
  # be logged without being a parameter (`Log.e(TAG, …)`).
  if (match(code, /(^|[^A-Za-z0-9_])(const[[:space:]]+val|static[[:space:]]+let|let)[[:space:]]+[A-Z][A-Z0-9_]*[[:space:]]*(:[^=]*)?=/)) {
    cname = substr(code, RSTART, RLENGTH)
    sub(/[[:space:]]*(:[^=]*)?=$/, "", cname); sub(/^.*[[:space:]]/, "", cname)
    CONSTS[nf] = CONSTS[nf] cname " "
  }
  TX[nf] = TX[nf] code "\n"
  RX[nf] = RX[nf] raw "\n"
  NL[nf] = FNR
}

# Parameter NAMES of a signature: `t: Throwable`, `_ message: String`,
# `vararg xs: Int`, `label name: T = 1` -> t message xs name.
function params_of(text,   n, i, c, depth, piece, out, name) {
  out = " "; depth = 0; piece = ""; n = length(text)
  for (i = 1; i <= n + 1; i++) {
    c = (i <= n) ? substr(text, i, 1) : ","
    if (c ~ /[({[]/) depth++
    else if (c ~ /[]})]/) depth--
    if (c == "," && depth == 0) {
      sub(/=.*$/, "", piece)
      sub(/:.*$/, "", piece)
      gsub(/@[A-Za-z_][A-Za-z0-9_.]*(\([^)]*\))?/, "", piece)
      name = trim(piece); sub(/^.*[[:space:]]/, "", name)
      if (name ~ /^[A-Za-z_][A-Za-z0-9_]*$/) out = out name " "
      piece = ""
    } else piece = piece c
  }
  return out
}

# Every function: its parameters and body span (for the call-site context),
# and whether it is a WRAPPER — a body containing a raw call, whose callers
# are then scanned exactly like the raw call would be.
function index_functions(   f, rest, pos, rs, rl, name, sp, plen, after, bstart, blen, body, q) {
  WRAPPERS = ""
  for (f = 1; f <= nf; f++) {
    rest = TX[f]; pos = 1; FNN[f] = 0
    while (match(rest, /(^|[^A-Za-z0-9_])(fun|func)[[:space:]]+[A-Za-z_][A-Za-z0-9_]*[[:space:]]*\(/)) {
      rs = RSTART; rl = RLENGTH
      name = substr(rest, rs, rl); sub(/^.*(fun|func)[[:space:]]+/, "", name); sub(/[[:space:]]*\($/, "", name)
      sp = rs + rl - 1
      plen = skip_balanced(substr(rest, sp))
      after = substr(rest, sp + plen)
      # Return type / throws, then either a block body or a `=` expression body.
      body = ""; bstart = 0; blen = 0
      if (match(after, /^[^{=\n]*\{/)) {
        bstart = sp + plen + RLENGTH - 1
        blen = skip_balanced(substr(rest, bstart))
        body = substr(rest, bstart, blen)
      } else if (match(after, /^[^{\n]*=/)) {
        bstart = sp + plen + RLENGTH
        body = substr(rest, bstart); q = index(body, "\n"); if (q) body = substr(body, 1, q)
        blen = length(body)
      }
      if (blen > 0) {
        FNN[f]++
        FBS[f, FNN[f]] = pos + bstart - 1
        FBE[f, FNN[f]] = pos + bstart + blen - 2
        FP[f, FNN[f]] = params_of(substr(rest, sp + 1, plen - 2))
      }
      if (body ~ RAWCALL) WRAPPERS = WRAPPERS (WRAPPERS == "" ? "" : "|") name
      pos += rs + rl - 1
      rest = substr(rest, rs + rl)
    }
  }
}

# Kotlin's release gate is a plain `if (BuildConfig.DEBUG) { … }` block:
# its brace span is DEBUG, the `else` after it is not.
function index_kotlin_debug(   f, rest, pos, rs, rl, bstart, blen) {
  for (f = 1; f <= nf; f++) {
    rest = TX[f]; pos = 1; KDN[f] = 0
    while (match(rest, /(^|[^A-Za-z0-9_])if[[:space:]]*\([[:space:]]*BuildConfig\.DEBUG[[:space:]]*\)[[:space:]]*\{/)) {
      rs = RSTART; rl = RLENGTH
      bstart = rs + rl - 1
      blen = skip_balanced(substr(rest, bstart))
      KDN[f]++
      KDS[f, KDN[f]] = pos + bstart - 1
      KDE[f, KDN[f]] = pos + bstart + blen - 2
      pos += bstart
      rest = substr(rest, bstart + 1)
    }
  }
}

function kotlin_debug(f, abs,   j) {
  for (j = 1; j <= KDN[f]; j++) if (KDS[f, j] <= abs && abs <= KDE[f, j]) return 1
  return 0
}

function set_context(f, abs,   j, best) {
  CUR_PARAMS = " "; best = 0
  for (j = 1; j <= FNN[f]; j++)
    if (FBS[f, j] <= abs && abs <= FBE[f, j] && FBS[f, j] > best) { best = FBS[f, j]; CUR_PARAMS = FP[f, j] }
  CUR_CONSTS = CONSTS[f]
}

function allowed_ident(x) {
  if (x ~ FWD && index(CUR_PARAMS, " " x " ")) return 1
  if (x ~ CONSTNAME && index(CUR_CONSTS, " " x " ")) return 1
  return 0
}

# Every `${…}` / `$ident` (Kotlin) or `\(…)` (Swift) in the RAW invocation.
function bad_interpolations(rawtext,   rest, rs, rl, inner, out, q) {
  out = ""; rest = rawtext
  if (lang == "kotlin") {
    while (match(rest, /\$(\{|[A-Za-z_][A-Za-z0-9_]*)/)) {
      rs = RSTART; rl = RLENGTH
      if (substr(rest, rs + 1, 1) == "{") {
        q = skip_balanced(substr(rest, rs + 1))
        inner = trim(substr(rest, rs + 2, q - 2))
        rest = substr(rest, rs + 1 + q)
      } else {
        inner = substr(rest, rs + 1, rl - 1)
        rest = substr(rest, rs + rl)
      }
      if (inner !~ INTERP_OK && !allowed_ident(inner)) out = out (out == "" ? "" : ", ") "${" inner "}"
    }
  } else {
    while (match(rest, /\\\(/)) {
      rs = RSTART
      q = skip_balanced(substr(rest, rs + 1))
      inner = trim(substr(rest, rs + 2, q - 2))
      rest = substr(rest, rs + 1 + q)
      if (inner !~ INTERP_OK && !allowed_ident(inner)) out = out (out == "" ? "" : ", ") "\\(" inner ")"
    }
  }
  return out
}

# Non-literal arguments of the STRIPPED invocation (literals are blank).
function bad_args(codetext,   inner, i, n, c, depth, arg, out) {
  inner = substr(codetext, index(codetext, "(") + 1)
  inner = substr(inner, 1, length(inner) - 1)
  out = ""; depth = 0; arg = ""; n = length(inner)
  for (i = 1; i <= n + 1; i++) {
    c = (i <= n) ? substr(inner, i, 1) : ","
    if (c ~ /[({[]/) depth++
    else if (c ~ /[]})]/) depth--
    if (c == "," && depth == 0) {
      arg = trim(arg)
      # A Swift argument LABEL is not the thing being logged: `log: X` is
      # judged on X, by exactly the rules a bare X is judged by. Stripping it
      # can admit nothing an unlabelled argument would not be admitted for,
      # and Haven's iOS logs need it because `os_log`'s destination arrives as
      # `log: <declared all-caps constant>` (see native_log_allowlist.txt).
      # Only a leading `<identifier>:` comes off, so `a ? b : c` keeps its own.
      if (arg ~ /^[A-Za-z_][A-Za-z0-9_]*:[[:space:]]/) sub(/^[A-Za-z_][A-Za-z0-9_]*:[[:space:]]+/, "", arg)
      if (arg != "" && arg !~ ARG_OK && !allowed_ident(arg)) out = out (out == "" ? "" : ", ") arg
      arg = ""
    } else arg = arg c
  }
  return out
}

END {
  index_functions()
  if (lang == "kotlin") index_kotlin_debug()
  CALL = "(^|[^A-Za-z0-9_.])(" RAWNAMES (WRAPPERS == "" ? "" : "|" WRAPPERS) ")[[:space:]]*\\("
  for (f = 1; f <= nf; f++) {
    rest = TX[f]; base = 0
    while (match(rest, CALL)) {
      rs = RSTART; rl = RLENGTH
      # The match's first character is the boundary unless the name itself
      # opens the text.
      nstart = rs + (substr(rest, rs, 1) ~ /[A-Za-z0-9_.]/ ? 0 : 1)
      name = substr(rest, nstart, rs + rl - 1 - nstart); sub(/[[:space:]]*\($/, "", name)
      before = substr(rest, 1, nstart - 1)
      isdef = (before ~ /(^|[^A-Za-z0-9_])(fun|func)[[:space:]]+$/)
      pend = rs + rl - 1
      pend = pend + skip_balanced(substr(rest, pend)) - 1
      if (!isdef) {
        abs = base + nstart
        line = line_of(f, abs)
        codetext = substr(rest, nstart, pend - nstart + 1)
        rawtext = substr(RX[f], abs, pend - nstart + 1)
        kind = (name ~ ("^(" RAWNAMES ")$")) ? "raw" : "wrapper"
        indebug = (lang == "kotlin") ? kotlin_debug(f, abs) : DBG[f, line]
        set_context(f, abs)
        problems = ""
        p = bad_interpolations(rawtext)
        if (p != "") problems = "interpolates " p
        p = bad_args(codetext)
        if (p != "") problems = problems (problems == "" ? "" : "; ") "non-literal argument(s) " p
        printf "SITE%s%s%s%d%s%s%s%d%s%s%s%s\n", US, F[f], US, line, US, kind, US, indebug, US, trim(RAWL[f, line]), US, problems
      }
      base = base + pend
      rest = substr(rest, pend + 1)
    }
  }
  printf "#wrappers %s\n", WRAPPERS
}
AWK
readonly SCAN_AWK

# check_tree <root> <allowlist-file> <min-sites>
check_tree() {
  local root="$1" allow="$2" min="$3"
  local -a kt swift
  mapfile -t kt < <(find "${root}/haven/android" -name '*.kt' -not -path '*/build/*' 2>/dev/null | sort)
  mapfile -t swift < <(find "${root}/haven/ios/Runner" -name '*.swift' 2>/dev/null | sort)
  (( ${#kt[@]} > 0 ))    || { fail "no Kotlin sources under haven/android — nothing scanned, nothing proven."; return 2; }
  (( ${#swift[@]} > 0 )) || { fail "no Swift sources under haven/ios/Runner — nothing scanned, nothing proven."; return 2; }
  [[ -f "${allow}" ]]    || { fail "allowlist not found: ${allow}"; return 2; }

  local rows
  rows="$(awk -v lang=kotlin "${SCAN_AWK}" "${kt[@]}"; awk -v lang=swift "${SCAN_AWK}" "${swift[@]}")"

  local -A why owner used
  local lineno=0 path key j o
  while IFS='|' read -r path key j o; do
    lineno=$(( lineno + 1 ))
    [[ -z "${path}" || "${path}" == \#* ]] && continue
    if [[ -z "${key}" || -z "${o}" ]]; then
      fail "${ALLOWLIST_REL}:${lineno}: malformed row — expected <path>|<call line>|<why>|<owner>"
      return 1
    fi
    why["${path}|${key}"]="${j}"
    owner["${path}|${key}"]="${o}"
  done < "${allow}"

  local sites=0 rc=0 file line kind indebug first problems rel k
  while IFS=$'\037' read -r _ file line kind indebug first problems; do
    [[ -n "${file}" ]] || continue
    sites=$(( sites + 1 ))
    rel="${file#"${root}/"}"
    k="${rel}|${first}"
    if [[ -z "${why[${k}]+x}" ]]; then
      fail "${rel}:${line}: ${kind} log call is not allowlisted: ${first}"
      rc=1
    else
      used["${k}"]=1
      if [[ -z "${why[${k}]}" ]]; then
        fail "${rel}:${line}: allowlist row has no justification: ${first}"
        rc=1
      fi
    fi
    if [[ -n "${problems}" ]]; then
      fail "${rel}:${line}: ${problems} — only a type name, an enum code, a forwarded message/tag PARAMETER or a declared all-caps constant may be logged"
      rc=1
    fi
    if [[ "${kind}" == raw && "${indebug}" != 1 ]]; then
      case "${rel}" in
        *.swift) fail "${rel}:${line}: Swift log call is not inside #if DEBUG" ;;
        *)       fail "${rel}:${line}: Kotlin log call is not inside if (BuildConfig.DEBUG) { … }" ;;
      esac
      rc=1
    fi
  done < <(grep '^SITE' <<<"${rows}" || true)

  for k in "${!why[@]}"; do
    if [[ -z "${used[${k}]+x}" ]]; then
      fail "${ALLOWLIST_REL}: stale row matches no call in the tree: ${k%%|*} | ${k#*|}"
      rc=1
    fi
  done

  if (( sites < min )); then
    fail "found ${sites} native log call(s), expected >= ${min} — the scanner has stopped matching."
    return 2
  fi
  (( rc == 0 )) && log "OK: ${sites} native log call(s) (${#kt[@]} Kotlin, ${#swift[@]} Swift file(s)), every one allowlisted, type-only and DEBUG-gated."
  return "${rc}"
}

# ---------------------------------------------------------------------------
# Self-test — hermetic fixture trees.
# ---------------------------------------------------------------------------
readonly DECLARED_CASES=27

self_test() {
  local tmp fails=0 checked=0
  tmp="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf '${tmp}'" RETURN

  local KT_OK='class App {
    fun onCreate() {
        try {
            init()
        } catch (t: Throwable) {
            if (BuildConfig.DEBUG) {
                Log.e(TAG, "init failed: ${t::class.java.simpleName}")
            }
        }
    }

    companion object {
        private const val TAG = "App"
    }
}
'
  local SW_OK='class Handler {
  func fire(error: Error) {
    debugLog("fire failed: \(type(of: error))")
  }

  private func debugLog(_ message: String) {
    #if DEBUG
    NSLog("[Handler] %@", message)
    #endif
  }
}
'
  local ROW_KT='haven/android/app/src/main/kotlin/A.kt|Log.e(TAG, "init failed: ${t::class.java.simpleName}")|class name only|team'
  local ROW_SW_RAW='haven/ios/Runner/B.swift|NSLog("[Handler] %@", message)|wrapper body, DEBUG only|team'
  local ROW_SW_CALL='haven/ios/Runner/B.swift|debugLog("fire failed: \(type(of: error))")|type name only|team'
  local ALLOW_OK="${ROW_KT}"$'\n'"${ROW_SW_RAW}"$'\n'"${ROW_SW_CALL}"$'\n'

  # _case <label> <want-rc> <min-sites> <allowlist> <kt|-> <swift>
  _case() {
    local label="$1" want="$2" min="$3" allow="$4" ktc="$5" swc="$6" got=0 root
    checked=$(( checked + 1 ))
    root="${tmp}/case${checked}"
    mkdir -p "${root}/haven/android/app/src/main/kotlin" "${root}/haven/ios/Runner"
    [[ "${ktc}" == "-" ]] || printf '%s' "${ktc}" > "${root}/haven/android/app/src/main/kotlin/A.kt"
    printf '%s' "${swc}" > "${root}/haven/ios/Runner/B.swift"
    printf '%s' "${allow}" > "${root}/allow.txt"
    ( check_tree "${root}" "${root}/allow.txt" "${min}" ) >/dev/null 2>&1 || got=$?
    if [[ "${got}" -eq "${want}" ]]; then
      printf '  \033[1;32mPASS\033[0m %s (rc=%d)\n' "${label}" "${got}"
    else
      printf '  \033[1;31mFAIL\033[0m %s (want rc=%d, got rc=%d)\n' "${label}" "${want}" "${got}" >&2
      ( check_tree "${root}" "${root}/allow.txt" "${min}" ) 2>&1 | sed 's/^/        /' >&2 || true
      fails=1
    fi
  }

  log "self-test: native log allowlist"

  _case "fully allowlisted, type-only, DEBUG-gated tree passes" 0 3 "${ALLOW_OK}" "${KT_OK}" "${SW_OK}"
  _case "an unlisted Log.d FAILS" 1 3 "${ALLOW_OK}" \
"${KT_OK}
fun other() { if (BuildConfig.DEBUG) { Log.d(\"T\", \"tick\") } }
" "${SW_OK}"
  _case "a row with an empty justification FAILS" 1 3 \
"${ROW_KT%%|class name only|team}||team"$'\n'"${ROW_SW_RAW}"$'\n'"${ROW_SW_CALL}"$'\n' "${KT_OK}" "${SW_OK}"
  _case "a stale row FAILS" 1 3 \
"${ALLOW_OK}haven/ios/Runner/B.swift|NSLog(\"gone\")|removed last year|team"$'\n' "${KT_OK}" "${SW_OK}"
  _case "Swift NSLog outside #if DEBUG FAILS" 1 3 "${ALLOW_OK}" "${KT_OK}" \
'class Handler {
  func fire(error: Error) {
    debugLog("fire failed: \(type(of: error))")
  }

  private func debugLog(_ message: String) {
    NSLog("[Handler] %@", message)
  }
}
'
  _case "NSLog in an #else branch FAILS" 1 3 "${ALLOW_OK}" "${KT_OK}" \
'class Handler {
  func fire(error: Error) {
    debugLog("fire failed: \(type(of: error))")
  }

  private func debugLog(_ message: String) {
    #if DEBUG
    let _ = message
    #else
    NSLog("[Handler] %@", message)
    #endif
  }
}
'
  _case "NSLog inside DEBUG interpolating a URL FAILS" 1 3 \
"${ALLOW_OK}haven/ios/Runner/B.swift|NSLog(\"relay \\(url) closed\")|listed but leaks|team"$'\n' "${KT_OK}" \
"${SW_OK}
extension Handler {
  func closed(url: String) {
    #if DEBUG
    NSLog(\"relay \\(url) closed\")
    #endif
  }
}
"
  _case "Kotlin \${t::class.java.simpleName} passes" 0 3 "${ALLOW_OK}" "${KT_OK}" "${SW_OK}"
  _case "Kotlin \$url FAILS even when listed" 1 3 \
"${ALLOW_OK}haven/android/app/src/main/kotlin/A.kt|Log.w(TAG, \"relay \$url down\")|listed but leaks|team"$'\n' \
"${KT_OK}
fun down(url: String) { if (BuildConfig.DEBUG) { Log.w(\"T\", \"relay \$url down\") } }
" "${SW_OK}"
  # The bypass this guard exists to close: the raw NSLog is clean and
  # DEBUG-gated, the leak is at the wrapper's call site.
  _case "a wrapper caller passing \\(relayUrl) FAILS" 1 3 \
"${ALLOW_OK}haven/ios/Runner/B.swift|debugLog(\"closed \\(relayUrl)\")|listed but leaks|team"$'\n' "${KT_OK}" \
"${SW_OK}
extension Handler {
  func closed(relayUrl: String) {
    debugLog(\"closed \\(relayUrl)\")
  }
}
"
  _case "a wrapper caller passing \\(type(of: e)) passes" 0 3 \
"${ALLOW_OK}haven/ios/Runner/B.swift|debugLog(\"closed: \\(type(of: e))\")|type name only|team"$'\n' "${KT_OK}" \
"${SW_OK}
extension Handler {
  func closed(e: Error) {
    debugLog(\"closed: \\(type(of: e))\")
  }
}
"
  _case "an unlisted wrapper caller FAILS" 1 3 "${ALLOW_OK}" "${KT_OK}" \
"${SW_OK}
extension Handler {
  func tick() { debugLog(\"tick\") }
}
"
  _case "an unlisted os_log FAILS" 1 3 "${ALLOW_OK}" "${KT_OK}" \
"${SW_OK}
extension Handler {
  func tick() {
    #if DEBUG
    os_log(\"tick\")
    #endif
  }
}
"
  _case "Swift print( outside DEBUG FAILS even when listed" 1 3 \
"${ALLOW_OK}haven/ios/Runner/B.swift|print(\"tick\")|listed but ships|team"$'\n' "${KT_OK}" \
"${SW_OK}
extension Handler {
  func tick() { print(\"tick\") }
}
"
  _case "a commented-out NSLog is not a call" 0 3 "${ALLOW_OK}" "${KT_OK}" \
"${SW_OK}
// NSLog(\"old \\(url)\")
/* print(\"old \\(url)\") */
"
  _case "a .print( method on a receiver is not a log call" 0 3 "${ALLOW_OK}" \
"${KT_OK}
fun render(sink: Sink) { sink.print(secret) }
" "${SW_OK}"

  # Kotlin's release gate. android.util.Log is not stripped from release
  # builds, so an ungated call ships in every APK.
  _case "a Kotlin raw call outside if (BuildConfig.DEBUG) FAILS" 1 3 "${ALLOW_OK}" \
'class App {
    fun onCreate() {
        try {
            init()
        } catch (t: Throwable) {
            Log.e(TAG, "init failed: ${t::class.java.simpleName}")
        }
    }

    companion object {
        private const val TAG = "App"
    }
}
' "${SW_OK}"
  _case "a Kotlin raw call inside if (BuildConfig.DEBUG) passes" 0 3 \
"${ALLOW_OK}haven/android/app/src/main/kotlin/A.kt|Log.d(TAG, \"tick\")|constant marker|team"$'\n' \
"${KT_OK}
fun tick() {
    if (BuildConfig.DEBUG) {
        Log.d(TAG, \"tick\")
    }
}
" "${SW_OK}"
  _case "a Kotlin raw call in the else branch of if (BuildConfig.DEBUG) FAILS" 1 3 \
"${ALLOW_OK}haven/android/app/src/main/kotlin/A.kt|Log.d(TAG, \"tick\")|constant marker|team"$'\n' \
"${KT_OK}
fun tick() {
    if (BuildConfig.DEBUG) {
        val _ = 1
    } else {
        Log.d(TAG, \"tick\")
    }
}
" "${SW_OK}"

  # A forwarded `message` is a parameter or nothing: a local by that name is
  # exactly how a URL would be smuggled through a clean-looking wrapper.
  _case "message forwarded from a LOCAL (not a parameter) FAILS" 1 3 "${ALLOW_OK}" "${KT_OK}" \
'class Handler {
  func fire(error: Error) {
    debugLog("fire failed: \(type(of: error))")
  }

  private func debugLog(_ text: String) {
    let message = url
    #if DEBUG
    NSLog("[Handler] %@", message)
    #endif
  }
}
'
  _case "a forwarded message PARAMETER passes (Kotlin wrapper)" 0 3 \
"${ALLOW_OK}haven/android/app/src/main/kotlin/A.kt|Log.d(TAG, msg)|wrapper body forwarding its parameter|team"$'\n'"haven/android/app/src/main/kotlin/A.kt|dlog(\"tick\")|constant marker|team"$'\n' \
"${KT_OK}
fun dlog(msg: String) {
    if (BuildConfig.DEBUG) {
        Log.d(TAG, msg)
    }
}
fun tick() {
    dlog(\"tick\")
}
" "${SW_OK}"
  _case "TAG without a const declaration in the file FAILS" 1 3 "${ALLOW_OK}" \
'class App {
    fun onCreate() {
        try {
            init()
        } catch (t: Throwable) {
            if (BuildConfig.DEBUG) {
                Log.e(TAG, "init failed: ${t::class.java.simpleName}")
            }
        }
    }
}
' "${SW_OK}"

  # A LABELLED argument is judged on its value, by the same rules. Haven's iOS
  # logs need it (`os_log(…, log: HAVEN_SLC_LOG, message)`), and the label must
  # not become a way in: the same call with an unlisted local behind the label
  # still fails.
  local SW_OSLOG='let HAVEN_TEST_LOG = OSLog(subsystem: "haven_ios", category: "t")

class Handler {
  func fire(error: Error) {
    debugLog("fire failed: \(type(of: error))")
  }

  private func debugLog(_ message: String) {
    #if DEBUG
    os_log("%{public}@", log: HAVEN_TEST_LOG, message)
    #endif
  }
}
'
  local ROW_SW_OSLOG='haven/ios/Runner/B.swift|os_log("%{public}@", log: HAVEN_TEST_LOG, message)|wrapper body, DEBUG only, declared constant destination|team'
  _case "a labelled os_log destination that is a declared constant passes" 0 3 \
"${ROW_KT}
${ROW_SW_OSLOG}
${ROW_SW_CALL}
" "${KT_OK}" "${SW_OSLOG}"
  _case "a label does not launder an undeclared identifier" 1 3 \
"${ROW_KT}
haven/ios/Runner/B.swift|os_log(\"%{public}@\", log: someLocalLog, message)|wrapper body, DEBUG only|team
${ROW_SW_CALL}
" "${KT_OK}" "$(printf '%s' "${SW_OSLOG}" | sed 's/log: HAVEN_TEST_LOG/log: someLocalLog/')"
  _case "a labelled os_log outside #if DEBUG FAILS" 1 3 \
"${ROW_KT}
${ROW_SW_OSLOG}
${ROW_SW_CALL}
" "${KT_OK}" "$(printf '%s' "${SW_OSLOG}" | sed '/#if DEBUG/d; /#endif/d')"
  _case "no Kotlin sources is BROKEN" 2 3 "${ALLOW_OK}" "-" "${SW_OK}"
  _case "fewer calls than the floor is BROKEN" 2 9 "${ALLOW_OK}" "${KT_OK}" "${SW_OK}"

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

  [[ -d "${REPO_ROOT}/haven/android" ]]    || misconfig "${REPO_ROOT}/haven/android not found"
  [[ -d "${REPO_ROOT}/haven/ios/Runner" ]] || misconfig "${REPO_ROOT}/haven/ios/Runner not found"
  [[ -f "${REPO_ROOT}/${ALLOWLIST_REL}" ]] || misconfig "${ALLOWLIST_REL} not found"

  local rc=0
  check_tree "${REPO_ROOT}" "${REPO_ROOT}/${ALLOWLIST_REL}" "${MIN_NATIVE_SITES}" || rc=$?
  exit "${rc}"
}

main "$@"
