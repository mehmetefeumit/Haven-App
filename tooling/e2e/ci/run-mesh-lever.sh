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
#   S2     API 29, a build WITH the flag      Haven installs and starts on
#                                             Android 10 with the flag-on
#                                             library, and offers nothing of
#                                             the mesh. Whether that shows
#                                             the Android 11 gate depends on
#                                             the image — see "A stated
#                                             limit" below
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
# Lines are planted from Haven's own process through liblog. Three carry a
# verdict:
#
#   P1  a DEBUG line under `BluetoothGatt`     a platform Bluetooth tag, the
#                                              kind the lever will have to
#                                              keep out of the log
#   P2  a line under `flutter`, same call      the control: the plant call
#                                              writes and the capture is live
#   P3  a string event (`__android_log_bswrite`)  the events buffer, which no
#                                              lever reaches
#
# and four more are answers alone, at the priorities and tags the lever's own
# lane will plant at (MORE_PLANTS): a line missing there later must be the
# lever's doing, so whether each is written with no lever is asked now.
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
# # A stated limit
#
# `supported` is false below Android 11 AND on a phone with no Bluetooth LE,
# so on an API 29 image that declares no LE feature S2's `supported=false`
# would be answered with the Android 11 gate deleted: the gate is not
# exercised there. A leg that held everything it could judge and could NOT
# judge something its name promises, for a reason that is the image's, is rc 0
# with the verdict word `limited`, an answer that says what (`s2.
# api_gate_exercised=no`), a `LIMIT` line and a notice on the run — never the
# word `pass`. Red or unusable on every run by construction would be a lane
# nobody reads; a plain green would claim what was not shown. Where the limit
# stands, the gate rests on the JVM test of the pure rule alone
# (PoliciesTest.belowApiThirtyAStartIsUnsupportedAndTouchesNothing). The same
# holds for S2's P1: nothing in this lane says what Android 10 does with a
# DEBUG line under a platform tag, so its absence there is a limit on the
# "no Bluetooth-tagged line" witness, not a finding about Haven.
#
# The probe's verdict is about whether a measurement was TAKEN, not about
# what it answered: Bluetooth that does not come on is `probe.bt_on=no` and
# rc 0. The exceptions are what push A promises whatever the platform says
# (the turn-on fails, nothing is stored, no component exists) and what §O
# calls a misconfiguration (fewer than five readable log buffers).
#
# # A target that ends early
#
# What the host reads of the APP it reads while the target holds; what the
# probe reads of the PLATFORM — the buffers, the property, the adapter's
# settings, the dumps' skeletons — needs no app and is read after the drive,
# whatever became of it. A target that never reached its hold is one UNUSABLE
# sentence (and RED where the suite failed), with the platform's measurements
# still judged; and why it ended is printed as `mesh-failure` lines
# (mesh_failure_facts): the thrown type, the assertion's file and line, the
# stack's `package:` frames — read out of the RAW transcript in closed shapes,
# because the transcript itself is withheld whenever the gate trips on it,
# which a framework failure report can make it do.
#
# # Log anonymity (Security Rule 15)
#
# An emulator's Bluetooth address and adapter name are identifiers all the
# same. Captures are taken into RAW_DIR, which is never uploaded; what goes to
# LOG_DIR (mesh_publish) is: the device log, with every address shape, the
# adapter's name and address — read over adb, held in two shell variables,
# never printed — and, on lines that are not Haven's, every bare run of twelve
# hex digits replaced by a fixed word (mesh_redact); of the events buffer,
# only the entries Haven's pid wrote; the drive transcript. A platform dump is
# kept only as a SKELETON (mesh_skeleton): its lines' shape, every value
# masked, which is what a parser is written against. Everything in LOG_DIR
# then goes through the gate like any lane's, and a hit there is a leak like
# any lane's. Whether a line of Haven's carries an address is judged over the
# RAW captures, by the oracle. What this runner prints — answers and the
# sentences of a finding alike — is numbers and a closed vocabulary
# (MESH_WORDS), by construction (mesh_show).
#
# Usage:
#   run-mesh-lever.sh <leg>...     # each of s0 | probe | s2, in order
#   run-mesh-lever.sh --self-test
#
#   s0 probe   the API 34 job: the flag-off control, then the probe
#   s2         the API 29 job
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

# The five buffers `logcat` documents for a shell; fewer readable is a
# misconfigured capture (§O.2.3).
readonly -a DOCUMENTED_BUFFERS=(main system crash radio events)
readonly -a PROBED_BUFFERS=(main system crash radio events stats security kernel)

# Every word an answer may be. `mesh_answer` writes nothing else, so the
# verdict file and the job log carry fixed words and numbers by construction.
readonly -a MESH_WORDS=(
  yes no unread present absent foreign ok nolib nosym refused failed on off
  true false none granted denied deniedForGood stopped running paused skipped
  not_found started error kept other pass red unusable broken
  mac unjudged cancelled bluetoothOff noPermission noPermissionForGood
  unsupported ON OFF TURNING_ON TURNING_OFF BLE_TURNING_ON BLE_ON
  BLE_TURNING_OFF missing answered asked unasked empty limited
)

# The plants beyond P1, P2 and P3, as the target writes them (`_morePlants`):
# the priorities and tags the lever's own lane will plant at. Each is an
# answer in every leg, never a verdict.
readonly -a MORE_PLANTS=(p1v:BluetoothGatt p1e:BluetoothGatt p4:BluetoothGattServer p5:BluetoothAdapter)

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

