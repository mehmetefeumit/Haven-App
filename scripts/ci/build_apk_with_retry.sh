#!/usr/bin/env bash
#
# `flutter build apk` with a CLASSIFIED retry.
#
# ## Why this exists
#
# Gradle dependency resolution intermittently fails on hosted runners: Maven
# Central / plugins.gradle.org rate-limit shared CI IPs, and the build dies
# before compiling anything. Observed in CI run 30732662493, where the `arm`
# matrix leg failed with "Error resolving plugin
# [id: 'dev.flutter.flutter-plugin-loader']" / "Gradle threw an error while
# downloading artifacts from the network" while `arm64` and `x64` built the
# same commit successfully.
#
# ## Why it CLASSIFIES instead of retrying anything non-zero
#
# `tooling/e2e/ci/build-integration-apks.sh` retries every non-zero exit,
# reasoning that a genuine compile error fails all attempts anyway. That is
# true for compile errors and false for the failures that actually matter on a
# shared runner: disk exhaustion and OOM are intermittent AND real, so a blind
# retry can turn a capacity problem into a green build that hides it. This
# script therefore retries ONLY when the captured output matches a
# network/dependency-resolution signature, and fails immediately on anything
# else — including "No space left on device".
#
# A retry is cheap: Gradle keeps whatever it already fetched in ~/.gradle for
# the life of the job, so attempt 2 re-fetches only what attempt 1 missed.
#
# Usage:
#   scripts/ci/build_apk_with_retry.sh <flutter-target-platform> [extra flutter args...]
#
# Env:
#   HAVEN_BUILD_MAX_ATTEMPTS      default 3
#   HAVEN_BUILD_RETRY_DELAY_SECS  default 20

set -euo pipefail
readonly MAX_ATTEMPTS="${HAVEN_BUILD_MAX_ATTEMPTS:-3}"
readonly RETRY_DELAY_SECS="${HAVEN_BUILD_RETRY_DELAY_SECS:-20}"

# Signatures of a transient repository/network failure. Deliberately anchored on
# Gradle's own dependency-resolution wording rather than a bare "error", so a
# compile failure that happens to mention a URL is not misread as a flake.
readonly RETRIABLE_RE='Could not (GET|HEAD|resolve|download)|Error resolving plugin|downloading artifacts from the network|Read timed out|Connection (reset|timed out)|status code (403|408|429|5[0-9][0-9])|Could not resolve all (artifacts|dependencies|files)|repo\.maven\.apache\.org.*failed|plugins\.gradle\.org.*failed'

# Signatures that must NEVER be retried: intermittent but REAL. Retrying these
# converts a capacity problem into a passing build that hides it.
readonly FATAL_RE='No space left on device|Java heap space|OutOfMemoryError|Killed|Cannot allocate memory'

log() { printf '\033[1;34m[build_apk_with_retry]\033[0m %s\n' "$*"; }
err() { printf '\033[1;31m[build_apk_with_retry]\033[0m %s\n' "$*" >&2; }

# --self-test: proves the predicate still classifies correctly, WITHOUT running
# a build. A retry predicate that silently stops matching is the dangerous
# failure here — it would either stop retrying real flakes, or start retrying
# genuine breakage. Wired into repo-guards, mirroring the `--self-test` on
# run-single-avd-scenario.sh and scan-logs-for-secrets.sh.
if [[ "${1:-}" == "--self-test" ]]; then
  classify() {
    if grep -qE "${FATAL_RE}" <<<"$1"; then echo fatal
    elif grep -qE "${RETRIABLE_RE}" <<<"$1"; then echo retry
    else echo fail; fi
  }
  st_fail=0
  expect() { # $1 label, $2 expected, $3 sample
    local got; got="$(classify "$3")"
    if [[ "${got}" == "$2" ]]; then
      printf '  ok    %-42s -> %s\n' "$1" "${got}"
    else
      printf '  FAIL  %-42s -> %s (want %s)\n' "$1" "${got}" "$2" >&2
      st_fail=1
    fi
  }
  # The two verbatim messages from CI run 30732662493's failed `arm` leg.
  expect "CI 30732662493: plugin resolution" retry \
    "Error resolving plugin [id: 'dev.flutter.flutter-plugin-loader', version: '1.0.0']"
  expect "CI 30732662493: network download" retry \
    "[!] Gradle threw an error while downloading artifacts from the network."
  expect "Maven Central 403" retry \
    "Could not GET 'https://repo1.maven.org/kotlin-stdlib.pom'. Received status code 403"
  # Genuine breakage must NEVER be retried.
  expect "dart compile error" fail \
    "lib/src/main.dart:12:3: Error: Expected ';' after this."
  expect "kotlin compile error" fail \
    "e: file:///x/Main.kt:8:1 Unresolved reference: foo"
  # Intermittent but REAL — retrying would hide a capacity problem.
  expect "disk exhaustion" fatal "java.io.IOException: No space left on device"
  expect "heap exhaustion" fatal "java.lang.OutOfMemoryError: Java heap space"
  if (( st_fail )); then
    err "self-test FAILED — the retry predicate no longer classifies correctly."
    exit 1
  fi
  log "self-test passed (7 cases)."
  exit 0
fi

readonly TARGET_PLATFORM="${1:?usage: build_apk_with_retry.sh <target-platform> [args...]}"
shift

attempt=1
while (( attempt <= MAX_ATTEMPTS )); do
  rc=0
  out="$(mktemp)"
  # `tee` so the build streams live AND is captured for classification; the
  # pipeline's exit status must come from flutter, not tee (pipefail + rc grab).
  flutter build apk --debug --target-platform "${TARGET_PLATFORM}" "$@" 2>&1 \
    | tee "${out}" || rc=$?

  if (( rc == 0 )); then
    rm -f "${out}"
    exit 0
  fi

  if grep -qE "${FATAL_RE}" "${out}"; then
    err "build failed with a NON-retriable condition (disk/memory) — not retrying."
    err "This is intermittent but real; retrying would hide a capacity problem."
    rm -f "${out}"
    exit "${rc}"
  fi

  if ! grep -qE "${RETRIABLE_RE}" "${out}"; then
    err "build failed (rc=${rc}) with no transient-network signature — not retrying."
    err "Treated as a genuine build failure; see the output above."
    rm -f "${out}"
    exit "${rc}"
  fi

  rm -f "${out}"
  if (( attempt == MAX_ATTEMPTS )); then
    err "build failed after ${MAX_ATTEMPTS} attempts (rc=${rc}), last failure was a"
    err "transient repository/network error. If this recurs, the runner's egress to"
    err "Maven Central / plugins.gradle.org is the thing to investigate."
    exit "${rc}"
  fi

  log "attempt ${attempt}/${MAX_ATTEMPTS} hit a transient Gradle repo/network"
  log "failure — retrying in ${RETRY_DELAY_SECS}s (Gradle reuses what it cached)."
  sleep "${RETRY_DELAY_SECS}"
  attempt=$(( attempt + 1 ))
done
