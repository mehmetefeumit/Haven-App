#!/usr/bin/env bash
#
# The Bluetooth mesh lane, push A — docs/BLUETOOTH_MESH_M3_DESIGN.md §O.2,
# as built in §O.7. Runner of `.github/workflows/e2e-mesh.yml`.
#
# # What push A can prove, and what this lane is for
#
# In push A nothing can turn the mesh on. No manifest declares its service,
# receiver or tap alias, and the radio's channel does not answer the three
# methods behind the log lever (`bluetoothOn`, `bluetoothName`, `start`), so a
# turn-on ends `failed` before anything is stored. Push B makes the lever
# reachable, and may land only on a lane that proves it holds. This is that
# lane's first half: two controls that hold today, and a probe that measures
# what no source settled, so that push B's oracle is written against answers
# and not against memory.
#
#   S0     API 34, a build WITHOUT the flag   the mesh cannot be started at
#                                             all: no channel, no button, no
#                                             component, no service to start
#   probe  API 34, a build WITH the flag      no promise about the platform:
#                                             each measurement of §O.2.3 is
#                                             TAKEN and written down. What
#                                             Haven promises of push A is
#                                             still held: the turn-on fails
#   S2     API 29, a build WITH the flag      Haven starts on Android 10 with
#                                             the flag-on library; nothing of
#                                             the mesh is offered
#
# # How it observes
#
# One drive target, `haven/integration_test/mesh_lever_test.dart`, in every
# leg. It does not know its leg: it reports facts as `[mesh] …` lines, its own
# `debugPrint`s (the product has no marker and gains none: §O.4, Q-20), and
# then stays alive while this runner reads the device — `dumpsys`, `am`, `pm`,
# the log buffers — and says when it is done, by a file made with `run-as` in
# the app's own data directory. The oracle then reads complete captures.
#
# Three lines are planted from Haven's own process through liblog:
#
#   P1  a DEBUG line under `BluetoothGatt`     a platform Bluetooth tag, the
#                                              kind the lever will have to
#                                              keep out of the log
#   P2  a line under `flutter`, same call      the control: the plant call
#                                              writes and the capture is live
#   P3  a string event (`__android_log_bswrite`)  the events buffer, which no
#                                              lever reaches
#
# Each carries a token minted by the target, random per run, of the log
# scanner's plant alphabet (so no structural rule fires inside one). They are
# judged HERE, by pid and tag, not by the scanner: a declared needle must be
# absent from every line of a device-wide capture, and these must be present
# (§O-4). The token names nothing and is printed by the target itself.
#
# # Verdicts
#
#   0  every promise of the leg(s) held and every measurement was taken
#   1  a promise is broken, or the log-privacy gate found a leak
#   2  this runner or its wiring is broken: bad arguments, no APK, the wrong
#      build driven
#   3  UNUSABLE: the platform, the emulator or the capture would not answer —
#      a control missed, a dump unread, a target that never reported. Nothing
#      was proved either way. Not red, never green
#   4  the log-privacy gate's meta floor (it proved too little)
#
# Folded 1 > 2 > 3 > 4 > 0, the tree's closed set (logscan-gate.sh).
#
# The probe's verdict is about whether a measurement was TAKEN, not about
# what it answered: Bluetooth that does not come on is `probe.bt_on=no` and
# rc 0. The exceptions are what push A promises whatever the platform says
# (the turn-on fails, nothing is stored, no component exists) and what §O
# calls a misconfiguration (fewer than five readable log buffers).
#
# # Log anonymity (Security Rule 15)
#
# An emulator's Bluetooth address and adapter name are identifiers all the
# same. Captures are taken into RAW_DIR, which is never uploaded; what goes to
# LOG_DIR is a copy with every address shape and the adapter's name and
# address — read over adb, held in two shell variables, never printed —
# replaced by a fixed word (mesh_redact). A platform dump is kept only as a
# SKELETON (mesh_skeleton): its lines' shape, every value masked, which is
# what a parser is written against. Everything in LOG_DIR then goes through
# the gate like any lane's. The answers this runner prints are a closed
# vocabulary (MESH_WORDS) and numbers, by construction (mesh_answer).
#
# Usage:
#   run-mesh-lever.sh <leg>...     # each of s0 | probe | s2 | adapter, in order
#   run-mesh-lever.sh --self-test
#
#   s0 probe   the API 34 job: the flag-off control, then the probe
#   s2         the API 29 job
#   adapter    the adapter measurement alone, for a boot of another kind
#              (§O.2.3's first fall-back): no app, no device log
#
# The legs are positional so that the lane-budget check, which reads this one
# file for every job, charges each job the legs it names and no others.

set -Eeuo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR="${script_dir}"

# shellcheck source=tooling/e2e/ci/drive-log-lib.sh
source "${SCRIPT_DIR}/drive-log-lib.sh"
# shellcheck source=tooling/e2e/ci/app-install-lib.sh
source "${SCRIPT_DIR}/app-install-lib.sh"
# shellcheck source=tooling/e2e/ci/logscan-gate.sh
source "${SCRIPT_DIR}/logscan-gate.sh"

# ---------------------------------------------------------------------------
# VERBATIM markers. MUST match the `k*Marker` constants in
# haven/integration_test/mesh_lever_test.dart; the self-test reads that file
# and holds the two together.
# ---------------------------------------------------------------------------
readonly MARK_PHASE='[mesh] PHASE'
readonly MARK_UI='[mesh] UI'
readonly MARK_CHANNEL='[mesh] CHANNEL'
readonly MARK_ANSWER='[mesh] ANSWER'
readonly MARK_PLANT='[mesh] PLANT'
readonly MARK_TURN_ON='[mesh] TURN_ON'
readonly MARK_AFTER='[mesh] AFTER'
readonly MARK_READY='[mesh] READY'
readonly MARK_RELEASED='[mesh] RELEASED'
readonly MARK_HOLD_EXPIRED='[mesh] HOLD_EXPIRED'
readonly MARK_DONE='[mesh] DONE'

readonly PKG='com.oblivioustech.haven'
# The components push B declares, by the names the mesh's Kotlin gives them
# (ChannelWords.TAP_ALIAS; MeshService). Push A declares none.
readonly MESH_SERVICE="${PKG}/.mesh.MeshService"
readonly MESH_ALIAS="${PKG}/.mesh.MeshTap"
# MeshPrefs.FILE: the service's stored copy.
readonly MESH_PREFS_FILE='haven_mesh.xml'
# The notification channel's id stem (MeshNotices: `haven_mesh_v1`).
readonly MESH_CHANNEL_STEM='haven_mesh'
# The release file's name, in the app's data directory (the target's
# `_releasePath`).
readonly RELEASE_FILE='mesh-lane-release'

# Mirrors the target's `_holdBound`: how long it stays alive for the
# inspection below. Tied by the self-test.
readonly HOLD_BOUND_SECS=240

# A turn-on that ends at the unanswered method costs a few channel round
# trips. One that took this long ended somewhere else — the permission
# question never came back (kMeshRadioPermissionBound is 120 s) — and proves
# nothing about the method.
readonly TURN_ON_MAX_MS=60000

# The five buffers `logcat` documents for a shell; fewer readable is a
# misconfigured capture (§O.2.3).
readonly -a DOCUMENTED_BUFFERS=(main system crash radio events)
readonly -a PROBED_BUFFERS=(main system crash radio events stats security kernel)

# Every word an answer may be. `mesh_answer` writes nothing else, so the
# verdict file and the job log carry fixed words and numbers by construction.
readonly -a MESH_WORDS=(
  yes no unread present absent foreign ok nolib nosym refused failed on off
  true false none granted denied deniedForGood stopped running paused skipped
  not_found started error kept other pass red unusable broken snapshot cold
  mac unjudged cancelled bluetoothOff noPermission noPermissionForGood
  unsupported ON OFF TURNING_ON TURNING_OFF BLE_TURNING_ON BLE_ON
  BLE_TURNING_OFF
)

# ---------------------------------------------------------------------------
# Readers — pure text, no device. Everything the verdict rests on is here, so
# `--self-test` exercises it hermetically.
# ---------------------------------------------------------------------------

# The header of an `adb logcat -v threadtime` entry, up to its tag.
readonly THREADTIME_HEAD_RE='^[0-9][0-9]-[0-9][0-9] +[0-9:.]+ +[0-9]+ +[0-9]+ +[A-Z] '

# mesh_entries <capture> — every threadtime entry as `<pid>\t<tag>\t<message>`.
# The tag ends at the first colon-space, trailing padding off (logcat pads a
# tag to eight columns: `flutter : …`).
mesh_entries() {
  [[ -f "${1:-}" ]] || return 0
  LC_ALL=C awk -v head="${THREADTIME_HEAD_RE}" '
    {
      sub(/\r$/, "")
      if (!match($0, head)) next
      rest = substr($0, RLENGTH + 1)
      at = index(rest, ": ")
      if (!at) next
      tag = substr(rest, 1, at - 1)
      sub(/ +$/, "", tag)
      print $3 "\t" tag "\t" substr(rest, at + 2)
    }
  ' "$1"
}

# mesh_load <capture> — the capture's `flutter` entries, read ONCE, into
# MESH_LINES as `<pid>\t<message>`. The oracle asks some forty questions of
# one capture; parsing it for each was most of the self-test's time.
MESH_LINES=""
mesh_load() {
  MESH_LINES="$(mesh_entries "${1:-}" | LC_ALL=C awk -F'\t' '$2 == "flutter" { print $1 "\t" $3 }')"
}

# mesh_loaded_line <prefix> — `<pid>\t<message>` of the LAST loaded entry
# whose message is <prefix> or opens with <prefix> and a space.
mesh_loaded_line() {
  local prefix="${1:-}" line message last=""
  while IFS= read -r line; do
    message="${line#*$'\t'}"
    if [[ "${message}" == "${prefix}" || "${message}" == "${prefix} "* ]]; then
      last="${line}"
    fi
  done <<<"${MESH_LINES}"
  [[ -z "${last}" ]] || printf '%s\n' "${last}"
}

# mesh_loaded_pid <prefix> — the pid that wrote that line, or nothing.
mesh_loaded_pid() {
  local line
  line="$(mesh_loaded_line "${1:-}")"
  [[ -z "${line}" ]] || printf '%s\n' "${line%%$'\t'*}"
}

# mesh_loaded_has <prefix> — 0 when such a line exists.
mesh_loaded_has() { [[ -n "$(mesh_loaded_line "${1:-}")" ]]; }

# mesh_loaded_field <prefix> <key> — the value of ` <key>=<value>` on that
# line, or nothing. PARSED: `button=0` and `button=1` both carry the marker.
mesh_loaded_field() {
  local line word key="${2:-}"
  local -a words=()
  line="$(mesh_loaded_line "${1:-}")"
  read -r -a words <<<"${line#*$'\t'}"
  for word in ${words[@]+"${words[@]}"}; do
    if [[ "${word}" == "${key}="* ]]; then
      printf '%s\n' "${word#*=}"
      return 0
    fi
  done
}

# The same four over a capture file, for a single question.
mesh_line() { local MESH_LINES; mesh_load "${1:-}"; mesh_loaded_line "${2:-}"; }
mesh_line_pid() { local MESH_LINES; mesh_load "${1:-}"; mesh_loaded_pid "${2:-}"; }
mesh_has() { local MESH_LINES; mesh_load "${1:-}"; mesh_loaded_has "${2:-}"; }
mesh_field() { local MESH_LINES; mesh_load "${1:-}"; mesh_loaded_field "${2:-}" "${3:-}"; }

# mesh_plant_seen <capture> <token> <pid> <tag> — where a planted line is:
#   present  an entry under <pid> and <tag> whose whole message is the token
#   foreign  such an entry under another pid
#   absent   neither
# With an empty <tag> any tag counts and the message need only CONTAIN the
# token: an event's tag is a number logcat renders in its own way.
#
# The whole message, not a substring: the target also PRINTS each token, in a
# `[mesh] PLANT …` line under `flutter`, and that line is not the plant.
mesh_plant_seen() {
  local token="${2:-}"
  [[ -n "${token}" ]] || { echo absent; return 0; }
  mesh_entries "${1:-}" | LC_ALL=C awk -F'\t' -v token="${token}" -v pid="${3:-}" -v tag="${4:-}" '
    (tag == "" ? index($3, token) > 0 : ($2 == tag && $3 == token)) {
      if ($1 == pid) mine = 1; else other = 1
    }
    END { print mine ? "present" : (other ? "foreign" : "absent") }
  '
}

# mesh_bt_touch_count <capture> <pid> <token>... — entries under <pid> whose
# tag opens with `Bluetooth` and whose message is none of the tokens: the
# platform's own Bluetooth classes log under such tags from the process that
# uses them, so one of these is Haven having made a Bluetooth object.
mesh_bt_touch_count() {
  local capture="${1:-}" pid="${2:-}"
  shift 2 || true
  mesh_entries "${capture}" | LC_ALL=C awk -F'\t' -v pid="${pid}" -v tokens="$*" '
    BEGIN { n = split(tokens, token, " ") }
    $1 == pid && index($2, "Bluetooth") == 1 {
      planted = 0
      for (i = 1; i <= n; i++) if ($3 == token[i]) planted = 1
      if (!planted) count++
    }
    END { print count + 0 }
  '
}

# mesh_crash_count <capture> — the platform's two records of Haven's process
# dying: the runtime's `Process: <pkg>` and the native crash dump's
# `>>> <pkg> <<<`.
mesh_crash_count() {
  mesh_entries "${1:-}" | LC_ALL=C awk -F'\t' -v pkg="${PKG}" '
    $2 == "AndroidRuntime" && index($3, "Process: " pkg) > 0 { count++ }
    $2 == "DEBUG" && index($3, ">>> " pkg " <<<") > 0 { count++ }
    END { print count + 0 }
  '
}

# mesh_fact <facts> <key> — the last value recorded for <key>, or nothing.
mesh_fact() {
  local line value="" key="${2:-}"
  [[ -f "${1:-}" ]] || return 0
  while IFS= read -r line; do
    if [[ "${line}" == "${key}="* ]]; then value="${line#*=}"; fi
  done < "$1"
  printf '%s\n' "${value}"
}

# mesh_feature_word <feature> — stdin `pm list features`.
mesh_feature_word() {
  tr -d '\r' | LC_ALL=C awk -v want="feature:${1:-}" '
    index($0, "feature:") == 1 { listed = 1 }
    $0 == want || index($0, want "=") == 1 { found = 1 }
    END { print !listed ? "unread" : (found ? "yes" : "no") }
  '
}