# mesh_load <capture> — the TARGET's `flutter` entries, read ONCE, into
# MESH_LINES as `<pid>\t<message>`. The oracle asks some forty questions of
# one capture; parsing it for each was most of the self-test's time.
#
# Whose lines: those of the pid that wrote the last `[mesh] PHASE` entry
# naming itself. Any process may log under `flutter`, so a marker another
# pid wrote is not the target's and is not loaded — and with no PHASE line
# that names its own writer, nothing is.
MESH_LINES=""
mesh_load() {
  MESH_LINES="$(mesh_entries "${1:-}" | LC_ALL=C awk -F'\t' -v phase="${MARK_PHASE}" '
    $2 != "flutter" { next }
    { n++; pid[n] = $1; text[n] = $3 }
    index($3, phase " ") == 1 {
      m = split($3, word, " ")
      for (i = 1; i <= m; i++) if (word[i] == "pid=" $1) own = $1
    }
    END { if (own != "") for (i = 1; i <= n; i++) if (pid[i] == own) print pid[i] "\t" text[i] }
  ')"
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

# mesh_show <value> — a value as it may be PRINTED or compared: up to nine
# digits, or a word of MESH_WORDS; nothing stays nothing, and anything else
# is `other`. Everything the oracle reads out of a capture or a facts file
# passes through this before it is used, so no sentence it prints can carry
# what a capture held.
mesh_show() {
  local value="${1:-}" word
  [[ -n "${value}" ]] || return 0
  if [[ "${value}" =~ ^[0-9]{1,9}$ ]]; then
    printf '%s\n' "${value}"
    return 0
  fi
  for word in "${MESH_WORDS[@]}"; do
    if [[ "${value}" == "${word}" ]]; then
      printf '%s\n' "${value}"
      return 0
    fi
  done
  echo other
}

# mesh_get <prefix> <key> — a loaded marker's field, through mesh_show.
mesh_get() { mesh_show "$(mesh_loaded_field "${1:-}" "${2:-}")"; }

# mesh_known <facts> <key> — a recorded fact, through mesh_show.
mesh_known() { mesh_show "$(mesh_fact "${1:-}" "${2:-}")"; }

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

# mesh_addr_line_count <capture> <pid> — entries under <pid>, whatever their
# tag, that carry a Bluetooth address shape: six colon-separated pairs, the
# platform's own `XX:XX:XX:XX:…` redaction included. Read over the RAW
# capture: the published copy has every such shape replaced, on Haven's lines
# too, so this is the one place an address in a line of Haven's is seen.
mesh_addr_line_count() {
  mesh_entries "${1:-}" | LC_ALL=C awk -F'\t' -v pid="${2:-}" '
    BEGIN {
      pair = "[0-9A-Fa-fXx][0-9A-Fa-fXx]"
      shape = pair ":" pair ":" pair ":" pair ":" pair ":" pair
    }
    $1 == pid && $3 ~ shape { count++ }
    END { print count + 0 }
  '
}

# mesh_pid_slice <pid> — stdin a threadtime capture, stdout the entries
# <pid> wrote and nothing else.
mesh_pid_slice() {
  LC_ALL=C awk -v head="${THREADTIME_HEAD_RE}" -v pid="${1:-}" '
    { sub(/\r$/, "") }
    match($0, head) && $3 == pid { print }
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

# mesh_failure_facts <drive-transcript> <device-log> [<pid>] — why a drive
# ended, as `key=value` lines of CLOSED shapes, read out of the raw captures:
#
#   thrown=<Type>                  `The following <Type> was thrown …`
#   exception=<Class>              a line that opens with `…Exception`/`…Error`
#   assertion=<package path>:<n>   `'package:…dart': Failed assertion: line <n>`
#   frame=<package path>:<n>       a stack frame's location
#   target_frame=<test path>:<n>   …and one inside `integration_test/`
#   missing_plugin=<method>@<channel>
#   url_alone_lines=<n> / url_alone_host=<host|other>
#   url_dial_failure_lines=<n>     the two line shapes the scanner's S13 reads
#   suite=failed, timed_out=yes, drive_lost_app=yes
#
# A type, a class, a method and a channel are identifiers of CODE; a path is
# a `package:` path; a host is one of a fixed list or the word `other`. No
# message, no description of a widget, no value: an exception's own text can
# carry anything, and is never read out.
#
# Why this exists: a framework failure report can end in a line that is a URL
# and nothing else, which the log scanner reads as a relay host a wrap left
# alone (S13) — so the gate withholds the very transcript that says why the
# drive failed (CI run 43586443164, the probe's two LEAK lines). These lines
# are what is left to read then.
mesh_failure_facts() {
  local drive="${1:-}" device="${2:-}" pid="${3:-}"
  {
    if [[ -f "${drive}" ]]; then tr -d '\r' < "${drive}"; fi
    mesh_entries "${device}" | LC_ALL=C awk -F'\t' -v pid="${pid}" '
      $2 == "flutter" && (pid == "" || $1 == pid) { print $3 }
    '
  } | LC_ALL=C awk '
    function lead(text, re, most) {
      if (!match(text, re) || RLENGTH > most) return ""
      return substr(text, 1, RLENGTH)
    }
    function emit(key, value, most,   line) {
      line = key "=" value
      if (value == "" || (line in seen) || made[key] >= most || n >= 40) return
      seen[line] = 1; made[key]++; out[++n] = line
    }
    function host_word(url,   host) {
      sub(/^[Hh][Tt][Tt][Pp][Ss]?:\/\//, "", url)
      host = tolower(lead(url, "^[A-Za-z0-9.-]+", 80))
      return (host in known) ? host : "other"
    }
    # The location a frame ends in: `(package:<pkg>/<path>.dart:<line>…`, or a
    # file under integration_test/.
    function location(text,   at, path, rest, line) {
      at = index(text, "(package:")
      if (at) {
        rest = substr(text, at + 1)
        path = lead(rest, "^package:[a-z0-9_]+/[A-Za-z0-9_/.]+[.]dart", 160)
        line = lead(substr(rest, length(path) + 1), "^:[0-9]+", 10)
        if (path != "" && line != "") emit("frame", path line, index(path, "package:haven/") == 1 ? 12 : 6)
        return
      }
      at = index(text, "/integration_test/")
      if (at && index(text, "(file://")) {
        rest = substr(text, at + 1)
        path = lead(rest, "^integration_test/[A-Za-z0-9_/]+[.]dart", 160)
        line = lead(substr(rest, length(path) + 1), "^:[0-9]+", 10)
        if (path != "" && line != "") emit("target_frame", path line, 4)
      }
    }
    BEGIN {
      split("github.com flutter.dev docs.flutter.dev api.flutter.dev dart.dev pub.dev", hosts, " ")
      for (i in hosts) known[hosts[i]] = 1
      dial = "uri *=|httpexception|websocketexception|connection closed|socket closed|not upgraded to websocket|websocket[.]connect|handshake"
    }
    {
      text = $0
      sub(/^[A-Z]\/flutter *\( *[0-9]+\): /, "", text)
      sub(/^[ \t]+/, "", text)
      sub(/[ \t]+$/, "", text)

      at = index(text, "The following ")
      if (at) {
        rest = substr(text, at + 14)
        type = lead(rest, "^[A-Za-z_][A-Za-z0-9_]*", 64)
        if (type != "" && index(substr(rest, length(type) + 1), " was thrown") == 1) emit("thrown", type, 4)
      }
      type = lead(text, "^[A-Z_][A-Za-z0-9_]*(Exception|Error)", 64)
      if (type != "" && substr(text, length(type) + 1, 1) ~ /^[:( ]?$/) emit("exception", type, 8)

      at = index(text, ": Failed assertion: line ")
      if (at) {
        from = index(text, "package:")
        path = from ? lead(substr(text, from), "^package:[a-z0-9_]+/[A-Za-z0-9_/.]+[.]dart", 160) : ""
        line = lead(substr(text, at + 25), "^[0-9]+", 9)
        if (path != "" && line != "") emit("assertion", path ":" line, 4)
      }
      if (text ~ /^#[0-9]+ /) location(text)

      at = index(text, "No implementation found for method ")
      if (at) {
        rest = substr(text, at + 35)
        method = lead(rest, "^[A-Za-z0-9_.]+", 40)
        rest = substr(rest, length(method) + 1)
        if (method != "" && index(rest, " on channel ") == 1) {
          emit("missing_plugin", method "@" lead(substr(rest, 13), "^[A-Za-z0-9_./-]+", 80), 6)
        }
      }

      if (text ~ /^[Hh][Tt][Tt][Pp][Ss]?:\/\/[^ \t]+$/) {
        alone++
        emit("url_alone_host", host_word(text), 7)
      } else if (text ~ /[Hh][Tt][Tt][Pp][Ss]?:\/\// && tolower(text) ~ dial) {
        dialled++
      }
      if (index(text, "Some tests failed") || index(text, "Failure Details:")) emit("suite", "failed", 1)
      if (index(text, "Test timed out") || index(text, "timed out after")) emit("timed_out", "yes", 1)
      if (index(text, "Lost connection to device") || index(text, "Service has disappeared")) emit("drive_lost_app", "yes", 1)
    }
    END {
      for (i = 1; i <= n; i++) print out[i]
      if (alone) print "url_alone_lines=" alone
      if (dialled) print "url_dial_failure_lines=" dialled
    }
  '
}

# mesh_leak_message <legs whose own gate tripped> <exit-scan rc> — WHICH gate
# found a leak. Two read this lane's logs: each leg's own, over that leg's
# device log, events slice and drive transcript the moment its drive ends,
# and the exit scan over everything left in the directory. A leg's gate
# deletes what it scanned, so the exit scan after it finds nothing of that
# leak: "the exit scan was clean" beside a red run is not a contradiction.
mesh_leak_message() {
  local legs="${1:-}" exit_rc="${2:-0}"
  local text="log-privacy gate tripped (Security Rules 6 and 15):"
  if [[ -n "${legs}" ]]; then
    text+=" the per-leg gate of ${legs} found the leak, in that leg's device log, events slice or drive transcript. The LEAK line(s) under its 'the leg's own log-privacy gate' heading name the file and line; those captures were deleted there and then"
    if [[ "${exit_rc}" == 1 ]]; then
      text+=", and the exit scan over what was left found another (the LEAK line(s) just above)."
    else
      text+=", so the exit scan over what was left found nothing more."
    fi
  else
    text+=" the exit scan over the uploaded directory found the leak, in a file no leg's own gate reads (a dump's skeleton, the verdict file, the relay's log). The LEAK line(s) just above name it."
  fi
  printf '%s\n' "${text}"
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

# mesh_service_word <service> — stdin `service check <service>`: whether the
# platform has that service at all. Android 10 starts its Bluetooth service
# only on an image that declares the Bluetooth feature (android10-release,
# services/java/com/android/server/SystemServer.java:1066-1075); on one that
# does not, a missing `dumpsys bluetooth_manager` is the truth, not a
# capture that failed.
mesh_service_word() {
  tr -d '\r' | LC_ALL=C awk -v name="${1:-}" '
    $0 == "Service " name ": found" { found = 1 }
    $0 == "Service " name ": not found" { missing = 1 }
    END { print found ? "present" : (missing ? "absent" : "unread") }
  '
}

# mesh_buffer_read_word — stdin `logcat -v threadtime -d -b <buffer> -t 1;
# echo "lane-rc $?"`: whether a shell is HANDED that buffer's entries, which
# a size query does not say.
#   yes     an entry came back
#   empty   the read succeeded and the buffer had none
#   no      the read failed
#   unread  the command never reported
mesh_buffer_read_word() {
  tr -d '\r' | LC_ALL=C awk -v head="${THREADTIME_HEAD_RE}" '
    index($0, "lane-rc ") == 1 { rc = substr($0, 9); ended = 1; next }
    match($0, head) { entries++ }
    END {
      if (!ended) print "unread"
      else if (rc != "0") print "no"
      else print (entries ? "yes" : "empty")
    }
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

# mesh_redact <label> <address> [<pid>|all] — stdin to stdout, with every
# Bluetooth address shape (`AA:BB:…`, the platform's own `XX:XX:XX:XX:…`
# redaction) and this adapter's name and address replaced by a fixed word.
# The address is also searched bare, in both cases. A name under four
# characters is not searched: it would shred the capture and identify nobody.
#
# A shell does not always get the address (`settings get` answers `null`
# where it may not), and then a BARE one — twelve hex digits — cannot be
# searched for. So every run of exactly twelve hex digits goes too, on every
# line but the entries <pid> wrote — or on none, with `all`, for a file whose
# every line is Haven's (a drive transcript): Haven's own lines are left for
# the scanner as they are, because a truncated id is twelve hex digits as well
# and must not be hidden from it. What Haven's lines may not carry is judged
# over the raw capture (mesh_addr_line_count), not here.
mesh_redact() {
  MESH_REDACT_LABEL="${1:-}" MESH_REDACT_ADDR="${2:-}" LC_ALL=C awk \
      -v head="${THREADTIME_HEAD_RE}" -v own="${3:-}" '
    function fixed(line, needle, word,    at, out) {
      # Also what ends the loop below: an empty needle is found at every
      # position, for ever.
      if (length(needle) < 4) return line
      out = ""
      while ((at = index(line, needle)) > 0) {
        out = out substr(line, 1, at - 1) word
        line = substr(line, at + length(needle))
      }
      return out line
    }
    function twelve(line,    out, run) {
      out = ""
      while (match(line, /[0-9A-Fa-f]+/)) {
        run = substr(line, RSTART, RLENGTH)
        out = out substr(line, 1, RSTART - 1) (RLENGTH == 12 ? "<hex12>" : run)
        line = substr(line, RSTART + RLENGTH)
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
      mine = (own == "all" || (own != "" && match($0, head) && $3 == own))
      line = fixed($0, label, "<bt-name>")
      if (addr != "") {
        line = fixed(line, addr, "<bt-addr>")
        line = fixed(line, toupper(addr), "<bt-addr>")
        line = fixed(line, tolower(addr), "<bt-addr>")
        line = fixed(line, toupper(bare), "<bt-addr>")
        line = fixed(line, tolower(bare), "<bt-addr>")
      }
      gsub(shape, "<bt-addr>", line)
      if (!mine) line = twelve(line)
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

# mesh_publish <leg> <raw-dir> <log-dir> <label> <address> <pid> — what of a
# leg's captures is PUBLISHED, and in what state:
#
#   logcat.<leg>.log         the device log whole, as every lane publishes it,
#                            redacted
#   logcat-events.<leg>.log  of the events buffer, the entries Haven's pid
#                            wrote and no others. The lane needs that buffer
#                            for its own planted event and, later, for what
#                            Haven's process puts there; the system's events —
#                            every process start, every notification — are
#                            nobody's evidence here and stay on the runner
#   flutter-drive.<leg>.log  the drive transcript, redacted; every line of it
#                            is Haven's or the tool's
#
# An empty capture publishes nothing: the gate reads a missing sink as what
# it is. With no pid known, no events are published at all.
mesh_publish() {
  local leg="$1" raw="$2" out="$3" label="$4" addr="$5" pid="$6"
  if [[ -s "${raw}/logcat.${leg}.raw" ]]; then
    mesh_redact "${label}" "${addr}" "${pid}" < "${raw}/logcat.${leg}.raw" > "${out}/logcat.${leg}.log" || true
  fi
  if [[ -s "${raw}/events.${leg}.raw" ]]; then
    mesh_pid_slice "${pid}" < "${raw}/events.${leg}.raw" \
      | mesh_redact "${label}" "${addr}" "${pid}" > "${out}/logcat-events.${leg}.log" || true
    [[ -s "${out}/logcat-events.${leg}.log" ]] || rm -f "${out}/logcat-events.${leg}.log"
  fi
  if [[ -s "${raw}/drive.${leg}.raw" ]]; then
    mesh_redact "${label}" "${addr}" all < "${raw}/drive.${leg}.raw" > "${out}/flutter-drive.${leg}.log" || true
  fi
}

# ---------------------------------------------------------------------------
# The oracle.
# ---------------------------------------------------------------------------
MESH_RED=()
MESH_UNUSABLE=()
MESH_BROKEN=()
MESH_LIMITS=()
MESH_ANSWERS=()

mesh_red() { MESH_RED+=("$*"); }
mesh_unusable() { MESH_UNUSABLE+=("$*"); }
mesh_broken() { MESH_BROKEN+=("$*"); }
# A limit is a leg that held everything it could judge and could NOT judge
# something its name promises, for a reason that is the image's: rc 0, the
# verdict word `limited`, and the sentence in the log. Never a silent pass.
mesh_limit() { MESH_LIMITS+=("$*"); }

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

# mesh_verdict_rc — 1 > 2 > 3 > 0 over what the oracle found. A limit is rc 0.
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
  state="$(mesh_known "$1" "$2")"
  [[ "${state}" == ok ]] && return 0
  mesh_unusable "$3 could not be read (${2}=${state:-missing}), so what it would have shown is unknown."
  return 1
}

# mesh_require_zero <facts> <key> <what>
mesh_require_zero() {
  local count
  count="$(mesh_known "$1" "$2")"
  [[ "${count}" == 0 ]] && return 0
  mesh_red "$3 (${2}=${count:-missing})."
  return 1
}

# mesh_probe_measurements <facts> — the probe's measurements of the PLATFORM:
# each must have been TAKEN, and none depends on Haven's app being alive, so
# they are judged even of a run whose target died.
mesh_probe_measurements() {
  local facts="$1" key value readable=0 buffer
  for key in le_feature bt_on; do
    value="$(mesh_known "${facts}" "${key}")"
    [[ "${key}" == le_feature ]] || mesh_answer "probe.${key}" "${value}"
    if [[ "${value}" != yes && "${value}" != no ]]; then
      mesh_unusable "the probe could not measure ${key} (${value:-missing}): the platform did not answer."
    fi
  done
  mesh_answer probe.bt_state "$(mesh_known "${facts}" bt_state)"
  mesh_answer probe.bt_on_after_s "$(mesh_known "${facts}" bt_on_after_s)" n
  for key in setprop_log_tag adapter_address_readable adapter_label_readable; do
    value="$(mesh_known "${facts}" "${key}")"
    mesh_answer "probe.${key}" "${value}"
    if [[ "${value}" != yes && "${value}" != no ]]; then
      mesh_unusable "the probe could not measure ${key} (${value:-missing})."
    fi
  done
  mesh_answer probe.adapter_address_shape "$(mesh_known "${facts}" adapter_address_shape)"
  # Two questions a buffer: does logd answer for its size, and is a shell
  # handed an entry of it. Only the second says the lever's lane can read it.
  for buffer in "${PROBED_BUFFERS[@]}"; do
    value="$(mesh_known "${facts}" "buffer_${buffer}_kib")"
    if [[ "${value}" =~ ^[0-9]+$ ]]; then
      mesh_answer "probe.buffer_${buffer}_kib" "${value}" n
    else
      mesh_answer "probe.buffer_${buffer}_kib" unread
    fi
    value="$(mesh_known "${facts}" "buffer_${buffer}_read")"
    mesh_answer "probe.buffer_${buffer}_read" "${value}"
    case "${value}" in
      yes|empty|no) ;;
      *) mesh_unusable "the probe could not ask whether a shell is handed the ${buffer} buffer's entries (${value:-missing})." ;;
    esac
  done
  for buffer in "${DOCUMENTED_BUFFERS[@]}"; do
    [[ "$(mesh_known "${facts}" "buffer_${buffer}_kib")" =~ ^[0-9]+$ ]] && readable=$(( readable + 1 ))
  done
  mesh_answer probe.buffers_readable "${readable}" n
  if (( readable < ${#DOCUMENTED_BUFFERS[@]} )); then
    mesh_unusable "a shell reads ${readable} of the five log buffers logcat documents (main, system, crash, radio, events): a misconfigured capture, and no list for the lever's lane to capture."
  fi
  for key in dump_services dump_notification dump_bluetooth; do
    value="$(mesh_known "${facts}" "${key}")"
    mesh_answer "probe.${key}" "${value}"
    if [[ "${value}" != kept ]]; then
      mesh_unusable "the probe did not keep the skeleton of a dump (${key}=${value:-missing}): the lever's parsers would be written against nothing."
    fi
  done
}

# mesh_run_oracle <leg> <logcat> <events> <facts> — s0 | probe | s2. Reads
# complete captures; no device. Fills the arrays and returns the verdict.
#
# Every value it reads — a marker's field, a fact — comes through mesh_show
# (mesh_get, mesh_known), so what it compares and what it prints are numbers
# and words of MESH_WORDS. The plant tokens are the one exception: they are
# searched for and never printed.
mesh_run_oracle() {
  local leg="$1" logcat="$2" events="$3" facts="$4"
  MESH_RED=(); MESH_UNUSABLE=(); MESH_BROKEN=(); MESH_LIMITS=(); MESH_ANSWERS=()
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
  local pid flag host_pid
  pid="$(mesh_get "${MARK_PHASE}" pid)"
  flag="$(mesh_get "${MARK_PHASE}" flag)"
  host_pid="$(mesh_known "${facts}" pid_host)"
  if [[ ! "${pid}" =~ ^[0-9]+$ ]]; then
    mesh_unusable "the drive target never reported: no '${MARK_PHASE}' line under the flutter tag that names the pid that wrote it. The app did not launch, the drive did not reach it, or the capture is not live. Nothing below can be judged."
    mesh_verdict_rc
    return
  fi
  if [[ "${flag}" != "${want_flag}" ]]; then
    mesh_broken "leg ${leg} drove a build whose mesh flag reads '${flag:-nothing}', and it needs '${want_flag}': the wrong APK was installed."
    mesh_verdict_rc
    return
  fi
  if [[ "$(mesh_known "${facts}" drive_failed)" != no ]]; then
    mesh_red "the drive did not complete cleanly (flutter drive failed, or the suite on the device reported a failure) after the target had started."
  fi
  # --- What the image is ---------------------------------------------------
  # Asked in every leg, because what a leg can prove depends on it.
  local le_feature bt_service
  le_feature="$(mesh_known "${facts}" le_feature)"
  bt_service="$(mesh_known "${facts}" bt_service)"
  mesh_answer "${leg}.le_feature" "${le_feature}"
  mesh_answer "${leg}.bt_service" "${bt_service}"

  # --- Control: the plant call writes and the capture is live (P2) ---------
  local p1_token p2_token p3_token p1 p2 p3 p1_call p2_call p3_call
  p1_token="$(mesh_loaded_field "${MARK_PLANT} id=p1" token)"
  p2_token="$(mesh_loaded_field "${MARK_PLANT} id=p2" token)"
  p3_token="$(mesh_loaded_field "${MARK_PLANT} id=p3" token)"
  p1_call="$(mesh_get "${MARK_PLANT} id=p1" call)"
  p2_call="$(mesh_get "${MARK_PLANT} id=p2" call)"
  p3_call="$(mesh_get "${MARK_PLANT} id=p3" call)"
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

  # The other priorities and tags the lever's lane will plant at. Answers,
  # in every leg; their tokens are plants for the count below.
  local plant id tag token seen
  local -a planted=("${p1_token}")
  for plant in "${MORE_PLANTS[@]}"; do
    id="${plant%%:*}"
    tag="${plant##*:}"
    token="$(mesh_loaded_field "${MARK_PLANT} id=${id}" token)"
    seen="$(mesh_plant_seen "${logcat}" "${token}" "${pid}" "${tag}")"
    mesh_answer "${leg}.${id}" "${seen}"
    [[ -z "${token}" ]] || planted+=("${token}")
  done

  # --- P1: a platform Bluetooth tag, written with no lever -----------------
  # S0 (API 34): a promise — no lever is in the process, so the line is there,
  # and the probe of the same job, on the same image, says whether the
  # platform writes such a line at all. The probe: an answer. S2 (API 29):
  # nothing in this lane says what Android 10 does with such a line, so its
  # absence there is a limit — the witness below was not exercised — and not
  # a finding about Haven, which has no lever below API 30 to put in.
  if [[ "${p2}" == present && "${p1}" == absent ]]; then
    case "${leg}" in
      s0) mesh_red "P1: a DEBUG line written under BluetoothGatt from Haven's process is not in the log, while the flutter line written by the same call is. Either a log lever is in a process that must have none, or this platform drops such a line; the probe leg's p1 answer, same job and same image, says which." ;;
      s2) mesh_limit "P1: a DEBUG line written under BluetoothGatt from Haven's process is not in this release's log, so 'no Bluetooth-tagged line from Haven' was not exercised here: nothing shows such a line would be in the capture." ;;
    esac
  fi

  # --- No Bluetooth object was made in Haven's process ---------------------
  # Judged only where P1 is present: that is what shows such a line would be
  # in this capture at all.
  if [[ "${p1}" == present ]]; then
    local touched
    touched="$(mesh_bt_touch_count "${logcat}" "${pid}" "${planted[@]}")"
    mesh_answer "${leg}.bt_tag_lines" "${touched}" n
    if (( touched > 0 )); then
      mesh_red "${touched} line(s) under a platform Bluetooth tag were written from Haven's process and are not planted ones: something in this build made a Bluetooth object, which nothing in push A may."
    fi
  else
    mesh_answer "${leg}.bt_tag_lines" unjudged
  fi
  # …and no line of Haven's, under any tag and in either buffer, carries a
  # Bluetooth address. Counted over the raw captures: the published copies
  # have every address shape replaced.
  local addressed
  addressed=$(( $(mesh_addr_line_count "${logcat}" "${pid}") + $(mesh_addr_line_count "${events}" "${pid}") ))
  mesh_answer "${leg}.address_lines" "${addressed}" n
  if (( addressed > 0 )); then
    mesh_red "${addressed} line(s) from Haven's process carry a Bluetooth address shape. Nothing of Haven's may write one (Security Rule 15), and no build of push A can so much as read one."
  fi

  # --- The target must have reached its hold --------------------------------
  # A target that ended before `READY` — its test failed, or its process went
  # — was never read by the host: there was no app to read. That is one
  # sentence, not twenty; and what the probe measures of the platform, which
  # needs no app, is still judged.
  if [[ "$(mesh_known "${facts}" ready)" != yes ]]; then
    mesh_unusable "the target never reached '${MARK_READY}': the drive ended first, so the host read nothing of the app and nothing the target reports after its plants was said. See the mesh-failure lines for what the drive's own transcript says ended it."
    if [[ "${leg}" == probe ]]; then
      mesh_probe_measurements "${facts}"
    fi
    mesh_verdict_rc
    return
  fi
  if [[ "${host_pid}" != "${pid}" ]]; then
    mesh_unusable "the host read pid '${host_pid:-nothing}' for ${PKG} while the target reported '${pid}': what the host inspected was not the process that reported."
  fi
  if mesh_loaded_has "${MARK_HOLD_EXPIRED}"; then
    mesh_unusable "the target's hold ran out before the host had finished inspecting it (${HOLD_BOUND_SECS}s): what was read may have been read of an app no longer running."
  elif ! mesh_loaded_has "${MARK_RELEASED}" || ! mesh_loaded_has "${MARK_DONE}"; then
    mesh_unusable "the target never reached '${MARK_RELEASED}' and '${MARK_DONE}': it ended, or the capture did, inside the inspection."
  fi

  # --- The channel ---------------------------------------------------------
  local asked missing answered failed lever_missing
  asked="$(mesh_get "${MARK_CHANNEL}" asked)"
  missing="$(mesh_get "${MARK_CHANNEL}" missing)"
  answered="$(mesh_get "${MARK_CHANNEL}" answered)"
  failed="$(mesh_get "${MARK_CHANNEL}" failed)"
  lever_missing="$(mesh_get "${MARK_CHANNEL}" lever_missing)"
  if [[ -z "${asked}" ]]; then
    mesh_unusable "the target never reported the channel ('${MARK_CHANNEL}')."
  elif (( ! flag_on )); then
    if [[ "${asked}" != 11 || "${missing}" != 11 || "${answered}" != 0 || "${failed}" != 0 ]]; then
      mesh_red "a build without the flag has a native end on the mesh's channel: of ${asked} methods asked, ${missing:-nothing} were missing, ${answered:-nothing} answered and ${failed:-nothing} failed. All eleven must be missing."
    fi
  else
    if [[ "${lever_missing}" != 3 ]]; then
      mesh_red "a method behind the log lever is answered: ${lever_missing:-none} of bluetoothOn, bluetoothName and start were missing, and in push A all three must be. The lever is reachable ahead of the lane that proves it."
    fi
    if [[ "${asked}" != 7 || "${answered}" != 4 || "${failed}" != 0 ]]; then
      mesh_red "the channel does not answer what push A answers: of ${asked} methods asked, ${answered:-nothing} answered and ${failed:-nothing} failed; permission, status, supported and takeAction must each answer."
    fi
  fi

  local supported permission state wanted
  supported="$(mesh_get "${MARK_ANSWER}" supported)"
  permission="$(mesh_get "${MARK_ANSWER}" permission)"
  state="$(mesh_get "${MARK_ANSWER}" state)"
  wanted="$(mesh_get "${MARK_ANSWER}" wanted)"
  mesh_answer "${leg}.supported" "${supported}"
  mesh_answer "${leg}.permission" "${permission}"
  if [[ -z "${supported}" ]]; then
    mesh_unusable "the target never reported the channel's answers ('${MARK_ANSWER}')."
  elif (( ! flag_on )); then
    if [[ "${supported}" != none || "${permission}" != none || "${state}" != none || "${wanted}" != none ]]; then
      mesh_red "a build without the flag answered a question of the mesh's (supported=${supported} permission=${permission:-nothing} state=${state:-nothing} wanted=${wanted:-nothing})."
    fi
  else
    if [[ "${state}" != stopped || "${wanted}" != false ]]; then
      mesh_red "before anything was asked the radio reads state=${state:-nothing} wanted=${wanted:-nothing}; a build of push A has no service, so it must read stopped and not wanted."
    fi
    if [[ "${leg}" == s2 && "${supported}" != false ]]; then
      mesh_red "below Android 11 the channel answers supported=${supported}; it must answer false there, whatever the image has."
    fi
    if [[ "${leg}" == probe ]]; then
      if [[ "${le_feature}" == yes && "${supported}" != true ]] || [[ "${le_feature}" == no && "${supported}" != false ]]; then
        mesh_red "the channel answers supported=${supported} on an image whose Bluetooth LE feature reads '${le_feature}': the two must agree on Android 11 and later."
      fi
    fi
  fi

  # --- S2: was the API gate what answered? ---------------------------------
  # `supported` is false below Android 11 AND on a phone with no Bluetooth LE.
  # Only on an image that HAS the feature does `supported=false` show the API
  # gate: without it the answer would be false with the gate deleted. That is
  # said, as an answer and as a limit; the gate itself is then held by the
  # JVM test of the pure rule alone
  # (PoliciesTest.belowApiThirtyAStartIsUnsupportedAndTouchesNothing).
  if [[ "${leg}" == s2 ]]; then
    case "${le_feature}" in
      yes) mesh_answer s2.api_gate_exercised yes ;;
      no)
        mesh_answer s2.api_gate_exercised no
        mesh_limit "this image declares no Bluetooth LE feature, so 'supported' is false here with or without the Android 11 gate: the gate was NOT exercised on a device. It rests on the JVM test of the rule; what this leg did show is that the flag-on build installs and runs on Android 10 and offers nothing of the mesh."
        ;;
      *)
        mesh_answer s2.api_gate_exercised unread
        mesh_unusable "whether this image declares Bluetooth LE could not be read (le_feature=${le_feature:-missing}), so what 'supported=false' shows here is unknown."
        ;;
    esac
  fi

  # --- The tree ------------------------------------------------------------
  local shell button want_button=0
  shell="$(mesh_get "${MARK_UI}" shell)"
  button="$(mesh_get "${MARK_UI}" button)"
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
      mesh_red "a flag-on build on a phone the radio says can run the mesh draws ${button:-no reported} mesh button(s); it must draw one. That one is also what shows the other legs' zero is a finding."
    else
      mesh_red "${button:-an unreported number of} mesh button(s) are in the tree of a build or a phone that must offer nothing of the mesh."
    fi
  fi

  # --- The turn-on, and what it left ---------------------------------------
  # WHERE it ended is the target's observation of its own channel traffic,
  # not an inference: what `bluetoothOn` was answered during the turn-on, and
  # whether `start` was ever sent.
  local ended turn_ms turn_bt turn_start after_state after_wanted
  ended="$(mesh_get "${MARK_TURN_ON}" ended)"
  turn_ms="$(mesh_get "${MARK_TURN_ON}" ms)"
  turn_bt="$(mesh_get "${MARK_TURN_ON}" bt_on)"
  turn_start="$(mesh_get "${MARK_TURN_ON}" start)"
  after_state="$(mesh_get "${MARK_AFTER}" state)"
  after_wanted="$(mesh_get "${MARK_AFTER}" wanted)"
  mesh_answer "${leg}.turn_on" "${ended}"
  mesh_answer "${leg}.turn_on_ms" "${turn_ms}" n
  mesh_answer "${leg}.turn_on_bluetooth_on" "${turn_bt}"
  if [[ -z "${ended}" ]]; then
    mesh_unusable "the target never reported its turn-on ('${MARK_TURN_ON}')."
  elif [[ "${ended}" == skipped ]]; then
    mesh_unusable "the turn-on was not asked: the radio's permission reads '${permission:-nothing}', so the system would have shown its dialog and the answer would have been the dialog's bound. The grant did not take."
  elif [[ "${ended}" != failed ]]; then
    mesh_red "a turn-on ended '${ended}'. In push A no build can turn the mesh on: it must end 'failed' at the unanswered method, with nothing stored."
  fi
  if [[ -n "${ended}" && "${ended}" != skipped ]] && [[ -z "${turn_bt}" || -z "${turn_start}" ]]; then
    mesh_unusable "the target did not report where its turn-on ended (what 'bluetoothOn' was answered, whether 'start' was sent), so that it ended at the unanswered method is not shown."
  elif [[ -n "${ended}" && "${ended}" != skipped ]]; then
    if [[ "${turn_start}" != unasked ]]; then
      mesh_red "during the turn-on the radio's 'start' was sent (start=${turn_start}): in push A a turn-on must end before it, at 'bluetoothOn'."
    fi
    if (( flag_on )); then
      case "${turn_bt}" in
        missing) ;;
        answered) mesh_red "during the turn-on 'bluetoothOn' was ANSWERED: a method behind the log lever has a native end, and the lever is reachable ahead of the lane that proves it." ;;
        *) mesh_unusable "the turn-on failed without ever asking 'bluetoothOn' (bt_on=${turn_bt}): it ended somewhere earlier — the notices' words, the permission question — and where a turn-on ends in push A was not shown." ;;
      esac
    elif [[ "${turn_bt}" != unasked ]]; then
      mesh_red "a build without the flag asked the radio 'bluetoothOn' during a turn-on (bt_on=${turn_bt}): with the flag off no Dart code may call a mesh entry."
    fi
  fi
  if [[ -z "${after_state}" ]]; then
    mesh_unusable "the target never reported the radio after its turn-on ('${MARK_AFTER}')."
  elif (( flag_on )) && [[ "${after_state}" != stopped || "${after_wanted}" != false ]]; then
    mesh_red "after the turn-on the radio reads state=${after_state} wanted=${after_wanted:-nothing}: something was started or stored."
  elif (( ! flag_on )) && [[ "${after_state}" != none || "${after_wanted}" != none ]]; then
    mesh_red "after the turn-on a build without the flag answers the radio's status (state=${after_state} wanted=${after_wanted:-nothing})."
  fi

  # --- The host's reading of the device ------------------------------------
  if mesh_require_dump "${facts}" package_dump "\`dumpsys package ${PKG}\`"; then
    mesh_require_zero "${facts}" package_mesh_components "the installed package declares a component of the mesh's, and no build of push A may" || true
    if (( flag_on )); then
      mesh_answer "${leg}.package_mesh_permissions" "$(mesh_known "${facts}" package_mesh_permissions)" n
    else
      mesh_require_zero "${facts}" package_mesh_permissions "a build without the flag requests a Bluetooth or connected-device permission" || true
    fi
  fi
  local am_key am_word
  for am_key in am_fgs am_svc am_alias; do
    am_word="$(mesh_known "${facts}" "${am_key}")"
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
  # An image with no Bluetooth service has no Bluetooth manager to ask, and
  # that is an answer: nothing can be registered with a service that is not
  # there. Anything but a plain `absent` leaves the dump owed.
  if [[ "${bt_service}" != absent ]]; then
    if mesh_require_dump "${facts}" bluetooth_dump "\`dumpsys bluetooth_manager\`"; then
      mesh_require_zero "${facts}" bluetooth_names_haven "the Bluetooth manager names Haven among what it serves" || true
    fi
  fi
  case "$(mesh_known "${facts}" stored_copy)" in
    absent) ;;
    present) mesh_red "the service's stored copy (${MESH_PREFS_FILE}) exists, and nothing in push A may write it." ;;
    *) mesh_unusable "the app's stored preferences could not be listed (\`run-as\` did not answer), so whether the turn-on stored anything is unknown." ;;
  esac

  if [[ "${leg}" == probe ]]; then
    mesh_probe_measurements "${facts}"
  fi

  mesh_verdict_rc
}

