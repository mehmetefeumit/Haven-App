#!/usr/bin/env bash
# CI guard: structural correctness invariants for the M7-C/D native background
# wakes (Android WorkManager + iOS SLC/BGTask).
#
# These are the STATIC, always-true invariants whose violation reintroduces one
# of the exact bugs that sank the 2026-07-02 native-wake draft, or a bug an
# adversarial review caught in M7-C/D / M7-E. Pure source checks (grep/awk +
# xmllint for XML) — no Flutter/Gradle/Xcode — so they run fast and independently,
# and CAN be verified on any box (the emulator/simulator RUNTIME proofs are the
# separate M7-E device/CI lanes; see docs/M7_BACKGROUND_SHARING_PLAN.md).
#
# Design (hardened over two adversarial review rounds that found false-passes):
#   * COMMENT-AWARE: `code_view` strips /* */ + // for Dart/Swift; `xmllint`
#     handles <!-- --> for XML (manifest/plist). A real call can't be hidden by
#     commenting it out while a doc mention keeps the guard green.
#   * VALUE-AWARE: identity checks (channel names, task id) assert the ASSIGNED
#     VALUE (fixed-string), not that a string merely appears — so swapped/typo'd
#     values are caught.
#   * STRUCTURE-BOUND: gate/teardown checks bind to the `if (...) return` guard
#     and to the enclosing function body, not bare token presence — so a token
#     reintroduced in dead code does not pass.
#
# It intentionally does NOT hard-enforce the inert ship-state
# (`backgroundCatchupEnabled == false`, RebootReceiver `enabled="false"`), so it
# does not block the M7-E enable cutover.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

WORKER="${REPO_ROOT}/haven/lib/src/services/background_catchup_worker.dart"
IOS_DART="${REPO_ROOT}/haven/lib/src/services/ios_background_catchup.dart"
MGR="${REPO_ROOT}/haven/lib/src/services/background_location_manager.dart"
MANIFEST="${REPO_ROOT}/haven/android/app/src/main/AndroidManifest.xml"
SLC="${REPO_ROOT}/haven/ios/Runner/HavenSLCHandler.swift"
BGT="${REPO_ROOT}/haven/ios/Runner/HavenBGTaskHandler.swift"
APPDELEGATE="${REPO_ROOT}/haven/ios/Runner/AppDelegate.swift"
PLIST="${REPO_ROOT}/haven/ios/Runner/Info.plist"
PUBSPEC="${REPO_ROOT}/haven/pubspec.yaml"
IOS_DIR="${REPO_ROOT}/haven/ios/Runner"

FAILED=0
fail() {
  echo "FAIL: $*" >&2
  FAILED=1
}

for f in "$WORKER" "$IOS_DART" "$MGR" "$MANIFEST" "$SLC" "$BGT" "$APPDELEGATE" "$PLIST" "$PUBSPEC"; do
  [[ -f "$f" ]] || { echo "FAIL: expected M7 file not found: $f" >&2; exit 1; }
done
command -v xmllint >/dev/null 2>&1 || { echo "FAIL: xmllint (libxml2-utils) is required by this guard" >&2; exit 1; }

# --- comment-aware matching helpers (Dart/Swift) ---------------------------
# Emit $1 with /* */ block comments and // line comments stripped, ONE output
# line per input line (line numbers preserved). (Does not strip // inside string
# literals — acceptable: none of the guarded tokens contain // or /*.)
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
first_code_line()   { code_view "$2" | grep -nF -m1 -- "$1" | cut -d: -f1; }
first_code_line_e() { code_view "$2" | grep -nE -m1 -- "$1" | cut -d: -f1; }
code_has()   { code_view "$2" | grep -qF -- "$1"; }
code_has_e() { code_view "$2" | grep -qE -- "$1"; }
# Value of the FIRST `<lhs> = "<value>"` (Swift) assignment, comment-stripped.
swift_str_value() { code_view "$2" | grep -oE "$1"' *= *"[^"]+"' | grep -oE '"[^"]+"' | tr -d '"' | head -1; }
# Extract the (comment-stripped) body of the function whose signature contains $1.
fn_slice() {
  code_view "$2" | awk -v sig="$1" '
    index($0, sig) > 0 { inbody = 1 }
    inbody {
      print
      o = gsub(/[{]/, "&"); c = gsub(/[}]/, "&")
      depth += o - c
      if (seen && depth <= 0) exit
      if (o > 0) seen = 1
    }'
}