# mesh_bt_state_word — stdin `dumpsys bluetooth_manager`: the adapter's state
# as the manager names it, `other` for a word this does not know, `unread`
# where the dump has no state line.
mesh_bt_state_word() {
  tr -d '\r' | LC_ALL=C awk '
    !seen && match($0, /^[ \t]*state:[ \t]*/) {
      seen = 1
      word = substr($0, RLENGTH + 1)
      sub(/[ \t].*$/, "", word)
    }
    END {
      if (!seen) { print "unread"; exit }
      known = " OFF TURNING_ON ON TURNING_OFF BLE_TURNING_ON BLE_ON BLE_TURNING_OFF "
      print index(known, " " word " ") ? word : "other"
    }
  '
}

# mesh_am_word — stdin the output of an `am start…` on a component:
#   not_found  the platform has no such component
#   refused    it has one and would not start it for a shell
#   started    it started
#   error      another error
#   unread     the command said nothing this knows
mesh_am_word() {
  tr -d '\r' | LC_ALL=C awk '
    /Error: Not found|does not exist/ { not_found = 1 }
    /Requires permission|Permission Denial|SecurityException|not exported/ { refused = 1 }
    /Error/ { error = 1 }
    /^Starting( service)?: Intent/ { starting = 1 }
    END {
      if (not_found) print "not_found"
      else if (refused) print "refused"
      else if (error) print "error"
      else if (starting) print "started"
      else print "unread"
    }
  '
}

# mesh_package_counts — stdin `dumpsys package <pkg>`; prints
# `<ok|unread> <mesh components> <mesh permissions>`. `ok` only for a dump
# that names the package and its launcher activity: a count of zero over a
# dump that is not one is the vacuous pass this guards.
#
# Components with an intent filter are what this dump lists (the receiver's
# boot filter puts it here); a service or alias with none is asked of `am`.
mesh_package_counts() {
  tr -d '\r' | LC_ALL=C awk -v pkg="${PKG}" '
    index($0, "Package [" pkg "]") > 0 { named = 1 }
    index($0, pkg "/.MainActivity") > 0 { activity = 1 }
    index($0, pkg "/.mesh.") > 0 || index($0, pkg "/" pkg ".mesh.") > 0 { components++ }
    /android\.permission\.(BLUETOOTH|FOREGROUND_SERVICE_CONNECTED_DEVICE)/ { permissions++ }
    END { print (named && activity ? "ok" : "unread"), components + 0, permissions + 0 }
  '
}

# mesh_dump_count <heading> <needle> — stdin a dump; prints `<ok|unread> <n>`:
# `ok` only where the dump carries <heading>, <n> the lines holding <needle>.
mesh_dump_count() {
  tr -d '\r' | LC_ALL=C awk -v heading="${1:-}" -v needle="${2:-}" '
    index($0, heading) > 0 { headed = 1 }
    index($0, needle) > 0 { count++ }
    END { print (headed ? "ok" : "unread"), count + 0 }
  '
}

# mesh_bluetooth_counts — stdin `dumpsys bluetooth_manager`; `ok` where it
# has the manager's heading or a state line.
mesh_bluetooth_counts() {
  tr -d '\r' | LC_ALL=C awk -v pkg="${PKG}" '
    /Bluetooth Status/ || /^[ \t]*state:[ \t]*[A-Z_]+/ { headed = 1 }
    index($0, pkg) > 0 { count++ }
    END { print (headed ? "ok" : "unread"), count + 0 }
  '
}

# mesh_stored_copy_word — stdin the listing of the app's shared_prefs behind
# the sentinel `lane-ls-end`: the sentinel proves `run-as` ran the listing.
mesh_stored_copy_word() {
  tr -d '\r' | LC_ALL=C awk -v file="${MESH_PREFS_FILE}" '
    $0 == "lane-ls-end" { ended = 1 }
    index($0, file) > 0 { found = 1 }
    END { print !ended ? "unread" : (found ? "present" : "absent") }
  '
}

# mesh_logcat_g_kib — stdin `logcat -g -b <buffer>`: the ring's size in KiB,
# or `unread`. Both spellings: `256 KiB` (Android 14) and `256Kb` (10).
mesh_logcat_g_kib() {
  tr -d '\r' | LC_ALL=C awk '
    !seen && match($0, /ring buffer is [0-9]+ ?[KMkm]?i?[Bb]/) {
      seen = 1
      text = substr($0, RSTART + 15, RLENGTH - 15)
      number = text + 0
      unit = text; gsub(/[0-9 ]/, "", unit)
      first = substr(unit, 1, 1)
      if (first == "M" || first == "m") number *= 1024
      else if (first != "K" && first != "k") number = int(number / 1024)
      print number
    }
    END { if (!seen) print "unread" }
  '
}

# mesh_settings_word — stdin a `settings get`: whether it answered a value.
mesh_settings_word() {
  local value
  value="$(tr -d '\r' | head -n 1)"
  if [[ -z "${value}" || "${value}" == null ]]; then echo no; else echo yes; fi
}

# mesh_addr_shape <value> — `mac` for six colon-separated pairs, `none` for
# nothing, `other` otherwise. The value is never printed.
mesh_addr_shape() {
  if [[ -z "${1:-}" || "${1:-}" == null ]]; then echo none
  elif [[ "$1" =~ ^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$ ]]; then echo mac
  else echo other
  fi
}

# mesh_redact <label> <address> — stdin to stdout, with every Bluetooth
# address shape (`AA:BB:…`, the platform's own `XX:XX:XX:XX:…` redaction)
# and this adapter's name and address replaced by a fixed word. The address
# is also searched bare, in both cases. A name under four characters is not
# searched: it would shred the capture and identify nobody.
mesh_redact() {
  MESH_REDACT_LABEL="${1:-}" MESH_REDACT_ADDR="${2:-}" LC_ALL=C awk '
    function fixed(line, needle, word,    at, out) {
      if (length(needle) < 4) return line
      out = ""
      while ((at = index(line, needle)) > 0) {
        out = out substr(line, 1, at - 1) word
        line = substr(line, at + length(needle))
      }
      return out line
    }
    BEGIN {
      label = ENVIRON["MESH_REDACT_LABEL"]
      addr = ENVIRON["MESH_REDACT_ADDR"]
      if (addr == "null") addr = ""
      if (label == "null") label = ""
      bare = addr; gsub(/:/, "", bare)
      pair = "[0-9A-Fa-fXx][0-9A-Fa-fXx]"
      shape = pair ":" pair ":" pair ":" pair ":" pair ":" pair
    }
    {
      line = fixed($0, label, "<bt-name>")
      if (addr != "") {
        line = fixed(line, addr, "<bt-addr>")
        line = fixed(line, toupper(addr), "<bt-addr>")
        line = fixed(line, tolower(addr), "<bt-addr>")
        line = fixed(line, toupper(bare), "<bt-addr>")
        line = fixed(line, tolower(bare), "<bt-addr>")
      }
      gsub(shape, "<bt-addr>", line)
      print line
    }
  '
}

# How much of a dump's skeleton is kept.
readonly SKELETON_MAX_LINES=3000

