#!/usr/bin/env bash
#
# The ONE place an Android E2E lane puts the Haven APK on the emulator. SOURCED
# by the lane runners; run directly only for --self-test and --check-installs.
#
# ## The race it closes (docs/E2E_TROUBLESHOOTING.md, failure mode 11)
#
# A FRESH install's PACKAGE_ADDED makes OverlayManagerService recompute the new
# package's overlay paths — always, for a newly added package — and since they
# change on this image (none -> the framework overlays), it tells
# ActivityManager, which bumps the asset sequence of the package's visible
# activities: a configuration change no manifest can absorb, so MainActivity is
# relaunched. FlutterActivity destroys its engine on the way out, and with it
# the isolate `flutter drive` is attached to; the new activity boots a second
# engine that runs the suite again from main() with no driver listening. After
# connect `requestData` is never answered and the drive hangs to its cap —
# app_test in CI run 34511084722, whose second engine printed "All tests
# passed!" to nobody. Before connect the same relaunch is the Collected
# sentinel run-single-avd-scenario.sh's is_connect_flake retries.
#
# That needs the broadcast to still be queued once the app is on screen, and a
# freshly booted emulator's queue backs up behind post-boot churn: the install's
# broadcasts were handed over 2.8 s after it in green run 34488512808 (0.4 s
# before `am start`), 13.6 s after it in red run 34511084722 (0.5 s after
# MainActivity was first displayed), and 34 s after it in 34488512808's FGS lane.
#
# ## What this does about it
#
# Nothing returns until the install's broadcasts have been handed to their
# receivers. PackageManagerService posts the PACKAGE_ADDED send to its own
# handler and only then answers the installer (android-14.0.0_r1,
# InstallPackageHelper.handlePackagePostInstall), so as `adb install` returns the
# broadcast may not exist yet. `cmd package wait-for-handler` drains that handler
# first, so the send has reached ActivityManager; `am wait-for-broadcast-barrier
# --flush-broadcast-loopers` then waits for its delivery. The flush alone is not
# enough: BroadcastLoopers registers a looper only once it has sent a broadcast,
# which on a freshly booted guest the package manager's may not have. What
# neither can reach are the in-process hops after hand-over (FgThread, the
# overlay manager's own thread, FgThread again), which nothing outside
# system_server can wait on: a margin of everything between here and the
# drive's launch, not a barrier.
#
# ## Why the guest is asked for its own exit codes
#
# Nothing here branches on a number adb reports or a word a framework prints —
# no run of this lane has ever shown us either. The same round trip asks the
# guest to print the two commands' OWN exit codes, and to reject two commands it
# cannot have: rc 0 from a command that does not exist reads exactly like rc 0
# from one that ran, so a shell that answered 0 to everything is the one shape
# that would make this whole file a no-op nobody could see. Anything but both
# zeros with both controls refused is a refusal, named. The four codes are
# printed on success, so every lane's log carries the evidence instead of this
# comment asserting it.
#
# MEASURED, run 35524002720 (2026-09-20), twelve Android lane jobs: `adb install
# -r` answers "Performing Streamed Install"/"Success" with rc 0; the probe reads
# a `package:` line for an installed package (M7's replaces) and nothing for an
# absent one (every lane's fresh install, after its uninstall); and the chain
# returned success in 0.3-14.8 s against the 120 s bound, worst case the
# KeyPackage-rotation lane. UNMEASURED, and so relied on nowhere: what either
# command's rc or text is when it is NOT understood.
#
# ONLY after a fresh install. A REPLACE is a no-op to the overlay manager for a
# package that neither declares nor is targeted by an overlay — which is why
# `flutter drive`'s own reinstall (its installApp never skips) relaunches
# nothing — so install_app decides by whether the package was on the device
# before it installed. Its probe can only err towards the barrier: anything but
# a `package:` line reads as absent.
#
# FAIL CLOSED, never best-effort. A failed install, a barrier command this
# runner could not execute at all, a device that cannot run the barrier (the
# commands arrived in API 34), a guest that reports no exit codes or answers 0
# to a command it cannot have, and a queue still backed up after
# INSTALL_BARRIER_SECS each return non-zero with the reason named, and the
# caller fails the lane: driving anyway is the silent ten-minute hang this
# exists to remove. The bound is ~3.5x the worst backlog above, and it is a term
# in every lane's worst case, which is why it is a constant here and not an
# argument: no lane can tighten it to fit a budget.
#
# ## Usage
#
#   source "${SCRIPT_DIR}/app-install-lib.sh"
#   install_fresh "${DEVICE}" "${APK}" || fail "..."  # clears any prior install
#   install_app   "${DEVICE}" "${APK}" || fail "..."  # installs over it, if any
#
#   bash tooling/e2e/ci/app-install-lib.sh --self-test                # stub adb
#   bash tooling/e2e/ci/app-install-lib.sh --check-installs [<root>]  # the pin

readonly INSTALL_BARRIER_SECS=120
readonly APP_INSTALL_PKG='com.oblivioustech.haven'

# The line the barrier's round trip asks the guest to print: the handler drain's
# exit code, the barrier's, then the two unknown-command controls'.
readonly _APP_INSTALL_VERDICT_RE='^haven-barrier-rc ([0-9]+) ([0-9]+) ([0-9]+) ([0-9]+)$'

_APP_INSTALL_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# _app_install_present <device> — 0 iff the package is installed on <device>.
_app_install_present() {
  local out
  out="$(adb -s "$1" shell pm path "${APP_INSTALL_PKG}" 2>/dev/null \
    | tr -d '\r')" || true
  grep -q '^package:' <<<"${out}"
}

