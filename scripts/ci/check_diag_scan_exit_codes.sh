#!/usr/bin/env bash
# CI guard: in a step that can report a log-privacy leak, exit code 1 means a
# leak and nothing else.
#
# # The invariant
#
# A workflow step that writes a `*_LEAK.txt` marker scans a log it has just
# written with `tooling/e2e/ci/scan-logs.sh` and branches on the scanner's code:
# 1 is a leak (the wrapper has already withheld the file), anything else
# non-zero is a log that could not be certified (absent, unreadable, empty, or
# no manifest because the run never sealed one). In such a step the only
# literal `exit 1` is the one in the branch that writes the leak marker, and
# the branch that writes the `*_UNSCANNABLE.txt` marker exits with the
# scanner's own code.
#
# # Why
#
# The job summary shows a failed step's exit code and nothing else. In CI run
# 35536892150 seven lanes whose emulator never booted had no manifest to scan
# against (scanner rc 2) and every one of them reported 1 — the LEAK code —
# because both branches said `exit 1`. A red that reads "identifier leaked" on
# a run where no test ran costs a privacy investigation, and teaches the reader
# that the leak code is noise.
#
# # Checks (per step that writes a leak marker)
#
#   E1  No literal `exit 1` outside the branch that writes the leak marker.
#   E2  The branch that writes the unscannable marker exits with a variable the
#       step captured from `$?` — never a constant, never nothing.
#   E3  The leak branch itself says `exit 1`, so the code keeps its meaning.
#
# A "branch" is the run of lines between two of `if`/`elif`/`else`/`fi`; an
# `exit 1` under a nested `if` inside the leak branch therefore fails E1, and
# belongs above it. Full-line comments are not code. An `exit 1` inside a quoted
# string counts: this reads text, and says so rather than guessing.
#
# Pure bash/awk over the checked-out tree, no toolchain — belongs in
# repo-guards.yml.
#
# Usage:
#   check_diag_scan_exit_codes.sh              # check the repo
#   check_diag_scan_exit_codes.sh --self-test
#
# Exit codes:
#   0  every leak-reporting step keeps 1 for the leak
#   1  a step violates one of E1-E3
#   2  the extractor cannot read a step it must grade, the tree holds fewer
#      such steps than are known to exist, or the self-test failed

set -euo pipefail

SCRIPT_NAME="check_diag_scan_exit_codes"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# A redirect INTO the marker, so an upload `path:` naming one is not a write.
readonly LEAK_RE='>[[:space:]]*[^[:space:]]*_LEAK[.]txt'
readonly UNSCANNABLE_RE='>[[:space:]]*[^[:space:]]*_UNSCANNABLE[.]txt'
# The seven Android scenario lanes' "Capture host + emulator diagnostics" steps.
# A floor, not an equality: a new lane with the same step is welcome.
readonly MIN_STEPS=7

log() { printf '\033[1;34m[%s]\033[0m %s\n' "${SCRIPT_NAME}" "$*"; }
fail_msg() { printf '\033[1;31m[%s] FAIL:\033[0m %s\n' "${SCRIPT_NAME}" "$*" >&2; }
misconfig() { printf '\033[1;31m[%s] ERROR:\033[0m %s\n' "${SCRIPT_NAME}" "$*" >&2; exit 2; }

VIOLATIONS=0
note_violation() { fail_msg "$*"; VIOLATIONS=$((VIOLATIONS + 1)); }

