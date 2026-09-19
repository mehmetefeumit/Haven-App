#!/usr/bin/env bash
#
# CI guard: the soak rig is REACHED BY A LANE, and the lane's numbers agree
# with the rig's own.
#
# ## Why this exists
#
# `check_soak_test_only.sh` is the negative half of the rig's boundary — it
# proves the rig cannot reach a shipped build. This is the positive half, and
# it answers the other question: does anything run it?
#
# That question has a recorded history in this repository.
# `docs/CI_HARDENING_BACKLOG.md` catalogues, under "the recurring failure
# mode", eleven instruments that were written, reviewed, green on their own
# `--self-test`, and executed nowhere. A soak rig is the most expensive
# possible instance of that shape: several thousand lines whose whole claim is
# "the invariants hold under a nemesis", proved by nothing but its own
# fixtures.
#
# ## The chain, and why each link is load-bearing
#
#   L1  ci.yml CALLS IT, with the `pr` profile, gated on `rust` only. A
#       reusable workflow nothing calls runs on no commit.
#
#   L2  THE JOB NAME IS COUNTED. e2e-flakiness.yml selects lane jobs by a regex
#       over the job display name. A soak job named outside it is invisible to
#       every flakiness report, so a lane that starts failing intermittently
#       would never appear in the one place that looks for exactly that. The
#       regex is read FROM e2e-flakiness.yml rather than restated here, so the
#       two cannot drift.
#
#   L3  THE ARTIFACT IS SELF-TESTED. rust-check.yml runs the shipped binary's
#       `--self-test`. `cargo test` proves the code; the self-test proves the
#       artifact the lane launches, which is a different build with a different
#       profile.
#
#   L4  THE SCAN STANDS BETWEEN THE RUN AND THE UPLOAD. Every soak job drives
#       through `run-soak-core.sh` under `run-with-deadline.sh`, and its
#       upload-artifact step comes after that drive. The runner is what gates:
#       it sources logscan-gate.sh and calls `logscan_gate`, so every capture
#       passes the key-material floor and the identifier scanner before the
#       workflow can publish any of it. A lane that uploaded first would
#       publish the leak its own scan was about to find.
#
#   L7  THE SCAN ALSO STANDS OUTSIDE THE DRIVE. L4 is not enough on its own,
#       and the reason is the reaper: `run-with-deadline.sh` bounds the drive
#       with `timeout`, which signals the whole PROCESS GROUP, so an
#       overrunning run dies between the rig and the scan INSIDE the runner —
#       while the upload step, gated on the job not being cancelled, publishes
#       the tree anyway. So every soak job also carries a scan step of its own,
#       before the upload, whose condition cannot be switched off by the very
#       outcome it exists for: it runs on `!cancelled()` (or `always()`) and
#       names no `steps.<the drive>.` outcome. A scan keyed on the drive's
#       success is skipped in exactly the case it was written for.
#
#   L5  THE PROFILES NEST. `pr` ⊆ `nightly` ⊆ `weekly` in the checked-in
#       profile TOMLs. A scenario that is in `pr` but not in `nightly` means
#       the nightly run proves LESS than the per-commit one, which is never
#       what anybody intends — and it is invisible in a diff that touches two
#       files. Also: no `tooling/e2e/expected_drive_skips.txt` row may name a
#       soak path; that file describes Dart drive hatches and a soak row there
#       would be an exemption nobody can act on.
#
#   L6  THE TOML AND THE WORKFLOW AGREE ON THE DEADLINE. The profile declares
#       an inner deadline and the workflow spells one as a literal. They are
#       two files, edited by two owners, and the failure when they disagree is
#       the quietest kind: a run reaped before the rig can finalise, reported
#       as an anonymous timeout. This tie belongs to a guard rather than to a
#       crate test — a Rust test parsing a workflow would split the workflow's
#       ownership.
#
# ## Absent crate
#
# L5 and L6 read `tooling/soak/profiles/`. While that directory is not in the
# tree they print that they are inert and return 0; L1–L4 and L7 are about the
# workflows and run regardless. The moment the profiles land, both enforce.
#
# The TOML may declare its deadline either way — `deadline = "6m"` or
# `deadline_secs = 360` — and both are compared in seconds, so the rig's own
# spelling is not this guard's to dictate.
#
# Pure grep/awk, no toolchain — belongs in repo-guards.yml.
#
# Usage:
#   bash scripts/ci/check_soak_lane_reachable.sh
#   bash scripts/ci/check_soak_lane_reachable.sh --self-test
#
# Exit codes:
#   0  the chain holds
#   1  a link is broken
#   2  the guard cannot see what it checks (missing workflow, unreadable regex,
#      self-test failure)

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
readonly REPO_ROOT
readonly SELF_NAME='check_soak_lane_reachable'

