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
#       fires during a slow boot on a healthy run. The drive steps' own
#       comments do this arithmetic by hand, with one more term on top: the
#       action's own setup and teardown, which sits outside both the boot and
#       the deadline. That term is measured, not bounded, so it is not
#       enforced here; the deadline, grace and boot terms are.
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
#   C6  Every job with an emulator/simulator step has a job cap of at least
#       the sum of every step cap it can run, plus the most its uncapped work
#       (setup, post steps, any step with no cap) has ever taken. C3 compares
#       one step to the job and cannot see that sum: below it, a run whose
#       every step is still inside its own cap dies at the job cap, anonymous
#       and without diagnostics, which is a false red. Every capped step
#       counts, whatever its `if:`, since the rule is about what a job CAN run.
#
#       The uncapped term is measured, not bounded, so each job declares it on
#       the line directly above its job-level `timeout-minutes`:
#
#           # job-uncapped-minutes: 3.6 (52 runs, worst 34488512808)
#
#       Minutes below 1000 as digits with at most two decimals after a `.`,
#       never below the measurement and never zero; then how many runs of the
#       job were measured and which one was worst (free text may follow
#       `runs`). The figure is read from that line and nowhere else, and it
#       sits beside the cap it justifies, so one diff shows both. A declaration
#       anywhere else is not read: the job fails as undeclared, because a
#       missing allowance is not zero, and a second one fails it too, because
#       the one not read is stale. The comparison is exact, in hundredths of a
#       minute.
#
#       What C6 cannot see: whether the figure is TRUE. It cannot re-measure
#       run history, so a figure that understates the real worst case passes.
#       That is why the provenance is mandatory: a reviewer opens the named
#       run and subtracts its capped steps' time from the job's. One figure
#       covers every branch and matrix leg of a job, so it must be the worst
#       of them. And steps that can never run together are still all summed,
#       which can only make the check stricter.
#
# # Scope and boundaries
#
# The subject is what the WORKFLOW declares. Per-drive timeouts that live in
# the harness scripts' own defaults are not read here; C4 covers a value only
# where a workflow states it, which is where the two can disagree. The other
# half — that the deadline is at least the harness's own worst case, every
# script-side wait included — is check_e2e_lane_budget.sh's, which finds the
# drive steps through this file's extraction rather than a parser of its own.
#
# GitHub expressions of the form `${{ <cond> && A || B }}` are evaluated as
# BOTH branches, paired positionally across the deadline/step/job values, so the
# poll and live-sync variants of a lane are each checked in full. That pairing
# holds only while a job's expressions all key on one condition
# (`inputs.live_sync`, or `matrix.live_sync` in e2e-ios-background-publish.yml),
# so C6 refuses a lane whose expressions key on two.
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
#   2  expected paths missing, a step list the extractor cannot read, or the
#      self-test failed (the guard itself cannot vouch for the lanes)

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
#   boot_timeout  cmd  body
#
# `cmd` is the action's `script:` or `command:` value alone, a folded block
# joined with spaces; a literal (`|`) block is kept with a leading `|`, because
# the emulator action runs each of its lines as a separate shell.
#
# Full-line comments are stripped from the body. Without that, a step comment
# mentioning `HAVEN_DRIVE_TIMEOUT=28m` (e2e-flakiness-stress.yml has one) would
# be read as a declaration. A trailing comment is no part of a scalar value
# either: `timeout-minutes: 90  # sized below` is 90, not unreadable.
#
# A step's first key shares its `- ` line and is read like any other, so a cap
# written first still counts. Records are held until the job ends, because a
# job-level key may follow its steps.
# ---------------------------------------------------------------------------

