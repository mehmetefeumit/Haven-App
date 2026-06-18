#!/usr/bin/env bash
# CI guard: the Stadia Maps API key (or any UUID-shaped secret) must NEVER be
# committed. The key is injected at build time from a gitignored dart-define
# file (haven/dart_defines/secrets.json) or a CI secret — it must not appear in
# any tracked source file, and the injection seam must stay compile-time.
#
# This script contains NO key. It runs in CI (secrets-check job) AND is invoked
# automatically by the Android Gradle / iOS Xcode release pre-build steps, so a
# leak fails the build before any artifact is produced.
#
# Checks:
#   1. No UUID-shaped token (Stadia key shape) in any tracked text file (binary
#      files are skipped). Allowlist is empty today — add explicit paths with
#      justification if a legitimate UUID is ever needed.
#   2. haven/dart_defines/secrets.json is NOT tracked, and the committed
#      secrets.example.json exists and holds ONLY the placeholder.
#   3. haven/lib/src/constants/tiles.dart still injects the key via
#      String.fromEnvironment( and contains no UUID literal (so nobody "fixes"
#      the map by hardcoding the key into the constant).
#
# Exit codes:
#   0  all checks pass
#   1  a violation was found
#   2  expected files missing (misconfiguration)

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DART_DEFINES_DIR="${REPO_ROOT}/haven/dart_defines"
SECRETS_FILE="${DART_DEFINES_DIR}/secrets.json"
EXAMPLE_FILE="${DART_DEFINES_DIR}/secrets.example.json"
TILES_FILE="${REPO_ROOT}/haven/lib/src/constants/tiles.dart"
PLACEHOLDER='STADIA_API_KEY_PLACEHOLDER'

# Stadia API keys are UUIDs. Match that shape anywhere in source.
UUID_RE='[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}'
# Paths exempt from the UUID scan (files with legitimate UUIDs). Keep empty.
ALLOWLIST_RE='^$'

log() {
  printf '\033[1;34m[check_no_committed_secrets]\033[0m %s\n' "$*"
}

fail() {
  printf '\033[1;31m[check_no_committed_secrets] FAIL:\033[0m %s\n' "$*" >&2
  exit 1
}

cd "${REPO_ROOT}"
command -v git >/dev/null 2>&1 || { echo "ERROR: git not found" >&2; exit 2; }

# ---------------------------------------------------------------------------
# 1. No UUID-shaped token in tracked source.
# ---------------------------------------------------------------------------
log "Scanning all tracked text files for UUID-shaped secrets (Stadia key shape)..."
# Populate the array portably: macOS ships bash 3.2, which lacks `mapfile`
# (this guard also runs on the macOS runner via the iOS release build).
scan_files=()
while IFS= read -r _scan_f; do
  scan_files+=("${_scan_f}")
done < <(git ls-files | grep -vE "${ALLOWLIST_RE}")
if [[ ${#scan_files[@]} -gt 0 ]]; then
  # -I skips binary files (treats them as non-matching).
  hits="$(grep -I -nEH "${UUID_RE}" "${scan_files[@]}" 2>/dev/null || true)"
  if [[ -n "${hits}" ]]; then
    printf '%s\n' "${hits}" >&2
    fail "UUID-shaped token found in a tracked file (possible committed Stadia key)"
  fi
fi

# ---------------------------------------------------------------------------
# 2. The real secrets file must be gitignored; the template must be a placeholder.
# ---------------------------------------------------------------------------
log "Verifying haven/dart_defines/secrets.json is not tracked..."
if git ls-files --error-unmatch haven/dart_defines/secrets.json >/dev/null 2>&1; then
  fail "haven/dart_defines/secrets.json is tracked by git — it must stay gitignored"
fi

log "Verifying the committed secrets.example.json holds only the placeholder..."
[[ -f "${EXAMPLE_FILE}" ]] || { echo "ERROR: ${EXAMPLE_FILE} not found" >&2; exit 2; }
grep -Fq "${PLACEHOLDER}" "${EXAMPLE_FILE}" \
  || fail "secrets.example.json lost its ${PLACEHOLDER} value"
if grep -InEH "${UUID_RE}" "${EXAMPLE_FILE}" >/dev/null 2>&1; then
  fail "secrets.example.json contains a UUID — that looks like a real key"
fi

# ---------------------------------------------------------------------------
# 3. The key injection seam must remain compile-time (no hardcoded literal).
# ---------------------------------------------------------------------------
log "Verifying tiles.dart still injects the key via String.fromEnvironment..."
[[ -f "${TILES_FILE}" ]] || { echo "ERROR: ${TILES_FILE} not found" >&2; exit 2; }
grep -Eq 'stadiaApiKey[[:space:]]*=[[:space:]]*String\.fromEnvironment\(' "${TILES_FILE}" \
  || fail "tiles.dart no longer injects stadiaApiKey via String.fromEnvironment("
if grep -InEH "${UUID_RE}" "${TILES_FILE}" >/dev/null 2>&1; then
  fail "tiles.dart contains a UUID literal (possible hardcoded API key)"
fi

# ---------------------------------------------------------------------------
# 4. iOS code-signing material must never be committed. Certs, private keys and
#    provisioning profiles belong in GitHub secrets / the Fastlane Match repo.
# ---------------------------------------------------------------------------
log "Scanning for committed iOS signing artifacts (.p8/.p12/.mobileprovision/.cer)..."
signing_artifacts="$(git ls-files \
  | grep -iE '\.(p8|p12|pfx|mobileprovision|provisionprofile|cer|certSigningRequest)$' || true)"
if [[ -n "${signing_artifacts}" ]]; then
  printf '%s\n' "${signing_artifacts}" >&2
  fail "iOS signing artifact is tracked by git — certs/keys/profiles must stay gitignored secrets"
fi

log "Scanning tracked text files for committed PEM private keys..."
if [[ ${#scan_files[@]} -gt 0 ]]; then
  pem_hits="$(grep -I -lE '\-\-\-\-\-BEGIN ([A-Z0-9]+ )?PRIVATE KEY\-\-\-\-\-' "${scan_files[@]}" 2>/dev/null || true)"
  if [[ -n "${pem_hits}" ]]; then
    printf '%s\n' "${pem_hits}" >&2
    fail "a PEM PRIVATE KEY block is committed in a tracked file"
  fi
fi

log "OK: no committed secrets; key injection stays compile-time."
