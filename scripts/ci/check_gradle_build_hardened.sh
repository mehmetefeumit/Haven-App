#!/usr/bin/env bash
# CI guard: every Gradle build in CI builds OFFLINE from the run's verified
# dependency set, through the classified retry.
#
# # The invariant
#
# Every workflow job that runs a Gradle-backed build
#   G1  fetches this run's set ("Fetch this run's Gradle dependencies", the
#       `gradle-deps` artifact) and installs it ("Install this run's Gradle
#       dependencies", scripts/ci/gradle_deps.sh unpack), in that order,
#       textually BEFORE its Setup Flutter step and its first build site;
#   G2  pins Setup Flutter to the version the set was resolved with
#       (`flutter-version: ${{ env.HAVEN_FLUTTER_VERSION }}`);
#   G3  sets `HAVEN_GRADLE_OFFLINE: "1"` on every step that builds;
#   C3  reaches Gradle through scripts/ci/build_apk_with_retry.sh (or a
#       builder that funnels into it), never a bare `flutter build apk`,
#       `flutter build appbundle` or `gradlew`;
# and, across the workflows,
#   G4  every job that CALLS a workflow holding such a job `needs:` a job of
#       its own file that calls android-gradle-deps.yml, every such deps job
#       grants `contents: read` and `actions: read`, and a workflow holding
#       such a job is reached through `workflow_call` alone (a trigger of its
#       own would run its build in a run no deps job served);
#   G5  no step caches ~/.gradle (the evicted cache this replaced), exactly one
#       step anywhere uploads `gradle-deps`, and every fetch and install step
#       carries a `timeout-minutes` and is never `continue-on-error`;
#   G6  release-build.yml names neither HAVEN_GRADLE_OFFLINE nor
#       scripts/ci/gradle_deps.sh in code, at any level, and downloads no
#       `gradle-deps*` artifact: it builds what it signs online, from no set;
#   C7  every script under tooling/ that reaches build_apk_with_retry.sh or runs
#       `flutter build apk` is in BUILDERS, or says why CI never reaches its
#       build, so a workflow step that runs it is seen as a build;
#   C8  every line two spaces deep under `jobs:` is a job key this guard can
#       read, so no job escapes the checks by its spelling.
#
# # Why
#
# The lanes used to resolve their classpath over the network at build time
# from an actions/cache that GitHub evicted before nearly every main run (the
# repository's cache set is far over 10 GB, and the one writer saved after the
# lanes had started), so a Plugin Portal blip on `org.gradle.kotlin.kotlin-dsl`
# failed whichever lane drew it at "Build E2E test APK" (CI runs 45142774793,
# 45012283370). android-gradle-deps.yml now resolves the run's set once and
# proves it complete offline; a lane that skipped the fetch, built online, ran
# a Flutter other than the set's, or ran in a run with no deps job would bring
# the network — or a miss — back to every lane it was copied into, and read in
# review exactly like one that does not. Hence a check, not a convention.
#
# Fail-closed by design: the fetch is never `continue-on-error`, because a lane
# without its set cannot build offline, and a failed deps job must turn the run
# red (scripts/ci/check_all_jobs_passed.sh), never into a quietly online build.
#
# # Exemptions
#
# A job may opt out ONLY with a reason, on a comment line of its own inside its
# block (the token quoted in prose exempts nothing):
#
#     # HAVEN_GRADLE_DEPS-EXEMPT: <why this job takes no dependency set>
#
# On a building job it exempts G1-G3 (release-build.yml's `android`, which
# signs what it builds); on a calling job, G4 (release-build.yml's launch gate
# call, which hands the gate APKs and builds nothing); in a tooling script, C7
# (a local run's fallback build that CI never reaches). An exempt building job
# still builds through the wrapper (C3). The reason is mandatory (C5).
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
#   1  a job violates G1-G6 or C3-C8
#   2  expected paths missing, or the self-test failed

set -euo pipefail

readonly SCRIPT_NAME="check_gradle_build_hardened.sh"
readonly RC_BROKEN=2

readonly FETCH_STEP="Fetch this run's Gradle dependencies"
readonly INSTALL_STEP="Install this run's Gradle dependencies"
readonly FLUTTER_STEP="Setup Flutter"
readonly EXEMPT_TOKEN="HAVEN_GRADLE_DEPS-EXEMPT:"
readonly DEPS_WORKFLOW="android-gradle-deps.yml"
readonly ARTIFACT="gradle-deps"
readonly PIN="\${{ env.HAVEN_FLUTTER_VERSION }}"

