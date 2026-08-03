#!/usr/bin/env bash
# CI guard: every app build must DECLARE its receive path.
#
# `haven/lib/src/providers/live_sync_provider.dart`:
#
#   const liveSyncEnabled = bool.fromEnvironment(
#     'HAVEN_LIVE_SYNC',
#     defaultValue: true,
#   );
#
# The default is `true` (M11 Phase B), and the value is a COMPILE-TIME const
# baked into the artifact — `flutter drive` does not re-pass dart-defines, so
# whatever the build step decided is what the whole lane runs. Together those
# two facts mean a build that omits `--dart-define=HAVEN_LIVE_SYNC` does not
# produce an "unset" or "neutral" build. It produces a LIVE-SYNC build, chosen
# by nobody, under whatever name the lane happens to carry.
#
# That is not hypothetical. `e2e-flakiness-stress.yml` inherited `true` from the
# Phase-B flip and spent months running the ten M11 live-sync scenarios inside a
# budget derived from the poll path (a 20-minute per-iteration DRIVE_TIMEOUT
# against a suite e2e-android.yml gives 28 minutes), failing most nights on
# `[MapShell] live-sync start error` while its header still said it mirrored the
# poll lane. `e2e-profile.yml` was worse-shaped: its Android job inherited Dart's
# default (live) while its iOS job took run-ios-sim-scenario.sh's default (poll),
# so ONE lane ran ONE scenario file on TWO receive paths, and no file in the repo
# stated either. Both are CI_HARDENING_BACKLOG.md A7.
#
# This guard makes the mode un-inheritable: not "pass the define everywhere",
# but "no job may build the app without an answer on the record".
#
# # Checks
#
#   1. Workflow jobs. For every job in .github/workflows/*.yml that invokes an
#      app build, the job block must declare HAVEN_LIVE_SYNC with a value —
#      `--dart-define=HAVEN_LIVE_SYNC=<v>`, an `env:` entry, or a shell
#      assignment — or carry the production-default intent token (below).
#
#   2. Build scripts. Every checked-in script that compiles the app must emit
#      `--dart-define=HAVEN_LIVE_SYNC` on its build command line. Check 1 alone
#      is not enough: the three lanes that build through
#      build-integration-apks.sh would keep "declaring" the value in YAML while
#      the funnel quietly stopped forwarding it.
#
# # The production-default intent token
#
# build-check.yml and release-build.yml deliberately pass NO define, because
# they build the artifact that SHIPS, and the shipped artifact's receive path
# has to come from `defaultValue` — that const is the documented one-line
# rollback lever (docs/M11_ROLLOUT.md §8, pinned by check 14b of
# check_m7_native_wake_guards.sh). A literal define in those workflows would
# outrank it: flipping the default back to `false` would change production while
# CI kept building and blessing the abandoned path. So they declare the decision
# instead of the value, with the token
#
#   HAVEN_LIVE_SYNC-INTENT: production-default
#
# and the ALLOWLIST below names the only two files where that token counts. A
# new lane cannot reach for it without editing this script — which is the point:
# the escape hatch is a reviewable act, not an omission.
#
# # Scope: builds, not host tests
#
# The subject is app BUILD sites (`flutter build apk|ios|ipa|appbundle`, and
# `flutter test <integration_test/...>` which builds+installs+drives on iOS).
# The host `flutter test` suite in coverage.yml is deliberately OUT of scope and
# deliberately passes no define: it is the only place `live_sync_provider_test`'s
# "defaults ON" assertion can observe the compiled default, and forcing a define
# there would turn that proof into a tautology.
#
# There is no build-time/drive-time split to police in this repo. Android bakes
# at build and drives a fixed APK; iOS builds and drives in one `flutter test`.
# A drive step cannot set the value, so requiring it there would be theatre.
#
# Pure grep/bash, no toolchain — belongs in repo-guards.yml.
#
# Usage:
#   check_live_sync_define_declared.sh            # check the repo
#   check_live_sync_define_declared.sh --self-test
#
# Exit codes:
#   0  all checks pass
#   1  a job builds the app without declaring the receive path, or a build
#      script stopped emitting the define
#   2  expected paths missing / self-test failed (the guard itself is broken)

set -euo pipefail

SCRIPT_NAME="check_live_sync_define_declared"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

