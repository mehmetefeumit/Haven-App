#!/usr/bin/env bash
#
# Drives Haven's relay-CUSTOMIZATION Flutter integration tests on the
# action-booted emulator-5554, ONE target at a time, against TWO
# hermetic strfry relays (the relay-customization CI lane).
#
# This is the two-relay sibling of run-integration-tests.sh. The three
# targets it drives:
#
#   integration_test/relay_customization_publish_test.dart   (service-FFI wire proofs)
#   integration_test/relay_customization_trigger_test.dart   (provider bug-catcher)
#   integration_test/relay_resync_convergence_test.dart      (MIP-01 relay-update convergence)
#   integration_test/relay_two_plane_privacy_test.dart       (two-plane no-leak proof)
#
# # Why TWO relays
#
# These tests prove that when a user CUSTOMIZES their relay set, Haven
# actually honors the customization — events land on the chosen relay
# and NOT (only) on the default. A single relay cannot prove that: if
# there is only one relay, "published to the custom relay" and
# "published to the default relay" are indistinguishable. So the lane
# runs a SECOND, DISTINCT relay (R2) that stands in for the custom
# relay, distinct from R1 (the default). The targets read two
# dart-defines baked at build time:
#
#   HAVEN_E2E_RELAY    R1 = ws://10.0.2.2:7777  (the default relay)
#   HAVEN_E2E_RELAY_2  R2 = ws://10.0.2.2:7778  (the custom relay)
#
# `flutter drive` does NOT re-pass dart-defines, so both values are
# compiled into each APK by the workflow's pre-emulator build step;
# this driver only resets relays, stages the prebuilt APK, and drives.
#
# # Two relays => distinct container / port / data-dir
#
# start-strfry.sh / stop-strfry.sh manage exactly ONE relay each, keyed
# by STRFRY_CONTAINER / STRFRY_PORT / STRFRY_DATA_DIR. Their defaults
# are the R1 relay: container `strfry`, port `7777`, data dir
# `/tmp/strfry-data`. CRITICALLY, start-strfry.sh `docker rm -f`s its
# own container name on start and `rm -rf`s its own DATA_DIR — so if R2
# reused R1's name/port/dir, starting R2 would KILL R1 and wipe its
# LMDB env. R2 therefore MUST use a distinct identity:
#
#   STRFRY_CONTAINER=strfry2  STRFRY_PORT=7778  STRFRY_DATA_DIR=/tmp/strfry2-data
#
# # Per-target reset of BOTH relays (isolation)
#
# The integration targets use deterministic per-actor seeds (Alice
# [0x01;32], Bob [0x02;32], Carol [0x03;32]); their events are
# byte-for-byte identical every run. Leftover events from a prior
# target — on EITHER relay — would be served back as stale state and
# poison the next target. So before each target we reset BOTH relays
# (stop + start, which wipes both LMDB envs), guaranteeing
# order-independence: the suite passes (or fails) the same way
# regardless of which target ran first.
#
# # Why pre-built APKs are passed in (the OOM trap)
#
# `flutter build apk` peaks at several GB (Rust-NDK + Gradle). Building
# WHILE the emulator + two strfry containers are resident is the
# historical cause of the silently-lost runner (see
# docs/E2E_TROUBLESHOOTING.md). So — exactly like the e2e_android and
# e2e_integration lanes — the workflow builds every target's APK in a
# dedicated step BEFORE the emulator boots and passes the staged path
# in here. This script then only stages each APK at the path
# run-single-avd-scenario.sh expects (/tmp/scenario.apk) and drives it;
# no Gradle runs while the emulator is up.
#
# For LOCAL runs you may omit the `=<apk>` part of an argument; this
# script then removes any stale /tmp/scenario.apk so
# run-single-avd-scenario.sh falls back to building that target itself.
#
# # Why a checked-in script
#
# The reactivecircus/android-emulator-runner action runs each line of a
# multi-line `script:` in a separate `sh -c`, dropping shell state
# (cd, vars, background PIDs). Wrapping the whole loop in one
# `bash <path>` invocation keeps state coherent — same rationale as the
# other tooling/e2e/ci scripts.
#
# Usage:
#   bash tooling/e2e/ci/run-relay-customization.sh \
#     <target.dart>[=<prebuilt.apk>] [<target.dart>[=<prebuilt.apk>] ...]
#
# Example (CI, pre-built APKs):
#   bash tooling/e2e/ci/run-relay-customization.sh \
#     integration_test/relay_customization_publish_test.dart=/tmp/relay-custom-apks/relay_customization_publish_test.apk \
#     integration_test/relay_customization_trigger_test.dart=/tmp/relay-custom-apks/relay_customization_trigger_test.apk \
#     integration_test/relay_resync_convergence_test.dart=/tmp/relay-custom-apks/relay_resync_convergence_test.apk
#
# Example (local, build-on-demand):
#   bash tooling/e2e/ci/run-relay-customization.sh \
#     integration_test/relay_customization_publish_test.dart \
#     integration_test/relay_customization_trigger_test.dart \
#     integration_test/relay_resync_convergence_test.dart
#
# Required env (set by the workflow before invoking this script):
#   HAVEN_E2E_RELAY    R1 WebSocket URL (default: ws://10.0.2.2:7777),
#                      forwarded to run-single-avd-scenario.sh.
#   HAVEN_E2E_RELAY_2  R2 WebSocket URL (default: ws://10.0.2.2:7778) —
#                      informational here (baked into the APK at build
#                      time), kept for parity / local invocation.
#
# Optional env (forwarded to start-strfry.sh / stop-strfry.sh for R1):
#   STRFRY_IMAGE, STRFRY_READY_TIMEOUT  — see start-strfry.sh. R2 always
#                      uses its own fixed container/port/data-dir below.
#
# Side effects:
#   - Per target, overwrites /tmp/adb-logcat.log and
#     /tmp/flutter-drive.log (run-single-avd-scenario.sh), then copies
#     them to /tmp/relay-custom-logs/<slug>.{logcat,drive}.log so a
#     later target can't clobber an earlier failure's evidence.
#   - Resets BOTH strfry containers + their data dirs between targets.

