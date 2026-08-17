#!/usr/bin/env bash
#
# Builds (release) and starts the RECORDING WEBSOCKET PROXY, then blocks until
# it accepts connections.
#
# The proxy sits between the app under test and the hermetic relay and writes
# an NDJSON wire journal — one line per WebSocket message, both directions,
# with a globally monotonic wire_seq. See docs/WIRE_JOURNAL.md.
#
# ## Where it sits, and why nothing else moves
#
# The relay keeps port 7777. The proxy listens on 7788 and forwards there, so
# inserting it into a lane is a ONE-LINE change to that lane's HAVEN_E2E_RELAY:
#
#     HAVEN_E2E_RELAY: ws://10.0.2.2:7777   ->   ws://10.0.2.2:7788   (Android)
#     HAVEN_E2E_RELAY: ws://localhost:7777  ->   ws://localhost:7788  (iOS)
#
# Relay startup, teardown, health checks and the network-egress guard are all
# unchanged (the guard allows ALL loopback traffic, so any port works).
#
# ## Multi-relay lanes
#
# Pass a ROUTING TABLE instead of a single port/upstream to record several
# relays into ONE journal and ONE wire_seq space — the only way an oracle can
# order relay R1's traffic against R2's:
#
#     HAVEN_WIRE_PROXY_ROUTES='7788=ws://127.0.0.1:7777,7789=ws://127.0.0.1:7778' \
#       bash tooling/e2e/ci/start-wire-proxy.sh
#
# ## Fail-open, and where that stops
#
# RECORDING fails open: if the journal cannot be written the proxy keeps
# forwarding traffic and the scenario still runs (see docs/WIRE_JOURNAL.md).
# STARTING does not: a proxy that cannot bind leaves the app pointed at a dead
# port, so this script exits non-zero and the lane fails immediately.
#
# ## Preflight
#
# The binary's own `--self-test` runs before the proxy is started, so the lane
# proves the instrument works ON THIS RUNNER before depending on it. It takes a
# few seconds and costs one relay + one proxy + one client on loopback.
#
# ## One journal per live instance, enforced
#
# HAVEN_WIRE_JOURNAL overrides the PER-INSTANCE default, so two instances
# started with it exported would both aim at one path — and the second one's
# rotation (`rm -f`) would unlink the file the first still holds open. The
# first would keep writing to an unlinked inode, reporting itself healthy,
# while its journal was unreachable; the binary's own staleness warning could
# not fire either, because the file it checks would be gone. Every oracle
# downstream would then read a journal missing an entire plane's traffic and
# still call it complete.
#
# So each instance CLAIMS its journal path (a sidecar next to its pid file) and
# this script refuses to start when another LIVE instance already holds the one
# it was asked for. Like binding, this does not fail open.
#
# ## The MLS-group-id sidecar
#
# The proxy also writes a SIDECAR file: one lowercase-hex line per distinct
# REAL MLS group id the device declares over the control channel
# (["HAVEN_WIRE_MLS_GROUP_ID","<hex>"], intercepted — never forwarded, never
# journalled). A host-side oracle needs those literal values to assert Security
# Rule 4 (the real group id never appears on the wire): asserting an ABSENCE
# requires knowing the value, and it cannot come from the journal, because its
# absence there is the assertion.
#
# That file is the most sensitive thing on the runner. It is NOT the drive log
# (uploaded, 14-day retention) and NOT the journal (the corpus the oracle
# scans). It is rotated here, deliberately NOT deleted by stop-wire-proxy.sh —
# the lane reads it after teardown — and check_wire_proxy_test_only.sh check 3
# fails CI if any workflow ever puts it in an upload-artifact step.
#
# Usage: start-wire-proxy.sh [listen-port] [upstream-url] [instance]
#        (defaults: 7788 ws://127.0.0.1:7777 default)
#        start-wire-proxy.sh --self-test
#
# Optional env:
#   HAVEN_WIRE_PROXY_ROUTES        '<listen>=<upstream>,...' — wins over argv.
#                                  <listen> is a bare port or an IP literal and
#                                  port; a non-loopback one is a hard startup
#                                  failure in the binary, with no override.
#   HAVEN_WIRE_JOURNAL             Journal path (default per instance, below).
#   HAVEN_WIRE_MLS_GROUP_ID_FILE   Sidecar path (default per instance, below).
#   HAVEN_WIRE_PROXY_ALLOW_REMOTE  '1' to permit a non-loopback upstream.
#   HAVEN_WIRE_PROXY_SKIP_SELFTEST '1' to skip the preflight (NOT for CI).
#   HAVEN_WIRE_PROXY_RUN_DIR       Where pid/log/claim files live (default /tmp).
#
# Files, mirroring start-local-relay.sh's instance convention:
#   default  -> /tmp/haven-wire-proxy.pid  .log  .journalpath  .mlsgroupid
#               /tmp/haven-wire-journal.ndjson
#   <name>   -> /tmp/haven-wire-proxy-<name>.{pid,log,journalpath,mlsgroupid}
#               /tmp/haven-wire-journal-<name>.ndjson

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
readonly CRATE_DIR="${SCRIPT_DIR}/../local-relay"
# Not readonly: the self-test points it at a temp fixture directory.
RUN_DIR="${HAVEN_WIRE_PROXY_RUN_DIR:-/tmp}"

