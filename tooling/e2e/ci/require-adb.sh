#!/usr/bin/env bash
#
# The emulator action's `pre-emulator-launch-script`: proves the adb the action
# is about to poll runs, and when it does not, stops the action before it
# starts an emulator.
#
# ## Why
#
# `reactivecircus/android-emulator-runner` puts `<sdk>/platform-tools` on PATH,
# runs its own `sdkmanager --install … platform-tools …` with the output
# discarded, starts the emulator and polls `adb … getprop sys.boot_completed`
# every 2 s. In five jobs (137207551525, 137192122237, 137236468689,
# 137282691794, 140270147003) the emulator booted while every poll failed with
# "Unable to locate executable file: adb", for the whole boot timeout; the
# action's teardown is `adb emu kill`, so the emulator it could not reach kept
# the action's output open and the step hung to its timeout-minutes, 15 to 44
# minutes after the fault. provision-android-sdk.sh had graded platform-tools
# minutes earlier by its directory and manifest alone.
#
# The action runs this AFTER its own sdkmanager call and before it launches the
# emulator, with the PATH it will poll with, so this sees the adb the action
# will use. A failed pre-launch script only marks the action failed — it goes on
# to launch and poll — so on a failure this ends the action's process itself:
# the step fails within seconds, with no emulator running, and the job's
# `if: failure()` steps run. Either way it prints what the root cause needs:
# which adb PATH resolves, the platform-tools revision on disk (compare it with
# the one provision-android-sdk.sh logged) and the directory's contents.
#
# That report must not die with the action. What this script prints reaches the
# log only through the action, which reads it from a pipe and writes it on; a
# line still in that pipe when the action is killed is lost (a harness modelled
# on @actions/exec lost the `::error::` once in 260 runs). Flushing cannot help:
# bash's echo is already a write(2), and the bytes are lost in the reader. So
# the report is written straight to the action's own standard output, the pipe
# the runner reads (/proc/<pid>/fd/1, opened for append): once that write
# returns, the runner holds it whatever happens to the action, and only then is
# the action stopped. It is also appended to $GITHUB_STEP_SUMMARY, a file.
#
# Usage:
#   require-adb.sh               (the action's pre-emulator-launch-script)
#   require-adb.sh --self-test
#
# Exit codes:
#   0  adb resolves on PATH and `adb version` runs
#   3  it does not — infrastructure, no emulator was started and no test ran

set -euo pipefail

readonly SCRIPT_NAME="require-adb.sh"
readonly RC_NO_ADB=3
# `adb version` prints and exits without starting the server; this bounds a
# binary that hangs instead.
readonly ADB_PROBE_SECS=10
readonly PROBE_TAIL_LINES=6
# The action's own process, recognised by its path in the runner's action cache
# (…/_actions/reactivecircus/android-emulator-runner/<ref>/lib/main.js).
readonly ACTION_MARK="/android-emulator-runner/"

PROC_ROOT=/proc
# Where the walk to the action starts: the shell the action ran this under.
FROM_PID="${PPID}"

# action_pid <pid> — the nearest ancestor of <pid> (itself included) whose
# command line names the action, or nothing.
action_pid() {
  local pid="$1" cmdline ppid
  while [[ "${pid}" =~ ^[0-9]+$ ]] && (( pid > 1 )); do
    cmdline="$(tr '\0' ' ' 2>/dev/null < "${PROC_ROOT}/${pid}/cmdline" || true)"
    if [[ "${cmdline}" == *"${ACTION_MARK}"* ]]; then
      printf '%s\n' "${pid}"
      return 0
    fi
    # Field 4 of stat, read past the parenthesised command name, which may
    # itself hold spaces or parentheses.
    ppid="$(sed -E 's/^.*\) [A-Za-z] ([0-9]+) .*$/\1/' "${PROC_ROOT}/${pid}/stat" 2>/dev/null || true)"
    [[ "${ppid}" != "${pid}" ]] || return 0
    pid="${ppid}"
  done
  return 0
}

stop_action() { kill -TERM "$1"; }

# pt_revision — the platform-tools Pkg.Revision sdkmanager recorded.
pt_revision() {
  local props="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-}}/platform-tools/source.properties"
  if [[ -f "${props}" ]]; then sed -n 's/^Pkg\.Revision=//p' "${props}"; else printf 'unrecorded\n'; fi
}