readonly CI_YML='.github/workflows/ci.yml'
readonly LANE_YML='.github/workflows/soak-core.yml'
readonly RUST_YML='.github/workflows/rust-check.yml'
readonly FLAKINESS_YML='.github/workflows/e2e-flakiness.yml'
readonly RUNNER_SH='tooling/e2e/ci/run-soak-core.sh'
readonly GATE_SH='tooling/e2e/ci/logscan-gate.sh'
readonly PROFILE_DIR='tooling/soak/profiles'
readonly DRIVE_SKIPS='tooling/e2e/expected_drive_skips.txt'
# Equality pin: a fixture added or removed without moving this line is a
# self-test that no longer says what it runs.
readonly SELF_TEST_FIXTURES=32

FAILED=0
BROKEN=0
fail()   { printf 'FAIL: %s\n' "$*" >&2; FAILED=1; }
broken() { printf 'BROKEN: %s\n' "$*" >&2; BROKEN=1; }
log()    { printf '[%s] %s\n' "${SELF_NAME}" "$*"; }

# Full-line comments dropped: a commented-out `uses:` is not a call, and a
# comment naming a step is not that step.
uncommented() { grep -vE '^[[:space:]]*#' "$1"; }

# `<job-id>\t<first-line>\t<last-line>` for every job in a workflow.
lane_jobs() { # lane_jobs <workflow>
  awk '
    /^[^[:space:]]/ { injobs = ($0 ~ /^jobs:[[:space:]]*$/); if (job != "") { print job "\t" start "\t" NR - 1; job = "" } next }
    !injobs { next }
    /^  [A-Za-z0-9_.-]+:[[:space:]]*$/ {
      if (job != "") print job "\t" start "\t" NR - 1
      job = $0; sub(/^  /, "", job); sub(/:[[:space:]]*$/, "", job)
      start = NR
      next
    }
    END { if (job != "") print job "\t" start "\t" NR }
  ' "$1"
}

# L1 — ci.yml calls the lane with the pr profile, gated on rust only.
check_ci_calls_the_lane() {
  local root="$1" f="${root}/${CI_YML}" body
  [[ -f "${f}" ]] || { broken "${CI_YML} not found."; return 2; }
  body="$(uncommented "${f}")"
  if ! grep -qF -- 'uses: ./.github/workflows/soak-core.yml' <<<"${body}"; then
    fail "${CI_YML} does not call ${LANE_YML}. A reusable workflow nothing calls runs on no commit; the whole rig would be green from its own fixtures and executed nowhere."
    return 1
  fi
  # The three lines that follow the call: `with:` then `profile: pr`.
  local ctx
  ctx="$(grep -A4 -F -- 'uses: ./.github/workflows/soak-core.yml' <<<"${body}")"
  if ! grep -qE '^[[:space:]]*profile:[[:space:]]*pr[[:space:]]*$' <<<"${ctx}"; then
    fail "${CI_YML} calls ${LANE_YML} without \`profile: pr\`. Every job in that workflow is gated on its profile input, so a call without one runs nothing at all — a green lane that executed no scenario."
    return 1
  fi
  local pre
  pre="$(grep -B4 -F -- 'uses: ./.github/workflows/soak-core.yml' <<<"${body}")"
  if ! grep -qE '^[[:space:]]*needs:[[:space:]]*\[rust\][[:space:]]*$' <<<"${pre}"; then
    fail "${CI_YML}: the soak call is not \`needs: [rust]\`. Stage 4 gates on rust alone (E2E is a functional signal, not a coverage one), and the soak's cache is written by rust-check.yml's soak-tooling job — a different gate would either start the lane cold or serialise it behind coverage."
    return 1
  fi
  return 0
}

# The regex e2e-flakiness.yml selects lane jobs with, read from that file.
flakiness_job_re() { # flakiness_job_re <root>
  local f="$1/${FLAKINESS_YML}"
  [[ -f "${f}" ]] || return 1
  uncommented "${f}" | grep -oE 'test\("[^"]+"\)' | head -1 | sed -e 's/^test("//' -e 's/")$//'
}

# L2 — the lane's job names are counted by the flakiness report.
check_job_names_are_counted() {
  local root="$1" re job rc=0 n=0
  re="$(flakiness_job_re "${root}")"
  if [[ -z "${re}" ]]; then
    broken "could not read the lane-job regex out of ${FLAKINESS_YML}. This guard derives the naming rule from that file rather than restating it; with nothing extracted, every name below would pass."
    return 2
  fi
  local f="${root}/${LANE_YML}"
  [[ -f "${f}" ]] || { broken "${LANE_YML} not found."; return 2; }
  while IFS=$'\t' read -r job _ _; do
    [[ -n "${job}" ]] || continue
    n=$(( n + 1 ))
    if ! grep -qE -- "${re}" <<<"${job}"; then
      fail "${LANE_YML}: job \`${job}\` does not match the lane-job pattern ${FLAKINESS_YML} counts (${re}). A lane outside it is invisible to every flakiness report, which is the one place an intermittently failing lane would otherwise surface."
      rc=1
    fi
  done < <(lane_jobs "${f}")
  if (( n == 0 )); then
    broken "${LANE_YML} declares no job this guard can read — the job extractor has rotted, so every check over it is vacuous."
    return 2
  fi
  log "L2: ${n} soak job(s) all match ${FLAKINESS_YML}'s pattern."
  return "${rc}"
}

