#!/usr/bin/env bash
#
# Log-privacy gate for captured E2E logs: ONE call, TWO scanners, ONE verdict.
#
# A lane hands this wrapper every log it captured, and the wrapper runs
#
#   1. `scan-logs-for-secrets.sh` — the toolchain-free KEY-MATERIAL floor
#      (Security Rule 6), over every named file, with its own exit code; and
#   2. `haven-logscan scan` — the runtime IDENTIFIER scanner (Security Rule
#      15), over the same files as typed sinks, against the run's sealed
#      needle manifest.
#
# This wrapper runs the key-material floor and the identifier scanner; policy
# lives in `tooling/logscan/policy.toml`. The floor's clean fixture is
# deliberately permissive about pubkeys and event ids — that is a statement of
# ITS scope, not a licence; the identifier scanner is where those are leaks.
#
# The two verdicts are folded as 1 > 2 > 3 > 4 > 0, and on a leak the wrapper
# CONTAINS: it deletes every named sink before returning, because the lane's
# failure is what triggers the `if: failure()` upload, and an upload that finds
# the file publishes the line the lane went red on. It never reads a sink or
# the manifest itself, never prints a matched value, and names the manifest by
# basename only — the manifest holds the run's declared identifiers verbatim.
#
# Fail-closed by construction: an absent or non-executable `haven-logscan` is
# rc 2, never a skipped scan (a soft `if [[ -x … ]]` gate is the shape under
# which a lane once went green having scanned nothing; the self-test pins its
# absence), and the floor runs BEFORE the binary is looked for, so containment
# on a key-material leak never depends on the scanner being built.
#
# Usage:
#   scan-logs.sh --manifest <path>.needles.json --sink <class>=<path>[,<path>...] \
#                [--sink ...] [--segments <class>=<n>]... [--plants-in <class>=<path>]... \
#                [--report <path>.ndjson]
#   scan-logs.sh --rules-only [--exempt-endpoint <url|host|ip>]... \
#                --sink <class>=<path>[,<path>...] [--sink ...] [--report <path>.ndjson]
#   scan-logs.sh --self-test
#
#   --manifest   the manifest `haven-logscan seal` wrote; must end in `.needles.json`
#   --rules-only no manifest: the structural rules and the line floors alone,
#                for a sink no needle is declarable for (a unit-test transcript).
#                It certifies that the rules ran, NOT that any declared value is
#                absent, so no device or simulator lane may use it — exactly one
#                of --manifest and --rules-only, never both
#   --exempt-endpoint  (--rules-only only) an endpoint the URL and IP rules
#                skip, in host, host:port and URL spellings: a rules-only scan
#                has no manifest to carry a sealed exemption (cargo prints an
#                `#[ignore]` reason naming http://127.0.0.1:<port>). With a
#                manifest the exemptions are sealed, so passing one here is rc 2
#   --sink       a sink CLASS (logcat, drive, ios, rust-test, relay, proxy, diag)
#                and the file(s) of that class, comma-separated; repeatable
#   --segments   how many rotated files the class is expected to have
#   --plants-in  reconcile the class's positive controls against this file only
#   --report     NDJSON findings (sink, line, class/encoding or rule, count —
#                never a value); must end in `.ndjson`
#   HAVEN_LOGSCAN_BIN  the scanner binary (default: the release build under
#                tooling/logscan/); read at call time so --self-test can inject
#                a fake, exactly as the runners inject a fake SECRET_SCAN
#
# Exit codes (the tree's closed set, aggregated 1 > 2 > 3 > 4 > 0):
#   0  clean — every sink present, above its floor, every plant caught, no hit
#   1  leak  — a needle or structural hit, or key material; EVERY named sink
#              has been deleted before this returns
#   2  guard broken — usage error, scanner binary absent or not executable,
#              a mis-shaped manifest, an expired allowlist entry, or a scanner
#              exit code outside the closed set
#   3  unusable — a sink absent/empty/unreadable, a segment count off, a plant
#              missed: fix the CAPTURE, not the app
#   4  meta floor — a line or declaration floor unmet, no manifest: fix the
#              SCENARIO
#   Sinks are kept on 2, 3 and 4 (nothing there is a proven leak); callers
#   treat any non-zero as fatal.

