#!/usr/bin/env bash
#
# The log-privacy gate every lane runner calls: ONE function, ONE verdict, over
# every log a lane captured, BEFORE anything echoes or uploads it.
#
# Sourced by the runners (run-single-avd-scenario.sh keeps its log_privacy_gate
# as a thin call into this); run directly only for --self-test.
#
#   logscan_gate <profile> <needle-dir> [<extra seal arg>...] -- <wrapper arg>...
#
#     <profile>      proxy  the lane ran the recording proxy: the seal reads its
#                           `*.needles.decl` sidecar(s) — none is rc 3 — and
#                           adds the host needles (host-needles.sh) to them
#                    host   no proxy: the host needles are the whole
#                           declaration, sealed `--declared-plants none` — a
#                           plant proves the APP reached the sink, and only a
#                           lane with a declaration channel can hand the app a
#                           token to print, so a host lane has no Dart plants
#                           to reconcile (the rust/kotlin/swift shape plants
#                           are still required)
#                    rules  no seal at all; the wrapper runs `--rules-only`
#
#     Under either sealing profile a manifest already at the out path is THIS
#     run's — the job rotates the needle directory before its first capture
#     (check_logscan_wired_everywhere.sh (i)), so nothing older can be there
#     — sealed by an earlier gate in the same lane, and is reused: a
#     multi-target lane gates every target and then the aggregate, and
#     e2e-ios.yml gates two drives in one proxy session (the seal writes the
#     manifest `create_new`, so a second seal at the same run id would be rc
#     2 on every run). Reuse is right ONLY because the later gate declares
#     nothing the first did not: the mirror drive runs no TestRelay and the
#     host needles are constants. A proxy lane whose later target declared
#     NEW values over the channel would need a per-target run-id suffix, not
#     this reuse — its sidecar would be sealed by nobody.
#     <needle-dir>   where the sidecars are read and the manifest is written
#     <extra>        appended to the seal argv verbatim: a lane's `--expect`
#                    floors, its own `--host-decl coordinate=…`, further
#                    `--exempt-endpoint`s
#     <wrapper arg>  scan-logs.sh's own vocabulary — `--sink <class>=<path>[,…]`
#                    (at least one), `--plants-in`, `--segments`, `--report`
#
#   logscan_seal <profile> <needle-dir> [<extra seal arg>...]
#
#     The seal half alone, for an orchestrator that must seal its lane's ONE
#     manifest — with the lane's own floors — before the first target's gate
#     would seal it without them (every later gate reuses what is at the out
#     path). Returns the seal's rc; 0 without sealing when HAVEN_LOGSCAN is
#     off or this run's manifest is already there.
#
#   logscan_gate_dir <profile> <needle-dir> <dir> <report> [<extra seal arg>...]
#
#     The same gate over every `*.log` under <dir> (an orchestrator's evidence
#     directory, uploaded whole), each file typed by its name: `*logcat*` is a
#     `logcat` sink, `*drive*` a `drive` one, and the exact names the relay
#     producers write (LOGSCAN_RELAY_LOG_NAMES below) a `relay` one — the
#     class whose structural rules are off and whose pubkey/event-id needles
#     are scoped out, since a relay's own log legitimately holds them. Any
#     other name, `relay`-prefixed or not, is `diag`: the one-line-floor,
#     no-plant class that still searches every needle and runs every rule, so
#     no name can put a file out of the scanner's reach, and no new file can
#     type itself into the relay class by choosing a prefix. No `*.log` at all
#     is rc 3: a run that recorded nothing cannot be proven clean. The report
#     goes where the caller says; never inside <dir>, which is uploaded.
#
# Two arms. With HAVEN_LOGSCAN=true it seals the run's needle manifest and hands
# every named sink to scan-logs.sh, which runs the key-material floor AND the
# identifier scanner and contains on a leak. Otherwise it is the floor alone,
# over exactly the files the flag-on arm would have handed to the wrapper.
#
# The flag-on arm fails CLOSED at every joint — an absent binary (rc 2), a
# sidecar the drive never wrote (rc 3, proxy profile only), a seal that refuses
# — and still runs the wrapper after a failed seal, so the floor's containment
# never waits on the scanner. The seal exempts the lane's own endpoints from the
# URL and IP rules (RELAY_URL, the proxy's two listen spellings, WIRE_UPSTREAM
# when the workflow exported it) and never DECLARES them: a declared value must
# appear nowhere, but the lane's relay is infrastructure the harness itself
# names — declared as well, it flagged every Haven-owned line naming its host
# (run 34766632019).
#
# Read at call time, so a runner's --self-test can inject a fake: HAVEN_LOGSCAN,
# HAVEN_LOGSCAN_BIN, SECRET_SCAN, SCAN_LOGS, RELAY_URL, WIRE_UPSTREAM,
# GITHUB_RUN_ID, GITHUB_RUN_ATTEMPT.
#
# Written for bash 3.2: the iOS lanes source this on macOS runners, whose
# /bin/bash has no mapfile, no associative arrays and no case conversion. The
# self-test pins that statically, since macOS cannot be run here.

LOGSCAN_GATE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly LOGSCAN_GATE_DIR
readonly LOGSCAN_DEFAULT_BIN="${LOGSCAN_GATE_DIR}/../../logscan/target/release/haven-logscan"
readonly LOGSCAN_MANIFEST_SUFFIX='.needles.json'

# shellcheck source=tooling/e2e/ci/host-needles.sh
source "${LOGSCAN_GATE_DIR}/host-needles.sh"

