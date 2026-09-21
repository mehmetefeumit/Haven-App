#!/usr/bin/env bash
# CI guard: iOS background location PUBLISH invariants.
#
# ONE STREAM OWNER PER PLATFORM. On Android the owner is still geolocator, and
# the root cause pinned there is unchanged: the plugin supports exactly ONE
# position stream per instance — it caches the stream Dart-side and silently
# returns the cached one (old settings and all) to any later getPositionStream
# call, and the native side rejects a second concurrent listen. Only cancelling
# the subscription clears that cache, so stream settings can change ONLY by way
# of a new subscription. On iOS the owner is Haven's own
# `HavenLocationStreamHandler.swift`, reached through the single
# `IosLocationSource.positions(...)` boundary. Check 2 counts BOTH boundaries
# (one `.getPositionStream(`, one `.positions(`, one file subscribing to the
# native EventChannel); check 3 bans the dead symbols by name, including the
# retired `_kIosNoDistanceFilter` sentinel — geolocator's pointer-comparing
# distance mapper, and the `-1` vs `0` trap it created, are MOOT under the
# native owner and must not come back.
#
# "One stream" is a per-ISOLATE statement, and worth saying precisely now that
# the Android foreground service registers one of its own. Each Dart isolate
# has its own plugin instance and its own GeolocatorLocationService, so the UI
# isolate and the FGS can each own ONE registration — and they never hold one
# at the same time: the UI releases its subscription at pause before it hands
# ownership over, and takes it back only after the FGS has released its own.
# They are exclusive by LIFECYCLE, not by settings. The FGS asks this same API
# for its own AndroidStreamProfile (one long interval, no distance filter, no
# timeLimit) rather than for a stream API of its own.
#
# WHERE THE iOS SETTINGS WENT. They used to be `AppleSettings` fields inside
# `_streamSettings` and were pinned there. They are now CoreLocation properties
# on Haven's own manager, and every one of them is pinned where the behaviour
# now lives (check 4a, `check_native_stream_handler`):
#
#   `distanceFilter: backgroundSharingEnabled ? _kIosNoDistanceFilter : 1`
#       -> `manager.distanceFilter = kCLDistanceFilterNone` in `init`, with a
#          file-wide "exactly one assignment" count. The opt-out arm's 1 m
#          filter is retired BY DESIGN, not by omission: under the native owner
#          both profiles carry `kCLDistanceFilterNone` because Apple's 16.4
#          delivery rule requires it of the session, and the session is the same
#          object in both toggle states. The battery lever that the 1 m arm used
#          to be is now the ACCURACY TIER (Best <-> HundredMeters), whose two
#          permitted values are pinned by the same check. Android's own arms are
#          pinned by check_android_location_power.sh (6).
#   `_kIosNoDistanceFilter = -1`
#       -> the symbolic `kCLDistanceFilterNone`, plus a lib-wide ban on the dead
#          constant (check 3). Nothing maps a Dart int to a filter any more.
#   `allowBackgroundLocationUpdates: backgroundSharingEnabled`
#       -> the Dart routing expression `positions(allowsBackgroundLocationUpdates:
#          backgroundSharingEnabled)` in `_listenInner` (check 4, R8: no other
#          `allowsBackgroundLocationUpdates:` anywhere in the service) AND the
#          Swift `manager.allowsBackgroundLocationUpdates = allowsBg`, where
#          `allowsBg` is derived on ONE line from the listen arguments — never a
#          literal, never `?? true` (check 4a). It stays a pure function of the
#          user's toggle across the whole hop.
#   `showBackgroundLocationIndicator: backgroundSharingEnabled`
#       -> `manager.showsBackgroundLocationIndicator = !alwaysConfirmed`
#          (check 4a): the indicator is a TIER decision now, not a toggle
#          decision (OD1). Its other half — which tier holds a
#          CLBackgroundActivitySession — is check 8.
#   `pauseLocationUpdatesAutomatically: false`
#       -> `manager.pausesLocationUpdatesAutomatically = false` in `init`, with
#          the same file-wide single-assignment count.
#
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
# ios_location_source_test.dart, location_provider_test.dart,
# map_shell_test.dart) and, across a REAL OS background transition, by the
# e2e-ios-background-publish lane — three legs since OD4-d, so BOTH receive
# planes are exercised there: the burst on the two live-sync legs and the 90 s
# background catch-up timer on the poll one. The Simulator does suspend a
# backgrounded app that has no live location session (CI run 32646436116), which
# is why check 11 exists. Jetsam, the SLC relaunch and BGTaskScheduler remain
# physical-iPhone owner checks (docs/M7_BACKGROUND_SHARING.md §6).
#
# NOTHING runs Swift unit tests in CI (build-check.yml builds only;
# RunnerTests.swift is never executed), so for the two native handlers these
# static checks are the ONLY thing standing between a silent edit and a shipped
# regression. They are written to work on source TEXT with comments stripped,
# so prose can never satisfy a rule, and every one of them has a fixture that
# fails on the shape it forbids.
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
BG_PUBLISH_WORKFLOW="${REPO_ROOT}/.github/workflows/e2e-ios-background-publish.yml"
SLC_HANDLER="${REPO_ROOT}/haven/ios/Runner/HavenSLCHandler.swift"
BGTASK_HANDLER="${REPO_ROOT}/haven/ios/Runner/HavenBGTaskHandler.swift"
BURST_COORDINATOR="${REPO_ROOT}/haven/lib/src/services/background_burst_coordinator.dart"
STREAM_HANDLER="${REPO_ROOT}/haven/ios/Runner/HavenLocationStreamHandler.swift"
IOS_SOURCE="${REPO_ROOT}/haven/lib/src/services/ios_location_source.dart"
PBXPROJ="${REPO_ROOT}/haven/ios/Runner.xcodeproj/project.pbxproj"
BG_PUBLISH_WRAPPER="${REPO_ROOT}/tooling/e2e/ci/run-ios-bg-publish.sh"
BG_PUBLISH_PROBE="${REPO_ROOT}/tooling/e2e/ci/bgp-wire-probe.dart"
LOCATION_CONSTANTS="${REPO_ROOT}/haven/lib/src/constants/location.dart"

FAILED=0
fail() {
  echo "FAIL: $*" >&2
  FAILED=1
}

# Failure sink for the checks that are factored into functions so
# --self-test can drive them against fixture files. They report through this
# instead of `fail` so they can return an exit code the fixtures assert on.
_lf=0
lfail() {
  echo "FAIL: $*" >&2
  _lf=1
}

for f in "$SERVICE" "$PROVIDER" "$MAP_SHELL" "$PLIST" "$SESSION_HANDLER" "$APP_DELEGATE" "$BG_PROVIDER" "$BG_PUBLISH_DRIVE" "$BG_PUBLISH_WORKFLOW" "$STREAM_HANDLER" "$IOS_SOURCE" "$PBXPROJ"; do
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

# Prints the brace-balanced block that opens at the first `{` at or after
# <anchor> in the text on stdin, and NOTHING after its matching `}`. Empty when
# the anchor is missing or the braces do not balance.
#
# `fn_slice` cannot do this job for an inner block: it counts braces per LINE,
# so `} else {` nets to zero and the slice runs on into the else branch — which
# is exactly the branch the only-Best rule and the tier rule need excluded.
brace_block() { # <anchor>; text on stdin
  awk -v anchor="$1" '
    { s = s $0 "\n" }
    END {
      a = index(s, anchor); if (a == 0) exit
      b = index(substr(s, a), "{"); if (b == 0) exit
      b += a - 1
      depth = 0
      for (e = b; e <= length(s); e++) {
        c = substr(s, e, 1)
        if (c == "{") depth++
        else if (c == "}") { depth--; if (depth == 0) break }
      }
      if (depth != 0) exit
      print substr(s, b, e - b + 1)
    }'
}

# Prints everything that FOLLOWS the brace block opened at <anchor> — i.e. the
# `else` chain, if any, that the branch is attached to. Empty when the anchor is
# missing or the braces do not balance.
#
# The shape of an else matters as much as its contents: `else if let held =
# alwaysSession ...` and `else` run the same statements, but only the second
# runs them when the reference is already gone.
after_block() { # <anchor>; text on stdin
  awk -v anchor="$1" '
    { s = s $0 "\n" }
    END {
      a = index(s, anchor); if (a == 0) exit
      b = index(substr(s, a), "{"); if (b == 0) exit
      b += a - 1
      depth = 0
      for (e = b; e <= length(s); e++) {
        c = substr(s, e, 1)
        if (c == "{") depth++
        else if (c == "}") { depth--; if (depth == 0) break }
      }
      if (depth != 0) exit
      print substr(s, e + 1)
    }'
}

# Line number of the first EXECUTABLE occurrence of <pattern> (ERE) in the
# code view of <text-on-stdin>, or empty. Used by the line-order pins.
code_line_of() { # <ere>; text on stdin
  grep -nE -- "$1" | head -n1 | cut -d: -f1
}

# Blanks the CONTENTS of every quoted span, leaving the quotes themselves.
#
# The brace scanner below decides what a statement is nested INSIDE by counting
# `{` and `}`. A brace that lives in a string literal — a `${...}` interpolation
# or a message that merely mentions one — is not a block, and letting it move
# the depth would make the scanner read a top-level statement as a nested one
# or the reverse.
strip_strings() { # text on stdin
  awk '
    BEGIN { sq = sprintf("%c", 39); dq = sprintf("%c", 34); bs = sprintf("%c", 92) }
    {
      out = ""; q = ""; i = 1; n = length($0)
      while (i <= n) {
        c = substr($0, i, 1)
        if (q == "") {
          if (c == sq || c == dq) q = c
          out = out c
        } else {
          if (c == bs) { i += 2; continue }
          if (c == q) { q = ""; out = out c }
        }
        i++
      }
      print out
    }'
}

# True when <needle> occurs at least once in the code on stdin at a point that
# NOTHING conditional encloses: every brace block around it was opened by
# something other than `if`/`else`/`for`/`while`/`switch`/`do`/`catch`, and the
# statement it sits in is not itself a braceless conditional.
#
# `try {` is deliberately transparent — its body runs on every path — while its
# `catch` is not, which is the difference between "the link is issued whatever
# happens" and "the link is issued when something failed".
#
# Presence is not the promise. A guard that only greps for a call inside a
# method stays green through the most natural-looking refactor there is:
# tucking the calls into the branch that already exists above them. The method
# still names them, still compiles, still reads correctly — and the release has
# quietly become conditional on the state that branch tests for.
# The brace-balanced BODY of the function whose slice is on stdin — the block
# that opens at the first `{` OUTSIDE the signature's parentheses.
#
# `brace_block` cannot do this job here: a named-parameter list is itself a
# brace block, so anchoring on the signature returns the PARAMETERS. Paren
# depth separates them exactly, for named and positional signatures alike, and
# the separation matters: a parameter named after a link would satisfy any rule
# about the link being present.
fn_body() { # function slice on stdin
  strip_strings | awk '
    { s = s $0 "\n" }
    END {
      pd = 0; b = 0
      for (i = 1; i <= length(s); i++) {
        c = substr(s, i, 1)
        if (c == "(") pd++
        else if (c == ")") pd--
        else if (c == "{" && pd == 0) { b = i; break }
      }
      if (b == 0) exit
      depth = 0
      for (e = b; e <= length(s); e++) {
        c = substr(s, e, 1)
        if (c == "{") depth++
        else if (c == "}") { depth--; if (depth == 0) break }
      }
      if (depth != 0) exit
      print substr(s, b, e - b + 1)
    }'
}

has_unconditional() { # <needle>; code text on stdin
  strip_strings | awk -v needle="$1" '
    { s = s $0 "\n" }
    END {
      n = length(s); m = length(needle); depth = 0; cur = ""; found = 0
      cond[0] = 0
      for (i = 1; i <= n; i++) {
        if (substr(s, i, m) == needle) {
          blocked = (cur ~ /(^|[^A-Za-z0-9_$])(if|else|for|while|switch|do|catch)([^A-Za-z0-9_]|$)/) ? 1 : 0
          for (d = 1; d <= depth; d++) if (cond[d]) blocked = 1
          if (!blocked) found = 1
        }
        c = substr(s, i, 1)
        if (c == "{") {
          depth++
          cond[depth] = (cur ~ /(^|[^A-Za-z0-9_$])(if|else|for|while|switch|do|catch)([^A-Za-z0-9_]|$)/) ? 1 : 0
          cur = ""
        } else if (c == "}") {
          if (depth > 0) depth--
          cur = ""
        } else if (c == ";") {
          cur = ""
        } else {
          cur = cur c
        }
      }
      exit found ? 0 : 1
    }'
}

check_single_plugin_boundary() { # <geolocator_location_service.dart> <lib dir>
  local svc="$1" lib="$2"
  _lf=0

  # The DefaultGeolocatorWrapper's `geo.Geolocator.getPositionStream` delegate
  # IS the plugin boundary, not a consumer of it, and is excluded. The call may
  # be line-wrapped, so match the leading-dot invocation form.
  local calls
  calls="$(grep -E '\.getPositionStream\(' <<<"$(code_view "$svc")" | grep -cvE 'Geolocator\.getPositionStream' || true)"
  if [[ "$calls" != "1" ]]; then
    lfail "expected exactly 1 executable .getPositionStream( call site in $(basename "$svc") (excluding the wrapper delegate), found ${calls} — the single-plugin-boundary invariant is broken. A second call site re-introduces the cached-stream settings-swallowing defect (a later request silently inherits the live session's settings); zero means the service no longer subscribes to the ANDROID owner at all, which no unit test can distinguish from a stream that simply never fires"
  fi

  # The iOS half of the same statement. `IosLocationSource.positions(` is the
  # boundary to Haven's own CLLocationManager; a second call site opens a
  # second EventChannel listen, and the native side hands the second listener
  # the sink while `onCancel` tears the first one's session down.
  local ios_calls
  ios_calls="$(code_count '.positions(' "$svc")"
  if [[ "$ios_calls" != "1" ]]; then
    lfail "expected exactly 1 executable .positions( call site in $(basename "$svc"), found ${ios_calls} — the iOS stream owner has exactly one boundary too. Two subscriptions to the native EventChannel share one CLLocationManager and one sink; zero means the iOS branch no longer subscribes at all, and a stream that never fires looks identical to a quiet platform"
  fi

  # And exactly ONE file under haven/lib may subscribe to the native event
  # channel. A second `receiveBroadcastStream(` is a second native listen by
  # another name, and it would not be counted above.
  local subs
  subs="$(grep -rlE 'receiveBroadcastStream\(' --include='*.dart' "$lib" 2>/dev/null | sort || true)"
  local nsubs=0
  [[ -n "$subs" ]] && nsubs="$(wc -l <<<"$subs")"
  if [[ "$nsubs" != "1" ]]; then
    lfail "expected exactly 1 Dart file under $(basename "$lib") subscribing to a native EventChannel (receiveBroadcastStream), found ${nsubs}: ${subs:-none} — the native position stream has exactly one Dart owner (ios_location_source.dart); zero means nothing subscribes to the iOS session at all"
  elif [[ "$(basename "$subs")" != "ios_location_source.dart" ]]; then
    lfail "the only receiveBroadcastStream( subscriber under $(basename "$lib") is ${subs}, not ios_location_source.dart — the native position stream must be owned by IosLocationSource, which is where the profile controller, the only-Best rule and the sink error contract live"
  fi
  return "$_lf"
}

check_ios_stream_route() { # <geolocator_location_service.dart>
  local svc="$1"
  _lf=0
  local view; view="$(code_view "$svc")"

  # --- the ONE routing site -------------------------------------------------
  #
  # `_listenInner`, not `getLocationStream`: `resumeStream()` re-subscribes
  # through it after a pause, and it must ask for the SAME background intent
  # the outer stream was created with. A routing expression that lived in
  # `getLocationStream` alone would leave the resume path taking the parameter
  # default — a background-capable session silently downgraded on the first
  # resume, which nothing observes until peers stop receiving.
  local listen_body
  listen_body="$(fn_slice 'void _listenInner(' "$svc")"
  if [[ -z "$listen_body" ]]; then
    lfail "_listenInner not found in $(basename "$svc") — it is the single platform-routing site (iOS: Haven's own session; Android: geolocator). If it was renamed, update this guard rather than deleting it"
    return "$_lf"
  fi
  local listen_flat
  listen_flat="$(tr '\n' ' ' <<<"$listen_body" | tr -s ' ')"

  grep -qE 'backgroundSharingEnabled *= *_streamBackgroundSharing' <<<"$listen_flat" ||
    lfail "_listenInner no longer takes the background intent from _streamBackgroundSharing — the stored intent is what makes a resumeStream() re-subscription identical to the original one; anything else lets a restart drop the background capability"
  grep -qE '\.positions\( *allowsBackgroundLocationUpdates: *backgroundSharingEnabled' <<<"$listen_flat" ||
    lfail "_listenInner does not route iOS through 'positions(allowsBackgroundLocationUpdates: backgroundSharingEnabled)' — the toggle must reach the native manager's allowsBackgroundLocationUpdates unchanged, and a literal there would either keep the OS keep-alive for a user who declined background sharing (privacy Rule 10) or drop it for one who did not"
  grep -qF '_isIOS' <<<"$listen_flat" ||
    lfail "_listenInner no longer branches on _isIOS — one owner PER PLATFORM is the invariant; an unbranched route sends one platform to the other's owner"

  # R8, file-wide: the named argument may only ever be the toggle.
  local bad_assign
  bad_assign="$(grep -nE 'allowsBackgroundLocationUpdates *:' <<<"$view" |
    grep -vE 'allowsBackgroundLocationUpdates: *backgroundSharingEnabled' || true)"
  if [[ -n "$bad_assign" ]]; then
    lfail "hardcoded allowsBackgroundLocationUpdates argument in $(basename "$svc") (it may only ever be keyed off backgroundSharingEnabled): ${bad_assign}"
  fi

  # --- _streamSettings is ANDROID-ONLY now ----------------------------------
  local settings_body
  settings_body="$(fn_slice 'geo.LocationSettings _streamSettings(' "$svc")"
  if [[ -z "$settings_body" ]]; then
    lfail "_streamSettings not found in $(basename "$svc")"
  elif grep -qF 'AppleSettings(' <<<"$settings_body"; then
    lfail "_streamSettings builds geo.AppleSettings again — the iOS session belongs to HavenLocationStreamHandler, which sets distanceFilter, the accuracy tier and auto-pause natively. A geolocator AppleSettings arm here means a SECOND CLLocationManager configured by a plugin whose distance mapper compares boxed pointers, and neither manager can see the other's session"
  fi

  # --- the backgrounded cold-cache shortcut ---------------------------------
  #
  # Line order, like check 12. A background-launched process (SLC/region/BGTask
  # relaunch) builds this service before any Flutter lifecycle callback, so a
  # Dart-side foreground flag reads `true` there and the one-shot below would be
  # started from the background, where its CLLocationManager never enables
  # background updates and the request simply times out. The lifecycle must come
  # from the NATIVE session, and it must fail closed.
  local gcl
  gcl="$(fn_slice 'Future<Position> getCurrentLocation() async {' "$svc")"
  if [[ -z "$gcl" ]]; then
    lfail "getCurrentLocation not found in $(basename "$svc")"
  else
    local bg_line last_line one_shot_line
    bg_line="$(code_line_of '\.backgrounded' <<<"$gcl")"
    last_line="$(code_line_of '_getLastKnownPosition\(' <<<"$gcl")"
    one_shot_line="$(code_line_of 'getCurrentPosition\(' <<<"$gcl")"
    if grep -qF '_foregroundActive' <<<"$gcl"; then
      lfail "getCurrentLocation reads _foregroundActive again — the Dart lifecycle flag defaults to foregrounded and is never written on a background LAUNCH, so the backgrounded shortcut would be skipped and a one-shot started from a process that cannot complete it. Read (await _iosSource.status()).backgrounded instead, which fails closed"
    fi
    if [[ -z "$bg_line" ]]; then
      lfail "getCurrentLocation no longer reads the native session's 'backgrounded' state — the iOS cold-cache shortcut is what keeps a relaunched process receive-only"
    elif [[ -z "$last_line" || -z "$one_shot_line" ]]; then
      lfail "getCurrentLocation lost its last-known read or its one-shot call — the shortcut is an ORDER between the two, so neither may go missing (last-known line ${last_line:-none}, one-shot line ${one_shot_line:-none})"
    elif (( bg_line >= one_shot_line || last_line >= one_shot_line )); then
      lfail "getCurrentLocation runs the one-shot before the backgrounded last-known shortcut (backgrounded read line ${bg_line}, last-known line ${last_line}, one-shot line ${one_shot_line}) — a backgrounded process would stall for the full one-shot timeout instead of serving the native owner's last Best fix"
    fi

    # And the branch may not FALL THROUGH. Line order alone left the refusal
    # incidental: with both caches empty — the state a post-termination
    # SLC/region/BGTask relaunch is in BY DESIGN, since the native cache does
    # not survive termination — the shortcut found nothing and control simply
    # continued into the one-shot below, which is the publish input
    # INV-L-IOS-WAKES-RECEIVE-ONLY says a background-relaunched process cannot
    # have. So the branch is pinned STRUCTURALLY: it contains the last-known
    # read, it does not contain the one-shot, and its final statement is a
    # `throw` — nothing after it, and not nested inside anything, so no path
    # through the branch reaches the code below.
    local bg_block
    bg_block="$(brace_block '(await _iosSource.status()).backgrounded' <<<"$gcl")"
    if [[ -z "$bg_block" ]]; then
      lfail "getCurrentLocation's backgrounded branch is not a brace-balanced block opened at '(await _iosSource.status()).backgrounded' — the refusal is pinned as a BLOCK that cannot complete normally, so it has to be one"
    else
      grep -qF '_getLastKnownPosition(' <<<"$bg_block" ||
        lfail "getCurrentLocation's backgrounded branch no longer reads _getLastKnownPosition() — it would refuse without first serving the native owner's last Best fix, which is the only publish input a backgrounded iOS process has"
      if grep -qE 'getCurrentPosition\(' <<<"$bg_block"; then
        lfail "getCurrentLocation's backgrounded branch starts the one-shot ITSELF — moving the call inside the branch keeps the line order but re-opens the same hole: a background-launched process would start a request whose CLLocationManager has no background capability"
      fi
      # `throw` last: everything from the final `throw` to the end of the
      # branch must be that one statement — exactly one `;`, and no `}`, which
      # is what a throw nested inside an `if` would leave behind.
      if ! awk '
          { s = s $0 "\n" }
          END {
            b = index(s, "{"); e = length(s)
            while (e > 0 && substr(s, e, 1) != "}") e--
            body = substr(s, b + 1, e - b - 1)
            t = 0
            for (i = 1; i <= length(body) - 4; i++) {
              if (substr(body, i, 5) == "throw") t = i
            }
            if (t == 0) exit 1
            rest = substr(body, t)
            if (gsub(/;/, ";", rest) != 1) exit 1
            if (index(rest, "}") > 0) exit 1
            exit 0
          }' <<<"$bg_block"; then
        lfail "getCurrentLocation's backgrounded branch does not END in a throw — with no cached fix it would FALL THROUGH to the one-shot below, and 'the plugin one-shot is unreachable there' would be a coincidence of what happened to be in memory rather than a rule (INV-L-IOS-WAKES-RECEIVE-ONLY). A throw nested inside an inner block does not count: the last statement of the branch must be the refusal itself"
      fi
    fi
  fi

  # --- last-known is the NATIVE owner's last BEST fix on iOS ----------------
  local lastknown
  lastknown="$(fn_slice 'Future<Position?> _getLastKnownPosition() async {' "$svc")"
  if [[ -z "$lastknown" ]]; then
    lfail "_getLastKnownPosition not found in $(basename "$svc")"
  else
    grep -qE '_isIOS.*_iosSource\.lastBestFix\(' <<<"$(tr '\n' ' ' <<<"$lastknown")" ||
      lfail "_getLastKnownPosition no longer serves _iosSource.lastBestFix() on iOS — the plugin's CLLocationManager is never STARTED under the native owner, so its .location property holds something undefined, and only the native cache carries the only-Best guarantee (a 100 m-tier coordinate is never stored there, so it can never be served here)"
  fi

  # --- all THREE copies clear TOGETHER --------------------------------------
  #
  # The service reaches two of them from here: its own `_lastStreamPosition`
  # and, through `clearLastBestFix()`, the native cache AND the profile
  # controller's anchor (pinned in check 4b, where that method lives).
  local clearbody
  clearbody="$(fn_slice 'void clearCachedPosition() {' "$svc")"
  if [[ -z "$clearbody" ]]; then
    lfail "clearCachedPosition not found in $(basename "$svc")"
  else
    grep -qF '_iosSource.clearLastBestFix(' <<<"$clearbody" ||
      lfail "clearCachedPosition no longer clears the NATIVE last-Best fix — on logout or a background-sharing opt-out the Dart copy would go while a full-precision coordinate stayed in the stream handler's memory and in the profile controller's anchor, outliving the consent that produced it (privacy Rule 10)"
  fi
  return "$_lf"
}

check_ios_source_third_copy() { # <ios_location_source.dart>
  local src="$1"
  _lf=0
  local view; view="$(code_view "$src")"
  if [[ -z "${view//[[:space:]]/}" ]]; then
    lfail "$(basename "$src") holds no code — an emptied or fully commented-out source must never read as a clean one"
    return "$_lf"
  fi

  # A live session holds the last Best fix THREE times: natively, as the
  # service's `_lastStreamPosition`, and as the profile controller's anchor.
  # The first two are cleared from the service (check 4); the anchor is only
  # reachable from here, and nothing outside this file can see that it was
  # missed — it is never emitted, so no behavioural test of the publish path
  # would go red.
  local clearbody
  clearbody="$(fn_slice 'Future<void> clearLastBestFix() {' "$src")"
  if [[ -z "$clearbody" ]]; then
    lfail "MethodChannelIosLocationSource.clearLastBestFix not found in $(basename "$src") as a BLOCK-bodied method — the anchor clear and the channel call have to live together, so an expression body cannot express it"
  else
    grep -qE '_controller\.forgetAnchor\(' <<<"$clearbody" ||
      lfail "clearLastBestFix no longer drops the profile controller's anchor — it is the THIRD full-precision copy of the last Best fix, and it survives logout, a toggle-off pause and an observed access loss unless it is cleared here (privacy Rule 10, INV-L-IOS-PUBLISH-INPUT-BEST-PROFILE-ONLY)"
    grep -qE "_invoke\('clearLastBestFix'" <<<"$clearbody" ||
      lfail "clearLastBestFix no longer invokes the native clearLastBestFix — the Dart copies would go while the coordinate stayed in the stream handler's memory"
  fi

  local forgetbody
  forgetbody="$(fn_slice 'void forgetAnchor(DateTime now) {' "$src")"
  if [[ -z "$forgetbody" ]]; then
    lfail "IosProfileController.forgetAnchor not found in $(basename "$src") — it is what makes the third copy clearable at all"
  else
    grep -qE '_anchor *= *null' <<<"$forgetbody" ||
      lfail "forgetAnchor does not null the anchor — every other field it touches is bookkeeping; the anchor is the coordinate, and a version that only resets the tier reads correctly while leaving the plaintext position in memory"
    grep -qE '_profile *= *IosLocationProfile\.best' <<<"$forgetbody" ||
      lfail "forgetAnchor no longer returns the session to Best — an anchorless coarse tier can neither confirm stillness nor measure a displacement, so it would sit at a tier that decides nothing until the app is foregrounded"
  fi
  return "$_lf"
}

check_stationary_anchor_cap() { # <ios_location_source.dart> <geolocator_location_service.dart>
  local src="$1" svc="$2"
  _lf=0
  local view; view="$(code_view "$src")"
  if [[ -z "${view//[[:space:]]/}" ]]; then
    lfail "$(basename "$src") holds no code — an emptied or fully commented-out source must never read as a clean one"
    return "$_lf"
  fi

  # --- the DELIVERY half: a confirming fix may not extend an aged-out anchor
  #
  # The chain of confirmations is what removes the freshness ceiling on a
  # PUBLISHED coordinate, because the wire carries the publish instant and
  # never the fix time. The break has to happen on the delivery and not only on
  # the deadline timer: a suspended app services the fix that woke it, and an
  # overdue timer must not be what stands between a peer and a coordinate this
  # class already knows is stale.
  local coarse
  coarse="$(fn_slice 'void _onCoarseProfileFix(IosFix fix) {' "$src")"
  if [[ -z "$coarse" ]]; then
    lfail "IosProfileController._onCoarseProfileFix not found in $(basename "$src") — the confirmation chain is written there, and so is the only thing that ends it"
  else
    local coarse_flat; coarse_flat="$(tr '\n' ' ' <<<"$coarse")"
    if ! grep -qE 'anchor\.timestamp[^;]*kStationaryAnchorMaxAge' <<<"$coarse_flat"; then
      lfail "_onCoarseProfileFix no longer bounds the ANCHOR's own age by kStationaryAnchorMaxAge — a stationary backgrounded device then re-publishes one Best coordinate for as long as coarse fixes keep vouching for it, each stamped with the publish instant, so a peer reads 'just now' for a fix that may be hours old and up to 200 m wrong (OD-P3-e). Measuring the cap from the CONFIRMATION rather than from the anchor recreates exactly the chain it exists to break"
    else
      local capbody; capbody="$(brace_block 'kStationaryAnchorMaxAge' <<<"$coarse")"
      if [[ -z "$capbody" ]]; then
        lfail "the kStationaryAnchorMaxAge branch of _onCoarseProfileFix is not a brace-delimited block — the guard reads the branch body, and an expression form hides what the expiry actually does"
      else
        grep -qE '_profile *= *IosLocationProfile\.best' <<<"$capbody" ||
          lfail "the expired-anchor branch of _onCoarseProfileFix no longer returns the session to Best — bounded staleness means going and taking a real fix, and a branch that merely stops confirming leaves the session at a tier that cannot produce one"
        grep -qE '_confirmedAt *= *null' <<<"$capbody" ||
          lfail "the expired-anchor branch of _onCoarseProfileFix no longer drops the confirmation — the confirmation is what extends the freshness window past the fix time, so an anchor that may no longer be served must stop carrying one"
      fi
    fi
  fi

  # --- the TIMER half: the earlier of the two deadlines --------------------
  local deadline
  deadline="$(fn_slice 'Duration? nextDeadline(DateTime now) {' "$src")"
  if [[ -z "$deadline" ]]; then
    lfail "IosProfileController.nextDeadline not found in $(basename "$src") — it is what arms the single confirm timer, and therefore what escalates a session no fix is arriving to break"
  else
    local deadline_flat; deadline_flat="$(tr '\n' ' ' <<<"$deadline")"
    grep -qF 'kStationaryConfirmMaxAge' <<<"$deadline_flat" ||
      lfail "nextDeadline no longer arms on kStationaryConfirmMaxAge — nothing would then escalate a coarse session that stops being confirmed at all"
    grep -qF 'kStationaryAnchorMaxAge' <<<"$deadline_flat" ||
      lfail "nextDeadline no longer arms on kStationaryAnchorMaxAge — the confirm deadline only ever fires when NOTHING confirms, so a device whose coarse fixes keep confirming would arm no timer that can ever come due"
    grep -qE 'remaining *= *[A-Za-z_]+ *< *[A-Za-z_]+ *\? *[A-Za-z_]+ *: *[A-Za-z_]+' <<<"$deadline_flat" ||
      lfail "nextDeadline no longer returns the EARLIER of the two deadlines as 'remaining = a < b ? a : b' — computing the anchor bound and then arming the timer on the confirm bound alone reads correctly and caps nothing. If the expression is deliberately restructured, update this pin with it"
  fi

  # --- the SERVING half: the bound at the point the coordinate is handed out
  #
  # The escalation above is carried by a delivery or a timer, and neither is
  # guaranteed to have run before the next publish reads the cache. Both halves
  # read the one constant, so the bound cannot be enforced at two values.
  local fresh
  fresh="$(awk '/bool _streamFixIsFresh\(/{f=1} f{print; if (/;/) exit}' <<<"$(code_view "$svc")")"
  if [[ -z "$fresh" ]]; then
    lfail "_streamFixIsFresh not found in $(basename "$svc") — it is the ONE freshness rule both the cache read and hasFreshStreamFix answer from"
  else
    local fresh_flat; fresh_flat="$(tr '\n' ' ' <<<"$fresh")"
    grep -qF 'kStreamPositionMaxAge' <<<"$fresh_flat" ||
      lfail "_streamFixIsFresh no longer bounds the confirmed age by kStreamPositionMaxAge — that is the window every platform, Android included, has always been held to"
    grep -qE 'difference\(fix\.timestamp\)[^;]*kStationaryAnchorMaxAge' <<<"$fresh_flat" ||
      lfail "_streamFixIsFresh no longer caps the FIX's own age at kStationaryAnchorMaxAge — a confirmation may extend the window but may not remove it, and this clause is what makes the bound true at the point the coordinate is actually served rather than only when a timer happens to have fired first (OD-P3-e). Capping the confirmation's age instead is not the same rule: the confirmation is refreshed by every coarse fix"
  fi
  return "$_lf"
}

