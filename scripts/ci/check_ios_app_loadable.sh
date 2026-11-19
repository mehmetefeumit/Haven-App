#!/usr/bin/env bash
# CI guard: an iOS app bundle can be loaded — every library it links resolves,
# and the framework Dart opens exports every symbol the bridge looks up.
#
# A simulator cannot run the Release Dart AOT build that TestFlight receives,
# so the iOS launch gate starts a Release-native/debug-Dart build instead
# (docs/LAUNCH_GATE.md). Two release-only load failures stay visible without
# a device, in the Mach-O load commands and export tables, and this reads them:
#
#   I1  dyld closure. Every LC_LOAD_DYLIB / LC_LOAD_WEAK_DYLIB /
#       LC_REEXPORT_DYLIB / LC_LOAD_UPWARD_DYLIB / LC_LAZY_LOAD_DYLIB of the
#       main executable, of every Frameworks/*.framework and Frameworks/*.dylib
#       and of every PlugIns/*.appex resolves: inside the bundle through
#       @executable_path, @loader_path or one of the image's (or the main
#       executable's) LC_RPATHs, or to the OS under /usr/lib or /System (by an
#       OS rpath, a Swift runtime library only). Any other absolute path is a
#       build machine's, which no device has. A weak load may be absent only if
#       WEAK_ABSENT_ALLOWED names it; the type is read from each `cmd` line.
#   I2  bridge exports. Frameworks/rust_lib_haven.framework/rust_lib_haven
#       itself (`nm -gU`, every architecture of a universal binary) exports
#       every `frbgen_haven_*` symbol haven/lib/src/rust/frb_generated.io.dart
#       looks up, and every runtime symbol the flutter_rust_bridge Dart package
#       looks up (FRB_RUNTIME_SYMBOLS below). A missing one is a
#       "Failed to lookup symbol" at RustLib.init, before the first frame.
#
# Fail closed (rc 2) where a pass would be vacuous: no bundle, no main
# executable, no rust_lib_haven framework, an executable with no load command
# parsed or that does not link Flutter, no frbgen name derived, or a
# flutter_rust_bridge in haven/pubspec.lock other than the version the runtime
# list was read from.
#
# Usage:
#   check_ios_app_loadable.sh <Runner.app>
#   check_ios_app_loadable.sh --self-test    stubs otool/nm with text fixtures
#
# Tools: otool and nm (Xcode command-line tools), python3 for Info.plist.
# Exit: 0 loadable, 1 a library or symbol is missing, 2 cannot vouch.

set -euo pipefail
export LC_ALL=C

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
readonly REPO_ROOT
readonly SELF_TEST_FIXTURES=16

# Read from flutter_rust_bridge 2.11.1's Dart package (pub.dev archive sha256
# 37ef40bc…067e, the hash haven/pubspec.lock pins): every symbol
# lib/src/generalized_frb_rust_binding/_io.dart reaches through
# lib/src/ffigen_generated/multi_package.dart's lookups. The Dart_* lookups in
# that file are dart_api_dl shims the binding never calls. A different pinned
# version is rc 2 until this list is read again from that version.
readonly FRB_RUNTIME_VERSION='2.11.1'
readonly FRB_RUNTIME_SYMBOLS=(
  store_dart_post_cobject
  frb_create_shutdown_callback
  frb_init_frb_dart_api_dl
  frb_pde_ffi_dispatcher_primary
  frb_pde_ffi_dispatcher_sync
  frb_dart_fn_deliver_output
  frb_get_rust_content_hash
  frb_dart_opaque_dart2rust_encode
  frb_dart_opaque_rust2dart_decode
  frb_dart_opaque_drop_thread_box_persistent_handle
  frb_free_wire_sync_rust2dart_dco
  frb_free_wire_sync_rust2dart_sse
  frb_rust_vec_u8_new
  frb_rust_vec_u8_resize
  frb_rust_vec_u8_free
)
readonly RUST_FRAMEWORK='rust_lib_haven'

# Weak loads dyld may find absent, each with why. Flutter 3.50 builds iOS dev
# dependencies into every mode (flutter_tools flutter_plugins.dart:1512-1546,
# flutter/flutter#163874), and patrol's podspec weak-links XCTest, which no
# device ships. Remove the entry when #163874 lands.
readonly WEAK_ABSENT_ALLOWED='@rpath/XCTest.framework/XCTest'

OTOOL="${OTOOL:-otool}"
NM="${NM:-nm}"