# L3 — the shipped artifact is self-tested where the crate is built.
check_self_test_runs() {
  local root="$1" f="${root}/${RUST_YML}" body
  [[ -f "${f}" ]] || { broken "${RUST_YML} not found."; return 2; }
  # Materialised, never piped into `grep -q`: `-q` exits on the first match and
  # SIGPIPEs whatever is still writing, and `pipefail` then reports 141 for a
  # pipeline that MATCHED. Under a parallel guard runner that reads as "the
  # self-test is gone" on a tree where it is right there.
  body="$(uncommented "${f}" || true)"
  if ! grep -qE 'haven-soak --[[:space:]]*(\\)?$|haven-soak -- --self-test|--bin haven-soak -- --self-test' <<<"${body}"; then
    fail "${RUST_YML} never runs the rig's --self-test. \`cargo test\` proves the code; the self-test proves the ARTIFACT the lane launches, which is a different profile with different cfgs — the ws:// loopback opt-in among them."
    return 1
  fi
  return 0
}

# L4 — drive through the gated runner, then upload. Per job.
check_scan_precedes_upload() {
  local root="$1" f="${root}/${LANE_YML}" rc=0 job first last body drive driving upload n=0
  [[ -f "${f}" ]] || { broken "${LANE_YML} not found."; return 2; }
  # The runner is what gates; if it stopped, no ordering in the workflow helps.
  local runner="${root}/${RUNNER_SH}"
  if [[ ! -f "${runner}" ]]; then
    broken "${RUNNER_SH} not found — the lane drives through it and it is what runs the log-privacy gate."
    return 2
  fi
  grep -qE '^[[:space:]]*(source|[.])[[:space:]].*logscan-gate[.]sh' "${runner}" \
    || { fail "${RUNNER_SH} no longer sources ${GATE_SH}. Without the gate the lane uploads captures no scanner has read."; rc=1; }
  grep -qE '^[[:space:]]*(if[[:space:]]+)?logscan_gate([[:space:]]|$)' "${runner}" \
    || { fail "${RUNNER_SH} sources the gate but never calls logscan_gate at a command position. A sourced gate nobody calls scans nothing."; rc=1; }

  while IFS=$'\t' read -r job first last; do
    [[ -n "${job}" ]] || continue
    n=$(( n + 1 ))
    body="$(sed -n "${first},${last}p" "${f}" | grep -vE '^[[:space:]]*#')"
    drive="$(grep -nF -- "${RUNNER_SH}" <<<"${body}" | cut -d: -f1 | head -1)"
    upload="$(grep -nE 'uses:[[:space:]]*actions/upload-artifact' <<<"${body}" | cut -d: -f1 | head -1)"
    if [[ -z "${drive}" ]]; then
      fail "${LANE_YML}:${job} never runs ${RUNNER_SH}. A soak job that does not drive the rig is a job that proves nothing."
      rc=1
      continue
    fi
    # Materialised for the reason L3's own read gives: a `grep -q` at the end
    # of a pipeline turns a MATCH into a 141 under `pipefail`.
    driving="$(grep -F -- "${RUNNER_SH}" <<<"${body}" || true)"
    if ! grep -qF -- 'run-with-deadline.sh' <<<"${driving}"; then
      fail "${LANE_YML}:${job} drives the rig without run-with-deadline.sh. A hang then burns to the step cap and reports an anonymous 124 with no artifacts."
      rc=1
    fi
    if [[ -z "${upload}" ]]; then
      fail "${LANE_YML}:${job} uploads nothing. The evidence tree is the run's whole record; a job that keeps it on the runner has none."
      rc=1
      continue
    fi
    if (( upload < drive )); then
      fail "${LANE_YML}:${job} uploads (line $(( first + upload - 1 ))) BEFORE it drives (line $(( first + drive - 1 ))). The gate runs inside the drive, so an upload above it publishes captures nothing has scanned."
      rc=1
    fi
  done < <(lane_jobs "${f}")
  if (( n == 0 )); then
    broken "${LANE_YML} declares no job this guard can read."
    return 2
  fi
  return "${rc}"
}

# `<line>\t<step text on one line>\t<if-expr>` for every step of ONE job. Line
# numbers are absolute; full-line comments are dropped, so a commented-out step
# is not a step and a comment naming one is not its body. The CONDITION is the
# last field because a tab is IFS whitespace: an empty middle field collapses
# and every later field shifts left, which reads a step with no `if:` as a step
# with no body.
lane_steps() { # lane_steps <workflow> <first> <last>
  awk -v first="$2" -v last="$3" '
    NR < first || NR > last { next }
    /^[[:space:]]*#/ { next }
    /^      - / {
      if (start) print start "\t" body "\t" cond
      start = NR; cond = ""; body = ""
    }
    !start { next }
    {
      line = $0
      if (line ~ /^[[:space:]]*if:/) {
        c = line
        sub(/^[[:space:]]*if:[[:space:]]*/, "", c)
        cond = cond " " c
      }
      gsub(/\t/, " ", line)
      body = body " " line
    }
    END { if (start) print start "\t" body "\t" cond }
  ' "$1"
}

