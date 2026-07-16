#!/usr/bin/env bash
# CI guard: public-profile privacy boundaries (kind-0 + Blossom migration).
#
# Haven's public Nostr profile (kind-0 metadata + Blossom-hosted picture) is an
# owner-directed exception to the no-public-profiles privacy model, recorded
# 2026-07-12 (docs/PUBLIC_PROFILE_MIGRATION_PLAN.md §1). The module is allowed
# to exist ONLY inside a hard privacy boundary, enforced structurally here:
#
#   1. `Image.network(` appears in NO Dart file under haven/lib — profile
#      pictures are downloaded by Rust (anti-SSRF connect-time IP filtering)
#      and rendered from bytes; no URL ever crosses the FFI (plan D2).
#   2. No circle/group identifier tokens in any profile code path (the profile
#      plane must be unlinkable to circles at the source level).
#   3. IMPORT BOUNDARY: haven-core/src/profile/** must not reach the circle or
#      MLS modules (`crate::circle`, `crate::nostr::mls`, `mdk`,
#      `exporter_secret`). This — not token check 2 — is what enforces key
#      separation structurally: profile events can only ever be signed by the
#      Nostr identity key because no MLS handle is reachable from the module
#      (security review F3).
#   4. kind-0 construction (Kind::Metadata / kind-0 ctors /
#      EventBuilder::metadata) is CONFINED to haven-core/src/profile/ + the
#      profile FFI banner block in rust_builder/src/api.rs. Everything else —
#      all of haven-core/src, the rest of api.rs, and ALL of haven/lib (event
#      construction is Rust-only per plan D2, so even profile Dart files must
#      not build kind-0) — is scanned as the complement and must be clean.
#   5. HTTPS-only Blossom: no plaintext `http://` literal in profile code
#      paths (loopback exempt — debug/e2e builds only), and the
#      DEFAULT_BLOSSOM_SERVER constant must be an `https://` URL.
#   6. Retraction no-op gate structurally bound at the RETRACTION SITE.
#      Publishing a public profile is UNCONDITIONAL (public-by-default,
#      owner-directed 2026-07-16, matching White Noise): there is no consent
#      flag and normal publishers carry no gate. The one publish-side invariant
#      that survives is the retraction no-op gate: every fn on the explicit
#      retraction allowlist (CONSENT_GATE_EXEMPT_FNS — the ONLY fns that build a
#      blank kind-0 republish / kind-5 deletion) must call has_published_profile()
#      BEFORE it initiates that footprint, so a "delete/remove" action can never
#      CREATE the first public event for a pubkey that never published (security
#      review F2). Non-allowlisted publishers are NOT checked here (they publish
#      unconditionally by design). Unit tests (#[cfg(test)] modules) are skipped
#      (brace-walked out). A retraction fn that drops its has_published_profile()
#      gate fails this check.
#
# This is a pure grep/awk gate (no Flutter/Rust toolchain) so it runs fast and
# independently of the build/test lanes. It replaces
# check_avatar_privacy_boundaries.sh at the Wave-6 cutover; both guards run
# during the flag-gated coexistence window.
#
# Exit codes:
#   0  all checks pass
#   1  a privacy-boundary violation was found
#   2  expected files/paths missing (misconfiguration). NOTE: until the
#      profile module lands, exit 2 ("haven-core/src/profile not found") is
#      the INTENDED red state — the guard lands first (plan §7.3 / M1) and
#      goes green only when the module exists and satisfies checks 1-6.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LIB_DIR="${REPO_ROOT}/haven/lib"
CORE_SRC_DIR="${REPO_ROOT}/haven-core/src"
CORE_PROFILE_DIR="${REPO_ROOT}/haven-core/src/profile"
API_FILE="${REPO_ROOT}/haven/rust_builder/src/api.rs"

# The profile FFI block in api.rs is opened by this section banner (expected
# full form: `// ==================== Profile (public Nostr metadata)`); the
# block ends at the NEXT `====================` section banner, or EOF if the
# profile block is the last section.
API_PROFILE_BEGIN='==================== Profile'