# mesh_report <leg> <rc> — the oracle's findings and answers, in fixed words.
# Nothing a capture held is printed: the findings are this file's sentences
# over values that came through mesh_show, and the answers are filtered.
mesh_report() {
  local leg="$1" rc="$2" line verdict=pass
  case "${rc}" in 1) verdict=red ;; 2) verdict=broken ;; 3) verdict=unusable ;; esac
  if [[ "${verdict}" == pass ]] && (( ${#MESH_LIMITS[@]} > 0 )); then verdict=limited; fi
  for line in ${MESH_RED[@]+"${MESH_RED[@]}"}; do echo "  RED (${leg}): ${line}" >&2; done
  for line in ${MESH_BROKEN[@]+"${MESH_BROKEN[@]}"}; do echo "  BROKEN (${leg}): ${line}" >&2; done
  for line in ${MESH_UNUSABLE[@]+"${MESH_UNUSABLE[@]}"}; do echo "  UNUSABLE (${leg}): ${line}" >&2; done
  for line in ${MESH_LIMITS[@]+"${MESH_LIMITS[@]}"}; do
    echo "  LIMIT (${leg}): ${line}"
    # Fixed text on the run's summary page: a limited green must not need the
    # step log opened to be seen as one.
    echo "::notice title=Mesh lane ${leg}: passed with a stated limit::${line}"
  done
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
  local T1V='mesh-lane-plant-p1v-KABMCDNEFP' T1E='mesh-lane-plant-p1e-MABNCDPEFQ'
  local T4='mesh-lane-plant-p4-NABPCDQEFR' T5='mesh-lane-plant-p5-PABQCDREFS'
  _capture() {
    local leg="$1" logcat="$2" events="$3" facts="$4"
    local flag=on channel answer ui='shell=1 button=0 available=false supported_read=false'
    local after='state=stopped wanted=false' perms=6 turned='bt_on=missing start=unasked'
    case "${leg}" in
      s0)
        flag=off; perms=0; turned='bt_on=unasked start=unasked'
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
      _entry 4021 V BluetoothGatt "${T1V}"
      _entry 4021 I flutter "${MARK_PLANT} id=p1v token=${T1V} call=ok"
      _entry 4021 E BluetoothGatt "${T1E}"
      _entry 4021 I flutter "${MARK_PLANT} id=p1e token=${T1E} call=ok"
      _entry 4021 D BluetoothGattServer "${T4}"
      _entry 4021 I flutter "${MARK_PLANT} id=p4 token=${T4} call=ok"
      _entry 4021 D BluetoothAdapter "${T5}"
      _entry 4021 I flutter "${MARK_PLANT} id=p5 token=${T5} call=ok"
      _entry 4021 I flutter "${MARK_TURN_ON} ended=failed ms=412 ${turned}"
      _entry 4021 I flutter "${MARK_AFTER} ${after}"
      _entry 4021 I flutter "${MARK_READY}"
      _entry 4021 I flutter "${MARK_RELEASED}"
      _entry 4021 I flutter "${MARK_DONE}"
    } > "${logcat}"
    {
      echo '--------- beginning of events'
      _entry 4021 I '[1296388936]' "${T3}"
    } > "${events}"
    printf '%s\n' ready=yes pid_host=4021 drive_failed=no le_feature=yes bt_service=present \
      package_dump=ok package_mesh_components=0 "package_mesh_permissions=${perms}" \
      am_fgs=not_found am_svc=not_found am_alias=not_found \
      services_dump=ok services_mesh=0 notification_dump=ok notification_mesh=0 \
      bluetooth_dump=ok bluetooth_names_haven=0 stored_copy=absent > "${facts}"
    if [[ "${leg}" == probe ]]; then
      printf '%s\n' bt_on=yes bt_state=ON bt_on_after_s=4 \
        setprop_log_tag=yes adapter_address_readable=yes adapter_address_shape=mac \
        adapter_label_readable=yes buffer_main_kib=256 buffer_system_kib=256 \
        buffer_crash_kib=256 buffer_radio_kib=256 buffer_events_kib=256 \
        buffer_stats_kib=64 buffer_security_kib=unread buffer_kernel_kib=unread \
        buffer_main_read=yes buffer_system_read=yes buffer_crash_read=empty \
        buffer_radio_read=yes buffer_events_read=yes buffer_stats_read=yes \
        buffer_security_read=no buffer_kernel_read=no \
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

  # --- the suites that run beside everything below --------------------------
  # Four of them, each with its own scratch directory and sharing nothing:
  # one a leg, and the probe's answers with the first run's shapes. Started
  # here, before the first serial check, so that this self-test's wall time
  # is the longest of five strands and not their sum.
  _answers_suite() {
    local id written leg failure shapes
    # --- the probe answers; it does not judge the platform --------------------
    _fresh probe; _edit facts 's/^bt_on=yes$/bt_on=no/' 'bt_on=no'
    _edit facts 's/^bt_state=ON$/bt_state=OFF/' 'bt_state=OFF'
    _oracle "Bluetooth that does not come on is an answer, not a failure" probe 0
    _eq_case "…written as one" 1 "$(printf '%s\n' "${MESH_ANSWERS[@]}" | grep -cx 'probe.bt_on=no' || true)"
    _fresh probe; _drop logcat "D BluetoothGatt:"
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
    local written
    for id in p1v p1e p4 p5; do
      case "${id}" in
        p1v) written='V BluetoothGatt' ;;
        p1e) written='E BluetoothGatt' ;;
        p4) written='D BluetoothGattServer' ;;
        *) written='4021 D BluetoothAdapter' ;;
      esac
      _fresh probe; _drop logcat "${written}"
      _oracle "a plant at another priority or tag that is not written is an answer (${id})" probe 0
      _eq_case "…written as one" 1 "$(printf '%s\n' "${MESH_ANSWERS[@]}" | grep -cx "probe.${id}=absent" || true)"
    done
    _fresh probe; _oracle "the other plants are answered where they are written" probe 0
    _eq_case "…each by its own tag" 4 \
      "$(printf '%s\n' "${MESH_ANSWERS[@]}" | grep -cxE 'probe\.(p1v|p1e|p4|p5)=present' || true)"
    _fresh probe; _edit facts 's/^buffer_stats_read=yes$/buffer_stats_read=no/' 'buffer_stats_read=no'
    _oracle "a buffer a shell is not handed is an answer" probe 0
    _eq_case "…written as one, beside its size" 2 \
      "$(printf '%s\n' "${MESH_ANSWERS[@]}" | grep -cxE 'probe\.buffer_stats_read=no|probe\.buffer_stats_kib=64' || true)"
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
    _fresh probe; _drop facts 'buffer_kernel_read='
    _oracle "a buffer whose read was never asked is unusable" probe 3 'handed the kernel buffer'
    _fresh probe; _edit facts 's/^dump_bluetooth=kept$/dump_bluetooth=unread/' 'dump_bluetooth=unread'
    _oracle "a dump whose skeleton was not kept is unusable" probe 3 'did not keep the skeleton'

    # --- the shapes of this lane's first run on CI (43586443164) --------------
    # The probe's target ended inside its turn-on: no TURN_ON line, no READY, a
    # failed drive, and nothing of the app read by a host that never got its cue.
    # The platform was read all the same.
    _early() {
      local marker
      _fresh "$1"
      for marker in "${MARK_TURN_ON}" "${MARK_AFTER}" "${MARK_READY}" "${MARK_RELEASED}" "${MARK_DONE}"; do
        _drop logcat "${marker}"
      done
      grep -vE '^(ready|pid_host|drive_failed|package_|am_|services_|notification_|bluetooth_|stored_copy)' \
        "${tmp}/c.facts" > "${tmp}/c.tmp" || true
      mv "${tmp}/c.tmp" "${tmp}/c.facts"
      printf '%s\n' ready=no drive_failed=yes >> "${tmp}/c.facts"
    }
    _early probe
    _oracle "a probe whose target ended before its hold is red: its suite failed" probe 1 'did not complete cleanly'
    _eq_case "…with ONE sentence for all the host never read, not one a question" 1 "${#MESH_UNUSABLE[@]}"
    _eq_case "…which says the target never reached its hold" 1 \
      "$(grep -cF -- "never reached '${MARK_READY}'" <<<"${MESH_UNUSABLE[*]-}" || true)"
    _eq_case "…while what the probe measures of the platform is answered all the same" 5 \
      "$(printf '%s\n' "${MESH_ANSWERS[@]}" | grep -cxE 'probe\.(buffers_readable=5|setprop_log_tag=yes|bt_on=yes|dump_bluetooth=kept|buffer_main_read=yes)' || true)"
    _eq_case "…and so is what the target said before it ended" 3 \
      "$(printf '%s\n' "${MESH_ANSWERS[@]}" | grep -cxE 'probe\.(p1=present|le_feature=yes|bt_service=present)' || true)"
    _eq_case "…and nothing is said of a turn-on, a tree or a channel nobody reported" 0 \
      "$(printf '%s\n' "${MESH_ANSWERS[@]}" | grep -cE '^probe\.(turn_on|ui_button|supported|package_)' || true)"
    _early probe; _edit facts 's/^drive_failed=yes$/drive_failed=no/' 'drive_failed=no'
    _oracle "…a target that only never reached its hold is unusable, never green" probe 3 "never reached '${MARK_READY}'"
    _early probe; _drop facts 'buffer_'
    _oracle "…and a platform nobody asked is said of a target that ended early too" probe 1 'a shell reads 0 of the five'
    _early probe; _drop facts 'ready='
    _oracle "a run that never recorded whether the cue came is not read as one that got it" probe 1 "never reached '${MARK_READY}'"
    for leg in s0 s2; do
      _early "${leg}"
      _oracle "${leg}: a target that ended before its hold is red, in one sentence" "${leg}" 1 'did not complete cleanly'
      _eq_case "…${leg}: one" 1 "${#MESH_UNUSABLE[@]}"
      _eq_case "…${leg}: and no limit is stated of a leg that judged nothing" 0 "${#MESH_LIMITS[@]}"
    done
    # An app that was there at the cue and gone when the host read: a pid nobody
    # could read, no release, a failed drive.
    _fresh probe; _edit facts 's/^pid_host=4021$/pid_host=/' 'pid_host='
    _edit facts 's/^drive_failed=no$/drive_failed=yes/' 'drive_failed=yes'
    _drop logcat "${MARK_RELEASED}"; _drop logcat "${MARK_DONE}"
    _oracle "an app gone when the host reads is red, the drive having failed" probe 1 'did not complete cleanly'
    _eq_case "…and what was read is said to be of no process that reported" 1 \
      "$(grep -cF -- "the host read pid 'nothing'" <<<"${MESH_UNUSABLE[*]-}" || true)"
    _eq_case "…nor of a target that was still holding" 1 \
      "$(grep -cF -- "never reached '${MARK_RELEASED}'" <<<"${MESH_UNUSABLE[*]-}" || true)"

    # Why a drive ended, out of a transcript the gate may withhold: closed
    # shapes, and nothing of an exception's own text.
    cat > "${tmp}/fail.drive" <<'DRIVE_EOF'