# install_app <device> <apk> — install <apk> over whatever is on <device>. When
# the package was absent the install is fresh, and its broadcasts are flushed
# before this returns. Non-zero, with the reason on stderr, otherwise.
#
# Explicit returns throughout: callers run this from `||` or `if !`, where
# errexit no longer reaches inside.
install_app() {
  local device="$1" apk="$2" fresh=1 rc=0 out verdict
  local drain barrier ctl_cmd ctl_am
  if _app_install_present "${device}"; then
    fresh=0
    echo "  installing ${apk} over the installed ${APP_INSTALL_PKG} (a replace:" \
         "its data stays, and no barrier is needed)..."
  else
    echo "  installing ${apk} fresh..."
  fi
  adb -s "${device}" install -r "${apk}" || rc=$?
  if (( rc != 0 )); then
    echo "ERROR: adb install -r ${apk} failed on ${device} (rc=${rc})." >&2
    return 1
  fi
  if (( fresh == 0 )); then
    return 0
  fi
  # An installer's rc is not evidence that the app is there; the probe is. WHICH
  # adb answers 0 for an install that did not land is UNMEASURED — asking costs
  # one round trip, and a fresh install that did not land would leave `flutter
  # drive` to make the fresh, unflushed one.
  if ! _app_install_present "${device}"; then
    echo "ERROR: adb install -r ${apk} reported success, but" \
         "${APP_INSTALL_PKG} is not on ${device}." >&2
    return 1
  fi
  echo "  fresh install: flushing its broadcasts (up to ${INSTALL_BARRIER_SECS} s)..."
  # `;` and not `&&`, so a half that fails still reports its own code rather
  # than vanishing into a short circuit. The controls' output is dropped on the
  # guest — nothing reads it, and an unrecognised command may answer with its
  # whole help text.
  #
  # What the controls rest on is read from source, not yet seen on a lane: both
  # `cmd package` and `am` (a wrapper over `cmd activity`) fall through to
  # BasicShellCommandHandler.handleDefaultCommands, which prints "Unknown
  # command: <cmd>" and returns -1, and cmd.cpp returns that result as the exit
  # status (255). A guest that answers otherwise is refused below WITH the codes
  # it gave, so one run settles it either way.
  out="$(timeout "${INSTALL_BARRIER_SECS}" adb -s "${device}" shell \
    "cmd package wait-for-handler --timeout $(( INSTALL_BARRIER_SECS * 1000 ))" \
    '; h=$?; am wait-for-broadcast-barrier --flush-broadcast-loopers; b=$?;' \
    'cmd package haven-not-a-command >/dev/null 2>&1; c=$?;' \
    'am haven-not-a-command >/dev/null 2>&1; a=$?;' \
    'echo; echo "haven-barrier-rc $h $b $c $a"' 2>&1)" || rc=$?
  # The probe strips these for the same reason: an adb shell can hand back CRLF.
  out="${out//$'\r'/}"
  if (( rc == 124 )); then
    echo "ERROR: the fresh install's broadcasts were still queued after" \
         "${INSTALL_BARRIER_SECS} s. Launching now would let a late" \
         "PACKAGE_ADDED relaunch MainActivity under the driver" \
         "(docs/E2E_TROUBLESHOOTING.md failure mode 11); treating ${device}" \
         "as wedged. Its last words: ${out:-<none>}" >&2
    return 1
  fi
  # The chain ends in an `echo`, so no guest-side failure can reach adb's own
  # exit status: 125-127 is this runner failing to execute the command at all,
  # as `timeout … adb` did in eight of run 35536892150's thirteen Android lane
  # jobs, with adb off the PATH.
  if (( rc >= 125 && rc <= 127 )); then
    echo "ERROR: nothing was asked of ${device}: the install barrier could not" \
         "be run here at all (exit ${rc} — timeout's own usage, or a command" \
         "that could not be executed). That is this runner's tooling." >&2
    return 1
  fi
  if (( rc != 0 )); then
    echo "ERROR: adb could not run the install barrier on ${device} (exit" \
         "${rc}): ${out}. Refusing to drive an unflushed fresh install." >&2
    return 1
  fi
  verdict="$(awk '/^haven-barrier-rc /{ v = $0 } END { print v }' <<<"${out}")"
  if [[ ! "${verdict}" =~ ${_APP_INSTALL_VERDICT_RE} ]]; then
    echo "ERROR: ${device} exited 0 without reporting what the barrier's own" \
         "commands returned, so nothing here can say its broadcasts were" \
         "flushed. Its words: ${out:-<none>}" >&2
    return 1
  fi
  drain="${BASH_REMATCH[1]}"
  barrier="${BASH_REMATCH[2]}"
  ctl_cmd="${BASH_REMATCH[3]}"
  ctl_am="${BASH_REMATCH[4]}"
  # MEASURED before it became a refusal: every Android lane of CI run
  # 35664400984 (twelve, api-34 google_apis x86_64) printed
  # `unknown-command control rc 255/255` — the -1 AOSP's
  # BasicShellCommandHandler.handleDefaultCommands returns, as cmd.cpp exits it.
  # A guest that answers 0 here makes the barrier's own 0 worthless, so the
  # install is refused rather than driven into the race this file exists to
  # remove. The codes are printed so a new image that differs is diagnosable
  # from the log, not from a guess.
  if (( ctl_cmd == 0 || ctl_am == 0 )); then
    echo "ERROR: ${device} answered 0 to a command it cannot have (cmd" \
         "${ctl_cmd}, am ${ctl_am}), so the install barrier's own 0 proves" \
         "nothing about a command this guest may equally not have. Refusing" \
         "to drive an install whose broadcasts may not have flushed." >&2
    return 1
  fi
  if (( drain != 0 || barrier != 0 )); then
    echo "ERROR: the install barrier failed on ${device}: the package-manager" \
         "handler drain exited ${drain} and the broadcast barrier exited" \
         "${barrier}. A guest that predates either command reports non-zero;" \
         "refusing to drive an unflushed fresh install." >&2
    return 1
  fi
  echo "  install broadcasts flushed (handler/barrier rc ${drain}/${barrier}," \
       "unknown-command control rc ${ctl_cmd}/${ctl_am})."
}

# install_fresh <device> <apk> — clear any prior install, then install_app,
# whose install is therefore fresh. What it clears is a sticky foreground
# service from an earlier target, which `install -r` keeps and reconnects to the
# next engine (run-single-avd-scenario.sh, Phase 2), and that target's data. A
# missing package fails both clearing commands, so their exit codes cannot tell
# a failed clear from nothing to clear; the probe after them can.
install_fresh() {
  local device="$1" apk="$2"
  echo "  clearing any prior ${APP_INSTALL_PKG} on ${device}..."
  adb -s "${device}" shell am force-stop "${APP_INSTALL_PKG}" || true
  adb -s "${device}" uninstall "${APP_INSTALL_PKG}" >/dev/null 2>&1 || true
  if _app_install_present "${device}"; then
    echo "ERROR: ${APP_INSTALL_PKG} is still on ${device} after its uninstall;" \
         "installing over it would keep the earlier target's data and any" \
         "sticky foreground service." >&2
    return 1
  fi
  install_app "${device}" "${apk}"
}

# ---------------------------------------------------------------------------
# --check-installs — the structural pin.
#
# The barrier only protects a lane that installs through this file, so this
# asserts that every one does, over the Android lanes' shell (tooling/e2e/ci)
# and their workflows:
#
#   R1  Nothing outside this file installs the app: no `adb … install*`,
#       `pm install*`, `cmd package install*` or `flutter … install`.
#   R2  Nothing outside this file defines install_fresh, install_app or an
#       `_app_install_*` helper. A copy is how one implementation becomes seven
#       again, and a sourcing lane's redefinition would silently replace this.
#   R3  Every run-*.sh that talks to adb and launches the app with `flutter
#       drive`, `flutter test` or `flutter run` (global options before the
#       subcommand included) calls install_fresh or
#       install_app. With nothing on the device the launcher's own install is
#       the fresh one, and it is unflushed. (The adb condition is what keeps the
#       iOS runners, which launch with `flutter test -d <udid>`, out.)
#
# WHERE THE LINE IS. Shell is read through _app_install_code: comments, heredoc
# bodies and quoted words are text, so a comment, a message or a fixture that
# NAMES an install never fires; `$( … )` inside double quotes is code, and a
# backslash-continued command is one command, so neither hides one. Workflows
# are read line by line with comments removed: their strings are shell the
# runner executes, so none is exempt. `flutter drive`'s own replace is not an
# install here. R3 asks that a lane which launches the app also calls this
# file's install — presence, not order, which a lexical check cannot establish.
#
# What a lexical check cannot see: an install behind `eval`, `bash -c` or a
# variable, a path, a function or an alias standing in for `adb`, `flutter` or
# one of this file's functions; a quoted subcommand (`adb … "install"`); one
# inside `$( … )` in an unquoted heredoc body, or in a heredoc fed to `bash` or
# `adb shell`; a device-side `pm install` quoted into a single `adb shell "…"`
# argument; a workflow command split over lines (a `\` continuation, a folded
# `>` scalar); a launch from a file not named run-*.sh (a sourced helper, a
# delegated script); a lane that names the install without calling it
# (`type install_app`); and a few constructs the lexer misreads — a `case`
# pattern inside `"$( … )"`, a heredoc opened on a continued line,
# `"${x:-"…"}"`, a word that runs on past a `$( … )` or an escaped space into
# `#…` (read as a comment), an arithmetic `<< name` that a later line happens
# to terminate. A file that ends inside a quoted word
# or a heredoc cannot be read at all, and is rc 2, never a pass.
#
# Exit: 0 clean, 1 a violation, 2 the check itself cannot run.
# ---------------------------------------------------------------------------

# `flutter` and any global options before its subcommand (`-v`, `-d <id>`).
readonly _APP_INSTALL_FLUTTER_RE='(^|[^[:alnum:]_.-])flutter([[:space:]]+-[^[:space:]|;&]*([[:space:]]+[^-[:space:]|;&][^[:space:]|;&]*)?)*[[:space:]]+'
readonly _APP_INSTALL_RE='(^|[^[:alnum:]_.-])adb([[:space:]]+[^[:space:]|;&]+)*[[:space:]]+install(-multiple|-multi-package)?([[:space:]]|$)|(^|[^[:alnum:]_.-])(pm|cmd[[:space:]]+package)[[:space:]]+install([^[:alnum:]_]|$)|'"${_APP_INSTALL_FLUTTER_RE}"'install([[:space:]]|$)'
readonly _APP_INSTALL_DEF_RE='(^|[[:space:];{(])(function[[:space:]]+)?(install_fresh|install_app|_app_install_[[:alnum:]_]+)[[:space:]]*\(\)|(^|[[:space:];{(])function[[:space:]]+(install_fresh|install_app|_app_install_[[:alnum:]_]+)([[:space:]{]|$)'
readonly _APP_INSTALL_LAUNCH_RE="${_APP_INSTALL_FLUTTER_RE}"'(drive|test|run)([[:space:]]|$)'
readonly _APP_INSTALL_ADB_RE='(^|[^[:alnum:]_.-])adb[[:space:]]'
readonly _APP_INSTALL_CALL_RE='(^|[^[:alnum:]_])(install_fresh|install_app)([[:space:]]|$)'

