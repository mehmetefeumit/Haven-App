#!/usr/bin/env bash
# CI gate: localization (l10n) consistency for the Haven Flutter app.
#
# This is the authoritative, zero-extra-dependency translation gate (the
# optional AI review in l10n-check.yml is advisory). It:
#
#   1. regenerates the gen-l10n sources and fails if any template message is
#      untranslated in a shipped locale (build/untranslated.json non-empty);
#   2. fails if the committed generated AppLocalizations sources have drifted
#      from a fresh regeneration (so the committed files always match the ARBs);
#   3. runs scripts/ci/arb_parity_check.dart for cross-locale key/placeholder/
#      ICU-plural/empty-value/untranslated-copy parity.
#
# Run from anywhere: paths are resolved from the script location.
# Requires the Flutter toolchain on PATH (like the other Flutter CI lanes).
#
# Exit codes:
#   0  consistent
#   1  an inconsistency was found
#   2  misconfiguration (missing files/toolchain)

set -euo pipefail
trap 'echo "[check_l10n_parity] ERROR on line ${LINENO}" >&2' ERR

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HAVEN_DIR="${REPO_ROOT}/haven"
L10N_DIR="${HAVEN_DIR}/lib/l10n"
TEMPLATE="${L10N_DIR}/app_en.arb"
UNTRANSLATED="${HAVEN_DIR}/build/untranslated.json"
PARITY_SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/arb_parity_check.dart"

log() {
  printf '\033[1;34m[check_l10n_parity]\033[0m %s\n' "$*"
}
fail() {
  printf '\033[1;31m[check_l10n_parity] FAIL:\033[0m %s\n' "$*" >&2
  exit 1
}

[[ -d "${HAVEN_DIR}" ]]   || { echo "ERROR: ${HAVEN_DIR} not found" >&2; exit 2; }
[[ -f "${TEMPLATE}" ]]    || { echo "ERROR: template ${TEMPLATE} not found" >&2; exit 2; }
[[ -f "${PARITY_SCRIPT}" ]] || { echo "ERROR: ${PARITY_SCRIPT} not found" >&2; exit 2; }
command -v flutter >/dev/null 2>&1 || { echo "ERROR: flutter not on PATH" >&2; exit 2; }

# ---------------------------------------------------------------------------
# Step 1: regenerate and check for untranslated messages.
#
# `flutter pub get` is required before gen-l10n on a fresh checkout (it also
# auto-generates because pubspec sets `generate: true`); the explicit gen-l10n
# call makes the intent obvious and writes build/untranslated.json.
# ---------------------------------------------------------------------------
log "Resolving dependencies and regenerating localizations ..."
( cd "${HAVEN_DIR}" && flutter pub get >/dev/null && flutter gen-l10n >/dev/null )

if [[ -f "${UNTRANSLATED}" ]]; then
  # gen-l10n writes "{}" when nothing is missing; anything else lists gaps.
  compact="$(tr -d '[:space:]' < "${UNTRANSLATED}")"
  if [[ -n "${compact}" && "${compact}" != "{}" ]]; then
    log "Untranslated messages:"
    cat "${UNTRANSLATED}" >&2
    fail "shipped locales are missing translations (see build/untranslated.json)"
  fi
fi

# ---------------------------------------------------------------------------
# Step 2: the staged/committed generated sources must match a fresh regen.
#
# Two failure modes, both checked against the git index so the gate passes
# whether the generated files are committed (CI) or merely staged (local
# pre-commit):
#   * untracked generated/ARB files were never added → "commit lib/l10n";
#   * tracked files differ from the index after regeneration → stale generation
#     (someone changed an ARB without regenerating, or forgot to stage).
# Run from REPO_ROOT so the pathspec is unambiguous.
# ---------------------------------------------------------------------------
log "Checking generated sources for drift ..."
untracked="$(git -C "${REPO_ROOT}" ls-files --others --exclude-standard -- 'haven/lib/l10n' || true)"
if [[ -n "${untracked}" ]]; then
  printf '%s\n' "${untracked}" >&2
  fail "untracked l10n sources — run 'flutter gen-l10n' and commit lib/l10n"
fi
unstaged="$(git -C "${REPO_ROOT}" diff --name-only -- 'haven/lib/l10n' || true)"
if [[ -n "${unstaged}" ]]; then
  printf '%s\n' "${unstaged}" >&2
  fail "generated l10n sources differ from the index — run 'flutter gen-l10n' and stage lib/l10n"
fi

# ---------------------------------------------------------------------------
# Step 3: cross-locale parity (keys, placeholders, plural categories, etc.).
# ---------------------------------------------------------------------------
log "Checking cross-locale ARB parity ..."
( cd "${HAVEN_DIR}" && dart "${PARITY_SCRIPT}" "${L10N_DIR}" )

log "OK: localizations are consistent."
