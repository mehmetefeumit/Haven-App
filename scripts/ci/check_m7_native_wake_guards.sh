#!/usr/bin/env bash
# CI guard: structural correctness invariants for the M7-C/D native background
# wakes (Android WorkManager + iOS SLC/BGTask).
#
# These are the STATIC, always-true invariants whose violation reintroduces one
# of the exact bugs that sank the 2026-07-02 native-wake draft, or a bug an
# adversarial review caught in M7-C/D / M7-E. Pure source checks (grep/awk +
# xmllint for XML) — no Flutter/Gradle/Xcode — so they run fast and independently,
# and CAN be verified on any box (the emulator/simulator RUNTIME proofs are the
# separate M7-E device/CI lanes; see docs/M7_BACKGROUND_SHARING.md).
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
# CHECK 9b — THE DEPENDENCY SURFACE — is the one check documented here rather
# than beside its code, because what it does NOT reach matters as much as what
# it does. `privacyWhatHavenIsDetailNoTelemetry` promises, in thirteen
# languages, that "the app contains no analytics, crash reporting, or
# advertising code" and that this "can be checked rather than taken on trust".
# Check 9 already refuses a PUSH plugin; 9b is its sibling and shares its idiom.
# It scans every place such a dependency can ARRIVE that this repo owns:
#
#   * `haven/pubspec.yaml` — direct AND dev dependencies. A dev dependency
#     FAILS TOO, deliberately. "It does not ship" is not true here: Flutter
#     registers dev-dependency plugins in GeneratedPluginRegistrant for release
#     builds, which is exactly why haven/android/app/build.gradle.kts carries a
#     `compileOnly(project(":integration_test"))` workaround. A reporting SDK
#     in dev_dependencies is also live on every developer and CI device, and it
#     is indistinguishable from a shipped one to the reader that the claim's
#     second sentence invites to check the source.
#   * `haven/pubspec.lock` — the TRANSITIVE graph, which the pubspec cannot
#     show. An SDK pulled in by an innocent-looking package arrives here and
#     nowhere else.
#   * `haven-core/` + `haven/rust_builder/` Cargo.toml and Cargo.lock — the
#     Rust core is compiled into the app, so `sentry`/`opentelemetry` there
#     ships exactly as a Dart package does.
#   * every `*.gradle`/`*.gradle.kts` under `haven/android` — Firebase
#     Analytics and Crashlytics arrive as a GRADLE PLUGIN
#     (`com.google.gms.google-services`, `com.google.firebase.crashlytics`) or
#     a Maven coordinate, which a Dart-only pubspec scan would never see.
#   * `AndroidManifest.xml` android:name attributes — AdMob needs a
#     `com.google.android.gms.ads.APPLICATION_ID` meta-data, Sentry an
#     `io.sentry.dsn` one.
#   * `haven/ios/Runner/Info.plist` KEYS, never its free text —
#     `SKAdNetworkItems`, `NSUserTrackingUsageDescription`,
#     `GADApplicationIdentifier`.
#   * `haven/ios/Runner/PrivacyInfo.xcprivacy` — Apple's own machine-readable
#     twin of this claim, pinned in both directions: NSPrivacyTracking false,
#     no tracking domains, no Analytics/Advertising collection purpose. Any ad
#     or attribution SDK forces all three to change.
#   * `haven/ios/Podfile` when present (CocoaPods manifests are generated at
#     build time and are not committed here).
#   * files whose mere PRESENCE is an SDK: google-services.json,
#     GoogleService-Info.plist, agconnect-services.json, sentry.properties.
#
# It then reads the promise itself out of `haven/lib/l10n/app_*.arb`; see THE
# COPY HALF below for what that does and does not establish.
#
# WHAT 9b CANNOT REACH, stated plainly so a green run is not read as more than
# it is: (a) a HAND-ROLLED report — an http.post of usage data from Dart, Rust,
# Kotlin or Swift — is not a dependency, and no name scan can see one; (b) a
# telemetry SDK vendored INSIDE another plugin's own Android/iOS artifact,
# which lives in the pub cache rather than this repo (only that plugin's pub
# name is visible here); (c) a Gradle coordinate assembled from variables, a
# version catalog or an included build; (d) ANY dependency whose NAME carries
# none of the tokens below.
#
# (d) is the wide one, and it is not merely the "republished under an innocuous
# name" case an earlier draft of this header conceded. It is the ordinary case
# of an SDK the list has not been taught yet: an adversarial review on
# 2026-08-13 added `usage` (Google's own analytics package for Dart),
# `clarity_flutter` (Microsoft Clarity), `openreplay_flutter` and
# `glean_flutter` (Mozilla) as direct pubspec dependencies UNDER THEIR REAL
# NAMES, and this check stayed green on all four. All four are matched now; the
# fifth one is not. So the token list is deliberately TWO layers — what a
# package DOES (`analytics`, `telemetry`, `metrics`, `usage`, `attribution`,
# `session_replay`, `crash`, `apm`, `ads`: the words an SDK's own name usually
# says out loud, and the layer that does not go stale when a vendor is renamed
# or acquired) and WHO ships it (a hand-maintained vendor roster, which lags by
# construction). Even both layers together only raise the cost of adding one of
# the SDKs people actually reach for. A name scan is not, and is not claimed to
# be, a proof that no telemetry is present; the claim's own second sentence —
# that this can be CHECKED rather than taken on trust — is what carries the rest.
#
# What 9b does make impossible is the failure mode a name scan usually dies of:
# quietly examining nothing. Every manifest must exist AND yield the positions
# it is read for, each floored where it is read rather than in a shared total —
# pubspec `dependencies:` and `dev_dependencies:` counted and floored SEPARATELY
# (a section renamed away must not be covered by the other section's positions),
# every Cargo manifest and lockfile, EVERY Gradle file at least one line of
# executable build code (a file truncated to nothing still counts toward a file
# TOTAL, so the count of files was never a floor), the AndroidManifest at least
# one component and the Info.plist at least one key. The run prints what it read.
#
# THE COPY HALF IS SPLIT, the way check_ios_privacy_blur.sh splits it and for
# the same reason. This file says "in thirteen languages" in its own prose and
# in a failure message, and a number a guard asserts but does not check is the
# overclaim this workstream exists to remove — so all thirteen locale ARBs are
# checked here for the key's PRESENCE and non-emptiness. A locale file deleted,
# or a translation emptied, takes the promise with it and no English review
# would ever see it. The ENGLISH WORDING is checked by rule 10 of
# check_privacy_invariants.sh, which reads app_en.arb and only app_en.arb. A
# translation SOFTENED — reworded to promise less, in a language most reviewers
# of this repo cannot read — is not detectable here and is not claimed to be.
#
# Checks 1-13 are milestone-independent (true whether the feature is inert or
# live). Checks 14a-14i pin the RELEASED state so a regression cannot silently
# RE-INERT a shipped feature (flag flipped back, RebootReceiver re-disabled,
# autoRunOnBoot dropped, the bootstrap reverted to the stub, an arming call-site
# deleted, or the persistent live-sync engine turned back off) without turning
# this gate red. On an intentional M7-E rollback (plan §7) checks
# 14a/14c/14e/14f/14g/14h/14i are reverted together with the code they pin; on an
# intentional live-sync rollback (M11 plan §8) 14b is reverted with the
# `defaultValue: false` it pins. 14d is rollback-independent. `liveSyncEnabled`
# defaults to `true` since M11 Phase B (the persistent live-sync engine is LIVE
# in production) and is pinned by 14b — a `bool.fromEnvironment('HAVEN_LIVE_SYNC',
# defaultValue: true)` const.
#
# Usage:
#   check_m7_native_wake_guards.sh              # check the repo
#   check_m7_native_wake_guards.sh --self-test  # hermetic fixtures for check 9b
#
# Exit codes:
#   0  all checks pass
#   1  an invariant is violated (including "found nothing to scan" — a moved or
#      renamed manifest is a guard failure, never a clean tree)
#   2  the guard itself is broken (bad usage, a failed self-test, a missing
#      tool)

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
LIVE_SYNC="${REPO_ROOT}/haven/lib/src/providers/live_sync_provider.dart"
MAIN="${REPO_ROOT}/haven/lib/main.dart"

FAILED=0
fail() {
  echo "FAIL: $*" >&2
  FAILED=1
}

command -v xmllint >/dev/null 2>&1 || { echo "ERROR: xmllint (libxml2-utils) is required by this guard" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "ERROR: jq is required by this guard (check 9b reads the locale ARBs)" >&2; exit 2; }

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
# Every helper MATERIALISES the code_view output into a local BEFORE matching
# it, so an early-exiting consumer (grep -q / grep -m1 / head -1 / awk exit)
# cannot SIGPIPE the code_view awk mid-stream and — under `set -o pipefail` —
# flip a genuine match into a false miss (a nondeterministic, load-dependent
# flake: the awk dies with 141, which pipefail surfaces as the pipeline status).
first_code_line()   { local v; v="$(code_view "$2")"; grep -nF -m1 -- "$1" <<<"$v" | cut -d: -f1; }
first_code_line_e() { local v; v="$(code_view "$2")"; grep -nE -m1 -- "$1" <<<"$v" | cut -d: -f1; }
code_has()   { local v; v="$(code_view "$2")"; grep -qF -- "$1" <<<"$v"; }
code_has_e() { local v; v="$(code_view "$2")"; grep -qE -- "$1" <<<"$v"; }
# Value of the FIRST `<lhs> = "<value>"` (Swift) assignment, comment-stripped.
swift_str_value() { local v; v="$(code_view "$2")"; grep -oE "$1"' *= *"[^"]+"' <<<"$v" | grep -oE '"[^"]+"' | tr -d '"' | head -1; }
# Extract the (comment-stripped) body of the function whose signature contains $1.
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

