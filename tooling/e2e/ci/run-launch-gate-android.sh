#!/usr/bin/env bash
#
# Android launch gate: a RELEASE APK opens, onboards as far as an offline
# device can, keeps what it saved across a cold restart, and upgrades cleanly
# from the last good release. Run inside .github/workflows/launch-gate-android.yml's
# emulator step, under run-with-deadline.sh and the host egress guard.
#
# v0.1.14 died at every process start (WorkDatabase_Impl.<init> stripped by R8)
# and nothing in CI had ever launched a release build. This launches one the
# way a user does — the launcher activity, cold, with the production main() —
# and reads the screen through UiAutomator, which sees Flutter's semantics in a
# release build (CI run 43588108447 tapped through onboarding that way).
#
# # Legs
#
#   fresh     install the candidate fresh, onboard, cold restart.
#   upgrade   install the previous release fresh, onboard it, install the
#             candidate over it (a replace: its data stays), cold launch.
#   baseline  the upgrade leg from a fixed older release (v0.1.13), which
#             onboards to the map offline, so the candidate opens MapShell in
#             release mode. Run when LAUNCH_GATE_BASELINE_DIR is set; the
#             workflow leaves it unset when the baseline IS the previous
#             release.
#
# # Offline, and why that is the right network
#
# The guest is in airplane mode with no default network, and the host's egress
# guard rejects TCP 80/443 besides. A release build pins rustls to the bundled
# roots and production relays, so the only alternative to offline would be
# publishing to production from CI. Offline, current onboarding stops at
# "Couldn't finish setting up" (onboardingFinishSetupError, the reachability
# wait of OD-C) — the SETUP_HELD terminal — after creating the identity and
# saving the display name; a build from before OD-C goes on to the location
# disclosure and the map — the MAP terminal. A cold restart or an upgrade must
# then show the same terminal class, never the intro, and the very name the
# first launch saved: on the create screen at SETUP_HELD, on Settings > Identity
# at MAP. That name is SharedPreferences keyed by the public key of the identity
# the app loads from secure storage (the Android keystore), so the round trip
# proves the identity and the preferences survived. It does NOT prove SQLCipher:
# every value a user can see offline that SQLCipher holds has a fallback that
# hides a failed open (the circle list reads empty on any failure,
# circles_provider.dart:36-49; the Identity page's name falls back to the
# preferences copy, display_name_card.dart:200-229).
#
# # How the screen is read
#
# Every label is the APK's OWN app_en.arb value, resolved by ui-dump.py, which
# matches whole lines of a node's text or description. Keys a build's ARB does
# not have remove their state (a pre-OD-C ARB has no onboardingFinishSetupError);
# the welcome and create CTAs and commonSettings are required. A tap is judged
# by the screen digest (see the journey below): a label is tapped once per
# screen, never retried, and a tap after which the screen stays exactly as it
# was for the whole window is "did not progress", a product failure under the
# responsiveness pillar.
#
# # Verdicts
#
# Crash evidence is read before anything is blamed: the crash buffer naming the
# process, the events buffer's am_crash/am_anr for the package, or the process
# gone or replaced while it should be running. The crash summary — exception
# lines, `at` frames, `#nn pc <offset> <library>` native frames, random install
# paths removed — is written only then.
#
#   0  every leg passed
#   1  product: the candidate crashed, stalled, lost data, showed the intro
#      after onboarding, kept a debug log plant, or did not replace the
#      previous release
#   2  usage: a missing input
#   3  infrastructure: the device went away, never booted, is not en-US, or
#      would not go offline — nothing about the app is known
#   4  the upgrade source is unusable: the previous release itself failed
#      before the candidate was installed (yank it in
#      scripts/ci/launch_gate_yanked_releases.txt)
#
# One `::error::` line names the leg, the state reached, the last observation
# (visible keys, foreground package, EditText count) and the class. The summary
# and any crash summary are written under LAUNCH_GATE_OUT and passed through the
# log-privacy gate BEFORE either is echoed; the workflow uploads nothing else.
# The display name the app generated is held in a 0700 directory, declared to
# the gate (`--host-decl display_name=…`) so the scanner proves it absent, and
# never printed. UI dumps live in that directory and are deleted per read.
#
# Every wait is bounded by a readonly constant below and polls a condition;
# nothing sleeps. scripts/ci/e2e_lane_budget.manifest prices each one.
#
# Usage:
#   run-launch-gate-android.sh <candidate-dir> <previous-dir>
#     each dir: install.apk, app_en.arb, version_code, tag
#     env: LAUNCH_GATE_BASELINE_DIR (optional, same layout), LAUNCH_GATE_OUT
#          (default /tmp/launch-gate/out)
#   run-launch-gate-android.sh --self-test     stub adb driven by scenarios

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR="${script_dir}"

# shellcheck source=tooling/e2e/ci/app-install-lib.sh
source "${SCRIPT_DIR}/app-install-lib.sh"
# shellcheck source=tooling/e2e/ci/logscan-gate.sh
source "${SCRIPT_DIR}/logscan-gate.sh"

readonly PKG='com.oblivioustech.haven'
readonly ACTIVITY="${PKG}/.MainActivity"
readonly DEVICE='emulator-5554'
readonly UI_DUMP="${SCRIPT_DIR}/ui-dump.py"
# The rotated needle directory every scanning lane seals into; a constant, as
# rotate-needle-dir.sh's is.
readonly NEEDLE_DIR=/tmp/haven-soak/needles
readonly OUT_DIR="${LAUNCH_GATE_OUT:-/tmp/launch-gate/out}"
readonly SUMMARY="${OUT_DIR}/launch-gate-summary.log"
readonly CRASH_SUMMARY="${OUT_DIR}/crash-summary.log"
readonly LOGSCAN_REPORT="${OUT_DIR%/*}/launch-gate-logscan.ndjson"

# Bounds. The LAUNCH_GATE_* overrides exist for the self-test, whose stub device
# answers instantly; the workflow sets none of them.
readonly BOOT_SECS="${LAUNCH_GATE_BOOT_SECS:-60}"        # adb and boot_completed after the action's boot
readonly OFFLINE_SECS="${LAUNCH_GATE_OFFLINE_SECS:-30}"  # airplane mode and no default network
readonly LAUNCH_SECS="${LAUNCH_GATE_LAUNCH_SECS:-60}"    # `am start -W` to a drawn activity
readonly SCREEN_SECS="${LAUNCH_GATE_SCREEN_SECS:-60}"    # from one screen to the next
# After "Create My Identity": identity creation, then the 60 s reachability
# wait (create_identity_screen.dart finishSetupTimeout) before the error shows.
readonly FINISH_SECS="${LAUNCH_GATE_FINISH_SECS:-120}"
readonly DUMP_SECS="${LAUNCH_GATE_DUMP_SECS:-15}"        # one uiautomator dump
readonly PROCESS_SECS="${LAUNCH_GATE_PROCESS_SECS:-20}"  # a pid after launch, none after force-stop
readonly ADB_SECS="${LAUNCH_GATE_ADB_SECS:-10}"          # one polled adb read
# A whole onboarding, each window opening at the last tap: the intro, the
# create screen, the finish wait, and two disclosures on the way to the map
# (v0.1.13 asks for background location, then foreground).
readonly JOURNEY_SECS=$(( 4 * SCREEN_SECS + FINISH_SECS ))
# A cold reopen: the first screen, then a window after each tap on the way to
# the Identity page — a disclosure declined, Settings, Identity.
readonly REOPEN_SECS=$(( 4 * SCREEN_SECS ))
# After a candidate's terminal screen: how long it must stay up, unattended.
readonly SETTLE_SECS="${LAUNCH_GATE_SETTLE_SECS:-30}"

