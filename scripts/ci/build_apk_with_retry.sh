#!/usr/bin/env bash
#
# `flutter build apk` with a CLASSIFIED, BUDGETED retry. The ONE build site
# every Gradle-backed lane goes through. On CI it first installs and verifies
# the Android NDK the build needs, under the same budget (see "The Android NDK"
# below).
#
# ## The failure this exists for
#
# Gradle resolves the buildscript classpath over the network before it compiles
# anything, and hosted runners share egress IPs, so Maven Central rate-limits a
# runner that nobody on this repo did anything to deserve. MEASURED, CI run
# 35622556197 job 106414462454 (E2E Location Provider Toggle, 2026-09-21): six
# consecutive Gradle invocations over 2m47s each died in ':classpath'
# resolution with
#
#     Could not GET 'https://repo.maven.apache.org/maven2/org/jetbrains/
#     kotlin/kotlin-stdlib/2.0.21/kotlin-stdlib-2.0.21.pom'.
#     Received status code 429 from server: Too Many Requests
#
# while TWELVE sibling Android lanes in the SAME run built the same commit with
# ZERO 429s (jobs 106414462467 / 106414462539 / 106414462323, 630-743 s each,
# first attempt). One runner's egress, not a broken build. No test ran.
#
# ## Why OFFLINE lanes are the fix and this is only the backstop
#
# Read this before raising the attempt count. A cold `~/.gradle/caches` makes a
# lane fetch hundreds of POMs; a warm one makes Gradle resolve fixed versions
# from disk and issue no request at all. Removing the requests beats retrying
# them. The shared cache that was meant to remove them was evicted before
# nearly every main run, so the lanes resolved cold anyway and a Plugin Portal
# blip still failed them (CI runs 45142774793, 45012283370). Now one job per
# run, android-gradle-deps.yml (scripts/ci/gradle_deps.sh), resolves and
# verifies the whole set, and every lane builds from it with
# HAVEN_GRADLE_OFFLINE=1 (`scripts/ci/check_gradle_build_hardened.sh` keeps it
# that way). Offline, nothing is retried: see "Offline" below. What remains
# for this retry is the deps job's own resolution (`--resolve-only`, with a
# wider budget of its own) and the online builds nothing hands a set to.
#
# Being honest about what this script can do: the MEASURED 429 above persisted
# ~123 s across six invocations, and the retry window here is ~140 s of waiting.
# It would have been marginal against that exact incident. Stronger still — a
# sweep of ~62 failed and 22 successful runs back to 2026-07-12 found NO log in
# which an in-job retry has ever cleared this class; what clears it is a
# different runner (in run 30732662493 a sibling job built the same commit
# clean six minutes later, and in 35622556197 five siblings did so
# concurrently). So this script's real product is not the recovery, it is the
# VERDICT: it converts an anonymous "exit code 1" from a job that ran no test
# into a message that says INFRASTRUCTURE. The offline set is what removes the
# class.
#
# What a warm `~/.gradle/caches/modules-2` does NOT buy is time — the old cache
# did not, and the offline set does not. A job's first `assembleDebug` took
# 429-638 s with the old cache HIT (run 35813757227) and 33-61 s for its later
# builds; that gap is Gradle configuration, cargokit's Rust cross-compiles
# (x86_64 and i686 Android targets) and the Kotlin compile, which live outside
# the module cache. Its whole product is that the classpath resolves from disk
# and issues no request that can draw the limit — four cached jobs, zero 429s.
#
# ## Offline (HAVEN_GRADLE_OFFLINE=1)
#
# The lanes set it on their build step. This script then installs
# scripts/ci/gradle-offline.init.gradle.kts into $GRADLE_USER_HOME/init.d and
# removes it when it exits, success or not, so no later Gradle call in the job
# runs offline unasked. Any other value than `1` or empty is refused: a lane
# that meant offline and typed `true` must not build online in silence.
#
# Offline, a GRADLE dependency-resolution failure is never transient: Gradle
# has no network to recover. It is a GAP in the run's set, classified before
# the retriable class and never retried — Gradle's "No cached version of
# <coordinate> available for offline mode", and also Gradle's other resolution
# wordings (OFFLINE_GAP_RE), because a missing plugin marker offline prints only
# "could not resolve plugin artifact '<marker>'" (measured, Gradle 9.5.0).
# Network wordings stay retriable offline: offline Gradle cannot print them, so
# they come from what the build still fetches — cargokit's rustup target
# installs, cargo's crate downloads, Flutter's engine artifacts. The verdict
# names the coordinate as the deps job's gap, taken token by token out of
# Gradle's two offline wordings and nothing else (no URL, no host), so nothing
# Rule 15 forbids reaches the annotation: a Maven coordinate names a library.
#
# ## Gradle's OWN retry, and why it is not enough (VERIFIED, 8.14 and 9.5.0)
#
# Gradle does retry 429 — in `NetworkingIssueVerifier.isLikelyTransient
# NetworkingIssue` (429 and 408 are the only retriable client errors; 401/403
# are explicitly NOT retried), driven by the loop in `ErrorHandlingModule
# ComponentRepository`. But its defaults are 3 TOTAL attempts with a backoff of
# 1000 ms doubling once: ~3 s of waiting before the failure is final. That is
# why the MEASURED attempts above died in 16-44 s. `haven/android/gradle.
# properties` widens that window via the two properties that genuinely exist in
# 8.14 and 9.5.0 — `org.gradle.internal.repository.max.tentatives` (TOTAL attempts,
# default 3) and `org.gradle.internal.repository.initial.backoff` (ms, default
# 1000, doubling).
#
# Do NOT cite `org.gradle.internal.repository.max.retries`: it does not exist in
# Gradle, at 8.14, 9.5.0 or anywhere (no hit in the shipped distribution's jars or in
# gradle/gradle). Gradle also ignores `Retry-After` — no `ServiceUnavailable
# RetryStrategy` is ever registered — so the wait is its own fixed schedule.
#
# Note when reading a log: `flutter build apk` ALSO retries Gradle once itself
# ("Retrying Gradle Build: #1, wait time: 100ms", MEASURED in the run above), so
# ONE attempt here is TWO Gradle invocations.
#
# ## Why it CLASSIFIES instead of retrying anything non-zero
#
# Disk exhaustion and OOM are intermittent AND real, so a blind retry turns a
# capacity problem into a green build that hides it. A compile error is not
# intermittent at all, and retrying it burns the step's budget before printing
# the same error three times. So: retry ONLY on a dependency-resolution
# signature, refuse capacity signatures outright, and treat everything
# unclassified as a genuine failure with its ORIGINAL exit code.
#
# What the classifier CANNOT do is tell a transient repository failure from a
# dependency this commit got wrong: `Could not resolve all files for
# configuration ...` is the wrapper Gradle prints for both. The decision taken
# here is to retry the class and be honest in the verdict — three attempts cost
# the step ~140 s of ladder, whereas refusing to retry would hand every real 429
# back to a human. `infra_error` below therefore says only what the captured
# output entitles it to say, and names the missing-coordinate shape when it
# sees it. Being wrong about the CAUSE in an annotation is the failure mode
# that teaches people to re-run instead of read.
#
# ## The budget
#
# Bounded by wall-clock, not just by a count, because the count alone multiplies:
# `build-integration-apks.sh` builds up to seven APKs in ONE step, and a
# per-invocation budget would let a throttled runner spend it seven times over.
# The budget is therefore carried in a state file under `RUNNER_TEMP`, which is
# per-JOB — and every E2E lane has exactly ONE Gradle build step, so job-scoped
# and step-scoped coincide there. That is what makes the worst case below a
# property of the STEP that `check_e2e_step_timeout_ordering.sh` grades. The
# one job with two (build-check.yml's arm64 leg: its build, then its unit tests
# through --gradle-task) shares one budget across both, so neither step's worst
# case can exceed it.
#
# EVERY attempt that fails retriably is charged to it, the FIRST one included,
# and so is every pause. A failed attempt is time the step lost to a transient
# whether it was the first or the fourth; charging only the later ones left the
# first one unbounded, which is what made the old worst case below false.
#
# ## The projection: a retriable failure is not necessarily a FAST failure
#
# An attempt is started only if the budget can afford it:
#
#     spent + backoff + (the PREVIOUS attempt's elapsed) <= RETRY_BUDGET_SECS
#
# The previous attempt's duration is the only estimate available for the next
# one's. Without that term the loop committed to attempts it could not pay for.
#
# The old worst case assumed a retriable failure always lands in 16-44 s,
# "before compilation, by definition". That holds for the MEASURED incidents,
# which all died resolving the `:classpath` configuration — Gradle's
# CONFIGURATION phase, before any task runs (run 35622556197 job 106414462454,
# 16-44 s; run 35418051379 job 105830389349, 33 s). It does NOT hold for the
# class as a whole: `Could not resolve all files for configuration ':app:debug
# RuntimeClasspath'` is resolved at EXECUTION time, by the task that consumes
# it, which in a Flutter build is after the Rust/NDK and Dart work — minutes in.
# `Could not download` and `Read timed out` sit in the same place. UNMEASURED in
# this repo's logs: it follows from which Gradle phase resolves which
# configuration, not from a run we have. The projection is what makes the
# arithmetic below hold either way — a first attempt that burns ten minutes and
# then fails retriably starts no second attempt at all.
#
# ## Worst case (the arithmetic the step caps must cover)
#
# Every attempt except an invocation's LAST is charged, as is every pause, and
# no attempt starts unless what it is projected to add still fits. So whenever
# the loop continues, the budget already holds everything spent so far:
#
#   a step that goes GREEN = (its own successful build time, B — every APK)
#                          + RETRY_BUDGET_SECS   (every pause AND every failed
#                                                 attempt, across the whole
#                                                 step, not per invocation)
#
#   = B + 180 s  =  B + 3.0 min
#
# The NDK's and CMake's attempts are charged to the same budget by the same
# rules, so this is the bound with them included; the installs that succeed are
# part of B, as they were when Flutter and AGP made them inside Gradle (CMake's
# took 1.2-2.8 s in the three jobs of run 45142774793 read for it). On
# CI since the ubuntu-26.04 image the NDK install has MEASURED at most ~1 min,
# which leaves every line of the table below inside its cap (e2e-android and
# e2e-profile are the tightest: 15.8 + 1 + 3 = 19.8 < 25). What ENFORCES it is only
# NDK_ATTEMPT_SECS (5 min): a download five times slower than any measured
# would still land, and would put that lane over its cap — the exposure Flutter's
# own uncapped call already had, not one this script adds.
#
# On the path that ends RED the final attempt is a failure rather than a build,
# so the same bound holds with that failure standing in for the last build. A
# single Gradle invocation is bounded by the step's own `timeout-minutes` and by
# nothing here — exactly as it would be with no retry machinery at all.
#
# Against the MEASURED build times of CI run 35622556197 and the step caps in
# force:
#
#   e2e-integration       B = 15.9 min (7 APKs: 1 cold +   -> 18.9 < cap 35
#                             6 warm)
#   e2e-android, e2e-profile                               -> 18.8 < cap 25
#   every other lane      B <= 15.8 min (the worst single  -> 18.8 < cap 30-40
#                             cold `assembleDebug` in 182
#                             samples, 945.7 s)
#   build-check           B <= 17.9 min (whole job, 12     -> 20.9 < job cap 45
#                             runs 2026-09-19..21)
#
# So no `timeout-minutes` anywhere needs to move, and none may shrink below
# these. Shrink the budget before you grow it: the job caps clear their step
# caps by only 3-6 minutes (check_e2e_step_timeout_ordering.sh C6), so a bigger
# budget would have to be paid for in every lane's job cap.
#
# ## --resolve-only
#
# The deps job's resolution, through the same engine: in haven/android (after
# `flutter build apk --config-only`), `havenResolveAll` from
# scripts/ci/gradle-resolve-all.init.gradle.kts, plus
# `:app:compileDebugNavigationResources`, because AGP fetches aapt2 through a
# detached configuration no enumeration can see and resolves it only when a
# resource task runs; an offline build without it failed exactly there. That
# task needs neither the Flutter compile nor cargokit, and every variant uses
# the same aapt2. Always `--rerun-tasks`: a task Gradle reports UP-TO-DATE
# resolves nothing, and in the spike the online pass did exactly that, so the
# offline pass after it was the first to need aapt2 and missed it. No NDK is
# provisioned. Extra arguments go to Gradle.
#
# ## --gradle-task
#
# One Gradle task line run from haven/android through the same engine, offline
# switch, provisioning and budget as the build, with `-Ptarget-platform` set as
# `flutter build apk` sets it, so after a build of that platform Flutter's own
# tasks stay up to date. build-check.yml runs the JVM unit tests this way; it
# needs a gradlew, which a Flutter build of the tree generates.
#
# Usage:
#   scripts/ci/build_apk_with_retry.sh <flutter-target-platform> [extra flutter args...]
#   scripts/ci/build_apk_with_retry.sh --resolve-only [extra gradle args...]
#   scripts/ci/build_apk_with_retry.sh --gradle-task <flutter-target-platform> <task> [extra gradle args...]
#   scripts/ci/build_apk_with_retry.sh --provision-only   (CI: NDK and CMake)
#   scripts/ci/build_apk_with_retry.sh --self-test
#
# Env:
#   HAVEN_BUILD_MAX_ATTEMPTS       default 4; past 4 every pause is the last step
#   HAVEN_BUILD_RETRY_BUDGET_SECS  default 180
#   HAVEN_BUILD_RETRY_STATE        budget state file; default under RUNNER_TEMP,
#                                  named per GITHUB_RUN_ID (per PID off CI)
#   HAVEN_GRADLE_OFFLINE           `1`: build offline (see "Offline"); empty or
#                                  unset: online; anything else is refused
#
# Exit codes:
#   0  the APK built, or the --gradle-task task line passed (on some attempt)
#   *  the build's own exit code, unchanged — a retry never rewrites it
#   2  wrong arguments (HAVEN_GRADLE_OFFLINE included), the self-test failed,
#      or (CI) the NDK cannot be provisioned for a reason that is this
#      script's, not the network's
#   3  (CI) the NDK or CMake did not install and verify within the attempts
#      and budget

set -euo pipefail

readonly SCRIPT_NAME="build_apk_with_retry.sh"
readonly MAX_ATTEMPTS="${HAVEN_BUILD_MAX_ATTEMPTS:-4}"
readonly RETRY_BUDGET_SECS="${HAVEN_BUILD_RETRY_BUDGET_SECS:-180}"

# One entry per PAUSE at the default MAX_ATTEMPTS, i.e. exactly MAX_ATTEMPTS-1
# of them; fixture (h) pins that. A caller that asks for more attempts (the
# deps job's resolution does, so its wider budget is what ends it) repeats the
# last pause. Fixed steps, no jitter: a deterministic schedule is one a worst
# case can be computed from, and jitter buys nothing when the contended
# resource is a per-IP rate limiter rather than a thundering herd of our own
# making.
readonly BACKOFF_SECS=(20 45 75)
backoff_for() { # <attempt that just failed>
  printf '%s' "${BACKOFF_SECS[$1 - 1]:-${BACKOFF_SECS[-1]}}"
}

readonly RC_BROKEN=2