# scan_logs_or_contain <log>... — the key-material floor (Security Rule 6)
# alone. A leak (rc 1) fails the lane, and that failure is what triggers the
# `if: failure()` upload — so the gate REMOVES every log it scanned before
# returning, or the run would publish the leak it just caught. rc 3
# (absent/empty) keeps them: nothing there to contain.
scan_logs_or_contain() {
  local rc=0 floor="${SECRET_SCAN:-${LOGSCAN_GATE_DIR}/scan-logs-for-secrets.sh}"
  bash "${floor}" "$@" || rc=$?
  if (( rc == 1 )); then
    rm -f -- "$@"
    echo "ERROR: secret-leak guard tripped (see the LEAK line(s) above); removed" \
         "the scanned logs so the failure-artifact upload cannot publish them:" \
         "$*" >&2
  fi
  return "${rc}"
}

# worst_rc <a> <b> — the verdict of two gates, 1 > 2 > 3 > 4 > 0 (the tree's
# closed exit set, as scan-logs.sh and haven-logscan fold it). A code outside
# that set is a broken guard, never a pass.
worst_rc() {
  local rc
  for rc in 1 2 3 4; do
    if (( $1 == rc || $2 == rc )); then return "${rc}"; fi
  done
  if (( $1 == 0 && $2 == 0 )); then return 0; fi
  return 2
}