# ---------------------------------------------------------------------------
# 1. Android callbackDispatcher: WidgetsFlutterBinding + DartPluginRegistrant
#    initialised (in that order) BEFORE the WorkManager task body, in EXECUTABLE
#    code. Missing registrant => MissingPluginException → silent no-op (bug #1).
# ---------------------------------------------------------------------------
wfb="$(first_code_line 'WidgetsFlutterBinding.ensureInitialized()' "$WORKER")"
dpr="$(first_code_line 'DartPluginRegistrant.ensureInitialized()' "$WORKER")"
exec_task="$(first_code_line 'Workmanager().executeTask' "$WORKER")"
if [[ -z "$wfb" || -z "$dpr" || -z "$exec_task" ]]; then
  fail "callbackDispatcher missing (in code) WidgetsFlutterBinding (${wfb:-absent}) / DartPluginRegistrant (${dpr:-absent}) / executeTask (${exec_task:-absent}) (reverted-draft bug #1)"
elif ! { [[ "$wfb" -le "$dpr" ]] && [[ "$dpr" -le "$exec_task" ]]; }; then
  fail "callbackDispatcher order wrong: WidgetsFlutterBinding(L$wfb) -> DartPluginRegistrant(L$dpr) -> executeTask(L$exec_task) must be non-decreasing (bug #1)"
fi