check_native_stream_handler() { # <HavenLocationStreamHandler.swift>
  local sh="$1"
  _lf=0
  local view; view="$(code_view "$sh")"
  if [[ -z "${view//[[:space:]]/}" ]]; then
    lfail "$(basename "$sh") holds no code — an emptied or fully commented-out handler must never read as a clean one"
    return "$_lf"
  fi

  # --- init: the shape that keeps a backgrounded app receiving --------------
  local init_body
  init_body="$(fn_slice 'override init() {' "$sh")"
  if [[ -z "$init_body" ]]; then
    lfail "$(basename "$sh") has no init() — the four session properties are set once there, for BOTH accuracy profiles"
    return "$_lf"
  fi
  grep -qE 'pausesLocationUpdatesAutomatically *= *false' <<<"$init_body" ||
    lfail "init() no longer sets pausesLocationUpdatesAutomatically = false — auto-pause ends delivery with no callback and no restart path while backgrounded, and iOS refuses the restart a resume would need"
  grep -qE 'distanceFilter *= *kCLDistanceFilterNone' <<<"$init_body" ||
    lfail "init() no longer sets distanceFilter = kCLDistanceFilterNone — Apple's 16.4 delivery rule requires NO distance filter (together with allowsBackgroundLocationUpdates and an accuracy no coarser than 100 m); a metre-scale filter is the shape the OS is documented to suspend while stationary"
  grep -qE 'activityType *= *\.other' <<<"$init_body" ||
    lfail "init() no longer sets activityType = .other — any other activity type asks CoreLocation for activity-specific behaviour (including its own pausing heuristics) that Haven does not want"

  # Counted file-wide: a second assignment elsewhere is how the pinned value
  # gets overwritten at runtime while init() still reads correctly.
  local n prop
  for prop in pausesLocationUpdatesAutomatically distanceFilter; do
    n="$(grep -cE "${prop} *= *[^=]" <<<"$view" || true)"
    if [[ "$n" != "1" ]]; then
      lfail "expected exactly 1 assignment to ${prop} in $(basename "$sh"), found ${n} — it is set once in init() for both profiles; a second assignment can undo it on a live manager, and zero means it is never set at all"
    fi
  done

  # --- exactly TWO accuracy values, ever ------------------------------------
  #
  # A third, coarser tier (ThreeKilometers, Kilometer, ...) leaves the 16.4
  # shape and re-creates the suspension it describes. `desiredAccuracy ==`
  # comparisons are reads, not assignments, and are excluded by the `[^=]`.
  local acc bad_acc
  acc="$(grep -oE 'desiredAccuracy *= *[^=][^ ]*' <<<"$view" | sed -E 's/.*= *//' | sort -u || true)"
  if [[ -z "$acc" ]]; then
    lfail "no desiredAccuracy assignment in $(basename "$sh") — the manager would run at the CoreLocation default and neither profile would exist"
  fi
  bad_acc="$(grep -vE '^(kCLLocationAccuracyBest|kCLLocationAccuracyHundredMeters)$' <<<"$acc" || true)"
  if [[ -n "$bad_acc" ]]; then
    lfail "desiredAccuracy is assigned a value other than kCLLocationAccuracyBest / kCLLocationAccuracyHundredMeters in $(basename "$sh"): $(tr '\n' ' ' <<<"$bad_acc") — exactly two tiers may ever be assigned; a third, coarser one leaves Apple's 16.4 delivery shape and a finer one is the 24/7 GNSS session this phase removed"
  fi
  grep -qF 'kCLLocationAccuracyHundredMeters' <<<"$acc" ||
    lfail "kCLLocationAccuracyHundredMeters is never assigned to desiredAccuracy in $(basename "$sh") — the backgrounded-and-stationary tier IS the power fix; without it the session stays at Best 24/7"

  # --- onListen: the only start site, refusing background starts ------------
  local onlisten
  onlisten="$(fn_slice 'func onListen(' "$sh")"
  if [[ -z "$onlisten" ]]; then
    lfail "onListen not found in $(basename "$sh") — it is the only startUpdatingLocation() site and the only place the background refusal can live"
    return "$_lf"
  fi
  grep -qE 'let allowsBg *= *args\["allowsBackgroundLocationUpdates"\] as\? Bool \?\? false' <<<"$onlisten" ||
    lfail "onListen no longer derives allowsBg on one line as 'args[\"allowsBackgroundLocationUpdates\"] as? Bool ?? false' — the background capability must stay a pure function of the user's toggle. A literal, or a '?? true' default, hands an OS keep-alive to a user who declined background sharing whenever the argument is missing or mistyped (privacy Rule 10)"
  grep -qE 'allowsBackgroundLocationUpdates *= *allowsBg' <<<"$onlisten" ||
    lfail "onListen no longer assigns allowsBackgroundLocationUpdates = allowsBg — anything else breaks the toggle -> session hop that R8 pins on the Dart side"
  local bad_bg
  bad_bg="$(grep -nE 'allowsBackgroundLocationUpdates *= *[^=]' <<<"$view" |
    grep -vE 'allowsBackgroundLocationUpdates *= *(allowsBg|false)\b' || true)"
  if [[ -n "$bad_bg" ]]; then
    lfail "allowsBackgroundLocationUpdates is assigned something other than the derived allowsBg (onListen) or false (onCancel) in $(basename "$sh"): ${bad_bg}"
  fi
  grep -qE 'applicationState == \.background' <<<"$onlisten" ||
    lfail "onListen no longer refuses a start while applicationState == .background — iOS rejects a background-capable start issued from the background, and a refused start is indistinguishable from a running one until peers stop receiving. The test must be '== .background', never '!= .active': Flutter's 'resumed' is delivered from applicationDidBecomeActive, so a legitimate foreground start can land while UIKit still reports .inactive"
  if grep -qE 'applicationState *!= *\.active' <<<"$onlisten"; then
    lfail "onListen tests applicationState != .active — that refuses legitimate foreground starts delivered while UIKit is still .inactive (the instant Flutter reports 'resumed'), silently leaving the app with no location session at all"
  fi
  grep -qE 'events\(FlutterError\( *$|events\(FlutterError\(code: "background_start_refused"' <<<"$onlisten" ||
    lfail "onListen no longer pushes the refusal through the event SINK — a FlutterError RETURNED from onListen is handed to FlutterError.reportError and never reaches the stream, so the refusal would be swallowed and Dart would wait forever for a fix"
  grep -qF 'background_start_refused' <<<"$onlisten" ||
    lfail "onListen no longer emits the 'background_start_refused' code — Dart distinguishes the refusal from a CoreLocation failure by that code"
  if grep -qE 'return FlutterError\(' <<<"$onlisten"; then
    lfail "onListen RETURNS a FlutterError — the Flutter engine hands a returned error to FlutterError.reportError and never adds it to the stream. Every outcome must travel through the sink; onListen always returns nil"
  fi
  grep -qF 'startUpdatingLocation()' <<<"$onlisten" ||
    lfail "onListen no longer starts the manager — nothing else may, so the session would never exist"
  n="$(code_count 'startUpdatingLocation()' "$sh")"
  if [[ "$n" != "1" ]]; then
    lfail "expected exactly 1 startUpdatingLocation() site in $(basename "$sh"), found ${n} — a second start outside onListen escapes the background refusal, which is the whole of R7"
  fi

  # --- the indicator is a TIER decision, taken in one place ------------------
  local ind
  ind="$(grep -nE 'showsBackgroundLocationIndicator *= *[^=]' <<<"$view" || true)"
  n=0; [[ -n "$ind" ]] && n="$(wc -l <<<"$ind")"
  if [[ "$n" != "1" ]]; then
    lfail "expected exactly 1 showsBackgroundLocationIndicator assignment in $(basename "$sh"), found ${n}: ${ind:-none} — one site, one policy; a second assignment decides the pill somewhere the tier is not known"
  elif ! grep -qE 'showsBackgroundLocationIndicator *= *!' <<<"$ind" || ! grep -qF 'alwaysConfirmed' <<<"$ind"; then
    lfail "showsBackgroundLocationIndicator is not assigned '!<...>alwaysConfirmed': ${ind} — a hardcoded value decouples the pill from the tier. Under CONFIRMED Always the flag is the only remaining pill source and OD1 turns it off; under When-In-Use (which is what the OS makes of a provisional or iOS 17 Always) the pill is mandatory and the flag must stay true so the settings copy, which follows this state, stays honest"
  fi

  # --- only Best-profile fixes are ever cached ------------------------------
  local best_guard
  best_guard="$(brace_block 'desiredAccuracy == kCLLocationAccuracyBest && loc.timestamp >= bestSince' <<<"$view")"
  local assigns
  assigns="$(grep -nE 'lastBestFix *= *[^=]' <<<"$view" | grep -vE 'lastBestFix *= *nil' || true)"
  n=0; [[ -n "$assigns" ]] && n="$(wc -l <<<"$assigns")"
  if [[ "$n" != "1" ]]; then
    lfail "expected exactly 1 non-nil assignment to lastBestFix in $(basename "$sh"), found ${n}: ${assigns:-none} — the cache that feeds every published coordinate has one writer"
  elif [[ -z "$best_guard" ]]; then
    lfail "no 'if manager.desiredAccuracy == kCLLocationAccuracyBest && loc.timestamp >= bestSince' block in $(basename "$sh") — BOTH clauses are the rule: the tier says what the manager was asked for, and the timestamp excludes a fix that was COMPUTED under the 100 m tier and merely arrived after the switch. Dropping either one publishes a coarse coordinate as a GPS-grade one"
  elif ! grep -qF "$(sed -E 's/^ *[0-9]+://; s/^ *//' <<<"$assigns")" <<<"$best_guard"; then
    lfail "the lastBestFix assignment (${assigns}) is not inside the Best-profile guard — a fix taken at the 100 m tier would become the publish input and the last-known answer"
  fi
  local oncancel
  oncancel="$(fn_slice 'func onCancel(' "$sh")"
  if [[ -z "$oncancel" ]]; then
    lfail "onCancel not found in $(basename "$sh")"
  else
    grep -qE 'lastBestFix *= *nil' <<<"$oncancel" ||
      lfail "onCancel no longer drops lastBestFix — a full-precision coordinate would outlive the subscription that produced it in NATIVE memory, where the Dart-side clear cannot reach it (privacy Rule 10)"
    grep -qF 'stopUpdatingLocation()' <<<"$oncancel" ||
      lfail "onCancel no longer stops the manager — the CoreLocation session would outlive its only subscriber"
    grep -qE 'allowsBackgroundLocationUpdates *= *false' <<<"$oncancel" ||
      lfail "onCancel no longer clears allowsBackgroundLocationUpdates — the background claim would survive a suspendStream() or an opt-out pause"
  fi
  grep -qF 'case "clearLastBestFix"' <<<"$view" ||
    lfail "$(basename "$sh") no longer handles the clearLastBestFix method — Dart's clearCachedPosition() would clear only its own copy and the native one would survive logout (privacy Rule 10)"

  # --- transient failures are not session-ending ----------------------------
  #
  # CoreLocation reports `locationUnknown` for "no fix right now" and keeps
  # trying; Apple documents clients as ignoring it, and it is routine INDOORS,
  # which is exactly where the stationary 100 m tier runs. Dart reads any sink
  # error as the end of the session's tier bookkeeping, so forwarding this one
  # ended background sharing over a momentary loss of signal until the user
  # reopened the app. Everything else must still be forwarded: a `denied` that
  # never reaches Dart is a revocation nothing observes.
  local didfail
  didfail="$(fn_slice 'didFailWithError error: Error) {' "$sh")"
  if [[ -z "$didfail" ]]; then
    lfail "didFailWithError not found in $(basename "$sh") — CoreLocation reports a denial through it, and a handler that does not exist leaves the revocation unobserved on the Dart side"
  else
    grep -qE '\.locationUnknown' <<<"$didfail" ||
      lfail "didFailWithError no longer filters CLError.locationUnknown — it is the documented 'no fix right now, still trying' signal, not a failure, and forwarding it makes Dart tear down the tier bookkeeping of a session that is still running (one ordinary indoor moment ends background sharing)"
    grep -qE 'events\(FlutterError\(' <<<"$didfail" ||
      lfail "didFailWithError no longer pushes any error through the sink — filtering the transient one must not become swallowing all of them; a denial that never reaches Dart leaves a revoked session looking healthy"
    grep -qF 'denied' <<<"$didfail" ||
      lfail "didFailWithError no longer distinguishes the 'denied' code — Dart tells a revocation apart from a transient failure by it"
  fi

  # --- nothing this class could say is safe to say -------------------------
  local leaks
  leaks="$(grep -nE 'NSLog\(|[^a-zA-Z]print\(|localizedDescription' <<<"$view" || true)"
  if [[ -n "$leaks" ]]; then
    lfail "$(basename "$sh") logs, or renders an error's localizedDescription: ${leaks} — it holds nothing but coordinates and CoreLocation error internals (Security Rules 6 and 8), and no DEBUG-gated logger is wired here"
  fi
  return "$_lf"
}

check_stream_provider() { # <location_provider.dart>
  local provider="$1"
  _lf=0

  local body
  body="$(fn_slice 'final locationStreamProvider' "$provider")"
  if [[ -z "$body" ]]; then
    lfail "locationStreamProvider not found in $(basename "$provider")"
    return "$_lf"
  fi

  grep -qF 'ref.watch(backgroundSharingProvider)' <<<"$body" ||
    lfail "locationStreamProvider no longer watches backgroundSharingProvider — toggle flips would stop re-configuring the stream"
  # Line-wrapped by the formatter, so match on a flattened copy.
  grep -qE 'getLocationStream\([[:space:]]*backgroundSharingEnabled:' <<<"$(tr '\n' ' ' <<<"$body")" ||
    lfail "locationStreamProvider no longer passes the toggle state into getLocationStream — the stream would take the parameter default and lose its background capability"
  grep -qF 'ref.read(appForegroundProvider)' <<<"$body" ||
    lfail "locationStreamProvider no longer branches on ref.read(appForegroundProvider) — a background launch (SLC/region relaunch) would open a background-capable session iOS refuses to honour"

  # Split the body at the fail-closed branch. Everything outside it is the
  # RUNNING foreground build, which must never watch the foreground state: a
  # watch there tears the kept iOS session down at the resume rebuild, and no
  # frame runs while paused to put it back.
  local paused fg
  paused="$(mktemp)"; fg="$(mktemp)"
  awk -v pat='if (!ref.read(appForegroundProvider))' -v pf="$paused" -v ff="$fg" '
    !inb && index($0, pat) > 0 { inb = 1; seen = 0; depth = 0 }
    {
      if (inb) {
        print > pf
        o = gsub(/[{]/, "&"); c = gsub(/[}]/, "&")
        depth += o - c
        if (seen && depth <= 0) { inb = 0 }
        else if (o > 0) { seen = 1 }
      } else {
        print > ff
      }
    }' <<<"$body"

  if [[ ! -s "$paused" ]]; then
    lfail "locationStreamProvider has no 'if (!ref.read(appForegroundProvider))' block — the fail-closed background-launch guard is gone"
  else
    grep -qF 'getLocationStream(' "$paused" &&
      lfail "the not-foregrounded branch of locationStreamProvider starts a location stream — iOS refuses a background-capable session begun from the background (the 2026-08-20 field failure)"
  fi
  grep -qF 'clearCachedPosition()' "$fg" ||
    lfail "locationStreamProvider no longer clears the cached stream position on the foreground disabled rebuild — a plaintext coordinate would outlive the consent that produced it"
  # No closing paren: `ref.watch(appForegroundProvider.select(...))` is the
  # same defect — it still rebuilds the running build on the pause write — and
  # a match anchored on `)` would let it through.
  grep -qF 'ref.watch(appForegroundProvider' "$fg" &&
    lfail "the RUNNING foreground build of locationStreamProvider watches appForegroundProvider — the pause write would cancel the kept iOS session and the rebuild replacing it only lands at resume"
  rm -f "$paused" "$fg"
  return "$_lf"
}

# Prints the OPT-OUT branch of the C4 mid-pause consent watcher: everything in
# the `_bgSharingPausedSub` callback after the `if (next) { … return; }` re-arm
# block. Empty if any anchor is missing (an anti-vacuity failure for callers).
c4_optout_slice() { # <flat _onPaused body>
  awk -v flat="$1" '
    BEGIN {
      a = index(flat, "listenManual<bool>(backgroundSharingProvider,")
      if (a == 0) exit
      b = index(substr(flat, a), "{")            # the callback body
      if (b == 0) exit
      b += a - 1
      depth = 0
      for (e = b; e <= length(flat); e++) {
        c = substr(flat, e, 1)
        if (c == "{") depth++
        else if (c == "}") { depth--; if (depth == 0) break }
      }
      if (depth != 0) exit
      cb = substr(flat, b, e - b + 1)
      g = index(cb, "if (next)")                 # the re-arm branch
      if (g == 0) exit
      i = g + 3                                  # the "(" of the condition
      depth = 0
      for (; i <= length(cb); i++) {
        c = substr(cb, i, 1)
        if (c == "(") depth++
        else if (c == ")") { depth--; if (depth == 0) break }
      }
      if (depth != 0) exit
      i++
      while (substr(cb, i, 1) == " ") i++
      if (substr(cb, i, 1) == "{") {
        depth = 0
        for (j = i; j <= length(cb); j++) {
          c = substr(cb, j, 1)
          if (c == "{") depth++
          else if (c == "}") { depth--; if (depth == 0) break }
        }
        if (depth != 0) exit
      } else {
        j = index(substr(cb, i), ";")
        if (j == 0) exit
        j += i - 1
      }
      print substr(cb, j + 1)
    }'
}

check_c4_optout_release() { # <map_shell.dart>
  local shell="$1"
  _lf=0

  local body
  body="$(fn_slice 'Future<void> _onPaused() async {' "$shell")"
  if [[ -z "$body" ]]; then
    lfail "_onPaused not found in $(basename "$shell") — if it was renamed, update this guard rather than deleting it"
    return "$_lf"
  fi

  local flat optout
  flat="$(tr '\n' ' ' <<<"$body" | tr -s ' ')"
  optout="$(c4_optout_slice "$flat")"
  if [[ -z "$optout" ]]; then
    lfail "the C4 mid-pause consent watcher in _onPaused has no 'if (next) { … }' re-arm branch to slice, so its opt-out branch cannot be checked — restore the shape or update this guard, never delete it"
    return "$_lf"
  fi

  [[ "$optout" == *"suspendStream("* ]] ||
    lfail "the C4 opt-out branch no longer calls suspendStream( — consent withdrawn while the app is paused would leave the CLLocationManager session running, because the provider rebuild that used to release it cannot run while frames are off (privacy Rule 10)"
  [[ "$optout" == *"clearCachedPosition("* ]] ||
    lfail "the C4 opt-out branch no longer calls clearCachedPosition( — the cached coordinate would OUTLIVE the consent that produced it for the rest of the background window (privacy Rule 10)"
  [[ "$optout" == *"disarm("* ]] ||
    lfail "the C4 opt-out branch no longer disarms the native CoreLocation session objects — CLBackgroundActivitySession/CLServiceSession would keep the process executable after consent was withdrawn (privacy Rule 10)"
  [[ "$optout" == *"releaseBurstPlaneOnOptOut("* ]] ||
    lfail "the C4 opt-out branch no longer releases the burst plane — withdrawn consent would leave the engine subscribed and the publish socket open until iOS happened to suspend the process, i.e. a non-deterministic window of continued presence after the user said stop (privacy Rule 10)"

  # …and the release must still BE the release. The call site above names it;
  # only its body says whether it closes both sockets, and a gutted one
  # compiles, lints clean and leaves every other guard green.
  local release
  release="$(fn_slice 'static Future<void> releaseBurstPlaneOnOptOut(' "$shell")"
  if [[ -z "$release" ]]; then
    lfail "MapShell.releaseBurstPlaneOnOptOut not found — if it was renamed, update this guard rather than deleting it"
    return "$_lf"
  fi
  # Both links, in the BODY (the signature declares a parameter named after one
  # of them), and named rather than CALLED: a link may legitimately be handed
  # to a runner as a tear-off — `_optOutLink('pool shutdown',
  # shutdownPublishPool)` — which writes no parentheses at all. Whether the
  # runner actually runs it is a behavioural question, and it is answered
  # behaviourally in map_shell_burst_wiring_test.dart; what cannot be observed
  # from a test is the SHAPE this branch has while the process is paused, which
  # is what the rest of this function pins.
  local body
  body="$(fn_body <<<"$release")"
  if [[ -z "$body" ]]; then
    lfail "releaseBurstPlaneOnOptOut has no brace-balanced body outside its parameter list — an expression-bodied release cannot express 'both links, unconditionally', so it has to be a block"
    return "$_lf"
  fi

  # Presence is the weaker half of the promise, and the gap between the two
  # halves is one indentation level: moving the links inside the
  # `if (runningBurst != null)` branch that already sits above them keeps every
  # presence grep green while making the release happen only when a burst
  # happened to be in flight. That is the exact inverse of what the method
  # exists for — the bounded wait is bounded PRECISELY so the pause and the
  # pool shutdown are issued even when the burst never settles. A user who opts
  # out with nothing in flight is the common case, and they are the ones such a
  # refactor would leave with a live socket.
  local link
  for link in pauseSubscriptions shutdownPublishPool; do
    if ! grep -qF -- "$link" <<<"$body"; then
      lfail "releaseBurstPlaneOnOptOut's body no longer names '${link}' — the standing REQ opened by the last burst, or the publish pool behind it, would live on with its socket for the whole background window after the user said stop"
      continue
    fi
    has_unconditional "$link" <<<"$body" ||
      lfail "releaseBurstPlaneOnOptOut reaches '${link}' only from inside a conditional (an if/else, a loop or a catch) — it must be issued on EVERY path. 'An opt-out leaves no socket' is unconditional: nesting the link under the burst-in-flight branch, or under the error handler, leaves the standing REQ and the publish pool up for every user who withdrew consent while nothing was running"
  done

  return "$_lf"
}