log() { printf '\033[1;34m[%s]\033[0m %s\n' "${SCRIPT_NAME}" "$*"; }
fail_msg() { printf '\033[1;31m[%s] FAIL:\033[0m %s\n' "${SCRIPT_NAME}" "$*" >&2; }
misconfig() { printf '\033[1;31m[%s] ERROR:\033[0m %s\n' "${SCRIPT_NAME}" "$*" >&2; exit 2; }

# ---------------------------------------------------------------------------
# Patterns
# ---------------------------------------------------------------------------

# An app BUILD. Either a direct flutter invocation, or a call to one of the
# checked-in wrappers that performs one. `flutter test` counts ONLY when it
# names an integration_test target: that form builds and installs a real app
# (the iOS lanes' whole execution model), whereas a bare `flutter test` is the
# host suite.
#
# The wrapper names are listed literally rather than matched loosely so that a
# renamed or newly added wrapper shows up as an unrecognised build site in
# check 2's inventory instead of silently escaping check 1.
readonly BUILD_RE='flutter build (apk|ios|ipa|appbundle)|flutter test [^|&]*integration_test/|build-integration-apks\.sh|run-ios-sim-scenario\.sh|build_apk_with_retry\.sh|build_release\.sh'

# A DECLARATION of the value: `--dart-define=HAVEN_LIVE_SYNC=x`, a YAML
# `HAVEN_LIVE_SYNC: x` env entry, or a shell `HAVEN_LIVE_SYNC=x`.
#
# The trailing value is REQUIRED. Without it this would match prose — e2e-android
# .yml's own input description reads "Build e2e_combined with
# --dart-define=HAVEN_LIVE_SYNC. true exercises ...", and a lane that documents
# the flag while forgetting to pass it is precisely the failure being guarded.
readonly DECL_RE='HAVEN_LIVE_SYNC[:=][[:space:]]*("|'"'"')?(true|false|\$\{)'

# The sanctioned "compile the shipped default" declaration.
readonly INTENT_TOKEN='HAVEN_LIVE_SYNC-INTENT: production-default'

# Files where INTENT_TOKEN is honoured. Everything else must pass a value.
readonly INTENT_ALLOWLIST=(
  "build-check.yml"
  "release-build.yml"
)

# Lines that name a build command without performing one. Both classes are
# present in this repo and both produced false positives on the first run:
#
#   comments      rust-check.yml explains that a Rust change can break the
#                 "build (cargokit / build_release.sh)" — prose, not a build.
#                 Comments are stripped before matching BOTH the build pattern
#                 and the declaration pattern, so a job cannot satisfy the guard
#                 by DESCRIBING a value it never passes either.
#   --self-test   repo-guards.yml runs `build_apk_with_retry.sh --self-test`,
#                 which exercises the retry predicate against fixtures and never
#                 invokes Flutter.
#
# The intent token lives in a comment by construction, so it is matched against
# the RAW block, never this filtered view.
_code_only() {
  grep -vE '^[[:space:]]*#' | grep -vF -- '--self-test'
}

# Scripts that build the app and must forward the define. Value = the reason a
# script is exempt, or the empty string when it must emit the define.
#
# Exemptions are narrow and structural, never "this one is fine":
#   build_apk_with_retry.sh  a transparent `"$@"` pass-through around
#                            `flutter build apk`; it adds no defines of its own,
#                            so its CALLER is the declaring party (build-check
#                            .yml, via the intent token).
#   build_release.sh         builds the shipped artifact, which by design takes
#                            live_sync_provider.dart's defaultValue — see the
#                            production-default note above.
readonly BUILD_SCRIPT_EXEMPT_RE='scripts/ci/build_apk_with_retry\.sh$|scripts/build_release\.sh$'

