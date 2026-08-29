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
# Usage:
#   check_ios_background_publish.sh              # check the tree
#   check_ios_background_publish.sh --self-test  # hermetic fixtures, no repo
#                                                # read
#
# Pure source checks (comment-aware grep + xmllint), mirroring the
# conventions of check_m7_native_wake_guards.sh. Runtime behavior is covered
# by `flutter test` (geolocator_location_service_test.dart,
# location_provider_test.dart, map_shell_test.dart) and, across a REAL OS
# background transition, by the e2e-ios-background-publish lane — the
# Simulator does suspend a backgrounded app that has no live location session
# (CI run 32646436116), which is why check 11 exists. Jetsam, the SLC
# relaunch and BGTaskScheduler remain physical-iPhone owner checks
# (docs/M7_BACKGROUND_SHARING.md §6).
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

SERVICE="${REPO_ROOT}/haven/lib/src/services/geolocator_location_service.dart"
PROVIDER="${REPO_ROOT}/haven/lib/src/providers/location_provider.dart"
MAP_SHELL="${REPO_ROOT}/haven/lib/src/pages/map_shell.dart"
PLIST="${REPO_ROOT}/haven/ios/Runner/Info.plist"
LIB_DIR="${REPO_ROOT}/haven/lib"
SESSION_HANDLER="${REPO_ROOT}/haven/ios/Runner/HavenBackgroundSessionHandler.swift"
APP_DELEGATE="${REPO_ROOT}/haven/ios/Runner/AppDelegate.swift"
BG_PROVIDER="${REPO_ROOT}/haven/lib/src/providers/background_location_provider.dart"
BG_PUBLISH_DRIVE="${REPO_ROOT}/haven/integration_test/ios_bg_publish_test.dart"
SLC_HANDLER="${REPO_ROOT}/haven/ios/Runner/HavenSLCHandler.swift"

FAILED=0
fail() {
  echo "FAIL: $*" >&2
  FAILED=1
}

# Failure sink for the two checks that are factored into functions so
# --self-test can drive them against fixture files. They report through this
# instead of `fail` so they can return an exit code the fixtures assert on.
_lf=0
lfail() {
  echo "FAIL: $*" >&2
  _lf=1
}

for f in "$SERVICE" "$PROVIDER" "$MAP_SHELL" "$PLIST" "$SESSION_HANDLER" "$APP_DELEGATE" "$BG_PROVIDER" "$BG_PUBLISH_DRIVE"; do
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

check_stream_settings() { # <geolocator_location_service.dart>
  local svc="$1"
  _lf=0

  local settings_body
  settings_body="$(fn_slice '_streamSettings' "$svc")"
  if [[ -z "$settings_body" ]]; then
    lfail "_streamSettings not found in $(basename "$svc")"
    return "$_lf"
  fi

  grep -qE 'distanceFilter: *backgroundSharingEnabled \? *_kIosNoDistanceFilter *: *1\b' <<<"$settings_body" ||
    lfail "_streamSettings: the iOS distanceFilter is not exactly 'backgroundSharingEnabled ? _kIosNoDistanceFilter : 1' — a metre-scale filter on the background-capable arm re-breaks Apple's continuous-background-updates requirement, and widening the opt-out arm spends battery on a stream that never runs backgrounded"
  grep -qE 'const int _kIosNoDistanceFilter = -1;' <<<"$(code_view "$svc")" ||
    lfail "_kIosNoDistanceFilter is no longer -1 — only kCLDistanceFilterNone (-1) reaches CoreLocation as 'no filter' through geolocator's pointer-comparing distance mapper"
  grep -qE 'allowBackgroundLocationUpdates: *backgroundSharingEnabled' <<<"$settings_body" ||
    lfail "_streamSettings: allowBackgroundLocationUpdates is not keyed off backgroundSharingEnabled"
  grep -qE 'showBackgroundLocationIndicator: *backgroundSharingEnabled' <<<"$settings_body" ||
    lfail "_streamSettings: showBackgroundLocationIndicator is not keyed off backgroundSharingEnabled"
  grep -qE 'pauseLocationUpdatesAutomatically: *false' <<<"$settings_body" ||
    lfail "_streamSettings: pauseLocationUpdatesAutomatically must be explicitly false (auto-pause is a liveness hazard)"

  local bad_assign
  bad_assign="$(grep -nE 'allowBackgroundLocationUpdates *:' <<<"$(code_view "$svc")" | grep -vE 'allowBackgroundLocationUpdates *: *backgroundSharingEnabled' || true)"
  if [[ -n "$bad_assign" ]]; then
    lfail "hardcoded allowBackgroundLocationUpdates assignment in $(basename "$svc") (must only ever be keyed off backgroundSharingEnabled): ${bad_assign}"
  fi
  return "$_lf"
}