check_burst_plane_entry() { # <lib dir> <native wake handler>...
  local lib="$1"; shift
  _lf=0

  local coordinator="${lib}/src/services/background_burst_coordinator.dart"
  local owner="${lib}/src/pages/map_shell.dart"
  local engine_api="${lib}/src/services/subscription_service.dart"
  local engine_impl="${lib}/src/services/nostr_subscription_service.dart"

  # ONE pass over the tree, four sweeps. Every one reads the CODE view: the
  # coordinator's own header quotes `setTickSink(coordinator)` in prose, and a
  # doc comment must never be able to satisfy — or violate — a rule.
  #
  # Generated bindings are excluded. `lib/src/rust/` mirrors the Rust API
  # surface verbatim; it is not a place where anyone decides who may publish.
  local f view built="" sunk="" installed="" opened=""
  while IFS= read -r f; do
    case "$f" in */lib/src/rust/*) continue ;; esac
    view="$(code_view "$f")"
    grep -qE -- 'BackgroundBurstCoordinator\(' <<<"$view" && built+="${f}"$'\n'
    grep -qE -- '(implements|extends|with)[^;{]*\bBurstSink\b|extends[^;{]*\bBackgroundBurstCoordinator\b' <<<"$view" &&
      sunk+="${f}"$'\n'
    grep -qE -- '\.setTickSink\(' <<<"$view" && installed+="${f}"$'\n'
    grep -qE -- '\bopenBackgroundBurst\b' <<<"$view" && opened+="${f}"$'\n'
  done < <(find "$lib" -name '*.dart' -type f | LC_ALL=C sort)
  built="${built%$'\n'}"; sunk="${sunk%$'\n'}"
  installed="${installed%$'\n'}"; opened="${opened%$'\n'}"

  # 1. Construction. The coordinator's own file declares the constructor and is
  #    excluded; every other mention is a call.
  local built_sites
  built_sites="$(grep -vFx -- "$coordinator" <<<"$built" || true)"
  [[ "$built_sites" == "$owner" ]] ||
    lfail "BackgroundBurstCoordinator is constructed in [${built_sites:-nowhere}], not in exactly $(basename "$owner") — it PUBLISHES (one GPS fix, one kind-445 per due circle), and the only process that may is the one the user last had open. A construction site in another file is one edit away from an entry point that runs with no UI"

  # 2. Any OTHER way to become the thing the scheduler ticks. The constructor
  #    is not the only door: `BurstSink` is a public interface and the
  #    coordinator is a plain class, so an implementation — or a subclass
  #    reaching the same collaborators through `super(...)` — becomes the sink
  #    without ever writing the constructor's name.
  [[ "$sunk" == "$coordinator" ]] ||
    lfail "BurstSink is implemented, or BackgroundBurstCoordinator subclassed, in [${sunk:-nowhere}] rather than in exactly $(basename "$coordinator") — a second sink is a second publisher, and it passes a constructor-name pin untouched. 'Nowhere' is the same defect read backwards: the coordinator would no longer be the scheduler's sink at all"

  # 3. Installation. `setTickSink` is public on the scheduler notifier, so
  #    holding a sink is not enough — this is the call that makes the burst
  #    plane receive ticks. Its DECLARATION carries no receiver and is not
  #    matched.
  [[ "$installed" == "$owner" ]] ||
    lfail "the scheduler's tick sink is installed from [${installed:-nowhere}], not from exactly $(basename "$owner") — the install is what routes every due circle's publish through the burst plane, and it belongs to the file that owns the pause and therefore knows the process is still the user's. Nowhere means nothing installs it and the whole plane is dead"

  # 4. The engine's burst API. `openBackgroundBurst()` re-anchors every REQ at
  #    its persisted cursor; it is the receive half of a burst, and a caller
  #    outside this triangle is a file opening a burst on its own account.
  local expect_opened
  expect_opened="$(printf '%s\n%s\n%s\n' "$coordinator" "$engine_impl" "$engine_api" | LC_ALL=C sort)"
  [[ "$opened" == "$expect_opened" ]] ||
    lfail "openBackgroundBurst is named in [${opened:-nowhere}], not in exactly the declaration, its implementation and the coordinator — a new caller opens a burst outside the one place that closes it, and a missing one means the plane no longer re-anchors its cursors at all. If a caller is legitimately added, add it HERE in the same change"

  # 5. The native wakes. A Swift handler cannot reach the burst plane by
  #    naming a Dart symbol — it has no Dart symbols. It reaches Dart through
  #    exactly one door, `invokeMethod`, so THAT is what is pinned: every
  #    invocation these post-termination wake handlers make must be the
  #    receive-only `runCatchup`. `INV-L-IOS-WAKES-RECEIVE-ONLY` is held on the
  #    Dart side by check 3 (the backgrounded branch of getCurrentLocation ends
  #    in a throw, so a relaunched process has no publish input at all); this
  #    is the complementary shape pin — no wake may open a SECOND route into
  #    Dart, whatever that route turns out to do.
  local sw invokes bad
  for sw in "$@"; do
    if [[ ! -f "$sw" ]]; then
      lfail "expected native wake handler not found: ${sw} — a post-termination wake source that this guard cannot see is one whose Dart entry point nothing pins"
      continue
    fi
    invokes="$(grep -oE 'invokeMethod\( *"[^"]*"' <<<"$(code_view "$sw")" || true)"
    if [[ -z "$invokes" ]]; then
      lfail "$(basename "$sw") makes no executable invokeMethod( call — the wake would fire and reach no Dart at all, and a handler that does nothing is indistinguishable from one whose channel name rotted. A commented-out invocation is not one"
      continue
    fi
    bad="$(grep -vE 'invokeMethod\( *"runCatchup"' <<<"$invokes" || true)"
    if [[ -n "$bad" ]]; then
      lfail "$(basename "$sw") invokes a Dart method other than runCatchup: $(tr '\n' ' ' <<<"$bad") — a post-termination wake runs with no UI, often long after the user last opened the app, and may only ever hand control to the receive-only catch-up entry point. A second method call is a second contract, and nothing in CI can relaunch a terminated app to observe what it does (docs/M7_BACKGROUND_SHARING.md §6 item 2b)"
    fi
  done
  return "$_lf"
}

# Presence-only logging: no debugPrint may interpolate a coordinate, a Position
# or a burst fix (Security Rules 6/8, extended to location data).
#
# `BurstFix` is the reason the coordinator is on this list: it carries a
# latitude, a longitude and the pubkey the burst publishes under, in one object
# whose `toString()` would render all three. Nothing it logs today is
# sensitive — every catch prints `e.runtimeType` — and that is precisely the
# state a guard exists to keep.
check_presence_only_logging() { # <dart file>...
  _lf=0
  local f leaks
  for f in "$@"; do
    if [[ ! -f "$f" ]]; then
      lfail "expected file not found: ${f} — a file this sweep cannot read is one whose logs nothing checks"
      continue
    fi
    leaks="$(grep -nE 'debugPrint\(.*(latitude|longitude|\$position|\$\{position|\$fix|\$\{fix)' <<<"$(code_view "$f")" || true)"
    if [[ -n "$leaks" ]]; then
      lfail "$(basename "$f") debugPrint interpolates location data (presence-only logging required): ${leaks}"
    fi
  done
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

check_arm_tier_policy() { # <HavenBackgroundSessionHandler.swift>
  local sh="$1"
  _lf=0
  local view; view="$(code_view "$sh")"
  if [[ -z "${view//[[:space:]]/}" ]]; then
    lfail "$(basename "$sh") holds no code — an emptied or fully commented-out handler must never read as a clean one"
    return "$_lf"
  fi

  local arm_body
  arm_body="$(fn_slice 'func arm()' "$sh")"
  if [[ -z "$arm_body" ]]; then
    lfail "HavenBackgroundSessionHandler.arm() not found"
    return "$_lf"
  fi

  # --- the consent + authorization gates (unchanged, and never allowed to rot)
  grep -qF 'UserDefaults.standard.bool(forKey: Self.kBgSharingKey)' <<<"$arm_body" ||
    lfail "arm() no longer re-reads the persisted background-sharing consent (fail-closed gate)"
  grep -qF 'UserDefaults.standard.bool(forKey: Self.kBgDisclosureKey)' <<<"$arm_body" ||
    lfail "arm() no longer requires the accepted background disclosure — the pre-2026-06-07 stale-true cohort would get a keep-alive with no disclosure"
  grep -qF 'disarm()' <<<"$arm_body" ||
    lfail "arm() no longer disarms when the consent predicate is off — a stale session could outlive an opt-out (privacy Rule 10)"
  grep -qF '.authorizedWhenInUse' <<<"$arm_body" ||
    lfail "arm() no longer gates session creation on granted authorization — creating CLBackgroundActivitySession while .notDetermined can drive a launch-time prompt the user did not initiate"
  grep -qF '#available(iOS 17.0, *)' <<<"$arm_body" ||
    lfail "arm() lost the iOS 17 availability guard for CLBackgroundActivitySession"
  grep -qF 'CLBackgroundActivitySession()' <<<"$arm_body" ||
    lfail "arm() no longer creates CLBackgroundActivitySession — the When-In-Use tier loses its iOS 17+ background continuation contract"
  grep -qF '.authorizedAlways' <<<"$arm_body" ||
    lfail "arm() no longer gates CLServiceSession on already-granted Always authorization (an ungated .always session can drive an OS prompt)"

  # --- the TIER branch (D2 / OD1) -------------------------------------------
  #
  # `wantsActivitySession` is the whole policy in one expression, and both of
  # its clauses matter: the WIU clause is the honest posture for a tier the OS
  # treats as When-In-Use, and `!alwaysConfirmed` is what keeps a PROVISIONAL
  # Always (authorizationStatus already reports .authorizedAlways while the
  # second prompt is unanswered) and every iOS 17 Always on that same posture.
  # Gating on `.authorizedWhenInUse` alone drops the activity session for the
  # provisional cohort — the exact shape that failed in the field on
  # 2026-08-20.
  local wants
  wants="$(grep -E 'wantsActivitySession *= *' <<<"$arm_body" || true)"
  if [[ -z "$wants" ]]; then
    lfail "arm() no longer derives a wantsActivitySession predicate — the tier decision would be inlined or gone, and OD1 rests on it being one expression"
  else
    grep -qF '.authorizedWhenInUse' <<<"$wants" ||
      lfail "wantsActivitySession is not derived from .authorizedWhenInUse: ${wants} — a When-In-Use app gets nothing delivered while backgrounded without the activity session"
    grep -qE '\|\|' <<<"$wants" ||
      lfail "wantsActivitySession has no second clause: ${wants} — Always alone is not a tier decision; provisional Always and iOS 17 Always must fall on the When-In-Use side"
    grep -qF '!alwaysConfirmed' <<<"$wants" ||
      lfail "wantsActivitySession is not gated on !alwaysConfirmed: ${wants} — authorizationStatus reports .authorizedAlways while the second prompt is still unanswered, so only the POSITIVE diagnostic confirmation may take the Always branch. Gating on the status alone drops the keep-alive for the provisional cohort (the 2026-08-20 field failure)"
  fi

  local wants_block
  wants_block="$(brace_block 'if wantsActivitySession' <<<"$arm_body")"
  if [[ -z "$wants_block" ]]; then
    lfail "arm() has no 'if wantsActivitySession' block — the activity session would be created unconditionally, which is the constant blue pill under confirmed Always that OD1 removes"
  elif ! grep -qF 'CLBackgroundActivitySession()' <<<"$wants_block"; then
    lfail "arm() creates CLBackgroundActivitySession outside the wantsActivitySession branch — the tier decision would not gate the object it decides"
  fi

  # The deferred invalidate. `arm()` never withdraws an in-use claim while
  # backgrounded: a WIU->Always upgrade delivered in the background (the
  # authorization delegate DOES fire there) would otherwise drop the only
  # keep-alive the process has, while its replacement cannot start outside the
  # foreground. The AppDelegate's foreground re-arm performs it later.
  local drop_block
  drop_block="$(brace_block 'else if UIApplication.shared.applicationState != .background' <<<"$arm_body")"
  if [[ -z "$drop_block" ]]; then
    lfail "arm()'s activity-session release is not gated on 'else if UIApplication.shared.applicationState != .background' — an Always confirmation or an upgrade delivered while backgrounded would invalidate the only object keeping the process executable, and nothing can create its replacement until the next foreground (the FA wedge shape, and the DTS stuck-indicator path)"
  else
    grep -qF 'invalidate()' <<<"$drop_block" ||
      lfail "the foreground-only release branch of arm() no longer invalidates the activity session — a released reference alone leaves the session held by CoreLocation"
    grep -qF 'backgroundActivity = nil' <<<"$drop_block" ||
      lfail "the foreground-only release branch of arm() no longer nils backgroundActivity — an invalidated session can never reactivate, so the next arm() would silently reuse a dead object"
  fi

  # --- the .always reset is UNCONDITIONAL ----------------------------------
  #
  # `alwaysConfirmed` must never outlive the session that yielded it. Gating the
  # reset on the reference still being HELD (`else if let held = alwaysSession
  # ...`) reopens an ordering race the cancel cannot close: a confirmation
  # already dispatched to the main queue lands AFTER a downgrade dropped the
  # session, writes true, and re-runs arm() — which now finds the reference nil,
  # skips the gated reset, and leaves a true with nothing behind it. Contained
  # while the user stays on When-In-Use (the WIU clause of wantsActivitySession
  # still holds the session), but the NEXT Always grant then takes the Always
  # branch and drops the activity session before a single diagnostic has
  # confirmed anything — the provisional-Always shape of the 2026-08-20 field
  # failure.
  local always_tail
  always_tail="$(after_block 'if status == .authorizedAlways' <<<"$arm_body")"
  if [[ -n "$always_tail" ]]; then
    local always_else_head always_else
    always_else_head="$(grep -vE '^[[:space:]]*$' <<<"$always_tail" | head -n1)"
    if ! grep -qE '^[[:space:]]*else[[:space:]]*\{' <<<"$always_else_head"; then
      lfail "arm()'s .always branch has no UNCONDITIONAL else (found: ${always_else_head:-nothing}) — the non-Always path must clear alwaysConfirmed whether or not a session is still held. Any condition there is skippable, and the confirmation that outlives its session is what drops the activity session on the next Always grant, unconfirmed"
    else
      always_else="$(brace_block 'else' <<<"$always_tail")"
      local stmt
      for stmt in 'invalidate()' 'alwaysSession = nil' 'diagnosticsTask?.cancel()'; do
        grep -qF "$stmt" <<<"$always_else" ||
          lfail "arm()'s non-Always branch no longer runs '${stmt}' — a downgraded app must drop the unfulfilled .always goal AND its observer, or Core Location re-asks on the app's behalf at the next foreground and a live observer keeps writing verdicts for a session nobody holds"
      done
      grep -qE 'alwaysConfirmed *= *false' <<<"$always_else" ||
        lfail "arm()'s non-Always branch no longer clears alwaysConfirmed — the predicate would survive the session it was measured from, and the next Always grant would drop the activity session before any diagnostic confirmed anything (the provisional-Always shape that failed in the field)"
      local nested
      nested="$(grep -nE '(if|guard)[^;]*alwaysSession' <<<"$always_else" || true)"
      if [[ -n "$nested" ]]; then
        lfail "arm()'s non-Always branch gates its reset on alwaysSession: ${nested} — nesting the clear behind the held reference is the same skippable condition as an 'else if', and leaves alwaysConfirmed true once a racing confirmation has already nilled or replaced the session"
      fi
    fi
  fi
  local gated_reset
  gated_reset="$(grep -nE 'else if[^;]*alwaysSession' <<<"$arm_body" || true)"
  if [[ -n "$gated_reset" ]]; then
    lfail "arm() gates an else branch on alwaysSession: ${gated_reset} — the .always reset must run unconditionally. A main-queue confirmation that lands after the session was dropped re-runs arm(), and a gated branch is exactly what it slips past"
  fi

  # --- the diagnostics observer --------------------------------------------
  #
  # The confirmation is ASYNCHRONOUS: even the "immediate" first diagnostic of a
  # settled authorization lands after arm() has returned. An observer that only
  # SETS the flag leaves every genuinely-Always launch on the When-In-Use
  # posture for its whole first background window, and nothing undoes it before
  # the next foreground — OD1 would simply not materialise. Nothing behavioural
  # can see that (no Swift test runs in CI), so the re-arm is pinned here.
  local obs
  obs="$(fn_slice 'private func observeAlwaysDiagnostics' "$sh")"
  if [[ -z "$obs" ]]; then
    lfail "observeAlwaysDiagnostics not found in $(basename "$sh") — without it alwaysConfirmed can never become true and the Always tier is unreachable"
  else
    grep -qF '.diagnostics' <<<"$obs" ||
      lfail "observeAlwaysDiagnostics no longer iterates the session's diagnostics — a stubbed observer leaves alwaysConfirmed false forever, which is fail-SAFE but silently discards the whole Always branch"
    local clause
    for clause in alwaysAuthorizationDenied authorizationRequestInProgress insufficientlyInUse; do
      grep -qF "$clause" <<<"$obs" ||
        lfail "the diagnostics verdict no longer reads ${clause} — every clause must hold before Always is confirmed. A request still in progress means the second prompt is unanswered, and insufficientlyInUse means Core Location cannot act on the Always goal yet; either way the EFFECTIVE authorization is When-In-Use, and confirming there is the unsafe direction (silent publish loss)"
    done
    grep -qE 'alwaysConfirmed *= *confirmed' <<<"$obs" ||
      lfail "observeAlwaysDiagnostics does not set alwaysConfirmed from the computed verdict — the predicate would be decided somewhere the diagnostic is not in hand"
    grep -qE '(self\.)?arm\(\)' <<<"$obs" ||
      lfail "observeAlwaysDiagnostics does not RE-RUN arm() when the confirmation flips — setting the flag alone changes nothing: the activity session created by the unconfirmed first arm() stays held (and the pill with it) until the next foreground, so every real-Always launch would spend its first background window on the When-In-Use posture"
    grep -qF 'onAlwaysConfirmedChanged' <<<"$obs" ||
      lfail "observeAlwaysDiagnostics does not fire onAlwaysConfirmedChanged — the stream handler's indicator policy is the other half of the tier decision and would keep the pill on under confirmed Always"

    # The verdict is computed off the main thread and APPLIED from a block
    # hopped onto the main queue. `diagnosticsTask?.cancel()` cannot reach a
    # block that is already enqueued there, so cancelling on a downgrade
    # discards nothing that is already in flight: the stale block still runs,
    # still writes its confirmation, and the arm() it re-runs finds the session
    # gone. Nothing else in the block can tell stale from live — the flag, the
    # authorization status and the task are identical in both cases — so it must
    # compare the session it OBSERVED against the one the handler now holds, and
    # it must do so BEFORE the write.
    local hop
    hop="$(brace_block 'DispatchQueue.main.async' <<<"$obs")"
    if [[ -z "$hop" ]]; then
      lfail "observeAlwaysDiagnostics no longer applies the verdict inside a DispatchQueue.main.async block — the confirmation would be written from the diagnostics task's own thread, racing every arm()/disarm() on main outright (and no guard could see which session it belonged to)"
    else
      grep -qF 'alwaysSession' <<<"$hop" ||
        lfail "the main-queue confirmation block never re-reads alwaysSession — a block enqueued before a downgrade runs after it, so the block must re-check the handler's CURRENT session or it applies a verdict to a session that no longer exists"
      grep -qE '=== *session' <<<"$hop" ||
        lfail "the main-queue confirmation block does not compare the held session against the OBSERVED one ('=== session') — a mere non-nil check passes for a REPLACED session too, and identity is the only thing that distinguishes this observation from the next one's"
      local id_line set_line
      id_line="$(code_line_of '=== *session' <<<"$hop")"
      set_line="$(code_line_of 'alwaysConfirmed *= *confirmed' <<<"$hop")"
      if [[ -n "$id_line" && -n "$set_line" ]] && (( id_line >= set_line )); then
        lfail "the identity re-check does not precede the alwaysConfirmed write in the main-queue block (identity at line ${id_line}, write at line ${set_line}) — a check that runs after the write has already let the stale confirmation through"
      fi
    fi
  fi

  # Fail-safe, file-wide: the predicate is only ever computed or cleared.
  local forced
  forced="$(grep -nE 'alwaysConfirmed *= *true' <<<"$view" || true)"
  if [[ -n "$forced" ]]; then
    lfail "alwaysConfirmed is assigned a literal true in $(basename "$sh"): ${forced} — it may only ever come from a positive CLServiceSessionDiagnostic (or be cleared to false). A literal promotes the provisional cohort, whose effective authorization is When-In-Use, into the branch that holds no keep-alive"
  fi

  # --- disarm() is UNCONDITIONAL -------------------------------------------
  local disarm_body
  disarm_body="$(fn_slice 'func disarm()' "$sh")"
  if [[ -z "$disarm_body" ]]; then
    lfail "HavenBackgroundSessionHandler.disarm() not found"
  else
    grep -qF 'invalidate()' <<<"$disarm_body" ||
      lfail "disarm() no longer invalidates the held sessions"
    grep -qF 'backgroundActivity = nil' <<<"$disarm_body" ||
      lfail "disarm() no longer nils backgroundActivity — an invalidated session can never reactivate, so reuse is a silent no-op"
    grep -qF 'alwaysSession = nil' <<<"$disarm_body" ||
      lfail "disarm() no longer nils alwaysSession — an invalidated session can never reactivate, so reuse is a silent no-op"
    grep -qE 'alwaysConfirmed *= *false' <<<"$disarm_body" ||
      lfail "disarm() no longer clears alwaysConfirmed — a confirmation is never more current than the session that yielded it, and a stale true would take the next arm() straight to the Always branch without a diagnostic"
    # The asymmetry IS the contract: arm() never withdraws a claim while
    # backgrounded; disarm() always does. A lifecycle or consent gate here
    # would leave the OS keep-alive held through an opt-out taken while the
    # app is paused — the C4 branch's whole point (privacy Rule 10).
    local gated
    gated="$(grep -nE 'applicationState|UserDefaults' <<<"$disarm_body" || true)"
    if [[ -n "$gated" ]]; then
      lfail "disarm() consults the app lifecycle or the persisted consent: ${gated} — it must be UNCONDITIONAL. It runs on opt-out (often while the app is PAUSED, where no rebuild can run) and on identity deletion; a gate there leaves CLBackgroundActivitySession/CLServiceSession held after consent was withdrawn (privacy Rule 10), and the header sentence 'arm() never withdraws a claim while backgrounded; disarm() always does' becomes false"
    fi
  fi

  # --- nothing here has anything safe to say -------------------------------
  if grep -qE 'NSLog\(|[^a-zA-Z]print\(' <<<"$view"; then
    lfail "$(basename "$sh") logs — the handler has nothing safe to say (presence-only policy, and no DEBUG-gated logger is wired here)"
  fi
  return "$_lf"
}

check_bg_publish_drive() { # <ios_bg_publish_test.dart>
  local drive="$1"
  _lf=0
  local view; view="$(code_view "$drive")"

  # The lane measures publishing from INSIDE the app it backgrounds, and the
  # app's only claim to keep EXECUTING there is the live CLLocationManager
  # session the PRODUCTION path creates. A fake anywhere on that path removes
  # the claim: iOS suspends the process ~30 s in, the frozen in-process oracle
  # counts zero, and the lane reds blaming the publish pipeline (CI run
  # 32646436116). `iosLocationSourceProvider` is the same hole one layer down —
  # a faked source subscribes to no EventChannel, so no native session exists
  # even though the real GeolocatorLocationService is in place.
  local sym
  for sym in 'locationServiceProvider.override' 'FakeLocationService' \
    'iosLocationSourceProvider.override' 'NoopIosLocationSource' 'FakeIosLocationSource'; do
    if grep -qF -- "$sym" <<<"$view"; then
      lfail "ios_bg_publish_test.dart injects a fake location source ('$sym') — a faked service or source starts no CLLocationManager, so iOS suspends the backgrounded app and the lane can only measure a frozen process (CI run 32646436116). This target must run the production GeolocatorLocationService over the production IosLocationSource."
    fi
  done

  # Ordering. Enabling the toggle only tears the foreground session down
  # synchronously; the rebuild that re-creates it with background capability is
  # deferred to markNeedsBuild, and this binding draws no frame until the test
  # pumps. In CI run 32661622879 the rebuild landed 0.43 s AFTER SpringBoard set
  # `visibility is no`; locationd denied the process assertion and runningboardd
  # suspended the app — while every static check still passed.
  local enable_line ready_line
  enable_line="$(code_line_of 'setEnabled\(enabled: true\)' <<<"$view")"
  ready_line="$(code_line_of 'debugPrint\(kReadyForBackgroundMarker\)' <<<"$view")"
  if [[ -z "$enable_line" || -z "$ready_line" ]]; then
    lfail "ios_bg_publish_test.dart lost its setEnabled(enabled: true) call or its kReadyForBackgroundMarker print — P1 and the host handshake are the lane's spine"
    return "$_lf"
  fi
  if (( enable_line >= ready_line )); then
    lfail "ios_bg_publish_test.dart signals READY before enabling background sharing (enable line ${enable_line}, READY line ${ready_line}) — the app would be backgrounded with the toggle still off"
    return "$_lf"
  fi
  # Only the window between the enable and the READY signal counts: a pump
  # before the enable predates the rebuild, and one after READY may run against
  # a paused app, where frame production is off and the pump deadlocks.
  local arming_slice
  arming_slice="$(sed -n "$((enable_line + 1)),$((ready_line - 1))p" <<<"$view")"
  grep -qF 'await tester.pump()' <<<"$arming_slice" ||
    lfail "ios_bg_publish_test.dart no longer pumps between enabling background sharing and signalling READY — the locationStreamProvider rebuild that creates the background-capable session is deferred to markNeedsBuild, and this binding's fadePointers frame policy runs no build without a pump (CI run 32661622879)"
  grep -qE 'pumpUntilCondition\(' <<<"$arming_slice" ||
    lfail "ios_bg_publish_test.dart no longer WAITS between enabling background sharing and signalling READY — a bare pump schedules the rebuild but proves nothing about the session it creates"
  grep -qF 'locationStreamProvider' <<<"$arming_slice" ||
    lfail "ios_bg_publish_test.dart no longer asserts on locationStreamProvider between enabling background sharing and signalling READY — a fresh fix from the REBUILT stream is the only in-process proof that the background-capable session is live, and iOS only lets such a session start while the app is in use"

  # P2c's ORACLE. The receive half of the background promise has no wire
  # oracle in this lane (the host-native relay journals no REQ/CLOSE frames),
  # so it rests entirely on what the drive reads from the engine — and there
  # are two readings, one of which is wrong in a way no failing test would
  # ever show. `poolSubscriptionCount` is the count of subscriptions the pool
  # actually holds; `isPaused` is a flag the core raises as the FIRST
  # statement of its pause, before `unsubscribe_all`, before the router drain,
  # before the uncapped Rule-13 publish gauge and before the disconnect. A
  # drive switched to the flag would go GREEN through every state P2c exists
  # to catch: a pause that dropped no REQ, one still draining, one whose
  # disconnect never happened. Nothing else in this repo can see that swap —
  # the lane would still print all five of its terminal proofs.
  #
  # EVERY read below is taken off ONE string-stripped view, not just the
  # `isPaused` ban. This drive's failure reasons quote each predicate it
  # relies on, verbatim and at length — that is what makes them good failure
  # messages — so a scan over the comment-only view accepts an oracle that
  # survives solely as prose ABOUT itself: a deleted control arm with a
  # `reason:` still mentioning `count > 0` reads as present, and a `reason:`
  # mentioning `count == 0` above the poll mis-positions the ordering check,
  # which takes the FIRST match. `strip_strings` blanks quoted spans per LINE,
  # so it emits one output line per input line and the line numbers the
  # ordering pin below reads are the file's own. (Per-line is also why a Dart
  # `'''` block would read as code — this target uses none, and a future one
  # that did would need this view rebuilt rather than trusted.)
  local no_strings; no_strings="$(strip_strings <<<"$view")"
  grep -qF 'poolSubscriptionCount(' <<<"$no_strings" ||
    lfail "ios_bg_publish_test.dart no longer reads poolSubscriptionCount — P2c's 'no standing REQ between bursts' has no other oracle in this lane, and the count is the only reading that sees the REQs rather than the intent to drop them"
  if grep -qF 'isPaused' <<<"$no_strings"; then
    lfail "ios_bg_publish_test.dart reads isPaused — that flag is raised as the FIRST statement of the engine's pause, before a single REQ is dropped, so an oracle built on it reports the burst promise kept in exactly the states that break it. Read poolSubscriptionCount instead (the count of registered subscriptions); if a future phase needs isPaused for something else entirely, narrow this check rather than deleting it"
  fi

  # …and the oracle's two halves. Zero is the value the promise is KEPT by, so
  # a counter that could only ever read zero — a broken FFI read, an engine
  # that never subscribed, a lane compiled without the receive engine — proves
  # it for free. The foreground control (`> 0`) is what makes the
  # between-bursts assertion (`== 0`) mean anything, and it is the half a
  # later edit is most likely to drop as redundant.
  grep -qF 'count > 0' <<<"$no_strings" ||
    lfail "ios_bg_publish_test.dart no longer requires a NON-ZERO pool subscription count anywhere — P2c's control arm is gone, so its 'no standing REQ between bursts' assertion would pass on an engine that never subscribed to anything, a lane compiled with HAVEN_LIVE_SYNC=false included"
  # The ordering pin anchors on the ASSERTION, never on the poll's predicate.
  # A poll is a wait; `expect(quiet.matched, ...)` is the claim the terminal
  # proof stands for, and the two are separated by several lines. Anchored on
  # the predicate, a marker moved between the poll and the assertion sits
  # after `count == 0` and passes — which is the A3b hole this pin exists to
  # close, not a narrower version of it. `quiet.matched` is the verdict field
  # of `_pollPoolSubscriptions`'s return record read off its local; renaming
  # that local is a legitimate edit that must re-point this anchor, so the
  # message says so.
  local zero_line verdict_line receive_line
  zero_line="$(code_line_of 'count == 0' <<<"$no_strings")"
  verdict_line="$(code_line_of 'quiet\.matched' <<<"$no_strings")"
  receive_line="$(code_line_of 'debugPrint\(kBackgroundReceiveMarker\)' <<<"$no_strings")"
  if [[ -z "$zero_line" ]]; then
    lfail "ios_bg_publish_test.dart no longer waits for a ZERO pool subscription count — that count reaching zero IS the background-burst promise (no standing REQ between publish ticks), and nothing else in this lane asserts it"
  fi
  if [[ -z "$verdict_line" ]]; then
    lfail "ios_bg_publish_test.dart no longer ASSERTS the between-bursts poll's verdict (quiet.matched) — a bounded poll that is never expected is a wait, not an oracle: it returns its last observation whatever that was, and BACKGROUND_RECEIVE_OK would be printed over a count that never fell to zero. If the local was merely renamed, re-point this anchor to the new name"
  fi
  if [[ -z "$receive_line" ]]; then
    lfail "ios_bg_publish_test.dart no longer prints kBackgroundReceiveMarker — the wrapper's completion gate demands it, so the lane would red with 'the drive exited 0 without its terminal proof' instead of naming the phase that went missing"
  elif [[ -n "$verdict_line" ]] && (( receive_line <= verdict_line )); then
    lfail "ios_bg_publish_test.dart prints kBackgroundReceiveMarker at line ${receive_line}, BEFORE the between-bursts assertion it stands for at line ${verdict_line} — a terminal proof printed ahead of its own assertion is the A3b hole the completion gate exists to close: the drive could return early and still satisfy the gate"
  fi

  # P2d's ORACLE — the poll leg's half, and it needs its own pins for exactly
  # the reasons P2c's does. It is the only runtime proof anywhere that the poll
  # path's background receive timer fires at all (OD4-d), it has no wire oracle
  # in this lane either, and its reading is the PERSISTED last-known store
  # rather than the in-memory member cache. That choice is load-bearing and
  # looks like an arbitrary one: `cachedLocations` re-reads the store only for a
  # circle it has not hydrated, this circle was hydrated in the foreground, and
  # the catch-up sweep writes the store directly from Rust — so a drive switched
  # to the cache would report an absence for a sweep that worked perfectly, on
  # every run. Read off the same string-stripped view, for the same reason.
  grep -qF 'snapshotLastKnownForCircle(' <<<"$no_strings" ||
    lfail "ios_bg_publish_test.dart no longer reads snapshotLastKnownForCircle — that persisted store is P2d's only oracle: on the poll leg the catch-up sweep writes it from Rust and nothing hydrates the in-memory member cache while the app is paused, so the cache would report an absence for a sweep that worked"
  local catchup_verdict_line catchup_marker_line
  catchup_verdict_line="$(code_line_of 'catchup\.fix' <<<"$no_strings")"
  catchup_marker_line="$(code_line_of 'debugPrint\(kBackgroundCatchupMarker\)' \
    <<<"$no_strings")"
  if [[ -z "$catchup_verdict_line" ]]; then
    lfail "ios_bg_publish_test.dart no longer ASSERTS the poll-path catch-up poll's verdict — _pollForStoredPeerFix RETURNS on its deadline with whatever it last read (a null fix included), so a bounded poll that is never expected is a wait, not an oracle, and BACKGROUND_CATCHUP_OK would be printed over a store the sweep never wrote. If the local was merely renamed, re-point this anchor to the new name"
  fi
  if [[ -z "$catchup_marker_line" ]]; then
    lfail "ios_bg_publish_test.dart no longer prints kBackgroundCatchupMarker — the poll leg's completion gate demands it, so that leg would red with 'the drive exited 0 without its terminal proof' instead of naming the phase that went missing"
  elif [[ -n "$catchup_verdict_line" ]] &&
       (( catchup_marker_line <= catchup_verdict_line )); then
    lfail "ios_bg_publish_test.dart prints kBackgroundCatchupMarker at line ${catchup_marker_line}, BEFORE the catch-up assertion it stands for at line ${catchup_verdict_line} — a terminal proof printed ahead of its own assertion is the A3b hole the completion gate exists to close: the drive could return early and still satisfy the gate"
  fi
  return "$_lf"
}

# check_bg_publish_timeout_ladder <ios_bg_publish_test.dart> <workflow yml> —
# the drive's own `Timeout` must stay far enough inside the lane's per-attempt
# retry deadline that it is the bound which FIRES, and the one that names the
# failing test.
#
# Both files already say "raise one and re-derive the other in the same
# commit"; until this check, nothing read either value. The failure it catches
# is silent and expensive: a drive Timeout raised to fit a new phase, with the
# retry deadline left where it was, turns every overrun into `nick-fields/retry`
# killing the attempt mid-phase — no test name, no assertion, and a second
# attempt burned on the same wall clock.
#
# ## Per LEG, paired positionally
#
# Since OD4-d the lane runs three legs over two receive planes, and the planes
# do not cost the same — so BOTH ends of the ladder are per-leg expressions:
# `Timeout(Duration(minutes: liveSyncEnabled ? 40 : 37))` in the drive,
# `timeout_minutes: ${{ matrix.live_sync == 'true' && 65 || 62 }}` in the
# workflow. This check reads every value each side declares, in source order,
# and requires the SAME COUNT and the overhead clearance on each pair. Both
# halves matter:
#
#   * checking only the first value would leave the cheaper leg's rung
#     unenforced, which is where the mistake is likeliest — a leg added with a
#     new drive Timeout and the retry deadline copied from its sibling;
#   * a count mismatch is itself the defect. One side made per-leg while the
#     other stayed scalar means one leg is running against the other leg's
#     ladder, and the arithmetic would still "pass" against whichever value
#     happened to come first.
#
# It deliberately does NOT try to match a Dart `liveSyncEnabled ?` branch to a
# YAML `matrix.live_sync ==` branch by name. Positional order is what both files
# document and what a reader compares; a name-matching parser would be a second
# expression language to maintain, and its failure mode (silently matching
# nothing) is the one this repo keeps re-learning.
#
# What positional pairing DOES require is that both conditions select legs in
# the same order, and that is checked — by one literal needle per side, not by a
# parser. Without it an inversion on either end (`matrix.live_sync != 'true'`,
# or a negated Dart condition) leaves both lists the same length with every pair
# still clearing the overhead, while each leg is bounded by the OTHER leg's
# deadline: 65-37=28 and 62-40=22 both pass, and the live-sync leg ends up
# holding the cheap leg's 37 m Timeout against its own ~38 m phase sum.
check_bg_publish_timeout_ladder() { # <ios_bg_publish_test.dart> <workflow yml>
  local drive="$1" workflow="$2"
  _lf=0
  # Fixed per-attempt cost the drive's Timeout does NOT cover, in minutes, as
  # derived in the workflow's own timeout arithmetic: the cold Xcode + pods +
  # aarch64-Rust build the wrapper performs before the drive (~15), `flutter
  # test`'s incremental rebuild (~3), install/grant/seed + launch/attach (~2)
  # and teardown (~2). Raising a drive Timeout by N minutes therefore costs
  # N minutes of that leg's retry deadline, and this is the sum that must
  # survive it. Shared by every leg: none of those four terms depends on the
  # receive plane.
  local -r overhead=22
  # Every integer inside the drive's `Timeout(Duration(minutes: …))`, in source
  # order — one on a scalar declaration, two on the `liveSyncEnabled ? A : B`
  # form. The `Timeout(` anchor is what keeps an unrelated `Duration(minutes:)`
  # elsewhere in the file out of the list.
  #
  # Each side's DECLARING LINE is kept, not just its integers: the polarity
  # check below reads the condition, and reading it off the same line the
  # arithmetic came from is what stops one of the workflow's other
  # `matrix.live_sync == 'true'` expressions (the job cap, the step cap) from
  # answering for the retry deadline's own.
  local drive_line wf_line drive_mins attempt_mins
  drive_line="$(code_view "$drive" |
    grep -F 'Timeout(Duration(minutes:' | head -n1 || true)"
  drive_mins="$(sed -n \
    's/.*Timeout(Duration(minutes:[[:space:]]*\([^)]*\)).*/\1/p' \
    <<<"$drive_line" | grep -oE '[0-9]+' || true)"
  # …and every integer in the retry step's `timeout_minutes:`, whether it is a
  # bare number or a `${{ cond && A || B }}` expression.
  wf_line="$(sed -n \
    's/^[[:space:]]*timeout_minutes:[[:space:]]*\(.*\)$/\1/p' \
    "$workflow" | head -n1 || true)"
  attempt_mins="$(grep -oE '[0-9]+' <<<"$wf_line" || true)"
  if [[ -z "$drive_mins" ]]; then
    lfail "ios_bg_publish_test.dart declares no parseable \`Timeout(Duration(minutes: N))\` — the drive would inherit flutter_test's 30 s default per test, so every phase past the first half-minute would die unattributed, and the lane's whole timeout ladder loses its innermost rung"
    return "$_lf"
  fi
  if [[ -z "$attempt_mins" ]]; then
    lfail "e2e-ios-background-publish.yml declares no parseable \`timeout_minutes:\` for its retry step — without a per-attempt deadline the retry cannot bound an attempt at all, and the drive's own Timeout has nothing to sit inside"
    return "$_lf"
  fi
  local -a DRIVE_MIN ATTEMPT_MIN
  mapfile -t DRIVE_MIN <<<"$drive_mins"
  mapfile -t ATTEMPT_MIN <<<"$attempt_mins"
  if (( ${#DRIVE_MIN[@]} != ${#ATTEMPT_MIN[@]} )); then
    lfail "the iOS background-publish timeout ladder declares ${#DRIVE_MIN[@]} drive Timeout value(s) but ${#ATTEMPT_MIN[@]} per-attempt deadline(s) (drive: ${DRIVE_MIN[*]}; retry: ${ATTEMPT_MIN[*]}). The lane's legs do not cost the same, so both ends are per-leg and are compared in source order — one side made per-leg while the other stayed scalar means a leg is running inside another leg's ladder. Give both ends one value per leg, in the same order"
    return "$_lf"
  fi
  # Equal counts is not yet a pairing. The two lists are compared in SOURCE
  # ORDER, so both conditions have to put the same leg first; nothing above
  # reads either condition, and every arithmetic pair survives an inversion.
  # One literal needle per side — the `==`/`liveSyncEnabled` is inside the
  # needle, which is what makes a negation fail to match rather than match a
  # substring of itself. Only meaningful once a side is per-leg: a ladder that
  # is scalar on both ends has no legs to order.
  if (( ${#DRIVE_MIN[@]} > 1 )); then
    grep -qF 'Timeout(Duration(minutes: liveSyncEnabled ?' <<<"$drive_line" ||
      lfail "ios_bg_publish_test.dart's per-leg drive Timeout does not key on \`liveSyncEnabled ?\` (it reads: ${drive_line#"${drive_line%%[![:space:]]*}"}). This check pairs the drive's values against the workflow's timeout_minutes values POSITIONALLY, so both ends must select legs in the same polarity — a negated or renamed condition here silently hands each leg the other leg's per-attempt deadline while every pair still clears the ${overhead}m overhead. Write it as \`liveSyncEnabled ? <live-sync leg> : <poll leg>\`, or teach this check the new condition in the same commit"
    grep -qF "live_sync == 'true' &&" <<<"$wf_line" ||
      lfail "e2e-ios-background-publish.yml's per-leg \`timeout_minutes:\` does not key on \`matrix.live_sync == 'true' &&\` (it reads: ${wf_line}). This check pairs it against the drive's Timeout values POSITIONALLY, so both ends must select legs in the same polarity — flipping this one expression to \`!=\` (or reordering its arms) leaves the counts equal and every pair clearing the ${overhead}m overhead while the live-sync leg is bounded by the poll leg's deadline. Keep the true arm first, matching the drive"
  fi
  local i
  for i in "${!DRIVE_MIN[@]}"; do
    if (( ATTEMPT_MIN[i] - DRIVE_MIN[i] < overhead )); then
      lfail "the iOS background-publish timeout ladder is inverted on leg #$(( i + 1 )): the drive's Timeout is ${DRIVE_MIN[i]}m and the retry's per-attempt deadline is ${ATTEMPT_MIN[i]}m, leaving ${ATTEMPT_MIN[i]}-${DRIVE_MIN[i]}=$(( ATTEMPT_MIN[i] - DRIVE_MIN[i] ))m for the cold build, the incremental rebuild, install/grant/launch/attach and teardown — ${overhead}m is what those cost. The attempt would be killed before the drive's own Timeout could fire, so the red would name no test. Raise that leg's timeout_minutes (and re-check its step cap against max_attempts x it), or lower its drive Timeout"
    fi
  done
  return "$_lf"
}

# check_poll_path_receive_cadence <map_shell.dart> <ios_bg_publish_test.dart> —
# the POLL path's background receive cadence must be ONE number.
#
# `MapShell._startIosBackgroundReceiveTimer` arms
# `Timer.periodic(const Duration(seconds: 90))`, and that 90 is an inline
# literal — nothing exports it, so the drive target cannot import it and
# declares `_pollPathReceiveInterval` instead. P2d's whole window is derived
# from that constant (two ticks, because a sweep whose window opened in the same
# second the peer's event was stored can miss it and only the next sweep's 60 s
# re-read recovers it), so a cadence raised in the product and not in the drive
# leaves the window covering ONE tick where the derivation needs two.
#
# That failure mode is why this is a guard and not a comment: a too-small window
# is not a red, it is a FLAKE — it still covers the ordinary case and fails only
# on the interleaving the second tick exists for. Nothing else compares the two
# numbers, and the lane cannot: it would have to hit the race to notice.
check_poll_path_receive_cadence() { # <map_shell.dart> <ios_bg_publish_test.dart>
  local shell="$1" drive="$2"
  _lf=0
  # Sliced to the method by its DECLARATION, not by its name: the name appears
  # at two call sites earlier in the file, and `fn_slice` anchors on the first
  # match — from a call site it slices whatever block follows, which is how a
  # negative assertion about this method's body ends up asserted about the pause
  # branch instead (check 6's known weakness). The declaration is unique, and
  # slicing from it also makes the foreground receive timer's own
  # `Timer.periodic(const Duration(seconds: 30))` unreachable from here.
  local body shell_secs drive_secs
  body="$(fn_slice 'void _startIosBackgroundReceiveTimer() {' "$shell")"
  if [[ -z "$body" ]]; then
    lfail "map_shell.dart has no _startIosBackgroundReceiveTimer method — that timer IS the poll path's background receive plane, and the e2e-ios-background-publish poll leg (P2d) exists to prove it fires under a real OS backgrounding. If the poll receive path was deliberately removed, remove the leg and this check in the same commit"
    return "$_lf"
  fi
  shell_secs="$(sed -n \
    's/.*Timer\.periodic([[:space:]]*const Duration(seconds:[[:space:]]*\([0-9][0-9]*\)).*/\1/p' \
    <<<"$body" | head -n1)"
  drive_secs="$(code_view "$drive" |
    sed -n 's/^const Duration _pollPathReceiveInterval = Duration(seconds:[[:space:]]*\([0-9][0-9]*\));$/\1/p' |
    head -n1)"
  if [[ -z "$shell_secs" ]]; then
    lfail "_startIosBackgroundReceiveTimer no longer arms a \`Timer.periodic(const Duration(seconds: N))\` — the poll path's background receive plane is that timer, and P2d's window in ios_bg_publish_test.dart is derived from its cadence. If the shape changed, re-derive _pollPathReceiveInterval from whatever replaced it and re-point this check"
  fi
  if [[ -z "$drive_secs" ]]; then
    lfail "ios_bg_publish_test.dart declares no \`const Duration _pollPathReceiveInterval = Duration(seconds: N);\` — P2d's catch-up window is two of those ticks, and without the constant there is nothing to compare the product's cadence against"
  fi
  if [[ -n "$shell_secs" && -n "$drive_secs" && "$shell_secs" != "$drive_secs" ]]; then
    lfail "the poll path's background receive cadence disagrees: map_shell.dart arms the timer every ${shell_secs}s, ios_bg_publish_test.dart derives P2d's window from ${drive_secs}s. A cadence longer than the drive thinks makes P2d's window span fewer ticks than its derivation needs, which is a FLAKE and not a red — it still covers the ordinary interleaving and fails only on the same-second cursor race the second tick is there for. Move both numbers together"
  fi
  # The interval is only HALF the cadence. The timer's own callback debounces on
  # `_lastLocationFetchTime`, returning early while the gap since the last
  # ACCEPTED sweep is `<=` that debounce — so a tick reaches `runCatchup` only
  # when the interval is STRICTLY greater than it. The first tick's
  # `now.difference(...)` IS the interval, so at equality the comparison holds
  # and alternate ticks are swallowed: the effective gap doubles while the
  # `Timer.periodic` literal, and check 16's comparison against the drive, both
  # still read the smaller number. Harmless at 90 > 80 today; a product cadence
  # lowered under the debounce would break P2d's two-tick derivation with this
  # guard green, and it would surface as a lane FLAKE, not a red.
  local debounce_secs
  debounce_secs="$(awk '
    /now\.difference\(_lastLocationFetchTime!\)/ { seen = 1 }
    seen && match($0, /const Duration\(seconds: *[0-9]+\)/) {
      s = substr($0, RSTART, RLENGTH)
      gsub(/[^0-9]/, "", s)
      print s
      exit
    }' <<<"$body")"
  if [[ -z "$debounce_secs" ]]; then
    lfail "_startIosBackgroundReceiveTimer's tick no longer debounces on \`now.difference(_lastLocationFetchTime!) <= const Duration(seconds: N)\` — that debounce is the second half of the poll path's effective cadence, and this check has nothing left to compare the ${shell_secs:-periodic}s interval against. If it was deliberately removed the effective gap is the interval alone and the relation is vacuous: delete this half of check 16 in the same commit rather than leaving it reading nothing"
  elif [[ -n "$shell_secs" ]] && (( shell_secs <= debounce_secs )); then
    lfail "the poll path's background receive timer ticks every ${shell_secs}s but its callback debounces anything within ${debounce_secs}s of the last accepted sweep, so the effective gap is not ${shell_secs}s: the first tick's own difference is ${shell_secs}s, the comparison is \`<=\`, and alternate ticks are swallowed — P2d derives its catch-up window from TWO ticks (the second covers the same-second cursor race) and would be getting one sweep where it needs two. That is a FLAKE, not a red: the ordinary interleaving still passes. Keep the Timer.periodic interval strictly above the debounce, and move _pollPathReceiveInterval with it"
  fi
  return "$_lf"
}

# check_poll_path_background_wake <map_shell.dart> — the poll path's background
# sweep must declare itself a BACKGROUND WAKE.
#
# `isBackgroundWake: true` is the ONLY thing that puts a `runCatchup` behind the
# C3 chokepoint, which hard-returns before any FFI or relay call once the user
# has withdrawn background-sharing consent. Everything else about the sweep is
# identical either way — `CatchupService.runCatchup`'s only use of the flag is
# that gate — so dropping the argument is a silent privacy regression: the sweep
# still works, the store still fills, P2d still goes GREEN, and a wake that
# leaked past the C4 timer cancel now reaches the relay after the opt-out.
#
# Mutation-verified: with `isBackgroundWake: true` removed from
# `_runBackgroundCatchUp`, this repo's whole suite stays green — every guard,
# `flutter analyze` (the method is still referenced, so no unused_element) and
# every host test in test/pages/ and test/services/ that names the flag, because
# all of them call `CatchupService` directly and none of them assert what
# `MapShell` passes it.
#
# The two SIBLING background-wake entry points are already pinned this way in
# check_m7_native_wake_guards.sh (checks on ios_background_catchup.dart and
# background_catchup_worker.dart); this is the third, and it was the unpinned
# one.
check_poll_path_background_wake() { # <map_shell.dart>
  local shell="$1"
  _lf=0
  # Sliced by DECLARATION for the reason check 16 is: the method's own name
  # appears at the call site inside the 90 s timer, which is EARLIER in the
  # file, and `fn_slice` anchors on the first match — from that call site it
  # would slice the timer's body and read the argument out of whatever followed.
  local body
  body="$(fn_slice 'Future<void> _runBackgroundCatchUp() async {' "$shell")"
  if [[ -z "$body" ]]; then
    lfail "map_shell.dart has no _runBackgroundCatchUp method — that is the poll path's background sweep, the one MapShell._startIosBackgroundReceiveTimer's timer drives and the one P2d of the e2e-ios-background-publish poll leg asserts. If it was renamed, re-point this check and check 16's neighbour in the same commit"
    return "$_lf"
  fi
  grep -qF 'runCatchup(isBackgroundWake: true)' <<<"$body" ||
    lfail "map_shell.dart's _runBackgroundCatchUp no longer calls runCatchup(isBackgroundWake: true) — that argument is the ONLY thing that puts this sweep behind the C3 consent chokepoint, and it is the only difference the flag makes: without it the sweep still runs, still persists and still passes P2d, while a wake that outlived the C4 timer cancel now reaches the relay after the user withdrew background sharing (Rule 10). Never pass false here, and never let the sweep reach CatchupService through a helper that drops it"
  return "$_lf"
}

# check_poll_leg_tier <workflow yml> — the poll leg's authorization tier is a
# CORRECTNESS constraint on P2d's oracle, not a sampling choice.
#
# P2d reads the PERSISTED last-known store, and the 90 s receive timer is not
# the only writer of it: `registerIosBackgroundCatchupHandler` (main.dart,
# registered regardless of `liveSyncEnabled`) reaches the same
# `persist_locations` through the same `runCatchup`, driven by the native SLC
# wake. `HavenSLCHandler.startMonitoring` arms nothing without
# `.authorizedAlways` — so `tier: when-in-use` is what makes P2d's row
# attributable to the timer at all. Flip that leg to `always`, or add an
# (always, poll) leg, and the phase still passes while proving less than its
# text claims. The lane header states this; nothing read it until here.
#
# (The other native wake, `HavenBGTaskHandler`, is not tier-gated and is
# excluded only by the Simulator's `notPermitted` — a ceiling, not something a
# guard can pin.)
check_poll_leg_tier() { # <workflow yml>
  local workflow="$1"
  _lf=0
  # Comments stripped first, so a `# … live_sync: "false"` in prose cannot read
  # as a leg. The walk stops at the first line inside `include:` that is not one
  # of the three keys, which is the `timeout-minutes:` below the matrix.
  local rows
  rows="$(sed -e 's/[[:space:]]*#.*$//' -e '/^[[:space:]]*$/d' "$workflow" |
    awk '
      /^[[:space:]]*include:[[:space:]]*$/ { inc = 1; next }
      !inc { next }
      /^[[:space:]]*-[[:space:]]*leg:[[:space:]]*/ {
        if (n) print leg "\t" tier "\t" ls
        n = 1; leg = $NF; tier = "-"; ls = "-"; next
      }
      /^[[:space:]]*tier:[[:space:]]*/ { tier = $NF; next }
      /^[[:space:]]*live_sync:[[:space:]]*/ { ls = $NF; gsub(/"/, "", ls); next }
      { if (n) { print leg "\t" tier "\t" ls; n = 0 } inc = 0 }
      END { if (n) print leg "\t" tier "\t" ls }
    ')"
  if [[ -z "$rows" ]]; then
    lfail "e2e-ios-background-publish.yml declares no parseable matrix \`include:\` legs (leg/tier/live_sync) — the lane's three legs are what make it a matrix, and this check has nothing left to read. If the matrix shape changed, re-point this check in the same commit"
    return "$_lf"
  fi
  local poll_legs
  poll_legs="$(awk -F'\t' '$3 == "false"' <<<"$rows")"
  local n_poll
  n_poll="$(grep -c . <<<"${poll_legs}" || true)"
  [[ -n "$poll_legs" ]] || n_poll=0
  if (( n_poll == 0 )); then
    lfail "e2e-ios-background-publish.yml has no leg with live_sync: \"false\" — the POLL configuration's background receive branch is then unmeasured under a real OS backgrounding anywhere in the repo, which is the gap OD4-d was closed by adding that leg. If the rollback path was retired, remove P2d and this check in the same commit"
  fi
  local leg tier ls
  while IFS=$'\t' read -r leg tier ls; do
    [[ -n "$leg" ]] || continue
    if [[ "$tier" != 'when-in-use' ]]; then
      lfail "e2e-ios-background-publish.yml's poll leg '${leg}' runs tier '${tier}', not when-in-use. P2d's oracle is the PERSISTED last-known store, and under an Always grant the native SLC wake writes that same store through the same runCatchup — so the row would no longer be attributable to _startIosBackgroundReceiveTimer and P2d would pass while proving less than its own text claims. The tier on a poll leg is a correctness constraint; give P2d a different oracle before changing it"
    fi
  done <<<"$poll_legs"
  return "$_lf"
}

# check_p3_host_wire_oracle <wrapper> <probe> <drive> <location constants> —
# P3's settle window must have an oracle that OUTLIVES the app, and the branch
# where the app dies must end on a proven verdict.
#
# The phase this guards is the only stretch of the lane where the app holds no
# execution claim — that absence IS the guarantee — so iOS may take the
# process at any point inside it, and in CI runs 35397118356 and 35622556197 it
# did. Until this check there was one oracle, it lived in the app, and when the
# app went away the wrapper said P3 was "neither proved nor disproved" and
# exited non-zero: an indeterminate result reported as a failure, i.e. a flaky
# lane by construction. The fix is a host-side wire probe plus a verdict
# function with no default-to-green, and all four of its premises are things
# only a source-shape check can hold:
#
#   * The WINDOW. Two oracles now measure one window — the drive's event-id
#     diff and the host's count — and they agree only because three numbers in
#     three files agree. A drift is silent and two-sided: a host window that
#     opened earlier would count the app's own in-flight tick as a leak, and
#     one that closed later would count the post-window foreground publish the
#     wrapper itself provokes.
#   * The PREMISE of a count. The host cannot tell Alice's kind-445 from the
#     synthetic peer's — the author is an ephemeral per-message key and the `h`
#     tag is shared — so counting ALL of them is only an answer while the peer
#     is gone. The drive disposes him before P3 for exactly that reason; move
#     that line after the disable and the host's oracle starts reporting his
#     traffic as Alice's leak.
#   * The INSTRUMENT. A probe that reads nothing answers "silent" for every
#     relay there is. So it carries TWO controls whose answers cannot be zero
#     and a range filter of its own, and the wrapper proves it on the runner
#     before depending on it — the lesson of the emulator-probe round, where a
#     fake that returned success for any argv made a broken verifier look
#     healthy. The second control is the one that tests the CLASS: a relay
#     answering kind-30443 while no longer serving kind-445 would report a
#     silent window on a lane whose own P1/P2 have already asserted that
#     kind-445s were being published seconds earlier.
#   * The EXCUSE. A host-proved P3 lets the completion gate drop the two
#     markers a reclaimed process could not print. That is the one place in
#     this lane where a green is granted over a missing proof, so its single
#     source and its exact width are pinned here.
check_p3_host_wire_oracle() { # <wrapper> <probe> <drive> <constants>
  local wrapper="$1" probe="$2" drive="$3" constants="$4"
  _lf=0
  if [[ ! -f "$probe" ]]; then
    lfail "tooling/e2e/ci/bgp-wire-probe.dart is missing — P3's settle window has no oracle that survives the app, so a run where iOS reclaims the process inside it goes back to being an unconditional red whose own message says the phase was neither proved nor disproved"
    return "$_lf"
  fi
  if [[ ! -f "$wrapper" ]]; then
    lfail "tooling/e2e/ci/run-ios-bg-publish.sh is missing — this check has nothing to read"
    return "$_lf"
  fi
  # The wrapper's own --self-test quotes these literals inside its fixtures, so
  # everything below reads the REAL RUN only: a scan over the whole file would
  # accept a wrapper whose wiring survives solely as prose about itself.
  #
  # ONE assertion is the exception, and says so where it stands: the
  # completion-gate excuse lives in `bgp_unexcused_proofs`, a function DEFINED
  # above the `# Real run` boundary, so it is read from `$wrapper_code` — the
  # whole file with its comment lines stripped, which is what keeps prose from
  # satisfying it.
  local body wrapper_code
  body="$(sed -n '/^# Real run$/,$p' "$wrapper" | grep -v '^[[:space:]]*#')"
  wrapper_code="$(grep -v '^[[:space:]]*#' "$wrapper")"
  if [[ -z "$body" ]]; then
    lfail "run-ios-bg-publish.sh no longer has a '# Real run' boundary, so this check cannot separate its real wiring from the fixtures that quote it. Restore the marker or re-point this check in the same commit"
    return "$_lf"
  fi

  # --- The one window, across three files. ----------------------------------
  local max_interval addend grace_dart window_sh grace_sh
  max_interval="$(sed -n 's/^const Duration kLocationPublishMaxInterval = Duration(seconds: \([0-9]*\));$/\1/p' "$constants")"
  addend="$(sed -n 's/^.*kLocationPublishMaxInterval + const Duration(seconds: \([0-9]*\));$/\1/p' "$drive")"
  grace_dart="$(sed -n 's/^const int _inFlightGraceSecs = \([0-9]*\);$/\1/p' "$drive")"
  window_sh="$(sed -n 's/^readonly SETTLE_WINDOW_SECS=\([0-9]*\)$/\1/p' "$wrapper")"
  grace_sh="$(sed -n 's/^readonly LEAK_GRACE_SECS=\([0-9]*\)$/\1/p' "$wrapper")"
  if [[ -z "$max_interval" || -z "$addend" || -z "$grace_dart" ||
        -z "$window_sh" || -z "$grace_sh" ]]; then
    lfail "one of P3's window terms is no longer readable (kLocationPublishMaxInterval in haven/lib/src/constants/location.dart, the drive's _negativeSettleWindow addend and _inFlightGraceSecs, the wrapper's SETTLE_WINDOW_SECS and LEAK_GRACE_SECS) — an unreadable term is not a matching one, and the two oracles would go on measuring windows nothing compares"
  else
    if (( max_interval + addend != window_sh )); then
      lfail "P3's settle window disagrees across the two oracles: the drive waits ${max_interval}+${addend}s and run-ios-bg-publish.sh's SETTLE_WINDOW_SECS says ${window_sh}. The host's wire verdict must measure the SAME window the drive's diff does — a shorter host window misses a leak the drive would catch, a longer one counts the foreground publish the host's own re-foreground provokes"
    fi
    if (( grace_dart != grace_sh )); then
      lfail "P3's in-flight grace disagrees: the drive tolerates ${grace_dart}s and run-ios-bg-publish.sh's LEAK_GRACE_SECS says ${grace_sh}. The app's last tick before the disable would then be a straggler to one oracle and a leak to the other, on a perfectly healthy run"
    fi
  fi

  # --- The premise a COUNT rests on: the peer is gone before P3 starts. ------
  local drive_code dispose_line disable_line
  drive_code="$(strip_strings <<<"$(code_view "$drive")")"
  dispose_line="$(code_line_of 'bob\.dispose\(\)' <<<"$drive_code")"
  disable_line="$(code_line_of 'setEnabled\(enabled: false\)' <<<"$drive_code")"
  if [[ -z "$dispose_line" || -z "$disable_line" ]]; then
    lfail "ios_bg_publish_test.dart no longer disposes the synthetic peer, or no longer disables background sharing where this check can see it — the host's settle-window oracle counts EVERY kind-445 in the window because only Alice can author one there, and that is true only while the peer is gone"
  elif (( dispose_line >= disable_line )); then
    lfail "ios_bg_publish_test.dart disposes the synthetic peer at line ${dispose_line}, at or AFTER the disable at line ${disable_line}. The host's wire oracle cannot tell his kind-445 from Alice's — the author is an ephemeral per-message key and the h tag is the same — so a peer still publishing inside P3's window reports as a leak and reds the lane for the app behaving correctly"
  fi

  # --- The instrument: two controls that cannot be zero, and its own range. --
  code_has 'reading.controlCount <= 0' "$probe" ||
    lfail "bgp-wire-probe.dart no longer distinguishes 'the relay answered nothing' from 'the probe could not read the relay' — without the control branch an unread relay reports as a silent window and P3 passes vacuously on exactly the runs it was added for"
  code_has 'reading.preDisableCount <= 0' "$probe" ||
    lfail "bgp-wire-probe.dart no longer requires a kind-445 from BEFORE the disable — the KeyPackage control only proves the relay answers, not that it still serves the kind the settle window is read for, so a relay that stopped serving 445 would report a silent window on a lane whose own P1/P2 just asserted that 445s were being published"
  code_has 'createdAt >= since' "$probe" ||
    lfail "bgp-wire-probe.dart no longer checks an event's created_at against the window's START — it would count the app's in-flight tick, which the in-flight grace exists to tolerate"
  code_has 'createdAt <= until' "$probe" ||
    lfail "bgp-wire-probe.dart no longer checks an event's created_at against the window's END — the wrapper re-foregrounds the app when the window closes and a foregrounded Haven publishes BY DESIGN, so the lane would red for the app behaving correctly"

  # --- The wrapper: prove the instrument, then use it, then excuse exactly
  #     the two proofs a dead process owes. --------------------------------
  grep -qF '"${DART_BIN}" "${WIRE_PROBE}" --self-test' <<<"$body" ||
    lfail "run-ios-bg-publish.sh no longer runs the wire probe's own --self-test in its preflight — the lane would depend on an instrument nothing on that runner has exercised, which is how a broken verifier looked healthy in CI run 35536892150"
  grep -qF 'if [[ -z "${DART_BIN}" ]]; then' <<<"$body" ||
    lfail "run-ios-bg-publish.sh no longer fails closed when there is no 'dart' to run the wire probe with — a missing instrument must stop the lane, never silently reduce P3 to the in-app half"
  grep -qF 'bgp_p3_host_verdict' <<<"$body" ||
    lfail "run-ios-bg-publish.sh no longer takes a host verdict on P3 — the branch where iOS reclaims the app is then back to printing a diagnosis and falling through to the drive's rc, which is an indeterminate outcome reported as a failure"
  local proven_count holds_arm
  proven_count="$(grep -cF 'P3_PROVEN_BY_HOST=1' <<<"$body" || true)"
  if [[ "$proven_count" != '1' ]]; then
    lfail "run-ios-bg-publish.sh sets P3_PROVEN_BY_HOST in ${proven_count} place(s), not exactly one. That flag excuses two terminal proofs and converts a non-zero drive rc into a green, so it may have exactly ONE source: the 'holds' verdict"
  fi
  holds_arm="$(sed -n '/^        holds)$/,/^          ;;$/p' <<<"$body" || true)"
  if ! grep -qF 'P3_PROVEN_BY_HOST=1' <<<"$holds_arm"; then
    lfail "run-ios-bg-publish.sh's P3_PROVEN_BY_HOST is not set under the 'holds' arm of the host verdict — set anywhere else it would excuse the silence and disarm proofs on a run where the wire was never read, the app came back, or the disable was never signalled"
  fi
  # The one assertion outside `$body` — see the note where `wrapper_code` is
  # built. `bgp_unexcused_proofs` is defined with the other helpers, above the
  # real-run boundary, so scoping this to the real run would make it vacuous.
  grep -qF '| grep -vFx -e "${SILENCE_MARKER}" -e "${DISARMED_MARKER}" || true' \
    <<<"$wrapper_code" ||
    lfail "run-ios-bg-publish.sh's completion-gate excuse is no longer exactly the two markers a reclaimed process cannot print (NEGATIVE_SILENCE_OK, SESSION_DISARMED). Widening it would let a drive that stopped in an EARLIER phase buy a green off P3's verdict, which says nothing about that phase"
  return "$_lf"
}

check_pbxproj_stream_handler() { # <project.pbxproj>
  local pbx="$1"
  _lf=0

  # A Swift file on disk but absent from the Xcode project compiles NOWHERE and
  # fails SILENTLY: the channel is never registered, every invoke raises
  # MissingPluginException, and the Dart source treats that as "no native
  # handler" — i.e. no position stream on iOS, discovered only when peers stop
  # receiving. The four references are the build file, the file reference, the
  # group child and the Sources build-phase entry; three of the four leave the
  # project openable and the file invisible to the compiler.
  local refs
  refs="$(grep -cF 'HavenLocationStreamHandler.swift' "$pbx" || true)"
  if [[ "$refs" != "4" ]]; then
    lfail "project.pbxproj references HavenLocationStreamHandler.swift ${refs} time(s), expected 4 (PBXBuildFile, PBXFileReference, the group child, and the Sources build phase) — anything less and the handler is not compiled, which surfaces only as MissingPluginException at runtime and reads as 'no native handler' in Dart"
  fi
  local id
  for id in 5E10CA750000000000000001 5E10CA750000000000000002; do
    grep -qF "$id" "$pbx" ||
      lfail "project.pbxproj no longer carries the ${id} object id for HavenLocationStreamHandler.swift — the fileRef/buildFile pair is what ties the source file to the Sources phase"
  done
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
# 2. ONE stream boundary PER PLATFORM: exactly one geolocator
#    `.getPositionStream(` call site (Android), exactly one `.positions(` call
#    site (iOS), and exactly one Dart file under haven/lib subscribing to the
#    native EventChannel. The per-subscription settings — the iOS background
#    intent, the Android profile — are arguments to those boundaries; a second
#    call site on either side is a second session that silently inherits or
#    tears down the first one's.
# ---------------------------------------------------------------------------
check_single_plugin_boundary "$SERVICE" "$LIB_DIR" || FAILED=1

# ---------------------------------------------------------------------------
# 3. The dead second-stream API must never reappear anywhere under haven/lib,
#    and neither may the retired geolocator iOS arm's distance sentinel:
#    `_kIosNoDistanceFilter` existed only because geolocator's
#    LocationDistanceMapper compares the boxed NSNumber pointer rather than its
#    value, so -1 reached CoreLocation as kCLDistanceFilterNone while 0 was
#    forwarded verbatim as a 0 m filter. Under Haven's own manager the property
#    is set symbolically (check 4a) and the trap is moot — its reappearance
#    means the plugin arm came back.
# ---------------------------------------------------------------------------
for sym in getBackgroundLocationStream _startBackgroundLocationStream _stopBackgroundLocationStream _backgroundLocationSub kBackgroundDistanceFilterMeters _kIosNoDistanceFilter; do
  hits="$(grep -rln --include='*.dart' -- "$sym" "$LIB_DIR" || true)"
  if [[ -n "$hits" ]]; then
    fail "banned second-stream symbol '$sym' reappeared under haven/lib: ${hits}"
  fi
done

# ---------------------------------------------------------------------------
# 4. The iOS ROUTE through the service: `_listenInner` (not `getLocationStream`
#    — `resumeStream()` re-subscribes through it and must ask for the same
#    intent) hands the toggle to the native owner unchanged, `_streamSettings`
#    is Android-only, the backgrounded cold-cache shortcut reads the NATIVE
#    lifecycle before the one-shot, last-known is the native owner's last BEST
#    fix, and the Dart and native caches clear together.
# ---------------------------------------------------------------------------
check_ios_stream_route "$SERVICE" || FAILED=1

# ---------------------------------------------------------------------------
# 4a. The native owner itself: the four session properties, exactly two
#     accuracy tiers, the background-start refusal through the SINK, one
#     `startUpdatingLocation()` site, the tier-driven indicator, the only-Best
#     cache rule and its teardown, and no logging. Nothing runs Swift unit
#     tests in CI, so this check is the whole of the proof.
# ---------------------------------------------------------------------------
check_native_stream_handler "$STREAM_HANDLER" || FAILED=1

# ---------------------------------------------------------------------------
# 4b. The Dart half of the native owner: the profile controller's anchor is a
#     THIRD full-precision copy of the last Best fix, reachable from nowhere
#     but this file. It is never emitted, so no behavioural test of the
#     publish path can see it survive a logout — only this can.
# ---------------------------------------------------------------------------
check_ios_source_third_copy "$IOS_SOURCE" || FAILED=1

# ---------------------------------------------------------------------------
# 4c. The bounded-staleness cap. A published location carries the instant of
#     the PUBLISH, never the fix time, so the confirmation chain that lets a
#     stationary device keep serving one Best anchor is also what removes the
#     ceiling on how old that anchor may be. kStationaryAnchorMaxAge is the
#     ceiling that replaces it, and it is enforced in two places for one
#     reason: the controller escalates to go and take a real fix, while the
#     service refuses to SERVE past the bound whether or not the delivery or
#     the timer that carries that escalation has run yet. Delete either half
#     and the app still publishes, still passes every test that is not about
#     the cap, and quietly serves hours-old coordinates as "just now" again.
# ---------------------------------------------------------------------------
check_stationary_anchor_cap "$IOS_SOURCE" "$SERVICE" || FAILED=1

# ---------------------------------------------------------------------------
# 5. locationStreamProvider: the rebuild is the ONLY way stream settings can
#    ever change (so it must watch the toggle and pass it through), the
#    disabled FOREGROUND rebuild must still clear the cached position, and the
#    fail-closed background-launch branch must start nothing while the running
#    foreground build must not watch the foreground state.
# ---------------------------------------------------------------------------
check_stream_provider "$PROVIDER" || FAILED=1

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

# 6b. And that watcher's OPT-OUT branch must actually withdraw the keep-alive
#     and the coordinate it produced. This is the consent-withdrawn-while-
#     paused path: no rebuild can run (frames are off), so if these four
#     calls are not here nothing else releases the CoreLocation session or the
#     engine's socket, and the cached fix survives the consent that authorised
#     it (privacy Rule 10). Nothing behavioural sees it — `MapShell` cannot be
#     pumped — so the branch is sliced structurally rather than grepped for
#     anywhere in the method, where the enabled branch's own calls would
#     satisfy the match, and the release helper's own body is read separately
#     so that a gutted one cannot pass on the strength of its call site.
check_c4_optout_release "$MAP_SHELL" || FAILED=1

# 6c. And the burst plane may be entered from the RUNNING process only.
#     `BackgroundBurstCoordinator` publishes: it takes a GPS fix and sends a
#     kind-445 per due circle. iOS's post-termination wakes (SLC, BGTask) are
#     RECEIVE-ONLY by promise — they run with no UI, often long after the user
#     last opened the app.
#
#     This is a SHAPE pin, and it is not what holds
#     INV-L-IOS-WAKES-RECEIVE-ONLY. That invariant is held by check 3, which
#     pins `getCurrentLocation`'s backgrounded branch to a block that ends in a
#     `throw` with the one-shot unreachable, over a native cache that is empty
#     after termination by construction: a relaunched process has no publish
#     input at all, whatever it manages to call. What 6c adds is the second
#     lock — that the four doors into the burst plane (construct it, implement
#     or subclass its sink, install that sink on the scheduler, open a burst on
#     the engine) stay in the three files that own them, and that no native
#     wake grows a second route into Dart.
#
#     Nothing behavioural can see any of it: CI cannot relaunch a terminated
#     app (docs/M7_BACKGROUND_SHARING.md §6 item 2b).
check_burst_plane_entry "$LIB_DIR" "$SLC_HANDLER" "$BGTASK_HANDLER" || FAILED=1

# ---------------------------------------------------------------------------
# 7. Presence-only logging in every file that HOLDS a coordinate: the location
#    service, the shell, the background provider, the iOS source, the native
#    session service — and the burst coordinator, which handles the `BurstFix`
#    carrying latitude, longitude and the publishing pubkey in one loggable
#    object.
# ---------------------------------------------------------------------------
check_presence_only_logging \
  "$SERVICE" \
  "$MAP_SHELL" \
  "$BG_PROVIDER" \
  "$IOS_SOURCE" \
  "${REPO_ROOT}/haven/lib/src/services/ios_background_session_service.dart" \
  "$BURST_COORDINATOR" || FAILED=1

# ---------------------------------------------------------------------------
# 8. Native CoreLocation session handler, tier policy included: arm() gated on
#    the persisted consent + disclosure + granted authorization (fail-closed —
#    an arm with the toggle off must DISARM); the activity session created only
#    under `wantsActivitySession` (When-In-Use OR not-yet-CONFIRMED Always, so
#    the provisional cohort keeps the keep-alive the OS's own view of their
#    authorization requires); the release of that session gated on
#    `applicationState != .background`; the diagnostics observer re-running the
#    policy rather than only setting a flag; and disarm() UNCONDITIONAL,
#    invalidating and nilling both sessions — an invalidated session can never
#    become active again, so silent reuse is a latent no-op.
# ---------------------------------------------------------------------------
check_arm_tier_policy "$SESSION_HANDLER" || FAILED=1

# ---------------------------------------------------------------------------
# 9. AppDelegate: both native handlers registered on the messenger; the session
#    handler armed SYNCHRONOUSLY in didFinishLaunching (a session held at
#    previous termination can only be retaken for a few seconds after a
#    background relaunch) and re-armed on every foreground return (covers the
#    Always-downgrade drop and a toggle-enable whose Dart arm call raced engine
#    teardown); and the two-way tier wiring assigned AFTER the session handler
#    is registered.
#
#    The ORDER is the pin, like check 12. CoreLocation fires
#    locationManagerDidChangeAuthorization at manager CREATION — which happens
#    when the AppDelegate's stored property is initialised, BEFORE this method
#    runs — so a wiring assigned earlier would have the authorization callback
#    reach arm() before the documented synchronous arm() site, and that site
#    would stop meaning what its comment says.
# ---------------------------------------------------------------------------
code_has 'backgroundSessionHandler.register(with: messenger)' "$APP_DELEGATE" ||
  fail "AppDelegate no longer registers the background-session channel"
code_has 'locationStreamHandler.register(with: messenger)' "$APP_DELEGATE" ||
  fail "AppDelegate no longer registers the location-stream channels — the EventChannel would never be served, every Dart listen would raise MissingPluginException, and iOS would have no position stream at all"
appdelegate_view="$(code_view "$APP_DELEGATE")"
session_reg_line="$(code_line_of 'backgroundSessionHandler\.register\(with:' <<<"$appdelegate_view")"
for wiring in 'locationStreamHandler\.sessionHandler *=' 'locationStreamHandler\.onAuthorizationChanged *=' 'backgroundSessionHandler\.onAlwaysConfirmedChanged *='; do
  wiring_line="$(code_line_of "$wiring" <<<"$appdelegate_view")"
  if [[ -z "$wiring_line" ]]; then
    fail "AppDelegate no longer wires '${wiring}' — the two handlers share ONE tier decision: the session handler owns alwaysConfirmed, the stream handler applies its indicator half and re-arms from its own authorization delegate. A missing wiring silently splits the policy in two"
  elif [[ -z "$session_reg_line" ]] || (( wiring_line <= session_reg_line )); then
    fail "AppDelegate assigns '${wiring}' at line ${wiring_line:-none}, not AFTER backgroundSessionHandler.register(with:) at line ${session_reg_line:-none} — the wiring must follow the registration so the authorization callback CoreLocation fires at manager creation finds nothing to call"
  fi
done
grep -qF 'applyIndicatorPolicy()' <<<"$appdelegate_view" ||
  fail "AppDelegate's onAlwaysConfirmedChanged wiring no longer calls applyIndicatorPolicy() — a confirmation would flip the tier without ever re-applying the indicator, so the pill would stay on under confirmed Always until the next start"
launch_body="$(fn_slice 'didFinishLaunchingWithOptions' "$APP_DELEGATE")"
grep -qF 'backgroundSessionHandler.arm()' <<<"$launch_body" ||
  fail "AppDelegate didFinishLaunching no longer arms the background sessions (the relaunch-retake window is only a few seconds)"
foreground_body="$(fn_slice 'applicationWillEnterForeground' "$APP_DELEGATE")"
grep -qF 'backgroundSessionHandler.arm()' <<<"$foreground_body" ||
  fail "AppDelegate applicationWillEnterForeground no longer re-arms the background sessions — it is also where arm()'s DEFERRED invalidate lands, the one an Always confirmation delivered while backgrounded had to leave undone"

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
# 11 + 12. The e2e-ios-background-publish drive target.
#
#     11 — it must never override the location service OR the iOS location
#     source. Its P2 measures publishing from INSIDE the app it backgrounds,
#     and the app's only claim to keep EXECUTING there is the live
#     CLLocationManager session the PRODUCTION path creates (checks 1/4/4a).
#     A fake at either layer removes that claim: iOS suspends the process
#     ~30 s into the background, the frozen in-process oracle counts zero, and
#     the lane reds blaming the publish pipeline — CI run 32646436116. Nothing
#     behavioural can see the difference, which is why it is pinned here.
#
#     12 — it must PUMP after enabling background sharing and require a fresh
#     fix from the rebuilt locationStreamProvider, BEFORE it signals the host
#     to background the app. Enabling the toggle only tears the foreground
#     session down synchronously (Riverpod runs the provider's onDispose
#     inside `invalidateSelf`); the rebuild that re-creates it with background
#     capability is deferred to `markNeedsBuild`, and
#     IntegrationTestWidgetsFlutterBinding's inherited `fadePointers` frame
#     policy draws no frame until the test pumps. In CI run 32661622879 that
#     rebuild landed 0.43 s AFTER SpringBoard set `visiblity is no`; locationd
#     answered `#Warning Denying process assertion`, dropped its "Location
#     subscription" assertion 2 s later, and runningboardd suspended the app —
#     while every static check here still passed. A background-capable session
#     may only be established while the app is in use, so this ordering is the
#     invariant, and only a pump-then-assert before the READY marker
#     establishes it.
#
#     …and it must read P2c's receive promise from the engine's SUBSCRIPTION
#     COUNT, never from `isPaused`. The two answer differently in precisely
#     the states P2c exists to catch: the core raises that flag as the first
#     statement of its pause, before `unsubscribe_all`, before the router
#     drain, before the uncapped Rule-13 publish gauge and before the
#     disconnect — so a drive reading the flag reports "no standing REQ"
#     through a pause that dropped none. The count's control arm (a non-zero
#     read while foregrounded) is pinned with it, because zero is the value
#     the promise is KEPT by: without the control the assertion passes on an
#     engine that never subscribed, a lane compiled with HAVEN_LIVE_SYNC=false
#     included. Every one of those reads is taken off a STRING-STRIPPED view,
#     because this drive's failure reasons quote each predicate verbatim, so a
#     scan over the comment-only view would accept an oracle that survives
#     only as prose about itself. And the terminal proof must be printed AFTER
#     the ASSERTION it stands for — `expect(quiet.matched, …)`, not the poll's
#     `count == 0` predicate several lines above it — or the completion gate
#     accepts an early return (A3b).
#
#     P2d's oracle (the poll leg, OD4-d) is pinned to the same contract one
#     plane over: the read must be the PERSISTED store, the catch-up poll's
#     verdict must be asserted, and BACKGROUND_CATCHUP_OK must be printed after
#     that assertion. The store-over-cache choice is the load-bearing one and
#     the one that looks arbitrary: on the poll leg the sweep writes the store
#     from Rust, `cachedLocations` re-reads it only for an unhydrated circle, and
#     this circle was hydrated in the foreground — so a drive switched to the
#     cache reports an absence for a sweep that worked, on every run.
# ---------------------------------------------------------------------------
check_bg_publish_drive "$BG_PUBLISH_DRIVE" || FAILED=1

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

# ---------------------------------------------------------------------------
# 14. HavenLocationStreamHandler.swift must be IN the Xcode project.
#
#     A Swift file that exists on disk but is missing from project.pbxproj is
#     compiled nowhere, and the failure is silent in the worst way: the channels
#     are never registered, every Dart invoke raises MissingPluginException, and
#     the source treats that as "no native handler". The four references are
#     counted by name (the new file's pbxproj comments all carry `.swift`; do
#     NOT generalise this counting to the BGTask precedent, whose fileRef
#     comment omits the extension).
# ---------------------------------------------------------------------------
check_pbxproj_stream_handler "$PBXPROJ" || FAILED=1

# ---------------------------------------------------------------------------
# 15. The lane's timeout LADDER, across the two files that own its ends, and
#     PER LEG since OD4-d — both ends are now expressions with one value per
#     receive plane, compared in source order, with a count mismatch treated as
#     the defect it is.
#
#     `check_e2e_step_timeout_ordering.sh` reads the workflow's own rungs
#     (inner deadline < step cap < job cap) and deliberately stops there: it
#     never opens a harness file, so the innermost rung of all — the drive
#     target's `Timeout` — is outside it. Both sides carry the same sentence
#     ("raise one and re-derive the other in the same commit") and until this
#     check nothing enforced it. An unpaired raise is silent: the retry kills
#     the attempt mid-phase, so the red names no test, and the second attempt
#     spends the same wall clock reaching the same place.
# ---------------------------------------------------------------------------
check_bg_publish_timeout_ladder "$BG_PUBLISH_DRIVE" "$BG_PUBLISH_WORKFLOW" || FAILED=1

# ---------------------------------------------------------------------------
# 16. The POLL path's background receive cadence — across the two files that
#     each hold a copy of it, AND against the debounce inside the timer's own
#     callback.
#
#     The product's number is an inline `Timer.periodic(const Duration(seconds:
#     90))` inside `_startIosBackgroundReceiveTimer`; nothing exports it, so the
#     e2e drive declares `_pollPathReceiveInterval` and derives P2d's whole
#     window from that (two ticks — the second is the same-second cursor race,
#     recoverable only by the next sweep's 60 s re-read). A cadence raised in
#     one file and not the other therefore leaves the window spanning fewer
#     ticks than its derivation needs, and the resulting failure is a FLAKE, not
#     a red: it still covers the ordinary interleaving. The lane cannot catch it
#     — it would have to hit the race to notice.
#
#     The interval alone does not describe the cadence, which is why comparing
#     the two files is not enough. The callback debounces on
#     `_lastLocationFetchTime`, returning early while the gap since the last
#     ACCEPTED sweep is `<=` 80 s, so the effective gap is the interval only
#     while the interval is STRICTLY above the debounce. Lower the product
#     cadence under it — in BOTH files, so the comparison above stays happy —
#     and alternate ticks are swallowed: P2d gets one sweep where its derivation
#     needs two, silently, and as a flake rather than a red.
# ---------------------------------------------------------------------------
check_poll_path_receive_cadence "$MAP_SHELL" "$BG_PUBLISH_DRIVE" || FAILED=1

# ---------------------------------------------------------------------------
# 17. The POLL path's background sweep must declare itself a background WAKE.
#
#     `isBackgroundWake: true` is the only difference the flag makes to
#     `CatchupService.runCatchup` — it is what puts the call behind the C3
#     chokepoint that hard-returns after a consent withdrawal. Drop it and the
#     sweep behaves identically in every observable way: P2d still goes green,
#     `flutter analyze` sees a still-referenced method, and every host test that
#     names the flag calls `CatchupService` directly rather than through
#     `MapShell`. Mutation-verified: the whole suite stays green. The two
#     sibling wake entry points are already pinned in
#     check_m7_native_wake_guards.sh; this was the unpinned third.
# ---------------------------------------------------------------------------
check_poll_path_background_wake "$MAP_SHELL" || FAILED=1

# ---------------------------------------------------------------------------
# 18. The poll leg's authorization tier, because P2d's oracle depends on it.
#
#     The persisted last-known store has a second frame-free writer: the native
#     catch-up channel handler, registered from main.dart regardless of the
#     flag, reaching the same `persist_locations`. Its SLC driver arms nothing
#     without `.authorizedAlways`, so a `when-in-use` poll leg is what keeps
#     P2d's row attributable to the receive timer. That constraint is stated in
#     the lane header and in the drive; this is what reads it.
# ---------------------------------------------------------------------------
check_poll_leg_tier "$BG_PUBLISH_WORKFLOW" || FAILED=1

# ---------------------------------------------------------------------------
# 19. P3's settle window must have an oracle that OUTLIVES the app.
#
#     The disable is what removes the app's claim to execute in the
#     background, so from that instant iOS owns the process — and twice now it
#     has taken it mid-window (CI runs 35397118356, 35622556197; the second
#     one's sim-lifecycle.log names runningboardd, an expired FinishTask
#     assertion and OS_REASON_RUNNINGBOARD, with no jetsam, crash or
#     watchdog). A healthy product therefore REACHES that outcome, and the
#     lane must end there on a proven verdict rather than on "neither proved
#     nor disproved". What makes the host's answer trustworthy is four source
#     facts nothing behavioural can see: the two oracles measure one window,
#     the synthetic peer is gone before the count begins, the probe carries a
#     control and its own range, and the completion gate's single excuse has
#     exactly two markers in it.
# ---------------------------------------------------------------------------
check_p3_host_wire_oracle "$BG_PUBLISH_WRAPPER" "$BG_PUBLISH_PROBE" \
  "$BG_PUBLISH_DRIVE" "$LOCATION_CONSTANTS" || FAILED=1

fi

# ---------------------------------------------------------------------------
# --self-test: hermetic fixtures for the checks that are function-shaped.
#
# Every one pins an invariant nothing behavioural can see. The two Swift
# handlers are the extreme case: NO Swift unit test runs in this CI at all, so
# their session shape, accuracy tiers, error contract, only-Best cache rule and
# tier policy show up only as "iOS suspended the app" or "the pill never went
# away", hours later and off-device. The number of stream call sites is
# invisible to `flutter test` by construction, because a mocked boundary
# honours the settings of EVERY call while the real plugin returns its cached
# stream and drops them; the C4 opt-out branch runs only while the process is
# PAUSED, and `MapShell` cannot be pumped at all (CLAUDE.md); the relaunch
# region only ever fires after a REAL termination, which no CI can stage
# (docs/M7_BACKGROUND_SHARING.md §6 item 2b); the burst plane's four entry
# doors are a source-shape question by nature, since the wake that would abuse
# one only exists after that same unstageable termination; and a Swift file
# missing from project.pbxproj surfaces as a MissingPluginException the Dart
# source reads as "no native handler". A guard that could rot unnoticed here
# would take the invariant with it, so every mutation below is an edit that
# leaves the file compiling and reading correctly, plus the anti-vacuity
# direction (a missing anchor is a failure, never a pass) and — the case a
# reviewer proved on the Android side — a GUTTED function body, which compiles,
# lints clean and leaves every other guard green.
#
# The count is pinned by EQUALITY, not a floor: a floor lets a deleted fixture
# hide under the slack.
# ---------------------------------------------------------------------------
self_test() {
  local -r SELF_TEST_FIXTURES=209
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

  # --- check_single_plugin_boundary -----------------------------------------
  #
  # The counts ARE the check, so both directions of "wrong count" get a
  # fixture on both platforms: two call sites (a second session that inherits
  # or tears down the first one's) and zero (a service that subscribes to
  # nothing — which every behavioural test reads as "the platform delivered
  # nothing"). The EventChannel owner is counted the same way, because a
  # second `receiveBroadcastStream(` is a second native listen under another
  # name and no `.positions(` count would see it.
  local boundary_wrapper='class DefaultGeolocatorWrapper implements GeolocatorWrapper {
  @override
  Stream<geo.Position> getPositionStream({
    required geo.LocationSettings locationSettings,
  }) {
    return geo.Geolocator.getPositionStream(locationSettings: locationSettings);
  }
}'
  local boundary_listen='  void _listenInner(StreamController<Position> outer) {
    final backgroundSharingEnabled = _streamBackgroundSharing;
    final source = _isIOS
        ? _iosSource.positions(
            allowsBackgroundLocationUpdates: backgroundSharingEnabled,
          )
        : _geolocator
              .getPositionStream(
                locationSettings: _streamSettings(profile: _streamProfile),
              )
              .map(_convertPosition);
    _inner = source.listen((position) => outer.add(position));
  }'
  local boundary_source='class MethodChannelIosLocationSource implements IosLocationSource {
  @override
  Stream<Position> positions({required bool allowsBackgroundLocationUpdates}) {
    return eventChannel
        .receiveBroadcastStream(<String, Object?>{
          "allowsBackgroundLocationUpdates": allowsBackgroundLocationUpdates,
        })
        .map(_convert);
  }
}'

  _boundary() { # <label> <want-rc> <service body>
    local got=0
    mkdir -p "${tmp}/lib"
    rm -f "${tmp}/lib/"*.dart
    printf '%s\n\nclass GeolocatorLocationService {\n%s\n}\n' \
      "${boundary_wrapper}" "$3" >"${tmp}/lib/service.dart"
    printf '%s\n' "${boundary_source}" >"${tmp}/lib/ios_location_source.dart"
    ( check_single_plugin_boundary "${tmp}/lib/service.dart" "${tmp}/lib" ) >/dev/null 2>&1 || got=$?
    _record "$1" "$2" "${got}"
  }

  _boundary 'boundary: one call site per platform beside the wrapper delegate passes' 0 \
    "${boundary_listen}"
  _boundary 'boundary: a second geolocator stream call site' 1 \
    "${boundary_listen}

  Stream<Position> getBackgroundStream() {
    return _geolocator
        .getPositionStream(locationSettings: _backgroundSettings())
        .map(_convertPosition);
  }"
  # Comment-awareness, in the direction that must PASS: a superseded call site
  # left in prose is not a second subscription.
  _boundary 'boundary: a second call site that is only a comment' 0 \
    "${boundary_listen}

  // Was: _geolocator.getPositionStream(locationSettings: old).listen(...)"
  # Anti-vacuity: zero is not "no violation". A service that subscribes to
  # nothing produces no fix, and every behavioural test reads that as a quiet
  # platform.
  _boundary 'boundary: the only geolocator call site commented out' 1 \
    "  void _listenInner(StreamController<Position> outer) {
    // _inner = _geolocator.getPositionStream(locationSettings: s).listen(...);
    _inner = _iosSource.positions(allowsBackgroundLocationUpdates: true).listen(_add);
  }"
  # The iOS half of both directions. A second `.positions(` is a second listen
  # on the ONE native EventChannel: the handler hands the new sink over and its
  # `onCancel` stops the manager the first subscriber is still reading.
  _boundary 'boundary: a second .positions( call site' 1 \
    "${boundary_listen}

  Stream<Position> getBackgroundStream() {
    return _iosSource.positions(allowsBackgroundLocationUpdates: true);
  }"
  _boundary 'boundary: the only .positions( call site commented out' 1 \
    "  void _listenInner(StreamController<Position> outer) {
    // _inner = _iosSource.positions(allowsBackgroundLocationUpdates: true);
    _inner = _geolocator
        .getPositionStream(locationSettings: _streamSettings(profile: _streamProfile))
        .listen(_add);
  }"

  _boundary_files() { # <label> <want-rc> <name> <body> [<name2> <body2>]
    local got=0
    mkdir -p "${tmp}/lib"
    rm -f "${tmp}/lib/"*.dart
    printf '%s\n\nclass GeolocatorLocationService {\n%s\n}\n' \
      "${boundary_wrapper}" "${boundary_listen}" >"${tmp}/lib/service.dart"
    [[ -n "$4" ]] && printf '%s\n' "$4" >"${tmp}/lib/$3"
    [[ -n "${6:-}" ]] && printf '%s\n' "$6" >"${tmp}/lib/$5"
    ( check_single_plugin_boundary "${tmp}/lib/service.dart" "${tmp}/lib" ) >/dev/null 2>&1 || got=$?
    _record "$1" "$2" "${got}"
  }

  _boundary_files 'boundary: a SECOND file subscribes to the native EventChannel' 1 \
    'ios_location_source.dart' "${boundary_source}" \
    'legacy_ios_source.dart' 'class LegacyIosSource {
  Stream<Object?> raw() => const EventChannel("x").receiveBroadcastStream();
}'
  # Anti-vacuity: nobody subscribing to the native channel is not "clean" —
  # it is an iOS build with no position stream at all.
  _boundary_files 'boundary: no file subscribes to the native EventChannel' 1 \
    'ios_location_source.dart' 'class MethodChannelIosLocationSource {}'
  # And the owner must be the class that carries the only-Best rule and the
  # sink error contract, not some other file that happens to subscribe.
  _boundary_files 'boundary: the native subscriber moved to another file' 1 \
    'map_page.dart' "${boundary_source}"

  # --- check_ios_stream_route -----------------------------------------------
  #
  # The Dart half of what used to be `check_stream_settings`. Every assertion
  # here replaces a retired AppleSettings pin (see the header): the toggle now
  # reaches CoreLocation through `positions(allowsBackgroundLocationUpdates:)`
  # instead of through `allowBackgroundLocationUpdates:`, and the shortcut and
  # the two caches are the F4 route the native owner made necessary.
  local route_listen='  void _listenInner(StreamController<Position> outer) {
    final backgroundSharingEnabled = _streamBackgroundSharing;
    final source = _isIOS
        ? _iosSource.positions(
            allowsBackgroundLocationUpdates: backgroundSharingEnabled,
          )
        : _geolocator
              .getPositionStream(
                locationSettings: _streamSettings(profile: _streamProfile),
              )
              .map(_convertPosition);
    _inner = source.listen((position) => outer.add(position));
  }'
  local route_settings='  geo.LocationSettings _streamSettings({
    required AndroidStreamProfile profile,
  }) {
    return geo.AndroidSettings(distanceFilter: 1, forceLocationManager: true);
  }'
  local route_current='  Future<Position> getCurrentLocation() async {
    final granted = await _ensureAccessOrThrow();
    if (granted) {
      final cached = _lastStreamPosition;
      if (cached != null && _streamFixIsFresh(cached, DateTime.now())) {
        return cached;
      }
      if (_isIOS && (await _iosSource.status()).backgrounded) {
        final lastPosition = await _getLastKnownPosition();
        if (lastPosition != null) return lastPosition;
        throw LocationServiceException("unavailable in the background");
      }
    }
    final geoPosition = await _geolocator.getCurrentPosition(
      locationSettings: _currentPositionSettings(),
    );
    return _convertPosition(geoPosition);
  }'
  local route_lastknown='  Future<Position?> _getLastKnownPosition() async {
    if (_isIOS) {
      final fix = await _iosSource.lastBestFix();
      if (fix == null || !_streamFixIsFresh(fix, DateTime.now())) return null;
      return fix;
    }
    final position = await _geolocator.getLastKnownPosition();
    return position == null ? null : _convertPosition(position);
  }'
  local route_clear='  void clearCachedPosition() {
    _lastStreamPosition = null;
    unawaited(_iosSource.clearLastBestFix());
  }'

  _route() { # <label> <want-rc> <listen> <settings> <getCurrentLocation> <lastKnown> <clear>
    local got=0
    printf 'class GeolocatorLocationService {\n%s\n%s\n%s\n%s\n%s\n}\n' \
      "$3" "$4" "$5" "$6" "$7" >"${tmp}/service.dart"
    ( check_ios_stream_route "${tmp}/service.dart" ) >/dev/null 2>&1 || got=$?
    _record "$1" "$2" "${got}"
  }

  _route 'route: today'"'"'s tree passes' 0 \
    "${route_listen}" "${route_settings}" "${route_current}" "${route_lastknown}" "${route_clear}"
  # R8: the background capability must stay a pure function of the toggle. A
  # literal `true` hands an OS keep-alive to a user who declined background
  # sharing; a literal `false` silently drops it for one who did not.
  _route 'route: allowsBackgroundLocationUpdates hardcoded true' 1 \
    '  void _listenInner(StreamController<Position> outer) {
    final backgroundSharingEnabled = _streamBackgroundSharing;
    final source = _isIOS
        ? _iosSource.positions(allowsBackgroundLocationUpdates: true)
        : _geolocator.getPositionStream(locationSettings: _streamSettings(profile: _streamProfile));
    _inner = source.listen((position) => outer.add(position));
  }' "${route_settings}" "${route_current}" "${route_lastknown}" "${route_clear}"
  # The escape a `positions(` grep alone would miss: the argument is still a
  # variable, but the variable is not the stored intent, so every resumeStream()
  # after a pause re-subscribes WITHOUT background capability.
  _route 'route: the intent no longer comes from _streamBackgroundSharing' 1 \
    '  void _listenInner(StreamController<Position> outer) {
    const backgroundSharingEnabled = false;
    final source = _isIOS
        ? _iosSource.positions(
            allowsBackgroundLocationUpdates: backgroundSharingEnabled,
          )
        : _geolocator.getPositionStream(locationSettings: _streamSettings(profile: _streamProfile));
    _inner = source.listen((position) => outer.add(position));
  }' "${route_settings}" "${route_current}" "${route_lastknown}" "${route_clear}"
  _route 'route: geo.AppleSettings back in _streamSettings' 1 \
    "${route_listen}" '  geo.LocationSettings _streamSettings({
    required AndroidStreamProfile profile,
  }) {
    if (_isIOS) {
      return geo.AppleSettings(distanceFilter: 1, pauseLocationUpdatesAutomatically: false);
    }
    return geo.AndroidSettings(distanceFilter: 1, forceLocationManager: true);
  }' "${route_current}" "${route_lastknown}" "${route_clear}"
  # The F4 route, both halves. A Dart-side lifecycle flag reads "foregrounded"
  # in a background-LAUNCHED process (no lifecycle callback has run), so the
  # shortcut is skipped and a one-shot is started that can never complete.
  _route 'route: the shortcut reads _foregroundActive again' 1 \
    "${route_listen}" "${route_settings}" '  Future<Position> getCurrentLocation() async {
    final granted = await _ensureAccessOrThrow();
    if (granted && _isIOS && !_foregroundActive) {
      final lastPosition = await _getLastKnownPosition();
      if (lastPosition != null) {
        return lastPosition;
      }
    }
    final geoPosition = await _geolocator.getCurrentPosition(
      locationSettings: _currentPositionSettings(),
    );
    return _convertPosition(geoPosition);
  }' "${route_lastknown}" "${route_clear}"
  _route 'route: the one-shot runs before the backgrounded last-known shortcut' 1 \
    "${route_listen}" "${route_settings}" '  Future<Position> getCurrentLocation() async {
    final granted = await _ensureAccessOrThrow();
    try {
      final geoPosition = await _geolocator.getCurrentPosition(
        locationSettings: _currentPositionSettings(),
      );
      return _convertPosition(geoPosition);
    } on Exception {
      if (granted && _isIOS && (await _iosSource.status()).backgrounded) {
        final lastPosition = await _getLastKnownPosition();
        if (lastPosition != null) {
          return lastPosition;
        }
      }
      rethrow;
    }
  }' "${route_lastknown}" "${route_clear}"
  # The structural half of the same rule. Line order is satisfied by BOTH of
  # these and they are the shape the invariant forbids: with no cached fix —
  # the state a post-termination relaunch is in by design — control reaches a
  # one-shot the relaunched process may not have.
  _route 'route: the backgrounded branch falls through to the one-shot' 1 \
    "${route_listen}" "${route_settings}" '  Future<Position> getCurrentLocation() async {
    final granted = await _ensureAccessOrThrow();
    if (granted) {
      final cached = _lastStreamPosition;
      if (cached != null && _streamFixIsFresh(cached, DateTime.now())) {
        return cached;
      }
      if (_isIOS && (await _iosSource.status()).backgrounded) {
        final lastPosition = await _getLastKnownPosition();
        if (lastPosition != null) {
          return lastPosition;
        }
      }
    }
    final geoPosition = await _geolocator.getCurrentPosition(
      locationSettings: _currentPositionSettings(),
    );
    return _convertPosition(geoPosition);
  }' "${route_lastknown}" "${route_clear}"
  # The escape a "does it throw anywhere?" grep would miss: the refusal is
  # there, but nested, so the no-cached-fix path still falls out of the branch.
  _route 'route: the refusal nested inside an inner branch' 1 \
    "${route_listen}" "${route_settings}" '  Future<Position> getCurrentLocation() async {
    final granted = await _ensureAccessOrThrow();
    if (granted) {
      if (_isIOS && (await _iosSource.status()).backgrounded) {
        final lastPosition = await _getLastKnownPosition();
        if (lastPosition == null && _neverTrue) {
          throw LocationServiceException("unavailable in the background");
        }
        if (lastPosition != null) return lastPosition;
      }
    }
    final geoPosition = await _geolocator.getCurrentPosition(
      locationSettings: _currentPositionSettings(),
    );
    return _convertPosition(geoPosition);
  }' "${route_lastknown}" "${route_clear}"
  # And the other way the branch reaches the plugin: moving the one-shot INTO
  # it keeps every line-order pin green.
  _route 'route: the one-shot moved inside the backgrounded branch' 1 \
    "${route_listen}" "${route_settings}" '  Future<Position> getCurrentLocation() async {
    final granted = await _ensureAccessOrThrow();
    if (granted) {
      if (_isIOS && (await _iosSource.status()).backgrounded) {
        final lastPosition = await _getLastKnownPosition();
        if (lastPosition != null) return lastPosition;
        final fallback = await _geolocator.getCurrentPosition(
          locationSettings: _currentPositionSettings(),
        );
        throw LocationServiceException(_convertPosition(fallback).toString());
      }
    }
    final geoPosition = await _geolocator.getCurrentPosition(
      locationSettings: _currentPositionSettings(),
    );
    return _convertPosition(geoPosition);
  }' "${route_lastknown}" "${route_clear}"
  # The plugin manager is never STARTED under the native owner, so its
  # `.location` is undefined — and it carries no only-Best guarantee.
  _route 'route: last-known falls back to the plugin on iOS' 1 \
    "${route_listen}" "${route_settings}" "${route_current}" \
    '  Future<Position?> _getLastKnownPosition() async {
    final position = await _geolocator.getLastKnownPosition();
    return position == null ? null : _convertPosition(position);
  }' "${route_clear}"
  _route 'route: the native cache clear deleted' 1 \
    "${route_listen}" "${route_settings}" "${route_current}" "${route_lastknown}" \
    '  void clearCachedPosition() {
    _lastStreamPosition = null;
  }'
  # Anti-vacuity: prose that names every token is not code.
  _route 'route: the whole routing site commented out' 1 \
    '  // void _listenInner(StreamController<Position> outer) {
  //   final backgroundSharingEnabled = _streamBackgroundSharing;
  //   _iosSource.positions(allowsBackgroundLocationUpdates: backgroundSharingEnabled);
  // }' "${route_settings}" "${route_current}" "${route_lastknown}" "${route_clear}"

  # --- check_ios_source_third_copy ------------------------------------------
  #
  # The controller's anchor is never emitted and never returned, so nothing
  # behavioural can see it survive a logout: every publish-path assertion reads
  # one of the OTHER two copies. This check is its only proof.
  local src_clear='  @override
  Future<void> clearLastBestFix() {
    _controller.forgetAnchor(clock.now());
    _applyProfile();
    return _invoke('"'"'clearLastBestFix'"'"');
  }'
  local src_forget='  void forgetAnchor(DateTime now) {
    _anchor = null;
    _profile = IosLocationProfile.best;
    _movedAt = now;
    _confirmedAt = null;
  }'

  _iossrc() { # <label> <want-rc> <clearLastBestFix> <forgetAnchor>
    local got=0
    printf 'class IosProfileController {\n%s\n}\n\nclass MethodChannelIosLocationSource {\n%s\n}\n' \
      "${4:-$src_forget}" "${3:-$src_clear}" >"${tmp}/ios_location_source.dart"
    ( check_ios_source_third_copy "${tmp}/ios_location_source.dart" ) >/dev/null 2>&1 || got=$?
    _record "$1" "$2" "${got}"
  }

  _iossrc 'third copy: today'"'"'s source passes' 0 '' ''
  _iossrc 'third copy: the clear no longer drops the anchor' 1 \
    '  @override
  Future<void> clearLastBestFix() => _invoke('"'"'clearLastBestFix'"'"');' ''
  _iossrc 'third copy: the anchor is dropped but the native copy is not' 1 \
    '  @override
  Future<void> clearLastBestFix() {
    _controller.forgetAnchor(clock.now());
    _applyProfile();
    return Future<void>.value();
  }' ''
  # The mutation that reads correctly: forgetAnchor resets the bookkeeping the
  # session can see and leaves the coordinate itself in memory.
  _iossrc 'third copy: forgetAnchor keeps the anchor' 1 '' \
    '  void forgetAnchor(DateTime now) {
    _profile = IosLocationProfile.best;
    _movedAt = now;
    _confirmedAt = null;
  }'
  # An anchorless coarse tier decides nothing: it can neither confirm stillness
  # nor measure a displacement, so it would sit there until the app is opened.
  _iossrc 'third copy: forgetAnchor leaves the session at the coarse tier' 1 '' \
    '  void forgetAnchor(DateTime now) {
    _anchor = null;
    _movedAt = now;
    _confirmedAt = null;
  }'
  # Anti-vacuity: prose naming every token is not code.
  _iossrc 'third copy: the clear commented out' 1 \
    '  // Future<void> clearLastBestFix() {
  //   _controller.forgetAnchor(clock.now());
  //   return _invoke('"'"'clearLastBestFix'"'"');
  // }' ''

  # --- check_stationary_anchor_cap ------------------------------------------
  #
  # The cap is the only bound on how old a PUBLISHED coordinate may be, and
  # every mutation below leaves an app that still publishes on time: what
  # changes is the age of what it publishes, which the wire cannot carry and
  # no peer can measure. Both halves are fixtured, because either one alone is
  # a bound that holds only when a timer happened to fire first.
  local cap_coarse='  void _onCoarseProfileFix(IosFix fix) {
    if (fix.accuracy > kStationaryConfirmMaxAccuracyMeters) return;
    final anchor = _anchor;
    if (anchor == null) return;
    if (_distance(anchor, fix) >= kMotionTriggerDistanceMeters) {
      _profile = IosLocationProfile.best;
      _movedAt = fix.timestamp;
      _confirmedAt = null;
      return;
    }
    if (fix.timestamp.difference(anchor.timestamp) > kStationaryAnchorMaxAge) {
      _profile = IosLocationProfile.best;
      _confirmedAt = null;
      return;
    }
    _confirmedAt = fix.timestamp;
  }'
  local cap_deadline='  Duration? nextDeadline(DateTime now) {
    final confirmedAt = _confirmedAt;
    final anchor = _anchor;
    if (_profile != IosLocationProfile.hundredMeters ||
        confirmedAt == null ||
        anchor == null) {
      return null;
    }
    final unconfirmed = kStationaryConfirmMaxAge - now.difference(confirmedAt);
    final anchorLeft =
        kStationaryAnchorMaxAge - now.difference(anchor.timestamp);
    final remaining = unconfirmed < anchorLeft ? unconfirmed : anchorLeft;
    return remaining.isNegative ? Duration.zero : remaining;
  }'
  local cap_fresh='  bool _streamFixIsFresh(Position fix, DateTime now) =>
      now.difference(_lastFixConfirmedAt ?? fix.timestamp) <=
          kStreamPositionMaxAge &&
      now.difference(fix.timestamp) <= kStationaryAnchorMaxAge;'

  _cap() { # <label> <want-rc> <_onCoarseProfileFix> <nextDeadline> <_streamFixIsFresh>
    local got=0
    printf 'class IosProfileController {\n%s\n\n%s\n}\n' \
      "${3:-$cap_coarse}" "${4:-$cap_deadline}" >"${tmp}/ios_location_source.dart"
    printf 'class GeolocatorLocationService {\n%s\n}\n' \
      "${5:-$cap_fresh}" >"${tmp}/service.dart"
    ( check_stationary_anchor_cap "${tmp}/ios_location_source.dart" \
        "${tmp}/service.dart" ) >/dev/null 2>&1 || got=$?
    _record "$1" "$2" "${got}"
  }

  _cap 'cap: today'"'"'s shape passes' 0 '' '' ''
  # The mutation the review found: with the expiry gone, a stationary device
  # re-publishes one anchor for as long as coarse fixes keep confirming it.
  _cap 'cap: the expired-anchor branch removed' 1 \
    '  void _onCoarseProfileFix(IosFix fix) {
    if (fix.accuracy > kStationaryConfirmMaxAccuracyMeters) return;
    final anchor = _anchor;
    if (anchor == null) return;
    if (_distance(anchor, fix) >= kMotionTriggerDistanceMeters) {
      _profile = IosLocationProfile.best;
      _movedAt = fix.timestamp;
      _confirmedAt = null;
      return;
    }
    _confirmedAt = fix.timestamp;
  }' '' ''
  # Reads correctly, caps nothing: every coarse fix refreshes the confirmation,
  # so a bound measured from it is a bound that is never reached.
  _cap 'cap: measured from the confirmation instead of the anchor' 1 \
    '  void _onCoarseProfileFix(IosFix fix) {
    if (fix.accuracy > kStationaryConfirmMaxAccuracyMeters) return;
    final anchor = _anchor;
    final confirmedAt = _confirmedAt;
    if (anchor == null || confirmedAt == null) return;
    if (_distance(anchor, fix) >= kMotionTriggerDistanceMeters) {
      _profile = IosLocationProfile.best;
      _movedAt = fix.timestamp;
      _confirmedAt = null;
      return;
    }
    if (fix.timestamp.difference(confirmedAt) > kStationaryAnchorMaxAge) {
      _profile = IosLocationProfile.best;
      _confirmedAt = null;
      return;
    }
    _confirmedAt = fix.timestamp;
  }' '' ''
  # Stops confirming, but stays at the coarse tier: the session then decides
  # nothing until the confirm deadline, and the fresh fix the cap exists to go
  # and take is never requested.
  _cap 'cap: the expired-anchor branch stops escalating' 1 \
    '  void _onCoarseProfileFix(IosFix fix) {
    if (fix.accuracy > kStationaryConfirmMaxAccuracyMeters) return;
    final anchor = _anchor;
    if (anchor == null) return;
    if (_distance(anchor, fix) >= kMotionTriggerDistanceMeters) {
      _profile = IosLocationProfile.best;
      _movedAt = fix.timestamp;
      _confirmedAt = null;
      return;
    }
    if (fix.timestamp.difference(anchor.timestamp) > kStationaryAnchorMaxAge) {
      _confirmedAt = null;
      return;
    }
    _confirmedAt = fix.timestamp;
  }' '' ''
  # Escalates, but leaves the stale confirmation standing — and the
  # confirmation is precisely what lets the publish path serve the anchor past
  # its own timestamp.
  _cap 'cap: the expired-anchor branch keeps the confirmation' 1 \
    '  void _onCoarseProfileFix(IosFix fix) {
    if (fix.accuracy > kStationaryConfirmMaxAccuracyMeters) return;
    final anchor = _anchor;
    if (anchor == null) return;
    if (_distance(anchor, fix) >= kMotionTriggerDistanceMeters) {
      _profile = IosLocationProfile.best;
      _movedAt = fix.timestamp;
      _confirmedAt = null;
      return;
    }
    if (fix.timestamp.difference(anchor.timestamp) > kStationaryAnchorMaxAge) {
      _profile = IosLocationProfile.best;
      return;
    }
    _confirmedAt = fix.timestamp;
  }' '' ''
  _cap 'cap: nextDeadline drops the anchor bound' 1 '' \
    '  Duration? nextDeadline(DateTime now) {
    final confirmedAt = _confirmedAt;
    if (_profile != IosLocationProfile.hundredMeters || confirmedAt == null) {
      return null;
    }
    final remaining = kStationaryConfirmMaxAge - now.difference(confirmedAt);
    return remaining.isNegative ? Duration.zero : remaining;
  }' ''
  # Both constants present, one of them dead: the timer is still armed on the
  # deadline that a confirming fix re-arms for ever.
  _cap 'cap: nextDeadline computes the anchor bound and ignores it' 1 '' \
    '  Duration? nextDeadline(DateTime now) {
    final confirmedAt = _confirmedAt;
    final anchor = _anchor;
    if (_profile != IosLocationProfile.hundredMeters ||
        confirmedAt == null ||
        anchor == null) {
      return null;
    }
    final unconfirmed = kStationaryConfirmMaxAge - now.difference(confirmedAt);
    final anchorLeft =
        kStationaryAnchorMaxAge - now.difference(anchor.timestamp);
    final remaining = unconfirmed;
    return remaining.isNegative ? Duration.zero : remaining;
  }' ''
  _cap 'cap: the serving bound loses the cap clause' 1 '' '' \
    '  bool _streamFixIsFresh(Position fix, DateTime now) =>
      now.difference(_lastFixConfirmedAt ?? fix.timestamp) <=
      kStreamPositionMaxAge;'
  # The confirmation is refreshed by every coarse fix, so capping ITS age caps
  # nothing at all — and the expression reads exactly like the real rule.
  _cap 'cap: the serving bound caps the confirmation age instead' 1 '' '' \
    '  bool _streamFixIsFresh(Position fix, DateTime now) =>
      now.difference(_lastFixConfirmedAt ?? fix.timestamp) <=
          kStreamPositionMaxAge &&
      now.difference(_lastFixConfirmedAt ?? fix.timestamp) <=
          kStationaryAnchorMaxAge;'
  # Anti-vacuity: prose naming every token is not code.
  _cap 'cap: the expiry branch left in a comment' 1 \
    '  void _onCoarseProfileFix(IosFix fix) {
    if (fix.accuracy > kStationaryConfirmMaxAccuracyMeters) return;
    final anchor = _anchor;
    if (anchor == null) return;
    if (_distance(anchor, fix) >= kMotionTriggerDistanceMeters) {
      _profile = IosLocationProfile.best;
      _movedAt = fix.timestamp;
      _confirmedAt = null;
      return;
    }
    // if (fix.timestamp.difference(anchor.timestamp) > kStationaryAnchorMaxAge) {
    //   _profile = IosLocationProfile.best;
    //   _confirmedAt = null;
    //   return;
    // }
    _confirmedAt = fix.timestamp;
  }' '' ''

  # --- check_native_stream_handler ------------------------------------------
  #
  # Nothing runs Swift unit tests in CI, so every property of Haven's own
  # CLLocationManager is pinned by this check ALONE — and every mutation below
  # leaves the file compiling and reading correctly. Four of them are the
  # AppleSettings pins this guard used to carry on the Dart side, re-expressed
  # where the behaviour now lives.
  local swift_head='final class HavenLocationStreamHandler: NSObject, CLLocationManagerDelegate, FlutterStreamHandler {
  private static let profileBest = "best"
  private static let profileHundredMeters = "hundredMeters"
  weak var sessionHandler: HavenBackgroundSessionHandler?
  private let manager = CLLocationManager()
  private var sink: FlutterEventSink?
  private var bestSince = Date.distantFuture
  private var lastBestFix: CLLocation?'
  local swift_init='  override init() {
    super.init()
    manager.delegate = self
    manager.pausesLocationUpdatesAutomatically = false
    manager.distanceFilter = kCLDistanceFilterNone
    manager.activityType = .other
    manager.desiredAccuracy = kCLLocationAccuracyBest
  }'
  local swift_onlisten='  func onListen(
    withArguments arguments: Any?,
    eventSink events: @escaping FlutterEventSink
  ) -> FlutterError? {
    guard sink == nil else { return nil }
    let args = arguments as? [String: Any] ?? [:]
    let allowsBg = args["allowsBackgroundLocationUpdates"] as? Bool ?? false
    if allowsBg && UIApplication.shared.applicationState == .background {
      events(FlutterError(code: "background_start_refused", message: nil, details: nil))
      events(FlutterEndOfEventStream)
      return nil
    }
    sink = events
    manager.allowsBackgroundLocationUpdates = allowsBg
    applyIndicatorPolicy()
    bestSince = Date()
    manager.desiredAccuracy = kCLLocationAccuracyBest
    manager.startUpdatingLocation()
    return nil
  }'
  local swift_oncancel='  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    manager.stopUpdatingLocation()
    manager.allowsBackgroundLocationUpdates = false
    lastBestFix = nil
    sink = nil
    return nil
  }'
  local swift_profile='  private func setProfile(_ name: String) -> Bool {
    switch name {
    case Self.profileBest:
      bestSince = Date()
      manager.desiredAccuracy = kCLLocationAccuracyBest
    case Self.profileHundredMeters:
      manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    default:
      return false
    }
    return true
  }'
  local swift_didupdate='  func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
    guard let events = sink else { return }
    for loc in locations {
      if manager.desiredAccuracy == kCLLocationAccuracyBest && loc.timestamp >= bestSince {
        lastBestFix = loc
        events(fixMap(loc, profile: Self.profileBest))
      } else {
        events(fixMap(loc, profile: Self.profileHundredMeters))
      }
    }
  }'
  local swift_indicator='  func applyIndicatorPolicy() {
    manager.showsBackgroundLocationIndicator = !(sessionHandler?.alwaysConfirmed ?? false)
  }'
  local swift_register='  func register(with messenger: FlutterBinaryMessenger) {
    channel.setMethodCallHandler { [weak self] call, result in
      switch call.method {
      case "clearLastBestFix":
        self?.lastBestFix = nil
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }'

  local swift_didfail='  func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
    guard let events = sink else { return }
    let code = (error as? CLError)?.code
    if code == .locationUnknown { return }
    events(FlutterError(
      code: code == .denied ? "denied" : "failed",
      message: "\(type(of: error))",
      details: nil
    ))
  }'

  _native() { # <label> <want-rc> <init> <onListen> <onCancel> <setProfile> <didUpdate> <indicator> <register> <didFail> <extra>
    local got=0
    printf '%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n}\n' \
      "${swift_head}" "${3:-$swift_init}" "${4:-$swift_onlisten}" \
      "${5:-$swift_oncancel}" "${6:-$swift_profile}" "${7:-$swift_didupdate}" \
      "${8:-$swift_indicator}" "${9:-$swift_register}" "${10:-$swift_didfail}" \
      "${11:-}" \
      >"${tmp}/HavenLocationStreamHandler.swift"
    ( check_native_stream_handler "${tmp}/HavenLocationStreamHandler.swift" ) >/dev/null 2>&1 || got=$?
    _record "$1" "$2" "${got}"
  }

  _native 'native: today'"'"'s handler passes' 0 '' '' '' '' '' '' '' ''
  # The four retired AppleSettings pins, in their new home.
  _native 'native: auto-pause turned back on' 1 \
    '  override init() {
    super.init()
    manager.pausesLocationUpdatesAutomatically = true
    manager.distanceFilter = kCLDistanceFilterNone
    manager.activityType = .other
    manager.desiredAccuracy = kCLLocationAccuracyBest
  }' '' '' '' '' '' '' ''
  _native 'native: a metre-scale distance filter' 1 \
    '  override init() {
    super.init()
    manager.pausesLocationUpdatesAutomatically = false
    manager.distanceFilter = 100
    manager.activityType = .other
    manager.desiredAccuracy = kCLLocationAccuracyBest
  }' '' '' '' '' '' '' ''
  _native 'native: activityType no longer .other' 1 \
    '  override init() {
    super.init()
    manager.pausesLocationUpdatesAutomatically = false
    manager.distanceFilter = kCLDistanceFilterNone
    manager.activityType = .fitness
    manager.desiredAccuracy = kCLLocationAccuracyBest
  }' '' '' '' '' '' '' ''
  # The escape a body-scoped grep cannot see: init() still reads correctly and
  # a later write on the LIVE manager undoes it.
  _native 'native: a second distanceFilter write elsewhere' 1 '' '' '' '' '' '' '' '' \
    '  func throttle() {
    manager.distanceFilter = 50
  }'
  # A third, coarser tier leaves Apple'"'"'s 16.4 delivery shape entirely.
  _native 'native: a third, coarser accuracy tier' 1 '' '' '' \
    '  private func setProfile(_ name: String) -> Bool {
    switch name {
    case Self.profileBest:
      bestSince = Date()
      manager.desiredAccuracy = kCLLocationAccuracyBest
    case Self.profileHundredMeters:
      manager.desiredAccuracy = kCLLocationAccuracyThreeKilometers
    default:
      return false
    }
    return true
  }' '' '' '' ''
  # And the other direction: the 100 m tier IS the power fix, so a handler that
  # only ever runs at Best is the 24/7 GNSS session this phase removed.
  _native 'native: the 100 m tier deleted (Best only)' 1 '' '' '' \
    '  private func setProfile(_ name: String) -> Bool {
    bestSince = Date()
    manager.desiredAccuracy = kCLLocationAccuracyBest
    return true
  }' '' '' '' ''
  # R8 across the channel hop: the background capability is a pure function of
  # the toggle, never a literal and never a permissive default.
  _native 'native: allowsBackgroundLocationUpdates hardcoded true' 1 '' \
    '  func onListen(
    withArguments arguments: Any?,
    eventSink events: @escaping FlutterEventSink
  ) -> FlutterError? {
    guard sink == nil else { return nil }
    let args = arguments as? [String: Any] ?? [:]
    let allowsBg = args["allowsBackgroundLocationUpdates"] as? Bool ?? false
    if allowsBg && UIApplication.shared.applicationState == .background {
      events(FlutterError(code: "background_start_refused", message: nil, details: nil))
      events(FlutterEndOfEventStream)
      return nil
    }
    sink = events
    manager.allowsBackgroundLocationUpdates = true
    applyIndicatorPolicy()
    bestSince = Date()
    manager.desiredAccuracy = kCLLocationAccuracyBest
    manager.startUpdatingLocation()
    return nil
  }' '' '' '' '' '' ''
  _native 'native: the derivation defaults to true when the argument is missing' 1 '' \
    '  func onListen(
    withArguments arguments: Any?,
    eventSink events: @escaping FlutterEventSink
  ) -> FlutterError? {
    guard sink == nil else { return nil }
    let args = arguments as? [String: Any] ?? [:]
    let allowsBg = args["allowsBackgroundLocationUpdates"] as? Bool ?? true
    if allowsBg && UIApplication.shared.applicationState == .background {
      events(FlutterError(code: "background_start_refused", message: nil, details: nil))
      events(FlutterEndOfEventStream)
      return nil
    }
    sink = events
    manager.allowsBackgroundLocationUpdates = allowsBg
    applyIndicatorPolicy()
    bestSince = Date()
    manager.desiredAccuracy = kCLLocationAccuracyBest
    manager.startUpdatingLocation()
    return nil
  }' '' '' '' '' '' ''
  _native 'native: allowsBg is a constant, not the argument' 1 '' \
    '  func onListen(
    withArguments arguments: Any?,
    eventSink events: @escaping FlutterEventSink
  ) -> FlutterError? {
    guard sink == nil else { return nil }
    let allowsBg = true
    if allowsBg && UIApplication.shared.applicationState == .background {
      events(FlutterError(code: "background_start_refused", message: nil, details: nil))
      events(FlutterEndOfEventStream)
      return nil
    }
    sink = events
    manager.allowsBackgroundLocationUpdates = allowsBg
    applyIndicatorPolicy()
    bestSince = Date()
    manager.desiredAccuracy = kCLLocationAccuracyBest
    manager.startUpdatingLocation()
    return nil
  }' '' '' '' '' '' ''
  # R7, both ways it rots.
  _native 'native: the background-start refusal removed' 1 '' \
    '  func onListen(
    withArguments arguments: Any?,
    eventSink events: @escaping FlutterEventSink
  ) -> FlutterError? {
    guard sink == nil else { return nil }
    let args = arguments as? [String: Any] ?? [:]
    let allowsBg = args["allowsBackgroundLocationUpdates"] as? Bool ?? false
    sink = events
    manager.allowsBackgroundLocationUpdates = allowsBg
    applyIndicatorPolicy()
    bestSince = Date()
    manager.desiredAccuracy = kCLLocationAccuracyBest
    manager.startUpdatingLocation()
    return nil
  }' '' '' '' '' '' ''
  _native 'native: the refusal written as applicationState != .active' 1 '' \
    '  func onListen(
    withArguments arguments: Any?,
    eventSink events: @escaping FlutterEventSink
  ) -> FlutterError? {
    guard sink == nil else { return nil }
    let args = arguments as? [String: Any] ?? [:]
    let allowsBg = args["allowsBackgroundLocationUpdates"] as? Bool ?? false
    if allowsBg && UIApplication.shared.applicationState != .active {
      events(FlutterError(code: "background_start_refused", message: nil, details: nil))
      events(FlutterEndOfEventStream)
      return nil
    }
    sink = events
    manager.allowsBackgroundLocationUpdates = allowsBg
    applyIndicatorPolicy()
    bestSince = Date()
    manager.desiredAccuracy = kCLLocationAccuracyBest
    manager.startUpdatingLocation()
    return nil
  }' '' '' '' '' '' ''
  # The EventChannel error contract: a RETURNED FlutterError goes to
  # FlutterError.reportError and never reaches the stream, so the refusal
  # becomes a silent hang on the Dart side.
  _native 'native: the refusal RETURNED instead of pushed through the sink' 1 '' \
    '  func onListen(
    withArguments arguments: Any?,
    eventSink events: @escaping FlutterEventSink
  ) -> FlutterError? {
    guard sink == nil else { return nil }
    let args = arguments as? [String: Any] ?? [:]
    let allowsBg = args["allowsBackgroundLocationUpdates"] as? Bool ?? false
    if allowsBg && UIApplication.shared.applicationState == .background {
      return FlutterError(code: "background_start_refused", message: nil, details: nil)
    }
    sink = events
    manager.allowsBackgroundLocationUpdates = allowsBg
    applyIndicatorPolicy()
    bestSince = Date()
    manager.desiredAccuracy = kCLLocationAccuracyBest
    manager.startUpdatingLocation()
    return nil
  }' '' '' '' '' '' ''
  _native 'native: a second startUpdatingLocation() site outside onListen' 1 '' '' '' '' '' '' '' '' \
    '  func restart() {
    manager.startUpdatingLocation()
  }'
  # OD1: the pill follows the TIER, not a literal and not the toggle.
  _native 'native: the indicator hardcoded' 1 '' '' '' '' '' \
    '  func applyIndicatorPolicy() {
    manager.showsBackgroundLocationIndicator = true
  }' '' ''
  # Only-Best, both clauses.
  _native 'native: a 100 m-tier fix cached as the publish input' 1 '' '' '' '' \
    '  func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
    guard let events = sink else { return }
    for loc in locations {
      if manager.desiredAccuracy == kCLLocationAccuracyBest && loc.timestamp >= bestSince {
        events(fixMap(loc, profile: Self.profileBest))
      } else {
        lastBestFix = loc
        events(fixMap(loc, profile: Self.profileHundredMeters))
      }
    }
  }' '' '' ''
  _native 'native: the bestSince clause dropped from the only-Best guard' 1 '' '' '' '' \
    '  func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
    guard let events = sink else { return }
    for loc in locations {
      if manager.desiredAccuracy == kCLLocationAccuracyBest {
        lastBestFix = loc
        events(fixMap(loc, profile: Self.profileBest))
      } else {
        events(fixMap(loc, profile: Self.profileHundredMeters))
      }
    }
  }' '' '' ''
  # The transient/terminal split. `locationUnknown` is CoreLocation saying "no
  # fix right now, still trying" — routine indoors, which is exactly where the
  # stationary tier runs — and Dart reads ANY sink error as the end of the
  # session's tier bookkeeping, so forwarding it ended background sharing over
  # a momentary loss of signal.
  _native 'native: locationUnknown forwarded as a failure again' 1 '' '' '' '' '' '' '' \
    '  func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
    guard let events = sink else { return }
    let denied = (error as? CLError)?.code == .denied
    events(FlutterError(
      code: denied ? "denied" : "failed",
      message: "\(type(of: error))",
      details: nil
    ))
  }' ''
  # The over-correction, which is just as silent: a revocation that never
  # reaches Dart leaves a dead session looking healthy.
  _native 'native: didFailWithError swallows every error' 1 '' '' '' '' '' '' '' \
    '  func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
    return
  }' ''
  # Anti-vacuity: no handler at all is not "nothing forwarded wrongly".
  _native 'native: didFailWithError deleted outright' 1 '' '' '' '' '' '' '' \
    '  // no error delegate at all' ''
  # Rule 10: the native copy dies with the subscription and on demand.
  _native 'native: onCancel no longer drops the cached Best fix' 1 '' '' \
    '  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    manager.stopUpdatingLocation()
    manager.allowsBackgroundLocationUpdates = false
    sink = nil
    return nil
  }' '' '' '' '' ''
  _native 'native: the clearLastBestFix method dropped' 1 '' '' '' '' '' '' \
    '  func register(with messenger: FlutterBinaryMessenger) {
    channel.setMethodCallHandler { [weak self] call, result in
      switch call.method {
      case "status":
        result(self?.status())
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }' ''
  _native 'native: a coordinate reaches a log line' 1 '' '' '' '' '' '' '' \
    '  private func trace(_ loc: CLLocation) {
    NSLog("fix %@", "\(loc.coordinate)")
  }'
  # Anti-vacuity: a file that says everything in comments says nothing.
  local native_none=0
  cat >"${tmp}/HavenLocationStreamHandler.swift" <<'EOF'
