#!/usr/bin/env bash
# Publish Haven's release to Zapstore (Nostr app store, https://zapstore.dev).
#
# Reads zapstore.yaml at the repo root. `zsp` resolves the arm64-v8a APK from the
# GitHub Release (metadata_sources: github + match: ^app-arm64-v8a-release\.apk$),
# downloads it plus the icon, uploads them to a Blossom server, and SIGNS the
# kind 32267/30063/3063 Nostr events with $SIGN_WITH. zsp does NOT re-sign the
# APK — it only reads the signing-certificate fingerprint and distributes Haven's
# own signed APK unchanged, so Zapstore stays inside Haven's single signing
# lineage (same key as the GitHub Release / Obtainium builds).
#
# Required env:
#   SIGN_WITH     Haven's Zapstore publisher key. PREFER a NIP-46 `bunker://...`
#                 URL so the nsec never enters the runner env (readable via
#                 /proc/*/environ); a raw `nsec1...` also works.
#
# Optional env:
#   GITHUB_TOKEN  passed through so zsp avoids GitHub API rate limits when it reads
#                 the release/changelog (recommended; not strictly required).
#   ZAPSTORE_CHANNEL  explicit channel override (main|beta|nightly|dev).
#   GITHUB_REF_TYPE / GITHUB_REF_NAME  if no explicit channel and the tag is a
#                 pre-release (contains '-', e.g. v1.2.3-beta.1), publish to the
#                 'beta' channel; final tags go to the default 'main' channel.
#
# zsp is expected on PATH (the CI job installs a pinned release binary first).
#
# Exit codes: 0 ok | 1 misconfiguration / missing tool

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CONFIG="${REPO_ROOT}/zapstore.yaml"

log()  { printf '\033[1;34m[publish_zapstore]\033[0m %s\n' "$*"; }
fail() { printf '\033[1;31m[publish_zapstore] FAIL:\033[0m %s\n' "$1" >&2; exit "${2:-1}"; }

command -v zsp >/dev/null 2>&1 || fail "zsp not found on PATH (the CI job installs a pinned binary first)" 1
[[ -f "${CONFIG}" ]] || fail "zapstore.yaml not found at ${CONFIG}" 1
[[ -n "${SIGN_WITH:-}" ]] || fail "SIGN_WITH is not set (Zapstore publisher key: bunker://... preferred, or nsec1...)" 1

# Channel selection: an explicit override always wins; otherwise a pre-release tag
# (vX.Y.Z-...) publishes to 'beta', and a final tag publishes to 'main' (default).
channel="${ZAPSTORE_CHANNEL:-main}"
if [[ -z "${ZAPSTORE_CHANNEL:-}" && "${GITHUB_REF_TYPE:-}" == "tag" && "${GITHUB_REF_NAME:-}" == *-* ]]; then
  channel="beta"
fi

channel_args=()
if [[ "${channel}" != "main" ]]; then
  channel_args=(--channel "${channel}")
fi

cd "${REPO_ROOT}"

# Validate the config actually resolves the arm64-v8a APK from the GitHub Release
# before signing/publishing anything (exit 0 = the asset was found).
log "validating zapstore.yaml (zsp publish --check)..."
zsp publish --check zapstore.yaml

log "publishing to Zapstore (channel: ${channel})..."
zsp publish zapstore.yaml -y ${channel_args[@]+"${channel_args[@]}"}

log "done."
