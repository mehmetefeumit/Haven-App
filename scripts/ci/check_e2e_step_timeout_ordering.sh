#!/usr/bin/env bash
# CI guard: every emulator/simulator lane stays bounded from the inside out.
#
# # The invariant
#
#     inner deadline  <  step `timeout-minutes`  <  job `timeout-minutes`
#
# Three nested bounds, and they must fire in that order. The reason is not
# tidiness — it is which bound produces a USABLE red:
#
#   * The INNER deadline is ours. On Linux it is a coreutils `timeout` (via
#     tooling/e2e/ci/run-with-deadline.sh), on macOS it is `nick-fields/retry`'s
#     `timeout_minutes` (the macos-* runners have no GNU `timeout`). When it
#     fires it names the lane, and the step's `if: failure()` diagnostics,
#     secret scan and artifact upload all still run. That is a red you can act
#     on.
#   * The STEP cap is GitHub's, and on a `reactivecircus/android-emulator-runner`
#     step it does NOT reliably reap the action's backgrounded emulator/adb/
#     drive subtree — a hang once ran the full ~45 min past a 30-min step cap
#     to the 60-min JOB cap, twice (runs 28056995601, 28065762568). It is a
#     belt, not the bound.
#   * The JOB cap SIGKILLs the runner. Every `if: failure()` step is skipped,
#     so a job-cap death lands as "cancelled after N minutes" with no logcat,
#     no drive log, no relay log. Slow AND evidence-free: the worst red there
#     is, and the one that teaches people to hit re-run instead of reading.
#
# So an unbounded drive step is not "a bit sloppy" — it routes every hang in
# that lane to the worst of the three outcomes. Conversely a step cap at or
# below its own inner budget is a false-red generator: it cuts a healthy (if
# slow) run before the thing that would have explained it.
#
# CI_HARDENING_BACKLOG.md A8. At the time it was written, 4 of the then-6
# Android emulator lanes ran their drive with no inner deadline at all.
#
# # Checks
#
#   C1  Every emulator/simulator DRIVE step declares an inner deadline —
#       `run-with-deadline.sh <dur>`, a raw `timeout ... <dur>`, or
#       `nick-fields/retry`'s `timeout_minutes` x `max_attempts`.
#
#   C2  inner budget < step `timeout-minutes`, where the budget is what the
#       step can ACTUALLY consume:
#           deadline + SIGKILL grace + emulator-boot-timeout
#       The boot term matters: the action boots the AVD BEFORE running
#       `script:`, so a step whose cap only covers the script is a cap that
#       fires during a slow boot on a healthy run. e2e-android.yml's own step
#       comment does this same arithmetic by hand ("45m (script) + 7m (boot) +
#       1m ~= 53m. The belt is therefore 55"); this check is that reasoning,
#       enforced.
#
#   C3  Every step carrying a `timeout-minutes` has it STRICTLY below its job's.
#       Equality is the silent case worth naming: e2e-integration.yml's APK
#       build step sat at 45 inside a 45-minute job, so its cap could never fire
#       first and a hung Gradle build died at the job cap with no diagnostics —
#       an inoperative bound that reads, in review, exactly like a working one.
#
#   C4  A per-drive `*_DRIVE_TIMEOUT` declared in a drive step must be below
#       that step's deadline. Otherwise the harness's own attributable message
#       ("flutter drive for X exceeded 20m") is unreachable: the outer deadline
#       SIGTERMs first and the lane reports an anonymous 124. e2e-android.yml's
#       poll path had exactly this shape — a 20m HAVEN_DRIVE_TIMEOUT under a
#       16m wrapper.
#
#   C5  Every emulator/simulator step carries a `timeout-minutes`, and every
#       `reactivecircus` step carries an `emulator-boot-timeout`. The AVD
#       snapshot steps had neither: a step whose entire job is booting an
#       emulator, with no bound on the boot.
#
# # Scope and boundaries
#
# The subject is what the WORKFLOW declares. Per-drive timeouts that live in
# the harness scripts' own defaults (run-integration-tests.sh's 10m,
# run-b1-fgs-publish.sh's 18m, run-single-avd-scenario.sh's 20m) are the
# harness's business and are documented there; C4 covers a value only where a
# workflow states it, which is where the two can disagree. That boundary is
# deliberate: parsing the scripts' defaults from here would couple this guard
# to their internals and rot on the first refactor.
#
# GitHub expressions of the form `${{ <cond> && A || B }}` are evaluated as
# BOTH branches, paired positionally across the deadline/step/job values (every
# such expression in this repo keys on the same `inputs.live_sync`), so the
# poll and live-sync variants of a lane are each checked in full.
#
# Pure bash/awk over the checked-out tree, no toolchain — belongs in
# repo-guards.yml.
#
# Usage:
#   check_e2e_step_timeout_ordering.sh              # check the repo
#   check_e2e_step_timeout_ordering.sh --self-test
#
# Exit codes:
#   0  the invariant holds in every lane
#   1  a lane violates it
#   2  expected paths missing / self-test failed (the guard itself is broken)