set -euo pipefail

readonly RC_CLEAN=0
readonly RC_LEAK=1
readonly RC_GUARD=2
readonly RC_UNUSABLE=3
readonly RC_META=4

SELF_PATH="${BASH_SOURCE[0]}"
readonly SELF_PATH
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly script_dir
readonly SECRET_SCAN="${script_dir}/scan-logs-for-secrets.sh"
readonly DEFAULT_LOGSCAN_BIN="${script_dir}/../../logscan/target/release/haven-logscan"

usage() {
  echo "Usage: $0 --manifest <path>.needles.json --sink <class>=<path>[,<path>...]... [--segments <class>=<n>]... [--plants-in <class>=<path>]... [--report <path>.ndjson]  |  $0 --rules-only [--exempt-endpoint <url|host|ip>]... --sink <class>=<path>[,<path>...]... [--report <path>.ndjson]  |  $0 --self-test" >&2
}

usage_error() {
  echo "ERROR: $*" >&2
  usage
  exit "${RC_GUARD}"
}

# worse <a> <b> — the verdict the caller must act on, 1 > 2 > 3 > 4 > 0. A code
# outside the closed set is itself a broken guard: a scanner that cannot name
# its verdict must not be read as clean.
worse() {
  local a="$1" b="$2" rc
  for rc in "${RC_LEAK}" "${RC_GUARD}" "${RC_UNUSABLE}" "${RC_META}"; do
    if [[ "${a}" == "${rc}" || "${b}" == "${rc}" ]]; then
      echo "${rc}"
      return
    fi
  done
  if [[ "${a}" == "${RC_CLEAN}" && "${b}" == "${RC_CLEAN}" ]]; then
    echo "${RC_CLEAN}"
    return
  fi
  echo "${RC_GUARD}"
}

verdict_word() {
  case "$1" in
    0) echo "clean" ;;
    1) echo "LEAK" ;;
    2) echo "GUARD BROKEN" ;;
    3) echo "UNUSABLE" ;;
    4) echo "META-FLOOR" ;;
    *) echo "UNDOCUMENTED rc $1" ;;
  esac
}

