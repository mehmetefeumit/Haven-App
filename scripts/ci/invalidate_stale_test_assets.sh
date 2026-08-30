#!/usr/bin/env bash
# Drops haven/build/unit_test_assets when a DIFFERENT Flutter SDK produced it.
#
# ## The failure this exists to prevent
#
# `flutter test` compiles the framework's shaders (ink_sparkle.frag,
# stretch_effect.frag) with the SDK's own impellerc and caches the result in
# build/unit_test_assets. Whether to rebuild that bundle is decided by
# flutter_tools' `_needsRebuild` (packages/flutter_tools/lib/src/commands/test.dart)
# from MTIMES alone — AssetManifest.bin against pubspec.yaml and the asset
# sources — and the SDK that compiled the bundle is not an input. An SDK
# checkout's own files are older than the bundle, so switching SDKs leaves the
# stale one in place and the new engine refuses to decode it:
#
#   Asset 'shaders/ink_sparkle.frag' manifest could not be decoded:
#   INVALID_ARGUMENT: Unsupported runtime stages format version. Expected 1, got 2.
#
# Every widget test that raises a Material ink splash then fails, which reads
# as dozens of broken tests rather than as one stale artifact. Upstream has the
# gap on file (flutter/flutter#128563); until it closes, `flutter clean` is the
# documented remedy and this is that remedy, applied automatically.
#
# Haven walks into it by design: coverage_toolchain.env pins the SDK the floors
# were measured on while every other job floats on stable, so re-pinning the
# manifest means switching SDKs and switching back — exactly the move that
# poisons the bundle.
#
# The SDK identity is stamped OUTSIDE the bundle directory, because writeBundle
# owns everything inside it.
#
# ## Usage
#
#   invalidate_stale_test_assets.sh <flutter-package-dir> <sdk-id>
#   invalidate_stale_test_assets.sh --self-test
#
# <sdk-id> is any string that changes when the SDK does (the gate passes
# `flutter --version`'s version field). Pass `unknown` when it cannot be
# determined: it never matches a stamp, so the bundle is rebuilt rather than
# trusted.

set -euo pipefail

SCRIPT_NAME="invalidate_stale_test_assets"

misconfig() { printf '%s: %s\n' "${SCRIPT_NAME}" "$*" >&2; exit 2; }

# Returns 0 and prints one line when it removed a bundle; silent otherwise.
invalidate() { # <package-dir> <sdk-id>
  local pkg="$1" sdk="$2"
  local bundle="${pkg}/build/unit_test_assets"
  local stamp="${pkg}/build/.unit_test_assets.sdk"

  local stamped=''
  [ -f "$stamp" ] && stamped="$(cat "$stamp")"

  # `unknown` is deliberately never equal to itself: an unidentifiable SDK must
  # not be able to certify a bundle it may not have built.
  if [ -n "$stamped" ] && [ "$stamped" = "$sdk" ] && [ "$sdk" != "unknown" ]; then
    return 0
  fi

  if [ -d "$bundle" ]; then
    rm -rf "$bundle"
    printf 'Removed build/unit_test_assets (built by %s, running %s) — flutter test will recompile it.\n' \
      "${stamped:-an unrecorded SDK}" "$sdk"
  fi
  mkdir -p "${pkg}/build"
  printf '%s\n' "$sdk" >"$stamp"
}

# ================================ self-test =================================
# Every assertion runs its predicate in an `||` context: a bare failing command
# would abort the run under `set -e` and report a pass count instead of a
# failure.
SELFTEST_TMP=''
self_test() {
  local failures=0 rc
  SELFTEST_TMP="$(mktemp -d)"
  trap 'rm -rf "${SELFTEST_TMP:-}"' EXIT
  local tmp="$SELFTEST_TMP"

  check() { # <label> <0 = pass>
    if [ "$2" = "0" ]; then printf '  ok   %s\n' "$1"; else printf '  FAIL %s\n' "$1"; failures=1; fi
  }
  make_bundle() { mkdir -p "$tmp/build/unit_test_assets"; : >"$tmp/build/unit_test_assets/AssetManifest.bin"; }
  assert() { # <label> <predicate...>
    rc=0; "${@:2}" || rc=1; check "$1" "$rc"
  }
  gone() { [ ! -d "$tmp/build/unit_test_assets" ]; }
  kept() { [ -d "$tmp/build/unit_test_assets" ]; }
  stamped_is() { [ "$(cat "$tmp/build/.unit_test_assets.sdk")" = "$1" ]; }

  # An unstamped bundle is of unknown provenance — the state every clone is in
  # the first time this runs — so it goes.
  make_bundle
  invalidate "$tmp" "3.41.0" >/dev/null
  assert "unstamped bundle is dropped" gone

  # Same SDK: the cache is the whole point, so it must survive.
  make_bundle
  invalidate "$tmp" "3.41.0" >/dev/null
  assert "same SDK keeps the bundle" kept

  # Different SDK: the case that produced the ink_sparkle failure.
  invalidate "$tmp" "3.44.8" >/dev/null
  assert "changed SDK drops the bundle" gone
  assert "stamp records the SDK that will rebuild it" stamped_is "3.44.8"

  # An unidentifiable SDK must never certify a bundle, not even against itself.
  make_bundle
  invalidate "$tmp" "unknown" >/dev/null
  assert "unknown SDK drops the bundle" gone
  make_bundle
  invalidate "$tmp" "unknown" >/dev/null
  assert "unknown SDK stays untrusted on a repeat run" gone

  # No bundle yet: stamp anyway, or the next run reads no stamp and throws away
  # a bundle this SDK just built.
  rm -f "$tmp/build/.unit_test_assets.sdk"
  invalidate "$tmp" "3.41.0" >/dev/null
  assert "absent bundle still records the SDK" stamped_is "3.41.0"
  make_bundle
  invalidate "$tmp" "3.41.0" >/dev/null
  assert "the recorded SDK is trusted next run" kept

  [ "$failures" = "0" ] || { printf '%s: self-test FAILED\n' "${SCRIPT_NAME}" >&2; return 1; }
  printf '%s: self-test passed\n' "${SCRIPT_NAME}"
}

if [ "${1:-}" = "--self-test" ]; then
  self_test
  exit
fi

[ "$#" -eq 2 ] || misconfig "usage: ${SCRIPT_NAME}.sh <flutter-package-dir> <sdk-id> | --self-test"
[ -d "$1" ] || misconfig "not a directory: $1"
[ -n "$2" ] || misconfig "empty sdk-id — pass 'unknown' rather than nothing."
invalidate "$1" "$2"