// final class HavenLocationStreamHandler: NSObject {
//   override init() {
//     manager.pausesLocationUpdatesAutomatically = false
//     manager.distanceFilter = kCLDistanceFilterNone
//     manager.desiredAccuracy = kCLLocationAccuracyBest
//   }
//   func onListen(...) -> FlutterError? {
//     let allowsBg = args["allowsBackgroundLocationUpdates"] as? Bool ?? false
//     manager.startUpdatingLocation()
//   }
// }
EOF
  ( check_native_stream_handler "${tmp}/HavenLocationStreamHandler.swift" ) >/dev/null 2>&1 || native_none=$?
  _record 'native: the whole handler commented out' 1 "${native_none}"

  # --- check_stream_provider ------------------------------------------------
  local provider_head='final locationStreamProvider = StreamProvider<Position>((ref) {
  final service = ref.watch(locationServiceProvider);
  final backgroundSharingEnabled = ref.watch(backgroundSharingProvider);
'
  local provider_tail='  if (service is GeolocatorLocationService) {
    if (!backgroundSharingEnabled) {
      service.clearCachedPosition();
    }
    return service.getLocationStream(
      backgroundSharingEnabled: backgroundSharingEnabled,
    );
  }
  return service.getLocationStream();
});'
  local paused_block='  if (!ref.read(appForegroundProvider)) {
    ref.watch(appForegroundProvider);
    final paused = StreamController<Position>();
    ref.onDispose(paused.close);
    return paused.stream;
  }