check_relaunch_region() { # <HavenSLCHandler.swift>
  local slc="$1"
  _lf=0

  local slc_start slc_stop region_arm exit_body
  slc_start="$(fn_slice 'func startMonitoring()' "$slc")"
  grep -qF 'refreshRelaunchRegion(' <<<"$slc_start" ||
    lfail "HavenSLCHandler.startMonitoring() no longer arms the relaunch region — SLC alone leaves a terminated app unrecoverable where cell-tower changes are sparse"
  slc_stop="$(fn_slice 'func stopMonitoring()' "$slc")"
  grep -qF 'stopRelaunchRegion()' <<<"$slc_stop" ||
    lfail "HavenSLCHandler.stopMonitoring() no longer releases the relaunch region — a region survives termination, so one left armed after opt-out keeps waking the app (privacy Rule 10)"

  region_arm="$(fn_slice 'private func refreshRelaunchRegion' "$slc")"
  if [[ -z "$region_arm" ]]; then
    lfail "HavenSLCHandler.refreshRelaunchRegion not found"
  else
    grep -qF 'isEnabled()' <<<"$region_arm" ||
      lfail "refreshRelaunchRegion no longer re-reads the enable predicate — the region must arm on exactly the consent SLC arms on"
    grep -qF '.authorizedAlways' <<<"$region_arm" ||
      lfail "refreshRelaunchRegion no longer requires Always authorization — the same requirement SLC carries"
    grep -qF 'notifyOnExit = true' <<<"$region_arm" ||
      lfail "refreshRelaunchRegion no longer monitors the EXIT transition — entry alone fires on arm and proves nothing about leaving"
  fi

  exit_body="$(fn_slice 'didExitRegion region: CLRegion' "$slc")"
  if [[ -z "$exit_body" ]]; then
    lfail "HavenSLCHandler has no didExitRegion delegate — the relaunch region would wake the app to do nothing"
  else
    grep -qF 'isEnabled()' <<<"$exit_body" ||
      lfail "didExitRegion no longer re-checks the durable consent on the wake itself"
    grep -qF 'triggerDartCatchup()' <<<"$exit_body" ||
      lfail "didExitRegion no longer routes through triggerDartCatchup() — the region wake must reuse the receive-only runCatchup channel, never a new path"
  fi

  local region_leaks
  region_leaks="$(grep -nE 'debugLog\(.*(coordinate|latitude|longitude|\\\(location|\\\(region)' <<<"$(code_view "$slc")" || true)"
  if [[ -n "$region_leaks" ]]; then
    lfail "HavenSLCHandler logs location or region detail (presence-only logging required, Security Rule 6): ${region_leaks}"
  fi
  return "$_lf"
}