# mesh_skeleton <label> <address> — stdin a platform dump, stdout its
# SKELETON: indentation, punctuation and the words that are the platform's
# own vocabulary, with every value masked. That is what a parser is written
# against, and it can carry no identifier BY CONSTRUCTION rather than by luck:
#
#   * mesh_redact first;
#   * any word holding a digit is `<n>` (a number) or `<x>`: an id, a hash, a
#     time, an address, a version;
#   * any word holding `://` is `<uri>`, and one that opens with `/` or
#     holds `~` is `<path>`: an install directory's name is random;
#   * any word with a run of 24 or more of `[A-Za-z0-9+/]` is `<long>`: no
#     encoded blob survives, whatever its digits;
#   * `geo`, `geohash` and `gh` are `<x>`;
#   * after a key that names something a user or a device chose — a name, an
#     address, a title, a text, an alias, an account — the rest of the line is
#     `<redacted>`.
#
# Still scanned as `diag`, every rule and every needle on, so the claim is
# checked and not merely made.
mesh_skeleton() {
  mesh_redact "${1:-}" "${2:-}" | head -n "${SKELETON_MAX_LINES}" | tr -d '\r' | LC_ALL=C awk '
    function shape(word,    run, rest) {
      if (word == "<bt-name>" || word == "<bt-addr>") return word
      if (index(word, "://") > 0) return "<uri>"
      if (substr(word, 1, 1) == "/" || index(word, "~") > 0) return "<path>"
      rest = word
      while (match(rest, /[A-Za-z0-9+\/]+/)) {
        if (RLENGTH >= 24) return "<long>"
        rest = substr(rest, RSTART + RLENGTH)
      }
      if (word ~ /[0-9]/) return (word ~ /^[0-9.,:-]+$/) ? "<n>" : "<x>"
      if (tolower(word) ~ /^(geo|geohash|gh)$/) return "<x>"
      return word
    }
    {
      match($0, /^[ \t]*/)
      out = substr($0, 1, RLENGTH)
      rest = substr($0, RLENGTH + 1)
      while (rest != "") {
        if (match(rest, /^[^] \t=(){}[,;"]+/)) {
          word = substr(rest, 1, RLENGTH)
          rest = substr(rest, RLENGTH + 1)
          colon = ""
          if (word ~ /:$/ && length(word) > 1) { colon = ":"; word = substr(word, 1, length(word) - 1) }
          out = out shape(word) colon
          key = tolower(word)
          if (key ~ /(name|addr|address|alias|title|text|label|ticker|summary|ssid|account|identity)$/ \
              && (colon == ":" || substr(rest, 1, 1) == "=")) {
            out = out (colon == ":" ? " " : "=") "<redacted>"
            break
          }
        } else {
          out = out substr(rest, 1, 1)
          rest = substr(rest, 2)
        }
      }
      print out
    }
  '
}

# ---------------------------------------------------------------------------
# The oracle.
# ---------------------------------------------------------------------------
MESH_RED=()
MESH_UNUSABLE=()
MESH_BROKEN=()
MESH_ANSWERS=()

mesh_red() { MESH_RED+=("$*"); }
mesh_unusable() { MESH_UNUSABLE+=("$*"); }
mesh_broken() { MESH_BROKEN+=("$*"); }

# mesh_answer <key> <value> [n] — records `<key>=<value>`: a value that is not
# a number (with `n`) or one of MESH_WORDS is written as `other`, so nothing
# a capture held can reach the verdict file or the job log.
mesh_answer() {
  local key="$1" value="${2:-}" kind="${3:-w}" word ok=0
  if [[ "${kind}" == n ]]; then
    [[ "${value}" =~ ^[0-9]{1,9}$ ]] && ok=1
  else
    for word in "${MESH_WORDS[@]}"; do
      [[ "${value}" == "${word}" ]] && ok=1
    done
  fi
  (( ok )) || value=other
  MESH_ANSWERS+=("${key}=${value}")
}

# mesh_verdict_rc — 1 > 2 > 3 > 0 over what the oracle found.
mesh_verdict_rc() {
  if (( ${#MESH_RED[@]} > 0 )); then return 1; fi
  if (( ${#MESH_BROKEN[@]} > 0 )); then return 2; fi
  if (( ${#MESH_UNUSABLE[@]} > 0 )); then return 3; fi
  return 0
}

# mesh_require_dump <facts> <key> <what> — a dump the host could not read is
# a question nobody answered.
mesh_require_dump() {
  local state
  state="$(mesh_fact "$1" "$2")"
  [[ "${state}" == ok ]] && return 0
  mesh_unusable "$3 could not be read (${2}=${state:-missing}), so what it would have shown is unknown."
  return 1
}

# mesh_require_zero <facts> <key> <what>
mesh_require_zero() {
  local count
  count="$(mesh_fact "$1" "$2")"
  [[ "${count}" == 0 ]] && return 0
  mesh_red "$3 (${2}=${count:-missing})."
  return 1
}

# mesh_run_oracle <leg> <logcat> <events> <facts> — s0 | probe | s2. Reads
# complete captures; no device. Fills the four arrays and returns the verdict.
mesh_run_oracle() {
  local leg="$1" logcat="$2" events="$3" facts="$4"
  MESH_RED=(); MESH_UNUSABLE=(); MESH_BROKEN=(); MESH_ANSWERS=()
  mesh_load "${logcat}"
  local flag_on=1 want_flag=on
  if [[ "${leg}" == s0 ]]; then flag_on=0; want_flag=off; fi

  # --- Haven's process must not have died, in any leg ----------------------
  local crashes
  crashes="$(mesh_crash_count "${logcat}")"
  if (( crashes > 0 )); then
    mesh_red "the platform recorded Haven's process dying (${crashes} record(s) in the device log)."
  fi

  # --- Control: the target reported, from the process the host inspected ---
  local pid flag line_pid host_pid
  pid="$(mesh_loaded_field "${MARK_PHASE}" pid)"
  flag="$(mesh_loaded_field "${MARK_PHASE}" flag)"
  line_pid="$(mesh_loaded_pid "${MARK_PHASE}")"
  host_pid="$(mesh_fact "${facts}" pid_host)"
  if [[ ! "${pid}" =~ ^[0-9]+$ ]]; then
    mesh_unusable "the drive target never reported: no '${MARK_PHASE}' line under the flutter tag. The app did not launch, the drive did not reach it, or the capture is not live. Nothing below can be judged."
    mesh_verdict_rc
    return
  fi
  if [[ "${line_pid}" != "${pid}" ]]; then
    mesh_unusable "the '${MARK_PHASE}' line names one pid and was written by another: the capture cannot be attributed to the target."
    mesh_verdict_rc
    return
  fi
  if [[ "${flag}" != "${want_flag}" ]]; then
    mesh_broken "leg ${leg} drove a build whose mesh flag reads '${flag:-nothing}', and it needs '${want_flag}': the wrong APK was installed."
    mesh_verdict_rc
    return
  fi
  if [[ "$(mesh_fact "${facts}" drive_failed)" != no ]]; then
    mesh_red "the drive did not complete cleanly (flutter drive failed, or the suite on the device reported a failure) after the target had started."
  fi
  if [[ "${host_pid}" != "${pid}" ]]; then
    mesh_unusable "the host read pid '${host_pid:-nothing}' for ${PKG} while the target reported '${pid}': what the host inspected was not the process that reported."
  fi
  if mesh_loaded_has "${MARK_HOLD_EXPIRED}"; then
    mesh_unusable "the target's hold ran out before the host had finished inspecting it (${HOLD_BOUND_SECS}s): what was read may have been read of an app no longer running."
  elif ! mesh_loaded_has "${MARK_RELEASED}" || ! mesh_loaded_has "${MARK_DONE}"; then
    mesh_unusable "the target never reached '${MARK_RELEASED}' and '${MARK_DONE}': it ended, or the capture did, inside the inspection."
  fi

  # --- Control: the plant call writes and the capture is live (P2) ---------
  local p1_token p2_token p3_token p1 p2 p3 p1_call p2_call p3_call
  p1_token="$(mesh_loaded_field "${MARK_PLANT} id=p1" token)"
  p2_token="$(mesh_loaded_field "${MARK_PLANT} id=p2" token)"
  p3_token="$(mesh_loaded_field "${MARK_PLANT} id=p3" token)"
  p1_call="$(mesh_loaded_field "${MARK_PLANT} id=p1" call)"
  p2_call="$(mesh_loaded_field "${MARK_PLANT} id=p2" call)"
  p3_call="$(mesh_loaded_field "${MARK_PLANT} id=p3" call)"
  p1="$(mesh_plant_seen "${logcat}" "${p1_token}" "${pid}" BluetoothGatt)"
  p2="$(mesh_plant_seen "${logcat}" "${p2_token}" "${pid}" flutter)"
  p3="$(mesh_plant_seen "${events}" "${p3_token}" "${pid}" "")"
  mesh_answer "${leg}.p1" "${p1}"
  mesh_answer "${leg}.p1_call" "${p1_call}"
  mesh_answer "${leg}.p2" "${p2}"
  mesh_answer "${leg}.p3" "${p3}"
  mesh_answer "${leg}.p3_call" "${p3_call}"
  if [[ "${p2}" != present ]]; then
    mesh_unusable "P2: the line planted under the flutter tag through liblog is ${p2} (call: ${p2_call:-unreported}). The plant call does not write, or the capture does not hold Haven's lines; a planted line that is missing elsewhere would mean nothing."
  fi
  if [[ "${p1}" == foreign || "${p3}" == foreign ]]; then
    mesh_unusable "a planted token is in the log under a pid that is not the target's: the capture cannot be attributed."
  fi

  # --- P1: a platform Bluetooth tag, written with no lever -----------------
  # A promise in S0 and S2 (no lever is in the process, so the line is there);
  # an answer in the probe, which exists to say whether the plant is sound.
  if [[ "${leg}" != probe && "${p2}" == present && "${p1}" == absent ]]; then
    mesh_red "P1: a DEBUG line written under BluetoothGatt from Haven's process is not in the log, while the flutter line written by the same call is. Either a log lever is in a process that must have none, or this platform drops such a line; the probe leg's p1 answer says which."
  fi

  # --- No Bluetooth object was made in Haven's process ---------------------
  # Judged only where P1 is present: that is what shows such a line would be
  # in this capture at all.
  if [[ "${p1}" == present ]]; then
    local touched
    touched="$(mesh_bt_touch_count "${logcat}" "${pid}" "${p1_token}")"
    mesh_answer "${leg}.bt_tag_lines" "${touched}" n
    if (( touched > 0 )); then
      mesh_red "${touched} line(s) under a platform Bluetooth tag were written from Haven's process and are not the planted one: something in this build made a Bluetooth object, which nothing in push A may."
    fi
  else
    mesh_answer "${leg}.bt_tag_lines" unjudged
  fi

  # --- The channel ---------------------------------------------------------
  local asked missing answered failed lever_missing
  asked="$(mesh_loaded_field "${MARK_CHANNEL}" asked)"
  missing="$(mesh_loaded_field "${MARK_CHANNEL}" missing)"
  answered="$(mesh_loaded_field "${MARK_CHANNEL}" answered)"
  failed="$(mesh_loaded_field "${MARK_CHANNEL}" failed)"
  lever_missing="$(mesh_loaded_field "${MARK_CHANNEL}" lever_missing)"
  if [[ -z "${asked}" ]]; then
    mesh_unusable "the target never reported the channel ('${MARK_CHANNEL}')."
  elif (( ! flag_on )); then
    if [[ "${asked}" != 11 || "${missing}" != 11 || "${answered}" != 0 || "${failed}" != 0 ]]; then
      mesh_red "a build without the flag has a native end on the mesh's channel: of ${asked} methods asked, ${missing} were missing, ${answered} answered and ${failed} failed. All eleven must be missing."
    fi
  else
    if [[ "${lever_missing}" != 3 ]]; then
      mesh_red "a method behind the log lever is answered: ${lever_missing:-none} of bluetoothOn, bluetoothName and start were missing, and in push A all three must be. The lever is reachable ahead of the lane that proves it."
    fi
    if [[ "${asked}" != 7 || "${answered}" != 4 || "${failed}" != 0 ]]; then
      mesh_red "the channel does not answer what push A answers: of ${asked} methods asked, ${answered} answered and ${failed} failed; permission, status, supported and takeAction must each answer."
    fi
  fi

  local supported permission state wanted
  supported="$(mesh_loaded_field "${MARK_ANSWER}" supported)"
  permission="$(mesh_loaded_field "${MARK_ANSWER}" permission)"
  state="$(mesh_loaded_field "${MARK_ANSWER}" state)"
  wanted="$(mesh_loaded_field "${MARK_ANSWER}" wanted)"
  mesh_answer "${leg}.supported" "${supported}"
  mesh_answer "${leg}.permission" "${permission}"
  if [[ -z "${supported}" ]]; then
    mesh_unusable "the target never reported the channel's answers ('${MARK_ANSWER}')."
  elif (( ! flag_on )); then
    if [[ "${supported}" != none || "${permission}" != none || "${state}" != none || "${wanted}" != none ]]; then
      mesh_red "a build without the flag answered a question of the mesh's (supported=${supported} permission=${permission} state=${state} wanted=${wanted})."
    fi
  else
    if [[ "${state}" != stopped || "${wanted}" != false ]]; then
      mesh_red "before anything was asked the radio reads state=${state} wanted=${wanted}; a build of push A has no service, so it must read stopped and not wanted."
    fi
    if [[ "${leg}" == s2 && "${supported}" != false ]]; then
      mesh_red "below Android 11 the channel answers supported=${supported}; it must answer false there."
    fi
    if [[ "${leg}" == probe ]]; then
      local le_feature
      le_feature="$(mesh_fact "${facts}" le_feature)"
      if [[ "${le_feature}" == yes && "${supported}" != true ]] || [[ "${le_feature}" == no && "${supported}" != false ]]; then
        mesh_red "the channel answers supported=${supported} on an image whose Bluetooth LE feature reads '${le_feature}': the two must agree on Android 11 and later."
      fi
    fi
  fi

  # --- The tree ------------------------------------------------------------
  local shell button want_button=0
  shell="$(mesh_loaded_field "${MARK_UI}" shell)"
  button="$(mesh_loaded_field "${MARK_UI}" button)"
  mesh_answer "${leg}.ui_button" "${button}" n
  if [[ "${leg}" == probe && "${supported}" == true ]]; then want_button=1; fi
  if [[ -z "${shell}" ]]; then
    mesh_unusable "the target never reported the tree ('${MARK_UI}')."
  elif [[ "${shell}" != 1 ]]; then
    mesh_unusable "the map was not on screen (shell=${shell}), so a count of mesh buttons says nothing about whether one would be drawn."
  elif [[ -z "${supported}" ]]; then
    : # How many buttons there must be is the radio's answer, which is missing: unusable, above.
  elif [[ "${button}" != "${want_button}" ]]; then
    if (( want_button )); then
      mesh_red "a flag-on build on a phone the radio says can run the mesh draws ${button} mesh button(s); it must draw one. That one is also what shows the other legs' zero is a finding."
    else
      mesh_red "${button} mesh button(s) are in the tree of a build or a phone that must offer nothing of the mesh."
    fi
  fi

  # --- The turn-on, and what it left ---------------------------------------
  local ended turn_ms after_state after_wanted
  ended="$(mesh_loaded_field "${MARK_TURN_ON}" ended)"
  turn_ms="$(mesh_loaded_field "${MARK_TURN_ON}" ms)"
  after_state="$(mesh_loaded_field "${MARK_AFTER}" state)"
  after_wanted="$(mesh_loaded_field "${MARK_AFTER}" wanted)"
  mesh_answer "${leg}.turn_on" "${ended}"
  mesh_answer "${leg}.turn_on_ms" "${turn_ms}" n
  if [[ -z "${ended}" ]]; then
    mesh_unusable "the target never reported its turn-on ('${MARK_TURN_ON}')."
  elif [[ "${ended}" == skipped ]]; then
    mesh_unusable "the turn-on was not asked: the radio's permission reads '${permission}', so the system would have shown its dialog and the answer would have been the dialog's bound. The grant did not take."
  elif [[ "${ended}" != failed ]]; then
    mesh_red "a turn-on ended '${ended}'. In push A no build can turn the mesh on: it must end 'failed' at the unanswered method, with nothing stored."
  elif (( flag_on )) && [[ ! "${turn_ms}" =~ ^[0-9]+$ || "${turn_ms}" -ge "${TURN_ON_MAX_MS}" ]]; then
    mesh_unusable "the turn-on took ${turn_ms:-an unreported number of} ms to fail: that is not the unanswered method answering, so where it ended is unknown."
  fi
  if [[ -z "${after_state}" ]]; then
    mesh_unusable "the target never reported the radio after its turn-on ('${MARK_AFTER}')."
  elif (( flag_on )) && [[ "${after_state}" != stopped || "${after_wanted}" != false ]]; then
    mesh_red "after the turn-on the radio reads state=${after_state} wanted=${after_wanted}: something was started or stored."
  elif (( ! flag_on )) && [[ "${after_state}" != none || "${after_wanted}" != none ]]; then
    mesh_red "after the turn-on a build without the flag answers the radio's status (state=${after_state} wanted=${after_wanted})."
  fi

  # --- The host's reading of the device ------------------------------------
  if mesh_require_dump "${facts}" package_dump "\`dumpsys package ${PKG}\`"; then
    mesh_require_zero "${facts}" package_mesh_components "the installed package declares a component of the mesh's, and no build of push A may" || true
    if (( flag_on )); then
      mesh_answer "${leg}.package_mesh_permissions" "$(mesh_fact "${facts}" package_mesh_permissions)" n
    else
      mesh_require_zero "${facts}" package_mesh_permissions "a build without the flag requests a Bluetooth or connected-device permission" || true
    fi
  fi
  local am_key am_word
  for am_key in am_fgs am_svc am_alias; do
    am_word="$(mesh_fact "${facts}" "${am_key}")"
    case "${am_word}" in
      not_found) ;;
      unread|'') mesh_unusable "the platform's answer to starting the mesh's component was not understood (${am_key}=${am_word:-missing})." ;;
      *) mesh_red "the platform knows a component of the mesh's (${am_key}=${am_word}): asked to start it, it did not answer that none exists." ;;
    esac
  done
  if mesh_require_dump "${facts}" services_dump "\`dumpsys activity services\`"; then
    mesh_require_zero "${facts}" services_mesh "the mesh's service is running" || true
  fi
  if mesh_require_dump "${facts}" notification_dump "\`dumpsys notification\`"; then
    mesh_require_zero "${facts}" notification_mesh "the mesh's notification channel or a notice of it exists" || true
  fi
  if mesh_require_dump "${facts}" bluetooth_dump "\`dumpsys bluetooth_manager\`"; then
    mesh_require_zero "${facts}" bluetooth_names_haven "the Bluetooth manager names Haven among what it serves" || true
  fi
  case "$(mesh_fact "${facts}" stored_copy)" in
    absent) ;;
    present) mesh_red "the service's stored copy (${MESH_PREFS_FILE}) exists, and nothing in push A may write it." ;;
    *) mesh_unusable "the app's stored preferences could not be listed (\`run-as\` did not answer), so whether the turn-on stored anything is unknown." ;;
  esac

  # --- The probe's measurements: each must have been TAKEN -----------------
  if [[ "${leg}" == probe ]]; then
    local key value readable=0 buffer
    for key in le_feature bt_on; do
      value="$(mesh_fact "${facts}" "${key}")"
      mesh_answer "probe.${key}" "${value}"
      if [[ "${value}" != yes && "${value}" != no ]]; then
        mesh_unusable "the probe could not measure ${key} (${value:-missing}): the platform did not answer."
      fi
    done
    mesh_answer probe.boot "$(mesh_fact "${facts}" boot)"
    mesh_answer probe.bt_state "$(mesh_fact "${facts}" bt_state)"
    mesh_answer probe.bt_on_after_s "$(mesh_fact "${facts}" bt_on_after_s)" n
    for key in setprop_log_tag adapter_address_readable adapter_label_readable; do
      value="$(mesh_fact "${facts}" "${key}")"
      mesh_answer "probe.${key}" "${value}"
      if [[ "${value}" != yes && "${value}" != no ]]; then
        mesh_unusable "the probe could not measure ${key} (${value:-missing})."
      fi
    done
    mesh_answer probe.adapter_address_shape "$(mesh_fact "${facts}" adapter_address_shape)"
    for buffer in "${PROBED_BUFFERS[@]}"; do
      value="$(mesh_fact "${facts}" "buffer_${buffer}_kib")"
      if [[ "${value}" =~ ^[0-9]+$ ]]; then
        mesh_answer "probe.buffer_${buffer}_kib" "${value}" n
      else
        mesh_answer "probe.buffer_${buffer}_kib" unread
      fi
    done
    for buffer in "${DOCUMENTED_BUFFERS[@]}"; do
      [[ "$(mesh_fact "${facts}" "buffer_${buffer}_kib")" =~ ^[0-9]+$ ]] && readable=$(( readable + 1 ))
    done
    mesh_answer probe.buffers_readable "${readable}" n
    if (( readable < ${#DOCUMENTED_BUFFERS[@]} )); then
      mesh_unusable "a shell reads ${readable} of the five log buffers logcat documents (main, system, crash, radio, events): a misconfigured capture, and no list for the lever's lane to capture."
    fi
    for key in dump_services dump_notification dump_bluetooth; do
      value="$(mesh_fact "${facts}" "${key}")"
      mesh_answer "probe.${key}" "${value}"
      if [[ "${value}" != kept ]]; then
        mesh_unusable "the probe did not keep the skeleton of a dump (${key}=${value:-missing}): the lever's parsers would be written against nothing."
      fi
    done
  fi

  mesh_verdict_rc
}

# mesh_report <leg> <rc> — the oracle's findings and answers, in fixed words.
# Nothing a capture held is printed: the findings are this file's sentences
# over parsed numbers and words of MESH_WORDS, and the answers are filtered.
mesh_report() {
  local leg="$1" rc="$2" line verdict=pass
  case "${rc}" in 1) verdict=red ;; 2) verdict=broken ;; 3) verdict=unusable ;; esac
  for line in ${MESH_RED[@]+"${MESH_RED[@]}"}; do echo "  RED (${leg}): ${line}" >&2; done
  for line in ${MESH_BROKEN[@]+"${MESH_BROKEN[@]}"}; do echo "  BROKEN (${leg}): ${line}" >&2; done
  for line in ${MESH_UNUSABLE[@]+"${MESH_UNUSABLE[@]}"}; do echo "  UNUSABLE (${leg}): ${line}" >&2; done
  mesh_answer "${leg}.verdict" "${verdict}"
  for line in "${MESH_ANSWERS[@]}"; do echo "  mesh-answer: ${line}"; done
}

# ---------------------------------------------------------------------------
# Self-test — hermetic: fixture captures, no device, no relay.
# ---------------------------------------------------------------------------
run_self_test() {
  local tmp fails=0 checks=0 rc
  tmp="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf '${tmp}'" RETURN

  _case() { # <label> <expected-rc> <actual-rc>
    checks=$(( checks + 1 ))
    if [[ "$3" -eq "$2" ]]; then
      printf '  \033[1;32mPASS\033[0m %s\n' "$1"
    else
      printf '  \033[1;31mFAIL\033[0m %s (want rc=%s, got rc=%s)\n' "$1" "$2" "$3" >&2
      fails=1
    fi
  }
  _eq_case() { # <label> <expected> <actual>
    checks=$(( checks + 1 ))
    if [[ "$3" == "$2" ]]; then
      printf '  \033[1;32mPASS\033[0m %s\n' "$1"
    else
      printf '  \033[1;31mFAIL\033[0m %s (want "%s", got "%s")\n' "$1" "$2" "$3" >&2
      fails=1
    fi
  }

  # A threadtime entry.
  _entry() { printf '11-14 10:00:00.000 %5d %5d %s %-8s: %s\n' "$1" "$1" "$2" "$3" "$4"; }

  # _capture <leg> <logcat> <events> <facts> — a complete, PASSING leg. Each
  # negative fixture below changes exactly one thing in a copy.
  local T1='mesh-lane-plant-p1-GABHCDJEFK' T2='mesh-lane-plant-p2-HABJCDKEFM' T3='mesh-lane-plant-p3-JABKCDMEFN'
  _capture() {
    local leg="$1" logcat="$2" events="$3" facts="$4"
    local flag=on channel answer ui='shell=1 button=0 available=false supported_read=false'
    local after='state=stopped wanted=false' perms=6
    case "${leg}" in
      s0)
        flag=off; perms=0
        channel='asked=11 missing=11 answered=0 failed=0 lever_missing=3'
        answer='supported=none permission=none state=none wanted=none'
        after='state=none wanted=none' ;;
      probe)
        channel='asked=7 missing=3 answered=4 failed=0 lever_missing=3'
        answer='supported=true permission=granted state=stopped wanted=false'
        ui='shell=1 button=1 available=true supported_read=true' ;;
      s2)
        channel='asked=7 missing=3 answered=4 failed=0 lever_missing=3'
        answer='supported=false permission=granted state=stopped wanted=false' ;;
    esac
    {
      echo '--------- beginning of main'
      _entry 900 D BluetoothAdapter 'the Bluetooth process speaks of AA:BB:CC:DD:EE:01'
      _entry 4021 I flutter "${MARK_PHASE} flag=${flag} pid=4021"
      _entry 4021 I flutter "${MARK_UI} ${ui}"
      _entry 4021 I flutter "${MARK_CHANNEL} ${channel}"
      _entry 4021 I flutter "${MARK_ANSWER} ${answer}"
      _entry 4021 D BluetoothGatt "${T1}"
      _entry 4021 I flutter "${MARK_PLANT} id=p1 token=${T1} call=ok"
      _entry 4021 I flutter "${T2}"
      _entry 4021 I flutter "${MARK_PLANT} id=p2 token=${T2} call=ok"
      _entry 4021 I flutter "${MARK_PLANT} id=p3 token=${T3} call=ok"
      _entry 4021 I flutter "${MARK_TURN_ON} ended=failed ms=412"
      _entry 4021 I flutter "${MARK_AFTER} ${after}"
      _entry 4021 I flutter "${MARK_READY}"
      _entry 4021 I flutter "${MARK_RELEASED}"
      _entry 4021 I flutter "${MARK_DONE}"
    } > "${logcat}"
    {
      echo '--------- beginning of events'
      _entry 4021 I '[1296388936]' "${T3}"
    } > "${events}"
    printf '%s\n' pid_host=4021 drive_failed=no \
      package_dump=ok package_mesh_components=0 "package_mesh_permissions=${perms}" \
      am_fgs=not_found am_svc=not_found am_alias=not_found \
      services_dump=ok services_mesh=0 notification_dump=ok notification_mesh=0 \
      bluetooth_dump=ok bluetooth_names_haven=0 stored_copy=absent > "${facts}"
    if [[ "${leg}" == probe ]]; then
      printf '%s\n' boot=snapshot le_feature=yes bt_on=yes bt_state=ON bt_on_after_s=4 \
        setprop_log_tag=yes adapter_address_readable=yes adapter_address_shape=mac \
        adapter_label_readable=yes buffer_main_kib=256 buffer_system_kib=256 \
        buffer_crash_kib=256 buffer_radio_kib=256 buffer_events_kib=256 \
        buffer_stats_kib=64 buffer_security_kib=unread buffer_kernel_kib=unread \
        dump_services=kept dump_notification=kept dump_bluetooth=kept >> "${facts}"
    fi
  }

  # _oracle <label> <leg> <want-rc> [<finding-substring>] — runs the oracle
  # over ${tmp}/c.{logcat,events,facts} and, for a non-zero verdict, requires
  # the finding that names the cause: a fixture that fails for another reason
  # would otherwise pass for the wrong one.
  _oracle() {
    local label="$1" leg="$2" want="$3" needle="${4:-}" got=0 all
    mesh_run_oracle "${leg}" "${tmp}/c.logcat" "${tmp}/c.events" "${tmp}/c.facts" || got=$?
    _case "${label}" "${want}" "${got}"
    if [[ -n "${needle}" ]]; then
      all="$(printf '%s\n' ${MESH_RED[@]+"${MESH_RED[@]}"} ${MESH_BROKEN[@]+"${MESH_BROKEN[@]}"} ${MESH_UNUSABLE[@]+"${MESH_UNUSABLE[@]}"})"
      _eq_case "…and names it: ${needle}" 1 "$(grep -cF -- "${needle}" <<<"${all}" | awk '{ print ($1 > 0) }')"
    fi
  }
  # _fresh <leg>; _edit <file-suffix> <sed-expression> <expected-substring>
  _fresh() { _capture "$1" "${tmp}/c.logcat" "${tmp}/c.events" "${tmp}/c.facts"; }
  _edit() {
    sed -i -e "$2" "${tmp}/c.$1"
    if [[ -n "${3:-}" ]] && ! grep -qF -- "$3" "${tmp}/c.$1"; then
      printf '  \033[1;31mFAIL\033[0m self-test setup: the mutation did not apply — expected %s\n' "$3" >&2
      fails=1
    fi
  }
  _drop() { # <file-suffix> <fixed-substring> — delete the lines holding it
    if ! grep -qF -- "$2" "${tmp}/c.$1"; then
      printf '  \033[1;31mFAIL\033[0m self-test setup: nothing to drop for %s\n' "$2" >&2
      fails=1
    fi
    grep -vF -- "$2" "${tmp}/c.$1" > "${tmp}/c.tmp" || true
    mv "${tmp}/c.tmp" "${tmp}/c.$1"
  }

  echo "run-mesh-lever.sh --self-test"

  # --- readers --------------------------------------------------------------
  _fresh probe
  _eq_case "a marker's field is parsed from the flutter line" 4021 \
    "$(mesh_field "${tmp}/c.logcat" "${MARK_PHASE}" pid)"
  _eq_case "…and the pid that wrote it is read from the entry, not the text" 4021 \
    "$(mesh_line_pid "${tmp}/c.logcat" "${MARK_PHASE}")"
  _eq_case "a prefix matches a whole word: PLANT id=p1 is not id=p10" "" \
    "$(mesh_field "${tmp}/c.logcat" "${MARK_PLANT} id=p" token)"
  _entry 4021 I OtherTag "${MARK_PHASE} flag=off pid=77" > "${tmp}/tag.logcat"
  _eq_case "a marker under another tag is not the target's" "" \
    "$(mesh_field "${tmp}/tag.logcat" "${MARK_PHASE}" pid)"
  printf '%s\n' "${MARK_PHASE} flag=on pid=5" > "${tmp}/raw.logcat"
  _eq_case "a line that is no threadtime entry is not read" "" \
    "$(mesh_field "${tmp}/raw.logcat" "${MARK_PHASE}" pid)"
  _eq_case "a missing capture reads as nothing" "" \
    "$(mesh_field "${tmp}/nope" "${MARK_PHASE}" pid)"

  _eq_case "P1 is present under the target's pid and tag" present \
    "$(mesh_plant_seen "${tmp}/c.logcat" "${T1}" 4021 BluetoothGatt)"
  _eq_case "…and foreign under another pid" foreign \
    "$(mesh_plant_seen "${tmp}/c.logcat" "${T1}" 5000 BluetoothGatt)"
  _eq_case "…and absent under another tag" absent \
    "$(mesh_plant_seen "${tmp}/c.logcat" "${T1}" 4021 BluetoothGattServer)"
  _eq_case "the target's own PLANT line is not the planted line" absent \
    "$(mesh_plant_seen "${tmp}/c.logcat" "${T3}" 4021 flutter)"
  _eq_case "an event is found by its token under the pid, whatever its tag" present \
    "$(mesh_plant_seen "${tmp}/c.events" "${T3}" 4021 "")"
  _eq_case "no token is no plant" absent "$(mesh_plant_seen "${tmp}/c.logcat" "" 4021 flutter)"

  _eq_case "another process's Bluetooth lines are not Haven's" 0 \
    "$(mesh_bt_touch_count "${tmp}/c.logcat" 4021 "${T1}")"
  _entry 4021 D BluetoothAdapter 'isLeEnabled(): ON' >> "${tmp}/c.logcat"
  _eq_case "a Bluetooth-tagged line of Haven's that is no plant is counted" 1 \
    "$(mesh_bt_touch_count "${tmp}/c.logcat" 4021 "${T1}")"
  _eq_case "…and without the token the plant itself is counted too" 2 \
    "$(mesh_bt_touch_count "${tmp}/c.logcat" 4021)"

  {
    _entry 4021 E AndroidRuntime 'FATAL EXCEPTION: main'
    _entry 4021 E AndroidRuntime "Process: ${PKG}, PID: 4021"
    _entry 5100 E AndroidRuntime 'Process: com.example.other, PID: 5100'
    _entry 6000 F DEBUG "pid: 4021, tid: 4040, name: 1.ui  >>> ${PKG} <<<"
  } > "${tmp}/crash.logcat"
  _eq_case "both crash records of Haven's are counted, another app's is not" 2 \
    "$(mesh_crash_count "${tmp}/crash.logcat")"

  _eq_case "the LE feature is read" yes \
    "$(printf 'feature:android.hardware.bluetooth\nfeature:android.hardware.bluetooth_le\n' | mesh_feature_word android.hardware.bluetooth_le)"
  _eq_case "…a prefix of it is not the feature" no \
    "$(printf 'feature:android.hardware.bluetooth\nfeature:android.hardware.bluetooth_le_extra\n' | mesh_feature_word android.hardware.bluetooth_le)"
  _eq_case "…a versioned feature is" yes \
    "$(printf 'feature:android.hardware.bluetooth_le=1\n' | mesh_feature_word android.hardware.bluetooth_le)"
  _eq_case "…and a listing that is none is unread, not a no" unread \
    "$(printf 'error: device offline\n' | mesh_feature_word android.hardware.bluetooth_le)"

  _eq_case "the adapter's state is read" ON \
    "$(printf 'Bluetooth Status\n  enabled: true\n  state: ON\n  address: 00:11:22:33:44:55\n' | mesh_bt_state_word)"
  _eq_case "…the first state line, not a later profile's" TURNING_ON \
    "$(printf '  state: TURNING_ON\n  A2dp state: ON\n  state: ON\n' | mesh_bt_state_word)"
  _eq_case "…a word it does not know is other" other "$(printf '  state: 12\n' | mesh_bt_state_word)"
  _eq_case "…and no state line is unread" unread "$(printf 'Bluetooth Service not connected\n' | mesh_bt_state_word)"

  _eq_case "a component that does not exist" not_found \
    "$(printf 'Starting service: Intent { cmp=%s }\nError: Not found; no service started.\n' "${MESH_SERVICE}" | mesh_am_word)"
  _eq_case "an alias that does not exist" not_found \
    "$(printf 'Starting: Intent { cmp=%s }\nError type 3\nError: Activity class {%s} does not exist.\n' "${MESH_ALIAS}" "${MESH_ALIAS}" | mesh_am_word)"
  _eq_case "a component that exists and is refused" refused \
    "$(printf 'Starting service: Intent { cmp=%s }\nError: Requires permission not exported from uid 10123\n' "${MESH_SERVICE}" | mesh_am_word)"
  _eq_case "a service that started" started \
    "$(printf 'Starting service: Intent { cmp=%s }\n' "${MESH_SERVICE}" | mesh_am_word)"
  _eq_case "another error" error "$(printf 'Error: app is in background uid null\n' | mesh_am_word)"
  _eq_case "silence is unread, never a refusal" unread "$(printf '' | mesh_am_word)"

  printf '%s\n' \
    'Activity Resolver Table:' \
    "        1a2b3c4 ${PKG}/.MainActivity filter 5d6e7f8" \
    'Packages:' \
    "  Package [${PKG}] (9a8b7c6):" \
    '    requested permissions:' \
    '      android.permission.ACCESS_FINE_LOCATION' > "${tmp}/package.dump"
  _eq_case "a package dump with nothing of the mesh" "ok 0 0" "$(mesh_package_counts < "${tmp}/package.dump")"
  {
    cat "${tmp}/package.dump"
    echo "        2b3c4d5 ${PKG}/.mesh.MeshReceiver filter 6e7f8a9"
    echo '      android.permission.BLUETOOTH_SCAN'
    echo '      android.permission.FOREGROUND_SERVICE_CONNECTED_DEVICE'
  } > "${tmp}/package-mesh.dump"
  _eq_case "…a mesh component and its permissions are counted" "ok 1 2" \
    "$(mesh_package_counts < "${tmp}/package-mesh.dump")"
  _eq_case "…and a dump of another package is unread, not a zero" "unread 0 0" \
    "$(printf 'Unable to find package: %s\n' "${PKG}" | mesh_package_counts)"

  _eq_case "a services dump with no mesh service" "ok 0" \
    "$(printf 'ACTIVITY MANAGER SERVICES (dumpsys activity services)\n  (nothing)\n' | mesh_dump_count 'ACTIVITY MANAGER SERVICES' '.mesh.MeshService')"
  _eq_case "…with one" "ok 1" \
    "$(printf 'ACTIVITY MANAGER SERVICES (dumpsys activity services)\n  * ServiceRecord{1a2b3c u0 %s}\n' "${MESH_SERVICE}" | mesh_dump_count 'ACTIVITY MANAGER SERVICES' '.mesh.MeshService')"
  _eq_case "…and with no heading it is unread" "unread 0" \
    "$(printf "Can't find service: activity\n" | mesh_dump_count 'ACTIVITY MANAGER SERVICES' '.mesh.MeshService')"
  _eq_case "a Bluetooth dump that names Haven" "ok 1" \
    "$(printf 'Bluetooth Status\n  state: ON\n  %s (Registered)\n' "${PKG}" | mesh_bluetooth_counts)"
  _eq_case "…one that does not" "ok 0" "$(printf '  state: OFF\n' | mesh_bluetooth_counts)"
  _eq_case "…and one that is none" "unread 0" "$(printf "Can't find service: bluetooth_manager\n" | mesh_bluetooth_counts)"

  _eq_case "no stored copy" absent "$(printf 'FlutterSharedPreferences.xml\nlane-ls-end\n' | mesh_stored_copy_word)"
  _eq_case "…no preferences at all" absent \
    "$(printf 'ls: shared_prefs: No such file or directory\nlane-ls-end\n' | mesh_stored_copy_word)"
  _eq_case "…a stored copy" present "$(printf '%s\nlane-ls-end\n' "${MESH_PREFS_FILE}" | mesh_stored_copy_word)"
  _eq_case "…and a listing run-as never made is unread" unread \
    "$(printf 'run-as: package not debuggable: %s\n' "${PKG}" | mesh_stored_copy_word)"

  _eq_case "a ring size, Android 14's spelling" 256 \
    "$(printf 'main: ring buffer is 256 KiB (30 KiB consumed, 2 KiB readable), max entry is 5120 B, max payload is 4068 B\n' | mesh_logcat_g_kib)"
  _eq_case "…Android 10's" 256 \
    "$(printf 'main: ring buffer is 256Kb (30Kb consumed), max entry is 5120b, max payload is 4068b\n' | mesh_logcat_g_kib)"
  _eq_case "…megabytes" 1024 "$(printf 'main: ring buffer is 1 MiB (30 KiB consumed)\n' | mesh_logcat_g_kib)"
  _eq_case "…and a buffer a shell cannot read" unread \
    "$(printf "logcat: Unable to get log size for 'security'\n" | mesh_logcat_g_kib)"

  _eq_case "a setting that answered" yes "$(printf '22:22:AB:CD:EF:01\n' | mesh_settings_word)"
  _eq_case "…one that is null" no "$(printf 'null\n' | mesh_settings_word)"
  _eq_case "…one that is empty" no "$(printf '' | mesh_settings_word)"
  _eq_case "an address's shape" mac "$(mesh_addr_shape '22:22:AB:CD:EF:01')"
  _eq_case "…none" none "$(mesh_addr_shape null)"
  _eq_case "…another" other "$(mesh_addr_shape 'not-an-address')"

  # --- redaction ------------------------------------------------------------
  printf '%s\n' \
    '11-14 10:00:00.000   900   900 D bt_stack: local 22:22:AB:CD:EF:01 name Lane Phone 7' \
    '11-14 10:00:00.000   900   900 D bt_stack: peer XX:XX:XX:XX:EF:02 and bare 2222abcdef01 / 2222ABCDEF01' \
    '11-14 10:00:00.000   900   900 D bt_stack: clock 10:00:00.000 is no address' > "${tmp}/redact.in"
  mesh_redact 'Lane Phone 7' '22:22:AB:CD:EF:01' < "${tmp}/redact.in" > "${tmp}/redact.out"
  _eq_case "redaction leaves no address, bare or shaped, and no adapter name" 0 \
    "$(grep -ciE '22:22|2222abcdef01|XX:XX:XX:XX:EF:02|Lane Phone' "${tmp}/redact.out" || true)"
  _eq_case "…replaces each with its fixed word" "4 1" \
    "$(grep -o '<bt-addr>' "${tmp}/redact.out" | grep -c . || true) $(grep -o '<bt-name>' "${tmp}/redact.out" | grep -c . || true)"
  _eq_case "…and keeps every line an entry, a clock time untouched" 3 \
    "$(grep -cE '^11-14 10:00:00\.000 +900 +900 D bt_stack: ' "${tmp}/redact.out" || true)"
  _eq_case "with nothing read the address shapes still go" 0 \
    "$(mesh_redact '' '' < "${tmp}/redact.in" | grep -cE '22:22:AB|XX:XX:XX:XX:EF:02' || true)"
  _eq_case "a name too short to search is not searched" 1 \
    "$(printf 'a b c\n' | mesh_redact 'b' '' | grep -c 'a b c' || true)"

  # --- skeleton -------------------------------------------------------------
  printf '%s\n' \
    'Bluetooth Status' \
    '  enabled: true' \
    '  state: ON' \
    '  address: 22:22:AB:CD:EF:01' \
    '  name: Lane Phone 7' \
    '  time since enabled: 00:01:02.345' \
    'Enable log:' \
    '  11-14 10:00:00  Enabled by com.android.shell' \
    '  * ServiceRecord{1a2b3c4 u0 com.android.bluetooth/.gatt.GattService}' \
    '    intent={cmp=com.android.bluetooth/.gatt.GattService}' \
    '    baseDir=/data/app/~~Zm9vYmFyYmF6cXV1eA==/com.x-QUJDREVGR0hJSktMTU5P==/base.apk' \
    '    NotificationRecord(0x0a1b2c3d: pkg=com.android.systemui user=UserHandle{0} id=7 tag=null importance=2 key=0|com.android.systemui|7|null|10100: Notification(channel=ALR shortcut=null sound=content://settings/system/notification_sound))' \
    '    mName=Alerts for Quiet Wanderer' \
    '    token=QUJDREVGR0hJSktMTU5PUFFSU1RVVldYWVo' \
    '    geo: u4pruyd' \
    '    uuid=0000fe01-0000-1000-8000-00805f9b34fb' \
    '    secret=AbCdEfGhIjKlMnOpQrStUvWxYzAbCd' \
    '    bonded: Lane Phone 7 (22:22:AB:CD:EF:01)' > "${tmp}/skeleton.in"
  mesh_skeleton 'Lane Phone 7' '22:22:AB:CD:EF:01' < "${tmp}/skeleton.in" > "${tmp}/skeleton.out"
  _eq_case "a skeleton carries no digit" 0 "$(grep -c '[0-9]' "${tmp}/skeleton.out" || true)"
  _eq_case "…no address, name, blob, uri, cell or chosen text" 0 \
    "$(grep -ciE '22:22|Lane|Phone|Zm9v|QUJD|content:|u4pruyd|Quiet|Wanderer|fe01' "${tmp}/skeleton.out" || true)"
  _eq_case "…and keeps the dump's own words, keys and indentation" 6 \
    "$(grep -cE '^Bluetooth Status$|^  enabled: true$|^  state: ON$|^  address: <redacted>$|^  name: <redacted>$|^Enable log:$' "${tmp}/skeleton.out" || true)"
  _eq_case "…a record's shape survives its values" 1 \
    "$(grep -cF '  * ServiceRecord{<x> <x> com.android.bluetooth/.gatt.GattService}' "${tmp}/skeleton.out" || true)"
  _eq_case "…a key keeps its name and loses its value" 2 \
    "$(grep -cE '^    intent=\{cmp=com\.android\.bluetooth/\.gatt\.GattService\}$|^    baseDir=<path>==<path>==<path>$' "${tmp}/skeleton.out" || true)"
  _eq_case "…a notice's record keeps every key a parser reads" 1 \
    "$(grep -cF 'NotificationRecord(<x>: pkg=com.android.systemui user=UserHandle{<n>} id=<n> tag=null importance=<n> key=<x>: Notification(channel=ALR shortcut=null sound=<uri>))' "${tmp}/skeleton.out" || true)"
  _eq_case "…a name-like key takes the rest of its line" 1 \
    "$(grep -cE '^    mName=<redacted>$' "${tmp}/skeleton.out" || true)"
  _eq_case "…a blob with no digit in it goes by its length" 1 \
    "$(grep -cE '^    secret=<long>$' "${tmp}/skeleton.out" || true)"
  _eq_case "…the word a cell is found by goes with the cell" 1 \
    "$(grep -cE '^    <x>: <x>$' "${tmp}/skeleton.out" || true)"
  _eq_case "…the adapter's name and address go wherever they stand, not only after a key" 1 \
    "$(grep -cF '    bonded: <bt-name> (<bt-addr>)' "${tmp}/skeleton.out" || true)"
  _eq_case "…every line is kept" 18 "$(grep -c '' "${tmp}/skeleton.out" || true)"

  # --- the oracle: the three passing legs -----------------------------------
  _fresh s0;    _oracle "S0 passes" s0 0
  _fresh probe; _oracle "the probe passes" probe 0
  _eq_case "…and writes its answers in fixed words" 1 \
    "$(printf '%s\n' "${MESH_ANSWERS[@]}" | grep -cx 'probe.bt_on=yes' || true)"
  _eq_case "…the buffers a shell cannot read as unread" 2 \
    "$(printf '%s\n' "${MESH_ANSWERS[@]}" | grep -cE '^probe\.buffer_(security|kernel)_kib=unread$' || true)"
  _fresh s2;    _oracle "S2 passes" s2 0

  # --- the probe answers; it does not judge the platform --------------------
  _fresh probe; _edit facts 's/^bt_on=yes$/bt_on=no/' 'bt_on=no'
  _edit facts 's/^bt_state=ON$/bt_state=OFF/' 'bt_state=OFF'
  _oracle "Bluetooth that does not come on is an answer, not a failure" probe 0
  _eq_case "…written as one" 1 "$(printf '%s\n' "${MESH_ANSWERS[@]}" | grep -cx 'probe.bt_on=no' || true)"
  _fresh probe; _drop logcat "D BluetoothGatt"
  _oracle "P1 absent is the probe's answer" probe 0
  _eq_case "…written as one, with the Bluetooth-tag count unjudged" 2 \
    "$(printf '%s\n' "${MESH_ANSWERS[@]}" | grep -cxE 'probe\.p1=absent|probe\.bt_tag_lines=unjudged' || true)"
  _fresh probe; : > "${tmp}/c.events"
  _edit logcat 's/id=p3 token=\([^ ]*\) call=ok/id=p3 token=\1 call=nosym/' 'call=nosym'
  _oracle "an event the device's liblog will not write is an answer" probe 0
  _eq_case "…written as one" 2 "$(printf '%s\n' "${MESH_ANSWERS[@]}" | grep -cxE 'probe\.p3=absent|probe\.p3_call=nosym' || true)"
  _fresh probe; _edit facts 's/^le_feature=yes$/le_feature=no/' 'le_feature=no'
  _edit logcat 's/supported=true permission/supported=false permission/' 'supported=false permission'
  _edit logcat 's/shell=1 button=1/shell=1 button=0/' 'button=0'
  _oracle "an image with no LE feature is an answer: supported false, no button" probe 0
  _fresh probe; _edit facts 's/^setprop_log_tag=yes$/setprop_log_tag=no/' 'setprop_log_tag=no'
  _edit facts 's/^adapter_address_readable=yes$/adapter_address_readable=no/' 'adapter_address_readable=no'
  _oracle "a shell that cannot set the property or read the address is an answer" probe 0

  # --- …but each measurement must have been taken ---------------------------
  _fresh probe; _edit facts 's/^bt_on=yes$/bt_on=unread/' 'bt_on=unread'
  _oracle "an adapter state nobody could read is unusable" probe 3 'could not measure bt_on'
  _fresh probe; _edit facts 's/^le_feature=yes$/le_feature=unread/' 'le_feature=unread'
  _oracle "a feature list nobody could read is unusable" probe 3 'could not measure le_feature'
  _fresh probe; _drop facts 'setprop_log_tag='
  _oracle "a measurement that was never made is unusable" probe 3 'could not measure setprop_log_tag'
  _fresh probe; _edit facts 's/^buffer_radio_kib=256$/buffer_radio_kib=unread/' 'buffer_radio_kib=unread'
  _oracle "fewer than the five documented buffers is a misconfigured capture" probe 3 'a shell reads 4 of the five'
  _fresh probe; _edit facts 's/^dump_bluetooth=kept$/dump_bluetooth=unread/' 'dump_bluetooth=unread'
  _oracle "a dump whose skeleton was not kept is unusable" probe 3 'did not keep the skeleton'

  # --- what push A promises, in every leg -----------------------------------
  # One suite a leg, side by side: each has its own scratch directory and
  # shares nothing, and together they are most of this self-test's time.
  _leg_suite() {
    local leg="$1"
    _fresh "${leg}"; _edit logcat 's/TURN_ON ended=failed/TURN_ON ended=on/' 'ended=on'
    _oracle "${leg}: a turn-on that succeeds is red" "${leg}" 1 "a turn-on ended 'on'"
    _fresh "${leg}"; _edit facts 's/^package_mesh_components=0$/package_mesh_components=1/' 'package_mesh_components=1'
    _oracle "${leg}: a declared mesh component is red" "${leg}" 1 'declares a component'
    _fresh "${leg}"; _edit facts 's/^am_fgs=not_found$/am_fgs=started/' 'am_fgs=started'
    _oracle "${leg}: a mesh service a shell can start is red" "${leg}" 1 'am_fgs=started'
    _fresh "${leg}"; _edit facts 's/^am_svc=not_found$/am_svc=refused/' 'am_svc=refused'
    _oracle "${leg}: a mesh service that exists and refuses a shell is red in push A" "${leg}" 1 'am_svc=refused'
    _fresh "${leg}"; _edit facts 's/^am_alias=not_found$/am_alias=refused/' 'am_alias=refused'
    _oracle "${leg}: a tap alias that exists is red in push A" "${leg}" 1 'am_alias=refused'
    _fresh "${leg}"; _edit facts 's/^services_mesh=0$/services_mesh=1/' 'services_mesh=1'
    _oracle "${leg}: a running mesh service is red" "${leg}" 1 "the mesh's service is running"
    _fresh "${leg}"; _edit facts 's/^notification_mesh=0$/notification_mesh=2/' 'notification_mesh=2'
    _oracle "${leg}: the mesh's notification channel is red" "${leg}" 1 'notification channel'
    _fresh "${leg}"; _edit facts 's/^bluetooth_names_haven=0$/bluetooth_names_haven=1/' 'bluetooth_names_haven=1'
    _oracle "${leg}: Haven named by the Bluetooth manager is red" "${leg}" 1 'names Haven'
    _fresh "${leg}"; _edit facts 's/^stored_copy=absent$/stored_copy=present/' 'stored_copy=present'
    _oracle "${leg}: a stored copy is red" "${leg}" 1 'stored copy'
    _fresh "${leg}"; _entry 4021 D BluetoothAdapter 'getState()' >> "${tmp}/c.logcat"
    _oracle "${leg}: a Bluetooth object made in Haven's process is red" "${leg}" 1 'made a Bluetooth object'
    _fresh "${leg}"; _entry 4021 E AndroidRuntime "Process: ${PKG}, PID: 4021" >> "${tmp}/c.logcat"
    _oracle "${leg}: Haven's process dying is red" "${leg}" 1 'process dying'
    _fresh "${leg}"; _edit facts 's/^drive_failed=no$/drive_failed=yes/' 'drive_failed=yes'
    _oracle "${leg}: a drive that failed after the target started is red" "${leg}" 1 'did not complete cleanly'

    # …and each of the host's readings must have been read.
    _fresh "${leg}"; _edit facts 's/^package_dump=ok$/package_dump=unread/' 'package_dump=unread'
    _oracle "${leg}: a package dump that is none is unusable, not a zero" "${leg}" 3 'dumpsys package'
    _fresh "${leg}"; _edit facts 's/^am_fgs=not_found$/am_fgs=unread/' 'am_fgs=unread'
    _oracle "${leg}: an am that said nothing is unusable, not a refusal" "${leg}" 3 'am_fgs=unread'
    _fresh "${leg}"; _drop facts 'am_alias='
    _oracle "${leg}: an am that was never asked is unusable" "${leg}" 3 'am_alias=missing'
    _fresh "${leg}"; _edit facts 's/^services_dump=ok$/services_dump=unread/' 'services_dump=unread'
    _oracle "${leg}: a services dump that is none is unusable" "${leg}" 3 'dumpsys activity services'
    _fresh "${leg}"; _edit facts 's/^notification_dump=ok$/notification_dump=unread/' 'notification_dump=unread'
    _oracle "${leg}: a notification dump that is none is unusable" "${leg}" 3 'dumpsys notification'
    _fresh "${leg}"; _edit facts 's/^bluetooth_dump=ok$/bluetooth_dump=unread/' 'bluetooth_dump=unread'
    _oracle "${leg}: a Bluetooth dump that is none is unusable" "${leg}" 3 'dumpsys bluetooth_manager'
    _fresh "${leg}"; _edit facts 's/^stored_copy=absent$/stored_copy=unread/' 'stored_copy=unread'
    _oracle "${leg}: preferences run-as could not list are unusable" "${leg}" 3 'could not be listed'

    # The controls: a capture that proves nothing is never a pass.
    _fresh "${leg}"; : > "${tmp}/c.logcat"
    _oracle "${leg}: an empty capture is unusable" "${leg}" 3 'never reported'
    _fresh "${leg}"; sed -i -e 's/ 4021  4021 I flutter /  555   555 I flutter /' "${tmp}/c.logcat"
    _oracle "${leg}: markers written by another pid are unusable" "${leg}" 3 'written by another'
    _fresh "${leg}"; _edit facts 's/^pid_host=4021$/pid_host=4999/' 'pid_host=4999'
    _oracle "${leg}: a host that inspected another process is unusable" "${leg}" 3 'was not the process'
    _fresh "${leg}"; _drop facts 'pid_host='
    _oracle "${leg}: a host that found no process is unusable" "${leg}" 3 'was not the process'
    _fresh "${leg}"; _edit logcat "s/${MARK_RELEASED//[/\\[}/${MARK_HOLD_EXPIRED//[/\\[}/" "${MARK_HOLD_EXPIRED}"
    _oracle "${leg}: a hold that ran out is unusable" "${leg}" 3 'hold ran out'
    _fresh "${leg}"; _drop logcat "${MARK_DONE}"
    _oracle "${leg}: a target that never finished is unusable" "${leg}" 3 'never reached'
    _fresh "${leg}"; _drop logcat "I flutter : ${T2}"
    _oracle "${leg}: P2 absent is unusable: the plant call or the capture is dead" "${leg}" 3 'P2: the line planted'
    _fresh "${leg}"; sed -i -e "s/^\(.*\) 4021  4021 I flutter : ${T2}\$/\1  555   555 I flutter : ${T2}/" "${tmp}/c.logcat"
    _oracle "${leg}: P2 under another pid is unusable" "${leg}" 3 'P2: the line planted'
    _fresh "${leg}"; _drop logcat "${MARK_UI}"
    _oracle "${leg}: a target that never reported the tree is unusable" "${leg}" 3 'never reported the tree'
    _fresh "${leg}"; _edit logcat 's/shell=1 /shell=0 /' 'shell=0'
    _oracle "${leg}: no map on screen is unusable, not a zero" "${leg}" 3 'map was not on screen'
    _fresh "${leg}"; _drop logcat "${MARK_CHANNEL}"
    _oracle "${leg}: a target that never reported the channel is unusable" "${leg}" 3 'never reported the channel ('
    _fresh "${leg}"; _drop logcat "${MARK_ANSWER}"
    _oracle "${leg}: a target that never reported its answers is unusable" "${leg}" 3 "channel's answers"
    _fresh "${leg}"; _drop logcat "${MARK_TURN_ON}"
    _oracle "${leg}: a target that never reported its turn-on is unusable" "${leg}" 3 'never reported its turn-on'
    _fresh "${leg}"; _drop logcat "${MARK_AFTER}"
    _oracle "${leg}: a target that never reported the radio afterwards is unusable" "${leg}" 3 'after its turn-on'
  }
  local leg
  for leg in s0 probe s2; do
    (
      tmp="${tmp}/suite-${leg}"
      mkdir -p "${tmp}"
      checks=0
      fails=0
      _leg_suite "${leg}"
      echo "__suite ${checks} ${fails}"
    ) > "${tmp}/suite-${leg}.out" 2>&1 &
  done

  # --- per leg --------------------------------------------------------------
  _fresh s0; _edit logcat 's/flag=off/flag=on/' 'flag=on'
  _oracle "S0 over a flag-on build is a broken lane" s0 2 'wrong APK'
  _fresh probe; _edit logcat 's/flag=on/flag=off/' 'flag=off'
  _oracle "the probe over a flag-off build is a broken lane" probe 2 'wrong APK'
  _fresh s0; _edit logcat 's/missing=11 answered=0/missing=10 answered=1/' 'answered=1'
  _oracle "S0: one answered method is red" s0 1 'has a native end'
  _fresh s0; _edit logcat 's/asked=11 missing=11/asked=10 missing=10/' 'asked=10'
  _oracle "S0: fewer than eleven methods asked is red, not a pass on ten" s0 1 'has a native end'
  _fresh s0; _edit logcat 's/supported=none permission=none/supported=false permission=none/' 'supported=false'
  _oracle "S0: an answered question is red" s0 1 "answered a question of the mesh's"
  _fresh s0; _edit logcat 's/shell=1 button=0/shell=1 button=1/' 'button=1'
  _oracle "S0: a mesh button is red" s0 1 'must offer nothing'
  _fresh s0; _edit facts 's/^package_mesh_permissions=0$/package_mesh_permissions=3/' 'package_mesh_permissions=3'
  _oracle "S0: a Bluetooth permission is red" s0 1 'requests a Bluetooth'
  _fresh s0; _edit logcat 's/AFTER state=none wanted=none/AFTER state=stopped wanted=false/' 'AFTER state=stopped'
  _oracle "S0: a status answered after the turn-on is red" s0 1 "answers the radio's status"
  _fresh s0; _drop logcat "D BluetoothGatt"
  _oracle "S0: P1 absent beside P2 is red: a lever, or a platform that drops it" s0 1 'P1: a DEBUG line'
  _fresh s2; _drop logcat "D BluetoothGatt"
  _oracle "S2: P1 absent beside P2 is red" s2 1 'P1: a DEBUG line'
  _fresh s0; sed -i -e "s/^\(.*\) 4021  4021 D BluetoothGatt: ${T1}\$/\1  555   555 D BluetoothGatt: ${T1}/" "${tmp}/c.logcat"
  _oracle "S0: P1 under another pid is unusable" s0 3 'not the target'

  _fresh s2; _edit logcat 's/supported=false permission/supported=true permission/' 'supported=true permission'
  _oracle "S2: supported below Android 11 is red" s2 1 'must answer false there'
  _fresh s2; _edit logcat 's/shell=1 button=0/shell=1 button=1/' 'button=1'
  _oracle "S2: a mesh button below Android 11 is red" s2 1 'must offer nothing'

  for leg in probe s2; do
    _fresh "${leg}"; _edit logcat 's/missing=3 answered=4 failed=0 lever_missing=3/missing=2 answered=5 failed=0 lever_missing=2/' 'lever_missing=2'
    _oracle "${leg}: a method behind the lever that answers is red" "${leg}" 1 'behind the log lever is answered'
    _fresh "${leg}"; _edit logcat 's/missing=3 answered=4 failed=0/missing=3 answered=3 failed=1/' 'failed=1'
    _oracle "${leg}: a method push A answers that fails is red" "${leg}" 1 'does not answer what push A answers'
    _fresh "${leg}"; _edit logcat 's/\(ANSWER .*\)state=stopped wanted=false/\1state=running wanted=true/' 'state=running'
    _oracle "${leg}: a radio that reads running before anything is asked is red" "${leg}" 1 'before anything was asked'
    _fresh "${leg}"; _edit logcat 's/AFTER state=stopped wanted=false/AFTER state=stopped wanted=true/' 'wanted=true'
    _oracle "${leg}: a wanted flag left by the turn-on is red" "${leg}" 1 'something was started or stored'
    _fresh "${leg}"; _edit logcat 's/ended=failed ms=412/ended=failed ms=121000/' 'ms=121000'
    _oracle "${leg}: a turn-on that failed at the dialog's bound is unusable" "${leg}" 3 'ms to fail'
    _fresh "${leg}"; _edit logcat 's/ended=failed ms=412/ended=skipped ms=0/' 'ended=skipped'
    _oracle "${leg}: a turn-on not asked is unusable" "${leg}" 3 'was not asked'
  done
  _fresh probe; _edit logcat 's/shell=1 button=1/shell=1 button=0/' 'button=0'
  _oracle "the probe: no button on a phone that can run the mesh is red" probe 1 'it must draw one'
  _fresh probe; _edit logcat 's/supported=true permission/supported=false permission/' 'supported=false permission'
  _oracle "the probe: supported false beside an LE feature is red" probe 1 'the two must agree'

  # --- folding --------------------------------------------------------------
  _fresh s0; _edit logcat 's/TURN_ON ended=failed/TURN_ON ended=on/' 'ended=on'
  _edit facts 's/^stored_copy=absent$/stored_copy=unread/' 'stored_copy=unread'
  _oracle "a red beside an unusable is red" s0 1 'a turn-on ended'
  rc=0; worst_rc 3 1 || rc=$?
  _case "the legs fold 1 over 3" 1 "${rc}"
  rc=0; worst_rc 0 3 || rc=$?
  _case "…and 3 over 0" 3 "${rc}"

  # --- answers are a closed vocabulary --------------------------------------
  MESH_ANSWERS=()
  mesh_answer k yes; mesh_answer k '22:22:AB:CD:EF:01'; mesh_answer k 412 n; mesh_answer k '4x' n; mesh_answer k ''
  _eq_case "an answer is a known word or a number, and anything else is other" \
    "k=yes k=other k=412 k=other k=other" "${MESH_ANSWERS[*]}"

  # --- the target and this runner name the same things ----------------------
  local target="${SCRIPT_DIR}/../../../haven/integration_test/mesh_lever_test.dart" name value
  while read -r name value; do
    _eq_case "the target's ${name} is this runner's" 1 \
      "$(grep -cF -- "const String ${name} = '${value}';" "${target}" || true)"
  done <<EOF
kPhaseMarker ${MARK_PHASE}
kUiMarker ${MARK_UI}
kChannelMarker ${MARK_CHANNEL}
kAnswerMarker ${MARK_ANSWER}
kPlantMarker ${MARK_PLANT}
kTurnOnMarker ${MARK_TURN_ON}
kAfterMarker ${MARK_AFTER}
kReadyMarker ${MARK_READY}
kReleasedMarker ${MARK_RELEASED}
kHoldExpiredMarker ${MARK_HOLD_EXPIRED}
kDoneMarker ${MARK_DONE}
EOF
  _eq_case "the target's hold is this runner's bound" 1 \
    "$(grep -cF -- "const Duration _holdBound = Duration(seconds: ${HOLD_BOUND_SECS});" "${target}" || true)"
  _eq_case "the target waits on the file this runner makes" 1 \
    "$(grep -cF -- "'/data/data/${PKG}/${RELEASE_FILE}';" "${target}" || true)"
  _eq_case "the target plants under the tag this runner reads" 1 \
    "$(grep -cF -- "_plantLine(_priorityDebug, 'BluetoothGatt', p1)" "${target}" || true)"

  # --- log-privacy gate wiring ----------------------------------------------
  # Source pins, in the shape of run-b5-permission-revocation.sh's: the gate
  # is what stands between a capture and the job log, so its position is read
  # from this file's own lines. Continuations joined, comments dropped.
  local self="${BASH_SOURCE[0]}" joined scope gate_at cat_at
  joined="$(sed -e ':a' -e '/\\$/N; s/\\\n//; ta' "${self}" | grep -vE '^[[:space:]]*#')"
  scope="$(sed -n '/^report_leg() {/,/^}/p' <<<"${joined}")"
  gate_at="$(grep -nE '^  logscan_gate host /tmp/haven-soak/needles' <<<"${scope}" \
    | cut -d: -f1 | head -n 1 || true)"
  cat_at="$(grep -nE '^[[:space:]]*cat "\$\{drive_log\}"' <<<"${scope}" | cut -d: -f1 | head -n 1 || true)"
  rc=0
  [[ -n "${gate_at}" && -n "${cat_at}" ]] && (( gate_at < cat_at )) || rc=1
  _case "the drive log is echoed only after the log-privacy gate" 0 "${rc}"
  _eq_case "…and exactly once in the whole runner" 1 \
    "$(grep -cE '^[[:space:]]*(cat|tail|head|less|more)[[:space:]].*(drive_log|LOG_DIR|RAW_DIR)' <<<"${joined}" || true)"
  local gate_lit='logscan_gate host /tmp/haven-soak/needles "${SEAL_EXTRA[@]}" --     --sink "logcat=${LOG_DIR}/logcat.${leg}.log,${LOG_DIR}/logcat-events.${leg}.log"     --sink "drive=${drive_log}" --report "${LOGSCAN_REPORTS}/gate-${leg}.ndjson" || gate_rc=$?'
  _eq_case "the gate names both device captures and the drive log" 1 \
    "$(awk -v lit="${gate_lit}" 'index($0, lit) == 3 { n++ } END { print n + 0 }' <<<"${scope}")"
  _eq_case "what the gate is handed is the redacted copy, never the raw capture" 0 \
    "$(grep -cE 'logscan_gate(_dir)? .*RAW_DIR' <<<"${joined}" || true)"
  _eq_case "the raw captures are written under RAW_DIR alone" 0 \
    "$(grep -cE 'adb .*(logcat -v|dumpsys) .*> *"\$\{LOG_DIR\}' <<<"${joined}" || true)"
  local exit_scope
  exit_scope="$(sed -n '/^cleanup() {/,/^}/p' <<<"${joined}")"
  _eq_case "the whole evidence directory is gated at exit" 1 \
    "$(grep -cE '^  logscan_gate_dir host /tmp/haven-soak/needles "\$\{LOG_DIR\}"' <<<"${exit_scope}" || true)"
  local extra_lit='readonly -a SEAL_EXTRA=(--floor drive=7 --floor relay=7)'
  _eq_case "the seal extras carry the lane's two line floors and nothing else" 1 \
    "$(awk -v lit="${extra_lit}" 'index($0, lit) == 1 { n++ } END { print n + 0 }' "${self}")"

  # The directory gate over a leg's files, through the SHARED fake scanner:
  # the two device captures type as `logcat`, the transcript as `drive`, the
  # verdict and a skeleton as `diag`.
  local fake_dir="${tmp}/fake" fake_bin="${LOGSCAN_FAKE_BIN}" dir="${tmp}/logs"
  mkdir -p "${fake_dir}" "${dir}"
  _case "the shared fake scanner is present and executable" 0 "$([[ -x "${fake_bin}" ]]; echo $?)"
  _fresh probe
  mesh_redact '' '' < "${tmp}/c.logcat" > "${dir}/logcat.probe.log"
  mesh_redact '' '' < "${tmp}/c.events" > "${dir}/logcat-events.probe.log"
  printf '00:03 +1: All tests passed!\n' > "${dir}/flutter-drive.probe.log"
  printf 'probe.bt_on=yes\n' > "${dir}/verdict.s0-probe.log"
  mesh_skeleton '' '' < "${tmp}/skeleton.in" > "${dir}/dump-bluetooth.probe.skel.log"
  FAKE_SCAN_ARGV="${fake_dir}/scan-argv" GITHUB_RUN_ID= GITHUB_RUN_ATTEMPT= WIRE_UPSTREAM= RELAY_URL= \
    HAVEN_LOGSCAN=true HAVEN_LOGSCAN_BIN="${fake_bin}" \
    logscan_gate_dir host "${fake_dir}/needles" "${dir}" "${fake_dir}/r.ndjson" >/dev/null 2>&1 || true
  _eq_case "a leg's evidence directory gates as two device captures, a transcript and two diag files" \
    "$(printf '%s\n' scan --manifest "${fake_dir}/needles/local-local.needles.json" \
         --sink "logcat=${dir}/logcat-events.probe.log,${dir}/logcat.probe.log" \
         --sink "drive=${dir}/flutter-drive.probe.log" \
         --sink "diag=${dir}/dump-bluetooth.probe.skel.log,${dir}/verdict.s0-probe.log" \
         --report "${fake_dir}/r.ndjson")" \
    "$(cat "${fake_dir}/scan-argv" 2>/dev/null || true)"
  _eq_case "the published copy of a capture holds no address" 0 \
    "$(grep -c 'AA:BB:CC:DD:EE:01' "${dir}/logcat.probe.log" || true)"

  # The three suites started above.
  local suite_checks suite_fails
  wait
  for leg in s0 probe s2; do
    grep -v '^__suite ' "${tmp}/suite-${leg}.out" || true
    read -r _ suite_checks suite_fails < <(grep '^__suite ' "${tmp}/suite-${leg}.out" || echo "__suite 0 1")
    checks=$(( checks + suite_checks ))
    if (( suite_fails != 0 || suite_checks == 0 )); then
      echo "  FAIL the ${leg} suite did not finish clean (${suite_checks} checks)" >&2
      fails=1
    fi
  done

  if (( fails )); then
    echo "run-mesh-lever.sh --self-test: FAILED" >&2
    return 1
  fi
  echo "run-mesh-lever.sh --self-test: all ${checks} checks passed"
}

if [[ "${1:-}" == "--self-test" ]]; then
  run_self_test
  exit $?
fi

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------
usage() {
  echo "usage: run-mesh-lever.sh <s0|probe|s2|adapter>... | --self-test" >&2
  exit 2
}
(( $# > 0 )) || usage
USES_RELAY=0
for leg in "$@"; do
  case "${leg}" in
    s0|probe|s2) USES_RELAY=1 ;;
    adapter) ;;
    *) usage ;;
  esac
done
readonly USES_RELAY
# The run's name, for its verdict file: the legs, joined.
RUN_NAME="$(IFS=-; echo "$*")"
readonly RUN_NAME

readonly DEVICE="emulator-5554"
readonly DRIVER_FILE="test_driver/integration_test.dart"
readonly TARGET="integration_test/mesh_lever_test.dart"
readonly APK_OFF="/tmp/integration-apks/mesh_lever_test.apk"
readonly APK_ON="/tmp/integration-apks/mesh_lever_test.mesh.apk"
readonly LOG_DIR="/tmp/mesh-logs"
# The raw captures: addresses and all. Read by the oracle, never uploaded,
# never handed to the gate, never echoed.
readonly RAW_DIR="/tmp/mesh-raw"
readonly LOGSCAN_REPORTS="/tmp/mesh-logscan"

# One drive's bound. The target bounds itself at eight minutes; this sits
# above it so the target's own, attributable timeout is the one that fires.
readonly DRIVE_TIMEOUT="10m"
readonly DRIVE_KILL_AFTER_SECS=30
readonly MARKER_POLL_SECS=2
# The wait for the target's cue is released by the drive's own death, so this
# only has to exceed the drive's bound.
readonly READY_TIMEOUT_SECS=660
# How long the adapter is given to come on once asked.
readonly BT_ON_TIMEOUT_SECS=60
readonly BT_POLL_SECS=2
# How long the device log is given to deliver the target's last line once the
# drive has ended.
readonly SETTLE_TIMEOUT_SECS=10
readonly SETTLE_POLL_SECS=1

readonly REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
readonly HAVEN_DIR="${REPO_ROOT}/haven"
readonly START_STRFRY="${SCRIPT_DIR}/start-strfry.sh"
readonly STOP_STRFRY="${SCRIPT_DIR}/stop-strfry.sh"
readonly STRFRY_CONTAINER="${STRFRY_CONTAINER:-strfry}"

# This lane's seal claim: its two line floors, as run-b5-permission-revocation.sh
# derives them — what `flutter drive` prints on the host for one launch, and
# the startup block every live strfry prints. No value is declared: the lane
# mints none, and the adapter's name and address are redacted out of what is
# scanned rather than searched for, because a declared needle is searched on
# the Bluetooth process's lines too, where they belong (§O-4).
readonly -a SEAL_EXTRA=(--floor drive=7 --floor relay=7)

LOGCAT_PID=""
EVENTS_PID=""
DRIVE_PID=""
LOGSCAN_GATE_RC=0
# The leg whose captures are in RAW_DIR and not yet published.
OPEN_LEG=""
# This adapter's address and name, for mesh_redact alone. Never printed.
BT_ADDR=""
BT_LABEL=""
VERDICT_RC=0
VERDICT_LINES=()
readonly VERDICT_FILE="${LOG_DIR}/verdict.${RUN_NAME}.log"

mkdir -p "${LOG_DIR}" "${RAW_DIR}" "${LOGSCAN_REPORTS}"

# stop_captures — ends the two device-log readers.
stop_captures() {
  local reader
  for reader in "${LOGCAT_PID}" "${EVENTS_PID}"; do
    if [[ -n "${reader}" ]] && kill -0 "${reader}" 2>/dev/null; then
      kill "${reader}" 2>/dev/null || true
    fi
  done
  LOGCAT_PID=""
  EVENTS_PID=""
}

# publish_leg <leg> — the leg's captures into the uploaded directory, with
# every Bluetooth address and the adapter's name out of them.
publish_leg() {
  local leg="$1" pair
  for pair in "logcat:logcat" "events:logcat-events" "drive:flutter-drive"; do
    if [[ -s "${RAW_DIR}/${pair%%:*}.${leg}.raw" ]]; then
      mesh_redact "${BT_LABEL}" "${BT_ADDR}" < "${RAW_DIR}/${pair%%:*}.${leg}.raw" \
        > "${LOG_DIR}/${pair##*:}.${leg}.log" || true
    fi
  done
  OPEN_LEG=""
}

# write_verdict — the answers, one `<leg>.<key>=<value>` a line.
write_verdict() {
  (( ${#VERDICT_LINES[@]} > 0 )) || return 0
  printf '%s\n' "${VERDICT_LINES[@]}" > "${VERDICT_FILE}"
}

# ---------------------------------------------------------------------------
# Cleanup (EXIT trap): stop the helpers, publish what a leg left unpublished,
# write the verdict file, run the MANDATORY log-privacy gate over everything
# that will be uploaded, tear the relay down. Escalates on a leak; never masks
# a verdict. The containment is run-b5-permission-revocation.sh's.
# ---------------------------------------------------------------------------
cleanup() {
  local rc=$?
  local scan_rc=0
  trap - EXIT
  if [[ -n "${DRIVE_PID}" ]] && kill -0 "${DRIVE_PID}" 2>/dev/null; then
    kill "${DRIVE_PID}" 2>/dev/null || true
  fi
  stop_captures
  if [[ -n "${OPEN_LEG}" ]]; then
    publish_leg "${OPEN_LEG}"
  fi
  if (( USES_RELAY )); then
    docker logs "${STRFRY_CONTAINER}" > "${LOG_DIR}/strfry.final.log" 2>&1 || true
  fi
  write_verdict
  echo "== Log-privacy scan over ${LOG_DIR} (Security Rules 6 and 15) =="
  logscan_gate_dir host /tmp/haven-soak/needles "${LOG_DIR}" "${LOGSCAN_REPORTS}/exit-${RUN_NAME}.ndjson" "${SEAL_EXTRA[@]}" \
    || scan_rc=$?
  if (( scan_rc == 1 || LOGSCAN_GATE_RC == 1 )); then
    {
      echo "Logs withheld: the log-privacy gate tripped (Security Rules 6 and 15)."
      echo "See the LEAK line(s) in the step log for file/label/line numbers."
    } > "${LOG_DIR}/LEAK_DETECTED.txt"
    echo "ERROR: log-privacy gate tripped on the mesh lane's logs — logs deleted, not uploaded." >&2
    rc=1
  elif (( scan_rc != 0 || LOGSCAN_GATE_RC != 0 )); then
    if (( rc == 0 )); then
      echo "ERROR: the log-privacy gate could not certify the mesh lane's logs" \
           "(rc=${scan_rc}, post-drive rc=${LOGSCAN_GATE_RC}) — see the lines above." \
           "The lane otherwise passed, so an expected capture is missing or too" \
           "short and the privacy scan proved nothing. Logs kept for triage." >&2
      worst_rc "${scan_rc}" "${LOGSCAN_GATE_RC}" || rc=$?
    else
      echo "NOTE: the log-privacy gate could not certify every log" \
           "(rc=${scan_rc}, post-drive rc=${LOGSCAN_GATE_RC}); the lane had already" \
           "ended ${rc}, which is why a capture is short or missing. Preserving" \
           "exit code ${rc}. Logs kept for triage." >&2
    fi
  fi
  if (( USES_RELAY )); then
    bash "${STOP_STRFRY}" >/dev/null 2>&1 || true
  fi
  exit "${rc}"
}
trap cleanup EXIT

# die <rc> <message…> — a failure of the lane's own plumbing, before or
# outside any oracle.
die() {
  local rc="$1"
  shift
  echo "MESH-LANE-FAIL (rc ${rc}): $*" >&2
  exit "${rc}"
}

# record <key> <value> — one fact of the leg in progress.
FACTS=""
record() { printf '%s=%s\n' "$1" "$2" >> "${FACTS}"; }

# wait_for_marker <marker> <timeout-secs> — 0 when the marker is in the leg's
# device log, 1 on timeout or on the drive dying first.
wait_for_marker() {
  local marker="$1" timeout_s="$2" waited=0
  while (( waited < timeout_s )); do
    if mesh_has "${RAW_DIR}/logcat.${OPEN_LEG}.raw" "${marker}"; then
      echo "  observed '${marker}' after ${waited}s"
      return 0
    fi
    if [[ -n "${DRIVE_PID}" ]] && ! kill -0 "${DRIVE_PID}" 2>/dev/null; then
      echo "  the drive exited before '${marker}' appeared (after ${waited}s)" >&2
      return 1
    fi
    sleep "${MARKER_POLL_SECS}"
    waited=$(( waited + MARKER_POLL_SECS ))
  done
  echo "  timed out after ${timeout_s}s waiting for '${marker}'" >&2
  return 1
}

# read_adapter_identity — this adapter's address and name into the two
# variables mesh_redact takes. Read, never shown.
read_adapter_identity() {
  BT_ADDR="$(adb -s "${DEVICE}" shell settings get secure bluetooth_address 2>/dev/null | tr -d '\r' | head -n 1 || true)"
  BT_LABEL="$(adb -s "${DEVICE}" shell settings get secure bluetooth_name 2>/dev/null | tr -d '\r' | head -n 1 || true)"
}

# enable_bluetooth — asks the adapter on and reads its state back until it
# is, or the bound passes. Records bt_on, bt_state and how long it took.
enable_bluetooth() {
  local word=unread waited=0
  adb -s "${DEVICE}" shell cmd bluetooth_manager enable >/dev/null 2>&1 || true
  while (( waited < BT_ON_TIMEOUT_SECS )); do
    word="$(adb -s "${DEVICE}" shell dumpsys bluetooth_manager 2>/dev/null | mesh_bt_state_word || true)"
    if [[ "${word}" == ON || "${word}" == unread ]]; then
      break
    fi
    sleep "${BT_POLL_SECS}"
    waited=$(( waited + BT_POLL_SECS ))
  done
  record bt_state "${word}"
  record bt_on_after_s "${waited}"
  case "${word}" in
    ON) record bt_on yes ;;
    unread) record bt_on unread ;;
    *) record bt_on no ;;
  esac
  echo "  adapter asked on: reads $(mesh_fact "${FACTS}" bt_on) after ${waited}s"
}

# keep_skeleton <leg> <fact> <name> <raw-dump> — a dump's skeleton into the
# uploaded directory; `kept` only for one that has lines.
keep_skeleton() {
  local leg="$1" fact="$2" name="$3" raw="$4" out
  out="${LOG_DIR}/dump-${name}.${leg}.skel.log"
  if [[ -s "${raw}" ]]; then
    {
      echo "# Skeleton of a platform dump: its lines' shape, every value masked"
      echo "# (run-mesh-lever.sh, mesh_skeleton). The dump itself is not kept."
      mesh_skeleton "${BT_LABEL}" "${BT_ADDR}" < "${raw}"
    } > "${out}" || true
    record "${fact}" kept
  else
    record "${fact}" unread
  fi
}

# inspect_leg <leg> — the host's reading of the device while the target is
# alive. Every answer is a fixed word or a count; every dump stays in RAW_DIR.
inspect_leg() {
  local leg="$1" state count more buffer value
  record pid_host "$(adb -s "${DEVICE}" shell pidof "${PKG}" 2>/dev/null | tr -d '\r' | awk 'NR == 1 { print $1 }' || true)"

  adb -s "${DEVICE}" shell dumpsys package "${PKG}" > "${RAW_DIR}/package.${leg}.dump" 2>&1 || true
  read -r state count more < <(mesh_package_counts < "${RAW_DIR}/package.${leg}.dump") || true
  record package_dump "${state:-unread}"
  record package_mesh_components "${count:-0}"
  record package_mesh_permissions "${more:-0}"

  # Asked to start what push B will declare. Each answer is the platform's.
  record am_fgs "$(adb -s "${DEVICE}" shell am start-foreground-service -n "${MESH_SERVICE}" 2>&1 | mesh_am_word || true)"
  record am_svc "$(adb -s "${DEVICE}" shell am startservice -n "${MESH_SERVICE}" 2>&1 | mesh_am_word || true)"
  record am_alias "$(adb -s "${DEVICE}" shell am start -n "${MESH_ALIAS}" 2>&1 | mesh_am_word || true)"

  adb -s "${DEVICE}" shell dumpsys activity services "${PKG}" > "${RAW_DIR}/services.${leg}.dump" 2>&1 || true
  read -r state count < <(mesh_dump_count 'ACTIVITY MANAGER SERVICES' '.mesh.MeshService' < "${RAW_DIR}/services.${leg}.dump") || true
  record services_dump "${state:-unread}"
  record services_mesh "${count:-0}"

  adb -s "${DEVICE}" shell dumpsys notification > "${RAW_DIR}/notification.${leg}.dump" 2>&1 || true
  read -r state count < <(mesh_dump_count 'Current Notification Manager state' "${MESH_CHANNEL_STEM}" < "${RAW_DIR}/notification.${leg}.dump") || true
  record notification_dump "${state:-unread}"
  record notification_mesh "${count:-0}"

  adb -s "${DEVICE}" shell dumpsys bluetooth_manager > "${RAW_DIR}/bluetooth.${leg}.dump" 2>&1 || true
  read -r state count < <(mesh_bluetooth_counts < "${RAW_DIR}/bluetooth.${leg}.dump") || true
  record bluetooth_dump "${state:-unread}"
  record bluetooth_names_haven "${count:-0}"

  record stored_copy "$(adb -s "${DEVICE}" shell "run-as ${PKG} sh -c 'ls shared_prefs 2>&1; echo lane-ls-end'" 2>&1 | mesh_stored_copy_word || true)"

  if [[ "${leg}" == probe ]]; then
    # Whether a shell can set the property the lever's lane will set. After
    # the plants, so that P1 was written with no property; cleared again.
    adb -s "${DEVICE}" shell setprop log.tag.BluetoothGatt VERBOSE >/dev/null 2>&1 || true
    value="$(adb -s "${DEVICE}" shell getprop log.tag.BluetoothGatt 2>/dev/null | tr -d '\r' | head -n 1 || true)"
    if [[ "${value}" == VERBOSE ]]; then record setprop_log_tag yes; else record setprop_log_tag no; fi
    adb -s "${DEVICE}" shell setprop log.tag.BluetoothGatt '""' >/dev/null 2>&1 || true

    # Bluetooth is on by now if it comes on at all, so the settings hold what
    # they will hold. Read again: the redaction below uses them.
    read_adapter_identity
    record adapter_address_readable "$(mesh_settings_word <<<"${BT_ADDR}")"
    record adapter_address_shape "$(mesh_addr_shape "${BT_ADDR}")"
    record adapter_label_readable "$(mesh_settings_word <<<"${BT_LABEL}")"

    for buffer in "${PROBED_BUFFERS[@]}"; do
      record "buffer_${buffer}_kib" "$(adb -s "${DEVICE}" shell logcat -g -b "${buffer}" 2>&1 | mesh_logcat_g_kib || true)"
    done

    # The three dumps the lever's parsers will read, as skeletons. The
    # services dump is the whole device's here, not Haven's alone: a record's
    # shape is what is wanted, and Haven has none to show.
    adb -s "${DEVICE}" shell dumpsys activity services > "${RAW_DIR}/services-all.${leg}.dump" 2>&1 || true
    keep_skeleton "${leg}" dump_services activity-services "${RAW_DIR}/services-all.${leg}.dump"
    keep_skeleton "${leg}" dump_notification notification "${RAW_DIR}/notification.${leg}.dump"
    keep_skeleton "${leg}" dump_bluetooth bluetooth-manager "${RAW_DIR}/bluetooth.${leg}.dump"
  fi
}

# report_leg <leg> <drive-rc> — publishes the leg's captures, gates them, and
# only then echoes the drive log. Records whether the drive failed.
report_leg() {
  local leg="$1" drc="$2" gate_rc=0
  local drive_log="${LOG_DIR}/flutter-drive.${leg}.log"
  publish_leg "${leg}"
  logscan_gate host /tmp/haven-soak/needles "${SEAL_EXTRA[@]}" -- \
    --sink "logcat=${LOG_DIR}/logcat.${leg}.log,${LOG_DIR}/logcat-events.${leg}.log" \
    --sink "drive=${drive_log}" --report "${LOGSCAN_REPORTS}/gate-${leg}.ndjson" || gate_rc=$?
  if (( gate_rc == 1 || LOGSCAN_GATE_RC == 0 )); then
    LOGSCAN_GATE_RC="${gate_rc}"
  fi
  if (( gate_rc == 0 )); then
    cat "${drive_log}" || true
  else
    echo "${leg} drive log withheld from the step log — log-privacy gate rc ${gate_rc}." >&2
  fi
  if (( drc != 0 )) || drive_log_reports_test_failure "${RAW_DIR}/drive.${leg}.raw"; then
    record drive_failed yes
    echo "  the ${leg} drive did not complete cleanly (flutter drive rc ${drc})." >&2
  else
    record drive_failed no
  fi
}

# fold_leg <leg> <rc> — the leg's answers into the verdict file and its
# verdict into the run's.
LEG_STARTED=0
fold_leg() {
  local leg="$1" rc="$2" line
  mesh_answer "${leg}.wall_s" "$(( $(date +%s) - LEG_STARTED ))" n
  mesh_report "${leg}" "${rc}"
  for line in "${MESH_ANSWERS[@]}"; do VERDICT_LINES+=("${line}"); done
  worst_rc "${VERDICT_RC}" "${rc}" || VERDICT_RC=$?
}

# drive_leg <leg> — one drive of the target, inspected while it holds, judged
# over its complete captures.
drive_leg() {
  local leg="$1" apk="${APK_ON}" drc=0 oracle_rc=0 perm settled=0
  if [[ "${leg}" == s0 ]]; then apk="${APK_OFF}"; fi
  echo "== ${leg}: installing ${apk} =="
  [[ -f "${apk}" ]] || die 2 "APK not found: ${apk} (was the build step skipped?)"
  install_fresh "${DEVICE}" "${apk}" \
    || die 3 "the fresh install of ${apk} did not complete (see the ERROR above)."

  if [[ "${leg}" == probe ]]; then
    # The three a turn-on asks for, and the notice's: granted before the first
    # frame so that the turn-on meets no dialog. Read back by the target, which
    # asks for nothing where the grant did not take.
    for perm in BLUETOOTH_SCAN BLUETOOTH_ADVERTISE BLUETOOTH_CONNECT POST_NOTIFICATIONS; do
      adb -s "${DEVICE}" shell pm grant "${PKG}" "android.permission.${perm}" >/dev/null 2>&1 || true
    done
  fi
  read_adapter_identity

  OPEN_LEG="${leg}"
  adb -s "${DEVICE}" logcat -b all -c >/dev/null 2>&1 || true
  adb -s "${DEVICE}" logcat -v threadtime > "${RAW_DIR}/logcat.${leg}.raw" 2>&1 &
  LOGCAT_PID=$!
  adb -s "${DEVICE}" logcat -b events -v threadtime > "${RAW_DIR}/events.${leg}.raw" 2>&1 &
  EVENTS_PID=$!

  echo "== ${leg}: driving =="
  : > "${RAW_DIR}/drive.${leg}.raw"
  (
    cd "${HAVEN_DIR}" && timeout --kill-after="${DRIVE_KILL_AFTER_SECS}s" "${DRIVE_TIMEOUT}" \
      flutter drive \
        --no-pub \
        --device-id "${DEVICE}" \
        --use-application-binary "${apk}" \
        --driver "${DRIVER_FILE}" \
        --target "${TARGET}"
  ) > "${RAW_DIR}/drive.${leg}.raw" 2>&1 &
  DRIVE_PID=$!

  if wait_for_marker "${MARK_READY}" "${READY_TIMEOUT_SECS}"; then
    echo "== ${leg}: inspecting the device while the target holds =="
    inspect_leg "${leg}"
    adb -s "${DEVICE}" shell "run-as ${PKG} touch ${RELEASE_FILE}" >/dev/null 2>&1 \
      || echo "  WARN: the release file could not be made; the target will run out its hold." >&2
  fi
  wait "${DRIVE_PID}" || drc=$?
  DRIVE_PID=""

  # The target's last line can still be on its way out of the device.
  while (( settled < SETTLE_TIMEOUT_SECS )); do
    if mesh_has "${RAW_DIR}/logcat.${leg}.raw" "${MARK_DONE}"; then
      break
    fi
    sleep "${SETTLE_POLL_SECS}"
    settled=$(( settled + SETTLE_POLL_SECS ))
  done
  stop_captures

  report_leg "${leg}" "${drc}"

  echo "== ${leg}: the oracle =="
  mesh_run_oracle "${leg}" "${RAW_DIR}/logcat.${leg}.raw" "${RAW_DIR}/events.${leg}.raw" "${FACTS}" || oracle_rc=$?
  fold_leg "${leg}" "${oracle_rc}"
}

# adapter_leg — what is left of the adapter's measurement once it has been
# asked on: its dump's skeleton, and the answers. No app, no device log.
adapter_leg() {
  local key rc=0
  read_adapter_identity
  adb -s "${DEVICE}" shell dumpsys bluetooth_manager > "${RAW_DIR}/bluetooth.adapter.dump" 2>&1 || true
  keep_skeleton adapter dump_bluetooth bluetooth-manager "${RAW_DIR}/bluetooth.adapter.dump"
  MESH_RED=(); MESH_UNUSABLE=(); MESH_BROKEN=(); MESH_ANSWERS=()
  for key in boot le_feature bt_on bt_state dump_bluetooth; do
    mesh_answer "adapter.${key}" "$(mesh_fact "${FACTS}" "${key}")"
  done
  mesh_answer adapter.bt_on_after_s "$(mesh_fact "${FACTS}" bt_on_after_s)" n
  case "$(mesh_fact "${FACTS}" bt_on)" in
    yes|no) ;;
    *) mesh_unusable "the adapter's state could not be read after this boot." ;;
  esac
  mesh_verdict_rc || rc=$?
  fold_leg adapter "${rc}"
}

