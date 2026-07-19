#!/usr/bin/env bash
# CI guard: iOS background location PUBLISH invariants (the unified-stream fix).
#
# Root cause being pinned: geolocator supports exactly ONE position stream —
# the plugin caches it Dart-side and silently returns the cached stream (old
# settings and all) to any later getPositionStream call, and the native side
# rejects a second concurrent listen. Haven therefore runs a SINGLE stream
# whose iOS AppleSettings are a pure function of the user's background-sharing
# toggle, established at subscription time (necessarily while foregrounded).
# A regression on any of these invariants re-breaks iOS background publishing
# SILENTLY (the app just suspends and peers stop receiving), or — for the
# toggle-OFF explicit-false pin — silently re-introduces the accidental
# keep-alive for users who never consented to background sharing (privacy
# Rule 10).
#
# Pure source checks (comment-aware grep + xmllint), mirroring the
# conventions of check_m7_native_wake_guards.sh. Runtime behavior is covered
# by `flutter test` (geolocator_location_service_test.dart,
# location_provider_test.dart, map_shell_test.dart); real-device background
# continuity is a physical-iPhone owner check (docs/M7_BACKGROUND_SHARING.md
# §6) because neither CI nor the Simulator can truly suspend an app.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

SERVICE="${REPO_ROOT}/haven/lib/src/services/geolocator_location_service.dart"
PROVIDER="${REPO_ROOT}/haven/lib/src/providers/location_provider.dart"
MAP_SHELL="${REPO_ROOT}/haven/lib/src/pages/map_shell.dart"
PLIST="${REPO_ROOT}/haven/ios/Runner/Info.plist"
LIB_DIR="${REPO_ROOT}/haven/lib"

FAILED=0
fail() {
  echo "FAIL: $*" >&2
  FAILED=1
}

for f in "$SERVICE" "$PROVIDER" "$MAP_SHELL" "$PLIST"; do
  [[ -f "$f" ]] || { echo "FAIL: expected file not found: $f" >&2; exit 1; }
done
command -v xmllint >/dev/null 2>&1 || { echo "FAIL: xmllint (libxml2-utils) is required by this guard" >&2; exit 1; }

# --- comment-aware matching helpers (same shape as check_m7_native_wake_guards.sh)
code_view() {
  awk '
    {
      line = $0; out = ""; i = 1; n = length(line)
      while (i <= n) {
        if (inblock) {
          e = index(substr(line, i), "*/")
          if (e == 0) { i = n + 1 } else { i += e + 1; inblock = 0 }
        } else {
          two = substr(line, i, 2)
          if (two == "/*") { inblock = 1; i += 2 }
          else if (two == "//") { i = n + 1 }
          else { out = out substr(line, i, 1); i += 1 }
        }
      }
      print out
    }' "$1"
}
code_has()   { local v; v="$(code_view "$2")"; grep -qF -- "$1" <<<"$v"; }
code_has_e() { local v; v="$(code_view "$2")"; grep -qE -- "$1" <<<"$v"; }
code_count() { local v; v="$(code_view "$2")"; grep -cF -- "$1" <<<"$v"; }
fn_slice() {
  local v; v="$(code_view "$2")"
  awk -v sig="$1" '
    index($0, sig) > 0 { inbody = 1 }
    inbody {
      print
      o = gsub(/[{]/, "&"); c = gsub(/[}]/, "&")
      depth += o - c
      if (seen && depth <= 0) exit
      if (o > 0) seen = 1
    }' <<<"$v"
}

# ---------------------------------------------------------------------------
# 1. Info.plist: UIBackgroundModes must contain `location`. Without it the
#    plugin's native side silently ANDs allowsBackgroundLocationUpdates to
#    false — no crash, the app just suspends on backgrounding.
# ---------------------------------------------------------------------------
bg_modes="$(xmllint --nonet --xpath "//key[text()='UIBackgroundModes']/following-sibling::array[1]/string/text()" "$PLIST" 2>/dev/null)"
if ! grep -qx 'location' <<<"$bg_modes"; then
  fail "Info.plist UIBackgroundModes lacks 'location' — iOS background publishing silently dies (found: ${bg_modes:-none})"
fi

# ---------------------------------------------------------------------------
# 2. Exactly ONE getPositionStream call site in the service (the single-stream
#    invariant). A second call site is a re-introduction of the cached-stream
#    settings-swallowing defect. The DefaultGeolocatorWrapper's
#    `geo.Geolocator.getPositionStream` delegate is the plugin boundary, not a
#    stream consumer, and is excluded; the call may be line-wrapped, so match
#    the leading-dot invocation form.
# ---------------------------------------------------------------------------
svc_code="$(code_view "$SERVICE")"
stream_calls="$(grep -E '\.getPositionStream\(' <<<"$svc_code" | grep -cvE 'Geolocator\.getPositionStream' || true)"
if [[ "$stream_calls" != "1" ]]; then
  fail "expected exactly 1 executable .getPositionStream( call site in geolocator_location_service.dart (excluding the wrapper delegate), found ${stream_calls} — the single-stream invariant is broken"
fi