'

  _provider() { # <label> <want-rc> <whole-file>
    local got=0
    printf '%s\n' "$3" >"${tmp}/location_provider.dart"
    ( check_stream_provider "${tmp}/location_provider.dart" ) >/dev/null 2>&1 || got=$?
    _record "$1" "$2" "${got}"
  }

  _provider 'provider: today'"'"'s tree passes' 0 \
    "${provider_head}${paused_block}${provider_tail}"
  # The reviewer trap: a watch in the RUNNING build cancels the kept iOS
  # session on the pause write and only rebuilds at the resume frame.
  _provider 'provider: the foreground build watches the foreground provider' 1 \
    "final locationStreamProvider = StreamProvider<Position>((ref) {
  final service = ref.watch(locationServiceProvider);
  final backgroundSharingEnabled = ref.watch(backgroundSharingProvider);
  final foregrounded = ref.watch(appForegroundProvider);
${paused_block}${provider_tail}"
  # Same defect wearing a `.select`: still a watch, still rebuilds on the
  # pause write, still tears the kept session down — and invisible to a match
  # anchored on the closing paren.
  _provider 'provider: the foreground build watches it through .select' 1 \
    "final locationStreamProvider = StreamProvider<Position>((ref) {
  final service = ref.watch(locationServiceProvider);
  final backgroundSharingEnabled = ref.watch(backgroundSharingProvider);
  final foregrounded = ref.watch(appForegroundProvider.select((v) => v));