say() { printf '[check_ios_app_loadable] %s\n' "$*"; }
cannot() { printf '[check_ios_app_loadable] CANNOT VOUCH: %s\n' "$*" >&2; exit 2; }

# The bundle executable an Info.plist names, or the bundle's own stem.
bundle_executable() { # <bundle dir>
  local plist="$1/Info.plist" stem
  stem="$(basename "$1")"; stem="${stem%.*}"
  if [[ -f "${plist}" ]]; then
    python3 -I -c '
import plistlib, sys
with open(sys.argv[1], "rb") as f:
    print(plistlib.load(f).get("CFBundleExecutable") or sys.argv[2])
' "${plist}" "${stem}"
  else
    printf '%s\n' "${stem}"
  fi
}

# `otool -l` -> "L\t<load command>\t<dylib>" per load and "R\t<rpath>" per
# LC_RPATH, over every architecture slice (a universal binary prints one block
# per slice).
load_commands() { # <binary>
  "${OTOOL}" -arch all -l "$1" | awk '
    $1 == "cmd" { cmd = $2; next }
    $1 == "name" && cmd ~ /^LC_(LOAD_DYLIB|LOAD_WEAK_DYLIB|REEXPORT_DYLIB|LOAD_UPWARD_DYLIB|LAZY_LOAD_DYLIB)$/ {
      v = $0; sub(/^[[:space:]]*name[[:space:]]+/, "", v); sub(/[[:space:]]+\(offset [0-9]+\)[[:space:]]*$/, "", v)
      print "L\t" cmd "\t" v; next
    }
    $1 == "path" && cmd == "LC_RPATH" {
      v = $0; sub(/^[[:space:]]*path[[:space:]]+/, "", v); sub(/[[:space:]]+\(offset [0-9]+\)[[:space:]]*$/, "", v)
      print "R\t" v; next
    }
  ' | sort -u
}

