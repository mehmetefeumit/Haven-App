#!/usr/bin/env bash
#
# The `verdict` job: red unless every other job of its workflow run succeeded.
#
# ## Why
#
# A job whose `needs:` failed is SKIPPED, and GitHub reports a skipped job as
# neither red nor green: a required status check that names it passes. Since
# every Android lane needs android-gradle-deps.yml's job, a run that could not
# get its Gradle dependencies would skip ~17 lanes — the iOS jobs sharing
# e2e-profile.yml and build-check.yml with them too — and a check reading only
# their status could pass. The owner's decision (2026-11-26): such a run is red
# and a human re-runs it; nothing skipped ever reads as passed. So each
# workflow below carries one job that needs every other job, runs whatever they
# did (`if: always()`), and fails unless each `needs.<job>.result` is
# `success`: `skipped`, `cancelled` and `failure` are all red. No ci.yml job is
# skipped on a good run (none carries an `if:`; a reusable workflow whose own
# jobs skip by design still reports `success` to its caller, as in run
# 45142774793), so there is no exemption to take.
#
# ## Where (the static check)
#
#   ci.yml, and every workflow that calls android-gradle-deps.yml (today
#   e2e-nightly.yml, e2e-live-sync.yml and launch-gate-android-dispatch.yml),
#   each hold exactly one job `verdict` that
#     V1  exists once,
#     V2  runs `if: always()`,
#     V3  `needs:` exactly every other job of the file, as a block list,
#     V4  judges with `bash scripts/ci/check_all_jobs_passed.sh --judge` and
#         `NEEDS: ${{ toJSON(needs) }}`,
#     V5  and is never `continue-on-error`.
#
# Usage:
#   check_all_jobs_passed.sh              # the static check (repo-guards.yml)
#   check_all_jobs_passed.sh --judge      # the verdict job; reads $NEEDS
#   check_all_jobs_passed.sh --self-test
#
# Exit codes:
#   0  passed
#   1  a job did not succeed (--judge), or a verdict job is mis-wired
#   2  misconfiguration: no or unreadable $NEEDS, a missing workflow
#      directory, or the self-test failed

set -euo pipefail

readonly SCRIPT_NAME="check_all_jobs_passed.sh"
readonly RC_BROKEN=2
readonly VERDICT_JOB="verdict"
readonly JUDGE_RUN='run: bash scripts/ci/check_all_jobs_passed.sh --judge'
readonly JUDGE_ENV='NEEDS: ${{ toJSON(needs) }}'
readonly DEPS_USES='uses: ./.github/workflows/android-gradle-deps.yml'

log() { printf '[%s] %s\n' "${SCRIPT_NAME}" "$*"; }
fail() { printf '[%s] FAIL: %s\n' "${SCRIPT_NAME}" "$*" >&2; violations=$(( violations + 1 )); }

judge() {
  local rows bad
  [[ -n "${NEEDS:-}" ]] || { printf '::error::the verdict job was given no needs context.\n' >&2; return "${RC_BROKEN}"; }
  rows="$(jq -er 'to_entries | if length == 0 then error("empty") else .[] | "\(.key)\t\(.value.result)" end' <<<"${NEEDS}" 2>/dev/null)" \
    || { printf '::error::the verdict job cannot read its needs context, or it names no job.\n' >&2; return "${RC_BROKEN}"; }
  bad="$(awk -F'\t' '$2 != "success" { print "  " $1 ": " $2 }' <<<"${rows}")"
  if [[ -n "${bad}" ]]; then
    printf '%s\n' "${bad}" >&2
    printf '::error::%s job(s) of this run did not succeed (listed above). A skipped job is not a passed one: a job skips here because a job it needs failed, so this run is red until a re-run makes every job succeed.\n' \
      "$(grep -c . <<<"${bad}")" >&2
    return 1
  fi
  log "all $(grep -c . <<<"${rows}") jobs this run needs succeeded."
}