${paused_block}${provider_tail}"
  _provider 'provider: a stream start inside the not-foregrounded block' 1 \
    "${provider_head}  if (!ref.read(appForegroundProvider)) {
    ref.watch(appForegroundProvider);
    return service.getLocationStream(backgroundSharingEnabled: false);
  }
${provider_tail}"
  _provider 'provider: the opt-out cache clear deleted' 1 \
    "${provider_head}${paused_block}  if (service is GeolocatorLocationService) {
    return service.getLocationStream(
      backgroundSharingEnabled: backgroundSharingEnabled,
    );
  }
  return service.getLocationStream();
});"
  # Anti-vacuity: prose that names every token is not code.
  _provider 'provider: the body commented out entirely' 1 \
    "// final locationStreamProvider = StreamProvider<Position>((ref) {
//   final backgroundSharingEnabled = ref.watch(backgroundSharingProvider);
//   if (!ref.read(appForegroundProvider)) { return paused.stream; }
//   service.clearCachedPosition();
//   return service.getLocationStream(backgroundSharingEnabled: true);
// });"

  # --- check_c4_optout_release ----------------------------------------------
  #
  # The branch that runs when consent is WITHDRAWN while the app is paused.
  # Deleting any one of its four calls leaves every behavioural test and
  # every other guard green — `MapShell` cannot be pumped — while the
  # CLLocationManager session, the native session objects, the cached
  # coordinate, or the engine subscription and its socket outlive the consent
  # that authorised them.
  local c4_release='      _geolocatorService
        ?..suspendStream()
        ..clearCachedPosition();
      unawaited(ref.read(iosBackgroundSessionServiceProvider).disarm());
      unawaited(
        MapShell.releaseBurstPlaneOnOptOut(
          engine: ref.read(subscriptionServiceProvider),
          shutdownPublishPool: _shutdownPublishPool,
          runningBurst: _burstCoordinator?.runningBurst,
        ),
      );'
  # The static the call site names. Present in every fixture except the one
  # that guts it, so the branch checks above are never satisfied by a helper
  # that closes nothing.
  local c4_static='  static Future<void> releaseBurstPlaneOnOptOut({
    required SubscriptionService engine,
    required Future<void> Function() shutdownPublishPool,
    Future<void>? runningBurst,
  }) async {
    if (runningBurst != null) {
      await runningBurst.timeout(kOptOutBurstWait, onTimeout: () {});
    }
    await engine.pauseSubscriptions();
    await shutdownPublishPool();
  }'

  _c4() { # <label> <want-rc> <re-arm branch> <opt-out branch> [static]
    local got=0
    cat >"${tmp}/map_shell.dart" <<EOF
class MapShell {
${5-${c4_static}}
}

class _MapShellState {
  Future<void> _onPaused() async {
    _bgSharingPausedSub?.close();
    _bgSharingPausedSub = ref.listenManual<bool>(backgroundSharingProvider, (
      _,
      next,
    ) {
      if (next) {
        ref.read(locationPublishSchedulerProvider.notifier).startScheduling();
$3
        return;
      }
      ref.read(locationPublishSchedulerProvider.notifier).stopScheduling();
$4
    });
  }
}
EOF
    ( check_c4_optout_release "${tmp}/map_shell.dart" ) >/dev/null 2>&1 || got=$?
    _record "$1" "$2" "${got}"
  }

  _c4 'C4 opt-out: today'"'"'s tree passes' 0 \
    '        _startMotionTrigger();' "${c4_release}"
  # One deletion per fixture: everything else the branch owes is still there,
  # so each rc=1 is attributable to the one call that went missing.
  local c4_burst='      unawaited(
        MapShell.releaseBurstPlaneOnOptOut(
          engine: ref.read(subscriptionServiceProvider),
          shutdownPublishPool: _shutdownPublishPool,
          runningBurst: _burstCoordinator?.runningBurst,
        ),
      );'
  _c4 'C4 opt-out: the stream release deleted' 1 \
    '        _startMotionTrigger();' \
"      _geolocatorService?.clearCachedPosition();
      unawaited(ref.read(iosBackgroundSessionServiceProvider).disarm());
${c4_burst}"
  _c4 'C4 opt-out: the cached-fix clear deleted' 1 \
    '        _startMotionTrigger();' \
"      _geolocatorService?.suspendStream();
      unawaited(ref.read(iosBackgroundSessionServiceProvider).disarm());
${c4_burst}"
  _c4 'C4 opt-out: the native session disarm deleted' 1 \
    '        _startMotionTrigger();' \
"      _geolocatorService
        ?..suspendStream()
        ..clearCachedPosition();
${c4_burst}"
  # The socket half: consent is withdrawn, the location plane is released —
  # and the engine keeps its standing REQ and its socket until iOS happens to
  # suspend the process.
  _c4 'C4 opt-out: the burst-plane release deleted' 1 \
    '        _startMotionTrigger();' \
'      _geolocatorService
        ?..suspendStream()
        ..clearCachedPosition();
      unawaited(ref.read(iosBackgroundSessionServiceProvider).disarm());'
  # A gutted body compiles, lints clean, keeps the call site the branch check
  # reads, and closes nothing — the mutation a call-site grep cannot see.
  _c4 'C4 opt-out: the release helper closes nothing' 1 \
    '        _startMotionTrigger();' "${c4_release}" \
'  static Future<void> releaseBurstPlaneOnOptOut({
    required SubscriptionService engine,
    required Future<void> Function() shutdownPublishPool,
    Future<void>? runningBurst,
  }) async {
    debugPrint("[MapShell] opt-out");
  }'
  # The escape a method-wide grep cannot see: every call is still present in
  # `_onPaused`, on the branch that runs for users who withdrew NOTHING.
  _c4 'C4 opt-out: the four calls moved to the re-arm branch' 1 \
"${c4_release}" \
'      debugPrint("[MapShell] background sharing disabled while paused");'
  # Anti-vacuity: a missing anchor must fail, never pass for want of something
  # to slice.
  local c4_none=0
  cat >"${tmp}/map_shell.dart" <<'EOF'
class _MapShellState {
  Future<void> _onPaused() async {
    // _bgSharingPausedSub = ref.listenManual<bool>(backgroundSharingProvider, (
    //   _,
    //   next,
    // ) {
    //   if (next) { return; }
    //   _geolocatorService?..suspendStream()..clearCachedPosition();
    //   unawaited(ref.read(iosBackgroundSessionServiceProvider).disarm());
    // });
  }
}
EOF
  ( check_c4_optout_release "${tmp}/map_shell.dart" ) >/dev/null 2>&1 || c4_none=$?
  _record 'C4 opt-out: the whole watcher commented out' 1 "${c4_none}"

  # The UNCONDITIONALITY half. Every fixture below still NAMES both links
  # inside `releaseBurstPlaneOnOptOut`, so every presence grep above stays
  # green; only where they sit changes. That is the whole point — the release
  # is promised on every path, and the branch that already exists one line
  # above them is the obvious place a refactor would tuck them into.
  local c4_nested_both='  static Future<void> releaseBurstPlaneOnOptOut({
    required SubscriptionService engine,
    required Future<void> Function() shutdownPublishPool,
    Future<void>? runningBurst,
  }) async {
    if (runningBurst != null) {
      await runningBurst.timeout(kOptOutBurstWait, onTimeout: () {});
      await engine.pauseSubscriptions();
      await shutdownPublishPool();
    }
  }'
  _c4 'C4 opt-out: both links moved inside the burst-in-flight branch' 1 \
    '        _startMotionTrigger();' "${c4_release}" "${c4_nested_both}"
  _c4 'C4 opt-out: only the pause moved inside the branch' 1 \
    '        _startMotionTrigger();' "${c4_release}" \
'  static Future<void> releaseBurstPlaneOnOptOut({
    required SubscriptionService engine,
    required Future<void> Function() shutdownPublishPool,
    Future<void>? runningBurst,
  }) async {
    if (runningBurst != null) {
      await runningBurst.timeout(kOptOutBurstWait, onTimeout: () {});
      await engine.pauseSubscriptions();
    }
    await shutdownPublishPool();
  }'
  _c4 'C4 opt-out: only the pool shutdown moved inside the branch' 1 \
    '        _startMotionTrigger();' "${c4_release}" \
'  static Future<void> releaseBurstPlaneOnOptOut({
    required SubscriptionService engine,
    required Future<void> Function() shutdownPublishPool,
    Future<void>? runningBurst,
  }) async {
    if (runningBurst != null) {
      await runningBurst.timeout(kOptOutBurstWait, onTimeout: () {});
      await shutdownPublishPool();
    }
    await engine.pauseSubscriptions();
  }'
  # …and the direction that must PASS, in the tree's real shape: each link
  # wrapped in its own `try`, with an `on Object catch` beside it. A `try` body
  # runs on every path, so it is transparent to the rule; the message strings
  # carry `${...}` interpolations, whose braces must not shift the nesting the
  # rule reads. A version that failed here would push the next author to delete
  # the error handling to satisfy a guard.
  _c4 "C4 opt-out: the tree's real try/catch shape passes" 0 \
    '        _startMotionTrigger();' "${c4_release}" \
'  static Future<void> releaseBurstPlaneOnOptOut({
    required SubscriptionService engine,
    required Future<void> Function() shutdownPublishPool,
    Future<void>? runningBurst,
    Duration burstWait = kOptOutBurstWait,
  }) async {
    if (runningBurst != null) {
      try {
        await runningBurst.timeout(
          burstWait,
          onTimeout: () => debugPrint("not settled within ${burstWait}s"),
        );
      } on Object catch (e) {
        debugPrint("burst failed: ${e.runtimeType}");
      }
    }
    try {
      await engine.pauseSubscriptions();
    } on Object catch (e) {
      debugPrint("pause failed: ${e.runtimeType}");
    }
    try {
      await shutdownPublishPool();
    } on Object catch (e) {
      debugPrint("pool shutdown failed: ${e.runtimeType}");
    }
  }'
  # …and the direction the tree moved to while this guard was being written: a
  # link handed to a runner as a TEAR-OFF writes no parentheses at all. The
  # rule is "both links are named, unconditionally, in the body", not "both
  # links are called here" — a pin on the call syntax would have pushed the
  # next author to un-refactor working code to satisfy a guard.
  _c4 'C4 opt-out: links handed to a runner as tear-offs pass' 0 \
    '        _startMotionTrigger();' "${c4_release}" \
'  static Future<void> releaseBurstPlaneOnOptOut({
    required SubscriptionService engine,
    required Future<void> Function() shutdownPublishPool,
    Future<void>? runningBurst,
    Duration burstWait = kOptOutBurstWait,
  }) async {
    if (runningBurst != null) {
      await runningBurst.timeout(burstWait, onTimeout: () {});
    }
    await Future.wait(<Future<void>>[
      _optOutLink("pause", () => engine.pauseSubscriptions()),
      _optOutLink("pool shutdown", shutdownPublishPool),
    ]);
  }'
  # Anti-vacuity for the body slicer: an expression-bodied release has no block
  # to read, so "unconditionally" cannot be established over it. The signature
  # declares a PARAMETER named after one of the links, which is exactly what a
  # whole-method grep would have matched.
  _c4 'C4 opt-out: an expression-bodied release has no body to read' 1 \
    '        _startMotionTrigger();' "${c4_release}" \
'  static Future<void> releaseBurstPlaneOnOptOut({
    required SubscriptionService engine,
    required Future<void> Function() shutdownPublishPool,
  }) =>
      Future.wait(<Future<void>>[
        engine.pauseSubscriptions(),
        shutdownPublishPool(),
      ]);'

  # --- check_burst_plane_entry ----------------------------------------------
  #
  # Four doors into the publish plane, and a constructor-name pin holds only
  # the first. The tree below is the real triangle in miniature: the plane
  # itself, the lifecycle file that builds and installs it, the scheduler that
  # ticks it, and the engine interface it opens a burst on.
  local burst_plane='/// Installed with `scheduler.setTickSink(coordinator)` on the pause.
abstract class BurstSink {
  Future<void> onTick({required String circleKey, required Circle circle});
  Future<void>? get runningBurst;
}

class BackgroundBurstCoordinator implements BurstSink {
  BackgroundBurstCoordinator({required this.engine});
  final SubscriptionService engine;

