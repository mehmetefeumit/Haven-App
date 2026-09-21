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
#   scan-logs.sh (--manifest <path>.needles.json | --manifest-dir <dir>) \
#                --sink <class>=<path>[,<path>...] \
#                [--sink ...] [--segments <class>=<n>]... [--plants-in <class>=<path>]... \
#                [--report <path>.ndjson]
#   scan-logs.sh --rules-only [--exempt-endpoint <url|host|ip>]... \
#                --sink <class>=<path>[,<path>...] [--sink ...] [--report <path>.ndjson]
#   scan-logs.sh --self-test
#
#   --manifest   the manifest `haven-logscan seal` wrote; must end in
#                `.needles.json`, and must be ONE path: a `*.needles.json` the
#                caller's shell left unexpanded is refused, never searched for
#   --manifest-dir  the run's needle directory, matched HERE under nullglob.
#                Exactly one match is scanned against; no match is the meta
#                floor, naming the directory and whether it exists at all (so
#                "the lane died before sealing" is told from "wrong
#                directory"); two or more is a broken guard, because choosing
#                one would scan this run's capture against another run's
#                needles — glob order would pick the LOWER run id, i.e. the
#                stale one. Callers pass this rather than a glob: an
#                unexpanded pattern reaches an argv parser as one literal or
#                as two paths, and neither shape can say which happened
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
#              a mis-shaped manifest, more than one manifest in the needle
#              directory, an expired allowlist entry, or a scanner exit code
#              outside the closed set
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
  echo "Usage: $0 (--manifest <path>.needles.json | --manifest-dir <dir>) --sink <class>=<path>[,<path>...]... [--segments <class>=<n>]... [--plants-in <class>=<path>]... [--report <path>.ndjson]  |  $0 --rules-only [--exempt-endpoint <url|host|ip>]... --sink <class>=<path>[,<path>...]... [--report <path>.ndjson]  |  $0 --self-test" >&2
}