set -euo pipefail

# Per-target `flutter drive` timeout, exported so run-single-avd-scenario.sh
# (invoked by run_one for each target) bounds every drive. Same reasoning as
# run-integration-tests.sh: these targets are small — the measured per-target
# drive here is ~90 s — so 10m is a generous ceiling.
#
# This lane used to inherit run-single-avd-scenario.sh's 20m default, which was
# sized for the long single-target e2e_combined flow, not for a four-target
# loop. The cost was measurable: across 34 successful runs (ci.yml, 2026-07/08)
# the emulator step ran p95 6.5 min but MAX 25.8 min, on a GREEN run where one
# target wedged on cold attach, burned the full 20m, and then passed on the
# retry below. At 20m that shape could not fit under any step deadline that
# also fits under the job cap; at 10m the same shape costs ~16 min (plus up to
# the 120 s install-broadcast barrier per install since 2026-09-10), so the
# retry — which exists precisely for that attach flake — can actually complete
# inside the lane's bounds instead of being SIGKILLed mid-recovery.
# CI_HARDENING_BACKLOG.md A8.
export HAVEN_DRIVE_TIMEOUT="${HAVEN_DRIVE_TIMEOUT:-10m}"

# The log-privacy gate (logscan_gate_dir): one implementation for every
# runner, sourced BEFORE the --self-test dispatch so the self-test exercises a
# runner wired exactly like the real one.
# shellcheck source=tooling/e2e/ci/logscan-gate.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/logscan-gate.sh"

# Where this runner's gate writes its findings report (sink:line, class, rule
# ids — never a value). Outside LOG_DIR, which the workflow uploads whole.
readonly LOGSCAN_REPORT="/tmp/logscan-report-relay-customization.ndjson"

