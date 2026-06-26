#!/usr/bin/env bash
# CI guard: the encrypted map-tile cache must never persist or log the Stadia
# api_key, a raw tile URL, or `(z,x,y)` coordinate values. A tile cache is a map
# of everywhere the user and their circle have been, so a coordinate leaking into
# a log line, or the api_key landing in a DB column/filename, is a privacy defect.
#
# The api_key is stripped in Dart (TileKey.tryParse drops the query) before any
# value crosses the FFI boundary; the storage layer deals only in
# (style,z,x,y,retina); errors and logs are redacted. This guard pins those
# invariants so a future change can't silently regress them.
#
# Checks (static, low-false-positive):
#   1. The Rust tile storage layer (src/tiles/) references no `url`/`api_key` —
#      it keys on (style,z,x,y,retina) only, so neither token should appear.
#   2. No `log::` line in the Rust tile layer (src/tiles/ + the api.rs tile FFI)
#      interpolates a value (`{...}`): tile logs must be static strings, never a
#      coordinate/URL/byte dump.
#   3. The Dart tile-cache layer logs only `runtimeType` — never a raw url, a
#      coordinate, or a `TileKey` (whose toString carries coordinates).
#
# Exit codes:
#   0  all checks pass
#   1  a violation was found
#   2  expected files missing (misconfiguration)

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TILES_RS_DIR="${REPO_ROOT}/haven-core/src/tiles"
API_RS="${REPO_ROOT}/haven/rust_builder/src/api.rs"
# Strict files: every log call must emit ONLY `runtimeType` (these never log
# counts, so the tightest check applies).
DART_TILE_FILES=(
  "${REPO_ROOT}/haven/lib/src/services/tile_key.dart"
  "${REPO_ROOT}/haven/lib/src/services/tile_cache_store.dart"
  "${REPO_ROOT}/haven/lib/src/services/encrypted_tile_caching_provider.dart"
  "${REPO_ROOT}/haven/lib/src/providers/tile_cache_provider.dart"
)
# Broader set for the no-url/key/coordinate-interpolation check. Includes the two
# files that build raw tile URLs / coordinates and legitimately log counts
# (so the strict runtimeType-only rule cannot apply, but a coordinate/URL/key
# must still never be interpolated into a log line).
DART_TILE_LOG_FILES=(
  "${DART_TILE_FILES[@]}"
  "${REPO_ROOT}/haven/lib/src/services/tile_prefetch_service.dart"
  "${REPO_ROOT}/haven/lib/src/utils/tile_coordinates.dart"
)

log() {
  printf '\033[1;34m[check_no_tile_cache_secrets]\033[0m %s\n' "$*"
}

fail() {
  printf '\033[1;31m[check_no_tile_cache_secrets] FAIL:\033[0m %s\n' "$*" >&2
  exit 1
}

[[ -d "${TILES_RS_DIR}" ]] || { echo "ERROR: ${TILES_RS_DIR} not found" >&2; exit 2; }
[[ -f "${API_RS}" ]]      || { echo "ERROR: ${API_RS} not found" >&2; exit 2; }
for f in "${DART_TILE_LOG_FILES[@]}"; do
  [[ -f "${f}" ]] || { echo "ERROR: ${f} not found" >&2; exit 2; }
done

# ---------------------------------------------------------------------------
# 1. The Rust tile storage layer must not reference `url` or `api_key`.
# ---------------------------------------------------------------------------
log "Verifying the Rust tile storage layer keys on (style,z,x,y,retina) only..."
# Match `api_key`/`url` only as code. `grep -rIn` emits `FILE:LINENO:CONTENT`;
# exclude rows whose CONTENT begins with `//` / `//!` / `*` (doc comments, which
# legitimately say "never a URL or api_key"). Inline trailing comments are still
# checked.
COMMENT_ROW=':[0-9]+:[[:space:]]*(//|\*)'
if grep -rInE '\bapi[_-]?key\b' "${TILES_RS_DIR}" | grep -vE "${COMMENT_ROW}" >&2; then
  fail "api_key referenced as code in the Rust tile storage layer (must never reach it)"
fi
if grep -rInE '\burl\b' "${TILES_RS_DIR}" | grep -vE "${COMMENT_ROW}" >&2; then
  fail "a 'url' identifier/column appears in the Rust tile storage layer (no URL is persisted)"
fi

# ---------------------------------------------------------------------------
# 2. Tile-layer log:: lines must be static (no value interpolation).
# ---------------------------------------------------------------------------
log "Verifying Rust tile logs are static strings (no coordinate/URL interpolation)..."
# src/tiles/: any log:: line that contains a '{' format placeholder is suspect.
if grep -rInE 'log::[a-z]+!' "${TILES_RS_DIR}" | grep -F '{' >&2; then
  fail "a log:: line in src/tiles/ interpolates a value — tile logs must be static"
fi
# api.rs: only the tile-related log lines (those mentioning 'tile').
if grep -InE 'log::[a-z]+!' "${API_RS}" | grep -iF 'tile' | grep -F '{' >&2; then
  fail "a tile-related log:: line in api.rs interpolates a value"
fi

# ---------------------------------------------------------------------------
# 3. Dart tile-cache logging only ever emits runtimeType.
# ---------------------------------------------------------------------------
log "Verifying Dart tile-cache logs leak no url/coords/TileKey..."
# (a) Strict files: every log call must reference runtimeType (no counts logged).
for f in "${DART_TILE_FILES[@]}"; do
  bad_logs="$(grep -nE '(debugPrint|[^.]print)\(' "${f}" | grep -v 'runtimeType' || true)"
  if [[ -n "${bad_logs}" ]]; then
    printf '%s\n' "${bad_logs}" >&2
    fail "a log call in ${f##*/} does not emit runtimeType (possible url/coordinate leak)"
  fi
done
# (b) All tile-log files (incl. the URL/coordinate builders): no log call may
# interpolate a url/key/coordinate variable (counts like \$n are allowed).
for f in "${DART_TILE_LOG_FILES[@]}"; do
  if grep -nE '(debugPrint|[^.]print)\(' "${f}" | grep -iE '\$\{?(url|key|tilekey|[zxy])\b' >&2; then
    fail "a log call in ${f##*/} interpolates a url/key/coordinate"
  fi
done

log "OK: tile cache persists/logs no api_key, raw URL, or coordinate."