# Signatures of a transient repository/network failure. Anchored on Gradle's own
# dependency-resolution wording rather than a bare "error", so a compile failure
# that happens to mention a URL is not misread as a flake.
#
# Provenance of each alternative — MEASURED means this repo's CI printed it:
#   MEASURED   run 35622556197 job 106414462454: "Could not GET '...'. Received
#              status code 429 from server: Too Many Requests", "Could not
#              resolve all artifacts for configuration 'classpath'", "Could not
#              parse POM https://...", "Could not get resource '...'",
#              "Error resolving plugin [id: 'dev.flutter.flutter-plugin-loader'
#              ...]", "Gradle threw an error while downloading artifacts from
#              the network".
#   MEASURED   run 30732662493 job 91456350943 (`arm` leg, 2026-08-02): the same
#              429 on the same five Kotlin coordinates, two years' worth of
#              wording identical.
#   MEASURED   run 29054586352 (e2e_m7, recorded in docs/E2E_TROUBLESHOOTING.md
#              failure mode 6): a 403 — "Could not resolve org.jetbrains.kotlin
#              :kotlin-stdlib:2.0.21. / > Could not GET '...pom'. Received
#              status code 403 from server: Forbidden" — on one lane while every
#              sibling Android build in that run passed. A transient, in this
#              repo, with a status Gradle itself refuses to retry.
#   MEASURED   run 35418051379 job 105830389349 (nightly relay-customization,
#              2026-09-19): "Could not find org.jetbrains.kotlin:kotlin-stdlib
#              :2.0.21. / Searched in the following locations:" — the SAME
#              transient class (two sibling lanes built that commit fine), but
#              deliberately NOT given its own alternative here. That wording is
#              also exactly what a genuinely missing or mistyped version prints,
#              and it carries no status code, so matching it would make a real
#              "this dependency does not exist" error retriable. The incident is
#              already covered: its output also carries "Could not resolve ..."
#              and "Could not parse POM ...", which are matched below — and
#              because it IS, `infra_error` names that shape rather than
#              asserting a cause it cannot see.
#   MEASURED   run 42392657873 job 128468678459 (e2e_kp_rotation, 2026-11-07),
#              with the dependency cache missed: the Gradle WRAPPER, fetching
#              the distribution before Gradle runs, printed
#              "java.io.IOException: Server returned HTTP response code: 504 for
#              URL: https://github.com/gradle/gradle-distributions/releases/
#              download/v8.14.0/gradle-8.14-all.zip" — Java's wording, not
#              Gradle's, so the `status code` alternative never saw it, and no
#              in-Gradle retry can, since Gradle is not running yet. Matched by
#              WRAPPER_DOWNLOAD_RE, anchored on that wording AND the
#              distribution archive's name, and only for the codes Gradle
#              itself treats as transient (408, 429, 5xx): a 404 is a
#              distribution this commit named wrongly. The wrapper is the jar
#              Flutter supplies (its cache's gradle_wrapper; the stack matches
#              Gradle 2.10's), which deletes a partial `.part` before each
#              download and writes its `.ok` marker last, so a retry downloads
#              afresh. It fetches the same bytes, because
#              gradle-wrapper.properties pins them by `distributionSha256Sum`,
#              and a checksum mismatch prints no status and is never retried.
#              UNMEASURED: github.com redirects to a signed asset URL whose
#              archive name is a query value (`filename%3Dgradle-…`), so a 5xx
#              at that hop is matched by its `%3D` form.
#   MEASURED   run 44811957518 job 136563108866 (e2e_background_catchup,
#              2026-11-20), cache missed: "Plugin [id: 'org.gradle.kotlin.
#              kotlin-dsl', version: '6.5.7'] was not found ... (could not
#              resolve plugin artifact '...:6.5.7')" in 53 s, while twelve
#              sibling Android lanes of that run resolved the same marker and
#              the Portal serves it. Gradle's ArtifactRepositoriesPluginResolver
#              asks for the marker through a LENIENT artifact view and reports
#              ANY failure — a 429, a 5xx, a timeout, a real absence — in that
#              one lower-case wording, the cause discarded, so no other
#              alternative here can see it. Retried like "Could not resolve all
#              files": the same honest ambiguity, told in `infra_error`. A
#              real absence (a typo'd version) fails every attempt the same
#              way, so it still ends red, after a pause and a Gradle start-up
#              per retry: one or two retries inside the 180 s budget.
#   UNMEASURED "Read timed out", "Connection reset", "Connection timed out",
#              "Could not HEAD", "Could not download", and the 408/5xx codes:
#              never seen in this repo's logs. They are Gradle's own transient
#              class (VERIFIED in 8.14's and 9.5.0's NetworkingIssueVerifier, which retries
#              408, 429 and every 5xx), kept so the first occurrence is ridden
#              out rather than discovered.
#   UNMEASURED "[28] Timeout was reached": libcurl's error 28 as cargo prints it
#              when a crate download stalls inside cargokit's build. Gradle
#              never prints it, so an offline build still retries it.
#
# 403 has no alternative of its own, and that is NOT the same as 403 being
# refused. Gradle classifies 401/403 as authentication and never retries them,
# but this repo has MEASURED a transient one (run 29054586352 above), and every
# 403 it has ever printed arrived wrapped in "Could not resolve ..." /
# "Could not GET ..." — so the real 403 IS retried here, by the wrapper rather
# than by the number. What a bare status line cannot do is get itself classified
# from the number alone: with no resolution wording around it there is nothing
# to say the line came from dependency resolution at all. Fixture (i) pins both
# halves, because for a while this header claimed the opposite of what the code
# does.
readonly WRAPPER_DOWNLOAD_RE='Server returned HTTP response code: (408|429|5[0-9][0-9]) for URL: [^[:space:]]*(/|%3D)gradle-[0-9][0-9.]*-(all|bin)\.zip'
readonly RETRIABLE_RE="Could not (GET|HEAD|resolve|download|get resource)|Could not parse POM|Error resolving plugin|could not resolve plugin artifact '|downloading artifacts from the network|Read timed out|Connection (reset|timed out)|status code (408|429|5[0-9][0-9])|Could not resolve all (artifacts|dependencies|files)|\[28\] Timeout was reached|${WRAPPER_DOWNLOAD_RE}"

# Signatures that must NEVER be retried: intermittent but REAL. Retrying these
# converts a capacity problem into a passing build that hides it. Checked FIRST,
# because a runner that ran out of disk mid-download also prints a resolution
# error, and the capacity verdict is the one that must win.
#
# UNMEASURED, and deliberately kept anyway. The disk exhaustion these describe
# is real history — it is why every lane pins `--target-platform android-x64`
# (commits 9743293, ea4c7bc) — but the log that printed it has aged out of
# GitHub's retention, and a sweep back to 2026-07-12 found no current instance.
# These are a never-retry guard placed ahead of the evidence, not observed
# strings: the whole point is that the FIRST occurrence must not be retried.
readonly FATAL_RE='No space left on device|Java heap space|OutOfMemoryError|Cannot allocate memory'

# Gradle's own wording for a coordinate an offline build's cache lacks. Checked
# after FATAL_RE (a full disk still wins) and BEFORE RETRIABLE_RE, whose
# `Could not resolve` the same output always carries: a gap is never retried.
readonly OFFLINE_MISS_RE='available for offline mode'
# Gradle's resolution wordings, which while offline can only mean a gap. A
# coordinate after "Could not resolve " is what tells Gradle's line from
# curl's "Could not resolve host: <host>", which offline is still a network
# failure of something Gradle does not fetch.
readonly OFFLINE_GAP_RE="Could not resolve [A-Za-z0-9._-]+:[A-Za-z0-9._-]+|Could not resolve all (artifacts|dependencies|files) for configuration|could not resolve plugin artifact '|Error resolving plugin"

log() { printf '[%s] %s\n' "${SCRIPT_NAME}" "$*"; }
err() { printf '[%s] %s\n' "${SCRIPT_NAME}" "$*" >&2; }

# The two functions the self-test replaces, so it needs neither real time nor
# real waiting. Production reads the real clock and really sleeps; an env
# variable that could shorten either is an env variable that could make the
# stated worst case false.
build_now() { printf '%s' "${EPOCHSECONDS}"; }
build_sleep() { sleep "$1"; }

# Where the per-job retry budget is carried. RUNNER_TEMP is per-job on a hosted
# runner; the fallbacks only matter to a local run.
#
# The run discriminator is what keeps the fallback from turning one transient
# into a permanent one. `${TMPDIR:-/tmp}` survives across runs on a developer
# machine, so a fixed name would leave a spent budget lying there and every
# later build would decline to retry, silently, forever. On CI the id is the
# run's, so the file is still shared by every APK of a multi-APK step; locally
# it is the process's, so the budget stops carrying between invocations — the
# right way round, since the thing the budget exists to bound is a CI step.
budget_state_file() {
  printf '%s' "${HAVEN_BUILD_RETRY_STATE:-${RUNNER_TEMP:-${TMPDIR:-/tmp}}/haven-build-retry-budget-${GITHUB_RUN_ID:-$$}}"
}

budget_spent() {
  local f; f="$(budget_state_file)"
  local v=0
  if [[ -r "${f}" ]]; then
    v="$(cat "${f}")"
    [[ "${v}" =~ ^[0-9]+$ ]] || v=0
  fi
  printf '%s' "${v}"
}

budget_charge() { # $1 seconds to add
  local f; f="$(budget_state_file)"
  local now; now="$(budget_spent)"
  mkdir -p "$(dirname "${f}")" 2>/dev/null || true
  printf '%s' "$(( now + $1 ))" > "${f}"
}

# classify <text> -> fatal | offline | retry | fail
#
# The text is passed as a value, never piped in: under `pipefail` a
# `producer | grep -q` fails OPEN when grep exits early on its first match, and
# "fails open" here means classifying a capacity failure as retriable.
classify() {
  if grep -qE "${FATAL_RE}" <<<"$1"; then printf 'fatal'
  elif grep -qE "${OFFLINE_MISS_RE}" <<<"$1"; then printf 'offline'
  elif [[ "${HAVEN_GRADLE_OFFLINE:-}" == 1 ]] && grep -qE "${OFFLINE_GAP_RE}" <<<"$1"; then printf 'offline'
  elif grep -qE "${RETRIABLE_RE}" <<<"$1"; then printf 'retry'
  else printf 'fail'; fi
}

# The coordinates an offline build reported missing, comma-joined, from
# Gradle's two offline wordings only, each token held to a coordinate's
# characters.
offline_coordinates() { # <text>
  {
    grep -oE "No cached version of [A-Za-z0-9._:+-]+ available for offline mode" <<<"$1" \
      | sed -E 's/^No cached version of ([^ ]+) available.*$/\1/' || true
    grep -oE "could not resolve plugin artifact '[A-Za-z0-9._:+-]+'" <<<"$1" \
      | sed -E "s/^could not resolve plugin artifact '([^']+)'$/\1/" || true
  } | LC_ALL=C sort -u | paste -sd, - | sed 's/,/, /g'
}

offline_error() { # $1 rc, $2 the captured build output
  local coords
  coords="$(offline_coordinates "$2")"
  printf '::error::Gradle built OFFLINE from this run'"'"'s dependency set (android-gradle-deps.yml) and the set lacks %s. That is a gap in what the deps job resolved, not a network failure: no retry can fetch it, so none was made, and no test ran in this job. If this commit changed a dependency, scripts/ci/gradle_deps.sh'"'"'s key should have moved with it; otherwise havenResolveAll (scripts/ci/gradle-resolve-all.init.gradle.kts) is missing the configuration that asked for it. The original Gradle error is above, unaltered.\n' \
    "${coords:-a coordinate Gradle did not name (see its error above)}" >&2
  err "build failed offline (rc=$1) on a gap in this run's Gradle dependency set — not retrying."
}

# The one-line verdict a human scrolling a red job needs. `::error::` puts it in
# the run's annotation list, where a step that "failed with exit code 1" and ran
# no test otherwise says nothing about why.
#
# It says only what the captured output entitles it to say. "Rate-limited" is a
# claim about a remote server whose only evidence is a status code, and the
# retriable class deliberately includes a wrapper — "Could not resolve all files
# for configuration ..." — that a wrong or missing dependency version prints
# too. An annotation that asserts HTTP 429 over a mistyped coordinate sends the
# reader to re-run instead of to the diff. So: four wordings, each as specific
# as its evidence allows, and never the coordinate itself — Gradle's own output
# is above, unaltered, and already has it (Rule 15: an annotation is a log sink).
infra_error() { # $1 attempts, $2 rc, $3 the captured build output
  local why code
  if grep -qE "${WRAPPER_DOWNLOAD_RE}" <<<"$3"; then
    code="$(grep -oE 'Server returned HTTP response code: [0-9]{3}' <<<"$3" | tail -n 1 | grep -oE '[0-9]{3}$')"
    why="the Gradle wrapper could not download the Gradle distribution (HTTP ${code} from its host) before Gradle ran. That is INFRASTRUCTURE, not a product failure: the archive is pinned by distributionSha256Sum, so a re-run fetches the same bytes"
  elif grep -q 'status code 429' <<<"$3"; then
    why="a repository rate-limited this runner (HTTP 429). That is INFRASTRUCTURE, not a product failure — the limit follows the shared runner egress IP, not this commit. A re-run on a different runner is the remedy"
  elif grep -q 'Could not find ' <<<"$3" && grep -q 'Searched in the following locations' <<<"$3"; then
    why="Gradle reports a coordinate it could not find in any repository it searched. This repo has seen that shape as a transient, but it is ALSO exactly what a wrong or missing dependency version prints, and no status code says which. Read the Gradle error above FIRST: if this commit changed a dependency, no re-run will fix it"
  else
    why="no HTTP status was reported, so the cause is not knowable from here. Usually infrastructure — but if this commit changed a dependency, read the Gradle error above first"
  fi
  printf '::error::Gradle could not resolve build dependencies after %s attempt(s) and %ss of retry budget, and no test ran in this job: %s. The original Gradle error is above, unaltered.\n' \
    "$1" "${RETRY_BUDGET_SECS}" "${why}" >&2
  err "build failed after $1 attempt(s) (rc=$2) — last failure was a transient"
  err "repository/network error; see the ORIGINAL Gradle output above."
}

# build_with_retry <cmd> [args...]
#
# Runs the command, classifies any failure, and retries only the transient
# class, within both the attempt count and the wall-clock budget. Returns the
# command's OWN exit code on failure — never a code of its own invention.
build_with_retry() {
  local attempt=1 rc=0 out text verdict started elapsed spent backoff

  while :; do
    out="$(mktemp)"
    started="$(build_now)"
    # `tee` so the build streams live AND is captured for classification.
    # PIPESTATUS, not the pipeline status: the build's code must survive tee.
    set +e
    "$@" 2>&1 | tee "${out}"
    rc=${PIPESTATUS[0]}
    set -e
    elapsed=$(( $(build_now) - started ))

    if (( rc == 0 )); then
      rm -f "${out}"
      if (( attempt > 1 )); then
        log "built on attempt ${attempt}/${MAX_ATTEMPTS} after a transient repository failure."
      fi
      return 0
    fi

    text="$(cat "${out}")"
    rm -f "${out}"
    verdict="$(classify "${text}")"

    if [[ "${verdict}" == "fatal" ]]; then
      err "build failed on a CAPACITY condition (disk or memory) — not retrying."
      err "That is intermittent but real; a retry would hide it. Original output above."
      return "${rc}"
    fi

    if [[ "${verdict}" == "offline" ]]; then
      offline_error "${rc}" "${text}"
      return "${rc}"
    fi

    if [[ "${verdict}" == "fail" ]]; then
      err "build failed (rc=${rc}) with no dependency-resolution signature — not retrying."
      err "Treated as a genuine build failure; the original output is above, unaltered."
      return "${rc}"
    fi

    # EVERY retriably-failed attempt is charged, the first included, sleeps
    # too, so the budget holds all of the step's transient-failure time and the
    # header's worst case holds. A successful build is never charged: it is the
    # step's own work, not overhead.
    budget_charge "${elapsed}"

    if (( attempt >= MAX_ATTEMPTS )); then
      infra_error "${attempt}" "${rc}" "${text}"
      return "${rc}"
    fi

    # Project the next attempt from the one that just failed, and refuse to
    # START one the budget cannot pay for. Without the `elapsed` term the loop
    # committed to attempts it could not afford: a retriable failure is not
    # necessarily a fast failure (a runtime-classpath resolution dies at task
    # EXECUTION time, minutes in), so an unprojected retry could double the
    # longest build the step can run.
    backoff="$(backoff_for "${attempt}")"
    spent="$(budget_spent)"
    if (( spent + backoff + elapsed > RETRY_BUDGET_SECS )); then
      err "retry budget spent (${spent}s of ${RETRY_BUDGET_SECS}s used by this job;"
      err "the next attempt is projected at ${elapsed}s plus a ${backoff}s pause) — not"
      err "starting another. The step's worst case is bounded on purpose."
      infra_error "${attempt}" "${rc}" "${text}"
      return "${rc}"
    fi

    log "attempt ${attempt}/${MAX_ATTEMPTS} hit a transient Gradle repository failure;"
    log "waiting ${backoff}s (${spent}s of the ${RETRY_BUDGET_SECS}s budget used)."
    budget_charge "${backoff}"
    build_sleep "${backoff}"
    attempt=$(( attempt + 1 ))
  done
}

# ---------------------------------------------------------------------------
# The Android NDK, installed and verified before the first build (CI only).
#
# Flutter's Gradle plugin (3.47.9, FlutterPluginUtils.forceNdkDownload) runs
# `sdkmanager --install ndk;<flutter.ndkVersion>` itself when the SDK does not
# hold that version: once, judged by its exit code and a `source.properties`
# marker, never retried. The ubuntu-26.04 runner image ships NDK 30 alone, so
# since `ubuntu-latest` moved to it every Android build downloads the ~700 MB
# NDK 28 that way, and in CI run 41546262596 one download arrived truncated
# ("Error reading Zip content from a SeekableByteChannel"): the build died
# before compiling anything, no test ran, and the classifier above rightly
# found no dependency-resolution signature to retry.
#
# So the install happens here, ahead of Gradle, under this script's rules. An
# attempt is graded by what landed on disk — that version's `source.properties`
# naming exactly that revision, sdkmanager's `package.xml` (the marker cargokit
# reads), and its clang running — never by sdkmanager's
# exit code. A package that fails the grading is removed together with
# sdkmanager's download cache before the next attempt (a kept archive would make
# the retry an unzip of the same truncated bytes). Every failed attempt and
# every pause is charged to the SAME budget as the Gradle retries, with the same
# projection, so the worst case in the header holds for the step as a whole;
# the install that succeeds is part of B, as it already was inside Gradle
# (measured 15-60 s across the 15 jobs of run 41546262596 that made it). Once
# the NDK verifies, Flutter finds it installed and makes no call of its own.
#
# CI only: a developer's SDK is theirs, and there Flutter installs what it needs
# exactly as before.
# ---------------------------------------------------------------------------

