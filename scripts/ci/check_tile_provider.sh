#!/usr/bin/env bash
# CI guard: the raw OpenStreetMap tile endpoint must never be Haven's release
# default tile source (OSMF tile usage policy; OSM checklist #17/#23). It is
# permitted ONLY as a documented dev fallback inside the constants file
# haven/lib/src/constants/tiles.dart.
#
# Checks:
#   1. 'tile.openstreetmap.org' appears in no Dart file under haven/lib except
#      the sanctioned constants file (tiles.dart).
#   2. The default-provider getter resolves to the Stadia config.
#   3. The Stadia config's URL template targets tiles.stadiamaps.com.
#
# Exit codes:
#   0  all checks pass
#   1  a violation was found
#   2  expected files missing (misconfiguration)

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LIB_DIR="${REPO_ROOT}/haven/lib"
TILES_FILE="${LIB_DIR}/src/constants/tiles.dart"
OSM_HOST='tile.openstreetmap.org'

log() {
  printf '\033[1;34m[check_tile_provider]\033[0m %s\n' "$*"
}

fail() {
  printf '\033[1;31m[check_tile_provider] FAIL:\033[0m %s\n' "$*" >&2
  exit 1
}

[[ -d "${LIB_DIR}" ]] || { echo "ERROR: ${LIB_DIR} not found" >&2; exit 2; }
[[ -f "${TILES_FILE}" ]] || { echo "ERROR: ${TILES_FILE} not found" >&2; exit 2; }

# 1. No raw-OSM endpoint anywhere in haven/lib except the constants file.
log "Scanning haven/lib for the raw OSM endpoint outside tiles.dart..."
offenders="$(grep -rn --include='*.dart' -F "${OSM_HOST}" "${LIB_DIR}" \
  | grep -v 'src/constants/tiles.dart:' || true)"
if [[ -n "${offenders}" ]]; then
  printf '%s\n' "${offenders}" >&2
  fail "raw OSM endpoint used outside haven/lib/src/constants/tiles.dart"
fi

# 2. The release default provider must be the Stadia config.
log "Verifying the release default tile provider is Stadia..."
grep -Eq \
  'get[[:space:]]+defaultTileProvider[[:space:]]*=>[[:space:]]*stadiaAlidadeSmooth' \
  "${TILES_FILE}" \
  || fail "defaultTileProvider does not resolve to stadiaAlidadeSmooth"

# 3. The Stadia config must target the Stadia tile host.
log "Verifying the Stadia config targets tiles.stadiamaps.com..."
grep -Fq 'tiles.stadiamaps.com' "${TILES_FILE}" \
  || fail "Stadia tile host (tiles.stadiamaps.com) not found in tiles.dart"

log "OK: release default is Stadia; raw OSM endpoint confined to tiles.dart."
