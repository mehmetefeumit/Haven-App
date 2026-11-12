#!/usr/bin/env bash
# CI guard: what the built Android library exports to Java and imports from
# `liblog` (docs/BLUETOOTH_MESH_M3_DESIGN.md §A.6, N-2, N-3, §N.4).
#
# `check_mesh_radio.sh` reads the bridge crate's source. This reads the
# artifact, which no way of writing the source gets past:
#
#   * EXPORTS. Kotlin finds a native method by its symbol when the method is
#     first called, so a name that is missing is a crash at that call, and a
#     `Java_*` symbol nobody pinned is a native entry no guard has read. The
#     library's defined `Java_*` symbols must be exactly the methods of
#     `haven/rust_builder/fixtures/mesh_radio_exports.txt`, each as
#     `Java_com_oblivioustech_haven_mesh_MeshNative_<name>`, and the one the
#     keyring's crate exports (`android-native-keyring-store`, called from
#     `HavenApplication`).
#
#   * IMPORTS. An undefined symbol the device's `liblog` does not have stops
#     the library loading — all of Haven, on that Android. The log lever's
#     five functions exist from API 30 and Haven runs from API 23, which is
#     why `log_lever.rs` finds them with `dlsym`; and a dependency's feature
#     can import another (`android_logger`'s `android-api-30` imports
#     `__android_log_is_loggable_len`). So every undefined `__android_log_*`
#     symbol must be one of OLD_LIBLOG: the six functions `android/log.h`
#     declares with no `__INTRODUCED_IN` (read at android-11.0.0_r1), there on
#     every release Haven runs on. The library is expected to need two of
#     them, `__android_log_write` and `__android_log_buf_write`. A weak
#     reference is listed with the rest and fails with them: it would load,
#     and nothing here should be one.
#
# It reads names and nothing else: not a symbol's type, not what an export
# does. Which lane runs it: `build-check.yml`, on the library of each of the
# three ABIs' debug APK. A release build's library is not read.
#
# Usage:
#   bash scripts/ci/check_mesh_radio_symbols.sh <file or directory>...
#       every librust_lib_haven.so that is, or is under, an argument
#   bash scripts/ci/check_mesh_radio_symbols.sh --self-test
#
# NM names the symbol lister (default `nm`; `llvm-nm` takes the same flags).
#
# Exit codes:
#   0  every library exports and imports what is pinned (or the self-test
#      passed)
#   1  a library exports another set of `Java_*` symbols, or imports an
#      `__android_log_*` symbol that is not an old one
#   2  no library to read, no symbol lister, a listing that failed or is
#      empty, or a fixture that lists no method — the check would be reading
#      nothing (misconfiguration)

set -euo pipefail

REPO_ROOT="${REPO_ROOT_OVERRIDE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
readonly EXPORTS="${REPO_ROOT}/haven/rust_builder/fixtures/mesh_radio_exports.txt"
readonly LIBRARY='librust_lib_haven.so'
readonly NM="${NM:-nm}"
readonly PREFIX='Java_com_oblivioustech_haven_mesh_MeshNative_'
readonly KEYRING='Java_io_crates_keyring_Keyring_00024Companion_initializeNdkContext'
readonly -a OLD_LIBLOG=(
  __android_log_write
  __android_log_print
  __android_log_vprint
  __android_log_assert
  __android_log_buf_write
  __android_log_buf_print
)

log() {
  printf '\033[1;34m[check_mesh_radio_symbols]\033[0m %s\n' "$*"
}

fail() {
  printf '\033[1;31m[check_mesh_radio_symbols] FAIL:\033[0m %s\n' "$*" >&2
  FAILED=1
}

# The names of a library's dynamic symbols, defined or undefined, one a line,
# without the version a symbol may carry (`name@LIBLOG`).
names() { # <--defined-only|--undefined-only> <library>
  local listing
  listing="$("${NM}" -D "$1" "$2")" || { echo "ERROR: '${NM} -D $1 $2' failed — is it a library this ${NM} reads?" >&2; exit 2; }
  awk 'NF { name = $NF; sub(/@.*$/, "", name); print name }' <<<"${listing}" | LC_ALL=C sort -u
}

