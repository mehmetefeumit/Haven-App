#!/usr/bin/env bash
# CI guard: every cargo call in cross-check.yml resolves from the committed
# lockfile.
#
# The cross builds are the only check of the Apple, Windows and Android graphs
# before a release. A `cargo check` without `--locked` re-resolves whatever the
# committed lockfile does not hold for that target, so it can build crates the
# lockfile guards (check_mdk_supply_chain.sh, check_lockfile_universe.sh) never
# read, and pass. With `--locked` it fails instead.
#
# Pure grep over .github/workflows/cross-check.yml: every non-comment line that
# runs `cargo <subcommand>` carries `--locked`, and at least one such line
# exists, so a renamed workflow or a moved call is a failure, not a pass.
#
# Usage:
#   bash scripts/ci/check_cross_check_locked.sh
#   bash scripts/ci/check_cross_check_locked.sh --self-test
#
# Exit codes:
#   0  every cargo call is locked (or the self-test passed)
#   1  a cargo call is not, or there is none (or the self-test failed)
#   2  the workflow is missing (misconfiguration)

set -euo pipefail

REPO_ROOT="${REPO_ROOT_OVERRIDE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
readonly WORKFLOW='.github/workflows/cross-check.yml'
readonly CARGO_CALL='(^|[^A-Za-z0-9_-])cargo[[:space:]]+([+][^[:space:]]+[[:space:]]+)?[a-z]'

# How many fixtures the self-test runs. Pinned, because a fixture that stops
# running is the one way a deleted check reports success.
readonly SELF_TEST_FIXTURES=6

log() {
  printf '\033[1;34m[check_cross_check_locked]\033[0m %s\n' "$*"
}

run_check() {
  local file="${REPO_ROOT}/${WORKFLOW}" calls unlocked
  [[ -f "${file}" ]] || { echo "ERROR: ${file} not found" >&2; return 2; }
  calls="$(grep -nE "${CARGO_CALL}" "${file}" | grep -vE '^[0-9]+:[[:space:]]*#' || true)"
  if [[ -z "${calls}" ]]; then
    printf '\033[1;31m[check_cross_check_locked] FAIL:\033[0m %s runs no cargo command: this guard would be checking nothing.\n' "${WORKFLOW}" >&2
    return 1
  fi
  unlocked="$(grep -vE '(^|[[:space:]])--locked([[:space:]]|$)' <<<"${calls}" || true)"
  if [[ -n "${unlocked}" ]]; then
    printf '%s\n' "${unlocked}" >&2
    printf '\033[1;31m[check_cross_check_locked] FAIL:\033[0m a cargo call in %s lacks --locked: it would build a graph the committed lockfile does not hold, which no lockfile guard reads.\n' "${WORKFLOW}" >&2
    return 1
  fi
  log "OK: $(grep -c . <<<"${calls}") cargo call(s) in ${WORKFLOW}, every one --locked."
}

self_test() {
  local tmp fails=0 checked=0 t
  tmp="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf '${tmp}'" RETURN

  _tree() { # <tree> <run line>...
    local t="$1"; shift
    mkdir -p "${t}/.github/workflows"
    {
      printf 'jobs:\n  apple:\n    steps:\n'
      printf '      # cargo check without the flag, in a comment, is no call\n'
      local line
      for line in "$@"; do printf '      - run: %s\n' "${line}"; done
    } >"${t}/${WORKFLOW}"
  }
  _case() { # _case <label> <want-rc> <tree>
    local label="$1" want="$2" got=0
    checked=$(( checked + 1 ))
    REPO_ROOT_OVERRIDE="$3" bash "${BASH_SOURCE[0]}" >/dev/null 2>&1 || got=$?
    if [[ "${got}" -eq "${want}" ]]; then
      printf '  \033[1;32mPASS\033[0m %s\n' "${label}"
    else
      printf '  \033[1;31mFAIL\033[0m %s (want rc=%d, got rc=%d)\n' "${label}" "${want}" "${got}" >&2
      fails=1
    fi
  }

  echo "check_cross_check_locked.sh --self-test"
  t="${tmp}/ok"; _tree "${t}" 'cargo check --locked --target aarch64-apple-ios' 'cargo check --target x86_64-pc-windows-msvc --locked'
  _case "every call locked passes, the flag before or after the target" 0 "${t}"

  t="${tmp}/one"; _tree "${t}" 'cargo check --locked --target aarch64-apple-ios' 'cargo check --target aarch64-linux-android'
  _case "one call without --locked fails" 1 "${t}"

  t="${tmp}/toolchain"; _tree "${t}" 'cargo check --locked --target aarch64-apple-ios' 'cargo +stable check --target aarch64-apple-ios'
  _case "a call naming a toolchain, without --locked, fails" 1 "${t}"

  t="${tmp}/lookalike"; _tree "${t}" 'cargo check --locked-ish --target aarch64-apple-ios'
  _case "a flag that only starts with --locked fails" 1 "${t}"

  t="${tmp}/none"; _tree "${t}" 'echo nothing to build'
  _case "a workflow with no cargo call fails" 1 "${t}"

  t="${tmp}/missing"; mkdir -p "${t}"
  _case "a missing workflow is a misconfiguration" 2 "${t}"

  if (( fails )); then
    echo "self-test: FAILED" >&2
    return 1
  fi
  if (( checked != SELF_TEST_FIXTURES )); then
    echo "self-test: ran ${checked} fixture(s), expected exactly ${SELF_TEST_FIXTURES}. A fixture was added or removed without moving the pin — the one way a deleted fixture reports success." >&2
    return 1
  fi
  echo "self-test: OK (${checked}/${SELF_TEST_FIXTURES} fixtures)"
}

case "${1:-}" in
  --self-test) self_test ;;
  '') run_check ;;
  *) echo "usage: $(basename "$0") [--self-test]" >&2; exit 2 ;;
esac
