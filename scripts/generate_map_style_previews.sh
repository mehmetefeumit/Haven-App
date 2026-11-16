#!/usr/bin/env bash
# Render the map-style page's bundled preview images, once, with the owner's
# Stadia Maps key.
#
# The Map style page (haven/lib/src/pages/settings/map_style_settings_page.dart)
# shows every style over two fixed scenes from images bundled in the app, so
# opening it makes no network request. This script renders those images: one
# per style in kTileStyleCatalog (haven/lib/src/constants/tiles.dart) per scene,
# written to haven/assets/map_style_previews/<config id>_<scene>.webp — the name
# the page derives from TileProviderConfig.id and MapStylePreviewScene.name.
# Commit the eight files it writes. Re-run it only to change a scene or a style.
#
# ---------------------------------------------------------------------------
# UNVERIFIED — CONFIRM BEFORE RUNNING
#
# This script was written without network access to Stadia, so neither the
# endpoint below nor its terms were checked:
#   * STATIC_MAPS_ENDPOINT and the query shape built in render_one() are the
#     Stadia Static Maps API as remembered (center=<lat>,<lon>, zoom=<z>,
#     size=<w>x<h>@2x, api_key=<key>). Check them on docs.stadiamaps.com.
#   * LICENSING: Stadia's standard static maps may not be stored. Stadia offers
#     a separate cacheable static-maps product whose images may be kept while
#     a paid plan is held. Confirm on docs.stadiamaps.com (and the terms of
#     service) WHICH endpoint permits storing the images inside a distributed
#     app, that the account's plan covers it, and point STATIC_MAPS_ENDPOINT at
#     that endpoint before committing any image.
#   * ZOOM: the scenes' zooms are the ones the page's old live FlutterMap used
#     (256 px raster-tile convention). If the static renderer counts zoom the
#     vector way (512 px tiles), its images come out one level wider; compare
#     them with the map at the same place and adjust.
#
# ATTRIBUTION: the images are a Produced Work of OpenStreetMap data (ODbL) in
# Stadia/OpenMapTiles styles. The page shows the real map's credits and the
# ODbL link under them (StaticMapAttribution); if the endpoint also burns an
# attribution into the image, that does not replace the page's links.
# ---------------------------------------------------------------------------
#
# Format and size: each image is <LOGICAL_WIDTH>x<LOGICAL_HEIGHT> map pixels
# rendered at RENDER_SCALE (960x360 px at the default @2x). The height is the
# preview box's 180 dp, so labels appear at their native size; the width covers
# the box on phones up to ~510 dp wide, narrower screens crop the sides around
# the scene's centre. The page decodes at most 180 dp x devicePixelRatio tall,
# so a larger source only ever gets crisper — set RENDER_SCALE=3 if the
# endpoint supports @3x. Lossy WebP with sharp YUV keeps label edges crisp at a
# fraction of a PNG's size (Flutter decodes WebP natively on every platform);
# an image above BUDGET_KB is reported, not refused.
#
# Usage (from anywhere):
#   scripts/generate_map_style_previews.sh
#
# Key source (first match wins, the same order as scripts/build_release.sh):
#   1. haven/dart_defines/secrets.json   (gitignored; local dev)
#   2. $STADIA_API_KEY                   (environment)
# The key is passed to curl on stdin, never on its command line, and is never
# printed — nor is any URL that carries it (Security Rule 15).
#
# Needs: curl, cwebp and webpinfo (libwebp: `brew install webp`,
# `apt install webp`).
#
# Exit codes: 0 ok | 1 render/convert/verify failure | 2 no usable key |
#             3 key is empty/placeholder/malformed | 4 missing tool

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HAVEN_DIR="${REPO_ROOT}/haven"
SECRETS_FILE="${HAVEN_DIR}/dart_defines/secrets.json"
OUT_DIR="${HAVEN_DIR}/assets/map_style_previews"
PLACEHOLDER='STADIA_API_KEY_PLACEHOLDER'
# Stadia keys are UUIDs (scripts/ci/check_no_committed_secrets.sh). Holding the
# key to that shape also keeps it from breaking out of curl's config syntax.
UUID_RE='^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'