  Future<void> _runBurst() async {
    await engine.openBackgroundBurst();
  }
}'
  local burst_owner='class _MapShellState {
  BackgroundBurstCoordinator _installBurstCoordinator() {
    final coordinator = BackgroundBurstCoordinator(engine: _engine);
    _scheduler.setTickSink(coordinator);
    return coordinator;
  }
}'
  local burst_scheduler='class LocationPublishSchedulerNotifier {
  BurstSink? _tickSink;

  void setTickSink(BurstSink? sink) {
    _tickSink = sink;
  }
}'
  local burst_api='abstract class SubscriptionService {
  Future<void> openBackgroundBurst();
}'
  local burst_impl='class NostrSubscriptionService implements SubscriptionService {
  @override
  Future<void> openBackgroundBurst() async {
    await engine.openBackgroundBurst();
  }
}'
  local burst_slc='final class HavenSLCHandler: NSObject {
  private func triggerDartCatchup() {
    channel.invokeMethod("runCatchup", arguments: nil) { [weak self] _ in }
  }
}'
  local burst_bgtask='final class HavenBGTaskHandler: NSObject {
  private func triggerDartCatchup(task: BGTask) {
    channel.invokeMethod("runCatchup", arguments: nil) { [weak task] _ in }
  }
}'

  _burst_tree() { # rebuilds the canonical fixture tree
    rm -rf "${tmp}/burst"
    mkdir -p "${tmp}/burst/lib/src/services" "${tmp}/burst/lib/src/pages" \
      "${tmp}/burst/lib/src/providers" "${tmp}/burst/lib/src/rust" \
      "${tmp}/burst/ios"
    printf '%s\n' "${burst_plane}" \
      >"${tmp}/burst/lib/src/services/background_burst_coordinator.dart"
    printf '%s\n' "${burst_owner}" >"${tmp}/burst/lib/src/pages/map_shell.dart"
    printf '%s\n' "${burst_scheduler}" \
      >"${tmp}/burst/lib/src/providers/location_publish_scheduler_provider.dart"
    printf '%s\n' "${burst_api}" \
      >"${tmp}/burst/lib/src/services/subscription_service.dart"
    printf '%s\n' "${burst_impl}" \
      >"${tmp}/burst/lib/src/services/nostr_subscription_service.dart"
    printf '%s\n' "${burst_slc}" >"${tmp}/burst/ios/HavenSLCHandler.swift"
    printf '%s\n' "${burst_bgtask}" >"${tmp}/burst/ios/HavenBGTaskHandler.swift"
  }

  _burst() { # <label> <want-rc>
    local got=0
    ( check_burst_plane_entry "${tmp}/burst/lib" \
        "${tmp}/burst/ios/HavenSLCHandler.swift" \
        "${tmp}/burst/ios/HavenBGTaskHandler.swift" ) >/dev/null 2>&1 || got=$?
    _record "$1" "$2" "${got}"
  }

  _burst_tree
  _burst 'burst plane: the four doors in their three files pass' 0
  # 1. Construction, both directions. Zero is not "clean": it is a build in
  #    which nothing ever publishes in the background.
  _burst_tree
  printf 'class WakeEntry {\n  void go() {\n    BackgroundBurstCoordinator(engine: e).onTick(circleKey: k, circle: c);\n  }\n}\n' \
    >"${tmp}/burst/lib/src/services/wake_entry.dart"
  _burst 'burst plane: a SECOND file constructs the coordinator' 1
  _burst_tree
  printf 'class WakeEntry {\n  // Was: BackgroundBurstCoordinator(engine: e).onTick(...);\n}\n' \
    >"${tmp}/burst/lib/src/services/wake_entry.dart"
  _burst 'burst plane: a construction elsewhere that is only a comment' 0
  _burst_tree
  printf '%s\n' 'class _MapShellState {
  void _installBurstCoordinator() {
    _scheduler.setTickSink(_someOtherSink);
  }
}' >"${tmp}/burst/lib/src/pages/map_shell.dart"
  _burst 'burst plane: nobody constructs the coordinator' 1
  # 2. The doors a constructor-name pin cannot see.
  _burst_tree
  printf '%s\n' 'class WakeSink implements BurstSink {
  @override
  Future<void> onTick({required String circleKey, required Circle circle}) async {}
  @override
  Future<void>? get runningBurst => null;
}' >"${tmp}/burst/lib/src/services/wake_sink.dart"
  _burst 'burst plane: a second file implements BurstSink' 1
  _burst_tree
  printf '%s\n' 'class WakeBurst extends BackgroundBurstCoordinator {
  WakeBurst() : super(engine: e);
}' >"${tmp}/burst/lib/src/services/wake_burst.dart"
  _burst 'burst plane: a second file subclasses the coordinator' 1
  # 3. Installation, both directions. The scheduler's own DECLARATION of
  #    setTickSink carries no receiver and must not read as an install.
  _burst_tree
  printf '%s\n' 'class WakeEntry {
  void go(Object scheduler) {
    (scheduler as dynamic).setTickSink(_sink);
  }
}' >"${tmp}/burst/lib/src/services/wake_entry.dart"
  _burst 'burst plane: a second file installs the tick sink' 1
  _burst_tree
  printf '%s\n' 'class _MapShellState {
  BackgroundBurstCoordinator _installBurstCoordinator() {
    return BackgroundBurstCoordinator(engine: _engine);
  }
}' >"${tmp}/burst/lib/src/pages/map_shell.dart"
  _burst 'burst plane: nobody installs the tick sink' 1
  # 4. The engine's burst API, and the deliberate exclusion of the generated
  #    bindings — which mirror the Rust surface and decide nothing.
  _burst_tree
  printf '%s\n' 'Future<void> wakeCatchup(SubscriptionService engine) async {
  await engine.openBackgroundBurst();
}' >"${tmp}/burst/lib/src/services/ios_background_catchup.dart"
  _burst 'burst plane: a new file opens a burst on the engine' 1
  _burst_tree
  printf '%s\n' 'abstract class RustSubscriptionEngine {
  Future<void> openBackgroundBurst();
}' >"${tmp}/burst/lib/src/rust/api.dart"
  _burst 'burst plane: the generated bindings are not a call site' 0
  # 5. The native wakes: one door into Dart, and it is receive-only.
  _burst_tree
  printf '%s\n' 'final class HavenSLCHandler: NSObject {
  private func triggerDartCatchup() {
    channel.invokeMethod("startBurstPublish", arguments: nil)
    channel.invokeMethod("runCatchup", arguments: nil) { [weak self] _ in }
  }
}' >"${tmp}/burst/ios/HavenSLCHandler.swift"
  _burst 'burst plane: a native wake invokes a second Dart method' 1
  _burst_tree
  printf '%s\n' 'final class HavenBGTaskHandler: NSObject {
  private func triggerDartCatchup(task: BGTask) {
    // channel.invokeMethod("runCatchup", arguments: nil) { [weak task] _ in }
  }
}' >"${tmp}/burst/ios/HavenBGTaskHandler.swift"
  _burst "burst plane: a native wake's only invoke is commented out" 1
  # A wake source this guard cannot read is one whose Dart entry point nothing
  # pins — the same defect as a missing anchor anywhere else here.
  _burst_tree
  rm -f "${tmp}/burst/ios/HavenBGTaskHandler.swift"
  _burst 'burst plane: a native wake handler is missing from the tree' 1

  # --- check_presence_only_logging ------------------------------------------
  #
  # The coordinator is the file this sweep gained: `BurstFix` holds a latitude,
  # a longitude and the pubkey the burst publishes under, and its `toString()`
  # renders all three into one `debugPrint`.
  _logs() { # <label> <want-rc> <body>
    local got=0
    printf 'class C {\n%s\n}\n' "$3" >"${tmp}/logs.dart"
    ( check_presence_only_logging "${tmp}/logs.dart" ) >/dev/null 2>&1 || got=$?
    _record "$1" "$2" "${got}"
  }
  _logs 'presence-only logs: type-only failure logs pass' 0 \
    "  void go() {
    debugPrint('[BackgroundBurst] burst failed: \${e.runtimeType}');
    debugPrint('[BackgroundBurst] published \$count circle(s)');
  }"
  _logs 'presence-only logs: the whole BurstFix interpolated' 1 \
    "  void go() {
    debugPrint('[BackgroundBurst] publishing \$fix');
  }"
  _logs 'presence-only logs: a latitude interpolated' 1 \
    "  void go() {
    debugPrint('[BackgroundBurst] at \${fix.latitude}');
  }"
  _logs 'presence-only logs: the leak is only in a comment' 0 \
    "  void go() {
    // debugPrint('[BackgroundBurst] publishing \$fix');
    debugPrint('[BackgroundBurst] publishing');
  }"
  # Anti-vacuity: a sweep over a file that has moved inspects nothing, and a
  # list of paths is exactly the thing a rename leaves behind.
  local logs_missing=0
  ( check_presence_only_logging "${tmp}/no_such_file.dart" ) >/dev/null 2>&1 ||
    logs_missing=$?
  _record 'presence-only logs: a swept file has moved away' 1 "${logs_missing}"

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

  # --- check_arm_tier_policy ------------------------------------------------
  #
  # The tier policy decides, for every user, whether the app holds an OS
  # keep-alive at all. Getting it wrong in the permissive direction is a
  # constant blue pill; getting it wrong in the RESTRICTIVE direction (treating
  # a provisional Always as confirmed) silently drops the keep-alive for a
  # cohort the OS itself handles as When-In-Use — the 2026-08-20 field failure.
  # Nothing behavioural can see either: no Swift test runs in CI. The first
  # fixture below is the one the Android review earned us — a GUTTED function
  # that leaves every lint and every other guard green.
  local arm_good='  func arm() {
    guard UserDefaults.standard.bool(forKey: Self.kBgSharingKey),
      UserDefaults.standard.bool(forKey: Self.kBgDisclosureKey)
    else {
      disarm()
      return
    }
    let status = CLLocationManager().authorizationStatus
    guard status == .authorizedWhenInUse || status == .authorizedAlways else {
      disarm()
      return
    }
    if #available(iOS 17.0, *) {
      let wantsActivitySession = status == .authorizedWhenInUse || !alwaysConfirmed
      if wantsActivitySession {
        if backgroundActivity == nil { backgroundActivity = CLBackgroundActivitySession() }
      } else if UIApplication.shared.applicationState != .background {
        (backgroundActivity as? CLBackgroundActivitySession)?.invalidate()
        backgroundActivity = nil
      }
    }
    if #available(iOS 18.0, *) {
      if status == .authorizedAlways {
        if alwaysSession == nil {
          let session = CLServiceSession(authorization: .always)
          alwaysSession = session
          observeAlwaysDiagnostics(session)
        }
      } else {
        (alwaysSession as? CLServiceSession)?.invalidate()
        alwaysSession = nil
        diagnosticsTask?.cancel()
        diagnosticsTask = nil
        alwaysConfirmed = false
      }
    }
  }'
  local obs_good='  @available(iOS 18.0, *)
  private func observeAlwaysDiagnostics(_ session: CLServiceSession) {
    diagnosticsTask = Task { [weak self] in
      for try await diagnostic in session.diagnostics {
        let confirmed = !diagnostic.alwaysAuthorizationDenied
          && !diagnostic.authorizationRequestInProgress
          && !diagnostic.insufficientlyInUse
        DispatchQueue.main.async {
          guard let self = self,
            let held = self.alwaysSession as? CLServiceSession,
            held === session,
            self.alwaysConfirmed != confirmed
          else { return }
          self.alwaysConfirmed = confirmed
          self.arm()
          self.onAlwaysConfirmedChanged?()
        }
      }
    }
  }'
  local disarm_good='  func disarm() {
    if #available(iOS 17.0, *) {
      (backgroundActivity as? CLBackgroundActivitySession)?.invalidate()
    }
    backgroundActivity = nil
    if #available(iOS 18.0, *) {
      (alwaysSession as? CLServiceSession)?.invalidate()
    }
    alwaysSession = nil
    diagnosticsTask?.cancel()
    diagnosticsTask = nil
    alwaysConfirmed = false
  }'

  _tier() { # <label> <want-rc> <arm> <observer> <disarm> <extra>
    local got=0
    printf 'final class HavenBackgroundSessionHandler: NSObject {\n  private var backgroundActivity: Any?\n  private var alwaysSession: Any?\n  private var diagnosticsTask: Task<Void, Never>?\n  private(set) var alwaysConfirmed = false\n%s\n%s\n%s\n%s\n}\n' \
      "${3:-$arm_good}" "${4:-$obs_good}" "${5:-$disarm_good}" "${6:-}" \
      >"${tmp}/HavenBackgroundSessionHandler.swift"
    ( check_arm_tier_policy "${tmp}/HavenBackgroundSessionHandler.swift" ) >/dev/null 2>&1 || got=$?
    _record "$1" "$2" "${got}"
  }

  _tier 'tier: today'"'"'s handler passes' 0 '' '' '' ''
  # The Android lesson: a gutted function compiles, lints clean, and leaves
  # every other guard green while the feature it named no longer exists.
  _tier 'tier: arm() gutted to an empty body' 1 '  func arm() {
  }' '' '' ''
  _tier 'tier: the activity session created unconditionally' 1 \
    '  func arm() {
    guard UserDefaults.standard.bool(forKey: Self.kBgSharingKey),
      UserDefaults.standard.bool(forKey: Self.kBgDisclosureKey)
    else {
      disarm()
      return
    }
    let status = CLLocationManager().authorizationStatus
    guard status == .authorizedWhenInUse || status == .authorizedAlways else {
      disarm()
      return
    }
    if #available(iOS 17.0, *) {
      if backgroundActivity == nil { backgroundActivity = CLBackgroundActivitySession() }
    }
  }' '' '' ''
  # The reviewer trap that OD-P3-b turns on: authorizationStatus already reports
  # .authorizedAlways while the second prompt is unanswered, so gating on the
  # status alone drops the keep-alive for the provisional cohort.
  _tier 'tier: the activity session gated on .authorizedWhenInUse alone' 1 \
    '  func arm() {
    guard UserDefaults.standard.bool(forKey: Self.kBgSharingKey),
      UserDefaults.standard.bool(forKey: Self.kBgDisclosureKey)
    else {
      disarm()
      return
    }
    let status = CLLocationManager().authorizationStatus
    guard status == .authorizedWhenInUse || status == .authorizedAlways else {
      disarm()
      return
    }
    if #available(iOS 17.0, *) {
      let wantsActivitySession = status == .authorizedWhenInUse
      if wantsActivitySession {
        if backgroundActivity == nil { backgroundActivity = CLBackgroundActivitySession() }
      } else if UIApplication.shared.applicationState != .background {
        (backgroundActivity as? CLBackgroundActivitySession)?.invalidate()
        backgroundActivity = nil
      }
    }
  }' '' '' ''
  _tier 'tier: the When-In-Use clause deleted from the predicate' 1 \
    '  func arm() {
    guard UserDefaults.standard.bool(forKey: Self.kBgSharingKey),
      UserDefaults.standard.bool(forKey: Self.kBgDisclosureKey)
    else {
      disarm()
      return
    }
    let status = CLLocationManager().authorizationStatus
    guard status == .authorizedWhenInUse || status == .authorizedAlways else {
      disarm()
      return
    }
    if #available(iOS 17.0, *) {
      let wantsActivitySession = !alwaysConfirmed
      if wantsActivitySession {
        if backgroundActivity == nil { backgroundActivity = CLBackgroundActivitySession() }
      } else if UIApplication.shared.applicationState != .background {
        (backgroundActivity as? CLBackgroundActivitySession)?.invalidate()
        backgroundActivity = nil
      }
    }
  }' '' '' ''
  # arm() never withdraws an in-use claim while backgrounded: a WIU->Always
  # upgrade delivered in the background would drop the only keep-alive the
  # process has, and its replacement cannot start outside the foreground.
  _tier 'tier: the release runs without the applicationState guard' 1 \
    '  func arm() {
    guard UserDefaults.standard.bool(forKey: Self.kBgSharingKey),
      UserDefaults.standard.bool(forKey: Self.kBgDisclosureKey)
    else {
      disarm()
      return
    }
    let status = CLLocationManager().authorizationStatus
    guard status == .authorizedWhenInUse || status == .authorizedAlways else {
      disarm()
      return
    }
    if #available(iOS 17.0, *) {
      let wantsActivitySession = status == .authorizedWhenInUse || !alwaysConfirmed
      if wantsActivitySession {
        if backgroundActivity == nil { backgroundActivity = CLBackgroundActivitySession() }
      } else {
        (backgroundActivity as? CLBackgroundActivitySession)?.invalidate()
        backgroundActivity = nil
      }
    }
  }' '' '' ''
  _tier 'tier: the Always branch releases without nilling the reference' 1 \
    '  func arm() {
    guard UserDefaults.standard.bool(forKey: Self.kBgSharingKey),
      UserDefaults.standard.bool(forKey: Self.kBgDisclosureKey)
    else {
      disarm()
      return
    }
    let status = CLLocationManager().authorizationStatus
    guard status == .authorizedWhenInUse || status == .authorizedAlways else {
      disarm()
      return
    }
    if #available(iOS 17.0, *) {
      let wantsActivitySession = status == .authorizedWhenInUse || !alwaysConfirmed
      if wantsActivitySession {
        if backgroundActivity == nil { backgroundActivity = CLBackgroundActivitySession() }
      } else if UIApplication.shared.applicationState != .background {
        (backgroundActivity as? CLBackgroundActivitySession)?.invalidate()
      }
    }
  }' '' '' ''
  _tier 'tier: the disclosure gate dropped from arm()' 1 \
    '  func arm() {
    guard UserDefaults.standard.bool(forKey: Self.kBgSharingKey) else {
      disarm()
      return
    }
    let status = CLLocationManager().authorizationStatus
    guard status == .authorizedWhenInUse || status == .authorizedAlways else {
      disarm()
      return
    }
    if #available(iOS 17.0, *) {
      let wantsActivitySession = status == .authorizedWhenInUse || !alwaysConfirmed
      if wantsActivitySession {
        if backgroundActivity == nil { backgroundActivity = CLBackgroundActivitySession() }
      } else if UIApplication.shared.applicationState != .background {
        (backgroundActivity as? CLBackgroundActivitySession)?.invalidate()
        backgroundActivity = nil
      }
    }
  }' '' '' ''
  # The observer is the other half the Android lesson applies to: a stub leaves
  # alwaysConfirmed false forever and silently deletes the whole Always tier.
  _tier 'tier: the diagnostics observer stubbed out' 1 '' \
    '  @available(iOS 18.0, *)
  private func observeAlwaysDiagnostics(_ session: CLServiceSession) {
  }' '' ''
  _tier 'tier: the observer sets the flag without re-running arm()' 1 '' \
    '  @available(iOS 18.0, *)
  private func observeAlwaysDiagnostics(_ session: CLServiceSession) {
    diagnosticsTask = Task { [weak self] in
      for try await diagnostic in session.diagnostics {
        let confirmed = !diagnostic.alwaysAuthorizationDenied
          && !diagnostic.authorizationRequestInProgress
          && !diagnostic.insufficientlyInUse
        DispatchQueue.main.async {
          guard let self = self,
            let held = self.alwaysSession as? CLServiceSession,
            held === session,
            self.alwaysConfirmed != confirmed
          else { return }
          self.alwaysConfirmed = confirmed
          self.onAlwaysConfirmedChanged?()
        }
      }
    }
  }' '' ''
  _tier 'tier: the observer stops firing onAlwaysConfirmedChanged' 1 '' \
    '  @available(iOS 18.0, *)
  private func observeAlwaysDiagnostics(_ session: CLServiceSession) {
    diagnosticsTask = Task { [weak self] in
      for try await diagnostic in session.diagnostics {
        let confirmed = !diagnostic.alwaysAuthorizationDenied
          && !diagnostic.authorizationRequestInProgress
          && !diagnostic.insufficientlyInUse
        DispatchQueue.main.async {
          guard let self = self,
            let held = self.alwaysSession as? CLServiceSession,
            held === session,
            self.alwaysConfirmed != confirmed
          else { return }
          self.alwaysConfirmed = confirmed
          self.arm()
        }
      }
    }
  }' '' ''
  # Dropping a clause confirms Always for a user whose EFFECTIVE authorization
  # is still When-In-Use — the unsafe direction (silent publish loss).
  _tier 'tier: the insufficientlyInUse clause dropped from the verdict' 1 '' \
    '  @available(iOS 18.0, *)
  private func observeAlwaysDiagnostics(_ session: CLServiceSession) {
    diagnosticsTask = Task { [weak self] in
      for try await diagnostic in session.diagnostics {
        let confirmed = !diagnostic.alwaysAuthorizationDenied
          && !diagnostic.authorizationRequestInProgress
        DispatchQueue.main.async {
          guard let self = self,
            let held = self.alwaysSession as? CLServiceSession,
            held === session
          else { return }
          self.alwaysConfirmed = confirmed
          self.arm()
          self.onAlwaysConfirmedChanged?()
        }
      }
    }
  }' '' ''
  # --- the ordering race an independent review found on 2026-09-03 ----------
  #
  # The verdict is computed off the main thread and applied from a block hopped
  # onto the MAIN queue, and `Task.cancel()` cannot reach a block that is
  # already enqueued there. The first fixture is the code EXACTLY as it stood
  # before the fix: a downgrade that invalidates the session, nils it and
  # clears the flag is immediately followed by the stale block writing true and
  # re-running arm(), which — finding the reference already nil — skipped the
  # gated reset and left a confirmation with no session behind it. Contained
  # while the user stays on When-In-Use, but the NEXT Always grant then drops
  # the activity session before any diagnostic has confirmed anything: the
  # provisional-Always shape of the 2026-08-20 field failure.
  _tier 'tier: the confirmation applied without checking which session yielded it' 1 '' \
    '  @available(iOS 18.0, *)
  private func observeAlwaysDiagnostics(_ session: CLServiceSession) {
    diagnosticsTask?.cancel()
    diagnosticsTask = Task { [weak self] in
      for try await diagnostic in session.diagnostics {
        let confirmed = !diagnostic.alwaysAuthorizationDenied
          && !diagnostic.authorizationRequestInProgress
          && !diagnostic.insufficientlyInUse
        DispatchQueue.main.async {
          guard let self = self, self.alwaysConfirmed != confirmed else { return }
          self.alwaysConfirmed = confirmed
          self.arm()
          self.onAlwaysConfirmedChanged?()
        }
      }
    }
  }' '' ''
  # A non-nil check is not an identity check: it passes for the REPLACED
  # session of the next Always grant, which is the case that matters.
  _tier 'tier: the confirmation gated on any session being held, not the observed one' 1 '' \
    '  @available(iOS 18.0, *)
  private func observeAlwaysDiagnostics(_ session: CLServiceSession) {
    diagnosticsTask?.cancel()
    diagnosticsTask = Task { [weak self] in
      for try await diagnostic in session.diagnostics {
        let confirmed = !diagnostic.alwaysAuthorizationDenied
          && !diagnostic.authorizationRequestInProgress
          && !diagnostic.insufficientlyInUse
        DispatchQueue.main.async {
          guard let self = self,
            self.alwaysSession != nil,
            self.alwaysConfirmed != confirmed
          else { return }
          self.alwaysConfirmed = confirmed
          self.arm()
          self.onAlwaysConfirmedChanged?()
        }
      }
    }
  }' '' ''
  _tier 'tier: the identity re-check placed AFTER the alwaysConfirmed write' 1 '' \
    '  @available(iOS 18.0, *)
  private func observeAlwaysDiagnostics(_ session: CLServiceSession) {
    diagnosticsTask?.cancel()
    diagnosticsTask = Task { [weak self] in
      for try await diagnostic in session.diagnostics {
        let confirmed = !diagnostic.alwaysAuthorizationDenied
          && !diagnostic.authorizationRequestInProgress
          && !diagnostic.insufficientlyInUse
        DispatchQueue.main.async {
          guard let self = self, self.alwaysConfirmed != confirmed else { return }
          self.alwaysConfirmed = confirmed
          guard let held = self.alwaysSession as? CLServiceSession, held === session
          else { return }
          self.arm()
          self.onAlwaysConfirmedChanged?()
        }
      }
    }
  }' '' ''
  # No hop at all is worse, not better: the write then races arm() from the
  # diagnostics task's own thread.
  _tier 'tier: the confirmation written straight from the diagnostics task' 1 '' \
    '  @available(iOS 18.0, *)
  private func observeAlwaysDiagnostics(_ session: CLServiceSession) {
    diagnosticsTask?.cancel()
    diagnosticsTask = Task { [weak self] in
      for try await diagnostic in session.diagnostics {
        let confirmed = !diagnostic.alwaysAuthorizationDenied
          && !diagnostic.authorizationRequestInProgress
          && !diagnostic.insufficientlyInUse
        self?.alwaysConfirmed = confirmed
        self?.arm()
        self?.onAlwaysConfirmedChanged?()
      }
    }
  }' '' ''
  # The other half of the same race: the reset arm() runs on a downgrade must
  # not be skippable, or a confirmation that lands late outlives its session.
  _tier 'tier: the .always reset gated on the session still being held' 1 \
    '  func arm() {
    guard UserDefaults.standard.bool(forKey: Self.kBgSharingKey),
      UserDefaults.standard.bool(forKey: Self.kBgDisclosureKey)
    else {
      disarm()
      return
    }
    let status = CLLocationManager().authorizationStatus
    guard status == .authorizedWhenInUse || status == .authorizedAlways else {
      disarm()
      return
    }
    if #available(iOS 17.0, *) {
      let wantsActivitySession = status == .authorizedWhenInUse || !alwaysConfirmed
      if wantsActivitySession {
        if backgroundActivity == nil { backgroundActivity = CLBackgroundActivitySession() }
      } else if UIApplication.shared.applicationState != .background {
        (backgroundActivity as? CLBackgroundActivitySession)?.invalidate()
        backgroundActivity = nil
      }
    }
    if #available(iOS 18.0, *) {
      if status == .authorizedAlways {
        if alwaysSession == nil {
          let session = CLServiceSession(authorization: .always)
          alwaysSession = session
          observeAlwaysDiagnostics(session)
        }
      } else if let held = alwaysSession as? CLServiceSession {
        held.invalidate()
        alwaysSession = nil
        diagnosticsTask?.cancel()
        diagnosticsTask = nil
        alwaysConfirmed = false
      }
    }
  }' '' '' ''
  _tier 'tier: the .always reset nested behind an inner alwaysSession check' 1 \
    '  func arm() {
    guard UserDefaults.standard.bool(forKey: Self.kBgSharingKey),
      UserDefaults.standard.bool(forKey: Self.kBgDisclosureKey)
    else {
      disarm()
      return
    }
    let status = CLLocationManager().authorizationStatus
    guard status == .authorizedWhenInUse || status == .authorizedAlways else {
      disarm()
      return
    }
    if #available(iOS 17.0, *) {
      let wantsActivitySession = status == .authorizedWhenInUse || !alwaysConfirmed
      if wantsActivitySession {
        if backgroundActivity == nil { backgroundActivity = CLBackgroundActivitySession() }
      } else if UIApplication.shared.applicationState != .background {
        (backgroundActivity as? CLBackgroundActivitySession)?.invalidate()
        backgroundActivity = nil
      }
    }
    if #available(iOS 18.0, *) {
      if status == .authorizedAlways {
        if alwaysSession == nil {
          let session = CLServiceSession(authorization: .always)
          alwaysSession = session
          observeAlwaysDiagnostics(session)
        }
      } else {
        if alwaysSession != nil {
          (alwaysSession as? CLServiceSession)?.invalidate()
          alwaysSession = nil
          diagnosticsTask?.cancel()
          diagnosticsTask = nil
          alwaysConfirmed = false
        }
      }
    }
  }' '' '' ''
  _tier 'tier: the .always else stops clearing alwaysConfirmed' 1 \
    '  func arm() {
    guard UserDefaults.standard.bool(forKey: Self.kBgSharingKey),
      UserDefaults.standard.bool(forKey: Self.kBgDisclosureKey)
    else {
      disarm()
      return
    }
    let status = CLLocationManager().authorizationStatus
    guard status == .authorizedWhenInUse || status == .authorizedAlways else {
      disarm()
      return
    }
    if #available(iOS 17.0, *) {
      let wantsActivitySession = status == .authorizedWhenInUse || !alwaysConfirmed
      if wantsActivitySession {
        if backgroundActivity == nil { backgroundActivity = CLBackgroundActivitySession() }
      } else if UIApplication.shared.applicationState != .background {
        (backgroundActivity as? CLBackgroundActivitySession)?.invalidate()
        backgroundActivity = nil
      }
    }
    if #available(iOS 18.0, *) {
      if status == .authorizedAlways {
        if alwaysSession == nil {
          let session = CLServiceSession(authorization: .always)
          alwaysSession = session
          observeAlwaysDiagnostics(session)
        }
      } else {
        (alwaysSession as? CLServiceSession)?.invalidate()
        alwaysSession = nil
        diagnosticsTask?.cancel()
        diagnosticsTask = nil
      }
    }
  }' '' '' ''
  _tier 'tier: alwaysConfirmed forced true by a literal' 1 '' '' '' \
    '  func assumeAlways() {
    alwaysConfirmed = true
  }'
  # disarm() is UNCONDITIONAL. It runs on opt-out — usually while the app is
  # PAUSED, where no rebuild can run — and on identity deletion.
  _tier 'tier: disarm() gated on the persisted consent' 1 '' '' \
    '  func disarm() {
    guard !UserDefaults.standard.bool(forKey: Self.kBgSharingKey) else { return }
    if #available(iOS 17.0, *) {
      (backgroundActivity as? CLBackgroundActivitySession)?.invalidate()
    }
    backgroundActivity = nil
    if #available(iOS 18.0, *) {
      (alwaysSession as? CLServiceSession)?.invalidate()
    }
    alwaysSession = nil
    diagnosticsTask?.cancel()
    diagnosticsTask = nil
    alwaysConfirmed = false
  }' ''
  _tier 'tier: disarm() gated on the app lifecycle' 1 '' '' \
    '  func disarm() {
    guard UIApplication.shared.applicationState != .background else { return }
    if #available(iOS 17.0, *) {
      (backgroundActivity as? CLBackgroundActivitySession)?.invalidate()
    }
    backgroundActivity = nil
    if #available(iOS 18.0, *) {
      (alwaysSession as? CLServiceSession)?.invalidate()
    }
    alwaysSession = nil
    diagnosticsTask?.cancel()
    diagnosticsTask = nil
    alwaysConfirmed = false
  }' ''
  _tier 'tier: disarm() stops nilling the service session' 1 '' '' \
    '  func disarm() {
    if #available(iOS 17.0, *) {
      (backgroundActivity as? CLBackgroundActivitySession)?.invalidate()
    }
    backgroundActivity = nil
    if #available(iOS 18.0, *) {
      (alwaysSession as? CLServiceSession)?.invalidate()
    }
    diagnosticsTask?.cancel()
    diagnosticsTask = nil
    alwaysConfirmed = false
  }' ''
  _tier 'tier: disarm() leaves a stale alwaysConfirmed behind' 1 '' '' \
    '  func disarm() {
    if #available(iOS 17.0, *) {
      (backgroundActivity as? CLBackgroundActivitySession)?.invalidate()
    }
    backgroundActivity = nil
    if #available(iOS 18.0, *) {
      (alwaysSession as? CLServiceSession)?.invalidate()
    }
    alwaysSession = nil
    diagnosticsTask?.cancel()
    diagnosticsTask = nil
  }' ''
  _tier 'tier: the handler starts logging' 1 '' '' '' \
    '  private func trace() {
    NSLog("[HavenBGSession] armed")
  }'
  # Anti-vacuity.
  local tier_none=0
  cat >"${tmp}/HavenBackgroundSessionHandler.swift" <<'EOF'
// final class HavenBackgroundSessionHandler: NSObject {
//   func arm() {
//     guard UserDefaults.standard.bool(forKey: Self.kBgSharingKey) else { disarm(); return }
//     let wantsActivitySession = status == .authorizedWhenInUse || !alwaysConfirmed
//     if wantsActivitySession { backgroundActivity = CLBackgroundActivitySession() }
//   }
//   func disarm() { backgroundActivity = nil; alwaysSession = nil }
// }
EOF
  ( check_arm_tier_policy "${tmp}/HavenBackgroundSessionHandler.swift" ) >/dev/null 2>&1 || tier_none=$?
  _record 'tier: the whole handler commented out' 1 "${tier_none}"

  # --- check_bg_publish_drive -----------------------------------------------
  #
  # The lane's own vacuity guard. A fake at either layer, or a READY signal
  # that beats the session into existence, turns a runtime proof into a
  # measurement of a frozen process (CI runs 32646436116 and 32661622879).
  #
  # The two receive phases sit SIDE BY SIDE here rather than in the
  # `liveSyncEnabled` branch the real target uses. This fixture is not a valid
  # drive and does not have to be: every read in this check is per-symbol or an
  # ordering between two lines, and both orderings hold in this shape. Keeping
  # it flat is what lets each mutant below be one substitution.
  local drive_good='void main() {
  testWidgets("P1", (tester) async {
    await tester.pumpWidget(const HavenApp());
    await container.read(backgroundSharingProvider.notifier).setEnabled(enabled: true);
    await tester.pump();
    await pumpUntilCondition(tester, () => container.read(locationStreamProvider).hasValue);
    final standing = await engine.poolSubscriptionCount();
    await _pollPoolSubscriptions(engine, window, wanted: (count) => count > 0);
    debugPrint(kReadyForBackgroundMarker);
    await peer.publishLocation(relay: relay);
    final quiet = await _pollPoolSubscriptions(engine, window, wanted: (count) => count == 0);
    expect(quiet.matched, isTrue, reason: "a standing REQ survived the burst");
    debugPrint(kBackgroundReceiveMarker);
    final rows = await circleService.snapshotLastKnownForCircle(nostrGroupId: gid);
    final catchup = firstFrom(rows, peer.pubkeyHex);
    expect(catchup.fix, isNotNull, reason: "the sweep landed nothing");
    debugPrint(kBackgroundCatchupMarker);
  });
}'

  _drive() { # <label> <want-rc> <body>
    local got=0
    printf '%s\n' "$3" >"${tmp}/ios_bg_publish_test.dart"
    ( check_bg_publish_drive "${tmp}/ios_bg_publish_test.dart" ) >/dev/null 2>&1 || got=$?
    _record "$1" "$2" "${got}"
  }

  _drive 'drive: today'"'"'s target passes' 0 "${drive_good}"
  _drive 'drive: the location service faked' 1 \
    "${drive_good/await tester.pumpWidget(const HavenApp());/locationServiceProvider.overrideWithValue(FakeLocationService()),}"
  # The same hole one layer down: the production service is in place, but a
  # faked source subscribes to no EventChannel, so no CLLocationManager exists.
  _drive 'drive: the iOS location SOURCE faked' 1 \
    "${drive_good/await tester.pumpWidget(const HavenApp());/iosLocationSourceProvider.overrideWithValue(const NoopIosLocationSource()),}"
  _drive 'drive: READY signalled before the toggle is enabled' 1 \
    'void main() {
  testWidgets("P1", (tester) async {
    debugPrint(kReadyForBackgroundMarker);
    await container.read(backgroundSharingProvider.notifier).setEnabled(enabled: true);
    await tester.pump();
    await pumpUntilCondition(tester, () => container.read(locationStreamProvider).hasValue);
  });
}'
  _drive 'drive: a bare pump with nothing waiting on the rebuilt stream' 1 \
    'void main() {
  testWidgets("P1", (tester) async {
    await container.read(backgroundSharingProvider.notifier).setEnabled(enabled: true);
    await tester.pump();
    debugPrint(kReadyForBackgroundMarker);
  });
}'

  # --- P2c's oracle. Each mutant below leaves a drive that still prints every
  #     terminal proof, so the completion gate, the wrapper's fixtures and the
  #     lane itself all stay green while the receive half proves nothing.
  #
  #     The first is the one this check exists for: `isPaused` is raised as the
  #     FIRST statement of the engine's pause, so a drive reading it observes
  #     "not subscribed" through a pause that dropped no REQ at all.
  _drive 'drive: the P2c oracle swapped for isPaused' 1 \
    "${drive_good/await engine.poolSubscriptionCount();/engine.isPaused ? 0 : 1;}"
  # Non-vacuity for the ban: the swap is caught by the READ, not by the word
  # appearing somewhere. A drive that merely NAMES the flag in a failure
  # reason — which the real one does, at length — must still pass.
  _drive 'drive: isPaused named only inside a string passes' 0 \
    "${drive_good/debugPrint(kBackgroundReceiveMarker);/expect(n, isZero, reason: \"isPaused would have said yes here\");
    debugPrint(kBackgroundReceiveMarker);}"
  # The control arm dropped: the between-bursts assertion then passes on an
  # engine that never subscribed to anything — including a lane compiled
  # without the receive engine at all.
  _drive 'drive: the non-zero control arm dropped' 1 \
    "${drive_good/wanted: (count) => count > 0/wanted: (count) => true}"
  # …and the promise itself, replaced by a predicate every state satisfies.
  _drive 'drive: the zero-subscription wait dropped' 1 \
    "${drive_good/wanted: (count) => count == 0/wanted: (count) => true}"
  # The verdict never asserted: `_pollPoolSubscriptions` RETURNS on its
  # deadline with whatever it last read, so a drive that drops the `expect`
  # keeps a bounded wait and loses the oracle — and prints the terminal proof
  # over it.
  _drive 'drive: the between-bursts verdict never asserted' 1 \
    "${drive_good/    expect(quiet.matched, isTrue, reason: \"a standing REQ survived the burst\");