# _app_install_code <file> — "<line>\t<code>" for each logical line of shell
# <file>, keeping only what the shell would execute.
#
# Comments, heredoc bodies and the contents of quoted words are dropped (each
# quoted word leaves one space, so the words around it stay apart); `$( … )` and
# backquotes inside double quotes are code, tracked on a stack; a backslash-
# continued line is joined to the next. A `<<WORD` whose word is a number is an
# arithmetic shift, not a heredoc. Exits 3 when the file ends inside a quoted
# word or a heredoc — including an arithmetic `<< NAME` misread as one —
# because nothing after that point could be vouched for.
#
# drive-log-lib.sh's string stripper is not reused: it does not track `$( … )`
# inside double quotes, so it reads `x="$(adb -s "${d}" install -r "${a}")"` as
# two strings and would hide the install.
_app_install_code() {
  awk '
    BEGIN {
      sq = sprintf("%c", 39); dq = sprintf("%c", 34); bq = sprintf("%c", 96)
      sp = 1; st[1] = "C"; dep[1] = -1
    }
    hd != "" {
      t = $0
      if (hdtabs) sub(/^\t+/, "", t)
      if (t == hd) hd = ""
      next
    }
    {
      if (!open) { start = NR; open = 1 }
      line = $0; n = length(line); cont = 0
      for (i = 1; i <= n; i++) {
        c = substr(line, i, 1); s = st[sp]
        if (s == "S") { if (c == sq) sp--; continue }
        if (s == "A") { if (c == "\\") i++; else if (c == sq) sp--; continue }
        if (s == "D") {
          if (c == "\\") i++
          else if (c == dq) sp--
          else if (c == bq) { st[++sp] = "B"; dep[sp] = -1 }
          else if (c == "$" && substr(line, i + 1, 1) == "(") {
            st[++sp] = "C"; dep[sp] = 0; i++
          }
          continue
        }
        if (c == "\\") {
          if (i == n) { cont = 1; break }
          buf = buf substr(line, i, 2); i++; continue
        }
        if (s == "B" && c == bq) { sp--; buf = buf " "; continue }
        if (c == sq) { st[++sp] = "S"; buf = buf " "; continue }
        if (c == dq) { st[++sp] = "D"; buf = buf " "; continue }
        if (c == "$" && substr(line, i + 1, 1) == sq) {
          st[++sp] = "A"; buf = buf " "; i++; continue
        }
        if (c == "#" && (i == 1 || substr(line, i - 1, 1) ~ /[[:space:];&|()<>]/)) break
        if (substr(line, i, 3) == "<<<") { buf = buf "<<<"; i += 2; continue }
        if (substr(line, i, 2) == "<<" \
            && match(substr(line, i), /^<<-?[[:space:]]*[^[:space:];&|<>()]+/)) {
          d = substr(line, i, RLENGTH); tabs = (substr(d, 3, 1) == "-")
          sub(/^<<-?[[:space:]]*/, "", d)
          gsub(sq, "", d); gsub(dq, "", d); gsub(/\\/, "", d)
          if (d ~ /^[A-Za-z0-9_.-]+$/ && d !~ /^[0-9]+$/) {
            pend = d; ptabs = tabs; buf = buf "<<"; i += RLENGTH - 1; continue
          }
        }
        if (dep[sp] >= 0) {
          if (c == "(") dep[sp]++
          else if (c == ")") {
            if (dep[sp] == 0) { sp--; buf = buf " "; continue }
            dep[sp]--
          }
        }
        buf = buf c
      }
      if (pend != "") { hd = pend; hdtabs = ptabs; pend = "" }
      if (cont || sp > 1) { buf = buf " "; next }
      print start "\t" buf
      buf = ""; open = 0
    }
    END { if (sp > 1 || hd != "") exit 3 }
  ' "$1"
}