# 5x the slowest healthy install measured (60 s): an attempt is cut only when it
# is plainly stalled, never because a mirror is slow, since an attempt that long
# also starts no second one (the projection). The self-test replaces the
# function, not the constant, for the same reason build_now is a function.
readonly NDK_ATTEMPT_SECS=300
readonly NDK_PROBE_SECS=20
readonly RC_SDK_FAILED=3
ndk_attempt_secs() { printf '%s' "${NDK_ATTEMPT_SECS}"; }

# ndk_required_version <flutter-root> <app build.gradle.kts> — the version
# Flutter's plugin will ask for, read where it is defined. A source that moved
# is refused rather than guessed at: provisioning the wrong version is a silent
# no-op that hands the download back to Flutter's single unretried call.
ndk_required_version() {
  local ext="$1/packages/flutter_tools/gradle/src/main/kotlin/FlutterExtension.kt" app="$2" pins found
  pins="$(grep -cE '^[[:space:]]*ndkVersion[[:space:]]*=[[:space:]]*flutter\.ndkVersion[[:space:]]*$' "${app}" 2>/dev/null || true)"
  if [[ "${pins}" != "1" ]]; then
    err "${app} does not set 'ndkVersion = flutter.ndkVersion' exactly once, so the"
    err "NDK it builds with is not the one this script reads; teach ndk_required_version its source."
    return 1
  fi
  found="$(sed -nE 's/^[[:space:]]*val ndkVersion: String = "([0-9]+\.[0-9]+\.[0-9]+)"[[:space:]]*$/\1/p' "${ext}" 2>/dev/null || true)"
  if [[ ! "${found}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    err "cannot read flutter.ndkVersion from ${ext}: exactly one"
    err "'val ndkVersion: String = \"<x.y.z>\"' line was expected, so Flutter has moved it."
    return 1
  fi
  printf '%s' "${found}"
}

# ndk_verified <dir> <version> — the grading. Says on stderr why it failed.
ndk_verified() {
  local dir="$1" ver="$2" host
  if [[ ! -f "${dir}/source.properties" ]]; then
    err "  NDK ${ver}: no source.properties."
    return 1
  fi
  if ! grep -qxE "Pkg\.Revision[[:space:]]*=[[:space:]]*${ver//./\\.}[[:space:]]*" "${dir}/source.properties"; then
    err "  NDK ${ver}: source.properties names another revision."
    return 1
  fi
  if [[ ! -f "${dir}/package.xml" ]]; then
    err "  NDK ${ver}: no package.xml, which sdkmanager writes last."
    return 1
  fi
  case "$(uname -s)" in
    Linux) host=linux-x86_64 ;;
    Darwin) host=darwin-x86_64 ;;
    *) err "  NDK ${ver}: no NDK host toolchain for $(uname -s)."; return 1 ;;
  esac
  if ! timeout "${NDK_PROBE_SECS}" "${dir}/toolchains/llvm/prebuilt/${host}/bin/clang" --version >/dev/null 2>&1; then
    err "  NDK ${ver}: its clang is missing or does not run."
    return 1
  fi
  return 0
}

# Flutter's included Gradle build resolves its build classpath through the
# Plugin Portal alone; this init script gives it the Central-mirror fallback
# (its header has the incident). init.d, because Flutter passes Gradle no `-I`
# of ours.
install_central_fallback() {
  local dir="${GRADLE_USER_HOME:-${HOME}/.gradle}/init.d"
  mkdir -p "${dir}"
  cp "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/maven-central-fallback.init.gradle.kts" \
    "${dir}/haven-maven-central-fallback.init.gradle.kts"
}

# The offline switch (see "Offline" in the header). The caller removes it
# through remove_offline in an EXIT trap.
offline_init_path() {
  printf '%s' "${GRADLE_USER_HOME:-${HOME}/.gradle}/init.d/haven-gradle-offline.init.gradle.kts"
}

install_offline() {
  mkdir -p "$(dirname "$(offline_init_path)")"
  cp "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/gradle-offline.init.gradle.kts" "$(offline_init_path)"
}

remove_offline() { rm -f "$(offline_init_path)"; }

# sdk_manager <sdk-root> <label> — the sdkmanager to install with, or rc 2.
sdk_manager() {
  local m="$1/cmdline-tools/latest/bin/sdkmanager"
  if [[ ! -x "${m}" ]]; then
    m="$(command -v sdkmanager || true)"
  fi
  if [[ -z "${m}" || ! -x "${m}" ]]; then
    printf '::error::no executable sdkmanager under the SDK root or on PATH, so %s cannot be provisioned — this script is broken, not the lane.\n' "$2" >&2
    return "${RC_BROKEN}"
  fi
  printf '%s' "${m}"
}

# install_sdk_package <sdk-root> <sdkmanager> <package> <dir> <grader> <version> <label>
#
# The install loop the NDK header above describes, for any package graded by
# <grader> <dir> <version>: never by sdkmanager's exit code, a failed copy and
# sdkmanager's download cache removed before the next attempt, every failed
# attempt and pause charged to the shared budget under the same projection.
install_sdk_package() {
  local sdk="$1" sdkmanager="$2" pkg="$3" dir="$4" grader="$5" ver="$6" label="$7" attempt=1 rc started elapsed spent backoff out
  # A copy that fails the grading is not an install sdkmanager will redo.
  rm -rf "${dir}" "${sdk}/.downloadIntermediates" "${sdk}/.temp"

  while :; do
    out="$(mktemp)"
    started="$(build_now)"
    rc=0
    # sdkmanager would otherwise CREATE $XDG_CONFIG_HOME/.android (the runner
    # sets XDG_CONFIG_HOME), and AGP then keeps its debug keystore there, not
    # in ~/.android where the launch gate re-signs from (CI run 45801715777).
    ANDROID_USER_HOME="${HOME}/.android" \
      timeout -k 10 "$(ndk_attempt_secs)" "${sdkmanager}" "--sdk_root=${sdk}" --install "${pkg}" \
      > "${out}" 2>&1 <<<"$(printf 'y\n%.0s' {1..16})" || rc=$?
    elapsed=$(( $(build_now) - started ))
    if "${grader}" "${dir}" "${ver}"; then
      rm -f "${out}"
      log "${label} installed and verified on attempt ${attempt}/${MAX_ATTEMPTS} (sdkmanager rc ${rc})."
      return 0
    fi
    err "${label} did not verify on attempt ${attempt}/${MAX_ATTEMPTS} (sdkmanager rc ${rc}); its last lines:"
    tr '\r' '\n' < "${out}" | awk 'NF' | tail -n 6 | sed 's/^/    | /' >&2
    rm -f "${out}"
    rm -rf "${dir}" "${sdk}/.downloadIntermediates" "${sdk}/.temp"
    budget_charge "${elapsed}"
    if (( attempt >= MAX_ATTEMPTS )); then
      break
    fi
    backoff="$(backoff_for "${attempt}")"
    spent="$(budget_spent)"
    if (( spent + backoff + elapsed > RETRY_BUDGET_SECS )); then
      err "retry budget spent (${spent}s of ${RETRY_BUDGET_SECS}s used by this job; the next"
      err "attempt is projected at ${elapsed}s plus a ${backoff}s pause) — not starting another."
      break
    fi
    log "waiting ${backoff}s before ${label} attempt $(( attempt + 1 ))/${MAX_ATTEMPTS}."
    budget_charge "${backoff}"
    build_sleep "${backoff}"
    attempt=$(( attempt + 1 ))
  done
  printf '::error::the Android %s that this build needs could not be installed and verified after %s attempt(s). This is INFRASTRUCTURE, not a product failure: no APK was built and no test ran in this job.\n' "${label}" "${attempt}" >&2
  return "${RC_SDK_FAILED}"
}

# provision_ndk <flutter-root> <sdk-root> <app build.gradle.kts>
provision_ndk() {
  local flutter_root="$1" sdk="$2" app="$3" ver dir sdkmanager
  if [[ -z "${flutter_root}" ]]; then
    printf '::error::FLUTTER_ROOT is not set, so the NDK version Flutter builds with cannot be read — this script is broken, not the lane.\n' >&2
    return "${RC_BROKEN}"
  fi
  ver="$(ndk_required_version "${flutter_root}" "${app}")" || return "${RC_BROKEN}"
  if [[ -z "${sdk}" || ! -d "${sdk}" ]]; then
    printf '::error::neither ANDROID_HOME nor ANDROID_SDK_ROOT names an SDK directory, so NDK %s cannot be provisioned — this script is broken, not the lane.\n' "${ver}" >&2
    return "${RC_BROKEN}"
  fi
  dir="${sdk}/ndk/${ver}"
  if ndk_verified "${dir}" "${ver}" 2>/dev/null; then
    log "NDK ${ver} is installed and verified."
    return 0
  fi
  sdkmanager="$(sdk_manager "${sdk}" "NDK ${ver}")" || return "${RC_BROKEN}"
  install_sdk_package "${sdk}" "${sdkmanager}" "ndk;${ver}" "${dir}" ndk_verified "${ver}" "NDK ${ver}"
}

# ---------------------------------------------------------------------------
# CMake, installed and verified before the first build (CI only), for the same
# reason as the NDK and one more. Flutter's forceNdkDownload points AGP at an
# empty CMake project, and AGP installs the CMake that needs itself, once and
# unretried (the e2e_android, Debug Builds and launch-gate build jobs of run
# 45142774793 each printed "Installing CMake 3.22.1") — and OFFLINE not at
# all: "[CXX1300] CMake '3.22.1' was not found in SDK, PATH, or by cmake.dir
# property" (measured with Gradle 9.5.0 and AGP 9.3.1 while the offline lanes
# were introduced; the same build online installed it). 3.22.1 is AGP 9.3.1's
# default (com.android.build.gradle.internal.cxx.configure.CMakeVersion), which
# it asks for when, as here, the project names none. An AGP whose default moves
# fails the offline build naming the version it wanted: move this with it.
# ---------------------------------------------------------------------------
readonly CMAKE_VERSION=3.22.1

# cmake_verified <dir> <version> — the grading. Says on stderr why it failed.
cmake_verified() {
  local dir="$1" ver="$2"
  if [[ ! -f "${dir}/source.properties" ]] \
     || ! grep -qxE "Pkg\.Revision[[:space:]]*=[[:space:]]*${ver//./\\.}[[:space:]]*" "${dir}/source.properties"; then
    err "  CMake ${ver}: no source.properties naming that revision."
    return 1
  fi
  if [[ ! -f "${dir}/package.xml" ]]; then
    err "  CMake ${ver}: no package.xml, which sdkmanager writes last."
    return 1
  fi
  if ! timeout "${NDK_PROBE_SECS}" "${dir}/bin/cmake" --version >/dev/null 2>&1; then
    err "  CMake ${ver}: its cmake is missing or does not run."
    return 1
  fi
  return 0
}

# provision_cmake <sdk-root>
provision_cmake() {
  local sdk="$1" dir sdkmanager
  if [[ -z "${sdk}" || ! -d "${sdk}" ]]; then
    printf '::error::neither ANDROID_HOME nor ANDROID_SDK_ROOT names an SDK directory, so CMake %s cannot be provisioned — this script is broken, not the lane.\n' "${CMAKE_VERSION}" >&2
    return "${RC_BROKEN}"
  fi
  dir="${sdk}/cmake/${CMAKE_VERSION}"
  if cmake_verified "${dir}" "${CMAKE_VERSION}" 2>/dev/null; then
    log "CMake ${CMAKE_VERSION} is installed and verified."
    return 0
  fi
  sdkmanager="$(sdk_manager "${sdk}" "CMake ${CMAKE_VERSION}")" || return "${RC_BROKEN}"
  install_sdk_package "${sdk}" "${sdkmanager}" "cmake;${CMAKE_VERSION}" "${dir}" cmake_verified "${CMAKE_VERSION}" "CMake ${CMAKE_VERSION}"
}

# provision_sdk — both, NDK first (CI only; see each header).
provision_sdk() {
  local sdk="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-}}"
  provision_ndk "${FLUTTER_ROOT:-}" "${sdk}" \
    "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/haven/android/app/build.gradle.kts" || return
  provision_cmake "${sdk}"
}

# ---------------------------------------------------------------------------
# Self-test: hermetic. A fake `flutter` on PATH, no network, no real waiting.
# ---------------------------------------------------------------------------
readonly SELF_TEST_FIXTURES=37

# The verbatim Gradle output of CI run 35622556197 job 106414462454. Fixtures
# assert against what the runner actually printed, not a paraphrase of it: a
# predicate tuned to a paraphrase is a predicate nobody has tested.
readonly MEASURED_429_TEXT="FAILURE: Build failed with an exception.
* What went wrong:
Error resolving plugin [id: 'dev.flutter.flutter-plugin-loader', version: '1.0.0']
> A problem occurred configuring project ':gradle'.
   > Could not resolve all artifacts for configuration 'classpath'.
      > Could not resolve org.jetbrains.kotlin:kotlin-stdlib:2.0.21.
         > Could not get resource 'https://plugins.gradle.org/m2/org/jetbrains/kotlin/kotlin-stdlib/2.0.21/kotlin-stdlib-2.0.21.pom'.
            > Could not GET 'https://repo.maven.apache.org/maven2/org/jetbrains/kotlin/kotlin-stdlib/2.0.21/kotlin-stdlib-2.0.21.pom'. Received status code 429 from server: Too Many Requests
BUILD FAILED in 43s"

# The 403 this repo really drew, recorded verbatim in docs/E2E_TROUBLESHOOTING.md
# failure mode 6 from CI run 29054586352. It matters that it is the WRAPPED
# form: every 403 here has arrived inside Gradle's resolution wording, which is
# why the classifier retries it without any 403 alternative of its own.
readonly MEASURED_403_TEXT="Could not resolve org.jetbrains.kotlin:kotlin-stdlib:2.0.21.
   > Could not GET 'https://repo.maven.apache.org/maven2/org/jetbrains/kotlin/kotlin-stdlib/2.0.21/kotlin-stdlib-2.0.21.pom'. Received status code 403 from server: Forbidden"

# The wrapper's own failure, verbatim from CI run 42392657873 job 128468678459
# (log lines 1133-1146): printed by the Gradle WRAPPER before Gradle ran, in
# Java's wording.
readonly MEASURED_WRAPPER_504_TEXT="Exception in thread \"main\" java.io.IOException: Server returned HTTP response code: 504 for URL: https://github.com/gradle/gradle-distributions/releases/download/v8.14.0/gradle-8.14-all.zip
	at java.base/sun.net.www.protocol.http.HttpURLConnection.getInputStream0(HttpURLConnection.java:2034)
	at java.base/sun.net.www.protocol.http.HttpURLConnection.getInputStream(HttpURLConnection.java:1632)
	at java.base/sun.net.www.protocol.https.HttpsURLConnectionImpl.getInputStream(HttpsURLConnectionImpl.java:223)
	at org.gradle.wrapper.Download.downloadInternal(Download.java:58)
	at org.gradle.wrapper.Download.download(Download.java:44)
	at org.gradle.wrapper.Install\$1.call(Install.java:61)
	at org.gradle.wrapper.Install\$1.call(Install.java:48)
	at org.gradle.wrapper.ExclusiveFileAccessManager.access(ExclusiveFileAccessManager.java:65)
	at org.gradle.wrapper.Install.createDist(Install.java:48)
	at org.gradle.wrapper.WrapperExecutor.execute(WrapperExecutor.java:128)
	at org.gradle.wrapper.GradleWrapperMain.main(GradleWrapperMain.java:61)
Running Gradle task 'assembleDebug'...                             11.6s
Gradle task assembleDebug failed with exit code 1"

# The plugin-marker failure, verbatim from CI run 44811957518 job 136563108866:
# every resolution word in it is lower-case, and the cause is gone.
readonly MEASURED_PLUGIN_MARKER_TEXT="FAILURE: Build failed with an exception.

* Where:
Build file '/opt/hostedtoolcache/flutter/stable-3.50.1-x64/flutter/packages/flutter_tools/gradle/build.gradle.kts' line: 7

* What went wrong:
Plugin [id: 'org.gradle.kotlin.kotlin-dsl', version: '6.5.7'] was not found in any of the following sources:

- Gradle Core Plugins (plugin is not in 'org.gradle' namespace)
- Included Builds (No included builds contain this plugin)
- Plugin Repositories (could not resolve plugin artifact 'org.gradle.kotlin.kotlin-dsl:org.gradle.kotlin.kotlin-dsl.gradle.plugin:6.5.7')
  Searched in the following repositories:
    MavenRepo
    maven(https://maven-central.storage-download.googleapis.com/maven2/)
    Gradle Central Plugin Repository

BUILD FAILED in 53s
Running Gradle task 'assembleDebug'...                             53.8s
Gradle task assembleDebug failed with exit code 1"

# A dependency that does not exist. The `Could not find ... / Searched in the
# following locations:` half is MEASURED (run 35418051379 job 105830389349); the
# `:app:debugRuntimeClasspath` wrapper and the invented version are
# CONSTRUCTED, to stand for the case the measured one cannot: a coordinate this
# commit got wrong, resolved at task EXECUTION time, minutes into the build.
# It classifies as retriable — that is the point. The annotation must not then
# claim a rate limit.
readonly MISSING_COORDINATE_TEXT="FAILURE: Build failed with an exception.
* What went wrong:
Execution failed for task ':app:checkDebugAarMetadata'.
> Could not resolve all files for configuration ':app:debugRuntimeClasspath'.
   > Could not find org.jetbrains.kotlin:kotlin-stdlib:9.9.9.
     Searched in the following locations:
       - https://repo.maven.apache.org/maven2/org/jetbrains/kotlin/kotlin-stdlib/9.9.9/kotlin-stdlib-9.9.9.pom
     Required by:
         project :app
BUILD FAILED in 4m 12s"

# Gradle 9.5.0 building OFFLINE without AGP's aapt2, verbatim (one of its
# identical cause lines kept), from the local spike that introduced the offline
# lanes: the miss that taught `--resolve-only` its aapt2 witness.
readonly MEASURED_OFFLINE_MISS_TEXT="* What went wrong:
Execution failed for task ':app:compileDebugNavigationResources' (registered by plugin 'com.android.internal.application').
> A failure occurred while executing com.android.build.gradle.tasks.CompileNavigationXmlTask\$CompileNavigationResourcesAction
   > Could not isolate value com.android.build.gradle.tasks.CompileNavigationXmlTask\$CompileNavigationResourcesParams_Decorated@84a8f62 of type CompileNavigationXmlTask.CompileNavigationResourcesParams
      > Could not resolve all files for configuration ':app:detachedConfiguration1'.
         > Could not resolve com.android.tools.build:aapt2:9.3.1-15703166.
           Required by:
               project ':app'
            > No cached version of com.android.tools.build:aapt2:9.3.1-15703166 available for offline mode."

# write_fake_flutter <bindir> <mode>
#
# The fake models MEASURED behaviour and CARRIES ITS OWN CONTROL: it refuses any
# argv that is not the `build apk --debug --target-platform <x>` this script
# actually issues. A fake that answers the same way to everything proves nothing
# about what was passed to it — the lesson of the emulator probe that exited 255
# on a headless runner while its self-test stayed green.
write_fake_flutter() {
  local bindir="$1" mode="$2"
  mkdir -p "${bindir}"
  {
    printf '#!/usr/bin/env bash\n'
    printf 'set -u\n'
    printf 'printf "%%s\\n" "$*" >> "%s/argv.log"\n' "${bindir}"
    # The control. Anything but a real build invocation is refused, loudly.
    printf 'if [[ "${1:-}" != "build" || "${2:-}" != "apk" ]]; then\n'
    printf '  echo "fake-flutter: refusing argv that is not a build apk: $*" >&2; exit 97\n'
    printf 'fi\n'
    printf 'if [[ "$*" != *"--debug"* || "$*" != *"--target-platform"* ]]; then\n'
    printf '  echo "fake-flutter: refusing a build apk without --debug/--target-platform: $*" >&2; exit 97\n'
    printf 'fi\n'
    printf 'n=0; [[ -r "%s/n" ]] && n="$(cat "%s/n")"\n' "${bindir}" "${bindir}"
    printf 'n=$(( n + 1 )); printf "%%s" "${n}" > "%s/n"\n' "${bindir}"
    # What Gradle would find in init.d while this build runs.
    printf 'f="${GRADLE_USER_HOME:-${HOME}/.gradle}/init.d/haven-gradle-offline.init.gradle.kts"\n'
    printf 'if [[ -f "${f}" ]]; then cp "${f}" "%s/offline-seen"; echo present >> "%s/offline.log"; else echo absent >> "%s/offline.log"; fi\n' \
      "${bindir}" "${bindir}" "${bindir}"
    case "${mode}" in
      # Fails once with the MEASURED 429, then succeeds.
      flaky429)
        printf 'if (( n == 1 )); then cat <<%s\n%s\n%s\nexit 1\nfi\n' \
          "'GRADLE_EOF'" "${MEASURED_429_TEXT}" "GRADLE_EOF"
        printf 'echo "Built build/app/outputs/flutter-apk/app-debug.apk"\nexit 0\n'
        ;;
      always429)
        printf 'cat <<%s\n%s\n%s\nexit 1\n' \
          "'GRADLE_EOF'" "${MEASURED_429_TEXT}" "GRADLE_EOF"
        ;;
      # Fails once with the MEASURED wrapper 504, then succeeds.
      flakywrapper504)
        printf 'if (( n == 1 )); then cat <<%s\n%s\n%s\nexit 1\nfi\n' \
          "'GRADLE_EOF'" "${MEASURED_WRAPPER_504_TEXT}" "GRADLE_EOF"
        printf 'echo "Built build/app/outputs/flutter-apk/app-debug.apk"\nexit 0\n'
        ;;
      compile)
        printf 'echo "lib/src/main.dart:12:3: Error: Expected %s;%s after this."\nexit 1\n' "'" "'"
        ;;
      disk)
        printf 'echo "java.io.IOException: No space left on device"\nexit 1\n'
        ;;
      # Gradle 9.5.0's offline miss, as the spike that introduced the offline
      # lanes printed it for AGP's aapt2.
      offlinemiss)
        printf 'cat <<%s\n%s\n%s\nexit 1\n' "'GRADLE_EOF'" "${MEASURED_OFFLINE_MISS_TEXT}" "GRADLE_EOF"
        ;;
      ok)
        printf 'echo "Built build/app/outputs/flutter-apk/app-debug.apk"\nexit 0\n'
        ;;
      *) echo "write_fake_flutter: unknown mode ${mode}" >&2; return 1 ;;
    esac
  } > "${bindir}/flutter"
  chmod +x "${bindir}/flutter"
}

fake_invocations() { # <bindir>
  local f="$1/n"
  if [[ -r "${f}" ]]; then cat "${f}"; else printf '0'; fi
}

# The NDK fixtures' version. Any x.y.z serves, since the fixtures also write
# Flutter's definition of it — except where the REAL app build file is read.
readonly FAKE_NDK_VERSION="28.2.13676358"

fake_ndk_host() { case "$(uname -s)" in Darwin) printf 'darwin-x86_64' ;; *) printf 'linux-x86_64' ;; esac; }

# write_fake_ndk <dir> <revision> — the two things ndk_verified grades.
write_fake_ndk() {
  local dir="$1" rev="$2" clang
  clang="${dir}/toolchains/llvm/prebuilt/$(fake_ndk_host)/bin/clang"
  mkdir -p "$(dirname "${clang}")"
  printf 'Pkg.Desc = Android NDK\nPkg.Revision = %s\n' "${rev}" > "${dir}/source.properties"
  printf '<package/>\n' > "${dir}/package.xml"
  printf '#!/bin/sh\necho "Android clang version 19 (fake)"\n' > "${clang}"
  chmod +x "${clang}"
}

# write_fake_flutter_root <root> <version>... — one `val ndkVersion` line per
# version given, where Flutter 3.47.9 defines it.
write_fake_flutter_root() {
  local root="$1" f v
  shift
  f="${root}/packages/flutter_tools/gradle/src/main/kotlin/FlutterExtension.kt"
  mkdir -p "$(dirname "${f}")"
  {
    printf 'open class FlutterExtension {\n'
    for v in "$@"; do printf '    val ndkVersion: String = "%s"\n' "${v}"; done
    printf '}\n'
  } > "${f}"
}

# write_fake_sdkmanager <sdk-root> <ndk mode> [cmake mode]. Like the fake
# flutter it carries its own control: any argv but the two installs
# provision_sdk issues is refused, so a call that drifts reds the fixtures
# instead of passing against a yes-machine. CMake calls are counted apart, so
# every NDK fixture's count means what it always did.
write_fake_sdkmanager() {
  local sdk="$1" mode="$2" cmake_mode="${3:-ok}" bin="$1/cmdline-tools/latest/bin" host
  host="$(fake_ndk_host)"
  mkdir -p "${bin}"
  cat > "${bin}/sdkmanager" <<EOF
#!/usr/bin/env bash
set -u
sdk='${sdk}'; ver='${FAKE_NDK_VERSION}'; mode='${mode}'; cmake_mode='${cmake_mode}'
printf '%s %s\n' "\${3:-}" "\${ANDROID_USER_HOME:-unset}" >> "\${sdk}/user-home"
if [[ \$# -eq 3 && "\$1" == "--sdk_root=\${sdk}" && "\$2" == "--install" && "\$3" == "cmake;${CMAKE_VERSION}" ]]; then
  echo x >> "\${sdk}/cmake-invocations"
  if [[ "\${cmake_mode}" == ok ]]; then
    d="\${sdk}/cmake/${CMAKE_VERSION}"
    mkdir -p "\${d}/bin"
    printf 'Pkg.Revision = %s\nPkg.Path = cmake;%s\n' '${CMAKE_VERSION}' '${CMAKE_VERSION}' > "\${d}/source.properties"
    printf '<package/>\n' > "\${d}/package.xml"
    printf '#!/bin/sh\necho "cmake version ${CMAKE_VERSION} (fake)"\n' > "\${d}/bin/cmake"
    chmod +x "\${d}/bin/cmake"
  else
    echo "Warning: Failed to download package!"
  fi
  exit 0
fi
if [[ \$# -ne 3 || "\$1" != "--sdk_root=\${sdk}" || "\$2" != "--install" || "\$3" != "ndk;\${ver}" ]]; then
  echo "fake-sdkmanager: refusing argv: \$*" >&2
  exit 64
fi
echo x >> "\${sdk}/invocations"
n="\$(wc -l < "\${sdk}/invocations" | tr -d ' ')"
dir="\${sdk}/ndk/\${ver}"
put() { # <with a working clang: yes|no>
  mkdir -p "\${dir}/toolchains/llvm/prebuilt/${host}/bin"
  printf 'Pkg.Desc = Android NDK\nPkg.Revision = %s\n' "\${ver}" > "\${dir}/source.properties"
  printf '<package/>\n' > "\${dir}/package.xml"
  if [[ "\$1" == yes ]]; then
    printf '#!/bin/sh\necho "Android clang version 19 (fake)"\n' > "\${dir}/toolchains/llvm/prebuilt/${host}/bin/clang"
    chmod +x "\${dir}/toolchains/llvm/prebuilt/${host}/bin/clang"
  fi
}
case "\${mode}" in
  # Like the real one, it takes a package directory that exists for installed.
  ok) [[ -d "\${dir}" ]] || put yes ;;
  # sdkmanager's own wording when a download fails, and an exit code of 0.
  nothing) echo "Warning: Failed to download package!" ;;
  # Run 41546262596's shape: the manifest lands, the toolchain does not, and the
  # archive stays in the download cache. A retry over that cache unzips the same
  # bytes, so it fails the same way; only a cleared cache lets it install.
  truncated)
    if (( n == 1 )) || [[ -e "\${sdk}/.downloadIntermediates/ndk.zip" ]]; then
      mkdir -p "\${sdk}/.downloadIntermediates"
      echo partial > "\${sdk}/.downloadIntermediates/ndk.zip"
      put no
      echo "Warning: An error occurred while preparing SDK package NDK (Side by side) \${ver}: Error reading Zip content from a SeekableByteChannel."
      exit 1
    fi
    put yes ;;
  hang)
    echo started >> "\${sdk}/hang"
    sleep 300
    echo finished >> "\${sdk}/hang" ;;
  *) echo "fake-sdkmanager: unknown mode \${mode}" >&2; exit 65 ;;
esac
exit 0
EOF
  chmod +x "${bin}/sdkmanager"
}

sdk_invocations() { # <sdk-root> [count file]
  if [[ -r "$1/${2:-invocations}" ]]; then wc -l < "$1/${2:-invocations}" | tr -d ' '; else printf '0'; fi
}