/}"
  # The terminal proof printed ahead of the whole poll: the completion gate
  # would accept a body that returned early (A3b).
  _drive 'drive: the receive marker printed above the between-bursts poll' 1 \
    "${drive_good/    final quiet = await _pollPoolSubscriptions(engine, window, wanted: (count) => count == 0);/    debugPrint(kBackgroundReceiveMarker);
    final quiet = await _pollPoolSubscriptions(engine, window, wanted: (count) => count == 0);}"
  # …and the same proof moved only PAST the poll but still ahead of the
  # assertion. This is the mutant an ordering pin anchored on the poll's
  # `count == 0` predicate accepts: the marker sits after the predicate and
  # before the claim, which is exactly the early return A3b describes.
  _drive 'drive: the receive marker printed between the poll and its assertion' 1 \
    "${drive_good/    expect(quiet.matched, isTrue, reason: \"a standing REQ survived the burst\");
    debugPrint(kBackgroundReceiveMarker);/    debugPrint(kBackgroundReceiveMarker);
    expect(quiet.matched, isTrue, reason: \"a standing REQ survived the burst\");}"
  # …and deleted outright, which the wrapper would report as an absent proof
  # without naming the phase that lost it.
  _drive 'drive: the receive marker deleted' 1 \
    "${drive_good/debugPrint(kBackgroundReceiveMarker);/}"

  # --- …and the same three reads, surviving ONLY as prose about themselves.
  #     Each mutant below deletes the real thing and leaves a `reason:` string
  #     naming it — the shape a scan over the comment-only view accepts, and
  #     the reason every read in this section is taken off the string-stripped
  #     one. They are not hypothetical: this drive's reasons quote all three
  #     predicates already.
  _drive 'drive: the count read survives only inside a reason string' 1 \
    "${drive_good/final standing = await engine.poolSubscriptionCount();/expect(standing, isNotNull, reason: \"read through poolSubscriptionCount()\");}"
  _drive 'drive: the control arm survives only inside a reason string' 1 \
    "${drive_good/await _pollPoolSubscriptions(engine, window, wanted: (count) => count > 0);/expect(standing, isNotNull, reason: \"the foreground read must be count > 0\");}"
  _drive 'drive: the zero-count wait survives only inside a reason string' 1 \
    "${drive_good/final quiet = await _pollPoolSubscriptions(engine, window, wanted: (count) => count == 0);/final quiet = observation(reason: \"this phase wants count == 0\");}"

  # --- P2d's oracle, the poll leg's half (OD4-d). Every mutant below leaves a
  #     drive that still prints all of the live-sync leg's proofs, so nothing
  #     else in the repo notices: the poll leg is the ONLY runtime proof that
  #     the poll path's background receive timer fires at all, and it has no
  #     wire oracle here either.
  #
  #     The store read first, because the choice of store over the in-memory
  #     member cache looks arbitrary and is not: `cachedLocations` re-reads the
  #     store only for a circle it has not hydrated, this circle was hydrated in
  #     the foreground, and the catch-up sweep writes the store from Rust — so a
  #     drive switched to the cache reports an absence for a sweep that worked,
  #     on every run.
  _drive 'drive: the P2d store read replaced by the member cache' 1 \
    "${drive_good/final rows = await circleService.snapshotLastKnownForCircle(nostrGroupId: gid);/final rows = await sharing.cachedLocations(circle);}"
  # …and surviving only as prose about itself, the same way the P2c reads can.
  _drive 'drive: the P2d store read survives only inside a reason string' 1 \
    "${drive_good/final rows = await circleService.snapshotLastKnownForCircle(nostrGroupId: gid);/expect(rows, isNotNull, reason: \"read via snapshotLastKnownForCircle()\");}"
  # The verdict never asserted: `_pollForStoredPeerFix` RETURNS on its deadline
  # with whatever it last read — a null fix included — so a drive that drops the
  # `expect` keeps a bounded wait, loses the oracle, and prints the terminal
  # proof over it.
  _drive 'drive: the P2d catch-up verdict never asserted' 1 \
    "${drive_good/    expect(catchup.fix, isNotNull, reason: \"the sweep landed nothing\");
/}"
  # The terminal proof ahead of the assertion it stands for: the completion gate
  # would accept a body that returned early (A3b).
  _drive 'drive: the catchup marker printed above its own assertion' 1 \
    "${drive_good/    expect(catchup.fix, isNotNull, reason: \"the sweep landed nothing\");
    debugPrint(kBackgroundCatchupMarker);/    debugPrint(kBackgroundCatchupMarker);
    expect(catchup.fix, isNotNull, reason: \"the sweep landed nothing\");}"
  # …and deleted outright, which the wrapper would report as an absent proof
  # without naming the phase that lost it.
  _drive 'drive: the catchup marker deleted' 1 \
    "${drive_good/debugPrint(kBackgroundCatchupMarker);/}"

  # --- check_bg_publish_timeout_ladder --------------------------------------
  #
  # The rung `check_e2e_step_timeout_ordering.sh` cannot see: the drive's own
  # `Timeout` against the retry's per-attempt deadline. Both files document
  # the coupling in prose; these fixtures are what make it enforced.
  local ladder_drive='void main() {
  testWidgets("bg publish", (tester) async {}, timeout: const Timeout(Duration(minutes: 40)));
}'
  local ladder_wf='jobs:
  e2e_ios_bg_publish:
    timeout-minutes: 175
    steps:
      - name: Run the lane
        timeout-minutes: 135
        uses: nick-fields/retry@v3
        with:
          timeout_minutes: 65
          max_attempts: 2'
  _ladder() { # <label> <want-rc> <drive text> <workflow text>
    local got=0
    printf '%s\n' "$3" >"${tmp}/ladder_drive.dart"
    printf '%s\n' "$4" >"${tmp}/ladder_workflow.yml"
    ( check_bg_publish_timeout_ladder \
        "${tmp}/ladder_drive.dart" "${tmp}/ladder_workflow.yml" ) \
      >/dev/null 2>&1 || got=$?
    _record "$1" "$2" "${got}"
  }
  _ladder 'ladder: 40m drive inside a 65m attempt passes' 0 \
    "${ladder_drive}" "${ladder_wf}"
  # The unpaired raise this check exists for: a new phase widens the drive's
  # Timeout and the attempt deadline stays put, so the retry kills the attempt
  # before the bound that would have named the test.
  _ladder 'ladder: the drive Timeout raised without the attempt deadline' 1 \
    "${ladder_drive/minutes: 40/minutes: 50}" "${ladder_wf}"
  # …and the mirror image: the attempt deadline cut under a drive that did not
  # move.
  _ladder 'ladder: the attempt deadline cut under an unchanged drive' 1 \
    "${ladder_drive}" "${ladder_wf/timeout_minutes: 65/timeout_minutes: 55}"
  # Exactly at the overhead is the passing edge — the bound is "clears it",
  # not "clears it comfortably", and a fixture on the edge is what stops the
  # constant drifting on feel.
  _ladder 'ladder: exactly the derived overhead passes' 0 \
    "${ladder_drive}" "${ladder_wf/timeout_minutes: 65/timeout_minutes: 62}"
  _ladder 'ladder: one minute inside the derived overhead is REFUSED' 1 \
    "${ladder_drive}" "${ladder_wf/timeout_minutes: 65/timeout_minutes: 61}"
  # Fail CLOSED on either end going missing: a drive with no Timeout inherits
  # flutter_test's 30 s default, and a retry step with no deadline bounds
  # nothing at all.
  _ladder 'ladder: a drive with no Timeout is REFUSED' 1 \
    'void main() { testWidgets("bg publish", (tester) async {}); }' "${ladder_wf}"
  _ladder 'ladder: a retry step with no timeout_minutes is REFUSED' 1 \
    "${ladder_drive}" "${ladder_wf/          timeout_minutes: 65
/}"
  # Non-vacuity for the parser: a Timeout that lives only in a COMMENT is not
  # a Timeout. `code_view` is what makes that true, and nothing else here
  # exercises it on this file.
  _ladder 'ladder: a commented-out drive Timeout is REFUSED' 1 \
    'void main() {
  // timeout: const Timeout(Duration(minutes: 40)),
  testWidgets("bg publish", (tester) async {});
}' "${ladder_wf}"

  # --- …and the PER-LEG form the lane actually ships since OD4-d: both ends of
  #     the ladder are expressions, one value per leg, compared in source order.
  local ladder_drive_legs='void main() {
  testWidgets("bg publish", (tester) async {},
      timeout: const Timeout(Duration(minutes: liveSyncEnabled ? 40 : 37)));
}'
  # Written out rather than substituted into `ladder_wf`: the replacement text
  # would contain `}`, which bash's `${var/pat/repl}` ends the expansion on, and
  # the result would be a MALFORMED fixture that still happens to yield two
  # numbers — a fixture passing for the wrong reason.
  local ladder_wf_legs='jobs:
  e2e_ios_bg_publish:
    timeout-minutes: ${{ matrix.live_sync == '"'"'true'"'"' && 175 || 169 }}
    steps:
      - name: Run the lane
        timeout-minutes: ${{ matrix.live_sync == '"'"'true'"'"' && 135 || 129 }}
        uses: nick-fields/retry@v3
        with:
          timeout_minutes: ${{ matrix.live_sync == '"'"'true'"'"' && 65 || 62 }}
          max_attempts: 2'
  _ladder 'ladder: the per-leg form passes on BOTH legs' 0 \
    "${ladder_drive_legs}" "${ladder_wf_legs}"
  # The mistake this form makes possible, and the one a first-value-only check
  # would miss entirely: a leg added with its own drive Timeout and its retry
  # deadline copied from the sibling. Leg #1 still clears the overhead.
  _ladder 'ladder: only the SECOND leg inverted is still REFUSED' 1 \
    "${ladder_drive_legs/liveSyncEnabled ? 40 : 37/liveSyncEnabled ? 40 : 45}" \
    "${ladder_wf_legs}"
  # A count mismatch is itself the defect: one end made per-leg while the other
  # stayed scalar means one leg is bounded by the other leg's ladder, and the
  # arithmetic would still "pass" against whichever value came first.
  _ladder 'ladder: per-leg drive against a scalar attempt deadline is REFUSED' 1 \
    "${ladder_drive_legs}" "${ladder_wf}"
  _ladder 'ladder: scalar drive against per-leg attempt deadlines is REFUSED' 1 \
    "${ladder_drive}" "${ladder_wf_legs}"
  # --- …and the POLARITY the positional pairing rests on. Both fixtures keep
  #     every arithmetic pair clearing the overhead (65-40 and 62-37, or 65-37
  #     and 62-40 — 25/25 and 28/22), so the ONLY thing that can red them is the
  #     condition. This is the hole the count check leaves: equal counts with
  #     inverted conditions means each leg is bounded by the other leg's
  #     deadline, and the live-sync leg ends up holding the poll leg's 37 m
  #     Timeout against its own ~38 m phase sum.
  _ladder 'ladder: the drive leg condition negated is REFUSED' 1 \
    "${ladder_drive_legs/minutes: liveSyncEnabled ?/minutes: !liveSyncEnabled ?}" \
    "${ladder_wf_legs}"
  # Written out with ONLY the retry deadline flipped, and the job cap and step
  # cap left on `==`: that is both the realistic mistake (one expression edited)
  # and the proof that the polarity is read off the `timeout_minutes:` line
  # itself rather than off any `matrix.live_sync == 'true'` in the file.
  local ladder_wf_legs_flipped='jobs:
  e2e_ios_bg_publish:
    timeout-minutes: ${{ matrix.live_sync == '"'"'true'"'"' && 175 || 169 }}
    steps:
      - name: Run the lane
        timeout-minutes: ${{ matrix.live_sync == '"'"'true'"'"' && 135 || 129 }}
        uses: nick-fields/retry@v3
        with:
          timeout_minutes: ${{ matrix.live_sync != '"'"'true'"'"' && 65 || 62 }}
          max_attempts: 2'
  _ladder 'ladder: the retry deadline condition negated is REFUSED' 1 \
    "${ladder_drive_legs}" "${ladder_wf_legs_flipped}"

  # --- check_poll_path_receive_cadence ---------------------------------------
  #
  # The poll path's background receive cadence lives twice: as an inline
  # `Timer.periodic` literal in map_shell.dart and as `_pollPathReceiveInterval`
  # in the drive, which derives P2d's whole window from it (two ticks — the
  # second is the same-second cursor race). A drift makes that window span one
  # tick where the derivation needs two, and the resulting failure is a FLAKE:
  # the ordinary interleaving still passes. Nothing else compares the two, and
  # the lane cannot — it would have to hit the race to notice.
  local cadence_shell='class _MapShellState {
  void _startTimers() {
    _receiveTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      ref.invalidate(memberLocationsProvider);
    });
  }

  void _startIosBackgroundReceiveTimer() {
    if (liveSyncEnabled) return;
    _receiveTimer = Timer.periodic(const Duration(seconds: 90), (_) {
      if (!mounted) return;
      final now = DateTime.now();
      if (_lastLocationFetchTime != null &&
          now.difference(_lastLocationFetchTime!) <=
              const Duration(seconds: 80)) {
        return;
      }
      _lastLocationFetchTime = now;
      unawaited(_runBackgroundCatchUp());
    });
  }
}'
  # The three gutted shapes are written out rather than substituted into
  # `cadence_shell`: the text to remove now spans the whole debounce, and a
  # `${var/pat/repl}` over it has to escape the `}` its own pattern contains —
  # a mis-escape yields a fixture that still parses and passes for the wrong
  # reason, which is the failure mode this file already avoids on `ladder_wf`.
  local cadence_shell_no_bg_timer='class _MapShellState {
  void _startTimers() {
    _receiveTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      ref.invalidate(memberLocationsProvider);
    });
  }
}'
  local cadence_shell_gutted_bg_timer='class _MapShellState {
  void _startTimers() {
    _receiveTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      ref.invalidate(memberLocationsProvider);
    });
  }

  void _startIosBackgroundReceiveTimer() {
    if (liveSyncEnabled) return;
    unawaited(_runBackgroundCatchUp());
  }
}'
  local cadence_shell_no_debounce='class _MapShellState {
  void _startTimers() {
    _receiveTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      ref.invalidate(memberLocationsProvider);
    });
  }

  void _startIosBackgroundReceiveTimer() {
    if (liveSyncEnabled) return;
    _receiveTimer = Timer.periodic(const Duration(seconds: 90), (_) {
      if (!mounted) return;
      _lastLocationFetchTime = DateTime.now();
      unawaited(_runBackgroundCatchUp());
    });
  }
}'
  local cadence_drive='const Duration _pollPathReceiveInterval = Duration(seconds: 90);'
  _cadence() { # <label> <want-rc> <map_shell text> <drive text>
    local got=0
    printf '%s\n' "$3" >"${tmp}/cadence_shell.dart"
    printf '%s\n' "$4" >"${tmp}/cadence_drive.dart"
    ( check_poll_path_receive_cadence \
        "${tmp}/cadence_shell.dart" "${tmp}/cadence_drive.dart" ) \
      >/dev/null 2>&1 || got=$?
    _record "$1" "$2" "${got}"
  }
  _cadence 'cadence: the two copies agreeing passes' 0 \
    "${cadence_shell}" "${cadence_drive}"
  _cadence 'cadence: a product cadence the drive does not know is REFUSED' 1 \
    "${cadence_shell/seconds: 90/seconds: 120}" "${cadence_drive}"
  # The method deleted outright — the mutation check 6 is known to pass over,
  # and the one that removes the poll path's background receive plane entirely.
  _cadence 'cadence: _startIosBackgroundReceiveTimer deleted is REFUSED' 1 \
    "${cadence_shell_no_bg_timer}" "${cadence_drive}"
  _cadence 'cadence: the drive constant gone is REFUSED' 1 \
    "${cadence_shell}" 'const Duration _peerFixWindow = Duration(seconds: 30);'
  # NON-VACUITY for the slice, and the reason it is anchored on the
  # DECLARATION: with the background timer gutted, a file-wide read would find
  # the FOREGROUND receive timer's 30 s first and match a drive that said 30 —
  # certifying a cadence for a plane that no longer exists.
  _cadence 'cadence: the foreground 30s timer cannot answer for it' 1 \
    "${cadence_shell_gutted_bg_timer}" \
    'const Duration _pollPathReceiveInterval = Duration(seconds: 30);'
  # --- …and the TICK DEBOUNCE, the other half of the effective cadence. The
  #     callback returns early while the gap since the last accepted sweep is
  #     `<=` it, so a tick is accepted only when the interval is STRICTLY above
  #     it. Every fixture below keeps the two FILES in agreement, which is what
  #     makes them unreachable for the drift comparison above.
  #
  #     A cadence lowered under the debounce swallows alternate ticks: P2d
  #     derives its window from two ticks and would get one sweep. Both numbers
  #     move together, so nothing else in the tree notices, and the lane's
  #     failure is a FLAKE — the ordinary interleaving still passes.
  _cadence 'cadence: BOTH files lowered under the tick debounce is REFUSED' 1 \
    "${cadence_shell/seconds: 90/seconds: 60}" \
    'const Duration _pollPathReceiveInterval = Duration(seconds: 60);'
  # Equality is the flaky EDGE, not the safe one: the first tick difference IS
  # the interval and the comparison is `<=`, so that tick is swallowed.
  _cadence 'cadence: an interval equal to the tick debounce is REFUSED' 1 \
    "${cadence_shell/seconds: 80/seconds: 90}" "${cadence_drive}"
  # The mirror image — the debounce raised over an interval that did not move.
  _cadence 'cadence: a tick debounce ABOVE the interval is REFUSED' 1 \
    "${cadence_shell/seconds: 80/seconds: 100}" "${cadence_drive}"
  # Fail CLOSED on the anchor going missing. Removing the debounce is in fact
  # SAFE for P2d (the effective gap becomes the interval alone), but a guard
  # that reads nothing is the one thing this repo keeps re-learning: the red
  # says to delete this half deliberately rather than let it go quiet.
  _cadence 'cadence: the tick debounce gone is REFUSED' 1 \
    "${cadence_shell_no_debounce}" "${cadence_drive}"

  # --- check_poll_path_background_wake ---------------------------------------
  #
  # `isBackgroundWake: true` is the whole C3 chokepoint, and it is invisible to
  # everything else: the sweep behaves identically without it, so P2d stays
  # green, the method stays referenced (no unused_element) and every host test
  # that names the flag exercises `CatchupService` directly rather than what
  # `MapShell` passes it.
  local wake_shell='class _MapShellState {
  void _startIosBackgroundReceiveTimer() {
    if (liveSyncEnabled) return;
    _receiveTimer = Timer.periodic(const Duration(seconds: 90), (_) {
      unawaited(_runBackgroundCatchUp());
    });
  }

  Future<void> _runBackgroundCatchUp() async {
    await ref.read(catchupServiceProvider).runCatchup(isBackgroundWake: true);
  }
}'
  _wake() { # <label> <want-rc> <map_shell text>
    local got=0
    printf '%s\n' "$3" >"${tmp}/wake_shell.dart"
    ( check_poll_path_background_wake "${tmp}/wake_shell.dart" ) \
      >/dev/null 2>&1 || got=$?
    _record "$1" "$2" "${got}"
  }
  _wake 'wake: the sweep declaring itself a background wake passes' 0 \
    "${wake_shell}"
  _wake 'wake: the argument dropped is REFUSED' 1 \
    "${wake_shell/runCatchup(isBackgroundWake: true)/runCatchup()}"
  _wake 'wake: an explicit false is REFUSED' 1 \
    "${wake_shell/isBackgroundWake: true/isBackgroundWake: false}"
  _wake 'wake: the method gone is REFUSED' 1 \
    "${wake_shell/  Future<void> _runBackgroundCatchUp() async {
    await ref.read(catchupServiceProvider).runCatchup(isBackgroundWake: true);
  \}
/}"
  # NON-VACUITY for the slice, and the reason it anchors on the DECLARATION: the
  # method's own name appears at the timer call site ABOVE it, so a slice taken
  # from the first match would read the argument out of the timer's body — where
  # a mutation could park a correct-looking call it never makes.
  local wake_hoisted="${wake_shell/      unawaited(_runBackgroundCatchUp());/      unawaited(ref.read(catchupServiceProvider).runCatchup(isBackgroundWake: true));}"
  _wake 'wake: a call site above the declaration cannot answer for it' 1 \
    "${wake_hoisted/runCatchup(isBackgroundWake: true);
  \}/runCatchup();
  \}}"

  # --- check_poll_leg_tier ---------------------------------------------------
  #
  # The poll leg's grant is a correctness constraint on P2d's oracle: the native
  # SLC wake writes the SAME persisted store through the SAME runCatchup, and
  # `.authorizedAlways` is the only thing that arms it. Under `always` the phase
  # still passes and proves less than its text claims — the exact shape a
  # positional matrix edit produces.
  local tier_wf='jobs:
  e2e_ios_bg_publish:
    strategy:
      matrix:
        include:
          - leg: when-in-use-live-sync
            tier: when-in-use
            live_sync: "true"
          - leg: always-live-sync
            tier: always
            live_sync: "true"
          # OD4-d: the rollback path under a real backgrounding.
          - leg: when-in-use-poll
            tier: when-in-use
            live_sync: "false"
    timeout-minutes: 175'
  _tier() { # <label> <want-rc> <workflow text>
    local got=0
    printf '%s\n' "$3" >"${tmp}/tier.yml"
    ( check_poll_leg_tier "${tmp}/tier.yml" ) >/dev/null 2>&1 || got=$?
    _record "$1" "$2" "${got}"
  }
  _tier 'tier: the three shipped legs pass' 0 "${tier_wf}"
  _tier 'tier: the poll leg flipped to always is REFUSED' 1 \
    "${tier_wf/          - leg: when-in-use-poll
            tier: when-in-use/          - leg: when-in-use-poll
            tier: always}"
  # A fourth leg is the likelier edit than a flip, and it must be refused for
  # the same reason rather than for its cost.
  _tier 'tier: an added (always, poll) leg is REFUSED' 1 \
    "${tier_wf/            live_sync: \"false\"/            live_sync: \"false\"
          - leg: always-poll
            tier: always
            live_sync: \"false\"}"
  # The poll leg REMOVED is the OD4-d gap re-opening, and a check that only
  # looked at legs it found would report nothing at all.
  _tier 'tier: no poll leg left at all is REFUSED' 1 \
    "${tier_wf/            live_sync: \"false\"/            live_sync: \"true\"}"
  # Anti-vacuity: a matrix this parser cannot read must FAIL, never pass by
  # finding no rows to object to.
  _tier 'tier: an unparseable matrix is REFUSED' 1 \
    'jobs:
  e2e_ios_bg_publish:
    strategy:
      matrix:
        tier: [when-in-use, always]
    timeout-minutes: 175'
  # The comment strip, in the direction that would produce a FALSE RED: without
  # it `$NF` on this line is the last word of the comment, the leg reads as
  # live_sync `note`, and the shipped matrix would be reported as having no poll
  # leg at all.
  _tier 'tier: a trailing comment on a leg line still parses' 0 \
    "${tier_wf/            live_sync: \"false\"/            live_sync: \"false\" # the rollback path}"
  # …and a poll leg that survives only as a COMMENT is not a leg: the matrix no
  # longer runs one, which is the OD4-d gap re-opening.
  _tier 'tier: a commented-out poll leg is not a leg' 1 \
    "${tier_wf/          - leg: when-in-use-poll
            tier: when-in-use
            live_sync: \"false\"/          # - leg: when-in-use-poll
          #   tier: when-in-use
          #   live_sync: \"false\"}"

  # --- check_pbxproj_stream_handler -----------------------------------------
  #
  # A Swift file absent from the project compiles nowhere and fails as a
  # MissingPluginException the Dart side reads as "no native handler" — i.e. no
  # iOS position stream at all, discovered when peers stop receiving.
  local pbx_good='		5E10CA750000000000000002 /* HavenLocationStreamHandler.swift in Sources */ = {isa = PBXBuildFile; fileRef = 5E10CA750000000000000001 /* HavenLocationStreamHandler.swift */; };
		5E10CA750000000000000001 /* HavenLocationStreamHandler.swift */ = {isa = PBXFileReference; path = HavenLocationStreamHandler.swift; sourceTree = "<group>"; };
				5E10CA750000000000000001 /* HavenLocationStreamHandler.swift */,
				5E10CA750000000000000002 /* HavenLocationStreamHandler.swift in Sources */,'

  _pbx() { # <label> <want-rc> <body>
    local got=0
    printf '%s\n' "$3" >"${tmp}/project.pbxproj"
    ( check_pbxproj_stream_handler "${tmp}/project.pbxproj" ) >/dev/null 2>&1 || got=$?
    _record "$1" "$2" "${got}"
  }

  _pbx 'pbxproj: all four references present' 0 "${pbx_good}"
  # The silent one: the project opens, the file is visible in the navigator,
  # and nothing compiles it.
  _pbx 'pbxproj: the Sources build-phase entry dropped' 1 \
    '		5E10CA750000000000000002 /* HavenLocationStreamHandler.swift in Sources */ = {isa = PBXBuildFile; fileRef = 5E10CA750000000000000001 /* HavenLocationStreamHandler.swift */; };
		5E10CA750000000000000001 /* HavenLocationStreamHandler.swift */ = {isa = PBXFileReference; path = HavenLocationStreamHandler.swift; sourceTree = "<group>"; };
				5E10CA750000000000000001 /* HavenLocationStreamHandler.swift */,'
  _pbx 'pbxproj: the file never added at all' 1 \
    '		97C146EC1CF9000F007C117D /* Resources */ = {isa = PBXResourcesBuildPhase; };'
  # Four mentions is not four LIVE references: the ids are what tie the source
  # file to the Sources phase.
  _pbx 'pbxproj: four mentions but the object ids renamed' 1 \
    '		DEADBEEF00000000000000002 /* HavenLocationStreamHandler.swift in Sources */ = {isa = PBXBuildFile; fileRef = DEADBEEF00000000000000001 /* HavenLocationStreamHandler.swift */; };
		DEADBEEF00000000000000001 /* HavenLocationStreamHandler.swift */ = {isa = PBXFileReference; path = HavenLocationStreamHandler.swift; sourceTree = "<group>"; };
				DEADBEEF00000000000000001 /* HavenLocationStreamHandler.swift */,
				DEADBEEF00000000000000002 /* HavenLocationStreamHandler.swift in Sources */,'

  # --- check_p3_host_wire_oracle --------------------------------------------
  #
  # Every fixture below leaves all four files readable and internally sensible
  # — the failure this guard exists for is not a broken file, it is two
  # oracles that quietly stopped measuring the same thing, a counting oracle
  # whose premise was moved out from under it, or an excuse that grew. The two
  # anti-vacuity directions are here too: an unreadable window term and a
  # wrapper with no real-run boundary must FAIL rather than pass over nothing.
  local p3_constants='const Duration kLocationPublishMaxInterval = Duration(seconds: 168);'
  local p3_drive='const int _inFlightGraceSecs = 10;
final Duration _negativeSettleWindow =
    kLocationPublishMaxInterval + const Duration(seconds: 32);
Future<void> body() async {
  await bob.dispose();
  await bgNotifier.setEnabled(enabled: false);
}'
  local p3_probe='int verdict(ProbeReading reading) {
  if (reading.controlCount <= 0) {
    return 4;
  }
  if (reading.preDisableCount <= 0) {
    return 4;
  }
  return 0;
}
void count(int createdAt) {
  if (createdAt >= since && createdAt <= until) {
    windowCount++;
  }
}'
  local p3_wrapper='readonly SETTLE_WINDOW_SECS=200
readonly LEAK_GRACE_SECS=10
bgp_unexcused_proofs() {
  printf '"'"'%s\n'"'"' "${missing}" \
    | grep -vFx -e "${SILENCE_MARKER}" -e "${DISARMED_MARKER}" || true
}
# Real run
if [[ -z "${DART_BIN}" ]]; then
  exit 2
fi
if ! PROBE_SELFTEST="$("${DART_BIN}" "${WIRE_PROBE}" --self-test 2>&1)"; then
  exit 2
fi
    P3_HOST_VERDICT="$(bgp_p3_host_verdict "${DISABLE_RC}" \
      "${DRIVE_EXIT_APP_STATE}" "${APP_STATE_AT_WINDOW_END}" "${WIRE_RC}")"
    if (( RECLAIMED_INSIDE_WINDOW == 1 )); then
      case "${P3_HOST_VERDICT}" in
        holds)
          P3_PROVEN_BY_HOST=1
          ;;
      esac
    fi'

  _p3oracle() { # <label> <want-rc> <wrapper> <probe> <drive> <constants>
    local got=0
    printf '%s\n' "$3" >"${tmp}/run-ios-bg-publish.sh"
    printf '%s\n' "$5" >"${tmp}/ios_bg_publish_test.dart"
    printf '%s\n' "$6" >"${tmp}/location.dart"
    rm -f "${tmp}/bgp-wire-probe.dart"
    if [[ -n "$4" ]]; then
      printf '%s\n' "$4" >"${tmp}/bgp-wire-probe.dart"
    fi
    ( check_p3_host_wire_oracle "${tmp}/run-ios-bg-publish.sh" \
        "${tmp}/bgp-wire-probe.dart" "${tmp}/ios_bg_publish_test.dart" \
        "${tmp}/location.dart" ) >/dev/null 2>&1 || got=$?
    _record "$1" "$2" "${got}"
  }

  _p3oracle 'p3 oracle: the wired shape passes' 0 \
    "${p3_wrapper}" "${p3_probe}" "${p3_drive}" "${p3_constants}"
  # 168+32 is 200; a wrapper that says 210 measures ten seconds the drive does
  # not, and both oracles still look perfectly reasonable on their own.
  _p3oracle 'p3 oracle: the settle window drifts between the two oracles' 1 \
    "${p3_wrapper/SETTLE_WINDOW_SECS=200/SETTLE_WINDOW_SECS=210}" \
    "${p3_probe}" "${p3_drive}" "${p3_constants}"
  _p3oracle 'p3 oracle: the in-flight grace drifts' 1 \
    "${p3_wrapper/LEAK_GRACE_SECS=10/LEAK_GRACE_SECS=12}" \
    "${p3_probe}" "${p3_drive}" "${p3_constants}"
  # The premise of counting EVERY kind-445: the peer must already be gone.
  _p3oracle 'p3 oracle: the peer is disposed AFTER the disable' 1 \
    "${p3_wrapper}" "${p3_probe}" \
    'const int _inFlightGraceSecs = 10;
final Duration _negativeSettleWindow =
    kLocationPublishMaxInterval + const Duration(seconds: 32);
Future<void> body() async {
  await bgNotifier.setEnabled(enabled: false);
  await bob.dispose();
}' "${p3_constants}"
  _p3oracle 'p3 oracle: the probe loses the window'"'"'s upper bound' 1 \
    "${p3_wrapper}" "${p3_probe/ \&\& createdAt <= until/}" \
    "${p3_drive}" "${p3_constants}"
  _p3oracle 'p3 oracle: the probe loses its control arm' 1 \
    "${p3_wrapper}" "${p3_probe/reading.controlCount <= 0/false}" \
    "${p3_drive}" "${p3_constants}"
  # The SECOND control, dropped on its own. A relay that answers kind-30443 and
  # serves no kind-445 satisfies the first one perfectly while proving nothing
  # about the kind P3's window is read for.
  _p3oracle 'p3 oracle: the probe loses its pre-disable 445 control' 1 \
    "${p3_wrapper}" "${p3_probe/reading.preDisableCount <= 0/false}" \
    "${p3_drive}" "${p3_constants}"
  _p3oracle 'p3 oracle: the preflight stops proving the instrument' 1 \
    "${p3_wrapper/\"\$\{DART_BIN\}\" \"\$\{WIRE_PROBE\}\" --self-test/\"\$\{DART_BIN\}\" --version}" \
    "${p3_probe}" "${p3_drive}" "${p3_constants}"
  # A second assignment is the mutation that matters: the flag would then be
  # set on a run whose verdict was never `holds`.
  _p3oracle 'p3 oracle: the proven flag gains a second source' 1 \
    "${p3_wrapper}
P3_PROVEN_BY_HOST=1" "${p3_probe}" "${p3_drive}" "${p3_constants}"
  _p3oracle 'p3 oracle: the completion-gate excuse widens' 1 \
    "${p3_wrapper/-e \"\$\{DISARMED_MARKER\}\" || true/-e \"\$\{DISARMED_MARKER\}\" -e \"\$\{ARMED_MARKER\}\" || true}" \
    "${p3_probe}" "${p3_drive}" "${p3_constants}"
  # The excuse is the ONE assertion read from the whole file rather than the
  # real-run section, so it is the one that has to prove it reads CODE: a
  # wrapper that keeps the line only as a comment excuses nothing at runtime
  # and must not pass here.
  _p3oracle 'p3 oracle: the excuse surviving only as a comment is not the excuse' 1 \
    "${p3_wrapper/    | grep -vFx/    # | grep -vFx}" \
    "${p3_probe}" "${p3_drive}" "${p3_constants}"
  _p3oracle 'p3 oracle: the probe file is gone' 1 \
    "${p3_wrapper}" '' "${p3_drive}" "${p3_constants}"
  # Anti-vacuity, both directions.
  # `${var/#…}` would anchor to the start of the string, so the boundary is
  # broken by renaming it rather than by a pattern that begins with `#`.
  _p3oracle 'p3 oracle: a wrapper with no real-run boundary is refused' 1 \
    "${p3_wrapper/Real run/Real ran}" "${p3_probe}" "${p3_drive}" \
    "${p3_constants}"
  _p3oracle 'p3 oracle: an unreadable window term is refused' 1 \
    "${p3_wrapper}" "${p3_probe}" "${p3_drive}" \
    'const Duration kPublishMaxInterval = Duration(seconds: 168);'

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
echo "OK: iOS background publish invariants hold (plist mode, one stream boundary per platform, toggle-keyed iOS route with a background branch that cannot fall through to the one-shot, native owner's session shape + two accuracy tiers + sink-only refusals + transient-error filter + only-Best cache in all three copies, bounded anchor staleness in both the controller and the serving path, fail-closed background-launch provider guard, C4 watcher + its opt-out release issued on every path, burst plane entered only from the running process and native wakes with one receive-only door into Dart, presence-only logs, tier-based session/indicator policy with a session-scoped confirmation and an unconditional disarm, AppDelegate wiring order, unfaked bg-publish drive, background-capable stream established before the drive backgrounds the app, P2c's receive oracle read from the subscription count and never from the paused flag and P2d's from the persisted last-known store, each with its terminal proof printed after the assertion it stands for, relaunch region coupled to SLC, stream handler compiled into the Xcode project, every leg's drive Timeout inside its own per-attempt retry deadline, one poll-path receive cadence across the product and the drive, the poll path's sweep declaring itself a background wake so the C3 consent chokepoint applies, every poll leg held at the when-in-use grant P2d's attribution depends on, and P3's settle window measured by the same numbers from both sides with a host-side wire oracle that outlives the app, two controls it cannot read nothing through — one that the relay answers at all, one that it still serves the kind the window is read for — and a completion-gate excuse of exactly two markers from exactly one source)."