readonly KEY_WELCOME=onboardingWelcomeCta
readonly KEY_CREATE=onboardingCreateIdentityCta
readonly KEY_NOT_NOW=locationDisclosureNotNow
readonly KEY_SETUP_HELD=onboardingFinishSetupError
readonly KEY_MAP=commonSettings
readonly KEY_IDENTITY=settingsIdentityTitle
readonly KEY_IDENTITY_PAGE=identityTitle
# Optional: the Identity page's name card while it loads (its only plain-text
# "Display Name"; the loaded field carries it as a hint, which no dump shows).
readonly KEY_NAME_LOADING=displayNameCardTitle
readonly KEYS_FATAL='onboardingCreateIdentityError onboardingDisplayNameError'
readonly ALL_KEYS="${KEY_WELCOME},${KEY_CREATE},${KEY_NOT_NOW},${KEY_SETUP_HELD},${KEY_MAP},${KEY_IDENTITY},${KEY_IDENTITY_PAGE},${KEY_NAME_LOADING},onboardingCreateIdentityError,onboardingDisplayNameError"

# What the summary reports, set as the run goes.
LEG='preconditions'
STATE='-'
LEGS_DONE='none '
OBS_SUMMARY='no observation yet'
VERDICT_RC=''
VERDICT_MSG=''
UPGRADE_SOURCE=0
APP_PID=''
PRIV=''

# Set by observe.
OBS_FG=''
OBS_EDITS=0
OBS_KEYS=''
OBS_DIGEST=''
declare -A OBS_XY=()

say() { echo "[launch-gate] $*"; }

# verdict <rc> <message> — record the outcome and end the run; the EXIT trap
# classifies, writes, gates and reports. rc "" means "product unless the device
# is gone", decided once, in the trap.
verdict() {
  VERDICT_RC="$1"
  VERDICT_MSG="$2"
  exit 0
}

# ---------------------------------------------------------------------------
# Device reads.
# ---------------------------------------------------------------------------
dev() { adb -s "${DEVICE}" "$@"; }

# pid_now — the app's pid, or nothing when it is not running (pidof's rc 1);
# non-zero when adb gave no answer in time, which a caller polls past rather
# than reads as a death.
pid_now() {
  local out rc=0
  out="$(timeout "${ADB_SECS}" adb -s "${DEVICE}" shell pidof "${PKG}" 2>/dev/null)" || rc=$?
  (( rc == 0 || rc == 1 )) || return 1
  printf '%s' "${out//$'\r'/}"
}

# observe <arb> [<edit-value-file>] — one dump, read by ui-dump.py into OBS_*.
observe() {
  local arb="$1" edit_out="${2:-}" out rc=0 line w
  local -a extra=(--digest-out "${PRIV}/digest")
  OBS_FG=''; OBS_EDITS=0; OBS_KEYS=''; OBS_XY=(); OBS_DIGEST=''
  rm -f "${PRIV}/digest"
  timeout "${DUMP_SECS}" adb -s "${DEVICE}" exec-out \
    "uiautomator dump /sdcard/haven-launch-gate.xml >/dev/null 2>&1 && cat /sdcard/haven-launch-gate.xml; rm -f /sdcard/haven-launch-gate.xml" \
    > "${PRIV}/dump.xml" 2>/dev/null || true
  [[ -z "${edit_out}" ]] || extra+=(--edit-value-out "${edit_out}")
  out="$(python3 -I "${UI_DUMP}" observe --dump "${PRIV}/dump.xml" --package "${PKG}" \
    --arb "${arb}" --keys "${ALL_KEYS}" "${extra[@]}")" || rc=$?
  rm -f "${PRIV}/dump.xml"
  if (( rc == 2 )); then
    verdict 2 "ui-dump.py refused its input (see stderr)"
  fi
  (( rc == 0 )) || return 1
  OBS_DIGEST="$(cat "${PRIV}/digest")"
  rm -f "${PRIV}/digest"
  while IFS= read -r line; do
    read -r -a w <<<"${line}"
    case "${w[0]:-}" in
      foreground) OBS_FG="${w[1]}" ;;
      edittexts) OBS_EDITS="${w[1]}" ;;
      visible) OBS_KEYS+="${OBS_KEYS:+ }${w[1]}"; OBS_XY["${w[1]}"]="${w[2]} ${w[3]}" ;;
    esac
  done <<<"${out}"
  OBS_SUMMARY="visible [${OBS_KEYS:-none}], foreground ${OBS_FG}, edittexts ${OBS_EDITS}"
}

seen() { [[ " ${OBS_KEYS} " == *" $1 "* ]]; }

tap() { # tap <key> — at the centre ui-dump.py reported for it
  local x y
  read -r x y <<<"${OBS_XY[$1]}"
  dev shell input tap "${x}" "${y}" >/dev/null
  say "${LEG}: tapped ${1}"
}

# alive — the process launched for this leg is still the one running.
alive() {
  local now
  now="$(pid_now)" || return 0
  if [[ -z "${now}" ]]; then
    verdict '' "the app process died at state ${STATE}"
  fi
  if [[ "${now}" != "${APP_PID}" ]]; then
    verdict '' "the app process was replaced at state ${STATE} (a crash and restart)"
  fi
}

clear_logs() { dev logcat -b all -c >/dev/null 2>&1 || true; }

launch_app() {
  local out rc=0 deadline
  STATE='launch'
  out="$(timeout "${LAUNCH_SECS}" adb -s "${DEVICE}" shell am start -W -n "${ACTIVITY}" 2>&1 | tr -d '\r')" || rc=$?
  if ! grep -qx 'Status: ok' <<<"${out}"; then
    verdict '' "am start -W did not report 'Status: ok' within ${LAUNCH_SECS} s (rc ${rc})"
  fi
  deadline=$(( SECONDS + PROCESS_SECS ))
  while (( SECONDS < deadline )); do
    if APP_PID="$(pid_now)"; then
      if [[ -z "${APP_PID}" ]]; then
        verdict 1 "am start -W reported ok but no ${PKG} process is running"
      fi
      say "${LEG}: launched cold"
      return 0
    fi
  done
  verdict '' "adb gave no process list within ${PROCESS_SECS} s of the launch"
}

stop_app() {
  local deadline now
  dev shell am force-stop "${PKG}" >/dev/null 2>&1 || true
  deadline=$(( SECONDS + PROCESS_SECS ))
  while (( SECONDS < deadline )); do
    if now="$(pid_now)" && [[ -z "${now}" ]]; then
      APP_PID=''
      return 0
    fi
  done
  verdict '' "${PKG} was still running ${PROCESS_SECS} s after force-stop"
}

installed_version_code() {
  dev shell "dumpsys package ${PKG} | grep -m1 versionCode=" 2>/dev/null \
    | tr -d '\r' | sed -nE 's/.*versionCode=([0-9]+).*/\1/p'
}

# check_no_crash — the leg-end proof that nothing died behind the screen.
check_no_crash() {
  if crash_evidence; then
    verdict '' "crash evidence for ${PKG} at the end of the leg"
  fi
}

check_no_plant() {
  local n
  n="$(dev shell 'logcat -d | grep -c logscan-plant-' 2>/dev/null | tr -d '\r' || true)"
  if [[ ! "${n}" =~ ^[0-9]+$ ]]; then
    verdict '' "could not count debug log plants in logcat"
  fi
  if (( n > 0 )); then
    verdict 1 "a debug-only log plant (logscan-plant-*) reached logcat: this is not a release build's logging"
  fi
}

# crash_evidence — 0 when the device holds evidence that the app crashed or
# stopped responding. Read into memory only; never written raw.
CRASH_TEXT=''
crash_evidence() {
  local crash events
  crash="$(timeout "${ADB_SECS}" adb -s "${DEVICE}" logcat -d -b crash 2>/dev/null | tr -d '\r' || true)"
  events="$(timeout "${ADB_SECS}" adb -s "${DEVICE}" logcat -d -b events 2>/dev/null | tr -d '\r' || true)"
  CRASH_TEXT=''
  if grep -qE "Process: ${PKG//./\\.}(,|$)|>>> ${PKG//./\\.} <<<" <<<"${crash}"; then
    CRASH_TEXT="${crash}"
    return 0
  fi
  if grep -qE "am_(crash|anr)[^[]*\[[^]]*[[,]${PKG//./\\.}[],]" <<<"${events}"; then
    CRASH_TEXT="$(grep -E "am_(crash|anr)" <<<"${events}")"
    return 0
  fi
  return 1
}

