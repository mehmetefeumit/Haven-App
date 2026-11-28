#!/usr/bin/env bash
# CI guard: an iOS app bundle was built with an iOS SDK App Store Connect
# accepts.
#
# From April 2027 App Store Connect refuses (ITMS-90725) an upload not built
# with the iOS 27 SDK or later (Apple, 2026-09-09,
# developer.apple.com/news/?id=k1mtkt1k; Haven 0.1.19 build 26 was warned). The
# SDK is a fact of the BUILT bundle, not of the workflow that asked for it, so
# it is read from the bundle's own Info.plist (binary or XML, plistlib):
#
#   S1  DTSDKName is iphoneos<M>.<m> or iphonesimulator<M>.<m>, DTPlatformName
#       names the same platform, and that platform is the one expected: the
#       device SDK, or with --simulator the simulator SDK.
#   S2  DTPlatformVersion is <M>.<m>[.<p>] with DTSDKName's <M>.<m>: two
#       readings of one fact, so an edit to one cannot pass the floor alone.
#   S3  the SDK major <M>, and the major of DTXcode (<MMmp>, the Xcode that
#       built it; Xcode 27 is the first with an iOS 27 SDK), are each at least
#       IOS_SDK_FLOOR.
#
# Fail closed (rc 2): no bundle, no Info.plist, an unparsable one, a missing or
# malformed key, or readings that disagree.
#
# Usage:
#   check_ios_app_sdk.sh [--simulator] <Runner.app>
#   check_ios_app_sdk.sh --self-test    plistlib fixtures, XML and binary
#
# Tools: python3 (plistlib). Written for bash 3.2, macOS's /bin/bash.
# Exit: 0 floor met, 1 below the floor or the wrong platform, 2 cannot vouch.

set -euo pipefail
export LC_ALL=C

# The App Store's floor (header). Raise it when Apple raises theirs, in the
# same commit as the `xcode-NN` runner label of every iOS job
# (check_release_launch_gated.sh G10 holds the label to it).
readonly IOS_SDK_FLOOR=27
readonly SELF_TEST_FIXTURES=20

say() { printf '[check_ios_app_sdk] %s\n' "$*"; }
cannot() { printf '[check_ios_app_sdk] CANNOT VOUCH: %s\n' "$*" >&2; exit 2; }

check_app() { # <bundle dir> <expected platform>
  local app="${1%/}" want="$2" rc=0 out
  [[ -d "${app}" ]] || cannot "${app##*/} is not an app bundle directory"
  out="$(python3 -I -c '
import plistlib, re, sys
path, floor, want = sys.argv[1], int(sys.argv[2]), sys.argv[3]
def end(rc, msg):
    print(msg); sys.exit(rc)
try:
    with open(path, "rb") as f:
        p = plistlib.load(f)
except FileNotFoundError:
    end(2, "CANNOT VOUCH: the bundle has no Info.plist")
except Exception:
    end(2, "CANNOT VOUCH: the bundle'"'"'s Info.plist does not parse")
if not isinstance(p, dict):
    end(2, "CANNOT VOUCH: the bundle'"'"'s Info.plist is not a dictionary")
def key(k):
    v = p.get(k)
    if not isinstance(v, str) or not v:
        end(2, "CANNOT VOUCH: Info.plist has no %s string" % k)
    return v[:40]
name, plat, pver, xc = key("DTSDKName"), key("DTPlatformName"), key("DTPlatformVersion"), key("DTXcode")
m = re.fullmatch(r"(iphoneos|iphonesimulator)([0-9]+)\.([0-9]+)", name)
if not m:
    end(2, "CANNOT VOUCH: DTSDKName %r names no iOS SDK" % name)
sdk, major, minor = m.group(1), int(m.group(2)), int(m.group(3))
if plat != sdk:
    end(2, "CANNOT VOUCH: DTPlatformName %r disagrees with DTSDKName %r" % (plat, name))
v = re.fullmatch(r"([0-9]+)\.([0-9]+)(\.[0-9]+)?", pver)
if not v or (int(v.group(1)), int(v.group(2))) != (major, minor):
    end(2, "CANNOT VOUCH: DTPlatformVersion %r disagrees with DTSDKName %r" % (pver, name))
if not re.fullmatch(r"[0-9]{4}", xc):
    end(2, "CANNOT VOUCH: DTXcode %r is not an Xcode version" % xc)
if sdk != want:
    end(1, "FAIL S1: built against the %s SDK, expected %s" % (sdk, want))
if major < floor:
    end(1, "FAIL S3: iOS SDK %d.%d is below the App Store floor %d (ITMS-90725)" % (major, minor, floor))
if int(xc) // 100 < floor:
    end(1, "FAIL S3: built by Xcode %s, below the App Store floor %d (ITMS-90725)" % (xc, floor))
end(0, "OK: iOS SDK %d.%d (%s), Xcode %s; floor %d" % (major, minor, sdk, xc, floor))
' "${app}/Info.plist" "${IOS_SDK_FLOOR}" "${want}")" || rc=$?
  # An uncaught Python exception is rc 1 too; only the reader's own verdict
  # line may be read as one.
  case "${rc}:${out}" in
    "0:OK: "*) say "${out}" ;;
    "1:FAIL S"*) say "${out}" >&2 ;;
    "2:CANNOT VOUCH: "*) printf '[check_ios_app_sdk] %s\n' "${out}" >&2 ;;
    *) cannot "the Info.plist reader failed (rc ${rc})" ;;
  esac
  return "${rc}"
}

