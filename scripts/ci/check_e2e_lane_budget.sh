#!/usr/bin/env bash
# CI guard: every E2E lane's inner deadline covers the worst case of what it
# runs, computed from the code.
#
# # The missing link
#
# check_e2e_step_timeout_ordering.sh enforces deadline < step cap < job cap.
# Nothing enforced the link below them: that the deadline is at least the
# harness's own worst-case runtime. Hand-written sums at the drive steps kept
# leaving waits out — a route wait, a Wi-Fi wait, the guard's probes, a
# drive's kill-after, a lane's post-drive tail — and each false sum was found
# by a person reading the arithmetic. This check does that reading.
#
# # How the worst case is computed
#
# 1. Lanes are the drive steps check_e2e_step_timeout_ordering.sh finds, with
#    its extraction (sourced, not re-parsed): the same deadline, both sides of
#    a `${{ c && A || B }}` expression paired positionally — which holds only
#    while everything the lane reads is chosen by that one condition, so a
#    lane that reads values chosen by two conditions is refused.
# 2. The deadline's command is split into the tooling/e2e/ci scripts it runs,
#    with the env the workflow gives them (workflow, job, step, the command's
#    own prefix; a name any step writes to GITHUB_ENV is decided at run time).
#    Anything else in that command is a violation: it would run inside the
#    deadline unbudgeted.
# 3. Each script is read by an analyzer (the awk below) that drops comments,
#    heredoc bodies and quoted text and follows local function calls (a
#    function defined inside another, or with a subshell body, included) and
#    EXIT/ERR traps, so every WAIT the script can reach becomes a site with a
#    path such as `wait_for_marker#2/sleep:MARKER_POLL_SECS#1`. A wait is
#    `sleep`, `timeout`, `read -t`, `nc -w`, `iptables -w`, a device
#    `wait-for-*` or `adb shell sleep|timeout`, an unwrapped `flutter
#    drive|test|run`, another tooling script run by `bash` or by its path, a
#    `bash` reading its script from stdin (a site no charge can bound), or a
#    call into a sourced library function that waits — also behind sudo, nice,
#    env, stdbuf, ionice, taskset, chrt, exec, time, nohup, setsid, builtin or
#    command, by absolute path or backslashed. The `--self-test` branches (an
#    `if` whose whole condition tests the first argument == --self-test, a
#    `case` arm on it whose only pattern is --self-test) are not paths.
# 4. scripts/ci/e2e_lane_budget.manifest must claim every site, and says what
#    it costs: `charge <expr>` over the script's OWN constants, times a count.
#    The check evaluates those constants from their definitions — the literal,
#    the `${ENV:-default}` the workflow may override, the positional argument,
#    the arithmetic, an earlier constant — so a changed constant changes the
#    sum, and nothing is ever read from prose. A value is only as good as its
#    source: one from a workflow expression it cannot evaluate is refused, and
#    an input's default is accepted only in a reaper lane (below), where a
#    larger dispatch only grows a sum that already exceeds the deadline. What
#    the caller passes is the value only while the script, and every library
#    it sources, never sets that name some other way than a top-level
#    NAME=value (in a function, `${ENV:=…}`, `printf -v`, `read`, `unset`,
#    `export -n`, a nameref): such a name is refused, before a definition that
#    reads it and in the child it reaches — as is a positional argument, and
#    the target count, once a top-level `shift` or `set` has moved them. A child run behind `env` sees env's
#    own assignments and loses what `env -u`/`env -i`/`exec -c` remove; one
#    behind `sudo` (without -E) sees what sudo's policy keeps, which is
#    refused as unknowable.
# 5. worst case = the sum of the charges + UNBOUNDED_WORK_ALLOWANCE_SECS, and
#    it must not exceed the deadline. A lane with a wait the check could not
#    count is INCOMPLETE: its sum is a lower bound, enough to show a deadline
#    too short and never enough to show one sufficient.
#
# The analyzer is checked by a second reading of every script and library
# function a lane reaches, through app-install-lib.sh's lexer: on no reachable
# line may it see more waits than the analyzer read, or the check stops
# (rc 2). Its command recognition is independent; its lexer follows the same
# quoting rules, so a lexing error both share is not caught. The set of lanes
# is checked against the ordering guard's own count.
#
# # What makes a claim acceptable (the completeness rule)
#
#   * every site is claimed (first matching pattern wins), and every claim,
#     section and declaration matches something: an unclaimed wait is a sum
#     that omits a wait; a stale claim is a sum that counts one that is gone;
#   * a charge is at least the wait's own bound, and names the constant that
#     bound is written in — or, for a wait inside a loop, the constant the loop
#     is bounded by, which the analyzer finds in the loop header, one local
#     assignment behind it, or the caller's argument. Every constant a charge
#     or a bound names, and every constant those are defined from, is
#     `readonly`, so nothing can change what was read;
#   * a wait charged by its loop is charged at least what that loop can spend
#     in it, read from the header: ceil((bound - start) / step) passes of a
#     counted loop (one more for `<=`), or the bound plus one tick of a
#     wall-clock loop. A header this cannot read is refused: an `||`, a
#     negation, a bound set to two values or written in any other way, a
#     counter both counted and clocked, one that starts anywhere but a whole
#     number set outside the loop (a negative or computed start, a reset in
#     the body) or moves any way but forward by one word (`x=$(( x + S ))`,
#     `(( x += S ))`, `x++`), and a wall-clock loop in a script that sets
#     SECONDS;
#   * every loop around a wait is paid for: its bound or its count appears in
#     the charge, the wait is a `poll` whose loop is released by `kill -0` of a
#     captured PID (whose job's waits are charged) or, in a background job, by
#     a `-e`/`-f` test of a file the lane's own path `touch`es, or the claim
#     says `once <reason>`;
#   * `concurrent` only for a wait inside a background job whose PID is
#     captured and never joined (a `wait` on anything but that PID variable
#     joins every job); `allowance` only for a `wait-for-*` with no bound;
#     `within <label> <reason>` only while the waits within a charged claim
#     fit its charges together, each counted at what its innermost loop can
#     spend in it; `excluded <reason>` must say why;
#   * a library function a lane calls may not call another library's waiting
#     function, and a library's top level may not wait: either wait would be
#     on no budget.
#
# # Lanes that are not covered, by declaration
#
#   reaper <workflow>::<job> <reason>   An aggregate deadline that reaps a long
#       run by design. Accepted only if the lane's full worst case EXCEEDS it
#       (otherwise budget it normally); it runs at least two drives, each an
#       unconditional drive site times the invocation's positional count,
#       where that count governs a loop around the site — never a claim's
#       retry count, a positional count on a drive no such loop repeats, or a
#       drive only an `if`, a `case` arm or an `||` reaches, so a
#       single-target lane cannot claim it; and one
#       drive's own bound is below the deadline, so a per-drive timeout can
#       fire before the aggregate one.
#   unbudgeted <workflow>::<job> <reason>   The macOS lanes: accepted only for
#       a `nick-fields/retry` step on a macOS runner whose harness launches
#       `flutter test` with no bound of its own, so there is no finite worst
#       case to compare.
#
# # Blind spots
#
# A wait behind `eval`, a variable holding a command other than a script's
# path, a function called through a variable, `coproc`, or a wrapper not
# listed above (a `bash -c` string is a script site of its own, unbounded);
# `set -a`; a command substitution inside `(( ))` (the second reading stops
# the check instead); the multiplicity a claim's `times`/`once`, `poll`,
# `within` or `excluded` asserts beyond the lexical facts above (a `within`
# wait's outer loops are not multiplied; a `kill -0` poll is matched to its
# jobs by the PID variable's name); a counted loop's passes read from its
# header, increment and start, not from the paths through its body (a
# `continue` that skips the increment); a `timeout` without `--kill-after`
# whose child ignores SIGTERM; a name set inside an unquoted heredoc body
# (`${X:=…}` there assigns), through a nameref whose target is not a literal,
# or behind a wrapper option this does not model (`env -S`, combined short
# options). Unbounded work that is not a wait — a fallback `flutter build`
# when no prebuilt APK is staged, a loop with no wait in it — is priced only by
# the allowance. The allowance is an estimate, not a bound.
#
# Usage:
#   check_e2e_lane_budget.sh              # check the repo
#   check_e2e_lane_budget.sh --explain    # ... and print every lane's sum
#   check_e2e_lane_budget.sh --sites <script>   # the waits a claim can name
#   check_e2e_lane_budget.sh --root <tree>      # the same check over another tree
#   check_e2e_lane_budget.sh --self-test
#
# Exit: 0 every lane covered, 1 a violation, 2 the check itself cannot run.

set -euo pipefail
export LC_ALL=C

LB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly LB_DIR
# shellcheck source=scripts/ci/check_e2e_step_timeout_ordering.sh
source "${LB_DIR}/check_e2e_step_timeout_ordering.sh"

readonly LB_NAME="check_e2e_lane_budget"
readonly LB_MANIFEST_REL="scripts/ci/e2e_lane_budget.manifest"

# Unbounded work inside a deadline: adb install/grant/read round trips, the
# docker and strfry calls, the secret scans. An ESTIMATE, applied once to every
# lane and declared nowhere else, so no lane can pick its own. Provenance: the
# figure e2e-android's hand budget carried since A8, kept because the sick
# device that reaches the other bounds is the one that slows this work down;
# run 34488512808's healthy single-target lanes spent under 30 s on it.
readonly UNBOUNDED_WORK_ALLOWANCE_SECS=180

lb_log() { printf '\033[1;34m[%s]\033[0m %s\n' "${LB_NAME}" "$*"; }
lb_die() { printf '\033[1;31m[%s] ERROR:\033[0m %s\n' "${LB_NAME}" "$*" >&2; exit 2; }

# Violations are counted in the calling shell, never inside `$( … )`, where the
# increment would be discarded with the subshell. Keyed, because a script that
# several lanes run would otherwise report one defect once per lane.
LB_VIOL=0
declare -A LB_VSEEN=()
lb_violation() {
  local key="$1"; shift
  [[ -z "${LB_VSEEN[${key}]:-}" ]] || return 0
  LB_VSEEN["${key}"]=1
  LB_VIOL=$(( LB_VIOL + 1 ))
  printf '\033[1;31m[%s] FAIL:\033[0m %s\n' "${LB_NAME}" "$*" >&2
}

