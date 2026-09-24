#!/usr/bin/env bash
# CI guard: no job builds the app with a cold Gradle cache or an unclassified
# retry.
#
# # The invariant
#
# Every workflow job that runs a Gradle-backed build
#   (1) restores the shared Gradle dependency cache, on the canonical key,
#       textually BEFORE its first build site, and
#   (2) reaches Gradle through scripts/ci/build_apk_with_retry.sh, never a bare
#       `flutter build apk`,
# and exactly ONE job in the repo WRITES that cache key.
#
# # The cache must never redden a lane (C6)
#
# Every restore step carries BOTH a `timeout-minutes` and `continue-on-error:
# true`. A cache miss or a service error is already fail-open INSIDE the action,
# but a step that overruns its own `timeout-minutes` fails the job — so the cap
# that stops a hung download from eating the lane's budget is, without
# `continue-on-error`, itself a new way to lose a healthy lane to the cache
# service. The two belong together: the cap bounds the wait, the fail-open turns
# the expiry into a cold build.
#
# # The writer's key is the restore's output (C2/C4)
#
# The save step spells its key as the restore step's `cache-primary-key` output,
# not a second `hashFiles(...)`. `hashFiles` is evaluated where it is written,
# and the save runs AFTER the build, so re-spelled globs that walk build trees
# could hash a generated file and publish under a key no restore ever asks for.
# That is actions/cache's own documented restore/save split. It only resolves if
# the restore step declares the matching `id`, so both halves are pinned.
#
# # Why
#
# Gradle resolves the buildscript classpath over the network before it compiles
# anything, so a cold `~/.gradle` makes a lane fetch hundreds of POMs from a
# shared runner egress IP, and Maven Central rate-limits it. The cache buys
# safety, not time: with it HIT, a job's first `assembleDebug` still takes
# 429-638 s (run 35813757227) against 33-61 s for its later ones, because that
# gap is Gradle configuration, cargokit's Rust cross-compiles and the Kotlin
# compile, none of which the dependency cache holds. CI run 35622556197 job
# 106414462454 lost a whole lane to HTTP 429 on the classpath with no test run,
# while twelve sibling Android lanes built the same commit clean; run
# 30732662493 job 91456350943 lost the `arm` leg the same way in August.
#
# The cache is the fix because it removes the requests. The retry is the
# backstop, and it has to CLASSIFY: a blind retry re-runs a compile error three
# times, and — worse — retries disk and memory exhaustion, which are
# intermittent AND real, turning a capacity problem into a green build that
# hides it. Three lane builders carried exactly that blind loop before this
# guard existed.
#
# Both halves rot the same silent way: a new lane copied from an old one, or a
# cache step quietly given a key nothing writes, leaves a job that looks
# hardened in review and is not. Hence a check rather than a convention.
#
# # The single-writer rule (C4)
#
# One job SAVES the key; every other job restores it read-only. That is not
# tidiness: e2e-relay-customization.yml deliberately `rm -rf`s `~/.gradle/caches`
# after its build to keep disk headroom for the emulator's system image. If that
# lane could also save, it would publish a cache emptied by its own cleanup and
# every other lane would restore the hole. A second writer anywhere reintroduces
# that class, so the count is pinned at exactly one.
#
# # Exemptions
#
# A job may opt out of C1 ONLY with a reason on the line above its `runs-on`:
#
#     # HAVEN_GRADLE_CACHE-EXEMPT: <why this job cannot restore the cache>
#
# The reason is mandatory and must be non-empty, so an exemption is a sentence
# somebody wrote and a reviewer can disagree with, never a silent omission. It
# exempts C1 only — an exempt job still has to build through the wrapper.
#
# Pure bash/awk over the checked-out tree, no toolchain — belongs in
# repo-guards.yml.
#
# Usage:
#   check_gradle_build_hardened.sh              # check the repo
#   check_gradle_build_hardened.sh --self-test
#
# Exit codes:
#   0  every Gradle-building job is hardened
#   1  a job violates C1-C6
#   2  expected paths missing, or the self-test failed

set -euo pipefail

readonly SCRIPT_NAME="check_gradle_build_hardened.sh"
readonly RC_BROKEN=2

readonly RESTORE_STEP_NAME="Restore Gradle dependency cache"
readonly SAVE_STEP_NAME="Save Gradle dependency cache"
readonly EXEMPT_TOKEN="HAVEN_GRADLE_CACHE-EXEMPT:"