# crash_summary — stdin a crash text, stdout the lines that say what died:
# threadtime prefixes stripped, native frames reduced to number, offset and
# library, random install paths and R8's 64-hex map id removed (the log-privacy
# gate rightly withholds a line carrying one, and with it the explanation).
crash_summary() {
  echo "crash evidence for ${PKG}:"
  awk '
    / am_(crash|anr) *: / { sub(/^.* am_/, "am_"); sub(/ *: /, ": "); print; next }
    { sub(/^[0-9][0-9]-[0-9][0-9] [0-9:.]+ +[0-9]+ +[0-9]+ [A-Z] [^:]*: /, "") }
    /#[0-9]+ pc [0-9a-f]+/ {
      match($0, /#[0-9]+ pc [0-9a-f]+/); f = substr($0, RSTART, RLENGTH)
      lib = $0; sub(/^.*#[0-9]+ pc [0-9a-f]+ +/, "", lib); sub(/ .*$/, "", lib); sub(/^.*\//, "", lib)
      print f " " lib; next
    }
    { gsub(/\/data\/app\/[^ ]*/, "<app>"); gsub(/r8-map-id-[0-9a-f]+/, "r8") }
    /FATAL EXCEPTION|Caused by:|^[[:space:]]*at |Exception|Error:|Fatal signal|Abort message/ { print }
  ' | head -n 80
}

# ---------------------------------------------------------------------------
# The journey: one launch from wherever the app opens to a terminal state.
#
# A tap is judged by the screen, not by its label. Each observation carries the
# screen digest (ui-dump.py: a sha256 of our window's text, kept in memory and
# never printed). A tap records the digest it was made on; ANY change to it is
# the tap taking effect, and the tap "did not progress" only when the digest
# stayed exactly that for the whole window after it. A label seen again on a
# different screen is a new screen: v0.1.13 declines the background disclosure
# and then shows the foreground one, another dialog with the same "Not now".
# A label is never tapped twice on one screen, and only on a screen two dumps
# in a row agree on, so a route still animating in is never tapped mid-way.
# ---------------------------------------------------------------------------
TERMINAL=''
TAP_KEY=''
TAP_DIGEST=''
PREV_DIGEST=''
STALL=0
NAME_UNREAD=0
declare -A TAPPED=()

# window_open <secs> — a fresh launch's tap state, and its first window.
window_open() {
  TAP_KEY=''; TAP_DIGEST=''; PREV_DIGEST=''; NAME_UNREAD=0; TAPPED=()
  STALL=$(( SECONDS + $1 ))
}

# act <name-file> <key>... — after an observation of our window: wait out a
# pending tap, or tap the first key on screen that this screen has not had.
act() {
  local name_file="$1" key settled=0
  shift
  if [[ "${OBS_DIGEST}" == "${PREV_DIGEST}" ]]; then settled=1; fi
  PREV_DIGEST="${OBS_DIGEST}"
  if [[ -n "${TAP_KEY}" ]]; then
    [[ "${OBS_DIGEST}" != "${TAP_DIGEST}" ]] || return 0
    TAP_KEY=''
  fi
  for key in "$@"; do
    seen "${key}" || continue
    [[ -z "${TAPPED[${key}|${OBS_DIGEST}]:-}" ]] || continue
    (( settled )) || return 0
    if [[ "${key}" == "${KEY_CREATE}" ]]; then
      if (( OBS_EDITS != 1 )) || [[ ! -s "${name_file}.read" ]]; then
        NAME_UNREAD=1
        continue
      fi
      mv "${name_file}.read" "${name_file}"
      STALL=$(( SECONDS + FINISH_SECS ))
    else
      STALL=$(( SECONDS + SCREEN_SECS ))
    fi
    tap "${key}"
    TAP_KEY="${key}"
    TAP_DIGEST="${OBS_DIGEST}"
    TAPPED["${key}|${OBS_DIGEST}"]=1
    STATE="after ${key}"
    return 0
  done
}

# stalled <foreign-package> — the verdict when a window closes without progress.
stalled() {
  if [[ -n "$1" ]]; then
    verdict 1 "$1 held the foreground at state ${STATE} until the deadline"
  fi
  if [[ -n "${TAP_KEY}" ]]; then
    verdict 1 "did not progress: the screen did not change in the window after ${TAP_KEY} was tapped"
  fi
  if (( NAME_UNREAD )); then
    verdict 1 "the create screen never showed exactly one non-empty name field, so the name it saves could not be checked"
  fi
}

# journey <arb> <name-file> — sets TERMINAL to SETUP_HELD or MAP.
journey() {
  local arb="$1" name_file="$2" deadline key foreign=''
  deadline=$(( SECONDS + JOURNEY_SECS ))
  window_open "${SCREEN_SECS}"
  STATE='first screen'
  while (( SECONDS < deadline )); do
    alive
    if (( SECONDS >= STALL )); then
      break
    fi
    observe "${arb}" "${name_file}.read" || continue
    if [[ "${OBS_FG}" != "${PKG}" ]]; then
      foreign="${OBS_FG}"
      continue
    fi
    foreign=''
    for key in ${KEYS_FATAL}; do
      if seen "${key}"; then verdict 1 "the app showed ${key} at state ${STATE}"; fi
    done
    if seen "${KEY_SETUP_HELD}"; then TERMINAL=SETUP_HELD; STATE="${TERMINAL}"; return 0; fi
    if seen "${KEY_MAP}"; then TERMINAL=MAP; STATE="${TERMINAL}"; return 0; fi
    act "${name_file}" "${KEY_NOT_NOW}" "${KEY_CREATE}" "${KEY_WELCOME}"
  done
  stalled "${foreign}"
  verdict 1 "no progress past state ${STATE} within its deadline"
}

# expect_reopened <arb> <name-file> — a cold launch after onboarding shows the
# same terminal class, never the intro, and the display name the source
# onboarded with: SETUP_HELD's create screen shows it, and a MAP launch is
# driven to Settings > Identity, whose name field must show it. That page is
# its title (identityTitle, the same "Identity" the Settings entry reads) with
# one EditText; Settings has none (settings_page.dart). On it nothing is ever
# tapped — its title would match the Settings entry — and the field, which
# seeds asynchronously, is read until it shows the name. The map's
# Settings button alone proves only SharedPreferences' onboarding flag; the
# name is read under the identity the app loads from secure storage (it is
# keyed by that identity's public key, nostr_identity_service.dart:444-449),
# so an update that loses the identity cannot pass. A map the location
# disclosure covers (a user who declined it is asked again, modally) is
# declined the way the journey declines it.
expect_reopened() {
  local arb="$1" name_file="$2" deadline key name_seen=0
  STATE="reopen (${TERMINAL})"
  deadline=$(( SECONDS + REOPEN_SECS ))
  window_open "${SCREEN_SECS}"
  while (( SECONDS < deadline )); do
    alive
    if (( SECONDS >= STALL )); then
      break
    fi
    observe "${arb}" "${name_file}.after" || continue
    [[ "${OBS_FG}" == "${PKG}" ]] || continue
    for key in ${KEYS_FATAL}; do
      if seen "${key}"; then verdict 1 "the app showed ${key} after a cold launch"; fi
    done
    if seen "${KEY_WELCOME}"; then
      verdict 1 "a cold launch after onboarding showed the intro again (onboarding state was lost)"
    fi
    if [[ "${TERMINAL}" == MAP ]] \
       && { seen "${KEY_NAME_LOADING}" || { seen "${KEY_IDENTITY_PAGE}" && (( OBS_EDITS == 1 )); }; }; then
      # The Identity page is up: the tap that opened it took effect.
      TAP_KEY=''
      if (( OBS_EDITS == 1 )); then
        name_seen=1
        if cmp -s "${name_file}" "${name_file}.after"; then
          rm -f "${name_file}.after"
          return 0
        fi
      fi
      continue
    fi
    if [[ "${TERMINAL}" == SETUP_HELD ]] && seen "${KEY_CREATE}" && (( OBS_EDITS == 1 )); then
      name_seen=1
      if cmp -s "${name_file}" "${name_file}.after"; then
        rm -f "${name_file}.after"
        return 0
      fi
    fi
    if [[ "${TERMINAL}" == MAP ]]; then
      act "${name_file}" "${KEY_NOT_NOW}" "${KEY_IDENTITY}" "${KEY_MAP}"
    fi
  done
  rm -f "${name_file}.after"
  stalled ''
  if (( name_seen )); then
    verdict 1 "a cold launch did not show the display name the first launch saved"
  fi
  verdict 1 "a cold launch did not reopen at ${TERMINAL} and show the saved display name"
}

# settle_watch <arb> — the screen a candidate reached stays up, unattended,
# for SETTLE_SECS, its process the same one throughout; the caller's
# check_no_crash then reads the crash and events buffers, so a crash or an ANR
# moments after MapShell's or the setup screen's first frame is still caught.
settle_watch() {
  local arb="$1" deadline
  STATE="${STATE}, settling"
  deadline=$(( SECONDS + SETTLE_SECS ))
  while (( SECONDS < deadline )); do
    alive
    observe "${arb}" || true
  done
}

# ---------------------------------------------------------------------------
# Legs.
# ---------------------------------------------------------------------------
leg_fresh() {
  local cand="$1"
  LEG='fresh'
  STATE='install'
  if ! install_fresh "${DEVICE}" "${cand}/install.apk"; then
    verdict '' "the candidate did not install fresh"
  fi
  dev shell pm grant "${PKG}" android.permission.POST_NOTIFICATIONS >/dev/null 2>&1 || true
  clear_logs
  launch_app
  journey "${cand}/app_en.arb" "${PRIV}/name.fresh"
  settle_watch "${cand}/app_en.arb"
  check_no_crash
  say "fresh: onboarded to ${TERMINAL}; restarting cold"
  local before="${APP_PID}"
  stop_app
  launch_app
  if [[ "${APP_PID}" == "${before}" ]]; then
    verdict 1 "the restart reused the old process"
  fi
  expect_reopened "${cand}/app_en.arb" "${PRIV}/name.fresh"
  settle_watch "${cand}/app_en.arb"
  check_no_crash
  check_no_plant
  LEGS_DONE="fresh=${TERMINAL} "
  say "fresh: passed (${TERMINAL} kept across a cold restart)"
}

# leg_upgrade <label> <source-dir> <candidate-dir>
leg_upgrade() {
  local label="$1" src="$2" cand="$3" vc name="${PRIV}/name.$1"
  LEG="${label} (from $(cat "${src}/tag"))"
  UPGRADE_SOURCE=1
  STATE='install'
  if ! install_fresh "${DEVICE}" "${src}/install.apk"; then
    verdict '' "the previous release did not install fresh"
  fi
  dev shell pm grant "${PKG}" android.permission.POST_NOTIFICATIONS >/dev/null 2>&1 || true
  dev shell pm grant "${PKG}" android.permission.ACCESS_FINE_LOCATION >/dev/null 2>&1 || true
  dev shell pm grant "${PKG}" android.permission.ACCESS_COARSE_LOCATION >/dev/null 2>&1 || true
  clear_logs
  launch_app
  journey "${src}/app_en.arb" "${name}"
  check_no_crash
  vc="$(installed_version_code)"
  if [[ "${vc}" != "$(cat "${src}/version_code")" ]]; then
    verdict '' "the device reports versionCode '${vc}' for the previous release, not $(cat "${src}/version_code")"
  fi
  say "${LEG}: the previous release onboarded to ${TERMINAL}; installing the candidate over it"
  stop_app
  UPGRADE_SOURCE=0
  STATE='upgrade install'
  # Before the install, so a crash during or right after it stays in evidence.
  clear_logs
  if ! install_app "${DEVICE}" "${cand}/install.apk"; then
    verdict 1 "the candidate did not install over the previous release"
  fi
  vc="$(installed_version_code)"
  if [[ "${vc}" != "$(cat "${cand}/version_code")" ]]; then
    verdict 1 "after the upgrade the device reports versionCode '${vc}', not the candidate's $(cat "${cand}/version_code")"
  fi
  launch_app
  expect_reopened "${cand}/app_en.arb" "${name}"
  settle_watch "${cand}/app_en.arb"
  check_no_crash
  check_no_plant
  LEGS_DONE+="${label}=${TERMINAL} "
  say "${LEG}: passed (${TERMINAL} kept across the upgrade)"
}

# ---------------------------------------------------------------------------
# Preconditions: a booted en-US device, offline, with error dialogs hidden.
# ---------------------------------------------------------------------------
preconditions() {
  local boot_deadline offline_deadline boot locale air net
  if ! timeout "${BOOT_SECS}" adb -s "${DEVICE}" wait-for-device; then
    verdict 3 "${DEVICE} did not come online within ${BOOT_SECS} s"
  fi
  boot_deadline=$(( SECONDS + BOOT_SECS ))
  while (( SECONDS < boot_deadline )); do
    boot="$(timeout "${ADB_SECS}" adb -s "${DEVICE}" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r' || true)"
    [[ "${boot}" == 1 ]] && break
  done
  [[ "${boot:-}" == 1 ]] || verdict 3 "sys.boot_completed never read 1 within ${BOOT_SECS} s"
  locale="$(dev shell getprop persist.sys.locale 2>/dev/null | tr -d '\r' || true)"
  [[ -n "${locale}" ]] || locale="$(dev shell getprop ro.product.locale 2>/dev/null | tr -d '\r' || true)"
  if [[ "${locale}" != en-US ]]; then
    verdict 3 "the device locale is '${locale}', not en-US: the gate reads the English ARB's labels"
  fi
  dev shell settings put global hide_error_dialogs 1 >/dev/null 2>&1 || true
  if [[ "$(dev shell settings get global hide_error_dialogs 2>/dev/null | tr -d '\r')" != 1 ]]; then
    verdict 3 "hide_error_dialogs did not read back 1"
  fi
  dev shell cmd connectivity airplane-mode enable >/dev/null 2>&1 || true
  # "Active default network: none" is ConnectivityService.dump()'s line when
  # no network is the default (AOSP android-14); read from source, so a guest
  # that prints anything else is refused here, by name, rather than trusted.
  offline_deadline=$(( SECONDS + OFFLINE_SECS ))
  while (( SECONDS < offline_deadline )); do
    air="$(timeout "${ADB_SECS}" adb -s "${DEVICE}" shell settings get global airplane_mode_on 2>/dev/null | tr -d '\r' || true)"
    net="$(timeout "${ADB_SECS}" adb -s "${DEVICE}" shell "dumpsys connectivity | grep -m1 'Active default network:'" 2>/dev/null | tr -d '\r' || true)"
    if [[ "${air}" == 1 && "${net}" =~ Active\ default\ network:\ none$ ]]; then
      say "device ready: booted, en-US, airplane mode on, no default network"
      return 0
    fi
  done
  verdict 3 "the device did not go offline within ${OFFLINE_SECS} s (airplane_mode_on='${air:-}', '${net:-no default-network line}')"
}

# ---------------------------------------------------------------------------
# The EXIT trap: classify, write, gate, then — only then — echo.
# ---------------------------------------------------------------------------
finish() {
  local rc=$? cls gate_rc=0 cause=''
  local -a decls=()
  local f
  if [[ -z "${VERDICT_MSG}" ]]; then
    VERDICT_RC=''
    VERDICT_MSG="the runner stopped unexpectedly (rc ${rc}) at state ${STATE}"
  fi
  rm -f "${CRASH_SUMMARY}"
  if [[ "${VERDICT_RC}" != 0 && "${VERDICT_RC}" != 2 ]] && crash_evidence; then
    crash_summary <<<"${CRASH_TEXT}" > "${CRASH_SUMMARY}"
    VERDICT_MSG="the app crashed (${VERDICT_MSG})"
    VERDICT_RC=1
  elif [[ -z "${VERDICT_RC}" ]]; then
    if [[ "$(timeout "${ADB_SECS}" adb -s "${DEVICE}" get-state 2>/dev/null | tr -d '\r')" == device ]]; then
      VERDICT_RC=1
    else
      VERDICT_RC=3
      VERDICT_MSG="${DEVICE} went offline (${VERDICT_MSG})"
    fi
  fi
  if (( VERDICT_RC == 1 && UPGRADE_SOURCE == 1 )); then
    VERDICT_RC=4
  fi
  case "${VERDICT_RC}" in
    0) cls='pass' ;; 1) cls='product' ;; 2) cls='usage' ;; 3) cls='infrastructure' ;;
    4) cls='upgrade source unusable — yank it in scripts/ci/launch_gate_yanked_releases.txt' ;;
  esac
  {
    echo "launch-gate-android verdict: ${cls} (rc ${VERDICT_RC})"
    echo "leg: ${LEG}; state: ${STATE}; last observation: ${OBS_SUMMARY}"
    echo "reason: ${VERDICT_MSG}"
    echo "legs passed: ${LEGS_DONE% }"
  } > "${SUMMARY}"
  if [[ -n "${PRIV}" ]]; then
    for f in "${PRIV}"/name.*; do
      [[ -s "${f}" ]] && decls+=(--host-decl "display_name=$(cat "${f}")")
    done
  fi
  local -a sinks=(--sink "diag=${SUMMARY}")
  [[ ! -f "${CRASH_SUMMARY}" ]] || sinks+=(--sink "diag=${CRASH_SUMMARY}")
  logscan_gate host "${NEEDLE_DIR}" ${decls[@]+"${decls[@]}"} -- "${sinks[@]}" \
    --report "${LOGSCAN_REPORT}" || gate_rc=$?
  [[ -z "${PRIV}" ]] || rm -rf "${PRIV}"
  if (( gate_rc != 0 )); then
    echo "::error::launch-gate-android: the log-privacy gate refused the summary (rc ${gate_rc}); it is not shown. Verdict class: ${cls}."
    exit $(( VERDICT_RC == 0 ? 1 : VERDICT_RC ))
  fi
  cat "${SUMMARY}"
  if [[ -f "${CRASH_SUMMARY}" ]]; then
    echo "--- crash summary ---"
    cat "${CRASH_SUMMARY}"
    cause="$(grep -E 'Caused by:|Exception|Fatal signal' "${CRASH_SUMMARY}" | tail -n 1 || true)"
  fi
  if (( VERDICT_RC != 0 )); then
    echo "::error::launch-gate-android ${cls}: leg ${LEG}, state ${STATE}; ${VERDICT_MSG}${cause:+; ${cause}}; last observation: ${OBS_SUMMARY}"
  fi
  exit "${VERDICT_RC}"
}

