#!/usr/bin/env bash
# CI guard: every class Android or a library instantiates BY NAME in a release
# APK still has the constructor it is instantiated through.
#
# v0.1.14 died at every process start: under AGP 9, R8's strict full mode read
# Room's member-less `-keep class * extends androidx.room.RoomDatabase` as not
# keeping constructors, stripped WorkDatabase_Impl.<init>(), and WorkManager's
# startup provider then failed `newInstance()` before any Dart ran. The same
# change stripped ML Kit's ComponentRegistrar constructors, which breaks QR
# scanning only when a scan starts — a launch test cannot see that one. Both are
# visible in the dex without a device, so this reads the dex.
#
# Checks (a class must exist, be neither abstract nor an interface, and declare
# the constructor):
#   E1  every manifest component — application, appComponentFactory, activity,
#       activity-alias target, service, receiver, provider — has <init>()V.
#       A component absent from the dex AND declared android:enabled=false is
#       exempt: the platform never instantiates a disabled component, and a
#       class R8 could delete is one no code enables (GMS's ModuleDependencies
#       service is such a manifest-only marker). A present class is checked
#       whatever its enabled state, since code may enable it at run time.
#   E2  every `com.google.firebase.components:<class>` meta-data whose value is
#       com.google.firebase.components.ComponentRegistrar: <class> has <init>()V.
#   E3  every meta-data whose value is androidx.startup: the named Initializer
#       has <init>()V.
#   E4  every class `X_Impl` whose direct superclass is `X` has <init>()V.
#       This is Room's own lookup (`X` + "_Impl", then newInstance()); R8
#       renames RoomDatabase itself, so the generated pair's names are what is
#       left to match on.
#   E5  every concrete class below the superclass of androidx.work.Worker (the
#       R8-renamed ListenableWorker; Worker keeps its name) has
#       <init>(Landroid/content/Context;Landroidx/work/WorkerParameters;)V,
#       the constructor WorkManager's default WorkerFactory looks up.
#
# And the native libraries, because only the x86_64 APK is ever launched and
# the platform maps a library straight out of the APK (extractNativeLibs is
# false), which needs each one stored and page-aligned there; Android 15+
# devices with 16 KB pages also need every segment aligned to 16 KB:
#   N1  every lib/<abi>/*.so is stored uncompressed (`unzip -Z`: `stor`);
#   N2  its data starts on a 16 KB boundary in the zip (`zipalign -c -v -P 16
#       4`, whose offsets this reads rather than trusting its verdict);
#   N3  for arm64-v8a and x86_64, every PT_LOAD of the library has p_align of
#       at least 0x4000 (`readelf -lW`). 32-bit ARM has no 16 KB-page devices.
#
# Fail closed (rc 2) on anything that would make a pass vacuous: no
# build-tools, a tool that fails, dexdump or aapt2 output that does not parse
# into the shape below, no MainActivity or HavenApplication among the E1
# components, no subject at all for any of E2-E5, no native library or no
# librust_lib_haven.so, a library zipalign did not list, and a library whose
# program headers show no PT_LOAD.
#
# Usage:
#   check_apk_loadable.sh <apk>...    dexdump, aapt2 and zipalign from the
#                                     newest $ANDROID_HOME/build-tools/* (or
#                                     $ANDROID_SDK_ROOT); unzip and readelf
#                                     on PATH
#   check_apk_loadable.sh --self-test fixtures: scripts/ci/fixtures/apk_loadable
#
# Exit: 0 every APK passes, 1 a constructor or a library's layout is wrong,
#       2 cannot vouch.

set -euo pipefail
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
readonly FIXTURE_DIR="${SCRIPT_DIR}/fixtures/apk_loadable"

