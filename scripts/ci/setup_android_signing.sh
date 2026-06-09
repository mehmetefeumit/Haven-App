#!/usr/bin/env bash
# CI helper: decode the Android release keystore from a base64 secret and write
# haven/android/key.properties so the release build is signed with the upload
# key. If the keystore secret is absent, this no-ops and the build falls back to
# debug signing (see haven/android/app/build.gradle.kts) — useful for dry-run
# release builds before the signing secrets are configured.
#
# Reads from the environment (set these as GitHub Actions repository secrets):
#   ANDROID_KEYSTORE_BASE64    base64 of the release keystore (.jks)
#   ANDROID_KEYSTORE_PASSWORD  keystore password
#   ANDROID_KEY_ALIAS          signing key alias
#   ANDROID_KEY_PASSWORD       signing key password
#
# Secrets are never echoed. key.properties + the decoded .jks are gitignored.
#
# Exit codes: 0 ok (or skipped) | non-zero on misconfiguration

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ANDROID_DIR="${REPO_ROOT}/haven/android"
KEYSTORE="${ANDROID_DIR}/app/upload-keystore.jks"
KEY_PROPS="${ANDROID_DIR}/key.properties"

# Create the keystore + key.properties as 0600 (before any secret is written).
umask 077

log()  { printf '\033[1;34m[setup_android_signing]\033[0m %s\n' "$*"; }
fail() { printf '\033[1;31m[setup_android_signing] FAIL:\033[0m %s\n' "$1" >&2; exit 1; }

if [[ -z "${ANDROID_KEYSTORE_BASE64:-}" ]]; then
  log "ANDROID_KEYSTORE_BASE64 not set — skipping; release will use debug-sign fallback."
  exit 0
fi

[[ -n "${ANDROID_KEYSTORE_PASSWORD:-}" ]] || fail "ANDROID_KEYSTORE_PASSWORD required when a keystore is provided"
[[ -n "${ANDROID_KEY_ALIAS:-}" ]]        || fail "ANDROID_KEY_ALIAS required when a keystore is provided"
[[ -n "${ANDROID_KEY_PASSWORD:-}" ]]     || fail "ANDROID_KEY_PASSWORD required when a keystore is provided"

log "decoding release keystore"
base64 -d <<< "${ANDROID_KEYSTORE_BASE64}" > "${KEYSTORE}" \
  || fail "could not base64-decode ANDROID_KEYSTORE_BASE64"

log "writing key.properties (gitignored)"
cat > "${KEY_PROPS}" <<EOF
storeFile=${KEYSTORE}
storePassword=${ANDROID_KEYSTORE_PASSWORD}
keyAlias=${ANDROID_KEY_ALIAS}
keyPassword=${ANDROID_KEY_PASSWORD}
EOF

log "release signing configured."