VMServiceFlutterDriver: Connecting to Flutter application at http://127.0.0.1:33145/abc=/
I/flutter ( 4021): == EXCEPTION CAUGHT BY FLUTTER TEST FRAMEWORK ==
I/flutter ( 4021): The following assertion was thrown running a test:
I/flutter ( 4021): 'package:flutter/src/widgets/framework.dart': Failed assertion: line 2957 pos 12: '!_dirty': is not true.
I/flutter ( 4021): In either case, please report this assertion by filing a bug on GitHub:
I/flutter ( 4021):   https://github.com/flutter/flutter/issues/new?template=02_bug.yml
I/flutter ( 4021): When the exception was thrown, this was the stack:
I/flutter ( 4021): #2      Element.rebuild (package:flutter/src/widgets/framework.dart:5000:7)
I/flutter ( 4021): #3      _MapShellState._onResumed (package:haven/src/pages/map_shell.dart:2870:9)
I/flutter ( 4021): #4      main.<anonymous closure> (file:///home/runner/work/x/haven/integration_test/mesh_lever_test.dart:421:33)
I/flutter ( 4021): The following StateError was thrown running a test:
I/flutter ( 4021): Bad state: PlantedCircleName at relay.example.invalid
I/flutter ( 4021): MissingPluginException(No implementation found for method bluetoothOn on channel haven.app/mesh_radio)
I/flutter ( 4021): HttpException: Connection closed before full header was received, uri = https://relay.example.invalid
I/flutter ( 4021):   https://relay.example.invalid/PlantedCircleName
I/flutter ( 4021): The following Planted Circle Name was thrown running a test:
I/flutter ( 4021): #5      f (package:haven/src/a b.dart:1:1)
I/flutter ( 4021): MissingPluginException(No implementation found for method PlantedCircleName!x on channel c)
Failure Details:
DRIVE_EOF
    {
      _entry 4021 I flutter 'The following TimeoutException was thrown running a test:'
      _entry 555 I flutter 'The following ForeignError was thrown running a test:'
      _entry 4021 I OtherTag 'The following OtherTagError was thrown running a test:'
    } > "${tmp}/fail.logcat"
    local failure
    failure="$(mesh_failure_facts "${tmp}/fail.drive" "${tmp}/fail.logcat" 4021)"
    _eq_case "why a drive ended is read out of the raw transcript and the target's own lines" \
      "thrown=assertion assertion=package:flutter/src/widgets/framework.dart:2957 url_alone_host=github.com frame=package:flutter/src/widgets/framework.dart:5000 frame=package:haven/src/pages/map_shell.dart:2870 target_frame=integration_test/mesh_lever_test.dart:421 thrown=StateError exception=MissingPluginException missing_plugin=bluetoothOn@haven.app/mesh_radio exception=HttpException url_alone_host=other suite=failed thrown=TimeoutException url_alone_lines=2 url_dial_failure_lines=1" \
      "$(tr '\n' ' ' <<<"${failure}" | sed 's/ $//')"
    _eq_case "…with nothing of an exception's own text, and no host but a listed one" 0 \
      "$(grep -cE 'Planted|invalid|_dirty|Bad state' <<<"${failure}" || true)"
    local shapes='^(thrown|exception)=[A-Za-z_][A-Za-z0-9_]*$'
    shapes+='|^(assertion|frame)=package:[a-z0-9_]+/[A-Za-z0-9_/.]+[.]dart:[0-9]+$'
    shapes+='|^target_frame=integration_test/[A-Za-z0-9_/]+[.]dart:[0-9]+$'
    shapes+='|^missing_plugin=[A-Za-z0-9_.]+@[A-Za-z0-9_./-]+$'
    shapes+='|^url_alone_host=(github[.]com|flutter[.]dev|docs[.]flutter[.]dev|api[.]flutter[.]dev|dart[.]dev|pub[.]dev|other)$'
    shapes+='|^url_(alone|dial_failure)_lines=[0-9]+$|^(suite=failed|timed_out=yes|drive_lost_app=yes)$'
    _eq_case "…every line of it one of the closed shapes" 0 "$(grep -cvE "${shapes}" <<<"${failure}" || true)"
    _eq_case "…a line another process wrote under flutter is not the target's" 0 \
      "$(grep -c 'ForeignError' <<<"${failure}" || true)"
    _eq_case "…though with no pid known every flutter line is read" 1 \
      "$(mesh_failure_facts "${tmp}/fail.drive" "${tmp}/fail.logcat" '' | grep -c '^thrown=ForeignError$' || true)"
    _eq_case "…and never a line under another tag" 0 \
      "$(mesh_failure_facts "${tmp}/fail.drive" "${tmp}/fail.logcat" '' | grep -c 'OtherTagError' || true)"
    _eq_case "…a drive that said nothing of a known shape yields nothing" "" \
      "$(printf 'All tests passed!\n' > "${tmp}/ok.drive"; mesh_failure_facts "${tmp}/ok.drive" "${tmp}/nope" '')"
    printf '%s\n' 'Test timed out after 8 minutes.' 'Lost connection to device.' > "${tmp}/lost.drive"
    _eq_case "…a timeout and a lost app are each one fixed word" "timed_out=yes drive_lost_app=yes" \
      "$(mesh_failure_facts "${tmp}/lost.drive" "${tmp}/nope" '' | tr '\n' ' ' | sed 's/ $//')"

    # Which gate found a leak: the run's last word used to say only that one had.
    _eq_case "a leak a leg's own gate found is laid at that leg's gate" 1 \
      "$(mesh_leak_message probe 0 | grep -c 'the per-leg gate of probe found the leak.*the exit scan over what was left found nothing more' || true)"
    _eq_case "…with the exit scan's own find beside it where it made one" 1 \
      "$(mesh_leak_message 's0 probe' 1 | grep -c 'the per-leg gate of s0 probe found the leak.*the exit scan over what was left found another' || true)"
    _eq_case "…and a leak only the exit scan found is laid there" "1 0" \
      "$(mesh_leak_message '' 1 | grep -c 'the exit scan over the uploaded directory found the leak' || true) $(mesh_leak_message '' 1 | grep -c 'per-leg' || true)"
  }

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
    _fresh "${leg}"; _entry 4021 I haven_core 'linked AA:BB:CC:DD:EE:09' >> "${tmp}/c.logcat"
    _oracle "${leg}: a Bluetooth address on a line of Haven's is red" "${leg}" 1 'carry a Bluetooth address shape'
    _fresh "${leg}"; _entry 4021 I '[1296388936]' 'XX:XX:XX:XX:EE:09' >> "${tmp}/c.events"
    _oracle "${leg}: …in the events buffer too" "${leg}" 1 'carry a Bluetooth address shape'
    _fresh "${leg}"; _edit logcat 's/start=unasked/start=asked/' 'start=asked'
    _oracle "${leg}: a turn-on that sent the radio's start is red" "${leg}" 1 "'start' was sent"
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
    _oracle "${leg}: a Bluetooth dump that is none, on an image with the service, is unusable" "${leg}" 3 'dumpsys bluetooth_manager'
    _fresh "${leg}"; _edit facts 's/^bluetooth_dump=ok$/bluetooth_dump=unread/' 'bluetooth_dump=unread'
    _edit facts 's/^bt_service=present$/bt_service=unread/' 'bt_service=unread'
    _oracle "${leg}: …and where nobody could say whether the service exists" "${leg}" 3 'dumpsys bluetooth_manager'
    _fresh "${leg}"; _edit facts 's/^bluetooth_dump=ok$/bluetooth_dump=unread/' 'bluetooth_dump=unread'
    _edit facts 's/^bt_service=present$/bt_service=absent/' 'bt_service=absent'
    _oracle "${leg}: …but on an image with no Bluetooth service it is the answer" "${leg}" 0
    _eq_case "…written as one" 1 "$(printf '%s\n' "${MESH_ANSWERS[@]}" | grep -cx "${leg}.bt_service=absent" || true)"
    _fresh "${leg}"; _edit facts 's/^stored_copy=absent$/stored_copy=unread/' 'stored_copy=unread'
    _oracle "${leg}: preferences run-as could not list are unusable" "${leg}" 3 'could not be listed'

    # The controls: a capture that proves nothing is never a pass.
    _fresh "${leg}"; : > "${tmp}/c.logcat"
    _oracle "${leg}: an empty capture is unusable" "${leg}" 3 'never reported'
    _fresh "${leg}"; sed -i -e 's/ 4021  4021 I flutter /  555   555 I flutter /' "${tmp}/c.logcat"
    _oracle "${leg}: markers written by another pid are unusable" "${leg}" 3 'never reported'
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
  local suite
  for suite in s0 probe s2 answers; do
    (
      tmp="${tmp}/suite-${suite}"
      mkdir -p "${tmp}"
      checks=0
      fails=0
      if [[ "${suite}" == answers ]]; then _answers_suite; else _leg_suite "${suite}"; fi
      echo "__suite ${checks} ${fails}"
    ) > "${tmp}/suite-${suite}.out" 2>&1 &
  done

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

  _eq_case "another process's Bluetooth lines are not Haven's, and its plants are not findings" 0 \
    "$(mesh_bt_touch_count "${tmp}/c.logcat" 4021 "${T1}" "${T1V}" "${T1E}" "${T4}" "${T5}")"
  _entry 4021 D BluetoothAdapter 'isLeEnabled(): ON' >> "${tmp}/c.logcat"
  _eq_case "a Bluetooth-tagged line of Haven's that is no plant is counted" 1 \
    "$(mesh_bt_touch_count "${tmp}/c.logcat" 4021 "${T1}" "${T1V}" "${T1E}" "${T4}" "${T5}")"
  _eq_case "…and a plant whose token is not handed over is counted too" 2 \
    "$(mesh_bt_touch_count "${tmp}/c.logcat" 4021 "${T1}" "${T1V}" "${T1E}" "${T4}")"

  {
    _entry 4021 E AndroidRuntime 'FATAL EXCEPTION: main'
    _entry 4021 E AndroidRuntime "Process: ${PKG}, PID: 4021"
    _entry 5100 E AndroidRuntime 'Process: com.example.other, PID: 5100'
    _entry 6000 F DEBUG "pid: 4021, tid: 4040, name: 1.ui  >>> ${PKG} <<<"
  } > "${tmp}/crash.logcat"
  _eq_case "both crash records of Haven's are counted, another app's is not" 2 \
    "$(mesh_crash_count "${tmp}/crash.logcat")"

  {
    _entry 4021 I flutter 'no address here, a clock 10:00:00 and a pid'
    _entry 4021 I haven_core 'peer AA:BB:CC:DD:EE:01 seen'
    _entry 4021 D OtherTag 'the platform form XX:XX:XX:XX:EE:02'
    _entry 900 D bt_stack 'the stack speaks of AA:BB:CC:DD:EE:03'
  } > "${tmp}/addr.logcat"
  _eq_case "an address shape on a line of Haven's is counted, under any tag; the stack's is not" 2 \
    "$(mesh_addr_line_count "${tmp}/addr.logcat" 4021)"
  _eq_case "a slice is one pid's entries and nothing else" 3 \
    "$(mesh_pid_slice 4021 < "${tmp}/addr.logcat" | grep -c ' 4021  4021 ' || true)"
  _eq_case "…the other process's entry is not in it" 0 \
    "$(mesh_pid_slice 4021 < "${tmp}/addr.logcat" | grep -c 'bt_stack' || true)"

  # A marker another process wrote under `flutter` is not the target's: only
  # the pid whose PHASE line names itself is loaded.
  {
    _entry 4021 I flutter "${MARK_PHASE} flag=on pid=4021"
    _entry 4021 I flutter "${MARK_TURN_ON} ended=failed ms=3 bt_on=missing start=unasked"
    _entry 555 I flutter "${MARK_TURN_ON} ended=on ms=1 bt_on=answered start=asked"
    _entry 555 I flutter "${MARK_PHASE} flag=off pid=4021"
    _entry 4021 I OtherTag "${MARK_TURN_ON} ended=on ms=1 bt_on=answered start=asked"
  } > "${tmp}/two.logcat"
  _eq_case "a later marker from another pid, or from the target under another tag, does not answer for it" failed \
    "$(mesh_field "${tmp}/two.logcat" "${MARK_TURN_ON}" ended)"
  _eq_case "…nor does a PHASE line that names a pid it was not written by" on \
    "$(mesh_field "${tmp}/two.logcat" "${MARK_PHASE}" flag)"

  _eq_case "a number is shown as it is" 4021 "$(mesh_show 4021)"
  _eq_case "…a known word too" not_found "$(mesh_show not_found)"
  _eq_case "…nothing stays nothing" "" "$(mesh_show '')"
  _eq_case "…and anything else, an address or a long number, is other" "other other other" \
    "$(mesh_show '22:22:AB:CD:EF:01') $(mesh_show 1234567890) $(mesh_show 'on; rm')"

  _eq_case "a service the platform has" present \
    "$(printf 'Service bluetooth_manager: found\n' | mesh_service_word bluetooth_manager)"
  _eq_case "…one it does not" absent \
    "$(printf 'Service bluetooth_manager: not found\n' | mesh_service_word bluetooth_manager)"
  _eq_case "…another service's answer is not this one's" unread \
    "$(printf 'Service bluetooth: found\n' | mesh_service_word bluetooth_manager)"
  _eq_case "…and silence is unread, never absent" unread "$(printf '' | mesh_service_word bluetooth_manager)"

  _eq_case "a buffer a shell is handed an entry of" yes \
    "$(printf -- '--------- beginning of main\n11-14 10:00:00.000  1234  1234 I ActivityManager: Start proc\nlane-rc 0\n' | mesh_buffer_read_word)"
  _eq_case "…one that is readable and holds nothing" empty \
    "$(printf -- '--------- beginning of crash\nlane-rc 0\n' | mesh_buffer_read_word)"
  _eq_case "…one the read fails on" no \
    "$(printf "logcat: Unable to open log device 'security': Operation not permitted\nlane-rc 1\n" | mesh_buffer_read_word)"
  _eq_case "…an error line with rc 0 is no entry" empty \
    "$(printf 'logcat: something it says\nlane-rc 0\n' | mesh_buffer_read_word)"
  _eq_case "…and a read that never reported" unread \
    "$(printf -- '--------- beginning of main\n' | mesh_buffer_read_word)"

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
  # With the address unread, a bare one cannot be searched for: every run of
  # exactly twelve hex digits goes — but not on Haven's own entries, where a
  # truncated id has that shape and the scanner must still see it.
  {
    _entry 900 D bt_stack 'own 2222abcdef01 and 2222ABCDEF01, not 2222abcdef0 nor 2222abcdef012'
    _entry 4021 I flutter 'id 2222abcdef01'
    echo 'no entry at all: 2222abcdef01'
  } > "${tmp}/hex.in"
  mesh_redact '' 'null' 4021 < "${tmp}/hex.in" > "${tmp}/hex.out"
  _eq_case "a bare twelve-digit run goes where the address was never read" \
    "2 0 1" \
    "$(sed -n 1p "${tmp}/hex.out" | grep -o '<hex12>' | grep -c . || true) $(sed -n 1p "${tmp}/hex.out" | grep -c '2222abcdef01 \|2222ABCDEF01,' || true) $(sed -n 3p "${tmp}/hex.out" | grep -c '<hex12>' || true)"
  _eq_case "…a run of eleven or thirteen is no address" 1 \
    "$(sed -n 1p "${tmp}/hex.out" | grep -c 'not 2222abcdef0 nor 2222abcdef012' || true)"
  _eq_case "…and Haven's own entry reaches the scanner as it was written" 1 \
    "$(grep -c ' 4021  4021 I flutter : id 2222abcdef01$' "${tmp}/hex.out" || true)"
  _eq_case "…with no pid named, every line is treated alike" 3 \
    "$(mesh_redact '' '' < "${tmp}/hex.in" | grep -c '<hex12>' || true)"

  # --- skeleton -------------------------------------------------------------
  # A UUID as a dump prints one, put together here: none is written out in a
  # tracked file (check_no_committed_secrets.sh reads that shape as a key).
  local uuid_parts=(0000fe01 0000 1000 8000 00805f9b34fb) uuid
  uuid="$(IFS=-; echo "${uuid_parts[*]}")"
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
    "    uuid=${uuid}" \
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
  _eq_case "…and writes its answers in fixed words" 3 \
    "$(printf '%s\n' "${MESH_ANSWERS[@]}" | grep -cxE 'probe\.bt_on=yes|probe\.le_feature=yes|probe\.turn_on_bluetooth_on=missing' || true)"
  _eq_case "…the buffers a shell cannot read as unread" 2 \
    "$(printf '%s\n' "${MESH_ANSWERS[@]}" | grep -cE '^probe\.buffer_(security|kernel)_kib=unread$' || true)"
  _fresh s2;    _oracle "S2 passes" s2 0
  _eq_case "…with the API gate exercised, on an image that has Bluetooth LE" "1 0" \
    "$(printf '%s\n' "${MESH_ANSWERS[@]}" | grep -cx 's2.api_gate_exercised=yes' || true) ${#MESH_LIMITS[@]}"
  _fresh probe
  _entry 555 I flutter "${MARK_TURN_ON} ended=on ms=1 bt_on=answered start=asked" >> "${tmp}/c.logcat"
  _oracle "a marker another process wrote does not answer for the target" probe 0

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
  _fresh s0; _drop logcat "D BluetoothGatt:"
  _oracle "S0: P1 absent beside P2 is red: a lever, or a platform that drops it" s0 1 'P1: a DEBUG line'
  _fresh s2; _drop logcat "D BluetoothGatt:"
  _oracle "S2: P1 absent beside P2 is a stated limit, not a pass and not a finding" s2 0
  _eq_case "…the limit says what was not exercised" 1 \
    "$(printf '%s\n' ${MESH_LIMITS[@]+"${MESH_LIMITS[@]}"} | grep -c 'was not exercised here' || true)"
  mesh_report s2 0 > "${tmp}/report.out" 2>&1
  _eq_case "…and the leg's verdict word is limited, with a notice on the run" "1 1" \
    "$(printf '%s\n' "${MESH_ANSWERS[@]}" | grep -cx 's2.verdict=limited' || true) $(grep -c '^::notice title=Mesh lane s2: passed with a stated limit::' "${tmp}/report.out" || true)"
  _fresh s2; _oracle "S2 with nothing left unjudged" s2 0
  mesh_report s2 0 > /dev/null 2>&1
  _eq_case "…is a plain pass" 1 "$(printf '%s\n' "${MESH_ANSWERS[@]}" | grep -cx 's2.verdict=pass' || true)"
  _fresh s2; _edit logcat 's/TURN_ON ended=failed/TURN_ON ended=on/' 'ended=on'
  _drop logcat "D BluetoothGatt:"
  mesh_run_oracle s2 "${tmp}/c.logcat" "${tmp}/c.events" "${tmp}/c.facts" || rc=$?
  mesh_report s2 1 > /dev/null 2>&1
  _eq_case "a limit beside a red is red, not limited" 1 "$(printf '%s\n' "${MESH_ANSWERS[@]}" | grep -cx 's2.verdict=red' || true)"

  # The image under S2 decides what S2 shows.
  _fresh s2; _edit facts 's/^le_feature=yes$/le_feature=no/' 'le_feature=no'
  _oracle "S2 on an image with no LE feature: the API gate was not exercised, and it says so" s2 0
  _eq_case "…as an answer and as a limit that names the JVM test's rule" "1 1" \
    "$(printf '%s\n' "${MESH_ANSWERS[@]}" | grep -cx 's2.api_gate_exercised=no' || true) $(printf '%s\n' ${MESH_LIMITS[@]+"${MESH_LIMITS[@]}"} | grep -c 'NOT exercised on a device' || true)"
  _fresh s2; _edit facts 's/^le_feature=yes$/le_feature=no/' 'le_feature=no'
  _edit logcat 's/supported=false permission/supported=true permission/' 'supported=true permission'
  _oracle "S2: supported with no LE feature is red all the same" s2 1 'must answer false there'
  _fresh s2; _edit facts 's/^le_feature=yes$/le_feature=unread/' 'le_feature=unread'
  _oracle "S2: an image nobody could read the feature of is unusable" s2 3 'declares Bluetooth LE could not be read'
  _fresh s2; _drop facts 'le_feature='
  _oracle "S2: …or never asked" s2 3 'declares Bluetooth LE could not be read'
  _fresh s0; _edit facts 's/^le_feature=yes$/le_feature=no/' 'le_feature=no'
  _oracle "S0 does not depend on the feature" s0 0
  _fresh s0; _edit logcat 's/bt_on=unasked/bt_on=missing/' 'bt_on=missing'
  _oracle "S0: a flag-off turn-on that asked the radio is red" s0 1 "asked the radio 'bluetoothOn'"
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
    _fresh "${leg}"; _edit logcat 's/bt_on=missing/bt_on=unasked/' 'bt_on=unasked'
    _oracle "${leg}: a turn-on that failed before it asked bluetoothOn is unusable" "${leg}" 3 "without ever asking 'bluetoothOn'"
    _fresh "${leg}"; _edit logcat 's/ bt_on=missing start=unasked//' 'ended=failed ms=412'
    _oracle "${leg}: a turn-on that did not report where it ended is not taken as ended there" "${leg}" 3 'did not report where its turn-on ended'
    _fresh "${leg}"; _edit logcat 's/bt_on=missing/bt_on=answered/' 'bt_on=answered'
    _oracle "${leg}: bluetoothOn answered during a turn-on is red" "${leg}" 1 "'bluetoothOn' was ANSWERED"
    _fresh "${leg}"; _edit logcat 's/ended=failed ms=412/ended=skipped ms=0/' 'ended=skipped'
    _oracle "${leg}: a turn-on not asked is unusable" "${leg}" 3 'was not asked'
  done
  _fresh probe; _edit logcat 's/shell=1 button=1/shell=1 button=0/' 'button=0'
  _oracle "the probe: no button on a phone that can run the mesh is red" probe 1 'it must draw one'
  _fresh probe; _edit logcat 's/supported=true permission/supported=false permission/' 'supported=false permission'
  _oracle "the probe: supported false beside an LE feature is red" probe 1 'the two must agree'

  # --- nothing a capture held is printed --------------------------------------
  # A value that is no number and no known word reaches a sentence as `other`:
  # a marker's field, a fact, the host's pid.
  _shown() { # <label> — the findings of the last oracle run hold no planted value
    _eq_case "$1" 0 "$(printf '%s\n' ${MESH_RED[@]+"${MESH_RED[@]}"} ${MESH_BROKEN[@]+"${MESH_BROKEN[@]}"} ${MESH_UNUSABLE[@]+"${MESH_UNUSABLE[@]}"} ${MESH_LIMITS[@]+"${MESH_LIMITS[@]}"} "${MESH_ANSWERS[@]}" | grep -c 'AA:BB\|EE:07' || true)"
  }
  _fresh s0; _edit logcat 's/flag=off/flag=AA:BB:CC:DD:EE:07/' 'flag=AA:BB:CC:DD:EE:07'
  _oracle "a flag that is no word is the wrong build" s0 2 "reads 'other'"
  _shown "…and is not printed"
  _fresh probe; _edit facts 's/^am_fgs=not_found$/am_fgs=AA:BB:CC:DD:EE:07/' 'am_fgs=AA:BB'
  _oracle "a fact that is no word is not the platform saying none exists" probe 1 'am_fgs=other'
  _shown "…and is not printed"
  _fresh s2; _edit facts 's/^pid_host=4021$/pid_host=AA:BB:CC:DD:EE:07/' 'pid_host=AA:BB'
  _oracle "a host pid that is no number is not the target's" s2 3 "read pid 'other'"
  _shown "…and is not printed"
  _fresh probe; _edit logcat 's/ended=failed ms=412/ended=AA:BB:CC:DD:EE:07 ms=412/' 'ended=AA:BB'
  _oracle "a turn-on that ended in no known word did not end failed" probe 1 "a turn-on ended 'other'"
  _shown "…and is not printed"

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
  local more priority
  for more in "${MORE_PLANTS[@]}"; do
    case "${more%%:*}" in p1v) priority=_priorityVerbose ;; p1e) priority=_priorityError ;; *) priority=_priorityDebug ;; esac
    _eq_case "the target's ${more%%:*} is planted under the tag this runner reads it by" 1 \
      "$(grep -cF -- "('${more%%:*}', ${priority}, '${more##*:}')," "${target}" || true)"
  done
  _eq_case "the target reports where its turn-on ended in the fields this runner reads" 2 \
    "$(grep -cE "bt_on=\\\$bluetoothOn start=\\\$start'" "${target}" || true)"

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
  local gate_lit='logscan_gate host /tmp/haven-soak/needles "${SEAL_EXTRA[@]}" --     --sink "logcat=${device_logs}"     --sink "drive=${drive_log}" --report "${LOGSCAN_REPORTS}/gate-${leg}.ndjson" || gate_rc=$?'
  _eq_case "the gate names the device captures and the drive log" 1 \
    "$(awk -v lit="${gate_lit}" 'index($0, lit) == 3 { n++ } END { print n + 0 }' <<<"${scope}")"
  _eq_case "…the device log always, and the slice of the events buffer where one was published" 2 \
    "$(grep -cE '^  local device_logs="\$\{LOG_DIR\}/logcat\.\$\{leg\}\.log"$|^    device_logs\+=",\$\{LOG_DIR\}/logcat-events\.\$\{leg\}\.log"$' <<<"${scope}" || true)"
  _eq_case "what the gate is handed is the redacted copy, never the raw capture" 0 \
    "$(grep -cE 'logscan_gate(_dir)? .*RAW_DIR' <<<"${joined}" || true)"
  _eq_case "the raw captures are written under RAW_DIR alone" 0 \
    "$(grep -cE 'adb .*(logcat -v|dumpsys) .*> *"\$\{LOG_DIR\}' <<<"${joined}" || true)"
  # What is read of the platform is read whatever became of the target; what
  # is read of the app, only at its cue.
  local leg_scope cue_at wait_at app_at platform_at
  leg_scope="$(sed -n '/^run_leg() {/,/^}/p' <<<"${joined}")"
  cue_at="$(grep -nE '^  if wait_for_marker "\$\{MARK_READY\}"' <<<"${leg_scope}" | cut -d: -f1 | head -n 1 || true)"
  wait_at="$(grep -nE '^  wait "\$\{DRIVE_PID\}"' <<<"${leg_scope}" | cut -d: -f1 | head -n 1 || true)"
  app_at="$(grep -nE '^    inspect_app "\$\{leg\}"$' <<<"${leg_scope}" | cut -d: -f1 | head -n 1 || true)"
  platform_at="$(grep -nE '^    inspect_platform "\$\{leg\}"$' <<<"${leg_scope}" | cut -d: -f1 | head -n 1 || true)"
  rc=0
  [[ -n "${cue_at}" && -n "${wait_at}" && -n "${app_at}" && -n "${platform_at}" ]] \
    && (( cue_at < app_at && app_at < wait_at && wait_at < platform_at )) || rc=1
  _case "the app is read at its cue, and the platform after the drive whatever became of it" 0 "${rc}"
  _eq_case "…the platform's reading is under no condition but the leg's name" 1 \
    "$(grep -B2 -E '^    inspect_platform "\$\{leg\}"$' <<<"${leg_scope}" | grep -cE '^  if \[\[ "\$\{leg\}" == probe \]\]; then$' || true)"
  _eq_case "…and whether the cue came is recorded either way" "1 1" \
    "$(grep -cE '^    record ready yes$' <<<"${leg_scope}" || true) $(grep -cE '^    record ready no$' <<<"${leg_scope}" || true)"
  _eq_case "a leak is laid at the gate that found it, in the run's last word" 1 \
    "$(grep -cF -- 'mesh_leak_message "${LEAK_LEGS[*]-}" "${scan_rc}"' <<<"$(sed -n '/^cleanup() {/,/^}/p' <<<"${joined}")" || true)"
  _eq_case "…a leg whose own gate found one being remembered" 1 \
    "$(grep -cE '^  if \(\( gate_rc == 1 \)\); then LEAK_LEGS\+=\("\$\{leg\}"\); fi$' <<<"${scope}" || true)"
  _eq_case "why a failed drive ended is read from the RAW transcript, which is never withheld" 1 \
    "$(grep -cF -- 'done < <(mesh_failure_facts "${raw_drive}" "${raw_device}"' <<<"${scope}" || true)"
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
  # What is published of a leg: the device log whole and redacted, of the
  # events buffer only what Haven's pid wrote, the transcript as Haven wrote it.
  local rawdir="${tmp}/rawdir"
  mkdir -p "${rawdir}"
  _fresh probe
  cp "${tmp}/c.logcat" "${rawdir}/logcat.probe.raw"
  {
    cat "${tmp}/c.events"
    _entry 1200 I am_proc_start '[0,5678,10123,com.example.other,activity,{com.example.other/.Main}]'
    _entry 900 I bluetooth_event 'own 2222abcdef01'
  } > "${rawdir}/events.probe.raw"
  printf '%s\n' '00:03 +1: All tests passed!' 'I/flutter ( 4021): handle 2222abcdef01' > "${rawdir}/drive.probe.raw"
  mesh_publish probe "${rawdir}" "${dir}" '' 'null' 4021
  _eq_case "of the events buffer, only what Haven's pid wrote is published" "1 0" \
    "$(grep -c '' "${dir}/logcat-events.probe.log" || true) $(grep -cE 'am_proc_start|bluetooth_event|com\.example' "${dir}/logcat-events.probe.log" || true)"
  _eq_case "…which is the planted event" 1 "$(grep -c "${T3}" "${dir}/logcat-events.probe.log" || true)"
  _eq_case "the device log is published whole" "$(grep -c '' "${tmp}/c.logcat")" \
    "$(grep -c '' "${dir}/logcat.probe.log" || true)"
  _eq_case "the transcript reaches the scanner as Haven wrote it" 1 \
    "$(grep -c 'handle 2222abcdef01' "${dir}/flutter-drive.probe.log" || true)"
  mkdir -p "${tmp}/nopid" "${tmp}/quiet"
  mesh_publish probe "${rawdir}" "${tmp}/nopid" '' '' ''
  _eq_case "with no pid known, nothing of the events buffer is published" 0 \
    "$(find "${tmp}/nopid" -name 'logcat-events.*' | grep -c . || true)"
  mesh_publish probe "${rawdir}" "${tmp}/quiet" '' '' 7777
  _eq_case "a pid that wrote no event publishes no empty file" 0 \
    "$(find "${tmp}/quiet" -name 'logcat-events.*' | grep -c . || true)"
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

  # The four suites started above.
  local suite_checks suite_fails
  wait
  for suite in s0 probe s2 answers; do
    grep -v '^__suite ' "${tmp}/suite-${suite}.out" || true
    read -r _ suite_checks suite_fails < <(grep '^__suite ' "${tmp}/suite-${suite}.out" || echo "__suite 0 1")
    checks=$(( checks + suite_checks ))
    if (( suite_fails != 0 || suite_checks == 0 )); then
      echo "  FAIL the ${suite} suite did not finish clean (${suite_checks} checks)" >&2
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
  echo "usage: run-mesh-lever.sh <s0|probe|s2>... | --self-test" >&2
  exit 2
}
(( $# > 0 )) || usage
for leg in "$@"; do
  case "${leg}" in
    s0|probe|s2) ;;
    *) usage ;;
  esac