# dexdump's plain layout -> "C\t<descriptor>\t<FLAG|FLAG>\t<superclass>" per
# class, "M\t<descriptor>\t<signature>" per DIRECT <init>, and a final
# "H\t<class headers>\t<dex files opened>" so the caller can refuse a dump
# whose class blocks did not all parse.
readonly DEX_AWK='
  /^Opened \x27.*\x27, DEX version \x27[0-9]+\x27$/ { opened++; next }
  /^Class #[0-9]+/ { headers++; cls = ""; acc = ""; hasacc = 0; sect = ""; nm = ""; next }
  /^  Class descriptor  : \x27L.*;\x27$/ {
    cls = $0; sub(/^  Class descriptor  : \x27/, "", cls); sub(/\x27$/, "", cls); next
  }
  /^  Access flags      : 0x[0-9a-f]+ \(.*\)$/ {
    acc = $0; sub(/^[^(]*\(/, "", acc); sub(/\)$/, "", acc); gsub(/ /, "|", acc); hasacc = 1; next
  }
  /^  Superclass        : \x27L.*;\x27$/ {
    sup = $0; sub(/^  Superclass        : \x27/, "", sup); sub(/\x27$/, "", sup)
    if (cls != "" && hasacc) print "C\t" cls "\t" acc "\t" sup
    next
  }
  /^  Direct methods    -$/ { sect = "D"; next }
  /^  Virtual methods   -$/ { sect = "V"; next }
  sect == "D" && /^      name          : \x27/ {
    nm = $0; sub(/^      name          : \x27/, "", nm); sub(/\x27$/, "", nm); next
  }
  sect == "D" && /^      type          : \x27/ {
    if (nm == "<init>") {
      t = $0; sub(/^      type          : \x27/, "", t); sub(/\x27$/, "", t)
      print "M\t" cls "\t" t
    }
    nm = ""; next
  }
  END { print "H\t" headers + 0 "\t" opened + 0 }
'

# `aapt2 dump xmltree` of AndroidManifest.xml -> "P\t<package>",
# "A\t<application>" and one "K\t<kind>\t<class>\t<enabled>" per subject,
# where <kind> is the component kind, `registrar` (E2) or `initializer` (E3)
# and <enabled> is the literal android:enabled value, or "" when unset.
readonly MANIFEST_AWK='
  function aval(line, nm,   v) {
    if (line !~ ("android:" nm "\\(0x[0-9a-f]+\\)=\"")) return ""
    v = line; sub("^.*android:" nm "\\(0x[0-9a-f]+\\)=\"", "", v)
    sub(/" \(Raw: .*$/, "", v); sub(/"$/, "", v); return v
  }
  function aflag(line, nm,   v) {
    if (line !~ ("android:" nm "\\(0x[0-9a-f]+\\)=")) return ""
    v = line; sub("^.*android:" nm "\\(0x[0-9a-f]+\\)=", "", v); return v
  }
  function flush() {
    if (el ~ /^(application|activity|service|receiver|provider)$/ && name != "")
      print "K\t" el "\t" name "\t" enabled
    if (el == "application" && name != "") print "A\t" name
    if (el == "application" && factory != "") print "K\tappComponentFactory\t" factory "\t"
    if (el == "activity-alias" && target != "") print "K\tactivity-alias\t" target "\t" enabled
    if (el == "meta-data" && value == "com.google.firebase.components.ComponentRegistrar" \
        && name ~ /^com\.google\.firebase\.components:/) {
      sub(/^com\.google\.firebase\.components:/, "", name); print "K\tregistrar\t" name "\t"
    }
    if (el == "meta-data" && value == "androidx.startup" && name != "") print "K\tinitializer\t" name "\t"
    el = ""; name = ""; enabled = ""; factory = ""; target = ""; value = ""
  }
  /^ *E: [A-Za-z-]+ \(line=[0-9]+\)$/ { flush(); el = $2; if (el == "manifest") manifests++; next }
  /^ *A: package="[^"]+"/ && el == "manifest" {
    p = $0; sub(/^ *A: package="/, "", p); sub(/".*$/, "", p); print "P\t" p; next
  }
  /^ *A: / {
    v = aval($0, "name"); if (v != "") name = v
    v = aflag($0, "enabled"); if (v != "") enabled = v
    v = aval($0, "appComponentFactory"); if (v != "") factory = v
    v = aval($0, "targetActivity"); if (v != "") target = v
    v = aval($0, "value"); if (v != "") value = v
  }
  END { flush(); print "N\t" manifests + 0 }
'