# ---------------------------------------------------------------------------
# 3. The dead second-stream API must never reappear anywhere under haven/lib.
# ---------------------------------------------------------------------------
for sym in getBackgroundLocationStream _startBackgroundLocationStream _stopBackgroundLocationStream _backgroundLocationSub kBackgroundDistanceFilterMeters; do
  hits="$(grep -rln --include='*.dart' -- "$sym" "$LIB_DIR" || true)"
  if [[ -n "$hits" ]]; then
    fail "banned second-stream symbol '$sym' reappeared under haven/lib: ${hits}"
  fi
done

# ---------------------------------------------------------------------------
# 4. _streamSettings: both background flags keyed off the
#    backgroundSharingEnabled parameter (never hardcoded), and the auto-pause
#    liveness hazard pinned off. Anywhere else in the service, an
#    allowBackgroundLocationUpdates assignment is forbidden.
# ---------------------------------------------------------------------------
settings_body="$(fn_slice '_streamSettings' "$SERVICE")"
if [[ -z "$settings_body" ]]; then
  fail "_streamSettings not found in geolocator_location_service.dart"
else
  grep -qE 'allowBackgroundLocationUpdates: *backgroundSharingEnabled' <<<"$settings_body" ||
    fail "_streamSettings: allowBackgroundLocationUpdates is not keyed off backgroundSharingEnabled"
  grep -qE 'showBackgroundLocationIndicator: *backgroundSharingEnabled' <<<"$settings_body" ||
    fail "_streamSettings: showBackgroundLocationIndicator is not keyed off backgroundSharingEnabled"
  grep -qE 'pauseLocationUpdatesAutomatically: *false' <<<"$settings_body" ||
    fail "_streamSettings: pauseLocationUpdatesAutomatically must be explicitly false (auto-pause is a liveness hazard)"
fi
svc_view="$(code_view "$SERVICE")"
bad_assign="$(grep -nE 'allowBackgroundLocationUpdates *:' <<<"$svc_view" | grep -vE 'allowBackgroundLocationUpdates *: *backgroundSharingEnabled' || true)"
if [[ -n "$bad_assign" ]]; then
  fail "hardcoded allowBackgroundLocationUpdates assignment in geolocator_location_service.dart (must only ever be keyed off backgroundSharingEnabled): ${bad_assign}"
fi

# ---------------------------------------------------------------------------
# 5. locationStreamProvider must watch backgroundSharingProvider (the rebuild
#    is the ONLY way stream settings can ever change) and must clear the
#    cached position on the disabled branch.
# ---------------------------------------------------------------------------
code_has 'ref.watch(backgroundSharingProvider)' "$PROVIDER" ||
  fail "locationStreamProvider no longer watches backgroundSharingProvider — toggle flips would stop re-configuring the stream"
code_has 'clearCachedPosition()' "$PROVIDER" ||
  fail "locationStreamProvider no longer clears the cached stream position on the disabled rebuild"

# ---------------------------------------------------------------------------
# 6. map_shell: the C4 disable-while-paused watcher must be installed in
#    executable code via listenManual on backgroundSharingProvider, and the
#    keep-publishing decision must route through shouldKeepPublishingWhilePaused.
#    (The watcher moved OUT of the liveSyncEnabled-gated receive-timer setup —
#    a watcher that lives only there is unreachable in production builds.)
# ---------------------------------------------------------------------------
code_has 'shouldKeepPublishingWhilePaused(' "$MAP_SHELL" ||
  fail "map_shell no longer routes the pause decision through shouldKeepPublishingWhilePaused"
code_has_e '_bgSharingPausedSub *= *ref\.listenManual<bool>\(backgroundSharingProvider' "$MAP_SHELL" ||
  fail "map_shell no longer installs the C4 disable-while-paused watcher (listenManual on backgroundSharingProvider)"
receive_timer_body="$(fn_slice '_startIosBackgroundReceiveTimer' "$MAP_SHELL")"
if [[ -n "$receive_timer_body" ]] && grep -qF 'listenManual' <<<"$receive_timer_body"; then
  fail "_startIosBackgroundReceiveTimer installs its own listenManual watcher again — that install is unreachable when liveSyncEnabled=true and shadows the unified C4 watcher"
fi

# ---------------------------------------------------------------------------
# 7. Presence-only logging: no debugPrint in the location service or map_shell
#    may interpolate a coordinate or Position (Security Rule 6/8 extension to
#    location data).
# ---------------------------------------------------------------------------
for f in "$SERVICE" "$MAP_SHELL"; do
  v="$(code_view "$f")"
  leaks="$(grep -nE 'debugPrint\(.*(latitude|longitude|\$position|\$\{position)' <<<"$v" || true)"
  if [[ -n "$leaks" ]]; then
    fail "$(basename "$f") debugPrint interpolates location data (presence-only logging required): ${leaks}"
  fi
done

if [[ "$FAILED" -ne 0 ]]; then
  echo "iOS background publish guard FAILED — see failures above." >&2
  exit 1
fi
echo "OK: iOS background publish invariants hold (plist mode, single stream, toggle-keyed AppleSettings, C4 watcher, presence-only logs)."
