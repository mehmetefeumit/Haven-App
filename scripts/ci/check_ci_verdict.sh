#!/usr/bin/env bash
# Release gate: the tagged commit passed ci.yml's deterministic jobs.
#
# release-build.yml used to call rust-check, cross-check, coverage and
# repo-guards again on the tag. That rebuilt cold what ci.yml had already
# proved on the same commit: the tag's cache scope holds nothing, and the
# repository's 10 GB cache is full. On v0.1.13 the redo passed 60 minutes and
# timed out. The push to main has already run every one of those jobs, on the
# same tree, and its repo-guards run also ratchets the privacy manifest
# against the previous tip, which a tag run cannot. So the gate reads that
# verdict instead of re-deriving it.
#
# The verdict comes from the newest ci.yml `push` run on main for the commit,
# read through the Actions API, whose runs only GitHub Actions can create. Every
# job under the four gate workflows must end `success` or `skipped`, where a
# `skipped` job is another `group` call's copy. Each job in REQUIRED_JOBS must
# have at least one `success`. The E2E lanes stay out of the gate, as before:
# their device nondeterminism must never block a release of a green commit.
# While a gate job is still running the gate waits, so a tag may be pushed
# right after main.
#
# REQUIRED_JOBS is pinned, because a job that silently left the list would be
# a deleted check that reports success. The no-argument mode derives the same
# set from the four reusable workflows and ci.yml's callers, and fails when the
# two differ.
#
# A verdict recorded at merge cannot see an advisory published since, so the
# dependency audit is the one check release-build.yml runs afresh: its
# `dependency-audit` job calls audit.yml in `full` mode on every event. The
# no-argument mode also holds that every other release-build.yml job needs
# both `gate` and `dependency-audit`, directly or through the jobs it needs,
# and that none overrides a failed need with always(), failure() or
# cancelled(), so nothing is built, signed, uploaded or published unless both
# passed. "Re-run failed jobs" keeps a passed audit from an earlier attempt, so
# every job that needs `dependency-audit` directly must start with the step
# that fails unless the audit ran in this attempt (a job that needs it only
# through another job needs one that does). A job-level `if:` must be one line, the form this reads;
# the iOS job's must hold it to main and tags; and audit.yml's jobs have none,
# since a skipped job in a called workflow is a success to its caller.
#
# Usage:
#   bash scripts/ci/check_ci_verdict.sh                # pinned list == workflows,
#                                                      # and release-build.yml's needs
#   bash scripts/ci/check_ci_verdict.sh --sha <sha>    # the gate (GH_TOKEN,
#                                                      # GITHUB_REPOSITORY)
#   bash scripts/ci/check_ci_verdict.sh --self-test
#
# Exit codes:
#   0  passed (or the self-test passed)
#   1  a gate job failed, was cancelled, never passed, or never finished; no
#      CI run exists for the commit; the pinned list drifted; or a release job
#      can run without the gate or the fresh audit
#   2  misconfiguration: a bad argument, a missing token, an API that does not
#      answer, or a workflow whose job names cannot be read

set -euo pipefail

REPO_ROOT="${REPO_ROOT_OVERRIDE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
readonly CI_YML_REL='.github/workflows/ci.yml'
readonly GATE_WORKFLOWS=(rust-check.yml cross-check.yml coverage.yml repo-guards.yml)
# <workflow>:<job key> that no good run executes. rust-check's `group` job
# fails a call whose group input is unknown, so it is skipped on every good
# run; the "nothing failed" rule still holds it.
readonly EXEMPT_JOBS=('rust-check.yml:group')
readonly REQUIRED_JOBS=(
  'Coverage / Flutter Coverage'
  'Coverage / Rust Coverage'
  'Cross-Platform Compile / Android (arm64)'
  'Cross-Platform Compile / Apple (macOS + iOS)'
  'Cross-Platform Compile / Windows (x64)'
  'Repo Guards / Static checks'
  'Rust Checks / e2e tooling (hermetic relay + wire proxy)'
  'Rust Checks / haven-core'
  'Rust Checks / haven-core suite (stable)'
  'Rust Checks / logscan tooling (runtime log-privacy scanner)'
  'Rust Checks / rust_builder (FFI surface)'
  'Rust Checks / soak tooling (Tier-1 soak rig)'
)
readonly RELEASE_YML_REL='.github/workflows/release-build.yml'
readonly AUDIT_YML_REL='.github/workflows/audit.yml'
# Every other release-build.yml job must need both of these.
readonly RELEASE_ROOTS=(gate dependency-audit)
# The first step of every job that needs dependency-audit directly: these lines
# exactly, and no other line but FRESH_STEP_ALLOWED's.
readonly FRESH_STEP=(
  'name: Dependency audit ran in this attempt'
  'AUDIT_ATTEMPT: ${{ needs.dependency-audit.outputs.attempt }}'
  'RUN_ATTEMPT: ${{ github.run_attempt }}'
  '[[ "${AUDIT_ATTEMPT}" == "${RUN_ATTEMPT}" ]] || { echo "::error::dependency audit is from attempt ${AUDIT_ATTEMPT}; use Re-run all jobs so the audit is fresh"; exit 1; }'
)
readonly FRESH_STEP_ALLOWED=('env:' 'run: |' 'working-directory: /')
# A dispatch from any other branch must not reach TestFlight.
readonly IOS_IF="\${{ github.ref == 'refs/heads/main' || github.ref_type == 'tag' }}"
POLL_SECS="${CI_VERDICT_POLL_SECS:-60}"
# A tag pushed with main can arrive before GitHub has created main's run.
NO_RUN_GRACE_SECS="${CI_VERDICT_NO_RUN_GRACE_SECS:-300}"
# ci.yml's slowest gate job, cold, has taken 50 minutes.
DEADLINE_SECS="${CI_VERDICT_DEADLINE_SECS:-5400}"
# Consecutive API calls that may fail before the gate gives up: one blip in
# 90 minutes of polling must not fail a release.
readonly API_MISS_LIMIT=3
# How many fixtures the self-test runs. Pinned, because a fixture that stops
# running is the one way a deleted check reports success.
readonly SELF_TEST_FIXTURES=30

