#!/usr/bin/env bash
# Local E2E test runner. Mirrors the CI workflow but uses whatever Flutter
# device the developer has already attached.
#
# Subcommands:
#   smoke            Run integration_test/e2e/smoke_test.dart against a
#                    local strfry. Phase 0 acceptance gate.
#   scenario <N>     Run integration_test/e2e/scenario_<N>_*.dart. Reserved
#                    for Phase 1+.
#   all              Run every scenario sequentially.
#   relay-up         Start strfry and exit (useful when iterating manually
#                    via `flutter test`).
#   relay-down       Stop strfry.
#
# Environment overrides:
#   HAVEN_E2E_RELAY  Override the dart-define passed to flutter test
#                    (default: ws://10.0.2.2:7777 — Android emulator
#                    host-loopback alias).
#   HAVEN_E2E_DEVICE Device id to pass to flutter test --device-id (default:
#                    unset; uses Flutter's default device picker).
#
# Failure modes:
#   - Exits 2 if Docker is not installed.
#   - Exits 3 if strfry healthcheck never reports ready.
#   - Exits with flutter test's own exit code on scenario failure.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HAVEN_DIR="${REPO_ROOT}/haven"
E2E_DIR="${REPO_ROOT}/tooling/e2e"
COMPOSE_FILE="${E2E_DIR}/docker-compose.yml"

# Default relay URL: Android emulator loopback alias. iOS simulator users
# should export HAVEN_E2E_RELAY=ws://localhost:7777 before invoking this.
RELAY_URL="${HAVEN_E2E_RELAY:-ws://10.0.2.2:7777}"

# Optional device override.
DEVICE_ARGS=()
if [[ -n "${HAVEN_E2E_DEVICE:-}" ]]; then
  DEVICE_ARGS+=("--device-id" "${HAVEN_E2E_DEVICE}")
fi

log() {
  printf '\033[1;34m[run_e2e_local]\033[0m %s\n' "$*"
}

require_docker() {
  if ! command -v docker >/dev/null 2>&1; then
    echo "ERROR: docker is not installed or not on PATH." >&2
    echo "       Install Docker Desktop or podman-docker, then retry." >&2
    exit 2
  fi
  if ! docker compose version >/dev/null 2>&1; then
    echo "ERROR: 'docker compose' subcommand not available." >&2
    echo "       Upgrade Docker to a version with the compose plugin." >&2
    exit 2
  fi
}

relay_up() {
  require_docker
  log "starting strfry on ${RELAY_URL}"
  docker compose -f "${COMPOSE_FILE}" up -d strfry

  # Wait for the healthcheck to report healthy. Cap at ~60 s — strfry
  # boots in <3 s on a warm machine; anything longer means something is
  # wrong (port collision, image pull failure, etc.).
  log "waiting for strfry healthcheck"
  local attempts=0
  until [[ "$(docker inspect -f '{{.State.Health.Status}}' haven-e2e-strfry 2>/dev/null || echo starting)" == "healthy" ]]; do
    attempts=$((attempts + 1))
    if [[ ${attempts} -ge 30 ]]; then
      echo "ERROR: strfry never reported healthy after 60 s." >&2
      docker compose -f "${COMPOSE_FILE}" logs strfry >&2 || true
      exit 3
    fi
    sleep 2
  done
  log "strfry healthy"
}

relay_down() {
  require_docker
  log "stopping strfry"
  docker compose -f "${COMPOSE_FILE}" down -v
}

run_flutter_test() {
  local target="$1"
  log "running flutter test ${target}"
  cd "${HAVEN_DIR}"
  flutter test \
    --dart-define=HAVEN_E2E_RELAY="${RELAY_URL}" \
    "${DEVICE_ARGS[@]}" \
    "${target}"
}

cmd_smoke() {
  relay_up
  trap relay_down EXIT
  run_flutter_test "integration_test/e2e/smoke_test.dart"
}

cmd_scenario() {
  local id="$1"
  local candidates=("${HAVEN_DIR}/integration_test/e2e/scenario_${id}"_*.dart)
  if [[ ${#candidates[@]} -eq 0 || ! -f "${candidates[0]}" ]]; then
    echo "ERROR: no scenario file matching scenario_${id}_*.dart found." >&2
    echo "       Available scenarios:" >&2
    ls "${HAVEN_DIR}/integration_test/e2e/" 2>/dev/null | sed 's/^/         /' >&2
    exit 1
  fi
  relay_up
  trap relay_down EXIT
  run_flutter_test "integration_test/e2e/$(basename "${candidates[0]}")"
}

cmd_all() {
  relay_up
  trap relay_down EXIT
  local failed=0
  for f in "${HAVEN_DIR}/integration_test/e2e/"*.dart; do
    [[ -f "$f" ]] || continue
    log "=== $(basename "$f") ==="
    if ! run_flutter_test "integration_test/e2e/$(basename "$f")"; then
      failed=$((failed + 1))
      log "FAILED: $(basename "$f")"
    fi
  done
  if [[ ${failed} -gt 0 ]]; then
    echo "ERROR: ${failed} scenario(s) failed." >&2
    exit 1
  fi
}

usage() {
  sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'
  exit 1
}

case "${1:-}" in
  smoke) cmd_smoke ;;
  scenario)
    if [[ $# -lt 2 ]]; then usage; fi
    cmd_scenario "$2"
    ;;
  all) cmd_all ;;
  relay-up) relay_up ;;
  relay-down) relay_down ;;
  -h|--help|help|"") usage ;;
  *)
    echo "Unknown subcommand: $1" >&2
    usage
    ;;
esac