# ---------------------------------------------------------------------------
# Journal-claim bookkeeping. Defined before the self-test entry point so the
# self-test can drive it against fixtures without starting anything.
# ---------------------------------------------------------------------------

# instance_files <instance> — echoes
#   "<pid> <log> <claim> <default-journal> <default-mlsgroupid>".
#
# The MLS-group-id sidecar is LAST so the positional reads that only want the
# first few fields keep working; a reader that wants it must name it.
instance_files() {
  local instance="$1"
  if [[ "${instance}" == "default" ]]; then
    echo "${RUN_DIR}/haven-wire-proxy.pid ${RUN_DIR}/haven-wire-proxy.log" \
      "${RUN_DIR}/haven-wire-proxy.journalpath ${RUN_DIR}/haven-wire-journal.ndjson" \
      "${RUN_DIR}/haven-wire-proxy.mlsgroupid"
  else
    echo "${RUN_DIR}/haven-wire-proxy-${instance}.pid" \
      "${RUN_DIR}/haven-wire-proxy-${instance}.log" \
      "${RUN_DIR}/haven-wire-proxy-${instance}.journalpath" \
      "${RUN_DIR}/haven-wire-journal-${instance}.ndjson" \
      "${RUN_DIR}/haven-wire-proxy-${instance}.mlsgroupid"
  fi
}

# conflicting_instance <mine> <journal> — prints "<other-instance> <pid>" when
# ANOTHER instance that is still running has claimed <journal>, else nothing.
#
# Liveness is checked, not assumed: a crashed run leaves its claim behind, and
# refusing to start after a crash would turn a recorder fault into a permanently
# red lane.
conflicting_instance() {
  local mine="$1" journal="$2" claim base other pid claimed
  shopt -s nullglob
  for claim in "${RUN_DIR}"/haven-wire-proxy.journalpath \
    "${RUN_DIR}"/haven-wire-proxy-*.journalpath; do
    [[ -f "${claim}" ]] || continue
    base="$(basename "${claim}" .journalpath)"
    other="${base#haven-wire-proxy}"
    other="${other#-}"
    [[ -z "${other}" ]] && other="default"
    [[ "${other}" == "${mine}" ]] && continue

    claimed="$(head -n 1 "${claim}" 2>/dev/null || true)"
    [[ "${claimed}" == "${journal}" ]] || continue

    read -r pid _ < <(cat "${RUN_DIR}/${base}.pid" 2>/dev/null || echo "")
    [[ -n "${pid:-}" ]] || continue
    if kill -0 "${pid}" 2>/dev/null; then
      echo "${other} ${pid}"
      return 0
    fi
  done
  return 0
}

