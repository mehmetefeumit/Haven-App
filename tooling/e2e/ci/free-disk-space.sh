#!/usr/bin/env bash
#
# Reclaims disk on GitHub-hosted ubuntu runners before an E2E APK build.
#
# # Why this exists
#
# The debug E2E APK links the (large) haven-core Rust crypto stack
# (OpenMLS + SQLCipher + nostr) via cargokit. Even constrained to the
# x86_64 AVD ABI (`--target-platform android-x64`), the debug Rust target
# dir plus the NDK `stripDebugSymbols` intermediates push a default runner
# (~72 GB, the bulk pre-consumed by the image) toward full. A run died with
# `LLVM ERROR: ... No space left on device` mid-strip. We delete the big
# preinstalled toolchains the Haven build never touches so the build and the
# strip pass keep comfortable headroom.
#
# # Conventions
#
# Best-effort: every removal is guarded with `|| true` so a path that moved
# between runner-image versions cannot fail the step. `df` is printed before
# and after so a future disk regression is diagnosable from the job log
# alone (evidence-first). Run AFTER `actions/checkout` (this script lives in
# the repo) but BEFORE the Gradle/Rust build.
set -euo pipefail

echo "=== Disk before cleanup ==="
df -h /

# Large preinstalled SDKs / toolchains unused by the Flutter + Android + Rust
# build. Each is a top-level dir on the hosted image; sizes are approximate.
sudo rm -rf /usr/share/dotnet || true          # .NET SDKs   (~2 GB)
sudo rm -rf /opt/ghc || true                   # Haskell     (~3 GB)
sudo rm -rf /usr/local/.ghcup || true          # Haskell GHCup (~2 GB)
sudo rm -rf /usr/local/share/boost || true     # Boost C++   (~1 GB)
sudo rm -rf /usr/share/swift || true           # Swift       (~2 GB)
sudo rm -rf /usr/local/graalvm || true         # GraalVM     (~1 GB)
# NOTE: the Android NDK is deliberately NOT touched — cargokit cross-compiles
# the Rust lib through the NDK pinned by `android.ndkVersion`, so removing any
# NDK risks the build.
# CodeQL bundle (~5 GB). Only the CodeQL subdir — the Java/Flutter tool-cache
# siblings under /opt/hostedtoolcache are still needed by later setup steps.
sudo rm -rf /opt/hostedtoolcache/CodeQL || true

# Preinstalled Docker images (several GB). strfry is pulled later by
# start-strfry.sh, so dropping the image cache now is safe.
docker image prune --all --force || true

echo "=== Disk after cleanup ==="
df -h /