set -euo pipefail

SCRIPT_NAME="check_e2e_step_timeout_ordering"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

log() { printf '\033[1;34m[%s]\033[0m %s\n' "${SCRIPT_NAME}" "$*"; }
fail_msg() { printf '\033[1;31m[%s] FAIL:\033[0m %s\n' "${SCRIPT_NAME}" "$*" >&2; }
misconfig() { printf '\033[1;31m[%s] ERROR:\033[0m %s\n' "${SCRIPT_NAME}" "$*" >&2; exit 2; }

# The SIGTERM->SIGKILL grace run-with-deadline.sh allows. Part of the C2 budget
# because a drive that ignores SIGTERM really does consume it.
readonly KILL_GRACE_MIN=1
# The `reactivecircus/android-emulator-runner` default when a step does not set
# `emulator-boot-timeout`. C5 requires the step to set one, so this is only the
# fallback used while reporting a C5 violation.
readonly DEFAULT_BOOT_TIMEOUT_MIN=10

VIOLATIONS=0
note_violation() { fail_msg "$*"; VIOLATIONS=$((VIOLATIONS + 1)); }

# ---------------------------------------------------------------------------
# Extraction
#
# A purpose-built, indentation-driven reader rather than a YAML library: the
# values under scrutiny are GitHub EXPRESSIONS (`${{ inputs.live_sync && 55 ||
# 30 }}`), which any parser hands back as opaque strings anyway, so the parse
# would buy nothing and cost a runtime dependency in a job that has none.
#
# Emits one TSV record per step:
#   file  job  jobcap  runs_on  stepname  stepcap  uses  retry_to  retry_ma
#   boot_timeout  body
#
# Full-line comments are stripped from the body. Without that, a step comment
# mentioning `HAVEN_DRIVE_TIMEOUT=28m` (e2e-flakiness-stress.yml has one) would
# be read as a declaration.
# ---------------------------------------------------------------------------

extract_steps() {
  local file="$1"
  awk -v file="${file}" '
    function flush_step(   ) {
      if (in_step) {
        printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n",
          file, job, jobcap, runs_on, stepname, stepcap, uses,
          retry_to, retry_ma, boot_to, body
      }
      in_step = 0
      stepname = "-"; stepcap = "-"; uses = "-"
      retry_to = "-"; retry_ma = "-"; boot_to = "-"; body = ""
    }
    BEGIN {
      job = "-"; jobcap = "-"; runs_on = "-"
      stepname = "-"; stepcap = "-"; uses = "-"
      retry_to = "-"; retry_ma = "-"; boot_to = "-"; body = ""
      in_jobs = 0; in_steps = 0; in_step = 0
    }
    # Top-level key: leaving (or entering) the jobs: block.
    /^[A-Za-z_][A-Za-z0-9_-]*:/ {
      flush_step(); in_steps = 0
      in_jobs = ($0 ~ /^jobs:/)
      next
    }
    !in_jobs { next }
    # Job header (2-space indent).
    /^  [A-Za-z_][A-Za-z0-9_.-]*:[[:space:]]*$/ {
      flush_step(); in_steps = 0
      job = $0; sub(/^  /, "", job); sub(/:[[:space:]]*$/, "", job)
      jobcap = "-"; runs_on = "-"
      next
    }
    # Job-level keys (4-space indent).
    !in_steps && /^    timeout-minutes:[[:space:]]*/ {
      jobcap = $0; sub(/^    timeout-minutes:[[:space:]]*/, "", jobcap); next
    }
    !in_steps && /^    runs-on:[[:space:]]*/ {
      runs_on = $0; sub(/^    runs-on:[[:space:]]*/, "", runs_on); next
    }
    /^    steps:[[:space:]]*$/ { flush_step(); in_steps = 1; next }
    !in_steps { next }
    # A new step starts at "      - " (6-space indent, list item).
    /^      - / {
      flush_step()
      in_step = 1
      if ($0 ~ /^      - name:[[:space:]]*/) {
        stepname = $0; sub(/^      - name:[[:space:]]*/, "", stepname)
      } else {
        stepname = "(unnamed)"
      }
      body = $0
      next
    }
    !in_step { next }
    # Full-line comments never reach the body (see header).
    /^[[:space:]]*#/ { next }
    /^        timeout-minutes:[[:space:]]*/ {
      stepcap = $0; sub(/^        timeout-minutes:[[:space:]]*/, "", stepcap)
    }
    /^        uses:[[:space:]]*/ {
      uses = $0; sub(/^        uses:[[:space:]]*/, "", uses)
    }
    /^          timeout_minutes:[[:space:]]*/ {
      retry_to = $0; sub(/^          timeout_minutes:[[:space:]]*/, "", retry_to)
    }
    /^          max_attempts:[[:space:]]*/ {
      retry_ma = $0; sub(/^          max_attempts:[[:space:]]*/, "", retry_ma)
    }
    /^          emulator-boot-timeout:[[:space:]]*/ {
      boot_to = $0; sub(/^          emulator-boot-timeout:[[:space:]]*/, "", boot_to)
    }
    { gsub(/\t/, " "); body = body " " $0 }
    END { flush_step() }
  ' "${file}"
}

