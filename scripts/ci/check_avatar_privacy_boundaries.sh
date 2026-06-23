#!/usr/bin/env bash
# CI guard: avatar privacy boundaries.
#
# Haven avatars are E2E-encrypted and shared INLINE over MLS (kind 445) within a
# circle. They MUST NEVER be published as a public Nostr profile (kind 0 /
# Kind::Metadata), uploaded to a CDN/Blossom server, or fetched/uploaded over any
# plain HTTP(S) endpoint. The only network surface an avatar may ever touch is a
# Nostr relay over `wss://` (carrying the encrypted MLS payload). See SECURITY.md
# rule #8 (no relay/CDN contact for an avatar) and the private-avatar design.
#
# This is a pure-grep gate (no Flutter/Rust toolchain) so it runs fast and
# independently of the build/test lanes.
#
# Checks:
#   1. `Image.network(` appears in NO Dart file under haven/lib (a network image
#      widget would reach out to a relay/CDN to render an avatar — forbidden).
#   2. Within the avatar CODE PATHS (the Dart avatar files, haven-core/src/avatar,
#      and the avatar FFI block in rust_builder/src/api.rs), none of:
#        - `Kind::Metadata` or a kind-0 metadata publish
#        - `blossom` / `Blossom`
#        - `imeta` / `MIP-04` upload references
#        - a non-`wss` `http(s)://` URL used for fetching/uploading avatar bytes
#      The scan strips comments and ignores benign `wss://` relays and the
#      `www.w3.org` XML namespace literal (used only to PROVE SVG is rejected).
#
# Exit codes:
#   0  all checks pass
#   1  a privacy-boundary violation was found
#   2  expected files/paths missing (misconfiguration)

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LIB_DIR="${REPO_ROOT}/haven/lib"
CORE_AVATAR_DIR="${REPO_ROOT}/haven-core/src/avatar"
API_FILE="${REPO_ROOT}/haven/rust_builder/src/api.rs"

# Dart files that implement the avatar feature surface.
DART_AVATAR_FILES=(
  "${LIB_DIR}/src/providers/avatar_data_saver_provider.dart"
  "${LIB_DIR}/src/providers/avatar_anti_entropy_provider.dart"
  "${LIB_DIR}/src/providers/own_avatar_provider.dart"
  "${LIB_DIR}/src/providers/member_avatar_provider.dart"
  "${LIB_DIR}/src/widgets/identity/avatar.dart"
  "${LIB_DIR}/src/widgets/map/avatar_image_cache.dart"
)

# The avatar FFI block in api.rs is delimited by these section banners.
API_AVATAR_BEGIN='==================== Avatar'
API_AVATAR_END='==================== Invitation Handling'

log() {
  printf '\033[1;34m[check_avatar_privacy_boundaries]\033[0m %s\n' "$*"
}

fail() {
  printf '\033[1;31m[check_avatar_privacy_boundaries] FAIL:\033[0m %s\n' "$*" >&2
  exit 1
}

[[ -d "${LIB_DIR}" ]] || { echo "ERROR: ${LIB_DIR} not found" >&2; exit 2; }
[[ -d "${CORE_AVATAR_DIR}" ]] || { echo "ERROR: ${CORE_AVATAR_DIR} not found" >&2; exit 2; }
[[ -f "${API_FILE}" ]] || { echo "ERROR: ${API_FILE} not found" >&2; exit 2; }

# ---------------------------------------------------------------------------
# Check 1: no Image.network( anywhere under haven/lib.
#
# Match the literal call form `Image.network(` (with the open paren) so a
# doc-comment reference like `[Image.network]` does not trip the gate. A real
# network-image render would contact a relay/CDN to display an avatar.
# ---------------------------------------------------------------------------
log "Scanning haven/lib for Image.network( ..."
net_offenders="$(grep -rn --include='*.dart' -F 'Image.network(' "${LIB_DIR}" || true)"
if [[ -n "${net_offenders}" ]]; then
  printf '%s\n' "${net_offenders}" >&2
  fail "Image.network( found under haven/lib — avatars must never be fetched over the network (use Image.memory)"
fi

# ---------------------------------------------------------------------------
# Build the exact list of avatar code-path "sources" to scan.
#
# Each source is "<label>::<file>::<line-range>" where line-range is either
# "ALL" (whole file) or "<start>,<end>" (inclusive). This lets us pin the scan
# to the avatar FFI block inside the large api.rs without touching unrelated
# code.
# ---------------------------------------------------------------------------
sources=()

for f in "${DART_AVATAR_FILES[@]}"; do
  [[ -f "${f}" ]] || { echo "ERROR: expected avatar file ${f} not found" >&2; exit 2; }
  sources+=("dart::${f}::ALL")
done

while IFS= read -r f; do
  sources+=("core::${f}::ALL")
done < <(find "${CORE_AVATAR_DIR}" -type f -name '*.rs' | sort)