# The canonical cache key and paths. Checked verbatim: a lane that restores a
# key nothing writes is colder than one with no cache step at all, and reads in
# review exactly like a working one.
readonly CANON_KEY="gradle-deps-\${{ runner.os }}-\${{ hashFiles('haven/android/**/*.gradle*', 'haven/rust_builder/**/*.gradle*', 'haven/android/gradle/wrapper/gradle-wrapper.properties', 'haven/pubspec.lock') }}"
readonly CANON_PATH_1="~/.gradle/caches/modules-2"
readonly CANON_PATH_2="~/.gradle/wrapper"

# The writer's save key, and the restore `id` it reads through.
readonly CANON_RESTORE_ID="gradle-cache-restore"
readonly CANON_SAVE_KEY="\${{ steps.${CANON_RESTORE_ID}.outputs.cache-primary-key }}"

# A Gradle-backed build site: the wrapper itself, or one of the checked-in
# builders that funnels into it. Listed literally rather than matched loosely so
# a NEW builder shows up as an unrecognised bare build (C3) instead of silently
# escaping C1.
#
# `build_release.sh` counts only for its ANDROID artifacts. The same script
# builds the iOS `ipa` through Xcode, which resolves no Maven dependency and has
# no ~/.gradle to warm; requiring a Gradle cache on the macOS job would be a
# step that can only ever miss.
#
# `[.]` rather than `\.`: the pattern crosses into awk through `-v`, which
# processes escape sequences first, so `\.` arrives as a bare `.` AND warns on
# the way (gawk does; mawk silently differs). A bracket expression means the
# same thing to both and survives the hand-off intact.
readonly BUILD_SITE_RE='build_apk_with_retry[.]sh|build-integration-apks[.]sh|build-b3-real-gps-apk[.]sh|build-kp-rotation-apk[.]sh|build_release[.]sh (apk|appbundle)'

# A build that does NOT go through the wrapper. `flutter build apk` in a
# workflow's command position is the whole of it — the iOS lanes build through
# `flutter test integration_test/`, which is not Gradle.
readonly BARE_BUILD_RE='flutter build apk'

log()  { printf '[%s] %s\n' "${SCRIPT_NAME}" "$*"; }
fail() { printf '[%s] FAIL: %s\n' "${SCRIPT_NAME}" "$*" >&2; violations=$(( violations + 1 )); }