done
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
# The legs that passed with a limit, and the legs whose own gate found a leak.
LIMITED_LEGS=()
LEAK_LEGS=()
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

# publish_leg <leg> — mesh_publish over the leg's captures, for the pid the
# host read or, where it read none, the one the target named.
publish_leg() {
  local leg="$1" pid
  pid="$(mesh_known "${RAW_DIR}/facts.${leg}" pid_host)"
  if [[ ! "${pid}" =~ ^[0-9]+$ ]]; then
    pid="$(mesh_show "$(mesh_field "${RAW_DIR}/logcat.${leg}.raw" "${MARK_PHASE}" pid)")"
  fi
  mesh_publish "${leg}" "${RAW_DIR}" "${LOG_DIR}" "${BT_LABEL}" "${BT_ADDR}" "${pid}"
  OPEN_LEG=""
}

# write_verdict — the answers of every leg judged, one `<leg>.<key>=<value>`
# a line.
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
  docker logs "${STRFRY_CONTAINER}" > "${LOG_DIR}/strfry.final.log" 2>&1 || true
  write_verdict
  echo "== Log-privacy scan over ${LOG_DIR} (Security Rules 6 and 15) =="
  logscan_gate_dir host /tmp/haven-soak/needles "${LOG_DIR}" "${LOGSCAN_REPORTS}/exit-${RUN_NAME}.ndjson" "${SEAL_EXTRA[@]}" \
    || scan_rc=$?
  if (( scan_rc == 1 || LOGSCAN_GATE_RC == 1 )); then
    {
      echo "Logs withheld: the log-privacy gate tripped (Security Rules 6 and 15)."
      echo "See the LEAK line(s) in the step log for file/label/line numbers."
    } > "${LOG_DIR}/LEAK_DETECTED.txt"
    echo "ERROR: $(mesh_leak_message "${LEAK_LEGS[*]-}" "${scan_rc}") What was scanned is deleted, not uploaded." >&2
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
  bash "${STOP_STRFRY}" >/dev/null 2>&1 || true
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