log() {
  printf '\033[1;34m[check_profile_privacy_boundaries]\033[0m %s\n' "$*"
}

fail() {
  printf '\033[1;31m[check_profile_privacy_boundaries] FAIL:\033[0m %s\n' "$*" >&2
  exit 1
}

# ---------------------------------------------------------------------------
# kind-0 construction tokens (check 4 only — check 6 gates on publish CALL sites,
# not construction).
#
# Catch the canonical metadata kind (`Kind::Metadata` / Dart `Kind.metadata`),
# the metadata event builder (`EventBuilder::metadata`), AND the explicit
# kind-0 constructor forms (`Kind::Custom(0)`, `Kind::from_u16(0)`,
# `Kind::Other(0)`, `Kind(0)`, Dart `Kind.custom(0)` / `Kind.fromU16(0)`).
# Each constructor is anchored to a literal `( 0 )`, so generic `0` literals
# (indices, lengths) are never false positives.
# ---------------------------------------------------------------------------
KIND0_CTORS='::Custom|::from_u16|::Other|\.custom|\.fromU16'
KIND0_PATTERN="Kind::Metadata|Kind\.metadata|EventBuilder::metadata|Kind(${KIND0_CTORS})?[[:space:]]*\([[:space:]]*0[[:space:]]*\)"

# ---------------------------------------------------------------------------
# Retraction allowlist (checks 4+6) — the ONLY fns that build a profile event
# by way of a blank kind-0 republish / kind-5 deletion. Normal publishing is
# unconditional (public-by-default), so publishers carry no gate; retraction is
# special because it must be a no-op for a never-published pubkey:
#
#   * check 4 still confines these fns to the profile module / FFI block;
#   * check 6 requires each allowlisted fn to be gated on
#     has_published_profile() BEFORE the event construction, so a retraction
#     can never mint a first public event for a pubkey that never published
#     (security review F2).
#
# Extending this list is a deliberate, reviewable act: a name may be added
# ONLY for a builder that is provably incapable of emitting new profile
# content (blank kind-0 or kind-5 deletion only). Names per plan §4.1/§5.
# ---------------------------------------------------------------------------
readonly -a CONSENT_GATE_EXEMPT_FNS=(
  delete_public_profile      # core publish.rs: blank kind-0 + kind-5 + Blossom DELETE (plan D10)
  delete_my_public_profile   # FFI wrapper of the above (plan §5)
  remove_my_profile_picture  # FFI: clears the picture field via retraction republish (plan §5)
)

# ---------------------------------------------------------------------------
# Misconfiguration guards (exit 2). The CORE_PROFILE_DIR guard is the intended
# RED state until the profile module lands (plan §7.3 / milestone M1).
# ---------------------------------------------------------------------------
[[ -d "${LIB_DIR}" ]] || { echo "ERROR: ${LIB_DIR} not found" >&2; exit 2; }
[[ -f "${API_FILE}" ]] || { echo "ERROR: ${API_FILE} not found" >&2; exit 2; }
if [[ ! -d "${CORE_PROFILE_DIR}" ]]; then
  echo "ERROR: haven-core/src/profile not found (expected: ${CORE_PROFILE_DIR})" >&2
  echo "       The public-profile module has not landed yet. This exit-2 RED state is" >&2
  echo "       the intended M1 baseline (docs/PUBLIC_PROFILE_MIGRATION_PLAN.md §7.3);" >&2
  echo "       the guard goes green once the module exists and passes checks 1-6." >&2
  exit 2
fi

