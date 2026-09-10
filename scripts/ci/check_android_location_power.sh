#!/usr/bin/env bash
# CI guard: the UI isolate must not hold a location registration while the app
# is backgrounded (Android), and the release must not depend on a frame.
#
# What is being pinned, and why nothing else can pin it:
#
#   The map's position stream is a plugin subscription the UI isolate owns. On
#   Android that registration is 1 Hz / 1 m, the foreground service owns
#   background publishing, and nothing cancels the UI registration when the app
#   goes away — so a backgrounded Haven kept GNSS busy for a map nobody was
#   looking at. The fix is a DIRECT, synchronous
#   `GeolocatorLocationService.suspendStream()` call from `MapShell._onPaused`.
#
#   It cannot ride a provider rebuild. Flutter disables frames BEFORE the
#   lifecycle observers run, and Riverpod defers a rebuild into a frame, so a
#   release expressed as a `ref.watch`/`ref.invalidate` happens at RESUME —
#   i.e. never, for the whole window that matters. That failure is invisible:
#   the app looks correct, the map works, and the only symptom is battery.
#
#   And the ORDER is load-bearing: the Android pause hands publishing to the
#   foreground service with `markForegroundActive(active: false)`. Releasing
#   GPS after that write leaves two isolates holding location clients at once.
#
# Both are one-line reorders away from being wrong again, and neither has a
# runtime oracle on a host test runner — hence a source guard.
#
# Usage:
#   check_android_location_power.sh              # check the tree
#   check_android_location_power.sh --self-test  # hermetic fixtures, no repo
#                                                # read
#
# Check numbering follows the Android power-efficiency list:
#
#   (1) the plugin's PERMANENT wake lock is still held (`allowWakeLock` unset)
#   (2) Haven's SCOPED `Haven:publish` lock exists, is bounded natively, and is
#       never released by the plugin's Kotlin lifecycle listeners
#   (3) the manifest declares WAKE_LOCK in its own right
#   (4) exactly two files under haven/lib ask the plugin for a position stream
#   (5) every registration is issued from the publish cycle, below the
#       current-consent gate and BOTH the ownership and disclosure gates, and
#       onDestroy releases it before it drains
#   (6) the foreground-service stream profile is the duty-cycled one
#   (7)+(8) the UI isolate releases its registration at pause, in order
#
# Checks 1-3 are the only automated statement about `PublishWakeLock.kt` there
# is: this repository has no JVM test runner, so nothing executes that file
# outside the e2e lanes. Deleting a check here does not weaken a proof, it
# removes the last one.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
MAP_SHELL="${REPO_ROOT}/haven/lib/src/pages/map_shell.dart"
FGS_MANAGER="${REPO_ROOT}/haven/lib/src/services/background_location_manager.dart"
KOTLIN_DIR="${REPO_ROOT}/haven/android/app/src/main/kotlin/com/oblivioustech/haven"
PUBLISH_WAKE_LOCK="${KOTLIN_DIR}/PublishWakeLock.kt"
HAVEN_APPLICATION="${KOTLIN_DIR}/HavenApplication.kt"
MANIFEST="${REPO_ROOT}/haven/android/app/src/main/AndroidManifest.xml"
LIB_DIR="${REPO_ROOT}/haven/lib"
BG_TASK="${REPO_ROOT}/haven/lib/src/services/background_location_task.dart"
LOCATION_SERVICE="${REPO_ROOT}/haven/lib/src/services/geolocator_location_service.dart"

FAILED=0

# Failure sink for the function-shaped checks, so --self-test can drive them
# against fixture files and assert on the returned code.
_lf=0
lfail() {
  echo "FAIL: $*" >&2
  _lf=1
}

# --- comment-aware matching helpers (same shape as check_ios_background_publish.sh)
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

# Prints `<condition>\t<governed statement or block>` for the nearest `if (`
# that OPENS before the first occurrence of <needle> in the flattened <body>.
#
# Balancing rather than slicing by position is the whole point: a guard that
# only checked "the text between the last `if (` and the call starts with the
# keep rule" passes for
#
#   if (!shouldKeepLocationStreamWhilePaused(...)) { _log(); }
#   locationService?.suspendStream();
#
# which releases the stream UNCONDITIONALLY — killing the iOS background
# session and ending background publishing — while reading like the rule is
# still in force. Only containment can tell the two apart.
#
# Both Dart forms are handled: a braced block, and a single unbraced statement
# (`if (!bgEnabled) foo();`), which the repo uses for one-liners.
guarded_slice() { # <flat-body> <needle>
  awk -v flat="$1" -v needle="$2" '
    BEGIN {
      n = index(flat, needle)
      if (n == 0) exit
      head = substr(flat, 1, n - 1)
      p = 0
      while ((k = index(substr(head, p + 1), "if (")) > 0) p += k
      if (p == 0) exit                       # not inside any conditional
      i = p + 3                              # the "(" of the condition
      depth = 0
      for (; i <= length(flat); i++) {
        c = substr(flat, i, 1)
        if (c == "(") depth++
        else if (c == ")") { depth--; if (depth == 0) break }
      }
      if (depth != 0) exit                   # unbalanced condition
      cond = substr(flat, p + 3, i - p - 2)  # "(" .. ")" inclusive
      i++
      while (substr(flat, i, 1) == " ") i++
      if (substr(flat, i, 1) == "{") {
        depth = 0
        for (j = i; j <= length(flat); j++) {
          c = substr(flat, j, 1)
          if (c == "{") depth++
          else if (c == "}") { depth--; if (depth == 0) break }
        }
        if (depth != 0) exit                 # unbalanced block
        body = substr(flat, i, j - i + 1)
      } else {
        j = index(substr(flat, i), ";")
        if (j == 0) exit
        body = substr(flat, i, j)
      }
      printf "%s\t%s\n", cond, body
    }'
}

# Emit $1 with <!-- --> comments stripped (multi-line aware), one output line
# per input line. A permission that is only COMMENTED OUT must never read as a
# declared one.
xml_view() {
  awk '
    {
      line = $0; out = ""; i = 1; n = length(line)
      while (i <= n) {
        if (incomment) {
          e = index(substr(line, i), "-->")
          if (e == 0) { i = n + 1 } else { i += e + 2; incomment = 0 }
        } else {
          if (substr(line, i, 4) == "<!--") { incomment = 1; i += 4 }
          else { out = out substr(line, i, 1); i += 1 }
        }
      }
      print out
    }' "$1"
}

# The parenthesis-balanced argument list of the FIRST `<name>(` call in the
# comment-stripped view of <file>. Balancing, not a line window: the options
# constructor spans a dozen lines and nests three more calls.
call_slice() { # <name> <file>
  local v; v="$(code_view "$2")"
  awk -v name="$1" '
    { all = all $0 "\n" }
    END {
      start = index(all, name "(")
      if (start == 0) exit
      depth = 0
      for (i = start + length(name); i <= length(all); i++) {
        c = substr(all, i, 1)
        if (c == "(") depth++
        else if (c == ")") {
          depth--
          if (depth == 0) { print substr(all, start, i - start + 1); exit }
        }
      }
    }' <<<"$v"
}

# The lines of a Kotlin member, from its signature to the next declaration.
#
# Bounded by the NEXT member rather than by braces so both body forms read
# alike: an expression body (`= Unit`) has no braces to balance, and a
# brace-balancing slice would run to the end of the file and report whatever it
# found there against the wrong member.
# The comment-stripped body of `_publishCycle`, brace-balanced, one output line
# per source line. Shared by checks (5) and (5b), which police opposite halves
# of the same method and must never disagree about where it ends.
publish_cycle_body() { # <background_location_task.dart>
  awk '
    index($0, "Future<void> _publishCycle(") > 0 { inbody = 1 }
    inbody {
      print
      o = gsub(/[{]/, "&"); c = gsub(/[}]/, "&")
      depth += o - c
      if (seen && depth <= 0) exit
      if (o > 0) seen = 1
    }' <<<"$(code_view "$1")"
}

kotlin_member() { # <signature> <file>
  local v; v="$(code_view "$2")"
  awk -v sig="$1" '
    index($0, sig) > 0 && !seen { seen = 1; print; next }
    seen {
      if ($0 ~ /^[[:space:]]{0,8}(override |private |internal |public )*fun /) exit
      print
    }' <<<"$v"
}