# L7 — a scan step the reaper cannot switch off stands before every upload.
check_scan_step_survives_the_reaper() {
  local root="$1"
  local f="${root}/${LANE_YML}" rc=0 job first last n=0
  [[ -f "${f}" ]] || { broken "${LANE_YML} not found."; return 2; }
  local line cond body drive_id scan_at scan_cond upload_at
  while IFS=$'\t' read -r job first last; do
    [[ -n "${job}" ]] || continue
    n=$(( n + 1 ))
    drive_id=''; scan_at=''; scan_cond=''; upload_at=''
    while IFS=$'\t' read -r line body cond; do
      case "${body}" in
        *--scan-only*|*scan-logs.sh*)
          [[ -n "${scan_at}" ]] || { scan_at="${line}"; scan_cond="${cond}"; } ;;
        *"${RUNNER_SH}"*)
          if [[ -z "${drive_id}" && "${body}" =~ id:[[:space:]]+([A-Za-z0-9_-]+) ]]; then
            drive_id="${BASH_REMATCH[1]}"
          fi ;;
        *upload-artifact*)
          [[ -n "${upload_at}" ]] || upload_at="${line}" ;;
      esac
    done < <(lane_steps "${f}" "${first}" "${last}")

    if [[ -z "${scan_at}" ]]; then
      fail "${LANE_YML}:${job} has no scan step of its own between the drive and the upload. The drive's scan dies with the drive: the deadline's \`timeout\` signals the whole process group, and the upload then publishes a tree nothing has read."
      rc=1
      continue
    fi
    if [[ ! "${scan_cond}" =~ (^|[^[:alnum:]_])(![[:space:]]*cancelled\(\)|always\(\)) ]]; then
      fail "${LANE_YML}:${job}'s scan step (line ${scan_at}) is not outcome-independent: its \`if:\` is '${scan_cond# }'. Without \`!cancelled()\` or \`always()\` a step runs only while every step before it succeeded — so a reaped drive (rc 124) skips the scan and the upload publishes the captures it would have read."
      rc=1
    fi
    if [[ -n "${drive_id}" && "${scan_cond}" == *"steps.${drive_id}."* ]]; then
      fail "${LANE_YML}:${job}'s scan step (line ${scan_at}) keys its \`if:\` on the drive step (steps.${drive_id}). That is the one outcome it may not read: the case it exists for IS the drive failing."
      rc=1
    fi
    if [[ -n "${upload_at}" ]] && (( scan_at > upload_at )); then
      fail "${LANE_YML}:${job} scans (line ${scan_at}) AFTER it uploads (line ${upload_at}). A scan below the upload reads what has already been published."
      rc=1
    fi
  done < <(lane_jobs "${f}")
  if (( n == 0 )); then
    broken "${LANE_YML} declares no job this guard can read."
    return 2
  fi
  log "L7: ${n} soak job(s) scan before uploading, on a condition the drive's outcome cannot switch off."
  return "${rc}"
}

# The scenario ids a profile TOML declares, lower-cased and sorted.
#
# Comment lines dropped first. A profile's header prose names the scenarios it
# deliberately does NOT run — `pr.toml` explains why S17 is not in it — and
# counting those would let a profile drop a scenario from its `[[scenarios]]`
# tables and still satisfy the nesting check by mentioning it in a sentence.
profile_scenarios() { # profile_scenarios <toml>
  grep -vE '^[[:space:]]*#' "$1" 2>/dev/null \
    | grep -ohEi '\bs[0-9]{2}\b' | tr 'A-Z' 'a-z' | sort -u
}

# L5 — the profiles nest, and no drive-skip row names a soak path.
check_profiles_nest() {
  local root="$1" dir="${root}/${PROFILE_DIR}" rc=0 rows=''
  local skips="${root}/${DRIVE_SKIPS}"
  # Comment lines dropped first, then matched anywhere on the line: a pattern
  # anchored with `^[^#].*` would miss a row whose very first characters ARE
  # the path. Materialised rather than piped, for L3's reason — here a
  # `pipefail` 141 on a MATCH would wave the violation through.
  [[ -f "${skips}" ]] && rows="$(grep -vE '^[[:space:]]*(#|$)' "${skips}" || true)"
  if [[ -n "${rows}" ]] && grep -qE 'tooling/soak|haven-soak|haven_soak' <<<"${rows}"; then
    fail "${DRIVE_SKIPS} carries a row naming a soak path. That file declares Dart drive hatches under haven/integration_test; a soak row there is an exemption nothing can act on and nobody can re-derive."
    rc=1
  fi
  if [[ ! -d "${dir}" ]]; then
    log "L5/L6 are inert: ${PROFILE_DIR} is not in the tree yet."
    return "${rc}"
  fi
  local pr nightly weekly missing
  pr="$(profile_scenarios "${dir}/pr.toml")"
  nightly="$(profile_scenarios "${dir}/nightly.toml")"
  weekly="$(profile_scenarios "${dir}/weekly.toml")"
  if [[ -z "${pr}" || -z "${nightly}" || -z "${weekly}" ]]; then
    broken "${PROFILE_DIR}: one of pr/nightly/weekly declares no scenario this guard can read, so the nesting below would hold vacuously."
    return 2
  fi
  missing="$(comm -23 <(printf '%s\n' "${pr}") <(printf '%s\n' "${nightly}") | tr '\n' ' ')"
  if [[ -n "${missing% }" ]]; then
    fail "${PROFILE_DIR}: pr declares scenario(s) nightly does not (${missing% }). The nightly run would then prove LESS than the per-commit one."
    rc=1
  fi
  missing="$(comm -23 <(printf '%s\n' "${nightly}") <(printf '%s\n' "${weekly}") | tr '\n' ' ')"
  if [[ -n "${missing% }" ]]; then
    fail "${PROFILE_DIR}: nightly declares scenario(s) weekly does not (${missing% })."
    rc=1
  fi
  log "L5: pr ($(grep -c . <<<"${pr}")) ⊆ nightly ($(grep -c . <<<"${nightly}")) ⊆ weekly ($(grep -c . <<<"${weekly}"))."
  return "${rc}"
}