# ---------------------------------------------------------------------------
# Value helpers
# ---------------------------------------------------------------------------

# branches <raw> -> "<true-branch> <false-branch>", or "" if unparseable.
# A scalar broadcasts to both branches so callers never special-case it.
branches() {
  local raw="$1"
  raw="${raw%\"}"; raw="${raw#\"}"
  if [[ "${raw}" =~ \$\{\{[^}]*\&\&[[:space:]]*\'?([0-9]+[smhd]?)\'?[[:space:]]*\|\|[[:space:]]*\'?([0-9]+[smhd]?)\'?[[:space:]]*\}\} ]]; then
    printf '%s %s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
    return 0
  fi
  if [[ "${raw}" =~ ^[[:space:]]*\'?([0-9]+[smhd]?)\'?[[:space:]]*$ ]]; then
    printf '%s %s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[1]}"
    return 0
  fi
  printf '\n'
}

# dur_to_min <token> -> whole minutes, rounded UP.
# Rounding up is the safe direction for a budget: it can only make the guard
# stricter, never let an over-long inner bound slip under a step cap.
dur_to_min() {
  local t="$1" n unit
  if [[ "${t}" =~ ^([0-9]+)([smhd]?)$ ]]; then
    n="${BASH_REMATCH[1]}"; unit="${BASH_REMATCH[2]}"
  else
    echo ""; return
  fi
  case "${unit}" in
    s) echo $(( (n + 59) / 60 )) ;;
    ""|m) echo "${n}" ;;
    h) echo $(( n * 60 )) ;;
    d) echo $(( n * 1440 )) ;;
  esac
}

# A bare `timeout-minutes:` value is minutes by definition, so it must NOT
# carry a unit suffix; a unit there would mean something different to GitHub
# than to a reader.
cap_to_min() {
  local t="$1"
  [[ "${t}" =~ ^[0-9]+$ ]] && { echo "${t}"; return; }
  echo ""
}

# ---------------------------------------------------------------------------
# Classification
# ---------------------------------------------------------------------------

is_emulator_step() { [[ "$1" == *"reactivecircus/android-emulator-runner"* ]]; }
# An iOS step counts as a simulator step when it drives the simulator harness
# or boots the sim; the shared runner name is the reliable marker (the iOS
# lanes have no equivalent of the emulator action).
#
# `--self-test` is excluded because repo-guards.yml invokes the SAME harness
# scripts hermetically — no simulator, no device, seconds long. Demanding an
# emulator budget from a step that never boots one would be noise, and noise in
# a guard is how guards get disabled.
is_simulator_body() {
  [[ "$1" == *"--self-test"* ]] && return 1
  [[ "$1" == *"run-ios-sim-scenario.sh"* || "$1" == *"boot-ios-sim.sh"* ]]
}
# A DRIVE step actually runs a lane's harness. An AVD-snapshot step uses the
# same action but only echoes, so it needs a cap (C5) and no deadline (C1).
is_drive_body() { [[ "$1" == *"tooling/e2e/ci/run-"* ]]; }

# deadline_token <body> -> the raw inner-deadline token, or "".
# Both spellings are accepted: the helper (which adds the attributable banner)
# and a raw coreutils `timeout`, so the guard states the invariant rather than
# mandating one call style.
deadline_token() {
  local body="$1"
  if [[ "${body}" =~ run-with-deadline\.sh[[:space:]]+(\$\{\{[^}]*\}\}|[0-9]+[smhd]) ]]; then
    printf '%s\n' "${BASH_REMATCH[1]}"; return 0
  fi
  if [[ "${body}" =~ [[:space:]]timeout[[:space:]]+(--[^[:space:]]+[[:space:]]+)*(\$\{\{[^}]*\}\}|[0-9]+[smhd])[[:space:]] ]]; then
    printf '%s\n' "${BASH_REMATCH[2]}"; return 0
  fi
  printf '\n'
}

