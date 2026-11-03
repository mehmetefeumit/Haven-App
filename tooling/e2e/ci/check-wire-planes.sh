#!/usr/bin/env bash
#
# Relay-plane placement oracle over the E2E wire journal (backlog Workstream C,
# item C8): every client->relay EVENT, REQ and NEG-OPEN reached a listen whose
# declared roles admit it.
#
# A thin wrapper. The judge is the Rust binary `haven-wire-planes`
# (tooling/e2e/local-relay/src/planes), the one judge haven-core's tests, the
# soak rig and this lane share; its fixture suite runs as `cargo test` in
# rust-check.yml's e2e-tooling job. This script BUILDS NOTHING:
# start-wire-proxy.sh builds the binary in the same cargo invocation as the
# recording proxy, inside its capped step, so a lane that recorded has it. An
# absent binary is rc 3 (the instrument is not there), never a pass and never
# a build inside the oracle step, which has no time cap of its own.
#
# Every argument is handed to the binary unchanged and its exit code is this
# script's. The binary prints rule ids, role names, kind numbers, row ids,
# declaration ordinals and bucketed counts only; this script prints nothing of
# its own but the fixed absent-binary line, so no URL, port, listen, token or
# needle value can reach the step log through it (Security Rule 15).
#
# Written for bash 3.2: the iOS runners' /bin/bash.
#
# Usage:
#   check-wire-planes.sh --journal <path> --sentinel <token>
#                        --plane <role>=<ip>:<port>... [--exclude-conn <conn_id>]...
#                        [--declare-overlap <role>:<role>]...
#   check-wire-planes.sh --self-test
#
# Exit codes (the binary's, a closed set):
#   0  CLEAN       every rule C8.1-C8.8 held
#   1  VIOLATION   a frame crossed a plane
#   2  USAGE       the lane invoked the oracle wrong
#   3  UNUSABLE    the journal, a declaration or the binary itself is unusable
#   4  META-FLOOR  nothing provable: no anchor, an empty snapshot, a role never
#                  witnessed, missing ground truth

set -uo pipefail

SELF_PATH="${BASH_SOURCE[0]}"
SCRIPT_DIR="$(cd "$(dirname "${SELF_PATH}")" && pwd)"
readonly SELF_PATH SCRIPT_DIR
readonly BIN="${SCRIPT_DIR}/../local-relay/target/release/haven-wire-planes"
readonly RC_UNUSABLE=3
readonly ABSENT_TEXT="UNUSABLE: the haven-wire-planes binary is not built. start-wire-proxy.sh builds it beside the recording proxy; without it nothing was checked."

readonly SELF_TEST_CASES=11