# --self-test — hermetic: no device, no docker, no relay. Two things are under
# test. (1) CONTAINMENT: through logscan-gate.sh's floor arm with a FAKE
# scanner, a leak (rc 1) removes every *.log under the evidence directory and
# nothing else; rc 3 and rc 0 leave it untouched; the verdict comes back
# unchanged. (2) THE WIRING, read from this file: the gate library is sourced,
# the real call site hands LOG_DIR to logscan_gate_dir with the report outside
# it, and no soft `if [[ -x …` gate is in front of the scanner — an unbuilt
# scanner would be skipped, not fatal.
run_self_test() {
  local tmp fail=0 dir fake want rc real_run
  tmp="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf '${tmp}'" RETURN
  fake="${tmp}/fake-scan.sh"
  printf '%s\n' '#!/usr/bin/env bash' 'exit "${FAKE_SCAN_RC}"' > "${fake}"
  dir="${tmp}/logs"
  for want in 1 3 0; do
    rm -rf "${dir}"
    mkdir -p "${dir}/nested"
    printf 'a\n' > "${dir}/iter-3.logcat.log"
    printf 'b\n' > "${dir}/nested/drive.log"
    printf 'c\n' > "${dir}/notes.txt"
    rc=0
    HAVEN_LOGSCAN= SECRET_SCAN="${fake}" FAKE_SCAN_RC="${want}" \
      logscan_gate_dir host "${tmp}/needles" "${dir}" "${tmp}/report.ndjson" 2>/dev/null || rc=$?
    if (( rc != want )); then
      echo "SELF-TEST FAIL: the gate returned ${rc} for a scanner rc of ${want}" >&2
      fail=1
    fi
    if (( want == 1 )); then
      if [[ -e "${dir}/iter-3.logcat.log" || -e "${dir}/nested/drive.log" ]]; then
        echo "SELF-TEST FAIL: a leak (rc 1) left a scanned *.log on disk for the" \
             "if: always() upload to publish" >&2
        fail=1
      fi
      if [[ ! -e "${dir}/notes.txt" ]]; then
        echo "SELF-TEST FAIL: rc 1 removed a file the scan never walked" >&2
        fail=1
      fi
    elif [[ ! -e "${dir}/iter-3.logcat.log" || ! -e "${dir}/nested/drive.log" ]]; then
      echo "SELF-TEST FAIL: scanner rc ${want} touched a directory it had no leak to contain" >&2
      fail=1
    fi
  done
  real_run="$(sed -n '1,/^run_self_test() {/p' "${BASH_SOURCE[0]}"; sed -n '/^if \[\[ "${1:-}" == "--self-test" \]\]; then/,$p' "${BASH_SOURCE[0]}")"
  real_run="$(grep -v '^[[:space:]]*#' <<<"${real_run}")"
  if ! grep -qE '^source .*/logscan-gate\.sh"$' <<<"${real_run}"; then
    echo "SELF-TEST FAIL (wiring): logscan-gate.sh is no longer sourced" >&2
    fail=1
  fi
  if (( "$(grep -cE '^logscan_gate_dir host /tmp/haven-soak/needles "\$\{LOG_DIR\}" "\$\{LOGSCAN_REPORT\}" "\$\{SEAL_EXTRA\[@\]\}"' <<<"${real_run}")" != 1 )); then
    echo "SELF-TEST FAIL (wiring): expected exactly one gate call over LOG_DIR with the report outside it" >&2
    fail=1
  fi
  # The segment claim, and that it is DERIVED: the aggregate gate says how many
  # drive transcripts must be under LOG_DIR, and the number is the argument
  # list's own length taken before the loop. Without it a target whose log
  # never reached the directory is invisible — the files that did land still
  # clear the summed floor and still carry the reporter's proof_of_run. The
  # mutation below is why the pin is worth having: a constant satisfies the
  # gate's argv just as well and certifies whatever landed.
  local count_line loop_at
  count_line="$(grep -n -m1 '^readonly TARGET_COUNT=\$#$' "${BASH_SOURCE[0]}" || true)"
  count_line="${count_line%%:*}"
  loop_at="$(grep -n -m1 '^for spec in "$@"; do' "${BASH_SOURCE[0]}" || true)"
  loop_at="${loop_at%%:*}"
  if [[ -z "${count_line}" || -z "${loop_at}" ]] || (( count_line > loop_at )) \
     || (( "$(grep -cF -- '--segments "drive=${TARGET_COUNT}"' <<<"${real_run}")" != 1 )); then
    echo "SELF-TEST FAIL (wiring): the aggregate gate must claim one drive transcript per target spec, from a count taken before the loop (count='${count_line:-none}', loop='${loop_at:-none}')" >&2
    fail=1
  fi
  if (( "$(grep -cF -- '--segments "drive=${TARGET_COUNT}"' \
            <<<"$(sed 's/--segments "drive=${TARGET_COUNT}"/--segments "drive=4"/' "${BASH_SOURCE[0]}")")" != 0 )); then
    echo "SELF-TEST FAIL (wiring): a segment count frozen to a literal would still satisfy the pin above, which would then certify whatever landed rather than what this run drove" >&2
    fail=1
  fi
  # The rc-124 retry re-runs a target through the SHARED capture and the single
  # `cp` files it under the target's one slug, so a retried target adds no
  # second file and the claim above stays exactly the number of specs.
  if (( "$(grep -cE '^  cp /tmp/flutter-drive\.log "\$\{LOG_DIR\}/\$\{s\}\.drive\.log" 2>/dev/null \|\| true$' <<<"${real_run}")" != 1 )); then
    echo "SELF-TEST FAIL (wiring): a target's transcript must be copied exactly once, under its own slug — a second copy would make the retry add a segment the claim does not expect" >&2
    fail=1
  fi
  if grep -qE 'if[[:space:]]+\[\[[[:space:]]+-x[[:space:]]' <<<"${real_run}"; then
    echo "SELF-TEST FAIL (wiring): a soft \`if [[ -x …\` scanner gate is in the real run" >&2
    fail=1
  fi
  local seal_line loop_line
  seal_line="$(grep -n -m1 '^logscan_seal host /tmp/haven-soak/needles "${SEAL_EXTRA\[@\]}" || seal_rc=$?$' "${BASH_SOURCE[0]}")"
  seal_line="${seal_line%%:*}"
  loop_line="$(grep -n -m1 '^for spec in "$@"; do' "${BASH_SOURCE[0]}")"
  loop_line="${loop_line%%:*}"
  if [[ -z "${seal_line}" || -z "${loop_line}" ]] || (( seal_line > loop_line )) \
     || ! grep -qE '^readonly -a SEAL_EXTRA=\(--floor drive=18 --floor logcat=300 --floor relay=7 --exempt-endpoint "\$\{HAVEN_E2E_RELAY_2:-ws://10\.0\.2\.2:7778\}"\)$' "${BASH_SOURCE[0]}"; then
    echo "SELF-TEST FAIL (wiring): the lane's manifest must be sealed once, with its drive, logcat and relay floors, before the first target (seal='${seal_line:-none}', loop='${loop_line:-none}')" >&2
    fail=1
  fi
  # …and that drive floor stays derived from what the HOST prints, never from a
  # transcript's length. Each target is gated as `drive=<final>,<full>` (run-
  # single-avd-scenario.sh) and the floor SUMS a class's files, so the fixture
  # is both: the runner's own attempt banner, `Installing …`, the six
  # `VMServiceFlutterDriver:` connect lines (four unconditional, two the
  # `kPauseStart` branch `--start-paused` guarantees — see the seal below) and
  # the driver script's verdict —
  # interleaved with forwarded device chatter, exactly as a real capture is.
  local host_printed_re printed_final printed_full drive_floor
  host_printed_re='^(===== flutter drive attempt |Installing |VMServiceFlutterDriver: |All tests passed\.|Failure Details:)'
  printf '%s\n' \
    '===== flutter drive attempt 1/3 (rc=0, preconnect_stall=0) =====' \
    'Installing /tmp/scenario.apk...                 1,196ms' \
    'D/FlutterGeolocator( 5487): Creating service.' \
    'VMServiceFlutterDriver: Connecting to Flutter application at <endpoint>' \
    'VMServiceFlutterDriver: Isolate found with number: <n>' \
    'VMServiceFlutterDriver: Isolate <n> is runnable.' \
    'VMServiceFlutterDriver: Isolate is paused at start.' \
    'VMServiceFlutterDriver: Attempting to resume isolate' \
    'VMServiceFlutterDriver: Connected to Flutter application.' \
    'I/flutter ( 5487): 00:00 +0: (setUpAll)' \
    'I/flutter ( 5487): 00:21 +6: All tests passed!' \
    'All tests passed.' > "${tmp}/host-printed.full.drive.log"
  cp "${tmp}/host-printed.full.drive.log" "${tmp}/host-printed.final.drive.log"
  printed_full="$(grep -cE "${host_printed_re}" "${tmp}/host-printed.full.drive.log" || true)"
  printed_final="$(grep -cE "${host_printed_re}" "${tmp}/host-printed.final.drive.log" || true)"
  drive_floor="$(sed -n -E 's/^readonly -a SEAL_EXTRA=\(--floor drive=([0-9]+) .*/\1/p' "${BASH_SOURCE[0]}")"
  if (( printed_final != 9 || printed_full != 9 )); then
    echo "SELF-TEST FAIL (drive floor): a target's two slices carry ${printed_final} and ${printed_full} host-printed line(s), not the 9 each every complete transcript of this lane carries — the check below would be measuring the wrong thing" >&2
    fail=1
  elif [[ -z "${drive_floor}" ]] || (( drive_floor < 1 )) \
       || (( drive_floor > printed_final + printed_full )); then
    echo "SELF-TEST FAIL (drive floor): drive=${drive_floor:-none} is not within the $(( printed_final + printed_full )) line(s) the host prints for a target's two gated slices. A drive floor is calibrated to those lines alone; a higher one was measured from a transcript that also carried forwarded logcat furniture, which is not a property of the run (CI run 35464818348). 'A test ran' is the scanner's proof_of_run, not this number." >&2
    fail=1
  fi
  # Both relay logs are only evidence if they are read out of LIVE containers
  # and written where the aggregate gate still reaches them: after the target's
  # own reset (so they are this target's relays), before the gate (so they are
  # scanned), and exactly twice — one per relay, no more. The names are checked
  # through the walker's own predicate, so a change to the relay-name list
  # fails here rather than silently retyping a dump as a `diag` sink, where the
  # structural rules would read a relay's legitimate pubkeys and event ids as
  # leaks.
  local reset_line dump_line gate_line
  reset_line="$(grep -n -m1 '^  start_r2$' "${BASH_SOURCE[0]}" || true)"
  reset_line="${reset_line%%:*}"
  dump_line="$(grep -n -m1 '^  docker logs "${STRFRY_CONTAINER:-strfry}" > "${LOG_DIR}/strfry\.${s}\.log" 2>&1 || true$' "${BASH_SOURCE[0]}" || true)"
  dump_line="${dump_line%%:*}"
  gate_line="$(grep -n -m1 '^logscan_gate_dir host /tmp/haven-soak/needles "${LOG_DIR}"' "${BASH_SOURCE[0]}" || true)"
  gate_line="${gate_line%%:*}"
  if [[ -z "${reset_line}" || -z "${dump_line}" || -z "${gate_line}" ]] \
     || (( reset_line > dump_line || dump_line > gate_line )) \
     || (( "$(grep -cE '^[[:space:]]*docker logs ' <<<"${real_run}")" != 2 )) \
     || (( "$(grep -cF 'if [[ "${s}" == *logcat* || "${s}" == *drive* ]]; then' <<<"${real_run}")" != 1 )) \
     || ! grep -qF 'docker logs "${R2_CONTAINER}" > "${LOG_DIR}/strfry2.${s}.log"' "${BASH_SOURCE[0]}" \
     || ! logscan_is_relay_log "strfry.integration_test_relay_two_plane_privacy_test_dart.log" \
     || ! logscan_is_relay_log "strfry2.integration_test_relay_two_plane_privacy_test_dart.log"; then
    echo "SELF-TEST FAIL (wiring): both relay logs must be dumped from the live containers exactly once each, after the target's relay reset (line ${reset_line:-none}) and before the aggregate gate (line ${gate_line:-none}), under names logscan_gate_dir types as relay sinks and behind the slug check that refuses a target whose name the walker would match first (first dump line ${dump_line:-none})" >&2
    fail=1
  fi
  if grep -qE '(^|[;&|][[:space:]]*)[[:space:]]*(cat|head|tail|less|more)[[:space:]]+[^|]*\.log' <<<"${real_run}"; then
    echo "SELF-TEST FAIL (wiring): this runner echoes a captured log itself; only the AVD runner may, after its gate" >&2
    fail=1
  fi
  if (( fail )); then
    echo "run-relay-customization.sh: SELF-TEST FAILED" >&2
    return 1
  fi
  echo "run-relay-customization.sh: self-test passed (the log-privacy gate removes exactly the *.log files it scanned on a leak and touches nothing on rc 3 or rc 0; the gate library is sourced, the one gate call covers LOG_DIR with its report outside the upload and claims one drive transcript per target spec from a count taken before the loop — a literal in its place is refused, and the one per-target copy keeps a retried target at one file — no soft scanner gate, no captured-log echo of its own, the manifest is sealed once with the lane's drive, logcat and relay floors before the first target; each target's TWO relay logs are dumped from the live containers, typed as relay sinks, before the aggregate gate)."
  return 0
}