# ---------------------------------------------------------------------------
# The analyzer: one bash file in, its reachable wait sites out.
#
#   -v roots="MAIN" | "fn …"   entry scopes (a script's top level, or the
#                              functions a library exports)
#   -v ext="fn …"              functions of SOURCED libraries; a call to one is
#                              a `lib:` site (dropped later if it waits for
#                              nothing)
#
# Output records (TSV):
#   F  name                    a function
#   A  name  value  keyword  line   a top-level assignment
#   SRC  target  word  line    a `source`d file (target "?" when the word
#                              names no .sh this can resolve)
#   X  name  scope  hasval     an export at the top level or in a reachable
#                              function (hasval: it also assigns, so a
#                              function's export is a value this cannot read)
#   WR  name  line             a write to name other than a top-level
#                              NAME=value, at the top level or in a reachable
#                              function (see addwrite)
#   S  path kind b1 b2 line bg waited loops env args cond
#                              a site: bound words b1 (b2 = kill-after), the
#                              background job (id:line:PID variable) and
#                              whether its PID is `wait`ed ("waited" | "free"
#                              | "unknown"), the enclosing loops (line|governing
#                              idents|kill -0 PIDs|touched stop files|bound|<=|
#                              step|wall clock, `;`-joined), for a `bash` site
#                              its prefix env and arguments, and whether only
#                              some paths reach it (an `if` body, a `case` arm,
#                              after `&&`/`||`)
#   RNG  F|U|X|M  start  end   a reachable (F) or unreachable (U) function's
#                              lines, a --self-test region (X), and whether the
#                              top level is a root (M): the second reading's map
#   LC  line  count            how many waits the analyzer read on a line
#   E  message                 the file cannot be read (exit 3)
#
# The lexer keeps two views of each logical line: RAW (comments and heredoc
# bodies gone, continuations joined) and CODE, the same length with quoted
# text replaced by `_`, so a `sleep` inside a message is not a command while
# the argument of a real `sleep` is still read from RAW at the same offset.
# POSIX awk only: gawk --posix and mawk must read it the same way.
# ---------------------------------------------------------------------------
LB_AWK=$(cat <<'AWK'
BEGIN {
  sq = sprintf("%c", 39); dq = sprintf("%c", 34); bq = sprintf("%c", 96)
  FILL = "_"
  SELFTEST_IF = "^if[[:space:]]+([[][[]|[[]|test)[[:space:]]+[^[:space:]]+[[:space:]]+==?[[:space:]]+[" dq sq "]?--self-test[" dq sq "]?[[:space:]]*([]][]]|[]])?[[:space:]]*(;[[:space:]]*then([[:space:]]|$)|$)"
  # A name an arithmetic expression writes: NAME (op)= (never ==), NAME++,
  # NAME--, ++NAME, --NAME; never $NAME, which it only reads.
  ARITH_W = "[^$A-Za-z0-9_][A-Za-z_][A-Za-z0-9_]*[[:space:]]*(([-+*/%&|^]|<<|>>)?=([^=]|$)|[+][+]|--)|([+][+]|--)[[:space:]]*[A-Za-z_][A-Za-z0-9_]*"
  sp = 1; st[1] = "C"; dep[1] = -1
  NL = 0; open = 0; hd = ""; pend = ""
  nx = split(ext, xa, " "); for (i = 1; i <= nx; i++) EXT[xa[i]] = 1
}
hd != "" {
  t = $0
  if (hdtabs) sub(/^\t+/, "", t)
  if (t == hd) hd = ""
  next
}
{
  if (!open) { start = NR; open = 1; raw = ""; code = "" }
  line = $0; n = length(line); cont = 0
  for (i = 1; i <= n; i++) {
    c = substr(line, i, 1); s = st[sp]
    if (s == "S") { raw = raw c; if (c == sq) { sp--; code = code c } else code = code FILL; continue }
    if (s == "A") {
      if (c == "\\") { raw = raw substr(line, i, 2); code = code FILL FILL; i++; continue }
      raw = raw c; if (c == sq) { sp--; code = code c } else code = code FILL; continue
    }
    if (s == "D") {
      if (c == "\\") { raw = raw substr(line, i, 2); code = code FILL FILL; i++; continue }
      if (c == dq) { sp--; raw = raw c; code = code c; continue }
      if (c == bq) { st[++sp] = "B"; dep[sp] = -1; raw = raw c; code = code c; continue }
      if (c == "$" && substr(line, i + 1, 1) == "(") {
        st[++sp] = "C"; dep[sp] = 0; raw = raw "$("; code = code "$("; i++; continue
      }
      raw = raw c; code = code FILL; continue
    }
    if (c == "\\") {
      if (i == n) { cont = 1; break }
      raw = raw substr(line, i, 2); code = code substr(line, i, 2); i++; continue
    }
    if (s == "B" && c == bq) { sp--; raw = raw c; code = code c; continue }
    if (c == sq) { st[++sp] = "S"; raw = raw c; code = code c; continue }
    if (c == dq) { st[++sp] = "D"; raw = raw c; code = code c; continue }
    if (c == "$" && substr(line, i + 1, 1) == sq) {
      st[++sp] = "A"; raw = raw "$" sq; code = code "$" sq; i++; continue
    }
    if (c == "#" && (i == 1 || substr(line, i - 1, 1) ~ /[[:space:];&|()<>]/)) break
    # An array literal, NAME=( … ), holds words, not commands; it may span lines.
    if (c == "(" && i > 1 && substr(line, i - 1, 1) == "=") { st[++sp] = "C"; dep[sp] = 0; raw = raw c; code = code c; continue }
    if (substr(line, i, 3) == "<<<") { raw = raw "<<<"; code = code "<<<"; i += 2; continue }
    if (substr(line, i, 2) == "<<" \
        && match(substr(line, i), /^<<-?[[:space:]]*[^[:space:];&|<>()]+/)) {
      d = substr(line, i, RLENGTH); tabs = (substr(d, 3, 1) == "-")
      dd = d; sub(/^<<-?[[:space:]]*/, "", dd)
      gsub(sq, "", dd); gsub(dq, "", dd); gsub(/\\/, "", dd)
      if (dd ~ /^[A-Za-z0-9_.-]+$/ && dd !~ /^[0-9]+$/) {
        pend = dd; ptabs = tabs
        raw = raw d; code = code "<<" fill(RLENGTH - 2)
        i += RLENGTH - 1; continue
      }
    }
    if (dep[sp] >= 0) {
      if (c == "(") dep[sp]++
      else if (c == ")") {
        if (dep[sp] == 0) { sp--; raw = raw c; code = code c; continue }
        dep[sp]--
      }
    }
    raw = raw c; code = code c
  }
  if (pend != "") { hd = pend; hdtabs = ptabs; pend = "" }
  if (cont || sp > 1) { raw = raw " "; code = code " "; next }
  NL++; RAW[NL] = raw; CODE[NL] = code; LN[NL] = start
  open = 0
}

function fill(n,    s) { s = ""; while (n-- > 0) s = s FILL; return s }
function nz(v) { return v == "" ? "-" : v }

function addtok(ty, s, e) { NT++; TT[NT] = ty; TS[NT] = s; TE[NT] = e }
function tokenize(code) { NT = 0; tokrange(code, 1, length(code)) }
# A word holding a `$( … )` is emitted whole, AFTER the substitution's own
# commands: bash runs those first, and the word keeps its full text (a sourced
# path, an assignment's value) instead of being cut at the `$(`.
function tokrange(code, j, n,    c, c2, s, k, dp, t) {
  while (j <= n) {
    c = substr(code, j, 1)
    if (c == " " || c == "\t") { j++; continue }
    c2 = substr(code, j, 2)
    if (substr(code, j, 3) == "$((" || c2 == "((") {
      s = j; j += (substr(code, j, 3) == "$((" ? 3 : 2); dp = 2
      while (j <= n && dp > 0) {
        c = substr(code, j, 1); if (c == "(") dp++; else if (c == ")") dp--; j++
      }
      while (j <= n && substr(code, j, 1) !~ /[[:space:];&|()<>]/) j++
      addtok("w", s, j - 1); continue
    }
    if (c2 == "<(" || c2 == ">(") { addtok("so", j, j + 1); j += 2; continue }
    if (c == bq) { addtok("bq", j, j); j++; continue }
    if (substr(code, j, 3) == ";;&") { addtok("op", j, j + 2); j += 3; continue }
    if (c2 == "&&" || c2 == "||" || c2 == ";;" || c2 == ";&" || c2 == "|&") {
      addtok("op", j, j + 1); j += 2; continue
    }
    if (match(substr(code, j, n - j + 1), /^[0-9]*(<<<|<<-|<<|>>|>&|<&|&>>|&>|>[|]|<>|>|<)/)) {
      t = substr(code, j, RLENGTH); k = j + RLENGTH
      if (t ~ /&$/ && match(substr(code, k, n - k + 1), /^[0-9-]+/)) {
        k += RLENGTH; addtok("rd", j, k - 1); j = k; continue
      }
      addtok("rt", j, k - 1); j = k; continue
    }
    if (c == ";" || c == "|" || c == "&" || c == "(" || c == ")") { addtok("op", j, j); j++; continue }
    s = j
    while (j <= n) {
      c = substr(code, j, 1)
      if (c == " " || c == "\t") break
      if (c == "$" && substr(code, j + 1, 1) == "{") {
        k = j + 2; dp = 1
        while (k <= n && dp > 0) { c = substr(code, k, 1); if (c == "{") dp++; else if (c == "}") dp--; k++ }
        j = k; continue
      }
      if (substr(code, j, 3) == "$((") {
        k = j + 3; dp = 2
        while (k <= n && dp > 0) { c = substr(code, k, 1); if (c == "(") dp++; else if (c == ")") dp--; k++ }
        j = k; continue
      }
      if (c == "$" && substr(code, j + 1, 1) == "(") {
        k = j + 2; dp = 1
        while (k <= n && dp > 0) { c = substr(code, k, 1); if (c == "(") dp++; else if (c == ")") dp--; k++ }
        addtok("so", j, j + 1); tokrange(code, j + 2, k - 2); addtok("op", k - 1, k - 1)
        j = k; continue
      }
      if (c == "(" && j > s && substr(code, j - 1, 1) == "=") {
        k = j + 1; dp = 1
        while (k <= n && dp > 0) { c = substr(code, k, 1); if (c == "(") dp++; else if (c == ")") dp--; k++ }
        j = k; continue
      }
      if (c == ";" || c == "&" || c == "|" || c == "(" || c == ")" || c == "<" || c == ">" || c == bq) break
      j++
    }
    if (j > s) addtok("w", s, j - 1)
    else { addtok("op", j, j); j++ }
  }
}

# One frame per open construct. Commands collect per depth, so a `$( … )`
# interrupts the command around it rather than ending it.
function push(ty, v) {
  D++; ST_t[D] = ty; ST_v[D] = v; ST_ls[D] = NI; ST_le[D] = NEV; ST_ex[D] = 0; ST_cm[D] = ""
  ST_sj[D] = ""; CWN[D] = 0; CP[D] = 1; FORH[D] = 0; ANDOR[D] = 0
}
function pop() {
  if (D <= 1) { ERR = ERR "unbalanced " ST_t[D] " close at line " LN[CUR_LL] "; "; return }
  if (ST_ex[D]) { EXCL--; exrange(ST_v[D]) }
  if (ST_t[D] == "CASE" && ST_cm[D] == "armx") { EXCL--; exrange(ST_v[D]) }
  if (ST_t[D] == "FUNC") FN_E[ST_v[D]] = LN[CUR_LL]
  if (ST_t[D] == "LOOP") L_end[ST_v[D]] = LN[CUR_LL]
  D--
}
# A --self-test region, from where it opened to here.
function exrange(s) { NX++; X_S[NX] = s; X_E[NX] = LN[CUR_LL] }
# A function defined inside another is a function of its own, as bash defines
# it: its body runs where it is called, not where it is written.
function curscope(    d) {
  for (d = D; d >= 1; d--) if (ST_t[d] == "FUNC") return ST_v[d]
  return "MAIN"
}
# Whether a command in this scope runs only on some paths: inside an `if`
# body, a `case` arm, or after `||`. A drive there (a retry, a fallback) is not
# a target of its own. (`cd dir && drive` is the idiom for a precondition.)
function conditional(    d, s) {
  s = 1
  for (d = 1; d <= D; d++) if (ST_t[d] == "FUNC") s = d + 1
  for (d = s; d <= D; d++)
    if ((ST_t[d] == "IF" && ST_cm[d] == "body") || ST_t[d] == "CASE" || ANDOR[d]) return 1
  return 0
}
function loopchain(    d, s, r) {
  r = ""; s = 1
  for (d = 1; d <= D; d++) if (ST_t[d] == "FUNC") s = d + 1
  for (d = s; d <= D; d++) if (ST_t[d] == "LOOP") r = r (r == "" ? "" : " ") ST_v[d]
  return r
}
function unq(w) { gsub(sq, "", w); gsub(dq, "", w); return w }
# Whether a word holds an expansion outside quotes: it may split into several.
function unqdollar(w) { gsub(dq "[^" dq "]*" dq, "", w); gsub(sq "[^" sq "]*" sq, "", w); return index(w, "$") > 0 }
# Whether a word is the script's or function's first argument: "$1",
# "${1:-x}", or a variable this scope assigned from it.
function isarg1(w,    v) {
  w = unq(w)
  if (w ~ /^[$][{]?1([:]?-[^}]*)?[}]?$/) return 1
  if (!match(w, /^[$][{]?[A-Za-z_][A-Za-z0-9_]*[}]?$/)) return 0
  v = w; gsub(/[${}]/, "", v)
  return ((curscope() SUBSEP v) in ALIAS) && ALIAS[curscope(), v] == "1"
}
function firstvar(w,    t) {
  if (!match(w, /[$][{]?[A-Za-z_][A-Za-z0-9_]*/)) return ""
  t = substr(w, RSTART, RLENGTH); sub(/^[$][{]?/, "", t); return t
}
function idents(w,    r) {
  r = ""
  while (match(w, /[A-Za-z_][A-Za-z0-9_]*/)) { r = r " " substr(w, RSTART, RLENGTH); w = substr(w, RSTART + RLENGTH) }
  return r " "
}
function addword(d, raw, code) { CWN[d]++; CWR[d, CWN[d]] = raw; CWC[d, CWN[d]] = code }
function cmdname(w) { w = unq(w); sub(/^\\/, "", w); sub(/^.*\//, "", w); return w }
function wrapopt(W, o) {
  if (W == "sudo") return o ~ /^-[ugpCDhrtTU]$/
  if (W == "nice") return o == "-n"
  if (W == "env") return o ~ /^-[uCS]$/
  if (W == "stdbuf") return o ~ /^-[ioe]$/
  if (W == "ionice") return o ~ /^-[cnpPu]$/
  if (W == "exec") return o == "-a"
  if (W == "time") return o ~ /^-[of]$/
  return 0
}
function isassign(code) { return code ~ /^[A-Za-z_][A-Za-z0-9_]*[+]?=/ }
function record_assign(nv, kw,    nm, v, sc) {
  if (EXCL > 0) return
  nm = nv; sub(/[+]?=.*$/, "", nm)
  v = substr(nv, index(nv, "=") + 1)
  sc = curscope()
  NA++; A_sc[NA] = sc; A_nm[NA] = nm; A_v[NA] = v; A_kw[NA] = kw; A_ln[NA] = LN[CUR_LL]
  LAN[sc, nm]++; LAV[sc, nm, LAN[sc, nm]] = v; LAL[sc, nm, LAN[sc, nm]] = LN[CUR_LL]; LASG[sc, nm] = v
  if (sc != "MAIN") addwrite(nm, "a")
  if (v ~ /^"?[$][{]?[0-9]/ && match(v, /[0-9]+/)) ALIAS[sc, nm] = substr(v, RSTART, RLENGTH)
  if (PEND_J > 0 && v == "$!") J_pid[PEND_J] = nm
}
function emit(kind, a, b, c, env, args,    sc) {
  if (EXCL > 0) return
  sc = curscope()
  NI++; I_k[NI] = kind; I_a[NI] = a; I_b[NI] = b; I_c[NI] = c; I_env[NI] = env
  I_args[NI] = args; I_sc[NI] = sc; I_ln[NI] = LN[CUR_LL]; I_lp[NI] = loopchain(); I_bg[NI] = 0
  I_cond[NI] = conditional()
  SCOPE_ITEMS[sc] = SCOPE_ITEMS[sc] " " NI
}
function addexport(nv, hasval,    nm) {
  if (EXCL > 0) return
  nm = nv; sub(/[+]?=.*$/, "", nm)
  NEX++; EX_nm[NEX] = nm; EX_sc[NEX] = curscope(); EX_v[NEX] = hasval
}
# A write to a name other than a top-level NAME=value, which A records model:
# "a" a function's assignment, "h" arithmetic in a `for ((` header, "i" an
# arithmetic step forward (NAME++, ++NAME, NAME += one word, the step in
# W_st), "x" any other — printf -v, read, mapfile, getopts, let, a for/select
# variable, other arithmetic, ${NAME:=…}, unset, export -n; and "@", the
# script's positional arguments, which a top-level shift or set moves. What
# the caller passed for such a name is not what the script reads, and a
# counter moved by an "x" write is not counted from its header.
function addwrite(nm, k, st) {
  if (EXCL > 0 || nm !~ /^([A-Za-z_][A-Za-z0-9_]*|@)$/) return
  NW++; W_nm[NW] = nm; W_k[NW] = k; W_st[NW] = st; W_sc[NW] = curscope(); W_ln[NW] = LN[CUR_LL]; W_hd[NW] = openhdr()
}
# The loop whose header is being read, in this scope (a write there is the
# header's own, `while (( n++ < MAX ))`), or 0.
function openhdr(    d) {
  for (d = D; d >= 1; d--) {
    if (ST_t[d] == "FUNC") return 0
    if (ST_t[d] == "LOOP") return L_open[ST_v[d]] ? ST_v[d] : 0
  }
  return 0
}
# ${NAME:=…} in a word's raw text (bash assigns it quoted or not), and every
# write inside each (( … )) of its code.
function scanwrites(w, c, k,    t, s, j, dp, nm, m, st) {
  while (match(w, /[$][{][A-Za-z_][A-Za-z0-9_]*:?=/)) {
    nm = substr(w, RSTART + 2, RLENGTH - 2); sub(/:?=$/, "", nm); addwrite(nm, "x")
    w = substr(w, RSTART + RLENGTH)
  }
  while ((s = index(c, "((")) > 0) {
    c = substr(c, s + 2); dp = 2
    for (j = 1; j <= length(c) && dp > 0; j++) { t = substr(c, j, 1); if (t == "(") dp++; else if (t == ")") dp-- }
    t = " " substr(c, 1, j - 1); c = substr(c, j)
    while (match(t, ARITH_W)) {
      m = substr(t, RSTART, RLENGTH); st = substr(t, RSTART + RLENGTH - 1); t = substr(t, RSTART + RLENGTH)
      nm = m; sub(/^[^A-Za-z_]+/, "", nm); sub(/[^A-Za-z0-9_].*$/, "", nm)
      if (k == "h") addwrite(nm, k)
      else if (index(m, "++")) addwrite(nm, "i", "1")
      else if (m ~ /[^+][+]=/ && match(st, /^[[:space:]]*[A-Za-z0-9_]+[[:space:]]*([),;]|$)/)) {
        st = substr(st, RSTART, RLENGTH); gsub(/[^A-Za-z0-9_]/, "", st); addwrite(nm, "i", st)
      } else addwrite(nm, "x")
    }
  }
}
# xwrote <scope> <name> <loop> <kinds> — whether a write of one of <kinds>,
# outside <loop>'s own header, sets <name> in <scope>.
function xwrote(sc, nm, id, kinds,    i) {
  for (i = 1; i <= NW; i++) if (W_nm[i] == nm && W_sc[i] == sc && index(kinds, W_k[i]) && W_hd[i] != id) return 1
  return 0
}
function finish_cmd(d,    n, k, W, cw, env, args, j, dur, kill, v, t, s1, kw, x, nk, parts, we) {
  n = CWN[d]; CWN[d] = 0
  if (n == 0) return
  env = ""; k = 1
  while (k <= n && isassign(CWC[d, k])) { env = env (env == "" ? "" : "\034") CWR[d, k]; k++ }
  if (k > n) {
    for (j = 1; j <= n; j++) record_assign(CWR[d, j], "")
    PEND_J = 0; return
  }
  # Wrappers that run a later word as the command, their argument-taking
  # options consumed with them, so `sudo -u x sleep 5` and `taskset -c 0
  # timeout 9 …` are still waits. `command -v` names a command; it runs none.
  # What the command inherits through one: env's and sudo's NAME=value words
  # are its own, `env -u NAME` removes one (\035-NAME), `env -i` and `exec -c`
  # remove all (\035*), and sudo keeps what its policy says, which nothing
  # here can read (\035?) unless -E keeps it all.
  while (k <= n) {
    W = cmdname(CWR[d, k])
    if (W == "command" && k < n && CWR[d, k + 1] ~ /^-[vV]/) break
    if (W == "sudo" || W == "nice" || W == "env" || W == "stdbuf" || W == "ionice" \
        || W == "taskset" || W == "chrt" || W == "exec" || W == "command" || W == "time") {
      k++; we = ""; s1 = (W == "sudo") ? "\034\035?" : ""
      while (k <= n && (CWR[d, k] ~ /^-/ || ((W == "env" || W == "sudo") && isassign(CWC[d, k])))) {
        v = CWR[d, k]
        if (isassign(CWC[d, k])) we = we "\034" v
        else if (W == "sudo" && (v == "-E" || v == "--preserve-env")) s1 = ""
        else if ((W == "env" && (v == "-i" || v == "-" || v == "--ignore-environment")) || (W == "exec" && v ~ /^-[a-z]*c/)) we = we "\034\035*"
        else if (W == "env" && (v == "-u" || v == "--unset") && k < n) we = we "\034\035-" unq(CWR[d, k + 1])
        else if (W == "env" && v ~ /^--unset=/) we = we "\034\035-" substr(v, 9)
        else if (W == "env" && v ~ /^-u./) we = we "\034\035-" substr(v, 3)
        if (wrapopt(W, v)) k++
        k++
      }
      we = s1 we
      if (we != "") env = env (env == "" ? substr(we, 2) : we)
      if (W == "taskset" || W == "chrt") k++
      continue
    }
    if (W == "nohup" || W == "setsid" || W == "builtin") { k++; while (k <= n && CWR[d, k] ~ /^-/) k++; continue }
    break
  }
  if (k > n) { PEND_J = 0; return }
  W = cmdname(CWR[d, k]); cw = k
  args = ""
  for (j = cw + 1; j <= n; j++) args = args (args == "" ? "" : "\034") CWR[d, j]
  if (W == "printf") { for (j = cw + 1; j < n; j++) if (CWR[d, j] == "-v") addwrite(unq(CWR[d, j + 1]), "x") }
  # Every name-shaped word: a superset of the names these write (or unset).
  if (W == "read" || W == "mapfile" || W == "readarray" || W == "getopts" || W == "let" || W == "unset") {
    x = 0; for (j = cw + 1; j <= n; j++) if (W == "unset" && CWR[d, j] ~ /^-[a-z]*f/) x = 1
    if (!x) for (j = cw + 1; j <= n; j++) { v = unq(CWR[d, j]); sub(/[^A-Za-z0-9_].*$/, "", v); addwrite(v, "x") }
  }
  # `declare -r` is readonly and `declare -x` an export, as bash reads them;
  # an export's name reaches the scripts this one runs. `export -n` and
  # `declare +x` take a name out of the environment instead, and a nameref
  # (`declare -n`, `local -n`) writes the name it holds.
  if (W == "local" || W == "readonly" || W == "export" || W == "declare" || W == "typeset") {
    kw = W; x = (W == "export"); nk = 0
    for (j = cw + 1; j <= n; j++) {
      if (W != "local" && CWR[d, j] ~ /^-[A-Za-z]+$/) {
        if (CWR[d, j] ~ /x/) x = 1
        if (W != "export" && CWR[d, j] ~ /r/) kw = "readonly"
      }
      if ((W == "export" && CWR[d, j] ~ /^-[A-Za-z]*n/) || CWR[d, j] ~ /^[+][A-Za-z]*x/) nk = 1
      else if (CWR[d, j] ~ /^-[A-Za-z]*n/) nk = 2
    }
    for (j = cw + 1; j <= n; j++) {
      if (nk == 1 && CWC[d, j] ~ /^[A-Za-z_][A-Za-z0-9_]*([+]?=|$)/) { v = CWR[d, j]; sub(/[+]?=.*$/, "", v); addwrite(v, "x"); continue }
      if (nk == 2 && isassign(CWC[d, j])) addwrite(unq(substr(CWR[d, j], index(CWR[d, j], "=") + 1)), "x")
      if (isassign(CWC[d, j])) { record_assign(CWR[d, j], kw); if (x) addexport(CWR[d, j], 1) }
      else if (x && CWC[d, j] ~ /^[A-Za-z_][A-Za-z0-9_]*$/) addexport(CWR[d, j], 0)
    }
    PEND_J = 0; return
  }
  PEND_J = 0
  if (W == "timeout") {
    dur = ""; kill = "-"
    for (j = cw + 1; j <= n; j++) {
      v = CWR[d, j]
      if (v ~ /^--kill-after=/) { kill = substr(v, 14); continue }
      if (v == "-k" || v == "--kill-after" || v == "-s" || v == "--signal") {
        if (v == "-k" || v == "--kill-after") kill = CWR[d, j + 1]
        j++; continue
      }
      if (v ~ /^-k./) { kill = substr(v, 3); continue }
      if (v ~ /^--signal=|^-s.|^--foreground$|^--preserve-status$|^--verbose$|^-[pfv]+$/) continue
      dur = v; break
    }
    emit("timeout", dur, kill, "", env, args); return
  }
  # `sleep 1 2` sleeps for the sum; one argument is the form this can read.
  if (W == "sleep") { emit("sleep", (n == cw + 1 ? CWR[d, cw + 1] : "?"), "-", "", env, args); return }
  if (W == "read") {
    for (j = cw + 1; j <= n && CWR[d, j] ~ /^-/; j++) {
      v = CWR[d, j]
      if (v ~ /^-[rse]*t$/) { emit("read-t", CWR[d, j + 1], "-", "", env, args); return }
      if (v ~ /^-[rse]*t[0-9]/) { sub(/^-[rse]*t/, "", v); emit("read-t", v, "-", "", env, args); return }
      if (v ~ /^-[A-Za-z]*[adinNpu]$/) j++
    }
  }
  if (W == "iptables" || W == "ip6tables") {
    for (j = cw + 1; j <= n; j++) if (CWR[d, j] == "-w" || CWR[d, j] == "--wait") {
      v = (j < n && CWR[d, j + 1] ~ /^[0-9]/) ? CWR[d, j + 1] : "?"
      emit("lock", v, "-", W, env, args); return
    }
  }
  if (W == "nc" || W == "ncat" || W == "netcat") {
    for (j = cw + 1; j <= n; j++) {
      v = CWR[d, j]
      if (v ~ /^-[A-Za-z]*w$/) { emit("nc-w", CWR[d, j + 1], "-", "", env, args); return }
      if (v ~ /^-[A-Za-z]*w[0-9]/) { sub(/^-[A-Za-z]*w/, "", v); emit("nc-w", v, "-", "", env, args); return }
    }
  }
  if (W == "flutter") {
    for (j = cw + 1; j <= n && CWR[d, j] ~ /^-/; j++) if (CWR[d, j] == "-d" || CWR[d, j] == "--device-id") j++
    s1 = (j <= n) ? unq(CWR[d, j]) : ""
    if (s1 == "drive" || s1 == "test" || s1 == "run") { emit("launch", "flutter-" s1, "-", "", env, args); return }
  }
  # A device-side wait-for, even quoted into `adb shell "…"`; the same words
  # as another command's argument (a grep pattern, a message) are not one.
  if (W == "adb") {
    for (j = cw + 1; j <= n && unq(CWR[d, j]) != "shell"; j++) { }
    t = ""; for (j++; j <= n; j++) t = t " " unq(CWR[d, j])
    if (match(t, /(^|[;&|[:space:]])(sleep|timeout)[[:space:]]+[^[:space:];&|]+/)) {
      t = substr(t, RSTART, RLENGTH); sub(/^[;&|[:space:]]+/, "", t)
      v = t; sub(/[[:space:]].*$/, "", v); sub(/^[^[:space:]]+[[:space:]]+/, "", t)
      emit(v, t, "-", "adb", env, args); return
    }
  }
  if (W == "adb" || W == "am" || W == "cmd") {
    for (j = cw + 1; j <= n; j++) {
      v = unq(CWR[d, j])
      if (match(v, /(^|[[:space:]])wait-for-[a-z-]+/)) {
        v = substr(v, RSTART, RLENGTH); sub(/^[[:space:]]+/, "", v)
        emit("wait-for", v, "-", W, env, args); return
      }
    }
  }
  # Joins and stop files count only where a lane can reach them, which is
  # known at the end (see resolve_events): a --self-test's `wait` joins nothing.
  if (W == "wait") {
    if (cw == n) addevent("W", "*")
    for (j = cw + 1; j <= n; j++) {
      v = CWR[d, j]
      if (v == "-f") continue
      if (v == "-p") { j++; continue }
      if (unq(v) ~ /^[$][{]?[A-Za-z_][A-Za-z0-9_]*[}]?$/) addevent("W", firstvar(v))
      else addevent("W", "*")
    }
    return
  }
  if (W == "shift" || (W == "set" && n > cw && (CWR[d, cw + 1] == "--" || CWR[d, cw + 1] !~ /^[-+]/))) {
    SHIFTED[curscope()] = 1; if (curscope() == "MAIN") addwrite("@", "x"); return
  }
  if (W == "touch") { for (j = cw + 1; j <= n; j++) { t = firstvar(CWR[d, j]); if (t != "") addevent("T", t) }; return }
  if (W == "kill") {
    for (j = cw + 1; j < n; j++) if (CWR[d, j] == "-0") { t = firstvar(CWR[d, j + 1]); if (t != "") addkill0(t) }
    return
  }
  if (W == "bash" || W == "sh") {
    for (j = cw + 1; j <= n; j++) if (CWR[d, j] !~ /^-/) break
    if (j <= n) {
      args = ""; for (k = j + 1; k <= n; k++) args = args (args == "" ? "" : "\034") CWR[d, k]
      emit("script", CWR[d, j], "-", "", env, args)
    } else emit("script", "?", "-", "", env, "")
    return
  }
  if (W == "source" || W == ".") {
    if (EXCL == 0) { SRC_N++; SRC[SRC_N] = script_target(curscope(), CWR[d, cw + 1]) "\t" CWR[d, cw + 1] "\t" LN[CUR_LL] }
    return
  }
  # An EXIT (or 0, or ERR) trap runs inside the deadline: each command of its
  # action is a call, and a wait written into the action string is refused.
  if (W == "trap") {
    if (EXCL > 0) return
    j = cw + 1; if (CWR[d, j] == "--") j++
    v = unq(CWR[d, j]); x = 0
    for (k = j + 1; k <= n; k++) if (unq(CWR[d, k]) ~ /^(SIG)?(EXIT|ERR)$|^0$/) x = 1
    if (!x || v == "" || v == "-") return
    t = v; gsub(/&&|[|][|]|[;&|]/, "\n", t)
    nk = split(t, parts, "\n")
    for (k = 1; k <= nk; k++) {
      s1 = parts[k]; sub(/^[[:space:]]+/, "", s1)
      while (s1 ~ /^[A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*/) sub(/^[A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]*/, "", s1)
      sub(/[[:space:]].*$/, "", s1)
      if (s1 ~ /^(sleep|timeout|read|nc|ncat|netcat|iptables|ip6tables|flutter|wait|bash|sh|source|[.])$/) {
        emit("trap", s1, "-", "", env, ""); return
      }
      if (s1 ~ /^[A-Za-z_][A-Za-z0-9_:.-]*$/) emit("call", s1, "-", "", env, "")
    }
    return
  }
  # A script run by its path, or through a variable that holds one.
  if (W ~ /[.]sh$/ || (CWR[d, cw] ~ /[$]/ && script_target(curscope(), CWR[d, cw]) != "?")) {
    emit("script", CWR[d, cw], "-", "", env, args); return
  }
  if (W ~ /^[A-Za-z_][A-Za-z0-9_:.-]*$/) emit("call", W, "-", "", env, args)
}
function addevent(kind, v) { NEV++; EV_K[NEV] = kind; EV_V[NEV] = v; EV_S[NEV] = curscope(); EV_X[NEV] = (EXCL > 0); EV_B[NEV] = 0 }
# A `wait` or `touch` inside a background job joins or releases nothing on the
# lane's path (a subshell cannot wait for its siblings), and a `wait` on a
# variable that holds no captured PID may hold any: it joins every job.
function resolve_events(    i) {
  for (i = 1; i <= NEV; i++) {
    if (EV_X[i] || EV_B[i] || !(EV_S[i] in REACH)) continue
    if (EV_K[i] == "T") TOUCHED[EV_V[i]] = 1
    else if (EV_V[i] == "*" || !(EV_V[i] in PIDV)) WAITALL = 1
    else WAITED[EV_V[i]] = 1
  }
}
function addkill0(v,    d, s) {
  s = 1
  for (d = 1; d <= D; d++) if (ST_t[d] == "FUNC") s = d + 1
  for (d = s; d <= D; d++) if (ST_t[d] == "LOOP") L_k0[ST_v[d]] = L_k0[ST_v[d]] " " v
}
function background(d,    m) {
  NJ++; J_ln[NJ] = LN[CUR_LL]
  for (m = ST_ls[d] + 1; m <= NI; m++) I_bg[m] = NJ
  for (m = ST_le[d] + 1; m <= NEV; m++) EV_B[m] = 1
  ST_ls[d] = NI; ST_le[d] = NEV; PEND_J = NJ; ANDOR[d] = 0
}
function end_list(d) { finish_cmd(d); ST_ls[d] = NI; ST_le[d] = NEV; CP[d] = 1; FORH[d] = 0; ANDOR[d] = 0 }
function loop_header_end(    d, id) {
  for (d = D; d >= 1; d--) if (ST_t[d] == "LOOP") {
    id = ST_v[d]
    if (L_open[id]) {
      if (L_sll[id] == CUR_LL) L_hdr[id] = substr(RAW[CUR_LL], L_spos[id], TOKPOS - L_spos[id])
      else L_hdr[id] = substr(RAW[L_sll[id]], L_spos[id]) " " substr(RAW[CUR_LL], 1, TOKPOS - 1)
      L_open[id] = 0
    }
    return
  }
}
function parse_line(ll,    k, ty, w, wc, last, skip) {
  CUR_LL = ll
  tokenize(CODE[ll])
  skip = 0; last = ""
  for (k = 1; k <= NT; k++) {
    ty = TT[k]; TOKPOS = TS[k]
    w = substr(RAW[ll], TS[k], TE[k] - TS[k] + 1); wc = substr(CODE[ll], TS[k], TE[k] - TS[k] + 1)
    last = wc
    if (ty == "w") scanwrites(w, wc, FORH[D] ? "h" : "x")
    if (skip > 0) { skip--; continue }
    if (ty == "rt") { if (k < NT && TT[k + 1] == "w") skip = 1; continue }
    if (ty == "rd") continue
    if (ty == "so") { push("SUBST", ""); continue }
    if (ty == "bq") { if (ST_t[D] == "BQ") { finish_cmd(D); pop() } else push("BQ", ""); continue }
    if (ty == "op") {
      if (ST_t[D] == "CASE" && ST_cm[D] == "pat") {
        if (wc == ")") {
          PATX = (PATX == 1 && PATW == 1 && isarg1(ST_sj[D]))
          ST_cm[D] = (PATX ? "armx" : "arm"); if (PATX) { EXCL++; ST_v[D] = LN[ll] }
          PATX = 0; PATW = 0; CP[D] = 1
        }
        continue
      }
      if (wc == ";") { end_list(D); continue }
      if (wc == "&&") { finish_cmd(D); CP[D] = 1; continue }
      if (wc == "||") { finish_cmd(D); CP[D] = 1; ANDOR[D] = 1; continue }
      if (wc == "|" || wc == "|&") { finish_cmd(D); CP[D] = 1; continue }
      if (wc == "&") { finish_cmd(D); background(D); CP[D] = 1; continue }
      if (wc == ";;" || wc == ";&" || wc == ";;&") {
        finish_cmd(D)
        if (ST_t[D] == "CASE") { if (ST_cm[D] == "armx") { EXCL--; exrange(ST_v[D]) }; ST_cm[D] = "pat"; PATX = 0; PATW = 0 }
        continue
      }
      if (wc == "(") {
        if (PENDF != "") { push("FUNC", PENDF); ST_cm[D] = "paren"; FN[PENDF] = LN[ll]; PENDF = "" }
        else push("GROUP", "")
        continue
      }
      if (wc == ")") {
        if (ST_t[D] == "SUBST" || ST_t[D] == "GROUP" || (ST_t[D] == "FUNC" && ST_cm[D] == "paren")) { finish_cmd(D); pop(); CP[D] = 0; continue }
        ERR = ERR "stray ) at line " LN[ll] "; "; continue
      }
      continue
    }
    if (ST_t[D] == "CASE" && ST_cm[D] == "subj") { if (wc == "in") ST_cm[D] = "pat"; else ST_sj[D] = ST_sj[D] w; continue }
    if (ST_t[D] == "CASE" && ST_cm[D] == "pat") {
      if (wc == "esac") { pop(); CP[D] = 0; continue }
      PATW++
      if (unq(w) == "--self-test") PATX++
      continue
    }
    if (FORH[D]) { if (wc == "do") { FORH[D] = 0; loop_header_end(); CP[D] = 1 }; continue }
    if (CP[D]) {
      if (wc ~ /^[A-Za-z_][A-Za-z0-9_:.-]*$/ && k + 2 <= NT && TT[k + 1] == "op" \
          && substr(CODE[ll], TS[k + 1], 1) == "(" && TT[k + 2] == "op" && substr(CODE[ll], TS[k + 2], 1) == ")") {
        PENDF = wc; skip = 2; continue
      }
      if (wc == "function") {
        if (k < NT) { PENDF = substr(CODE[ll], TS[k + 1], TE[k + 1] - TS[k + 1] + 1); sub(/[(][)]$/, "", PENDF); skip = 1 }
        if (k + 3 <= NT && TT[k + 2] == "op" && TT[k + 3] == "op") skip = 3
        continue
      }
      if (wc == "{") {
        if (PENDF != "") { push("FUNC", PENDF); FN[PENDF] = LN[ll]; PENDF = "" }
        else push("BRACE", "")
        continue
      }
      if (wc == "}") { finish_cmd(D); pop(); CP[D] = 0; continue }
      if (wc == "if") {
        push("IF", ""); ST_cm[D] = "cond"
        # `if [[ "${1:-}" == "--self-test" ]]; then` and kin: the branch that
        # runs only under --self-test is not a lane path. Its `else` is. The
        # whole condition must be that one test.
        w = substr(RAW[ll], TS[k])
        if (w ~ SELFTEST_IF) {
          sub(/^if[[:space:]]+([[][[]|[[]|test)[[:space:]]+/, "", w); sub(/[[:space:]].*$/, "", w)
          if (isarg1(w)) { ST_ex[D] = 1; ST_v[D] = LN[ll]; EXCL++ }
        }
        continue
      }
      if (wc == "then") { finish_cmd(D); CP[D] = 1; if (ST_t[D] == "IF") ST_cm[D] = "body"; continue }
      if (wc == "else" || wc == "elif") {
        finish_cmd(D); CP[D] = 1; if (ST_t[D] == "IF") ST_cm[D] = "body"
        if (ST_t[D] == "IF" && ST_ex[D]) { ST_ex[D] = 0; EXCL--; exrange(ST_v[D]) }
        continue
      }
      if (wc == "fi") { finish_cmd(D); if (ST_t[D] == "IF") pop(); else ERR = ERR "stray fi at line " LN[ll] "; "; CP[D] = 0; continue }
      if (wc == "while" || wc == "until" || wc == "for" || wc == "select") {
        if ((wc == "for" || wc == "select") && k < NT && TT[k + 1] == "w") addwrite(substr(CODE[ll], TS[k + 1], TE[k + 1] - TS[k + 1] + 1), "x")
        NLP++; L_ln[NLP] = LN[ll]; L_sll[NLP] = ll; L_spos[NLP] = TE[k] + 1; L_open[NLP] = 1; L_kw[NLP] = wc
        push("LOOP", NLP); if (wc == "for" || wc == "select") FORH[D] = 1
        continue
      }
      if (wc == "do") { finish_cmd(D); loop_header_end(); CP[D] = 1; continue }
      if (wc == "done") { finish_cmd(D); if (ST_t[D] == "LOOP") pop(); else ERR = ERR "stray done at line " LN[ll] "; "; CP[D] = 0; continue }
      if (wc == "case") { push("CASE", ""); ST_cm[D] = "subj"; PATX = 0; PATW = 0; continue }
      if (wc == "esac") { finish_cmd(D); if (ST_t[D] == "CASE") pop(); else ERR = ERR "stray esac at line " LN[ll] "; "; CP[D] = 0; continue }
      if (wc == "!") continue
      if (isassign(wc)) { addword(D, w, wc); continue }
      addword(D, w, wc); CP[D] = 0; continue
    }
    addword(D, w, wc)
  }
  if (last == "&&" || last == "||" || last == "|" || last == "|&") { finish_cmd(D); CP[D] = 1 }
  else if (!(ST_t[D] == "CASE" && ST_cm[D] != "arm" && ST_cm[D] != "armx")) end_list(D)
}

# A loop's governing identifiers: its header's, one local assignment behind
# them (an accumulator such as `waited=$(( waited + P ))` is skipped: it is
# the tick, not the bound), and a positional parameter's caller argument.
function loopdesc(id, sc, cargs,    hdr, syms, n, a, i, x, b, ca, k0, fl, t) {
  hdr = L_hdr[id]; syms = idents(hdr)
  n = split(syms, a, " ")
  for (i = 1; i <= n; i++) {
    x = a[i]
    for (b = 1; b <= LAN[sc, x]; b++)
      if (index(idents(LAV[sc, x, b]), " " x " ") == 0) syms = syms idents(LAV[sc, x, b])
  }
  n = split(syms, a, " ")
  for (i = 1; i <= n; i++) {
    x = a[i]
    if (((sc SUBSEP x) in ALIAS) && cargs != "" && !(sc in SHIFTED)) { split(cargs, ca, "\034"); syms = syms idents(ca[ALIAS[sc, x]]) }
  }
  if (sc == "MAIN" && (index(hdr, "$@") || index(hdr, "$*") || index(hdr, "${@}"))) syms = syms " ARGC "
  k0 = ""; n = split(L_k0[id], a, " ")
  for (i = 1; i <= n; i++) if (a[i] in PIDV) k0 = k0 (k0 == "" ? "" : ",") a[i]
  fl = ""; t = hdr
  while (match(t, /-[ef][[:space:]]+"?[$][{]?[A-Za-z_][A-Za-z0-9_]*/)) {
    x = substr(t, RSTART, RLENGTH); sub(/^-[ef][[:space:]]+"?[$][{]?/, "", x)
    if (x in TOUCHED) fl = fl (fl == "" ? "" : ",") x
    t = substr(t, RSTART + RLENGTH)
  }
  gsub(/[[:space:]]+/, ",", syms); sub(/^,+/, "", syms); sub(/,+$/, "", syms)
  loopbound(id, sc, cargs)
  return L_ln[id] "|" syms "|" k0 "|" fl "|" LBD_E "|" LBD_LE "|" LBD_INC "|" LBD_WALL "|" LBD_INIT
}
# loopbound — what bounds a `while`/`for` loop whose header compares against
# a limit: `(( X < E ))`, `(( X <= E ))`, `for (( …; X < E; … ))`, alone or as
# one `&&` conjunct (an `||`, or a negated comparison, leaves another way to go
# on). Sets LBD_E (E, resolved through the one local `$(( SECONDS + E ))` it
# names or a positional alias to the caller's argument), LBD_LE (1 for <=),
# LBD_INC (how far X moves per pass; "" if unseen or not one value, read as 1,
# the most passes) and LBD_WALL (1 when X or E is wall clock: SECONDS, date).
# A counter both counted and read from the clock is not read at all; nor is
# one that starts anywhere but a whole number set outside the loop, or moves
# any way but its increments (a reset or decrement in the body, arithmetic,
# read, printf -v), a bound the script can move, or a clock it sets.
function loopbound(id, sc, cargs,    hdr, c, lhs, e, b, v, ca, w, pre, ndate, ninc, incs, iv, ln, h, cl) {
  LBD_E = ""; LBD_LE = 0; LBD_INC = ""; LBD_WALL = 0; LBD_INIT = ""
  if (L_kw[id] != "while" && L_kw[id] != "for") return
  hdr = L_hdr[id]
  if (index(hdr, "||")) return
  if (!match(hdr, /[A-Za-z_][A-Za-z0-9_]*[[:space:]]*<=?[[:space:]]*[^;&|)<>]+/)) return
  c = substr(hdr, RSTART, RLENGTH)
  pre = substr(hdr, 1, RSTART - 1); sub(/^.*&&/, "", pre)
  if (index(pre, "!")) return
  lhs = c; sub(/[[:space:]]*<.*$/, "", lhs)
  LBD_LE = (c ~ /<=/)
  e = c; sub(/^[^<]*<=?[[:space:]]*/, "", e); sub(/[[:space:]]+$/, "", e); gsub(/[${}"]/, "", e)
  ndate = (lhs == "SECONDS"); ninc = 0; incs = ""
  if (xwrote(sc, lhs, id, "x") || (ndate && SECW)) return
  for (b = 1; b <= LAN[sc, lhs]; b++) {
    v = LAV[sc, lhs, b]; ln = LAL[sc, lhs, b]
    if (index(v, "date") || index(v, "SECONDS")) { ndate++; continue }
    if (index(idents(v), " " lhs " ") && match(v, /[+][[:space:]]*[^)]+/)) {
      w = substr(v, RSTART + 1, RLENGTH - 1); gsub(/[${}" ]/, "", w)
      if (ninc == 0) incs = w; else if (w != incs) incs = ""
      ninc++; continue
    }
    # The counter's start: the least whole number it is set to outside the loop.
    iv = v; gsub(/"/, "", iv)
    if (iv !~ /^[0-9]+$/ || (ln > L_ln[id] && ln <= L_end[id])) return
    if (LBD_INIT == "" || iv + 0 < LBD_INIT + 0) LBD_INIT = iv
  }
  for (b = 1; b <= NW; b++) if (W_nm[b] == lhs && W_sc[b] == sc && W_k[b] == "i" && W_hd[b] != id) {
    w = W_st[b]; if (ninc == 0) incs = w; else if (w != incs) incs = ""; ninc++
  }
  if (L_kw[id] == "for") {
    # `for (( start; test; step ))`: a whole-number start, and ++ or += a
    # constant or nothing as its step.
    h = hdr
    if (!sub(/^[[:space:]]*[(][(]/, "", h) || split(h, cl, ";") < 3) return
    gsub(/[[:space:]]/, "", cl[1]); gsub(/[[:space:]]/, "", cl[3]); sub(/[)][)]$/, "", cl[3])
    if (cl[1] != "") {
      if (cl[1] !~ ("^" lhs "=[0-9]+$")) return
      iv = substr(cl[1], length(lhs) + 2)
      if (LBD_INIT == "" || iv + 0 < LBD_INIT + 0) LBD_INIT = iv
    }
    if (cl[3] == lhs "++" || cl[3] == "++" lhs) w = "1"
    else if (cl[3] ~ ("^" lhs "[+]=[A-Za-z0-9_]+$")) w = substr(cl[3], length(lhs) + 3)
    else if (cl[3] != "") return
    if (cl[3] != "") { if (ninc == 0) incs = w; else if (w != incs) incs = ""; ninc++ }
  } else if (index(hdr, lhs "++") || index(hdr, "++" lhs)) { if (ninc == 0) incs = "1"; else if (incs != "1") incs = ""; ninc++ }
  if (ndate && ninc) return
  LBD_WALL = (ndate > 0); LBD_INC = incs
  if (e ~ /^[A-Za-z_][A-Za-z0-9_]*$/) {
    if (xwrote(sc, e, id, "xi")) return
    for (b = 2; b <= LAN[sc, e]; b++) if (LAV[sc, e, b] != LAV[sc, e, 1]) return
    if ((sc SUBSEP e) in ALIAS) {
      if (cargs == "" || (sc in SHIFTED)) { LBD_E = ""; return }
      e = argword(cargs, ALIAS[sc, e]); gsub(/[${}"]/, "", e)
    } else if (LAN[sc, e] >= 1 && LAV[sc, e, 1] ~ /SECONDS/) {
      if (SECW) return
      v = LAV[sc, e, 1]
      gsub(/[$(){}"]/, "", v)
      if (sub(/^[[:space:]]*SECONDS[[:space:]]*[+][[:space:]]*/, "", v)) {
        LBD_WALL = 1; e = v; sub(/[[:space:]]+$/, "", e)
        if ((sc SUBSEP e) in ALIAS) {
          if (cargs == "" || (sc in SHIFTED)) { LBD_E = ""; return }
          e = argword(cargs, ALIAS[sc, e]); gsub(/[${}"]/, "", e)
        }
      } else e = ""
    }
  }
  if (e !~ /^[A-Za-z0-9_ +*()-]+$/) e = ""
  LBD_E = e
  if (LBD_INIT == "") LBD_INIT = 0
}
# argword <cargs> <N> — the caller's Nth word, or "?" when a split before it
# (or in it) may have moved it.
function argword(cargs, N,    ca, nc, k) {
  nc = split(cargs, ca, "\034")
  for (k = 1; k <= N && k <= nc; k++) if (ca[k] ~ /[$][{]?[@*]/ || unqdollar(ca[k])) return "?"
  return ca[N]
}
function norm(w) {
  w = unq(w)
  if (match(w, /^[$][{]?[A-Za-z_][A-Za-z0-9_]*[}]?/)) { w = substr(w, 1, RLENGTH); gsub(/[${}]/, "", w) }
  return w
}
function script_target(sc, raw,    v, t, val) {
  t = unq(raw)
  if (match(t, /(^|\/)[A-Za-z0-9_.-]+[.]sh$/)) { sub(/^.*\//, "", t); return t }
  v = firstvar(raw)
  if (v == "") return "?"
  val = ((sc SUBSEP v) in LASG) ? LASG[sc, v] : LASG["MAIN", v]
  if (match(val, /[A-Za-z0-9_.-]+[.]sh/)) return substr(val, RSTART, RLENGTH)
  return "?"
}
# The caller's argument words, with any that are this scope's own positional
# parameters replaced by what ITS caller passed.
# A positional the caller's words cannot pin down — after a shift, a "$@", or
# an unquoted expansion at or before it that may split — is the one word "$?",
# which no reading resolves.
function pass_args(sc, raw, cargs,    n, a, i, r, v, ca, nc, k, moved) {
  if (raw == "") return ""
  n = split(raw, a, "\034"); r = ""
  nc = split(cargs, ca, "\034")
  for (i = 1; i <= n; i++) {
    v = firstvar(a[i])
    if (v != "" && ((sc SUBSEP v) in ALIAS) && cargs != "") {
      moved = (sc in SHIFTED)
      for (k = 1; k <= ALIAS[sc, v] && k <= nc; k++) if (ca[k] ~ /[$][{]?[@*]/ || unqdollar(ca[k])) moved = 1
      a[i] = moved ? (dq "$?" dq) : ca[ALIAS[sc, v]]
    }
    r = r (i > 1 ? "\034" : "") a[i]
  }
  return r
}
function visit(sc, prefix, loopsp, bgp, cargs, stk, condp,    inst, n, a, i, m, k, leaf, lp, x, bg, ids, nn, j, waited, pid, cond) {
  inst = ++NINST
  n = split(SCOPE_ITEMS[sc], a, " ")
  for (i = 1; i <= n; i++) {
    m = a[i]
    lp = loopsp
    nn = split(I_lp[m], ids, " ")
    for (j = 1; j <= nn; j++) lp = lp (lp == "" ? "" : ";") loopdesc(ids[j], sc, cargs)
    bg = (bgp != "") ? bgp : (I_bg[m] ? I_bg[m] : "")
    cond = (condp || I_cond[m]) ? 1 : 0
    if (I_k[m] == "call") {
      x = I_a[m]
      if (x in FN) {
        if (!(x in HASW)) continue
        if (index(" " stk " ", " " x " ")) { ERR = ERR "recursive call to " x ", which waits; "; continue }
        k = ++CNT[inst, "call:" x]
        visit(x, prefix x "#" k "/", lp, bg, pass_args(sc, I_args[m], cargs), stk " " x, cond)
        continue
      }
      if (!(x in EXT)) continue
      leaf = "lib:" x
    } else if (I_k[m] == "script") leaf = "bash:" script_target(sc, I_a[m])
    else if (I_k[m] == "lock") leaf = I_c[m] "-w:" norm(I_a[m])
    else if (I_k[m] == "wait-for") leaf = I_a[m]
    else if (I_k[m] == "launch") leaf = "launch:" I_a[m]
    else if (I_k[m] == "trap") leaf = "trap:" I_a[m]
    else leaf = I_k[m] ":" norm(I_a[m])
    k = ++CNT[inst, leaf]
    waited = "-"
    if (bg != "") {
      pid = J_pid[bg]
      if (WAITALL || (pid != "" && (pid in WAITED))) waited = "waited"
      else if (pid == "") waited = "unknown"
      else waited = "free"
    }
    # No field is ever empty: bash `read` with a tab IFS merges empty fields.
    printf "S\t%s%s#%d\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%d\n", prefix, leaf, k, I_k[m], \
      nz(I_k[m] == "script" ? script_target(sc, I_a[m]) : I_a[m]), nz(I_b[m]), I_ln[m], \
      (bg == "" ? "-" : bg ":" J_ln[bg] ":" J_pid[bg]), waited, nz(lp), nz(I_env[m]), nz(pass_args(sc, I_args[m], cargs)), cond
  }
}
END {
  if (sp > 1 || hd != "") { print "E\tthe file ends inside a quoted word or heredoc"; exit 3 }
  D = 0; push("TOP", ""); EXCL = 0; NI = 0; NJ = 0; NLP = 0; NA = 0; NW = 0; PEND_J = 0
  for (ll = 1; ll <= NL; ll++) parse_line(ll)
  finish_cmd(D)
  if (D != 1) ERR = ERR "unclosed " ST_t[D] " at end of file; "
  for (j = 1; j <= NJ; j++) if (J_pid[j] != "") PIDV[J_pid[j]] = 1
  for (m = 1; m <= NI; m++) if (I_k[m] != "call" || (I_a[m] in EXT)) HASW[I_sc[m]] = 1
  for (ch = 1; ch; ) {
    ch = 0
    for (m = 1; m <= NI; m++)
      if (I_k[m] == "call" && (I_a[m] in HASW) && (I_a[m] in FN) && !(I_sc[m] in HASW)) { HASW[I_sc[m]] = 1; ch = 1 }
  }
  nr = split(roots, ra, " ")
  # Reachability ignores whether a function waits, so a wait this analyzer
  # failed to see still lies on a line the second reading covers; and a join
  # or stop file counts only on a reachable, non---self-test line.
  for (r = 1; r <= nr; r++) REACH[ra[r]] = 1
  for (ch = 1; ch; ) {
    ch = 0
    for (m = 1; m <= NI; m++)
      if (I_k[m] == "call" && (I_sc[m] in REACH) && (I_a[m] in FN) && !(I_a[m] in REACH)) { REACH[I_a[m]] = 1; ch = 1 }
  }
  resolve_events()
  # SECONDS is one clock for the whole script: set anywhere, no wall-clock
  # loop is bounded by its header.
  for (i = 1; i <= NA; i++) if (A_nm[i] == "SECONDS") SECW = 1
  for (i = 1; i <= NW; i++) if (W_nm[i] == "SECONDS") SECW = 1
  for (i = 1; i <= NW; i++) if (W_sc[i] == "MAIN" || (W_sc[i] in REACH)) print "WR\t" W_nm[i] "\t" W_ln[i]
  for (f in FN) print "F\t" f
  for (i = 1; i <= NA; i++) if (A_sc[i] == "MAIN") print "A\t" A_nm[i] "\t" (A_v[i] == "" ? dq dq : A_v[i]) "\t" nz(A_kw[i]) "\t" A_ln[i]
  for (i = 1; i <= SRC_N; i++) print "SRC\t" SRC[i]
  for (i = 1; i <= NEX; i++) if (EX_sc[i] == "MAIN" || (EX_sc[i] in REACH)) print "X\t" EX_nm[i] "\t" EX_sc[i] "\t" EX_v[i]
  for (r = 1; r <= nr; r++) {
    if (ra[r] != "MAIN" && !(ra[r] in FN)) { ERR = ERR "no function " ra[r] "; "; continue }
    visit(ra[r], (ra[r] == "MAIN" ? "" : ra[r] "/"), "", "", "", ra[r], 0)
  }
  # The second reading's map: reachable and unreachable functions, the
  # --self-test regions, and whether the top level is a root.
  for (f in FN) print "RNG\t" ((f in REACH) ? "F" : "U") "\t" FN[f] "\t" FN_E[f]
  for (m = 1; m <= NI; m++) if (I_k[m] ~ /^(sleep|timeout|read-t|nc-w|lock|wait-for|launch)$/) LCN[I_ln[m]]++
  for (i in LCN) print "LC\t" i "\t" LCN[i]
  for (i = 1; i <= NX; i++) print "RNG\tX\t" X_S[i] "\t" X_E[i]
  if ("MAIN" in REACH) print "RNG\tM\t0\t0"
  if (ERR != "") { print "E\t" ERR; exit 3 }
}
AWK
)

# ---------------------------------------------------------------------------
# Values
# ---------------------------------------------------------------------------

# lb_secs <word> -> seconds for a literal duration as `sleep`/`timeout` read
# it (a bare number is SECONDS; a fraction rounds up), or "".
lb_secs() {
  local t="$1" i f u num den
  [[ "${t}" =~ ^([0-9]+)(\.([0-9]+))?([smhd]?)$ ]] || { echo ""; return; }
  i="${BASH_REMATCH[1]}"; f="${BASH_REMATCH[3]}"; u="${BASH_REMATCH[4]}"
  case "${u}" in ""|s) u=1 ;; m) u=60 ;; h) u=3600 ;; d) u=86400 ;; esac
  den=1; num=$(( 10#${i} ))
  if [[ -n "${f}" ]]; then
    den=$(( 10 ** ${#f} )); num=$(( 10#${i} * den + 10#${f} ))
  fi
  echo $(( (num * u + den - 1) / den ))
}

# ---------------------------------------------------------------------------
# Units: scripts and sourced libraries, analysed once each.
# ---------------------------------------------------------------------------
declare -A LB_U_DONE=() LB_U_SITES=() LB_U_LIBS=() LB_U_EXPORTS=() LB_U_FUNCS=()
declare -A LB_ASG=() LB_ASGN=() LB_ASGKW=() LB_ASGL=() LB_EXPF=() LB_L_WF=() LB_READ=() LB_LIBCALL=() LB_WR=()

# lb_load_unit <root> <rel> <unit|lib>. A file the analyzer cannot read is the
# check being unable to run (rc 2), never a pass.
lb_load_unit() {
  local root="$1" rel="$2" kind="$3" key="$3:$2" out rc=0 rec a b c d srcs=() lib ext="" f roots
  if [[ -n "${LB_U_DONE[${key}]:-}" ]]; then return 0; fi
  LB_U_DONE["${key}"]=1
  if [[ ! -f "${root}/${rel}" ]]; then
    lb_violation "missing:${rel}" "${rel} is run inside a deadline but does not exist."
    LB_U_SITES["${key}"]=""
    return 0
  fi
  out="$(awk -v roots="" -v ext="" "${LB_AWK}" "${root}/${rel}")" || rc=$?
  if (( rc != 0 )); then
    lb_die "cannot read ${rel}: $(sed -n 's/^E\t//p' <<<"${out}")"
  fi
  while IFS=$'\t' read -r rec a b c d; do
    case "${rec}" in
      F) LB_U_FUNCS["${key}"]+="${a} " ;;
      A)
        if [[ -n "${LB_ASG[${rel}|${a}]+x}" && "${LB_ASG[${rel}|${a}]}" != "${b}" ]]; then
          LB_ASGN["${rel}|${a}"]=2
        fi
        LB_ASG["${rel}|${a}"]="${b}"
        [[ -n "${LB_ASGL[${rel}|${a}]:-}" ]] || LB_ASGL["${rel}|${a}"]="${d}"
        if [[ "${c}" == readonly ]]; then LB_ASGKW["${rel}|${a}"]=readonly; fi ;;
      SRC)
        # A library the analyzer cannot name, or one outside tooling/e2e/ci,
        # would add its functions' waits unseen.
        if [[ "${a}" == "?" ]]; then
          [[ "${b}" != *'$'* ]] || lb_die "${rel}:${c}: sources ${b}, which this check cannot resolve to a file"
          continue
        fi
        [[ -f "${root}/tooling/e2e/ci/${a}" ]] || lb_die "${rel}:${c}: sources ${b}, which is not a script in tooling/e2e/ci"
        srcs+=("${a}") ;;
    esac
  done <<<"${out}"
  # A library a library sources is loaded too, so a call between the two
  # is seen (lb_lib_to_lib).
  for f in ${srcs[@]+"${srcs[@]}"}; do
    lib="tooling/e2e/ci/${f}"
    lb_load_unit "${root}" "${lib}" lib
    if [[ "${kind}" == "unit" ]]; then
      LB_U_LIBS["${key}"]+="${lib} "
      ext+="${LB_U_FUNCS[lib:${lib}]:-} "
    fi
  done
  if [[ "${kind}" == "unit" ]]; then roots="MAIN"; else roots="${LB_U_FUNCS[${key}]:-}"; fi
  rc=0
  out="$(awk -v roots="${roots}" -v ext="${ext}" "${LB_AWK}" "${root}/${rel}")" || rc=$?
  if (( rc != 0 )); then
    lb_die "cannot read ${rel}: $(sed -n 's/^E\t//p' <<<"${out}")"
  fi
  LB_U_SITES["${key}"]="$(sed -n 's/^S\t//p' <<<"${out}")"
  while IFS=$'\t' read -r rec a b c; do
    case "${rec}" in
      X)
        LB_U_EXPORTS["${key}"]+="${a} "
        if [[ "${b}" != MAIN && "${c}" == 1 ]]; then LB_EXPF["${rel}|${a}"]=1; fi ;;
      WR) LB_WR["${rel}|${a}"]+="${b} " ;;
    esac
  done <<<"${out}"
  if [[ "${kind}" == "lib" ]]; then
    for f in ${roots}; do
      if [[ $'\n'"${LB_U_SITES[${key}]}" == *$'\n'"${f}/"* ]]; then LB_L_WF["${rel}"]+="${f} "; fi
    done
    # Its top level runs wherever it is sourced, and no budget reads it.
    rc=0
    out="$(awk -v roots=MAIN -v ext="" "${LB_AWK}" "${root}/${rel}")" || rc=$?
    (( rc == 0 )) || lb_die "cannot read ${rel}: $(sed -n 's/^E\t//p' <<<"${out}")"
    while IFS=$'\t' read -r a b c d; do
      [[ "${a}" == S ]] || continue
      lb_violation "libtop:${rel}|${b}" "${rel}: ${b} waits at the library's top level, which runs wherever it is sourced and is on no lane's budget. Move it into a function a lane calls."
    done <<<"${out}"
  fi
}

# ---------------------------------------------------------------------------
# The manifest
# ---------------------------------------------------------------------------
declare -A LB_SEC=() LB_DECL=() LB_DECL_LN=() LB_DECL_HIT=() LB_SEC_HIT=()
declare -a LB_C_SEC=() LB_C_LABEL=() LB_C_PAT=() LB_C_MODE=() LB_C_EXPR=() LB_C_TIMES=()
declare -a LB_C_ONCE=() LB_C_ANCHOR=() LB_C_LN=() LB_C_HIT=()
LB_NC=0

readonly LB_LEAF_RE='(sleep|timeout|read-t|nc-w|iptables-w|ip6tables-w|launch|trap|bash|lib):|wait-for-'

lb_manifest_fail() { lb_die "${LB_MANIFEST_REL}:$1: $2"; }

lb_load_manifest() {
  local file="$1" ln=0 line sec="" w n i mode lab pat rest expr times once anchor part tok
  [[ -f "${file}" ]] || lb_die "missing ${LB_MANIFEST_REL}"
  while IFS= read -r line || [[ -n "${line}" ]]; do
    ln=$(( ln + 1 ))
    [[ "${line}" =~ ^[[:space:]]*(#|$) ]] && continue
    read -r -a w <<<"${line}"
    n=${#w[@]}
    case "${w[0]}" in
      unit|lib)
        (( n == 2 )) || lb_manifest_fail "${ln}" "\`${w[0]} <path>\` takes exactly one path"
        [[ -z "${LB_SEC[${w[1]}]:-}" ]] || lb_manifest_fail "${ln}" "${w[1]} has two sections"
        sec="${w[1]}"; LB_SEC["${sec}"]="${w[0]}"
        continue ;;
      reaper|unbudgeted)
        (( n >= 4 )) || lb_manifest_fail "${ln}" "\`${w[0]} <workflow>::<job> <reason>\` needs a reason"
        [[ "${w[1]}" == *"::"* ]] || lb_manifest_fail "${ln}" "lane key '${w[1]}' is not <workflow>::<job>"
        [[ -z "${LB_DECL[${w[1]}]:-}" ]] || lb_manifest_fail "${ln}" "${w[1]} is declared twice"
        LB_DECL["${w[1]}"]="${w[0]}"; LB_DECL_LN["${w[1]}"]="${ln}"
        sec=""
        continue ;;
      allowance)
        lb_manifest_fail "${ln}" "the unbounded-work allowance is UNBOUNDED_WORK_ALLOWANCE_SECS in check_e2e_lane_budget.sh, applied to every lane alike; a lane cannot carry its own" ;;
    esac
    [[ -n "${sec}" ]] || lb_manifest_fail "${ln}" "a claim outside any \`unit\`/\`lib\` section"
    (( n >= 3 )) || lb_manifest_fail "${ln}" "a claim is <label> <pattern> <mode> …"
    lab="${w[0]}"; pat="${w[1]}"; mode="${w[2]}"
    [[ "${lab}" =~ ^[a-z][a-z0-9-]*$ ]] || lb_manifest_fail "${ln}" "label '${lab}' must be lower-case words joined by -"
    for (( i = 0; i < LB_NC; i++ )); do
      if [[ "${LB_C_SEC[i]}" == "${sec}" && "${LB_C_LABEL[i]}" == "${lab}" ]]; then
        lb_manifest_fail "${ln}" "label '${lab}' is used twice in ${sec}"
      fi
    done
    # The last segment names the kind of wait, so no pattern can be a bare `*`
    # that silently swallows every wait a script gains later.
    [[ "${pat##*/}" =~ ^(${LB_LEAF_RE}) ]] \
      || lb_manifest_fail "${ln}" "pattern '${pat}' must end in a wait leaf (sleep:, timeout:, bash:, lib:, wait-for-, …)"
    expr=""; times=""; once=""; anchor=""
    rest=("${w[@]:3}")
    case "${mode}" in
      charge|poll)
        part=expr
        for tok in ${rest[@]+"${rest[@]}"}; do
          if [[ "${part}" != once && "${tok}" == times ]]; then part=times; continue; fi
          if [[ "${part}" != once && "${tok}" == once ]]; then part=once; continue; fi
          case "${part}" in
            expr) expr+="${tok} " ;;
            times) times+="${tok} " ;;
            once) once+="${tok} " ;;
          esac
        done
        if [[ "${mode}" == charge ]]; then
          lb_grammar "${expr}" || lb_manifest_fail "${ln}" "charge '${expr}' is not an expression of constants, integers, @ and + - * ( )"
        elif [[ -n "${expr// /}" ]]; then
          lb_manifest_fail "${ln}" "poll charges the wait's own bound; it takes no expression"
        fi
        if [[ -n "${times// /}" ]] && ! lb_grammar "${times}"; then
          lb_manifest_fail "${ln}" "times '${times}' is not an expression"
        fi
        if [[ "${part}" == once && -z "${once// /}" ]]; then
          lb_manifest_fail "${ln}" "\`once\` must say why the loop cannot repeat this wait"
        fi ;;
      within)
        (( n >= 5 )) || lb_manifest_fail "${ln}" "\`within <label> <reason>\` needs the label of the wait whose window contains this one, and why"
        anchor="${rest[0]}" ;;
      excluded)
        (( n >= 5 )) || lb_manifest_fail "${ln}" "\`excluded <reason>\` needs a reason of more than one word" ;;
      concurrent|allowance)
        (( n == 3 )) || lb_manifest_fail "${ln}" "\`${mode}\` takes no arguments" ;;
      *) lb_manifest_fail "${ln}" "unknown mode '${mode}'" ;;
    esac
    LB_C_SEC[LB_NC]="${sec}"; LB_C_LABEL[LB_NC]="${lab}"; LB_C_PAT[LB_NC]="${pat}"
    LB_C_MODE[LB_NC]="${mode}"; LB_C_EXPR[LB_NC]="${expr% }"; LB_C_TIMES[LB_NC]="${times% }"
    LB_C_ONCE[LB_NC]="${once% }"; LB_C_ANCHOR[LB_NC]="${anchor}"
    LB_C_LN[LB_NC]="${ln}"; LB_C_HIT[LB_NC]=0
    LB_NC=$(( LB_NC + 1 ))
  done <"${file}"
}

# ---------------------------------------------------------------------------
# Workflows: env and GitHub expressions
# ---------------------------------------------------------------------------

# lb_extract_env <workflow> -> "scope<TAB>key<TAB>value" for the workflow's,
# each job's and each step's `env:` mapping (scope "wf", "job:<id>",
# "step:<id>:<step name>"), on the same indentation extract_steps assumes. A
# block scalar (`KEY: |`, `KEY: >-`) is folded as YAML folds it, its newlines
# written `\n`, and the keys after it are still read. An `env:` this cannot
# read (flow style, an expression) is an "E" line: the check cannot run.
lb_extract_env() {
  awk '
    function val(v,    f, l) {
      sub(/^[^:]*:[[:space:]]*/, "", v)
      f = substr(v, 1, 1); l = substr(v, length(v), 1)
      if (length(v) >= 2 && f == l && (f == sprintf("%c", 34) || f == sprintf("%c", 39))) v = substr(v, 2, length(v) - 2)
      else sub(/[[:space:]]+#.*$/, "", v)
      return v
    }
    function key(v) { sub(/^[[:space:]]*/, "", v); sub(/:.*$/, "", v); return v }
    function rep(t, n,    r) { r = ""; while (n-- > 0) r = r t; return r }
    function put(sc, k, v, ind) {
      if (v ~ /^[|>][-+0-9]*$/) {
        blk = substr(v, 1, 1); bch = (v ~ /-/) ? "-" : ((v ~ /[+]/) ? "+" : "")
        bsc = sc; bkey = k; bki = ind; bci = -1; bv = ""; bhave = 0; pend = 0
        return
      }
      print sc "\t" k "\t" v
    }
    function flush() {
      print bsc "\t" bkey "\t" bv (bch == "-" ? "" : (bch == "+" ? rep("\\n", pend + 1) : "\\n"))
      blk = ""
    }
    blk != "" {
      if ($0 ~ /^[[:space:]]*$/) { pend++; next }
      match($0, /^ */); ind = RLENGTH
      if (ind > bki && (bci < 0 || ind >= bci)) {
        if (bci < 0) bci = ind
        t = substr($0, bci + 1)
        if (!bhave) { bv = t; bhave = 1 }
        else if (blk == "|") bv = bv rep("\\n", pend + 1) t
        else bv = bv (pend > 0 ? rep("\\n", pend) : " ") t
        pend = 0; next
      }
      flush()
    }
    /^[[:space:]]*(#|$)/ { next }
    # Inside a mapping: its keys sit at the indentation of the first key,
    # and a line no deeper than `env:` ends it.
    mode != "" {
      match($0, /^ */); ind = RLENGTH
      if (ind > envind) {
        if (keyind < 0) keyind = ind
        if (ind == keyind && $0 ~ /^ *[A-Za-z_][A-Za-z0-9_]*:/) put(mode, key($0), val($0), ind)
        next
      }
      mode = ""
    }
    /^(    |        )?env:[[:space:]]*[^[:space:]#]/ { print "E\t" NR "\t" $0; next }
    /^env:[[:space:]]*(#.*)?$/ { mode = "wf"; envind = 0; keyind = -1; next }
    /^[A-Za-z_]/ { injobs = ($0 ~ /^jobs:/); next }
    injobs && /^  [A-Za-z_][A-Za-z0-9_.-]*:[[:space:]]*(#.*)?$/ { job = key($0); next }
    injobs && /^    env:[[:space:]]*(#.*)?$/ { mode = "job:" job; envind = 4; keyind = -1; next }
    injobs && /^      - / {
      step = "(unnamed)"
      if ($0 ~ /^      - name:[[:space:]]*/) { step = $0; sub(/^      - name:[[:space:]]*/, "", step) }
      next
    }
    injobs && /^        env:[[:space:]]*(#.*)?$/ { mode = "step:" job ":" step; envind = 8; keyind = -1; next }
    END { if (blk != "") flush() }
  ' "$1"
}

# A value taken from a workflow carries a status: "<n>[.<id>…]", n 0 exact,
# 1 an input's default (`x || 'lit'`), 2 unknowable; each id names a
# `${{ c && A || B }}` condition that chose it. A lane reads both branches
# paired positionally, as the ordering guard does, which is sound only while
# every such value the lane actually reads is chosen by one condition: the
# conditions consumed are collected in LB_CONDS and compared per lane.
declare -A LB_CONDID=() LB_CONDS=()
declare -a LB_CONDTXT=()
lb_cond_id() {
  local c="${1//[[:space:]]/ }"
  while [[ "${c}" == *"  "* ]]; do c="${c//  / }"; done
  c="${c# }"; c="${c% }"
  if [[ -z "${LB_CONDID[${c}]:-}" ]]; then
    LB_CONDTXT+=("${c}"); LB_CONDID["${c}"]="$(( ${#LB_CONDTXT[@]} - 1 ))"
  fi
  LB_CID="${LB_CONDID[${c}]}"
}
lb_st_max() { # <status> <status> -> LB_STJ
  local a="$1" b="$2" n id
  local -A seen=()
  n="${a%%.*}"; (( ${b%%.*} > n )) && n="${b%%.*}"
  LB_STJ="${n}"
  a="${a#"${a%%.*}"}${b#"${b%%.*}"}"
  for id in ${a//./ }; do
    [[ -n "${seen[${id}]:-}" ]] && continue
    seen["${id}"]=1; LB_STJ+=".${id}"
  done
}
lb_st_use() { # <status> -> LB_STN; the conditions it names become consumed
  local s="$1" id rest
  LB_STN="${s%%.*}"; rest="${s#"${LB_STN}"}"
  for id in ${rest//./ }; do LB_CONDS["${LB_CONDTXT[id]}"]=1; done
}

# lb_ghexpr <inner> <branch 0|1> [depth] — the value of one `${{ … }}`, into
# LB_GH with its status in LB_GHST.
declare -A LB_WENV=()
lb_ghexpr() {
  local e="$1" br="$2" depth="${3:-0}" c t
  e="${e#"${e%%[![:space:]]*}"}"; e="${e%"${e##*[![:space:]]}"}"
  LB_GH=""; LB_GHST=2
  if [[ "${e}" =~ ^(.+)\&\&[[:space:]]*(\'[^\']*\'|[A-Za-z0-9_.-]+)[[:space:]]*\|\|[[:space:]]*(\'[^\']*\'|[A-Za-z0-9_.-]+)$ ]]; then
    c="${BASH_REMATCH[1]}"; t="${BASH_REMATCH[2]}"; LB_GH="${BASH_REMATCH[3]}"
    # `c && A || B` is B whenever A is falsy ('', 0, false, null), as GitHub
    # evaluates it: that branch never yields A.
    if (( br == 0 )) && [[ ! "${t}" =~ ^(\'\'|0|false|null)$ ]]; then LB_GH="${t}"; fi
    LB_GH="${LB_GH#\'}"; LB_GH="${LB_GH%\'}"
    lb_cond_id "${c}"; LB_GHST="0.${LB_CID}"
    return 0
  fi
  if [[ "${e}" =~ ^env\.([A-Za-z_][A-Za-z0-9_]*)$ ]] && [[ -n "${LB_WENV[${BASH_REMATCH[1]}]+x}" ]] && (( depth < 4 )); then
    lb_resolve_gh "${LB_WENV[${BASH_REMATCH[1]}]}" "${br}" $(( depth + 1 ))
    return 0
  fi
  if [[ "${e}" =~ \|\|[[:space:]]*\'([^\']*)\'$ ]]; then
    LB_GH="${BASH_REMATCH[1]}"; LB_GHST=1; return 0
  fi
  LB_GH="\${{ ${e} }}"; LB_GHST=2
}

# lb_resolve_gh <text> <branch> [depth] [mark] — every `${{ … }}` in <text>
# replaced, the joined status in LB_GHST. With <mark> each replacement is
# wrapped as \002<status>\037<value>\003, so lb_lane_cmd can give every word
# of a command the status of the expressions it holds.
lb_resolve_gh() {
  local t="$1" br="$2" depth="${3:-0}" mark="${4:-0}" out="" st=0 inner
  while [[ "${t}" == *'${{'* ]]; do
    out+="${t%%'${{'*}"; t="${t#*'${{'}"
    inner="${t%%'}}'*}"; t="${t#*'}}'}"
    lb_ghexpr "${inner}" "${br}" "${depth}"
    if (( mark )); then out+=$'\002'"${LB_GHST}"$'\037'"${LB_GH}"$'\003'; else out+="${LB_GH}"; fi
    lb_st_max "${st}" "${LB_GHST}"; st="${LB_STJ}"
  done
  LB_GH="${out}${t}"; LB_GHST="${st}"
}

# lb_unmark_word <word> -> LB_UW without markers, LB_UST the joined status of
# every expression the word holds part of. A value with a space in it is split
# across words, so a marker still open at a word's end (LB_MOPEN) carries on.
readonly LB_MARK_RE=$'^([^\002\003]*)([\002\003])(.*)$'
LB_MOPEN=""
lb_unmark_word() {
  local w="$1" out="" st=0 s
  if [[ -n "${LB_MOPEN}" ]]; then st="${LB_MOPEN}"; fi
  while [[ "${w}" =~ ${LB_MARK_RE} ]]; do
    out+="${BASH_REMATCH[1]}"; w="${BASH_REMATCH[3]}"
    if [[ "${BASH_REMATCH[2]}" == $'\003' ]]; then LB_MOPEN=""; continue; fi
    s="${w%%$'\037'*}"; w="${w#*$'\037'}"
    LB_MOPEN="${s}"; lb_st_max "${st}" "${s}"; st="${LB_STJ}"
  done
  LB_UW="${out}${w}"; LB_UST="${st}"
}

# lb_words <text> -> one token per line: "W<word>" with quotes removed ("V"
# when the word holds an expansion outside quotes, which the shell may split
# into several), or "O<op>" for && || ; | & ( ). Enough shell to read a step's
# command line.
lb_words() {
  awk '
    BEGIN { sq = sprintf("%c", 39); dq = sprintf("%c", 34) }
    function flush() { if (have) print (split_ ? "V" : "W") w; w = ""; have = 0; split_ = 0 }
    {
      s = $0; n = length(s); w = ""; have = 0; q = ""; split_ = 0
      for (i = 1; i <= n; i++) {
        c = substr(s, i, 1)
        if (q != "") { if (c == q) q = ""; else w = w c; continue }
        if (c == sq || c == dq) { q = c; have = 1; continue }
        if (c == "$") split_ = 1
        if (c == "\\" && i < n) { w = w substr(s, i + 1, 1); have = 1; i++; continue }
        if (c == " " || c == "\t") { flush(); continue }
        if (substr(s, i, 2) == "&&" || substr(s, i, 2) == "||") { flush(); print "O" substr(s, i, 2); i++; continue }
        if (c == ";" || c == "|" || c == "&" || c == "(" || c == ")") { flush(); print "O" c; continue }
        w = w c; have = 1
      }
      if (q != "") { print "E"; exit }
      flush()
    }' <<<"$1"
}

# ---------------------------------------------------------------------------
# Budgets
# ---------------------------------------------------------------------------

declare -A LB_INPROG=()
# lb_const <rel> <NAME> -> LB_V (seconds, or a count), 0/1. The value comes
# from the definition the script itself runs: a literal, `${ENV:-default}`
# with ENV from the caller, `$N` from the arguments, or `$(( … ))` over other
# constants. Reads LENV/LENVS/LARGS/LCONST/LWF of the calling lb_budget. Under
# LB_STRICT (a name a charge, a bound or a loop names, and every script
# constant its definition reads, transitively) the definition must be
# `readonly`, so no function, `printf -v`, `(( X = … ))` or `local` can change
# what was read.
lb_const() {
  local rel="$1" name="$2" raw strict="${LB_STRICT:-0}"
  # A count is only as good as the words counted: an argument whose value this
  # check cannot vouch for may be one word, or several.
  if [[ "${name}" == ARGC ]]; then
    local i
    if (( LARGCU )); then LB_WHY="ARGC: which words the arguments are depends on a \"\$@\" or an unquoted expansion this check cannot split"; return 1; fi
    if lb_rewritten "${rel}" "@"; then LB_WHY="ARGC: ${LB_WHY/writes @ itself/moves the positional arguments} (shift, set), so a loop over them sees fewer than it was given"; return 1; fi
    for (( i = 0; i < ${#LARGS[@]}; i++ )); do lb_arg "${i}" ARGC || return 1; done
    LB_V="${#LARGS[@]}"; return 0
  fi
  if [[ -z "${LB_ASG[${rel}|${name}]+x}" ]]; then
    LB_WHY="${name} has no top-level definition in ${rel}"; return 1
  fi
  if [[ "${LB_ASGN[${rel}|${name}]:-1}" != 1 ]]; then
    LB_WHY="${name} is defined more than once, with different values, in ${rel}"; return 1
  fi
  if (( strict )) && [[ "${LB_ASGKW[${rel}|${name}]:-}" != readonly ]]; then
    LB_WHY="${name} in ${rel} is not readonly, so the script could change the value this check reads"; return 1
  fi
  if (( ! strict )) && [[ -n "${LCONST[${name}]+x}" ]]; then LB_V="${LCONST[${name}]}"; return 0; fi
  if [[ -n "${LB_INPROG[${rel}|${name}]:-}" ]]; then LB_WHY="${name}'s definition in ${rel} refers to itself"; return 1; fi
  raw="${LB_ASG[${rel}|${name}]}"
  LB_INPROG["${rel}|${name}"]=1
  if ! lb_value "${rel}" "${raw}" "${name}"; then LB_STRICT="${strict}"; unset "LB_INPROG[${rel}|${name}]"; return 1; fi
  LB_STRICT="${strict}"; unset "LB_INPROG[${rel}|${name}]"
  (( strict )) || LCONST["${name}"]="${LB_V}"
}

# lb_before <rel> <NAME> <WHO> — 0 iff <NAME> is another of the script's
# top-level constants, defined on a line before <WHO>'s definition.
lb_before() {
  [[ "$2" != "$3" && -n "${LB_ASG[$1|$2]+x}" ]] || return 1
  (( ${LB_ASGL[$1|$2]:-0} < ${LB_ASGL[$1|$3]:-0} ))
}

# lb_rewritten <rel> <NAME> [<after> <before>] — 0 iff <rel> writes NAME some
# way other than a top-level NAME=value (a function's assignment, printf -v,
# read, ${NAME:=…}, unset, export -n, …) on a line after <after> and before
# <before> (anywhere, without them), or a library it sources writes it at all:
# then what the caller passed is not what the script reads. LB_WHY says where.
lb_rewritten() {
  local rel="$1" name="$2" after="${3:-0}" before="${4:-}" l u
  for l in ${LB_WR[${rel}|${name}]:-}; do
    if (( l > after )) && { [[ -z "${before}" ]] || (( l < before )); }; then
      LB_WHY="${rel}:${l} writes ${name} itself"; return 0
    fi
  done
  for u in ${LB_U_LIBS[unit:${rel}]:-}; do
    if [[ -n "${LB_WR[${u}|${name}]:-}" ]]; then
      LB_WHY="${u}:${LB_WR[${u}|${name}]%% *}, which ${rel} sources, writes ${name}"; return 0
    fi
  done
  return 1
}

# lb_unwritten <rel> <NAME> <WHO> — 0 iff nothing writes NAME, other than the
# top-level definition lb_before reads, between that definition (or the start)
# and WHO's; else rc 1 with LB_WHY.
lb_unwritten() {
  local from=0
  if lb_before "$1" "$2" "$3"; then from="${LB_ASGL[$1|$2]}"; fi
  lb_rewritten "$1" "$2" "${from}" "${LB_ASGL[$1|$3]:-}" || return 0
  LB_WHY="${3} in ${1} reads ${2}, but ${LB_WHY} before that: the value it reads is not one this check can see"
  return 1
}

# lb_env_unknown <env text> — the same names, each at a value nothing here can
# read (a child run behind sudo keeps what its policy says).
lb_env_unknown() {
  local k s v
  while IFS=$'\t' read -r k s v; do
    [[ -z "${k}" ]] || printf '%s\t2\t?\n' "${k}"
  done <<<"$1"
}

# lb_env <NAME> -> LB_S, the string the script would see; rc 1 when unset,
# rc 2 when set in a way this check cannot evaluate. An input's default is a
# value only in a reaper lane, where a larger dispatch only grows a sum that
# already exceeds the deadline; anywhere else a dispatch can pass any value.
lb_env() {
  local name="$1"
  [[ -n "${LENV[${name}]+x}" ]] || return 1
  lb_st_use "${LENVS[${name}]}"
  case "${LB_STN}" in
    0) ;;
    1) if (( ! LB_REAPER )); then
         LB_WHY="${name}='${LENV[${name}]}' is an input's default, and a dispatch can pass any value"; return 2
       fi ;;
    2) LB_WHY="${name}='${LENV[${name}]}' depends on an expression this check cannot evaluate"; return 2 ;;
    *) LB_WHY="${name} is written to GITHUB_ENV in ${LWF}, at run time, where this check cannot see its value"; return 2 ;;
  esac
  LB_S="${LENV[${name}]}"
}

# lb_arg <index> <who> -> LB_S, a positional argument, under the same rule.
lb_arg() {
  local i="$1" who="$2" st v
  if (( LARGCU )); then LB_WHY="${who}: which words the arguments are depends on a \"\$@\" or an unquoted expansion this check cannot split"; return 1; fi
  if (( i >= ${#LARGS[@]} )); then LB_S=""; return 0; fi
  [[ "${LARGS[i]}" =~ ^([0-9](\.[0-9]+)*):(.*)$ ]] || lb_die "internal: argument '${LARGS[i]}' carries no status"
  st="${BASH_REMATCH[1]}"; v="${BASH_REMATCH[3]}"
  lb_st_use "${st}"
  if (( LB_STN >= 2 )) || { (( LB_STN == 1 )) && (( ! LB_REAPER )); }; then
    LB_WHY="${who}: argument $(( i + 1 )) ('${v}') depends on an expression or input this check cannot evaluate"
    return 1
  fi
  LB_S="${v}"
}

lb_value() {
  local rel="$1" v="$2" who="$3" name def s rc
  if [[ "${v}" == \"*\" ]]; then v="${v#\"}"; v="${v%\"}"; fi
  if [[ "${v}" == \'*\' ]]; then v="${v#\'}"; v="${v%\'}"; fi
  s="$(lb_secs "${v}")"
  if [[ -n "${s}" ]]; then LB_V="${s}"; return 0; fi
  if [[ "${v}" =~ ^\$\{([A-Za-z_][A-Za-z0-9_]*):?-(.*)\}$ ]]; then
    name="${BASH_REMATCH[1]}"; def="${BASH_REMATCH[2]}"
    if [[ -n "${LCALLER}" ]] && { [[ -n "${LB_ASG[${LCALLER}|${name}]+x}" ]] || lb_rewritten "${LCALLER}" "${name}"; }; then
      LB_WHY="${who}: ${rel} reads \${${name}:-…}, and ${LCALLER}, which sources it, sets ${name} itself: which value it sees depends on an order this check does not read"
      return 1
    fi
    lb_unwritten "${rel}" "${name}" "${who}" || return 1
    # Another of this script's constants defined before this one, else the
    # environment: a later definition is not yet made when this one runs.
    if lb_before "${rel}" "${name}" "${who}"; then
      if [[ "${LB_ASG[${rel}|${name}]}" != '""' && -n "${LB_ASG[${rel}|${name}]}" ]]; then lb_const "${rel}" "${name}"; return $?; fi
      lb_value "${rel}" "${def}" "${who}"; return $?
    fi
    rc=0; lb_env "${name}" || rc=$?
    if (( rc == 2 )); then return 1; fi
    if (( rc == 0 )) && [[ -n "${LB_S}" ]]; then
      s="$(lb_secs "${LB_S}")"
      [[ -n "${s}" ]] || { LB_WHY="${who}: ${name}='${LB_S}' is not a duration"; return 1; }
      LB_V="${s}"; return 0
    fi
    lb_value "${rel}" "${def}" "${who}"; return $?
  fi
  if [[ "${v}" =~ ^\$\{?([1-9])\}?$|^\$\{([1-9]):?-.*\}$ ]] && lb_rewritten "${rel}" "@" 0 "${LB_ASGL[${rel}|${who}]:-}"; then
    LB_WHY="${who} in ${rel} reads a positional argument, but ${LB_WHY/writes @ itself/moves them (shift, set)} before that"
    return 1
  fi
  if [[ "${v}" =~ ^\$\{?([1-9])\}?$ ]]; then
    lb_arg "$(( BASH_REMATCH[1] - 1 ))" "${who}" || return 1
    lb_value "${rel}" "${LB_S}" "${who}"; return $?
  fi
  if [[ "${v}" =~ ^\$\{([1-9]):?-(.*)\}$ ]]; then
    def="${BASH_REMATCH[2]}"
    lb_arg "$(( BASH_REMATCH[1] - 1 ))" "${who}" || return 1
    [[ -n "${LB_S}" ]] || LB_S="${def}"
    lb_value "${rel}" "${LB_S}" "${who}"; return $?
  fi
  if [[ "${v}" =~ ^\$\(\((.*)\)\)$ ]]; then
    lb_arith "${rel}" "${BASH_REMATCH[1]}" "${who}"; return $?
  fi
  if [[ "${v}" =~ ^\$\{?([A-Za-z_][A-Za-z0-9_]*)\}?$ ]]; then
    name="${BASH_REMATCH[1]}"
    lb_unwritten "${rel}" "${name}" "${who}" || return 1
    if lb_before "${rel}" "${name}" "${who}"; then lb_const "${rel}" "${name}"; return $?; fi
    rc=0; lb_env "${name}" || rc=$?
    if (( rc == 0 )); then lb_value "${rel}" "${LB_S}" "${who}"; return $?; fi
    if (( rc == 2 )); then return 1; fi
  fi
  LB_WHY="${who}='${v}' in ${rel} is not a value this check can evaluate"
  return 1
}

# lb_grammar <expr> — 0 iff <expr> is operands (identifiers, integers with no
# leading zero, `@`) joined by + - * inside balanced parentheses: what bash
# arithmetic evaluates without an error and without reading 09 as octal.
# No division: a budget is a sum of bounds, and integer division is how one
# silently shrinks.
lb_grammar() {
  local e="$1" tok want=operand depth=0
  e="${e//[[:space:]]/}"
  [[ -n "${e}" ]] || return 1
  while [[ -n "${e}" ]]; do
    if [[ "${e}" =~ ^([A-Za-z_][A-Za-z0-9_]*|[1-9][0-9]*|0|@) ]]; then
      [[ "${want}" == operand ]] || return 1
      want=operator
    elif [[ "${e}" =~ ^([-+*]) ]]; then
      [[ "${want}" == operator ]] || return 1
      want=operand
    elif [[ "${e}" =~ ^(\() ]]; then
      [[ "${want}" == operand ]] || return 1
      depth=$(( depth + 1 ))
    elif [[ "${e}" =~ ^(\)) ]]; then
      if [[ "${want}" != operator ]] || (( depth == 0 )); then return 1; fi
      depth=$(( depth - 1 ))
    else
      return 1
    fi
    tok="${BASH_REMATCH[1]}"; e="${e:${#tok}}"
  done
  [[ "${want}" == operator ]] && (( depth == 0 ))
}

# lb_arith <rel> <expr> -> LB_V: identifiers replaced by their constants, then
# bash arithmetic over what is left, once lb_grammar has accepted it — so
# nothing the manifest or a script says is ever executed, and nothing crashes.
lb_arith() {
  local rel="$1" e="$2" who="${3:-}" out="" id
  while [[ "${e}" =~ ^([^A-Za-z_]*)([A-Za-z_][A-Za-z0-9_]*)(.*)$ ]]; do
    out+="${BASH_REMATCH[1]}"; id="${BASH_REMATCH[2]}"; e="${BASH_REMATCH[3]}"
    if [[ -n "${who}" ]] && ! lb_before "${rel}" "${id}" "${who}"; then
      LB_WHY="${who} in ${rel} reads ${id} before any definition of it has run"; return 1
    fi
    lb_const "${rel}" "${id}" || return 1
    out+="${LB_V}"
  done
  out+="${e}"
  if ! lb_grammar "${out}"; then LB_WHY="'${2}' in ${rel} is not plain arithmetic"; return 1; fi
  LB_V=$(( out ))
}

# lb_expr <rel> <expr> <at> -> LB_V: a manifest expression (or a loop's bound)
# over readonly constants; `@` is <at>, the called script's budget.
lb_expr() {
  local rel="$1" e="$2" at="$3" rc=0
  if [[ "${e}" == *@* ]]; then
    [[ -n "${at}" ]] || { LB_WHY="'@' names a called script's budget, and this wait calls none"; return 1; }
    e="${e//@/(${at})}"
  fi
  LB_STRICT=1
  lb_arith "${rel}" "${e}" || rc=$?
  LB_STRICT=0
  return "${rc}"
}

# lb_word <rel> <bound word> -> LB_V seconds, LB_SYM the constant it names.
lb_word() {
  local rel="$1" w="$2" s unit rc=0
  w="${w//\"/}"; w="${w//\'/}"
  LB_SYM=""
  s="$(lb_secs "${w}")"
  if [[ -n "${s}" ]]; then LB_V="${s}"; return 0; fi
  if [[ "${w}" =~ ^\$\{?([A-Za-z_][A-Za-z0-9_]*)\}?([smhd]?)$ ]]; then
    LB_SYM="${BASH_REMATCH[1]}"; unit="${BASH_REMATCH[2]}"
    LB_STRICT=1
    lb_const "${rel}" "${LB_SYM}" || rc=$?
    LB_STRICT=0
    (( rc == 0 )) || return 1
    case "${unit}" in m) LB_V=$(( LB_V * 60 )) ;; h) LB_V=$(( LB_V * 3600 )) ;; d) LB_V=$(( LB_V * 86400 )) ;; esac
    return 0
  fi
  LB_WHY="the bound '${2}' is not a literal or a constant"
  return 1
}

# lb_splits <word> — 0 iff the word holds an expansion outside quotes, which
# may split it into several words.
lb_splits() {
  local w="$1"
  while [[ "${w}" =~ ^(.*)(\"[^\"]*\"|\'[^\']*\')(.*)$ ]]; do w="${BASH_REMATCH[1]}${BASH_REMATCH[3]}"; done
  [[ "${w}" == *'$'* ]]
}

lb_idents() { # <expr...> -> " id id " (with @ as an identifier)
  local e="$*" r=" "
  while [[ "${e}" =~ ([A-Za-z_][A-Za-z0-9_]*|@)(.*)$ ]]; do r+="${BASH_REMATCH[1]} "; e="${BASH_REMATCH[2]}"; done
  printf '%s' "${r}"
}

# lb_positional <rel> <expr> <loop>… — 0 iff <expr> counts the invocation's
# own targets: ARGC, or a constant defined from a positional argument, that
# governs one of the loops around the site. A count on a site no such loop
# repeats is a claim, and one drive claimed twice is still one drive.
lb_positional() {
  local rel="$1" expr="$2" id lp js
  shift 2
  for id in $(lb_idents "${expr}"); do
    [[ "${id}" == ARGC || "${LB_ASG[${rel}|${id}]:-}" =~ ^\"?\$\{?[1-9] ]] || continue
    for lp in "$@"; do
      IFS='|' read -r _ js _ <<<"${lp}"
      [[ ",${js}," != *",${id},"* ]] || return 0
    done
  done
  return 1
}

# lb_loopfloor <rel> <bound> <le> <inc> <wall> <tick> <init> -> LB_V, the most
# time a polling loop can spend in one wait of <tick> seconds. Wall clock
# (SECONDS, date): the bound, plus the tick that can start just before it.
# Counted from <init>: ceil((bound - init) / inc) passes (one more for <=),
# one tick each; an unseen inc is taken as 1, the most passes.
lb_loopfloor() {
  local rel="$1" be="$2" le="$3" inc="$4" wall="$5" p="$6" init="${7:-0}" g i n
  [[ -n "${be}" ]] || { LB_WHY="its bound cannot be read from its header"; return 1; }
  lb_expr "${rel}" "${be}" "" || return 1
  g="${LB_V}"
  if (( wall )); then LB_V=$(( g + le + p )); return 0; fi
  i=1
  if [[ -n "${inc}" ]]; then lb_expr "${rel}" "${inc}" "" || return 1; i="${LB_V}"; fi
  (( i >= 1 )) || { LB_WHY="its step (${inc}) is not positive"; return 1; }
  g=$(( g - init ))
  if (( g < 0 )); then n=0; elif (( le )); then n=$(( g / i + 1 )); else n=$(( (g + i - 1) / i )); fi
  LB_V=$(( n * p ))
}

# lb_bviol <key> <message> — a violation in a lane's sum, which leaves that
# lane INCOMPLETE rather than ok.
lb_bviol() { LB_EVAL_ERR=$(( LB_EVAL_ERR + 1 )); lb_violation "$@"; }

# lb_budget <root> <rel> <unit|lib> <fn|MAIN> <env> <args> <depth> [caller]
#   -> LB_TOT, LB_DRV (drives, counted per target), LB_MAXD (longest drive)
# <env> is "NAME<TAB>status<TAB>value" lines; <args> is \034-separated
# "status:value" words, led by \035 when a "$@" made their count unknowable;
# <caller> is the script that sources <rel>, for a library.
lb_budget() {
  local root="$1" rel="$2" ukind="$3" fn="$4" envtext="$5" argstext="$6" depth="$7" LCALLER="${8:-}"
  local -A LENV=() LENVS=() LCONST=() JOBC=() JOBX=() WSUM=() ACHG=()
  local -a LARGS=() POLLS=()
  local k s v key="${ukind}:${rel}" total=0 drives=0 maxd=0 LARGCU=0
  local path kind b1 b2 line bg waited loops senv sargs scond
  if (( depth > 8 )); then
    lb_bviol "depth:${rel}" "${rel}: scripts call each other more than 8 deep"
    LB_TOT=0; LB_DRV=0; LB_MAXD=0; return 0
  fi
  while IFS=$'\t' read -r k s v; do
    [[ -n "${k}" ]] || continue
    LENV["${k}"]="${v}"; LENVS["${k}"]="${s}"
  done <<<"${envtext}"
  if [[ "${argstext}" == $'\035'* ]]; then LARGCU=1; argstext="${argstext#$'\035'}"; fi
  if [[ -n "${argstext}" ]]; then IFS=$'\034' read -r -a LARGS <<<"${argstext}"; fi
  lb_load_unit "${root}" "${rel}" "${ukind}"
  LB_SEC_HIT["${rel}"]=1
  if [[ -n "${LB_SEC[${rel}]:-}" && "${LB_SEC[${rel}]}" != "${ukind}" ]]; then
    lb_bviol "kind:${rel}" "${LB_MANIFEST_REL}: [${rel}] is a \`${LB_SEC[${rel}]}\` section, but a lane reaches it as a \`${ukind}\`."
  fi
  while IFS=$'\t' read -r path kind b1 b2 line bg waited loops senv sargs scond; do
    [[ -n "${path}" ]] || continue
    [[ "${loops}" != "-" ]] || loops=""
    [[ "${senv}" != "-" ]] || senv=""
    [[ "${sargs}" != "-" ]] || sargs=""
    if [[ "${ukind}" == lib ]]; then
      [[ "${path}" == "${fn}/"* ]] || continue
    fi
    local callee="" at="" cdrv=0 cmax=0 ci=-1 i bgpid=""
    [[ "${bg}" == "-" ]] || bgpid="${bg##*:}"
    # A call into a script or library function that does not wait is not a
    # wait here; one that gains a wait later becomes one.
    if [[ "${kind}" == script ]]; then
      if [[ "${b1}" != "?" ]]; then
        callee="tooling/e2e/ci/${b1}"
        lb_load_unit "${root}" "${callee}" unit
        LB_READ["${callee}"]=1
        [[ -n "${LB_U_SITES[unit:${callee}]:-}" ]] || continue
      fi
    elif [[ "${kind}" == call ]]; then
      local l
      for l in ${LB_U_LIBS[${key}]:-}; do
        if [[ " ${LB_U_FUNCS[lib:${l}]:-} " == *" ${b1} "* ]]; then callee="${l}"; fi
      done
      [[ -n "${callee}" ]] || continue
      [[ " ${LB_LIBCALL[${callee}]:-} " == *" ${b1} "* ]] || LB_LIBCALL["${callee}"]+=" ${b1}"
      [[ " ${LB_L_WF[${callee}]:-} " == *" ${b1} "* ]] || continue
    fi
    for (( i = 0; i < LB_NC; i++ )); do
      if [[ "${LB_C_SEC[i]}" == "${rel}" ]] && [[ "${path}" == ${LB_C_PAT[i]} ]]; then ci="${i}"; break; fi
    done
    local where="${rel}:${line} ${path}"
    if (( ci < 0 )); then
      lb_bviol "unclaimed:${rel}|${path}" "${where}: a ${kind} the budget does not claim. Add it to ${LB_MANIFEST_REL} [${rel}] — charged by its bound, or with the reason it costs nothing on this path."
      continue
    fi
    LB_C_HIT[ci]=$(( LB_C_HIT[ci] + 1 ))
    local mode="${LB_C_MODE[ci]}" label="${LB_C_LABEL[ci]}" ckey="${rel}|${path}" mark="${#LB_EXPLAIN}"
    # The called script or function's own budget, when there is one. What it
    # inherits keeps the status of where it came from.
    if [[ -n "${callee}" ]]; then
      local cenv="${envtext}" name kv u
      if [[ "${kind}" == script ]]; then
        # What the child inherits: the exports of this script and the
        # libraries it sources, and every inherited name it reassigns (an
        # assignment keeps the export), each at the value this script gives it.
        local -A cexp=()
        for name in ${LB_U_EXPORTS[${key}]:-}; do cexp["${name}"]="${rel}"; done
        for u in ${LB_U_LIBS[${key}]:-}; do
          for name in ${LB_U_EXPORTS[lib:${u}]:-}; do [[ -n "${cexp[${name}]:-}" ]] || cexp["${name}"]="${u}"; done
        done
        for name in "${!LENV[@]}"; do [[ -z "${LB_ASG[${rel}|${name}]+x}" ]] || cexp["${name}"]="${rel}"; done
        for name in "${!cexp[@]}"; do
          u="${cexp[${name}]}"
          if [[ -n "${LB_EXPF[${u}|${name}]:-}" || "${LB_ASGN[${u}|${name}]:-1}" != 1 ]] \
             || lb_rewritten "${rel}" "${name}" || lb_rewritten "${u}" "${name}"; then
            cenv+=$'\n'"${name}"$'\t2\t?'
          elif [[ -n "${LB_ASG[${u}|${name}]+x}" ]]; then
            if lb_resolve_str "${u}" "${LB_ASG[${u}|${name}]}" "${name}"; then cenv+=$'\n'"${name}"$'\t'"${LB_SST}"$'\t'"${LB_S}"
            else cenv+=$'\n'"${name}"$'\t2\t?'; fi
          fi
        done
        # An inherited name this script writes some other way (unset, a
        # function's assignment, printf -v, …) reaches the child changed.
        for name in "${!LENV[@]}"; do
          if [[ -z "${cexp[${name}]:-}" ]] && lb_rewritten "${rel}" "${name}"; then cenv+=$'\n'"${name}"$'\t2\t?'; fi
        done
        # The run's own words, in order: NAME=value, and the analyzer's marks
        # for what a wrapper takes away (see finish_cmd).
        if [[ -n "${senv}" ]]; then
          while IFS= read -r kv; do
            [[ -n "${kv}" ]] || continue
            case "${kv}" in
              $'\035*') cenv="" ;;
              $'\035?') cenv="$(lb_env_unknown "${cenv}")" ;;
              $'\035-'*) cenv+=$'\n'"${kv#$'\035-'}"$'\t0\t' ;;
              *)
                if lb_resolve_str "${rel}" "${kv#*=}"; then cenv+=$'\n'"${kv%%=*}"$'\t'"${LB_SST}"$'\t'"${LB_S}"
                else cenv+=$'\n'"${kv%%=*}"$'\t2\t?'; fi ;;
            esac
          done < <(tr '\034' '\n' <<<"${senv}")
        fi
        # "$@" at the top level forwards this script's own arguments; any
        # other "$@" or "$*" leaves the child's argument count unknowable.
        local cargs="" a x cu=0
        if [[ -n "${sargs}" ]]; then
          while IFS= read -r a; do
            if [[ "${a}" =~ ^\"?\$\{?@\}?\"?$ && "${path}" != */* ]]; then
              if (( LARGCU )) || lb_rewritten "${rel}" "@"; then cu=1; fi
              for x in ${LARGS[@]+"${LARGS[@]}"}; do cargs+="${x}"$'\034'; done
            elif [[ "${a}" =~ \$\{?[@*] ]] || lb_splits "${a}"; then
              cu=1
            elif lb_resolve_str "${rel}" "${a}"; then cargs+="${LB_SST}:${LB_S}"$'\034'
            else cargs+="2:?"$'\034'; fi
          done < <(tr '\034' '\n' <<<"${sargs}")
          cargs="${cargs%$'\034'}"
        fi
        (( ! cu )) || cargs=$'\035'"${cargs}"
        lb_budget "${root}" "${callee}" unit MAIN "${cenv}" "${cargs}" $(( depth + 1 ))
      else
        lb_budget "${root}" "${callee}" lib "${b1}" "${envtext}" "" $(( depth + 1 )) "${rel}"
      fi
      at="${LB_TOT}"; cdrv="${LB_DRV}"; cmax="${LB_MAXD}"
    fi
    # The wait's own bound: its value, and the constants it is written in.
    local ob="" osyms="" unb=0 unbwhy=""
    LB_WHY=""
    case "${kind}" in
      timeout)
        if lb_word "${rel}" "${b1}"; then
          ob="${LB_V}"; osyms="${LB_SYM}"
          if (( ob == 0 )); then unb=1; unbwhy=": a duration of 0 never expires"; fi
          if [[ "${b2}" != "-" ]]; then
            if lb_word "${rel}" "${b2}"; then ob=$(( ob + LB_V )); osyms+=" ${LB_SYM}"; else ob=""; fi
          fi
        fi ;;
      sleep|read-t|nc-w|lock)
        if [[ "${b1}" == "?" ]]; then unb=1
        elif lb_word "${rel}" "${b1}"; then ob="${LB_V}"; osyms="${LB_SYM}"; fi ;;
      wait-for|launch|trap) unb=1 ;;
      script|call) if [[ -n "${callee}" ]]; then ob="${at}"; osyms="@"; else unb=1; fi ;;
    esac
    local obwhy="${LB_WHY}"
    # The loops around it, innermost last: line|governing idents|kill -0
    # PIDs|stop files|bound|<=|step|wall clock.
    local -a lps=()
    if [[ -n "${loops}" ]]; then IFS=';' read -r -a lps <<<"${loops}"; fi
    local nl=${#lps[@]} lline="" lsyms="" lk0="" lfl="" lbe="" lle=0 linc="" lwall=0 linit=0
    if (( nl > 0 )); then IFS='|' read -r lline lsyms lk0 lfl lbe lle linc lwall linit <<<"${lps[nl-1]}"; fi
    local charge=0 tv=1 contrib=0 E="" EC="" once="${LB_C_ONCE[ci]}"
    case "${mode}" in
      charge|poll|within)
        if (( unb )); then
          lb_bviol "unb:${ckey}" "${where}: '${label}' is a ${mode} claim on a wait with no bound of its own (${kind} ${b1}${unbwhy}); only excluded, concurrent or, for a wait-for, allowance can claim it."
          continue
        fi
        if [[ -z "${ob}" ]]; then
          lb_bviol "ob:${ckey}" "${where}: cannot evaluate this wait's bound: ${obwhy}"
          continue
        fi ;;
    esac
    case "${mode}" in
      charge)
        EC="$(lb_idents "${LB_C_EXPR[ci]}")"; E="$(lb_idents "${LB_C_EXPR[ci]}" "${LB_C_TIMES[ci]}")"
        if ! lb_expr "${rel}" "${LB_C_EXPR[ci]}" "${at}"; then
          lb_bviol "ev:${ckey}" "${where}: '${label}' cannot be evaluated: ${LB_WHY}"
          continue
        fi
        charge="${LB_V}" ;;
      poll)
        E="$(lb_idents "${LB_C_TIMES[ci]}")"
        charge="${ob}" ;;
    esac
    if [[ "${mode}" == charge || "${mode}" == poll ]]; then
      if [[ -n "${LB_C_TIMES[ci]}" ]]; then
        if ! lb_expr "${rel}" "${LB_C_TIMES[ci]}" ""; then
          lb_bviol "tv:${ckey}" "${where}: '${label}' times cannot be evaluated: ${LB_WHY}"
          continue
        fi
        tv="${LB_V}"
        # Zero is a real count: a retry that a single attempt never makes.
        if (( tv < 0 )); then
          lb_bviol "tv1:${ckey}" "${where}: '${label}' multiplies by ${tv}"
          continue
        fi
      fi
      local ok sym j
      if [[ "${mode}" == charge ]]; then
        ok=1
        for sym in ${osyms}; do [[ "${E}" == *" ${sym} "* ]] || ok=0; done
        if (( ! ok )) && (( nl > 0 )); then
          for sym in ${E}; do [[ ",${lsyms}," == *",${sym},"* ]] && ok=1; done
        fi
        if (( ! ok )); then
          lb_bviol "link:${ckey}" "${where}: '${label}' charges '${LB_C_EXPR[ci]}', which names neither this wait's bound (${osyms}) nor the bound of the loop around it."
        fi
        if (( charge < ob )); then
          lb_bviol "floor:${ckey}:${charge}:${ob}" "${where}: '${label}' charges ${charge} s, below this wait's own bound of ${ob} s."
        fi
        # Charged by its loop: then by at least what the loop can spend in it,
        # read from the loop's own header, not from the charge's names.
        local byloop=0
        if (( nl > 0 )); then
          for sym in ${EC}; do [[ ",${lsyms}," == *",${sym},"* ]] && byloop=1; done
        fi
        if (( byloop )); then
          if ! lb_loopfloor "${rel}" "${lbe}" "${lle}" "${linc}" "${lwall}" "${ob}" "${linit}"; then
            lb_bviol "lfloor:${ckey}" "${where}: '${label}' is charged by the loop at line ${lline}, but ${LB_WHY}; charge the wait by its own bound, with the loop's count as \`times\`."
          elif (( charge < LB_V )); then
            lb_bviol "lfloor:${ckey}:${charge}:${LB_V}" "${where}: the loop at line ${lline} can spend ${LB_V} s in this wait (bound ${lbe}$( (( lwall )) && echo ', wall clock' ), step ${linc:-1}, from ${linit}, ${ob} s a pass), above the ${charge} s '${label}' charges."
          fi
        fi
      fi
      for (( j = 0; j < nl; j++ )); do
        local jl js jk jf
        IFS='|' read -r jl js jk jf _ <<<"${lps[j]}"
        ok=0
        for sym in ${E}; do [[ ",${js}," == *",${sym},"* ]] && ok=1; done
        if (( ! ok )) && [[ "${mode}" == poll ]] && (( j == nl - 1 )) && [[ -n "${jk}${jf}" ]]; then ok=1; fi
        if (( ! ok )) && [[ -n "${once}" ]]; then ok=1; fi
        if (( ! ok )); then
          if [[ "${mode}" == poll ]] && (( j == nl - 1 )); then
            lb_bviol "loop:${ckey}:${jl}" "${where}: '${label}' is a poll, but the loop at line ${jl} is released by no \`kill -0\` of a captured PID and no \`-e\`/\`-f\` of a file this script touches."
          else
            lb_bviol "loop:${ckey}:${jl}" "${where}: the loop at line ${jl} repeats this wait, and '${label}' pays for it nowhere: charge its bound or count (${js:-none in its header}), or say \`once <why>\`."
          fi
        fi
      done
      if [[ "${mode}" == poll ]]; then
        if (( nl == 0 )); then
          lb_bviol "pollnl:${ckey}" "${where}: '${label}' is a poll, but no loop encloses this wait."
        elif [[ -n "${lk0}" ]]; then
          POLLS+=("${lk0}|${where}|${label}")
        elif [[ -n "${lfl}" && "${bg}" == "-" ]]; then
          lb_bviol "pollfg:${ckey}" "${where}: '${label}' is a poll released by the stop file ${lfl}, but the loop runs in the foreground, where nothing on the lane's path can touch the file while it waits."
        fi
      fi
      contrib=$(( charge * tv ))
      ACHG["${label}"]=$(( ${ACHG[${label}]:-0} + contrib ))
      [[ -z "${bgpid}" ]] || JOBC["${bgpid}"]=1
    fi
    case "${mode}" in
      concurrent)
        [[ -z "${bgpid}" ]] || JOBX["${bgpid}"]=1
        if [[ "${bg}" == "-" ]]; then
          lb_bviol "conc:${ckey}" "${where}: '${label}' says concurrent, but this wait is on the lane's own path, not in a background job."
        elif [[ "${waited}" == waited ]]; then
          lb_bviol "conc:${ckey}" "${where}: '${label}' says concurrent, but the background job (line ${bg#*:}) is joined with \`wait\`, so its waits are on the path — charge them."
        elif [[ "${waited}" != free ]]; then
          lb_bviol "conc:${ckey}" "${where}: '${label}' says concurrent, but the background job (line ${bg#*:}) has no PID captured as NAME=\$!, so nothing shows it is never joined."
        fi ;;
      allowance)
        if [[ "${kind}" != wait-for ]]; then
          lb_bviol "allow:${ckey}" "${where}: '${label}' puts a ${kind} under the unbounded-work allowance; only a wait-for with no bound belongs there."
        fi ;;
      within)
        local an=-1 wt="${ob}"
        for (( i = 0; i < LB_NC; i++ )); do
          if [[ "${LB_C_SEC[i]}" == "${rel}" && "${LB_C_LABEL[i]}" == "${LB_C_ANCHOR[ci]}" && "${LB_C_MODE[i]}" =~ ^(charge|poll)$ && i -ne ci ]]; then an="${i}"; fi
        done
        if (( an < 0 )); then
          lb_bviol "within:${ckey}" "${where}: '${label}' is within '${LB_C_ANCHOR[ci]}', which is not a charged claim in [${rel}]."
        else
          # What the wait can take: one period of a released poll, else what
          # its innermost loop can spend in it, else (no loop, or one whose
          # bound cannot be read) its own bound. The anchor's charges must
          # hold all of its within waits together.
          if (( nl > 0 )) && [[ -z "${lk0}${lfl}" && -n "${lbe}" ]] && lb_loopfloor "${rel}" "${lbe}" "${lle}" "${linc}" "${lwall}" "${ob}" "${linit}"; then
            wt="${LB_V}"
          fi
          WSUM["${LB_C_ANCHOR[ci]}"]=$(( ${WSUM[${LB_C_ANCHOR[ci]}]:-0} + wt ))
        fi ;;
    esac
    # Drives: a bounded `flutter drive|test|run`, counted once per run of the
    # invocation's own targets — never by a retry's count, and never where only
    # some paths reach it (a retry in an `if`), either of which would let one
    # target look like many. Every drive's bound counts toward the longest.
    if [[ "${mode}" == charge || "${mode}" == poll ]]; then
      local tf=1
      if [[ -n "${LB_C_TIMES[ci]}" ]] && lb_positional "${rel}" "${LB_C_TIMES[ci]}" ${lps[@]+"${lps[@]}"}; then tf="${tv}"; fi
      (( ! scond )) || tf=0
      if [[ "${kind}" == timeout && "${sargs}" =~ flutter.(drive|test|run) ]]; then
        drives=$(( drives + tf ))
        if (( ob > maxd )); then maxd="${ob}"; fi
      elif [[ -n "${callee}" ]]; then
        drives=$(( drives + cdrv * tf ))
        if (( cmax > maxd )); then maxd="${cmax}"; fi
      fi
    fi
    total=$(( total + contrib ))
    local xl
    printf -v xl '%*s%-10s %-58s %6s' $(( depth * 2 )) '' "${mode}" "${rel##*/}: ${path}" "${contrib}"
    if (( tv != 1 )); then xl+="  (${charge} x ${tv})"; fi
    # Above the called script's own lines, which the recursion already added.
    LB_EXPLAIN="${LB_EXPLAIN:0:mark}${xl}"$'\n'"${LB_EXPLAIN:mark}"
  done <<<"${LB_U_SITES[${key}]:-}"
  local a p pid
  for a in "${!WSUM[@]}"; do
    if (( WSUM[${a}] > ${ACHG[${a}]:-0} )); then
      lb_bviol "wsum:${rel}|${a}:${WSUM[${a}]}" "${rel}: the waits within '${a}' can take ${WSUM[${a}]} s together, more than the ${ACHG[${a}]:-0} s '${a}' is charged — its window cannot contain them."
    fi
  done
  # A poll is one period after the job it watches ends: that job's own waits
  # must be on the budget, or the poll joins something nobody charged.
  for p in ${POLLS[@]+"${POLLS[@]}"}; do
    local w="${p#*|}" pids="${p%%|*}"
    for pid in ${pids//,/ }; do
      if [[ -n "${JOBX[${pid}]:-}" || -z "${JOBC[${pid}]:-}" ]]; then
        lb_bviol "pjob:${rel}|${w}|${pid}" "${w%|*}: '${w##*|}' polls the job in \$${pid}, but that job's waits are not charged (it is concurrent, or charges nothing), so the poll joins an uncharged wait."
      fi
    done
  done
  LB_TOT="${total}"; LB_DRV="${drives}"; LB_MAXD="${maxd}"
}

# lb_resolve_str <rel> <raw> -> LB_S, LB_SST: a word as the script would pass
# it (exports, prefix env, arguments), and the status of what it came from.
# Only quotes, ${X:-d}, $X and $N; anything else is not resolvable (rc 1).
lb_resolve_str() {
  local rel="$1" v="$2" self="${3:-}" depth="${4:-0}" name
  LB_SST=0
  (( depth < 8 )) || return 1
  if [[ "${v}" == \"*\" ]]; then v="${v#\"}"; v="${v%\"}"; fi
  if [[ "${v}" == \'*\' ]]; then LB_S="${v:1:${#v}-2}"; return 0; fi
  if [[ "${v}" != *'$'* ]]; then LB_S="${v}"; return 0; fi
  if [[ "${v}" =~ ^\$\{([A-Za-z_][A-Za-z0-9_]*):?-([^}\$]*)\}$ ]]; then
    name="${BASH_REMATCH[1]}"; LB_S="${BASH_REMATCH[2]}"
    if lb_rewritten "${rel}" "${name}"; then LB_S="?"; LB_SST=2; return 0; fi
    # A definition reading its own name, `X="${X:-d}"`, reads the environment.
    if [[ "${name}" != "${self}" && -n "${LB_ASG[${rel}|${name}]+x}" ]]; then
      local def="${LB_S}"
      lb_resolve_str "${rel}" "${LB_ASG[${rel}|${name}]}" "${name}" $(( depth + 1 )) || return 1
      if [[ -z "${LB_S}" && "${LB_SST}" == 0 ]]; then LB_S="${def}"; fi
      return 0
    fi
    if [[ -n "${LENV[${name}]+x}" ]] && [[ -n "${LENV[${name}]}" || "${LENVS[${name}]%%.*}" != 0 ]]; then
      LB_S="${LENV[${name}]}"; LB_SST="${LENVS[${name}]}"
    fi
    return 0
  fi
  if [[ "${v}" =~ ^\$\{?([A-Za-z_][A-Za-z0-9_]*)\}?$ ]]; then
    name="${BASH_REMATCH[1]}"
    if lb_rewritten "${rel}" "${name}"; then LB_S="?"; LB_SST=2; return 0; fi
    if [[ "${name}" != "${self}" && -n "${LB_ASG[${rel}|${name}]+x}" ]]; then
      lb_resolve_str "${rel}" "${LB_ASG[${rel}|${name}]}" "${name}" $(( depth + 1 )); return $?
    fi
    if [[ -n "${LENV[${name}]+x}" ]]; then LB_S="${LENV[${name}]}"; LB_SST="${LENVS[${name}]}"; return 0; fi
    return 1
  fi
  if [[ "${v}" =~ ^\$\{?([1-9])\}?$ ]]; then
    local i=$(( BASH_REMATCH[1] - 1 ))
    if (( LARGCU )) || lb_rewritten "${rel}" "@"; then LB_S="?"; LB_SST=2; return 0; fi
    LB_S=""
    if (( i < ${#LARGS[@]} )) && [[ "${LARGS[i]}" =~ ^([0-9](\.[0-9]+)*):(.*)$ ]]; then
      LB_SST="${BASH_REMATCH[1]}"; LB_S="${BASH_REMATCH[3]}"
    fi
    return 0
  fi
  return 1
}

# ---------------------------------------------------------------------------
# The second reading
#
# app-install-lib.sh's lexer is an independent, separately tested reading of
# the same shell. Wherever it sees a wait word in command position on a line a
# lane can reach, the analyzer must have reported a site on that line; if it
# did not, the analyzer has misread the file, and a sum built on that reading
# cannot be vouched for (rc 2). Reachability comes from the call graph alone,
# not from which functions were found to wait, so a missed wait still falls
# on a covered line.
# ---------------------------------------------------------------------------
# shellcheck source=tooling/e2e/ci/app-install-lib.sh
source "${LB_DIR}/../../tooling/e2e/ci/app-install-lib.sh"
declare -F _app_install_code >/dev/null \
  || lb_die "tooling/e2e/ci/app-install-lib.sh no longer defines _app_install_code, the second reading"
# The same waits the analyzer reads, over the other lexer's code (quoted words
# gone): in command position, after an assignment prefix, a wrapper with its
# options and arguments, and a path. A launch's global options are the
# analyzer's too: any `-…` word, and `-d`/`--device-id` with its value, so
# `flutter -v drive` is a launch and `flutter -v pub run` is not.
readonly LB_CMDPOS='(^|[;&|(){}!]|(^|[[:space:];&|(){}!])[A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]|(^|[[:space:]])(then|do|else|elif|if|while|until|time))[[:space:]]*'
readonly LB_WRAP='((([^[:space:];&|]*/)?(sudo|nice|env|stdbuf|ionice|exec|nohup|setsid|time|builtin|taskset|chrt)([[:space:]]+(-[^[:space:]]*([[:space:]]+[^-[:space:]][^[:space:]]*)?|[0-9][^[:space:]]*|[A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*))*|command)[[:space:]]+)*'
readonly LB_WAITWORD="${LB_CMDPOS}${LB_WRAP}([^[:space:];&|]*/)?(sleep|timeout|flutter([[:space:]]+(-d|--device-id)[[:space:]]+[^[:space:];&|]+|[[:space:]]+-[^[:space:];&|]*)*[[:space:]]+(drive|test|run)|read([[:space:]]+(-[A-Za-z]*[adinNpu]([[:space:]]*[^-[:space:]][^[:space:]]*)?|-[rse]+))*[[:space:]]+-[rse]*t|(iptables|ip6tables)([[:space:]]+[^[:space:];&|]+)*[[:space:]]+(-w|--wait)|(nc|ncat|netcat)([[:space:]]+[^[:space:];&|]+)*[[:space:]]+-[A-Za-z]*w|(adb|am|cmd)([[:space:]]+[^[:space:];&|]+)*[[:space:]]+wait-for-[a-z-]+)([[:space:]]|[0-9]|\$)"

# lb_second_reading <root> <rel> <roots>
lb_second_reading() {
  local root="$1" rel="$2" roots="$3" out rc=0 rec a b c ln code mainr=0 i best kind got rest pre
  local -a rs=() re=() rk=()
  local -A have=()
  out="$(awk -v roots="${roots}" -v ext="" "${LB_AWK}" "${root}/${rel}")" || rc=$?
  (( rc == 0 )) || lb_die "cannot read ${rel}: $(sed -n 's/^E\t//p' <<<"${out}")"
  while IFS=$'\t' read -r rec a b c; do
    case "${rec}" in
      RNG) if [[ "${a}" == M ]]; then mainr=1; else rs+=("${b}"); re+=("${c}"); rk+=("${a}"); fi ;;
      LC) have["${a}"]="${b}" ;;
    esac
  done <<<"${out}"
  rc=0
  out="$(_app_install_code "${root}/${rel}")" || rc=$?
  (( rc == 0 )) || lb_die "the second reading cannot read ${rel} (app-install-lib.sh's lexer rc ${rc})"
  while IFS=$'\t' read -r ln code; do
    [[ "${code}" =~ ${LB_WAITWORD} ]] || continue
    # The innermost range around the line decides: a --self-test region, an
    # unreachable function or a reachable one; none, the top level.
    best=-1; kind=M
    for (( i = 0; i < ${#rs[@]}; i++ )); do
      if (( ln >= rs[i] && ln <= re[i] )) && { (( best < 0 )) || (( re[i] - rs[i] < re[best] - rs[best] )); }; then best="${i}"; fi
    done
    (( best < 0 )) || kind="${rk[best]}"
    [[ "${kind}" == F || ( "${kind}" == M && "${mainr}" == 1 ) ]] || continue
    # Every wait the lexer sees on the line, each blanked once counted.
    got=0; rest="${code}"
    while [[ "${rest}" =~ ${LB_WAITWORD} ]]; do
      got=$(( got + 1 ))
      pre="${rest%%"${BASH_REMATCH[0]}"*}"
      rest="${pre//?/_}${BASH_REMATCH[0]//?/_}${rest#*"${BASH_REMATCH[0]}"}"
    done
    (( got > ${have[${ln}]:-0} )) || continue
    lb_die "${rel}:${ln}: app-install-lib.sh's lexer sees ${got} wait(s) here ('${code}') on a line a lane reaches, and this check's analyzer read ${have[${ln}]:-0}. One of the two misreads the file; the budget cannot be vouched for until they agree."
  done <<<"${out}"
}

# lb_lib_to_lib <root> — a library function a lane calls that calls another
# library's function that waits: its budget would count that wait nowhere, so
# it is refused rather than modelled.
lb_lib_to_lib() {
  local root="$1" key l others out rc path kind g m
  for l in "${!LB_LIBCALL[@]}"; do
    others=""
    for key in "${!LB_U_DONE[@]}"; do
      [[ "${key}" == lib:* && "${key}" != "lib:${l}" ]] && others+="${LB_U_FUNCS[${key}]:-} "
    done
    [[ -n "${others// /}" ]] || continue
    rc=0
    out="$(awk -v roots="${LB_LIBCALL[${l}]}" -v ext="${others}" "${LB_AWK}" "${root}/${l}")" || rc=$?
    (( rc == 0 )) || lb_die "cannot read ${l}: $(sed -n 's/^E\t//p' <<<"${out}")"
    while IFS=$'\t' read -r path kind g _; do
      [[ "${kind}" == call ]] || continue
      for key in "${!LB_U_DONE[@]}"; do
        [[ "${key}" == lib:* ]] || continue
        m="${key#lib:}"
        [[ " ${LB_L_WF[${m}]:-} " == *" ${g} "* ]] || continue
        lb_violation "lib2lib:${l}|${path}" "${l}: ${path} calls ${g} of ${m}, which waits; a library calling another library's waiting function is not budgeted. Call it from the script instead."
      done
    done < <(sed -n 's/^S\t//p' <<<"${out}")
  done
}

# ---------------------------------------------------------------------------
# Lanes
# ---------------------------------------------------------------------------
declare -A LB_GHENV=()

# lb_lane_cmd <cmd> -> LB_INV: one "script<TAB>env<TAB>args" line per tooling
# script the command runs, env and args \034-joined words carrying the status
# of the expressions they hold ("status:NAME=value", "status:value"); rc 1
# with LB_WHY when the command runs something that cannot be budgeted.
lb_lane_cmd() {
  local cmd="$1" toks t w i n inv="" env="" args="" script="" state=start cu
  local -a tk=()
  toks="$(lb_words "${cmd}")"
  [[ "${toks}" != "E" ]] || { LB_WHY="unbalanced quotes"; return 1; }
  while IFS= read -r t; do [[ -n "${t}" ]] && tk+=("${t}"); done <<<"${toks}"
  n=${#tk[@]}
  if (( n == 3 )) && [[ "${tk[0]}" == Wbash && "${tk[1]}" == W-c ]]; then
    lb_lane_cmd "${tk[2]#W}"; return $?
  fi
  LB_MOPEN=""; cu=0
  tk+=("O;")
  for (( i = 0; i <= n; i++ )); do
    t="${tk[i]}"
    if [[ "${t}" == O* ]]; then
      if [[ "${t}" != "O&&" && "${t}" != "O;" ]]; then LB_WHY="the command uses '${t#O}', which this check does not model"; return 1; fi
      if [[ -n "${script}" ]]; then
        env="${env%$'\034'}"; args="${args%$'\034'}"
        (( ! cu )) || args=$'\035'"${args}"
        inv+="${script}"$'\t'"${env:--}"$'\t'"${args:--}"$'\n'
      fi
      env=""; args=""; script=""; state=start; cu=0
      continue
    fi
    lb_unmark_word "${t:1}"; w="${LB_UW}"
    case "${state}" in
      start)
        if [[ "${w}" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; then env+="${LB_UST}:${w}"$'\034'; continue; fi
        [[ "${LB_UST}" == 0 ]] || { LB_WHY="the command word '${w}' comes from an expression"; return 1; }
        case "${w}" in
          bash|sh) state=script ;;
          test|"["|true) state=skip ;;
          *) LB_WHY="the command runs '${w}' inside the deadline, which this check cannot budget"; return 1 ;;
        esac ;;
      script)
        if [[ "${LB_UST}" == 0 && "${w}" == tooling/e2e/ci/*.sh ]]; then script="${w}"; state=args
        else LB_WHY="the command runs 'bash ${w}', not a tooling/e2e/ci script"; return 1; fi ;;
      args) args+="${LB_UST}:${w}"$'\034'; [[ "${t}" != V* ]] || cu=1 ;;
      skip) ;;
    esac
  done
  LB_INV="${inv}"
}

# lb_drive_launches <root> <rel> [depth] — 0 iff <rel>, or a script it runs,
# launches the app with no bound of its own.
lb_drive_launches() {
  local root="$1" rel="$2" depth="${3:-0}" path kind b1 rest
  (( depth < 6 )) || return 1
  lb_load_unit "${root}" "${rel}" unit
  while IFS=$'\t' read -r path kind b1 rest; do
    [[ "${kind}" == launch ]] && { LB_LAUNCH="${rel}: ${path}"; return 0; }
    if [[ "${kind}" == script && "${b1}" != "?" ]] && lb_drive_launches "${root}" "tooling/e2e/ci/${b1}" $(( depth + 1 )); then
      return 0
    fi
  done <<<"${LB_U_SITES[unit:${rel}]:-}"
  return 1
}

LB_EXPLAIN=""
LB_LANES=0
declare -a LB_REPORT=()

# lb_check_repo <root> [--explain]
lb_check_repo() {
  local root="$1" explain="${2:-}" wf f v
  local file job jobcap runs_on stepname stepcap uses retry_to retry_ma boot_to cmd body
  LB_VIOL=0; LB_VSEEN=(); LB_LANES=0; LB_REPORT=()
  LB_U_DONE=(); LB_U_SITES=(); LB_U_LIBS=(); LB_U_EXPORTS=(); LB_U_FUNCS=()
  LB_ASG=(); LB_ASGN=(); LB_ASGKW=(); LB_ASGL=(); LB_EXPF=(); LB_L_WF=(); LB_READ=(); LB_LIBCALL=(); LB_WR=(); LB_SEC=(); LB_DECL=()
  LB_DECL_LN=(); LB_DECL_HIT=(); LB_SEC_HIT=(); LB_NC=0
  LB_C_SEC=(); LB_C_LABEL=(); LB_C_PAT=(); LB_C_MODE=(); LB_C_EXPR=(); LB_C_TIMES=()
  LB_C_ONCE=(); LB_C_ANCHOR=(); LB_C_LN=(); LB_C_HIT=(); LB_GHENV=()
  lb_load_manifest "${root}/${LB_MANIFEST_REL}"
  local wfs=()
  while IFS= read -r f; do wfs+=("${f}"); done < <(find "${root}/.github/workflows" -maxdepth 1 -name '*.yml' | sort)
  (( ${#wfs[@]} > 0 )) || lb_die "no workflows under ${root}/.github/workflows"
  for wf in "${wfs[@]}"; do
    local base="${wf##*/}"
    # A step that writes GITHUB_ENV may set any name it assigns, on any of its
    # lines (a grouped `{ …; } >> "$GITHUB_ENV"` puts them on others), as
    # NAME=value or as the multi-line NAME<<DELIMITER.
    while IFS= read -r v; do
      [[ -n "${v}" ]] && LB_GHENV["${base}|${v}"]=1
    done < <(extract_steps "${wf}" | awk -F'\t' 'index($12, "GITHUB_ENV")' \
               | grep -oE '[A-Za-z_][A-Za-z0-9_]*(=|<<)' | sed -E 's/(=|<<)$//' || true)
    local envrecs
    envrecs="$(lb_extract_env "${wf}")"
    if [[ $'\n'"${envrecs}" == *$'\nE\t'* ]]; then
      v=$'\n'"${envrecs}"; v="${v#*$'\n'E$'\t'}"; v="${v%%$'\n'*}"
      lb_die "${base}:${v%%$'\t'*}: an env mapping this check cannot read (${v#*$'\t'}); write it as a block mapping"
    fi
    while IFS=$'\t' read -r file job jobcap runs_on stepname stepcap uses retry_to retry_ma boot_to cmd body; do
      # `is_soak_body` joins the gate for the reason it joined the ordering
      # guard's: the soak lane is a plain `ubuntu-latest` `run:` step, so
      # without it the lane declares NOTHING in the manifest and gets no budget
      # protection at all — and a stale-declaration check cannot report a
      # section nobody ever reaches.
      is_emulator_step "${uses}" || is_simulator_body "${body}" || is_soak_body "${body}" || continue
      is_drive_body "${body}" || continue
      LB_LANES=$(( LB_LANES + 1 ))
      local lkey="${base}::${job}" label="${base}::${job} (${stepname})"
      local decl="${LB_DECL[${lkey}]:-}" retry=0
      [[ -n "${decl}" ]] && LB_DECL_HIT["${lkey}"]=1
      [[ "${uses}" == *nick-fields/retry* ]] && retry=1
      LB_REAPER=0; [[ "${decl}" != reaper ]] || LB_REAPER=1
      LWF="${base}"
      # The deadline, as the ordering guard reads it.
      local dlraw dlb dl0 dl1 per=""
      dlraw="$(deadline_token "${body}")"
      if [[ -n "${dlraw}" ]]; then
        dlb="$(branches "${dlraw}")"
      elif (( retry )); then
        dlb="$(branches "${retry_to}")"; per=" per attempt"
      else
        lb_violation "dl:${label}" "${label}: no inner deadline to compare with (check_e2e_step_timeout_ordering.sh C1)."
        continue
      fi
      [[ -n "${dlb}" ]] || { lb_violation "dl:${label}" "${label}: the deadline '${dlraw:-${retry_to}}' does not parse."; continue; }
      read -r dl0 dl1 <<<"${dlb}"
      if [[ "${decl}" == unbudgeted ]]; then
        lb_unbudgeted "${root}" "${label}" "${lkey}" "${retry}" "${cmd}" "${dl0}" "${runs_on}"
        continue
      fi
      if [[ "${cmd}" == "|"* ]]; then
        lb_violation "cmd:${label}" "${label}: a multi-line script: the emulator action runs each line in its own shell, so the deadline would not bound the lines after the first."
        continue
      fi
      # The conditions the lane reads, starting with its deadline's own.
      LB_CONDS=()
      if [[ "${dlraw:-${retry_to}}" =~ \$\{\{(.+)\&\&[[:space:]]*\'?[0-9]+[smhd]?\'?[[:space:]]*\|\| ]]; then
        lb_cond_id "${BASH_REMATCH[1]}"; LB_CONDS["${LB_CONDTXT[LB_CID]}"]=1
      fi
      # Both sides of every `${{ c && A || B }}` in the step, paired
      # positionally as the ordering guard pairs them; one line when they agree.
      local br res0="" res1=""
      for br in 0 1; do
        local dtok dsecs
        if (( br == 0 )); then dtok="${dl0}"; else dtok="${dl1}"; fi
        dsecs="$(dur_to_secs "${dtok}")"
        # This lane's env: the workflow's, the job's, then the step's, wherever
        # each sits in the file; then
        # every name a step writes to GITHUB_ENV, whose value is decided at
        # run time; then the command's own prefix assignments (below).
        LB_WENV=()
        local sc key val want
        for want in wf "job:${job}" "step:${job}:${stepname}"; do
          while IFS=$'\t' read -r sc key val; do
            [[ "${sc}" != "${want}" ]] || LB_WENV["${key}"]="${val}"
          done <<<"${envrecs}"
        done
        local envtext="" cmdm
        for key in "${!LB_WENV[@]}"; do
          lb_resolve_gh "${LB_WENV[${key}]}" "${br}"
          envtext+="${key}"$'\t'"${LB_GHST}"$'\t'"${LB_GH}"$'\n'
        done
        for key in "${!LB_GHENV[@]}"; do
          [[ "${key}" != "${base}|"* ]] || envtext+="${key#*|}"$'\t3\t?\n'
        done
        lb_resolve_gh "${cmd}" "${br}" 0 1; cmdm="${LB_GH}"
        # What runs under the deadline: after `run-with-deadline.sh <dl>
        # <label> --`, after `timeout <dl>`, or a retry step's whole command.
        local inner="${cmdm}" dword=""
        if [[ -n "${dlraw}" ]]; then
          if [[ "${cmdm}" =~ run-with-deadline\.sh[[:space:]]+([^[:space:]]+)[[:space:]]+(\"[^\"]*\"|\'[^\']*\'|[^[:space:]]+)[[:space:]]+--[[:space:]]+(.*)$ ]]; then
            dword="${BASH_REMATCH[1]}"; inner="${BASH_REMATCH[3]}"
            LB_MOPEN=""; lb_unmark_word "${dword}"
            [[ "${LB_UW}" == "${dtok}" ]] || lb_die "${label}: the step's deadline (${dtok}) and its command's (${LB_UW}) disagree"
          elif local tre='(^|[[:space:]])timeout[[:space:]]+(--?[^[:space:]]+[[:space:]]+)*('$'\002''[^'$'\037'']*'$'\037'')?'"${dtok}"$'\003''?[[:space:]]+(.*)$'
               [[ "${cmdm}" =~ ${tre} ]]; then
            inner="${BASH_REMATCH[4]}"
          else
            lb_violation "cmd:${label}" "${label}: cannot find the command under the deadline in '${cmd}'."
            continue 2
          fi
        fi
        if ! lb_lane_cmd "${inner}"; then
          lb_violation "cmd:${label}" "${label}: ${LB_WHY}."
          continue 2
        fi
        local sctext total=0 drv=0 maxd=0 senv sargs ienv kv st
        LB_EXPLAIN=""; LB_EVAL_ERR=0
        while IFS=$'\t' read -r sctext senv sargs; do
          [[ -n "${sctext}" ]] || continue
          [[ "${senv}" != "-" ]] || senv=""
          [[ "${sargs}" != "-" ]] || sargs=""
          ienv="${envtext}"
          if [[ -n "${senv}" ]]; then
            while IFS= read -r kv; do
              [[ -n "${kv}" ]] || continue
              st="${kv%%:*}"; kv="${kv#*:}"
              ienv+="${kv%%=*}"$'\t'"${st}"$'\t'"${kv#*=}"$'\n'
            done < <(tr '\034' '\n' <<<"${senv}")
          fi
          LB_READ["${sctext}"]=1
          LB_EXPLAIN+="  ${sctext##*/}"$'\n'
          lb_budget "${root}" "${sctext}" unit MAIN "${ienv}" "${sargs}" 1
          total=$(( total + LB_TOT )); drv=$(( drv + LB_DRV ))
          if (( LB_MAXD > maxd )); then maxd="${LB_MAXD}"; fi
        done <<<"${LB_INV}"
        printf -v "res${br}" '%s\t%s\t%s\t%s\t%s\t%s\t%s' "${total}" "${dsecs}" "${dtok}" "${drv}" "${maxd}" "${LB_EVAL_ERR}" "${LB_EXPLAIN}"
      done
      if (( ${#LB_CONDS[@]} > 1 )); then
        lb_violation "cond:${label}" "${label}: what this lane reads is chosen by different conditions ($(printf '%s\n' "${!LB_CONDS[@]}" | sort | sed "s/.*/'&'/" | paste -sd, -)); both guards pair the branches of \${{ c && A || B }} positionally, which holds only for one condition."
      fi
      local r tag total dsecs dtok drv maxd inc xpl worst at
      for br in 0 1; do
        if (( br == 0 )); then r="${res0}"; else r="${res1}"; fi
        tag=""
        if [[ "${res0%%$'\t'*}" != "${res1%%$'\t'*}" || "${dl0}" != "${dl1}" ]]; then
          if (( br == 0 )); then tag=" [true branch]"; else tag=" [false branch]"; fi
        elif (( br == 1 )); then
          break
        fi
        IFS=$'\t' read -r total dsecs dtok drv maxd inc _ <<<"${r}"
        xpl="${r#*$'\t'*$'\t'*$'\t'*$'\t'*$'\t'*$'\t'}"
        worst=$(( total + UNBOUNDED_WORK_ALLOWANCE_SECS ))
        at=""; (( inc == 0 )) || at="at least "
        # A sum with a wait it could not count is a lower bound: enough to
        # show a deadline too short, never enough to show one sufficient.
        if (( inc > 0 )) && { [[ "${decl}" == reaper ]] || (( worst <= dsecs )); }; then
          LB_REPORT+=("INCOMP ${label}${tag}: ${inc} wait(s) not counted (see above); at least ${worst} s against ${dtok}${per} (${dsecs} s)")
        elif [[ "${decl}" == reaper ]]; then
          lb_reaper "${label}${tag}" "${lkey}" "${worst}" "${dsecs}" "${dtok}" "${drv}" "${maxd}"
        elif (( worst > dsecs )); then
          lb_violation "short:${label}${tag}" "${label}${tag}: worst case ${at}${worst} s (${total} s of bounded waits + ${UNBOUNDED_WORK_ALLOWANCE_SECS} s allowance) EXCEEDS its ${dtok}${per} deadline (${dsecs} s) by $(( worst - dsecs )) s. Raise the deadline, with its derivation, or shorten a wait:"$'\n'"${xpl%$'\n'}"
          LB_REPORT+=("SHORT  ${label}${tag}: ${at}${worst} s > ${dtok}${per} (${dsecs} s)")
        else
          LB_REPORT+=("ok     ${label}${tag}: ${worst} s = ${total} + ${UNBOUNDED_WORK_ALLOWANCE_SECS} allowance <= ${dtok}${per} (${dsecs} s), headroom $(( dsecs - worst )) s")
        fi
        if [[ -n "${explain}" ]]; then LB_REPORT+=("${xpl%$'\n'}"); fi
      done
    done < <(extract_steps "${wf}")
  done
  # Declarations and claims that nothing used are sums over waits that are
  # not there — as wrong as the reverse.
  local d
  for d in "${!LB_DECL[@]}"; do
    [[ -n "${LB_DECL_HIT[${d}]:-}" ]] || lb_violation "stale-decl:${d}" "${LB_MANIFEST_REL}:${LB_DECL_LN[${d}]}: ${LB_DECL[${d}]} ${d} matches no drive step."
  done
  local i sec
  for sec in "${!LB_SEC[@]}"; do
    [[ -n "${LB_SEC_HIT[${sec}]:-}" ]] || lb_violation "stale-sec:${sec}" "${LB_MANIFEST_REL}: [${sec}] is on no budgeted lane's path."
  done
  for (( i = 0; i < LB_NC; i++ )); do
    if [[ -n "${LB_SEC_HIT[${LB_C_SEC[i]}]:-}" ]] && (( LB_C_HIT[i] == 0 )); then
      lb_violation "stale:${i}" "${LB_MANIFEST_REL}:${LB_C_LN[i]}: '${LB_C_LABEL[i]}' (${LB_C_PAT[i]}) matches no wait in ${LB_C_SEC[i]}: a stale claim."
    fi
  done
  local u
  while IFS= read -r u; do
    [[ -n "${u}" ]] && lb_second_reading "${root}" "${u}" MAIN
  done < <(printf '%s\n' "${!LB_READ[@]}" | sort)
  while IFS= read -r u; do
    [[ -n "${u}" ]] && lb_second_reading "${root}" "${u}" "${LB_LIBCALL[${u}]}"
  done < <(printf '%s\n' "${!LB_LIBCALL[@]}" | sort)
  lb_lib_to_lib "${root}"
  # The ordering guard counts the drive steps with the same extraction, and
  # proves by raw grep that no workflow bearing a drive marker was skipped:
  # equal counts mean no drive step dropped out of this check before its
  # verdict.
  VIOLATIONS=0
  check_dir "${root}/.github/workflows" 2>/dev/null || true
  check_extractor_sees_the_repo "${root}/.github/workflows" >/dev/null
  (( LB_LANES > 0 )) || lb_die "found no drive step under ${root}/.github/workflows: the extraction has gone blind"
  (( LB_LANES == DRIVE_STEPS )) \
    || lb_die "this check evaluated ${LB_LANES} drive step(s), check_e2e_step_timeout_ordering.sh counts ${DRIVE_STEPS}"
}

# A reaper is accepted for what is TRUE of it, never for being named one.
lb_reaper() {
  local label="$1" lkey="$2" worst="$3" dsecs="$4" dtok="$5" drv="$6" maxd="$7"
  local why="${LB_MANIFEST_REL}:${LB_DECL_LN[${lkey}]}"
  if (( drv < 2 )); then
    lb_violation "reap1:${label}" "${label}: declared reaper (${why}), but runs ${drv} drive(s). An aggregate deadline is for many drives; a single-drive lane must cover its worst case (${worst} s)."
  elif (( worst <= dsecs )); then
    lb_violation "reap2:${label}" "${label}: declared reaper (${why}), but its worst case ${worst} s fits the ${dtok} deadline: budget it as an ordinary lane and drop the declaration."
  elif (( maxd >= dsecs )); then
    lb_violation "reap3:${label}" "${label}: declared reaper (${why}), but one drive's own bound (${maxd} s) is not below the ${dtok} deadline (${dsecs} s), so a single hang dies unattributed."
  else
    LB_REPORT+=("reaper ${label}: ${drv} drives, worst ${worst} s > ${dtok} (${dsecs} s) by design; one drive's bound ${maxd} s < ${dsecs} s")
  fi
}

lb_unbudgeted() {
  local root="$1" label="$2" lkey="$3" retry="$4" cmd="$5" dtok="$6" runs_on="$7" sctext rest
  if (( ! retry )) || [[ "${runs_on}" != *macos* ]]; then
    lb_violation "unb1:${label}" "${label}: declared unbudgeted (${LB_MANIFEST_REL}:${LB_DECL_LN[${lkey}]}), but only a nick-fields/retry lane on a macOS runner, whose harness has no inner bound, may be."
    return 0
  fi
  lb_resolve_gh "${cmd}" 0
  if ! lb_lane_cmd "${LB_GH}"; then
    lb_violation "unb2:${label}" "${label}: ${LB_WHY}."
    return 0
  fi
  while IFS=$'\t' read -r sctext rest; do
    [[ -n "${sctext}" ]] || continue
    if lb_drive_launches "${root}" "${sctext}"; then
      LB_REPORT+=("unbudg ${label}: $(( $(dur_to_secs "${dtok}") / 60 ))m per attempt; ${LB_LAUNCH} launches with no bound of its own")
      return 0
    fi
  done <<<"${LB_INV}"
  lb_violation "unb3:${label}" "${label}: declared unbudgeted, but every launch its harness makes is bounded now: budget it."
}

# ---------------------------------------------------------------------------
# Entry
# ---------------------------------------------------------------------------

lb_main() {
  local root="$1" explain="${2:-}" r
  lb_log "checking every E2E lane's deadline against its harness's worst case"
  # Which awk read the scripts: the analyzer is POSIX awk, run by whatever the
  # runner calls awk (mawk and gawk print their name on -W version's first line).
  lb_log "awk: $(awk -W version 2>&1 </dev/null | sed -n 1p)"
  lb_check_repo "${root}" "${explain}"
  for r in ${LB_REPORT[@]+"${LB_REPORT[@]}"}; do printf '  %s\n' "${r}"; done
  if (( LB_VIOL > 0 )); then
    printf '\033[1;31m[%s] FAIL:\033[0m %d violation(s). The rule: a lane'"'"'s deadline covers every wait its harness can reach, each at its bound, plus the %d s allowance.\n' "${LB_NAME}" "${LB_VIOL}" "${UNBOUNDED_WORK_ALLOWANCE_SECS}" >&2
    return 1
  fi
  lb_log "OK — ${LB_LANES} drive steps: every budgeted lane's deadline covers its worst case"
}

# ---------------------------------------------------------------------------
# Self-test: a synthetic tree, one rule per case, both directions.
#
# The base tree is a sound lane whose script also carries every wait that must
# NOT count — after a `;` in a comment and in strings, in a heredoc, in the
# --self-test branch and in an uncalled library function — next to every kind
# that must: a helper script's wall-clock loop, a sourced library's barrier, a
# background drip, a counted poll, a settle and the drive. Its deadline is its
# budget plus the allowance plus 59 s, so every number below follows from the
# fixture's constants and the allowance, and a +60 s change is 1 s short.
# ---------------------------------------------------------------------------

# Cases lb_self_test must run, pinned by EQUALITY: a deleted case must fail
# the suite, not shrink it.
readonly LB_SELF_TEST_CASES=171

# The base lane's budget, from the fixture's constants: the helper's
# UP_SECS + 1 tick, BARRIER_SECS, READY_SECS, SETTLE_SECS and the drive's
# 10m + DRIVE_KILL_AFTER_SECS.
readonly LB_ST_BUDGET=$(( (30 + 1) + 60 + 40 + 20 + (600 + 30) ))

# _lb_mk_base <dir> <deadline secs>
_lb_mk_base() {
  local b="$1" d="$2" ci="$1/tooling/e2e/ci"
  mkdir -p "${ci}" "${b}/.github/workflows" "${b}/scripts/ci"
  cat >"${b}/.github/workflows/lane.yml" <<YML
name: lane
on: [push]
jobs:
  lane:
    runs-on: ubuntu-latest
    timeout-minutes: $(( d / 60 + 21 ))
    steps:
      - name: Drive
        timeout-minutes: $(( d / 60 + 11 ))
        uses: reactivecircus/android-emulator-runner@v2
        with:
          emulator-boot-timeout: 420
          script: bash tooling/e2e/ci/run-with-deadline.sh ${d}s "lane drive" -- bash tooling/e2e/ci/run-lane.sh
YML
  cat >"${ci}/run-lane.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/install-lib.sh"
readonly DRIVE_TIMEOUT="${LANE_DRIVE_TIMEOUT:-10m}"
readonly DRIVE_KILL_AFTER_SECS=30
readonly SETTLE_SECS=20
readonly POLL_SECS=2
readonly READY_SECS=40
if [[ "${1:-}" == "--self-test" ]]; then
  sleep 900
  exit 0
fi
: # x; sleep 800 is a comment
cat > /tmp/stub <<'STUB'
sleep 700
timeout 9h true
STUB
echo "x; sleep 600" 'y; timeout 5h true'
bash "${SCRIPT_DIR}/helper.sh"
install_app emulator-5554 /tmp/app.apk
( while sleep "${POLL_SECS}"; do :; done ) &
DRIP_PID=$!
waited=0
while (( waited < READY_SECS )); do
  sleep "${POLL_SECS}"
  waited=$(( waited + POLL_SECS ))
done
sleep "${SETTLE_SECS}"
timeout --kill-after="${DRIVE_KILL_AFTER_SECS}s" "${DRIVE_TIMEOUT}" flutter drive --target x
kill "${DRIP_PID}"
SH
  cat >"${ci}/helper.sh" <<'SH'
#!/usr/bin/env bash
readonly UP_SECS=30
deadline=$(( SECONDS + UP_SECS ))
while (( SECONDS < deadline )); do
  sleep 1
done
SH
  cat >"${ci}/install-lib.sh" <<'SH'
readonly BARRIER_SECS=60
install_app() {
  timeout "${BARRIER_SECS}" adb -s "$1" shell true
}
lib_self_test() { sleep 999; }
SH
  cat >"${ci}/run-multi.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly LANE="${SCRIPT_DIR}/run-lane.sh"
for spec in "$@"; do
  bash "${LANE}" "${spec}"
done
SH
  cat >"${ci}/run-ios-sim-scenario.sh" <<'SH'
#!/usr/bin/env bash
flutter test integration_test/x.dart -d "$1" &
pid=$!
wait "${pid}"
SH
  cat >"${b}/scripts/ci/e2e_lane_budget.manifest" <<'MF'
# fixture
unit tooling/e2e/ci/helper.sh
up sleep:1#1 charge UP_SECS + 1

lib tooling/e2e/ci/install-lib.sh
barrier install_app/timeout:BARRIER_SECS#1 charge BARRIER_SECS

unit tooling/e2e/ci/run-lane.sh
helper bash:helper.sh#1 charge @
install lib:install_app#1 charge @
drip sleep:POLL_SECS#1 concurrent
ready sleep:POLL_SECS#2 charge READY_SECS
settle sleep:SETTLE_SECS#1 charge SETTLE_SECS
drive timeout:DRIVE_TIMEOUT#1 charge DRIVE_TIMEOUT + DRIVE_KILL_AFTER_SECS
MF
}

# _lb_add_reaper <tree> <deadline> [<args>] — the multi-target lane.
_lb_add_reaper() {
  cat >"$1/.github/workflows/multi.yml" <<YML
jobs:
  multi:
    runs-on: ubuntu-latest
    timeout-minutes: 190
    steps:
      - name: Drive
        timeout-minutes: 180
        uses: reactivecircus/android-emulator-runner@v2
        with:
          emulator-boot-timeout: 420
          script: bash tooling/e2e/ci/run-with-deadline.sh $2 "multi" -- bash tooling/e2e/ci/run-multi.sh ${3:-a b c}
YML
  printf '%s\n' '' 'reaper multi.yml::multi three targets, each a full run-lane.sh' \
    'unit tooling/e2e/ci/run-multi.sh' 'each bash:run-lane.sh#1 charge @ times ARGC' \
    >>"$1/scripts/ci/e2e_lane_budget.manifest"
}

_lb_add_ios() {
  cat >"$1/.github/workflows/ios.yml" <<'YML'
jobs:
  ios:
    runs-on: macos-latest
    timeout-minutes: 90
    steps:
      - name: Drive
        timeout-minutes: 70
        uses: nick-fields/retry@v3
        with:
          timeout_minutes: 30
          max_attempts: 2
          command: >-
            bash tooling/e2e/ci/run-ios-sim-scenario.sh
            some-udid
YML
  printf '%s\n' '' 'unbudgeted ios.yml::ios the attempt timeout is the only bound on flutter test' \
    >>"$1/scripts/ci/e2e_lane_budget.manifest"
}

# _lb_sub <file> <exact line> <replacement> — the first line equal to <exact
# line> becomes <replacement> (which may hold newlines). A fixture whose line
# is gone stops the suite, rather than testing an unedited tree.
_lb_sub() {
  local f="$1" old="$2" new="$3" out="" line hit=0
  while IFS= read -r line || [[ -n "${line}" ]]; do
    if (( ! hit )) && [[ "${line}" == "${old}" ]]; then out+="${new}"$'\n'; hit=1; else out+="${line}"$'\n'; fi
  done <"${f}"
  (( hit )) || lb_die "self-test fixture: no line '${old}' in ${f}"
  printf '%s' "${out}" >"${f}"
}

lb_self_test() {
  local tmp t cases=0 fails=0 lane lf mf
  local A="${UNBOUNDED_WORK_ALLOWANCE_SECS}" B="${LB_ST_BUDGET}"
  local D=$(( LB_ST_BUDGET + UNBOUNDED_WORK_ALLOWANCE_SECS + 59 ))
  tmp="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf '${tmp}'" RETURN
  _lb_mk_base "${tmp}/base" "${D}"

  _lb_tree() {
    rm -rf "${tmp}/$1"; cp -R "${tmp}/base" "${tmp}/$1"; t="${tmp}/$1"
    lane="${t}/tooling/e2e/ci/run-lane.sh"; lf="${t}/.github/workflows/lane.yml"
    mf="${t}/scripts/ci/e2e_lane_budget.manifest"
  }
  _lb_mf() { printf '%s\n' "$@" >>"${mf}"; }
  # _lb_expect <desc> <want-rc> [<ere the output must carry>] [<ere it must not>]
  # The check runs in a subshell because a misconfig exits; the verdict is its
  # rc, which the subshell derives from the violation count itself. The lane
  # report is part of the output, so a case can pin a lane's computed number.
  _lb_expect() {
    local desc="$1" want="$2" re="${3:-}" nre="${4:-}" out rc=0
    cases=$(( cases + 1 ))
    out="$( (lb_check_repo "${t}"; printf '%s\n' ${LB_REPORT[@]+"${LB_REPORT[@]}"}; (( LB_VIOL == 0 )) || exit 1) 2>&1 )" || rc=$?
    if (( rc != want )); then
      echo "  FAIL: ${desc}: want rc ${want}, got ${rc}" >&2
      sed 's/^/      /' <<<"${out}" >&2
      fails=$(( fails + 1 )); return 0
    fi
    if [[ -n "${re}" ]] && ! grep -qE -- "${re}" <<<"${out}"; then
      echo "  FAIL: ${desc}: the output does not say /${re}/" >&2
      sed 's/^/      /' <<<"${out}" >&2
      fails=$(( fails + 1 )); return 0
    fi
    if [[ -n "${nre}" ]] && grep -qE -- "${nre}" <<<"${out}"; then
      echo "  FAIL: ${desc}: the output says /${nre}/" >&2
      sed 's/^/      /' <<<"${out}" >&2
      fails=$(( fails + 1 )); return 0
    fi
    echo "  ok: ${desc}"
  }
  # _lb_blind_expect <desc> <from> <to> <ere> — the check run with the
  # analyzer's text <from> replaced by <to>, blinding it to one kind of wait
  # as a bad edit would; the second reading must stop it (rc 2, <ere>).
  _lb_blind_expect() {
    local desc="$1" from="$2" to="$3" re="$4" out rc=0 blind
    cases=$(( cases + 1 ))
    blind="${LB_AWK//"${from}"/"${to}"}"
    if [[ "${blind}" == "${LB_AWK}" ]]; then
      echo "  FAIL: ${desc}: the fixture could not blind the analyzer" >&2
      fails=$(( fails + 1 )); return 0
    fi
    out="$( (LB_AWK="${blind}"; lb_check_repo "${t}"; (( LB_VIOL == 0 )) || exit 1) 2>&1 )" || rc=$?
    if (( rc == 2 )) && grep -qE -- "${re}" <<<"${out}"; then
      echo "  ok: ${desc}"
    else
      echo "  FAIL: ${desc}: the second reading did not stop a blind analyzer (rc ${rc})" >&2
      sed 's/^/      /' <<<"${out}" >&2
      fails=$(( fails + 1 ))
    fi
  }
  local settle='sleep "${SETTLE_SECS}"' drivecmd=' -- bash tooling/e2e/ci/run-lane.sh'
  echo "[${LB_NAME}] self-test"

  # --- Both directions of the core rule. ------------------------------------
  _lb_tree sound
  _lb_expect "a sound lane passes at its computed sum; waits in a comment, a heredoc, strings, the self-test branch and uncalled code do not count" \
    0 "ok     lane.yml::lane \(Drive\): $(( B + A )) s = ${B} \+ ${A} allowance <= ${D}s"

  _lb_tree raised
  _lb_sub "${lane}" 'readonly SETTLE_SECS=20' 'readonly SETTLE_SECS=80'
  _lb_expect "a wait constant raised without raising the deadline fails" \
    1 "worst case $(( B + 60 + A )) s .* EXCEEDS its ${D}s deadline \(${D} s\) by 1 s"

  _lb_tree undeclared
  _lb_sub "${lane}" "${settle}" "${settle}"$'\nsleep 5'
  _lb_expect "an undeclared new wait fails" 1 'sleep:5#1: a sleep the budget does not claim'

  _lb_tree declared
  _lb_sub "${lane}" "${settle}" "${settle}"$'\nsleep 5'
  _lb_mf 'extra sleep:5#1 charge 5'
  _lb_expect "a wait added to the declared budget passes" 0 "ok .*: $(( B + 5 + A )) s"

  _lb_tree allowance
  _lb_sub "${mf}" 'unit tooling/e2e/ci/run-lane.sh' $'unit tooling/e2e/ci/run-lane.sh\nallowance 60'
  _lb_expect "a lane carrying its own allowance is refused" 2 'a lane cannot carry its own'

  _lb_tree shaved
  _lb_sub "${mf}" 'helper bash:helper.sh#1 charge @' 'helper bash:helper.sh#1 charge @ - 31'
  _lb_expect "a charge below the wait's own bound fails" 1 'charges 0 s, below this wait.s own bound of 31 s'

  # --- Reaper and macOS exemptions. -----------------------------------------
  _lb_tree false-reaper
  _lb_mf 'reaper lane.yml::lane it is a long run, it says'
  _lb_expect "an ordinary lane falsely claiming the reaper exemption fails" 1 'declared reaper .*runs 1 drive'

  _lb_tree reaper
  _lb_add_reaper "${t}" 25m
  _lb_expect "a reaper lane passes" 0 "reaper multi.yml::multi \(Drive\): 3 drives, worst $(( 3 * B + A )) s"

  _lb_tree reaper-fits
  _lb_add_reaper "${t}" "$(( 3 * B + A + 60 ))s"
  _lb_expect "a reaper whose worst case fits its deadline fails" 1 'fits the [0-9]+s deadline'

  _lb_tree reaper-drive
  _lb_add_reaper "${t}" 10m
  _lb_expect "a reaper whose single drive outlives its deadline fails" 1 'one drive.s own bound \(630 s\) is not below'

  _lb_tree reaper-inflated
  _lb_sub "${mf}" 'drive timeout:DRIVE_TIMEOUT#1 charge DRIVE_TIMEOUT + DRIVE_KILL_AFTER_SECS' \
    'drive timeout:DRIVE_TIMEOUT#1 charge DRIVE_TIMEOUT + DRIVE_KILL_AFTER_SECS times 3'
  _lb_mf 'reaper lane.yml::lane three drives, it says'
  _lb_expect "a retry count cannot make one drive look like the many a reaper needs" 1 'declared reaper .*runs 1 drive'

  _lb_tree reaper-argc-once
  sed -i "s|${drivecmd}\$| -- bash tooling/e2e/ci/run-lane.sh a b|" "${lf}"
  _lb_sub "${mf}" 'drive timeout:DRIVE_TIMEOUT#1 charge DRIVE_TIMEOUT + DRIVE_KILL_AFTER_SECS' \
    'drive timeout:DRIVE_TIMEOUT#1 charge DRIVE_TIMEOUT + DRIVE_KILL_AFTER_SECS times ARGC'
  _lb_mf 'reaper lane.yml::lane two arguments, so two drives, it says'
  _lb_expect "a positional count on a drive no loop over the targets repeats is still one drive" 1 'declared reaper .*runs 1 drive'

  _lb_tree ios
  _lb_add_ios "${t}"
  _lb_expect "a macOS retry lane with an unbounded launch is unbudgeted" 0 'unbudg ios.yml::ios'

  _lb_tree android-unbudgeted
  _lb_mf 'unbudgeted lane.yml::lane it has no bound, it says'
  _lb_expect "an Android lane declared unbudgeted fails" 1 'only a nick-fields/retry lane on a macOS runner'

  _lb_tree linux-retry-unbudgeted
  _lb_add_ios "${t}"
  _lb_sub "${t}/.github/workflows/ios.yml" '    runs-on: macos-latest' '    runs-on: ubuntu-latest'
  _lb_expect "a retry lane on a Linux runner declared unbudgeted fails" 1 'only a nick-fields/retry lane on a macOS runner'

  _lb_tree ios-bounded
  _lb_add_ios "${t}"
  _lb_sub "${t}/tooling/e2e/ci/run-ios-sim-scenario.sh" 'flutter test integration_test/x.dart -d "$1" &' \
    'timeout 20m flutter test integration_test/x.dart -d "$1" &'
  _lb_expect "a macOS lane whose launch is bounded must be budgeted" 1 'every launch its harness makes is bounded now'

  # --- What a charge must name, and what a loop can spend. ------------------
  _lb_tree no-kill-after
  _lb_sub "${mf}" 'drive timeout:DRIVE_TIMEOUT#1 charge DRIVE_TIMEOUT + DRIVE_KILL_AFTER_SECS' 'drive timeout:DRIVE_TIMEOUT#1 charge DRIVE_TIMEOUT'
  _lb_expect "a drive charged without its kill-after fails" 1 'names neither this wait.s bound'

  _lb_tree tick
  _lb_sub "${mf}" 'ready sleep:POLL_SECS#2 charge READY_SECS' 'ready sleep:POLL_SECS#2 charge POLL_SECS'
  _lb_expect "a loop's wait charged by its tick alone fails" 1 'the loop at line [0-9]+ repeats this wait'

  _lb_tree floor-odd
  _lb_sub "${lane}" 'readonly READY_SECS=40' 'readonly READY_SECS=41'
  _lb_expect "a counted loop whose bound is no multiple of its step spends one more pass" 1 'the loop at line [0-9]+ can spend 42 s in this wait'

  _lb_tree floor-expr
  _lb_sub "${lane}" 'while (( waited < READY_SECS )); do' 'while (( waited < READY_SECS * 2 )); do'
  _lb_expect "a loop bounded by an expression is charged by its value, not its names" 1 'can spend 80 s in this wait'

  _lb_tree floor-wall
  _lb_sub "${mf}" 'up sleep:1#1 charge UP_SECS + 1' 'up sleep:1#1 charge UP_SECS'
  _lb_expect "a wall-clock loop's last tick past its bound is charged" 1 'can spend 31 s in this wait \(bound UP_SECS, wall clock'

  _lb_tree caller-arg
  _lb_sub "${lane}" 'readonly READY_SECS=40' $'readonly READY_SECS=40\npoll_for() {\n  local limit="$1" n=0\n  while (( n < limit )); do\n    sleep "${POLL_SECS}"\n    n=$(( n + POLL_SECS ))\n  done\n}'
  _lb_sub "${lane}" "${settle}" "${settle}"$'\npoll_for "${READY_SECS}"'
  _lb_mf 'poll-for poll_for#1/sleep:POLL_SECS#1 charge READY_SECS'
  _lb_expect "a loop bounded by its caller's argument is charged by that argument" 0 "ok .*: $(( B + 40 + A )) s"

  _lb_tree bad-poll
  _lb_sub "${mf}" 'ready sleep:POLL_SECS#2 charge READY_SECS' 'ready sleep:POLL_SECS#2 poll'
  _lb_expect "a poll on a loop nothing releases fails" 1 'is a poll, but the loop'

  _lb_tree good-poll
  _lb_sub "${lane}" 'kill "${DRIP_PID}"' $'( sleep 1 ) &\nJOB_PID=$!\nwhile kill -0 "${JOB_PID}" 2>/dev/null; do\n  sleep "${POLL_SECS}"\ndone\nkill "${DRIP_PID}"'
  _lb_mf 'job sleep:1#1 charge 1' 'job-watch sleep:POLL_SECS#3 poll'
  _lb_expect "a poll released by kill -0 of a job whose wait is charged passes, at one period" 0 "ok .*: $(( B + 1 + 2 + A )) s"

  _lb_tree poll-concurrent
  _lb_sub "${lane}" 'kill "${DRIP_PID}"' $'( sleep 1 ) &\nJOB_PID=$!\nwhile kill -0 "${JOB_PID}" 2>/dev/null; do\n  sleep "${POLL_SECS}"\ndone\nkill "${DRIP_PID}"'
  _lb_mf 'job sleep:1#1 concurrent' 'job-watch sleep:POLL_SECS#3 poll'
  _lb_expect "a poll on a job whose waits nobody charges fails" 1 "polls the job in .JOB_PID, but that job's waits are not charged"

  _lb_tree stop-file
  _lb_sub "${lane}" "${settle}" $'STOP_FILE=/tmp/lane-stop\n( while [[ ! -e "${STOP_FILE}" ]]; do sleep "${POLL_SECS}"; done ) &\nSERVO_PID=$!\n'"${settle}"
  _lb_sub "${lane}" 'kill "${DRIP_PID}"' $'touch "${STOP_FILE}"\nwait "${SERVO_PID}"\nkill "${DRIP_PID}"'
  _lb_mf 'servo sleep:POLL_SECS#3 poll'
  _lb_expect "a poll released by a stop file the script touches passes" 0 "ok .*: $(( B + 2 + A )) s"

  _lb_tree stop-file-untouched
  _lb_sub "${lane}" "${settle}" $'STOP_FILE=/tmp/lane-stop\n( while [[ ! -e "${STOP_FILE}" ]]; do sleep "${POLL_SECS}"; done ) &\nSERVO_PID=$!\n'"${settle}"
  _lb_sub "${lane}" 'kill "${DRIP_PID}"' $'wait "${SERVO_PID}"\nkill "${DRIP_PID}"'
  _lb_mf 'servo sleep:POLL_SECS#3 poll'
  _lb_expect "a poll on a stop file nothing touches fails" 1 'is released by no `kill -0` of a captured PID and no'

  _lb_tree once-within
  _lb_sub "${lane}" "${settle}" $'for attempt in 1 2; do\n  sleep "${SETTLE_SECS}"\n  break\ndone\nsleep 4'
  _lb_sub "${mf}" 'settle sleep:SETTLE_SECS#1 charge SETTLE_SECS' \
    $'settle sleep:SETTLE_SECS#1 charge SETTLE_SECS once the loop breaks after its first pass\nsettle-tail sleep:4#1 within settle a fixture: its time is inside the settle window'
  _lb_expect "once and within pass when they give a reason" 0 "ok .*: $(( B + A )) s"

  _lb_tree within-sum
  _lb_sub "${lane}" "${settle}" "${settle}"$'\nsleep 30'
  _lb_mf 'settle-tail sleep:30#1 within settle a fixture: said to be inside the settle window'
  _lb_expect "waits within an anchor that outlast its charge fail" 1 "the waits within 'settle' can take 30 s together, more than the 20 s"

  _lb_tree joined
  _lb_sub "${lane}" 'kill "${DRIP_PID}"' 'wait "${DRIP_PID}"'
  _lb_expect "a concurrent claim on a joined job fails" 1 'is joined with `wait`'

  _lb_tree bare-wait
  _lb_sub "${lane}" 'kill "${DRIP_PID}"' $'finish() { wait; }\nfinish'
  _lb_expect "a bare wait in a called function joins every job" 1 'is joined with `wait`'

  _lb_tree self-test-wait
  _lb_sub "${lane}" '  sleep 900' $'  sleep 900\n  wait'
  _lb_expect "a wait in the --self-test branch joins nothing on a lane" 0

  _lb_tree not-bg
  _lb_sub "${mf}" 'settle sleep:SETTLE_SECS#1 charge SETTLE_SECS' 'settle sleep:SETTLE_SECS#1 concurrent'
  _lb_expect "a concurrent claim on a foreground wait fails" 1 'on the lane.s own path, not in a background job'

  _lb_tree no-pid
  _lb_sub "${lane}" 'kill "${DRIP_PID}"' $'( sleep 11 ) &\nkill "${DRIP_PID}"'
  _lb_mf 'orphan sleep:11#1 concurrent'
  _lb_expect "a concurrent claim on a job whose PID is never captured fails" 1 'has no PID captured'

  _lb_tree stale
  _lb_mf 'ghost sleep:99#1 charge 99'
  _lb_expect "a stale claim fails" 1 'matches no wait .*: a stale claim'

  _lb_tree stale-section
  _lb_mf '' 'unit tooling/e2e/ci/nowhere.sh' 'x sleep:1#1 charge 1'
  _lb_expect "a section no lane reaches fails" 1 '\[tooling/e2e/ci/nowhere.sh\] is on no budgeted lane.s path'

  _lb_tree stale-decl
  _lb_mf 'reaper ghost.yml::ghost a lane that is gone'
  _lb_expect "a declaration no drive step matches fails" 1 'reaper ghost.yml::ghost matches no drive step'

  _lb_tree within
  _lb_sub "${mf}" 'settle sleep:SETTLE_SECS#1 charge SETTLE_SECS' 'settle sleep:SETTLE_SECS#1 within nowhere inside a window nobody charges'
  _lb_expect "a within claim on no charged anchor fails" 1 'is within .nowhere., which is not a charged claim'

  _lb_tree allowance-sleep
  _lb_sub "${mf}" 'settle sleep:SETTLE_SECS#1 charge SETTLE_SECS' 'settle sleep:SETTLE_SECS#1 allowance'
  _lb_expect "a bounded wait put under the allowance fails" 1 'puts a sleep under the unbounded-work allowance'

  _lb_tree wait-for
  _lb_sub "${lane}" "${settle}" "${settle}"$'\nadb wait-for-device\ngrep -q "wait-for-device" /tmp/x || true\ngrep wait-for-device /tmp/x || true'
  _lb_mf 'device wait-for-device#1 allowance'
  _lb_expect "a device wait-for sits under the allowance; the same words as a grep pattern are not a wait" \
    0 "ok .*: $(( B + A )) s" 'wait-for-device#2'

  _lb_tree unevaluable
  _lb_sub "${mf}" 'settle sleep:SETTLE_SECS#1 charge SETTLE_SECS' 'settle sleep:SETTLE_SECS#1 charge NOPE_SECS'
  _lb_expect "a charge that cannot be evaluated fails and leaves the lane INCOMPLETE, not ok" \
    1 'INCOMP lane.yml::lane \(Drive\): 1 wait\(s\) not counted' 'ok     lane.yml'

  _lb_tree times-zero
  _lb_sub "${lane}" "${settle}" "${settle}"$'\nreadonly RETRIES=0\nfor (( r = 0; r < RETRIES; r++ )); do sleep 3; done'
  _lb_mf 'retry sleep:3#1 charge 3 times RETRIES'
  _lb_expect "a retry that runs zero times costs nothing" 0 "ok .*: $(( B + A )) s"

  _lb_tree times-negative
  _lb_sub "${lane}" "${settle}" "${settle}"$'\nreadonly RETRIES=0\nfor (( r = 0; r < RETRIES; r++ )); do sleep 3; done'
  _lb_mf 'retry sleep:3#1 charge 3 times RETRIES - 1'
  _lb_expect "a negative count fails" 1 'multiplies by -1'

  _lb_tree not-readonly
  _lb_sub "${lane}" 'readonly SETTLE_SECS=20' 'SETTLE_SECS=20'
  _lb_expect "a bound whose constant is not readonly fails" 1 'SETTLE_SECS in tooling/e2e/ci/run-lane.sh is not readonly'

  # --- Where waits hide. ----------------------------------------------------
  _lb_tree subst
  _lb_sub "${lane}" "${settle}" "${settle}"$'\nx="$(sleep 3)"'
  _lb_expect "a wait inside \"\$( … )\" counts" 1 'sleep:3#1: a sleep the budget does not claim'

  _lb_tree wrapped
  _lb_sub "${lane}" "${settle}" "${settle}"$'\nsudo -u nobody nice -n 5 sleep 6'
  _lb_expect "a wait behind sudo -u and nice -n counts" 1 'sleep:6#1: a sleep the budget does not claim'

  _lb_tree abs-path
  _lb_sub "${lane}" "${settle}" "${settle}"$'\nsudo -n /usr/bin/sleep 6'
  _lb_expect "a wait by absolute path behind sudo -n counts" 1 'sleep:6#1: a sleep the budget does not claim'

  _lb_tree read-t
  _lb_sub "${lane}" "${settle}" "${settle}"$'\nread -rt 7 line < /dev/null || true'
  _lb_expect "a clustered read -rt counts" 1 'read-t:7#1: a read-t the budget does not claim'

  _lb_tree xtables
  _lb_sub "${lane}" "${settle}" "${settle}"$'\nsudo iptables -w 5 -L >/dev/null || true'
  _lb_expect "an iptables -w lock wait counts" 1 'iptables-w:5#1: a lock the budget does not claim'

  _lb_tree trap-exit
  _lb_sub "${lane}" "${settle}" $'cleanup() { sleep 8; }\ntrap cleanup EXIT\n'"${settle}"
  _lb_expect "a wait in an EXIT trap counts" 1 'cleanup#1/sleep:8#1: a sleep the budget does not claim'

  _lb_tree function-kw
  _lb_sub "${lane}" "${settle}" $'function waiter { sleep 9; }\nwaiter\n'"${settle}"
  _lb_expect "a function declared with the function keyword is followed" 1 'waiter#1/sleep:9#1: a sleep the budget does not claim'

  _lb_tree not-self-test
  _lb_sub "${lane}" "${settle}" "${settle}"$'\nif [[ "${1:-}" != "--self-test" ]]; then sleep 12; fi'
  _lb_expect "a branch that runs when NOT under --self-test is a lane path" 1 'sleep:12#1: a sleep the budget does not claim'

  _lb_tree case-arm
  _lb_sub "${lane}" "${settle}" "${settle}"$'\ncase "${1:-}" in --self-test) sleep 13 ;; esac'
  _lb_expect "a --self-test case arm is not a lane path" 0 "ok .*: $(( B + A )) s"

  _lb_tree case-arm-shared
  _lb_sub "${lane}" "${settle}" "${settle}"$'\ncase "${1:-}" in --self-test|--dry-run) sleep 14 ;; esac'
  _lb_expect "a case arm --self-test shares with another pattern is a lane path" 1 'sleep:14#1: a sleep the budget does not claim'

  _lb_tree assign-word
  _lb_sub "${lane}" "${settle}" "${settle}"$'\nx=timeout; y=sleep; echo "${x}${y}"'
  _lb_expect "a wait word as an assignment's value is not a wait, to either reading" 0 "ok .*: $(( B + A )) s"

  _lb_tree helper-wait
  echo 'sleep 7' >>"${t}/tooling/e2e/ci/helper.sh"
  _lb_expect "a new wait in a called helper script fails" 1 'helper.sh:[0-9]+ sleep:7#1'

  _lb_tree second-install
  _lb_sub "${lane}" 'install_app emulator-5554 /tmp/app.apk' $'install_app emulator-5554 /tmp/app.apk\ninstall_app emulator-5554 /tmp/app.apk'
  _lb_expect "a second call to a waiting library function fails" 1 'lib:install_app#2: a call the budget does not claim'

  _lb_tree cmd
  sed -i "s|${drivecmd}\$| -- bash -c \"sleep 30 \\&\\& bash tooling/e2e/ci/run-lane.sh\"|" "${lf}"
  _lb_expect "a wait in the deadline command itself fails" 1 "runs 'sleep' inside the deadline"

  _lb_tree multi-line
  sed -i 's|^          script: \(.*\)$|          script: \|\n            \1|' "${lf}"
  _lb_expect "a multi-line emulator script fails" 1 'a multi-line script'

  # --- Values come from the code and the workflow. --------------------------
  _lb_tree env-inline
  sed -i "s|${drivecmd}\$| -- bash -c \"LANE_DRIVE_TIMEOUT=16m bash tooling/e2e/ci/run-lane.sh\"|" "${lf}"
  _lb_expect "a drive timeout the workflow raises is read" 1 "worst case $(( B + 360 + A )) s"

  _lb_tree env-step
  _lb_sub "${lf}" '        uses: reactivecircus/android-emulator-runner@v2' \
    $'        env:\n          LANE_DRIVE_TIMEOUT: 16m\n        uses: reactivecircus/android-emulator-runner@v2'
  _lb_expect "a drive timeout the step env raises is read" 1 "worst case $(( B + 360 + A )) s"

  _lb_tree env-block
  _lb_sub "${lf}" '        uses: reactivecircus/android-emulator-runner@v2' \
    $'        env:\n          NOTE: |\n            a block scalar\n          LANE_DRIVE_TIMEOUT: 16m\n        uses: reactivecircus/android-emulator-runner@v2'
  _lb_expect "an env key after a block scalar is still read" 1 "worst case $(( B + 360 + A )) s"

  _lb_tree env-block-value
  _lb_sub "${lf}" '        uses: reactivecircus/android-emulator-runner@v2' \
    $'        env:\n          LANE_DRIVE_TIMEOUT: >-\n            16m\n        uses: reactivecircus/android-emulator-runner@v2'
  _lb_expect "a block-scalar value is folded as YAML folds it" 1 "worst case $(( B + 360 + A )) s"

  _lb_tree export
  _lb_sub "${lane}" 'bash "${SCRIPT_DIR}/helper.sh"' $'export HELPER_UP_SECS=45\nbash "${SCRIPT_DIR}/helper.sh"'
  _lb_sub "${t}/tooling/e2e/ci/helper.sh" 'readonly UP_SECS=30' 'readonly UP_SECS="${HELPER_UP_SECS:-30}"'
  _lb_expect "a value a script exports reaches the script it runs" 0 "ok .*: $(( B + 15 + A )) s"

  # What the caller passed is the value only while the script does not set
  # the name itself first, some way other than a top-level NAME=value.
  local wrote='reads LANE_DRIVE_TIMEOUT, but [^ ]*run-lane.sh:[0-9]+ writes LANE_DRIVE_TIMEOUT itself'
  local dtline='readonly DRIVE_TIMEOUT="${LANE_DRIVE_TIMEOUT:-10m}"'
  _lb_tree env-colon-default
  _lb_sub "${lane}" "${dtline}" $': "${LANE_DRIVE_TIMEOUT:=16m}"\n'"${dtline}"
  _lb_expect "a name the script defaults itself with \${NAME:=…} is not read from the caller" 1 "${wrote}"

  _lb_tree env-function-default
  _lb_sub "${lane}" "${dtline}" $'lane_defaults() { LANE_DRIVE_TIMEOUT=16m; }\nlane_defaults\n'"${dtline}"
  _lb_expect "a name a function the script calls first sets is not read from the caller" 1 "${wrote}"

  _lb_tree env-printf-v
  _lb_sub "${lane}" "${dtline}" $'printf -v LANE_DRIVE_TIMEOUT \'%s\' 16m\n'"${dtline}"
  _lb_expect "a name the script sets with printf -v is not read from the caller" 1 "${wrote}"

  _lb_tree env-unset
  _lb_sub "${lane}" "${dtline}" $'unset LANE_DRIVE_TIMEOUT\nreadonly DRIVE_TIMEOUT="${LANE_DRIVE_TIMEOUT:-16m}"'
  _lb_sub "${lf}" '        uses: reactivecircus/android-emulator-runner@v2' \
    $'        env:\n          LANE_DRIVE_TIMEOUT: 10m\n        uses: reactivecircus/android-emulator-runner@v2'
  _lb_expect "a name the script unsets is not read from the caller" 1 "${wrote}"

  local helper='bash "${SCRIPT_DIR}/helper.sh"' upline='readonly UP_SECS=30' unread='HELPER_UP_SECS=.[?]. depends on an expression'
  _lb_tree export-rewritten
  _lb_sub "${lane}" "${helper}" $'export HELPER_UP_SECS=30\nprintf -v HELPER_UP_SECS \'%s\' 90\n'"${helper}"
  _lb_sub "${t}/tooling/e2e/ci/helper.sh" "${upline}" 'readonly UP_SECS="${HELPER_UP_SECS:-30}"'
  _lb_expect "an export the script then rewrites reaches the script it runs at no value this can read" 1 "${unread}"

  _lb_tree inherited-rewritten
  _lb_sub "${lf}" '        uses: reactivecircus/android-emulator-runner@v2' \
    $'        env:\n          HELPER_UP_SECS: 30\n        uses: reactivecircus/android-emulator-runner@v2'
  _lb_sub "${lane}" "${helper}" $'printf -v HELPER_UP_SECS \'%s\' 90\n'"${helper}"
  _lb_sub "${t}/tooling/e2e/ci/helper.sh" "${upline}" 'readonly UP_SECS="${HELPER_UP_SECS:-30}"'
  _lb_expect "an inherited name the script rewrites reaches the script it runs at no value this can read" 1 "${unread}"

  # What a script run through a wrapper inherits: env's words, less what
  # env -u, env -i or exec -c take away; under sudo, its policy's.
  local up90='readonly UP_SECS="${HELPER_UP_SECS:-90}"' short="worst case $(( B + 60 + A )) s .* by 1 s"
  _lb_tree env-wrapper
  _lb_sub "${lane}" "${helper}" "env HELPER_UP_SECS=90 ${helper}"
  _lb_sub "${t}/tooling/e2e/ci/helper.sh" "${upline}" 'readonly UP_SECS="${HELPER_UP_SECS:-30}"'
  _lb_expect "a value env passes to the script it runs is read" 1 "${short}"

  _lb_tree env-u
  _lb_sub "${lane}" "${helper}" $'export HELPER_UP_SECS=30\nenv -u HELPER_UP_SECS '"${helper}"
  _lb_sub "${t}/tooling/e2e/ci/helper.sh" "${upline}" "${up90}"
  _lb_expect "a name env -u takes from the script it runs is that script's default" 1 "${short}"

  _lb_tree env-i
  _lb_sub "${lane}" "${helper}" $'export HELPER_UP_SECS=30\nenv -i '"${helper}"
  _lb_sub "${t}/tooling/e2e/ci/helper.sh" "${upline}" "${up90}"
  _lb_expect "a script env -i runs inherits nothing" 1 "${short}"

  _lb_tree exec-c
  _lb_sub "${lane}" "${helper}" $'export HELPER_UP_SECS=30\n( exec -c '"${helper}"' )'
  _lb_sub "${t}/tooling/e2e/ci/helper.sh" "${upline}" "${up90}"
  _lb_expect "a script exec -c runs inherits nothing" 1 "${short}"

  _lb_tree sudo-child
  _lb_sub "${lane}" "${helper}" $'export HELPER_UP_SECS=30\nsudo '"${helper}"
  _lb_sub "${t}/tooling/e2e/ci/helper.sh" "${upline}" "${up90}"
  _lb_expect "what sudo passes to the script it runs is its policy's, which this cannot read" 1 "${unread}"

  _lb_tree sudo-preserve
  _lb_sub "${lane}" "${helper}" $'export HELPER_UP_SECS=30\nsudo -E '"${helper}"
  _lb_sub "${t}/tooling/e2e/ci/helper.sh" "${upline}" "${up90}"
  _lb_expect "sudo -E passes the environment on" 0 "ok .*: $(( B + A )) s"

  _lb_tree branches
  grep -v 'script: ' "${lf}" >"${lf}.new"
  # shellcheck disable=SC2016
  printf '%s\n' "          script: bash tooling/e2e/ci/run-with-deadline.sh \${{ inputs.live_sync && '$(( D + 300 ))s' || '${D}s' }} \"lane drive\" -- bash -c 'LANE_DRIVE_TIMEOUT=\${{ inputs.live_sync && '20m' || '10m' }} bash tooling/e2e/ci/run-lane.sh'" >>"${lf}.new"
  mv "${lf}.new" "${lf}"
  _lb_expect "a live_sync lane whose true branch is short fails, naming the branch" 1 "\[true branch\]: worst case $(( B + 600 + A )) s"

  _lb_tree mixed-conditions
  grep -v 'script: ' "${lf}" >"${lf}.new"
  # shellcheck disable=SC2016
  printf '%s\n' "          script: bash tooling/e2e/ci/run-with-deadline.sh \${{ inputs.a && '${D}s' || '${D}s' }} \"lane drive\" -- bash -c 'LANE_DRIVE_TIMEOUT=\${{ inputs.b && '10m' || '9m' }} bash tooling/e2e/ci/run-lane.sh'" >>"${lf}.new"
  mv "${lf}.new" "${lf}"
  _lb_expect "a lane reading values chosen by two conditions fails" 1 "chosen by different conditions \('inputs.a','inputs.b'\)"

  _lb_tree unread-condition
  grep -v 'script: ' "${lf}" >"${lf}.new"
  # shellcheck disable=SC2016
  printf '%s\n' "          script: bash tooling/e2e/ci/run-with-deadline.sh \${{ inputs.a && '${D}s' || '${D}s' }} \"lane drive\" -- bash -c 'UNUSED=\${{ inputs.b && 'x' || 'y' }} bash tooling/e2e/ci/run-lane.sh'" >>"${lf}.new"
  mv "${lf}.new" "${lf}"
  _lb_expect "a second condition on a value the lane never reads is harmless" 0 "ok .*: $(( B + A )) s"

  _lb_tree github-env
  _lb_sub "${lf}" '    steps:' $'    steps:\n      - name: Set\n        run: |\n          {\n            echo "LANE_DRIVE_TIMEOUT=30m"\n          } >> "${GITHUB_ENV}"'
  _lb_expect "a budget value written to GITHUB_ENV fails" 1 'written to GITHUB_ENV'

  _lb_tree input-default
  _lb_sub "${lf}" '        uses: reactivecircus/android-emulator-runner@v2' \
    $'        env:\n          LANE_DRIVE_TIMEOUT: ${{ inputs.t || \'10m\' }}\n        uses: reactivecircus/android-emulator-runner@v2'
  _lb_expect "an input's default is no bound for an ordinary lane" 1 "is an input's default, and a dispatch can pass any value"

  _lb_tree input-default-reaper
  # shellcheck disable=SC2016
  _lb_add_reaper "${t}" 25m '${{ inputs.targets || '"'"'a b c'"'"' }}'
  _lb_expect "an input's default may size a reaper, whose sum already exceeds its deadline" 0 'reaper multi.yml::multi \(Drive\): 3 drives'

  _lb_tree argc-default
  _lb_add_reaper "${t}" "${D}s" '${{ inputs.targets || '"'"'a'"'"' }}'
  _lb_sub "${mf}" 'reaper multi.yml::multi three targets, each a full run-lane.sh' '# not a reaper'
  _lb_expect "a target count from an input's default is no count for an ordinary lane" 1 "ARGC: argument 1 \('a'\) depends on"

  # "$@" at a script's top level forwards its own arguments; inside a
  # function it is the function's, which this check does not count.
  _lb_tree forward-args
  _lb_add_reaper "${t}" "${D}s" 'a b c'
  _lb_sub "${mf}" 'reaper multi.yml::multi three targets, each a full run-lane.sh' '# not a reaper'
  _lb_sub "${mf}" 'each bash:run-lane.sh#1 charge @ times ARGC' $'forward bash:run-each.sh#1 charge @\nunit tooling/e2e/ci/run-each.sh\neach sleep:2#1 charge 2 times ARGC'
  printf '%s\n' '#!/usr/bin/env bash' 'bash "$(dirname "$0")/run-each.sh" "$@"' >"${t}/tooling/e2e/ci/run-multi.sh"
  printf '%s\n' '#!/usr/bin/env bash' 'for s in "$@"; do sleep 2; done' >"${t}/tooling/e2e/ci/run-each.sh"
  _lb_expect "a script forwarding \"\$@\" passes its own argument count" 0 "ok     multi.yml::multi \(Drive\): $(( 6 + A )) s = 6 \+"

  _lb_tree forward-args-fn
  _lb_add_reaper "${t}" "${D}s" 'a b c'
  _lb_sub "${mf}" 'reaper multi.yml::multi three targets, each a full run-lane.sh' '# not a reaper'
  _lb_sub "${mf}" 'each bash:run-lane.sh#1 charge @ times ARGC' $'forward go#1/bash:run-each.sh#1 charge @\nunit tooling/e2e/ci/run-each.sh\neach sleep:2#1 charge 2 times ARGC'
  printf '%s\n' '#!/usr/bin/env bash' 'go() { bash "$(dirname "$0")/run-each.sh" "$@"; }' 'go x' >"${t}/tooling/e2e/ci/run-multi.sh"
  printf '%s\n' '#!/usr/bin/env bash' 'for s in "$@"; do sleep 2; done' >"${t}/tooling/e2e/ci/run-each.sh"
  _lb_expect "a function's \"\$@\" leaves the called script's argument count unknowable" 1 'ARGC: which words the arguments are depends on a "\$@"'

  # --- Waits that hide in the forms bash also accepts. ----------------------
  _lb_tree timeout-zero
  _lb_sub "${lf}" '        uses: reactivecircus/android-emulator-runner@v2' \
    $'        env:\n          LANE_DRIVE_TIMEOUT: "0"\n        uses: reactivecircus/android-emulator-runner@v2'
  _lb_expect "a timeout of 0, which never expires, is no bound" 1 'a duration of 0 never expires'

  _lb_tree loop-or
  _lb_sub "${lane}" 'while (( waited < READY_SECS )); do' 'while (( waited < READY_SECS )) || ! grep -q ready /tmp/state; do'
  _lb_expect "a loop header with || is not bounded by its comparison" 1 "'ready' is charged by the loop at line [0-9]+, but its bound cannot be read"

  _lb_tree stop-file-fg
  _lb_sub "${lane}" "${settle}" $'STOP_FILE=/tmp/lane-stop\nwhile [[ ! -e "${STOP_FILE}" ]]; do sleep "${POLL_SECS}"; done\n'"${settle}"
  _lb_sub "${lane}" 'kill "${DRIP_PID}"' $'touch "${STOP_FILE}"\nkill "${DRIP_PID}"'
  _lb_mf 'servo sleep:POLL_SECS#3 poll'
  _lb_expect "a stop-file poll in the foreground, which nothing can release, fails" 1 'the loop runs in the foreground'

  _lb_tree stop-file-bg-toucher
  _lb_sub "${lane}" "${settle}" $'STOP_FILE=/tmp/lane-stop\n( while [[ ! -e "${STOP_FILE}" ]]; do sleep "${POLL_SECS}"; done ) &\nSERVO_PID=$!\n( sleep 1; touch "${STOP_FILE}" ) &\nTOUCH_PID=$!\n'"${settle}"
  _lb_sub "${lane}" 'kill "${DRIP_PID}"' $'wait "${SERVO_PID}"\nkill "${DRIP_PID}"'
  _lb_mf 'servo sleep:POLL_SECS#3 poll' 'toucher sleep:1#1 concurrent'
  _lb_expect "a stop file touched only by a background job releases nothing on the path" 1 'is released by no `kill -0` of a captured PID and no'

  _lb_tree wait-jobspec
  _lb_sub "${lane}" 'kill "${DRIP_PID}"' 'wait %1'
  _lb_expect "a wait on a job spec joins every job" 1 'is joined with `wait`'

  _lb_tree wait-copy
  _lb_sub "${lane}" 'kill "${DRIP_PID}"' $'PIDS="${DRIP_PID}"\nwait ${PIDS}'
  _lb_expect "a wait on a variable that holds no captured PID joins every job" 1 'is joined with `wait`'

  _lb_tree flutter-flags
  _lb_add_ios "${t}"
  _lb_sub "${t}/tooling/e2e/ci/run-ios-sim-scenario.sh" 'flutter test integration_test/x.dart -d "$1" &' \
    'flutter --verbose test integration_test/x.dart -d "$1" &'
  _lb_expect "a launch with global flags before its subcommand is still a launch" 0 'unbudg ios.yml::ios'

  _lb_tree flutter-global-drive
  _lb_sub "${lane}" "${settle}" "${settle}"$'\nflutter -v drive --target y'
  _lb_expect "a drive with a global option before its subcommand is a wait a budget must claim" 1 'launch:flutter-drive#1: a launch the budget does not claim'

  _lb_tree flutter-no-launch
  _lb_sub "${lane}" "${settle}" "${settle}"$'\nflutter pub run build_runner build\nflutter -v pub run build_runner build\nflutter -v build apk --debug'
  _lb_expect "flutter pub run and a build launch nothing, to either reading" 0 "ok .*: $(( B + A )) s"

  _lb_tree direct-script
  _lb_sub "${lane}" 'bash "${SCRIPT_DIR}/helper.sh"' '"${SCRIPT_DIR}/helper.sh"'
  _lb_expect "a script run by its path, without bash, is still followed" 0 "ok .*: $(( B + A )) s"

  _lb_tree source-var
  _lb_sub "${lane}" 'source "${SCRIPT_DIR}/install-lib.sh"' $'readonly INSTALL_LIB="${SCRIPT_DIR}/install-lib.sh"\nsource "${INSTALL_LIB}"'
  _lb_expect "a library sourced through a variable is still read" 0 "ok .*: $(( B + A )) s"

  _lb_tree lib-to-lib
  printf '%s\n' 'readonly SETTLE_DEVICE_SECS=30' 'settle_device() { sleep "${SETTLE_DEVICE_SECS}"; }' >"${t}/tooling/e2e/ci/wait-lib.sh"
  _lb_sub "${t}/tooling/e2e/ci/install-lib.sh" '  timeout "${BARRIER_SECS}" adb -s "$1" shell true' \
    $'  timeout "${BARRIER_SECS}" adb -s "$1" shell true\n  settle_device'
  _lb_sub "${lane}" 'source "${SCRIPT_DIR}/install-lib.sh"' $'source "${SCRIPT_DIR}/install-lib.sh"\nsource "${SCRIPT_DIR}/wait-lib.sh"'
  _lb_expect "a library function that calls another library's waiting function fails" 1 'calls settle_device of tooling/e2e/ci/wait-lib.sh, which waits'

  _lb_tree array-literal
  _lb_sub "${lane}" 'readonly READY_SECS=40' $'readonly READY_SECS=40\nreadonly HELPERS=(\n  helper.sh\n  install-lib.sh\n)'
  _lb_expect "the words of an array literal are not commands" 0 "ok .*: $(( B + A )) s"

  _lb_tree lib-top-level
  printf '%s\n' 'sleep 3' >>"${t}/tooling/e2e/ci/install-lib.sh"
  _lb_expect "a wait at a library's top level, run wherever it is sourced, fails" 1 "install-lib.sh: sleep:3#1 waits at the library's top level"

  _lb_tree lib-sources-lib
  printf '%s\n' 'readonly SETTLE_DEVICE_SECS=30' 'settle_device() { sleep "${SETTLE_DEVICE_SECS}"; }' >"${t}/tooling/e2e/ci/wait-lib.sh"
  _lb_sub "${t}/tooling/e2e/ci/install-lib.sh" 'readonly BARRIER_SECS=60' $'readonly BARRIER_SECS=60\nsource "$(dirname "${BASH_SOURCE[0]}")/wait-lib.sh"'
  _lb_sub "${t}/tooling/e2e/ci/install-lib.sh" '  timeout "${BARRIER_SECS}" adb -s "$1" shell true' \
    $'  timeout "${BARRIER_SECS}" adb -s "$1" shell true\n  settle_device'
  _lb_expect "a library that sources another and calls its waiting function fails" 1 'calls settle_device of tooling/e2e/ci/wait-lib.sh, which waits'

  _lb_tree trap-string
  _lb_sub "${lane}" "${settle}" $'cleanup() { sleep 8; }\ntrap -- \'cleanup "$?"\' EXIT\n'"${settle}"
  _lb_expect "an EXIT trap whose action string calls a function is followed" 1 'cleanup#1/sleep:8#1: a sleep the budget does not claim'

  _lb_tree trap-wait-string
  _lb_sub "${lane}" "${settle}" $'trap \'sleep 5\' EXIT\n'"${settle}"
  _lb_expect "a wait written into a trap's action string must be claimed" 1 'trap:sleep#1: a trap the budget does not claim'

  _lb_tree backslash
  _lb_sub "${lane}" "${settle}" "${settle}"$'\n\\sleep 300'
  _lb_expect "a backslashed command name is still a wait" 1 'sleep:300#1: a sleep the budget does not claim'

  _lb_tree bash-stdin
  _lb_sub "${lane}" "${settle}" "${settle}"$'\nbash <<\'STDIN\'\nsleep 300\nSTDIN'
  _lb_expect "bash reading its script from a heredoc is a script this cannot see, to be claimed" 1 'bash:\?#1: a script the budget does not claim'

  _lb_tree adb-shell-sleep
  _lb_sub "${lane}" "${settle}" "${settle}"$'\nadb -s emulator-5554 shell sleep 300'
  _lb_expect "a device-side sleep blocks the host adb call and counts" 1 'sleep:300#1: a sleep the budget does not claim'

  _lb_tree subshell-function
  _lb_sub "${lane}" "${settle}" $'settle_once() ( sleep "${SETTLE_SECS}" )\nsettle_once\n'"${settle}"
  _lb_expect "a function whose body is a subshell is a function" 1 'settle_once#1/sleep:SETTLE_SECS#1: a sleep the budget does not claim'

  _lb_tree nested-function
  _lb_sub "${lane}" "${settle}" $'outer() {\n  inner() { sleep 9; }\n  inner\n}\nouter\n'"${settle}"
  _lb_expect "a function defined inside another runs where it is called" 1 'outer#1/inner#1/sleep:9#1: a sleep the budget does not claim'

  _lb_tree read-array-t
  _lb_sub "${lane}" "${settle}" "${settle}"$'\nread -ra words -t 5 < /dev/null || true'
  _lb_expect "read's -t after an array option and its name counts" 1 'read-t:5#1: a read-t the budget does not claim'

  _lb_tree timeout-short-flag
  _lb_sub "${lane}" "${settle}" "${settle}"$'\ntimeout -p 5 true'
  _lb_expect "timeout's -p is a flag, not its duration" 1 'timeout:5#1: a timeout the budget does not claim'

  _lb_tree nc-w
  _lb_sub "${lane}" "${settle}" "${settle}"$'\nnc -w 3 127.0.0.1 1 || true'
  _lb_expect "an nc -w connect wait counts" 1 'nc-w:3#1: a nc-w the budget does not claim'

  # Every wrapper the header names, each claimed at its own bound: the sum is
  # exact, and a wrapper this stopped reading would leave a claim stale.
  _lb_tree wrappers
  _lb_sub "${lane}" "${settle}" "${settle}"$'\nenv A=1 sleep 21\nstdbuf -oL sleep 22\nionice -c 3 sleep 23\ntaskset -c 0 sleep 24\nchrt 10 sleep 25\n( exec sleep 26 )\ntime -p sleep 27\nnohup sleep 28 >/dev/null\nsetsid -w sleep 29\ncommand sleep 31\nbuiltin read -t 32 x < /dev/null || true'
  _lb_mf 'w21 sleep:21#1 charge 21' 'w22 sleep:22#1 charge 22' 'w23 sleep:23#1 charge 23' 'w24 sleep:24#1 charge 24' \
    'w25 sleep:25#1 charge 25' 'w26 sleep:26#1 charge 26' 'w27 sleep:27#1 charge 27' 'w28 sleep:28#1 charge 28' \
    'w29 sleep:29#1 charge 29' 'w31 sleep:31#1 charge 31' 'w32 read-t:32#1 charge 32'
  sed -i "s|run-with-deadline.sh ${D}s|run-with-deadline.sh $(( D + 300 ))s|" "${lf}"
  _lb_expect "a wait behind env, stdbuf, ionice, taskset, chrt, exec, time -p, nohup, setsid -w, command or builtin counts" \
    0 "ok .*: $(( B + 288 + A )) s"

  # --- Which branch is the --self-test one. ---------------------------------
  _lb_tree self-test-dash
  _lb_sub "${lane}" 'if [[ "${1:-}" == "--self-test" ]]; then' 'if [[ "${1-}" == "--self-test" ]]; then'
  _lb_expect "\${1-} names the first argument too" 0 "ok .*: $(( B + A )) s"

  _lb_tree self-test-or
  _lb_sub "${lane}" "${settle}" "${settle}"$'\nif [[ "${1:-}" == "--self-test" || -n "${CI:-}" ]]; then sleep 77; fi'
  _lb_expect "a condition that also runs the branch without --self-test is a lane path" 1 'sleep:77#1: a sleep the budget does not claim'

  _lb_tree self-test-same-line
  _lb_sub "${lane}" "${settle}" "${settle}"$'\nif [[ -z "${X:-}" ]]; then sleep 78; fi; [[ "${1:-}" == --self-test ]] && exit 0'
  _lb_expect "a --self-test test elsewhere on the line excludes nothing" 1 'sleep:78#1: a sleep the budget does not claim'

  _lb_tree case-other-subject
  _lb_sub "${lane}" "${settle}" "${settle}"$'\ncase "${MODE:-}" in --self-test) sleep 79 ;; esac'
  _lb_expect "a --self-test arm on a subject other than the first argument is a lane path" 1 'sleep:79#1: a sleep the budget does not claim'

  _lb_tree case-arg-alias
  _lb_sub "${lane}" "${settle}" "${settle}"$'\ndispatch() {\n  local cmd="${1:-run}"\n  case "${cmd}" in --self-test) sleep 81 ;; esac\n}\ndispatch "$@"'
  _lb_expect "a --self-test arm on a variable set from the first argument is not a lane path" 0 "ok .*: $(( B + A )) s"

  # --- What loops can spend, and what constants hold. -----------------------
  _lb_tree deadline-reused
  printf '%s\n' 'readonly SLOW_SECS=600' 'deadline=$(( SECONDS + SLOW_SECS ))' 'while (( SECONDS < deadline )); do sleep 1; done' \
    >>"${t}/tooling/e2e/ci/helper.sh"
  _lb_expect "a loop whose deadline variable is set to two values is not bounded by the first" 1 "'up' is charged by the loop at line [0-9]+, but its bound cannot be read"

  _lb_tree two-steps
  _lb_sub "${lane}" '  waited=$(( waited + POLL_SECS ))' '  waited=$(( waited + 1 ))'
  _lb_sub "${lane}" "${settle}" "${settle}"$'\nwhile (( waited < SETTLE_SECS * 10 )); do waited=$(( waited + SETTLE_SECS )); done'
  _lb_expect "a counter moved by two different steps is counted at the smallest" 1 'can spend 80 s in this wait'

  _lb_tree counted-and-clock
  _lb_sub "${lane}" 'waited=0' $'waited="$(date +%s)"\nwaited=0'
  _lb_expect "a counter that is both counted and read from the clock is not read" 1 "'ready' is charged by the loop at line [0-9]+, but its bound cannot be read"

  # After the shift, limit is the caller's second word (LONG_SECS), so a
  # charge by the first (READY_SECS) must not link.
  _lb_tree shifted
  _lb_sub "${lane}" 'readonly READY_SECS=40' $'readonly READY_SECS=40\nreadonly LONG_SECS=400\npoll_for() {\n  local what="$1"; shift\n  local limit="$1" n=0\n  while (( n < limit )); do\n    sleep "${POLL_SECS}"\n    n=$(( n + POLL_SECS ))\n  done\n}'
  _lb_sub "${lane}" "${settle}" "${settle}"$'\npoll_for "${READY_SECS}" "${LONG_SECS}"'
  _lb_mf 'poll-for poll_for#1/sleep:POLL_SECS#1 charge READY_SECS'
  _lb_expect "after a shift, a positional is no caller's argument this can name" 1 'names neither this wait.s bound'

  _lb_tree le-pass
  _lb_sub "${lane}" 'while (( waited < READY_SECS )); do' 'while (( waited <= READY_SECS )); do'
  _lb_expect "a <= bound runs one pass more" 1 'can spend 42 s in this wait'

  _lb_tree within-loop
  _lb_sub "${lane}" "${settle}" "${settle}"$'\nfor (( t = 0; t < 6; t++ )); do sleep 4; done'
  _lb_mf 'settle-tail sleep:4#1 within settle a fixture: said to fit the settle window'
  _lb_expect "a within wait in a loop counts what the loop can spend in it" 1 "the waits within 'settle' can take 24 s together, more than the 20 s"

  # A counter or bound its header does not govern alone.
  local unread_ready="'ready' is charged by the loop at line [0-9]+, but its bound cannot be read"
  local inc_line='  waited=$(( waited + POLL_SECS ))'
  _lb_tree loop-negative-start
  _lb_sub "${lane}" 'waited=0' 'waited=-400'
  _lb_expect "a counter that starts below zero is not counted from its header" 1 "${unread_ready}"

  _lb_tree loop-body-reset
  _lb_sub "${lane}" "${inc_line}" "${inc_line}"$'\n  [[ ! -f /tmp/again ]] || waited=0'
  _lb_expect "a counter the loop's body resets is not counted from its header" 1 "${unread_ready}"

  _lb_tree loop-arith-back
  _lb_sub "${lane}" "${inc_line}" "${inc_line}"$'\n  (( waited -= 1 ))'
  _lb_expect "a counter arithmetic moves back is not counted from its header" 1 "${unread_ready}"

  _lb_tree loop-one-line-back
  _lb_sub "${lane}" 'while (( waited < READY_SECS )); do' 'while (( waited < READY_SECS )); do (( waited -= 1 )); :'
  _lb_expect "a one-line body that moves the counter back is the body's, not the header's" 1 "${unread_ready}"

  _lb_tree loop-arith-step
  _lb_sub "${lane}" "${inc_line}" '  (( waited += POLL_SECS ))'
  _lb_expect "a counter arithmetic steps forward by a constant is counted from its header" 0 "ok .*: $(( B + A )) s"

  _lb_tree loop-arith-incr
  _lb_sub "${lane}" "${settle}" "${settle}"$'\nreadonly TICKS=6\nn=0\nwhile (( n < TICKS )); do\n  sleep 4\n  (( n++ ))\ndone'
  _lb_mf 'tick sleep:4#1 charge 4 * TICKS'
  _lb_expect "a counter arithmetic steps forward by one is counted from its header" 0 "ok .*: $(( B + 24 + A )) s"

  _lb_tree loop-bound-grows
  _lb_sub "${lane}" 'readonly READY_SECS=40' $'readonly READY_SECS=40\npoll_for() {\n  local limit="$1" n=0\n  while (( n < limit )); do\n    sleep "${POLL_SECS}"\n    n=$(( n + POLL_SECS ))\n    (( limit += 2 ))\n  done\n}'
  _lb_sub "${lane}" "${settle}" "${settle}"$'\npoll_for "${READY_SECS}"'
  _lb_mf 'poll-for poll_for#1/sleep:POLL_SECS#1 charge READY_SECS'
  _lb_expect "a bound the loop's own body raises is no bound" 1 "'poll-for' is charged by the loop at line [0-9]+, but its bound cannot be read"

  local unread_tick="'tick' is charged by the loop at line [0-9]+, but its bound cannot be read"
  _lb_tree for-negative-start
  _lb_sub "${lane}" "${settle}" "${settle}"$'\nreadonly TICKS=6\nfor (( t = -30; t < TICKS; t++ )); do sleep 4; done'
  _lb_mf 'tick sleep:4#1 charge 4 * TICKS'
  _lb_expect "a for (( )) that starts below zero is not counted from its header" 1 "${unread_tick}"

  _lb_tree for-step-back
  _lb_sub "${lane}" "${settle}" "${settle}"$'\nreadonly TICKS=6\nfor (( t = 0; t < TICKS; t-- )); do sleep 4; done'
  _lb_mf 'tick sleep:4#1 charge 4 * TICKS'
  _lb_expect "a for (( )) whose step moves back is not counted from its header" 1 "${unread_tick}"

  _lb_tree for-step-plus
  _lb_sub "${lane}" "${settle}" "${settle}"$'\nreadonly TICKS=12\nfor (( t = 0; t < TICKS; t += 2 )); do sleep 4; done'
  _lb_mf 'tick sleep:4#1 charge 2 * TICKS'
  _lb_expect "a for (( )) stepping by a constant takes its passes from that step" 0 "ok .*: $(( B + 24 + A )) s"

  _lb_tree clock-set
  _lb_sub "${t}/tooling/e2e/ci/helper.sh" 'deadline=$(( SECONDS + UP_SECS ))' $'deadline=$(( SECONDS + UP_SECS ))\nSECONDS=0'
  _lb_expect "a script that sets SECONDS bounds no wall-clock loop by its header" 1 "'up' is charged by the loop at line [0-9]+, but its bound cannot be read"

  _lb_tree readonly-transitive
  _lb_sub "${lane}" 'readonly SETTLE_SECS=20' $'settle_base=20\nprintf -v settle_base \'%d\' 300\nreadonly SETTLE_SECS=$(( settle_base ))'
  _lb_expect "a readonly bound read from a constant that is not readonly fails" 1 'settle_base in tooling/e2e/ci/run-lane.sh is not readonly'

  _lb_tree later-definition
  _lb_sub "${lane}" 'readonly SETTLE_SECS=20' 'readonly SETTLE_SECS="${SETTLE_OVERRIDE:-300}"'
  _lb_sub "${lane}" 'kill "${DRIP_PID}"' $'kill "${DRIP_PID}"\nSETTLE_OVERRIDE=20'
  _lb_expect "a default overridden only by a later line is the default" 1 "worst case $(( B + 280 + A )) s"

  _lb_tree positional-constant
  _lb_sub "${lane}" 'readonly SETTLE_SECS=20' 'readonly SETTLE_SECS="${1:-20}"'
  sed -i "s|${drivecmd}\$| -- bash tooling/e2e/ci/run-lane.sh 45|" "${lf}"
  _lb_expect "a constant from the script's argument takes the lane's argument" 0 "ok .*: $(( B + 25 + A )) s"

  # A top-level shift or set moves the arguments every positional read sees.
  _lb_tree shift-constant
  _lb_sub "${lane}" 'readonly SETTLE_SECS=20' $'shift\nreadonly SETTLE_SECS="${1:-20}"'
  sed -i "s|${drivecmd}\$| -- bash tooling/e2e/ci/run-lane.sh 5 300|" "${lf}"
  _lb_expect "a constant read from a positional the script has shifted is refused" 1 'reads a positional argument, but [^ ]*run-lane.sh:[0-9]+ moves them'

  _lb_tree shift-argc
  _lb_add_reaper "${t}" 25m 'x a'
  _lb_sub "${t}/tooling/e2e/ci/run-multi.sh" 'for spec in "$@"; do' $'shift\nfor spec in "$@"; do'
  _lb_expect "a target count after a shift is no count, so one drive cannot pass as two" 1 'ARGC: [^ ]*run-multi.sh:[0-9]+ moves the positional arguments'

  _lb_tree shift-forward
  _lb_add_reaper "${t}" "${D}s" 'a b c'
  _lb_sub "${mf}" 'reaper multi.yml::multi three targets, each a full run-lane.sh' '# not a reaper'
  _lb_sub "${mf}" 'each bash:run-lane.sh#1 charge @ times ARGC' $'forward bash:run-each.sh#1 charge @\nunit tooling/e2e/ci/run-each.sh\neach sleep:2#1 charge 2 times ARGC'
  printf '%s\n' '#!/usr/bin/env bash' 'shift' 'bash "$(dirname "$0")/run-each.sh" "$@"' >"${t}/tooling/e2e/ci/run-multi.sh"
  printf '%s\n' '#!/usr/bin/env bash' 'for s in "$@"; do sleep 2; done' >"${t}/tooling/e2e/ci/run-each.sh"
  _lb_expect "\"\$@\" forwarded after a shift is no count of the script's own" 1 'ARGC: which words the arguments are depends on a "\$@"'

  _lb_tree shift-child-arg
  _lb_sub "${lane}" 'bash "${SCRIPT_DIR}/helper.sh"' $'shift\nbash "${SCRIPT_DIR}/helper.sh" "$1"'
  _lb_sub "${t}/tooling/e2e/ci/helper.sh" 'readonly UP_SECS=30' 'readonly UP_SECS="${1:-30}"'
  sed -i "s|${drivecmd}\$| -- bash tooling/e2e/ci/run-lane.sh 30 90|" "${lf}"
  _lb_expect "a positional a script passes on after a shift is no value this can read" 1 'UP_SECS: argument 1 [(].[?].[)] depends on an expression or input'

  _lb_tree excluded-pass
  _lb_sub "${lane}" "${settle}" "${settle}"$'\nsleep 5'
  _lb_mf 'extra sleep:5#1 excluded a fixture: it runs only under a flag no lane sets'
  _lb_expect "an exclusion with its reason passes, at no cost" 0 "ok .*: $(( B + A )) s"

  _lb_tree unquoted-lane-args
  _lb_add_reaper "${t}" "${D}s" '$TARGETS'
  _lb_sub "${mf}" 'reaper multi.yml::multi three targets, each a full run-lane.sh' '# not a reaper'
  _lb_sub "${t}/.github/workflows/multi.yml" '    runs-on: ubuntu-latest' $'    runs-on: ubuntu-latest\n    env:\n      TARGETS: a b c'
  _lb_expect "a target count from an unquoted expansion in the lane command is no count" 1 'ARGC: which words the arguments are depends on'

  _lb_tree unquoted-script-args
  _lb_add_reaper "${t}" "${D}s" 'a'
  _lb_sub "${mf}" 'reaper multi.yml::multi three targets, each a full run-lane.sh' '# not a reaper'
  _lb_sub "${mf}" 'each bash:run-lane.sh#1 charge @ times ARGC' $'forward bash:run-each.sh#1 charge @\nunit tooling/e2e/ci/run-each.sh\neach sleep:2#1 charge 2 times ARGC'
  printf '%s\n' '#!/usr/bin/env bash' 'readonly SPECS="a b c"' 'bash "$(dirname "$0")/run-each.sh" ${SPECS}' >"${t}/tooling/e2e/ci/run-multi.sh"
  printf '%s\n' '#!/usr/bin/env bash' 'for s in "$@"; do sleep 2; done' >"${t}/tooling/e2e/ci/run-each.sh"
  _lb_expect "a target count from an unquoted expansion in a script is no count" 1 'ARGC: which words the arguments are depends on'

  _lb_tree retry-is-not-a-target
  _lb_sub "${lane}" 'kill "${DRIP_PID}"' $'if [[ -f /tmp/retry ]]; then\n  timeout --kill-after="${DRIVE_KILL_AFTER_SECS}s" "${DRIVE_TIMEOUT}" flutter drive --target x\nfi\nkill "${DRIP_PID}"'
  _lb_mf 'retry-drive timeout:DRIVE_TIMEOUT#2 charge DRIVE_TIMEOUT + DRIVE_KILL_AFTER_SECS' 'reaper lane.yml::lane a retry makes it two drives, it says'
  _lb_expect "a drive only a retry branch reaches is not a second target" 1 'declared reaper .*runs 1 drive'

  _lb_tree incomplete-short
  _lb_sub "${lane}" 'readonly SETTLE_SECS=20' 'readonly SETTLE_SECS=80'
  _lb_sub "${lane}" "${settle}" "${settle}"$'\nsleep 5'
  _lb_mf 'extra sleep:5#1 charge NOPE_SECS'
  _lb_expect "a lane short even without the waits it could not count is short" 1 "worst case at least $(( B + 60 + A )) s"

  _lb_tree empty-section
  _lb_mf '' 'unit tooling/e2e/ci/gone.sh'
  _lb_expect "a section with no claims that no lane reaches fails" 1 '\[tooling/e2e/ci/gone.sh\] is on no budgeted lane.s path'

  # --- How a workflow sets a value. -----------------------------------------
  _lb_tree env-comment
  _lb_sub "${lf}" '        uses: reactivecircus/android-emulator-runner@v2' \
    $'        env:  # the drive\'s knobs\n          LANE_DRIVE_TIMEOUT: 16m\n        uses: reactivecircus/android-emulator-runner@v2'
  _lb_expect "an env: line with a comment is still read" 1 "worst case $(( B + 360 + A )) s"

  _lb_tree env-deep
  _lb_sub "${lf}" '        uses: reactivecircus/android-emulator-runner@v2' \
    $'        env:\n            LANE_DRIVE_TIMEOUT: 16m\n        uses: reactivecircus/android-emulator-runner@v2'
  _lb_expect "env keys at any indentation are read" 1 "worst case $(( B + 360 + A )) s"

  _lb_tree env-job
  _lb_sub "${lf}" '    runs-on: ubuntu-latest' $'    runs-on: ubuntu-latest\n    env:\n      LANE_DRIVE_TIMEOUT: 16m'
  _lb_expect "a job's env is read" 1 "worst case $(( B + 360 + A )) s"

  _lb_tree env-workflow
  _lb_sub "${lf}" 'on: [push]' $'on: [push]\nenv:\n  LANE_DRIVE_TIMEOUT: 16m'
  _lb_expect "a workflow's env is read" 1 "worst case $(( B + 360 + A )) s"

  _lb_tree env-scope-order
  _lb_sub "${lf}" '        uses: reactivecircus/android-emulator-runner@v2' \
    $'        env:\n          LANE_DRIVE_TIMEOUT: 16m\n        uses: reactivecircus/android-emulator-runner@v2'
  printf '%s\n' '    env:' '      LANE_DRIVE_TIMEOUT: 10m' >>"${lf}"
  _lb_expect "a step's env wins over its job's, wherever each sits in the file" 1 "worst case $(( B + 360 + A )) s"

  _lb_tree github-env-heredoc
  _lb_sub "${lf}" '    steps:' $'    steps:\n      - name: Set\n        run: |\n          echo "LANE_DRIVE_TIMEOUT<<EOF" >> "${GITHUB_ENV}"\n          echo 30m >> "${GITHUB_ENV}"\n          echo EOF >> "${GITHUB_ENV}"'
  _lb_expect "a value written to GITHUB_ENV in its multi-line form fails" 1 'written to GITHUB_ENV'

  _lb_tree falsy-branch
  grep -v 'script: ' "${lf}" >"${lf}.new"
  # shellcheck disable=SC2016
  printf '%s\n' "          script: bash tooling/e2e/ci/run-with-deadline.sh \${{ inputs.fast && '${D}s' || '${D}s' }} \"lane drive\" -- bash -c 'LANE_DRIVE_TIMEOUT=\${{ inputs.fast && '' || '16m' }} bash tooling/e2e/ci/run-lane.sh'" >>"${lf}.new"
  mv "${lf}.new" "${lf}"
  _lb_expect "c && '' || B yields B on both branches, as GitHub evaluates it" 1 "lane.yml::lane \(Drive\): worst case $(( B + 360 + A )) s"

  _lb_tree matrix-expression
  _lb_sub "${lf}" '        uses: reactivecircus/android-emulator-runner@v2' \
    $'        env:\n          LANE_DRIVE_TIMEOUT: ${{ matrix.t }}\n        uses: reactivecircus/android-emulator-runner@v2'
  _lb_expect "a value from an expression this cannot evaluate fails" 1 'depends on an expression this check cannot evaluate'

  _lb_tree raw-timeout-deadline
  sed -i "s|          script: bash tooling/e2e/ci/run-with-deadline.sh ${D}s \"lane drive\" -- |          script: timeout ${D}s |" "${lf}"
  _lb_expect "a deadline written as timeout <dl> is read" 0 "ok .*<= ${D}s"

  # --- The check itself cannot run: rc 2, never a pass. ---------------------
  _lb_tree unreadable
  echo "echo 'never closed" >>"${lane}"
  _lb_expect "a script the analyzer cannot read is rc 2" 2 'cannot read tooling/e2e/ci/run-lane.sh'

  _lb_tree no-reason
  _lb_mf 'quiet sleep:99#1 excluded'
  _lb_expect "an exclusion without a reason is rc 2" 2 'needs a reason'

  _lb_tree bare-glob
  _lb_mf 'everything * excluded all of it, whatever it is'
  _lb_expect "a pattern that names no kind of wait is rc 2" 2 'must end in a wait leaf'

  _lb_tree octal
  _lb_sub "${mf}" 'settle sleep:SETTLE_SECS#1 charge SETTLE_SECS' 'settle sleep:SETTLE_SECS#1 charge 08'
  _lb_expect "a charge bash would read as octal is rc 2" 2 "charge '08 ' is not an expression"

  _lb_tree recursion
  _lb_sub "${lane}" "${settle}" $'rec() { sleep 1; rec; }\nrec\n'"${settle}"
  _lb_expect "a waiting function that calls itself is rc 2" 2 'recursive call to rec, which waits'

  _lb_tree flow-env
  _lb_sub "${lf}" '        uses: reactivecircus/android-emulator-runner@v2' \
    $'        env: { LANE_DRIVE_TIMEOUT: 16m }\n        uses: reactivecircus/android-emulator-runner@v2'
  _lb_expect "an env mapping in flow style is rc 2" 2 'an env mapping this check cannot read'

  _lb_tree once-no-reason
  _lb_sub "${mf}" 'settle sleep:SETTLE_SECS#1 charge SETTLE_SECS' 'settle sleep:SETTLE_SECS#1 charge SETTLE_SECS once'
  _lb_expect "once without its reason is rc 2" 2 '`once` must say why'

  _lb_tree source-unresolvable
  _lb_sub "${lane}" 'source "${SCRIPT_DIR}/install-lib.sh"' 'source "${SOMEWHERE}"'
  _lb_expect "a library this cannot resolve is rc 2" 2 'sources "\$\{SOMEWHERE\}", which this check cannot resolve'

  _lb_tree kind
  _lb_sub "${mf}" 'lib tooling/e2e/ci/install-lib.sh' 'unit tooling/e2e/ci/install-lib.sh'
  _lb_expect "a library claimed as a script's section fails" 1 'is a `unit` section, but a lane reaches it as a `lib`'

  # --- The second reading. An analyzer that stops seeing one kind of wait,
  # as a bad edit to it would, is stopped by app-install-lib.sh's lexer, which
  # still sees the reachable ones — and only those: (1) already ran it over the
  # waits in the --self-test branch, a heredoc and uncalled code.
  _lb_tree second-reading
  _lb_blind_expect "an analyzer that misses a script's reachable wait is stopped by the second reading" \
    'if (W == "sleep")' 'if (W == "sleep-no-more")' "helper.sh:5: app-install-lib.sh's lexer sees 1 wait\\(s\\) here"

  _lb_tree second-reading-lib
  _lb_sub "${t}/tooling/e2e/ci/install-lib.sh" '  timeout "${BARRIER_SECS}" adb -s "$1" shell true' \
    $'  timeout "${BARRIER_SECS}" adb -s "$1" shell true\n  nc -w 3 127.0.0.1 1 || true'
  _lb_blind_expect "an analyzer that misses a library function's wait is stopped by the second reading" \
    'if (W == "nc" || W == "ncat" || W == "netcat")' 'if (W == "nc-no-more")' "install-lib.sh:4: app-install-lib.sh's lexer sees 1 wait\\(s\\) here"

  _lb_tree second-reading-launch
  _lb_sub "${lane}" "${settle}" "${settle}"$'\nflutter -v drive --target y'
  _lb_blind_expect "an analyzer that misses a drive behind a global option is stopped by the second reading" \
    'if (W == "flutter") {' 'if (W == "flutter-no-more") {' "run-lane.sh:[0-9]+: app-install-lib.sh's lexer sees 1 wait\\(s\\) here"

  _lb_tree second-reading-count
  _lb_sub "${lane}" "${settle}" "${settle}"'; (( n = $(sleep 300; echo 1) ))'
  _lb_expect "a line where the lexer sees more waits than the analyzer read stops the check" 2 "run-lane.sh:[0-9]+: app-install-lib.sh's lexer sees 2 wait\(s\) here"

  # --- The SOAK lane: a plain `ubuntu-latest` `run:` step, no emulator action
  # and no simulator harness in its body. Before is_soak_body() the walk
  # `continue`d past it, so the lane declared nothing here and got no budget
  # protection at all — and the stale-section check cannot report a section
  # nobody ever reaches. Three cases: the lane is SEEN (an unclaimed wait in it
  # fails), it passes once the wait is claimed, and a `--self-test` invocation
  # of the same runner is still not a lane.
  _lb_soak() { # _lb_soak <claim?>
    cat >"${t}/tooling/e2e/ci/run-soak-core.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
readonly SOAK_SETTLE_SECS=25
if [[ "${1:-}" == "--self-test" ]]; then
  exit 0
fi
sleep "${SOAK_SETTLE_SECS}"
SH
    cat >"${t}/.github/workflows/soak.yml" <<YML
name: soak
on: [workflow_call]
jobs:
  e2e_soak_core_pr:
    runs-on: ubuntu-latest
    timeout-minutes: 60
    steps:
      - name: Run the soak
        timeout-minutes: 10
        run: bash tooling/e2e/ci/run-with-deadline.sh 6m "soak-core pr" -- bash tooling/e2e/ci/run-soak-core.sh pr
YML
    [[ "${1:-}" != claim ]] || _lb_mf '' 'unit tooling/e2e/ci/run-soak-core.sh' \
      'settle sleep:SOAK_SETTLE_SECS#1 charge SOAK_SETTLE_SECS'
  }

  _lb_tree soak-unclaimed
  _lb_soak
  _lb_expect "a wait in the soak runner is SEEN, not skipped for want of an emulator" 1 \
    'sleep:SOAK_SETTLE_SECS#1: a sleep the budget does not claim'

  _lb_tree soak-claimed
  _lb_soak claim
  _lb_expect "a claimed soak lane is budgeted against its own deadline" 0 \
    "soak.yml::e2e_soak_core_pr .*: $(( 25 + A )) s = 25 \+ ${A} allowance <= 6m"

  _lb_tree soak-self-test
  _lb_soak
  _lb_sub "${t}/.github/workflows/soak.yml" \
    '        run: bash tooling/e2e/ci/run-with-deadline.sh 6m "soak-core pr" -- bash tooling/e2e/ci/run-soak-core.sh pr' \
    '        run: bash tooling/e2e/ci/run-soak-core.sh --self-test'
  _lb_expect "a --self-test invocation of the soak runner is not a lane" 0 '' \
    'run-soak-core.sh'

  if (( cases != LB_SELF_TEST_CASES )); then
    echo "[${LB_NAME}] self-test FAILED: ran ${cases} case(s), expected ${LB_SELF_TEST_CASES}" >&2
    return 1
  fi
  if (( fails > 0 )); then
    echo "[${LB_NAME}] self-test FAILED (${fails} of ${cases})" >&2
    return 1
  fi
  echo "[${LB_NAME}] self-test passed (${cases} cases)"
}


# lb_sites <script> — every wait the analyzer finds, as the manifest names it.
lb_sites() {
  local root="${LB_DIR}/../.." rel="$1" path kind b1 b2 line bg waited loops rest ukind=unit l waits
  root="$(cd "${root}" && pwd)"
  rel="${rel#"${root}/"}"
  [[ -f "${root}/${rel}" ]] || lb_die "no such script: ${rel}"
  lb_load_manifest "${root}/${LB_MANIFEST_REL}"
  [[ "${LB_SEC[${rel}]:-}" != lib ]] || ukind=lib
  lb_load_unit "${root}" "${rel}" "${ukind}"
  while IFS=$'\t' read -r path kind b1 b2 line bg waited loops rest; do
    [[ -n "${path}" ]] || continue
    if [[ "${kind}" == script && "${b1}" != "?" ]]; then
      lb_load_unit "${root}" "tooling/e2e/ci/${b1}" unit
      if [[ -z "${LB_U_SITES[unit:tooling/e2e/ci/${b1}]:-}" ]]; then
        printf '%s:%s  %s  (waits for nothing: no claim)\n' "${rel}" "${line}" "${path}"
        continue
      fi
    elif [[ "${kind}" == call ]]; then
      waits=0
      for l in ${LB_U_LIBS[${ukind}:${rel}]:-}; do [[ " ${LB_L_WF[${l}]:-} " != *" ${b1} "* ]] || waits=1; done
      if (( ! waits )); then
        printf '%s:%s  %s  (waits for nothing: no claim)\n' "${rel}" "${line}" "${path}"
        continue
      fi
    fi
    printf '%s:%s  %s\n' "${rel}" "${line}" "${path}"
    printf '    %s %s%s' "${kind}" "${b1}" "$([[ "${b2}" != "-" ]] && printf ' kill-after %s' "${b2}")"
    if [[ "${bg}" != "-" ]]; then
      local jl="${bg#*:}"; jl="${jl%%:*}"
      printf '  background job (line %s, PID %s, %s)' "${jl}" "${bg##*:}" "${waited}"
    fi
    printf '\n'
    if [[ "${loops}" != "-" ]]; then
      local -a lps=()
      local lp ll ls lk lf lb lle linc lw li
      IFS=';' read -r -a lps <<<"${loops}"
      for lp in "${lps[@]}"; do
        IFS='|' read -r ll ls lk lf lb lle linc lw li <<<"${lp}"
        printf '    in the loop at line %s, whose header names: %s' "${ll}" "${ls:-nothing}"
        if [[ -n "${lb}" ]] && (( lw )); then
          printf '; bounded by %s %s (wall clock)' "$( (( lle )) && echo '<=' || echo '<' )" "${lb}"
        elif [[ -n "${lb}" ]]; then
          printf '; bounded by %s %s, step %s, from %s' "$( (( lle )) && echo '<=' || echo '<' )" "${lb}" "${linc:-unseen, taken as 1}" "${li}"
        fi
        [[ -z "${lk}" ]] || printf '; released by kill -0 %s' "${lk}"
        [[ -z "${lf}" ]] || printf '; released by stop file %s' "${lf}"
        printf '\n'
      done
    fi
  done <<<"${LB_U_SITES[${ukind}:${rel}]:-}"
}

case "${1:-}" in
  --self-test) lb_self_test; exit $? ;;
  --sites) [[ $# -eq 2 ]] || lb_die "usage: ${0##*/} --sites <script>"; lb_sites "$2"; exit 0 ;;
  --root) [[ $# -eq 2 ]] || lb_die "usage: ${0##*/} --root <tree>"; lb_main "$2"; exit $? ;;
  --explain) lb_main "${LB_DIR}/../.." --explain; exit $? ;;
  "") lb_main "${LB_DIR}/../.."; exit $? ;;
  *) lb_die "usage: ${0##*/} [--explain | --sites <script> | --root <tree> | --self-test]" ;;
esac