# ---------------------------------------------------------------------------
# 1. The plugin's PERMANENT PARTIAL_WAKE_LOCK is still held: `allowWakeLock` is
#    absent from `ForegroundTaskOptions(`, so the plugin default (true) stands.
#
#    Absence is the invariant, and either value is a failure. `false` removes
#    the only wake source the no-fix watchdog has — indoors on a GNSS-only
#    device nothing else wakes the isolate — so sharing stops silently on the
#    cohort the setting exists for, while reading like a battery fix. `true`
#    states the default and reads as a decision that was reviewed. Phase P2b
#    replaces this check with one binding `allowWakeLock:` to the
#    battery-exemption predicate (never a literal).
# ---------------------------------------------------------------------------
check_plugin_wake_lock_kept() { # <background_location_manager.dart>
  local mgr="$1"
  _lf=0

  local slice
  slice="$(call_slice 'ForegroundTaskOptions' "$mgr")"
  if [[ -z "$slice" ]]; then
    lfail "(1) no ForegroundTaskOptions( call found in code in $(basename "$mgr") — the foreground service is configured somewhere this guard cannot see, so nothing pins the plugin wake lock any more"
    return "$_lf"
  fi
  if [[ "$slice" != *"eventAction:"* ]]; then
    lfail "(1) the ForegroundTaskOptions( slice carries no eventAction: — the slice is not the constructor this check means to read, and every assertion on it is vacuous"
  fi
  if [[ "$slice" == *"allowWakeLock"* ]]; then
    lfail "(1) ForegroundTaskOptions sets allowWakeLock. It must stay ABSENT: 'false' removes the only wake source the indoor/no-fix watchdog has (sharing then stops silently, with no banner), and 'true' merely restates the plugin default. The scoped Haven:publish lock is additive until a replacement wake source is proven"
  fi

  return "$_lf"
}