if [[ "${1:-}" == "--self-test" ]]; then
  run_self_test
  exit $?
fi

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <target.dart>[=<prebuilt.apk>] [<target.dart>[=<prebuilt.apk>] ...]" >&2
  exit 2
fi

# How many transcripts the aggregate gate must find (see its `--segments`
# claim). Taken from the argument list itself, before the loop consumes it, so
# adding a target to the workflow's invocation moves the claim by construction
# — a constant here would certify whatever landed. A target the rc-124 retry
# runs twice still writes ONE file: both drives go through the shared capture
# and the single `cp` below files it under the target's one slug.
readonly TARGET_COUNT=$#

# Resolve sibling scripts relative to this file so the workflow doesn't
# have to care about its cwd.
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SINGLE_AVD="${script_dir}/run-single-avd-scenario.sh"
readonly START_STRFRY="${script_dir}/start-strfry.sh"
readonly STOP_STRFRY="${script_dir}/stop-strfry.sh"
# The key-material floor the gate's flag-off arm runs (logscan-gate.sh reads it
# at call time); the flag-on arm runs it through scan-logs.sh.
readonly SECRET_SCAN="${script_dir}/scan-logs-for-secrets.sh"

for dep in "${SINGLE_AVD}" "${START_STRFRY}" "${STOP_STRFRY}" "${SECRET_SCAN}"; do
  if [[ ! -f "${dep}" ]]; then
    echo "ERROR: required helper not found: ${dep}" >&2
    exit 1
  fi
