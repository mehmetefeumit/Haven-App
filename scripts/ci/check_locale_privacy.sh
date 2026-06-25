#!/usr/bin/env bash
# CI guard: locale stays a local-only preference.
#
# The user's chosen app language is persisted on-device in SharedPreferences
# (key `haven.locale.tag`) and read ONLY by the root MaterialApp to set its
# `locale`. It is a BCP-47 language subtag with no identity/location/crypto
# material, but it is still a fingerprinting signal: it must NEVER flow to a
# relay or any other out-of-band consumer. This guard fails if the locale state
# or its storage key is referenced from anywhere outside a small allowlist of
# UI/wiring files, so a future change cannot silently start propagating the
# language (e.g. into a Nostr event builder). See locale_provider.dart and the
# i18n plan's privacy section.
#
# Pure-grep gate (no Flutter/Rust toolchain) so it runs fast and independently.
#
# Checks:
#   1. `localeControllerProvider` / `kLocaleKey` appear ONLY in the allowlisted
#      files (the provider, main.dart wiring, and the two settings pages).
#      Anything else under haven/lib referencing them fails the gate — a broad
#      allowlist scan (like the avatar-privacy guard) rather than a single
#      directory, so an event builder added OUTSIDE services/ is still caught.
#   2. The literal storage key `haven.locale.tag` appears ONLY in
#      locale_provider.dart (its single source of truth).
#
# Adding a new LEGITIMATE, non-network consumer of the locale means adding it to
# ALLOWED below — deliberate friction so each new reader is reviewed.
#
# Exit codes:
#   0  all checks pass
#   1  a privacy-boundary violation was found
#   2  expected files/paths missing (misconfiguration)

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LIB_DIR="${REPO_ROOT}/haven/lib"
PROVIDER_FILE="${LIB_DIR}/src/providers/locale_provider.dart"
LOCALE_KEY='haven.locale.tag'

# Files permitted to reference the locale state. Keep this minimal; every entry
# is a non-network consumer (the provider definition, the root wiring, and the
# settings UI that lets the user pick a language).
declare -A ALLOWED=(
  ["${PROVIDER_FILE}"]=1
  ["${LIB_DIR}/main.dart"]=1
  ["${LIB_DIR}/src/pages/settings/appearance_settings_page.dart"]=1
  ["${LIB_DIR}/src/pages/settings/language_settings_page.dart"]=1
)

log() {
  printf '\033[1;34m[check_locale_privacy]\033[0m %s\n' "$*"
}

fail() {
  printf '\033[1;31m[check_locale_privacy] FAIL:\033[0m %s\n' "$*" >&2
  exit 1
}

[[ -d "${LIB_DIR}" ]] || { echo "ERROR: ${LIB_DIR} not found" >&2; exit 2; }
[[ -f "${PROVIDER_FILE}" ]] || { echo "ERROR: ${PROVIDER_FILE} not found" >&2; exit 2; }

# ---------------------------------------------------------------------------
# Check 1: locale state is referenced only by the allowlisted files.
# ---------------------------------------------------------------------------
log "Scanning haven/lib for locale-state references outside the allowlist ..."
state_offenders=""
while IFS= read -r line; do
  [[ -z "${line}" ]] && continue
  file="${line%%:*}"
  if [[ -z "${ALLOWED[${file}]:-}" ]]; then
    state_offenders+="${line}"$'\n'
  fi
done < <(grep -rn --include='*.dart' -E 'localeControllerProvider|kLocaleKey' "${LIB_DIR}" || true)
if [[ -n "${state_offenders}" ]]; then
  printf '%s' "${state_offenders}" >&2
  fail "locale state referenced outside the allowlisted files — the language must never reach a relay or other out-of-band consumer (extend ALLOWED only after confirming the reader is non-network)"
fi

# ---------------------------------------------------------------------------
# Check 2: the storage-key literal lives only in locale_provider.dart.
# ---------------------------------------------------------------------------
log "Verifying the '${LOCALE_KEY}' storage key has a single source ..."
key_offenders=""
while IFS= read -r f; do
  [[ -z "${f}" ]] && continue
  [[ "${f}" == "${PROVIDER_FILE}" ]] && continue
  key_offenders+="${f}"$'\n'
done < <(grep -rl --include='*.dart' -F "${LOCALE_KEY}" "${LIB_DIR}" || true)
if [[ -n "${key_offenders}" ]]; then
  printf 'locale storage key referenced outside locale_provider.dart:\n%s' "${key_offenders}" >&2
  fail "the locale storage key '${LOCALE_KEY}' must only appear in locale_provider.dart"
fi

log "OK: locale is a local-only preference — no out-of-band state or key access."