# ---------------------------------------------------------------------------
# Self-test. A stub `adb` plays a device: the install, the barrier, airplane
# mode, `am start -W`, pidof, `input tap`, the crash and events buffers, and a
# small model of Haven's onboarding whose screens it renders as uiautomator
# XML, so the real ui-dump.py reads them. Each APK is a text file naming the
# flow it plays and its versionCode. Scenarios are environment knobs on the
# stub. Logs go through the real logscan-gate.sh and scan-logs.sh with the
# shared fake scanner. Deadlines are shrunk through the LAUNCH_GATE_*_SECS
# overrides only for scenarios that must run one out; every other verdict
# comes from what the stub shows, not from time.
# ---------------------------------------------------------------------------
readonly SELF_TEST_FIXTURES=44
readonly ST_NAME='Quiet Wanderer Fixture'

_st_write_stub() { # <dir>
  cat > "$1/adb" <<'STUB'
#!/usr/bin/env bash
# The launch gate's stub device. State lives in files under ${STUB}.
S="${STUB}"
printf '%s\n' "$*" >> "${S}/calls"
[[ "${1:-}" == -s ]] && shift 2
if [[ -f "${S}/offline" ]]; then echo "error: device offline" >&2; exit 1; fi
PKG=com.oblivioustech.haven
get() { cat "${S}/$1" 2>/dev/null || true; }
put() { printf '%s\n' "$2" > "${S}/$1"; }
flow() { sed -n 's/^flow //p' "$(get installed)"; }
tt() { echo "11-14 12:00:00.000  4242  4242 E AndroidRuntime: $*"; }
node() { # <class> <text> <desc> <bounds> [pkg]
  printf '<node index="0" text="%s" resource-id="" class="%s" package="%s" content-desc="%s" clickable="true" enabled="true" bounds="%s"/>' \
    "$2" "$1" "${5:-${PKG}}" "$3" "$4"
}
body_of() {
  local scr="$1" body=''
  case "${scr}" in
    blank) body="$(node android.view.View '' '' '[0,0][1080,2400]')" ;;
    intro) body="$(node android.widget.Button 'Get Started' '' '[40,2200][1040,2300]')" ;;
    create) body="$(node "${STUB_EDIT_CLASS:-android.widget.EditText}" "$(get shown_name)" '' '[40,900][1040,1000]')$(node android.widget.Button 'Create My Identity' '' '[40,2200][1040,2300]')" ;;
    finishing) body="$(node android.widget.EditText "$(get shown_name)" '' '[40,900][1040,1000]')$(node android.view.View '' 'Finishing setup…' '[40,2200][1040,2300]')" ;;
    held) body="$(node android.widget.EditText "$(get shown_name)" '' '[40,900][1040,1000]')$(node android.view.View 'Couldn&apos;t finish setting up your account. Check your connection and try again.' '' '[40,1100][1040,1200]')$(node android.widget.Button 'Retry' '' '[40,2200][1040,2300]')" ;;
    name_error) body="$(node android.view.View 'Couldn’t save that name. Please try again.' '' '[40,2000][1040,2100]')" ;;
    # v0.1.13's two disclosures: one button label, two dialogs. The map's
    # is modal, so the map under it is not in the tree.
    bg_disclosure) body="$(node android.view.View 'Share your location in the background?' '' '[40,900][1040,1000]')$(node android.widget.Button 'Not now' '' '[40,2000][500,2100]')" ;;
    fg_disclosure) body="$(node android.view.View 'Share your location while you use Haven?' '' '[40,900][1040,1000]')$(node android.widget.Button 'Not now' '' '[40,2000][500,2100]')" ;;
    map) body="$(node android.widget.Button '' 'Settings' '[900,100][1000,200]')" ;;
    settings) body="$(node android.view.View 'Settings' '' '[40,100][600,200]')$(node android.widget.Button 'Identity' '' '[40,300][1040,400]')$(node android.widget.Button 'Relays' '' '[40,450][1040,550]')" ;;
    # The Identity page as the real tree has it: the app-bar title "Identity"
    # (the Settings entry's words too) and, once loaded, ONE EditText whose
    # "Display Name" label is a hint no dump shows. While the card loads
    # (STUB_IDENTITY_LOADING dumps, default 1) it shows "Display Name" as plain
    # text and no field. The field holds the saved name, read under the
    # identity — empty when STUB_IDENTITY_LOST.
    identity) body="$(node android.view.View 'Identity' '' '[40,100][600,200]')"
      if (( $(get identity_dumps) > ${STUB_IDENTITY_LOADING:-1} )); then
        body+="$(node android.widget.EditText "$([[ -n "${STUB_IDENTITY_LOST:-}" ]] || cat "${S}/data/name")" '' '[40,900][1040,1000]')"
      else
        body+="$(node android.view.View 'Display Name' '' '[40,800][1040,850]')"
      fi ;;
  esac
  printf '%s' "${body}"
}
screen_xml() { # <screen> [<outgoing screen still in the tree>]
  local scr="$1" body
  body="${2:+$(body_of "$2")}$(body_of "${scr}")"
  printf "<?xml version='1.0' encoding='UTF-8' standalone='yes' ?><hierarchy rotation=\"0\">"
  if [[ -n "${STUB_FOREIGN:-}" && "${scr}" == create ]]; then
    node android.widget.FrameLayout '' '' '[0,0][1080,2400]' com.android.permissioncontroller
  else
    printf '<node index="0" text="" resource-id="" class="android.widget.FrameLayout" package="%s" content-desc="" bounds="[0,0][1080,2400]">%s</node>' "${PKG}" "${body}"
  fi
  printf '</hierarchy>'
}
launch() {
  local f; f="$(flow)"
  put dumps 0
  if [[ "${f}" == crash-at-start ]]; then
    { tt "FATAL EXCEPTION: main"; tt "Process: ${PKG}, PID: 4242"
      tt "java.lang.RuntimeException: Unable to get provider androidx.startup.InitializationProvider: androidx.startup.StartupException"
      tt "	at android.app.ActivityThread.installProvider(ActivityThread.java:7660)"
      tt "	at dz2.a(r8-map-id-$(printf '2%.0s' {1..64}):535)"
      tt "Caused by: java.lang.NoSuchMethodException: androidx.work.impl.WorkDatabase_Impl.<init> []"
      echo "11-14 12:00:00.000  4242  4242 F DEBUG   :       #00 pc 000000000005e8b4  /data/app/~~Zq1x==/${PKG}-Ab2==/lib/x86_64/librust_lib_haven.so (BuildId: 1a2b)"
    } >> "${S}/crash.log"
    rm -f "${S}/pid"
  else
    put pid $(( $(get pidseq) + 1 )); put pidseq "$(get pid)"
    rm -f "${S}/leaving"
    # Declining the foreground disclosure is asked again on every launch.
    if [[ -f "${S}/data/completed" ]]; then put screen fg_disclosure
    elif [[ -f "${S}/data/intro_seen" && -z "${STUB_FORGET_INTRO:-}" ]]; then
      put screen create; put shown_name 'Fresh Random Name'; put restore_pending 1
    else put screen intro; fi
    [[ -z "${STUB_ANR:-}" ]] || echo "11-14 12:00:01.000   500   600 I am_anr  : [0,4242,${PKG},952745540,Input dispatching timed out]" >> "${S}/events.log"
  fi
  printf 'Starting: Intent { cmp=%s/.MainActivity }\nStatus: ok\nLaunchState: COLD\nActivity: %s/.MainActivity\nTotalTime: 812\nWaitTime: 815\nComplete\n' "${PKG}" "${PKG}"
}
dump() {
  local n scr
  n=$(( $(get dumps) + 1 )); put dumps "${n}"
  [[ -n "$(get pid)" ]] || return 0
  if (( n == 3 )) && [[ -n "${STUB_PID_FLIP:-}" ]]; then put pid 9999; fi
  scr="$(get screen)"
  if (( n == 1 )); then screen_xml blank; return 0; fi
  # A route still on its way out: one dump of the old screen alone, then one
  # with both, then the new one.
  if [[ -n "$(get leaving)" ]]; then
    put leaving_dumps $(( $(get leaving_dumps) + 1 ))
    if (( $(get leaving_dumps) == 1 )); then screen_xml "$(get leaving)"; return 0; fi
    screen_xml "${scr}" "$(get leaving)"; rm -f "${S}/leaving"; return 0
  fi
  if [[ "${scr}" == create && -n "$(get restore_pending)" && -z "${STUB_NAME_LOST:-}" ]] && (( n >= 3 )); then
    put shown_name "$(cat "${S}/data/name")"; rm -f "${S}/restore_pending"
  fi
  if [[ "${scr}" == finishing ]]; then
    put fin $(( $(get fin) + 1 )); (( $(get fin) < 3 )) || put screen held
  fi
  [[ "${scr}" != identity ]] || put identity_dumps $(( $(get identity_dumps) + 1 ))
  # A crash moments after a terminal screen's first frames.
  if [[ -n "${STUB_LATE_CRASH:-}" && ( "${scr}" == held || "${scr}" == identity ) ]]; then
    put late $(( $(get late) + 1 ))
    if (( $(get late) == 3 )); then
      tt "FATAL EXCEPTION: main" >> "${S}/crash.log"; tt "Process: ${PKG}, PID: 4242" >> "${S}/crash.log"
      tt "java.lang.IllegalStateException: late" >> "${S}/crash.log"
      rm -f "${S}/pid"; return 0
    fi
  fi
  screen_xml "${scr}"
}
tap() {
  local x="$1" y="$2" scr; scr="$(get screen)"
  [[ -z "${STUB_TRANSITION:-}" ]] || { put leaving "${scr}"; put leaving_dumps 0; }
  case "${scr}" in
    intro) (( y >= 2200 && y <= 2300 )) || return 0
      [[ -n "${STUB_CTA_STUCK:-}" ]] && return 0
      touch "${S}/data/intro_seen"; put shown_name "${STUB_NAME}"; put screen create ;;
    create) (( y >= 2200 && y <= 2300 )) || return 0
      get shown_name > "${S}/data/name"
      case "$(flow)" in
        setup-held) put fin 0; put screen finishing ;;
        map) put screen bg_disclosure ;;
        name-error) put screen name_error ;;
      esac ;;
    bg_disclosure) (( x <= 500 && y >= 2000 && y <= 2100 )) || return 0
      touch "${S}/data/completed"; put screen fg_disclosure ;;
    fg_disclosure) (( x <= 500 && y >= 2000 && y <= 2100 )) || return 0
      put screen map ;;
    map) (( x >= 900 && x <= 1000 && y >= 100 && y <= 200 )) || return 0
      put screen settings ;;
    settings) (( y >= 300 && y <= 400 )) || return 0
      put identity_dumps 0; put screen identity ;;
  esac
}
case "${1:-}" in
  wait-for-device) exit 0 ;;
  get-state) echo device; exit 0 ;;
  uninstall) rm -f "${S}/installed" "${S}/data/"*; exit 0 ;;
  install) apk="${!#}"
    if [[ -f "${S}/installed" ]]; then
      [[ -n "${STUB_VC_UNCHANGED:-}" ]] || put vc "$(sed -n 's/^vc //p' "${apk}")"
      # A crash the replace provokes (a receiver of MY_PACKAGE_REPLACED, say).
      if [[ -n "${STUB_CRASH_ON_REPLACE:-}" ]]; then
        { tt "FATAL EXCEPTION: main"; tt "Process: ${PKG}, PID: 4243"; tt "java.lang.IllegalStateException: replaced"; } >> "${S}/crash.log"
      fi
    else rm -f "${S}/data/"*; put vc "$(sed -n 's/^vc //p' "${apk}")"; fi
    cp "${apk}" "${S}/apk.$(get pidseq).$RANDOM"; put installed "${apk}"
    echo "Performing Streamed Install"; echo "Success"; exit 0 ;;
  logcat)
    case "$*" in
      "logcat -b all -c") : > "${S}/crash.log"; : > "${S}/events.log" ;;
      "logcat -d -b crash") cat "${S}/crash.log" ;;
      "logcat -d -b events") cat "${S}/events.log" ;;
    esac; exit 0 ;;
  exec-out) dump; exit 0 ;;
  shell) shift ;;
  *) exit 9 ;;
