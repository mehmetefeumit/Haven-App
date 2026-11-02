#!/usr/bin/env bash
# Deletes the Flutter build tree and Gradle's caches once a lane's APKs are
# copied out, so the emulator's system image has room to install.
#
# haven/build holds every Gradle intermediate of every APK the lane built and
# cargokit's Rust target for Android (`--target-dir` is the plugin project's
# buildDir, haven/build/rust_lib_haven/build): a debug build of the core with
# full debuginfo. A lane that builds before provisioning the SDK keeps all of it
# on disk for nothing: on a 72 GB runner eight APKs left 44 MB for the system
# image (CI run 41167769413), and a single one left 3.3 GB, too little for the
# image to unpack (CI run 41322563075). Nothing after the build reads it, nor
# the Gradle caches, which these lanes restore and never save: the drives
# install the copied APKs with --use-application-binary.
#
# Usage: release-apk-build-outputs.sh <dir holding the lane's copied APKs>
# Refuses (exit 2) unless that directory holds at least one APK, so it can never
# run before the copies exist.
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "usage: $0 <dir holding the lane's copied APKs>" >&2
  exit 2
fi
readonly APK_DIR="$1"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
readonly REPO_ROOT
readonly BUILD_TREE="${REPO_ROOT}/haven/build"

if ! compgen -G "${APK_DIR}/*.apk" > /dev/null; then
  echo "ERROR: ${APK_DIR} holds no APK; refusing to delete the build tree they would be copied from." >&2
  exit 2
fi

echo "=== Disk before releasing the build tree ==="
df -h /
rm -rf "${BUILD_TREE}" "${HOME}/.gradle/caches" "${HOME}/.gradle/daemon"
echo "=== Disk after releasing the build tree ==="
df -h /