main() {
  local manifest="" report="" rules_only=0
  local -a sink_files=() scanner_args=() exempt_args=()
  local spec class paths part
  local -a parts

  [[ $# -gt 0 ]] || usage_error "no arguments"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --manifest)
        [[ $# -ge 2 ]] || usage_error "--manifest takes a path"
        [[ -z "${manifest}" ]] || usage_error "--manifest given twice (a second manifest means the needle directory was not rotated)"
        manifest="$2"
        shift 2
        ;;
      --rules-only)
        rules_only=1
        shift
        ;;
      --exempt-endpoint)
        [[ $# -ge 2 && -n "$2" && "$2" != *[[:space:]]* ]] \
          || usage_error "--exempt-endpoint takes <url|host|ip>"
        exempt_args+=(--exempt-endpoint "$2")
        shift 2
        ;;
      --sink)
        [[ $# -ge 2 ]] || usage_error "--sink takes <class>=<path>[,<path>...]"
        spec="$2"
        class="${spec%%=*}"
        paths="${spec#*=}"
        [[ "${spec}" == *=* && "${class}" =~ ^[a-z][a-z0-9-]*$ && -n "${paths}" ]] \
          || usage_error "--sink wants <class>=<path>[,<path>...], got '${spec}'"
        IFS=',' read -r -a parts <<<"${paths}"
        for part in "${parts[@]}"; do
          [[ -n "${part}" && "${part}" != *[[:space:]]* ]] \
            || usage_error "--sink ${class}: an empty or whitespace path in '${paths}'"
          sink_files+=("${part}")
        done
        scanner_args+=(--sink "${spec}")
        shift 2
        ;;
      --segments)
        [[ $# -ge 2 ]] || usage_error "--segments takes <class>=<n>"
        [[ "$2" =~ ^[a-z][a-z0-9-]*=[1-9][0-9]*$ ]] \
          || usage_error "--segments wants <class>=<positive integer>, got '$2'"
        scanner_args+=(--segments "$2")
        shift 2
        ;;
      --plants-in)
        [[ $# -ge 2 ]] || usage_error "--plants-in takes <class>=<path>"
        [[ "$2" =~ ^[a-z][a-z0-9-]*=[^[:space:],]+$ ]] \
          || usage_error "--plants-in wants <class>=<path>, got '$2'"
        scanner_args+=(--plants-in "$2")
        shift 2
        ;;
      --report)
        [[ $# -ge 2 ]] || usage_error "--report takes a path"
        [[ "$2" == *.ndjson && "$2" != *.needles.json ]] \
          || usage_error "--report must end in .ndjson, got '${2##*/}'"
        report="$2"
        shift 2
        ;;
      *)
        usage_error "unknown argument '$1'"
        ;;
    esac
  done
  if (( rules_only )); then
    [[ -z "${manifest}" ]] || usage_error "--rules-only and --manifest are exclusive: a manifest means needles are declarable, so they must be searched"
  else
    (( ${#exempt_args[@]} == 0 )) || usage_error "--exempt-endpoint is for --rules-only: with a manifest the exemptions were sealed into it"
    [[ -n "${manifest}" ]] || usage_error "--manifest is required (or --rules-only for a sink no needle is declarable for)"
    # The suffix is the contract the sidecar guard keys its bans on; a manifest
    # under another name is a manifest nothing protects.
    [[ "${manifest}" == *.needles.json ]] \
      || usage_error "--manifest must end in .needles.json, got '${manifest##*/}'"
  fi
  (( ${#sink_files[@]} > 0 )) || usage_error "at least one --sink is required"
  if [[ ! -f "${SECRET_SCAN}" ]]; then
    echo "ERROR: key-material floor missing at ${SECRET_SCAN}" >&2
    exit "${RC_GUARD}"
  fi

  # The floor first, and unconditionally: it needs no toolchain and no
  # manifest, so its containment never waits on the scanner being built.
  local floor_rc=0
  bash "${SECRET_SCAN}" "${sink_files[@]}" || floor_rc=$?

  local bin="${HAVEN_LOGSCAN_BIN:-${DEFAULT_LOGSCAN_BIN}}" scan_rc=0
  if [[ ! -f "${bin}" || ! -x "${bin}" ]]; then
    echo "ERROR: haven-logscan is not an executable file at ${bin}. Build it" \
         "(cargo build --release --manifest-path tooling/logscan/Cargo.toml) or" \
         "point HAVEN_LOGSCAN_BIN at one. An absent scanner is a broken guard," \
         "never a skipped scan." >&2
    scan_rc="${RC_GUARD}"
  else
    local -a report_args=() source_args=(--manifest "${manifest}")
    [[ -z "${report}" ]] || report_args=(--report "${report}")
    (( ! rules_only )) || source_args=(--rules-only ${exempt_args[@]+"${exempt_args[@]}"})
    "${bin}" scan "${source_args[@]}" "${scanner_args[@]}" \
      ${report_args[@]+"${report_args[@]}"} || scan_rc=$?
  fi

  local rc
  rc="$(worse "${floor_rc}" "${scan_rc}")"
  if [[ "${rc}" == "${RC_LEAK}" ]]; then
    rm -f -- "${sink_files[@]}"
    echo "ERROR: secret-leak guard tripped (see the LEAK line(s) above); removed" \
         "the scanned logs so the failure-artifact upload cannot publish them:" \
         "${sink_files[*]}" >&2
  fi
  local basis="manifest ${manifest##*/}"
  (( ! rules_only )) || basis="rules-only, no manifest"
  echo "scan-logs: $(verdict_word "${rc}") (rc ${rc}) — key-material floor rc ${floor_rc}," \
       "identifier scanner rc ${scan_rc}; ${#sink_files[@]} sink file(s); ${basis}"
  exit "${rc}"
}

# --self-test — the wrapper's OWN logic, driven end to end through a
# subprocess with a FAKE scanner injected via HAVEN_LOGSCAN_BIN and the REAL
# key-material floor. The fake records its argv and exits with FAKE_LOGSCAN_RC;
# the floor is driven with its own real patterns (a `secret: Some([…])` line),
# so the integration under test is the actual one. Every fixture count is
# pinned by equality: a deleted fixture is the one way a self-test reports
# success for work it did not do.
readonly SELF_TEST_FIXTURES=43
# The iOS lanes run this wrapper on macOS under /bin/bash 3.2 (no mapfile,
# no associative arrays, no case conversion); fixture (10) pins that
# statically, since macOS cannot be run here.
# bash-4-only: mapfile/readarray, coproc, declare -A, case conversion, |&, ;;&,
# negative substring offsets.
readonly BASH4_ONLY_RE='(^|[^[:alnum:]_])(mapfile|readarray|coproc)([^[:alnum:]_]|$)|declare[[:space:]]+-[a-zA-Z]*A|\$\{[A-Za-z_][A-Za-z0-9_]*(,,|\^\^)|\|&|;;&|\$\{[^}]*:([[:space:]]+-[0-9]|[0-9]+:[[:space:]]*-[0-9])'

run_self_test() {
  local tmp fail=0 ran=0
  tmp="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf '${tmp}'" RETURN

  local fake="${tmp}/fake-logscan" argv="${tmp}/argv"
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'printf "%s\n" "$@" > "${FAKE_ARGV_FILE}"' \
    'while [[ $# -gt 0 ]]; do if [[ "$1" == "--report" ]]; then : > "$2"; fi; shift; done' \
    'exit "${FAKE_LOGSCAN_RC}"' \
    > "${fake}"
  chmod +x "${fake}"
  local manifest="${tmp}/selftest.needles.json"
  printf '{}\n' > "${manifest}"

  local a="${tmp}/gate-a.log" b="${tmp}/gate-b.log" c="${tmp}/gate-c.log"
  reset_sinks() {
    printf 'I/flutter ( 111): started\n' > "${a}"
    printf 'I/flutter ( 111): still running\n' > "${b}"
    printf '00:03 +1: a scenario\n' > "${c}"
  }
  plant_key_material() { # into <file>
    printf 'D/keyring ( 111): Entry { secret: Some([1, 2, 3]) }\n' >> "$1"
  }

  # expect <label> <want-rc> <deleted|kept> <fake-rc> <bin> -- <args...>
  #   Runs the real wrapper as a subprocess and asserts its exit code and
  #   whether the three fixture sinks survived. `deleted` means ALL named sinks
  #   are gone; `kept` means EVERY one that existed beforehand still does.
  expect() {
    local label="$1" want="$2" fate="$3" fake_rc="$4" bin="$5"
    shift 5
    [[ "${1:-}" == "--" ]] && shift
    local -a existed=()
    local f
    for f in "${a}" "${b}" "${c}"; do [[ -e "${f}" ]] && existed+=("${f}"); done
    ran=$(( ran + 1 ))
    rm -f "${argv}"
    local rc=0
    HAVEN_LOGSCAN_BIN="${bin}" FAKE_LOGSCAN_RC="${fake_rc}" FAKE_ARGV_FILE="${argv}" \
      bash "${SELF_PATH}" "$@" > "${tmp}/out" 2>&1 || rc=$?
    if (( rc != want )); then
      echo "SELF-TEST FAIL (${label}): wanted rc ${want}, got ${rc}" >&2
      fail=1
    fi
    case "${fate}" in
      deleted)
        for f in "${a}" "${b}" "${c}"; do
          if [[ -e "${f}" ]]; then
            echo "SELF-TEST FAIL (${label}): a leak verdict left ${f##*/} on disk for the failure-artifact upload to publish" >&2
            fail=1
          fi
        done
        if ! grep -qF 'secret-leak guard tripped' "${tmp}/out"; then
          echo "SELF-TEST FAIL (${label}): the leak verdict did not print the evidence-withheld line" >&2
          fail=1
        fi
        ;;
      kept)
        for f in ${existed[@]+"${existed[@]}"}; do
          if [[ ! -e "${f}" ]]; then
            echo "SELF-TEST FAIL (${label}): rc ${rc} removed ${f##*/}, which it had no leak to contain" >&2
            fail=1
          fi
        done
        ;;
    esac
  }

  local -a sinks=(--manifest "${manifest}" --sink "logcat=${a}" --sink "drive=${b},${c}")

  # (1) Aggregation across the two scanners, floor clean, scanner rc varied.
  #     Only 1 contains; 2/3/4 keep; a code outside the closed set is 2.
  reset_sinks; expect "clean/clean is 0"                0 kept    0 "${fake}" -- "${sinks[@]}"
  reset_sinks; expect "scanner 1 contains"              1 deleted 1 "${fake}" -- "${sinks[@]}"
  reset_sinks; expect "scanner 2 keeps"                 2 kept    2 "${fake}" -- "${sinks[@]}"
  reset_sinks; expect "scanner 3 keeps"                 3 kept    3 "${fake}" -- "${sinks[@]}"
  reset_sinks; expect "scanner 4 keeps"                 4 kept    4 "${fake}" -- "${sinks[@]}"
  reset_sinks; expect "scanner rc outside the set is 2" 2 kept    7 "${fake}" -- "${sinks[@]}"

  # (2) The floor's own verdict: a key-material line contains on its own, and
  #     outranks an unusable scanner verdict.
  reset_sinks; plant_key_material "${b}"
  expect "floor leak contains"                          1 deleted 0 "${fake}" -- "${sinks[@]}"
  reset_sinks; plant_key_material "${a}"
  expect "floor leak outranks scanner 3"                1 deleted 3 "${fake}" -- "${sinks[@]}"

  # (3) An absent sink is the floor's rc 3; a leak elsewhere still outranks it
  #     and unusable outranks meta.
  reset_sinks; rm -f "${c}"
  expect "absent sink is 3"                             3 kept    0 "${fake}" -- "${sinks[@]}"
  reset_sinks; rm -f "${c}"
  expect "leak outranks an absent sink"                 1 deleted 1 "${fake}" -- "${sinks[@]}"
  reset_sinks; rm -f "${c}"
  expect "unusable outranks meta"                       3 kept    4 "${fake}" -- "${sinks[@]}"
  reset_sinks; : > "${b}"
  expect "guard outranks an empty sink"                 2 kept    2 "${fake}" -- "${sinks[@]}"

  # (4) The binary is REQUIRED. Absent, a directory, or present but not
  #     executable: rc 2, sinks kept — never a skip. And containment on a
  #     key-material leak does not wait for it.
  reset_sinks; expect "absent binary is 2"              2 kept    0 "${tmp}/no-such-binary" -- "${sinks[@]}"
  reset_sinks; expect "a directory is not a binary"     2 kept    0 "${tmp}" -- "${sinks[@]}"
  : > "${tmp}/not-executable"
  reset_sinks; expect "non-executable binary is 2"      2 kept    0 "${tmp}/not-executable" -- "${sinks[@]}"
  reset_sinks; plant_key_material "${c}"
  expect "floor contains without the binary"            1 deleted 0 "${tmp}/no-such-binary" -- "${sinks[@]}"

  # (5) Usage errors: rc 2 before anything runs (the fake is never invoked).
  reset_sinks
  expect "manifest without the suffix"                  2 kept    0 "${fake}" -- --manifest "${tmp}/wrong.json" --sink "logcat=${a}"
  if [[ -e "${argv}" ]]; then
    echo "SELF-TEST FAIL: a usage error still ran the scanner" >&2
    fail=1
  fi
  expect "no --manifest"                                2 kept    0 "${fake}" -- --sink "logcat=${a}"
  expect "two --manifest"                               2 kept    0 "${fake}" -- --manifest "${manifest}" --manifest "${manifest}" --sink "logcat=${a}"
  expect "no --sink"                                    2 kept    0 "${fake}" -- --manifest "${manifest}"
  expect "--sink without a class"                       2 kept    0 "${fake}" -- --manifest "${manifest}" --sink "=${a}"
  expect "--sink without a path"                        2 kept    0 "${fake}" -- --manifest "${manifest}" --sink "logcat="
  expect "--report without .ndjson"                     2 kept    0 "${fake}" -- "${sinks[@]}" --report "${tmp}/report.txt"
  expect "--segments not a count"                       2 kept    0 "${fake}" -- "${sinks[@]}" --segments "logcat=x"
  expect "--plants-in without a path"                   2 kept    0 "${fake}" -- "${sinks[@]}" --plants-in "drive="
  expect "unknown option"                               2 kept    0 "${fake}" -- "${sinks[@]}" --no-such-option
  expect "no arguments"                                 2 kept    0 "${fake}"
  expect "--rules-only with a manifest"                 2 kept    0 "${fake}" -- --rules-only "${sinks[@]}"
  if [[ -e "${argv}" ]]; then
    echo "SELF-TEST FAIL: --rules-only beside --manifest still ran the scanner" >&2
    fail=1
  fi

  # (5b) --rules-only: no manifest, the floor still first, the scanner told so
  #      and nothing else re-derived; a leak still contains; the verdict line
  #      says what the scan was based on.
  reset_sinks
  expect "rules-only clean"                             0 kept    0 "${fake}" -- --rules-only --sink "logcat=${a}" --sink "drive=${b},${c}" --report "${tmp}/rules.ndjson"
  local -a want_rules=(scan --rules-only --sink "logcat=${a}" --sink "drive=${b},${c}" --report "${tmp}/rules.ndjson")
  got="$(< "${argv}")"
  ran=$(( ran + 1 ))
  if [[ "${got}" != "$(printf '%s\n' "${want_rules[@]}")" ]]; then
    echo "SELF-TEST FAIL: --rules-only invoked the scanner with '${got//$'\n'/ }', expected '${want_rules[*]}'" >&2
    fail=1
  fi
  ran=$(( ran + 1 ))
  if ! grep -qF 'rules-only, no manifest' "${tmp}/out"; then
    echo "SELF-TEST FAIL: the rules-only verdict line does not say it ran without a manifest" >&2
    fail=1
  fi
  reset_sinks; plant_key_material "${a}"
  expect "rules-only floor leak contains"               1 deleted 0 "${fake}" -- --rules-only --sink "logcat=${a}" --sink "drive=${b},${c}"
  # An exempt endpoint rides a rules-only scan verbatim, repeatably; with a
  # manifest it is a usage error (the seal carried the exemptions).
  reset_sinks
  expect "rules-only exempt endpoints pass through"     0 kept    0 "${fake}" -- --rules-only --exempt-endpoint 127.0.0.1 --sink "rust-test=${a}" --exempt-endpoint http://127.0.0.1:4545
  want_rules=(scan --rules-only --exempt-endpoint 127.0.0.1 --exempt-endpoint http://127.0.0.1:4545 --sink "rust-test=${a}")
  got="$(< "${argv}")"
  ran=$(( ran + 1 ))
  if [[ "${got}" != "$(printf '%s\n' "${want_rules[@]}")" ]]; then
    echo "SELF-TEST FAIL: --exempt-endpoint reached the scanner as '${got//$'\n'/ }', expected '${want_rules[*]}'" >&2
    fail=1
  fi
  reset_sinks
  expect "exempt endpoint with a manifest is 2"         2 kept    0 "${fake}" -- "${sinks[@]}" --exempt-endpoint 127.0.0.1
  if [[ -e "${argv}" ]]; then
    echo "SELF-TEST FAIL: --exempt-endpoint beside --manifest still ran the scanner" >&2
    fail=1
  fi
  expect "exempt endpoint without a value"              2 kept    0 "${fake}" -- --rules-only --sink "logcat=${a}" --exempt-endpoint

  # (6) Pass-through: the scanner receives exactly the typed-sink arguments,
  #     nothing re-derived, and the report survives a leak (it holds sink:line
  #     and class only — never a value).
  reset_sinks
  local rep="${tmp}/findings.ndjson"
  expect "report survives a leak"                       1 deleted 1 "${fake}" -- "${sinks[@]}" --segments logcat=1 --plants-in "drive=${b}" --report "${rep}"
  if [[ ! -e "${rep}" ]]; then
    echo "SELF-TEST FAIL: the leak verdict deleted the findings report along with the sinks" >&2
    fail=1
  fi
  local got
  local -a want_argv=(scan --manifest "${manifest}" --sink "logcat=${a}" --sink "drive=${b},${c}" --segments logcat=1 --plants-in "drive=${b}" --report "${rep}")
  got="$(< "${argv}")"
  ran=$(( ran + 1 ))
  if [[ "${got}" != "$(printf '%s\n' "${want_argv[@]}")" ]]; then
    echo "SELF-TEST FAIL: the scanner was invoked with '${got//$'\n'/ }', expected '${want_argv[*]}'" >&2
    fail=1
  fi

  # (7) The manifest is named by basename only, in every line this wrapper
  #     prints — the full path is the one thing a job log must not learn.
  reset_sinks
  expect "clean run for the output check"               0 kept    0 "${fake}" -- "${sinks[@]}"
  ran=$(( ran + 1 ))
  if grep -qF "${manifest}" "${tmp}/out"; then
    echo "SELF-TEST FAIL: the wrapper printed the manifest's full path" >&2
    fail=1
  elif ! grep -qF "${manifest##*/}" "${tmp}/out"; then
    echo "SELF-TEST FAIL: the wrapper's verdict line no longer names the manifest" >&2
    fail=1
  fi

  # (8) THE SHAPE OF THE GATE, read from the real run (everything above this
  #     self-test, comments stripped): the binary is asserted with the hard-fail
  #     form, and the soft `if [[ -x … ]]` skip — under which an unbuilt scanner
  #     would be silently stepped over — is absent.
  local real_run
  real_run="$(sed -n '1,/^readonly SELF_TEST_FIXTURES=/p' "${SELF_PATH}" | grep -v '^[[:space:]]*#')"
  ran=$(( ran + 1 ))
  if grep -qE 'if[[:space:]]+\[\[[[:space:]]+-x[[:space:]]' <<<"${real_run}"; then
    echo "SELF-TEST FAIL (gate shape): a soft \`if [[ -x …\` scanner gate is in the real run — an absent scanner would be skipped, not fatal" >&2
    fail=1
  fi
  if ! grep -qF -- '[[ ! -f "${bin}" || ! -x "${bin}" ]]' <<<"${real_run}"; then
    echo "SELF-TEST FAIL (gate shape): the scanner's presence is no longer asserted with the hard-fail form" >&2
    fail=1
  fi
  # (9) ...and the real run never reads a sink or the manifest itself: no
  #     cat/head/tail/less/more/base64 at a command position.
  ran=$(( ran + 1 ))
  if grep -qE '(^|[;&|][[:space:]]*|\$\()[[:space:]]*(cat|head|tail|less|more|base64)([[:space:]]|$)' <<<"${real_run}"; then
    echo "SELF-TEST FAIL (no reads): the real run reads a file it was only asked to scan" >&2
    fail=1
  fi
  # (10) Runs on macOS's bash 3.2 too: no bash-4-only construct in this file.
  ran=$(( ran + 1 ))
  if grep -vF 'BASH4_ONLY_RE=' "${BASH_SOURCE[0]}" | grep -v '^[[:space:]]*#' \
       | grep -qE "${BASH4_ONLY_RE}"; then
    echo "SELF-TEST FAIL (bash 3.2): a bash-4-only construct is in this file (the constructs are listed at the regex definition); macOS's /bin/bash cannot run it" >&2
    fail=1
  fi

  if (( fail )); then
    echo "scan-logs: SELF-TEST FAILED" >&2
    return 1
  fi
  if (( ran != SELF_TEST_FIXTURES )); then
    echo "scan-logs: SELF-TEST FAILED — ran ${ran} fixture(s), expected exactly ${SELF_TEST_FIXTURES}; a fixture was added or removed without moving the pin" >&2
    return 1
  fi
  echo "scan-logs: self-test passed (${ran}/${SELF_TEST_FIXTURES} fixtures: verdicts fold 1 > 2 > 3 > 4 > 0 across both scanners, only a leak deletes and it deletes every sink, the key-material floor contains on its own and before the binary is looked for, an absent or non-executable scanner is rc 2 and never a skip, usage errors run nothing, arguments pass through untouched, the report survives containment, the manifest is named by basename only, the gate keeps its hard-fail shape, and no bash-4-only construct is in the file)."
  return 0
}

if [[ "${1:-}" == "--self-test" ]]; then
  run_self_test
  exit $?
fi

main "$@"