esac
cmd="$*"
case "${cmd}" in
  "pm path ${PKG}") [[ -f "${S}/installed" ]] && echo "package:/data/app/~~x==/${PKG}-y==/base.apk"; exit 0 ;;
  "cmd package wait-for-handler"*) echo; echo "haven-barrier-rc 0 0 255 255" ;;
  "am force-stop ${PKG}") rm -f "${S}/pid" ;;
  "pm grant "*) : ;;
  "getprop sys.boot_completed") echo 1 ;;
  "getprop persist.sys.locale") echo "" ;;
  "getprop ro.product.locale") echo "${STUB_LOCALE:-en-US}" ;;
  "settings put global hide_error_dialogs 1") touch "${S}/hide" ;;
  "settings get global hide_error_dialogs") [[ -f "${S}/hide" ]] && echo 1 || echo 0 ;;
  "cmd connectivity airplane-mode enable") [[ -n "${STUB_AIRPLANE_STUCK:-}" ]] || touch "${S}/airplane" ;;
  "settings get global airplane_mode_on") [[ -f "${S}/airplane" ]] && echo 1 || echo 0 ;;
  "dumpsys connectivity | grep -m1 'Active default network:'")
    [[ -f "${S}/airplane" ]] && echo "Active default network: none" || echo "Active default network: 100" ;;
  "am start -W -n ${PKG}/.MainActivity")
    if [[ -n "${STUB_OFFLINE_AT_LAUNCH:-}" && -f "${S}/data/intro_seen" ]]; then touch "${S}/offline"; exit 1; fi
    launch ;;
  "pidof ${PKG}")
    # Every other read is one adb cannot answer (its own rc 255).
    put pidof_reads $(( $(get pidof_reads) + 1 ))
    if [[ -n "${STUB_PIDOF_FLAKY:-}" ]] && (( $(get pidof_reads) % 2 == 1 )); then exit 255; fi
    [[ -n "$(get pid)" ]] || exit 1; get pid ;;
  "input tap "*) read -r _ _ x y <<<"${cmd}"; tap "${x}" "${y}" ;;
  "dumpsys package ${PKG} | grep -m1 versionCode=") echo "    versionCode=$(get vc) minSdk=24 targetSdk=35" ;;
  "logcat -d | grep -c logscan-plant-") echo "${STUB_PLANTS:-0}" ;;
  *) exit 9 ;;