# ===========================================================================
# CHECK 9b — the analytics / crash-reporting / advertising dependency surface.
# Written as a function over a tree ROOT so `--self-test` can drive it against
# hermetic fixtures; the real run passes $REPO_ROOT. See the header for the
# arrival paths it covers and the four it cannot.
# ===========================================================================

# Dependency-NAME tokens, matched as a substring of a name that stands in a
# DEPENDENCY POSITION — a pubspec/lock/Cargo key — and never as free text.
# "no analytics" in a comment, the `isMonitoringTool` manifest flag and a Dart
# identifier called `crashCount` are all legitimate and must not trip this.
# Names are lower-cased and hyphens folded to underscores first, so `unity-ads`
# and `unity_ads` are one token.
#
# TWO LAYERS, for the reason the header gives: a vendor roster alone let four
# real SDKs through under their real names. Tokens that are also ordinary
# English words (`usage`, `metrics`, `insights`, `apm`, `clarity`, `singular`)
# are anchored to whole underscore-separated words so they match a name's own
# component and not a fragment of a longer one.

# Layer 1 — what the package DOES. An SDK's name usually says it out loud, and
# this layer keeps matching when a vendor is renamed, acquired or forked.
TELEMETRY_NAME_DOES_RE='analytics|telemetry|(^|_)metrics?(_|$)|(^|_)usage(_|$)|(^|_)insights?(_|$)|(^|_)apm(_|$)|attribution|session_replay|sessionreplay|heatmap|error_report|crash|statsd|firebase_performance|firebase_inappmessaging|admob|(^|_)ads(_|$)|audience_network'

# Layer 2 — WHO ships it. Hand-maintained, and therefore always one SDK behind;
# it exists to catch the products people actually reach for, not to be complete.
TELEMETRY_NAME_VENDOR_RE='sentry|bugsnag|rollbar|instabug|raygun|embrace|datadog|newrelic|new_relic|dynatrace|appdynamics|appcenter|app_center|countly|amplitude|mixpanel|posthog|matomo|clevertap|braze|smartlook|fullstory|logrocket|aptabase|mparticle|flurry|appmetrica|umeng|bugly|honeycomb|(^|_)clarity(_|$)|openreplay|(^|_)glean(_|$)|uxcam|hotjar|mouseflow|contentsquare|moengage|webengage|leanplum|swrve|statsig|rudderstack|snowplow|(^|_)singular(_|$)|adbrix|quantcast|bugfender|appsignal|honeybadger|airbrake|sumologic|loggly|applovin|ironsource|facebook_app_events|appsflyer|adjust_sdk|branch_sdk|kochava|tenjin|tapjoy|vungle|chartboost|inmobi|appodeal'

TELEMETRY_NAME_RE="${TELEMETRY_NAME_DOES_RE}|${TELEMETRY_NAME_VENDOR_RE}"

# Gradle plugin ids, Maven coordinates and CocoaPods names. Matched
# case-insensitively against COMMENT-STRIPPED lines of a build file, which is
# the native half a Dart-only scan misses entirely: `firebase_analytics` never
# has to appear in pubspec.yaml for the Firebase Analytics SDK to be linked in.
TELEMETRY_NATIVE_RE='google-services|firebase-analytics|firebase-crashlytics|firebase-perf|firebase-inappmessaging|firebase\.crashlytics|play-services-ads|play-services-measurement|google\.android\.ump|google-mobile-ads|googlemobileads|io\.sentry|sentry-android|sentry-cocoa|com\.bugsnag|com\.newrelic|com\.datadoghq|com\.dynatrace|com\.appdynamics|com\.appsflyer|appsflyerframework|com\.adjust|com\.amplitude|com\.mixpanel|com\.applovin|unity3d\.ads|com\.ironsource|io\.branch|com\.crashlytics|com\.smartlook|io\.embrace|microsoft\.appcenter|microsoft\.clarity|openreplay|mozilla\.telemetry|ch\.acra|io\.uxcam|com\.singular|ly\.count\.android|com\.posthog|com\.segment|com\.instabug|tencent\.bugly|com\.umeng|facebook-android-sdk|firebase/analytics|firebase/crashlytics|firebase/performance'

# android:name attributes an ad/analytics SDK requires to function at all.
TELEMETRY_MANIFEST_RE='google\.android\.gms\.ads|com\.google\.firebase|firebase_|crashlytics|analytics|io\.sentry|appsflyer|com\.adjust|amplitude|applovin|bugsnag|instabug|datadog|newrelic|unity3d\.ads|ironsource|appmetrica'

# Info.plist keys that only an analytics, attribution or ad SDK ever needs.
TELEMETRY_PLIST_KEYS=(
  NSUserTrackingUsageDescription
  NSAdvertisingAttributionReportEndpoint
  SKAdNetworkItems
  GADApplicationIdentifier
  GADIsAdManagerApp
  GADDelayAppMeasurementInit
  FirebaseAppDelegateProxyEnabled
  FirebaseAutomaticScreenReportingEnabled
  FirebaseCrashlyticsCollectionEnabled
  FirebaseDataCollectionDefaultEnabled
  AppsFlyerDevKey
  BugsnagAPIKey
  SentryDSN
  InstabugToken
)

# PrivacyInfo.xcprivacy collection purposes. Apple's list separates "this app
# works" from "we measure you"; the second and third are the claim's own words.
TELEMETRY_PRIVACY_PURPOSES=(
  NSPrivacyCollectedDataTypePurposeAnalytics
  NSPrivacyCollectedDataTypePurposeThirdPartyAdvertising
  NSPrivacyCollectedDataTypePurposeDeveloperAdvertising
)

# Files that exist for no reason other than to configure one of these SDKs.
TELEMETRY_MARKER_FILES=(
  haven/android/app/google-services.json
  haven/android/google-services.json
  haven/android/app/agconnect-services.json
  haven/ios/Runner/GoogleService-Info.plist
  haven/ios/GoogleService-Info.plist
  haven/sentry.properties
  haven/android/sentry.properties
  haven/ios/sentry.properties
)

# How many locale ARBs must still carry the promise. Pinned because this file
# says "thirteen languages" in its own header and in a failure message below,
# and a number a guard asserts but does not check is exactly the overclaim it
# is here to prevent. Dropping a language is a decision: make it here and in
# the wording this constant pins, in the same commit.
LOCALE_ARB_FLOOR=13

# Gradle/Kotlin-DSL comment view. NOT the shared `code_view`: that one strips
# from any `//` to end of line, which eats the tail of every `https://` URL —
# and a custom Maven repo URL (`uri("https://sentry.io/maven")`) is precisely
# where a coordinate hides. A `//` preceded by `:` is therefore left alone.
gradle_code_view() {
  awk '
    {
      line = $0; out = ""; i = 1; n = length(line)
      while (i <= n) {
        if (inblock) {
          e = index(substr(line, i), "*/")
          if (e == 0) { i = n + 1 } else { i += e + 1; inblock = 0 }
        } else {
          two = substr(line, i, 2)
          prev = (i > 1) ? substr(line, i - 1, 1) : ""
          if (two == "/*") { inblock = 1; i += 2 }
          else if (two == "//" && prev != ":") { i = n + 1 }
          else { out = out substr(line, i, 1); i += 1 }
        }
      }
      print out
    }' "$1"
}

# --- dependency-position extractors ----------------------------------------
# Each prints one "<line>\t[<section>\t]<name>" per position and nothing else.
# The floors in the scan count these lines, so a manifest that was renamed or
# reshaped yields zero and FAILS instead of certifying a clean tree.