# A pattern the caller's shell did not expand. `*.needles.json` arrives as this
# literal when nothing matched it, so a wrapper that took it as a path would
# report the honest "no manifest" red for a mistyped directory too.
holds_glob_char() {
  case "$1" in
    *'*'*|*'?'*|*'['*) return 0 ;;
  esac
  return 1
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
  local manifest="" manifest_dir="" report="" rules_only=0
  local -a sink_files=() scanner_args=() exempt_args=()
  local spec class paths part
  local -a parts

  [[ $# -gt 0 ]] || usage_error "no arguments"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --manifest)
        [[ $# -ge 2 ]] || usage_error "--manifest takes a path"
        [[ -z "${manifest}" ]] || usage_error "--manifest given twice (a second manifest means the needle directory was not rotated)"
        if holds_glob_char "$2"; then
          usage_error "--manifest takes one sealed manifest, and '${2##*/}' still holds a glob character: a pattern reached this wrapper unexpanded, so the caller's shell matched nothing. Pass --manifest-dir <dir> and let the wrapper match, say what it found, and refuse to choose"
        fi
        manifest="$2"
        shift 2
        ;;
      --manifest-dir)
        [[ $# -ge 2 ]] || usage_error "--manifest-dir takes a directory"
        [[ -z "${manifest_dir}" ]] || usage_error "--manifest-dir given twice"
        if holds_glob_char "$2"; then
          usage_error "--manifest-dir takes a directory, not a pattern, and '$2' still holds a glob character: the wrapper does the matching"
        fi
        manifest_dir="$2"
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
    [[ -z "${manifest}" && -z "${manifest_dir}" ]] || usage_error "--rules-only and --manifest/--manifest-dir are exclusive: a manifest means needles are declarable, so they must be searched"
  else
    (( ${#exempt_args[@]} == 0 )) || usage_error "--exempt-endpoint is for --rules-only: with a manifest the exemptions were sealed into it"
    [[ -z "${manifest}" || -z "${manifest_dir}" ]] || usage_error "--manifest and --manifest-dir are exclusive: one names the sealed manifest, the other asks this wrapper to find it"
    [[ -n "${manifest}" || -n "${manifest_dir}" ]] || usage_error "--manifest or --manifest-dir is required (or --rules-only for a sink no needle is declarable for)"
    # The suffix is the contract the sidecar guard keys its bans on; a manifest
    # under another name is a manifest nothing protects. What --manifest-dir
    # resolves carries the suffix by construction — it matched on it.
    [[ -z "${manifest}" || "${manifest}" == *.needles.json ]] \
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

  # The needle directory is read AFTER the floor, for the floor's reason:
  # containment must no more depend on the directory having been rotated than
  # on the scanner having been built.
  local manifest_rc=0
  if [[ -n "${manifest_dir}" ]]; then
    local -a found=()
    local had_nullglob=0
    if shopt -q nullglob; then had_nullglob=1; fi
    shopt -s nullglob
    found=("${manifest_dir}"/*.needles.json)
    (( had_nullglob )) || shopt -u nullglob
    if (( ${#found[@]} == 1 )); then
      manifest="${found[0]}"
    elif (( ${#found[@]} == 0 )); then
      local state="holds no *.needles.json, so this run sealed none — the lane died before it could"
      [[ -d "${manifest_dir}" ]] || state="is not an existing directory, so nothing could have sealed into it"
      echo "ERROR: the needle directory ${manifest_dir} ${state}. A scan with no" \
           "manifest proves only that the structural rules ran; fix the lane, or" \
           "the directory this was pointed at." >&2
      manifest_rc="${RC_META}"
    else
      echo "ERROR: the needle directory ${manifest_dir} holds ${#found[@]} manifests," \
           "and this wrapper will not choose one: glob order would take the lowest" \
           "run id, i.e. the STALE file, and scan this run's capture against another" \
           "run's needles. Rotate the directory before the run seals." >&2
      manifest_rc="${RC_GUARD}"
    fi
  fi

  local bin="${HAVEN_LOGSCAN_BIN:-${DEFAULT_LOGSCAN_BIN}}" scan_rc=0
  if [[ ! -f "${bin}" || ! -x "${bin}" ]]; then
    echo "ERROR: haven-logscan is not an executable file at ${bin}. Build it" \
         "(cargo build --release --manifest-path tooling/logscan/Cargo.toml) or" \
         "point HAVEN_LOGSCAN_BIN at one. An absent scanner is a broken guard," \
         "never a skipped scan." >&2
    scan_rc="${RC_GUARD}"
  elif (( manifest_rc )); then
    # No manifest resolved; the block above has already said which case it is.
    scan_rc="${manifest_rc}"
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
  if (( rules_only )); then
    basis="rules-only, no manifest"
  elif [[ -z "${manifest}" ]]; then
    basis="no manifest resolved from the needle directory"
  fi
  echo "scan-logs: $(verdict_word "${rc}") (rc ${rc}) — key-material floor rc ${floor_rc}," \
       "identifier scanner rc ${scan_rc}; ${#sink_files[@]} sink file(s); ${basis}"
  exit "${rc}"
}

# --self-test — the wrapper's OWN logic, driven end to end through a
# subprocess with the SHARED fake scanner injected via HAVEN_LOGSCAN_BIN and
# the REAL key-material floor. The fake parses the real binary's argv contract,
# records what it ACCEPTED in FAKE_SCAN_ARGV and exits with FAKE_SCAN_RC; the
# floor is driven with its own real patterns (a `secret: Some([…])` line), so
# the integration under test is the actual one. Every fixture count is
# pinned by equality: a deleted fixture is the one way a self-test reports
# success for work it did not do.
readonly SELF_TEST_FIXTURES=64
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

  # The SHARED fake, never one written here: a fake this file authored could
  # only record what it was handed, so it would answer a renamed flag exactly
  # as it answers a working one — the shape that cost CI run 35536892150 a
  # whole Android matrix. This wrapper does not source logscan-gate.sh, so it
  # resolves the same fixture beside itself; cli_contract.rs is where the fake
  # is held to the real binary's argv contract.
  local fake="${script_dir}/fixtures/fake-haven-logscan.sh" argv="${tmp}/argv"
  ran=$(( ran + 1 ))
  if [[ ! -f "${fake}" || ! -x "${fake}" ]]; then
    echo "SELF-TEST FAIL (fake scanner): ${fake} is missing or not an executable" \
         "file; every fixture below would exercise this wrapper's absent-binary" \
         "arm instead of its scanner arm and still pass" >&2
    fail=1
  fi
  # ...and it is a PARSER, not a yes-machine. repo-guards.yml runs this
  # self-test with no cargo, so cli_contract.rs — which ties the fake's
  # vocabulary to the binary's — is not beside it; without this control every
  # fixture below would prove only that SOMETHING ran.
  local control_rc=0
  bash "${fake}" scan --sink "logcat=${tmp}/absent.log" --no-such-flag x >/dev/null 2>&1 \
    || control_rc=$?
  ran=$(( ran + 1 ))
  if (( control_rc != RC_GUARD )); then
    echo "SELF-TEST FAIL (fake scanner): the injected fake answered rc ${control_rc}" \
         "for a flag the real scanner does not have; a fake that accepts every" \
         "command line cannot tell a working argv from a renamed one" >&2
    fail=1
  fi
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
  # The fake records ACCEPTED argv only, so an absent record no longer tells
  # "never invoked" from "invoked and refused" — both are rc 2. Its messages
  # are the binary's own (`haven-logscan: …`, `haven-logscan — …`); this
  # wrapper's are `ERROR:` plus its usage block. So both are asked.
  scanner_ran() {
    local rc=0
    if [[ ! -e "${argv}" ]]; then
      grep -qE '^haven-logscan( —|:)' "${tmp}/out" || rc=1
    fi
    return "${rc}"
  }
  never_ran() { # <what would have happened>
    ran=$(( ran + 1 ))
    if scanner_ran; then
      echo "SELF-TEST FAIL: $1" >&2
      fail=1
    fi
  }
  # A refused invocation records nothing, which is the mismatch to REPORT
  # rather than a reason to die reading a file that is not there.
  argv_text() {
    if [[ -e "${argv}" ]]; then
      printf '%s' "$(< "${argv}")"
    else
      printf '%s' '<nothing recorded: the scanner refused this argv, or was never invoked>'
    fi
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
    HAVEN_LOGSCAN_BIN="${bin}" FAKE_SCAN_RC="${fake_rc}" FAKE_SCAN_ARGV="${argv}" \
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
  never_ran "a usage error still ran the scanner"
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
  never_ran "--rules-only beside --manifest still ran the scanner"

  # (5b) --rules-only: no manifest, the floor still first, the scanner told so
  #      and nothing else re-derived; a leak still contains; the verdict line
  #      says what the scan was based on.
  reset_sinks
  expect "rules-only clean"                             0 kept    0 "${fake}" -- --rules-only --sink "logcat=${a}" --sink "drive=${b},${c}" --report "${tmp}/rules.ndjson"
  local -a want_rules=(scan --rules-only --sink "logcat=${a}" --sink "drive=${b},${c}" --report "${tmp}/rules.ndjson")
  local got
  got="$(argv_text)"
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
  got="$(argv_text)"
  ran=$(( ran + 1 ))
  if [[ "${got}" != "$(printf '%s\n' "${want_rules[@]}")" ]]; then
    echo "SELF-TEST FAIL: --exempt-endpoint reached the scanner as '${got//$'\n'/ }', expected '${want_rules[*]}'" >&2
    fail=1
  fi
  reset_sinks
  expect "exempt endpoint with a manifest is 2"         2 kept    0 "${fake}" -- "${sinks[@]}" --exempt-endpoint 127.0.0.1
  never_ran "--exempt-endpoint beside --manifest still ran the scanner"
  expect "exempt endpoint without a value"              2 kept    0 "${fake}" -- --rules-only --sink "logcat=${a}" --exempt-endpoint
  # --plants-in under --rules-only: this wrapper FORWARDS it, because mirroring
  # the scanner's mode policy here would be a second copy of it, and the
  # SCANNER's refusal is the verdict — rc 2, sinks kept, its own reason in the
  # log. Only a fake that parses can pin this; the inline one answered 0 and
  # the lane would have been the first to find out.
  reset_sinks
  expect "rules-only forwards --plants-in to its refusal" 2 kept  0 "${fake}" -- --rules-only --sink "logcat=${a}" --plants-in "drive=${b}"
  ran=$(( ran + 1 ))
  if ! grep -qF 'reconciles positive controls' "${tmp}/out"; then
    echo "SELF-TEST FAIL: --plants-in under --rules-only did not surface the scanner's own reason, so rc 2 says only that something was wrong" >&2
    fail=1
  fi

  # (5c) --manifest-dir: the needle directory resolved HERE, so the three cases
  #      a caller's `*.needles.json` collapses into stay apart. One match is
  #      today's scan; none is the meta floor and says whether the directory
  #      even exists; two is a broken guard that picks NEITHER (glob order
  #      would take the lower run id — the stale one); and a pattern that
  #      reached --manifest unexpanded is refused as such rather than read as
  #      "the lane sealed nothing".
  local nd_one="${tmp}/nd-one" nd_empty="${tmp}/nd-empty" nd_two="${tmp}/nd-two"
  local nd_gone="${tmp}/nd-gone"
  mkdir -p "${nd_one}" "${nd_empty}" "${nd_two}"
  printf '{}\n' > "${nd_one}/900001-1.needles.json"
  printf '{}\n' > "${nd_two}/900001-1.needles.json"
  printf '{}\n' > "${nd_two}/900002-1.needles.json"

  reset_sinks
  expect "one manifest in the dir scans"                0 kept    0 "${fake}" -- --manifest-dir "${nd_one}" --sink "logcat=${a}"
  want_rules=(scan --manifest "${nd_one}/900001-1.needles.json" --sink "logcat=${a}")
  got="$(argv_text)"
  ran=$(( ran + 1 ))
  if [[ "${got}" != "$(printf '%s\n' "${want_rules[@]}")" ]]; then
    echo "SELF-TEST FAIL: --manifest-dir reached the scanner as '${got//$'\n'/ }', expected '${want_rules[*]}'" >&2
    fail=1
  fi

  reset_sinks
  expect "an empty needle dir is the meta floor"        4 kept    0 "${fake}" -- --manifest-dir "${nd_empty}" --sink "logcat=${a}"
  ran=$(( ran + 1 ))
  if ! grep -qF "${nd_empty} holds no *.needles.json" "${tmp}/out"; then
    echo "SELF-TEST FAIL: an existing but empty needle directory did not report that it exists and sealed nothing" >&2
    fail=1
  fi
  never_ran "a run with no sealed manifest still invoked the scanner"

  reset_sinks
  expect "a missing needle dir is the meta floor too"   4 kept    0 "${fake}" -- --manifest-dir "${nd_gone}" --sink "logcat=${a}"
  ran=$(( ran + 1 ))
  if ! grep -qF "${nd_gone} is not an existing directory" "${tmp}/out"; then
    echo "SELF-TEST FAIL: a mistyped needle directory read as 'the lane sealed none', which is a different fact" >&2
    fail=1
  fi

  reset_sinks
  expect "two manifests is a broken guard"              2 kept    0 "${fake}" -- --manifest-dir "${nd_two}" --sink "logcat=${a}"
  ran=$(( ran + 1 ))
  if ! grep -qF 'holds 2 manifests' "${tmp}/out"; then
    echo "SELF-TEST FAIL: two manifests in the needle directory did not report the count" >&2
    fail=1
  fi
  ran=$(( ran + 1 ))
  if scanner_ran || grep -qF '900001-1.needles.json' "${tmp}/out"; then
    echo "SELF-TEST FAIL: two manifests still picked one — the capture would be scanned against another run's needles" >&2
    fail=1
  fi

  reset_sinks
  expect "a glob that reached --manifest is refused"    2 kept    0 "${fake}" -- --manifest "${nd_empty}/*.needles.json" --sink "logcat=${a}"
  ran=$(( ran + 1 ))
  if ! grep -qF 'reached this wrapper unexpanded' "${tmp}/out"; then
    echo "SELF-TEST FAIL: a pattern that reached --manifest unexpanded was not named as one" >&2
    fail=1
  fi
  expect "--manifest beside --manifest-dir is 2"        2 kept    0 "${fake}" -- --manifest "${manifest}" --manifest-dir "${nd_one}" --sink "logcat=${a}"
  expect "--rules-only beside --manifest-dir is 2"      2 kept    0 "${fake}" -- --rules-only --manifest-dir "${nd_one}" --sink "logcat=${a}"

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
  local -a want_argv=(scan --manifest "${manifest}" --sink "logcat=${a}" --sink "drive=${b},${c}" --segments logcat=1 --plants-in "drive=${b}" --report "${rep}")
  got="$(argv_text)"
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
  echo "scan-logs: self-test passed (${ran}/${SELF_TEST_FIXTURES} fixtures: the injected scanner is the ONE shared fake and it parses, refusing a flag the real binary does not have; verdicts fold 1 > 2 > 3 > 4 > 0 across both scanners, only a leak deletes and it deletes every sink, the key-material floor contains on its own and before the binary is looked for, an absent or non-executable scanner is rc 2 and never a skip, usage errors run nothing at all, arguments pass through untouched, --plants-in under --rules-only reaches the scanner and its refusal is the verdict, the report survives containment, the manifest is named by basename only, a needle directory resolves to exactly one manifest or to a named reason — empty, missing or holding several, never a choice between two — a pattern that reached --manifest unexpanded is refused as one, the gate keeps its hard-fail shape, and no bash-4-only construct is in the file)."
  return 0
}

if [[ "${1:-}" == "--self-test" ]]; then
  run_self_test
  exit $?
fi

main "$@"