# ---------------------------------------------------------------------------
# Extraction — indentation-driven, like check_android_sdk_provisioned.sh's and
# for the same reason. Records, tab-separated:
#   MARK                          a leak-marker write seen inside a step
#   STEP   job  name              a step that writes one (graded)
#   UNSC   job  name              a graded step's unscannable branch
#   E1|E2|E3  job  name  line     a violation
# mawk-safe: no interval expressions, no gawk extensions.
# ---------------------------------------------------------------------------
extract() {
  local file="$1"
  awk -v leak_re="${LEAK_RE}" -v unscannable_re="${UNSCANNABLE_RE}" '
    function reset_step() {
      stepname = "(unnamed)"; marks = 0; seg = 0; rcvars = " "
      split("", leak); split("", unscannable); split("", exit1); split("", varexit)
    }
    function flush_step(   s) {
      if (in_step && marks) {
        printf "STEP\t%s\t%s\n", job, stepname
        for (s = 0; s <= seg; s++) {
          if ((s in exit1) && !(s in leak)) printf "E1\t%s\t%s\t%d\n", job, stepname, exit1[s]
          if ((s in leak) && !(s in exit1)) printf "E3\t%s\t%s\t%d\n", job, stepname, leak[s]
          if (s in unscannable) {
            printf "UNSC\t%s\t%s\n", job, stepname
            if (!(s in varexit) || index(rcvars, " " varexit[s] " ") == 0)
              printf "E2\t%s\t%s\t%d\n", job, stepname, unscannable[s]
          }
        }
      }
      in_step = 0
      reset_step()
    }
    BEGIN { job = "-"; in_jobs = 0; in_steps = 0; in_step = 0; reset_step() }
    /^[A-Za-z_][A-Za-z0-9_-]*:/ { flush_step(); in_steps = 0; in_jobs = ($0 ~ /^jobs:/); next }
    !in_jobs { next }
    /^  [A-Za-z_][A-Za-z0-9_.-]*:[[:space:]]*(#.*)?$/ {
      flush_step(); in_steps = 0
      job = $0; sub(/^  /, "", job); sub(/:[[:space:]]*(#.*)?$/, "", job)
      next
    }
    in_steps && /^    [A-Za-z_]/ { flush_step(); in_steps = 0 }
    /^    steps:[[:space:]]*(#.*)?$/ { in_steps = 1; next }
    !in_steps { next }
    /^      - / {
      flush_step()
      in_step = 1
      if ($0 ~ /^      - name:[[:space:]]*/) { stepname = $0; sub(/^      - name:[[:space:]]*/, "", stepname) }
    }
    !in_step { next }
    /^[[:space:]]*#/ { next }
    {
      t = $0; sub(/^[ \t]+/, "", t)
      if (t ~ /^(if|elif|else|fi)([ \t;]|$)/) seg++
      if (match($0, /[A-Za-z_][A-Za-z0-9_]*=[$][?]/)) rcvars = rcvars substr($0, RSTART, RLENGTH - 3) " "
      if ($0 ~ leak_re) { leak[seg] = NR; marks++; print "MARK" }
      if ($0 ~ unscannable_re) unscannable[seg] = NR
      if ($0 ~ /(^|[^A-Za-z0-9_])exit[ \t]+"?1"?([^0-9]|$)/ && !(seg in exit1)) exit1[seg] = NR
      if (match($0, /(^|[^A-Za-z0-9_])exit[ \t]+"?[$][{]?[A-Za-z_][A-Za-z0-9_]*[}]?"?[ \t]*$/)) {
        v = substr($0, RSTART, RLENGTH)
        sub(/^.*[$][{]?/, "", v); sub(/[}]?"?[ \t]*$/, "", v)
        varexit[seg] = v
      }
    }
    END { flush_step() }
  ' "${file}"
}

# check_dir <dir> — violations on stderr, counts in the globals: a `$(...)`
# capture would run this in a subshell and discard every increment.
GRADED_STEPS=0
UNSCANNABLE_BRANCHES=0
MARKS_SEEN=0
check_dir() {
  local dir="$1" f base kind job name line
  local files=()
  while IFS= read -r f; do files+=("${f}"); done < <(find "${dir}" -maxdepth 1 -name '*.yml' | sort)
  (( ${#files[@]} > 0 )) || misconfig "no workflow files under ${dir}"

  GRADED_STEPS=0
  UNSCANNABLE_BRANCHES=0
  MARKS_SEEN=0
  for f in "${files[@]}"; do
    base="${f##*/}"
    while IFS=$'\t' read -r kind job name line; do
      local label="${base} :: ${job}: '${name}'"
      case "${kind}" in
        MARK) MARKS_SEEN=$((MARKS_SEEN + 1)) ;;
        STEP) GRADED_STEPS=$((GRADED_STEPS + 1)) ;;
        UNSC) UNSCANNABLE_BRANCHES=$((UNSCANNABLE_BRANCHES + 1)) ;;
        E1) note_violation "E1 ${label} (line ${line}): a literal \`exit 1\` outside the branch that writes the leak marker. On this step 1 means an identifier leaked, and the job summary shows nothing but the code — exit with the scanner's own code (\`exit \"\${<rc>}\"\`) instead." ;;
        E2) note_violation "E2 ${label} (line ${line}): the branch that writes the unscannable marker has no \`exit \"\${<rc>}\"\` on a variable this step captured from \`\$?\`. A constant loses which of absent/unreadable/empty/no-manifest it was; no exit at all passes a log nothing certified." ;;
        E3) note_violation "E3 ${label} (line ${line}): the branch that writes the leak marker has no literal \`exit 1\` of its own (one under a nested \`if\` does not count — move it above). 1 is the leak code only while the leak branch is what says it." ;;
        *) misconfig "unreadable extractor record '${kind}' for ${base}" ;;
      esac
    done < <(extract "${f}")
  done
}

