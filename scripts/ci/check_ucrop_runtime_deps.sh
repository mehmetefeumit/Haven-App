#!/usr/bin/env bash
# CI guard: the crop editor's AndroidX classes are Haven's own dependencies,
# and the start-up initializers that ship are a decision, not a side effect.
#
# uCrop 2.2.11 (image_cropper 12.2.1's crop editor, from JitPack) publishes a
# POM that declares NO dependencies. The AppCompat, Transition and
# ExifInterface classes its activity loads reached the APK only through other
# plugins' graphs (shared_preferences_android -> androidx.preference), so a
# plugin bump that dropped them would kill the process the moment the editor
# opened (hnvn/flutter_image_cropper#573: NoClassDefFoundError
# AppCompatActivity). haven/android/app/build.gradle.kts declares them at the
# versions uCrop 2.2.11 is built against.
#
# AppCompat brings emoji2, whose EmojiCompatInitializer asks the system font
# provider for the emoji font at every cold start — a cross-app request naming
# Haven. The manifest removes it; this guard keeps it removed, and pins the
# whole set of androidx.startup initializers in the release APK, so a new one
# arriving with a dependency fails here instead of shipping unnoticed.
#
# Modes:
#   check_ucrop_runtime_deps.sh                         static: the gradle file
#                                                       and the source manifest
#   check_ucrop_runtime_deps.sh --resolved <file>       output of `./gradlew -q
#        :app:dependencies --configuration releaseRuntimeClasspath`: what Gradle
#        actually resolved (another graph may raise a version, never lower it)
#   check_ucrop_runtime_deps.sh --merged-manifest <file>  `aapt2 dump xmltree
#        --file AndroidManifest.xml <release apk>`: the initializers that ship
#   check_ucrop_runtime_deps.sh --self-test             hermetic fixtures
#
# Exit: 0 pass, 1 a violation, 2 usage or an input that proves nothing.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
GRADLE_FILE="${REPO_ROOT}/haven/android/app/build.gradle.kts"
MANIFEST="${REPO_ROOT}/haven/android/app/src/main/AndroidManifest.xml"

# group:artifact minimum — uCrop 2.2.11's own build.gradle `ext` block.
readonly REQUIRED=(
  "androidx.appcompat:appcompat 1.7.1"
  "androidx.transition:transition 1.6.0"
  "androidx.exifinterface:exifinterface 1.4.1"
)

# The androidx.startup initializers the release APK may carry, sorted.
readonly STARTUP_INITIALIZERS="androidx.lifecycle.ProcessLifecycleInitializer
androidx.profileinstaller.ProfileInstallerInitializer
androidx.work.WorkManagerInitializer"

readonly EMOJI_INITIALIZER="androidx.emoji2.text.EmojiCompatInitializer"

# version_at_least <have> <want>
version_at_least() {
  [[ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -n1)" == "$2" ]]
}

# check_static <build.gradle.kts> <AndroidManifest.xml>
check_static() {
  local gradle="$1" manifest="$2" fail=0 entry coord want have
  for entry in "${REQUIRED[@]}"; do
    coord="${entry% *}" want="${entry#* }"
    have="$(grep -oE "^[[:space:]]*implementation\(\"${coord//./\\.}:[^\"]+\"\)" "${gradle}" \
      | sed -E 's/.*:([^:"]+)"\)$/\1/' | head -n1 || true)"
    if [[ -z "${have}" ]]; then
      echo "FAIL S1 ${coord}: not declared as an implementation dependency" >&2
      fail=1
    elif ! version_at_least "${have}" "${want}"; then
      echo "FAIL S1 ${coord}: declared ${have}, below ${want}" >&2
      fail=1
    fi
  done
  if ! xmllint --noout "${manifest}" 2>/dev/null; then
    echo "FAIL S2 the manifest is not well-formed XML" >&2
    return 1
  fi
  local removed
  removed="$(xmllint --xpath "count(/manifest/application/provider[@*[local-name()='name']='androidx.startup.InitializationProvider'][@*[local-name()='node']='merge']/meta-data[@*[local-name()='name']='${EMOJI_INITIALIZER}'][@*[local-name()='node']='remove'])" "${manifest}" 2>/dev/null || echo 0)"
  if [[ "${removed}" != "1" ]]; then
    echo "FAIL S2 ${EMOJI_INITIALIZER} is not removed from androidx.startup's InitializationProvider (tools:node=\"remove\" under a tools:node=\"merge\" provider)" >&2
    fail=1
  fi
  return "${fail}"
}

# check_resolved <gradle dependencies output>
check_resolved() {
  local deps="$1" fail=0 entry coord want versions have
  for entry in "${REQUIRED[@]}"; do
    coord="${entry% *}" want="${entry#* }"
    # `+--- g:a:1.1.0 -> 1.7.1 (*)` resolves to the version after the arrow.
    versions="$(awk -v c="${coord}:" '{
      for (i = 1; i <= NF; i++) if (index($i, c) == 1) {
        v = substr($i, length(c) + 1)
        if ($(i + 1) == "->") v = $(i + 2)
        print v
      }
    }' "${deps}" | sort -u)"
    if [[ -z "${versions}" ]]; then
      echo "VACUOUS R1 ${coord}: absent from the resolved graph" >&2
      return 2
    fi
    while IFS= read -r have; do
      if ! version_at_least "${have}" "${want}"; then
        echo "FAIL R1 ${coord}: resolved ${have}, below ${want}" >&2
        fail=1
      fi
    done <<<"${versions}"
  done
  return "${fail}"
}

