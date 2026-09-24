#!/usr/bin/env bash
#
# `flutter build apk` with a CLASSIFIED, BUDGETED retry. The ONE build site
# every Gradle-backed lane goes through.
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
# ## Why the CACHE is the fix and this is only the backstop
#
# Read this before raising the attempt count. A cold `~/.gradle/caches` makes a
# lane fetch hundreds of POMs; a warm one makes Gradle resolve fixed versions
# from disk and issue no request at all. Removing the requests beats retrying
# them, which is why every Gradle-building job restores a Gradle dependency
# cache (`scripts/ci/check_gradle_build_hardened.sh` C1 keeps it that way) and
# why the budget below is deliberately small.
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
# into a message that says INFRASTRUCTURE. The cache is what removes the class.
#
# What the cache does NOT buy is time. A job's first `assembleDebug` takes
# 429-638 s with the dependency cache HIT (run 35813757227) and 33-61 s for its
# later builds; that gap is Gradle configuration, cargokit's Rust cross-compiles
# (x86_64 and i686 Android targets) and the Kotlin compile, which live outside
# `~/.gradle/caches/modules-2`. The cache's whole product is that the classpath
# resolves from disk and issues no request that can draw the limit — four
# cached jobs, zero 429s.
#
# ## Gradle's OWN retry, and why it is not enough (VERIFIED, 8.14)
#
# Gradle 8.14 does retry 429 — in `NetworkingIssueVerifier.isLikelyTransient
# NetworkingIssue` (429 and 408 are the only retriable client errors; 401/403
# are explicitly NOT retried), driven by the loop in `ErrorHandlingModule
# ComponentRepository`. But its defaults are 3 TOTAL attempts with a backoff of
# 1000 ms doubling once: ~3 s of waiting before the failure is final. That is
# why the MEASURED attempts above died in 16-44 s. `haven/android/gradle.
# properties` widens that window via the two properties that genuinely exist in
# 8.14 — `org.gradle.internal.repository.max.tentatives` (TOTAL attempts,
# default 3) and `org.gradle.internal.repository.initial.backoff` (ms, default
# 1000, doubling).
#
# Do NOT cite `org.gradle.internal.repository.max.retries`: it does not exist in
# Gradle, at 8.14 or anywhere (no hit in the shipped distribution's jars or in
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
# per-JOB — and every lane has exactly ONE Gradle build step, so job-scoped and
# step-scoped coincide here. That is what makes the worst case below a property
# of the STEP that `check_e2e_step_timeout_ordering.sh` grades.
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
# On the path that ends RED the final attempt is a failure rather than a build,
# so the same bound holds with that failure standing in for the last build. A
# single Gradle invocation is bounded by the step's own `timeout-minutes` and by
# nothing here — exactly as it would be with no retry machinery at all.
#
# Against the MEASURED build times of CI run 35622556197 and the step caps in
# force:
#
#   e2e-flakiness-stress  B = 16.9 min (worst of 96 runs)  -> 19.9 < cap 22
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
# these. Shrink the budget before you grow it: e2e-flakiness-stress's step cap
# is 22 and its JOB cap is already GitHub's 360-minute ceiling, so that lane
# cannot fund a bigger one, and the other job caps clear their step caps by only
# 3-6 minutes (check_e2e_step_timeout_ordering.sh C6).
#
# Usage:
#   scripts/ci/build_apk_with_retry.sh <flutter-target-platform> [extra flutter args...]
#   scripts/ci/build_apk_with_retry.sh --self-test
#
# Env:
#   HAVEN_BUILD_MAX_ATTEMPTS       default 4
#   HAVEN_BUILD_RETRY_BUDGET_SECS  default 180
#   HAVEN_BUILD_RETRY_STATE        budget state file; default under RUNNER_TEMP,
#                                  named per GITHUB_RUN_ID (per PID off CI)
#
# Exit codes:
#   0  the APK built (on some attempt)
#   *  the build's own exit code, unchanged — a retry never rewrites it
#   2  wrong arguments, or the self-test failed

set -euo pipefail

readonly SCRIPT_NAME="build_apk_with_retry.sh"
readonly MAX_ATTEMPTS="${HAVEN_BUILD_MAX_ATTEMPTS:-4}"
readonly RETRY_BUDGET_SECS="${HAVEN_BUILD_RETRY_BUDGET_SECS:-180}"

# One entry per PAUSE, i.e. exactly MAX_ATTEMPTS-1 of them; fixture (h) pins
# that. Fixed steps, no jitter: a deterministic schedule is one a worst case can
# be computed from, and jitter buys nothing when the contended resource is a
# per-IP rate limiter rather than a thundering herd of our own making.
readonly BACKOFF_SECS=(20 45 75)

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
#   UNMEASURED "Read timed out", "Connection reset", "Connection timed out",
#              "Could not HEAD", "Could not download", and the 408/5xx codes:
#              never seen in this repo's logs. They are Gradle's own transient
#              class (VERIFIED in 8.14's NetworkingIssueVerifier, which retries
#              408, 429 and every 5xx), kept so the first occurrence is ridden
#              out rather than discovered.
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
readonly RETRIABLE_RE='Could not (GET|HEAD|resolve|download|get resource)|Could not parse POM|Error resolving plugin|downloading artifacts from the network|Read timed out|Connection (reset|timed out)|status code (408|429|5[0-9][0-9])|Could not resolve all (artifacts|dependencies|files)'

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

