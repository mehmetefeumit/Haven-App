#!/usr/bin/env bash
# CI guard: every Dart entry point installs the release `debugPrint` silencer
# FIRST, then the two anonymous error handlers (Security Rule 15 — log
# anonymity, in every build).
#
# ## Why
#
# `main()` replaces `debugPrint` with a no-op under `kReleaseMode`, so a log
# line that slipped past the source guards still cannot reach a release
# device's logcat / unified log. That defence has exactly one weakness: it is
# installed per ISOLATE, and a `@pragma('vm:entry-point')` function is by
# definition an isolate that never ran `main()` — the WorkManager dispatcher
# and the foreground-task callback each boot their own engine. One of them
# shipped without the silencer, and every `[BackgroundTask]` line it printed
# carried the user's circle count and a per-cycle timing oracle into release
# logcat. Position matters as much as presence: anything executed before the
# silencer (`WidgetsFlutterBinding.ensureInitialized()` included) logs into
# the unsilenced default.
#
# The framework's own error reporting is the second hole: an uncaught
# exception is dumped by `FlutterError.onError` / `PlatformDispatcher.onError`
# with its `toString()` — a `SocketException` names the relay host — and it
# bypasses `debugPrint` entirely. So every entry point also installs both
# handlers, right after the silencer, and each may render only the failure's
# TYPE (`.runtimeType`) and the framework library that raised it.
#
# ## What is checked
#
# For every `@pragma('vm:entry-point')`-annotated function under `haven/lib`
# (minus the generated `src/rust/`) and for the top-level `main(`, whitespace
# aside, statement 1 must be
#
#   if (kReleaseMode) { debugPrint = (String? m, {int? w}) {}; }
#
# and, in either order, before ANY other statement except the binding /
# plugin-registrant init (`WidgetsFlutterBinding.ensureInitialized()`,
# `DartPluginRegistrant.ensureInitialized()` — placing the handlers after those
# means a binding init cannot clobber them),
#
#   FlutterError.onError = (details) => debugPrint('… ${details.exception.runtimeType} … ${details.library}');
#   PlatformDispatcher.instance.onError = (error, stack) { debugPrint('… ${error.runtimeType}'); return true; };
#
# (the first with an arrow or a block body). Inside a handler's message only
# `<expr>.runtimeType` and `details.library` may be interpolated:
# `${details.exception}`, `$error`, `$stack`, `${error.toString()}` all fail.
# Comments before the statements are fine; anything else is not. A pragma on
# something that has no block body (a class, a getter, an `=>` function) is a
# violation, not a skip — the annotation says "runs without main()", and that
# is the whole threat. Strings and comments are lexed away before matching
# (URLs in comments contain `//`), and the handler messages are re-read on
# the RAW text so a bare `$error` inside a blanked literal is still seen.
#
# Exit codes:
#   0  every entry point is silenced first and its handlers are anonymous
#   1  a violation was found
#   2  expected paths missing / floor breached / self-test failed

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
readonly REPO_ROOT
readonly SCRIPT_NAME='check_release_log_silencer'

# Two `vm:entry-point` functions plus `main()` today. A parser that stopped
# recognising either shape would otherwise report "0 entry points, all fine".
readonly MIN_ENTRYPOINTS=3

log()  { printf '\033[1;34m[%s]\033[0m %s\n' "${SCRIPT_NAME}" "$*"; }
fail() { printf '\033[1;31m[%s] FAIL:\033[0m %s\n' "${SCRIPT_NAME}" "$*" >&2; }
misconfig() { printf '\033[1;31m[%s] BROKEN:\033[0m %s\n' "${SCRIPT_NAME}" "$*" >&2; exit 2; }