run_self_test() {
  local tmp fail=0 ran=0 rc out want
  tmp="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf '${tmp}'" RETURN
  # A scratch tree shaped like the repo: the wrapper resolves the binary next
  # to itself, so a stub at that path is what it runs, and no real build on
  # this machine can stand in for the stub.
  mkdir -p "${tmp}/ci" "${tmp}/local-relay/target/release"
  cp "${SELF_PATH}" "${tmp}/ci/check-wire-planes.sh"
  local wrapper="${tmp}/ci/check-wire-planes.sh"
  local stub="${tmp}/local-relay/target/release/haven-wire-planes"
  # Planted values of every shape a lane hands the oracle; none may come back.
  local planted_journal="${tmp}/planted-journal-9f3a.ndjson"
  local planted_token="HAVEN_WIRE_SENTINEL:7c1d0e5b2a"
  local planted_listen="127.0.0.1:7788"
  local planted_conn="c4242"
  local -a args=(--journal "${planted_journal}" --sentinel "${planted_token}"
                 --plane "inbox=${planted_listen}" --plane "location=127.0.0.1:7789"
                 --exclude-conn "${planted_conn}" --declare-overlap inbox:discovery)

  leaks() { # leaks <file> — true when the output carries a planted value
    grep -qF -e "${planted_journal}" -e "${planted_token}" -e "${planted_listen}" \
      -e "7789" -e "${planted_conn}" "$1"
  }

  # 1. No binary: rc 3, the fixed line and nothing else.
  ran=$(( ran + 1 )); rc=0
  bash "${wrapper}" "${args[@]}" > "${tmp}/out" 2>&1 || rc=$?
  if (( rc != 3 )) || [[ "$(<"${tmp}/out")" != "${ABSENT_TEXT}" ]] || leaks "${tmp}/out"; then
    echo "SELF-TEST FAIL (absent binary): wanted rc 3 and only the fixed line, got rc ${rc}" >&2
    fail=1
  fi

  # 2. A file that cannot be executed is not a binary either.
  ran=$(( ran + 1 )); rc=0
  printf 'not a program\n' > "${stub}"
  chmod 0644 "${stub}"
  bash "${wrapper}" "${args[@]}" > "${tmp}/out" 2>&1 || rc=$?
  if (( rc != 3 )) || [[ "$(<"${tmp}/out")" != "${ABSENT_TEXT}" ]]; then
    echo "SELF-TEST FAIL (non-executable binary): wanted rc 3, got rc ${rc}" >&2
    fail=1
  fi

  # 3-8. Every exit code passes through unchanged, an undocumented one too: the
  # lane's verdict() names a code outside {0..4} as a broken oracle, so the
  # wrapper must not normalise it away.
  local code
  for code in 0 1 2 3 4 5; do
    ran=$(( ran + 1 )); rc=0
    printf '#!/usr/bin/env bash\nexit %d\n' "${code}" > "${stub}"
    chmod 0755 "${stub}"
    bash "${wrapper}" "${args[@]}" > "${tmp}/out" 2>&1 || rc=$?
    if (( rc != code )) || [[ -s "${tmp}/out" ]]; then
      echo "SELF-TEST FAIL (exit ${code} passthrough): got rc ${rc} or wrapper output" >&2
      fail=1
    fi
  done

  # 9. The arguments reach the binary verbatim, in order, one per argv slot.
  ran=$(( ran + 1 )); rc=0
  cat > "${stub}" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$@" > "${tmp}/argv"
SH
  chmod 0755 "${stub}"
  bash "${wrapper}" "${args[@]}" > "${tmp}/out" 2>&1 || rc=$?
  want="$(printf '%s\n' "${args[@]}")"
  if (( rc != 0 )) || [[ "$(<"${tmp}/argv")" != "${want}" ]]; then
    echo "SELF-TEST FAIL (argument passthrough): the binary did not receive the lane's arguments verbatim" >&2
    fail=1
  fi

  # 10. The wrapper adds nothing to a run: a silent binary yields a silent step.
  ran=$(( ran + 1 ))
  if [[ -s "${tmp}/out" ]] || leaks "${tmp}/out"; then
    echo "SELF-TEST FAIL (no value echoed): the wrapper printed output of its own" >&2
    fail=1
  fi

  # 11. The binary's own output is the step's output, unaltered.
  ran=$(( ran + 1 )); rc=0
  printf '#!/usr/bin/env bash\necho "C8.1 VIOLATION: crossed-event: kind 445 (row EV-445A) on a listen carrying inbox: 1"\nexit 1\n' > "${stub}"
  bash "${wrapper}" "${args[@]}" > "${tmp}/out" 2>&1 || rc=$?
  if (( rc != 1 )) || [[ "$(<"${tmp}/out")" != "C8.1 VIOLATION: crossed-event: kind 445 (row EV-445A) on a listen carrying inbox: 1" ]]; then
    echo "SELF-TEST FAIL (output passthrough): the binary's report did not reach the step unaltered" >&2
    fail=1
  fi

  if (( fail )); then
    echo "check-wire-planes: SELF-TEST FAILED" >&2
    return 1
  fi
  if (( ran != SELF_TEST_CASES )); then
    echo "check-wire-planes: SELF-TEST FAILED — ran ${ran} case(s), expected exactly ${SELF_TEST_CASES}; a case was added or removed without moving the pin" >&2
    return 1
  fi
  echo "check-wire-planes: self-test passed (${ran}/${SELF_TEST_CASES} cases: an absent or non-executable binary is rc 3 with a fixed line, every exit code and every argument passes through unchanged, and the wrapper prints no value of its own)."
  return 0
}

if [[ "${1:-}" == "--self-test" ]]; then
  run_self_test
  exit $?
fi

if [[ ! -f "${BIN}" || ! -x "${BIN}" ]]; then
  echo "${ABSENT_TEXT}" >&2
  exit "${RC_UNUSABLE}"
fi
exec "${BIN}" "$@"