# ---------------------------------------------------------------------------
# Self-test for the claim gate. Hermetic: fixtures in a temp RUN_DIR, no build,
# no proxy, no network. Both directions are pinned for every case, because a
# gate that cannot fail is the same as no gate — and this one guards a failure
# whose whole signature is SILENCE (a journal that looks healthy while its file
# has been unlinked underneath it).
# ---------------------------------------------------------------------------
self_test() {
  local tmp fails=0 live dead
  tmp="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf '${tmp}'" RETURN
  RUN_DIR="${tmp}"

  # A pid that IS running, and one that is definitely not.
  sleep 60 &
  live=$!
  sleep 60 &
  dead=$!
  kill "${dead}" 2>/dev/null || true
  wait "${dead}" 2>/dev/null || true

  _claim() { # _claim <instance> <journal> <pid>
    local instance="$1" journal="$2" pid="$3" p c
    read -r p _ c _ < <(instance_files "${instance}")
    printf '%s\n' "${journal}" >"${c}"
    printf '%s\n' "${pid}" >"${p}"
  }

  _case() { # _case <label> <want-conflict:yes|no> <mine> <journal>
    local label="$1" want="$2" mine="$3" journal="$4" got
    got="$(conflicting_instance "${mine}" "${journal}")"
    local saw="no"
    [[ -n "${got}" ]] && saw="yes"
    if [[ "${saw}" == "${want}" ]]; then
      printf '  \033[1;32mPASS\033[0m %s\n' "${label}"
    else
      printf '  \033[1;31mFAIL\033[0m %s (want conflict=%s, saw %s "%s")\n' \
        "${label}" "${want}" "${saw}" "${got}" >&2
      fails=1
    fi
  }

  echo "self-test: journal-claim gate"
  _case "an unclaimed journal is free" no "default" "${tmp}/j.ndjson"

  _claim "planeA" "${tmp}/shared.ndjson" "${live}"
  # THE regression: HAVEN_WIRE_JOURNAL exported across two instances. Without
  # this gate the second instance rm -f's the first's file while the first holds
  # the fd, and the first keeps writing to an unlinked inode.
  _case "a live instance holding the same journal is a conflict" \
    yes "planeB" "${tmp}/shared.ndjson"
  _case "a different journal is not a conflict" \
    no "planeB" "${tmp}/other.ndjson"
  _case "an instance never conflicts with its own claim" \
    no "planeA" "${tmp}/shared.ndjson"

  # A crashed run must not wedge the lane forever.
  _claim "planeC" "${tmp}/stale.ndjson" "${dead}"
  _case "a dead instance's stale claim is ignored" \
    no "planeD" "${tmp}/stale.ndjson"

  # ...and a claim with no pid file at all is equally inert.
  local pc
  read -r _ _ pc _ < <(instance_files "planeE")
  printf '%s\n' "${tmp}/orphan.ndjson" >"${pc}"
  _case "a claim with no pid file is ignored" no "planeF" "${tmp}/orphan.ndjson"

  # The default instance participates like any other — it is the one a lane
  # actually uses, and its files are named differently.
  _claim "default" "${tmp}/def.ndjson" "${live}"
  _case "the default instance can conflict with a named one" \
    yes "planeG" "${tmp}/def.ndjson"

  # ...and the WIRING, not only the predicate: the script itself must refuse,
  # and must do so BEFORE the destructive `rm -f` and before the build. The
  # fixture journal file is created first, so "it still exists afterwards" is
  # the observable proof that rotation never ran.
  echo "self-test: the script refuses rather than rotating a held journal"
  printf 'pre-existing evidence\n' >"${tmp}/shared.ndjson"
  local rc=0
  # SKIP_SELFTEST because a gate that has REGRESSED would otherwise fall
  # through to a release build and a proxy self-test here, turning a fast
  # failure into a slow one — and would leave a live proxy behind, which the
  # teardown below removes.
  HAVEN_WIRE_PROXY_RUN_DIR="${tmp}" \
    HAVEN_WIRE_JOURNAL="${tmp}/shared.ndjson" \
    HAVEN_WIRE_PROXY_SKIP_SELFTEST=1 \
    bash "${SCRIPT_DIR}/$(basename "${BASH_SOURCE[0]}")" 7788 ws://127.0.0.1:7777 planeB \
    >/dev/null 2>&1 || rc=$?
  if [[ "${rc}" -eq 2 ]] && [[ -s "${tmp}/shared.ndjson" ]]; then
    printf '  \033[1;32mPASS\033[0m refused (rc=2) and left the held journal intact\n'
  else
    printf '  \033[1;31mFAIL\033[0m rc=%s, journal present=%s\n' \
      "${rc}" "$([[ -s "${tmp}/shared.ndjson" ]] && echo yes || echo NO)" >&2
    fails=1
  fi
  HAVEN_WIRE_PROXY_RUN_DIR="${tmp}" \
    bash "${SCRIPT_DIR}/stop-wire-proxy.sh" planeB >/dev/null 2>&1 || true

  # -------------------------------------------------------------------------
  # The MLS-group-id sidecar's PATH and LIFECYCLE.
  #
  # Both halves are load-bearing and both are silent when wrong. A path this
  # script and the oracle disagree on gives the oracle an empty needle set, and
  # a sidecar the teardown deletes gives it a missing file — and C5.8's
  # precondition then reports "no --mls-group-id declared", which reads like a
  # lane that never wired the channel rather than one that lost the evidence.
  # -------------------------------------------------------------------------
  echo "self-test: the mls-group-id sidecar's path and lifecycle"
  local m_default m_named
  read -r _ _ _ _ m_default < <(instance_files "default")
  read -r _ _ _ _ m_named < <(instance_files "planeZ")
  _path_case() { # _path_case <label> <got> <want>
    if [[ "$2" == "$3" ]]; then
      printf '  \033[1;32mPASS\033[0m %s\n' "$1"
    else
      printf '  \033[1;31mFAIL\033[0m %s (want %s, got %s)\n' "$1" "$3" "$2" >&2
      fails=1
    fi
  }
  _path_case "the default instance's sidecar is unsuffixed" \
    "${m_default}" "${tmp}/haven-wire-proxy.mlsgroupid"
  _path_case "a named instance's sidecar carries its name" \
    "${m_named}" "${tmp}/haven-wire-proxy-planeZ.mlsgroupid"

  # ROTATION, and the fact that teardown LEAVES it: the lane reads this file
  # after stop-wire-proxy.sh has run.
  printf 'staleid\n' >"${m_named}"
  HAVEN_WIRE_PROXY_RUN_DIR="${tmp}" \
    bash "${SCRIPT_DIR}/stop-wire-proxy.sh" planeZ >/dev/null 2>&1 || true
  if [[ -f "${m_named}" ]]; then
    printf '  \033[1;32mPASS\033[0m teardown leaves the sidecar for the lane to read\n'
  else
    printf '  \033[1;31mFAIL\033[0m stop-wire-proxy.sh deleted the sidecar\n' >&2
    fails=1
  fi

  kill "${live}" 2>/dev/null || true
  wait "${live}" 2>/dev/null || true

  if ((fails)); then
    echo "self-test: FAILED" >&2
    return 1
  fi
  echo "self-test: OK"
  return 0
}