# A duration token (`6m`, `300m`, `90s`) in seconds; "" when unparseable.
dur_secs() { # dur_secs <token>
  local t="$1" n u
  [[ "${t}" =~ ^([0-9]+)([smhd])$ ]] || { printf '\n'; return; }
  n="${BASH_REMATCH[1]}"; u="${BASH_REMATCH[2]}"
  case "${u}" in
    s) printf '%s\n' "${n}" ;;
    m) printf '%s\n' "$(( n * 60 ))" ;;
    h) printf '%s\n' "$(( n * 3600 ))" ;;
    d) printf '%s\n' "$(( n * 86400 ))" ;;
  esac
}

# The deadline a profile TOML declares, in seconds. Either spelling.
toml_deadline_secs() { # toml_deadline_secs <toml>
  local f="$1" v
  [[ -f "${f}" ]] || { printf '\n'; return; }
  v="$(grep -oE '^[[:space:]]*deadline_secs[[:space:]]*=[[:space:]]*[0-9]+' "${f}" | grep -oE '[0-9]+$' | head -1)"
  if [[ -n "${v}" ]]; then printf '%s\n' "${v}"; return; fi
  v="$(grep -oE '^[[:space:]]*deadline[[:space:]]*=[[:space:]]*"[0-9]+[smhd]"' "${f}" \
        | grep -oE '[0-9]+[smhd]' | head -1)"
  dur_secs "${v}"
}

# L6 — the TOML's deadline equals the workflow's literal, per profile.
check_deadlines_agree() {
  local root="$1" dir="${root}/${PROFILE_DIR}" f="${root}/${LANE_YML}" rc=0
  [[ -d "${dir}" ]] || return 0
  [[ -f "${f}" ]] || { broken "${LANE_YML} not found."; return 2; }
  local job first last body tok want got n=0 profile
  while IFS=$'\t' read -r job first last; do
    [[ -n "${job}" ]] || continue
    profile="${job##*_}"
    [[ -f "${dir}/${profile}.toml" ]] || continue
    n=$(( n + 1 ))
    body="$(sed -n "${first},${last}p" "${f}" | grep -vE '^[[:space:]]*#')"
    tok="$(grep -oE 'run-with-deadline\.sh[[:space:]]+[0-9]+[smhd]' <<<"${body}" \
            | grep -oE '[0-9]+[smhd]' | head -1)"
    if [[ -z "${tok}" ]]; then
      fail "${LANE_YML}:${job} spells no run-with-deadline.sh literal, so there is nothing for ${profile}.toml to agree with."
      rc=1
      continue
    fi
    got="$(dur_secs "${tok}")"
    want="$(toml_deadline_secs "${dir}/${profile}.toml")"
    if [[ -z "${want}" ]]; then
      fail "${PROFILE_DIR}/${profile}.toml declares no deadline (\`deadline = \"6m\"\` or \`deadline_secs = 360\`). The rig sizes its run against it and the lane reaps at its own literal; unstated, the two cannot be held together."
      rc=1
      continue
    fi
    if [[ "${want}" != "${got}" ]]; then
      fail "${LANE_YML}:${job} reaps at ${tok} (${got} s) while ${profile}.toml declares ${want} s. The quiet failure is the reaper firing before the rig can finalise, reported as an anonymous timeout."
      rc=1
    fi
  done < <(lane_jobs "${f}")
  if (( n == 0 )); then
    broken "${PROFILE_DIR} exists but no soak job's profile matched a TOML there — the job-to-profile mapping this guard reads (the job id's last \`_\` segment) has rotted."
    return 2
  fi
  log "L6: ${n} profile deadline(s) agree between ${LANE_YML} and ${PROFILE_DIR}."
  return "${rc}"
}

run_all() {
  local root="$1"
  check_ci_calls_the_lane "${root}" || true
  check_job_names_are_counted "${root}" || true
  check_self_test_runs "${root}" || true
  check_scan_precedes_upload "${root}" || true
  check_scan_step_survives_the_reaper "${root}" || true
  check_profiles_nest "${root}" || true
  check_deadlines_agree "${root}" || true
}