# inspect_app <leg> — the host's reading of the APP, while the target is
# alive and holding. Every answer is a fixed word or a count; every dump
# stays in RAW_DIR.
inspect_app() {
  local leg="$1" state count more
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
}

# inspect_platform <leg> — the probe's reading of the PLATFORM. None of it is
# asked of Haven's app, so it is read after the drive whatever became of the
# target: a probe whose target died still says what a shell can read here
# (CI run 43586443164 read "0 of five buffers" of a device that was never
# asked).
inspect_platform() {
  local leg="$1" value buffer
  # Whether a shell can set the property the lever's lane will set. After the
  # drive, so that P1 was written with no property; cleared again.
  adb -s "${DEVICE}" shell setprop log.tag.BluetoothGatt VERBOSE >/dev/null 2>&1 || true
  value="$(adb -s "${DEVICE}" shell getprop log.tag.BluetoothGatt 2>/dev/null | tr -d '\r' | head -n 1 || true)"
  if [[ "${value}" == VERBOSE ]]; then record setprop_log_tag yes; else record setprop_log_tag no; fi
  adb -s "${DEVICE}" shell setprop log.tag.BluetoothGatt '""' >/dev/null 2>&1 || true

  # Bluetooth is on by now if it comes on at all, so the settings hold what
  # they will hold.
  read_adapter_identity
  record adapter_address_readable "$(mesh_settings_word <<<"${BT_ADDR}")"
  record adapter_address_shape "$(mesh_addr_shape "${BT_ADDR}")"
  record adapter_label_readable "$(mesh_settings_word <<<"${BT_LABEL}")"

  for buffer in "${PROBED_BUFFERS[@]}"; do
    record "buffer_${buffer}_kib" "$(adb -s "${DEVICE}" shell logcat -g -b "${buffer}" 2>&1 | mesh_logcat_g_kib || true)"
    # …and whether a shell is handed an entry of it, which the size does not
    # say.
    record "buffer_${buffer}_read" "$(adb -s "${DEVICE}" shell "logcat -v threadtime -d -b ${buffer} -t 1; echo lane-rc \$?" 2>&1 | mesh_buffer_read_word || true)"
  done

  # The three dumps the lever's parsers will read, as skeletons. The services
  # dump is the whole device's, not Haven's alone: a record's shape is what is
  # wanted, and Haven has none to show.
  adb -s "${DEVICE}" shell dumpsys activity services > "${RAW_DIR}/services-all.${leg}.dump" 2>&1 || true
  adb -s "${DEVICE}" shell dumpsys notification > "${RAW_DIR}/notification-all.${leg}.dump" 2>&1 || true
  adb -s "${DEVICE}" shell dumpsys bluetooth_manager > "${RAW_DIR}/bluetooth-all.${leg}.dump" 2>&1 || true
  keep_skeleton "${leg}" dump_services activity-services "${RAW_DIR}/services-all.${leg}.dump"
  keep_skeleton "${leg}" dump_notification notification "${RAW_DIR}/notification-all.${leg}.dump"
  keep_skeleton "${leg}" dump_bluetooth bluetooth-manager "${RAW_DIR}/bluetooth-all.${leg}.dump"
}