extract_steps() {
  local file="$1"
  awk -v file="${file}" '
    function flush_step(   ) {
      if (in_step) {
        recs[nrec++] = sprintf("%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s",
          stepname, stepcap, uses, retry_to, retry_ma, boot_to,
          (cmd == "" ? "-" : cmd), body)
      }
      in_step = 0; in_cmd = 0
      stepname = "-"; stepcap = "-"; uses = "-"
      retry_to = "-"; retry_ma = "-"; boot_to = "-"; cmd = "-"; body = ""
    }
    function flush_job(   i) {
      flush_step()
      for (i = 0; i < nrec; i++) printf "%s\t%s\t%s\t%s\t%s\n", file, job, jobcap, runs_on, recs[i]
      nrec = 0; jobcap = "-"; runs_on = "-"
    }
    function value(line) { sub(/^[^:]*:[[:space:]]*/, "", line); sub(/[[:space:]]+#.*$/, "", line); return line }
    BEGIN {
      job = "-"; jobcap = "-"; runs_on = "-"
      stepname = "-"; stepcap = "-"; uses = "-"
      retry_to = "-"; retry_ma = "-"; boot_to = "-"; cmd = "-"; body = ""
      in_jobs = 0; in_steps = 0; in_step = 0; in_cmd = 0; nrec = 0
    }
    # Top-level key: leaving (or entering) the jobs: block.
    /^[A-Za-z_][A-Za-z0-9_-]*:/ {
      flush_job(); in_steps = 0
      in_jobs = ($0 ~ /^jobs:/)
      next
    }
    !in_jobs { next }
    # Job header (2-space indent).
    /^  [A-Za-z_][A-Za-z0-9_.-]*:[[:space:]]*(#.*)?$/ {
      flush_job(); in_steps = 0
      job = $0; sub(/^  /, "", job); sub(/:[[:space:]]*(#.*)?$/, "", job)
      next
    }
    # A job-level key (4-space indent) ends the steps, wherever it sits.
    in_steps && /^    [A-Za-z_]/ { flush_step(); in_steps = 0 }
    !in_steps && /^    timeout-minutes:/ { jobcap = value($0); next }
    !in_steps && /^    runs-on:/ { runs_on = value($0); next }
    /^    steps:[[:space:]]*(#.*)?$/ { in_steps = 1; next }
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
      sub(/^      - /, "        ")
    }
    !in_step { next }
    # Full-line comments never reach the body (see header).
    /^[[:space:]]*#/ { next }
    in_cmd && /^            / {
      c = $0; sub(/^[[:space:]]+/, "", c); gsub(/\t/, " ", c)
      cmd = cmd (cmd == "" || cmd == "|" ? "" : cmd_sep) c
    }
    in_cmd && !/^            / && !/^[[:space:]]*$/ { in_cmd = 0 }
    /^          (script|command):[[:space:]]*/ {
      c = $0; sub(/^          (script|command):[[:space:]]*/, "", c); gsub(/\t/, " ", c)
      if (c ~ /^[>|][-+]?[[:space:]]*$/) {
        in_cmd = 1; cmd_sep = (c ~ /^[|]/) ? " ; " : " "; cmd = (c ~ /^[|]/) ? "|" : ""
      } else cmd = c
    }
    /^        timeout-minutes:/ { stepcap = value($0) }
    /^        uses:/ { uses = value($0) }
    /^          timeout_minutes:/ { retry_to = value($0) }
    /^          max_attempts:/ { retry_ma = value($0) }
    /^          emulator-boot-timeout:/ { boot_to = value($0) }
    { gsub(/\t/, " "); body = body " " $0 }
    END { flush_job() }
  ' "${file}"
}

# ---------------------------------------------------------------------------
# Value helpers
# ---------------------------------------------------------------------------

# expr_parts <raw> -> true for a `${{ <cond> && A || B }}`, leaving <cond> in
# BASH_REMATCH[1] and A and B in [2] and [3]. A `||` inside <cond> means more
# than two outcomes (`a && 70 || b && 42 || 30`), of which the pattern would
# read only the last two, so that is refused rather than half-read.
expr_parts() {
  [[ "$1" =~ \$\{\{([^}]*)\&\&[[:space:]]*\'?([0-9]+[smhd]?)\'?[[:space:]]*\|\|[[:space:]]*\'?([0-9]+[smhd]?)\'?[[:space:]]*\}\} ]] \
    && [[ "${BASH_REMATCH[1]}" != *'||'* ]]
}

# branches <raw> -> "<true-branch> <false-branch>", or "" if unparseable.
# A scalar broadcasts to both branches so callers never special-case it.
branches() {
  local raw="$1"
  raw="${raw%\"}"; raw="${raw#\"}"
  if expr_parts "${raw}"; then
    printf '%s %s\n' "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}"
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

# dur_to_secs <token> -> whole seconds, reading a bare number as minutes as
# dur_to_min does (a `timeout_minutes` is minutes). check_e2e_lane_budget.sh
# compares deadlines in seconds through this, so the two guards read a
# deadline alike.
dur_to_secs() {
  local t="$1" n unit
  if [[ "${t}" =~ ^([0-9]+)([smhd]?)$ ]]; then
    n="${BASH_REMATCH[1]}"; unit="${BASH_REMATCH[2]}"
  else
    echo ""; return
  fi
  case "${unit}" in
    s) echo "${n}" ;;
    ""|m) echo $(( n * 60 )) ;;
    h) echo $(( n * 3600 )) ;;
    d) echo $(( n * 86400 )) ;;
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

# GitHub resolves a `uses:` owner without regard to case, and the action's own
# is spelled ReactiveCircus: a case-sensitive match would drop that lane.
is_emulator_step() {
  local u
  u="$(LC_ALL=C tr '[:upper:]' '[:lower:]' <<<"$1")"
  [[ "${u}" == *"reactivecircus/android-emulator-runner"* ]]
}
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
  [[ "$1" == *"run-ios-sim-scenario.sh"* || "$1" == *"boot-ios-sim.sh"* \
     || "$1" == *"run-b7-ios-auth-tier.sh"* \
     || "$1" == *"run-b4-ios-real-gps.sh"* ]]
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
# Files in which the extractor actually counted a step, newline-separated. These
# are what the repo-derived vacuity check compares against: a NUMBER can only
# say "fewer than expected", a SET can name the lane that went missing.
EMU_FILES=""
DRIVE_FILES=""
check_dir() {
  local dir="$1"
  local files=()
  while IFS= read -r f; do files+=("${f}"); done < <(find "${dir}" -maxdepth 1 -name '*.yml' | sort)
  (( ${#files[@]} > 0 )) || misconfig "no workflow files under ${dir}"

  EMU_STEPS=0
  DRIVE_STEPS=0
  EMU_FILES=""
  DRIVE_FILES=""
  local file job jobcap runs_on stepname stepcap uses retry_to retry_ma boot_to _cmd body

  local rec
  for f in "${files[@]}"; do
    while IFS=$'\t' read -r file job jobcap runs_on stepname stepcap uses retry_to retry_ma boot_to _cmd body; do
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
      EMU_FILES="${EMU_FILES}${file##*/}"$'\n'
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
      DRIVE_FILES="${DRIVE_FILES}${file##*/}"$'\n'

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

# extract_job_caps <file> -> one TSV record per job:
#   job  declaration  declarations-in-job
# `declaration` is the payload of a `# job-uncapped-minutes:` comment on the
# line directly above the job-level `timeout-minutes:`, or "-". The job cap
# itself is taken from extract_steps, so C3 and C6 read the same number. Only
# a job-level key sits at four spaces, so that cap is found before or after
# the steps alike.
extract_job_caps() {
  awk '
    function flush() {
      if (job != "-") printf "%s\t%s\t%d\n", job, decl, ndecl
      job = "-"; decl = "-"; ndecl = 0
    }
    BEGIN { job = "-"; decl = "-"; ndecl = 0; in_jobs = 0; prev = "" }
    /^[A-Za-z_][A-Za-z0-9_-]*:/ {
      flush(); in_jobs = ($0 ~ /^jobs:/); prev = $0; next
    }
    !in_jobs { prev = $0; next }
    /^  [A-Za-z_][A-Za-z0-9_.-]*:[[:space:]]*(#.*)?$/ {
      flush()
      job = $0; sub(/^  /, "", job); sub(/:[[:space:]]*(#.*)?$/, "", job)
      prev = $0; next
    }
    /^[[:space:]]*#[[:space:]]*job-uncapped-minutes:/ { ndecl++ }
    /^    timeout-minutes:/ && prev ~ /^[[:space:]]*#[[:space:]]*job-uncapped-minutes:/ {
      decl = prev; sub(/^[[:space:]]*#[[:space:]]*job-uncapped-minutes:[[:space:]]*/, "", decl)
      gsub(/\t/, " ", decl)
    }
    { prev = $0 }
    END { flush() }
  ' "$1"
}

# Minutes (below 1000, at most two decimals, `.` only), then the provenance.
readonly C6_DECL_RE='^(0|[1-9][0-9]{0,2})(\.([0-9]{1,2}))?[[:space:]]+\(([1-9][0-9]*) runs([^()]*), worst ([1-9][0-9]{7,})\)[[:space:]]*$'

# hundredths_to_min <n> -> "<n/100>.<n%100>", e.g. 11635 -> 116.35
hundredths_to_min() { printf '%d.%02d' $(( $1 / 100 )) $(( $1 % 100 )); }

C6_JOBS=0
check_job_caps() {
  local dir="$1" f
  C6_JOBS=0
  while IFS= read -r f; do
    local -A scope=() jobcap=() list0=() list1=() sum0=() sum1=() split=() bad=() decl=() ndecl=()
    local -A cond=() mixed=()
    local _file job jc _runs_on stepname stepcap uses _rto _rma _boot _cmd body
    while IFS=$'\t' read -r _file job jc _runs_on stepname stepcap uses _rto _rma _boot _cmd body; do
      jobcap[${job}]="${jc}"
      local vals=("${jc}" "${stepcap}") v w
      if is_emulator_step "${uses}" || is_simulator_body "${body}"; then
        scope[${job}]=1
        if is_drive_body "${body}"; then
          vals+=("${_rto}" "${_rma}" "$(deadline_token "${body}")" "$(drive_timeout_token "${body}")")
        fi
      fi
      # Every value some check here pairs with another, by branch position.
      for v in "${vals[@]}"; do
        expr_parts "${v}" || continue
        read -r -a w <<<"${BASH_REMATCH[1]}"
        if [[ -z "${cond[${job}]:-}" ]]; then cond[${job}]="${w[*]}"
        elif [[ "${w[*]}" != "${cond[${job}]}" ]]; then mixed[${job}]="${w[*]}"; fi
      done
      if [[ "${stepcap}" == "-" ]]; then continue; fi
      local s0 s1
      # shellcheck disable=SC2207
      local SB=($(branches "${stepcap}"))
      s0="$(cap_to_min "${SB[0]:-}")"; s1="$(cap_to_min "${SB[1]:-}")"
      if [[ -z "${s0}" || -z "${s1}" ]]; then
        bad[${job}]+=" '${stepname}' (${stepcap})"
        continue
      fi
      sum0[${job}]=$(( ${sum0[${job}]:-0} + s0 )); sum1[${job}]=$(( ${sum1[${job}]:-0} + s1 ))
      list0[${job}]+="${list0[${job}]:+ + }${s0}"; list1[${job}]+="${list1[${job}]:+ + }${s1}"
      if [[ "${s0}" != "${s1}" ]]; then split[${job}]=1; fi
    done < <(extract_steps "${f}")
    (( ${#scope[@]} > 0 )) || continue

    local d n
    while IFS=$'\t' read -r job d n; do
      decl[${job}]="${d}"; ndecl[${job}]="${n}"
    done < <(extract_job_caps "${f}")

    while IFS= read -r job; do
      C6_JOBS=$((C6_JOBS + 1))
      local label="${f##*/} :: ${job}"
      if [[ -n "${bad[${job}]:-}" ]]; then
        note_violation "C6 ${label}: cannot sum the step caps, not a bare number of minutes:${bad[${job}]}."
        continue
      fi
      local j0 j1
      # shellcheck disable=SC2207
      local JB=($(branches "${jobcap[${job}]}"))
      j0="$(cap_to_min "${JB[0]:-}")"; j1="$(cap_to_min "${JB[1]:-}")"
      if [[ -z "${j0}" || -z "${j1}" ]]; then
        note_violation "C6 ${label}: job timeout-minutes '${jobcap[${job}]}' is not a parseable number of minutes, so its steps cannot be checked against it."
        continue
      fi
      if [[ -n "${mixed[${job}]:-}" ]]; then
        note_violation "C6 ${label}: its \${{ c && A || B }} caps and deadlines key on different conditions ('${cond[${job}]}', '${mixed[${job}]}'). Every check here pairs their branches by position, which holds only for one condition."
        continue
      fi
      local dv="${decl[${job}]:--}"
      if [[ "${dv}" == "-" ]]; then
        local hint=""
        if (( ${ndecl[${job}]:-0} > 0 )); then
          hint=" One appears elsewhere in the job; only the line directly above timeout-minutes is read."
        fi
        note_violation "C6 ${label}: no job-uncapped-minutes declaration directly above the job's timeout-minutes. A missing allowance is not zero: declare the most this job's uncapped work has ever taken, as # job-uncapped-minutes: <minutes> (<N> runs, worst <run id>).${hint}"
        continue
      fi
      if (( ${ndecl[${job}]} > 1 )); then
        note_violation "C6 ${label}: ${ndecl[${job}]} job-uncapped-minutes declarations; only the one directly above timeout-minutes is read, so any other is stale or misleading. Keep one."
        continue
      fi
      if ! [[ "${dv}" =~ ${C6_DECL_RE} ]]; then
        note_violation "C6 ${label}: declaration '${dv}' is not <minutes> (<N> runs, worst <run id>): minutes below 1000 as digits with at most two decimals after a '.', then how many runs were measured and the worst one, so a reviewer can re-measure it."
        continue
      fi
      local frac="${BASH_REMATCH[3]}00"
      local allow=$(( 10#${BASH_REMATCH[1]} * 100 + 10#${frac:0:2} ))
      if (( allow == 0 )); then
        note_violation "C6 ${label}: declares no uncapped time at all, which no job has (setting up the runner alone takes seconds)."
        continue
      fi
      # Branches pair positionally, as in C3: A is `${{ c && A || B }}`'s first.
      local scalar=0 i jc_i sum_i list_i need tag="" side=(A B)
      if [[ -z "${split[${job}]:-}" && "${j0}" == "${j1}" ]]; then scalar=1; fi
      for i in 0 1; do
        if (( i == 0 )); then jc_i="${j0}"; sum_i="${sum0[${job}]:-0}"; list_i="${list0[${job}]:-none}"
        else jc_i="${j1}"; sum_i="${sum1[${job}]:-0}"; list_i="${list1[${job}]:-none}"; fi
        if (( ! scalar )); then tag=" [${side[i]} branch]"; fi
        need=$(( sum_i * 100 + allow ))
        if (( jc_i * 100 < need )); then
          note_violation "C6 ${label}${tag}: job cap ${jc_i}m is below its step caps (${list_i} = ${sum_i}) plus the declared uncapped $(hundredths_to_min "${allow}") = $(hundredths_to_min "${need}"). A run whose every step is still inside its own cap can die at the job cap, before its if: failure() diagnostics run."
        fi
        if (( scalar )); then break; fi
      done
    done < <(printf '%s\n' "${!scope[@]}" | sort)
  done < <(find "${dir}" -maxdepth 1 -name '*.yml' | sort)
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

check_extractor_sees_the_repo() {
  local wf="$1"

  # Full-line comments are stripped, exactly as the extractor strips them from
  # step bodies. Without this a commented-out `uses:` line, or a comment naming
  # a harness script, would be counted as a lane the extractor "lost" — a guard
  # that reds on a correct repo gets deleted rather than fixed.
  local MARKERS='uses:.*reactivecircus/android-emulator-runner|run-ios-sim-scenario\.sh|boot-ios-sim\.sh|run-b7-ios-auth-tier\.sh|run-b4-ios-real-gps\.sh'
  _uncommented() { grep -v '^[[:space:]]*#' "$1"; }

  # (0) Every step list is laid out as the extractor reads it: items at six
  #     spaces, each `- <key>:`, the rest at eight or deeper. YAML also allows
  #     an indentless (`    - `) or deeper list, a flow mapping or an alias,
  #     none of which the extractor reads as a step, so every check would pass
  #     that job unseen; (b) cannot tell while another job in its file counts.
  local unread
  unread="$(awk '
    FNR == 1 { in_jobs = 0; in_steps = 0 }
    /^[A-Za-z_]/ { in_jobs = ($0 ~ /^jobs:/); in_steps = 0; next }
    !in_jobs || /^[[:space:]]*(#|$)/ { next }
    /^  [^ ]/ || /^    [A-Za-z_]/ { in_steps = ($0 ~ /^    steps:[[:space:]]*(#.*)?$/); item = 0; next }
    !in_steps { next }
    /^      - [A-Za-z_][A-Za-z0-9_-]*:/ { item = 1; next }
    item && /^        / { next }
    { f = FILENAME; sub(/^.*\//, "", f); print " " f ":" FNR; in_steps = 0 }
  ' "${wf}"/*.yml)" || misconfig "could not scan ${wf} for step lists"
  [[ -z "${unread}" ]] || misconfig "these step lists are not laid out as the extractor reads them (items at six spaces, each \`- <key>:\`):${unread//$'\n'/}. It sees no step there, so no check here covers that job."

  # (a) EXACT count. `uses:` appears exactly once per step, so the number of
  #     reactivecircus lines IS the number of emulator steps — no estimate.
  local expect_emu=0 f base n
  for f in "${wf}"/*.yml; do
    n="$(_uncommented "${f}" | grep -ci "uses:.*reactivecircus/android-emulator-runner" || true)"
    expect_emu=$((expect_emu + n))
  done
  if (( expect_emu > EMU_STEPS )); then
    misconfig "the extractor counted ${EMU_STEPS} emulator/simulator step(s) but ${expect_emu} \`uses: reactivecircus/android-emulator-runner\` line(s) exist. It has stopped seeing $(( expect_emu - EMU_STEPS )) emulator step(s); the record parser or is_emulator_step() has rotted."
  fi

  # (b) SET coverage. Every workflow carrying a marker must contribute at least
  #     one counted step. Names the lane rather than reporting a shortfall.
  local missing=""
  for f in "${wf}"/*.yml; do
    base="${f##*/}"
    # repo-guards.yml invokes the same harnesses hermetically with --self-test:
    # no emulator, no simulator, seconds long. Not a lane. The last reader
    # drains its input: one that stopped at its first match could leave a
    # writer to die of SIGPIPE, which pipefail turns into a skipped workflow.
    _uncommented "${f}" | grep -E "${MARKERS}" | grep -v -- "--self-test" | awk 'END { exit (NR == 0) }' || continue
    grep -qxF "${base}" <<<"${EMU_FILES}" || missing="${missing} ${base}"
  done
  [[ -z "${missing}" ]] || misconfig "these workflows carry an emulator/simulator marker but the extractor counted no step in them:${missing}. Either the lane lost its bound, or the extractor stopped parsing it."

  # (c) SET coverage for drives, same argument one level down.
  local dmissing=""
  for f in "${wf}"/*.yml; do
    base="${f##*/}"
    _uncommented "${f}" | grep "tooling/e2e/ci/run-" | grep -v -- "--self-test" | awk 'END { exit (NR == 0) }' || continue
    grep -qxF "${base}" <<<"${EMU_FILES}" || continue   # not a lane at all; (b) owns that
    grep -qxF "${base}" <<<"${DRIVE_FILES}" || dmissing="${dmissing} ${base}"
  done
  [[ -z "${dmissing}" ]] || misconfig "these workflows run a harness but the extractor counted no DRIVE step in them:${dmissing}. is_drive_body() has stopped matching, so C1/C2/C4 are asserting nothing there."

  log "vacuity check: ${expect_emu} emulator \`uses:\` line(s) all accounted for; every marker-bearing workflow contributed a step"
}

self_test() {
  # Fixture count pinned by EQUALITY, not printed as prose. A hardcoded "(N
  # cases)" in the closing line is how a deleted fixture reports "all passed"
  # while running one check fewer — the exact rot this whole self-test exists to
  # prevent in the checks it covers.
  local -r SELF_TEST_CASES=44
  local tmp failures=0 cases=0
  tmp="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf '${tmp}'" RETURN

  _expect() {
    local desc="$1" dir="$2" want_rc="$3" want_grep="${4:-}"
    local out rc=0
    cases=$((cases + 1))
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

  # --- The action's owner in its own capitals, as GitHub also resolves it.
  local cc="${tmp}/cc"; mkdir -p "${cc}"
  write_fixture "${cc}/c2case.yml" \
'jobs:' \
'  lane:' \
'    runs-on: ubuntu-latest' \
'    timeout-minutes: 60' \
'    steps:' \
'      - name: Drive' \
'        timeout-minutes: 30' \
'        uses: ReactiveCircus/android-emulator-runner@v2' \
'        with:' \
'          emulator-boot-timeout: 420' \
'          script: bash tooling/e2e/ci/run-with-deadline.sh 26m lane -- bash tooling/e2e/ci/run-x.sh'
  _expect "an emulator action written ReactiveCircus/… is still a lane" "${cc}" 1 "C2"

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

  # --- The vacuity check itself. It replaced a hardcoded floor (>=10 steps,
  #     >=8 drives) that the repo had outgrown by 3.5x, so these fixtures exist
  #     to stop the REPLACEMENT rotting the same way. `misconfig` exits, so each
  #     case runs in a subshell.
  _expect_vacuity() {
    local desc="$1" dir="$2" want_rc="$3" want_grep="${4:-}"
    cases=$((cases + 1))
    local out rc=0
    out="$( ( VIOLATIONS=0; check_dir "${dir}" >/dev/null 2>&1
              check_extractor_sees_the_repo "${dir}" ) 2>&1 )" || rc=$?
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

  # M: a well-formed lane — the extractor sees it, so nothing fires.
  _expect_vacuity "vacuity: a lane the extractor parses is accounted for" "${a}" 0

  # N: a workflow carrying the emulator marker that the extractor counts NO
  #    step in. This is the shape the old floor could not see: with 35 real
  #    steps, losing one lane still cleared a floor of 10.
  local n="${tmp}/n"; mkdir -p "${n}"
  #    The marker reaches the file through job-level `env:` indirection, so the
  #    raw grep sees the lane but the body-matching classifier never does.
  write_fixture "${n}/lane.yml" \
'jobs:' \
'  lane:' \
'    runs-on: macos-latest' \
'    timeout-minutes: 60' \
'    env:' \
'      HARNESS: tooling/e2e/ci/run-ios-sim-scenario.sh' \
'    steps:' \
'      - name: Drive' \
'        timeout-minutes: 35' \
'        run: bash "${HARNESS}" lane'
  _expect_vacuity "vacuity: a marker-bearing lane with no counted step is named" "${n}" 2 "lane.yml"

  # O: the EXACT half. Two `uses:` lines, one inside a job the extractor cannot
  #    reach, so the count disagrees even though the file itself contributed.
  local o="${tmp}/o"; mkdir -p "${o}"
  write_fixture "${o}/two.yml" \
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
'          script: bash tooling/e2e/ci/run-with-deadline.sh 25m lane -- bash tooling/e2e/ci/run-x.sh' \
'  orphan:' \
'    uses: reactivecircus/android-emulator-runner@v2'
  _expect_vacuity "vacuity: an unparsed \`uses:\` line fails the exact count" "${o}" 2 "stopped seeing"

  local oc="${tmp}/oc"; mkdir -p "${oc}"
  sed 's|^    uses: reactivecircus/|    uses: ReactiveCircus/|' "${o}/two.yml" > "${oc}/two.yml"
  _expect_vacuity "vacuity: the exact count reads the action's owner in any case" "${oc}" 2 "stopped seeing"

  # P: repo-guards.yml's hermetic --self-test steps carry the marker strings but
  #    are not lanes. They must not be DEMANDED as steps, or the guard reds on a
  #    correct repo — the false-positive direction, which is how guards get
  #    deleted rather than fixed.
  _expect_vacuity "vacuity: a hermetic --self-test workflow is not demanded" "${l}" 0

  # Q: check (c). The file references a harness, and its emulator step IS
  #    counted — but no step body carries the reference, so no DRIVE is counted
  #    and C1/C2/C4 silently assert nothing about this lane.
  local q="${tmp}/q"; mkdir -p "${q}"
  write_fixture "${q}/snapshot-only.yml" \
'jobs:' \
'  lane:' \
'    runs-on: ubuntu-latest' \
'    timeout-minutes: 60' \
'    env:' \
'      HARNESS: tooling/e2e/ci/run-x.sh' \
'    steps:' \
'      - name: Snapshot' \
'        timeout-minutes: 35' \
'        uses: reactivecircus/android-emulator-runner@v2' \
'        with:' \
'          emulator-boot-timeout: 420' \
'          script: echo snapshot'
  _expect_vacuity "vacuity: a lane whose harness call is never a step body is named" "${q}" 2 "no DRIVE step"

  # R: the false-positive direction. A COMMENTED-OUT marker must not be read as
  #    a lane the extractor lost — the extractor strips full-line comments, so
  #    this check must too, or it reds on a correct repo.
  local r="${tmp}/r"; mkdir -p "${r}"
  write_fixture "${r}/commented.yml" \
'jobs:' \
'  lane:' \
'    runs-on: ubuntu-latest' \
'    timeout-minutes: 60' \
'    steps:' \
'      # uses: reactivecircus/android-emulator-runner@v2 — removed, see #123' \
'      # was: bash tooling/e2e/ci/run-ios-sim-scenario.sh lane' \
'      - name: Nothing' \
'        run: echo hi'
  _expect_vacuity "vacuity: a commented-out marker is not a lost lane" "${r}" 0

  # --- C6. Every fixture below passes C1-C5, and a red one must be red for C6
  #     alone: a fixture that tripped another check would prove nothing here.
  #     `forbid` names output that must NOT appear.
  _expect_c6() {
    local desc="$1" dir="$2" want_rc="$3" want_grep="${4:-}" forbid="${5:-}"
    local out rc=0 line
    cases=$((cases + 1))
    if [[ -z "${dir}" ]]; then
      echo "FAIL: ${desc}: its variant is identical to the sound lane, so it tests nothing" >&2
      failures=$((failures + 1)); return
    fi
    VIOLATIONS=0
    { check_dir "${dir}"; check_job_caps "${dir}"; } 2>"${tmp}/err.txt" || rc=$?
    out="$(cat "${tmp}/err.txt")"
    (( VIOLATIONS > 0 )) && rc=1
    while IFS= read -r line; do
      if [[ "${line}" == *"] FAIL:"* && "${line}" != *" C6 "* ]]; then
        echo "FAIL: ${desc}: a check other than C6 fired: ${line}" >&2
        failures=$((failures + 1)); return
      fi
    done <<<"${out}"
    if (( rc != want_rc )); then
      echo "FAIL: ${desc}: expected rc ${want_rc}, got ${rc}" >&2
      echo "${out}" | sed 's/^/    /' >&2
      failures=$((failures + 1)); return
    fi
    if [[ -n "${want_grep}" ]] && ! grep -qF -- "${want_grep}" <<<"${out}"; then
      echo "FAIL: ${desc}: output did not mention '${want_grep}'" >&2
      echo "${out}" | sed 's/^/    /' >&2
      failures=$((failures + 1)); return
    fi
    if [[ -n "${forbid}" ]] && grep -qF -- "${forbid}" <<<"${out}"; then
      echo "FAIL: ${desc}: output mentioned '${forbid}'" >&2
      echo "${out}" | sed 's/^/    /' >&2
      failures=$((failures + 1)); return
    fi
    echo "  ok: ${desc}"
  }
  # _c6_variant <name> <sed expression> — the sound lane, changed in one place.
  # Prints nothing if the edit did not apply, which _expect_c6 fails.
  _c6_variant() {
    mkdir -p "${tmp}/$1"
    sed "$2" "${tmp}/c6/lane.yml" > "${tmp}/$1/lane.yml"
    if ! cmp -s "${tmp}/c6/lane.yml" "${tmp}/$1/lane.yml"; then printf '%s\n' "${tmp}/$1"; fi
  }

  # The sound lane: 30 + 15 + 42 = 87 of step caps, 2.5 declared, 89.5 <= 90.
  # The build step is not an emulator step, and its cap counts all the same.
  # The second job runs no emulator, so it is not C6's and declares nothing.
  mkdir -p "${tmp}/c6"
  write_fixture "${tmp}/c6/lane.yml" \
'jobs:' \
'  lane:' \
'    runs-on: ubuntu-latest' \
'    # job-uncapped-minutes: 2.5 (40 runs, worst 12345678901)' \
'    timeout-minutes: 90' \
'    steps:' \
'      - name: Build' \
'        timeout-minutes: 30' \
'        run: bash build.sh' \
'      - name: Create AVD snapshot' \
'        timeout-minutes: 15' \
'        uses: reactivecircus/android-emulator-runner@v2' \
'        with:' \
'          emulator-boot-timeout: 420' \
'          script: echo snapshot' \
'      - name: Drive' \
'        timeout-minutes: 42' \
'        uses: reactivecircus/android-emulator-runner@v2' \
'        with:' \
'          emulator-boot-timeout: 420' \
'          script: bash tooling/e2e/ci/run-with-deadline.sh 32m lane -- bash tooling/e2e/ci/run-x.sh' \
'  build:' \
'    runs-on: ubuntu-latest' \
'    timeout-minutes: 20' \
'    steps:' \
'      - name: Compile' \
'        timeout-minutes: 15' \
'        run: bash build.sh'
  _expect_c6 "C6: a job cap covering its step caps plus its declaration passes" "${tmp}/c6" 0

  _expect_c6 "C6: the job cap lowered by one minute fails" \
    "$(_c6_variant c6-cap 's/^    timeout-minutes: 90$/    timeout-minutes: 89/')" 1 "= 89.50"
  _expect_c6 "C6: a step cap raised without the job cap fails" \
    "$(_c6_variant c6-step 's/^        timeout-minutes: 30$/        timeout-minutes: 31/')" 1 "= 90.50"
  _expect_c6 "C6: a job with no declaration fails (a missing allowance is not zero)" \
    "$(_c6_variant c6-none '/job-uncapped-minutes/d')" 1 "no job-uncapped-minutes declaration"
  _expect_c6 "C6: a declaration with no provenance fails" \
    "$(_c6_variant c6-bare 's/ (40 runs, worst 12345678901)$//')" 1 "is not <minutes>"
  _expect_c6 "C6: a provenance that names no worst run fails" \
    "$(_c6_variant c6-noworst 's/, worst 12345678901)$/)/')" 1 "is not <minutes>"

  # The poll side (B) alone is over: 30 + 15 + 42 + 2.5 = 89.5 > 89, while the
  # live side is 30 + 15 + 58 + 2.5 = 105.5 <= 106. Reporting A too, or only A,
  # would mean the branches are not paired positionally.
  _expect_c6 "C6: a conditional cap whose second branch alone violates fails" \
    "$(_c6_variant c6-expr 's/^    timeout-minutes: 90$/    timeout-minutes: ${{ inputs.live_sync \&\& 106 || 89 }}/
      s/^        timeout-minutes: 42$/        timeout-minutes: ${{ inputs.live_sync \&\& 58 || 42 }}/
      s/run-with-deadline.sh 32m/run-with-deadline.sh ${{ inputs.live_sync \&\& '"'48m'"' || '"'32m'"' }}/')" \
    1 "[B branch]" "[A branch]"
  # The same lane sound on both sides (105.5 <= 106, 89.5 <= 90), its step's
  # expression spaced differently: one condition, however it is written.
  _expect_c6 "C6: a conditional lane that fits on both branches passes" \
    "$(_c6_variant c6-expr-ok 's/^    timeout-minutes: 90$/    timeout-minutes: ${{ inputs.live_sync \&\& 106 || 90 }}/
      s/^        timeout-minutes: 42$/        timeout-minutes: ${{inputs.live_sync\&\&58||42}}/
      s/run-with-deadline.sh 32m/run-with-deadline.sh ${{ inputs.live_sync \&\& '"'48m'"' || '"'32m'"' }}/')" 0
  # A scalar job cap over a conditional step: 87 + 2.5 fits on A, 88 + 2.5 does
  # not on B. Checking one branch, or B with A's caps, passes it.
  _expect_c6 "C6: a scalar job cap is checked against both branches of its steps" \
    "$(_c6_variant c6-split 's/^        timeout-minutes: 42$/        timeout-minutes: ${{ inputs.live_sync \&\& 42 || 43 }}/')" \
    1 "[B branch]" "[A branch]"
  # The job's cap keys on the negation of the step's condition. Paired by
  # position both sides fit (106 >= 105.5, 90 >= 89.5); run for real, a live
  # run gets 90 minutes for 105.5 of work.
  _expect_c6 "C6: caps keyed on different conditions are refused, not paired" \
    "$(_c6_variant c6-cond 's/^    timeout-minutes: 90$/    timeout-minutes: ${{ !inputs.live_sync \&\& 106 || 90 }}/
      s/^        timeout-minutes: 42$/        timeout-minutes: ${{ inputs.live_sync \&\& 58 || 42 }}/
      s/run-with-deadline.sh 32m/run-with-deadline.sh ${{ inputs.live_sync \&\& '"'48m'"' || '"'32m'"' }}/')" \
    1 "different conditions"
  # The caps agree, the deadline C2 pairs with the step cap does not.
  _expect_c6 "C6: a deadline keyed on another condition than its caps is refused" \
    "$(_c6_variant c6-cond-dl 's/^    timeout-minutes: 90$/    timeout-minutes: ${{ inputs.live_sync \&\& 106 || 90 }}/
      s/^        timeout-minutes: 42$/        timeout-minutes: ${{ inputs.live_sync \&\& 58 || 42 }}/
      s/run-with-deadline.sh 32m/run-with-deadline.sh ${{ inputs.slow \&\& '"'48m'"' || '"'32m'"' }}/')" \
    1 "different conditions"

  # Exactness, both ways: 87 + 3.00 is exactly 90, and 87 + 3.01 is not. A
  # check that truncated the fraction, or compared with a strict `<`, fails one.
  _expect_c6 "C6: a fractional allowance at exactly the boundary passes" \
    "$(_c6_variant c6-edge 's/minutes: 2.5 /minutes: 3.00 /')" 0
  _expect_c6 "C6: a fractional allowance 0.01 over the boundary fails" \
    "$(_c6_variant c6-over 's/minutes: 2.5 /minutes: 3.01 /')" 1 "= 90.01"
  # A comma is a decimal point in half the world's locales; read as "3" it
  # would pass. It is not a number here at all.
  _expect_c6 "C6: a comma-decimal allowance is refused, not read as its integer part" \
    "$(_c6_variant c6-comma 's/minutes: 2.5 /minutes: 3,01 /')" 1 "is not <minutes>"
  _expect_c6 "C6: an allowance of zero is refused" \
    "$(_c6_variant c6-zero 's/minutes: 2.5 /minutes: 0.00 /')" 1 "declares no uncapped time"
  # One line between the declaration and the cap, and it is no longer read:
  # adjacency is what keeps a figure attached to the cap it justifies.
  _expect_c6 "C6: a declaration not directly above the job cap is not read" \
    "$(_c6_variant c6-apart 's/^    timeout-minutes: 90$/    # sized for the lane\
    timeout-minutes: 90/')" 1 "only the line directly above"
  _expect_c6 "C6: a second declaration in the job is refused" \
    "$(_c6_variant c6-twice 's/^      - name: Drive$/      # job-uncapped-minutes: 9.0 (40 runs, worst 12345678901)\
&/')" 1 "2 job-uncapped-minutes declarations"
  # No job runs 1000 minutes, and a long enough figure would overflow the
  # hundredths arithmetic into a pass.
  _expect_c6 "C6: an allowance of 1000 minutes or more is refused" \
    "$(_c6_variant c6-big 's/minutes: 2.5 /minutes: 1000 /')" 1 "is not <minutes>"

  # Layouts YAML allows and a reader keyed to indentation could miss. Each
  # must be read as the same lane, so each red names the same sum.
  _expect_c6 "C6: a step cap written as the step's first key still counts" \
    "$(_c6_variant c6-first 's/^    timeout-minutes: 90$/    timeout-minutes: 89/
      s/^      - name: Build$/      - timeout-minutes: 30/
      s/^        timeout-minutes: 30$/        name: Build/')" 1 "(30 + 15 + 42 = 87) plus the declared uncapped 2.50 = 89.50"
  _expect_c6 "C6: comments after a job header and its caps are not part of them" \
    "$(_c6_variant c6-comments 's/^  lane:$/  lane:  # the lane/
      s/^    timeout-minutes: 90$/    timeout-minutes: 89  # sized below/
      s/^        timeout-minutes: 30$/        timeout-minutes: 30 # the build/')" 1 "(30 + 15 + 42 = 87) plus the declared uncapped 2.50 = 89.50"
  _expect_c6 "C6: a job cap written after the steps is read" \
    "$(_c6_variant c6-after '/job-uncapped-minutes/d
      /^    timeout-minutes: 90$/d
      s/run-x\.sh$/&\
    # job-uncapped-minutes: 2.5 (40 runs, worst 12345678901)\
    timeout-minutes: 89/')" 1 "(30 + 15 + 42 = 87) plus the declared uncapped 2.50 = 89.50"

  # A simulator lane is C6's as much as an emulator one: 15 + 65 + 4.5 > 84.
  local c6i="${tmp}/c6-ios"; mkdir -p "${c6i}"
  write_fixture "${c6i}/ios.yml" \
'jobs:' \
'  lane:' \
'    runs-on: macos-latest' \
'    # job-uncapped-minutes: 4.5 (30 runs, worst 12345678901)' \
'    timeout-minutes: 84' \
'    steps:' \
'      - name: Boot iOS simulator' \
'        timeout-minutes: 15' \
'        run: bash tooling/e2e/ci/boot-ios-sim.sh' \
'      - name: Drive' \
'        timeout-minutes: 65' \
'        uses: nick-fields/retry@v3' \
'        with:' \
'          timeout_minutes: 30' \
'          max_attempts: 2' \
'          command: bash tooling/e2e/ci/run-ios-sim-scenario.sh x'
  _expect_c6 "C6: a simulator lane's job cap is checked too" "${c6i}" 1 "(15 + 65 = 80) plus the declared uncapped 4.50 = 84.50"

  # Three outcomes, of which a two-branch reader would see only 42 and 30.
  local x3="${tmp}/x3"; mkdir -p "${x3}"
  sed 's/^        timeout-minutes: 35$/        timeout-minutes: ${{ inputs.a \&\& 70 || inputs.b \&\& 42 || 30 }}/' \
    "${a}/ok.yml" > "${x3}/ok.yml"
  _expect "an expression with more than two outcomes is refused, not half-read" "${x3}" 1 "is not a parseable number"

  # An indentless step list in a file whose other job IS counted: (b) passes
  # that file, so only the layout check can name it.
  local v0="${tmp}/v0"; mkdir -p "${v0}"
  sed 's/^  lane:$/  first:/' "${a}/ok.yml" > "${v0}/two.yml"
  printf '%s\n' \
'  lane:' \
'    runs-on: macos-latest' \
'    timeout-minutes: 60' \
'    steps:' \
'    - name: Drive' \
'      timeout-minutes: 50' \
'      run: bash tooling/e2e/ci/run-with-deadline.sh 40m x -- bash tooling/e2e/ci/run-ios-sim-scenario.sh x' \
    >> "${v0}/two.yml"
  _expect_vacuity "vacuity: a step list the extractor cannot read is named" "${v0}" 2 "two.yml:18"

  VIOLATIONS=0
  if (( cases != SELF_TEST_CASES )); then
    echo "[${SCRIPT_NAME}] self-test FAILED: ran ${cases} case(s), expected ${SELF_TEST_CASES}" >&2
    failures=$((failures + 1))
  fi
  if (( failures > 0 )); then
    echo "[${SCRIPT_NAME}] self-test FAILED (${failures} case(s))" >&2
    return 1
  fi
  echo "[${SCRIPT_NAME}] self-test passed (${cases} cases)"
  return 0
}

# ---------------------------------------------------------------------------
# Entry
# ---------------------------------------------------------------------------

# Sourced (by check_e2e_lane_budget.sh, for the extraction above): stop here.
if [[ "${BASH_SOURCE[0]}" != "${0}" ]]; then
  return 0
fi

# Every number here is parsed by pattern; C locale keeps `[0-9]` and `.` ASCII.
export LC_ALL=C

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
check_job_caps "${WF_DIR}"
(( C6_JOBS > 0 )) || misconfig "C6 evaluated no job, yet ${emu_steps} emulator/simulator steps exist: the job-cap check has gone blind."

# A shrinking count means the extractor stopped recognising steps — the guard
# would then pass vacuously, which is the failure mode every grep-guard dies of.
#
# This was a HARDCODED floor of 10 steps / 8 drives. That is the wrong shape: it
# was written when the repo had ~11 lanes, and by the time the repo had 35 steps
# and 18 drives the extractor could have lost two thirds of them and still
# passed. A floor that does not move with the repo stops being a floor.
#
# So derive the expectation FROM THE REPO, by a different mechanism than the
# extractor uses. The extractor parses workflow YAML into per-step records and
# classifies them; the check below greps the raw files for the marker strings.
# Two independent readings of the same source: if the record parser rots, the
# grep still sees the lane, and the mismatch names it.
check_extractor_sees_the_repo "${WF_DIR}"

if (( VIOLATIONS > 0 )); then
  fail_msg "${VIOLATIONS} ordering violation(s). The rule is: inner deadline < step timeout-minutes < job timeout-minutes, and each job cap >= its step caps + its declared uncapped minutes."
  exit 1
fi

log "OK — ${emu_steps} emulator/simulator steps (${drive_steps} drives), inner < step < job holds in all of them; ${C6_JOBS} job caps cover their step caps plus the declared uncapped minutes"
exit 0