# ---------------------------------------------------------------------------
# Anti-vacuity: every uncommented leak-marker write must have been seen INSIDE
# a step. Fewer means a step list this reader skipped (items at six spaces,
# each `- <key>:`), so a leak-reporting step is graded by nothing.
# ---------------------------------------------------------------------------
check_extractor_sees_the_dir() {
  local dir="$1" f n expect=0
  for f in "${dir}"/*.yml; do
    n="$(grep -v '^[[:space:]]*#' "${f}" | grep -cE -- "${LEAK_RE}" || true)"
    expect=$((expect + n))
  done
  if (( expect != MARKS_SEEN )); then
    misconfig "the extractor saw ${MARKS_SEEN} leak-marker write(s) inside steps but ${expect} exist under ${dir}; some step list is laid out in a way it cannot read."
  fi
}

# ---------------------------------------------------------------------------
# Self-test (hermetic: synthetic workflows in a temp dir, no repo access)
# ---------------------------------------------------------------------------

readonly SELF_TEST_FIXTURES=12
readonly FIXTURE_STEP="lane.yml :: lane: 'Capture host + emulator diagnostics'"

# The real step, comment included: the WHY comment in the unscannable branch
# says "never 1", and a reader that graded comments would trip on it.
compliant_wf() {
  printf '%s\n' \
    'jobs:' \
    '  lane:' \
    '    runs-on: ubuntu-latest' \
    '    steps:' \
    '      - name: Checkout' \
    '        uses: actions/checkout@v6' \
    '      - name: Capture host + emulator diagnostics' \
    '        if: failure()' \
    '        run: |' \
    '          mkdir -p /tmp/b8-logs' \
    '          { df -h || true; } > /tmp/b8-logs/diag.log 2>&1 || true' \
    '          diag_scan_rc=0' \
    '          bash tooling/e2e/ci/scan-logs.sh \' \
    '            --sink diag=/tmp/b8-logs/diag.log || diag_scan_rc=$?' \
    '          if [ "${diag_scan_rc}" -eq 1 ]; then' \
    '            echo "diag withheld: log-privacy gate tripped" > /tmp/b8-logs/DIAG_LEAK.txt' \
    '            exit 1' \
    '          elif [ "${diag_scan_rc}" -ne 0 ]; then' \
    '            echo "diag uncertified (rc=${diag_scan_rc})" \' \
    '              > /tmp/b8-logs/DIAG_UNSCANNABLE.txt' \
    '            # The scanner'"'"'s own code, never 1: on this step 1 means a leak.' \
    '            exit "${diag_scan_rc}"' \
    '          fi' \
    '      - name: Upload artifacts' \
    '        if: always()' \
    '        uses: actions/upload-artifact@v6'
}

# expect <label> <want-rc> <dir> [<check> <count>] — rc alone would not do for a
# negative: every check exits 1, so the fixture must fail for the check under
# test, the stated number of times, naming the file, job and step.
expect() {
  local label="$1" want="$2" dir="$3" code="${4:-}" count="${5:-0}" out rc=0
  out="$(
    VIOLATIONS=0
    check_dir "${dir}" 2>&1 >/dev/null
    check_extractor_sees_the_dir "${dir}" 2>&1 >/dev/null
    (( VIOLATIONS == 0 )) || exit 1
  )" || rc=$?
  if [[ "${rc}" != "${want}" ]]; then
    echo "SELF-TEST FAIL (${label}): want rc=${want}, got rc=${rc}" >&2
    return 1
  fi
  [[ -n "${code}" ]] || return 0
  local total named
  total="$(grep -c 'FAIL:' <<<"${out}" || true)"
  named="$(grep -cF "${code} ${FIXTURE_STEP}" <<<"${out}" || true)"
  if [[ "${total}" != "${count}" || "${named}" != "${count}" ]]; then
    echo "SELF-TEST FAIL (${label}): want exactly ${count} violation(s), all ${code} naming ${FIXTURE_STEP}; got ${total}, ${named} of them so" >&2
    return 1
  fi
  return 0
}

run_self_test() {
  local tmp fail=0 ran=0 d
  tmp="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf '${tmp}'" RETURN
  local unscannable_exit='            exit "${diag_scan_rc}"'

  # (1) The real shape.
  ran=$(( ran + 1 )); d="${tmp}/ok"; mkdir -p "${d}"
  compliant_wf > "${d}/lane.yml"
  expect 1 0 "${d}" || fail=1

  # (2) The regression itself: the unscannable branch says `exit 1` again. E2
  #     fires beside E1 — the constant replaced the scanner's code — so this
  #     one is pinned on E1 being among them, and (3) isolates it.
  ran=$(( ran + 1 )); d="${tmp}/regressed"; mkdir -p "${d}"
  compliant_wf | sed "s|^${unscannable_exit}\$|            exit 1|" > "${d}/lane.yml"
  expect 2 1 "${d}" || fail=1
  local out
  out="$(check_dir "${d}" 2>&1 >/dev/null)"
  if [[ "${out}" != *"E1 ${FIXTURE_STEP} (line 22)"* ]]; then
    echo "SELF-TEST FAIL (2): want E1 naming ${FIXTURE_STEP} at line 22" >&2
    fail=1
  fi

  # (3) E1 alone — a second `exit 1` anywhere else in the step.
  ran=$(( ran + 1 )); d="${tmp}/stray"; mkdir -p "${d}"
  compliant_wf | sed 's|^          mkdir -p /tmp/b8-logs$|          mkdir -p /tmp/b8-logs \|\| exit 1|' > "${d}/lane.yml"
  expect 3 1 "${d}" E1 1 || fail=1

  # (4)-(6) E2 alone — a constant, a variable that is not a captured `$?`, and
  #         no exit at all.
  local bent label=4
  for bent in '            exit 2' '            exit "${other_rc}"' '            true'; do
    ran=$(( ran + 1 )); d="${tmp}/bent${label}"; mkdir -p "${d}"
    compliant_wf | sed "s|^${unscannable_exit}\$|${bent}|" > "${d}/lane.yml"
    expect "${label}" 1 "${d}" E2 1 || fail=1
    label=$(( label + 1 ))
  done

  # (7) E3 alone — the leak branch loses its `exit 1`.
  ran=$(( ran + 1 )); d="${tmp}/silentleak"; mkdir -p "${d}"
  compliant_wf | sed '/^            exit 1$/d' > "${d}/lane.yml"
  expect 7 1 "${d}" E3 1 || fail=1

  # (8) A comment is not code, even one that spells the banned line.
  ran=$(( ran + 1 )); d="${tmp}/comment"; mkdir -p "${d}"
  compliant_wf | sed "s|^${unscannable_exit}\$|            # was: exit 1\n&|" > "${d}/lane.yml"
  expect 8 0 "${d}" || fail=1

  # (9) The token, not a prefix: `exit 10` is not the leak code.
  ran=$(( ran + 1 )); d="${tmp}/prefix"; mkdir -p "${d}"
  compliant_wf | sed 's|^          mkdir -p /tmp/b8-logs$|          mkdir -p /tmp/b8-logs \|\| exit 10|' > "${d}/lane.yml"
  expect 9 0 "${d}" || fail=1

  # (10) A step that writes no leak marker may say `exit 1` as it likes.
  ran=$(( ran + 1 )); d="${tmp}/unmarked"; mkdir -p "${d}"
  compliant_wf | sed '/DIAG_LEAK/d' > "${d}/lane.yml"
  expect 10 0 "${d}" || fail=1

  # (11) The marker's and the variable's NAMES are not the key: another lane's
  #      spelling regresses the same way.
  ran=$(( ran + 1 )); d="${tmp}/renamed"; mkdir -p "${d}"
  compliant_wf | sed "s|^${unscannable_exit}\$|            exit 1|; s/DIAG_LEAK/SIM_LEAK/; s/DIAG_UNSCANNABLE/SIM_UNSCANNABLE/; s/diag_scan_rc/rc/g" > "${d}/lane.yml"
  expect 11 1 "${d}" || fail=1

  # (12) Anti-vacuity: a step list this reader cannot parse (YAML's indentless
  #      sequence) must stop the guard, never pass as a tree with nothing to grade.
  ran=$(( ran + 1 )); d="${tmp}/unreadable"; mkdir -p "${d}"
  compliant_wf | sed '5,$ s/^  //' > "${d}/lane.yml"
  expect 12 2 "${d}" || fail=1

  VIOLATIONS=0
  if (( fail )); then
    echo "${SCRIPT_NAME}: SELF-TEST FAILED" >&2
    return 1
  fi
  if (( ran != SELF_TEST_FIXTURES )); then
    echo "${SCRIPT_NAME}: SELF-TEST FAILED — ran ${ran} fixture(s), expected exactly ${SELF_TEST_FIXTURES}; a fixture was added or removed without moving the pin" >&2
    return 1
  fi
  echo "${SCRIPT_NAME}: self-test passed (${ran}/${SELF_TEST_FIXTURES} fixtures: the real step passes; an unscannable branch that says \`exit 1\` fails E1 naming its file, job, step and line, under this marker name and another; a stray \`exit 1\` elsewhere in the step fails E1 alone; an unscannable branch exiting a constant, an uncaptured variable, or not at all fails E2 alone; a leak branch without its \`exit 1\` fails E3 alone; a comment spelling \`exit 1\`, an \`exit 10\`, and a step that writes no leak marker each pass; and a step list this reader cannot parse stops the guard rather than passing it)."
  return 0
}

# ---------------------------------------------------------------------------

if [[ "${1:-}" == "--self-test" && $# -eq 1 ]]; then
  run_self_test
  exit $?
fi
(( $# == 0 )) || misconfig "usage: ${SCRIPT_NAME}.sh [--self-test]"

WORKFLOW_DIR="${REPO_ROOT}/.github/workflows"
[[ -d "${WORKFLOW_DIR}" ]] || misconfig "${WORKFLOW_DIR} does not exist"

log "checking leak-reporting steps' exit codes in .github/workflows"
check_dir "${WORKFLOW_DIR}"
check_extractor_sees_the_dir "${WORKFLOW_DIR}"
(( GRADED_STEPS >= MIN_STEPS )) || misconfig "graded ${GRADED_STEPS} leak-reporting step(s), fewer than the ${MIN_STEPS} known to exist; this guard has gone blind rather than found a clean tree."
(( UNSCANNABLE_BRANCHES >= MIN_STEPS )) || misconfig "graded ${UNSCANNABLE_BRANCHES} unscannable branch(es), fewer than the ${MIN_STEPS} known to exist; E2 is checking nothing."

if (( VIOLATIONS > 0 )); then
  fail_msg "${VIOLATIONS} violation(s). In a step that writes a leak marker, \`exit 1\` belongs to the leak branch alone and the unscannable branch exits with the scanner's code."
  exit 1
fi
log "OK — ${GRADED_STEPS} leak-reporting step(s), ${UNSCANNABLE_BRANCHES} unscannable branch(es); 1 means a leak in every one."