log() {
  printf '\033[1;34m[check_ci_verdict]\033[0m %s\n' "$*"
}

fail() { # <rc> <message>
  printf '\033[1;31m[check_ci_verdict] FAIL:\033[0m %s\n' "$2" >&2
  return "$1"
}

# ---------------------------------------------------------------------------
# The pinned list against the workflows.
# ---------------------------------------------------------------------------

# "<reusable file>\t<caller name>" for each job of ci.yml that calls one.
ci_callers() { # <ci.yml>
  awk '
    function emit() { if (uses != "") print uses "\t" name; name = ""; uses = "" }
    /^jobs:/ { j = 1; next }
    j && /^  [A-Za-z0-9_-]+:[[:space:]]*$/ { emit() }
    j && /^    name:/ { v = $0; sub(/^    name:[[:space:]]*/, "", v); gsub(/^["\047]|["\047]$/, "", v); name = v }
    j && /^    uses:/ { v = $0; sub(/^    uses:[[:space:]]*\.\/\.github\/workflows\//, "", v); uses = v }
    END { emit() }
  ' "$1"
}

# "<job key>\t<job name>" for each job of a reusable workflow.
job_names() { # <workflow>
  awk '
    /^jobs:/ { j = 1; next }
    j && /^  [A-Za-z0-9_-]+:[[:space:]]*$/ { key = $1; sub(/:$/, "", key) }
    j && /^    name:/ { v = $0; sub(/^    name:[[:space:]]*/, "", v); gsub(/^["\047]|["\047]$/, "", v); print key "\t" v }
  ' "$1"
}

derived_jobs() { # <repo root>
  local root="$1" wf caller key name callers
  callers="$(ci_callers "${root}/${CI_YML_REL}")"
  for wf in "${GATE_WORKFLOWS[@]}"; do
    [[ -f "${root}/.github/workflows/${wf}" ]] || { echo "ERROR: .github/workflows/${wf} not found" >&2; return 2; }
    caller="$(awk -F'\t' -v w="${wf}" '$1 == w { print $2 }' <<<"${callers}" | sort -u)"
    [[ -n "${caller}" && "${caller}" != *$'\n'* ]] \
      || { echo "ERROR: ${CI_YML_REL} must call ${wf} under exactly one job name (found: ${caller:-none})" >&2; return 2; }
    while IFS=$'\t' read -r key name; do
      [[ -n "${key}" ]] || continue
      [[ " ${EXEMPT_JOBS[*]} " == *" ${wf}:${key} "* ]] && continue
      [[ "${name}" != *'${{'* ]] || { echo "ERROR: ${wf} job ${key} computes its name; the gate cannot pin it" >&2; return 2; }
      printf '%s / %s\n' "${caller}" "${name}"
    done < <(job_names "${root}/.github/workflows/${wf}")
  done
}

check_pinned() { # <repo root>
  local derived pinned
  derived="$(derived_jobs "$1")" || return 2
  [[ -n "${derived}" ]] || { echo "ERROR: derived no gate job from the workflows" >&2; return 2; }
  pinned="$(printf '%s\n' "${REQUIRED_JOBS[@]}")"
  if [[ "$(sort -u <<<"${derived}")" != "$(sort -u <<<"${pinned}")" ]]; then
    diff <(sort -u <<<"${pinned}") <(sort -u <<<"${derived}") | sed -n 's/^</  pinned only:  /p; s/^>/  workflow only:/p' >&2 || true
    fail 1 "REQUIRED_JOBS in scripts/ci/check_ci_verdict.sh no longer matches the jobs ci.yml runs from ${GATE_WORKFLOWS[*]}. Update the list in the same change."
    return
  fi
  log "OK: the release gate requires all $(grep -c . <<<"${pinned}") jobs ci.yml runs from ${GATE_WORKFLOWS[*]}."
}

# ---------------------------------------------------------------------------
# release-build.yml: nothing runs without the gate and the fresh audit.
# ---------------------------------------------------------------------------

# "<job>\t<field>\t<value>" for each release-build.yml job: one `job` row,
# then a `needs` row per need and its `uses`, `with.mode` and `if`, an `ifmulti`
# row when the `if:` runs past its line, and a `step1` row per line of its
# first step.
release_jobs() { # <release-build.yml>
  awk '
    function value(s) { sub(/^[^:]*:[[:space:]]*/, "", s); sub(/[[:space:]]+#.*$/, "", s); gsub(/^["\047]|["\047]$/, "", s); return s }
    function needs(s,   n, i, a) {
      gsub(/[][]/, "", s); n = split(s, a, ",")
      for (i = 1; i <= n; i++) { gsub(/^[[:space:]]+|[[:space:]]+$/, "", a[i]); if (a[i] != "") print job "\tneeds\t" a[i] }
    }
    /^jobs:/ { j = 1; next }
    j && /^[^[:space:]#]/ { j = 0 }
    !j { next }
    ifcont && !/^[[:space:]]*(#.*)?$/ { if (/^     /) print job "\tifmulti\t1"; ifcont = 0 }
    /^  [A-Za-z0-9_-]+:[[:space:]]*$/ { job = $1; sub(/:$/, "", job); print job "\tjob\t"; blk = ""; next }
    /^    [A-Za-z0-9_-]+:/ { blk = "" }
    /^    needs:/ { v = value($0); if (v == "") blk = "needs"; else needs(v); next }
    blk == "needs" && /^      - / { v = $0; sub(/^      - /, "", v); needs(v); next }
    /^    uses:/ { print job "\tuses\t" value($0); next }
    /^    with:[[:space:]]*$/ { blk = "with"; next }
    blk == "with" && /^      mode:/ { print job "\tmode\t" value($0); next }
    /^    if:/ { v = value($0); print job "\tif\t" v; if (v == "" || v ~ /^[>|]/) print job "\tifmulti\t1"; else ifcont = 1; next }
    /^    steps:[[:space:]]*$/ { blk = "steps"; step = 0; next }
    blk == "steps" && /^      - / { step++ }
    blk == "steps" && step == 1 && !/^[[:space:]]*(#.*)?$/ { v = $0; sub(/^[[:space:]]+/, "", v); sub(/^- /, "", v); print job "\tstep1\t" v }
  ' "$1"
}

# The job keys of a workflow with a job-level `if:`.
jobs_with_if() { # <workflow>
  awk '
    /^jobs:/ { j = 1; next }
    j && /^[^[:space:]#]/ { j = 0 }
    j && /^  [A-Za-z0-9_-]+:[[:space:]]*$/ { job = $1; sub(/:$/, "", job) }
    j && /^    if:/ { print job }
  ' "$1"
}

# Whether <job>'s first step is exactly the freshness check.
fresh_first_step() { # <job> <release_jobs rows>
  local lines line l
  lines="$(awk -F'\t' -v j="$1" '$1 == j && $2 == "step1" { print $3 }' <<<"$2")"
  for l in "${FRESH_STEP[@]}"; do grep -qxF -- "${l}" <<<"${lines}" || return 1; done
  while IFS= read -r line; do
    [[ -n "${line}" ]] || continue
    printf '%s\n' "${FRESH_STEP[@]}" "${FRESH_STEP_ALLOWED[@]}" | grep -qxF -- "${line}" || return 1
  done <<<"${lines}"
}

check_release_needs() { # <repo root>
  local yml="$1/${RELEASE_YML_REL}" rows job field value root next queue bad='' n
  local -A needs=() seen=() fresh=()
  local -a jobs=()
  [[ -f "${yml}" ]] || { echo "ERROR: ${RELEASE_YML_REL} not found" >&2; return 2; }
  [[ -f "$1/${AUDIT_YML_REL}" ]] || { echo "ERROR: ${AUDIT_YML_REL} not found" >&2; return 2; }
  rows="$(release_jobs "${yml}")"
  _field() { awk -F'\t' -v j="$1" -v f="$2" '$1 == j && $2 == f { print $3 }' <<<"${rows}"; }
  while IFS=$'\t' read -r job field value; do
    case "${field}" in
      job) jobs+=("${job}"); needs[${job}]='' ;;
      needs) needs[${job}]+=" ${value}" ;;
    esac
  done <<<"${rows}"
  for root in "${RELEASE_ROOTS[@]}"; do
    [[ -v "needs[${root}]" ]] || bad+="  ${RELEASE_YML_REL} has no ${root} job"$'\n'
  done
  [[ "$(_field dependency-audit uses)" == './.github/workflows/audit.yml' ]] \
    || bad+="  dependency-audit does not call ./.github/workflows/audit.yml"$'\n'
  [[ "$(_field dependency-audit mode)" == full ]] \
    || bad+="  dependency-audit does not run audit.yml with mode: full"$'\n'
  while read -r n; do
    [[ -z "${n}" ]] || bad+="  ${AUDIT_YML_REL} job ${n} has an if:, and a skipped called job is a success to its caller"$'\n'
  done <<<"$(jobs_with_if "$1/${AUDIT_YML_REL}")"
  [[ "$(_field ios if)" == "${IOS_IF}" ]] \
    || bad+="  ios does not run only on main and tags (if: ${IOS_IF})"$'\n'
  for job in "${jobs[@]}"; do
    [[ " ${needs[${job}]} " != *' dependency-audit '* ]] || ! fresh_first_step "${job}" "${rows}" || fresh[${job}]=1
  done
  for job in "${jobs[@]}"; do
    [[ -z "$(_field "${job}" ifmulti)" ]] \
      || bad+="  ${job}'s if: runs past its line; write it on one line"$'\n'
    [[ " ${RELEASE_ROOTS[*]} " == *" ${job} "* ]] && continue
    [[ "$(_field "${job}" if)" =~ (always|failure|cancelled)\( ]] \
      && bad+="  ${job} overrides its needs with a status function in its if:"$'\n'
    if [[ " ${needs[${job}]} " == *' dependency-audit '* && -z "${fresh[${job}]:-}" ]]; then
      bad+="  ${job} needs dependency-audit but does not start with the step that fails on an audit from an earlier attempt"$'\n'
    fi
    seen=(); queue="${needs[${job}]}"
    while read -r next queue <<<"${queue}" && [[ -n "${next}" ]]; do
      [[ -v "seen[${next}]" ]] && continue
      seen[${next}]=1
      queue+=" ${needs[${next}]:-}"
    done
    for root in "${RELEASE_ROOTS[@]}"; do
      [[ -v "seen[${root}]" ]] || bad+="  ${job} does not need ${root}, directly or through another job"$'\n'
    done
  done
  if [[ -n "${bad}" ]]; then
    printf '%s' "${bad}" >&2
    fail 1 "every ${RELEASE_YML_REL} job must need gate and dependency-audit (audit.yml, mode: full, from this attempt), so nothing is built, signed, uploaded or published unless both passed on this run."
    return
  fi
  log "OK: all $(( ${#jobs[@]} - ${#RELEASE_ROOTS[@]} )) other ${RELEASE_YML_REL} jobs need gate and a full dependency audit from this attempt."
}

# ---------------------------------------------------------------------------
# The gate.
# ---------------------------------------------------------------------------

# "<run id>\t<html url>\t<status>" of the newest ci.yml push run on main, or
# nothing.
fetch_run() { # <sha>
  gh api "repos/${GITHUB_REPOSITORY}/actions/workflows/ci.yml/runs?head_sha=$1&event=push&branch=main&per_page=1" \
    --jq '.workflow_runs[0] // empty | [.id, .html_url, .status] | @tsv'
}

# "<name>\t<status>\t<conclusion>" for each job of the run's latest attempt.
fetch_jobs() { # <run id>
  gh api --paginate "repos/${GITHUB_REPOSITORY}/actions/runs/$1/jobs?filter=latest&per_page=100" \
    --jq '.jobs[] | [.name, .status, (.conclusion // "")] | @tsv'
}

# 0 passed, 1 failed, 3 still running. Reads fetch_jobs lines on stdin.
judge() { # <run status>
  local run_status="$1" jobs prefixes bad pending missing req gate_jobs
  jobs="$(cat)"
  prefixes="$(printf '%s\n' "${REQUIRED_JOBS[@]}" | sed 's| / .*| / |' | sort -u)"
  gate_jobs="$(awk -F'\t' 'NR == FNR { p[$0] = 1; next } $1 != "" { for (x in p) if (index($1, x) == 1) { print; next } }' \
    <(printf '%s\n' "${prefixes}") <(printf '%s\n' "${jobs}"))"
  bad="$(awk -F'\t' '$2 == "completed" && $3 != "success" && $3 != "skipped" { print "  " $1 ": " $3 }' <<<"${gate_jobs}")"
  if [[ -n "${bad}" ]]; then
    printf '%s\n' "${bad}" >&2
    return 1
  fi
  pending="$(awk -F'\t' 'NF && $2 != "completed" { print "  " $1 ": " $2 }' <<<"${gate_jobs}")"
  if [[ -n "${pending}" ]]; then
    printf '%s\n' "${pending}"
    return 3
  fi
  missing=''
  for req in "${REQUIRED_JOBS[@]}"; do
    awk -F'\t' -v n="${req}" '$1 == n && $3 == "success" { f = 1 } END { exit !f }' <<<"${gate_jobs}" \
      || missing+="  ${req}: never passed"$'\n'
  done
  if [[ -n "${missing}" ]]; then
    # A run just created lists its jobs a moment later.
    [[ "${run_status}" == completed ]] || return 3
    printf '%s' "${missing}" >&2
    return 1
  fi
}

gate() { # <sha>
  local sha="$1" run id url run_status jobs rc misses=0 started="${SECONDS}"
  [[ "${sha}" =~ ^[0-9a-f]{40}$ ]] || { echo "ERROR: --sha needs a full commit SHA" >&2; return 2; }
  while :; do
    if ! run="$(fetch_run "${sha}")" || { [[ -n "${run}" ]] && { IFS=$'\t' read -r id url run_status <<<"${run}"; ! jobs="$(fetch_jobs "${id}")"; }; }; then
      misses=$(( misses + 1 ))
      (( misses < API_MISS_LIMIT )) || { echo "ERROR: the Actions API did not answer ${API_MISS_LIMIT} times in a row" >&2; return 2; }
      log "the Actions API did not answer; asking again"
      sleep "${POLL_SECS}"
      continue
    fi
    misses=0
    if [[ -n "${run}" ]]; then
      rc=0
      judge "${run_status}" <<<"${jobs}" || rc=$?
      case "${rc}" in
        0) log "OK: all ${#REQUIRED_JOBS[@]} gate jobs passed in ${url}."; return 0 ;;
        1) fail 1 "ci.yml did not pass its gate jobs on this commit (${url}). Fix it and tag the fixed commit, or, for a job a later push to main cancelled or a flaky one, run 'gh run rerun ${id} --failed' (which cancels any ci.yml run then in progress on main) and, once it passes, re-run this release with Re-run all jobs (re-running only the failed jobs keeps the old dependency audit, which the release then refuses)."; return ;;
      esac
      (( SECONDS - started < DEADLINE_SECS )) \
        || { fail 1 "ci.yml's gate jobs had not finished after ${DEADLINE_SECS} s (${url}). Once they pass, re-run this release with Re-run all jobs."; return; }
      log "waiting for ci.yml's gate jobs in ${url}"
    else
      (( SECONDS - started < NO_RUN_GRACE_SECS )) \
        || { fail 1 "no ci.yml push run on main exists for ${sha}. A release tag must point at a commit pushed to main."; return; }
      log "no ci.yml run on main for this commit yet; waiting"
    fi
    sleep "${POLL_SECS}"
  done
}

# ---------------------------------------------------------------------------
# Self-test: the gate over stubbed API answers, and the pinned-list check over
# planted workflows. No network.
# ---------------------------------------------------------------------------
self_test() {
  local tmp fails=0 checked=0
  tmp="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf '${tmp}'" RETURN
  local sha; sha="$(printf 'a%.0s' {1..40})"

  # A run's jobs as the API lists them for run 42083193168 (v0.1.13's commit):
  # each rust-check job three times, two of them another group's skipped copy.
  _green() {
    local j
    for j in "${REQUIRED_JOBS[@]}"; do
      printf '%s\tcompleted\tsuccess\n' "${j}"
      [[ "${j}" == 'Rust Checks / '* ]] && printf '%s\tcompleted\tskipped\n%s\tcompleted\tskipped\n' "${j}" "${j}"
    done
    printf 'Rust Checks / group input is known\tcompleted\tskipped\n%.0s' 1 2 3
    printf 'Flutter Checks / flutter analyze\tcompleted\tsuccess\n'
    printf 'E2E Core Flow (iOS) / e2e_ios\tcompleted\tfailure\n'
  }
  _green >"${tmp}/green.tsv"

  _case() { # _case <label> <want-rc> <command>...
    local label="$1" want="$2" got=0; shift 2
    checked=$(( checked + 1 ))
    ( "$@" ) >"${tmp}/out" 2>&1 || got=$?
    if [[ "${got}" -eq "${want}" ]]; then
      printf '  \033[1;32mPASS\033[0m %s\n' "${label}"
    else
      printf '  \033[1;31mFAIL\033[0m %s (want rc=%d, got rc=%d)\n' "${label}" "${want}" "${got}" >&2
      sed 's/^/      /' "${tmp}/out" >&2
      fails=1
    fi
  }
  # Each fixture stubs the API: the jobs file answers fetch_jobs (a file per
  # poll when JOBS_SEQ is set), NO_RUN makes fetch_run answer nothing,
  # RUN_STATUS is the run's own status and API_FAILS fails that many calls.
  _gate() { # <jobs file or sequence prefix>
    JOBS="$1"
    fetch_run() { [[ -n "${NO_RUN:-}" ]] || printf '7\thttps://example.invalid/run/7\t%s\n' "${RUN_STATUS:-completed}"; }
    fetch_jobs() {
      # fetch_jobs runs in a command substitution, so counts live in files.
      local f; f=$(( $(cat "${JOBS}.fails" 2>/dev/null || echo 0) + 1 )); echo "${f}" >"${JOBS}.fails"
      (( f > ${API_FAILS:-0} )) || return 1
      if [[ -n "${JOBS_SEQ:-}" ]]; then
        local n; n=$(( $(cat "${JOBS}.polls" 2>/dev/null || echo 0) + 1 )); echo "${n}" >"${JOBS}.polls"
        cat "${JOBS}.${n}" 2>/dev/null || cat "${JOBS}.last"
      else
        cat "${JOBS}"
      fi
    }
    sleep() { :; }
    POLL_SECS=0 NO_RUN_GRACE_SECS="${GRACE:-0}" DEADLINE_SECS="${DEADLINE:-0}" gate "${sha}"
  }
  _edit() { # <out> <sed expression>
    sed -E "$2" "${tmp}/green.tsv" >"${tmp}/$1"
  }

  echo "check_ci_verdict.sh --self-test"
  _case "a run whose gate jobs all passed passes, whatever the E2E lanes did" 0 _gate "${tmp}/green.tsv"

  _edit failed.tsv 's#^(Rust Checks / soak tooling \(Tier-1 soak rig\)\tcompleted\t)success#\1failure#'
  _case "a failed gate job fails" 1 _gate "${tmp}/failed.tsv"

  _edit cancelled.tsv 's#^(Coverage / Rust Coverage\tcompleted\t)success#\1cancelled#'
  _case "a cancelled gate job fails" 1 _gate "${tmp}/cancelled.tsv"

  _edit skipped.tsv 's#^(Repo Guards / Static checks\tcompleted\t)success#\1skipped#'
  _case "a required job that only skipped fails" 1 _gate "${tmp}/skipped.tsv"

  { cat "${tmp}/green.tsv"; printf 'Rust Checks / a job added later\tcompleted\tfailure\n'; } >"${tmp}/unlisted.tsv"
  _case "a failed job under a gate workflow fails even when the list does not name it" 1 _gate "${tmp}/unlisted.tsv"

  _edit guard.tsv '0,/^Rust Checks \/ group input is known\tcompleted\tskipped/s##Rust Checks / group input is known\tcompleted\tfailure#'
  _case "an unknown group input fails, though its job is exempt from the list" 1 _gate "${tmp}/guard.tsv"

  grep -v '^Cross-Platform Compile / Windows (x64)' "${tmp}/green.tsv" >"${tmp}/absent.tsv"
  _case "a required job absent from the run fails" 1 _gate "${tmp}/absent.tsv"

  _edit "seq.1" 's#^(Coverage / Rust Coverage\t)completed\tsuccess#\1in_progress\t#'
  cp "${tmp}/green.tsv" "${tmp}/seq.last"
  _seq() { JOBS_SEQ=1 DEADLINE=60 _gate "$1"; }
  _case "a gate job still running is waited for, then judged" 0 _seq "${tmp}/seq"

  _case "a gate job that never finishes fails at the deadline" 1 _gate "${tmp}/seq.1"

  _no_run() { NO_RUN=1 _gate "$1"; }
  _case "no CI run for the commit fails once the grace is spent" 1 _no_run "${tmp}/green.tsv"

  : >"${tmp}/bare.1"; cp "${tmp}/green.tsv" "${tmp}/bare.last"
  _bare_running() { JOBS_SEQ=1 RUN_STATUS=in_progress DEADLINE=60 _gate "$1"; }
  _case "a run that lists no job yet is waited for" 0 _bare_running "${tmp}/bare"
  rm -f "${tmp}/bare.polls" "${tmp}/bare.fails"
  _bare_done() { JOBS_SEQ=1 DEADLINE=60 _gate "$1"; }
  _case "a finished run that lists no gate job fails at once" 1 _bare_done "${tmp}/bare"

  _blip() { API_FAILS=$(( API_MISS_LIMIT - 1 )) _gate "$1"; }
  _case "API calls that fail fewer times in a row than the limit are asked again" 0 _blip "${tmp}/green.tsv"
  rm -f "${tmp}/green.tsv.fails"
  _down() { API_FAILS=${API_MISS_LIMIT} _gate "$1"; }
  _case "an API that keeps failing is a misconfiguration" 2 _down "${tmp}/green.tsv"
  rm -f "${tmp}/green.tsv.fails"

  # The queries themselves, through a stubbed gh: this commit's push runs on
  # main, and every page of the latest attempt's jobs.
  _queries() { # <fetch function> <argument> <expected gh argv>
    gh() { printf '%s\n' "$*" >"${tmp}/gh.argv"; }
    GITHUB_REPOSITORY=o/r "$1" "$2"
    [[ "$(cat "${tmp}/gh.argv")" == "$3" ]] || { printf 'gh was called with: %s\n' "$(cat "${tmp}/gh.argv")"; return 1; }
  }
  _case "fetch_run asks for the newest ci.yml push run on main for this commit" 0 _queries fetch_run "${sha}" \
    "api repos/o/r/actions/workflows/ci.yml/runs?head_sha=${sha}&event=push&branch=main&per_page=1 --jq .workflow_runs[0] // empty | [.id, .html_url, .status] | @tsv"
  _case "fetch_jobs reads every page of the run's latest attempt" 0 _queries fetch_jobs 7 \
    "api --paginate repos/o/r/actions/runs/7/jobs?filter=latest&per_page=100 --jq .jobs[] | [.name, .status, (.conclusion // \"\")] | @tsv"

  # The pinned list against planted workflows.
  _repo() { # <dir>
    mkdir -p "$1/.github/workflows"
    cp "${REPO_ROOT}/${CI_YML_REL}" "$1/${CI_YML_REL}"
    for wf in "${GATE_WORKFLOWS[@]}"; do cp "${REPO_ROOT}/.github/workflows/${wf}" "$1/.github/workflows/${wf}"; done
  }
  _repo "${tmp}/added"
  printf '\n  late-job:\n    name: a job added later\n    runs-on: ubuntu-latest\n    steps:\n      - run: true\n' \
    >>"${tmp}/added/.github/workflows/rust-check.yml"
  _case "a job added to a gate workflow and not to the list fails" 1 check_pinned "${tmp}/added"

  _repo "${tmp}/renamed"
  sed -i 's/^    name: Coverage$/    name: Coverage Gate/' "${tmp}/renamed/${CI_YML_REL}"
  _case "a renamed ci.yml caller fails" 1 check_pinned "${tmp}/renamed"

  # release-build.yml's needs, over the real file and planted edits of it.
  _release() { # <dir>
    mkdir -p "$1/.github/workflows"
    cp "${REPO_ROOT}/${RELEASE_YML_REL}" "$1/${RELEASE_YML_REL}"
    cp "${REPO_ROOT}/${AUDIT_YML_REL}" "$1/${AUDIT_YML_REL}"
  }
  _release "${tmp}/rel-ok"
  _case "release-build.yml: every job needs the gate and the fresh full audit" 0 check_release_needs "${tmp}/rel-ok"

  _release "${tmp}/rel-dropped"
  sed -Ei '/^  ios:/,/^  [a-z]/ s/^    needs: \[gate, dependency-audit\]$/    needs: [gate]/' "${tmp}/rel-dropped/${RELEASE_YML_REL}"
  _case "a release job (TestFlight's) that drops dependency-audit fails" 1 check_release_needs "${tmp}/rel-dropped"

  _release "${tmp}/rel-transitive"
  printf '\n  notes:\n    needs: android-sign\n    runs-on: ubuntu-latest\n    steps:\n      - run: true\n' \
    >>"${tmp}/rel-transitive/${RELEASE_YML_REL}"
  _case "a job that needs both only through another job passes" 0 check_release_needs "${tmp}/rel-transitive"

  _release "${tmp}/rel-always"
  printf '\n  late:\n    needs: [gate, dependency-audit]\n    if: ${{ always() }}\n    runs-on: ubuntu-latest\n    steps:\n      - run: true\n' \
    >>"${tmp}/rel-always/${RELEASE_YML_REL}"
  _case "a job whose if: runs it after a failed need fails" 1 check_release_needs "${tmp}/rel-always"

  _release "${tmp}/rel-pr"
  sed -i 's/^      mode: full$/      mode: pr/' "${tmp}/rel-pr/${RELEASE_YML_REL}"
  _case "a dependency-audit in pr mode fails" 1 check_release_needs "${tmp}/rel-pr"

  _release "${tmp}/rel-other"
  sed -i 's#^    uses: \./\.github/workflows/audit\.yml$#    uses: ./.github/workflows/rust-check.yml#' "${tmp}/rel-other/${RELEASE_YML_REL}"
  _case "a dependency-audit that calls another workflow fails" 1 check_release_needs "${tmp}/rel-other"

  # The freshness step, removed from TestFlight's job, then skipped by an if:.
  _release "${tmp}/rel-stale"
  sed -i '/^  ios:/,/^  [a-z]/ { /^      - name: Dependency audit ran in this attempt$/ s/name: Dependency audit ran in this attempt/name: Some other first step/ }' \
    "${tmp}/rel-stale/${RELEASE_YML_REL}"
  _case "a job that needs dependency-audit and does not check its attempt fails" 1 check_release_needs "${tmp}/rel-stale"

  _release "${tmp}/rel-stale-if"
  sed -i '/^  android-publish:/,/^  [a-z]/ { /^      - name: Dependency audit ran in this attempt$/ a\        if: false
  }' "${tmp}/rel-stale-if/${RELEASE_YML_REL}"
  _case "an attempt check that an if: can skip fails" 1 check_release_needs "${tmp}/rel-stale-if"

  _release "${tmp}/rel-block"
  sed -i '/^  zapstore:/,/^  [a-z]/ s/^    if: .*$/    if: >-\n      always()/' "${tmp}/rel-block/${RELEASE_YML_REL}"
  _case "a release job if: written as a block scalar fails" 1 check_release_needs "${tmp}/rel-block"

  _release "${tmp}/rel-folded"
  sed -i '/^  zapstore:/,/^  [a-z]/ s/^    if: .*$/    if: github.ref_type == '"'tag'"' ||\n      always()/' "${tmp}/rel-folded/${RELEASE_YML_REL}"
  _case "a release job if: that runs onto a second line fails" 1 check_release_needs "${tmp}/rel-folded"

  _release "${tmp}/rel-ios-any"
  sed -i '/^  ios:/,/^  [a-z]/ { /^    if: /d }' "${tmp}/rel-ios-any/${RELEASE_YML_REL}"
  _case "an iOS job that any branch's dispatch reaches fails" 1 check_release_needs "${tmp}/rel-ios-any"

  _release "${tmp}/rel-audit-if"
  sed -i 's/^    runs-on: ubuntu-latest$/    if: inputs.mode == '"'pr'"'\n&/' "${tmp}/rel-audit-if/${AUDIT_YML_REL}"
  _case "an audit.yml job with an if: fails" 1 check_release_needs "${tmp}/rel-audit-if"

  if (( checked != SELF_TEST_FIXTURES )); then
    printf '  \033[1;31mFAIL\033[0m ran %d fixtures, expected %d\n' "${checked}" "${SELF_TEST_FIXTURES}" >&2
    fails=1
  fi
  (( fails == 0 )) || { echo "check_ci_verdict.sh --self-test: FAILED" >&2; return 1; }
  log "OK: self-test passed — each way a gate job can fail, skip, go missing or never finish, a missing or bare run, an API blip and outage, both queries, each way the pinned list can drift, and each way a release job can run without the gate or an audit from this attempt."
}

case "${1:-}" in
  '')
    rc=0
    check_pinned "${REPO_ROOT}" || rc=$?
    r=0
    check_release_needs "${REPO_ROOT}" || r=$?
    if (( r > rc )); then rc=${r}; fi
    exit "${rc}" ;;
  --self-test) self_test ;;
  --sha)
    [[ -n "${2:-}" ]] || { echo "ERROR: --sha needs a commit" >&2; exit 2; }
    [[ -n "${GH_TOKEN:-}" && -n "${GITHUB_REPOSITORY:-}" ]] || { echo "ERROR: the gate needs GH_TOKEN and GITHUB_REPOSITORY" >&2; exit 2; }
    gate "$2" ;;
  *) echo "ERROR: unknown argument '$1' (expected none, --sha <sha> or --self-test)" >&2; exit 2 ;;
esac