esac
exit 0
STUB
  chmod +x "$1/adb"
}

self_test() {
  local tmp fails=0 ran=0 rc out
  tmp="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf '${tmp}'" RETURN
  mkdir -p "${tmp}/bin" "${tmp}/priv"
  _st_write_stub "${tmp}/bin"
  local arb_now arb_old
  arb_now="$(python3 -I -c 'import json, sys
k = sys.argv[1:]
print(json.dumps({k[0]: "Get Started", k[1]: "Create My Identity", k[2]: "Not now",
  k[3]: "Couldn\x27t finish setting up your account. Check your connection and try again.",
  k[4]: "Settings", k[5]: "Identity", k[6]: "Identity", k[7]: "Display Name",
  "onboardingCreateIdentityError": "Something went wrong creating your identity. Please try again.",
  "onboardingDisplayNameError": "Couldn\u2019t save that name. Please try again."}))' \
    "${KEY_WELCOME}" "${KEY_CREATE}" "${KEY_NOT_NOW}" "${KEY_SETUP_HELD}" "${KEY_MAP}" "${KEY_IDENTITY}" "${KEY_IDENTITY_PAGE}" "${KEY_NAME_LOADING}")"
  # A pre-OD-C ARB, as v0.1.13's: no onboardingFinishSetupError.
  arb_old="$(python3 -I -c 'import json,sys; d=json.loads(sys.argv[1]); d.pop("onboardingFinishSetupError"); print(json.dumps(d))' "${arb_now}")"

  _mkdir() { # <dir> <tag> <vc> <flow> <arb-json>
    mkdir -p "$1"
    printf 'flow %s\nvc %s\n' "$4" "$3" > "$1/install.apk"
    printf '%s\n' "$5" > "$1/app_en.arb"
    printf '%s\n' "$3" > "$1/version_code"
    printf '%s\n' "$2" > "$1/tag"
  }
  # _scenario <label> <want-rc> <cand-flow> <prev-flow> [VAR=value...]
  _scenario() {
    local label="$1" want_rc="$2" cf="$3" pf="$4"
    shift 4
    ran=$(( ran + 1 ))
    rm -rf "${tmp}/stub" "${tmp}/cand" "${tmp}/prev" "${tmp}/out" "${tmp}/priv" "${tmp}/seal.argv"
    mkdir -p "${tmp}/stub/data" "${tmp}/priv"
    : > "${tmp}/stub/crash.log"; : > "${tmp}/stub/events.log"; echo 4000 > "${tmp}/stub/pidseq"
    _mkdir "${tmp}/cand" candidate 4022 "${cf}" "${ARB_CAND:-${arb_now}}"
    _mkdir "${tmp}/prev" v0.1.13 4020 "${pf}" "${ARB_PREV:-${arb_old}}"
    rc=0
    out="$(env PATH="${tmp}/bin:${PATH}" STUB="${tmp}/stub" STUB_NAME="${ST_NAME}" TMPDIR="${tmp}/priv" \
      LAUNCH_GATE_OUT="${tmp}/out/summary" \
      HAVEN_LOGSCAN=true HAVEN_LOGSCAN_BIN="${LOGSCAN_FAKE_BIN}" FAKE_SEAL_ARGV="${tmp}/seal.argv" \
      GITHUB_RUN_ID="launch-gate-self-test-$$-${ran}" GITHUB_RUN_ATTEMPT=1 LAUNCH_GATE_SCREEN_SECS=3 LAUNCH_GATE_FINISH_SECS=3 \
      LAUNCH_GATE_OFFLINE_SECS=2 LAUNCH_GATE_PROCESS_SECS=2 LAUNCH_GATE_SETTLE_SECS=1 "$@" \
      bash "${BASH_SOURCE[0]}" "${tmp}/cand" "${tmp}/prev" 2>&1)" || rc=$?
    if (( rc == want_rc )); then
      printf '  PASS %s\n' "${label}"
    else
      printf '  FAIL %s (want rc %s, got %s)\n%s\n' "${label}" "${want_rc}" "${rc}" "${out}" >&2
      fails=1
    fi
    # Every scenario: the generated name never reaches the transcript or the
    # summaries, and the private directory is gone.
    if grep -qF -- "${ST_NAME}" <<<"${out}" || grep -rqF -- "${ST_NAME}" "${tmp}/out" 2>/dev/null; then
      printf '  FAIL %s: the display name reached the transcript or a summary\n' "${label}" >&2
      fails=1
    fi
    # …nor does a screen digest, which hashes that name (no 64-hex string at all).
    if grep -Eq '[0-9a-f]{64}' <<<"${out}" || grep -rEq '[0-9a-f]{64}' "${tmp}/out" 2>/dev/null; then
      printf '  FAIL %s: a 64-hex string (a screen digest?) reached the transcript or a summary\n' "${label}" >&2
      fails=1
    fi
    if [[ -n "$(ls -A "${tmp}/priv")" ]]; then
      printf '  FAIL %s: the private directory was left behind\n' "${label}" >&2
      fails=1
    fi
  }
  _has() { # <label> <fixed-string> — the last transcript names it
    ran=$(( ran + 1 ))
    if grep -qF -- "$2" <<<"${out}"; then printf '  PASS %s\n' "$1"; else
      printf '  FAIL %s: transcript lacks "%s"\n%s\n' "$1" "$2" "${out}" >&2; fails=1; fi
  }

  echo "run-launch-gate-android.sh --self-test"
  # (1) The current product: fresh SETUP_HELD with the name restored; the
  #     upgrade from a pre-OD-C release that reaches the map.
  #     The previous release is v0.1.13-shaped: it declines the background
  #     disclosure, then the foreground one (same "Not now", another dialog),
  #     and the upgraded candidate's map opens under that dialog again.
  _scenario "a healthy candidate passes every leg" 0 setup-held map
  _has "…fresh ends SETUP_HELD and upgrade MAP" "legs passed: fresh=SETUP_HELD upgrade=MAP"
  _taps() { # <label> — the run made exactly the nine taps the flows need
    ran=$(( ran + 1 ))
    local n
    n="$(grep -c '^-s emulator-5554 shell input tap ' "${tmp}/stub/calls" || true)"
    if [[ "${n}" == 9 ]]; then printf '  PASS %s\n' "$1"; else
      printf '  FAIL %s: %s taps, want 9 (welcome and create, twice; two disclosures; the reopened map'"'"'s disclosure, Settings, Identity)\n' "$1" "${n}" >&2; fails=1; fi
  }
  _taps "…with every CTA tapped once per screen it appeared on: 9 taps"
  # (4) Each tap's outgoing screen stays in the tree for two dumps (alone,
  #     then beside the new one): a label still visible mid-transition is
  #     neither "did not progress" nor tapped again.
  _scenario "a tapped label still on screen during a transition is not a stall" 0 setup-held map STUB_TRANSITION=1
  _taps "…and is never tapped twice: still 9 taps"
  # (6) The Identity page whose card is still loading for three dumps: its
  #     title reads like the Settings entry, and is never tapped.
  _scenario "an Identity page still loading is waited on, its title never tapped" 0 setup-held map STUB_IDENTITY_LOADING=3
  _taps "…still 9 taps"
  # (8) The scanner is told the generated name, so it proves it absent.
  ran=$(( ran + 1 ))
  if grep -qxF -- "display_name=${ST_NAME}" "${tmp}/seal.argv"; then echo "  PASS the generated name is declared to the log-privacy gate"; else
    echo "  FAIL the generated name was not declared to the seal" >&2; fails=1; fi
  # (9) The v0.1.14 crash: product, the crash summary names the missing
  #     constructor, the native frame is reduced and the install path gone.
  _scenario "a candidate that crashes at start is a product failure" 1 crash-at-start map
  _has "…and the ::error:: line names the missing constructor" "WorkDatabase_Impl.<init>"
  _has "…native frames reduced to number, offset and library" "#00 pc 000000000005e8b4 librust_lib_haven.so"
  ran=$(( ran + 1 ))
  if grep -q '/data/app/' <<<"${out}"; then echo "  FAIL the random install path reached the transcript" >&2; fails=1
  else echo "  PASS random install paths are removed"; fi
  ran=$(( ran + 1 ))
  if grep -Eq 'r8-map-id-[0-9a-f]' <<<"${out}"; then echo "  FAIL R8's map id reached the transcript" >&2; fails=1
  else echo "  PASS R8's map id is removed from Java frames"; fi
  # (14) The crash summary is echoed only after the log-privacy gate.
  ran=$(( ran + 1 ))
  local gate_at echo_at
  gate_at="$(grep -n '^scan-logs: ' <<<"${out}" | head -n 1 | cut -d: -f1)"
  echo_at="$(grep -n -- '--- crash summary ---' <<<"${out}" | head -n 1 | cut -d: -f1)"
  if [[ -n "${gate_at}" && -n "${echo_at}" ]] && (( gate_at < echo_at )); then
    echo "  PASS the crash summary is echoed only after the log-privacy gate"
  else
    echo "  FAIL the crash summary is echoed only after the log-privacy gate (gate line ${gate_at:-none}, echo line ${echo_at:-none})" >&2; fails=1
  fi
  # (15) A gate that finds a leak: nothing is echoed and the run is red.
  _scenario "a summary the gate refuses is never echoed" 1 crash-at-start map FAKE_SCAN_RC=1
  ran=$(( ran + 1 ))
  if grep -q -- '--- crash summary ---\|^launch-gate-android verdict' <<<"${out}"; then
    echo "  FAIL a refused summary was echoed" >&2; fails=1
  else echo "  PASS …and neither summary reaches the transcript"; fi
  # (17) The previous release crashing is the upgrade source, not the candidate.
  _scenario "a previous release that crashes is rc 4 (upgrade source unusable)" 4 setup-held crash-at-start
  # (18) A process replaced mid-journey.
  _scenario "a pid change mid-journey is a product failure" 1 setup-held map STUB_PID_FLIP=1
  # (19) A pid read adb cannot answer is polled past, never read as a death.
  _scenario "an unanswered pid read is not a death" 0 setup-held map STUB_PIDOF_FLAKY=1
  # (20) An ANR in the events buffer.
  _scenario "an am_anr for the package is a product failure" 1 setup-held map STUB_ANR=1
  _has "…reported as a crash" "the app crashed"
  # (22) Onboarding forgotten across the restart.
  _scenario "the intro after a cold restart is a product failure" 1 setup-held map STUB_FORGET_INTRO=1
  _has "…named as lost onboarding state" "showed the intro again"
  # (24) The saved name not restored.
  _scenario "a display name that is not restored is a product failure" 1 setup-held map STUB_NAME_LOST=1
  _has "…named as such" "did not show the display name the first launch saved"
  # An upgrade that keeps the onboarding flag and loses the identity: the map
  # opens, but the Identity page has no name.
  _scenario "an upgraded map whose Identity page lost the name is a product failure" 1 setup-held map STUB_IDENTITY_LOST=1
  _has "…named at the upgrade leg's Identity page" "leg upgrade (from v0.1.13), state after settingsIdentityTitle; a cold launch did not show the display name the first launch saved"
  # A crash moments after a terminal screen is drawn.
  _scenario "a crash just after the setup screen or the Identity page is a product failure" 1 setup-held map STUB_LATE_CRASH=1
  _has "…caught by the settle watch" "state: SETUP_HELD, settling"
  # A crash the upgrade's own install provokes is not cleared away.
  _scenario "a crash during the in-place install is a product failure" 1 setup-held map STUB_CRASH_ON_REPLACE=1
  _has "…blamed on the candidate, not the upgrade source" "verdict: product (rc 1)"
  # (32) The upgrade not taking.
  _scenario "a versionCode unchanged by the upgrade is a product failure" 1 setup-held map STUB_VC_UNCHANGED=1
  # (33) The device going away.
  _scenario "a device that goes offline is infrastructure" 3 setup-held map STUB_OFFLINE_AT_LAUNCH=1
  # (34) Another app holding the screen.
  _scenario "a foreign window until the deadline is a product failure naming it" 1 setup-held map STUB_FOREIGN=1
  _has "…naming the package" "com.android.permissioncontroller held the foreground"
  # (36) A debug log plant in a release build.
  _scenario "a debug log plant is a product failure" 1 setup-held map STUB_PLANTS=2
  # (37) A tap that does not take effect.
  _scenario "a CTA still on screen after its tap is 'did not progress'" 1 setup-held map STUB_CTA_STUCK=1
  _has "…the screen unchanged for the whole window after the tap" "did not progress: the screen did not change in the window after onboardingWelcomeCta was tapped"
  # (39) The device not in the state the gate needs.
  _scenario "a device that is not en-US is infrastructure" 3 setup-held map STUB_LOCALE=fr-FR
  _scenario "a device that will not go offline is infrastructure" 3 setup-held map STUB_AIRPLANE_STUCK=1
  # (41) A name field the gate cannot read is never tapped past.
  _scenario "a create screen without a readable name field is a product failure" 1 setup-held map STUB_EDIT_CLASS=android.view.View
  _has "…named as such" "never showed exactly one non-empty name field"
  # (43) An error state names its key; a required key missing is usage.
  _scenario "a display-name error on screen is a product failure naming it" 1 name-error map
  ARB_CAND="$(python3 -I -c 'import json,sys; d=json.loads(sys.argv[1]); d.pop("commonSettings"); print(json.dumps(d))' "${arb_now}")" \
    _scenario "an ARB without a required key is a usage error" 2 setup-held map

  if (( ran != SELF_TEST_FIXTURES )); then
    echo "SELF-TEST FAIL: ran ${ran} fixture(s), expected ${SELF_TEST_FIXTURES}" >&2
    fails=1
  fi
  if (( fails )); then
    echo "run-launch-gate-android.sh --self-test: FAILED" >&2
    return 1
  fi
  echo "run-launch-gate-android.sh --self-test: all ${ran} fixtures passed"
}