# ---------------------------------------------------------------------------
# Self-test. Hermetic: synthetic workflow trees in a temp dir, both directions
# per link, plus every route by which the guard could go blind.
# ---------------------------------------------------------------------------
self_test() {
  local tmp fails=0 checked=0
  tmp="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf '${tmp}'" RETURN

  _case() { # _case <label> <want-rc> <fn> <root>
    local label="$1" want="$2" fn="$3" root="$4" got=0
    checked=$(( checked + 1 ))
    ( FAILED=0; BROKEN=0
      "${fn}" "${root}" >/dev/null 2>&1
      if (( BROKEN )); then exit 2; fi
      if (( FAILED )); then exit 1; fi
      exit 0
    ) || got=$?
    if [[ "${got}" -eq "${want}" ]]; then
      printf '  \033[1;32mPASS\033[0m %s\n' "${label}"
    else
      printf '  \033[1;31mFAIL\033[0m %s (want rc=%d, got rc=%d)\n' "${label}" "${want}" "${got}" >&2
      fails=1
    fi
  }

  _mk() { # _mk <root>
    local r="$1"
    mkdir -p "${r}/.github/workflows" "${r}/tooling/e2e/ci" "${r}/${PROFILE_DIR}"
    cat > "${r}/${CI_YML}" <<'YAML'
name: CI
on: [push]
jobs:
  rust:
    uses: ./.github/workflows/rust-check.yml
  soak-core-pr:
    name: Soak Core (pr profile)
    needs: [rust]
    uses: ./.github/workflows/soak-core.yml
    with:
      profile: pr
YAML
    cat > "${r}/${LANE_YML}" <<'YAML'
name: Soak Core
on:
  workflow_call:
    inputs:
      profile:
        type: string
jobs:
  e2e_soak_core_pr:
    name: e2e_soak_core_pr
    if: ${{ inputs.profile == 'pr' }}
    runs-on: ubuntu-latest
    steps:
      - name: Checkout
        id: checkout
        uses: actions/checkout@v6
      - name: Run the soak (pr profile)
        id: soak
        run: bash tooling/e2e/ci/run-with-deadline.sh 6m "soak-core pr" -- bash tooling/e2e/ci/run-soak-core.sh pr
      - name: Scan the soak evidence before upload
        if: ${{ !cancelled() && steps.checkout.outcome == 'success' }}
        run: bash tooling/e2e/ci/run-soak-core.sh --scan-only pr
      - name: Upload soak evidence
        uses: actions/upload-artifact@v6
        with:
          path: ${{ runner.temp }}/soak-upload/
YAML
    cat > "${r}/${RUST_YML}" <<'YAML'
name: Rust Check
on:
  workflow_call:
jobs:
  soak-tooling:
    runs-on: ubuntu-latest
    steps:
      - name: Rig self-test
        run: cargo run --profile soak --bin haven-soak -- --self-test > "${RUNNER_TEMP}/soak-selftest.log" 2>&1
YAML
    cat > "${r}/${FLAKINESS_YML}" <<'YAML'
name: E2E Flakiness
on: [schedule]
jobs:
  report:
    runs-on: ubuntu-latest
    steps:
      - run: |
          gh run view --jq '[.jobs[] | select(.name | test("(^| / )(e2e_|scenario_[0-9]|flake_stress)"))]'
YAML
    cat > "${r}/${RUNNER_SH}" <<'SH'
#!/usr/bin/env bash
source "${DIR}/logscan-gate.sh"
logscan_gate host "${SOAK_NEEDLE_DIR}" -- --sink "soak=${spec}"
SH
    printf 'scenarios = ["s01", "s06"]\ndeadline = "6m"\n'  > "${r}/${PROFILE_DIR}/pr.toml"
    printf 'scenarios = ["s01", "s06", "s17"]\ndeadline = "80m"\n' > "${r}/${PROFILE_DIR}/nightly.toml"
    printf 'scenarios = ["s01", "s06", "s17", "s19"]\ndeadline = "300m"\n' > "${r}/${PROFILE_DIR}/weekly.toml"
    printf '# declared drive hatches\nsome/dart/path.dart|reason\n' > "${r}/${DRIVE_SKIPS}"
  }

  echo "[${SELF_NAME}] self-test"

  local ok="${tmp}/ok"; _mk "${ok}"
  _case "a wired lane passes L1" 0 check_ci_calls_the_lane "${ok}"
  _case "a wired lane passes L2" 0 check_job_names_are_counted "${ok}"
  _case "a wired lane passes L3" 0 check_self_test_runs "${ok}"
  _case "a wired lane passes L4" 0 check_scan_precedes_upload "${ok}"
  _case "a wired lane passes L7" 0 check_scan_step_survives_the_reaper "${ok}"
  _case "nesting profiles pass L5" 0 check_profiles_nest "${ok}"
  _case "agreeing deadlines pass L6" 0 check_deadlines_agree "${ok}"

  # --- L1.
  local uncalled="${tmp}/uncalled"; _mk "${uncalled}"
  sed -i '/soak-core.yml/d' "${uncalled}/${CI_YML}"
  _case "a lane ci.yml never calls fails" 1 check_ci_calls_the_lane "${uncalled}"

  local noprofile="${tmp}/noprofile"; _mk "${noprofile}"
  sed -i '/profile: pr/d' "${noprofile}/${CI_YML}"
  _case "a call with no profile input fails" 1 check_ci_calls_the_lane "${noprofile}"

  local wrongneeds="${tmp}/wrongneeds"; _mk "${wrongneeds}"
  sed -i 's/needs: \[rust\]/needs: [rust, coverage]/' "${wrongneeds}/${CI_YML}"
  _case "a call gated on more than rust fails" 1 check_ci_calls_the_lane "${wrongneeds}"

  local commented="${tmp}/commented"; _mk "${commented}"
  sed -i 's|^    uses: ./.github/workflows/soak-core.yml|#    uses: ./.github/workflows/soak-core.yml|' \
    "${commented}/${CI_YML}"
  _case "a commented-out call is not a call" 1 check_ci_calls_the_lane "${commented}"

  # --- L2.
  local badname="${tmp}/badname"; _mk "${badname}"
  sed -i 's/^  e2e_soak_core_pr:/  soak_core_pr:/' "${badname}/${LANE_YML}"
  _case "a job name outside the flakiness pattern fails" 1 check_job_names_are_counted "${badname}"

  local nore="${tmp}/nore"; _mk "${nore}"
  sed -i 's/test(".*")/select(.name)/' "${nore}/${FLAKINESS_YML}"
  _case "an unreadable flakiness regex is BROKEN, not clean" 2 check_job_names_are_counted "${nore}"

  # --- L3.
  local noself="${tmp}/noself"; _mk "${noself}"
  sed -i '/--self-test/d' "${noself}/${RUST_YML}"
  _case "no --self-test of the shipped binary fails" 1 check_self_test_runs "${noself}"

  # --- L4.
  local uploadfirst="${tmp}/uploadfirst"; _mk "${uploadfirst}"
  cat > "${uploadfirst}/${LANE_YML}" <<'YAML'
name: Soak Core
on:
  workflow_call:
jobs:
  e2e_soak_core_pr:
    runs-on: ubuntu-latest
    steps:
      - name: Upload soak evidence
        uses: actions/upload-artifact@v6
        with:
          path: ${{ runner.temp }}/soak-upload/
      - name: Run the soak
        run: bash tooling/e2e/ci/run-with-deadline.sh 6m "soak" -- bash tooling/e2e/ci/run-soak-core.sh pr
YAML
  _case "an upload above the drive fails" 1 check_scan_precedes_upload "${uploadfirst}"

  local nodeadline="${tmp}/nodeadline"; _mk "${nodeadline}"
  sed -i 's|bash tooling/e2e/ci/run-with-deadline.sh 6m "soak-core pr" -- ||' "${nodeadline}/${LANE_YML}"
  _case "a drive with no inner deadline fails" 1 check_scan_precedes_upload "${nodeadline}"

  local noupload="${tmp}/noupload"; _mk "${noupload}"
  sed -i '/upload-artifact/d' "${noupload}/${LANE_YML}"
  _case "a job that uploads nothing fails" 1 check_scan_precedes_upload "${noupload}"

  local ungated="${tmp}/ungated"; _mk "${ungated}"
  sed -i '/logscan_gate host/d' "${ungated}/${RUNNER_SH}"
  _case "a runner that never calls the gate fails" 1 check_scan_precedes_upload "${ungated}"

  local unsourced="${tmp}/unsourced"; _mk "${unsourced}"
  sed -i '/logscan-gate.sh/d' "${unsourced}/${RUNNER_SH}"
  _case "a runner that no longer sources the gate fails" 1 check_scan_precedes_upload "${unsourced}"

  local norunner="${tmp}/norunner"; _mk "${norunner}"
  rm -f "${norunner}/${RUNNER_SH}"
  _case "a missing runner is BROKEN, not clean" 2 check_scan_precedes_upload "${norunner}"

  # --- L7: the four ways a scan step stops standing between a REAPED drive and
  # the upload. Each is a shape that looks right in a diff.
  local noscan="${tmp}/noscan"; _mk "${noscan}"
  sed -i '/- name: Scan the soak evidence before upload/,+2d' "${noscan}/${LANE_YML}"
  _case "a job whose only scan is inside the drive fails" 1 check_scan_step_survives_the_reaper "${noscan}"

  local drivekeyed="${tmp}/drivekeyed"; _mk "${drivekeyed}"
  sed -i "s|steps.checkout.outcome == 'success'|steps.soak.outcome == 'success'|" \
    "${drivekeyed}/${LANE_YML}"
  _case "a scan keyed on the drive's own outcome fails" 1 check_scan_step_survives_the_reaper "${drivekeyed}"

  local plaincond="${tmp}/plaincond"; _mk "${plaincond}"
  sed -i "/if: \${{ !cancelled() && steps.checkout.outcome == 'success' }}/d" \
    "${plaincond}/${LANE_YML}"
  _case "a scan step with no condition at all fails (the default is success())" \
    1 check_scan_step_survives_the_reaper "${plaincond}"

  local scanlast="${tmp}/scanlast"; _mk "${scanlast}"
  cat > "${scanlast}/${LANE_YML}" <<'YAML'
name: Soak Core
on:
  workflow_call:
jobs:
  e2e_soak_core_pr:
    runs-on: ubuntu-latest
    steps:
      - name: Checkout
        id: checkout
        uses: actions/checkout@v6
      - name: Run the soak
        id: soak
        run: bash tooling/e2e/ci/run-with-deadline.sh 6m "soak" -- bash tooling/e2e/ci/run-soak-core.sh pr
      - name: Upload soak evidence
        uses: actions/upload-artifact@v6
        with:
          path: ${{ runner.temp }}/soak-upload/
      - name: Scan the soak evidence
        if: ${{ !cancelled() }}
        run: bash tooling/e2e/ci/run-soak-core.sh --scan-only pr
YAML
  _case "a scan step below the upload fails" 1 check_scan_step_survives_the_reaper "${scanlast}"

  # --- L5.
  local notnested="${tmp}/notnested"; _mk "${notnested}"
  printf 'scenarios = ["s01", "s06", "s13"]\ndeadline = "6m"\n' > "${notnested}/${PROFILE_DIR}/pr.toml"
  _case "a pr scenario missing from nightly fails" 1 check_profiles_nest "${notnested}"

  local soakskip="${tmp}/soakskip"; _mk "${soakskip}"
  printf 'tooling/soak/scenarios/s01.rs|because\n' >> "${soakskip}/${DRIVE_SKIPS}"
  _case "a drive-skip row naming a soak path fails" 1 check_profiles_nest "${soakskip}"

  local emptytoml="${tmp}/emptytoml"; _mk "${emptytoml}"
  printf 'deadline = "80m"\n' > "${emptytoml}/${PROFILE_DIR}/nightly.toml"
  _case "a profile declaring no scenario is BROKEN, not clean" 2 check_profiles_nest "${emptytoml}"

  # --- L6.
  local mismatch="${tmp}/mismatch"; _mk "${mismatch}"
  printf 'scenarios = ["s01", "s06"]\ndeadline = "5m"\n' > "${mismatch}/${PROFILE_DIR}/pr.toml"
  _case "a TOML deadline that differs from the lane's literal fails" 1 check_deadlines_agree "${mismatch}"

  local secs="${tmp}/secs"; _mk "${secs}"
  printf 'scenarios = ["s01", "s06"]\ndeadline_secs = 360\n' > "${secs}/${PROFILE_DIR}/pr.toml"
  _case "the deadline_secs spelling is accepted and compared in seconds" 0 check_deadlines_agree "${secs}"

  local nodecl="${tmp}/nodecl"; _mk "${nodecl}"
  printf 'scenarios = ["s01", "s06"]\n' > "${nodecl}/${PROFILE_DIR}/pr.toml"
  _case "a profile declaring no deadline at all fails" 1 check_deadlines_agree "${nodecl}"

  # --- the landing window.
  local absent="${tmp}/absent"; _mk "${absent}"
  rm -rf "${absent}/tooling/soak"
  _case "L5 is inert while the profiles are absent" 0 check_profiles_nest "${absent}"
  _case "L6 is inert while the profiles are absent" 0 check_deadlines_agree "${absent}"

  if (( fails )); then
    echo "self-test: FAILED" >&2
    return 1
  fi
  if (( checked != SELF_TEST_FIXTURES )); then
    echo "self-test: ran ${checked} fixture(s), expected exactly ${SELF_TEST_FIXTURES}. A fixture was added or removed without moving the pin." >&2
    return 1
  fi
  echo "self-test: OK (${checked}/${SELF_TEST_FIXTURES} fixtures)"
  return 0
}

main() {
  if [[ "${1:-}" == "--self-test" ]]; then
    self_test
    exit $?
  fi
  if [[ $# -gt 0 ]]; then
    echo "usage: $(basename "$0") [--self-test]" >&2
    exit 2
  fi

  run_all "${REPO_ROOT}"

  if (( BROKEN )); then
    echo >&2
    echo "This guard could not see the chain it checks. That is not a clean bill" >&2
    echo "of health: an extractor that stops matching reports every link as intact." >&2
    exit 2
  fi
  if (( FAILED )); then
    echo >&2
    echo "A soak rig nothing runs is the most expensive form of the failure mode" >&2
    echo "docs/CI_HARDENING_BACKLOG.md catalogues: written, reviewed, green on its" >&2
    echo "own fixtures, executed nowhere. See docs/SOAK_LANE.md." >&2
    exit 1
  fi
  log "OK — ci.yml drives the pr profile, the jobs are counted, the artifact is self-tested, the gate stands before every upload and again in a step no reaping can skip, and the profiles and deadlines agree."
}

main "$@"