done

# R2's distinct identity. start-strfry.sh defaults R1 to
# strfry/7777/tmp/strfry-data; R2 MUST differ on all three so the R2
# start can't `docker rm -f` R1's container or `rm -rf` R1's data dir.
readonly R2_CONTAINER="strfry2"
readonly R2_PORT="7778"
readonly R2_DATA_DIR="/tmp/strfry2-data"

readonly STAGED_APK="/tmp/scenario.apk"
readonly LOG_DIR="/tmp/relay-custom-logs"
mkdir -p "${LOG_DIR}"
# The line floors this lane seals with. A floor is what turns "the scan read an
# empty or truncated file and found nothing" into rc 4 instead of a green, so
# each is calibrated to the part of a capture its PRODUCER always writes, never
# to what would make this lane pass.
#
# drive=18, the number its sibling run-integration-tests.sh derives, and it is
# deliberately NOT a transcript's length: a `flutter drive` transcript is the
# tool's own output INTERLEAVED with whatever logcat furniture the device
# happened to print, so its length is not a property of the run (this lane's
# shortest target measured 42, 43 and 45 lines across three green runs —
# 35311161479, 35376588206, 35397118356 — and the M7 lane's old, measured floor
# reddened a COMPLETE capture in CI run 35464818348). "A test actually ran" is
# the scanner's `proof_of_run` instead (tooling/logscan/policy.toml). What is
# left for this floor is an empty or truncated file, so it counts what the HOST
# prints: each target is gated as `drive=<final>,<full>` and a floor SUMS its
# class's files, so it is twice the per-slice skeleton — the runner's own
# `===== flutter drive attempt …` banner, `Installing …`, the six
# `VMServiceFlutterDriver:` connect lines (four unconditional; `Isolate is
# paused at start.` and `Attempting to resume isolate` are the `kPauseStart`
# branch of flutter_driver's vmservice_driver.dart, which `flutter drive`
# guarantees by defaulting `--start-paused` to true — nothing in drive mode
# resumes the root isolate, so another branch would mean a foreign debugger)
# and the driver script's verdict.
#
# logcat=300. The policy's 2000 is a device-wide capture of a whole scenario;
# this lane captures logcat PER TARGET, and its smallest complete slice
# measured is 874 lines (run 35397118356). 300 matches the sibling lane's
# floor, derived from the smaller 725-line slice there, and is far above the
# handful of lines a dead or mis-pathed capture yields. It is still a measured
# proxy — what proves this class reached the app's log backends is the `rust`
# and `kotlin` SHAPE plants the policy demands of it.
#
# relay=7. The policy's 1 is sized for the hermetic host relay, which prints a
# single listen line; this lane's relays are strfry, whose `docker logs` dump
# OPENS with a fixed 9-line startup block and grows only with traffic
# (9-49 lines across the fleet's green runs; exactly 9 for a target whose relay
# serves nothing it logs). 7 sits under the block every LIVE container prints,
# while one torn down before the dump yields ONE line of docker error text — so
# this floor tells those two apart without depending on how much traffic the
# target happened to generate.
#
# Sealed ONCE, before the first target: the host profile reuses the manifest at
# its out path, so the first seal's floors are the lane's — every later call
# passes the same arguments, R2's exemption included (infrastructure the lane
# names, never a needle).
readonly -a SEAL_EXTRA=(--floor drive=18 --floor logcat=300 --floor relay=7 --exempt-endpoint "${HAVEN_E2E_RELAY_2:-ws://10.0.2.2:7778}")
seal_rc=0
logscan_seal host /tmp/haven-soak/needles "${SEAL_EXTRA[@]}" || seal_rc=$?
if (( seal_rc != 0 )); then
  echo "ERROR: could not seal this lane's needle manifest (rc ${seal_rc}) — see the" \
       "line(s) above; every target's gate would fail the same way, so nothing" \
       "this run drives can be proven clean." >&2
  exit 1