# Emits one TAB-separated record per interesting line:
#   <job>\t<lineno>\t<kind>\t<payload>
# kinds: build, bare, restore, save, exempt, restore-key, restore-path, save-key,
#        save-if, restore-timeout, restore-coe, restore-id
#
# Full-line comments are dropped first: a workflow's prose legitimately quotes
# `flutter build apk` (e2e-relay-customization.yml's disk-headroom note does),
# and a guard that reads prose as code is a guard that reports the comment.
scan_workflow() {
  awk -v build_re="${BUILD_SITE_RE}" -v bare_re="${BARE_BUILD_RE}" \
      -v restore_name="${RESTORE_STEP_NAME}" -v save_name="${SAVE_STEP_NAME}" \
      -v exempt_tok="${EXEMPT_TOKEN}" '
    # Track which job we are in: a 2-space key after the top-level `jobs:`.
    /^jobs:[[:space:]]*$/ { injobs = 1; next }
    injobs && /^  [A-Za-z_][A-Za-z0-9_-]*:[[:space:]]*$/ {
      job = $0; sub(/^  /, "", job); sub(/:[[:space:]]*$/, "", job)
      step = ""
      next
    }
    # The exemption is read from the RAW line, since it lives in a comment.
    index($0, exempt_tok) > 0 {
      reason = substr($0, index($0, exempt_tok) + length(exempt_tok))
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", reason)
      printf "%s\t%d\texempt\t%s\n", job, NR, reason
    }
    { raw = $0 }
    # Everything below reads CODE only.
    /^[[:space:]]*#/ { next }
    # A `--self-test` line names a build script without performing a build:
    # repo-guards.yml runs the wrapper`s own fixtures, which never invoke
    # Flutter. Without this, the guards job reads as a lane that builds the app.
    /--self-test/ { next }
    {
      if (match($0, /^      - name: /)) {
        step = substr($0, RLENGTH + 1)
        gsub(/[[:space:]]+$/, "", step)
        if (step == restore_name) printf "%s\t%d\trestore\t\n", job, NR
        if (step == save_name)    printf "%s\t%d\tsave\t\n", job, NR
      }
      if (step == restore_name || step == save_name) {
        if (match($0, /^          key: /)) {
          k = substr($0, RLENGTH + 1); gsub(/[[:space:]]+$/, "", k)
          printf "%s\t%d\t%s-key\t%s\n", job, NR, (step == restore_name ? "restore" : "save"), k
        }
        # Any path ENTRY under the step`s `path:` block, not just a ~/.gradle
        # one: a step that cached ~/.m2 or the whole of ~/.gradle/caches must be
        # seen in order to be rejected, and a matcher anchored on the right
        # answer can only ever find the right answer. The `restore-keys:`
        # entries sit at the same indent but begin with the key prefix, so the
        # leading ~ or / is what tells the two apart.
        if ($0 ~ "^ +[~/]") {
          p = $0; gsub(/^[[:space:]]+|[[:space:]]+$/, "", p)
          printf "%s\t%d\t%s-path\t%s\n", job, NR, (step == restore_name ? "restore" : "save"), p
        }
        if ($0 ~ /^        if: success\(\)[[:space:]]*$/ && step == save_name)
          printf "%s\t%d\tsave-if\t\n", job, NR
      }
      # Restore-step properties only: the save step carries its own
      # `continue-on-error` for an unrelated reason (a lost save race), and
      # reading it as the restore`s would make C6 pass on a lane with none.
      if (step == restore_name) {
        if ($0 ~ /^        timeout-minutes: [0-9]+[[:space:]]*$/)
          printf "%s\t%d\trestore-timeout\t\n", job, NR
        if ($0 ~ /^        continue-on-error: true[[:space:]]*$/)
          printf "%s\t%d\trestore-coe\t\n", job, NR
        if (match($0, /^        id: /)) {
          v = substr($0, RLENGTH + 1); gsub(/[[:space:]]+$/, "", v)
          printf "%s\t%d\trestore-id\t%s\n", job, NR, v
        }
      }
      if ($0 ~ build_re) printf "%s\t%d\tbuild\t%s\n", job, NR, raw
      else if ($0 ~ bare_re) printf "%s\t%d\tbare\t%s\n", job, NR, raw
    }
  ' "$1"
}