# check_merged_manifest <aapt2 xmltree output>
check_merged_manifest() {
  local tree="$1" found
  # A meta-data's name attribute precedes its value; pair them per element.
  found="$(awk '
    /E: meta-data/ { name = ""; next }
    /A: http:\/\/schemas.android.com\/apk\/res\/android:name\(/ {
      if (match($0, /="[^"]*"/)) name = substr($0, RSTART + 2, RLENGTH - 3)
      next
    }
    /A: http:\/\/schemas.android.com\/apk\/res\/android:value\(/ {
      if ($0 ~ /="androidx\.startup"/ && name != "") print name
    }
  ' "${tree}" | sort -u)"
  if [[ -z "${found}" ]]; then
    echo "VACUOUS M1 no androidx.startup initializer found: not an aapt2 xmltree of the app manifest" >&2
    return 2
  fi
  if [[ "${found}" != "${STARTUP_INITIALIZERS}" ]]; then
    echo "FAIL M1 the release APK's androidx.startup initializers changed:" >&2
    diff <(echo "${STARTUP_INITIALIZERS}") <(echo "${found}") | sed -n 's/^[<>] /  &/p' >&2 || true
    echo "  ('<' expected, '>' shipped; a new initializer is a decision: list it here, or remove it in AndroidManifest.xml)" >&2
    return 1
  fi
}

self_test() {
  local tmp failures=0
  tmp="$(mktemp -d)"
  trap 'rm -rf "${tmp}"' RETURN

  _case() { # <name> <want rc> <command...>
    local name="$1" want="$2" got=0
    shift 2
    "$@" >/dev/null 2>&1 || got=$?
    if [[ "${got}" != "${want}" ]]; then
      echo "self-test FAILED [${name}]: expected exit ${want}, got ${got}" >&2
      failures=$((failures + 1))
    fi
  }

  # Static, over the repository's own files and mutations of them.
  cp "${GRADLE_FILE}" "${tmp}/g.kts"
  cp "${MANIFEST}" "${tmp}/m.xml"
  _case "the repository's files pass" 0 check_static "${tmp}/g.kts" "${tmp}/m.xml"
  sed '/androidx\.transition:transition/d' "${tmp}/g.kts" >"${tmp}/g-no-transition.kts"
  _case "a dropped declaration fails" 1 check_static "${tmp}/g-no-transition.kts" "${tmp}/m.xml"
  sed 's/appcompat:appcompat:1\.7\.1/appcompat:appcompat:1.6.1/' "${tmp}/g.kts" >"${tmp}/g-low.kts"
  _case "a lower version fails" 1 check_static "${tmp}/g-low.kts" "${tmp}/m.xml"
  sed 's/appcompat:appcompat:1\.7\.1/appcompat:appcompat:1.10.0/' "${tmp}/g.kts" >"${tmp}/g-high.kts"
  _case "a higher version passes, compared as a version" 0 check_static "${tmp}/g-high.kts" "${tmp}/m.xml"
  sed 's|^\(\s*\)implementation("androidx\.exifinterface|\1// implementation("androidx.exifinterface|' "${tmp}/g.kts" >"${tmp}/g-commented.kts"
  _case "a commented-out declaration fails" 1 check_static "${tmp}/g-commented.kts" "${tmp}/m.xml"
  sed '/androidx\.emoji2\.text\.EmojiCompatInitializer/{n;s/tools:node="remove"/tools:node="merge"/}' "${tmp}/m.xml" >"${tmp}/m-kept.xml"
  _case "an emoji2 initializer no longer removed fails" 1 check_static "${tmp}/g.kts" "${tmp}/m-kept.xml"
  printf '<manifest>\n' >"${tmp}/m-broken.xml"
  _case "a malformed manifest fails" 1 check_static "${tmp}/g.kts" "${tmp}/m-broken.xml"

  # Resolved graph.
  cat >"${tmp}/deps.txt" <<'TXT'
releaseRuntimeClasspath - Runtime classpath of /release.
+--- androidx.appcompat:appcompat:1.7.1
|    +--- androidx.emoji2:emoji2:1.3.0
+--- androidx.transition:transition:1.6.0
+--- androidx.exifinterface:exifinterface:1.4.1 -> 1.4.2
\--- project :shared_preferences_android
     \--- androidx.preference:preference:1.2.1
          +--- androidx.appcompat:appcompat:1.1.0 -> 1.7.1 (*)
          \--- androidx.transition:transition:1.4.1 -> 1.6.0 (c)
TXT
  _case "a resolved graph at or above every floor passes" 0 check_resolved "${tmp}/deps.txt"
  sed 's/appcompat:1\.1\.0 -> 1\.7\.1/appcompat:1.1.0 -> 1.1.0/' "${tmp}/deps.txt" >"${tmp}/deps-low.txt"
  _case "a resolved version below its floor fails" 1 check_resolved "${tmp}/deps-low.txt"
  sed '/exifinterface/d' "${tmp}/deps.txt" >"${tmp}/deps-none.txt"
  _case "a module absent from the graph is vacuous" 2 check_resolved "${tmp}/deps-none.txt"

  # Merged manifest, over a REAL aapt2 dump (v0.1.14, which shipped emoji2's).
  local real="${REPO_ROOT}/scripts/ci/fixtures/apk_loadable/v0.1.14.manifest.txt"
  grep -v '^#' "${real}" >"${tmp}/x-shipped.txt"
  _case "v0.1.14's manifest, emoji2's initializer included, fails" 1 check_merged_manifest "${tmp}/x-shipped.txt"
  awk '/androidx\.emoji2\.text\.EmojiCompatInitializer/ { skip = 2; next } skip > 0 && /android:value/ { skip = 0; next } { print }' \
    "${tmp}/x-shipped.txt" >"${tmp}/x-removed.txt"
  _case "the same manifest without it passes" 0 check_merged_manifest "${tmp}/x-removed.txt"
  sed 's/androidx\.profileinstaller\.ProfileInstallerInitializer/androidx.example.NewInitializer/g' \
    "${tmp}/x-removed.txt" >"${tmp}/x-new.txt"
  _case "an initializer nobody listed fails" 1 check_merged_manifest "${tmp}/x-new.txt"
  sed 's/="androidx\.startup"/="other"/' "${tmp}/x-removed.txt" >"${tmp}/x-none.txt"
  _case "no androidx.startup meta-data is vacuous" 2 check_merged_manifest "${tmp}/x-none.txt"

  if ((failures > 0)); then
    echo "uCrop runtime-deps guard: self-test FAILED (${failures})" >&2
    return 1
  fi
  echo "uCrop runtime-deps guard: self-test OK (14 fixtures)."
}

case "${1:-}" in
  --self-test) self_test ;;
  --resolved)
    [[ -f "${2:-}" ]] || { echo "usage: $0 --resolved <gradle dependencies output>" >&2; exit 2; }
    check_resolved "$2"
    echo "OK: uCrop's AndroidX dependencies resolve at or above their floors."
    ;;
  --merged-manifest)
    [[ -f "${2:-}" ]] || { echo "usage: $0 --merged-manifest <aapt2 xmltree output>" >&2; exit 2; }
    check_merged_manifest "$2"
    echo "OK: the release APK carries exactly the listed androidx.startup initializers."
    ;;
  "")
    check_static "${GRADLE_FILE}" "${MANIFEST}"
    echo "OK: uCrop's AndroidX dependencies are declared and emoji2's initializer is removed."
    ;;
  *) echo "usage: $0 [--self-test | --resolved <file> | --merged-manifest <file>]" >&2; exit 2 ;;
esac
