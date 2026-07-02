#!/usr/bin/env bash
# CI guard: the production Android manifest MUST declare INTERNET (M7-8).
#
# The persistent live-sync engine and the M7 background catch-up sweep are
# Haven's Android RECEIVE path. Without android.permission.INTERNET a release
# build silently loses ALL relay connectivity — no location receive or send —
# a shipped-broken outcome that no test lane would catch (the app launches
# fine, it just can never reach a relay). The manifest carries INTERNET behind
# a load-bearing comment; this pure-grep gate fails the build if it is ever
# removed or gated behind a build variant.
#
# A stronger post-build check that runs `aapt dump permissions` against the
# ASSEMBLED release APK (catching a `tools:node="remove"` or a manifest-merger
# strip that this source grep cannot see) belongs in the android-build CI lane;
# see the note at the bottom.
#
# Pure grep — no Flutter/Rust toolchain — so it runs fast and independently.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
MANIFEST="${REPO_ROOT}/haven/android/app/src/main/AndroidManifest.xml"

if [[ ! -f "${MANIFEST}" ]]; then
  echo "FAIL: production AndroidManifest not found at ${MANIFEST}" >&2
  exit 1
fi

# Match a <uses-permission ... android:name="android.permission.INTERNET" ...>
# declaration. Also fail if it is present but neutralised by a
# tools:node="remove" on the same element.
if ! grep -qE '<uses-permission[^>]*android:name="android\.permission\.INTERNET"' "${MANIFEST}"; then
  echo "FAIL: ${MANIFEST} does not declare android.permission.INTERNET." >&2
  echo "      The Android relay receive path (live-sync engine + M7 catch-up)" >&2
  echo "      cannot function without it — a release would ship silently broken." >&2
  exit 1
fi

if grep -E '<uses-permission[^>]*android:name="android\.permission\.INTERNET"' "${MANIFEST}" \
     | grep -q 'tools:node="remove"'; then
  echo "FAIL: INTERNET permission is present but stripped via tools:node=\"remove\"." >&2
  exit 1
fi

echo "OK: android.permission.INTERNET is declared in the production manifest."

# --- CI-lane follow-up (documented, not enforced by this pure-grep gate) ------
# In the android-build lane, after assembling the release APK, verify the FINAL
# merged manifest still declares INTERNET (catches a manifest-merger strip a
# source grep cannot):
#     aapt dump permissions <apk> | grep -q 'android.permission.INTERNET' \
#       || { echo "release APK is missing INTERNET"; exit 1; }