# ---------------------------------------------------------------------------
# 2. The SCOPED `Haven:publish` lock: present, bounded natively, registered for
#    every process start, and never released by the plugin's lifecycle
#    listeners.
#
#    The listener rule is the subtle one. `ForegroundTask.destroy` invokes
#    Dart's `onDestroy` ASYNCHRONOUSLY and then calls `onTaskDestroy` /
#    `onEngineWillDestroy` SYNCHRONOUSLY — before the isolate's bounded
#    teardown drain, which carries the last publish of the session, has even
#    started. A release there drops the CPU out from under that drain; a
#    `setMethodCallHandler(null)` there leaves the drain's own final release
#    with nowhere to land. Both bodies must therefore be EMPTY, and emptiness
#    is what is asserted rather than the absence of two tokens: a body calling
#    a helper reads innocent and does the same damage.
# ---------------------------------------------------------------------------
check_scoped_publish_lock() { # <PublishWakeLock.kt> <HavenApplication.kt>
  local lock="$1" app="$2"
  _lf=0

  local code
  code="$(code_view "$lock")"
  if [[ -z "${code//[[:space:]]/}" ]]; then
    lfail "(2) $(basename "$lock") holds no code — the scoped wake lock cannot be there to hold"
    return "$_lf"
  fi

  local token
  for token in 'PowerManager.PARTIAL_WAKE_LOCK' '"Haven:publish"' \
    'setReferenceCounted(false)' 'coerceIn(1L, MAX_TIMEOUT_MS)'; do
    grep -qF -- "$token" <<<"$code" ||
      lfail "(2) $(basename "$lock") no longer contains ${token} — a FULL lock would light the screen, an untagged one is invisible to the dumpsys oracle, a reference-counted one is never released by a cycle that acquires per circle, and an uncoerced timeout lets Dart ask for a hold longer than the ceiling"
  done

  grep -qE 'MAX_TIMEOUT_MS *= *30_000L' <<<"$code" ||
    lfail "(2) $(basename "$lock") does not declare MAX_TIMEOUT_MS = 30_000L — it is the twin of Dart's kPublishWakeLockTimeout (location_test.dart pins the Dart half); a drift leaves the lock expiring mid-publish or outliving the cycle"

  grep -qE '\.acquire\([^)[:space:]]' <<<"$code" ||
    lfail "(2) $(basename "$lock") never calls acquire( with a timeout argument"
  grep -qE '\.acquire\([[:space:]]*\)' <<<"$code" &&
    lfail "(2) $(basename "$lock") contains a bare acquire() — an untimed hold is exactly the permanent lock this phase exists to make removable"

  grep -qF -- 'release()' <<<"$code" ||
    lfail "(2) $(basename "$lock") has no release() at all — every cycle would then rely on the 30 s timeout alone, and the emptiness rule below would pass for want of anything to find"

  # The channel INSTALLATION, not just its name. `onEngineCreate` is the only
  # hook that reaches the foreground-service engine before the Dart entrypoint
  # runs; gutted to `= Unit` it leaves the object still registered as a
  # listener, still declaring CHANNEL_NAME, still holding a lock it can never
  # be asked to take — and every Dart acquire degrades to a swallowed
  # MissingPluginException. Nothing else sees that: no JVM test runs this file,
  # the app publishes exactly as before, and the only symptom is a CPU that
  # sleeps mid-publish.
  local create
  create="$(kotlin_member 'fun onEngineCreate(' "$lock")"
  if [[ -z "${create//[[:space:]]/}" ]]; then
    lfail "(2) $(basename "$lock") has no 'fun onEngineCreate(' — it is the only hook that hands over the foreground-service engine before the Dart entrypoint runs"
  else
    local tok
    for tok in 'CHANNEL_NAME' 'setMethodCallHandler(this)'; do
      grep -qF -- "$tok" <<<"$create" ||
        lfail "(2) onEngineCreate in $(basename "$lock") does not contain ${tok} — a body that no longer builds the channel ON THIS OBJECT installs no handler, so every acquire is a swallowed MissingPluginException and the scoped lock is silently dead while the registration in HavenApplication.kt still reads correct"
    done
  fi

  local sig member
  for sig in 'fun onTaskDestroy(' 'fun onEngineWillDestroy('; do
    member="$(kotlin_member "$sig" "$lock")"
    if [[ -z "${member//[[:space:]]/}" ]]; then
      lfail "(2) $(basename "$lock") has no '${sig}' — the listener contract it implements is what installs the channel, so a missing hook means the object no longer is that listener"
      continue
    fi
    member="$(tr '\n' ' ' <<<"$member" | tr -s ' ')"
    member="${member#"${member%%[![:space:]]*}"}"
    member="${member%"${member##*[![:space:]]}"}"
    if [[ ! "$member" =~ ^override\ fun\ [A-Za-z]+\(\)\ (=\ Unit|\{[[:space:]]*\})$ ]]; then
      lfail "(2) '${sig}' in $(basename "$lock") is not empty: '${member}'. It runs synchronously BEFORE the Dart onDestroy drain that carries the session's last publish, so anything here — a release, a setMethodCallHandler(null), or a helper call doing either — takes the CPU or the channel away mid-drain. Release belongs to Dart's onDestroy finally, with the native timeout as the backstop"
    fi
  done

  local app_code
  app_code="$(code_view "$app")"
  grep -qF -- 'addTaskLifecycleListener(PublishWakeLock)' <<<"$app_code" ||
    lfail "(2) $(basename "$app") does not call addTaskLifecycleListener(PublishWakeLock) in code — onEngineCreate is the only hook that hands over the foreground-service engine before the Dart entrypoint runs, and Application.onCreate is the only place that runs for the Activity-less starts (boot restart, headless wake). Without it the channel is never installed and every acquire is a silent no-op"
  grep -qF -- 'PublishWakeLock.attach(' <<<"$app_code" ||
    lfail "(2) $(basename "$app") does not call PublishWakeLock.attach( in code — without the process Context there is no PowerManager, so the lock is never created and the failure is invisible (acquire returns, nothing is held)"

  return "$_lf"
}

# ---------------------------------------------------------------------------
# 3. The manifest declares WAKE_LOCK itself.
#
#    Today it also arrives by merge from flutter_foreground_task's manifest, so
#    an explicit declaration costs nothing and survives that plugin being
#    replaced — at which point the merge, the permission and the scoped lock
#    would go together, silently. Comment-aware (xmllint is not required here):
#    a commented-out declaration is not a declaration.
# ---------------------------------------------------------------------------
check_wake_lock_permission() { # <AndroidManifest.xml>
  local manifest="$1"
  _lf=0

  local view
  view="$(xml_view "$manifest")"
  if ! grep -qE '<uses-permission[^>]*android:name="android\.permission\.WAKE_LOCK"' <<<"$view"; then
    lfail "(3) $(basename "$manifest") does not declare android.permission.WAKE_LOCK outside a comment — PowerManager.newWakeLock throws SecurityException without it, so every publish cycle would run unlocked and the failure would look like a battery win"
    return "$_lf"
  fi
  if grep -E '<uses-permission[^>]*android:name="android\.permission\.WAKE_LOCK"' <<<"$view" |
    grep -q 'tools:node="remove"'; then
    lfail "(3) the WAKE_LOCK declaration in $(basename "$manifest") is neutralised by tools:node=\"remove\" — the merged manifest ships without it"
  fi

  return "$_lf"
}

# ---------------------------------------------------------------------------
# 4. Exactly TWO files under haven/lib ask the plugin for a position stream:
#    the UI isolate's provider and the foreground service's task.
#
#    The invariant is one owner PER ISOLATE, exclusive by lifecycle — the UI
#    stream exists only while foregrounded, the service's only after the UI
#    released ownership. A third caller cannot be reasoned about that way: it
#    would hold a registration on somebody else's schedule, and two live
#    platform requests coalesce at the provider to the TIGHTER one, so a
#    forgotten 1 s stream silently un-does the whole duty cycle while every
#    functional test still passes.
#
#    The interface DECLARATION (`location_service.dart`) is not a call and is
#    excluded by requiring a `.` or `(` context; the service's own definition
#    is excluded the same way.
# ---------------------------------------------------------------------------
check_stream_callers() { # <lib dir>
  local lib="$1"
  _lf=0

  local callers=()
  local f rel view
  while IFS= read -r f; do
    rel="${f#"${lib}/"}"
    # The generated FRB bindings never call it, and scanning them only makes
    # this guard hostage to a codegen change.
    [[ "$rel" == src/rust/* ]] && continue
    view="$(code_view "$f")"
    # A CALL: `something.getLocationStream(` — never the bare declaration.
    grep -qE '\.getLocationStream\(' <<<"$view" && callers+=("$rel")
  done < <(find "$lib" -name '*.dart' -type f | sort)

  local expected=(
    'src/providers/location_provider.dart'
    'src/services/background_location_task.dart'
  )
  local got="${callers[*]}" want="${expected[*]}"
  if [[ "$got" != "$want" ]]; then
    lfail "(4) the files calling .getLocationStream( under haven/lib are [${got}], expected [${want}]. One owner per isolate, exclusive by lifecycle, is what makes the foreground service's long-interval registration a duty cycle at all: a third live request coalesces at the provider to the tighter interval and quietly restores continuous GNSS"
  fi

  return "$_lf"
}

# ---------------------------------------------------------------------------
# 5. Every registration is issued from the publish cycle, BELOW the
#    background-sharing consent gate, BELOW the foreground-ownership gate and
#    BELOW the Play disclosure gate — and `onDestroy` releases it before it
#    starts draining.
#
#    This is the structural half of the consent property. A registration is
#    location COLLECTION: the moment it is issued the platform starts
#    producing this device's coordinates for Haven, for as long as it lives.
#    Wiring one into `onStart`, `onReceiveData` or `onRepeatEvent` — each of
#    which runs unconditionally — would put collection above every gate on a
#    path no functional test distinguishes from the gated one.
#
#    The consent gate is the CURRENT one and the disclosure flags are not: they
#    record that the dialogs were accepted and are never cleared on opt-out.
#    The service can also outlive the toggle, because the teardown that follows
#    it is best-effort — so this key, re-read from disk each cycle, is the only
#    thing standing between an opted-out user and a standing platform request.
#
#    The COUNT is pinned as well as the position, because "below the gate" is
#    only meaningful while every site is in this one method: two sites is what
#    the cycle needs (the aim before the burst, and the retry cadence after a
#    failed publish, which cannot be known before it), and a third is a new
#    path that needs its own reasoning.
# ---------------------------------------------------------------------------
check_registration_is_gated() { # <background_location_task.dart>
  local task="$1"
  _lf=0

  local view
  view="$(code_view "$task")"

  local cycle
  cycle="$(publish_cycle_body "$task")"
  if [[ -z "$cycle" ]]; then
    lfail "(5) _publishCycle( not found in code in $(basename "$task") — if it was renamed, re-point this guard rather than deleting it"
    return "$_lf"
  fi

  # Call sites, never the declaration: `_ensureRegistration({` is the helper
  # itself and would satisfy any bare-token count with every call deleted.
  local total in_cycle
  total="$(grep -c 'await _ensureRegistration(' <<<"$view")"
  in_cycle="$(grep -c 'await _ensureRegistration(' <<<"$cycle")"
  if [[ "$total" != "2" ]]; then
    lfail "(5) $(basename "$task") has ${total} 'await _ensureRegistration(' call site(s), expected exactly 2 (the aim before the burst, and the retry cadence after a failed publish). A new one is a new route to a platform location request and needs its own gate reasoning — state it here in the same commit"
  fi
  if [[ "$in_cycle" != "$total" ]]; then
    lfail "(5) ${total} 'await _ensureRegistration(' call site(s) exist but only ${in_cycle} are inside _publishCycle. Every other entry point (onStart, onReceiveData, onRepeatEvent) runs unconditionally, so a registration outside the cycle is location collection above both consent gates"
  fi

  local gate_consent gate_fg gate_disclosure first_call
  gate_consent="$(awk 'index($0, "if (!(prefs.getBool(kBackgroundSharingKey) ?? false)) {") > 0 { print NR; exit }' <<<"$cycle")"
  gate_fg="$(awk 'index($0, "if (foregroundActive) {") > 0 { print NR; exit }' <<<"$cycle")"
  gate_disclosure="$(awk 'index($0, "if (!backgroundPublishDisclosureAccepted(") > 0 { print NR; exit }' <<<"$cycle")"
  first_call="$(awk 'index($0, "await _ensureRegistration(") > 0 { print NR; exit }' <<<"$cycle")"
  if [[ -z "$gate_consent" || -z "$gate_fg" || -z "$gate_disclosure" ]]; then
    lfail "(5) _publishCycle no longer contains all three gate anchors ('if (!(prefs.getBool(kBackgroundSharingKey) ?? false)) {', 'if (foregroundActive) {' and 'if (!backgroundPublishDisclosureAccepted(') — without them the ordering rule below is vacuous"
    return "$_lf"
  fi
  if [[ -z "$first_call" ]]; then
    lfail "(5) _publishCycle issues no registration at all — the cadence would then be the watchdog poll and the one-shot it drives"
    return "$_lf"
  fi
  (( gate_consent < first_call )) ||
    lfail "(5) a registration is issued at line ${first_call} of _publishCycle, ABOVE the background-sharing consent gate at line ${gate_consent} — the disclosure flags are sticky and the service outlives a best-effort stop, so this key is the only thing that can refuse a standing location request for a user who opted out"
  (( gate_fg < first_call )) ||
    lfail "(5) a registration is issued at line ${first_call} of _publishCycle, ABOVE the foreground-ownership gate at line ${gate_fg} — two isolates would hold a platform location request at once"
  (( gate_disclosure < first_call )) ||
    lfail "(5) a registration is issued at line ${first_call} of _publishCycle, ABOVE the Play disclosure gate at line ${gate_disclosure} — a location request is collection, and collection before disclosure is the rule this app is held to"

  # onDestroy: release the registration BEFORE the drain. A request still
  # delivering into an isolate that is tearing down is a fix nobody can
  # publish and a receiver nobody turns off.
  local destroy
  destroy="$(awk '
    index($0, "Future<void> onDestroy(") > 0 { inbody = 1 }
    inbody {
      print
      o = gsub(/[{]/, "&"); c = gsub(/[}]/, "&")
      depth += o - c
      if (seen && depth <= 0) exit
      if (o > 0) seen = 1
    }' <<<"$view")"
  local cancel_at drain_at
  cancel_at="$(awk 'index($0, "_cancelRegistration(") > 0 { print NR; exit }' <<<"$destroy")"
  drain_at="$(awk 'index($0, "_inFlightPublish?.timeout(") > 0 { print NR; exit }' <<<"$destroy")"
  if [[ -z "$cancel_at" ]]; then
    lfail "(5) onDestroy does not call _cancelRegistration( — the platform keeps delivering fixes to an isolate that is tearing down, and the GNSS engine is never told to stop"
  elif [[ -n "$drain_at" ]] && (( cancel_at > drain_at )); then
    lfail "(5) onDestroy cancels the registration at line ${cancel_at}, AFTER it starts draining at line ${drain_at} — the drain is the window in which a delivery would start a cycle underneath the teardown"
  fi

  return "$_lf"
}

# ---------------------------------------------------------------------------
# 5b. Every `return` ABOVE the registration stands the registration down first.
#
#     Check (5) pins where a request may be TAKEN; this pins where it must be
#     GIVEN BACK. The cycle is re-entered by a 72 s watchdog, so a return that
#     leaves the request live does not cost one cycle — it costs every cycle
#     from then on, because the next one reaches the same return. The GNSS
#     receiver keeps duty-cycling for an isolate that provably cannot publish,
#     and the only symptom is battery.
#
#     A uniform rule rather than a case analysis, because the case analysis is
#     what went wrong: the empty-roster return stood down with exactly this
#     rationale while the gates above it did not, and whether a given gate can
#     be reached WITH a live registration depends on lifecycle facts (which
#     fields are nulled where) that change under maintenance. `_cancelRegistration`
#     is idempotent, so the rule costs nothing where the state cannot arise.
#
#     Returns BELOW the registration are the cycle's normal exits (nothing due,
#     no fix) and must keep it — that is the aim the request was just issued
#     for.
#
#     There is no runtime oracle for this on a host runner, and for most of
#     these gates none on a device either: the app still behaves, it just
#     collects location it cannot use.
# ---------------------------------------------------------------------------
check_returns_stand_down() { # <background_location_task.dart>
  local task="$1"
  _lf=0

  local cycle
  cycle="$(publish_cycle_body "$task")"
  if [[ -z "$cycle" ]]; then
    lfail "(5b) _publishCycle( not found in code in $(basename "$task") — if it was renamed, re-point this guard rather than deleting it"
    return "$_lf"
  fi

  local first_reg
  first_reg="$(awk 'index($0, "await _ensureRegistration(") > 0 { print NR; exit }' <<<"$cycle")"
  if [[ -z "$first_reg" ]]; then
    lfail "(5b) _publishCycle issues no registration at all, so this check has no 'above' to police — restore it (check (5) owns the same anchor)"
    return "$_lf"
  fi

  # A `return;` that shares its line with anything else escapes the rule below
  # by construction, so the form is pinned first: above the registration a
  # return is a statement of its own.
  local inline
  inline="$(awk -v limit="$first_reg" '
    NR >= limit { exit }
    /return;/ && $0 !~ /^[[:space:]]*return;[[:space:]]*$/ { print NR ": " $0 }
  ' <<<"$cycle")"
  if [[ -n "$inline" ]]; then
    lfail "(5b) _publishCycle has an inline return above the registration, which cannot carry a stand-down: ${inline//$'\n'/ | }. Write it as a block whose last two statements are the stand-down and the return"
  fi

  # The stand-down must be the PREVIOUS statement. Comment lines survive
  # `code_view` as empty ones, so a WHY beside the gate is not an escape and
  # not a violation either.
  local bare
  bare="$(awk -v limit="$first_reg" '
    NR >= limit { exit }
    /^[[:space:]]*$/ { next }
    /^[[:space:]]*return;[[:space:]]*$/ {
      if (prev !~ /^[[:space:]]*await _(cancelRegistration|yieldToForeground)\(\);[[:space:]]*$/) print NR
      prev = $0
      next
    }
    { prev = $0 }
  ' <<<"$cycle")"
  if [[ -n "$bare" ]]; then
    lfail "(5b) _publishCycle returns at line(s) ${bare//$'\n'/, } (of the method) above the registration without releasing it first. Every gate that cannot publish must be preceded by 'await _cancelRegistration();' — or by 'await _yieldToForeground();', which also drops the per-circle schedules so the next handoff seeds every circle due-now. Otherwise the watchdog re-enters, reaches the same return, and the receiver keeps running for an isolate that publishes nothing"
  fi

  return "$_lf"
}

# ---------------------------------------------------------------------------
# 6. The foreground service's stream profile is the DUTY-CYCLED one.
#
#    Three properties, each of which silently removes the whole saving:
#      * `forceLocationManager: true` — the platform LocationManager, whose
#        delayed-register / hibernate regime is what stops GNSS between fixes;
#      * `distanceFilter: 0` — the publish is due on TIME, so a filter
#        suppresses the very fix the cycle is waiting for while the device
#        sits still;
#      * NO `timeLimit:` — on a STREAM geolocator's timeLimit is an
#        inter-event timeout that CLOSES the stream, which the service reads
#        as an access loss and answers by dropping the cached fix. On a 62-158
#        s interval that fires on every healthy cycle.
# ---------------------------------------------------------------------------
check_background_stream_profile() { # <geolocator_location_service.dart>
  local svc="$1"
  _lf=0

  # The `BackgroundServiceStreamProfile(:...) => geo.AndroidSettings(...)` arm
  # of the settings switch, balanced from the pattern to the close of the
  # AndroidSettings call — never a line window, since the arm spans a dozen
  # lines of comments.
  #
  # Anchored on the DESTRUCTURING pattern (`(:`), not on the bare type name:
  # the class's own constructor declaration appears first in the file, and a
  # slice starting there would run through the one-shot settings — whose
  # `timeLimit` is legitimate — and report it against this arm.
  local arm
  arm="$(code_view "$svc" | awk '
    { all = all $0 "\n" }
    END {
      start = index(all, "BackgroundServiceStreamProfile(:")
      if (start == 0) exit
      open = index(substr(all, start), "AndroidSettings(")
      if (open == 0) exit
      i = start + open + length("AndroidSettings(") - 2
      depth = 0
      for (; i <= length(all); i++) {
        c = substr(all, i, 1)
        if (c == "(") depth++
        else if (c == ")") { depth--; if (depth == 0) break }
      }
      print substr(all, start, i - start + 1)
    }')"
  if [[ -z "$arm" ]]; then
    lfail "(6) no 'BackgroundServiceStreamProfile(:' -> AndroidSettings( arm found in code in $(basename "$svc") — the foreground service is asking the plugin for something this guard cannot see"
    return "$_lf"
  fi

  grep -qF -- 'forceLocationManager: true' <<<"$arm" ||
    lfail "(6) the background-service stream arm does not set forceLocationManager: true — without the platform LocationManager there is no delayed-register/hibernate regime, and the interval stops being a duty cycle"
  grep -qE 'distanceFilter: 0([^0-9]|$)' <<<"$arm" ||
    lfail "(6) the background-service stream arm does not set distanceFilter: 0 — a filter suppresses the fix the cycle is waiting for whenever the device sits still, which is exactly when a publish is still owed"
  grep -qF -- 'intervalDuration:' <<<"$arm" ||
    lfail "(6) the background-service stream arm sets no intervalDuration: — the request would fall back to the plugin default and the aim computed by the cycle would reach the platform nowhere"
  grep -qF -- 'timeLimit' <<<"$arm" &&
    lfail "(6) the background-service stream arm sets timeLimit: — on a STREAM that is an inter-event timeout that CLOSES the stream, which this service reads as an access loss and answers by dropping the cached fix. On a 62-158 s interval it fires on every healthy cycle"

  return "$_lf"
}

# ---------------------------------------------------------------------------
# 7 + 8. `_onPaused` releases the platform position subscription itself,
#        before it hands publishing over, and decides whether to do so through
#        the ONE keep rule rather than a hand-rolled platform test.
# ---------------------------------------------------------------------------
check_pause_releases_stream() { # <map_shell.dart>
  local shell="$1"
  _lf=0

  local body
  body="$(fn_slice 'Future<void> _onPaused() async {' "$shell")"
  if [[ -z "$body" ]]; then
    lfail "_onPaused not found in $(basename "$shell") — if it was renamed, update this guard rather than deleting it"
    return "$_lf"
  fi

  # One line, spaces squeezed, so the ordering and the enclosing condition can
  # be read positionally regardless of how the call is wrapped.
  local flat
  flat="$(tr '\n' ' ' <<<"$body" | tr -s ' ')"

  if [[ "$flat" != *"suspendStream("* ]]; then
    lfail "(7) _onPaused never calls suspendStream( — the UI isolate keeps its 1 Hz / 1 m location registration for the whole backgrounded window, and a release that rides a provider rebuild cannot run while frames are off"
    return "$_lf"
  fi
  if [[ "$flat" != *"markForegroundActive(active: false)"* ]]; then
    lfail "(7) _onPaused no longer writes markForegroundActive(active: false) — without the ownership write the ordering rule below is vacuous, and the foreground service never takes over publishing"
    return "$_lf"
  fi

  local before_suspend before_owner
  before_suspend="${flat%%suspendStream(*}"
  before_owner="${flat%%markForegroundActive(active: false)*}"
  if (( ${#before_suspend} > ${#before_owner} )); then
    lfail "(7) _onPaused calls suspendStream( AFTER markForegroundActive(active: false) — the foreground service is told to take over publishing while this isolate still holds a location client, so both hold one at once"
  fi

  # (8) The release must be CONTAINED by a conditional that IS the keep rule.
  #     Its own `isIOS:` argument is fine; a hand-rolled platform branch is
  #     not — the iOS background-sharing session is the only thing keeping
  #     that process executable, and releasing it there ends background
  #     publishing outright. Containment, not position: see `guarded_slice`.
  local guarded condition governed
  guarded="$(guarded_slice "$flat" "suspendStream(")"
  if [[ -z "$guarded" ]]; then
    lfail "(8) the suspendStream( call in _onPaused is not inside any conditional — the iOS background-sharing stream IS the process keep-alive and must never be released at pause"
    return "$_lf"
  fi
  condition="${guarded%%$'\t'*}"
  governed="${guarded#*$'\t'}"
  if [[ "$governed" != *"suspendStream("* ]]; then
    lfail "(8) the suspendStream( call in _onPaused sits AFTER a conditional rather than inside it — the release is unconditional, so the iOS background-sharing stream (the process keep-alive) dies at every pause and background publishing ends"
  elif [[ ! "$condition" =~ ^\(!?shouldKeepLocationStreamWhilePaused\( ]]; then
    lfail "(8) the conditional containing suspendStream( in _onPaused is not shouldKeepLocationStreamWhilePaused( — the keep rule has exactly one definition, and a hand-rolled platform branch beside it is how the two silently diverge"
  fi

  return "$_lf"
}

if [[ "${1:-}" != "--self-test" ]]; then
  for f in "$MAP_SHELL" "$FGS_MANAGER" "$PUBLISH_WAKE_LOCK" "$HAVEN_APPLICATION" \
    "$MANIFEST" "$BG_TASK" "$LOCATION_SERVICE"; do
    [[ -f "$f" ]] || { echo "FAIL: expected file not found: $f" >&2; exit 2; }
  done
  check_plugin_wake_lock_kept "$FGS_MANAGER" || FAILED=1
  check_scoped_publish_lock "$PUBLISH_WAKE_LOCK" "$HAVEN_APPLICATION" || FAILED=1
  check_wake_lock_permission "$MANIFEST" || FAILED=1
  check_stream_callers "$LIB_DIR" || FAILED=1
  check_registration_is_gated "$BG_TASK" || FAILED=1
  check_returns_stand_down "$BG_TASK" || FAILED=1
  check_background_stream_profile "$LOCATION_SERVICE" || FAILED=1
  check_pause_releases_stream "$MAP_SHELL" || FAILED=1
fi

# ---------------------------------------------------------------------------
# --self-test: hermetic fixtures for the function-shaped check above.
#
# It pins an invariant nothing behavioural can see on a host runner: a
# backgrounded platform registration only shows up as battery, hours later and
# off-device. Every mutation below leaves the file compiling and reading
# naturally, and both anti-vacuity directions are covered — a deleted call and
# a deleted ordering anchor must FAIL, never pass for want of something to
# match.
#
# The count is pinned by EQUALITY, not a floor: a floor lets a deleted fixture
# hide under the slack.
# ---------------------------------------------------------------------------
self_test() {
  local -r SELF_TEST_FIXTURES=66
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

  # -- checks 1-3: the wake-lock policy -------------------------------------
  #
  # Reduced-but-faithful seeds, mutated one edit at a time. Every mutation
  # leaves a file that compiles and reads naturally — which is the only kind
  # this guard exists to catch, since no JVM test ever runs this Kotlin.
  _seed_manager() {
    cat >"${tmp}/background_location_manager.dart" <<'DART'
class BackgroundLocationManager {
  static void init({required String channelName}) {
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'haven_location_v3',
        channelName: channelName,
      ),
      foregroundTaskOptions: ForegroundTaskOptions(
        eventAction: ForegroundTaskEventAction.repeat(
          kBackgroundRepeatInterval.inMilliseconds,
        ),
        // allowWakeLock stays absent: the plugin lock is the watchdog's wake
        // source until a replacement is proven.
        autoRunOnBoot: true,
      ),
    );
  }
}
DART
  }

  _seed_kotlin() {
    cat >"${tmp}/PublishWakeLock.kt" <<'KOTLIN'
object PublishWakeLock :
    FlutterForegroundTaskLifecycleListener,
    MethodChannel.MethodCallHandler {
    private const val CHANNEL_NAME = "haven.app/publish_wake_lock"
    private const val LOCK_TAG = "Haven:publish"
    private const val MAX_TIMEOUT_MS = 30_000L

    private var powerManager: PowerManager? = null
    private var lock: PowerManager.WakeLock? = null

    fun attach(context: Context) {
        powerManager = context.getSystemService(Context.POWER_SERVICE) as? PowerManager
    }

    override fun onEngineCreate(flutterEngine: FlutterEngine?) {
        val messenger = flutterEngine?.dartExecutor?.binaryMessenger ?: return
        MethodChannel(messenger, CHANNEL_NAME).setMethodCallHandler(this)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "acquire" -> {
                val requested = (call.arguments as? Number)?.toLong() ?: MAX_TIMEOUT_MS
                acquire(requested.coerceIn(1L, MAX_TIMEOUT_MS))
                result.success(null)
            }
            "release" -> {
                release()
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    override fun onTaskStart(starter: FlutterForegroundTaskStarter) = Unit

    override fun onTaskRepeatEvent() = Unit

    // Deliberately empty: these run before the Dart teardown drain.
    override fun onTaskDestroy() = Unit

    override fun onEngineWillDestroy() = Unit

    private fun acquire(timeoutMs: Long) {
        val held = lock ?: powerManager
            ?.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, LOCK_TAG)
            ?.apply { setReferenceCounted(false) }
            ?.also { lock = it }
        held?.acquire(timeoutMs)
    }

    private fun release() {
        lock?.let { if (it.isHeld) it.release() }
    }
}
KOTLIN
    cat >"${tmp}/HavenApplication.kt" <<'KOTLIN'
class HavenApplication : Application() {
    override fun onCreate() {
        super.onCreate()
        PublishWakeLock.attach(applicationContext)
        FlutterForegroundTaskPlugin.addTaskLifecycleListener(PublishWakeLock)
        Keyring.initializeNdkContext(applicationContext)
    }
}
KOTLIN
  }

  _seed_manifest() {
    cat >"${tmp}/AndroidManifest.xml" <<'XML'
<manifest xmlns:android="http://schemas.android.com/apk/res/android"
    xmlns:tools="http://schemas.android.com/tools">
    <uses-permission android:name="android.permission.INTERNET" />
    <!-- Wake lock for the scoped Haven:publish PARTIAL_WAKE_LOCK. -->
    <uses-permission android:name="android.permission.WAKE_LOCK" />
    <application android:name=".HavenApplication" />
</manifest>
XML
  }

  _mgr() { # <label> <want-rc> <mutation>
    local got=0
    _seed_manager
    eval "$3"
    ( check_plugin_wake_lock_kept "${tmp}/background_location_manager.dart" ) \
      >/dev/null 2>&1 || got=$?
    _record "$1" "$2" "${got}"
  }

  _kt() { # <label> <want-rc> <mutation>
    local got=0
    _seed_kotlin
    eval "$3"
    ( check_scoped_publish_lock "${tmp}/PublishWakeLock.kt" \
        "${tmp}/HavenApplication.kt" ) >/dev/null 2>&1 || got=$?
    _record "$1" "$2" "${got}"
  }

  _manifest() { # <label> <want-rc> <mutation>
    local got=0
    _seed_manifest
    eval "$3"
    ( check_wake_lock_permission "${tmp}/AndroidManifest.xml" ) \
      >/dev/null 2>&1 || got=$?
    _record "$1" "$2" "${got}"
  }

  local KT="${tmp}/PublishWakeLock.kt"
  local APP="${tmp}/HavenApplication.kt"
  local MGRF="${tmp}/background_location_manager.dart"
  local MF="${tmp}/AndroidManifest.xml"

  # (1) the plugin's permanent lock. Positive control first: a check hard-coded
  #     to fail would pass every negative fixture below and look perfect.
  _mgr "today's ForegroundTaskOptions passes" 0 ':'
  _mgr 'allowWakeLock: true FAILS' 1 \
    "sed -i 's/        autoRunOnBoot: true,/        allowWakeLock: true,\n        autoRunOnBoot: true,/' '${MGRF}'"
  _mgr 'allowWakeLock: false FAILS' 1 \
    "sed -i 's/        autoRunOnBoot: true,/        allowWakeLock: false,\n        autoRunOnBoot: true,/' '${MGRF}'"
  # The WHY comment beside the absence must stay legal, or it gets deleted
  # instead of the code it explains.
  _mgr 'prose naming allowWakeLock passes' 0 \
    "sed -i 's|        autoRunOnBoot: true,|        // allowWakeLock: false would stop the watchdog.\n        autoRunOnBoot: true,|' '${MGRF}'"
  _mgr 'no ForegroundTaskOptions( call at all FAILS' 1 \
    "sed -i 's/ForegroundTaskOptions(/TaskOptions(/' '${MGRF}'"
  _mgr 'a ForegroundTaskOptions( slice without eventAction FAILS' 1 \
    "sed -i '/eventAction:/,+2d' '${MGRF}'"

  # (2) the scoped lock.
  _kt "today's PublishWakeLock.kt and HavenApplication.kt pass" 0 ':'
  _kt 'a bare acquire() FAILS' 1 \
    "sed -i 's/held?.acquire(timeoutMs)/held?.acquire()/' '${KT}'"
  _kt 'MAX_TIMEOUT_MS = 60_000L FAILS' 1 \
    "sed -i 's/MAX_TIMEOUT_MS = 30_000L/MAX_TIMEOUT_MS = 60_000L/' '${KT}'"
  _kt 'the native coercion dropped FAILS' 1 \
    "sed -i 's/acquire(requested.coerceIn(1L, MAX_TIMEOUT_MS))/acquire(requested)/' '${KT}'"
  _kt 'a reference-counted lock FAILS' 1 \
    "sed -i 's/setReferenceCounted(false)/setReferenceCounted(true)/' '${KT}'"
  _kt 'a FULL_WAKE_LOCK instead of PARTIAL FAILS' 1 \
    "sed -i 's/PowerManager.PARTIAL_WAKE_LOCK/PowerManager.FULL_WAKE_LOCK/' '${KT}'"
  _kt 'a renamed lock tag FAILS (the dumpsys oracle looks for it)' 1 \
    "sed -i 's/\"Haven:publish\"/\"Haven:cycle\"/' '${KT}'"
  # The channel installation itself. Both mutants leave a file that compiles,
  # a listener that is still registered and a lock that is never asked for.
  _kt 'a gutted onEngineCreate FAILS' 1 \
    "sed -i '/val messenger = flutterEngine/d; /MethodChannel(messenger, CHANNEL_NAME).setMethodCallHandler(this)/d' '${KT}'"
  _kt 'onEngineCreate installing on a literal channel name FAILS' 1 \
    "sed -i 's|MethodChannel(messenger, CHANNEL_NAME)|MethodChannel(messenger, \"haven.app/wake\")|' '${KT}'"
  _kt 'a releasing onTaskDestroy FAILS' 1 \
    "sed -i 's/    override fun onTaskDestroy() = Unit/    override fun onTaskDestroy() = release()/' '${KT}'"
  _kt 'a detaching onEngineWillDestroy FAILS' 1 \
    "sed -i 's/    override fun onEngineWillDestroy() = Unit/    override fun onEngineWillDestroy() { channel.setMethodCallHandler(null) }/' '${KT}'"
  # The escape a two-token scan cannot see: the listener body names neither
  # release nor setMethodCallHandler, and does both.
  _kt 'a destroy listener delegating to a helper FAILS' 1 \
    "sed -i 's/    override fun onTaskDestroy() = Unit/    override fun onTaskDestroy() = tearDown()\n\n    private fun tearDown() {\n        release()\n    }/' '${KT}'"
  _kt 'release() deleted outright FAILS' 1 \
    "sed -i 's/^                release()$/                \/\/ removed/; s/    private fun release() {/    private fun unused() {/; s/lock?.let { if (it.isHeld) it.release() }/lock = null/' '${KT}'"
  # A reformat must not be a violation, or the guard gets worked around.
  _kt 'a braced empty destroy body passes' 0 \
    "sed -i 's/    override fun onTaskDestroy() = Unit/    override fun onTaskDestroy() {}/' '${KT}'"
  _kt 'a deleted onTaskDestroy override FAILS' 1 \
    "sed -i '/override fun onTaskDestroy() = Unit/d' '${KT}'"
  _kt 'an empty PublishWakeLock.kt FAILS' 1 ": > '${KT}'"
  _kt 'the addTaskLifecycleListener registration deleted FAILS' 1 \
    "sed -i '/addTaskLifecycleListener(PublishWakeLock)/d' '${APP}'"
  _kt 'a commented-out registration FAILS' 1 \
    "sed -i 's|        FlutterForegroundTaskPlugin.addTaskLifecycleListener|        // FlutterForegroundTaskPlugin.addTaskLifecycleListener|' '${APP}'"
  _kt 'the PublishWakeLock.attach( call deleted FAILS' 1 \
    "sed -i '/PublishWakeLock.attach(/d' '${APP}'"

  # (3) the manifest permission.
  _manifest "today's manifest passes" 0 ':'
  _manifest 'no WAKE_LOCK declaration FAILS' 1 \
    "sed -i '/android.permission.WAKE_LOCK/d' '${MF}'"
  _manifest 'a commented-out declaration FAILS' 1 \
    "sed -i 's|    <uses-permission android:name=\"android.permission.WAKE_LOCK\" />|    <!-- <uses-permission android:name=\"android.permission.WAKE_LOCK\" /> -->|' '${MF}'"
  _manifest 'a tools:node=remove declaration FAILS' 1 \
    "sed -i 's|android:name=\"android.permission.WAKE_LOCK\" />|android:name=\"android.permission.WAKE_LOCK\" tools:node=\"remove\" />|' '${MF}'"

  # -- checks 4-6: the foreground-service registration invariants ----------
  #
  # Reduced-but-faithful seeds again. Every mutation below is one edit that
  # leaves the file compiling and reading naturally — a second registration
  # site, a gate reordered above it, a filter added "for battery", a
  # `timeLimit` added "so a dead stream cannot hang". None of them has a
  # runtime oracle on a host runner: the app still publishes, it just publishes
  # with the receiver on.
  _seed_lib() {
    rm -rf "${tmp}/lib"
    mkdir -p "${tmp}/lib/src/providers" "${tmp}/lib/src/services" \
      "${tmp}/lib/src/rust"
    cat >"${tmp}/lib/src/services/location_service.dart" <<'DART'
abstract class LocationService {
  Stream<Position> getLocationStream();
}
DART
    cat >"${tmp}/lib/src/providers/location_provider.dart" <<'DART'
final locationStreamProvider = StreamProvider<Position>((ref) {
  return service.getLocationStream(backgroundSharingEnabled: enabled);
});
DART
    cat >"${tmp}/lib/src/rust/frb_generated.dart" <<'DART'
// Generated. Mentions service.getLocationStream( in a doc comment only.
DART
    cat >"${tmp}/lib/src/services/background_location_task.dart" <<'DART'
class BackgroundLocationTaskHandler {
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {
    if (!_shutdownSignal.isCompleted) _shutdownSignal.complete();
    await _cancelRegistration();
    await _wakeLock.acquire();
    try {
      await _inFlightPublish?.timeout(teardownDrainBudget);
    } finally {
      await _wakeLock.release();
    }
  }

  Future<void> _ensureRegistration({
    required DateTime earliestDue,
    required DateTime now,
    required DateTime plannedPublishStart,
  }) async {
    await _cancelRegistration();
    _fixSub = _locationService!
        .getLocationStream(profile: profile)
        .listen(_onFixDelivered);
  }

  Future<void> _cancelRegistration() async {
    await _fixSub?.cancel();
  }

  Future<void> _publishCycle(DateTime timestamp) async {
    await _wakeLock.acquire();
    try {
      if (_pubkeyHex == null) {
        await _cancelRegistration();
        return;
      }
      if (!(prefs.getBool(kBackgroundSharingKey) ?? false)) {
        await _yieldToForeground();
        return;
      }
      final foregroundActive = await _foregroundActiveFrom(prefs);
      if (foregroundActive) {
        await _yieldToForeground();
        return;
      }
      if (!backgroundPublishDisclosureAccepted(
        foregroundAccepted: foregroundDisclosed,
        backgroundAccepted: backgroundDisclosed,
      )) {
        // Collection, not just publication.
        await _cancelRegistration();
        return;
      }
      await _ensureRegistration(
        earliestDue: earliestDue,
        now: DateTime.now(),
        plannedPublishStart: planStart,
      );
      if (dueKeys.isEmpty) return;
      final position = await _unlessShuttingDown(
        _locationService!.getCurrentLocation(),
      );
      if (publishFailed) {
        await _ensureRegistration(
          earliestDue: retryAt,
          now: DateTime.now(),
          plannedPublishStart: DateTime.now(),
        );
      }
    } finally {
      await _wakeLock.release();
    }
  }
}
DART
  }

  _seed_service() {
    cat >"${tmp}/geolocator_location_service.dart" <<'DART'
final class BackgroundServiceStreamProfile extends AndroidStreamProfile {
  const BackgroundServiceStreamProfile({required this.interval});
  final Duration interval;
}

class GeolocatorLocationService {
  geo.LocationSettings _streamSettings({
    required bool backgroundSharingEnabled,
    required AndroidStreamProfile profile,
  }) {
    return switch (profile) {
      ForegroundStreamProfile() => geo.AndroidSettings(
        distanceFilter: 1,
        forceLocationManager: true,
        intervalDuration: const Duration(seconds: 1),
      ),
      BackgroundServiceStreamProfile(:final interval) => geo.AndroidSettings(
        // Explicit despite matching the plugin default.
        // ignore: avoid_redundant_argument_values
        distanceFilter: 0,
        forceLocationManager: true, // Bypass Google Play Services
        intervalDuration: interval, // The provider duty-cycles GNSS on this
      ),
    };
  }

  Future<Position> _oneShot() async => _geolocator.getCurrentPosition(
    locationSettings: geo.AndroidSettings(
      forceLocationManager: true,
      timeLimit: kOneShotLocationTimeout,
    ),
  );
}
DART
  }

  _callers() { # <label> <want-rc> <mutation>
    local got=0
    _seed_lib
    eval "$3"
    ( check_stream_callers "${tmp}/lib" ) >/dev/null 2>&1 || got=$?
    _record "$1" "$2" "${got}"
  }

  _gated() { # <label> <want-rc> <mutation>
    local got=0
    _seed_lib
    eval "$3"
    ( check_registration_is_gated \
        "${tmp}/lib/src/services/background_location_task.dart" ) \
      >/dev/null 2>&1 || got=$?
    _record "$1" "$2" "${got}"
  }

  _standdown() { # <label> <want-rc> <mutation>
    local got=0
    _seed_lib
    eval "$3"
    ( check_returns_stand_down \
        "${tmp}/lib/src/services/background_location_task.dart" ) \
      >/dev/null 2>&1 || got=$?
    _record "$1" "$2" "${got}"
  }

  _profile() { # <label> <want-rc> <mutation>
    local got=0
    _seed_service
    eval "$3"
    ( check_background_stream_profile "${tmp}/geolocator_location_service.dart" ) \
      >/dev/null 2>&1 || got=$?
    _record "$1" "$2" "${got}"
  }

  local TASKF="${tmp}/lib/src/services/background_location_task.dart"
  local SVCF="${tmp}/geolocator_location_service.dart"

  # (4) who may ask the plugin for a stream.
  _callers "today's two callers pass" 0 ':'
  _callers 'a third file calling getLocationStream( FAILS' 1 \
    "printf 'final s = service.getLocationStream();\n' > '${tmp}/lib/src/services/rogue.dart'"
  _callers 'the UI provider losing its call FAILS' 1 \
    "sed -i 's/return service.getLocationStream(/return service.somethingElse(/' '${tmp}/lib/src/providers/location_provider.dart'"
  _callers 'the foreground service losing its call FAILS' 1 \
    "sed -i 's/.getLocationStream(profile: profile)/.somethingElse(profile: profile)/' '${TASKF}'"
  # A commented-out call is not a call, in either direction.
  _callers 'a commented-out third call passes' 0 \
    "printf '// final s = service.getLocationStream();\n' > '${tmp}/lib/src/services/rogue.dart'"
  # The generated bindings are excluded by path, not by luck.
  _callers 'a mention in the generated bindings passes' 0 \
    "printf 'final s = service.getLocationStream();\n' > '${tmp}/lib/src/rust/api.dart'"

  # (5) every registration sits inside the cycle, below both gates.
  _gated "today's single gated pair passes" 0 ':'
  # The count stays at two, so what fails is CONTAINMENT and nothing else:
  # onDestroy runs on every stop, above no gate at all.
  _gated 'a registration moved out of the cycle into onDestroy FAILS' 1 \
    "sed -i '/      if (publishFailed) {/,+6d' '${TASKF}' && sed -i '0,/    await _cancelRegistration();/s||    await _ensureRegistration(earliestDue: e, now: n, plannedPublishStart: p);\n    await _cancelRegistration();|' '${TASKF}'"
  _gated 'a third call site FAILS' 1 \
    "sed -i 's|      if (dueKeys.isEmpty) return;|      await _ensureRegistration(earliestDue: e, now: n, plannedPublishStart: p);\n      if (dueKeys.isEmpty) return;|' '${TASKF}'"
  # Again the count is preserved: the first site simply moves up one gate.
  # The deletion is anchored at that site's own indentation, so the retry call
  # nested inside `if (publishFailed)` survives and the fixture fails for the
  # ORDERING and nothing else.
  _gated 'the registration moved above the disclosure gate FAILS' 1 \
    "sed -i '/^      await _ensureRegistration(\$/,+4d' '${TASKF}' && sed -i '0,/      if (!backgroundPublishDisclosureAccepted(/s||      await _ensureRegistration(earliestDue: e, now: n, plannedPublishStart: p);\n      if (!backgroundPublishDisclosureAccepted(|' '${TASKF}'"
  _gated 'the consent gate deleted FAILS' 1 \
    "sed -i '/if (!(prefs.getBool(kBackgroundSharingKey) ?? false)) {/,+3d' '${TASKF}'"
  # The count is preserved again: the first site simply moves above the
  # consent gate, which is where an opted-out user gets a standing request.
  _gated 'the registration moved above the consent gate FAILS' 1 \
    "sed -i '/^      await _ensureRegistration(\$/,+4d' '${TASKF}' && sed -i '0,/      if (!(prefs.getBool(kBackgroundSharingKey) ?? false)) {/s||      await _ensureRegistration(earliestDue: e, now: n, plannedPublishStart: p);\n      if (!(prefs.getBool(kBackgroundSharingKey) ?? false)) {|' '${TASKF}'"
  _gated 'the foreground gate deleted FAILS' 1 \
    "sed -i '/if (foregroundActive) {/,+3d' '${TASKF}'"
  _gated 'the disclosure gate deleted FAILS' 1 \
    "sed -i '/if (!backgroundPublishDisclosureAccepted(/,+5d' '${TASKF}'"
  _gated 'no registration at all FAILS' 1 \
    "sed -i 's/      await _ensureRegistration(/      await _somethingElse(/' '${TASKF}'"
  _gated 'onDestroy without _cancelRegistration( FAILS' 1 \
    "sed -i '0,/    await _cancelRegistration();/s|    await _cancelRegistration();||' '${TASKF}'"
  _gated 'onDestroy cancelling AFTER the drain FAILS' 1 \
    "sed -i '0,/    await _cancelRegistration();/s|    await _cancelRegistration();||' '${TASKF}' && sed -i 's|      await _inFlightPublish?.timeout(teardownDrainBudget);|      await _inFlightPublish?.timeout(teardownDrainBudget);\n      await _cancelRegistration();|' '${TASKF}'"
  _gated 'a renamed _publishCycle FAILS loudly rather than passing empty' 1 \
    "sed -i 's/Future<void> _publishCycle(/Future<void> _runCycle(/' '${TASKF}'"

  # (5b) every return above the registration gives it back. The mutations are
  # the two shapes the omission actually takes — a gate that simply returns,
  # and a one-liner with nowhere to put the stand-down — plus both
  # anti-over-reach directions, since a rule that also fired BELOW the
  # registration would forbid the cycle's normal exits.
  _standdown "today's stand-downs pass" 0 ':'
  _standdown 'a gate that returns without releasing the request FAILS' 1 \
    "sed -i '/\/\/ Collection, not just publication./{n;d}' '${TASKF}'"
  _standdown 'an inline return above the registration FAILS' 1 \
    "sed -i 's|      final foregroundActive = await _foregroundActiveFrom(prefs);|      if (_circleService == null) return;\n      final foregroundActive = await _foregroundActiveFrom(prefs);|' '${TASKF}'"
  _standdown 'a return BELOW the registration needs no stand-down' 0 \
    "sed -i 's|      if (publishFailed) {|      if (position == null) return;\n      if (publishFailed) {|' '${TASKF}'"
  _standdown 'a comment between the stand-down and the return passes' 0 \
    "sed -i 's|^        await _cancelRegistration();\$|        await _cancelRegistration();\n        // ...and then leave.|' '${TASKF}'"
  _standdown 'no registration at all FAILS loudly rather than passing empty' 1 \
    "sed -i 's/      await _ensureRegistration(/      await _somethingElse(/' '${TASKF}'"

  # (6) the duty-cycled profile. The positive control is also the anti-escape
  # one: the seed carries the ONE-SHOT's own legitimate `timeLimit`, which a
  # file-wide grep would report against this arm.
  _profile "today's background arm passes beside the one-shot's timeLimit" 0 ':'
  _profile 'a timeLimit on the background arm FAILS' 1 \
    "sed -i 's|        intervalDuration: interval, // The provider duty-cycles GNSS on this|        intervalDuration: interval,\n        timeLimit: kStreamPositionMaxAge,|' '${SVCF}'"
  _profile 'a distance filter on the background arm FAILS' 1 \
    "sed -i '0,/        distanceFilter: 0,/{s/        distanceFilter: 0,/        distanceFilter: 10,/}' '${SVCF}'"
  _profile 'dropping forceLocationManager on the background arm FAILS' 1 \
    "sed -i 's|        forceLocationManager: true, // Bypass Google Play Services||' '${SVCF}'"
  _profile 'dropping intervalDuration on the background arm FAILS' 1 \
    "sed -i 's|        intervalDuration: interval, // The provider duty-cycles GNSS on this||' '${SVCF}'"
  _profile 'no background arm at all FAILS' 1 \
    "sed -i 's/BackgroundServiceStreamProfile(:final interval)/ForegroundStreamProfile()/' '${SVCF}'"
  _shell() { # <label> <want-rc> <_onPaused body>
    local got=0
    cat >"${tmp}/map_shell.dart" <<EOF
class _MapShellState {
  Future<void> _onPaused() async {
$3
  }

  Future<void> _onResumed() async {
    _geolocatorService?.resumeStream();
  }
}
EOF
    ( check_pause_releases_stream "${tmp}/map_shell.dart" ) >/dev/null 2>&1 || got=$?
    _record "$1" "$2" "${got}"
  }

  local good='    final bgEnabled = ref.read(backgroundSharingProvider);
    final locationService = _geolocatorService;
    if (!shouldKeepLocationStreamWhilePaused(
      backgroundSharingEnabled: bgEnabled,
      isIOS: Platform.isIOS,
    )) {
      locationService?.suspendStream();
    }
    if (bgEnabled && Platform.isAndroid) {
      await BackgroundLocationManager.markForegroundActive(active: false);
    }'

  _shell "today's tree shape passes" 0 "${good}"

  _shell 'the release happens after the ownership write' 1 \
'    final bgEnabled = ref.read(backgroundSharingProvider);
    final locationService = _geolocatorService;
    if (bgEnabled && Platform.isAndroid) {
      await BackgroundLocationManager.markForegroundActive(active: false);
    }
    if (!shouldKeepLocationStreamWhilePaused(
      backgroundSharingEnabled: bgEnabled,
      isIOS: Platform.isIOS,
    )) {
      locationService?.suspendStream();
    }'

  _shell 'a hand-rolled platform branch replaces the keep rule' 1 \
'    final bgEnabled = ref.read(backgroundSharingProvider);
    final locationService = _geolocatorService;
    if (!(bgEnabled && Platform.isIOS)) {
      locationService?.suspendStream();
    }
    await BackgroundLocationManager.markForegroundActive(active: false);'

  _shell 'the release is unconditional (the iOS keep-alive dies too)' 1 \
'    final locationService = _geolocatorService;
    locationService?.suspendStream();
    await BackgroundLocationManager.markForegroundActive(active: false);'

  # The escape a positional match cannot see: the keep rule is still there,
  # still named, still the nearest preceding `if (` — and the release sits
  # AFTER its block, so it runs on every pause. Reads correct; ends iOS
  # background publishing outright.
  _shell 'an unconditional release after a keep-rule branch' 1 \
'    final bgEnabled = ref.read(backgroundSharingProvider);
    final locationService = _geolocatorService;
    if (!shouldKeepLocationStreamWhilePaused(
      backgroundSharingEnabled: bgEnabled,
      isIOS: Platform.isIOS,
    )) {
      debugPrint("[MapShell] releasing the position stream");
    }
    locationService?.suspendStream();
    await BackgroundLocationManager.markForegroundActive(active: false);'

  _shell 'the release is gone entirely' 1 \
'    final bgEnabled = ref.read(backgroundSharingProvider);
    if (bgEnabled && Platform.isAndroid) {
      await BackgroundLocationManager.markForegroundActive(active: false);
    }'

  _shell 'only a comment describes the release' 1 \
'    final bgEnabled = ref.read(backgroundSharingProvider);
    final locationService = _geolocatorService;
    // if (!shouldKeepLocationStreamWhilePaused(
    //   backgroundSharingEnabled: bgEnabled,
    //   isIOS: Platform.isIOS,
    // )) locationService?.suspendStream();
    await BackgroundLocationManager.markForegroundActive(active: false);'

  if (( checked != SELF_TEST_FIXTURES )); then
    echo "SELF-TEST FAIL: ran ${checked} fixture(s), expected ${SELF_TEST_FIXTURES}" >&2
    fails=1
  fi
  if (( fails != 0 )); then
    echo "check_android_location_power.sh --self-test: FAILED" >&2
    return 1
  fi
  echo "check_android_location_power.sh --self-test: ${checked} fixtures passed"
  return 0
}

if [[ "${1:-}" == "--self-test" ]]; then
  self_test
  exit $?
fi

if [[ "$FAILED" -ne 0 ]]; then
  echo "check_android_location_power.sh: FAILED" >&2
  exit 1
fi
echo "check_android_location_power.sh: OK"