# ---------------------------------------------------------------------------
# 2. RebootReceiver (and any descendant) MUST NOT carry tools:node="replace"
#    (strips the plugin's BOOT_COMPLETED intent-filter — bug #2). Uses xmllint so
#    XML comments cannot hide it and child self-closing tags cannot end the scope
#    early. RestartReceiver legitimately keeps it (not matched — scoped by name).
# ---------------------------------------------------------------------------
reboot_count="$(xmllint --nonet --xpath "count(//receiver[contains(@*[local-name()='name'],'RebootReceiver')])" "$MANIFEST" 2>/dev/null)"
if [[ -z "$reboot_count" || "$reboot_count" == "0" ]]; then
  fail "RebootReceiver element not found in $MANIFEST (manifest structure changed?)"
else
  reboot_node_attrs="$(xmllint --nonet --xpath "//receiver[contains(@*[local-name()='name'],'RebootReceiver')]/descendant-or-self::*/@*[local-name()='node']" "$MANIFEST" 2>/dev/null)"
  if grep -q 'replace' <<<"$reboot_node_attrs"; then
    fail "RebootReceiver (or a descendant) carries tools:node=\"replace\" — strips the plugin's BOOT_COMPLETED intent-filter (reverted-draft bug #2)."
  fi
fi

# ---------------------------------------------------------------------------
# 3. No [weak channel] / [unowned channel] capture in the Swift handlers
#    (deallocates before the async closure runs → dead wake / crash — bug #3).
# ---------------------------------------------------------------------------
for f in "$SLC" "$BGT"; do
  if code_has_e '(weak|unowned)[ \t]+channel' "$f"; then
    fail "$(basename "$f") captures the channel [weak/unowned] (reverted-draft bug #3): $(code_view "$f" | grep -nE '(weak|unowned)[ \t]+channel' | head -1)"
  fi
done

# ---------------------------------------------------------------------------
# 4. The channel MUST be a STRONG stored `var channel: FlutterMethodChannel`
#    property, never weak/unowned (regardless of modifier order).
# ---------------------------------------------------------------------------
for f in "$SLC" "$BGT"; do
  decl="$(code_view "$f" | grep -nE 'var +channel *: *FlutterMethodChannel' | head -1)"
  if [[ -z "$decl" ]]; then
    fail "$(basename "$f") has no stored 'var channel: FlutterMethodChannel' property"
  elif grep -qE '(weak|unowned)' <<<"$decl"; then
    fail "$(basename "$f") declares the channel weak/unowned — must be strongly retained: $decl"
  fi
done

# ---------------------------------------------------------------------------
# 5. BGTask identifier parity: HavenBGTaskHandler.taskIdentifier MUST equal an
#    Info.plist BGTaskSchedulerPermittedIdentifiers entry (xmllint = XML-comment
#    safe; fixed-string compare = no regex-metachar leniency).
# ---------------------------------------------------------------------------
swift_id="$(swift_str_value 'static let taskIdentifier' "$BGT")"
if [[ -z "$swift_id" ]]; then
  fail "could not extract HavenBGTaskHandler.taskIdentifier from $BGT"
else
  plist_ids="$(xmllint --nonet --xpath "//key[text()='BGTaskSchedulerPermittedIdentifiers']/following-sibling::array[1]/string/text()" "$PLIST" 2>/dev/null)"
  if ! grep -qF -- "$swift_id" <<<"$plist_ids"; then
    fail "BGTask identifier \"$swift_id\" (Swift) is NOT in Info.plist BGTaskSchedulerPermittedIdentifiers (comment-safe check) — a launch crash on device"
  fi
fi

# ---------------------------------------------------------------------------
# 6. SLC + BGTask teardown channels bound (by VALUE) to their OWN distinct
#    channel — a value swap (each on the WRONG channel → both uncancellable on
#    disable) is caught. The old shared name must appear nowhere.
# ---------------------------------------------------------------------------
if grep -rqs "ios_background_scheduler_teardown" "${REPO_ROOT}/haven/ios" "${REPO_ROOT}/haven/lib"; then
  fail "the collided teardown channel name 'ios_background_scheduler_teardown' still appears — SLC and BGTask must use separate channels"
fi
code_has_e 'teardownChannelName *= *"haven\.app/ios_slc_teardown"' "$SLC" ||
  fail "HavenSLCHandler.teardownChannelName is not bound to \"haven.app/ios_slc_teardown\""
code_has_e 'teardownChannelName *= *"haven\.app/ios_bgtask_teardown"' "$BGT" ||
  fail "HavenBGTaskHandler.teardownChannelName is not bound to \"haven.app/ios_bgtask_teardown\""
code_has_e 'teardownChannelName *= *"haven\.app/ios_bgtask_teardown"' "$SLC" &&
  fail "HavenSLCHandler is bound to the BGTask teardown channel (swapped)"
code_has_e 'teardownChannelName *= *"haven\.app/ios_slc_teardown"' "$BGT" &&
  fail "HavenBGTaskHandler is bound to the SLC teardown channel (swapped)"

# ---------------------------------------------------------------------------
# 7. WorkManager registration double-gated by an actual `if (...) return|{`
#    guard — !backgroundCatchupEnabled (inert) AND !Platform.isAndroid (keeps
#    workmanager_apple inert on iOS) — BEFORE the first Workmanager().initialize().
#    Binds to the guard structure, so a bare condition in dead code won't pass.
# ---------------------------------------------------------------------------
init_line="$(first_code_line 'Workmanager().initialize' "$WORKER")"
flag_gate="$(first_code_line_e 'if[^;{]*!backgroundCatchupEnabled\)[^;]*(return|\{)' "$WORKER")"
android_gate="$(first_code_line_e 'if[^;{]*!Platform\.isAndroid\)[^;]*(return|\{)' "$WORKER")"
if [[ -z "$init_line" ]]; then
  fail "no Workmanager().initialize() found in code in $WORKER"
else
  { [[ -n "$flag_gate" ]] && [[ "$flag_gate" -lt "$init_line" ]]; } ||
    fail "Workmanager().initialize()(L${init_line}) is not preceded by an 'if (!backgroundCatchupEnabled) return;' guard (L${flag_gate:-absent})"
  { [[ -n "$android_gate" ]] && [[ "$android_gate" -lt "$init_line" ]]; } ||
    fail "Workmanager().initialize()(L${init_line}) is not preceded by an 'if (!Platform.isAndroid) return;' guard (L${android_gate:-absent})"
fi

# ---------------------------------------------------------------------------
# 8. iOS handler: an `if (!backgroundCatchupEnabled) return|{` guard precedes the
#    runCatchup FFI call; the Android worker re-checks kBackgroundSharingKey.
# ---------------------------------------------------------------------------
[[ -n "$(first_code_line 'getBool(kBackgroundSharingKey)' "$WORKER")" ]] ||
  fail "Android worker does not re-check intent via getBool(kBackgroundSharingKey) in executable code"
ios_gate="$(first_code_line_e 'if[^;{]*!backgroundCatchupEnabled\)[^;]*(return|\{)' "$IOS_DART")"
ios_call="$(first_code_line 'runCatchup(isBackgroundWake: true)' "$IOS_DART")"
if [[ -z "$ios_call" ]]; then
  fail "iOS handler does not call runCatchup(isBackgroundWake: true) in executable code"
elif [[ -z "$ios_gate" || "$ios_gate" -ge "$ios_call" ]]; then
  fail "iOS handler's 'if (!backgroundCatchupEnabled) return' guard (L${ios_gate:-absent}) does not precede the runCatchup FFI call (L$ios_call)"
fi

# ---------------------------------------------------------------------------
# 9. NO push / FCM / APNs / notification-server creep (the M7 architecture
#    rejects push — a coordinator learning wake-timing is a privacy regression).
#    Broad plugin-name matching (not a fixed allowlist) + the whole ios/Runner
#    tree (incl. *.entitlements) + Podfile for remote-push tokens.
# ---------------------------------------------------------------------------
if grep -qiE '^[[:space:]]+[a-z0-9_]*(firebase_messaging|onesignal|apns|pushy|pusher_beams|airship|urbanairship|notifee)[a-z0-9_]*:' "$PUBSPEC"; then
  fail "a push/FCM/APNs dependency was added to pubspec.yaml — the M7 architecture forbids push (privacy regression)"
fi
push_targets=("$IOS_DIR")
[[ -f "${REPO_ROOT}/haven/ios/Podfile" ]] && push_targets+=("${REPO_ROOT}/haven/ios/Podfile")
if grep -rqsiE 'remote-notification|aps-environment|registerForRemoteNotifications|didReceiveRemoteNotification' "${push_targets[@]}"; then
  fail "a remote/push-notification token (remote-notification / aps-environment / registerForRemoteNotifications / didReceiveRemoteNotification) appears under haven/ios — push background delivery is forbidden by the M7 architecture"
fi

# ---------------------------------------------------------------------------
# 10. No secret/location/error-internal logging in the native wake files (a log
#     that interpolates a sensitive value, logs it via an os_log %{public}
#     specifier, or logs an error's whole value / .localizedDescription).
#     Conservative: current logs use \(type(of: error)) / %@ .code — not flagged.
# ---------------------------------------------------------------------------
LOG_FN='(NSLog|os_log|print|debugPrint|debugLog)'
SENS='coordinate|latitude|longitude|coord|location|geohash|pubkey|npub|nsec|privkey|seckey|secret|exporter|nostr_group|group_id|\blat\b|\blng\b|\blon\b'
for f in "$SLC" "$BGT" "$WORKER" "$IOS_DART" "$APPDELEGATE" "$MGR"; do
  logs="$(code_view "$f" | grep -nE "$LOG_FN")"
  intp="$(echo "$logs" | grep -iE '\\\([^)]*('"$SENS"')|\$\{[^}]*('"$SENS"')|\$('"$SENS"')' | head -1)"
  pub="$(echo "$logs" | grep -F '%{public}' | grep -iE "$SENS" | head -1)"
  errl="$(echo "$logs" | grep -E 'localizedDescription|\\\(error\)|\\\(err\)' | head -1)"
  [[ -z "$intp" ]] || fail "$(basename "$f") logs an interpolated sensitive value: $intp"
  [[ -z "$pub"  ]] || fail "$(basename "$f") logs a sensitive value via os_log %{public}: $pub"
  [[ -z "$errl" ]] || fail "$(basename "$f") logs error internals (whole error / .localizedDescription): $errl"
done

# ---------------------------------------------------------------------------
# 11. Cancel-on-disable kill switch, bound to the ENCLOSING FUNCTIONS (not
#     file-scoped): disableBackgroundScheduling() must call both native teardowns,
#     and cancelNativeSchedulers() must issue both stopSLC + cancelAllBGTasks.
# ---------------------------------------------------------------------------
mgr_body="$(fn_slice 'disableBackgroundScheduling' "$MGR")"
grep -qF -- 'cancelBackgroundCatchup(' <<<"$mgr_body" ||
  fail "disableBackgroundScheduling() does not call cancelBackgroundCatchup() (Android task not cancelled on opt-out)"
grep -qF -- 'cancelNativeSchedulers(' <<<"$mgr_body" ||
  fail "disableBackgroundScheduling() does not call cancelNativeSchedulers() (iOS SLC/BGTask not cancelled on opt-out)"
ios_teardown_body="$(fn_slice 'cancelNativeSchedulers' "$IOS_DART")"
grep -qF -- "invokeMethod<void>('stopSLC')" <<<"$ios_teardown_body" ||
  fail "cancelNativeSchedulers() does not invoke 'stopSLC' (SLC monitoring not stopped on opt-out)"
grep -qF -- "invokeMethod<void>('cancelAllBGTasks')" <<<"$ios_teardown_body" ||
  fail "cancelNativeSchedulers() does not invoke 'cancelAllBGTasks' (pending BGTask not cancelled on opt-out)"

# ---------------------------------------------------------------------------
# 12. Main catch-up trigger channel parity (SLC/BGT Swift + Dart identical) and
#     the trigger MUST be payload-free (arguments: nil) so no location/pubkey can
#     be smuggled through the native->Dart signal.
# ---------------------------------------------------------------------------
slc_ch="$(swift_str_value 'static let channelName' "$SLC")"
bgt_ch="$(swift_str_value 'static let channelName' "$BGT")"
dart_ch="$(code_view "$IOS_DART" | grep -oE "_kCatchupChannelName = '[^']+'" | grep -oE "'[^']+'" | tr -d "'" | head -1)"
if [[ -z "$slc_ch" || "$slc_ch" != "$bgt_ch" || "$slc_ch" != "$dart_ch" ]]; then
  fail "iOS catch-up channel mismatch: SLC='${slc_ch:-?}' BGT='${bgt_ch:-?}' Dart='${dart_ch:-?}' — all must be identical or the wake is silently dead"
fi
for f in "$SLC" "$BGT"; do
  code_has_e 'invokeMethod\("runCatchup", *arguments: *nil' "$f" ||
    fail "$(basename "$f") runCatchup invoke must pass arguments: nil (payload-free trigger — no location/pubkey smuggling)"
done

# ---------------------------------------------------------------------------
# 13. AppDelegate MUST retain the handlers as STORED PROPERTIES (a local would
#     deallocate when didFinishLaunching returns → BGTask [weak self] sees nil
#     → every task marked failed).
# ---------------------------------------------------------------------------
code_has_e 'private +(lazy +)?(let|var) +bgTaskHandler' "$APPDELEGATE" ||
  fail "AppDelegate does not retain bgTaskHandler as a stored property"
code_has_e 'private +(lazy +)?(let|var) +slcHandler' "$APPDELEGATE" ||
  fail "AppDelegate does not retain slcHandler as a stored property"

# ---------------------------------------------------------------------------
if [[ "$FAILED" -ne 0 ]]; then
  echo "M7-C/D native-wake guard FAILED — see failures above." >&2
  exit 1
fi
echo "OK: M7-C/D native-wake structural invariants hold (13 checks)."