check_repo() { # $1 = workflow dir
  local dir="$1" f base rec
  local -a records
  violations=0
  local total_jobs=0 total_saves=0 checked_files=0

  for f in "${dir}"/*.yml; do
    [[ -e "${f}" ]] || continue
    base="$(basename "${f}")"
    checked_files=$(( checked_files + 1 ))
    # Materialise: under `pipefail` a producer read by a short-lived consumer
    # fails OPEN, and "open" here means a workflow reported as having no builds.
    mapfile -t records < <(scan_workflow "${f}")

    local -A first_build=() restore_at=() exempt=() has_restore=()
    local -A restore_timeout=() restore_coe=() restore_id=() has_save=()
    local job lineno kind payload
    for rec in "${records[@]}"; do
      [[ -n "${rec}" ]] || continue
      IFS=$'\t' read -r job lineno kind payload <<<"${rec}"
      case "${kind}" in
        build|bare)
          [[ -n "${first_build[${job}]:-}" ]] || first_build["${job}"]="${lineno}"
          if [[ "${kind}" == "bare" ]]; then
            fail "C3 ${base} :: ${job} line ${lineno}: builds with a bare \`flutter build apk\`. Every Gradle build must go through scripts/ci/build_apk_with_retry.sh, which retries ONLY a dependency-resolution failure and refuses to retry a compile error or a full disk."
          fi
          ;;
        restore) has_restore["${job}"]=1; restore_at["${job}"]="${lineno}" ;;
        restore-timeout) restore_timeout["${job}"]=1 ;;
        restore-coe)     restore_coe["${job}"]=1 ;;
        restore-id)      restore_id["${job}"]="${payload}" ;;
        save)    total_saves=$(( total_saves + 1 )); has_save["${job}"]=1 ;;
        exempt)
          if [[ -z "${payload}" ]]; then
            fail "C5 ${base} line ${lineno}: a ${EXEMPT_TOKEN} with no reason. An exemption has to be a sentence a reviewer can disagree with."
          else
            exempt["${job}"]=1
          fi
          ;;
        restore-key)
          [[ "${payload}" == "${CANON_KEY}" ]] || \
            fail "C2 ${base} :: ${job} line ${lineno}: restores a NON-canonical cache key. A key nothing writes is colder than no cache at all, and reads like a working one."
          ;;
        restore-path|save-path)
          [[ "${payload}" == "${CANON_PATH_1}" || "${payload}" == "${CANON_PATH_2}" ]] || \
            fail "C2 ${base} :: ${job} line ${lineno}: caches '${payload}', which is not one of the two canonical paths."
          ;;
        save-key)
          [[ "${payload}" == "${CANON_SAVE_KEY}" ]] || \
            fail "C2 ${base} :: ${job} line ${lineno}: saves a NON-canonical cache key, so nothing restores what it writes. It must be '${CANON_SAVE_KEY}' — a second hashFiles() here is evaluated AFTER the build, over globs that would then also see whatever the build generated."
          ;;
      esac
    done

    # save-if is recorded only when the save step carries `if: success()`.
    local saves_here=0 save_ifs=0
    for rec in "${records[@]}"; do
      [[ -n "${rec}" ]] || continue
      IFS=$'\t' read -r job lineno kind payload <<<"${rec}"
      [[ "${kind}" == "save" ]] && saves_here=$(( saves_here + 1 ))
      [[ "${kind}" == "save-if" ]] && save_ifs=$(( save_ifs + 1 ))
    done
    if (( saves_here != save_ifs )); then
      fail "C4 ${base}: a ${SAVE_STEP_NAME} step without \`if: success()\`. A cache written by a build that died mid-resolution carries exactly the gaps that made it fail, and every lane restoring it inherits them."
    fi

    for job in "${!has_restore[@]}"; do
      if [[ -z "${restore_timeout[${job}]:-}" ]]; then
        fail "C6 ${base} :: ${job} line ${restore_at[${job}]}: the ${RESTORE_STEP_NAME} step has no \`timeout-minutes\`. A cache service that stops answering would then hold the lane for the whole job cap."
      fi
      if [[ -z "${restore_coe[${job}]:-}" ]]; then
        fail "C6 ${base} :: ${job} line ${restore_at[${job}]}: the ${RESTORE_STEP_NAME} step is not \`continue-on-error: true\`. A miss is fail-open inside the action, but a step that overruns its own \`timeout-minutes\` FAILS the job — a cache is an optimisation and must never redden a lane that would have built cold."
      fi
    done

    # The save key only resolves if the restore step it names really carries
    # that `id`; otherwise the expression is empty and the cache is written
    # under a key nothing — including the next run of this very job — asks for.
    for job in "${!has_save[@]}"; do
      if [[ "${restore_id[${job}]:-}" != "${CANON_RESTORE_ID}" ]]; then
        fail "C4 ${base} :: ${job}: saves under the restore step's \`cache-primary-key\` output, but no ${RESTORE_STEP_NAME} step in this job declares \`id: ${CANON_RESTORE_ID}\`. The expression resolves to nothing."
      fi
    done

    for job in "${!first_build[@]}"; do
      total_jobs=$(( total_jobs + 1 ))
      if [[ -n "${exempt[${job}]:-}" ]]; then
        continue
      fi
      if [[ -z "${has_restore[${job}]:-}" ]]; then
        fail "C1 ${base} :: ${job}: builds the app (line ${first_build[${job}]}) with no '${RESTORE_STEP_NAME}' step. A cold ~/.gradle fetches hundreds of POMs from a shared runner IP; that is what HTTP 429'd a lane into a red job that ran no test (CI run 35622556197)."
      elif (( restore_at["${job}"] > first_build["${job}"] )); then
        fail "C1 ${base} :: ${job}: restores the Gradle cache at line ${restore_at[${job}]}, AFTER its first build at line ${first_build[${job}]}. A cache restored after the build it was meant to warm is a no-op."
      fi
    done
  done

  if (( total_saves != 1 )); then
    fail "C4 ${total_saves} job(s) SAVE the Gradle cache key; there must be exactly ONE writer. A lane that deletes or half-fills ~/.gradle must never be able to publish a cache the others restore (e2e-relay-customization.yml wipes ~/.gradle/caches by design)."
  fi

  if (( violations )); then
    printf '[%s] FAIL: %d violation(s).\n' "${SCRIPT_NAME}" "${violations}" >&2
    return 1
  fi
  log "OK — ${checked_files} workflow(s), ${total_jobs} Gradle-building job(s): each restores the canonical cache before its first build and builds through the classified retry; exactly one job writes the key."
  return 0
}

# ---------------------------------------------------------------------------
# Self-test: hermetic workflow fixtures in a temp dir. Each negative differs
# from the positive by exactly the property under test.
# ---------------------------------------------------------------------------
readonly SELF_TEST_FIXTURES=14

# emit_restore [id] — the id is emitted only when asked, because in the repo
# only the WRITER's restore carries one (the readers have nothing to read it).
emit_restore() {
  cat <<EOF
      - name: ${RESTORE_STEP_NAME}
${1:+        id: $1
}        uses: actions/cache/restore@v4
        timeout-minutes: 2
        continue-on-error: true
        with:
          path: |
            ${CANON_PATH_1}
            ${CANON_PATH_2}
          key: ${CANON_KEY}
EOF
}

emit_save() {
  cat <<EOF
      - name: ${SAVE_STEP_NAME}
        if: success()
        continue-on-error: true
        uses: actions/cache/save@v4
        with:
          path: |
            ${CANON_PATH_1}
            ${CANON_PATH_2}
          key: ${CANON_SAVE_KEY}
EOF
}

# A repo whose single writer lives in its own file, so a fixture can vary the
# BUILDING workflow without also losing the writer.
write_writer_file() {
  { echo "name: W"; echo "jobs:"; echo "  writer:"; echo "    runs-on: ubuntu-latest"
    echo "    steps:"; emit_restore "${CANON_RESTORE_ID}"
    echo "      - name: Build APK"; echo "        run: ../scripts/ci/build_apk_with_retry.sh android-x64"
    emit_save; } > "$1/zz-writer.yml"
}

run_self_test() {
  local tmp ran=0 failures=0 d rc out
  tmp="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf '${tmp}'" EXIT

  _case() { # <label> <expect-rc> <dir>
    local label="$1" want="$2" dir="$3" got=0
    out="$(check_repo "${dir}" 2>&1)" || got=$?
    if (( got != want )); then
      echo "SELF-TEST FAIL (${label}): expected rc ${want}, got ${got}" >&2
      echo "${out}" | sed 's/^/    /' >&2
      failures=1
    fi
    LAST_OUT="${out}"
  }

  # (1) The shape the repo is supposed to have: a lane that restores then builds
  #     through the wrapper, plus exactly one writer.
  ran=$(( ran + 1 ))
  d="${tmp}/ok"; mkdir -p "${d}"; write_writer_file "${d}"
  { echo "name: A"; echo "jobs:"; echo "  lane:"; echo "    runs-on: ubuntu-latest"
    echo "    steps:"; emit_restore
    echo "      - name: Build"; echo "        run: bash ../tooling/e2e/ci/build-integration-apks.sh"; } > "${d}/a.yml"
  _case 1 0 "${d}"

  # (2) A building job with NO restore step — the new-lane-copied-from-an-old-one
  #     case, and the only difference from (1).
  ran=$(( ran + 1 ))
  d="${tmp}/nocache"; mkdir -p "${d}"; write_writer_file "${d}"
  { echo "name: A"; echo "jobs:"; echo "  lane:"; echo "    runs-on: ubuntu-latest"
    echo "    steps:"
    echo "      - name: Build"; echo "        run: bash ../tooling/e2e/ci/build-integration-apks.sh"; } > "${d}/a.yml"
  _case 2 1 "${d}"
  [[ "${LAST_OUT}" == *"C1"* ]] || { echo "SELF-TEST FAIL (2): a missing cache must be reported as C1" >&2; failures=1; }

  # (3) Restore present but AFTER the build: a no-op that reads like a fix.
  ran=$(( ran + 1 ))
  d="${tmp}/late"; mkdir -p "${d}"; write_writer_file "${d}"
  { echo "name: A"; echo "jobs:"; echo "  lane:"; echo "    runs-on: ubuntu-latest"
    echo "    steps:"
    echo "      - name: Build"; echo "        run: bash ../tooling/e2e/ci/build-integration-apks.sh"
    emit_restore; } > "${d}/a.yml"
  _case 3 1 "${d}"
  [[ "${LAST_OUT}" == *"AFTER its first build"* ]] || { echo "SELF-TEST FAIL (3): a late restore must be named as late" >&2; failures=1; }

  # (4) A bare `flutter build apk` — the unclassified retry path.
  ran=$(( ran + 1 ))
  d="${tmp}/bare"; mkdir -p "${d}"; write_writer_file "${d}"
  { echo "name: A"; echo "jobs:"; echo "  lane:"; echo "    runs-on: ubuntu-latest"
    echo "    steps:"; emit_restore
    echo "      - name: Build"; echo "        run: flutter build apk --debug"; } > "${d}/a.yml"
  _case 4 1 "${d}"
  [[ "${LAST_OUT}" == *"C3"* ]] || { echo "SELF-TEST FAIL (4): a bare build must be reported as C3" >&2; failures=1; }

  # (5) CONTROL for (4): the same bare build inside a COMMENT is prose, not a
  #     build. Without this, (4) would also pass on a guard that reads comments.
  ran=$(( ran + 1 ))
  d="${tmp}/prose"; mkdir -p "${d}"; write_writer_file "${d}"
  { echo "name: A"; echo "jobs:"; echo "  lane:"; echo "    runs-on: ubuntu-latest"
    echo "    steps:"; emit_restore
    echo "      # \`flutter build apk\` peaks at several GB, so we build first."
    echo "      - name: Build"; echo "        run: bash ../tooling/e2e/ci/build-integration-apks.sh"; } > "${d}/a.yml"
  _case 5 0 "${d}"

  # (6) A non-canonical key: a cache nothing writes.
  ran=$(( ran + 1 ))
  d="${tmp}/key"; mkdir -p "${d}"; write_writer_file "${d}"
  { echo "name: A"; echo "jobs:"; echo "  lane:"; echo "    runs-on: ubuntu-latest"
    echo "    steps:"
    echo "      - name: ${RESTORE_STEP_NAME}"; echo "        uses: actions/cache/restore@v4"
    echo "        timeout-minutes: 2"; echo "        continue-on-error: true"
    echo "        with:"; echo "          path: |"
    echo "            ${CANON_PATH_1}"; echo "            ${CANON_PATH_2}"
    echo "          key: gradle-deps-\${{ runner.os }}-typo"
    echo "      - name: Build"; echo "        run: bash ../tooling/e2e/ci/build-integration-apks.sh"; } > "${d}/a.yml"
  _case 6 1 "${d}"
  [[ "${LAST_OUT}" == *"C2"* ]] || { echo "SELF-TEST FAIL (6): a wrong key must be reported as C2" >&2; failures=1; }

  # (7) A SECOND writer — the lane that wipes ~/.gradle publishing its hole.
  ran=$(( ran + 1 ))
  d="${tmp}/twowriters"; mkdir -p "${d}"; write_writer_file "${d}"
  { echo "name: A"; echo "jobs:"; echo "  lane:"; echo "    runs-on: ubuntu-latest"
    echo "    steps:"; emit_restore
    echo "      - name: Build"; echo "        run: bash ../tooling/e2e/ci/build-integration-apks.sh"
    emit_save; } > "${d}/a.yml"
  _case 7 1 "${d}"
  [[ "${LAST_OUT}" == *"exactly ONE writer"* ]] || { echo "SELF-TEST FAIL (7): a second writer must be named" >&2; failures=1; }

  # (8) A save without `if: success()` — publishing a half-resolved cache.
  ran=$(( ran + 1 ))
  d="${tmp}/nosuccess"; mkdir -p "${d}"
  { echo "name: W"; echo "jobs:"; echo "  writer:"; echo "    runs-on: ubuntu-latest"
    echo "    steps:"; emit_restore "${CANON_RESTORE_ID}"
    echo "      - name: Build APK"; echo "        run: ../scripts/ci/build_apk_with_retry.sh android-x64"
    echo "      - name: ${SAVE_STEP_NAME}"; echo "        uses: actions/cache/save@v4"
    echo "        with:"; echo "          path: |"
    echo "            ${CANON_PATH_1}"; echo "            ${CANON_PATH_2}"
    echo "          key: ${CANON_SAVE_KEY}"; } > "${d}/zz-writer.yml"
  _case 8 1 "${d}"
  [[ "${LAST_OUT}" == *"if: success()"* ]] || { echo "SELF-TEST FAIL (8): an unconditional save must be named" >&2; failures=1; }

  # (9) An exemption works, and ONLY with a reason. Both halves, because an
  #     exemption that accepts a blank reason is an exemption nobody wrote.
  ran=$(( ran + 1 ))
  d="${tmp}/exempt"; mkdir -p "${d}"; write_writer_file "${d}"
  { echo "name: A"; echo "jobs:"; echo "  lane:"
    echo "    # ${EXEMPT_TOKEN} job cap is already at GitHub's ceiling."
    echo "    runs-on: ubuntu-latest"; echo "    steps:"
    echo "      - name: Build"; echo "        run: bash ../tooling/e2e/ci/build-integration-apks.sh"; } > "${d}/a.yml"
  _case 9 0 "${d}"
  d="${tmp}/exempt-blank"; mkdir -p "${d}"; write_writer_file "${d}"
  { echo "name: A"; echo "jobs:"; echo "  lane:"
    echo "    # ${EXEMPT_TOKEN}"
    echo "    runs-on: ubuntu-latest"; echo "    steps:"
    echo "      - name: Build"; echo "        run: bash ../tooling/e2e/ci/build-integration-apks.sh"; } > "${d}/a.yml"
  _case "9b" 1 "${d}"
  [[ "${LAST_OUT}" == *"no reason"* ]] || { echo "SELF-TEST FAIL (9b): a blank exemption must be refused" >&2; failures=1; }

  # (10) The WRITER saving a non-canonical key: every reader then restores
  #      nothing, for the life of the mistake, with no lane ever going red. The
  #      key used here is the RESTORE key spelled out again — the exact shape
  #      this repo shipped before the save was switched to the restore step's
  #      output, and the one a future edit is most likely to reach for, because
  #      it looks identical to what the readers ask for. It is not: this step is
  #      evaluated after the build, so its globs can hash a generated file.
  ran=$(( ran + 1 ))
  d="${tmp}/savekey"; mkdir -p "${d}"
  { echo "name: W"; echo "jobs:"; echo "  writer:"; echo "    runs-on: ubuntu-latest"
    echo "    steps:"; emit_restore "${CANON_RESTORE_ID}"
    echo "      - name: Build APK"; echo "        run: ../scripts/ci/build_apk_with_retry.sh android-x64"
    echo "      - name: ${SAVE_STEP_NAME}"; echo "        if: success()"
    echo "        uses: actions/cache/save@v4"; echo "        with:"; echo "          path: |"
    echo "            ${CANON_PATH_1}"; echo "            ${CANON_PATH_2}"
    echo "          key: ${CANON_KEY}"; } > "${d}/zz-writer.yml"
  _case 10 1 "${d}"
  [[ "${LAST_OUT}" == *"nothing restores what it writes"* ]] || { echo "SELF-TEST FAIL (10): a writer saving the wrong key must be named" >&2; failures=1; }

  # (11) A cache step pointed at the wrong PATH. ~/.gradle/caches wholesale is
  #      the plausible mistake: it sweeps in build-cache-1 and the transform
  #      cache, which churn every commit, so the key would miss constantly while
  #      the step still reads as "we cache Gradle".
  ran=$(( ran + 1 ))
  d="${tmp}/path"; mkdir -p "${d}"; write_writer_file "${d}"
  { echo "name: A"; echo "jobs:"; echo "  lane:"; echo "    runs-on: ubuntu-latest"
    echo "    steps:"
    echo "      - name: ${RESTORE_STEP_NAME}"; echo "        uses: actions/cache/restore@v4"
    echo "        timeout-minutes: 2"; echo "        continue-on-error: true"
    echo "        with:"; echo "          path: |"
    echo "            ~/.gradle/caches"; echo "            ${CANON_PATH_2}"
    echo "          key: ${CANON_KEY}"
    echo "      - name: Build"; echo "        run: bash ../tooling/e2e/ci/build-integration-apks.sh"; } > "${d}/a.yml"
  _case 11 1 "${d}"
  [[ "${LAST_OUT}" == *"not one of the two canonical paths"* ]] || { echo "SELF-TEST FAIL (11): a wrong cache path must be named" >&2; failures=1; }

  # (12) A restore capped but NOT fail-open — the shape every lane had before
  #      C6. The cap is what makes it reachable: a restore that outruns two
  #      minutes fails the step, and a failed step fails the job, so the lane
  #      goes red having built nothing and run no test.
  ran=$(( ran + 1 ))
  d="${tmp}/nocoe"; mkdir -p "${d}"; write_writer_file "${d}"
  { echo "name: A"; echo "jobs:"; echo "  lane:"; echo "    runs-on: ubuntu-latest"
    echo "    steps:"
    echo "      - name: ${RESTORE_STEP_NAME}"; echo "        uses: actions/cache/restore@v4"
    echo "        timeout-minutes: 2"
    echo "        with:"; echo "          path: |"
    echo "            ${CANON_PATH_1}"; echo "            ${CANON_PATH_2}"
    echo "          key: ${CANON_KEY}"
    echo "      - name: Build"; echo "        run: bash ../tooling/e2e/ci/build-integration-apks.sh"; } > "${d}/a.yml"
  _case 12 1 "${d}"
  [[ "${LAST_OUT}" == *"continue-on-error"* ]] || { echo "SELF-TEST FAIL (12): a restore that is not fail-open must be named" >&2; failures=1; }

  # (13) The mirror of (12): fail-open but UNCAPPED. Differs from the passing
  #      shape by the cap alone, so neither half of C6 can be dropped quietly.
  ran=$(( ran + 1 ))
  d="${tmp}/nocap"; mkdir -p "${d}"; write_writer_file "${d}"
  { echo "name: A"; echo "jobs:"; echo "  lane:"; echo "    runs-on: ubuntu-latest"
    echo "    steps:"
    echo "      - name: ${RESTORE_STEP_NAME}"; echo "        uses: actions/cache/restore@v4"
    echo "        continue-on-error: true"
    echo "        with:"; echo "          path: |"
    echo "            ${CANON_PATH_1}"; echo "            ${CANON_PATH_2}"
    echo "          key: ${CANON_KEY}"
    echo "      - name: Build"; echo "        run: bash ../tooling/e2e/ci/build-integration-apks.sh"; } > "${d}/a.yml"
  _case 13 1 "${d}"
  [[ "${LAST_OUT}" == *"no \`timeout-minutes\`"* ]] || { echo "SELF-TEST FAIL (13): an uncapped restore must be named" >&2; failures=1; }

  # (14) The writer saves the canonical EXPRESSION, but its restore carries no
  #      matching `id` — so the expression resolves to nothing and the cache is
  #      published under an empty key. Textually the save key is right, which is
  #      exactly why the literal check alone cannot see this.
  ran=$(( ran + 1 ))
  d="${tmp}/noid"; mkdir -p "${d}"
  { echo "name: W"; echo "jobs:"; echo "  writer:"; echo "    runs-on: ubuntu-latest"
    echo "    steps:"; emit_restore
    echo "      - name: Build APK"; echo "        run: ../scripts/ci/build_apk_with_retry.sh android-x64"
    emit_save; } > "${d}/zz-writer.yml"
  _case 14 1 "${d}"
  [[ "${LAST_OUT}" == *"resolves to nothing"* ]] || { echo "SELF-TEST FAIL (14): a save reading an id no restore declares must be named" >&2; failures=1; }

  if (( failures )); then
    echo "${SCRIPT_NAME}: SELF-TEST FAILED" >&2
    return 1
  fi
  if (( ran != SELF_TEST_FIXTURES )); then
    echo "${SCRIPT_NAME}: SELF-TEST FAILED — ran ${ran} fixture(s), expected exactly ${SELF_TEST_FIXTURES}; a fixture was added or removed without moving the pin" >&2
    return 1
  fi
  echo "${SCRIPT_NAME}: self-test passed (${ran}/${SELF_TEST_FIXTURES} fixtures: a hardened lane passes; a building job with no cache, one whose restore lands after its build, a bare \`flutter build apk\`, a non-canonical key, a second writer and a save without if: success() are each caught and named; a bare build quoted in a COMMENT is prose and passes, which is what makes the bare-build case about code; an exemption is honoured only when it carries a reason; a writer that saves the wrong key, or a step pointed at the wrong path, is caught too; and C6 catches each half on its own — a restore capped but not fail-open, and one fail-open but uncapped — while a save spelling the canonical output expression over a restore that declares no matching id is caught as the dangling reference it is)."
  return 0
}

if [[ "${1:-}" == "--self-test" && $# -eq 1 ]]; then
  run_self_test
  exit $?
fi

if [[ $# -ne 0 ]]; then
  echo "usage: ${SCRIPT_NAME} [--self-test]" >&2
  exit "${RC_BROKEN}"
fi

readonly WORKFLOW_DIR=".github/workflows"
if [[ ! -d "${WORKFLOW_DIR}" ]]; then
  echo "${SCRIPT_NAME}: ${WORKFLOW_DIR} not found — run from the repo root." >&2
  exit "${RC_BROKEN}"
fi

log "checking Gradle build hardening in ${WORKFLOW_DIR}"
check_repo "${WORKFLOW_DIR}"
