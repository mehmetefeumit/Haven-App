#!/usr/bin/env bash
# prebuild-ios-app.sh — the cold iOS app build, once per job, before the
# simulator boots and outside the drive step's `nick-fields/retry` attempt.
#
# Usage: HAVEN_LIVE_SYNC=<true|false> prebuild-ios-app.sh <scenario path relative to haven/>
#
# The pod builds the Rust staticlib with thin LTO in debug too
# (haven/rust_builder/ios/rust_lib_haven.podspec: -force_load needs it). Since
# then a cold simulator build inside the attempt, with the simulator resident,
# has taken 900-1650 s; build-check.yml's cold debug build of the same crate
# graph, for the device and with no simulator, takes 333-468 s. In CI run
# 41492770461 a 1492 s build left e2e_profile_ios 52 s of its 30-minute attempt:
# the timeout killed a healthy app before its first test, the retry gate rightly
# refused an attempt that never reached classification, and the lane went red
# with nothing tested. Here a slow build fails under this step's own cap, by
# name, and leaves the attempt its incremental rebuild (107-158 s in that run)
# plus the test.
#
# The invocation is the one run-b4-ios-real-gps.sh, run-b7-ios-auth-tier.sh and
# run-ios-bg-publish.sh make inside their attempts — generic simulator
# destination, Debug, same build directory and so the same cargokit target dir —
# which is what lets their build and `flutter test -d <udid>` reuse it. No
# `--no-codesign`: it changes the build settings the later builds compare.
# HAVEN_LIVE_SYNC is required, as everywhere the app is compiled
# (check_live_sync_define_declared.sh), though nothing built here is trusted:
# what runs is what the attempt itself (re)builds with its own defines.

set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "usage: HAVEN_LIVE_SYNC=<true|false> $0 <scenario path relative to haven/>" >&2
  exit 2
fi
if [[ ! "${HAVEN_LIVE_SYNC:-}" =~ ^(true|false)$ ]]; then
  echo "ERROR: HAVEN_LIVE_SYNC must be exactly 'true' or 'false' (got '${HAVEN_LIVE_SYNC:-}')." >&2
  exit 2
fi

cd "$(dirname "$0")/../../../haven"
flutter build ios --simulator --debug --target "$1" \
  --dart-define=HAVEN_LIVE_SYNC="${HAVEN_LIVE_SYNC}"