if [[ "${1:-}" != "--self-test" ]]; then
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
# 4. _streamSettings: both background flags AND the iOS distance filter keyed
#    off the backgroundSharingEnabled parameter (never hardcoded), and the
#    auto-pause liveness hazard pinned off. Anywhere else in the service, an
#    allowBackgroundLocationUpdates assignment is forbidden.
#
#    The distance filter is part of Apple's stated requirement for
#    uninterrupted background updates (allowsBackgroundLocationUpdates on,
#    accuracy <= 100 m, NO distance filter); a metre-scale filter is the shape
#    the OS is documented to suspend while stationary. -1 is
#    kCLDistanceFilterNone itself — 0 is NOT equivalent, because geolocator's
#    LocationDistanceMapper compares the boxed NSNumber pointer rather than its
#    value and forwards a non-nil 0 verbatim as a 0 m filter.
#
#    BOTH arms are pinned. The opt-out arm keeps the 1 m filter deliberately:
#    dropping the filter costs delivery frequency (and battery) on a stream
#    that never runs backgrounded, so a change there is a battery regression
#    for users who declined background sharing.
# ---------------------------------------------------------------------------
check_stream_settings "$SERVICE" || FAILED=1

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
for f in "$SERVICE" "$MAP_SHELL" "$BG_PROVIDER" "${REPO_ROOT}/haven/lib/src/services/ios_background_session_service.dart"; do
  v="$(code_view "$f")"
  leaks="$(grep -nE 'debugPrint\(.*(latitude|longitude|\$position|\$\{position)' <<<"$v" || true)"
  if [[ -n "$leaks" ]]; then
    fail "$(basename "$f") debugPrint interpolates location data (presence-only logging required): ${leaks}"
  fi
done

# ---------------------------------------------------------------------------
# 8. Native CoreLocation session handler: arm() must be gated on the persisted
#    background-sharing consent (fail-closed — an arm with the toggle off must
#    DISARM), must create CLBackgroundActivitySession under an iOS 17
#    availability guard, and must gate CLServiceSession on already-granted
#    Always authorization (creating it earlier can drive an OS prompt).
#    disarm() must invalidate AND nil both sessions — an invalidated session
#    can never become active again, so silent reuse is a latent no-op.
# ---------------------------------------------------------------------------
arm_body="$(fn_slice 'func arm()' "$SESSION_HANDLER")"
if [[ -z "$arm_body" ]]; then
  fail "HavenBackgroundSessionHandler.arm() not found"
else
  grep -qF 'UserDefaults.standard.bool(forKey: Self.kBgSharingKey)' <<<"$arm_body" ||
    fail "arm() no longer re-reads the persisted background-sharing consent (fail-closed gate)"
  grep -qF 'UserDefaults.standard.bool(forKey: Self.kBgDisclosureKey)' <<<"$arm_body" ||
    fail "arm() no longer requires the accepted background disclosure — the pre-2026-06-07 stale-true cohort would get a keep-alive with no disclosure"
  grep -qF 'disarm()' <<<"$arm_body" ||
    fail "arm() no longer disarms when the consent predicate is off — a stale session could outlive an opt-out (privacy Rule 10)"
  grep -qF '.authorizedWhenInUse' <<<"$arm_body" ||
    fail "arm() no longer gates session creation on granted authorization — creating CLBackgroundActivitySession while .notDetermined can drive a launch-time prompt the user did not initiate"
  grep -qF '#available(iOS 17.0, *)' <<<"$arm_body" ||
    fail "arm() lost the iOS 17 availability guard for CLBackgroundActivitySession"
  grep -qF 'CLBackgroundActivitySession()' <<<"$arm_body" ||
    fail "arm() no longer creates CLBackgroundActivitySession — When-In-Use background continuation loses its iOS 17+ session contract"
  grep -qF '.authorizedAlways' <<<"$arm_body" ||
    fail "arm() no longer gates CLServiceSession on already-granted Always authorization (an ungated .always session can drive an OS prompt)"
fi
sh_view="$(code_view "$SESSION_HANDLER")"
if grep -qE 'NSLog\(|[^a-zA-Z]print\(' <<<"$sh_view"; then
  fail "HavenBackgroundSessionHandler.swift logs — the handler has nothing safe to say (presence-only policy, and no DEBUG-gated logger is wired here)"
fi
disarm_body="$(fn_slice 'func disarm()' "$SESSION_HANDLER")"
if [[ -z "$disarm_body" ]]; then
  fail "HavenBackgroundSessionHandler.disarm() not found"