# classify <text> -> fatal | retry | fail
#
# The text is passed as a value, never piped in: under `pipefail` a
# `producer | grep -q` fails OPEN when grep exits early on its first match, and
# "fails open" here means classifying a capacity failure as retriable.
classify() {
  if grep -qE "${FATAL_RE}" <<<"$1"; then printf 'fatal'
  elif grep -qE "${RETRIABLE_RE}" <<<"$1"; then printf 'retry'
  else printf 'fail'; fi
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
# reader to re-run instead of to the diff. So: three wordings, each as specific
# as its evidence allows, and never the coordinate itself — Gradle's own output
# is above, unaltered, and already has it (Rule 15: an annotation is a log sink).
infra_error() { # $1 attempts, $2 rc, $3 the captured build output
  local why
  if grep -q 'status code 429' <<<"$3"; then
    why="a repository rate-limited this runner (HTTP 429). That is INFRASTRUCTURE, not a product failure — the limit follows the shared runner egress IP, not this commit. A re-run on a different runner is the remedy; a recurrence means the Gradle dependency cache is not being restored"
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
    backoff="${BACKOFF_SECS[attempt - 1]}"
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
# Self-test: hermetic. A fake `flutter` on PATH, no network, no real waiting.
# ---------------------------------------------------------------------------
readonly SELF_TEST_FIXTURES=16

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
      compile)
        printf 'echo "lib/src/main.dart:12:3: Error: Expected %s;%s after this."\nexit 1\n' "'" "'"
        ;;
      disk)
        printf 'echo "java.io.IOException: No space left on device"\nexit 1\n'
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
  _classifies "bare 503 status line" retry \
    "> Received status code 503 from server: Service Unavailable"
  _classifies "bare failed GET" retry \
    "> Could not GET 'https://repo.maven.apache.org/maven2/x/y/1.0/y-1.0.pom'."
  _classifies "bare unparseable POM" retry \
    "> Could not parse POM https://plugins.gradle.org/m2/x/y/1.0/y-1.0.pom"
  _classifies "socket read timeout" retry \
    "Caused by: java.net.SocketTimeoutException: Read timed out"
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
  out="$(PATH="${bin}:${PATH}" HAVEN_BUILD_RETRY_STATE="${tmp}/j.budget" \
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

  # (m) The annotation says only what the output entitles it to say. Three
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
  _annotation "a timeout with no status admits it cannot know" \
    "> Could not resolve all files for configuration ':app:debugRuntimeClasspath'.
Caused by: java.net.SocketTimeoutException: Read timed out" \
    "not knowable from here" "429"

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
  echo "${SCRIPT_NAME}: self-test passed (${ran}/${SELF_TEST_FIXTURES} fixtures: a transient 429 is ridden out on the second attempt after exactly one ladder pause, and the fake proves it refuses both a non-build argv and a build missing the flags this script adds; a compile error and a disk exhaustion each fail once with their own exit code, their original output and the right verdict; a persistent 429 stops at exactly ${MAX_ATTEMPTS} attempts with one ::error:: saying INFRASTRUCTURE and that no test ran, the Gradle error still shown; a budget spent by an earlier build in the step starts no further attempt, and a retried build charges the shared budget while a clean one charges nothing; an attempt long enough that repeating it would not fit the budget is never started, while a short one under the same injected clock still is; every retriable signature is load-bearing on its own, this repo's real wrapped 403 is retried while a bare status line decides nothing, and a capacity signature beats a resolution one; the annotation names a rate limit only where a 429 says so, names the missing-coordinate shape as the ambiguity it is without reprinting the coordinate, and otherwise admits the cause is not knowable; a spent budget left by another run is not read; the script itself issues the build argv the lanes depend on; one backoff per pause, and the ladder fits the budget)."
  return 0
}

if [[ "${1:-}" == "--self-test" && $# -eq 1 ]]; then
  run_self_test
  exit $?
fi

if [[ $# -lt 1 ]]; then
  err "usage: ${SCRIPT_NAME} <flutter-target-platform> [extra flutter args...]"
  err "       ${SCRIPT_NAME} --self-test"
  exit "${RC_BROKEN}"
fi

readonly TARGET_PLATFORM="$1"
shift

build_rc=0
build_with_retry flutter build apk --debug --target-platform "${TARGET_PLATFORM}" "$@" || build_rc=$?
exit "${build_rc}"