logscan_gate() {
  local profile="${1:-}" needle_dir="${2:-}"
  shift 2 2>/dev/null || { echo "ERROR: logscan_gate needs <profile> <needle-dir> … -- <wrapper args>" >&2; return 2; }
  case "${profile}" in
    proxy|host|rules) ;;
    *) echo "ERROR: logscan_gate: unknown profile '${profile}' (proxy|host|rules)" >&2; return 2 ;;
  esac
  local -a extra=() wrapper=() files=() parts=()
  local seen_sep=0 part
  while (( $# > 0 )); do
    if [[ "$1" == "--" ]]; then seen_sep=1; shift; break; fi
    extra+=("$1")
    shift
  done
  if (( ! seen_sep )); then
    echo "ERROR: logscan_gate: no \`--\` before the wrapper arguments" >&2
    return 2
  fi
  wrapper=("$@")
  while (( $# > 0 )); do
    if [[ "$1" == "--sink" && $# -ge 2 ]]; then
      IFS=',' read -r -a parts <<<"${2#*=}"
      for part in "${parts[@]}"; do [[ -z "${part}" ]] || files+=("${part}"); done
      shift 2
    else
      shift
    fi
  done
  if (( ${#files[@]} == 0 )); then
    echo "ERROR: logscan_gate: no --sink after \`--\`; a gate over nothing certifies nothing" >&2
    return 2
  fi

  if [[ "${HAVEN_LOGSCAN:-}" != "true" ]]; then
    scan_logs_or_contain "${files[@]}"
    return
  fi

  local scan_logs="${SCAN_LOGS:-${LOGSCAN_GATE_DIR}/scan-logs.sh}"
  local scan_rc=0
  if [[ "${profile}" == rules ]]; then
    bash "${scan_logs}" --rules-only "${wrapper[@]}" || scan_rc=$?
    return "${scan_rc}"
  fi

  local run_id="${GITHUB_RUN_ID:-local}-${GITHUB_RUN_ATTEMPT:-local}"
  local manifest="${needle_dir}/${run_id}${LOGSCAN_MANIFEST_SUFFIX}"
  local seal_rc=0
  logscan_seal "${profile}" "${needle_dir}" ${extra[@]+"${extra[@]}"} || seal_rc=$?
  bash "${scan_logs}" --manifest "${manifest}" "${wrapper[@]}" || scan_rc=$?
  worst_rc "${seal_rc}" "${scan_rc}"
}

logscan_seal() {
  local profile="${1:-}" needle_dir="${2:-}"
  shift 2 2>/dev/null || { echo "ERROR: logscan_seal needs <profile> <needle-dir>" >&2; return 2; }
  case "${profile}" in
    proxy|host) ;;
    *) echo "ERROR: logscan_seal: unknown profile '${profile}' (proxy|host)" >&2; return 2 ;;
  esac
  [[ "${HAVEN_LOGSCAN:-}" == "true" ]] || return 0
  local bin="${HAVEN_LOGSCAN_BIN:-${LOGSCAN_DEFAULT_BIN}}"
  local run_id="${GITHUB_RUN_ID:-local}-${GITHUB_RUN_ATTEMPT:-local}"
  local manifest="${needle_dir}/${run_id}${LOGSCAN_MANIFEST_SUFFIX}"
  local seal_rc=0 seal=1
  local -a seal_args=() decls=("${needle_dir}"/*.needles.decl)
  local decl line
  if [[ ! -f "${bin}" || ! -x "${bin}" ]]; then
    echo "ERROR: haven-logscan is not an executable file at ${bin}. Build it" \
         "(cargo build --release --manifest-path tooling/logscan/Cargo.toml) or" \
         "point HAVEN_LOGSCAN_BIN at one. An absent scanner is a broken guard," \
         "never a skipped scan." >&2
    seal_rc=2
    seal=0
  elif [[ -f "${manifest}" ]]; then
    # Sealed by an earlier gate of this run (the rotation invariant; see the
    # header): tested before the profile switch, or a proxy lane's second
    # drive would re-seal `create_new` onto it and be rc 2 on every run.
    seal=0
  elif [[ "${profile}" == proxy ]]; then
    if [[ ! -e "${decls[0]}" ]]; then
      echo "ERROR: no needle declaration sidecar under ${needle_dir}: the drive" \
           "never reached the recording proxy's declaration channel, so there is" \
           "nothing to seal and this run cannot prove its logs clean." >&2
      seal_rc=3
      seal=0
    else
      for decl in "${decls[@]}"; do seal_args+=(--decl "${decl}"); done
    fi
  fi
  if (( seal )); then
    while IFS= read -r line; do seal_args+=("${line}"); done < <(host_needle_args "${profile}")
    [[ "${profile}" != host ]] || seal_args+=(--declared-plants none)
    [[ -z "${RELAY_URL:-}" ]] || seal_args+=(--exempt-endpoint "${RELAY_URL}")
    seal_args+=(--exempt-endpoint ws://127.0.0.1:7788 --exempt-endpoint ws://10.0.2.2:7788)
    [[ -z "${WIRE_UPSTREAM:-}" ]] || seal_args+=(--exempt-endpoint "${WIRE_UPSTREAM}")
    "${bin}" seal --run-id "${run_id}" "${seal_args[@]}" "$@" \
      --out "${manifest}" || seal_rc=$?
  fi
  return "${seal_rc}"
}

# The files a relay itself writes, by exact producer: strfry's docker logs
# (`strfry.<tag>.log`, `strfry2.final.log` — run-m7-background-catchup.sh,
# run-b5-permission-revocation.sh, run-relay-customization.sh), the
# host-native relay's own log and the workflows' copies of it (`relay.log`,
# `relay-profile-<port>.log` — start-local-relay.sh, e2e-profile.yml), B5's
# relay poll line and the relay exports it diffs (run-b5-permission-revocation.sh
# `RELAY_POLL_LOG`, `relay-scan.tmp`, `relay-scan.ids`, `BASELINE_IDS`,
# `NEW_IDS`, `APPOPS_NEW_IDS` and their `.raw`, promoted to `.log` by
# b5_prepare_logs_for_scan), and B9's exported backlog event (`BACKLOG_FILE`).
# A blossom log is NOT here: an HTTP blob server's log carries kind-24242 auth
# events, which the rules must see.
readonly -a LOGSCAN_RELAY_LOG_NAMES=(
  'strfry*.log' 'relay.log' 'relay-profile-*.log' 'haven-local-relay*.log'
  'relay-poll.b5.log' 'relay-backlog-event.b9.log'
  'relay-scan.tmp.log' 'relay-scan.ids.log' 'relay-baseline.ids.log'
  'relay-act2-new.ids.log' 'relay-act2-new.ids.raw.log'
  'relay-appops-new.ids.log' 'relay-appops-new.ids.raw.log'
)

logscan_is_relay_log() { # <basename>
  local pat
  for pat in "${LOGSCAN_RELAY_LOG_NAMES[@]}"; do
    # shellcheck disable=SC2053
    [[ "$1" == ${pat} ]] && return 0
  done
  return 1
}

logscan_gate_dir() {
  local profile="$1" needle_dir="$2" dir="$3" report="$4"
  shift 4
  local -a files=() logcat=() drive=() relay=() diag=() sinks=()
  local f
  while IFS= read -r f; do files+=("${f}"); done \
    < <(find "${dir}" -type f -name '*.log' 2>/dev/null | LC_ALL=C sort)
  for f in ${files[@]+"${files[@]}"}; do
    case "${f##*/}" in
      *logcat*) logcat+=("${f}") ;;
      *drive*) drive+=("${f}") ;;
      *) if logscan_is_relay_log "${f##*/}"; then relay+=("${f}"); else diag+=("${f}"); fi ;;
    esac
  done
  if (( ${#files[@]} == 0 )); then
    echo "ERROR: no *.log under ${dir}: nothing was captured, so this run carries" \
         "no evidence either way and cannot be proven clean." >&2
    return 3
  fi
  local IFS=','
  (( ${#logcat[@]} == 0 )) || sinks+=(--sink "logcat=${logcat[*]}")
  (( ${#drive[@]} == 0 )) || sinks+=(--sink "drive=${drive[*]}")
  (( ${#relay[@]} == 0 )) || sinks+=(--sink "relay=${relay[*]}")
  (( ${#diag[@]} == 0 )) || sinks+=(--sink "diag=${diag[*]}")
  unset IFS
  logscan_gate "${profile}" "${needle_dir}" "$@" -- "${sinks[@]}" --report "${report}"
}

# --self-test — the gate's own wiring, end to end: a FAKE haven-logscan
# (HAVEN_LOGSCAN_BIN, read at call time) that records its argv, the REAL
# scan-logs.sh and the REAL key-material floor. Under test is that the gate
# seals from what each profile is given, hands every sink to the wrapper, folds
# the two verdicts, and contains on a leak — never the scanner's patterns, which
# are the crate's own tests.
readonly LOGSCAN_GATE_SELF_TEST_FIXTURES=70
# bash-4-only: mapfile/readarray, coproc, declare -A, case conversion, |&, ;;&,
# negative substring offsets.
readonly LOGSCAN_GATE_BASH4_ONLY_RE='(^|[^[:alnum:]_])(mapfile|readarray|coproc)([^[:alnum:]_]|$)|declare[[:space:]]+-[a-zA-Z]*A|\$\{[A-Za-z_][A-Za-z0-9_]*(,,|\^\^)|\|&|;;&|\$\{[^}]*:([[:space:]]+-[0-9]|[0-9]+:[[:space:]]*-[0-9])'

logscan_gate_self_test() {
  local tmp fail=0 ran=0 rc
  tmp="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf '${tmp}'" RETURN

  local fake_bin="${tmp}/fake-logscan" seal_argv="${tmp}/seal-argv" scan_argv="${tmp}/scan-argv"
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'case "${1:-}" in' \
    '  seal) printf "%s\n" "$@" > "${FAKE_SEAL_ARGV}"; exit "${FAKE_SEAL_RC:-0}" ;;' \
    '  scan) printf "%s\n" "$@" > "${FAKE_SCAN_ARGV}"; exit "${FAKE_SCAN_RC:-0}" ;;' \
    'esac' \
    'exit 9' \
    > "${fake_bin}"
  chmod +x "${fake_bin}"
  export FAKE_SEAL_ARGV="${seal_argv}" FAKE_SCAN_ARGV="${scan_argv}"
  local needles="${tmp}/needles" logcat="${tmp}/logcat.log"
  local drive_final="${tmp}/drive-final.log" drive_full="${tmp}/drive-full.log"
  mkdir -p "${needles}"
  : > "${needles}/default.needles.decl"
  local -a sinks=(--sink "logcat=${logcat}" --sink "drive=${drive_final},${drive_full}"
                  --plants-in "drive=${drive_final}" --report "${tmp}/report.ndjson")
  local -a needle_argv=() host_argv=()
  local line
  while IFS= read -r line; do needle_argv+=("${line}"); done < <(host_needle_args proxy)
  while IFS= read -r line; do host_argv+=("${line}"); done < <(host_needle_args host)
  local -a floors=(--expect pubkey=3 --expect coordinate=4 --expect circle_name=1
                   --expect petname=1 --expect nostr_group_id=1 --expect mls_group_id=1
                   --expect event_id=3)

  reset_logs() {
    printf 'I/flutter ( 111): started\n' > "${logcat}"
    printf '00:03 +1: a scenario\n' > "${drive_final}"
    printf '===== attempt 1 =====\n00:03 +1: a scenario\n' > "${drive_full}"
    rm -f "${seal_argv}" "${scan_argv}" "${needles}/local-local.needles.json"
  }
  # gate_case <label> <profile> <want-rc> <deleted|kept> <seal-rc> <scan-rc> [dir]
  #
  # Every call pins the whole environment the gate reads. The guards job
  # inherits GITHUB_RUN_ID/GITHUB_RUN_ATTEMPT from Actions and a lane exports
  # WIRE_UPSTREAM and HAVEN_LOGSCAN, so a fixture that let them through passed
  # on a laptop and failed in CI (run 34766632019). Empty is how the gate reads
  # "unset". RELAY_URL is the value a lane carries.
  gate_case() {
    local label="$1" profile="$2" want="$3" fate="$4" dir="${7:-${needles}}" f
    rc=0
    ran=$(( ran + 1 ))
    GITHUB_RUN_ID= GITHUB_RUN_ATTEMPT= WIRE_UPSTREAM= RELAY_URL=ws://10.0.2.2:7788 \
      SECRET_SCAN= SCAN_LOGS= \
      HAVEN_LOGSCAN=true HAVEN_LOGSCAN_BIN="${fake_bin}" FAKE_SEAL_RC="$5" FAKE_SCAN_RC="$6" \
      logscan_gate "${profile}" "${dir}" "${floors[@]}" -- "${sinks[@]}" \
      > "${tmp}/gate-out" 2>&1 || rc=$?
    if (( rc != want )); then
      echo "SELF-TEST FAIL (${label}): wanted rc ${want}, got ${rc}" >&2
      fail=1
    fi
    for f in "${logcat}" "${drive_final}" "${drive_full}"; do
      if [[ "${fate}" == deleted && -e "${f}" ]]; then
        echo "SELF-TEST FAIL (${label}): a leak verdict left ${f##*/} on disk for" \
             "the failure-artifact upload to publish" >&2
        fail=1
      elif [[ "${fate}" == kept && ! -e "${f}" ]]; then
        echo "SELF-TEST FAIL (${label}): rc ${rc} removed ${f##*/}, which it had no" \
             "leak to contain" >&2
        fail=1
      fi
    done
  }
  # argv_is <label> <file> <want...> — the recorded argv equals <want>. A seal
  # argv carries the host seeds, so a mismatch names the first differing index
  # and the flag words there, never a value.
  argv_is() {
    local label="$1" file="$2" line i=0 g w
    shift 2
    ran=$(( ran + 1 ))
    local -a got=()
    [[ ! -e "${file}" ]] || while IFS= read -r line; do got+=("${line}"); done < "${file}"
    while (( i < ${#got[@]} || i < $# )); do
      g='<end>'; w='<end>'
      (( i >= ${#got[@]} )) || g="${got[i]}"
      (( i >= $# )) || w="${@:$((i + 1)):1}"
      if [[ "${g}" != "${w}" ]]; then
        echo "SELF-TEST FAIL (${label}): argv differs at index ${i} — got $(argv_word "${g}") (of ${#got[@]}), expected $(argv_word "${w}") (of $#)" >&2
        fail=1
        return
      fi
      i=$(( i + 1 ))
    done
  }
  # argv_word <word> — a flag is named; anything else is only its length.
  argv_word() { if [[ "$1" == --* || "$1" == '<end>' ]]; then printf '%s' "$1"; else printf '<%d-char value>' "${#1}"; fi; }
  # argv_line <file> — the recorded argv as one space-joined line, for
  # substring checks only (never printed).
  argv_line() { printf '%s' "$(< "$1")" | tr '\n' ' '; }

  # (1) The proxy profile: the (9c) matrix. Verdicts fold, only a leak deletes,
  #     the wrapper runs even under a failed seal, no sidecar is 3, no binary 2.
  reset_logs; gate_case "proxy: scanner leak contains"        proxy 1 deleted 0 1
  reset_logs; gate_case "proxy: clean"                        proxy 0 kept    0 0
  reset_logs; gate_case "proxy: scanner unusable keeps"       proxy 3 kept    0 3
  reset_logs; gate_case "proxy: seal meta-floor keeps"        proxy 4 kept    4 0
  reset_logs; gate_case "proxy: leak outranks a failed seal"  proxy 1 deleted 4 1
  reset_logs; gate_case "proxy: seal guard outranks unusable" proxy 2 kept    2 3
  reset_logs
  printf 'D/keyring ( 111): Entry { secret: Some([1, 2, 3]) }\n' >> "${logcat}"
  gate_case "proxy: floor contains under a failed seal"       proxy 1 deleted 4 0
  reset_logs; gate_case "proxy: no sidecar is 3"              proxy 3 kept    0 0 "${tmp}/no-needles"
  ran=$(( ran + 1 ))
  if [[ ! -e "${scan_argv}" ]]; then
    echo "SELF-TEST FAIL (proxy: no sidecar): a missing sidecar skipped the wrapper" \
         "instead of only the seal" >&2
    fail=1
  fi
  reset_logs
  rc=0
  ran=$(( ran + 1 ))
  GITHUB_RUN_ID= GITHUB_RUN_ATTEMPT= WIRE_UPSTREAM= RELAY_URL=ws://10.0.2.2:7788 \
    HAVEN_LOGSCAN=true HAVEN_LOGSCAN_BIN="${tmp}/no-such-binary" \
    logscan_gate proxy "${needles}" -- "${sinks[@]}" > "${tmp}/gate-out" 2>&1 || rc=$?
  if (( rc != 2 )) || [[ ! -e "${logcat}" || ! -e "${drive_full}" ]]; then
    echo "SELF-TEST FAIL (proxy: absent binary): wanted rc 2 with the logs kept, got rc ${rc}" >&2
    fail=1
  fi

  # (2) The proxy seal argv: run id, every sidecar, the host needles ADDED, the
  #     relay as an exempt endpoint only, both proxy spellings, the caller's
  #     floors, the manifest under the sidecar directory; the upstream only when
  #     the workflow exported it.
  reset_logs
  : > "${needles}/second.needles.decl"
  gate_case "proxy: seal argv run" proxy 0 kept 0 0
  argv_is "proxy: seal argv" "${seal_argv}" seal --run-id local-local \
    --decl "${needles}/default.needles.decl" --decl "${needles}/second.needles.decl" \
    "${needle_argv[@]}" \
    --exempt-endpoint ws://10.0.2.2:7788 \
    --exempt-endpoint ws://127.0.0.1:7788 --exempt-endpoint ws://10.0.2.2:7788 \
    "${floors[@]}" \
    --out "${needles}/local-local.needles.json"
  argv_is "proxy: scan argv" "${scan_argv}" scan --manifest "${needles}/local-local.needles.json" \
    "${sinks[@]}"
  rm -f "${needles}/second.needles.decl"
  reset_logs
  rc=0
  ran=$(( ran + 1 ))
  GITHUB_RUN_ID=424242 GITHUB_RUN_ATTEMPT=2 WIRE_UPSTREAM=ws://127.0.0.1:7777 RELAY_URL=ws://10.0.2.2:7788 \
    HAVEN_LOGSCAN=true HAVEN_LOGSCAN_BIN="${fake_bin}" FAKE_SEAL_RC=0 FAKE_SCAN_RC=0 \
    logscan_gate proxy "${needles}" -- "${sinks[@]}" > "${tmp}/gate-out" 2>&1 || rc=$?
  local got
  got="$(argv_line "${seal_argv}")"
  if (( rc != 0 )) || [[ "${got}" != *"--run-id 424242-2 "* ]] \
     || [[ "${got}" != *"--exempt-endpoint ws://127.0.0.1:7777 "* ]] \
     || [[ "${got}" != *"--out ${needles}/424242-2.needles.json" ]]; then
    echo "SELF-TEST FAIL (proxy: run id): the seal must carry the workflow run id" \
         "and attempt, the exported upstream, and the matching manifest path" \
         "(rc ${rc}; run id present: $([[ "${got}" == *"--run-id 424242-2 "* ]] && echo yes || echo no);" \
         "upstream present: $([[ "${got}" == *"--exempt-endpoint ws://127.0.0.1:7777 "* ]] && echo yes || echo no);" \
         "out path present: $([[ "${got}" == *"--out ${needles}/424242-2.needles.json" ]] && echo yes || echo no))" >&2
    fail=1
  fi
  argv_is "proxy: scan argv follows the run id" "${scan_argv}" scan \
    --manifest "${needles}/424242-2.needles.json" "${sinks[@]}"
  # A proxy gate called twice in one run — e2e-ios.yml drives e2e_combined and
  # then the background mirror in ONE proxy session, with no rotation between
  # — seals once and scans twice: the second call finds this run's manifest
  # and hands it to the wrapper without re-sealing (the seal writes it
  # `create_new`; a second seal was rc 2 on every run).
  reset_logs; gate_case "proxy: two gates, the first seals"  proxy 0 kept 0 0
  : > "${needles}/local-local.needles.json"
  rm -f "${seal_argv}" "${scan_argv}"
  gate_case "proxy: two gates, the second reuses"            proxy 0 kept 0 0
  ran=$(( ran + 1 ))
  if [[ -e "${seal_argv}" ]]; then
    echo "SELF-TEST FAIL (proxy: second gate): a proxy gate re-sealed this run's" \
         "manifest; the seal writes it create_new, so a two-drive proxy lane" \
         "would be rc 2 on every run" >&2
    fail=1
  fi
  argv_is "proxy: second gate still scans" "${scan_argv}" scan \
    --manifest "${needles}/local-local.needles.json" "${sinks[@]}"
  # No RELAY_URL: nothing is exempted in its place.
  reset_logs
  ran=$(( ran + 1 ))
  GITHUB_RUN_ID= GITHUB_RUN_ATTEMPT= WIRE_UPSTREAM= RELAY_URL= \
    HAVEN_LOGSCAN=true HAVEN_LOGSCAN_BIN="${fake_bin}" FAKE_SEAL_RC=0 FAKE_SCAN_RC=0 \
    logscan_gate proxy "${needles}" -- "${sinks[@]}" > "${tmp}/gate-out" 2>&1 || true
  got="$(argv_line "${seal_argv}")"
  if [[ "${got}" != *"--host-decl petname=Qzvx PETNAME  --exempt-endpoint ws://127.0.0.1:7788 "* ]]; then
    echo "SELF-TEST FAIL (proxy: no RELAY_URL): an empty relay must add no exemption, so the" \
         "first proxy spelling must directly follow the last host needle (it does not)" >&2
    fail=1
  fi

  # (3) The host profile: no sidecar is NOT 3 — the host needles are the whole
  #     declaration, with the floors they meet and no Dart plants to reconcile;
  #     a manifest already there is reused (no second seal) and the scan still
  #     runs against it.
  reset_logs; gate_case "host: no sidecar is clean"           host 0 kept    0 0 "${tmp}/no-needles"
  argv_is "host: seal argv" "${seal_argv}" seal --run-id local-local \
    "${host_argv[@]}" \
    --declared-plants none \
    --exempt-endpoint ws://10.0.2.2:7788 \
    --exempt-endpoint ws://127.0.0.1:7788 --exempt-endpoint ws://10.0.2.2:7788 \
    "${floors[@]}" \
    --out "${tmp}/no-needles/local-local.needles.json"
  argv_is "host: scan argv" "${scan_argv}" scan --manifest "${tmp}/no-needles/local-local.needles.json" \
    "${sinks[@]}"
  reset_logs; gate_case "host: scanner leak contains"         host 1 deleted 0 1
  reset_logs; gate_case "host: seal meta-floor keeps"         host 4 kept    4 0
  reset_logs
  : > "${needles}/local-local.needles.json"
  gate_case "host: existing manifest is reused"                host 0 kept    0 0
  ran=$(( ran + 1 ))
  if [[ -e "${seal_argv}" ]]; then
    echo "SELF-TEST FAIL (host: reuse): a manifest already sealed this run was sealed again" >&2
    fail=1
  fi
  argv_is "host: reuse still scans" "${scan_argv}" scan --manifest "${needles}/local-local.needles.json" \
    "${sinks[@]}"
  reset_logs
  rc=0
  ran=$(( ran + 1 ))
  GITHUB_RUN_ID= GITHUB_RUN_ATTEMPT= WIRE_UPSTREAM= RELAY_URL=ws://10.0.2.2:7788 \
    HAVEN_LOGSCAN=true HAVEN_LOGSCAN_BIN="${tmp}/no-such-binary" \
    logscan_gate host "${needles}" -- "${sinks[@]}" > "${tmp}/gate-out" 2>&1 || rc=$?
  if (( rc != 2 )) || [[ ! -e "${logcat}" || ! -e "${drive_full}" ]]; then
    echo "SELF-TEST FAIL (host: absent binary): wanted rc 2 with the logs kept, got rc ${rc}" >&2
    fail=1
  fi

  # (4) The rules profile: no seal, the wrapper runs `--rules-only` over the
  #     same sinks; a leak still contains.
  reset_logs; gate_case "rules: clean"                        rules 0 kept    0 0 "${tmp}/no-needles"
  ran=$(( ran + 1 ))
  if [[ -e "${seal_argv}" ]]; then
    echo "SELF-TEST FAIL (rules: no seal): a rules-only gate sealed a manifest" >&2
    fail=1
  fi
  argv_is "rules: scan argv" "${scan_argv}" scan --rules-only "${sinks[@]}"
  reset_logs; gate_case "rules: scanner leak contains"        rules 1 deleted 0 1 "${tmp}/no-needles"

  # (5) The flag-off arm never touches the scanner: with HAVEN_LOGSCAN unset —
  #     pinned empty, so a lane's exported `true` cannot pick the other arm —
  #     the gate is the floor alone over every named sink.
  reset_logs
  rc=0
  ran=$(( ran + 1 ))
  local fake_floor="${tmp}/fake-floor.sh"
  printf '%s\n' '#!/usr/bin/env bash' 'exit 1' > "${fake_floor}"
  HAVEN_LOGSCAN= HAVEN_LOGSCAN_BIN="${fake_bin}" SECRET_SCAN="${fake_floor}" \
    logscan_gate host "${needles}" -- "${sinks[@]}" > "${tmp}/gate-out" 2>&1 || rc=$?
  if (( rc != 1 )) || [[ -e "${logcat}" || -e "${drive_final}" || -e "${drive_full}" ]] \
     || [[ -e "${seal_argv}" || -e "${scan_argv}" ]]; then
    echo "SELF-TEST FAIL (flag-off): with HAVEN_LOGSCAN unset the gate must be the" \
         "floor alone over every sink (rc ${rc})" >&2
    fail=1
  fi
  reset_logs
  rc=0
  ran=$(( ran + 1 ))
  printf '%s\n' '#!/usr/bin/env bash' 'exit 3' > "${fake_floor}"
  HAVEN_LOGSCAN= HAVEN_LOGSCAN_BIN="${fake_bin}" SECRET_SCAN="${fake_floor}" \
    logscan_gate host "${needles}" -- "${sinks[@]}" > "${tmp}/gate-out" 2>&1 || rc=$?
  if (( rc != 3 )) || [[ ! -e "${logcat}" || ! -e "${drive_full}" ]]; then
    echo "SELF-TEST FAIL (flag-off rc 3): the floor's verdict is returned unchanged and nothing is removed (rc ${rc})" >&2
    fail=1
  fi

  # (6) Usage: an unknown profile, a missing `--`, and no --sink are rc 2
  #     before anything runs.
  reset_logs
  local -a bad=("nonesuch|--sink logcat=${logcat}" "host|--sink logcat=${logcat}" "host|--|--report x.ndjson")
  local spec
  for spec in "${bad[@]}"; do
    rc=0
    ran=$(( ran + 1 ))
    # shellcheck disable=SC2086
    HAVEN_LOGSCAN=true HAVEN_LOGSCAN_BIN="${fake_bin}" \
      logscan_gate "${spec%%|*}" "${needles}" ${spec#*|} > "${tmp}/gate-out" 2>&1 || rc=$?
    if (( rc != 2 )) || [[ -e "${seal_argv}" || -e "${scan_argv}" ]]; then
      echo "SELF-TEST FAIL (usage '${spec}'): wanted rc 2 and no scanner call, got rc ${rc}" >&2
      fail=1
    fi
  done

  # (7) logscan_seal alone: the host argv with the caller's floors, no scan; a
  #     second call reuses the manifest; flag-off seals nothing; proxy only
  #     ever seals from a sidecar.
  reset_logs
  rm -rf "${tmp}/preseal"; mkdir -p "${tmp}/preseal"
  rc=0
  ran=$(( ran + 1 ))
  GITHUB_RUN_ID= GITHUB_RUN_ATTEMPT= WIRE_UPSTREAM= RELAY_URL=ws://10.0.2.2:7777 \
    HAVEN_LOGSCAN=true HAVEN_LOGSCAN_BIN="${fake_bin}" FAKE_SEAL_RC=0 \
    logscan_seal host "${tmp}/preseal" --floor drive=20 > "${tmp}/gate-out" 2>&1 || rc=$?
  if (( rc != 0 )) || [[ -e "${scan_argv}" ]]; then
    echo "SELF-TEST FAIL (seal alone): wanted rc 0 and no scan, got rc ${rc}" >&2
    fail=1
  fi
  argv_is "seal alone: argv" "${seal_argv}" seal --run-id local-local \
    "${host_argv[@]}" --declared-plants none \
    --exempt-endpoint ws://10.0.2.2:7777 \
    --exempt-endpoint ws://127.0.0.1:7788 --exempt-endpoint ws://10.0.2.2:7788 \
    --floor drive=20 \
    --out "${tmp}/preseal/local-local.needles.json"
  : > "${tmp}/preseal/local-local.needles.json"
  rm -f "${seal_argv}"
  rc=0
  ran=$(( ran + 1 ))
  GITHUB_RUN_ID= GITHUB_RUN_ATTEMPT= WIRE_UPSTREAM= RELAY_URL= \
    HAVEN_LOGSCAN=true HAVEN_LOGSCAN_BIN="${fake_bin}" \
    logscan_seal host "${tmp}/preseal" --floor drive=20 > "${tmp}/gate-out" 2>&1 || rc=$?
  if (( rc != 0 )) || [[ -e "${seal_argv}" ]]; then
    echo "SELF-TEST FAIL (seal alone: reuse): a manifest already sealed this run must not be sealed again (rc ${rc})" >&2
    fail=1
  fi
  rm -f "${seal_argv}"
  rc=0
  ran=$(( ran + 1 ))
  HAVEN_LOGSCAN= HAVEN_LOGSCAN_BIN="${fake_bin}" \
    logscan_seal host "${tmp}/no-needles" > "${tmp}/gate-out" 2>&1 || rc=$?
  if (( rc != 0 )) || [[ -e "${seal_argv}" ]]; then
    echo "SELF-TEST FAIL (seal alone: flag-off): nothing may be sealed with HAVEN_LOGSCAN unset (rc ${rc})" >&2
    fail=1
  fi

  # (8) The directory walker types every *.log by name, omits absent classes,
  #     puts the report where it is told, forwards the extra seal arguments,
  #     and refuses an empty directory as rc 3.
  local evidence="${tmp}/evidence"
  rm -rf "${evidence}"
  mkdir -p "${evidence}/nested"
  printf 'I/flutter ( 111): a\n' > "${evidence}/t1.logcat.log"
  printf '00:03 +1: b\n' > "${evidence}/t1.drive.log"
  printf '00:03 +1: c\n' > "${evidence}/nested/drive.b.log"
  printf 'd\n' > "${evidence}/strfry.final.log"
  printf 'e\n' > "${evidence}/blossom.log"
  printf 'f\n' > "${evidence}/toggle.log"
  printf 'g\n' > "${evidence}/notes.txt"
  rm -f "${seal_argv}" "${scan_argv}"
  rc=0
  ran=$(( ran + 1 ))
  GITHUB_RUN_ID= GITHUB_RUN_ATTEMPT= WIRE_UPSTREAM= RELAY_URL=ws://10.0.2.2:7777 \
    HAVEN_LOGSCAN=true HAVEN_LOGSCAN_BIN="${fake_bin}" FAKE_SEAL_RC=0 FAKE_SCAN_RC=0 \
    logscan_gate_dir host "${tmp}/no-needles" "${evidence}" "${tmp}/dir.ndjson" \
    --host-decl coordinate=1.000000,2.000000 > "${tmp}/gate-out" 2>&1 || rc=$?
  if (( rc != 0 )); then
    echo "SELF-TEST FAIL (dir walk): wanted rc 0, got ${rc}" >&2
    fail=1
  fi
  argv_is "dir walk: scan argv" "${scan_argv}" scan --manifest "${tmp}/no-needles/local-local.needles.json" \
    --sink "logcat=${evidence}/t1.logcat.log" \
    --sink "drive=${evidence}/nested/drive.b.log,${evidence}/t1.drive.log" \
    --sink "relay=${evidence}/strfry.final.log" \
    --sink "diag=${evidence}/blossom.log,${evidence}/toggle.log" \
    --report "${tmp}/dir.ndjson"
  ran=$(( ran + 1 ))
  got="$(argv_line "${seal_argv}")"
  if [[ "${got}" != *" --host-decl coordinate=1.000000,2.000000 --out "* ]]; then
    echo "SELF-TEST FAIL (dir walk: extra seal args): the walker's extra seal argument" \
         "must be forwarded verbatim, directly before --out (it is not)" >&2
    fail=1
  fi
  # typed_as <name> <class> — one file alone under a fresh evidence directory
  # lands in exactly that sink class. One fixture per real relay producer
  # (LOGSCAN_RELAY_LOG_NAMES), then the names that must NOT be relay: an
  # unknown `relay-` prefix (a new file cannot choose the rules-off class by
  # its name) and the blossom log (an HTTP server whose log carries the
  # kind-24242 auth events the rules must see).
  typed_as() {
    local name="$1" class="$2" ev="${tmp}/typed"
    rm -rf "${ev}"; mkdir -p "${ev}"
    printf 'x\n' > "${ev}/${name}"
    rm -f "${seal_argv}" "${scan_argv}"
    ran=$(( ran + 1 ))
    GITHUB_RUN_ID= GITHUB_RUN_ATTEMPT= WIRE_UPSTREAM= RELAY_URL= \
      HAVEN_LOGSCAN=true HAVEN_LOGSCAN_BIN="${fake_bin}" FAKE_SEAL_RC=0 FAKE_SCAN_RC=0 \
      logscan_gate_dir host "${tmp}/no-needles" "${ev}" "${tmp}/typed.ndjson" > "${tmp}/gate-out" 2>&1 || true
    if ! grep -qxF -- "${class}=${ev}/${name}" "${scan_argv}" 2>/dev/null; then
      echo "SELF-TEST FAIL (dir walk: ${name}): must be typed ${class}; typed" \
           "$(grep -oE '^(logcat|drive|relay|diag)=' "${scan_argv}" 2>/dev/null | tr -d '=' | tr '\n' ' ')" >&2
      fail=1
    fi
  }
  local name
  for name in strfry.final.log strfry.iter-3.log strfry2.final.log strfry.log \
              relay.log relay-profile-7790.log haven-local-relay.log haven-local-relay-profile-7790.log \
              relay-poll.b5.log relay-backlog-event.b9.log \
              relay-scan.tmp.log relay-scan.ids.log relay-baseline.ids.log \
              relay-act2-new.ids.log relay-act2-new.ids.raw.log \
              relay-appops-new.ids.log relay-appops-new.ids.raw.log; do
    typed_as "${name}" relay
  done
  for name in relay-something-new.log relayed.log relay-poll.b5.err.log blossom.log haven-local-blossom.log; do
    typed_as "${name}" diag
  done
  rm -f "${seal_argv}" "${scan_argv}"
  rc=0
  ran=$(( ran + 1 ))
  GITHUB_RUN_ID= GITHUB_RUN_ATTEMPT= WIRE_UPSTREAM= RELAY_URL=ws://10.0.2.2:7777 \
    HAVEN_LOGSCAN=true HAVEN_LOGSCAN_BIN="${fake_bin}" FAKE_SEAL_RC=0 FAKE_SCAN_RC=1 \
    logscan_gate_dir host "${tmp}/no-needles" "${evidence}" "${tmp}/dir.ndjson" > "${tmp}/gate-out" 2>&1 || rc=$?
  if (( rc != 1 )) || [[ -e "${evidence}/t1.logcat.log" || -e "${evidence}/nested/drive.b.log" \
     || -e "${evidence}/toggle.log" ]] || [[ ! -e "${evidence}/notes.txt" ]]; then
    echo "SELF-TEST FAIL (dir walk: leak): every *.log must go and nothing else (rc ${rc})" >&2
    fail=1
  fi
  rm -rf "${evidence}"
  mkdir -p "${evidence}"
  rm -f "${seal_argv}" "${scan_argv}"
  rc=0
  ran=$(( ran + 1 ))
  HAVEN_LOGSCAN=true HAVEN_LOGSCAN_BIN="${fake_bin}" \
    logscan_gate_dir host "${tmp}/no-needles" "${evidence}" "${tmp}/dir.ndjson" > "${tmp}/gate-out" 2>&1 || rc=$?
  if (( rc != 3 )) || [[ -e "${seal_argv}" || -e "${scan_argv}" ]]; then
    echo "SELF-TEST FAIL (dir walk: empty): an empty evidence directory must be rc 3 with nothing run (rc ${rc})" >&2
    fail=1
  fi
  unset FAKE_SEAL_ARGV FAKE_SCAN_ARGV
  # The iOS lanes source this on macOS runners under /bin/bash 3.2, which
  # cannot be run here, so the guard is static: no bash-4-only construct
  # anywhere in this file (its own definition line excepted).
  ran=$(( ran + 1 ))
  if grep -vF 'LOGSCAN_GATE_BASH4_ONLY_RE=' "${BASH_SOURCE[0]}" | grep -v '^[[:space:]]*#' \
       | grep -qE "${LOGSCAN_GATE_BASH4_ONLY_RE}"; then
    echo "SELF-TEST FAIL (bash 3.2): a bash-4-only construct is in this file (the constructs are listed at the regex definition); macOS's /bin/bash cannot run it" >&2
    fail=1
  fi

  if (( fail )); then
    echo "logscan-gate.sh: SELF-TEST FAILED" >&2
    return 1
  fi
  if (( ran != LOGSCAN_GATE_SELF_TEST_FIXTURES )); then
    echo "logscan-gate.sh: SELF-TEST FAILED — ran ${ran} fixture(s), expected exactly ${LOGSCAN_GATE_SELF_TEST_FIXTURES}; a fixture was added or removed without moving the pin" >&2
    return 1
  fi
  echo "logscan-gate.sh: self-test passed (${ran}/${LOGSCAN_GATE_SELF_TEST_FIXTURES} fixtures: under a pinned environment the proxy profile seals from the sidecar directory with the host needles added, exempting the lane's own endpoints without declaring them, then runs scan-logs.sh over every sink, folds the two verdicts, contains on a leak even under a failed seal, fails closed on an absent binary or sidecar, and called twice in one run seals once and scans twice; the host profile seals the host needles alone with no declared plants, treats no sidecar as clean, reuses this run's manifest and still scans; the rules profile seals nothing and runs --rules-only; logscan_seal alone seals the host argv with the caller's floors, reuses this run's manifest and is a no-op flag-off; the flag-off arm is the floor alone over every sink; usage errors run nothing; the directory walker types every *.log by name — each real relay producer as relay, an unknown relay-prefixed name and the blossom log as diag — omits absent classes, forwards extra seal arguments, contains on a leak and refuses an empty directory; no bash-4-only construct)."
  return 0
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  set -Eeuo pipefail
  case "${1:-}" in
    --self-test)
      logscan_gate_self_test
      exit $?
      ;;
  esac
  echo "logscan-gate.sh is a sourced library; pass --self-test to run it directly." >&2
  exit 2
fi