# ---------------------------------------------------------------------------
# Check 1: no Image.network( anywhere under haven/lib.
#
# Match the literal call form `Image.network(` (with the open paren) so a
# doc-comment reference like `[Image.network]` does not trip the gate. A real
# network-image render would leak the viewer's IP to whatever host the URL
# points at, bypassing the Rust download path's anti-SSRF filter.
# ---------------------------------------------------------------------------
log "Scanning haven/lib for Image.network( ..."
net_offenders="$(grep -rn --include='*.dart' -F 'Image.network(' "${LIB_DIR}" || true)"
if [[ -n "${net_offenders}" ]]; then
  printf '%s\n' "${net_offenders}" >&2
  fail "Image.network( found under haven/lib — profile pictures must be downloaded by Rust (anti-SSRF filtered) and rendered via Image.memory"
fi

# ---------------------------------------------------------------------------
# Build the exact list of profile code-path "sources" to scan.
#
# Each source is "<label>::<file>::<line-range>" where line-range is either
# "ALL" (whole file) or "<start>,<end>" (inclusive). This lets us pin the scan
# to the profile FFI block inside the large api.rs without touching unrelated
# code.
# ---------------------------------------------------------------------------
sources=()

# Dart files that implement the profile feature surface — auto-discovered by
# the `*profile*` filename convention (plan §6: profile_service.dart,
# own_profile_provider.dart, member_profile_provider.dart,
# public_profile_notice.dart, member_profile_refresh_provider.dart,
# ...). Auto-discovery (vs a hand-maintained list) is the safer choice for a
# privacy gate: a NEWLY added profile widget/provider is scanned automatically
# (no chance of forgetting to list it — a silent coverage gap), and a renamed
# or removed one never leaves a stale reference that breaks the gate on an
# unrelated change.
mapfile -t dart_profile_files < <(find "${LIB_DIR}" -type f -name '*profile*.dart' | sort)