# UNVERIFIED — see the header. The one place the endpoint is named.
STATIC_MAPS_ENDPOINT='https://tiles.stadiamaps.com/static'

LOGICAL_WIDTH=480
LOGICAL_HEIGHT=180
RENDER_SCALE=2
WEBP_QUALITY=82
BUDGET_KB=150

# Every TileProviderConfig.id in kTileStyleCatalog. The Stadia style slug is the
# id without its `stadia_` prefix. Pinned to the catalog by
# haven/test/pages/settings/map_style_preview_assets_test.dart.
STYLES=(
  stadia_alidade_smooth
  stadia_alidade_smooth_dark
  stadia_osm_bright
  stadia_outdoors
)

# One scene per MapStylePreviewScene value: "<name> <lat> <lon> <zoom>".
#
# city — the canal ring of Amsterdam, Netherlands. A dense, water-laced core:
#   at zoom 17 "Detailed" fills with legible street names, place and shop
#   labels, tram lines and building footprints that "Minimal" leaves out; any
#   lower and the labels are too sparse to tell the styles apart.
# nature — Lake Louise, Banff National Park, Canada (deliberately another
#   country). A glacial lake ringed by forest, trails and named peaks: at zoom
#   16 "Outdoors" resolves individual trails, the shoreline and summits that
#   "Minimal" renders as a calm empty canvas; any lower and the trail network
#   blurs together. The longitude sits ~half a preview-width east of the lake's
#   eastern tip (near -116.2200), so the frame leans onto the wooded shore,
#   Chateau grounds and trailheads rather than open water.
SCENES=(
  "city 52.3676 4.8895 17"
  "nature 51.4163 -116.2157 16"
)

log()  { printf '\033[1;34m[map_previews]\033[0m %s\n' "$*"; }
fail() { printf '\033[1;31m[map_previews] FAIL:\033[0m %s\n' "$1" >&2; exit "${2:-1}"; }

# --- 1. Tools --------------------------------------------------------------
for tool in curl cwebp webpinfo; do
  command -v "${tool}" >/dev/null 2>&1 \
    || fail "${tool} not found (cwebp/webpinfo: brew install webp | apt install webp)" 4
done