# ---------------------------------------------------------------------------
# Check 1 — every workflow job that builds the app declares the receive path.
#
# Job-scoped, not file-scoped: e2e-profile.yml is the reason. Its two jobs build
# the same scenario on two platforms, and a file-level check would let one
# declare while the other inherited — which is the exact defect that shipped.
#
# Scoping is by indentation. Under `jobs:` every job key sits at exactly two
# spaces and everything belonging to it is indented further, which is uniform
# across this repo's workflows. A job-level `env:` therefore lands inside its own
# block and correctly covers all of that job's steps (the e2e-fgs-publish
# pattern), while a sibling job's declaration cannot leak across.
# ---------------------------------------------------------------------------
check_workflows() {
  local wf_dir="$1" rc=0
  local file base in_jobs job_start job_name

  while IFS= read -r file; do
    base="$(basename "${file}")"

    # Split the file into job blocks and test each independently.
    # awk emits: <job-name>\t<start-line>\t<end-line>
    while IFS=$'\t' read -r job_name job_start job_end; do
      local block code
      block="$(sed -n "${job_start},${job_end}p" "${file}")"
      code="$(_code_only <<<"${block}" || true)"

      grep -qE "${BUILD_RE}" <<<"${code}" || continue

      if grep -qE "${DECL_RE}" <<<"${code}"; then
        continue
      fi

      if grep -qF "${INTENT_TOKEN}" <<<"${block}"; then
        local allowed=0 allow
        for allow in "${INTENT_ALLOWLIST[@]}"; do
          [[ "${base}" == "${allow}" ]] && allowed=1
        done
        if (( allowed )); then
          continue
        fi
        fail_msg "${base} job '${job_name}' uses the production-default intent token, but only ${INTENT_ALLOWLIST[*]} may — that token means 'this job builds the artifact users install'. A test lane must pass an explicit --dart-define=HAVEN_LIVE_SYNC=true|false instead."
        rc=1
        continue
      fi

      fail_msg "${base} job '${job_name}' (lines ${job_start}-${job_end}) builds the app but never declares HAVEN_LIVE_SYNC. Omitting the define does not build 'neutral' — liveSyncEnabled is bool.fromEnvironment('HAVEN_LIVE_SYNC', defaultValue: true), so this job silently compiles the live-sync engine ON whatever its name says. Add HAVEN_LIVE_SYNC: \"true\"|\"false\" to the job env (and bake it with --dart-define at the build step)."
      rc=1
    done < <(
      awk '
        # Track the start of the top-level `jobs:` mapping.
        /^jobs:[[:space:]]*$/ { in_jobs = 1; next }
        # A new top-level key ends the jobs mapping.
        in_jobs && /^[^[:space:]#]/ { if (name != "") { print name "\t" start "\t" NR - 1 }; in_jobs = 0; name = ""; next }
        # A job key: exactly two spaces, then an identifier and a colon.
        in_jobs && /^  [A-Za-z_][A-Za-z0-9_-]*:[[:space:]]*$/ {
          if (name != "") { print name "\t" start "\t" NR - 1 }
          name = $1; sub(/:$/, "", name); start = NR; next
        }
        END { if (name != "") { print name "\t" start "\t" NR } }
      ' "${file}"
    )
  done < <(find "${wf_dir}" -maxdepth 1 -type f -name '*.yml' | sort)

  return "${rc}"
}

# ---------------------------------------------------------------------------
# Check 2 — every checked-in build script still forwards the define.
#
# Check 1 verifies the WORKFLOW made a decision; this verifies the decision
# reaches the compiler. Without it, deleting `${LIVE_SYNC_DEFINE}` from
# build-integration-apks.sh would silently revert three lanes to the inherited
# default while their YAML kept advertising a value.
# ---------------------------------------------------------------------------
check_build_scripts() {
  local root="$1" rc=0
  local file rel

  while IFS= read -r file; do
    rel="${file#"${root}/"}"
    [[ "${rel}" =~ ${BUILD_SCRIPT_EXEMPT_RE} ]] && continue

    local code
    code="$(_code_only < "${file}" || true)"

    # Does this script actually compile the app? (Comments already stripped —
    # every sibling in tooling/e2e/ci discusses `flutter build apk` at length.)
    grep -qE 'flutter build (apk|ios|ipa|appbundle)|flutter test [^|&]*integration_test/|flutter test \\' <<<"${code}" || continue
    # ... as a COMMAND, not inside a string or a heredoc: require it to start a
    # line or follow a `&&` / `(`.
    grep -qE '(^|&&[[:space:]]*|\([[:space:]]*)[[:space:]]*flutter (build|test)' <<<"${code}" || continue

    if ! grep -qF -- '--dart-define=HAVEN_LIVE_SYNC' <<<"${code}"; then
      fail_msg "${rel} compiles the app but never passes --dart-define=HAVEN_LIVE_SYNC. The receive path would fall back to liveSyncEnabled's defaultValue (true) no matter what the calling workflow declared, so every lane routed through this script would silently agree with the default instead of with itself."
      rc=1
    fi
  done < <(find "${root}/scripts" "${root}/tooling" -type f -name '*.sh' 2>/dev/null | sort)

  return "${rc}"
}

# ---------------------------------------------------------------------------
# Self-test — hermetic fixtures, no repo state, no toolchain.
#
# The fixtures are chosen so that a guard which has rotted into always-passing
# cannot survive: (2) is the defect itself (a build with no declaration), (5) is
# the prose-only near-miss that a looser DECL_RE would wave through, and (6) is
# the cross-job leak that a file-scoped implementation would miss.
# ---------------------------------------------------------------------------
self_test() {
  local tmp fails=0
  tmp="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf '${tmp}'" RETURN

  mkdir -p "${tmp}/wf" "${tmp}/repo/scripts/ci" "${tmp}/repo/tooling/e2e/ci"

  _wf_case() { # _wf_case <label> <expect-rc> <file-basename> <content>
    local label="$1" want="$2" name="$3" content="$4" got=0
    rm -f "${tmp}/wf"/*.yml
    printf '%s' "${content}" > "${tmp}/wf/${name}"
    # SUBSHELL: check_workflows returns, but keep the isolation symmetric with
    # the script-side cases and immune to any future `exit` inside it.
    ( check_workflows "${tmp}/wf" ) >/dev/null 2>&1 || got=$?
    if [[ "${got}" -eq "${want}" ]]; then
      printf '  \033[1;32mPASS\033[0m %s (rc=%d)\n' "${label}" "${got}"
    else
      printf '  \033[1;31mFAIL\033[0m %s (want rc=%d, got rc=%d)\n' "${label}" "${want}" "${got}" >&2
      fails=1
    fi
  }

  _script_case() { # _script_case <label> <expect-rc> <relpath> <content>
    local label="$1" want="$2" rel="$3" content="$4" got=0
    rm -rf "${tmp}/repo/scripts" "${tmp}/repo/tooling"
    mkdir -p "${tmp}/repo/$(dirname "${rel}")" "${tmp}/repo/scripts" "${tmp}/repo/tooling"
    printf '%s' "${content}" > "${tmp}/repo/${rel}"
    ( check_build_scripts "${tmp}/repo" ) >/dev/null 2>&1 || got=$?
    if [[ "${got}" -eq "${want}" ]]; then
      printf '  \033[1;32mPASS\033[0m %s (rc=%d)\n' "${label}" "${got}"
    else
      printf '  \033[1;31mFAIL\033[0m %s (want rc=%d, got rc=%d)\n' "${label}" "${want}" "${got}" >&2
      fails=1
    fi
  }

  log "self-test: workflow jobs (check 1)"

  # (1) Happy path — a build that declares the value inline.
  _wf_case "declared inline define passes" 0 "ok.yml" \
'name: OK
jobs:
  builder:
    runs-on: ubuntu-latest
    steps:
      - name: Build
        run: |
          flutter build apk --debug \
            --dart-define=HAVEN_LIVE_SYNC=false
'

  # (2) THE CRITICAL FIXTURE — the defect itself. A job builds the app and says
  #     nothing, so it inherits liveSyncEnabled's `true`.
  _wf_case "undeclared build FAILS" 1 "bad.yml" \
'name: Bad
jobs:
  builder:
    runs-on: ubuntu-latest
    steps:
      - name: Build
        run: flutter build apk --debug --dart-define=HAVEN_E2E_RELAY=ws://x
'

  # (3) A job-level `env:` covers every step in that job (the e2e-fgs-publish
  #     shape) — the guard must accept it or lanes would be pushed into
  #     duplicating the value at each step.
  _wf_case "job-level env passes" 0 "env.yml" \
'name: Env
jobs:
  builder:
    runs-on: ubuntu-latest
    env:
      HAVEN_LIVE_SYNC: "true"
    steps:
      - name: Build
        run: bash tooling/e2e/ci/build-integration-apks.sh
'

  # (4) A templated value is a decision too (e2e-android threads its input).
  _wf_case "expression-valued declaration passes" 0 "expr.yml" \
'name: Expr
jobs:
  builder:
    runs-on: ubuntu-latest
    steps:
      - name: Build
        run: flutter build apk --dart-define=HAVEN_LIVE_SYNC=${{ inputs.live_sync }}
'

  # (5) PROSE-ONLY near-miss. A lane that DOCUMENTS the flag but never passes it
  #     is the most likely way this guard gets defeated by accident — the real
  #     e2e-android.yml contains exactly this sentence next to a real define.
  _wf_case "mention without a value FAILS" 1 "prose.yml" \
'name: Prose
on:
  workflow_call:
    inputs:
      live_sync:
        description: Build with --dart-define=HAVEN_LIVE_SYNC. true exercises the engine.
        type: boolean
jobs:
  builder:
    runs-on: ubuntu-latest
    steps:
      - name: Build
        run: flutter build apk --debug
'

  # (5b) The value requirement, pinned INSIDE a job block. Fixture (5) puts its
  #      prose in the `on:` preamble, which the job-scoped scan never reads — so
  #      (5) alone does not actually test DECL_RE, and loosening DECL_RE to a
  #      bare name match slipped past the self-test until this fixture existed.
  #      A job that merely NAMES the variable has still not chosen a value.
  _wf_case "naming the variable without a value FAILS" 1 "named.yml" \
'name: Named
jobs:
  builder:
    runs-on: ubuntu-latest
    steps:
      - name: Note
        run: echo "HAVEN_LIVE_SYNC is documented in the runbook"
      - name: Build
        run: flutter build apk --debug
'

  # (5c) An EMPTY declaration is a half-edit, not a decision — and downstream
  #      every build wrapper rejects it, so accepting it here would report green
  #      on a lane that cannot run.
  _wf_case "empty-valued declaration FAILS" 1 "empty.yml" \
'name: Empty
jobs:
  builder:
    runs-on: ubuntu-latest
    env:
      HAVEN_LIVE_SYNC: ""
    steps:
      - name: Build
        run: flutter build apk --debug
'

  # (6) CROSS-JOB LEAK. One job declares, its sibling does not. A file-scoped
  #     implementation passes this; e2e-profile.yml is why that is unacceptable.
  _wf_case "sibling job without a declaration FAILS" 1 "twojobs.yml" \
'name: Two
jobs:
  android:
    runs-on: ubuntu-latest
    env:
      HAVEN_LIVE_SYNC: "true"
    steps:
      - name: Build
        run: flutter build apk --dart-define=HAVEN_LIVE_SYNC="${HAVEN_LIVE_SYNC}"
  ios:
    runs-on: macos-latest
    steps:
      - name: Build
        run: bash tooling/e2e/ci/run-ios-sim-scenario.sh integration_test/e2e/x.dart UDID
'

  # (7) A job that builds nothing needs no declaration — the guard must not
  #     force noise onto lint/analyze/aggregator jobs.
  _wf_case "non-building job needs nothing" 0 "nobuild.yml" \
'name: NoBuild
jobs:
  analyze:
    runs-on: ubuntu-latest
    steps:
      - name: Analyze
        run: flutter analyze --no-fatal-infos
  test:
    runs-on: ubuntu-latest
    steps:
      - name: Host suite
        run: flutter test --coverage
'

  # (8) The intent token is honoured in an allowlisted file ...
  _wf_case "intent token in an allowlisted file passes" 0 "build-check.yml" \
'name: Build Check
jobs:
  android:
    # HAVEN_LIVE_SYNC-INTENT: production-default
    runs-on: ubuntu-latest
    steps:
      - name: Build
        run: ../scripts/ci/build_apk_with_retry.sh android-arm64
'

  # (9) ... and REFUSED anywhere else, or it becomes a one-line opt-out of the
  #     whole guard.
  _wf_case "intent token outside the allowlist FAILS" 1 "e2e-sneaky.yml" \
'name: Sneaky
jobs:
  builder:
    # HAVEN_LIVE_SYNC-INTENT: production-default
    runs-on: ubuntu-latest
    steps:
      - name: Build
        run: flutter build apk --debug
'

  # (10) An iOS `flutter test <integration_test/...>` IS a build (it compiles,
  #      installs and drives), so it is in scope like any other.
  _wf_case "undeclared integration flutter test FAILS" 1 "ios.yml" \
'name: iOS
jobs:
  sim:
    runs-on: macos-latest
    steps:
      - name: Run
        run: flutter test integration_test/e2e/e2e_combined.dart -d "${UDID}"
'

  # (11) A `--self-test` invocation of a build wrapper is not a build. Both
  #      false positives on this guard'"'"'s first real run were of this shape or
  #      (12)'"'"'s; without fixtures they would come back the moment either
  #      filter is touched.
  _wf_case "wrapper --self-test is not a build" 0 "repo-guards.yml" \
'name: Repo Guards
jobs:
  guards:
    runs-on: ubuntu-latest
    steps:
      - name: Build-retry predicate self-test
        run: bash scripts/ci/build_apk_with_retry.sh --self-test
'

  # (12) A comment that MENTIONS a build is not a build ...
  _wf_case "comment mentioning a build is not a build" 0 "rust-check.yml" \
'name: Rust
jobs:
  core:
    runs-on: ubuntu-latest
    steps:
      - name: Test
        # A Rust break can surface only in the app build (build_release.sh).
        run: cargo test
'

  # (13) ... and, symmetrically, a comment that mentions a VALUE is not a
  #      declaration. This is the direction that actually loses coverage: a job
  #      that discusses HAVEN_LIVE_SYNC: "false" in prose while compiling the
  #      inherited default would otherwise be waved through.
  _wf_case "declaration only in a comment FAILS" 1 "commented.yml" \
'name: Commented
jobs:
  builder:
    runs-on: ubuntu-latest
    # This lane is poll-path; HAVEN_LIVE_SYNC: "false" is what we mean.
    steps:
      - name: Build
        run: flutter build apk --debug
'

  log "self-test: build scripts (check 2)"

  # (11) A build script that forwards the define.
  _script_case "forwarding build script passes" 0 "tooling/e2e/ci/build-x.sh" \
'#!/usr/bin/env bash
set -euo pipefail
flutter build apk \
  --debug \
  --dart-define=HAVEN_LIVE_SYNC="${HAVEN_LIVE_SYNC}"
'

  # (12) THE OTHER CRITICAL FIXTURE — the funnel stops forwarding. Every lane
  #      routed through it reverts to the inherited default while its YAML still
  #      declares a value, so check 1 alone would stay green.
  _script_case "build script that dropped the define FAILS" 1 "tooling/e2e/ci/build-x.sh" \
'#!/usr/bin/env bash
set -euo pipefail
flutter build apk \
  --debug \
  --dart-define=HAVEN_E2E_RELAY="${RELAY_URL}"
'

  # (13) A script that never builds the app is not the subject.
  _script_case "non-building script needs nothing" 0 "tooling/e2e/ci/relay.sh" \
'#!/usr/bin/env bash
set -euo pipefail
docker run --rm strfry
'

  # (14) The structural exemptions must actually hold, or the allowlist is
  #      decorative.
  _script_case "pass-through wrapper is exempt" 0 "scripts/ci/build_apk_with_retry.sh" \
'#!/usr/bin/env bash
set -euo pipefail
flutter build apk --debug --target-platform "${1}" "$@"
'
  _script_case "release wrapper is exempt" 0 "scripts/build_release.sh" \
'#!/usr/bin/env bash
set -euo pipefail
flutter build apk --release --dart-define-from-file="${defines}"
'

  if (( fails )); then
    fail_msg "self-test failed — this guard cannot be trusted until it is fixed"
    exit 2
  fi
  log "OK: self-test passed (20 fixtures)."
}

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------
main() {
  if [[ "${1:-}" == "--self-test" ]]; then
    self_test
    exit 0
  fi
  if [[ $# -gt 0 ]]; then
    misconfig "usage: ${SCRIPT_NAME}.sh [--self-test]"
  fi

  local wf_dir="${REPO_ROOT}/.github/workflows"
  local flag="${REPO_ROOT}/haven/lib/src/providers/live_sync_provider.dart"

  [[ -d "${wf_dir}" ]] || misconfig "${wf_dir} not found"
  [[ -f "${flag}" ]] || misconfig "${flag} not found — the flag this guard exists for is gone; update or delete the guard"

  # The guard's whole premise is that the define has a compile-time default that
  # a build can inherit. If the const is ever rewritten into something without
  # one, this check is about the wrong thing and must be revisited rather than
  # left passing over a stale assumption.
  grep -qE "bool\.fromEnvironment\(" "${flag}" ||
    misconfig "liveSyncEnabled is no longer a bool.fromEnvironment const — the inheritance this guard prevents may no longer exist; re-derive the guard before re-enabling it"

  local rc=0
  log "Checking workflow jobs that build the app ..."
  check_workflows "${wf_dir}" || rc=1
  log "Checking checked-in build scripts forward the define ..."
  check_build_scripts "${REPO_ROOT}" || rc=1

  if (( rc )); then
    fail_msg "an app build does not declare its receive path (CI_HARDENING_BACKLOG.md A7)"
    exit 1
  fi

  log "OK: every app build declares HAVEN_LIVE_SYNC (or the production default)."
}

main "$@"