is_system_path() { [[ "$1" == /usr/lib/* || "$1" == /System/* ]]; }

# Expands @executable_path / @loader_path; prints the path or nothing.
expand_path() { # <path> <executable dir> <loader dir>
  local p="$1"
  case "${p}" in
    @executable_path/*) printf '%s/%s\n' "$2" "${p#@executable_path/}" ;;
    @loader_path/*)     printf '%s/%s\n' "$3" "${p#@loader_path/}" ;;
    @*)                 ;;
    *)                  printf '%s\n' "${p}" ;;
  esac
}

# 0 when <dylib> resolves for an image in <loader dir> with <rpaths>.
resolves() { # <dylib> <executable dir> <loader dir> <rpaths, newline-separated>
  local dylib="$1" exe_dir="$2" loader_dir="$3" rpaths="$4" r base cand
  if [[ "${dylib}" == @rpath/* ]]; then
    while IFS= read -r r; do
      [[ -n "${r}" ]] || continue
      base="$(expand_path "${r}" "${exe_dir}" "${loader_dir}")"
      [[ -n "${base}" ]] || continue
      cand="${base%/}/${dylib#@rpath/}"
      [[ -f "${cand}" ]] && return 0
      # An OS rpath serves the Swift runtime and nothing a bundle ships.
      if is_system_path "${cand}" && [[ "${dylib}" =~ ^@rpath/libswift[A-Za-z0-9_]*\.dylib$ ]]; then return 0; fi
    done <<<"${rpaths}"
    return 1
  fi
  cand="$(expand_path "${dylib}" "${exe_dir}" "${loader_dir}")"
  [[ -n "${cand}" ]] || return 1
  if is_system_path "${cand}"; then return 0; fi
  # An absolute path outside the OS is the build machine's, never a device's.
  [[ "${dylib}" == @* && -f "${cand}" ]]
}

# The frbgen_haven_* names the Dart bindings look up.
frbgen_names() {
  grep -oE "'frbgen_haven_[A-Za-z0-9_]+'" "${FRB_IO_DART}" | tr -d "'" | sort -u
}

# nm -gU -> one "<arch>\t<symbol>" per exported symbol, the Mach-O leading
# underscore removed; a thin binary's slice is "-".
exported_symbols() { # <binary>
  "${NM}" -gU "$1" | awk '
    /\(for architecture [^)]+\):$/ { a = $0; sub(/.*\(for architecture /, "", a); sub(/\):$/, "", a); arch = a; next }
    NF >= 3 && $(NF-1) ~ /^[A-Z]$/ { s = $NF; sub(/^_/, "", s); print (arch == "" ? "-" : arch) "\t" s }
  '
}

check_app() { # <Runner.app>
  local app="${1%/}" fails=0
  [[ -d "${app}" ]] || cannot "${app} is not a directory"
  local pinned
  pinned="$(awk '/^  flutter_rust_bridge:/ { f = 1; next } f && /^  [^ ]/ { f = 0 } f && /^    version:/ { gsub(/[" ]/, "", $2); print $2; exit }' "${PUBSPEC_LOCK}")"
  [[ "${pinned}" == "${FRB_RUNTIME_VERSION}" ]] \
    || cannot "haven/pubspec.lock pins flutter_rust_bridge '${pinned}', but the runtime symbol list was read from ${FRB_RUNTIME_VERSION}; read it again from that version's Dart package"

  local main_exe
  main_exe="${app}/$(bundle_executable "${app}")"
  [[ -f "${main_exe}" ]] || cannot "no main executable in the bundle"

  # The images dyld maps: the app, its frameworks and dylibs, its extensions.
  local -a images=("${main_exe}")
  local d
  for d in "${app}"/Frameworks/*.framework "${app}"/PlugIns/*.appex; do
    [[ -d "${d}" ]] || continue
    images+=("${d}/$(bundle_executable "${d}")")
  done
  for d in "${app}"/Frameworks/*.dylib; do
    [[ -f "${d}" ]] && images+=("${d}")
  done

  # I1
  local main_cmds main_rpaths img cmds rpaths kind dylib loads=0 exe_dir
  main_cmds="$(load_commands "${main_exe}")" || cannot "otool failed on the main executable"
  grep -q '^L	' <<<"${main_cmds}" || cannot "no load command parsed from the main executable"
  grep -qE '^L	LC_[A-Z_]+	@rpath/Flutter\.framework/Flutter$' <<<"${main_cmds}" \
    || cannot "the main executable does not link Flutter.framework: not a Flutter app bundle"
  main_rpaths="$(awk -F'\t' '$1 == "R" { print $2 }' <<<"${main_cmds}")"
  for img in "${images[@]}"; do
    [[ -f "${img}" ]] || { say "FAIL I1: ${img#"${app}"/} is a bundle without its executable"; fails=$((fails + 1)); continue; }
    cmds="$(load_commands "${img}")" || cannot "otool failed on ${img#"${app}"/}"
    rpaths="$(awk -F'\t' '$1 == "R" { print $2 }' <<<"${cmds}")"$'\n'"${main_rpaths}"
    exe_dir="${app}"
    [[ "${img}" == "${app}"/PlugIns/*.appex/* ]] && exe_dir="$(dirname "${img}")"
    while IFS=$'\t' read -r _ kind dylib; do
      loads=$((loads + 1))
      if resolves "${dylib}" "${exe_dir}" "$(dirname "${img}")" "${rpaths}"; then continue; fi
      if [[ "${kind}" == LC_LOAD_WEAK_DYLIB && "${dylib}" == "${WEAK_ABSENT_ALLOWED}" ]]; then
        say "allowed: ${img#"${app}"/} weak-links ${dylib}, absent on a device (WEAK_ABSENT_ALLOWED)"
        continue
      fi
      say "FAIL I1: ${img#"${app}"/} links ${dylib} (${kind}), which resolves nowhere in the bundle or the OS"
      fails=$((fails + 1))
    done < <(grep '^L	' <<<"${cmds}" || true)
  done

  # I2
  local rust_bin="${app}/Frameworks/${RUST_FRAMEWORK}.framework/${RUST_FRAMEWORK}"
  [[ -f "${rust_bin}" ]] || cannot "no Frameworks/${RUST_FRAMEWORK}.framework/${RUST_FRAMEWORK}: the bridge would have nothing to open"
  local -a wanted=()
  local name
  while IFS= read -r name; do [[ -n "${name}" ]] && wanted+=("${name}"); done < <(frbgen_names)
  (( ${#wanted[@]} > 0 )) || cannot "no frbgen_haven_* lookup found in haven/lib/src/rust/frb_generated.io.dart"
  local nbinding=${#wanted[@]}
  wanted+=("${FRB_RUNTIME_SYMBOLS[@]}")
  local syms arch
  syms="$(exported_symbols "${rust_bin}")" || cannot "nm failed on ${RUST_FRAMEWORK}"
  [[ -n "${syms}" ]] || cannot "nm listed no exported symbol in ${RUST_FRAMEWORK}"
  for arch in $(cut -f1 <<<"${syms}" | sort -u); do
    for name in "${wanted[@]}"; do
      if ! grep -qxF -e "${arch}	${name}" <<<"${syms}"; then
        say "FAIL I2: ${RUST_FRAMEWORK} (${arch/#-/thin}) does not export ${name}"
        fails=$((fails + 1))
      fi
    done
  done

  if (( fails > 0 )); then
    say "${fails} load failure(s): this bundle would not start"
    return 1
  fi
  say "OK: ${#images[@]} images, ${loads} load commands resolved; ${RUST_FRAMEWORK} exports ${nbinding} binding + ${#FRB_RUNTIME_SYMBOLS[@]} runtime symbols"
}

# ---------------------------------------------------------------------------
# --self-test: otool/nm replaced by stubs that print fixtures keyed by the
# binary's basename, over a bundle tree built in a temp dir.
# ---------------------------------------------------------------------------
self_test() {
  local tmp ran=0 fail=0
  tmp="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf '${tmp}'" EXIT
  mkdir -p "${tmp}/bin" "${tmp}/fx"
  cat >"${tmp}/bin/otool" <<'EOF'
#!/usr/bin/env bash
f="${FX_DIR}/otool.$(basename "${!#}")"
[[ -f "${f}" ]] && cat "${f}"
exit 0
EOF
  cat >"${tmp}/bin/nm" <<'EOF'
#!/usr/bin/env bash
cat "${FX_DIR}/nm.$(basename "${!#}")"
EOF
  chmod +x "${tmp}/bin/otool" "${tmp}/bin/nm"

  # Two binding names stand in for the generated twenty.
  cat >"${tmp}/frb_generated.io.dart" <<'EOF'
  late final _a = _lookup<ffi.NativeFunction<ffi.Void Function(ffi.Pointer<ffi.Void>)>>(
        'frbgen_haven_rust_arc_increment_strong_count_X',
      );
  late final _b = _lookup<ffi.NativeFunction<ffi.Void Function(ffi.Pointer<ffi.Void>)>>(
        'frbgen_haven_rust_arc_decrement_strong_count_X',
      );
EOF
  _lock() { printf 'packages:\n  flutter_rust_bridge:\n    dependency: "direct main"\n    source: hosted\n    version: "%s"\n  flutter_secure_storage:\n    version: "9.0.0"\n' "$1" >"${tmp}/pubspec.lock"; }

  _lc() { # <cmd> <value> -> one load command block in `otool -l`'s own layout
    if [[ "$1" == LC_RPATH ]]; then
      printf 'Load command 9\n          cmd LC_RPATH\n      cmdsize 32\n         path %s (offset 12)\n' "$2"
    else
      printf 'Load command 9\n          cmd %s\n      cmdsize 56\n         name %s (offset 24)\n   time stamp 2 Thu Jan  1 00:00:02 1970\n      current version 1.0.0\ncompatibility version 1.0.0\n' "$1" "$2"
    fi
  }
  _nm_line() { printf '0000000000012340 T _%s\n' "$1"; }
  _all_syms() {
    local s
    for s in frbgen_haven_rust_arc_increment_strong_count_X frbgen_haven_rust_arc_decrement_strong_count_X "${FRB_RUNTIME_SYMBOLS[@]}"; do
      [[ "${s}" == "${1:-}" ]] || _nm_line "${s}"
    done
    printf '0000000000000000 U _malloc\n'
  }

  # A healthy bundle: Runner links Flutter and the pods by @rpath, Swift
  # through an OS rpath, a weak OS library; the Rust framework links a sibling
  # by @loader_path.
  _fixture_healthy() {
    rm -rf "${tmp}/Runner.app" "${tmp}/fx"; mkdir -p "${tmp}/fx"
    local app="${tmp}/Runner.app"
    mkdir -p "${app}/Frameworks/Flutter.framework" "${app}/Frameworks/${RUST_FRAMEWORK}.framework" "${app}/Frameworks/helper.framework"
    : >"${app}/Runner"; : >"${app}/Frameworks/Flutter.framework/Flutter"
    : >"${app}/Frameworks/${RUST_FRAMEWORK}.framework/${RUST_FRAMEWORK}"; : >"${app}/Frameworks/helper.framework/helper"
    {
      printf 'Runner:\n'
      _lc LC_LOAD_DYLIB @rpath/Flutter.framework/Flutter
      _lc LC_LOAD_DYLIB "@rpath/${RUST_FRAMEWORK}.framework/${RUST_FRAMEWORK}"
      _lc LC_LOAD_DYLIB /usr/lib/libSystem.B.dylib
      _lc LC_LOAD_DYLIB @rpath/libswiftCore.dylib
      _lc LC_LOAD_WEAK_DYLIB /usr/lib/swift/libswift_Concurrency.dylib
      _lc LC_RPATH /usr/lib/swift
      _lc LC_RPATH @executable_path/Frameworks
    } >"${tmp}/fx/otool.Runner"
    { printf 'Flutter:\n'; _lc LC_LOAD_DYLIB /System/Library/Frameworks/UIKit.framework/UIKit; } >"${tmp}/fx/otool.Flutter"
    {
      printf '%s:\n' "${RUST_FRAMEWORK}"
      _lc LC_LOAD_DYLIB @loader_path/../helper.framework/helper
      _lc LC_LOAD_DYLIB @rpath/Flutter.framework/Flutter
    } >"${tmp}/fx/otool.${RUST_FRAMEWORK}"
    { printf 'helper:\n'; _lc LC_LOAD_DYLIB /usr/lib/libc++.1.dylib; } >"${tmp}/fx/otool.helper"
    _all_syms >"${tmp}/fx/nm.${RUST_FRAMEWORK}"
    _lock "${FRB_RUNTIME_VERSION}"
  }

  _case() { # <label> <want rc> <ERE the output must hold>...
    local label="$1" want="$2" got=0 out re missing=0
    shift 2
    out="$(PATH="${tmp}/bin:${PATH}" FX_DIR="${tmp}/fx" OTOOL=otool NM=nm \
      FRB_IO_DART="${tmp}/frb_generated.io.dart" PUBSPEC_LOCK="${tmp}/pubspec.lock" \
      check_app "${tmp}/Runner.app" 2>&1)" || got=$?
    ran=$((ran + 1))
    for re in "$@"; do grep -qE -- "${re}" <<<"${out}" || missing=1; done
    if [[ "${got}" -ne "${want}" ]] || (( missing )); then
      printf 'SELF-TEST FAIL: %s (want rc %s, got %s)\n%s\n' "${label}" "${want}" "${got}" "${out}" >&2
      fail=1
    else
      printf '  PASS %s (rc=%s)\n' "${label}" "${got}"
    fi
  }

  _fixture_healthy
  _case "a healthy bundle passes" 0 '^\[check_ios_app_loadable\] OK: 4 images, 9 load commands resolved; rust_lib_haven exports 2 binding \+ 15 runtime symbols$'

  _fixture_healthy
  rm -rf "${tmp}/Runner.app/Frameworks/helper.framework"
  _case "a framework linked by @loader_path but absent fails" 1 'FAIL I1: Frameworks/rust_lib_haven.framework/rust_lib_haven links @loader_path/../helper.framework/helper'

  _fixture_healthy
  _lc LC_LOAD_DYLIB @rpath/Missing.framework/Missing >>"${tmp}/fx/otool.Runner"
  _case "an @rpath framework the bundle lacks fails" 1 'FAIL I1: Runner links @rpath/Missing.framework/Missing \(LC_LOAD_DYLIB\)'

  # patrol's shape: Runner and the plugin framework both weak-link XCTest.
  _fixture_healthy
  _lc LC_LOAD_WEAK_DYLIB @rpath/XCTest.framework/XCTest >>"${tmp}/fx/otool.Runner"
  _lc LC_LOAD_WEAK_DYLIB @rpath/XCTest.framework/XCTest >>"${tmp}/fx/otool.helper"
  _case "a weak XCTest absent from the bundle is allowed" 0 \
    '^\[check_ios_app_loadable\] allowed: Frameworks/helper.framework/helper weak-links @rpath/XCTest.framework/XCTest' \
    '^\[check_ios_app_loadable\] OK: 4 images, 11 load commands resolved'

  _fixture_healthy
  _lc LC_LOAD_DYLIB @rpath/XCTest.framework/XCTest >>"${tmp}/fx/otool.Runner"
  _case "a strong XCTest absent from the bundle fails" 1 'FAIL I1: Runner links @rpath/XCTest.framework/XCTest \(LC_LOAD_DYLIB\)'

  _fixture_healthy
  _lc LC_LOAD_WEAK_DYLIB @rpath/Other.framework/Other >>"${tmp}/fx/otool.Runner"
  _case "any other absent weak library fails" 1 'FAIL I1: Runner links @rpath/Other.framework/Other \(LC_LOAD_WEAK_DYLIB\)'

  # The type comes from each block's own cmd line: a strong XCTest in one
  # slice of a universal binary is not excused by a weak one in another.
  _fixture_healthy
  { printf 'Runner (architecture x86_64):\n'; _lc LC_LOAD_WEAK_DYLIB @rpath/XCTest.framework/XCTest
    printf 'Runner (architecture arm64):\n'; _lc LC_LOAD_DYLIB @rpath/XCTest.framework/XCTest; } >>"${tmp}/fx/otool.Runner"
  _case "a strong load in one slice fails beside a weak one in another" 1 'FAIL I1: Runner links @rpath/XCTest.framework/XCTest \(LC_LOAD_DYLIB\)'

  _fixture_healthy
  _lc LC_LOAD_DYLIB /Users/runner/work/target/librust_lib_haven.dylib >>"${tmp}/fx/otool.${RUST_FRAMEWORK}"
  _case "a build machine's absolute path fails" 1 'links /Users/runner/work/target/librust_lib_haven.dylib'

  _fixture_healthy
  _lc LC_LOAD_DYLIB @rpath/libswift_Foo.dylib >>"${tmp}/fx/otool.helper"
  _case "an @rpath library resolves through the main executable's OS rpath" 0 '^\[check_ios_app_loadable\] OK'

  _fixture_healthy
  _all_syms frbgen_haven_rust_arc_decrement_strong_count_X >"${tmp}/fx/nm.${RUST_FRAMEWORK}"
  _case "a binding symbol the framework does not export fails" 1 'FAIL I2: rust_lib_haven \(thin\) does not export frbgen_haven_rust_arc_decrement_strong_count_X'

  _fixture_healthy
  { _all_syms frb_pde_ffi_dispatcher_primary; printf '0000000000012340 t _frb_pde_ffi_dispatcher_primary\n'; } >"${tmp}/fx/nm.${RUST_FRAMEWORK}"
  _case "a runtime symbol that is only private fails" 1 'does not export frb_pde_ffi_dispatcher_primary$'

  _fixture_healthy
  { printf '\n%s (for architecture arm64):\n' "${RUST_FRAMEWORK}"; _all_syms
    printf '\n%s (for architecture x86_64):\n' "${RUST_FRAMEWORK}"; _all_syms frb_get_rust_content_hash; } >"${tmp}/fx/nm.${RUST_FRAMEWORK}"
  _case "one slice of a universal binary missing a symbol fails" 1 'rust_lib_haven \(x86_64\) does not export frb_get_rust_content_hash$'

  _fixture_healthy
  rm -rf "${tmp}/Runner.app/Frameworks/${RUST_FRAMEWORK}.framework"
  sed -i.bak "/${RUST_FRAMEWORK}/d" "${tmp}/fx/otool.Runner"
  _case "no Rust framework cannot vouch" 2 'CANNOT VOUCH: no Frameworks/rust_lib_haven.framework'

  _fixture_healthy
  printf 'Runner:\n' >"${tmp}/fx/otool.Runner"
  _case "an executable with no parsed load command cannot vouch" 2 'no load command parsed'

  _fixture_healthy
  sed -i.bak '/Flutter.framework/d' "${tmp}/fx/otool.Runner"
  _case "an executable that does not link Flutter cannot vouch" 2 'does not link Flutter.framework'

  _fixture_healthy
  _lock 2.12.0
  _case "a different pinned bridge version cannot vouch" 2 "pins flutter_rust_bridge '2.12.0'"

  if (( ran != SELF_TEST_FIXTURES )); then
    printf 'SELF-TEST FAIL: ran %d fixtures, pinned %d\n' "${ran}" "${SELF_TEST_FIXTURES}" >&2
    fail=1
  fi
  if (( fail )); then echo "check_ios_app_loadable.sh --self-test: FAILED" >&2; return 1; fi
  echo "check_ios_app_loadable.sh --self-test: all ${ran} fixtures passed"
}

FRB_IO_DART="${FRB_IO_DART:-${REPO_ROOT}/haven/lib/src/rust/frb_generated.io.dart}"
PUBSPEC_LOCK="${PUBSPEC_LOCK:-${REPO_ROOT}/haven/pubspec.lock}"

case "${1:-}" in
  --self-test) self_test ;;
  ''|-*) echo "usage: $0 <Runner.app> | --self-test" >&2; exit 2 ;;
  *) [[ $# -eq 1 ]] || { echo "usage: $0 <Runner.app> | --self-test" >&2; exit 2; }
     check_app "$1" ;;
esac