else
  grep -qF 'invalidate()' <<<"$disarm_body" ||
    fail "disarm() no longer invalidates the held sessions"
  grep -qF 'backgroundActivity = nil' <<<"$disarm_body" ||
    fail "disarm() no longer nils backgroundActivity — an invalidated session can never reactivate, so reuse is a silent no-op"
  grep -qF 'alwaysSession = nil' <<<"$disarm_body" ||
    fail "disarm() no longer nils alwaysSession — an invalidated session can never reactivate, so reuse is a silent no-op"
fi

# ---------------------------------------------------------------------------
# 9. AppDelegate: the session handler must be registered on the messenger and
#    armed SYNCHRONOUSLY in didFinishLaunching (a session held at previous
#    termination can only be retaken for a few seconds after a background
#    relaunch) and re-armed on every foreground return (covers the
#    Always-downgrade drop and a toggle-enable whose Dart arm call raced
#    engine teardown).
# ---------------------------------------------------------------------------
code_has 'backgroundSessionHandler.register(with: messenger)' "$APP_DELEGATE" ||
  fail "AppDelegate no longer registers the background-session channel"
launch_body="$(fn_slice 'didFinishLaunchingWithOptions' "$APP_DELEGATE")"
grep -qF 'backgroundSessionHandler.arm()' <<<"$launch_body" ||
  fail "AppDelegate didFinishLaunching no longer arms the background sessions (the relaunch-retake window is only a few seconds)"
foreground_body="$(fn_slice 'applicationWillEnterForeground' "$APP_DELEGATE")"
grep -qF 'backgroundSessionHandler.arm()' <<<"$foreground_body" ||
  fail "AppDelegate applicationWillEnterForeground no longer re-arms the background sessions"

# ---------------------------------------------------------------------------
# 10. BackgroundSharingNotifier: the Dart side must AWAIT arm() (the awaited
#     call is what sequences the session before the state flip that rebuilds
#     the position stream) and must disarm on disable so withdrawal of
#     consent deterministically releases the OS keep-alive.
# ---------------------------------------------------------------------------
code_has 'await _iosBackgroundSession.arm()' "$BG_PROVIDER" ||
  fail "BackgroundSharingNotifier no longer awaits the background-session arm before flipping state"
code_has '_iosBackgroundSession.disarm()' "$BG_PROVIDER" ||
  fail "BackgroundSharingNotifier no longer disarms the background sessions on disable (privacy Rule 10)"
load_body="$(fn_slice 'Future<void> _load()' "$BG_PROVIDER")"
grep -qF '_iosBackgroundSession.disarm()' <<<"$load_body" ||
  fail "_load()'s fail-closed disclosure reconcile no longer disarms — the native launch-time arm read the stale true BEFORE Dart ran, so the reconcile must actively release the keep-alive"
CATCHUP_SVC="${REPO_ROOT}/haven/lib/src/services/ios_background_catchup.dart"
code_has 'MethodChannelIosBackgroundSessionService().disarm()' "$CATCHUP_SVC" ||
  fail "cancelNativeSchedulers no longer disarms the background sessions — identity deletion (which keeps the toggle pref) would leave the OS keep-alive held and re-armed on every launch"

# ---------------------------------------------------------------------------
# 11. The e2e-ios-background-publish drive target must never override
#     locationServiceProvider. Its P2 measures publishing from INSIDE the app
#     it backgrounds, and the app's only claim to keep EXECUTING there is the
#     live CLLocationManager session the production service creates (checks
#     1/4 above). A fake removes that claim: iOS suspends the process ~30 s
#     into the background, the frozen in-process oracle counts zero, and the
#     lane reds blaming the publish pipeline — CI run 32646436116. Nothing
#     behavioural can see the difference, which is why it is pinned here.
# ---------------------------------------------------------------------------
for sym in 'locationServiceProvider.override' 'FakeLocationService'; do
  if code_has "$sym" "$BG_PUBLISH_DRIVE"; then
    fail "ios_bg_publish_test.dart injects a fake location service ('$sym') — a faked service starts no CLLocationManager, so iOS suspends the backgrounded app and the lane can only measure a frozen process (CI run 32646436116). This target must run the production GeolocatorLocationService."
  fi
done

