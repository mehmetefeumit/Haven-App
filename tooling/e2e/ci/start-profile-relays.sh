#!/usr/bin/env bash
#
# Starts the hermetic PROFILE-PLANE relay pool used by the public-profile E2E
# lane (.github/workflows/e2e-profile.yml).
#
# # Why a separate pool exists at all
#
# Haven routes kind-0 (public profile) traffic to a relay pool that is DISJOINT
# from every relay carrying the account's kind-445 / kind-1059 traffic — that
# separation is the whole point of the profile redesign
# (haven-core/src/profile/relay_pool.rs). A relay that has seen circle traffic
# is recorded in the contamination ledger and SUBTRACTED from the profile pool;
# `resolve_profile_pool` then fails closed with `PoolUnderflow` rather than
# degrading onto a contaminated relay.
#
# The lane's original single strfry is simultaneously the CIRCLE relay, so under
# the new design it is contaminated by construction and can never serve the
# profile plane. This script stands up the profile-plane relays as SEPARATE
# instances, on separate ports, with separate stores.
#
# # Why THREE by default, not one
#
# `haven-core/src/profile/relay_pool.rs` sets `PROFILE_POOL_MIN = 3`: fewer than
# three usable relays is a terminal `PoolUnderflow`. A one-relay hermetic pool
# would therefore fail closed exactly like the contaminated single-relay setup
# it replaces. Three is the smallest pool the production resolver accepts.
#
# NOTE for whoever wires the Dart side (see the TODO in
# haven/integration_test/e2e/e2e_profile_sharing.dart): per-author fetches are
# pinned to the author's top-`PROFILE_MAX_RELAY_RANK` (= 2) relays by rendezvous
# hash over a per-install RANDOM salt, so the pool member a given author is read
# from is not predictable from the harness. These three relays have INDEPENDENT
# stores, so the scenario must make Alice's kind-0 observable on ALL of them
# (publish to the whole pool) — publishing to just one would pass or fail on the
# salt lottery (~1/3 flake).
#
# # Isolation
#
# Each instance gets a distinct container name / port / data dir (docker mode)
# or a distinct PID+log file and process marker (native mode), because
# start-strfry.sh `docker rm -f`s its own container name and `rm -rf`s its own
# data dir on start, and start-local-relay.sh stops its own instance on start.
# Reusing an identity would make starting relay N kill relay N-1.
#
# Usage:
#   start-profile-relays.sh docker [port ...]   # Linux runner  (Android job)
#   start-profile-relays.sh native [port ...]   # macOS runner  (iOS job)
#
# Ports default to "7778 7779 7780" (the circle relay keeps 7777). The URLs the
# app is built against (HAVEN_E2E_PROFILE_RELAY / HAVEN_E2E_PROFILE_RELAYS
# dart-defines) MUST match whatever ports are passed here — they are baked into
# the build and this script does not re-derive them.
#
# Optional env (docker mode): STRFRY_IMAGE is forwarded to start-strfry.sh
# unchanged, so the pool pulls the same pinned digest as the circle relay.
#
# Exit status: non-zero as soon as ANY pool member fails to become healthy.
# Members started before the failure are left running for the workflow's
# `if: always()` teardown (stop-profile-relays.sh) to remove.

set -euo pipefail

if [[ $# -ge 1 ]]; then
  MODE="$1"
  shift
else
  MODE=""
fi
readonly MODE

# Deliberately a whitespace-separated STRING, not an array: this script runs on
# the macOS runners' bash 3.2, where expanding an empty array under `set -u` is
# an "unbound variable" error. Word-splitting `${PORTS}` below is intentional
# (the values are validated as digits first).
PORTS="$*"
if [[ -z "${PORTS}" ]]; then
  PORTS="7778 7779 7780"
fi
readonly PORTS

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR

case "${MODE}" in
  docker | native) ;;
  *)
    echo "ERROR: usage: $0 <docker|native> [port ...]" >&2
    exit 2
    ;;
esac

echo "[start-profile-relays] mode=${MODE} ports=${PORTS}"

# shellcheck disable=SC2086 # intentional word splitting over the port list
for port in ${PORTS}; do
  if [[ ! "${port}" =~ ^[0-9]+$ ]]; then
    echo "ERROR: invalid port '${port}' (digits only)" >&2
    exit 2
  fi

  if [[ "${MODE}" == "docker" ]]; then
    echo "[start-profile-relays] starting strfry-profile-${port} on :${port}"
    STRFRY_CONTAINER="strfry-profile-${port}" \
    STRFRY_PORT="${port}" \
    STRFRY_DATA_DIR="/tmp/strfry-profile-${port}-data" \
      bash "${SCRIPT_DIR}/start-strfry.sh"
  else
    echo "[start-profile-relays] starting host-native profile-${port} on :${port}"
    bash "${SCRIPT_DIR}/start-local-relay.sh" "${port}" "profile-${port}"
  fi
done

echo "[start-profile-relays] all profile-plane relays healthy (${PORTS})."