app_install_check_installs() {
  local root="${1:-${_APP_INSTALL_LIB_DIR}/../../..}" dir lib f rel code ln text
  local calls drives=0
  local -a hits=()
  root="$(cd "${root}" 2>/dev/null && pwd)" || {
    echo "ERROR: repo root '${1:-}' is not a directory" >&2
    return 2
  }
  dir="${root}/tooling/e2e/ci"
  lib="${dir}/app-install-lib.sh"
  if [[ ! -f "${lib}" ]]; then
    echo "ERROR: ${lib} does not exist — the wrong repo root, or the one" \
         "install implementation this check protects is gone." >&2
    return 2
  fi

  for f in "${dir}"/*.sh; do
    if [[ "${f}" == "${lib}" ]]; then
      continue
    fi
    rel="${f#"${root}/"}"
    if ! code="$(_app_install_code "${f}")"; then
      echo "ERROR: ${rel} ends inside a quoted word or heredoc, so this check" \
           "cannot read it. Fix the construct (or _app_install_code) rather" \
           "than exempting the file." >&2
      return 2
    fi
    while IFS=$'\t' read -r ln text; do
      if [[ "${text}" =~ ${_APP_INSTALL_RE} ]]; then
        hits+=("${rel}:${ln}: R1 installs the app itself")
      fi
      if [[ "${text}" =~ ${_APP_INSTALL_DEF_RE} ]]; then
        hits+=("${rel}:${ln}: R2 defines one of this library's functions")
      fi
    done <<<"${code}"
    if [[ "${f##*/}" == run-*.sh ]] \
       && grep -qE -- "${_APP_INSTALL_LAUNCH_RE}" <<<"${code}" \
       && grep -qE -- "${_APP_INSTALL_ADB_RE}" <<<"${code}"; then
      drives=$(( drives + 1 ))
      # `declare -F install_fresh` proves the symbol exists, not that the lane
      # installs through it.
      calls="$(grep -vF -- 'declare -F' <<<"${code}" || true)"
      if ! grep -qE -- "${_APP_INSTALL_CALL_RE}" <<<"${calls}"; then
        hits+=("${rel}: R3 launches the app but never calls install_fresh or install_app")
      fi
    fi
  done

  for f in "${root}"/.github/workflows/*.yml; do
    if [[ ! -f "${f}" ]]; then
      continue
    fi
    rel="${f#"${root}/"}"
    while IFS=$'\t' read -r ln text; do
      if [[ "${text}" =~ ${_APP_INSTALL_RE} ]]; then
        hits+=("${rel}:${ln}: R1 installs the app itself")
      fi
    # A line keeps everything up to a ` #` outside quotes: a YAML comment, or
    # a shell comment in a `run: |` block.
    done < <(awk '
      BEGIN { sq = sprintf("%c", 39); dq = sprintf("%c", 34) }
      /^[[:space:]]*#/ { next }
      {
        q = ""; out = ""
        for (i = 1; i <= length($0); i++) {
          c = substr($0, i, 1)
          if (q == "" && c == "#" && i > 1 && substr($0, i - 1, 1) ~ /[[:space:]]/) break
          if (q == "" && (c == sq || c == dq)) q = c
          else if (c == q) q = ""
          out = out c
        }
        print NR "\t" out
      }' "${f}")
  done

  if (( drives < 2 )); then
    echo "ERROR: found ${drives} run-*.sh under ${dir} that launch the app;" \
         "this check has gone blind rather than found a clean tree." >&2
    return 2
  fi

  if (( ${#hits[@]} > 0 )); then
    {
      echo
      echo "  APP INSTALLED OUTSIDE THE SHARED FRESH-INSTALL STEP:"
      printf '    * %s\n' "${hits[@]}"
      cat <<EOF

  Every Android lane must put the app on the emulator through
  tooling/e2e/ci/app-install-lib.sh (install_fresh / install_app). A fresh
  install's PACKAGE_ADDED can relaunch MainActivity under \`flutter drive\` when
  it lands late, destroying the isolate the driver is attached to and hanging
  the lane to its cap (docs/E2E_TROUBLESHOOTING.md failure mode 11); only
  install_app flushes it, and only when the install is fresh.

  Fix by calling install_fresh (clean slate) or install_app (over what is
  there) instead of installing directly, and never by copying them: R2 exists
  because a second implementation is how the next lane loses the barrier.
EOF
    } >&2
    return 1
  fi

  echo "app-install-lib.sh --check-installs: OK — ${drives} run-*.sh launch the" \
       "app and every one installs it through this library; nothing else under" \
       "tooling/e2e/ci or .github/workflows installs it."
}

# ---------------------------------------------------------------------------
# Self-test. A stub `adb` on PATH records every call and plays the device: the
# package present or absent, the install passing or failing, the barrier
# answering with any of the verdicts install_app must tell apart, wedged, or
# never reached at all.
#
# WHAT THE STUB IS ALLOWED TO CLAIM. Every shape it plays that the library reads
# is one a real run has shown (the citations sit on each arm) or one this file
# invented — the verdict line, which the guest prints because it was asked to.
# Where a real message or rc is UNMEASURED and the library never reads it, the
# stub does not invent one: it plays the rc class and says so. A fake that
# modelled remembered text would prove only that the memory and the code agree.
#
# The stub `timeout` records the bound it is asked for and hands the call to the
# REAL coreutils timeout with that bound rewritten to 1 s, so a wedged device
# costs a second rather than two minutes while 124, a pass-through rc and a
# post-`-k` 137 stay the real tool's; the recorded call is what pins the real
# bound, and _ai_suite_timeout checks the stub against coreutils in the same run.
#
# The helpers read `tmp`, `ran`, `fail`, `ai_rc` and `real_timeout` out of
# app_install_lib_self_test's scope through bash's dynamic scoping.
# ---------------------------------------------------------------------------

# Assertions app_install_lib_self_test must make. Pinned by EQUALITY, not by a
# floor: a floor lets a fixture be deleted and the suite stay green, which is
# how a prose count once reported success here. Change it only in the commit
# that adds or removes a fixture.
readonly APP_INSTALL_SELF_TEST_FIXTURES=80

# The calls install_fresh and install_app make on the stub device, verbatim —
# transcribed here rather than shared with the code, so that changing either
# reds the suite.
readonly _AI_STOP='-s emulator-5554 shell am force-stop com.oblivioustech.haven'
readonly _AI_UNINSTALL='-s emulator-5554 uninstall com.oblivioustech.haven'
readonly _AI_PROBE='-s emulator-5554 shell pm path com.oblivioustech.haven'
readonly _AI_INSTALL='-s emulator-5554 install -r /tmp/fixture.apk'
readonly _AI_REMOTE='cmd package wait-for-handler --timeout 120000 ; h=$?; am wait-for-broadcast-barrier --flush-broadcast-loopers; b=$?; cmd package haven-not-a-command >/dev/null 2>&1; c=$?; am haven-not-a-command >/dev/null 2>&1; a=$?; echo; echo "haven-barrier-rc $h $b $c $a"'
readonly _AI_BARRIER="-s emulator-5554 shell ${_AI_REMOTE}"
readonly _AI_BOUND="timeout 120 adb ${_AI_BARRIER}"

_ai_write_stubs() {
  mkdir -p "${tmp}/bin"
  cat > "${tmp}/bin/adb" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${STUB_CALLS}"
case "$*" in
  *"wait-for-broadcast-barrier"*)
    # The verdict line is this file's own protocol, so playing it is modelling,
    # not remembering: <drain> <barrier> <cmd control> <am control>, where a
    # control is the rc of a command the guest cannot have. flushed's 255 is
    # what `cmd`/`am` are expected to answer there and NOTHING reads its value,
    # which is why alt-codes plays a different pair.
    case "${STUB_BARRIER}" in
      flushed)     echo "haven-barrier-rc 0 0 255 255" ;;
      alt-codes)   echo "haven-barrier-rc 0 0 1 20" ;;
      # An adb shell that hands its lines back CRLF, as this library's probe has
      # always assumed one can: the verdict is the same verdict.
      crlf)        printf 'haven-barrier-rc 0 0 255 255\r\n' ;;
      no-handler)  echo "haven-barrier-rc 255 0 255 255" ;;
      no-barrier)  echo "haven-barrier-rc 0 255 255 255" ;;
      lying-shell) echo "haven-barrier-rc 0 0 0 0" ;;
      truncated)   echo "haven-barrier-rc 0 0" ;;
      mute)        : ;;  # answers 0 and says nothing of its own commands
      # 127 is what timeout answers when it cannot execute adb at all — the
      # shape eight of run 35536892150's thirteen Android lane jobs hit, with
      # adb off the PATH.
      unrunnable)  exit 127 ;;
      # "adb: device offline" is verbatim from the lane logs (60 hits in run
      # 35524002720's jobs); rc 1 is this adb's, measured with no device.
      offline)     echo "adb: device offline" >&2; exit 1 ;;
      # Outlives the stub timeout's 1 s, then reports success: a barrier that
      # lost its bound fails fixture (3) instead of hanging the self-test.
      wedged)      exec sleep 30 ;;
    esac ;;
  *" shell pm path "*)
    # noise: every probe reads the noise of a package service that is not up;
    # noise-once: only the first does. Both its lines must read as ABSENT. The
    # library reads stdout alone, so the noise is put there deliberately — a
    # real service error goes to the stderr this discards, and its rc, 20, is
    # read by nothing here.
    if [[ "${STUB_PROBE}" == noise ]] \
       || { [[ "${STUB_PROBE}" == noise-once ]] && [[ ! -e "${STUB_STATE}.probed" ]]; }; then
      : > "${STUB_STATE}.probed"
      # Names the package service, so a match on `package` alone reads it as an
      # installed app. cmd.cpp prints `cmd: Can't find service: <name>` to
      # STDERR and exits 20; it is placed on stdout here, where the library
      # looks, which is the harder case for the anchor.
      echo "cmd: Can't find service: package"
      # Constructed, not quoted from any run: `package:` away from the start of
      # a line, so it is the ANCHOR and not the colon that decides. Unanchored,
      # this line reads as an installed app and a FRESH install takes no barrier.
      echo "Error: Unknown package: com.oblivioustech.haven"
      exit 20
    fi
    # Present: the `package:` line every M7 replace read in run 35524002720.
    # Absent: no such line — measured the same run, by every lane's probe after
    # its uninstall. The rc is read by nothing here.
    [[ -e "${STUB_STATE}" ]] || exit 1
    echo "package:/data/app/~~stub==/com.oblivioustech.haven-stub==/base.apk" ;;
  *" uninstall "*)
    # Nothing reads this call's output or rc, so neither is invented: what is
    # modelled is that clearing a device with nothing to clear FAILS, which is
    # the state every lane's first install_fresh starts from, and that a stuck
    # uninstall can still answer 0 — which is why the probe after it decides.
    if [[ "${STUB_UNINSTALL}" == stuck ]]; then
      exit 0
    fi
    [[ -e "${STUB_STATE}" ]] || exit 1
    rm -f "${STUB_STATE}" ;;
  *" install -r "*)
    case "${STUB_INSTALL}" in
      # Verbatim from run 35524002720's 20 installs, in that order, on stdout.
      ok) : > "${STUB_STATE}"; echo "Performing Streamed Install"; echo "Success" ;;
      # An installer that answers 0 for an install that did not land. WHICH adb
      # does this is UNMEASURED — a green lane never shows it — so what is
      # modelled is only the shape the library must survive: an rc that says
      # yes over a device that says no.
      silent) echo "Performing Streamed Install"; echo "Failure [INSTALL_FAILED_STUB]" ;;
      *) echo "adb: failed to install /tmp/fixture.apk: Failure [INSTALL_FAILED_STUB]" >&2; exit 1 ;;
    esac ;;
esac
exit 0
STUB
  cat > "${tmp}/bin/timeout" <<'STUB'
#!/usr/bin/env bash
# Records the call, then hands it to the REAL timeout with the DURATION operand
# — and only it — rewritten to 1 s. Options are passed through untouched, so
# `-k`'s kill, the 124 on expiry and a pass-through rc are the real tool's
# behaviour rather than this file's idea of it.
printf 'timeout %s\n' "$*" >> "${STUB_CALLS}"
opts=()
while [[ "${1:-}" == -* ]]; do
  case "$1" in
    --) shift; break ;;
    -k|--kill-after|-s|--signal) opts+=( "$1" "$2" ); shift 2 ;;
    *) opts+=( "$1" ); shift ;;
  esac
done
shift
exec "${STUB_REAL_TIMEOUT}" "${opts[@]}" 1 "$@"
STUB
  chmod +x "${tmp}/bin/adb" "${tmp}/bin/timeout"
}

# _ai_run <function> <present|absent> <install ok|failed|silent>
#         <barrier flushed|alt-codes|no-handler|no-barrier|lying-shell|mute|
#                  unrunnable|offline|wedged>
#         [<probe clean|noise|noise-once>] [<uninstall ok|stuck>]
# Runs `<function> emulator-5554 /tmp/fixture.apk` on the stub device and
# leaves its rc in ai_rc, its calls in ${tmp}/calls and its stderr in ${tmp}/err.
_ai_run() {
  : > "${tmp}/calls"
  rm -f "${tmp}/installed" "${tmp}/installed.probed"
  if [[ "$2" == present ]]; then
    : > "${tmp}/installed"
  fi
  ai_rc=0
  (
    export PATH="${tmp}/bin:${PATH}" STUB_CALLS="${tmp}/calls" \
      STUB_STATE="${tmp}/installed" STUB_INSTALL="$3" STUB_BARRIER="$4" \
      STUB_PROBE="${5:-clean}" STUB_UNINSTALL="${6:-ok}" \
      STUB_REAL_TIMEOUT="${real_timeout}"
    "$1" emulator-5554 /tmp/fixture.apk
  ) >/dev/null 2>"${tmp}/err" || ai_rc=$?
}

# `ran=$(( ran + 1 ))`, never `(( ran++ ))`: the latter returns 1 when ran is 0,
# which `set -e` on the direct-execution path would treat as a failure.
_ai_expect_ok() { # <label>
  ran=$(( ran + 1 ))
  if (( ai_rc != 0 )); then
    echo "SELF-TEST FAIL ($1): want success, got rc=${ai_rc}:" >&2
    sed 's/^/    /' "${tmp}/err" >&2
    fail=1
  fi
}
_ai_expect_refused() { # <label>
  ran=$(( ran + 1 ))
  if (( ai_rc == 0 )); then
    echo "SELF-TEST FAIL ($1): want a refusal, got success" >&2
    fail=1
  fi
}
_ai_expect_calls() { # <label> <call>...
  ran=$(( ran + 1 ))
  if [[ "$(cat "${tmp}/calls")" != "$(printf '%s\n' "${@:2}")" ]]; then
    echo "SELF-TEST FAIL ($1): the device saw:" >&2
    sed 's/^/    /' "${tmp}/calls" >&2
    fail=1
  fi
}
_ai_expect_named() { # <label> <ere the refusal must name>
  ran=$(( ran + 1 ))
  if ! grep -qE -- "$2" "${tmp}/err"; then
    echo "SELF-TEST FAIL ($1): the refusal does not say /$2/:" >&2
    sed 's/^/    /' "${tmp}/err" >&2
    fail=1
  fi
}
_ai_expect_check_rc() { # <label> <want-rc> <tree> [<ere the report must carry>]
  local got=0 out
  ran=$(( ran + 1 ))
  out="$(app_install_check_installs "$3" 2>&1)" || got=$?
  if (( got != $2 )); then
    echo "SELF-TEST FAIL ($1): --check-installs want rc=$2, got rc=${got}:" >&2
    sed 's/^/    /' <<<"${out}" >&2
    fail=1
  elif [[ -n "${4:-}" ]] && ! grep -qE -- "$4" <<<"${out}"; then
    echo "SELF-TEST FAIL ($1): the report does not carry /$4/:" >&2
    sed 's/^/    /' <<<"${out}" >&2
    fail=1
  fi
}

# _ai_timeout_rc <stub|real> <arg>... — `timeout <arg>...` under the stub or
# under coreutils, its rc echoed. The stub forces every bound to 1 s, so the
# real leg is given a bound of its own: it is the rc, not the wait, under test.
_ai_timeout_rc() {
  local which="$1" rc=0
  shift
  if [[ "${which}" == stub ]]; then
    (
      export PATH="${tmp}/bin:${PATH}" STUB_CALLS="${tmp}/timeout-calls" \
        STUB_REAL_TIMEOUT="${real_timeout}"
      timeout "$@"
    ) >/dev/null 2>&1 || rc=$?
  else
    "${real_timeout}" "$@" >/dev/null 2>&1 || rc=$?
  fi
  printf '%s' "${rc}"
}
_ai_expect_timeout_agrees() { # <label> <want-rc> <stub-rc> <real-rc>
  ran=$(( ran + 1 ))
  if [[ "$3" != "$2" || "$4" != "$2" ]]; then
    echo "SELF-TEST FAIL ($1): want rc $2 from both; the stub gave $3 and" \
         "coreutils timeout gave $4" >&2
    fail=1
  fi
}

# ---------------------------------------------------------------------------
# Suite 0: the stub `timeout` against the real one, in the same run. install_app
# tells a wedged queue (124) from a barrier that answered (its own rc) from a
# command this runner could not execute (127) — three rcs a fake could silently
# flatten into one, which is why each is taken from both and must match.
# ---------------------------------------------------------------------------
_ai_suite_timeout() {
  # (T1) A command that outlives its bound: 124, what install_app reads as a
  #      broadcast queue that never drained.
  _ai_expect_timeout_agrees T1 124 \
    "$(_ai_timeout_rc stub 120 sleep 30)" "$(_ai_timeout_rc real 0.2 sleep 30)"

  # (T2) One that returns in time keeps its own rc — every verdict install_app
  #      reads, its 0 included, arrives through this.
  _ai_expect_timeout_agrees T2 7 \
    "$(_ai_timeout_rc stub 120 bash -c 'exit 7')" \
    "$(_ai_timeout_rc real 5 bash -c 'exit 7')"

  # (T3) One that ignores TERM is killed after --kill-after: 137, and the option
  #      reaches the real tool rather than being eaten as the bound. No lane
  #      passes -k here today; a stub that mangled it would hand the next one a
  #      127 dressed as a device fault.
  _ai_expect_timeout_agrees T3 137 \
    "$(_ai_timeout_rc stub -k 0.2 120 bash -c 'trap "" TERM; sleep 30')" \
    "$(_ai_timeout_rc real -k 0.2 0.2 bash -c 'trap "" TERM; sleep 30')"
}

# ---------------------------------------------------------------------------
# Suite 1: install_fresh — moved here with the implementation from
# run-single-avd-scenario.sh's --self-test (its fixtures 8a-8d).
# ---------------------------------------------------------------------------
_ai_suite_fresh() {
  # (1) THE PROMISE, from a device that already has the package: a clean slate,
  #     checked, the install — fresh, because the slate is clean — a check that
  #     it landed, and only then, under the full bound and on the same device, a
  #     drained package-manager handler and a barrier that flushes the loopers
  #     broadcasts are sent from.
  _ai_run install_fresh present ok flushed
  _ai_expect_ok 1
  _ai_expect_calls 1b "${_AI_STOP}" "${_AI_UNINSTALL}" "${_AI_PROBE}" \
    "${_AI_PROBE}" "${_AI_INSTALL}" "${_AI_PROBE}" "${_AI_BOUND}" "${_AI_BARRIER}"

  # (1c) THE PATH EVERY LANE TAKES FIRST: a freshly booted guest with nothing to
  #      clear, so the uninstall fails for want of anything to remove. Its rc
  #      may not be read — the probe after it is what decides — and the sequence
  #      is the same one, barrier included.
  _ai_run install_fresh absent ok flushed
  _ai_expect_ok 1c
  _ai_expect_calls 1d "${_AI_STOP}" "${_AI_UNINSTALL}" "${_AI_PROBE}" \
    "${_AI_PROBE}" "${_AI_INSTALL}" "${_AI_PROBE}" "${_AI_BOUND}" "${_AI_BARRIER}"

  # (1e) An uninstall that leaves the package fails, by name, before installing:
  #      over it the install would be a replace keeping the earlier target's
  #      data and sticky service, where the caller asked for a clean slate.
  _ai_run install_fresh present ok flushed clean stuck
  _ai_expect_refused 1e
  _ai_expect_named 1f 'still on emulator-5554 after its uninstall'
  _ai_expect_calls 1g "${_AI_STOP}" "${_AI_UNINSTALL}" "${_AI_PROBE}"

  # (2) A guest whose package manager cannot drain its handler — the command
  #     arrived in API 34 — fails, never drives unflushed, and says why.
  _ai_run install_fresh present ok no-handler
  _ai_expect_refused 2
  _ai_expect_named 2b 'install barrier failed'

  # (3) A barrier that never drains fails within its bound, by name.
  _ai_run install_fresh present ok wedged
  _ai_expect_refused 3
  _ai_expect_named 3b 'still queued after 120 s'

  # (4) A failed install fails. Unchecked (errexit is gone under `||`) it would
  #     flush a barrier over nothing, and `flutter drive`'s own install would
  #     become the FRESH one — the unflushed race, reinstated.
  _ai_run install_fresh absent failed flushed
  _ai_expect_refused 4
  _ai_expect_named 4b 'adb install -r /tmp/fixture\.apk failed'

  # (4c) An adb that reports success for an install that did not land. Trusted,
  #      the barrier would flush nothing and `flutter drive`'s own install would
  #      be the fresh, unflushed one — so it fails, by name, before any barrier.
  _ai_run install_fresh present silent flushed
  _ai_expect_refused 4c
  _ai_expect_named 4d 'reported success, but'
  _ai_expect_calls 4e "${_AI_STOP}" "${_AI_UNINSTALL}" "${_AI_PROBE}" \
    "${_AI_PROBE}" "${_AI_INSTALL}" "${_AI_PROBE}"
}

# ---------------------------------------------------------------------------
# Suite 2: install_app — the barrier runs exactly where a fresh install did.
# ---------------------------------------------------------------------------
_ai_suite_app() {
  # (5) Nothing on the device: the install IS fresh, so it is flushed.
  _ai_run install_app absent ok flushed
  _ai_expect_ok 5
  _ai_expect_calls 5b "${_AI_PROBE}" "${_AI_INSTALL}" "${_AI_PROBE}" \
    "${_AI_BOUND}" "${_AI_BARRIER}"

  # (5c) The control rcs are read as a class, never as values: a guest that
  #      refuses an unknown command with some other pair passes just the same.
  _ai_run install_app absent ok alt-codes
  _ai_expect_ok 5c

  # (5d) A verdict handed back CRLF is the same verdict. The probe has stripped
  #      those since this file was written; a parser that did not would fail
  #      every fresh install on the first guest whose shell allocates a pty.
  _ai_run install_app absent ok crlf
  _ai_expect_ok 5d

  # (6) THE NO-FALSE-RED FIXTURE. Over an installed package the install is a
  #     replace, which the overlay manager ignores: no barrier is taken, so a
  #     device that could not have run one does not fail the lane.
  _ai_run install_app present ok no-handler
  _ai_expect_ok 6
  _ai_expect_calls 6b "${_AI_PROBE}" "${_AI_INSTALL}"

  # (7) A probe that reads noise where `package:` should be — noise that names
  #     the package service, so a loose match would read it as present — reads
  #     as absent, so the doubt resolves towards the barrier: the package really
  #     is installed here, and the barrier runs anyway.
  _ai_run install_app present ok flushed noise-once
  _ai_expect_ok 7
  _ai_expect_calls 7b "${_AI_PROBE}" "${_AI_INSTALL}" "${_AI_PROBE}" \
    "${_AI_BOUND}" "${_AI_BARRIER}"

  # (7c) A device whose probe never answers cannot show the fresh install
  #      landed, and fails closed.
  _ai_run install_app present ok flushed noise
  _ai_expect_refused 7c

  # (8) A fresh install on a device that cannot take the barrier fails here too,
  #     naming the half that refused.
  _ai_run install_app absent ok no-handler
  _ai_expect_refused 8
  _ai_expect_named 8b 'handler drain exited 255'

  # (8c) ...and so does the other half, which the same line must tell apart: a
  #      guest can have the drain and not the barrier.
  _ai_run install_app absent ok no-barrier
  _ai_expect_refused 8c
  _ai_expect_named 8d 'broadcast barrier exited 255'

  # (8e) A guest that answers 0 to a command it cannot have makes the barrier's
  #      own 0 worthless: rc 0 from a command that ran and rc 0 from one that
  #      does not exist are the same line. Nothing else here would notice, and
  #      the lane would drive into the race this file exists to remove.
  _ai_run install_app absent ok lying-shell
  _ai_expect_refused 8e
  _ai_expect_named 8f 'answered 0 to a command it cannot have \(cmd 0, am 0\)'

  # (8g) An adb that exits 0 having said nothing about the barrier's commands
  #      proves nothing was flushed — whether the guest ran them or adb dropped
  #      its own exit status on the way back.
  _ai_run install_app absent ok mute
  _ai_expect_refused 8g
  _ai_expect_named 8h 'without reporting what the barrier'

  # (8i) A verdict cut short is not a verdict. A looser read would take the
  #      halves it cannot see for zeros — the one wrong answer that passes.
  _ai_run install_app absent ok truncated
  _ai_expect_refused 8i
  _ai_expect_named 8j 'without reporting what the barrier'

  # (8k) A barrier that could not be executed on the RUNNER (adb off the PATH,
  #      as in run 35536892150) is not the guest's fault, and is not reported as
  #      one: nothing was asked of it.
  _ai_run install_app absent ok unrunnable
  _ai_expect_refused 8k
  _ai_expect_named 8l 'nothing was asked of emulator-5554'

  # (8m) A transport that dropped mid-barrier fails as the device-level refusal
  #      it is, carrying what adb said.
  _ai_run install_app absent ok offline
  _ai_expect_refused 8m
  _ai_expect_named 8n 'adb could not run the install barrier'

  # (9) A wedged queue after a fresh install fails here too.
  _ai_run install_app absent ok wedged
  _ai_expect_refused 9

  # (10) A failed replace fails.
  _ai_run install_app present failed flushed
  _ai_expect_refused 10

  # (11) The bound: ~3.5x the worst backlog on record (34 s). Every lane's
  #      budget carries it at this value; it is never tightened to fit one.
  ran=$(( ran + 1 ))
  if (( INSTALL_BARRIER_SECS != 120 )); then
    echo "SELF-TEST FAIL (11): INSTALL_BARRIER_SECS is ${INSTALL_BARRIER_SECS}," \
         "not 120" >&2
    fail=1
  fi
}

# ---------------------------------------------------------------------------
# Suite 3: the pin. A fixture tree carries a copy of this library, two lanes
# that drive through it (one from a clean slate, one over an installed app), a
# lane that only delegates, and a workflow — the shape of the real tree.
# ---------------------------------------------------------------------------
_ai_tree() { # <name> — a fresh copy of the base tree; echoes its root
  local t="${tmp}/trees/$1"
  rm -rf "${t}"
  cp -R "${tmp}/base" "${t}"
  printf '%s' "${t}"
}
_ai_mk_base() {
  local b="${tmp}/base" ci="${tmp}/base/tooling/e2e/ci"
  mkdir -p "${ci}" "${b}/.github/workflows" "${tmp}/trees"
  cp "${_APP_INSTALL_LIB_DIR}/app-install-lib.sh" "${ci}/"
  cat > "${ci}/run-alpha.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
source "${SCRIPT_DIR}/app-install-lib.sh"
install_fresh "${DEVICE}" "${APK}" || fail "fresh install failed"
adb -s "${DEVICE}" shell pm grant com.oblivioustech.haven android.permission.POST_NOTIFICATIONS
( cd "${HAVEN_DIR}" && timeout --kill-after=30s "${DRIVE_TIMEOUT}" flutter drive \
    --no-pub \
    --use-application-binary "${APK}" \
    --target "${TARGET}" ) > "${LOG}" 2>&1 || drc=$?
SH
  cat > "${ci}/run-beta.sh" <<'SH'
#!/usr/bin/env bash
source "${SCRIPT_DIR}/app-install-lib.sh"
if ! install_app "${DEVICE}" "${APK}"; then
  exit 1
fi
adb -s "${DEVICE}" shell pm grant com.oblivioustech.haven android.permission.POST_NOTIFICATIONS
flutter drive --use-application-binary "${APK}" --target "${TARGET}" > "${LOG}" 2>&1 || drc=$?
SH
  cat > "${ci}/run-delegate.sh" <<'SH'
#!/usr/bin/env bash
readonly INNER="${script_dir}/run-alpha.sh"
bash "${INNER}" "$@"
SH
  cat > "${b}/.github/workflows/e2e-lane.yml" <<'YML'
jobs:
  lane:
    steps:
      - name: Drive on the emulator
        uses: reactivecircus/android-emulator-runner@v2
        with:
          script: bash tooling/e2e/ci/run-with-deadline.sh 5m "lane" -- bash -c 'bash tooling/e2e/ci/setup-network-guard.sh install && bash tooling/e2e/ci/run-alpha.sh'
YML
}

_ai_suite_pin() {
  local t
  _ai_mk_base

  # (12) The real tree's shape is clean: two adb-using lanes that install through
  #      the library before `flutter drive` — whose own replace is not an install —
  #      a delegating lane that drives nothing, and this library, whose own
  #      `adb install` is the one implementation.
  _ai_expect_check_rc 12 0 "$(_ai_tree clean)"

  # --- R1 fires: a bare install, however it is written. ---------------------
  # (13) The line every lane carried before the shared step — and the report
  #      says where it is.
  t="$(_ai_tree bare)"
  printf 'adb -s "${DEVICE}" install -r "${APK}"\n' >> "${t}/tooling/e2e/ci/run-alpha.sh"
  _ai_expect_check_rc 13 1 "${t}" 'run-alpha\.sh:10: R1'

  # (14) Inside a double-quoted command substitution, where a naive string
  #      stripper sees two strings and nothing else.
  t="$(_ai_tree subst)"
  printf 'out="$(adb -s "${DEVICE}" install -r "${APK}" 2>&1)"\n' \
    >> "${t}/tooling/e2e/ci/run-beta.sh"
  _ai_expect_check_rc 14 1 "${t}"

  # (14b) ...or inside backquotes inside double quotes, which are code too.
  t="$(_ai_tree backquoted)"
  printf '%s\n' 'out="`adb -s emulator-5554 install -r /tmp/app.apk`"' \
    >> "${t}/tooling/e2e/ci/run-beta.sh"
  _ai_expect_check_rc 14b 1 "${t}" 'run-beta\.sh:8: R1'

  # (15) Split over a backslash continuation.
  t="$(_ai_tree continued)"
  printf 'adb -s "${DEVICE}" \\\n  install -r "${APK}"\n' \
    >> "${t}/tooling/e2e/ci/run-alpha.sh"
  _ai_expect_check_rc 15 1 "${t}"

  # (15b) Arguments that carry an arithmetic (or command) substitution.
  t="$(_ai_tree subst-args)"
  printf 'adb -s emulator-$(( 5554 + 2 * n )) install -r "${APK}"\n' \
    >> "${t}/tooling/e2e/ci/run-alpha.sh"
  _ai_expect_check_rc 15b 1 "${t}"

  # (16) Device-side, through the package manager.
  t="$(_ai_tree pm)"
  printf 'adb -s "${DEVICE}" shell pm install -r /data/local/tmp/haven.apk\n' \
    >> "${t}/tooling/e2e/ci/run-alpha.sh"
  _ai_expect_check_rc 16 1 "${t}"

  # (16b) ...with no `adb` word on the line for the rule above to find: the
  #       package-manager spelling fires on its own.
  t="$(_ai_tree pm-no-adb)"
  printf '%s\n' '"${ADB}" -s "${DEVICE}" shell pm install -r /data/local/tmp/haven.apk' \
    >> "${t}/tooling/e2e/ci/run-alpha.sh"
  _ai_expect_check_rc 16b 1 "${t}" 'run-alpha\.sh:10: R1'

  # (17) Through flutter_tools.
  t="$(_ai_tree flutter-install)"
  printf 'flutter install --device-id "${DEVICE}"\n' >> "${t}/tooling/e2e/ci/run-beta.sh"
  _ai_expect_check_rc 17 1 "${t}"

  # (17b) ...with global options before the subcommand.
  t="$(_ai_tree flutter-opts-install)"
  printf 'flutter -v -d emulator-5554 install\n' >> "${t}/tooling/e2e/ci/run-beta.sh"
  _ai_expect_check_rc 17b 1 "${t}" 'run-beta\.sh:8: R1'

  # (18) Inline in a workflow's emulator script.
  t="$(_ai_tree workflow)"
  sed -i 's|script: bash tooling|script: adb install -r /tmp/app.apk \&\& bash tooling|' \
    "${t}/.github/workflows/e2e-lane.yml"
  _ai_expect_check_rc 18 1 "${t}" 'e2e-lane\.yml:7: R1'

  # (18b) ...with a comment after it: the comment goes, the install stays.
  t="$(_ai_tree workflow-then-comment)"
  sed -i 's|script: bash tooling|script: adb install -r /tmp/app.apk \&\& bash tooling|' \
    "${t}/.github/workflows/e2e-lane.yml"
  sed -i '/script:/ s|$|  # restores the app first|' "${t}/.github/workflows/e2e-lane.yml"
  _ai_expect_check_rc 18b 1 "${t}" 'e2e-lane\.yml:7: R1'

  # (18c) ...and a ` #` inside a quoted string is not a comment.
  t="$(_ai_tree workflow-quoted-hash)"
  sed -i 's|script: bash tooling|script: echo "step #1"; adb install -r /tmp/app.apk \&\& bash tooling|' \
    "${t}/.github/workflows/e2e-lane.yml"
  _ai_expect_check_rc 18c 1 "${t}" 'e2e-lane\.yml:7: R1'

  # --- R2 fires: a second implementation. ------------------------------------
  # (19) A copy in another file, even one that installs nothing.
  t="$(_ai_tree copy)"
  printf '#!/usr/bin/env bash\ninstall_fresh() { :; }\n' \
    > "${t}/tooling/e2e/ci/lane-helpers.sh"
  _ai_expect_check_rc 19 1 "${t}" 'lane-helpers\.sh:2: R2'

  # (19b) ...written with the `function` keyword and no parentheses.
  t="$(_ai_tree copy-function-kw)"
  printf '#!/usr/bin/env bash\nfunction install_app {\n  :\n}\n' \
    > "${t}/tooling/e2e/ci/lane-helpers.sh"
  _ai_expect_check_rc 19b 1 "${t}" 'lane-helpers\.sh:2: R2'

  # (20) A lane overriding the probe after sourcing: every install would read as
  #      a replace, and no barrier would ever run.
  t="$(_ai_tree override)"
  printf '_app_install_present() { return 0; }\n' >> "${t}/tooling/e2e/ci/run-alpha.sh"
  _ai_expect_check_rc 20 1 "${t}"

  # --- R3 fires: a drive with no flushed install before it. ------------------
  # (21) The next lane, written without the step.
  t="$(_ai_tree no-install)"
  printf '#!/usr/bin/env bash\nadb -s "${DEVICE}" wait-for-device\nflutter drive --target "${TARGET}"\n' \
    > "${t}/tooling/e2e/ci/run-gamma.sh"
  _ai_expect_check_rc 21 1 "${t}" 'run-gamma\.sh: R3'

  # (21b) ...or written with `flutter test -d`, which installs and launches too.
  t="$(_ai_tree flutter-test)"
  printf '#!/usr/bin/env bash\nadb -s "${DEVICE}" wait-for-device\nflutter test integration_test/x_test.dart -d "${DEVICE}"\n' \
    > "${t}/tooling/e2e/ci/run-gamma.sh"
  _ai_expect_check_rc 21b 1 "${t}" 'run-gamma\.sh: R3'

  # (21c) ...or with global options before the subcommand.
  t="$(_ai_tree flutter-opts-drive)"
  printf '#!/usr/bin/env bash\nadb -s "${DEVICE}" wait-for-device\nflutter --verbose -d emulator-5554 drive --target "${TARGET}"\n' \
    > "${t}/tooling/e2e/ci/run-gamma.sh"
  _ai_expect_check_rc 21c 1 "${t}" 'run-gamma\.sh: R3'

  # (22) Probing the symbol is not calling it.
  t="$(_ai_tree probe-only)"
  sed -i 's|^install_fresh .*|declare -F install_fresh >/dev/null|' \
    "${t}/tooling/e2e/ci/run-alpha.sh"
  _ai_expect_check_rc 22 1 "${t}" 'run-alpha\.sh: R3'

  # --- Must NOT fire: text that names an install is not one. -----------------
  # (23) Comments, including a commented-out definition.
  t="$(_ai_tree comments)"
  printf '%s\n' '# adb -s "${DEVICE}" install -r "${APK}"' \
    '  # install_fresh() { :; }' 'grants=1 # then adb install -r x' \
    >> "${t}/tooling/e2e/ci/run-alpha.sh"
  _ai_expect_check_rc 23 0 "${t}"

  # (23b) A comment led by `)` is a comment, so its apostrophe opens no quote —
  #       one that would swallow the real install on the next line.
  t="$(_ai_tree paren-comment)"
  printf '%s\n' 'case "${n}" in x)# not a quote: it'"'"'s a comment' \
    '  adb -s "${DEVICE}" install -r "${APK}" ;;' 'esac' \
    >> "${t}/tooling/e2e/ci/run-alpha.sh"
  _ai_expect_check_rc 23b 1 "${t}" 'run-alpha\.sh:11: R1'

  # (24) Messages, quoted in every way a lane quotes them.
  t="$(_ai_tree messages)"
  printf '%s\n' 'echo "adb install -r failed"' \
    'fail "`adb -s ${DEVICE} install` exited 1; see flutter install docs"' \
    "printf '%s\\n' 'pm install needs a pushed APK'" \
    >> "${t}/tooling/e2e/ci/run-alpha.sh"
  sed -i 's|fail "`adb|fail "\\`adb|; s|install` exited|install\\` exited|' \
    "${t}/tooling/e2e/ci/run-alpha.sh"
  _ai_expect_check_rc 24 0 "${t}"

  # (25) Fixtures: a stub adb in a heredoc, and a lane body in a multi-line
  #      single-quoted string, as other self-tests here write them.
  t="$(_ai_tree fixtures)"
  cat >> "${t}/tooling/e2e/ci/run-alpha.sh" <<'SH'
cat > "${tmp}/adb" <<'STUB'
case "$*" in *" install -r "*) exit 0 ;; esac
adb install -r "${APK}"
STUB
mk_runner "${tree}" run-x.sh '
adb -s "${DEVICE}" install -r "${APK}"
flutter install'
SH
  _ai_expect_check_rc 25 0 "${t}"

  # (26) Look-alikes, and the syntax that trips naive lexers: none is an
  #      install, and the file still parses to the end.
  t="$(_ai_tree lookalikes)"
  cat >> "${t}/tooling/e2e/ci/run-alpha.sh" <<'SH'
adb -s "${DEVICE}" uninstall "${PKG}" >/dev/null 2>&1 || true
adb -s "${DEVICE}" shell settings get secure install_non_market_apps
bash tooling/e2e/ci/setup-network-guard.sh install
tab=$'\t'; n=${#hits[@]}; shift=$(( 1 << 3 )); grep -c x <<<"${tab}" || true
case "${n}" in install) echo "an install token as a case label" ;; esac
SH
  _ai_expect_check_rc 26 0 "${t}"

  # (26b) An iOS runner launches with `flutter test -d <udid>` and never talks to
  #       adb, so R3 is not its business.
  t="$(_ai_tree ios)"
  printf '#!/usr/bin/env bash\nxcrun simctl boot "${SIM_UDID}"\nflutter test integration_test/x_test.dart -d "${SIM_UDID}"\n' \
    > "${t}/tooling/e2e/ci/run-ios-x.sh"
  _ai_expect_check_rc 26b 0 "${t}"

  # (26c) An escaped quote inside `$'…'` does not close it, so the install on
  #       the next line is still read as code.
  t="$(_ai_tree ansi-c)"
  cat >> "${t}/tooling/e2e/ci/run-alpha.sh" <<'SH'
msg=$'it\'s one word'
adb -s "${DEVICE}" install -r "${APK}"
SH
  _ai_expect_check_rc 26c 1 "${t}" 'run-alpha\.sh:11: R1'

  # (26d) A `<<-` heredoc ends at its tab-indented terminator, so the install
  #       after it is still read as code.
  t="$(_ai_tree heredoc-tabs)"
  printf 'cat <<-EOF >/dev/null\n\tbody\n\tEOF\nadb -s "${DEVICE}" install -r "${APK}"\n' \
    >> "${t}/tooling/e2e/ci/run-alpha.sh"
  _ai_expect_check_rc 26d 1 "${t}" 'run-alpha\.sh:13: R1'

  # (26e) A lane that talks to adb and runs flutter without launching the app
  #       — a pub script, a build with a global option — owes no install.
  t="$(_ai_tree flutter-no-launch)"
  printf '#!/usr/bin/env bash\nadb -s "${DEVICE}" wait-for-device\nflutter pub run build_runner build\nflutter -v build apk --debug\n' \
    > "${t}/tooling/e2e/ci/run-gamma.sh"
  _ai_expect_check_rc 26e 0 "${t}"

  # (27) A workflow comment that quotes the old line.
  t="$(_ai_tree workflow-comment)"
  sed -i 's|^      - name: Drive|      # was: adb install -r /tmp/app.apk\n      - name: Drive|' \
    "${t}/.github/workflows/e2e-lane.yml"
  _ai_expect_check_rc 27 0 "${t}"

  # (27b) ...or one written after a line's content.
  t="$(_ai_tree workflow-trailing-comment)"
  sed -i '/script:/ s|$|  # was: adb install -r /tmp/app.apk|' \
    "${t}/.github/workflows/e2e-lane.yml"
  _ai_expect_check_rc 27b 0 "${t}"

  # --- The check itself cannot run: rc 2, never a pass. ----------------------
  # (28) No harness directory at all.
  t="${tmp}/trees/empty"
  mkdir -p "${t}"
  _ai_expect_check_rc 28 2 "${t}"

  # (29) The one implementation is gone.
  t="$(_ai_tree no-lib)"
  rm -f "${t}/tooling/e2e/ci/app-install-lib.sh"
  _ai_expect_check_rc 29 2 "${t}"

  # (30) Too few driving lanes to trust: the extractor has gone blind.
  t="$(_ai_tree blind)"
  rm -f "${t}/tooling/e2e/ci/run-beta.sh"
  _ai_expect_check_rc 30 2 "${t}"

  # (31) A file that never closes its quote cannot be vouched for.
  t="$(_ai_tree unparseable)"
  printf "echo 'never closed\n" >> "${t}/tooling/e2e/ci/run-delegate.sh"
  _ai_expect_check_rc 31 2 "${t}"
}

app_install_lib_self_test() {
  local tmp fail=0 ran=0 ai_rc=0 real_timeout
  tmp="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf '${tmp}'" RETURN
  real_timeout="$(command -v timeout)" || {
    echo "SELF-TEST FAIL: no coreutils timeout on PATH" >&2
    return 1
  }

  _ai_write_stubs
  _ai_suite_timeout
  _ai_suite_fresh
  _ai_suite_app
  _ai_suite_pin

  if (( ran != APP_INSTALL_SELF_TEST_FIXTURES )); then
    echo "SELF-TEST FAIL: ran ${ran} fixtures, expected" \
         "${APP_INSTALL_SELF_TEST_FIXTURES}" >&2
    fail=1
  fi
  if (( fail != 0 )); then
    echo "app-install-lib.sh --self-test: FAILED" >&2
    return 1
  fi
  echo "app-install-lib.sh --self-test: all ${ran} fixtures passed"
}

# Executed directly (not sourced).
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  set -Eeuo pipefail
  case "${1:-}" in
    --self-test)
      app_install_lib_self_test
      exit $?
      ;;
    --check-installs)
      app_install_check_installs "${2:-}"
      exit $?
      ;;
  esac
  echo "app-install-lib.sh is a sourced library; pass --self-test or" \
       "--check-installs [<repo-root>] to run it directly." >&2
  exit 2
fi