# run_leg <leg> — the adapter is measured before anything is installed, in
# the two legs that measure it: the probe (a snapshot boot, the lanes' own)
# and the adapter leg (whatever boot its step asked for; cold, today).
run_leg() {
  local leg="$1"
  LEG_STARTED="$(date +%s)"
  FACTS="${RAW_DIR}/facts.${leg}"
  : > "${FACTS}"
  if [[ "${leg}" == probe || "${leg}" == adapter ]]; then
    if [[ "${leg}" == probe ]]; then record boot snapshot; else record boot cold; fi
    record le_feature "$(adb -s "${DEVICE}" shell pm list features 2>/dev/null | mesh_feature_word android.hardware.bluetooth_le || true)"
    enable_bluetooth
  fi
  if [[ "${leg}" == adapter ]]; then
    adapter_leg
  else
    drive_leg "${leg}"
  fi
}

if (( USES_RELAY )); then
  echo "Starting hermetic strfry..."
  bash "${START_STRFRY}"
fi
adb -s "${DEVICE}" wait-for-device

for leg in "$@"; do
  run_leg "${leg}"
done

case "${VERDICT_RC}" in
  0) echo "MESH LANE PASS (${RUN_NAME}) — every promise of push A held and every measurement was taken." ;;
  1) echo "MESH LANE RED (${RUN_NAME}) — a promise of push A is broken; see the RED line(s) above." >&2 ;;
  2) echo "MESH LANE BROKEN (${RUN_NAME}) — the lane drove the wrong thing; see the BROKEN line(s) above." >&2 ;;
  *) echo "MESH LANE UNUSABLE (${RUN_NAME}) — the platform or the capture would not answer; nothing was proved. See the UNUSABLE line(s) above." >&2 ;;
esac
exit "${VERDICT_RC}"