# pubspec keys under dependencies / dev_dependencies / dependency_overrides.
# `#` to end of line is dropped first: the key is always left of any comment,
# so over-eager stripping can hide no dependency, only a comment about one.
pubspec_dep_names() { # <pubspec.yaml>
  awk '
    { line = $0; sub(/#.*/, "", line) }
    line ~ /^[A-Za-z_][A-Za-z0-9_]*:/ { sec = line; sub(/:.*/, "", sec); next }
    (sec == "dependencies" || sec == "dev_dependencies" || sec == "dependency_overrides") \
      && line ~ /^[ \t]+[A-Za-z0-9_]+:/ {
        name = line; sub(/^[ \t]+/, "", name); sub(/:.*/, "", name)
        print NR "\t" sec "\t" name
      }' "$1"
}

# pubspec.lock package blocks: a bare `  <name>:` at exactly two spaces under
# `packages:`. Everything deeper is that package's metadata.
pubspec_lock_names() { # <pubspec.lock>
  awk '
    { line = $0; sub(/#.*/, "", line) }
    line ~ /^[A-Za-z_][A-Za-z0-9_]*:/ { sec = line; sub(/:.*/, "", sec); next }
    sec == "packages" && line ~ /^  [A-Za-z0-9_]+:[ \t]*$/ {
      name = line; sub(/^[ \t]+/, "", name); sub(/:.*/, "", name)
      print NR "\t" name
    }' "$1"
}

# Cargo keys under [dependencies] / [dev-dependencies] / [build-dependencies],
# including their `[target.'cfg(...)'.dependencies]` and `[dependencies.foo]`
# forms.
cargo_dep_names() { # <Cargo.toml>
  awk '
    { line = $0; sub(/#.*/, "", line) }
    line ~ /^[ \t]*\[/ {
      sec = line; sub(/^[ \t]*\[+/, "", sec); sub(/\]+[ \t]*$/, "", sec)
      if (sec ~ /(^|\.)(dependencies|dev-dependencies|build-dependencies)\.[A-Za-z0-9_-]+$/) {
        n = sec; sub(/.*\./, "", n); print NR "\t" n
      }
      next
    }
    sec ~ /(^|\.)(dependencies|dev-dependencies|build-dependencies)$/ \
      && line ~ /^[A-Za-z0-9_-]+[ \t]*=/ {
        name = line; sub(/[ \t]*=.*/, "", name); print NR "\t" name
      }' "$1"
}

# Every resolved crate, direct or transitive — the Rust twin of pubspec.lock.
cargo_lock_names() { # <Cargo.lock>
  awk -F'"' '/^name = "/ { print NR "\t" $2 }' "$1"
}

telemetry_name_hit() { # <name> -> 0 when the name is an analytics/crash/ad SDK
  local n="${1,,}"
  grep -qE "${TELEMETRY_NAME_RE}" <<<"${n//-/_}"
}

# ---------------------------------------------------------------------------
# telemetry_dependency_scan <tree-root>   -> 0 clean, 1 violated or vacuous
# ---------------------------------------------------------------------------
telemetry_dependency_scan() {
  local root="$1" fail=0
  local n_files=0 n_dep=0 n_dep_main=0 n_dep_dev=0 n_lock=0 n_rust=0
  local n_gradle=0 n_gradle_lines=0
  local n_plist=0 n_manifest=0 n_pods=0 n_arb=0

  t_fail() { echo "FAIL: 9b: $*" >&2; fail=1; }

  # -- Dart, direct and dev --------------------------------------------------
  local pubspec="${root}/haven/pubspec.yaml"
  if [[ ! -f "${pubspec}" ]]; then
    t_fail "haven/pubspec.yaml is missing. The dependency scan behind \
privacyWhatHavenIsDetailNoTelemetry has nothing to read, which is a guard \
failure — if the app moved, move this scan with it."
  else
    n_files=$(( n_files + 1 ))
    local deps ln sec name
    deps="$(pubspec_dep_names "${pubspec}")"
    [[ -n "${deps}" ]] && n_dep="$(grep -c '' <<<"${deps}")"
    # Floored PER SECTION, never on the sum: on one combined count, renaming
    # `dependencies:` alone is covered by the dev_dependencies positions and
    # passes — which is precisely what the message below claims to catch.
    # `dependency_overrides:` is legitimately absent from this pubspec and is
    # scanned when present, so it gets no floor.
    n_dep_main="$(awk -F'\t' '$2 == "dependencies"' <<<"${deps}" | grep -c '[^[:space:]]')"
    n_dep_dev="$(awk -F'\t' '$2 == "dev_dependencies"' <<<"${deps}" | grep -c '[^[:space:]]')"
    local empty_sections=()
    (( n_dep_main > 0 )) || empty_sections+=('dependencies')
    (( n_dep_dev > 0 ))  || empty_sections+=('dev_dependencies')
    if (( ${#empty_sections[@]} > 0 )); then
      t_fail "haven/pubspec.yaml yielded no dependency positions under: \
${empty_sections[*]} (dependencies=${n_dep_main}, dev_dependencies=${n_dep_dev}). \
That heading was renamed or its entries reshaped, so the half of this scan that \
reads it examined nothing and would stay green forever."
    fi
    while IFS=$'\t' read -r ln sec name; do
      [[ -n "${name}" ]] || continue
      telemetry_name_hit "${name}" || continue
      if [[ "${sec}" == "dev_dependencies" ]]; then
        t_fail "haven/pubspec.yaml:${ln} declares '${name}' under \
dev_dependencies. A dev dependency fails this check on purpose: Flutter \
registers dev-dependency plugins in GeneratedPluginRegistrant for RELEASE \
builds (the reason build.gradle.kts carries a compileOnly integration_test \
workaround), it reports from every developer and CI device regardless, and the \
claim invites the reader to check the source — where it is indistinguishable \
from a shipped one."
      else
        t_fail "haven/pubspec.yaml:${ln} declares '${name}' under ${sec}. \
privacyWhatHavenIsDetailNoTelemetry promises, in thirteen languages, that the \
app contains no analytics, crash-reporting or advertising code. Remove the \
promise in every locale first if that is really changing."
      fi
    done <<<"${deps}"
  fi

  # -- Dart, transitive ------------------------------------------------------
  local lock="${root}/haven/pubspec.lock"
  if [[ ! -f "${lock}" ]]; then
    t_fail "haven/pubspec.lock is missing. It is the only place the TRANSITIVE \
graph is visible — an SDK pulled in by an innocent-looking package appears \
there and in no manifest a human writes."
  else
    n_files=$(( n_files + 1 ))
    local locks
    locks="$(pubspec_lock_names "${lock}")"
    [[ -n "${locks}" ]] && n_lock="$(grep -c '' <<<"${locks}")"
    if (( n_lock == 0 )); then
      t_fail "haven/pubspec.lock yielded no package entries — its packages: \
section changed shape, so the transitive half of this scan examined nothing."
    fi
    while IFS=$'\t' read -r ln name; do
      [[ -n "${name}" ]] || continue
      telemetry_name_hit "${name}" || continue
      t_fail "haven/pubspec.lock:${ln} resolves '${name}', an \
analytics/crash-reporting/advertising package. It is transitive — no manifest \
in this repo names it — but it ships, and the claim is about what ships."
    done <<<"${locks}"
  fi

  # -- Rust: the core is compiled into the app -------------------------------
  local manifest_path
  for manifest_path in haven-core/Cargo.toml haven/rust_builder/Cargo.toml; do
    if [[ ! -f "${root}/${manifest_path}" ]]; then
      t_fail "${manifest_path} is missing — the Rust half of the app is \
unscanned, and a reporting crate there ships exactly as a Dart package does."
      continue
    fi
    n_files=$(( n_files + 1 ))
    local rust_deps
    rust_deps="$(cargo_dep_names "${root}/${manifest_path}")"
    if [[ -z "${rust_deps}" ]]; then
      t_fail "${manifest_path} yielded no dependency positions — its \
[dependencies] tables moved or changed shape."
      continue
    fi
    n_rust=$(( n_rust + $(grep -c '' <<<"${rust_deps}") ))
    while IFS=$'\t' read -r ln name; do
      [[ -n "${name}" ]] || continue
      telemetry_name_hit "${name}" || continue
      t_fail "${manifest_path}:${ln} declares the crate '${name}'. The Rust \
core is linked into the shipped app, so a reporting crate there falsifies the \
claim exactly as a Flutter plugin would."
    done <<<"${rust_deps}"
  done
  for manifest_path in haven-core/Cargo.lock haven/rust_builder/Cargo.lock; do
    if [[ ! -f "${root}/${manifest_path}" ]]; then
      t_fail "${manifest_path} is missing — the transitive Rust graph is \
unscanned."
      continue
    fi
    n_files=$(( n_files + 1 ))
    local rust_locks
    rust_locks="$(cargo_lock_names "${root}/${manifest_path}")"
    if [[ -z "${rust_locks}" ]]; then
      t_fail "${manifest_path} yielded no crate names — the lockfile format \
changed, so this scan examined nothing."
      continue
    fi
    n_rust=$(( n_rust + $(grep -c '' <<<"${rust_locks}") ))
    while IFS=$'\t' read -r ln name; do
      [[ -n "${name}" ]] || continue
      telemetry_name_hit "${name}" || continue
      t_fail "${manifest_path}:${ln} resolves the crate '${name}', a \
telemetry/crash-reporting crate, into the shipped Rust core."
    done <<<"${rust_locks}"
  done

  # -- Android build files: the layer a pubspec scan cannot see ---------------
  local gradle_files=() gf
  while IFS= read -r gf; do
    [[ -n "${gf}" ]] && gradle_files+=("${gf}")
  done < <(find "${root}/haven/android" -type f \( -name '*.gradle' -o -name '*.gradle.kts' \) \
    -not -path '*/build/*' -not -path '*/.gradle/*' 2>/dev/null | sort)
  if (( ${#gradle_files[@]} == 0 )); then
    t_fail "no *.gradle/*.gradle.kts files found under haven/android. Firebase \
Analytics and Crashlytics arrive as a Gradle plugin, not a Dart package, so \
with these files unreadable the scan's native half certifies nothing."
  else
    n_gradle="${#gradle_files[@]}"
    n_files=$(( n_files + n_gradle ))
    for gf in "${gradle_files[@]}"; do
      local view hits n_lines
      view="$(gradle_code_view "${gf}")"
      # The floor is PER FILE, and it is on CODE LINES rather than on the file
      # count: a build file truncated to nothing still counts toward a total of
      # files, so counting files never floored anything. Emptying both of them
      # used to leave this scan green with nothing read at all.
      n_lines="$(grep -c '[^[:space:]]' <<<"${view}")"
      n_gradle_lines=$(( n_gradle_lines + n_lines ))
      if (( n_lines == 0 )); then
        t_fail "${gf#"${root}/"} contains no executable build code. A Gradle \
file emptied (or commented out entirely) is unreadable to this scan, and the \
Gradle layer is the only place a Firebase Analytics or Crashlytics plugin ever \
appears — a Dart-only scan would never see it."
        continue
      fi
      hits="$(grep -inE "${TELEMETRY_NATIVE_RE}|${TELEMETRY_NAME_RE}" <<<"${view}")"
      [[ -z "${hits}" ]] && continue
      t_fail "${gf#"${root}/"} applies an analytics/crash-reporting/ad SDK in \
executable build code: ${hits//$'\n'/ | }. A Gradle plugin or Maven coordinate \
links the SDK in without ever appearing in pubspec.yaml."
    done
  fi

  # -- AndroidManifest components (xmllint: an XML comment is not a component) -
  local android_manifest="${root}/haven/android/app/src/main/AndroidManifest.xml"
  if [[ ! -f "${android_manifest}" ]]; then
    t_fail "haven/android/app/src/main/AndroidManifest.xml is missing — AdMob's \
APPLICATION_ID meta-data and Sentry's io.sentry.dsn would go unseen."
  elif ! xmllint --nonet --noout "${android_manifest}" 2>/dev/null; then
    t_fail "haven/android/app/src/main/AndroidManifest.xml is not well-formed \
XML; this scan cannot read it."
  else
    n_files=$(( n_files + 1 ))
    local names
    names="$(xmllint --nonet --xpath "//*[@*[local-name()='name']]/@*[local-name()='name']" \
      "${android_manifest}" 2>/dev/null | tr ' ' '\n' | grep -c 'name=')"
    n_manifest="${names:-0}"
    if (( n_manifest == 0 )); then
      t_fail "haven/android/app/src/main/AndroidManifest.xml declares no \
android:name attributes — the manifest changed shape and this scan read nothing."
    fi
    local bad
    bad="$(xmllint --nonet --xpath "//*[@*[local-name()='name']]/@*[local-name()='name']" \
      "${android_manifest}" 2>/dev/null | tr ' ' '\n' | grep -iE "${TELEMETRY_MANIFEST_RE}")"
    if [[ -n "${bad}" ]]; then
      t_fail "AndroidManifest.xml registers an analytics/ad component: \
${bad//$'\n'/ | }. AdMob cannot initialise without its APPLICATION_ID \
meta-data and Sentry cannot without its DSN, so this is the manifest half of \
an SDK that is already linked."
    fi
  fi

  # -- iOS Info.plist: KEYS, never free text ---------------------------------
  local ios_plist="${root}/haven/ios/Runner/Info.plist"
  if [[ ! -f "${ios_plist}" ]]; then
    t_fail "haven/ios/Runner/Info.plist is missing — SKAdNetworkItems and \
NSUserTrackingUsageDescription would go unseen."
  elif ! xmllint --nonet --noout "${ios_plist}" 2>/dev/null; then
    t_fail "haven/ios/Runner/Info.plist is not well-formed XML; this scan \
cannot read it."
  else
    n_files=$(( n_files + 1 ))
    n_plist="$(xmllint --nonet --xpath "count(//key)" "${ios_plist}" 2>/dev/null || echo 0)"
    if [[ "${n_plist}" == "0" ]]; then
      t_fail "haven/ios/Runner/Info.plist contains no <key> elements — it \
changed shape and this scan read nothing."
    fi
    local k count
    for k in "${TELEMETRY_PLIST_KEYS[@]}"; do
      count="$(xmllint --nonet --xpath "count(//key[text()='${k}'])" "${ios_plist}" 2>/dev/null || echo 0)"
      [[ "${count}" == "0" ]] && continue
      t_fail "haven/ios/Runner/Info.plist declares ${k}. Nothing but an \
analytics, attribution or advertising SDK needs that key."
    done
  fi

  # -- PrivacyInfo.xcprivacy: Apple's machine-readable twin of the claim ------
  local xcprivacy="${root}/haven/ios/Runner/PrivacyInfo.xcprivacy"
  if [[ ! -f "${xcprivacy}" ]]; then
    t_fail "haven/ios/Runner/PrivacyInfo.xcprivacy is missing. It is where \
Haven tells Apple, machine-readably, that it does not track — deleting it does \
not make the claim true, it makes it uncheckable."
  elif ! xmllint --nonet --noout "${xcprivacy}" 2>/dev/null; then
    t_fail "haven/ios/Runner/PrivacyInfo.xcprivacy is not well-formed XML; \
this scan cannot read it."
  else
    n_files=$(( n_files + 1 ))
    local tracking domains purpose count
    tracking="$(xmllint --nonet --xpath \
      "local-name(//key[text()='NSPrivacyTracking']/following-sibling::*[1])" \
      "${xcprivacy}" 2>/dev/null)"
    if [[ "${tracking}" != "false" ]]; then
      t_fail "PrivacyInfo.xcprivacy declares NSPrivacyTracking = \
'${tracking:-absent}', which must be 'false'. Any ad or attribution SDK forces \
this to true, and the app then tells Apple the opposite of what it tells the \
user."
    fi
    domains="$(xmllint --nonet --xpath \
      "count(//key[text()='NSPrivacyTrackingDomains']/following-sibling::array[1]/string)" \
      "${xcprivacy}" 2>/dev/null || echo 0)"
    if [[ "${domains}" != "0" ]]; then
      t_fail "PrivacyInfo.xcprivacy lists ${domains} NSPrivacyTrackingDomains. \
That array is the list of hosts the app reports to; it must stay empty."
    fi
    for purpose in "${TELEMETRY_PRIVACY_PURPOSES[@]}"; do
      count="$(xmllint --nonet --xpath "count(//string[text()='${purpose}'])" \
        "${xcprivacy}" 2>/dev/null || echo 0)"
      [[ "${count}" == "0" ]] && continue
      t_fail "PrivacyInfo.xcprivacy declares the collection purpose ${purpose}. \
Haven collects location for app functionality only; measuring or advertising \
against it is the thing the claim says does not happen."
    done
    count="$(xmllint --nonet --xpath \
      "count(//key[text()='NSPrivacyCollectedDataTypeTracking']/following-sibling::true)" \
      "${xcprivacy}" 2>/dev/null || echo 0)"
    if [[ "${count}" != "0" ]]; then
      t_fail "PrivacyInfo.xcprivacy marks a collected data type as used for \
TRACKING (NSPrivacyCollectedDataTypeTracking = true)."
    fi
  fi

  # -- CocoaPods, when a Podfile is committed (it is generated at build time) -
  local podfile="${root}/haven/ios/Podfile"
  if [[ -f "${podfile}" ]]; then
    n_files=$(( n_files + 1 ))
    n_pods=1
    local pod_hits
    pod_hits="$(sed 's/#.*$//' "${podfile}" | grep -inE "${TELEMETRY_NATIVE_RE}|${TELEMETRY_NAME_RE}")"
    if [[ -n "${pod_hits}" ]]; then
      t_fail "haven/ios/Podfile installs an analytics/crash-reporting/ad pod: \
${pod_hits//$'\n'/ | }."
    fi
  fi

  # -- files that only exist to configure one of these SDKs ------------------
  local marker
  for marker in "${TELEMETRY_MARKER_FILES[@]}"; do
    [[ -e "${root}/${marker}" ]] || continue
    t_fail "${marker} exists. That file has exactly one purpose — configuring \
an analytics/crash-reporting SDK — so its presence is the SDK, whatever the \
build files say."
  done

  # -- the promise itself, in every locale that ships it ---------------------
  # Presence and non-emptiness only. This is the half rule 10 of
  # check_privacy_invariants.sh cannot cover: it reads app_en.arb alone, so the
  # twelve translations of a claim this file calls a thirteen-language promise
  # were checked by nothing. A softened translation is still invisible to both;
  # see the header.
  local l10n_dir="${root}/haven/lib/l10n"
  local arbs=() af locale value arb_missing=()
  for af in "${l10n_dir}"/app_*.arb; do
    [[ -f "${af}" ]] && arbs+=("${af}")
  done
  n_arb="${#arbs[@]}"
  for af in "${arbs[@]}"; do
    n_files=$(( n_files + 1 ))
    if ! jq -e . "${af}" >/dev/null 2>&1; then
      t_fail "${af#"${root}/"} is not valid JSON, so this scan cannot tell \
whether the no-telemetry promise is still made in that language."
      continue
    fi
    value="$(jq -r '.privacyWhatHavenIsDetailNoTelemetry // ""' "${af}")"
    locale="${af##*/app_}"
    [[ -n "${value//[[:space:]]/}" ]] || arb_missing+=("${locale%.arb}")
  done
  if (( n_arb < LOCALE_ARB_FLOOR )); then
    t_fail "only ${n_arb} locale ARB(s) under haven/lib/l10n, and this check \
says — in its own header and in the failure message it prints when a telemetry \
package is found — that the no-telemetry promise is made in \
${LOCALE_ARB_FLOOR} languages. A locale file deleted outright takes its copy of \
the promise with it and leaves every key-parity check happy. If a language is \
really being dropped, drop it in LOCALE_ARB_FLOOR and in the wording that \
constant pins, in the same commit."
  fi
  if (( ${#arb_missing[@]} > 0 )); then
    t_fail "privacyWhatHavenIsDetailNoTelemetry is missing or empty in: \
${arb_missing[*]}. Haven tells users in every language it ships that the app \
contains no analytics, crash-reporting or advertising code; a locale where that \
sentence has quietly gone is a locale where the promise is no longer made at \
all, and no English-language review would ever see it."
  fi

  # The anti-vacuity report: a moved manifest must never read as a clean tree,
  # so what was actually examined is printed on every run, pass or fail.
  printf '  9b: dependency surface examined %d file(s) — %d pubspec position(s) (%d dependencies / %d dev_dependencies), %d locked package(s), %d Rust dependency name(s), %d Gradle file(s)/%d code line(s), %d Info.plist key(s), %d manifest component(s), %d Podfile(s), %d locale ARB(s).\n' \
    "${n_files}" "${n_dep}" "${n_dep_main}" "${n_dep_dev}" "${n_lock}" \
    "${n_rust}" "${n_gradle}" "${n_gradle_lines}" "${n_plist}" \
    "${n_manifest}" "${n_pods}" "${n_arb}"

  (( fail == 0 ))
}

# ---------------------------------------------------------------------------
# Self-test for check 9b — hermetic fixtures, no repo state.
#
# Every arrival path gets a fixture that fails for its OWN reason, every
# anti-vacuity floor gets one, and both false-positive directions are pinned:
# prose naming every banned SDK (a pubspec comment, a Gradle comment, an
# Info.plist usage string, a Cargo comment, an XML comment) must stay green,
# because a guard that forbids explaining itself gets the explanation deleted
# instead of the code. Every fixture must also exercise an input of its OWN: a
# case whose mutation is `:` re-runs its predecessor under a new label and
# reports coverage of nothing.
# ---------------------------------------------------------------------------

# An EXACT pin, not a floor. A floor lets fixtures be deleted down to it in
# silence — the failure this repo has already seen once, where MIN_CASES sat ten
# below the real count and ten cases could have gone without a red run. Equality
# turns every deletion into a visible one-line diff here.
EXPECTED_FIXTURES=67

telemetry_self_test() {
  local tmp root fails=0 checked=0
  tmp="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf '${tmp}'" RETURN
  root="${tmp}/tree"

  # The committed shapes, reduced: a real dependency list (whose names include
  # the ones that must NOT trip — image_cropper, shared_preferences, and the
  # nearest real neighbours of the name tokens: leak_tracker, lazy_static,
  # backtrace, android_logger), the real `isMonitoringTool` meta-data, and a
  # usage description that says the words "analytics" and "crash reports" out
  # loud.
  _seed() {
    mkdir -p "${root}/haven/android/app/src/main" "${root}/haven/ios/Runner" \
      "${root}/haven-core" "${root}/haven/rust_builder" "${root}/haven/lib/l10n"
    cat > "${root}/haven/pubspec.yaml" <<'YAML'
name: haven
description: Private, end-to-end encrypted family location sharing.

dependencies:
  flutter:
    sdk: flutter
  geolocator: ^14.0.0
  image_cropper: ^12.2.1
  shared_preferences: ^2.5.0

dev_dependencies:
  flutter_test:
    sdk: flutter
  very_good_analysis: ^8.0.0
  leak_tracker: ^11.0.0

flutter:
  uses-material-design: true
YAML
    local loc
    for loc in en ar de es fa fr hi ja ne pt ru tr ur; do
      printf '{\n  "privacyWhatHavenIsDetailNoTelemetry": "no-telemetry promise, %s"\n}\n' \
        "${loc}" > "${root}/haven/lib/l10n/app_${loc}.arb"
    done
    cat > "${root}/haven/pubspec.lock" <<'YAML'
packages:
  archive:
    dependency: transitive
    description:
      name: archive
      url: "https://pub.dev"
    source: hosted
    version: "4.0.0"
  geolocator:
    dependency: "direct main"
    description:
      name: geolocator
      url: "https://pub.dev"
    source: hosted
    version: "14.0.0"
sdks:
  dart: ">=3.10.7 <4.0.0"
YAML
    cat > "${root}/haven-core/Cargo.toml" <<'TOML'
[package]
name = "haven-core"

[dependencies]
nostr = "0.44"
zeroize = { version = "1.8", features = ["zeroize_derive"] }

[dev-dependencies]
proptest = "1.5"
TOML
    cat > "${root}/haven-core/Cargo.lock" <<'TOML'
[[package]]
name = "nostr"
version = "0.44.0"

[[package]]
name = "zeroize"
version = "1.8.1"

[[package]]
name = "backtrace"
version = "0.3.75"

[[package]]
name = "android_logger"
version = "0.15.1"
TOML
    cat > "${root}/haven/rust_builder/Cargo.toml" <<'TOML'
[package]
name = "rust_lib_haven"

[dependencies]
haven-core = { path = "../../haven-core" }
flutter_rust_bridge = "=2.11.1"
TOML
    cat > "${root}/haven/rust_builder/Cargo.lock" <<'TOML'
[[package]]
name = "flutter_rust_bridge"
version = "2.11.1"
TOML
    cat > "${root}/haven/android/app/build.gradle.kts" <<'KTS'
plugins {
    id("com.android.application")
    id("kotlin-android")
    id("dev.flutter.flutter-gradle-plugin")
}

dependencies {
    compileOnly(project(":integration_test"))
}
KTS
    cat > "${root}/haven/android/settings.gradle.kts" <<'KTS'
pluginManagement {
    repositories {
        google()
        mavenCentral()
    }
}
include(":app")
KTS
    cat > "${root}/haven/android/app/src/main/AndroidManifest.xml" <<'XML'
<?xml version="1.0" encoding="utf-8"?>
<manifest xmlns:android="http://schemas.android.com/apk/res/android">
    <application android:name=".HavenApplication">
        <activity android:name=".MainActivity"/>
        <meta-data android:name="flutterEmbedding" android:value="2"/>
        <meta-data android:name="isMonitoringTool" android:value="true"/>
    </application>
</manifest>
XML
    cat > "${root}/haven/ios/Runner/Info.plist" <<'XML'
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>haven</string>
  <key>NSLocationWhenInUseUsageDescription</key>
  <string>Haven shares your location with your circles. It sends no analytics and no crash reports.</string>
</dict></plist>
XML
    cat > "${root}/haven/ios/Runner/PrivacyInfo.xcprivacy" <<'XML'
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
  <key>NSPrivacyTracking</key><false/>
  <key>NSPrivacyTrackingDomains</key><array/>
  <key>NSPrivacyCollectedDataTypes</key><array><dict>
    <key>NSPrivacyCollectedDataType</key><string>NSPrivacyCollectedDataTypePreciseLocation</string>
    <key>NSPrivacyCollectedDataTypeTracking</key><false/>
    <key>NSPrivacyCollectedDataTypePurposes</key>
    <array><string>NSPrivacyCollectedDataTypePurposeAppFunctionality</string></array>
  </dict></array>
</dict></plist>
XML
  }

  _case() { # _case <label> <want-rc> <mutation, evaluated with $root set>
    local label="$1" want="$2" mutation="$3" got=0
    checked=$(( checked + 1 ))
    rm -rf "${root}"
    _seed
    eval "${mutation}"
    ( telemetry_dependency_scan "${root}" ) >/dev/null 2>&1 || got=$?
    if [[ "${got}" -eq "${want}" ]]; then
      printf '  \033[1;32mPASS\033[0m %s (rc=%d)\n' "${label}" "${got}"
    else
      printf '  \033[1;31mFAIL\033[0m %s (want rc=%d, got rc=%d)\n' \
        "${label}" "${want}" "${got}" >&2
      fails=1
    fi
  }

  printf '\033[1;34m[check_m7_native_wake_guards]\033[0m self-test: check 9b, the no-telemetry dependency surface\n'

  # (1) Positive control first: a guard hard-coded to fail passes every
  #     negative fixture below and looks perfect.
  _case 'the committed dependency surface passes' 0 ':'

  # -- Dart: direct, dev, transitive ----------------------------------------
  _case 'a direct sentry_flutter dependency FAILS' 1 \
    'sed -i "s/  geolocator: ^14.0.0/  geolocator: ^14.0.0\n  sentry_flutter: ^8.0.0/" "${root}/haven/pubspec.yaml"'
  _case 'a direct firebase_analytics dependency FAILS' 1 \
    'sed -i "s/  geolocator: ^14.0.0/  geolocator: ^14.0.0\n  firebase_analytics: ^11.0.0/" "${root}/haven/pubspec.yaml"'
  _case 'a direct google_mobile_ads dependency FAILS' 1 \
    'sed -i "s/  geolocator: ^14.0.0/  geolocator: ^14.0.0\n  google_mobile_ads: ^5.0.0/" "${root}/haven/pubspec.yaml"'
  # The four an adversarial review added under their REAL names while this check
  # stayed green (2026-08-13). One fixture each: they failed for four different
  # reasons — one is a bare English word, three are vendor names nothing on the
  # old roster resembled — and a single combined fixture would go green again
  # the moment any one of the four tokens was dropped.
  _case "Google's own 'usage' analytics package FAILS" 1 \
    'sed -i "s/  geolocator: ^14.0.0/  geolocator: ^14.0.0\n  usage: ^4.1.1/" "${root}/haven/pubspec.yaml"'
  _case 'clarity_flutter (Microsoft Clarity) FAILS' 1 \
    'sed -i "s/  geolocator: ^14.0.0/  geolocator: ^14.0.0\n  clarity_flutter: ^3.0.0/" "${root}/haven/pubspec.yaml"'
  _case 'openreplay_flutter FAILS' 1 \
    'sed -i "s/  geolocator: ^14.0.0/  geolocator: ^14.0.0\n  openreplay_flutter: ^1.0.0/" "${root}/haven/pubspec.yaml"'
  _case 'glean_flutter (Mozilla telemetry) FAILS' 1 \
    'sed -i "s/  geolocator: ^14.0.0/  geolocator: ^14.0.0\n  glean_flutter: ^1.0.0/" "${root}/haven/pubspec.yaml"'
  # dev_dependencies fail on purpose — see the header for why "it does not
  # ship" is not true in this repo.
  _case 'sentry_flutter under dev_dependencies FAILS' 1 \
    'sed -i "s/  very_good_analysis: ^8.0.0/  very_good_analysis: ^8.0.0\n  sentry_flutter: ^8.0.0/" "${root}/haven/pubspec.yaml"'
  _case 'a dependency_overrides entry FAILS' 1 \
    'printf "\ndependency_overrides:\n  amplitude_flutter: ^4.0.0\n" >> "${root}/haven/pubspec.yaml"'
  _case 'a TRANSITIVE crashlytics package in the lockfile FAILS' 1 \
    'sed -i "s/^  geolocator:/  firebase_crashlytics:\n    dependency: transitive\n    description:\n      name: firebase_crashlytics\n      url: \"https:\/\/pub.dev\"\n    source: hosted\n    version: \"4.0.0\"\n  geolocator:/" "${root}/haven/pubspec.lock"'

  # -- Rust: the core is part of the app ------------------------------------
  _case 'a sentry crate in haven-core FAILS' 1 \
    'sed -i "s/^nostr = \"0.44\"/nostr = \"0.44\"\nsentry = \"0.34\"/" "${root}/haven-core/Cargo.toml"'
  _case 'a telemetry crate in a [dependencies.x] table FAILS' 1 \
    'printf "\n[dependencies.opentelemetry]\nversion = \"0.24\"\n" >> "${root}/haven-core/Cargo.toml"'
  _case 'a transitive crate in Cargo.lock FAILS' 1 \
    'printf "\n[[package]]\nname = \"sentry-core\"\nversion = \"0.34.0\"\n" >> "${root}/haven-core/Cargo.lock"'
  _case 'a telemetry crate in rust_builder FAILS' 1 \
    'sed -i "s/^flutter_rust_bridge = \"=2.11.1\"/flutter_rust_bridge = \"=2.11.1\"\ndatadog-tracing = \"0.1\"/" "${root}/haven/rust_builder/Cargo.toml"'

  # -- Android: the layer a Dart-only scan misses entirely -------------------
  _case 'the google-services Gradle plugin FAILS' 1 \
    'sed -i "s/    id(\"kotlin-android\")/    id(\"kotlin-android\")\n    id(\"com.google.gms.google-services\")/" "${root}/haven/android/app/build.gradle.kts"'
  _case 'the Crashlytics Gradle plugin FAILS' 1 \
    'sed -i "s/    id(\"kotlin-android\")/    id(\"kotlin-android\")\n    id(\"com.google.firebase.crashlytics\")/" "${root}/haven/android/app/build.gradle.kts"'
  _case 'a firebase-analytics Maven coordinate FAILS' 1 \
    'sed -i "s|    compileOnly(project(\":integration_test\"))|    compileOnly(project(\":integration_test\"))\n    implementation(\"com.google.firebase:firebase-analytics:22.0.0\")|" "${root}/haven/android/app/build.gradle.kts"'
  _case 'a play-services-ads coordinate in the ROOT build file FAILS' 1 \
    'printf "\ndependencies {\n    implementation(\"com.google.android.gms:play-services-ads:23.0.0\")\n}\n" >> "${root}/haven/android/settings.gradle.kts"'
  _case 'an AdMob APPLICATION_ID meta-data FAILS' 1 \
    'sed -i "s|<activity android:name=\".MainActivity\"/>|<activity android:name=\".MainActivity\"/><meta-data android:name=\"com.google.android.gms.ads.APPLICATION_ID\" android:value=\"ca-app-pub-0\"/>|" "${root}/haven/android/app/src/main/AndroidManifest.xml"'
  _case 'a google-services.json FAILS on presence alone' 1 \
    'printf "{}" > "${root}/haven/android/app/google-services.json"'
  _case 'a sentry.properties FAILS on presence alone' 1 \
    'printf "defaults.project=haven\n" > "${root}/haven/android/sentry.properties"'

  # -- iOS -------------------------------------------------------------------
  _case 'NSUserTrackingUsageDescription FAILS' 1 \
    'sed -i "s|<key>CFBundleName</key><string>haven</string>|<key>CFBundleName</key><string>haven</string><key>NSUserTrackingUsageDescription</key><string>Improve ads</string>|" "${root}/haven/ios/Runner/Info.plist"'
  _case 'SKAdNetworkItems FAILS' 1 \
    'sed -i "s|<key>CFBundleName</key><string>haven</string>|<key>CFBundleName</key><string>haven</string><key>SKAdNetworkItems</key><array/>|" "${root}/haven/ios/Runner/Info.plist"'
  _case 'GADApplicationIdentifier FAILS' 1 \
    'sed -i "s|<key>CFBundleName</key><string>haven</string>|<key>CFBundleName</key><string>haven</string><key>GADApplicationIdentifier</key><string>ca-app-pub-0</string>|" "${root}/haven/ios/Runner/Info.plist"'
  _case 'NSPrivacyTracking flipped to true FAILS' 1 \
    'sed -i "s|<key>NSPrivacyTracking</key><false/>|<key>NSPrivacyTracking</key><true/>|" "${root}/haven/ios/Runner/PrivacyInfo.xcprivacy"'
  _case 'a declared tracking domain FAILS' 1 \
    'sed -i "s|<key>NSPrivacyTrackingDomains</key><array/>|<key>NSPrivacyTrackingDomains</key><array><string>app-measurement.com</string></array>|" "${root}/haven/ios/Runner/PrivacyInfo.xcprivacy"'
  _case 'an Analytics collection purpose FAILS' 1 \
    'sed -i "s|NSPrivacyCollectedDataTypePurposeAppFunctionality|NSPrivacyCollectedDataTypePurposeAnalytics|" "${root}/haven/ios/Runner/PrivacyInfo.xcprivacy"'
  _case 'a data type marked as used for tracking FAILS' 1 \
    'sed -i "s|<key>NSPrivacyCollectedDataTypeTracking</key><false/>|<key>NSPrivacyCollectedDataTypeTracking</key><true/>|" "${root}/haven/ios/Runner/PrivacyInfo.xcprivacy"'
  _case 'a Podfile installing Sentry FAILS' 1 \
    'printf "target %sRunner%s do\n  pod %sSentry%s, %s8.0%s\nend\n" "'"'"'" "'"'"'" "'"'"'" "'"'"'" "'"'"'" "'"'"'" > "${root}/haven/ios/Podfile"'

  # -- false-positive direction: prose is not a dependency -------------------
  _case 'a pubspec comment naming every banned SDK still passes' 0 \
    'sed -i "s|  geolocator: ^14.0.0|  # Deliberately absent: sentry_flutter, firebase_analytics,\n  # firebase_crashlytics, google_mobile_ads, appsflyer_sdk. See the\n  # no-telemetry claim in app_en.arb.\n  geolocator: ^14.0.0|" "${root}/haven/pubspec.yaml"'
  _case 'a Gradle comment naming the banned plugins still passes' 0 \
    'sed -i "s|    id(\"kotlin-android\")|    // NOT applied, ever: com.google.gms.google-services,\n    // com.google.firebase.crashlytics, com.google.firebase:firebase-analytics.\n    id(\"kotlin-android\")|" "${root}/haven/android/app/build.gradle.kts"'
  _case 'a Cargo comment naming sentry still passes' 0 \
    'sed -i "s|^nostr = \"0.44\"|# No sentry, no opentelemetry: Haven reports no crashes.\nnostr = \"0.44\"|" "${root}/haven-core/Cargo.toml"'
  # The plist half matches KEYS, never free text — so a usage description that
  # names every banned SDK by name is not a hit. (This fixture used to re-run
  # the seed unchanged under its own label, which exercised no input of its own
  # and made the fixture count one higher than the number of distinct inputs.)
  _case 'an Info.plist STRING naming every banned SDK still passes' 0 \
    'sed -i "s|<key>CFBundleName</key><string>haven</string>|<key>CFBundleName</key><string>haven</string><key>NSLocationAlwaysAndWhenInUseUsageDescription</key><string>No Firebase Analytics, no Crashlytics, no AdMob, no Sentry, no AppsFlyer, no session replay.</string>|" "${root}/haven/ios/Runner/Info.plist"'
  _case 'a commented-out banned plist key does not count' 0 \
    'sed -i "s|<key>CFBundleName</key><string>haven</string>|<!-- <key>SKAdNetworkItems</key><array/> --><key>CFBundleName</key><string>haven</string>|" "${root}/haven/ios/Runner/Info.plist"'
  _case 'a commented-out manifest meta-data does not count' 0 \
    'sed -i "s|<activity android:name=\".MainActivity\"/>|<activity android:name=\".MainActivity\"/><!-- <meta-data android:name=\"com.google.android.gms.ads.APPLICATION_ID\" android:value=\"x\"/> -->|" "${root}/haven/android/app/src/main/AndroidManifest.xml"'
  _case 'a Podfile comment naming Sentry still passes' 0 \
    'printf "# No Sentry, no Firebase/Crashlytics pod here.\ntarget %sRunner%s do\nend\n" "'"'"'" "'"'"'" > "${root}/haven/ios/Podfile"'
  # A repository URL is not a comment: the shared code_view would eat the tail
  # of every `https://` line, so a coordinate could hide behind one.
  _case 'a https:// maven URL does not hide a coordinate behind it' 1 \
    'printf "\nrepositories {\n    maven { url = uri(\"https://maven.google.com\") }\n    maven { url = uri(\"https://io.sentry/maven\") }\n}\n" >> "${root}/haven/android/app/build.gradle.kts"'

  # -- anti-vacuity: a scan with nothing to read is a FAILURE ----------------
  _case 'a missing pubspec.yaml FAILS' 1 'rm -f "${root}/haven/pubspec.yaml"'
  _case 'a missing pubspec.lock FAILS' 1 'rm -f "${root}/haven/pubspec.lock"'
  _case 'a pubspec with no dependencies section FAILS' 1 \
    'printf "name: haven\nflutter:\n  uses-material-design: true\n" > "${root}/haven/pubspec.yaml"'
  # Each section floored on its OWN positions: on a combined count, renaming one
  # heading is covered by the other section's entries and passes.
  _case 'renaming dependencies: alone FAILS (dev_dependencies must not cover it)' 1 \
    'sed -i "s/^dependencies:/deps:/" "${root}/haven/pubspec.yaml"'
  _case 'renaming dev_dependencies: alone FAILS (dependencies must not cover it)' 1 \
    'sed -i "s/^dev_dependencies:/dev_deps:/" "${root}/haven/pubspec.yaml"'
  _case 'a lockfile with no packages section FAILS' 1 \
    'printf "sdks:\n  dart: \">=3.10.7 <4.0.0\"\n" > "${root}/haven/pubspec.lock"'
  _case 'a missing Cargo.toml FAILS' 1 'rm -f "${root}/haven-core/Cargo.toml"'
  _case 'a Cargo.toml with no dependency table FAILS' 1 \
    'printf "[package]\nname = \"haven-core\"\n" > "${root}/haven-core/Cargo.toml"'
  _case 'a missing Cargo.lock FAILS' 1 'rm -f "${root}/haven-core/Cargo.lock"'
  _case 'a Cargo.lock naming no crates FAILS' 1 \
    'printf "version = 4\n" > "${root}/haven-core/Cargo.lock"'
  _case 'a renamed android directory (no build files) FAILS' 1 \
    'rm -rf "${root}/haven/android"'
  # Files still present, still counted, nothing left in them to read: the case
  # the file-count floor could not see.
  _case 'EVERY gradle file truncated to zero bytes FAILS' 1 \
    ': > "${root}/haven/android/app/build.gradle.kts"
     : > "${root}/haven/android/settings.gradle.kts"'
  _case 'ONE gradle file truncated to zero bytes FAILS' 1 \
    ': > "${root}/haven/android/app/build.gradle.kts"'
  _case 'a gradle file emptied by commenting out every line FAILS' 1 \
    'sed -i "s|^|// |" "${root}/haven/android/app/build.gradle.kts"'
  _case 'a missing AndroidManifest FAILS' 1 \
    'rm -f "${root}/haven/android/app/src/main/AndroidManifest.xml"'
  _case 'an AndroidManifest declaring no components FAILS' 1 \
    'printf "<manifest/>\n" > "${root}/haven/android/app/src/main/AndroidManifest.xml"'
  _case 'a missing Info.plist FAILS' 1 'rm -f "${root}/haven/ios/Runner/Info.plist"'
  _case 'an Info.plist with no keys FAILS' 1 \
    'printf "<plist version=\"1.0\"><dict/></plist>\n" > "${root}/haven/ios/Runner/Info.plist"'
  _case 'a deleted PrivacyInfo.xcprivacy FAILS' 1 \
    'rm -f "${root}/haven/ios/Runner/PrivacyInfo.xcprivacy"'
  _case 'a dropped NSPrivacyTracking declaration FAILS' 1 \
    'sed -i "s|<key>NSPrivacyTracking</key><false/>||" "${root}/haven/ios/Runner/PrivacyInfo.xcprivacy"'
  _case 'an unparsable Info.plist FAILS' 1 \
    'printf "<plist><dict><key>CFBundleName</key>" > "${root}/haven/ios/Runner/Info.plist"'
  _case 'an unparsable PrivacyInfo.xcprivacy FAILS' 1 \
    'printf "<plist><dict><key>NSPrivacyTracking</key>" > "${root}/haven/ios/Runner/PrivacyInfo.xcprivacy"'
  _case 'an unparsable AndroidManifest FAILS' 1 \
    'printf "<manifest><application" > "${root}/haven/android/app/src/main/AndroidManifest.xml"'

  # -- the copy half: the promise is made in all thirteen languages ----------
  _case 'the promise deleted from ONE non-English locale FAILS' 1 \
    'printf "{}\n" > "${root}/haven/lib/l10n/app_ja.arb"'
  _case 'the promise whitespaced out in one locale FAILS' 1 \
    'printf "{\n  \"privacyWhatHavenIsDetailNoTelemetry\": \"   \"\n}\n" > "${root}/haven/lib/l10n/app_tr.arb"'
  _case 'a deleted locale ARB (twelve left) FAILS' 1 \
    'rm -f "${root}/haven/lib/l10n/app_ur.arb"'
  _case 'no locale ARBs at all FAILS' 1 'rm -rf "${root}/haven/lib/l10n"'
  _case 'an unparsable locale ARB FAILS' 1 \
    'printf "{\"privacyWhatHavenIsDetailNoTelemetry\": " > "${root}/haven/lib/l10n/app_de.arb"'
  # The honest limit, pinned so nobody later reads the check as more than it is:
  # a translation REWRITTEN to promise less is still a non-empty string, and
  # this scan passes it. English wording is rule 10's job; the other twelve
  # languages are nobody's.
  _case 'a SOFTENED translation still passes (not detectable, not claimed)' 0 \
    'printf "{\n  \"privacyWhatHavenIsDetailNoTelemetry\": \"We collect only a little.\"\n}\n" > "${root}/haven/lib/l10n/app_es.arb"'

  if (( checked != EXPECTED_FIXTURES )); then
    printf '\033[1;31m[check_m7_native_wake_guards] FAIL:\033[0m the 9b self-test ran %d fixture(s) and EXPECTED_FIXTURES pins %d. A count that is only PRINTED lets fixtures be deleted silently, which is how a sibling guard lost ten cases with a green banner. Adding or removing a fixture is a deliberate act: change it here in the same commit.\n' \
      "${checked}" "${EXPECTED_FIXTURES}" >&2
    fails=1
  fi
  if (( fails )); then
    printf '\033[1;31m[check_m7_native_wake_guards] FAIL:\033[0m self-test failed — this guard cannot be trusted until it is fixed\n' >&2
    exit 2
  fi
  printf '\033[1;34m[check_m7_native_wake_guards]\033[0m OK: check 9b self-test passed (%d fixtures).\n' "${checked}"
}

# --- dispatch (before any repo read, so --self-test stays hermetic) --------
if [[ "${1:-}" == "--self-test" ]]; then
  telemetry_self_test
  exit 0
fi
if (( $# != 0 )); then
  echo "ERROR: usage: $(basename "${BASH_SOURCE[0]}") [--self-test]" >&2
  exit 2
fi

for f in "$WORKER" "$IOS_DART" "$MGR" "$MANIFEST" "$SLC" "$BGT" "$APPDELEGATE" "$PLIST" "$PUBSPEC" "$LIVE_SYNC" "$MAIN"; do
  [[ -f "$f" ]] || { echo "FAIL: expected M7 file not found: $f" >&2; exit 1; }
done

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
# 9b. NO analytics / crash-reporting / advertising dependency surface — the
#     sibling of check 9, backing privacyWhatHavenIsDetailNoTelemetry. Scans
#     the Dart, Rust, Gradle, AndroidManifest and iOS plist layers, and reads
#     the promise out of all thirteen locale ARBs; see the header for the
#     arrival paths covered, the four it cannot reach, the copy split it shares
#     with check_privacy_invariants.sh rule 10, and why a dev_dependency fails.
# ---------------------------------------------------------------------------
telemetry_dependency_scan "$REPO_ROOT" || FAILED=1

# ---------------------------------------------------------------------------
# 10. No secret/location/error-internal logging in the native wake files (a log
#     that interpolates a sensitive value, logs it via an os_log %{public}
#     specifier, or logs an error's whole value / .localizedDescription).
#     Conservative: current logs use \(type(of: error)) / %@ .code — not flagged.
# ---------------------------------------------------------------------------
LOG_FN='(NSLog|os_log|print|debugPrint|debugLog)'
# `\blocation\b` (word-boundaried) so the safe `locations=${result.locations
# Applied}` counter marker does NOT false-positive, while a real `${location}`
# still trips.
SENS='coordinate|latitude|longitude|coord|\blocation\b|geohash|pubkey|npub|nsec|privkey|seckey|secret|exporter|nostr_group|group_id|\blat\b|\blng\b|\blon\b'
for f in "$SLC" "$BGT" "$WORKER" "$IOS_DART" "$APPDELEGATE" "$MGR"; do
  code="$(code_view "$f")"
  logs="$(printf '%s\n' "$code" | grep -nE "$LOG_FN")"
  # L2: the sensitive-INTERPOLATION scan runs over the WHOLE file (not just the
  # log-fn line) so a value interpolated on a CONTINUATION line of a multi-line
  # log call is caught. In these privacy-critical wake files any string
  # interpolation of a sensitive value is suspect, so a file-wide scan is the
  # right (stricter) stance — it does not depend on the interpolation sharing a
  # physical line with the log call.
  intp="$(printf '%s\n' "$code" | grep -niE '\\\([^)]*('"$SENS"')|\$\{[^}]*('"$SENS"')|\$('"$SENS"')' | head -1)"
  # %{public}-specifier + error-internals checks stay log-line-scoped (they are
  # about HOW a log call renders, not where a value appears).
  pub="$(printf '%s\n' "$logs" | grep -F '%{public}' | grep -iE "$SENS" | head -1)"
  errl="$(printf '%s\n' "$logs" | grep -E 'localizedDescription|\\\(error\)|\\\(err\)' | head -1)"
  [[ -z "$intp" ]] || fail "$(basename "$f") interpolates a sensitive value into a string (likely a log leak): $intp"
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

# ===========================================================================
# RELEASED-STATE PINS (M7-E + M11 LIVE) — checks 14a-14i. A regression that
# re-inerts a shipped feature (M7-E background wakes, or M11's live-sync engine)
# turns these red. See the header for the rollback story.
# ===========================================================================

# 14a. backgroundCatchupEnabled MUST be `true` (LIVE). Bound to the const
#      declaration so a mere reference elsewhere cannot satisfy it, and the
#      `= false` form must be absent (catches a half-edit / stray shadow).
code_has_e 'const bool backgroundCatchupEnabled *= *true' "$LIVE_SYNC" ||
  fail "14a: backgroundCatchupEnabled is not declared '= true' in $(basename "$LIVE_SYNC") — the feature is inert (M7-E requires it LIVE)"
code_has_e 'const bool backgroundCatchupEnabled *= *false' "$LIVE_SYNC" &&
  fail "14a: backgroundCatchupEnabled is declared '= false' — the M7-E feature is inert"

# 14b. liveSyncEnabled MUST default to `true` (LIVE — M11 Phase B flipped it, so
#      a production release build, which passes no --dart-define, resolves the
#      persistent live-sync engine ON). It is a compile-time
#      `bool.fromEnvironment('HAVEN_LIVE_SYNC', defaultValue: true)` const, so
#      the invariant is the declaration's `defaultValue: true`, not a bare
#      `= true`. This pins the RELEASED state (mirroring 14a for
#      backgroundCatchupEnabled): a silent re-inert — flipping `defaultValue`
#      back to `false`, or a bare `= false` — turns this red. The `-A3` window
#      ties the default to THIS const's declaration (not some other future
#      `bool.fromEnvironment`). On an INTENTIONAL live-sync rollback (M11 plan
#      §8) this check is reverted together with the `defaultValue: false` it
#      pins — it correctly fails first.
live_sync_decl="$(code_view "$LIVE_SYNC" | grep -A3 -E 'const liveSyncEnabled *= *bool\.fromEnvironment' || true)"
grep -qE 'defaultValue: *true' <<<"$live_sync_decl" ||
  fail "14b: liveSyncEnabled does not default to true — M11 Phase B ships the persistent live-sync engine ON; a re-inert to defaultValue:false (or a bare '= false') is a released-state regression (an intentional plan-§8 rollback reverts this check with it)"
grep -qE 'defaultValue: *false' <<<"$live_sync_decl" &&
  fail "14b: liveSyncEnabled defaultValue is 'false' — the M11-shipped live-sync engine was re-inerted outside a plan-§8 rollback (which must revert this guard too)"
code_has_e 'const liveSyncEnabled *= *false' "$LIVE_SYNC" &&
  fail "14b: liveSyncEnabled is a bare '= false' — the M11-shipped live-sync engine was re-inerted"

# 14c. RebootReceiver MUST be enabled="true" (FGS restarts after reboot when
#      sharing was on). xmllint = XML-comment safe.
reboot_enabled="$(xmllint --nonet --xpath "string(//receiver[contains(@*[local-name()='name'],'RebootReceiver')]/@*[local-name()='enabled'])" "$MANIFEST" 2>/dev/null)"
[[ "$reboot_enabled" == "true" ]] ||
  fail "14c: RebootReceiver android:enabled is '${reboot_enabled:-absent}', must be 'true' (M7-E reboot re-arm)"

# 14d. RestartReceiver MUST STAY enabled="false" (Haven manages the FGS
#      lifecycle explicitly; the plugin's ANR/kill auto-restart is suppressed).
#      This receiver legitimately keeps tools:node="replace" (unlike Reboot).
restart_enabled="$(xmllint --nonet --xpath "string(//receiver[contains(@*[local-name()='name'],'RestartReceiver')]/@*[local-name()='enabled'])" "$MANIFEST" 2>/dev/null)"
[[ "$restart_enabled" == "false" ]] ||
  fail "14d: RestartReceiver android:enabled is '${restart_enabled:-absent}', must stay 'false' (Haven owns the FGS lifecycle)"
restart_node="$(xmllint --nonet --xpath "//receiver[contains(@*[local-name()='name'],'RestartReceiver')]/descendant-or-self::*/@*[local-name()='node']" "$MANIFEST" 2>/dev/null)"
grep -q 'replace' <<<"$restart_node" ||
  fail "14d: RestartReceiver lost tools:node=\"replace\" — the plugin's auto-restart-on-ANR/kill behaviour would return"

# 14e. autoRunOnBoot: true present (paired with 14c so the FGS actually restarts).
code_has_e 'autoRunOnBoot: *true' "$MGR" ||
  fail "14e: autoRunOnBoot: true is not set in $(basename "$MGR") ForegroundTaskOptions — the FGS will not restart after reboot"

# 14f. The worker runs the REAL bootstrap, not the comment stub. Pin the three
#      load-bearing bootstrap calls (in executable code) + the receive-only
#      chokepoint. The old stub (`_runCatchupViaProviders`) was pure comments,
#      so requiring these in code proves it was replaced.
code_has 'RustLib.init()' "$WORKER" ||
  fail "14f: worker does not call RustLib.init() in code — the bootstrap is still the inert stub"
code_has 'CircleManagerFfi.newInstance' "$WORKER" ||
  fail "14f: worker does not open a CircleManagerFfi in code — the bootstrap is still the inert stub"
code_has_e 'runCatchup\(isBackgroundWake: true' "$WORKER" ||
  fail "14f: worker does not call runCatchup(isBackgroundWake: true) in code — the receive-only chokepoint is missing"

# 14g. The pending-MLS-wipe read (M10.1 gate) MUST precede the sweep call in the
#      worker — a wake must decline BEFORE it can open/create MLS state a logout
#      is destroying. Structure-bound ordering (comment-stripped line numbers).
wipe_read="$(first_code_line 'kPendingMlsWipeKey' "$WORKER")"
sweep_call="$(first_code_line_e 'runCatchup\(isBackgroundWake: true' "$WORKER")"
if [[ -z "$wipe_read" ]]; then
  fail "14g: worker never reads kPendingMlsWipeKey — the M10.1 pending-wipe gate is missing"
elif [[ -z "$sweep_call" ]]; then
  fail "14g: worker never calls runCatchup(isBackgroundWake: true) — cannot verify gate ordering"
elif [[ "$wipe_read" -ge "$sweep_call" ]]; then
  fail "14g: the kPendingMlsWipeKey gate (L$wipe_read) does not precede the sweep (L$sweep_call) — a wake could touch MLS state mid-wipe"
fi

# 14h. main() MUST still write the iOS flag mirror AND register the iOS catch-up
#      handler in EXECUTABLE code (A8). The D7 sim test calls these functions
#      itself, so only a source pin here catches a deleted call-site (on which
#      the iOS arming + rollback re-inert both depend).
code_has 'writeCatchupEnabledMirror()' "$MAIN" ||
  fail "14h: main.dart no longer calls writeCatchupEnabledMirror() — iOS never learns the flag value (arming + rollback re-inert both break)"
code_has 'registerIosBackgroundCatchupHandler(' "$MAIN" ||
  fail "14h: main.dart no longer calls registerIosBackgroundCatchupHandler() — the iOS runCatchup channel is unhandled"

# 14i. AppDelegate MUST re-arm SLC + BGTask in applicationDidEnterBackground
#      (A3) — closes the launch-arm-before-mirror-write lag for upgraders and
#      same-session toggle-enablers. Bound to the enclosing function body.
appbg_body="$(fn_slice 'func applicationDidEnterBackground' "$APPDELEGATE")"
if [[ -z "$appbg_body" ]]; then
  fail "14i: AppDelegate has no applicationDidEnterBackground override — the iOS one-launch arming lag (A3) is not closed"
else
  grep -qF -- 'slcHandler.startMonitoring()' <<<"$appbg_body" ||
    fail "14i: applicationDidEnterBackground does not re-arm SLC (slcHandler.startMonitoring())"
  grep -qF -- 'bgTaskHandler.scheduleNextCatchup()' <<<"$appbg_body" ||
    fail "14i: applicationDidEnterBackground does not re-arm the BGTask (bgTaskHandler.scheduleNextCatchup())"
fi

# ---------------------------------------------------------------------------
if [[ "$FAILED" -ne 0 ]]; then
  echo "M7 native-wake guard FAILED — see failures above." >&2
  exit 1
fi
echo "OK: M7 native-wake structural invariants hold (13 checks + the 9b dependency-surface scan + 9 M7-E released-state pins)."