# report_leg <leg> <drive-rc> — publishes the leg's captures, gates them, and
# only then echoes the drive log. Records whether the drive failed, and where
# it did prints why in closed shapes: the transcript may be withheld.
report_leg() {
  local leg="$1" drc="$2" gate_rc=0 line said=0
  local drive_log="${LOG_DIR}/flutter-drive.${leg}.log"
  local device_logs="${LOG_DIR}/logcat.${leg}.log"
  local raw_drive="${RAW_DIR}/drive.${leg}.raw" raw_device="${RAW_DIR}/logcat.${leg}.raw"
  publish_leg "${leg}"
  if [[ -s "${LOG_DIR}/logcat-events.${leg}.log" ]]; then
    device_logs+=",${LOG_DIR}/logcat-events.${leg}.log"
  fi
  echo "== ${leg}: the leg's own log-privacy gate (its device log, events slice and drive transcript) =="
  logscan_gate host /tmp/haven-soak/needles "${SEAL_EXTRA[@]}" -- \
    --sink "logcat=${device_logs}" \
    --sink "drive=${drive_log}" --report "${LOGSCAN_REPORTS}/gate-${leg}.ndjson" || gate_rc=$?
  if (( gate_rc == 1 || LOGSCAN_GATE_RC == 0 )); then
    LOGSCAN_GATE_RC="${gate_rc}"
  fi
  if (( gate_rc == 1 )); then LEAK_LEGS+=("${leg}"); fi
  if (( gate_rc == 0 )); then
    cat "${drive_log}" || true
  else
    echo "${leg} drive log withheld from the step log — the ${leg} leg's own log-privacy gate ended rc ${gate_rc}." >&2
  fi
  if (( drc != 0 )) || drive_log_reports_test_failure "${raw_drive}"; then
    record drive_failed yes
    echo "  the ${leg} drive did not complete cleanly (flutter drive rc ${drc}). What its transcript and the target's own lines say of it, in closed shapes:" >&2
    while IFS= read -r line; do
      [[ -n "${line}" ]] || continue
      echo "  mesh-failure (${leg}): ${line}" >&2
      said=1
    done < <(mesh_failure_facts "${raw_drive}" "${raw_device}" "$(mesh_show "$(mesh_field "${raw_device}" "${MARK_PHASE}" pid)")")
    (( said )) || echo "  mesh-failure (${leg}): nothing of a known shape — no thrown type, assertion or stack frame in the transcript or under the target's pid." >&2
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
  if (( rc == 0 && ${#MESH_LIMITS[@]} > 0 )); then LIMITED_LEGS+=("${leg}"); fi
  worst_rc "${VERDICT_RC}" "${rc}" || VERDICT_RC=$?
}

# run_leg <leg> — one drive of the target, inspected while it holds, judged
# over its complete captures.
run_leg() {
  local leg="$1" apk="${APK_ON}" drc=0 oracle_rc=0 perm settled=0
  LEG_STARTED="$(date +%s)"
  FACTS="${RAW_DIR}/facts.${leg}"
  : > "${FACTS}"
  if [[ "${leg}" == s0 ]]; then apk="${APK_OFF}"; fi

  # What the image is, asked of the platform before anything is installed:
  # what a leg can show depends on it. An image with no Bluetooth service has
  # no Bluetooth manager to ask anything of.
  record le_feature "$(adb -s "${DEVICE}" shell pm list features 2>/dev/null | mesh_feature_word android.hardware.bluetooth_le || true)"
  record bt_service "$(adb -s "${DEVICE}" shell service check bluetooth_manager 2>&1 | mesh_service_word bluetooth_manager || true)"
  if [[ "${leg}" == probe ]]; then
    enable_bluetooth
  fi

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
    record ready yes
    echo "== ${leg}: inspecting the app while the target holds =="
    inspect_app "${leg}"
    adb -s "${DEVICE}" shell "run-as ${PKG} touch ${RELEASE_FILE}" >/dev/null 2>&1 \
      || echo "  WARN: the release file could not be made; the target will run out its hold." >&2
  else
    record ready no
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

  if [[ "${leg}" == probe ]]; then
    echo "== ${leg}: reading the platform (no app needed) =="
    inspect_platform "${leg}"
  fi

  report_leg "${leg}" "${drc}"

  echo "== ${leg}: the oracle =="
  mesh_run_oracle "${leg}" "${RAW_DIR}/logcat.${leg}.raw" "${RAW_DIR}/events.${leg}.raw" "${FACTS}" || oracle_rc=$?
  fold_leg "${leg}" "${oracle_rc}"
}

echo "Starting hermetic strfry..."
bash "${START_STRFRY}"
adb -s "${DEVICE}" wait-for-device

for leg in "$@"; do
  run_leg "${leg}"
done

case "${VERDICT_RC}" in
  0)
    if (( ${#LEAK_LEGS[@]} > 0 )); then
      echo "MESH LANE RED (${RUN_NAME}) — the oracle found nothing broken, and a leg's own log-privacy gate found a leak (${LEAK_LEGS[*]}): see the ERROR below." >&2
    elif (( ${#LIMITED_LEGS[@]} > 0 )); then
      echo "MESH LANE PASS WITH A STATED LIMIT (${RUN_NAME}; limited: ${LIMITED_LEGS[*]}) — everything that could be judged on this image held, and what could NOT be judged is in the LIMIT line(s) above. That part is not proved by this run."
    else
      echo "MESH LANE PASS (${RUN_NAME}) — every promise of push A held and every measurement was taken."
    fi
    ;;
  1) echo "MESH LANE RED (${RUN_NAME}) — a promise of push A is broken; see the RED line(s) above." >&2 ;;
  2) echo "MESH LANE BROKEN (${RUN_NAME}) — the lane drove the wrong thing; see the BROKEN line(s) above." >&2 ;;
  *) echo "MESH LANE UNUSABLE (${RUN_NAME}) — the platform or the capture would not answer; nothing was proved. See the UNUSABLE line(s) above." >&2 ;;
esac
exit "${VERDICT_RC}"