# ---------------------------------------------------------------------------
# --self-test: bundles whose Info.plist plistlib writes, XML or binary. The
# fixtures are relative to IOS_SDK_FLOOR, so raising it moves both edges.
# ---------------------------------------------------------------------------
self_test() {
  local tmp app ran=0 fail=0 F="${IOS_SDK_FLOOR}"
  local below=$((F - 1)) above=$((F + 1))
  tmp="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf '${tmp}'" EXIT
  app="${tmp}/Runner.app"

  # _bundle <xml|binary> [<key>=<value> | -<key>]... — a fresh Runner.app
  # holding a device build at the floor (iphoneosF.2, Xcode F.2), with each
  # argument setting or removing one key.
  _bundle() {
    rm -rf "${app}"; mkdir -p "${app}"
    python3 -I -c '
import plistlib, sys
out, fmt, floor = sys.argv[1], sys.argv[2], int(sys.argv[3])
p = {"CFBundleExecutable": "Runner", "DTSDKName": "iphoneos%d.2" % floor,
     "DTPlatformName": "iphoneos", "DTPlatformVersion": "%d.2" % floor,
     "DTXcode": "%d20" % floor}
for a in sys.argv[4:]:
    if a.startswith("-"):
        del p[a[1:]]
    else:
        k, v = a.split("=", 1)
        p[k] = v
with open(out, "wb") as f:
    plistlib.dump(p, f, fmt=plistlib.FMT_BINARY if fmt == "binary" else plistlib.FMT_XML)
' "${app}/Info.plist" "$1" "${F}" "${@:2}"
  }

  _case() { # <label> <want rc> <ERE the output must hold> <argument>...
    local label="$1" want="$2" re="$3" got=0 out
    shift 3
    out="$(bash "${BASH_SOURCE[0]}" "$@" 2>&1)" || got=$?
    ran=$((ran + 1))
    if [[ "${got}" -ne "${want}" ]] || ! grep -qE -- "${re}" <<<"${out}"; then
      printf 'SELF-TEST FAIL: %s (want rc %s, got %s)\n%s\n' "${label}" "${want}" "${got}" "${out}" >&2
      fail=1
    else
      printf '  PASS %s (rc=%s)\n' "${label}" "${got}"
    fi
  }

  _bundle binary
  _case "a device build at the floor, binary plist, passes" 0 "^\[check_ios_app_sdk\] OK: iOS SDK ${F}\.2 \(iphoneos\), Xcode ${F}20; floor ${F}$" "${app}"

  _bundle xml DTSDKName="iphonesimulator${F}.0" DTPlatformName=iphonesimulator DTPlatformVersion="${F}.0" DTXcode="${F}00"
  _case "a simulator build at the floor, XML plist, passes under --simulator" 0 "OK: iOS SDK ${F}\.0 \(iphonesimulator\)" --simulator "${app}"

  _bundle xml DTSDKName="iphoneos${above}.0" DTPlatformVersion="${above}.0.1" DTXcode="${above}01"
  _case "a newer SDK passes: a floor, not a pin" 0 "OK: iOS SDK ${above}\.0 \(iphoneos\)" "${app}"

  _bundle binary DTSDKName="iphoneos${below}.2" DTPlatformVersion="${below}.2" DTXcode="${below}20"
  _case "the ITMS-90725 build, one SDK below the floor, fails" 1 "FAIL S3: iOS SDK ${below}\.2 is below the App Store floor ${F}" "${app}"

  # The build App Store Connect warned about (0.1.19 build 26), in absolute
  # terms, so lowering the floor below it cannot pass.
  _bundle binary DTSDKName=iphoneos26.2 DTPlatformVersion=26.2 DTXcode=2620
  _case "the iOS 26.2 SDK build ITMS-90725 named fails" 1 'FAIL S3: iOS SDK 26\.2 is below the App Store floor' "${app}"

  # Before Xcode 26 the Xcode and iOS majors differed (Xcode 16.4, iOS 18.5).
  _bundle binary DTSDKName=iphoneos18.5 DTPlatformVersion=18.5 DTXcode=1640
  _case "an Xcode 16 build reads as too old, not as unreadable" 1 'FAIL S3: iOS SDK 18\.5 is below' "${app}"

  _bundle binary DTSDKName="iphoneos${F}.2" DTXcode="${below}20"
  _case "an Xcode below the floor fails, whatever DTSDKName says" 1 "FAIL S3: built by Xcode ${below}20" "${app}"

  _bundle xml DTSDKName="iphonesimulator${F}.2" DTPlatformName=iphonesimulator
  _case "a simulator build where the device build is expected fails" 1 'FAIL S1: built against the iphonesimulator SDK, expected iphoneos' "${app}"

  _bundle xml
  _case "a device build under --simulator fails" 1 'FAIL S1: built against the iphoneos SDK, expected iphonesimulator' --simulator "${app}"

  _bundle xml -DTSDKName
  _case "no DTSDKName cannot vouch" 2 'CANNOT VOUCH: Info.plist has no DTSDKName' "${app}"

  _bundle xml -DTPlatformVersion
  _case "no DTPlatformVersion cannot vouch" 2 'CANNOT VOUCH: Info.plist has no DTPlatformVersion' "${app}"

  _bundle xml -DTXcode
  _case "no DTXcode cannot vouch" 2 'CANNOT VOUCH: Info.plist has no DTXcode' "${app}"

  _bundle xml DTSDKName="iphonesimulator${F}.2"
  _case "a DTPlatformName other than the SDK's cannot vouch" 2 'DTPlatformName .* disagrees with DTSDKName' "${app}"

  # Only the name raised to the floor: the version still says the old SDK.
  _bundle binary DTPlatformVersion="${below}.2"
  _case "a DTPlatformVersion that disagrees with DTSDKName cannot vouch" 2 'DTPlatformVersion .* disagrees with DTSDKName' "${app}"

  _bundle xml DTXcode="${F}.2"
  _case "a malformed DTXcode cannot vouch" 2 'DTXcode .* is not an Xcode version' "${app}"

  _bundle xml DTSDKName="macosx${F}.0" DTPlatformName=macosx
  _case "a macOS SDK cannot vouch" 2 "DTSDKName 'macosx${F}\.0' names no iOS SDK" "${app}"

  _bundle xml DTSDKName=iphoneos
  _case "an SDK name without a version cannot vouch" 2 "DTSDKName 'iphoneos' names no iOS SDK" "${app}"

  _bundle xml; rm "${app}/Info.plist"
  _case "a bundle without an Info.plist cannot vouch" 2 'the bundle has no Info.plist' "${app}"

  _bundle xml; printf '<?xml version="1.0"?><plist><dict><key>DTSDKName</key>' >"${app}/Info.plist"
  _case "an unparsable Info.plist cannot vouch" 2 'Info.plist does not parse' "${app}"

  _case "a path that is not a bundle directory cannot vouch" 2 'is not an app bundle directory' "${tmp}/Missing.app"

  if (( ran != SELF_TEST_FIXTURES )); then
    printf 'SELF-TEST FAIL: ran %d fixtures, pinned %d\n' "${ran}" "${SELF_TEST_FIXTURES}" >&2
    fail=1
  fi
  if (( fail )); then echo "check_ios_app_sdk.sh --self-test: FAILED" >&2; return 1; fi
  echo "check_ios_app_sdk.sh --self-test: all ${ran} fixtures passed"
}

case "${1:-}" in
  --self-test) self_test ;;
  --simulator)
    [[ $# -eq 2 && -n "$2" ]] || { echo "usage: $0 [--simulator] <Runner.app> | --self-test" >&2; exit 2; }
    check_app "$2" iphonesimulator ;;
  ''|-*) echo "usage: $0 [--simulator] <Runner.app> | --self-test" >&2; exit 2 ;;
  *) [[ $# -eq 1 ]] || { echo "usage: $0 [--simulator] <Runner.app> | --self-test" >&2; exit 2; }
     check_app "$1" iphoneos ;;
esac