# ---------------------------------------------------------------------------
# 12. The bg-publish drive must PUMP after enabling background sharing and
#     require a fresh fix from the rebuilt locationStreamProvider, BEFORE it
#     signals the host to background the app.
#
#     Enabling the toggle only tears the foreground CLLocationManager session
#     down synchronously (Riverpod runs the provider's onDispose inside
#     `invalidateSelf`); the rebuild that re-creates it with
#     `allowBackgroundLocationUpdates: true` is deferred to `markNeedsBuild`,
#     and IntegrationTestWidgetsFlutterBinding's inherited `fadePointers`
#     frame policy draws no frame until the test pumps. In CI run
#     32661622879 that rebuild therefore landed 0.43 s AFTER SpringBoard set
#     `visiblity is no`; locationd answered `#Warning Denying process
#     assertion`, dropped its "Location subscription" assertion 2 s later,
#     and runningboardd suspended the app — while every static check here
#     still passed. A background-capable session may only be established
#     while the app is in use, so this ordering is the invariant, and only a
#     pump-then-assert before the READY marker establishes it.
# ---------------------------------------------------------------------------
drive_view="$(code_view "$BG_PUBLISH_DRIVE")"
enable_line="$(grep -n 'setEnabled(enabled: true)' <<<"$drive_view" | head -n1 | cut -d: -f1)"
ready_line="$(grep -n 'debugPrint(kReadyForBackgroundMarker)' <<<"$drive_view" | head -n1 | cut -d: -f1)"
if [[ -z "$enable_line" || -z "$ready_line" ]]; then
  fail "ios_bg_publish_test.dart lost its setEnabled(enabled: true) call or its kReadyForBackgroundMarker print — P1 and the host handshake are the lane's spine"
elif (( enable_line >= ready_line )); then
  fail "ios_bg_publish_test.dart signals READY before enabling background sharing (enable line ${enable_line}, READY line ${ready_line}) — the app would be backgrounded with the toggle still off"
else
  # Only the window between the enable and the READY signal counts: a pump
  # before the enable predates the rebuild, and one after READY may run
  # against a paused app, where frame production is off and the pump
  # deadlocks. Both must therefore live strictly inside this slice.
  arming_slice="$(sed -n "$((enable_line + 1)),$((ready_line - 1))p" <<<"$drive_view")"
  grep -qF 'await tester.pump()' <<<"$arming_slice" ||
    fail "ios_bg_publish_test.dart no longer pumps between enabling background sharing and signalling READY — the locationStreamProvider rebuild that creates the background-capable CLLocationManager session is deferred to markNeedsBuild, and this binding's fadePointers frame policy runs no build without a pump (CI run 32661622879: the session started 0.43 s after the app lost visibility, locationd denied the process assertion, runningboardd suspended the app)"
  grep -qE 'pumpUntilCondition\(' <<<"$arming_slice" ||
    fail "ios_bg_publish_test.dart no longer WAITS between enabling background sharing and signalling READY — a bare pump schedules the rebuild but proves nothing about the session it creates"
  grep -qF 'locationStreamProvider' <<<"$arming_slice" ||
    fail "ios_bg_publish_test.dart no longer asserts on locationStreamProvider between enabling background sharing and signalling READY — a fresh fix from the REBUILT stream is the only in-process proof that the background-capable session is live, and iOS only lets such a session start while the app is in use"
fi

# ---------------------------------------------------------------------------
# 13. The relaunch region must live and die with SLC.
#
#     SLC is driven by cell-tower transitions, so a terminated app in a
#     tower-sparse area can travel a long way before the OS calls anything
#     "significant"; one ~500 m exit region around the last fix is the second
#     relaunch source. Because it survives termination exactly like SLC does,
#     an arm that outlives an opt-out is a privacy defect (Rule 10) and an arm
#     that never happens is a silent loss of coverage — neither is observable
#     from CI, which cannot relaunch a terminated app (owner checklist
#     docs/M7_BACKGROUND_SHARING.md §6 item 2b). So the coupling is pinned
#     statically: same enable predicate, same Always requirement, same
#     teardown, same receive-only Dart channel, no new wake path.
# ---------------------------------------------------------------------------
if [[ ! -f "$SLC_HANDLER" ]]; then
  fail "expected file not found: $SLC_HANDLER"