# evidence — what explains a missing adb, for the root cause.
evidence() {
  local sdk="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-}}"
  echo "${SCRIPT_NAME}: PATH entries naming platform-tools:"
  tr ':' '\n' <<<"${PATH}" | grep -n 'platform-tools' | sed 's/^/    | /' || echo "    | (none)"
  if [[ -z "${sdk}" ]]; then
    echo "${SCRIPT_NAME}: neither ANDROID_HOME nor ANDROID_SDK_ROOT is set."
    return 0
  fi
  echo "${SCRIPT_NAME}: platform-tools revision on disk: $(pt_revision)"
  echo "${SCRIPT_NAME}: ${sdk}/platform-tools holds:"
  ls -la "${sdk}/platform-tools" 2>&1 | sed 's/^/    | /' || true
}

require_adb() {
  local adb probe_out probe_rc=0 why pid verdict report=""
  # bash's lookup falls back to a NON-executable match, so -x decides.
  adb="$(command -v adb || true)"
  if [[ -z "${adb}" || ! -x "${adb}" ]]; then
    why="no executable adb on the PATH the emulator action polls with"
  else
    probe_out="$(timeout "${ADB_PROBE_SECS}" "${adb}" version 2>&1)" || probe_rc=$?
    if (( probe_rc == 0 )); then
      printf '%s: OK — %s: %s; platform-tools revision on disk: %s\n' "${SCRIPT_NAME}" "${adb}" \
        "$(head -n 1 <<<"${probe_out}")" "$(pt_revision)"
      return 0
    fi
    why="\`${adb} version\` exited ${probe_rc}"
    report="${SCRIPT_NAME}: its last lines:"$'\n'"$(tail -n "${PROBE_TAIL_LINES}" <<<"${probe_out}" | sed 's/^/    | /')"$'\n'
  fi
  verdict="${SCRIPT_NAME}: ${why}. This is INFRASTRUCTURE, not a product failure: the emulator action would poll adb for its whole boot timeout and then hang on a teardown it cannot run, so it is stopped here, before it starts an emulator; no test ran."
  report+="$(evidence)"$'\n'"::error::${verdict}"$'\n'
  if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
    printf '### Emulator step stopped: no runnable adb\n\n%s\n\n```\n%s```\n' "${verdict}" "${report}" >> "${GITHUB_STEP_SUMMARY}" || true
  fi
  pid="$(action_pid "${FROM_PID}")"
  if [[ -z "${pid}" ]]; then
    printf '%s' "${report}"
    echo "::error::${SCRIPT_NAME}: no ancestor process is the emulator action, so nothing was stopped."
    return "${RC_NO_ADB}"
  fi
  # Past the action's relay, so the kill cannot drop it; where the action's
  # descriptor cannot be opened, through the relay as before.
  { printf '%s' "${report}" >> "${PROC_ROOT}/${pid}/fd/1"; } 2>/dev/null || printf '%s' "${report}"
  stop_action "${pid}"
  return "${RC_NO_ADB}"
}

# ---------------------------------------------------------------------------
# Self-test: a stub adb on a PATH of its own, and a fake process table.
# ---------------------------------------------------------------------------
readonly SELF_TEST_FIXTURES=8

# fake_proc <root> <pid> <ppid> <cmdline…> — one process of the fake table.
fake_proc() {
  local root="$1" pid="$2" ppid="$3"
  shift 3
  mkdir -p "${root}/${pid}"
  printf '%s\0' "$@" > "${root}/${pid}/cmdline"
  printf '%s (%s) S %s 1 1 0\n' "${pid}" "$(basename "$1") (x)" "${ppid}" > "${root}/${pid}/stat"
}

