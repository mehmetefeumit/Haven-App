#!/usr/bin/env bash
#
# The Android Gradle dependency set of one CI run: resolved and verified ONCE,
# by android-gradle-deps.yml, and handed to every Android lane of the run as the
# artifact `gradle-deps`, which each lane unpacks and then builds OFFLINE from.
#
# ## Why
#
# Every Android lane used to resolve its Gradle classpath over the network at
# "Build E2E test APK", from a cache that was LRU-evicted before nearly every
# main run (the repository's cache set is far over GitHub's 10 GB, and the one
# writer saved it after the lanes had started). So ~17 lanes resolved cold on
# every run, and a Plugin Portal blip on `org.gradle.kotlin.kotlin-dsl` (which
# only the Portal serves) failed whichever lane drew it (CI runs 45142774793 and
# 45012283370). Now one job per run touches the network, with its own retry
# budget, and a lane cannot meet the network at all: a gap is a classified red
# naming the coordinate (build_apk_with_retry.sh), never a retry.
#
# ## Where the set comes from
#
# A main run (ci.yml on push, e2e-nightly.yml on schedule) uploads what it
# verified as `gradle-deps-src-<key>`, kept 90 days. The next run whose key
# matches downloads that instead of resolving, but only from a run that
# `trusted_run` accepts — never a pull request's, a fork's or another
# workflow's, since a lane builds from these bytes. A source that fails the
# strict offline verification is topped up online and verified again, and the
# completed set is uploaded as a newer source, which `find_source` prefers: an
# incomplete source can never stick. One that does not unpack is resolved from
# an empty cache. No source: resolve online, with a 900 s budget and enough
# attempts that the budget is what ends it.
#
# Whatever the path, the set is accepted only if `havenResolveAll` (every
# resolvable configuration of the composite, non-leniently, plus AGP's aapt2)
# passes with Gradle OFFLINE, and only after the canaries prove, with the
# Gradle the lanes run, that offline really is offline in an included build and
# that a configuration nobody resolves still fails the task, in the top build,
# in an included one and in one included through `pluginManagement` (Flutter's
# shape).
#
# The key covers every input that decides the set: the Flutter framework
# revision (flutter_tools' own build and the engine jars follow it, which is
# also why every lane pins the Flutter version this job recorded), and every
# tracked Gradle file of the app, rust_builder and third_party, the wrapper and
# gradle.properties, pubspec.lock, the three init scripts, the retry wrapper
# that drives the resolution, and this script.
#
# Usage:
#   gradle_deps.sh key            print this tree's key (Flutter on PATH)
#   gradle_deps.sh produce        the deps job (CI only)
#   gradle_deps.sh unpack <dir>   a lane: install <dir>'s set, pin Flutter
#   gradle_deps.sh --self-test
#
# Exit codes:
#   0  done
#   1  the set could not be resolved, verified or proved (produce)
#   2  wrong arguments, missing inputs, or the self-test failed

set -euo pipefail

readonly SCRIPT_NAME="gradle_deps.sh"
readonly RC_BROKEN=2
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

readonly TARBALL="gradle-deps.tar.zst"
readonly VERSION_FILE="flutter-version"
readonly SOURCE_PREFIX="gradle-deps-src-"
# The workflows whose main runs may publish a source; see trusted_run.
readonly TRUSTED_WORKFLOWS=".github/workflows/ci.yml .github/workflows/e2e-nightly.yml"
# The deps job's own retry budget for the online resolution, far wider than a
# lane's 180 s: it is the run's ONE network resolution, a full one takes
# minutes, and a re-run costs every Android lane of the run.
readonly ONLINE_BUDGET_SECS=900
# Enough attempts that the budget, not the count, ends a run of quick
# failures: past the wrapper's 20/45/75 s ladder every pause is 75 s, so eleven
# pauses alone are 740 s.
readonly ONLINE_MAX_ATTEMPTS=12
# A listing can hold any number of sources; only this many newest ones are
# each checked against the run that made them.
readonly SOURCE_CANDIDATES=10
readonly CANARY_COORDINATE="invalid.haven.gradle-deps.canary:absent:0.0.0"

KEYED_PATHSPECS=(
  ':(glob)haven/android/**/*.gradle*'
  ':(glob)haven/rust_builder/**/*.gradle*'
  ':(glob)third_party/**/*.gradle*'
  'haven/android/gradle.properties'
  'haven/android/gradle/wrapper/gradle-wrapper.properties'
  'haven/pubspec.lock'
  'scripts/ci/maven-central-fallback.init.gradle.kts'
  'scripts/ci/gradle-resolve-all.init.gradle.kts'
  'scripts/ci/gradle-offline.init.gradle.kts'
  'scripts/ci/build_apk_with_retry.sh'
  'scripts/ci/gradle_deps.sh'
)

log() { printf '[%s] %s\n' "${SCRIPT_NAME}" "$*"; }
err() { printf '[%s] %s\n' "${SCRIPT_NAME}" "$*" >&2; }

guh() { printf '%s' "${GRADLE_USER_HOME:-${HOME}/.gradle}"; }

# flutter_field <name> — one field of `flutter --version --machine`.
flutter_field() {
  flutter --version --machine 2>/dev/null | jq -er --arg f "$1" '.[$f]'
}

compute_key() {
  local rev digest
  rev="$(flutter_field frameworkRevision)" || { err "cannot read Flutter's frameworkRevision"; return "${RC_BROKEN}"; }
  [[ "${rev}" =~ ^[0-9a-f]{40}$ ]] || { err "Flutter's frameworkRevision is not a commit"; return "${RC_BROKEN}"; }
  # Path and content of every keyed TRACKED file, so a generated
  # local.properties or a build tree never moves the key.
  digest="$(cd "${REPO_ROOT}" && git ls-files -z -- "${KEYED_PATHSPECS[@]}" | LC_ALL=C sort -z \
    | while IFS= read -r -d '' f; do printf '%s\0%s\n' "${f}" "$(sha256sum < "${f}" | cut -d' ' -f1)"; done \
    | sha256sum | cut -c1-32)"
  printf 'gradle-deps-v1-%s-%s-%s' "$(uname -s)" "${rev:0:12}" "${digest}"
}