run_self_test() {
  local tmp ran=0 failures=0 bin rc out slept CLOCK_FILE=""
  tmp="$(mktemp -d)"
  # shellcheck disable=SC2064  # expand tmp now, not at trap time.
  trap "rm -rf '${tmp}'" EXIT

  # Replaced for the whole self-test: the real ladder would put 140 s of sleep
  # into a guard that runs on every push. Every pause is RECORDED instead, so
  # fixtures can assert how many happened and for how long.
  build_sleep() { printf '%s\n' "$1" >> "${tmp}/sleeps"; }

  # An INJECTED clock, so a fixture can make an attempt "take" minutes without
  # waiting any. Each call consumes the next line of CLOCK_FILE; with no file,
  # or once it is empty, it is the real clock — so every fixture that does not
  # set one measures exactly what production measures. File-backed rather than
  # an array because `build_now` is read through `$( )`, and a subshell's
  # variables die with it while its writes do not.
  build_now() {
    local v
    if [[ -n "${CLOCK_FILE:-}" && -s "${CLOCK_FILE}" ]]; then
      v="$(head -n 1 "${CLOCK_FILE}")"
      tail -n +2 "${CLOCK_FILE}" > "${CLOCK_FILE}.rest"
      mv "${CLOCK_FILE}.rest" "${CLOCK_FILE}"
      printf '%s' "${v}"
    else
      printf '%s' "${EPOCHSECONDS}"
    fi
  }

  _fail() { echo "SELF-TEST FAIL ($1): $2" >&2; failures=1; }
  _sleeps() { if [[ -r "${tmp}/sleeps" ]]; then wc -l < "${tmp}/sleeps" | tr -d ' '; else printf '0'; fi; }

  # (a) A transient 429 on the first attempt is ridden out: rc 0, two
  #     invocations, exactly one pause, and that pause is the ladder's first.
  ran=$(( ran + 1 ))
  bin="${tmp}/a"; write_fake_flutter "${bin}" flaky429
  rm -f "${tmp}/sleeps"
  rc=0
  out="$(export PATH="${bin}:${PATH}" HAVEN_BUILD_RETRY_STATE="${tmp}/a.budget"; \
         build_with_retry flutter build apk --debug --target-platform android-x64 2>&1)" || rc=$?
  slept="$(_sleeps)"
  if (( rc != 0 )) || [[ "$(fake_invocations "${bin}")" != "2" ]] || (( slept != 1 )) \
     || [[ "$(head -1 "${tmp}/sleeps")" != "${BACKOFF_SECS[0]}" ]]; then
    _fail a "a 429 that clears on the second attempt must return 0 after exactly 2 invocations and 1 pause of ${BACKOFF_SECS[0]}s; got rc=${rc}, $(fake_invocations "${bin}") invocation(s), ${slept} pause(s)"
  fi

  # (a2) CONTROL for (a): the fake really does refuse an argv it was not given,
  #      so (a)'s green means the build command was passed through intact rather
  #      than the fake saying yes to anything.
  ran=$(( ran + 1 ))
  rc=0
  out="$(PATH="${bin}:${PATH}" flutter --version 2>&1)" || rc=$?
  if (( rc != 97 )) || [[ "${out}" != *"refusing argv"* ]]; then
    _fail a2 "the fake flutter accepted a non-build argv (rc=${rc}); it no longer models the call this script makes, so (a) cannot see a wrong command line"
  fi

  # (a3) CONTROL for (a): the same fake refuses a build that drops the flags
  #      this script is responsible for adding.
  ran=$(( ran + 1 ))
  rc=0
  out="$(PATH="${bin}:${PATH}" flutter build apk 2>&1)" || rc=$?
  if (( rc != 97 )) || [[ "${out}" != *"without --debug"* ]]; then
    _fail a3 "the fake flutter accepted a build apk with no --debug/--target-platform (rc=${rc}); (a) would then pass even if this script stopped adding them"
  fi

  # (a4) The wrapper's distribution download failing with a 5xx is ridden out
  #      the same way, through the whole retry engine, not only the classifier.
  ran=$(( ran + 1 ))
  bin="${tmp}/a4"; write_fake_flutter "${bin}" flakywrapper504
  rm -f "${tmp}/sleeps"
  rc=0
  out="$(export PATH="${bin}:${PATH}" HAVEN_BUILD_RETRY_STATE="${tmp}/a4.budget"; \
         build_with_retry flutter build apk --debug --target-platform android-x64 2>&1)" || rc=$?
  slept="$(_sleeps)"
  if (( rc != 0 )) || [[ "$(fake_invocations "${bin}")" != "2" ]] || (( slept != 1 )); then
    _fail a4 "a wrapper 504 that clears on the second attempt must return 0 after exactly 2 invocations and 1 pause; got rc=${rc}, $(fake_invocations "${bin}") invocation(s), ${slept} pause(s)"
  fi

  # (b) A COMPILE error is never retried: one invocation, no pause, the
  #     command's own rc, and its original output still shown.
  ran=$(( ran + 1 ))
  bin="${tmp}/b"; write_fake_flutter "${bin}" compile
  rm -f "${tmp}/sleeps"
  rc=0
  out="$(export PATH="${bin}:${PATH}" HAVEN_BUILD_RETRY_STATE="${tmp}/b.budget"; \
         build_with_retry flutter build apk --debug --target-platform android-x64 2>&1)" || rc=$?
  if (( rc != 1 )) || [[ "$(fake_invocations "${bin}")" != "1" ]] || (( $(_sleeps) != 0 )) \
     || [[ "${out}" != *"Expected ';' after this."* ]] || [[ "${out}" != *"no dependency-resolution signature"* ]]; then
    _fail b "a compile error must fail once with its own rc and its original output; got rc=${rc}, $(fake_invocations "${bin}") invocation(s), $(_sleeps) pause(s)"
  fi

  # (c) A CAPACITY failure is never retried either — and is reported as
  #     capacity, not as a network flake, so the real problem stays visible.
  ran=$(( ran + 1 ))
  bin="${tmp}/c"; write_fake_flutter "${bin}" disk
  rm -f "${tmp}/sleeps"
  rc=0
  out="$(export PATH="${bin}:${PATH}" HAVEN_BUILD_RETRY_STATE="${tmp}/c.budget"; \
         build_with_retry flutter build apk --debug --target-platform android-x64 2>&1)" || rc=$?
  if (( rc != 1 )) || [[ "$(fake_invocations "${bin}")" != "1" ]] || (( $(_sleeps) != 0 )) \
     || [[ "${out}" != *"CAPACITY condition"* ]]; then
    _fail c "disk exhaustion must fail once, named as capacity; got rc=${rc}, $(fake_invocations "${bin}") invocation(s), $(_sleeps) pause(s)"
  fi

  # (d) A 429 that never clears stops at EXACTLY MAX_ATTEMPTS, with the
  #     infrastructure verdict and the original Gradle error both present.
  ran=$(( ran + 1 ))
  bin="${tmp}/d"; write_fake_flutter "${bin}" always429
  rm -f "${tmp}/sleeps"
  rc=0
  out="$(export PATH="${bin}:${PATH}" HAVEN_BUILD_RETRY_STATE="${tmp}/d.budget"; \
         build_with_retry flutter build apk --debug --target-platform android-x64 2>&1)" || rc=$?
  if (( rc != 1 )) || [[ "$(fake_invocations "${bin}")" != "${MAX_ATTEMPTS}" ]] \
     || [[ "${out}" != *"::error::"* ]] || [[ "${out}" != *"INFRASTRUCTURE"* ]] \
     || [[ "${out}" != *"no test ran in this job"* ]] \
     || [[ "${out}" != *"Received status code 429"* ]]; then
    _fail d "a persistent 429 must stop at exactly ${MAX_ATTEMPTS} invocations with one ::error:: saying INFRASTRUCTURE and no test ran, the original Gradle error still shown; got rc=${rc}, $(fake_invocations "${bin}") invocation(s)"
  fi

  # (e) A budget already spent by an EARLIER build in the same step means no
  #     further attempt at all — the multi-APK step cannot spend the budget once
  #     per target. One invocation, no pause, infrastructure verdict.
  ran=$(( ran + 1 ))
  bin="${tmp}/e"; write_fake_flutter "${bin}" always429
  rm -f "${tmp}/sleeps"
  printf '%s' "${RETRY_BUDGET_SECS}" > "${tmp}/e.budget"
  rc=0
  out="$(export PATH="${bin}:${PATH}" HAVEN_BUILD_RETRY_STATE="${tmp}/e.budget"; \
         build_with_retry flutter build apk --debug --target-platform android-x64 2>&1)" || rc=$?
  if (( rc != 1 )) || [[ "$(fake_invocations "${bin}")" != "1" ]] || (( $(_sleeps) != 0 )) \
     || [[ "${out}" != *"retry budget spent"* ]]; then
    _fail e "a spent budget must stop the run without another attempt; got rc=${rc}, $(fake_invocations "${bin}") invocation(s), $(_sleeps) pause(s)"
  fi

  # (f) The budget is CARRIED between invocations, which is what makes (e)
  #     reachable in a real multi-APK step: a run that retried must leave the
  #     state file larger than it found it.
  ran=$(( ran + 1 ))
  bin="${tmp}/f"; write_fake_flutter "${bin}" always429
  rm -f "${tmp}/sleeps" "${tmp}/f.budget"
  rc=0
  (export PATH="${bin}:${PATH}" HAVEN_BUILD_RETRY_STATE="${tmp}/f.budget"; \
    build_with_retry flutter build apk --debug --target-platform android-x64 >/dev/null 2>&1) || rc=$?
  if (( rc != 1 )) || [[ ! -r "${tmp}/f.budget" ]] || (( $(cat "${tmp}/f.budget") <= 0 )); then
    _fail f "a retried build must charge the shared budget file; got rc=${rc}, state='$( [[ -r "${tmp}/f.budget" ]] && cat "${tmp}/f.budget" )'"
  fi

  # (g) A clean build runs ONCE and touches nothing: no pause, and no budget
  #     charged, so a healthy lane pays nothing for this machinery.
  ran=$(( ran + 1 ))
  bin="${tmp}/g"; write_fake_flutter "${bin}" ok
  rm -f "${tmp}/sleeps" "${tmp}/g.budget"
  rc=0
  (export PATH="${bin}:${PATH}" HAVEN_BUILD_RETRY_STATE="${tmp}/g.budget"; \
    build_with_retry flutter build apk --debug --target-platform android-x64 >/dev/null 2>&1) || rc=$?
  if (( rc != 0 )) || [[ "$(fake_invocations "${bin}")" != "1" ]] || (( $(_sleeps) != 0 )) \
     || [[ -r "${tmp}/g.budget" ]]; then
    _fail g "a clean build must run once, never pause and never charge the budget; got rc=${rc}, $(fake_invocations "${bin}") invocation(s), $(_sleeps) pause(s)"
  fi

  # (i) The classifier, sample by sample. The MEASURED Gradle failure carries
  #     FIVE retriable signatures at once, so fixtures (a)/(d) stay green even
  #     if one alternative is deleted. These samples each isolate ONE, which is
  #     what makes every alternative load-bearing — and they pin the judgements
  #     the prose above claims and no other fixture can see: what a BARE status
  #     line does and does not decide, what this repo's REAL 403 does, and that
  #     a capacity signature BEATS a resolution one in the same output.
  ran=$(( ran + 1 ))
  _classifies() { # <label> <expected> <sample>
    local got; got="$(classify "$3")"
    [[ "${got}" == "$2" ]] || _fail i "${1}: classified '${got}', expected '${2}'"
  }
  _classifies "bare 429 status line" retry \
    "> Received status code 429 from server: Too Many Requests"
  # A bare status line with NO resolution wording is not classified from the
  # number: nothing in it says the line came from dependency resolution at all.
  # This is not a judgement about 403 — see the next sample, which is the 403
  # this repo really drew and IS retried.
  _classifies "bare 403 status line, no resolution wording" fail \
    "> Received status code 403 from server: Forbidden"
  _classifies "the MEASURED 403, wrapped as Gradle really printed it" retry \
    "${MEASURED_403_TEXT}"
  # A dependency that does not exist is retriable too — the wrapper is the same
  # one a transient prints. The retry is deliberate; `infra_error` is where the
  # difference has to be told honestly, which fixture (m) pins.
  _classifies "a coordinate that exists nowhere" retry \
    "${MISSING_COORDINATE_TEXT}"
  _classifies "the MEASURED plugin marker Gradle reported missing" retry \
    "${MEASURED_PLUGIN_MARKER_TEXT}"
  # A plugin request Gradle refuses before asking any repository is this
  # commit's, and its notFound shares everything with the sample above but the
  # marker wording.
  _classifies "a plugin request with no version, refused before any lookup" fail \
    "Plugin [id: 'com.example.plugin'] was not found in any of the following sources:

- Gradle Core Plugins (plugin is not in 'org.gradle' namespace)
- Included Builds (No included builds contain this plugin)
- Plugin Repositories (plugin dependency must include a version number for this source)"
  _classifies "bare 503 status line" retry \
    "> Received status code 503 from server: Service Unavailable"
  _classifies "bare failed GET" retry \
    "> Could not GET 'https://repo.maven.apache.org/maven2/x/y/1.0/y-1.0.pom'."
  _classifies "bare unparseable POM" retry \
    "> Could not parse POM https://plugins.gradle.org/m2/x/y/1.0/y-1.0.pom"
  _classifies "socket read timeout" retry \
    "Caused by: java.net.SocketTimeoutException: Read timed out"
  _classifies "the MEASURED wrapper 504 fetching the distribution" retry \
    "${MEASURED_WRAPPER_504_TEXT}"
  # The wrapper alternative is anchored on the distribution archive: Java's
  # wording for some other URL decides nothing, and a 404 is a distribution
  # this commit named wrongly.
  _classifies "Java's 504 wording for a URL that is not the distribution" fail \
    "java.io.IOException: Server returned HTTP response code: 504 for URL: https://example.invalid/app.json"
  _classifies "a wrapper 503 at the redirect's signed asset URL" retry \
    "java.io.IOException: Server returned HTTP response code: 503 for URL: https://release-assets.githubusercontent.com/github-production-release-asset/1/2?sp=r&response-content-disposition=attachment%3B%20filename%3Dgradle-8.14-all.zip&response-content-type=application%2Foctet-stream"
  _classifies "Java's 504 wording for some other archive" fail \
    "java.io.IOException: Server returned HTTP response code: 504 for URL: https://example.invalid/releases/app-release.zip"
  _classifies "a wrapper 404 is a misnamed distribution, never retried" fail \
    "java.io.IOException: Server returned HTTP response code: 404 for URL: https://services.gradle.org/distributions/gradle-8.99-all.zip"
  _classifies "a distribution failing its pinned checksum is never retried" fail \
    "Exception in thread \"main\" java.lang.RuntimeException: Verification of Gradle distribution failed!"
  _classifies "kotlin compile error" fail \
    "e: file:///x/Main.kt:8:1 Unresolved reference: foo"
  _classifies "capacity WINS over a resolution error in the same output" fatal \
    "> Could not GET 'https://repo.maven.apache.org/x.pom'.
java.io.IOException: No space left on device"

  # (j) End to end, as a SUBPROCESS: the script itself, not just its retry
  #     engine, must issue `build apk --debug --target-platform <x>` and forward
  #     the caller's arguments. Every fixture above calls build_with_retry
  #     directly and so cannot see the argv this script assembles — the one line
  #     every lane depends on.
  ran=$(( ran + 1 ))
  bin="${tmp}/j"; write_fake_flutter "${bin}" ok
  rc=0
  out="$(PATH="${bin}:${PATH}" GITHUB_ACTIONS= HAVEN_BUILD_RETRY_STATE="${tmp}/j.budget" \
         bash "${BASH_SOURCE[0]}" android-x64 --target=integration_test/x.dart \
         --dart-define=HAVEN_LIVE_SYNC=false 2>&1)" || rc=$?
  if (( rc != 0 )) || [[ "$(cat "${bin}/argv.log")" != "build apk --debug --target-platform android-x64 --target=integration_test/x.dart --dart-define=HAVEN_LIVE_SYNC=false" ]]; then
    _fail j "the script must run 'build apk --debug --target-platform <x>' and forward the caller's arguments verbatim; got rc=${rc}, argv='$(cat "${bin}/argv.log" 2>/dev/null)'"
  fi

  # (k) A retriable failure that took a LONG time starts no further attempt.
  #     150 s is chosen to isolate the PROJECTION: 150 charged plus the 20 s
  #     pause is 170, still inside the 180 s budget, so neither the spend nor
  #     the pause alone would stop the loop — only adding what the next attempt
  #     is projected to cost does. The build still ends with its OWN exit code
  #     and the infrastructure verdict, because refusing to retry is not the
  #     same as swallowing the failure.
  ran=$(( ran + 1 ))
  bin="${tmp}/k"; write_fake_flutter "${bin}" always429
  rm -f "${tmp}/sleeps"
  CLOCK_FILE="${tmp}/k.clock"; printf '1000\n1150\n' > "${CLOCK_FILE}"
  rc=0
  out="$(export PATH="${bin}:${PATH}" HAVEN_BUILD_RETRY_STATE="${tmp}/k.budget"; \
         build_with_retry flutter build apk --debug --target-platform android-x64 2>&1)" || rc=$?
  CLOCK_FILE=""
  if (( rc != 1 )) || [[ "$(fake_invocations "${bin}")" != "1" ]] || (( $(_sleeps) != 0 )) \
     || [[ "${out}" != *"projected at 150s"* ]] || [[ "${out}" != *"::error::"* ]] \
     || [[ "${out}" != *"Received status code 429"* ]]; then
    _fail k "an attempt whose repeat cannot fit the budget must not be started: expected rc 1 after exactly 1 invocation and 0 pauses, with the projection named and the original Gradle error kept; got rc=${rc}, $(fake_invocations "${bin}") invocation(s), $(_sleeps) pause(s)"
  fi

  # (k2) CONTROL for (k): the same injected clock, a SHORT attempt (30 s, the
  #      MEASURED class), and the retry happens. Without this, (k) would also
  #      pass if injecting a clock at all made the loop refuse everything.
  ran=$(( ran + 1 ))
  bin="${tmp}/k2"; write_fake_flutter "${bin}" flaky429
  rm -f "${tmp}/sleeps"
  CLOCK_FILE="${tmp}/k2.clock"; printf '1000\n1030\n' > "${CLOCK_FILE}"
  rc=0
  out="$(export PATH="${bin}:${PATH}" HAVEN_BUILD_RETRY_STATE="${tmp}/k2.budget"; \
         build_with_retry flutter build apk --debug --target-platform android-x64 2>&1)" || rc=$?
  slept="$(_sleeps)"
  CLOCK_FILE=""
  if (( rc != 0 )) || [[ "$(fake_invocations "${bin}")" != "2" ]] || (( slept != 1 )); then
    _fail k2 "a 30s failure is well inside the budget and must still be retried; got rc=${rc}, $(fake_invocations "${bin}") invocation(s), ${slept} pause(s)"
  fi

  # (m) The annotation says only what the output entitles it to say. Four
  #     wordings, one per evidence class, and none of them reprints the
  #     coordinate: Gradle's own output is above, unaltered, and an annotation
  #     is a log sink (Rule 15).
  ran=$(( ran + 1 ))
  _annotation() { # <label> <text> <must-say> <must-not-say>
    local got; got="$(infra_error 4 1 "$2" 2>&1)"
    if [[ "${got}" != *"$3"* ]]; then
      _fail m "${1}: the annotation never says '${3}'"
    fi
    if [[ -n "$4" && "${got}" == *"$4"* ]]; then
      _fail m "${1}: the annotation claims '${4}', which this output is no evidence for"
    fi
    if [[ "${got}" != *"no test ran in this job"* ]]; then
      _fail m "${1}: the annotation drops the one fact every wording owes the reader"
    fi
  }
  _annotation "a 429 is named as the rate limit it is" \
    "${MEASURED_429_TEXT}" "HTTP 429" ""
  _annotation "a missing coordinate is NOT called a rate limit" \
    "${MISSING_COORDINATE_TEXT}" "if this commit changed a dependency" "429"
  _annotation "a missing coordinate is not reprinted by us" \
    "${MISSING_COORDINATE_TEXT}" "a coordinate it could not find" "kotlin-stdlib:9.9.9"
  _annotation "a wrapper 504 names the distribution download and its status" \
    "${MEASURED_WRAPPER_504_TEXT}" "Gradle distribution (HTTP 504" "429"
  _annotation "a timeout with no status admits it cannot know" \
    "> Could not resolve all files for configuration ':app:debugRuntimeClasspath'.
Caused by: java.net.SocketTimeoutException: Read timed out" \
    "not knowable from here" "429"
  _annotation "a plugin marker reported missing admits it cannot know" \
    "${MEASURED_PLUGIN_MARKER_TEXT}" "not knowable from here" "429"
  _annotation "a plugin marker reported missing is not reprinted by us" \
    "${MEASURED_PLUGIN_MARKER_TEXT}" "if this commit changed a dependency" "kotlin-dsl"

  # (n) The budget state file is per RUN. Its fallback lives under a directory
  #     that survives reboots on a developer machine, so a fixed name would let
  #     ONE transient leave a spent budget behind and silently disable retries
  #     from then on. Both decoys below are readable and say the budget is gone;
  #     neither is this run's.
  ran=$(( ran + 1 ))
  bin="${tmp}/n"; write_fake_flutter "${bin}" flaky429
  rm -f "${tmp}/sleeps"; mkdir -p "${tmp}/n-temp"
  printf '%s' "${RETRY_BUDGET_SECS}" > "${tmp}/n-temp/haven-build-retry-budget"
  printf '%s' "${RETRY_BUDGET_SECS}" > "${tmp}/n-temp/haven-build-retry-budget-222"
  rc=0
  out="$(export PATH="${bin}:${PATH}" RUNNER_TEMP="${tmp}/n-temp" GITHUB_RUN_ID=111; \
         unset HAVEN_BUILD_RETRY_STATE; \
         build_with_retry flutter build apk --debug --target-platform android-x64 2>&1)" || rc=$?
  if (( rc != 0 )) || [[ "$(fake_invocations "${bin}")" != "2" ]] \
     || [[ ! -r "${tmp}/n-temp/haven-build-retry-budget-111" ]]; then
    _fail n "a spent budget left by another run must not be read, and this run must charge its own file; got rc=${rc}, $(fake_invocations "${bin}") invocation(s), this run's file $( [[ -r "${tmp}/n-temp/haven-build-retry-budget-111" ]] && echo present || echo ABSENT )"
  fi

  # ---- The Android NDK (provision_ndk). One fake Flutter root and one app
  #      build file serve every in-process fixture below; each fixture has its
  #      own SDK root, budget file and pause log.
  local sdk fr="${tmp}/flutter-root" app="${tmp}/app.gradle.kts" ndk_dir
  write_fake_flutter_root "${fr}" "${FAKE_NDK_VERSION}"
  printf 'android {\n    ndkVersion = flutter.ndkVersion\n}\n' > "${app}"
  _ndk_dir() { printf '%s/ndk/%s' "$1" "${FAKE_NDK_VERSION}"; }

  # (p1) An SDK without the NDK gets it in one sdkmanager call, verified, with
  #      no pause and nothing charged to the budget.
  ran=$(( ran + 1 ))
  sdk="${tmp}/p1"; write_fake_sdkmanager "${sdk}" ok
  rm -f "${tmp}/sleeps"
  rc=0
  out="$(export HAVEN_BUILD_RETRY_STATE="${tmp}/p1.budget"; \
         provision_ndk "${fr}" "${sdk}" "${app}" 2>&1)" || rc=$?
  if (( rc != 0 )) || [[ "$(sdk_invocations "${sdk}")" != "1" ]] || (( $(_sleeps) != 0 )) \
     || ! ndk_verified "$(_ndk_dir "${sdk}")" "${FAKE_NDK_VERSION}" 2>/dev/null \
     || [[ -s "${tmp}/p1.budget" && "$(cat "${tmp}/p1.budget")" != "0" ]]; then
    _fail p1 "a missing NDK must be installed and verified in one call with nothing charged; got rc=${rc}, $(sdk_invocations "${sdk}") call(s), $(_sleeps) pause(s): ${out}"
  fi

  # (p2) An NDK already installed and verifying costs no sdkmanager call at all.
  ran=$(( ran + 1 ))
  sdk="${tmp}/p2"; write_fake_sdkmanager "${sdk}" ok
  write_fake_ndk "$(_ndk_dir "${sdk}")" "${FAKE_NDK_VERSION}"
  rc=0
  out="$(export HAVEN_BUILD_RETRY_STATE="${tmp}/p2.budget"; \
         provision_ndk "${fr}" "${sdk}" "${app}" 2>&1)" || rc=$?
  if (( rc != 0 )) || [[ "$(sdk_invocations "${sdk}")" != "0" ]]; then
    _fail p2 "a verified NDK must be left alone; got rc=${rc}, $(sdk_invocations "${sdk}") call(s)"
  fi

  # (p2b) …but only a COMPLETE one: a copy whose manifest and clang are there
  #       without sdkmanager's package.xml — what a kill between its last two
  #       writes leaves, and what cargokit would then reinstall unretried — is
  #       reinstalled here instead.
  ran=$(( ran + 1 ))
  sdk="${tmp}/p2b"; write_fake_sdkmanager "${sdk}" ok
  write_fake_ndk "$(_ndk_dir "${sdk}")" "${FAKE_NDK_VERSION}"
  rm -f "$(_ndk_dir "${sdk}")/package.xml"
  rc=0
  out="$(export HAVEN_BUILD_RETRY_STATE="${tmp}/p2b.budget"; \
         provision_ndk "${fr}" "${sdk}" "${app}" 2>&1)" || rc=$?
  if (( rc != 0 )) || [[ "$(sdk_invocations "${sdk}")" != "1" ]] \
     || [[ ! -f "$(_ndk_dir "${sdk}")/package.xml" ]]; then
    _fail p2b "an NDK without package.xml must be reinstalled; got rc=${rc}, $(sdk_invocations "${sdk}") call(s)"
  fi

  # (p3) Run 41546262596's failure: a truncated archive leaves the manifest
  #      without the toolchain. It is caught by the grading despite the
  #      manifest, retried after exactly one ladder pause, and the retry
  #      installs only because the download cache was cleared (the fake fails
  #      again over a kept archive). Both the attempt and the pause are charged.
  ran=$(( ran + 1 ))
  sdk="${tmp}/p3"; write_fake_sdkmanager "${sdk}" truncated
  rm -f "${tmp}/sleeps"
  rc=0
  out="$(export HAVEN_BUILD_RETRY_STATE="${tmp}/p3.budget"; \
         provision_ndk "${fr}" "${sdk}" "${app}" 2>&1)" || rc=$?
  if (( rc != 0 )) || [[ "$(sdk_invocations "${sdk}")" != "2" ]] || (( $(_sleeps) != 1 )) \
     || [[ "$(head -1 "${tmp}/sleeps" 2>/dev/null)" != "${BACKOFF_SECS[0]}" ]] \
     || (( $(cat "${tmp}/p3.budget" 2>/dev/null || echo 0) < BACKOFF_SECS[0] )) \
     || [[ -e "${sdk}/.downloadIntermediates" ]] \
     || [[ "${out}" != *"clang is missing or does not run"* ]] \
     || [[ "${out}" != *"Error reading Zip content"* ]]; then
    _fail p3 "a truncated NDK must be graded as failed, its cache cleared and the retry charged; got rc=${rc}, $(sdk_invocations "${sdk}") call(s), $(_sleeps) pause(s), budget '$(cat "${tmp}/p3.budget" 2>/dev/null)': ${out}"
  fi

  # (p4) A copy that names another revision is not the NDK asked for: it is
  #      replaced, not accepted.
  ran=$(( ran + 1 ))
  sdk="${tmp}/p4"; write_fake_sdkmanager "${sdk}" ok
  write_fake_ndk "$(_ndk_dir "${sdk}")" "27.0.12077973"
  rc=0
  out="$(export HAVEN_BUILD_RETRY_STATE="${tmp}/p4.budget"; \
         provision_ndk "${fr}" "${sdk}" "${app}" 2>&1)" || rc=$?
  if (( rc != 0 )) || [[ "$(sdk_invocations "${sdk}")" != "1" ]] \
     || ! ndk_verified "$(_ndk_dir "${sdk}")" "${FAKE_NDK_VERSION}" 2>/dev/null; then
    _fail p4 "an NDK directory naming another revision must be reinstalled; got rc=${rc}, $(sdk_invocations "${sdk}") call(s)"
  fi

  # (p5) An sdkmanager that exits 0 having installed nothing fails CLOSED, at
  #      exactly MAX_ATTEMPTS calls, with one annotation that names the version,
  #      says INFRASTRUCTURE and that no test ran.
  ran=$(( ran + 1 ))
  sdk="${tmp}/p5"; write_fake_sdkmanager "${sdk}" nothing
  rm -f "${tmp}/sleeps"
  rc=0
  out="$(export HAVEN_BUILD_RETRY_STATE="${tmp}/p5.budget"; \
         provision_ndk "${fr}" "${sdk}" "${app}" 2>&1)" || rc=$?
  if (( rc != RC_SDK_FAILED )) || [[ "$(sdk_invocations "${sdk}")" != "${MAX_ATTEMPTS}" ]] \
     || [[ "$(grep -c '::error::' <<<"${out}")" != "1" ]] \
     || [[ "${out}" != *"NDK ${FAKE_NDK_VERSION}"*"INFRASTRUCTURE"*"no test ran in this job"* ]]; then
    _fail p5 "an NDK that never lands must fail with rc ${RC_SDK_FAILED} after ${MAX_ATTEMPTS} calls and one infrastructure annotation; got rc=${rc}, $(sdk_invocations "${sdk}") call(s): ${out}"
  fi

  # (p6) A HUNG sdkmanager is killed at the attempt bound, and an attempt that
  #      took that long is not repeated: 150 s charged plus a 20 s pause plus a
  #      projected 150 s is past the budget (as is anything up to the real
  #      300 s bound). The bound is shortened by replacing
  #      ndk_attempt_secs inside this fixture's subshell only; the clock says
  #      the attempt took 150 s.
  ran=$(( ran + 1 ))
  sdk="${tmp}/p6"; write_fake_sdkmanager "${sdk}" hang
  rm -f "${tmp}/sleeps"
  rc=0
  out="$(ndk_attempt_secs() { printf '1'; }
         CLOCK_FILE="${tmp}/p6.clock"; printf '1000\n1150\n' > "${CLOCK_FILE}"
         export HAVEN_BUILD_RETRY_STATE="${tmp}/p6.budget"
         provision_ndk "${fr}" "${sdk}" "${app}" 2>&1)" || rc=$?
  if (( rc != RC_SDK_FAILED )) || [[ "$(sdk_invocations "${sdk}")" != "1" ]] || (( $(_sleeps) != 0 )) \
     || ! grep -q started "${sdk}/hang" || grep -q finished "${sdk}/hang" \
     || [[ "${out}" != *"projected at 150s"* ]]; then
    _fail p6 "a hung sdkmanager must be killed at the attempt bound and a 150 s attempt not repeated; got rc=${rc}, $(sdk_invocations "${sdk}") call(s), $(_sleeps) pause(s), hang log '$(tr '\n' ' ' < "${sdk}/hang" 2>/dev/null)': ${out}"
  fi

  # (p7) Inputs this script owns fail as BROKEN (rc ${RC_BROKEN}) before any
  #      sdkmanager call: Flutter's definition missing or ambiguous, an app that
  #      no longer takes flutter.ndkVersion, no Flutter root, no sdkmanager.
  ran=$(( ran + 1 ))
  local case_name case_fr case_app case_sdk tool
  # A PATH holding only what provision_ndk runs before its sdkmanager lookup,
  # so no sdkmanager the host happens to have can answer for the absent one.
  mkdir -p "${tmp}/p7-path"
  for tool in grep sed; do ln -sf "$(command -v "${tool}")" "${tmp}/p7-path/${tool}"; done
  for case_name in no-definition two-definitions app-pins-its-own no-flutter-root no-sdkmanager; do
    case_fr="${tmp}/p7-${case_name}-fr"; case_app="${app}"; case_sdk="${tmp}/p7-${case_name}"
    mkdir -p "${case_sdk}"
    case "${case_name}" in
      no-definition) mkdir -p "${case_fr}" ;;
      two-definitions) write_fake_flutter_root "${case_fr}" "${FAKE_NDK_VERSION}" "27.0.12077973" ;;
      app-pins-its-own)
        write_fake_flutter_root "${case_fr}" "${FAKE_NDK_VERSION}"
        case_app="${tmp}/p7-app.gradle.kts"
        printf 'android {\n    ndkVersion = "%s"\n}\n' "${FAKE_NDK_VERSION}" > "${case_app}" ;;
      no-flutter-root) case_fr="" ;;
      no-sdkmanager) write_fake_flutter_root "${case_fr}" "${FAKE_NDK_VERSION}" ;;
    esac
    [[ "${case_name}" == "no-sdkmanager" ]] || write_fake_sdkmanager "${case_sdk}" ok
    rc=0
    out="$(export PATH="${tmp}/p7-path" HAVEN_BUILD_RETRY_STATE="${tmp}/p7.budget"; \
           provision_ndk "${case_fr}" "${case_sdk}" "${case_app}" 2>&1)" || rc=$?
    if (( rc != RC_BROKEN )) || [[ "$(sdk_invocations "${case_sdk}")" != "0" ]]; then
      _fail p7 "${case_name}: must fail as broken (rc ${RC_BROKEN}) with no sdkmanager call; got rc=${rc}, $(sdk_invocations "${case_sdk}") call(s): ${out}"
    fi
  done

  # (p8) End to end on CI, as a SUBPROCESS against the REAL app build file:
  #      the script installs the Maven Central fallback init script and
  #      provisions the NDK and CMake before it builds, and an NDK that cannot
  #      be provisioned stops it with rc ${RC_SDK_FAILED} before Gradle is ever
  #      run. Reading the real file is also the live check that the app still
  #      takes flutter.ndkVersion, the one source ndk_required_version reads.
  ran=$(( ran + 1 ))
  sdk="${tmp}/p8-ok"; write_fake_sdkmanager "${sdk}" ok
  bin="${tmp}/p8-ok-bin"; write_fake_flutter "${bin}" ok
  rc=0
  out="$(PATH="${bin}:${PATH}" GITHUB_ACTIONS=true FLUTTER_ROOT="${fr}" ANDROID_HOME="${sdk}" \
         GRADLE_USER_HOME="${tmp}/p8-ok-guh" HAVEN_BUILD_RETRY_STATE="${tmp}/p8-ok.budget" \
         bash "${BASH_SOURCE[0]}" android-x64 --dart-define=HAVEN_LIVE_SYNC=false 2>&1)" || rc=$?
  if (( rc != 0 )) || [[ "$(sdk_invocations "${sdk}")" != "1" ]] || [[ "$(sdk_invocations "${sdk}" cmake-invocations)" != "1" ]] \
     || [[ "$(fake_invocations "${bin}")" != "1" ]]; then
    _fail p8 "on CI the script must provision the NDK and CMake and then build; got rc=${rc}, $(sdk_invocations "${sdk}") NDK and $(sdk_invocations "${sdk}" cmake-invocations) CMake sdkmanager call(s), $(fake_invocations "${bin}") build(s): ${out}"
  fi
  if ! cmp -s "$(dirname "${BASH_SOURCE[0]}")/maven-central-fallback.init.gradle.kts" \
       "${tmp}/p8-ok-guh/init.d/haven-maven-central-fallback.init.gradle.kts"; then
    _fail p8 "on CI the script must install the Maven Central fallback init script into GRADLE_USER_HOME/init.d before Gradle runs"
  fi
  sdk="${tmp}/p8-bad"; write_fake_sdkmanager "${sdk}" nothing
  bin="${tmp}/p8-bad-bin"; write_fake_flutter "${bin}" ok
  rc=0
  out="$(PATH="${bin}:${PATH}" GITHUB_ACTIONS=true FLUTTER_ROOT="${fr}" ANDROID_HOME="${sdk}" \
         GRADLE_USER_HOME="${tmp}/p8-bad-guh" HAVEN_BUILD_MAX_ATTEMPTS=1 HAVEN_BUILD_RETRY_STATE="${tmp}/p8-bad.budget" \
         bash "${BASH_SOURCE[0]}" android-x64 --dart-define=HAVEN_LIVE_SYNC=false 2>&1)" || rc=$?
  if (( rc != RC_SDK_FAILED )) || [[ "$(fake_invocations "${bin}")" != "0" ]]; then
    _fail p8 "on CI an NDK that cannot be provisioned must stop the script with rc ${RC_SDK_FAILED} before any build; got rc=${rc}, $(fake_invocations "${bin}") build(s): ${out}"
  fi

  # (p9) Off CI the script leaves the SDK and GRADLE_USER_HOME alone — a
  #      developer's are theirs — and builds, even with the NDK absent and an
  #      sdkmanager to hand.
  ran=$(( ran + 1 ))
  sdk="${tmp}/p9"; write_fake_sdkmanager "${sdk}" ok
  bin="${tmp}/p9-bin"; write_fake_flutter "${bin}" ok
  rc=0
  out="$(PATH="${bin}:${PATH}" GITHUB_ACTIONS= FLUTTER_ROOT="${fr}" ANDROID_HOME="${sdk}" \
         GRADLE_USER_HOME="${tmp}/p9-guh" HAVEN_BUILD_RETRY_STATE="${tmp}/p9.budget" \
         bash "${BASH_SOURCE[0]}" android-x64 --dart-define=HAVEN_LIVE_SYNC=false 2>&1)" || rc=$?
  if (( rc != 0 )) || [[ "$(sdk_invocations "${sdk}")" != "0" ]] || [[ "$(sdk_invocations "${sdk}" cmake-invocations)" != "0" ]] \
     || [[ "$(fake_invocations "${bin}")" != "1" ]]; then
    _fail p9 "off CI the script must build without touching the SDK; got rc=${rc}, $(sdk_invocations "${sdk}") NDK and $(sdk_invocations "${sdk}" cmake-invocations) CMake sdkmanager call(s), $(fake_invocations "${bin}") build(s)"
  fi
  if [[ -e "${tmp}/p9-guh/init.d" ]]; then
    _fail p9 "off CI the script must leave the developer's GRADLE_USER_HOME alone; it wrote an init.d"
  fi

  # (p10) CMake, which an offline AGP cannot install: installed and verified
  #       in one call when missing, left alone when present, refused as
  #       installed when its cmake does not run, and failing CLOSED with one
  #       INFRASTRUCTURE annotation naming it when sdkmanager installs nothing.
  ran=$(( ran + 1 ))
  sdk="${tmp}/p10"; write_fake_sdkmanager "${sdk}" ok ok
  rc=0; out="$(export HAVEN_BUILD_RETRY_STATE="${tmp}/p10.budget"; provision_cmake "${sdk}" 2>&1)" || rc=$?
  if (( rc != 0 )) || [[ "$(sdk_invocations "${sdk}" cmake-invocations)" != "1" ]] \
     || ! cmake_verified "${sdk}/cmake/${CMAKE_VERSION}" "${CMAKE_VERSION}" 2>/dev/null; then
    _fail p10 "a missing CMake must be installed and verified in one call; got rc=${rc}, $(sdk_invocations "${sdk}" cmake-invocations) call(s): ${out}"
  fi
  rc=0; out="$(export HAVEN_BUILD_RETRY_STATE="${tmp}/p10.budget"; provision_cmake "${sdk}" 2>&1)" || rc=$?
  if (( rc != 0 )) || [[ "$(sdk_invocations "${sdk}" cmake-invocations)" != "1" ]]; then
    _fail p10 "a verified CMake must be left alone; got rc=${rc}, $(sdk_invocations "${sdk}" cmake-invocations) call(s)"
  fi
  chmod -x "${sdk}/cmake/${CMAKE_VERSION}/bin/cmake"
  cmake_verified "${sdk}/cmake/${CMAKE_VERSION}" "${CMAKE_VERSION}" 2>/dev/null \
    && _fail p10 "a CMake whose cmake does not run must not grade as installed"
  sdk="${tmp}/p10-bad"; write_fake_sdkmanager "${sdk}" ok nothing
  rm -f "${tmp}/sleeps"
  rc=0; out="$(export HAVEN_BUILD_RETRY_STATE="${tmp}/p10-bad.budget"; provision_cmake "${sdk}" 2>&1)" || rc=$?
  if (( rc != RC_SDK_FAILED )) || [[ "$(sdk_invocations "${sdk}" cmake-invocations)" != "${MAX_ATTEMPTS}" ]] \
     || [[ "$(grep -c '::error::' <<<"${out}")" != "1" ]] || [[ "${out}" != *"CMake ${CMAKE_VERSION}"*"INFRASTRUCTURE"* ]]; then
    _fail p10 "a CMake that never lands must fail with rc ${RC_SDK_FAILED} after ${MAX_ATTEMPTS} calls and one annotation naming it; got rc=${rc}, $(sdk_invocations "${sdk}" cmake-invocations) call(s): ${out}"
  fi

  # (p13) Every sdkmanager call is told ANDROID_USER_HOME=$HOME/.android, so
  #       on a runner that sets XDG_CONFIG_HOME it creates no
  #       $XDG_CONFIG_HOME/.android for AGP to adopt as the debug keystore's
  #       home (CI run 45801715777: the launch gate found no keystore in
  #       ~/.android).
  ran=$(( ran + 1 ))
  sdk="${tmp}/p13"; write_fake_sdkmanager "${sdk}" ok ok
  rc=0
  out="$(export HOME="${tmp}/p13-home" XDG_CONFIG_HOME="${tmp}/p13-home/.config" HAVEN_BUILD_RETRY_STATE="${tmp}/p13.budget"
         unset ANDROID_USER_HOME
         provision_ndk "${fr}" "${sdk}" "${app}" && provision_cmake "${sdk}" 2>&1)" || rc=$?
  if (( rc != 0 )) || [[ "$(cat "${sdk}/user-home" 2>/dev/null)" != "ndk;${FAKE_NDK_VERSION} ${tmp}/p13-home/.android
cmake;${CMAKE_VERSION} ${tmp}/p13-home/.android" ]]; then
    _fail p13 "both installs must run sdkmanager with ANDROID_USER_HOME=\$HOME/.android; got rc=${rc}, '$(cat "${sdk}/user-home" 2>/dev/null)': ${out}"
  fi

  # (p11) --provision-only, scripts/build_release.sh's offline path: on CI it
  #       provisions both packages and builds nothing; off CI it touches
  #       nothing; an NDK that cannot be had is its exit code.
  ran=$(( ran + 1 ))
  sdk="${tmp}/p11"; write_fake_sdkmanager "${sdk}" ok ok
  bin="${tmp}/p11-bin"; write_fake_flutter "${bin}" ok
  rc=0
  out="$(PATH="${bin}:${PATH}" GITHUB_ACTIONS=true FLUTTER_ROOT="${fr}" ANDROID_HOME="${sdk}" HAVEN_GRADLE_OFFLINE=1 \
         GRADLE_USER_HOME="${tmp}/p11-guh" HAVEN_BUILD_RETRY_STATE="${tmp}/p11.budget" \
         bash "${BASH_SOURCE[0]}" --provision-only 2>&1)" || rc=$?
  if (( rc != 0 )) || [[ "$(sdk_invocations "${sdk}")" != "1" || "$(sdk_invocations "${sdk}" cmake-invocations)" != "1" ]] \
     || [[ "$(fake_invocations "${bin}")" != "0" ]] || [[ -e "${tmp}/p11-guh" ]]; then
    _fail p11 "--provision-only on CI must provision the NDK and CMake, build nothing and leave GRADLE_USER_HOME alone; got rc=${rc}: ${out}"
  fi
  sdk="${tmp}/p11-off"; write_fake_sdkmanager "${sdk}" ok ok
  rc=0
  (GITHUB_ACTIONS= FLUTTER_ROOT="${fr}" ANDROID_HOME="${sdk}" HAVEN_BUILD_RETRY_STATE="${tmp}/p11.budget" \
     bash "${BASH_SOURCE[0]}" --provision-only >/dev/null 2>&1) || rc=$?
  if (( rc != 0 )) || [[ "$(sdk_invocations "${sdk}")" != "0" || "$(sdk_invocations "${sdk}" cmake-invocations)" != "0" ]]; then
    _fail p11 "--provision-only off CI must touch nothing; got rc=${rc}"
  fi
  sdk="${tmp}/p11-bad"; write_fake_sdkmanager "${sdk}" nothing ok
  rc=0
  (GITHUB_ACTIONS=true FLUTTER_ROOT="${fr}" ANDROID_HOME="${sdk}" HAVEN_BUILD_MAX_ATTEMPTS=1 HAVEN_BUILD_RETRY_STATE="${tmp}/p11-bad.budget" \
     bash "${BASH_SOURCE[0]}" --provision-only >/dev/null 2>&1) || rc=$?
  if (( rc != RC_SDK_FAILED )) || [[ "$(sdk_invocations "${sdk}" cmake-invocations)" != "0" ]]; then
    _fail p11 "--provision-only must stop with rc ${RC_SDK_FAILED} at an NDK it cannot have, before CMake; got rc=${rc}"
  fi

  # (p12) scripts/build_release.sh's offline path stops before Flutter when
  #       provisioning fails, with ITS code 4 — never this script's 2 or 3,
  #       which there mean "no usable key" and "placeholder key".
  ran=$(( ran + 1 ))
  sdk="${tmp}/p12"; write_fake_sdkmanager "${sdk}" nothing ok
  bin="${tmp}/p12-bin"; write_fake_flutter "${bin}" ok
  rc=0
  out="$(PATH="${bin}:${PATH}" GITHUB_ACTIONS=true FLUTTER_ROOT="${fr}" ANDROID_HOME="${sdk}" HAVEN_GRADLE_OFFLINE=1 \
         STADIA_API_KEY=self-test-not-a-key HAVEN_BUILD_MAX_ATTEMPTS=1 HAVEN_BUILD_RETRY_STATE="${tmp}/p12.budget" \
         GRADLE_USER_HOME="${tmp}/p12-guh" bash "$(dirname "${BASH_SOURCE[0]}")/../build_release.sh" apk 2>&1)" || rc=$?
  if (( rc != 4 )) || [[ "$(fake_invocations "${bin}")" != "0" ]] || [[ "${out}" != *"could not be provisioned"* ]]; then
    _fail p12 "build_release.sh must stop with its own rc 4 before Flutter when the NDK cannot be provisioned; got rc=${rc}, $(fake_invocations "${bin}") build(s): ${out}"
  fi

  # ---- Offline (HAVEN_GRADLE_OFFLINE=1) and --resolve-only.

  # (q1) The classifier offline: Gradle's offline wording is a gap whether or
  #      not this script was asked for offline, a missing plugin marker (which
  #      offline says only "could not resolve plugin artifact") is a gap when it
  #      was and stays retriable when it was not, and a full disk still wins.
  ran=$(( ran + 1 ))
  _classifies_offline() { # <label> <expected> <HAVEN_GRADLE_OFFLINE> <sample>
    local got; got="$(HAVEN_GRADLE_OFFLINE="$3" classify "$4")"
    [[ "${got}" == "$2" ]] || _fail q1 "${1}: classified '${got}', expected '${2}'"
  }
  _classifies_offline "the MEASURED offline miss, offline" offline 1 "${MEASURED_OFFLINE_MISS_TEXT}"
  _classifies_offline "the MEASURED offline miss, even when not asked for offline" offline "" "${MEASURED_OFFLINE_MISS_TEXT}"
  _classifies_offline "a plugin marker missing offline" offline 1 "${MEASURED_PLUGIN_MARKER_TEXT}"
  _classifies_offline "the same plugin marker online" retry "" "${MEASURED_PLUGIN_MARKER_TEXT}"
  _classifies_offline "a Gradle resolution failure is a gap offline whatever status it carries" offline 1 "${MEASURED_429_TEXT}"
  # What offline Gradle cannot print, and the build still fetches: rustup's
  # target install, cargo's crate download, curl's own failed lookup. Each
  # stays retriable offline. CONSTRUCTED from rustup's, cargo's and curl's
  # wordings; no such failure is in this repo's logs.
  _classifies_offline "rustup's target install reset by its mirror, offline" retry 1 "INFO: Installing Rust target: i686-linux-android
error: could not download file from 'https://static.rust-lang.org/dist/2026-11-20/rust-std-1.97.1-i686-linux-android.tar.xz' to '/home/runner/.rustup/downloads/x.partial'
error: error decoding response body: request or response body error: Connection reset by peer (os error 104)"
  _classifies_offline "cargo's crate download timing out, offline" retry 1 "warning: spurious network error (3 tries remaining): [28] Timeout was reached (Operation timed out after 30001 milliseconds with 0 out of 0 bytes received)
error: failed to download from \`https://static.crates.io/crates/openssl-src/300.5.4+3.5.4/download\`

Caused by:
  [28] Timeout was reached (Operation timed out after 30001 milliseconds with 0 out of 0 bytes received)"
  _classifies_offline "curl's failed lookup is not Gradle's 'Could not resolve', offline" retry 1 "curl: (6) Could not resolve host: static.rust-lang.org"
  _classifies_offline "Gradle's resolution wording alone is a gap offline" offline 1 "> Could not resolve all files for configuration ':app:debugRuntimeClasspath'.
   > Could not resolve androidx.core:core:1.17.0."
  _classifies_offline "capacity WINS over an offline miss" fatal 1 "${MEASURED_OFFLINE_MISS_TEXT}
java.io.IOException: No space left on device"
  _classifies_offline "a compile error offline is still a compile error" fail 1 "e: file:///x/Main.kt:8:1 Unresolved reference: foo"

  # (q2) An offline miss through the engine: ONE invocation, no pause, nothing
  #      charged, its own rc, and one ::error:: naming the coordinate as the
  #      deps job's gap — and the plugin-marker shape names its marker.
  ran=$(( ran + 1 ))
  bin="${tmp}/q2"; write_fake_flutter "${bin}" offlinemiss
  rm -f "${tmp}/sleeps" "${tmp}/q2.budget"
  rc=0
  out="$(export PATH="${bin}:${PATH}" HAVEN_BUILD_RETRY_STATE="${tmp}/q2.budget" HAVEN_GRADLE_OFFLINE=1; \
         build_with_retry flutter build apk --debug --target-platform android-x64 2>&1)" || rc=$?
  if (( rc != 1 )) || [[ "$(fake_invocations "${bin}")" != "1" ]] || (( $(_sleeps) != 0 )) || [[ -s "${tmp}/q2.budget" ]] \
     || [[ "$(grep -c '::error::' <<<"${out}")" != "1" ]] \
     || [[ "${out}" != *"::error::"*"lacks com.android.tools.build:aapt2:9.3.1-15703166."*"deps job"*"no test ran in this job"* ]]; then
    _fail q2 "an offline miss must fail once, uncharged, with one ::error:: naming the coordinate as the deps job's gap; got rc=${rc}, $(fake_invocations "${bin}") invocation(s), $(_sleeps) pause(s): ${out}"
  fi
  out="$(HAVEN_GRADLE_OFFLINE=1 offline_error 1 "${MEASURED_PLUGIN_MARKER_TEXT}" 2>&1)"
  [[ "${out}" == *"lacks org.gradle.kotlin.kotlin-dsl:org.gradle.kotlin.kotlin-dsl.gradle.plugin:6.5.7."* ]] \
    || _fail q2 "a plugin marker missing offline must be named: ${out}"
  [[ "${out}" != *"https://"* && "${out}" != *"googleapis"* ]] \
    || _fail q2 "the offline verdict must carry coordinates only, never a URL or host: ${out}"

  # (q3) End to end: with HAVEN_GRADLE_OFFLINE=1 the offline init script, byte
  #      for byte, is in GRADLE_USER_HOME/init.d while Gradle runs and gone once
  #      the script exits, on a red build as on a green one; without it, it is
  #      never there; and any other value is refused before any build.
  ran=$(( ran + 1 ))
  local mode guh_q
  for mode in ok compile; do
    bin="${tmp}/q3-${mode}"; write_fake_flutter "${bin}" "${mode}"; guh_q="${tmp}/q3-${mode}-guh"
    rc=0
    out="$(PATH="${bin}:${PATH}" GITHUB_ACTIONS= HAVEN_GRADLE_OFFLINE=1 GRADLE_USER_HOME="${guh_q}" \
           HAVEN_BUILD_RETRY_STATE="${tmp}/q3.budget" bash "${BASH_SOURCE[0]}" android-x64 2>&1)" || rc=$?
    if [[ "$(cat "${bin}/offline.log" 2>/dev/null)" != "present" ]] \
       || ! cmp -s "${bin}/offline-seen" "$(dirname "${BASH_SOURCE[0]}")/gradle-offline.init.gradle.kts" \
       || [[ -e "${guh_q}/init.d/haven-gradle-offline.init.gradle.kts" ]]; then
      _fail q3 "${mode} build: the offline init script must be installed for the build and removed at exit; saw '$(cat "${bin}/offline.log" 2>/dev/null)', left $( [[ -e "${guh_q}/init.d/haven-gradle-offline.init.gradle.kts" ]] && echo present || echo absent ) (rc=${rc})"
    fi
  done
  bin="${tmp}/q3-online"; write_fake_flutter "${bin}" ok
  rc=0
  (PATH="${bin}:${PATH}" GITHUB_ACTIONS= GRADLE_USER_HOME="${tmp}/q3-online-guh" HAVEN_GRADLE_OFFLINE= \
     HAVEN_BUILD_RETRY_STATE="${tmp}/q3.budget" bash "${BASH_SOURCE[0]}" android-x64 >/dev/null 2>&1) || rc=$?
  if (( rc != 0 )) || [[ "$(cat "${bin}/offline.log" 2>/dev/null)" != "absent" ]]; then
    _fail q3 "without HAVEN_GRADLE_OFFLINE the build must run online; got rc=${rc}, saw '$(cat "${bin}/offline.log" 2>/dev/null)'"
  fi
  bin="${tmp}/q3-true"; write_fake_flutter "${bin}" ok
  rc=0
  out="$(PATH="${bin}:${PATH}" GITHUB_ACTIONS= GRADLE_USER_HOME="${tmp}/q3-true-guh" HAVEN_GRADLE_OFFLINE=true \
         HAVEN_BUILD_RETRY_STATE="${tmp}/q3.budget" bash "${BASH_SOURCE[0]}" android-x64 2>&1)" || rc=$?
  if (( rc != RC_BROKEN )) || [[ "$(fake_invocations "${bin}")" != "0" ]] || [[ "${out}" != *"must be 1 or empty"* ]]; then
    _fail q3 "HAVEN_GRADLE_OFFLINE=true must be refused with rc ${RC_BROKEN} before any build; got rc=${rc}, $(fake_invocations "${bin}") build(s)"
  fi

  # (q4) --resolve-only end to end, in a copy of the tree with a fake gradlew:
  #      the exact Gradle argv (--rerun-tasks, the resolve-all init script by
  #      absolute path, havenResolveAll, the aapt2 witness, the caller's extra
  #      arguments) from haven/android, the Maven Central fallback installed on
  #      CI, a transient ridden out through the engine, and offline a
  #      resolution failure is a gap that is tried once.
  ran=$(( ran + 1 ))
  local tree="${tmp}/q4-tree" tf
  mkdir -p "${tree}/scripts/ci" "${tree}/haven/android"
  for tf in build_apk_with_retry.sh gradle-resolve-all.init.gradle.kts maven-central-fallback.init.gradle.kts gradle-offline.init.gradle.kts; do
    cp "$(dirname "${BASH_SOURCE[0]}")/${tf}" "${tree}/scripts/ci/${tf}"
  done
  _fake_gradlew() { # <mode: flaky|offlinemiss|ok|testfail>
    rm -f "${tree}/haven/android/n" "${tree}/haven/android/argv.log"
    {
      printf '#!/usr/bin/env bash\n'
      printf 'printf "%%s|%%s\\n" "$PWD" "$*" >> "%s/argv.log"\n' "${tree}/haven/android"
      printf 'n=$(( $(cat "%s/n" 2>/dev/null || echo 0) + 1 )); echo "${n}" > "%s/n"\n' "${tree}/haven/android" "${tree}/haven/android"
      printf '[[ -e "${GRADLE_USER_HOME}/init.d/haven-gradle-offline.init.gradle.kts" ]] && echo present >> "%s/offline.log" || echo absent >> "%s/offline.log"\n' "${tree}/haven/android" "${tree}/haven/android"
      case "$1" in
        flaky) printf 'if (( n == 1 )); then cat <<%s\n%s\n%s\nexit 1\nfi\necho "BUILD SUCCESSFUL"\n' "'GRADLE_EOF'" "${MEASURED_PLUGIN_MARKER_TEXT}" "GRADLE_EOF" ;;
        offlinemiss) printf 'cat <<%s\n%s\n%s\nexit 1\n' "'GRADLE_EOF'" "${MEASURED_PLUGIN_MARKER_TEXT}" "GRADLE_EOF" ;;
        ok) printf 'echo "BUILD SUCCESSFUL"\n' ;;
        testfail) printf 'echo "BootResumeTest > a_refused_resume_posts_the_notice FAILED"\necho "FAILURE: Build failed with an exception."\necho "There were failing tests."\nexit 1\n' ;;
      esac
    } > "${tree}/haven/android/gradlew"
    rm -f "${tree}/haven/android/offline.log"
    chmod +x "${tree}/haven/android/gradlew"
  }
  _fake_gradlew flaky
  rm -f "${tmp}/sleeps"
  rc=0
  out="$(GITHUB_ACTIONS=true GRADLE_USER_HOME="${tmp}/q4-guh" HAVEN_BUILD_RETRY_STATE="${tmp}/q4.budget" HAVEN_GRADLE_OFFLINE= \
         bash "${tree}/scripts/ci/build_apk_with_retry.sh" --resolve-only --info 2>&1)" || rc=$?
  local want_argv="${tree}/haven/android|--continue --rerun-tasks -I ${tree}/scripts/ci/gradle-resolve-all.init.gradle.kts havenResolveAll :app:compileDebugNavigationResources --info"
  if (( rc != 0 )) || [[ "$(cat "${tree}/haven/android/n")" != "2" ]] \
     || [[ "$(sort -u "${tree}/haven/android/argv.log")" != "${want_argv}" ]] \
     || ! cmp -s "${tree}/scripts/ci/maven-central-fallback.init.gradle.kts" "${tmp}/q4-guh/init.d/haven-maven-central-fallback.init.gradle.kts"; then
    _fail q4 "--resolve-only must run '${want_argv}' through the retry engine with the Central fallback installed; got rc=${rc}, argv '$(sort -u "${tree}/haven/android/argv.log" 2>/dev/null)', $(cat "${tree}/haven/android/n" 2>/dev/null) run(s): ${out}"
  fi
  _fake_gradlew offlinemiss
  rc=0
  out="$(GITHUB_ACTIONS= GRADLE_USER_HOME="${tmp}/q4-off-guh" HAVEN_BUILD_RETRY_STATE="${tmp}/q4-off.budget" HAVEN_GRADLE_OFFLINE=1 \
         bash "${tree}/scripts/ci/build_apk_with_retry.sh" --resolve-only 2>&1)" || rc=$?
  if (( rc != 1 )) || [[ "$(cat "${tree}/haven/android/n")" != "1" ]] || [[ "${out}" != *"::error::Gradle built OFFLINE"* ]] \
     || [[ -e "${tmp}/q4-off-guh/init.d/haven-gradle-offline.init.gradle.kts" ]]; then
    _fail q4 "an offline --resolve-only that misses a marker must run once, say it is the set's gap and leave no offline init behind; got rc=${rc}, $(cat "${tree}/haven/android/n" 2>/dev/null) run(s): ${out}"
  fi

  # (q5) --gradle-task end to end (build-check.yml's JVM unit tests), in q4's
  #      tree: on CI the NDK and CMake are provisioned and the Central fallback
  #      installed first, then exactly `<task> <extra> -Ptarget-platform=<p>`
  #      runs from haven/android, once;
  #      offline the init script is there for the task and gone after it, and
  #      a resolution failure is the set's gap, tried once; a failing test is
  #      a genuine failure, tried once; a task line missing is refused.
  ran=$(( ran + 1 ))
  mkdir -p "${tree}/haven/android/app"
  cp "$(dirname "${BASH_SOURCE[0]}")/../../haven/android/app/build.gradle.kts" "${tree}/haven/android/app/build.gradle.kts"
  sdk="${tmp}/q5-sdk"; write_fake_sdkmanager "${sdk}" ok ok
  _fake_gradlew ok
  rc=0
  out="$(GITHUB_ACTIONS=true FLUTTER_ROOT="${fr}" ANDROID_HOME="${sdk}" GRADLE_USER_HOME="${tmp}/q5-guh" \
         HAVEN_BUILD_RETRY_STATE="${tmp}/q5.budget" HAVEN_GRADLE_OFFLINE= \
         bash "${tree}/scripts/ci/build_apk_with_retry.sh" --gradle-task android-arm64 :app:testDebugUnitTest --info 2>&1)" || rc=$?
  want_argv="${tree}/haven/android|:app:testDebugUnitTest --info -Ptarget-platform=android-arm64"
  if (( rc != 0 )) || [[ "$(cat "${tree}/haven/android/n")" != "1" ]] \
     || [[ "$(cat "${tree}/haven/android/argv.log")" != "${want_argv}" ]] || [[ "$(cat "${tree}/haven/android/offline.log")" != "absent" ]] \
     || [[ "$(sdk_invocations "${sdk}")" != "1" || "$(sdk_invocations "${sdk}" cmake-invocations)" != "1" ]] \
     || ! cmp -s "${tree}/scripts/ci/maven-central-fallback.init.gradle.kts" "${tmp}/q5-guh/init.d/haven-maven-central-fallback.init.gradle.kts"; then
    _fail q5 "--gradle-task on CI must provision, install the Central fallback and run '${want_argv}' once, online; got rc=${rc}, argv '$(sort -u "${tree}/haven/android/argv.log" 2>/dev/null)', $(cat "${tree}/haven/android/n" 2>/dev/null) run(s), sdkmanager $(sdk_invocations "${sdk}")+$(sdk_invocations "${sdk}" cmake-invocations): ${out}"
  fi
  _fake_gradlew offlinemiss
  rc=0
  out="$(GITHUB_ACTIONS= GRADLE_USER_HOME="${tmp}/q5-off-guh" HAVEN_BUILD_RETRY_STATE="${tmp}/q5-off.budget" HAVEN_GRADLE_OFFLINE=1 \
         bash "${tree}/scripts/ci/build_apk_with_retry.sh" --gradle-task android-arm64 :app:testDebugUnitTest 2>&1)" || rc=$?
  if (( rc != 1 )) || [[ "$(cat "${tree}/haven/android/n")" != "1" ]] || [[ "$(cat "${tree}/haven/android/offline.log")" != "present" ]] \
     || [[ "${out}" != *"::error::Gradle built OFFLINE"* ]] || [[ -e "${tmp}/q5-off-guh/init.d/haven-gradle-offline.init.gradle.kts" ]]; then
    _fail q5 "an offline --gradle-task must run with the offline init script, try a gap once and remove the script; got rc=${rc}, $(cat "${tree}/haven/android/n" 2>/dev/null) run(s), offline '$(cat "${tree}/haven/android/offline.log" 2>/dev/null)': ${out}"
  fi
  _fake_gradlew testfail
  rc=0
  out="$(GITHUB_ACTIONS= GRADLE_USER_HOME="${tmp}/q5-t-guh" HAVEN_BUILD_RETRY_STATE="${tmp}/q5-t.budget" HAVEN_GRADLE_OFFLINE=1 \
         bash "${tree}/scripts/ci/build_apk_with_retry.sh" --gradle-task android-arm64 :app:testDebugUnitTest 2>&1)" || rc=$?
  if (( rc != 1 )) || [[ "$(cat "${tree}/haven/android/n")" != "1" ]] || [[ "${out}" == *"::error::"* || "${out}" != *"genuine build failure"* ]]; then
    _fail q5 "a failing unit test must fail once with its own rc, judged genuine, with no infrastructure verdict; got rc=${rc}, $(cat "${tree}/haven/android/n" 2>/dev/null) run(s): ${out}"
  fi
  _fake_gradlew ok
  rc=0
  (GITHUB_ACTIONS= HAVEN_BUILD_RETRY_STATE="${tmp}/q5-u.budget" \
     bash "${tree}/scripts/ci/build_apk_with_retry.sh" --gradle-task android-arm64 >/dev/null 2>&1) || rc=$?
  if (( rc != RC_BROKEN )) || [[ -e "${tree}/haven/android/n" ]]; then
    _fail q5 "--gradle-task without a task must be refused with rc ${RC_BROKEN} before Gradle; got rc=${rc}"
  fi

  # (h2) Past the ladder every pause is its last step, so a caller that asks
  #      for more attempts never indexes past it (an unbound variable under
  #      `set -u`, which would end the run on its fourth failure).
  ran=$(( ran + 1 ))
  local pauses="" a
  for a in 1 2 3 4 5 11; do pauses+="$(backoff_for "${a}") "; done
  [[ "${pauses}" == "20 45 75 75 75 75 " ]] || _fail h2 "pauses after attempts 1-5 and 11 must be 20 45 75 75 75 75; got '${pauses}'"

  # (h) Structural: one backoff per pause, and the header's worst case is the
  #     one the constants actually add up to. Both are claims the prose above
  #     makes, and neither is visible in any single fixture.
  ran=$(( ran + 1 ))
  local ladder_sum=0 s
  for s in "${BACKOFF_SECS[@]}"; do ladder_sum=$(( ladder_sum + s )); done
  if (( ${#BACKOFF_SECS[@]} != MAX_ATTEMPTS - 1 )); then
    _fail h "${#BACKOFF_SECS[@]} backoff(s) for ${MAX_ATTEMPTS} attempt(s); there must be exactly one per pause"
  elif (( ladder_sum > RETRY_BUDGET_SECS )); then
    _fail h "the ladder sums to ${ladder_sum}s, over the ${RETRY_BUDGET_SECS}s budget: the last pause could never be taken, so the attempt count overstates what this script does"
  fi

  if (( failures )); then
    echo "${SCRIPT_NAME}: SELF-TEST FAILED" >&2
    return 1
  fi
  if (( ran != SELF_TEST_FIXTURES )); then
    echo "${SCRIPT_NAME}: SELF-TEST FAILED — ran ${ran} fixture(s), expected exactly ${SELF_TEST_FIXTURES}; a fixture was added or removed without moving the pin" >&2
    return 1
  fi
  echo "${SCRIPT_NAME}: self-test passed (${ran}/${SELF_TEST_FIXTURES} fixtures: a transient 429 is ridden out on the second attempt after exactly one ladder pause, and so is the wrapper's 504 fetching the Gradle distribution, and the fake proves it refuses both a non-build argv and a build missing the flags this script adds; a compile error and a disk exhaustion each fail once with their own exit code, their original output and the right verdict; a persistent 429 stops at exactly ${MAX_ATTEMPTS} attempts with one ::error:: saying INFRASTRUCTURE and that no test ran, the Gradle error still shown; a budget spent by an earlier build in the step starts no further attempt, and a retried build charges the shared budget while a clean one charges nothing; an attempt long enough that repeating it would not fit the budget is never started, while a short one under the same injected clock still is; every retriable signature is load-bearing on its own, this repo's real wrapped 403 is retried while a bare status line decides nothing, a plugin marker Gradle reports missing is retried while a version-less plugin request is not, the wrapper's distribution download is retried on a 5xx but not on a 404, a checksum mismatch or another URL, and a capacity signature beats a resolution one; the annotation names a rate limit only where a 429 says so, names a failed distribution download with its status, names the missing-coordinate shape as the ambiguity it is without reprinting the coordinate, and otherwise admits the cause is not knowable; a spent budget left by another run is not read; the script itself issues the build argv the lanes depend on; on CI the NDK Flutter asks for is installed in one call when missing, left alone when present and complete and reinstalled when its package.xml is missing, a truncated install is graded failed despite its manifest, its download cache cleared and the charged retry installs it, another revision is replaced, a yes-machine sdkmanager fails closed at ${MAX_ATTEMPTS} calls with one INFRASTRUCTURE annotation, a hung one is killed at the attempt bound and not repeated past the budget, and every input this script owns fails as broken before any call; end to end the script installs the Maven Central fallback init script and provisions before it builds against the real app build file, stops before Gradle when the NDK cannot be had, and off CI never touches the SDK or GRADLE_USER_HOME; CMake, which an offline AGP cannot install, is provisioned too — installed when missing, left alone when present, refused when its cmake does not run, failing closed with one annotation naming it — and --provision-only provisions both on CI, builds nothing and touches nothing off CI, and build_release.sh turns its failure into its own rc 4; every sdkmanager call runs with ANDROID_USER_HOME=\$HOME/.android, so none creates the XDG folder AGP would keep its debug keystore in; offline, Gradle's offline wording is a gap and so is every Gradle resolution wording (a missing plugin marker says nothing about offline), while rustup's reset, cargo's curl timeout and curl's failed lookup stay retriable, capacity still wins and a compile error stays one, a gap is tried once and uncharged with one ::error:: naming the coordinate (or marker) as the deps job's and no URL, the offline init script is in init.d for exactly the build and gone after it on a red build as on a green one, absent without HAVEN_GRADLE_OFFLINE, and any value but 1 is refused before a build; --resolve-only runs havenResolveAll and the aapt2 witness from haven/android through the engine with the Central fallback installed, and offline tries a gap once; --gradle-task provisions on CI and runs exactly its task line with -Ptarget-platform from haven/android through the engine, online without the offline init script, offline with the init script for exactly the task, a gap and a failing test each tried once, and a missing task line refused; one backoff per pause, the ladder fits the budget, and more attempts than the ladder repeat its last pause)."
  return 0
}

if [[ "${1:-}" == "--self-test" && $# -eq 1 ]]; then
  run_self_test
  exit $?
fi

if [[ $# -lt 1 ]]; then
  err "usage: ${SCRIPT_NAME} <flutter-target-platform> [extra flutter args...]"
  err "       ${SCRIPT_NAME} --resolve-only [extra gradle args...]"
  err "       ${SCRIPT_NAME} --gradle-task <flutter-target-platform> <task> [extra gradle args...]"
  err "       ${SCRIPT_NAME} --provision-only"
  err "       ${SCRIPT_NAME} --self-test"
  exit "${RC_BROKEN}"
fi

# scripts/build_release.sh's offline path: the SDK packages an offline AGP
# cannot install, and nothing else: no Gradle runs, so it ignores
# HAVEN_GRADLE_OFFLINE and never touches init.d.
if [[ "$1" == "--provision-only" && $# -eq 1 ]]; then
  if [[ "${GITHUB_ACTIONS:-}" == "true" ]]; then
    provision_sdk
  fi
  exit $?
fi

case "${HAVEN_GRADLE_OFFLINE:-}" in
  '') ;;
  1) install_offline; trap remove_offline EXIT ;;
  *) printf '::error::HAVEN_GRADLE_OFFLINE must be 1 or empty, not "%s" — refusing to guess whether this build may reach the network.\n' "${HAVEN_GRADLE_OFFLINE}" >&2
     exit "${RC_BROKEN}" ;;
esac

if [[ "$1" == "--resolve-only" ]]; then
  shift
  if [[ "${GITHUB_ACTIONS:-}" == "true" ]]; then
    install_central_fallback
  fi
  resolve_rc=0
  resolve_init="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/gradle-resolve-all.init.gradle.kts"
  cd "$(dirname "${resolve_init}")/../../haven/android"
  build_with_retry ./gradlew --continue --rerun-tasks -I "${resolve_init}" \
    havenResolveAll :app:compileDebugNavigationResources "$@" || resolve_rc=$?
  exit "${resolve_rc}"
fi

gradle_task=0
if [[ "$1" == "--gradle-task" ]]; then
  if [[ $# -lt 3 ]]; then
    err "usage: ${SCRIPT_NAME} --gradle-task <flutter-target-platform> <task> [extra gradle args...]"
    exit "${RC_BROKEN}"
  fi
  gradle_task=1
  shift
fi

readonly TARGET_PLATFORM="$1"
shift

if [[ "${GITHUB_ACTIONS:-}" == "true" ]]; then
  install_central_fallback
  sdk_rc=0
  provision_sdk || sdk_rc=$?
  if (( sdk_rc != 0 )); then
    exit "${sdk_rc}"
  fi
fi

build_rc=0
if (( gradle_task )); then
  cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/../../haven/android" && pwd)"
  build_with_retry ./gradlew "$@" "-Ptarget-platform=${TARGET_PLATFORM}" || build_rc=$?
else
  build_with_retry flutter build apk --debug --target-platform "${TARGET_PLATFORM}" "$@" || build_rc=$?
fi
exit "${build_rc}"