run_check() {
  local path library pinned want defined found undefined old name names_diff
  local -a libraries=()
  FAILED=0

  [[ -f "${EXPORTS}" ]] || { echo "ERROR: ${EXPORTS} not found" >&2; exit 2; }
  command -v "${NM}" >/dev/null || { echo "ERROR: no '${NM}' to list symbols with" >&2; exit 2; }
  pinned="$(awk '!/^[[:space:]]*(#|$)/ { print $1 }' "${EXPORTS}")"
  [[ -n "${pinned}" ]] || { echo "ERROR: ${EXPORTS} lists no method — the check would be reading nothing" >&2; exit 2; }
  want="$({ sed "s/^/${PREFIX}/" <<<"${pinned}"; echo "${KEYRING}"; } | LC_ALL=C sort -u)"

  for path in "$@"; do
    [[ -e "${path}" ]] || { echo "ERROR: ${path} not found" >&2; exit 2; }
    while IFS= read -r library; do
      libraries+=("${library}")
    done < <(find "${path}" -type f -name "${LIBRARY}" | LC_ALL=C sort)
  done
  (( ${#libraries[@]} > 0 )) || { echo "ERROR: no ${LIBRARY} in: $* — the check would be reading nothing" >&2; exit 2; }

  for library in "${libraries[@]}"; do
    defined="$(names --defined-only "${library}")"
    [[ -n "${defined}" ]] || { echo "ERROR: ${library} defines no dynamic symbol — not a library this check can read" >&2; exit 2; }
    found="$(grep -E '^Java_' <<<"${defined}" || true)"
    if [[ "${found}" != "${want}" ]]; then
      names_diff="$(diff <(printf '%s\n' "${want}") <(printf '%s\n' "${found}") | grep -E '^[<>]' | tr '\n' ';' || true)"
      fail "${library} does not export exactly the pinned Java_* symbols ('<' pinned and missing, '>' exported and not pinned: ${names_diff}). Kotlin finds a native method by this name at its first call; one that is missing is a crash there, and one that is not pinned is a native entry no guard has read. The pins are ${EXPORTS#"${REPO_ROOT}/"} and the keyring's ${KEYRING}."
    fi
    undefined="$(names --undefined-only "${library}")"
    while IFS= read -r name; do
      [[ "${name}" == __android_log_* ]] || continue
      for old in "${OLD_LIBLOG[@]}"; do
        [[ "${name}" == "${old}" ]] && continue 2
      done
      fail "${library} imports ${name}, which is none of the liblog functions every Android Haven runs on has (${OLD_LIBLOG[*]}). Where the device's liblog lacks an imported symbol the library does not load: Haven would not start there. A function newer than that is found at run time, as log_lever.rs finds its five."
    done <<<"${undefined}"
  done

  if (( FAILED )); then
    exit 1
  fi
  log "OK: ${#libraries[@]} librar$( (( ${#libraries[@]} == 1 )) && echo y || echo ies) export the $(grep -c . <<<"${pinned}") pinned methods of MeshNative and the keyring's one and no other Java_* symbol, and import no __android_log_* symbol but an old one."
}

# ---------------------------------------------------------------------------
# Self-test. Each fixture is a tree with a fixture file and libraries whose
# listings a stand-in for `nm` prints, run through the real entry point.
# ---------------------------------------------------------------------------
self_test() {
  local tmp fails=0 checked=0
  tmp="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf '${tmp}'" RETURN

  # Prints `<library>.defined` or `<library>.undefined` as `nm -D` would, and
  # fails for a library that has neither.
  cat >"${tmp}/nm" <<'SH'
#!/usr/bin/env bash
[[ "$1" == "-D" ]] || exit 64
case "$2" in
  --defined-only) cat "$3.defined" ;;
  --undefined-only) cat "$3.undefined" ;;
  *) exit 64 ;;
esac
SH
  chmod +x "${tmp}/nm"

  _tree() { # <tree>
    local t="$1" abi
    mkdir -p "${t}/haven/rust_builder/fixtures"
    cat >"${t}/haven/rust_builder/fixtures/mesh_radio_exports.txt" <<'TXT'
# <name> <JNI descriptor> <Rust parameter types> <Rust return type>

leftMs ()J - jlong
receive (J[B)V jlong,JByteArray -
leverInstall ()Z - jboolean
TXT
    for abi in arm64-v8a armeabi-v7a; do
      mkdir -p "${t}/lib/${abi}"
      : >"${t}/lib/${abi}/${LIBRARY}"
      cat >"${t}/lib/${abi}/${LIBRARY}.defined" <<'NM'
000000000012e3b0 T Java_com_oblivioustech_haven_mesh_MeshNative_leftMs
000000000012e3f4 T Java_com_oblivioustech_haven_mesh_MeshNative_leverInstall
000000000012e438 T Java_com_oblivioustech_haven_mesh_MeshNative_receive
00000000003a1c20 T Java_io_crates_keyring_Keyring_00024Companion_initializeNdkContext
00000000001f0a10 T frb_pde_ffi_dispatcher_primary
0000000000a41b08 D __android_log_set_logger_is_only_a_name_here
NM
      cat >"${t}/lib/${abi}/${LIBRARY}.undefined" <<'NM'
                 U __android_log_buf_write@LIBLOG
                 U __android_log_write
                 U dlopen@LIBC
                 U dlsym
                 w __cxa_finalize
NM
    done
  }
  _case() { # <label> <want-rc> <want-msg-substring> <tree> [argument...]
    local label="$1" want="$2" msg="$3" tree="$4" got=0 out
    shift 4
    (( $# > 0 )) || set -- "${tree}/lib"
    checked=$(( checked + 1 ))
    out="$(env REPO_ROOT_OVERRIDE="${tree}" NM="${NM_OVERRIDE:-${tmp}/nm}" bash "${BASH_SOURCE[0]}" "$@" 2>&1)" || got=$?
    if [[ "${got}" -ne "${want}" ]]; then
      printf '  \033[1;31mFAIL\033[0m %s (want rc=%d, got rc=%d)\n%s\n' "${label}" "${want}" "${got}" "${out}" >&2
      fails=1
    elif [[ -n "${msg}" && "${out}" != *"${msg}"* ]]; then
      printf '  \033[1;31mFAIL\033[0m %s (rc=%d, but no message matched %q)\n%s\n' "${label}" "${got}" "${msg}" "${out}" >&2
      fails=1
    else
      printf '  \033[1;32mPASS\033[0m %s\n' "${label}"
    fi
  }

  echo "check_mesh_radio_symbols.sh --self-test"
  local t="${tmp}/ok" arm
  _tree "${t}"
  _case "two libraries that export the pinned methods and the keyring's, and import two old liblog functions, one with its version, pass" 0 '2 libraries export the 3 pinned methods' "${t}"
  _case "one library named by its own path passes" 0 '1 library export' "${t}" "${t}/lib/arm64-v8a/${LIBRARY}"

  # Exports.
  t="${tmp}/missing"; _tree "${t}"; arm="${t}/lib/armeabi-v7a/${LIBRARY}"
  sed -i '/MeshNative_leverInstall$/d' "${arm}.defined"
  _case "a pinned method one library does not export fails, and that library is named" 1 "armeabi-v7a/${LIBRARY} does not export exactly" "${t}"
  _case "and the missing symbol is named" 1 '< Java_com_oblivioustech_haven_mesh_MeshNative_leverInstall' "${t}"

  t="${tmp}/extra"; _tree "${t}"; arm="${t}/lib/armeabi-v7a/${LIBRARY}"
  printf '000000000012e47c T Java_com_oblivioustech_haven_mesh_MeshNative_reset\n' >>"${arm}.defined"
  _case "an exported method of MeshNative that is not pinned fails" 1 '> Java_com_oblivioustech_haven_mesh_MeshNative_reset' "${t}"

  t="${tmp}/foreign"; _tree "${t}"; arm="${t}/lib/armeabi-v7a/${LIBRARY}"
  printf '00000000004b0000 T Java_com_example_plugin_Native_init\n' >>"${arm}.defined"
  _case "a Java_* symbol of another class fails: a native entry nobody pinned" 1 '> Java_com_example_plugin_Native_init' "${t}"

  t="${tmp}/no-keyring"; _tree "${t}"; arm="${t}/lib/armeabi-v7a/${LIBRARY}"
  sed -i '/Java_io_crates_keyring_/d' "${arm}.defined"
  _case "the keyring's export gone fails" 1 '< Java_io_crates_keyring_Keyring_00024Companion_initializeNdkContext' "${t}"

  t="${tmp}/renamed"; _tree "${t}"; arm="${t}/lib/armeabi-v7a/${LIBRARY}"
  sed -i 's/MeshNative_leftMs$/MeshNative_left_1ms/' "${arm}.defined"
  _case "an export under another name fails both ways" 1 '> Java_com_oblivioustech_haven_mesh_MeshNative_left_1ms' "${t}"

  # Imports.
  t="${tmp}/api-30"; _tree "${t}"; arm="${t}/lib/armeabi-v7a/${LIBRARY}"
  printf '                 U __android_log_set_logger\n' >>"${arm}.undefined"
  _case "one of the lever's five imported fails: Android 6 to 10 cannot bind it" 1 'imports __android_log_set_logger,' "${t}"

  t="${tmp}/api-30-feature"; _tree "${t}"; arm="${t}/lib/armeabi-v7a/${LIBRARY}"
  printf '                 U __android_log_is_loggable_len@LIBLOG_R\n' >>"${arm}.undefined"
  _case "the import a dependency's API-30 feature makes fails, its version read off" 1 'imports __android_log_is_loggable_len,' "${t}"

  t="${tmp}/weak"; _tree "${t}"; arm="${t}/lib/armeabi-v7a/${LIBRARY}"
  printf '                 w __android_log_write_log_message\n' >>"${arm}.undefined"
  _case "a weak reference to a new function fails with the rest" 1 'imports __android_log_write_log_message,' "${t}"

  t="${tmp}/old"; _tree "${t}"; arm="${t}/lib/armeabi-v7a/${LIBRARY}"
  printf '                 U __android_log_print\n                 U __android_log_assert@LIBLOG\n' >>"${arm}.undefined"
  _case "the other old liblog functions imported pass" 0 '' "${t}"

  # Misconfiguration.
  t="${tmp}/nowhere"; _tree "${t}"
  rm -r "${t}/lib"; mkdir -p "${t}/lib/arm64-v8a"; : >"${t}/lib/arm64-v8a/libflutter.so"
  _case "a path that holds no library of Haven's is a misconfiguration, not a pass" 2 'would be reading nothing' "${t}"

  t="${tmp}/absent"; _tree "${t}"
  _case "a path that is not there is a misconfiguration" 2 'not found' "${t}" "${t}/apk-lib"

  t="${tmp}/unlisted"; _tree "${t}"
  rm "${t}/lib/arm64-v8a/${LIBRARY}.undefined"
  _case "a listing that fails is a misconfiguration" 2 'failed' "${t}"

  t="${tmp}/empty"; _tree "${t}"
  : >"${t}/lib/arm64-v8a/${LIBRARY}.defined"
  _case "a library with no dynamic symbol is a misconfiguration, not a set of missing exports" 2 'defines no dynamic symbol' "${t}"

  t="${tmp}/unpinned"; _tree "${t}"
  sed -i '/^[a-zA-Z]/d' "${t}/haven/rust_builder/fixtures/mesh_radio_exports.txt"
  _case "a fixture that lists no method is a misconfiguration" 2 'lists no method' "${t}"

  t="${tmp}/no-fixture"; _tree "${t}"
  rm "${t}/haven/rust_builder/fixtures/mesh_radio_exports.txt"
  _case "a missing fixture is a misconfiguration" 2 'not found' "${t}"

  t="${tmp}/no-lister"; _tree "${t}"
  NM_OVERRIDE="${tmp}/no-such-nm" _case "no symbol lister is a misconfiguration" 2 'to list symbols with' "${t}"

  if (( fails )); then
    echo "self-test: FAILED" >&2
    return 1
  fi
  if (( checked != 19 )); then
    echo "self-test: ran ${checked} fixture(s), expected exactly 19. A fixture was added or removed without moving the pin." >&2
    return 1
  fi
  echo "self-test: OK (${checked}/19 fixtures)"
}

case "${1:-}" in
  --self-test) self_test ;;
  '') echo "usage: $(basename "$0") <file or directory>... | --self-test" >&2; exit 2 ;;
  *) run_check "$@" ;;
esac