# ---------------------------------------------------------------------------
# The source.
# ---------------------------------------------------------------------------

# trusted_run <run id> — only a run of a trusted workflow, on a push or a
# schedule, on main, from this repository may have produced what a lane builds
# from. Never a pull request (pull_request_target included) and never a fork.
trusted_run() {
  local fields path event branch head_repo
  fields="$(gh api "repos/${GITHUB_REPOSITORY}/actions/runs/$1" \
    --jq '[.path, .event, .head_branch, (.head_repository.full_name // "")] | @tsv')" || return 1
  IFS=$'\t' read -r path event branch head_repo <<<"${fields}"
  [[ " ${TRUSTED_WORKFLOWS} " == *" ${path} "* ]] || return 1
  [[ "${event}" == push || "${event}" == schedule ]] || return 1
  [[ "${branch}" == main ]] || return 1
  [[ "${head_repo}" == "${GITHUB_REPOSITORY}" ]] || return 1
}

# find_source <key> — the newest unexpired source from a trusted run, as an
# artifact id, or nothing. The listing's own fields drop what cannot be
# trusted — expired, off main, from a fork — before any run is asked about,
# and at most SOURCE_CANDIDATES runs are: trusted_run stays the authority.
find_source() {
  local listing id run
  if ! listing="$(gh api --paginate "repos/${GITHUB_REPOSITORY}/actions/artifacts?name=${SOURCE_PREFIX}$1&per_page=100" \
      --jq '.artifacts[] | select(.expired == false and .workflow_run.head_branch == "main" and .workflow_run.head_repository_id == .workflow_run.repository_id) | [.created_at, .id, .workflow_run.id] | @tsv')"; then
    printf '::warning::the artifact listing did not answer, so this run resolves its Gradle dependencies online instead of from a main run'"'"'s verified set.\n' >&2
    return 0
  fi
  while IFS=$'\t' read -r _ id run; do
    [[ -n "${id}" ]] || continue
    if trusted_run "${run}"; then
      printf '%s' "${id}"
      return 0
    fi
  done < <(LC_ALL=C sort -r <<<"${listing}" | head -n "${SOURCE_CANDIDATES}")
}

download_source() { # <artifact id> <dir>
  local zip="$2/source.zip" attempt
  mkdir -p "$2"
  for attempt in 1 2 3; do
    if gh api "repos/${GITHUB_REPOSITORY}/actions/artifacts/$1/zip" > "${zip}" && unzip -q -o "${zip}" -d "$2"; then
      rm -f "${zip}"
      [[ -s "$2/${TARBALL}" && -s "$2/${VERSION_FILE}" ]] && return 0
      err "the source artifact holds no ${TARBALL} with its ${VERSION_FILE}."
      return 1
    fi
    err "downloading the source artifact failed (attempt ${attempt}/3)."
    rm -f "${zip}"
  done
  return 1
}

# ---------------------------------------------------------------------------
# Pack and unpack. Only the module cache and the wrapper's distribution travel:
# Gradle rebuilds every other cache offline from them. Lock files and the
# cache's gc bookkeeping are per-machine, and the distribution's zip is dead
# weight once its unpacked tree and `.ok` marker exist, which is all the
# wrapper reads.
# ---------------------------------------------------------------------------
pack() { # <gradle user home> <out dir> <flutter version>
  mkdir -p "$2"
  tar -C "$1" --exclude='*.lock' --exclude='*.lck' --exclude='gc.properties' \
      --exclude='wrapper/dists/*/*/*.zip' -cf - caches/modules-2 wrapper/dists \
    | zstd -q -f -T0 -3 -o "$2/${TARBALL}"
  printf '%s\n' "$3" > "$2/${VERSION_FILE}"
}

valid_version() { [[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?$ ]]; }

# install_set <dir> <gradle user home> — unpack the two members a set carries
# and nothing else (a stray init.d script or gradle.properties would run in
# every later build), then delete the tarball: it is ~2 GB of disk the lane's
# build needs more. A failed unpack keeps the tarball and says so, since every
# caller tests this function and a test suspends errexit inside it.
install_set() {
  [[ -s "$1/${TARBALL}" ]] || { err "$1 holds no ${TARBALL}."; return "${RC_BROKEN}"; }
  mkdir -p "$2"
  tar -I 'zstd -d' -xf "$1/${TARBALL}" -C "$2" --no-same-owner caches/modules-2 wrapper/dists \
    || { err "unpacking $1/${TARBALL} failed; it is kept."; return 1; }
  rm -f "$1/${TARBALL}"
}

unpack() { # <dir>
  local dir="$1" version
  [[ -s "${dir}/${VERSION_FILE}" ]] || { err "${dir} holds no ${VERSION_FILE}; this lane did not download this run's gradle-deps artifact."; return "${RC_BROKEN}"; }
  version="$(head -n 1 "${dir}/${VERSION_FILE}")"
  valid_version "${version}" || { err "${dir}/${VERSION_FILE} does not hold a Flutter version."; return "${RC_BROKEN}"; }
  [[ -n "${GITHUB_ENV:-}" ]] || { err "GITHUB_ENV is not set, so the Flutter pin cannot reach the next steps."; return "${RC_BROKEN}"; }
  install_set "${dir}" "$(guh)" || return
  printf 'HAVEN_FLUTTER_VERSION=%s\n' "${version}" >> "${GITHUB_ENV}"
  log "installed this run's Gradle dependency set into $(guh); Flutter is pinned to ${version}."
}

# ---------------------------------------------------------------------------
# Resolution, verification and the canaries. Each Gradle call is one function,
# the only ones the self-test replaces.
# ---------------------------------------------------------------------------
retry_wrapper() { printf '%s' "${SCRIPT_DIR}/build_apk_with_retry.sh"; }

resolve_online() {
  HAVEN_BUILD_RETRY_BUDGET_SECS="${ONLINE_BUDGET_SECS}" HAVEN_BUILD_MAX_ATTEMPTS="${ONLINE_MAX_ATTEMPTS}" \
    bash "$(retry_wrapper)" --resolve-only
}

