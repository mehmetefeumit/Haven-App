#!/usr/bin/env bash
#
# CI guard: every step of repo-guards.yml after its checkout runs whenever the
# checkout succeeded, whatever failed before it.
#
# A step with no `if:` carries GitHub's implicit `success()`, so it is skipped
# the moment any earlier step fails. In CI run 44523702729 the xmllint install
# failed on a mirror outage, the jq and Dart setup steps behind it had no `if:`
# and were skipped, and the Dart guards then failed `dart: command not found`
# — one outage, twelve red steps, most pointing at the wrong cause. The same
# hole on a guard step hides that guard's verdict behind any earlier red.
# check_privacy_invariants.sh accepts an absent `if:` on the guards it cites,
# so nothing else holds this.
#
# Rule: in each of the file's jobs, the step with `id: checkout` comes first,
# and every other step carries exactly
#     if: ${{ !cancelled() && steps.checkout.outcome == 'success' }}
#
# Usage:
#   check_repo_guards_step_conditions.sh [<workflow>]   default: repo-guards.yml
#   check_repo_guards_step_conditions.sh --self-test
#
# Exit: 0 holds; 1 a step breaks it; 2 a workflow this cannot read (no
# checkout step, no steps), or a failed self-test.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
readonly STANDARD="\${{ !cancelled() && steps.checkout.outcome == 'success' }}"

check() { # check <workflow>
  [[ -f "$1" ]] || { echo "ERROR: $1 not found" >&2; return 2; }
  awk -v want="${STANDARD}" '
    function indent(s) { match(s, /^[[:space:]]*/); return RLENGTH }
    function value(s) { sub(/^[[:space:]]*(-[[:space:]]+)?[A-Za-z_-]+:[[:space:]]*/, "", s); sub(/[[:space:]]+$/, "", s); return s }
    function close_step() {
      if (!n) return
      if (n == 1) { if (id != "checkout") { first_bad = 1 } }
      else if (cond != want) { printf "FAIL step %d (%s): if: %s\n", n, name, (cond == "" ? "absent (skipped after any earlier failure)" : "`" cond "`"); bad = 1 }
      if (n > most) most = n
    }
    /^[[:space:]]*steps:[[:space:]]*$/ { if (insteps) close_step(); insteps = 1; si = -1; n = 0; next }
    !insteps { next }
    /^[[:space:]]*#/ || /^[[:space:]]*$/ { next }
    /^[[:space:]]*-[[:space:]]+[A-Za-z_-]+:/ && (si < 0 || indent($0) == si) {
      close_step()
      si = indent($0); match($0, /^[[:space:]]*-[[:space:]]+/); ki = RLENGTH
      n++; name = "unnamed"; id = ""; cond = ""
    }
    si >= 0 && indent($0) < si && $0 !~ /^[[:space:]]*-/ { close_step(); n_end = n; insteps = 0; next }
    {
      line = $0
      if (indent(line) == si) line = sprintf("%" ki "s", "") substr(line, ki + 1)
      if (indent(line) != ki) next
      if (line ~ /^[[:space:]]*name:/) name = value(line)
      else if (line ~ /^[[:space:]]*id:/) id = value(line)
      else if (line ~ /^[[:space:]]*if:/) cond = value(line)
    }
    END {
      if (insteps) close_step()
      if (most < 2) { print "ERROR: fewer than two steps found: not a workflow this guard can read" > "/dev/stderr"; exit 2 }
      if (first_bad) { print "ERROR: the first step is not `id: checkout`: the rule has no anchor" > "/dev/stderr"; exit 2 }
      exit bad
    }
  ' "$1"
}

self_test() {
  local tmp failures=0
  tmp="$(mktemp -d)"
  trap 'rm -rf "${tmp}"' RETURN

  _case() { # <name> <want rc> <workflow body>
    local got=0
    printf '%s\n' "$3" >"${tmp}/w.yml"
    check "${tmp}/w.yml" >/dev/null 2>&1 || got=$?
    if [[ "${got}" != "$2" ]]; then
      echo "self-test FAILED [$1]: expected exit $2, got ${got}" >&2
      failures=$((failures + 1))
    fi
  }

  local head="name: Repo Guards
on:
  workflow_call:
jobs:
  guards:
    runs-on: ubuntu-latest
    steps:
      - name: Checkout
        id: checkout
        uses: actions/checkout@v6"
  local cond="if: ${STANDARD}" ok="        if: ${STANDARD}"

  _case "standard conditions pass" 0 "${head}
      - name: Ensure tools
        ${cond}
        timeout-minutes: 7
        run: bash scripts/ci/ensure_ci_tools.sh jq=jq
      # a comment between steps
      - name: A guard
        timeout-minutes: 3
${ok}
        run: |
          echo 'if: false'
          bash scripts/ci/check_x.sh"
  _case "a setup step with no if: fails (run 44523702729)" 1 "${head}
      - name: Ensure tools
        run: bash scripts/ci/ensure_ci_tools.sh jq=jq
      - name: Set up Dart
        uses: dart-lang/setup-dart@v1
        with:
          sdk: stable"
  _case "a step that starts with uses: and has no if: fails" 1 "${head}
      - uses: dart-lang/setup-dart@v1
        name: Set up Dart"
  _case "an if: commented out does not count" 1 "${head}
      - name: A guard
        # ${cond}
        run: bash scripts/ci/check_x.sh"
  _case "an if: inside with: does not count" 1 "${head}
      - name: A guard
        uses: some/action@v1
        with:
          ${cond}"
  _case "!cancelled() alone fails: it runs the step without a checkout" 1 "${head}
      - name: A guard
        if: \${{ !cancelled() }}
        run: bash scripts/ci/check_x.sh"
  _case "always() fails" 1 "${head}
      - name: A guard
        if: always()
        run: bash scripts/ci/check_x.sh"
  _case "a checkout that is not first is unreadable" 2 "${head/        id: checkout
/}
      - name: Later checkout
        id: checkout
${ok}
        uses: actions/checkout@v6"
  _case "a checkout alone is unreadable" 2 "${head}"
  _case "no steps at all is unreadable" 2 "name: Repo Guards"
  local second="
  harness:
    runs-on: ubuntu-latest
    steps:
      - name: Checkout
        id: checkout
        uses: actions/checkout@v6"
  _case "a second job holds to the same rule from its own checkout" 0 "${head}${second}
      - name: A harness
${ok}
        run: bash tooling/e2e/ci/x.sh --self-test"
  _case "a second job's step with no if: fails" 1 "${head}${second}
      - name: A harness
        run: bash tooling/e2e/ci/x.sh --self-test"
  _case "a second job that does not start at its checkout is unreadable" 2 "${head}${second/        id: checkout
/}
      - name: A harness
${ok}
        run: bash tooling/e2e/ci/x.sh --self-test"

  if ((failures > 0)); then
    echo "repo-guards step conditions: self-test FAILED (${failures})" >&2
    return 2
  fi
  echo "repo-guards step conditions: self-test OK (13 fixtures)."
}

case "${1:-}" in
  --self-test) self_test ;;
  *)
    check "${1:-${REPO_ROOT}/.github/workflows/repo-guards.yml}"
    echo "OK: every repo-guards.yml step after the checkout runs whenever the checkout succeeded."
    ;;
esac