else
  check_relaunch_region "$SLC_HANDLER" || FAILED=1
fi

fi

# ---------------------------------------------------------------------------
# --self-test: hermetic fixtures for the two checks that are function-shaped.
#
# Both pin invariants nothing behavioural can see. `_streamSettings` is a
# settings object handed to a plugin — its distance filter and background flags
# only show up as "iOS suspended the app", hours later and off-device — and the
# relaunch region only ever fires after a REAL termination, which no CI can
# stage (docs/M7_BACKGROUND_SHARING.md §6 item 2b). A guard that could rot
# unnoticed here would take the invariant with it, so every mutation below is
# an edit that leaves the file compiling and reading correctly, plus the
# anti-vacuity direction (a missing anchor is a failure, never a pass).
#
# The count is pinned by EQUALITY, not a floor: a floor lets a deleted fixture
# hide under the slack.
# ---------------------------------------------------------------------------
self_test() {
  local -r SELF_TEST_FIXTURES=19
  local tmp fails=0 checked=0
  tmp="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf '${tmp}'" RETURN

  _record() { # <label> <want-rc> <got-rc>
    checked=$(( checked + 1 ))
    if [[ "$3" -eq "$2" ]]; then
      printf '  \033[1;32mPASS\033[0m %s (rc=%d)\n' "$1" "$3"
    else
      printf '  \033[1;31mFAIL\033[0m %s (want rc=%d, got rc=%d)\n' "$1" "$2" "$3" >&2
      fails=1
    fi
  }

  # --- check_stream_settings ------------------------------------------------
  local dart_head='const int _kIosNoDistanceFilter = -1;

class GeolocatorLocationService {
  geo.LocationSettings _streamSettings({
    required bool backgroundSharingEnabled,
  }) {
    if (_isIOS) {
      return geo.AppleSettings('
  local dart_tail='        activityType: geo.ActivityType.other,
      );
    }
    return geo.AndroidSettings(
      distanceFilter: 1,
      forceLocationManager: true,
    );
  }
}'
  local good_args='        distanceFilter: backgroundSharingEnabled ? _kIosNoDistanceFilter : 1,
        allowBackgroundLocationUpdates: backgroundSharingEnabled,
        showBackgroundLocationIndicator: backgroundSharingEnabled,
        pauseLocationUpdatesAutomatically: false,'

  _dart() { # <label> <want-rc> <whole-file>
    local got=0
    printf '%s\n' "$3" >"${tmp}/service.dart"
    ( check_stream_settings "${tmp}/service.dart" ) >/dev/null 2>&1 || got=$?
    _record "$1" "$2" "${got}"
  }
  _dart_args() { # <label> <want-rc> <apple-settings-args>
    _dart "$1" "$2" "${dart_head}
$3
${dart_tail}"
  }

  _dart_args 'stream: today'"'"'s tree passes' 0 "${good_args}"
  _dart_args 'stream: a hardcoded 1 m filter on the background arm' 1 \
    '        distanceFilter: 1,
        allowBackgroundLocationUpdates: backgroundSharingEnabled,
        showBackgroundLocationIndicator: backgroundSharingEnabled,
        pauseLocationUpdatesAutomatically: false,'
  # The escape the review found: the ternary is still keyed off the toggle, so
  # a grep that stopped at `? _kIosNoDistanceFilter` stayed green while every
  # opt-out user's stream woke on 50 m instead of 1 m.
  _dart_args 'stream: the OPT-OUT arm widened to 50 m' 1 \
    '        distanceFilter: backgroundSharingEnabled ? _kIosNoDistanceFilter : 50,
        allowBackgroundLocationUpdates: backgroundSharingEnabled,
        showBackgroundLocationIndicator: backgroundSharingEnabled,
        pauseLocationUpdatesAutomatically: false,'
  _dart_args 'stream: the two arms swapped' 1 \
    '        distanceFilter: backgroundSharingEnabled ? 1 : _kIosNoDistanceFilter,
        allowBackgroundLocationUpdates: backgroundSharingEnabled,
        showBackgroundLocationIndicator: backgroundSharingEnabled,
        pauseLocationUpdatesAutomatically: false,'
  _dart_args 'stream: allowBackgroundLocationUpdates hardcoded true' 1 \
    '        distanceFilter: backgroundSharingEnabled ? _kIosNoDistanceFilter : 1,
        allowBackgroundLocationUpdates: true,
        showBackgroundLocationIndicator: backgroundSharingEnabled,
        pauseLocationUpdatesAutomatically: false,'
  _dart_args 'stream: showBackgroundLocationIndicator hardcoded false' 1 \
    '        distanceFilter: backgroundSharingEnabled ? _kIosNoDistanceFilter : 1,
        allowBackgroundLocationUpdates: backgroundSharingEnabled,
        showBackgroundLocationIndicator: false,
        pauseLocationUpdatesAutomatically: false,'
  _dart_args 'stream: auto-pause turned back on' 1 \
    '        distanceFilter: backgroundSharingEnabled ? _kIosNoDistanceFilter : 1,
        allowBackgroundLocationUpdates: backgroundSharingEnabled,
        showBackgroundLocationIndicator: backgroundSharingEnabled,
        pauseLocationUpdatesAutomatically: true,'
  # The sentinel silently moved to 0, which geolocator's pointer-comparing
  # mapper forwards verbatim as a 0 m filter rather than kCLDistanceFilterNone.
  _dart 'stream: _kIosNoDistanceFilter changed to 0' 1 \
    "$(printf '%s\n%s\n%s' "${dart_head/-1;/0;}" "${good_args}" "${dart_tail}")"
  # Anti-vacuity: prose that names every token is not code.
  _dart 'stream: _streamSettings commented out entirely' 1 \
    '// geo.LocationSettings _streamSettings({required bool backgroundSharingEnabled}) {
//   distanceFilter: backgroundSharingEnabled ? _kIosNoDistanceFilter : 1,
// }
const int _kIosNoDistanceFilter = -1;'

  # --- check_relaunch_region ------------------------------------------------
  local swift_start='  func startMonitoring() {
    guard isEnabled() else { return }
    locationManager.startMonitoringSignificantLocationChanges()
    refreshRelaunchRegion(around: locationManager.location)
  }'
  local swift_stop='  func stopMonitoring() {
    locationManager.stopMonitoringSignificantLocationChanges()
    stopRelaunchRegion()
    endBackgroundTask()
  }'
  local swift_arm='  private func refreshRelaunchRegion(around location: CLLocation?) {
    guard isEnabled(),
      locationManager.authorizationStatus == .authorizedAlways,
      let fix = location
    else { return }
    let region = CLCircularRegion(center: fix.coordinate, radius: 500, identifier: "id")
    region.notifyOnEntry = false
    region.notifyOnExit = true
    locationManager.startMonitoring(for: region)
  }'
  local swift_exit='  func locationManager(_ manager: CLLocationManager, didExitRegion region: CLRegion) {
    guard isEnabled(), region.identifier == Self.relaunchRegionIdentifier else { return }
    refreshRelaunchRegion(around: manager.location)
    beginCatchupWindow()
    triggerDartCatchup()
  }'
  local swift_log='  private func debugLog(_ message: String) {
    NSLog("[HavenSLC] %@", message)
  }'

  _swift() { # <label> <want-rc> <start> <stop> <arm> <exit> <log>
    local got=0
    printf 'final class HavenSLCHandler {\n%s\n%s\n%s\n%s\n%s\n}\n' \
      "$3" "$4" "$5" "$6" "$7" >"${tmp}/HavenSLCHandler.swift"
    ( check_relaunch_region "${tmp}/HavenSLCHandler.swift" ) >/dev/null 2>&1 || got=$?
    _record "$1" "$2" "${got}"
  }

  _swift 'region: today'"'"'s tree passes' 0 \
    "${swift_start}" "${swift_stop}" "${swift_arm}" "${swift_exit}" "${swift_log}"
  _swift 'region: startMonitoring stops arming it' 1 \
    '  func startMonitoring() {
    guard isEnabled() else { return }
    locationManager.startMonitoringSignificantLocationChanges()
  }' "${swift_stop}" "${swift_arm}" "${swift_exit}" "${swift_log}"
  _swift 'region: stopMonitoring stops releasing it (survives opt-out)' 1 \
    "${swift_start}" '  func stopMonitoring() {
    locationManager.stopMonitoringSignificantLocationChanges()
    endBackgroundTask()
  }' "${swift_arm}" "${swift_exit}" "${swift_log}"
  _swift 'region: arming no longer re-reads the consent predicate' 1 \
    "${swift_start}" "${swift_stop}" '  private func refreshRelaunchRegion(around location: CLLocation?) {
    guard locationManager.authorizationStatus == .authorizedAlways,
      let fix = location
    else { return }
    let region = CLCircularRegion(center: fix.coordinate, radius: 500, identifier: "id")
    region.notifyOnEntry = false
    region.notifyOnExit = true
    locationManager.startMonitoring(for: region)
  }' "${swift_exit}" "${swift_log}"
  _swift 'region: arming no longer requires Always' 1 \
    "${swift_start}" "${swift_stop}" '  private func refreshRelaunchRegion(around location: CLLocation?) {
    guard isEnabled(), let fix = location else { return }
    let region = CLCircularRegion(center: fix.coordinate, radius: 500, identifier: "id")
    region.notifyOnEntry = false
    region.notifyOnExit = true
    locationManager.startMonitoring(for: region)
  }' "${swift_exit}" "${swift_log}"
  _swift 'region: exit transition turned off' 1 \
    "${swift_start}" "${swift_stop}" '  private func refreshRelaunchRegion(around location: CLLocation?) {
    guard isEnabled(),
      locationManager.authorizationStatus == .authorizedAlways,
      let fix = location
    else { return }
    let region = CLCircularRegion(center: fix.coordinate, radius: 500, identifier: "id")
    region.notifyOnEntry = true
    region.notifyOnExit = false
    locationManager.startMonitoring(for: region)
  }' "${swift_exit}" "${swift_log}"
  _swift 'region: the arming function removed entirely (anti-vacuity)' 1 \
    "${swift_start}" "${swift_stop}" '' "${swift_exit}" "${swift_log}"
  _swift 'region: no didExitRegion delegate at all' 1 \
    "${swift_start}" "${swift_stop}" "${swift_arm}" '' "${swift_log}"
  _swift 'region: the exit wake bypasses the receive-only Dart channel' 1 \
    "${swift_start}" "${swift_stop}" "${swift_arm}" \
    '  func locationManager(_ manager: CLLocationManager, didExitRegion region: CLRegion) {
    guard isEnabled(), region.identifier == Self.relaunchRegionIdentifier else { return }
    beginCatchupWindow()
    publishLocationDirectly()
  }' "${swift_log}"
  _swift 'region: a coordinate reaches a log line' 1 \
    "${swift_start}" "${swift_stop}" "${swift_arm}" "${swift_exit}" \
    '  private func debugLog(_ message: String) {
    debugLog("exited at \(location.coordinate)")
  }'

  if (( checked != SELF_TEST_FIXTURES )); then
    echo "SELF-TEST FAIL: ran ${checked} fixture(s), expected ${SELF_TEST_FIXTURES}" >&2
    fails=1
  fi
  if (( fails != 0 )); then
    echo "check_ios_background_publish.sh --self-test: FAILED" >&2
    return 1
  fi
  echo "check_ios_background_publish.sh --self-test: ${checked} fixtures passed"
  return 0
}

if [[ "${1:-}" == "--self-test" ]]; then
  self_test
  exit $?
fi

if [[ "$FAILED" -ne 0 ]]; then
  echo "iOS background publish guard FAILED — see failures above." >&2
  exit 1
fi
echo "OK: iOS background publish invariants hold (plist mode, single stream, toggle-keyed AppleSettings, C4 watcher, presence-only logs, CoreLocation session arming, unfaked bg-publish drive, background-capable stream established before the drive backgrounds the app, relaunch region coupled to SLC)."