# --- 2. Key, refusing empty/placeholder/malformed --------------------------
api_key=""
if [[ -f "${SECRETS_FILE}" ]]; then
  grep -Fq "${PLACEHOLDER}" "${SECRETS_FILE}" \
    && fail "STADIA_API_KEY is still the placeholder in ${SECRETS_FILE}" 3
  api_key="$(sed -nE 's/.*"STADIA_API_KEY"[[:space:]]*:[[:space:]]*"([^"]*)".*/\1/p' \
    "${SECRETS_FILE}" | head -n 1)"
  [[ -n "${api_key}" ]] || fail "STADIA_API_KEY missing or empty in ${SECRETS_FILE}" 3
  log "using key from ${SECRETS_FILE}"
elif [[ -n "${STADIA_API_KEY:-}" && "${STADIA_API_KEY}" != "${PLACEHOLDER}" ]]; then
  api_key="${STADIA_API_KEY}"
  log "using STADIA_API_KEY from environment"
else
  fail "no usable key: create ${SECRETS_FILE} from secrets.example.json, or export STADIA_API_KEY" 2
fi
[[ "${api_key}" =~ ${UUID_RE} ]] || fail "STADIA_API_KEY is not a Stadia key (UUID shape)" 3
# Children (cwebp, webpinfo) have no use for it.
unset STADIA_API_KEY || true

expected_width=$((LOGICAL_WIDTH * RENDER_SCALE))
expected_height=$((LOGICAL_HEIGHT * RENDER_SCALE))
size_param="${LOGICAL_WIDTH}x${LOGICAL_HEIGHT}"
((RENDER_SCALE > 1)) && size_param+="@${RENDER_SCALE}x"

WORK_DIR="$(mktemp -d)"
cleanup() { rm -rf "${WORK_DIR}"; }
trap cleanup EXIT

# --- 3. Render, convert, verify --------------------------------------------
# render_one <config id> <scene> <lat> <lon> <zoom>
render_one() {
  local id="$1" scene="$2" lat="$3" lon="$4" zoom="$5"
  local name="${id}_${scene}"
  local raw="${WORK_DIR}/${name}.raw" webp="${WORK_DIR}/${name}.webp"
  local url="${STATIC_MAPS_ENDPOINT}/${id#stadia_}?center=${lat},${lon}&zoom=${zoom}&size=${size_param}&api_key=${api_key}"
  local out rc=0

  # The URL reaches curl as a config line on stdin, keeping the key out of the
  # process table. curl's own stderr may echo the URL, so only its exit code is
  # reported. No redirects: a non-200 answer is a failure, never followed.
  out="$(printf 'url = "%s"\n' "${url}" | curl --config - --silent \
    --proto '=https' --max-time 60 --output "${raw}" \
    --write-out '%{http_code} %{content_type}' 2>/dev/null)" || rc=$?
  ((rc == 0)) || fail "${name}: request failed (curl exit ${rc}; see 'man curl', EXIT CODES)"

  local status="${out%% *}" content_type="${out#* }"
  [[ "${status}" == 200 ]] || fail "${name}: HTTP ${status} (expected 200)"
  [[ "${content_type}" == image/* ]] \
    || fail "${name}: response is '${content_type}', not an image"

  cwebp -quiet -q "${WEBP_QUALITY}" -m 6 -sharp_yuv -metadata none \
    "${raw}" -o "${webp}" 2>/dev/null \
    || fail "${name}: cwebp could not convert the response"

  local info width height
  info="$(webpinfo "${webp}")" || fail "${name}: webpinfo rejected the converted image"
  width="$(sed -nE 's/^[[:space:]]*Width:[[:space:]]*([0-9]+).*/\1/p' <<<"${info}" | head -n 1)"
  height="$(sed -nE 's/^[[:space:]]*Height:[[:space:]]*([0-9]+).*/\1/p' <<<"${info}" | head -n 1)"
  [[ "${width}x${height}" == "${expected_width}x${expected_height}" ]] \
    || fail "${name}: image is ${width:-?}x${height:-?} px, expected ${expected_width}x${expected_height}"
}

for id in "${STYLES[@]}"; do
  for entry in "${SCENES[@]}"; do
    read -r scene lat lon zoom <<<"${entry}"
    log "rendering ${id}_${scene}"
    render_one "${id}" "${scene}" "${lat}" "${lon}" "${zoom}"
  done
done
unset api_key

# --- 4. Install all or nothing ---------------------------------------------
# Only once every image rendered and verified, so a failed run never leaves a
# mix of old and new previews.
mkdir -p "${OUT_DIR}"
summary=()
for webp in "${WORK_DIR}"/*.webp; do
  name="$(basename "${webp}")"
  mv -f "${webp}" "${OUT_DIR}/${name}"
  kb=$(( ($(wc -c <"${OUT_DIR}/${name}") + 1023) / 1024 ))
  line="$(printf '  %-42s %4d KB' "${name}" "${kb}")"
  ((kb > BUDGET_KB)) && line+="  (over the ${BUDGET_KB} KB budget: lower WEBP_QUALITY)"
  summary+=("${line}")
done

log "wrote ${#summary[@]} previews (${expected_width}x${expected_height} px) to ${OUT_DIR#"${REPO_ROOT}"/}:"
printf '%s\n' "${summary[@]}"
log "check each image against the scene described above, then commit them."