# Misconfiguration guard: the profile Dart surface must not silently shrink to
# near-nothing — e.g. a wholesale rename away from the `profile` convention
# would leave the token scan covering an empty set and pass vacuously. The
# plan lands >= 5 profile Dart files (M7); require a sane floor and revisit
# this guard (and the `*profile*` convention) if the surface ever legitimately
# consolidates below it.
readonly MIN_PROFILE_DART_FILES=3
if (( ${#dart_profile_files[@]} < MIN_PROFILE_DART_FILES )); then
  echo "ERROR: found ${#dart_profile_files[@]} profile Dart file(s) under ${LIB_DIR}" \
       "(expected >= ${MIN_PROFILE_DART_FILES})." >&2
  echo "       Either the M7 Flutter profile scaffolding has not landed yet (expected" >&2
  echo "       RED until it does), or profile files were renamed away from the" >&2
  echo "       '*profile*' convention — update this guard so the surface stays covered." >&2
  exit 2
fi

for f in "${dart_profile_files[@]}"; do
  sources+=("dart::${f}::ALL")
done

mapfile -t core_profile_files < <(find "${CORE_PROFILE_DIR}" -type f -name '*.rs' | sort)

# Misconfiguration guard: an empty/near-empty profile module means the Rust
# scans cover nothing and pass vacuously. Plan §4.1 specifies ~9 files.
readonly MIN_PROFILE_CORE_FILES=2
if (( ${#core_profile_files[@]} < MIN_PROFILE_CORE_FILES )); then
  echo "ERROR: found ${#core_profile_files[@]} Rust file(s) under ${CORE_PROFILE_DIR}" \
       "(expected >= ${MIN_PROFILE_CORE_FILES})." >&2
  exit 2
fi

for f in "${core_profile_files[@]}"; do
  sources+=("core::${f}::ALL")
done

# Resolve the profile FFI block line range in api.rs: from the profile banner
# to the next `====================` section banner (or EOF if last section).
api_begin_line="$(grep -nF "${API_PROFILE_BEGIN}" "${API_FILE}" | head -n1 | cut -d: -f1 || true)"
if [[ -z "${api_begin_line}" ]]; then
  echo "ERROR: could not locate the profile FFI block banner in ${API_FILE}" >&2
  echo "       expected '${API_PROFILE_BEGIN}' (full form per plan §5:" >&2
  echo "       '// ==================== Profile (public Nostr metadata)')" >&2
  exit 2
fi
api_end_line="$(awk -v b="${api_begin_line}" 'NR > b && /====================/ { print NR; exit }' "${API_FILE}")"
if [[ -z "${api_end_line}" ]]; then
  api_end_line="$(wc -l < "${API_FILE}")"
fi
if (( api_end_line <= api_begin_line )); then
  echo "ERROR: profile FFI block banners out of order in ${API_FILE}" >&2
  exit 2
fi
sources+=("ffi::${API_FILE}::${api_begin_line},${api_end_line}")

# ---------------------------------------------------------------------------
# Scan machinery (style of check_avatar_privacy_boundaries.sh).
#
# extract_code emits "<lineno>:<text>" for the requested range; callers drop
# whole-line comments (`^\s*//`) before matching — profile comments
# legitimately mention forbidden terms, but ONLY on their own comment lines
# (a trailing same-line comment mentioning a forbidden token WILL trip the
# gate; keep such prose on its own line). We deliberately do NOT use a
# char-level `//`-stripper here: it would truncate string literals at the
# `//` of every URL and blind the http(s) checks.
# ---------------------------------------------------------------------------
extract_code() {
  # $1 = file, $2 = range ("ALL" or "start,end")
  local file="$1" range="$2"
  if [[ "${range}" == "ALL" ]]; then
    grep -nE '.*' "${file}" || true
  else
    { sed -n "${range}p" "${file}" | grep -nE '.*' \
      | awk -F: -v off="${range%,*}" '{ $1 = $1 + off - 1 } 1' OFS=: ; } || true
  fi
}

# Blanks the code of any numbered line ("<lineno>:<code>", as emitted by
# extract_code) that sits inside a `#[cfg(test)]` module, brace-walked the same
# way check_consent_gate marks test lines. Line numbers are preserved (blanked
# lines keep their "<lineno>:" prefix) so reporting stays accurate and no scan
# is shifted. Used ONLY by check 5's http:// scan: production Blossom traffic
# stays strictly HTTPS-only, while test code may assert require_https REJECTS a
# non-loopback http:// URL (which necessarily requires the literal). Rust-only
# by construction — Dart/FFI sources have no `#[cfg(test)]` mod so they pass
# through unchanged.
strip_test_modules() {
  awk '
    {
      match($0, /^[0-9]+/); lineno[NR] = substr($0, 1, RLENGTH)
      code[NR] = substr($0, RLENGTH + 2)
    }
    END {
      depth = 0; intest = 0; pending = 0; testdepth = 0
      for (j = 1; j <= NR; j++) {
        t = code[j]
        if (!intest && t ~ /#\[[[:space:]]*cfg\(test\)/) pending = 1
        tmp = t; o = gsub(/[{]/, "", tmp)
        tmp = t; c = gsub(/[}]/, "", tmp)
        if (!intest && pending && o > 0 && t ~ /(^|[^A-Za-z0-9_])mod([^A-Za-z0-9_]|$)/) {
          intest = 1; testdepth = depth; pending = 0
        }
        istest[j] = intest
        depth += o - c
        if (intest && depth <= testdepth) intest = 0
      }
      for (j = 1; j <= NR; j++) {
        if (istest[j]) print lineno[j] ":"
        else print lineno[j] ":" code[j]
      }
    }'
}

scan_profile_paths() {
  # $1 = human description, $2 = forbidden regex (ERE), $3 = optional label
  # filter (only scan sources with this label; empty = all), $4 = optional ERE
  # of benign TOKENS to neutralize (blank out) on each line BEFORE matching,
  # $5 = "strip-tests" to blank out `#[cfg(test)]` module bodies before matching
  # (check 5 only; keeps production strictly HTTPS-only while letting tests
  # assert http:// rejection).
  #
  # The token-strip approach (vs. dropping the whole line) is deliberate: a
  # line that contains BOTH a benign token (e.g. a loopback URL) and a real
  # offending URL must still fail. We erase only the benign token, leaving any
  # genuine offender intact for the pattern grep to catch.
  local desc="$1" pattern="$2" only_label="${3:-}" strip="${4:-}" strip_tests="${5:-}"
  local src label file range body matches
  local found=""
  for src in "${sources[@]}"; do
    label="${src%%::*}"
    file="${src#*::}"
    range="${file##*::}"
    file="${file%%::*}"
    if [[ -n "${only_label}" && "${label}" != "${only_label}" ]]; then
      continue
    fi
    # Pull code and drop whole-line comments (we gate on actual code only).
    body="$(extract_code "${file}" "${range}" | grep -vE '^[0-9]+:[[:space:]]*//' || true)"
    # Blank #[cfg(test)] module bodies when requested (check 5 only).
    if [[ "${strip_tests}" == "strip-tests" ]]; then
      body="$(printf '%s\n' "${body}" | strip_test_modules)"
    fi
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
    fail "${desc}"
  fi
}

# ---------------------------------------------------------------------------
# Check 2: no circle/group identifier tokens in any profile code path.
#
# The profile plane must be unlinkable to circles: no group/circle identifier
# may appear in the profile module, the profile Dart files, or the profile FFI
# block (plan §4.4: cache keyed by pubkey, no `h` tags, no group columns).
# `circleId` (Dart camelCase) is included alongside the plan's token list.
# ---------------------------------------------------------------------------
log "Scanning profile code paths for circle/group identifier tokens ..."
scan_profile_paths \
  "circle/group identifier token found in a profile code path — profiles must be unlinkable to circles (keyed by pubkey only)" \
  'nostr_group_id|MlsGroupId|mls_group_id|GroupId|circle_id|circleId|CircleId'

# ---------------------------------------------------------------------------
# Check 3: IMPORT BOUNDARY — haven-core/src/profile/** must not reach the
# circle or MLS modules. This is the structural key-separation enforcement
# (security review F3): with no MLS handle reachable from `profile/`, kind-0 /
# kind-24242 events can only ever be signed by the Nostr identity key — never
# the MLS signing key, never anything exporter-secret-derived. Beyond the
# plan's four tokens, bare `circle::` / `mls::` path segments are also banned
# (catches grouped `use crate::{circle, ...}` imports and inline paths).
# ---------------------------------------------------------------------------
log "Scanning haven-core/src/profile for circle/MLS/mdk import-boundary breaches ..."
scan_profile_paths \
  "import-boundary breach in haven-core/src/profile — the profile module must not reach crate::circle / crate::nostr::mls / mdk / exporter_secret (key separation, security review F3)" \
  'crate::circle\b|crate::nostr::mls\b|\bcircle::|\bmls::|\bmdk|Mdk|MDK|exporter_secret' \
  'core'

# ---------------------------------------------------------------------------
# Check 4: kind-0 construction CONFINED to the profile module + profile FFI
# block. Scan the COMPLEMENT: all of haven-core/src except profile/, all of
# api.rs except the profile banner range, and ALL of haven/lib (stricter than
# "except *profile* files": per plan D2 all event construction is Rust-only,
# so no Dart file — profile-named or not — may build kind-0). Whole-line
# comments are dropped, mirroring the profile-path scans.
#
# The retraction builders (CONSENT_GATE_EXEMPT_FNS above) are NOT exempt from
# this confinement — they live inside profile/; check 6 additionally requires
# them to carry the has_published_profile() no-op gate. A kind-0 builder added
# anywhere else fails here.
# ---------------------------------------------------------------------------
log "Scanning the complement (everything outside the profile module) for kind-0 construction ..."
COMMENT_HIT='^[^:]+:[0-9]+:[[:space:]]*//'
complement_hits=""

core_hits="$(grep -rnE --include='*.rs' "${KIND0_PATTERN}" "${CORE_SRC_DIR}" 2>/dev/null \
  | grep -vF "${CORE_PROFILE_DIR}/" | grep -vE "${COMMENT_HIT}" || true)"
[[ -n "${core_hits}" ]] && complement_hits+="${core_hits}"$'\n'

dart_hits="$(grep -rnE --include='*.dart' "${KIND0_PATTERN}" "${LIB_DIR}" 2>/dev/null \
  | grep -vE "${COMMENT_HIT}" || true)"
[[ -n "${dart_hits}" ]] && complement_hits+="${dart_hits}"$'\n'

api_hits="$(grep -nE "${KIND0_PATTERN}" "${API_FILE}" \
  | awk -F: -v b="${api_begin_line}" -v e="${api_end_line}" '$1 < b || $1 > e' \
  | sed "s#^#${API_FILE}:#" | grep -vE "${COMMENT_HIT}" || true)"
[[ -n "${api_hits}" ]] && complement_hits+="${api_hits}"$'\n'

if [[ -n "${complement_hits}" ]]; then
  printf '%s' "${complement_hits}" >&2
  fail "kind-0 construction found OUTSIDE haven-core/src/profile + the profile FFI block — public profile metadata may only be built inside the consent-gated profile module"
fi

# ---------------------------------------------------------------------------
# Check 5: HTTPS-only Blossom.
#
# (a) No plaintext `http://` literal in PRODUCTION profile code. Loopback
#     (127.0.0.1 / localhost / [::1]) is neutralized before matching — the
#     debug/e2e-only exemption (plan §4 blossom.rs) — but any OTHER http://
#     URL on the same line still fails. `#[cfg(test)]` modules are stripped
#     first (strip-tests): unit tests must be able to assert require_https
#     REJECTS a non-loopback http:// URL, and reference the Android emulator
#     loopback alias, without weakening the production HTTPS-only guarantee.
# (b) The DEFAULT_BLOSSOM_SERVER constant must be assigned an https:// URL.
#     Required to exist once any *blossom* file exists in the module;
#     validated whenever present.
# ---------------------------------------------------------------------------
log "Scanning profile code paths for plaintext http:// URLs (loopback exempt) ..."
scan_profile_paths \
  "plaintext http:// URL found in production profile code — Blossom/profile traffic is HTTPS-only (loopback is exempt for debug/e2e builds only)" \
  'http://' \
  '' \
  'http://(127\.0\.0\.1|localhost|\[::1\])[^"'"'"'[:space:]]*' \
  strip-tests

log "Checking DEFAULT_BLOSSOM_SERVER is https:// ..."
mapfile -t blossom_files < <(find "${CORE_PROFILE_DIR}" -type f -name '*blossom*.rs' | sort)
# Bind the extraction to the ASSIGNMENT (`DEFAULT_BLOSSOM_SERVER ... =`), not a
# mere reference: a reference line can carry an unrelated quoted string (e.g. a
# loopback debug literal) that would poison the value. Take the first quoted
# string AFTER the `=`, allowing a 2-line rustfmt wrap.
assign_block="$(cat "${core_profile_files[@]}" | grep -vE '^[[:space:]]*//' \
  | grep -A2 -E 'DEFAULT_BLOSSOM_SERVER[^=]*=' | head -n3 || true)"
default_server="$(printf '%s\n' "${assign_block}" | sed -E '1s/^[^=]*=//' \
  | grep -oE '"[^"]+"' | head -n1 | tr -d '"' || true)"
if [[ -n "${default_server}" ]]; then
  if [[ "${default_server}" != https://* ]]; then
    fail "DEFAULT_BLOSSOM_SERVER is '${default_server}' — it must start with https:// (plan D5: HTTPS-only Blossom)"
  fi
elif (( ${#blossom_files[@]} > 0 )); then
  fail "a *blossom* file exists in haven-core/src/profile but no DEFAULT_BLOSSOM_SERVER string assignment was found — the https:// default (plan D5) must be defined in the profile module"
else
  log "  (no *blossom* file in the module yet — DEFAULT_BLOSSOM_SERVER check deferred)"
fi

# ---------------------------------------------------------------------------
# Check 6: retraction no-op gate structurally bound at the retraction SITE.
#
# Publishing a public profile is unconditional (public-by-default), so ordinary
# publishers carry no gate and are NOT checked here. The surviving invariant is
# the retraction no-op gate: a "delete/remove" action must never CREATE the
# first public event for a pubkey that never published (security review F2).
#
# Function-body-span technique (check_m7_native_wake_guards.sh): for every
# PRODUCTION Rust fn on the retraction allowlist (CONSENT_GATE_EXEMPT_FNS) whose
# (comment-stripped) body INITIATES a public footprint — a CALL to a footprint
# primitive (publish_metadata / publish_event, or upload_profile_picture) — a
# call to has_published_profile() must appear BEFORE that first footprint. Any
# fn NOT on the allowlist is skipped: it publishes unconditionally by design.
#
# Unit tests (#[cfg(test)] modules) are excluded (brace-walked out). Token
# reintroduction in dead comments cannot pass (the span is comment-stripped); a
# gate/footprint in a DIFFERENT fn cannot pass (the search is bounded to the
# enclosing fn body).
# ---------------------------------------------------------------------------
log "Checking retraction no-op gate binding at profile retraction call sites ..."

# Comment-aware view (m7 technique): strips /* */ and // — ONE output line per
# input line (line numbers preserved). Char-level, not string-aware: a URL's
# `//` truncates the rest of that line, which is safe here because none of the
# check-6 tokens can legitimately share a line with a URL literal.
code_view() {
  awk '
    {
      line = $0; out = ""; i = 1; n = length(line)
      while (i <= n) {
        if (inblock) {
          e = index(substr(line, i), "*/")
          if (e == 0) { i = n + 1 } else { i += e + 1; inblock = 0 }
        } else {
          two = substr(line, i, 2)
          if (two == "/*") { inblock = 1; i += 2 }
          else if (two == "//") { i = n + 1 }
          else { out = out substr(line, i, 1); i += 1 }
        }
      }
      print out
    }' "$1"
}

# Footprint-call tokens for check 6 (awk dynamic ERE — bracket forms instead of
# backslash escapes, which `awk -v` would mangle). A "footprint call" is a CALL
# to one of the publish/upload primitives that create a public footprint:
# publish_metadata / publish_event (relay publish), or upload_profile_picture
# (Blossom upload). Anchored on a non-identifier boundary AND a following `(` so
# that (a) a longer identifier that merely ENDS in a token — e.g. the FFI fn
# upload_my_profile_picture — never matches, and (b) only actual call sites,
# never a bare fn reference, are caught.
FOOTPRINT_TOKENS_AWK='(^|[^A-Za-z0-9_])(publish_metadata|publish_event|upload_profile_picture)[[:space:]]*[(]'

check_consent_gate() {
  # $1 = file, $2 = first line to consider, $3 = last line to consider.
  # Emits one "file:line: ..." violation per offending fn; empty output = OK.
  #
  # Publishing is unconditional (public-by-default), so ordinary publishers are
  # NOT checked. Only the retraction allowlist is enforced: for every PRODUCTION
  # fn whose NAME is on CONSENT_GATE_EXEMPT_FNS and whose body initiates a public
  # footprint (a call to a footprint primitive), require has_published_profile()
  # to precede the first such call (the retraction no-op gate). Any non-allowlist
  # fn is skipped. #[cfg(test)] modules are brace-walked out.
  local file="$1" minline="$2" maxline="$3"
  code_view "${file}" | awk \
    -v file="${file}" -v minline="${minline}" -v maxline="${maxline}" \
    -v retract_gate='has_published_profile' \
    -v footre="${FOOTPRINT_TOKENS_AWK}" \
    -v allow="${CONSENT_GATE_EXEMPT_FNS[*]}" '
    { lines[NR] = $0 }
    END {
      nallow = split(allow, aw, " ")
      for (k = 1; k <= nallow; k++) allowset[aw[k]] = 1
      n = NR

      # Pass 1: mark lines inside a `#[cfg(test)]` mod block (brace-walked) so
      # unit tests that call the ungated primitives directly are not flagged.
      depth = 0; intest = 0; pending = 0; testdepth = 0
      for (j = 1; j <= n; j++) {
        t = lines[j]
        if (!intest && t ~ /#\[[[:space:]]*cfg\(test\)/) pending = 1
        tmp = t; o = gsub(/[{]/, "", tmp)
        tmp = t; c = gsub(/[}]/, "", tmp)
        if (!intest && pending && o > 0 && t ~ /(^|[^A-Za-z0-9_])mod([^A-Za-z0-9_]|$)/) {
          intest = 1; testdepth = depth; pending = 0
        }
        if (intest) in_test[j] = 1
        depth += o - c
        if (intest && depth <= testdepth) intest = 0
      }

      # Pass 2: per production fn ON THE RETRACTION ALLOWLIST, find the first
      # footprint call and require has_published_profile() to precede it.
      for (i = 1; i <= n; i++) {
        if (i < minline || i > maxline) continue
        if (in_test[i]) continue
        if (!match(lines[i], /(^|[^A-Za-z0-9_])fn[[:space:]]+[A-Za-z0-9_]+/)) continue
        frag = substr(lines[i], RSTART, RLENGTH)
        sub(/^.*fn[[:space:]]+/, "", frag)
        name = frag
        # Walk the fn body by brace depth from the signature line. A `;`
        # before the first `{` means a bodyless decl (trait sig) — skip it so
        # the walk cannot leak into the next fn.
        depth = 0; seen = 0; bodyless = 0
        retline = 0; publine = 0
        for (j = i; j <= n; j++) {
          t = lines[j]
          # Strip the fn declaration (`fn NAME`) from the line before footprint
          # matching so a primitive definition line (e.g. `fn publish_metadata(`)
          # cannot self-match a footprint token.
          st = t
          gsub(/(^|[^A-Za-z0-9_])fn[[:space:]]+[A-Za-z0-9_]+/, " ", st)
          if (!retline && index(t, retract_gate) > 0) retline = j
          if (!publine && st ~ footre) publine = j
          tmp = t; o = gsub(/[{]/, "", tmp)
          tmp = t; c = gsub(/[}]/, "", tmp)
          depth += o - c
          if (o > 0) seen = 1
          if (seen && depth <= 0) break
          if (!seen && index(t, ";") > 0) { bodyless = 1; break }
        }
        if (bodyless || publine == 0) continue
        if (!(name in allowset)) continue
        if (retline == 0 || retline > publine)
          printf "%s:%d: fn %s (retraction allowlist) initiates a profile public footprint without a preceding has_published_profile() no-op gate (retraction must never CREATE a first public event)\n", file, publine, name
      }
    }'
}

gate_violations=""
for f in "${core_profile_files[@]}"; do
  v="$(check_consent_gate "${f}" 1 999999999)"
  if [[ -n "${v}" ]]; then
    gate_violations+="${v}"$'\n'
  fi
done
v="$(check_consent_gate "${API_FILE}" "${api_begin_line}" "${api_end_line}")"
if [[ -n "${v}" ]]; then
  gate_violations+="${v}"$'\n'
fi
if [[ -n "${gate_violations}" ]]; then
  printf '%s' "${gate_violations}" >&2
  fail "retraction footprint without its has_published_profile() no-op gate — an allowlisted retraction builder must be structurally bound to has_published_profile() so it never CREATES a first public event"
fi

log "OK: public-profile privacy boundaries hold — no Image.network, no circle/group tokens, import boundary intact, kind-0 confined to the profile module, HTTPS-only Blossom, retraction no-op gate bound at every retraction call site."