fi

# Start/stop helpers for each relay. R1 uses the script defaults; R2
# overrides container/port/data-dir via env. STRFRY_IMAGE /
# STRFRY_READY_TIMEOUT (if set in the environment) flow through to both
# because start-strfry.sh reads them from the environment.
start_r1() { bash "${START_STRFRY}"; }
stop_r1()  { bash "${STOP_STRFRY}"; }
start_r2() {
  STRFRY_CONTAINER="${R2_CONTAINER}" \
  STRFRY_PORT="${R2_PORT}" \
  STRFRY_DATA_DIR="${R2_DATA_DIR}" \
    bash "${START_STRFRY}"
}
stop_r2() {
  STRFRY_CONTAINER="${R2_CONTAINER}" \
  STRFRY_DATA_DIR="${R2_DATA_DIR}" \
    bash "${STOP_STRFRY}"
}

# Tear down BOTH relays on ANY exit (pass, fail, or signal) so we never
# leak a container/data dir into a later step or a reused runner. The
# per-target loop also resets the relays before each target, so this
# trap is the final backstop. Each teardown is best-effort (`|| true`)
# so cleanup can't itself flip the script's exit code, and so a failed
# R1 stop doesn't skip the R2 stop.
cleanup() {
  stop_r1 >/dev/null 2>&1 || true
  stop_r2 >/dev/null 2>&1 || true
}
trap cleanup EXIT

# Reset BOTH relays for per-target isolation: stop each (idempotent),
# then start each fresh. start-strfry.sh wipes the data dir on start,
# so this guarantees an empty LMDB env on BOTH relays for every target
# regardless of what the previous target published to either one.
reset_relays() {
  echo "[relay] resetting R1 (${STRFRY_CONTAINER:-strfry}) and R2 (${R2_CONTAINER})"
  stop_r1 || true
  stop_r2 || true
  start_r1
  start_r2
}

# A filesystem-safe slug for a target path, used to name per-target log
# copies (integration_test/foo.dart -> integration_test_foo_dart).
slug() {
  printf '%s' "$1" | tr '/.' '__'
}

declare -a PASSED=()
declare -a FAILED=()
declare -a SKIPPED_BUILD=()