verify_offline() {
  HAVEN_GRADLE_OFFLINE=1 bash "$(retry_wrapper)" --resolve-only
}

# A main set that misses something is topped up, not a failure, so its gap is
# a warning: a deps job that ends green carries no ::error::.
verify_source() {
  verify_offline 2>&1 | sed 's/^::error::/::warning::/'
  return "${PIPESTATUS[0]}"
}

# canary_gradle <project dir> <args...> — the Gradle the lanes run, on a
# throwaway build of our own.
canary_gradle() {
  local d="$1"; shift
  "${REPO_ROOT}/haven/android/gradlew" -p "${d}" --no-daemon --continue "$@"
}

write_canary() { # <dir>
  local d="$1" b
  mkdir -p "${d}/offline/inc/src/main/java/canary" "${d}/empty-repo"
  # Offline: the included plugin build compiles against a coordinate nobody
  # has, from a REMOTE repository: Gradle's offline mode never covers a file
  # repository, which it reads either way. The host cannot resolve, so if
  # offline were not in force the answer would be a failed GET, not the
  # offline wording, and nothing real is ever asked.
  printf 'pluginManagement { includeBuild("inc") }\nrootProject.name = "haven-canary-top"\n' > "${d}/offline/settings.gradle.kts"
  printf 'plugins { id("haven.gradle-deps.canary") }\n' > "${d}/offline/build.gradle.kts"
  printf 'rootProject.name = "haven-canary-included"\n' > "${d}/offline/inc/settings.gradle.kts"
  cat > "${d}/offline/inc/build.gradle.kts" <<EOF
plugins { \`java-gradle-plugin\` }
repositories { maven { url = uri("https://repository.invalid/maven2/") } }
dependencies { implementation("${CANARY_COORDINATE}") }
gradlePlugin { plugins { create("c") { id = "haven.gradle-deps.canary"; implementationClass = "canary.P" } } }
EOF
  printf 'package canary;\npublic class P implements org.gradle.api.Plugin<org.gradle.api.Project> { public void apply(org.gradle.api.Project p) {} }\n' \
    > "${d}/offline/inc/src/main/java/canary/P.java"
  # Strict: a configuration no task of the build resolves, in the top build,
  # in a build it includes, and in one it includes the way Flutter's
  # flutter_tools is, through `pluginManagement` — separate builds, because
  # the top build's task waits on an included one's and never runs once that
  # fails.
  for b in top included plugin-included; do
    mkdir -p "${d}/strict-${b}/inc"
    printf 'includeBuild("inc")\nrootProject.name = "haven-canary-top"\n' > "${d}/strict-${b}/settings.gradle.kts"
    printf 'rootProject.name = "haven-canary-included"\n' > "${d}/strict-${b}/inc/settings.gradle.kts"
    : > "${d}/strict-${b}/build.gradle.kts"; : > "${d}/strict-${b}/inc/build.gradle.kts"
  done
  printf 'pluginManagement { includeBuild("inc") }\nrootProject.name = "haven-canary-top"\n' > "${d}/strict-plugin-included/settings.gradle.kts"
  for b in "${d}/strict-top" "${d}/strict-included/inc" "${d}/strict-plugin-included/inc"; do
    cat > "${b}/build.gradle.kts" <<EOF
repositories { maven { url = uri("${d}/empty-repo") } }
val havenCanary by configurations.creating
dependencies { havenCanary("${CANARY_COORDINATE}") }
EOF
  done
}

# judge_canaries <offline output> <strict-top output> <strict-included output>
#                <strict-plugin-included output>
# — the assertions, apart from the Gradle calls so the self-test can hold them
# to both directions.
judge_canaries() {
  local ok=0
  if [[ "$1" != *"No cached version of ${CANARY_COORDINATE} available for offline mode"* ]]; then
    printf '::error::the offline canary did not fail as offline: an included build of a Gradle run under scripts/ci/gradle-offline.init.gradle.kts asked a remote repository for a coordinate nobody has and Gradle did not answer "No cached version ... available for offline mode". The lanes would not be offline; nothing is uploaded.\n' >&2
    printf '%s\n' "$1" | tail -n 25 | sed 's/^/    | /' >&2
    ok=1
  fi
  if [[ "$2" != *"haven-canary-top project 'havenCanary'"* ]]; then
    printf '::error::the strictness canary'"'"'s top build has a configuration nobody resolves and havenResolveAll did not name it, so it no longer proves the set complete; nothing is uploaded.\n' >&2
    printf '%s\n' "$2" | tail -n 25 | sed 's/^/    | /' >&2
    ok=1
  fi
  if [[ "$3" != *"haven-canary-included project 'havenCanary'"* ]]; then
    printf '::error::the strictness canary'"'"'s INCLUDED build has a configuration nobody resolves and havenResolveAll did not name it, so it no longer reaches included builds; nothing is uploaded.\n' >&2
    printf '%s\n' "$3" | tail -n 25 | sed 's/^/    | /' >&2
    ok=1
  fi
  if [[ "$4" != *"haven-canary-included project 'havenCanary'"* ]]; then
    printf '::error::the strictness canary'"'"'s build included through pluginManagement, as Flutter'"'"'s flutter_tools is, has a configuration nobody resolves and havenResolveAll did not name it; nothing is uploaded.\n' >&2
    printf '%s\n' "$4" | tail -n 25 | sed 's/^/    | /' >&2
    ok=1
  fi
  return "${ok}"
}

run_canaries() {
  local d off top inc plg
  d="$(mktemp -d)"
  write_canary "${d}"
  off="$(canary_gradle "${d}/offline" -I "${SCRIPT_DIR}/gradle-offline.init.gradle.kts" help 2>&1 || true)"
  top="$(canary_gradle "${d}/strict-top" -I "${SCRIPT_DIR}/gradle-resolve-all.init.gradle.kts" havenResolveAll 2>&1 || true)"
  inc="$(canary_gradle "${d}/strict-included" -I "${SCRIPT_DIR}/gradle-resolve-all.init.gradle.kts" havenResolveAll 2>&1 || true)"
  plg="$(canary_gradle "${d}/strict-plugin-included" -I "${SCRIPT_DIR}/gradle-resolve-all.init.gradle.kts" havenResolveAll 2>&1 || true)"
  rm -rf "${d}"
  judge_canaries "${off}" "${top}" "${inc}" "${plg}"
}

# ---------------------------------------------------------------------------
# produce: the deps job. Writes the set to $RUNNER_TEMP/gradle-deps and
# `key` / `upload_source` to $GITHUB_OUTPUT.
# ---------------------------------------------------------------------------
prepare_tree() {
  (cd "${REPO_ROOT}/haven" && flutter build apk --config-only)
}

produce() {
  local key version id out="${RUNNER_TEMP:?}/gradle-deps" fetched="${RUNNER_TEMP}/gradle-deps-source" upload_source=true
  [[ -n "${GITHUB_OUTPUT:-}" && -n "${GITHUB_REPOSITORY:-}" ]] || { err "produce runs in the deps job only."; return "${RC_BROKEN}"; }
  key="$(compute_key)" || return "${RC_BROKEN}"
  version="$(flutter_field frameworkVersion)" || { err "cannot read Flutter's frameworkVersion"; return "${RC_BROKEN}"; }
  valid_version "${version}" || { err "Flutter's frameworkVersion is not a version"; return "${RC_BROKEN}"; }
  log "dependency-set key: ${key} (Flutter ${version})"
  prepare_tree || { err "flutter build apk --config-only failed; the Android project cannot be configured."; return 1; }

  id="$(find_source "${key}")"
  if [[ -n "${id}" ]] && download_source "${id}" "${fetched}"; then
    if install_set "${fetched}" "$(guh)"; then
      log "installed main's verified set (artifact ${id}); verifying it offline."
      if verify_source; then
        upload_source=false
      else
        printf '::warning::main'"'"'s verified Gradle set for this key no longer resolves offline; topping it up online. The completed set is uploaded as a newer source, which replaces it.\n' >&2
      fi
    else
      # What a truncated archive left must never be packed as the new source.
      printf '::warning::main'"'"'s verified Gradle set for this key could not be unpacked; resolving online from an empty cache.\n' >&2
      rm -rf "$(guh)/caches/modules-2" "$(guh)/wrapper/dists"
    fi
  else
    log "no verified set from main for this key; resolving online."
  fi
  rm -rf "${fetched}"

  if [[ "${upload_source}" == true ]]; then
    resolve_online || { printf '::error::the Gradle dependencies of this tree could not be resolved within the deps job'"'"'s %ss retry budget. Every Android lane of this run is skipped and the run is red: re-run it. If this commit changed a dependency, read the Gradle error above first.\n' "${ONLINE_BUDGET_SECS}" >&2; return 1; }
    verify_offline || { printf '::error::the dependency set resolved online does NOT resolve offline, so a lane would meet the network. Read the offline gap above; nothing is uploaded.\n' >&2; return 1; }
  fi

  run_canaries || return 1
  pack "$(guh)" "${out}" "${version}"
  printf 'key=%s\nupload_source=%s\n' "${key}" "${upload_source}" >> "${GITHUB_OUTPUT}"
  log "packed the verified set ($(du -h "${out}/${TARBALL}" | cut -f1)); upload_source=${upload_source}."
}

# ---------------------------------------------------------------------------
# Self-test: hermetic. A throwaway git repo for the key, a stub `gh` serving
# recorded API shapes through the REAL jq filters, a stub `flutter`, and the
# Gradle calls replaced. No network, no Gradle.
# ---------------------------------------------------------------------------
readonly SELF_TEST_FIXTURES=19

run_self_test() {
  local tmp ran=0 failures=0 rc out t
  for t in git jq zstd; do
    command -v "${t}" >/dev/null || { echo "${SCRIPT_NAME}: the self-test needs ${t}, which is missing" >&2; return 1; }
  done
  tmp="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf '${tmp}'" EXIT
  _fail() { echo "SELF-TEST FAIL ($1): $2" >&2; failures=1; }

  # Stubs on PATH. `flutter` answers --version --machine from FLUTTER_REV.
  mkdir -p "${tmp}/bin"
  cat > "${tmp}/bin/flutter" <<'EOF'
#!/usr/bin/env bash
[[ "$*" == "--version --machine" ]] || { echo "stub flutter: unexpected argv $*" >&2; exit 97; }
printf '{"frameworkVersion":"%s","frameworkRevision":"%s"}\n' "${FLUTTER_VER:-3.50.1}" "${FLUTTER_REV}"
EOF
  # `gh api [--paginate] <path> --jq <filter>`: the path is looked up in
  # GH_FIXTURES (one file per path, '/' and '?' flattened); a missing fixture
  # is an API failure. The filter is applied by the real jq.
  cat > "${tmp}/bin/gh" <<'EOF'
#!/usr/bin/env bash
[[ "$1" == api ]] || exit 97; shift
[[ "$1" == --paginate ]] && shift
path="$1"; shift; filter=""
[[ "${1:-}" == --jq ]] && filter="$2"
f="${GH_FIXTURES}/$(printf '%s' "${path}" | tr '/?&=' '____')"
echo "${path}" >> "${GH_FIXTURES}/calls"
[[ -r "${f}" ]] || exit 1
if [[ -n "${filter}" ]]; then jq -r "${filter}" < "${f}"; else cat "${f}"; fi
EOF
  chmod +x "${tmp}/bin/flutter" "${tmp}/bin/gh"
  local rev_a rev_b
  rev_a="$(printf 'a%.0s' {1..40})"; rev_b="$(printf 'b%.0s' {1..40})"

  # (1) The key: stable, moved by every keyed input and by the Flutter
  #     revision, and NOT by an unkeyed file or an untracked generated one.
  ran=$(( ran + 1 ))
  local repo="${tmp}/repo" f k0 k
  mkdir -p "${repo}"
  git -C "${repo}" init -q
  local -a keyed=(haven/android/build.gradle.kts haven/android/app/build.gradle.kts
    haven/rust_builder/android/build.gradle haven/rust_builder/cargokit/gradle/plugin.gradle
    third_party/geolocator_android/android/build.gradle haven/android/gradle.properties
    haven/android/gradle/wrapper/gradle-wrapper.properties haven/pubspec.lock
    scripts/ci/maven-central-fallback.init.gradle.kts scripts/ci/gradle-resolve-all.init.gradle.kts
    scripts/ci/gradle-offline.init.gradle.kts scripts/ci/build_apk_with_retry.sh scripts/ci/gradle_deps.sh)
  for f in "${keyed[@]}" haven/lib/main.dart; do mkdir -p "${repo}/$(dirname "${f}")"; echo v1 > "${repo}/${f}"; done
  git -C "${repo}" add -A && git -C "${repo}" -c user.email=t@t -c user.name=t commit -qm init
  _key() { (export PATH="${tmp}/bin:${PATH}" FLUTTER_REV="${1:-${rev_a}}"; REPO_ROOT="${repo}"; compute_key); }
  k0="$(_key)"
  [[ "${k0}" =~ ^gradle-deps-v1-[A-Za-z]+-a{12}-[0-9a-f]{32}$ ]] || _fail 1 "unexpected key shape '${k0}'"
  [[ "$(_key)" == "${k0}" ]] || _fail 1 "the key is not stable"
  [[ "$(_key "${rev_b}")" != "${k0}" ]] || _fail 1 "a new Flutter revision must move the key"
  for f in "${keyed[@]}"; do
    echo v2 > "${repo}/${f}"; git -C "${repo}" add -A
    [[ "$(_key)" != "${k0}" ]] || _fail 1 "a change to ${f} must move the key"
    git -C "${repo}" checkout -q -- . 2>/dev/null; git -C "${repo}" reset -q --hard
  done
  echo v2 > "${repo}/haven/lib/main.dart"; git -C "${repo}" add -A
  [[ "$(_key)" == "${k0}" ]] || _fail 1 "an unkeyed file must not move the key"
  git -C "${repo}" reset -q --hard
  echo generated > "${repo}/haven/android/local.gradle.kts"
  [[ "$(_key)" == "${k0}" ]] || _fail 1 "an UNTRACKED generated Gradle file must not move the key"
  rm -f "${repo}/haven/android/local.gradle.kts"

  # (2-6) find_source against recorded API shapes. Each fixture differs from
  #       the trusted one by the one property it tests.
  local gf="${tmp}/gh" key="gradle-deps-v1-Linux-x"
  _run_json() { # <run id> <path> <event> <branch> <head repo>
    printf '{"path":"%s","event":"%s","head_branch":"%s","head_repository":{"full_name":"%s"}}\n' "$2" "$3" "$4" "$5" \
      > "${gf}/repos_o_r_actions_runs_$1"
  }
  _listing() { # <artifact json objects...>
    local IFS=,; printf '{"total_count":%s,"artifacts":[%s]}\n' "$#" "$*" \
      > "${gf}/repos_o_r_actions_artifacts_name_${SOURCE_PREFIX}${key}_per_page_100"
  }
  # <id> <expired> <created_at> <run id> [head_branch] [head_repository_id];
  # this repository's id is 1.
  _art() { printf '{"id":%s,"expired":%s,"created_at":"%s","workflow_run":{"id":%s,"head_branch":"%s","repository_id":1,"head_repository_id":%s}}' \
    "$1" "$2" "$3" "$4" "${5:-main}" "${6:-1}"; }
  _find() { (export PATH="${tmp}/bin:${PATH}" GH_FIXTURES="${gf}" GITHUB_REPOSITORY=o/r; find_source "${key}"); }
  _case_find() { # <label> <want id or empty> <listing objects...>
    local label="$1" want="$2"; shift 2
    ran=$(( ran + 1 ))
    rm -rf "${gf}"; mkdir -p "${gf}"
    _run_json 11 .github/workflows/ci.yml push main o/r
    _run_json 12 .github/workflows/e2e-nightly.yml schedule main o/r
    _run_json 21 .github/workflows/ci.yml pull_request main o/r
    _run_json 22 .github/workflows/ci.yml push feature o/r
    _run_json 23 .github/workflows/ci.yml push main fork/r
    _run_json 24 .github/workflows/launch-gate-android-dispatch.yml push main o/r
    _run_json 25 .github/workflows/ci.yml pull_request_target main o/r
    [[ $# -gt 0 ]] && _listing "$@"
    local got; got="$(_find 2>"${tmp}/find.err")"
    [[ "${got}" == "${want}" ]] || _fail "find: ${label}" "got '${got}', want '${want}'"
  }
  _case_find "a trusted ci.yml push on main is taken" 101 "$(_art 101 false 2026-11-20T00:00:00Z 11)"
  # The listing says main and this repository for 202 and 203 here, so only
  # trusted_run's own reading of each run can refuse them.
  _case_find "a pull request's, a non-main push's, a fork's, another workflow's and a pull_request_target's are all refused" "" \
    "$(_art 201 false 2026-11-21T00:00:00Z 21)" "$(_art 202 false 2026-11-21T00:00:00Z 22)" \
    "$(_art 203 false 2026-11-21T00:00:00Z 23)" "$(_art 204 false 2026-11-21T00:00:00Z 24)" \
    "$(_art 205 false 2026-11-21T00:00:00Z 25)"
  _case_find "an expired source is refused" "" "$(_art 301 true 2026-11-22T00:00:00Z 11)"
  _case_find "the NEWEST trusted source wins, so a topped-up source replaces an incomplete one" 402 \
    "$(_art 401 false 2026-11-20T00:00:00Z 11)" "$(_art 402 false 2026-11-23T00:00:00Z 12)" \
    "$(_art 403 false 2026-11-24T00:00:00Z 21)"
  _case_find "a listing that does not answer is no source, said aloud" ""
  grep -q '::warning::' "${tmp}/find.err" || _fail 6 "an unanswered listing must warn that the run resolves online"
  # The listing's own fields refuse a fork's and an off-main source before
  # any run is asked about: run 11 is trusted, so only the filter refuses.
  _case_find "a fork's or an off-main source never reaches trusted_run" "" \
    "$(_art 601 false 2026-11-21T00:00:00Z 11 main 2)" "$(_art 602 false 2026-11-21T00:00:00Z 11 feature 1)"
  ! grep -q 'actions/runs/' "${gf}/calls" || _fail 7 "a fork's or an off-main source must be refused by the listing's fields, before any run is read"
  # A flood of sources that pass the filter and fail trusted_run asks about
  # SOURCE_CANDIDATES runs at most.
  local flood=() i
  for i in $(seq 700 724); do flood+=("$(_art "${i}" false "2026-11-21T00:00:${i: -2}Z" 24)"); done
  _case_find "a flood of untrusted sources is checked only up to the cap" "" "${flood[@]}"
  (( $(grep -c 'actions/runs/' "${gf}/calls") <= SOURCE_CANDIDATES )) \
    || _fail 8 "$(grep -c 'actions/runs/' "${gf}/calls") runs were read for one listing; at most ${SOURCE_CANDIDATES} may be"

  # (7) Pack and unpack round-trip: the module cache and the unpacked
  #     distribution travel, locks, gc bookkeeping and the zip do not, the
  #     tarball is deleted, and the Flutter pin reaches GITHUB_ENV.
  ran=$(( ran + 1 ))
  local src="${tmp}/guh-src" dst="${tmp}/guh-dst" art="${tmp}/art" env_file="${tmp}/env"
  mkdir -p "${src}/caches/modules-2/files-2.1/g/m/1/h" "${src}/wrapper/dists/gradle-9-all/x/gradle-9" "${src}/caches/9.5.0/transforms"
  echo jar > "${src}/caches/modules-2/files-2.1/g/m/1/h/m-1.jar"
  echo l > "${src}/caches/modules-2/modules-2.lock"; echo gc > "${src}/caches/modules-2/gc.properties"
  echo t > "${src}/caches/9.5.0/transforms/t"
  echo ok > "${src}/wrapper/dists/gradle-9-all/x/gradle-9-all.zip.ok"
  echo zip > "${src}/wrapper/dists/gradle-9-all/x/gradle-9-all.zip"
  echo lck > "${src}/wrapper/dists/gradle-9-all/x/gradle-9-all.zip.lck"
  echo bin > "${src}/wrapper/dists/gradle-9-all/x/gradle-9/gradle"
  pack "${src}" "${art}" 3.50.1
  : > "${env_file}"
  rc=0; out="$(GRADLE_USER_HOME="${dst}" GITHUB_ENV="${env_file}" unpack "${art}" 2>&1)" || rc=$?
  if (( rc != 0 )) || [[ ! -f "${dst}/caches/modules-2/files-2.1/g/m/1/h/m-1.jar" ]] \
     || [[ ! -f "${dst}/wrapper/dists/gradle-9-all/x/gradle-9-all.zip.ok" || ! -f "${dst}/wrapper/dists/gradle-9-all/x/gradle-9/gradle" ]] \
     || [[ -e "${dst}/caches/modules-2/modules-2.lock" || -e "${dst}/caches/modules-2/gc.properties" ]] \
     || [[ -e "${dst}/wrapper/dists/gradle-9-all/x/gradle-9-all.zip" || -e "${dst}/wrapper/dists/gradle-9-all/x/gradle-9-all.zip.lck" ]] \
     || [[ -e "${dst}/caches/9.5.0" || -e "${art}/${TARBALL}" ]] \
     || [[ "$(cat "${env_file}")" != "HAVEN_FLUTTER_VERSION=3.50.1" ]]; then
    _fail 7 "pack/unpack must carry exactly the module cache and the unpacked distribution, delete the tarball and pin Flutter; got rc=${rc}: ${out}"
  fi

  # (8) A sidecar that is not a version never reaches GITHUB_ENV (it is a
  #     file other steps execute as assignments), and nothing is unpacked.
  ran=$(( ran + 1 ))
  pack "${src}" "${art}" 3.50.1
  printf '3.50.1;PATH=/evil\n' > "${art}/${VERSION_FILE}"
  : > "${env_file}"; rm -rf "${dst}"
  rc=0; GRADLE_USER_HOME="${dst}" GITHUB_ENV="${env_file}" unpack "${art}" >/dev/null 2>&1 || rc=$?
  if (( rc != RC_BROKEN )) || [[ -s "${env_file}" ]] || [[ -e "${dst}" ]]; then
    _fail 8 "a malformed Flutter version must be refused with rc ${RC_BROKEN} before anything is unpacked or pinned; got rc=${rc}"
  fi

  # A truncated set fails the unpack — errexit is off inside a tested
  # function, so only an explicit check can see tar fail — pins nothing, and
  # keeps the tarball.
  ran=$(( ran + 1 ))
  pack "${src}" "${art}" 3.50.1
  # Half of it, whatever its size: a fixed byte count can exceed a small set.
  head -c "$(( $(stat -c %s "${art}/${TARBALL}") / 2 ))" "${art}/${TARBALL}" > "${art}/t" && mv "${art}/t" "${art}/${TARBALL}"
  : > "${env_file}"; rm -rf "${dst}"
  rc=0; GRADLE_USER_HOME="${dst}" GITHUB_ENV="${env_file}" unpack "${art}" >/dev/null 2>&1 || rc=$?
  if (( rc == 0 )) || [[ -s "${env_file}" ]] || [[ ! -s "${art}/${TARBALL}" ]]; then
    _fail 9 "a truncated set must fail the unpack, pin nothing and keep the tarball; got rc=${rc}"
  fi

  # Only the module cache and the distribution are unpacked: an init.d script
  # or gradle.properties smuggled into a set never lands.
  ran=$(( ran + 1 ))
  local stray="${tmp}/stray"
  rm -rf "${stray}"; cp -a "${src}" "${stray}"
  mkdir -p "${stray}/init.d"; echo evil > "${stray}/init.d/evil.init.gradle.kts"; echo evil > "${stray}/gradle.properties"
  mkdir -p "${art}"; tar -C "${stray}" -cf - caches/modules-2 wrapper/dists init.d gradle.properties | zstd -q -o "${art}/${TARBALL}" -f
  echo 3.50.1 > "${art}/${VERSION_FILE}"
  : > "${env_file}"; rm -rf "${dst}"
  rc=0; GRADLE_USER_HOME="${dst}" GITHUB_ENV="${env_file}" unpack "${art}" >/dev/null 2>&1 || rc=$?
  if (( rc != 0 )) || [[ -e "${dst}/init.d" || -e "${dst}/gradle.properties" ]] \
     || [[ ! -f "${dst}/caches/modules-2/files-2.1/g/m/1/h/m-1.jar" ]]; then
    _fail 10 "a set's stray init.d or gradle.properties must not be unpacked; got rc=${rc}, init.d $( [[ -e "${dst}/init.d" ]] && echo present || echo absent )"
  fi

  # (9-11) produce's decisions, with the Gradle calls, the tree preparation
  #        and the source download replaced and every call recorded.
  local calls="${tmp}/calls"
  _produce() { # <has source: yes|no|corrupt> <offline verify results, space-separated> <online result> <canary result>
    local has="$1" online_result="$3" canary_result="$4"
    (
      export PATH="${tmp}/bin:${PATH}" FLUTTER_REV="${rev_a}" RUNNER_TEMP="${tmp}/rt" GITHUB_OUTPUT="${tmp}/out" \
             GITHUB_REPOSITORY=o/r GRADLE_USER_HOME="${tmp}/guh-p"
      REPO_ROOT="${repo}"
      rm -rf "${tmp}/rt" "${tmp}/guh-p"; mkdir -p "${tmp}/rt" "${tmp}/guh-p/caches/modules-2" "${tmp}/guh-p/wrapper/dists"
      # What a truncated unpack leaves behind, whatever tar managed to write.
      if [[ "${has}" == corrupt ]]; then echo partial > "${tmp}/guh-p/caches/modules-2/left-by-a-truncated-unpack.jar"; fi
      : > "${calls}"; : > "${tmp}/out"; echo "$2" > "${tmp}/verify-results"
      prepare_tree() { echo prepare >> "${calls}"; }
      find_source() { [[ "${has}" != no ]] && printf '7'; return 0; }
      download_source() {
        echo download >> "${calls}"; mkdir -p "$2"; pack "${tmp}/guh-src" "$2" 3.50.1
        if [[ "${has}" == corrupt ]]; then
          head -c "$(( $(stat -c %s "$2/${TARBALL}") / 2 ))" "$2/${TARBALL}" > "$2/t"; mv "$2/t" "$2/${TARBALL}"
        fi
      }
      verify_offline() {
        echo verify >> "${calls}"
        local r rest; read -r r rest < "${tmp}/verify-results"; echo "${rest}" > "${tmp}/verify-results"
        [[ "${r}" == ok ]] || { echo "::error::stub offline gap" >&2; return 1; }
      }
      # Records whether the online resolution starts from an empty cache.
      resolve_online() {
        if [[ -n "$(find "${GRADLE_USER_HOME}/caches" "${GRADLE_USER_HOME}/wrapper" -type f 2>/dev/null)" ]]; then
          echo online-over-files >> "${calls}"
        else
          echo online >> "${calls}"
        fi
        [[ "${online_result}" == ok ]]
      }
      run_canaries() { echo canaries >> "${calls}"; [[ "${canary_result}" == ok ]]; }
      produce
    )
  }
  ran=$(( ran + 1 ))
  rc=0; _produce yes "ok" ok ok >/dev/null 2>&1 || rc=$?
  if (( rc != 0 )) || [[ "$(tr '\n' ' ' < "${calls}")" != "prepare download verify canaries " ]] \
     || ! grep -qx 'upload_source=false' "${tmp}/out" || [[ ! -s "${tmp}/rt/gradle-deps/${TARBALL}" ]]; then
    _fail 9 "a source that verifies offline must be used as is — no online resolution, no new source; got rc=${rc}, calls '$(tr '\n' ' ' < "${calls}")'"
  fi
  ran=$(( ran + 1 ))
  rc=0; out="$(_produce yes "bad ok" ok ok 2>&1)" || rc=$?
  if (( rc != 0 )) || [[ "$(tr '\n' ' ' < "${calls}")" != "prepare download verify online-over-files verify canaries " ]] \
     || ! grep -qx 'upload_source=true' "${tmp}/out"; then
    _fail 10 "a source that fails offline must be topped up online, verified again and REPLACED; got rc=${rc}, calls '$(tr '\n' ' ' < "${calls}")'"
  fi
  # ...and the job that ends green carries no ::error::: the source's gap is
  # a warning.
  ran=$(( ran + 1 ))
  if grep -q '::error::' <<<"${out}" || ! grep -q '::warning::stub offline gap' <<<"${out}"; then
    _fail 11 "a topped-up source must leave a green job with no ::error:: and its gap as a ::warning::; got: ${out}"
  fi
  # A source that cannot be unpacked is resolved online from an EMPTY cache,
  # so what the truncated archive left can never be packed as the new source.
  ran=$(( ran + 1 ))
  rc=0; _produce corrupt "ok" ok ok >/dev/null 2>&1 || rc=$?
  if (( rc != 0 )) || [[ "$(tr '\n' ' ' < "${calls}")" != "prepare download online verify canaries " ]] \
     || ! grep -qx 'upload_source=true' "${tmp}/out"; then
    _fail 12 "a source that does not unpack must be resolved online from an empty cache and replaced; got rc=${rc}, calls '$(tr '\n' ' ' < "${calls}")'"
  fi
  ran=$(( ran + 1 ))
  local scen label want_calls
  for scen in "no|ok|ok|ok|0|prepare online verify canaries " \
              "no|ok|bad|ok|1|prepare online " \
              "no|bad|ok|ok|1|prepare online verify " \
              "no|ok|ok|bad|1|prepare online verify canaries "; do
    IFS='|' read -r has vr onl can want_rc want_calls <<<"${scen}"
    rc=0; _produce "${has}" "${vr}" "${onl}" "${can}" >/dev/null 2>&1 || rc=$?
    label="source=${has} verify=${vr} online=${onl} canaries=${can}"
    if (( rc != want_rc )) || [[ "$(tr '\n' ' ' < "${calls}")" != "${want_calls}" ]]; then
      _fail 11 "${label}: want rc ${want_rc} and calls '${want_calls}', got rc ${rc} and '$(tr '\n' ' ' < "${calls}")'"
    fi
    if (( want_rc != 0 )) && [[ -e "${tmp}/rt/gradle-deps/${TARBALL}" || -s "${tmp}/out" ]]; then
      _fail 11 "${label}: a failed produce must pack nothing and output nothing"
    fi
  done

  # The online resolution is given the deps job's own budget and enough
  # attempts that the budget is what ends it.
  ran=$(( ran + 1 ))
  printf '#!/usr/bin/env bash\necho "${HAVEN_BUILD_RETRY_BUDGET_SECS} ${HAVEN_BUILD_MAX_ATTEMPTS} ${HAVEN_GRADLE_OFFLINE:-online} $*" > "%s/wrapper.env"\n' "${tmp}" > "${tmp}/fake-wrapper"
  ( retry_wrapper() { printf '%s' "${tmp}/fake-wrapper"; }; unset HAVEN_GRADLE_OFFLINE; resolve_online )
  [[ "$(cat "${tmp}/wrapper.env")" == "${ONLINE_BUDGET_SECS} ${ONLINE_MAX_ATTEMPTS} online --resolve-only" ]] \
    || _fail 13 "resolve_online must run the wrapper online with budget ${ONLINE_BUDGET_SECS} and ${ONLINE_MAX_ATTEMPTS} attempts; got '$(cat "${tmp}/wrapper.env")'"

  # (12) The canary judgement, both directions: the outputs Gradle 9.5.0 really
  #      printed pass; the answer a FILE repository gets offline (a plain "Could
  #      not find": offline does not cover it), and strictness runs that name
  #      nothing or the wrong build, each fail.
  ran=$(( ran + 1 ))
  local good_off="> Could not resolve all files for configuration ':inc:compileClasspath'.
   > Could not resolve ${CANARY_COORDINATE}.
      > No cached version of ${CANARY_COORDINATE} available for offline mode."
  local file_repo_off="> Could not resolve all files for configuration ':inc:compileClasspath'.
   > Could not find ${CANARY_COORDINATE}.
     Searched in the following locations:
       - file:/tmp/x/empty-repo/invalid/haven/gradle-deps/canary/absent/0.0.0/absent-0.0.0.pom"
  local good_top="> havenResolveAll: 1 configuration(s) did not resolve:
  haven-canary-top project 'havenCanary': Could not resolve all files for configuration ':havenCanary'."
  local good_inc="> havenResolveAll: 1 configuration(s) did not resolve:
  haven-canary-included project 'havenCanary': Could not resolve all files for configuration ':inc:havenCanary'."
  judge_canaries "${good_off}" "${good_top}" "${good_inc}" "${good_inc}" 2>/dev/null || _fail 12 "the real canary outputs must pass"
  judge_canaries "${file_repo_off}" "${good_top}" "${good_inc}" "${good_inc}" 2>/dev/null && _fail 12 "a plain 'Could not find' must fail the offline canary"
  judge_canaries "${good_off}" "BUILD SUCCESSFUL" "${good_inc}" "${good_inc}" 2>/dev/null && _fail 12 "a strictness run whose top build names nothing must fail"
  judge_canaries "${good_off}" "${good_top}" "${good_top}" "${good_inc}" 2>/dev/null && _fail 12 "a strictness run that misses the included build must fail"
  judge_canaries "${good_off}" "${good_top}" "${good_inc}" "${good_top}" 2>/dev/null && _fail 12 "a strictness run that misses the pluginManagement-included build must fail"

  if (( failures )); then
    echo "${SCRIPT_NAME}: SELF-TEST FAILED" >&2
    return 1
  fi
  if (( ran != SELF_TEST_FIXTURES )); then
    echo "${SCRIPT_NAME}: SELF-TEST FAILED — ran ${ran} fixture(s), expected exactly ${SELF_TEST_FIXTURES}" >&2
    return 1
  fi
  echo "${SCRIPT_NAME}: self-test passed (${ran}/${SELF_TEST_FIXTURES} fixtures: the key is stable, moved by every keyed input and by the Flutter revision and by nothing untracked or unkeyed; a source is taken only from a trusted workflow's push or schedule run on main in this repository, never a pull request's, a fork's, another workflow's or an expired one, the newest wins, and an unanswered listing resolves online with a warning; a fork's or an off-main source is refused by the listing's own fields before any run is read, and a flood of sources reads at most ${SOURCE_CANDIDATES} runs; pack and unpack carry exactly the module cache and the unpacked distribution, delete the tarball and pin Flutter, a malformed version is refused before anything is written, a truncated set fails, pins nothing and keeps its tarball, and a set's stray init.d or gradle.properties never lands; a source that verifies offline is used as is, one that does not is topped up, re-verified and replaced with its gap only a warning, one that does not unpack is resolved from an empty cache, and a failed online resolution, offline verification or canary packs and outputs nothing; the online resolution gets the ${ONLINE_BUDGET_SECS} s budget and ${ONLINE_MAX_ATTEMPTS} attempts; the canary judgement passes Gradle's real outputs and fails a file repository's plain answer, a top build that names nothing and a run that misses the included or the pluginManagement-included build)."
}

case "${1:-}" in
  --self-test) [[ $# -eq 1 ]] || { err "usage: ${SCRIPT_NAME} --self-test"; exit "${RC_BROKEN}"; }; run_self_test ;;
  key) compute_key; echo ;;
  produce) produce ;;
  unpack) [[ $# -eq 2 ]] || { err "usage: ${SCRIPT_NAME} unpack <dir>"; exit "${RC_BROKEN}"; }; unpack "$2" ;;
  *) err "usage: ${SCRIPT_NAME} key | produce | unpack <dir> | --self-test"; exit "${RC_BROKEN}" ;;
esac