# <job key>\t<line> for every job key of a workflow, quoted or with a comment
# after it; a line two spaces deep under `jobs:` that is no key it can read
# comes out as `!unparsed`, so no job escapes the check by its spelling.
job_keys() {
  awk '/^jobs:[[:space:]]*(#.*)?$/ { j = 1; next }
       j && /^[^[:space:]#]/ { j = 0 }
       j && /^  [^[:space:]#]/ {
         k = $0; sub(/^  /, "", k); sub(/[[:space:]]+#.*$/, "", k); sub(/[[:space:]]+$/, "", k)
         if (k ~ /^["\047]?[A-Za-z0-9_-]+["\047]?:$/) { sub(/:$/, "", k); gsub(/["\047]/, "", k); print k "\t" NR }
         else print "!unparsed\t" NR
       }' "$1"
}

# 0 when one step of the verdict block runs the judge, unconditionally, over
# the needs context: the command in a comment, or in a step with an `if:`,
# judges nothing on the run that needs it.
judges() { # <verdict block>
  awk -v run="${JUDGE_RUN}" -v env="${JUDGE_ENV}" '
    function close_step() { if (r && e && !c) ok = 1; r = 0; e = 0; c = 0 }
    /^      - / { close_step(); $0 = "        " substr($0, 9) }
    { line = $0; sub(/^[[:space:]]+/, "", line); sub(/[[:space:]]+$/, "", line) }
    /^        run:/ && line == run { r = 1 }
    /^          NEEDS:/ && line == env { e = 1 }
    /^        if:/ { c = 1 }
    END { close_step(); exit !ok }
  ' <<<"$1"
}

check_workflow() { # <file>
  local f="$1" base keys n start end block needs others
  base="$(basename "${f}")"
  keys="$(job_keys "${f}")"
  if grep -q '^!unparsed' <<<"${keys}"; then
    fail "V0 ${base} line(s) $(awk -F'\t' '$1 == "!unparsed" { print $2 }' <<<"${keys}" | paste -sd, -): sit where a job key belongs and are no key this guard can read, so the verdict could not be held to that job. Write each as \`  <key>:\`."
    return
  fi
  n="$(awk -F'\t' -v v="${VERDICT_JOB}" '$1 == v' <<<"${keys}" | grep -c . || true)"
  if [[ "${n}" != 1 ]]; then
    fail "V1 ${base}: has ${n} \`${VERDICT_JOB}\` job(s), not exactly one. Without it a run whose Gradle-dependency job failed skips every lane that needs it, and a skipped job passes a required check."
    return
  fi
  start="$(awk -F'\t' -v v="${VERDICT_JOB}" '$1 == v { print $2 }' <<<"${keys}")"
  end="$(awk -F'\t' -v s="${start}" '$2 > s { print $2 - 1; exit }' <<<"${keys}")"
  [[ -n "${end}" ]] || end="$(wc -l < "${f}")"
  block="$(sed -n "${start},${end}p" "${f}")"

  grep -qxE '    if: always\(\)[[:space:]]*' <<<"${block}" \
    || fail "V2 ${base}: \`${VERDICT_JOB}\` is not \`if: always()\`, so it is skipped exactly when a job it needs failed — the one case it exists for."
  needs="$(awk '/^    needs:[[:space:]]*$/ { n = 1; next } n && /^      - / { v = $0; sub(/^      - /, "", v); sub(/[[:space:]]+$/, "", v); print v; next } n { n = 0 }' <<<"${block}" | LC_ALL=C sort)"
  others="$(awk -F'\t' -v v="${VERDICT_JOB}" '$1 != v { print $1 }' <<<"${keys}" | LC_ALL=C sort)"
  if [[ -z "${needs}" || "${needs}" != "${others}" ]]; then
    fail "V3 ${base}: \`${VERDICT_JOB}\` must need every other job of the file, each once, as a block list; missing: [$(comm -13 <(printf '%s\n' "${needs}") <(printf '%s\n' "${others}") | paste -sd, -)], extra or repeated: [$(comm -23 <(printf '%s\n' "${needs}") <(printf '%s\n' "${others}") | paste -sd, -)]."
  fi
  if ! judges "${block}"; then
    fail "V4 ${base}: \`${VERDICT_JOB}\` must judge with '${JUDGE_RUN}' over '${JUDGE_ENV}', in one step that carries no \`if:\`."
  fi
  if grep -qE '^[[:space:]]+continue-on-error:' <<<"${block}"; then
    fail "V5 ${base}: \`${VERDICT_JOB}\` must never be continue-on-error: a verdict that cannot fail is no verdict."
  fi
}

check_repo() { # <workflow dir>
  local dir="$1" f checked=0
  violations=0
  for f in "${dir}"/*.yml; do
    [[ -e "${f}" ]] || continue
    if [[ "$(basename "${f}")" == ci.yml ]] || grep -qF -- "${DEPS_USES}" "${f}"; then
      check_workflow "${f}"
      checked=$(( checked + 1 ))
    fi
  done
  if [[ ! -f "${dir}/ci.yml" ]]; then
    fail "V1 ci.yml is missing from ${dir}."
  fi
  if (( violations )); then
    printf '[%s] FAIL: %d violation(s).\n' "${SCRIPT_NAME}" "${violations}" >&2
    return 1
  fi
  log "OK — ${checked} workflow(s) each end in one \`${VERDICT_JOB}\` job that needs every other job, runs always and is red unless each succeeded."
}

# ---------------------------------------------------------------------------
# Self-test: the judgement over planted needs contexts, and the static check
# over planted workflows, each negative one property away from the positive.
# ---------------------------------------------------------------------------
readonly SELF_TEST_FIXTURES=19

run_self_test() {
  local tmp ran=0 failures=0 rc
  tmp="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf '${tmp}'" EXIT
  _expect_judge() { # <label> <want rc> <needs json>
    ran=$(( ran + 1 ))
    rc=0; NEEDS="$3" judge >"${tmp}/out" 2>&1 || rc=$?
    if (( rc != $2 )); then echo "SELF-TEST FAIL (${1}): rc ${rc}, want $2" >&2; sed 's/^/    /' "${tmp}/out" >&2; failures=1; fi
  }
  _expect_judge "every job succeeded" 0 '{"rust":{"result":"success","outputs":{}},"gradle-deps":{"result":"success","outputs":{}}}'
  _expect_judge "a lane skipped because the deps job failed" 1 '{"gradle-deps":{"result":"failure","outputs":{}},"e2e-android":{"result":"skipped","outputs":{}}}'
  _expect_judge "a skipped job alone is red" 1 '{"rust":{"result":"success"},"e2e-profile":{"result":"skipped"}}'
  _expect_judge "a cancelled job is red" 1 '{"rust":{"result":"success"},"coverage":{"result":"cancelled"}}'
  _expect_judge "no needs context is a misconfiguration" 2 ''
  _expect_judge "an empty needs context is a misconfiguration" 2 '{}'

  local wf="${tmp}/wf"
  _write() { # <file> <needs lines...>
    local file="$1"; shift
    {
      printf 'name: X\non:\n  push:\njobs:\n'
      printf '  gradle-deps:\n    permissions:\n      contents: read\n      actions: read\n    uses: ./.github/workflows/android-gradle-deps.yml\n'
      printf '  lane:\n    needs: [gradle-deps]\n    uses: ./.github/workflows/e2e-android.yml\n'
      printf '  %s:\n    name: All jobs passed\n    if: always()\n    needs:\n' "${VERDICT_JOB}"
      local n; for n in "$@"; do printf '      - %s\n' "${n}"; done
      printf '    runs-on: ubuntu-latest\n    steps:\n      - name: Every job succeeded\n        env:\n          %s\n        %s\n' "${JUDGE_ENV}" "${JUDGE_RUN}"
    } > "${file}"
  }
  _expect_check() { # <label> <want rc> <must-say>
    ran=$(( ran + 1 ))
    rc=0; check_repo "${wf}" >"${tmp}/out" 2>&1 || rc=$?
    if (( rc != $2 )) || [[ -n "$3" && "$(cat "${tmp}/out")" != *"$3"* ]]; then
      echo "SELF-TEST FAIL (${1}): rc ${rc}, want $2${3:+ saying '$3'}" >&2; sed 's/^/    /' "${tmp}/out" >&2; failures=1
    fi
  }
  _reset() { rm -rf "${wf}"; mkdir -p "${wf}"; _write "${wf}/ci.yml" gradle-deps lane; _write "${wf}/e2e-nightly.yml" gradle-deps lane
             printf 'name: Y\non:\n  push:\njobs:\n  a:\n    runs-on: ubuntu-latest\n    steps:\n      - run: true\n' > "${wf}/other.yml"; }

  _reset; _expect_check "the wired shape passes" 0 ""
  _reset; _write "${wf}/e2e-nightly.yml" gradle-deps; _expect_check "a job left out of needs" 1 "missing: [lane]"
  _reset; _write "${wf}/ci.yml" gradle-deps lane ghost; _expect_check "a need that is no job here" 1 "extra or repeated: [ghost]"
  _reset; sed -i 's/    if: always()/    if: success()/' "${wf}/ci.yml"; _expect_check "if: success() instead of always()" 1 "V2"
  _reset; sed -i "s|${JUDGE_RUN}|run: exit 0|" "${wf}/ci.yml"; _expect_check "a verdict that judges nothing" 1 "V4"
  _reset; sed -i 's/    runs-on: ubuntu-latest$/    runs-on: ubuntu-latest\n    continue-on-error: true/' "${wf}/ci.yml"; _expect_check "a verdict that cannot fail" 1 "V5"
  _reset; sed -i "/^  ${VERDICT_JOB}:/,\$d" "${wf}/e2e-nightly.yml"; _expect_check "a deps-calling workflow with no verdict" 1 "V1 e2e-nightly.yml"
  # CONTROL for the one above: the same file with no verdict and no deps call
  # is not the subject, which is what makes that case about the deps call.
  _reset; sed -i "/^  ${VERDICT_JOB}:/,\$d; /android-gradle-deps.yml/d" "${wf}/e2e-nightly.yml"; _expect_check "a workflow that calls no deps job needs no verdict" 0 ""

  # Spellings that once escaped the wiring check.
  _reset; sed -i 's/^  lane:$/  lane: # a lane\n    uses: x\n  late: # added later/' "${wf}/ci.yml"
  _expect_check "a job key with a trailing comment still has to be needed" 1 "missing: [late]"
  _reset; sed -i 's/^  lane:$/  lane:\n    uses: x\n  "late":/' "${wf}/ci.yml"
  _expect_check "a quoted job key still has to be needed" 1 "missing: [late]"
  _reset; printf '  other: {runs-on: x}\n' >> "${wf}/ci.yml"
  _expect_check "a line under jobs: that is no readable key fails closed" 1 "V0"
  _reset; sed -i "s|^        ${JUDGE_RUN}$|        # ${JUDGE_RUN}\n        run: exit 0|" "${wf}/ci.yml"
  _expect_check "the judge in a comment judges nothing" 1 "V4"
  _reset; sed -i 's/^      - name: Every job succeeded$/      - name: Every job succeeded\n        if: success()/' "${wf}/ci.yml"
  _expect_check "a judge step that can be skipped judges nothing" 1 "V4"

  if (( failures )); then
    echo "${SCRIPT_NAME}: SELF-TEST FAILED" >&2
    return 1
  fi
  if (( ran != SELF_TEST_FIXTURES )); then
    echo "${SCRIPT_NAME}: SELF-TEST FAILED — ran ${ran} fixture(s), expected exactly ${SELF_TEST_FIXTURES}" >&2
    return 1
  fi
  echo "${SCRIPT_NAME}: self-test passed (${ran}/${SELF_TEST_FIXTURES} fixtures: the judgement passes a run whose every job succeeded and fails one with a skipped, cancelled or failed job, and refuses a missing or empty needs context; the static check passes the wired shape and catches a job left out of needs, a need that is no job, if: success(), a verdict that judges nothing, one that cannot fail, and a deps-calling workflow with no verdict, while a workflow that calls no deps job needs none; a job key with a comment or quotes is still held to the needs list and an unreadable one fails closed; and the judge only in a comment, or in a step with an if:, judges nothing)."
}

case "${1:-}" in
  --self-test) run_self_test ;;
  --judge) judge ;;
  '')
    [[ -d .github/workflows ]] || { echo "${SCRIPT_NAME}: .github/workflows not found — run from the repo root." >&2; exit "${RC_BROKEN}"; }
    check_repo .github/workflows ;;
  *) echo "usage: ${SCRIPT_NAME} [--judge | --self-test]" >&2; exit "${RC_BROKEN}" ;;
esac