if [[ "${1:-}" == "--self-test" ]]; then
  self_test
  exit $?
fi

readonly PORT="${1:-7788}"
readonly UPSTREAM="${2:-ws://127.0.0.1:7777}"
readonly INSTANCE="${3:-default}"

if [[ ! "${INSTANCE}" =~ ^[A-Za-z0-9._-]+$ ]]; then
  echo "ERROR: instance name '${INSTANCE}' must match [A-Za-z0-9._-]+" >&2
  exit 2
fi

read -r PID_FILE LOG_FILE CLAIM_FILE DEFAULT_JOURNAL DEFAULT_MLS_GROUP_ID_FILE \
  < <(instance_files "${INSTANCE}")
readonly PID_FILE LOG_FILE CLAIM_FILE DEFAULT_JOURNAL DEFAULT_MLS_GROUP_ID_FILE
readonly JOURNAL="${HAVEN_WIRE_JOURNAL:-${DEFAULT_JOURNAL}}"
# Honoured rather than silently overridden, so `HAVEN_WIRE_MLS_GROUP_ID_FILE=x
# start-wire-proxy.sh` means what it looks like it means. Do NOT export it when
# running more than one instance: two proxies pointed at one sidecar would
# rotate each other's ground truth away, exactly as HAVEN_WIRE_JOURNAL does to
# the journal (which is what the claim gate above exists for).
readonly MLS_GROUP_ID_FILE="${HAVEN_WIRE_MLS_GROUP_ID_FILE:-${DEFAULT_MLS_GROUP_ID_FILE}}"

# ---------------------------------------------------------------------------
# Hermeticity gate — UPSTREAMS ONLY, and that is now a complete statement.
#
# The journal maps traffic to NAMED ENDPOINTS. Against the hermetic loopback
# relays that is lane configuration; against a real relay it would be a durable
# metadata map of who talked to whom, sitting in /tmp of a CI runner. Refuse by
# default, and make the override explicit and visible in the log.
#
# The other half — what the proxy LISTENS on — is deliberately not checked here.
# `config::validate_listen` refuses a non-loopback listen address in the binary,
# with no override, so a routing table naming `0.0.0.0` fails at startup whether
# it arrives through this script or not. Re-checking it here would put the
# stronger of the two guarantees behind the weaker path (this script is not the
# only way to start the recorder) and leave both looking optional.
# ---------------------------------------------------------------------------
check_loopback() { # check_loopback <ws-url>
  local url="$1" host
  host="${url#ws://}"
  host="${host#wss://}"
  host="${host%%/*}"
  host="${host%%:*}"
  case "${host}" in
    127.0.0.1 | localhost | ::1 | '[::1]') return 0 ;;
    *) return 1 ;;
  esac
}