# Resolve the avatar FFI block line range in api.rs.
api_begin_line="$(grep -nF "${API_AVATAR_BEGIN}" "${API_FILE}" | head -n1 | cut -d: -f1 || true)"
api_end_line="$(grep -nF "${API_AVATAR_END}" "${API_FILE}" | head -n1 | cut -d: -f1 || true)"
if [[ -z "${api_begin_line}" || -z "${api_end_line}" ]]; then
  echo "ERROR: could not locate the avatar FFI block banners in ${API_FILE}" >&2
  echo "       expected '${API_AVATAR_BEGIN}' and '${API_AVATAR_END}'" >&2
  exit 2
fi
if (( api_end_line <= api_begin_line )); then
  echo "ERROR: avatar FFI block banners out of order in ${API_FILE}" >&2
  exit 2
fi
sources+=("ffi::${API_FILE}::${api_begin_line},${api_end_line}")

# ---------------------------------------------------------------------------
# Check 2: scan the avatar code paths for forbidden network/profile surfaces.
#
# extract_code emits "<file>:<lineno>:<text>" for the requested range with:
#   - comment lines stripped (Rust/Dart `//`, `///`; here `^\s*//` lines are
#     dropped entirely — avatar comments legitimately mention these terms).
# We then run targeted greps over the extracted CODE only.
# ---------------------------------------------------------------------------
extract_code() {
  # $1 = file, $2 = range ("ALL" or "start,end")
  local file="$1" range="$2"
  if [[ "${range}" == "ALL" ]]; then
    grep -nE '.*' "${file}"
  else
    sed -n "${range}p" "${file}" | grep -nE '.*' \
      | awk -F: -v off="${range%,*}" '{ $1 = $1 + off - 1 } 1' OFS=:
  fi
}

scan_avatar_paths() {
  # $1 = human description, $2 = forbidden regex (ERE), $3 = optional ERE of
  # benign TOKENS to neutralize (blank out) on each line BEFORE matching.
  #
  # The token-strip approach (vs. dropping the whole line) is deliberate: a line
  # that contains BOTH a benign token (e.g. the W3C XML namespace) and a real
  # offending URL must still fail. We erase only the benign token, leaving any
  # genuine offender intact for the pattern grep to catch.
  local desc="$1" pattern="$2" strip="${3:-}" src label file range body matches
  local found=""
  for src in "${sources[@]}"; do
    label="${src%%::*}"
    file="${src#*::}"
    range="${file##*::}"
    file="${file%%::*}"
    # Pull code and drop whole-line comments (avatar comments legitimately
    # mention these terms; we gate on actual code only).
    body="$(extract_code "${file}" "${range}" | grep -vE '^[0-9]+:[[:space:]]*//')"
    # Neutralize benign tokens so they cannot mask a co-located real offender.
    if [[ -n "${strip}" ]]; then
      body="$(printf '%s\n' "${body}" | sed -E "s#${strip}##g")"
    fi
    matches="$(printf '%s\n' "${body}" | grep -nE "${pattern}" || true)"
    if [[ -n "${matches}" ]]; then
      # Re-key the report with the real file path.
      while IFS= read -r m; do
        # m is "<dummy>:<file-lineno>:<text>"; keep file-lineno + text.
        found+="${file}:${m#*:}"$'\n'
      done <<< "${matches}"
    fi
  done
  if [[ -n "${found}" ]]; then
    printf '%s' "${found}" >&2
    fail "${desc} found in an avatar code path — avatars are MLS-only, never public-profile/CDN"
  fi
}

log "Scanning avatar code paths for public Nostr profile (kind 0 / Kind::Metadata) ..."
# Catch the canonical metadata kind (`Kind::Metadata` / Dart `Kind.metadata`)
# AND the explicit kind-0 constructor forms the codebase actually uses
# (`Kind::Custom(0)`, `Kind::from_u16(0)`, `Kind::Other(0)`, `Kind(0)`, and the
# Dart `Kind.custom(0)` / `Kind.fromU16(0)` equivalents). Each constructor is
# anchored to a literal `( 0 )`, so generic `0` literals (indices, lengths) are
# never false positives.
KIND0_CTORS='::Custom|::from_u16|::Other|\.custom|\.fromU16'
scan_avatar_paths "Kind::Metadata / kind-0 metadata publish" \
  "Kind::Metadata|Kind\.metadata|Kind(${KIND0_CTORS})?[[:space:]]*\([[:space:]]*0[[:space:]]*\)"

log "Scanning avatar code paths for Blossom / CDN upload references ..."
scan_avatar_paths "Blossom reference" \
  '[Bb]lossom'

log "Scanning avatar code paths for imeta / MIP-04 upload references ..."
scan_avatar_paths "imeta / MIP-04 upload reference" \
  'imeta|MIP-04'

log "Scanning avatar code paths for non-wss http(s) fetch/upload URLs ..."
# Flag any http:// or https:// URL. The W3C SVG XML-namespace literal (used in
# tests only to PROVE SVG is rejected) is neutralized first via the strip arg so
# it is not a false positive — but any OTHER http(s) URL on the same line still
# fails. (wss:// relays do not use the http(s) scheme, so they never match.)
scan_avatar_paths "non-wss http(s):// URL" \
  'https?://' \
  'https?://www\.w3\.org/[^"'"'"' ]*'

log "OK: avatars stay MLS-only — no Image.network, no kind-0/Blossom/imeta/HTTP avatar surface."