# A Gradle-backed build site: the wrapper itself, or one of the checked-in
# builders that funnels into it. Listed literally rather than matched loosely,
# and C7 holds the list complete: a script under tooling/ that reaches the
# wrapper or runs `flutter build apk` must be named here (or carry a reasoned
# exemption), so a NEW builder cannot escape G1/G3 by its name; a workflow that
# builds through anything else is a bare build (C3).
#
# `build_release.sh` counts only for its ANDROID artifacts. The same script
# builds the iOS `ipa` through Xcode, which resolves no Maven dependency.
#
# `[.]` rather than `\.`: the pattern crosses into awk through `-v`, which
# processes escape sequences first, so `\.` arrives as a bare `.` AND warns on
# the way (gawk does; mawk silently differs). A bracket expression means the
# same thing to both and survives the hand-off intact.
readonly BUILDERS=(build_apk_with_retry.sh build-integration-apks.sh build-b3-real-gps-apk.sh build-kp-rotation-apk.sh)
BUILD_SITE_RE="$(printf '%s|' "${BUILDERS[@]//./[.]}")build_release[.]sh (apk|appbundle)"
readonly BUILD_SITE_RE

# A build that does NOT go through the wrapper: Flutter's Android builds and
# Gradle itself. The iOS lanes build through `flutter test integration_test/`,
# which is not Gradle.
readonly BARE_BUILD_RE='flutter build (apk|appbundle)|gradlew'

log()  { printf '[%s] %s\n' "${SCRIPT_NAME}" "$*"; }
fail() { printf '[%s] FAIL: %s\n' "${SCRIPT_NAME}" "$*" >&2; violations=$(( violations + 1 )); }

# Emits one TAB-separated record per interesting line:
#   <job>\t<lineno>\t<kind>\t<payload>
# kinds: build, bare, exempt, step (payload: step name), step-uses, step-timeout,
#        step-coe, step-offline (payload: value), step-pin (payload: value),
#        step-artifact (payload: value), step-unpack, gradle-cache, job-uses,
#        job-need (payload: job key), job-perm-actions-read, job-perm-contents-read,
#        trigger (payload: event; job is empty)
#
# Full-line comments are dropped before anything but the exemption is read: a
# workflow's prose legitimately quotes `flutter build apk`, and a guard that
# reads prose as code is a guard that reports the comment.
scan_workflow() {
  awk -v build_re="${BUILD_SITE_RE}" -v bare_re="${BARE_BUILD_RE}" -v exempt_tok="${EXEMPT_TOKEN}" '
    function emit(kind, payload) { printf "%s\t%d\t%s\t%s\n", (job == "" ? "-" : job), NR, kind, payload }
    # A value without its key, a trailing ` # comment` or its quotes.
    function val(line) { sub(/^[^:]*:[[:space:]]*/, "", line); sub(/[[:space:]]+#.*$/, "", line); gsub(/[[:space:]]+$/, "", line); gsub(/^["\047]|["\047]$/, "", line); return line }
    function trigger_list(list,   k, a, i) { gsub(/[][[:space:]"\047]/, "", list); k = split(list, a, ","); for (i = 1; i <= k; i++) if (a[i] != "") { job = "-"; emit("trigger", a[i]) } }
    # `on:` in every spelling YAML allows here: a block of keys or of `- x`
    # items, an inline list, one event, a trailing comment.
    /^["\047]?on["\047]?:/ {
      rest = $0; sub(/^[^:]*:[[:space:]]*/, "", rest); sub(/[[:space:]]*#.*$/, "", rest)
      if (rest == "") inon = 1; else trigger_list(rest)
      next
    }
    inon && /^  - / { t = $0; sub(/^  - /, "", t); sub(/[[:space:]]*#.*$/, "", t); trigger_list(t); next }
    inon && /^  ["\047]?[A-Za-z_]+["\047]?:/ { t = $1; sub(/:.*/, "", t); gsub(/["\047]/, "", t); job = "-"; emit("trigger", t); next }
    inon && /^[^[:space:]#]/ { inon = 0 }
    /^jobs:[[:space:]]*(#.*)?$/ { injobs = 1; job = ""; next }
    injobs && /^[^[:space:]#]/ { injobs = 0; job = "" }
    # Every line two spaces deep under `jobs:` is a job key, quoted or with a
    # comment after it, or the guard cannot read the file and says so.
    injobs && /^  [^[:space:]#]/ {
      k = $0; sub(/^  /, "", k); sub(/[[:space:]]+#.*$/, "", k); sub(/[[:space:]]+$/, "", k)
      if (k ~ /^["\047]?[A-Za-z0-9_-]+["\047]?:$/) {
        sub(/:$/, "", k); gsub(/["\047]/, "", k)
        job = k; instep = 0; insteps = 0; inneeds = 0; inperm = 0; inpath = 0
      } else { job = "-"; emit("unparsed", $0); job = "" }
      next
    }
    # The exemption is a comment of its own, never the token quoted in prose.
    match($0, /^[[:space:]]*#[[:space:]]*/) && substr($0, RLENGTH + 1, length(exempt_tok)) == exempt_tok {
      reason = substr($0, RLENGTH + 1 + length(exempt_tok))
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", reason)
      emit("exempt", reason)
    }
    { raw = $0 }
    /^[[:space:]]*#/ { next }
    /HAVEN_GRADLE_OFFLINE/ { emit("any-offline", "") }
    /gradle_deps[.]sh/ { emit("any-gradle-deps-sh", "") }
    injobs && job != "" {
      if ($0 ~ /^    [^[:space:]#]/) { inneeds = 0; inperm = 0; insteps = 0; instep = 0 }
      if ($0 ~ /^    needs:[[:space:]]*\[/) {
        n = $0; sub(/^[^\[]*\[/, "", n); sub(/\].*$/, "", n); gsub(/[[:space:]"\047]/, "", n)
        k = split(n, a, ","); for (i = 1; i <= k; i++) if (a[i] != "") emit("job-need", a[i])
      } else if ($0 ~ /^    needs:[[:space:]]*(#.*)?$/) { inneeds = 1 }
      else if ($0 ~ /^    needs:/) { emit("job-need", val($0)) }
      else if (inneeds && $0 ~ /^      - /) { n = $0; sub(/^      - /, "", n); emit("job-need", val("x: " n)) }
      if ($0 ~ /^    permissions:[[:space:]]*(#.*)?$/) inperm = 1
      if (inperm && $0 ~ /^      actions:/ && val($0) == "read") emit("job-perm-actions-read", "")
      if (inperm && $0 ~ /^      contents:/ && val($0) == "read") emit("job-perm-contents-read", "")
      if ($0 ~ /^    uses:/) emit("job-uses", val($0))
      if ($0 ~ /^    steps:/) insteps = 1
      # Any `- ` item starts a step, named or not, so an unnamed step never
      # inherits the one before it. Its first key moves to the key column.
      if (insteps && $0 ~ /^      - /) {
        instep = 1; inpath = 0
        emit("step", "")
        $0 = "        " substr($0, 9)
      }
      if (instep) {
        if ($0 ~ /^        name:/) emit("step-name", val($0))
        if ($0 ~ /^        uses:/) emit("step-uses", val($0))
        if ($0 ~ /^        timeout-minutes:[[:space:]]*[0-9]+[[:space:]]*(#.*)?$/) emit("step-timeout", "")
        if ($0 ~ /^        continue-on-error:/) emit("step-coe", val($0))
        if ($0 ~ /^          HAVEN_GRADLE_OFFLINE:/) emit("step-offline", val($0))
        if ($0 ~ /^          flutter-version:/) emit("step-pin", val($0))
        if ($0 ~ /^          name:/) emit("step-artifact", val($0))
        if ($0 ~ /^          pattern:/) emit("step-pattern", val($0))
        if ($0 ~ /scripts\/ci\/gradle_deps[.]sh unpack /) emit("step-unpack", "")
        if ($0 ~ /^          path:/) inpath = 1
        else if ($0 ~ /^          [A-Za-z-]+:/) inpath = 0
        if ((inpath || $0 ~ /^          path:/) && $0 ~ /~\/[.]gradle|[$][{]?HOME[}]?\/[.]gradle/) emit("gradle-cache-path", "")
      }
      # A `--self-test` names a build script without performing a build.
      if (raw !~ /--self-test/) {
        if (raw ~ build_re) emit("build", raw)
        else if (raw ~ bare_re) emit("bare", raw)
      }
    }
  ' "$1"
}

# check_builders <tooling dir> — C7.
check_builders() {
  local f base known b code
  while IFS= read -r f; do
    base="$(basename "${f}")"
    # Into a variable, then a here-string: a `grep -q` at the end of a pipe
    # exits on its first match, the grep feeding it dies of SIGPIPE on a large
    # script, and pipefail turns a found build into "not a builder".
    code="$(grep -vE '^[[:space:]]*#' "${f}" | grep -v -- '--self-test' || true)"
    grep -qE 'build_apk_with_retry[.]sh|(^|&&|\()[[:space:]]*flutter build (apk|appbundle)' <<<"${code}" || continue
    known=0
    for b in "${BUILDERS[@]}"; do [[ "${base}" == "${b}" ]] && known=1; done
    (( known )) && continue
    if grep -qE "^[[:space:]]*#[[:space:]]*${EXEMPT_TOKEN}[[:space:]]*[^[:space:]]" "${f}"; then continue; fi
    fail "C7 ${f}: builds the app (it reaches build_apk_with_retry.sh or runs flutter build apk) but is not in BUILDERS, so a workflow step that runs it is not seen as a build and escapes G1 and G3. Add it to BUILDERS, or give it a '# ${EXEMPT_TOKEN} <reason>' line if CI never reaches its build."
  done < <(find "$1" -type f -name '*.sh' 2>/dev/null | sort)
}

check_repo() { # $1 = workflow dir, $2 = tooling dir
  local dir="$1" f base rec job lineno kind payload
  local -a records
  violations=0
  local total_jobs=0 uploaders=0 checked_files=0
  local -A building_files=() file_records=()

  # Pass 1: per job, G1-G3, C3, C5, G5's per-step half.
  for f in "${dir}"/*.yml; do
    [[ -e "${f}" ]] || continue
    base="$(basename "${f}")"
    checked_files=$(( checked_files + 1 ))
    # Materialise: under `pipefail` a producer read by a short-lived consumer
    # fails OPEN, and "open" here means a workflow reported as having no builds.
    mapfile -t records < <(scan_workflow "${f}")
    file_records["${base}"]="$(printf '%s\n' "${records[@]}")"

    local -A first_build=() exempt=() fetch_at=() install_at=() flutter_at=() pinned=() building_step=()
    local -A step_name=() step_kind=() step_uses=() step_timeout=() step_coe=() step_offline=() step_artifact=() step_pattern=() step_unpack=() step_cache=()
    local cur=""
    for rec in "${records[@]}"; do
      [[ -n "${rec}" ]] || continue
      IFS=$'\t' read -r job lineno kind payload <<<"${rec}"
      case "${kind}" in
        step)          cur="${job}:${lineno}"; step_name["${cur}"]="" ;;
        step-name)
          step_name["${cur}"]="${payload}"
          [[ "${payload}" == "${FETCH_STEP}" && -z "${fetch_at[${job}]:-}" ]] && fetch_at["${job}"]="${cur##*:}"
          [[ "${payload}" == "${INSTALL_STEP}" && -z "${install_at[${job}]:-}" ]] && install_at["${job}"]="${cur##*:}"
          [[ "${payload}" == "${FLUTTER_STEP}" && -z "${flutter_at[${job}]:-}" ]] && flutter_at["${job}"]="${cur##*:}"
          ;;
        unparsed)
          fail "C8 ${base} line ${lineno}: '${payload}' sits where a job key belongs and is not one this guard can read, so the job under it would escape every check. Write it as \`  <key>:\`."
          ;;
        step-uses)     step_uses["${cur}"]="${payload}" ;;
        step-timeout)  step_timeout["${cur}"]=1 ;;
        step-coe)      step_coe["${cur}"]="${payload}" ;;
        step-offline)  step_offline["${cur}"]="${payload}" ;;
        step-artifact) step_artifact["${cur}"]="${payload}" ;;
        step-pattern)  step_pattern["${cur}"]="${payload}" ;;
        step-unpack)   step_unpack["${cur}"]=1 ;;
        gradle-cache-path) step_cache["${cur}"]=1 ;;
        step-pin)
          if [[ "${step_name[${cur}]:-}" == "${FLUTTER_STEP}" && "${payload}" == "${PIN}" ]]; then pinned["${job}"]=1; fi
          ;;
        build|bare)
          [[ -n "${first_build[${job}]:-}" ]] || first_build["${job}"]="${lineno}"
          [[ -n "${cur}" && "${cur%%:*}" == "${job}" ]] && building_step["${cur}"]=1
          if [[ "${kind}" == "bare" ]]; then
            fail "C3 ${base} :: ${job} line ${lineno}: builds with a bare \`flutter build apk\`, \`flutter build appbundle\` or \`gradlew\`. Every Gradle build must go through scripts/ci/build_apk_with_retry.sh (or a builder listed in BUILDERS), which installs the offline switch, classifies a failure and never retries a gap, a compile error or a full disk."
          fi
          ;;
        exempt)
          if [[ -z "${payload}" ]]; then
            fail "C5 ${base} line ${lineno}: a ${EXEMPT_TOKEN} with no reason. An exemption has to be a sentence a reviewer can disagree with."
          else
            exempt["${job}"]=1
          fi
          ;;
      esac
    done

    local s
    for s in "${!step_name[@]}"; do
      job="${s%%:*}"
      if [[ -n "${step_cache[${s}]:-}" && "${step_uses[${s}]:-}" == actions/cache* ]]; then
        fail "G5 ${base} :: ${job} line ${s##*:}: '${step_name[${s}]}' caches ~/.gradle. That is the evicted cache this run's verified set replaced; a lane builds offline from \`${ARTIFACT}\` alone."
      fi
      if [[ "${step_uses[${s}]:-}" == actions/upload-artifact* && "${step_artifact[${s}]:-}" == "${ARTIFACT}" ]]; then
        uploaders=$(( uploaders + 1 ))
      fi
      if [[ "${step_name[${s}]}" == "${FETCH_STEP}" || "${step_name[${s}]}" == "${INSTALL_STEP}" ]]; then
        [[ -n "${step_timeout[${s}]:-}" ]] || fail "G5 ${base} :: ${job} line ${s##*:}: '${step_name[${s}]}' has no \`timeout-minutes\`, so a stalled artifact service holds the lane for its whole job cap."
        [[ -z "${step_coe[${s}]:-}" ]] || fail "G5 ${base} :: ${job} line ${s##*:}: '${step_name[${s}]}' is \`continue-on-error\`. A lane without its set cannot build offline: it must fail here, not build online or miss later."
      fi
      if [[ "${step_name[${s}]}" == "${FETCH_STEP}" ]] \
         && { [[ "${step_uses[${s}]:-}" != actions/download-artifact@* ]] || [[ "${step_artifact[${s}]:-}" != "${ARTIFACT}" ]]; }; then
        fail "G1 ${base} :: ${job} line ${s##*:}: '${FETCH_STEP}' must download the \`${ARTIFACT}\` artifact with actions/download-artifact."
      fi
      if [[ "${step_name[${s}]}" == "${INSTALL_STEP}" && -z "${step_unpack[${s}]:-}" ]]; then
        fail "G1 ${base} :: ${job} line ${s##*:}: '${INSTALL_STEP}' must run scripts/ci/gradle_deps.sh unpack."
      fi
      if [[ "${base}" == release-build.yml && "${step_uses[${s}]:-}" == actions/download-artifact* ]] \
         && [[ "${step_artifact[${s}]:-}" == "${ARTIFACT}"* || "${step_pattern[${s}]:-}" == "${ARTIFACT}"* ]]; then
        fail "G6 release-build.yml :: ${job} line ${s##*:}: downloads a \`${ARTIFACT}\` artifact. The release builds what it signs online, from no set (its ${EXEMPT_TOKEN} reason)."
      fi
    done

    for job in "${!first_build[@]}"; do
      total_jobs=$(( total_jobs + 1 ))
      [[ -n "${exempt[${job}]:-}" ]] && continue
      building_files["${base}"]=1
      if [[ -z "${fetch_at[${job}]:-}" || -z "${install_at[${job}]:-}" ]]; then
        fail "G1 ${base} :: ${job}: builds the app (line ${first_build[${job}]}) without both '${FETCH_STEP}' and '${INSTALL_STEP}'. Without the run's verified set a lane resolves over the network, which is what failed lanes at the build (CI runs 45142774793, 45012283370)."
      else
        (( fetch_at["${job}"] < install_at["${job}"] )) \
          || fail "G1 ${base} :: ${job}: '${INSTALL_STEP}' (line ${install_at[${job}]}) runs before '${FETCH_STEP}' (line ${fetch_at[${job}]}): it would install nothing."
        (( install_at["${job}"] < first_build["${job}"] )) \
          || fail "G1 ${base} :: ${job}: installs the set at line ${install_at[${job}]}, AFTER its first build at line ${first_build[${job}]}."
        if [[ -z "${flutter_at[${job}]:-}" ]] || (( install_at["${job}"] > flutter_at["${job}"] )); then
          fail "G1 ${base} :: ${job}: the set must be installed before '${FLUTTER_STEP}', which reads the Flutter version it was resolved with."
        fi
      fi
      [[ -n "${pinned[${job}]:-}" ]] \
        || fail "G2 ${base} :: ${job}: '${FLUTTER_STEP}' must pin \`flutter-version: ${PIN}\`. flutter_tools' own build and the engine jars follow the Flutter revision, so another Flutter builds against coordinates the set does not hold."
      for s in "${!building_step[@]}"; do
        [[ "${s%%:*}" == "${job}" ]] || continue
        [[ "${step_offline[${s}]:-}" == 1 ]] \
          || fail "G3 ${base} :: ${job} line ${s##*:}: '${step_name[${s}]}' builds without \`HAVEN_GRADLE_OFFLINE: \"1\"\`. Online, a lane meets the network the run's set exists to keep it from."
      done
    done
    unset first_build exempt fetch_at install_at flutter_at pinned building_step
    unset step_name step_kind step_uses step_timeout step_coe step_offline step_artifact step_pattern step_unpack step_cache
  done

  # Pass 2: G4 and G6 across the workflows.
  local -A deps_jobs=() needs=() uses_of=() exempt_job=() perm_actions=() perm_contents=() triggers=()
  for base in "${!file_records[@]}"; do
    while IFS=$'\t' read -r job lineno kind payload; do
      [[ -n "${kind:-}" ]] || continue
      case "${kind}" in
        job-uses) uses_of["${base}:${job}"]="${payload}"
                  [[ "${payload}" == "./.github/workflows/${DEPS_WORKFLOW}" ]] && deps_jobs["${base}:${job}"]=1 ;;
        job-need) needs["${base}:${job}"]+=" ${payload} " ;;
        exempt)   [[ -n "${payload}" ]] && exempt_job["${base}:${job}"]=1 ;;
        job-perm-actions-read)  perm_actions["${base}:${job}"]=1 ;;
        job-perm-contents-read) perm_contents["${base}:${job}"]=1 ;;
        trigger)  triggers["${base}"]+=" ${payload} " ;;
        any-offline|any-gradle-deps-sh)
          if [[ "${base}" == release-build.yml ]]; then
            fail "G6 release-build.yml line ${lineno}: names $( [[ "${kind}" == any-offline ]] && echo HAVEN_GRADLE_OFFLINE || echo scripts/ci/gradle_deps.sh ) in code. The release builds what it signs online, from no set (its ${EXEMPT_TOKEN} reason)."
          fi ;;
      esac
    done <<<"${file_records[${base}]}"
  done

  local key target n ok
  for key in "${!deps_jobs[@]}"; do
    if [[ -z "${perm_actions[${key}]:-}" || -z "${perm_contents[${key}]:-}" ]]; then
      fail "G4 ${key%%:*} :: ${key#*:}: calls ${DEPS_WORKFLOW} without granting \`permissions: {contents: read, actions: read}\`. Its job lists and downloads a main run's artifact; without the grant it cannot, and a caller's token may not reach it."
    fi
  done
  for key in "${!uses_of[@]}"; do
    target="${uses_of[${key}]#./.github/workflows/}"
    [[ -n "${building_files[${target}]:-}" ]] || continue
    [[ -n "${exempt_job[${key}]:-}" ]] && continue
    ok=0
    for n in ${needs[${key}]:-}; do
      [[ -n "${deps_jobs[${key%%:*}:${n}]:-}" ]] && ok=1
    done
    (( ok )) || fail "G4 ${key%%:*} :: ${key#*:}: calls ${target}, which builds the app, without \`needs:\` on a job of this file that calls ${DEPS_WORKFLOW}. Its build would find no \`${ARTIFACT}\` artifact in the run."
  done
  for base in "${!building_files[@]}"; do
    for n in ${triggers[${base}]:-}; do
      [[ "${n}" == workflow_call ]] && continue
      fail "G4 ${base}: builds the app and is triggered by \`${n}\`. Only a caller can give its run the deps job a build needs; trigger it through a wrapper that calls ${DEPS_WORKFLOW} first (as launch-gate-android-dispatch.yml does)."
    done
  done

  check_builders "${2}"

  if (( uploaders != 1 )); then
    fail "G5 ${uploaders} step(s) upload the \`${ARTIFACT}\` artifact; there must be exactly ONE, ${DEPS_WORKFLOW}'s, so no lane can publish a set nobody verified."
  fi

  if (( violations )); then
    printf '[%s] FAIL: %d violation(s).\n' "${SCRIPT_NAME}" "${violations}" >&2
    return 1
  fi
  log "OK — ${checked_files} workflow(s), ${total_jobs} Gradle-building job(s): each fetches and installs the run's verified set before Setup Flutter and its first build, pins the set's Flutter and builds offline through the classified retry; every caller needs the deps job, which one step uploads; nothing caches ~/.gradle."
  return 0
}

# ---------------------------------------------------------------------------
# Self-test: hermetic workflow fixtures in a temp dir. Each negative differs
# from the positive by exactly the property under test.
# ---------------------------------------------------------------------------
readonly SELF_TEST_FIXTURES=39

emit_fetch() {
  cat <<EOF
      - name: ${FETCH_STEP}
        timeout-minutes: 5
        uses: actions/download-artifact@v6
        with:
          name: ${ARTIFACT}
          path: \${{ runner.temp }}/gradle-deps
      - name: ${INSTALL_STEP}
        timeout-minutes: 2
        run: bash scripts/ci/gradle_deps.sh unpack "\${RUNNER_TEMP}/gradle-deps"
EOF
}

emit_flutter() { # [pin]
  cat <<EOF
      - name: ${FLUTTER_STEP}
        uses: subosito/flutter-action@v2
        with:
          channel: stable
          flutter-version: ${1-${PIN}}
EOF
}

emit_build() { # [offline value]
  cat <<EOF
      - name: Build
        env:
          HAVEN_GRADLE_OFFLINE: "${1-1}"
        run: bash ../tooling/e2e/ci/build-integration-apks.sh
EOF
}

# The deps workflow (the one uploader) and a caller that needs it, so a fixture
# can vary the BUILDING workflow alone.
write_base() { # <dir>
  { echo "name: D"; echo "on:"; echo "  workflow_call:"; echo "jobs:"; echo "  resolve:"; echo "    runs-on: ubuntu-latest"
    echo "    steps:"; echo "      - name: Upload"; echo "        uses: actions/upload-artifact@v6"; echo "        with:"
    echo "          name: ${ARTIFACT}"; echo "          path: x"; } > "$1/${DEPS_WORKFLOW}"
  { echo "name: CI"; echo "on:"; echo "  push:"; echo "jobs:"; echo "  gradle-deps:"; echo "    permissions:"
    echo "      contents: read"; echo "      actions: read"; echo "    uses: ./.github/workflows/${DEPS_WORKFLOW}"
    echo "  lane:"; echo "    needs: [rust, gradle-deps]"; echo "    uses: ./.github/workflows/a.yml"; } > "$1/ci.yml"
}

write_lane() { # <dir> <steps...as one string>
  { echo "name: A"; echo "on:"; echo "  workflow_call:"; echo "jobs:"; echo "  lane:"; echo "    runs-on: ubuntu-latest"
    echo "    steps:"; printf '%s\n' "$2"; } > "$1/a.yml"
}

run_self_test() {
  local tmp ran=0 failures=0 d out
  tmp="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf '${tmp}'" EXIT

  _case() { # <label> <expect-rc> <dir> [must-say]
    local label="$1" want="$2" dir="$3" say="${4:-}" got=0
    ran=$(( ran + 1 ))
    out="$(check_repo "${dir}" "${dir}/tooling" 2>&1)" || got=$?
    if (( got != want )) || [[ -n "${say}" && "${out}" != *"${say}"* ]]; then
      echo "SELF-TEST FAIL (${label}): expected rc ${want}${say:+ saying '${say}'}, got ${got}" >&2
      echo "${out}" | sed 's/^/    /' >&2
      failures=1
    fi
  }
  _new() { d="${tmp}/$1"; mkdir -p "${d}"; write_base "${d}"; }
  local good
  good="$(emit_fetch)
$(emit_flutter)
$(emit_build)"

  _new ok; write_lane "${d}" "${good}"
  _case "the hardened shape passes" 0 "${d}"

  _new nofetch; write_lane "${d}" "$(emit_flutter)
$(emit_build)"
  _case "a building job with no fetch" 1 "${d}" "G1"

  _new lateflutter; write_lane "${d}" "$(emit_flutter)
$(emit_fetch)
$(emit_build)"
  _case "the set installed after Setup Flutter" 1 "${d}" "before '${FLUTTER_STEP}'"

  _new latebuild; write_lane "${d}" "$(emit_flutter)
$(emit_build)
$(emit_fetch)"
  _case "the set installed after the build" 1 "${d}" "AFTER its first build"

  _new noinstall; write_lane "${d}" "$(emit_fetch | sed "/name: ${INSTALL_STEP}/,\$d")
$(emit_flutter)
$(emit_build)"
  _case "a fetch with no install" 1 "${d}" "G1"

  _new wrongart; write_lane "${d}" "$(emit_fetch | sed "s/name: ${ARTIFACT}$/name: something-else/")
$(emit_flutter)
$(emit_build)"
  _case "a fetch of another artifact" 1 "${d}" "must download the"

  _new nopin; write_lane "${d}" "$(emit_fetch)
$(emit_flutter "3.50.1")
$(emit_build)"
  _case "Setup Flutter pinned to a literal instead of the set's version" 1 "${d}" "G2"

  _new online; write_lane "${d}" "$(emit_fetch)
$(emit_flutter)
      - name: Build
        run: bash ../tooling/e2e/ci/build-integration-apks.sh"
  _case "a build without HAVEN_GRADLE_OFFLINE" 1 "${d}" "G3"

  _new offtrue; write_lane "${d}" "$(emit_fetch)
$(emit_flutter)
$(emit_build true)"
  _case "HAVEN_GRADLE_OFFLINE: \"true\" is not offline" 1 "${d}" "G3"

  _new noneeds; write_lane "${d}" "${good}"; sed -i 's/    needs: \[rust, gradle-deps\]/    needs: [rust]/' "${d}/ci.yml"
  _case "a caller that does not need the deps job" 1 "${d}" "G4 ci.yml :: lane"

  _new wrongneed; write_lane "${d}" "${good}"
  sed -i 's|    uses: ./.github/workflows/'"${DEPS_WORKFLOW}"'|    uses: ./.github/workflows/other.yml|' "${d}/ci.yml"
  _case "a caller needing a job that is not the deps job" 1 "${d}" "G4 ci.yml :: lane"

  _new noperm; write_lane "${d}" "${good}"; sed -i '/      actions: read/d' "${d}/ci.yml"
  _case "a deps call without actions: read" 1 "${d}" "actions: read"

  _new dispatch; write_lane "${d}" "${good}"; sed -i 's/^  workflow_call:$/  workflow_call:\n  workflow_dispatch:/' "${d}/a.yml"
  _case "a building workflow with a trigger of its own" 1 "${d}" "workflow_dispatch"

  _new callexempt; write_lane "${d}" "${good}"
  sed -i 's/    needs: \[rust, gradle-deps\]/    # '"${EXEMPT_TOKEN}"' it hands the lane APKs and builds nothing.\n    needs: [rust]/' "${d}/ci.yml"
  _case "a caller exemption with a reason is honoured" 0 "${d}"

  _new cache; write_lane "${d}" "      - name: Restore Gradle dependency cache
        uses: actions/cache/restore@v4
        with:
          path: |
            ~/.gradle/caches/modules-2
          key: k
${good}"
  _case "a step caching ~/.gradle" 1 "${d}" "G5"

  _new twouploads; write_lane "${d}" "${good}
      - name: Upload
        uses: actions/upload-artifact@v6
        with:
          name: ${ARTIFACT}
          path: x"
  _case "a second uploader of the set" 1 "${d}" "exactly ONE"

  _new coe; write_lane "${d}" "$(emit_fetch | sed 's/^        timeout-minutes: 5$/        timeout-minutes: 5\n        continue-on-error: true/')
$(emit_flutter)
$(emit_build)"
  _case "a fail-open fetch" 1 "${d}" "continue-on-error"

  _new nocap; write_lane "${d}" "$(emit_fetch | sed '/timeout-minutes: 2$/d')
$(emit_flutter)
$(emit_build)"
  _case "an uncapped install" 1 "${d}" "timeout-minutes"

  _new bare; write_lane "${d}" "$(emit_fetch)
$(emit_flutter)
      - name: Build
        env:
          HAVEN_GRADLE_OFFLINE: \"1\"
        run: flutter build apk --debug"
  _case "a bare flutter build apk" 1 "${d}" "C3"

  # CONTROL for the one above: the same bare build inside a COMMENT is prose.
  _new prose; write_lane "${d}" "$(emit_fetch)
$(emit_flutter)
      # \`flutter build apk\` peaks at several GB, so we build first.
$(emit_build)"
  _case "a bare build quoted in a comment is prose" 0 "${d}"

  _new exemptblank; write_lane "${d}" "      # ${EXEMPT_TOKEN}
      - name: Build
        run: bash ../tooling/e2e/ci/build-integration-apks.sh"
  _case "an exemption with no reason" 1 "${d}" "no reason"

  _new release; write_lane "${d}" "${good}"
  { echo "name: R"; echo "on:"; echo "  push:"; echo "jobs:"; echo "  android:"; echo "    # ${EXEMPT_TOKEN} signs what it builds."
    echo "    runs-on: ubuntu-latest"; echo "    steps:"; echo "      - name: Build release APKs"; echo "        env:"
    echo "          HAVEN_GRADLE_OFFLINE: \"1\""; echo "        run: bash ../scripts/build_release.sh apk"; } > "${d}/release-build.yml"
  _case "release-build.yml setting HAVEN_GRADLE_OFFLINE" 1 "${d}" "G6"

  # ---- Parsing, each fixture a spelling that once escaped every check.

  _new keycomment; write_lane "${d}" "$(emit_flutter)
$(emit_build)"; sed -i 's/^  lane:$/  lane: # the lane/' "${d}/a.yml"
  _case "a job key with a trailing comment is still checked" 1 "${d}" "G1 a.yml :: lane"

  _new keyquoted; write_lane "${d}" "$(emit_flutter)
$(emit_build)"; sed -i 's/^  lane:$/  "lane":/' "${d}/a.yml"
  _case "a quoted job key is still checked" 1 "${d}" "G1 a.yml :: lane"

  _new keyflow; write_lane "${d}" "${good}"; printf '  other: {runs-on: ubuntu-latest}\n' >> "${d}/a.yml"
  _case "a line under jobs: that is no readable key fails closed" 1 "${d}" "C8"

  _new unnamed; write_lane "${d}" "$(emit_fetch)
$(emit_flutter)
      - name: Prepare
        env:
          HAVEN_GRADLE_OFFLINE: \"1\"
        run: true
      - run: bash ../tooling/e2e/ci/build-integration-apks.sh"
  _case "an unnamed build step does not borrow the step before it" 1 "${d}" "G3"

  _new prosetoken; write_lane "${d}" "      # A job takes the ${EXEMPT_TOKEN} token only with a reason.
$(emit_flutter)
$(emit_build)"
  _case "the exemption token quoted in prose exempts nothing" 1 "${d}" "G1"

  _new trailing; write_lane "${d}" "$(emit_fetch | sed "s/^      - name: ${FETCH_STEP}$/      - name: ${FETCH_STEP} # from the deps job/; s|^        uses: actions/download-artifact@v6$|        uses: actions/download-artifact@v6 # pinned by tag|")
$(emit_flutter)
$(emit_build)"
  _case "trailing comments on a step's name and uses are read through" 0 "${d}"

  _new inlinetrig; write_lane "${d}" "${good}"; sed -i '/^on:$/,/^  workflow_call:$/c on: [workflow_call, workflow_dispatch]' "${d}/a.yml"
  _case "an inline trigger list is read" 1 "${d}" "workflow_dispatch"

  _new commenttrig; write_lane "${d}" "${good}"; sed -i 's/^on:$/on: # triggers/; s/^  workflow_call:$/  workflow_call:\n  workflow_dispatch:/' "${d}/a.yml"
  _case "a trigger block opened with a comment is read" 1 "${d}" "workflow_dispatch"

  # G6, one fixture per spelling of a release that would build from a set.
  local g6
  for g6 in jobenv runprefix depsscript download pattern; do
    _new "g6-${g6}"; write_lane "${d}" "${good}"
    {
      echo "name: R"; echo "on:"; echo "  push:"; echo "jobs:"; echo "  android:"; echo "    # ${EXEMPT_TOKEN} signs what it builds."
      echo "    runs-on: ubuntu-latest"
      [[ "${g6}" == jobenv ]] && { echo "    env:"; echo "      HAVEN_GRADLE_OFFLINE: \"1\""; }
      echo "    steps:"
      [[ "${g6}" == download ]] && { echo "      - uses: actions/download-artifact@v6"; echo "        with:"; echo "          name: ${ARTIFACT}-src-k"; }
      [[ "${g6}" == pattern ]] && { echo "      - uses: actions/download-artifact@v6"; echo "        with:"; echo "          pattern: ${ARTIFACT}*"; }
      [[ "${g6}" == depsscript ]] && { echo "      - run: bash scripts/ci/gradle_deps.sh unpack x"; }
      echo "      - name: Build release APKs"
      if [[ "${g6}" == runprefix ]]; then echo "        run: HAVEN_GRADLE_OFFLINE=1 bash ../scripts/build_release.sh apk"
      else echo "        run: bash ../scripts/build_release.sh apk"; fi
    } > "${d}/release-build.yml"
    _case "release-build.yml building from a set (${g6})" 1 "${d}" "G6"
  done

  # C3/C7: a build reached by something the guard does not list.
  _new gradlew; write_lane "${d}" "$(emit_fetch)
$(emit_flutter)
      - name: Build
        env:
          HAVEN_GRADLE_OFFLINE: \"1\"
        run: ./gradlew :app:assembleRelease"
  _case "Gradle run directly is a bare build" 1 "${d}" "C3"

  _new newbuilder; write_lane "${d}" "${good}"; mkdir -p "${d}/tooling/e2e/ci"
  printf '#!/usr/bin/env bash\n"${REPO_ROOT}/scripts/ci/build_apk_with_retry.sh" android-x64 --dart-define=HAVEN_LIVE_SYNC=false\n' > "${d}/tooling/e2e/ci/build-new-apk.sh"
  _case "a tooling builder missing from BUILDERS" 1 "${d}" "C7"
  # The same unlisted builder, its build line first and ~256 KB after it, as
  # large as tooling's biggest scripts: a reader that stops early must not
  # let the scan that feeds it die and read as "no build".
  { printf '#!/usr/bin/env bash\n"${REPO_ROOT}/scripts/ci/build_apk_with_retry.sh" android-x64 --dart-define=HAVEN_LIVE_SYNC=false\n'
    printf 'echo "filler line that names no build at all, only to make the script large"\n%.0s' $(seq 3500); } > "${d}/tooling/e2e/ci/build-new-apk.sh"
  (( $(stat -c %s "${d}/tooling/e2e/ci/build-new-apk.sh") > 250000 )) || { echo "SELF-TEST FAIL: the large builder fixture is too small" >&2; failures=1; }
  _case "a large tooling builder missing from BUILDERS" 1 "${d}" "C7"
  # CONTROL: the same script saying why CI never reaches its build.
  printf '#!/usr/bin/env bash\n# %s a local fallback; CI stages the lane'"'"'s APK.\nflutter build apk --debug\n' "${EXEMPT_TOKEN}" > "${d}/tooling/e2e/ci/build-new-apk.sh"
  _case "a tooling build CI never reaches, said so with a reason, passes" 0 "${d}"

  if (( failures )); then
    echo "${SCRIPT_NAME}: SELF-TEST FAILED" >&2
    return 1
  fi
  if (( ran != SELF_TEST_FIXTURES )); then
    echo "${SCRIPT_NAME}: SELF-TEST FAILED — ran ${ran} fixture(s), expected exactly ${SELF_TEST_FIXTURES}; a fixture was added or removed without moving the pin" >&2
    return 1
  fi
  echo "${SCRIPT_NAME}: self-test passed (${ran}/${SELF_TEST_FIXTURES} fixtures: a hardened lane passes; a building job with no fetch, a set installed after Setup Flutter or after the build, a fetch with no install or of another artifact, a Flutter pinned to anything but the set's version, a build online or with HAVEN_GRADLE_OFFLINE other than 1, a caller that does not need the deps job or needs another, a deps call without actions: read, and a building workflow with a trigger of its own are each caught and named; a caller exemption with a reason is honoured and one with none refused; a ~/.gradle cache, a second uploader of the set, a fail-open fetch and an uncapped install are caught; a bare \`flutter build apk\` is caught while the same words in a comment pass; release-build.yml building from a set is caught at job-env level, as a run prefix, through gradle_deps.sh and through a gradle-deps download by name or by pattern; a job key with a comment or quotes is still checked and an unreadable one fails closed, an unnamed build step borrows nothing, the token quoted in prose exempts nothing, trailing comments on name and uses are read through, inline and commented trigger blocks are read, Gradle run directly is bare, and a tooling builder missing from BUILDERS is caught, a 256 KB one too, unless it says why CI never reaches it)."
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
check_repo "${WORKFLOW_DIR}" tooling