# drive_timeout_token <body> -> a per-drive `*_DRIVE_TIMEOUT` the WORKFLOW sets.
drive_timeout_token() {
  local body="$1"
  if [[ "${body}" =~ [A-Z0-9_]*DRIVE_TIMEOUT[=:][[:space:]]*\'?(\$\{\{[^}]*\}\}|[0-9]+[smhd])\'? ]]; then
    printf '%s\n' "${BASH_REMATCH[1]}"; return 0
  fi
  printf '\n'
}

# ---------------------------------------------------------------------------
# The check
# ---------------------------------------------------------------------------

# check_dir <dir> — walks every workflow under <dir>, reporting violations on
# stderr and setting the globals EMU_STEPS / DRIVE_STEPS.
#
# Counts come back through globals rather than stdout on purpose: a caller that
# captured them with `$(...)` would run this in a SUBSHELL, and every
# `note_violation` increment would be discarded with it — the guard would report
# each violation and then exit 0. Nothing here writes to stdout.
EMU_STEPS=0
DRIVE_STEPS=0
check_dir() {
  local dir="$1"
  local files=()
  while IFS= read -r f; do files+=("${f}"); done < <(find "${dir}" -maxdepth 1 -name '*.yml' | sort)
  (( ${#files[@]} > 0 )) || misconfig "no workflow files under ${dir}"

  EMU_STEPS=0
  DRIVE_STEPS=0
  local file job jobcap runs_on stepname stepcap uses retry_to retry_ma boot_to body

  local rec
  for f in "${files[@]}"; do
    while IFS=$'\t' read -r file job jobcap runs_on stepname stepcap uses retry_to retry_ma boot_to body; do
      local is_emu=0 is_sim=0
      if is_emulator_step "${uses}"; then is_emu=1; fi
      if is_simulator_body "${body}"; then is_sim=1; fi
      (( is_emu || is_sim )) || {
        # Not an emulator/sim step — C3 still applies to any step that carries
        # a cap, because an inoperative cap is inoperative everywhere.
        [[ "${stepcap}" == "-" ]] && continue
        check_c3 "${file}" "${job}" "${stepname}" "${stepcap}" "${jobcap}"
        continue
      }

      EMU_STEPS=$((EMU_STEPS + 1))
      local label="${file##*/} :: ${job} :: ${stepname}"

      # --- C5: a bound must exist at all.
      if [[ "${stepcap}" == "-" ]]; then
        note_violation "C5 ${label}: emulator/simulator step has no \`timeout-minutes\`. A hang here has no step bound and dies at the job cap, skipping every if: failure() diagnostic."
        continue
      fi
      if (( is_emu )) && [[ "${boot_to}" == "-" ]]; then
        note_violation "C5 ${label}: reactivecircus step has no \`emulator-boot-timeout\`. The boot is unbounded, and the boot is the most common emulator hang."
      fi

      check_c3 "${file}" "${job}" "${stepname}" "${stepcap}" "${jobcap}"

      # --- C1/C2/C4 apply to DRIVE steps (the ones that run a harness).
      if ! is_drive_body "${body}"; then continue; fi
      DRIVE_STEPS=$((DRIVE_STEPS + 1))

      local dl_raw dl_branches
      dl_raw="$(deadline_token "${body}")"
      if [[ -z "${dl_raw}" && "${uses}" == *"nick-fields/retry"* ]]; then
        # macOS lanes: the retry action enforces the per-attempt bound itself,
        # and the step can spend it once per attempt.
        local to_b ma_b
        to_b="$(branches "${retry_to}")"; ma_b="$(branches "${retry_ma}")"
        [[ -n "${to_b}" && -n "${ma_b}" ]] || {
          note_violation "C1 ${label}: nick-fields/retry step without a parseable timeout_minutes x max_attempts."
          continue
        }
        # shellcheck disable=SC2206
        local TO=(${to_b}) MA=(${ma_b})
        dl_branches="$(( $(dur_to_min "${TO[0]}") * MA[0] ))m $(( $(dur_to_min "${TO[1]}") * MA[1] ))m"
      elif [[ -z "${dl_raw}" ]]; then
        note_violation "C1 ${label}: drive step has NO inner deadline. Wrap the script in tooling/e2e/ci/run-with-deadline.sh so a hang fails fast and names this lane, instead of burning to the job cap with no artifacts."
        continue
      else
        dl_branches="$(branches "${dl_raw}")"
        [[ -n "${dl_branches}" ]] || {
          note_violation "C1 ${label}: inner deadline '${dl_raw}' is not a parseable duration."
          continue
        }
      fi

      # shellcheck disable=SC2206
      local DL=(${dl_branches})
      local SC BC
      # shellcheck disable=SC2206
      SC=($(branches "${stepcap}"))
      local boot_min="${DEFAULT_BOOT_TIMEOUT_MIN}"
      if [[ "${boot_to}" != "-" ]]; then
        # `emulator-boot-timeout` is SECONDS.
        boot_min="$(dur_to_min "${boot_to}s")"
      fi
      # The iOS sim boot is its own, separately capped step, so it is not part
      # of a macOS drive step's budget.
      if (( ! is_emu )); then boot_min=0; fi

      local i
      for i in 0 1; do
        local dl_min cap_min budget
        dl_min="$(dur_to_min "${DL[$i]}")"
        cap_min="$(cap_to_min "${SC[$i]:-}")"
        [[ -n "${dl_min}" ]] || { note_violation "C2 ${label}: unparseable deadline '${DL[$i]}'."; continue; }
        [[ -n "${cap_min}" ]] || { note_violation "C2 ${label}: unparseable step timeout-minutes '${SC[$i]:-}' (must be a bare number of minutes)."; continue; }
        budget=$(( dl_min + KILL_GRACE_MIN + boot_min ))
        if (( budget >= cap_min )); then
          note_violation "C2 ${label}: inner budget ${budget}m (deadline ${dl_min}m + ${KILL_GRACE_MIN}m kill grace + ${boot_min}m boot) is NOT below the step cap ${cap_min}m. The step reaper can fire before our own bound, which is the anonymous-red case."
        fi
        # A scalar (non-expression) lane has identical branches; checking it
        # twice would double-report. `if/then/break` rather than `&& break`:
        # a trailing `[[ ]] &&` that evaluates FALSE leaves the enclosing
        # function's status at 1, which `set -e` turns into a silent early
        # exit at the call site — the guard would stop mid-sweep and report
        # nothing at all.
        if [[ "${DL[0]}" == "${DL[1]}" && "${SC[0]}" == "${SC[1]:-}" ]]; then break; fi
      done

      # --- C4: the harness's own per-drive bound must stay reachable.
      local dt_raw
      dt_raw="$(drive_timeout_token "${body}")"
      if [[ -n "${dt_raw}" ]]; then
        local dt_branches
        dt_branches="$(branches "${dt_raw}")"
        if [[ -z "${dt_branches}" ]]; then
          note_violation "C4 ${label}: unparseable *_DRIVE_TIMEOUT '${dt_raw}'."
        else
          # shellcheck disable=SC2206
          local DT=(${dt_branches})
          for i in 0 1; do
            local dt_min dl_min
            dt_min="$(dur_to_min "${DT[$i]}")"
            dl_min="$(dur_to_min "${DL[$i]}")"
            if [[ -n "${dt_min}" && -n "${dl_min}" ]] && (( dt_min >= dl_min )); then
              note_violation "C4 ${label}: per-drive timeout ${dt_min}m is NOT below the step's inner deadline ${dl_min}m, so the harness's own \"flutter drive exceeded\" message can never print — the outer deadline SIGTERMs first and the lane reports an anonymous 124."
            fi
            if [[ "${DT[0]}" == "${DT[1]}" ]]; then break; fi
          done
        fi
      fi
    done < <(extract_steps "${f}")
  done
}

check_c3() {
  local file="$1" job="$2" stepname="$3" stepcap="$4" jobcap="$5"
  local label="${file##*/} :: ${job} :: ${stepname}"
  local sc_b jc_b
  sc_b="$(branches "${stepcap}")"; jc_b="$(branches "${jobcap}")"
  if [[ -z "${sc_b}" ]]; then
    note_violation "C3 ${label}: step timeout-minutes '${stepcap}' is not a parseable number."
    return
  fi
  if [[ -z "${jc_b}" ]]; then
    note_violation "C3 ${label}: job '${job}' has no parseable timeout-minutes ('${jobcap}'). Without a job cap a runaway job runs to GitHub's 6-hour default."
    return
  fi
  # shellcheck disable=SC2206
  local SC=(${sc_b}) JC=(${jc_b})
  local i
  for i in 0 1; do
    local s j
    s="$(cap_to_min "${SC[$i]}")"; j="$(cap_to_min "${JC[$i]}")"
    if [[ -n "${s}" && -n "${j}" ]] && (( s >= j )); then
      note_violation "C3 ${label}: step cap ${s}m is NOT below the job cap ${j}m, so it can never fire first — an inoperative bound that reads like a working one."
    fi
    if [[ "${SC[0]}" == "${SC[1]}" && "${JC[0]}" == "${JC[1]}" ]]; then break; fi
  done
  # Explicit success: this function is invoked as a bare command inside
  # check_dir, so any non-zero status leaking out of the loop above would end
  # the whole sweep under `set -e`.
  return 0
}

# ---------------------------------------------------------------------------
# Self-test (hermetic: synthetic workflows in a temp dir, no repo access)
#
# Each fixture is a lane shape that has actually occurred in this repo, so a
# mutation that disables a check fails a case that describes a real outage.
# ---------------------------------------------------------------------------

write_fixture() {
  local path="$1"; shift
  printf '%s\n' "$@" > "${path}"
}

self_test() {
  local tmp failures=0
  tmp="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf '${tmp}'" RETURN

  _expect() {
    local desc="$1" dir="$2" want_rc="$3" want_grep="${4:-}"
    local out rc=0
    VIOLATIONS=0
    # Run in THIS shell (stderr captured to a file) rather than under `$(...)`:
    # a subshell would discard every VIOLATIONS increment, which is exactly the
    # bug this guard would otherwise ship — reporting each violation and then
    # exiting 0. The verdict is taken from BOTH the counter and the reported
    # text, so a check that counts silently, or prints without counting, fails.
    check_dir "${dir}" 2>"${tmp}/err.txt" || rc=$?
    out="$(cat "${tmp}/err.txt")"
    (( VIOLATIONS > 0 )) && rc=1
    if grep -q '\] FAIL:' <<<"${out}" && (( VIOLATIONS == 0 )); then
      echo "FAIL: ${desc}: a violation was printed but not counted" >&2
      failures=$((failures + 1)); return
    fi
    if (( rc != want_rc )); then
      echo "FAIL: ${desc}: expected rc ${want_rc}, got ${rc}" >&2
      echo "${out}" | sed 's/^/    /' >&2
      failures=$((failures + 1)); return
    fi
    if [[ -n "${want_grep}" ]] && ! grep -q -- "${want_grep}" <<<"${out}"; then
      echo "FAIL: ${desc}: output did not mention '${want_grep}'" >&2
      echo "${out}" | sed 's/^/    /' >&2
      failures=$((failures + 1)); return
    fi
    echo "  ok: ${desc}"
  }

  echo "[${SCRIPT_NAME}] self-test"

  # --- Fixture A: a correct Android lane. Nothing may fire.
  local a="${tmp}/a"; mkdir -p "${a}"
  write_fixture "${a}/ok.yml" \
'name: ok' \
'on: [push]' \
'jobs:' \
'  lane:' \
'    runs-on: ubuntu-latest' \
'    timeout-minutes: 60' \
'    steps:' \
'      - name: Drive' \
'        timeout-minutes: 35' \
'        uses: reactivecircus/android-emulator-runner@v2' \
'        with:' \
'          emulator-boot-timeout: 420' \
'          script: bash tooling/e2e/ci/run-with-deadline.sh 25m lane -- bash tooling/e2e/ci/run-integration-tests.sh x'
  _expect "correct lane passes" "${a}" 0

  # --- Fixture B: C1 — the A8 defect itself, a drive with no inner deadline.
  local b="${tmp}/b"; mkdir -p "${b}"
  write_fixture "${b}/c1.yml" \
'jobs:' \
'  lane:' \
'    runs-on: ubuntu-latest' \
'    timeout-minutes: 45' \
'    steps:' \
'      - name: Drive' \
'        timeout-minutes: 35' \
'        uses: reactivecircus/android-emulator-runner@v2' \
'        with:' \
'          emulator-boot-timeout: 420' \
'          script: bash tooling/e2e/ci/run-integration-tests.sh x'
  _expect "C1 catches a drive with no inner deadline" "${b}" 1 "C1"

  # --- Fixture C: C2 — deadline+grace+boot at or above the step cap.
  local c="${tmp}/c"; mkdir -p "${c}"
  write_fixture "${c}/c2.yml" \
'jobs:' \
'  lane:' \
'    runs-on: ubuntu-latest' \
'    timeout-minutes: 60' \
'    steps:' \
'      - name: Drive' \
'        timeout-minutes: 30' \
'        uses: reactivecircus/android-emulator-runner@v2' \
'        with:' \
'          emulator-boot-timeout: 420' \
'          script: bash tooling/e2e/ci/run-with-deadline.sh 26m lane -- bash tooling/e2e/ci/run-x.sh'
  _expect "C2 catches an inner budget at/over the step cap" "${c}" 1 "C2"

  # --- Fixture D: C3 — step cap EQUAL to the job cap (the integration-build bug).
  local d="${tmp}/d"; mkdir -p "${d}"
  write_fixture "${d}/c3.yml" \
'jobs:' \
'  lane:' \
'    runs-on: ubuntu-latest' \
'    timeout-minutes: 45' \
'    steps:' \
'      - name: Build' \
'        timeout-minutes: 45' \
'        run: bash build.sh'
  _expect "C3 catches step cap == job cap" "${d}" 1 "C3"

  # --- Fixture E: C4 — per-drive timeout at/above the wrapper (e2e-android poll).
  local e="${tmp}/e"; mkdir -p "${e}"
  write_fixture "${e}/c4.yml" \
'jobs:' \
'  lane:' \
'    runs-on: ubuntu-latest' \
'    timeout-minutes: 60' \
'    steps:' \
'      - name: Drive' \
'        timeout-minutes: 35' \
'        uses: reactivecircus/android-emulator-runner@v2' \
'        with:' \
'          emulator-boot-timeout: 420' \
"          script: bash tooling/e2e/ci/run-with-deadline.sh 16m lane -- bash -c 'HAVEN_DRIVE_TIMEOUT=20m bash tooling/e2e/ci/run-single-avd-scenario.sh x'"
  _expect "C4 catches a per-drive timeout above the wrapper" "${e}" 1 "C4"

  # --- Fixture F: C5 — an emulator step with no cap at all (AVD snapshot).
  local ff="${tmp}/f"; mkdir -p "${ff}"
  write_fixture "${ff}/c5.yml" \
'jobs:' \
'  lane:' \
'    runs-on: ubuntu-latest' \
'    timeout-minutes: 60' \
'    steps:' \
'      - name: Create AVD snapshot' \
'        uses: reactivecircus/android-emulator-runner@v2' \
'        with:' \
'          script: echo "Generated AVD snapshot for caching."'
  _expect "C5 catches an emulator step with no timeout-minutes" "${ff}" 1 "C5"

  # --- Fixture G: C5 — reactivecircus step with no emulator-boot-timeout.
  local g="${tmp}/g"; mkdir -p "${g}"
  write_fixture "${g}/c5b.yml" \
'jobs:' \
'  lane:' \
'    runs-on: ubuntu-latest' \
'    timeout-minutes: 60' \
'    steps:' \
'      - name: Drive' \
'        timeout-minutes: 35' \
'        uses: reactivecircus/android-emulator-runner@v2' \
'        with:' \
'          script: bash tooling/e2e/ci/run-with-deadline.sh 25m lane -- bash tooling/e2e/ci/run-x.sh'
  _expect "C5 catches a missing emulator-boot-timeout" "${g}" 1 "emulator-boot-timeout"

  # --- Fixture H: both branches of a live_sync expression are checked. The
  #     TRUE branch is fine (45+1+7=53 < 55) and the FALSE branch is not
  #     (26+1+7=34 >= 30) — a lane whose poll variant was the broken one.
  local h="${tmp}/h"; mkdir -p "${h}"
  write_fixture "${h}/expr.yml" \
'jobs:' \
'  lane:' \
'    runs-on: ubuntu-latest' \
'    timeout-minutes: ${{ inputs.live_sync && 90 || 60 }}' \
'    steps:' \
'      - name: Drive' \
'        timeout-minutes: ${{ inputs.live_sync && 55 || 30 }}' \
'        uses: reactivecircus/android-emulator-runner@v2' \
'        with:' \
'          emulator-boot-timeout: 420' \
"          script: bash tooling/e2e/ci/run-with-deadline.sh \${{ inputs.live_sync && '45m' || '26m' }} lane -- bash tooling/e2e/ci/run-x.sh"
  _expect "both branches of a live_sync expression are checked" "${h}" 1 "C2"

  # --- Fixture I: an AVD-snapshot step (no harness call) needs a cap but NOT a
  #     deadline — C1 must not fire on it, or every lane would need a wrapper
  #     around an `echo`.
  local i="${tmp}/i"; mkdir -p "${i}"
  write_fixture "${i}/snap.yml" \
'jobs:' \
'  lane:' \
'    runs-on: ubuntu-latest' \
'    timeout-minutes: 60' \
'    steps:' \
'      - name: Create AVD snapshot' \
'        timeout-minutes: 15' \
'        uses: reactivecircus/android-emulator-runner@v2' \
'        with:' \
'          emulator-boot-timeout: 420' \
'          script: echo "Generated AVD snapshot for caching."'
  _expect "a snapshot step needs a cap, not a deadline" "${i}" 0

  # --- Fixture J: macOS lane bounded by nick-fields/retry, not coreutils.
  #     60 (30x2) < 65 < 90 holds, so it must pass; the guard must not demand
  #     a GNU `timeout` that macos-* runners do not have.
  local j="${tmp}/j"; mkdir -p "${j}"
  write_fixture "${j}/ios.yml" \
'jobs:' \
'  lane:' \
'    runs-on: macos-latest' \
'    timeout-minutes: 90' \
'    steps:' \
'      - name: Drive' \
'        timeout-minutes: 65' \
'        uses: nick-fields/retry@v3' \
'        with:' \
'          timeout_minutes: 30' \
'          max_attempts: 2' \
'          command: bash tooling/e2e/ci/run-ios-sim-scenario.sh x' \
'      - name: Bad drive' \
'        timeout-minutes: 45' \
'        uses: nick-fields/retry@v3' \
'        with:' \
'          timeout_minutes: 30' \
'          max_attempts: 2' \
'          command: bash tooling/e2e/ci/run-ios-sim-scenario.sh y'
  _expect "retry-bounded macOS lane: good passes, over-budget one fails" "${j}" 1 "Bad drive"

  # --- Fixture K: a step comment naming a timeout must NOT be read as a
  #     declaration. e2e-flakiness-stress.yml carries exactly such a comment.
  local k="${tmp}/k"; mkdir -p "${k}"
  write_fixture "${k}/comment.yml" \
'jobs:' \
'  lane:' \
'    runs-on: ubuntu-latest' \
'    timeout-minutes: 60' \
'    steps:' \
'      - name: Drive' \
'        timeout-minutes: 35' \
'        uses: reactivecircus/android-emulator-runner@v2' \
'        with:' \
'          emulator-boot-timeout: 420' \
'          # e2e-android.yml needs HAVEN_DRIVE_TIMEOUT=99m for its flag-on lane.' \
'          script: bash tooling/e2e/ci/run-with-deadline.sh 25m lane -- bash tooling/e2e/ci/run-x.sh'
  _expect "a comment mentioning a timeout is not a declaration" "${k}" 0

  # --- Fixture L: repo-guards.yml runs the SAME simulator harness scripts
  #     hermetically (`--self-test`, no device, seconds long). Those steps must
  #     NOT be treated as simulator lanes — a guard that demands an emulator
  #     budget from an `echo`-speed self-test is a guard people turn off.
  local l="${tmp}/l"; mkdir -p "${l}"
  write_fixture "${l}/guards.yml" \
'jobs:' \
'  guards:' \
'    runs-on: ubuntu-latest' \
'    timeout-minutes: 20' \
'    steps:' \
'      - name: E2E harness self-test (iOS first-test watchdog)' \
'        run: bash tooling/e2e/ci/run-ios-sim-scenario.sh --self-test'
  _expect "a hermetic --self-test step is not a simulator lane" "${l}" 0

  VIOLATIONS=0
  if (( failures > 0 )); then
    echo "[${SCRIPT_NAME}] self-test FAILED (${failures} case(s))" >&2
    return 1
  fi
  echo "[${SCRIPT_NAME}] self-test passed (12 cases)"
  return 0
}

# ---------------------------------------------------------------------------
# Entry
# ---------------------------------------------------------------------------

if [[ "${1:-}" == "--self-test" ]]; then
  self_test
  exit $?
fi

WF_DIR="${REPO_ROOT}/.github/workflows"
[[ -d "${WF_DIR}" ]] || misconfig "missing ${WF_DIR}"
[[ -f "${REPO_ROOT}/tooling/e2e/ci/run-with-deadline.sh" ]] \
  || misconfig "missing tooling/e2e/ci/run-with-deadline.sh (the inner-deadline helper this guard assumes)"

log "checking emulator/simulator timeout ordering in ${WF_DIR#"${REPO_ROOT}"/}"
check_dir "${WF_DIR}"
emu_steps="${EMU_STEPS}"
drive_steps="${DRIVE_STEPS}"

# A zero count means the extractor stopped recognising steps — the guard would
# then pass vacuously forever, which is the failure mode every grep-guard dies
# of. Assert it found the lanes it is supposed to be guarding.
if (( emu_steps < 10 || drive_steps < 8 )); then
  misconfig "only found ${emu_steps} emulator/simulator step(s), ${drive_steps} drive step(s) — the extractor is not seeing the lanes it guards (expected at least 10 / 8)."
fi

if (( VIOLATIONS > 0 )); then
  fail_msg "${VIOLATIONS} ordering violation(s). The rule is: inner deadline < step timeout-minutes < job timeout-minutes."
  exit 1
fi

log "OK — ${emu_steps} emulator/simulator steps (${drive_steps} drives), inner < step < job holds in all of them"
exit 0