# ---------------------------------------------------------------------------
# One file per invocation. Prints one line per subject:
#   OK<TAB>file<TAB>line<TAB>kind
#   V<TAB>file<TAB>line<TAB>kind: <reason>[; <reason>...]
# ---------------------------------------------------------------------------
read -r -d '' SCAN_AWK <<'AWK' || true
BEGIN {
  # All three are matched with whitespace removed and string contents blanked,
  # so inside `debugPrint(...)` only interpolated CODE survives.
  SILENCER = "^if\\(kReleaseMode\\)\\{debugPrint=\\(String\\?[A-Za-z_][A-Za-z0-9_]*,\\{int\\?[A-Za-z_][A-Za-z0-9_]*\\}\\)\\{\\};\\}$"
  FE_RE = "^FlutterError\\.onError=\\(details\\)(=>debugPrint\\([^;]*\\);|\\{debugPrint\\([^;]*\\);\\};)$"
  PD_RE = "^PlatformDispatcher\\.instance\\.onError=\\(error,stack\\)\\{debugPrint\\([^;]*\\);returntrue;\\};$"
  OKINTERP = "^[A-Za-z_][A-Za-z0-9_.]*\\.runtimeType$|^details\\.library$"
  mode = "code"; lvl = 0; np = 0
}

# Blanks string contents and comments, one space per character, so columns
# and line numbers survive. Interpolation (`${...}`) re-enters code mode with
# its own brace depth, so a quote inside `${map['k']}` cannot desync the lexer.
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
      closes = triple ? (c3 == qc qc qc) : (c == qc)
      if (closes) { out = out (triple ? "   " : " "); i += (triple ? 3 : 1); mode = "code"; continue }
      if (!rawstr && c == "\\") { out = out "  "; i += 2; continue }
      if (!rawstr && c2 == "${") {
        lvl++; cd[lvl] = 0; SQ[lvl] = qc; ST[lvl] = triple
        out = out "  "; i += 2; mode = "code"; continue
      }
      out = out " "; i++; continue
    }
    if (c2 == "//") { while (i <= n) { out = out " "; i++ }; break }
    if (c2 == "/*") { mode = "bcomment"; bdepth = 1; out = out "  "; i += 2; continue }
    if (c == "\"" || c == "'") {
      rawstr = (i > 1 && substr(s, i - 1, 1) == "r" && (i == 2 || substr(s, i - 2, 1) !~ /[A-Za-z0-9_]/))
      qc = c; triple = (c3 == c c c)
      out = out (triple ? "   " : " "); i += (triple ? 3 : 1); mode = "str"; continue
    }
    if (lvl > 0) {
      if (c == "{") cd[lvl]++
      else if (c == "}") {
        if (cd[lvl] == 0) { qc = SQ[lvl]; triple = ST[lvl]; rawstr = 0; lvl--; mode = "str"; out = out " "; i++; continue }
        cd[lvl]--
      }
    }
    out = out c; i++
  }
  # A single-quoted Dart literal cannot span lines; if the lexer is still
  # inside one at EOL it has desynced, so resync rather than eat the file.
  if (mode == "str" && !triple) mode = "code"
  return out
}

# Index (within s, which starts at an opener) of the matching closer.
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

function line_of(pos,   k) {
  for (k = 1; k <= NLINES; k++) if (LS[k] > pos) return k - 1
  return NLINES
}

function trim(s) { sub(/^[[:space:]]+/, "", s); sub(/[[:space:]]+$/, "", s); return s }
function nows(s) { gsub(/[[:space:]]/, "", s); return s }
function add(list, item) { return (list == "" ? item : list "; " item) }