declare -a UPSTREAMS=()
if [[ -n "${HAVEN_WIRE_PROXY_ROUTES:-}" ]]; then
  IFS=',' read -r -a _routes <<<"${HAVEN_WIRE_PROXY_ROUTES}"
  for _route in "${_routes[@]}"; do
    _route="${_route// /}"
    [[ -z "${_route}" ]] && continue
    UPSTREAMS+=("${_route#*=}")
  done
else
  UPSTREAMS+=("${UPSTREAM}")
fi

# What this instance actually serves, for the human-facing lines below. With a
# routing table the port/upstream argv is INERT — `config::resolve` gives the
# table precedence over HAVEN_WIRE_PROXY_PORT/UPSTREAM — so naming
# "127.0.0.1:${PORT}" there would print a port nothing is listening on. The
# authoritative statement is the proxy's own "ws://<listen> -> <upstream>" line
# per bound route, which the readiness branch cats out below.
if [[ -n "${HAVEN_WIRE_PROXY_ROUTES:-}" ]]; then
  ROUTES_DESC="routing table '${HAVEN_WIRE_PROXY_ROUTES}'"
else
  ROUTES_DESC="127.0.0.1:${PORT} -> ${UPSTREAM}"
fi
readonly ROUTES_DESC

for _upstream in "${UPSTREAMS[@]}"; do
  if ! check_loopback "${_upstream}"; then
    if [[ "${HAVEN_WIRE_PROXY_ALLOW_REMOTE:-0}" != "1" ]]; then
      echo "ERROR: upstream '${_upstream}' is not loopback." >&2
      echo "       The wire journal maps traffic to named endpoints; against a" >&2
      echo "       REAL relay that is a metadata map, not lane configuration." >&2
      echo "       Set HAVEN_WIRE_PROXY_ALLOW_REMOTE=1 to override deliberately." >&2
      exit 2
    fi
    echo "WARNING: recording traffic to NON-LOOPBACK upstream '${_upstream}'." >&2
    echo "         The journal will name a real host. Do not upload it." >&2
  fi
done

# Restart semantics, matching start-local-relay.sh: stop any proxy already
# running FOR THIS INSTANCE so a retried attempt starts clean. Scoped to the
# instance so restarting one plane's proxy cannot take another's down.
bash "${SCRIPT_DIR}/stop-wire-proxy.sh" "${INSTANCE}" >/dev/null 2>&1 || true

# ---------------------------------------------------------------------------
# Journal-claim gate. Checked BEFORE the build so a misconfigured lane fails in
# seconds, and before the `rm -f` below, which is the destructive step.
# ---------------------------------------------------------------------------
CONFLICT="$(conflicting_instance "${INSTANCE}" "${JOURNAL}")"
if [[ -n "${CONFLICT}" ]]; then
  read -r _other _pid <<<"${CONFLICT}"
  echo "ERROR: journal '${JOURNAL}' is already held by the running instance" >&2
  echo "       '${_other}' (pid ${_pid})." >&2
  echo "       Starting here would rotate (rm -f) a file that process still" >&2
  echo "       has open: it would keep writing to an unlinked inode, report" >&2
  echo "       itself healthy, and every oracle would read a journal missing" >&2
  echo "       that plane's traffic without any sign that it was missing." >&2
  echo "       HAVEN_WIRE_JOURNAL overrides the PER-INSTANCE default, so do" >&2
  echo "       not export it when running more than one instance." >&2
  exit 2
fi

echo "Building recording wire proxy (release)..."
cargo build --release --manifest-path "${CRATE_DIR}/Cargo.toml" --bin haven-wire-proxy
readonly BIN="${CRATE_DIR}/target/release/haven-wire-proxy"

if [[ "${HAVEN_WIRE_PROXY_SKIP_SELFTEST:-0}" == "1" ]]; then
  echo "WARNING: skipping the proxy self-test (HAVEN_WIRE_PROXY_SKIP_SELFTEST=1)." >&2
  echo "         The lane is about to trust an instrument it has not verified." >&2