run_self_test() {
  local tmp ran=0 fail=0 rc out
  # The CI step running this has a summary of its own, which no fixture writes.
  unset GITHUB_STEP_SUMMARY
  tmp="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf '${tmp}'" RETURN
  mkdir -p "${tmp}/ok/platform-tools" "${tmp}/bad/platform-tools" "${tmp}/none/platform-tools" "${tmp}/bin"
  printf '%s\n' '#!/usr/bin/env bash' '[[ "$*" == version ]] || exit 9' 'echo "Android Debug Bridge version 1.0.41"' > "${tmp}/ok/platform-tools/adb"
  printf '%s\n' '#!/usr/bin/env bash' 'echo "error while loading shared libraries: libc++.so" >&2' 'exit 127' > "${tmp}/bad/platform-tools/adb"
  chmod +x "${tmp}/ok/platform-tools/adb" "${tmp}/bad/platform-tools/adb"
  printf 'Pkg.Revision=36.0.1\n' > "${tmp}/ok/platform-tools/source.properties"
  printf 'Pkg.Revision=36.0.2\n' > "${tmp}/none/platform-tools/source.properties"
  : > "${tmp}/none/platform-tools/adb"
  # The commands this script runs, and nothing named adb.
  local c
  for c in bash tr grep sed ls head tail basename timeout cat mkdir; do
    ln -s "$(command -v "${c}")" "${tmp}/bin/${c}"
  done

  # The process table: this script under the action's shell under the action.
  PROC_ROOT="${tmp}/proc"
  fake_proc "${PROC_ROOT}" 4100 1 /home/runner/externals/node24/bin/node \
    /home/runner/work/_actions/reactivecircus/android-emulator-runner/v2/lib/main.js
  fake_proc "${PROC_ROOT}" 4200 4100 /usr/bin/sh -c "bash tooling/e2e/ci/require-adb.sh"
  # The action's standard output, the runner's pipe, is a file here.
  mkdir -p "${PROC_ROOT}/4100/fd"
  # Records the stop, as `unreported` when the ::error:: was not yet in the
  # action's output: a kill sent before it would lose it.
  stop_action() {
    if grep -qF '::error::' "${PROC_ROOT}/$1/fd/1" 2>/dev/null; then printf '%s\n' "$1"; else echo unreported; fi >> "${tmp}/stopped"
  }

  # _run <sdk dir> — the check, with that SDK's platform-tools as the only adb:
  # `relayed` is what it printed (what the action passes on), `direct` what it
  # wrote to the action's own standard output, `out` both.
  local relayed direct
  _run() {
    rc=0; rm -f "${tmp}/stopped" "${tmp}/summary"; : > "${PROC_ROOT}/4100/fd/1"
    relayed="$(ANDROID_HOME="$1" PATH="${tmp}/bin:$1/platform-tools" FROM_PID=4200 \
      GITHUB_STEP_SUMMARY="${tmp}/summary" require_adb 2>&1)" || rc=$?
    direct="$(cat "${PROC_ROOT}/4100/fd/1")"
    out="${relayed}${direct}"
  }

  # (a) A runnable adb passes, says which one and its revision, and stops
  #     nothing.
  ran=$(( ran + 1 )); _run "${tmp}/ok"
  if (( rc != 0 )) || [[ "${out}" != *"OK — ${tmp}/ok/platform-tools/adb: Android Debug Bridge version 1.0.41; platform-tools revision on disk: 36.0.1"* ]] || [[ -e "${tmp}/stopped" ]]; then
    echo "SELF-TEST FAIL (a): a runnable adb must pass, name itself and stop nothing; got rc=${rc}: ${out}" >&2; fail=1
  fi
  if [[ -e "${tmp}/summary" || -n "${direct}" ]]; then
    echo "SELF-TEST FAIL (a): a runnable adb must write no step summary and nothing past the action" >&2; fail=1
  fi

  # (b) No adb PATH resolves (here the file is there, not executable): rc 3,
  #     one ::error:: calling it infrastructure, the evidence, and the action —
  #     not the shell between — stopped.
  ran=$(( ran + 1 )); _run "${tmp}/none"
  if (( rc != RC_NO_ADB )) || [[ "${out}" != *"::error::${SCRIPT_NAME}: no executable adb on the PATH"*"INFRASTRUCTURE"*"no test ran"* ]] \
     || [[ "$(cat "${tmp}/stopped" 2>/dev/null)" != 4100 ]]; then
    echo "SELF-TEST FAIL (b): a missing adb must fail rc ${RC_NO_ADB} as infrastructure and stop the action's process (4100); got rc=${rc}, stopped '$(cat "${tmp}/stopped" 2>/dev/null)': ${out}" >&2; fail=1
  fi
  if [[ "${out}" != *"platform-tools revision on disk: 36.0.2"* ]] || [[ "${out}" != *"    | "*"adb"* ]] \
     || [[ "${out}" != *"${tmp}/none/platform-tools"* ]]; then
    echo "SELF-TEST FAIL (b): a missing adb must print the evidence — the PATH entry, the revision on disk and the directory listing; got: ${out}" >&2; fail=1
  fi

  # (b2) That report goes to the action's own standard output, once, and none
  #      of it through the action's relay, which the kill would cut; and the
  #      step summary holds the verdict and the evidence.
  ran=$(( ran + 1 ))
  if [[ "${direct}" != *"::error::${SCRIPT_NAME}: no executable adb"* || "${direct}" != *"revision on disk: 36.0.2"* ]] \
     || [[ "$(grep -c '::error::' <<<"${direct}")" != 1 || -n "${relayed}" ]]; then
    echo "SELF-TEST FAIL (b2): the verdict and evidence must be written once to the action's standard output and nothing relayed; relayed '${relayed}', direct '${direct}'" >&2; fail=1
  fi
  if ! grep -qF "${SCRIPT_NAME}: no executable adb on the PATH" "${tmp}/summary" 2>/dev/null \
     || ! grep -qF "revision on disk: 36.0.2" "${tmp}/summary"; then
    echo "SELF-TEST FAIL (b2): \$GITHUB_STEP_SUMMARY must hold the verdict and the evidence; got: $(cat "${tmp}/summary" 2>/dev/null)" >&2; fail=1
  fi

  # (c) An adb that does not run: its exit code and last lines, then the same.
  ran=$(( ran + 1 )); _run "${tmp}/bad"
  if (( rc != RC_NO_ADB )) || [[ "${out}" != *"version\` exited 127"* ]] || [[ "${out}" != *"libc++.so"* ]] \
     || [[ "$(cat "${tmp}/stopped" 2>/dev/null)" != 4100 ]]; then
    echo "SELF-TEST FAIL (c): an adb that fails must say how and stop the action; got rc=${rc}: ${out}" >&2; fail=1
  fi

  # (d) Outside the action nothing is stopped, and that is said.
  ran=$(( ran + 1 )); rc=0; rm -f "${tmp}/stopped"
  out="$(ANDROID_HOME="${tmp}/none" PATH="${tmp}/bin:${tmp}/none/platform-tools" FROM_PID=4100 PROC_ROOT="${tmp}/empty" require_adb 2>&1)" || rc=$?
  if (( rc != RC_NO_ADB )) || [[ -e "${tmp}/stopped" ]] || [[ "${out}" != *"no ancestor process is the emulator action"* ]]; then
    echo "SELF-TEST FAIL (d): with no action above it the check must fail without stopping anything, and say so; got rc=${rc}: ${out}" >&2; fail=1
  fi

  # (e) The walk: from the shell to the action, through a command name with
  #     spaces and parentheses, and nothing for a chain that never meets it.
  ran=$(( ran + 1 ))
  fake_proc "${PROC_ROOT}" 4300 4200 "/opt/odd (name)/bash" x
  if [[ "$(action_pid 4300)" != 4100 || "$(action_pid 4100)" != 4100 || -n "$(PROC_ROOT="${tmp}/empty" action_pid 4300)" ]]; then
    echo "SELF-TEST FAIL (e): the ancestor walk must find the action from below and from itself, and nothing in an empty table" >&2; fail=1
  fi

  # (f) End to end on the real process table: the script, run with no adb
  #     under a process whose command line names the action, ends that
  #     process with SIGTERM before the process could print "survived".
  #     The script's own output is discarded, the worst a relay cut by the
  #     kill can do, and the ::error:: must still be in the action's output.
  ran=$(( ran + 1 ))
  rc=0
  out="$(ANDROID_HOME="${tmp}/none" PATH="${tmp}/bin:${tmp}/none/platform-tools" \
    "${BASH}" -c 'exec -a "node /x/android-emulator-runner/v2/lib/main.js" "${BASH}" -c "\"\${BASH}\" \"\$0\" >/dev/null 2>&1; echo survived" "$0"' \
    "${BASH_SOURCE[0]}" 2>&1)" || rc=$?
  if (( rc != 143 )) || [[ "${out}" == *survived* ]]; then
    echo "SELF-TEST FAIL (f): a missing adb under the action must end the action's process with SIGTERM (rc 143); got rc=${rc}: ${out}" >&2; fail=1
  fi
  ran=$(( ran + 1 ))
  if [[ "${out}" != *"::error::${SCRIPT_NAME}: no executable adb on the PATH"* ]]; then
    echo "SELF-TEST FAIL (f2): the ::error:: must reach the action's own output before the kill, not depend on the action relaying it; got: ${out}" >&2; fail=1
  fi

  if (( fail != 0 )); then
    echo "${SCRIPT_NAME}: SELF-TEST FAILED" >&2
    return 1
  fi
  if (( ran != SELF_TEST_FIXTURES )); then
    echo "${SCRIPT_NAME}: SELF-TEST FAILED — ran ${ran} fixture(s), expected exactly ${SELF_TEST_FIXTURES}" >&2
    return 1
  fi
  echo "${SCRIPT_NAME}: self-test passed (${ran}/${SELF_TEST_FIXTURES} fixtures: a runnable adb passes and names itself; one PATH does not resolve, or one whose \`version\` fails, is rc ${RC_NO_ADB} as infrastructure with the PATH entry, the revision on disk and the directory listing, and stops the emulator action's process — never the shell between — having first written that report to the action's own standard output, past the relay the kill would cut, and to the step summary; outside the action nothing is stopped and that is said; the ancestor walk survives a command name with spaces and parentheses; and, on the real process table, the action's process ends on a SIGTERM with the ::error:: already in its output)."
}

if [[ "${1:-}" == "--self-test" && $# -eq 1 ]]; then
  run_self_test
  exit $?
fi
if (( $# != 0 )); then
  echo "usage: ${SCRIPT_NAME}  |  ${SCRIPT_NAME} --self-test" >&2
  exit 2
fi
require_adb