# Top-level statements of a body (outer braces included): SS[k]/SE[k] are
# 1-based offsets into the body. A `}` closing to depth 0 ends a statement only
# when the statement is a block form and nothing continues it.
function split_statements(body,   n, i, c, depth, start, nxt, head) {
  NS = 0; n = length(body) - 1; depth = 0; start = 2
  for (i = 2; i <= n; i++) {
    c = substr(body, i, 1)
    if (c ~ /[({[]/) { depth++; continue }
    if (c ~ /[]})]/) {
      depth--
      if (depth == 0 && c == "}") {
        nxt = substr(body, i + 1); sub(/^[[:space:]]+/, "", nxt)
        if (nxt ~ /^(;|else([^A-Za-z0-9_]|$)|\.|\))/) continue
        head = trim(substr(body, start, i - start + 1))
        if (head ~ /^(if|for|while|do|try|switch|\{)([^A-Za-z0-9_]|$)/) { NS++; SS[NS] = start; SE[NS] = i; start = i + 1 }
      }
      continue
    }
    if (c == ";" && depth == 0) { NS++; SS[NS] = start; SE[NS] = i; start = i + 1 }
  }
}

function silencer_reason(b) {
  if (b ~ /^\{if\(kReleaseMode\)\{debugPrint=/) return "the kReleaseMode block is not the plain no-op silencer (the closure must be `{}`)"
  if (b ~ /^\{if\(kReleaseMode&&/) return "the silencer is conditioned on more than kReleaseMode"
  if (b ~ /if\(kReleaseMode\)\{debugPrint=/) return "a statement runs BEFORE the kReleaseMode silencer"
  if (b ~ /if\(kDebugMode\)\{debugPrint=/) return "the silencer is keyed to kDebugMode; it must be kReleaseMode"
  return "no kReleaseMode debugPrint silencer as the first statement"
}

# What a handler renders beyond a type name: every `${…}` / `$ident` of the
# RAW statement, plus any code visible inside debugPrint(...) once literals
# are blanked (a non-literal argument, or a `${error}` re-entered as code).
function bad_handler_interp(rawtext, codetext,   rest, rs, rl, inner, q, out, n, i, toks) {
  out = ""; rest = rawtext
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
    if (inner !~ OKINTERP && !index(out, "`" inner "`")) out = out (out == "" ? "" : ", ") "`" inner "`"
  }
  q = index(codetext, "debugPrint")
  if (q) {
    inner = substr(codetext, q + 10)
    sub(/^[[:space:]]*/, "", inner)
    inner = substr(inner, 2, skip_balanced(inner) - 2)
    gsub(/,/, " ", inner)                      # a trailing comma is Dart style, not code
    n = split(inner, toks, /[[:space:]]+/)
    for (i = 1; i <= n; i++)
      if (toks[i] != "" && toks[i] !~ OKINTERP && !index(out, "`" toks[i] "`")) out = out (out == "" ? "" : ", ") "`" toks[i] "`"
  }
  return out
}

function check_at(start, kind,   rest, i, consumed, line, bstart, blen, body, reasons, s1, k, sw, fe, pd, p, nb) {
  rest = substr(T, start)
  while (1) {
    if (match(rest, /^[[:space:]]+/)) { rest = substr(rest, RLENGTH + 1); continue }
    if (match(rest, /^@[A-Za-z_][A-Za-z0-9_.]*/)) {
      rest = substr(rest, RLENGTH + 1)
      if (substr(rest, 1, 1) == "(") rest = substr(rest, skip_balanced(rest) + 1)
      continue
    }
    break
  }
  consumed = length(T) - start + 1 - length(rest)
  line = line_of(start + consumed)
  if (!match(rest, /^(external[[:space:]]+)?(static[[:space:]]+)?([A-Za-z_][A-Za-z0-9_<>?, ]*[[:space:]]+)?[A-Za-z_][A-Za-z0-9_]*[[:space:]]*\(/)) {
    printf "V\t%s\t%d\t%s: the annotated declaration is not a function, so no silencer can run first in it\n", FILENAME, line, kind
    return
  }
  i = RLENGTH
  rest = substr(rest, i)
  rest = substr(rest, skip_balanced(rest) + 1)
  sub(/^[[:space:]]*(async\*?|sync\*)?[[:space:]]*/, "", rest)
  if (substr(rest, 1, 1) != "{") {
    printf "V\t%s\t%d\t%s: expression-bodied or bodiless function cannot install the silencer first\n", FILENAME, line, kind
    return
  }
  # `rest` is always a suffix of T, so the body's absolute offset falls out.
  bstart = length(T) - length(rest) + 1
  blen = skip_balanced(rest)
  body = substr(rest, 1, blen)
  split_statements(body)
  reasons = ""
  s1 = (NS >= 1) ? nows(substr(body, SS[1], SE[1] - SS[1] + 1)) : ""
  if (s1 !~ SILENCER) reasons = add(reasons, silencer_reason(nows(body)))
  # Both handlers must be installed before the first statement that can log:
  # only the binding / plugin-registrant init and the other handler may
  # precede them.
  fe = 0; pd = 0; blocker = ""
  for (k = 2; k <= NS; k++) {
    if (fe && pd) break
    sw = nows(substr(body, SS[k], SE[k] - SS[k] + 1))
    if (sw ~ FE_RE) { if (!fe) fe = k; continue }
    if (sw ~ PD_RE) { if (!pd) pd = k; continue }
    if (sw ~ /^(WidgetsFlutterBinding|DartPluginRegistrant)\.ensureInitialized\(\);$/) continue
    if (blocker == "") blocker = substr(nows(substr(body, SS[k], SE[k] - SS[k] + 1)), 1, 40)
  }
  nb = nows(body)
  if (!fe) reasons = add(reasons, (index(nb, "FlutterError.onError=") ? "the FlutterError.onError handler is malformed (expected `(details) => debugPrint(...)` or a block, rendering only runtimeType/library)" : "no FlutterError.onError handler"))
  if (!pd) reasons = add(reasons, (index(nb, "PlatformDispatcher.instance.onError=") ? "the PlatformDispatcher.instance.onError handler is malformed (expected `(error, stack) { debugPrint(...); return true; }`)" : "no PlatformDispatcher.instance.onError handler"))
  if (blocker != "") reasons = add(reasons, "`" blocker "` runs before both error handlers are installed (only the binding/plugin-registrant init may precede them)")
  if (fe) {
    p = bad_handler_interp(substr(RAWT, bstart + SS[fe] - 1, SE[fe] - SS[fe] + 1), substr(body, SS[fe], SE[fe] - SS[fe] + 1))
    if (p != "") reasons = add(reasons, "the FlutterError.onError handler renders " p " — only <expr>.runtimeType and details.library may be interpolated")
  }
  if (pd) {
    p = bad_handler_interp(substr(RAWT, bstart + SS[pd] - 1, SE[pd] - SS[pd] + 1), substr(body, SS[pd], SE[pd] - SS[pd] + 1))
    if (p != "") reasons = add(reasons, "the PlatformDispatcher.instance.onError handler renders " p " — only <expr>.runtimeType may be interpolated")
  }
  if (reasons == "") printf "OK\t%s\t%d\t%s\n", FILENAME, line, kind
  else printf "V\t%s\t%d\t%s: %s\n", FILENAME, line, kind, reasons
}

{
  raw = $0
  LS[FNR] = length(T) + 1
  code = strip_line(raw)
  # The pragma's argument is a string and is blanked with everything else, so
  # it is recognised on the RAW line and confirmed as code (not a comment) on
  # the stripped one.
  if (raw ~ /@pragma\([[:space:]]*['"]vm:entry-point['"][[:space:]]*\)/ && code ~ /@pragma\(/) {
    np++; PL[np] = FNR
  }
  T = T code "\n"
  RAWT = RAWT raw "\n"
  NLINES = FNR
}

END {
  for (k = 1; k <= np; k++) {
    seg = substr(T, LS[PL[k]])
    if (!match(seg, /@pragma\(/)) continue
    p = LS[PL[k]] + RSTART - 1 + RLENGTH - 1
    check_at(p + skip_balanced(substr(T, p)), "vm:entry-point")
  }
  rest = T; base = 0
  while (match(rest, /(^|\n)(void|Future<void>)[[:space:]]+main[[:space:]]*\(/)) {
    # check_at() calls match() itself, so the cursor is saved first.
    rs = RSTART; rl = RLENGTH
    check_at(base + rs + (substr(rest, rs, 1) == "\n" ? 1 : 0), "main()")
    base = base + rs + rl - 1
    rest = substr(rest, rs + rl)
  }
}
AWK
readonly SCAN_AWK

# check_tree <lib-dir> <min-entrypoints>
check_tree() {
  local lib="$1" min="$2" out subjects violations
  local -a files
  mapfile -t files < <(find "${lib}" -name '*.dart' -not -path '*/src/rust/*' | sort)
  (( ${#files[@]} > 0 )) || { fail "no Dart sources under ${lib}"; return 2; }
  out=""
  local f
  for f in "${files[@]}"; do
    out+="$(awk "${SCAN_AWK}" "${f}")"$'\n'
  done
  subjects="$(grep -c $'^\(OK\|V\)\t' <<<"${out}" || true)"
  if (( subjects < min )); then
    fail "found ${subjects} entry point(s), expected >= ${min}."
    echo "  The parser has stopped recognising @pragma('vm:entry-point') or main(); fix it." >&2
    return 2
  fi
  violations="$(grep $'^V\t' <<<"${out}" || true)"
  if [[ -n "${violations}" ]]; then
    fail "an isolate entry point does not install the kReleaseMode silencer FIRST, then the two anonymous error handlers (Security Rule 15)."
    awk -F'\t' '{ printf "    %s:%s: %s\n", $2, $3, $4 }' <<<"${violations}" >&2
    echo "  The body must open with the silencer, then install both handlers before anything" >&2
    echo "  but WidgetsFlutterBinding/DartPluginRegistrant.ensureInitialized():" >&2
    echo "    if (kReleaseMode) { debugPrint = (String? message, {int? wrapWidth}) {}; }" >&2
    echo "    FlutterError.onError = (details) => debugPrint('[FlutterError] \${details.exception.runtimeType} in \${details.library}');" >&2
    echo "    PlatformDispatcher.instance.onError = (error, stack) { debugPrint('[UncaughtAsync] \${error.runtimeType}'); return true; };" >&2
    return 1
  fi
  log "OK: ${subjects} entry point(s) install the release debugPrint silencer before anything else, then the two anonymous error handlers."
  return 0
}

# ---------------------------------------------------------------------------
# Self-test — hermetic fixture trees.
# ---------------------------------------------------------------------------
readonly DECLARED_CASES=25

self_test() {
  local tmp fails=0 checked=0
  tmp="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf '${tmp}'" RETURN

  # The compliant preamble, in the shape the tree uses.
  local SIL='  if (kReleaseMode) {
    debugPrint = (String? message, {int? wrapWidth}) {};
  }'
  local FE="  FlutterError.onError = (details) => debugPrint(
    '[FlutterError] \${details.exception.runtimeType} in \${details.library}',
  );"
  local PD="  PlatformDispatcher.instance.onError = (error, stack) {
    debugPrint('[UncaughtAsync] \${error.runtimeType}');
    return true;
  };"

  # _case <label> <want-rc> <min> <relative-path> <content>
  _case() {
    local label="$1" want="$2" min="$3" rel="$4" content="$5" got=0 root
    checked=$(( checked + 1 ))
    root="${tmp}/case${checked}/haven/lib"
    mkdir -p "${root}/$(dirname "${rel}")"
    printf '%s' "${content}" > "${root}/${rel}"
    ( check_tree "${root}" "${min}" ) >/dev/null 2>&1 || got=$?
    if [[ "${got}" -eq "${want}" ]]; then
      printf '  \033[1;32mPASS\033[0m %s (rc=%d)\n' "${label}" "${got}"
    else
      printf '  \033[1;31mFAIL\033[0m %s (want rc=%d, got rc=%d)\n' "${label}" "${want}" "${got}" >&2
      ( check_tree "${root}" "${min}" ) 2>&1 | sed 's/^/        /' >&2 || true
      fails=1
    fi
  }

  log "self-test: entry-point silencer + anonymous error handlers"

  _case "compliant vm:entry-point function passes" 0 1 a.dart \
"@pragma('vm:entry-point')
void callbackDispatcher() {
${SIL}
${FE}
${PD}
  WidgetsFlutterBinding.ensureInitialized();
}
"
  # THE regression: the silencer is present, but the binding boots first.
  _case "a statement before the silencer FAILS" 1 1 a.dart \
"@pragma('vm:entry-point')
void callbackDispatcher() {
  WidgetsFlutterBinding.ensureInitialized();
${SIL}
${FE}
${PD}
}
"
  _case "compliant async main() passes" 0 1 main.dart \
"Future<void> main() async {
${SIL}
${FE}
${PD}
  runApp(const App());
}
"
  _case "main() with a statement before the silencer FAILS" 1 1 main.dart \
"Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
${SIL}
${FE}
${PD}
  runApp(const App());
}
"
  _case "main() with no silencer FAILS" 1 1 main.dart \
"void main() {
${FE}
${PD}
  runApp(const App());
}
"
  # A closure that forwards is not a silencer.
  _case "a forwarding closure FAILS" 1 1 a.dart \
"@pragma('vm:entry-point')
void cb() {
  if (kReleaseMode) {
    debugPrint = (String? m, {int? wrapWidth}) => print(m);
  }
${FE}
${PD}
}
"
  _case "kDebugMode instead of kReleaseMode FAILS" 1 1 a.dart \
"@pragma('vm:entry-point')
void cb() {
  if (kDebugMode) {
    debugPrint = (String? m, {int? w}) {};
  }
${FE}
${PD}
}
"
  _case "an extra condition on the silencer FAILS" 1 1 a.dart \
"@pragma('vm:entry-point')
void cb() {
  if (kReleaseMode && silence) {
    debugPrint = (String? m, {int? w}) {};
  }
${FE}
${PD}
}
"
  # Double quotes, a doc comment, and comment lines between `{` and the
  # silencer are all fine — only STATEMENTS count.
  _case "double-quoted pragma with comments before the silencer passes" 0 1 a.dart \
"/// Entry point. See https://example.invalid/docs // not a comment start
@pragma(\"vm:entry-point\")
Future<void> cb() async {
  // (0) silence first
  /* block
     comment */
  if (kReleaseMode) {
    debugPrint = (String? m, {int? w}) {};
  }
  // (1) then the anonymous handlers
${FE}
${PD}
  await run();
}
"
  # A `//` inside a string on the line before must not swallow the pragma.
  _case "a URL string before the function does not desync the lexer" 0 1 a.dart \
"const docs = 'https://example.invalid/{path}';
@pragma('vm:entry-point')
void cb() {
${SIL}
${FE}
${PD}
}
"
  _case "an expression-bodied entry point FAILS" 1 1 a.dart \
"@pragma('vm:entry-point')
void cb() => run();
"
  # A pragma inside a comment annotates nothing; with the floor at 1 the
  # only subject must be the compliant main below.
  _case "a commented-out pragma is not a subject" 0 1 main.dart \
"// @pragma('vm:entry-point')
// void old() { run(); }
void main() {
${SIL}
${FE}
${PD}
}
"
  # Generated bindings are machine output: an unsilenced pragma there is
  # outside this guard's remit, and the compliant main keeps the floor met.
  checked=$(( checked + 1 ))
  local root="${tmp}/gen/haven/lib" got=0
  mkdir -p "${root}/src/rust"
  printf '%s' "@pragma('vm:entry-point')
void generated() {
  run();
}
" > "${root}/src/rust/frb.dart"
  printf '%s' "void main() {
${SIL}
${FE}
${PD}
}
" > "${root}/main.dart"
  ( check_tree "${root}" 1 ) >/dev/null 2>&1 || got=$?
  if (( got == 0 )); then
    printf '  \033[1;32mPASS\033[0m src/rust/ is excluded (rc=0)\n'
  else
    printf '  \033[1;31mFAIL\033[0m src/rust/ is excluded (want rc=0, got rc=%d)\n' "${got}" >&2
    fails=1
  fi

  _case "a pragma on a class FAILS" 1 1 a.dart \
"@pragma('vm:entry-point')
class Holder {
  void run() {}
}
"
  _case "fewer entry points than the floor is BROKEN" 2 3 main.dart \
"void main() {
${SIL}
${FE}
${PD}
}
"

  # The error handlers: both, right after the silencer, rendering a type only.
  _case "the two handlers in swapped order (block-bodied FlutterError) pass" 0 1 main.dart \
"void main() {
${SIL}
${PD}
  FlutterError.onError = (details) {
    debugPrint('[FlutterError] \${details.exception.runtimeType} in \${details.library}');
  };
  runApp(const App());
}
"
  _case "a missing FlutterError.onError handler FAILS" 1 1 main.dart \
"void main() {
${SIL}
${PD}
  runApp(const App());
}
"
  _case "a missing PlatformDispatcher.instance.onError handler FAILS" 1 1 main.dart \
"void main() {
${SIL}
${FE}
  runApp(const App());
}
"
  # `details.exception` is the exception's toString — a SocketException names
  # the relay host.
  _case "a handler interpolating \${details.exception} FAILS" 1 1 main.dart \
"void main() {
${SIL}
  FlutterError.onError = (details) => debugPrint(
    '[FlutterError] \${details.exception} in \${details.library}',
  );
${PD}
}
"
  # A bare \$error lives inside the blanked literal: the raw re-read is what
  # sees it.
  _case "a handler interpolating \$error FAILS" 1 1 main.dart \
"void main() {
${SIL}
${FE}
  PlatformDispatcher.instance.onError = (error, stack) {
    debugPrint('[UncaughtAsync] \$error');
    return true;
  };
}
"
  _case "a handler installed BEFORE the silencer FAILS" 1 1 main.dart \
"void main() {
${FE}
${SIL}
${PD}
}
"
  # Without `return true` the framework falls through to its own dump of
  # the error, toString and all.
  _case "a PlatformDispatcher handler that does not return true FAILS" 1 1 main.dart \
"void main() {
${SIL}
${FE}
  PlatformDispatcher.instance.onError = (error, stack) {
    debugPrint('[UncaughtAsync] \${error.runtimeType}');
    return false;
  };
}
"

  # Placement relative to the binding init: both positions are fine, a logging
  # call (or anything else) before both handlers is not.
  _case "handlers AFTER the binding/plugin-registrant init pass" 0 1 a.dart \
"@pragma('vm:entry-point')
void callbackDispatcher() {
${SIL}
  WidgetsFlutterBinding.ensureInitialized();
  DartPluginRegistrant.ensureInitialized();
${FE}
${PD}
  Workmanager().executeTask((taskName, inputData) => runWake());
}
"
  _case "a logging call before a handler FAILS" 1 1 main.dart \
"void main() {
${SIL}
  debugPrint('boot');
${FE}
${PD}
}
"
  _case "runApp between the two handlers FAILS" 1 1 main.dart \
"Future<void> main() async {
${SIL}
  WidgetsFlutterBinding.ensureInitialized();
${FE}
  runApp(const App());
${PD}
}
"

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

  local lib="${REPO_ROOT}/haven/lib"
  [[ -d "${lib}" ]] || misconfig "${lib} not found"
  [[ -f "${lib}/main.dart" ]] || misconfig "${lib}/main.dart not found"

  local rc=0
  check_tree "${lib}" "${MIN_ENTRYPOINTS}" || rc=$?
  exit "${rc}"
}

main "$@"