main() {
  local cand="${1:-}" prev="${2:-}" base="${LAUNCH_GATE_BASELINE_DIR:-}" d k
  local -a required_keys=("${KEY_WELCOME}" "${KEY_CREATE}" "${KEY_MAP}")
  mkdir -p "${OUT_DIR}"
  PRIV="$(mktemp -d)"
  chmod 0700 "${PRIV}"
  trap finish EXIT
  for d in "${cand}" "${prev}" ${base:+"${base}"}; do
    for k in install.apk app_en.arb version_code tag; do
      [[ -s "${d}/${k}" ]] || verdict 2 "'${d}' has no ${k}"
    done
    for k in "${required_keys[@]}"; do
      python3 -I "${UI_DUMP}" keys --arb "${d}/app_en.arb" --keys "${k}" | grep -qx "${k}" \
        || verdict 2 "$(cat "${d}/tag")'s app_en.arb has no usable ${k}"
    done
  done
  # The candidate also needs the way to its Identity page.
  for k in "${KEY_IDENTITY}" "${KEY_IDENTITY_PAGE}"; do
    python3 -I "${UI_DUMP}" keys --arb "${cand}/app_en.arb" --keys "${k}" | grep -qx "${k}" \
      || verdict 2 "the candidate's app_en.arb has no usable ${k}"
  done
  preconditions
  leg_fresh "${cand}"
  leg_upgrade upgrade "${prev}" "${cand}"
  if [[ -n "${base}" ]]; then
    leg_upgrade baseline "${base}" "${cand}"
  else
    say "baseline: skipped (LAUNCH_GATE_BASELINE_DIR unset: the baseline is the previous release)"
  fi
  LEG='all'
  STATE='done'
  verdict 0 "every leg passed"
}

if [[ "${1:-}" == "--self-test" ]]; then
  self_test
  exit $?
fi
main "$@"