run_one() {
  local spec="$1"
  local target apk

  # Split "<target>=<apk>" (apk optional). A target path never contains
  # '=', so the first '=' is an unambiguous delimiter.
  if [[ "${spec}" == *"="* ]]; then
    target="${spec%%=*}"
    apk="${spec#*=}"
  else
    target="${spec}"
    apk=""
  fi

  if [[ -z "${target}" ]]; then
    echo "ERROR: empty target in argument '${spec}'" >&2
    # Record as a failure so a malformed argument fails the build
    # rather than being silently swallowed by the caller's `|| true`.
    FAILED+=("<empty-target:${spec}>")
    return 2
  fi

  echo "============================================================"
  echo "Relay-customization target: ${target}"
  echo "  prebuilt APK: ${apk:-<none — run-single-avd-scenario.sh will build>}"
  echo "============================================================"

  # --- Per-target reset of BOTH relays (isolation) ----------------
  # Wipe both LMDB envs BEFORE this target so deterministic-seed,
  # byte-identical events published by a prior target (on EITHER relay)
  # can't be served back as stale state and poison this one.
  reset_relays

  # --- Stage the APK at the path run-single-avd-scenario.sh expects.
  # If a prebuilt APK was supplied, copy it into place (it would
  # otherwise reuse whatever stale APK a previous target left there).
  # If none was supplied (local use), remove any stale staged APK so
  # run-single-avd-scenario.sh rebuilds for THIS target.
  if [[ -n "${apk}" ]]; then
    if [[ ! -f "${apk}" ]]; then
      echo "ERROR: prebuilt APK for ${target} not found at ${apk}" >&2
      # A misconfigured/missing prebuilt APK is a real failure (the
      # workflow's build step should have produced it) — record it so
      # the build fails instead of the caller's `|| true` hiding it.
      FAILED+=("${target}")
      return 1
    fi
    cp "${apk}" "${STAGED_APK}"
    echo "[apk] staged ${apk} -> ${STAGED_APK}"
  else
    rm -f "${STAGED_APK}"
    SKIPPED_BUILD+=("${target}")
    echo "[apk] no prebuilt APK; run-single-avd-scenario.sh will build ${target}"
  fi

  # --- Drive the target. run-single-avd-scenario.sh installs, grants
  # runtime permissions, and runs `flutter drive`. Its exit code is
  # flutter drive's (pipefail), so a genuine assertion failure / driver
  # error fails here. A `markTestSkipped` exits 0 on its own (the
  # reporter counts it as passed), so the scenario's drive-log check is
  # what turns a fired hatch red — see `expected_drive_skips.txt`. Only R1
  # (HAVEN_E2E_RELAY) is forwarded as env — R2 was baked into the APK
  # at build time; the drive step never re-passes dart-defines.
  local rc=0
  HAVEN_E2E_RELAY="${HAVEN_E2E_RELAY:-ws://10.0.2.2:7777}" \
    bash "${SINGLE_AVD}" "${target}" || rc=$?

  # Retry ONCE on a per-drive TIMEOUT only (rc=124). The first target in the
  # loop cold-attaches a snapshot-restored emulator, where `flutter drive`'s
  # VM-service attach can non-deterministically wedge until the per-drive
  # timeout even though the test body itself runs clean in <1 min (observed:
  # the publish target stalling 20 min with an empty log, then all tests
  # flushing at kill time). This is an attach/infra flake, NOT a test bug —
  # so retry exactly once after force-stopping any wedged app so the
  # re-attach is clean and hits a now-warm emulator. A REAL assertion/driver
  # failure exits with a deterministic NON-124 rc and is never retried, so a
  # genuine red never gets a second chance to flake green.
  if (( rc == 124 )); then
    echo "WARN: ${target} hit the per-drive timeout (rc=124) — likely a" \
      "cold-attach flake; force-stopping and retrying once."
    adb -s emulator-5554 shell am force-stop com.oblivioustech.haven || true
    rc=0
    HAVEN_E2E_RELAY="${HAVEN_E2E_RELAY:-ws://10.0.2.2:7777}" \
      bash "${SINGLE_AVD}" "${target}" || rc=$?
  fi

  # --- Preserve this target's evidence before the next target
  # overwrites the shared /tmp/*.log paths.
  local s
  s="$(slug "${target}")"
  cp /tmp/adb-logcat.log "${LOG_DIR}/${s}.logcat.log" 2>/dev/null || true
  cp /tmp/flutter-drive.log "${LOG_DIR}/${s}.drive.log" 2>/dev/null || true
  # BOTH relays' own logs, read out of the containers while they still exist.
  # `docker logs` against a torn-down container prints one line of error text,
  # and that is exactly what the workflow's post-run collection step uploaded
  # under this lane's relay names for as long as it existed: the EXIT trap and
  # the next target's reset both `docker rm -f` both containers long before a
  # workflow step runs, so the relay sink this lane certified was two docker
  # error messages, not two relay logs (CI run 35280144455). Here they are
  # still up — the next reset is the first thing the NEXT iteration does — and
  # the aggregate gate below still scans what lands in LOG_DIR. R2 is dumped
  # as well as R1 because the two-plane proof is about what each relay did and
  # did not receive, which is exactly what its own log records.
  # Both names must LEAD with `strfry` (logscan_gate_dir types `strfry*.log`
  # as a `relay` sink: structural rules off, the public classes scoped out)
  # and the slug must contain neither `logcat` nor `drive`, which the walker
  # matches first.
  if [[ "${s}" == *logcat* || "${s}" == *drive* ]]; then
    echo "ERROR: target slug '${s}' contains 'logcat' or 'drive', which" \
         "logscan_gate_dir matches BEFORE the relay-name list — the relay dumps" \
         "would be typed logcat or drive sinks, the structural rules would read" \
         "the relays' own pubkeys and event ids as leaks, and the rc 1 that" \
         "follows would delete this lane's evidence. Rename the target." >&2
    exit 2
  fi
  docker logs "${STRFRY_CONTAINER:-strfry}" > "${LOG_DIR}/strfry.${s}.log" 2>&1 || true
  docker logs "${R2_CONTAINER}" > "${LOG_DIR}/strfry2.${s}.log" 2>&1 || true

  if (( rc == 0 )); then
    echo "PASS: ${target}"
    PASSED+=("${target}")
  else
    echo "FAIL (rc=${rc}): ${target}"
    FAILED+=("${target}")
  fi
}