# The verdict over one manifest table and one dex table (the two awk outputs
# above). Prints one FAIL/VACUOUS line per finding and one summary line;
# exits 0, 1 or 2.
readonly EVAL_AWK='
  BEGIN { FS = "\t" }
  FNR == NR {
    if ($1 == "P") pkg = $2
    else if ($1 == "A") app = $2
    else if ($1 == "N") manifests = $2
    else if ($1 == "K") { n++; kind[n] = $2; name[n] = $3; en[n] = $4 }
    next
  }
  $1 == "C" { classes++; flags[$2] = $3; sup[$2] = $4; next }
  $1 == "M" { init[$2 "\t" $3] = 1; next }
  $1 == "H" { headers = $2; opened = $3; next }
  function fq(c) {
    if (substr(c, 1, 1) == ".") return pkg c
    if (index(c, ".") == 0) return pkg "." c
    return c
  }
  function desc(c) { gsub(/\./, "/", c); return "L" c ";" }
  function dotted(d) { d = substr(d, 2, length(d) - 2); gsub(/\//, ".", d); return d }
  function concrete(d) { return (d in flags) && flags[d] !~ /(^|\|)(ABSTRACT|INTERFACE)(\||$)/ }
  function vacuous(msg) { print "VACUOUS " msg; bad2 = 1 }
  function need(id, d, sig, why) {
    if (!(d in flags)) { print "FAIL " id " " dotted(d) ": not in the dex (" why ")"; bad1 = 1; return }
    if (!concrete(d)) { print "FAIL " id " " dotted(d) ": abstract or an interface (" why ")"; bad1 = 1; return }
    if (!((d "\t" sig) in init)) { print "FAIL " id " " dotted(d) ": no " sig " constructor (" why ")"; bad1 = 1 }
  }
  END {
    if (manifests != 1 || pkg == "" || app == "") vacuous("the manifest dump did not parse into one manifest with a package and an application")
    if (headers < 1 || opened < 1 || classes != headers) vacuous("the dexdump output did not parse: " classes + 0 " of " headers + 0 " class block(s) read from " opened + 0 " dex file(s)")
    for (i = 1; i <= n; i++) {
      d = desc(fq(name[i]))
      if (kind[i] == "registrar") { e2++; need("E2", d, "()V", "Firebase components instantiate a ComponentRegistrar by name"); continue }
      if (kind[i] == "initializer") { e3++; need("E3", d, "()V", "androidx.startup instantiates an Initializer by name"); continue }
      if (!(d in flags) && en[i] == "false") { skipped++; continue }
      e1++
      if (d == desc(pkg ".MainActivity")) main_seen = 1
      if (d == desc(pkg ".HavenApplication")) app_seen = 1
      need("E1", d, "()V", "the platform instantiates a " kind[i] " by name")
    }
    for (d in sup) {
      if (d !~ /_Impl;$/) continue
      base = d; sub(/_Impl;$/, ";", base)
      if (sup[d] != base) continue
      e4++
      need("E4", d, "()V", "Room instantiates " dotted(base) "_Impl by name")
    }
    anchor = sup["Landroidx/work/Worker;"]
    for (d in sup) {
      if (anchor == "" || !concrete(d)) continue
      for (y = d; (y in sup) && sup[y] != anchor && hops < 64; hops++) y = sup[y]
      hops = 0
      if (!(y in sup) || sup[y] != anchor) continue
      e5++
      need("E5", d, "(Landroid/content/Context;Landroidx/work/WorkerParameters;)V", "WorkManager instantiates a worker by name")
    }
    if (!main_seen || !app_seen) vacuous("E1 did not find both " pkg ".MainActivity and " pkg ".HavenApplication among the manifest components")
    if (e2 < 1) vacuous("E2 found no ComponentRegistrar meta-data")
    if (e3 < 1) vacuous("E3 found no androidx.startup meta-data")
    if (e4 < 1) vacuous("E4 found no X_Impl class whose superclass is X")
    if (anchor == "") vacuous("E5 found no androidx.work.Worker, so no ListenableWorker to read workers from")
    else if (e5 < 1) vacuous("E5 found no concrete worker class")
    printf "E1 %d component(s) (%d disabled and absent), E2 %d registrar(s), E3 %d initializer(s), E4 %d Room database(s), E5 %d worker(s)\n", e1, skipped, e2, e3, e4, e5
    exit bad2 ? 2 : (bad1 ? 1 : 0)
  }
'

# The native-library verdict over three texts, in order: `unzip -Z <apk>
# 'lib/*'`, `zipalign -c -v -P 16 4 <apk>`, and `readelf -lW` of each 64-bit
# library, each preceded by a `== <zip path>` line. Prints FAIL/VACUOUS lines
# and one summary line; exits 0, 1 or 2.
readonly NATIVE_AWK='
  function hex(s,   i, c, v) {
    v = 0; s = tolower(substr(s, 3))
    for (i = 1; i <= length(s); i++) { c = index("0123456789abcdef", substr(s, i, 1)); v = v * 16 + c - 1 }
    return v
  }
  function vacuous(msg) { print "VACUOUS " msg; bad2 = 1 }
  FNR == 1 { part++ }
  part == 1 && $NF ~ /^lib\/[^\/]+\/[^\/]+\.so$/ {
    if (NF < 9) { vacuous("unzip -Z printed a library line not in its long shape"); next }
    n++; lib[n] = $NF; method[$NF] = $6; next
  }
  part == 2 && /^Verification (successful|FAILED)/ { verified = 1; next }
  part == 2 && $2 ~ /^lib\/[^\/]+\/[^\/]+\.so$/ {
    if ($1 !~ /^[0-9]+$/) { vacuous("zipalign printed a library line without an offset"); next }
    off[$2] = $1; next
  }
  part == 3 && /^== lib\// { cur = $2; next }
  part == 3 && $1 == "LOAD" {
    if ($NF !~ /^0x[0-9a-fA-F]+$/) { vacuous("readelf printed a PT_LOAD of " cur " without an alignment"); next }
    loads[cur]++
    if (hex($NF) < 16384) small[cur] = $NF
    next
  }
  END {
    if (n < 1) vacuous("the APK carries no native library")
    if (!verified) vacuous("zipalign printed no verification line")
    for (i = 1; i <= n; i++) {
      p = lib[i]; split(p, seg, "/"); abi = seg[2]
      if (p ~ /\/librust_lib_haven\.so$/) rust = 1
      if (method[p] != "stor") { print "FAIL N1 " p ": stored " method[p] ", not uncompressed"; bad1 = 1 }
      else n1++
      if (!(p in off)) vacuous("zipalign did not list " p)
      else if (off[p] % 16384 != 0) { print "FAIL N2 " p ": data at offset " off[p] ", not on a 16 KB boundary"; bad1 = 1 }
      else n2++
      if (abi != "arm64-v8a" && abi != "x86_64") continue
      if (loads[p] < 1) { vacuous("readelf showed no PT_LOAD for " p); continue }
      if (p in small) { print "FAIL N3 " p ": a PT_LOAD aligned to " small[p] ", below 16 KB"; bad1 = 1 }
      else n3++
    }
    if (n >= 1 && !rust) vacuous("the APK carries no librust_lib_haven.so")
    printf "N1 %d stored, N2 %d on 16 KB boundaries, N3 %d 64-bit librar(ies) with 16 KB segments, of %d native librar(ies)\n", n1, n2, n3, n
    exit bad2 ? 2 : (bad1 ? 1 : 0)
  }
'

# apk_loadable_evaluate <manifest-dump> <dexdump-output> — the verdict over the
# two tools' text, with no tool and no APK. rc 0/1/2 as the script's.
apk_loadable_evaluate() {
  local tmp rc=0
  tmp="$(mktemp -d)"
  awk "${MANIFEST_AWK}" "$1" > "${tmp}/manifest.tsv"
  awk "${DEX_AWK}" "$2" > "${tmp}/dex.tsv"
  awk "${EVAL_AWK}" "${tmp}/manifest.tsv" "${tmp}/dex.tsv" || rc=$?
  rm -rf "${tmp}"
  return "${rc}"
}

# resolve_tools — sets DEXDUMP and AAPT2 from the newest build-tools, or rc 2.
resolve_tools() {
  local sdk="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-}}" newest
  if [[ -z "${sdk}" || ! -d "${sdk}/build-tools" ]]; then
    echo "check_apk_loadable: no \$ANDROID_HOME/build-tools (ANDROID_HOME='${sdk}'); cannot read the dex." >&2
    return 2
  fi
  local d
  newest="$(for d in "${sdk}"/build-tools/*/; do [[ -d "${d}" ]] && basename "${d}"; done | sort -V | tail -n 1)"
  DEXDUMP="${sdk}/build-tools/${newest}/dexdump"
  AAPT2="${sdk}/build-tools/${newest}/aapt2"
  ZIPALIGN="${sdk}/build-tools/${newest}/zipalign"
  if [[ -z "${newest}" || ! -x "${DEXDUMP}" || ! -x "${AAPT2}" || ! -x "${ZIPALIGN}" ]]; then
    echo "check_apk_loadable: the newest build-tools ('${newest}') lacks an executable dexdump, aapt2 or zipalign." >&2
    return 2
  fi
  if ! command -v unzip >/dev/null 2>&1 || ! READELF="$(command -v readelf)"; then
    echo "check_apk_loadable: unzip or readelf is not on PATH; cannot read the APK's dex files and libraries." >&2
    return 2
  fi
}

# check_apk <apk> — dump one APK with the real tools and evaluate it.
check_apk() {
  local apk="$1" tmp rc=0 entry
  local -a dexes=()
  if [[ ! -f "${apk}" ]]; then
    echo "check_apk_loadable: ${apk}: no such file." >&2
    return 2
  fi
  tmp="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf '${tmp}'" RETURN
  while IFS= read -r entry; do
    [[ "${entry}" =~ ^classes[0-9]*\.dex$ ]] && dexes+=("${entry}")
  done < <(unzip -Z1 "${apk}" 2>/dev/null || true)
  if (( ${#dexes[@]} == 0 )); then
    echo "check_apk_loadable: ${apk}: no classes*.dex in the archive." >&2
    return 2
  fi
  : > "${tmp}/dexdump.txt"
  for entry in "${dexes[@]}"; do
    if ! unzip -p "${apk}" "${entry}" > "${tmp}/${entry}" \
       || ! (cd "${tmp}" && "${DEXDUMP}" "${entry}" >> "${tmp}/dexdump.txt" 2>/dev/null); then
      echo "check_apk_loadable: ${apk}: dexdump failed on ${entry}." >&2
      return 2
    fi
  done
  "${AAPT2}" dump xmltree --file AndroidManifest.xml "${apk}" > "${tmp}/manifest.txt" 2>/dev/null \
    || { echo "check_apk_loadable: ${apk}: aapt2 could not dump AndroidManifest.xml." >&2; return 2; }
  echo "check_apk_loadable: $(basename "${apk}") (${#dexes[@]} dex file(s))"
  apk_loadable_evaluate "${tmp}/manifest.txt" "${tmp}/dexdump.txt" || rc=$?
  local nrc=0 zrc=0 lib
  # rc 11 is unzip's "no file matched": an APK without libraries, which the
  # verdict names; anything else is a tool that failed.
  unzip -Z "${apk}" 'lib/*' > "${tmp}/zipinfo.txt" 2>/dev/null || zrc=$?
  if (( zrc != 0 && zrc != 11 )); then
    echo "check_apk_loadable: ${apk}: unzip -Z failed (rc ${zrc})." >&2
    return 2
  fi
  # zipalign exits non-zero on a misaligned entry; its offsets are the verdict.
  "${ZIPALIGN}" -c -v -P 16 4 "${apk}" > "${tmp}/zipalign.txt" 2>&1 || true
  : > "${tmp}/readelf.txt"
  while IFS= read -r lib; do
    [[ "${lib}" =~ ^lib/(arm64-v8a|x86_64)/[^/]+\.so$ ]] || continue
    { echo "== ${lib}"
      unzip -p "${apk}" "${lib}" > "${tmp}/lib.so" && "${READELF}" -lW "${tmp}/lib.so"
    } >> "${tmp}/readelf.txt" 2>/dev/null \
      || { echo "check_apk_loadable: ${apk}: readelf could not read ${lib}." >&2; return 2; }
  done < <(unzip -Z1 "${apk}" 'lib/*' 2>/dev/null || true)
  awk "${NATIVE_AWK}" "${tmp}/zipinfo.txt" "${tmp}/zipalign.txt" "${tmp}/readelf.txt" || nrc=$?
  if (( nrc == 2 || (nrc == 1 && rc == 0) )); then rc="${nrc}"; fi
  return "${rc}"
}

main() {
  local apk worst=0 rc
  if (( $# == 0 )); then
    echo "usage: $0 <apk>... | --self-test" >&2
    return 2
  fi
  resolve_tools || return 2
  for apk in "$@"; do
    rc=0
    check_apk "${apk}" || rc=$?
    if (( rc == 2 || (rc == 1 && worst == 0) )); then worst="${rc}"; fi
  done
  case "${worst}" in
    0) echo "check_apk_loadable: OK — every name-instantiated class keeps its constructor, and every native library is stored and 16 KB aligned, in $# APK(s)." ;;
    1) echo "::error::check_apk_loadable: a class instantiated by name lost its constructor, or a native library is compressed or misaligned (FAIL lines above); this APK crashes when that class is first created or that library is loaded." ;;
    *) echo "::error::check_apk_loadable: could not vouch for the APK(s) (VACUOUS or tool errors above); this is never a pass." ;;
  esac
  return "${worst}"
}

# ---------------------------------------------------------------------------
# Self-test. The fixtures are real dexdump/aapt2 output excerpts of the shipped
# v0.1.13 (good) and v0.1.14 (the crash) APKs, and real unzip/zipalign/readelf
# output of v0.1.13's arm64-v8a libraries; their headers say how each was cut. Every check is mutated on the good pair, and the tool plumbing is run
# end to end over stub tools and a real zip.
# ---------------------------------------------------------------------------
readonly SELF_TEST_CASES=36

self_test() {
  local tmp ran=0 fail=0 out rc
  tmp="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf '${tmp}'" RETURN
  local v
  for v in 13 14; do
    sed '/^#/d' "${FIXTURE_DIR}/v0.1.${v}.manifest.txt" > "${tmp}/m${v}"
    sed '/^#/d' "${FIXTURE_DIR}/v0.1.${v}.dexdump.txt" > "${tmp}/d${v}"
  done
  for v in zipinfo zipalign readelf; do
    sed '/^#/d' "${FIXTURE_DIR}/v0.1.13.native.${v}.txt" > "${tmp}/n.${v}"
  done

  # _case <label> <want-rc> <manifest> <dexdump> [<must-grep>...]
  _case() {
    local label="$1" want="$2" m="$3" d="$4" pat ok=1
    shift 4
    ran=$(( ran + 1 ))
    rc=0
    out="$(apk_loadable_evaluate "${m}" "${d}" 2>&1)" || rc=$?
    (( rc == want )) || ok=0
    for pat in "$@"; do grep -qE -- "${pat}" <<<"${out}" || ok=0; done
    if (( ok )); then
      echo "  PASS ${label}"
    else
      echo "  FAIL ${label} (want rc ${want}, got ${rc}; output: ${out})" >&2
      fail=1
    fi
  }
  # _mut <name> <file> <sed-script> — a mutated copy of <file>; fails the
  # self-test when the sed changed nothing, so a fixture drift cannot turn a
  # mutation into a copy that passes for the wrong reason.
  _mut() {
    sed -e "$3" "$2" > "${tmp}/$1"
    if cmp -s "$2" "${tmp}/$1"; then
      echo "  FAIL mutation $1 changed nothing" >&2
      fail=1
    fi
    printf '%s' "${tmp}/$1"
  }

  echo "check_apk_loadable.sh --self-test"
  # (1) The shipped v0.1.13: passes, with every count pinned.
  _case "v0.1.13 passes with pinned counts" 0 "${tmp}/m13" "${tmp}/d13" \
    '^E1 5 component\(s\) \(1 disabled and absent\), E2 3 registrar\(s\), E3 4 initializer\(s\), E4 1 Room database\(s\), E5 3 worker\(s\)$'
  # (2) The shipped v0.1.14: fails naming the crash and the QR break.
  _case "v0.1.14 fails on WorkDatabase_Impl (E4) and the ML Kit registrars (E2)" 1 "${tmp}/m14" "${tmp}/d14" \
    '^FAIL E4 androidx\.work\.impl\.WorkDatabase_Impl: no \(\)V constructor' \
    '^FAIL E2 com\.google\.mlkit\.vision\.barcode\.internal\.BarcodeRegistrar: no \(\)V' \
    '^FAIL E2 com\.google\.mlkit\.vision\.common\.internal\.VisionCommonRegistrar: ' \
    '^FAIL E2 com\.google\.mlkit\.common\.internal\.CommonComponentRegistrar: ' \
    'E5 2 worker\(s\)$'
  # (3) …and nothing else in it is blamed.
  _case "v0.1.14 blames exactly four classes" 1 "${tmp}/m14" "${tmp}/d14"
  if [[ "$(grep -c '^FAIL ' <<<"${out}")" != 4 ]]; then
    echo "  FAIL (3) expected exactly 4 FAIL lines, got: ${out}" >&2; fail=1
  fi

  # Each check's own mutation on the good pair.
  # (4) E1: MainActivity's constructor renamed.
  _case "E1 a component without <init>()V fails" 1 "${tmp}/m13" \
    "$(_mut e1-ctor "${tmp}/d13" "/MainActivity;)\$/,/type/{s/name          : '<init>'/name          : '<xinit>'/}")" \
    '^FAIL E1 com\.oblivioustech\.haven\.MainActivity: no \(\)V'
  # (5) E1: the application class made abstract.
  _case "E1 an abstract component fails" 1 "${tmp}/m13" \
    "$(_mut e1-abs "${tmp}/d13" "/HavenApplication;'\$/,/Access flags/{s/(PUBLIC FINAL)/(PUBLIC ABSTRACT)/;s/(PUBLIC)/(PUBLIC ABSTRACT)/}")" \
    '^FAIL E1 com\.oblivioustech\.haven\.HavenApplication: abstract'
  # (6) E1: an enabled component whose class is gone.
  _case "E1 an enabled component absent from the dex fails" 1 "${tmp}/m13" \
    "$(_mut e1-gone "${tmp}/d13" "/MlKitComponentDiscoveryService;'\$/s/MlKitComponentDiscoveryService/MlKitComponentDiscoveryServiceX/")" \
    '^FAIL E1 com\.google\.mlkit\.common\.internal\.MlKitComponentDiscoveryService: not in the dex'
  # (7) E1: a disabled component that IS in the dex is still checked.
  _case "E1 a disabled but present component is still checked" 1 \
    "$(_mut e1-dis-m "${tmp}/m13" '/MainActivity" (Raw/a\            A: http://schemas.android.com/apk/res/android:enabled(0x0101000e)=false')" \
    "$(_mut e1-dis-d "${tmp}/d13" "/MainActivity;)\$/,/type/{s/name          : '<init>'/name          : '<xinit>'/}")" \
    '^FAIL E1 com\.oblivioustech\.haven\.MainActivity: '
  # (8) E1: the disabled-and-absent exemption needs BOTH: enabled it fails.
  _case "E1 the absent ModuleDependencies fails once enabled" 1 \
    "$(_mut e1-en "${tmp}/m13" 's/android:enabled(0x0101000e)=false/android:enabled(0x0101000e)=true/')" "${tmp}/d13" \
    '^FAIL E1 com\.google\.android\.gms\.metadata\.ModuleDependencies: not in the dex'
  # (9) E2: one registrar's constructor removed.
  _case "E2 a registrar without <init>()V fails" 1 "${tmp}/m13" \
    "$(_mut e2 "${tmp}/d13" "/BarcodeRegistrar;)\$/,/type/{s/name          : '<init>'/name          : '<xinit>'/}")" \
    '^FAIL E2 com\.google\.mlkit\.vision\.barcode\.internal\.BarcodeRegistrar: no \(\)V'
  # (10) E3: one initializer's constructor removed.
  _case "E3 an initializer without <init>()V fails" 1 "${tmp}/m13" \
    "$(_mut e3 "${tmp}/d13" "/WorkManagerInitializer;)\$/,/type          : '()V'/{s/name          : '<init>'/name          : '<xinit>'/}")" \
    '^FAIL E3 androidx\.work\.WorkManagerInitializer: no \(\)V'
  # (11) E4: the v0.1.14 crash planted into v0.1.13.
  _case "E4 WorkDatabase_Impl without <init>()V fails" 1 "${tmp}/m13" \
    "$(_mut e4 "${tmp}/d13" "/WorkDatabase_Impl;)\$/,/type/{s/name          : '<init>'/name          : '<xinit>'/}")" \
    '^FAIL E4 androidx\.work\.impl\.WorkDatabase_Impl: no \(\)V'
  # (12) E5: a worker whose constructor lost its WorkerParameters.
  _case "E5 a worker without the (Context, WorkerParameters) constructor fails" 1 "${tmp}/m13" \
    "$(_mut e5 "${tmp}/d13" "/BackgroundWorker;)\$/,/type/{s|(Landroid/content/Context;Landroidx/work/WorkerParameters;)V|(Landroid/content/Context;)V|}")" \
    '^FAIL E5 dev\.fluttercommunity\.workmanager\.BackgroundWorker: no \(Landroid'
  # (13) A constructor listed under Virtual methods is not a constructor.
  _case "an <init> outside Direct methods does not count" 1 "${tmp}/m13" \
    "$(_mut virt "${tmp}/d13" "/MainActivity;'\$/,/source_file_idx/{s/^  Direct methods    -\$/  Virtual methods   -/}")" \
    '^FAIL E1 com\.oblivioustech\.haven\.MainActivity: no \(\)V'

  # (14) A package-private class prints an EMPTY flag list, `0x0000 ()`: it
  #      is a concrete class like any other (33 of v0.1.13's 4596 are).
  _case "a class with no access flags is read, and is concrete" 0 "${tmp}/m13" \
    "$(_mut pkg-private "${tmp}/d13" "/MainActivity;'\$/,/Access flags/{s/0x0011 (PUBLIC FINAL)/0x0000 ()/}")" \
    '^E1 5 component'

  # Vacuity: rc 2, never a pass.
  : > "${tmp}/empty"
  # (15) Empty dexdump output.
  _case "an empty dexdump is vacuous" 2 "${tmp}/m13" "${tmp}/empty" '^VACUOUS the dexdump output did not parse'
  # (16) A class block whose descriptor line is in an unknown shape.
  _case "a class block that does not parse is vacuous" 2 "${tmp}/m13" \
    "$(_mut d-shape "${tmp}/d13" "0,/^  Class descriptor  : /s/^  Class descriptor  : /  Class descriptor: /")" \
    '^VACUOUS the dexdump output did not parse: 19 of 20 class'
  # (17) Empty manifest dump.
  _case "an empty manifest dump is vacuous" 2 "${tmp}/empty" "${tmp}/d13" '^VACUOUS the manifest dump did not parse'
  # (18) No MainActivity among the components.
  _case "no MainActivity is vacuous" 2 \
    "$(_mut no-main "${tmp}/m13" 's/com\.oblivioustech\.haven\.MainActivity/com.oblivioustech.haven.OtherActivity/g')" "${tmp}/d13" \
    '^VACUOUS E1 did not find both'
  # (19) No registrar meta-data.
  _case "no ComponentRegistrar meta-data is vacuous" 2 \
    "$(_mut no-reg "${tmp}/m13" 's/="com\.google\.firebase\.components\.ComponentRegistrar"/="other"/')" "${tmp}/d13" \
    '^VACUOUS E2 found no ComponentRegistrar'
  # (20) No androidx.startup meta-data.
  _case "no androidx.startup meta-data is vacuous" 2 \
    "$(_mut no-init "${tmp}/m13" 's/="androidx\.startup"/="other"/')" "${tmp}/d13" \
    '^VACUOUS E3 found no androidx.startup'
  # (21) No X_Impl pair.
  _case "no Room X_Impl pair is vacuous" 2 "${tmp}/m13" \
    "$(_mut no-impl "${tmp}/d13" "s|'Landroidx/work/impl/WorkDatabase;'|'Landroidx/work/impl/WorkDatabaseBase;'|")" \
    '^VACUOUS E4 found no X_Impl'
  # (22) No androidx.work.Worker.
  _case "no androidx.work.Worker is vacuous" 2 "${tmp}/m13" \
    "$(_mut no-worker "${tmp}/d13" "s|Class descriptor  : 'Landroidx/work/Worker;'|Class descriptor  : 'Landroidx/work/Wurker;'|")" \
    '^VACUOUS E5 found no androidx.work.Worker'

  # The native libraries, over real unzip/zipalign/readelf output of v0.1.13.
  # _ncase <label> <want-rc> <zipinfo> <zipalign> <readelf> [<must-grep>...]
  _ncase() {
    local label="$1" want="$2" z="$3" a="$4" e="$5" pat ok=1
    shift 5
    ran=$(( ran + 1 ))
    rc=0
    out="$(awk "${NATIVE_AWK}" "${z}" "${a}" "${e}" 2>&1)" || rc=$?
    (( rc == want )) || ok=0
    for pat in "$@"; do grep -qE -- "${pat}" <<<"${out}" || ok=0; done
    if (( ok )); then echo "  PASS ${label}"; else
      echo "  FAIL ${label} (want rc ${want}, got ${rc}; output: ${out})" >&2; fail=1; fi
  }
  local nz="${tmp}/n.zipinfo" na="${tmp}/n.zipalign" ne="${tmp}/n.readelf" rust='lib\/arm64-v8a\/librust_lib_haven\.so'
  # (23) The shipped v0.1.13: every library stored, on 16 KB, 16 KB segments.
  _ncase "v0.1.13's native libraries pass with pinned counts" 0 "${nz}" "${na}" "${ne}" \
    '^N1 8 stored, N2 8 on 16 KB boundaries, N3 8 64-bit librar\(ies\) with 16 KB segments, of 8 native librar\(ies\)$'
  # (24) N1: a library deflated in the zip.
  _ncase "N1 a compressed library fails" 1 "$(_mut n1 "${nz}" "/librust_lib_haven/s/ stor / defN /")" "${na}" "${ne}" \
    '^FAIL N1 lib/arm64-v8a/librust_lib_haven\.so: stored defN'
  # (25) N2: a library's data 4 KB off a 16 KB boundary.
  _ncase "N2 a library off a 16 KB boundary fails" 1 "${nz}" "$(_mut n2 "${na}" "s/^[0-9]* \(${rust} (OK)\)\$/26382336 \1/")" "${ne}" \
    '^FAIL N2 lib/arm64-v8a/librust_lib_haven\.so: data at offset 26382336'
  # (26) N3: a 64-bit library with a 4 KB segment.
  _ncase "N3 a 64-bit library with a 4 KB PT_LOAD fails" 1 "${nz}" "${na}" \
    "$(_mut n3 "${ne}" "/^== ${rust}\$/,/^== /{/^  LOAD /s/0x4000\$/0x1000/}")" \
    '^FAIL N3 lib/arm64-v8a/librust_lib_haven\.so: a PT_LOAD aligned to 0x1000'
  # (27) …and N3 reads 64-bit ABIs only: the same library as armeabi-v7a passes.
  _ncase "N3 does not hold 32-bit ARM to 16 KB segments" 0 "$(_mut v7z "${nz}" 's|lib/arm64-v8a/librust|lib/armeabi-v7a/librust|')" \
    "$(_mut v7a "${na}" 's|lib/arm64-v8a/librust|lib/armeabi-v7a/librust|')" \
    "$(_mut v7e "${tmp}/n3" 's|lib/arm64-v8a/librust|lib/armeabi-v7a/librust|')" '^N1 8 stored, N2 8 .*N3 7 '
  # (28)-(31) Vacuity: no library, no verification line, no PT_LOAD, no Rust library.
  : > "${tmp}/none"
  _ncase "an APK without native libraries is vacuous" 2 "${tmp}/none" "${na}" "${ne}" '^VACUOUS the APK carries no native library'
  _ncase "zipalign output without its verdict line is vacuous" 2 "${nz}" "$(_mut nov "${na}" '/^Verification/d')" "${ne}" \
    '^VACUOUS zipalign printed no verification line'
  _ncase "a library readelf shows no PT_LOAD for is vacuous" 2 "${nz}" "${na}" \
    "$(_mut noload "${ne}" "/^== ${rust}\$/,/^== /{/^  LOAD /d}")" '^VACUOUS readelf showed no PT_LOAD for lib/arm64-v8a/librust_lib_haven\.so'
  _ncase "an APK without librust_lib_haven.so is vacuous" 2 "$(_mut norz "${nz}" 's/librust_lib_haven/librust_lib_other/')" \
    "$(_mut nora "${na}" 's/librust_lib_haven/librust_lib_other/')" "$(_mut nore "${ne}" 's/librust_lib_haven/librust_lib_other/')" \
    '^VACUOUS the APK carries no librust_lib_haven\.so'

  # The tool plumbing, end to end: stub dexdump/aapt2 in an SDK tree, a real zip.
  local sdk="${tmp}/sdk" bt
  for bt in 9.0.0 10.0.0; do
    mkdir -p "${sdk}/build-tools/${bt}"
    printf '#!/usr/bin/env bash\nexit 99\n' > "${sdk}/build-tools/${bt}/dexdump"
    printf '#!/usr/bin/env bash\nexit 99\n' > "${sdk}/build-tools/${bt}/aapt2"
    printf '#!/usr/bin/env bash\nexit 99\n' > "${sdk}/build-tools/${bt}/zipalign"
  done
  # 10.0.0 sorts after 9.0.0 only by version, not by text: the stubs there work.
  printf '#!/usr/bin/env bash\necho "$1" >> %q\nif [[ "$1" == classes.dex ]]; then cat %q; else echo "Opened %s, DEX version %s"; fi\n' \
    "${tmp}/dexdump.calls" "${tmp}/d13" "'classes2.dex'" "'037'" > "${sdk}/build-tools/10.0.0/dexdump"
  printf '#!/usr/bin/env bash\ncat %q\n' "${tmp}/m13" > "${sdk}/build-tools/10.0.0/aapt2"
  # zipalign answers with v0.1.13's offsets; readelf, on PATH, with the
  # program headers of the library whose zip path the extracted file holds.
  printf '#!/usr/bin/env bash\ncat %q\n' "${tmp}/n.zipalign" > "${sdk}/build-tools/10.0.0/zipalign"
  mkdir -p "${tmp}/bin"
  printf '#!/usr/bin/env bash\nawk -v want="== $(cat "${!#}")" '"'"'$0 == want { on = 1; next } /^== / { on = 0 } on'"'"' %q\n' \
    "${tmp}/n.readelf" > "${tmp}/bin/readelf"
  chmod +x "${sdk}"/build-tools/*/* "${tmp}/bin/readelf"
  local -a libs=()
  mapfile -t libs < <(awk '{ print $NF }' "${tmp}/n.zipinfo")
  python3 -I -c 'import sys, zipfile
z = zipfile.ZipFile(sys.argv[1], "w")
for n in sys.argv[2:]: z.writestr(n, n.encode() if n.startswith("lib/") else b"dex\n")
z.close()' "${tmp}/two.apk" classes.dex classes2.dex AndroidManifest.xml "${libs[@]}"
  python3 -I -c 'import sys, zipfile
z = zipfile.ZipFile(sys.argv[1], "w"); z.writestr("AndroidManifest.xml", b"x"); z.close()' "${tmp}/nodex.apk"

  _run() { # _run <label> <want-rc> <env-sdk> <args>... -- prints nothing; sets rc/out
    local label="$1" want="$2" s="$3"
    shift 3
    ran=$(( ran + 1 ))
    rc=0
    out="$(PATH="${tmp}/bin:${PATH}" ANDROID_HOME="${s}" ANDROID_SDK_ROOT='' main "$@" 2>&1)" || rc=$?
    if (( rc == want )); then echo "  PASS ${label}"; else
      echo "  FAIL ${label} (want rc ${want}, got ${rc}; output: ${out})" >&2; fail=1; fi
  }
  # (32) Newest build-tools by version, every dex dumped, every 64-bit library
  #      read, v0.1.13 passes.
  _run "end to end: newest build-tools, every dex file, every library, rc 0" 0 "${sdk}" "${tmp}/two.apk"
  if ! grep -q '^N1 8 stored, N2 8 on 16 KB boundaries, N3 8 ' <<<"${out}"; then
    echo "  FAIL (32) the libraries were not all read: ${out}" >&2; fail=1
  fi
  if [[ "$(tr '\n' ' ' < "${tmp}/dexdump.calls" 2>/dev/null)" != "classes.dex classes2.dex " ]]; then
    echo "  FAIL (32) dexdump was not run once per dex file: $(cat "${tmp}/dexdump.calls" 2>/dev/null)" >&2; fail=1
  fi
  # (33) No build-tools at all.
  _run "no build-tools is rc 2" 2 "${tmp}/nosdk" "${tmp}/two.apk"
  # (34) An APK with no dex.
  _run "an APK with no classes.dex is rc 2" 2 "${sdk}" "${tmp}/nodex.apk"
  # (35) A dexdump that fails.
  printf '#!/usr/bin/env bash\nexit 3\n' > "${sdk}/build-tools/10.0.0/dexdump"
  _run "a failing dexdump is rc 2" 2 "${sdk}" "${tmp}/two.apk"
  # (36) Build-tools without zipalign cannot vouch for the libraries.
  rm "${sdk}/build-tools/10.0.0/zipalign"
  _run "build-tools without zipalign is rc 2" 2 "${sdk}" "${tmp}/two.apk"

  if (( ran != SELF_TEST_CASES )); then
    echo "SELF-TEST FAIL: ran ${ran} case(s), expected ${SELF_TEST_CASES}" >&2
    fail=1
  fi
  if (( fail )); then
    echo "check_apk_loadable.sh --self-test: FAILED" >&2
    return 1
  fi
  echo "check_apk_loadable.sh --self-test: all ${ran} cases passed"
}

if [[ "${1:-}" == "--self-test" ]]; then
  self_test
  exit $?
fi
main "$@"
