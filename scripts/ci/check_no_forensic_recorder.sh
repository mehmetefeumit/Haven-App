#!/usr/bin/env bash
# CI guard: Haven never installs an MDK forensic recorder (Security Rule 15).
#
# MDK's engine can write an audit trail through a `ForensicRecorder`, and the
# rows it writes carry raw group-ref hex and relay URLs (v0.10.4
# `marmot-forensics/src/audit.rs`); `JsonlRecorder` puts them in a file on disk.
# The engine defaults to a no-op recorder, so the trail exists only if Haven
# installs one. The install paths are the session and engine builders'
# `.recorder(..)`, `AccountDeviceSession::set_audit_recorder` and the engine's
# `set_recorder`, and every one of them takes a `ForensicRecorder`.
#
# Same flat shape as check_no_kp_lifetime_override.sh: none of the tokens below
# appears in any file under the scanned roots, comments included. Prose can say
# "MDK's audit trail"; a flat ban needs no comment parsing a rewording could
# sidestep.
#
# Pure grep, no toolchain.
#
# Usage:
#   bash scripts/ci/check_no_forensic_recorder.sh
#   bash scripts/ci/check_no_forensic_recorder.sh --self-test
#
# Exit codes:
#   0  no token found (or the self-test passed)
#   1  a token appears (or the self-test failed)
#   2  a scanned root is missing (misconfiguration)

set -euo pipefail

REPO_ROOT="${REPO_ROOT_OVERRIDE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
readonly -a SCAN_ROOTS=(haven-core/src haven-core/tests haven/rust_builder/src tooling/soak/src tooling/soak/tests)
readonly -a TOKENS=(set_recorder set_audit_recorder ForensicRecorder JsonlRecorder marmot_forensics '.recorder(')

# How many fixtures the self-test runs. Pinned, because a fixture that stops
# running is the one way a deleted check reports success.
readonly SELF_TEST_FIXTURES=8

log() {
  printf '\033[1;34m[check_no_forensic_recorder]\033[0m %s\n' "$*"
}

run_check() {
  local root hits
  local -a patterns=()
  for root in "${SCAN_ROOTS[@]}"; do
    [[ -d "${REPO_ROOT}/${root}" ]] || { echo "ERROR: ${REPO_ROOT}/${root} not found" >&2; return 2; }
  done
  for root in "${TOKENS[@]}"; do patterns+=(-e "${root}"); done
  hits="$(cd "${REPO_ROOT}" && grep -rnF "${patterns[@]}" "${SCAN_ROOTS[@]}" 2>/dev/null || true)"
  if [[ -n "${hits}" ]]; then
    printf '%s\n' "${hits}" >&2
    printf '\033[1;31m[check_no_forensic_recorder] FAIL:\033[0m an MDK forensic recorder is named above — its rows carry raw group ids and relay URLs, and Haven installs none (Rule 15).\n' >&2
    return 1
  fi
  log "OK: no MDK forensic recorder is installed (${#SCAN_ROOTS[@]} roots)."
}

self_test() {
  local tmp fails=0 checked=0 t token r
  tmp="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf '${tmp}'" RETURN

  _tree() { # <tree>
    for r in "${SCAN_ROOTS[@]}"; do
      mkdir -p "$1/${r}"
      printf 'fn open() { let _ = SessionConfig::new(); recorder_count(); }\n' >"$1/${r}/lib.rs"
    done
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

  echo "check_no_forensic_recorder.sh --self-test"
  t="${tmp}/ok"; _tree "${t}"
  _case "a tree naming no recorder passes (a bare 'recorder' identifier is not an install)" 0 "${t}"

  # One plant per token, rotated across the roots so each root is proven read.
  local i=0
  for token in "${TOKENS[@]}"; do
    t="${tmp}/plant-${i}"; _tree "${t}"
    r="${SCAN_ROOTS[$(( i % ${#SCAN_ROOTS[@]} ))]}"
    printf '// session.%s\n' "${token}" >"${t}/${r}/planted.rs"
    _case "'${token}' in ${r} (in a comment) fails" 1 "${t}"
    i=$(( i + 1 ))
  done

  t="${tmp}/missing"; _tree "${t}"; rm -r "${t}/tooling/soak/tests"
  _case "a missing root is a misconfiguration" 2 "${t}"

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