else
  echo "Preflight: haven-wire-proxy --self-test ..."
  if ! "${BIN}" --self-test; then
    echo "ERROR: the wire proxy failed its own self-test on this runner." >&2
    echo "       Refusing to start: every oracle downstream would be reading a" >&2
    echo "       journal produced by an instrument known to be broken." >&2
    exit 1
  fi
fi

# ROTATE the journal. The proxy opens it in APPEND mode (a torn write must
# never truncate prior evidence), so a leftover file from an earlier attempt
# would merge two runs under two overlapping wire_seq spaces — and a consumer
# would see wire_seq go backwards with no way to tell which run a line is from.
rm -f "${JOURNAL}"

# ROTATE the MLS-group-id sidecar too, and for a sharper reason: it is the
# GROUND TRUTH a host-side oracle scans the journal for. A leftover file would
# hand this run's oracle the ids of a PREVIOUS run's circles, which were never
# on this wire and therefore can never be found — an assertion that cannot
# fail, which is the one failure mode a privacy oracle must not have.
rm -f "${MLS_GROUP_ID_FILE}"

echo "Starting wire proxy instance '${INSTANCE}': ${ROUTES_DESC}"
echo "  journal: ${JOURNAL}"
# NEVER upload this file. It holds the REAL MLS group ids the device declares,
# which Security Rule 4 says must never reach a relay; it exists so a host-side
# oracle can assert their ABSENCE from the journal. stop-wire-proxy.sh
# deliberately leaves it in place, because the lane reads it after teardown,
# and check_wire_proxy_test_only.sh check 3 keeps it out of every artifact.
echo "  mls-group-id sidecar: ${MLS_GROUP_ID_FILE} (host-only, never an artifact)"
HAVEN_WIRE_PROXY_PORT="${PORT}" \
HAVEN_WIRE_PROXY_UPSTREAM="${UPSTREAM}" \
HAVEN_WIRE_JOURNAL="${JOURNAL}" \
HAVEN_WIRE_MLS_GROUP_ID_FILE="${MLS_GROUP_ID_FILE}" \
  nohup "${BIN}" "--haven-wire-proxy-instance=${INSTANCE}" \
  >"${LOG_FILE}" 2>&1 &
echo $! >"${PID_FILE}"
# CLAIM the journal, so a second instance pointed at the same path refuses to
# start rather than unlinking this one's file out from under it.
printf '%s\n' "${JOURNAL}" >"${CLAIM_FILE}"
# The sidecar gets a claim of its own, for the same reason the journal has one:
# a reader that GUESSES the filename reads the wrong instance's file the day a
# lane runs two recorders, and for the sidecar that is worse than for the
# journal — a stale file makes C5.8 scan for a previous plane's ids, find
# nothing, and report clean. Derived from CLAIM_FILE so it carries the instance
# suffix automatically.
printf '%s\n' "${MLS_GROUP_ID_FILE}" >"${CLAIM_FILE%.journalpath}.mlsgroupidpath"

# Readiness is the proxy's OWN log line, not a port probe.
#
# `nc -z` opens a bare TCP connection and drops it without a WebSocket
# handshake, which the proxy correctly records as a conn_open + conn_error
# pair — so every journal would open with two lines describing the readiness
# check rather than the app. The log line is also a STRONGER signal: the proxy
# prints it after binding every route AND opening the journal, so it proves the
# instrument is up, not merely that something is listening.
for _ in $(seq 1 30); do
  if grep -q '^\[haven-wire-proxy\] journal:' "${LOG_FILE}" 2>/dev/null; then
    echo "Wire proxy '${INSTANCE}' is up: ${ROUTES_DESC}."
    cat "${LOG_FILE}" 2>/dev/null || true
    # Say it loudly here too: a lane whose recorder came up already degraded
    # would otherwise only find out from a fail-closed oracle an hour later.
    if grep -q 'DEGRADED' "${LOG_FILE}" 2>/dev/null; then
      echo "WARNING: the wire proxy started DEGRADED — traffic will flow but" >&2
      echo "         nothing will be recorded, and every oracle reading the" >&2
      echo "         journal will (correctly) fail closed." >&2
    fi
    exit 0
  fi
  sleep 1
done

echo "ERROR: wire proxy '${INSTANCE}' (${ROUTES_DESC}) did not come up within 30s" >&2
cat "${LOG_FILE}" >&2 2>/dev/null || true
exit 1