for spec in "$@"; do
  # Do NOT abort the whole suite on the first failing target — run them
  # all so one red target doesn't mask a second. We aggregate and fail
  # at the end if ANY target failed. `set -e` is intentionally not in
  # effect for the per-target call (run_one captures rc itself).
  run_one "${spec}" || true
done

# ---------------------------------------------------------------------------
# Secret-leak guard (Security Rule #6) over the AGGREGATED evidence directory.
#
# run-single-avd-scenario.sh already scans /tmp/adb-logcat.log and
# /tmp/flutter-drive.log after each drive — but only when it REACHES that scan.
# It runs under `set -e` from the moment it starts logcat, and has two earlier
# `exit 2` argument guards, so an install / build / config failure leaves the
# lane through a path that never scans. run_one's `cp` then copies those
# never-scanned logs into ${LOG_DIR}, which the workflow uploads with 14-day
# retention — i.e. the failure mode publishes precisely the material the inner
# guard exists to catch. Re-scanning the aggregate closes that window.
#
# This lane carries extra exposure: it drives TWO relays, so its logs contain
# more relay/identity chatter than the single-relay lanes. Each file is typed
# by its name (logcat / drive) and scanned against the manifest the first
# target's gate sealed for this run; R2 is exempted from the URL rules exactly
# as the AVD runner exempts it — infrastructure the lane names, never a needle.
#
# Deliberately placed BEFORE the summary's `exit 1` so it also runs on red
# runs: those are exactly the runs where the inner scan was likely skipped.
# The verdict is applied after the FAIL list is printed, so a leak never robs
# triage of the failing-target names (both outcomes are exit 1 regardless).
#
# `--segments drive=<targets>` is what makes "N drive logs" mean "N distinct
# drives". Nothing else here does: the class's line floor SUMS its files and
# its proof_of_run ORs them, so three complete transcripts certify a fourth
# target that never wrote one. The count is the argument list's own length, so
# it cannot be satisfied by whatever landed. A short walk is rc 3, and the
# cases that produce one are all already loud — a target that failed before its
# drive is in FAILED, and a per-target gate that contained a leak deleted the
# transcript it flagged and printed the LEAK line above. What this adds is the
# case nothing else covers: a target whose transcript is `cp`'d here out of the
# shared /tmp path the NEXT target overwrites, so one that died before writing
# it leaves no file at all — and the lane can still report success.
# ---------------------------------------------------------------------------
echo
echo "== Log-privacy gate over ${LOG_DIR} (Security Rules 6 and 15) =="
scan_rc=0
logscan_gate_dir host /tmp/haven-soak/needles "${LOG_DIR}" "${LOGSCAN_REPORT}" "${SEAL_EXTRA[@]}" \
  --segments "drive=${TARGET_COUNT}" || scan_rc=$?

echo
echo "============================================================"
echo "Relay-customization test summary"
echo "  passed:  ${#PASSED[@]}"
echo "  failed:  ${#FAILED[@]}"
echo "============================================================"
if (( ${#PASSED[@]} > 0 )); then
  printf '  PASS  %s\n' "${PASSED[@]}"
fi
if (( ${#SKIPPED_BUILD[@]} > 0 )); then
  echo "  (built on-demand, no prebuilt APK: ${#SKIPPED_BUILD[@]})"
fi
if (( ${#FAILED[@]} > 0 )); then
  printf '  FAIL  %s\n' "${FAILED[@]}"
  echo
  echo "ERROR: ${#FAILED[@]} relay-customization target(s) failed." >&2
  exit 1
fi

if (( scan_rc != 0 )); then
  echo "ERROR: log-privacy gate failed on ${LOG_DIR} (rc=${scan_rc}) — see the" \
       "line(s) above. rc=1 means key material or a declared identifier reached" \
       "the logs; rc=3 means a target's log was absent, unreadable or empty, or" \
       "fewer than the ${TARGET_COUNT} transcripts this run drove reached" \
       "${LOG_DIR} — if a per-target gate contained a leak it deleted the" \
       "transcript it flagged, and that LEAK line, not this one, is the" \
       "verdict." >&2
  exit 1
fi

echo "All relay-customization targets passed (skips, if any, are honest)."
exit 0
